#!/usr/bin/env bash
# ============================================================================
# OmnioneCX 2.0.0.3 컨테이너 안으로 들어가는 명령어 (db/verifier/oacx/admin/sample 공용)
#
# docker-compose.yml의 서비스명을 그대로 쓴다 -- 실제 container_name을
# 무엇으로 지었든 상관없이 동작한다.
#
# 사용법:
#   ./exec.sh db           # db 컨테이너 안에서 sh 실행 (기본 셸)
#   ./exec.sh verifier      # verifier 컨테이너 안에서 sh 실행
#   ./exec.sh oacx bash     # oacx 컨테이너 안에서 bash 실행 (셸 직접 지정)
#
# db에 SQL 클라이언트로 바로 붙고 싶으면:
#   ./exec.sh db mariadb -uroot -p
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICE="${1:-}"
shift || true

if [[ -z "$SERVICE" || ! "$SERVICE" =~ ^(db|verifier|oacx|admin|sample)$ ]]; then
  echo "사용법: $0 <db|verifier|oacx|admin|sample> [실행할 명령, 기본값: sh]" >&2
  exit 1
fi

CMD=("$@")
[[ "${#CMD[@]}" -eq 0 ]] && CMD=(sh)

ENV_FILE="${SCRIPT_DIR}/.staging/omnionecx.env"
if [[ -f "$ENV_FILE" ]]; then
  COMPOSE_PROJECT="$(grep -oE '^COMPOSE_PROJECT=.*' "$ENV_FILE" | head -n1 | cut -d= -f2-)"
  COMPOSE_PROJECT="${COMPOSE_PROJECT:-omnionecx-2003}"
  exec docker compose -f docker-compose.yml -p "$COMPOSE_PROJECT" --env-file "$ENV_FILE" exec "$SERVICE" "${CMD[@]}"
else
  exec docker compose -p omnionecx-2003 exec "$SERVICE" "${CMD[@]}"
fi
