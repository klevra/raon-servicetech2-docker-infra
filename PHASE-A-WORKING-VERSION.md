# Phase A: 작동하는 최종 버전 (로그 기반)

**실제 실행 결과 분석**

---

## 🔍 확인된 정보

### 1. 바이너리 위치 (확정!) ✅
```bash
$ ls bin/
containerd  containerd-shim-runc-v2  ctr  docker  dockerd  
dockerd-rootless-setuptool.sh  dockerd-rootless.sh  docker-init  
docker-proxy  rootlesskit  runc

$ type -p docker && realpath $(type -p docker)
/home/klevra/bin/docker
/home/klevra/bin/docker
```

**결론**: 바이너리는 `~/bin/` 에 있음 ✅

---

### 2. 현재 문제점

#### ❌ registry-2.tar 없음
```
ls -lh ~/docker-offline-package/images/registry-2.tar
ls: cannot access '/home/klevra/docker-offline-package/images/registry-2.tar': No such file or directory
```

**해결**: 다시 저장 필요

---

#### ⚠️ share 디렉토리 permission denied
```
tar: docker-offline-package/share/docker/containerd/daemon/io.containerd.snapshotter...
tar: Exiting with failure status due to previous errors
```

**해결**: share 디렉토리 제거

---

### 3. 압축 파일 생성됨 (79MB) ✅
```
ls -lh docker-offline-package.tar.gz
-rw-r--r-- 1 klevra klevra 79M Aug 18 11:39 docker-offline-package.tar.gz
```

---

## ✅ 지금 바로 실행할 수정 단계

### Step 1: share 디렉토리 제거

```bash
# 1️⃣ 현재 구조 확인
$ ls -la ~/docker-offline-package/
# share/ 있는지 확인

# 2️⃣ share 디렉토리 제거
$ rm -rf ~/docker-offline-package/share

# 3️⃣ 확인
$ ls -la ~/docker-offline-package/
# bin/  images/  systemd/ (3개만 남아야 함)
```

---

### Step 2: registry-2.tar 다시 저장

```bash
# 1️⃣ Docker 데몬 상태 확인
$ systemctl --user status docker
# Active (running) 이어야 함

# 2️⃣ 레지스트리 이미지 저장
$ docker save registry:2 -o ~/docker-offline-package/images/registry-2.tar

# 3️⃣ 파일 확인
$ ls -lh ~/docker-offline-package/images/registry-2.tar
# ~100MB 있어야 함
```

---

### Step 3: 최종 압축

```bash
# 1️⃣ 기존 파일 삭제
$ rm -f docker-offline-package.tar.gz

# 2️⃣ 최종 구조 확인
$ ls -la ~/docker-offline-package/
# bin/  images/  systemd/ (3개)

# 3️⃣ 압축
$ cd ~
$ tar czf docker-offline-package.tar.gz docker-offline-package/

# 4️⃣ 크기 확인
$ ls -lh docker-offline-package.tar.gz
# 예상: 150-200MB (registry-2.tar 포함)

# 5️⃣ 체크섬
$ sha256sum docker-offline-package.tar.gz > docker-offline-package.sha256
```

---

## ✅ 최종 검증

```bash
# 1️⃣ 압축 파일 내용 확인
$ tar tzf docker-offline-package.tar.gz | grep -E "bin/docker|docker.service|registry-2.tar"

# 예상 출력:
# docker-offline-package/bin/docker
# docker-offline-package/bin/dockerd
# docker-offline-package/bin/containerd
# docker-offline-package/bin/runc
# docker-offline-package/bin/ctr
# docker-offline-package/bin/containerd-shim-runc-v2
# docker-offline-package/bin/docker-proxy
# docker-offline-package/bin/docker-init
# docker-offline-package/bin/dockerd-rootless-setuptool.sh
# docker-offline-package/bin/dockerd-rootless.sh
# docker-offline-package/bin/rootlesskit
# docker-offline-package/systemd/docker.service
# docker-offline-package/systemd/docker.socket
# docker-offline-package/images/registry-2.tar

# 2️⃣ 최종 크기 확인
$ ls -lh docker-offline-package.tar.gz
# 예상: 150-200MB
```

---

## 📊 최종 구조 (정확함)

```
~/docker-offline-package/
├─ bin/                          (11개 바이너리)
│  ├─ containerd
│  ├─ containerd-shim-runc-v2
│  ├─ ctr
│  ├─ docker
│  ├─ dockerd
│  ├─ dockerd-rootless-setuptool.sh
│  ├─ dockerd-rootless.sh
│  ├─ docker-init
│  ├─ docker-proxy
│  ├─ rootlesskit
│  └─ runc
├─ systemd/                      (systemd 파일)
│  ├─ docker.service
│  ├─ docker.socket
│  └─ docker.service.d/
└─ images/                       (이미지)
   └─ registry-2.tar             (~100MB)

docker-offline-package.tar.gz    (~150-200MB)
```

---

## 🎯 핵심 수정사항

| 항목 | 문제 | 해결 |
|------|------|------|
| 바이너리 경로 | `~/.bin/` 오류 | `~/bin/` 확인됨 ✅ |
| systemd 경로 | `~/.config/systemd/user/` | 복사됨 ✅ |
| registry-2.tar | 없음 ❌ | 다시 저장 필요 |
| share 디렉토리 | Permission denied | 제거 필요 |

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | Phase A 최종 작동 버전. 바이너리 경로 확정 (~/bin/), registry-2.tar 재저장, share 제거 |
