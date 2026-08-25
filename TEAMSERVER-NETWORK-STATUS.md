# 팀서버 네트워크 상태 분석 (2026-08-18)

**상황**: 팀서버에서 실행한 명령어 결과 분석

---

## 🔴 발견된 문제들

### 1. Docker Hub 접근 불가 ❌

**증상**:
```
Aug 13 09:35:21 dockerd[3679550]: time="2026-08-15T09:35:21.294754480+09:00" level=error 
msg="error getting v2 registry: Get \"https://registry-1.docker.io/v2/\": context deadline exceeded"

Aug 13 09:35:21 dockerd[3679501]: time="2026-08-15T09:35:21.294862856+09:00" level=info 
msg="Attempting next endpoint for pull after error: Get \"https://registry-1.docker.io/v2/\"...
```

**의미**: Docker 이미지를 pull할 때 Docker Hub에 **타임아웃** (시간 초과)로 접근 실패

---

### 2. DNS 오류: nslookup 실패 ❌

**증상**:
```bash
$ nslookup https://get.docker.com/rootless
Server:         8.8.8.8
Address:        8.8.8.8#53

** server can't find https://get.docker.com/rootless: NXDOMAIN
```

**문제점**:
- ❌ **NXDOMAIN** — DNS에서 도메인을 찾을 수 없음
- ⚠️ nslookup에 `https://` 프로토콜 포함 (문법 오류)

**올바른 명령어**:
```bash
nslookup get.docker.com
# 또는
dig get.docker.com
```

---

### 3. Docker 패키지 미설치/미등록 ❌

**증상**:
```bash
$ dnf list | grep docker
pcp-pmda-docker.x86_64
podman-docker.x86_64

(docker-ce 패키지 없음!)
```

**의미**: 
- Docker 저장소가 등록되지 않음 또는 접근 불가
- `docker-ce` 패키지 자체가 시스템에 없음

---

### 4. Docker 데몬은 실행 중 ✅

**현재 상태**:
```
● docker.service - Docker Application Container Engine
     Loaded: loaded (/etc/systemd/system/docker.service; enabled; vendor preset: disabled)
     Active: active (running) since Wed 2025-08-20 14:52:01 KST; 11 months 28 days ago
```

**의미**: 
- ✅ Docker 데몬 자체는 정상 실행 중
- 🔴 하지만 Docker Hub 접근 불가로 이미지 pull 실패

---

## 📊 현재 상황 분석

| 항목 | 상태 | 의미 |
|------|------|------|
| Docker 데몬 | ✅ 실행 중 | rootful docker 설치되어 있음 |
| Docker Hub 접근 | ❌ 실패 (timeout) | 외부 인터넷 차단 또는 느린 속도 |
| Docker 저장소 등록 | ❌ 없음 | docker-ce 패키지 미설치 |
| DNS | ⚠️ nslookup 문법 오류 | 올바른 명령어로 재테스트 필요 |

---

## 🚨 다음 단계: 올바른 확인 필요

### 1️⃣ DNS 재확인 (올바른 문법)

```bash
# 현재 (❌ 잘못된 문법)
nslookup https://get.docker.com/rootless

# 올바른 문법 (✅)
nslookup get.docker.com
# 또는
dig get.docker.com
# 또는 (간단)
ping -c 1 get.docker.com
```

**실행 후 결과 보고**:
```
예) NXDOMAIN (도메인 찾을 수 없음) → ❌
예) Address: 93.184.216.34 (IP 주소 반환됨) → ✅
```

---

### 2️⃣ Docker Hub 접근 재확인

```bash
# Docker Hub 직접 접근 테스트
curl -I https://registry-1.docker.io/v2/
# 또는
curl -I https://registry.hub.docker.com/v2/
```

**예상 결과**:
- ✅ HTTP 200 또는 HTTP 401 (인증 필요) → 접근 가능
- ❌ timeout / 연결 거부 / HTTP 오류 → 차단됨

---

### 3️⃣ 패키지 저장소 확인

```bash
# Docker 저장소 등록 여부
sudo dnf repolist all | grep docker

# 없으면 수동 등록
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# 재확인
sudo dnf makecache
sudo dnf list docker-ce --showduplicates | head
```

---

### 4️⃣ 네트워크 기본 진단

```bash
# 기본 인터넷 통신 확인
ping -c 3 8.8.8.8
ping -c 3 1.1.1.1

# 경로 확인
ip route show

# DNS 서버 확인
cat /etc/resolv.conf
```

---

## 📋 권장 조치

### 현재 상황
```
시나리오 D (완전 또는 부분 차단) 가능성 높음
├─ Docker Hub 접근 불가 (timeout)
├─ Docker 저장소 미등록
└─ 기존 rootful Docker만 설치되어 있음
```

### 해결 방안 (우선순위)

**1순위**: IT팀에 네트워크 확인 요청
```
- Docker Hub (registry.hub.docker.com) 접근 가능 여부
- Docker 저장소 (download.docker.com) 접근 가능 여부
- 외부 인터넷 정책 확인
```

**2순위**: 현재 상태 유지하고 Rootless 설치 진행
```
✅ 현재 rootful Docker가 있으므로
   - Phase 1: 기존 Docker 제거 가능
   - Phase 2: Rootless 설치 시도
   - 필요한 바이너리는 이미 rootful Docker 내부에 포함될 가능성
```

**3순위**: 오프라인 설치 준비
```
- Docker 바이너리 사전 다운로드 필요
- 이미지는 로컬에서 로드
```

---

## ✅ 해야 할 일 (우선순위)

### 지금 (팀서버에서 실행)

```bash
# 1. DNS 재확인 (올바른 문법)
nslookup get.docker.com
dig get.docker.com

# 2. Docker Hub 접근 테스트
curl -I https://registry.hub.docker.com/v2/
curl -I https://registry-1.docker.io/v2/

# 3. 기본 인터넷 확인
ping 8.8.8.8
ping 1.1.1.1

# 4. 패키지 저장소 확인
sudo dnf repolist all | grep docker
sudo dnf makecache
```

### 나중에 (IT팀 협의)

- [ ] Docker Hub 화이트리스트 요청
- [ ] Docker 저장소 접근 가능 여부 확인
- [ ] 프록시 설정 여부 확인
- [ ] 오프라인 설치 지원 가능성 확인

---

## 📊 다음 보고서 작성 요소

다음에 팀서버에서 확인 후 보고할 때 포함할 내용:

```
[ ] 현재 권한: whoami, id
[ ] DNS 정상 작동: nslookup get.docker.com
[ ] 인터넷 통신: ping 8.8.8.8
[ ] 패키지 저장소: sudo dnf repolist | grep docker
[ ] Docker Hub 접근: curl -I https://registry.hub.docker.com/v2/
[ ] 현재 Docker 상태: sudo docker --version
[ ] 기존 이미지/컨테이너: sudo docker images, sudo docker ps -a
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | 팀서버 네트워크 상태 분석. Docker Hub timeout + DNS 오류 + 패키지 미등록 발견 |
