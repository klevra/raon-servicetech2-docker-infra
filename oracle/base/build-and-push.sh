#!/usr/bin/env bash
# ============================================================================
# Oracle 베이스 이미지 빌드 + servicetech2 레지스트리 push 스크립트 (bash)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
#
# 라이선스 주의사항
#   - 19c Enterprise Edition : Oracle 공식 OTN 라이선스(개발/테스트/데모 목적 무료).
#     Oracle 계정 + container-registry.oracle.com 라이선스 동의 + Auth Token 필요.
#   - 21c/18c Express Edition(XE) : 완전 무료, 커뮤니티(gvenzl) 빌드 이미지, 계정 불필요.
#   - 운영(production) 환경 사용 금지. 테스트/개발/데모 전용.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGISTRY_HOST="container-registry.oracle.com"
NAMESPACE="servicetech2"

# .env가 있으면 ORACLE_REGISTRY_USER / ORACLE_AUTH_TOKEN을 읽어온다 (없으면 나중에 직접 입력받음).
# .env는 .gitignore에 등록되어 있으며, 토큰은 절대 커밋되지 않는다.
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

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

echo "=============================================================="
echo " Oracle 베이스 이미지 빌드 + servicetech2 레지스트리 등록"
echo "=============================================================="

# ---------- 0. 대상 레지스트리 주소 ----------
# 개발 PC: localhost:5000 (이 PC에서 만든 로컬 레지스트리)
# 팀서버(new-servicetech2-1, 192.168.0.168): servicetech2:5000
# (hosts 파일 등록 + insecure-registry 등록 필요, registry-server/linux-registry-setup.md 참고)
echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-localhost:5000}"
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

# ---------- 2. Oracle 버전 선택 ----------
echo
echo "Oracle 버전을 선택하세요:"
echo "  1) 19c Enterprise Edition  (공식 레지스트리, Oracle 계정 필요)"
echo "  2) 21c Express Edition XE  (커뮤니티 이미지, 계정 불필요)"
echo "  3) 18c Express Edition XE  (커뮤니티 이미지, 계정 불필요, 레거시 호환용)"
ask "번호 선택" "1"
EDITION="$REPLY"

case "$EDITION" in
  1)
    UPSTREAM_IMAGE="${REGISTRY_HOST}/database/enterprise:19.3.0.0"
    TAG="19c"
    NEEDS_LOGIN=1
    ;;
  2)
    UPSTREAM_IMAGE="gvenzl/oracle-xe:21-slim"
    TAG="21c-xe"
    NEEDS_LOGIN=0
    ;;
  3)
    UPSTREAM_IMAGE="gvenzl/oracle-xe:18-slim"
    TAG="18c-xe"
    NEEDS_LOGIN=0
    ;;
  *)
    err "잘못된 선택입니다."; exit 1
    ;;
esac
TARGET_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${TAG}"
ok "선택됨: $UPSTREAM_IMAGE → $TARGET_IMAGE"

# ---------- 3. (EE 전용) 로그인 ----------
if [[ "$NEEDS_LOGIN" -eq 1 ]]; then
  echo
  info "Enterprise Edition은 Oracle 계정 인증이 필요합니다."
  if DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect "$UPSTREAM_IMAGE" >/dev/null 2>&1; then
    ok "이미 로그인/캐시된 자격증명으로 이미지 접근이 가능합니다. 로그인 단계를 건너뜁니다."
  else
    warn "먼저 브라우저에서 아래를 완료해야 합니다:"
    echo "   1) https://${REGISTRY_HOST} 접속 후 로그인"
    echo "   2) Database > enterprise 리포지터리 라이선스 동의(Continue)"
    echo "   3) 계정 아이콘 > Auth Token 메뉴에서 토큰 발급"
    echo

    if [[ -n "${ORACLE_REGISTRY_USER:-}" && -n "${ORACLE_AUTH_TOKEN:-}" ]]; then
      ok ".env에서 계정(${ORACLE_REGISTRY_USER})과 토큰을 읽었습니다. 대화형 입력을 건너뜁니다."
      ORACLE_USER="$ORACLE_REGISTRY_USER"
      AUTH_TOKEN="$ORACLE_AUTH_TOKEN"
    else
      read -r -p "위 단계를 완료했으면 Enter를 눌러 계속하세요..." _
      ask "Oracle 계정 이메일(Username)" "${ORACLE_REGISTRY_USER:-}"
      ORACLE_USER="$REPLY"
      ask_secret "Auth Token"
      AUTH_TOKEN="$REPLY"
    fi

    if ! printf '%s' "$AUTH_TOKEN" | docker login "$REGISTRY_HOST" --username "$ORACLE_USER" --password-stdin; then
      err "로그인 실패. Auth Token 또는 라이선스 동의 상태를 다시 확인하세요. (.env의 ORACLE_AUTH_TOKEN이 비어있지 않은지도 확인)"
      exit 1
    fi
    unset AUTH_TOKEN
    ok "로그인 성공"
  fi
fi

# ---------- 4. 로컬 레지스트리 확인 ----------
if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi

# ---------- 5. 상위 이미지 pull ----------
info "상위 이미지를 내려받는 중입니다: $UPSTREAM_IMAGE"
docker pull "$UPSTREAM_IMAGE"

# ---------- 6. 빌드 ----------
info "베이스 이미지를 빌드합니다: $TARGET_IMAGE"
docker build --build-arg "BASE_IMAGE=${UPSTREAM_IMAGE}" -t "$TARGET_IMAGE" -f Dockerfile .

# ---------- 7. push ----------
info "레지스트리로 push 합니다: $TARGET_IMAGE"
docker push "$TARGET_IMAGE"

echo
echo "======================= 완료 ======================="
echo " 상위 이미지   : $UPSTREAM_IMAGE"
echo " 등록된 이미지 : $TARGET_IMAGE"
echo "======================================================"
