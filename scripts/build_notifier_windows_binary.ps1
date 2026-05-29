param(
    [string]$Python = "py -3",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $projectRoot "redos_notifier\windows"
}

$targetBundleDir = Join-Path $OutDir "vacation-notifier"
$targetExe = Join-Path $targetBundleDir "vacation-notifier.exe"
$buildRoot = Join-Path $projectRoot "build\pyinstaller-notifier"
$legacyOneFileExe = Join-Path $projectRoot "redos_notifier\vacation-notifier.exe"

if (Test-Path $buildRoot) {
    Remove-Item -Recurse -Force $buildRoot
}
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

if (Test-Path $targetBundleDir) {
    Remove-Item -Recurse -Force $targetBundleDir
}
if (Test-Path $legacyOneFileExe) {
    Remove-Item -Force $legacyOneFileExe
}

$pythonCmd = $Python.Split(' ')[0]
$pythonArgs = @()
if ($Python.Contains(' ')) {
    $pythonArgs = $Python.Substring($pythonCmd.Length).Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
}

$pyInstallerAvailable = $false
& $pythonCmd @pythonArgs -m PyInstaller --version *> $null
if ($LASTEXITCODE -eq 0) {
    $pyInstallerAvailable = $true
}

if (-not $pyInstallerAvailable) {
    & $pythonCmd @pythonArgs -m pip install pyinstaller
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install pyinstaller. Install it manually or provide internet access."
    }
}

$entryScript = Join-Path $projectRoot "redos_notifier\notifier.py"
$distDir = Join-Path $buildRoot "dist"
$workDir = Join-Path $buildRoot "work"
$specDir = Join-Path $buildRoot "spec"

& $pythonCmd @pythonArgs -m PyInstaller `
  --noconfirm `
  --clean `
  --onedir `
  --windowed `
  --name vacation-notifier `
  --distpath $distDir `
  --workpath $workDir `
  --specpath $specDir `
  $entryScript

if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed" }

Copy-Item -Path (Join-Path $distDir "vacation-notifier") -Destination $targetBundleDir -Recurse -Force
Copy-Item -Path (Join-Path $projectRoot "redos_notifier\VERSION") -Destination (Join-Path $targetBundleDir "VERSION") -Force

if (-not (Test-Path $targetExe)) {
    throw "Notifier binary not found after build: $targetExe"
}

Write-Host "Built bundle: $targetBundleDir"
