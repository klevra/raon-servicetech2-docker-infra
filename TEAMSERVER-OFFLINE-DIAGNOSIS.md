# 팀서버 오프라인 진단 결과 (2026-08-18)

**결론**: 🔴 **완전 오프라인 환경 확정**

---

## 📊 진단 결과 분석

### 1️⃣ DNS ✅ (작동함)
```bash
$ nslookup get.docker.com
Server: 8.8.8.8
Address: 8.8.8.8#53

get.docker.com canonical name = d3cxuo8f8w64ms.cloudfront.net
Address: 54.230.62.75
Address: 54.230.62.43
Address: 54.230.62.50
Address: 54.230.62.125
```

**의미**: DNS는 정상 작동 ✅ (로컬/캐시된 DNS 또는 내부 DNS)

---

### 2️⃣ 외부 인터넷 통신 ❌ (100% 차단)

```bash
$ ping -c 3 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
3 packets transmitted, 0 received, 100% packet loss, time 2062ms

$ ping -c 3 1.1.1.1
PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
3 packets transmitted, 0 received, 100% packet loss, time 2078ms
```

**의미**: 
- Google DNS 및 Cloudflare DNS 모두 **완전 차단**
- 외부 인터넷 통신 **불가능** ❌

---

### 3️⃣ Docker Hub 접근 ❌ (응답 없음)

```bash
$ curl -i https://registry.hub.docker.com/v2/
(응답 없음 / timeout)

$ curl -i https://registry-1.docker.io/v2/
(응답 없음 / timeout)
```

**의미**: Docker Hub **접근 불가** ❌

---

### 4️⃣ Docker 패키지 저장소 ❌ (미등록)

```bash
$ sudo dnf repolist all | grep docker
(docker 관련 저장소 없음)
```

**의미**: Docker 저장소 **미등록 또는 접근 불가** ❌

---

## 🔴 확정: 시나리오 D (완전 오프라인)

| 항목 | 상태 | 의미 |
|------|------|------|
| DNS | ✅ 작동 | 내부 DNS만 사용 가능 |
| 외부 인터넷 | ❌ 차단 | 8.8.8.8, 1.1.1.1 모두 100% loss |
| Docker Hub | ❌ 접근 불가 | 방화벽 완전 차단 |
| Docker 저장소 | ❌ 미등록 | dnf로 docker-ce 설치 불가능 |
| 기존 Docker | ✅ 설치됨 | rootful Docker는 이미 설치 |

---

## 🚨 현재 상황 요약

```
팀서버 네트워크 정책
├─ 외부 인터넷: 완전 차단 (Google/Cloudflare DNS도 ping 100% loss)
├─ Docker Hub: 접근 불가
├─ Docker 저장소: 접근 불가
├─ 기존 rootful Docker: 설치됨 ✅
└─ 내부 DNS: 작동 (로컬 해석만 가능)

= 완전 오프라인 환경
```

---

## 📋 가능한 설치 방법 (우선순위)

### 옵션 A: 오프라인 + 기존 Docker 활용 ✅ (권장)

**상황**: 기존 rootful Docker가 있으므로 일부 기능 재사용 가능

1. **Phase 1**: 기존 rootful Docker 제거
   ```bash
   sudo systemctl stop docker
   sudo dnf remove -y docker-ce docker-ce-cli
   ```
   ✅ 가능 (이미 설치되어 있음)

2. **Phase 2**: Rootless Docker 설치
   ```bash
   # Option A-1: 기존 Docker 바이너리 재활용
   # 기존 rootful Docker의 바이너리를 rootless 버전으로 변환 (복잡)
   
   # Option A-2: 수동 바이너리 설치 (권장)
   # get.docker.com/rootless 스크립트를 다른 환경에서 실행해 바이너리 얻기
   ```

---

### 옵션 B: IT팀 지원 + 오프라인 설치

**필요한 것**:
1. Docker 바이너리 (컴파일된 파일)
   - containerd
   - docker-ce
   - docker-ce-cli
   - docker-buildx-plugin
   - docker-compose-plugin

2. 레지스트리 이미지
   - registry:2 (docker image tar 파일)

3. 전달 방법
   - USB/외장 드라이브
   - 내부 파일 서버
   - git/svn

---

## 💡 권장 조치 (단계별)

### 1단계: IT팀에 요청

**요청 사항**:
```
1. 현재 네트워크 정책 확인
   - 외부 인터넷 정책 (완전 차단인지 일부 서버만 차단인지)
   - Docker Hub 특별 허용 가능 여부
   - 프록시/미러 서버 있는지

2. 오프라인 설치 지원
   - Docker 바이너리 제공 가능 여부
   - 레지스트리 이미지 제공 가능 여부
   - 파일 전달 방법 (USB/네트워크 드라이브 등)
```

---

### 2단계: 임시 방안 (기존 Docker 활용)

**현재 상태 유지**:
```bash
# 기존 rootful Docker 계속 사용 가능
sudo docker --version
sudo docker info

# 유의: Docker Hub에서 이미지를 pull할 수 없으므로
#      로컬 이미지만 사용 가능
```

**로컬 이미지 작업**:
```bash
# 현재 있는 이미지 확인
sudo docker images

# 혹시 로컬에 레지스트리 이미지가 있다면
sudo docker run -d -p 5000:5000 \
  --name servicetech2-registry \
  --restart=always \
  [registry 이미지 ID 또는 이름]
```

---

### 3단계: Rootless 설치 (IT팀 지원 후)

**IT팀에서 바이너리 받은 후**:
```bash
# 1. Rootful 제거
sudo systemctl stop docker
sudo dnf remove -y docker-ce docker-ce-cli containerd.io

# 2. 다운로드받은 바이너리 설치
# (구체적인 절차는 바이너리 패키징 방식에 따라 다름)
```

---

## 📞 IT팀에 보낼 이메일 초안

```
제목: 팀서버 Docker Rootless 설치를 위한 오프라인 환경 지원 요청

본문:

현재 팀서버(Oracle Linux 8.10)에서 Docker를 rootful에서 rootless로 
전환하려고 합니다.

다음과 같이 네트워크 정책이 확인되었습니다:

1. 외부 인터넷: 완전 차단 (Google DNS/Cloudflare DNS ping 100% loss)
2. Docker Hub: 접근 불가
3. Docker 저장소: 접근 불가
4. 내부 DNS: 작동

따라서 오프라인 설치가 필요합니다. 다음을 지원해주실 수 있는지 
확인 부탁드립니다:

[ ] 1. 외부 인터넷 정책 상세 설명
[ ] 2. Docker Hub 특별 허용 가능 여부
[ ] 3. 프록시/미러 서버 존재 여부 (있으면 설정 제공)
[ ] 4. 오프라인 바이너리 설치 지원 가능 여부

(필요한 바이너리 목록 포함)

감사합니다.
```

---

## ⚠️ 현재 추천 조치

### 즉시 (지금)
1. ✅ IT팀에 위 메일 발송
2. ✅ 기존 rootful Docker는 계속 사용 가능 (제거 금지)
3. ✅ Phase 0 확인 완료 (오프라인 확정)

### 대기 중
1. ⏳ IT팀 응답 기다리기
2. ⏳ 필요시 특별 허용 또는 바이너리 지원

### 불가능
1. ❌ Phase 1~6 현재 진행 불가능 (패키지 설치 불가)
2. ❌ docker pull hello-world (이미지 다운로드 불가)
3. ❌ dnf install docker-ce (패키지 설치 불가)

---

## 📋 다음 옵션별 진행 방법

### 만약 IT팀이 "프록시 설정 가능"이라면
→ [docker-proxy-setup.md](docker-proxy-setup.md) 생성 필요

### 만약 IT팀이 "부분 화이트리스트 가능"이라면
→ 최소 필요 도메인만 화이트리스트 요청
```
docker-ce.repo: download.docker.com
registry:2 미리 pull: registry.hub.docker.com
```

### 만약 IT팀이 "바이너리 제공 가능"이라면
→ [docker-offline-installation.md](docker-offline-installation.md) 작성 필요

### 만약 "변경 불가능"이라면
→ 기존 rootful Docker 유지 운영

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | 팀서버 오프라인 진단 확정. DNS만 작동, 외부 인터넷 100% 차단. IT팀 지원 필요 |
