<#
  Realtor AI Assistant — UNIFIED LAUNCHER (run every day, Windows)

   1. Creates/activates a Python virtualenv (first time only).
   2. Installs backend dependencies (idempotent).
   3. Loads server\.env.
   4. If the LLM server is unreachable and a local GGUF model is
      configured, starts `llama-server.exe` automatically.
   5. Starts the web app with uvicorn.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ----------------------------------------------------------
# Helpers. PowerShell 5.1 turns a native command's stderr into
# a terminating error when $ErrorActionPreference='Stop'.
# These run native commands safely and return their exit code.
# ----------------------------------------------------------
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & $FilePath @Arguments
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-NativeSilent {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & $FilePath @Arguments *> $null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

$ProjectRoot = $PSScriptRoot
Set-Location $ProjectRoot

# ----------------------------------------------------------
# Python interpreter
# ----------------------------------------------------------
function Get-Python {
    foreach ($candidate in @('python', 'py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            if ((Invoke-NativeSilent $candidate '--version') -eq 0) { return $candidate }
        }
    }
    return $null
}

$Python = Get-Python
if (-not $Python) {
    Write-Host 'python не найден. Установите Python 3.12 и запустите run.bat ещё раз.' -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------
# Virtualenv
# ----------------------------------------------------------
$VenvDir    = Join-Path $ProjectRoot '.venv'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'

if (-not (Test-Path -LiteralPath $VenvPython)) {
    Write-Host '==> Создаю виртуальное окружение (.venv)…'
    if ((Invoke-Native $Python '-m' 'venv' $VenvDir) -ne 0) {
        Write-Host 'ОШИБКА: не удалось создать виртуальное окружение.' -ForegroundColor Red
        Write-Host 'Если сообщается "ensurepip is not available" — переустановите Python' -ForegroundColor Red
        Write-Host 'с https://www.python.org/downloads/ и запустите run.bat ещё раз.' -ForegroundColor Red
        exit 1
    }
}

# ----------------------------------------------------------
# Dependencies (idempotent)
# ----------------------------------------------------------
Write-Host '==> Проверяю/устанавливаю зависимости…'
if ((Invoke-Native $VenvPython '-m' 'pip' 'install' '--quiet' '--upgrade' 'pip') -ne 0) {
    Write-Host 'ОШИБКА: pip upgrade не удался.' -ForegroundColor Red
    exit 1
}
if ((Invoke-Native $VenvPython '-m' 'pip' 'install' '--quiet' '-r' (Join-Path $ProjectRoot 'server\requirements.txt')) -ne 0) {
    Write-Host 'ОШИБКА: установка зависимостей не удалась.' -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------
# Load server\.env
# ----------------------------------------------------------
$EnvFile = Join-Path $ProjectRoot 'server\.env'
if (Test-Path -LiteralPath $EnvFile) {
    Write-Host '==> Загружаю server\.env'
    foreach ($raw in [System.IO.File]::ReadAllLines($EnvFile)) {
        $line = $raw.Trim().TrimStart([char]0xFEFF)
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) { continue }
        $idx = $line.IndexOf('=')
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        if ($key) { Set-Item -Path "env:$key" -Value $val }
    }
}

$BaseUrl   = if ($env:LLM_BASE_URL) { $env:LLM_BASE_URL.TrimEnd('/') } else { 'http://127.0.0.1:8080/v1' }
$HostName  = if ($env:HOST) { $env:HOST } else { '127.0.0.1' }
$Port      = if ($env:PORT) { $env:PORT } else { '8000' }
$StateDir  = if ($env:STATE_DIR) { $env:STATE_DIR } else { (Join-Path $env:USERPROFILE 'realtor-ai-app\state') }
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# LLM server port (for auto-starting llama-server).
$LlmPort = '8080'
if ($BaseUrl -match '^https?://[^:/]+:([0-9]+)') { $LlmPort = $Matches[1] }

$LlamaServer = if ($env:LLAMA_SERVER_PATH) { $env:LLAMA_SERVER_PATH } else { 'llama-server.exe' }
$LocalGguf   = $env:LOCAL_GGUF_PATH

function Test-LlmReachable([string]$BaseUrl) {
    return ((Invoke-NativeSilent curl.exe -fsS --max-time 5 "$BaseUrl/models") -eq 0)
}

# ----------------------------------------------------------
# Ensure the LLM server is reachable
# ----------------------------------------------------------
if (-not (Test-LlmReachable $BaseUrl)) {
    if ($LocalGguf -and (Test-Path -LiteralPath $LocalGguf) -and (Test-Path -LiteralPath $LlamaServer)) {
        Write-Host '==> LLM-сервер недоступен. Автозапуск llama-server:'
        Write-Host "    бинарник: $LlamaServer"
        Write-Host "    модель: $LocalGguf"

        $Alias   = if ($env:REALTOR_MODEL) { $env:REALTOR_MODEL } else { 'qwen2.5-7b-instruct' }
        $CtxSize = if ($env:LLM_CTX_SIZE) { $env:LLM_CTX_SIZE } else { '8192' }
        $Threads = [Environment]::ProcessorCount

        $OutLog = Join-Path $StateDir 'llama-server.log'
        $ErrLog = Join-Path $StateDir 'llama-server.err.log'

        $proc = Start-Process -FilePath $LlamaServer -ArgumentList @(
            '--model', $LocalGguf,
            '--alias', $Alias,
            '--host', '127.0.0.1',
            '--port', $LlmPort,
            '--ctx-size', $CtxSize,
            '--threads', "$Threads"
        ) -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -PassThru

        Write-Host "    PID: $($proc.Id)"
        Write-Host "    лог: $OutLog"

        Write-Host '==> Ожидаю запуска LLM-сервера…'
        for ($i = 0; $i -lt 40; $i++) {
            if (Test-LlmReachable $BaseUrl) { break }
            Start-Sleep -Seconds 2
        }
    }
}

if (Test-LlmReachable $BaseUrl) {
    Write-Host "==> LLM-сервер доступен: $BaseUrl"
}
else {
    Write-Host ''
    Write-Host "ВНИМАНИЕ: LLM-сервер недоступен по адресу $BaseUrl"
    Write-Host 'Приложение запустится, но агенты не смогут отвечать.'
    Write-Host 'Способы запустить LLM-сервер описаны в README.md.'
    Write-Host ''
}

Write-Host ''
Write-Host '================================================='
Write-Host '  Realtor AI Assistant'
Write-Host "  Веб-интерфейс : http://${HostName}:$Port"
Write-Host "  LLM endpoint   : $BaseUrl"
Write-Host "  Хранилище      : $StateDir"
Write-Host '================================================='
Write-Host ''

# uvicorn пишет логи в stderr. Запускаем с 'Continue', чтобы логи
# отображались, но не обрывали скрипт.
$ErrorActionPreference = 'Continue'
& $VenvPython -m uvicorn app:app --app-dir server --host $HostName --port $Port
exit $LASTEXITCODE