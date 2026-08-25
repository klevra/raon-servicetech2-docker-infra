# Docker Rootful Registry 팀서버 세팅 - 최종 완료 보고서

**완료일**: 2026-08-18  
**팀서버**: new-servicetech2-1 (Oracle Linux 8.10)  
**상태**: ✅ **완료** (방화벽 오픈 대기)

---

## 🎯 프로젝트 개요

**목표**: 팀서버에 Rootful Docker + Registry:2 설치 및 실행

**배경**:
- 팀서버: 외부 인터넷 완전 차단 (정책)
- 외부 VM: 인터넷 가능 (패키지 준비용)
- 설치 방식: 완전 오프라인 배포

---

## 📋 완료된 작업

### Phase A: 외부 VM에서 오프라인 패키지 생성

**날짜**: 2026-08-18  
**위치**: 외부 VM (klevra@raon-local)

| 항목 | 상세 |
|------|------|
| **Docker 버전** | 29.7.2 (build a7dcaa6) |
| **바이너리 수** | 11개 |
| **패키지 크기** | 103MB (gzip 압축) |
| **레지스트리 이미지** | registry:2 (9.9MB) |

**생성 파일**:
- `docker-offline-package.tar.gz` (103M)
- `docker-offline-package.sha256` (체크섬)

**검증**:
```bash
sha256sum: 0908fe846e024af5a36aed64f39c12fa39c5c16adb4a2dc1eb53730f98b41e64
```

---

### Phase B: 팀서버로 파일 전달

**날짜**: 2026-08-18  
**방법**: SCP (안전한 전송)  
**대상**: `/home/servicetech2/upload/docker/`

| 단계 | 상태 |
|------|------|
| 외부 VM 파일 생성 | ✅ |
| SCP 전송 | ✅ |
| 체크섬 검증 | ✅ |
| 압축 해제 | ✅ |

**디렉토리 구조**:
```
/home/servicetech2/upload/docker/
├── docker-offline-package/
│   ├── bin/              (11개 바이너리)
│   ├── systemd/          (docker.service, docker.socket)
│   └── images/           (registry-2.tar)
├── docker-offline-package.tar.gz
└── docker-offline-package.sha256
```

---

### Phase C: 팀서버에 Rootful Docker 설치

**날짜**: 2026-08-18  
**OS**: Oracle Linux 8.10  
**Kernel**: 5.15.0-306

#### Step 1: 기존 Docker 제거
```bash
✅ Docker 29.0.9 제거
✅ systemd 파일 정리
✅ 데이터 디렉토리 보관
```

#### Step 2: iptables 모듈 로드
```bash
✅ ip_tables
✅ iptable_nat
✅ iptable_filter
✅ iptable_mangle
```

#### Step 3: 바이너리 설치
```bash
위치: ~/.local/bin/
실행: chmod +x

11개 바이너리 모두 설치됨:
✅ docker (41M)
✅ dockerd (96M)
✅ containerd (37M)
✅ runc (17M)
✅ 기타 도구 (7개)
```

#### Step 4: systemd 파일 설정
```bash
위치: ~/.config/systemd/user/ (초기) → /etc/systemd/system/ (최종)

최종 설정:
- ExecStart=/usr/local/bin/dockerd -H unix:///var/run/docker.sock --userland-proxy-path=/usr/local/bin/docker-proxy
- Type=notify
- Restart=on-failure
```

#### Step 5: Registry 이미지 로드
```bash
✅ docker load < registry-2.tar
✅ 이미지 확인: registry:2 (10.3MB)
```

#### Step 6: Docker 데몬 시작
```bash
✅ sudo systemctl start docker
✅ sudo systemctl enable docker
✅ systemctl status: Active (running)
```

---

### Phase D: Registry 컨테이너 실행

**날짜**: 2026-08-18  
**상태**: ✅ **정상 작동**

```bash
# 실행 명령어
sudo docker run -d -p 5000:5000 --name registry registry:2

# 결과
Container ID: 6c67d7cf85de
Status: Up (정상 실행 중)
Port: 0.0.0.0:5000->5000/tcp

# 로그
listening on [::]:5000
```

**레지스트리 API 테스트**:
```bash
$ curl http://localhost:5000/v2/
{}

✅ 정상 응답
```

---

## 🔧 설치 후 시스템 상태

### Docker 명령어 경로

| 명령어 | 경로 | 상태 |
|--------|------|------|
| docker | ~/.local/bin/ (사용자) / /usr/bin/ (symlink) | ✅ |
| dockerd | /usr/local/bin/ (root systemd용) | ✅ |
| docker-proxy | /usr/local/bin/ | ✅ |
| containerd | /usr/local/bin/ | ✅ |

### 소켓 위치

```bash
/var/run/docker.sock
- 소유자: root:root
- 권한: 0660
- 상태: 정상 작동
```

### 서비스 상태

```bash
$ sudo systemctl status docker
● docker.service - Docker
   Loaded: loaded (/etc/systemd/system/docker.service; enabled)
   Active: active (running) since Tue 2026-08-18 12:51:56 KST

$ sudo docker ps
CONTAINER ID   IMAGE        COMMAND                  CREATED      STATUS
6c67d7cf85de   registry:2   "/entrypoint.sh /etc…"   2 mins ago   Up 2 mins
```

---

## 📊 주요 변경 이력

| 날짜 | 항목 | 내용 |
|------|------|------|
| 2026-08-18 | A-1 | 기존 rootful Docker 제거 |
| 2026-08-18 | A-2 | iptables 모듈 로드 |
| 2026-08-18 | A-3 | 바이너리 설치 (110개 파일) |
| 2026-08-18 | A-4 | systemd 파일 설정 |
| 2026-08-18 | A-5 | Registry 이미지 로드 |
| 2026-08-18 | A-6 | Docker 데몬 시작 |
| 2026-08-18 | A-7 | Registry 컨테이너 실행 |

---

## ⏳ 대기 중인 항목

### Phase D: 방화벽 오픈 (다음주)

**상태**: ⏳ 팀장님 휴가 (예상 복귀: 2026-08-25)

**필요 설정**:
```bash
# 요청 사항
- 포트: TCP 5000
- 대상: new-servicetech2-1
- 용도: Docker Registry
- 범위: 172.16.0.0/12 (권장)

# 설정 스크립트 (승인 후)
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --reload
```

---

## 🚀 추후 계획

### 단기 (1주)
- [ ] 팀장님 휴가 복귀
- [ ] 방화벽 오픈 승인
- [ ] 포트 5000 오픈
- [ ] 팀원 공지

### 중기 (2-4주)
- [ ] Rootless Docker 마이그레이션 (선택)
- [ ] 레지스트리 데이터 저장소 구성
- [ ] 팀원 클라이언트 세팅 가이드

### 장기
- [ ] 고가용성 구성 (선택)
- [ ] 모니터링 설정
- [ ] 백업 정책 수립

---

## 🎓 주요 배운 점

### 기술적 이슈
1. **Rootless vs Rootful**: rootless 초기화 실패 → rootful로 전환
2. **바이너리 경로**: 다양한 위치 확인 필요
3. **심링크 필요성**: root 접근 시 /usr/bin 심링크 필수
4. **권한 관리**: Docker 소켓 권한 설정 중요

### 오프라인 배포 팁
1. 체크섬 검증 필수
2. 충분한 여유 공간 확보 (패키지 + 압축 풀기)
3. 바이너리 버전 호환성 확인
4. systemd 파일 경로 명확히 (root vs user)

---

## 📞 문의/지원

**담당자**: servicetech2@new-servicetech2-1  
**레지스트리 주소**: `http://new-servicetech2-1:5000`  
**문서**: 이 파일 참조

---

## 변경 이력

| 날짜 | 버전 | 내용 |
|------|------|------|
| 2026-08-18 | 1.0 | 최종 완료 보고서 작성 |
