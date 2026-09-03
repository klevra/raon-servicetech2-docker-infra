<#
.SYNOPSIS
  OmnioneCX 통합 배포 스크립트 (PowerShell) — 우리투자증권(wooriib) 전용, 버전 고정 이미지 트랙

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  전제조건 : oracle/registry/setup-registry.ps1 로 레지스트리가 떠있어야 하고,
             db/verifier/oacx 각각의 build-and-push.sh(.ps1) 로 이 사이트
             전용 이미지(omnionecx-{db,verifier,oacx}-wooriib)가 레지스트리에
             이미 등록되어 있어야 함.

  omnionecx/default 트랙과의 차이 (모두 상위 폴더(..\db, ..\verifier, ..\oacx)의
  세 Dockerfile에 빌트인됨):
    - verifier/oacx: app(JAR/WAR)이 이미지 안에 있음 -- app 스테이징 없음
    - DB: DDL/DML이 이미지 안에 있음 -- DDL_DIR/DML_DIR 수령 없음
    - PARTNER_CODE는 배포 시점에 물어봄(기본값 'raon') -- OPER_SORT와 같은
      방식(플레이스홀더 + 컨테이너 최초 기동 시 치환)으로 DB 이미지에 반영됨
    - DB 데이터는 DbDataDir에 영속화됨 (default는 휘발성이었음)

  그래서 이 스크립트가 하는 일은 3가지뿐이다:
    1) DB 접속정보/운영·개발/포트/경로 등 값을 수령
    2) verifier/oacx config를 sandbox 원본에 직접 패치 (default와 동일한 방식)
    3) 레지스트리에서 세 이미지를 pull 하고 compose로 기동

  비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Namespace = "servicetech2"
$Site = "우리투자증권(wooriib)"
$DbVersionTag = "latest"          # 사이트 전용 DB 이미지는 독립 버전 없이 latest 고정
$VerifierVersionTag = "1.3.25_fix"
$OacxVersionTag = "1.0.0.9"

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

function Ask-Secret([string]$Prompt, [string]$Default = "") {
    $promptLabel = if ($Default -ne "") { "$Prompt [입력 없으면 기본값 사용]" } else { $Prompt }
    if ([Console]::IsInputRedirected) {
        $val = Read-Host "$promptLabel"
    } else {
        $secure = Read-Host "$promptLabel" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $val = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrEmpty($val)) { return $Default }
    return $val
}

function Confirm([string]$Prompt = "계속 진행할까요?") {
    $val = Read-Host "$Prompt (y/n) [y]"
    if ([string]::IsNullOrWhiteSpace($val)) { $val = "y" }
    return $val -match '^[Yy]'
}

function Confirm-No([string]$Prompt = "계속 진행할까요?") {
    $val = Read-Host "$Prompt (y/n) [n]"
    if ([string]::IsNullOrWhiteSpace($val)) { $val = "n" }
    return $val -match '^[Yy]'
}

function New-RandomPassword {
    $pool = (48..57) + (65..90) + (97..122)
    return -join ($pool | Get-Random -Count 20 | ForEach-Object { [char]$_ })
}

function Read-Utf8File([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Write-Utf8File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "=============================================================="
Write-Host " OmnioneCX $Site 통합 배포 (버전 고정 이미지 트랙)"
Write-Host " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
Write-Host "=============================================================="

# ============================================================================
# 1. 설정값 일괄 수령
# ============================================================================
Write-Host ""
Write-Host "########## 1단계: 설정값 일괄 수령 ##########"

Write-Host ""
Write-Host "이 배포가 어떤 환경을 대상으로 하는지 선택하세요:"
Write-Host "  1) 개발 (기본값)"
Write-Host "  2) 운영"
$EnvSel = Ask "번호 선택" "1"
switch ($EnvSel) {
    "1" { $DeployEnv = "개발"; $OperSort = "dev";  $DidFileName = "raondev2.sp.did" }
    "2" { $DeployEnv = "운영"; $OperSort = "prod"; $DidFileName = "raonEnt.did" }
    default { Write-Err2 "잘못된 선택입니다."; exit 1 }
}
if ($DeployEnv -eq "운영") {
    Write-Warn2 "이 스크립트는 데이터가 DbDataDir 볼륨에만 영속화되는 테스트/개발용 배포입니다."
    if (-not (Confirm-No "정말로 '운영' 환경 대상으로 진행할까요? (권장하지 않음)")) {
        Write-Err2 "사용자가 취소했습니다."
        exit 1
    }
}

Write-Host ""
$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "192.168.0.168:5000" }
$LocalRegistry = Ask "대상 레지스트리 주소 (호스트:포트)" $envDefault
try { Invoke-WebRequest -Uri "http://$LocalRegistry/v2/" -UseBasicParsing -TimeoutSec 3 | Out-Null }
catch { Write-Err2 "로컬 레지스트리($LocalRegistry)가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.ps1 을 실행하세요."; exit 1 }

Write-Host ""
$NetworkName = Ask "공용 네트워크 이름" "omnionecx-net"

Write-Host ""
$PartnerCode = Ask "VF_ORGANIZATION.PARTNER_CODE / provider.json partnerCode 공통값" "raon"

Write-Host ""
Write-Host "-------- config 설정값 업데이트 여부 --------"
Write-Info "verifier/oacx가 마운트할 config 안의 DB 접속정보(jdbc/datasource)를 이번 배포값으로 덮어쓸지 선택하세요."
Write-Info "('아니오'를 선택하면 config에 이미 들어있는 값을 그대로 사용하고, DB도 그 값에 맞춰 자동으로 생성합니다.)"
$UpdateDbConfig = Confirm-No "DB 접속정보를 이번 배포값으로 업데이트할까요? (기본값 N = config의 값을 그대로 사용)"

Write-Host ""
$defaultVerifierRoot = Join-Path $ScriptDir "verifier"
if (Test-Path $defaultVerifierRoot -PathType Container) {
    $VerifierRoot = $defaultVerifierRoot
    Write-Ok "verifier 폴더를 찾았습니다: $VerifierRoot (경로 입력 생략)"
} else {
    $VerifierRoot = Ask "verifier 설정 루트 경로 (config/ 가 있는 위치)" "D:\03. Docker\sandbox\verifier"
}

Write-Host ""
Write-Host "-------- DB --------"
$DbImage = "$LocalRegistry/$Namespace/omnionecx-db-wooriib:$DbVersionTag"

$DsSrc = Join-Path $VerifierRoot "config\config\application-datasource.properties"
if ($UpdateDbConfig) {
    $DbContainer = Ask "DB 컨테이너 이름" "db"
    $DbName = Ask "DB(스키마) 이름 (verifier/oacx가 하나의 DB를 공유 -- 실제 운영값과 동일하게 기본 VC_VERIFIER)" "VC_VERIFIER"
    $AppUser = Ask "공용 앱 계정 이름" "omnione"
    $AppPassword = Ask-Secret "공용 앱 계정 비밀번호" "0mN1DB"
} else {
    if (-not (Test-Path $DsSrc)) {
        Write-Err2 "DB 접속정보를 config에서 읽어와야 하는데 파일을 찾을 수 없습니다: $DsSrc"
        exit 1
    }
    $dsSrcContent = Read-Utf8File $DsSrc
    $urlMatch = [regex]::Match($dsSrcContent, 'spring\.datasource\.url=jdbc:mariadb://([^:/\s]+)[^/\s]*/([^/?\s]+)')
    if (-not $urlMatch.Success) {
        Write-Err2 "config에서 DB 접속정보를 추출하지 못했습니다 ($DsSrc 확인 필요)."
        exit 1
    }
    $DbContainer = $urlMatch.Groups[1].Value
    $DbName = $urlMatch.Groups[2].Value
    $userMatch = [regex]::Match($dsSrcContent, 'spring\.datasource\.hikari\.username=(\S+)')
    $passMatch = [regex]::Match($dsSrcContent, 'spring\.datasource\.hikari\.password=(\S+)')
    if (-not $userMatch.Success) {
        Write-Err2 "config에서 DB 접속정보를 추출하지 못했습니다 ($DsSrc 확인 필요)."
        exit 1
    }
    $AppUser = $userMatch.Groups[1].Value
    $AppPassword = if ($passMatch.Success) { $passMatch.Groups[1].Value } else { "" }
    Write-Ok "config에서 DB 접속정보를 그대로 가져왔습니다: host(컨테이너명)=$DbContainer, db=$DbName, user=$AppUser"
}
$DbPort = Ask "DB 포트 (호스트에 노출할 포트, DBeaver 등 외부 툴 접속용)" "3306"

Write-Host ""
$defaultDbDataDir = Join-Path (Split-Path -Parent $VerifierRoot) "data\db"
$DbDataDir = Ask "DB 데이터 저장 경로 (컨테이너를 내렸다 올려도 유지됨 -- 이 경로에서 데이터 파일에 직접 접근 가능)" $defaultDbDataDir
New-Item -ItemType Directory -Force -Path $DbDataDir | Out-Null

Write-Host ""
Write-Warn2 "root 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
$DbRootPassword = Ask-Secret "root 초기 비밀번호 (비우면 랜덤 생성)" ""
$GeneratedPw = $false
if ([string]::IsNullOrEmpty($DbRootPassword)) {
    $DbRootPassword = New-RandomPassword
    $GeneratedPw = $true
}

Write-Host ""
Write-Host "-------- verifier --------"
Write-Info "verifier 설정 루트: $VerifierRoot (앞에서 이미 입력받음)"
$VfContainer = Ask "verifier 컨테이너 이름" "verifier"
$VfPort = Ask "verifier 포트" "48085"
$VerifierImage = "$LocalRegistry/$Namespace/omnionecx-verifier-wooriib:$VerifierVersionTag"

Write-Host ""
Write-Host "-------- oacx --------"
$defaultOacxRoot = Join-Path $ScriptDir "oacx"
if (Test-Path $defaultOacxRoot -PathType Container) {
    $OacxRoot = $defaultOacxRoot
    Write-Ok "oacx 폴더를 찾았습니다: $OacxRoot (경로 입력 생략)"
} else {
    $OacxRoot = Ask "OACX 설정 루트 경로 (config/ 가 있는 위치)" "D:\03. Docker\sandbox\oacx"
}
$OacxContainer = Ask "OACX 컨테이너 이름" "oacx"
$ContextPath = Ask "OACX Context path (URL: http://localhost:<포트>/<이 값>/)" "oacx"
$OacxHostPort = Ask "OACX 포트" "8080"
$OacxImage = "$LocalRegistry/$Namespace/omnionecx-oacx-wooriib:$OacxVersionTag"

Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 사이트        : $Site (OACX $OacxVersionTag / verifier $VerifierVersionTag)"
Write-Host " 배포 환경     : $DeployEnv (oper.mode/OperSort=$OperSort)"
$updateLabel = if ($UpdateDbConfig) { "예 (DB 접속정보를 아래 값으로 덮어씀)" } else { "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)" }
Write-Host " config 업데이트 : $updateLabel"
Write-Host " 네트워크      : $NetworkName"
Write-Host " DB            : $DbImage / $DbContainer / db=$DbName / port=$DbPort"
Write-Host " DB 데이터 경로 : $DbDataDir"
Write-Host " 공용 앱 계정  : $AppUser"
Write-Host " PARTNER_CODE  : $PartnerCode"
Write-Host " verifier      : $VerifierImage / $VfContainer (포트 $VfPort), root=$VerifierRoot"
Write-Host " oacx          : $OacxImage / $OacxContainer (포트 $OacxHostPort, /$ContextPath), root=$OacxRoot"
if ($GeneratedPw) { Write-Host " 생성된 root 비밀번호 : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==========================================================="
if (-not (Confirm "위 설정으로 전체 스택을 배포할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

foreach ($c in @($DbContainer, $VfContainer, $OacxContainer)) {
    $existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $c }
    if ($existing) {
        Write-Warn2 "이미 '$c' 컨테이너가 존재합니다. 삭제하고 새로 만듭니다."
        docker rm -f $c | Out-Null
    }
}

# ============================================================================
# 2. verifier config 패치 (sandbox 원본에 직접, 컨테이너는 이 원본을 그대로 마운트)
# ============================================================================
Write-Host ""
Write-Host "########## 2단계: verifier config 패치 ##########"

$VfConfigDir = Join-Path $VerifierRoot "config\config"
$DsProp = $DsSrc
if ($UpdateDbConfig -and (Test-Path $DsProp)) {
    $dsContent = Read-Utf8File $DsProp
    $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
    $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.hikari\.username=).*', ('${1}' + $AppUser))
    $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.hikari\.password=).*', ('${1}' + $AppPassword))
    Write-Utf8File $DsProp $dsContent
    Write-Ok "verifier application-datasource.properties(원본)에 공용 DB 접속정보를 반영했습니다."
} else {
    Write-Info "config 설정값 업데이트를 선택하지 않아 application-datasource.properties는 그대로 사용합니다 (DB를 이 값에 맞춰 생성했습니다)."
}

$VfLogRoot = Join-Path (Split-Path -Parent $VerifierRoot) "log\verifier"
New-Item -ItemType Directory -Force -Path $VfLogRoot | Out-Null
Write-Ok "verifier 준비 완료 (실제 기동은 compose가 한 번에 처리합니다)"

# ============================================================================
# 3. oacx config 패치 (sandbox 원본에 직접)
# ============================================================================
Write-Host ""
Write-Host "########## 3단계: oacx config 패치 ##########"

if (-not (Test-Path (Join-Path $OacxRoot "config") -PathType Container)) {
    Write-Err2 "config/ 폴더를 찾을 수 없습니다: $OacxRoot"
    exit 1
}

$OacxConfigDir = Join-Path $OacxRoot "config"
$SpProp = Join-Path $OacxConfigDir "server.properties"
$spContent = Read-Utf8File $SpProp
$spContent = [regex]::Replace($spContent, '(mybatis\.mapper\.path=).*', '${1}/config/mybatis')
$spContent = [regex]::Replace($spContent, '(log\.file=).*', '${1}/config/logback.xml')
$spContent = [regex]::Replace($spContent, '(log\.path=).*', '${1}/logs/app')
$spContent = [regex]::Replace($spContent, '(oper\.mode=).*', ('${1}' + $OperSort))
if ($UpdateDbConfig) {
    $spContent = [regex]::Replace($spContent, '(jdbc\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
    $spContent = [regex]::Replace($spContent, '(jdbc\.user=).*', ('${1}' + $AppUser))
    $spContent = [regex]::Replace($spContent, '(jdbc\.password=).*', ('${1}' + $AppPassword))
    Write-Utf8File $SpProp $spContent
    Write-Ok "oacx server.properties에 공용 DB 접속정보 + oper.mode($OperSort)를 반영했습니다."
} else {
    Write-Utf8File $SpProp $spContent
    Write-Ok "oacx server.properties의 DB 접속정보는 그대로 사용, oper.mode($OperSort)/mybatis·log 경로만 반영했습니다."
}

# ---------- provider.json 6종: base/publicKey/vc.curveType 자동 반영 (partnerCode는 raon 고정) ----------
Write-Info "verifier DID 파일($DidFileName)에서 publicKey/curveType을 추출합니다..."
$DidFile = Join-Path $VerifierRoot "config\sp\$DidFileName"
$DidPublicKey = ""
$DidCurveType = ""
if (Test-Path $DidFile) {
    $didJson = Read-Utf8File $DidFile
    $vmMatch = [regex]::Match($didJson, '"verificationMethod":\[[^\]]*\]')
    if ($vmMatch.Success) {
        $vmBlock = $vmMatch.Value
        $keyMatch = [regex]::Match($vmBlock, '"publicKeyBase58":"([^"]*)"')
        if ($keyMatch.Success) { $DidPublicKey = $keyMatch.Groups[1].Value }
        $typeMatch = [regex]::Match($vmBlock, '"type":"([^"]*)"')
        $didTypeRaw = if ($typeMatch.Success) { $typeMatch.Groups[1].Value } else { "" }
        if ($didTypeRaw -match "Secp256k1") { $DidCurveType = "SECP256_K1" }
        elseif ($didTypeRaw -match "Secp256[rR]1") { $DidCurveType = "SECP256_R1" }
        else { Write-Warn2 "did type '$didTypeRaw'을(를) curveType으로 매핑하지 못했습니다. provider.json의 vc.curveType은 그대로 둡니다." }
    }
    if ($DidPublicKey) {
        $shown = $DidPublicKey.Substring(0, [Math]::Min(12, $DidPublicKey.Length))
        $curveShown = if ($DidCurveType) { $DidCurveType } else { "(미확인)" }
        Write-Ok "publicKey=$shown... curveType=$curveShown ($DidFileName 기준)"
    } else {
        Write-Warn2 "DID 파일에서 publicKeyBase58을 찾지 못했습니다: $DidFile"
    }
} else {
    Write-Warn2 "DID 파일을 찾을 수 없습니다: $DidFile (provider.json의 publicKey는 기존 값을 유지합니다)"
}

$ProviderFiles = @("coidentitydocument-provider.json", "comdc-provider.json", "comdl-provider.json", "comnh-provider.json", "comrc-provider.json", "coresidence-provider.json")
foreach ($pf in $ProviderFiles) {
    $target = Join-Path $OacxConfigDir $pf
    if (-not (Test-Path $target)) { Write-Warn2 "provider.json을 찾을 수 없습니다: $pf (건너뜁니다)"; continue }
    $pc = Read-Utf8File $target
    $pc = [regex]::Replace($pc, '"base": "[^"]*"', ('"base": "http://' + $VfContainer + ':' + $VfPort + '"'))
    $pc = [regex]::Replace($pc, '"partnerCode": "[^"]*"', ('"partnerCode": "' + $PartnerCode + '"'))
    if ($DidPublicKey) { $pc = [regex]::Replace($pc, '"publicKey" ?: ?"[^"]*"', ('"publicKey" : "' + $DidPublicKey + '"')) }
    if ($DidCurveType) { $pc = [regex]::Replace($pc, '"vc\.curveType":\s*"[^"]*"', ('"vc.curveType":"' + $DidCurveType + '"')) }
    $pc = $pc -replace '/api/v2/transaction/web2appsspay', '/api/v2/transaction/web2app'
    Write-Utf8File $target $pc
}
Write-Ok "provider.json 6종에 base/partnerCode/publicKey/vc.curveType을 반영했습니다 (partnerCode=$PartnerCode)."
Write-Warn2 "serviceCode는 인증사업자별 고유값이라 자동화 대상에서 제외했습니다 -- 비어있는 파일은 직접 채워야 합니다."

$ContextXml = Join-Path $ScriptDir ".staging\$OacxContainer\$ContextPath.xml"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ContextXml) | Out-Null
@"
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="/app" path="/$ContextPath" reloadable="false" />
"@ | Set-Content -Path $ContextXml -Encoding utf8

$OxLogRoot = Join-Path (Split-Path -Parent $OacxRoot) "log\oacx"
New-Item -ItemType Directory -Force -Path (Join-Path $OxLogRoot "tomcat") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OxLogRoot "app") | Out-Null

Write-Ok "oacx 준비 완료"

# ============================================================================
# 4. 이미지 pull + compose 기동
# ============================================================================
Write-Host ""
Write-Host "########## 4단계: 이미지 pull + compose 기동 ##########"

foreach ($img in @($DbImage, $VerifierImage, $OacxImage)) {
    Write-Info "레지스트리 이미지를 내려받는 중입니다: $img"
    docker pull $img
    if ($LASTEXITCODE -ne 0) { Write-Err2 "이미지를 가져오지 못했습니다: $img (해당 build-and-push.ps1(.sh) 로 먼저 등록하세요)"; exit 1 }
}

$EnvFile = Join-Path $ScriptDir ".staging\omnionecx.env"
@"
DB_IMAGE=$DbImage
DB_CONTAINER=$DbContainer
DB_NAME=$DbName
DB_PORT=$DbPort
DB_DATA_DIR=$DbDataDir
APP_USER=$AppUser
PARTNER_CODE=$PartnerCode
OPER_SORT=$OperSort
VERIFIER_IMAGE=$VerifierImage
VF_CONTAINER=$VfContainer
VF_PORT=$VfPort
VF_CONFIG_DIR=$VfConfigDir
VERIFIER_CONFIG_ROOT=$VerifierRoot\config
VF_LOG_ROOT=$VfLogRoot
OACX_IMAGE=$OacxImage
OACX_CONTAINER=$OacxContainer
OACX_HOST_PORT=$OacxHostPort
OACX_CONFIG_DIR=$OacxConfigDir
CONTEXT_XML=$ContextXml
CONTEXT_PATH=$ContextPath
OX_LOG_ROOT=$OxLogRoot
NETWORK_NAME=$NetworkName
"@ | Set-Content -Path $EnvFile -Encoding utf8

$env:DB_ROOT_PASSWORD = $DbRootPassword
$env:APP_PASSWORD = $AppPassword
Write-Info "docker compose up -d 를 실행합니다 (db -> verifier -> oacx 순서로 기동, 시간이 걸릴 수 있습니다)..."
docker compose -f (Join-Path $ScriptDir "docker-compose.yml") -p omnionecx --env-file $EnvFile up -d
$ComposeExit = $LASTEXITCODE
Remove-Item Env:\DB_ROOT_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:\APP_PASSWORD -ErrorAction SilentlyContinue
if ($ComposeExit -ne 0) {
    Write-Err2 "docker compose up 실패 (종료 코드 $ComposeExit). 'docker compose -f docker-compose.yml -p omnionecx --env-file $EnvFile logs'로 확인하세요."
    exit 1
}

function Wait-Healthy([string]$Container, [string]$Label, [int]$Timeout) {
    Write-Info "$Label 기동을 기다리는 중입니다..."
    $elapsed = 0; $interval = 5
    while ($true) {
        $status = (docker inspect -f '{{.State.Health.Status}}' $Container 2>$null)
        if ($status -eq "healthy") { Write-Ok "$Label 정상 기동되었습니다."; return }
        $running = docker ps -q -f "name=^$Container`$"
        if (-not $running) {
            Write-Err2 "$Label 컨테이너가 중단되었습니다. 로그:"
            docker logs $Container 2>&1 | Select-Object -Last 60
            exit 1
        }
        if ($elapsed -ge $Timeout) {
            Write-Warn2 "$Label : 제한 시간 내에 healthy 상태가 되지 않았습니다. 'docker logs -f $Container'로 확인하세요."
            return
        }
        Start-Sleep -Seconds $interval; $elapsed += $interval; Write-Host "." -NoNewline
    }
}
Wait-Healthy $DbContainer "DB" 300; Write-Host ""
Wait-Healthy $VfContainer "verifier" 180; Write-Host ""
Wait-Healthy $OacxContainer "oacx" 300; Write-Host ""

function Test-Http([string]$Url) {
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        return $resp.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        Start-Sleep -Seconds 3
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            return $resp.StatusCode
        } catch { return "000" }
    }
}
$VfHttp = Test-Http "http://localhost:$VfPort/"
$OacxHttp = Test-Http "http://localhost:$OacxHostPort/$ContextPath/"

Write-Host ""
Write-Host "======================= 접속 정보 ======================="
Write-Host " 사이트        : $Site (OACX $OacxVersionTag / verifier $VerifierVersionTag)"
Write-Host " 배포 환경     : $DeployEnv (oper.mode/OperSort=$OperSort)"
Write-Host " -------------------------- [DB] --------------------------"
Write-Host " Host          : localhost / Port: $DbPort / DB: $DbName / User: $AppUser"
Write-Host " JDBC URL      : jdbc:mariadb://localhost:$DbPort/$DbName"
Write-Host " 데이터 경로   : $DbDataDir"
Write-Host " (컨테이너 간 통신용 Host: $DbContainer, Network: $NetworkName)"
Write-Host " -------------------------- [verifier] --------------------------"
Write-Host " URL           : http://localhost:$VfPort/  (HTTP $VfHttp)"
Write-Host " -------------------------- [oacx] --------------------------"
Write-Host " URL           : http://localhost:$OacxHostPort/$ContextPath/  (HTTP $OacxHttp)"
if ($GeneratedPw) { Write-Host " root 비밀번호(DB) : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==========================================================="
Write-Info "컨테이너 안으로 들어가려면: .\exec.ps1 <db|verifier|oacx> [명령]"
Write-Warn2 "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
$DbRootPassword = $null
$AppPassword = $null
