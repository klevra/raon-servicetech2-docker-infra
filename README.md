# Docker Registry 오프라인 배포 + OmnioneCX 통합 배포 프로젝트

## 📋 개요

팀서버(Oracle Linux 8.10)에 **완전 오프라인 환경**에서 Docker Registry를 설치하고, **OmnioneCX 통합인증 플랫폼**을 자동화 배포하는 프로젝트입니다.

**특징**:
- ✅ 인터넷 차단된 환경에서도 설치 가능
- ✅ 모든 바이너리와 이미지를 오프라인 패키지로 포함
- ✅ 완전 자동화된 배포 스크립트 (PowerShell/Bash)
- ✅ 다중 환경 지원 (dev/prod)
- ✅ 다중 사이트 지원 (1.0.0.12/2.0.0.3/aia/fsb/wooriib)

---

## 🚀 현재 상태

| 항목 | 상태 | 날짜 |
|------|------|------|
| **Docker 설치** | ✅ 완료 | 2026-08-18 |
| **Registry 실행** | ✅ 완료 | 2026-08-18 |
| **방화벽 오픈** | ✅ 완료 | 2026-09-11 |
| **팀원 배포 준비** | 🔄 **진행 중** | 2026-09-11 ~ |

---

## 🎯 지금 바로 할 일

### 팀원을 위한 빠른 시작 (각자 1시간)

**1. Docker insecure-registries 설정**
```json
// C:\Users\<username>\AppData\Roaming\Docker\daemon.json (Windows)
{
  "insecure-registries": ["new-servicetech2-1:5000"]
}
```
→ Docker Desktop 재시작 필요

**2. 접근 테스트**
```bash
docker pull new-servicetech2-1:5000/library/alpine:latest
```

**3. OmnioneCX 배포**
```powershell
cd d:\99_project\Docker\sandbox
.\deploy.ps1
# 레지스트리: new-servicetech2-1:5000 입력
```

**4. 결과 확인**
```bash
docker ps  # 5개 서비스 healthy 확인
curl http://localhost:48085/       # verifier 200
curl http://localhost:8080/oacx/api/  # oacx 200
```

📖 **상세 가이드**: [FIREWALL-OPEN-TODO.md](FIREWALL-OPEN-TODO.md)

---

## 📚 주요 문서

| 문서 | 설명 | 상태 |
|------|------|------|
| **[FIREWALL-OPEN-TODO.md](FIREWALL-OPEN-TODO.md)** | 🔴 **지금 읽어야 할 문서** — 방화벽 오픈 후 체크리스트 | 🆕 최신 |
| **[PHASE-E-POST-FIREWALL-CHECKLIST.md](PHASE-E-POST-FIREWALL-CHECKLIST.md)** | 5가지 Phase별 상세 체크리스트 | 🆕 최신 |
| **[FINAL-SETUP-SUMMARY.md](FINAL-SETUP-SUMMARY.md)** | 팀서버 Docker/Registry 설치 완료 보고서 | ✅ 완료 |
| **[omnionecx/aia/README.md](omnionecx/aia/README.md)** | AIA생명 백포팅 (2.0.0.1) 상세 정보 | ✅ 완료 |
| **[omnionecx/2.0.0.3/README.md](omnionecx/2.0.0.3/README.md)** | 신 버전 (2.0.0.3) 상세 정보 | ✅ 완료 |

---

## 🔗 주요 정보

### Registry 접근

**주소**: `http://new-servicetech2-1:5000`

**테스트**:
```bash
# 팀서버에서
curl http://localhost:5000/v2/           # {} 반환
sudo docker ps | grep registry           # running 확인

# 다른 PC에서
curl http://new-servicetech2-1:5000/v2/  # 외부 접근 확인
docker pull new-servicetech2-1:5000/library/alpine  # pull 테스트
```

### OmnioneCX 배포 환경

**포트**:
| 서비스 | 포트 | 접근 URL |
|--------|------|----------|
| DB | 3306 | `localhost:3306` |
| verifier | 48085 | `http://localhost:48085/` |
| oacx | 8080 | `http://localhost:8080/oacx/api/` |
| admin | 6443 | `http://localhost:6443/` |
| sample | 9025 | `http://localhost:9025/` |

---

## 🆘 트러블슈팅

### "connection refused"
```bash
sudo firewall-cmd --list-all | grep 5000  # 팀서버 방화벽 확인
ping new-servicetech2-1                   # 클라이언트 네트워크 확인
```

### "no basic auth credentials"
```bash
docker info | grep insecure  # insecure-registries 설정 확인
docker restart                 # Docker 재시작
```

---

## 📞 문의 및 지원

| 항목 | 담당자 |
|------|--------|
| **레지스트리/팀서버** | 인프라팀 |
| **OmnioneCX 배포** | 개발팀 |
| **환경 준비** | 각 개발자 |
| **문서/진행** | claude |

---

## 📝 변경 이력

| 버전 | 날짜 | 내용 |
|------|------|------|
| **2.0** | 2026-09-11 | 🔴 방화벽 오픈 완료 — 팀원 배포 가이드 추가 |
| **1.1** | 2026-08-18 | Registry 설치 완료 |
| **1.0** | 2026-08-13 | 초기 프로젝트 시작 |
