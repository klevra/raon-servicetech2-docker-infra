#!/usr/bin/env bash
# ============================================================================
# CUBRID 테스트 인스턴스 배포 스크립트 (bash) — servicetech2 레지스트리 기반
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh, cubrid/base/build-and-push.sh
#            가 먼저 실행되어 servicetech2 레지스트리에 이미지가 등록되어 있어야 함
#            (레지스트리 자체는 DB 종류와 무관하게 공용으로 사용)
#
# 대화형으로 아래 항목을 입력받습니다:
#   1) DB 종류 (현재 CUBRID 고정)    2) CUBRID 버전(레지스트리 태그)
#   3) 컨테이너 이름                 4) DB 이름
#   5) 애플리케이션 계정(선택)       6) 포트 (브로커)
#   7) 실행 로그 파일 저장 여부 (선택, 기본 n)
#
# *** 중요: --privileged 필요 ***
# CUBRID 공식 이미지는 11.4부터 시스템 파라미터를 설정하려면 --privileged
# 옵션이 필수라고 공식 문서화되어 있다. 이 프로젝트의 다른 DB(오라클/마리아DB/
# MySQL/PostgreSQL)는 전부 일반 권한 컨테이너로 돌아가지만, CUBRID만 호스트에
# 대한 접근 권한이 훨씬 넓은 privileged 모드로 띄워야 한다. 이 스크립트는
# 항상 --privileged를 붙여서 실행하며, 실행 전 요약 화면에서 다시 한번 경고한다.
#
# *** 관리자(dba) 계정: 비밀번호 없음 ***
# CUBRID 공식 이미지에는 dba 비밀번호를 설정하는 환경변수가 없다. dba 계정은
# CUBRID 자체의 기본 동작대로 비밀번호 없이 생성된다 (이 프로젝트가 임의로
# 만든 제약이 아니라 이미지 자체의 사양). 운영 환경에서는 절대 이대로 쓰면
# 안 되며, 이 프로젝트가 테스트/개발/데모 전용인 이유 중 하나다.
#
# *** DDL/DML 자동 실행 미지원 ***
# CUBRID 공식 이미지는 MariaDB/MySQL/PostgreSQL의 /docker-entrypoint-initdb.d/
# 같은 초기화 SQL 자동 실행 규칙이 없다. 그래서 이 스크립트는 DDL/DML 파일
# 주입 기능을 제공하지 않는다 (다른 DB 스크립트와의 의도적인 차이점).
#
# 접속 IP 제한: 이 프로젝트는 별도 bind-address 제약이나 방화벽 규칙을 추가하지
# 않으며, docker run -p 도 호스트IP 미지정(0.0.0.0 바인딩)이라 기본적으로 접속 IP
# 제한이 없습니다.
#
# 데이터는 휘발성(볼륨 미사용)입니다. 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

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
echo " CUBRID 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
echo " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
echo " *** --privileged 컨테이너로 실행됩니다 (CUBRID 공식 요구사항) ***"
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
echo "DB 종류를 선택하세요 (현재는 CUBRID만 지원):"
echo "  1) CUBRID"
ask "번호 선택" "1"
if [[ "$REPLY" != "1" ]]; then
  err "현재는 CUBRID만 지원합니다."
  exit 1
fi
DB_KIND="cubrid"

# ---------- 2. CUBRID 버전(레지스트리 태그) ----------
echo
echo "배포할 CUBRID 버전(레지스트리 태그)을 선택하세요:"
echo "  1) latest"
echo "  2) 11.4"
echo "  3) 11.3    (구버전)"
echo "  4) 11.4.5  (latest가 가리키는 정확한 버전 고정, 2026-08-26 기준)"
ask "번호 선택" "1"
case "$REPLY" in
  1) TAG="latest" ;;
  2) TAG="11.4" ;;
  3) TAG="11.3" ;;
  4) TAG="11.4.5" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
REGISTRY_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${TAG}"

if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi
info "레지스트리 이미지를 내려받는 중입니다: $REGISTRY_IMAGE"
if ! docker pull "$REGISTRY_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 cubrid/base/build-and-push.sh 로 '${TAG}' 태그를 등록하세요."
  exit 1
fi

# 예전에는 여기서 HEALTHCHECK만 추가한 "배포용" 이미지를 별도로 docker build 했었다.
# docker run --health-cmd 등으로 헬스체크를 런타임에 지정할 수 있어(빌드 없이 동일 효과),
# base 이미지를 그대로 실행한다 -- 로컬에 이미지가 DB당 1개만 남는다 (2026-08-26 정리).
DEPLOY_IMAGE="$REGISTRY_IMAGE"

# ---------- 3. 컨테이너 이름 ----------
echo
ask "컨테이너 이름" "cubrid-${TAG}-deploy"
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

# ---------- 4. DB 이름 ----------
echo
ask "최초 생성할 DB 이름" "testdb"
DB_NAME="$REPLY"

# ---------- 5. 애플리케이션 계정 (선택, CUBRID_USER/CUBRID_PASSWORD 공식 기능) ----------
echo
info "dba는 관리자 계정이며 비밀번호가 없습니다(CUBRID 기본 동작). 애플리케이션에서 쓸 별도 계정을 만들고 싶다면 아래에서 생성하세요."
info "(CUBRID 공식 이미지 기능으로 생성 — 로그인은 대소문자를 구분하지 않습니다)"
APP_USER=""
APP_PASSWORD=""
APP_GENERATED_PW=0
if confirm "애플리케이션 계정을 생성할까요?"; then
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

# ---------- 6. 포트 (브로커) ----------
echo
ask "포트" "33000"
LISTENER_PORT="$REPLY"
if port_in_use "$LISTENER_PORT"; then
  warn "포트 ${LISTENER_PORT}은(는) 이미 사용 중인 것으로 보입니다."
fi

# ---------- 6.5 실행 로그 파일 저장 여부 ----------
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
echo " *** --privileged 컨테이너로 실행됩니다 (호스트 접근 권한 확대, CUBRID 공식 요구사항) ***"
echo " ---------------------------------------------------------"
echo " [관리자] 계정 : dba (비밀번호 없음 — CUBRID 기본 동작, 테스트 전용이므로 허용)"
if [[ -n "$APP_USER" ]]; then
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : $APP_USER"
else
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : (생성 안 함, dba로만 접속)"
fi
echo " ---------------------------------------------------------"
echo " 접속 IP 제한  : 없음 (0.0.0.0 바인딩)"
echo " DDL/DML       : 미지원 (CUBRID 공식 이미지에 초기화 SQL 자동 실행 규칙 없음)"
echo " 데이터        : 휘발성(볼륨 미사용)"
[[ "$APP_GENERATED_PW" -eq 1 ]] && echo " 생성된 비밀번호(${APP_USER}): $APP_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
} | log_tee
if ! confirm "위 설정으로 컨테이너를 생성할까요? (--privileged 포함)"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ---------- docker run 구성 ----------
RUN_ARGS=(-d --name "$CONTAINER_NAME" --privileged -p "${LISTENER_PORT}:33000")
# 예전 deploy/Dockerfile의 HEALTHCHECK를 그대로 옮긴 것 -- 별도 이미지 빌드 없이 동일하게 동작
RUN_ARGS+=(
  --health-cmd='gosu cubrid csql -u dba $CUBRID_DB -c "SELECT 1;" >/dev/null 2>&1 || exit 1'
  --health-interval=5s --health-timeout=5s --health-start-period=60s --health-retries=15
)
RUN_ARGS+=(
  -e "CUBRID_DB=${DB_NAME}"
  -e "TZ=Asia/Seoul"
)
if [[ -n "$APP_USER" ]]; then
  RUN_ARGS+=(
    -e "CUBRID_USER=${APP_USER}"
    -e "CUBRID_PASSWORD=${APP_PASSWORD}"
  )
fi

info "컨테이너를 실행합니다: $CONTAINER_NAME"
docker run "${RUN_ARGS[@]}" "$DEPLOY_IMAGE"

# ---------- 기동 대기 ----------
info "DB 초기화를 기다리는 중입니다 (CUBRID는 최초 기동 시 DB 볼륨을 새로 생성해 다른 DB보다 오래 걸릴 수 있습니다)..."
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
echo " DB 종류    : $DB_KIND"
echo " 버전(태그) : $TAG"
echo " Host       : localhost"
echo " Port       : $LISTENER_PORT"
echo " -------------------------- [관리자] --------------------------"
echo " Database   : $DB_NAME"
echo " Username   : dba"
echo " JDBC URL   : jdbc:cubrid:localhost:${LISTENER_PORT}:${DB_NAME}:::"
echo " 접속 예시  : docker exec -it ${CONTAINER_NAME} gosu cubrid csql -u dba ${DB_NAME}"
echo " (비밀번호 없음 — csql에 -p 옵션을 주지 않고 그대로 접속)"
if [[ -n "$APP_USER" ]]; then
  echo " ---------------------------- [앱] -----------------------------"
  echo " 계정       : $APP_USER"
  echo " JDBC URL   : jdbc:cubrid:localhost:${LISTENER_PORT}:${DB_NAME}:::"
  if [[ "$APP_GENERATED_PW" -eq 1 ]]; then
    echo " 접속 예시  : docker exec -it ${CONTAINER_NAME} gosu cubrid csql -u ${APP_USER} -p ${APP_PASSWORD} ${DB_NAME}"
  else
    echo " 접속 예시  : docker exec -it ${CONTAINER_NAME} gosu cubrid csql -u ${APP_USER} -p <입력한 비밀번호> ${DB_NAME}"
  fi
fi
echo "==========================================================="
echo " 참고: CUBRID CLI(csql)는 호스트 PC에 별도 설치가 필요해, 위 예시는"
echo "       docker exec로 컨테이너 안에서 직접 접속하는 방법입니다."
echo "       외부 애플리케이션은 JDBC 드라이버로 위 JDBC URL을 사용하면 됩니다."
} | log_tee
if [[ -n "$LOG_FILE" ]]; then
  warn "비밀번호가 포함된 로그 파일이 남아있습니다: ${LOG_FILE} (필요 없어지면 직접 삭제하세요)"
else
  warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
fi
unset APP_PASSWORD
