<#
.SYNOPSIS
  OmnioneCX 통합 배포 스크립트 (PowerShell) — 우리투자증권(wooriib) 전용, 버전 고정 이미지 트랙

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  전제조건 : oracle/registry/setup-registry.ps1 로 레지스트리가 떠있어야 하고,
             db/verifier/oacx 각각의 build-and-push.sh(.ps1) 로 이 사이트가
             쓰는 이미지가 레지스트리에 이미 등록되어 있어야 함. db/verifier/
             oacx는 사이트별 리포지토리가 아니라 컴포넌트당 하나의 리포지토리로
             통합 관리된다 -- DB는 사이트명 태그(omnionecx-db:wooriib)만 쓰고,
             verifier/oacx는 벤더 표준판이라 순수 버전 태그(omnionecx-verifier:
             1.3.25_fix)를 쓰며 "wooriib"는 그 버전을 가리키는 이동 태그일
             뿐이다. 이 사이트 전용 커스텀/포크 빌드가 생기면 그때는
             "wooriib-버전" 형태로 별도 관리한다.

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
# db/verifier/oacx가 각각 하나의 리포지토리로 통합 관리된다. verifier/oacx는
# 커스텀 포크가 아닌 벤더 표준판이라 태그도 순수 버전 번호(아래 *VersionTag)를
# 그대로 쓰고, SiteTag(사이트명)는 "지금 이 사이트가 쓰는 버전"을 가리키는
# 이동 태그로만 쓴다 -- 나중에 이 사이트 전용으로 커스텀/포크된 빌드가 생기면
# 그때는 "SiteTag-버전" 형태(예: wooriib-1.3.42)로 별도 관리한다.
$SiteTag = "wooriib"
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

# 이 PC가 실제 네트워크에서 쓰는 IP를 최대한 정확히 추정한다(기본
# 게이트웨이가 잡혀있는 인터페이스 기준 -- 루프백/APIPA/가상 어댑터를
# 걸러내는 것보다 훨씬 안정적). 실패하면 빈 문자열을 반환한다.
function Get-LocalIp {
    try {
        $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq "Up" } | Select-Object -First 1
        if ($cfg) { return $cfg.IPv4Address.IPAddress }
    } catch { }
    return ""
}

# 이 호스트 포트를 지금 물고 있는 컨테이너 이름을 반환한다(없으면 빈 문자열).
function Get-PortOwnerContainer([int]$Port) {
    try {
        $lines = docker ps --format '{{.Names}}`t{{.Ports}}' 2>$null
        foreach ($line in $lines) {
            $parts = $line -split "`t", 2
            if ($parts.Count -eq 2 -and $parts[1] -match [regex]::Escape(":$Port->")) { return $parts[0] }
        }
    } catch { }
    return ""
}

# 이 호스트 포트가 실제로 비어있는지 TCP connect로 확인한다(docker가
# 점유했든 다른 프로세스가 점유했든 다 잡아낸다).
function Test-PortInUse([int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(300)
        $inUse = $ok -and $client.Connected
        $client.Close()
        return $inUse
    } catch { return $false }
}

# preferred 포트가 비어있으면 그대로 반환. 이미 쓰이고 있어도, 그 포트를
# 물고 있는 게 Exclude(이번에 내릴 내 컨테이너)라면 재사용 가능하다고
# 본다. 그 외의 경우(다른 사이트/무관한 프로세스)면 1씩 올려가며 빈 포트를
# 찾는다(최대 20회 시도).
function Find-AvailablePort([int]$Port, [string]$Exclude = "") {
    $tries = 0
    while ($true) {
        $owner = Get-PortOwnerContainer $Port
        if ([string]::IsNullOrEmpty($owner)) {
            if (-not (Test-PortInUse $Port)) { return $Port }
        } elseif ($Exclude -and $owner -eq $Exclude) {
            return $Port
        }
        $Port++
        $tries++
        if ($tries -ge 20) { return $Port }
    }
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
Write-Info "docker compose 프로젝트 이름은 위 네트워크 이름과 별개입니다 -- 같은 PC에서 이 사이트를 여러 벌(예: 병렬 테스트) 띄우려면 서로 다르게 지정하세요."
$ComposeProject = Ask "docker compose 프로젝트 이름" "omnionecx-wooriib"

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
$DbImage = "$LocalRegistry/$Namespace/omnionecx-db:$SiteTag"

$DsSrc = Join-Path $VerifierRoot "config\config\application-datasource.properties"
$NeedDbPrompt = $false
if ($UpdateDbConfig) {
    $NeedDbPrompt = $true
} else {
    $DbContainer = ""; $DbName = ""; $AppUser = ""; $AppPassword = ""
    if (-not (Test-Path $DsSrc)) {
        Write-Warn2 "DB 접속정보를 config에서 읽어와야 하는데 파일을 찾을 수 없습니다: $DsSrc"
        Write-Warn2 "직접 입력받는 방식으로 대신 진행합니다."
        $NeedDbPrompt = $true
    } else {
        $dsSrcContent = Read-Utf8File $DsSrc
        $urlMatch = [regex]::Match($dsSrcContent, 'spring\.datasource\.url=jdbc:mariadb://([^:/\s]+)[^/\s]*/([^/?\s]+)')
        $userMatch = [regex]::Match($dsSrcContent, 'spring\.datasource\.hikari\.username=(\S+)')
        $passMatch = [regex]::Match($dsSrcContent, 'spring\.datasource\.hikari\.password=(\S+)')
        if (-not $urlMatch.Success -or -not $userMatch.Success) {
            Write-Warn2 "config에서 DB 접속정보를 추출하지 못했습니다 ($DsSrc 확인 필요) -- 직접 입력받는 방식으로 대신 진행합니다."
            $NeedDbPrompt = $true
        } else {
            $DbContainer = $urlMatch.Groups[1].Value
            $DbName = $urlMatch.Groups[2].Value
            $AppUser = $userMatch.Groups[1].Value
            $AppPassword = if ($passMatch.Success) { $passMatch.Groups[1].Value } else { "" }
            Write-Ok "config에서 DB 접속정보를 그대로 가져왔습니다: host(컨테이너명)=$DbContainer, db=$DbName, user=$AppUser"
        }
    }
}
if ($NeedDbPrompt) {
    $dbContainerDefault = if ($DbContainer) { $DbContainer } else { "mariadb-1.0.0.9" }
    $DbContainer = Ask "DB 컨테이너 이름" $dbContainerDefault
    $dbNameDefault = if ($DbName) { $DbName } else { "VC_VERIFIER" }
    $DbName = Ask "DB(스키마) 이름 (verifier/oacx가 하나의 DB를 공유 -- 실제 운영값과 동일하게 기본 VC_VERIFIER)" $dbNameDefault
    $appUserDefault = if ($AppUser) { $AppUser } else { "omnione" }
    $AppUser = Ask "공용 앱 계정 이름" $appUserDefault
    $appPasswordDefault = if ($AppPassword) { $AppPassword } else { "0mN1DB" }
    $AppPassword = Ask-Secret "공용 앱 계정 비밀번호" $appPasswordDefault
    # 직접 입력받은 이상, 값이 실제 파일에도 반영되어야 하니 이후 패치
    # 단계에서 이 값들을 강제로 적용하도록 표시한다.
    $UpdateDbConfig = $true
}
$defaultDbPort = Find-AvailablePort 3306 $DbContainer
if ($defaultDbPort -ne 3306) { Write-Warn2 "3306 포트가 이미 사용 중이라, 대신 $defaultDbPort 을(를) 기본값으로 제안합니다." }
$DbPort = Ask "DB 포트 (호스트에 노출할 포트, DBeaver 등 외부 툴 접속용)" "$defaultDbPort"

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
$VfContainer = Ask "verifier 컨테이너 이름" "verifier-1.3.25-fix"
$defaultVfPort = Find-AvailablePort 48085 $VfContainer
if ($defaultVfPort -ne 48085) { Write-Warn2 "48085 포트가 이미 사용 중이라, 대신 $defaultVfPort 을(를) 기본값으로 제안합니다." }
$VfPort = Ask "verifier 포트" "$defaultVfPort"
$VerifierImage = "$LocalRegistry/$Namespace/omnionecx-verifier:$SiteTag"

$DetectedIp = Get-LocalIp
if ($DetectedIp) {
    Write-Ok "이 PC의 IP를 감지했습니다: $DetectedIp"
} else {
    Write-Warn2 "이 PC의 IP를 자동으로 감지하지 못했습니다. 직접 입력해주세요."
    $DetectedIp = "localhost"
}
$VfPublicDomain = Ask "verifier의 외부 콜백 주소(mdl.sp.api-server-domain, 앱이 Profile 요청/VP 제출 시 직접 접근하는 주소)" "http://${DetectedIp}:$VfPort"

Write-Host ""
Write-Host "-------- oacx --------"
$defaultOacxRoot = Join-Path $ScriptDir "oacx"
if (Test-Path $defaultOacxRoot -PathType Container) {
    $OacxRoot = $defaultOacxRoot
    Write-Ok "oacx 폴더를 찾았습니다: $OacxRoot (경로 입력 생략)"
} else {
    $OacxRoot = Ask "OACX 설정 루트 경로 (config/ 가 있는 위치)" "D:\03. Docker\sandbox\oacx"
}
$OacxContainer = Ask "OACX 컨테이너 이름" "oacx-1.0.0.9"
$ContextPath = Ask "OACX Context path (URL: http://localhost:<포트>/<이 값>/)" "oacx"
$defaultOacxPort = Find-AvailablePort 8080 $OacxContainer
if ($defaultOacxPort -ne 8080) { Write-Warn2 "8080 포트가 이미 사용 중이라, 대신 $defaultOacxPort 을(를) 기본값으로 제안합니다." }
$OacxHostPort = Ask "OACX 포트" "$defaultOacxPort"
$OacxImage = "$LocalRegistry/$Namespace/omnionecx-oacx:$SiteTag"

$OacxPublicUrl = Ask "oacx '앱 호출 테스트' 페이지에 표시할 OACX 서버 주소 (이 PC에서 접근 가능한 IP)" "http://${DetectedIp}:$OacxHostPort"

Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 사이트        : $Site (OACX $OacxVersionTag / verifier $VerifierVersionTag)"
Write-Host " 배포 환경     : $DeployEnv (oper.mode/OperSort=$OperSort)"
$updateLabel = if ($UpdateDbConfig) { "예 (DB 접속정보를 아래 값으로 덮어씀)" } else { "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)" }
Write-Host " config 업데이트 : $updateLabel"
Write-Host " 네트워크      : $NetworkName"
Write-Host " compose 프로젝트 : $ComposeProject"
Write-Host " DB            : $DbImage / $DbContainer / db=$DbName / port=$DbPort"
Write-Host " DB 데이터 경로 : $DbDataDir"
Write-Host " 공용 앱 계정  : $AppUser"
Write-Host " PARTNER_CODE  : $PartnerCode"
Write-Host " verifier      : $VerifierImage / $VfContainer (포트 $VfPort), root=$VerifierRoot"
Write-Host " VF_PUBLIC_DOMAIN : $VfPublicDomain"
Write-Host " oacx          : $OacxImage / $OacxContainer (포트 $OacxHostPort, /$ContextPath), root=$OacxRoot"
Write-Host " OACX_PUBLIC_URL : $OacxPublicUrl"
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
# 호스트/포트/DB명(컨테이너 내부 네트워킹 배선)은 배포 때마다 항상 현재
# DbContainer/DbName 값으로 다시 맞춘다 -- config에 이미 들어있던 값이
# 예전 배포(다른 컨테이너명/사이트) 것일 수 있어 매번 확실히 고쳐쓴다.
# 계정(username/password)은 "DB 접속정보 업데이트" 선택 시에만 덮어쓴다.
if (Test-Path $DsProp) {
    $dsContent = Read-Utf8File $DsProp
    $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
    if ($UpdateDbConfig) {
        $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.hikari\.username=).*', ('${1}' + $AppUser))
        $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.hikari\.password=).*', ('${1}' + $AppPassword))
        Write-Utf8File $DsProp $dsContent
        Write-Ok "verifier application-datasource.properties(원본)에 공용 DB 접속정보(호스트+계정)를 반영했습니다."
    } else {
        Write-Utf8File $DsProp $dsContent
        Write-Ok "verifier application-datasource.properties의 DB 호스트/포트는 현재 배포값($DbContainer)으로 맞췄고, 계정 정보는 기존 값을 유지합니다."
    }
} else {
    Write-Warn2 "application-datasource.properties를 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $DsProp"
}

# verifier 자신의 외부 콜백 주소(mdl.sp.api-server-domain) -- Profile 요청/VP
# 제출 등 앱이 직접 접근하는 주소라 배포 PC/포트가 바뀔 때마다 갱신 필요.
# application-sp.properties(1.3.x 공통) / application-mdl-sp.properties(일부
# 최신 버전) 둘 다 있으면 둘 다 반영한다.
foreach ($spf in @((Join-Path $VfConfigDir "application-sp.properties"), (Join-Path $VfConfigDir "application-mdl-sp.properties"))) {
    if (-not (Test-Path $spf)) { continue }
    $spfContent = Read-Utf8File $spf
    $spfContent = [regex]::Replace($spfContent, '(mdl\.sp\.api-server-domain=)https?://\S*', ('${1}' + $VfPublicDomain))
    Write-Utf8File $spf $spfContent
}
Write-Ok "verifier mdl.sp.api-server-domain을 $VfPublicDomain(으)로 반영했습니다."

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
# 호스트/포트/DB명은 배포 때마다 항상 현재 DbContainer/DbName으로 다시
# 맞춘다(예전 배포의 컨테이너명이 남아있는 문제 방지).
if ($spContent -match '(?m)^jdbc\.type=jndi') {
    Write-Warn2 "oacx server.properties가 아직 jdbc.type=jndi 상태입니다 -- jdbc 직결 방식으로 먼저 바꿔야 DB 접속정보 자동 반영이 적용됩니다."
}
$spContent = [regex]::Replace($spContent, '(jdbc\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
if ($UpdateDbConfig) {
    $spContent = [regex]::Replace($spContent, '(jdbc\.user=).*', ('${1}' + $AppUser))
    $spContent = [regex]::Replace($spContent, '(jdbc\.password=).*', ('${1}' + $AppPassword))
    Write-Utf8File $SpProp $spContent
    Write-Ok "oacx server.properties에 공용 DB 접속정보(호스트+계정) + oper.mode($OperSort)를 반영했습니다."
} else {
    Write-Utf8File $SpProp $spContent
    Write-Ok "oacx server.properties의 DB 호스트/포트는 현재 배포값($DbContainer)으로 맞췄고, 계정 정보는 기존 값을 유지합니다. oper.mode($OperSort)/mybatis·log 경로도 반영."
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

# co*-provider.json 전부를 대상으로 하되, "base"는 현재 우리 verifier를
# 가리키고 있던 값일 때만 갱신한다(호스트명이 "verifier"로 시작하는 경우) --
# naver/kakao/정부망 등 외부 인증사업자의 진짜 API 주소는 절대 건드리지
# 않기 위한 안전장치. partnerCode/publicKey/vc.curveType은 우리 쪽 신원
# (DID)이라 어떤 인증사업자를 부르든 공통으로 반영한다.
$providerCount = 0
Get-ChildItem -Path $OacxConfigDir -Filter "co*-provider.json" -File | ForEach-Object {
    $target = $_.FullName
    $providerCount++
    $pc = Read-Utf8File $target
    $pc = [regex]::Replace($pc, '"base": "https?://verifier[^"]*"', ('"base": "http://' + $VfContainer + ':' + $VfPort + '"'))
    $pc = [regex]::Replace($pc, '"partnerCode": "[^"]*"', ('"partnerCode": "' + $PartnerCode + '"'))
    if ($DidPublicKey) { $pc = [regex]::Replace($pc, '"publicKey" ?: ?"[^"]*"', ('"publicKey" : "' + $DidPublicKey + '"')) }
    if ($DidCurveType) { $pc = [regex]::Replace($pc, '"vc\.curveType":\s*"[^"]*"', ('"vc.curveType":"' + $DidCurveType + '"')) }
    $pc = $pc -replace '/api/v2/transaction/web2appsspay', '/api/v2/transaction/web2app'
    Write-Utf8File $target $pc
}
Write-Ok "provider.json $providerCount 개에 partnerCode/publicKey/vc.curveType을 반영했고, 그 중 우리 verifier를 가리키던 base 주소는 http://${VfContainer}:${VfPort}(으)로 갱신했습니다 (외부 인증사업자 주소는 그대로 둠)."
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
OACX_PUBLIC_URL=$OacxPublicUrl
OACX_CONFIG_DIR=$OacxConfigDir
CONTEXT_XML=$ContextXml
CONTEXT_PATH=$ContextPath
OX_LOG_ROOT=$OxLogRoot
NETWORK_NAME=$NetworkName
COMPOSE_PROJECT=$ComposeProject
"@ | Set-Content -Path $EnvFile -Encoding utf8

# docker-compose.yml에서 이 네트워크를 external로 선언해뒀으므로(여러
# 사이트가 공유), compose가 대신 만들어주지 않는다 -- 없으면 여기서 미리
# 만들어둔다(이미 있으면 조용히 통과).
docker network inspect $NetworkName *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Info "네트워크($NetworkName)가 없어 새로 만듭니다."
    docker network create $NetworkName | Out-Null
}

$env:DB_ROOT_PASSWORD = $DbRootPassword
$env:APP_PASSWORD = $AppPassword
Write-Info "docker compose up -d 를 실행합니다 (db -> verifier -> oacx 순서로 기동, 시간이 걸릴 수 있습니다)..."
docker compose -f (Join-Path $ScriptDir "docker-compose.yml") -p $ComposeProject --env-file $EnvFile up -d
$ComposeExit = $LASTEXITCODE
Remove-Item Env:\DB_ROOT_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:\APP_PASSWORD -ErrorAction SilentlyContinue
if ($ComposeExit -ne 0) {
    Write-Err2 "docker compose up 실패 (종료 코드 $ComposeExit). 'docker compose -f docker-compose.yml -p $ComposeProject --env-file $EnvFile logs'로 확인하세요."
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
