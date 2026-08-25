# Phase A: Rootless Docker 설치 (수정본 - iptables 포함)

**수정 사항**: A-2에서 시스템 요구사항 설치 추가  
**이유**: bridge 모드/포트 바인딩을 위해 iptables 필수  
**대상**: 외부 VM (Oracle Linux 8.10, 인터넷 가능)

---

## 🎯 Phase A 전체 흐름

```
A-0: 환경 확인
  ↓
A-1: 시스템 요구사항 확인 및 설치 (iptables 모듈 로드)
  ↓
A-2: Rootless Docker 설치
  ↓
A-3: 레지스트리 이미지 다운로드
  ↓
A-4: 파일 패키징
  ↓
✅ docker-offline-package.tar.gz 생성
```

---

## 📋 A-0: 환경 확인 (5분)

```bash
# 외부 VM에서 실행

$ whoami
klevra  # 또는 다른 일반 사용자

$ uname -r
5.15.0-206.153.7.1.el8uek.x86_64  # 또는 유사 버전

$ cat /etc/os-release
NAME="Oracle Linux Server"
VERSION="8.10"

$ dnf --version
dnf version 4.x.x
```

---

## ⚠️ A-1: 시스템 요구사항 설치 (필수!) (5분)

### A-1-1. 현재 상태 확인

```bash
# iptables 모듈 로드 여부 확인
$ lsmod | grep iptables
# 출력 없으면 로드되지 않은 상태

# 또는
$ modinfo iptables
# "modname: iptables" 나타나면 사용 가능
```

### A-1-2. iptables 모듈 로드 (에러 메시지에서 제시한 방법)

```bash
# sudo 권한 필요!

cat <<EOF | sudo sh -x
modprobe iptables_filter
modprobe ip_tables
modprobe iptables_nat
modprobe nf_nat
modprobe nf_conntrack
EOF

# 또는 간단하게
$ sudo modprobe iptables_filter
$ sudo modprobe iptables_nat
```

### A-1-3. 설치 확인

```bash
# 로드 확인
$ lsmod | grep iptables
# 예상: iptables_filter 나타나야 함
```

---

## 🐳 A-2: Rootless Docker 설치 (10분)

### A-2-1. 공식 스크립트로 설치

```bash
# 이제 iptables가 준비되었으므로 정상 설치 가능

$ curl -fsSL https://get.docker.com/rootless | bash

# 출력 예:
# ...
# Creating socket activation directory...
# Creating systemd service directory...
# Ensuring other services are stopped...
# WARNING: Docker socket is not activated.
# ...
```

### A-2-2. 설치 확인

```bash
# 버전 확인
$ ~/.local/bin/docker --version
# 예상: Docker version 28.x.x (또는 24.x.x)

# 경로 확인
$ ls -la ~/.local/bin/docker
$ ls -la ~/.local/bin/dockerd
$ ls -la ~/.local/bin/containerd
```

### A-2-3. systemd 통합 확인

```bash
# 데몬 시작
$ systemctl --user start docker

# 상태 확인
$ systemctl --user status docker
# 예상: Active (running)

# 자동 시작 설정
$ systemctl --user enable docker
```

---

## 📥 A-3: 레지스트리 이미지 다운로드 (10분)

```bash
# 1️⃣ 데몬이 실행 중인지 확인
$ systemctl --user status docker
# Active (running) 이어야 함

# 2️⃣ 레지스트리 이미지 다운로드
$ docker pull registry:2
# Pulling from library/registry
# Digest: sha256:...
# Status: Downloaded newer image for registry:2

# 3️⃣ 다운로드 확인
$ docker images
# REPOSITORY   TAG    IMAGE ID      CREATED       SIZE
# registry     2      [image-id]    ...           ~100MB

# 4️⃣ (선택) 기타 이미지 (필요하면)
$ docker pull alpine
$ docker images | grep alpine
```

---

## 📦 A-4: 파일 패키징 (15분)

### A-4-1. 패키징 디렉토리 준비

```bash
# 1️⃣ 디렉토리 생성
$ mkdir -p ~/docker-offline-package/{bin,systemd,images}

# 2️⃣ 바이너리 복사
$ cp ~/.local/bin/docker* ~/docker-offline-package/bin/
$ cp ~/.local/bin/containerd* ~/docker-offline-package/bin/
$ cp ~/.local/bin/ctr ~/docker-offline-package/bin/ 2>/dev/null || true
$ cp ~/.local/bin/runc ~/docker-offline-package/bin/ 2>/dev/null || true

# 3️⃣ 파일 확인
$ ls -lh ~/docker-offline-package/bin/
# 예상: docker (~40MB), dockerd (~20MB), containerd (~50MB) 등
```

### A-4-2. systemd 파일 복사

```bash
# 1️⃣ systemd 파일 복사
$ cp -r ~/.local/lib/systemd/user/docker* ~/docker-offline-package/systemd/

# 2️⃣ 확인
$ ls -la ~/docker-offline-package/systemd/
# 예상: docker.service, docker.socket, docker.service.d/ 등
```

### A-4-3. 레지스트리 이미지 저장

```bash
# 1️⃣ registry:2 이미지 저장
$ docker save registry:2 -o ~/docker-offline-package/images/registry-2.tar
# Saving image...

# 2️⃣ 파일 크기 확인
$ du -sh ~/docker-offline-package/images/registry-2.tar
# 예상: ~100MB

# 3️⃣ (선택) 기타 이미지도 저장
$ docker save alpine -o ~/docker-offline-package/images/alpine.tar
```

### A-4-4. 최종 압축

```bash
# 1️⃣ 구조 확인
$ tree ~/docker-offline-package/
# 또는
$ find ~/docker-offline-package/ -type f | sort

# 2️⃣ 압축
$ cd ~
$ tar czf docker-offline-package.tar.gz docker-offline-package/

# 3️⃣ 파일 크기 확인
$ ls -lh docker-offline-package.tar.gz
# 예상: ~150-200MB

# 4️⃣ 체크섬 생성 (검증용)
$ sha256sum docker-offline-package.tar.gz > docker-offline-package.sha256
$ cat docker-offline-package.sha256
```

---

## ✅ A-4 완료 확인 체크리스트

```bash
# 1️⃣ 파일 구조 확인
$ tar tzf docker-offline-package.tar.gz | head -20

# 2️⃣ 바이너리 포함 확인
$ tar tzf docker-offline-package.tar.gz | grep 'bin/docker' | head -5

# 3️⃣ systemd 파일 포함 확인
$ tar tzf docker-offline-package.tar.gz | grep 'docker.service'

# 4️⃣ 이미지 포함 확인
$ tar tzf docker-offline-package.tar.gz | grep registry-2.tar

# 5️⃣ 최종 확인
$ ls -lh ~/docker-offline-package.tar.gz
$ cat ~/docker-offline-package.sha256
```

---

## 🚨 문제 발생 시 대응

### 문제 1: A-1 iptables 로드 실패
```
$ cat <<EOF | sudo sh -x
modprobe iptables_filter
EOF

Error: modprobe: FATAL: Module iptables_filter not found in ...
```

**대응**:
```bash
# 시스템 패키지 설치 필요
$ sudo dnf install -y iptables

# 또는 커널 설정 확인
$ cat /boot/config-$(uname -r) | grep CONFIG_IP_NF_FILTER
# = y 면 OK, = m 이면 modprobe 시도
```

---

### 문제 2: A-2 설치 후에도 docker 명령 안 됨
```
$ docker --version
command not found
```

**대응**:
```bash
# PATH 추가
$ echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
$ source ~/.bashrc

# 또는 직접 실행
$ ~/.local/bin/docker --version
```

---

### 문제 3: A-3 registry:2 pull 실패
```
$ docker pull registry:2
ERROR: Cannot connect to Docker daemon
```

**대응**:
```bash
# 데몬 재시작
$ systemctl --user restart docker

# 상태 확인
$ systemctl --user status docker

# 다시 시도
$ docker pull registry:2
```

---

## 📊 최종 산출물

### 생성되는 파일

```
~/docker-offline-package.tar.gz          (~150-200MB)
├─ docker-offline-package/
│  ├─ bin/
│  │  ├─ docker                (40MB)
│  │  ├─ dockerd               (20MB)
│  │  ├─ containerd            (50MB)
│  │  ├─ ctr
│  │  ├─ runc
│  │  └─ ...
│  ├─ systemd/
│  │  ├─ docker.service
│  │  ├─ docker.socket
│  │  └─ docker.service.d/
│  └─ images/
│     ├─ registry-2.tar        (100MB)
│     └─ alpine.tar            (선택사항)

~/docker-offline-package.sha256
└─ [체크섬]
```

### 다음 단계 (Phase B)

```bash
# 파일 팀서버로 전달
# 1️⃣ USB에 복사
$ cp docker-offline-package.tar.gz /media/usb/

# 2️⃣ 또는 SCP
$ scp docker-offline-package.tar.gz servicetech2@팀서버IP:~/

# 3️⃣ 또는 HTTP 서버
$ python3 -m http.server 8000
# 팀서버에서: wget http://외부VM_IP:8000/docker-offline-package.tar.gz
```

---

## ⏱️ 소요 시간

| 단계 | 작업 | 시간 |
|------|------|------|
| A-0 | 환경 확인 | 5분 |
| A-1 | iptables 설치 | 5분 |
| A-2 | Docker 설치 | 10분 |
| A-3 | 이미지 다운로드 | 10분 |
| A-4 | 파일 패키징 | 15분 |
| **합계** | | **45분** |

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | Phase A 수정본. A-1에서 iptables 모듈 로드 추가 (bridge 모드/포트 바인딩 필수) |
