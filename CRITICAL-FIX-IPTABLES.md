# 🔧 중요 수정: A-1 iptables 설치 단계 추가

**수정 내용**: Phase A에 새로운 **A-1단계** 추가  
**이유**: bridge 모드/포트 바인딩을 위해 iptables 필수  
**타이밍**: A-2 Docker 설치 **전에** 반드시 실행

---

## 🚨 정정된 Phase A 흐름

```
기존 (잘못됨):
A-0: 환경 확인 → A-2: Docker 설치 ❌ (iptables 부족)

수정됨 (올바름):
A-0: 환경 확인
  ↓
A-1: iptables 모듈 로드 ✅ (새로 추가!)
  ↓
A-2: Rootless Docker 설치 (정상 진행 가능)
  ↓
A-3: 레지스트리 이미지 다운로드
  ↓
A-4: 파일 패키징
```

---

## ✅ A-1: iptables 모듈 로드 (5분) - 필수 추가 단계

### 에러 메시지에서 제시한 방법 그대로 실행

```bash
# 외부 VM에서 실행

# 🔧 이 명령어 바로 실행!
cat <<EOF | sudo sh -x
modprobe iptables_filter
modprobe ip_tables
modprobe iptables_nat
modprobe nf_nat
modprobe nf_conntrack
EOF

# 또는 각각 실행
$ sudo modprobe iptables_filter
$ sudo modprobe ip_tables
$ sudo modprobe iptables_nat
```

### 확인

```bash
# 로드되었는지 확인
$ lsmod | grep iptables
# 예상: iptables_filter 나타나야 함 ✅
```

### 왜 필요한가?

```
bridge 모드 작동 원리:
├─ 컨테이너 내부 포트 (5000) 
├─ bridge 네트워크 (docker0)
├─ ✅ iptables NAT 규칙 (포트 포워딩)
│  └─ 5000 → 호스트:5000 매핑
└─ 외부 접근 가능

iptables 없으면:
├─ NAT 규칙 설정 불가 ❌
├─ 포트 포워딩 불가 ❌
└─ docker run -p 5000:5000 실패 ❌
```

---

## 📋 수정된 Phase A 전체 순서

| 단계 | 작업 | 시간 | 필수 |
|------|------|------|------|
| A-0 | 환경 확인 | 5분 | ⭐ |
| **A-1** | **iptables 설치** | **5분** | **⭐⭐⭐** |
| A-2 | Docker 설치 | 10분 | ⭐ |
| A-3 | 이미지 다운로드 | 10분 | ⭐ |
| A-4 | 파일 패키징 | 15분 | ⭐ |
| **합계** | | **45분** | |

---

## 🔍 현재 외부 VM 상태 (스크린샷 기반)

```
✅ A-0: 환경 확인 완료
└─ OS: Oracle Linux 8.10 ✅
└─ Kernel: 5.15.0-206.153... ✅

❌ A-1: iptables 설치 안 됨 ← 지금 여기!
└─ Error: "Missing system requirements"
└─ 해결: cat <<EOF | sudo sh -x ... 실행 필요

⏳ A-2: Docker 설치 대기 (A-1 완료 후)
⏳ A-3: 이미지 다운로드 대기
⏳ A-4: 파일 패키징 대기
```

---

## 🚀 지금 바로 실행할 것

**외부 VM에서**:

```bash
# Step 1: iptables 모듈 로드 (에러 메시지에서 제시한 명령)
cat <<EOF | sudo sh -x
modprobe iptables_filter
modprobe ip_tables
modprobe iptables_nat
modprobe nf_nat
modprobe nf_conntrack
EOF

# Step 2: 확인
$ lsmod | grep iptables
# iptables_filter ... 나타나야 함

# Step 3: 이제 Docker 설치 진행 (정상 진행)
$ curl -fsSL https://get.docker.com/rootless | bash

# Step 4: 검증
$ docker --version
$ systemctl --user status docker
```

---

## 📚 참고 문서

- **[PHASE-A-CORRECTED.md](PHASE-A-CORRECTED.md)** ← 수정된 A-0~A-4 전체 절차
- [EXECUTION-PLAN-FINAL.md](EXECUTION-PLAN-FINAL.md) ← A-1 추가로 업데이트됨

---

## ⚠️ 주의

- **A-1은 A-2 전에 반드시 실행**
- A-0과 A-1을 건너뛰면 A-2에서 같은 에러 반복
- iptables = bridge 모드/포트 바인딩 필수 → 팀서버에서 레지스트리 5000포트 작동 필요

---

**상태**: ✅ 수정 완료. A-1 실행 후 A-2~A-4 진행하세요!
