# 🔴 중대 네트워크 제약: 팀서버 완전 오프라인 확정

**작성일**: 2026-08-18  
**상태**: 🔴 **CRITICAL - 현재 계획 변경 필요**  
**영향도**: Rootless Docker 설치 불가능 (온라인 모드에서)

---

## 📊 진단 결과 한눈에 보기

| 항목 | 상태 | 결과 |
|------|------|------|
| DNS 작동 | ✅ 예 | get.docker.com → 정상 응답 |
| 외부 인터넷 | ❌ 차단 | 8.8.8.8, 1.1.1.1 ping 100% loss |
| Docker Hub 접근 | ❌ 불가 | timeout (응답 없음) |
| Docker 저장소 | ❌ 미등록 | dnf에서 docker-ce 패키지 없음|
| 기존 Docker | ✅ 설치됨 | rootful 데몬 실행 중 |

**결론**: 🔴 **완전 오프라인 환경 (시나리오 D)**

---

## 🚨 즉시 대응 필요

### 현재 문제
```
기존 배포 계획 (온라인 모드)
├─ Phase 1: Rootful 제거 ✅ 가능
├─ Phase 2: Rootless 설치 ❌ 불가능 (dnf 패키지 접근 불가)
├─ Phase 4: 레지스트리 구성 ⚠️ 이미지 없음
└─ = 현재 계획 전면 중단 필요
```

---

## 📋 변경된 실행 계획

### A. IT팀 협의 (가장 중요!)

**즉시 요청**:
```
1. 네트워크 정책 확인
   - 현재 완전 차단 사유
   - Docker Hub 특별 허용 가능 여부
   - 프록시/미러 서버 존재 여부

2. 오프라인 설치 지원
   - Docker 바이너리 제공 가능 여부
   - 전달 방법 (USB/네트워크 드라이브)
   - 소요 시간 및 절차
```

---

### B. 임시 조치 (대기 중)

**현재 가능한 것**:
- ✅ 기존 rootful Docker 계속 사용 가능
- ✅ 로컬 이미지 작업 가능 (pull 불가, load만 가능)
- ✅ 레지스트리 기존 데이터 유지

**금지할 것**:
- ❌ Docker 제거하지 말 것 (다시 설치 불가)
- ❌ Phase 1 실행 중지
- ❌ systemctl stop docker 금지

**유지**:
```bash
# 현재 상태 유지
sudo systemctl status docker
sudo docker ps -a
sudo docker images

# (Docker Hub pull 불가이므로 새 이미지 다운로드는 불가)
```

---

### C. 향후 설치 시나리오 (선택사항)

#### 시나리오 1: IT팀이 프록시 제공 (최선)
```
장점: 기존 설치 계획 그대로 진행 가능
단계: 프록시 설정 → Phase 1~6 진행
```

#### 시나리오 2: IT팀이 바이너리 제공 (차선)
```
장점: 완전 오프라인에서도 설치 가능
단계: 바이너리 받기 → 수동 설치 (별도 절차)
```

#### 시나리오 3: 부분 화이트리스트 (절차상 복잡)
```
장점: 최소 필요 도메인만 허용
단계: 화이트리스트 요청 → 재설치 시도
```

#### 시나리오 4: 현 상태 유지 (불가피)
```
제약: 기존 rootful 유지만 가능
장점: 즉시 변경 없음
```

---

## 📞 IT팀 요청 이메일 템플릿

```
제목: [긴급] 팀서버 Docker Rootless 설치를 위한 네트워크 정책 확인

안녕하세요,

팀서버(Oracle Linux 8.10, new-servicetech2-1)에 Docker를 
rootful에서 rootless로 전환하려는 작업 중에 
다음과 같은 네트워크 제약이 발견되었습니다.

[진단 결과]
- DNS: 작동 (내부 DNS만)
- 외부 인터넷: 완전 차단 (ping 8.8.8.8/1.1.1.1 = 100% loss)
- Docker Hub (registry.hub.docker.com): 접근 불가
- Docker 저장소 (download.docker.com): 접근 불가

이로 인해 다음을 확인해주실 수 있는지 요청드립니다:

[요청 사항]
1. 현재 네트워크 정책상 이것이 의도된 차단인지 확인
2. Docker Hub 특별 허용 가능 여부
3. 프록시/미러 서버 설정 가능 여부
4. 오프라인 설치를 위한 바이너리 제공 가능 여부

[현재 상태]
- 기존 rootful Docker: 정상 운영 중 (제거하지 않음)
- 다른 기능: 정상

감사합니다.
```

---

## 📋 IT팀 응답 시나리오별 대응

### ✅ 응답 1: "프록시 설정 가능합니다"
```
→ 프록시 주소/포트 받기
→ docker-proxy-setup.md 작성
→ Phase 0 프록시 설정 추가
→ Phase 1~6 원래대로 진행 가능
```

### ✅ 응답 2: "바이너리 제공 가능합니다"
```
→ 바이너리 받기 (containerd, docker-ce, docker-ce-cli 등)
→ docker-offline-installation.md 작성
→ Phase 1~2 오프라인 설치 절차 실행
```

### ✅ 응답 3: "Docker Hub 특별 허용 가능합니다"
```
→ 화이트리스트 적용 대기
→ 핑 테스트로 재확인
→ 정상되면 기존 Phase 0~6 진행
```

### ⚠️ 응답 4: "변경 불가능합니다"
```
→ 기존 rootful Docker 유지
→ 필요시 root 권한 강화 정책 검토
→ Rootless 전환 불가능 문서화
```

---

## 🚫 금지 사항 (매우 중요!)

**다음을 하지 마세요**:

```bash
# ❌ 절대 금지!
sudo systemctl stop docker
sudo dnf remove docker-ce
docker system prune -a

# 이유: 
# - 제거한 후 재설치 불가능 (저장소 접근 불가)
# - 기존 기능까지 손상됨
```

---

## ✅ 현재 할 수 있는 것

```bash
# ✅ 가능한 작업
sudo docker --version
sudo docker ps -a
sudo docker images
sudo docker inspect [container]

# ✅ 로컬 이미지 작업 (pull 제외)
docker load < registry-2.tar      # 이미지 파일이 있다면
docker tag [image] [new-name]
docker run ... [local-image]
```

---

## 📝 다음 단계 체크리스트

- [ ] **즉시**: IT팀에 위 메일 발송
- [ ] **대기 중**: 응답 기다리기 (1~2일 소요 예상)
- [ ] **대기 중**: 기존 Docker 유지 (변경 금지)
- [ ] **대기 중**: IT팀 응답 시나리오별 대응 준비
- [ ] **응답 후**: 해당 시나리오의 상세 절차 문서화

---

## 📚 관련 문서

- [TEAMSERVER-OFFLINE-DIAGNOSIS.md](TEAMSERVER-OFFLINE-DIAGNOSIS.md) — 상세 진단 결과
- [TEAM-SERVER-NETWORK-CHECK.md](TEAM-SERVER-NETWORK-CHECK.md) — Phase 0 (현재 상태)
- DEPLOYMENT-GUIDE.md — 기존 계획 (현재 **일시 중단**)

---

## 📞 담당자 연락처

- **팀서버 관리**: servicetech2
- **IT팀**: [IT팀 메일/전화]
- **Docker 설치 담당**: [현재 사용자]

---

**상태**: 🔴 **CRITICAL - 즉시 IT팀 협의 필요**

**다음 진행 시간**: IT팀 응답까지 **대기**

