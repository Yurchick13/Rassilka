param(
    [string]$OutDir = "",
    [string]$IsccPath = "",
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$notifierExe = Join-Path $projectRoot "redos_notifier\windows\vacation-notifier\vacation-notifier.exe"

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

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $projectRoot "dist\windows"
}
$Version = Resolve-Version -RequestedVersion $Version -ProjectRoot $projectRoot

# Build standalone notifier binary so client installer doesn't depend on Python on target machines.
& powershell -ExecutionPolicy Bypass -File (Join-Path $projectRoot "scripts\build_notifier_windows_binary.ps1")
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $notifierExe)) {
    throw "Failed to build bundled notifier binary."
}

if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $candidates = @(
        (Join-Path $projectRoot "tools\innosetup\ISCC.exe"),
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $IsccPath = $candidate
            break
        }
    }
}

if (-not (Test-Path $IsccPath)) {
    throw "ISCC.exe not found. Install Inno Setup 6 or pass -IsccPath."
}

if (Test-Path $OutDir) {
    Get-ChildItem -Path $OutDir -File | Remove-Item -Force
}
else {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$serverIss = Join-Path $projectRoot "packaging\windows\vacation_server_installer.iss"
$notifierIss = Join-Path $projectRoot "packaging\windows\vacation_notifier_installer.iss"

& $IsccPath "/DProjectRoot=$projectRoot" "/DOutDir=$OutDir" "/DMyAppVersion=$Version" $serverIss
if ($LASTEXITCODE -ne 0) { throw "Server installer build failed." }

& $IsccPath "/DProjectRoot=$projectRoot" "/DOutDir=$OutDir" "/DMyAppVersion=$Version" $notifierIss
if ($LASTEXITCODE -ne 0) { throw "Notifier installer build failed." }

Write-Host "Installers built: $OutDir"
