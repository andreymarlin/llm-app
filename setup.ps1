<#
  Realtor AI Assistant — FIRST-TIME SETUP (Windows)

  Does everything needed once:
    1. Ensures Python is present.
    2. Downloads a prebuilt llama.cpp binary (`llama-server.exe`) from GitHub.
       (No manual build, no package managers required.)
    3. Downloads a free Qwen model (Qwen2.5-7B-Instruct, Q4_K_M, ~4.7 GB).
    4. Creates server\.env with sane defaults.

  After this, start the app any time with:  run.bat  (or  .\run.ps1)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Make sure Russian text renders correctly in the console.
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

# Hugging Face / GitHub can reset large downloads on Windows (curl exit 52,
# "empty reply from server"). A real browser User-Agent, forced IPv4 and
# HTTP/1.1 avoid the most common causes (HTTP/2 resets, broken IPv6 routes).
$CurlUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36'

# Download a file with resumable retries. Progress is never lost: once a
# partial file exists, --continue-at - resumes it on the next attempt.
function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [long]$ExpectedSize = 0,
        [int]$MaxAttempts = 10,
        [int]$DelaySeconds = 5
    )

    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $curlArgs = @('-L', '--fail', '-4', '--http1.1', '-A', $CurlUserAgent,
                      '--connect-timeout', '20', '-sS')
        if (Test-Path -LiteralPath $OutFile) { $curlArgs += @('--continue-at', '-') }
        $curlArgs += @('--output', $OutFile, $Url)

        Write-Host ("    Попытка {0}/{1}…" -f $attempt, $MaxAttempts)
        $code = Invoke-Native curl.exe @curlArgs

        $actual = 0
        if (Test-Path -LiteralPath $OutFile) {
            $actual = (Get-Item -LiteralPath $OutFile).Length
        }

        if ($code -eq 0) {
            if ($ExpectedSize -gt 0 -and $actual -ne $ExpectedSize) {
                Write-Host ("    Размер файла не совпал: {0:N0} вместо {1:N0}. Повторяю…" -f $actual, $ExpectedSize) -ForegroundColor Yellow
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            }
            else {
                return
            }
        }
        elseif ($code -eq 33) {
            # HTTP range not satisfiable: the file is already fully downloaded.
            if ($ExpectedSize -gt 0 -and $actual -ne $ExpectedSize) {
                Write-Host "    Частичный файл не удаётся докачать. Начинаю заново…" -ForegroundColor Yellow
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            }
            else {
                return
            }
        }

        Write-Host ("    Ошибка загрузки (код {0}). Пробую снова через {1} с…" -f $code, $DelaySeconds) -ForegroundColor Yellow
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $DelaySeconds }
    }

    Write-Host ("ОШИБКА: не удалось скачать файл после {0} попыток: {1}" -f $MaxAttempts, $Url) -ForegroundColor Red
    Write-Host 'Проверьте интернет-соединение, отключите VPN/прокси и запустите setup.bat ещё раз.' -ForegroundColor Red
    exit 1
}

# Fetch the final Content-Length (follows redirects) so we can verify a download.
function Get-ContentLength {
    param([Parameter(Mandatory = $true)][string]$Url)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $headers = & curl.exe -4 -L --http1.1 -A $CurlUserAgent --connect-timeout 20 --max-time 60 -sS -I $Url 2>$null
        foreach ($line in $headers) {
            if ($line -match '^content-length:\s*(\d+)') {
                return [long]$Matches[1]
            }
        }
    }
    finally {
        $ErrorActionPreference = $prev
    }
    return 0
}

$ProjectRoot = $PSScriptRoot
$AppRoot     = Join-Path $env:USERPROFILE 'realtor-ai-app'
$LlamaDir    = Join-Path $AppRoot 'bin'
$ModelsDir   = Join-Path $AppRoot 'models'
$EnvFile     = Join-Path $ProjectRoot 'server\.env'

Write-Host '================================================='
Write-Host '  Realtor AI Assistant — первичная настройка'
Write-Host '================================================='

# ----------------------------------------------------------
# 1. Python 3
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
    Write-Host ''
    Write-Host '==> python не найден.'
    Write-Host '    Скачайте и установите Python 3.12 с https://www.python.org/downloads/'
    Write-Host '    (при установке отметьте "Add python.exe to PATH"),'
    Write-Host '    затем запустите setup.bat ещё раз.'
    exit 1
}
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$versionOutput = (& $Python --version 2>&1 | Out-String)
$ErrorActionPreference = $prevEap
Write-Host "==> python: $($versionOutput.Trim())"

# ----------------------------------------------------------
# 2. llama.cpp — prebuilt `llama-server.exe` binary
# ----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LlamaDir | Out-Null

$LlamaServer = Join-Path $LlamaDir 'llama-server.exe'

function Test-LlamaServer {
    if (-not (Test-Path -LiteralPath $LlamaServer)) { return $false }
    return ((Invoke-NativeSilent $LlamaServer '--version') -eq 0)
}

if (Test-LlamaServer) {
    Write-Host "==> llama-server уже установлен: $LlamaServer"
}
else {
    Write-Host ''
    Write-Host '==> Скачиваю готовый бинарник llama.cpp (llama-server.exe)…'

    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        'AMD64' { $assetArch = 'x64' }
        'ARM64' { $assetArch = 'arm64' }
        default {
            Write-Host "ОШИБКА: неизвестная архитектура: $arch" -ForegroundColor Red
            exit 1
        }
    }

    # The "latest" GitHub release carries no binaries; nightly bXXXXX tags do.
    # Pick the newest release that ships a Windows CPU binary for this machine.
    try {
        $headers = @{ 'User-Agent' = 'realtor-ai-setup' }
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30' -Headers $headers
    }
    catch {
        Write-Host "ОШИБКА: не удалось получить список релизов llama.cpp с GitHub." -ForegroundColor Red
        Write-Host "Проверьте подключение к интернету и запустите setup.bat ещё раз." -ForegroundColor Red
        exit 1
    }

    $tag = $null
    foreach ($rel in $releases) {
        foreach ($a in $rel.assets) {
            if ($a.name -like "*bin-win-cpu-$assetArch.zip") {
                $tag = $rel.tag_name
                break
            }
        }
        if ($tag) { break }
    }

    if (-not $tag) {
        Write-Host "ОШИБКА: не найден бинарник llama.cpp для win-cpu-$assetArch." -ForegroundColor Red
        exit 1
    }

    $assetName = "llama-${tag}-bin-win-cpu-${assetArch}.zip"
    $url = "https://github.com/ggml-org/llama.cpp/releases/download/$tag/$assetName"
    Write-Host "    $url"

    $zipPath = Join-Path $LlamaDir 'llama.zip'
    Download-File -Url $url -OutFile $zipPath

    Expand-Archive -Path $zipPath -DestinationPath $LlamaDir -Force
    Remove-Item -Path $zipPath -Force

    # The zip is downloaded from the web; remove the Mark-of-the-Web so Windows
    # does not block the .exe/.dll files.
    Get-ChildItem -Path $LlamaDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
}

if (-not (Test-LlamaServer)) {
    Write-Host ''
    Write-Host 'ОШИБКА: llama-server.exe не запускается.' -ForegroundColor Red
    Write-Host '  Требуется 64-разрядная Windows 10 или новее.' -ForegroundColor Red
    Write-Host '  Подробности сборки: https://github.com/ggml-org/llama.cpp' -ForegroundColor Red
    exit 1
}
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$lsVer = (& $LlamaServer --version 2>&1 | Select-Object -First 1)
$ErrorActionPreference = $prevEap
Write-Host "==> llama-server: $LlamaServer ($lsVer)"

# ----------------------------------------------------------
# 3. Free Qwen model (single-file GGUF, Q4_K_M)
# ----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null

$ModelFile  = 'Qwen2.5-7B-Instruct-Q4_K_M.gguf'
$ModelUrl   = "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/$ModelFile"
$ModelPath  = Join-Path $ModelsDir $ModelFile

if (Test-Path -LiteralPath $ModelPath) {
    Write-Host "==> Модель уже скачана: $ModelPath"
}
else {
    Write-Host ''
    Write-Host '==> Скачиваю Qwen2.5-7B-Instruct (Q4_K_M, ~4.7 ГБ)…'
    Write-Host '    Это займёт время в зависимости от скорости сети.'

    $expectedSize = Get-ContentLength -Url $ModelUrl
    if ($expectedSize -gt 0) {
        Write-Host ("    Ожидаемый размер: {0:N0} байт (~{1:N1} ГБ)" -f $expectedSize, ($expectedSize / 1GB))
    }

    Download-File -Url $ModelUrl -OutFile $ModelPath -ExpectedSize $expectedSize
    Write-Host "==> Модель сохранена: $ModelPath"
}

# ----------------------------------------------------------
# 4. server\.env
# ----------------------------------------------------------
if (Test-Path -LiteralPath $EnvFile) {
    Write-Host "==> $EnvFile уже существует — не перезаписываю."
}
else {
    $StateDir = Join-Path $AppRoot 'state'
    $envContent = @"
# Generated by setup.ps1
LLM_BASE_URL=http://127.0.0.1:8080/v1
LLM_API_KEY=
LLM_TIMEOUT=600
REALTOR_MODEL=qwen2.5-7b-instruct
ANALYST_MODEL=qwen2.5-7b-instruct
STATE_DIR=$StateDir
LOCAL_GGUF_PATH=$ModelPath
LLAMA_SERVER_PATH=$LlamaServer
HOST=127.0.0.1
PORT=8000
"@
    [System.IO.File]::WriteAllText($EnvFile, $envContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "==> Создан $EnvFile"
}

Write-Host ''
Write-Host '================================================='
Write-Host ' Готово!'
Write-Host ''
Write-Host ' Запуск приложения (всегда):'
Write-Host '   run.bat'
Write-Host ''
Write-Host ' Затем откройте в браузере: http://127.0.0.1:8000'
Write-Host '================================================='