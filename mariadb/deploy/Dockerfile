# ============================================================================
# 배포용 Dockerfile (servicetech2)
#
# 목적: servicetech2 레지스트리에 등록된 베이스 이미지를 그대로 사용해
#       실제 테스트 인스턴스를 만든다. 스키마/계정/포트/DDL·DML SQL은
#       전부 컨테이너 실행 시점(런타임)에 -e / -v 로만 주입하며,
#       이 Dockerfile 자체에는 그런 값이 전혀 들어가지 않는다.
#
# HEALTHCHECK: MariaDB 공식 이미지에 내장된 healthcheck.sh를 그대로 사용한다.
#   이걸로 deploy.sh/.ps1이 Oracle과 동일하게 `docker inspect .State.Health.Status`
#   폴링 루프로 기동 완료를 감지할 수 있다 (공식 이미지엔 HEALTHCHECK가
#   기본 지정되어 있지 않아 여기서 직접 추가함).
#
# 빌드 예:
#   docker build --build-arg REGISTRY_IMAGE=localhost:5000/servicetech2/mariadb:11.4 \
#                -t servicetech2/mariadb-deploy:11.4 .
# ============================================================================
ARG REGISTRY_IMAGE
FROM ${REGISTRY_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 레지스트리 이미지를 기반으로 한 배포용 이미지 (계정/스키마/SQL은 런타임 주입)" \
      org.servicetech2.purpose="test-only"

HEALTHCHECK --interval=5s --timeout=5s --start-period=30s --retries=10 \
  CMD healthcheck.sh --connect --innodb_initialized || exit 1
