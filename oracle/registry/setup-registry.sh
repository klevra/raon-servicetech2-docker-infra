#!/usr/bin/env bash
# ============================================================================
# 로컬 프라이빗 Docker Registry(servicetech2) 구축 스크립트 (bash)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 주의      : 로컬(localhost) 전용입니다. 외부에 노출하지 마세요
#             (인증/TLS 미적용 상태입니다).
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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

echo "=============================================================="
echo " 로컬 프라이빗 Docker Registry 구축 (servicetech2)"
echo " (로컬 전용 — 외부 노출 금지)"
echo "=============================================================="
echo

ask "레지스트리 포트" "5000"
REGISTRY_PORT="$REPLY"

echo "REGISTRY_PORT=${REGISTRY_PORT}" > .env
ok ".env 파일 작성 완료 (REGISTRY_PORT=${REGISTRY_PORT})"

info "레지스트리 컨테이너를 기동합니다..."
docker compose up -d

info "정상 기동 대기 중..."
for i in $(seq 1 20); do
  if curl -sf "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    ok "레지스트리가 http://localhost:${REGISTRY_PORT} 에서 응답합니다."
    break
  fi
  sleep 1
  if [[ "$i" -eq 20 ]]; then
    err "레지스트리가 응답하지 않습니다. 'docker logs servicetech2-registry'로 확인하세요."
    exit 1
  fi
done

# ---------- 스모크 테스트: 실제 push/pull 왕복 확인 ----------
info "스모크 테스트: 작은 이미지로 push/pull 왕복 확인 중..."
SMOKE_TAG="localhost:${REGISTRY_PORT}/servicetech2/smoke-test:latest"
docker pull hello-world >/dev/null
docker tag hello-world "$SMOKE_TAG"
if docker push "$SMOKE_TAG" >/dev/null 2>&1; then
  ok "push 성공"
else
  err "push 실패. 레지스트리 상태를 확인하세요."
  exit 1
fi
docker rmi "$SMOKE_TAG" >/dev/null 2>&1 || true
if docker pull "$SMOKE_TAG" >/dev/null 2>&1; then
  ok "pull 성공 — 레지스트리가 정상 동작합니다."
else
  err "pull 실패."
  exit 1
fi
docker rmi "$SMOKE_TAG" >/dev/null 2>&1 || true

echo
echo "======================= 완료 ======================="
echo " 레지스트리 주소 : localhost:${REGISTRY_PORT}"
echo " 네임스페이스    : servicetech2"
echo " 이미지 네이밍 예: localhost:${REGISTRY_PORT}/servicetech2/oracle:19c"
echo "======================================================"
