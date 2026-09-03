# ============================================================================
# OmnioneCX DB — 우리투자증권(wooriib) 전용 이미지
#
# omnionecx/1.0.0.12/db/의 설계와 동일: DDL/DML을 이미지 안에 미리 구워
# 넣는다. 컨테이너가 처음 뜰 때(데이터 디렉터리가 비어있을 때만) MariaDB
# 공식 엔트리포인트가 /docker-entrypoint-initdb.d/ 안의 파일들을 실행해
# 스키마+초기 데이터를 자동으로 적재한다.
#
# PARTNER_CODE(기본값 raon)/OPER_SORT(운영/개발, 기본값 dev)는 배포 시점에
# 값을 바꿀 수 있도록, 해당 데이터를 플레이스홀더로 남겨두고
# 00-patch-placeholders.sh가 컨테이너 환경변수 값으로 최초 기동 시 1회 치환한다.
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx-db-wooriib:latest .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/mariadb:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX DB -- 우리투자증권(wooriib) 전용, DDL/DML 빌트인" \
      org.servicetech2.site="wooriib"

COPY initdb/ /docker-entrypoint-initdb.d/
# init 스크립트는 root가 아니라 mysql 계정으로 실행되는데, sed -i가 같은
# 디렉터리에 임시 파일을 만들어야 해서 디렉터리 자체도 쓰기 가능해야 한다.
RUN chmod +x /docker-entrypoint-initdb.d/00-patch-placeholders.sh \
 && chmod -R a+rwX /docker-entrypoint-initdb.d
