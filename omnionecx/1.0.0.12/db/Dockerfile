# ============================================================================
# OmnioneCX DB — 버전 고정 이미지 (1.0.0.12)
#
# default 트랙과의 차이: DDL/DML을 배포 시점에 외부 폴더에서 스테이징하지
# 않고, 이 이미지 안에 미리 구워 넣는다. 컨테이너가 처음 뜰 때(데이터
# 디렉터리가 비어있을 때만) MariaDB 공식 엔트리포인트가
# /docker-entrypoint-initdb.d/ 안의 파일들을 실행해 스키마+초기 데이터를
# 자동으로 적재한다 -- 별도 DDL_DIR/DML_DIR 마운트가 필요 없다.
#
# PARTNER_CODE는 'raon'으로 고정(빌드 시점에 이미 반영됨). OPER_SORT(운영/
# 개발)만 배포 시점에 선택 가능하도록, OACX_PROVIDER 데이터는 플레이스홀더로
# 남겨두고 00-patch-oper-sort.sh가 컨테이너 환경변수 OPER_SORT 값으로
# 최초 기동 시 1회 치환한다.
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx-db:1.0.0.12 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/mariadb:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX DB 1.0.0.12 -- DDL/DML 빌트인 (PARTNER_CODE=raon 고정, OPER_SORT는 런타임 선택)" \
      org.servicetech2.app-version="1.0.0.12"

COPY initdb/ /docker-entrypoint-initdb.d/
# init 스크립트는 root가 아니라 mysql 계정으로 실행되는데, sed -i가 같은
# 디렉터리에 임시 파일을 만들어야 해서 디렉터리 자체도 쓰기 가능해야 한다.
RUN chmod +x /docker-entrypoint-initdb.d/00-patch-oper-sort.sh \
 && chmod -R a+rwX /docker-entrypoint-initdb.d
