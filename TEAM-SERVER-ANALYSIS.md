# 팀서버 Docker 업그레이드 분석 (Oracle Linux 8.10)

작성일: 2026-08-18

## 1. 현재 상태 확인 결과

```
OS: Oracle Linux Server 8.10 (Fedora 기반)
Kernel: 5.15.0-306
Docker 버전: 24.0.9, build 2936816
설치 방식: dnf 패키지 (소스 빌드 아님 ✅)
실행 방식: rootful (현재)
daemon.json: 없음 (커스텀 설정 없음)
현재 컨테이너: 없음 (servicetech2-registry 미배포)
```

**좋은 상황**:
- 패키지 매니저 설치 → 업그레이드 간단
- 커스텀 설정 없음 → 마이그레이션 간편
- 아직 프로덕션 컨테이너 없음 → rootless 전환 최적 타이밍

---

## 2. Rootful vs Rootless 비교표

| 항목 | Rootful | Rootless |
|------|---------|----------|
| **보안** | ⚠️ 낮음 (dockerd=root) | ✅ 높음 (일반 사용자 권한) |
| **성능** | ✅ 최고 | 약간의 오버헤드 (~5-10%) |
| **호환성** | ✅ 최고 (모든 기능) | ⚠️ 제약있음 (아래 참고) |
| **설정 복잡도** | ✅ 단순 | 복잡함 (user namespace) |
| **systemd 통합** | ✅ 지원 | ✅ 지원 (systemd --user) |
| **volume 권한** | 명시적 처리 필수 | 사용자 권한 범위 내 |
| **네트워크 포트** | 1-65535 모두 가능 | < 1024 제약 (443, 80은 특수 처리 필수) |
| **권장 용도** | 프로덕션 CI/CD | 개발, 보안 중시 환경 |

### Rootless 제약사항
- 포트 1024 이하: 수동 포트 포워딩 필요 (systemd-userns-restrict)
- 일부 볼륨 권한 이슈 (uid/gid mapping)
- 성능: 약간의 오버헤드
- Docker Daemon 재시작 후 컨테이너 자동 복구 제약

---

## 3. Oracle Linux 8.10 × Rootless 호환성 체크

### Kernel 요구사항 ✅
```
5.15.0-306 → 충분함
- user namespace: kernel 3.10+
- cgroup v2: kernel 4.5+
- seccomp: kernel 3.17+
```

### 필요한 설정 항목

```bash
# 1. User namespace 활성화 확인
cat /proc/sys/user/max_user_namespaces
# → 0이 아니면 OK (기본값 보통 허용됨)

# 2. /etc/subuid, /etc/subgid 확인 (아래 참고)
cat /etc/subuid
cat /etc/subgid

# 3. cgroup v2 확인 (optional, systemd 통합 시 권장)
mount | grep cgroup2
```

---

## 4. 전환 경로 (3가지 선택지)

### 🔴 **Option A: Rootful 유지** (현재)
- 현상 유지
- Docker 28로만 업그레이드
- **장점**: 간단, 호환성 최고
- **단점**: 보안 리스크 (모든 프로세스가 root 권한)

**절차**: [registry-server/docker-upgrade-24-to-28.md](registry-server/docker-upgrade-24-to-28.md) 그대로 따르기

---

### 🟡 **Option B: Rootless로 완전 전환** (권장)
- 현재 rootful 데몬 제거 → rootless 새로 설치
- Docker 28 → 최신 (또는 29)
- **장점**: 보안 강화, 새 설정 적용
- **단점**: 재설정 필요, 처음부터 시작

**요구 단계**:
1. `dockerd` 인스턴스 정리 (지금 컨테이너 없으므로 간단)
2. 일반 사용자 계정에서 rootless 데몬 설치
3. `systemctl --user start docker` 로 관리
4. 레지스트리 데이터 마이그레이션 (user 권한 범위로)

**포트 이슈 대응**:
- 레지스트리 5000번 포트 → rootless에서 직접 바인드 불가 (>1024 OK)
- 우회책: `systemd` user socket forwarding 또는 `socat` 사용

---

### 🟢 **Option C: 단계적 전환** (균형잡힌 선택)
1. **Phase 1 (이번)**: Rootful 유지 + Docker 24 → 28 업그레이드
2. **Phase 2 (검증 후)**: Rootless 신규 설치 (별도 사용자, 병행 운영)
3. **Phase 3 (안정화)**: Rootless로 완전 전환

**장점**: 리스크 분산, 롤백 용이, 검증 시간 확보
**단점**: 초기 설정 이중화 (두 개 데몬 관리)

---

## 5. **권장 방안**

### 현 상황 최적 선택: **🟡 Option B (Rootless 완전 전환)**

**이유**:
1. ✅ 지금이 최적 타이밍
   - 프로덕션 컨테이너 0개
   - 커스텀 daemon.json 없음
   - 처음부터 보안 설정 가능

2. ⚠️ 보안 고려
   - 사내 레지스트리 = 중요 자산
   - rootless = 컨테이너 탈출/권한 상승 시 데미지 제한

3. ✅ 유지보수 용이
   - 포트 5000은 < 1024 아니므로 직접 바인드 가능
   - 미래 확장성 (다른 사용자도 독립적으로 Docker 사용 가능)

---

## 5-1. ⚠️ **예비 확인 (Phase 0): 네트워크/패키지 연결성**

**가장 먼저 이것을 확인해야 합니다!** (설치 실패의 주요 원인)

두 가지 핵심 확인:

### 확인 1: dnf 패키지 서버 연결
```bash
dnf makecache          # 패키지 캐시 갱신 가능?
dnf list docker-ce     # Docker 패키지 검색 가능?
```
- ✅ OK → Docker 설치 가능
- ❌ 실패 → Docker 저장소 미등록 또는 dnf 설정 문제

### 확인 2: Docker Hub / 웹서버 통신
```bash
curl -I https://registry.hub.docker.com/v2/              # Docker Hub
curl -I https://get.docker.com/rootless                  # 설치 스크립트
curl -s https://download.docker.com/linux/rhel/docker-ce.repo | head -5  # 저장소
```
- ✅ OK → 온라인 설치 가능
- ❌ HTTPS 차단 → HTTP 미러 필요
- ❌ 완전 차단 → 오프라인 설치 필요

**예상 네 가지 시나리오**:

| 시나리오 | dnf | Docker Hub | 대응 |
|---------|-----|------------|------|
| A: 정상 | ✅ | ✅ | 정상 설치 경로 |
| B: 부분 차단 | ✅ | ❌ | 이미지 사전 다운로드 + 로컬 설치 |
| C: HTTPS 차단 | ✅ | ⚠️ (HTTP OK) | HTTP 미러 또는 프록시 설정 |
| D: 완전 차단 | ❌ | ❌ | 수동 바이너리 설치 (별도 절차) |

**📌 자세한 확인 및 대응 방법**: [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md)

---

## 6. 실행 계획

### Phase 1: 현재 상태 백업 + 사전 설정

```bash
# 1. 현재 Docker 상태 기록
sudo docker info > ~/docker-info-backup-24.0.9.txt

# 2. daemon.json 백업 (있다면)
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak-$(date +%F) 2>/dev/null || echo "No daemon.json"

# 3. 일반 사용자에 subuid/subgid 할당 확인
# (보통 useradd 시 자동, 수동 확인만)
getent passwd servicetech2
```

### Phase 2: Rootful 정리 + Rootless 설치

```bash
# 1. 기존 rootful 데몬 중지
sudo systemctl stop docker

# 2. Rootless 설치 (--user로 설치, daemonize 없음 — systemd 관리)
# (Docker 공식 스크립트 또는 수동 설치)

# 3. Rootless 데몬 시작 (systemd --user)
systemctl --user start docker
systemctl --user enable docker
```

### Phase 3: 레지스트리 재구성

```bash
# 레지스트리 데이터 경로 재설정
# /opt/servicetech2-registry → /home/servicetech2/.local/share/docker (또는 커스텀)

# 권한 조정
chown -R servicetech2:servicetech2 /home/servicetech2/.local/share/docker
```

---

## 7. 다음 단계별 문서화 필요

- [ ] `rootless-setup.md` — Oracle Linux 8.10 rootless 상세 가이드 (포트 포워딩 포함)
- [ ] `docker-24-to-28-rootless.md` — rootful 제거 + rootless 설치 통합 가이드
- [ ] 레지스트리 데이터 마이그레이션 스크립트

---

## 8. 리스크 및 롤백

| 리스크 | 대응 |
|--------|-----|
| Rootless 설정 실패 | Rootful 재설치 후 복구 (기존 daemon.json 있으면 빠름) |
| 포트 포워딩 미작동 | socat 또는 systemd socket unit 수동 설정 |
| 권한 이슈 | subuid/subgid 재할당 + 볼륨 재마운트 |

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | 팀서버 현황 분석. Rootful 유지 vs Rootless 전환 옵션 정리. **추천: Rootless 완전 전환** |
