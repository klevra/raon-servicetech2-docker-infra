#!/usr/bin/env bash
# ============================================================================
# OmnioneCX 통합 배포 스크립트 (bash) — 우리투자증권(wooriib) 전용, 버전 고정 이미지 트랙
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh 로 레지스트리가 떠있어야 하고,
#            db/verifier/oacx 각각의 build-and-push.sh 로 이 사이트가 쓰는
#            이미지가 레지스트리에 이미 등록되어 있어야 함. db/verifier/oacx는
#            사이트별 리포지토리가 아니라 컴포넌트당 하나의 리포지토리로
#            통합 관리된다 -- DB는 사이트명 태그(omnionecx-db:wooriib)만 쓰고,
#            verifier/oacx는 벤더 표준판이라 순수 버전 태그(omnionecx-verifier:
#            1.3.25_fix)를 쓰며 "wooriib"는 그 버전을 가리키는 이동 태그일
#            뿐이다. 이 사이트 전용 커스텀/포크 빌드가 생기면 그때는
#            "wooriib-버전" 형태로 별도 관리한다.
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
# db/verifier/oacx가 각각 하나의 리포지토리로 통합 관리된다. verifier/oacx는
# 커스텀 포크가 아닌 벤더 표준판이라 태그도 순수 버전 번호(위 *_VERSION_TAG)를
# 그대로 쓰고, SITE_TAG(사이트명)는 "지금 이 사이트가 쓰는 버전"을 가리키는
# 이동 태그로만 쓴다 -- 나중에 이 사이트 전용으로 커스텀/포크된 빌드가 생기면
# 그때는 "sitetag-version" 형태(예: wooriib-1.3.42)로 별도 관리한다.
SITE_TAG="wooriib"
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

# 이 호스트 포트가 이미 쓰이고 있는지 실제 TCP connect로 확인한다(docker가
# 점유했든 다른 프로세스가 점유했든 다 잡아낸다).
port_in_use() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
  local rc=$?
  exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
  return $rc
}

# 이 호스트 포트를 지금 물고 있는 컨테이너 이름을 반환한다(없으면 빈 문자열).
port_owner_container() {
  local port="$1"
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | awk -F'\t' -v pat=":${port}->" '$2 ~ pat {print $1; exit}'
}

# preferred 포트가 비어있으면 그대로 반환. 이미 쓰이고 있어도, 그 포트를
# 물고 있는 게 exclude(이번에 내릴 내 컨테이너)라면 재사용 가능하다고
# 본다(어차피 곧 새로 만들면서 그 포트를 다시 쓸 것이므로). 그 외의
# 경우(다른 사이트/무관한 프로세스)면 1씩 올려가며 빈 포트를 찾는다
# (최대 20회 시도). ask의 "기본값"으로 이 결과를 쓰면, 사용자가 그대로
# enter만 쳐도 실제로 뜰 수 있는 포트가 기본값이 되고, 뒤이은 설정 파일
# 패치들도 전부 같은 변수를 재사용하므로 자동으로 일관되게 반영된다.
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
info "docker compose 프로젝트 이름은 위 네트워크 이름과 별개입니다 -- 같은 PC에서 이 사이트를 여러 벌(예: 병렬 테스트) 띄우려면 서로 다르게 지정하세요."
ask "docker compose 프로젝트 이름" "omnionecx-wooriib"
COMPOSE_PROJECT="$REPLY"

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
DB_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx-db:${SITE_TAG}"

DS_SRC="${VERIFIER_ROOT}/config/config/application-datasource.properties"
NEED_DB_PROMPT=0
if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
  NEED_DB_PROMPT=1
else
  DB_CONTAINER=""; DB_NAME=""; APP_USER=""; APP_PASSWORD=""
  if [[ ! -f "$DS_SRC" ]]; then
    warn "DB 접속정보를 config에서 읽어와야 하는데 파일을 찾을 수 없습니다: $DS_SRC"
    warn "직접 입력받는 방식으로 대신 진행합니다."
    NEED_DB_PROMPT=1
  else
    DERIVED_URL="$(grep -oE 'spring\.datasource\.url=jdbc:mariadb://[^[:space:]]+' "$DS_SRC" | head -n1)"
    DB_CONTAINER="$(sed -E 's#.*//([^:/]+).*#\1#' <<< "$DERIVED_URL")"
    DB_NAME="$(sed -E 's#.*/([^/?[:space:]]+)$#\1#' <<< "$DERIVED_URL")"
    APP_USER="$(grep -oE 'spring\.datasource\.hikari\.username=.*' "$DS_SRC" | head -n1 | sed -E 's/^[^=]*=//')"
    APP_PASSWORD="$(grep -oE 'spring\.datasource\.hikari\.password=.*' "$DS_SRC" | head -n1 | sed -E 's/^[^=]*=//')"
    if [[ -z "$DB_CONTAINER" || -z "$DB_NAME" || -z "$APP_USER" ]]; then
      warn "config에서 DB 접속정보를 추출하지 못했습니다 ($DS_SRC 확인 필요) -- 직접 입력받는 방식으로 대신 진행합니다."
      NEED_DB_PROMPT=1
    else
      ok "config에서 DB 접속정보를 그대로 가져왔습니다: host(컨테이너명)=${DB_CONTAINER}, db=${DB_NAME}, user=${APP_USER}"
    fi
  fi
fi
if [[ "$NEED_DB_PROMPT" -eq 1 ]]; then
  ask "DB 컨테이너 이름" "${DB_CONTAINER:-mariadb-1.0.0.9}"
  DB_CONTAINER="$REPLY"
  ask "DB(스키마) 이름 (verifier/oacx가 하나의 DB를 공유 -- 실제 운영값과 동일하게 기본 VC_VERIFIER)" "${DB_NAME:-VC_VERIFIER}"
  DB_NAME="$REPLY"
  ask "공용 앱 계정 이름" "${APP_USER:-omnione}"
  APP_USER="$REPLY"
  ask_secret "공용 앱 계정 비밀번호" "${APP_PASSWORD:-0mN1DB}"
  APP_PASSWORD="$REPLY"
  # 직접 입력받은 이상, 값이 실제 파일에도 반영되어야 하니 이후 패치
  # 단계에서 이 값들을 강제로 적용하도록 표시한다.
  UPDATE_DB_CONFIG=1
fi
DEFAULT_DB_PORT="$(find_available_port 3306 "$DB_CONTAINER")"
if [[ "$DEFAULT_DB_PORT" != "3306" ]]; then
  warn "3306 포트가 이미 사용 중이라, 대신 ${DEFAULT_DB_PORT}을(를) 기본값으로 제안합니다."
fi
ask "DB 포트 (호스트에 노출할 포트, DBeaver 등 외부 툴 접속용)" "$DEFAULT_DB_PORT"
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
DEFAULT_VF_PORT="$(find_available_port 48085 "$VF_CONTAINER")"
if [[ "$DEFAULT_VF_PORT" != "48085" ]]; then
  warn "48085 포트가 이미 사용 중이라, 대신 ${DEFAULT_VF_PORT}을(를) 기본값으로 제안합니다."
fi
ask "verifier 포트" "$DEFAULT_VF_PORT"
VF_PORT="$REPLY"
VERIFIER_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx-verifier:${SITE_TAG}"

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
  ask "OACX 설정 루트 경로 (config/ 가 있는 위치)" "D:\\03. Docker\\sandbox\\oacx"
  OACX_ROOT="$REPLY"
fi
ask "OACX 컨테이너 이름" "oacx-1.0.0.9"
OACX_CONTAINER="$REPLY"
ask "OACX Context path (URL: http://localhost:<포트>/<이 값>/)" "oacx"
CONTEXT_PATH="$REPLY"
DEFAULT_OACX_PORT="$(find_available_port 8080 "$OACX_CONTAINER")"
if [[ "$DEFAULT_OACX_PORT" != "8080" ]]; then
  warn "8080 포트가 이미 사용 중이라, 대신 ${DEFAULT_OACX_PORT}을(를) 기본값으로 제안합니다."
fi
ask "OACX 포트" "$DEFAULT_OACX_PORT"
OACX_HOST_PORT="$REPLY"
OACX_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/omnionecx-oacx:${SITE_TAG}"

ask "oacx '앱 호출 테스트' 페이지에 표시할 OACX 서버 주소 (이 PC에서 접근 가능한 IP)" "http://${DETECTED_IP:-localhost}:${OACX_HOST_PORT}"
OACX_PUBLIC_URL="$REPLY"

echo
{
echo "======================= 실행 요약 ======================="
echo " 사이트        : $SITE (OACX ${OACX_VERSION_TAG} / verifier ${VERIFIER_VERSION_TAG})"
echo " 배포 환경     : $DEPLOY_ENV (oper.mode/OPER_SORT=${OPER_SORT})"
echo " config 업데이트 : $([[ "$UPDATE_DB_CONFIG" -eq 1 ]] && echo "예 (DB 접속정보를 아래 값으로 덮어씀)" || echo "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)")"
echo " 네트워크      : $NETWORK_NAME"
echo " compose 프로젝트 : $COMPOSE_PROJECT"
echo " DB            : $DB_IMAGE / $DB_CONTAINER / db=$DB_NAME / port=$DB_PORT"
echo " DB 데이터 경로 : $DB_DATA_DIR"
echo " 공용 앱 계정  : $APP_USER"
echo " PARTNER_CODE  : $PARTNER_CODE"
echo " verifier      : $VERIFIER_IMAGE / $VF_CONTAINER (포트 ${VF_PORT}), root=$VERIFIER_ROOT"
echo " VF_PUBLIC_DOMAIN : $VF_PUBLIC_DOMAIN"
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
# 호스트/포트/DB명(컨테이너 내부 네트워킹 배선)은 배포 때마다 항상 현재
# DB_CONTAINER/DB_NAME 값으로 다시 맞춘다 -- config에 이미 들어있던 값이
# 예전 배포(다른 컨테이너명/사이트) 것일 수 있어 매번 확실히 고쳐쓴다.
# 계정(username/password)은 "DB 접속정보 업데이트" 선택 시에만 덮어쓴다.
if [[ -f "$DS_PROP" ]]; then
  sed -i -E \
    -e "s#(spring\.datasource\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" \
    "$DS_PROP"
  if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
    sed -i -E \
      -e "s#(spring\.datasource\.hikari\.username=).*#\1${APP_USER}#" \
      -e "s#(spring\.datasource\.hikari\.password=).*#\1${APP_PASSWORD}#" \
      "$DS_PROP"
    ok "verifier application-datasource.properties(원본)에 공용 DB 접속정보(호스트+계정)를 반영했습니다."
  else
    ok "verifier application-datasource.properties의 DB 호스트/포트는 현재 배포값(${DB_CONTAINER})으로 맞췄고, 계정 정보는 기존 값을 유지합니다."
  fi
else
  warn "application-datasource.properties를 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $DS_PROP"
fi

# verifier 자신의 외부 콜백 주소(mdl.sp.api-server-domain) -- Profile 요청/VP
# 제출 등 앱이 직접 접근하는 주소라 배포 PC/포트가 바뀔 때마다 갱신 필요.
# application-sp.properties(1.3.x 공통) / application-mdl-sp.properties(일부
# 최신 버전) 둘 다 있으면 둘 다 반영한다.
for spf in "${VF_CONFIG_DIR}/application-sp.properties" "${VF_CONFIG_DIR}/application-mdl-sp.properties"; do
  [[ -f "$spf" ]] || continue
  sed -i -E "s#(mdl\.sp\.api-server-domain=)https?://[^[:space:]]*#\1${VF_PUBLIC_DOMAIN}#" "$spf"
done
ok "verifier mdl.sp.api-server-domain을 ${VF_PUBLIC_DOMAIN}(으)로 반영했습니다."

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
# 호스트/포트/DB명(컨테이너 내부 네트워킹 배선)은 배포 때마다 항상 현재
# DB_CONTAINER/DB_NAME 값으로 다시 맞춘다 -- config에 이미 들어있던 값이
# 예전 배포(다른 컨테이너명/사이트) 것일 수 있어 매번 확실히 고쳐쓴다.
# (전제: jdbc.type=jdbc 직결 방식으로 이미 설정되어 있어야 함 -- jndi 방식
# 템플릿이면 이 sed는 아무 것도 바꾸지 못하니 수동으로 jdbc 직결로 바꿔둘 것)
if [[ -f "$SP_PROP" ]]; then
  if grep -qE '^jdbc\.type=jndi' "$SP_PROP"; then
    warn "oacx server.properties가 아직 jdbc.type=jndi 상태입니다 -- jdbc 직결 방식으로 먼저 바꿔야 DB 접속정보 자동 반영이 적용됩니다."
  fi
  sed -i -E \
    -e "s#(jdbc\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^[:space:]]*#\1${DB_CONTAINER}\2${DB_NAME}#" \
    "$SP_PROP"
  if [[ "$UPDATE_DB_CONFIG" -eq 1 ]]; then
    sed -i -E \
      -e "s#(jdbc\.user=).*#\1${APP_USER}#" \
      -e "s#(jdbc\.password=).*#\1${APP_PASSWORD}#" \
      "$SP_PROP"
    ok "oacx server.properties에 공용 DB 접속정보(호스트+계정) + oper.mode(${OPER_SORT})를 반영했습니다."
  else
    ok "oacx server.properties의 DB 호스트/포트는 현재 배포값(${DB_CONTAINER})으로 맞췄고, 계정 정보는 기존 값을 유지합니다. oper.mode(${OPER_SORT})/mybatis·log 경로도 반영."
  fi
else
  warn "server.properties를 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $SP_PROP"
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

# co*-provider.json 전부를 대상으로 하되, "base"는 현재 우리 verifier를
# 가리키고 있던 값일 때만 갱신한다(호스트명이 "verifier"로 시작하는 경우) --
# naver/kakao/정부망 등 외부 인증사업자의 진짜 API 주소는 절대 건드리지
# 않기 위한 안전장치. partnerCode/publicKey/vc.curveType은 우리 쪽 신원
# (DID)이라 어떤 인증사업자를 부르든 공통으로 반영한다.
PROVIDER_COUNT=0
for target in "${OACX_CONFIG_DIR}"/co*-provider.json; do
  [[ -f "$target" ]] || continue
  PROVIDER_COUNT=$((PROVIDER_COUNT + 1))
  sed -i -E "s#\"base\": \"https?://verifier[^\"]*\"#\"base\": \"http://${VF_CONTAINER}:${VF_PORT}\"#" "$target"
  sed -i -E "s#\"partnerCode\": \"[^\"]*\"#\"partnerCode\": \"${PARTNER_CODE}\"#" "$target"
  [[ -n "$DID_PUBLIC_KEY" ]] && sed -i -E "s#\"publicKey\" ?: ?\"[^\"]*\"#\"publicKey\" : \"${DID_PUBLIC_KEY}\"#" "$target"
  [[ -n "$DID_CURVE_TYPE" ]] && sed -i -E "s#\"vc\.curveType\":\s*\"[^\"]*\"#\"vc.curveType\":\"${DID_CURVE_TYPE}\"#" "$target"
  sed -i -E 's#/api/v2/transaction/web2appsspay#/api/v2/transaction/web2app#' "$target"
done
ok "provider.json ${PROVIDER_COUNT}개에 partnerCode/publicKey/vc.curveType을 반영했고, 그 중 우리 verifier를 가리키던 base 주소는 http://${VF_CONTAINER}:${VF_PORT}(으)로 갱신했습니다 (외부 인증사업자 주소는 그대로 둠)."
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
COMPOSE_PROJECT=${COMPOSE_PROJECT}
ENVEOF

# docker-compose.yml에서 이 네트워크를 external로 선언해뒀으므로(여러
# 사이트가 공유), compose가 대신 만들어주지 않는다 -- 없으면 여기서 미리
# 만들어둔다(이미 있으면 조용히 통과).
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  info "네트워크(${NETWORK_NAME})가 없어 새로 만듭니다."
  docker network create "$NETWORK_NAME" >/dev/null
fi

export DB_ROOT_PASSWORD APP_PASSWORD
info "docker compose up -d 를 실행합니다 (db → verifier → oacx 순서로 기동, 시간이 걸릴 수 있습니다)..."
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
