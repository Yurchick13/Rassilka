param(
    [string]$ServerIp = "192.168.76.95",
    [string]$ServerUser = "root",
    [string]$RemoteDir = "/tmp/vacation-registry-rebuild",
    [string]$InstallDir = "/opt/vacation-registry",
    [string]$AppTimezone = "Europe/Moscow",
    [int]$Port = 8000,
    [switch]$RewriteEnv
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [string]$Exe,
        [string[]]$Args
    )

    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Exe $($Args -join ' ')"
    }
}

foreach ($cmd in @("ssh", "scp", "tar")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Command not found: $cmd. Install OpenSSH client and tar, then retry."
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archiveName = "vacation-registry-$timestamp.tar.gz"
$localArchive = Join-Path $env:TEMP $archiveName
$remoteArchive = "/tmp/$archiveName"
$rewriteFlag = if ($RewriteEnv.IsPresent) { "1" } else { "0" }

if (Test-Path $localArchive) {
    Remove-Item -Force $localArchive
}

Push-Location $projectRoot
try {
    Invoke-Checked -Exe "tar" -Args @(
        "--exclude=.git",
        "--exclude=.venv",
        "--exclude=dist",
        "--exclude=build",
        "--exclude=__pycache__",
        "-czf",
        $localArchive,
        "."
    )
}
finally {
    Pop-Location
}

Write-Host "Archive created: $localArchive"
Invoke-Checked -Exe "scp" -Args @($localArchive, "$ServerUser@$ServerIp`:$remoteArchive")

$remoteScript = @"
set -euo pipefail
rm -rf '$RemoteDir'
mkdir -p '$RemoteDir'
tar -xzf '$remoteArchive' -C '$RemoteDir'
cd '$RemoteDir'
chmod +x scripts/install_server_ubuntu.sh
INSTALL_DIR='$InstallDir' APP_TIMEZONE='$AppTimezone' PORT='$Port' REWRITE_ENV='$rewriteFlag' bash scripts/install_server_ubuntu.sh
systemctl status vacation-registry --no-pager -l | sed -n '1,25p'
"@

Invoke-Checked -Exe "ssh" -Args @("$ServerUser@$ServerIp", $remoteScript)

try {
    Invoke-Checked -Exe "ssh" -Args @("$ServerUser@$ServerIp", "rm -f '$remoteArchive'")
}
catch {
    Write-Warning "Cannot remove remote archive: $remoteArchive"
}

try {
    Remove-Item -Force $localArchive
}
catch {
    Write-Warning "Cannot remove local archive: $localArchive"
}

Write-Host ""
Write-Host "Rebuild completed."
Write-Host "Web URL: http://$ServerIp`:$Port/"
