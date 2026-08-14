#!/usr/bin/env bash
# ============================================================================
# Oracle Database 테스트용 Docker 컨테이너 대화형 설치 스크립트 (bash)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 목적      : 테스트·개발·데모 용도로 Oracle DB 컨테이너를 대화형으로 구성/실행
#
# 라이선스 주의사항
#   - 19c Enterprise Edition : Oracle 공식 OTN 라이선스(개발/테스트/데모 목적 무료).
#     Oracle 계정 + container-registry.oracle.com 라이선스 동의 + Auth Token 필요.
#     (2025-06-30부터 계정 비밀번호가 아닌 Auth Token으로만 docker login 가능)
#   - 21c/18c Express Edition(XE) : 완전 무료, 커뮤니티(gvenzl) 빌드 이미지 사용, 계정 불필요.
#   - 어떤 옵션도 "운영(production) 환경" 사용을 허용하지 않습니다. 테스트/개발/데모 전용입니다.
#
# 이 스크립트는 어떤 비밀번호/토큰도 파일에 저장하지 않습니다 (셸 변수에만 보관, 사용 후 unset).
# ============================================================================
set -uo pipefail

# Windows Git Bash(MSYS)는 "docker run -v SRC:DEST:MODE" 인자 안의 "/"로 시작하는
# 부분을 전부 Windows 경로로 잘못 변환한다. 이 변수를 끄면 정상적으로 바인드/볼륨 마운트된다.
# (Linux/macOS의 순정 bash에는 이 변수가 없어 아무 영향 없음 — 안전하게 항상 설정)
export MSYS_NO_PATHCONV=1

REGISTRY_HOST="container-registry.oracle.com"

# ---------- 공통 유틸 ----------
c_reset='\033[0m'; c_green='\033[32m'; c_yellow='\033[33m'; c_red='\033[31m'; c_cyan='\033[36m'

info()  { printf "${c_cyan}[정보]${c_reset} %s\n" "$1"; }
ok()    { printf "${c_green}[완료]${c_reset} %s\n" "$1"; }
warn()  { printf "${c_yellow}[경고]${c_reset} %s\n" "$1"; }
err()   { printf "${c_red}[오류]${c_reset} %s\n" "$1" >&2; }

# 일반 입력 (기본값 지원)
ask() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " REPLY
    REPLY="${REPLY:-$default}"
  else
    read -r -p "$prompt: " REPLY
  fi
}

# 화면에 노출되지 않는 입력 (비밀번호/토큰)
ask_secret() {
  local prompt="$1"
  read -r -s -p "$prompt: " REPLY
  echo
}

# y/n 확인 (기본 y)
confirm() {
  local prompt="${1:-계속 진행할까요?}"
  local reply
  read -r -p "$prompt (y/n) [y]: " reply
  reply="${reply:-y}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

port_in_use() {
  local port="$1"
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"
}

# ---------- 0. 안내 ----------
cat <<'EOF'
==============================================================
 Oracle Database 테스트용 Docker 설치 스크립트
 (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)
==============================================================
EOF

# ---------- 1. 에디션 선택 ----------
echo
echo "설치할 Oracle 에디션을 선택하세요:"
echo "  1) Oracle 19c Enterprise Edition  (공식 레지스트리, Oracle 계정 필요)"
echo "  2) Oracle 21c Express Edition XE  (커뮤니티 이미지, 계정 불필요)"
echo "  3) Oracle 18c Express Edition XE  (커뮤니티 이미지, 계정 불필요, 레거시 호환용)"
ask "번호 선택" "2"
EDITION="$REPLY"

case "$EDITION" in
  1)
    EDITION_NAME="19c Enterprise Edition"
    IMAGE="${REGISTRY_HOST}/database/enterprise:19.3.0.0"
    NEEDS_LOGIN=1
    DEFAULT_NAME="oracle19c-test"
    ;;
  2)
    EDITION_NAME="21c Express Edition"
    IMAGE="gvenzl/oracle-xe:21-slim"
    NEEDS_LOGIN=0
    DEFAULT_NAME="oracle21xe-test"
    ;;
  3)
    EDITION_NAME="18c Express Edition"
    IMAGE="gvenzl/oracle-xe:18-slim"
    NEEDS_LOGIN=0
    DEFAULT_NAME="oracle18xe-test"
    ;;
  *)
    err "잘못된 선택입니다."; exit 1
    ;;
esac
ok "선택됨: $EDITION_NAME ($IMAGE)"

# ---------- 2. (EE 전용) 로그인 ----------
if [[ "$NEEDS_LOGIN" -eq 1 ]]; then
  echo
  info "Enterprise Edition은 Oracle 계정 인증이 필요합니다."
  if DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    ok "이미 로그인/캐시된 자격증명으로 이미지 접근이 가능합니다. 로그인 단계를 건너뜁니다."
  else
    warn "먼저 브라우저에서 아래를 완료해야 합니다:"
    echo "   1) https://${REGISTRY_HOST} 접속 후 로그인"
    echo "   2) Database > enterprise 리포지터리 라이선스 동의(Continue)"
    echo "   3) 계정 아이콘 > Auth Token 메뉴에서 토큰 발급"
    echo "      (2025-06-30부터 계정 비밀번호가 아닌 Auth Token만 docker login에 사용 가능)"
    echo
    read -r -p "위 단계를 완료했으면 Enter를 눌러 계속하세요..." _
    ask "Oracle 계정 이메일(Username)" ""
    ORACLE_USER="$REPLY"
    ask_secret "Auth Token"
    AUTH_TOKEN="$REPLY"
    if ! printf '%s' "$AUTH_TOKEN" | docker login "$REGISTRY_HOST" --username "$ORACLE_USER" --password-stdin; then
      err "로그인 실패. Auth Token 또는 라이선스 동의 상태를 다시 확인하세요."
      exit 1
    fi
    unset AUTH_TOKEN
    ok "로그인 성공"
  fi
fi

# ---------- 3. 컨테이너 설정 입력 ----------
echo
ask "컨테이너 이름" "$DEFAULT_NAME"
CONTAINER_NAME="$REPLY"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  warn "이미 '$CONTAINER_NAME' 이름의 컨테이너가 존재합니다."
  if confirm "기존 컨테이너를 삭제하고 새로 만들까요?"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
    ok "기존 컨테이너 삭제 완료"
  else
    err "컨테이너 이름 충돌로 중단합니다. 스크립트를 다시 실행해 다른 이름을 입력하세요."
    exit 1
  fi
fi

if [[ "$EDITION" == "1" ]]; then
  ask "SID (인스턴스 식별자)" "VERIFIER"
  ORACLE_SID_VAL="$REPLY"
  ask "PDB(Pluggable DB) 이름" "${ORACLE_SID_VAL}PDB"
  ORACLE_PDB_VAL="$REPLY"
else
  ask "추가 PDB 서비스 이름 (기본 XEPDB1 외에 추가 생성, 비워두면 생성 안 함)" ""
  ORACLE_DATABASE_VAL="$REPLY"
fi

ask "문자셋 (한글 지원: AL32UTF8 권장)" "AL32UTF8"
CHARSET="$REPLY"

ask "리스너 포트" "1521"
LISTENER_PORT="$REPLY"
if port_in_use "$LISTENER_PORT"; then
  warn "포트 ${LISTENER_PORT}은(는) 이미 사용 중인 것으로 보입니다. 계속 진행하면 실행 시 실패할 수 있습니다."
fi

if [[ "$EDITION" == "1" ]]; then
  ask "EM Express(관리 콘솔) 포트" "5500"
  EM_PORT="$REPLY"
fi

echo
warn "SYS/SYSTEM 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
ask_secret "SYS/SYSTEM 초기 비밀번호"
DB_PASSWORD="$REPLY"
if [[ ${#DB_PASSWORD} -lt 8 ]]; then
  warn "8자 미만입니다. Oracle 권장 규칙(8자 이상, 대/소문자+숫자 포함)을 벗어나면 생성 중 경고가 뜨지만, 보통 생성 자체는 계속 진행됩니다."
fi

if confirm "데이터를 컨테이너 삭제 후에도 유지할까요? (볼륨 마운트)"; then
  PERSIST=1
  ask "볼륨 이름" "${CONTAINER_NAME}-data"
  VOLUME_NAME="$REPLY"
else
  PERSIST=0
fi

# ---------- 4. 최종 확인 ----------
echo
echo "======================= 실행 요약 ======================="
echo " 에디션        : $EDITION_NAME"
echo " 이미지        : $IMAGE"
echo " 컨테이너 이름 : $CONTAINER_NAME"
if [[ "$EDITION" == "1" ]]; then
  echo " SID / PDB     : $ORACLE_SID_VAL / $ORACLE_PDB_VAL"
else
  echo " 추가 PDB      : ${ORACLE_DATABASE_VAL:-(생성 안 함, 기본 XEPDB1만 사용)}"
fi
echo " 문자셋        : $CHARSET"
echo " 리스너 포트   : $LISTENER_PORT"
[[ "$EDITION" == "1" ]] && echo " EM 포트       : $EM_PORT"
echo " 데이터 영속성 : $([[ $PERSIST -eq 1 ]] && echo "볼륨 유지 ($VOLUME_NAME)" || echo "휘발성(볼륨 없음)")"
echo " 비밀번호      : (입력됨, 표시 안 함)"
echo "==========================================================="
echo
if ! confirm "위 설정으로 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ---------- 5. 이미지 Pull ----------
info "이미지를 내려받는 중입니다: $IMAGE"
docker pull "$IMAGE"

# ---------- 6. docker run 구성 ----------
RUN_ARGS=(-d --name "$CONTAINER_NAME" -p "${LISTENER_PORT}:1521" --shm-size=1g)
[[ "$EDITION" == "1" ]] && RUN_ARGS+=(-p "${EM_PORT}:5500")

if [[ "$PERSIST" -eq 1 ]]; then
  RUN_ARGS+=(-v "${VOLUME_NAME}:/opt/oracle/oradata")
fi

if [[ "$EDITION" == "1" ]]; then
  RUN_ARGS+=(
    -e "ORACLE_SID=${ORACLE_SID_VAL}"
    -e "ORACLE_PDB=${ORACLE_PDB_VAL}"
    -e "ORACLE_PWD=${DB_PASSWORD}"
    -e "ORACLE_CHARACTERSET=${CHARSET}"
  )
  SERVICE_NAME="$ORACLE_PDB_VAL"
else
  RUN_ARGS+=(
    -e "ORACLE_PASSWORD=${DB_PASSWORD}"
    -e "ORACLE_CHARACTERSET=${CHARSET}"
  )
  [[ -n "${ORACLE_DATABASE_VAL:-}" ]] && RUN_ARGS+=(-e "ORACLE_DATABASE=${ORACLE_DATABASE_VAL}")
  SERVICE_NAME="${ORACLE_DATABASE_VAL:-XEPDB1}"
fi

info "컨테이너를 실행합니다: $CONTAINER_NAME"
docker run "${RUN_ARGS[@]}" "$IMAGE"
unset DB_PASSWORD

# ---------- 7. 기동 대기 ----------
info "DB 초기화를 기다리는 중입니다 (에디션에 따라 2~20분 소요될 수 있습니다)..."
ELAPSED=0
INTERVAL=15
TIMEOUT=1800
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
    warn "제한 시간(${TIMEOUT}s) 내에 healthy 상태가 되지 않았습니다. 계속 기동 중일 수 있으니 'docker logs -f ${CONTAINER_NAME}'로 직접 확인하세요."
    break
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  printf "."
done
echo

# ---------- 8. 접속 정보 안내 ----------
echo
echo "======================= 접속 정보 ======================="
echo " Host       : localhost"
echo " Port       : $LISTENER_PORT"
echo " Service    : $SERVICE_NAME"
echo " 접속 예시  : sqlplus system/<입력한 비밀번호>@localhost:${LISTENER_PORT}/${SERVICE_NAME}"
[[ "$EDITION" == "1" ]] && echo " EM Express : https://localhost:${EM_PORT}/em"
echo "==========================================================="
warn "이 스크립트는 비밀번호/토큰을 어떤 파일에도 저장하지 않았습니다. 필요 시 별도로 안전하게 보관하세요."
