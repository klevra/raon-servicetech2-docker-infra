# 📋 방화벽 오픈 완료 후 즉시 실행 사항 (한눈에 보기)

**방화벽 오픈 완료**: 2026-09-11 ✅  
**현재 상태**: 팀원 배포 준비 단계  
**예상 소요 시간**: 3-4시간 (병렬 진행 시 2시간)

---

## 🚀 지금 바로 할 것 (우선순위 순서)

### ✅ 1단계: 팀서버 검증 (인프라팀, 30분)
```bash
# 팀서버에서 실행
ssh servicetech2@new-servicetech2-1

# 로컬 테스트
curl http://localhost:5000/v2/           # {} 반환 확인
sudo docker ps | grep registry           # running 확인
sudo docker logs registry                # 에러 없음 확인

# 방화벽 확인
sudo firewall-cmd --list-all | grep 5000 # 5000/tcp 포함 확인
```

**담당**: 인프라팀  
**예상 시간**: 30분  
**결과**: ✅ 레지스트리 정상 작동 확인

---

### ✅ 2단계: 팀원 환경 준비 (각 팀원, 1시간/인원)

**각 팀원이 자신의 PC에서 할 일**:

#### A. Docker insecure-registries 설정

**Windows (Docker Desktop)**:
```json
// C:\Users\<username>\AppData\Roaming\Docker\daemon.json
{
  "insecure-registries": ["new-servicetech2-1:5000"]
}
```
→ Docker Desktop 재시작

**Linux**:
```bash
sudo vi /etc/docker/daemon.json
# 아래 내용 추가:
# {
#   "insecure-registries": ["new-servicetech2-1:5000"]
# }
sudo systemctl restart docker
```

#### B. 접근 테스트
```bash
docker pull new-servicetech2-1:5000/library/alpine:latest
# pulled 또는 already exists 확인
```

**담당**: 각 팀원  
**예상 시간**: 30분/인원  
**결과**: ✅ 레지스트리 접근 가능 확인

---

### ✅ 3단계: OmnioneCX 배포 테스트 (각 팀원, 1시간/인원)

```powershell
# Windows
cd d:\99_project\Docker\sandbox
.\deploy.ps1

# 입력 사항
# - 레지스트리: new-servicetech2-1:5000
# - 환경: 1 (개발)
# - 나머지는 기본값 Enter

# 결과 확인
docker ps          # 5개 서비스 모두 healthy 확인
curl http://localhost:48085/                      # 200 확인
curl http://localhost:8080/oacx/api/              # 200 확인
curl http://localhost:6443/                       # 200 확인
curl http://localhost:9025/                       # 200 확인
```

**담당**: 각 팀원  
**예상 시간**: 1시간/인원  
**결과**: ✅ 5개 서비스 모두 정상 작동 확인

---

## 📊 체크리스트 (전체)

### 팀서버 검증
- [ ] localhost:5000/v2/ 응답 OK
- [ ] registry 컨테이너 running
- [ ] firewall 5000/tcp open
- [ ] OmnioneCX 이미지 5개 등록됨

### 팀원 환경 (각자)
- [ ] insecure-registries 설정됨
- [ ] Docker 재시작됨
- [ ] alpine 이미지 pull 성공

### 배포 테스트 (각자)
- [ ] deploy.ps1 실행 완료
- [ ] 5개 서비스 healthy 상태
- [ ] 5개 HTTP 포트 모두 200 응답
- [ ] DB 데이터 정상 로드
- [ ] 로그에 ERROR 없음

---

## 🚨 만약 문제 발생 시

### "connection refused"
→ 팀서버 방화벽 확인: `sudo firewall-cmd --list-all | grep 5000`

### "no basic auth credentials"
→ insecure-registries 설정 + Docker 재시작 + 확인: `docker info | grep insecure`

### 서비스 기동 실패
→ 로그 확인: `docker logs <service-name>`

### DB 연결 실패
→ 네트워크 확인: `docker network ls` + `docker network inspect omnionecx`

---

## ⏰ 일정

| 항목 | 소요시간 | 담당 | 예상 완료 |
|------|---------|------|---------|
| 팀서버 검증 | 30분 | 인프라팀 | 오전 |
| 팀원 환경 준비 | 1시간 | 각 팀원 | 오전/오후 |
| 배포 테스트 | 1시간 | 각 팀원 | 오전/오후 |
| **총 소요 시간** | **2-4시간** | **병렬** | **오늘 중** |

---

## ✅ 완료 후 확인사항

모든 팀원이 아래를 확인하고 슬랙/메일로 완료 보고:

```
✅ 레지스트리 pull 성공
✅ 5개 서비스 배포 완료
✅ 5개 포트 모두 HTTP 200
✅ DB 데이터 정상
✅ 로그 에러 없음
```

---

## 📞 담당자

- **레지스트리/팀서버**: 인프라팀
- **각 팀원 환경**: 각 개발자
- **배포 이슈**: 개발팀
- **문서/진행**: claude

