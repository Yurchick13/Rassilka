param(
    [string]$InstallDir = "$env:LOCALAPPDATA\VacationNotifier"
)

$ErrorActionPreference = "Stop"

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

function Remove-DefenderExclusions {
    param([string]$InstallRoot)

    if (-not (Test-IsAdministrator)) {
        return
    }
    if (-not (Get-Command Remove-MpPreference -ErrorAction SilentlyContinue)) {
        return
    }

    $exePath = Join-Path $InstallRoot "redos_notifier\windows\vacation-notifier\vacation-notifier.exe"
    $exeDir = Split-Path -Parent $exePath
    $pathTargets = @($InstallRoot, $exeDir) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($pathItem in $pathTargets) {
        try {
            Remove-MpPreference -ExclusionPath $pathItem -ErrorAction Stop
        }
        catch {
        }
    }

    try {
        Remove-MpPreference -ExclusionProcess $exePath -ErrorAction Stop
    }
    catch {
    }
}

function Stop-NotifierProcesses {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'vacation-notifier.exe' OR Name = 'python.exe' OR Name = 'pythonw.exe' OR Name = 'wscript.exe'"
        foreach ($proc in $procs) {
            $cmd = [string]$proc.CommandLine
            $isNotifierProcess = $proc.Name -ieq "vacation-notifier.exe" -or
                ($cmd -match "VacationNotifier") -or
                ($cmd -match "vacation-notifier") -or
                ($cmd -match "run_notifier_hidden.vbs") -or
                ($cmd -match "redos_notifier\\notifier.py")

            if ($isNotifierProcess) {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
    }
}

function Remove-AutostartRegistry {
    $runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $approvedRunPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    $approvedStartupPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"

    Remove-ItemProperty -Path $runKeyPath -Name "VacationNotifier" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $approvedRunPath -Name "VacationNotifier" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $approvedStartupPath -Name "Vacation Notifier.lnk" -ErrorAction SilentlyContinue
}

function Remove-Shortcuts {
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $startMenuPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
    $startupPath = Join-Path $startMenuPath "Startup"

    $paths = @(
        (Join-Path $desktopPath "Vacation Notifier.lnk"),
        (Join-Path $startMenuPath "Vacation Notifier.lnk"),
        (Join-Path $startupPath "Vacation Notifier.lnk")
    )

    foreach ($path in $paths) {
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ScheduledTask {
    try {
        & schtasks /Delete /F /TN "VacationNotifier" *> $null
    }
    catch {
    }
}

Stop-NotifierProcesses
Remove-AutostartRegistry
Remove-Shortcuts
Remove-ScheduledTask
Remove-DefenderExclusions -InstallRoot $InstallDir

$cleanupDirs = @(
    $InstallDir,
    "$env:LOCALAPPDATA\vacation-notifier",
    "$env:LOCALAPPDATA\VacationNotifierTest"
)

foreach ($dir in $cleanupDirs) {
    if ([string]::IsNullOrWhiteSpace($dir)) {
        continue
    }
    Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Notifier uninstall cleanup completed."
