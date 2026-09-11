# ✅ 잔여사항 한눈에 보기

**현재 상황**: 팀원들 방화벽 오픈 완료 (2026-09-11~09-12)  
**진행률**: 95% 완료, 배포 테스트만 남음

---

## 🎯 지금 당장 해야 할 것 (1시간)

### ✉️ 팀원들에게 보낼 메시지

```
제목: OmnioneCX 배포 테스트 — 현황 확인 부탁

안녕하세요,

sandbox에서 OmnioneCX 배포를 진행한 후 아래 항목을 확인해주세요.

【배포 실행】
cd d:\99_project\Docker\sandbox
.\deploy.ps1
레지스트리 주소: new-servicetech2-1:5000
환경: 1 (개발)
나머지: Enter (기본값)

【확인 사항】
1. ✓ 5개 서비스 모두 healthy?
   docker ps | grep healthy

2. ✓ 5개 HTTP 포트 모두 200 응답?
   http://localhost:48085/       (verifier)
   http://localhost:8080/oacx/api/  (oacx)
   http://localhost:6443/        (admin)
   http://localhost:9025/        (sample)

3. ✓ DB 데이터 정상?
   docker exec sandbox-db mysql -u omnione -p0mN1DB VC_VERIFIER \
   -e "SELECT COUNT(*) FROM VF_ORGANIZATION;"

4. ✓ 발생한 문제?

【회신】
위 항목에 대해 회신 부탁드립니다.
기한: 오늘 또는 내일 오전

감사합니다.
```

---

## 📊 팀원 현황 수집 템플릿

```
팀원 이름     환경준비  배포완료  서비스OK  HTTP OK   DB OK   문제
─────────────────────────────────────────────────────────────
[팀원1]      ✅       ⏳       ⏳       ⏳       ⏳       -
[팀원2]      ✅       ⏳       ⏳       ⏳       ⏳       -
[팀원3]      ✅       ⏳       ⏳       ⏳       ⏳       -
...

범례:
✅ = 완료
⏳ = 대기/진행중
❌ = 실패
- = 문제 없음
```

---

## 🚨 예상 문제 & 대응

| 증상 | 원인 | 즉시 해결책 |
|------|------|----------|
| deployment 실패 | 이미지 pull 오류 | `docker pull new-servicetech2-1:5000/servicetech2/omnionecx2-db:aia` 재시도 |
| 서비스 안 뜸 | 포트 충돌 | `netstat -ano \| findstr :3306` 확인 후 포트 변경 |
| HTTP 500 | DB 연결 실패 | `docker logs <service>` 확인, DB 상태 체크 |
| 레지스트리 못 찾음 | insecure-registries 미설정 | Docker Desktop 재시작 |
| 권한 오류 | hosts/DNS 오류 | ping new-servicetech2-1 테스트 |

---

## 📋 체크리스트

### 오늘 (2026-09-12)
- [ ] 팀원 메시지 발송
- [ ] 배포 현황 수집 (기한: 오늘/내일 오전)
- [ ] 문제 발생 시 대응 준비

### 내일 (2026-09-13)
- [ ] 회신 정리
- [ ] 성공/실패 분류
- [ ] 문제 원인 분석 및 해결
- [ ] WORKLOG.md 갱신
- [ ] GitHub 커밋

### 다음주 (2026-09-18~)
- [ ] 모든 팀원 배포 완료 확인
- [ ] 운영 환경 테스트 시작
- [ ] 최종 배포 준비

---

## 📞 간단한 참고

| 상황 | 명령어 |
|------|--------|
| 배포 실행 | `cd sandbox && .\deploy.ps1` |
| 5개 서비스 확인 | `docker ps` (모두 healthy인지 확인) |
| 레지스트리 확인 | `curl http://new-servicetech2-1:5000/v2/` |
| 컨테이너 로그 | `docker logs <service>` |
| 컨테이너 중지 | `docker compose -f docker-compose.yml down` |
| 전체 재배포 | `rm -rf data/ log/ && docker compose up -d` |

---

**우선순위**: 🔴 팀원 배포 현황 조사 → 🟡 문제 해결 → 🟢 운영 준비

**예상 소요시간**: 1-2일 (배포) + 3-5일 (운영 준비)

