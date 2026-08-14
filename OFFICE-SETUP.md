# 사무실 PC 작업 환경 이관 가이드

- 작성일: 2026-08-13
- 배경: 메인 PC(개인)에서 진행하던 작업을 사무실 PC로 이관. 사무실 PC는 Docker/Git 등 기본 도구는 이미 설치되어 있음.
- 방침: 사무실 PC에서는 이 PC의 로컬 레지스트리(`localhost:5000`)를 재구축하지 않고, 이미 구축한 **사내 Linux 레지스트리(`servicetech2-registry`)만 사용**한다.

> 이 문서는 사무실 PC에서 **새 Claude Code 세션**을 시작해 그대로 따라 실행하기 위한 체크리스트입니다.

---

## 1. 저장소 클론

```bash
git clone https://github.com/klevra/raon-servicetech2-docker-infra.git
cd raon-servicetech2-docker-infra
```

## 2. GitHub 인증

```bash
gh auth login
```
- **GitHub.com → HTTPS → Login with a web browser** 순으로 진행
- 이 PC(메인 PC)와 **동일한 `klevra` 계정**으로 로그인 (RULES.md 7번 규칙에 따라 이후 실질 변경 시 자동 push되므로, push 권한이 있는 계정이어야 함)

## 3. 사내 Linux 레지스트리 연결 (hosts + insecure-registries)

이 PC에서 만든 `localhost:5000`은 사무실 PC에서는 사용하지 않습니다. 대신 사내 Linux 서버의 `servicetech2-registry`를 바로 사용합니다. 절차는 [registry-server/linux-registry-setup.md](registry-server/linux-registry-setup.md)의 **3, 4번 섹션**과 동일합니다.

### 3-1. hosts 파일 등록 (관리자 권한 PowerShell)
```powershell
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "`n<서버IP>  servicetech2-registry" -Encoding ascii
```
`<서버IP>`는 실제 사내 Linux 레지스트리 서버의 IP로 치환.

### 3-2. Docker Desktop insecure-registries 등록
Docker Desktop → **Settings → Docker Engine** → JSON에 추가:
```json
{
  "insecure-registries": ["servicetech2-registry:5000"]
}
```
**Apply & Restart**.

### 3-3. 연결 확인
```bash
curl -s http://servicetech2-registry:5000/v2/_catalog
```
등록된 이미지 목록(JSON)이 반환되면 정상입니다.

## 4. Oracle 계정 인증 (다시 필요함 — 머신별 로컬 저장이라 이관되지 않음)

Oracle 계정(`sadviolent@gmail.com`) 자체는 동일하게 재사용하지만, `docker login container-registry.oracle.com`에 사용하는 **Auth Token은 이 PC의 Docker credential store에만 저장되어 있어 사무실 PC로 자동으로 넘어가지 않습니다.**

19c Enterprise Edition 관련 작업을 사무실 PC에서 처음 할 때, `oracle/base/build-and-push.sh` 또는 `.ps1`가 로그인 여부를 자동 감지해서, 필요하면 Auth Token을 다시 물어봅니다. 이때:
1. https://container-registry.oracle.com 접속 → 계정 아이콘 → **Auth Token** 메뉴에서 토큰을 새로 발급(기존 토큰 재사용 가능하면 그걸 써도 되고, 새로 발급해도 무방)
2. 스크립트가 물어보면 그 토큰을 입력

## 5. 스크립트 실행 시 레지스트리 주소 입력

이번에 스크립트를 수정해서, `oracle/base/build-and-push.sh(.ps1)`와 `oracle/deploy/deploy.sh(.ps1)` 실행 시 **레지스트리 주소를 대화형으로 물어보도록** 변경했습니다 (기존엔 `localhost:5000`으로 고정되어 있었음). 사무실 PC에서 실행할 때:

```
대상 레지스트리 주소 (호스트:포트) [localhost:5000]: servicetech2-registry:5000
```

이렇게 `servicetech2-registry:5000`을 입력하면 됩니다. 매번 입력하기 번거로우면 환경변수로 기본값을 바꿀 수 있습니다:

```bash
export REGISTRY_ADDR=servicetech2-registry:5000   # bash
```
```powershell
$env:REGISTRY_ADDR = "servicetech2-registry:5000"  # PowerShell
```
이렇게 설정해두면 프롬프트의 기본값이 자동으로 `servicetech2-registry:5000`으로 바뀝니다 (그냥 Enter만 치면 됨).

## 6. VSCode / Claude Code 관련 — 이관되지 않는 설정

- `.claude/settings.local.json`은 `.gitignore`에 포함되어 있어 저장소에 없습니다. 사무실 PC에서 Claude Code 사용 중 권한 프롬프트가 새로 뜰 수 있습니다 — 정상입니다.
- RULES.md 4번 규칙(**"Enable Remote Control for all sessions"** 토글)은 VSCode 확장 자체 설정이라 파일로 이관되지 않습니다. 사무실 PC의 VSCode 확장 Settings에서 별도로 켜야 합니다.

## 7. 확인 체크리스트

- [ ] `git clone` 완료, `git log`로 커밋 히스토리 보이는지 확인
- [ ] `gh auth status`로 로그인 확인
- [ ] `curl http://servicetech2-registry:5000/v2/_catalog` 정상 응답
- [ ] `docker pull servicetech2-registry:5000/servicetech2/oracle:19c` (이미 등록된 이미지가 있다면) 정상 pull
- [ ] VSCode Remote Control 토글 확인
- [ ] `oracle/deploy/deploy.sh`(or `.ps1`) 실행해서 레지스트리 주소 프롬프트에 `servicetech2-registry:5000` 정상 입력되는지 확인

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-08-13 | 최초 작성. 사무실 PC는 로컬 레지스트리 재구축 없이 사내 Linux 레지스트리만 사용하기로 결정. 이에 맞춰 `build-and-push`/`deploy` 스크립트의 레지스트리 주소를 하드코딩에서 대화형 입력(+`REGISTRY_ADDR` 환경변수 기본값)으로 변경. |
