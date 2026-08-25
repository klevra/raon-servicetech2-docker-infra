# Phase A: 압축 전 확인 체크리스트 (외부 VM)

**상황**: A-2에서 시스템 요구사항 에러 발생  
**에러 메시지**: "Missing system requirements. Please run following commands to install requirements again"

---

## 🔴 발견된 문제

### A-2 설치 로그 분석

```
# Executing docker rootless install script, commit: a23123f03978989e95d257beb9de0c5ad9da6e70
# Missing system requirements. Please run following commands to install requirements again
# Alternatively iptables checks can be disabled with SKIP_IPTABLES=1

cat <<EOF | sudo sh -x
modprobe ip_tables
EOF
```

**의미**:
- ⚠️ `iptables` 모듈이 없거나 로드되지 않음
- ⚠️ 시스템 요구사항 미충족
- ✅ 하지만 `SKIP_IPTABLES=1`로 우회 가능
- ❓ 설치가 완전히 실패했는지 부분 성공했는지 확인 필요

---

## ✅ 확인할 항목 (우선순위순)

### 1️⃣ **Docker 설치 상태 확인** (가장 중요!)

```bash
$ whoami
klevra

# 1-1. 버전 확인
$ ~/.local/bin/docker --version
# 예상: Docker version 28.x.x 또는 Docker version 24.x.x
# 실패: command not found

# 1-2. info 확인
$ ~/.local/bin/docker info | head -20
# 예상: Server: 정보 출력
# 실패: cannot connect to Docker daemon

# 1-3. 경로 확인
$ which docker
# 또는
$ echo $PATH | grep .local
$ ls -la ~/.local/bin/docker
```

**결과 해석**:
- ✅ `docker --version` 성공 → 설치 완료, 다음 단계로
- ❌ `command not found` → 설치 실패, A-2 재실행 필요

---

### 2️⃣ **바이너리 파일 확인**

```bash
# 2-1. 바이너리 경로 확인
$ ls -la ~/.local/bin/ | grep docker
# 예상 파일들:
# -rwxr-xr-x docker
# -rwxr-xr-x docker-compose
# -rwxr-xr-x dockerd
# -rwxr-xr-x containerd
# -rwxr-xr-x ctr
# -rwxr-xr-x runc

# 2-2. 파일 개수 확인
$ ls -1 ~/.local/bin/ | wc -l
# 예상: 10개 이상

# 2-3. 각 주요 파일 크기 확인
$ du -sh ~/.local/bin/docker*
# 예상: docker 30~50MB, dockerd 10~20MB 등 (작지 않아야 함)
```

**결과 해석**:
- ✅ 파일이 여러 개 있고 크기가 크면 → OK
- ❌ 파일이 없거나 크기가 0B → 설치 실패

---

### 3️⃣ **systemd 사용자 파일 확인**

```bash
# 3-1. systemd 디렉토리 확인
$ ls -la ~/.local/lib/systemd/user/docker*
# 예상 파일:
# docker.service
# docker.socket
# docker.service.d/ (디렉토리)

# 3-2. 파일 내용 확인 (간단히)
$ cat ~/.local/lib/systemd/user/docker.service | head -10
# 예상: [Unit], [Service] 섹션 있어야 함
```

**결과 해석**:
- ✅ 파일이 있고 내용이 있으면 → OK
- ❌ 파일이 없으면 → 설치 실패

---

### 4️⃣ **레지스트리 이미지 다운로드 확인**

```bash
# 4-1. 데몬이 시작되었는지 확인
$ systemctl --user status docker
# 또는 (backgroundd 실행 중인지)
$ ps aux | grep dockerd

# 4-2. 이미지 다운로드 시도
$ docker pull registry:2
# 예상: Pull 진행... 최종적으로 "Digest: sha256:..."

# 4-3. 로컬 이미지 확인
$ docker images
# 예상:
# REPOSITORY   TAG    IMAGE ID     CREATED      SIZE
# registry     2      [id]         ...          ~100MB
```

**결과 해석**:
- ✅ `docker pull registry:2` 성공, `docker images`에 registry:2 보임 → OK
- ❌ daemon 연결 실패 또는 이미지 없음 → 데몬 시작 필요

---

## 🔧 **A-2 설치 실패 시 해결 방법**

### 방법 1: SKIP_IPTABLES로 재설치 (권장)

```bash
# 1. 이전 설치 정리
$ systemctl --user stop docker 2>/dev/null || true
$ rm -rf ~/.local/bin/docker*
$ rm -rf ~/.local/lib/systemd/user/docker*

# 2. SKIP_IPTABLES=1로 재설치
$ SKIP_IPTABLES=1 bash <(curl -fsSL https://get.docker.com/rootless)

# 3. 검증
$ docker --version
$ systemctl --user start docker
$ docker pull registry:2
```

---

### 방법 2: 수동 systemd 설정

만약 스크립트 설치가 여전히 실패한다면, 수동 설정:

```bash
# 1. 바이너리만 수동으로 설치했다고 가정

# 2. systemd 파일 수동 생성
mkdir -p ~/.local/lib/systemd/user

cat > ~/.local/lib/systemd/user/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine (Rootless)
Documentation=https://docs.docker.com/engine/security/rootless/
PartOf=docker.socket
After=docker.socket
Wants=docker-containerd.service

[Service]
Type=simple
ExecStart=%h/.local/bin/dockerd --logdriver json-file --log-opt labels=com.example.vendor=Acme \
  --log-opt max-size=10m --log-opt max-file=5 \
  --storage-driver overlay2

[Install]
WantedBy=default.target
EOF

# 3. systemd 새로고침
$ systemctl --user daemon-reload

# 4. 시작
$ systemctl --user start docker
```

---

## 📋 최종 체크 (압축 전)

**필수** (모두 확인되어야 압축 진행):

```bash
# 1️⃣ Docker 버전 확인 (필수!)
$ docker --version
# ✅ Docker version 28.x.x (또는 24.x.x)

# 2️⃣ 데몬 상태 확인 (필수!)
$ systemctl --user status docker
# ✅ Active (running)

# 3️⃣ 레지스트리 이미지 확인 (필수!)
$ docker images | grep registry
# ✅ registry  2     [image-id]   ...

# 4️⃣ 바이너리 파일 확인 (필수!)
$ ls -1h ~/.local/bin/docker* | wc -l
# ✅ 5개 이상

# 5️⃣ systemd 파일 확인 (필수!)
$ ls -la ~/.local/lib/systemd/user/docker*
# ✅ docker.service, docker.socket 있어야 함

# 6️⃣ 간단한 테스트 (권장)
$ docker run --rm alpine echo "Hello from Docker"
# ✅ Hello from Docker
```

---

## ⚠️ 상황별 대응

### 상황 1: Docker 명령 실패, systemd 파일 없음
```
→ A-2 재설치 필요
→ SKIP_IPTABLES=1 으로 시도
```

### 상황 2: Docker 설치됨, 데몬 시작 안 됨
```
→ systemctl --user start docker 실행
→ 실패하면 로그 확인: journalctl --user -xe
```

### 상황 3: Docker OK, 레지스트리 이미지 없음
```
→ docker pull registry:2 실행
→ 완료 후 docker images 확인
```

### 상황 4: 모두 정상
```
→ 압축 진행 가능!
→ A-3 단계로 이동
```

---

## 📝 완성 시 파일 구조

압축 전 최종 확인:

```
~/.local/bin/
├─ docker                 (메인 바이너리) ~40MB
├─ dockerd               (데몬) ~20MB
├─ docker-compose        ~10MB
├─ containerd            ~50MB
├─ ctr
└─ runc

~/.local/lib/systemd/user/
├─ docker.service        (systemd 서비스 정의)
├─ docker.socket         (systemd 소켓)
└─ docker.service.d/     (서비스 설정 디렉토리)

docker images:
├─ registry:2            ~100MB

패키징할 파일들:
├─ ~/.local/bin/*        (모두 복사)
├─ ~/.local/lib/systemd/user/docker*  (모두 복사)
└─ registry-2.tar        (이미지 저장)
```

---

## 🚀 다음 단계 (체크 완료 후)

**모든 항목이 ✅ 확인되면**:

```bash
# A-3: 파일 패키징 진행
mkdir -p ~/docker-offline-package/bin
cp ~/.local/bin/docker* ~/docker-offline-package/bin/
cp -r ~/.local/lib/systemd/user/docker* ~/docker-offline-package/
docker save registry:2 -o ~/docker-offline-package/registry-2.tar

# 최종 압축
cd ~
tar czf docker-offline-package.tar.gz docker-offline-package/
ls -lh docker-offline-package.tar.gz
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | Phase A 압축 전 확인 체크리스트. A-2 설치 에러 대응 방법 정리 |
