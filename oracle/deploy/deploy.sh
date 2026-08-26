#!/usr/bin/env bash
# ============================================================================
# Oracle 테스트 인스턴스 배포 스크립트 (bash) — servicetech2 레지스트리 기반
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh, oracle/base/build-and-push.sh
#            가 먼저 실행되어 servicetech2 레지스트리에 이미지가 등록되어 있어야 함
#
# 대화형으로 아래 항목을 입력받습니다:
#   1) DB 종류 (현재 Oracle 고정)   2) Oracle 버전(레지스트리 태그)
#   3) 스키마(SID/PDB)              4) 계정 정보(SYS/SYSTEM 비밀번호)
#   5) 애플리케이션 계정(선택)      6) DDL SQL 파일 경로
#   7) 초기데이터 DML SQL 파일 경로  8) 포트 (리스너)
#   9) 실행 로그 파일 저장 여부 (선택, 기본 n — 저장 시 비밀번호가 평문으로 파일에 남음)
#
# 접속 IP 제한: 이 프로젝트는 sqlnet.ora 등에 별도 Valid Node Checking/ACL을 추가하지
# 않으며, docker run -p 도 호스트IP 미지정(0.0.0.0 바인딩)이라 기본적으로 접속 IP
# 제한이 없습니다. Oracle 인증은 MySQL과 달리 계정이 특정 host에 종속되지 않습니다.
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
  # 대/소문자+숫자를 각각 포함하는 16자 랜덤 비밀번호 생성 (Oracle 복잡도 규칙 충족)
  printf '%s%s%s%s' \
    "$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c 3)" \
    "$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 3)" \
    "$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c 3)" \
    "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 7)"
}

echo "=============================================================="
echo " Oracle 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
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
echo "DB 종류를 선택하세요 (현재는 Oracle만 지원):"
echo "  1) Oracle"
ask "번호 선택" "1"
if [[ "$REPLY" != "1" ]]; then
  err "현재는 Oracle만 지원합니다."
  exit 1
fi
DB_KIND="oracle"

# ---------- 2. Oracle 버전(레지스트리 태그) ----------
echo
echo "배포할 Oracle 버전(레지스트리 태그)을 선택하세요:"
echo "  1) 19c  (Enterprise Edition — SID 임의 지정 가능)"
echo "  2) 21c-xe  (Express Edition — SID 고정(XE))"
echo "  3) 18c-xe  (Express Edition — SID 고정(XE))"
ask "번호 선택" "1"
case "$REPLY" in
  1) TAG="19c"; IS_EE=1 ;;
  2) TAG="21c-xe"; IS_EE=0 ;;
  3) TAG="18c-xe"; IS_EE=0 ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
REGISTRY_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${TAG}"

if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi
info "레지스트리 이미지를 내려받는 중입니다: $REGISTRY_IMAGE"
if ! docker pull "$REGISTRY_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 oracle/base/build-and-push.sh 로 '${TAG}' 태그를 등록하세요."
  exit 1
fi

DEPLOY_IMAGE="servicetech2/oracle-deploy:${TAG}"
info "배포용 이미지를 빌드합니다: $DEPLOY_IMAGE"
if ! docker build --build-arg "REGISTRY_IMAGE=${REGISTRY_IMAGE}" -t "$DEPLOY_IMAGE" -f Dockerfile .; then
  err "배포용 이미지 빌드 실패."
  exit 1
fi
ok "빌드 완료: $DEPLOY_IMAGE"

# ---------- 3. 컨테이너 이름 ----------
echo
ask "컨테이너 이름" "oracle-${TAG}-deploy"
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

# ---------- 4. 스키마(SID/PDB) ----------
echo
if [[ "$IS_EE" -eq 1 ]]; then
  ask "SID (인스턴스 식별자)" "VERIFIER"
  ORACLE_SID_VAL="$REPLY"
  ask "PDB(Pluggable DB) 이름" "${ORACLE_SID_VAL}PDB"
  ORACLE_PDB_VAL="$REPLY"
  SERVICE_NAME="$ORACLE_PDB_VAL"
else
  warn "Express Edition은 SID가 항상 'XE'로 고정됩니다 (제품 제약)."
  ask "추가 PDB 서비스 이름 (기본 XEPDB1 외 추가 생성, 비우면 생성 안 함)" ""
  ORACLE_DATABASE_VAL="$REPLY"
  SERVICE_NAME="${ORACLE_DATABASE_VAL:-XEPDB1}"
fi
ask "문자셋 (한글 지원: AL32UTF8 권장)" "AL32UTF8"
CHARSET="$REPLY"

# ---------- 5. 계정 정보 ----------
echo
warn "SYS/SYSTEM 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
ask_secret "SYS/SYSTEM 초기 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
DB_PASSWORD="$REPLY"
GENERATED_PW=0
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD="$(gen_random_password)"
  GENERATED_PW=1
  ok "비밀번호를 입력하지 않아 랜덤 비밀번호를 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다. 파일에는 저장하지 않습니다)."
elif [[ ${#DB_PASSWORD} -lt 8 ]]; then
  warn "8자 미만입니다. Oracle 권장 규칙(8자 이상, 대/소문자+숫자 포함)을 벗어나면 생성 중 경고가 뜨지만 보통 생성은 계속 진행됩니다."
fi

# ---------- 5.5 애플리케이션 계정 (SID/PDB 접근용, SYS/SYSTEM과 별도) ----------
echo
info "SYS/SYSTEM은 관리자 계정입니다. 애플리케이션에서 쓸 별도 계정을 만들고 싶다면 아래에서 생성하세요."
APP_USER=""
APP_PASSWORD=""
APP_GENERATED_PW=0
APP_CONNECT_MODE="service"
APP_CONNECT_DB=""
APP_CONNECT_LABEL=""
if confirm "애플리케이션 계정을 생성할까요? (생성 시 ALL PRIVILEGES 부여)"; then
  ask "애플리케이션 계정 이름" "APPUSER"
  APP_USER="$REPLY"
  ask_secret "애플리케이션 계정 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
  APP_PASSWORD="$REPLY"
  if [[ -z "$APP_PASSWORD" ]]; then
    APP_PASSWORD="$(gen_random_password)"
    APP_GENERATED_PW=1
    ok "애플리케이션 계정 비밀번호를 자동 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다)."
  fi

  echo
  echo "접속 방식을 선택하세요:"
  echo "  1) Service Name (PDB 안에 생성, 권장 — DBeaver 'Service Name'으로 접속)"
  echo "  2) SID (CDB 루트에 생성 — DBeaver 'SID'로 접속, PDB 격리 없이 루트 컨테이너에 직접 생성)"
  ask "번호 선택" "1"
  if [[ "$REPLY" == "2" ]]; then
    APP_CONNECT_MODE="sid"
    APP_CONNECT_DB="$([[ "$IS_EE" -eq 1 ]] && echo "$ORACLE_SID_VAL" || echo "XE")"
    APP_CONNECT_LABEL="SID"
  else
    APP_CONNECT_MODE="service"
    APP_CONNECT_DB="$SERVICE_NAME"
    APP_CONNECT_LABEL="Service Name"
  fi
fi

# ---------- 6. DDL / DML SQL 경로 ----------
echo
ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DDL_DIR="$REPLY"
ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DML_DIR="$REPLY"

STAGING_DIR="${SCRIPT_DIR}/.staging/${CONTAINER_NAME}/setup"
SETUP_MOUNT=0
if [[ -n "$APP_USER" || -n "$DDL_DIR" || -n "$DML_DIR" ]]; then
  rm -rf "${SCRIPT_DIR}/.staging/${CONTAINER_NAME}"
  mkdir -p "$STAGING_DIR"
  if [[ -n "$APP_USER" ]]; then
    if [[ "$APP_CONNECT_MODE" == "sid" ]]; then
      cat > "${STAGING_DIR}/01_create_app_user.sql" <<SQL
-- servicetech2 배포 스크립트 자동 생성 (테스트/개발 전용 — ALL PRIVILEGES는 운영 환경에 부적합)
-- SID 방식: CDB 루트에 직접 생성한다. 루트에서는 C## 접두어 없는 계정명이 기본적으로
-- 거부되므로(ORA-65096) "_ORACLE_SCRIPT"=true로 그 제약을 우회한다(컨테이너 스크립트 표준 기법).
-- 계정명은 따옴표 없이 생성 -- Oracle 기본 규칙대로 자동 대문자 변환되어, SYSTEM/SYS와 동일하게
-- 대소문자 구분 없이(DBeaver 등에서 따옴표 없이 입력해도) 접속 가능해진다.
ALTER SESSION SET "_ORACLE_SCRIPT"=true;
CREATE USER ${APP_USER} IDENTIFIED BY "${APP_PASSWORD}";
GRANT ALL PRIVILEGES TO ${APP_USER};
SQL
    else
      cat > "${STAGING_DIR}/01_create_app_user.sql" <<SQL
-- servicetech2 배포 스크립트 자동 생성 (테스트/개발 전용 — ALL PRIVILEGES는 운영 환경에 부적합)
-- Service Name 방식: 커스텀 setup 스크립트는 기본적으로 CDB 루트에서 실행되므로, PDB로
-- 컨테이너를 전환해야 C## 접두어 없는 일반 계정명을 만들 수 있다 (안 하면 ORA-65096).
-- 계정명은 따옴표 없이 생성 -- Oracle 기본 규칙대로 자동 대문자 변환되어, SYSTEM/SYS와 동일하게
-- 대소문자 구분 없이(DBeaver 등에서 따옴표 없이 입력해도) 접속 가능해진다.
ALTER SESSION SET CONTAINER = "${SERVICE_NAME}";
CREATE USER ${APP_USER} IDENTIFIED BY "${APP_PASSWORD}";
GRANT ALL PRIVILEGES TO ${APP_USER};
SQL
    fi
    ok "애플리케이션 계정 생성 SQL을 스테이징했습니다 (01_ 접두어, DDL/DML보다 먼저 실행됨, 접속 방식: ${APP_CONNECT_LABEL})"
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
fi

# ---------- 7. 포트 ----------
echo
ask "리스너 포트" "1521"
LISTENER_PORT="$REPLY"
if port_in_use "$LISTENER_PORT"; then
  warn "포트 ${LISTENER_PORT}은(는) 이미 사용 중인 것으로 보입니다."
fi

# ---------- 7.5 실행 로그 파일 저장 여부 ----------
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
if [[ "$IS_EE" -eq 1 ]]; then
  echo " SID / PDB     : $ORACLE_SID_VAL / $ORACLE_PDB_VAL"
else
  echo " 추가 PDB      : ${ORACLE_DATABASE_VAL:-(생성 안 함, 기본 XEPDB1만 사용)}"
fi
echo " 문자셋        : $CHARSET"
echo " 리스너 포트   : $LISTENER_PORT"
echo " ---------------------------------------------------------"
echo " [관리자] 계정 : SYSTEM  (SYS도 동일 비밀번호, Role=SYSDBA로 접속 시 사용)"
echo " [관리자] URL  : jdbc:oracle:thin:@localhost:${LISTENER_PORT}/${SERVICE_NAME}  (PDB 기준 고정)"
echo "               (DBeaver 'Database/Service Name' 필드에는 SID가 아니라 '${SERVICE_NAME}'을 입력)"
if [[ -n "$APP_USER" ]]; then
  if [[ "$APP_CONNECT_MODE" == "sid" ]]; then
    APP_JDBC_URL="jdbc:oracle:thin:@localhost:${LISTENER_PORT}:${APP_CONNECT_DB}"
  else
    APP_JDBC_URL="jdbc:oracle:thin:@localhost:${LISTENER_PORT}/${APP_CONNECT_DB}"
  fi
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : $APP_USER  (ALL PRIVILEGES)"
  echo " [앱]   접속방식: ${APP_CONNECT_LABEL} = ${APP_CONNECT_DB}"
  echo " [앱]   URL    : ${APP_JDBC_URL}"
else
  echo " ---------------------------------------------------------"
  echo " [앱]   계정   : (생성 안 함, SYSTEM으로만 접속)"
fi
echo " ---------------------------------------------------------"
echo " 접속 IP 제한  : 없음 (0.0.0.0 바인딩, Oracle 계정은 host에 종속되지 않음)"
echo " DDL 경로      : ${DDL_DIR:-(없음)}"
echo " DML 경로      : ${DML_DIR:-(없음)}"
echo " 데이터        : 휘발성(볼륨 미사용)"
[[ "$GENERATED_PW" -eq 1 ]] && echo " 생성된 비밀번호(SYSTEM) : $DB_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
[[ "$APP_GENERATED_PW" -eq 1 ]] && echo " 생성된 비밀번호(${APP_USER}): $APP_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
} | log_tee
if ! confirm "위 설정으로 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ---------- docker run 구성 ----------
RUN_ARGS=(-d --name "$CONTAINER_NAME" -p "${LISTENER_PORT}:1521" --shm-size=1g)
if [[ "$SETUP_MOUNT" -eq 1 ]]; then
  if [[ "$IS_EE" -eq 1 ]]; then
    # 공식 Oracle EE 이미지(oracle/docker-images) 관례: /opt/oracle/scripts/setup
    RUN_ARGS+=(-v "${STAGING_DIR}:/opt/oracle/scripts/setup:ro")
  else
    # gvenzl/oracle-xe 커뮤니티 이미지는 EE와 다른 관례를 쓴다: /container-entrypoint-initdb.d
    # (실제 컨테이너 안 container-entrypoint.sh 코드로 확인함 — 2026-08-26. EE 경로를 그대로
    #  쓰면 마운트는 되지만 이미지가 그 디렉토리를 전혀 스캔하지 않아 SQL이 조용히 실행 안 됨)
    RUN_ARGS+=(-v "${STAGING_DIR}:/container-entrypoint-initdb.d:ro")
  fi
fi

if [[ "$IS_EE" -eq 1 ]]; then
  RUN_ARGS+=(
    -e "ORACLE_SID=${ORACLE_SID_VAL}"
    -e "ORACLE_PDB=${ORACLE_PDB_VAL}"
    -e "ORACLE_PWD=${DB_PASSWORD}"
    -e "ORACLE_CHARACTERSET=${CHARSET}"
  )
else
  RUN_ARGS+=(
    -e "ORACLE_PASSWORD=${DB_PASSWORD}"
    -e "ORACLE_CHARACTERSET=${CHARSET}"
  )
  [[ -n "${ORACLE_DATABASE_VAL:-}" ]] && RUN_ARGS+=(-e "ORACLE_DATABASE=${ORACLE_DATABASE_VAL}")
fi

info "컨테이너를 실행합니다: $CONTAINER_NAME"
docker run "${RUN_ARGS[@]}" "$DEPLOY_IMAGE"

# ---------- 기동 대기 ----------
info "DB 초기화를 기다리는 중입니다 (에디션에 따라 2~20분 소요될 수 있습니다)..."
ELAPSED=0; INTERVAL=15; TIMEOUT=1800
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
echo " Service    : $SERVICE_NAME  (DBeaver 'Database/Service Name' 필드 — SID 아님, PDB 기준 고정)"
echo " Username   : SYSTEM  (SYS도 동일 비밀번호, 접속 시 Role=SYSDBA 필요)"
echo " JDBC URL   : jdbc:oracle:thin:@localhost:${LISTENER_PORT}/${SERVICE_NAME}"
if [[ "$GENERATED_PW" -eq 1 ]]; then
  echo " 접속 예시  : sqlplus system/${DB_PASSWORD}@localhost:${LISTENER_PORT}/${SERVICE_NAME}"
else
  echo " 접속 예시  : sqlplus system/<입력한 비밀번호>@localhost:${LISTENER_PORT}/${SERVICE_NAME}"
fi
if [[ -n "$APP_USER" ]]; then
  if [[ "$APP_CONNECT_MODE" == "sid" ]]; then
    APP_JDBC_URL="jdbc:oracle:thin:@localhost:${LISTENER_PORT}:${APP_CONNECT_DB}"
  else
    APP_JDBC_URL="jdbc:oracle:thin:@localhost:${LISTENER_PORT}/${APP_CONNECT_DB}"
  fi
  echo " ---------------------------- [앱] -----------------------------"
  echo " 계정       : $APP_USER  (ALL PRIVILEGES)"
  echo " DBeaver    : Connection Type = ${APP_CONNECT_LABEL}, Database = ${APP_CONNECT_DB}"
  echo " JDBC URL   : ${APP_JDBC_URL}"
  if [[ "$APP_GENERATED_PW" -eq 1 ]]; then
    echo " 접속 예시  : sqlplus ${APP_USER}/${APP_PASSWORD}@localhost:${LISTENER_PORT}/${APP_CONNECT_DB}"
  else
    echo " 접속 예시  : sqlplus ${APP_USER}/<입력한 비밀번호>@localhost:${LISTENER_PORT}/${APP_CONNECT_DB}"
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
