# 팀서버 네트워크/패키지 연결성 사전 확인 (Phase 0)

작성일: 2026-08-18  
목적: Rootless Docker 설치 전 필수 확인  
중요도: ⭐⭐⭐ (설치 실패의 주요 원인)  
**추가**: 권한(root vs 일반 사용자) 명확히 구분

---

## 개요

Rootless Docker 설치 및 레지스트리 운영에 필요한 외부 통신:

1. **dnf 패키지 저장소** — `docker-ce-rootless-extras` 등 설치 시 필요
2. **Docker Hub / Docker 웹서버** — 레지스트리 컨테이너 이미지 pull 시 필요
3. **기타** — 스크립트 다운로드, 플러그인 설치 등

사내 방화벽 정책에 따라 이들이 제한될 수 있으므로, **설치 전에 반드시 확인**해야 합니다.

---

## ⚠️ 권한 구분 (중요!)

**일반 사용자로도 가능한 확인** ✅:
- 네트워크 기본 확인 (ping, nslookup)
- 시스템 정보 (uname, id, cat /proc/...)
- 웹 접근 확인 (curl)

**sudo 권한 필수** 🔴:
- dnf 패키지 관리 (dnf makecache, dnf list)
- Docker 데몬 상태 확인 (systemctl, docker)
- /etc/docker 파일 접근

---

## 🔍 확인 항목 체크리스트

### 0단계: 현재 권한 확인 (가장 먼저!)

```bash
# 현재 사용자 확인
$ whoami
servicetech2

# 또는
$ id
uid=1000(servicetech2) gid=1000(servicetech2) groups=1000(servicetech2)
```

**출력 해석**:
- `servicetech2` (또는 uid=1000) → **일반 사용자** ✅
- `root` (또는 uid=0) → **root 사용자** 🔴

| 항목 | 결과 |
|------|------|
| `whoami` 출력 | _________________ |
| 권한 상태 | ☐ 일반 사용자 ✅ / ☐ root 사용자 🔴 |

---

### 1. 기본 네트워크 연결 확인 ✅ (일반 사용자)

**권한**: 일반 사용자로 실행 가능 (sudo 불필요)

```bash
# 일반 사용자로 실행 ($는 일반 사용자 프롬프트 의미)
$ whoami
servicetech2

# 1-1. DNS 해석 가능 여부
$ nslookup google.com
# 또는
$ dig google.com

# 1-2. 인터넷 통신 가능 여부
$ ping -c 3 8.8.8.8      # Google DNS
$ ping -c 3 1.1.1.1      # Cloudflare DNS

# 1-3. 기본 라우팅 확인
$ ip route show
```

| 항목 | 명령어 | 권한 | 결과 | 통과 |
|------|--------|------|------|------|
| DNS 해석 | nslookup google.com | 일반 ✅ | ____________ | ☐ |
| Ping Google DNS | ping 8.8.8.8 | 일반 ✅ | ✅ 응답 / ❌ 응답 없음 | ☐ |
| Ping Cloudflare DNS | ping 1.1.1.1 | 일반 ✅ | ✅ 응답 / ❌ 응답 없음 | ☐ |

---

### 2. 커널/시스템 정보 확인 ✅ (일반 사용자)

**권한**: 일반 사용자로 실행 가능 (sudo 불필요)

```bash
$ whoami
servicetech2

# 2-1. 커널 버전 확인
$ uname -r
# 예상: 5.15.0-306

# 2-2. OS 정보
$ cat /etc/os-release

# 2-3. User namespace 활성화 확인
$ cat /proc/sys/user/max_user_namespaces
# 예상: 0이 아닌 값 (보통 15000)

# 2-4. 사용자 정보 확인
$ id
$ getent passwd servicetech2
```

| 항목 | 명령어 | 권한 | 결과 | 통과 |
|------|--------|------|------|------|
| 커널 버전 | uname -r | 일반 ✅ | 5.15.0-306 | ☐ |
| OS 이름 | cat /etc/os-release | 일반 ✅ | Oracle Linux 8.10 | ☐ |
| max_user_namespaces | cat /proc/sys/... | 일반 ✅ | 0이 아님 (예: 15000) | ☐ |
| 사용자 ID/GID | id | 일반 ✅ | uid=1000(...) | ☐ |

---

### 3. sudo 권한 확인 ⚠️ (필수!)

**권한**: 일반 사용자에서 sudo 가능 여부 확인

```bash
$ whoami
servicetech2

# sudo 가능 여부 테스트
$ sudo -v
# → 비밀번호 입력 프롬프트 나타남 → OK ✅
# → "not in the sudoers file" 오류 → 불가 ❌

# 비밀번호 없이 sudo 가능한지 확인 (optional)
$ sudo -l
# → NOPASSWD로 시작하는 라인이 있으면 비밀번호 불필요
```

| 항목 | 확인 방법 | 결과 | 통과 |
|------|---------|------|------|
| sudo 비밀번호 | sudo -v | ✅ OK / ❌ 오류 | ☐ |
| sudo 필요 여부 | sudo -l | ⚠️ 필요 / ✅ 불필요 | ☐ |

---

### 4. dnf 패키지 서버 확인 🔴 (sudo 필수)

**권한**: sudo 필수 ⚠️

```bash
$ whoami
servicetech2

# 다음부터는 sudo를 붙여야 함!

# 4-1. dnf 저장소 목록 확인
$ sudo dnf repolist all
# [sudo] password for servicetech2: ← 비밀번호 입력

# 4-2. 패키지 캐시 갱신
$ sudo dnf clean all
$ sudo dnf makecache

# 4-3. Docker 패키지 검색 가능 여부
$ sudo dnf search docker-ce
$ sudo dnf list docker-ce --showduplicates | head -20
```

**예상 결과**:
```
docker-ce-stable                 Docker CE Stable - $basearch         enabled
...

docker-ce.x86_64    24.0.9-1.el8     docker-ce-stable
docker-ce.x86_64    28.0.0-1.el8     docker-ce-stable
docker-ce.x86_64    29.0.0-1.el8     docker-ce-stable
...
```

| 항목 | 명령어 | 권한 | 결과 | 통과 |
|------|--------|------|------|------|
| 저장소 목록 | sudo dnf repolist all | sudo 🔴 | repo 수 ____ | ☐ |
| 캐시 갱신 | sudo dnf makecache | sudo 🔴 | ✅ OK / ❌ 실패 | ☐ |
| docker-ce 검색 | sudo dnf list docker-ce | sudo 🔴 | ____ 버전 | ☐ |

---

### 5. Docker 저장소/Hub 접근 확인 ✅ (일반 사용자)

**권한**: 일반 사용자로 실행 가능 (curl 명령)

```bash
$ whoami
servicetech2

# 이 섹션은 일반 사용자로 실행 가능!

# 5-1. Docker 저장소 접근 테스트
$ curl -s https://download.docker.com/linux/rhel/docker-ce.repo | head -20

# 5-2. GPG 키 다운로드 가능 여부
$ curl -s https://download.docker.com/linux/rhel/gpg | head -5

# 5-3. Docker Hub 접근 테스트
$ curl -I https://registry.hub.docker.com/v2/

# 5-4. 설치 스크립트 다운로드 가능 여부
$ curl -I https://get.docker.com/rootless

# 5-5. 공식 스크립트 테스트 (다운로드만, 실행 X)
$ curl -fsSL https://get.docker.com/rootless > /tmp/test-script.sh
$ wc -l /tmp/test-script.sh
$ rm /tmp/test-script.sh
```

**예상 결과**:
```
[docker-ce-stable]
name=Docker CE Stable - $releasever - $basearch
baseurl=https://download.docker.com/linux/rhel/$releasever/$basearch/stable
...

(또는)

HTTP/1.1 200 OK
```

| 항목 | 명령어 | 권한 | 결과 | 통과 |
|------|--------|------|------|------|
| repo 파일 | curl docker repo | 일반 ✅ | 내용 수신 ✅ / 오류 ❌ | ☐ |
| GPG 키 | curl gpg URL | 일반 ✅ | PGP 헤더 ✅ / 오류 ❌ | ☐ |
| Docker Hub | curl -I hub | 일반 ✅ | HTTP 200 ✅ / HTTP 오류 ❌ | ☐ |
| 설치 스크립트 | curl -I get.docker | 일반 ✅ | HTTP 200 ✅ / HTTP 오류 ❌ | ☐ |

---

### 6. 현재 Docker 상태 확인 🔴 (sudo 필수)

**권한**: sudo 필수 ⚠️

```bash
$ whoami
servicetech2

# 이 섹션부터는 sudo 필요!

# 6-1. 현재 Docker 버전
$ sudo docker --version

# 6-2. 데몬 상태
$ sudo systemctl status docker

# 6-3. 실행 중인 컨테이너
$ sudo docker ps -a

# 6-4. daemon.json 확인
$ sudo cat /etc/docker/daemon.json
# 없으면 "No such file" 정상
```

| 항목 | 명령어 | 권한 | 결과 | 통과 |
|------|--------|------|------|------|
| Docker 버전 | sudo docker --version | sudo 🔴 | 24.0.9 | ☐ |
| 데몬 상태 | sudo systemctl status docker | sudo 🔴 | active / inactive | ☐ |
| 컨테이너 | sudo docker ps -a | sudo 🔴 | 0개 | ☐ |
| daemon.json | sudo cat /etc/docker/daemon.json | sudo 🔴 | 없음 | ☐ |

---

## 📋 Phase 0 최종 체크리스트

**실행 전 준비**:
- [ ] **현재 권한 확인**: `whoami` 결과가 servicetech2 (또는 일반 사용자명) ✅
- [ ] **sudo 비밀번호 준비**: `sudo -v` 테스트 통과 ⚠️

**실행 순서**:

| 단계 | 내용 | 권한 | 소요 시간 |
|------|------|------|----------|
| 1 | 현재 권한 확인 | 일반 ✅ | 1분 |
| 2 | 네트워크 기본 확인 | 일반 ✅ | 2분 |
| 3 | 커널/시스템 정보 | 일반 ✅ | 1분 |
| 4 | sudo 권한 확인 | 일반 ✅ | 1분 |
| 5 | dnf 패키지 서버 | sudo 🔴 | 3분 |
| 6 | Docker Hub 접근 | 일반 ✅ | 2분 |
| 7 | 현재 Docker 상태 | sudo 🔴 | 2분 |
| **총계** | | | **~12분** |

---

## 🚨 문제별 대응 방안

### 시나리오 A: 완전 정상 (모두 ✅)

```
dnf makecache: ✅ OK
curl docker hub: ✅ OK
curl install script: ✅ OK
```

→ **다음**: Phase 1 진행 (정상 경로)

---

### 시나리오 B: dnf OK, Docker Hub 차단

```
dnf makecache: ✅ OK
curl docker hub: ❌ 실패 (HTTP 403/404 등)
```

→ **대응**: 이미지 사전 다운로드 필요
```bash
# 인터넷 가능한 다른 서버에서 (또는 Windows PC)
docker pull registry:2
docker save registry:2 > registry-2.tar

# 팀서버로 전달 후
docker load < registry-2.tar
```

---

### 시나리오 C: HTTPS 차단 (HTTP 가능)

```
curl https://...: ❌ 연결 거부 / timeout
curl http://...: ✅ OK
```

→ **대응**: HTTP 미러 또는 프록시 설정
```bash
# dnf에 프록시 설정
$ sudo echo "proxy=http://proxy.company.com:8080" >> /etc/dnf/dnf.conf

# 또는 curl에 프록시
$ export http_proxy=http://proxy.company.com:8080
$ export https_proxy=http://proxy.company.com:8080
```

---

### 시나리오 D: 완전 오프라인 (모두 ❌)

```
dnf makecache: ❌ 실패
curl 모두: ❌ 실패
```

→ **대응**: IT팀 상담 필수
- 오프라인 바이너리 제공 필요
- 또는 VPN/방화벽 정책 변경 필요

---

## 📝 최종 기록

**실행 날짜**: __________  
**실행 권한**: ☐ 일반 사용자 (servicetech2) / ☐ root  
**소요 시간**: __________ 분  

### 네트워크 상태
```
[ ] 완전 정상 (모든 통신 OK)
[ ] 부분 차단 (dnf OK, Docker Hub 차단)
[ ] HTTPS 차단 (HTTP 가능)
[ ] 완전 오프라인 (모두 차단)
```

### 다음 설치 경로
```
[ ] 정상 경로: Phase 1 진행
[ ] 대체 경로: 이미지 사전 다운로드 후 Phase 2 진행
[ ] 프록시 설정 필요: HTTP 미러 설정 후 진행
[ ] IT팀 상담: 오프라인 설치 절차 대기
```

### 추가 메모
```
_____________________________________
_____________________________________
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 v2 | **권한 구분 강화**: 일반 사용자 vs sudo 명확히 표시, 0단계에서 권한 확인 추가 |
