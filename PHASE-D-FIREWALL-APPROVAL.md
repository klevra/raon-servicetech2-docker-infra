# Phase D: 방화벽 오픈 (팀장님 승인 필수)

**상태**: ⏳ **대기 중** (팀장님 휴가)  
**예정**: 2026-08-25 이후 (다음주)  
**담당**: 팀장님 승인 필요

---

## 📋 현재까지 완료된 작업

| 항목 | 상태 | 상세 |
|------|------|------|
| **외부 VM 패키지 생성** | ✅ | docker-offline-package.tar.gz (103M) |
| **팀서버 파일 전달** | ✅ | SCP로 /home/servicetech2/upload/docker/ |
| **Rootful Docker 설치** | ✅ | /usr/local/bin/docker* 설치 |
| **Registry 컨테이너 실행** | ✅ | 포트 5000, 정상 작동 중 |
| **방화벽 오픈** | ⏳ | **다음주 진행** |

---

## 🔥 필요한 방화벽 설정

### 요청 사항

**팀서버 레지스트리 포트 오픈 요청**

| 항목 | 값 |
|------|-----|
| **서버** | new-servicetech2-1 (팀 테스트 서버) |
| **프로토콜** | TCP |
| **포트** | 5000 |
| **용도** | Docker Registry 서비스 |
| **방향** | Inbound (172.16.0.0/12 범위 허용 권장) |

### 설정 스크립트 (승인 후 실행)

```bash
# 팀장님 승인 후 실행
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --reload

# 확인
sudo firewall-cmd --list-all | grep 5000
```

---

## 🔗 레지스트리 접근 테스트 (승인 후)

```bash
# 같은 네트워크 내에서 테스트
curl http://new-servicetech2-1:5000/v2/

# 또는
docker pull new-servicetech2-1:5000/some-image
```

---

## 📝 승인 체크리스트

- [ ] 팀장님 휴가 복귀 (예상: 2026-08-25)
- [ ] 방화벽 오픈 승인 요청
- [ ] 방화벽 설정 적용
- [ ] 네트워크 접근 테스트
- [ ] 팀원에게 레지스트리 주소 공지 (`http://new-servicetech2-1:5000`)

### 팀원 PC 사전 준비 (방화벽 승인과 무관하게 미리 진행 가능)

방화벽만 열려서는 pull이 안 됩니다 — 각 팀원 PC에서 아래 3가지도 준비해야 합니다. 상세 절차는 [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md) 참고.

- [ ] hosts 파일에 `192.168.0.168  servicetech2` 등록
- [ ] 방화벽 오픈 (서버 측, 위 항목과 동일 — 일괄 진행 예정)
- [ ] Docker `insecure-registries`에 `servicetech2:5000` 등록 (TLS 미적용 레지스트리라 필수)

준비가 끝나면 `oracle/deploy/deploy.ps1`(또는 `.sh`/`.bat`) 실행 시 레지스트리 주소를 `servicetech2:5000`으로 입력 — `oracle/registry`, `oracle/base` 단계는 건너뛰고 바로 배포됩니다.

---

## 📌 참고 정보

**현재 레지스트리 상태**:
```bash
# 팀서버에서 확인
sudo docker ps
# registry:2 컨테이너 running

sudo docker logs registry
# 정상 로그 확인
```

**레지스트리 주소**: `http://new-servicetech2-1:5000`

---

## 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-08-18 | Phase D: 방화벽 오픈 대기 (팀장님 휴가) |
| 2026-08-25 | 예정: 팀장님 승인 후 방화벽 설정 |
