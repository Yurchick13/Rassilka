param(
    [string]$InstallDir = "C:\Program Files\VacationRegistryServer",
    [string]$Host = "0.0.0.0",
    [int]$Port = 8000,
    [string]$AppTimezone = "Europe/Moscow",
    [string]$DatabaseUrl = "",
    [string]$SessionSecretKey = "",
    [string]$DefaultAdminLogin = "admin",
    [string]$DefaultAdminPassword = "admin12345"
)

$ErrorActionPreference = "Stop"

function Get-PythonInvocation {
    $osVersion = [System.Environment]::OSVersion.Version
    $isWindows7Family = ($osVersion.Major -eq 6 -and $osVersion.Minor -eq 1)

    $launcherVersions = if ($isWindows7Family) {
        @("3.8")
    }
    else {
        @("3.12", "3.11", "3.10", "3.9", "3.8")
    }

    foreach ($version in $launcherVersions) {
        try {
            & py "-$version" -c "import sys; print(sys.executable)" *> $null
            if ($LASTEXITCODE -eq 0) {
                return @{ Exe = "py"; Args = @("-$version") }
            }
        }
        catch {
        }
    }

    foreach ($cmd in @("python", "python3")) {
        try {
            & $cmd -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')" *> $null
            if ($LASTEXITCODE -eq 0) {
                $detected = (& $cmd -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')").Trim()
                if ($isWindows7Family -and $detected -ne "3.8") {
                    throw "Windows 7 requires Python 3.8 for compatibility. Detected: $detected"
                }
                return @{ Exe = $cmd; Args = @() }
            }
        }
        catch {
        }
    }

    if ($isWindows7Family) {
        throw "Python 3.8 not found. Install Python 3.8 first (Windows 7)."
    }

    throw "Python 3.8+ not found. Install Python and re-run installer."
}

function Invoke-CheckedCommand {
    param(
        [string]$Exe,
        [string[]]$Args
    )

    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Exe $($Args -join ' ')"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

if (-not (Test-Path (Join-Path $projectRoot "app"))) {
    throw "Cannot find app sources near script."
}

$python = Get-PythonInvocation

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

foreach ($entry in @("app", "requirements.txt", ".env.example")) {
    $src = Join-Path $projectRoot $entry
    if (-not (Test-Path $src)) {
        continue
    }

    $dst = Join-Path $InstallDir $entry
    if (Test-Path $dst) {
        Remove-Item -Recurse -Force $dst
    }
    Copy-Item -Path $src -Destination $dst -Recurse -Force
}

$venvDir = Join-Path $InstallDir ".venv"
if (Test-Path $venvDir) {
    Remove-Item -Recurse -Force $venvDir
}

Invoke-CheckedCommand -Exe $python.Exe -Args ($python.Args + @("-m", "venv", $venvDir))

$pipExe = Join-Path $venvDir "Scripts\pip.exe"
Invoke-CheckedCommand -Exe $pipExe -Args @("install", "--upgrade", "pip")
Invoke-CheckedCommand -Exe $pipExe -Args @("install", "-r", (Join-Path $InstallDir "requirements.txt"))

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    $dbPath = ($InstallDir -replace "\\", "/")
    $DatabaseUrl = "sqlite:///$dbPath/vacations.db"
}

if ([string]::IsNullOrWhiteSpace($SessionSecretKey)) {
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $SessionSecretKey = [Convert]::ToBase64String($bytes)
}

@"
APP_TIMEZONE=$AppTimezone
DATABASE_URL=$DatabaseUrl
SESSION_SECRET_KEY=$SessionSecretKey
SESSION_COOKIE_NAME=vacation_session
SESSION_HTTPS_ONLY=0
DEFAULT_ADMIN_LOGIN=$DefaultAdminLogin
DEFAULT_ADMIN_PASSWORD=$DefaultAdminPassword
"@ | Set-Content -Path (Join-Path $InstallDir ".env") -Encoding UTF8

$runBatPath = Join-Path $InstallDir "run_server.bat"
@"
@echo off
cd /d "$InstallDir"
for /f "usebackq tokens=* delims=" %%i in (`type ".env"`) do set %%i
"$venvDir\Scripts\python.exe" -m uvicorn app.main:app --host $Host --port $Port
"@ | Set-Content -Path $runBatPath -Encoding ASCII

try {
    & schtasks /Create /F /TN "VacationRegistryServer" /TR "\"$runBatPath\"" /SC ONSTART /RU SYSTEM /RL HIGHEST | Out-Null
}
catch {
    Write-Warning "Cannot create startup task automatically. Run as Administrator if needed."
}

try {
    & netsh advfirewall firewall add rule name="VacationRegistryAPI_$Port" dir=in action=allow protocol=TCP localport=$Port | Out-Null
}
catch {
    Write-Warning "Cannot add firewall rule automatically."
}

Write-Host "Server installer completed."
Write-Host "InstallDir: $InstallDir"
Write-Host "Start now: $runBatPath"
Write-Host "Open in browser: http://192.168.76.95:$Port/"
