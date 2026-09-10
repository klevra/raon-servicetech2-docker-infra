# ============================================================================
# OmnioneCX verifier — aia(2.0.0.1) 백포팅 트랙 전용 이미지
#
# 실제 jar: mdl-verifier-1.3.36-fix.jar (Spring Boot 2.7.4, jdk8 바이트코드
# class major version 52). jdk21 베이스 이미지(2.0.0.3과 동일)에서 config
# 마운트 없이 단독 부팅 테스트를 거쳐 JDK21 호환성을 확인했다(부팅 로그가
# DataSource 미설정 시점까지 정상 진행 -- 그 이후는 config 마운트 문제일 뿐
# JDK 비호환 문제가 아님).
#
# 2.0.0.3과 동일하게 application.yml이 spring.profiles.group.common으로
# datasource/logging 등 여러 프로필 멤버를 묶어 로드하는 구조라서, 같은
# merge-order 버그(느슨한 .properties/.yml 파일이 같은 /config 마운트에
# 있으면 빈 값으로 덮어씀)에 노출된다 -- config/_vendor-reference-unused/로
# 격리하는 대응은 deploy/verifier/config에 이미 반영되어 있다.
#
# 폰트: 이 jar도 1.0.0.12/2.0.0.3과 동일한 vc-converter SDK 계열이라
# application.yml의 font 설정을 SDK가 직접 읽지 않는 문제가 동일하게
# 적용될 것으로 보고, docker-entrypoint-wrapper.sh로 OS 폰트 설치를
# 그대로 재사용한다.
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 verifier의 app/
# 디렉터리(mdl-verifier-1.3.36-fix.jar, app/jdbc/ 등)가 있어야 한다.
# (app/은 실제 배포 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx2-verifier:1.3.36_fix .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk21:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX verifier aia(2.0.0.1) (1.3.36-fix) -- app(JAR) 빌트인, config는 런타임 마운트" \
      org.servicetech2.app-version="1.3.36-fix"

COPY app/ /app/

ENV LOADER_PATH=/app/jdbc
ENV APP_JAR_GLOB="mdl-verifier-1.*.jar"

COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh
ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
