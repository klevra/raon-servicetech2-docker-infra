# ============================================================================
# OmnioneCX admin — 버전 고정 이미지 (2.0.0.3)
#
# OACX 관리자 콘솔. 1.0.0.12/wooriib/fsb 트랙에는 없던 신규 컴포넌트다.
# oacx와 동일하게 내장 Tomcat 포함 실행형 fat jar(Spring Boot 3,
# PropertiesLauncher). oacx/verifier와 같은 VC_VERIFIER DB 스키마를
# 공유하며(OACX_PROVIDER/OACX_ADMIN 등 관리), mybatis 매퍼는 DB 종류별로
# (mariadb/oracle/postgresql/tibero) 나뉘어 외부 마운트로 제공된다
# (jar 안에 번들되어 있지 않음 -- application.yml의
# mybatis.mapper-locations: file:config/mybatis/mariadb/*.xml 참고).
#
# application.yml/logback-spring.xml/mybatis 전부 상대경로(./config/...)
# 관례라 Spring Boot의 기본 외부 설정 위치(file:./config/)가 WORKDIR(/app)
# 기준으로 자동으로 찾는다 -- 별도 JVM 옵션 불필요.
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 admin의 app/ 디렉터리
# (omnionecx-admin-2.0.3.jar, app/jdbc/ 등)가 있어야 한다. (app/은 실제
# 배포 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx2-admin:2.0.3 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk21:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX admin 2.0.0.3 (2.0.3) -- app(JAR) 빌트인, config는 런타임 마운트(/app/config)" \
      org.servicetech2.app-version="2.0.3"

COPY app/ /app/

ENV LOADER_PATH=/app/jdbc
ENV APP_JAR_GLOB="omnionecx-admin-2.0.3.jar"

# base 이미지(jdk21)의 기본 ENTRYPOINT를 그대로 사용.
