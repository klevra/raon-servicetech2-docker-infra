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

---

## 2026-08-25

### 팀서버 방화벽 오픈 완료 + 클라이언트 접속 검증

- 팀장님 승인 후 팀서버(`new-servicetech2-1`, `192.168.0.168`) 인바운드 5000/tcp 오픈 완료
- 이 PC에서 포트 오픈·레지스트리 API 응답·hosts 별칭(`servicetech2`)·Docker `insecure-registries` 등록까지 전 구간 실제 검증
  - 점검 중 hosts 파일에 예전 초안 이름(`servicetech2-registry`)이 남아있던 걸 발견했다가 재확인 결과 실제로는 `servicetech2`로 정상 등록돼 있었음(터미널 캐시 오류로 확인) — 혼선은 있었지만 실제 설정은 문제없었음
  - `~/.docker/daemon.json`의 `insecure-registries`에 `servicetech2:5000` 항목이 빠져있던 것 발견, 추가

### Oracle 19c EE 이미지 팀서버 레지스트리 등록 (네트워크 이슈 우회)

- `oracle/base/build-and-push.ps1`으로 `servicetech2:5000`에 직접 push 시도 → 특정 레이어에서 반복적으로 `net/http: timeout awaiting response headers` 발생 (대용량 레이어를 실제 네트워크 너머로 push할 때만 발생, localhost 레지스트리에선 문제없었음)
- 재시도할 때마다 이미 성공한 레이어는 `Already exists`로 건너뛰며 조금씩 진전은 있었으나 완주 실패
- **우회 방법으로 전환**: `docker save`로 이미지를 tar 파일(3.4GB)로 저장 → `scp`(포트 220)로 팀서버에 직접 전송 → 팀서버에서 `docker load` → `docker tag` → `docker push localhost:5000/...`(서버 내부 자기 자신에게 push라 네트워크 타임아웃 없음) → 성공
- 이 PC에서 `docker pull servicetech2:5000/servicetech2/oracle:19c`로 최종 검증 (digest 일치 확인)

### 발견 및 수정한 버그 2건

1. **`deploy.sh`/`.ps1`의 배포용 이미지 `docker build` 실패 감지 누락** — `build-and-push`엔 이미 있던 exit code 체크가 `deploy` 쪽엔 없어서, build 실패해도 "빌드 완료"로 잘못 표시되고 이후 `docker run`이 엉뚱한/오래된 이미지를 쓸 수 있었음. 수정 완료.
2. **push 재검증 로직(`docker manifest inspect`)이 insecure 레지스트리에서 오탐** — push는 실제로 성공했는데(`curl`로 태그 조회 성공, `docker pull`도 성공) `docker manifest inspect`만 "no such manifest"라고 잘못 보고하는 것을 발견 (MariaDB 작업 중 재현). `oracle/base`, `mariadb/base` 양쪽 다 레지스트리 REST API(`/v2/.../tags/list`)를 직접 curl/Invoke-WebRequest로 조회하는 방식으로 교체.

### deploy 스크립트 개선

- "대상 레지스트리 주소" 기본값을 `localhost:5000` → 팀서버 IP `192.168.0.168:5000`으로 변경 (`oracle`, `mariadb` 양쪽)
- 신규 기능: 실행 요약/접속 정보를 로그 파일로 저장할지 물어보는 옵션 추가 (기본값 n — 비밀번호가 평문 포함되므로 명시적 동의 필요), `*/deploy/logs/<컨테이너명>_<타임스탬프>.log`로 저장
- 실행 요약/접속 정보에 DB 종류·버전(태그) 표시 추가

### 팀서버 경유 실제 배포 종단간 검증 완료

- `oracle/deploy/deploy.ps1`을 팀서버 레지스트리(`192.168.0.168:5000`) 대상으로 실행, 로컬 Oracle 이미지를 전부 삭제한 "완전히 새로 pull하는" 상태에서 검증
- 애플리케이션 계정 Service Name 방식 / SID 방식 둘 다 실제 컨테이너 생성 + 로그인까지 성공 확인 (계정: `klevra`)
- 검증 도중 이 PC가 메모리 부족(OOM)으로 두 차례 크래시 — 상세는 아래 "WSL2 메모리 이슈" 참고

### WSL2 메모리 이슈 진단 및 해결

- 컨테이너가 `Exited (137)`(SIGKILL, OOM-kill 시그니처)로 죽는 문제 발생. 원인 추적 결과 `.wslconfig`에 걸어뒀던 WSL2 메모리 상한(2GB)이 Oracle 인스턴스의 shared pool 요구치(권장 810MB)보다 여유가 없어 인스턴스 자체가 죽은 것으로 확인 (`DBT-11205` 경고 로그로 사전 확인됨)
- `.wslconfig` 파일 삭제(WSL2 기본값 = 호스트 메모리의 50%, 최대 8GB로 복귀) 후 재배포 시 정상 완주 확인
- 부수적으로 확인된 사실: `wsl --shutdown`만으로는 Docker Desktop이 새 WSL2 백엔드에 재연결이 안 되는 경우가 있고, **Docker Desktop 앱 자체의 완전 재시작**이 필요했음

### MariaDB 배포 구조 신규 구축

- 개인 Vault의 과거 MariaDB 구축 노트(Docker Desktop.md — `docker run` 예시 3종, `MARIADB_ROOT_PASSWORD`/`DATABASE`/`USER`/`PASSWORD`/`TZ` env 조합, 고정 IP `mdl` 네트워크 등)를 참고해, Oracle 스크립트 패턴과 결합한 `mariadb/base`, `mariadb/deploy` 신규 작성
- 설계 결정(사용자 확인): 데이터는 Oracle과 동일하게 휘발성(볼륨 미사용), 네트워크도 Oracle처럼 단순 포트 매핑(예전의 `mdl` 고정 IP 브리지 네트워크는 채택 안 함)
- MariaDB는 Oracle 대비 단순한 지점: 라이선스/Auth Token 불필요, SID/PDB 개념 없음(단일 DB), 앱 계정도 공식 이미지의 `MARIADB_USER`/`PASSWORD`만으로 자동 권한 부여(커스텀 SQL 불필요)
- `mariadb/deploy/Dockerfile`에 `HEALTHCHECK`(`healthcheck.sh`) 직접 추가 — 공식 이미지엔 기본 지정이 없어서, Oracle과 동일한 `docker inspect .State.Health.Status` 폴링 루프를 그대로 재사용할 수 있게 함
- 실제 배포로 pull → build → run → healthcheck → root/앱 계정(`appuser`) 로그인 및 권한(`GRANT ALL PRIVILEGES ON testdb.*`)까지 전부 검증 완료
- 검증 중 발견: 최신 MariaDB 이미지엔 `mysql` 클라이언트 바이너리가 없고 `mariadb`만 존재 — 접속 예시 명령어 수정
- 팀서버 레지스트리에 MariaDB 3개 태그(`latest`, `11.4`, `10.11`) 전부 push 완료

### VSCode 메모리 사용량 진단

- 작업관리자에서 VSCode가 메모리를 과다 점유하는 현상 확인 요청 → 프로세스 트리(`Get-CimInstance Win32_Process`)로 역할별 분해
- 설치된 확장 중 `ms-python.python`/`debugpy`/`vscode-pylance`/`vscode-python-envs` 4종이 이 워크스페이스(순수 Docker/PowerShell 작업)에서 전혀 안 쓰이는데도 Pylance 언어서버(315MB)를 상시 구동 중인 것을 발견
- 사용자가 4종 삭제 후 VSCode 재시작 → 프로세스 15개→11개, 총 메모리 2,426MB→1,968MB로 약 460MB 회수 확인 (확장 삭제 직후엔 이미 떠 있던 Pylance 프로세스가 재시작 전까지 안 죽는다는 점도 확인)

**상태**: ✅ 팀서버 경유 Oracle/MariaDB 배포 파이프라인 전부 실제 검증 완료. 잔여 항목은 [TODO-TEAM-DEPLOY.md](TODO-TEAM-DEPLOY.md) 참고.

### PowerShell 스크립트 한글 깨짐 버그 발생 및 복구

- `mariadb/base/build-and-push.ps1`, `mariadb/deploy/deploy.ps1` 2개 파일이 `Write` 도구로 생성되며 BOM 없이 저장됨 → PowerShell 5.1이 BOM 없는 `.ps1`을 시스템 코드페이지(CP949)로 오독해 한글이 콘솔에서 깨져 표시되는 문제를 사용자가 실제 실행 중 발견
- **1차 시도 실수**: `Get-Content -Raw`로 읽어서 BOM을 붙이려 했으나, 이 방식 자체가 BOM 없는 파일을 CP949로 오독하기 때문에 파일 내용(한글)이 영구히 깨져버림 — 즉시 인지하고 원본 내용을 `Write` 도구로 재작성해 복구
- **최종 수정**: 텍스트 디코딩을 전혀 거치지 않고 바이트 단위(`ReadAllBytes` → `EF BB BF` 접두 → `WriteAllBytes`)로만 BOM을 추가하는 방식으로 안전하게 재작업. 이후 저장소 내 모든 `.ps1` 파일에 이 방식을 표준으로 적용
- 사용자의 `D:\99_project\sandbox\mariadb\` 테스트 복사본도 수정본으로 재동기화, 이후 실제 재실행으로 한글 정상 출력 및 배포 전체 흐름(레지스트리 pull → 빌드 → 컨테이너 생성 → root/앱 계정 → healthcheck) 재검증 완료

### DB 라이선스 조사: "라이선스 없이 만들 수 있는 DB" 분류

- 제품이 지원하는 DB 목록(goldilocks/altibase/cubrid/db2/informix/mariadb/mssql/oracle/postgres/tibero/mysql) 중 Docker로 라이선스 부담 없이 구축 가능한 것을 웹 조사로 분류
- **완전 오픈소스(라이선스 동의 불필요)**: MariaDB(완료), MySQL(GPL), PostgreSQL(완전 오픈소스), CUBRID(엔진 GPLv2+툴 BSD, NHN 오픈소스)
- **무료지만 EULA 동의·운영 제한 있음**: Oracle XE(용량 제한, 비용은 없음), MSSQL(Developer/Express), Db2 Community Edition(Docker 이미지는 비운영 전용 명시), Informix Developer Edition(비운영 전용)
- **사실상 불가(상용 라이선스 필수)**: Altibase(트라이얼 라이선스 파일 필요), Tibero(데모/유료 라이선스 필요 + hostname 바인딩), Goldilocks(공개 무료 배포 경로 확인 안 됨)
- 결론: 1차로 MySQL/PostgreSQL/CUBRID 3종을 mariadb와 동일 패턴으로 구축하기로 결정

### 스크립트 통합(최종 목표) 논의

- 사용자가 "각 DB마다 따로 있는 deploy 스크립트를 하나로 통합"하는 것이 최종 목표 중 하나임을 명시, "잊지 말라"는 요청에 따라 별도 메모리로 기록
- 논의된 구조안: `deploy/` 루트 아래 `common/`(공용 함수) + DB별 하위 폴더(`Dockerfile`+`logic.ps1`), 단일 진입점 스크립트가 DB 종류 선택 후 해당 로직을 dot-source하는 방식
- 사용자 결정: "대다수의 DBMS를 처리하고 그 뒤에 생각하자" — 지금은 각 DB 스크립트를 개별 완성하는 데 집중하고, 통합 리팩터링은 이후 별도 작업으로 미룸

### MySQL / PostgreSQL / CUBRID 배포 구조 신규 구축 및 실제 검증

- 3종 모두 `oracle`/`mariadb`와 동일한 3단계(registry 공용 + base + deploy) 구조로 `.sh`/`.ps1`(BOM 포함)/`.bat` 전 스크립트 작성
- **MySQL**: MariaDB와 거의 동일 (`MYSQL_ROOT_PASSWORD`/`MYSQL_DATABASE`/`MYSQL_USER`/`MYSQL_PASSWORD`). 공식 이미지에 `mysql` 클라이언트가 그대로 남아있어 MariaDB처럼 바이너리명을 바꿀 필요 없었음. HEALTHCHECK는 `mysqladmin ping` 직접 추가(공식 이미지에 기본 지정 없음)
- **PostgreSQL**: 공식 이미지에 MariaDB의 `*_USER` 같은 보조계정 자동생성 기능이 없어, `CREATE USER`/`GRANT` SQL을 직접 생성해 `/docker-entrypoint-initdb.d/`에 `05_` 접두어로 주입(DDL `10_`/DML `50_`보다 먼저 실행되도록 순서 설계, `ALTER DEFAULT PRIVILEGES`로 향후 생성 테이블에도 권한 자동 적용). **실제 검증 중 발견한 함정**: PostgreSQL은 따옴표 없는 식별자를 소문자로 접지만, 접속 인증 파라미터(libpq startup packet의 user 필드)는 이 접힘이 전혀 적용되지 않는 별도 경로라서, 대문자 섞인 계정명을 그대로 쓰면 "생성된 이름"과 "접속해야 하는 이름"이 달라져 로그인 실패 — Oracle 대소문자 버그와 정반대 방향의 함정. 앱 계정명을 입력받는 즉시 소문자로 강제 변환해 원천 차단(스크립트 실행 테스트로 대문자 입력 → 소문자로 정상 변환·로그인 확인). HEALTHCHECK는 `pg_isready -h 127.0.0.1`로 TCP 연결을 강제해 초기화 스크립트 실행 중(유닉스 소켓만 열린 임시 상태)에 조기 성공으로 오판하지 않도록 설계
- **CUBRID**: 사전 웹 조사 단계에서 문서마다 다른 정보(env var 이름, 포트 구성 등)가 나와, 실제 공식 이미지를 pull하여 `docker inspect`와 `entrypoint.sh` 원본을 직접 분석 + 실제 컨테이너 기동 테스트로 사실관계를 확정한 뒤 스크립트 작성. 확정된 사실: 지원 env는 `CUBRID_DB`/`CUBRID_USER`/`CUBRID_PASSWORD`/`CUBRID_VOLUME_SIZE`/`CUBRID_LOCALE`/`CUBRID_COMPONENTS`뿐이고 실제 노출 포트는 브로커용 `33000` 하나뿐(1523/8001/30000은 관련 문서에 나왔지만 실제 이미지엔 없음); `dba` 계정은 비밀번호를 설정하는 기능 자체가 이미지에 없어 항상 무password(이미지 자체 사양이며 이 프로젝트의 제약이 아님을 스크립트에 명시); 계정 인증은 대소문자를 구분하지 않음(테스트로 확인, PostgreSQL과 반대); `/docker-entrypoint-initdb.d/` 같은 DDL/DML 자동 실행 규칙이 없어 해당 기능은 지원하지 않는다고 명확히 표기. **11.4부터 `--privileged` 옵션이 공식 요구사항**이라는 점을 발견해 사용자에게 확인 후("privileged로 진행") 반영 — 이 프로젝트에서 유일하게 privileged 컨테이너로 뜨는 DB이며, 스크립트 요약 화면에 매번 명시적으로 경고하도록 처리
- 3종 모두 `.sh`/`.ps1` 양쪽으로 실제 build-and-push → deploy → 관리자/앱 계정 로그인 및 권한(테이블 생성/INSERT) 검증까지 마친 뒤 테스트 컨테이너·이미지 삭제, 팀서버 레지스트리에는 `latest` 베이스 이미지만 남김
- MySQL 베이스 이미지 push 중 대용량 레이어에서 `net/http: timeout awaiting response headers` 재현(Oracle 때와 동일 증상) — 이번엔 사용자가 직접 팀서버에 등록 완료, 이쪽에서는 `docker pull`로 digest 일치만 재검증. CUBRID는 동일 증상이 재시도 2회 만에 자체 해결됨

**상태**: ✅ MySQL/PostgreSQL/CUBRID 3종 배포 파이프라인 전부 실제 검증 완료 및 팀서버 레지스트리 등록 완료. 완전 무료 오픈소스 DB(MariaDB/MySQL/PostgreSQL/CUBRID) 4종 전부 구축 완료. 잔여 항목: 스크립트 통합 리팩터링(보류 중), Oracle XE/MSSQL/Db2/Informix 등 "무료지만 제약 있는" DB군은 미착수.

## 2026-08-26

### MySQL DBeaver 접속 오류 ("Public Key Retrieval is not allowed") 수정

- 사용자가 DBeaver로 실제 접속 테스트 중 재현. 원인은 MySQL 8+ 기본 인증방식(`caching_sha2_password`)이 SSL 없는 연결에서 RSA 공개키 교환을 요구하는데, JDBC 드라이버가 보안상 기본 차단하는 것 — 컨테이너/스크립트 버그가 아니라 클라이언트 쪽 기본 설정 문제
- `mysql/deploy/deploy.sh`·`.ps1`이 출력하는 JDBC URL 자체에 `?allowPublicKeyRetrieval=true&useSSL=false`를 포함시켜 URL을 그대로 복사해 쓰면 바로 접속되도록 수정. 이어서 사용자 요청으로 "JDBC 옵션값"과 "드라이버 옵션(DBeaver Driver properties용)"을 별도 줄로 명시적으로 추가 표기
- 재테스트로 정상 출력 확인 후 테스트 컨테이너/이미지 정리, 사용자가 실제 DBeaver 접속 성공까지 확인

### 레지스트리 이미지 정밀 버전 태그 추가

- mysql/postgres/cubrid는 지금까지 `latest` 태그만 있었는데, 사용자가 "latest로 태그 달릴 애들 버전으로 추가로 달 수 있어?"라고 요청
- 이미 로컬에 있던(레지스트리에서 재pull한) `latest` 이미지 안에서 직접 버전 확인: mysql `mysqld --version` → `26.7.0`, postgres `postgres --version` → `18.6`, cubrid `cubrid_rel` → `11.4.5`
- 동일 이미지에 태그만 추가로 붙여 push(레이어 전부 "already exists"라 즉시 성공, 재업로드 없음). `mysql:26.7.0`/`postgres:18.6`는 Docker Hub에도 실제 존재하는 태그로 확인됨(`docker manifest inspect`), cubrid `11.4.5`는 Docker Hub엔 없고 우리 레지스트리에만 있는 태그(CUBRID는 패치 버전 단위 태그를 공식 배포하지 않음)
- 각 DB `deploy.sh`/`.ps1`의 버전 선택 메뉴에 "옵션 4"로 이 정밀 버전을 추가해 실제로 선택·배포 가능하도록 반영

### Oracle XE (21c-xe / 18c-xe) 배포 검증 — 실제 버그 2건 발견 및 수정

- TODO에 있던 미검증 항목("gvenzl XE 이미지 경로로 실제 배포 테스트")을 실제로 진행. `oracle/base`, `oracle/deploy` 스크립트에는 이미 XE 분기 로직이 다 작성되어 있었으나(2026-08-21 작성 추정) 실행 검증은 한 번도 안 된 상태였음
- 베이스 이미지 빌드+push: 21c-xe/18c-xe 둘 다 대용량 레이어에서 `net/http: timeout awaiting response headers` 재현(다른 DB들과 동일 증상) — 재시도 여러 번(21c-xe는 6회째, 18c-xe는 4회째)만에 자체 성공, `docker save`/`scp` 우회는 필요 없었음
- **버그 1 — 앱 계정 생성 SQL이 조용히 무시됨**: `deploy.sh`/`.ps1`이 스테이징한 SQL을 항상 `/opt/oracle/scripts/setup`(공식 Oracle EE 이미지 관례)에만 마운트하고 있었는데, gvenzl XE 커뮤니티 이미지는 `container-entrypoint.sh` 코드상 `/container-entrypoint-initdb.d`를 스캔한다는 걸 실제 컨테이너 안에서 확인. EE 경로로 마운트해도 에러 없이 그냥 무시되어서, 실제 로그인 테스트(`appuser1`로 접속 시도) 전까지는 겉보기엔 배포가 "성공"한 것처럼 보였음 — 에디션별로 마운트 경로를 분기하도록 수정 후 재검증(로그인/CREATE TABLE/INSERT까지 확인)
- **버그 2 — XE에서 healthcheck가 영원히 "unknown"**: `docker inspect`로 확인한 결과 19c EE 이미지는 자체 HEALTHCHECK(`$ORACLE_BASE/$CHECK_DB_LOCK_FILE`)가 내장돼 있지만, gvenzl XE 이미지는 `Config.Healthcheck: null` — HEALTHCHECK 자체가 없음. `oracle/deploy/Dockerfile`에 EE/XE 양쪽의 실제 체크 스크립트(`/opt/oracle/healthcheck.sh` 또는 EE의 락파일 스크립트)를 런타임에 파일 존재 여부로 감지해 분기하는 HEALTHCHECK를 추가 — 하나의 Dockerfile로 EE 기존 동작은 그대로 유지하면서 XE도 정확히 healthy 판정되도록 수정 (재검증 시 이전엔 30분 타임아웃까지 대기하던 것이 20초 만에 healthy 전환)
- 21c-xe는 Service Name 방식, 18c-xe는 SID 방식으로 각각 앱 계정 생성 → 로그인 → `CREATE TABLE`/`INSERT`/`COMMIT`까지 실제 검증 완료. SID 방식 접속 예시 문구(`@host:port/SID` 슬래시 표기)가 문법적으로 의심스러워 보여 콜론 표기(`@host:port:SID`)와 비교 테스트했으나, XE는 SID와 동일한 이름의 서비스도 자동 등록해서 슬래시 표기가 실제로 정상 동작함을 확인(콜론 표기는 오히려 ORA-12545로 실패) — 기존 스크립트 문구가 맞았음, 수정 불필요
- Oracle Container Registry 로그인 없이도 계정/구매 없이 완전 무료로 쓸 수 있는 경로가 실사용까지 확인된 셈 — TODO의 "Oracle XE 추가 에디션" 항목 완료 처리
- 검증 후 테스트 컨테이너/배포용 이미지/베이스 이미지(레지스트리에는 이미 push됨) 전부 로컬 정리, 빌드 캐시도 정리

### 배포용(`-deploy`) 이미지 중복 제거 — 실버그 2건 추가 발견

- 사용자가 Docker Desktop에서 DB당 이미지가 2개씩(base + `-deploy`) 뜨는 걸 직접 발견해 질문. 원인: 지금까지 HEALTHCHECK 하나 추가하려고 매번 `docker build`로 base 이미지를 거의 그대로 복제한 "배포용" 이미지를 로컬에 하나 더 만들고 있었음
- `docker run --health-cmd/--health-interval/--health-timeout/--health-start-period/--health-retries` 플래그로 헬스체크를 런타임에 지정할 수 있다는 점에 착안 — `docker build` 단계를 완전히 제거하고 base 이미지를 바로 실행하도록 oracle/mariadb/mysql/postgres/cubrid 5종의 `deploy.sh`+`.ps1`(10개 파일)을 수정, `deploy/Dockerfile` 5개 삭제
- **버그 1 (심각)**: PowerShell에서 `docker run @RunArgs`처럼 배열을 native exe에 splatting할 때, 각 원소 문자열 안의 `"`(큰따옴표)가 Windows 프로세스 인자 전달 과정에서 조용히 사라지는 현상을 실측으로 확인. mysql/postgres는 따옴표 안 내용에 공백이 없어(`$MYSQL_ROOT_PASSWORD` 등 변수 하나) 값 자체는 살아남아 우연히 동작했지만, cubrid는 따옴표 안에 공백이 있는 문자열(`"SELECT 1;"`)이라 따옴표가 사라지면서 그 공백이 새로운 인자 경계가 되어 `docker run`이 통째로 `docker: invalid reference format` 에러로 실패 — 실제 재현. 여러 차례 `docker run --health-cmd=... alpine` 조합으로 직접 실험해 원인을 좁혔고, 최종적으로 PowerShell 문자열 안에서 `"` 대신 `\"`(백슬래시로 이스케이프한 큰따옴표)를 쓰면 Windows 인자 전달 과정에서 정확히 리터럴 `"` 하나로 살아남는다는 것을 확인 — mysql/postgres/cubrid/oracle 4개 `deploy.ps1`의 헬스체크 문자열을 전부 이 방식으로 수정 후 재검증 완료
- **버그 2**: 위 작업 검증 도중 `mysql/deploy/deploy.ps1`의 JDBC URL(`jdbc:mysql://localhost:$ListenerPort/$DbName?allowPublicKeyRetrieval=...`)에서 PowerShell이 `$DbName?allowPublicKeyRetrieval`을 통째로 하나의(존재하지 않는) 변수명으로 잘못 해석해, DB 이름이 URL에서 통째로 빠지고 `=true&useSSL=false`만 남는 것을 발견(`$var?` 형태에서 `?`가 변수명의 일부로 흡수됨 — 직전 턴에 이 JDBC 옵션 기능을 추가하며 생긴 버그, 그때는 못 잡았음). `${DbName}`처럼 중괄호로 변수명 경계를 명시해 수정, 재검증으로 정상 렌더링 확인
- 5개 DB 전부 `.sh`/`.ps1` 양쪽으로 pull→run(빌드 없이)→healthy→로그인까지 재검증 완료, 테스트 컨테이너/이미지 정리
- 결과: 로컬 이미지가 DB당 1개로 감소, `docker build` 단계가 사라져 배포도 약간 빨라짐, `deploy/Dockerfile` 5개는 저장소에서 삭제

**상태**: ✅ 이미지 중복 제거 리팩터링 + 실사용 중 발견한 PowerShell 인자 전달 버그 2건 수정 완료.

## 2026-08-27

### 팀서버 레지스트리 볼륨화 + 재시작 정책 적용

- TODO #1(레지스트리 컨테이너에 볼륨/재시작 정책 없음) 해결. 사용자가 서버에서 직접 작업(rootful docker, `sudo -i`로 root 전환), 이쪽은 절차 설계 + 명령어 제공 + 최종 검증 담당
- 절차: 기존 컨테이너 `stop` → `docker cp registry:/var/lib/registry/. <호스트경로>`로 데이터를 먼저 안전하게 백업 → `rm` → `-v <호스트경로>:/var/lib/registry --restart=always`로 재생성. 저장 경로는 특정 사용자 홈 대신 시스템 레벨(`/opt/servicetech2-registry/data`)을 추천해 채택
- `docker run`이 예상보다 오래 걸려 사용자가 문의 — 서버가 Oracle Linux(`ol-root` LVM)라 SELinux Enforcing에 의한 bind mount relabel 지연을 의심했으나, `getenforce` 확인 결과 **Disabled**라 해당 없음으로 판명. `iostat -x`로 실제 디스크 쓰기가 발생 중임을 확인해 "멈춘 게 아니라 진행 중"이라고 안내, 계속 대기하도록 함 — 결과적으로 컨테이너는 정상적으로 떴고 CLI foreground 리턴만 늦었던 것으로 정리
- 검증: 서버에서 `curl .../v2/_catalog`로 5개 레포(cubrid/mariadb/mysql/oracle/postgres) 전부 확인, `mariadb/tags/list`로 기존 태그(10.11/11.4/latest) 그대로 확인. 이 PC에서도 로컬 캐시 삭제 후 `docker pull`로 재검증 — digest(`sha256:bb62168a...`)가 마이그레이션 전과 완전히 동일함을 확인해 데이터 무결성 검증 완료

### JDK/Tomcat/DB 통합 배포(compose) 설계 논의 시작

- 사용자가 요구사항 구체화: JDK 이미지 + Tomcat 이미지 + DB를 docker compose로 묶어 한 번에 기동. 기동 순서는 DB → JDK → Tomcat이며, 버전/앱 종류에 따라 "DB → JDK(verifier)"만 쓰는 경로와 "DB → Tomcat(oacx) 또는 JDK(oacx)"처럼 갈라지는 경로가 있음 (기존 로컬에 있던 `mdl_verifier`/`mdl_oacx` 등 구(舊) 스택을 정식 3단계 레지스트리 패턴으로 이관하는 작업으로 파악)
- JDK 이미지 실행 시 `app_path`/`config_path`/`log_path` 3개 볼륨 마운트 경로 + `port_nbr`을 지정해야 함 (기존 TODO 항목과 일치)
- 서버 측 검토: 새 네임스페이스(`servicetech2/jdk18`, `jdk21`, `tomcat`)는 기존 DB와 동일하게 공식 이미지 재태깅만 하면 됨 — 앱(JAR/WAR) 자체는 이미지에 안 들어가고 `app_path`로 런타임 주입. 서버에 새 포트 오픈은 불필요(컨테이너는 개발자 PC에서 기동). 디스크 용량은 스크린샷으로 확인 — `/` 495G 중 448G 여유로 전혀 문제 없음
- 작업 PC 측 검토: (1) compose 스택 내부에서는 DB 접속을 `localhost:포트`가 아니라 **compose 서비스명**으로 해야 함(기존 개별 deploy 스크립트와의 중요한 차이점), (2) `depends_on: condition: service_healthy`로 순서를 강제하려면 JDK/Tomcat 쪽에도 자체 헬스체크가 필요, (3) 여러 조합(verifier만 / oacx+tomcat 등)은 compose `profiles:` 기능으로 하나의 파일에서 선택적으로 켜는 방식을 제안, (4) Windows 경로 마운트 시 기존에 겪은 MSYS/PowerShell 경로 이슈 재발 가능성 안내
- **결정 대기 중**: (1) verifier/oacx가 헬스체크 가능한 엔드포인트를 갖고 있는지, (2) JDK 이미지가 마운트된 JAR을 찾는 방식(파일명 고정/환경변수/글롭), (3) config_path에 들어갈 접속정보 파일을 누가 준비하는지 — 이 세 가지가 정해져야 실제 `jdk/`, `tomcat/`, `compose/` 구현 착수 가능

### verifier 실제 프로덕션 JAR + 실제 DB 통합 테스트 (mdl-verifier-1.3.42.jar)

- 위 결정 대기 항목을 실제 검증으로 해소하기 위해, 최소 stand-in 샘플 대신 **실제 프로덕션 verifier JAR**(`mdl-verifier-1.3.42.jar`)과 실제 DDL/DML(`D:\03. Docker\sandbox\ddl\mdl-verifier-mariadb.sql`, `dml\insert-init-data.sql`)로 곧바로 실전 테스트 진행. MariaDB 컨테이너(DB명 `VC_VERIFIER`, 앱 계정 `klevra`/`theg3p2`)를 커스텀 브리지 네트워크로 verifier와 묶어 컨테이너명 통신 확인
- **JDBC 드라이버 공백 발견**: verifier가 번들한 드라이버(oracle/mysql/mssql/postgres/tibero/goldilocks)에 MariaDB Connector/J가 없음 — Maven Central에서 `mariadb-java-client-3.3.3.jar`를 직접 받아 `LOADER_PATH`(Spring Boot PropertiesLauncher의 additive 클래스패스)로 외부 주입해 해결. `SPRING_CONFIG_ADDITIONAL_LOCATION=file:/config/`도 같은 additive 방식으로 외부 설정 디렉터리를 추가(기존 classpath 번들 설정은 그대로 유지한 채 override)
- **ddl-auto=validate 문제**: 실제 JPA 엔티티 10종과 정확히 일치해야 하는 `validate` 모드는 엔티티를 역공학할 수 없어 위험 판단 → 사용자 지시로 `ddl-auto=none`, 스키마는 이미 갖고 있는 실제 DDL/DML로 대체
- **`verifier.tar.gz`(실제 배포 서버의 살아있는 config) 발견 및 병합**: `config/sp`(wallet/did 파일), `application-*.properties`의 실제 값(블록체인 노드 주소, wallet 경로/비밀번호/key-id, jasypt 암호화 키 등)을 우리 config에 반영. 이 과정에서 발견/수정한 이슈들:
  - `application-sp.properties`와 `application-mdl-sp.properties`가 `mdl.sp.*` 네임스페이스를 **중복 정의**하고 있어, 한쪽만 값을 채우면 로드 순서에 따라 빈 값으로 덮어써지는 위험 확인(초기엔 mdl-sp를 비활성화로 "회피"했다가, 사용자가 "mdl-sp는 활성화 상태여야 한다"고 정정 — 최종적으로 두 파일의 모든 겹치는 키를 완전 동기화하는 방향으로 해결, 기동 시간도 98초→38초로 단축됨을 확인)
  - VCConverter 라이선스 오류 → 실제 `.rsl` 라이선스 파일 + 디자인 템플릿 7종을 `config/license`, `config/template`에 배치, `application-converter.yml`의 경로 설정
  - CA 앱 목록 조회 실패 → 실제 도메인 값 채움 + 사용자 지시로 `ca-list-data-cron-enabled=false`(개발서버 다운 상태)
  - 폰트 외부화 요청 → `config/fonts`(PretendardGOV 9종) 추가, `use-font-file=true` + `font-dir-path=/config/fonts`
- 최종 부팅 성공: `Started MdlApiApplication in 38.407 seconds`, 에러 0건, `curl` 200 확인. **sandbox 원본 템플릿**(`application-sp/mdl-sp.properties`)에도 "ca-list-domain이 빈 값인데 cron-enabled 기본값이 true"인 조합 자체가 함정이라는 걸 반영해 기본값을 `false`로 수정(실제 도메인 값은 환경별이라 템플릿엔 반영 안 함)

### 마운트 구조 확정 — sandbox/verifier를 "실제 배포 소스"로 정리

- verifier 통합 테스트 성공 후, 사용자가 마운트 구조를 반복 정제 요청 — 최종적으로 `D:\03. Docker\sandbox\verifier\`가 `app/`(JAR+jdbc 드라이버)와 `config/`(하위에 `config/`, `template/`, `license/`, `sp/`, `fonts/` 5개 서브폴더, 각각 컨테이너의 `/config`, `/config/template`, `/config/license`, `/config/sp`, `/config/fonts`에 개별 바인드마운트)로 정리됨
- **발견한 마운트 순서 함정**: `/config`를 `:ro`로 마운트하면 그 하위에 `/config/template` 등 새 마운트포인트를 만들 수 없어 컨테이너 생성 자체가 실패 — 최상위(`/config`)만 rw로 마운트하고, 실제 파일 보호는 하위 4개 개별 마운트의 `:ro`로 담당하는 구조로 해결
- 재구성 과정에서 실제 앱 포트가 8080이 아니라 **48085**(`api-server-domain`에 박혀있던 값과 동일)라는 걸 재확인, 포트 매핑 정정

### verifier deploy.sh/.ps1 정식 스크립트화

- 위 실전 테스트를 반복 가능한 스크립트로 정식화. `Dockerfile`은 `sandbox/verifier`에 위치(COPY 없음 — `app/config/jdbc/logs`는 전부 런타임 바인드마운트, `/app` 안에서 `mdl-verifier-1.*.jar`를 glob으로 찾아 정확히 1개일 때만 실행). DB 설정(파트너 코드/DDL 체크/DML 자동 패치), 포트, 운영·개발 여부 등을 대화형으로 입력받도록 구성
- **실제 버그 발견/수정**: (1) `application-datasource.properties`에 이전 테스트용 호스트명이 하드코딩돼 있어 새 컨테이너명과 불일치 → DB 연결 자체 실패 — 원본은 그대로 두고 매 실행마다 스테이징 사본을 패치하는 방식으로 해결. (2) `curl ... || echo "000"` 패턴이 드물게 "200"+"000"이 이어붙어 `200000`으로 찍히는 버그 → 정규식으로 3자리 숫자 검증하도록 수정
- **`.ps1` 작성 중 발견한 환경 이슈**: Write 도구로 새로 만든 `.ps1`은 UTF-8 **BOM 없이** 저장되는데, Windows PowerShell 5.1은 BOM이 없으면 시스템 코드페이지로 파일을 읽어 한글 주석/문자열을 오염시키고, 그 결과로 파서가 멀쩡한 문법 줄에서도 엉뚱한 문법 에러를 냄(원인 파악에 상당한 시간 소요, 최종적으로 BOM 포함 재저장만으로 모든 에러가 한 번에 해소됨 확인) — 메모리에 기록해 향후 신규 `.ps1` 작성 시 항상 BOM을 붙이도록 함

### OACX(Tomcat) 배포 파이프라인 신규 구축 + provider.json 실사용 설정

- `oacx.tar.gz`(실제 WAR 배포본)를 `app/`(WEB-INF 등)과 `config/`(provider.json 다수, mybatis, logback.xml, server.properties, toss-sec)로 분리해 verifier와 동일한 컨벤션으로 정리
- **Tomcat 배포 방식 결정**: `webapps/oacx` 직접 마운트 대신 `conf/Catalina/localhost/oacx.xml`에 `docBase="/app"` Context를 등록하는 방식 채택(uniform `/app`,`/config`,`/logs` 마운트 유지). `web.xml`의 `config.file=./WEB-INF/config/server.properties`(상대경로)는 배포 스크립트가 스테이징 시점에 `/config/server.properties`(절대경로)로 패치(원본 미변경)
- 이미지는 커스텀 빌드 없이 공식 `tomcat:9-jdk8-temurin` 그대로 사용(ENTRYPOINT 커스터마이징 불필요)
- **실제 데이터 버그 발견**: `01.insert_data.sql`의 `OACX_PROVIDER` INSERT 중 `PROVIDER_ID` 값이 `cotcotoss-identifyoss`(21자, 중복 오타로 추정)로 `varchar(20)` 컬럼을 초과해 INSERT 실패 → 사용자 확인 결과 **DDL 쪽 컬럼 길이 설계 실수**로 판명(`varchar(20)`→`varchar(25)`로 수정, 실제 최대 데이터 길이 21자라 데이터는 그대로 두어도 됨)
- 최초 부팅 성공: `Server startup in [129086] milliseconds`, `HTTP 응답 확인: 200`, `OACX_PROVIDER` 28건 정상 적재
- **OPER_SORT 개발/운영 자동화**: 배포 스크립트가 개발/운영 선택에 따라 DML의 `OACX_PROVIDER.OPER_SORT`('ent' 컬럼 바로 다음)를 `dev`/`prod`로 자동 치환(개발 기본값) — `'ent'` 앵커를 기준으로 정규식 매칭해 NULL/따옴표 유무가 섞인 컬럼 구성에도 안전하게 동작
- **provider.json 6종 실사용 설정**(coidentitydocument/comdc/comdl/comnh/comrc/coresidence): `services.authen.urls.base`를 verifier 컨테이너로, `publicKey`/`vc.curveType`을 verifier의 실제 did 파일(`raondev2.sp.did`/`raonEnt.did`)의 `verificationMethod.publicKeyBase58`/`type`에서 자동 추출해 반영(dev/prod에 따라 did 파일 자동 선택), `partnerCode`는 verifier와 동일 값으로 통일. 이 과정에서 **실제 설정 버그 2건 추가 발견**: comdl/comnh 두 파일의 `vc.curveType`이 실제로는 `SECP256_K1`이어야 하는데 `SECP256_R1`로 잘못 설정돼 있었음(두 did 파일 모두 `Secp256k1VerificationKey2018` 타입), `webToAppRequest`가 4개 파일에서 `web2appsspay`(오타)로 잘못 설정 — 전부 자동 반영 로직에서 정정. `serviceCode`는 인증사업자별 고유값이라 자동화 대상에서 제외(수기 입력 대상으로 명시, comdc는 현재 빈 값)
- oacx↔verifier가 서로 다른 네트워크에 있으면 컨테이너명 통신이 안 되는 문제를 발견해 `docker network connect`로 즉시 해결하고, 이후 배포 스크립트 자체에 네트워크 연동 옵션을 추가해 자동화

### OmnioneCX 통합 배포 스크립트(`omnionecx/v1/deploy/`) — DB 1개 + verifier + oacx

- 사용자가 제시한 7단계(①설정값 일괄 수령 ②DB 생성 ③DDL/DML 적용 ④verifier 설정 ⑤verifier 기동 ⑥oacx 설정 ⑦oacx 기동)를 검토 후, 네트워크 생성/헬스체크 대기/partnerCode 및 publicKey·curveType 자동 전파 등을 보강 사항으로 반영해 그대로 채택
- **DB 통합 방침 확정**: 사용자 확인에 따라 verifier/oacx가 하나의 DB(`VC_VERIFIER`, 실제 운영 config의 기본값과 동일)를 공유 — 실제 스키마 검증 결과 `VF_*`(12개)와 `OACX_*`(14개) 테이블이 이름 충돌 없이 정상 공존함을 확인. verifier DDL에 하드코딩된 `CREATE DATABASE`/`USE` 문은 실제 선택한 DB명으로 자동 정규화하는 로직 추가(다른 DB명을 선택해도 안전)
- **JDK8/JDK21/Tomcat 베이스 이미지 신규 구축 + 레지스트리 등록**: `jdk8/base`, `jdk21/base`(둘 다 `APP_JAR_GLOB` 환경변수로 앱마다 다른 JAR 이름 패턴을 지정할 수 있게 일반화한 glob 엔트리포인트), `tomcat/base`(공식 이미지 재태깅, 커스터마이징 없음) — 전부 `servicetech2` 레지스트리에 push 완료(`jdk8:latest`, `jdk21:latest`, `tomcat9-jdk8:9-jdk8`). 이후 verifier/oacx 배포는 로컬 빌드 없이 레지스트리에서 pull만 하도록 전환
- `deploy.sh` 작성 후 실전 데이터로 전체 스택 실행 검증: DB(공유)→verifier(30초 부팅, HTTP 200)→oacx(198초 부팅, HTTP 200), `VF_ORGANIZATION.PARTNER_CODE`/`OACX_PROVIDER.OPER_SORT` 자동 반영 확인. HTTP 체크가 "Server startup" 로그 직후 포트 accept 전이라 드물게 000이 뜨는 걸 발견해 짧은 재시도 로직 추가
- **`deploy.ps1` 포팅 중 발견한 2번째 인코딩 버그**: `.ps1` 자체는 BOM을 붙여 저장했지만, 스크립트가 **런타임에 읽고 쓰는 SQL/properties/json 파일**(전부 BOM 없는 UTF-8)을 `Get-Content -Encoding utf8`/`Set-Content -Encoding utf8`로 처리하면서 Windows PowerShell 5.1이 시스템 코드페이지로 잘못 디코딩 — 한글 주석이 깨진 SQL을 MariaDB가 파싱하다 실제로 `ERROR 1064` 문법 에러를 냄(bash 버전은 동일 로직인데 문제 없었음 — bash는 바이트를 그대로 다루기 때문). `[System.IO.File]::ReadAllText/WriteAllText`(BOM 강제 없이 UTF-8로 명시)로 전면 교체해 해결, 재검증으로 한글 주석 원형 보존 + 전체 스택 재부팅 성공(`.ps1` 기준 verifier 25초/oacx 154초, 둘 다 HTTP 200) 확인. 두 인코딩 버그 모두 메모리에 기록해 향후 신규 `.ps1` 작성 시 재발 방지
- admin(v1 JDK8/v2 JDK21)은 이번 라운드에서 명시적으로 범위 제외

**상태**: ✅ verifier+oacx+공유DB 통합 배포 파이프라인(`.sh`/`.ps1` 양쪽) 실전 데이터로 전체 검증 완료, JDK8/JDK21/Tomcat 베이스 이미지 레지스트리 등록 완료. 잔여: `comdc-provider.json`의 `serviceCode`(실제 값 필요), TODO/README류 정리, admin 트랙(보류).

### 마무리 보강 — 포트 기본값, config 업데이트 여부 옵션, 로그 경로 통합

- `comdc-provider.json`의 빈 `serviceCode`를 `coidentitydocument-provider.json`과 동일한 `raonsnc.5`로 직접 반영(자동화 대상 아님, 1회성 수정)
- **포트 기본값 정리**: verifier 호스트 노출 포트를 내부 포트와 동일하게(`48085`, 기존 `18090`에서 변경), oacx도 동일하게(`8080`, 기존 `18091`에서 변경) — DB처럼 리매핑 없이 그대로 노출하는 방향으로 통일. `verifier/oacx/omnionecx`의 `.sh`/`.ps1` 전부 반영
- **config 업데이트 여부 옵션 신규 구현**(`omnionecx/v1/deploy/deploy.sh`+`.ps1`): "DB 접속정보를 이번 배포값으로 업데이트할까요?" 프롬프트 추가(기본값 N = config 원본 값 그대로 사용). N을 선택하면 DB_CONTAINER/DB_NAME/APP_USER/APP_PASSWORD를 따로 입력받지 않고 verifier의 `application-datasource.properties`에서 직접 파싱해 그 값에 맞춰 DB 컨테이너를 생성(즉 config가 "진실의 원천"이 되고 DB가 거기에 맞춰짐 — 반대 방향이 아님). mybatis/log 경로, oper.mode, provider.json의 base/publicKey/curveType은 이 프로젝트의 마운트 컨벤션과 환경 선택에 필요한 구조적 값이라 업데이트 여부와 무관하게 항상 반영. `.sh`/`.ps1` 양쪽 실전 데이터로 재검증 완료(DB 컨테이너명이 config에 이미 박혀있던 `mariadb-verifier-test`로 자동 생성되는 것까지 확인)
- 검증 중 `http://localhost:8080/`(바로 접속)이 열리지 않는다는 문의가 있어 확인 — oacx의 Context path가 기본값 `oacx`라 실제로는 `http://localhost:8080/oacx/`에서 서비스됨(정상 동작, root(`/`)는 Tomcat 기본 404). 필요하면 Context path를 빈 값(ROOT)으로 바꾸는 옵션 추가 가능
- **로그 마운트 경로를 서비스별 폴더 밑에서 공용 `log/` 트리로 이전**: `<서비스>/logs` → `sandbox/log/<서비스>` 형태로 변경(예: `sandbox/verifier/logs` → `sandbox/log/verifier`, oacx는 `sandbox/log/oacx/{tomcat,app}`). `VERIFIER_ROOT`/`OACX_ROOT`의 부모 디렉터리를 기준으로 자동 계산(`dirname`/`Split-Path -Parent`). `verifier`, `oacx`, `omnionecx` 전부의 `.sh`/`.ps1`에 반영, `.sh` 기준 실전 재검증(새 경로에 실시간으로 로그가 쌓이는 것과 기존 경로엔 더 이상 안 쓰이는 것 둘 다 타임스탬프로 확인)
- 이 작업 중 `verifier/v1/deploy/deploy.ps1`(개별 버전)에서 `omnionecx`용에는 이미 적용했던 PowerShell UTF-8 mojibake 수정이 누락돼 있던 걸 발견해 동일하게 적용(`Read-Utf8File`/`Write-Utf8File` 헬퍼 추가)
- `.ps1` 동작 테스트는 사용자가 다른 PC에서 직접 진행 예정

### 다른 PC 실전 테스트에서 발견한 문제 3건 + 프롬프트 간소화

- 다른 PC에서 `.ps1` 직접 실행 시 Windows 기본 PowerShell 실행 정책(`Restricted`)에 막혀 `PSSecurityException` 발생 — 스크립트 문제 아님, `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` 또는 `-ExecutionPolicy Bypass -File`로 해결 안내
- **프롬프트 대폭 간소화 요청 반영**(24개 → 21개):
  - DDL/DML을 verifier/oacx 각각 물어보던 것(4개 프롬프트)을 통합 경로 1개씩(2개)으로 축소 — `INSERT INTO VF_ORGANIZATION`/`INSERT INTO OACX_PROVIDER` 문자열로 파일 내용을 보고 자동 판별하도록 스테이징 함수 재작성(같은 폴더에 섞여있어도 정상 동작)
  - verifier의 "컨테이너 내부 포트"/"호스트 노출 포트" 2개 질문을 "포트" 1개로 통합(리매핑 없음 정책과 일치)
  - **스크립트 위치 기준 자동 감지 추가**: `verifier/`, `oacx/`, `ddl/`, `dml/` 폴더가 스크립트와 같은 위치에 이미 있으면 경로를 아예 안 물어보고 자동 사용(사용자가 deploy.ps1을 sandbox 폴더 안에 직접 넣고 쓰는 실사용 패턴에 맞춤), 없을 때만 기존처럼 프롬프트
  - `.sh`/`.ps1` 둘 다 실전 재검증 완료

### docker compose 전환 (컨테이너명 db/verifier/oacx 고정 + 명시적 bridge 네트워크)

- 사용자 요청: (1) compose로 묶어서 db/verifier/oacx라는 이름으로 컨테이너 관리, (2) 외부 통신을 위해 네트워크를 명시적으로 bridge로 지정
- **하이브리드 구조로 설계**: 대화형 입력 수령 + config 패치 여부 분기 + DB에서 값 역추출 + provider.json 자동 설정 등 기존의 모든 명령형 로직은 그대로 유지하고, 마지막 실행 단계만 `docker run` 3회(+ 각각 별도 대기 루프) → `docker-compose.yml` 1개 생성 + `docker compose up -d` 1회 호출로 교체. `docker-compose.yml`은 `omnionecx/v1/deploy/`에 신규 작성(git 추적), `depends_on: condition: service_healthy`로 db→verifier→oacx 기동 순서를 compose가 직접 강제
- **verifier/oacx에 실제 HEALTHCHECK 신규 추가**: 기존엔 로그 문자열 grep으로만 부팅 확인했는데, compose의 `service_healthy` 게이팅을 쓰려면 진짜 헬스체크가 필요해서 `curl -f http://localhost:포트/`로 추가(사전에 `jdk8`/`tomcat9-jdk8` 이미지 둘 다 curl이 이미 설치돼 있음을 확인). DB는 기존 `healthcheck.sh` 그대로 compose YAML 문법으로 이관
- **컨테이너명**: `container_name: db/verifier/oacx`로 고정하되, DB는 "config 그대로 유지" 모드에서는 기존 config의 host값을 그대로 써야 접속이 되므로 그 모드일 땐 여전히 config에서 역추출한 이름을 사용 — "config 업데이트=예"를 고를 때만 기본값이 "db"로 제안됨(무조건 강제하면 "config 그대로 유지" 기능이 깨짐)
- **네트워크**: `networks: omnionecx: driver: bridge` 명시(이미 실측 확인된 기본 동작과 동일하지만, 사용자 요청대로 명시적으로 선언)
- **비밀번호 파일 미저장 원칙 유지**: compose의 변수치환은 `.env` 파일 또는 프로세스 환경변수 양쪽에서 값을 가져올 수 있는데, 비밀번호(`DB_ROOT_PASSWORD`/`APP_PASSWORD`)만 `.env`에 쓰지 않고 `docker compose up` 호출 직전에만 셸/프로세스 환경변수로 잠깐 설정했다가 호출 직후 즉시 제거(`export -n`/`Remove-Item Env:\`)하는 방식으로 "어떤 파일에도 저장하지 않는다"는 기존 원칙을 그대로 지킴. 나머지(경로/포트/이미지명/DB명/계정명 등 비민감 값)만 `.env` 파일에 기록
- **실제 발견한 버그**: `docker compose --env-file <경로>`에 넘긴 경로가 `D:\d\99_project\...`처럼 깨지는 현상 발견 — 원인은 스크립트 최상단의 `export MSYS_NO_PATHCONV=1`(예전 `docker run -v SRC:DEST:MODE` 콜론 문자열 보호용으로 필요했던 설정)이 이제 `docker run`을 전혀 안 쓰는 상황에서도 그대로 남아있어, `--env-file`처럼 MSYS의 정상적인 POSIX→Windows 경로 변환이 필요한 단일 경로 인자까지 변환을 막아버린 것 — Windows 실행 파일이 변환 안 된 POSIX 경로(`/d/99_project/...`)를 "현재 드라이브 기준 상대경로"로 오해석해 발생. `MSYS_NO_PATHCONV` 설정 자체를 제거해서 해결(더 이상 콜론 마운트 문자열을 셸 인자로 넘기지 않으므로 원래 목적 자체가 불필요해짐)
- `.sh`/`.ps1` 양쪽 모두 "config 업데이트 안 함"/"config 업데이트 함" 두 경로 전부 실전 데이터로 재검증: DB/verifier/oacx 3개 컨테이너 전부 Docker 자체 헬스체크로 `(healthy)` 상태 확인(`docker ps`), HTTP 200 확인, `.env` 파일에 비밀번호가 없음을 직접 확인

**상태**: ✅ compose 전환 완료 및 `.sh`/`.ps1` 양쪽 실전 검증 완료(config 업데이트 Y/N 두 경로 모두). 컨테이너명 고정(db 기본값/verifier/oacx), 네트워크 명시적 bridge, HEALTHCHECK 기반 순서 보장까지 반영.

### config 직접 마운트 전환 (staging 복사본 제거) — 설정 변경 즉시 반영

**배경**: 지금까지는 verifier/oacx의 config를 매 배포 실행마다 `.staging/`으로 복사한 뒤 값을 패치해서, 그 "복사본"을 컨테이너에 마운트했다. 그래서 sandbox 원본 config 파일을 직접 고쳐도 이미 뜬 컨테이너에는 반영되지 않았고, 설정값 테스트를 반복하려면 매번 전체 스크립트를 다시 돌려야 했다.

**변경**:
- verifier의 `config/config/*` (application-datasource.properties 등)와 oacx의 `config/*` (server.properties, provider.json 6종)는 더 이상 `.staging/`으로 복사하지 않고, **sandbox 원본 디렉터리를 그대로 docker-compose 볼륨 소스로 사용**한다 (`VF_CONFIG_DIR`, `OACX_CONFIG_DIR`).
- 기존에 하던 sed/regex 패치(DB 접속정보, mybatis/log 절대경로, oper.mode, provider.json의 base/partnerCode/publicKey/vc.curveType)는 복사본이 아니라 **원본 파일에 직접(in-place)** 적용한다. 모든 패치가 "전체 값을 치환"하는 형태라 여러 번 실행해도 결과가 같다(멱등).
- 부수 효과: comdc-provider.json의 serviceCode처럼 스크립트가 건드리지 않는 값은 재배포해도 사라지지 않고 그대로 유지된다 (예전엔 매번 원본에서 새로 복사해 패치했으므로 이런 수동 값도 매번 새로 들어갔지만, 결과적으로 동일 — 다만 이제는 "원본 자체가 최신 상태"라는 점이 다르다).
- 이제 컨테이너가 뜬 상태에서 sandbox의 config 파일을 직접 고치고 `docker restart <컨테이너>` (또는 `docker compose restart <service>`)만 해도 바로 반영된다. 전체 스크립트 재실행이 필요 없다.
- 여전히 staging을 거치는 것: DB의 DDL/DML(초기화 SQL, 여러 파일을 순서대로 합치는 특성상 계속 임시 병합 필요) / oacx의 `app`(web.xml 절대경로 패치 목적, config와 무관) / 생성되는 Context XML.
- `docker-compose.yml`의 볼륨 변수명을 `VF_CONFIG_STAGING`→`VF_CONFIG_DIR`, `OACX_CONFIG_STAGING`→`OACX_CONFIG_DIR`로 변경(의미 명확화).
- `config_template/` 폴더는 이번에 만들지 않았음: 현재 스크립트는 verifier/oacx config가 이미 존재해야만 동작하도록 되어 있어(없으면 즉시 에러), 부트스트랩용 기본값 템플릿이 채워줄 공백이 현재는 없음. 완전히 새로운 환경을 처음부터 세팅하는 시나리오가 생기면 그때 추가 검토.

**테스트**: 실제 sandbox 데이터(`D:\03. Docker\sandbox`)로 `deploy.sh`를 config 업데이트=N 경로로 end-to-end 실행. `application-datasource.properties`는 그대로 유지, `server.properties`는 mybatis/log 경로·oper.mode만 원본에 직접 반영, provider.json 6종도 원본에 직접 반영됨을 확인. `.staging/`에 더 이상 verifier/oacx config 하위 디렉터리가 생기지 않음을 확인. (DB 컨테이너가 DML 파일의 스키마명 하드코딩 오류로 기동 실패했으나, 이는 sandbox의 기존 DML 데이터 문제이며 이번 변경과 무관 — 별도 확인 필요 항목으로 남김.) 테스트 후 sandbox의 config는 원래 상태로 복원, 컨테이너/네트워크/.staging 모두 정리 완료.

**상태**: ✅ config 직접 마운트 전환 완료 (`.sh`/`.ps1` 양쪽 소스 수정, `.sh`는 실전 sandbox 데이터로 검증 완료. `.ps1`은 구문 검사만 완료, 실기동 테스트는 미실시).

### OmnioneCX v1 신규 트랙: JDK8/JDK21/Tomcat 베이스 이미지 + verifier/oacx/통합(omnionecx) 배포 스크립트, docker compose 전환

`omnionecx/v1/deploy/`를 `omnionecx/default/deploy/`로 이름 변경(git mv, 이력 보존)하고, 그 옆에 **버전 고정 이미지 트랙**(`omnionecx/1.0.0.12/`)을 신설했다.

**핵심 아이디어**: `default` 트랙은 매 배포마다 app(JAR/WAR)과 DDL/DML을 외부 폴더에서 스테이징/패치했지만, `1.0.0.12` 트랙은 그것들을 전부 이미지 빌드 시점에 구워 넣는다. 그래서 배포 시점에 필요한 파일이 `Dockerfile`(빌드용) + `docker-compose.yml`(실행용) + `deploy.sh`/`.ps1`(값 수령용) 정도로 최소화된다.

**세부 내역**:
1. **PARTNER_CODE를 'raon'으로 통일**하고, 관련 DDL/DML을 `omnionecx/1.0.0.12/db/Dockerfile`이 굽는 DB 이미지 안에 빌트인. `VF_ORGANIZATION.PARTNER_CODE`가 build 시점에 이미 'raon'으로 치환되어 있음.
2. **운영/개발(OPER_SORT) 선택은 유지** — `OACX_PROVIDER`의 dev/prod 리터럴을 `__OPER_SORT__` 플레이스홀더로 바꿔두고, DB 이미지의 `00-patch-oper-sort.sh`(initdb.d 안에서 다른 .sql보다 먼저 실행되도록 `00-` 접두사)가 컨테이너 환경변수 `OPER_SORT`로 컨테이너 최초 기동 시 1회 치환. (mysql 계정으로 실행되는 init 단계가 같은 디렉터리에 sed 임시파일을 못 만드는 권한 문제가 있어 `chmod -R a+rwX /docker-entrypoint-initdb.d`로 해결.)
3. **deploy 파일 최소화** — verifier/oacx 이미지에도 app이 빌트인되어 있어(`COPY app/ /app/`, oacx는 web.xml의 config 경로 절대경로 패치도 빌드 시점에 1회 처리) 배포 스크립트에서 app 스테이징/DDL_DIR/DML_DIR 수령이 전부 사라짐.
4. **DB 데이터 영속화** — `DB_DATA_DIR` 환경변수로 `/var/lib/mysql`을 호스트 경로에 바인드마운트(default는 휘발성이었음). 단, 데이터가 이미 있는 채로 재기동하면 MariaDB 공식 이미지 특성상 initdb.d(DDL/DML 시딩)는 다시 실행되지 않음 — 최초 기동 시 1회만 적용됨을 문서화.
5. **컨테이너 진입용 명령어** — `exec.sh`/`exec.ps1` 신설. `docker compose -p omnionecx exec <db|verifier|oacx> [명령]`을 감싼 얇은 래퍼.

**Dockerfile 설계** (`omnionecx/1.0.0.12/{db,verifier,oacx}/Dockerfile` + 각각의 `build-and-push.sh`):
- verifier: `servicetech2/jdk8` 베이스 + `COPY app/ /app/`, `LOADER_PATH=/app/jdbc`로 재설정(별도 jdbc 볼륨 불필요)
- oacx: `servicetech2/tomcat9-jdk8` 베이스 + `COPY app/ /app/` + web.xml의 `./WEB-INF/config/server.properties` → `/config/server.properties` 절대경로 패치(빌드 시 1회)
- db: `servicetech2/mariadb` 베이스 + DDL/DML(raon 고정, OPER_SORT 플레이스홀더) COPY

**config/log는 여전히 외부 마운트** — verifier/oacx의 config(DB 접속정보, provider.json 등 환경별 값)는 `default`와 동일하게 sandbox 원본에 직접 패치 후 그대로 마운트하는 방식을 유지(2주 전 작업한 "config 직접 마운트" 설계 그대로 재사용). app만 이미지에 고정되고 config는 여전히 배포 시점 값.

**테스트**: 실제 sandbox 데이터로 3개 이미지(db/verifier/oacx:1.0.0.12)를 빌드+레지스트리 push 후, `deploy.sh`와 `deploy.ps1` 양쪽 모두 실제 실행 — DB_DATA_DIR 영속 볼륨 + OPER_SORT(dev/prod 둘 다) + config 유지(N) 모드로 db→verifier→oacx 전부 healthy, HTTP 200/200, PARTNER_CODE=raon/OPER_SORT 반영 정확히 확인. `exec.sh`/`exec.ps1`의 기반 메커니즘(`docker compose exec`)도 별도 확인. 테스트에 사용한 로컬 복사본은 전부 정리하고 원본 sandbox 데이터 무결성 재확인 완료.

**상태**: ✅ 1.0.0.12 트랙(Dockerfile 3종 + build-and-push.sh 3종 + docker-compose.yml + deploy.sh/.ps1 + exec.sh/.ps1) 전부 실전 데이터로 end-to-end 검증 완료. 이미지 3종 레지스트리 등록 완료.

### omnionecx/1.0.0.12: 배포 폴더 구조 확정 + PARTNER_CODE도 배포 시점 값으로 일반화

- `omnionecx/1.0.0.12/deploy/`에 verifier/oacx config, log 폴더 스켈레톤(.gitkeep)을 추가 -- `sandbox/`와 동일한 패턴으로, 실제 내용물(민감정보)은 `.gitignore`(`/omnionecx/*/deploy/{verifier,oacx,log,data}/**`)로 계속 제외.
- **PARTNER_CODE 재검토**: 이전엔 'raon'으로 완전 고정했었는데, 배포마다 다른 거래처 코드를 써야 하는 경우가 있어 OPER_SORT와 같은 방식으로 되돌림 -- DML에 `__PARTNER_CODE__` 플레이스홀더를 심고, `00-patch-oper-sort.sh`를 `00-patch-placeholders.sh`로 일반화해서 `PARTNER_CODE`/`OPER_SORT` 둘 다 컨테이너 환경변수로 최초 기동 시 치환(기본값 각각 raon/dev). deploy.sh/.ps1에 PARTNER_CODE 프롬프트를 다시 추가.
- DDL은 여전히 100% 이미지 고정(외부 개입 없음), DML도 대부분 고정이지만 "배포마다 바뀔 수 있는 특정 필드만" 플레이스홀더로 열어두는 패턴을 확립 -- 앞으로 유사한 값이 더 필요해지면 SQL에 플레이스홀더 추가 + `00-patch-placeholders.sh`에 한 줄 추가로 확장 가능.
- 검토했던 대안(별도 dml/ 폴더를 마운트해서 컨테이너 기동 후 인증된 클라이언트로 추가 SQL 실행)은 root 비밀번호 인증을 스크립트가 직접 다뤄야 해서 기각 -- 플레이스홀더 치환 방식이 인증 이슈 없이 더 안전.

**테스트**: db 이미지를 재빌드/재푸시 후 (1) 기본값(raon/dev), (2) PARTNER_CODE=hanabank + OPER_SORT=prod 커스텀 조합을 각각 standalone 컨테이너로 검증. 이어서 실제 sandbox 데이터로 `deploy.sh` 전체를 PARTNER_CODE=hanabank 입력으로 재실행 -- DB와 provider.json 양쪽에 hanabank가 동일하게 반영되고 db/verifier/oacx 전부 healthy, HTTP 200/200 확인. 테스트 아티팩트 전부 정리, 원본 sandbox 무결성 재확인.

**상태**: ✅ deploy/ 폴더 스켈레톤 + PARTNER_CODE 일반화 전부 실전 검증 완료.

### omnionecx/wooriib(우리투자증권): 첫 사이트별 이미지 빌드 + 실전 배포 검증

`omnionecx/1.0.0.12/` 패턴을 그대로 따라 우리투자증권(wooriib) 전용 이미지를 빌드하고 레지스트리에 등록했다. 실제 산출물(`D:\99_project\Docker\sandbox`에 배치된 verifier 1.3.25-fix JAR, OACX 1.0.0.9 WAR, DDL/DML)로 처음부터 끝까지 검증.

**등록된 이미지**:
- `192.168.0.168:5000/servicetech2/omnionecx-db-wooriib:latest` (사이트 전용 DDL/DML 빌트인, 독립 버전 없어 latest 고정)
- `192.168.0.168:5000/servicetech2/omnionecx-verifier-wooriib:1.3.25_fix`
- `192.168.0.168:5000/servicetech2/omnionecx-oacx-wooriib:1.0.0.9`

**사이트 전용이라 새로 겪은 이슈 2건**:
1. **oacx WAR에 web.xml이 없고 web_normal.xml/web_mtranskey.xml 두 변형만 있음** — JBoss 배포용 산출물(jboss-web.xml 등)까지 같이 들어있어서, Tomcat용으로는 둘 중 하나를 web.xml로 지정해야 함. 사용자 확인 후 web_normal.xml(보안키패드 미사용) 채택 -- Dockerfile에서 `COPY app/ /app/` 직후 `cp web_normal.xml web.xml`을 추가해 빌드 시점에 1회 처리.
2. **OACX_PROVIDER 초기 데이터 손상**: `52_insert_data.sql`의 `cotoss-identify` 항목이 `cotcotoss-identifyoss`(21자)로 중복 손상되어 있어 `PROVIDER_ID varchar(20)` 컬럼 길이 초과로 DB 초기화 실패. 사용자 확인 후 값을 `cotoss-identify`로 수정. 추가로 `OACX_PROVIDER.PROVIDER_ID` 컬럼 자체도 `varchar(20)` → `varchar(25)`로 확장(향후 유사 문제 방지).

**배포 스크립트**: `omnionecx/1.0.0.12/deploy/`를 복사해 이미지 참조만 사이트 전용으로 교체(VERSION 변수 대신 `DB_VERSION_TAG`/`VERIFIER_VERSION_TAG`/`OACX_VERSION_TAG`를 스크립트에 고정값으로 박아둠 -- 폴더명이 이제 버전이 아니라 사이트 코드라서). docker-compose.yml은 완전히 파라미터화되어 있어 변경 없이 그대로 사용.

**테스트**: `D:\99_project\Docker\sandbox`에 deploy.sh/docker-compose.yml/exec.sh를 임시로 복사해(실 sandbox verifier/oacx config와 나란히) 실행 -- db/verifier/oacx 전부 healthy, HTTP 200/200, `PARTNER_CODE=raon` 확인. 테스트 산출물은 전부 정리, sandbox 원본은 유지.

**상태**: ✅ wooriib 트랙 1차 완료(이미지 3종 레지스트리 등록 + 실전 배포 검증). 저축은행중앙회(fsb), AIA생명(aia)은 아직 미착수.
