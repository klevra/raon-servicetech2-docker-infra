#!/usr/bin/env bash
# ============================================================================
# OACX(Tomcat) + MariaDB 통합 테스트 배포 스크립트 (bash)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh, mariadb/base/build-and-push.sh
#            가 먼저 실행되어 servicetech2 레지스트리에 MariaDB 이미지가 등록되어 있어야 함
#
# 이 스크립트가 하는 일:
#   1) MariaDB 컨테이너 배포 (레지스트리 이미지, DDL/DML 자동 실행, omnione 계정 생성)
#   2) OACX_ROOT/app, OACX_ROOT/config를 매 실행마다 스테이징 사본으로 떠서
#      - app/WEB-INF/web.xml의 config.file(상대경로) -> /config/server.properties(절대경로) 패치
#      - config/server.properties의 DB접속정보/절대경로/oper.mode 패치
#   3) 공식 tomcat:9-jdk8-temurin 이미지를 그대로 사용 (별도 빌드 없음).
#      oacx는 webapps/ 밑에 직접 두지 않고, conf/Catalina/localhost/oacx.xml로
#      docBase="/app" Context를 등록해서 붙인다 (uniform /app,/config,/logs 마운트 컨벤션 유지).
#   4) 위 두 컨테이너를 같은 브리지 네트워크로 묶어 컨테이너 이름으로 통신하도록 기동
#
# DML(01.insert_data.sql)의 OACX_PROVIDER.OPER_SORT 값은 배포 환경(개발/운영)에 따라
# 'dev'/'prod'로 자동 치환됩니다 (개발이 기본값).
#
# 데이터는 휘발성(볼륨 미사용)입니다. 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

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
echo " OACX(Tomcat) + MariaDB 통합 테스트 배포"
echo " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
echo "=============================================================="

# ---------- 0. 배포 환경 (개발/운영) ----------
echo
echo "이 배포가 어떤 환경을 대상으로 하는지 선택하세요:"
echo "  1) 개발 (기본값)"
echo "  2) 운영"
ask "번호 선택" "1"
case "$REPLY" in
  1) DEPLOY_ENV="개발"; OPER_SORT="dev" ;;
  2) DEPLOY_ENV="운영"; OPER_SORT="prod" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
if [[ "$DEPLOY_ENV" == "운영" ]]; then
  warn "이 스크립트는 데이터가 휘발성(볼륨 미사용)인 테스트/개발용 배포입니다."
  if ! confirm_no "정말로 '운영' 환경 대상으로 진행할까요? (권장하지 않음)"; then
    err "사용자가 취소했습니다."
    exit 1
  fi
fi
info "OACX_PROVIDER.OPER_SORT는 '${OPER_SORT}'로, server.properties의 oper.mode도 '${OPER_SORT}'로 반영됩니다."

# ---------- 1. 공용 네트워크 ----------
echo
ask "MariaDB↔OACX 통신용 브리지 네트워크 이름" "oacx-net"
NETWORK_NAME="$REPLY"
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  info "네트워크 '${NETWORK_NAME}'가 없어 새로 생성합니다 (bridge)."
  docker network create "$NETWORK_NAME" >/dev/null
  ok "네트워크 생성 완료"
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
ask "MariaDB 컨테이너 이름" "mariadb-oacx"
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
ask "DB(스키마) 이름" "OACX"
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
info "OACX용 애플리케이션 계정입니다. 기본값은 실제 config(server.properties)에 있는 omnione 계정입니다."
ask "애플리케이션 계정 이름" "omnione"
APP_USER="$REPLY"
ask_secret "애플리케이션 계정 비밀번호" "0mN1DB"
APP_PASSWORD="$REPLY"

# ---------- DDL(스키마) 경로 입력 + 체크 ----------
echo
ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DDL_DIR="$REPLY"
DETECTED_DB_NAME=""
if [[ -n "$DDL_DIR" && -d "$DDL_DIR" ]]; then
  DETECTED_DB_NAME="$(grep -ohiE 'CREATE[[:space:]]+DATABASE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?[`]?[A-Za-z0-9_]+[`]?' "$DDL_DIR"/*.sql 2>/dev/null \
    | head -n1 | grep -oE '[`]?[A-Za-z0-9_]+[`]?$' | tr -d '`')"
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
    warn "DDL 파일에서 CREATE DATABASE 구문을 찾지 못했습니다 (OACX DDL은 원래 이 구문이 없습니다 — 정상)."
  fi
fi

# ---------- DML(초기데이터) 경로 입력 + OPER_SORT 반영 ----------
echo
ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DML_DIR="$REPLY"

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
        # OACX_PROVIDER의 OPER_SORT 값('ent' 바로 다음 컬럼)을 배포 환경에 맞춰 dev/prod로 치환
        if grep -qi "INSERT INTO OACX_PROVIDER" "$dest" 2>/dev/null; then
          sed -i -E "s/('ent'[[:space:]]*,[[:space:]]*')(prod|dev)(')/\1${OPER_SORT}\3/gI" "$dest"
          PATCHED=1
        fi
        i=$((i + 1))
      done
      ok "DML 파일 $((i - 1))개를 스테이징했습니다 (50_ 접두어)"
      if [[ "$PATCHED" -eq 1 ]]; then
        ok "OACX_PROVIDER.OPER_SORT 값을 '${OPER_SORT}'로 반영했습니다."
      else
        warn "OACX_PROVIDER INSERT 구문을 찾지 못해 OPER_SORT를 반영하지 못했습니다."
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
echo " DML 경로      : ${DML_DIR:-(없음)} (OPER_SORT=${OPER_SORT})"
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
# PART B. OACX(Tomcat) 배포
# ============================================================================
echo
echo "----------------------------- [B] OACX -----------------------------"

ask "OACX 설정 루트 경로 (app/, config/ 가 있는 위치)" "D:\\03. Docker\\sandbox\\oacx"
OACX_ROOT="$REPLY"
if [[ ! -d "${OACX_ROOT}/app" || ! -d "${OACX_ROOT}/config" ]]; then
  err "app/ 또는 config/ 폴더를 찾을 수 없습니다: ${OACX_ROOT}"
  exit 1
fi
if [[ ! -f "${OACX_ROOT}/app/WEB-INF/web.xml" ]]; then
  err "app/WEB-INF/web.xml을 찾을 수 없습니다: ${OACX_ROOT}"
  exit 1
fi
if [[ ! -f "${OACX_ROOT}/config/server.properties" ]]; then
  err "config/server.properties를 찾을 수 없습니다: ${OACX_ROOT}"
  exit 1
fi

echo
ask "OACX 컨테이너 이름" "oacx"
OACX_CONTAINER="$REPLY"
if docker ps -a --format '{{.Names}}' | grep -qx "$OACX_CONTAINER"; then
  warn "이미 '$OACX_CONTAINER' 이름의 컨테이너가 존재합니다."
  if confirm "기존 컨테이너를 삭제하고 새로 만들까요?"; then
    docker rm -f "$OACX_CONTAINER" >/dev/null
    ok "기존 컨테이너 삭제 완료"
  else
    err "컨테이너 이름 충돌로 중단합니다."
    exit 1
  fi
fi

ask "Tomcat 이미지 태그" "tomcat:9-jdk8-temurin"
TOMCAT_IMAGE="$REPLY"
info "Tomcat 이미지를 내려받는 중입니다: $TOMCAT_IMAGE (별도 빌드 없이 공식 이미지 그대로 사용)"
if ! docker pull "$TOMCAT_IMAGE"; then
  err "이미지를 가져오지 못했습니다: $TOMCAT_IMAGE"
  exit 1
fi

echo
ask "Context path (URL: http://localhost:<포트>/<이 값>/)" "oacx"
CONTEXT_PATH="$REPLY"
ask "호스트에 노출할 포트" "8080"
OACX_HOST_PORT="$REPLY"
if port_in_use "$OACX_HOST_PORT"; then
  warn "포트 ${OACX_HOST_PORT}은(는) 이미 사용 중인 것으로 보입니다."
fi

echo
info "provider.json 설정들의 services.authen.urls.base가 verifier 컨테이너를 바라보므로, 컨테이너 이름으로 통신하려면 verifier가 붙어있는 네트워크에도 연결해야 합니다."
ask "verifier와 연동할 네트워크 이름 (비우면 연동 안 함)" "verifier-net"
VERIFIER_NETWORK="$REPLY"

echo
{
echo "=================== [B] OACX 실행 요약 ==================="
echo " 설정 루트     : $OACX_ROOT"
echo " 이미지        : $TOMCAT_IMAGE"
echo " 컨테이너 이름 : $OACX_CONTAINER"
echo " 네트워크      : $NETWORK_NAME (MariaDB: $DB_CONTAINER)"
echo " verifier 연동 : ${VERIFIER_NETWORK:-(연동 안 함)}"
echo " Context path  : /$CONTEXT_PATH"
echo " 포트          : ${OACX_HOST_PORT} -> 8080"
echo " 배포 환경     : $DEPLOY_ENV (oper.mode=${OPER_SORT})"
echo "============================================================"
}
if ! confirm "위 설정으로 OACX 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ---------- app/ 스테이징 + web.xml 패치 ----------
info "app/ 를 스테이징하고 web.xml의 config.file을 절대경로로 패치합니다 (원본은 건드리지 않음)..."
OACX_APP_STAGING="${SCRIPT_DIR}/.staging/${OACX_CONTAINER}/app"
rm -rf "$OACX_APP_STAGING"
mkdir -p "$(dirname "$OACX_APP_STAGING")"
cp -r "${OACX_ROOT}/app" "$OACX_APP_STAGING"
sed -i -E "s#(<param-value>)\./WEB-INF/config/server\.properties(</param-value>)#\1/config/server.properties\2#" \
  "${OACX_APP_STAGING}/WEB-INF/web.xml"
if grep -q "/config/server.properties" "${OACX_APP_STAGING}/WEB-INF/web.xml"; then
  ok "web.xml의 config.file을 /config/server.properties(절대경로)로 패치했습니다."
else
  warn "web.xml의 config.file 패치에 실패했습니다 (패턴을 찾지 못함). 원본 상대경로가 그대로 사용됩니다."
fi

# ---------- config/ 스테이징 + server.properties 패치 ----------
info "config/ 를 스테이징하고 server.properties를 실제 배포값으로 패치합니다 (원본은 건드리지 않음)..."
OACX_CONFIG_STAGING="${SCRIPT_DIR}/.staging/${OACX_CONTAINER}/config"
rm -rf "$OACX_CONFIG_STAGING"
mkdir -p "$OACX_CONFIG_STAGING"
cp -r "${OACX_ROOT}/config/." "$OACX_CONFIG_STAGING/"
SP_PROP="${OACX_CONFIG_STAGING}/server.properties"
sed -i -E \
  -e "s#(jdbc\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" \
  -e "s#(jdbc\.user=).*#\1${APP_USER}#" \
  -e "s#(jdbc\.password=).*#\1${APP_PASSWORD}#" \
  -e "s#(mybatis\.mapper\.path=).*#\1/config/mybatis#" \
  -e "s#(log\.file=).*#\1/config/logback.xml#" \
  -e "s#(log\.path=).*#\1/logs/app#" \
  -e "s#(oper\.mode=).*#\1${OPER_SORT}#" \
  "$SP_PROP"
ok "server.properties에 실제 배포값(host=${DB_CONTAINER}, db=${DB_NAME}, user=${APP_USER}, oper.mode=${OPER_SORT})을 반영했습니다."

# ---------- Tomcat Context XML 생성 ----------
CONTEXT_XML="${SCRIPT_DIR}/.staging/${OACX_CONTAINER}/${CONTEXT_PATH}.xml"
cat > "$CONTEXT_XML" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="/app" path="/${CONTEXT_PATH}" reloadable="false" />
XMLEOF
ok "Context XML 생성: ${CONTEXT_PATH}.xml (docBase=/app, path=/${CONTEXT_PATH})"

# ---------- 로그 디렉터리 (Tomcat 자체 로그 / 앱 로그 분리) ----------
# 로그는 각 서비스 폴더 밑이 아니라, OACX_ROOT와 같은 부모(sandbox) 아래 공용 log/ 트리에 모은다.
LOG_ROOT="$(dirname "$OACX_ROOT")/log/oacx"
mkdir -p "${LOG_ROOT}/tomcat" "${LOG_ROOT}/app"

OACX_RUN_ARGS=(-d --name "$OACX_CONTAINER" --network "$NETWORK_NAME" -p "${OACX_HOST_PORT}:8080")
OACX_RUN_ARGS+=(
  -v "${OACX_APP_STAGING}:/app"
  -v "${OACX_CONFIG_STAGING}:/config:ro"
  -v "${CONTEXT_XML}:/usr/local/tomcat/conf/Catalina/localhost/${CONTEXT_PATH}.xml:ro"
  -v "${LOG_ROOT}/tomcat:/usr/local/tomcat/logs"
  -v "${LOG_ROOT}/app:/logs/app"
)

info "OACX(Tomcat) 컨테이너를 실행합니다: $OACX_CONTAINER"
docker run "${OACX_RUN_ARGS[@]}" "$TOMCAT_IMAGE" >/dev/null

if [[ -n "$VERIFIER_NETWORK" ]]; then
  if docker network inspect "$VERIFIER_NETWORK" >/dev/null 2>&1; then
    docker network connect "$VERIFIER_NETWORK" "$OACX_CONTAINER"
    ok "'${OACX_CONTAINER}'를 네트워크 '${VERIFIER_NETWORK}'에도 연결했습니다 (verifier 컨테이너명으로 통신 가능)."
  else
    warn "네트워크 '${VERIFIER_NETWORK}'가 존재하지 않습니다 (verifier가 먼저 떠있어야 함). 연동을 건너뜁니다."
  fi
fi

info "OACX 기동을 기다리는 중입니다 (Tomcat + WAR 초기화에 시간이 걸릴 수 있습니다)..."
ELAPSED=0; INTERVAL=5; TIMEOUT=180; BOOTED=0
while [[ "$ELAPSED" -lt "$TIMEOUT" ]]; do
  if docker logs "$OACX_CONTAINER" 2>&1 | grep -q "Server startup"; then
    BOOTED=1
    break
  fi
  if ! docker ps -q -f "name=^${OACX_CONTAINER}\$" | grep -q .; then
    err "OACX 컨테이너가 중단되었습니다. 로그:"
    docker logs "$OACX_CONTAINER" 2>&1 | tail -60
    exit 1
  fi
  sleep "$INTERVAL"; ELAPSED=$((ELAPSED + INTERVAL)); printf "."
done
echo
if [[ "$BOOTED" -eq 1 ]]; then
  ok "$(docker logs "$OACX_CONTAINER" 2>&1 | grep "Server startup" | tail -1)"
else
  warn "제한 시간 내에 기동 완료 로그를 확인하지 못했습니다. 'docker logs -f ${OACX_CONTAINER}'로 확인하세요."
fi

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${OACX_HOST_PORT}/${CONTEXT_PATH}/" 2>/dev/null)"
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
echo " 배포 환경     : $DEPLOY_ENV (oper.mode / OACX_PROVIDER.OPER_SORT = ${OPER_SORT})"
echo " -------------------------- [MariaDB] --------------------------"
echo " Host          : localhost"
echo " Port          : $DB_PORT"
echo " Database      : $DB_NAME"
echo " App 계정      : $APP_USER"
echo " JDBC URL      : jdbc:mariadb://localhost:${DB_PORT}/${DB_NAME}"
echo " (컨테이너 간 통신용 Host: ${DB_CONTAINER}, Network: ${NETWORK_NAME})"
echo " -------------------------- [OACX] --------------------------"
echo " URL           : http://localhost:${OACX_HOST_PORT}/${CONTEXT_PATH}/"
[[ "$GENERATED_PW" -eq 1 ]] && echo " root 비밀번호(MariaDB) : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
unset DB_ROOT_PASSWORD APP_PASSWORD
