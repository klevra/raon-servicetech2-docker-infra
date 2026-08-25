# ============================================================================
# 배포용 Dockerfile (servicetech2)
#
# 목적: servicetech2 레지스트리에 등록된 베이스 이미지를 그대로 사용해
#       실제 테스트 인스턴스를 만든다. 스키마/계정/포트/DDL·DML SQL은
#       전부 컨테이너 실행 시점(런타임)에 -e / -v 로만 주입하며,
#       이 Dockerfile 자체에는 그런 값이 전혀 들어가지 않는다.
#
# HEALTHCHECK: PostgreSQL 공식 이미지에는 기본 헬스체크가 없어 여기서 직접 정의한다.
#   deploy.sh/.ps1은 Oracle/MariaDB/MySQL과 동일하게 `docker inspect .State.Health.Status`
#   폴링으로 기동 완료 시점을 판단한다. pg_isready에 -h 127.0.0.1을 명시해 TCP 접속을
#   강제하는데, 이렇게 해야 초기화 스크립트 실행 중(유닉스 소켓만 열려 있는 임시 상태)에
#   조기 성공으로 오판하지 않는다.
#
# 빌드 예:
#   docker build --build-arg REGISTRY_IMAGE=localhost:5000/servicetech2/postgres:16 \
#                -t servicetech2/postgres-deploy:16 .
# ============================================================================
ARG REGISTRY_IMAGE
FROM ${REGISTRY_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 레지스트리 이미지를 기반으로 한 배포용 이미지 (계정/스키마/SQL은 런타임 주입)" \
      org.servicetech2.purpose="test-only"

HEALTHCHECK --interval=5s --timeout=5s --start-period=30s --retries=10 \
  CMD pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1
