<#
.SYNOPSIS
  MySQL 베이스 이미지 빌드 + servicetech2 레지스트리 push 스크립트 (PowerShell)

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+

  라이선스 주의사항
    - MySQL Community Server는 완전 오픈소스(GPLv2)이며 Docker Hub 공식 이미지
      사용에 별도 계정/라이선스 동의가 필요 없다 (Oracle EE와 달리 로그인 불필요).
    - 운영(production) 환경 사용 금지. 테스트/개발/데모 전용.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Namespace = "servicetech2"

function Write-Info($msg)  { Write-Host "[정보] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[완료] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[경고] $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "[오류] $msg" -ForegroundColor Red }

function Ask([string]$Prompt, [string]$Default = "") {
    if ($Default -ne "") {
        $val = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
        return $val
    } else {
        return Read-Host "$Prompt"
    }
}

Write-Host "=============================================================="
Write-Host " MySQL 베이스 이미지 빌드 + servicetech2 레지스트리 등록"
Write-Host "=============================================================="

# 개발 PC: localhost:5000 / 팀서버(new-servicetech2-1, 192.168.0.168): servicetech2:5000
# (hosts 파일 등록 + insecure-registry 등록 필요, registry-server/linux-registry-setup.md 참고)
Write-Host ""
$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "192.168.0.168:5000" }
$LocalRegistry = Ask "대상 레지스트리 주소 (호스트:포트)" $envDefault

Write-Host ""
Write-Host "DB 종류를 선택하세요 (현재는 MySQL만 지원):"
Write-Host "  1) MySQL"
$dbSel = Ask "번호 선택" "1"
if ($dbSel -ne "1") {
    Write-Err2 "현재는 MySQL만 지원합니다."
    exit 1
}
$DbKind = "mysql"

Write-Host ""
Write-Host "MySQL 버전을 선택하세요 (전부 계정/로그인 불필요, 공개 이미지):"
Write-Host "  1) latest  (최신 안정 버전)"
Write-Host "  2) 8.4     (LTS)"
Write-Host "  3) 8.0     (구버전 LTS, 레거시 호환용)"
$VerSel = Ask "번호 선택" "1"
switch ($VerSel) {
    "1" { $UpstreamImage = "mysql:latest"; $Tag = "latest" }
    "2" { $UpstreamImage = "mysql:8.4";    $Tag = "8.4" }
    "3" { $UpstreamImage = "mysql:8.0";    $Tag = "8.0" }
    default { Write-Err2 "잘못된 선택입니다."; exit 1 }
}
$TargetImage = "$LocalRegistry/$Namespace/${DbKind}:$Tag"
Write-Ok "선택됨: $UpstreamImage -> $TargetImage"

try {
    Invoke-WebRequest -Uri "http://$LocalRegistry/v2/" -UseBasicParsing -TimeoutSec 3 | Out-Null
} catch {
    Write-Err2 "로컬 레지스트리($LocalRegistry)가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.ps1 을 실행하세요."
    exit 1
}

Write-Info "상위 이미지를 내려받는 중입니다: $UpstreamImage"
docker pull $UpstreamImage
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "상위 이미지 pull 실패. 네트워크 상태를 확인하고 재시도하세요."
    exit 1
}

Write-Info "베이스 이미지를 빌드합니다: $TargetImage"
docker build --build-arg "BASE_IMAGE=$UpstreamImage" -t $TargetImage -f Dockerfile .
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "이미지 빌드 실패."
    exit 1
}

Write-Info "레지스트리로 push 합니다: $TargetImage"
docker push $TargetImage
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "레지스트리 push 실패 (네트워크 타임아웃 등). 재시도하려면 이 스크립트를 다시 실행하거나 'docker push $TargetImage'를 직접 실행하세요."
    exit 1
}

# push 성공 여부를 명령 종료 코드만으로 판단하지 않고, 실제로 태그가 조회되는지 재확인
# 주의: `docker manifest inspect`는 이 프로젝트의 insecure(TLS 미적용) 레지스트리에서
# 실제로는 태그가 정상 존재해도 "no such manifest" 오탐을 내는 경우가 확인됨(2026-08-25) —
# 그래서 레지스트리 REST API(/v2/.../tags/list)를 직접 조회하는 방식으로 검증한다.
Write-Info "push 결과를 재확인합니다..."
$TagFound = $false
try {
    $tagsResp = Invoke-WebRequest -Uri "http://$LocalRegistry/v2/$Namespace/${DbKind}/tags/list" -UseBasicParsing -TimeoutSec 5
    if ($tagsResp.Content -match [regex]::Escape("`"$Tag`"")) { $TagFound = $true }
} catch {
    $TagFound = $false
}
if (-not $TagFound) {
    Write-Err2 "push 명령은 끝났지만 레지스트리에서 해당 태그가 확인되지 않습니다 (일부 레이어 업로드 실패 가능성). 'docker push $TargetImage'를 다시 실행하세요."
    exit 1
}
Write-Ok "레지스트리에서 태그 확인 완료"

Write-Host ""
Write-Host "======================= 완료 ======================="
Write-Host " 상위 이미지   : $UpstreamImage"
Write-Host " 등록된 이미지 : $TargetImage"
Write-Host "======================================================"
