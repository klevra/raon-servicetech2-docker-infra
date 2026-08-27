# ============================================================================
# 레지스트리 등록용 Tomcat 실행 베이스 이미지 (servicetech2)
#
# 목적: Tomcat 공식 이미지를 그대로 재태깅하여 프라이빗 레지스트리에 등록하기
#       위한 최소 구성. 별도 ENTRYPOINT 커스터마이징 없음 (공식 이미지의
#       catalina.sh run 그대로 사용). 애플리케이션(WAR)/설정은 여기에 포함하지
#       않으며, 배포 시점(oacx/deploy)에 conf/Catalina/localhost/*.xml로 Context를
#       등록하고 app/config/logs를 전부 바인드마운트로 주입한다.
#
# 빌드 예:
#   docker build --build-arg BASE_IMAGE=tomcat:9-jdk8-temurin \
#                -t localhost:5000/servicetech2/tomcat9-jdk8:latest .
# ============================================================================
ARG BASE_IMAGE=tomcat:9-jdk8-temurin
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="servicetech2 프라이빗 레지스트리용 Tomcat 실행 베이스 이미지 (앱/설정 미포함, 배포 단계에서 런타임 주입)" \
      org.servicetech2.purpose="test-only"
