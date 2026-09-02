#!/bin/sh
# ============================================================================
# OACX_PROVIDER 초기 데이터의 OPER_SORT(dev/prod)를 컨테이너 기동 시점에 반영.
#
# 52_insert_data.sql 안의 __OPER_SORT__ 플레이스홀더를, 컨테이너 환경변수
# OPER_SORT(deploy 스크립트가 운영/개발 선택을 받아 설정)로 치환한다.
# 파일명이 00- 로 시작해서 알파벳/숫자 순으로 실행되는 이 디렉터리 안에서
# 다른 .sql 파일들보다 먼저 실행되므로, 실제 INSERT가 일어나기 전에 패치가
# 끝난다. (MariaDB 공식 이미지는 최초 기동 시 -- 데이터 디렉터리가 비어
# 있을 때만 -- 이 디렉터리를 한 번 실행한다.)
# ============================================================================
set -e
OPER_SORT="${OPER_SORT:-dev}"
echo "[init] OPER_SORT=${OPER_SORT} 로 OACX_PROVIDER 초기 데이터를 패치합니다."
sed -i "s/__OPER_SORT__/${OPER_SORT}/g" /docker-entrypoint-initdb.d/*.sql
