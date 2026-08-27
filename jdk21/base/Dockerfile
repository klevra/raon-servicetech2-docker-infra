# ============================================================================
# 레지스트리 등록용 JDK21 실행 베이스 이미지 (servicetech2)
#
# 목적: 실행용 JAR 하나만 있으면 되는 JDK21 기반 애플리케이션(OmnioneCX v2의
#       verifier/oacx/admin 등)을 위한 공용 런타임. jdk8/base와 동일한 구조이며
#       베이스 이미지만 JDK21로 다르다. 애플리케이션 JAR/설정/드라이버는 여기에
#       포함하지 않으며, 배포 시점에 app/config/jdbc/logs를 전부 바인드마운트로 주입한다.
#
# 컨테이너 기동 시 /app 안에서 APP_JAR_GLOB(기본값 *.jar)에 맞는 JAR을
# 정확히 1개 찾아 실행한다 (여러 개/0개면 에러로 즉시 종료).
#
# 빌드 예:
#   docker build --build-arg BASE_IMAGE=eclipse-temurin:21-jre \
#                -t localhost:5000/servicetech2/jdk21:latest .
# ============================================================================
ARG BASE_IMAGE=eclipse-temurin:21-jre
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 프라이빗 레지스트리용 JDK21 실행 베이스 이미지 (앱/설정 미포함, 배포 단계에서 런타임 주입)" \
      org.servicetech2.purpose="test-only"

WORKDIR /app

ENV LOADER_PATH=/jdbc
ENV APP_JAR_GLOB="*.jar"
ENV JAVA_OPTS=""

ENTRYPOINT ["/bin/sh", "-c", "set -e; \
JAR=$(ls /app/$APP_JAR_GLOB 2>/dev/null | head -n1); \
if [ -z \"$JAR\" ]; then \
  echo \"[오류] /app 안에서 '$APP_JAR_GLOB' 패턴에 맞는 JAR 파일을 찾지 못했습니다.\" >&2; \
  ls -la /app >&2; \
  exit 1; \
fi; \
echo \"[정보] 실행 대상 JAR: $JAR\"; \
exec java $JAVA_OPTS -Dloader.path=$LOADER_PATH -jar \"$JAR\""]
