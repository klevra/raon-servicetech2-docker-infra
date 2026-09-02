<#
.SYNOPSIS
  OmnioneCX v1 통합 배포 스크립트 (PowerShell) — DB(공용 1개) + verifier + oacx

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  전제조건 : oracle/registry/setup-registry.ps1 로 레지스트리가 떠있어야 하고,
             mariadb/base, jdk8/base, tomcat/base 의 build-and-push.ps1(.sh) 로
             이미지가 레지스트리에 등록되어 있어야 함.

  실행 순서 (요청하신 7단계 + 자동화 보강):
    1) 설정값 일괄 수령 (DB/연결정보/앱 경로/운영·개발) + 공용 네트워크 생성
    2) DB 컨테이너 생성
    3) DB에 DDL/DML 적용 (verifier + oacx 스키마를 "하나의 DB"에 함께 적재.
       실제 운영 구성과 동일 -- verifier/oacx 모두 기본 DB명이 VC_VERIFIER로 통일되어 있음)
    4) verifier 설정값 세팅 (config는 sandbox 원본에 직접 패치, app은 원본 직접 마운트)
    5) verifier 기동 (+ 정상 기동까지 대기)
    6) oacx 설정값 세팅 (app은 스테이징, config는 sandbox 원본에 직접 패치 +
       provider.json 6종의 base/partnerCode/publicKey/vc.curveType 자동 반영)
       -- config는 컨테이너와 별개로 원본을 직접 마운트하므로, 값을 고친 뒤
          컨테이너만 재시작해도(재배포 없이) 즉시 반영됨
    7) oacx 기동 (+ 정상 기동까지 대기)

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

# Get-Content/Set-Content -Encoding utf8는 Windows PowerShell 5.1에서 BOM이 없는 UTF-8
# 파일(이 저장소의 SQL/properties/json이 전부 그렇다)을 시스템 코드페이지로 잘못 해석해
# 한글 주석/문자열을 깨뜨린다(mojibake). .NET File 메서드는 BOM 없이도 UTF-8을 정확히
# 읽고, 쓸 때도 BOM을 붙이지 않아 원본 파일의 인코딩 방식을 그대로 유지한다.
function Read-Utf8File([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Write-Utf8File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "=============================================================="
Write-Host " OmnioneCX v1 통합 배포 (DB 1개 + verifier + oacx)"
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
    Write-Warn2 "이 스크립트는 데이터가 휘발성(볼륨 미사용)인 테스트/개발용 배포입니다."
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
    $VerifierRoot = Ask "verifier 설정 루트 경로 (app/, config/ 가 있는 위치)" "D:\03. Docker\sandbox\verifier"
}

Write-Host ""
Write-Host "-------- DB --------"
Write-Host "DB 종류를 선택하세요 (현재는 MariaDB만 지원):"
Write-Host "  1) MariaDB"
$DbSel = Ask "번호 선택" "1"
if ($DbSel -ne "1") { Write-Err2 "현재는 MariaDB만 지원합니다."; exit 1 }
$DbKind = "mariadb"

Write-Host "배포할 MariaDB 버전(레지스트리 태그)을 선택하세요:"
Write-Host "  1) latest"
Write-Host "  2) 11.4   (LTS)"
Write-Host "  3) 10.11  (구버전 LTS, 레거시 호환용)"
$VerSel = Ask "번호 선택" "1"
switch ($VerSel) {
    "1" { $DbTag = "latest" }
    "2" { $DbTag = "11.4" }
    "3" { $DbTag = "10.11" }
    default { Write-Err2 "잘못된 선택입니다."; exit 1 }
}
$DbImage = "$LocalRegistry/$Namespace/${DbKind}:$DbTag"

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
Write-Warn2 "root 비밀번호는 화면에 표시되지 않으며, 어떤 파일에도 저장하지 않습니다."
$DbRootPassword = Ask-Secret "root 초기 비밀번호 (비우면 랜덤 생성)" ""
$GeneratedPw = $false
if ([string]::IsNullOrEmpty($DbRootPassword)) {
    $DbRootPassword = New-RandomPassword
    $GeneratedPw = $true
}

Write-Host ""
Write-Host "-------- DDL/DML (verifier + oacx 통합 경로) --------"
$defaultDdlDir = Join-Path $ScriptDir "ddl"
if (Test-Path $defaultDdlDir -PathType Container) {
    $DdlDir = $defaultDdlDir
    Write-Ok "ddl 폴더를 찾았습니다: $DdlDir (경로 입력 생략)"
} else {
    $DdlDir = Ask "DDL 경로 (비우면 건너뜀)" ""
}
$defaultDmlDir = Join-Path $ScriptDir "dml"
if (Test-Path $defaultDmlDir -PathType Container) {
    $DmlDir = $defaultDmlDir
    Write-Ok "dml 폴더를 찾았습니다: $DmlDir (경로 입력 생략)"
} else {
    $DmlDir = Ask "DML 경로 (비우면 건너뜀)" ""
}

Write-Host ""
$PartnerCode = Ask "VF_ORGANIZATION.PARTNER_CODE / provider.json partnerCode 공통값" "oacx"

Write-Host ""
Write-Host "-------- verifier --------"
Write-Info "verifier 설정 루트: $VerifierRoot (앞에서 이미 입력받음)"
$VfContainer = Ask "verifier 컨테이너 이름" "verifier"
$VfPort = Ask "verifier 포트" "48085"
$VfInternalPort = $VfPort
$VfHostPort = $VfPort

Write-Host ""
Write-Host "-------- oacx --------"
$defaultOacxRoot = Join-Path $ScriptDir "oacx"
if (Test-Path $defaultOacxRoot -PathType Container) {
    $OacxRoot = $defaultOacxRoot
    Write-Ok "oacx 폴더를 찾았습니다: $OacxRoot (경로 입력 생략)"
} else {
    $OacxRoot = Ask "OACX 설정 루트 경로 (app/, config/ 가 있는 위치)" "D:\03. Docker\sandbox\oacx"
}
$OacxContainer = Ask "OACX 컨테이너 이름" "oacx"
$TomcatImage = Ask "Tomcat 이미지 (레지스트리)" "$LocalRegistry/$Namespace/tomcat9-jdk8:9-jdk8"
$ContextPath = Ask "OACX Context path (URL: http://localhost:<포트>/<이 값>/)" "oacx"
$OacxHostPort = Ask "OACX 포트" "8080"

Write-Host ""
$Jdk8ImageDefault = "$LocalRegistry/$Namespace/jdk8:latest"
$Jdk8Image = Ask "verifier 실행용 JDK8 이미지 (레지스트리)" $Jdk8ImageDefault

Write-Host ""
Write-Host "======================= 실행 요약 ======================="
Write-Host " 배포 환경     : $DeployEnv (oper.mode/OperSort=$OperSort)"
$updateLabel = if ($UpdateDbConfig) { "예 (DB 접속정보를 아래 값으로 덮어씀)" } else { "아니오 (config 원본 값 그대로 사용, DB를 그 값에 맞춰 생성)" }
Write-Host " config 업데이트 : $updateLabel"
Write-Host " 네트워크      : $NetworkName"
Write-Host " DB            : $DbImage / $DbContainer / db=$DbName / port=$DbPort"
Write-Host " 공용 앱 계정  : $AppUser"
Write-Host " PARTNER_CODE  : $PartnerCode"
Write-Host " verifier      : $VfContainer (포트 $VfPort), root=$VerifierRoot"
Write-Host " oacx          : $OacxContainer (포트 $OacxHostPort, /$ContextPath), root=$OacxRoot"
if ($GeneratedPw) { Write-Host " 생성된 root 비밀번호 : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==========================================================="
if (-not (Confirm "위 설정으로 전체 스택을 배포할까요?")) {
    Write-Err2 "사용자가 취소했습니다."
    exit 1
}

# 네트워크는 별도로 미리 만들지 않는다 -- docker-compose.yml의 networks: 블록이
# name($NetworkName)과 driver(bridge)를 명시적으로 선언하고 있어서, `docker compose up`
# 실행 시 compose가 알아서 생성/재사용한다.

# 기존에 동일한 이름으로 떠있는 컨테이너가 있으면(이 스크립트의 이전 실행이든, compose가 아닌
# 수동 실행이든) compose가 새로 만들 때 이름 충돌이 날 수 있으므로 미리 정리한다.
foreach ($c in @($DbContainer, $VfContainer, $OacxContainer)) {
    $existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $c }
    if ($existing) {
        Write-Warn2 "이미 '$c' 컨테이너가 존재합니다. 삭제하고 새로 만듭니다."
        docker rm -f $c | Out-Null
    }
}

# ============================================================================
# 2~3. DB 준비 + DDL/DML 스테이징
# ============================================================================
Write-Host ""
Write-Host "########## 2~3단계: DB 준비 + DDL/DML 스테이징 ##########"

Write-Info "레지스트리 이미지를 내려받는 중입니다: $DbImage"
docker pull $DbImage
if ($LASTEXITCODE -ne 0) { Write-Err2 "이미지를 가져오지 못했습니다. 먼저 mariadb/base/build-and-push.ps1 로 '$DbTag' 태그를 등록하세요."; exit 1 }

# DDL/DML 스테이징: verifier + oacx 것을 하나의 initdb.d 디렉터리에 순서대로 모은다.
$StagingDir = Join-Path $ScriptDir ".staging\$DbContainer\initdb"
$StagingParent = Join-Path $ScriptDir ".staging\$DbContainer"
if (Test-Path $StagingParent) { Remove-Item -Recurse -Force $StagingParent }
New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

function Stage-Ddl([string]$Dir, [string]$Prefix) {
    if (-not $Dir) { return }
    if (-not (Test-Path $Dir -PathType Container)) { Write-Warn2 "DDL 경로를 찾을 수 없습니다: $Dir (건너뜁니다)"; return }
    $files = Get-ChildItem -Path $Dir -File
    $i = 1
    foreach ($f in $files) {
        $num = "{0:D3}" -f $i
        $dest = Join-Path $StagingDir "${Prefix}_${num}_$($f.Name)"
        Copy-Item $f.FullName -Destination $dest
        # CREATE DATABASE / USE 문에 박힌 DB명을 현재 선택한 DbName으로 정규화
        $content = Read-Utf8File $dest
        $content = [regex]::Replace($content, '(CREATE\s+DATABASE\s+IF\s+NOT\s+EXISTS\s+`)[^`]+(`)', "`${1}${DbName}`${2}", 'IgnoreCase')
        $content = [regex]::Replace($content, '(?m)(^USE\s+`)[^`]+(`;)', "`${1}${DbName}`${2}", 'IgnoreCase')
        Write-Utf8File $dest $content
        $i++
    }
    Write-Ok "DDL 스테이징: $Dir -> ${Prefix}_* ($($files.Count)개)"
}

function Stage-Dml([string]$Dir, [string]$Prefix) {
    if (-not $Dir) { return }
    if (-not (Test-Path $Dir -PathType Container)) { Write-Warn2 "DML 경로를 찾을 수 없습니다: $Dir (건너뜁니다)"; return }
    $files = Get-ChildItem -Path $Dir -File
    $i = 1
    foreach ($f in $files) {
        $num = "{0:D3}" -f $i
        $dest = Join-Path $StagingDir "${Prefix}_${num}_$($f.Name)"
        Copy-Item $f.FullName -Destination $dest
        $content = Read-Utf8File $dest
        # 파일 내용으로 verifier용/oacx용을 판별한다(폴더가 합쳐져 있어도 둘 다 정상 처리됨).
        if ($content -match '(?i)INSERT\s+INTO\s+VF_ORGANIZATION') {
            $pattern = "(INSERT\s+INTO\s+VF_ORGANIZATION\([^)]*\)\s*VALUES\s*\()'[^']*'"
            $content = [regex]::Replace($content, $pattern, ('${1}' + "'" + $PartnerCode + "'"), 'IgnoreCase')
            Write-Utf8File $dest $content
        }
        if ($content -match '(?i)INSERT\s+INTO\s+OACX_PROVIDER') {
            $content = [regex]::Replace($content, "('ent'\s*,\s*')(prod|dev)(')", ('${1}' + $OperSort + '${3}'), 'IgnoreCase')
            Write-Utf8File $dest $content
        }
        $i++
    }
    Write-Ok "DML 스테이징: $Dir -> ${Prefix}_* ($($files.Count)개)"
}

Stage-Ddl $DdlDir "10"
Stage-Dml $DmlDir "50"
$DbInitdbDir = $StagingDir
Write-Ok "DB 준비 완료 (실제 기동은 compose가 verifier/oacx와 함께 한 번에 처리합니다)"

# ============================================================================
# 4~5. verifier 설정 스테이징
# ============================================================================
Write-Host ""
Write-Host "########## 4~5단계: verifier 설정 스테이징 ##########"

if (-not (Test-Path (Join-Path $VerifierRoot "Dockerfile"))) {
    Write-Warn2 "Dockerfile을 찾을 수 없습니다: $(Join-Path $VerifierRoot 'Dockerfile') (레지스트리 이미지만 사용합니다)"
}
$jarFiles = Get-ChildItem -Path (Join-Path $VerifierRoot "app") -Filter "mdl-verifier-1.*.jar" -File -ErrorAction SilentlyContinue
if (-not $jarFiles -or $jarFiles.Count -ne 1) {
    Write-Err2 "$(Join-Path $VerifierRoot 'app') 안에 mdl-verifier-1.*.jar 파일이 정확히 1개 있어야 합니다 (현재 $($jarFiles.Count)개)."
    exit 1
}
$JarName = $jarFiles[0].Name
Write-Ok "실행 대상 JAR 확인: $JarName"

Write-Info "레지스트리에서 verifier 실행 이미지를 내려받는 중입니다: $Jdk8Image"
docker pull $Jdk8Image
if ($LASTEXITCODE -ne 0) { Write-Err2 "이미지를 가져오지 못했습니다. 먼저 jdk8/base/build-and-push.ps1 를 실행하세요."; exit 1 }

# config는 더 이상 staging으로 복사하지 않고 sandbox 원본을 그대로 마운트한다.
# (컨테이너를 재시작만 해도 config 수정사항이 즉시 반영되도록 하기 위함 -- WORKLOG 참고)
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

# 로그는 각 서비스 폴더 밑이 아니라, VerifierRoot와 같은 부모(sandbox) 아래 공용 log/ 트리에 모은다.
$VfLogRoot = Join-Path (Split-Path -Parent $VerifierRoot) "log\verifier"
New-Item -ItemType Directory -Force -Path $VfLogRoot | Out-Null

Write-Ok "verifier 준비 완료 (실제 기동은 compose가 한 번에 처리합니다)"

# ============================================================================
# 6~7. oacx 설정 스테이징
# ============================================================================
Write-Host ""
Write-Host "########## 6~7단계: oacx 설정 스테이징 ##########"

if (-not (Test-Path (Join-Path $OacxRoot "app") -PathType Container) -or -not (Test-Path (Join-Path $OacxRoot "config") -PathType Container)) {
    Write-Err2 "app/ 또는 config/ 폴더를 찾을 수 없습니다: $OacxRoot"
    exit 1
}

Write-Info "레지스트리에서 Tomcat 이미지를 내려받는 중입니다: $TomcatImage"
docker pull $TomcatImage
if ($LASTEXITCODE -ne 0) { Write-Err2 "이미지를 가져오지 못했습니다. 먼저 tomcat/base/build-and-push.ps1 를 실행하세요."; exit 1 }

# ---------- app/ 스테이징 + web.xml 패치 ----------
$OacxAppStaging = Join-Path $ScriptDir ".staging\$OacxContainer\app"
if (Test-Path $OacxAppStaging) { Remove-Item -Recurse -Force $OacxAppStaging }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OacxAppStaging) | Out-Null
Copy-Item -Path (Join-Path $OacxRoot "app") -Destination $OacxAppStaging -Recurse

$WebXml = Join-Path $OacxAppStaging "WEB-INF\web.xml"
$webXmlContent = Read-Utf8File $WebXml
$webXmlContent = [regex]::Replace($webXmlContent, '(<param-value>)\./WEB-INF/config/server\.properties(</param-value>)', '${1}/config/server.properties${2}')
Write-Utf8File $WebXml $webXmlContent
Write-Ok "oacx web.xml의 config.file을 절대경로로 패치했습니다."

# ---------- config: sandbox 원본을 직접 사용 (더 이상 staging 복사 안 함) ----------
$OacxConfigDir = Join-Path $OacxRoot "config"

$SpProp = Join-Path $OacxConfigDir "server.properties"
$spContent = Read-Utf8File $SpProp
# mybatis/log 경로와 oper.mode는 이 프로젝트의 마운트 컨벤션/환경 선택에 필요한 구조적 값이라
# config 업데이트 여부와 무관하게 항상 반영한다.
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

# ---------- provider.json 6종: base/partnerCode/publicKey/vc.curveType 자동 반영 ----------
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
    $pc = [regex]::Replace($pc, '"base": "[^"]*"', ('"base": "http://' + $VfContainer + ':' + $VfInternalPort + '"'))
    $pc = [regex]::Replace($pc, '"partnerCode": "[^"]*"', ('"partnerCode": "' + $PartnerCode + '"'))
    if ($DidPublicKey) { $pc = [regex]::Replace($pc, '"publicKey" ?: ?"[^"]*"', ('"publicKey" : "' + $DidPublicKey + '"')) }
    if ($DidCurveType) { $pc = [regex]::Replace($pc, '"vc\.curveType":\s*"[^"]*"', ('"vc.curveType":"' + $DidCurveType + '"')) }
    # 알려진 오타 보정 (web2appsspay -> web2app). sspay 전용 provider가 아닌 한 이 값이 맞다.
    $pc = $pc -replace '/api/v2/transaction/web2appsspay', '/api/v2/transaction/web2app'
    Write-Utf8File $target $pc
}
Write-Ok "provider.json 6종에 base/partnerCode/publicKey/vc.curveType을 반영했습니다."
Write-Warn2 "serviceCode는 인증사업자별 고유값이라 자동화 대상에서 제외했습니다 -- 비어있는 파일은 직접 채워야 합니다."

# ---------- Context XML 생성 ----------
$ContextXml = Join-Path $ScriptDir ".staging\$OacxContainer\$ContextPath.xml"
@"
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="/app" path="/$ContextPath" reloadable="false" />
"@ | Set-Content -Path $ContextXml -Encoding utf8

# 로그는 각 서비스 폴더 밑이 아니라, OacxRoot와 같은 부모(sandbox) 아래 공용 log/ 트리에 모은다.
$OxLogRoot = Join-Path (Split-Path -Parent $OacxRoot) "log\oacx"
New-Item -ItemType Directory -Force -Path (Join-Path $OxLogRoot "tomcat") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OxLogRoot "app") | Out-Null

Write-Ok "oacx 준비 완료"

# ============================================================================
# compose로 3개 서비스를 한 번에 기동 (db -> verifier -> oacx 순서는
# docker-compose.yml의 depends_on: condition: service_healthy 로 강제됨)
# ============================================================================
Write-Host ""
Write-Host "########## compose 기동 ##########"

# 비밀번호는 .env 파일(디스크)에 쓰지 않는다 -- compose 변수 치환은 프로세스 환경변수를
# .env보다 우선 사용하므로, 민감값만 $env:로 잠깐 설정했다가 compose 호출 직후 제거한다.
$EnvFile = Join-Path $ScriptDir ".staging\omnionecx.env"
@"
DB_IMAGE=$DbImage
DB_CONTAINER=$DbContainer
DB_NAME=$DbName
DB_PORT=$DbPort
DB_INITDB_DIR=$DbInitdbDir
APP_USER=$AppUser
JDK8_IMAGE=$Jdk8Image
VF_CONTAINER=$VfContainer
VF_PORT=$VfHostPort
VERIFIER_ROOT=$VerifierRoot
VF_CONFIG_DIR=$VfConfigDir
VF_LOG_ROOT=$VfLogRoot
TOMCAT_IMAGE=$TomcatImage
OACX_CONTAINER=$OacxContainer
OACX_HOST_PORT=$OacxHostPort
OACX_APP_STAGING=$OacxAppStaging
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
# 값 자체는 마지막 접속정보 요약에 화면 출력용으로 필요하니 $DbRootPassword/$AppPassword
# 변수는 유지하되, 이 스크립트가 띄우는 자식 프로세스에 더 이상 전파되지 않도록 프로세스
# 환경변수에서만 제거한다.
Remove-Item Env:\DB_ROOT_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:\APP_PASSWORD -ErrorAction SilentlyContinue
if ($ComposeExit -ne 0) {
    Write-Err2 "docker compose up 실패 (종료 코드 $ComposeExit). 'docker compose -f docker-compose.yml -p omnionecx logs'로 확인하세요."
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
    $code = "000"
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        $code = "$($resp.StatusCode)"
    } catch {
        if ($_.Exception.Response) { $code = "$([int]$_.Exception.Response.StatusCode)" }
    }
    if ($code -eq "000") {
        Start-Sleep -Seconds 3
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            $code = "$($resp.StatusCode)"
        } catch {
            if ($_.Exception.Response) { $code = "$([int]$_.Exception.Response.StatusCode)" }
        }
    }
    return $code
}
$VfHttp = Test-Http "http://localhost:$VfHostPort/"
$OacxHttp = Test-Http "http://localhost:$OacxHostPort/$ContextPath/"

# ---------- 최종 접속 정보 ----------
Write-Host ""
Write-Host "======================= 접속 정보 ======================="
Write-Host " 배포 환경     : $DeployEnv (oper.mode/OperSort=$OperSort)"
Write-Host " -------------------------- [DB] --------------------------"
Write-Host " Host          : localhost / Port: $DbPort / DB: $DbName / User: $AppUser"
Write-Host " JDBC URL      : jdbc:mariadb://localhost:$DbPort/$DbName"
Write-Host " (컨테이너 간 통신용 Host: $DbContainer, Network: $NetworkName)"
Write-Host " -------------------------- [verifier] --------------------------"
Write-Host " URL           : http://localhost:$VfHostPort/  (HTTP $VfHttp)"
Write-Host " PARTNER_CODE  : $PartnerCode"
Write-Host " -------------------------- [oacx] --------------------------"
Write-Host " URL           : http://localhost:$OacxHostPort/$ContextPath/  (HTTP $OacxHttp)"
if ($GeneratedPw) { Write-Host " root 비밀번호(DB) : $DbRootPassword  ⚠ 다시 표시되지 않으니 지금 저장하세요" }
Write-Host "==========================================================="
Write-Warn2 "비밀번호/토큰은 어떤 파일에도 저장하지 않았습니다."
$DbRootPassword = $null
$AppPassword = $null
