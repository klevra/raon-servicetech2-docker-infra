#!/bin/sh
# ============================================================================
# VCConverter(이미지 생성) 폰트 문제 대응:
# 1.0.0.12(1.3.42, jdk8)와 동일한 vc-converter SDK 버전(1.3.42)을 Boot3로
# 재빌드한 것뿐이라, application.yml의 converter.font-dir-path(/config/fonts)/
# use-font-file 설정을 SDK가 실제로 참조하지 않는 문제(바이트코드 확인 결과,
# 커스텀 VCFontCreator 구현/등록 코드가 앱/SDK 어디에도 없음)가 동일하게
# 적용될 것으로 보고 동일한 대응을 적용한다. SDK 기본 구현체는
# new Font(fontName, style, size)로 OS에 설치된 폰트를 이름으로 찾는 방식만
# 지원하므로, TTF 파일을 OS(fontconfig)에 폰트로 등록해야 한다.
#
# 폰트 파일 자체는 이미지에 새로 넣지 않고, 이미 /config/fonts로 바인드
# 마운트되어 있는 원본을 컨테이너 기동 시점에 그대로 끌어다 쓴다.
#
# 이 이미지는 root로 실행되므로(base jdk21 이미지와 동일) OS 폰트 디렉터리
# 쓰기 권한 문제는 없다.
# ============================================================================
set -e

if [ -d /config/fonts ]; then
  mkdir -p /usr/share/fonts/truetype/custom
  cp /config/fonts/*.ttf /usr/share/fonts/truetype/custom/ 2>/dev/null || true
  fc-cache -f >/dev/null 2>&1 || true
  echo "[init] /config/fonts의 TTF를 OS 폰트로 설치했습니다 (fc-cache 갱신 완료)."
else
  echo "[init] /config/fonts 마운트를 찾을 수 없어 폰트 설치를 건너뜁니다." >&2
fi

# base 이미지(jdk21)의 원래 ENTRYPOINT 로직을 그대로 재현한다:
#   /app 안에서 APP_JAR_GLOB 패턴의 JAR을 찾아 java로 실행
# verifier는 application.yml을 /config 절대경로에서 읽는다. 이 경로는
# 1.0.0.12와 동일하게 SPRING_CONFIG_ADDITIONAL_LOCATION 환경변수(docker-
# compose.yml에서 설정)로 넘겨받으며, Spring Boot가 이를 네이티브로 인식한다.
JAR="$(ls /app/${APP_JAR_GLOB} 2>/dev/null | head -n1)"
if [ -z "$JAR" ]; then
  echo "[오류] /app 안에서 '${APP_JAR_GLOB}' 패턴에 맞는 JAR 파일을 찾지 못했습니다." >&2
  ls -la /app >&2
  exit 1
fi
echo "[정보] 실행 대상 JAR: $JAR"
exec java $JAVA_OPTS -Dloader.path=$LOADER_PATH -jar "$JAR"
