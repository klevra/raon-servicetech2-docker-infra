#!/usr/bin/env bash
# ============================================================================
# OmnioneCX DB — 저축은행중앙회(fsb) 전용 이미지 빌드 + servicetech2 레지스트리 push
#
# initdb/ 안의 DDL/DML은 이 사이트 전용 데이터를 이미 반영한 상태(git으로
# 추적, 민감정보 없음 -- 스키마와 초기 참조 데이터일 뿐).
# 대상 베이스: mariadb/base로 이미 레지스트리에 등록된 servicetech2/mariadb 이미지.
#
# db/verifier/oacx는 각각 하나의 리포지토리로 통합 관리된다. DB는 자체
# 버전 번호가 없어 보통 사이트 코드 하나만 태그로 쓰지만(버전=사이트 코드로
# 동일하게 입력하면 태그 1개만 push됨), 참고용 라벨을 별도로 남기고 싶으면
# 서로 다른 값을 입력해도 된다(그 경우 2개 push).
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"
IMAGE_KIND="omnionecx-db"
SITE="저축은행중앙회(fsb)"
DEFAULT_SITE_TAG="fsb"
DEFAULT_VERSION="fsb"

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

confirm() {
  local prompt="${1:-계속 진행할까요?}" reply
  read -r -p "$prompt (y/n) [y]: " reply
  reply="${reply:-y}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

echo "=============================================================="
echo " OmnioneCX DB (${SITE}) 이미지 빌드 + 레지스트리 등록"
echo "=============================================================="

# ============================================================================
# 0. 사전 체크리스트
# ============================================================================
echo
echo "-------- 사전 체크리스트 --------"
if ! confirm "이번에 반영할 DDL/DML(initdb/) 업데이트가 하나만 있습니까? (여러 변경사항이 섞여있지 않은지 확인)"; then
  err "체크리스트 확인에서 중단했습니다. 변경사항을 하나로 정리한 뒤 다시 실행하세요."
  exit 1
fi
if ! confirm "이번 업데이트 내용(무엇이, 왜 바뀌었는지)을 정확히 파악하고 계십니까?"; then
  err "체크리스트 확인에서 중단했습니다. 업데이트 내용을 먼저 확인하세요."
  exit 1
fi

# ============================================================================
# 1. 사이트 코드 / 버전 정보 / 레지스트리 주소
# ============================================================================
echo
ask "사이트 코드 (이동 태그로 사용 -- 이 사이트가 현재 쓰는 이미지를 가리킴)" "$DEFAULT_SITE_TAG"
SITE_TAG="$REPLY"
ask "참고용 버전/라벨 (DB는 자체 버전이 없음 -- 사이트 코드와 같은 값이면 태그 1개만 push)" "$DEFAULT_VERSION"
VERSION="$REPLY"

echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"
if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi

TARGET_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${IMAGE_KIND}:${VERSION}"
MOVING_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${IMAGE_KIND}:${SITE_TAG}"
BASE_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/mariadb:latest"

# ============================================================================
# 2. 최종 요약 + 실행 확인
# ============================================================================
echo
{
echo "======================= 실행 요약 ======================="
echo " 사이트        : $SITE"
echo " 레지스트리    : $LOCAL_REGISTRY"
echo " 베이스 이미지 : $BASE_IMAGE"
echo " 등록될 이미지 : $TARGET_IMAGE"
if [[ "$VERSION" != "$SITE_TAG" ]]; then
echo "              : $MOVING_IMAGE (이동 태그, 이 사이트가 현재 쓰는 이미지)"
fi
echo "==========================================================="
}
if ! confirm "위 내용으로 빌드하고 레지스트리로 push할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ============================================================================
# 3. 빌드 + push
# ============================================================================
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

PUSH_TARGETS=("$TARGET_IMAGE")
if [[ "$VERSION" != "$SITE_TAG" ]]; then
  docker tag "$TARGET_IMAGE" "$MOVING_IMAGE"
  PUSH_TARGETS+=("$MOVING_IMAGE")
fi

for img in "${PUSH_TARGETS[@]}"; do
  info "레지스트리로 push 합니다: $img"
  if ! docker push "$img"; then
    err "레지스트리 push 실패 (네트워크 타임아웃 등). 재시도하려면 이 스크립트를 다시 실행하거나 'docker push ${img}'를 직접 실행하세요."
    exit 1
  fi
done

info "push 결과를 재확인합니다..."
TAGS_JSON="$(curl -sf "http://${LOCAL_REGISTRY}/v2/${NAMESPACE}/${IMAGE_KIND}/tags/list" 2>/dev/null || echo "")"
MISSING=0
for t in "$VERSION" "$SITE_TAG"; do
  grep -q "\"${t}\"" <<< "$TAGS_JSON" || MISSING=1
done
if [[ -z "$TAGS_JSON" || "$MISSING" -eq 1 ]]; then
  err "push 명령은 끝났지만 레지스트리에서 태그가 모두 확인되지 않습니다."
  exit 1
fi
ok "레지스트리에서 태그 확인 완료"

echo
{
echo "======================= 완료 ======================="
echo " 등록된 이미지 : $TARGET_IMAGE"
if [[ "$VERSION" != "$SITE_TAG" ]]; then
echo "              : $MOVING_IMAGE"
fi
echo "======================================================"
}
