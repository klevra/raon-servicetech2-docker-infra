# Docker Engine 업그레이드: 24.0.9 → 28.x (사내 Linux Registry 서버)

- 작성일: 2026-08-13
- 대상 서버: `servicetech2-registry` 컨테이너가 떠 있는 사내 Linux 서버 (rootful, root 계정으로 운영)
- 현재 버전: Docker 24.0.9
- 목표 버전: 28.x (최신 패치), 이후 검증되면 29로 2단계 진행 예정

> 이 문서는 명령어 실행을 위한 절차서입니다. 실제 서버에서는 사용자가 직접 실행하며,
> 아래 `<...>` 표시된 부분은 실행 결과를 보고 실제 값으로 치환해야 합니다.

---

## 0. 사전 확인 (실행 전 필수)

```bash
# 배포판/버전 확인 — dnf 계열인지 apt 계열인지에 따라 이후 명령이 달라짐
cat /etc/os-release

# 현재 Docker 버전 및 설치 방식 확인
docker --version
rpm -qa | grep docker      # RHEL/CentOS/Rocky 계열
# dpkg -l | grep docker    # Debian/Ubuntu 계열이면 이걸로

# 현재 떠 있는 컨테이너 확인
docker ps -a

# 이 데몬 API를 원격에서 호출하는 외부 클라이언트/CI 도구가 있는지 사전 점검
# (있다면 API 1.44 이상을 지원하는지 별도 확인 필요 — v29에서는 필수, v28은 영향 없음)
```

**이 문서는 RHEL/CentOS/Rocky 계열(`dnf`)을 기준으로 작성했습니다.** `/etc/os-release`에서 Debian/Ubuntu 계열로 확인되면 하단 "부록: apt 계열" 참고.

## 1. 백업

```bash
# 레지스트리 데이터 백업 (Docker 엔진과 무관하게 안전하지만, 만약을 위해)
tar czf ~/registry-images-backup-$(date +%F).tar.gz /home/servicetech2/docker/images

# daemon.json이 있다면 백업 (없으면 이 명령은 에러 없이 넘어감)
cp /etc/docker/daemon.json /etc/docker/daemon.json.bak-$(date +%F) 2>/dev/null

# 현재 컨테이너 실행 설정 기록 (문제 생겼을 때 동일하게 재생성하기 위한 참고용)
docker inspect servicetech2-registry > ~/servicetech2-registry-inspect-backup-$(date +%F).json
```

## 2. 설치 가능한 28.x 버전 확인

```bash
dnf list docker-ce --showduplicates | sort -r | grep '28\.'
```

출력된 목록에서 원하는(보통 가장 최신) 버전 문자열을 그대로 복사해 다음 단계에 사용합니다.
예: `docker-ce-3:28.3.1-1.el9.x86_64` 처럼 나오면 `3:28.3.1-1.el9`가 버전 지정 문자열입니다.

## 3. 업그레이드 실행

```bash
dnf install docker-ce-<확인한 버전> docker-ce-cli-<확인한 버전> containerd.io docker-buildx-plugin docker-compose-plugin -y
```

> 패키지 매니저가 알아서 서비스 중지 → 바이너리 교체 → 재시작까지 처리합니다.
> `--restart=always`로 띄운 `servicetech2-registry` 컨테이너는 dockerd가 다시 올라오면 자동으로 재기동됩니다.

## 4. 서비스 상태 확인

```bash
systemctl status docker
docker --version
docker info | head -30
```

## 5. 컨테이너 정상 기동 및 레지스트리 응답 확인

```bash
docker ps
curl -s http://localhost:5000/v2/_catalog
```

## 6. Push/Pull 재검증 (스모크 테스트)

v29에서 발견된 "컨테이너d 이미지 스토어로 인한 push 매니페스트 형식 변경" 이슈는 28에는 해당하지 않지만, 업그레이드 후 습관적으로 항상 검증하는 것을 권장합니다.

```bash
docker pull hello-world
docker tag hello-world localhost:5000/servicetech2/smoke-test:latest
docker push localhost:5000/servicetech2/smoke-test:latest
docker rmi localhost:5000/servicetech2/smoke-test:latest
docker pull localhost:5000/servicetech2/smoke-test:latest
```

`pull`이 다시 성공하면 정상입니다.

## 7. 문제 발생 시 롤백

```bash
# 2번 단계에서 확인해둔 기존 24.0.9의 정확한 버전 문자열로 재설치
dnf list docker-ce --showduplicates | sort -r | grep '24\.0\.9'
dnf install docker-ce-<24.0.9 버전 문자열> docker-ce-cli-<24.0.9 버전 문자열> containerd.io -y
systemctl restart docker
docker ps   # 컨테이너 정상 복귀 확인
```

레지스트리 데이터(`/home/servicetech2/docker/images`)는 바인드마운트라 롤백해도 그대로 유지됩니다.

## 8. 다음 단계

28에서 문제없이 며칠 운영 검증되면, 아래를 재확인한 뒤 29로 진행:
- 이 데몬 API를 원격에서 호출하는 외부 도구가 API 1.44 이상을 지원하는지 확인
- `docker push` 시 매니페스트 형식 변경 영향 재검토 (필요하면 `daemon.json`에 `"features": {"containerd-snapshotter": false}` 옵션 검토)

---

## 부록: apt 계열(Debian/Ubuntu)이었을 경우

```bash
apt-cache madison docker-ce | grep '28\.'
apt-get install docker-ce=<확인한 버전> docker-ce-cli=<확인한 버전> containerd.io docker-buildx-plugin docker-compose-plugin -y
systemctl status docker
```
롤백도 동일하게 `apt-get install docker-ce=24.0.9~... docker-ce-cli=24.0.9~...` 형태로 진행.

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-13 | 최초 작성. 24.0.9 → 28.x 업그레이드 절차 확정, 29는 28 검증 후 2단계로 진행하기로 결정 |
