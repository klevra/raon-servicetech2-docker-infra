#!/bin/sh
# ============================================================================
# VCConverter(이미지 생성) 폰트 문제 대응:
# application-converter.yml의 font-dir-path(/config/fonts)/use-font-file
# 설정은 vc-converter SDK가 실제로 참조하지 않는다 (바이트코드 확인 결과,
# 커스텀 VCFontCreator 구현/등록 코드가 앱/SDK 어디에도 없음). SDK 기본
# 구현체(VCTextAttribute$1)는 new Font(fontName, style, size)로 OS에 설치된
# 폰트를 이름으로 찾는 방식만 지원하므로, TTF 파일을 OS(fontconfig)에
# 폰트로 등록해야 한다.
#
# 폰트 파일 자체는 이미지에 새로 넣지 않고, 이미 /config/fonts로 바인드
# 마운트되어 있는 sandbox 원본을 컨테이너 기동 시점에 그대로 끌어다 쓴다
# (config와 동일한 취급 -- 이미지에 중복으로 구울 필요 없음).
#
# 이 이미지는 root로 실행되므로(base jdk8 이미지와 동일) OS 폰트 디렉터리
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

# base 이미지(jdk8)의 원래 ENTRYPOINT 로직을 그대로 재현한다
# (docker inspect로 확인한 base 이미지 ENTRYPOINT와 동일):
#   /app 안에서 APP_JAR_GLOB 패턴의 JAR을 찾아 java로 실행
JAR="$(ls /app/${APP_JAR_GLOB} 2>/dev/null | head -n1)"
if [ -z "$JAR" ]; then
  echo "[오류] /app 안에서 '${APP_JAR_GLOB}' 패턴에 맞는 JAR 파일을 찾지 못했습니다." >&2
  ls -la /app >&2
  exit 1
fi
echo "[정보] 실행 대상 JAR: $JAR"
exec java $JAVA_OPTS -Dloader.path=$LOADER_PATH -jar "$JAR"
