<#
.SYNOPSIS
  Oracle Database 테스트용 Docker 컨테이너 대화형 설치 스크립트 (PowerShell)

.DESCRIPTION
  지원 환경 : Windows PowerShell 5.1+ / PowerShell 7+
  목적      : 테스트·개발·데모 용도로 Oracle DB 컨테이너를 대화형으로 구성/실행

  라이선스 주의사항
    - 19c Enterprise Edition : Oracle 공식 OTN 라이선스(개발/테스트/데모 목적 무료).
      Oracle 계정 + container-registry.oracle.com 라이선스 동의 + Auth Token 필요.
      (2025-06-30부터 계정 비밀번호가 아닌 Auth Token으로만 docker login 가능)
    - 21c/18c Express Edition(XE) : 완전 무료, 커뮤니티(gvenzl) 빌드 이미지 사용, 계정 불필요.
    - 어떤 옵션도 "운영(production) 환경" 사용을 허용하지 않습니다. 테스트/개발/데모 전용입니다.

  이 스크립트는 어떤 비밀번호/토큰도 파일에 저장하지 않습니다 (변수에만 보관, 사용 후 폐기).
#>

$RegistryHost = "container-registry.oracle.com"

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

function Ask-Secret([string]$Prompt) {
    $secure = Read-Host "$Prompt" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Confirm([string]$Prompt = "계속 진행할까요?") {
    $val = Read-Host "$Prompt (y/n) [y]"
    if ([string]::IsNullOrWhiteSpace($val)) { $val = "y" }
    return $val -match '^[Yy]'
}

function Port-InUse([string]$Port) {
    $ports = docker ps --format '{{.Ports}}' 2>$null
    return ($ports -match ":$Port->")
}

Write-Host "=============================================================="
Write-Host " Oracle Database 테스트용 Docker 설치 스크립트"
Write-Host " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
Write-Host "=============================================================="

Write-Host ""
Write-Host "설치할 Oracle 에디션을 선택하세요:"
Write-Host "  1) Oracle 19c Enterprise Edition  (공식 레지스트리, Oracle 계정 필요)"
Write-Host "  2) Oracle 21c Express Edition XE  (커뮤니티 이미지, 계정 불필요)"
Write-Host "  3) Oracle 18c Express Edition XE  (커뮤니티 이미지, 계정 불필요, 레거시 호환용)"
$Edition = Ask "번호 선택" "2"

$NeedsLogin = $false
switch ($Edition) {
    "1" {
        $EditionName = "19c Enterprise Edition"
        $Image = "$RegistryHost/database/enterprise:19.3.0.0"
        $NeedsLogin = $true
        $DefaultName = "oracle19c-test"
    }
    "2" {
        $EditionName = "21c Express Edition"
        $Image = "gvenzl/oracle-xe:21-slim"
        $DefaultName = "oracle21xe-test"
    }
    "3" {
        $EditionName = "18c Express Edition"
        $Image = "gvenzl/oracle-xe:18-slim"
        $DefaultName = "oracle18xe-test"
    }
    default {
        Write-Err2 "잘못된 선택입니다."
        exit 1
    }
}
Write-Ok "선택됨: $EditionName ($Image)"

if ($NeedsLogin) {
    Write-Host ""
    Write-Info "Enterprise Edition은 Oracle 계정 인증이 필요합니다."
    $env:DOCKER_CLI_EXPERIMENTAL = "enabled"
    docker manifest inspect $Image *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "이미 로그인/캐시된 자격증명으로 이미지 접근이 가능합니다. 로그인 단계를 건너뜁니다."
    } else {
        Write-Warn2 "먼저 브라우저에서 아래를 완료해야 합니다:"
        Write-Host "   1) https://$RegistryHost 접속 후 로그인"
        Write-Host "   2) Database > enterprise 리포지터리 라이선스 동의(Continue)"
        Write-Host "   3) 계정 아이콘 > Auth Token 메뉴에서 토큰 발급"
        Write-Host "      (2025-06-30부터 계정 비밀번호가 아닌 Auth Token만 docker login에 사용 가능)"
        Write-Host ""
        Read-Host "위 단계를 완료했으면 Enter를 눌러 계속하세요"
        $OracleUser = Ask "Oracle 계정 이메일(Username)"
        $AuthToken = Ask-Secret "Auth Token"
        $AuthToken | docker login $RegistryHost --username $OracleUser --password-stdin
        if ($LASTEXITCODE -ne 0) {
            Write-Err2 "로그인 실패. Auth Token 또는 라이선스 동의 상태를 다시 확인하세요."
            exit 1
        }
        $AuthToken = $null
        Write-Ok "로그인 성공"
    }
}

Write-Host ""
$ContainerName = Ask "컨테이너 이름" $DefaultName

$existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $ContainerName }
if ($existing) {
    Write-Warn2 "이미 '$ContainerName' 이름의 컨테이너가 존재합니다."
    if (Confirm "기존 컨테이너를 삭제하고 새로 만들까요?") {
        docker rm -f $ContainerName | Out-Null
        Write-Ok "기존 컨테이너 삭제 완료"
    } else {
        Write-Err2 "컨테이너 이름 충돌로 중단합니다. 스크립트를 다시 실행해 다른 이름을 입력하세요."
        exit 1
    }
}

if ($Edition -eq "1") {
    $OracleSid = Ask "SID (인스턴스 식별자)" "VERIFIER"
    $OraclePdb = Ask "PDB(Pluggable DB) 이름" "${OracleSid}PDB"
} else {
    $OracleDatabase = Ask "추가 PDB 서비스 이름 (기본 XEPDB1 외에 추가 생성, 비워두면 생성 안 함)" ""
}

$Charset = Ask "문자셋 (한글 지원: AL32UTF8 권장)" "AL32UTF8"
$ListenerPort = Ask "리스너 포트" "1521"
if (Port-InUse $ListenerPort) {
    Write-Warn2 "포트 $ListenerPort 은(는) 이미 사용 중인 것으로 보입니다. 계속 진행하면 실행 시 실패할 수 있습니다."
}

if ($Edition -eq "1") {
    $EmPort = Ask "EM Express(관리 콘솔) 포트" "5500"
}

Write-Host ""
Write-Warn2 "SYS/SYSTEM 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
$DbPassword = Ask-Secret "SYS/SYSTEM 초기 비밀번호"
if ($DbPassword.Length -lt 8) {
    Write-Warn2 "8자 미만입니다. Oracle 권장 규칙(8자 이상, 대/소문자+숫자 포함)을 벗어나면 생성 중 경고가 뜨지만, 보통 생성 자체는 계속 진행됩니다."
}

$Persist = Confirm "데이터를 컨테이너 삭제 후에도 유지할까요? (볼륨 마운트)"
if ($Persist) {
    $VolumeName = Ask "볼륨 이름" "$ContainerName-data"
}

Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 에디션        : $EditionName"
Write-Host " 이미지        : $Image"
Write-Host " 컨테이너 이름 : $ContainerName"
if ($Edition -eq "1") {
    Write-Host " SID / PDB     : $OracleSid / $OraclePdb"
} else {
    $pdbDisplay = if ($OracleDatabase) { $OracleDatabase } else { "(생성 안 함, 기본 XEPDB1만 사용)" }
    Write-Host " 추가 PDB      : $pdbDisplay"
}
Write-Host " 문자셋        : $Charset"
Write-Host " 리스너 포트   : $ListenerPort"
if ($Edition -eq "1") { Write-Host " EM 포트       : $EmPort" }
$persistDisplay = if ($Persist) { "볼륨 유지 ($VolumeName)" } else { "휘발성(볼륨 없음)" }
Write-Host " 데이터 영속성 : $persistDisplay"
Write-Host " 비밀번호      : (입력됨, 표시 안 함)"
Write-Host "==========================================================="
Write-Host ""

if (-not (Confirm "위 설정으로 컨테이너를 생성할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

Write-Info "이미지를 내려받는 중입니다: $Image"
docker pull $Image

$RunArgs = @("-d", "--name", $ContainerName, "-p", "${ListenerPort}:1521", "--shm-size=1g")
if ($Edition -eq "1") { $RunArgs += @("-p", "${EmPort}:5500") }
if ($Persist) { $RunArgs += @("-v", "${VolumeName}:/opt/oracle/oradata") }

if ($Edition -eq "1") {
    $RunArgs += @(
        "-e", "ORACLE_SID=$OracleSid",
        "-e", "ORACLE_PDB=$OraclePdb",
        "-e", "ORACLE_PWD=$DbPassword",
        "-e", "ORACLE_CHARACTERSET=$Charset"
    )
    $ServiceName = $OraclePdb
} else {
    $RunArgs += @(
        "-e", "ORACLE_PASSWORD=$DbPassword",
        "-e", "ORACLE_CHARACTERSET=$Charset"
    )
    if ($OracleDatabase) { $RunArgs += @("-e", "ORACLE_DATABASE=$OracleDatabase") }
    $ServiceName = if ($OracleDatabase) { $OracleDatabase } else { "XEPDB1" }
}

Write-Info "컨테이너를 실행합니다: $ContainerName"
docker run @RunArgs $Image
$DbPassword = $null

Write-Info "DB 초기화를 기다리는 중입니다 (에디션에 따라 2~20분 소요될 수 있습니다)..."
$Elapsed = 0
$Interval = 15
$Timeout = 1800
while ($true) {
    $Status = (docker inspect -f '{{.State.Health.Status}}' $ContainerName 2>$null)
    if ($Status -eq "healthy") {
        Write-Ok "컨테이너가 정상 기동되었습니다."
        break
    }
    $running = docker ps -q -f "name=^$ContainerName`$"
    if (-not $running) {
        Write-Err2 "컨테이너가 중단되었습니다. 로그를 확인하세요:"
        docker logs $ContainerName 2>&1 | Select-Object -Last 60
        exit 1
    }
    if ($Elapsed -ge $Timeout) {
        Write-Warn2 "제한 시간(${Timeout}초) 내에 healthy 상태가 되지 않았습니다. 계속 기동 중일 수 있으니 'docker logs -f $ContainerName' 로 직접 확인하세요."
        break
    }
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval
    Write-Host "." -NoNewline
}
Write-Host ""

Write-Host ""
Write-Host "======================= 접속 정보 ======================="
Write-Host " Host       : localhost"
Write-Host " Port       : $ListenerPort"
Write-Host " Service    : $ServiceName"
Write-Host " 접속 예시  : sqlplus system/<입력한 비밀번호>@localhost:$ListenerPort/$ServiceName"
if ($Edition -eq "1") { Write-Host " EM Express : https://localhost:$EmPort/em" }
Write-Host "==========================================================="
Write-Warn2 "이 스크립트는 비밀번호/토큰을 어떤 파일에도 저장하지 않았습니다. 필요 시 별도로 안전하게 보관하세요."
