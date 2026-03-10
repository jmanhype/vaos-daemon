#Requires -Version 5.1
<#
.SYNOPSIS
    OSA Desktop — Windows Installer
.DESCRIPTION
    Installs OSA Desktop on Windows.
    Checks for and installs: Visual Studio Build Tools, Rust, Node.js.
    Builds the app from source and installs to Program Files.
    Creates a Start Menu shortcut.
.EXAMPLE
    irm https://raw.githubusercontent.com/robertohluna/osa-desktop/main/scripts/install.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
$AppName        = 'OSA'
$RepoUrl        = 'https://github.com/robertohluna/osa-desktop.git'
$InstallSource  = "$env:LOCALAPPDATA\osa-desktop-src"
$InstallTarget  = "$env:ProgramFiles\OSA"
$NodeVersion    = '20'
$RustupUrl      = 'https://win.rustup.rs/x86_64'
$RustupInstaller = "$env:TEMP\rustup-init.exe"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
function Write-Step  { Write-Host "`n[OSA] $args" -ForegroundColor Cyan }
function Write-OK    { Write-Host "[OK]  $args"  -ForegroundColor Green }
function Write-Warn  { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Write-Fail  { Write-Host "[ERR]  $args" -ForegroundColor Red; exit 1 }

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [System.Security.Principal.WindowsPrincipal]$id
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ToUserPath {
    param([string]$Dir)
    $current = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($current -notlike "*$Dir*") {
        [System.Environment]::SetEnvironmentVariable('PATH', "$Dir;$current", 'User')
        $env:PATH = "$Dir;$env:PATH"
        Write-OK "Added $Dir to user PATH"
    }
}

function Install-ViaWinget {
    param([string]$Id, [string]$Label)
    Write-Step "Installing $Label via winget..."
    winget install --id $Id --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "winget returned exit code $LASTEXITCODE for $Label — it may already be installed."
    }
    Write-OK "$Label installed"
}

# --------------------------------------------------------------------------- #
# Elevation check
# --------------------------------------------------------------------------- #
if (-not (Test-Admin)) {
    Write-Warn "Not running as Administrator. Some steps (copying to Program Files) may fail."
    Write-Warn "Re-run PowerShell as Administrator for a system-wide install."
    Write-Warn "Continuing with user-level install fallback..."
    $InstallTarget = "$env:LOCALAPPDATA\Programs\OSA"
}

# --------------------------------------------------------------------------- #
# winget availability
# --------------------------------------------------------------------------- #
Write-Step "Checking winget"
if (-not (Test-Command 'winget')) {
    Write-Fail "winget not found. Install App Installer from the Microsoft Store, then re-run this script."
}
Write-OK "winget: available"

# --------------------------------------------------------------------------- #
# Visual Studio Build Tools
# --------------------------------------------------------------------------- #
Write-Step "Checking Visual Studio Build Tools (C++ workload)"

# Check for cl.exe (MSVC compiler) in common VS locations
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$HasVs = $false

if (Test-Path $VsWhere) {
    $vsInstall = & $VsWhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    $HasVs = ($null -ne $vsInstall -and $vsInstall -ne '')
}

if (-not $HasVs) {
    Write-Step "Installing Visual Studio Build Tools 2022..."
    # Microsoft.VisualStudio.2022.BuildTools includes C++ workload
    Install-ViaWinget 'Microsoft.VisualStudio.2022.BuildTools' 'VS Build Tools 2022'
    Write-Warn "If this is your first VS Build Tools install, the C++ workload may need manual selection."
    Write-Warn "Open Visual Studio Installer, select 'Desktop development with C++', and click Modify."
} else {
    Write-OK "Visual Studio Build Tools with C++ workload: present"
}

# --------------------------------------------------------------------------- #
# WebView2 Runtime (required by Tauri on Windows)
# --------------------------------------------------------------------------- #
Write-Step "Checking WebView2 Runtime"

$Webview2Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
if (-not (Test-Path $Webview2Key)) {
    Write-Step "Installing Microsoft Edge WebView2 Runtime..."
    Install-ViaWinget 'Microsoft.EdgeWebView2Runtime' 'WebView2 Runtime'
} else {
    Write-OK "WebView2 Runtime: present"
}

# --------------------------------------------------------------------------- #
# Rust
# --------------------------------------------------------------------------- #
Write-Step "Checking Rust toolchain"

# Refresh PATH to catch any tools installed above
$env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('PATH', 'User')

if (Test-Command 'rustc') {
    $rustVersion = rustc --version
    Write-OK "Rust already installed: $rustVersion"
} else {
    Write-Step "Downloading rustup-init.exe..."
    Invoke-WebRequest -Uri $RustupUrl -OutFile $RustupInstaller -UseBasicParsing

    Write-Step "Running rustup-init (default install)..."
    & $RustupInstaller -y --no-modify-path
    if ($LASTEXITCODE -ne 0) { Write-Fail "rustup-init failed with exit code $LASTEXITCODE" }

    Remove-Item $RustupInstaller -ErrorAction SilentlyContinue

    # Add cargo bin to PATH
    Add-ToUserPath "$env:USERPROFILE\.cargo\bin"
    Write-OK "Rust installed"
}

# Ensure cargo is reachable
$env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
if (-not (Test-Command 'cargo')) {
    Write-Fail "cargo not found after Rust installation. Restart PowerShell and re-run this script."
}
Write-OK "cargo: $(cargo --version)"

# --------------------------------------------------------------------------- #
# Node.js
# --------------------------------------------------------------------------- #
Write-Step "Checking Node.js"

if (Test-Command 'node') {
    Write-OK "Node.js already installed: $(node --version)"
} else {
    Install-ViaWinget 'OpenJS.NodeJS.LTS' "Node.js LTS"

    # Refresh PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')

    if (-not (Test-Command 'node')) {
        Write-Fail "node not found after installation. Restart PowerShell and re-run this script."
    }
}
Write-OK "node: $(node --version) | npm: $(npm --version)"

# --------------------------------------------------------------------------- #
# git
# --------------------------------------------------------------------------- #
Write-Step "Checking git"
if (-not (Test-Command 'git')) {
    Install-ViaWinget 'Git.Git' 'Git'
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}
Write-OK "git: $(git --version)"

# --------------------------------------------------------------------------- #
# Clone / update repository
# --------------------------------------------------------------------------- #
Write-Step "Fetching OSA Desktop source"

if (Test-Path "$InstallSource\.git") {
    Write-Step "Repository found — pulling latest..."
    git -C $InstallSource pull --ff-only
} else {
    Write-Step "Cloning repository..."
    git clone --depth 1 $RepoUrl $InstallSource
}
Write-OK "Source ready at $InstallSource"

# --------------------------------------------------------------------------- #
# Install JS dependencies
# --------------------------------------------------------------------------- #
Write-Step "Installing Node.js dependencies"
Push-Location $InstallSource
npm ci --prefer-offline
Write-OK "npm dependencies installed"

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #
Write-Step "Building OSA Desktop (this may take several minutes on first run)"
npm run tauri:build
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Fail "tauri build failed" }
Pop-Location
Write-OK "Build complete"

# --------------------------------------------------------------------------- #
# Install
# --------------------------------------------------------------------------- #
Write-Step "Installing $AppName to $InstallTarget"

$BundleDir = "$InstallSource\src-tauri\target\release\bundle"

# Prefer MSI installer
$Msi = Get-ChildItem "$BundleDir\msi" -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -ne $Msi) {
    Write-Step "Running MSI installer silently..."
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$($Msi.FullName)`" /qn INSTALLDIR=`"$InstallTarget`""
    Write-OK "MSI installer completed"
} else {
    # Fallback: copy NSIS .exe or raw exe
    $NsisExe = Get-ChildItem "$BundleDir\nsis" -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $NsisExe) {
        Write-Step "Running NSIS installer silently..."
        Start-Process $NsisExe.FullName -Wait -ArgumentList '/S'
        Write-OK "NSIS installer completed"
    } else {
        # Manual copy fallback
        Write-Step "No installer found — copying binary directly..."
        $ExePath = "$InstallSource\src-tauri\target\release\osa-desktop.exe"
        if (-not (Test-Path $ExePath)) {
            Write-Fail "Could not find build output. Check $BundleDir"
        }
        New-Item -ItemType Directory -Path $InstallTarget -Force | Out-Null
        Copy-Item $ExePath "$InstallTarget\OSA.exe" -Force
        Add-ToUserPath $InstallTarget
        Write-OK "Binary copied to $InstallTarget"
    }
}

# --------------------------------------------------------------------------- #
# Start Menu shortcut
# --------------------------------------------------------------------------- #
Write-Step "Creating Start Menu shortcut"

$StartMenuDir  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$ShortcutPath  = "$StartMenuDir\OSA.lnk"
$TargetExe     = if (Test-Path "$InstallTarget\OSA.exe") { "$InstallTarget\OSA.exe" } else { "OSA" }

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath      = $TargetExe
$Shortcut.WorkingDirectory = $InstallTarget
$Shortcut.Description     = 'Optimal System Agent Desktop'
$Shortcut.IconLocation    = $TargetExe
$Shortcut.Save()

Write-OK "Shortcut created at $ShortcutPath"

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   OSA Desktop installed successfully  ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Launch: Search 'OSA' in the Start Menu, or run 'OSA.exe' from:" -ForegroundColor White
Write-Host "        $InstallTarget" -ForegroundColor Cyan
Write-Host ""
Write-Host "Source kept at: $InstallSource" -ForegroundColor Gray
Write-Host "To update, re-run this installer." -ForegroundColor Gray
Write-Host ""
