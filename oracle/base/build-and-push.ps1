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

# .env가 있으면 ORACLE_REGISTRY_USER / ORACLE_AUTH_TOKEN을 읽어온다 (없으면 나중에 직접 입력받음).
# .env는 .gitignore에 등록되어 있으며, 토큰은 절대 커밋되지 않는다.
$EnvFile = Join-Path $ScriptDir ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
        }
    }
}

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

Write-Host "=============================================================="
Write-Host " Oracle 베이스 이미지 빌드 + servicetech2 레지스트리 등록"
Write-Host "=============================================================="

# 개발 PC: localhost:5000 (이 PC에서 만든 로컬 레지스트리)
# 팀서버(new-servicetech2-1, 192.168.0.168): servicetech2:5000
# (hosts 파일 등록 + insecure-registry 등록 필요, registry-server/linux-registry-setup.md 참고)
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

        if ($env:ORACLE_REGISTRY_USER -and $env:ORACLE_AUTH_TOKEN) {
            Write-Ok ".env에서 계정($($env:ORACLE_REGISTRY_USER))과 토큰을 읽었습니다. 대화형 입력을 건너뜁니다."
            $OracleUser = $env:ORACLE_REGISTRY_USER
            $AuthToken = $env:ORACLE_AUTH_TOKEN
        } else {
            Read-Host "위 단계를 완료했으면 Enter를 눌러 계속하세요"
            $OracleUser = Ask "Oracle 계정 이메일(Username)" $env:ORACLE_REGISTRY_USER
            $AuthToken = Ask-Secret "Auth Token"
        }

        $AuthToken | docker login $RegistryHost --username $OracleUser --password-stdin
        if ($LASTEXITCODE -ne 0) {
            Write-Err2 "로그인 실패. Auth Token 또는 라이선스 동의 상태를 다시 확인하세요. (.env의 ORACLE_AUTH_TOKEN이 비어있지 않은지도 확인)"
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
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "상위 이미지 pull 실패. 네트워크 상태를 확인하고 재시도하세요."
    exit 1
}

Write-Info "베이스 이미지를 빌드합니다: $TargetImage"
docker build --build-arg "BASE_IMAGE=$UpstreamImage" -t $TargetImage -f Dockerfile .
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "이미지 빌드 실패."
    exit 1
}

Write-Info "레지스트리로 push 합니다: $TargetImage"
docker push $TargetImage
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "레지스트리 push 실패 (네트워크 타임아웃 등). 재시도하려면 이 스크립트를 다시 실행하거나 'docker push $TargetImage'를 직접 실행하세요."
    exit 1
}

# push 성공 여부를 명령 종료 코드만으로 판단하지 않고, 실제로 태그가 조회되는지 재확인
# (원격 레지스트리는 일부 레이어 업로드가 타임아웃 나도 push 명령 자체는 성공으로 끝나는 경우가 있었음 -- 2026-08-24 실제 발생)
Write-Info "push 결과를 재확인합니다..."
docker manifest inspect $TargetImage *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "push 명령은 끝났지만 레지스트리에서 해당 태그가 확인되지 않습니다 (일부 레이어 업로드 실패 가능성). 'docker push $TargetImage'를 다시 실행하세요."
    exit 1
}
Write-Ok "레지스트리에서 태그 확인 완료"

Write-Host ""
Write-Host "======================= 완료 ======================="
Write-Host " 상위 이미지   : $UpstreamImage"
Write-Host " 등록된 이미지 : $TargetImage"
Write-Host "======================================================"
