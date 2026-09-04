# ============================================================================
# OmnioneCX 저축은행중앙회(fsb) 컨테이너 안으로 들어가는 명령어 (db/verifier/oacx 공용)
#
# docker-compose.yml의 서비스명(db/verifier/oacx)을 그대로 쓴다 -- 실제
# container_name을 무엇으로 지었든 상관없이 동작한다.
#
# 사용법:
#   .\exec.ps1 db              # db 컨테이너 안에서 sh 실행 (기본 셸)
#   .\exec.ps1 verifier        # verifier 컨테이너 안에서 sh 실행
#   .\exec.ps1 oacx bash       # oacx 컨테이너 안에서 bash 실행 (셸 직접 지정)
#
# db에 SQL 클라이언트로 바로 붙고 싶으면:
#   .\exec.ps1 db mariadb -uroot -p
# ============================================================================
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("db", "verifier", "oacx")]
    [string]$Service,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Command
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

if (-not $Command -or $Command.Count -eq 0) {
    $Command = @("sh")
}

$EnvFile = Join-Path $ScriptDir ".staging\omnionecx.env"
if (Test-Path $EnvFile) {
    # deploy.ps1 실행 시 프로젝트 이름을 직접 물어보고 바꿀 수 있으므로(같은
    # PC에서 이 사이트를 여러 벌 띄우는 경우 등), 하드코딩하지 않고 그때
    # 저장해둔 값을 그대로 읽어 쓴다.
    $envLine = Select-String -Path $EnvFile -Pattern '^COMPOSE_PROJECT=' | Select-Object -First 1
    $ComposeProject = if ($envLine) { ($envLine.Line -split '=', 2)[1] } else { "omnionecx-fsb" }
    docker compose -f docker-compose.yml -p $ComposeProject --env-file $EnvFile exec $Service @Command
} else {
    # .staging\omnionecx.env가 없으면(예: deploy 스크립트를 거치지 않고 직접
    # docker compose로 띄운 경우) 기본 프로젝트명으로 접속을 시도한다.
    docker compose -p omnionecx-fsb exec $Service @Command
}
