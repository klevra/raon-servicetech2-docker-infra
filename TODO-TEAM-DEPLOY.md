# TODO: 팀서버 레지스트리 배포 잔여 체크리스트

- 작성일: 2026-08-21 / 최종 수정: 2026-08-26 (Oracle XE 21c/18c 검증 완료, mysql/postgres/cubrid 정밀 버전 태그 추가)
- 목적: "팀서버 레지스트리 → 방화벽 오픈 → 이미지 등록 → 각 PC에서 스크립트로 원샷 배포" 최종 목표까지 남은 작업 정리
- 관련 문서: [PHASE-D-FIREWALL-APPROVAL.md](PHASE-D-FIREWALL-APPROVAL.md), [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md), [oracle/PRD.md](oracle/PRD.md)

---

## 서버 측 (담당: 관리자 1인)

- [x] ~~팀장님 휴가 복귀 대기 → 방화벽 오픈 승인~~ (2026-08-25 완료)
- [x] ~~팀서버(`new-servicetech2-1`, `192.168.0.168`) 인바운드 5000/tcp 오픈~~ (2026-08-25 완료, 실제 접속 검증까지 완료)
- [ ] (검토 필요) 현재 팀서버 `registry` 컨테이너에 **볼륨 마운트도 `--restart` 정책도 없음** — 컨테이너 삭제/서버 재부팅 시 이미지 유실 위험. 데이터 영속화 + 자동 재시작 적용 여부 결정
- [ ] (선택) 현재 레지스트리 인증 없음(사내망 신뢰 전제) — 필요 시 `REGISTRY_AUTH=htpasswd` 적용 검토 ([linux-registry-setup.md](registry-server/linux-registry-setup.md) 5절 참고)
- [x] ~~Oracle 19c EE 베이스 이미지를 팀서버 레지스트리에 push~~ (2026-08-25 완료 — 네트워크 push는 반복 타임아웃 나서 `docker save`→`scp`→서버에서 `load`/`push` 방식으로 우회 성공. `oracle/base/build-and-push.*`로 직접 push 재시도는 여전히 타임아웃 날 수 있음, 안 되면 같은 우회법 사용)
- [x] ~~MariaDB 베이스 이미지(latest/11.4/10.11) 팀서버 레지스트리에 push~~ (2026-08-25 완료, 이건 이미지가 작아서 직접 push로 문제없이 성공)
- [x] ~~MySQL/PostgreSQL/CUBRID 베이스 이미지(각 latest) 팀서버 레지스트리에 push~~ (2026-08-25 완료. MySQL은 대용량 레이어 타임아웃이 나서 사용자가 직접 등록, PostgreSQL/CUBRID는 재시도로 자체 해결)

## 팀원 PC 각자 (담당: 팀원 개인)

- [ ] hosts 파일에 `192.168.0.168  servicetech2` 등록
- [ ] Docker `insecure-registries`에 `servicetech2:5000`**과** `192.168.0.168:5000` 둘 다 등록 후 Docker 재시작/Apply (스크립트 기본값이 IP라 IP 쪽도 꼭 등록해야 함, 2026-08-25 기준)
- [ ] `curl http://servicetech2:5000/v2/` 또는 `http://192.168.0.168:5000/v2/` 로 연결 테스트 → `{}` 응답 확인
- [ ] `oracle/deploy/deploy.ps1`(또는 `.sh`/`.bat`) 또는 `mariadb`/`mysql`/`postgres`/`cubrid`의 `deploy.ps1` 실행 → 레지스트리 주소는 기본값(Enter)이 이미 `192.168.0.168:5000`이라 그대로 진행하면 됨 (CUBRID는 `--privileged`로 뜨니 사전에 인지할 것)

상세 절차: [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md)

## 검증 완료 항목

- [x] ~~애플리케이션 계정 생성 — Service Name 방식~~ (2026-08-21 로컬, 2026-08-25 팀서버 경유 재검증 완료)
- [x] ~~애플리케이션 계정 생성 — SID 방식~~ (2026-08-21 로컬, 2026-08-25 팀서버 경유 재검증 완료)
- [x] ~~팀서버 레지스트리를 경유한 `deploy.ps1` 종단간 배포 테스트~~ (2026-08-25 완료, Oracle 19c EE 기준)
- [x] ~~MariaDB 신규 구축 + 팀서버 경유 배포 검증~~ (2026-08-25 완료 — root/앱 계정 로그인, 권한, HEALTHCHECK 전부 확인)
- [x] ~~MySQL/PostgreSQL/CUBRID 신규 구축 + 배포 검증~~ (2026-08-25 완료 — 관리자/앱 계정 로그인, 권한(테이블 생성/INSERT), HEALTHCHECK 전부 확인. `.sh`/`.ps1` 양쪽 검증)
- [x] ~~Oracle XE `21c-xe`/`18c-xe` 배포 검증~~ (2026-08-26 완료 — 21c-xe는 Service Name 방식, 18c-xe는 SID 방식으로 각각 앱 계정 로그인·권한(테이블 생성/INSERT) 확인. 검증 중 실제 버그 2건 발견·수정, 아래 참고)

## 검증 남은 항목

- [ ] MariaDB/MySQL/PostgreSQL DDL/DML(`/docker-entrypoint-initdb.d/`) 자동 실행 경로 실제 파일로 테스트 (지금까지는 파일 없이 빈 경로로만 검증. CUBRID는 이 기능 자체가 없어 대상 아님)
- [ ] 팀원 PC 1곳 이상에서 위 "팀원 PC 각자" 체크리스트 실제로 따라해보고 문서 미비점 확인
- [ ] (신규, 낮은 우선순위) 각 DB별로 흩어진 `deploy.*` 스크립트를 하나의 통합 진입점으로 리팩터링 — 사용자가 "대다수의 DBMS를 처리하고 그 뒤에 생각하자"고 결정해 보류 중. 논의된 구조안은 WORKLOG.md 2026-08-25 "스크립트 통합(최종 목표) 논의" 절 참고

## Oracle 추가 에디션 (2026-08-26 검증 완료)

- [x] ~~Oracle XE `21c-xe` (gvenzl 이미지) 배포 테스트~~ — 완전 무료(용량 제한: 2 CPU/2GB RAM/12GB 데이터)
- [x] ~~Oracle XE `18c-xe` (gvenzl 이미지) 배포 테스트~~ — 위와 동일, 구버전 호환용
- **검증 중 발견·수정한 실제 버그 2건** (`oracle/deploy/deploy.sh`·`.ps1`·`Dockerfile`):
  1. **앱 계정 생성 SQL이 조용히 무시됨**: EE 이미지는 초기화 SQL을 `/opt/oracle/scripts/setup`에서 찾지만, gvenzl XE 커뮤니티 이미지는 다른 경로(`/container-entrypoint-initdb.d`)를 사용한다 (실제 `container-entrypoint.sh` 코드로 확인). 지금까지 EE 경로만 마운트하고 있어 XE에서는 SQL 파일이 마운트는 되어도 전혀 실행되지 않았음(에러도 없음) — 에디션별로 마운트 경로 분기하도록 수정
  2. **XE에서 healthcheck가 영원히 "unknown"**: EE 이미지는 자체 HEALTHCHECK(`$ORACLE_BASE/$CHECK_DB_LOCK_FILE`)가 내장돼 있지만 gvenzl XE 이미지는 HEALTHCHECK 자체가 없음(`docker inspect`로 확인, `Config.Healthcheck: null`) — `deploy.sh`/`.ps1`의 상태 폴링이 30분 타임아웃까지 무의미하게 대기하다 끝남. `oracle/deploy/Dockerfile`에 EE/XE 양쪽의 실제 체크 스크립트를 런타임에 감지해 분기하는 HEALTHCHECK를 추가해 해결 (재검증 시 20초 만에 healthy 전환 확인)

## "무료지만 EULA 동의·비운영 전용 제약 있음" 그룹 (2026-08-25 조사 완료, 착수 전)

- [ ] **MSSQL** — `mcr.microsoft.com/mssql/server` 공식 이미지로 Docker 실행 가능 확인. `ACCEPT_EULA=Y` 필요. Developer(전기능·비운영 전용) 또는 Express(운영 가능·10GB 제한) 중 선택
- [ ] **Db2** — `ibmcom/db2` 공식 이미지로 Docker 실행 가능 확인. `LICENSE=accept` 필요. Community Edition 자체는 무상이지만 **Docker 이미지는 IBM이 비운영 전용으로 명시**
- [ ] **Informix** — `ibmcom/informix-developer-database` 공식 이미지로 Docker 실행 가능 확인. `LICENSE=accept` 필요. Developer Edition, 비운영 전용
- 셋 다 "Docker로 올릴 수 있는가?"에 대한 답은 **Yes** — 계정/구매 없이 공식 이미지 pull 자체는 가능. 다만 셋 다 최초 실행 시 EULA 동의 플래그를 넘겨야 하고, Db2/Informix는 이미지 자체가 비운영 전용으로 못박혀 있어 이 프로젝트의 "테스트/데모 전용" 취지와는 잘 맞음

## 신규 트랙: JDK/Tomcat 애플리케이션 서버 이미지 (2026-08-25 요청, 상세는 다음 세션에서 확정)

- [ ] **JDK 18** 이미지 구축 (DB가 아닌 애플리케이션 런타임 — 별도 트랙)
- [ ] **JDK 21** 이미지 구축
- [ ] **Tomcat** 이미지 구축
- 공통 설정 항목(확정, 세부 값/기본값은 미정): `app_path`, `config_path`, `log_path`, `port_nbr`
  - `app_path`/`config_path`/`log_path` 3개는 전부 **볼륨 마운트 경로** (호스트 ↔ 컨테이너 바인드마운트 대상)
  - `port_nbr`은 리스너 포트
- 디테일(정확한 마운트 대상 디렉터리, 이미지 베이스 선택, 배포 스크립트 패턴을 DB 3단계 구조와 동일하게 갈지 여부 등)는 다음 세션에서 논의 예정 — 오늘은 항목만 기록

## 참고: 2026-08-26 정밀 버전 태그 추가

- mysql/postgres/cubrid는 지금까지 `latest` 태그만 레지스트리에 있었음. `latest`가 실제로 가리키는 정확한 버전을 확인해(mysql=`26.7.0`, postgres=`18.6`, cubrid=`11.4.5`) 동일 이미지에 태그만 추가로 붙여 push 완료(재업로드 없음, 즉시 성공)
- 각 `deploy.sh`/`.ps1`의 버전 선택 메뉴에 "옵션 4"로 이 정밀 버전을 추가해 실제로 선택·배포 가능하게 함 — `latest`는 향후 build-and-push 재실행 시 내용이 바뀔 수 있으므로, 특정 버전을 고정하고 싶으면 옵션 4 사용

## 참고: 2026-08-25 발견한 이슈 (환경 문제, 스크립트와 무관)

- 이 PC의 WSL2 메모리 상한 설정이 낮으면 Oracle 인스턴스가 OOM-kill 될 수 있음 → `.wslconfig`에 `memory=` 제한을 걸지 않는 것을 권장 (기본값이면 충분)
- `docker manifest inspect`는 이 프로젝트의 insecure 레지스트리에서 오탐(false negative)을 낼 수 있어 스크립트에서 이미 curl 기반 검증으로 교체함 — 수동으로 확인할 때도 `docker manifest inspect` 대신 `docker pull` 또는 `curl .../tags/list`로 확인할 것

## 참고: 지난 작업 요약 (2026-08-21)

- `oracle/deploy`, `oracle/base` 스크립트: 애플리케이션 계정 자동 생성(ORA-65096/대소문자 버그 수정 포함), Service Name/SID 접속 방식 분기, JDBC URL 표시, 랜덤 비밀번호 자동 생성, EM Express 제거
- Windows 인코딩: `.bat` 3종 신규 작성(UTF-8 BOM + `chcp 65001`), PowerShell `Read-Host -AsSecureString`의 비대화형 입력 hang 버그 수정
- 팀서버 레지스트리 접속 정보 확정 및 문서화 (`servicetech2` → `192.168.0.168`)
