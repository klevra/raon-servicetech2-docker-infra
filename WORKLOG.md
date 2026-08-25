# 작업 로그

규칙 5번("모든 진행사항 및 변경사항은 마크다운 파일로 기록하기")에 따라 작업 진행 상황을 기록하는 파일입니다.
규칙 자체의 변경 이력은 [RULES.md](RULES.md)에서 별도 관리합니다.

---

## 2026-08-13

### Claude Code 터미널 설치 및 PATH 문제 해결

**상황**
- VSCode 확장으로는 Claude Code를 사용 중이었으나, 터미널(PowerShell)에서 `claude` 명령이 인식되지 않음 (`CommandNotFoundException`).

**진행 과정**
1. 설치 방법 안내: npm 방식(`npm install -g @anthropic-ai/claude-code`, Node.js 필요) vs 네이티브 설치 스크립트(Node.js 불필요 — 단 정확한 동작 방식은 미확인) 두 가지 옵션 제시.
2. **실제 사용한 설치 방법**: 네이티브 설치 스크립트로 진행.
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```
   설치 결과 실행 파일이 `C:\Users\ABC\.local\bin`에 생성됨.
3. 사용자가 설치 완료 후, 환경변수 PATH에 `C:\Users\ABC\.local\bin` 추가.
4. 그래도 VSCode 통합 터미널에서 `claude` 명령 미인식.
5. 원인 분석: VSCode 프로세스가 PATH 변경 이전에 실행 중이었기 때문에, 통합 터미널이 갱신된 PATH를 물려받지 못한 것으로 진단.
6. VSCode 완전 재시작으로 해결.

**결론 / 원인**
- Windows에서 시스템/사용자 PATH 환경변수를 변경해도, 이미 실행 중인 프로그램(VSCode 등)은 그 변경을 자동으로 인식하지 못한다. 해당 프로그램을 완전히 종료 후 재실행해야 새 PATH가 반영됨.

**상태**: ✅ 해결 완료 (2026-08-13)

**참고**: 향후 유사 증상(새로 설치한 CLI 도구가 VSCode 터미널에서만 안 잡히는 경우) 발생 시, "VSCode 밖에서 새 터미널 먼저 테스트 → 되면 VSCode 재시작"이 1차 점검 절차로 재사용 가능.

---

### 기본 규칙(RULES.md) 수립
- 사용자 요청으로 6개 기본 작업 규칙 문서화. 상세 내용 및 변경 이력은 [RULES.md](RULES.md) 참고.
- 4번 규칙(`/remote-control`)은 Skill 도구가 아닌 VSCode 확장 내장 명령/설정임을 확인, "Enable Remote Control for all sessions" 토글로 이행 방식 확정.

---

### DB 종류별 라이선스 분류
- Docker Registry 서버 구축에 앞서, 대상 DB 11종(altibase/cubrid/db2/goldilocks/infomix/mariadb/mssql/mysql/oracle/postgresql/tibero)을 라이선스 관점에서 분류.
  - 라이선스 불필요: PostgreSQL, MariaDB, MySQL(Community), CUBRID, Altibase(오픈소스 전환 버전)
  - 테스트/개발용 무료, 운영은 라이선스 필요: Oracle, MSSQL, DB2, Informix (모두 공식 Free/Developer/Community 에디션 존재)
  - 라이선스 필수(테스트조차 벤더 확인 필요): Tibero, Goldilocks

### Oracle 19c Enterprise Edition 테스트 컨테이너 수동 구축
**목표**: Oracle 19c를 테스트용 Docker 컨테이너로 구축 (SID=VERIFIER, 휘발성, AL32UTF8, 기본 포트).

**시행착오 및 원인**
1. 19c는 Express Edition(XE)이 없어 `container-registry.oracle.com` 공식 레지스트리(Enterprise Edition)가 필수 — 로그인 없는 커뮤니티 이미지로는 19c 확보 불가.
2. `docker login container-registry.oracle.com`이 올바른 계정 비밀번호로도 계속 `unauthorized: Auth failed` 발생.
   - 2FA 비활성화, 비밀번호 재설정 등을 시도했으나 모두 실패 (원인 아니었음).
   - **실제 원인**: 2025-06-30부로 Oracle이 이 레지스트리의 인증 방식을 SSO 비밀번호에서 **Auth Token**으로 전환함. `container-registry.oracle.com` 계정 메뉴 > "Auth Token" 발급 후 그 값을 비밀번호 자리에 사용해야 로그인 성공.
3. Oracle XE는 SID가 항상 `XE`로 고정(제품 특성). SID를 임의값으로 지정하려면 Enterprise/SE2 이미지가 필요함 — 이번엔 19c EE라서 `ORACLE_SID=VERIFIER`로 자유롭게 지정 가능했음.
4. 19c EE는 SYS/SYSTEM 비밀번호가 Oracle 권장 복잡도(대문자+소문자+숫자)에 안 맞아도 **경고만 뜨고 생성은 계속 진행**됨 (차단 아님) — `theg3p2`로 정상 진행 확인.

**결과**: `oracle19c-test` 컨테이너 정상 기동 확인 (`Up ... (healthy)`), `system/theg3p2@localhost:1521/VERIFIERPDB` 접속 및 `INSTANCE_NAME=VERIFIER, STATUS=OPEN` 확인 완료. 데이터는 휘발성(볼륨 미사용).

**보안 참고**: 이 과정에서 사용자 Oracle 계정 비밀번호와 Auth Token이 대화 로그에 노출됨. 사용자 확인 하에 회전(rotate)하지 않고 유지하기로 결정.

### Oracle 테스트 설치 인터랙티브 스크립트 1차 작성 (`oracle/install-oracle.sh`, `.ps1`)
- 위 수동 구축 경험을 재사용 가능하게 일반화한 대화형 스크립트. 에디션(19c EE / 21c XE / 18c XE) 선택, Auth Token 로그인, SID/PDB/문자셋/포트/비밀번호/데이터 영속성 여부를 프롬프트로 입력받아 `docker run`까지 자동화.
- **인코딩 이슈 발견 및 해결**: `install-oracle.ps1`이 BOM 없는 UTF-8로 저장되어 있어 Windows PowerShell 5.1이 한글을 시스템 코드페이지(CP949)로 오인식 → 파서 오류 발생. UTF-8 **with BOM**으로 재저장하여 해결 확인(`ParseFile` 결과 `SYNTAX_OK`). 이후 한글 포함 `.ps1` 파일은 항상 BOM 포함 UTF-8로 저장하기로 함.
- 이 1차 스크립트는 이후 Dockerfile 기반 레지스트리/배포 구조(`PRD.md` 참고)로 재설계되며 대체될 예정.

### Oracle 레지스트리·배포 구조 PRD 작성 (`oracle/PRD.md`)
- 요청 배경: 최초 목표였던 "Docker Registry 서버 구축"을 Oracle 사례로 실제 진행. 로컬 프라이빗 레지스트리(`localhost:5000`) → 베이스 이미지 등록 → 배포용 Dockerfile/스크립트의 3단계 구조로 설계.
- 설정 항목 7가지 확정: DB종류, Oracle 버전(이상 레지스트리용) / 스키마, 계정 ID·PW, DDL SQL 경로, DML SQL 경로, 포트(이상 배포용 변수).
- 핵심 설계 결정: 계정정보는 이미지에 절대 베이킹하지 않고 런타임 주입만 허용, DDL/DML SQL은 Oracle 공식 `/opt/oracle/scripts/setup` 자동실행 기능을 접두어(10_/50_) 방식으로 활용해 순서 보장.
- 상세 내용, 아키텍처 다이어그램, 리스크 목록은 [oracle/PRD.md](oracle/PRD.md) 참고.
- **상태**: PRD 작성 완료, 실제 구현(레지스트리 스크립트/base Dockerfile/deploy Dockerfile)은 다음 단계로 진행 예정.

### 레지스트리 이름 확정 + 3단계 구조 실제 구현 및 종단간 검증 완료
**이미지 네이밍 확정**: `localhost:5000/servicetech2/oracle:19c` (레지스트리 `localhost:5000` + 네임스페이스 `servicetech2` + 리포지토리 `oracle` + 태그로 버전 관리). `servicetech2/oracle-19c`처럼 호스트 지정 없이 쓰면 Docker Hub로 오인식되는 점을 확인하고 이 형식으로 정정.

**1단계 — 레지스트리 서버** (`oracle/registry/`)
- `docker-compose.yml`(공식 `registry:2`, `servicetech2-registry` 컨테이너, `localhost:5000`) + `setup-registry.sh/.ps1`
- 실행 및 `hello-world` 이미지로 push/pull 왕복 스모크 테스트 통과 확인.

**2단계 — 베이스 이미지** (`oracle/base/`)
- `Dockerfile`(`ARG BASE_IMAGE`로 상위 이미지 재태깅) + `build-and-push.sh/.ps1`(DB종류/버전 선택 → 상위 이미지 pull → build → push)
- `container-registry.oracle.com/database/enterprise:19.3.0.0` → `localhost:5000/servicetech2/oracle:19c` 로 실제 push 성공, 레지스트리 카탈로그(`/v2/_catalog`)에서 확인.

**3단계 — 배포** (`oracle/deploy/`)
- `Dockerfile`(`ARG REGISTRY_IMAGE`) + `deploy.sh/.ps1` — DB종류/버전/스키마(SID·PDB)/계정(SYS·SYSTEM 비밀번호)/DDL 경로/DML 경로/포트(리스너·EM Express) 7개 항목을 대화형으로 입력받아 배포.
- DDL·DML은 스테이징 폴더에 `10_`/`50_` 접두어로 합쳐 Oracle 공식 `/opt/oracle/scripts/setup` 자동실행 디렉터리에 마운트하는 방식으로 순서 보장.

**발견 및 수정한 버그**
1. **Windows Git Bash(MSYS) 경로 변환 버그**: `docker run -v SRC:DEST:MODE` 인자에서 MSYS가 `/`로 시작하는 부분을 전부 Windows 경로로 잘못 변환 — 호스트 경로뿐 아니라 **컨테이너 내부 경로까지** 오염시켜(`/opt/oracle/scripts/setup` → `\Program Files\Git\opt\...`) 바인드마운트가 빈 폴더가 되는 문제 발생. `export MSYS_NO_PATHCONV=1`을 스크립트 상단에 추가하여 해결 (`deploy.sh`, `install-oracle.sh` 모두 반영). Linux/macOS 순정 bash에는 영향 없음.
2. **setup SQL의 실행 계정 확인**: Oracle 공식 이미지의 setup 단계는 `sqlplus "/ as sysdba"`로 실행되어 DDL/DML로 만든 객체가 기본적으로 **SYS 스키마 소유**가 됨. 특정 앱 스키마로 만들려면 SQL 파일 안에서 직접 스키마/계정을 지정해야 함(사용 시 주의사항으로 문서화).

**종단간 검증**: 19c EE 배포 → 컨테이너 healthy 확인 → DDL(`CREATE TABLE`) → DML(`INSERT` + `COMMIT`) 순서대로 자동실행 확인 → `sys.verifier_test` 조회로 데이터 존재 확인까지 전 과정 성공.

**상태**: ✅ 1~3단계 스크립트·Dockerfile 작성 및 실제 실행 검증 완료. 테스트에 사용한 컨테이너(`oracle19c-test`, `oracle19c-deploy-test`)는 검증 후 삭제(사용자 확인 하에), 레지스트리 서버(`servicetech2-registry`)는 계속 유지 중. PRD의 리스크 섹션에 검증 결과 반영 완료.
- 상세 내용은 [oracle/PRD.md](oracle/PRD.md) 참고.

### 사내 Linux Docker Registry 서버 구축 가이드 작성
- 지금까지는 이 Windows PC의 `localhost:5000`에 레지스트리를 구축했으나, 별도로 **이미 Docker가 설치된 사내 Linux 서버**에도 레지스트리를 구축하는 요청이 들어와 별도 가이드 문서로 정리.
- 확정된 값: 호스트명 `servicetech2-registry` (hosts 파일에 등록해서 사용), 포트 `5000`, 인증 미적용(사내망 신뢰 전제, 필요 시 나중에 htpasswd 추가 가능하도록 가이드에 포함).
- localhost가 아니므로 Docker의 "로컬호스트 자동 insecure 허용" 특례가 적용되지 않아, **push/pull 하는 모든 클라이언트에 `insecure-registries` 설정이 필수**라는 점을 문서에 명시.
- 상세 명령어는 [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md) 참고. (이 Linux 서버에서 직접 실행/검증은 아직 하지 않음 — 사용자가 실행 예정)

### 사내 Linux 서버 Docker 버전 확인 및 24→28→29 업그레이드 계획
- 사용자가 rootless 적용을 검토했으나, 해당 서버가 외부 인터넷 접근이 막혀있을 가능성이 있어(정확한 오프라인 여부는 `nslookup get.docker.com`/`docker pull hello-world`로 재확인 필요, 최초 테스트는 `nslookup https://...` 형식 오류로 결론 유보) rootful로 진행하기로 결정.
- 현재 Docker 버전 확인: **24.0.9**.
- 28/29로의 업그레이드 영향도를 웹 검색으로 조사(출처는 PRD 대화 참고): **Docker 29는 API 최소 버전이 1.41→1.44로 상향**되어 24.x 클라이언트와 호환 깨짐, containerd 이미지 스토어가 기본값이 되며 `docker push` 매니페스트 형식도 변경됨. **28은 API 호환 유지되어 리스크 낮음.**
- **결정**: 24 → 28로 먼저 업그레이드하여 검증 후, 이후 별도로 29 진행. 절차서는 [registry-server/docker-upgrade-24-to-28.md](registry-server/docker-upgrade-24-to-28.md) 참고. (아직 실제 서버에서 실행 전 — 사용자가 직접 실행 예정)

### GitHub 저장소 연동 (RULES.md 7번 규칙 신설)
- 프로젝트를 GitHub에 등록하기로 결정. **저장소**: `raon-servicetech2-docker-infra` (private) — https://github.com/klevra/raon-servicetech2-docker-infra
- 신규 규칙: WORKLOG.md는 저장소에 포함(추적)하되, **WORKLOG.md만 변경되고 실질적 변경사항이 없으면 커밋/푸시하지 않음** — 로그만 있는 커밋으로 히스토리가 지저분해지는 것 방지. 실질적 변경이 있으면 매번 묻지 않고 자동 commit+push (지속적 승인으로 간주). 상세는 [RULES.md](RULES.md) 7번 참고.
- 진행 과정: GitHub CLI(`gh`) 미설치 확인 → `winget`으로 설치 → 사용자가 직접 `gh auth login`으로 브라우저 인증 → `git init -b main` + `.gitignore`/`.gitattributes` 작성(로컬 설정 파일, 배포 임시 스테이징 폴더, 자동생성 `.env` 등 제외) → 초기 커밋(19개 파일) → `gh repo create --private --push`로 저장소 생성과 동시에 push 완료.
- **상태**: ✅ 완료. 이 로그 항목 자체는 위 규칙에 따라 다음 실질 변경 시점에 같이 커밋됨(별도 즉시 push 안 함).

### 사무실 PC로 작업 환경 이관 준비
- 배경: 지금까지 작업하던 PC는 사용자 개인 메인 PC이고, 실제 작업은 사무실 PC에서 진행될 예정.
- 결정: 사무실 PC에서는 이 PC의 로컬 레지스트리(`localhost:5000`)를 별도로 재구축하지 않고, 이미 구축해 둔 **사내 Linux 레지스트리(`servicetech2-registry`)만 사용**.
- **스크립트 변경**: `oracle/base/build-and-push.sh(.ps1)`, `oracle/deploy/deploy.sh(.ps1)` 4개 파일에서 레지스트리 주소(`localhost:5000`)가 하드코딩되어 있던 것을 **대화형 입력(+ `REGISTRY_ADDR` 환경변수로 기본값 오버라이드 가능)** 방식으로 변경 — 같은 스크립트를 이 PC(localhost:5000)와 사무실 PC(servicetech2-registry:5000) 양쪽에서 그대로 재사용 가능해짐.
- 변경 후 `build-and-push.sh`로 프롬프트/기본값 동작 재검증(정상). 다만 검증 도중 이 PC의 Docker Desktop 데몬 자체가 응답 없음 상태가 되어 최종 push까지는 확인 못 함 — 스크립트 로직 자체는 문제없음, 데몬 재시작 후 재확인 필요.
- 사무실 PC에서 그대로 따라 할 수 있는 온보딩 체크리스트를 [OFFICE-SETUP.md](OFFICE-SETUP.md)로 작성 (저장소 클론, `gh auth login`, hosts/insecure-registries 설정, Oracle Auth Token 재발급 필요성, VSCode Remote Control 토글 등 이관되지 않는 설정 안내 포함).
- **상태**: 스크립트 변경 및 가이드 문서 작성 완료. 사무실 PC에서의 실제 실행/검증은 사용자가 진행 예정.

---

## 2026-08-18

### 팀서버 Docker 업그레이드 계획 수립 (Rootful vs Rootless 결정)

**상황**
- 팀서버(Oracle Linux 8.10, Kernel 5.15.0-306) 확인 결과
  - Docker 24.0.9 (dnf 패키지 설치 ✅ — 소스 빌드 아님)
  - 현재: rootful 운영 (root 권한)
  - 아직 컨테이너 없음 (레지스트리 미배포 = 마이그레이션 불필요)
  - daemon.json 커스텀 설정 없음 (깨끗한 상태)

**선택지 분석 및 결정**
- **Option A (Rootful 유지)**: Docker 28로만 업그레이드 → 간단하지만 보안 제약
- **Option B (Rootless 완전 전환)** ✅ **선택** → 보안 강화, 지금이 최적 타이밍
- **Option C (단계적 전환)**: Rootful 유지 후 나중에 전환 → 리스크 분산

**선택 사유**
1. 최적 타이밍: 컨테이너 0개, 설정 없음 → 처음부터 rootless로 시작 가능
2. 보안 고려: 프라이빗 레지스트리 = 중요 자산 → root 권한 노출 제한 필수
3. 기술 호환: Kernel 5.15.0-306 + user namespace 완벽 지원
4. 운영성: 포트 5000 (>1024) → rootless에서 직접 바인드 가능

**산출물**
- [TEAM-SERVER-ANALYSIS.md](TEAM-SERVER-ANALYSIS.md) — 현황 분석 + 3가지 선택지 비교표 (Rootful vs Rootless)
- [registry-server/docker-rootless-setup-oracle8.md](registry-server/docker-rootless-setup-oracle8.md) — Oracle Linux 8.10 Rootless 설치 상세 가이드 (Phase 1-6)
  - Phase 1: Rootful 제거
  - Phase 2: Rootless 설치 (subuid/subgid, systemd --user 통합)
  - Phase 3: 검증
  - Phase 4: 레지스트리 재구성
  - Phase 5: 버전 업데이트 (Optional)
  - Phase 6: 최종 검증

**다음 단계**
- 팀서버에서 Phase 1~4 실행 (사용자 직접 수행 예정)
- 레지스트리 정상 작동 후 추가 기능 테스트 (push/pull, Oracle 이미지 등)
- Phase 5에서 Docker 28 또는 29로 업그레이드 결정

**사전 확인 추가**: 사용자 지적으로 **네트워크/패키지 연결성 확인**의 중요성 강조 및 Phase 0 추가
- dnf 패키지 서버 연결 확인 (Docker 설치 가능 여부)
- Docker Hub / 웹서버 통신 확인 (이미지 다운로드 가능 여부)
- 4가지 시나리오 별 대응 방법 정리 ([TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md))

**산출물 (추가)**:
- [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md) — Phase 0 네트워크/패키지 연결성 확인 (필수)
  - 5가지 확인 항목 체크리스트
  - 4가지 문제 시나리오 + 대응 방법
  - 정상/대체/오프라인 설치 경로
  
- [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) — 전체 배포 가이드 (통합 진입점)
  - 모든 문서 네비게이션
  - 빠른 시작 (정상 환경)
  - 의사결정 흐름도
  - 문제 해결 종합 테이블

**권한 정보 추가**: 사용자 재지적으로 Phase 0에서 **root 권한인지 일반 사용자인지 확인** 필수로 추가
- Phase 0 0단계: 현재 권한 확인 (`whoami`, `id`)
- Phase별 권한 구분: ✅ 일반 사용자 가능 / 🔴 sudo 필수
- 모든 명령어에 권한 표시 ($=일반사용자, #=root)
- Phase 0~6에 동일 정보 추가로 일관성 유지

**팀서버 실행 결과 및 진단**:

**네트워크 진단 결과** (2026-08-18 팀서버 실행 후 분석):
- ✅ DNS: 작동 (get.docker.com → IP 주소 반환)
- ❌ 외부 인터넷: **완전 차단** (8.8.8.8, 1.1.1.1 모두 ping 100% loss)
- ❌ Docker Hub: 접근 불가 (timeout)
- ❌ Docker 저장소: 미등록/접근 불가
- ✅ 기존 rootful Docker: 설치됨

**결론**: 🔴 **완전 오프라인 환경 확정**

**산출물**: [TEAMSERVER-OFFLINE-DIAGNOSIS.md](TEAMSERVER-OFFLINE-DIAGNOSIS.md)

**현재 추천**:
1. IT팀에 네트워크 정책 확인 요청
2. 오프라인 바이너리 지원 가능 여부 확인
3. 기존 rootful Docker 유지 (Phase 1~6 실행 중단)

**상태**: ⏳ IT팀 응답 대기. 재설치 계획 변경 필요 (온라인 → 오프라인 모드)

### 오프라인 배포 계획 수정 (새로운 전략)

**새로운 상황** (사용자 추가 정보):
- 팀서버: 완전 오프라인 (정상 정책) ✅
- 외부 VM: Oracle Linux 8.10, 인터넷 가능 ✅
- 패키지 반입: 가능 (USB/SCP 등) ✅
- 팀장 승인: 이미 획득 ✅
- 기존 이미지: 불필요 (제거 가능) ✅

**새로운 전략: 2단계 배포**
1. **Phase A** (외부 VM, 1~2시간):
   - Rootless Docker 설치
   - 필요한 바이너리 + 이미지 (registry:2) 다운로드
   - docker-offline-package.tar.gz 생성

2. **Phase B** (파일 전달, 5~10분):
   - 외부 VM → 팀서버로 패키지 파일 이동 (USB/SCP)

3. **Phase C** (팀서버, 20~30분):
   - 기존 Docker 제거
   - Rootless 바이너리 수동 설치
   - 이미지 로드

4. **Phase D** (팀서버, 10~15분):
   - 레지스트리 컨테이너 구성

**총 소요 시간**: ~70분

**산출물**: [OFFLINE-DEPLOYMENT-PLAN.md](OFFLINE-DEPLOYMENT-PLAN.md)
- Phase A~D 상세 절차
- 체크리스트
- 롤백 방법
- IT팀 협의 불필요 (기술적으로 완전 해결)

**상태**: ✅ 새로운 계획 완성. 외부 VM에서 Phase A부터 시작 가능
