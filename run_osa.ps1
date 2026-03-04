$OSA_DIR = $PSScriptRoot
$ELIXIR_BIN = (Get-Command mix -ErrorAction SilentlyContinue | Split-Path)
if (-not $ELIXIR_BIN) { $ELIXIR_BIN = "$env:USERPROFILE\elixir\bin" }
$env:PATH = "C:\Program Files\Erlang OTP\bin;$ELIXIR_BIN;" + $env:PATH
Set-Location $OSA_DIR

# Load .env
Get-Content ".env" | ForEach-Object {
    if ($_ -match "^\s*([^#][^=]+)=(.*)$") {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
    }
}

# --- TUI binary selection: prefer Rust TUI, fallback to Go TUI ---
$RUST_TUI = "$OSA_DIR\priv\rust\tui\target\release\osagent.exe"
$GO_TUI   = "$OSA_DIR\priv\go\tui-v2\osa.exe"

if (Test-Path $RUST_TUI) {
    $TUI = $RUST_TUI
    Write-Host "Using Rust TUI" -ForegroundColor Green
} elseif (Test-Path $GO_TUI) {
    Write-Host "Rust TUI not found at $RUST_TUI" -ForegroundColor Yellow
    Write-Host "Falling back to Go TUI" -ForegroundColor Yellow
    # Offer to build if cargo is available
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargo) {
        $build = Read-Host "cargo found — build Rust TUI now? (y/N)"
        if ($build -eq "y") {
            Write-Host "Building Rust TUI (this may take a few minutes)..." -ForegroundColor Cyan
            Push-Location "$OSA_DIR\priv\rust\tui"
            & cargo build --release
            Pop-Location
            if (Test-Path $RUST_TUI) {
                $TUI = $RUST_TUI
                Write-Host "Build succeeded! Using Rust TUI" -ForegroundColor Green
            } else {
                Write-Host "Build failed. Using Go TUI" -ForegroundColor Red
                $TUI = $GO_TUI
            }
        } else {
            $TUI = $GO_TUI
        }
    } else {
        $TUI = $GO_TUI
    }
} else {
    Write-Host "ERROR: No TUI binary found!" -ForegroundColor Red
    Write-Host "  Expected Rust TUI at: $RUST_TUI" -ForegroundColor Red
    Write-Host "  Expected Go TUI at:   $GO_TUI" -ForegroundColor Red
    exit 1
}

# Check if any cloud API key is configured
$cloudKeys = @("OLLAMA_API_KEY", "GROQ_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "TOGETHER_API_KEY", "DEEPSEEK_API_KEY", "OPENROUTER_API_KEY")
$hasApiKey = $cloudKeys | Where-Object {
    $v = [System.Environment]::GetEnvironmentVariable($_, "Process")
    $null -ne $v -and $v -ne ""
} | Select-Object -First 1

$extraEnvLines = ""

if (-not $hasApiKey) {
    Write-Host ""
    Write-Host "Nenhuma API key configurada." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Opcoes: ollama, groq, anthropic, openai, openrouter"
    Write-Host "(Enter para tentar Ollama local sem key)"
    $choice = Read-Host "Provider"

    if ($choice -ne "") {
        $choice = $choice.ToLower().Trim()
        $apiKey = Read-Host "API Key para $choice"
        if ($apiKey -ne "") {
            $envKeyName = "$($choice.ToUpper())_API_KEY"
            [System.Environment]::SetEnvironmentVariable($envKeyName, $apiKey, "Process")
            [System.Environment]::SetEnvironmentVariable("OSA_DEFAULT_PROVIDER", $choice, "Process")
            $extraEnvLines = "[System.Environment]::SetEnvironmentVariable('OSA_DEFAULT_PROVIDER', '$choice', 'Process')`n[System.Environment]::SetEnvironmentVariable('$envKeyName', '$apiKey', 'Process')"
            Write-Host "OK! Usando $choice." -ForegroundColor Green
        }
    }
}

# Kill any stale process on :8089 (beam.smp may be a grandchild of the PS window)
$stale = Get-NetTCPConnection -LocalPort 8089 -ErrorAction SilentlyContinue
if ($stale) {
    Write-Host "Killing stale process on :8089..." -ForegroundColor Yellow
    $ownerPids = $stale | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($ownerPid in $ownerPids) {
        # Kill process tree (taskkill works on Windows PowerShell 5.1)
        taskkill /F /T /PID $ownerPid 2>$null
    }
    # Also kill any orphaned beam.smp processes
    Get-Process -Name "beam.smp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# Start Elixir backend in new window
Write-Host "Starting OSA backend on :8089..." -ForegroundColor Cyan
# Use single-quoted here-string so $_, $Matches, $env:PATH are literal in the generated script.
# Variable parts (paths) are substituted via -replace after building the string.
$backendScript = @'
$env:PATH = 'ELIXIR_BIN_PLACEHOLDER;C:\Program Files\Erlang OTP\bin;' + $env:PATH
Set-Location 'OSA_DIR_PLACEHOLDER'
Get-Content '.env' | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process')
    }
}
EXTRA_ENV_PLACEHOLDER
$env:OSA_SKIP_NIF = 'true'
& 'MIX_PATH_PLACEHOLDER' osa.serve
'@
$backendScript = $backendScript -replace 'ELIXIR_BIN_PLACEHOLDER', $ELIXIR_BIN
$backendScript = $backendScript -replace 'OSA_DIR_PLACEHOLDER',   $OSA_DIR
$backendScript = $backendScript -replace 'EXTRA_ENV_PLACEHOLDER',  $extraEnvLines
$backendScript = $backendScript -replace 'MIX_PATH_PLACEHOLDER',  "$ELIXIR_BIN\mix.bat"

$backendScript | Out-File "$env:TEMP\osa_backend.ps1" -Encoding UTF8
$backend = Start-Process powershell -ArgumentList "-NoExit", "-File", "$env:TEMP\osa_backend.ps1" -PassThru

# Wait for health
Write-Host "Waiting for backend..." -ForegroundColor Yellow
$attempts = 0
while ($attempts -lt 40) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8089/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { break }
    } catch {}
    Start-Sleep -Seconds 1
    $attempts++
}

if ($attempts -eq 40) {
    Write-Host "Backend failed to start. Check the backend window for errors." -ForegroundColor Red
    Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Backend ready! Launching TUI..." -ForegroundColor Green
& $TUI

Write-Host "Shutting down backend..." -ForegroundColor Yellow
# Kill the PowerShell wrapper and its entire process tree (beam.smp is a grandchild)
taskkill /F /T /PID $backend.Id 2>$null
Get-Process -Name "beam.smp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
