# Phase A: 실제 경로 재검토 (외부 VM 확인 기반)

**발견**: 바이너리 위치가 다름  
**실제 경로**: 
- 바이너리: `~/.bin/` (not `~/.local/bin/`)
- 데이터: `~/.local/share/docker/`
- systemd: 미확인 (찾기 필요)

---

## 🔍 실제 상황 (스크린샷 기반)

### 확인된 것 ✅

```bash
$ which docker
~/.bin/docker

$ which dockerd
~/.bin/dockerd

$ ls ~/.local/share/docker/
buildkit  containers  engine-id  image  network  plugins  runtimes  swarm  tmp  volumes
```

**의미**:
- ✅ Docker 설치됨 (명령 작동)
- ✅ 바이너리: `~/.bin/` 디렉토리
- ✅ 데이터: `~/.local/share/docker/` 디렉토리
- ⚠️ systemd 파일: 아직 확인 안 됨

---

## 🔧 수정된 A-3: 실제 경로로 패키징

### A-3-0. 모든 경로 먼저 확인

```bash
# 1️⃣ 바이너리 위치 확인
$ which docker
$ which dockerd
$ which containerd

# 출력: ~/.bin/docker, ~/.bin/dockerd, ... 등

# 2️⃣ 바이너리 전체 확인
$ ls -lah ~/.bin/
# (또는 where docker가 가리키는 경로)

# 3️⃣ systemd 파일 찾기
$ find ~ -name "docker.service" -o -name "docker.socket" 2>/dev/null
$ find ~ -path "*/systemd/*/docker*" 2>/dev/null

# 4️⃣ PATH 확인
$ echo $PATH
# ~/.bin 이 어디에 있는지 확인
```

---

### A-3-1. 올바른 경로로 바이너리 복사

```bash
# 1️⃣ 디렉토리 준비
$ mkdir -p ~/docker-offline-package/{bin,systemd,images,share}

# 2️⃣ ~/.bin/ 에서 모든 바이너리 복사 (실제 경로!)
$ cp ~/.bin/docker* ~/docker-offline-package/bin/ 2>/dev/null || true
$ cp ~/.bin/containerd* ~/docker-offline-package/bin/ 2>/dev/null || true
$ cp ~/.bin/runc ~/docker-offline-package/bin/ 2>/dev/null || true
$ cp ~/.bin/ctr ~/docker-offline-package/bin/ 2>/dev/null || true

# 또는 전체
$ find ~/.bin -maxdepth 1 -type f -executable -exec cp {} ~/docker-offline-package/bin/ \;

# 3️⃣ 확인
$ ls -lah ~/docker-offline-package/bin/
# docker, dockerd, containerd 등이 있어야 함

# 4️⃣ 각 파일 크기 확인 (0이 아니어야 함)
$ du -sh ~/docker-offline-package/bin/*
```

---

### A-3-2. systemd 파일 복사 (찾기부터)

```bash
# 1️⃣ systemd 파일 위치 검색
$ find ~ -name "docker.service" -o -name "docker.socket" 2>/dev/null

# 예상 경로 (하나 또는 여럿):
# ~/.local/lib/systemd/user/docker.service
# ~/.config/systemd/user/docker.service
# /usr/lib/systemd/user/docker.service (root 설치)
# /etc/systemd/system/docker.service

# 2️⃣ 찾은 경로로 복사
# 예: ~/.local/lib/systemd/user/ 에 있다면
$ cp -r ~/.local/lib/systemd/user/docker* ~/docker-offline-package/systemd/

# 또는 전체 검색 + 복사
$ find ~ -path "*/systemd/*/docker*" -type f 2>/dev/null | \
  xargs -I {} cp {} ~/docker-offline-package/systemd/ 2>/dev/null

# 3️⃣ 확인
$ ls -la ~/docker-offline-package/systemd/
# docker.service, docker.socket, docker.service.d/ 등이 있어야 함

# 만약 없다면:
$ find ~ -name "*.service" -path "*docker*" 2>/dev/null
```

---

### A-3-3. Docker 런타임 데이터 복사 (선택)

```bash
# 1️⃣ 데이터 디렉토리 복사
$ cp -r ~/.local/share/docker ~/docker-offline-package/share/

# 또는 (공간 절약 - 이미지만)
$ mkdir -p ~/docker-offline-package/share/docker/image
$ cp -r ~/.local/share/docker/image ~/docker-offline-package/share/docker/

# 2️⃣ 크기 확인
$ du -sh ~/docker-offline-package/share/
```

---

### A-3-4. 레지스트리 이미지 확인

```bash
# 1️⃣ 이미지 있는지 확인
$ ls -lh ~/docker-offline-package/images/registry-2.tar
# ~100MB 있어야 함

# 없다면 다시 저장
$ docker save registry:2 -o ~/docker-offline-package/images/registry-2.tar
```

---

### A-3-5. 최종 패키징

```bash
# 1️⃣ 구조 확인
$ find ~/docker-offline-package -type f | sort
# bin/, systemd/, images/, share/ 모두 파일이 있어야 함

# 2️⃣ 기존 압축 파일 삭제
$ rm -f docker-offline-package.tar.gz

# 3️⃣ 다시 압축
$ cd ~
$ tar czf docker-offline-package.tar.gz docker-offline-package/

# 4️⃣ 크기 확인
$ ls -lh docker-offline-package.tar.gz
# 이번엔 200MB 이상이어야 함

# 5️⃣ 체크섬
$ sha256sum docker-offline-package.tar.gz > docker-offline-package.sha256
```

---

## ✅ 완료 검증

```bash
# 1️⃣ 압축 파일 내용 확인
$ tar tzf docker-offline-package.tar.gz | head -50

# 2️⃣ 주요 파일 확인
$ tar tzf docker-offline-package.tar.gz | grep -E "bin/docker|docker.service|registry-2.tar"
# 출력:
# docker-offline-package/bin/docker
# docker-offline-package/bin/dockerd
# docker-offline-package/systemd/docker.service
# docker-offline-package/images/registry-2.tar

# 3️⃣ 최종 확인
$ ls -lh docker-offline-package.tar.gz
$ cat docker-offline-package.sha256
```

---

## 📊 올바른 디렉토리 구조

```
~/docker-offline-package/
├─ bin/                          (바이너리)
│  ├─ docker                     (~40MB)
│  ├─ dockerd                    (~20MB)
│  ├─ containerd                 (~50MB)
│  ├─ runc
│  ├─ ctr
│  └─ ...
├─ systemd/                      (systemd 서비스 파일)
│  ├─ docker.service
│  ├─ docker.socket
│  └─ docker.service.d/
├─ images/                       (Docker 이미지)
│  ├─ registry-2.tar             (~100MB)
│  └─ ...
└─ share/                        (선택: Docker 런타임 데이터)
   └─ docker/
      ├─ image/
      ├─ containers/
      └─ ...
```

---

## 🚨 만약 systemd 파일이 없다면

```bash
# 1️⃣ 공식 설치 스크립트 재실행
$ SKIP_IPTABLES=1 bash <(curl -fsSL https://get.docker.com/rootless)

# 또는

# 2️⃣ 수동으로 systemd 파일 생성 (팀서버에서 나중에)
mkdir -p ~/.local/lib/systemd/user/
# EXECUTION-PLAN-FINAL.md의 C-2 참고
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | A-3 재검토: 실제 경로 `~/.bin/`으로 수정. systemd 파일 위치 재확인 필요 |
