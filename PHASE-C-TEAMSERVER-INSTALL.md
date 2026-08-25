# Phase C: 팀서버 Rootless Docker 설치

**상태**: 준비 완료  
**위치**: /home/servicetech2/upload/docker/docker-offline-package/  
**목표**: 오라클리눅스 8.10에 Rootless Docker 설치

---

## 🔧 Step 1: 기존 Docker 제거

### C-1-1. 현재 Docker 상태 확인
```bash
docker --version
systemctl --user status docker
ps aux | grep docker
```

### C-1-2. 기존 Docker 관련 프로세스 종료
```bash
# 사용자 Docker 서비스 중지
systemctl --user stop docker 2>/dev/null || true

# 남은 프로세스 강제 종료
pkill -9 dockerd 2>/dev/null || true
pkill -9 containerd 2>/dev/null || true
```

### C-1-3. 기존 바이너리 제거
```bash
# ~/.local/bin/ 에 있는 경우
rm -f ~/.local/bin/docker*
rm -f ~/.local/bin/containerd*
rm -f ~/.local/bin/runc
rm -f ~/.local/bin/ctr

# 또는 ~/bin/ 에 있는 경우
rm -f ~/bin/docker*
rm -f ~/bin/containerd*
rm -f ~/bin/runc
rm -f ~/bin/ctr

# 확인
which docker
# "not found" 나와야 함
```

### C-1-4. 기존 systemd 파일 제거
```bash
systemctl --user daemon-reload 2>/dev/null || true
rm -f ~/.config/systemd/user/docker*
rm -rf ~/.config/systemd/user/docker.service.d

# 확인
ls ~/.config/systemd/user/ | grep docker
# (아무것도 안 나와야 함)
```

---

## 🔧 Step 2: iptables 모듈 로드

### C-2-1. 필수 시스템 모듈 로드
```bash
# iptables NAT 모듈 로드 (bridge mode 필요)
modprobe ip_tables
modprobe iptable_nat
modprobe iptable_filter
modprobe iptable_mangle

# 확인
lsmod | grep iptable
# ip_tables, iptable_nat 등이 나와야 함
```

### C-2-2. 부팅 시 자동 로드 설정 (선택)
```bash
cat <<'EOF' | sudo tee /etc/modprobe.d/docker-iptables.conf
# Docker bridge networking을 위한 iptables 모듈
ip_tables
iptable_nat
iptable_filter
iptable_mangle
EOF
```

---

## 🔧 Step 3: 오프라인 패키지에서 바이너리 설치

### C-3-1. 바이너리 디렉토리 생성
```bash
# ~/.local/bin/ 생성 (표준 위치)
mkdir -p ~/.local/bin
chmod 755 ~/.local/bin
```

### C-3-2. 바이너리 복사
```bash
# 압축 파일 경로
PACKAGE_PATH="/home/servicetech2/upload/docker/docker-offline-package"

# 바이너리 복사
cp $PACKAGE_PATH/bin/* ~/.local/bin/
chmod +x ~/.local/bin/*

# 확인
ls -lh ~/.local/bin/
# docker, dockerd, containerd 등 11개 모두 있는지 확인
```

### C-3-3. PATH에 추가
```bash
# 현재 세션
export PATH="$HOME/.local/bin:$PATH"

# 영구 설정 (bashrc에 추가)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 확인
which docker
# /home/servicetech2/.local/bin/docker 나와야 함
```

---

## 🔧 Step 4: systemd 서비스 파일 설정

### C-4-1. systemd 디렉토리 생성
```bash
mkdir -p ~/.config/systemd/user
chmod 755 ~/.config/systemd/user
```

### C-4-2. systemd 파일 복사
```bash
PACKAGE_PATH="/home/servicetech2/upload/docker/docker-offline-package"

# systemd 파일 복사
cp $PACKAGE_PATH/systemd/* ~/.config/systemd/user/
chmod 644 ~/.config/systemd/user/docker*

# 확인
ls -la ~/.config/systemd/user/docker*
# docker.service, docker.socket 있는지 확인
```

### C-4-3. systemd 데몬 재로드
```bash
systemctl --user daemon-reload
```

---

## 🔧 Step 5: 레지스트리 이미지 로드

### C-5-1. registry-2.tar 로드 (Docker 데몬 시작 전)
```bash
PACKAGE_PATH="/home/servicetech2/upload/docker/docker-offline-package"

# 레지스트리 이미지 로드
docker load < $PACKAGE_PATH/images/registry-2.tar

# 확인
docker images | grep registry
# registry:2 이미지 보이면 정상
```

---

## 🔧 Step 6: Docker 데몬 시작

### C-6-1. 사용자 Docker 서비스 시작
```bash
# Docker 서비스 시작
systemctl --user start docker

# 서비스 자동 시작 설정
systemctl --user enable docker

# 상태 확인
systemctl --user status docker
# Active (running) 이어야 함
```

### C-6-2. Docker 소켓 활성화
```bash
# socket 서비스도 시작 (필요시)
systemctl --user start docker.socket
systemctl --user enable docker.socket

# 확인
ls -la ~/.docker/run/docker.sock
```

---

## ✅ Step 7: 최종 검증

### C-7-1. Docker 정상 작동 확인
```bash
# 1️⃣ Docker 버전 확인
docker --version
# Docker version 29.x.x 나와야 함

# 2️⃣ Docker 정보 확인
docker info | head -20
# Storage Driver, Rootless 여부 등 확인

# 3️⃣ 이미지 확인
docker images
# registry:2 이미지 있는지 확인

# 4️⃣ 간단한 테스트 (선택)
docker run --rm alpine echo "Hello from Docker"
```

### C-7-2. systemd 서비스 확인
```bash
# 1️⃣ 서비스 상태
systemctl --user status docker
systemctl --user status docker.socket

# 2️⃣ 서비스 파일 확인
cat ~/.config/systemd/user/docker.service | head -20
```

### C-7-3. 레지스트리 컨테이너 준비
```bash
# 레지스트리 이미지 확인
docker images | grep registry
# registry:2 (10.3MB) 있는지 확인

# 다음 단계에서 컨테이너 실행
# docker run -d -p 5000:5000 --name registry registry:2
```

---

## 📊 예상 결과

```bash
✅ docker --version
Docker version 29.7.2, build a7dcaa6

✅ docker info | grep Rootless
Rootless: true

✅ docker images
REPOSITORY   TAG       IMAGE ID      CREATED       SIZE
registry     2         a3d8aaa6      2 weeks ago   10.3MB

✅ systemctl --user status docker
● docker.service - Docker Application Container Engine (Rootless)
     Loaded: loaded (/home/servicetech2/.config/systemd/user/docker.service)
     Active: active (running)
```

---

## ⚠️ 문제 해결

### 문제: "docker command not found"
```bash
# PATH 확인
echo $PATH
# ~/.local/bin 포함 여부 확인

# 해결
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

### 문제: "permission denied" (Docker 소켓)
```bash
# docker.sock 권한 확인
ls -la ~/.docker/run/docker.sock

# usermod으로 docker 그룹 확인 (Rootless 모드에서는 불필요)
# Rootless는 사용자 단위 실행이므로 그룹 불필요
```

### 문제: "modprobe: FATAL: Module iptables not found"
```bash
# 커널 모듈 확인
cat /boot/config-$(uname -r) | grep NETFILTER

# 또는 lsmod로 확인
lsmod | grep table

# 필요시 iptables 패키지 설치
sudo dnf install -y iptables iptables-libs
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | Phase C: 팀서버 Rootless Docker 설치 절차 작성 |
