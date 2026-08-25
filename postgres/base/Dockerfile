# ============================================================================
# 레지스트리 등록용 베이스 이미지 (servicetech2)
#
# 목적: PostgreSQL 공식 이미지를 그대로 재태깅하여 프라이빗 레지스트리에
#       등록하기 위한 최소 구성. 계정정보/스키마/DDL·DML SQL은 여기에 포함하지
#       않으며, 배포 시점(postgres/deploy)에 런타임으로만 주입한다.
#
# 빌드 예:
#   docker build --build-arg BASE_IMAGE=postgres:16 \
#                -t localhost:5000/servicetech2/postgres:16 .
# ============================================================================
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 프라이빗 레지스트리용 PostgreSQL 베이스 이미지 (계정/스키마/SQL 미포함, 배포 단계에서 런타임 주입)" \
      org.servicetech2.purpose="test-only"
