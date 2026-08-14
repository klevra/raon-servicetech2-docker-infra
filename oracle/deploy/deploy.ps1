<#
.SYNOPSIS
  Oracle 테스트 인스턴스 배포 스크립트 (PowerShell) — servicetech2 레지스트리 기반

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  전제조건 : oracle/registry/setup-registry.ps1, oracle/base/build-and-push.ps1
             가 먼저 실행되어 servicetech2 레지스트리에 이미지가 등록되어 있어야 함

  대화형으로 아래 항목을 입력받습니다:
    1) DB 종류 (현재 Oracle 고정)   2) Oracle 버전(레지스트리 태그)
    3) 스키마(SID/PDB)              4) 계정 정보(SYS/SYSTEM 비밀번호)
    5) DDL SQL 파일 경로             6) 초기데이터 DML SQL 파일 경로
    7) 포트 (리스너, EE는 EM Express 포함)

  데이터는 휘발성(볼륨 미사용)입니다. 비밀번호/토큰은 어떤 파일에도 저장하지 않습니다.
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
Write-Host " Oracle 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
Write-Host " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
Write-Host "=============================================================="

# 개발 PC: localhost:5000 / 사무실·실서버: servicetech2-registry:5000 (hosts 등록 필요)
Write-Host ""
$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "localhost:5000" }
$LocalRegistry = Ask "대상 레지스트리 주소 (호스트:포트)" $envDefault

Write-Host ""
Write-Host "DB 종류를 선택하세요 (현재는 Oracle만 지원):"
Write-Host "  1) Oracle"
$dbSel = Ask "번호 선택" "1"
if ($dbSel -ne "1") {
    Write-Err2 "현재는 Oracle만 지원합니다."
    exit 1
}
$DbKind = "oracle"

Write-Host ""
Write-Host "배포할 Oracle 버전(레지스트리 태그)을 선택하세요:"
Write-Host "  1) 19c  (Enterprise Edition — SID 임의 지정 가능, EM Express 포함)"
Write-Host "  2) 21c-xe  (Express Edition — SID 고정(XE), EM Express 없음)"
Write-Host "  3) 18c-xe  (Express Edition — SID 고정(XE), EM Express 없음)"
$VerSel = Ask "번호 선택" "1"
$IsEE = $false
switch ($VerSel) {
    "1" { $Tag = "19c"; $IsEE = $true }
    "2" { $Tag = "21c-xe" }
    "3" { $Tag = "18c-xe" }
    default { Write-Err2 "잘못된 선택입니다."; exit 1 }
}
$RegistryImage = "$LocalRegistry/$Namespace/${DbKind}:$Tag"

try {
    Invoke-WebRequest -Uri "http://$LocalRegistry/v2/" -UseBasicParsing -TimeoutSec 3 | Out-Null
} catch {
    Write-Err2 "로컬 레지스트리($LocalRegistry)가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.ps1 을 실행하세요."
    exit 1
}

Write-Info "레지스트리 이미지를 내려받는 중입니다: $RegistryImage"
docker pull $RegistryImage
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "이미지를 가져오지 못했습니다. 먼저 oracle/base/build-and-push.ps1 로 '$Tag' 태그를 등록하세요."
    exit 1
}

$DeployImage = "servicetech2/oracle-deploy:$Tag"
Write-Info "배포용 이미지를 빌드합니다: $DeployImage"
docker build --build-arg "REGISTRY_IMAGE=$RegistryImage" -t $DeployImage -f Dockerfile .
Write-Ok "빌드 완료: $DeployImage"

Write-Host ""
$ContainerName = Ask "컨테이너 이름" "oracle-$Tag-deploy"
$existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $ContainerName }
if ($existing) {
    Write-Warn2 "이미 '$ContainerName' 이름의 컨테이너가 존재합니다."
    if (Confirm "기존 컨테이너를 삭제하고 새로 만들까요?") {
        docker rm -f $ContainerName | Out-Null
        Write-Ok "기존 컨테이너 삭제 완료"
    } else {
        Write-Err2 "컨테이너 이름 충돌로 중단합니다."
        exit 1
    }
}

Write-Host ""
if ($IsEE) {
    $OracleSid = Ask "SID (인스턴스 식별자)" "VERIFIER"
    $OraclePdb = Ask "PDB(Pluggable DB) 이름" "${OracleSid}PDB"
    $ServiceName = $OraclePdb
} else {
    Write-Warn2 "Express Edition은 SID가 항상 'XE'로 고정됩니다 (제품 제약)."
    $OracleDatabase = Ask "추가 PDB 서비스 이름 (기본 XEPDB1 외 추가 생성, 비우면 생성 안 함)" ""
    $ServiceName = if ($OracleDatabase) { $OracleDatabase } else { "XEPDB1" }
}
$Charset = Ask "문자셋 (한글 지원: AL32UTF8 권장)" "AL32UTF8"

Write-Host ""
Write-Warn2 "SYS/SYSTEM 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
$DbPassword = Ask-Secret "SYS/SYSTEM 초기 비밀번호"
if ($DbPassword.Length -lt 8) {
    Write-Warn2 "8자 미만입니다. Oracle 권장 규칙(8자 이상, 대/소문자+숫자 포함)을 벗어나면 생성 중 경고가 뜨지만 보통 생성은 계속 진행됩니다."
}

Write-Host ""
$DdlDir = Ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
$DmlDir = Ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""

$StagingDir = Join-Path $ScriptDir ".staging\$ContainerName\setup"
$SetupMount = $false
if ($DdlDir -or $DmlDir) {
    $StagingParent = Join-Path $ScriptDir ".staging\$ContainerName"
    if (Test-Path $StagingParent) { Remove-Item -Recurse -Force $StagingParent }
    New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

    if ($DdlDir) {
        if (Test-Path $DdlDir -PathType Container) {
            $files = Get-ChildItem -Path $DdlDir -File
            $i = 1
            foreach ($f in $files) {
                $num = "{0:D3}" -f $i
                Copy-Item $f.FullName -Destination (Join-Path $StagingDir "10_${num}_$($f.Name)")
                $i++
            }
            Write-Ok "DDL 파일 $($files.Count)개를 스테이징했습니다 (10_ 접두어, DDL이 DML보다 먼저 실행됨)"
        } else {
            Write-Warn2 "DDL 경로를 찾을 수 없습니다: $DdlDir (건너뜁니다)"
        }
    }
    if ($DmlDir) {
        if (Test-Path $DmlDir -PathType Container) {
            $files = Get-ChildItem -Path $DmlDir -File
            $i = 1
            foreach ($f in $files) {
                $num = "{0:D3}" -f $i
                Copy-Item $f.FullName -Destination (Join-Path $StagingDir "50_${num}_$($f.Name)")
                $i++
            }
            Write-Ok "DML 파일 $($files.Count)개를 스테이징했습니다 (50_ 접두어, DDL 이후 실행됨)"
        } else {
            Write-Warn2 "DML 경로를 찾을 수 없습니다: $DmlDir (건너뜁니다)"
        }
    }
    $SetupMount = $true
}

Write-Host ""
$ListenerPort = Ask "리스너 포트" "1521"
if (Port-InUse $ListenerPort) {
    Write-Warn2 "포트 $ListenerPort 은(는) 이미 사용 중인 것으로 보입니다."
}
if ($IsEE) {
    $EmPort = Ask "EM Express(관리 콘솔) 포트" "5500"
}

Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 이미지        : $DeployImage"
Write-Host " 컨테이너 이름 : $ContainerName"
if ($IsEE) {
    Write-Host " SID / PDB     : $OracleSid / $OraclePdb"
} else {
    $pdbDisplay = if ($OracleDatabase) { $OracleDatabase } else { "(생성 안 함, 기본 XEPDB1만 사용)" }
    Write-Host " 추가 PDB      : $pdbDisplay"
}
Write-Host " 문자셋        : $Charset"
Write-Host " 리스너 포트   : $ListenerPort"
if ($IsEE) { Write-Host " EM 포트       : $EmPort" }
Write-Host " DDL 경로      : $(if ($DdlDir) { $DdlDir } else { '(없음)' })"
Write-Host " DML 경로      : $(if ($DmlDir) { $DmlDir } else { '(없음)' })"
Write-Host " 데이터        : 휘발성(볼륨 미사용)"
Write-Host "==========================================================="
if (-not (Confirm "위 설정으로 컨테이너를 생성할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

$RunArgs = @("-d", "--name", $ContainerName, "-p", "${ListenerPort}:1521", "--shm-size=1g")
if ($IsEE) { $RunArgs += @("-p", "${EmPort}:5500") }
if ($SetupMount) { $RunArgs += @("-v", "${StagingDir}:/opt/oracle/scripts/setup:ro") }

if ($IsEE) {
    $RunArgs += @(
        "-e", "ORACLE_SID=$OracleSid",
        "-e", "ORACLE_PDB=$OraclePdb",
        "-e", "ORACLE_PWD=$DbPassword",
        "-e", "ORACLE_CHARACTERSET=$Charset"
    )
} else {
    $RunArgs += @(
        "-e", "ORACLE_PASSWORD=$DbPassword",
        "-e", "ORACLE_CHARACTERSET=$Charset"
    )
    if ($OracleDatabase) { $RunArgs += @("-e", "ORACLE_DATABASE=$OracleDatabase") }
}

Write-Info "컨테이너를 실행합니다: $ContainerName"
docker run @RunArgs $DeployImage
$DbPassword = $null

Write-Info "DB 초기화를 기다리는 중입니다 (에디션에 따라 2~20분 소요될 수 있습니다)..."
$Elapsed = 0; $Interval = 15; $Timeout = 1800
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
        Write-Warn2 "제한 시간 내에 healthy 상태가 되지 않았습니다. 'docker logs -f $ContainerName' 로 직접 확인하세요."
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
if ($IsEE) { Write-Host " EM Express : https://localhost:$EmPort/em" }
Write-Host "==========================================================="
Write-Warn2 "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
