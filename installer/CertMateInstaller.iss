; CertMate Inno Setup installer
; Requires Inno Setup (ISCC) to compile into a single EXE on Windows

[Setup]
AppName=CertMate
AppVersion=1.0
DefaultDirName={pf}\CertMate
DefaultGroupName=CertMate
DisableProgramGroupPage=yes
OutputBaseFilename=CertMate-Setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin

; Include the repo files relative to the .iss location (compiled on Windows with this repository checked out)
[Files]
; Copy entire repository into {app}
Source: "..\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs skipifsourcetrmissing

[Icons]
Name: "{group}\CertMate Dashboard"; Filename: "{app}\installer\launch-dashboard.ps1"; WorkingDir: "{app}"

[Run]
; Run the bundled installer PowerShell script after extraction
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File \"{app}\installer\install.ps1\""; StatusMsg: "Running CertMate installer..."; Flags: runascurrentuser

[UninstallRun]
; Run the uninstall script if present
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File \"{app}\installer\uninstall.ps1\""; Flags: runascurrentuser

[Code]
; Nothing custom here — keep installer simple. Compile on Windows with Inno Setup and distributed as an EXE that runs the included install.ps1 to complete the server installation.
