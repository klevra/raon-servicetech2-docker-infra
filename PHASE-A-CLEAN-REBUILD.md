# Phase A: 깨끗한 재구성 (처음부터 다시)

**현재 문제**:
- registry-2.tar: 9.9MB (작음, 100MB 예상)
- 루트에 중복 파일
- 일부 바이너리 누락

**해결**: 모든 파일 제거 후 깨끗하게 다시 구성

---

## 🔧 Step 1: 기존 파일 모두 정리

```bash
# 1️⃣ 기존 디렉토리 완전 삭제
$ rm -rf ~/docker-offline-package
$ rm -f ~/docker-offline-package.tar.gz
$ rm -f ~/docker-offline-package.sha256

# 2️⃣ 확인
$ ls -la ~/ | grep docker-offline
# (아무것도 안 나와야 함)
```

---

## 🔧 Step 2: 깨끗한 디렉토리 구성

```bash
# 1️⃣ 새 디렉토리 생성
$ mkdir -p ~/docker-offline-package/{bin,systemd,images}

# 2️⃣ 확인
$ ls -la ~/docker-offline-package/
# bin/  images/  systemd/ (3개만)
```

---

## 🔧 Step 3: 바이너리 정확하게 복사

```bash
# 1️⃣ 바이너리 경로 확인
$ DOCKER_BIN=$(dirname $(type -p docker))
$ echo $DOCKER_BIN
# /home/klevra/bin 나와야 함

# 2️⃣ 모든 바이너리 복사 (find로 정확하게)
$ find $DOCKER_BIN -maxdepth 1 -type f -executable -exec cp {} ~/docker-offline-package/bin/ \;

# 3️⃣ 확인
$ ls -lh ~/docker-offline-package/bin/
# docker, dockerd, containerd, ctr, runc 등 11개 모두 있는지 확인
$ ls -1 ~/docker-offline-package/bin/ | wc -l
# 11개 나와야 함
```

---

## 🔧 Step 4: systemd 파일 정확하게 복사

```bash
# 1️⃣ systemd 경로 확인
$ SYSTEMD_PATH="$HOME/.config/systemd/user"

# 2️⃣ 파일 복사
$ find $SYSTEMD_PATH -name "docker*" -type f -exec cp {} ~/docker-offline-package/systemd/ \;
$ find $SYSTEMD_PATH -name "docker.service.d" -type d -exec cp -r {} ~/docker-offline-package/systemd/ \;

# 3️⃣ 확인
$ ls -la ~/docker-offline-package/systemd/
# docker.service, docker.socket 있는지 확인
```

---

## 🔧 Step 5: registry-2.tar 새로 저장 (정확하게)

```bash
# 1️⃣ 기존 이미지 삭제
$ rm -f ~/docker-offline-package/images/registry-2.tar

# 2️⃣ 다시 저장 (정확하게)
$ docker save registry:2 > ~/docker-offline-package/images/registry-2.tar

# 3️⃣ 크기 확인 (100MB 전후 여야 함!)
$ ls -lh ~/docker-offline-package/images/registry-2.tar
# 예상: 95-110MB 정도
```

---

## 🔧 Step 6: 최종 구조 확인

```bash
# 1️⃣ 전체 구조 확인
$ find ~/docker-offline-package -type f | sort

# 2️⃣ 디렉토리별 크기
$ du -sh ~/docker-offline-package/*
# bin/: 140MB 정도
# images/: 95-110MB (registry-2.tar)
# systemd/: 10KB 정도

# 3️⃣ 파일 개수
$ find ~/docker-offline-package -type f | wc -l
# 15-20개 정도
```

---

## 🔧 Step 7: 최종 압축

```bash
# 1️⃣ 압축 (중복 파일 없어야 함)
$ cd ~
$ tar czf docker-offline-package.tar.gz docker-offline-package/

# 2️⃣ 최종 크기 확인
$ ls -lh docker-offline-package.tar.gz
# 예상: 150-180MB (이전 70MB와 다름!)

# 3️⃣ 체크섬 생성
$ sha256sum docker-offline-package.tar.gz > docker-offline-package.sha256
$ cat docker-offline-package.sha256
```

---

## ✅ Step 8: 최종 검증

```bash
# 1️⃣ 압축 파일 내용 확인
$ tar tzf docker-offensive-package.tar.gz | grep -E "bin/|systemd/|images/" | head -20

# 2️⃣ 핵심 파일 모두 있는지 확인
$ tar tzf docker-offline-package.tar.gz | grep -E "docker|docker.service|registry-2.tar"

# 3️⃣ 파일 개수 최종 확인
$ tar tzf docker-offline-package.tar.gz | wc -l
# 15-20개 정도 나와야 함
```

---

## 📊 예상 최종 구조

```
docker-offline-package/
├─ bin/                          (11개 바이너리, 140MB)
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
├─ systemd/                      (3개 파일)
│  ├─ docker.service
│  ├─ docker.socket
│  └─ docker.service.d/
└─ images/                       (1개 파일, 100MB)
   └─ registry-2.tar

docker-offline-package.tar.gz    (150-180MB)
```

---

## ✅ 완료 기준

- ✅ docker-offline-package.tar.gz: 150-180MB
- ✅ 파일 개수: 15-20개
- ✅ registry-2.tar: 100MB 전후
- ✅ 모든 바이너리 포함
- ✅ systemd 파일 포함

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | Phase A 깨끗한 재구성. 기존 파일 정리 후 정확한 절차로 다시 구성 |
