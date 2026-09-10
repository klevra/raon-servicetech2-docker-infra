# omnionecx — AIA생명 백포팅 (aia, 2.0.0.1)

- **레지스트리 저장소: `servicetech2/omnionecx2-{db,verifier,oacx,admin,sample}`**
  (2026-09-09부터). 기존 `servicetech2/omnionecx-*`는 1.0.0.12/fsb/wooriib
  (WAR+jdk8+외장 Tomcat) 전용으로 남기고, 2.0 계열(fat jar+jdk21+내장
  Tomcat, 2.0.0.3/aia)만 별도 저장소로 분리했다 — 같은 저장소 안에
  `1.3.42`(1.0.0.12, WAR)와 `1.3.42-springboot-3`(2.0.0.3, fat jar)처럼
  버전 번호가 겹치거나 비슷해 보이는 태그가 섞여 있어 혼동 위험이 컸음.
  1.0 계열은 이미 운영 배포 중이라 그쪽 저장소/태그는 손대지 않았고,
  2.0.0.3/aia 쪽만 새 이름으로 재푸시(로컬 캐시 이미지 재태깅, 재빌드
  없음)했다. 기존 `omnionecx-*` 태그는 당장은 정리하지 않고 남겨둠.
- 사이트 코드: `aia` (이동 태그)
- OACX 버전: `2.0.0.1` (jar 매니페스트 `Implementation-Version: 2.0.1`이지만
  레지스트리 태그는 트랙 결정에 따라 `2.0.0.1` 사용 — `2.0.1` 아님)
- admin 버전: `2.0.0.1` (jar 매니페스트도 `2.0.1`, 위와 동일한 이유로 태그는 `2.0.0.1`)
- verifier 버전: `1.3.36_fix` (`mdl-verifier-1.3.36-fix.jar`, Spring Boot 2.7.4,
  jdk8 바이트코드 — jdk21 베이스 이미지에서 단독 부팅 테스트로 호환성 확인됨)
- sample: `mobileid-sample-springboot-1.0-SNAPSHOT.jar` — 2.0.0.3의 jar와
  MD5까지 동일(순수 복제본)

cx 2.0 계열(2.0.0.3과 동일 세대)의 백포팅 버전으로, **2.0.0.3 트랙을 그대로
베이스로 구축**했다 — Dockerfile/build-and-push/docker-compose/deploy 스크립트
전부 2.0.0.3의 것을 사이트 라벨만 바꿔 재사용. `application.yml`도 2.0.0.3의
완성본을 통째로 복사한 뒤 aia 고유 값(siteKey, service-id/task-code, dev
페이크유저, rsdcard 계열 claims의 cardsn 필드)만 별도로 반영했다.

```
db/       -- Dockerfile + build-and-push.sh(.ps1) + initdb/ (2.0.0.3의 완성 DDL/DML 재사용)
verifier/ -- Dockerfile + build-and-push.sh(.ps1) (verifier 1.3.36_fix 산출물 빌트인)
oacx/     -- Dockerfile + build-and-push.sh(.ps1) (OACX 2.0.0.1 산출물 빌트인)
admin/    -- Dockerfile + build-and-push.sh(.ps1) (OACX 관리자 콘솔 2.0.0.1 산출물 빌트인)
sample/   -- Dockerfile + build-and-push.sh(.ps1) (앱 호출 테스트 페이지 산출물 빌트인)
deploy/   -- deploy.sh(.ps1), exec.sh(.ps1), docker-compose.yml (2.0.0.3 템플릿 재사용)
```

## 2.0.0.3과의 차이점 (실제로 손댄 부분만)

- **verifier jar가 다르다**: 2.0.0.3은 Boot3(`1.3.42-springboot-3`)이고
  aia는 Boot 2.7.4(`1.3.36-fix`, jdk8 바이트코드)다. jdk21 베이스 이미지
  에서도 문제없이 뜨는 것은 확인했지만, **JPA dialect 설정이 서로 다르다**
  — 2.0.0.3의 jar에는 `com.raon.mdl.config.database.jpa.CustomMariaDBDialect`
  클래스가 들어있지만 aia의 jar에는 없어서(`ClassNotFoundException`) 2.0.0.3
  config를 그대로 복사했을 때 기동이 실패했다.
  처음엔 dialect를 아예 비우고 Hibernate 자동 감지에 맡겼으나(1.0.0.12
  벤더 설정의 "dialect 자동 설정되므로 따로 지정하지 않음" 안내를 따름),
  자동 감지는 부팅 시점에 DB로 실제 커넥션을 맺어 메타데이터를 읽어야만
  동작해서, DB가 healthy 판정된 직후의 아주 짧은 순간에도 연결이 한 번
  실패하면 재시도 없이 그대로 기동 실패하는 레이스 컨디션이 실제로
  발생했다(`HibernateException: Access to DialectResolutionInfo cannot
  be null when 'hibernate.dialect' not set`, 운영 테스트 중 재현됨).
  **최종적으로는 aia의 jar에 번들된 Hibernate 5.6.11 정식 MariaDB dialect
  클래스(`org.hibernate.dialect.MariaDB103Dialect` — 벤더 커스텀 클래스가
  아니라 Hibernate 자체 제공, 클래스 존재 확인됨)를 명시적으로 지정**해서
  부팅 시 DB 연결 없이도 dialect가 즉시 결정되도록 고쳤다
  (`deploy/verifier/config/application.yml`의 `spring.jpa.database-platform`).
- **verifier `mdl.sp.httpclient-conn-timeout`을 1000ms → 5000ms로 상향**:
  2.0.0.3과 동일한 벤더 기본값(1000ms)을 그대로 썼으나, 외부 정부 블록체인
  서버(`bcdev.mobileid.go.kr`/`pub.mobileid.go.kr`, DID 조회용) 호출에서
  `SocketTimeoutException: Connect timed out`이 1회 재현됨 — 벤더 주석상
  이 값은 다중 노드 페일오버용으로 일부러 짧게 잡은 것이지만, `rcp-host`에
  노드가 1개뿐이라 페일오버 이점 없이 순간 지연에 취약하기만 해서 여유
  있게 늘렸다.
- **oacx `mybatis.configuration.cache-enabled: false` — 시도했다가 롤백함**:
  oacx의 `ProviderMapper`(jar 내장 mapper.xml)에 `<cache
  flushInterval="30000" readOnly="true"/>` 2차 캐시가 걸려있는데,
  `OACX_SERVICE_PROVIDER`/`OACX_PROVIDER`는 admin 콘솔로 등록하는 데이터이고
  **admin과 oacx는 서로 다른 JVM 프로세스**라 admin에서 정상 등록해도 oacx
  캐시에는 전혀 통보되지 않는다 — 등록 직후 oacx가 여전히 예전 상태(또는
  없음)로 캐싱된 결과를 반환해 `OACX_PROVIDER_INFO_NOT_FOUND_SERVER_ERROR`
  ("인증사업자 정보를 찾을 수 없음")가 재현된다. jar 내장 mapper.xml은
  직접 수정할 수 없어서, 한때 MyBatis 설정으로 캐시 자체를 전역
  비활성화했었다.
  **하지만 이 설정을 켜두면 SQL 로그상으로는 `findByServiceIdAndProviderId`가
  행을 정상적으로 찾아왔는데도(`Total: 1`, Row 데이터까지 로그에 찍힘) Java
  쪽 `Optional<Provider>`는 비어있는 것으로 처리되는 더 심각한 문제가
  매번 재현됨을 확인** — 원인 미확정(캐시를 끄면 MyBatis Executor 종류가
  바뀌면서 이 매퍼의 Optional 매핑이 어긋나는 것으로 추정되나 100% 확정
  못함). **결론: `cache-enabled: false`는 롤백하고 캐시를 그대로 켜둔다.**
  admin 콘솔에서 서비스-provider를 등록/수정/삭제한 직후에는
  flushInterval(30초) 이내 재시도하거나, 급하면 oacx 컨테이너를 재기동해서
  캐시를 비울 것 (`deploy/oacx/config/application.yml`에 주석 처리된 상태로
  이 설정과 시도 이력을 남겨둠 — 다시 켜지 말 것).
- **siteKey가 다르다**: oacx/sample 둘 다 aia 전용 빌드에 내장된 값
  (`31jIMz6s/...`)으로 맞춰야 한다 — 2.0.0.3의 값(`tDezHWYbOJ...`)을
  그대로 쓰면 안 됨. 서비스키(service-id/task-code)는 사이트별로 자유롭게
  다를 수 있는 값이라 아이덴티티 문제 없음(aia는 `NEW000000101`/`AIASite`).
- **verifier claims에 `cardsn` 필드 추가**: aia 원본 설정에는 rsdcard/
  prmntrsdcard/ovkorrsdcard의 claims 목록에 `staydate` 다음에 `cardsn`이
  하나 더 있었다 — 2.0.0.3 기준 파일에는 없는 항목이라 복사 후 별도로
  추가했다.
- **dev.user 페이크 유저 블록 유지**: oacx의 `application.oper.dev.user`는
  2.0.0.3에는 없는(또는 제거된) 블록이지만, aia는 원본에 있던 걸 유지하기로
  함(테스트 편의용, 운영 배포 시 재검토 필요).
- DB DDL/DML은 2.0.0.3의 완성본(`AUTO_INCREMENT`, `OACX_TEMP_TOKEN.TOKEN`
  MEDIUMTEXT, `OACX_PROVIDER.PROVIDER_IF` timeout 30000 전부 반영됨)을
  그대로 재사용 — aia 원본과 diff 비교 결과 스키마/데이터가 완전히 동일했음
  (placeholder 패턴 차이, timeout 5000→30000 미수정 차이 제외).
- **`OACX_SERVICE_PROVIDER.PROVIDER_IF`의 `body.partnerCode`를 반드시 실제
  `VF_ORGANIZATION.PARTNER_CODE`(배포 시 입력한 값, 기본값 `raon`)와
  일치시켜야 한다** — 벤더가 시드해둔 `OACX_PROVIDER.PROVIDER_IF` 템플릿의
  `partnerCode` 값은 `"oacx"`(예시/데모용 값)로 되어 있는데, 이를 그대로
  `OACX_SERVICE_PROVIDER` 등록에 복사해오면 QR 발급 시 verifier의
  `OrganizationService.getOrganizationData()`가 `VF_ORGANIZATION`에서
  `PARTNER_CODE='oacx'`를 찾지 못해 `errorCode=50001`("이용기관의 ID가
  미존재합니다")로 실패한다. `raon`으로 수정한 뒤 QR 발급까지 정상 동작
  확인함(아래 진행 상태 참고).

## 배포 테스트 위치

라이브 기동 테스트는 `omnionecx/aia/deploy/`가 아니라 **`sandbox/`**
(리포지토리 루트)에서 진행한다. `sandbox/`에 `deploy/` 트리 전체를 복사해두고
거기서 `./deploy.sh`를 실행하는 방식 — `aia/deploy/` 쪽은 소스(기준본) 역할만
하고 실제 기동 테스트로 오염시키지 않는다.

## 포트/타임존/헬스체크

2.0.0.3과 동일 (템플릿 그대로 재사용).

| 서비스 | 포트 | 비고 |
|---|---|---|
| db | 3306 | |
| verifier | 48085 | |
| oacx | 8080 | context-path `/oacx/api`만 사용 |
| admin | 6443 | |
| sample | 9025 | |

- 전 서비스 `TZ=Asia/Seoul` 고정
- 전 서비스 JVM에 `-Djava.security.egd=file:/dev/./urandom` 고정
- 헬스체크는 `deploy.sh` 실행 시 Y/N으로 선택 가능

## 진행 상태 (2026-09-08 기준)

- [x] db/verifier/oacx/admin/sample 전부 이미지 빌드+레지스트리 등록
      (태그: 실버전 + `aia` 이동 태그, `latest`/`2.0.0.3`과 분리)
- [x] `deploy.sh`/`.ps1`, `exec.sh`/`.ps1` 작성 (2.0.0.3 템플릿 기반)
- [x] `sandbox/`에서 라이브 기동 테스트 — 5개 서비스 전부 healthy, HTTP 200
      확인, DB 시딩(VF_ORGANIZATION.APP_CONTENT=`2.0.0.1`, PARTNER_CODE=`raon`,
      OPER_SORT=`dev` placeholder 패치) 확인
- [x] verifier JPA dialect 문제 발견 및 조치 (위 내용 참고)
- [x] sample `/getProperties` 응답에서 siteKey/service-id/task-code/cx-url
      전부 aia 고유 값으로 정상 반영 확인
- [x] `OACX_SERVICE`(`NEW000000101`)/`OACX_SERVICE_PROVIDER` 등록 —
      `services.authen.urls.base`를 `http://verifier:48085`(컨테이너 내부
      주소)로, `connection.timeout`을 `30000`으로 설정해 SQL로 직접 삽입
      (2.0.0.3과 동일한 admin-콘솔-미사용 워크어라운드)
- [x] `partnerCode` 불일치 버그 발견 및 조치 — 위 내용 참고. 사용자가 admin
      콘솔에서 직접 화면으로 QR을 발급하다 verifier 로그에서 `errorCode=50001`
      확인, `OACX_SERVICE_PROVIDER.PROVIDER_IF.body.partnerCode`를
      `"oacx"`→`"raon"`으로 수정 후 재현 테스트로 조치 확인
- [x] sample 플로우(getCertInfo → `/v1.0/trans/info` → `/v1.0/authen/qr/request`)
      curl로 재현 — QR 정상 발급 확인(`resultCode: 200`, `clientMessage: 성공`),
      verifier 쪽 `TransactionGroup`/`TransactionHistory` 저장까지 확인
      (`errorHistories=null`)
- [x] 운영 모드 배포 테스트 진행 — verifier dialect 레이스 컨디션 발견/조치,
      httpclient-conn-timeout 상향 완료. oacx MyBatis 캐시는 비활성화를
      시도했다가 더 심각한 문제(위 참고)가 나와 롤백함
      (전부 위 "2.0.0.3과의 차이점" 참고)
- [x] admin 콘솔 로그인 UI를 통한 실제 서비스-provider 등록 — 사용자가 직접
      admin 콘솔에서 서비스 등록(`HJH000000101`)해서 정상 동작 확인함.
      **단, admin 콘솔의 등록 폼은 `PROVIDER_IF.connection.timeout` 기본값을
      `5000`으로 채워준다 — 반드시 `30000` 이상으로 직접 수정해서 등록할 것**
      (안 그러면 QR 발급 시 verifier 응답을 기다리다 타임아웃 재발).
- [ ] 모바일 지갑 앱으로 실제 QR 스캔 이후의 흐름(VP 제출~검증 완료)은
      미검증 — 실물 지갑 앱이 있어야 재현 가능

## 알아두면 좋은 것 (운영 투입 전 체크리스트)

- **`OACX_SERVICE`/`OACX_SERVICE_PROVIDER`는 admin 콘솔로 등록하는 런타임
  데이터** — DDL/DML 시드에는 없다. DB를 새로 초기화(재배포, 볼륨 삭제 등)할
  때마다 admin 콘솔에서 서비스-provider를 다시 등록해야 한다.
- 등록 시 **`connection.timeout`을 `30000` 이상으로 직접 입력**할 것
  (폼 기본값 `5000`은 verifier 처리 시간보다 짧아 타임아웃 재발).
- 등록 시 **`body.partnerCode`가 `VF_ORGANIZATION.PARTNER_CODE`(배포 시
  입력한 값, 기본 `raon`)와 일치**하는지 확인할 것.
- oacx의 `ProviderMapper` 2차 캐시(30초)는 **그대로 켜져 있다** —
  `cache-enabled: false`로 꺼봤다가 더 심각한 버그가 나와 롤백했다(위
  참고). admin 콘솔에서 서비스-provider를 등록/수정/삭제한 직후 QR 발급이
  "인증사업자 정보를 찾을 수 없음"으로 실패하면, DB 값을 의심하기 전에
  ① 30초 뒤 재시도하거나 ② `docker restart oacx`로 캐시를 비울 것.
