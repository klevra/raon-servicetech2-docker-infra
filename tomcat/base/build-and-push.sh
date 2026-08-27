#!/usr/bin/env bash
# ============================================================================
# Tomcat 실행 베이스 이미지 빌드 + servicetech2 레지스트리 push 스크립트 (bash)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 대상      : v1의 oacx(WAR) 등 Tomcat 애플리케이션. 별도 ENTRYPOINT 커스터마이징
#             없음 (공식 이미지 그대로 재태깅) — WAR/설정은 배포 시점에 주입.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"
IMAGE_KIND="tomcat9-jdk8"

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
echo " Tomcat 실행 베이스 이미지 빌드 + servicetech2 레지스트리 등록"
echo "=============================================================="

echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"

echo
echo "베이스로 사용할 Tomcat 이미지 태그를 선택하세요 (OmnioneCX v1: Tomcat 9 + JDK8):"
echo "  1) 9-jdk8-temurin  (기본값)"
ask "번호 선택" "1"
case "$REPLY" in
  1) UPSTREAM_IMAGE="tomcat:9-jdk8-temurin"; TAG="9-jdk8" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
TARGET_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${IMAGE_KIND}:${TAG}"
ok "선택됨: $UPSTREAM_IMAGE → $TARGET_IMAGE"

if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi

info "상위 이미지를 내려받는 중입니다: $UPSTREAM_IMAGE"
if ! docker pull "$UPSTREAM_IMAGE"; then
  err "상위 이미지 pull 실패. 네트워크 상태를 확인하고 재시도하세요."
  exit 1
fi

info "베이스 이미지를 빌드합니다: $TARGET_IMAGE"
if ! docker build --build-arg "BASE_IMAGE=${UPSTREAM_IMAGE}" -t "$TARGET_IMAGE" -f Dockerfile .; then
  err "이미지 빌드 실패."
  exit 1
fi

info "레지스트리로 push 합니다: $TARGET_IMAGE"
if ! docker push "$TARGET_IMAGE"; then
  err "레지스트리 push 실패 (네트워크 타임아웃 등). 재시도하려면 이 스크립트를 다시 실행하거나 'docker push ${TARGET_IMAGE}'를 직접 실행하세요."
  exit 1
fi

info "push 결과를 재확인합니다..."
TAGS_JSON="$(curl -sf "http://${LOCAL_REGISTRY}/v2/${NAMESPACE}/${IMAGE_KIND}/tags/list" 2>/dev/null || echo "")"
if [[ -z "$TAGS_JSON" ]] || ! grep -q "\"${TAG}\"" <<< "$TAGS_JSON"; then
  err "push 명령은 끝났지만 레지스트리에서 해당 태그가 확인되지 않습니다 (일부 레이어 업로드 실패 가능성). 'docker push ${TARGET_IMAGE}'를 다시 실행하세요."
  exit 1
fi
ok "레지스트리에서 태그 확인 완료"

echo
echo "======================= 완료 ======================="
echo " 상위 이미지   : $UPSTREAM_IMAGE"
echo " 등록된 이미지 : $TARGET_IMAGE"
echo "======================================================"
