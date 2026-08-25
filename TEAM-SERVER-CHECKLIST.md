# 팀서버 Docker 업그레이드 사전 확인 체크리스트

**작성일**: 2026-08-18  
**대상**: 팀서버 (Oracle Linux 8.10, Kernel 5.15.0-306)  
**현황**: Docker 24.0.9 (rootful) → Rootless + 버전 업그레이드

---

## ⚠️ **Phase 0: 네트워크/패키지 연결성 확인 (필수, 가장 먼저 실행)**

**이 단계를 완료하지 않고 진행하면 설치 실패 가능성 높습니다!**

**📌 중요: 권한 구분**
- ✅ **일반 사용자 권한**으로 가능한 확인: 네트워크(ping, curl), 시스템 정보(uname, id)
- 🔴 **sudo 권한 필수**: dnf 패키지 관리, Docker 데몬 상태 확인

👉 **[TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md) 문서를 먼저 참고하고, 아래 항목들을 확인하세요.**

### 0단계: 현재 권한 확인 (이것부터!)

```bash
$ whoami
# 출력: servicetech2 (또는 다른 사용자명)

$ id
# 출력: uid=1000(servicetech2) gid=1000(servicetech2)...
```

**권한 상태** | 결과
---|---
일반 사용자? | ☐ 예 (servicetech2 등) / ☐ 아니오 (root)
sudo 가능? | ☐ 예 (sudo -v 후 비밀번호 입력 가능) / ☐ 아니오 (오류)


```bash
# 1. 기본 네트워크 확인
nslookup google.com
ping -c 3 8.8.8.8
ip route show

# 2. dnf 패키지 서버 확인
dnf clean all
dnf makecache
dnf list docker-ce --showduplicates | head -5

# 3. Docker 저장소 확인
curl -s https://download.docker.com/linux/rhel/docker-ce.repo | head -5

# 4. Docker Hub 접근 확인
curl -I https://registry.hub.docker.com/v2/

# 5. 설치 스크립트 다운로드 가능 여부
curl -I https://get.docker.com/rootless
```

| 항목 | 상태 | 결과 |
|------|------|------|
| DNS / 기본 네트워크 | ☐ OK / ☐ 실패 | ________________ |
| dnf 패키지 서버 | ☐ OK / ☐ 실패 | ________________ |
| Docker 저장소 | ☐ OK / ☐ 실패 | ________________ |
| Docker Hub | ☐ OK / ☐ 실패 | ________________ |
| 공식 스크립트 | ☐ OK / ☐ 실패 | ________________ |

**결과 해석**:
- 모두 OK → 아래 Phase 1 진행 (정상 경로)
- 일부 실패 → [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md)의 "문제별 대응" 섹션 참고
- 모두 실패 → IT팀 네트워크 점검 필요

**권장 설치 경로**:
```
[ ] 정상 경로 (모든 통신 가능) → Phase 1 진행
[ ] 대체 경로 (dnf OK, Docker Hub 차단) → [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md)의 "대체 경로" 참고
[ ] 오프라인 경로 (완전 차단) → IT팀 상담 필수
```

---

## ✅ 수집된 정보 (재확인)

팀서버에서 실행하고 결과를 이 리스트에 기록하세요.

**⚠️ Phase 0 완료 후 진행하세요.**

### 시스템 정보

```bash
# 명령어 실행
cat /etc/os-release
cat /etc/system-release
uname -r
```

| 항목 | 확인됨 | 비고 |
|------|--------|------|
| OS 이름 | Oracle Linux Server 8.10 | ✅ |
| OS ID_LIKE | fedora | ✅ |
| 커널 버전 | 5.15.0-306 | ✅ |
| 커널 user namespace | - | 아래 "커널 설정" 섹션에서 |

---

### 현재 Docker 상태

```bash
# 명령어 실행
docker --version
which docker
rpm -qa | grep docker-ce
dpkg -l | grep docker 2>/dev/null || echo "(dpkg 없음, rpm 결과 위 참고)"
ls -la /etc/docker/daemon.json 2>/dev/null || echo "(daemon.json 없음)"
sudo docker ps -a
sudo systemctl status docker
```

| 항목 | 현재값 | 확인 |
|------|--------|------|
| Docker 버전 | 24.0.9, build 2936816 | ✅ |
| 설치 방식 | dnf 패키지 | ✅ |
| 바이너리 경로 | /usr/bin/docker | ✅ |
| daemon.json | 없음 | ✅ |
| 실행 중인 컨테이너 | 없음 | ✅ |
| 데몬 상태 | 실행 중 (rootful) | ✅ |

---

## 🔧 Phase 1 전 필수 커널 설정 확인

**팀서버**에서 실행하세요. 모두 "OK" 또는 0이 아닌 값이어야 합니다.

```bash
# 1. User namespace 활성화 확인
cat /proc/sys/user/max_user_namespaces

# 2. subuid/subgid 확인 (servicetech2 사용자)
getent passwd servicetech2
cat /etc/subuid | grep servicetech2
cat /etc/subgid | grep servicetech2

# 3. cgroup v2 확인 (optional, systemd 통합 시만 필요)
mount | grep cgroup2

# 4. SELinux 상태 확인 (optional, rootless와 충돌 가능)
getenforce
```

| 항목 | 확인 결과 | 상태 |
|------|---------|------|
| `max_user_namespaces` | ___ | ☐ 0이 아님 |
| servicetech2 존재 | ___ | ☐ uid/gid 확인됨 |
| subuid:servicetech2 | ___ | ☐ 100000:65536 형태 |
| subgid:servicetech2 | ___ | ☐ 100000:65536 형태 |
| SELinux | ___ | ☐ Enforcing (문제 시 나중에 disabled 가능) |

---

## 📋 Phase 1 실행 체크

**팀서버에서 [registry-server/docker-rootless-setup-oracle8.md](registry-server/docker-rootless-setup-oracle8.md)의 "Phase 1: Rootful Docker 제거"를 따라 실행**

```bash
# 명령어 실행
sudo systemctl stop docker
sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
docker --version 2>&1
```

| 단계 | 작업 | 완료 |
|------|------|------|
| 1-1 | Docker 서비스 중지 | ☐ |
| 1-2 | 패키지 제거 (dnf remove) | ☐ |
| 1-3 | 설정 백업 | ☐ |
| 1-4 | `docker: command not found` 확인 | ☐ |

**예상 결과**: `docker: command not found`

---

## 📋 Phase 2 실행 체크

**[registry-server/docker-rootless-setup-oracle8.md](registry-server/docker-rootless-setup-oracle8.md)의 "Phase 2: Rootless Docker 설치" 진행**

### 2-1. subuid/subgid 재확인

```bash
grep servicetech2 /etc/subuid /etc/subgid
```

| 항목 | 명령 결과 | 상태 |
|------|---------|------|
| /etc/subuid | servicetech2:100000:65536 | ☐ |
| /etc/subgid | servicetech2:100000:65536 | ☐ |

### 2-2. 커널 설정 확인 및 수정

```bash
# 현재 값 확인
cat /proc/sys/user/max_user_namespaces

# 만약 0이면:
sudo sysctl user.max_user_namespaces=15000
cat /proc/sys/user/max_user_namespaces  # 재확인
```

| 항목 | 값 | 상태 |
|------|-----|------|
| max_user_namespaces | ____ (0이 아님) | ☐ |

### 2-3. Rootless 설치

```bash
# 방법 A (권장): 공식 스크립트
curl -fsSL https://get.docker.com/rootless | sh

# 또는 방법 B: 수동 설치
sudo dnf install -y docker-ce-rootless-extras
dockerd-rootless-setuptool.sh install
```

| 단계 | 명령어 | 완료 | 출력 내용 |
|------|--------|------|---------|
| 2-3-A | curl rootless script | ☐ | ________________ |
| 또는 2-3-B | dnf + setuptool | ☐ | ________________ |

### 2-4. systemd --user 통합

```bash
# 사용자 systemd 시작
systemctl --user start docker
systemctl --user enable docker

# 상태 확인
systemctl --user status docker
```

| 단계 | 명령어 | 완료 | 상태 |
|------|--------|------|------|
| 2-4-1 | start | ☐ | Active ☐ |
| 2-4-2 | enable | ☐ | Enabled ☐ |
| 2-4-3 | status | ☐ | running ☐ |

---

## 📋 Phase 3: Rootless 검증

```bash
# 1. 버전 확인
docker version

# 2. 정보 확인
docker info | grep -i "rootless\|server"

# 3. hello-world 테스트 (sudo 불필요!)
docker run --rm hello-world

# 4. 소켓 위치 확인
echo $DOCKER_HOST
ls -la ~/.docker/run/docker.sock
```

| 항목 | 예상 결과 | 실제 결과 | 완료 |
|------|---------|----------|------|
| `docker version` | 24.x 이상 출력 | __________ | ☐ |
| `docker info \| grep rootless` | rootless 명시 | __________ | ☐ |
| `hello-world` 실행 | "Hello from Docker!" | __________ | ☐ |
| DOCKER_HOST | ~/.docker/run/docker.sock | __________ | ☐ |
| docker.sock 권한 | -rw------- servicetech2 | __________ | ☐ |

---

## 📋 Phase 4: 레지스트리 재구성

```bash
# 1. 데이터 디렉토리 생성
mkdir -p ~/.docker/volumes/servicetech2-registry/data
ls -la ~/.docker/volumes/servicetech2-registry/

# 2. 레지스트리 컨테이너 기동
docker run -d \
  --name servicetech2-registry \
  --restart=always \
  -p 5000:5000 \
  -v ~/.docker/volumes/servicetech2-registry/data:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# 3. 상태 확인
docker ps
curl -s http://localhost:5000/v2/ | head

# 4. 카탈로그 확인
curl -s http://localhost:5000/v2/_catalog
```

| 단계 | 명령어 | 완료 | 결과 |
|------|--------|------|------|
| 4-1 | mkdir data | ☐ | 디렉토리 생성 ✅ |
| 4-2 | docker run registry | ☐ | 컨테이너 ID 출력 ✅ |
| 4-3 | docker ps | ☐ | servicetech2-registry (Up) ☐ |
| 4-3 | curl /v2/ | ☐ | {} 또는 빈 응답 ☐ |
| 4-4 | curl /_catalog | ☐ | {"repositories":[]} ☐ |

---

## 📋 Phase 5 (Optional): Docker 버전 업그레이드

**현재 24.0.9에서 28 또는 29로 업그레이드하려면**: [registry-server/docker-upgrade-24-to-28.md](registry-server/docker-upgrade-24-to-28.md) 참고

```bash
# 1. 가능한 버전 확인
sudo dnf list docker-ce --showduplicates | grep '28\.\|29\.'

# 2. 선택한 버전으로 업그레이드 (예: 28.x)
sudo dnf install -y docker-ce-<버전> docker-ce-cli-<버전>

# 3. systemd --user 재시작
systemctl --user restart docker

# 4. 버전 확인
docker --version
```

| 항목 | 현재 | 업그레이드 후 | 완료 |
|------|------|--------------|------|
| Docker 버전 | 24.0.9 | ____________ | ☐ |
| 레지스트리 정상 여부 | - | curl /v2/ OK ☐ | ☐ |

---

## 📋 최종 검증

모든 Phase 완료 후 실행:

```bash
# 1. 부팅 후 자동 시작 여부 테스트 (optional)
# → 로그아웃/재로그인 후 docker ps 동작 확인

# 2. 이미지 push/pull 테스트
docker pull alpine
docker tag alpine localhost:5000/servicetech2/alpine:latest
docker push localhost:5000/servicetech2/alpine:latest
docker rmi localhost:5000/servicetech2/alpine:latest
docker pull localhost:5000/servicetech2/alpine:latest

# 3. 카탈로그 확인
curl -s http://localhost:5000/v2/_catalog
```

| 항목 | 완료 | 결과 |
|------|------|------|
| 부팅 후 자동 시작 (선택) | ☐ | docker ps 동작 ☐ |
| alpine push | ☐ | 성공 ☐ |
| alpine pull (재) | ☐ | 성공 ☐ |
| /_catalog 확인 | ☐ | alpine 목록에 나타남 ☐ |

---

## 🚨 문제 발생 시

| 증상 | 원인 | 해결 |
|------|------|------|
| `docker: command not found` (Phase 3에서) | PATH 미설정 | `export PATH=$PATH:~/.local/bin` |
| `permission denied docker.sock` | 권한 이슈 | `systemctl --user restart docker` |
| 레지스트리 5000 포트 충돌 | 기존 rootful 데몬 실행 중 | `sudo systemctl status docker` 확인 후 중지 |
| curl: (7) Failed to connect | 레지스트리 미시작 | `docker ps \| grep registry` 확인 |

---

## 📝 기록

**실행 날짜**: __________  
**실행자**: __________  
**소요 시간**: __________  
**문제 발생 여부**: ☐ 없음 / ☐ 있음 (아래 기록)  

### 문제 기록
```
[필요시 여기에 발생한 문제와 해결 과정 기록]
```

### 추가 메모
```
[기타 확인사항 기록]
```

---

## 다음 단계

- [ ] 팀서버에서 Phase 1~6 완료
- [ ] 레지스트리 정상 작동 확인
- [ ] 사무실 PC에서 `docker pull servicetech2-registry:5000/...` 테스트
- [ ] 필요시 Oracle 이미지 빌드 및 push 테스트
- [ ] Phase 5 (버전 업그레이드) 검토 후 실행 여부 결정

**상태**: 체크리스트 작성 완료. 팀서버에서 단계별 실행 후 이 문서에 결과 기록해주세요.
