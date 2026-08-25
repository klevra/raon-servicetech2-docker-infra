#!/usr/bin/env bash
# ============================================================================
# MySQL 베이스 이미지 빌드 + servicetech2 레지스트리 push 스크립트 (bash)
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
#
# 라이선스 주의사항
#   - MySQL Community Server는 완전 오픈소스(GPLv2)이며 Docker Hub 공식 이미지
#     사용에 별도 계정/라이선스 동의가 필요 없다 (Oracle EE와 달리 로그인 불필요).
#   - 운영(production) 환경 사용 금지. 테스트/개발/데모 전용.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="servicetech2"

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
echo " MySQL 베이스 이미지 빌드 + servicetech2 레지스트리 등록"
echo "=============================================================="

# ---------- 0. 대상 레지스트리 주소 ----------
# 개발 PC: localhost:5000 / 팀서버(new-servicetech2-1, 192.168.0.168): servicetech2:5000
# (hosts 파일 등록 + insecure-registry 등록 필요, registry-server/linux-registry-setup.md 참고)
echo
ask "대상 레지스트리 주소 (호스트:포트)" "${REGISTRY_ADDR:-192.168.0.168:5000}"
LOCAL_REGISTRY="$REPLY"

# ---------- 1. DB 종류 ----------
echo
echo "DB 종류를 선택하세요 (현재는 MySQL만 지원):"
echo "  1) MySQL"
ask "번호 선택" "1"
if [[ "$REPLY" != "1" ]]; then
  err "현재는 MySQL만 지원합니다."
  exit 1
fi
DB_KIND="mysql"

# ---------- 2. MySQL 버전 선택 ----------
echo
echo "MySQL 버전을 선택하세요 (전부 계정/로그인 불필요, 공개 이미지):"
echo "  1) latest  (최신 안정 버전)"
echo "  2) 8.4     (LTS)"
echo "  3) 8.0     (구버전 LTS, 레거시 호환용)"
ask "번호 선택" "1"
case "$REPLY" in
  1) UPSTREAM_IMAGE="mysql:latest"; TAG="latest" ;;
  2) UPSTREAM_IMAGE="mysql:8.4";    TAG="8.4" ;;
  3) UPSTREAM_IMAGE="mysql:8.0";    TAG="8.0" ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
TARGET_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${TAG}"
ok "선택됨: $UPSTREAM_IMAGE → $TARGET_IMAGE"

# ---------- 3. 로컬 레지스트리 확인 ----------
if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi

# ---------- 4. 상위 이미지 pull ----------
info "상위 이미지를 내려받는 중입니다: $UPSTREAM_IMAGE"
if ! docker pull "$UPSTREAM_IMAGE"; then
  err "상위 이미지 pull 실패. 네트워크 상태를 확인하고 재시도하세요."
  exit 1
fi

# ---------- 5. 빌드 ----------
info "베이스 이미지를 빌드합니다: $TARGET_IMAGE"
if ! docker build --build-arg "BASE_IMAGE=${UPSTREAM_IMAGE}" -t "$TARGET_IMAGE" -f Dockerfile .; then
  err "이미지 빌드 실패."
  exit 1
fi

# ---------- 6. push ----------
info "레지스트리로 push 합니다: $TARGET_IMAGE"
if ! docker push "$TARGET_IMAGE"; then
  err "레지스트리 push 실패 (네트워크 타임아웃 등). 재시도하려면 이 스크립트를 다시 실행하거나 'docker push ${TARGET_IMAGE}'를 직접 실행하세요."
  exit 1
fi

# push 성공 여부를 명령 종료 코드만으로 판단하지 않고, 실제로 태그가 조회되는지 재확인
# 주의: `docker manifest inspect`는 이 프로젝트의 insecure(TLS 미적용) 레지스트리에서
# 실제로는 태그가 정상 존재해도 "no such manifest" 오탐을 내는 경우가 확인됨(2026-08-25) —
# 그래서 레지스트리 REST API(/v2/.../tags/list)를 직접 curl로 조회하는 방식으로 검증한다.
info "push 결과를 재확인합니다..."
TAGS_JSON="$(curl -sf "http://${LOCAL_REGISTRY}/v2/${NAMESPACE}/${DB_KIND}/tags/list" 2>/dev/null || echo "")"
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
