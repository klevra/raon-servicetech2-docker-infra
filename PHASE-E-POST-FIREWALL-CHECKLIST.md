# Phase E: 방화벽 오픈 완료 후 체크리스트

**상태**: ✅ **방화벽 오픈 완료** (2026-09-11)  
**다음 단계**: 팀원 환경 준비 + 레지스트리 기능 검증 + 운영 배포 준비

---

## 📋 우선순위별 체크리스트

### **PHASE 1: 팀서버 레지스트리 기본 검증 (1-2시간)**

#### 1.1 팀서버에서 로컬 테스트
```bash
# 팀서버 접속 (servicetech2 사용자)
ssh servicetech2@new-servicetech2-1

# Registry API 정상 응답 확인
curl http://localhost:5000/v2/
# 예상 결과: {}

# Registry 컨테이너 상태 확인
sudo docker ps | grep registry
# 예상 결과: registry:2 UP

# Registry 로그 확인
sudo docker logs -f registry
# 예상 결과: listening on [::]:5000
```

**체크 항목**:
- [ ] localhost:5000 접근 가능
- [ ] `/v2/` API 정상 응답 (HTTP 200)
- [ ] Registry 컨테이너 running 상태
- [ ] 로그에 에러 없음

---

#### 1.2 다른 호스트에서 원격 접근 테스트
```bash
# 내부 네트워크의 다른 PC에서 테스트
curl http://new-servicetech2-1:5000/v2/

# Docker 클라이언트가 설치된 PC에서
docker pull new-servicetech2-1:5000/library/alpine:latest
```

**체크 항목**:
- [ ] 다른 호스트에서 원격 API 접근 가능
- [ ] 방화벽이 5000/tcp 통과 허용
- [ ] DNS 또는 IP로 모두 접근 가능 확인

---

#### 1.3 방화벽 설정 확인
```bash
# 팀서버에서
sudo firewall-cmd --list-all

# 출력에 다음이 포함되어 있어야 함
# ports: 5000/tcp (또는 services에 포함)
```

**체크 항목**:
- [ ] firewall-cmd 출력에 5000/tcp 포함
- [ ] --permanent 설정으로 재부팅 후에도 유지
- [ ] 5000/tcp이 active 상태

---

### **PHASE 2: 팀원 Docker 클라이언트 환경 준비 (30분~1시간/인원당)**

#### 2.1 Docker insecure-registries 설정 (모든 팀원 PC)

**Windows (Docker Desktop)**:
```json
// Docker Desktop 설정 > Docker Engine
{
  "insecure-registries": ["new-servicetech2-1:5000"],
  "registry-mirrors": ["https://mirror.aliyun.com"]
}
```

**Linux**:
```bash
# /etc/docker/daemon.json 생성/편집
{
  "insecure-registries": ["new-servicetech2-1:5000"]
}

# Docker 재시작
sudo systemctl restart docker
```

**체크 항목**:
- [ ] daemon.json에 insecure-registries 설정
- [ ] Docker 데몬 재시작
- [ ] 설정 확인: `docker info | grep -A5 insecure`

---

#### 2.2 hosts 파일 등록 (선택사항, DNS가 있으면 불필요)

**Windows** (`C:\Windows\System32\drivers\etc\hosts`):
```
# 팀서버 IP를 정확히 입력
192.168.x.x  new-servicetech2-1
```

**체크 항목**:
- [ ] hosts 파일 수정 (관리자 권한 필요)
- [ ] ping new-servicetech2-1 성공

---

#### 2.3 레지스트리 접근 테스트 (각 팀원)
```bash
# Docker 테스트 이미지 pull 시도
docker pull new-servicetech2-1:5000/library/alpine:latest
```

**체크 항목**:
- [ ] pull 성공 (HTTP 200)
- [ ] 방화벽/네트워크 이슈 없음
- [ ] 각 팀원이 독립적으로 접근 가능 확인

---

### **PHASE 3: OmnioneCX 이미지 레지스트리 등록 확인 (30분)**

#### 3.1 현재 등록된 이미지 확인
```bash
# 팀서버에서
sudo docker images | grep omnionecx

# 또는 registry API로
curl http://localhost:5000/v2/_catalog
```

**체크 항목**:
- [ ] omnionecx2-db:aia
- [ ] omnionecx2-verifier:aia
- [ ] omnionecx2-oacx:aia
- [ ] omnionecx2-admin:aia
- [ ] omnionecx2-sample:aia

이미지가 없으면:
```bash
cd omnionecx/aia/db
./build-and-push.sh
```

---

### **PHASE 4: 팀원 PC에서 실제 배포 테스트 (1-2시간)**

#### 4.1 배포 스크립트 실행
```powershell
cd d:\99_project\Docker\sandbox
.\deploy.ps1

# 첫 프롬프트: 레지스트리 주소
# 입력값: new-servicetech2-1:5000
```

**체크 항목**:
- [ ] 레지스트리에서 모든 이미지 pull 성공
- [ ] docker-compose up -d 정상 실행
- [ ] 5개 서비스 모두 healthy 상태 도달

---

#### 4.2 배포 후 HTTP 접근 테스트
```bash
curl http://localhost:48085/                      # verifier
curl http://localhost:8080/oacx/api/              # oacx
curl http://localhost:6443/                       # admin
curl http://localhost:9025/                       # sample
```

**체크 항목**:
- [ ] verifier: HTTP 200
- [ ] oacx: HTTP 200
- [ ] admin: HTTP 200
- [ ] sample: HTTP 200

---

#### 4.3 DB 접근 테스트
```bash
# 로컬 터미널에서
docker exec sandbox-db mysql -u omnione -p0mN1DB VC_VERIFIER -e "SELECT COUNT(*) FROM VF_ORGANIZATION;"

# 결과: 1 (raon)
```

**체크 항목**:
- [ ] DB 접속 성공
- [ ] VF_ORGANIZATION에 raon 데이터 존재

---

### **PHASE 5: 최종 검증 (30분)**

#### 5.1 전체 엔드-투-엔드 테스트
```bash
1. curl http://new-servicetech2-1:5000/v2/        ✓ {}
2. docker ps                                       ✓ 5개 healthy
3. curl http://localhost:48085/                   ✓ 200
4. curl http://localhost:8080/oacx/api/           ✓ 200
5. curl http://localhost:6443/                    ✓ 200
6. curl http://localhost:9025/                    ✓ 200
```

**체크 항목**:
- [ ] 위 6단계 모두 성공
- [ ] 특별한 에러 없음

---

## 🆘 트러블슈팅 가이드

### 문제 1: "connection refused" (레지스트리 연결 실패)
```
원인: 방화벽 미설정 또는 네트워크 이슈
해결:
1. 팀서버: sudo firewall-cmd --list-all | grep 5000 확인
2. 클라이언트: ping new-servicetech2-1 확인
3. Docker: docker info | grep insecure 확인
```

### 문제 2: "no basic auth credentials" (레지스트리 인증 오류)
```
원인: insecure-registries 미설정
해결:
1. /etc/docker/daemon.json 확인
2. "insecure-registries": ["new-servicetech2-1:5000"] 추가
3. Docker 재시작: sudo systemctl restart docker
```

### 문제 3: "HibernateException" (aia verifier 기동 실패)
```
원인: JPA dialect 미설정
해결:
1. sandbox/verifier/config/application.yml 확인
2. org.hibernate.dialect.MariaDB103Dialect 설정 확인
3. verifier 재시작: docker restart verifier
```

### 문제 4: "SocketTimeoutException" (외부 호출 타임아웃)
```
원인: HTTP 타임아웃 설정 부족
해결:
1. mdl.sp.httpclient-conn-timeout >= 5000
2. connection.timeout >= 30000 (admin 등록 시)
```

### 문제 5: "인증사업자 정보를 찾을 수 없음" (QR 발급 실패)
```
원인: MyBatis 캐시 또는 partnerCode 불일치
해결:
1. 30초 대기 또는 docker restart oacx 실행
2. body.partnerCode = VF_ORGANIZATION.PARTNER_CODE 일치 확인
```

---

## ✅ 최종 승인 체크리스트

배포 준비 완료 판정:

- [ ] **레지스트리**: 팀서버 정상 작동, 방화벽 오픈, 외부 접근 가능
- [ ] **이미지**: OmnioneCX 5개 컴포넌트 모두 레지스트리에 등록
- [ ] **팀원 환경**: 모든 팀원이 insecure-registries 설정 완료
- [ ] **배포 테스트**: sandbox에서 e2e 완료, 5개 서비스 healthy
- [ ] **HTTP 테스트**: 모든 서비스 HTTP 200 응답
- [ ] **DB**: 초기 데이터 정상 로드
- [ ] **문서화**: 모든 가이드 최신화
- [ ] **GitHub**: 변경사항 커밋/푸시

---

## 📝 다음 단계

### 이번주
1. PHASE 1-5 완료
2. 팀원 피드백 수집
3. 문제점 해결

### 다음주
1. 운영 환경 배포 준비
2. 실제 운영 데이터 테스트
3. 모바일 지갑 e2e 테스트

---

**문서 생성일**: 2026-09-11  
**작성자**: claude  
**상태**: 진행 중
