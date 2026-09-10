# ============================================================================
# OmnioneCX sample(테스트 페이지) — 버전 고정 이미지 (2.0.0.3)
#
# 1.0.0.12에서는 oacx WAR 안에 index.html/module/event.js가 번들되어 같이
# 떠 있었지만, 2.0.0.3의 oacx는 자체 실행형 fat jar(내장 Tomcat)라 정적
# 테스트 페이지를 더 이상 담지 못한다. 그래서 벤더가 이 테스트 페이지를
# 별도의 작은 Spring Boot 앱(mobileid-sample-springboot)으로 분리해서
# 제공한다 -- oacx의 REST API(/oacx/api)를 호출해 인증 흐름을 시연하는
# 용도.
#
# Spring Boot 2.7.18(JarLauncher) 기반이라 verifier/oacx/admin(Boot3,
# PropertiesLauncher)과는 다르지만, jar 하나만 실행하면 되는 구조는 동일해서
# jdk21 베이스 이미지를 그대로 재사용한다. jdbc 드라이버 등 외부 lib가
# 없어서 LOADER_PATH는 base 이미지 기본값을 그대로 둔다(사용되지 않음).
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 sample의 app/ 디렉터리
# (mobileid-sample-springboot-1.0-SNAPSHOT.jar)가 있어야 한다. (app/은 실제
# 배포 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx2-sample:1.0-SNAPSHOT .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk21:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX sample(테스트 페이지) 2.0.0.3 -- app(JAR) 빌트인, config는 런타임 마운트(/app/config)" \
      org.servicetech2.app-version="1.0-SNAPSHOT"

COPY app/ /app/

ENV APP_JAR_GLOB="mobileid-sample-springboot-1.0-SNAPSHOT.jar"

# base 이미지(jdk21)의 기본 ENTRYPOINT를 그대로 사용 -- jdbc 드라이버 등
# 외부 lib가 없어 LOADER_PATH는 base 기본값(/jdbc, 미사용)을 그대로 둔다.
