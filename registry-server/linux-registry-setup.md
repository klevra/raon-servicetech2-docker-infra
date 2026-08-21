# 사내 Docker Registry 서버 접속 (Linux, IP 통신 + hosts 등록)

- 작성일: 2026-08-13 / 최종 수정: 2026-08-21
- 대상: 이미 Docker + Registry가 설치되어 실행 중인 팀서버(`new-servicetech2-1`)
- 접근 방식: IP 기반 통신, 클라이언트마다 hosts 파일에 호스트명 등록
- **확정된 값**: hosts 별칭 `servicetech2` / 서버 IP `192.168.0.168` / 포트 `5000` / 인증 미적용(사내망 신뢰 전제)

> **주의**: 인증을 걸지 않았으므로, 이 레지스트리에 네트워크로 접근 가능한 사람은 누구나 push/pull이 가능합니다.
> 사내망이라도 신뢰 범위가 넓어지면(예: VPN 전체 개방 등) 나중에 `REGISTRY_AUTH=htpasswd`로 인증을 추가하는 것을 권장합니다.

---

## 0. 서버 쪽 현황 (참고용 — 이미 완료됨, 재실행 불필요)

`teamserver-docker-setup.sh`로 이미 아래와 같이 설치·실행되어 있습니다 (`docker ps`로 확인, 2026-08-21 기준 3일째 가동 중):

```
CONTAINER ID   IMAGE        COMMAND                  STATUS      PORTS                    NAMES
6c67d7cf85de   registry:2   "/entrypoint.sh /etc…"   Up 3 days   0.0.0.0:5000->5000/tcp   registry
```

- 서버 호스트명: `new-servicetech2-1` (실제 시스템 hostname, SSH 접속 등에 사용)
- 서버 IP: `192.168.0.168` (eth0)
- 컨테이너 이름: `registry` (참고: 초안 단계에서 검토했던 `servicetech2-registry`라는 이름은 실제로 쓰이지 않았음)
- 실행 커맨드: `docker run -d -p 5000:5000 --name registry registry:2`

> ⚠️ **알아두어야 할 점**: 위 실행 커맨드에는 **볼륨 마운트도 `--restart` 정책도 없습니다.** 즉 컨테이너를 삭제하거나 서버가 재부팅되면 그 안에 올려둔 이미지가 전부 사라질 수 있습니다. 데이터 영속화(볼륨)와 자동 재시작 정책 추가는 별도로 검토가 필요합니다 — 이 문서의 범위는 아니고, 클라이언트 접속 준비만 다룹니다.

## 1. 사전 준비 — 각 팀원 PC에서 진행

팀원들이 각자 자기 PC에서 아래 3가지를 준비합니다. 순서는 무관합니다.

### 1-1. hosts 파일 등록

**Linux/macOS 클라이언트**:
```bash
echo "192.168.0.168  servicetech2" | sudo tee -a /etc/hosts
```

**Windows 클라이언트** (관리자 권한 PowerShell):
```powershell
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "`n192.168.0.168  servicetech2" -Encoding ascii
```

### 1-2. 방화벽 오픈 (서버 쪽, 일괄 진행 예정)

팀서버(`new-servicetech2-1`)의 인바운드 5000 포트를 오픈하는 작업입니다. 이건 클라이언트가 아니라 **서버 쪽 작업**이며, 팀장님 승인 후 일괄 진행됩니다. 상세는 [PHASE-D-FIREWALL-APPROVAL.md](../PHASE-D-FIREWALL-APPROVAL.md) 참고.

### 1-3. 클라이언트에서 "insecure registry" 등록 (필수)

`localhost`가 아니라 호스트명(`servicetech2`)으로 접근하므로, Docker가 자동으로 허용하던 "로컬호스트 특례"가 적용되지 않습니다.
**TLS를 붙이지 않았기 때문에, push/pull 하는 모든 클라이언트 Docker에 이 레지스트리를 "insecure-registries"로 명시적으로 등록해야 합니다.**

**Linux 클라이언트** — `/etc/docker/daemon.json` 파일에 추가(없으면 새로 생성):
```json
{
  "insecure-registries": ["servicetech2:5000"]
}
```
```bash
sudo systemctl restart docker
```

**Windows 클라이언트 (Docker Desktop)**:
1. Docker Desktop → **Settings → Docker Engine**
2. JSON 설정에 아래 추가:
```json
{
  "insecure-registries": ["servicetech2:5000"]
}
```
3. **Apply & Restart**

## 2. 동작 확인 (위 3가지 준비 + 방화벽 오픈 완료 후)

```bash
# 레지스트리 응답 확인 (클라이언트에서)
curl -s http://servicetech2:5000/v2/
# {} 가 반환되면 정상

# 테스트 이미지로 push/pull 왕복 확인
docker pull hello-world
docker tag hello-world servicetech2:5000/servicetech2/smoke-test:latest
docker push servicetech2:5000/servicetech2/smoke-test:latest
docker rmi servicetech2:5000/servicetech2/smoke-test:latest
docker pull servicetech2:5000/servicetech2/smoke-test:latest
```

## 3. Oracle 이미지 push/pull 예시

```bash
# 로컬(개발 PC)에서 만든 이미지를 팀서버 레지스트리로 push
docker tag localhost:5000/servicetech2/oracle:19c servicetech2:5000/servicetech2/oracle:19c
docker push servicetech2:5000/servicetech2/oracle:19c

# 다른 팀원 PC에서 pull
docker pull servicetech2:5000/servicetech2/oracle:19c
```

준비가 끝나면, `oracle/deploy/deploy.sh`(또는 `.ps1`/`.bat`) 실행 시 "대상 레지스트리 주소" 프롬프트에 `servicetech2:5000`을 입력하면 됩니다. 이 경우 `oracle/registry`(1단계), `oracle/base`(2단계)는 실행할 필요 없이 바로 3단계(`oracle/deploy`)만 진행하면 됩니다 — 팀서버 레지스트리에 이미지가 이미 등록되어 있기 때문입니다.

## 4. 등록된 이미지 목록/태그 조회

```bash
curl -s http://servicetech2:5000/v2/_catalog
curl -s http://servicetech2:5000/v2/servicetech2/oracle/tags/list
```

## 5. (참고) 나중에 인증을 추가하고 싶을 때

현재 서버 쪽 컨테이너는 볼륨/재시작 정책 없이 떠 있으므로, 인증을 추가하려면 아래처럼 컨테이너를 다시 만들어야 합니다(데이터 영속화도 이 시점에 같이 검토 권장):

```bash
sudo mkdir -p /opt/servicetech2/auth /opt/servicetech2/data
docker run --rm --entrypoint htpasswd httpd:2 -Bbn <사용자명> <비밀번호> | \
  sudo tee /opt/servicetech2/auth/htpasswd

docker rm -f registry
docker run -d \
  --name registry \
  --restart=always \
  -p 5000:5000 \
  -v /opt/servicetech2/data:/var/lib/registry \
  -v /opt/servicetech2/auth:/auth \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM="servicetech2 Registry" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# 클라이언트에서는 push/pull 전 로그인 필요
docker login servicetech2:5000
```

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-13 | 최초 작성(초안). 호스트명 `servicetech2-registry`로 가정, 포트 5000, 인증 미적용 |
| 2026-08-21 | 실제 서버(`new-servicetech2-1`, `192.168.0.168`, 컨테이너명 `registry`) 확인 후 문서 전체 갱신. hosts 별칭을 `servicetech2`(하이픈 없음)로 확정. 서버가 볼륨/재시작 정책 없이 떠 있다는 점 명시. 클라이언트 준비 체크리스트(hosts/방화벽/insecure-registry) 구조로 재정리 |
