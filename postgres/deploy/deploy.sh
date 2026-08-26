#!/usr/bin/env bash
# ============================================================================
# PostgreSQL 테스트 인스턴스 배포 스크립트 (bash) — servicetech2 레지스트리 기반
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh, postgres/base/build-and-push.sh
#            가 먼저 실행되어 servicetech2 레지스트리에 이미지가 등록되어 있어야 함
#            (레지스트리 자체는 DB 종류와 무관하게 공용으로 사용)
#
# 대화형으로 아래 항목을 입력받습니다:
#   1) DB 종류 (현재 PostgreSQL 고정)  2) PostgreSQL 버전(레지스트리 태그)
#   3) 컨테이너 이름                   4) DB 이름
#   5) 관리자(postgres) 비밀번호       6) 애플리케이션 계정(선택)
#   7) DDL SQL 파일 경로               8) 초기데이터 DML SQL 파일 경로
#   9) 포트 (리스너)                   10) 실행 로그 파일 저장 여부 (선택, 기본 n)
#
# 접속 IP 제한: 이 프로젝트는 별도 bind-address 제약이나 방화벽 규칙을 추가하지
# 않으며, docker run -p 도 호스트IP 미지정(0.0.0.0 바인딩)이라 기본적으로 접속 IP
# 제한이 없습니다.
#
# 애플리케이션 계정: PostgreSQL 공식 이미지는 MariaDB/MySQL의 *_USER 같은
# "보조 계정 자동 생성" 기능이 없다. 그래서 이 스크립트는 CREATE USER/GRANT
# SQL을 직접 생성해 /docker-entrypoint-initdb.d/에 05_ 접두어로 주입한다
# (DDL 10_, DML 50_ 보다 먼저 실행되어야 이후 생성되는 테이블에도 기본 권한이
# 적용됨 — ALTER DEFAULT PRIVILEGES 사용).
# 계정 이름은 항상 소문자로 강제 변환한다: PostgreSQL은 CREATE USER 시 따옴표
# 없이 쓰면 소문자로 접힌 이름이 실제 저장되는데, 접속(인증) 파라미터는 이 접힘이
# 전혀 적용되지 않는 별도 경로라서, 대문자를 섞어 입력하면 "생성된 이름"과
# "접속 시 입력해야 하는 이름"이 달라져 로그인이 실패한다 (Oracle 대소문자
# 버그와는 반대 방향의 함정). 처음부터 소문자로 통일해 이 문제를 원천 차단한다.
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
echo " PostgreSQL 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
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
echo "DB 종류를 선택하세요 (현재는 PostgreSQL만 지원):"
echo "  1) PostgreSQL"
ask "번호 선택" "1"
if [[ "$REPLY" != "1" ]]; then
  err "현재는 PostgreSQL만 지원합니다."
  exit 1
fi
DB_KIND="postgres"

# ---------- 2. PostgreSQL 버전(레지스트리 태그) ----------
echo
echo "배포할 PostgreSQL 버전(레지스트리 태그)을 선택하세요:"
echo "  1) latest"
echo "  2) 16"
echo "  3) 15    (구버전, 레거시 호환용)"
echo "  4) 18.6  (latest가 가리키는 정확한 버전 고정, 2026-08-26 기준)"
ask "번호 선택" "1"
case "$REPLY" in
  1) TAG="latest" ;;
  2) TAG="16" ;;
  3) TAG="15" ;;
  4) TAG="18.6" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
REGISTRY_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${TAG}"

if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi
info "레지스트리 이미지를 내려받는 중입니다: $REGISTRY_IMAGE"
if ! docker pull "$REGISTRY_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 postgres/base/build-and-push.sh 로 '${TAG}' 태그를 등록하세요."
  exit 1
fi

# 예전에는 여기서 HEALTHCHECK만 추가한 "배포용" 이미지를 별도로 docker build 했었다.
# docker run --health-cmd 등으로 헬스체크를 런타임에 지정할 수 있어(빌드 없이 동일 효과),
# base 이미지를 그대로 실행한다 -- 로컬에 이미지가 DB당 1개만 남는다 (2026-08-26 정리).
DEPLOY_IMAGE="$REGISTRY_IMAGE"

# ---------- 3. 컨테이너 이름 ----------
echo
ask "컨테이너 이름" "postgres-${TAG}-deploy"
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

# ---------- 5. 관리자(postgres) 계정 정보 ----------
echo
warn "postgres 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
ask_secret "postgres 초기 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
DB_PASSWORD="$REPLY"
GENERATED_PW=0
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD="$(gen_random_password)"
  GENERATED_PW=1
  ok "비밀번호를 입력하지 않아 랜덤 비밀번호를 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다. 파일에는 저장하지 않습니다)."
fi

# ---------- 6. 애플리케이션 계정 (postgres와 별도, 해당 DB에만 전체 권한) ----------
echo
info "postgres는 관리자(슈퍼유저) 계정입니다. 애플리케이션에서 쓸 별도 계정을 만들고 싶다면 아래에서 생성하세요."
info "(PostgreSQL 공식 이미지에는 보조 계정 자동 생성 기능이 없어, CREATE USER/GRANT SQL을 자동 생성해 주입합니다)"
APP_USER=""
APP_PASSWORD=""
APP_GENERATED_PW=0
if confirm "애플리케이션 계정을 생성할까요? (생성 시 '${DB_NAME}' DB에 전체 권한 부여)"; then
  ask "애플리케이션 계정 이름" "appuser"
  # PostgreSQL 대소문자 함정 방지: 항상 소문자로 통일 (스크립트 상단 설명 참고)
  APP_USER="$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')"
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
if [[ -n "$APP_USER" || -n "$DDL_DIR" || -n "$DML_DIR" ]]; then
  rm -rf "${SCRIPT_DIR}/.staging/${CONTAINER_NAME}"
  mkdir -p "$STAGING_DIR"

  if [[ -n "$APP_USER" ]]; then
    cat > "${STAGING_DIR}/05_app_account.sql" <<EOF
CREATE USER "${APP_USER}" WITH PASSWORD '${APP_PASSWORD}';
GRANT ALL PRIVILEGES ON DATABASE "${DB_NAME}" TO "${APP_USER}";
GRANT ALL ON SCHEMA public TO "${APP_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "${APP_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "${APP_USER}";
EOF
    ok "애플리케이션 계정 생성 SQL을 스테이징했습니다 (05_ 접두어, DDL보다 먼저 실행됨)"
  fi
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
  warn "PostgreSQL의 /docker-entrypoint-initdb.d/ 자동 실행은 데이터 볼륨이 비어있는 최초 기동 시에만 동작합니다 (이 프로젝트는 항상 휘발성이라 매번 최초 기동입니다)."
fi

# ---------- 8. 포트 ----------
echo
ask "포트" "5432"
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
echo " [관리자] 계정 : postgres"
echo " [관리자] URL  : jdbc:postgresql://localhost:${LISTENER_PORT}/${DB_NAME}"
if [[ -n "$APP_USER" ]]; then
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : $APP_USER  (${DB_NAME} DB에 전체 권한)"
  echo " [앱]   URL    : jdbc:postgresql://localhost:${LISTENER_PORT}/${DB_NAME}"
else
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : (생성 안 함, postgres로만 접속)"
fi
echo " ---------------------------------------------------------"
echo " 접속 IP 제한  : 없음 (0.0.0.0 바인딩)"
echo " DDL 경로      : ${DDL_DIR:-(없음)}"
echo " DML 경로      : ${DML_DIR:-(없음)}"
echo " 데이터        : 휘발성(볼륨 미사용)"
[[ "$GENERATED_PW" -eq 1 ]] && echo " 생성된 비밀번호(postgres) : $DB_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
[[ "$APP_GENERATED_PW" -eq 1 ]] && echo " 생성된 비밀번호(${APP_USER}): $APP_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
} | log_tee
if ! confirm "위 설정으로 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ---------- docker run 구성 ----------
RUN_ARGS=(-d --name "$CONTAINER_NAME" -p "${LISTENER_PORT}:5432")
[[ "$SETUP_MOUNT" -eq 1 ]] && RUN_ARGS+=(-v "${STAGING_DIR}:/docker-entrypoint-initdb.d:ro")
# 예전 deploy/Dockerfile의 HEALTHCHECK를 그대로 옮긴 것 -- 별도 이미지 빌드 없이 동일하게 동작
RUN_ARGS+=(
  --health-cmd='pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1'
  --health-interval=5s --health-timeout=5s --health-start-period=30s --health-retries=10
)
RUN_ARGS+=(
  -e "POSTGRES_USER=postgres"
  -e "POSTGRES_PASSWORD=${DB_PASSWORD}"
  -e "POSTGRES_DB=${DB_NAME}"
  -e "TZ=Asia/Seoul"
)

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
echo " DB 종류    : $DB_KIND"
echo " 버전(태그) : $TAG"
echo " Host       : localhost"
echo " Port       : $LISTENER_PORT"
echo " -------------------------- [관리자] --------------------------"
echo " Database   : $DB_NAME"
echo " Username   : postgres"
echo " JDBC URL   : jdbc:postgresql://localhost:${LISTENER_PORT}/${DB_NAME}"
if [[ "$GENERATED_PW" -eq 1 ]]; then
  echo " 접속 예시  : PGPASSWORD=${DB_PASSWORD} psql -h 127.0.0.1 -p ${LISTENER_PORT} -U postgres -d ${DB_NAME}"
else
  echo " 접속 예시  : PGPASSWORD=<입력한 비밀번호> psql -h 127.0.0.1 -p ${LISTENER_PORT} -U postgres -d ${DB_NAME}"
fi
if [[ -n "$APP_USER" ]]; then
  echo " ---------------------------- [앱] -----------------------------"
  echo " 계정       : $APP_USER  (${DB_NAME} DB에 전체 권한)"
  echo " JDBC URL   : jdbc:postgresql://localhost:${LISTENER_PORT}/${DB_NAME}"
  if [[ "$APP_GENERATED_PW" -eq 1 ]]; then
    echo " 접속 예시  : PGPASSWORD=${APP_PASSWORD} psql -h 127.0.0.1 -p ${LISTENER_PORT} -U ${APP_USER} -d ${DB_NAME}"
  else
    echo " 접속 예시  : PGPASSWORD=<입력한 비밀번호> psql -h 127.0.0.1 -p ${LISTENER_PORT} -U ${APP_USER} -d ${DB_NAME}"
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
