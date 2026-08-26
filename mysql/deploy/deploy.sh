#!/usr/bin/env bash
# ============================================================================
# MySQL 테스트 인스턴스 배포 스크립트 (bash) — servicetech2 레지스트리 기반
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh, mysql/base/build-and-push.sh
#            가 먼저 실행되어 servicetech2 레지스트리에 이미지가 등록되어 있어야 함
#            (레지스트리 자체는 DB 종류와 무관하게 공용으로 사용)
#
# 대화형으로 아래 항목을 입력받습니다:
#   1) DB 종류 (현재 MySQL 고정)    2) MySQL 버전(레지스트리 태그)
#   3) 컨테이너 이름                4) DB 이름(스키마)
#   5) 관리자(root) 비밀번호        6) 애플리케이션 계정(선택)
#   7) DDL SQL 파일 경로            8) 초기데이터 DML SQL 파일 경로
#   9) 포트 (리스너)                10) 실행 로그 파일 저장 여부 (선택, 기본 n)
#
# 접속 IP 제한: 이 프로젝트는 별도 bind-address 제약이나 방화벽 규칙을 추가하지
# 않으며, docker run -p 도 호스트IP 미지정(0.0.0.0 바인딩)이라 기본적으로 접속 IP
# 제한이 없습니다. (단, MySQL은 Oracle과 달리 계정이 'user'@'host' 형태로 host에
# 종속될 수 있으나, 공식 이미지의 MYSQL_USER는 '%'(모든 host)로 생성됨)
#
# 데이터는 휘발성(볼륨 미사용)입니다. 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

# Windows Git Bash(MSYS)는 "docker run -v SRC:DEST:MODE" 인자 안의 "/"로 시작하는
# 부분을 전부 Windows 경로로 잘못 변환한다(호스트 경로뿐 아니라 컨테이너 내부 경로까지 오염됨).
# 이 변수를 끄면 MSYS가 인자를 건드리지 않아 정상적으로 바인드마운트된다.
# (Linux/macOS의 순정 bash에는 이 변수가 없어 아무 영향 없음 — 안전하게 항상 설정)
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
  local prompt="$1"
  read -r -s -p "$prompt: " REPLY
  echo
}

confirm() {
  local prompt="${1:-계속 진행할까요?}" reply
  read -r -p "$prompt (y/n) [y]: " reply
  reply="${reply:-y}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# confirm과 동일하지만 기본값이 y가 아니라 n (민감정보 포함 등, 명시적 동의가 필요한 항목용)
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

gen_random_password() {
  # 대/소문자+숫자를 각각 포함하는 16자 랜덤 비밀번호 생성
  printf '%s%s%s%s' \
    "$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c 3)" \
    "$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 3)" \
    "$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c 3)" \
    "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 7)"
}

echo "=============================================================="
echo " MySQL 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
echo " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
echo "=============================================================="

# ---------- 0. 대상 레지스트리 주소 ----------
# 개발 PC: localhost:5000 / 팀서버(new-servicetech2-1, 192.168.0.168): servicetech2:5000
# (팀서버 접속 전 각 PC에서 사전 준비 필요 — hosts 등록 + insecure-registry 등록:
#  registry-server/linux-registry-setup.md 참고)
echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"

# ---------- 1. DB 종류 ----------
echo
echo "DB 종류를 선택하세요 (현재는 MySQL만 지원):"
echo "  1) MySQL"
ask "번호 선택" "1"
if [[ "$REPLY" != "1" ]]; then
  err "현재는 MySQL만 지원합니다."
  exit 1
fi
DB_KIND="mysql"

# ---------- 2. MySQL 버전(레지스트리 태그) ----------
echo
echo "배포할 MySQL 버전(레지스트리 태그)을 선택하세요:"
echo "  1) latest"
echo "  2) 8.4     (LTS)"
echo "  3) 8.0     (구버전 LTS, 레거시 호환용)"
echo "  4) 26.7.0  (latest가 가리키는 정확한 버전 고정, 2026-08-26 기준)"
ask "번호 선택" "1"
case "$REPLY" in
  1) TAG="latest" ;;
  2) TAG="8.4" ;;
  3) TAG="8.0" ;;
  4) TAG="26.7.0" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
REGISTRY_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${TAG}"

if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi
info "레지스트리 이미지를 내려받는 중입니다: $REGISTRY_IMAGE"
if ! docker pull "$REGISTRY_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 mysql/base/build-and-push.sh 로 '${TAG}' 태그를 등록하세요."
  exit 1
fi

DEPLOY_IMAGE="servicetech2/mysql-deploy:${TAG}"
info "배포용 이미지를 빌드합니다: $DEPLOY_IMAGE"
if ! docker build --build-arg "REGISTRY_IMAGE=${REGISTRY_IMAGE}" -t "$DEPLOY_IMAGE" -f Dockerfile .; then
  err "배포용 이미지 빌드 실패."
  exit 1
fi
ok "빌드 완료: $DEPLOY_IMAGE"

# ---------- 3. 컨테이너 이름 ----------
echo
ask "컨테이너 이름" "mysql-${TAG}-deploy"
CONTAINER_NAME="$REPLY"
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  warn "이미 '$CONTAINER_NAME' 이름의 컨테이너가 존재합니다."
  if confirm "기존 컨테이너를 삭제하고 새로 만들까요?"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
    ok "기존 컨테이너 삭제 완료"
  else
    err "컨테이너 이름 충돌로 중단합니다."
    exit 1
  fi
fi

# ---------- 4. DB 이름(스키마) ----------
echo
ask "최초 생성할 DB(스키마) 이름" "testdb"
DB_NAME="$REPLY"

# ---------- 5. 관리자(root) 계정 정보 ----------
echo
warn "root 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
ask_secret "root 초기 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
DB_PASSWORD="$REPLY"
GENERATED_PW=0
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD="$(gen_random_password)"
  GENERATED_PW=1
  ok "비밀번호를 입력하지 않아 랜덤 비밀번호를 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다. 파일에는 저장하지 않습니다)."
fi

# ---------- 6. 애플리케이션 계정 (root와 별도, 해당 DB에만 전체 권한) ----------
echo
info "root는 관리자 계정입니다. 애플리케이션에서 쓸 별도 계정을 만들고 싶다면 아래에서 생성하세요."
info "(MySQL 공식 이미지 기능으로 생성 — 별도 SQL 없이 지정한 DB에 자동으로 전체 권한 부여됨)"
APP_USER=""
APP_PASSWORD=""
APP_GENERATED_PW=0
if confirm "애플리케이션 계정을 생성할까요? (생성 시 '${DB_NAME}' DB에 전체 권한 부여)"; then
  ask "애플리케이션 계정 이름" "appuser"
  APP_USER="$REPLY"
  ask_secret "애플리케이션 계정 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
  APP_PASSWORD="$REPLY"
  if [[ -z "$APP_PASSWORD" ]]; then
    APP_PASSWORD="$(gen_random_password)"
    APP_GENERATED_PW=1
    ok "애플리케이션 계정 비밀번호를 자동 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다)."
  fi
fi

# ---------- 7. DDL / DML SQL 경로 ----------
echo
ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DDL_DIR="$REPLY"
ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DML_DIR="$REPLY"

STAGING_DIR="${SCRIPT_DIR}/.staging/${CONTAINER_NAME}/initdb"
SETUP_MOUNT=0
if [[ -n "$DDL_DIR" || -n "$DML_DIR" ]]; then
  rm -rf "${SCRIPT_DIR}/.staging/${CONTAINER_NAME}"
  mkdir -p "$STAGING_DIR"
  if [[ -n "$DDL_DIR" ]]; then
    if [[ -d "$DDL_DIR" ]]; then
      i=1
      for f in "$DDL_DIR"/*; do
        [[ -f "$f" ]] || continue
        cp "$f" "${STAGING_DIR}/10_$(printf '%03d' "$i")_$(basename "$f")"
        i=$((i + 1))
      done
      ok "DDL 파일 $((i - 1))개를 스테이징했습니다 (10_ 접두어, DDL이 DML보다 먼저 실행됨)"
    else
      warn "DDL 경로를 찾을 수 없습니다: $DDL_DIR (건너뜁니다)"
    fi
  fi
  if [[ -n "$DML_DIR" ]]; then
    if [[ -d "$DML_DIR" ]]; then
      i=1
      for f in "$DML_DIR"/*; do
        [[ -f "$f" ]] || continue
        cp "$f" "${STAGING_DIR}/50_$(printf '%03d' "$i")_$(basename "$f")"
        i=$((i + 1))
      done
      ok "DML 파일 $((i - 1))개를 스테이징했습니다 (50_ 접두어, DDL 이후 실행됨)"
    else
      warn "DML 경로를 찾을 수 없습니다: $DML_DIR (건너뜁니다)"
    fi
  fi
  SETUP_MOUNT=1
  warn "MySQL의 /docker-entrypoint-initdb.d/ 자동 실행은 데이터 볼륨이 비어있는 최초 기동 시에만 동작합니다 (이 프로젝트는 항상 휘발성이라 매번 최초 기동입니다)."
fi

# ---------- 8. 포트 ----------
echo
ask "포트" "3306"
LISTENER_PORT="$REPLY"
if port_in_use "$LISTENER_PORT"; then
  warn "포트 ${LISTENER_PORT}은(는) 이미 사용 중인 것으로 보입니다."
fi

# ---------- 8.5 실행 로그 파일 저장 여부 ----------
echo
LOG_FILE=""
if confirm_no "실행 요약/접속 정보를 로그 파일로 저장할까요? (생성된 비밀번호가 평문으로 포함됩니다)"; then
  mkdir -p "${SCRIPT_DIR}/logs"
  LOG_FILE="${SCRIPT_DIR}/logs/${CONTAINER_NAME}_$(date +%Y%m%d_%H%M%S).log"
  ok "로그 파일: ${LOG_FILE} (.gitignore에 등록되어 있어 커밋되지 않습니다)"
fi

# 화면 출력과 동시에, LOG_FILE이 설정된 경우 파일에도 그대로 남긴다.
log_tee() {
  if [[ -n "$LOG_FILE" ]]; then
    tee -a "$LOG_FILE"
  else
    cat
  fi
}

# ---------- 최종 확인 ----------
echo
{
echo "======================= 실행 요약 ======================="
echo " DB 종류       : $DB_KIND"
echo " 버전(태그)    : $TAG"
echo " 이미지        : $DEPLOY_IMAGE"
echo " 컨테이너 이름 : $CONTAINER_NAME"
echo " DB 이름       : $DB_NAME"
echo " 포트          : $LISTENER_PORT"
echo " ---------------------------------------------------------"
echo " [관리자] 계정 : root"
echo " [관리자] URL  : jdbc:mysql://localhost:${LISTENER_PORT}/${DB_NAME}?allowPublicKeyRetrieval=true&useSSL=false"
if [[ -n "$APP_USER" ]]; then
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : $APP_USER  (${DB_NAME} DB에 전체 권한)"
  echo " [앱]   URL    : jdbc:mysql://localhost:${LISTENER_PORT}/${DB_NAME}?allowPublicKeyRetrieval=true&useSSL=false"
else
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : (생성 안 함, root로만 접속)"
fi
echo " ---------------------------------------------------------"
echo " 접속 IP 제한  : 없음 (0.0.0.0 바인딩, MYSQL_USER는 '%'(모든 host)로 생성됨)"
echo " DDL 경로      : ${DDL_DIR:-(없음)}"
echo " DML 경로      : ${DML_DIR:-(없음)}"
echo " 데이터        : 휘발성(볼륨 미사용)"
[[ "$GENERATED_PW" -eq 1 ]] && echo " 생성된 비밀번호(root) : $DB_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
[[ "$APP_GENERATED_PW" -eq 1 ]] && echo " 생성된 비밀번호(${APP_USER}): $APP_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
} | log_tee
if ! confirm "위 설정으로 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ---------- docker run 구성 ----------
RUN_ARGS=(-d --name "$CONTAINER_NAME" -p "${LISTENER_PORT}:3306")
[[ "$SETUP_MOUNT" -eq 1 ]] && RUN_ARGS+=(-v "${STAGING_DIR}:/docker-entrypoint-initdb.d:ro")
RUN_ARGS+=(
  -e "MYSQL_ROOT_PASSWORD=${DB_PASSWORD}"
  -e "MYSQL_DATABASE=${DB_NAME}"
  -e "TZ=Asia/Seoul"
)
if [[ -n "$APP_USER" ]]; then
  RUN_ARGS+=(
    -e "MYSQL_USER=${APP_USER}"
    -e "MYSQL_PASSWORD=${APP_PASSWORD}"
  )
fi

info "컨테이너를 실행합니다: $CONTAINER_NAME"
docker run "${RUN_ARGS[@]}" "$DEPLOY_IMAGE"

# ---------- 기동 대기 ----------
info "DB 초기화를 기다리는 중입니다..."
ELAPSED=0; INTERVAL=5; TIMEOUT=300
while true; do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  if [[ "$STATUS" == "healthy" ]]; then
    ok "컨테이너가 정상 기동되었습니다."
    break
  fi
  if ! docker ps -q -f "name=^${CONTAINER_NAME}\$" | grep -q .; then
    err "컨테이너가 중단되었습니다. 로그를 확인하세요:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -60
    exit 1
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    warn "제한 시간 내에 healthy 상태가 되지 않았습니다. 'docker logs -f ${CONTAINER_NAME}'로 직접 확인하세요."
    break
  fi
  sleep "$INTERVAL"; ELAPSED=$((ELAPSED + INTERVAL)); printf "."
done
echo

# ---------- 접속 정보 ----------
echo
{
echo "======================= 접속 정보 ======================="
echo " (JDBC URL의 allowPublicKeyRetrieval/useSSL 옵션: MySQL 8+ 기본 인증방식(caching_sha2_password)이"
echo "  SSL 없는 연결에서 RSA 공개키 교환을 요구하는데, DBeaver 등 JDBC 클라이언트는 보안상 이를 기본"
echo "  차단합니다. 테스트 환경이라 이 옵션으로 명시 허용 — 운영 환경에서는 SSL을 구성하세요.)"
echo " DB 종류    : $DB_KIND"
echo " 버전(태그) : $TAG"
echo " Host       : localhost"
echo " Port       : $LISTENER_PORT"
echo " -------------------------- [관리자] --------------------------"
echo " Database   : $DB_NAME"
echo " Username   : root"
echo " JDBC URL   : jdbc:mysql://localhost:${LISTENER_PORT}/${DB_NAME}?allowPublicKeyRetrieval=true&useSSL=false"
echo " JDBC 옵션값: allowPublicKeyRetrieval=true, useSSL=false (위 URL에 이미 포함됨)"
echo " 드라이버 옵션(DBeaver 등 GUI 툴, URL 대신 직접 접속 시): Driver properties 탭에서"
echo "   allowPublicKeyRetrieval = true"
echo "   useSSL                 = false"
if [[ "$GENERATED_PW" -eq 1 ]]; then
  echo " 접속 예시  : mysql -h 127.0.0.1 -P ${LISTENER_PORT} -u root -p${DB_PASSWORD} ${DB_NAME}"
else
  echo " 접속 예시  : mysql -h 127.0.0.1 -P ${LISTENER_PORT} -u root -p<입력한 비밀번호> ${DB_NAME}"
fi
if [[ -n "$APP_USER" ]]; then
  echo " ---------------------------- [앱] -----------------------------"
  echo " 계정       : $APP_USER  (${DB_NAME} DB에 전체 권한)"
  echo " JDBC URL   : jdbc:mysql://localhost:${LISTENER_PORT}/${DB_NAME}?allowPublicKeyRetrieval=true&useSSL=false"
  echo " JDBC 옵션값: allowPublicKeyRetrieval=true, useSSL=false (위 URL에 이미 포함됨)"
  echo " 드라이버 옵션(DBeaver 등 GUI 툴, URL 대신 직접 접속 시): Driver properties 탭에서"
  echo "   allowPublicKeyRetrieval = true"
  echo "   useSSL                 = false"
  if [[ "$APP_GENERATED_PW" -eq 1 ]]; then
    echo " 접속 예시  : mysql -h 127.0.0.1 -P ${LISTENER_PORT} -u ${APP_USER} -p${APP_PASSWORD} ${DB_NAME}"
  else
    echo " 접속 예시  : mysql -h 127.0.0.1 -P ${LISTENER_PORT} -u ${APP_USER} -p<입력한 비밀번호> ${DB_NAME}"
  fi
fi
echo "==========================================================="
} | log_tee
if [[ -n "$LOG_FILE" ]]; then
  warn "비밀번호가 포함된 로그 파일이 남아있습니다: ${LOG_FILE} (필요 없어지면 직접 삭제하세요)"
else
  warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
fi
unset DB_PASSWORD APP_PASSWORD
