<#
.SYNOPSIS
  OmnioneCX DB — 저축은행중앙회(fsb) 전용 이미지 빌드 + servicetech2 레지스트리 push (PowerShell)

.DESCRIPTION
  initdb\ 안의 DDL/DML은 이 사이트 전용 데이터를 이미 반영한 상태(git으로
  추적, 민감정보 없음 -- 스키마와 초기 참조 데이터일 뿐).
  대상 베이스: mariadb/base로 이미 레지스트리에 등록된 servicetech2/mariadb 이미지.

  db/verifier/oacx는 각각 하나의 리포지토리로 통합 관리된다. DB는 자체
  버전 번호가 없어 보통 사이트 코드 하나만 태그로 쓰지만(버전=사이트 코드로
  동일하게 입력하면 태그 1개만 push됨), 참고용 라벨을 별도로 남기고 싶으면
  서로 다른 값을 입력해도 된다(그 경우 2개 push).
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Namespace = "servicetech2"
$ImageKind = "omnionecx-db"
$Site = "저축은행중앙회(fsb)"
$DefaultSiteTag = "fsb"
$DefaultVersion = "fsb"

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

function Confirm([string]$Prompt = "계속 진행할까요?") {
    $val = Read-Host "$Prompt (y/n) [y]"
    if ([string]::IsNullOrWhiteSpace($val)) { $val = "y" }
    return $val -match '^[Yy]'
}

Write-Host "=============================================================="
Write-Host " OmnioneCX DB ($Site) 이미지 빌드 + 레지스트리 등록"
Write-Host "=============================================================="

# ============================================================================
# 0. 사전 체크리스트
# ============================================================================
Write-Host ""
Write-Host "-------- 사전 체크리스트 --------"
if (-not (Confirm "이번에 반영할 DDL/DML(initdb) 업데이트가 하나만 있습니까? (여러 변경사항이 섞여있지 않은지 확인)")) {
    Write-Err2 "체크리스트 확인에서 중단했습니다. 변경사항을 하나로 정리한 뒤 다시 실행하세요."
    exit 1
}
if (-not (Confirm "이번 업데이트 내용(무엇이, 왜 바뀌었는지)을 정확히 파악하고 계십니까?")) {
    Write-Err2 "체크리스트 확인에서 중단했습니다. 업데이트 내용을 먼저 확인하세요."
    exit 1
}

# ============================================================================
# 1. 사이트 코드 / 버전 정보 / 레지스트리 주소
# ============================================================================
Write-Host ""
$SiteTag = Ask "사이트 코드 (이동 태그로 사용 -- 이 사이트가 현재 쓰는 이미지를 가리킴)" $DefaultSiteTag
$Version = Ask "참고용 버전/라벨 (DB는 자체 버전이 없음 -- 사이트 코드와 같은 값이면 태그 1개만 push)" $DefaultVersion

Write-Host ""
$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "192.168.0.168:5000" }
$LocalRegistry = Ask "대상 레지스트리 주소 (호스트:포트)" $envDefault
try { Invoke-WebRequest -Uri "http://$LocalRegistry/v2/" -UseBasicParsing -TimeoutSec 3 | Out-Null }
catch { Write-Err2 "로컬 레지스트리($LocalRegistry)가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.ps1 을 실행하세요."; exit 1 }

$TargetImage = "$LocalRegistry/$Namespace/${ImageKind}:$Version"
$MovingImage = "$LocalRegistry/$Namespace/${ImageKind}:$SiteTag"
$BaseImage = "$LocalRegistry/$Namespace/mariadb:latest"

# ============================================================================
# 2. 최종 요약 + 실행 확인
# ============================================================================
Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 사이트        : $Site"
Write-Host " 레지스트리    : $LocalRegistry"
Write-Host " 베이스 이미지 : $BaseImage"
Write-Host " 등록될 이미지 : $TargetImage"
if ($Version -ne $SiteTag) {
    Write-Host "              : $MovingImage (이동 태그, 이 사이트가 현재 쓰는 이미지)"
}
Write-Host "==========================================================="
if (-not (Confirm "위 내용으로 빌드하고 레지스트리로 push할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

# ============================================================================
# 3. 빌드 + push
# ============================================================================
Write-Info "베이스 이미지를 내려받는 중입니다: $BaseImage"
docker pull $BaseImage
if ($LASTEXITCODE -ne 0) { Write-Err2 "베이스 이미지 pull 실패. mariadb/base/build-and-push.ps1(.sh) 로 먼저 등록하세요."; exit 1 }

Write-Info "이미지를 빌드합니다: $TargetImage"
docker build --build-arg "BASE_IMAGE=$BaseImage" -t $TargetImage -f Dockerfile .
if ($LASTEXITCODE -ne 0) { Write-Err2 "이미지 빌드 실패."; exit 1 }

$PushTargets = @($TargetImage)
if ($Version -ne $SiteTag) {
    docker tag $TargetImage $MovingImage
    $PushTargets += $MovingImage
}

foreach ($img in $PushTargets) {
    Write-Info "레지스트리로 push 합니다: $img"
    docker push $img
    if ($LASTEXITCODE -ne 0) { Write-Err2 "레지스트리 push 실패 (네트워크 타임아웃 등). 재시도하려면 이 스크립트를 다시 실행하거나 'docker push $img'를 직접 실행하세요."; exit 1 }
}

Write-Info "push 결과를 재확인합니다..."
try { $TagsJson = (Invoke-WebRequest -Uri "http://$LocalRegistry/v2/$Namespace/$ImageKind/tags/list" -UseBasicParsing -TimeoutSec 5).Content }
catch { $TagsJson = "" }
$missing = $false
foreach ($t in @($Version, $SiteTag)) {
    if ($TagsJson -notmatch [regex]::Escape("`"$t`"")) { $missing = $true }
}
if ([string]::IsNullOrEmpty($TagsJson) -or $missing) {
    Write-Err2 "push 명령은 끝났지만 레지스트리에서 태그가 모두 확인되지 않습니다."
    exit 1
}
Write-Ok "레지스트리에서 태그 확인 완료"

Write-Host ""
Write-Host "======================= 완료 ======================="
Write-Host " 등록된 이미지 : $TargetImage"
if ($Version -ne $SiteTag) {
    Write-Host "              : $MovingImage"
}
Write-Host "======================================================"
