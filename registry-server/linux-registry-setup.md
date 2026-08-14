# 사내 Docker Registry 서버 구축 (Linux, IP 통신 + hosts 등록)

- 작성일: 2026-08-13
- 대상: 이미 Docker가 설치된 사내 Linux 서버
- 접근 방식: IP 기반 통신, 클라이언트마다 hosts 파일에 호스트명 등록
- 확정된 값: 호스트명 `servicetech2-registry` / 포트 `5000` / 인증 미적용(사내망 신뢰 전제)

> **주의**: 인증을 걸지 않았으므로, 이 레지스트리에 네트워크로 접근 가능한 사람은 누구나 push/pull이 가능합니다.
> 사내망이라도 신뢰 범위가 넓어지면(예: VPN 전체 개방 등) 나중에 `REGISTRY_AUTH=htpasswd`로 인증을 추가하는 것을 권장합니다.

---

## 0. 사전 준비

- 서버의 사내망 IP 확인: `ip a` 또는 `hostname -I`
- 아래 예시에서 `<SERVER_IP>`는 실제 IP로 치환

## 1. 레지스트리 서버 구축 (Linux 서버에서 실행)

```bash
# 데이터 저장 디렉터리 생성
sudo mkdir -p /opt/servicetech2-registry/data

# registry:2 컨테이너 기동 (인증 미적용, 재시작 정책 always)
docker run -d \
  --name servicetech2-registry \
  --restart=always \
  -p 5000:5000 \
  -v /opt/servicetech2-registry/data:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# 정상 기동 확인
curl -s http://localhost:5000/v2/
# {} 가 반환되면 정상
```

## 2. 방화벽에서 5000 포트 개방 (서버에서 실행)

```bash
# firewalld 계열 (RHEL/CentOS/Rocky 등)
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --reload

# 또는 ufw 계열 (Ubuntu/Debian 등)
sudo ufw allow 5000/tcp
```

> 사용 중인 배포판에 맞는 쪽만 실행하면 됩니다. 클라우드 VM이라면 보안그룹/NSG 등 인프라 방화벽도 별도로 열어야 할 수 있습니다.

## 3. hosts 파일 등록

### 3-1. 레지스트리 서버 자기 자신 (선택, 서버에서 자체적으로 push/pull도 할 경우)
```bash
echo "127.0.0.1  servicetech2-registry" | sudo tee -a /etc/hosts
```

### 3-2. Linux 클라이언트 (push/pull 하는 다른 서버들)
```bash
echo "<SERVER_IP>  servicetech2-registry" | sudo tee -a /etc/hosts
```

### 3-3. Windows 클라이언트 (관리자 권한 PowerShell)
```powershell
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "`n<SERVER_IP>  servicetech2-registry" -Encoding ascii
```

## 4. 클라이언트에서 "insecure registry" 등록 (필수)

`localhost`가 아니라 호스트명/IP로 접근하므로, Docker가 자동으로 허용하던 "로컬호스트 특례"가 적용되지 않습니다.
**TLS를 붙이지 않았기 때문에, push/pull 하는 모든 클라이언트 Docker에 이 레지스트리를 "insecure-registries"로 명시적으로 등록해야 합니다.**

### 4-1. Linux 클라이언트
`/etc/docker/daemon.json` 파일에 추가 (없으면 새로 생성):
```json
{
  "insecure-registries": ["servicetech2-registry:5000"]
}
```
```bash
sudo systemctl restart docker
```

### 4-2. Windows 클라이언트 (Docker Desktop)
1. Docker Desktop → **Settings → Docker Engine**
2. JSON 설정에 아래 추가:
```json
{
  "insecure-registries": ["servicetech2-registry:5000"]
}
```
3. **Apply & Restart**

## 5. 동작 확인

```bash
# 레지스트리 응답 확인 (클라이언트에서)
curl -s http://servicetech2-registry:5000/v2/

# 테스트 이미지로 push/pull 왕복 확인
docker pull hello-world
docker tag hello-world servicetech2-registry:5000/servicetech2/smoke-test:latest
docker push servicetech2-registry:5000/servicetech2/smoke-test:latest
docker rmi servicetech2-registry:5000/servicetech2/smoke-test:latest
docker pull servicetech2-registry:5000/servicetech2/smoke-test:latest
```

## 6. 실제 이미지 push/pull 예시

```bash
# 로컬에서 만든 이미지를 사내 레지스트리로 push
docker tag localhost:5000/servicetech2/oracle:19c servicetech2-registry:5000/servicetech2/oracle:19c
docker push servicetech2-registry:5000/servicetech2/oracle:19c

# 다른 사내 서버에서 pull
docker pull servicetech2-registry:5000/servicetech2/oracle:19c
```

## 7. 등록된 이미지 목록/태그 조회

```bash
curl -s http://servicetech2-registry:5000/v2/_catalog
curl -s http://servicetech2-registry:5000/v2/servicetech2/oracle/tags/list
```

## 8. (참고) 나중에 인증을 추가하고 싶을 때

```bash
sudo mkdir -p /opt/servicetech2-registry/auth
docker run --rm --entrypoint htpasswd httpd:2 -Bbn <사용자명> <비밀번호> | \
  sudo tee /opt/servicetech2-registry/auth/htpasswd

docker rm -f servicetech2-registry
docker run -d \
  --name servicetech2-registry \
  --restart=always \
  -p 5000:5000 \
  -v /opt/servicetech2-registry/data:/var/lib/registry \
  -v /opt/servicetech2-registry/auth:/auth \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM="servicetech2 Registry" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# 클라이언트에서는 push/pull 전 로그인 필요
docker login servicetech2-registry:5000
```

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-13 | 최초 작성. 호스트명 `servicetech2-registry`, 포트 5000, 인증 미적용으로 확정 |
