---
name: oracle-linux-notes
description: Oracle Linux 8.10 특성 및 Docker Rootless 호환성 노트
metadata:
  type: reference
---

## Oracle Linux 8.10 + Docker Rootless 호환성

### 시스템 정보
- **OS**: Oracle Linux Server 8.10
- **ID_LIKE**: fedora (RHEL 계열, dnf 패키지 매니저 사용)
- **Kernel**: 5.15.0-306-generic (user namespace 지원)
- **패키지 매니저**: dnf (yum 대체)

### Rootless Docker 호환성 ✅
- **User namespace**: Kernel 3.10+ 요구 → 5.15.0-306 OK
- **cgroup v2**: Kernel 4.5+ 요구 → 5.15.0-306 OK
- **seccomp**: Kernel 3.17+ 요구 → 5.15.0-306 OK
- **subuid/subgid**: 시스템 기본 지원 (useradd 시 자동 할당)

### How to apply
- dnf 기반 설치: `dnf install docker-ce docker-ce-rootless-extras`
- 커널 설정 확인: `cat /proc/sys/user/max_user_namespaces` (0이 아니면 OK)
- user namespace 설정: `usermod --add-subuids/subgids` (필요시)

### 주의사항
- **SELinux**: 기본 Enforcing → rootless와 양립 가능 (필요시 disabled 옵션 있음)
- **firewalld**: 기본 활성화 → 5000/tcp 수동 개방 필요
- **Docker 저장소**: `https://download.docker.com/linux/rhel/` 사용 (CentOS/Rocky와 동일)
- **systemd 호환**: 사용자 systemd 활성화 (`systemctl --user` 사용)

### dnf 패키지 관리
- Docker 저장소 추가: `dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo`
- 버전 확인: `dnf list docker-ce --showduplicates`
- 설치: `dnf install docker-ce-<버전> docker-ce-cli-<버전> docker-ce-rootless-extras`
- 롤백: 동일한 dnf 명령으로 이전 버전 설치 가능 (패키지 버전 지정)

### 다른 배포판과의 차이점
- **Debian/Ubuntu**: `apt` 사용, `/etc/apt/sources.list.d/` 관리
- **RHEL/CentOS**: dnf (또는 yum), `/etc/yum.repos.d/` 관리 (Oracle Linux 동일)
- **Alpine**: apk 사용, 패키지 수 제한
- → Oracle Linux는 RHEL/CentOS와 거의 동일한 절차 따름

### Docker Hub 미러/프록시 설정 (필요시)
- 프록시: `/etc/docker/daemon.json`에 `"registry-mirrors": ["http://..."]` 추가
- 또는 Docker 저장소 주소 HTTP 미러 사용 (HTTPS 차단 시)
