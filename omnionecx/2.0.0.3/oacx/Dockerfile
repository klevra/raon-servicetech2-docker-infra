# ============================================================================
# OmnioneCX oacx — 버전 고정 이미지 (2.0.0.3)
#
# 1.0.0.12 트랙과의 차이: 1.0.0.12는 외장 Tomcat + WAR(Context XML 별도
# 생성 필요)였지만, 이 oacx는 내장 Tomcat 포함 실행형 fat jar(Spring Boot 3,
# PropertiesLauncher)다. context-path/port가 application.yml 안에 이미
# 고정돼 있어(server.servlet.context-path: /oacx/api, server.port: 8081)
# 배포 스크립트가 Context XML을 만들어줄 필요가 없다.
#
# mybatis 매퍼/기본 설정은 jar 안(BOOT-INF/classes)에 번들되어 있어 외부
# 마운트가 필요 없다. application.yml만 배포 시점에 /app/config로
# 바인드마운트하면 되고, Spring Boot의 기본 외부 설정 위치(file:./config/)가
# WORKDIR(/app)을 기준으로 자동으로 이를 찾는다 -- 별도 JVM 옵션 불필요.
# logging.config: ./config/logback-spring.xml 도 동일한 상대경로 관례.
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 oacx의 app/ 디렉터리
# (omnionecx-2.0.3.jar, app/jdbc/ 등)가 있어야 한다. (app/은 실제 배포
# 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx2-oacx:2.0.3 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk21:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX oacx 2.0.0.3 (2.0.3) -- app(JAR) 빌트인, config는 런타임 마운트(/app/config)" \
      org.servicetech2.app-version="2.0.3"

COPY app/ /app/

# jdbc 드라이버가 app/jdbc 밑에 같이 들어오므로, base 이미지의 기본값
# (/jdbc, 별도 바인드마운트 전제)을 이미지 안의 실제 위치로 맞춘다.
ENV LOADER_PATH=/app/jdbc
ENV APP_JAR_GLOB="omnionecx-2.0.3.jar"

# base 이미지(jdk21)의 기본 ENTRYPOINT를 그대로 사용 -- font 설치 등
# 별도 처리 필요 없음.
