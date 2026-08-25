# ============================================================================
# 배포용 Dockerfile (servicetech2)
#
# 목적: servicetech2 레지스트리에 등록된 베이스 이미지를 그대로 사용해
#       실제 테스트 인스턴스를 만든다. 스키마/계정/포트/DDL·DML SQL은
#       전부 컨테이너 실행 시점(런타임)에 -e / -v 로만 주입하며,
#       이 Dockerfile 자체에는 그런 값이 전혀 들어가지 않는다.
#
# HEALTHCHECK: MySQL 공식 이미지에는 기본 헬스체크가 없어 여기서 직접 정의한다.
#   deploy.sh/.ps1은 Oracle/MariaDB와 동일하게 `docker inspect .State.Health.Status`
#   폴링으로 기동 완료 시점을 판단하므로, 이 Dockerfile에 HEALTHCHECK가 없으면
#   해당 로직이 동작하지 않는다 (기본 이미지 자체에 HEALTHCHECK 없음).
#
# 빌드 예:
#   docker build --build-arg REGISTRY_IMAGE=localhost:5000/servicetech2/mysql:8.4 \
#                -t servicetech2/mysql-deploy:8.4 .
# ============================================================================
ARG REGISTRY_IMAGE
FROM ${REGISTRY_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 레지스트리 이미지를 기반으로 한 배포용 이미지 (계정/스키마/SQL은 런타임 주입)" \
      org.servicetech2.purpose="test-only"

HEALTHCHECK --interval=5s --timeout=5s --start-period=30s --retries=10 \
  CMD mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent || exit 1
