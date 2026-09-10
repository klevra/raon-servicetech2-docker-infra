# ============================================================================
# OmnioneCX oacx — aia(2.0.0.1) 백포팅 트랙 전용 이미지
#
# 실제 jar: omnionecx-2.0.1.jar (Spring Boot 3.5.10, PropertiesLauncher).
# 2.0.0.3과 동일하게 내장 Tomcat 포함 실행형 fat jar라 jdk21 베이스를 쓴다.
# context-path(/oacx/api)/port(8080)는 application.yml에 이미 고정돼 있다.
#
# 레지스트리 태그는 jar 매니페스트의 Implementation-Version(2.0.1) 그대로가
# 아니라 "2.0.0.1"을 쓴다 -- 이 트랙 자체를 2.0.0.1로 부르기로 한 결정을
# 따름(빌드 시점 build-and-push.sh의 버전 입력값에서 지정).
#
# mybatis 매퍼/기본 설정은 jar 안(BOOT-INF/classes)에 번들되어 있어 외부
# 마운트가 필요 없다. application.yml만 배포 시점에 /app/config로
# 바인드마운트하면 되고, Spring Boot의 기본 외부 설정 위치(file:./config/)가
# WORKDIR(/app)을 기준으로 자동으로 이를 찾는다 -- 별도 JVM 옵션 불필요.
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 oacx의 app/ 디렉터리
# (omnionecx-2.0.1.jar, app/jdbc/ 등)가 있어야 한다. (app/은 실제 배포
# 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx2-oacx:2.0.0.1 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk21:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX oacx aia(2.0.0.1) -- app(JAR) 빌트인, config는 런타임 마운트(/app/config)" \
      org.servicetech2.app-version="2.0.0.1"

COPY app/ /app/

ENV LOADER_PATH=/app/jdbc
ENV APP_JAR_GLOB="omnionecx-2.0.1.jar"

# base 이미지(jdk21)의 기본 ENTRYPOINT를 그대로 사용 -- font 설치 등
# 별도 처리 필요 없음.
