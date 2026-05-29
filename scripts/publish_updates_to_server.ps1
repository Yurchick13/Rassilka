param(
    [string]$ServerIp = "192.168.76.95",
    [string]$ServerUser = "root",
    [int]$ServerPort = 22,
    [string]$RemoteUpdatesDir = "/opt/vacation-registry/app/static/updates",
    [string]$PackagesDir = "",
    [string]$WindowsDir = "",
    [switch]$UseSudo
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )

    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Exe $($Arguments -join ' ')"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

if ([string]::IsNullOrWhiteSpace($PackagesDir)) {
    $PackagesDir = Join-Path $projectRoot "dist\packages"
}
if ([string]::IsNullOrWhiteSpace($WindowsDir)) {
    $WindowsDir = Join-Path $projectRoot "dist\windows"
}

try {
    $sshExe = (Get-Command "ssh.exe" -ErrorAction Stop).Source
    $scpExe = (Get-Command "scp.exe" -ErrorAction Stop).Source
}
catch {
    throw "OpenSSH client not found (ssh.exe/scp.exe). Install OpenSSH client and retry."
}

$artifacts = @(
    @{ local = (Join-Path $WindowsDir "vacation-notifier-setup.exe"); remote = "vacation-notifier-setup.exe" },
    @{ local = (Join-Path $PackagesDir "vacation-registry-notifier_latest_amd64.deb"); remote = "vacation-registry-notifier_latest_amd64.deb" },
    @{ local = (Join-Path $PackagesDir "vacation-registry-notifier-latest.x86_64.rpm"); remote = "vacation-registry-notifier-latest.x86_64.rpm" }
)

foreach ($artifact in $artifacts) {
    if (-not (Test-Path $artifact.local)) {
        throw "File not found: $($artifact.local). Build installers first."
    }
}

$sshTarget = "$ServerUser@$ServerIp"
$scpTargetBase = "$sshTarget`:/tmp"

foreach ($artifact in $artifacts) {
    $tmpName = "vacation-update-$($artifact.remote)"
    Invoke-Checked -Exe $scpExe -Arguments @("-P", "$ServerPort", $artifact.local, "$scpTargetBase/$tmpName")
}

$sudo = ""
if ($UseSudo.IsPresent -or $ServerUser -ne "root") {
    $sudo = "sudo "
}

$remoteScript = @"
set -euo pipefail
${sudo}mkdir -p '$RemoteUpdatesDir'
${sudo}install -m 0644 '/tmp/vacation-update-vacation-notifier-setup.exe' '$RemoteUpdatesDir/vacation-notifier-setup.exe'
${sudo}install -m 0644 '/tmp/vacation-update-vacation-registry-notifier_latest_amd64.deb' '$RemoteUpdatesDir/vacation-registry-notifier_latest_amd64.deb'
${sudo}install -m 0644 '/tmp/vacation-update-vacation-registry-notifier-latest.x86_64.rpm' '$RemoteUpdatesDir/vacation-registry-notifier-latest.x86_64.rpm'
rm -f '/tmp/vacation-update-vacation-notifier-setup.exe' \
      '/tmp/vacation-update-vacation-registry-notifier_latest_amd64.deb' \
      '/tmp/vacation-update-vacation-registry-notifier-latest.x86_64.rpm'
"@

Invoke-Checked -Exe $sshExe -Arguments @("-p", "$ServerPort", $sshTarget, $remoteScript)

Write-Host ""
Write-Host "Update files uploaded:"
Write-Host "  http://$ServerIp`:8000/static/updates/vacation-notifier-setup.exe"
Write-Host "  http://$ServerIp`:8000/static/updates/vacation-registry-notifier_latest_amd64.deb"
Write-Host "  http://$ServerIp`:8000/static/updates/vacation-registry-notifier-latest.x86_64.rpm"
Write-Host ""
Write-Host "Tip: in Admin -> Auto-update, leave URL fields empty to use these default /static/updates links automatically."
