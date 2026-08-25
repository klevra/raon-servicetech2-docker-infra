<#
.SYNOPSIS
  MariaDB 테스트 인스턴스 배포 스크립트 (PowerShell) — servicetech2 레지스트리 기반

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  전제조건 : oracle/registry/setup-registry.ps1, mariadb/base/build-and-push.ps1
             가 먼저 실행되어 servicetech2 레지스트리에 이미지가 등록되어 있어야 함
             (레지스트리 자체는 DB 종류와 무관하게 공용으로 사용)

  대화형으로 아래 항목을 입력받습니다:
    1) DB 종류 (현재 MariaDB 고정)  2) MariaDB 버전(레지스트리 태그)
    3) 컨테이너 이름                4) DB 이름(스키마)
    5) 관리자(root) 비밀번호        6) 애플리케이션 계정(선택)
    7) DDL SQL 파일 경로            8) 초기데이터 DML SQL 파일 경로
    9) 포트 (리스너)                10) 실행 로그 파일 저장 여부 (선택, 기본 n)

  접속 IP 제한: 이 프로젝트는 별도 bind-address 제약이나 방화벽 규칙을 추가하지
  않으며, docker run -p 도 호스트IP 미지정(0.0.0.0 바인딩)이라 기본적으로 접속 IP
  제한이 없습니다. (단, MariaDB는 Oracle과 달리 계정이 'user'@'host' 형태로 host에
  종속될 수 있으나, 공식 이미지의 MARIADB_USER는 '%'(모든 host)로 생성됨)

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
    # 대/소문자+숫자를 각각 포함하는 16자 랜덤 비밀번호 생성
    $upper = -join ((65..90)  | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    $lower = -join ((97..122) | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    $digit = -join ((48..57)  | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    $pool  = (48..57) + (65..90) + (97..122)
    $rest  = -join ($pool | Get-Random -Count 7 | ForEach-Object { [char]$_ })
    return "$upper$lower$digit$rest"
}

Write-Host "=============================================================="
Write-Host " MariaDB 테스트 인스턴스 배포 (servicetech2 레지스트리 기반)"
Write-Host " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
Write-Host "=============================================================="

# 개발 PC: localhost:5000 / 팀서버(new-servicetech2-1, 192.168.0.168): servicetech2:5000
# (팀서버 접속 전 각 PC에서 사전 준비 필요 -- hosts 등록 + insecure-registry 등록:
#  registry-server/linux-registry-setup.md 참고)
Write-Host ""
$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "192.168.0.168:5000" }
$LocalRegistry = Ask "대상 레지스트리 주소 (호스트:포트)" $envDefault

Write-Host ""
Write-Host "DB 종류를 선택하세요 (현재는 MariaDB만 지원):"
Write-Host "  1) MariaDB"
$dbSel = Ask "번호 선택" "1"
if ($dbSel -ne "1") {
    Write-Err2 "현재는 MariaDB만 지원합니다."
    exit 1
}
$DbKind = "mariadb"

Write-Host ""
Write-Host "배포할 MariaDB 버전(레지스트리 태그)을 선택하세요:"
Write-Host "  1) latest"
Write-Host "  2) 11.4   (LTS)"
Write-Host "  3) 10.11  (구버전 LTS, 레거시 호환용)"
$VerSel = Ask "번호 선택" "1"
switch ($VerSel) {
    "1" { $Tag = "latest" }
    "2" { $Tag = "11.4" }
    "3" { $Tag = "10.11" }
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
    Write-Err2 "이미지를 가져오지 못했습니다. 먼저 mariadb/base/build-and-push.ps1 로 '$Tag' 태그를 등록하세요."
    exit 1
}

$DeployImage = "servicetech2/mariadb-deploy:$Tag"
Write-Info "배포용 이미지를 빌드합니다: $DeployImage"
docker build --build-arg "REGISTRY_IMAGE=$RegistryImage" -t $DeployImage -f Dockerfile .
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "배포용 이미지 빌드 실패."
    exit 1
}
Write-Ok "빌드 완료: $DeployImage"

Write-Host ""
$ContainerName = Ask "컨테이너 이름" "mariadb-$Tag-deploy"
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
$DbName = Ask "최초 생성할 DB(스키마) 이름" "testdb"

Write-Host ""
Write-Warn2 "root 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
$DbPassword = Ask-Secret "root 초기 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
$GeneratedPw = $false
if ([string]::IsNullOrEmpty($DbPassword)) {
    $DbPassword = New-RandomPassword
    $GeneratedPw = $true
    Write-Ok "비밀번호를 입력하지 않아 랜덤 비밀번호를 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다. 파일에는 저장하지 않습니다)."
}

Write-Host ""
Write-Info "root는 관리자 계정입니다. 애플리케이션에서 쓸 별도 계정을 만들고 싶다면 아래에서 생성하세요."
Write-Info "(MariaDB 공식 이미지 기능으로 생성 -- 별도 SQL 없이 지정한 DB에 자동으로 전체 권한 부여됨)"
$AppUser = ""
$AppPassword = ""
$AppGeneratedPw = $false
if (Confirm "애플리케이션 계정을 생성할까요? (생성 시 '$DbName' DB에 전체 권한 부여)") {
    $AppUser = Ask "애플리케이션 계정 이름" "appuser"
    $AppPassword = Ask-Secret "애플리케이션 계정 비밀번호 (비우면 랜덤 비밀번호 자동 생성)"
    if ([string]::IsNullOrEmpty($AppPassword)) {
        $AppPassword = New-RandomPassword
        $AppGeneratedPw = $true
        Write-Ok "애플리케이션 계정 비밀번호를 자동 생성했습니다 (아래 실행 요약과 접속 정보에 표시됩니다)."
    }
}

Write-Host ""
$DdlDir = Ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
$DmlDir = Ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""

$StagingDir = Join-Path $ScriptDir ".staging\$ContainerName\initdb"
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
    Write-Warn2 "MariaDB의 /docker-entrypoint-initdb.d/ 자동 실행은 데이터 볼륨이 비어있는 최초 기동 시에만 동작합니다 (이 프로젝트는 항상 휘발성이라 매번 최초 기동입니다)."
}

Write-Host ""
$ListenerPort = Ask "포트" "3306"
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
Write-Both " DB 이름       : $DbName"
Write-Both " 포트          : $ListenerPort"
Write-Both " ---------------------------------------------------------"
Write-Both " [관리자] 계정 : root"
Write-Both " [관리자] URL  : jdbc:mariadb://localhost:$ListenerPort/$DbName"
if ($AppUser) {
    Write-Both " ---------------------------------------------------------"
    Write-Both " [앱]   계정   : $AppUser  ($DbName DB에 전체 권한)"
    Write-Both " [앱]   URL    : jdbc:mariadb://localhost:$ListenerPort/$DbName"
} else {
    Write-Both " ---------------------------------------------------------"
    Write-Both " [앱]   계정   : (생성 안 함, root로만 접속)"
}
Write-Both " ---------------------------------------------------------"
Write-Both " 접속 IP 제한  : 없음 (0.0.0.0 바인딩, MARIADB_USER는 '%'(모든 host)로 생성됨)"
Write-Both " DDL 경로      : $(if ($DdlDir) { $DdlDir } else { '(없음)' })"
Write-Both " DML 경로      : $(if ($DmlDir) { $DmlDir } else { '(없음)' })"
Write-Both " 데이터        : 휘발성(볼륨 미사용)"
if ($GeneratedPw) { Write-Both " 생성된 비밀번호(root) : $DbPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
if ($AppGeneratedPw) { Write-Both " 생성된 비밀번호($AppUser): $AppPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Both "==========================================================="
if (-not (Confirm "위 설정으로 컨테이너를 생성할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

$RunArgs = @("-d", "--name", $ContainerName, "-p", "${ListenerPort}:3306")
if ($SetupMount) { $RunArgs += @("-v", "${StagingDir}:/docker-entrypoint-initdb.d:ro") }
$RunArgs += @(
    "-e", "MARIADB_ROOT_PASSWORD=$DbPassword",
    "-e", "MARIADB_DATABASE=$DbName",
    "-e", "TZ=Asia/Seoul"
)
if ($AppUser) {
    $RunArgs += @(
        "-e", "MARIADB_USER=$AppUser",
        "-e", "MARIADB_PASSWORD=$AppPassword"
    )
}

Write-Info "컨테이너를 실행합니다: $ContainerName"
docker run @RunArgs $DeployImage

Write-Info "DB 초기화를 기다리는 중입니다..."
$Elapsed = 0; $Interval = 5; $Timeout = 300
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
Write-Both " Database   : $DbName"
Write-Both " Username   : root"
Write-Both " JDBC URL   : jdbc:mariadb://localhost:$ListenerPort/$DbName"
if ($GeneratedPw) {
    Write-Both " 접속 예시  : mariadb -h 127.0.0.1 -P $ListenerPort -u root -p$DbPassword $DbName"
} else {
    Write-Both " 접속 예시  : mariadb -h 127.0.0.1 -P $ListenerPort -u root -p<입력한 비밀번호> $DbName"
}
if ($AppUser) {
    Write-Both " ---------------------------- [앱] -----------------------------"
    Write-Both " 계정       : $AppUser  ($DbName DB에 전체 권한)"
    Write-Both " JDBC URL   : jdbc:mariadb://localhost:$ListenerPort/$DbName"
    if ($AppGeneratedPw) {
        Write-Both " 접속 예시  : mariadb -h 127.0.0.1 -P $ListenerPort -u $AppUser -p$AppPassword $DbName"
    } else {
        Write-Both " 접속 예시  : mariadb -h 127.0.0.1 -P $ListenerPort -u $AppUser -p<입력한 비밀번호> $DbName"
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
