# ============================================================================
# 배포용 Dockerfile (servicetech2)
#
# 목적: servicetech2 레지스트리에 등록된 베이스 이미지를 그대로 사용해
#       실제 테스트 인스턴스를 만든다. 스키마/계정/포트는 전부 컨테이너
#       실행 시점(런타임)에 -e 로만 주입하며, 이 Dockerfile 자체에는
#       그런 값이 전혀 들어가지 않는다.
#
# HEALTHCHECK: CUBRID 공식 이미지에는 기본 헬스체크가 없어 여기서 직접 정의한다.
#   csql로 dba 계정(비밀번호 없음, CUBRID 기본 동작)으로 실제 쿼리를 날려
#   서버가 클라이언트 연결을 받을 수 있는 상태인지 확인한다.
#   deploy.sh/.ps1은 다른 DB와 동일하게 `docker inspect .State.Health.Status`
#   폴링으로 기동 완료 시점을 판단한다. CUBRID는 최초 기동 시 100M+ 크기의
#   DB 볼륨을 새로 생성하는 과정이 있어 다른 DB보다 기동 시간이 길다.
#
# 빌드 예:
#   docker build --build-arg REGISTRY_IMAGE=localhost:5000/servicetech2/cubrid:11.4 \
#                -t servicetech2/cubrid-deploy:11.4 .
# ============================================================================
ARG REGISTRY_IMAGE
FROM ${REGISTRY_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 레지스트리 이미지를 기반으로 한 배포용 이미지 (계정/스키마는 런타임 주입)" \
      org.servicetech2.purpose="test-only"

HEALTHCHECK --interval=5s --timeout=5s --start-period=60s --retries=15 \
  CMD gosu cubrid csql -u dba $CUBRID_DB -c "SELECT 1;" >/dev/null 2>&1 || exit 1
