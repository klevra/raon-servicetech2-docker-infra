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
    5) 애플리케이션 계정(선택)      6) DDL SQL 파일 경로
    7) 초기데이터 DML SQL 파일 경로  8) 포트 (리스너)
    9) 실행 로그 파일 저장 여부 (선택, 기본 n -- 저장 시 비밀번호가 평문으로 파일에 남음)

  접속 IP 제한: 이 프로젝트는 sqlnet.ora 등에 별도 Valid Node Checking/ACL을 추가하지
  않으며, docker run -p 도 호스트IP 미지정(0.0.0.0 바인딩)이라 기본적으로 접속 IP
  제한이 없습니다. Oracle 인증은 MySQL과 달리 계정이 특정 host에 종속되지 않습니다.

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
    # Read-Host -AsSecureString는 실제 콘솔에서만 동작하며, 표준입력이 파일/파이프로
    # 리다이렉트된 상황(자동화·비대화형 실행)에서는 무한 대기(hang)한다.
    # 이런 경우를 감지해 일반 Read-Host(파이프 입력도 정상 처리)로 자동 전환한다.
    if ([Console]::IsInputRedirected) {
        return Read-Host "$Prompt"
    }
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

# Confirm과 동일하지만 기본값이 y가 아니라 n (민감정보 포함 등, 명시적 동의가 필요한 항목용)
function Confirm-No([string]$Prompt = "계속 진행할까요?") {
    $val = Read-Host "$Prompt (y/n) [n]"
    if ([string]::IsNullOrWhiteSpace($val)) { $val = "n" }
    return $val -match '^[Yy]'
}

function Port-InUse([string]$Port) {
    $ports = docker ps --format '{{.Ports}}' 2>$null
    return ($ports -match ":$Port->")
}

function New-RandomPassword {
    # 대/소문자+숫자를 각각 포함하는 16자 랜덤 비밀번호 생성 (Oracle 복잡도 규칙 충족)
    $upper = -join ((65..90)  | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    $lower = -join ((97..122) | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    $digit = -join ((48..57)  | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    $pool  = (48..57) + (65..90) + (97..122)
    $rest  = -join ($pool | Get-Random -Count 7 | ForEach-Object { [char]$_ })
    return "$upper$lower$digit$rest"
}

Write-Host "=============================================================="
Write-Host " Oracle 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
Write-Host " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
Write-Host "=============================================================="

# 개발 PC: localhost:5000 / 팀서버(new-servicetech2-1, 192.168.0.168): servicetech2:5000
# (팀서버 접속 전 각 PC에서 사전 준비 필요 -- hosts 등록 + insecure-registry 등록:
#  registry-server/linux-registry-setup.md 참고)
Write-Host ""
$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "192.168.0.168:5000" }
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
Write-Host "  1) 19c  (Enterprise Edition — SID 임의 지정 가능)"
Write-Host "  2) 21c-xe  (Express Edition — SID 고정(XE))"
Write-Host "  3) 18c-xe  (Express Edition — SID 고정(XE))"
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
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "배포용 이미지 빌드 실패."
    exit 1
}
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
$DbPassword = Ask-Secret "SYS/SYSTEM 초기 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
$GeneratedPw = $false
if ([string]::IsNullOrEmpty($DbPassword)) {
    $DbPassword = New-RandomPassword
    $GeneratedPw = $true
    Write-Ok "비밀번호를 입력하지 않아 랜덤 비밀번호를 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다. 파일에는 저장하지 않습니다)."
} elseif ($DbPassword.Length -lt 8) {
    Write-Warn2 "8자 미만입니다. Oracle 권장 규칙(8자 이상, 대/소문자+숫자 포함)을 벗어나면 생성 중 경고가 뜨지만 보통 생성은 계속 진행됩니다."
}

Write-Host ""
Write-Info "SYS/SYSTEM은 관리자 계정입니다. 애플리케이션에서 쓸 별도 계정을 만들고 싶다면 아래에서 생성하세요."
$AppUser = ""
$AppPassword = ""
$AppGeneratedPw = $false
$AppConnectMode = "service"
$AppConnectDb = ""
$AppConnectLabel = ""
if (Confirm "애플리케이션 계정을 생성할까요? (생성 시 ALL PRIVILEGES 부여)") {
    $AppUser = Ask "애플리케이션 계정 이름" "APPUSER"
    $AppPassword = Ask-Secret "애플리케이션 계정 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
    if ([string]::IsNullOrEmpty($AppPassword)) {
        $AppPassword = New-RandomPassword
        $AppGeneratedPw = $true
        Write-Ok "애플리케이션 계정 비밀번호를 자동 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다)."
    }

    Write-Host ""
    Write-Host "접속 방식을 선택하세요:"
    Write-Host "  1) Service Name (PDB 안에 생성, 권장 -- DBeaver 'Service Name'으로 접속)"
    Write-Host "  2) SID (CDB 루트에 생성 -- DBeaver 'SID'로 접속, PDB 격리 없이 루트 컨테이너에 직접 생성)"
    $ConnSel = Ask "번호 선택" "1"
    if ($ConnSel -eq "2") {
        $AppConnectMode = "sid"
        $AppConnectDb = if ($IsEE) { $OracleSid } else { "XE" }
        $AppConnectLabel = "SID"
    } else {
        $AppConnectMode = "service"
        $AppConnectDb = $ServiceName
        $AppConnectLabel = "Service Name"
    }
}

Write-Host ""
$DdlDir = Ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
$DmlDir = Ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""

$StagingDir = Join-Path $ScriptDir ".staging\$ContainerName\setup"
$SetupMount = $false
if ($AppUser -or $DdlDir -or $DmlDir) {
    $StagingParent = Join-Path $ScriptDir ".staging\$ContainerName"
    if (Test-Path $StagingParent) { Remove-Item -Recurse -Force $StagingParent }
    New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

    if ($AppUser) {
        if ($AppConnectMode -eq "sid") {
            $appSql = @"
-- servicetech2 배포 스크립트 자동 생성 (테스트/개발 전용 -- ALL PRIVILEGES는 운영 환경에 부적합)
-- SID 방식: CDB 루트에 직접 생성한다. 루트에서는 C## 접두어 없는 계정명이 기본적으로
-- 거부되므로(ORA-65096) "_ORACLE_SCRIPT"=true로 그 제약을 우회한다(컨테이너 스크립트 표준 기법).
-- 계정명은 따옴표 없이 생성 -- Oracle 기본 규칙대로 자동 대문자 변환되어, SYSTEM/SYS와 동일하게
-- 대소문자 구분 없이(DBeaver 등에서 따옴표 없이 입력해도) 접속 가능해진다.
ALTER SESSION SET "_ORACLE_SCRIPT"=true;
CREATE USER $AppUser IDENTIFIED BY "$AppPassword";
GRANT ALL PRIVILEGES TO $AppUser;
"@
        } else {
            $appSql = @"
-- servicetech2 배포 스크립트 자동 생성 (테스트/개발 전용 -- ALL PRIVILEGES는 운영 환경에 부적합)
-- Service Name 방식: 커스텀 setup 스크립트는 기본적으로 CDB 루트에서 실행되므로, PDB로
-- 컨테이너를 전환해야 C## 접두어 없는 일반 계정명을 만들 수 있다 (안 하면 ORA-65096).
-- 계정명은 따옴표 없이 생성 -- Oracle 기본 규칙대로 자동 대문자 변환되어, SYSTEM/SYS와 동일하게
-- 대소문자 구분 없이(DBeaver 등에서 따옴표 없이 입력해도) 접속 가능해진다.
ALTER SESSION SET CONTAINER = "$ServiceName";
CREATE USER $AppUser IDENTIFIED BY "$AppPassword";
GRANT ALL PRIVILEGES TO $AppUser;
"@
        }
        [System.IO.File]::WriteAllText((Join-Path $StagingDir "01_create_app_user.sql"), $appSql, [System.Text.UTF8Encoding]::new($false))
        Write-Ok "애플리케이션 계정 생성 SQL을 스테이징했습니다 (01_ 접두어, DDL/DML보다 먼저 실행됨, 접속 방식: $AppConnectLabel)"
    }

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

Write-Host ""
$LogFile = $null
if (Confirm-No "실행 요약/접속 정보를 로그 파일로 저장할까요? (생성된 비밀번호가 평문으로 포함됩니다)") {
    $LogDir = Join-Path $ScriptDir "logs"
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $LogFile = Join-Path $LogDir "${ContainerName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-Ok "로그 파일: $LogFile (.gitignore에 등록되어 있어 커밋되지 않습니다)"
}

function Write-Both([string]$msg) {
    Write-Host $msg
    if ($LogFile) { Add-Content -Path $LogFile -Value $msg -Encoding utf8 }
}

Write-Host ""
Write-Both "======================= 실행 요약 ======================="
Write-Both " DB 종류       : $DbKind"
Write-Both " 버전(태그)    : $Tag"
Write-Both " 이미지        : $DeployImage"
Write-Both " 컨테이너 이름 : $ContainerName"
if ($IsEE) {
    Write-Both " SID / PDB     : $OracleSid / $OraclePdb"
} else {
    $pdbDisplay = if ($OracleDatabase) { $OracleDatabase } else { "(생성 안 함, 기본 XEPDB1만 사용)" }
    Write-Both " 추가 PDB      : $pdbDisplay"
}
Write-Both " 문자셋        : $Charset"
Write-Both " 리스너 포트   : $ListenerPort"
Write-Both " ---------------------------------------------------------"
Write-Both " [관리자] 계정 : SYSTEM  (SYS도 동일 비밀번호, Role=SYSDBA로 접속 시 사용)"
Write-Both " [관리자] URL  : jdbc:oracle:thin:@localhost:$ListenerPort/$ServiceName  (PDB 기준 고정)"
Write-Both "               (DBeaver 'Database/Service Name' 필드에는 SID가 아니라 '$ServiceName'을 입력)"
if ($AppUser) {
    $AppJdbcUrl = if ($AppConnectMode -eq "sid") { "jdbc:oracle:thin:@localhost:${ListenerPort}:${AppConnectDb}" } else { "jdbc:oracle:thin:@localhost:${ListenerPort}/${AppConnectDb}" }
    Write-Both " ---------------------------------------------------------"
    Write-Both " [앱]   계정   : $AppUser  (ALL PRIVILEGES)"
    Write-Both " [앱]   접속방식: $AppConnectLabel = $AppConnectDb"
    Write-Both " [앱]   URL    : $AppJdbcUrl"
} else {
    Write-Both " ---------------------------------------------------------"
    Write-Both " [앱]   계정   : (생성 안 함, SYSTEM으로만 접속)"
}
Write-Both " ---------------------------------------------------------"
Write-Both " 접속 IP 제한  : 없음 (0.0.0.0 바인딩, Oracle 계정은 host에 종속되지 않음)"
Write-Both " DDL 경로      : $(if ($DdlDir) { $DdlDir } else { '(없음)' })"
Write-Both " DML 경로      : $(if ($DmlDir) { $DmlDir } else { '(없음)' })"
Write-Both " 데이터        : 휘발성(볼륨 미사용)"
if ($GeneratedPw) { Write-Both " 생성된 비밀번호(SYSTEM) : $DbPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
if ($AppGeneratedPw) { Write-Both " 생성된 비밀번호($AppUser): $AppPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Both "==========================================================="
if (-not (Confirm "위 설정으로 컨테이너를 생성할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

$RunArgs = @("-d", "--name", $ContainerName, "-p", "${ListenerPort}:1521", "--shm-size=1g")
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
Write-Both "======================= 접속 정보 ======================="
Write-Both " DB 종류    : $DbKind"
Write-Both " 버전(태그) : $Tag"
Write-Both " Host       : localhost"
Write-Both " Port       : $ListenerPort"
Write-Both " -------------------------- [관리자] --------------------------"
Write-Both " Service    : $ServiceName  (DBeaver 'Database/Service Name' 필드 — SID 아님, PDB 기준 고정)"
Write-Both " Username   : SYSTEM  (SYS도 동일 비밀번호, 접속 시 Role=SYSDBA 필요)"
Write-Both " JDBC URL   : jdbc:oracle:thin:@localhost:$ListenerPort/$ServiceName"
if ($GeneratedPw) {
    Write-Both " 접속 예시  : sqlplus system/$DbPassword@localhost:$ListenerPort/$ServiceName"
} else {
    Write-Both " 접속 예시  : sqlplus system/<입력한 비밀번호>@localhost:$ListenerPort/$ServiceName"
}
if ($AppUser) {
    $AppJdbcUrl = if ($AppConnectMode -eq "sid") { "jdbc:oracle:thin:@localhost:${ListenerPort}:${AppConnectDb}" } else { "jdbc:oracle:thin:@localhost:${ListenerPort}/${AppConnectDb}" }
    Write-Both " ---------------------------- [앱] -----------------------------"
    Write-Both " 계정       : $AppUser  (ALL PRIVILEGES)"
    Write-Both " DBeaver    : Connection Type = $AppConnectLabel, Database = $AppConnectDb"
    Write-Both " JDBC URL   : $AppJdbcUrl"
    if ($AppGeneratedPw) {
        Write-Both " 접속 예시  : sqlplus $AppUser/$AppPassword@localhost:$ListenerPort/$AppConnectDb"
    } else {
        Write-Both " 접속 예시  : sqlplus $AppUser/<입력한 비밀번호>@localhost:$ListenerPort/$AppConnectDb"
    }
}
Write-Both "==========================================================="
if ($LogFile) {
    Write-Warn2 "비밀번호가 포함된 로그 파일이 남아있습니다: $LogFile (필요 없어지면 직접 삭제하세요)"
} else {
    Write-Warn2 "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
}
$DbPassword = $null
$AppPassword = $null
