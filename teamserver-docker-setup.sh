#!/bin/bash
# ============================================
# Docker Registry 팀서버 세팅 스크립트
# 용도: 히스토리 관리 및 재설치용
# ============================================

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✅]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠️ ]${NC} $1"
}

log_error() {
    echo -e "${RED}[❌]${NC} $1"
}

# 시작
echo "=========================================="
echo "Docker Registry 팀서버 세팅"
echo "=========================================="
echo ""

# 1. 사전 조건 확인
log_info "1. 사전 조건 확인 중..."

if [ ! -f "/home/servicetech2/upload/docker/docker-offline-package.tar.gz" ]; then
    log_error "패키지 파일을 찾을 수 없습니다"
    log_error "경로: /home/servicetech2/upload/docker/docker-offline-package.tar.gz"
    exit 1
fi

log_success "패키지 파일 확인됨"

# 2. 체크섬 검증
log_info "2. 체크섬 검증 중..."

cd /home/servicetech2/upload/docker/

if [ ! -f "docker-offline-package.sha256" ]; then
    log_warn "체크섬 파일이 없습니다. 생략합니다"
else
    if sha256sum -c docker-offline-package.sha256 > /dev/null 2>&1; then
        log_success "체크섬 검증 완료"
    else
        log_error "체크섬 검증 실패!"
        exit 1
    fi
fi

# 3. 기존 Docker 정리
log_info "3. 기존 Docker 정리 중..."

sudo systemctl stop docker 2>/dev/null || true
pkill -9 -f dockerd 2>/dev/null || true
pkill -9 -f rootlesskit 2>/dev/null || true
pkill -9 -f slirp4netns 2>/dev/null || true

log_success "정리 완료"

# 4. 바이너리 설치
log_info "4. 바이너리 설치 중..."

sudo mkdir -p /usr/local/bin
sudo cp docker-offline-package/bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/docker*
sudo chmod +x /usr/local/bin/containerd*
sudo chmod +x /usr/local/bin/runc
sudo chmod +x /usr/local/bin/ctr

# 심링크 생성 (root 접근용)
sudo ln -sf /usr/local/bin/docker /usr/bin/docker
sudo ln -sf /usr/local/bin/dockerd /usr/bin/dockerd

BINARY_COUNT=$(ls -1 /usr/local/bin/docker* 2>/dev/null | wc -l)
log_success "바이너리 설치 완료 ($BINARY_COUNT개)"

# 5. iptables 모듈 로드
log_info "5. iptables 모듈 로드 중..."

sudo modprobe ip_tables 2>/dev/null || true
sudo modprobe iptable_nat 2>/dev/null || true
sudo modprobe iptable_filter 2>/dev/null || true
sudo modprobe iptable_mangle 2>/dev/null || true

log_success "iptables 모듈 로드 완료"

# 6. systemd 파일 설정
log_info "6. systemd 파일 설정 중..."

sudo mkdir -p /etc/systemd/system

sudo tee /etc/systemd/system/docker.service > /dev/null <<'EOF'
[Unit]
Description=Docker
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd -H unix:///var/run/docker.sock --userland-proxy-path=/usr/local/bin/docker-proxy
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
log_success "systemd 파일 설정 완료"

# 7. Docker 시작
log_info "7. Docker 데몬 시작 중..."

sudo systemctl enable docker
sudo systemctl start docker
sleep 5

if sudo systemctl is-active --quiet docker; then
    log_success "Docker 데몬 시작됨"
else
    log_error "Docker 데몬 시작 실패!"
    sudo systemctl status docker
    exit 1
fi

# 8. Registry 이미지 로드
log_info "8. Registry 이미지 로드 중..."

sudo docker load < docker-offline-package/images/registry-2.tar

IMAGE_COUNT=$(sudo docker images registry 2>/dev/null | grep -c registry || echo "0")
if [ "$IMAGE_COUNT" -gt 0 ]; then
    log_success "Registry 이미지 로드 완료"
else
    log_error "Registry 이미지 로드 실패!"
    exit 1
fi

# 9. Registry 컨테이너 시작
log_info "9. Registry 컨테이너 시작 중..."

# 기존 컨테이너 제거
sudo docker rm -f registry 2>/dev/null || true

# 새 컨테이너 시작
CONTAINER_ID=$(sudo docker run -d -p 5000:5000 --name registry registry:2)

sleep 3

if sudo docker ps | grep -q registry; then
    log_success "Registry 컨테이너 시작됨 (ID: ${CONTAINER_ID:0:12})"
else
    log_error "Registry 컨테이너 시작 실패!"
    sudo docker logs registry
    exit 1
fi

# 10. 최종 검증
log_info "10. 최종 검증 중..."

echo ""
echo "=== Docker 정보 ==="
docker --version

echo ""
echo "=== Docker 프로세스 ==="
sudo docker ps

echo ""
echo "=== Registry 로그 ==="
sudo docker logs registry | tail -3

echo ""
echo "=== Registry API 테스트 ==="
if curl -s http://localhost:5000/v2/ | grep -q "{}"; then
    log_success "Registry API 정상 응답"
else
    log_warn "Registry API 테스트 실패 (네트워크 문제일 수 있음)"
fi

echo ""
echo "=========================================="
log_success "Docker Registry 설정 완료!"
echo "=========================================="
echo ""
echo "📌 다음 단계:"
echo "1. 방화벽 오픈 (팀장님 승인 후)"
echo "   sudo firewall-cmd --permanent --add-port=5000/tcp"
echo "   sudo firewall-cmd --reload"
echo ""
echo "2. 레지스트리 주소: http://new-servicetech2-1:5000"
echo ""
echo "3. 확인 명령어:"
echo "   curl http://localhost:5000/v2/"
echo "   sudo docker ps"
echo ""
