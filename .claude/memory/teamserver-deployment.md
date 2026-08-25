---
name: teamserver-deployment
description: 팀서버 Docker Rootless 배포 전략 및 4단계 검증 프로세스
metadata:
  type: project
---

## 팀서버 Docker Rootless 배포 전략 (2026-08-18)

### 팀서버 환경
- **OS**: Oracle Linux Server 8.10 (Fedora 기반)
- **Kernel**: 5.15.0-306 (user namespace 완벽 지원)
- **현재 Docker**: 24.0.9 (dnf 패키지 설치, rootful)
- **상태**: 컨테이너 없음, daemon.json 없음 (깨끗한 상태)

### 결정: Rootless Docker 완전 전환
**Why**: 
- 최적 타이밍 (처음부터 깨끗한 구성 가능)
- 보안 고려 (프라이빗 레지스트리는 중요 자산)
- 기술 호환 (Kernel 완벽 지원, 포트 5000 직접 바인드 가능)

### 실행 프로세스 (6단계)
1. **Phase 0** (필수 사전확인): 네트워크/패키지 연결성 확인
   - dnf 패키지 서버 → Docker 설치 가능 여부
   - Docker Hub 접근 → 이미지 다운로드 가능 여부
   - 4가지 시나리오: 정상 / 부분차단(dnf OK) / HTTPS차단 / 완전차단

2. **Phase 1**: Rootful Docker 제거 (5분)
3. **Phase 2**: Rootless Docker 설치 + systemd 통합 (10분)
4. **Phase 3**: 검증 (hello-world 테스트, 5분)
5. **Phase 4**: 레지스트리 재구성 (10분)
6. **Phase 5** (선택): Docker 버전 업그레이드 28/29
7. **Phase 6**: 최종 검증 (push/pull 테스트, 5분)

### 관련 문서
- [[DEPLOYMENT-GUIDE.md]] — 통합 진입점 (전체 흐름도, 빠른 시작)
- [[TEAM-SERVER-NETWORK-CHECK.md]] — Phase 0 (네트워크 확인, 문제별 대응)
- [[TEAM-SERVER-CHECKLIST.md]] — 단계별 실행 체크리스트
- [[TEAM-SERVER-ANALYSIS.md]] — 분석 배경 (Rootful vs Rootless 비교표)
- [[docker-rootless-setup-oracle8.md]] — 상세 설치 가이드
- [[docker-upgrade-24-to-28.md]] — Phase 5 (버전 업그레이드)

### 리스크 및 대응
- **네트워크 문제**: Phase 0에서 사전 확인 → 4가지 시나리오별 대응 방법 제시
- **설치 실패**: 오프라인/프록시/HTTP 미러 대안 제공
- **롤백**: Rootful 복구 명령어 문서화 (언제든 되돌리기 가능)

### 예상 소요 시간
- Phase 0 (확인): 10분
- Phase 1~6 (실행): ~45분
- 총 ~55분

### 상태
- ✅ 분석 완료
- ✅ 모든 문서 작성 완료
- ⏳ 팀서버에서 단계별 실행 대기 (사용자 담당)
