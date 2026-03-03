$env:PATH = "C:\Program Files\Erlang OTP\bin;C:\Users\Pichau\elixir\bin;" + $env:PATH
Set-Location "C:\Users\Pichau\Desktop\OSA"

# Load .env
Get-Content ".env" | ForEach-Object {
    if ($_ -match "^\s*([^#][^=]+)=(.*)$") {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
    }
}

$TUI = "C:\Users\Pichau\Desktop\OSA\priv\go\tui-v2\osa.exe"

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
    $pids = $stale | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($pid in $pids) {
        # Kill the direct owner and any beam.smp children
        Get-Process -Id $pid -ErrorAction SilentlyContinue | ForEach-Object {
            $_.Kill($true)  # $true = kill entire process tree
        }
    }
    # Also kill any orphaned beam.smp processes
    Get-Process -Name "beam.smp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# Start Elixir backend in new window
Write-Host "Starting OSA backend on :8089..." -ForegroundColor Cyan
$backendScript = @"
`$env:PATH = 'C:\Program Files\Erlang OTP\bin;C:\Users\Pichau\elixir\bin;' + `$env:PATH
Set-Location 'C:\Users\Pichau\Desktop\OSA'
Get-Content '.env' | ForEach-Object {
    if (`$_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable(`$Matches[1].Trim(), `$Matches[2].Trim(), 'Process')
    }
}
$extraEnvLines
`$env:OSA_SKIP_NIF = 'true'
& 'C:\Users\Pichau\elixir\bin\mix.bat' osa.serve
"@

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
$backendProc = Get-Process -Id $backend.Id -ErrorAction SilentlyContinue
if ($backendProc) { $backendProc.Kill($true) }
Get-Process -Name "beam.smp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
