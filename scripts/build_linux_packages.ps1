param(
    [string]$Version = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

function Ensure-Nfpm {
    param([string]$ProjectRoot)

    $toolsDir = Join-Path $ProjectRoot "tools\nfpm"
    $nfpmExe = Join-Path $toolsDir "nfpm.exe"
    if (Test-Path $nfpmExe) {
        return $nfpmExe
    }

    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/goreleaser/nfpm/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like "*_Windows_x86_64.zip" } | Select-Object -First 1
    if (-not $asset) {
        throw "Cannot find Windows nfpm asset in latest release"
    }

    $zipPath = Join-Path $toolsDir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $toolsDir -Force
    Remove-Item $zipPath -Force

    if (-not (Test-Path $nfpmExe)) {
        throw "nfpm.exe was not extracted"
    }

    return $nfpmExe
}

function Resolve-Version {
    param(
        [string]$RequestedVersion,
        [string]$ProjectRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
        return $RequestedVersion.Trim()
    }

    $versionFile = Join-Path $ProjectRoot "redos_notifier\VERSION"
    if (Test-Path $versionFile) {
        $value = (Get-Content $versionFile -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return "1.0.0"
}

function New-StageTree {
    param([string]$ProjectRoot)

    $staging = Join-Path $ProjectRoot "dist\staging"
    if (Test-Path $staging) {
        Remove-Item -Recurse -Force $staging
    }

    $serverRoot = Join-Path $staging "server"
    $notifierRoot = Join-Path $staging "notifier"

    New-Item -ItemType Directory -Path (Join-Path $serverRoot "opt\vacation-registry") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $serverRoot "etc\systemd\system") -Force | Out-Null

    Copy-Item -Path (Join-Path $ProjectRoot "app") -Destination (Join-Path $serverRoot "opt\vacation-registry\app") -Recurse -Force
    Copy-Item -Path (Join-Path $ProjectRoot "requirements.txt") -Destination (Join-Path $serverRoot "opt\vacation-registry\requirements.txt") -Force
    Copy-Item -Path (Join-Path $ProjectRoot ".env.example") -Destination (Join-Path $serverRoot "opt\vacation-registry\.env.example") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "deploy\systemd\vacation-registry.service") -Destination (Join-Path $serverRoot "etc\systemd\system\vacation-registry.service") -Force

    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "opt\vacation-notifier") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "usr\bin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "usr\lib\systemd\user") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "usr\lib\systemd\system") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "usr\libexec") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "usr\share\applications") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "etc\xdg\autostart") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $notifierRoot "etc") -Force | Out-Null

    $linuxNotifierDst = Join-Path $notifierRoot "opt\vacation-notifier\redos_notifier"
    New-Item -ItemType Directory -Path $linuxNotifierDst -Force | Out-Null
    Copy-Item -Path (Join-Path $ProjectRoot "redos_notifier\notifier.py") -Destination (Join-Path $linuxNotifierDst "notifier.py") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "redos_notifier\VERSION") -Destination (Join-Path $linuxNotifierDst "VERSION") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "redos_notifier\requirements.txt") -Destination (Join-Path $linuxNotifierDst "requirements.txt") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "redos_notifier\requirements.txt") -Destination (Join-Path $notifierRoot "opt\vacation-notifier\requirements.txt") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\vacation-notifier") -Destination (Join-Path $notifierRoot "usr\bin\vacation-notifier") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\redos-notifier.service") -Destination (Join-Path $notifierRoot "usr\lib\systemd\user\redos-notifier.service") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\vacation-notifier-updater") -Destination (Join-Path $notifierRoot "usr\libexec\vacation-notifier-updater") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\vacation-notifier-updater.service") -Destination (Join-Path $notifierRoot "usr\lib\systemd\system\vacation-notifier-updater.service") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\vacation-notifier-updater.timer") -Destination (Join-Path $notifierRoot "usr\lib\systemd\system\vacation-notifier-updater.timer") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\vacation-notifier.desktop") -Destination (Join-Path $notifierRoot "usr\share\applications\vacation-notifier.desktop") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\vacation-notifier-autostart.desktop") -Destination (Join-Path $notifierRoot "etc\xdg\autostart\vacation-notifier.desktop") -Force
    Copy-Item -Path (Join-Path $ProjectRoot "packaging\templates\vacation-notifier.env.example") -Destination (Join-Path $notifierRoot "etc\vacation-notifier.env.example") -Force
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $projectRoot "dist\packages"
}

$Version = Resolve-Version -RequestedVersion $Version -ProjectRoot $projectRoot

if (Test-Path $OutDir) {
    Get-ChildItem -Path $OutDir -File | Remove-Item -Force
}
else {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$nfpmExe = Ensure-Nfpm -ProjectRoot $projectRoot
New-StageTree -ProjectRoot $projectRoot

$serverConfigTpl = Get-Content (Join-Path $projectRoot "packaging\nfpm\server.yaml") -Raw
$notifierConfigTpl = Get-Content (Join-Path $projectRoot "packaging\nfpm\notifier.yaml") -Raw

$serverConfig = Join-Path $projectRoot "dist\server.nfpm.yaml"
$notifierConfig = Join-Path $projectRoot "dist\notifier.nfpm.yaml"

($serverConfigTpl -replace "version: 1.0.0", "version: $Version") | Set-Content -Path $serverConfig -Encoding UTF8
($notifierConfigTpl -replace "version: 1.0.0", "version: $Version") | Set-Content -Path $notifierConfig -Encoding UTF8

& $nfpmExe package --config $serverConfig --packager deb --target (Join-Path $OutDir "vacation-registry-server_${Version}_amd64.deb")
if ($LASTEXITCODE -ne 0) { throw "Failed to build server deb" }

& $nfpmExe package --config $serverConfig --packager rpm --target (Join-Path $OutDir "vacation-registry-server-${Version}-1.x86_64.rpm")
if ($LASTEXITCODE -ne 0) { throw "Failed to build server rpm" }

$notifierDeb = Join-Path $OutDir "vacation-registry-notifier_${Version}_amd64.deb"
$notifierRpm = Join-Path $OutDir "vacation-registry-notifier-${Version}-1.x86_64.rpm"

& $nfpmExe package --config $notifierConfig --packager deb --target $notifierDeb
if ($LASTEXITCODE -ne 0) { throw "Failed to build notifier deb" }

& $nfpmExe package --config $notifierConfig --packager rpm --target $notifierRpm
if ($LASTEXITCODE -ne 0) { throw "Failed to build notifier rpm" }

# Stable filenames for auto-update URLs (no URL change required between versions).
Copy-Item -Path $notifierDeb -Destination (Join-Path $OutDir "vacation-registry-notifier_latest_amd64.deb") -Force
Copy-Item -Path $notifierRpm -Destination (Join-Path $OutDir "vacation-registry-notifier-latest.x86_64.rpm") -Force

Write-Host "Packages built in: $OutDir"
