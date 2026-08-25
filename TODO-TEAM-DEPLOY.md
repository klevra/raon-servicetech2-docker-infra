# TODO: 팀서버 레지스트리 배포 잔여 체크리스트

- 작성일: 2026-08-21 / 최종 수정: 2026-08-25
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

## 팀원 PC 각자 (담당: 팀원 개인)

- [ ] hosts 파일에 `192.168.0.168  servicetech2` 등록
- [ ] Docker `insecure-registries`에 `servicetech2:5000`**과** `192.168.0.168:5000` 둘 다 등록 후 Docker 재시작/Apply (스크립트 기본값이 IP라 IP 쪽도 꼭 등록해야 함, 2026-08-25 기준)
- [ ] `curl http://servicetech2:5000/v2/` 또는 `http://192.168.0.168:5000/v2/` 로 연결 테스트 → `{}` 응답 확인
- [ ] `oracle/deploy/deploy.ps1`(또는 `.sh`/`.bat`) 또는 `mariadb/deploy/deploy.ps1` 실행 → 레지스트리 주소는 기본값(Enter)이 이미 `192.168.0.168:5000`이라 그대로 진행하면 됨

상세 절차: [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md)

## 검증 완료 항목

- [x] ~~애플리케이션 계정 생성 — Service Name 방식~~ (2026-08-21 로컬, 2026-08-25 팀서버 경유 재검증 완료)
- [x] ~~애플리케이션 계정 생성 — SID 방식~~ (2026-08-21 로컬, 2026-08-25 팀서버 경유 재검증 완료)
- [x] ~~팀서버 레지스트리를 경유한 `deploy.ps1` 종단간 배포 테스트~~ (2026-08-25 완료, Oracle 19c EE 기준)
- [x] ~~MariaDB 신규 구축 + 팀서버 경유 배포 검증~~ (2026-08-25 완료 — root/앱 계정 로그인, 권한, HEALTHCHECK 전부 확인)

## 검증 남은 항목

- [ ] gvenzl(XE) 이미지 경로(`21c-xe`/`18c-xe`)로 실제 배포 테스트 (아직 19c EE 경로만 검증됨 — [oracle/PRD.md](oracle/PRD.md) 리스크 항목 참고)
- [ ] MariaDB DDL/DML(`/docker-entrypoint-initdb.d/`) 자동 실행 경로 실제 파일로 테스트 (지금까지는 DDL/DML 없이만 검증)
- [ ] 팀원 PC 1곳 이상에서 위 "팀원 PC 각자" 체크리스트 실제로 따라해보고 문서 미비점 확인

## 참고: 2026-08-25 발견한 이슈 (환경 문제, 스크립트와 무관)

- 이 PC의 WSL2 메모리 상한 설정이 낮으면 Oracle 인스턴스가 OOM-kill 될 수 있음 → `.wslconfig`에 `memory=` 제한을 걸지 않는 것을 권장 (기본값이면 충분)
- `docker manifest inspect`는 이 프로젝트의 insecure 레지스트리에서 오탐(false negative)을 낼 수 있어 스크립트에서 이미 curl 기반 검증으로 교체함 — 수동으로 확인할 때도 `docker manifest inspect` 대신 `docker pull` 또는 `curl .../tags/list`로 확인할 것

## 참고: 지난 작업 요약 (2026-08-21)

- `oracle/deploy`, `oracle/base` 스크립트: 애플리케이션 계정 자동 생성(ORA-65096/대소문자 버그 수정 포함), Service Name/SID 접속 방식 분기, JDBC URL 표시, 랜덤 비밀번호 자동 생성, EM Express 제거
- Windows 인코딩: `.bat` 3종 신규 작성(UTF-8 BOM + `chcp 65001`), PowerShell `Read-Host -AsSecureString`의 비대화형 입력 hang 버그 수정
- 팀서버 레지스트리 접속 정보 확정 및 문서화 (`servicetech2` → `192.168.0.168`)
