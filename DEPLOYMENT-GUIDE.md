# 팀서버 Docker Rootless 배포 완전 가이드

**작성일**: 2026-08-18  
**대상 환경**: Oracle Linux 8.10, Kernel 5.15.0-306  
**목표**: Docker 24.0.9 (rootful) → Rootless 전환 + 레지스트리 구축

---

## 📚 문서 구조

이 배포는 **순서대로 진행해야 하는 여러 단계**로 구성되어 있습니다.

### Phase 0: 네트워크/패키지 연결성 확인 ⭐ **매우 중요**
📄 **[TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md)**
- dnf 패키지 서버 연결 확인
- Docker Hub 웹 접근 확인
- 4가지 시나리오 별 대응 방법

**💡 설치 실패의 주요 원인이므로 반드시 먼저 완료하세요!**

---

### Phase 1-6: Rootless 설치 및 레지스트리 구축
📄 **[docker-rootless-setup-oracle8.md](registry-server/docker-rootless-setup-oracle8.md)**

| Phase | 내용 | 시간 |
|-------|------|------|
| 1 | Rootful Docker 제거 | 5분 |
| 2 | Rootless Docker 설치 | 10분 |
| 3 | Rootless 검증 | 5분 |
| 4 | 레지스트리 재구성 | 10분 |
| 5 | Docker 버전 업그레이드 (Optional) | 10분 |
| 6 | 최종 검증 | 5분 |

**총 소요 시간**: ~45분 (Phase 5 제외)

---

### 단계별 실행 체크리스트
📄 **[TEAM-SERVER-CHECKLIST.md](TEAM-SERVER-CHECKLIST.md)**
- Phase 0~6 실행 결과 기록용
- 문제 발생 시 참고

---

### 분석 및 의사결정 배경
📄 **[TEAM-SERVER-ANALYSIS.md](TEAM-SERVER-ANALYSIS.md)**
- Rootful vs Rootless 비교표
- 왜 Rootless인지 설명
- 리스크 및 롤백 방법

---

## ⚠️ 권한 확인 (가장 먼저!)

```bash
# 현재 사용자 확인
$ whoami
servicetech2

# sudo 가능 여부 확인
$ sudo -v
# → 비밀번호 입력 후 OK ✅ 또는 오류 ❌
```

**준비**:
- ✅ 일반 사용자 (예: servicetech2)
- ⚠️ sudo 비밀번호 준비
- 🔴 root가 아닐 것

---

## 🚀 빠른 시작 (정상 네트워크 환경)

**Step 1: 네트워크 확인** (일반 사용자 권한)
```bash
$ curl -I https://registry.hub.docker.com/v2/        # 일반 사용자 OK ✅
$ sudo dnf makecache                                   # sudo 필요 ⚠️
```
✅ 둘 다 성공하면 진행

**Step 2: Rootful 제거**
```bash
sudo systemctl stop docker
sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**Step 3: Rootless 설치**
```bash
curl -fsSL https://get.docker.com/rootless | sh
systemctl --user start docker
systemctl --user enable docker
```

**Step 4: 검증**
```bash
docker run --rm hello-world  # sudo 불필요!
```

**Step 5: 레지스트리 기동**
```bash
mkdir -p ~/.docker/volumes/servicetech2-registry/data
docker run -d \
  --name servicetech2-registry \
  --restart=always \
  -p 5000:5000 \
  -v ~/.docker/volumes/servicetech2-registry/data:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

curl http://localhost:5000/v2/  # {} 반환되면 OK
```

**완료!** 다음은 최종 검증 ([TEAM-SERVER-CHECKLIST.md](TEAM-SERVER-CHECKLIST.md)의 Phase 6)

---

## ⚠️ 네트워크 문제 발생 시

### 시나리오별 대응

**A. dnf는 OK, Docker Hub 접근 불가**
→ [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md)의 "시나리오 B: 일부 도메인만 차단" 참고

**B. HTTPS만 차단 (HTTP 가능)**
→ [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md)의 "시나리오 D: HTTPS 차단" 참고

**C. 완전 오프라인**
→ IT팀에 연락. 별도 절차 필요 (문서 작성 예정)

---

## 📋 체크리스트 (실행 전 확인)

- [ ] [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md) Phase 0 완료
  - [ ] dnf 패키지 서버 확인
  - [ ] Docker Hub 연결 확인
  - [ ] 설치 경로 결정 (정상/대체/오프라인)

- [ ] [TEAM-SERVER-CHECKLIST.md](TEAM-SERVER-CHECKLIST.md) 준비
  - [ ] Phase별 섹션 출력 또는 화면에 띄워 놓기
  - [ ] 결과 기록 준비

- [ ] 관리자 권한 확인
  - [ ] `sudo` 패스워드 준비
  - [ ] 필요시 `visudo` 권한 확인

- [ ] 백업 (선택사항, 권장)
  - [ ] 기존 /etc/docker 백업
  - [ ] 레지스트리 데이터 있다면 백업

---

## 🔄 롤백 (문제 발생 시)

모든 Phase를 롤백 가능합니다.

### Rootless 제거 후 Rootful 복구
```bash
# 1. Rootless 제거
systemctl --user stop docker
systemctl --user disable docker
rm -rf ~/.docker ~/

# 2. Rootful 재설치
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker
sudo systemctl enable docker

# 3. 검증
docker ps
```

자세한 내용: [docker-rootless-setup-oracle8.md](registry-server/docker-rootless-setup-oracle8.md)의 "참고: Rootful 복구 (롤백)"

---

## 📊 의사결정 흐름도

```
시작
  ↓
Phase 0: 네트워크 확인 [TEAM-SERVER-NETWORK-CHECK.md]
  ├─ ✅ 정상 (dnf OK, Docker Hub OK)
  │  └─ → 정상 설치 경로 (Phase 1~6 진행)
  │
  ├─ ⚠️ 부분 차단 (dnf OK, Docker Hub 차단)
  │  └─ → 이미지 사전 다운로드 필요 (Phase 2 변경)
  │
  ├─ ⚠️ HTTPS 차단 (HTTP OK)
  │  └─ → HTTP 미러 또는 프록시 설정 필요
  │
  └─ ❌ 완전 차단
     └─ → IT팀 상담 필수 (별도 절차)

Phase 1: Rootful 제거 [docker-rootless-setup-oracle8.md]
  ↓
Phase 2: Rootless 설치
  ↓
Phase 3: 검증 (hello-world)
  ↓
Phase 4: 레지스트리 구성
  ↓
Phase 5: 버전 업그레이드 (Optional)
  ↓
Phase 6: 최종 검증 (push/pull)
  ↓
✅ 완료!
```

---

## 🆘 문제 해결

| 증상 | 원인 | 해결 방법 |
|------|------|----------|
| `dnf makecache` 실패 | 네트워크 연결 불가 | [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md) 참고 |
| `curl https://...` 실패 | HTTPS 차단 | HTTP 미러 설정 또는 프록시 사용 |
| `docker: command not found` (Phase 3) | PATH 미설정 | `export PATH=$PATH:~/.local/bin` |
| `permission denied docker.sock` | 권한 이슈 | `systemctl --user restart docker` |
| 레지스트리 5000 포트 실패 | 기존 rootful 데몬 충돌 | `sudo systemctl status docker` 확인 후 중지 |

자세한 내용: [docker-rootless-setup-oracle8.md](registry-server/docker-rootless-setup-oracle8.md)의 "문제 해결"

---

## 🎓 학습 자료

**Rootless Docker 개념**:
- 보안 모델: user namespace 활용으로 root 권한 불필요
- systemd 통합: `systemctl --user` 로 사용자 프로세스로 관리
- 볼륨 권한: 사용자 UID/GID 범위 내에서만 접근 가능

**Oracle Linux 특성**:
- Fedora 기반 (dnf 패키지 매니저)
- RHEL 호환성 (docker-ce 저장소 동일)
- user namespace 기본 지원

---

## 📅 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | 팀서버 Docker 업그레이드 완전 가이드 작성. Phase 0 (네트워크 확인) 추가, 모든 문서 연동 |

---

## 마지막 체크

배포 전에 다시 한 번 확인하세요:

```bash
# 1. 문서 준비 확인
ls -la TEAM-SERVER-NETWORK-CHECK.md TEAM-SERVER-CHECKLIST.md \
  registry-server/docker-rootless-setup-oracle8.md

# 2. 팀서버 접속 정보 확인
ping <팀서버IP>
ssh servicetech2@<팀서버IP>

# 3. 현재 상태 기록
date > deployment-start.log
echo "Docker 24.0.9 rootful" >> deployment-start.log
```

**준비 완료되면 [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md) Phase 0부터 시작하세요!**

---

## 📞 문의 및 피드백

- 배포 중 문제 발생 → [docker-rootless-setup-oracle8.md](registry-server/docker-rootless-setup-oracle8.md)의 "문제 해결" 섹션
- 네트워크 관련 문제 → [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md)의 "문제별 대응 방안"
- 진행 상황 기록 → [TEAM-SERVER-CHECKLIST.md](TEAM-SERVER-CHECKLIST.md)

---

**이 가이드를 따라 모든 단계를 완료하면, 팀서버에 보안이 강화된 Rootless Docker와 프라이빗 레지스트리가 구축됩니다!** 🚀
