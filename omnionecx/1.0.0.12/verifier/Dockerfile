# ============================================================================
# OmnioneCX verifier — 버전 고정 이미지 (1.0.0.12)
#
# omnionecx/default 트랙과의 차이점: 실행용 JAR(app/)을 이미지 안에 미리
# COPY해서 넣어둔다. docker pull만 받으면 별도로 app을 바인드마운트하지
# 않아도 바로 실행 가능하다 -- 대신 앱 버전이 바뀔 때마다 이미지를 새로
# 빌드/태깅해야 한다 (그래서 폴더명 자체가 버전 번호).
#
# config(DB 접속정보, provider.json 등 환경별로 달라지는 값)는 여전히
# 배포 시점에 바인드마운트로 주입한다 (default와 동일한 방식 유지 --
# "app만 빌트인, config는 런타임 주입"이 이 트랙의 핵심 설계).
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 verifier의 app/
# 디렉터리(mdl-verifier-1.*.jar, jdbc/ 등)가 있어야 한다. (app/은 실제
# 배포 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx-verifier:1.0.0.12 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk8:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX verifier 1.0.0.12 -- app(JAR) 빌트인, config는 런타임 마운트" \
      org.servicetech2.app-version="1.0.0.12"

# base 이미지(jdk8)의 ENTRYPOINT가 /app 안에서 APP_JAR_GLOB 패턴의 JAR을
# 찾아 실행하므로, 여기서는 app만 미리 심어두면 별도 ENTRYPOINT 재정의가
# 필요 없다.
COPY app/ /app/

# jdbc 드라이버가 app/jdbc 밑에 같이 들어오므로, base 이미지의 기본값
# (/jdbc, 별도 바인드마운트 전제)을 이미지 안의 실제 위치로 맞춘다.
ENV LOADER_PATH=/app/jdbc
ENV APP_JAR_GLOB="mdl-verifier-1.*.jar"
