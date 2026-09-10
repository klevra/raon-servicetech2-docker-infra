#!/bin/sh
# ============================================================================
# 초기 데이터의 배포별 값(PARTNER_CODE, OPER_SORT)을 컨테이너 기동 시점에 반영.
#
# 51_insert-init-data.sql/52_insert_data.sql 안의 __PARTNER_CODE__,
# __OPER_SORT__ 플레이스홀더를 컨테이너 환경변수(deploy 스크립트가 값을
# 물어보고 설정)로 치환한다. 파일명이 00- 로 시작해서 알파벳/숫자 순으로
# 실행되는 이 디렉터리 안에서 다른 .sql 파일들보다 먼저 실행되므로, 실제
# INSERT가 일어나기 전에 패치가 끝난다. (MariaDB 공식 이미지는 최초 기동
# 시 -- 데이터 디렉터리가 비어 있을 때만 -- 이 디렉터리를 한 번 실행한다.)
#
# 새로운 배포별 값을 추가하려면: 해당 .sql에 __새이름__ 플레이스홀더를
# 심어두고, 아래에 한 줄만 추가하면 된다.
# ============================================================================
set -e
PARTNER_CODE="${PARTNER_CODE:-raon}"
OPER_SORT="${OPER_SORT:-dev}"
echo "[init] PARTNER_CODE=${PARTNER_CODE}, OPER_SORT=${OPER_SORT} 로 초기 데이터를 패치합니다."
sed -i \
  -e "s/__PARTNER_CODE__/${PARTNER_CODE}/g" \
  -e "s/__OPER_SORT__/${OPER_SORT}/g" \
  /docker-entrypoint-initdb.d/*.sql
