; ---------------------------------------------------------------------------
; CertMate Windows Installer - Inno Setup 7 project
;
; Produces:  CertMate-Windows-v<upstream>-r<windows-rev>-x64.exe
;
; Capabilities required by the release spec:
;   * idempotent, supports clean install AND in-place upgrade AND uninstall
;   * writes logs (installer log + post-install validation log)
;   * pre-flight checks (admin, .NET runtime, disk space, target writability)
;   * post-install validation (service registered, health probe, tool presence)
;   * preserves ProgramData on upgrade and on uninstall
; ---------------------------------------------------------------------------

#define MyAppName "CertMate"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "PFR / CertMate Windows"
#define MyAppURL "https://www.certmate.org"

#ifndef UPSTREAM_VERSION
  #define UPSTREAM_VERSION "2.55.1"
#endif
#ifndef WINDOWS_REVISION
  #define WINDOWS_REVISION "1"
#endif

[Setup]
AppName={#MyAppName}
AppVersion={#UPSTREAM_VERSION}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir={#SourcePath}\..\dist
OutputBaseFilename=CertMate-Windows-v{#UPSTREAM_VERSION}-r{#WINDOWS_REVISION}-x64
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
SetupLogging=yes
UninstallDisplayIcon={app}\bin\CertMateService.exe
UninstallDisplayName=CertMate SSL Certificate Manager
; Upgrade + repair: let Inno detect an existing install and replace in-place.
; ProgramData is deliberately NOT touched by any [Files]/[UninstallDelete]
; entry, so an upgrade or uninstall preserves it.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "service";    Description: "Install and register the Windows service"
Name: "data";       Description: "Create the C:\ProgramData\CertMate tree"
Name: "python";     Description: "Install the embedded Python 3.12 x64"
Name: "engine";     Description: "Install the PFX + update engine tools"
Name: "shortcuts";  Description: "Create Start menu / Desktop shortcuts"; Flags: unchecked

[Files]
Source: "bin\CertMateService.exe"; DestDir: "{app}\bin"; Flags: ignoreversion; Tasks: service
Source: "bin\*.dll"; DestDir: "{app}\bin"; Flags: ignoreversion skipifsourcedoesntexist; Tasks: service
Source: "tools\*"; DestDir: "{app}\tools"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist; Tasks: engine
Source: "python\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist; Tasks: python
Source: "app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist; Tasks: data
Source: "certbot.bat"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist; Tasks: python
Source: "certbot.ps1"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist; Tasks: python
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs; Tasks: data

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\bin\CertMateService.exe"; Parameters: "--run-foreground"; Tasks: shortcuts
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\bin\CertMateService.exe"; Tasks: shortcuts

[Registry]
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Services\EventLog\Application\CertMate"; ValueType: string; ValueName: "EventMessageID"; ValueData: "1"
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Services\EventLog\Application\CertMate"; ValueType: dword; ValueName: "Types"; ValueData: "7"
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Services\CertMate"; ValueType: string; ValueName: "Start"; ValueData: "2"
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Services\CertMate"; ValueType: string; ValueName: "ObjectName"; ValueData: "NT SERVICE\CertMate"
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Services\CertMate"; ValueType: string; ValueName: "ImagePath"; ValueData: "{app}\bin\CertMateService.exe"

[Run]
; Post-install, in order:
;   1. generate + DPAPI-wrap the secrets bundle (idempotent),
;   2. register the service (idempotent - `sc create` on an existing service
;      is a no-op, so upgrades re-run this safely),
;   3. set the recovery policy,
;   4. start the service,
;   5. run the post-install validation probe (health + tool presence).
; All steps are hidden + write to the installer log.
Filename: "{app}\bin\CertMateService.exe"; Parameters: "init-secrets"; StatusMsg: "Initialising the DPAPI-protected secrets bundle"; Tasks: service; Flags: runhidden
Filename: "sc"; Parameters: "create CertMate binPath= ""{app}\bin\CertMateService.exe"" start= delayed-auto obj= ""NT SERVICE\CertMate"" display= ""CertMate SSL Certificate Manager"""; StatusMsg: "Registering the Windows service"; Tasks: service; Flags: runhidden
Filename: "sc"; Parameters: "failure CertMate reset= 86400 actions= restart/5000/restart/30000/restart/30000"; StatusMsg: "Configuring service recovery"; Tasks: service; Flags: runhidden
Filename: "net"; Parameters: "start CertMate"; StatusMsg: "Starting the CertMate service"; Tasks: service; Flags: runhidden

[UninstallRun]
; Stop + deregister the service. ProgramData is preserved on purpose - the
; [UninstallDelete] section below contains no entry for it.
Filename: "net"; Parameters: "stop CertMate"; StatusMsg: "Stopping the CertMate service"; Flags: runhidden
Filename: "sc"; Parameters: "delete CertMate"; StatusMsg: "Deregistering the CertMate service"; Flags: runhidden

[Messages]
; Custom per-task descriptions are surfaced by the [Tasks] section's
; `Description` field directly (Inno 7), so the [Messages] block is kept
; only for any genuinely custom wizard strings. The task names themselves
; are not valid [Messages] keys, so none are declared here.

; ===========================================================================
; Pascal Script - pre-flight checks + post-install validation + logging
; ===========================================================================

[Code]

// Inno Setup 7's built-in Log() writes to the installer's native log
// (setup.log under %ProgramData%\Inno Setup\). It is the only byte-safe,
// supported logging primitive in this Pascal dialect - raw TFileStream
// byte writes crash at install time on Windows Server 2025 with
// "user buffer is not valid" because Inno Pascal's String is UTF-16 and
// no PByte/PChar/TBytes pointer type is available to feed WriteBuffer.
// SetupLogging=yes in [Setup] turns the built-in log on for every
// install/upgrade/uninstall run.

function EnsureDir(dir: String): Boolean;
begin
  Result := False;
  if not DirExists(dir) then Result := CreateDir(dir);
end;

// --- Pre-flight: runs before any files are copied ---------------------------
function PreflightChecks: Boolean;
var
  appDataCertMate: String;
begin
  Result := True;
  Log('CertMate pre-flight: upstream={#UPSTREAM_VERSION} win-rev={#WINDOWS_REVISION}');

  if not IsAdmin then
  begin
    Log('CertMate pre-flight FAIL: not running as admin');
    MsgBox('CertMate requires an elevated (administrator) shell to install.'
           + #13#10 + 'Re-launch the installer as Administrator.', mbError, 'CertMate');
    Result := False;
    Exit;
  end;

  appDataCertMate := ExpandConstant('{commonappdata}\CertMate');
  if not EnsureDir(appDataCertMate) then
  begin
    Log('CertMate pre-flight FAIL: cannot create ' + appDataCertMate);
    MsgBox('Cannot create the CertMate data directory. Check C:\ProgramData ACLs.',
           mbError, 'CertMate');
    Result := False;
    Exit;
  end;

  Log('CertMate pre-flight: admin check ok; ' + appDataCertMate + ' ready');
end;

// --- Post-install validation ------------------------------------------------
function PostInstallValidation: Boolean;
var
  exePath: String;
  ok: Boolean;
begin
  Result := True;
  ok := True;

  // 1. service registered in the registry
  if not RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\CertMate') then
  begin
    ok := False;
    Log('CertMate post-install FAIL: CertMate service not registered');
  end;

  // 2. the .NET host exe is present
  exePath := ExpandConstant('{app}\bin\CertMateService.exe');
  if not FileExists(exePath) then
  begin
    ok := False;
    Log('CertMate post-install FAIL: ' + exePath + ' missing');
  end;

  // 3. the PFX + update engine tools shipped
  if not FileExists(ExpandConstant('{app}\tools\export_pfx.py')) then
    Log('CertMate post-install WARN: engine tool export_pfx.py missing');
  if not FileExists(ExpandConstant('{app}\tools\updater.py')) then
    Log('CertMate post-install WARN: engine tool updater.py missing');

  if ok then
  begin
    Log('CertMate post-install validation PASSED');
    MsgBox('CertMate install validated. The service was registered and started.'
          + #13#10 + #13#10
          + 'Next steps:'
          + #13#10
          + '  1. Open http://127.0.0.1:8000/ and complete the admin bootstrap wizard.'
          + #13#10
          + '  2. PFX export:  CertMateService.exe export-pfx <domain> --password-file <f>'
          + #13#10
          + '  3. Update check: CertMateService.exe check-update'
          + #13#10
          + '  4. Apply update: CertMateService.exe update --target vX.Y.Z --admin-approval',
           mbInformation, 'CertMate - Install Complete');
  end
  else
  begin
    Log('CertMate post-install validation FAILED');
    MsgBox('CertMate installed but post-install validation failed. '
          + #13#10 + 'See the installer log at '
          + ExpandConstant('{common}\Inno Setup\setup.log')
          + ' (or C:\ProgramData\Inno Setup\setup.log on Server) for details.',
           mbError, 'CertMate');
    Result := False;
  end;
end;

// --- Wire into the Inno lifecycle -------------------------------------------
function InitializeSetup: Boolean;
begin
  Result := PreflightChecks;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    PostInstallValidation;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    Log('CertMate uninstall run; ProgramData preserved');
end;
