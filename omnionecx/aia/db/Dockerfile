# ============================================================================
# OmnioneCX DB — aia(2.0.0.1) 백포팅 트랙 전용 이미지
#
# initdb/는 2.0.0.3 트랙의 완성본(DDL AUTO_INCREMENT 수정, OACX_TEMP_TOKEN.TOKEN
# MEDIUMTEXT 수정, OACX_SERVICE_PROVIDER.PROVIDER_IF timeout 30000 수정 모두
# 반영됨)을 그대로 재사용한다 -- aia의 원본 DDL/DML과 diff 비교 결과 스키마와
# 초기 데이터가 완전히 동일했음(플레이스홀더 패턴 차이 제외, timeout 값만
# 5000으로 미수정 상태였던 차이 하나뿐). 51_insert-init-data.sql의
# APP_CONTENT 라벨만 "2.0.0.1"로 맞춰 별도 작성.
#
# 대상 베이스: mariadb/base로 이미 레지스트리에 등록된 servicetech2/mariadb 이미지.
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx2-db:aia .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/mariadb:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX DB aia(2.0.0.1) -- DDL/DML 빌트인 (PARTNER_CODE/OPER_SORT는 런타임 선택, 기본값 raon/dev)" \
      org.servicetech2.app-version="aia"

COPY initdb/ /docker-entrypoint-initdb.d/
# init 스크립트는 root가 아니라 mysql 계정으로 실행되는데, sed -i가 같은
# 디렉터리에 임시 파일을 만들어야 해서 디렉터리 자체도 쓰기 가능해야 한다.
RUN chmod +x /docker-entrypoint-initdb.d/00-patch-placeholders.sh \
 && chmod -R a+rwX /docker-entrypoint-initdb.d
