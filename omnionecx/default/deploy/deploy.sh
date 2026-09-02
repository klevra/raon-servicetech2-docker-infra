#!/usr/bin/env bash
# ============================================================================
# OmnioneCX v1 통합 배포 스크립트 (bash) — DB(공용 1개) + verifier + oacx
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh 로 레지스트리가 떠있어야 하고,
#            mariadb/base, jdk8/base, tomcat/base 의 build-and-push.sh 로
#            이미지가 레지스트리에 등록되어 있어야 함.
#
# 실행 순서 (요청하신 7단계 + 자동화 보강):
#   1) 설정값 일괄 수령 (DB/연결정보/앱 경로/운영·개발) + 공용 네트워크 생성
#   2) DB 컨테이너 생성
#   3) DB에 DDL/DML 적용 (verifier + oacx 스키마를 "하나의 DB"에 함께 적재.
#      실제 운영 구성과 동일 — verifier/oacx 모두 기본 DB명이 VC_VERIFIER로 통일되어 있음)
#   4) verifier 설정값 세팅 (config는 sandbox 원본에 직접 패치, app은 원본 직접 마운트)
#   5) verifier 기동 (+ 정상 기동까지 대기)
#   6) oacx 설정값 세팅 (app은 스테이징, config는 sandbox 원본에 직접 패치 +
#      provider.json 6종의 base/partnerCode/publicKey/vc.curveType 자동 반영)
#      -- config는 컨테이너와 별개로 원본을 직접 마운트하므로, 값을 고친 뒤
#         컨테이너만 재시작해도(재배포 없이) 즉시 반영됨
#   7) oacx 기동 (+ 정상 기동까지 대기)
#
# 데이터는 휘발성(볼륨 미사용)입니다. 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

# 이 스크립트는 docker run -v(콜론 구분 마운트 문자열)를 직접 쓰지 않고 docker compose만
# 호출한다 -- compose는 볼륨을 YAML/env파일 값으로 다루기 때문에(셸 인자로 콜론 문자열이
# 전달되지 않음) MSYS의 POSIX->Windows 경로 자동 변환을 그대로 둬도 안전하며, 오히려
# --env-file/-f 같은 단일 경로 인자는 이 변환이 있어야 정상 동작한다(꺼두면 Windows
# 실행 파일이 POSIX 경로를 드라이브 상대경로로 잘못 해석해 "D:\d\..." 같은 경로가 됨).
# 그래서 다른 deploy.sh들과 달리 MSYS_NO_PATHCONV를 여기서는 설정하지 않는다.

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
echo " OmnioneCX v1 통합 배포 (DB 1개 + verifier + oacx)"
echo " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
echo "=============================================================="

# ============================================================================
# 1. 설정값 일괄 수령
# ============================================================================
echo
echo "########## 1단계: 설정값 일괄 수령 ##########"

echo
echo "이 배포가 어떤 환경을 대상으로 하는지 선택하세요:"
echo "  1) 개발 (기본값)"
echo "  2) 운영"
ask "번호 선택" "1"
case "$REPLY" in
  1) DEPLOY_ENV="개발"; OPER_SORT="dev"; DID_FILE_NAME="raondev2.sp.did" ;;
  2) DEPLOY_ENV="운영"; OPER_SORT="prod"; DID_FILE_NAME="raonEnt.did" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
if [[ "$DEPLOY_ENV" == "운영" ]]; then
  warn "이 스크립트는 데이터가 휘발성(볼륨 미사용)인 테스트/개발용 배포입니다."
  if ! confirm_no "정말로 '운영' 환경 대상으로 진행할까요? (권장하지 않음)"; then
    err "사용자가 취소했습니다."
    exit 1
  fi
fi

echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"
if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi

echo
ask "공용 네트워크 이름" "omnionecx-net"
NETWORK_NAME="$REPLY"

echo
echo "-------- config 설정값 업데이트 여부 --------"
info "verifier/oacx가 마운트할 config 안의 DB 접속정보(jdbc/datasource)를 이번 배포값으로 덮어쓸지 선택하세요."
info "('아니오'를 선택하면 config에 이미 들어있는 값을 그대로 사용하고, DB도 그 값에 맞춰 자동으로 생성합니다.)"
if confirm_no "DB 접속정보를 이번 배포값으로 업데이트할까요? (기본값 N = config의 값을 그대로 사용)"; then
  UPDATE_DB_CONFIG=1
else
  UPDATE_DB_CONFIG=0
fi

echo
DEFAULT_VERIFIER_ROOT="${SCRIPT_DIR}/verifier"
if [[ -d "$DEFAULT_VERIFIER_ROOT" ]]; then
  VERIFIER_ROOT="$DEFAULT_VERIFIER_ROOT"
  ok "verifier 폴더를 찾았습니다: $VERIFIER_ROOT (경로 입력 생략)"
else
  ask "verifier 설정 루트 경로 (app/, config/ 가 있는 위치)" "D:\\03. Docker\\sandbox\\verifier"
  VERIFIER_ROOT="$REPLY"
fi

echo
echo "-------- DB --------"
echo "DB 종류를 선택하세요 (현재는 MariaDB만 지원):"
echo "  1) MariaDB"
ask "번호 선택" "1"
[[ "$REPLY" != "1" ]] && { err "현재는 MariaDB만 지원합니다."; exit 1; }
DB_KIND="mariadb"

echo "배포할 MariaDB 버전(레지스트리 태그)을 선택하세요:"
echo "  1) latest"
echo "  2) 11.4   (LTS)"
echo "  3) 10.11  (구버전 LTS, 레거시 호환용)"
ask "번호 선택" "1"
case "$REPLY" in
  1) DB_TAG="latest" ;;
  2) DB_TAG="11.4" ;;
  3) DB_TAG="10.11" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
DB_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${DB_TAG}"

DS_SRC="${VERIFIER_ROOT}/config/config/application-datasource.properties"
if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
  ask "DB 컨테이너 이름" "db"
  DB_CONTAINER="$REPLY"
  ask "DB(스키마) 이름 (verifier/oacx가 하나의 DB를 공유 -- 실제 운영값과 동일하게 기본 VC_VERIFIER)" "VC_VERIFIER"
  DB_NAME="$REPLY"
  ask "공용 앱 계정 이름" "omnione"
  APP_USER="$REPLY"
  ask_secret "공용 앱 계정 비밀번호" "0mN1DB"
  APP_PASSWORD="$REPLY"
else
  if [[ ! -f "$DS_SRC" ]]; then
    err "DB 접속정보를 config에서 읽어와야 하는데 파일을 찾을 수 없습니다: $DS_SRC"
    exit 1
  fi
  DERIVED_URL="$(grep -oE 'spring\.datasource\.url=jdbc:mariadb://[^[:space:]]+' "$DS_SRC" | head -n1)"
  DB_CONTAINER="$(sed -E 's#.*//([^:/]+).*#\1#' <<< "$DERIVED_URL")"
  DB_NAME="$(sed -E 's#.*/([^/?[:space:]]+)$#\1#' <<< "$DERIVED_URL")"
  APP_USER="$(grep -oE 'spring\.datasource\.hikari\.username=.*' "$DS_SRC" | head -n1 | sed -E 's/^[^=]*=//')"
  APP_PASSWORD="$(grep -oE 'spring\.datasource\.hikari\.password=.*' "$DS_SRC" | head -n1 | sed -E 's/^[^=]*=//')"
  if [[ -z "$DB_CONTAINER" || -z "$DB_NAME" || -z "$APP_USER" ]]; then
    err "config에서 DB 접속정보를 추출하지 못했습니다 ($DS_SRC 확인 필요)."
    exit 1
  fi
  ok "config에서 DB 접속정보를 그대로 가져왔습니다: host(컨테이너명)=${DB_CONTAINER}, db=${DB_NAME}, user=${APP_USER}"
fi
ask "DB 포트 (호스트에 노출할 포트, DBeaver 등 외부 툴 접속용)" "3306"
DB_PORT="$REPLY"

echo
warn "root 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
ask_secret "root 초기 비밀번호 (비우면 랜덤 생성)" ""
DB_ROOT_PASSWORD="$REPLY"
GENERATED_PW=0
if [[ -z "$DB_ROOT_PASSWORD" ]]; then
  DB_ROOT_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  GENERATED_PW=1
fi

echo
echo "-------- DDL/DML (verifier + oacx 통합 경로) --------"
DEFAULT_DDL_DIR="${SCRIPT_DIR}/ddl"
if [[ -d "$DEFAULT_DDL_DIR" ]]; then
  DDL_DIR="$DEFAULT_DDL_DIR"
  ok "ddl 폴더를 찾았습니다: $DDL_DIR (경로 입력 생략)"
else
  ask "DDL 경로 (비우면 건너뜀)" ""
  DDL_DIR="$REPLY"
fi
DEFAULT_DML_DIR="${SCRIPT_DIR}/dml"
if [[ -d "$DEFAULT_DML_DIR" ]]; then
  DML_DIR="$DEFAULT_DML_DIR"
  ok "dml 폴더를 찾았습니다: $DML_DIR (경로 입력 생략)"
else
  ask "DML 경로 (비우면 건너뜀)" ""
  DML_DIR="$REPLY"
fi

echo
ask "VF_ORGANIZATION.PARTNER_CODE / provider.json partnerCode 공통값" "oacx"
PARTNER_CODE="$REPLY"

echo
echo "-------- verifier --------"
info "verifier 설정 루트: $VERIFIER_ROOT (앞에서 이미 입력받음)"
ask "verifier 컨테이너 이름" "verifier"
VF_CONTAINER="$REPLY"
ask "verifier 포트" "48085"
VF_INTERNAL_PORT="$REPLY"
VF_HOST_PORT="$REPLY"

echo
echo "-------- oacx --------"
DEFAULT_OACX_ROOT="${SCRIPT_DIR}/oacx"
if [[ -d "$DEFAULT_OACX_ROOT" ]]; then
  OACX_ROOT="$DEFAULT_OACX_ROOT"
  ok "oacx 폴더를 찾았습니다: $OACX_ROOT (경로 입력 생략)"
else
  ask "OACX 설정 루트 경로 (app/, config/ 가 있는 위치)" "D:\\03. Docker\\sandbox\\oacx"
  OACX_ROOT="$REPLY"
fi
ask "OACX 컨테이너 이름" "oacx"
OACX_CONTAINER="$REPLY"
ask "Tomcat 이미지 (레지스트리)" "${LOCAL_REGISTRY}/${NAMESPACE}/tomcat9-jdk8:9-jdk8"
TOMCAT_IMAGE="$REPLY"
ask "OACX Context path (URL: http://localhost:<포트>/<이 값>/)" "oacx"
CONTEXT_PATH="$REPLY"
ask "OACX 포트" "8080"
OACX_HOST_PORT="$REPLY"

echo
JDK8_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/jdk8:latest"
ask "verifier 실행용 JDK8 이미지 (레지스트리)" "$JDK8_IMAGE"
JDK8_IMAGE="$REPLY"

echo
{
echo "======================= 실행 요약 ======================="
echo " 배포 환경     : $DEPLOY_ENV (oper.mode/OPER_SORT=${OPER_SORT})"
echo " config 업데이트 : $([[ "$UPDATE_DB_CONFIG" -eq 1 ]] && echo "예 (DB 접속정보를 아래 값으로 덮어씀)" || echo "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)")"
echo " 네트워크      : $NETWORK_NAME"
echo " DB            : $DB_IMAGE / $DB_CONTAINER / db=$DB_NAME / port=$DB_PORT"
echo " 공용 앱 계정  : $APP_USER"
echo " PARTNER_CODE  : $PARTNER_CODE"
echo " verifier      : $VF_CONTAINER (포트 ${VF_HOST_PORT}), root=$VERIFIER_ROOT"
echo " oacx          : $OACX_CONTAINER (포트 ${OACX_HOST_PORT}, /$CONTEXT_PATH), root=$OACX_ROOT"
[[ "$GENERATED_PW" -eq 1 ]] && echo " 생성된 root 비밀번호 : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
if ! confirm "위 설정으로 전체 스택을 배포할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# 네트워크는 별도로 미리 만들지 않는다 -- docker-compose.yml의 networks: 블록이
# name(${NETWORK_NAME})과 driver(bridge)를 명시적으로 선언하고 있어서, `docker compose up`
# 실행 시 compose가 알아서 생성/재사용한다.

# 기존에 동일한 이름으로 떠있는 컨테이너가 있으면(이 스크립트의 이전 실행이든, compose가 아닌
# 수동 실행이든) compose가 새로 만들 때 이름 충돌이 날 수 있으므로 미리 정리한다.
for c in "$DB_CONTAINER" "$VF_CONTAINER" "$OACX_CONTAINER"; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    warn "이미 '$c' 컨테이너가 존재합니다. 삭제하고 새로 만듭니다."
    docker rm -f "$c" >/dev/null
  fi
done

# ============================================================================
# 2~3. DB 준비 + DDL/DML 스테이징
# ============================================================================
echo
echo "########## 2~3단계: DB 준비 + DDL/DML 스테이징 ##########"

info "레지스트리 이미지를 내려받는 중입니다: $DB_IMAGE"
if ! docker pull "$DB_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 mariadb/base/build-and-push.sh 로 '${DB_TAG}' 태그를 등록하세요."
  exit 1
fi

# DDL/DML 스테이징: verifier + oacx 것을 하나의 initdb.d 디렉터리에 순서대로 모은다.
# (verifier DDL에 박혀있는 CREATE DATABASE/USE `VC_VERIFIER`는 실제 선택한 DB_NAME과
#  다를 수 있으므로, 모든 DDL 파일에 대해 DB명을 현재 선택값으로 정규화한다.)
STAGING_DIR="${SCRIPT_DIR}/.staging/${DB_CONTAINER}/initdb"
rm -rf "${SCRIPT_DIR}/.staging/${DB_CONTAINER}"
mkdir -p "$STAGING_DIR"

stage_ddl() {
  local dir="$1" prefix="$2"
  [[ -z "$dir" ]] && return
  if [[ ! -d "$dir" ]]; then warn "DDL 경로를 찾을 수 없습니다: $dir (건너뜁니다)"; return; fi
  local i=1
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    local dest="${STAGING_DIR}/${prefix}_$(printf '%03d' "$i")_$(basename "$f")"
    cp "$f" "$dest"
    # CREATE DATABASE / USE 문에 박힌 DB명을 현재 선택한 DB_NAME으로 정규화
    sed -i -E \
      -e "s/(CREATE[[:space:]]+DATABASE[[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+\`)[^\`]+(\`)/\1${DB_NAME}\2/I" \
      -e "s/(^USE[[:space:]]+\`)[^\`]+(\`;)/\1${DB_NAME}\2/I" \
      "$dest"
    i=$((i + 1))
  done
  ok "DDL 스테이징: $dir → ${prefix}_* ($((i - 1))개)"
}

stage_dml() {
  local dir="$1" prefix="$2"
  [[ -z "$dir" ]] && return
  if [[ ! -d "$dir" ]]; then warn "DML 경로를 찾을 수 없습니다: $dir (건너뜁니다)"; return; fi
  local i=1
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    local dest="${STAGING_DIR}/${prefix}_$(printf '%03d' "$i")_$(basename "$f")"
    cp "$f" "$dest"
    # 파일 내용으로 verifier용/oacx용을 판별한다(폴더가 합쳐져 있어도 둘 다 정상 처리됨).
    if grep -qi 'INSERT INTO VF_ORGANIZATION' "$dest" 2>/dev/null; then
      sed -i -E "s/(INSERT[[:space:]]+INTO[[:space:]]+VF_ORGANIZATION\([^)]*\)[[:space:]]*VALUES[[:space:]]*\()'[^']*'/\1'${PARTNER_CODE}'/I" "$dest"
    fi
    if grep -qi "INSERT INTO OACX_PROVIDER" "$dest" 2>/dev/null; then
      sed -i -E "s/('ent'[[:space:]]*,[[:space:]]*')(prod|dev)(')/\1${OPER_SORT}\3/gI" "$dest"
    fi
    i=$((i + 1))
  done
  ok "DML 스테이징: $dir → ${prefix}_* ($((i - 1))개)"
}

stage_ddl "$DDL_DIR" "10"
stage_dml "$DML_DIR" "50"
DB_INITDB_DIR="$STAGING_DIR"
ok "DB 준비 완료 (실제 기동은 compose가 verifier/oacx와 함께 한 번에 처리합니다)"

# ============================================================================
# 4~5. verifier 설정 스테이징
# ============================================================================
echo
echo "########## 4~5단계: verifier 설정 스테이징 ##########"

if [[ ! -f "${VERIFIER_ROOT}/Dockerfile" ]]; then
  warn "Dockerfile을 찾을 수 없습니다: ${VERIFIER_ROOT}/Dockerfile (레지스트리 이미지만 사용합니다)"
fi
JAR_COUNT=0; JAR_NAME=""
for f in "${VERIFIER_ROOT}/app"/mdl-verifier-1.*.jar; do
  [[ -f "$f" ]] || continue
  JAR_COUNT=$((JAR_COUNT + 1)); JAR_NAME="$(basename "$f")"
done
if [[ "$JAR_COUNT" -ne 1 ]]; then
  err "${VERIFIER_ROOT}/app 안에 mdl-verifier-1.*.jar 파일이 정확히 1개 있어야 합니다 (현재 ${JAR_COUNT}개)."
  exit 1
fi
ok "실행 대상 JAR 확인: $JAR_NAME"

info "레지스트리에서 verifier 실행 이미지를 내려받는 중입니다: $JDK8_IMAGE"
if ! docker pull "$JDK8_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 jdk8/base/build-and-push.sh 를 실행하세요."
  exit 1
fi

# config는 더 이상 staging으로 복사하지 않고 sandbox 원본을 그대로 마운트한다.
# (컨테이너를 재시작만 해도 config 수정사항이 즉시 반영되도록 하기 위함 -- WORKLOG 참고)
VF_CONFIG_DIR="${VERIFIER_ROOT}/config/config"
DS_PROP="$DS_SRC"
if [[ "$UPDATE_DB_CONFIG" -eq 1 && -f "$DS_PROP" ]]; then
  sed -i -E \
    -e "s#(spring\.datasource\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" \
    -e "s#(spring\.datasource\.hikari\.username=).*#\1${APP_USER}#" \
    -e "s#(spring\.datasource\.hikari\.password=).*#\1${APP_PASSWORD}#" \
    "$DS_PROP"
  ok "verifier application-datasource.properties(원본)에 공용 DB 접속정보를 반영했습니다."
else
  info "config 설정값 업데이트를 선택하지 않아 application-datasource.properties는 그대로 사용합니다 (DB를 이 값에 맞춰 생성했습니다)."
fi

# 로그는 각 서비스 폴더 밑이 아니라, VERIFIER_ROOT와 같은 부모(sandbox) 아래 공용 log/ 트리에 모은다.
VF_LOG_ROOT="$(dirname "$VERIFIER_ROOT")/log/verifier"
mkdir -p "${VF_LOG_ROOT}"
ok "verifier 준비 완료 (실제 기동은 compose가 한 번에 처리합니다)"

# ============================================================================
# 6~7. oacx 설정 스테이징
# ============================================================================
echo
echo "########## 6~7단계: oacx 설정 스테이징 ##########"

if [[ ! -d "${OACX_ROOT}/app" || ! -d "${OACX_ROOT}/config" ]]; then
  err "app/ 또는 config/ 폴더를 찾을 수 없습니다: ${OACX_ROOT}"
  exit 1
fi

info "레지스트리에서 Tomcat 이미지를 내려받는 중입니다: $TOMCAT_IMAGE"
if ! docker pull "$TOMCAT_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 tomcat/base/build-and-push.sh 를 실행하세요."
  exit 1
fi

# ---------- app/ 스테이징 + web.xml 패치 ----------
OACX_APP_STAGING="${SCRIPT_DIR}/.staging/${OACX_CONTAINER}/app"
rm -rf "$OACX_APP_STAGING"
mkdir -p "$(dirname "$OACX_APP_STAGING")"
cp -r "${OACX_ROOT}/app" "$OACX_APP_STAGING"
sed -i -E "s#(<param-value>)\./WEB-INF/config/server\.properties(</param-value>)#\1/config/server.properties\2#" \
  "${OACX_APP_STAGING}/WEB-INF/web.xml"
ok "oacx web.xml의 config.file을 절대경로로 패치했습니다."

# ---------- config: sandbox 원본을 직접 사용 (더 이상 staging 복사 안 함) ----------
OACX_CONFIG_DIR="${OACX_ROOT}/config"
SP_PROP="${OACX_CONFIG_DIR}/server.properties"
# mybatis/log 경로와 oper.mode는 이 프로젝트의 마운트 컨벤션/환경 선택에 필요한 구조적 값이라
# config 업데이트 여부와 무관하게 항상 반영한다.
sed -i -E \
  -e "s#(mybatis\.mapper\.path=).*#\1/config/mybatis#" \
  -e "s#(log\.file=).*#\1/config/logback.xml#" \
  -e "s#(log\.path=).*#\1/logs/app#" \
  -e "s#(oper\.mode=).*#\1${OPER_SORT}#" \
  "$SP_PROP"
if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
  sed -i -E \
    -e "s#(jdbc\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" \
    -e "s#(jdbc\.user=).*#\1${APP_USER}#" \
    -e "s#(jdbc\.password=).*#\1${APP_PASSWORD}#" \
    "$SP_PROP"
  ok "oacx server.properties에 공용 DB 접속정보 + oper.mode(${OPER_SORT})를 반영했습니다."
else
  ok "oacx server.properties의 DB 접속정보는 그대로 사용, oper.mode(${OPER_SORT})/mybatis·log 경로만 반영했습니다."
fi

# ---------- provider.json 6종: base/partnerCode/publicKey/vc.curveType 자동 반영 ----------
info "verifier DID 파일(${DID_FILE_NAME})에서 publicKey/curveType을 추출합니다..."
DID_FILE="${VERIFIER_ROOT}/config/sp/${DID_FILE_NAME}"
DID_PUBLIC_KEY=""
DID_CURVE_TYPE=""
if [[ -f "$DID_FILE" ]]; then
  DID_JSON="$(cat "$DID_FILE")"
  # verificationMethod 배열의 첫 항목에서 publicKeyBase58/type 추출 (id에 .rsa 포함된 keyAgreement 항목 제외)
  VM_BLOCK="$(grep -oE '"verificationMethod":\[[^]]*\]' <<< "$DID_JSON")"
  DID_PUBLIC_KEY="$(grep -oE '"publicKeyBase58":"[^"]*"' <<< "$VM_BLOCK" | head -n1 | sed -E 's/.*:"(.*)"/\1/')"
  DID_TYPE_RAW="$(grep -oE '"type":"[^"]*"' <<< "$VM_BLOCK" | head -n1 | sed -E 's/.*:"(.*)"/\1/')"
  case "$DID_TYPE_RAW" in
    *Secp256k1*) DID_CURVE_TYPE="SECP256_K1" ;;
    *Secp256r1*|*Secp256R1*) DID_CURVE_TYPE="SECP256_R1" ;;
    *) warn "did type '${DID_TYPE_RAW}'을(를) curveType으로 매핑하지 못했습니다. provider.json의 vc.curveType은 그대로 둡니다." ;;
  esac
  if [[ -n "$DID_PUBLIC_KEY" ]]; then
    ok "publicKey=${DID_PUBLIC_KEY:0:12}... curveType=${DID_CURVE_TYPE:-(미확인)} (${DID_FILE_NAME} 기준)"
  else
    warn "DID 파일에서 publicKeyBase58을 찾지 못했습니다: $DID_FILE"
  fi
else
  warn "DID 파일을 찾을 수 없습니다: $DID_FILE (provider.json의 publicKey는 기존 값을 유지합니다)"
fi

PROVIDER_FILES=(coidentitydocument-provider.json comdc-provider.json comdl-provider.json comnh-provider.json comrc-provider.json coresidence-provider.json)
for pf in "${PROVIDER_FILES[@]}"; do
  target="${OACX_CONFIG_DIR}/${pf}"
  [[ -f "$target" ]] || { warn "provider.json을 찾을 수 없습니다: $pf (건너뜁니다)"; continue; }
  sed -i -E "s#\"base\": \"[^\"]*\"#\"base\": \"http://${VF_CONTAINER}:${VF_INTERNAL_PORT}\"#" "$target"
  sed -i -E "s#\"partnerCode\": \"[^\"]*\"#\"partnerCode\": \"${PARTNER_CODE}\"#" "$target"
  [[ -n "$DID_PUBLIC_KEY" ]] && sed -i -E "s#\"publicKey\" ?: ?\"[^\"]*\"#\"publicKey\" : \"${DID_PUBLIC_KEY}\"#" "$target"
  [[ -n "$DID_CURVE_TYPE" ]] && sed -i -E "s#\"vc\.curveType\":\s*\"[^\"]*\"#\"vc.curveType\":\"${DID_CURVE_TYPE}\"#" "$target"
  # 알려진 오타 보정 (web2appsspay -> web2app). sspay 전용 provider가 아닌 한 이 값이 맞다.
  sed -i -E 's#/api/v2/transaction/web2appsspay#/api/v2/transaction/web2app#' "$target"
done
ok "provider.json 6종에 base/partnerCode/publicKey/vc.curveType을 반영했습니다."
warn "serviceCode는 인증사업자별 고유값이라 자동화 대상에서 제외했습니다 -- 비어있는 파일은 직접 채워야 합니다."

# ---------- Context XML 생성 ----------
CONTEXT_XML="${SCRIPT_DIR}/.staging/${OACX_CONTAINER}/${CONTEXT_PATH}.xml"
cat > "$CONTEXT_XML" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="/app" path="/${CONTEXT_PATH}" reloadable="false" />
XMLEOF

# 로그는 각 서비스 폴더 밑이 아니라, OACX_ROOT와 같은 부모(sandbox) 아래 공용 log/ 트리에 모은다.
OX_LOG_ROOT="$(dirname "$OACX_ROOT")/log/oacx"
mkdir -p "${OX_LOG_ROOT}/tomcat" "${OX_LOG_ROOT}/app"

ok "oacx 준비 완료"

# ============================================================================
# compose로 3개 서비스를 한 번에 기동 (db → verifier → oacx 순서는
# docker-compose.yml의 depends_on: condition: service_healthy 로 강제됨)
# ============================================================================
echo
echo "########## compose 기동 ##########"

# 비밀번호는 .env 파일(디스크)에 쓰지 않는다 -- compose 변수 치환은 셸에 export된
# 환경변수를 .env보다 우선 사용하므로, 민감값만 잠깐 export했다가 compose 호출 직후 unset한다.
ENV_FILE="${SCRIPT_DIR}/.staging/omnionecx.env"
cat > "$ENV_FILE" <<ENVEOF
DB_IMAGE=${DB_IMAGE}
DB_CONTAINER=${DB_CONTAINER}
DB_NAME=${DB_NAME}
DB_PORT=${DB_PORT}
DB_INITDB_DIR=${DB_INITDB_DIR}
APP_USER=${APP_USER}
JDK8_IMAGE=${JDK8_IMAGE}
VF_CONTAINER=${VF_CONTAINER}
VF_PORT=${VF_HOST_PORT}
VERIFIER_ROOT=${VERIFIER_ROOT}
VF_CONFIG_DIR=${VF_CONFIG_DIR}
VF_LOG_ROOT=${VF_LOG_ROOT}
TOMCAT_IMAGE=${TOMCAT_IMAGE}
OACX_CONTAINER=${OACX_CONTAINER}
OACX_HOST_PORT=${OACX_HOST_PORT}
OACX_APP_STAGING=${OACX_APP_STAGING}
OACX_CONFIG_DIR=${OACX_CONFIG_DIR}
CONTEXT_XML=${CONTEXT_XML}
CONTEXT_PATH=${CONTEXT_PATH}
OX_LOG_ROOT=${OX_LOG_ROOT}
NETWORK_NAME=${NETWORK_NAME}
ENVEOF

export DB_ROOT_PASSWORD APP_PASSWORD
info "docker compose up -d 를 실행합니다 (db → verifier → oacx 순서로 기동, 시간이 걸릴 수 있습니다)..."
COMPOSE_STATUS=0
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" -p omnionecx --env-file "$ENV_FILE" up -d || COMPOSE_STATUS=$?
# 값 자체는 마지막 접속정보 요약에 화면 출력용으로 필요하니 유지하되, 이후 이 스크립트가
# 띄우는 자식 프로세스에 환경변수로 전파되지 않도록 export만 해제한다(값은 남아있음).
export -n DB_ROOT_PASSWORD APP_PASSWORD
if [[ "$COMPOSE_STATUS" -ne 0 ]]; then
  err "docker compose up 실패 (종료 코드 ${COMPOSE_STATUS}). 'docker compose -f docker-compose.yml -p omnionecx logs'로 확인하세요."
  exit 1
fi

wait_healthy() {
  local container="$1" label="$2" timeout="$3" elapsed=0 interval=5
  info "${label} 기동을 기다리는 중입니다..."
  while true; do
    local status
    status="$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo unknown)"
    if [[ "$status" == "healthy" ]]; then ok "${label} 정상 기동되었습니다."; return 0; fi
    if ! docker ps -q -f "name=^${container}\$" | grep -q .; then
      err "${label} 컨테이너가 중단되었습니다. 로그:"; docker logs "$container" 2>&1 | tail -60; return 1
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      warn "${label}: 제한 시간 내에 healthy 상태가 되지 않았습니다. 'docker logs -f ${container}'로 확인하세요."
      return 0
    fi
    sleep "$interval"; elapsed=$((elapsed + interval)); printf "."
  done
}
wait_healthy "$DB_CONTAINER" "DB" 300; echo
wait_healthy "$VF_CONTAINER" "verifier" 180; echo
wait_healthy "$OACX_CONTAINER" "oacx" 300; echo

check_http() {
  local url="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  if [[ "$code" == "000" ]]; then
    sleep 3
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)"
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  fi
  echo "$code"
}
VF_HTTP="$(check_http "http://localhost:${VF_HOST_PORT}/")"
OACX_HTTP="$(check_http "http://localhost:${OACX_HOST_PORT}/${CONTEXT_PATH}/")"

# ---------- 최종 접속 정보 ----------
echo
{
echo "======================= 접속 정보 ======================="
echo " 배포 환경     : $DEPLOY_ENV (oper.mode/OPER_SORT=${OPER_SORT})"
echo " -------------------------- [DB] --------------------------"
echo " Host          : localhost / Port: $DB_PORT / DB: $DB_NAME / User: $APP_USER"
echo " JDBC URL      : jdbc:mariadb://localhost:${DB_PORT}/${DB_NAME}"
echo " (컨테이너 간 통신용 Host: ${DB_CONTAINER}, Network: ${NETWORK_NAME})"
echo " -------------------------- [verifier] --------------------------"
echo " URL           : http://localhost:${VF_HOST_PORT}/  (HTTP ${VF_HTTP})"
echo " PARTNER_CODE  : $PARTNER_CODE"
echo " -------------------------- [oacx] --------------------------"
echo " URL           : http://localhost:${OACX_HOST_PORT}/${CONTEXT_PATH}/  (HTTP ${OACX_HTTP})"
[[ "$GENERATED_PW" -eq 1 ]] && echo " root 비밀번호(DB) : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
unset DB_ROOT_PASSWORD APP_PASSWORD
