<#
.SYNOPSIS
  verifier(mdl-verifier) + MariaDB 통합 테스트 배포 스크립트 (PowerShell)

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  전제조건 : oracle/registry/setup-registry.ps1, mariadb/base/build-and-push.ps1
             가 먼저 실행되어 servicetech2 레지스트리에 MariaDB 이미지가 등록되어 있어야 함

  이 스크립트가 하는 일:
    1) MariaDB 컨테이너 배포 (레지스트리 이미지, DDL/DML 자동 실행, klevra 계정 생성)
    2) verifier(mdl-verifier) 런타임 이미지 빌드 (Dockerfile은 VerifierRoot 안에 위치)
    3) 위 두 컨테이너를 같은 브리지 네트워크로 묶어 컨테이너 이름으로 통신하도록 기동

  app 폴더 안의 mdl-verifier-1.*.jar 파일 "정확히 1개"만 실행합니다 (여러 개/0개면 에러).
  DB 종류는 현재 MariaDB로 고정입니다 (추후 다른 DBMS 지원 예정).

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

function Ask-Secret([string]$Prompt, [string]$Default = "") {
    # Read-Host -AsSecureString는 실제 콘솔에서만 동작하며, 표준입력이 파일/파이프로
    # 리다이렉트된 상황(자동화·비대화형 실행)에서는 무한 대기(hang)한다.
    # 이런 경우를 감지해 일반 Read-Host(파이프 입력도 정상 처리)로 자동 전환한다.
    $promptLabel = if ($Default -ne "") { "$Prompt [입력 없으면 기본값 사용]" } else { $Prompt }
    if ([Console]::IsInputRedirected) {
        $val = Read-Host "$promptLabel"
    } else {
        $secure = Read-Host "$promptLabel" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $val = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
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

function Port-InUse([string]$Port) {
    $ports = docker ps --format '{{.Ports}}' 2>$null
    return ($ports -match ":$Port->")
}

function New-RandomPassword {
    $pool = (48..57) + (65..90) + (97..122)
    return -join ($pool | Get-Random -Count 20 | ForEach-Object { [char]$_ })
}

# Get-Content/Set-Content -Encoding utf8는 Windows PowerShell 5.1에서 BOM이 없는 UTF-8
# 파일(이 프로젝트의 properties/json이 전부 그렇다)을 시스템 코드페이지로 잘못 해석해
# 한글 주석/문자열을 깨뜨린다(mojibake). .NET File 메서드는 BOM 없이도 UTF-8을 정확히
# 읽고, 쓸 때도 BOM을 붙이지 않아 원본 파일의 인코딩 방식을 그대로 유지한다.
function Read-Utf8File([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Write-Utf8File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "=============================================================="
Write-Host " verifier(mdl-verifier) + MariaDB 통합 테스트 배포"
Write-Host " (테스트/개발/데모 목적 전용 — 운영 환경 사용 금지)"
Write-Host "=============================================================="

# ---------- 0. 배포 환경 (개발/운영) ----------
Write-Host ""
Write-Host "이 배포가 어떤 환경을 대상으로 하는지 선택하세요:"
Write-Host "  1) 개발 (기본값)"
Write-Host "  2) 운영"
$EnvSel = Ask "번호 선택" "1"
switch ($EnvSel) {
    "1" { $DeployEnv = "개발" }
    "2" { $DeployEnv = "운영" }
    default { Write-Err2 "잘못된 선택입니다."; exit 1 }
}
if ($DeployEnv -eq "운영") {
    Write-Warn2 "이 스크립트는 데이터가 휘발성(볼륨 미사용)인 테스트/개발용 배포입니다."
    if (-not (Confirm-No "정말로 '운영' 환경 대상으로 진행할까요? (권장하지 않음)")) {
        Write-Err2 "사용자가 취소했습니다."
        exit 1
    }
}

# ---------- 1. 공용 네트워크 ----------
Write-Host ""
$NetworkName = Ask "MariaDB↔verifier 통신용 브리지 네트워크 이름" "verifier-net"
docker network inspect $NetworkName *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Info "네트워크 '$NetworkName'가 없어 새로 생성합니다 (bridge)."
    docker network create $NetworkName | Out-Null
    Write-Ok "네트워크 생성 완료 (driver=bridge — 컨테이너명 DNS 해석 + 외부 인터넷 접근 모두 기본 지원)"
} else {
    Write-Ok "기존 네트워크 '$NetworkName'를 사용합니다."
}

# ============================================================================
# PART A. MariaDB 배포
# ============================================================================
Write-Host ""
Write-Host "----------------------------- [A] MariaDB -----------------------------"

$envDefault = if ($env:REGISTRY_ADDR) { $env:REGISTRY_ADDR } else { "192.168.0.168:5000" }
$LocalRegistry = Ask "대상 레지스트리 주소 (호스트:포트)" $envDefault

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
$DbImage = "$LocalRegistry/$Namespace/mariadb:$Tag"

try {
    Invoke-WebRequest -Uri "http://$LocalRegistry/v2/" -UseBasicParsing -TimeoutSec 3 | Out-Null
} catch {
    Write-Err2 "로컬 레지스트리($LocalRegistry)가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.ps1 을 실행하세요."
    exit 1
}

Write-Info "레지스트리 이미지를 내려받는 중입니다: $DbImage"
docker pull $DbImage
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "이미지를 가져오지 못했습니다. 먼저 mariadb/base/build-and-push.ps1 로 '$Tag' 태그를 등록하세요."
    exit 1
}

Write-Host ""
$DbContainer = Ask "MariaDB 컨테이너 이름" "mariadb-verifier"
$existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $DbContainer }
if ($existing) {
    Write-Warn2 "이미 '$DbContainer' 이름의 컨테이너가 존재합니다."
    if (Confirm "기존 컨테이너를 삭제하고 새로 만들까요?") {
        docker rm -f $DbContainer | Out-Null
        Write-Ok "기존 컨테이너 삭제 완료"
    } else {
        Write-Err2 "컨테이너 이름 충돌로 중단합니다."
        exit 1
    }
}

Write-Host ""
$DbName = Ask "DB(스키마) 이름" "VC_VERIFIER"

Write-Host ""
Write-Warn2 "root 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
$DbRootPassword = Ask-Secret "root 초기 비밀번호 (비우면 랜덤 생성)" ""
$GeneratedPw = $false
if ([string]::IsNullOrEmpty($DbRootPassword)) {
    $DbRootPassword = New-RandomPassword
    $GeneratedPw = $true
    Write-Ok "root 비밀번호를 자동 생성했습니다 (아래 실행 요약/접속 정보에 표시됩니다)."
}

Write-Host ""
Write-Info "verifier용 애플리케이션 계정입니다. 기본값은 이번 통합 테스트에서 실제 검증된 klevra/theg3p2 입니다."
$AppUser = Ask "애플리케이션 계정 이름" "klevra"
$AppPassword = Ask-Secret "애플리케이션 계정 비밀번호" "theg3p2"

# ---------- DDL(스키마) 경로 입력 + 체크 ----------
Write-Host ""
$DdlDir = Ask "DDL(테이블 생성) SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
if ($DdlDir -and (Test-Path $DdlDir -PathType Container)) {
    $ddlFiles = Get-ChildItem -Path $DdlDir -Filter "*.sql" -File
    $detected = $null
    foreach ($f in $ddlFiles) {
        $m = Select-String -Path $f.FullName -Pattern 'CREATE\s+DATABASE\s+(IF\s+NOT\s+EXISTS\s+)?[`]?([A-Za-z0-9_]+)[`]?' -AllMatches | Select-Object -First 1
        if ($m) { $detected = $m.Matches[0].Groups[2].Value; break }
    }
    if ($detected) {
        Write-Info "DDL 파일에서 감지된 DB 이름: $detected"
        if ($detected -ne $DbName) {
            Write-Warn2 "입력한 DB 이름($DbName)과 DDL이 생성하는 DB 이름($detected)이 다릅니다."
            if (Confirm "DDL 기준($detected)으로 맞출까요? ('n'이면 입력한 이름 $DbName 유지)") {
                $DbName = $detected
                Write-Ok "DB 이름을 '$DbName'로 맞췄습니다."
            }
        } else {
            Write-Ok "DDL의 DB 이름과 일치합니다."
        }
    } else {
        Write-Warn2 "DDL 파일에서 CREATE DATABASE 구문을 찾지 못했습니다 (체크를 건너뜁니다)."
    }
}

# ---------- DML(초기데이터) 경로 입력 + partner code 반영 ----------
Write-Host ""
$DmlDir = Ask "초기데이터 INSERT용 DML SQL 파일들이 있는 경로 (비우면 건너뜀)" ""
Write-Host ""
$PartnerCode = Ask "VF_ORGANIZATION.PARTNER_CODE 값" "oacx"

$StagingDir = Join-Path $ScriptDir ".staging\$DbContainer\initdb"
$SetupMount = $false
if ($DdlDir -or $DmlDir) {
    $StagingParent = Join-Path $ScriptDir ".staging\$DbContainer"
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
            Write-Ok "DDL 파일 $($files.Count)개를 스테이징했습니다 (10_ 접두어)"
        } else {
            Write-Warn2 "DDL 경로를 찾을 수 없습니다: $DdlDir (건너뜁니다)"
        }
    }
    if ($DmlDir) {
        if (Test-Path $DmlDir -PathType Container) {
            $files = Get-ChildItem -Path $DmlDir -File
            $i = 1
            $patched = $false
            foreach ($f in $files) {
                $num = "{0:D3}" -f $i
                $dest = Join-Path $StagingDir "50_${num}_$($f.Name)"
                Copy-Item $f.FullName -Destination $dest
                # VF_ORGANIZATION INSERT의 PARTNER_CODE 값을 입력받은 값으로 치환
                $content = Read-Utf8File $dest
                if ($content -match '(?i)INSERT\s+INTO\s+VF_ORGANIZATION') {
                    $dmlPattern = '(INSERT\s+INTO\s+VF_ORGANIZATION\([^)]*\)\s*VALUES\s*\()' + "'" + '[^' + "'" + ']*' + "'"
                    $dmlReplacement = '${1}' + "'" + $PartnerCode + "'"
                    $newContent = [regex]::Replace($content, $dmlPattern, $dmlReplacement, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    Write-Utf8File $dest $newContent
                    $patched = $true
                }
                $i++
            }
            Write-Ok "DML 파일 $($files.Count)개를 스테이징했습니다 (50_ 접두어)"
            if ($patched) {
                Write-Ok "VF_ORGANIZATION.PARTNER_CODE 값을 '$PartnerCode'로 반영했습니다."
            } else {
                Write-Warn2 "VF_ORGANIZATION INSERT 구문을 찾지 못해 PARTNER_CODE를 반영하지 못했습니다."
            }
        } else {
            Write-Warn2 "DML 경로를 찾을 수 없습니다: $DmlDir (건너뜁니다)"
        }
    }
    $SetupMount = $true
    Write-Warn2 "MariaDB의 /docker-entrypoint-initdb.d/ 자동 실행은 최초 기동 시에만 동작합니다 (이 프로젝트는 항상 휘발성이라 매번 최초 기동입니다)."
}

Write-Host ""
$DbPort = Ask "MariaDB 포트" "3306"
if (Port-InUse $DbPort) {
    Write-Warn2 "포트 $DbPort 은(는) 이미 사용 중인 것으로 보입니다."
}

# ---------- MariaDB 실행 ----------
Write-Host ""
Write-Host "=================== [A] MariaDB 실행 요약 ==================="
Write-Host " 이미지        : $DbImage"
Write-Host " 컨테이너 이름 : $DbContainer"
Write-Host " DB 이름       : $DbName"
Write-Host " 포트          : $DbPort"
Write-Host " 네트워크      : $NetworkName"
Write-Host " 앱 계정       : $AppUser"
Write-Host " DDL 경로      : $(if ($DdlDir) { $DdlDir } else { '(없음)' })"
Write-Host " DML 경로      : $(if ($DmlDir) { $DmlDir } else { '(없음)' }) (PARTNER_CODE=$PartnerCode)"
if ($GeneratedPw) { Write-Host " 생성된 root 비밀번호 : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==============================================================="
if (-not (Confirm "위 설정으로 MariaDB 컨테이너를 생성할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

$DbRunArgs = @("-d", "--name", $DbContainer, "--network", $NetworkName, "-p", "${DbPort}:3306")
if ($SetupMount) { $DbRunArgs += @("-v", "${StagingDir}:/docker-entrypoint-initdb.d:ro") }
$DbRunArgs += @(
    '--health-cmd=healthcheck.sh --connect --innodb_initialized || exit 1',
    "--health-interval=5s", "--health-timeout=5s", "--health-start-period=30s", "--health-retries=10"
)
$DbRunArgs += @(
    "-e", "MARIADB_ROOT_PASSWORD=$DbRootPassword",
    "-e", "MARIADB_DATABASE=$DbName",
    "-e", "MARIADB_USER=$AppUser",
    "-e", "MARIADB_PASSWORD=$AppPassword",
    "-e", "TZ=Asia/Seoul"
)

Write-Info "MariaDB 컨테이너를 실행합니다: $DbContainer"
docker run @DbRunArgs $DbImage | Out-Null

Write-Info "MariaDB 초기화를 기다리는 중입니다..."
$Elapsed = 0; $Interval = 5; $Timeout = 300
while ($true) {
    $Status = (docker inspect -f '{{.State.Health.Status}}' $DbContainer 2>$null)
    if ($Status -eq "healthy") {
        Write-Ok "MariaDB가 정상 기동되었습니다."
        break
    }
    $running = docker ps -q -f "name=^$DbContainer`$"
    if (-not $running) {
        Write-Err2 "MariaDB 컨테이너가 중단되었습니다. 로그:"
        docker logs $DbContainer 2>&1 | Select-Object -Last 60
        exit 1
    }
    if ($Elapsed -ge $Timeout) {
        Write-Warn2 "제한 시간 내에 healthy 상태가 되지 않았습니다. 'docker logs -f $DbContainer' 로 확인하세요."
        break
    }
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval
    Write-Host "." -NoNewline
}
Write-Host ""

# ============================================================================
# PART B. verifier 배포
# ============================================================================
Write-Host ""
Write-Host "----------------------------- [B] verifier -----------------------------"

$VerifierRoot = Ask "verifier 설정 루트 경로 (Dockerfile, app/, config/ 가 있는 위치)" "D:\03. Docker\sandbox\verifier"
if (-not (Test-Path (Join-Path $VerifierRoot "Dockerfile"))) {
    Write-Err2 "Dockerfile을 찾을 수 없습니다: $(Join-Path $VerifierRoot 'Dockerfile')"
    exit 1
}
if (-not (Test-Path (Join-Path $VerifierRoot "app") -PathType Container) -or -not (Test-Path (Join-Path $VerifierRoot "config") -PathType Container)) {
    Write-Err2 "app/ 또는 config/ 폴더를 찾을 수 없습니다: $VerifierRoot"
    exit 1
}

# app 폴더 안 mdl-verifier-1.*.jar 파일이 정확히 1개인지 확인
$jarFiles = Get-ChildItem -Path (Join-Path $VerifierRoot "app") -Filter "mdl-verifier-1.*.jar" -File -ErrorAction SilentlyContinue
if (-not $jarFiles -or $jarFiles.Count -eq 0) {
    Write-Err2 "$(Join-Path $VerifierRoot 'app') 안에 mdl-verifier-1.*.jar 파일이 없습니다."
    exit 1
} elseif ($jarFiles.Count -gt 1) {
    Write-Err2 "$(Join-Path $VerifierRoot 'app') 안에 mdl-verifier-1.*.jar 파일이 $($jarFiles.Count)개 있습니다. 정확히 1개만 남겨주세요."
    exit 1
}
$JarName = $jarFiles[0].Name
Write-Ok "실행 대상 JAR 확인: $JarName"

Write-Host ""
$VfContainer = Ask "verifier 컨테이너 이름" "verifier"
$existingVf = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $VfContainer }
if ($existingVf) {
    Write-Warn2 "이미 '$VfContainer' 이름의 컨테이너가 존재합니다."
    if (Confirm "기존 컨테이너를 삭제하고 새로 만들까요?") {
        docker rm -f $VfContainer | Out-Null
        Write-Ok "기존 컨테이너 삭제 완료"
    } else {
        Write-Err2 "컨테이너 이름 충돌로 중단합니다."
        exit 1
    }
}

# application-sp.properties의 api-server-domain에 박힌 포트를 기본값으로 시도 추출
$DetectedAppPort = $null
$SpProp = Join-Path $VerifierRoot "config\config\application-sp.properties"
if (Test-Path $SpProp) {
    $m = Select-String -Path $SpProp -Pattern 'mdl\.sp\.api-server-domain=.*:([0-9]+)' | Select-Object -First 1
    if ($m) { $DetectedAppPort = $m.Matches[0].Groups[1].Value }
}
Write-Host ""
$VfInternalPort = Ask "컨테이너 내부 애플리케이션 포트" $(if ($DetectedAppPort) { $DetectedAppPort } else { "48085" })
$VfHostPort = Ask "호스트에 노출할 포트" "48085"
if (Port-InUse $VfHostPort) {
    Write-Warn2 "포트 $VfHostPort 은(는) 이미 사용 중인 것으로 보입니다."
}

Write-Host ""
Write-Host "=================== [B] verifier 실행 요약 ==================="
Write-Host " 설정 루트     : $VerifierRoot"
Write-Host " 실행 JAR      : $JarName"
Write-Host " 컨테이너 이름 : $VfContainer"
Write-Host " 네트워크      : $NetworkName (MariaDB: $DbContainer)"
Write-Host " 포트          : $VfHostPort -> $VfInternalPort"
Write-Host " 배포 환경     : $DeployEnv"
Write-Host "================================================================"
if (-not (Confirm "위 설정으로 verifier 이미지를 빌드하고 컨테이너를 생성할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

Write-Info "verifier 런타임 이미지를 빌드합니다..."
docker build -t verifier-jdk8:local -f (Join-Path $VerifierRoot "Dockerfile") $VerifierRoot
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "이미지 빌드에 실패했습니다."
    exit 1
}
Write-Ok "이미지 빌드 완료: verifier-jdk8:local"

# 로그는 각 서비스 폴더 밑이 아니라, VerifierRoot와 같은 부모(sandbox) 아래 공용 log/ 트리에 모은다.
$LogRoot = Join-Path (Split-Path -Parent $VerifierRoot) "log\verifier"
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

# application-datasource.properties는 DB 컨테이너 이름/DB명/계정을 하드코딩하고 있어
# 실행할 때마다 위에서 입력받은 실제 값으로 맞춰야 한다.
# 원본(VerifierRoot\config\config)은 건드리지 않고, 스테이징 사본만 패치해서 마운트한다.
$VfConfigStaging = Join-Path $ScriptDir ".staging\$VfContainer\config"
if (Test-Path $VfConfigStaging) { Remove-Item -Recurse -Force $VfConfigStaging }
New-Item -ItemType Directory -Force -Path $VfConfigStaging | Out-Null
Copy-Item -Path (Join-Path $VerifierRoot "config\config\*") -Destination $VfConfigStaging -Recurse -Force

$DsProp = Join-Path $VfConfigStaging "application-datasource.properties"
if (Test-Path $DsProp) {
    $dsContent = Read-Utf8File $DsProp
    $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.url=jdbc:mariadb://)[^:/]+(:[0-9]+/)[^\s]*', ('${1}' + $DbContainer + '${2}' + $DbName))
    $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.hikari\.username=).*', ('${1}' + $AppUser))
    $dsContent = [regex]::Replace($dsContent, '(spring\.datasource\.hikari\.password=).*', ('${1}' + $AppPassword))
    Write-Utf8File $DsProp $dsContent
    Write-Ok "application-datasource.properties에 실제 MariaDB 접속정보(host=$DbContainer, db=$DbName, user=$AppUser)를 반영했습니다."
} else {
    Write-Warn2 "application-datasource.properties를 찾지 못해 DB 접속정보를 자동 반영하지 못했습니다."
}

$VfRunArgs = @("-d", "--name", $VfContainer, "--network", $NetworkName, "-p", "${VfHostPort}:${VfInternalPort}")
$VfRunArgs += @(
    "-v", "$(Join-Path $VerifierRoot 'app'):/app:ro",
    "-v", "$(Join-Path $VerifierRoot 'app\jdbc'):/jdbc:ro",
    "-v", "${VfConfigStaging}:/config",
    "-v", "$(Join-Path $VerifierRoot 'config\template'):/config/template:ro",
    "-v", "$(Join-Path $VerifierRoot 'config\license'):/config/license:ro",
    "-v", "$(Join-Path $VerifierRoot 'config\sp'):/config/sp:ro",
    "-v", "$(Join-Path $VerifierRoot 'config\fonts'):/config/fonts:ro",
    "-v", "${LogRoot}:/logs"
)
$VfRunArgs += @(
    "-e", "SPRING_CONFIG_ADDITIONAL_LOCATION=file:/config/",
    "-e", "LOGGING_FILE_PATH=/logs",
    "-e", "LOADER_PATH=/jdbc"
)

Write-Info "verifier 컨테이너를 실행합니다: $VfContainer"
docker run @VfRunArgs verifier-jdk8:local | Out-Null

Write-Info "verifier 기동을 기다리는 중입니다 (Spring Boot 기동에 30~40초 정도 걸립니다)..."
$Elapsed = 0; $Interval = 5; $Timeout = 180; $Booted = $false
while ($Elapsed -lt $Timeout) {
    $logs = docker logs $VfContainer 2>&1
    if ($logs -match "Started MdlApiApplication") {
        $Booted = $true
        break
    }
    $running = docker ps -q -f "name=^$VfContainer`$"
    if (-not $running) {
        Write-Err2 "verifier 컨테이너가 중단되었습니다. 로그:"
        docker logs $VfContainer 2>&1 | Select-Object -Last 60
        exit 1
    }
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval
    Write-Host "." -NoNewline
}
Write-Host ""
if ($Booted) {
    $bootLine = (docker logs $VfContainer 2>&1 | Select-String "Started MdlApiApplication" | Select-Object -Last 1)
    Write-Ok "$bootLine"
} else {
    Write-Warn2 "제한 시간 내에 기동 완료 로그를 확인하지 못했습니다. 'docker logs -f $VfContainer' 로 확인하세요."
}

$HttpCode = "000"
try {
    $resp = Invoke-WebRequest -Uri "http://localhost:$VfHostPort/" -UseBasicParsing -TimeoutSec 5
    $HttpCode = "$($resp.StatusCode)"
} catch {
    if ($_.Exception.Response) {
        $HttpCode = "$([int]$_.Exception.Response.StatusCode)"
    }
}
if ($HttpCode -in @("200", "302", "401", "403")) {
    Write-Ok "HTTP 응답 확인: $HttpCode"
} else {
    Write-Warn2 "HTTP 응답 확인 실패 또는 예상 외 코드: $HttpCode"
}

# ---------- 최종 접속 정보 ----------
Write-Host ""
Write-Host "======================= 접속 정보 ======================="
Write-Host " 배포 환경     : $DeployEnv"
Write-Host " -------------------------- [MariaDB] --------------------------"
Write-Host " Host          : localhost"
Write-Host " Port          : $DbPort"
Write-Host " Database      : $DbName"
Write-Host " App 계정      : $AppUser"
Write-Host " JDBC URL      : jdbc:mariadb://localhost:$DbPort/$DbName"
Write-Host " (컨테이너 간 통신용 Host: $DbContainer, Network: $NetworkName)"
Write-Host " -------------------------- [verifier] --------------------------"
Write-Host " URL           : http://localhost:$VfHostPort/"
Write-Host " PARTNER_CODE  : $PartnerCode"
if ($GeneratedPw) { Write-Host " root 비밀번호(MariaDB) : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==========================================================="
Write-Warn2 "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
$DbRootPassword = $null
$AppPassword = $null
