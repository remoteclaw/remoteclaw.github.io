# RemoteClaw Installer for Windows (PowerShell)
# Usage: iwr -useb https://remoteclaw.org/install.ps1 | iex

param(
    [string]$Tag = "latest",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Colors
$ACCENT = "`e[38;2;99;102;241m"    # indigo
$SUCCESS = "`e[38;2;34;197;94m"     # green
$WARN = "`e[38;2;234;179;8m"       # amber
$ERROR = "`e[38;2;239;68;68m"      # red
$MUTED = "`e[38;2;90;100;128m"     # text-muted
$NC = "`e[0m"                      # No Color

function Write-Status {
    param([string]$Message, [string]$Level = "info")
    $msg = switch ($Level) {
        "success" { "$SUCCESS`u{2713}$NC $Message" }
        "warn" { "$WARN!$NC $Message" }
        "error" { "$ERROR`u{2717}$NC $Message" }
        default { "$MUTED`u{00B7}$NC $Message" }
    }
    [Console]::WriteLine($msg)
}

function Write-Banner {
    [Console]::WriteLine("")
    [Console]::WriteLine("${ACCENT}  RemoteClaw Installer$NC")
    [Console]::WriteLine("${MUTED}  Self-hosted middleware for AI coding agents.$NC")
    [Console]::WriteLine("")
}

function Get-ExecutionPolicyStatus {
    $policy = Get-ExecutionPolicy
    if ($policy -eq "Restricted" -or $policy -eq "AllSigned") {
        return @{ Blocked = $true; Policy = $policy }
    }
    return @{ Blocked = $false; Policy = $policy }
}

function Ensure-ExecutionPolicy {
    $status = Get-ExecutionPolicyStatus
    if ($status.Blocked) {
        Write-Status "PowerShell execution policy is set to: $($status.Policy)" -Level warn
        Write-Status "This prevents scripts like npm.ps1 from running." -Level warn

        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -ErrorAction Stop
            Write-Status "Set execution policy to RemoteSigned for current process" -Level success
            return $true
        } catch {
            Write-Status "Could not automatically set execution policy" -Level error
            [Console]::WriteLine("")
            Write-Status "To fix this, run:" -Level info
            Write-Status "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process" -Level info
            [Console]::WriteLine("")
            Write-Status "Or run PowerShell as Administrator and execute:" -Level info
            Write-Status "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine" -Level info
            return $false
        }
    }
    return $true
}

function Get-NodeVersion {
    try {
        $version = node --version 2>$null
        if ($version) {
            return $version -replace '^v', ''
        }
    } catch { }
    return $null
}

function Install-Node {
    Write-Status "Node.js not found" -Level info
    Write-Status "Installing Node.js..." -Level info

    # Try winget first
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Status "  Using winget..." -Level info
        try {
            winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-Status "  Node.js installed via winget" -Level success
            return $true
        } catch {
            Write-Status "  Winget install failed: $_" -Level warn
        }
    }

    # Try chocolatey
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Status "  Using chocolatey..." -Level info
        try {
            choco install nodejs-lts -y 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-Status "  Node.js installed via chocolatey" -Level success
            return $true
        } catch {
            Write-Status "  Chocolatey install failed: $_" -Level warn
        }
    }

    # Try scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Status "  Using scoop..." -Level info
        try {
            scoop install nodejs-lts 2>&1 | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            Write-Status "  Node.js installed via scoop" -Level success
            return $true
        } catch {
            Write-Status "  Scoop install failed: $_" -Level warn
        }
    }

    Write-Status "Could not install Node.js automatically" -Level error
    Write-Status "Please install Node.js 22+ manually from: https://nodejs.org" -Level info
    return $false
}

function Ensure-Node {
    $nodeVersion = Get-NodeVersion
    if ($nodeVersion) {
        $major = [int]($nodeVersion -split '\.')[0]
        if ($major -ge 22) {
            Write-Status "Node.js v$nodeVersion found" -Level success
            return $true
        }
        Write-Status "Node.js v$nodeVersion found, but need v22+" -Level warn
    }
    return Install-Node
}

function Install-RemoteClawNpm {
    param([string]$Version = "latest")

    Write-Status "Installing RemoteClaw (remoteclaw@$Version)..." -Level info

    try {
        npm install -g remoteclaw@$Version --no-fund --no-audit 2>&1
        Write-Status "RemoteClaw installed" -Level success
        return $true
    } catch {
        Write-Status "npm install failed: $_" -Level error
        return $false
    }
}

function Add-ToPath {
    param([string]$Path)

    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$Path*") {
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$Path", "User")
        Write-Status "Added $Path to user PATH" -Level info
    }
}

# Main
function Main {
    Write-Banner

    Write-Status "Windows detected" -Level success

    # Check and handle execution policy FIRST
    if (!(Ensure-ExecutionPolicy)) {
        [Console]::WriteLine("")
        Write-Status "Installation cannot continue due to execution policy restrictions" -Level error
        exit 1
    }

    if (!(Ensure-Node)) {
        exit 1
    }

    if ($DryRun) {
        Write-Status "[DRY RUN] Would install RemoteClaw via npm (tag: $Tag)" -Level info
        return
    }

    if (!(Install-RemoteClawNpm -Version $Tag)) {
        exit 1
    }

    # Try to add npm global bin to PATH
    try {
        $npmPrefix = npm config get prefix 2>$null
        if ($npmPrefix) {
            Add-ToPath -Path "$npmPrefix"
        }
    } catch { }

    [Console]::WriteLine("")
    Write-Status "RemoteClaw installed successfully!" -Level success
    [Console]::WriteLine("${MUTED}Open a new terminal to get started.$NC")
}

Main
