# ============================================================================
# OmnioneCX verifier — 버전 고정 이미지 (2.0.0.3)
#
# 1.0.0.12 트랙과의 차이: 1.0.0.12는 외장 Tomcat + WAR였지만, 이 verifier는
# 내장 Tomcat 포함 실행형 fat jar(Spring Boot 3, PropertiesLauncher)다.
# jdk8이 아니라 jdk21 베이스 이미지를 사용한다.
#
# 설정(application.yml 등)은 여전히 배포 시점에 /config로 바인드마운트
# 주입한다 -- "app만 빌트인, config는 런타임 주입" 설계는 동일하게 유지.
# application.yml이 spring.profiles.group.common으로 datasource/logging/sp/
# converter/web/mdl/zkp를 묶어서 로드하는데, 별도 application-{profile}.
# 파일들이 아니라 이 application.yml 하나에 전부 인라인으로 들어있는 형태다.
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 verifier의 app/
# 디렉터리(mdl-verifier-1.3.42-springboot-3.jar, app/jdbc/ 등)가 있어야
# 한다. (app/은 실제 배포 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx2-verifier:1.3.42-springboot-3 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk21:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX verifier 2.0.0.3 (1.3.42-springboot-3) -- app(JAR) 빌트인, config는 런타임 마운트" \
      org.servicetech2.app-version="1.3.42-springboot-3"

# base 이미지(jdk21)의 원래 ENTRYPOINT는 /app 안에서 APP_JAR_GLOB 패턴의
# JAR을 찾아 바로 실행하는 방식이었으나, 폰트 설치(아래 참고)를 위해
# docker-entrypoint-wrapper.sh로 감싸고 그 안에서 동일한 로직을 재현한다.
COPY app/ /app/

# jdbc 드라이버가 app/jdbc 밑에 같이 들어오므로, base 이미지의 기본값
# (/jdbc, 별도 바인드마운트 전제)을 이미지 안의 실제 위치로 맞춘다.
ENV LOADER_PATH=/app/jdbc
ENV APP_JAR_GLOB="mdl-verifier-1.*.jar"

COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh
ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
