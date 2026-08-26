# ============================================================================
# 배포용 Dockerfile (servicetech2)
#
# 목적: servicetech2 레지스트리에 등록된 베이스 이미지를 그대로 사용해
#       실제 테스트 인스턴스를 만든다. 스키마/계정/포트/DDL·DML SQL은
#       전부 컨테이너 실행 시점(런타임)에 -e / -v 로만 주입하며,
#       이 Dockerfile 자체에는 그런 값이 전혀 들어가지 않는다.
#
# HEALTHCHECK: 19c EE(공식 Oracle 이미지)와 21c-xe/18c-xe(gvenzl 커뮤니티 이미지)는
#   서로 다른 헬스체크 방식을 쓴다 (EE는 $ORACLE_BASE/$CHECK_DB_LOCK_FILE 락파일 스크립트,
#   XE는 /opt/oracle/healthcheck.sh). EE 이미지는 자체 HEALTHCHECK가 이미 내장돼 있지만,
#   XE 이미지는 HEALTHCHECK가 아예 없어서(2026-08-26 실제 확인) deploy.sh/.ps1의
#   `docker inspect .State.Health.Status` 폴링이 영원히 "unknown"만 보게 된다.
#   아래 CMD는 이미지 안에 실제로 존재하는 파일을 런타임에 확인해 해당 방식으로
#   분기하므로, 하나의 Dockerfile로 EE/XE 양쪽 다 정확한 헬스체크를 제공한다.
#
# 빌드 예:
#   docker build --build-arg REGISTRY_IMAGE=localhost:5000/servicetech2/oracle:19c \
#                -t servicetech2/oracle-deploy:19c .
# ============================================================================
ARG REGISTRY_IMAGE
FROM ${REGISTRY_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 레지스트리 이미지를 기반으로 한 배포용 이미지 (계정/스키마/SQL은 런타임 주입)" \
      org.servicetech2.purpose="test-only"

HEALTHCHECK --interval=15s --timeout=10s --start-period=600s --retries=80 \
  CMD if [ -f /opt/oracle/healthcheck.sh ]; then /opt/oracle/healthcheck.sh >/dev/null || exit 1; \
      elif [ -n "$CHECK_DB_LOCK_FILE" ] && [ -x "$ORACLE_BASE/$CHECK_DB_LOCK_FILE" ]; then "$ORACLE_BASE/$CHECK_DB_LOCK_FILE" >/dev/null || exit 1; \
      else exit 0; fi
