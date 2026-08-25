# Rootless Docker 설치 및 레지스트리 구축 (Oracle Linux 8.10)

작성일: 2026-08-18
대상: Oracle Linux 8.10 (Kernel 5.15.0-306)
목표: Rootful Docker 제거 → Rootless Docker 설치 → 레지스트리 재구성

---

## 0. 사전 점검 (필수)

### 0-1. 현재 권한 확인 (가장 먼저!)

```bash
# 일반 사용자로 실행
$ whoami
servicetech2

# 또는
$ id
uid=1000(servicetech2) gid=1000(servicetech2) groups=1000(servicetech2)
```

**준비 체크**:
- ✅ 일반 사용자 (root ❌)
- ⚠️ sudo 비밀번호 준비

---

### 0-2. 시스템 확인 (일반 사용자 권한)

```bash
$ whoami
servicetech2

# 1. 커널 요구사항 확인 (sudo 불필요)
$ uname -r
# → 5.15.0-306 (OK, user namespace 지원)

# 2. User namespace 활성화 확인 (sudo 불필요)
$ cat /proc/sys/user/max_user_namespaces
# → 0이 아닌 값 (OK)

# 3. 사용자 정보 확인 (sudo 불필요)
$ id
# → uid=1000(servicetech2) gid=1000(servicetech2)
```

---

### 0-3. Docker 상태 확인 (sudo 필요!)

```bash
$ whoami
servicetech2

# 이 명령부터는 sudo 필요!

# 현재 rootful 데몬 상태
$ sudo systemctl status docker
$ sudo docker ps -a
# → 컨테이너 없어야 함 (마이그레이션 불필요)

# 기존 daemon.json 있다면 백업
$ sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup-$(date +%F) 2>/dev/null || echo "No daemon.json"
```

---

## Phase 1: Rootful Docker 제거

```bash
# 1. Docker 서비스 중지
sudo systemctl stop docker

# 2. 패키지 제거 (dnf)
sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 3. 설정 디렉토리 백업 (혹시 모를 일에 대비)
sudo tar czf ~/docker-config-backup-$(date +%F).tar.gz /etc/docker/ 2>/dev/null || true

# 4. 확인
docker --version 2>&1 | grep "not found"
# → "docker: command not found" 출력되면 OK
```

---

## Phase 2: Rootless Docker 설치

### 2-1. 일반 사용자에 subuid/subgid 할당

```bash
# servicetech2 사용자에 uid/gid 범위 할당 (rootless 용)
# 형식: username:first_subuid:count

# 확인 (아마 이미 있을 가능성 높음)
grep servicetech2 /etc/subuid /etc/subgid

# 없다면 수동 할당
sudo usermod --add-subuids 100000-165535 servicetech2
sudo usermod --add-subgids 100000-165535 servicetech2

# 재확인
grep servicetech2 /etc/subuid /etc/subgid
# → servicetech2:100000:65536 형태로 나타나면 OK
```

### 2-2. 커널 설정 확인

```bash
# user namespace 활성화 확인
cat /proc/sys/user/max_user_namespaces
# → 0이 아니면 OK (보통 허용됨)
# 만약 0이면 root로 변경:
# sudo sysctl user.max_user_namespaces=15000

# /etc/sysctl.d에 영구 설정 (optional)
echo "user.max_user_namespaces=15000" | sudo tee /etc/sysctl.d/99-userns.conf
sudo sysctl -p /etc/sysctl.d/99-userns.conf
```

### 2-3. Docker Rootless 설치

#### 방법 A: 공식 설치 스크립트 (권장)

```bash
# Docker 공식 rootless 설치 스크립트 다운로드
curl -fsSL https://get.docker.com/rootless | sh

# 또는 gnupg로 검증하려면
curl -fsSL https://get.docker.com/rootless | bash
```

이 스크립트는 자동으로:
- 사용자 홈디렉토리에 Docker 바이너리 설치 (`~/.local/bin/`)
- `dockerd`를 사용자 프로세스로 실행
- systemd --user 통합 설정

#### 방법 B: 수동 설치 (스크립트 실패 시)

```bash
# 1. Rootless 패키지 설치
sudo dnf install -y docker-ce-rootless-extras

# 2. 현재 사용자로 rootless 설정
dockerd-rootless-setuptool.sh install

# 3. 실행 가능 확인
~/.local/bin/docker version
```

### 2-4. systemd --user 통합

```bash
# 1. 사용자 systemd 시작 (이미 실행 중일 가능성 높음)
systemctl --user start docker
systemctl --user enable docker

# 2. 상태 확인
systemctl --user status docker

# 3. 부팅 시에도 자동 시작하도록 설정 (optional, loginuid 필요)
# → 이 부분은 환경에 따라 다름 (나중에 필요시 조정)
```

---

## Phase 3: Rootless Docker 검증

```bash
# 1. 버전 확인
docker version
# → 24.x 또는 설치된 버전 출력

# 2. 정보 확인
docker info | head -20
# → Server: rootless 명시 확인

# 3. 권한 테스트 (sudo 불필요)
docker run --rm hello-world
# → 정상 실행되면 OK (root 권한 안 필요)

# 4. 데몬 소켓 위치 확인
echo $DOCKER_HOST
# → unix://$HOME/.docker/run/docker.sock
```

---

## Phase 4: 레지스트리 재구성

### 4-1. 데이터 경로 준비

```bash
# Rootless 환경에서 권한 범위 내 위치 선택
# Option A: 사용자 홈 (권장)
mkdir -p ~/.docker/volumes/servicetech2-registry/data

# 기존 데이터 있다면 이곳으로 이동
# (처음이므로 생략)

# 권한 확인
ls -la ~/.docker/volumes/servicetech2-registry/
# → servicetech2 소유 확인
```

### 4-2. 레지스트리 컨테이너 기동

```bash
# 포트 5000 (>1024 이므로 직접 바인드 가능)
docker run -d \
  --name servicetech2-registry \
  --restart=always \
  -p 5000:5000 \
  -v ~/.docker/volumes/servicetech2-registry/data:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# 상태 확인
docker ps

# 응답 확인
curl -s http://localhost:5000/v2/
# → {} 반환되면 정상
```

### 4-3. 리모트 클라이언트 접근 설정 (필요시)

#### 문제: Rootless는 기본적으로 로컬 전용
```bash
# Rootless docker.sock 위치
ls ~/.docker/run/docker.sock
# → 이 소켓은 사용자 프로세스만 접근 가능
```

#### 해결책 A: socat으로 포트 노출 (간단)
```bash
# socat 설치
sudo dnf install -y socat

# systemd user service로 자동 시작
mkdir -p ~/.config/systemd/user/

cat > ~/.config/systemd/user/docker-socat.service << 'EOF'
[Unit]
Description=Docker socket to TCP port forwarding
Requires=docker.service
After=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:2376,reuseaddr,fork UNIX-CONNECT:%h/.docker/run/docker.sock
Restart=always

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user start docker-socat
systemctl --user enable docker-socat

# 확인
curl -s http://localhost:2376 | head
```

#### 해결책 B: systemd socket unit (고급)
```bash
# /etc/systemd/user/ (또는 /usr/lib/systemd/user/)에서 
# docker.socket 단위 파일을 TCP 수신 도록 수정
# (복잡하므로 socat 권장)
```

---

## Phase 5: Docker 업버전 (Optional — 28/29로 업데이트)

Rootless 설치 후 최신 버전으로 업데이트하려면:

```bash
# 1. 현재 버전 확인
docker --version

# 2. Docker 저장소 활성화 (아직 없다면)
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# 3. 가능한 버전 확인
dnf list docker-ce --showduplicates | grep '28\.\|29\.'

# 4. 업데이트 (예: 28.x)
# 주의: rootless는 조금 다를 수 있음
sudo dnf install -y docker-ce-<28.x.x버전> docker-ce-cli-<버전>

# 5. systemd --user 재시작
systemctl --user restart docker
```

---

## Phase 6: 최종 검증 체크리스트

- [ ] `docker ps` 정상 작동
- [ ] `docker run --rm hello-world` 성공
- [ ] `curl http://localhost:5000/v2/` 응답 확인
- [ ] `docker ps | grep registry` 컨테이너 실행 중 확인
- [ ] `systemctl --user status docker` Active 상태
- [ ] 다른 사용자 로그인 → `sudo docker ps` 작동 여부 (rootless이므로 불가 정상)
- [ ] 부팅 후 `docker ps` 자동 복구 확인 (선택사항)

---

## 문제 해결

| 증상 | 원인 | 해결 |
|------|------|------|
| `docker: command not found` | PATH에 ~/.local/bin 없음 | `export PATH=$PATH:~/.local/bin` 추가 또는 systemd 통합 |
| `permission denied while trying to connect` | socket 권한 이슈 | `systemctl --user start docker` 재시작 |
| `error getting cgroup version: stat /sys/fs/cgroup/cgroup2: no such file` | cgroup v2 없음 | Optional (v1도 지원, 다만 systemd 통합 시 영향) |
| 컨테이너 재시작 안 됨 | rootless 특성 (restart=always도 로그아웃 시 미작동) | systemd service로 명시적 관리 |

---

## 참고: Rootful 복구 (롤백)

만약 Rootless에서 다시 Rootful로 돌아가야 한다면:

```bash
# 1. Rootless 제거
systemctl --user stop docker
systemctl --user disable docker
rm -rf ~/.docker ~/

# 2. Rootful 재설치
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 3. 데몬 시작
sudo systemctl start docker
sudo systemctl enable docker

# 4. 레지스트리 재구성 (기존 daemon.json.backup 사용)
sudo cp /etc/docker/daemon.json.backup-<날짜> /etc/docker/daemon.json
sudo systemctl restart docker
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | 최초 작성. Oracle Linux 8.10 rootless 설치 가이드 + 레지스트리 재구성. socat으로 리모트 접근 지원 |
