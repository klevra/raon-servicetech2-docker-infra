# PRD: Oracle DB 테스트/배포용 Docker 구조

- 작성일: 2026-08-13
- 작성자: 사용자 요청에 따라 Claude Code가 초안 작성
- 상태: 초안 (구현 착수 전 검토용)

---

## 1. 배경 및 목적

`RULES.md`의 상위 목표인 "Docker Registry 서버 구축"의 첫 사례로, **Oracle Database를 프라이빗 레지스트리에 등록하고, 그 이미지를 기반으로 실제 테스트 DB를 반복 가능하게 배포**할 수 있는 구조를 만든다.

이번 작업 전, 수동으로 Oracle 19c Enterprise Edition 컨테이너를 성공적으로 띄운 경험(계정 인증 Auth Token 이슈, SID 지정, 문자셋 등)이 있으며, 이 PRD는 그 경험을 **재사용 가능한 스크립트/이미지 구조**로 일반화하는 것이 목적이다.

## 2. 용어 정의

| 용어 | 의미 |
|---|---|
| 베이스 이미지 | Oracle 공식/커뮤니티 이미지를 그대로(또는 최소 가공하여) 프라이빗 레지스트리에 재등록한 이미지. 계정/스키마/SQL 등 배포별 정보는 포함하지 않음 |
| 배포 이미지/컨테이너 | 베이스 이미지를 `FROM`으로 삼아, 실제 스키마·계정·초기화 SQL이 적용된 실행 중인 인스턴스 |
| 레지스트리 | 사내(로컬) 프라이빗 Docker Registry (`localhost:5000`) |

## 3. 범위

### 포함(In Scope)
- 로컬 프라이빗 Docker Registry 서버 구축
- Oracle DB(19c EE / 21c XE / 18c XE)를 레지스트리에 등록하는 베이스 이미지 빌드·푸시 스크립트
- 베이스 이미지를 사용해 실제 테스트 DB를 대화형으로 배포하는 Dockerfile + 스크립트(bash/PowerShell)
- 아래 **7개 설정 항목**의 대화형(interactive) 입력 처리

### 제외(Out of Scope, 이번 PRD 기준)
- Oracle 외 DB(PostgreSQL, MariaDB 등)의 레지스트리 등록 — 구조만 확장 가능하게 설계, 실제 구현은 후속 작업
- 운영(Production) 환경 배포, 고가용성/백업/복제 구성
- 레지스트리의 외부 노출, TLS/인증서, 사용자 인증(Auth) 적용 — 로컬 전용으로 한정
- CI/CD 파이프라인 연동

## 4. 요구사항 상세 (설정 항목 7가지)

| # | 항목 | 관리 시점 | 기본값 | 비고 |
|---|---|---|---|---|
| 1 | DB 종류 | 레지스트리(베이스 이미지 빌드) 시점 | Oracle (고정) | 향후 다른 DB 추가 시 선택지 확장 |
| 2 | Oracle 버전 | 레지스트리(베이스 이미지 빌드) 시점, 이미지 태그로 관리 | 19c EE | 21c XE / 18c XE 선택 가능 |
| 3 | 스키마(서비스명/PDB명) | 배포 시점, 변수 | `VERIFIER`류 사용자 입력 | 컨테이너 실행 시 ENV로 주입 |
| 4 | 계정 정보(ID/PW) | 배포 시점, 변수 | 없음(필수 입력) | **이미지에 절대 베이킹하지 않음**, `docker run -e`로만 주입 |
| 5 | DDL SQL 파일 경로 | 배포 시점, 변수 | 없음(선택 입력) | 호스트 폴더 경로, 바인드마운트 |
| 6 | 초기데이터 DML SQL 파일 경로 | 배포 시점, 변수 | 없음(선택 입력) | 호스트 폴더 경로, 바인드마운트, **DDL 이후 실행 보장** |
| 7 | 포트 | 배포 시점, 변수 | 리스너 1521 / EM Express 5500(EE만) | 대화형 입력, 미입력 시 기본값 |

## 5. 시스템 아키텍처

```
[1단계: 레지스트리 서버]
   registry:2 컨테이너 (localhost:5000, 로컬 전용)
        │
        ▼  (docker push)
[2단계: 베이스 이미지 빌드/등록]
   상위 이미지 선택(container-registry.oracle.com 또는 gvenzl)
        │  docker build --build-arg BASE_IMAGE=...
        ▼
   localhost:5000/oracle:19c  (예시 태그)
        │
        ▼  (docker pull, FROM)
[3단계: 배포]
   deploy/Dockerfile  →  FROM localhost:5000/oracle:19c
   deploy.sh / deploy.ps1
     - 스키마/계정/포트 대화형 입력 → docker run -e 로 주입
     - DDL/DML 경로 입력 → 스테이징 폴더 구성 후 -v 바인드마운트
        │
        ▼
   실행 중인 테스트 Oracle 컨테이너 (SID/PDB, 계정, 초기 스키마·데이터 반영 완료)
```

## 6. 단계별 상세 설계

### 6.1 레지스트리 서버 (1단계)
- 이미지: 공식 `registry:2`
- 컨테이너/서버 명칭: `servicetech2` (사용자 지정)
- 바인딩: `localhost:5000` (로컬 전용, 외부 노출 금지)
- 스토리지: named volume으로 영속화 (레지스트리 자체는 휘발성으로 두지 않음 — 등록한 이미지가 사라지면 안 되므로)
- 인증/TLS: 미적용 (로컬 전용이므로 Docker가 `localhost`를 자동으로 insecure 허용하는 특례 사용). **외부에 노출할 계획이 생기면 이 결정을 반드시 재검토해야 함**

### 6.1.1 이미지 네이밍 규칙 (확정)
```
localhost:5000/servicetech2/oracle:19c
localhost:5000/servicetech2/oracle:21c-xe
localhost:5000/servicetech2/oracle:18c-xe
```
- 레지스트리 주소: `localhost:5000`
- 네임스페이스: `servicetech2` (호스트명이 아닌 리포지토리 경로 세그먼트로 사용 — 별도 hosts/daemon 설정 불필요)
- 리포지토리: `oracle` (DB 종류)
- 태그: 버전 (Docker 관례에 따라 태그로 분리 관리, 리포지토리 이름에 버전 포함하지 않음)
- 워크플로우: 이 PC에서 로컬 빌드 → `servicetech2` 레지스트리로 push → 내부 테스트/검증

### 6.2 베이스 이미지 (2단계, "레지스트리용")
- `oracle/base/Dockerfile`: `ARG BASE_IMAGE` 하나만 받아 `FROM ${BASE_IMAGE}`로 재태깅하는 최소 구성 (계정/스키마/SQL 미포함)
- `build-and-push.sh` / `.ps1`: 대화형으로 DB 종류(현재 Oracle 고정) + 버전을 선택받아
  1. 상위 이미지 pull (19c EE는 기존에 검증된 Auth Token 로그인 플로우 재사용)
  2. `docker build --build-arg BASE_IMAGE=<상위이미지> -t localhost:5000/oracle:<태그> .`
  3. `docker push localhost:5000/oracle:<태그>`

### 6.3 배포 (3단계)
- `oracle/deploy/Dockerfile`: `FROM localhost:5000/oracle:<태그>` — 레지스트리 이미지를 그대로 사용, 추가 가공 없음(계정/스키마는 이미지가 아니라 컨테이너 실행 시점 값이므로 Dockerfile에는 로직이 거의 없음. 사실상 `FROM` 한 줄 + 라벨 정도)
- `deploy.sh` / `.ps1`: 대화형으로 3~7번 항목을 입력받아 컨테이너 실행
  - **DDL/DML 처리 방식**: Oracle 공식 이미지의 `/opt/oracle/scripts/setup/` 자동 실행 기능(DB 최초 생성 직후 1회, 파일명 알파벳순 실행) 활용
    - 스크립트가 임시 스테이징 폴더 생성 → DDL 경로의 파일들을 `10_` 접두어로 복사, DML 경로의 파일들을 `50_` 접두어로 복사
    - 스테이징 폴더 하나를 `/opt/oracle/scripts/setup`에 `-v`로 마운트
    - Dockerfile 수정 없이 순서(DDL → DML) 보장
  - **포트 처리**: 리스너 포트 대화형 입력(기본 1521), EE 선택 시 EM Express 포트도 별도 입력(기본 5500). 기존 `install-oracle.sh/.ps1`에 이미 구현된 `port_in_use` 방식(실행 중 컨테이너의 포트와 충돌 여부 사전 경고)을 그대로 재사용

## 7. 보안 설계 원칙

1. **비밀번호/토큰은 어떤 파일에도 저장하지 않는다** — 스크립트 실행 중 변수로만 보관, 사용 직후 폐기(unset/`$null`)
2. **이미지 레이어에 계정정보를 절대 포함하지 않는다** — `ARG`/`ENV`로 비밀번호를 굽지 않음. 레지스트리에 올라가는 순간 그 안의 모든 레이어는 접근 가능한 사람에게 노출된다는 전제로 설계
3. **레지스트리는 로컬 전용을 기본값으로 한다** — 외부 노출 시 인증/TLS 재설계 필요성을 문서에 명시

## 8. 비기능 요구사항

- **크로스플랫폼**: 모든 스크립트는 bash(Linux/macOS/Windows-GitBash)와 PowerShell(Windows) 양쪽으로 작성 (`RULES.md` 6번 규칙)
- **인코딩**: 한글이 포함된 모든 스크립트/문서는 UTF-8(BOM 필요 시 포함) 또는 UTF-16으로 저장. 특히 **Windows PowerShell 5.1은 BOM 없는 UTF-8을 시스템 코드페이지로 오인식**하므로 `.ps1` 파일은 반드시 UTF-8 **with BOM**으로 저장 (이번 대화에서 실제로 파싱 오류가 재현되어 확인된 사항)
- **라이선스 준수**: 19c EE는 OTN 라이선스상 "개발/테스트/데모" 목적에서만 무료 — 이 문서와 스크립트 안내 문구에 반복 명시

## 9. 리스크 및 불확실성

| 항목 | 상태 | 내용 |
|---|---|---|
| `/opt/oracle/scripts/setup` 단일 평면 폴더 + 접두어 방식 | ✅ **실제 검증 완료 (2026-08-13)** | 19c EE 배포로 종단간 테스트: DDL(`10_` 접두어) → DML(`50_` 접두어) 순서대로 정상 자동실행됨 (`Table created.` → `1 row created. Commit complete.` 로그로 확인) |
| Windows Git Bash(MSYS)의 `-v` 바인드마운트 경로 오염 | ✅ **버그 발견 및 수정 완료 (2026-08-13)** | MSYS가 `-v SRC:DEST:MODE` 인자 안의 `/`로 시작하는 부분을 전부 Windows 경로로 잘못 변환(호스트·컨테이너 경로 모두 오염) → 마운트가 빈 폴더로 뜸. `export MSYS_NO_PATHCONV=1`로 해결, `deploy.sh`/`install-oracle.sh`에 반영함 |
| setup SQL 스크립트의 실행 계정 | ✅ **확인 완료 (2026-08-13)** | Oracle 공식 이미지의 setup 단계는 `sqlplus "/ as sysdba"`로 실행되어, DDL/DML 파일 안에서 스키마를 명시하지 않으면 **객체가 SYS 스키마 소유가 됨**. 특정 앱 스키마 소유로 만들려면 SQL 파일 안에서 `CREATE USER`/스키마 지정을 직접 해야 함 |
| gvenzl(XE) 이미지의 `/opt/oracle/scripts/setup` 동작 일치 여부 | 미검증 | EE와 동일한 규칙을 따르는 것으로 알려져 있으나, 실제 XE 경로로 배포 테스트는 아직 진행 전 |
| Oracle 계정 인증(Auth Token)의 만료/재발급 주기 | 미검증 | 베이스 이미지 빌드 스크립트가 매번 새 로그인을 요구할지, 캐시된 자격증명으로 충분할지는 실행 환경(Docker credential store 유지 여부)에 따라 달라짐 |

## 10. 향후 확장 계획

- DB 종류 선택지에 PostgreSQL, MariaDB 등 라이선스 불필요 그룹 추가
- 레지스트리 인증(htpasswd) 및 TLS 적용 옵션화 (외부/팀 공유 전환 시)
- `docker-compose.yml` 기반으로 레지스트리+배포 컨테이너를 한 번에 관리하는 옵션 추가

## 11. 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-13 | 최초 작성. 7개 설정 항목, 3단계 아키텍처(레지스트리/베이스/배포) 확정. 구현은 이후 별도 단계로 진행 예정 |
