#!/usr/bin/env bash
# ============================================================================
# OmnioneCX DB 버전 고정 이미지(1.0.0.12) 빌드 + servicetech2 레지스트리 push
#
# initdb/ 안의 DDL/DML은 git으로 추적되는 소스다 (민감정보 없음 -- 스키마와
# 초기 참조 데이터일 뿐). verifier/oacx와 달리 이 이미지는 실제 앱 산출물이
# 필요 없어 바로 빌드 가능하다.
# 대상 베이스: mariadb/base로 이미 레지스트리에 등록된 servicetech2/mariadb 이미지.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"
IMAGE_KIND="omnionecx-db"
VERSION="$(basename "$(dirname "$SCRIPT_DIR")")"   # 상위 폴더명(예: 1.0.0.12)을 버전으로 사용

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
echo " OmnioneCX DB ${VERSION} 이미지 빌드 + 레지스트리 등록"
echo "=============================================================="

echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"
if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi

TARGET_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${IMAGE_KIND}:${VERSION}"
BASE_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/mariadb:latest"

info "베이스 이미지를 내려받는 중입니다: $BASE_IMAGE"
if ! docker pull "$BASE_IMAGE"; then
  err "베이스 이미지 pull 실패. mariadb/base/build-and-push.sh 로 먼저 등록하세요."
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
  err "push 명령은 끝났지만 레지스트리에서 해당 태그가 확인되지 않습니다."
  exit 1
fi
ok "레지스트리에서 태그 확인 완료"

echo
echo "======================= 완료 ======================="
echo " 베이스 이미지 : $BASE_IMAGE"
echo " 등록된 이미지 : $TARGET_IMAGE"
echo "======================================================"
