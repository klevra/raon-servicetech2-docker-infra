# 팀서버 Rootless Docker 오프라인 배포 계획 (수정안)

작성일: 2026-08-18  
상황: 팀서버 완전 오프라인 + 외부 VM 서버 인터넷 가능  
전략: 2단계 배포 (외부 서버에서 준비 → 팀서버에 전달)

---

## 📋 현재 상황 정리

### ✅ 가용 자원

| 리소스 | 상태 | 용도 |
|--------|------|------|
| 팀서버 (new-servicetech2-1) | 🔴 완전 오프라인 | 최종 설치 대상 |
| 외부 VM (Oracle Linux 8.10) | ✅ 인터넷 가능 | 패키지/이미지 준비 |
| 기존 Docker (팀서버) | ✅ 설치됨 | 제거 후 공간 확보 |
| 이전 테스트 이미지 | ⚠️ 있음 | 제거 (미사용 확정) |
| 팀장 승인 | ✅ 있음 | 작업 권한 확인 |
| 패키지 반입 | ✅ 가능 | 파일 이동 수단 |

### 🔴 제약 사항

- 팀서버: 외부 인터넷 접근 불가 (정상 정책)
- 간접 설치: 모든 패키지/이미지를 사전 다운로드해야 함

---

## 🎯 새로운 배포 전략 (3단계)

### **Phase A: 외부 VM 서버에서 준비** (1~2시간)

**목표**: Rootless Docker 설치에 필요한 모든 파일 준비

#### A-1. 외부 VM 환경 확인

```bash
# 외부 VM에서 실행
uname -r
cat /etc/os-release
dnf --version
```

**예상 결과**:
- Oracle Linux 8.10
- Kernel 5.15.0-306 (또는 유사 버전)
- dnf 패키지 매니저 (팀서버와 동일)

#### A-2. Rootless Docker 설치 (외부 VM)

```bash
# 외부 VM에서만 실행 (팀서버 X)

# 1. 커널/시스템 준비
sudo dnf install -y docker-ce-rootless-extras

# 또는 공식 스크립트
curl -fsSL https://get.docker.com/rootless | bash

# 2. 설치 확인
~/.local/bin/docker --version
```

#### A-3. 필요한 파일 패키징

```bash
# 외부 VM에서 실행

# 1. Rootless Docker 바이너리 수집
mkdir -p ~/docker-offline-package/bin
cp ~/.local/bin/docker* ~/docker-offline-package/bin/
cp ~/.local/bin/containerd* ~/docker-offline-package/bin/
ls -lah ~/.local/lib/systemd/user/docker* | xargs -I {} cp {} ~/docker-offline-package/

# 2. 레지스트리 이미지 다운로드
docker pull registry:2
docker save registry:2 -o ~/docker-offline-package/registry-2.tar

# 3. 기타 필요한 이미지 (선택사항)
# docker pull alpine
# docker save alpine -o ~/docker-offline-package/alpine.tar

# 4. 패키징
cd ~
tar czf docker-offline-package.tar.gz docker-offline-package/
ls -lh docker-offline-package.tar.gz
```

**생성되는 파일**:
```
docker-offline-package.tar.gz (~100MB 예상)
├─ bin/               (바이너리)
├─ registry-2.tar     (레지스트리 이미지)
├─ alpine.tar         (선택사항)
└─ ...
```

---

### **Phase B: 팀서버로 파일 이동** (5~10분)

**방법**: USB/네트워크 드라이브/SCP 등

```bash
# 외부 VM에서
scp ~/docker-offline-package.tar.gz servicetech2@팀서버IP:~/

# 또는 USB로 복사
# /run/media/user/USB/ 에 복사

# 또는 파이썬 간단 서버
cd ~ && python3 -m http.server 8000
# 팀서버에서 wget http://외부VM_IP:8000/docker-offline-package.tar.gz
```

---

### **Phase C: 팀서버에서 설치** (20~30분)

#### C-0. 준비 (팀서버)

```bash
# 팀서버에서 실행 (현재 권한: servicetech2)

# 1. 현재 권한 확인
whoami
# → servicetech2

# 2. 패키지 파일 확인
ls -lh ~/docker-offline-package.tar.gz

# 3. 전개
mkdir -p ~/docker-prep
cd ~/docker-prep
tar xzf ~/docker-offline-package.tar.gz
ls -la docker-offline-package/
```

#### C-1. 기존 rootful Docker 제거 (팀서버)

```bash
# 팀서버에서 실행 (sudo 필요)

# 1. 기존 이미지 확인 (선택, 정보용)
sudo docker images

# 2. 기존 이미지 제거 (불필요 이미지만)
sudo docker rmi [image-id]  # 각 이미지별로

# 3. 데몬 중지
sudo systemctl stop docker
sudo systemctl disable docker

# 4. Docker 패키지 제거
sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 5. 확인
docker --version 2>&1 | grep "not found"
```

#### C-2. Rootless Docker 수동 설치 (팀서버)

```bash
# 팀서버에서 실행 (일반 사용자)

# 1. 바이너리 설치 경로 준비
mkdir -p ~/.local/bin

# 2. 바이너리 복사
cp ~/docker-prep/docker-offline-package/bin/docker* ~/.local/bin/
cp ~/docker-prep/docker-offline-package/bin/containerd* ~/.local/bin/
chmod +x ~/.local/bin/docker*
chmod +x ~/.local/bin/containerd*

# 3. PATH 추가 (필요시)
echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
source ~/.bashrc

# 4. systemd user 파일 설정 (복잡할 수 있으므로 외부 VM에서 준비)
# ~/.local/lib/systemd/user/docker.* 을 복사하거나
# 또는 dockerd-rootless-setuptool.sh 스크립트 사용

# 5. 검증
~/.local/bin/docker --version
```

#### C-3. 레지스트리 이미지 로드 (팀서버)

```bash
# 팀서버에서 실행

# 1. 이미지 로드
docker load < ~/docker-prep/docker-offline-package/registry-2.tar

# 2. 확인
docker images
# → registry:2 나타나야 함

# 3. 레지스트리 구성 (Phase D 참고)
```

---

### **Phase D: 레지스트리 구성** (10~15분)

#### D-1. 데이터 디렉터리 준비

```bash
# 팀서버에서 실행

mkdir -p ~/.docker/volumes/servicetech2-registry/data
ls -la ~/.docker/volumes/servicetech2-registry/
```

#### D-2. 레지스트리 컨테이너 실행

```bash
# 팀서버에서 실행

docker run -d \
  --name servicetech2-registry \
  --restart=always \
  -p 5000:5000 \
  -v ~/.docker/volumes/servicetech2-registry/data:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# 확인
docker ps
curl http://localhost:5000/v2/
```

---

## 📊 전체 흐름도

```
외부 VM (인터넷 가능)
├─ Phase A-1: 환경 확인
├─ Phase A-2: Rootless 설치
├─ Phase A-3: 파일 패키징
│  └─ docker-offline-package.tar.gz 생성
├─ 파일 이동 (USB/SCP 등)
│  ↓
팀서버 (오프라인)
├─ Phase B: 파일 수신 + 전개
├─ Phase C-1: 기존 Docker 제거
├─ Phase C-2: Rootless 설치
├─ Phase C-3: 레지스트리 이미지 로드
├─ Phase D: 레지스트리 구성
└─ ✅ 완료
```

---

## ⏱️ 소요 시간

| Phase | 내용 | 시간 |
|-------|------|------|
| A-1 | 외부 VM 환경 확인 | 5분 |
| A-2 | Rootless 설치 | 10분 |
| A-3 | 파일 패키징 | 10분 |
| B | 파일 이동 | 5~10분 |
| C-1 | 기존 Docker 제거 | 5분 |
| C-2 | Rootless 설치 | 10분 |
| C-3 | 이미지 로드 | 5분 |
| D | 레지스트리 구성 | 10분 |
| **총계** | | **~70분** |

---

## 📋 체크리스트

### 사전 준비
- [ ] 팀장 승인 확인 ✅ (이미 받음)
- [ ] 외부 VM 접근 권한 확인
- [ ] 파일 전달 방법 결정 (USB/SCP/드라이브)
- [ ] 필요한 이미지 목록 확인 (registry:2만으로 충분한가?)

### Phase A (외부 VM)
- [ ] 환경 확인 (OS, Kernel, dnf)
- [ ] Rootless 설치
- [ ] 이미지 다운로드
- [ ] 파일 패키징

### Phase B (파일 이동)
- [ ] 파일 생성 확인
- [ ] 파일 전달 방법 실행
- [ ] 팀서버에서 파일 수신 확인

### Phase C (팀서버 - 설치)
- [ ] 파일 전개
- [ ] 권한 확인 (servicetech2)
- [ ] 기존 Docker 제거
- [ ] Rootless 바이너리 설치
- [ ] 이미지 로드

### Phase D (팀서버 - 레지스트리)
- [ ] 디렉터리 준비
- [ ] 레지스트리 컨테이너 실행
- [ ] 정상 작동 확인

---

## 🚨 주의사항

### 필수 확인 (설치 전)

```bash
# 팀서버에서
sudo docker ps     # 기존 컨테이너 없는지 확인
sudo docker images # 제거할 이미지 확인
df -h              # 디스크 공간 확인 (~1GB 필요)
```

### 금지 사항

- ❌ 기존 Docker 바이너리 직접 사용 금지 (다른 버전/설정일 수 있음)
- ❌ Rootless 설치 중 root 계정 사용 금지
- ❌ 아직 `/etc/docker` 파일 수정 금지

### 롤백 (문제 발생 시)

```bash
# 팀서버에서
systemctl --user stop docker
rm -rf ~/.local/bin/docker*
# 다시 Phase C 실행
```

---

## 📚 이전 문서와의 관계

| 문서 | 상태 | 용도 |
|------|------|------|
| DEPLOYMENT-GUIDE.md | 일시 중단 | 기존 온라인 계획 |
| TEAM-SERVER-NETWORK-CHECK.md | 부분 사용 | Phase 0 (진단만) |
| CRITICAL-NETWORK-ALERT.md | 폐기 | IT팀 협의 불필요 |
| **OFFLINE-DEPLOYMENT-PLAN.md** | ✅ 활성 | 현재 계획 (이 문서) |

---

## 🔑 핵심 변화

### 이전 (온라인 모드, 불가능)
```
Phase 0: 네트워크 확인
Phase 1: Rootful 제거
Phase 2: dnf로 Rootless 설치 ← 불가능 (패키지 접근 불가)
```

### 현재 (오프라인 모드, 가능)
```
외부 VM:
  Phase A: 패키지/이미지 준비
  
파일 전달:
  Phase B: 패키지 이동
  
팀서버:
  Phase C: 수동 설치
  Phase D: 레지스트리 구성
```

---

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-18 | 오프라인 배포 계획 수립. 외부 VM 활용 + 2단계 배포 전략 |
