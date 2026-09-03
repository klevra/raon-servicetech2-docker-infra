# ============================================================================
# OmnioneCX verifier — 저축은행중앙회(fsb) 전용 이미지 (1.3.19_fix)
#
# 실행용 JAR(app/)을 이미지 안에 미리 COPY해서 넣어둔다. config(DB 접속정보,
# provider.json 등 환경별로 달라지는 값)는 여전히 배포 시점에 바인드마운트로
# 주입한다 (omnionecx/wooriib/verifier와 동일한 설계).
#
# 빌드 컨텍스트에는 이 Dockerfile과 같은 위치에 실제 fsb용 verifier app/
# 디렉터리(mdl-verifier-1.3.19-fix.jar, jdbc/ 등)가 있어야 한다. (app/은
# 실제 배포 산출물이라 git에는 커밋하지 않음 -- .gitignore 확인)
#
# 빌드 예:
#   docker build -t 192.168.0.168:5000/servicetech2/omnionecx-verifier-fsb:1.3.19_fix .
# ============================================================================
ARG BASE_IMAGE=192.168.0.168:5000/servicetech2/jdk8:latest
FROM ${BASE_IMAGE}

LABEL maintainer="servicetech2" \
      description="OmnioneCX verifier -- 저축은행중앙회(fsb) 전용, app(JAR) 빌트인" \
      org.servicetech2.site="fsb" \
      org.servicetech2.app-version="1.3.19_fix"

# base 이미지(jdk8)의 원래 ENTRYPOINT는 /app 안에서 APP_JAR_GLOB 패턴의
# JAR을 찾아 바로 실행하는 방식이었으나, 폰트 설치(아래 참고)를 위해
# docker-entrypoint-wrapper.sh로 감싸고 그 안에서 동일한 로직을 재현한다.
COPY app/ /app/

# jdbc 드라이버가 app/jdbc 밑에 같이 들어오므로, base 이미지의 기본값
# (/jdbc, 별도 바인드마운트 전제)을 이미지 안의 실제 위치로 맞춘다.
ENV LOADER_PATH=/app/jdbc
ENV APP_JAR_GLOB="mdl-verifier-1.*.jar"

# ----------------------------------------------------------------------------
# 이미지 생성용 폰트(NanumGothic/PretendardGOV 등) OS 레벨 설치
#
# application-converter.yml의 font-dir-path(/config/fonts)/use-font-file 설정은
# 실제로는 vc-converter SDK가 참조하지 않는다 (바이트코드 확인 결과, 커스텀
# VCFontCreator 구현/등록 코드가 앱/SDK 어디에도 없음). SDK 기본 구현체는
# new Font(fontName, style, size)로 "OS에 설치된 폰트를 이름으로 탐색"하는
# 방식만 지원하므로, TTF 파일을 OS(fontconfig)에 폰트로 등록해야 한다.
#
# 폰트 파일 자체는 이미지에 새로 굽지 않고, 이미 /config/fonts로 바인드
# 마운트되는 sandbox 원본을 컨테이너 기동 시점에 그대로 설치한다 (config와
# 동일한 취급). docker-entrypoint-wrapper.sh가 기동 시마다 fc-cache까지
# 갱신한 뒤 원래 java 실행 로직을 이어간다. 이 이미지는 root로 실행되므로
# (base jdk8 이미지와 동일) OS 폰트 디렉터리 쓰기 권한 문제는 없다.
# ----------------------------------------------------------------------------
COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh
ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
