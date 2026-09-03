#!/usr/bin/env bash
# ============================================================================
# OmnioneCX 저축은행중앙회(fsb) 컨테이너 안으로 들어가는 명령어 (db/verifier/oacx 공용)
#
# docker-compose.yml의 서비스명(db/verifier/oacx)을 그대로 쓴다 -- 실제
# container_name을 무엇으로 지었든(예: mariadb-omnionecx) 상관없이 동작한다.
#
# 사용법:
#   ./exec.sh db          # db 컨테이너 안에서 sh 실행 (기본 셸)
#   ./exec.sh verifier     # verifier 컨테이너 안에서 sh 실행
#   ./exec.sh oacx bash    # oacx 컨테이너 안에서 bash 실행 (셸 직접 지정)
#
# db에 SQL 클라이언트로 바로 붙고 싶으면:
#   ./exec.sh db mariadb -uroot -p
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICE="${1:-}"
shift || true

if [[ -z "$SERVICE" || ! "$SERVICE" =~ ^(db|verifier|oacx)$ ]]; then
  echo "사용법: $0 <db|verifier|oacx> [실행할 명령, 기본값: sh]" >&2
  exit 1
fi

CMD=("$@")
[[ "${#CMD[@]}" -eq 0 ]] && CMD=(sh)

ENV_FILE="${SCRIPT_DIR}/.staging/omnionecx.env"
if [[ -f "$ENV_FILE" ]]; then
  exec docker compose -f docker-compose.yml -p omnionecx-fsb --env-file "$ENV_FILE" exec "$SERVICE" "${CMD[@]}"
else
  # .staging/omnionecx.env가 없으면(예: deploy 스크립트를 거치지 않고 직접
  # docker compose로 띄운 경우) -p(프로젝트명)만으로 접속을 시도한다.
  exec docker compose -p omnionecx-fsb exec "$SERVICE" "${CMD[@]}"
fi
