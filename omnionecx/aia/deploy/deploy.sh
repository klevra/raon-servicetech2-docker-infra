#!/usr/bin/env bash
# ============================================================================
# OmnioneCX 통합 배포 스크립트 (bash) — 백포팅 트랙 (aia, 2.0.0.1)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh 로 레지스트리가 떠있어야 하고,
#            db/verifier/oacx/admin/sample 각각의 build-and-push.sh 로
#            omnionecx-{db,verifier,oacx,admin,sample}:aia 이미지가
#            레지스트리에 이미 등록되어 있어야 함.
#
# aia는 cx 2.0 계열의 백포팅 버전으로, 2.0.0.3 트랙과 동일한 구조(verifier/
# oacx/admin/sample 모두 내장 Tomcat 포함 실행형 fat jar)를 쓴다 -- 이
# 스크립트도 2.0.0.3 deploy.sh를 그대로 재사용한 것이다.
#
# 1.0.0.12 트랙과의 핵심 차이:
#   - verifier/oacx/admin/sample 모두 내장 Tomcat 포함 실행형 fat jar
#     (Spring Boot). oacx는 context-path(/oacx/api)/port(8080, 배포 시 조정 가능)가
#     이미지 안 application.yml에 고정되어 있어 Context XML 생성이
#     필요 없다.
#   - verifier 설정은 application-*.properties 여러 개가 아니라
#     application.yml 하나에 인라인으로 들어있다 -- 이 스크립트의 config
#     패치는 properties(key=value)가 아니라 YAML(key: value) 문법을 sed로
#     직접 건드린다.
#   - admin(신규): oacx/verifier와 같은 DB를 쓰는 관리자 콘솔. sample(신규):
#     oacx REST API를 호출하는 테스트 페이지. oacx가 healthy해진 뒤에 뜬다.
#   - oacx에 co*-provider.json 같은 인증사업자별 설정 파일이 없다 -- DID
#     publicKey/curveType 추출·반영 로직은 이 트랙에는 해당 사항이 없어
#     제외했다.
#
# 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"
SITE="OmnioneCX aia(2.0.0.1) 백포팅 트랙"
VERIFIER_APP_VERSION="1.3.36_fix"
OACX_APP_VERSION="2.0.0.1"
ADMIN_APP_VERSION="2.0.0.1"
SAMPLE_APP_VERSION="1.0-SNAPSHOT"
MOVING_TAG="aia"

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

port_in_use() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
  local rc=$?
  exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
  return $rc
}

port_owner_container() {
  local port="$1"
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | awk -F'\t' -v pat=":${port}->" '$2 ~ pat {print $1; exit}'
}

find_available_port() {
  local port="$1" exclude="${2:-}" tries=0
  while :; do
    local owner
    owner="$(port_owner_container "$port")"
    if [[ -z "$owner" ]]; then
      port_in_use "$port" || { echo "$port"; return; }
    elif [[ -n "$exclude" && "$owner" == "$exclude" ]]; then
      echo "$port"; return
    fi
    port=$((port + 1))
    tries=$((tries + 1))
    if [[ "$tries" -ge 20 ]]; then echo "$port"; return; fi
  done
}

echo "=============================================================="
echo " OmnioneCX ${SITE} 통합 배포 (백포팅 트랙, 태그=${MOVING_TAG})"
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
  1) DEPLOY_ENV="개발"; OPER_SORT="dev"; DID_FILE_NAME="raondev2.sp.did"
     SP_ENV_SUBDIR="dev"
     SP_SERVER_KEY_MANAGER_PATH="/config/sp/dev"
     SP_RCP_HOST="https://bcdev.mobileid.go.kr:18888"
     SP_KEY_MANAGER_PATH="raondev2.sp.wallet"
     SP_KEY_MANAGER_PASSWORD="raon12345!"
     SP_KEY_ID="dev2.sp"
     SP_RSA_KEY_ID="dev2.sp.rsa"
     SP_SERVICE_CODE="raonsecure.1"
     SP_CA_LIST_DOMAIN="https://mipdev.mobileid.go.kr:23443/v1/capush/list"
     ;;
  2) DEPLOY_ENV="운영"; OPER_SORT="prod"; DID_FILE_NAME="raonEnt.did"
     SP_ENV_SUBDIR="prod"
     SP_SERVER_KEY_MANAGER_PATH="/config/sp/prod"
     SP_RCP_HOST="https://bcc.mobileid.go.kr:18888"
     SP_KEY_MANAGER_PATH="raonEnt.wallet"
     SP_KEY_MANAGER_PASSWORD="1q2w3e4r!@"
     SP_KEY_ID="raonEnt.sp"
     SP_RSA_KEY_ID="raonEnt.sp.rsa"
     SP_SERVICE_CODE="raonsnc.1"
     SP_CA_LIST_DOMAIN="https://pub.mobileid.go.kr:10443/v1/capush/list"
     ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac

info "CA 앱 목록 서버(${SP_CA_LIST_DOMAIN}) 응답 여부를 확인합니다 (1초 대기)..."
if curl -s -f --max-time 1 --location "${SP_CA_LIST_DOMAIN}" --header 'Content-Type: application/json' --data '{"apiType" : "mip"}' >/dev/null 2>&1; then
  SP_CA_LIST_CRON_ENABLED="true"
  ok "CA 앱 목록 서버 응답 확인 -- mdl.sp.ca-list-data-cron-enabled=true로 설정합니다."
else
  SP_CA_LIST_CRON_ENABLED="false"
  warn "CA 앱 목록 서버(${SP_CA_LIST_DOMAIN})가 1초 내에 응답하지 않습니다 -- mdl.sp.ca-list-data-cron-enabled=false로 설정합니다."
fi

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
info "docker compose 프로젝트 이름은 위 네트워크 이름과 별개입니다 -- 같은 PC에서 이 트랙을 여러 벌(예: 병렬 테스트) 띄우려면 서로 다르게 지정하세요."
ask "docker compose 프로젝트 이름" "omnionecx-aia"
COMPOSE_PROJECT="$REPLY"

echo
ask "VF_ORGANIZATION.PARTNER_CODE / OACX_PROVIDER.OPER_SORT 공통값" "raon"
PARTNER_CODE="$REPLY"

echo
echo "-------- 헬스체크 사용 여부 --------"
info "끄면 각 서비스의 헬스체크가 항상 즉시 통과(exit 0)로 바뀝니다 -- depends_on 순서 기동 자체는 그대로 유지되고, 컨테이너 상태 점검만 생략됩니다."
if confirm "헬스체크를 사용할까요?"; then
  HEALTHCHECK_ENABLED=1
else
  HEALTHCHECK_ENABLED=0
  warn "헬스체크를 비활성화합니다 -- 컨테이너가 실제로 정상 응답하는지는 별도로 직접 확인하세요."
fi
# 실제 CMD 문자열은 각 서비스 포트가 전부 정해진 뒤(6단계 직전)에 구성한다.

echo
echo "-------- config 설정값 업데이트 여부 --------"
info "verifier/oacx/admin이 마운트할 config 안의 DB 접속정보(datasource)를 이번 배포값으로 덮어쓸지 선택하세요."
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
  ask "verifier 설정 루트 경로 (config/ 가 있는 위치)" "${SCRIPT_DIR}/verifier"
  VERIFIER_ROOT="$REPLY"
fi
VF_YML="${VERIFIER_ROOT}/config/application.yml"

echo
echo "-------- DB --------"
DB_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx2-db:${MOVING_TAG}"

NEED_DB_PROMPT=0
if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
  NEED_DB_PROMPT=1
else
  DB_CONTAINER=""; DB_NAME=""; APP_USER=""; APP_PASSWORD=""
  if [[ ! -f "$VF_YML" ]]; then
    warn "DB 접속정보를 config에서 읽어와야 하는데 파일을 찾을 수 없습니다: $VF_YML"
    warn "직접 입력받는 방식으로 대신 진행합니다."
    NEED_DB_PROMPT=1
  else
    DERIVED_URL="$(grep -oE '^[[:space:]]+url: jdbc:mariadb://[^[:space:]]+' "$VF_YML" | head -n1 | sed -E 's/^[[:space:]]+url: //')"
    DB_CONTAINER="$(sed -E 's#.*//([^:/]+).*#\1#' <<< "$DERIVED_URL")"
    DB_NAME="$(sed -E 's#.*/([^/?[:space:]]+)$#\1#' <<< "$DERIVED_URL")"
    APP_USER="$(grep -oE '^[[:space:]]+username: .*' "$VF_YML" | head -n1 | sed -E 's/^[[:space:]]+username: //')"
    APP_PASSWORD="$(grep -oE '^[[:space:]]+password: .*' "$VF_YML" | head -n1 | sed -E 's/^[[:space:]]+password: //')"
    if [[ -z "$DB_CONTAINER" || -z "$DB_NAME" || -z "$APP_USER" ]]; then
      warn "config에서 DB 접속정보를 추출하지 못했습니다 ($VF_YML 확인 필요) -- 직접 입력받는 방식으로 대신 진행합니다."
      NEED_DB_PROMPT=1
    else
      ok "config에서 DB 접속정보를 그대로 가져왔습니다: host(컨테이너명)=${DB_CONTAINER}, db=${DB_NAME}, user=${APP_USER}"
    fi
  fi
fi
if [[ "$NEED_DB_PROMPT" -eq 1 ]]; then
  ask "DB 컨테이너 이름" "${DB_CONTAINER:-db}"
  DB_CONTAINER="$REPLY"
  ask "DB(스키마) 이름 (verifier/oacx/admin이 하나의 DB를 공유 -- 실제 운영값과 동일하게 기본 VC_VERIFIER)" "${DB_NAME:-VC_VERIFIER}"
  DB_NAME="$REPLY"
  ask "공용 앱 계정 이름" "${APP_USER:-omnione}"
  APP_USER="$REPLY"
  ask_secret "공용 앱 계정 비밀번호" "${APP_PASSWORD:-0mN1DB}"
  APP_PASSWORD="$REPLY"
  UPDATE_DB_CONFIG=1
fi
DEFAULT_DB_PORT="$(find_available_port 3306 "$DB_CONTAINER")"
if [[ "$DEFAULT_DB_PORT" != "3306" ]]; then
  warn "3306 포트가 이미 사용 중이라, 대신 ${DEFAULT_DB_PORT}을(를) 기본값으로 제안합니다."
fi
ask "DB 포트 (호스트에 노출할 포트, DBeaver 등 외부 툴 접속용)" "$DEFAULT_DB_PORT"
DB_PORT="$REPLY"

echo
DEFAULT_DB_DATA_DIR="${SCRIPT_DIR}/data/db"
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
ask "verifier 컨테이너 이름" "verifier"
VF_CONTAINER="$REPLY"
DEFAULT_VF_PORT="$(find_available_port 48085 "$VF_CONTAINER")"
if [[ "$DEFAULT_VF_PORT" != "48085" ]]; then
  warn "48085 포트가 이미 사용 중이라, 대신 ${DEFAULT_VF_PORT}을(를) 기본값으로 제안합니다."
fi
ask "verifier 포트" "$DEFAULT_VF_PORT"
VF_PORT="$REPLY"
VERIFIER_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx2-verifier:${MOVING_TAG}"

DETECTED_IP="$(detect_local_ip)"
if [[ -n "$DETECTED_IP" ]]; then
  ok "이 PC의 IP를 감지했습니다: $DETECTED_IP"
else
  warn "이 PC의 IP를 자동으로 감지하지 못했습니다. 직접 입력해주세요."
fi
ask "verifier의 외부 콜백 주소(mdl.sp.api-server-domain, 앱이 Profile 요청/VP 제출 시 직접 접근하는 주소)" "http://${DETECTED_IP:-localhost}:${VF_PORT}"
VF_PUBLIC_DOMAIN="$REPLY"

echo
echo "-------- oacx --------"
DEFAULT_OACX_ROOT="${SCRIPT_DIR}/oacx"
if [[ -d "$DEFAULT_OACX_ROOT" ]]; then
  OACX_ROOT="$DEFAULT_OACX_ROOT"
  ok "oacx 폴더를 찾았습니다: $OACX_ROOT (경로 입력 생략)"
else
  ask "OACX 설정 루트 경로 (config/ 가 있는 위치)" "${SCRIPT_DIR}/oacx"
  OACX_ROOT="$REPLY"
fi
ask "OACX 컨테이너 이름" "oacx"
OACX_CONTAINER="$REPLY"
# context-path(/oacx/api)/포트(8080, 배포 시 조정 가능)는 이미지 안 application.yml에
# 고정되어 있어 1.0.0.12처럼 Context XML을 새로 만들 필요가 없다.
DEFAULT_OACX_PORT="$(find_available_port 8080 "$OACX_CONTAINER")"
if [[ "$DEFAULT_OACX_PORT" != "8080" ]]; then
  warn "8080 포트가 이미 사용 중이라, 대신 ${DEFAULT_OACX_PORT}을(를) 기본값으로 제안합니다."
fi
ask "OACX 포트" "$DEFAULT_OACX_PORT"
OACX_HOST_PORT="$REPLY"
OACX_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx2-oacx:${MOVING_TAG}"

# sample(테스트 페이지)이 브라우저에서 직접 호출하는 주소 -- 컨테이너 내부
# 전용 이름(oacx)이 아니라 이 PC/브라우저에서 실제로 접근 가능한 주소여야
# 한다 (verifier의 VF_PUBLIC_DOMAIN과 동일한 이유).
ask "oacx의 외부(브라우저) 접근 주소 -- sample 테스트 페이지가 여기로 API를 호출함" "http://${DETECTED_IP:-localhost}:${OACX_HOST_PORT}/oacx/api"
OACX_PUBLIC_URL="$REPLY"

echo
echo "-------- admin --------"
DEFAULT_ADMIN_ROOT="${SCRIPT_DIR}/admin"
if [[ -d "$DEFAULT_ADMIN_ROOT" ]]; then
  ADMIN_ROOT="$DEFAULT_ADMIN_ROOT"
  ok "admin 폴더를 찾았습니다: $ADMIN_ROOT (경로 입력 생략)"
else
  ask "admin 설정 루트 경로 (config/ 가 있는 위치)" "${SCRIPT_DIR}/admin"
  ADMIN_ROOT="$REPLY"
fi
ask "admin 컨테이너 이름" "admin"
ADMIN_CONTAINER="$REPLY"
DEFAULT_ADMIN_PORT="$(find_available_port 6443 "$ADMIN_CONTAINER")"
if [[ "$DEFAULT_ADMIN_PORT" != "6443" ]]; then
  warn "6443 포트가 이미 사용 중이라, 대신 ${DEFAULT_ADMIN_PORT}을(를) 기본값으로 제안합니다."
fi
ask "admin 포트" "$DEFAULT_ADMIN_PORT"
ADMIN_HOST_PORT="$REPLY"
ADMIN_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx2-admin:${MOVING_TAG}"

echo
echo "-------- sample(테스트 페이지) --------"
DEFAULT_SAMPLE_ROOT="${SCRIPT_DIR}/sample"
if [[ -d "$DEFAULT_SAMPLE_ROOT" ]]; then
  SAMPLE_ROOT="$DEFAULT_SAMPLE_ROOT"
  ok "sample 폴더를 찾았습니다: $SAMPLE_ROOT (경로 입력 생략)"
else
  ask "sample 설정 루트 경로 (config/ 가 있는 위치)" "${SCRIPT_DIR}/sample"
  SAMPLE_ROOT="$REPLY"
fi
ask "sample 컨테이너 이름" "sample"
SAMPLE_CONTAINER="$REPLY"
DEFAULT_SAMPLE_PORT="$(find_available_port 9025 "$SAMPLE_CONTAINER")"
if [[ "$DEFAULT_SAMPLE_PORT" != "9025" ]]; then
  warn "9025 포트가 이미 사용 중이라, 대신 ${DEFAULT_SAMPLE_PORT}을(를) 기본값으로 제안합니다."
fi
ask "sample 포트" "$DEFAULT_SAMPLE_PORT"
SAMPLE_HOST_PORT="$REPLY"
SAMPLE_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx2-sample:${MOVING_TAG}"

echo
{
echo "======================= 실행 요약 ======================="
echo " 사이트        : $SITE (verifier ${VERIFIER_APP_VERSION} / OACX ${OACX_APP_VERSION} / admin ${ADMIN_APP_VERSION} / sample ${SAMPLE_APP_VERSION}, 태그=${MOVING_TAG})"
echo " 배포 환경     : $DEPLOY_ENV (oper.mode/OPER_SORT=${OPER_SORT})"
echo " config 업데이트 : $([[ "$UPDATE_DB_CONFIG" -eq 1 ]] && echo "예 (DB 접속정보를 아래 값으로 덮어씀)" || echo "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)")"
echo " 헬스체크      : $([[ "$HEALTHCHECK_ENABLED" -eq 1 ]] && echo "사용" || echo "미사용 (항상 즉시 통과)")"
echo " 네트워크      : $NETWORK_NAME"
echo " compose 프로젝트 : $COMPOSE_PROJECT"
echo " DB            : $DB_IMAGE / $DB_CONTAINER / db=$DB_NAME / port=$DB_PORT"
echo " DB 데이터 경로 : $DB_DATA_DIR"
echo " 공용 앱 계정  : $APP_USER"
echo " PARTNER_CODE  : $PARTNER_CODE"
echo " verifier      : $VERIFIER_IMAGE / $VF_CONTAINER (포트 ${VF_PORT}), root=$VERIFIER_ROOT"
echo " VF_PUBLIC_DOMAIN : $VF_PUBLIC_DOMAIN"
echo " oacx          : $OACX_IMAGE / $OACX_CONTAINER (포트 ${OACX_HOST_PORT}, /oacx/api), root=$OACX_ROOT"
echo " OACX_PUBLIC_URL : $OACX_PUBLIC_URL (sample이 브라우저에서 호출하는 주소)"
echo " admin         : $ADMIN_IMAGE / $ADMIN_CONTAINER (포트 ${ADMIN_HOST_PORT}), root=$ADMIN_ROOT"
echo " sample        : $SAMPLE_IMAGE / $SAMPLE_CONTAINER (포트 ${SAMPLE_HOST_PORT}), root=$SAMPLE_ROOT"
[[ "$GENERATED_PW" -eq 1 ]] && echo " 생성된 root 비밀번호 : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
if ! confirm "위 설정으로 전체 스택을 배포할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

for c in "$DB_CONTAINER" "$VF_CONTAINER" "$OACX_CONTAINER" "$ADMIN_CONTAINER" "$SAMPLE_CONTAINER"; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    warn "이미 '$c' 컨테이너가 존재합니다. 삭제하고 새로 만듭니다."
    docker rm -f "$c" >/dev/null
  fi
done

# ============================================================================
# 2. verifier config 패치 (application.yml, YAML 문법)
# ============================================================================
echo
echo "########## 2단계: verifier config 패치 ##########"

VF_CONFIG_DIR="${VERIFIER_ROOT}/config"
if [[ -f "$VF_YML" ]]; then
  sed -i -E \
    -e "s#(^[[:space:]]+url: jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" \
    "$VF_YML"
  if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
    sed -i -E \
      -e "s#(^[[:space:]]+username: ).*#\1${APP_USER}#" \
      -e "s#(^[[:space:]]+password: ).*#\1${APP_PASSWORD}#" \
      "$VF_YML"
    ok "verifier application.yml(원본)에 공용 DB 접속정보(호스트+계정)를 반영했습니다."
  else
    ok "verifier application.yml의 DB 호스트/포트는 현재 배포값(${DB_CONTAINER})으로 맞췄고, 계정 정보는 기존 값을 유지합니다."
  fi
else
  warn "application.yml을 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $VF_YML"
fi

if [[ -f "$VF_YML" ]]; then
  sed -i -E "s#(^[[:space:]]+api-server-domain: )https?://[^[:space:]]*#\1${VF_PUBLIC_DOMAIN}#" "$VF_YML"
  sed -i -E \
    -e "s#(^[[:space:]]+server-key-manager-path: ).*#\1${SP_SERVER_KEY_MANAGER_PATH}#" \
    -e "s#(^[[:space:]]+rcp-host: ).*#\1${SP_RCP_HOST}#" \
    -e "s#(^[[:space:]]+key-manager-path: ).*#\1${SP_KEY_MANAGER_PATH}#" \
    -e "s#(^[[:space:]]+key-manager-password: ).*#\1${SP_KEY_MANAGER_PASSWORD}#" \
    -e "s#(^[[:space:]]+did-file-path: ).*#\1${DID_FILE_NAME}#" \
    -e "s#(^[[:space:]]+key-id: ).*#\1${SP_KEY_ID}#" \
    -e "s#(^[[:space:]]+rsa-key-id: ).*#\1${SP_RSA_KEY_ID}#" \
    -e "s#(^[[:space:]]+service-code: ).*#\1${SP_SERVICE_CODE}#" \
    -e "s#(^[[:space:]]+ca-list-domain: ).*#\1${SP_CA_LIST_DOMAIN}#" \
    -e "s#(^[[:space:]]+ca-list-data-cron-enabled: ).*#\1${SP_CA_LIST_CRON_ENABLED}#" \
    "$VF_YML"
  ok "verifier mdl.sp.api-server-domain을 ${VF_PUBLIC_DOMAIN}(으)로 반영했습니다."
  ok "verifier 지갑/DID/블록체인 접속정보(server-key-manager-path, rcp-host, key-manager-*, did-file-path, key-id, rsa-key-id, service-code, ca-list-*)를 ${DEPLOY_ENV} 환경 값으로 반영했습니다."
fi

VF_LOG_ROOT="${SCRIPT_DIR}/log/verifier"
mkdir -p "${VF_LOG_ROOT}"
ok "verifier 준비 완료 (실제 기동은 compose가 한 번에 처리합니다)"

# ============================================================================
# 3. oacx config 패치 (application.yml, YAML 문법)
# ============================================================================
echo
echo "########## 3단계: oacx config 패치 ##########"

if [[ ! -d "${OACX_ROOT}/config" ]]; then
  err "config/ 폴더를 찾을 수 없습니다: ${OACX_ROOT}"
  exit 1
fi
OACX_CONFIG_DIR="${OACX_ROOT}/config"
OACX_YML="${OACX_CONFIG_DIR}/application.yml"
if [[ -f "$OACX_YML" ]]; then
  sed -i -E "s#(^[[:space:]]+url: jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" "$OACX_YML"
  sed -i -E "s#(^[[:space:]]+mode: )(dev|stage|prod)(.*)#\1${OPER_SORT}\3#" "$OACX_YML"
  if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
    sed -i -E \
      -e "s#(^[[:space:]]+username: ).*#\1${APP_USER}#" \
      -e "s#(^[[:space:]]+password: ).*#\1${APP_PASSWORD}#" \
      "$OACX_YML"
    ok "oacx application.yml에 공용 DB 접속정보(호스트+계정) + application.oper.mode(${OPER_SORT})를 반영했습니다."
  else
    ok "oacx application.yml의 DB 호스트/포트는 현재 배포값(${DB_CONTAINER})으로 맞췄고, 계정 정보는 기존 값을 유지합니다. application.oper.mode(${OPER_SORT})도 반영."
  fi
else
  warn "application.yml을 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $OACX_YML"
fi
info "aia(2.0.0.1) oacx도 2.0.0.3과 동일하게 co*-provider.json 같은 인증사업자별 설정 파일이 없어(내장 mid.providers 고정 목록 사용), 1.0.0.12의 provider.json/DID publicKey 반영 단계는 이 트랙에 해당 사항이 없습니다."

OX_LOG_ROOT="${SCRIPT_DIR}/log/oacx"
mkdir -p "${OX_LOG_ROOT}"
ok "oacx 준비 완료"

# ============================================================================
# 4. admin config 패치 (application.yml, YAML 문법)
# ============================================================================
echo
echo "########## 4단계: admin config 패치 ##########"

if [[ ! -d "${ADMIN_ROOT}/config" ]]; then
  err "config/ 폴더를 찾을 수 없습니다: ${ADMIN_ROOT}"
  exit 1
fi
ADMIN_CONFIG_DIR="${ADMIN_ROOT}/config"
ADMIN_YML="${ADMIN_CONFIG_DIR}/application.yml"
if [[ -f "$ADMIN_YML" ]]; then
  sed -i -E "s#(^[[:space:]]+url: jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" "$ADMIN_YML"
  if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
    sed -i -E \
      -e "s#(^[[:space:]]+username: ).*#\1${APP_USER}#" \
      -e "s#(^[[:space:]]+password: ).*#\1${APP_PASSWORD}#" \
      "$ADMIN_YML"
    ok "admin application.yml에 공용 DB 접속정보(호스트+계정)를 반영했습니다."
  else
    ok "admin application.yml의 DB 호스트/포트는 현재 배포값(${DB_CONTAINER})으로 맞췄고, 계정 정보는 기존 값을 유지합니다."
  fi
else
  warn "application.yml을 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $ADMIN_YML"
fi

ADMIN_LOG_ROOT="${SCRIPT_DIR}/log/admin"
mkdir -p "${ADMIN_LOG_ROOT}"
ok "admin 준비 완료"

# ============================================================================
# 5. sample(테스트 페이지) config 패치
# ============================================================================
echo
echo "########## 5단계: sample config 패치 ##########"

if [[ ! -d "${SAMPLE_ROOT}/config" ]]; then
  err "config/ 폴더를 찾을 수 없습니다: ${SAMPLE_ROOT}"
  exit 1
fi
SAMPLE_CONFIG_DIR="${SAMPLE_ROOT}/config"
SAMPLE_YML="${SAMPLE_CONFIG_DIR}/application.yml"
if [[ -f "$SAMPLE_YML" ]]; then
  # sample은 브라우저에 로드되는 정적 페이지(event.js)가 window.onload 시점에
  # 자기 백엔드(getProperties)에서 cx-url을 읽어와 "통합인증 서버 주소" 입력란에
  # 채우고, 이후 CA 리스트 조회를 포함한 모든 API 호출을 그 주소로 브라우저가
  # 직접 나간다. 따라서 컨테이너 내부 전용 이름(oacx)을 넣으면 브라우저가 그
  # 이름을 못 찾아 요청이 oacx에 아예 도달하지 못한다(로그도 안 남음) -- 반드시
  # 이 PC/브라우저에서 접근 가능한 주소(OACX_PUBLIC_URL)를 넣어야 한다.
  sed -i -E "s#(cx-url: \")https?://[^\"]*(\")#\1${OACX_PUBLIC_URL}\2#" "$SAMPLE_YML"
  ok "sample raonsecure.cx-url을 ${OACX_PUBLIC_URL}(으)로 반영했습니다 (브라우저에서 직접 호출하는 주소)."
else
  warn "application.yml을 찾을 수 없어 cx-url 패치를 건너뜁니다: $SAMPLE_YML"
fi

SAMPLE_LOG_ROOT="${SCRIPT_DIR}/log/sample"
mkdir -p "${SAMPLE_LOG_ROOT}"
ok "sample 준비 완료"

# ============================================================================
# 6. 이미지 pull + compose 기동
# ============================================================================
echo
echo "########## 6단계: 이미지 pull + compose 기동 ##########"

# 헬스체크 CMD 문자열 구성 (포트가 전부 정해진 이 시점에 구성) -- 비활성화
# 선택 시 전부 "exit 0"(즉시 통과)로 바뀐다. 따옴표/파이프 등 셸 특수문자를
# .env에 안전하게 담기 위해 최대한 단순한 형태로 구성한다.
if [[ "$HEALTHCHECK_ENABLED" -eq 1 ]]; then
  HC_DB_CMD="healthcheck.sh --connect --innodb_initialized || exit 1"
  HC_VF_CMD="curl -f http://localhost:${VF_PORT}/ || exit 1"
  HC_OACX_CMD="curl -f http://localhost:${OACX_HOST_PORT}/oacx/api/actuator/health || exit 1"
  HC_ADMIN_CMD="curl -f http://localhost:${ADMIN_HOST_PORT}/ || exit 1"
  HC_SAMPLE_CMD="curl -f http://localhost:${SAMPLE_HOST_PORT}/ || exit 1"
else
  HC_DB_CMD="exit 0"
  HC_VF_CMD="exit 0"
  HC_OACX_CMD="exit 0"
  HC_ADMIN_CMD="exit 0"
  HC_SAMPLE_CMD="exit 0"
fi

for img in "$DB_IMAGE" "$VERIFIER_IMAGE" "$OACX_IMAGE" "$ADMIN_IMAGE" "$SAMPLE_IMAGE"; do
  info "레지스트리 이미지를 내려받는 중입니다: $img"
  if ! docker pull "$img"; then
    err "이미지를 가져오지 못했습니다: $img (해당 build-and-push.sh 로 먼저 등록하세요)"
    exit 1
  fi
done

ENV_FILE="${SCRIPT_DIR}/.staging/omnionecx.env"
mkdir -p "$(dirname "$ENV_FILE")"
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
OACX_CONFIG_DIR=${OACX_CONFIG_DIR}
OX_LOG_ROOT=${OX_LOG_ROOT}
ADMIN_IMAGE=${ADMIN_IMAGE}
ADMIN_CONTAINER=${ADMIN_CONTAINER}
ADMIN_HOST_PORT=${ADMIN_HOST_PORT}
ADMIN_CONFIG_DIR=${ADMIN_CONFIG_DIR}
ADMIN_LOG_ROOT=${ADMIN_LOG_ROOT}
SAMPLE_IMAGE=${SAMPLE_IMAGE}
SAMPLE_CONTAINER=${SAMPLE_CONTAINER}
SAMPLE_HOST_PORT=${SAMPLE_HOST_PORT}
SAMPLE_CONFIG_DIR=${SAMPLE_CONFIG_DIR}
SAMPLE_LOG_ROOT=${SAMPLE_LOG_ROOT}
NETWORK_NAME=${NETWORK_NAME}
COMPOSE_PROJECT=${COMPOSE_PROJECT}
HC_DB_CMD=${HC_DB_CMD}
HC_VF_CMD=${HC_VF_CMD}
HC_OACX_CMD=${HC_OACX_CMD}
HC_ADMIN_CMD=${HC_ADMIN_CMD}
HC_SAMPLE_CMD=${HC_SAMPLE_CMD}
ENVEOF

if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  info "네트워크(${NETWORK_NAME})가 없어 새로 만듭니다."
  docker network create "$NETWORK_NAME" >/dev/null
fi

export DB_ROOT_PASSWORD APP_PASSWORD
info "docker compose up -d 를 실행합니다 (db → verifier → oacx → admin/sample 순서로 기동, 시간이 걸릴 수 있습니다)..."
COMPOSE_STATUS=0
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" -p "$COMPOSE_PROJECT" --env-file "$ENV_FILE" up -d || COMPOSE_STATUS=$?
export -n DB_ROOT_PASSWORD APP_PASSWORD
if [[ "$COMPOSE_STATUS" -ne 0 ]]; then
  err "docker compose up 실패 (종료 코드 ${COMPOSE_STATUS}). 'docker compose -f docker-compose.yml -p ${COMPOSE_PROJECT} --env-file ${ENV_FILE} logs'로 확인하세요."
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
wait_healthy "$OACX_CONTAINER" "oacx" 180; echo
wait_healthy "$ADMIN_CONTAINER" "admin" 180; echo
wait_healthy "$SAMPLE_CONTAINER" "sample" 180; echo

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
OACX_HTTP="$(check_http "http://localhost:${OACX_HOST_PORT}/oacx/api/")"
ADMIN_HTTP="$(check_http "http://localhost:${ADMIN_HOST_PORT}/")"
SAMPLE_HTTP="$(check_http "http://localhost:${SAMPLE_HOST_PORT}/")"

echo
{
echo "======================= 접속 정보 ======================="
echo " 사이트        : $SITE (verifier ${VERIFIER_APP_VERSION} / OACX ${OACX_APP_VERSION} / admin ${ADMIN_APP_VERSION} / sample ${SAMPLE_APP_VERSION}, 태그=${MOVING_TAG})"
echo " 배포 환경     : $DEPLOY_ENV (oper.mode/OPER_SORT=${OPER_SORT})"
echo " -------------------------- [DB] --------------------------"
echo " Host          : localhost / Port: $DB_PORT / DB: $DB_NAME / User: $APP_USER"
echo " JDBC URL      : jdbc:mariadb://localhost:${DB_PORT}/${DB_NAME}"
echo " 데이터 경로   : $DB_DATA_DIR"
echo " (컨테이너 간 통신용 Host: ${DB_CONTAINER}, Network: ${NETWORK_NAME})"
echo " -------------------------- [verifier] --------------------------"
echo " URL           : http://localhost:${VF_PORT}/  (HTTP ${VF_HTTP})"
echo " -------------------------- [oacx] --------------------------"
echo " URL           : http://localhost:${OACX_HOST_PORT}/oacx/api/  (HTTP ${OACX_HTTP})"
echo " -------------------------- [admin] --------------------------"
echo " URL           : http://localhost:${ADMIN_HOST_PORT}/  (HTTP ${ADMIN_HTTP})"
echo " -------------------------- [sample(테스트 페이지)] --------------------------"
echo " URL           : http://localhost:${SAMPLE_HOST_PORT}/  (HTTP ${SAMPLE_HTTP})"
echo " (브라우저가 이 페이지를 열면 '통합인증 서버 주소' 입력란에 ${OACX_PUBLIC_URL}가 자동으로 채워짐)"
[[ "$GENERATED_PW" -eq 1 ]] && echo " root 비밀번호(DB) : $DB_ROOT_PASSWORD  ⚠ 다시 표시되지 않으니 지금 저장하세요"
echo "==========================================================="
}
info "컨테이너 안으로 들어가려면: ./exec.sh <db|verifier|oacx|admin|sample> [명령]"
warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
unset DB_ROOT_PASSWORD APP_PASSWORD
