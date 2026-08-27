#!/usr/bin/env bash
# ============================================================================
# verifier(mdl-verifier) + MariaDB 통합 테스트 배포 스크립트 (bash)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh, mariadb/base/build-and-push.sh
#            가 먼저 실행되어 servicetech2 레지스트리에 MariaDB 이미지가 등록되어 있어야 함
#
# 이 스크립트가 하는 일:
#   1) MariaDB 컨테이너 배포 (레지스트리 이미지, DDL/DML 자동 실행, klevra 계정 생성)
#   2) verifier(mdl-verifier) 런타임 이미지 빌드 (Dockerfile은 VERIFIER_ROOT 안에 위치)
#   3) 위 두 컨테이너를 같은 브리지 네트워크로 묶어 컨테이너 이름으로 통신하도록 기동
#
# app 폴더 안의 mdl-verifier-1.*.jar 파일 "정확히 1개"만 실행합니다 (여러 개/0개면 에러).
# DB 종류는 현재 MariaDB로 고정입니다 (추후 다른 DBMS 지원 예정).
#
# 데이터는 휘발성(볼륨 미사용)입니다. 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

# Windows Git Bash(MSYS)는 "docker run -v SRC:DEST:MODE" 인자 안의 "/"로 시작하는
# 부분을 전부 Windows 경로로 잘못 변환한다(호스트 경로뿐 아니라 컨테이너 내부 경로까지 오염됨).
# 이 변수를 끄면 MSYS가 인자를 건드리지 않아 정상적으로 바인드마운트된다.
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"

c_reset='\033[0m'; c_green='\033[32m'; c_yellow='\033[33m'; c_red='\033[31m'; c_cyan='\033[36m'
info()  { printf "${c_cyan}[정보]${c_reset} %s\n" "$1"; }
ok()    { printf "${c_green}[완료]${c_reset} %s\n" "$1"; }
warn()  { printf "${c_yellow}[경고]${c_reset} %s\n" "$1"; }
err()   { printf "${c_red}[오류]${c_reset} %s\n" "$1" >&2; }

ask() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " REPLY
    REPLY="${REPLY:-$default}"
  else
    read -r -p "$prompt: " REPLY
  fi
}

ask_secret() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    read -r -s -p "$prompt [입력 없으면 기본값 사용]: " REPLY
    echo
    REPLY="${REPLY:-$default}"
  else
    read -r -s -p "$prompt: " REPLY
    echo
  fi
}

confirm() {
  local prompt="${1:-계속 진행할까요?}" reply
  read -r -p "$prompt (y/n) [y]: " reply
  reply="${reply:-y}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

confirm_no() {
  local prompt="${1:-계속 진행할까요?}" reply
  read -r -p "$prompt (y/n) [n]: " reply
  reply="${reply:-n}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

port_in_use() {
  local port="$1"
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"
}

echo "=============================================================="
echo " verifier(mdl-verifier) + MariaDB 통합 테스트 배포"
echo " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
echo "=============================================================="

# ---------- 0. 배포 환경 (개발/운영) ----------
echo
echo "이 배포가 어떤 환경을 대상으로 하는지 선택하세요:"
echo "  1) 개발 (기본값)"
echo "  2) 운영"
ask "번호 선택" "1"
case "$REPLY" in
  1) DEPLOY_ENV="개발" ;;
  2) DEPLOY_ENV="운영" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
if [[ "$DEPLOY_ENV" == "운영" ]]; then
  warn "이 스크립트는 데이터가 휘발성(볼륨 미사용)인 테스트/개발용 배포입니다."
  if ! confirm_no "정말로 '운영' 환경 대상으로 진행할까요? (권장하지 않음)"; then
    err "사용자가 취소했습니다."
    exit 1
  fi
fi

# ---------- 1. 공용 네트워크 ----------
echo
ask "MariaDB↔verifier 통신용 브리지 네트워크 이름" "verifier-net"
NETWORK_NAME="$REPLY"
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  info "네트워크 '${NETWORK_NAME}'가 없어 새로 생성합니다 (bridge)."
  docker network create "$NETWORK_NAME" >/dev/null
  ok "네트워크 생성 완료 (driver=bridge — 컨테이너명 DNS 해석 + 외부 인터넷 접근 모두 기본 지원)"
else
  ok "기존 네트워크 '${NETWORK_NAME}'를 사용합니다."
fi

# ============================================================================
# PART A. MariaDB 배포
# ============================================================================
echo
echo "----------------------------- [A] MariaDB -----------------------------"

ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"

echo
echo "배포할 MariaDB 버전(레지스트리 태그)을 선택하세요:"
echo "  1) latest"
echo "  2) 11.4   (LTS)"
echo "  3) 10.11  (구버전 LTS, 레거시 호환용)"
ask "번호 선택" "1"
case "$REPLY" in
  1) TAG="latest" ;;
  2) TAG="11.4" ;;
  3) TAG="10.11" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
DB_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/mariadb:${TAG}"

if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi
info "레지스트리 이미지를 내려받는 중입니다: $DB_IMAGE"
if ! docker pull "$DB_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 mariadb/base/build-and-push.sh 로 '${TAG}' 태그를 등록하세요."
  exit 1
fi

echo
ask "MariaDB 컨테이너 이름" "mariadb-verifier"
DB_CONTAINER="$REPLY"
if docker ps -a --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
  warn "이미 '$DB_CONTAINER' 이름의 컨테이너가 존재합니다."
  if confirm "기존 컨테이너를 삭제하고 새로 만들까요?"; then
    docker rm -f "$DB_CONTAINER" >/dev/null
    ok "기존 컨테이너 삭제 완료"
  else
    err "컨테이너 이름 충돌로 중단합니다."
    exit 1
  fi
fi

echo
ask "DB(스키마) 이름" "VC_VERIFIER"
DB_NAME="$REPLY"

echo
warn "root 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
ask_secret "root 초기 비밀번호 (비우면 랜덤 생성)" ""
DB_ROOT_PASSWORD="$REPLY"
GENERATED_PW=0
if [[ -z "$DB_ROOT_PASSWORD" ]]; then
  DB_ROOT_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  GENERATED_PW=1
  ok "root 비밀번호를 자동 생성했습니다 (아래 실행 요약/접속 정보에 표시됩니다)."
fi

echo
info "verifier용 애플리케이션 계정입니다. 기본값은 이번 통합 테스트에서 실제 검증된 klevra/theg3p2 입니다."
ask "애플리케이션 계정 이름" "klevra"
APP_USER="$REPLY"
ask_secret "애플리케이션 계정 비밀번호" "theg3p2"
APP_PASSWORD="$REPLY"

# ---------- DDL(스키마) 경로 입력 + 체크 ----------
echo
ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DDL_DIR="$REPLY"
DETECTED_DB_NAME=""
if [[ -n "$DDL_DIR" && -d "$DDL_DIR" ]]; then
  DETECTED_DB_NAME="$(grep -ohiE 'CREATE[[:space:]]+DATABASE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?`?[A-Za-z0-9_]+`?' "$DDL_DIR"/*.sql 2>/dev/null \
    | head -n1 | grep -oE '`?[A-Za-z0-9_]+`?$' | tr -d '`')"
  if [[ -n "$DETECTED_DB_NAME" ]]; then
    info "DDL 파일에서 감지된 DB 이름: ${DETECTED_DB_NAME}"
    if [[ "$DETECTED_DB_NAME" != "$DB_NAME" ]]; then
      warn "입력한 DB 이름(${DB_NAME})과 DDL이 생성하는 DB 이름(${DETECTED_DB_NAME})이 다릅니다."
      if confirm "DDL 기준(${DETECTED_DB_NAME})으로 맞출까요? ('n'이면 입력한 이름 ${DB_NAME} 유지)"; then
        DB_NAME="$DETECTED_DB_NAME"
        ok "DB 이름을 '${DB_NAME}'로 맞췄습니다."
      fi
    else
      ok "DDL의 DB 이름과 일치합니다."
    fi
  else
    warn "DDL 파일에서 CREATE DATABASE 구문을 찾지 못했습니다 (체크를 건너뜁니다)."
  fi
fi

# ---------- DML(초기데이터) 경로 입력 + partner code 반영 ----------
echo
ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DML_DIR="$REPLY"
echo
ask "VF_ORGANIZATION.PARTNER_CODE 값" "oacx"
PARTNER_CODE="$REPLY"

STAGING_DIR="${SCRIPT_DIR}/.staging/${DB_CONTAINER}/initdb"
SETUP_MOUNT=0
if [[ -n "$DDL_DIR" || -n "$DML_DIR" ]]; then
  rm -rf "${SCRIPT_DIR}/.staging/${DB_CONTAINER}"
  mkdir -p "$STAGING_DIR"
  if [[ -n "$DDL_DIR" ]]; then
    if [[ -d "$DDL_DIR" ]]; then
      i=1
      for f in "$DDL_DIR"/*; do
        [[ -f "$f" ]] || continue
        cp "$f" "${STAGING_DIR}/10_$(printf '%03d' "$i")_$(basename "$f")"
        i=$((i + 1))
      done
      ok "DDL 파일 $((i - 1))개를 스테이징했습니다 (10_ 접두어)"
    else
      warn "DDL 경로를 찾을 수 없습니다: $DDL_DIR (건너뜁니다)"
    fi
  fi
  if [[ -n "$DML_DIR" ]]; then
    if [[ -d "$DML_DIR" ]]; then
      i=1
      PATCHED=0
      for f in "$DML_DIR"/*; do
        [[ -f "$f" ]] || continue
        dest="${STAGING_DIR}/50_$(printf '%03d' "$i")_$(basename "$f")"
        cp "$f" "$dest"
        # VF_ORGANIZATION INSERT의 PARTNER_CODE 값을 입력받은 값으로 치환
        if grep -qi 'INSERT INTO VF_ORGANIZATION' "$dest" 2>/dev/null; then
          sed -i -E "s/(INSERT[[:space:]]+INTO[[:space:]]+VF_ORGANIZATION\([^)]*\)[[:space:]]*VALUES[[:space:]]*\()'[^']*'/\1'${PARTNER_CODE}'/I" "$dest"
          PATCHED=1
        fi
        i=$((i + 1))
      done
      ok "DML 파일 $((i - 1))개를 스테이징했습니다 (50_ 접두어)"
      if [[ "$PATCHED" -eq 1 ]]; then
        ok "VF_ORGANIZATION.PARTNER_CODE 값을 '${PARTNER_CODE}'로 반영했습니다."
      else
        warn "VF_ORGANIZATION INSERT 구문을 찾지 못해 PARTNER_CODE를 반영하지 못했습니다."
      fi
    else
      warn "DML 경로를 찾을 수 없습니다: $DML_DIR (건너뜁니다)"
    fi
  fi
  SETUP_MOUNT=1
  warn "MariaDB의 /docker-entrypoint-initdb.d/ 자동 실행은 최초 기동 시에만 동작합니다 (이 프로젝트는 항상 휘발성이라 매번 최초 기동입니다)."
fi

echo
ask "MariaDB 포트" "3306"
DB_PORT="$REPLY"
if port_in_use "$DB_PORT"; then
  warn "포트 ${DB_PORT}은(는) 이미 사용 중인 것으로 보입니다."
fi

# ---------- MariaDB 실행 ----------
echo
{
echo "=================== [A] MariaDB 실행 요약 ==================="
echo " 이미지        : $DB_IMAGE"
echo " 컨테이너 이름 : $DB_CONTAINER"
echo " DB 이름       : $DB_NAME"
echo " 포트          : $DB_PORT"
echo " 네트워크      : $NETWORK_NAME"
echo " 앱 계정       : $APP_USER"
echo " DDL 경로      : ${DDL_DIR:-(없음)}"
echo " DML 경로      : ${DML_DIR:-(없음)} (PARTNER_CODE=${PARTNER_CODE})"
[[ "$GENERATED_PW" -eq 1 ]] && echo " 생성된 root 비밀번호 : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==============================================================="
}
if ! confirm "위 설정으로 MariaDB 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

DB_RUN_ARGS=(-d --name "$DB_CONTAINER" --network "$NETWORK_NAME" -p "${DB_PORT}:3306")
[[ "$SETUP_MOUNT" -eq 1 ]] && DB_RUN_ARGS+=(-v "${STAGING_DIR}:/docker-entrypoint-initdb.d:ro")
DB_RUN_ARGS+=(
  --health-cmd='healthcheck.sh --connect --innodb_initialized || exit 1'
  --health-interval=5s --health-timeout=5s --health-start-period=30s --health-retries=10
)
DB_RUN_ARGS+=(
  -e "MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
  -e "MARIADB_DATABASE=${DB_NAME}"
  -e "MARIADB_USER=${APP_USER}"
  -e "MARIADB_PASSWORD=${APP_PASSWORD}"
  -e "TZ=Asia/Seoul"
)

info "MariaDB 컨테이너를 실행합니다: $DB_CONTAINER"
docker run "${DB_RUN_ARGS[@]}" "$DB_IMAGE" >/dev/null

info "MariaDB 초기화를 기다리는 중입니다..."
ELAPSED=0; INTERVAL=5; TIMEOUT=300
while true; do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null || echo unknown)"
  if [[ "$STATUS" == "healthy" ]]; then
    ok "MariaDB가 정상 기동되었습니다."
    break
  fi
  if ! docker ps -q -f "name=^${DB_CONTAINER}\$" | grep -q .; then
    err "MariaDB 컨테이너가 중단되었습니다. 로그:"
    docker logs "$DB_CONTAINER" 2>&1 | tail -60
    exit 1
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    warn "제한 시간 내에 healthy 상태가 되지 않았습니다. 'docker logs -f ${DB_CONTAINER}'로 확인하세요."
    break
  fi
  sleep "$INTERVAL"; ELAPSED=$((ELAPSED + INTERVAL)); printf "."
done
echo

# ============================================================================
# PART B. verifier 배포
# ============================================================================
echo
echo "----------------------------- [B] verifier -----------------------------"

ask "verifier 설정 루트 경로 (Dockerfile, app/, config/ 가 있는 위치)" "D:\\03. Docker\\sandbox\\verifier"
VERIFIER_ROOT="$REPLY"
if [[ ! -f "${VERIFIER_ROOT}/Dockerfile" ]]; then
  err "Dockerfile을 찾을 수 없습니다: ${VERIFIER_ROOT}/Dockerfile"
  exit 1
fi
if [[ ! -d "${VERIFIER_ROOT}/app" || ! -d "${VERIFIER_ROOT}/config" ]]; then
  err "app/ 또는 config/ 폴더를 찾을 수 없습니다: ${VERIFIER_ROOT}"
  exit 1
fi

# app 폴더 안 mdl-verifier-1.*.jar 파일이 정확히 1개인지 확인
JAR_COUNT=0
JAR_NAME=""
for f in "${VERIFIER_ROOT}/app"/mdl-verifier-1.*.jar; do
  [[ -f "$f" ]] || continue
  JAR_COUNT=$((JAR_COUNT + 1))
  JAR_NAME="$(basename "$f")"
done
if [[ "$JAR_COUNT" -eq 0 ]]; then
  err "${VERIFIER_ROOT}/app 안에 mdl-verifier-1.*.jar 파일이 없습니다."
  exit 1
elif [[ "$JAR_COUNT" -gt 1 ]]; then
  err "${VERIFIER_ROOT}/app 안에 mdl-verifier-1.*.jar 파일이 ${JAR_COUNT}개 있습니다. 정확히 1개만 남겨주세요."
  exit 1
fi
ok "실행 대상 JAR 확인: $JAR_NAME"

echo
ask "verifier 컨테이너 이름" "verifier"
VF_CONTAINER="$REPLY"
if docker ps -a --format '{{.Names}}' | grep -qx "$VF_CONTAINER"; then
  warn "이미 '$VF_CONTAINER' 이름의 컨테이너가 존재합니다."
  if confirm "기존 컨테이너를 삭제하고 새로 만들까요?"; then
    docker rm -f "$VF_CONTAINER" >/dev/null
    ok "기존 컨테이너 삭제 완료"
  else
    err "컨테이너 이름 충돌로 중단합니다."
    exit 1
  fi
fi

# application-sp.properties의 api-server-domain에 박힌 포트를 기본값으로 시도 추출
DETECTED_APP_PORT=""
SP_PROP="${VERIFIER_ROOT}/config/config/application-sp.properties"
if [[ -f "$SP_PROP" ]]; then
  DETECTED_APP_PORT="$(grep -oE 'mdl\.sp\.api-server-domain=.*:[0-9]+' "$SP_PROP" 2>/dev/null | grep -oE '[0-9]+$' | head -n1)"
fi
echo
ask "컨테이너 내부 애플리케이션 포트" "${DETECTED_APP_PORT:-48085}"
VF_INTERNAL_PORT="$REPLY"
ask "호스트에 노출할 포트" "48085"
VF_HOST_PORT="$REPLY"
if port_in_use "$VF_HOST_PORT"; then
  warn "포트 ${VF_HOST_PORT}은(는) 이미 사용 중인 것으로 보입니다."
fi

echo
{
echo "=================== [B] verifier 실행 요약 ==================="
echo " 설정 루트     : $VERIFIER_ROOT"
echo " 실행 JAR      : $JAR_NAME"
echo " 컨테이너 이름 : $VF_CONTAINER"
echo " 네트워크      : $NETWORK_NAME (MariaDB: $DB_CONTAINER)"
echo " 포트          : ${VF_HOST_PORT} -> ${VF_INTERNAL_PORT}"
echo " 배포 환경     : $DEPLOY_ENV"
echo "================================================================"
}
if ! confirm "위 설정으로 verifier 이미지를 빌드하고 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

info "verifier 런타임 이미지를 빌드합니다..."
if ! docker build -t verifier-jdk8:local -f "${VERIFIER_ROOT}/Dockerfile" "$VERIFIER_ROOT"; then
  err "이미지 빌드에 실패했습니다."
  exit 1
fi
ok "이미지 빌드 완료: verifier-jdk8:local"

# 로그는 각 서비스 폴더 밑이 아니라, VERIFIER_ROOT와 같은 부모(sandbox) 아래 공용 log/ 트리에 모은다.
LOG_ROOT="$(dirname "$VERIFIER_ROOT")/log/verifier"
mkdir -p "$LOG_ROOT"

# application-datasource.properties는 DB 컨테이너 이름/DB명/계정을 하드코딩하고 있어
# 실행할 때마다 위에서 입력받은 실제 값으로 맞춰야 한다.
# 원본(VERIFIER_ROOT/config/config)은 건드리지 않고, 스테이징 사본만 패치해서 마운트한다.
VF_CONFIG_STAGING="${SCRIPT_DIR}/.staging/${VF_CONTAINER}/config"
rm -rf "$VF_CONFIG_STAGING"
mkdir -p "$VF_CONFIG_STAGING"
cp -r "${VERIFIER_ROOT}/config/config/." "$VF_CONFIG_STAGING/"
DS_PROP="${VF_CONFIG_STAGING}/application-datasource.properties"
if [[ -f "$DS_PROP" ]]; then
  sed -i -E \
    -e "s#(spring\.datasource\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" \
    -e "s#(spring\.datasource\.hikari\.username=).*#\1${APP_USER}#" \
    -e "s#(spring\.datasource\.hikari\.password=).*#\1${APP_PASSWORD}#" \
    "$DS_PROP"
  ok "application-datasource.properties에 실제 MariaDB 접속정보(host=${DB_CONTAINER}, db=${DB_NAME}, user=${APP_USER})를 반영했습니다."
else
  warn "application-datasource.properties를 찾지 못해 DB 접속정보를 자동 반영하지 못했습니다."
fi

VF_RUN_ARGS=(-d --name "$VF_CONTAINER" --network "$NETWORK_NAME" -p "${VF_HOST_PORT}:${VF_INTERNAL_PORT}")
VF_RUN_ARGS+=(
  -v "${VERIFIER_ROOT}/app:/app:ro"
  -v "${VERIFIER_ROOT}/app/jdbc:/jdbc:ro"
  -v "${VF_CONFIG_STAGING}:/config"
  -v "${VERIFIER_ROOT}/config/template:/config/template:ro"
  -v "${VERIFIER_ROOT}/config/license:/config/license:ro"
  -v "${VERIFIER_ROOT}/config/sp:/config/sp:ro"
  -v "${VERIFIER_ROOT}/config/fonts:/config/fonts:ro"
  -v "${LOG_ROOT}:/logs"
)
VF_RUN_ARGS+=(
  -e "SPRING_CONFIG_ADDITIONAL_LOCATION=file:/config/"
  -e "LOGGING_FILE_PATH=/logs"
  -e "LOADER_PATH=/jdbc"
)

info "verifier 컨테이너를 실행합니다: $VF_CONTAINER"
docker run "${VF_RUN_ARGS[@]}" verifier-jdk8:local >/dev/null

info "verifier 기동을 기다리는 중입니다 (Spring Boot 기동에 30~40초 정도 걸립니다)..."
ELAPSED=0; INTERVAL=5; TIMEOUT=180; BOOTED=0
while [[ "$ELAPSED" -lt "$TIMEOUT" ]]; do
  if docker logs "$VF_CONTAINER" 2>&1 | grep -q "Started MdlApiApplication"; then
    BOOTED=1
    break
  fi
  if ! docker ps -q -f "name=^${VF_CONTAINER}\$" | grep -q .; then
    err "verifier 컨테이너가 중단되었습니다. 로그:"
    docker logs "$VF_CONTAINER" 2>&1 | tail -60
    exit 1
  fi
  sleep "$INTERVAL"; ELAPSED=$((ELAPSED + INTERVAL)); printf "."
done
echo
if [[ "$BOOTED" -eq 1 ]]; then
  ok "$(docker logs "$VF_CONTAINER" 2>&1 | grep "Started MdlApiApplication" | tail -1)"
else
  warn "제한 시간 내에 기동 완료 로그를 확인하지 못했습니다. 'docker logs -f ${VF_CONTAINER}'로 확인하세요."
fi

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${VF_HOST_PORT}/" 2>/dev/null)"
[[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]] || HTTP_CODE="000"
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
  ok "HTTP 응답 확인: ${HTTP_CODE}"
else
  warn "HTTP 응답 확인 실패 또는 예상 외 코드: ${HTTP_CODE}"
fi

# ---------- 최종 접속 정보 ----------
echo
{
echo "======================= 접속 정보 ======================="
echo " 배포 환경     : $DEPLOY_ENV"
echo " -------------------------- [MariaDB] --------------------------"
echo " Host          : localhost"
echo " Port          : $DB_PORT"
echo " Database      : $DB_NAME"
echo " App 계정      : $APP_USER"
echo " JDBC URL      : jdbc:mariadb://localhost:${DB_PORT}/${DB_NAME}"
echo " (컨테이너 간 통신용 Host: ${DB_CONTAINER}, Network: ${NETWORK_NAME})"
echo " -------------------------- [verifier] --------------------------"
echo " URL           : http://localhost:${VF_HOST_PORT}/"
echo " PARTNER_CODE  : $PARTNER_CODE"
[[ "$GENERATED_PW" -eq 1 ]] && echo " root 비밀번호(MariaDB) : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
unset DB_ROOT_PASSWORD APP_PASSWORD
