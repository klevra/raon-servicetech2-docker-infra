<#
.SYNOPSIS
  OmnioneCX 통합 배포 스크립트 (PowerShell) — 버전 고정 이미지 트랙 (2.0.0.3)

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  전제조건 : oracle/registry/setup-registry.ps1 로 레지스트리가 떠있어야 하고,
             db/verifier/oacx/admin/sample 각각의 build-and-push.sh(.ps1) 로
             omnionecx-{db,verifier,oacx,admin,sample}:2.0.0.3 이미지가
             레지스트리에 이미 등록되어 있어야 함.

  1.0.0.12 트랙과의 핵심 차이:
    - verifier/oacx/admin/sample 모두 내장 Tomcat 포함 실행형 fat jar
      (Spring Boot). oacx는 context-path(/oacx/api)/port(8080, 배포 시
      조정 가능)가 이미지 안 application.yml에 고정되어 있어 Context XML
      생성이 필요 없다.
    - verifier 설정은 application-*.properties 여러 개가 아니라
      application.yml 하나에 인라인으로 들어있다 -- 이 스크립트의 config
      패치는 properties(key=value)가 아니라 YAML(key: value) 문법을
      정규식으로 직접 건드린다.
    - admin(신규): oacx/verifier와 같은 DB를 쓰는 관리자 콘솔. sample(신규):
      oacx REST API를 호출하는 테스트 페이지. oacx가 healthy해진 뒤에 뜬다.
    - oacx에 co*-provider.json 같은 인증사업자별 설정 파일이 없다 -- DID
      publicKey/curveType 추출·반영 로직은 이 트랙에는 해당 사항이 없어
      제외했다.

  비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Namespace = "servicetech2"
$Site = "OmnioneCX 2.0.0.3 트랙"
$VerifierAppVersion = "1.3.42-springboot-3"
$OacxAppVersion = "2.0.3"
$AdminAppVersion = "2.0.3"
$SampleAppVersion = "1.0-SNAPSHOT"
$MovingTag = "2.0.0.3"

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
# 게이트웨이가 잡혀있는 인터페이스 기준). 실패하면 빈 문자열을 반환한다.
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

# 이 호스트 포트가 실제로 비어있는지 TCP connect로 확인한다.
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
# 본다. 그 외의 경우면 1씩 올려가며 빈 포트를 찾는다(최대 20회 시도).
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
Write-Host " OmnioneCX $Site 통합 배포 (버전 고정 이미지 트랙, 태그=$MovingTag)"
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
    "1" {
        $DeployEnv = "개발"; $OperSort = "dev"; $DidFileName = "raondev2.sp.did"
        $SpEnvSubdir = "dev"
        $SpServerKeyManagerPath = "/config/sp/dev"
        $SpRcpHost = "https://bcdev.mobileid.go.kr:18888"
        $SpKeyManagerPath = "raondev2.sp.wallet"
        $SpKeyManagerPassword = "raon12345!"
        $SpKeyId = "dev2.sp"
        $SpRsaKeyId = "dev2.sp.rsa"
        $SpServiceCode = "raonsecure.1"
        $SpCaListDomain = "https://mipdev.mobileid.go.kr:23443/v1/capush/list"
    }
    "2" {
        $DeployEnv = "운영"; $OperSort = "prod"; $DidFileName = "raonEnt.did"
        $SpEnvSubdir = "prod"
        $SpServerKeyManagerPath = "/config/sp/prod"
        $SpRcpHost = "https://bcc.mobileid.go.kr:18888"
        $SpKeyManagerPath = "raonEnt.wallet"
        $SpKeyManagerPassword = "1q2w3e4r!@"
        $SpKeyId = "raonEnt.sp"
        $SpRsaKeyId = "raonEnt.sp.rsa"
        $SpServiceCode = "raonsnc.1"
        $SpCaListDomain = "https://pub.mobileid.go.kr:10443/v1/capush/list"
    }
    default { Write-Err2 "잘못된 선택입니다."; exit 1 }
}

Write-Info "CA 앱 목록 서버($SpCaListDomain) 응답 여부를 확인합니다 (1초 대기)..."
try {
    Invoke-WebRequest -Uri $SpCaListDomain -Method Post -Headers @{ "Content-Type" = "application/json" } -Body '{"apiType" : "mip"}' -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop | Out-Null
    $SpCaListCronEnabled = "true"
    Write-Ok "CA 앱 목록 서버 응답 확인 -- mdl.sp.ca-list-data-cron-enabled=true로 설정합니다."
} catch {
    $SpCaListCronEnabled = "false"
    Write-Warn2 "CA 앱 목록 서버($SpCaListDomain)가 1초 내에 응답하지 않습니다 -- mdl.sp.ca-list-data-cron-enabled=false로 설정합니다."
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
Write-Info "docker compose 프로젝트 이름은 위 네트워크 이름과 별개입니다 -- 같은 PC에서 이 트랙을 여러 벌(예: 병렬 테스트) 띄우려면 서로 다르게 지정하세요."
$ComposeProject = Ask "docker compose 프로젝트 이름" "omnionecx-2003"

Write-Host ""
$PartnerCode = Ask "VF_ORGANIZATION.PARTNER_CODE / OACX_PROVIDER.OPER_SORT 공통값" "raon"

Write-Host ""
Write-Host "-------- 헬스체크 사용 여부 --------"
Write-Info "끄면 각 서비스의 헬스체크가 항상 즉시 통과(exit 0)로 바뀝니다 -- depends_on 순서 기동 자체는 그대로 유지되고, 컨테이너 상태 점검만 생략됩니다."
$HealthcheckEnabled = Confirm "헬스체크를 사용할까요?"
if (-not $HealthcheckEnabled) {
    Write-Warn2 "헬스체크를 비활성화합니다 -- 컨테이너가 실제로 정상 응답하는지는 별도로 직접 확인하세요."
}
# 실제 CMD 문자열은 각 서비스 포트가 전부 정해진 뒤(6단계 직전)에 구성한다.

Write-Host ""
Write-Host "-------- config 설정값 업데이트 여부 --------"
Write-Info "verifier/oacx/admin이 마운트할 config 안의 DB 접속정보(datasource)를 이번 배포값으로 덮어쓸지 선택하세요."
Write-Info "('아니오'를 선택하면 config에 이미 들어있는 값을 그대로 사용하고, DB도 그 값에 맞춰 자동으로 생성합니다.)"
$UpdateDbConfig = Confirm-No "DB 접속정보를 이번 배포값으로 업데이트할까요? (기본값 N = config의 값을 그대로 사용)"

Write-Host ""
$defaultVerifierRoot = Join-Path $ScriptDir "verifier"
if (Test-Path $defaultVerifierRoot -PathType Container) {
    $VerifierRoot = $defaultVerifierRoot
    Write-Ok "verifier 폴더를 찾았습니다: $VerifierRoot (경로 입력 생략)"
} else {
    $VerifierRoot = Ask "verifier 설정 루트 경로 (config/ 가 있는 위치)" (Join-Path $ScriptDir "verifier")
}
$VfYml = Join-Path $VerifierRoot "config\application.yml"

Write-Host ""
Write-Host "-------- DB --------"
$DbImage = "$LocalRegistry/$Namespace/omnionecx2-db:$MovingTag"

$NeedDbPrompt = $false
if ($UpdateDbConfig) {
    $NeedDbPrompt = $true
} else {
    $DbContainer = ""; $DbName = ""; $AppUser = ""; $AppPassword = ""
    if (-not (Test-Path $VfYml)) {
        Write-Warn2 "DB 접속정보를 config에서 읽어와야 하는데 파일을 찾을 수 없습니다: $VfYml"
        Write-Warn2 "직접 입력받는 방식으로 대신 진행합니다."
        $NeedDbPrompt = $true
    } else {
        $vfYmlContent = Read-Utf8File $VfYml
        $urlMatch = [regex]::Match($vfYmlContent, '(?m)^[ \t]+url: jdbc:mariadb://([^:/\s]+)[^/\s]*/([^/?\s]+)')
        $userMatch = [regex]::Match($vfYmlContent, '(?m)^[ \t]+username: (\S+)')
        $passMatch = [regex]::Match($vfYmlContent, '(?m)^[ \t]+password: (\S+)')
        if (-not $urlMatch.Success -or -not $userMatch.Success) {
            Write-Warn2 "config에서 DB 접속정보를 추출하지 못했습니다 ($VfYml 확인 필요) -- 직접 입력받는 방식으로 대신 진행합니다."
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
    $dbContainerDefault = if ($DbContainer) { $DbContainer } else { "db" }
    $DbContainer = Ask "DB 컨테이너 이름" $dbContainerDefault
    $dbNameDefault = if ($DbName) { $DbName } else { "VC_VERIFIER" }
    $DbName = Ask "DB(스키마) 이름 (verifier/oacx/admin이 하나의 DB를 공유 -- 실제 운영값과 동일하게 기본 VC_VERIFIER)" $dbNameDefault
    $appUserDefault = if ($AppUser) { $AppUser } else { "omnione" }
    $AppUser = Ask "공용 앱 계정 이름" $appUserDefault
    $appPasswordDefault = if ($AppPassword) { $AppPassword } else { "0mN1DB" }
    $AppPassword = Ask-Secret "공용 앱 계정 비밀번호" $appPasswordDefault
    $UpdateDbConfig = $true
}
$defaultDbPort = Find-AvailablePort 3306 $DbContainer
if ($defaultDbPort -ne 3306) { Write-Warn2 "3306 포트가 이미 사용 중이라, 대신 $defaultDbPort 을(를) 기본값으로 제안합니다." }
$DbPort = Ask "DB 포트 (호스트에 노출할 포트, DBeaver 등 외부 툴 접속용)" "$defaultDbPort"

Write-Host ""
$defaultDbDataDir = Join-Path $ScriptDir "data\db"
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
$defaultVfPort = Find-AvailablePort 48085 $VfContainer
if ($defaultVfPort -ne 48085) { Write-Warn2 "48085 포트가 이미 사용 중이라, 대신 $defaultVfPort 을(를) 기본값으로 제안합니다." }
$VfPort = Ask "verifier 포트" "$defaultVfPort"
$VerifierImage = "$LocalRegistry/$Namespace/omnionecx2-verifier:$MovingTag"

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
    $OacxRoot = Ask "OACX 설정 루트 경로 (config/ 가 있는 위치)" (Join-Path $ScriptDir "oacx")
}
$OacxContainer = Ask "OACX 컨테이너 이름" "oacx"
# context-path(/oacx/api)/포트는 이미지 안 application.yml에 고정되어 있어
# 1.0.0.12처럼 Context XML을 새로 만들 필요가 없다.
$defaultOacxPort = Find-AvailablePort 8080 $OacxContainer
if ($defaultOacxPort -ne 8080) { Write-Warn2 "8080 포트가 이미 사용 중이라, 대신 $defaultOacxPort 을(를) 기본값으로 제안합니다." }
$OacxHostPort = Ask "OACX 포트" "$defaultOacxPort"
$OacxImage = "$LocalRegistry/$Namespace/omnionecx2-oacx:$MovingTag"

# sample(테스트 페이지)이 브라우저에서 직접 호출하는 주소 -- 컨테이너 내부
# 전용 이름(oacx)이 아니라 이 PC/브라우저에서 실제로 접근 가능한 주소여야
# 한다 (verifier의 VfPublicDomain과 동일한 이유).
$OacxPublicUrl = Ask "oacx의 외부(브라우저) 접근 주소 -- sample 테스트 페이지가 여기로 API를 호출함" "http://${DetectedIp}:$OacxHostPort/oacx/api"

Write-Host ""
Write-Host "-------- admin --------"
$defaultAdminRoot = Join-Path $ScriptDir "admin"
if (Test-Path $defaultAdminRoot -PathType Container) {
    $AdminRoot = $defaultAdminRoot
    Write-Ok "admin 폴더를 찾았습니다: $AdminRoot (경로 입력 생략)"
} else {
    $AdminRoot = Ask "admin 설정 루트 경로 (config/ 가 있는 위치)" (Join-Path $ScriptDir "admin")
}
$AdminContainer = Ask "admin 컨테이너 이름" "admin"
$defaultAdminPort = Find-AvailablePort 6443 $AdminContainer
if ($defaultAdminPort -ne 6443) { Write-Warn2 "6443 포트가 이미 사용 중이라, 대신 $defaultAdminPort 을(를) 기본값으로 제안합니다." }
$AdminHostPort = Ask "admin 포트" "$defaultAdminPort"
$AdminImage = "$LocalRegistry/$Namespace/omnionecx2-admin:$MovingTag"

Write-Host ""
Write-Host "-------- sample(테스트 페이지) --------"
$defaultSampleRoot = Join-Path $ScriptDir "sample"
if (Test-Path $defaultSampleRoot -PathType Container) {
    $SampleRoot = $defaultSampleRoot
    Write-Ok "sample 폴더를 찾았습니다: $SampleRoot (경로 입력 생략)"
} else {
    $SampleRoot = Ask "sample 설정 루트 경로 (config/ 가 있는 위치)" (Join-Path $ScriptDir "sample")
}
$SampleContainer = Ask "sample 컨테이너 이름" "sample"
$defaultSamplePort = Find-AvailablePort 9025 $SampleContainer
if ($defaultSamplePort -ne 9025) { Write-Warn2 "9025 포트가 이미 사용 중이라, 대신 $defaultSamplePort 을(를) 기본값으로 제안합니다." }
$SampleHostPort = Ask "sample 포트" "$defaultSamplePort"
$SampleImage = "$LocalRegistry/$Namespace/omnionecx2-sample:$MovingTag"

Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 사이트        : $Site (verifier $VerifierAppVersion / OACX $OacxAppVersion / admin $AdminAppVersion / sample $SampleAppVersion, 태그=$MovingTag)"
Write-Host " 배포 환경     : $DeployEnv (oper.mode/OperSort=$OperSort)"
$updateLabel = if ($UpdateDbConfig) { "예 (DB 접속정보를 아래 값으로 덮어씀)" } else { "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)" }
Write-Host " config 업데이트 : $updateLabel"
$hcLabel = if ($HealthcheckEnabled) { "사용" } else { "미사용 (항상 즉시 통과)" }
Write-Host " 헬스체크      : $hcLabel"
Write-Host " 네트워크      : $NetworkName"
Write-Host " compose 프로젝트 : $ComposeProject"
Write-Host " DB            : $DbImage / $DbContainer / db=$DbName / port=$DbPort"
Write-Host " DB 데이터 경로 : $DbDataDir"
Write-Host " 공용 앱 계정  : $AppUser"
Write-Host " PARTNER_CODE  : $PartnerCode"
Write-Host " verifier      : $VerifierImage / $VfContainer (포트 $VfPort), root=$VerifierRoot"
Write-Host " VF_PUBLIC_DOMAIN : $VfPublicDomain"
Write-Host " oacx          : $OacxImage / $OacxContainer (포트 $OacxHostPort, /oacx/api), root=$OacxRoot"
Write-Host " OACX_PUBLIC_URL : $OacxPublicUrl (sample이 브라우저에서 호출하는 주소)"
Write-Host " admin         : $AdminImage / $AdminContainer (포트 $AdminHostPort), root=$AdminRoot"
Write-Host " sample        : $SampleImage / $SampleContainer (포트 $SampleHostPort), root=$SampleRoot"
if ($GeneratedPw) { Write-Host " 생성된 root 비밀번호 : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==========================================================="
if (-not (Confirm "위 설정으로 전체 스택을 배포할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

foreach ($c in @($DbContainer, $VfContainer, $OacxContainer, $AdminContainer, $SampleContainer)) {
    $existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $c }
    if ($existing) {
        Write-Warn2 "이미 '$c' 컨테이너가 존재합니다. 삭제하고 새로 만듭니다."
        docker rm -f $c | Out-Null
    }
}

# ============================================================================
# 2. verifier config 패치 (application.yml, YAML 문법)
# ============================================================================
Write-Host ""
Write-Host "########## 2단계: verifier config 패치 ##########"

$VfConfigDir = Join-Path $VerifierRoot "config"
if (Test-Path $VfYml) {
    $vfContent = Read-Utf8File $VfYml
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+url: jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
    if ($UpdateDbConfig) {
        $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+username: ).*', ('${1}' + $AppUser))
        $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+password: ).*', ('${1}' + $AppPassword))
        Write-Ok "verifier application.yml(원본)에 공용 DB 접속정보(호스트+계정)를 반영했습니다."
    } else {
        Write-Ok "verifier application.yml의 DB 호스트/포트는 현재 배포값($DbContainer)으로 맞췄고, 계정 정보는 기존 값을 유지합니다."
    }

    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+api-server-domain: )https?://\S*', ('${1}' + $VfPublicDomain))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+server-key-manager-path: ).*', ('${1}' + $SpServerKeyManagerPath))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+rcp-host: ).*', ('${1}' + $SpRcpHost))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+key-manager-path: ).*', ('${1}' + $SpKeyManagerPath))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+key-manager-password: ).*', ('${1}' + $SpKeyManagerPassword))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+did-file-path: ).*', ('${1}' + $DidFileName))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+key-id: ).*', ('${1}' + $SpKeyId))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+rsa-key-id: ).*', ('${1}' + $SpRsaKeyId))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+service-code: ).*', ('${1}' + $SpServiceCode))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+ca-list-domain: ).*', ('${1}' + $SpCaListDomain))
    $vfContent = [regex]::Replace($vfContent, '(?m)^([ \t]+ca-list-data-cron-enabled: ).*', ('${1}' + $SpCaListCronEnabled))
    Write-Utf8File $VfYml $vfContent
    Write-Ok "verifier mdl.sp.api-server-domain을 $VfPublicDomain(으)로 반영했습니다."
    Write-Ok "verifier 지갑/DID/블록체인 접속정보(server-key-manager-path, rcp-host, key-manager-*, did-file-path, key-id, rsa-key-id, service-code, ca-list-*)를 $DeployEnv 환경 값으로 반영했습니다."
} else {
    Write-Warn2 "application.yml을 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $VfYml"
}

$VfLogRoot = Join-Path $ScriptDir "log\verifier"
New-Item -ItemType Directory -Force -Path $VfLogRoot | Out-Null
Write-Ok "verifier 준비 완료 (실제 기동은 compose가 한 번에 처리합니다)"

# ============================================================================
# 3. oacx config 패치 (application.yml, YAML 문법)
# ============================================================================
Write-Host ""
Write-Host "########## 3단계: oacx config 패치 ##########"

if (-not (Test-Path (Join-Path $OacxRoot "config") -PathType Container)) {
    Write-Err2 "config/ 폴더를 찾을 수 없습니다: $OacxRoot"
    exit 1
}
$OacxConfigDir = Join-Path $OacxRoot "config"
$OacxYml = Join-Path $OacxConfigDir "application.yml"
if (Test-Path $OacxYml) {
    $oacxContent = Read-Utf8File $OacxYml
    $oacxContent = [regex]::Replace($oacxContent, '(?m)^([ \t]+url: jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
    $oacxContent = [regex]::Replace($oacxContent, '(?m)^([ \t]+mode: )(dev|stage|prod)(.*)', ('${1}' + $OperSort + '${3}'))
    if ($UpdateDbConfig) {
        $oacxContent = [regex]::Replace($oacxContent, '(?m)^([ \t]+username: ).*', ('${1}' + $AppUser))
        $oacxContent = [regex]::Replace($oacxContent, '(?m)^([ \t]+password: ).*', ('${1}' + $AppPassword))
        Write-Utf8File $OacxYml $oacxContent
        Write-Ok "oacx application.yml에 공용 DB 접속정보(호스트+계정) + application.oper.mode($OperSort)를 반영했습니다."
    } else {
        Write-Utf8File $OacxYml $oacxContent
        Write-Ok "oacx application.yml의 DB 호스트/포트는 현재 배포값($DbContainer)으로 맞췄고, 계정 정보는 기존 값을 유지합니다. application.oper.mode($OperSort)도 반영."
    }
} else {
    Write-Warn2 "application.yml을 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $OacxYml"
}
Write-Info "2.0.0.3 oacx는 co*-provider.json 같은 인증사업자별 설정 파일이 없어(내장 mid.providers 고정 목록 사용), 1.0.0.12의 provider.json/DID publicKey 반영 단계는 이 트랙에 해당 사항이 없습니다."

$OxLogRoot = Join-Path $ScriptDir "log\oacx"
New-Item -ItemType Directory -Force -Path $OxLogRoot | Out-Null
Write-Ok "oacx 준비 완료"

# ============================================================================
# 4. admin config 패치 (application.yml, YAML 문법)
# ============================================================================
Write-Host ""
Write-Host "########## 4단계: admin config 패치 ##########"

if (-not (Test-Path (Join-Path $AdminRoot "config") -PathType Container)) {
    Write-Err2 "config/ 폴더를 찾을 수 없습니다: $AdminRoot"
    exit 1
}
$AdminConfigDir = Join-Path $AdminRoot "config"
$AdminYml = Join-Path $AdminConfigDir "application.yml"
if (Test-Path $AdminYml) {
    $adminContent = Read-Utf8File $AdminYml
    $adminContent = [regex]::Replace($adminContent, '(?m)^([ \t]+url: jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
    if ($UpdateDbConfig) {
        $adminContent = [regex]::Replace($adminContent, '(?m)^([ \t]+username: ).*', ('${1}' + $AppUser))
        $adminContent = [regex]::Replace($adminContent, '(?m)^([ \t]+password: ).*', ('${1}' + $AppPassword))
        Write-Utf8File $AdminYml $adminContent
        Write-Ok "admin application.yml에 공용 DB 접속정보(호스트+계정)를 반영했습니다."
    } else {
        Write-Utf8File $AdminYml $adminContent
        Write-Ok "admin application.yml의 DB 호스트/포트는 현재 배포값($DbContainer)으로 맞췄고, 계정 정보는 기존 값을 유지합니다."
    }
} else {
    Write-Warn2 "application.yml을 찾을 수 없어 DB 접속정보 패치를 건너뜁니다: $AdminYml"
}

$AdminLogRoot = Join-Path $ScriptDir "log\admin"
New-Item -ItemType Directory -Force -Path $AdminLogRoot | Out-Null
Write-Ok "admin 준비 완료"

# ============================================================================
# 5. sample(테스트 페이지) config 패치
# ============================================================================
Write-Host ""
Write-Host "########## 5단계: sample config 패치 ##########"

if (-not (Test-Path (Join-Path $SampleRoot "config") -PathType Container)) {
    Write-Err2 "config/ 폴더를 찾을 수 없습니다: $SampleRoot"
    exit 1
}
$SampleConfigDir = Join-Path $SampleRoot "config"
$SampleYml = Join-Path $SampleConfigDir "application.yml"
if (Test-Path $SampleYml) {
    # sample은 브라우저에 로드되는 정적 페이지(event.js)가 window.onload 시점에
    # 자기 백엔드(getProperties)에서 cx-url을 읽어와 "통합인증 서버 주소"
    # 입력란에 채우고, 이후 모든 API 호출을 브라우저가 그 주소로 직접 나간다.
    # 컨테이너 내부 전용 이름(oacx)을 넣으면 브라우저가 못 찾으므로 반드시
    # 이 PC/브라우저에서 접근 가능한 주소(OacxPublicUrl)를 넣어야 한다.
    $sampleContent = Read-Utf8File $SampleYml
    $sampleContent = [regex]::Replace($sampleContent, '(cx-url: ")https?://[^"]*(")', ('${1}' + $OacxPublicUrl + '${2}'))
    Write-Utf8File $SampleYml $sampleContent
    Write-Ok "sample raonsecure.cx-url을 $OacxPublicUrl(으)로 반영했습니다 (브라우저에서 직접 호출하는 주소)."
} else {
    Write-Warn2 "application.yml을 찾을 수 없어 cx-url 패치를 건너뜁니다: $SampleYml"
}

$SampleLogRoot = Join-Path $ScriptDir "log\sample"
New-Item -ItemType Directory -Force -Path $SampleLogRoot | Out-Null
Write-Ok "sample 준비 완료"

# ============================================================================
# 6. 이미지 pull + compose 기동
# ============================================================================
Write-Host ""
Write-Host "########## 6단계: 이미지 pull + compose 기동 ##########"

# 헬스체크 CMD 문자열 구성 (포트가 전부 정해진 이 시점에 구성) -- 비활성화
# 선택 시 전부 "exit 0"(즉시 통과)로 바뀐다.
if ($HealthcheckEnabled) {
    $HcDbCmd = "healthcheck.sh --connect --innodb_initialized || exit 1"
    $HcVfCmd = "curl -f http://localhost:$VfPort/ || exit 1"
    $HcOacxCmd = "curl -f http://localhost:$OacxHostPort/oacx/api/actuator/health || exit 1"
    $HcAdminCmd = "curl -f http://localhost:$AdminHostPort/ || exit 1"
    $HcSampleCmd = "curl -f http://localhost:$SampleHostPort/ || exit 1"
} else {
    $HcDbCmd = "exit 0"
    $HcVfCmd = "exit 0"
    $HcOacxCmd = "exit 0"
    $HcAdminCmd = "exit 0"
    $HcSampleCmd = "exit 0"
}

foreach ($img in @($DbImage, $VerifierImage, $OacxImage, $AdminImage, $SampleImage)) {
    Write-Info "레지스트리 이미지를 내려받는 중입니다: $img"
    docker pull $img
    if ($LASTEXITCODE -ne 0) { Write-Err2 "이미지를 가져오지 못했습니다: $img (해당 build-and-push.ps1(.sh) 로 먼저 등록하세요)"; exit 1 }
}

$EnvFile = Join-Path $ScriptDir ".staging\omnionecx.env"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $EnvFile) | Out-Null
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
OX_LOG_ROOT=$OxLogRoot
ADMIN_IMAGE=$AdminImage
ADMIN_CONTAINER=$AdminContainer
ADMIN_HOST_PORT=$AdminHostPort
ADMIN_CONFIG_DIR=$AdminConfigDir
ADMIN_LOG_ROOT=$AdminLogRoot
SAMPLE_IMAGE=$SampleImage
SAMPLE_CONTAINER=$SampleContainer
SAMPLE_HOST_PORT=$SampleHostPort
SAMPLE_CONFIG_DIR=$SampleConfigDir
SAMPLE_LOG_ROOT=$SampleLogRoot
NETWORK_NAME=$NetworkName
COMPOSE_PROJECT=$ComposeProject
HC_DB_CMD=$HcDbCmd
HC_VF_CMD=$HcVfCmd
HC_OACX_CMD=$HcOacxCmd
HC_ADMIN_CMD=$HcAdminCmd
HC_SAMPLE_CMD=$HcSampleCmd
"@ | Set-Content -Path $EnvFile -Encoding utf8

docker network inspect $NetworkName *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Info "네트워크($NetworkName)가 없어 새로 만듭니다."
    docker network create $NetworkName | Out-Null
}

$env:DB_ROOT_PASSWORD = $DbRootPassword
$env:APP_PASSWORD = $AppPassword
Write-Info "docker compose up -d 를 실행합니다 (db -> verifier -> oacx -> admin/sample 순서로 기동, 시간이 걸릴 수 있습니다)..."
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
Wait-Healthy $OacxContainer "oacx" 180; Write-Host ""
Wait-Healthy $AdminContainer "admin" 180; Write-Host ""
Wait-Healthy $SampleContainer "sample" 180; Write-Host ""

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
$OacxHttp = Test-Http "http://localhost:$OacxHostPort/oacx/api/"
$AdminHttp = Test-Http "http://localhost:$AdminHostPort/"
$SampleHttp = Test-Http "http://localhost:$SampleHostPort/"

Write-Host ""
Write-Host "======================= 접속 정보 ======================="
Write-Host " 사이트        : $Site (verifier $VerifierAppVersion / OACX $OacxAppVersion / admin $AdminAppVersion / sample $SampleAppVersion, 태그=$MovingTag)"
Write-Host " 배포 환경     : $DeployEnv (oper.mode/OperSort=$OperSort)"
Write-Host " -------------------------- [DB] --------------------------"
Write-Host " Host          : localhost / Port: $DbPort / DB: $DbName / User: $AppUser"
Write-Host " JDBC URL      : jdbc:mariadb://localhost:$DbPort/$DbName"
Write-Host " 데이터 경로   : $DbDataDir"
Write-Host " (컨테이너 간 통신용 Host: $DbContainer, Network: $NetworkName)"
Write-Host " -------------------------- [verifier] --------------------------"
Write-Host " URL           : http://localhost:$VfPort/  (HTTP $VfHttp)"
Write-Host " -------------------------- [oacx] --------------------------"
Write-Host " URL           : http://localhost:$OacxHostPort/oacx/api/  (HTTP $OacxHttp)"
Write-Host " -------------------------- [admin] --------------------------"
Write-Host " URL           : http://localhost:$AdminHostPort/  (HTTP $AdminHttp)"
Write-Host " -------------------------- [sample(테스트 페이지)] --------------------------"
Write-Host " URL           : http://localhost:$SampleHostPort/  (HTTP $SampleHttp)"
Write-Host " (브라우저가 이 페이지를 열면 '통합인증 서버 주소' 입력란에 $OacxPublicUrl 가 자동으로 채워짐)"
if ($GeneratedPw) { Write-Host " root 비밀번호(DB) : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==========================================================="
Write-Info "컨테이너 안으로 들어가려면: .\exec.ps1 <db|verifier|oacx|admin|sample> [명령]"
Write-Warn2 "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
$DbRootPassword = $null
$AppPassword = $null
