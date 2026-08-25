# Docker Registry 오프라인 배포 프로젝트

## 📋 개요

팀서버(Oracle Linux 8.10)에 **완전 오프라인 환경**에서 Docker Registry를 설치하고 배포하는 프로젝트입니다.

**특징**:
- 인터넷 차단된 환경에서도 설치 가능
- 모든 바이너리와 이미지를 오프라인 패키지로 포함
- 히스토리 관리 및 재설치 가능한 스크립트 포함

---

## 📁 프로젝트 구조

```
Docker/
├── README.md                           # 이 파일
├── FINAL-SETUP-SUMMARY.md             # 최종 완료 보고서
├── PHASE-D-FIREWALL-APPROVAL.md       # 방화벽 오픈 대기 (다음주)
│
├── teamserver-docker-setup.sh         # 팀서버 자동 설치 스크립트 ⭐
│
├── [이전 단계 문서들 (참고용)]
├── PHASE-A-CLEAN-REBUILD.md
├── PHASE-A-WORKING-VERSION.md
├── PHASE-A-ACTUAL-ERRORS-FIXED.md
├── PHASE-C-TEAMSERVER-INSTALL.md
└── EXECUTION-PLAN-FINAL.md
```

---

## 🚀 빠른 시작

### 1️⃣ 사전 조건

**팀서버에서 필요한 것**:
- Oracle Linux 8.10 이상
- `sudo` 권한 (servicetech2 사용자)
- 외부 VM에서 생성한 `docker-offline-package.tar.gz` 파일

**위치**:
```bash
/home/servicetech2/upload/docker/docker-offline-package.tar.gz
/home/servicetech2/upload/docker/docker-offline-package.sha256
```

### 2️⃣ 설치 실행

```bash
# 팀서버에서 실행
cd /home/servicetech2/upload/docker/

# 스크립트 권한 설정
chmod +x teamserver-docker-setup.sh

# 설치 실행
./teamserver-docker-setup.sh
```

### 3️⃣ 설치 완료 확인

```bash
# Docker 버전 확인
docker --version

# Registry 상태 확인
sudo docker ps

# Registry API 테스트
curl http://localhost:5000/v2/
# 예상 응답: {}
```

---

## 📚 상세 문서

### 📖 메인 문서

| 문서 | 설명 | 상태 |
|------|------|------|
| **FINAL-SETUP-SUMMARY.md** | 최종 완료 보고서 (전체 내용) | ✅ 완료 |
| **PHASE-D-FIREWALL-APPROVAL.md** | 방화벽 오픈 요청 및 대기 | ⏳ 진행 중 |

### 🔧 참고 문서 (이전 단계)

| 문서 | 내용 |
|------|------|
| PHASE-A-CLEAN-REBUILD.md | 외부 VM에서 패키지 생성 절차 |
| PHASE-A-WORKING-VERSION.md | 바이너리 경로 확정 |
| PHASE-A-ACTUAL-ERRORS-FIXED.md | 발생한 에러 및 해결 방법 |
| PHASE-C-TEAMSERVER-INSTALL.md | 팀서버 설치 상세 절차 |

---

## 🔗 주요 정보

### Registry 접근

**주소**: `http://new-servicetech2-1:5000`

**테스트 명령어**:
```bash
# 로컬 테스트
curl http://localhost:5000/v2/

# Docker 클라이언트에서 사용
docker pull new-servicetech2-1:5000/some-image
docker push new-servicetech2-1:5000/my-image
```

### 파일 경로

| 항목 | 경로 |
|------|------|
| Docker 바이너리 | `/usr/local/bin/docker*` |
| Docker 소켓 | `/var/run/docker.sock` |
| systemd 파일 | `/etc/systemd/system/docker.service` |
| Registry 컨테이너 | 실행 중 (포트 5000) |

### 서비스 관리

```bash
# Docker 서비스 상태
sudo systemctl status docker

# 재시작
sudo systemctl restart docker

# 로그 확인
sudo docker logs registry

# Registry 컨테이너 상태
sudo docker ps
```

---

## ⏳ 방화벽 설정 (다음주)

### 현재 상태
- ⏳ 팀장님 휴가 중 (예상 복귀: 2026-08-25)
- ⏳ 방화벽 오픈 대기

### 승인 후 설정

```bash
# 팀장님 승인 후 실행
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --reload

# 확인
sudo firewall-cmd --list-all | grep 5000
```

---

## 🔄 히스토리 관리

### 재설치 방법

현재 설정을 다시 적용해야 할 경우:

```bash
# 1. 설치 스크립트 실행
./teamserver-docker-setup.sh

# 2. 설정 확인
docker --version
sudo docker ps
curl http://localhost:5000/v2/
```

### 변경 이력

| 날짜 | 항목 | 상태 |
|------|------|------|
| 2026-08-18 | Docker 설치 및 Registry 실행 | ✅ 완료 |
| 2026-08-18 | 최종 보고서 작성 | ✅ 완료 |
| 2026-08-25 (예정) | 방화벽 오픈 | ⏳ 대기 |

---

## ❓ FAQ

### Q: Registry에 이미지를 올릴 수 없습니다
**A**: 방화벽이 아직 오픈되지 않았을 가능성이 높습니다. 팀장님 승인 후 포트 5000을 오픈하세요.

### Q: Docker 명령어가 작동하지 않습니다
**A**: `docker ps` 앞에 `sudo`를 붙이세요. 또는:
```bash
sudo usermod -aG docker servicetech2
sudo systemctl restart docker
```

### Q: Registry 로그를 확인하려면?
**A**: 
```bash
sudo docker logs registry        # 최근 로그
sudo docker logs -f registry     # 실시간 로그
```

### Q: Rootless로 변경할 수 있나요?
**A**: 네, 추후에 가능합니다. `FINAL-SETUP-SUMMARY.md`의 "추후 계획" 섹션을 참고하세요.

---

## 📞 문의

**담당자**: servicetech2@new-servicetech2-1  
**팀**: 개발팀  
**생성일**: 2026-08-18

---

## 📝 변경 이력

| 버전 | 날짜 | 내용 |
|------|------|------|
| 1.0 | 2026-08-18 | 초기 완료 버전 |
