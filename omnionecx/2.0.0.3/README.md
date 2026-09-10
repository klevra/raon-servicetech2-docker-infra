# omnionecx — 2.0.0.3

- **레지스트리 저장소: `servicetech2/omnionecx2-{db,verifier,oacx,admin,sample}`**
  (2026-09-09부터). 기존 `servicetech2/omnionecx-*`는 1.0.0.12/fsb/wooriib
  (WAR+jdk8+외장 Tomcat) 전용으로 남기고, 2.0 계열(fat jar+jdk21+내장
  Tomcat, 이 트랙과 aia)만 별도 저장소로 분리했다 — 같은 저장소 안에
  `1.3.42`(1.0.0.12, WAR)와 `1.3.42-springboot-3`(이 트랙, fat jar)처럼
  버전 번호가 겹치거나 비슷해 보이는 태그가 섞여 있어 혼동 위험이 컸음.
  1.0 계열은 이미 운영 배포 중이라 그쪽 저장소/태그는 손대지 않았음.
  기존 `omnionecx-*` 태그는 당장은 정리하지 않고 남겨둠.
- OACX 버전: `2.0.3` (Spring Boot 3 내장 Tomcat 실행형 fat jar, `omnionecx-2.0.3.jar`)
- verifier 버전: `1.3.42-springboot-3` (`Implementation-Version: 1.3.42`, 1.0.0.12와 동일 애플리케이션 버전을 Boot3로 재빌드)
- admin: `omnionecx-admin-2.0.3.jar` — OACX 관리자 콘솔 (신규 컴포넌트, 1.0.0.12/wooriib/fsb에는 없음)
- sample: `mobileid-sample-springboot-1.0-SNAPSHOT.jar` — 앱 호출 테스트 페이지 (신규 컴포넌트. 1.0.0.12는 oacx WAR 안에 번들되어 있었으나, 2.0.0.3의 oacx는 내장 Tomcat fat jar라 정적 페이지를 못 담아 별도 Spring Boot 2.7.18 앱으로 분리 제공됨)

`omnionecx/1.0.0.12/`(default 버전 고정 이미지 트랙)와 큰 틀은 같지만,
패키징 모델이 다릅니다:

- verifier/oacx/admin/sample 모두 외장 Tomcat+WAR가 아니라 **내장 Tomcat 포함
  실행형 fat jar** (`java -jar` + `-Dloader.path=...`로 JDBC 드라이버 등 외부
  lib 로드)
- verifier 설정은 1.0.0.12처럼 여러 개의 `application-*.properties`로 쪼개진
  형태가 아니라 **`application.yml` 단일 파일**로 제공됨 (`deploy/verifier/config/application.yml`).
  같은 폴더에 벤더가 과거 관례로 같이 넣어둔 `application-{sp,mdl-sp,...}.properties`
  류는 `config/_vendor-reference-unused/`로 격리해뒀음 — **실제로 이 둘이
  동시에 로드되면서 빈 값이 application.yml의 실값을 덮어써 verifier가
  기동 실패하는 사고가 실제로 있었음** (spring.profiles.group.common이
  datasource/sp/converter 등을 활성 프로파일로 잡아서, 같은 이름의
  application-{profile}.properties를 자동으로 같이 읽어들임). `application.yml`이
  유일한 기준본.
- oacx는 mybatis 매퍼/기본 설정이 jar 안에 번들되어 있어 별도 매퍼 XML
  마운트가 필요 없음. context-path(`/oacx/api`)/port는 애플리케이션 자체
  설정이라 1.0.0.12처럼 Context XML을 배포 스크립트가 만들어줄 필요가 없음.
- oacx→verifier 호출의 read timeout은 `OACX_PROVIDER.PROVIDER_IF`가 아니라
  **`OACX_SERVICE_PROVIDER.PROVIDER_IF`**(admin 콘솔에서 서비스-provider를
  등록할 때 만들어지는 런타임 데이터, 시드 SQL엔 없음)의
  `connection.timeout` 값이 실제로 쓰인다. 기본값 5000(5초)이 verifier의
  실제 처리 시간(첫 요청 워밍업 포함 최대 20초 관측)보다 짧아서
  `SocketTimeoutException`→`Broken pipe`가 나는 사고가 있었음 — admin에서
  서비스-provider를 새로 등록할 때는 이 값을 30000(30초) 이상으로 설정할 것.

```
db/       -- Dockerfile + build-and-push.sh + initdb/ (이 트랙 전용 DDL/DML, PARTNER_CODE/OPER_SORT 플레이스홀더 패치 방식은 1.0.0.12와 동일)
verifier/ -- Dockerfile + build-and-push.sh (verifier 1.3.42-springboot-3 산출물 빌트인)
oacx/     -- Dockerfile + build-and-push.sh (OACX 2.0.3 산출물 빌트인)
admin/    -- Dockerfile + build-and-push.sh (OACX 관리자 콘솔 2.0.3 산출물 빌트인)
sample/   -- Dockerfile + build-and-push.sh (앱 호출 테스트 페이지 산출물 빌트인)
deploy/   -- deploy.sh, exec.sh, docker-compose.yml (db/verifier/oacx/admin/sample 5개 서비스 오케스트레이션)
```

## 배포 테스트 위치

라이브 기동 테스트는 `omnionecx/2.0.0.3/deploy/`가 아니라 **`sandbox/`**
(리포지토리 루트)에서 진행한다. `sandbox/`에 `deploy/` 트리 전체(verifier·
oacx·admin·sample config + docker-compose.yml + deploy.sh/exec.sh)를
복사해두고 거기서 `./deploy.sh`를 실행하는 방식 — `2.0.0.3/deploy/` 쪽은
소스(기준본) 역할만 하고 실제 기동 테스트로 오염시키지 않는다.

## 포트/타임존/헬스체크 (2026-09-08 확정)

| 서비스 | 포트 | 비고 |
|---|---|---|
| db | 3306 | |
| verifier | 48085 | 1.0.0.12와 동일 포트 관례 |
| oacx | 8080 | context-path `/oacx/api`만 사용 (admin/sample은 별도 context-path 없음) |
| admin | 6443 | |
| sample | 9025 | |

- 전 서비스 `TZ=Asia/Seoul` 고정 (컨테이너가 호스트와 별개로 UTC로 찍히던
  문제 해결 — 컨테이너는 호스트 커널 시계를 그대로 공유하므로 별도 NTP
  데몬은 불필요, 어긋나 보였던 건 타임존 표기 문제였음)
- 전 서비스 JVM에 `-Djava.security.egd=file:/dev/./urandom` 고정 (jdk21
  베이스의 기본 `securerandom.source=file:/dev/random` 대응 — 이번 지연의
  직접 원인은 아니었던 것으로 확인됐으나 예방 차원으로 유지)
- 헬스체크는 `deploy.sh` 실행 시 Y/N으로 선택 가능 (끄면 5개 서비스 헬스체크가
  전부 즉시 통과로 바뀌고 `depends_on` 기동 순서는 그대로 유지됨)

## DB DDL 수정 사항

- `11_mdl-verifier-mariadb.sql`: 벤더가 전달한 원본에 전 테이블 `ID` 컬럼의
  `AUTO_INCREMENT`가 누락되어 있었음(1.0.0.12와 동일 스키마인데 이 속성만
  빠짐) — 11개 테이블 전부 추가.
- `10_mariadb.sql`: `OACX_TEMP_TOKEN.TOKEN` 컬럼이 `TEXT`라 저장 크기가
  부족했음 — `MEDIUMTEXT`로 변경.

## 진행 상태 (2026-09-08 기준)

- [x] db/verifier/oacx/admin/sample 전부 이미지 빌드+레지스트리 등록
      (태그: 실버전 + `2.0.0.3` 이동 태그, 1.0.0.12의 `latest`와 분리)
- [x] `deploy.sh`/`exec.sh` 작성 — 5개 서비스 오케스트레이션, dev/prod
      지갑 전환, DB 접속정보 자동 추출, 헬스체크 옵셔널화 전부 포함
- [x] `sandbox/`에서 라이브 기동 테스트 — 5개 서비스 전부 healthy, HTTP 200
      확인, DB 시딩(VF_ORGANIZATION/OACX_PROVIDER/OACX_ADMIN) 확인
- [x] sample 테스트 페이지를 통한 실제 인증 흐름(getCertInfo → trans/info →
      CA 리스트 → QR 발급) 재현 확인
- [x] oacx↔verifier 타임아웃 문제 원인 규명 및 조치 (위 내용 참고)
- [x] `deploy.ps1`/`exec.ps1`(PowerShell 버전) 작성 완료
- [x] admin 콘솔 서비스-provider 등록 → 모바일 지갑 VP 제출 → 검증까지
      `sandbox/`에서 구현·테스트 완료 (운영측 제출/검증까지 확인)
- [x] admin의 `token.key.jwt`(`OACX-ENT@123456789012345678901234`) — 특정
      옵션이 적용될 때 이 값이 사용/변경되는 정상 동작이며 플레이스홀더가
      아님. 그대로 유지.
