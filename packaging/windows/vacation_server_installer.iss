; Inno Setup script for server installer
#define MyAppName "Vacation Registry Server"
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
AppId={{8F6E97CB-30A5-43AF-8F91-398E1E3D1D10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\VacationRegistryInstallerFiles
DefaultGroupName=Vacation Registry
OutputDir={#OutDir}
OutputBaseFilename=vacation-server-setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
MinVersion=6.1sp1
ArchitecturesAllowed=x86compatible x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Files]
Source: "{#ProjectRoot}\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "__pycache__\*"
Source: "{#ProjectRoot}\requirements.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\.env.example"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\install_server_windows.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Run]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File ""{app}\scripts\install_server_windows.ps1"" -InstallDir ""{autopf}\VacationRegistryServer"""; Flags: runhidden waituntilterminated

[Icons]
Name: "{group}\Open Vacation Registry"; Filename: "http://192.168.76.95:8000/"
