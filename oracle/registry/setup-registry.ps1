<#
.SYNOPSIS
  로컬 프라이빗 Docker Registry(servicetech2) 구축 스크립트 (PowerShell)

.DESCRIPTION
  지원 환경: Windows PowerShell 5.1+ / PowerShell 7+
  주의     : 로컬(localhost) 전용입니다. 외부에 노출하지 마세요
             (인증/TLS 미적용 상태입니다).
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

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

Write-Host "=============================================================="
Write-Host " 로컬 프라이빗 Docker Registry 구축 (servicetech2)"
Write-Host " (로컬 전용 — 외부 노출 금지)"
Write-Host "=============================================================="
Write-Host ""

$RegistryPort = Ask "레지스트리 포트" "5000"

"REGISTRY_PORT=$RegistryPort" | Set-Content -Path ".env" -Encoding ascii
Write-Ok ".env 파일 작성 완료 (REGISTRY_PORT=$RegistryPort)"

Write-Info "레지스트리 컨테이너를 기동합니다..."
docker compose up -d

Write-Info "정상 기동 대기 중..."
$okFlag = $false
for ($i = 1; $i -le 20; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$RegistryPort/v2/" -UseBasicParsing -TimeoutSec 2
        if ($resp.StatusCode -eq 200) { $okFlag = $true; break }
    } catch { }
    Start-Sleep -Seconds 1
}
if ($okFlag) {
    Write-Ok "레지스트리가 http://localhost:$RegistryPort 에서 응답합니다."
} else {
    Write-Err2 "레지스트리가 응답하지 않습니다. 'docker logs servicetech2-registry'로 확인하세요."
    exit 1
}

# ---------- 스모크 테스트: 실제 push/pull 왕복 확인 ----------
Write-Info "스모크 테스트: 작은 이미지로 push/pull 왕복 확인 중..."
$SmokeTag = "localhost:$RegistryPort/servicetech2/smoke-test:latest"
docker pull hello-world | Out-Null
docker tag hello-world $SmokeTag
docker push $SmokeTag | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "push 성공"
} else {
    Write-Err2 "push 실패. 레지스트리 상태를 확인하세요."
    exit 1
}
docker rmi $SmokeTag 2>$null | Out-Null
docker pull $SmokeTag | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "pull 성공 — 레지스트리가 정상 동작합니다."
} else {
    Write-Err2 "pull 실패."
    exit 1
}
docker rmi $SmokeTag 2>$null | Out-Null

Write-Host ""
Write-Host "======================= 완료 ======================="
Write-Host " 레지스트리 주소 : localhost:$RegistryPort"
Write-Host " 네임스페이스    : servicetech2"
Write-Host " 이미지 네이밍 예: localhost:$RegistryPort/servicetech2/oracle:19c"
Write-Host "======================================================"
