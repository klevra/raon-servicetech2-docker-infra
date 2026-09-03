#!/usr/bin/env bash
# ============================================================================
# OmnioneCX verifier — 우리투자증권(wooriib) 전용 이미지(1.3.25_fix) 빌드 + push
#
# 전제조건: 이 스크립트와 같은 위치의 app/ 안에 실제 verifier 실행 산출물
#           (mdl-verifier-1.3.25-fix.jar, jdbc/ 등)이 있어야 한다. app/은
#           실제 배포 산출물이라 git에는 커밋하지 않음 (.gitignore 확인).
# 대상 베이스: jdk8/base로 이미 레지스트리에 등록된 servicetech2/jdk8 이미지.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"
IMAGE_KIND="omnionecx-verifier-wooriib"
VERSION="1.3.25_fix"   # 이 사이트에 고정된 verifier 버전

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
echo " OmnioneCX verifier (우리투자증권/wooriib) ${VERSION} 이미지 빌드 + 레지스트리 등록"
echo "=============================================================="

if [[ ! -d "${SCRIPT_DIR}/app" ]]; then
  err "app/ 폴더가 없습니다: ${SCRIPT_DIR}/app (실제 verifier 산출물을 먼저 복사하세요)"
  exit 1
fi
JAR_COUNT=0
for f in "${SCRIPT_DIR}/app"/mdl-verifier-1.*.jar; do
  [[ -f "$f" ]] && JAR_COUNT=$((JAR_COUNT + 1))
done
if [[ "$JAR_COUNT" -ne 1 ]]; then
  err "app/ 안에 mdl-verifier-1.*.jar 파일이 정확히 1개 있어야 합니다 (현재 ${JAR_COUNT}개)."
  exit 1
fi

echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"
if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi

TARGET_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${IMAGE_KIND}:${VERSION}"
BASE_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/jdk8:latest"

info "베이스 이미지를 내려받는 중입니다: $BASE_IMAGE"
if ! docker pull "$BASE_IMAGE"; then
  err "베이스 이미지 pull 실패. jdk8/base/build-and-push.sh 로 먼저 등록하세요."
  exit 1
fi

info "이미지를 빌드합니다: $TARGET_IMAGE"
if ! docker build --build-arg "BASE_IMAGE=${BASE_IMAGE}" -t "$TARGET_IMAGE" -f Dockerfile .; then
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
if [[ -z "$TAGS_JSON" ]] || ! grep -q "\"${VERSION}\"" <<< "$TAGS_JSON"; then
  err "push 명령은 끝났지만 레지스트리에서 해당 태그가 확인되지 않습니다 (일부 레이어 업로드 실패 가능성). 'docker push ${TARGET_IMAGE}'를 다시 실행하세요."
  exit 1
fi
ok "레지스트리에서 태그 확인 완료"

echo
echo "======================= 완료 ======================="
echo " 베이스 이미지 : $BASE_IMAGE"
echo " 등록된 이미지 : $TARGET_IMAGE"
echo "======================================================"
