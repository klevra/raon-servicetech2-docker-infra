<#
.SYNOPSIS
  OmnioneCX oacx — 저축은행중앙회(fsb) 전용 이미지 빌드 + push (PowerShell)

.DESCRIPTION
  WAR(app) 콘텐츠를 이미지 안에 미리 COPY해서 넣어둔다. config(server.properties,
  provider.json 등 환경별로 달라지는 값)는 여전히 배포 시점에 바인드마운트로
  주입한다.

  이 사이트의 산출물은 web.xml이 없고 web_normal.xml/web_mtranskey.xml
  두 변형으로 제공된다 -- fsb는 보안키패드(mTransKey) 없이 배포하므로
  web_normal.xml을 web.xml로 사용한다. (실제 변환은 Dockerfile이 빌드 시점에
  처리함)

  전제조건: 이 스크립트와 같은 위치의 app\ 안에 실제 oacx 실행 산출물
            (index.html, WEB-INF\ 등)이 있어야 한다. app\은 실제 배포
            산출물이라 git에는 커밋하지 않음 (.gitignore 확인).
  대상 베이스: tomcat/base로 이미 레지스트리에 등록된 servicetech2/tomcat9-jdk8 이미지.

  db/verifier/oacx는 각각 하나의 리포지토리로 통합 관리된다. 태그는 실제
  버전 번호를 쓰고, 사이트 코드(이동 태그)는 "이 사이트가 현재 쓰는 버전"을
  가리키도록 매번 갱신된다. 사이트 코드/버전은 실행할 때 물어보며(기본값은
  이 사이트에 고정된 값), 새 버전을 올릴 때 이 파일을 직접 열어 고칠 필요가
  없다 -- 프롬프트에서 새 값을 입력하면 된다.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Namespace = "servicetech2"
$ImageKind = "omnionecx-oacx"
$Site = "저축은행중앙회(fsb)"
$DefaultSiteTag = "fsb"
$DefaultVersion = "1.0.0.3"

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
Write-Host " OmnioneCX oacx ($Site) 이미지 빌드 + 레지스트리 등록"
Write-Host "=============================================================="

# ============================================================================
# 0. 사전 체크리스트
# ============================================================================
Write-Host ""
Write-Host "-------- 사전 체크리스트 --------"
if (-not (Confirm "이번에 반영할 app 산출물 업데이트가 하나만 있습니까? (여러 변경사항이 섞여있지 않은지 확인)")) {
    Write-Err2 "체크리스트 확인에서 중단했습니다. 변경사항을 하나로 정리한 뒤 다시 실행하세요."
    exit 1
}
if (-not (Confirm "이번 업데이트 내용(무엇이, 왜 바뀌었는지)을 정확히 파악하고 계십니까?")) {
    Write-Err2 "체크리스트 확인에서 중단했습니다. 업데이트 내용을 먼저 확인하세요."
    exit 1
}

# ============================================================================
# 1. app 산출물 확인
# ============================================================================
$AppDir = Join-Path $ScriptDir "app"
$WebInfDir = Join-Path $AppDir "WEB-INF"
if (-not (Test-Path $AppDir -PathType Container) -or -not (Test-Path $WebInfDir -PathType Container)) {
    Write-Err2 "app 폴더(또는 app\WEB-INF)가 없습니다: $AppDir (실제 oacx 산출물을 먼저 복사하세요)"
    exit 1
}
Write-Ok "산출물 확인: $AppDir"

# ============================================================================
# 2. 사이트 코드 / 버전 정보 / 레지스트리 주소
# ============================================================================
Write-Host ""
$SiteTag = Ask "사이트 코드 (이동 태그로 사용 -- 이 사이트가 현재 쓰는 버전을 가리킴)" $DefaultSiteTag
$Version = Ask "OACX 실제 버전 번호 (레지스트리 태그로 쓰임, app의 실제 버전과 일치해야 함)" $DefaultVersion

Write-Host ""
$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "192.168.0.168:5000" }
$LocalRegistry = Ask "대상 레지스트리 주소 (호스트:포트)" $envDefault
try { Invoke-WebRequest -Uri "http://$LocalRegistry/v2/" -UseBasicParsing -TimeoutSec 3 | Out-Null }
catch { Write-Err2 "로컬 레지스트리($LocalRegistry)가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.ps1 을 실행하세요."; exit 1 }

$TargetImage = "$LocalRegistry/$Namespace/${ImageKind}:$Version"
$MovingImage = "$LocalRegistry/$Namespace/${ImageKind}:$SiteTag"
$BaseImage = "$LocalRegistry/$Namespace/tomcat9-jdk8:9-jdk8"

# ============================================================================
# 3. 최종 요약 + 실행 확인
# ============================================================================
Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 사이트        : $Site"
Write-Host " 레지스트리    : $LocalRegistry"
Write-Host " 베이스 이미지 : $BaseImage"
Write-Host " 등록될 이미지 : $TargetImage (실제 버전, 고정/롤백용)"
if ($Version -ne $SiteTag) {
    Write-Host "              : $MovingImage (이동 태그, 이 사이트가 현재 쓰는 버전)"
}
Write-Host "==========================================================="
if (-not (Confirm "위 내용으로 빌드하고 레지스트리로 push할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

# ============================================================================
# 4. 빌드 + push
# ============================================================================
Write-Info "베이스 이미지를 내려받는 중입니다: $BaseImage"
docker pull $BaseImage
if ($LASTEXITCODE -ne 0) { Write-Err2 "베이스 이미지 pull 실패. tomcat/base/build-and-push.ps1(.sh) 로 먼저 등록하세요."; exit 1 }

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
    Write-Err2 "push 명령은 끝났지만 레지스트리에서 태그가 모두 확인되지 않습니다 (일부 레이어 업로드 실패 가능성). 이 스크립트를 다시 실행하세요."
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
