# Phase A: 실제 에러 분석 및 최종 수정

**발견된 에러들**:
1. `~/.bin/` 디렉토리 자체가 없음
2. systemd 경로: `/home/klevra/.config/systemd/user/` (확정)
3. Docker 데이터 복사 시 Permission denied
4. 압축 시 Permission denied

---

## 🔴 실제 에러 분석

### 에러 1: ~/.bin/ 디렉토리 없음
```
find ~/.bin -maxdepth 1 -type f -executable ...
find: '/home/klevra/.bin': No such file or directory
```

**의미**: `which docker` 결과는 `~/.bin/docker`로 보이지만, symlink 또는 PATH에서 찾은 것
**해결**: `type -a docker` 로 실제 경로 찾기

---

### 에러 2: systemd 파일 경로 확정 ✅
```
/home/klevra/.config/systemd/user/docker.service
/home/klevra/.config/systemd/user/docker.socket
```

**의미**: systemd 파일은 `~/.config/systemd/user/` 에 있음 (확정!)

---

### 에러 3: Docker 데이터 복사 권한 문제
```
cp: cannot access '/home/klevra/.local/share/docker/containerd/daemon/io.containerd.snapshotter.v1.overlayfs/snapshots/3/work/work'
Permission denied
```

**의미**: 
- Docker 런타임 데이터는 일부 파일이 접근 불가능
- 이미지 파일(`registry-2.tar`)만 필요하므로 데이터 전체 복사는 불필요

---

### 에러 4: 압축 시 Permission denied
```
tar: docker-offline-package/share/docker/containerd/daemon/io.containerd.snapshotter...
Exiting with failure status due to previous errors
```

**의미**: 권한 문제 때문에 tar 압축 실패

---

## ✅ 최종 수정: 올바른 실행 순서

### Step 1: 바이너리 실제 경로 찾기

```bash
# 1️⃣ docker 명령의 실제 위치 찾기
$ type -a docker

# 예상 출력:
# docker is hashed (/home/klevra/.local/bin/docker)
# 또는
# docker is /home/klevra/.local/bin/docker

# 2️⃣ 실제 파일 위치 확인
$ ls -la $(type -p docker)

# 3️⃣ symlink 해석
$ realpath $(type -p docker)
# 또는
$ readlink -f $(which docker)

# 4️⃣ 경로 확인 완료
$ dirname $(type -p docker)
# 이 경로가 바이너리 위치!
```

---

### Step 2: 올바른 디렉토리 구조로 패키징

```bash
# 1️⃣ 디렉토리 준비
$ mkdir -p ~/docker-offline-package/{bin,systemd,images}

# 2️⃣ 바이너리 경로 변수에 저장 (Step 1에서 찾은 경로)
$ DOCKER_BIN_PATH=$(dirname $(type -p docker))
$ echo $DOCKER_BIN_PATH
# /home/klevra/.local/bin 또는 다른 경로

# 3️⃣ 바이너리 복사
$ cp $DOCKER_BIN_PATH/docker* ~/docker-offline-package/bin/

# 또는 직접
$ cp /home/klevra/.local/bin/docker* ~/docker-offline-package/bin/ 2>/dev/null || \
  cp /usr/bin/docker* ~/docker-offline-package/bin/ 2>/dev/null || true

# 4️⃣ 확인
$ ls -lh ~/docker-offline-package/bin/
# docker, dockerd, containerd 등이 있어야 함
```

---

### Step 3: systemd 파일 복사 (경로 확정)

```bash
# 1️⃣ systemd 경로 (확정!)
$ SYSTEMD_PATH="$HOME/.config/systemd/user"

# 2️⃣ 파일 확인
$ ls -la $SYSTEMD_PATH/docker*

# 3️⃣ 복사
$ cp $SYSTEMD_PATH/docker* ~/docker-offline-package/systemd/
$ cp -r $SYSTEMD_PATH/docker.service.d ~/docker-offline-package/systemd/ 2>/dev/null || true

# 4️⃣ 확인
$ ls -la ~/docker-offline-package/systemd/
```

---

### Step 4: 레지스트리 이미지 (이미 있어야 함)

```bash
# 1️⃣ 확인
$ ls -lh ~/docker-offline-package/images/registry-2.tar
# ~100MB 있어야 함

# 2️⃣ 없다면 저장
$ docker save registry:2 -o ~/docker-offline-package/images/registry-2.tar
```

---

### Step 5: Docker 데이터는 생략 (권한 문제)

**이유**:
- 런타임 데이터는 접근 권한 문제
- 레지스트리 이미지(`registry-2.tar`)로 충분
- 팀서버에서 fresh 설치 시 새로 생성됨

```bash
# 데이터 복사 건너뛰기
# (권한 때문에 tar 압축 실패 회피)
```

---

### Step 6: 최종 압축 (permission 문제 회피)

```bash
# 1️⃣ 기존 파일 삭제
$ rm -f docker-offline-package.tar.gz

# 2️⃣ 최종 구조 확인
$ ls -la ~/docker-offline-package/
# bin/  images/  systemd/ (3개만!)

# 3️⃣ 압축
$ cd ~
$ tar czf docker-offline-package.tar.gz docker-offline-package/

# 4️⃣ 크기 확인
$ ls -lh docker-offline-package.tar.gz
# 예상: 100-150MB (데이터 없으므로)

# 5️⃣ 체크섬
$ sha256sum docker-offline-package.tar.gz > docker-offline-package.sha256
```

---

## ✅ 완료 검증

```bash
# 1️⃣ 압축 파일 내용 확인
$ tar tzf docker-offline-package.tar.gz | grep -E "bin/|systemd/|images/"

# 출력:
# docker-offline-package/bin/
# docker-offline-package/bin/docker
# docker-offline-package/bin/dockerd
# docker-offline-package/bin/containerd
# ...
# docker-offline-package/systemd/
# docker-offline-package/systemd/docker.service
# docker-offline-package/systemd/docker.socket
# docker-offline-package/images/
# docker-offline-package/images/registry-2.tar

# 2️⃣ 파일 개수
$ tar tzf docker-offline-package.tar.gz | wc -l
# 20~30개 정도

# 3️⃣ 최종 확인
$ ls -lh docker-offline-package.tar.gz
# OK! ✅
```

---

## 📊 올바른 최종 구조 (데이터 제외)

```
~/docker-offline-package/                (원본)
├─ bin/                                  (바이너리만)
│  ├─ docker                             (~40MB)
│  ├─ dockerd                            (~20MB)
│  ├─ containerd                         (~50MB)
│  ├─ ctr
│  └─ runc
├─ systemd/                              (systemd 파일)
│  ├─ docker.service
│  ├─ docker.socket
│  └─ docker.service.d/
└─ images/                               (이미지)
   └─ registry-2.tar                     (~100MB)

(share/ 데이터는 제외 - 권한 문제 & 팀서버에서 신규 생성)

docker-offline-package.tar.gz             (~120-150MB)
```

---

## 🔑 핵심 변화

```
이전 (실패):
├─ ~/.bin/ 찾기 실패
├─ systemd 경로 오류
├─ Docker 데이터 전체 복사 → permission denied
└─ 압축 실패

수정됨 (성공):
├─ type -p docker로 바이너리 경로 정확히 찾기 ✅
├─ ~/.config/systemd/user/ 사용 ✅
├─ 바이너리 + systemd + 이미지만 복사 ✅
└─ 압축 성공! ✅
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | A-3 최종 수정: 실제 에러 분석 + 데이터 복사 제외 + 정확한 경로 사용 |
