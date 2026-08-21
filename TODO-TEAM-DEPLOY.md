# TODO: 팀서버 레지스트리 배포 잔여 체크리스트

- 작성일: 2026-08-21
- 목적: "팀서버 레지스트리 → 방화벽 오픈 → 이미지 등록 → 각 PC에서 스크립트로 원샷 배포" 최종 목표까지 남은 작업 정리
- 관련 문서: [PHASE-D-FIREWALL-APPROVAL.md](PHASE-D-FIREWALL-APPROVAL.md), [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md), [oracle/PRD.md](oracle/PRD.md)

---

## 서버 측 (담당: 관리자 1인)

- [ ] 팀장님 휴가 복귀 대기 (예상 2026-08-25) → 방화벽 오픈 승인
- [ ] 팀서버(`new-servicetech2-1`, `192.168.0.168`) 인바운드 5000/tcp 오픈
  ```bash
  sudo firewall-cmd --permanent --add-port=5000/tcp
  sudo firewall-cmd --reload
  ```
- [ ] (검토 필요) 현재 팀서버 `registry` 컨테이너에 **볼륨 마운트도 `--restart` 정책도 없음** — 컨테이너 삭제/서버 재부팅 시 이미지 유실 위험. 데이터 영속화 + 자동 재시작 적용 여부 결정
- [ ] (선택) 현재 레지스트리 인증 없음(사내망 신뢰 전제) — 필요 시 `REGISTRY_AUTH=htpasswd` 적용 검토 ([linux-registry-setup.md](registry-server/linux-registry-setup.md) 5절 참고)
- [ ] 방화벽 오픈 후, 이 PC(또는 관리자 PC)에서 Oracle 19c EE 베이스 이미지를 팀서버 레지스트리에 push
  ```bash
  # oracle/base/build-and-push.ps1 (또는 .sh/.bat) 실행
  # "대상 레지스트리 주소" 프롬프트에 servicetech2:5000 입력
  ```
- [ ] push 후 `curl http://servicetech2:5000/v2/_catalog`로 등록 확인

## 팀원 PC 각자 (담당: 팀원 개인, 방화벽 승인과 무관하게 미리 진행 가능)

- [ ] hosts 파일에 `192.168.0.168  servicetech2` 등록
- [ ] Docker `insecure-registries`에 `servicetech2:5000` 등록 후 Docker 재시작/Apply
- [ ] (방화벽 오픈 후) `curl http://servicetech2:5000/v2/` 로 연결 테스트 → `{}` 응답 확인
- [ ] (방화벽 오픈 후) `oracle/deploy/deploy.ps1`(또는 `.sh`/`.bat`) 실행, 레지스트리 주소로 `servicetech2:5000` 입력 → 컨테이너 배포

상세 절차: [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md)

## 검증 남은 항목

- [ ] 실제 팀서버 레지스트리를 경유한 `deploy.ps1` 종단간 배포 테스트 (지금까지는 로컬 PC 레지스트리 기준으로만 검증됨)
- [x] ~~애플리케이션 계정 생성 — Service Name 방식~~ (2026-08-21 로컬 검증 완료)
- [x] ~~애플리케이션 계정 생성 — SID 방식~~ (2026-08-21 로컬 검증 완료)
- [ ] gvenzl(XE) 이미지 경로(`21c-xe`/`18c-xe`)로 실제 배포 테스트 (아직 19c EE 경로만 검증됨 — [oracle/PRD.md](oracle/PRD.md) 리스크 항목 참고)

## 참고: 오늘(2026-08-21) 완료된 작업 요약

- `oracle/deploy`, `oracle/base` 스크립트: 애플리케이션 계정 자동 생성(ORA-65096/대소문자 버그 수정 포함), Service Name/SID 접속 방식 분기, JDBC URL 표시, 랜덤 비밀번호 자동 생성, EM Express 제거
- Windows 인코딩: `.bat` 3종 신규 작성(UTF-8 BOM + `chcp 65001`), PowerShell `Read-Host -AsSecureString`의 비대화형 입력 hang 버그 수정
- 팀서버 레지스트리 접속 정보 확정 및 문서화 (`servicetech2` → `192.168.0.168`)
