# 📋 방화벽 오픈 완료 — 잔여사항 정리

**현재 상황**: 팀원들 방화벽 오픈 완료 (2026-09-11~09-12)  
**상태**: 🔄 배포 준비 단계 진행 중

---

## 🎯 현재까지 완료된 것

### ✅ 인프라 측 완료
- [x] 팀서버 Docker Registry 설치 (2026-08-18)
- [x] Registry 컨테이너 running
- [x] 방화벽 포트 5000/tcp 오픈 (팀서버)
- [x] OmnioneCX 5개 이미지 레지스트리 등록

### ✅ 팀원 환경 측 완료
- [x] 팀원들 방화벽 5000/tcp 오픈
- [x] 안내 문서 배포 (FIREWALL-OPEN-TODO.md 등)
- [x] 팀원들이 insecure-registries 설정
- [x] 팀원들이 레지스트리 접근 테스트

### 🔄 진행 중
- [ ] 팀원들이 각자 OmnioneCX 배포 테스트
- [ ] 배포 완료 현황 확인

---

## 📊 잔여사항 (우선순위 순)

### **1단계: 팀원 배포 테스트 진행 상황 파악**

#### 1.1 확인해야 할 것 (팀원별)
```
각 팀원으로부터 보고받아야 할 항목:
□ sandbox에서 deploy.ps1 실행 완료? (Y/N)
□ 5개 서비스 모두 healthy? (Y/N)
□ 5개 HTTP 포트 모두 200 응답? (Y/N)
□ DB 데이터 정상 로드? (Y/N)
□ 로그에서 ERROR 발견? (Y/N, 있으면 내용)
□ 발생한 문제 있는가?
```

#### 1.2 수집 방법
- [ ] 슬랙/메일로 각 팀원에게 확인 요청
- [ ] 회신 기한: 오늘 중 또는 내일 오전

#### 1.3 결과에 따른 분기
- **모두 성공**: → 2단계 진행
- **일부 실패**: → 문제 분석 및 해결
- **전체 실패**: → 환경 재검토

---

### **2단계: 배포 완료 현황 정리 및 문서화**

#### 2.1 현황 정리
```
배포 완료 현황:

팀원 이름          환경준비  배포테스트  HTTP테스트  DB테스트  상태
─────────────────────────────────────────────────────────────────
[팀원1]           ✅       □          □          □       진행중
[팀원2]           ✅       □          □          □       진행중
[팀원3]           ✅       □          □          □       진행중
...
```

#### 2.2 문제 분석 (발생 시)
```
문제 유형별 분류:
- 네트워크: insecure-registries, 방화벽, DNS
- 배포: 스크립트 오류, 이미지 pull 실패
- 서비스: 컨테이너 기동 실패, healthy 미도달
- DB: 접속 실패, 데이터 미로드
```

#### 2.3 해결책 제시 및 재시도
```
각 문제별 해결책:
1. [문제명] → [해결책] → [재시도] → [확인]
2. [문제명] → [해결책] → [재시도] → [확인]
```

---

### **3단계: 운영 환경 배포 준비**

#### 3.1 개발 환경 확정
```
현재 상태:
- 개발용 sandbox에서 deploy.ps1 테스트 완료: ✅
- 5개 서비스 정상 동작 확인: ✅
- 기본 데이터 시딩 확인: ✅
```

#### 3.2 운영 환경 테스트 계획
```
필요 작업:
□ 운영용 폴더 준비 (prod-test-aia 등)
□ 운영 환경 설정 (env=2, prod)
□ verifier DID 파일 준비 (운영)
□ admin 콘솔 서비스-provider 등록 테스트
□ sample을 통한 QR 발급 테스트
□ connection.timeout 30000 이상 설정 확인
```

#### 3.3 운영 배포 체크리스트
```
배포 전 필수 확인:
□ 환경: prod (운영)
□ DID 파일: raonEnt.did (운영)
□ RCP 호스트: https://bcc.mobileid.go.kr:18888
□ Verifier dialect: org.hibernate.dialect.MariaDB103Dialect
□ HTTP timeout: 5000ms 이상
□ OACX timeout: 30000ms 이상
□ PARTNER_CODE: 실제 값
□ DB 백업: 완료
```

---

### **4단계: 알려진 이슈 대응 준비**

#### 4.1 aia 특이사항 확인
```
배포 시 나타날 수 있는 증상:

1. JPA Dialect 오류
   증상: HibernateException: Access to DialectResolutionInfo...
   원인: verifier 설정 미흡
   해결: org.hibernate.dialect.MariaDB103Dialect 명시

2. HTTP Timeout
   증상: SocketTimeoutException: Connect timed out
   원인: mdl.sp.httpclient-conn-timeout 부족
   해결: 5000ms 이상으로 설정

3. OACX Timeout
   증상: QR 발급 시 타임아웃
   원인: connection.timeout 5000ms는 부족
   해결: 30000ms 이상으로 설정 (admin 콘솔에서)

4. MyBatis 캐시
   증상: admin 등록 후 OACX가 여전히 예전 데이터 반환
   원인: 캐시 미동기
   해결: 30초 대기 또는 docker restart oacx

5. Partner Code 불일치
   증상: errorCode=50001 ("이용기관 미존재")
   원인: body.partnerCode ≠ VF_ORGANIZATION.PARTNER_CODE
   해결: admin에서 등록 시 값 일치 확인
```

#### 4.2 트러블슈팅 매뉴얼 준비
```
문제 발생 시 순서:
1. 로그 확인: docker logs <service-name>
2. 네트워크 확인: docker network inspect omnionecx
3. DB 접속: docker exec db mysql -u omnione -p0mN1DB
4. 설정 재확인: verifier/config/application.yml
5. 컨테이너 재시작: docker restart <service-name>
6. 전체 재배포: docker compose down && rm -rf data/
```

---

### **5단계: 문서 최신화 및 정리**

#### 5.1 현재 문서 상태
```
✅ README.md: 최신화 완료 (방화벽 오픈 표시)
✅ FIREWALL-OPEN-TODO.md: 즉시 실행용
✅ PHASE-E-POST-FIREWALL-CHECKLIST.md: 상세 가이드
✅ WORKLOG.md: 마지막 갱신 2026-09-03
```

#### 5.2 업데이트 필요 사항
```
□ WORKLOG.md 갱신: 방화벽 오픈 완료 기록
□ 배포 완료 현황 문서 생성
□ 운영 배포 준비 계획 문서 생성
□ GitHub 커밋: 현황 업데이트
```

---

## 🎯 즉시 행동 항목 (오늘)

### 🔴 **지금 바로 할 일** (1-2시간)

#### A. 팀원 배포 현황 조사
```powershell
# 각 팀원에게 메시지:

안녕하세요,

OmnioneCX 배포 테스트 진행 현황을 확인하고 싶습니다.

다음 항목에 대해 회신 부탁드립니다:

1. sandbox에서 deploy.ps1 실행 완료? (Y/N)
2. 5개 서비스(DB/verifier/oacx/admin/sample) 모두 healthy? (Y/N)
3. 5개 HTTP 포트 모두 200 응답?
   - verifier: http://localhost:48085/
   - oacx: http://localhost:8080/oacx/api/
   - admin: http://localhost:6443/
   - sample: http://localhost:9025/
   (Y/N)
4. DB 데이터 정상 로드? (Y/N, 또는 select count from VF_ORGANIZATION 결과)
5. 발생한 문제? (있으면 상세히)

기한: 오늘 또는 내일 오전 중

감사합니다.
```

#### B. 결과 정리
- [ ] 회신 수집
- [ ] 성공/실패 분류
- [ ] 실패 원인 분석

#### C. 문제 해결 (필요 시)
```
문제 발생 시 순서:
1. 오류 메시지 요청
2. 로그 수집: docker logs <service-name>
3. 원인 분석
4. 해결책 제시 + 재시도
```

---

### 🟡 **내일 할 일** (반일)

#### A. 배포 완료 확인
- [ ] 모든 팀원 배포 완료 확인
- [ ] 성공률 통계

#### B. 운영 환경 테스트 준비
- [ ] 테스트 폴더 생성
- [ ] 운영 환경 설정값 준비
- [ ] 테스트 계획 수립

#### C. 문서 갱신
- [ ] WORKLOG.md 업데이트
- [ ] GitHub 커밋

---

### 🟢 **다음주 할 일** (1-2일)

#### A. 운영 환경 배포 테스트
- [ ] 개발용 완료 확인
- [ ] 운영 환경 테스트 시작
- [ ] 문제 해결

#### B. 실제 배포 준비
- [ ] 배포 일정 확정
- [ ] 팀원 교육
- [ ] 롤백 계획 수립

---

## 📌 체크리스트 (전체)

### 최우선 (오늘)
- [ ] 팀원 배포 현황 조사 (회신 기한 오늘/내일)
- [ ] 문제 원인 분석 (발생 시)
- [ ] 해결책 제시 + 재시도 (필요 시)

### 우선 (내일)
- [ ] 배포 완료 확인
- [ ] 운영 환경 테스트 계획 수립
- [ ] WORKLOG.md 갱신

### 차순위 (다음주)
- [ ] 운영 환경 테스트 실행
- [ ] 최종 배포 준비
- [ ] 팀원 교육

---

## 📊 현황 대시보드

```
Infrastructure (팀서버)
├─ Docker Registry           ✅ 완료 (2026-08-18)
├─ OmnioneCX 5개 이미지      ✅ 등록됨
├─ 방화벽 5000/tcp           ✅ 오픈됨 (2026-09-11)
└─ 팀원 외부 접근            ✅ 가능함

Team (팀원 PC)
├─ 방화벽 5000/tcp           ✅ 오픈됨 (2026-09-11~09-12)
├─ insecure-registries 설정  ✅ 완료됨
├─ Registry 접근 테스트      ✅ 성공함
├─ OmnioneCX 배포            🔄 진행 중 ← YOU ARE HERE
└─ 배포 완료 현황            ⏳ 대기 중

Documentation
├─ FIREWALL-OPEN-TODO.md            ✅ 완료
├─ PHASE-E-POST-FIREWALL-CHECKLIST  ✅ 완료
├─ README.md                        ✅ 개편됨
├─ 배포 완료 현황 문서              ⏳ 필요
└─ 운영 배포 준비 문서              ⏳ 필요
```

---

## 🎯 다음 마일스톤

| 마일스톤 | 예상 시기 | 담당 |
|---------|---------|------|
| 팀원 배포 완료 | 오늘/내일 | 각 팀원 |
| 배포 현황 정리 | 내일 | claude |
| 운영 환경 테스트 | 다음주 초 | 개발팀 |
| 최종 배포 준비 | 다음주 중 | 모두 |
| 운영 배포 | 다음주 말 | TBD |

---

**마지막 업데이트**: 2026-09-12  
**작성**: claude  
**상태**: 🔄 진행 중
