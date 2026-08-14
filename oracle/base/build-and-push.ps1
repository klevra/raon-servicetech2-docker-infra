<#
.SYNOPSIS
  Oracle 베이스 이미지 빌드 + servicetech2 레지스트리 push 스크립트 (PowerShell)

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+

  라이선스 주의사항
    - 19c Enterprise Edition : Oracle 공식 OTN 라이선스(개발/테스트/데모 목적 무료).
      Oracle 계정 + container-registry.oracle.com 라이선스 동의 + Auth Token 필요.
    - 21c/18c Express Edition(XE) : 완전 무료, 커뮤니티(gvenzl) 빌드 이미지, 계정 불필요.
    - 운영(production) 환경 사용 금지. 테스트/개발/데모 전용.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$RegistryHost = "container-registry.oracle.com"
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

Write-Host "=============================================================="
Write-Host " Oracle 베이스 이미지 빌드 + servicetech2 레지스트리 등록"
Write-Host "=============================================================="

# 개발 PC: localhost:5000 (이 PC에서 만든 로컬 레지스트리)
# 사무실/실서버: servicetech2-registry:5000 (hosts 파일 등록 필요, registry-server/linux-registry-setup.md 참고)
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
Write-Host "Oracle 버전을 선택하세요:"
Write-Host "  1) 19c Enterprise Edition  (공식 레지스트리, Oracle 계정 필요)"
Write-Host "  2) 21c Express Edition XE  (커뮤니티 이미지, 계정 불필요)"
Write-Host "  3) 18c Express Edition XE  (커뮤니티 이미지, 계정 불필요, 레거시 호환용)"
$Edition = Ask "번호 선택" "1"

$NeedsLogin = $false
switch ($Edition) {
    "1" {
        $UpstreamImage = "$RegistryHost/database/enterprise:19.3.0.0"
        $Tag = "19c"
        $NeedsLogin = $true
    }
    "2" {
        $UpstreamImage = "gvenzl/oracle-xe:21-slim"
        $Tag = "21c-xe"
    }
    "3" {
        $UpstreamImage = "gvenzl/oracle-xe:18-slim"
        $Tag = "18c-xe"
    }
    default {
        Write-Err2 "잘못된 선택입니다."
        exit 1
    }
}
$TargetImage = "$LocalRegistry/$Namespace/${DbKind}:$Tag"
Write-Ok "선택됨: $UpstreamImage -> $TargetImage"

if ($NeedsLogin) {
    Write-Host ""
    Write-Info "Enterprise Edition은 Oracle 계정 인증이 필요합니다."
    $env:DOCKER_CLI_EXPERIMENTAL = "enabled"
    docker manifest inspect $UpstreamImage *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "이미 로그인/캐시된 자격증명으로 이미지 접근이 가능합니다. 로그인 단계를 건너뜁니다."
    } else {
        Write-Warn2 "먼저 브라우저에서 아래를 완료해야 합니다:"
        Write-Host "   1) https://$RegistryHost 접속 후 로그인"
        Write-Host "   2) Database > enterprise 리포지터리 라이선스 동의(Continue)"
        Write-Host "   3) 계정 아이콘 > Auth Token 메뉴에서 토큰 발급"
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

try {
    $resp = Invoke-WebRequest -Uri "http://$LocalRegistry/v2/" -UseBasicParsing -TimeoutSec 3
} catch {
    Write-Err2 "로컬 레지스트리($LocalRegistry)가 응답하지 않습니다. 먼저 oracle/registry/setup-registry.ps1 을 실행하세요."
    exit 1
}

Write-Info "상위 이미지를 내려받는 중입니다: $UpstreamImage"
docker pull $UpstreamImage

Write-Info "베이스 이미지를 빌드합니다: $TargetImage"
docker build --build-arg "BASE_IMAGE=$UpstreamImage" -t $TargetImage -f Dockerfile .

Write-Info "레지스트리로 push 합니다: $TargetImage"
docker push $TargetImage

Write-Host ""
Write-Host "======================= 완료 ======================="
Write-Host " 상위 이미지   : $UpstreamImage"
Write-Host " 등록된 이미지 : $TargetImage"
Write-Host "======================================================"
