# Phase A: 최종 수정본 - 누락된 부분 추가

**문제점**: 바이너리와 systemd 파일 경로가 다름  
**원인**: Rootless Docker 설치 후 실제 파일 위치 확인 필요  
**해결**: 올바른 경로로 패키징

---

## 🔴 현재 상황 분석 (로그 기반)

### 성공한 것 ✅
```
✅ registry:2 이미지 다운로드 완료
✅ Digest: sha256:a86d68ea3008a6d1dea0a03f100d5895b6a58ace528858a7b332415373
✅ Status: Downloaded newer image for registry:2
✅ tar czf docker-offline-package.tar.gz 완료
```

### 실패한 것 ❌
```
❌ cp: cannot stat '/home/klevra/.local/bin/docker*': No such file or directory
❌ cp: cannot stat '/home/klevra/.local/lib/systemd/user/docker*': No such file or directory
```

**의미**: 바이너리/systemd 파일이 다른 경로에 있음

### 존재하는 것 ✅
```
~/.local/share/docker/ 
├─ buildkit/
├─ containerd/
├─ containers/
├─ engine-id
├─ image/
├─ network/
├─ plugins/
├─ runtimes/
├─ swarm/
├─ tmp/
└─ volumes/
```

**의미**: Docker 데이터는 있지만, 바이너리 경로가 다름

---

## 🔧 수정된 A-3: 파일 위치 확인 및 패키징

### A-3-1. 바이너리 위치 찾기

```bash
# 1️⃣ 현재 docker 명령 위치 확인
$ which docker
/home/klevra/.local/bin/docker

# 또는
$ command -v docker

# 또는
$ type docker
docker is /home/klevra/.local/bin/docker

# 2️⃣ 만약 위가 안 나오면 find로 검색
$ find ~/.local -name "docker" -type f 2>/dev/null

# 3️⃣ $PATH 확인
$ echo $PATH
# ~/.local/bin 이 포함되어 있어야 함

# 4️⃣ 바이너리 확인
$ ls -lah ~/.local/bin/ | head -20
# docker, dockerd, containerd 등이 있어야 함
```

### A-3-2. systemd 파일 위치 찾기

```bash
# 1️⃣ systemd 파일 위치 확인
$ find ~/.local -path "*/systemd/user/docker*" 2>/dev/null

# 2️⃣ 전체 구조 확인
$ find ~/.local -type d -name "systemd" 2>/dev/null

# 3️⃣ 또는
$ ls -la ~/.local/lib/systemd/user/ 2>/dev/null || \
  find ~/.local -name "docker.service" 2>/dev/null
```

### A-3-3. 올바른 경로로 패키징

```bash
# 1️⃣ 디렉토리 준비
$ mkdir -p ~/docker-offline-package/{bin,systemd,images}

# 2️⃣ 바이너리 복사 (실제 경로 확인 후)
$ ls ~/.local/bin/docker* >/dev/null 2>&1 && \
  cp ~/.local/bin/docker* ~/docker-offline-package/bin/ || \
  echo "docker 바이너리 찾기 실패 - 아래 수동 검색 필요"

# 3️⃣ docker 바이너리만 먼저 복사 (확실한 방법)
$ docker --version  # docker 명령이 작동하는지 확인
$ which docker      # 경로 확인 (예: /home/klevra/.local/bin/docker)

# 위에서 경로 확인 후:
$ cp /home/klevra/.local/bin/docker ~/docker-offline-package/bin/
$ cp /home/klevra/.local/bin/dockerd ~/docker-offline-package/bin/
$ cp /home/klevra/.local/bin/containerd ~/docker-offline-package/bin/

# 4️⃣ 모든 관련 바이너리 복사
$ find ~/.local/bin -executable -type f | xargs -I {} cp {} ~/docker-offline-package/bin/ 2>/dev/null

# 5️⃣ 확인
$ ls -lh ~/docker-offline-package/bin/
# docker, dockerd, containerd 등이 있어야 함

# 6️⃣ systemd 파일 복사 (경로 찾기)
$ find ~/.local -path "*/systemd/user/docker*" -type f | \
  xargs -I {} cp {} ~/docker-offline-package/systemd/ 2>/dev/null

# 또는 전체 systemd 디렉토리 복사
$ find ~/.local -path "*/systemd/user" -type d | \
  xargs -I {} cp -r {}/* ~/docker-offline-package/systemd/ 2>/dev/null

# 7️⃣ 확인
$ ls -la ~/docker-offline-package/systemd/
# docker.service, docker.socket 등이 있어야 함

# 8️⃣ Docker 데이터 디렉토리도 포함 (선택)
$ cp -r ~/.local/share/docker ~/docker-offline-package/

# 9️⃣ 최종 확인
$ find ~/docker-offline-package -type f | sort
```

---

## 📦 올바른 패키징 절차 (완전 버전)

```bash
# 1️⃣ 준비
$ mkdir -p ~/docker-offline-package/{bin,systemd,images,share}

# 2️⃣ 바이너리 복사 (모든 방법 시도)
# 방법 A: 단일 파일
$ cp ~/.local/bin/docker ~/docker-offline-package/bin/
$ cp ~/.local/bin/dockerd ~/docker-offline-package/bin/
$ cp ~/.local/bin/containerd ~/docker-offline-package/bin/

# 또는 방법 B: 와일드카드 (경로가 정확하면)
$ cp ~/.local/bin/docker* ~/docker-offline-package/bin/ 2>/dev/null || true

# 또는 방법 C: find 사용 (가장 확실)
$ find ~/.local/bin -maxdepth 1 -type f -executable -exec cp {} ~/docker-offline-package/bin/ \;

# 3️⃣ systemd 파일 복사
$ find ~/.local -name "docker.service" -o -name "docker.socket" -o -name "docker.service.d" 2>/dev/null | \
  while read f; do cp -r "$f" ~/docker-offline-package/systemd/ 2>/dev/null; done

# 또는
$ cp -r ~/.local/lib/systemd/user/docker* ~/docker-offline-package/systemd/ 2>/dev/null || \
  cp -r ~/.config/systemd/user/docker* ~/docker-offline-package/systemd/ 2>/dev/null || true

# 4️⃣ 레지스트리 이미지 (이미 했으면 스킵)
$ docker save registry:2 -o ~/docker-offline-package/images/registry-2.tar 2>/dev/null || \
  ls ~/docker-offline-package/images/registry-2.tar >/dev/null && \
  echo "이미지 파일 존재"

# 5️⃣ Docker 런타임 디렉토리 (선택사항)
$ cp -r ~/.local/share/docker ~/docker-offline-package/share/ 2>/dev/null || true

# 6️⃣ 최종 확인
$ echo "=== 바이너리 ===" 
$ ls -lh ~/docker-offline-package/bin/
$ echo "=== systemd 파일 ==="
$ ls -la ~/docker-offline-package/systemd/
$ echo "=== 이미지 ==="
$ ls -lh ~/docker-offline-package/images/

# 7️⃣ 문제가 있으면 전체 구조 확인
$ find ~/docker-offline-package -type f -exec ls -lh {} \;

# 8️⃣ 압축
$ cd ~
$ tar czf docker-offline-package.tar.gz docker-offline-package/
$ ls -lh docker-offline-package.tar.gz

# 9️⃣ 체크섬
$ sha256sum docker-offline-package.tar.gz > docker-offline-package.sha256
```

---

## 🔍 디버깅: 파일이 정말 없는 경우

```bash
# 1️⃣ docker 명령이 작동하는지 확인
$ docker --version
# Docker version 28.x.x 나오면 설치됨

# 2️⃣ 실제 실행 파일 위치 찾기
$ which docker
$ which dockerd
$ which containerd

# 3️⃣ 각 위치 확인
$ file $(which docker)
# /home/klevra/.local/bin/docker: ELF 64-bit ...

# 4️⃣ 크기 확인 (0이 아니어야 함)
$ du -sh $(which docker)
$ du -sh $(which dockerd)

# 5️⃣ 모든 docker 관련 파일 찾기
$ find ~ -name "*docker*" -type f 2>/dev/null | grep -E "bin|lib" | head -20

# 6️⃣ systemd 파일 찾기
$ find ~ -name "docker.service" -o -name "docker.socket" 2>/dev/null

# 7️⃣ 환경 변수 확인
$ echo $HOME
$ echo $PATH
$ env | grep -i local
```

---

## 📋 최종 체크리스트

압축 전 반드시 확인:

```bash
# ✅ 1. 바이너리 파일 확인
$ ls -1 ~/docker-offline-package/bin/ | wc -l
# 5개 이상이어야 함

# ✅ 2. 각 바이너리 크기 확인 (0이 아니어야 함)
$ du -sh ~/docker-offline-package/bin/*
# docker ~40MB, dockerd ~20MB, containerd ~50MB 등

# ✅ 3. systemd 파일 확인
$ ls -1 ~/docker-offline-package/systemd/ | wc -l
# 2개 이상 (docker.service, docker.socket)

# ✅ 4. 이미지 파일 확인
$ ls -lh ~/docker-offline-package/images/registry-2.tar
# ~100MB

# ✅ 5. 전체 구조 확인
$ tar tzf docker-offline-package.tar.gz | head -30
# bin/, systemd/, images/ 등이 보여야 함

# ✅ 6. 압축 파일 크기 확인
$ du -sh docker-offline-package.tar.gz
# 150-200MB 정도
```

---

## 🚀 완료 후 다음 단계

```bash
# 1. 최종 확인
$ ls -lh docker-offline-package.tar.gz
$ cat docker-offline-package.sha256

# 2. 팀서버로 전달 (USB/SCP 선택)
# USB: cp docker-offline-package.tar.gz /media/usb/
# SCP: scp docker-offline-package.tar.gz servicetech2@팀서버IP:~/
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | A-3 수정: 바이너리/systemd 파일 경로 오류 수정. 올바른 경로 찾기 및 패키징 방법 추가 |
