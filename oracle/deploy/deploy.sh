#!/usr/bin/env bash
# ============================================================================
# Oracle 테스트 인스턴스 배포 스크립트 (bash) — servicetech2 레지스트리 기반
#
# 지원 환경 : Linux / macOS / Windows(Git Bash, WSL)
# 전제조건 : oracle/registry/setup-registry.sh, oracle/base/build-and-push.sh
#            가 먼저 실행되어 servicetech2 레지스트리에 이미지가 등록되어 있어야 함
#
# 대화형으로 아래 항목을 입력받습니다:
#   1) DB 종류 (현재 Oracle 고정)   2) Oracle 버전(레지스트리 태그)
#   3) 스키마(SID/PDB)              4) 계정 정보(SYS/SYSTEM 비밀번호)
#   5) DDL SQL 파일 경로             6) 초기데이터 DML SQL 파일 경로
#   7) 포트 (리스너, EE는 EM Express 포함)
#
# 데이터는 휘발성(볼륨 미사용)입니다. 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
# ============================================================================
set -uo pipefail

# Windows Git Bash(MSYS)는 "docker run -v SRC:DEST:MODE" 인자 안의 "/"로 시작하는
# 부분을 전부 Windows 경로로 잘못 변환한다(호스트 경로뿐 아니라 컨테이너 내부 경로까지 오염됨).
# 이 변수를 끄면 MSYS가 인자를 건드리지 않아 정상적으로 바인드마운트된다.
# (Linux/macOS의 순정 bash에는 이 변수가 없어 아무 영향 없음 — 안전하게 항상 설정)
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCAL_REGISTRY="localhost:5000"
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

ask_secret() {
  local prompt="$1"
  read -r -s -p "$prompt: " REPLY
  echo
}

confirm() {
  local prompt="${1:-계속 진행할까요?}" reply
  read -r -p "$prompt (y/n) [y]: " reply
  reply="${reply:-y}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

port_in_use() {
  local port="$1"
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port}->"
}

echo "=============================================================="
echo " Oracle 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
echo " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
echo "=============================================================="

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

# ---------- 2. Oracle 버전(레지스트리 태그) ----------
echo
echo "배포할 Oracle 버전(레지스트리 태그)을 선택하세요:"
echo "  1) 19c  (Enterprise Edition — SID 임의 지정 가능, EM Express 포함)"
echo "  2) 21c-xe  (Express Edition — SID 고정(XE), EM Express 없음)"
echo "  3) 18c-xe  (Express Edition — SID 고정(XE), EM Express 없음)"
ask "번호 선택" "1"
case "$REPLY" in
  1) TAG="19c"; IS_EE=1 ;;
  2) TAG="21c-xe"; IS_EE=0 ;;
  3) TAG="18c-xe"; IS_EE=0 ;;
  *) err "잘못된 선택입니다."; exit 1 ;;
esac
REGISTRY_IMAGE="${LOCAL_REGISTRY}/${NAMESPACE}/${DB_KIND}:${TAG}"

if ! curl -sf "http://${LOCAL_REGISTRY}/v2/" >/dev/null 2>&1; then
  err "로컬 레지스트리(${LOCAL_REGISTRY})가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.sh 를 실행하세요."
  exit 1
fi
info "레지스트리 이미지를 내려받는 중입니다: $REGISTRY_IMAGE"
if ! docker pull "$REGISTRY_IMAGE"; then
  err "이미지를 가져오지 못했습니다. 먼저 oracle/base/build-and-push.sh 로 '${TAG}' 태그를 등록하세요."
  exit 1
fi

DEPLOY_IMAGE="servicetech2/oracle-deploy:${TAG}"
info "배포용 이미지를 빌드합니다: $DEPLOY_IMAGE"
docker build --build-arg "REGISTRY_IMAGE=${REGISTRY_IMAGE}" -t "$DEPLOY_IMAGE" -f Dockerfile .
ok "빌드 완료: $DEPLOY_IMAGE"

# ---------- 3. 컨테이너 이름 ----------
echo
ask "컨테이너 이름" "oracle-${TAG}-deploy"
CONTAINER_NAME="$REPLY"
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  warn "이미 '$CONTAINER_NAME' 이름의 컨테이너가 존재합니다."
  if confirm "기존 컨테이너를 삭제하고 새로 만들까요?"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
    ok "기존 컨테이너 삭제 완료"
  else
    err "컨테이너 이름 충돌로 중단합니다."
    exit 1
  fi
fi

# ---------- 4. 스키마(SID/PDB) ----------
echo
if [[ "$IS_EE" -eq 1 ]]; then
  ask "SID (인스턴스 식별자)" "VERIFIER"
  ORACLE_SID_VAL="$REPLY"
  ask "PDB(Pluggable DB) 이름" "${ORACLE_SID_VAL}PDB"
  ORACLE_PDB_VAL="$REPLY"
  SERVICE_NAME="$ORACLE_PDB_VAL"
else
  warn "Express Edition은 SID가 항상 'XE'로 고정됩니다 (제품 제약)."
  ask "추가 PDB 서비스 이름 (기본 XEPDB1 외 추가 생성, 비우면 생성 안 함)" ""
  ORACLE_DATABASE_VAL="$REPLY"
  SERVICE_NAME="${ORACLE_DATABASE_VAL:-XEPDB1}"
fi
ask "문자셋 (한글 지원: AL32UTF8 권장)" "AL32UTF8"
CHARSET="$REPLY"

# ---------- 5. 계정 정보 ----------
echo
warn "SYS/SYSTEM 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
ask_secret "SYS/SYSTEM 초기 비밀번호"
DB_PASSWORD="$REPLY"
if [[ ${#DB_PASSWORD} -lt 8 ]]; then
  warn "8자 미만입니다. Oracle 권장 규칙(8자 이상, 대/소문자+숫자 포함)을 벗어나면 생성 중 경고가 뜨지만 보통 생성은 계속 진행됩니다."
fi

# ---------- 6. DDL / DML SQL 경로 ----------
echo
ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DDL_DIR="$REPLY"
ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
DML_DIR="$REPLY"

STAGING_DIR="${SCRIPT_DIR}/.staging/${CONTAINER_NAME}/setup"
SETUP_MOUNT=0
if [[ -n "$DDL_DIR" || -n "$DML_DIR" ]]; then
  rm -rf "${SCRIPT_DIR}/.staging/${CONTAINER_NAME}"
  mkdir -p "$STAGING_DIR"
  if [[ -n "$DDL_DIR" ]]; then
    if [[ -d "$DDL_DIR" ]]; then
      i=1
      for f in "$DDL_DIR"/*; do
        [[ -f "$f" ]] || continue
        cp "$f" "${STAGING_DIR}/10_$(printf '%03d' "$i")_$(basename "$f")"
        i=$((i + 1))
      done
      ok "DDL 파일 $((i - 1))개를 스테이징했습니다 (10_ 접두어, DDL이 DML보다 먼저 실행됨)"
    else
      warn "DDL 경로를 찾을 수 없습니다: $DDL_DIR (건너뜁니다)"
    fi
  fi
  if [[ -n "$DML_DIR" ]]; then
    if [[ -d "$DML_DIR" ]]; then
      i=1
      for f in "$DML_DIR"/*; do
        [[ -f "$f" ]] || continue
        cp "$f" "${STAGING_DIR}/50_$(printf '%03d' "$i")_$(basename "$f")"
        i=$((i + 1))
      done
      ok "DML 파일 $((i - 1))개를 스테이징했습니다 (50_ 접두어, DDL 이후 실행됨)"
    else
      warn "DML 경로를 찾을 수 없습니다: $DML_DIR (건너뜁니다)"
    fi
  fi
  SETUP_MOUNT=1
fi

# ---------- 7. 포트 ----------
echo
ask "리스너 포트" "1521"
LISTENER_PORT="$REPLY"
if port_in_use "$LISTENER_PORT"; then
  warn "포트 ${LISTENER_PORT}은(는) 이미 사용 중인 것으로 보입니다."
fi
if [[ "$IS_EE" -eq 1 ]]; then
  ask "EM Express(관리 콘솔) 포트" "5500"
  EM_PORT="$REPLY"
fi

# ---------- 최종 확인 ----------
echo
echo "======================= 실행 요약 ======================="
echo " 이미지        : $DEPLOY_IMAGE"
echo " 컨테이너 이름 : $CONTAINER_NAME"
if [[ "$IS_EE" -eq 1 ]]; then
  echo " SID / PDB     : $ORACLE_SID_VAL / $ORACLE_PDB_VAL"
else
  echo " 추가 PDB      : ${ORACLE_DATABASE_VAL:-(생성 안 함, 기본 XEPDB1만 사용)}"
fi
echo " 문자셋        : $CHARSET"
echo " 리스너 포트   : $LISTENER_PORT"
[[ "$IS_EE" -eq 1 ]] && echo " EM 포트       : $EM_PORT"
echo " DDL 경로      : ${DDL_DIR:-(없음)}"
echo " DML 경로      : ${DML_DIR:-(없음)}"
echo " 데이터        : 휘발성(볼륨 미사용)"
echo "==========================================================="
if ! confirm "위 설정으로 컨테이너를 생성할까요?"; then
  err "사용자가 취소했습니다."
  exit 1
fi

# ---------- docker run 구성 ----------
RUN_ARGS=(-d --name "$CONTAINER_NAME" -p "${LISTENER_PORT}:1521" --shm-size=1g)
[[ "$IS_EE" -eq 1 ]] && RUN_ARGS+=(-p "${EM_PORT}:5500")
[[ "$SETUP_MOUNT" -eq 1 ]] && RUN_ARGS+=(-v "${STAGING_DIR}:/opt/oracle/scripts/setup:ro")

if [[ "$IS_EE" -eq 1 ]]; then
  RUN_ARGS+=(
    -e "ORACLE_SID=${ORACLE_SID_VAL}"
    -e "ORACLE_PDB=${ORACLE_PDB_VAL}"
    -e "ORACLE_PWD=${DB_PASSWORD}"
    -e "ORACLE_CHARACTERSET=${CHARSET}"
  )
else
  RUN_ARGS+=(
    -e "ORACLE_PASSWORD=${DB_PASSWORD}"
    -e "ORACLE_CHARACTERSET=${CHARSET}"
  )
  [[ -n "${ORACLE_DATABASE_VAL:-}" ]] && RUN_ARGS+=(-e "ORACLE_DATABASE=${ORACLE_DATABASE_VAL}")
fi

info "컨테이너를 실행합니다: $CONTAINER_NAME"
docker run "${RUN_ARGS[@]}" "$DEPLOY_IMAGE"
unset DB_PASSWORD

# ---------- 기동 대기 ----------
info "DB 초기화를 기다리는 중입니다 (에디션에 따라 2~20분 소요될 수 있습니다)..."
ELAPSED=0; INTERVAL=15; TIMEOUT=1800
while true; do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  if [[ "$STATUS" == "healthy" ]]; then
    ok "컨테이너가 정상 기동되었습니다."
    break
  fi
  if ! docker ps -q -f "name=^${CONTAINER_NAME}\$" | grep -q .; then
    err "컨테이너가 중단되었습니다. 로그를 확인하세요:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -60
    exit 1
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    warn "제한 시간 내에 healthy 상태가 되지 않았습니다. 'docker logs -f ${CONTAINER_NAME}'로 직접 확인하세요."
    break
  fi
  sleep "$INTERVAL"; ELAPSED=$((ELAPSED + INTERVAL)); printf "."
done
echo

# ---------- 접속 정보 ----------
echo
echo "======================= 접속 정보 ======================="
echo " Host       : localhost"
echo " Port       : $LISTENER_PORT"
echo " Service    : $SERVICE_NAME"
echo " 접속 예시  : sqlplus system/<입력한 비밀번호>@localhost:${LISTENER_PORT}/${SERVICE_NAME}"
[[ "$IS_EE" -eq 1 ]] && echo " EM Express : https://localhost:${EM_PORT}/em"
echo "==========================================================="
warn "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
