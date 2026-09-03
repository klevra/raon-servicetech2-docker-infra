#!/bin/sh
# ============================================================================
# app/module/event.js의 "앱 호출 테스트" 페이지에 박힌 OACX 서버 주소는
# 배포하는 PC/환경마다 달라지므로(이미지에는 고정할 수 없음), 빌드 시점에는
# __OACX_PUBLIC_URL__ 플레이스홀더로 남겨두고 컨테이너 기동 시 이 스크립트가
# OACX_PUBLIC_URL 환경변수 값으로 1회 치환한다 (deploy 스크립트가 로컬 IP를
# 자동 감지해 기본값으로 물어봄). omnionecx/wooriib/oacx와 동일한 패턴.
#
# 이 이미지는 root로 실행되므로(공식 tomcat 베이스와 동일) 파일 쓰기 권한
# 문제는 없다.
# ============================================================================
set -e
if [ -n "${OACX_PUBLIC_URL:-}" ]; then
  sed -i "s#__OACX_PUBLIC_URL__#${OACX_PUBLIC_URL}#g" /app/module/event.js
  echo "[init] OACX_PUBLIC_URL=${OACX_PUBLIC_URL} 로 event.js를 패치했습니다."
fi
exec "$@"
