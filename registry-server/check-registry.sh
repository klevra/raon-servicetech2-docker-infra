#!/usr/bin/env bash
# ============================================================================
# 사내 Docker Registry 상태/영속성 점검 (servicetech2, 192.168.0.168:5000)
#
# 두 가지 모드로 동작한다 (실행 위치를 자동 감지):
#
#  [서버 모드]  레지스트리 컨테이너가 있는 호스트(new-servicetech2-1)에서 실행
#              → 볼륨 마운트 / restart 정책 / delete API 설정 / 저장 경로 용량 /
#                디스크 여유 공간까지 전부 점검한다. "컨테이너가 날아가도
#                데이터가 남는가"를 실제로 확인하는 게 목적.
#
#  [클라이언트 모드]  팀원 PC 등 원격에서 실행 (SSH 없이 HTTP만)
#              → API 응답 / 저장소 목록 / 실제 blob을 하나 받아와서 스토리지
#                백엔드가 살아있는지(빈 레지스트리가 아니라 데이터가 실재하는지)
#                까지만 확인한다.
#
# 사용법:
#   ./check-registry.sh                 # 자동 감지
#   REGISTRY_ADDR=host:port ./check-registry.sh
#   REGISTRY_CONTAINER=registry ./check-registry.sh   # 서버 모드 컨테이너명 지정
# ============================================================================
set -uo pipefail

REGISTRY_ADDR="${REGISTRY_ADDR:-192.168.0.168:5000}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-registry}"
# 데이터 실재 확인용 참조 이미지 (작고, 항상 있어야 하는 것)
PROBE_REPO="${PROBE_REPO:-servicetech2/omnionecx2-oacx}"
PROBE_TAG="${PROBE_TAG:-aia}"

c_reset='\033[0m'; c_green='\033[32m'; c_yellow='\033[33m'; c_red='\033[31m'; c_cyan='\033[36m'
ok()   { printf "${c_green}[OK]${c_reset}   %s\n" "$1"; }
warn() { printf "${c_yellow}[경고]${c_reset} %s\n" "$1"; }
err()  { printf "${c_red}[실패]${c_reset} %s\n" "$1"; }
info() { printf "${c_cyan}[정보]${c_reset} %s\n" "$1"; }

FAIL=0

echo "=============================================================="
echo " 사내 Docker Registry 점검 — ${REGISTRY_ADDR}"
echo "=============================================================="

# ============================================================================
# 공통: HTTP API 점검 (서버/클라이언트 둘 다)
# ============================================================================
echo
echo "-------- 1. HTTP API --------"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${REGISTRY_ADDR}/v2/" 2>/dev/null)"
if [[ "$code" == "200" ]]; then
  ok "/v2/ 응답 200 (레지스트리 살아있음)"
else
  err "/v2/ 응답 코드: ${code:-없음} — 레지스트리에 접근 불가"
  FAIL=1
fi

CATALOG="$(curl -s --max-time 5 "http://${REGISTRY_ADDR}/v2/_catalog?n=200" 2>/dev/null)"
REPO_COUNT="$(grep -o '"servicetech2/[^"]*"' <<<"$CATALOG" | wc -l | tr -d ' ')"
if [[ "${REPO_COUNT:-0}" -gt 0 ]]; then
  ok "_catalog 조회 성공 — 저장소 ${REPO_COUNT}개"
else
  err "_catalog가 비어있거나 조회 실패 — 스토리지가 비었을 수 있음"
  FAIL=1
fi

# ============================================================================
# 공통: 실제 데이터 실재 확인 — manifest + blob 을 실제로 받아본다
#   (레지스트리가 200을 주더라도 스토리지 볼륨이 비면 이 단계에서 걸린다)
# ============================================================================
echo
echo "-------- 2. 데이터 실재 확인 (${PROBE_REPO}:${PROBE_TAG}) --------"
MF_ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
MANIFEST="$(curl -s --max-time 8 -H "Accept: ${MF_ACCEPT}" \
  "http://${REGISTRY_ADDR}/v2/${PROBE_REPO}/manifests/${PROBE_TAG}" 2>/dev/null)"

# manifest list / OCI index(멀티플랫폼·attestation 포함)면 platform이 실제 os/arch인
# 첫 자식 매니페스트 digest로 한 번 더 들어간다 (unknown/unknown = attestation은 건너뜀)
if grep -q '"manifests"' <<<"$MANIFEST"; then
  CHILD="$(grep -oE '"digest"[^,}]*|"architecture"[^,}]*' <<<"$MANIFEST" \
    | awk '/"digest"/{d=$0} /"architecture"/{ if ($0 !~ /unknown/ && d != "") { print d; exit } }' \
    | grep -oE 'sha256:[a-f0-9]+')"
  [[ -z "$CHILD" ]] && CHILD="$(grep -oE 'sha256:[a-f0-9]+' <<<"$MANIFEST" | head -n1)"
  if [[ -n "$CHILD" ]]; then
    MANIFEST="$(curl -s --max-time 8 -H "Accept: ${MF_ACCEPT}" \
      "http://${REGISTRY_ADDR}/v2/${PROBE_REPO}/manifests/${CHILD}" 2>/dev/null)"
  fi
fi

# config 또는 layers 중 아무 blob digest 하나 (마지막 = 보통 가장 작은 레이어)
BLOB_DIGEST="$(grep -oE 'sha256:[a-f0-9]{64}' <<<"$MANIFEST" | tail -n1)"
if [[ -z "$BLOB_DIGEST" ]]; then
  err "manifest에서 blob digest를 찾지 못함 — 참조 이미지(${PROBE_REPO}:${PROBE_TAG})가 없거나 manifest 손상"
  warn "다른 이미지로 확인하려면: PROBE_REPO=... PROBE_TAG=... $0"
  FAIL=1
else
  blob_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -I \
    "http://${REGISTRY_ADDR}/v2/${PROBE_REPO}/blobs/${BLOB_DIGEST}" 2>/dev/null)"
  if [[ "$blob_code" == "200" ]]; then
    ok "blob ${BLOB_DIGEST:0:19}... 존재 확인 (스토리지 백엔드 정상, 데이터 실재함)"
  else
    err "blob HEAD 응답 ${blob_code} — manifest는 있는데 실제 레이어가 없음 (스토리지 유실 의심)"
    FAIL=1
  fi
fi

# ============================================================================
# 서버 모드: 레지스트리 컨테이너를 로컬에서 볼 수 있으면 영속성 설정 점검
# ============================================================================
echo
if command -v docker >/dev/null 2>&1 && docker inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
  echo "-------- 3. [서버 모드] 컨테이너 영속성 설정 --------"
  info "컨테이너 '${REGISTRY_CONTAINER}' 를 로컬에서 찾음 — 상세 점검 진행"

  # 3-1. /var/lib/registry 마운트
  MOUNT_JSON="$(docker inspect "$REGISTRY_CONTAINER" --format '{{json .Mounts}}' 2>/dev/null)"
  MOUNT_SRC="$(docker inspect "$REGISTRY_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Type}}|{{.Source}}|{{.Name}}{{end}}{{end}}' 2>/dev/null)"
  if [[ -n "$MOUNT_SRC" ]]; then
    m_type="${MOUNT_SRC%%|*}"; rest="${MOUNT_SRC#*|}"; m_src="${rest%%|*}"; m_name="${rest#*|}"
    ok "/var/lib/registry 마운트 있음 — type=${m_type} source=${m_src} ${m_name:+name=$m_name}"
    if [[ -d "$m_src" ]]; then
      SIZE="$(du -sh "$m_src" 2>/dev/null | cut -f1)"
      NBLOB="$(find "$m_src" -type f -path '*/blobs/*/data' 2>/dev/null | wc -l | tr -d ' ')"
      ok "저장 경로 실재 — 용량 ${SIZE:-?}, blob 파일 약 ${NBLOB}개"
    else
      warn "마운트 source 경로를 이 셸에서 직접 볼 수 없음 (rootless/네임스페이스 등) — docker exec로 확인 권장"
    fi
  else
    err "/var/lib/registry 에 볼륨/바인드 마운트가 없음 → 컨테이너 삭제 시 전체 이미지 유실"
    echo "     현재 Mounts: $MOUNT_JSON"
    FAIL=1
  fi

  # 3-2. restart 정책
  RP="$(docker inspect "$REGISTRY_CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)"
  case "$RP" in
    always|unless-stopped) ok "restart 정책: ${RP} (서버 리부팅 시 자동 복구됨)";;
    ""|no) err "restart 정책: ${RP:-없음} → 서버 리부팅 시 레지스트리 안 뜸"; FAIL=1;;
    *) warn "restart 정책: ${RP}";;
  esac

  # 3-3. delete API
  DEL="$(docker inspect "$REGISTRY_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -i 'REGISTRY_STORAGE_DELETE_ENABLED' || true)"
  if grep -qi 'true' <<<"$DEL"; then
    ok "delete API 활성 (${DEL}) — 태그 정리 가능"
  else
    warn "delete API 비활성 (환경변수 없음) — 태그/저장소 정리하려면 REGISTRY_STORAGE_DELETE_ENABLED=true 로 재구성 필요"
  fi

  # 3-4. 디스크 여유
  echo
  info "레지스트리 저장 경로가 속한 파티션 여유 공간:"
  if [[ -n "${m_src:-}" && -d "${m_src:-/nonexistent}" ]]; then
    df -h "$m_src" 2>/dev/null | sed 's/^/     /'
  else
    df -h /var/lib/docker 2>/dev/null | sed 's/^/     /'
  fi

  # 3-5. 업타임
  STARTED="$(docker inspect "$REGISTRY_CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null)"
  info "컨테이너 기동 시각: ${STARTED}"
else
  echo "-------- 3. [클라이언트 모드] --------"
  info "이 호스트에는 레지스트리 컨테이너가 없음 (또는 docker 미설치) — HTTP 점검까지만 수행함."
  info "볼륨 마운트/restart 정책 확인은 레지스트리 서버(new-servicetech2-1)에서 이 스크립트를 실행하세요:"
  info "  docker inspect ${REGISTRY_CONTAINER} --format '{{json .Mounts}}'"
  info "  docker inspect ${REGISTRY_CONTAINER} --format '{{.HostConfig.RestartPolicy.Name}}'"
fi

echo
echo "=============================================================="
if [[ "$FAIL" -eq 0 ]]; then
  ok "치명적 문제 없음"
  exit 0
else
  err "위 [실패] 항목 확인 필요"
  exit 1
fi
