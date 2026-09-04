# ============================================================================
# OmnioneCX oacx — 버전 고정 이미지 (1.0.0.12)
#
# omnionecx/default 트랙과의 차이점: WAR(app) 콘텐츠를 이미지 안에 미리
# COPY해서 넣어둔다. docker pull만 받으면 별도로 app을 바인드마운트하지
# 않아도 바로 실행 가능하다 -- 대신 앱 버전이 바뀔 때마다 이미지를 새로
# 빌드/태깅해야 한다 (그래서 폴더명 자체가 버전 번호).
#
# config(server.properties, provider.json 등 환경별로 달라지는 값)는
# 여전히 배포 시점에 바인드마운트로 주입한다 (default와 동일한 방식
# 유지 -- "app만 빌트인, config는 런타임 주입"이 이 트랙의 핵심 설계).
#
# default 트랙은 web.xml의 config.file 경로(./WEB-INF/config/server.properties
# -> /config/server.properties)를 배포 스크립트가 매번 sed로 패치했지만,
# 여기서는 app이 이미지에 고정되므로 빌드 시점에 한 번만 패치해두면 된다.
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 oacx의 app/ 디렉터리
# (index.html, WEB-INF/ 등)가 있어야 한다. (app/은 실제 배포 산출물이라
# git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx-oacx:1.0.0.12 .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/tomcat9-jdk8:9-jdk8
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX oacx 1.0.0.12 -- app(WAR 콘텐츠) 빌트인, config는 런타임 마운트" \
      org.servicetech2.app-version="1.0.0.12"

# default 트랙은 app을 /app에 바인드마운트하고 Context XML의 docBase="/app"로
# 가리키게 했다. 여기서는 동일한 절대경로(/app) 관례를 유지해 Context XML
# 생성 로직을 그대로 재사용할 수 있게 한다.
COPY app/ /app/

# 이 산출물은 web.xml이 없고 web_normal.xml/web_mtranskey.xml 두 변형으로
# 제공된다 -- 이 트랙은 보안키패드(mTransKey) 없이 배포하므로 web_normal.xml을
# web.xml로 사용한다. 나머지 배포 서술자(web_mtranskey.xml, JBoss/Jeus용
# 파일들)는 Tomcat 배포에 필요 없으므로 삭제한다.
# 그 다음 config.file을 절대경로(/config/server.properties)로 빌드 시점에
# 1회 패치 -- default 트랙에서는 배포 스크립트가 매번 하던 작업이다.
RUN mv /app/WEB-INF/web_normal.xml /app/WEB-INF/web.xml \
 && rm -f /app/WEB-INF/web_mtranskey.xml \
          /app/WEB-INF/jboss-web.xml \
          /app/WEB-INF/jboss-deployment-structure.xml \
          /app/WEB-INF/jeus-web-dd.xml \
 && sed -i -E "s#(<param-value>)\./WEB-INF/config/server\.properties(</param-value>)#\1/config/server.properties\2#" \
    /app/WEB-INF/web.xml

# app/module/event.js(앱 호출 테스트 페이지)의 OACX 서버 주소는 배포하는
# PC/환경마다 달라서 이미지에 고정할 수 없다 -- __OACX_PUBLIC_URL__
# 플레이스홀더로 남겨두고, docker-entrypoint-wrapper.sh가 컨테이너 기동
# 시 OACX_PUBLIC_URL 환경변수 값으로 1회 치환한다(DB의 PARTNER_CODE/
# OPER_SORT 처리와 동일한 패턴).
COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh
ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
CMD ["catalina.sh", "run"]
