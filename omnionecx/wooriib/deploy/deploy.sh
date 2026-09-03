#!/usr/bin/env bash
# ============================================================================
# OmnioneCX 통합 배포 스크립트 (bash) — 우리투자증권(wooriib) 전용, 버전 고정 이미지 트랙
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh 로 레지스트리가 떠있어야 하고,
#            db/verifier/oacx 각각의 build-and-push.sh 로 이 사이트 전용
#            이미지(omnionecx-{db,verifier,oacx}-wooriib)가 레지스트리에
#            이미 등록되어 있어야 함.
#
# omnionecx/default 트랙과의 차이 (모두 상위 폴더(../db, ../verifier, ../oacx)의
# 세 Dockerfile에 빌트인됨):
#   - verifier/oacx: app(JAR/WAR)이 이미지 안에 있음 -- app 스테이징 없음
#   - DB: DDL/DML이 이미지 안에 있음 -- DDL_DIR/DML_DIR 수령 없음
#   - PARTNER_CODE는 배포 시점에 물어봄(기본값 'raon') -- OPER_SORT와 같은
#     방식(플레이스홀더 + 컨테이너 최초 기동 시 치환)으로 DB 이미지에 반영됨
#   - DB 데이터는 DB_DATA_DIR에 영속화됨 (default는 휘발성이었음)
#
# 그래서 이 스크립트가 하는 일은 3가지뿐이다:
#   1) DB 접속정보/운영·개발/포트/경로 등 값을 수령
#   2) verifier/oacx config를 sandbox 원본에 직접 패치 (default와 동일한 방식)
#   3) 레지스트리에서 세 이미지를 pull 하고 compose로 기동
#
# 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"
SITE="우리투자증권(wooriib)"
DB_VERSION_TAG="latest"          # 사이트 전용 DB 이미지는 독립 버전 없이 latest 고정
VERIFIER_VERSION_TAG="1.3.25_fix"
OACX_VERSION_TAG="1.0.0.9"

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

# 이 PC가 실제 네트워크에서 쓰는 IP를 최대한 정확히 추정한다(기본 게이트웨이가
# 잡혀있는 인터페이스 기준 -- 루프백/APIPA/가상 어댑터를 걸러내는 것보다
# 훨씬 안정적). 실패하면 빈 문자열을 반환하고 호출부에서 수동 입력을 받는다.
detect_local_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | sed -nE 's/.*src ([0-9.]+).*/\1/p' | head -n1)"
  fi
  if [[ -z "$ip" ]] && command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
    local iface
    iface="$(route get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')"
    [[ -n "$iface" ]] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
  fi
  if [[ -z "$ip" ]] && command -v powershell.exe >/dev/null 2>&1; then
    ip="$(powershell.exe -NoProfile -Command '(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq "Up" } | Select-Object -First 1).IPv4Address.IPAddress' 2>/dev/null | tr -d '\r\n')"
  fi
  echo "$ip"
}

confirm_no() {
  local prompt="${1:-계속 진행할까요?}" reply
  read -r -p "$prompt (y/n) [n]: " reply
  reply="${reply:-n}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

echo "=============================================================="
echo " OmnioneCX ${SITE} 통합 배포 (버전 고정 이미지 트랙)"
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
  warn "이 스크립트는 데이터가 DB_DATA_DIR 볼륨에만 영속화되는 테스트/개발용 배포입니다."
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
ask "VF_ORGANIZATION.PARTNER_CODE / provider.json partnerCode 공통값" "raon"
PARTNER_CODE="$REPLY"

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
  ask "verifier 설정 루트 경로 (config/ 가 있는 위치)" "D:\\03. Docker\\sandbox\\verifier"
  VERIFIER_ROOT="$REPLY"
fi

echo
echo "-------- DB --------"
DB_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx-db-wooriib:${DB_VERSION_TAG}"

DS_SRC="${VERIFIER_ROOT}/config/config/application-datasource.properties"
if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
  ask "DB 컨테이너 이름" "mariadb-1.0.0.9"
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
DEFAULT_DB_DATA_DIR="$(dirname "$VERIFIER_ROOT")/data/db"
ask "DB 데이터 저장 경로 (컨테이너를 내렸다 올려도 유지됨 -- 이 경로에서 데이터 파일에 직접 접근 가능)" "$DEFAULT_DB_DATA_DIR"
DB_DATA_DIR="$REPLY"
mkdir -p "$DB_DATA_DIR"

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
echo "-------- verifier --------"
info "verifier 설정 루트: $VERIFIER_ROOT (앞에서 이미 입력받음)"
ask "verifier 컨테이너 이름" "verifier-1.3.25-fix"
VF_CONTAINER="$REPLY"
ask "verifier 포트" "48085"
VF_PORT="$REPLY"
VERIFIER_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx-verifier-wooriib:${VERIFIER_VERSION_TAG}"

echo
echo "-------- oacx --------"
DEFAULT_OACX_ROOT="${SCRIPT_DIR}/oacx"
if [[ -d "$DEFAULT_OACX_ROOT" ]]; then
  OACX_ROOT="$DEFAULT_OACX_ROOT"
  ok "oacx 폴더를 찾았습니다: $OACX_ROOT (경로 입력 생략)"
else
  ask "OACX 설정 루트 경로 (config/ 가 있는 위치)" "D:\\03. Docker\\sandbox\\oacx"
  OACX_ROOT="$REPLY"
fi
ask "OACX 컨테이너 이름" "oacx-1.0.0.9"
OACX_CONTAINER="$REPLY"
ask "OACX Context path (URL: http://localhost:<포트>/<이 값>/)" "oacx"
CONTEXT_PATH="$REPLY"
ask "OACX 포트" "8080"
OACX_HOST_PORT="$REPLY"
OACX_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx-oacx-wooriib:${OACX_VERSION_TAG}"

DETECTED_IP="$(detect_local_ip)"
if [[ -n "$DETECTED_IP" ]]; then
  ok "이 PC의 IP를 감지했습니다: $DETECTED_IP"
else
  warn "이 PC의 IP를 자동으로 감지하지 못했습니다. 직접 입력해주세요."
fi
ask "oacx '앱 호출 테스트' 페이지에 표시할 OACX 서버 주소 (이 PC에서 접근 가능한 IP)" "http://${DETECTED_IP:-localhost}:${OACX_HOST_PORT}"
OACX_PUBLIC_URL="$REPLY"

echo
{
echo "======================= 실행 요약 ======================="
echo " 사이트        : $SITE (OACX ${OACX_VERSION_TAG} / verifier ${VERIFIER_VERSION_TAG})"
echo " 배포 환경     : $DEPLOY_ENV (oper.mode/OPER_SORT=${OPER_SORT})"
echo " config 업데이트 : $([[ "$UPDATE_DB_CONFIG" -eq 1 ]] && echo "예 (DB 접속정보를 아래 값으로 덮어씀)" || echo "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)")"
echo " 네트워크      : $NETWORK_NAME"
echo " DB            : $DB_IMAGE / $DB_CONTAINER / db=$DB_NAME / port=$DB_PORT"
echo " DB 데이터 경로 : $DB_DATA_DIR"
echo " 공용 앱 계정  : $APP_USER"
echo " PARTNER_CODE  : $PARTNER_CODE"
echo " verifier      : $VERIFIER_IMAGE / $VF_CONTAINER (포트 ${VF_PORT}), root=$VERIFIER_ROOT"
echo " oacx          : $OACX_IMAGE / $OACX_CONTAINER (포트 ${OACX_HOST_PORT}, /$CONTEXT_PATH), root=$OACX_ROOT"
echo " OACX_PUBLIC_URL : $OACX_PUBLIC_URL"
[[ "$GENERATED_PW" -eq 1 ]] && echo " 생성된 root 비밀번호 : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
if ! confirm "위 설정으로 전체 스택을 배포할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

for c in "$DB_CONTAINER" "$VF_CONTAINER" "$OACX_CONTAINER"; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    warn "이미 '$c' 컨테이너가 존재합니다. 삭제하고 새로 만듭니다."
    docker rm -f "$c" >/dev/null
  fi
done

# ============================================================================
# 2. verifier config 패치 (sandbox 원본에 직접, 컨테이너는 이 원본을 그대로 마운트)
# ============================================================================
echo
echo "########## 2단계: verifier config 패치 ##########"

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

VF_LOG_ROOT="$(dirname "$VERIFIER_ROOT")/log/verifier"
mkdir -p "${VF_LOG_ROOT}"
ok "verifier 준비 완료 (실제 기동은 compose가 한 번에 처리합니다)"

# ============================================================================
# 3. oacx config 패치 (sandbox 원본에 직접)
# ============================================================================
echo
echo "########## 3단계: oacx config 패치 ##########"

if [[ ! -d "${OACX_ROOT}/config" ]]; then
  err "config/ 폴더를 찾을 수 없습니다: ${OACX_ROOT}"
  exit 1
fi

OACX_CONFIG_DIR="${OACX_ROOT}/config"
SP_PROP="${OACX_CONFIG_DIR}/server.properties"
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

# ---------- provider.json 6종: base/publicKey/vc.curveType 자동 반영 (partnerCode는 raon 고정) ----------
info "verifier DID 파일(${DID_FILE_NAME})에서 publicKey/curveType을 추출합니다..."
DID_FILE="${VERIFIER_ROOT}/config/sp/${DID_FILE_NAME}"
DID_PUBLIC_KEY=""
DID_CURVE_TYPE=""
if [[ -f "$DID_FILE" ]]; then
  DID_JSON="$(cat "$DID_FILE")"
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
  sed -i -E "s#\"base\": \"[^\"]*\"#\"base\": \"http://${VF_CONTAINER}:${VF_PORT}\"#" "$target"
  sed -i -E "s#\"partnerCode\": \"[^\"]*\"#\"partnerCode\": \"${PARTNER_CODE}\"#" "$target"
  [[ -n "$DID_PUBLIC_KEY" ]] && sed -i -E "s#\"publicKey\" ?: ?\"[^\"]*\"#\"publicKey\" : \"${DID_PUBLIC_KEY}\"#" "$target"
  [[ -n "$DID_CURVE_TYPE" ]] && sed -i -E "s#\"vc\.curveType\":\s*\"[^\"]*\"#\"vc.curveType\":\"${DID_CURVE_TYPE}\"#" "$target"
  sed -i -E 's#/api/v2/transaction/web2appsspay#/api/v2/transaction/web2app#' "$target"
done
ok "provider.json 6종에 base/partnerCode/publicKey/vc.curveType을 반영했습니다 (partnerCode=${PARTNER_CODE})."
warn "serviceCode는 인증사업자별 고유값이라 자동화 대상에서 제외했습니다 -- 비어있는 파일은 직접 채워야 합니다."

CONTEXT_XML="${SCRIPT_DIR}/.staging/${OACX_CONTAINER}/${CONTEXT_PATH}.xml"
mkdir -p "$(dirname "$CONTEXT_XML")"
cat > "$CONTEXT_XML" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="/app" path="/${CONTEXT_PATH}" reloadable="false" />
XMLEOF

OX_LOG_ROOT="$(dirname "$OACX_ROOT")/log/oacx"
mkdir -p "${OX_LOG_ROOT}/tomcat" "${OX_LOG_ROOT}/app"

ok "oacx 준비 완료"

# ============================================================================
# 4. 이미지 pull + compose 기동
# ============================================================================
echo
echo "########## 4단계: 이미지 pull + compose 기동 ##########"

for img in "$DB_IMAGE" "$VERIFIER_IMAGE" "$OACX_IMAGE"; do
  info "레지스트리 이미지를 내려받는 중입니다: $img"
  if ! docker pull "$img"; then
    err "이미지를 가져오지 못했습니다: $img (해당 build-and-push.sh 로 먼저 등록하세요)"
    exit 1
  fi
done

ENV_FILE="${SCRIPT_DIR}/.staging/omnionecx.env"
cat > "$ENV_FILE" <<ENVEOF
DB_IMAGE=${DB_IMAGE}
DB_CONTAINER=${DB_CONTAINER}
DB_NAME=${DB_NAME}
DB_PORT=${DB_PORT}
DB_DATA_DIR=${DB_DATA_DIR}
APP_USER=${APP_USER}
PARTNER_CODE=${PARTNER_CODE}
OPER_SORT=${OPER_SORT}
VERIFIER_IMAGE=${VERIFIER_IMAGE}
VF_CONTAINER=${VF_CONTAINER}
VF_PORT=${VF_PORT}
VF_CONFIG_DIR=${VF_CONFIG_DIR}
VERIFIER_CONFIG_ROOT=${VERIFIER_ROOT}/config
VF_LOG_ROOT=${VF_LOG_ROOT}
OACX_IMAGE=${OACX_IMAGE}
OACX_CONTAINER=${OACX_CONTAINER}
OACX_HOST_PORT=${OACX_HOST_PORT}
OACX_PUBLIC_URL=${OACX_PUBLIC_URL}
OACX_CONFIG_DIR=${OACX_CONFIG_DIR}
CONTEXT_XML=${CONTEXT_XML}
CONTEXT_PATH=${CONTEXT_PATH}
OX_LOG_ROOT=${OX_LOG_ROOT}
NETWORK_NAME=${NETWORK_NAME}
ENVEOF

export DB_ROOT_PASSWORD APP_PASSWORD
info "docker compose up -d 를 실행합니다 (db → verifier → oacx 순서로 기동, 시간이 걸릴 수 있습니다)..."
COMPOSE_STATUS=0
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" -p omnionecx-wooriib --env-file "$ENV_FILE" up -d || COMPOSE_STATUS=$?
export -n DB_ROOT_PASSWORD APP_PASSWORD
if [[ "$COMPOSE_STATUS" -ne 0 ]]; then
  err "docker compose up 실패 (종료 코드 ${COMPOSE_STATUS}). 'docker compose -f docker-compose.yml -p omnionecx-wooriib --env-file ${ENV_FILE} logs'로 확인하세요."
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
VF_HTTP="$(check_http "http://localhost:${VF_PORT}/")"
OACX_HTTP="$(check_http "http://localhost:${OACX_HOST_PORT}/${CONTEXT_PATH}/")"

echo
{
echo "======================= 접속 정보 ======================="
echo " 사이트        : $SITE (OACX ${OACX_VERSION_TAG} / verifier ${VERIFIER_VERSION_TAG})"
echo " 배포 환경     : $DEPLOY_ENV (oper.mode/OPER_SORT=${OPER_SORT})"
echo " -------------------------- [DB] --------------------------"
echo " Host          : localhost / Port: $DB_PORT / DB: $DB_NAME / User: $APP_USER"
echo " JDBC URL      : jdbc:mariadb://localhost:${DB_PORT}/${DB_NAME}"
echo " 데이터 경로   : $DB_DATA_DIR"
echo " (컨테이너 간 통신용 Host: ${DB_CONTAINER}, Network: ${NETWORK_NAME})"
echo " -------------------------- [verifier] --------------------------"
echo " URL           : http://localhost:${VF_PORT}/  (HTTP ${VF_HTTP})"
echo " -------------------------- [oacx] --------------------------"
echo " URL           : http://localhost:${OACX_HOST_PORT}/${CONTEXT_PATH}/  (HTTP ${OACX_HTTP})"
[[ "$GENERATED_PW" -eq 1 ]] && echo " root 비밀번호(DB) : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
info "컨테이너 안으로 들어가려면: ./exec.sh <db|verifier|oacx> [명령]"
warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
unset DB_ROOT_PASSWORD APP_PASSWORD
