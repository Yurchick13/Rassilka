; Inno Setup script for notifier installer
#define MyAppName "Vacation Registry Notifier"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#ifndef ProjectRoot
  #error ProjectRoot define is required
#endif

#ifndef OutDir
  #define OutDir "."
#endif

[Setup]
AppId={{C44C4AF9-2469-4D03-B1F8-BE566470BF8B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\VacationNotifierInstallerFiles
DefaultGroupName=Vacation Registry
OutputDir={#OutDir}
OutputBaseFilename=vacation-notifier-setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest
MinVersion=6.1sp1
ArchitecturesAllowed=x86compatible x64compatible
WizardStyle=modern

[Files]
Source: "{#ProjectRoot}\redos_notifier\*"; DestDir: "{app}\redos_notifier"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "__pycache__\*"
Source: "{#ProjectRoot}\scripts\install_notifier_windows.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\uninstall_notifier_windows.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Run]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\scripts\install_notifier_windows.ps1"" -InstallDir ""{localappdata}\VacationNotifier"" -AutoStart 1 -LaunchNow 1 -CreateDesktopShortcut 0 -ConfigureDefenderExclusion 1"; Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\scripts\uninstall_notifier_windows.ps1"" -InstallDir ""{localappdata}\VacationNotifier"""; Flags: runhidden waituntilterminated
