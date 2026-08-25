# 🎯 팀서버 Docker Rootless 배포 최종 실행 계획

**작성일**: 2026-08-18  
**상황**: 팀서버 오프라인 + 외부 VM 인터넷 가능  
**전략**: 2단계 오프라인 배포 (외부 준비 → 팀서버 설치)  
**승인**: ✅ 팀장 승인 완료

---

## 🎯 실행 흐름 (전체)

```
[외부 VM 서버] (인터넷 가능)
    ↓ Phase A (1~2시간)
    ├─ A-1: 환경 확인 (Oracle Linux 8.10)
    ├─ A-2: Rootless Docker 설치
    ├─ A-3: 필요한 파일 패키징
    │       └─ docker-offline-package.tar.gz (~100MB)
    │           ├─ ~/.local/bin/* (바이너리)
    │           ├─ registry-2.tar (이미지)
    │           └─ ...
    ↓ Phase B (5~10분)
    [파일 전달] (USB/SCP/드라이브)
    ↓
[팀서버] (오프라인)
    ↓ Phase C (20~30분)
    ├─ C-1: 기존 rootful Docker 제거
    ├─ C-2: Rootless 바이너리 수동 설치
    └─ C-3: 레지스트리 이미지 로드
    ↓ Phase D (10~15분)
    └─ D-1: 레지스트리 컨테이너 구성
    ↓
    ✅ 완료!
```

---

## 📋 Phase별 상세 절차

### 🟦 Phase A: 외부 VM에서 준비 (1~2시간)

**위치**: 외부 VM (Oracle Linux 8.10, 인터넷 가능)  
**권한**: 일반 사용자 (sudo 필요)  
**산출물**: docker-offline-package.tar.gz

#### A-1. 환경 확인 (5분)

```bash
# 외부 VM에서 실행
$ whoami
user

$ uname -r
5.15.0-306  # 또는 유사 버전

$ cat /etc/os-release
NAME="Oracle Linux Server"
VERSION="8.10"

$ dnf --version
dnf version 4.x.x
```

#### A-1. 시스템 요구사항 설치 - iptables 모듈 로드 (5분)

```bash
# 외부 VM에서 실행 (sudo 필요)

# 1️⃣ iptables 모듈 로드 (bridge 모드/포트 바인딩 필수!)
cat <<EOF | sudo sh -x
modprobe iptables_filter
modprobe ip_tables
modprobe iptables_nat
modprobe nf_nat
modprobe nf_conntrack
EOF

# 2️⃣ 로드 확인
$ lsmod | grep iptables
# 예상: iptables_filter 나타나야 함
```

#### A-2. Rootless Docker 설치 (10분)

```bash
# 이제 시스템 요구사항이 준비되었으므로 정상 설치

$ curl -fsSL https://get.docker.com/rootless | bash

# 검증
$ ~/.local/bin/docker --version
# Docker version 28.x.x (또는 24.x.x)

# 데몬 시작
$ systemctl --user start docker
$ systemctl --user status docker
# Expected: Active (running)
```

#### A-3. 레지스트리 이미지 다운로드 (10분)

```bash
# 1️⃣ 이미지 다운로드
$ docker pull registry:2
# Pulling from library/registry
# Digest: sha256:...

# 2️⃣ 확인
$ docker images
# REPOSITORY   TAG    IMAGE ID      CREATED       SIZE
# registry     2      [image-id]    ...           ~100MB
```

#### A-4. 파일 패키징 (15분)

```bash
# 1️⃣ 디렉터리 준비
$ mkdir -p ~/docker-offline-package/bin
$ mkdir -p ~/docker-offline-package/systemd

# 2️⃣ 바이너리 복사
$ cp ~/.local/bin/docker* ~/docker-offline-package/bin/
$ cp ~/.local/bin/containerd* ~/docker-offline-package/bin/
$ cp ~/.local/bin/ctr ~/docker-offline-package/bin/

# 3️⃣ systemd 설정 복사
$ find ~/.local/lib/systemd/user/docker* -type f | \
  xargs -I {} cp {} ~/docker-offline-package/systemd/

# 4️⃣ 레지스트리 이미지 다운로드
$ docker pull registry:2
$ docker save registry:2 -o ~/docker-offline-package/registry-2.tar

# (선택) 기타 이미지
$ docker pull alpine
$ docker save alpine -o ~/docker-offline-package/alpine.tar

# 5️⃣ 최종 패키징
$ cd ~
$ tar czf docker-offline-package.tar.gz docker-offline-package/
$ ls -lh docker-offline-package.tar.gz
# → docker-offline-package.tar.gz 100M ...

# 6️⃣ 체크섬 생성 (검증용)
$ sha256sum docker-offline-package.tar.gz > docker-offline-package.sha256
```

**생성 파일**:
```
~/docker-offline-package.tar.gz    (메인 패키지)
~/docker-offline-package.sha256    (검증 파일)
```

---

### 🟩 Phase B: 파일 전달 (5~10분)

**방법 선택** (3가지):

#### B-1. USB 드라이브 (권장)
```bash
# 외부 VM에서
$ cp ~/docker-offline-package.tar.gz /media/usb/

# 팀서버에서
$ cp /media/usb/docker-offline-package.tar.gz ~/
```

#### B-2. SCP (네트워크 가능한 경우)
```bash
# 외부 VM에서
$ scp ~/docker-offline-package.tar.gz servicetech2@팀서버IP:~/

# 팀서버에서 (수신 확인)
$ ls -lh ~/docker-offline-package.tar.gz
```

#### B-3. 간단한 HTTP 서버
```bash
# 외부 VM에서
$ cd ~ && python3 -m http.server 8000
# Serving HTTP on 0.0.0.0 port 8000...

# 팀서버에서 (같은 네트워크라면)
$ wget http://외부VM_IP:8000/docker-offline-package.tar.gz
```

---

### 🟪 Phase C: 팀서버 설치 (20~30분)

**위치**: 팀서버 (new-servicetech2-1)  
**권한**: servicetech2 사용자 (sudo 필요)  
**전제**: docker-offline-package.tar.gz 받음

#### C-0. 준비 (5분)

```bash
# 팀서버에서 실행

# 1️⃣ 현재 상태 확인
$ whoami
servicetech2

$ sudo docker ps -a
# → 컨테이너 목록 (제거할 것 확인)

$ sudo docker images
# → 이미지 목록 (불필요한 것 제거)

# 2️⃣ 디스크 공간 확인
$ df -h /home
# → 1GB 이상 필요

# 3️⃣ 파일 확인
$ ls -lh ~/docker-offline-package.tar.gz
# → 100MB 정도
```

#### C-1. 기존 Docker 제거 (10분)

```bash
# 1️⃣ 불필요한 이미지 제거 (선택)
$ sudo docker rmi [image-id]  # 각각 실행

# 2️⃣ 데몬 중지
$ sudo systemctl stop docker
$ sudo systemctl disable docker

# 3️⃣ 패키지 제거
$ sudo dnf remove -y docker-ce docker-ce-cli \
  containerd.io docker-buildx-plugin docker-compose-plugin

# 4️⃣ 검증
$ docker --version 2>&1
# → docker: command not found ✅
```

#### C-2. 파일 준비 및 Rootless 설치 (10분)

```bash
# 1️⃣ 패키지 전개
$ mkdir -p ~/docker-prep
$ cd ~/docker-prep
$ tar xzf ~/docker-offline-package.tar.gz
$ ls -la docker-offline-package/

# 2️⃣ 바이너리 설치
$ mkdir -p ~/.local/bin
$ cp docker-offline-package/bin/* ~/.local/bin/
$ chmod +x ~/.local/bin/docker*
$ chmod +x ~/.local/bin/containerd*

# 3️⃣ PATH 추가
$ echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
$ source ~/.bashrc

# 4️⃣ systemd 설정 설치
$ mkdir -p ~/.local/lib/systemd/user
$ cp docker-offline-package/systemd/* ~/.local/lib/systemd/user/

# 5️⃣ 검증
$ docker --version
# → Docker version 28.x.x (또는 24.x.x)

$ systemctl --user daemon-reload
```

#### C-3. 레지스트리 이미지 로드 (5분)

```bash
# 1️⃣ Rootless 데몬 시작
$ systemctl --user start docker
$ systemctl --user enable docker

# 2️⃣ 상태 확인
$ systemctl --user status docker
# → Active (running) ✅

# 3️⃣ 이미지 로드
$ docker load < docker-offline-package/registry-2.tar
# → Loaded image: registry:2

# 4️⃣ 확인
$ docker images
# → registry  2     [image-id]
```

---

### 🟨 Phase D: 레지스트리 구성 (10~15분)

**위치**: 팀서버  
**작업**: Docker 레지스트리 컨테이너 실행

#### D-1. 데이터 디렉터리 준비 (5분)

```bash
# 팀서버에서 실행

$ mkdir -p ~/.docker/volumes/servicetech2-registry/data
$ chmod 755 ~/.docker/volumes/servicetech2-registry/data

# 확인
$ ls -la ~/.docker/volumes/servicetech2-registry/
```

#### D-2. 레지스트리 컨테이너 실행 (5분)

```bash
# 팀서버에서 실행

$ docker run -d \
  --name servicetech2-registry \
  --restart=always \
  -p 5000:5000 \
  -v ~/.docker/volumes/servicetech2-registry/data:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# 상태 확인
$ docker ps
# → servicetech2-registry  Up (healthy) ✅

# API 확인
$ curl http://localhost:5000/v2/
# → {} (또는 빈 응답) ✅
```

#### D-3. 최종 검증 (5분)

```bash
# 로컬 이미지 테스트 (선택)
$ docker tag alpine localhost:5000/servicetech2/alpine:latest
$ docker push localhost:5000/servicetech2/alpine:latest
$ curl http://localhost:5000/v2/_catalog
# → {"repositories":["servicetech2/alpine"]}
```

---

## ⏱️ 소요 시간 요약

| Phase | 작업 | 시간 |
|-------|------|------|
| A-1 | 환경 확인 | 5분 |
| A-2 | Rootless 설치 | 10분 |
| A-3 | 파일 패키징 | 15분 |
| **A 합계** | **외부 VM** | **30분** |
| B | 파일 전달 | 5~10분 |
| C-0 | 팀서버 준비 | 5분 |
| C-1 | 기존 Docker 제거 | 10분 |
| C-2 | Rootless 설치 | 10분 |
| C-3 | 이미지 로드 | 5분 |
| D-1 | 레지스트리 준비 | 5분 |
| D-2 | 레지스트리 실행 | 5분 |
| D-3 | 최종 검증 | 5분 |
| **C+D 합계** | **팀서버** | **45분** |
| **전체** | | **~85분** |

---

## ✅ 최종 체크리스트

### Phase A (외부 VM)
- [ ] 외부 VM 접근 가능
- [ ] Oracle Linux 8.10 확인
- [ ] Rootless Docker 설치 성공
- [ ] 바이너리 복사 완료
- [ ] registry:2 이미지 다운로드 완료
- [ ] docker-offline-package.tar.gz 생성 (100MB)
- [ ] sha256 체크섬 생성

### Phase B (파일 전달)
- [ ] 전달 방법 결정 (USB/SCP/HTTP)
- [ ] 파일 복사 완료
- [ ] 팀서버에서 파일 수신 확인

### Phase C (팀서버)
- [ ] 권한 확인 (servicetech2)
- [ ] 디스크 공간 확인 (1GB+)
- [ ] 불필요한 이미지 제거 (필요시)
- [ ] 기존 Docker 완전 제거
- [ ] 바이너리 설치 완료
- [ ] docker --version 성공
- [ ] registry:2 이미지 로드 완료

### Phase D (팀서버)
- [ ] 레지스트리 데이터 디렉터리 생성
- [ ] 레지스트리 컨테이너 실행 (healthy)
- [ ] curl http://localhost:5000/v2/ 성공
- [ ] 로컬 이미지 테스트 성공 (선택)

---

## 🚨 주의사항

### 필수
- ✅ Phase A는 **외부 VM에서만** 실행
- ✅ Phase C-1 (Docker 제거) 전에 **반드시 백업** (또는 이미지 제거)
- ✅ 팀서버는 **servicetech2 사용자**로 작업
- ✅ Rootless 설치 중 **root 계정 금지**

### 금지
- ❌ 팀서버에서 curl/wget으로 인터넷 접근 시도
- ❌ 기존 Docker 바이너리 재사용 (항상 새로 설치)
- ❌ Phase 중간에 systemctl stop/restart 금지 (완료할 때까지)

### 롤백 (문제 발생 시)
```bash
# 팀서버에서
$ systemctl --user stop docker
$ systemctl --user disable docker
$ rm -rf ~/.local/bin/docker*
$ rm -rf ~/.local/lib/systemd/user/docker*

# 기존 Docker 재설치 (불가능 - 오프라인이므로 주의 필요)
```

---

## 📚 참고 문서

- [OFFLINE-DEPLOYMENT-PLAN.md](OFFLINE-DEPLOYMENT-PLAN.md) — 상세 절차
- [WORKLOG.md](WORKLOG.md) — 전체 진행 상황
- [TEAMSERVER-OFFLINE-DIAGNOSIS.md](TEAMSERVER-OFFLINE-DIAGNOSIS.md) — 진단 결과

---

## 🎯 다음 액션

**지금**:
1. 이 문서 검토
2. Phase A (외부 VM) 준비 확인
3. 파일 전달 방법 결정 (USB/SCP/HTTP)

**외부 VM에서 (언제든)**:
1. Phase A-1~A-3 실행
2. docker-offline-package.tar.gz 생성

**팀서버에서 (Phase A 완료 후)**:
1. Phase B: 파일 수신
2. Phase C: 설치 진행
3. Phase D: 레지스트리 구성

---

**상태**: ✅ 최종 계획 완성. 외부 VM에서 시작 가능.

