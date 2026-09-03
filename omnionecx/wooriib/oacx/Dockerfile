# ============================================================================
# OmnioneCX oacx — 우리투자증권(wooriib) 전용 이미지 (1.0.0.9)
#
# WAR(app) 콘텐츠를 이미지 안에 미리 COPY해서 넣어둔다. config(server.properties,
# provider.json 등 환경별로 달라지는 값)는 여전히 배포 시점에 바인드마운트로
# 주입한다 (omnionecx/1.0.0.12/oacx/와 동일한 설계).
#
# 이 사이트의 산출물은 web.xml이 없고 web_normal.xml/web_mtranskey.xml
# 두 변형으로 제공된다 -- wooriib는 보안키패드(mTransKey) 없이 배포하므로
# web_normal.xml을 web.xml로 사용한다.
#
# web.xml의 config.file 경로(./WEB-INF/config/server.properties ->
# /config/server.properties)를 빌드 시점에 1회 패치해둔다.
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 wooriib용 oacx의 app/
# 디렉터리(index.html, WEB-INF/ 등)가 있어야 한다. (app/은 실제 배포
# 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx-oacx-wooriib:1.0.0.9 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/tomcat9-jdk8:9-jdk8
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX oacx -- 우리투자증권(wooriib) 전용, app(WAR 콘텐츠) 빌트인" \
      org.servicetech2.site="wooriib" \
      org.servicetech2.app-version="1.0.0.9"

# default 트랙은 app을 /app에 바인드마운트하고 Context XML의 docBase="/app"로
# 가리키게 했다. 여기서는 동일한 절대경로(/app) 관례를 유지해 Context XML
# 생성 로직을 그대로 재사용할 수 있게 한다.
COPY app/ /app/

# web_normal.xml -> web.xml로 파일명을 실제로 바꾸고, 쓰지 않는 나머지
# 배포 서술자(web_mtranskey.xml, JBoss용 jboss-web.xml/
# jboss-deployment-structure.xml)는 Tomcat 배포에 필요 없으므로 삭제한다.
# 그 다음 config.file을 절대경로(/config/server.properties)로 패치.
RUN mv /app/WEB-INF/web_normal.xml /app/WEB-INF/web.xml \
 && rm -f /app/WEB-INF/web_mtranskey.xml \
          /app/WEB-INF/jboss-web.xml \
          /app/WEB-INF/jboss-deployment-structure.xml \
 && sed -i -E "s#(<param-value>)\./WEB-INF/config/server\.properties(</param-value>)#\1/config/server.properties\2#" \
    /app/WEB-INF/web.xml
