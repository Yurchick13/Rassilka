param(
    [string]$InstallDir = "$env:LOCALAPPDATA\VacationNotifier",
    [string]$ServerHttpUrl = "http://192.168.76.95:8000",
    [string]$ServerWsUrl = "ws://192.168.76.95:8000/ws/registry",
    [string]$ClientHeartbeatToken = "",
    [string]$UpdateSignerThumbprint = "",
    [string]$UpdateSignerSubject = "",
    [string]$AutoStart = "1",
    [string]$LaunchNow = "1",
    [string]$CreateDesktopShortcut = "0",
    [string]$ConfigureDefenderExclusion = "1"
)

$ErrorActionPreference = "Stop"

function Convert-ToBool {
    param(
        [string]$Value,
        [bool]$DefaultValue = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in @("1", "true", "yes", "y", "on") } { return $true }
        { $_ -in @("0", "false", "no", "n", "off") } { return $false }
        default { return $DefaultValue }
    }
}

$AutoStartEnabled = Convert-ToBool -Value $AutoStart -DefaultValue $true
$LaunchNowEnabled = Convert-ToBool -Value $LaunchNow -DefaultValue $true
$CreateDesktopShortcutEnabled = Convert-ToBool -Value $CreateDesktopShortcut -DefaultValue $false
$ConfigureDefenderExclusionEnabled = Convert-ToBool -Value $ConfigureDefenderExclusion -DefaultValue $true

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Add-DefenderExclusions {
    param(
        [string]$InstallRoot,
        [string]$NotifierExePath
    )

    if (-not $ConfigureDefenderExclusionEnabled) {
        return
    }

    if (-not (Test-IsAdministrator)) {
        Write-Warning "Windows Defender exclusions skipped: run installer as Administrator to add exclusions automatically."
        return
    }

    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Warning "Add-MpPreference not available. Defender exclusions were not configured."
        return
    }

    $exeDir = Split-Path -Parent $NotifierExePath
    $paths = @($InstallRoot, $exeDir) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($pathItem in $paths) {
        try {
            Add-MpPreference -ExclusionPath $pathItem -ErrorAction Stop
        }
        catch {
            Write-Warning "Cannot add Defender exclusion path '$pathItem': $($_.Exception.Message)"
        }
    }

    try {
        Add-MpPreference -ExclusionProcess $NotifierExePath -ErrorAction Stop
    }
    catch {
        Write-Warning "Cannot add Defender exclusion process '$NotifierExePath': $($_.Exception.Message)"
    }
}

function New-ShortcutFile {
    param(
        [string]$Path,
        [string]$TargetPath,
        [string]$WorkingDirectory,
        [string]$Description,
        [string]$Arguments = ""
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = $Description
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $shortcut.Arguments = $Arguments
    }
    $shortcut.Save()
}

function Set-AutoStart {
    param(
        [string]$CommandLine,
        [bool]$Enable
    )

    $runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runValueName = "VacationNotifier"

    if ($Enable) {
        New-Item -Path $runKeyPath -Force | Out-Null
        New-ItemProperty -Path $runKeyPath -Name $runValueName -Value $CommandLine -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
    }
}

function Reset-StartupApprovedState {
    $approvedRunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    $approvedStartupPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"

    Remove-ItemProperty -Path $approvedRunPath -Name "VacationNotifier" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $approvedStartupPath -Name "Vacation Notifier.lnk" -ErrorAction SilentlyContinue
}

function Is-NotifierRunning {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'vacation-notifier.exe' OR Name = 'python.exe' OR Name = 'pythonw.exe' OR Name = 'wscript.exe'"
        foreach ($proc in $procs) {
            if ($proc.Name -ieq "vacation-notifier.exe") {
                return $true
            }
            if ($proc.CommandLine -and ($proc.CommandLine -match "VacationNotifier" -or $proc.CommandLine -match "vacation-notifier" -or $proc.CommandLine -match "redos_notifier\\notifier.py")) {
                return $true
            }
        }
    }
    catch {
    }
    return $false
}

function Stop-NotifierProcesses {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'vacation-notifier.exe' OR Name = 'python.exe' OR Name = 'pythonw.exe' OR Name = 'wscript.exe'"
        foreach ($proc in $procs) {
            $matchesNotifier = $false
            if ($proc.Name -ieq "vacation-notifier.exe") {
                $matchesNotifier = $true
            }
            elseif ($proc.CommandLine -and ($proc.CommandLine -match "VacationNotifier" -or $proc.CommandLine -match "vacation-notifier" -or $proc.CommandLine -match "redos_notifier\\notifier.py")) {
                $matchesNotifier = $true
            }

            if ($matchesNotifier) {
                try {
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                }
                catch {
                }
            }
        }
    }
    catch {
    }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Is-NotifierRunning)) {
            return
        }
        Start-Sleep -Milliseconds 300
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$sourceNotifier = Join-Path $projectRoot "redos_notifier"

if (-not (Test-Path $sourceNotifier)) {
    throw "Cannot find notifier sources near script."
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$targetNotifierDir = Join-Path $InstallDir "redos_notifier"
Stop-NotifierProcesses
if (Test-Path $targetNotifierDir) {
    Remove-Item -Recurse -Force $targetNotifierDir
}
Copy-Item -Path $sourceNotifier -Destination $targetNotifierDir -Recurse -Force

$envLines = @(
    "SERVER_HTTP_URL=$ServerHttpUrl",
    "SERVER_WS_URL=$ServerWsUrl",
    "NOTIFIER_AUTO_UPDATE_ENABLED=1",
    "HEARTBEAT_INTERVAL_SECONDS=60"
)
if (-not [string]::IsNullOrWhiteSpace($ClientHeartbeatToken)) {
    $envLines += "CLIENT_HEARTBEAT_TOKEN=$ClientHeartbeatToken"
}
if (-not [string]::IsNullOrWhiteSpace($UpdateSignerThumbprint)) {
    $envLines += "NOTIFIER_UPDATE_SIGNER_THUMBPRINT=$UpdateSignerThumbprint"
}
if (-not [string]::IsNullOrWhiteSpace($UpdateSignerSubject)) {
    $envLines += "NOTIFIER_UPDATE_SIGNER_SUBJECT=$UpdateSignerSubject"
}
$envLines | Set-Content -Path (Join-Path $InstallDir ".env") -Encoding UTF8

$exePath = Join-Path $targetNotifierDir "windows\vacation-notifier\vacation-notifier.exe"
if (-not (Test-Path $exePath)) {
    throw "Notifier binary not found. Rebuild client installer (onedir bundle) and reinstall."
}
Add-DefenderExclusions -InstallRoot $InstallDir -NotifierExePath $exePath

# Cleanup legacy hidden launcher files from older builds.
Remove-Item -Path (Join-Path $InstallDir "run_notifier.bat") -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $InstallDir "run_notifier_hidden.vbs") -ErrorAction SilentlyContinue

$launcherPath = $exePath
$launcherArgs = ""
$autoStartCommand = "`"$exePath`""

$desktopPath = [Environment]::GetFolderPath("Desktop")
$startMenuPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$startupPath = Join-Path $startMenuPath "Startup"

New-ShortcutFile -Path (Join-Path $startMenuPath "Vacation Notifier.lnk") -TargetPath $launcherPath -Arguments $launcherArgs -WorkingDirectory $InstallDir -Description "Vacation Registry Notifier"

$desktopShortcutPath = Join-Path $desktopPath "Vacation Notifier.lnk"
if ($CreateDesktopShortcutEnabled) {
    New-ShortcutFile -Path $desktopShortcutPath -TargetPath $launcherPath -Arguments $launcherArgs -WorkingDirectory $InstallDir -Description "Vacation Registry Notifier"
}
else {
    Remove-Item -Path $desktopShortcutPath -ErrorAction SilentlyContinue
}

if ($AutoStartEnabled) {
    New-ShortcutFile -Path (Join-Path $startupPath "Vacation Notifier.lnk") -TargetPath $launcherPath -Arguments $launcherArgs -WorkingDirectory $InstallDir -Description "Vacation Registry Notifier (Autostart)"
    Set-AutoStart -CommandLine $autoStartCommand -Enable $true
    Reset-StartupApprovedState
}
else {
    Remove-Item -Path (Join-Path $startupPath "Vacation Notifier.lnk") -ErrorAction SilentlyContinue
    Set-AutoStart -CommandLine $autoStartCommand -Enable $false
    Reset-StartupApprovedState
}

Write-Host "Notifier installer completed."
Write-Host "InstallDir: $InstallDir"
if ($AutoStartEnabled) {
    Write-Host "Autostart: enabled (Startup + HKCU\\Run)"
}
else {
    Write-Host "Autostart: disabled"
}

if ($LaunchNowEnabled) {
    if (-not (Is-NotifierRunning)) {
        Start-Process -FilePath $launcherPath -WorkingDirectory $InstallDir
        Write-Host "Notifier launched now."
    }
    else {
        Write-Host "Notifier is already running."
    }
}
