; ---------------------------------------------------------------------------
; WooCommerce Print Agent — Inno Setup installer script
;
; Build with:  iscc installer\print_agent.iss
; (or run tool\build_release.ps1, which builds Flutter and then calls this.)
;
; Design notes:
;  * Per-user install by default (PrivilegesRequired=lowest). The agent needs
;    the interactive desktop session to see the user's printer connections, and
;    it writes only to HKCU, so administrator rights are never required.
;    Pass /ALLUSERS at the command line for a machine-wide deployment.
;  * The running agent is closed before files are replaced, then restarted.
;  * Uninstall leaves %APPDATA% data in place unless the user opts to remove it,
;    so an upgrade-by-reinstall never loses the queue or the pairing.
; ---------------------------------------------------------------------------

#define AppName        "WooCommerce Print Agent"
#define AppShortName   "PrintAgent"
#define AppExeName     "wc_print_agent.exe"
#define AppPublisher   "Your Company"
#define AppURL         "https://example.com"

; The version can be supplied by the build (iscc /DAppVersion=1.2.3), which is
; how CI keeps it in step with pubspec.yaml. The literal below is only the
; fallback for a hand-run `iscc installer\print_agent.iss`.
#ifndef AppVersion
  #define AppVersion   "1.0.0"
#endif
#define BuildDir       "..\build\windows\x64\runner\Release"
#define DataFolderName "WooCommercePrintAgent"

[Setup]
AppId={{8E1C4A62-2F1D-4B77-9C3E-6B0A5D2F91C4}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName}
VersionInfoProductName={#AppName}

DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=no
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline

OutputDir=Output
OutputBaseFilename={#AppShortName}-Setup-{#AppVersion}
SetupIconFile=..\assets\icons\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
MinVersion=10.0.17763
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; \
  Description: "Create a &desktop shortcut"; \
  GroupDescription: "Additional shortcuts:"; \
  Flags: unchecked

Name: "startupicon"; \
  Description: "Start {#AppName} automatically when I sign in"; \
  GroupDescription: "Startup:"

[Files]
; The whole Flutter release output: the executable, flutter_windows.dll,
; the plugin DLLs (sqlite3, printing/pdfium, tray, window manager) and data\.
Source: "{#BuildDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\*.dll";         DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\data\*";        DestDir: "{app}\data"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

; Documentation shipped alongside, so a support engineer on the machine has it.
Source: "..\docs\*.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}\docs"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";  Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; \
  Tasks: desktopicon

[Registry]
; Autostart. The agent also manages this key itself from Settings; the installer
; only seeds it, and the uninstaller always removes it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "WooCommercePrintAgent"; \
  ValueData: """{app}\{#AppExeName}"" --startup"; \
  Flags: uninsdeletevalue; Tasks: startupicon

[Run]
Filename: "{app}\{#AppExeName}"; \
  Description: "Start {#AppName} now"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Only the installed program files; user data is handled in code below.
Type: filesandordirs; Name: "{app}\data"
Type: dirifempty;     Name: "{app}"

[Code]
var
  RemoveDataCheckBox: TNewCheckBox;

function AgentDataDir(): String;
begin
  Result := ExpandConstant('{userappdata}\{#DataFolderName}');
end;

{ Offer to remove the local database, logs and stored credentials on uninstall.
  Default is to keep them, so reinstalling does not force a re-pairing. }
procedure InitializeUninstallProgressForm();
begin
  { nothing to do; the checkbox is created on the confirmation page below }
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Response: Integer;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if DirExists(AgentDataDir()) then
    begin
      Response := MsgBox(
        'Remove the Print Agent''s local data?' + #13#10#13#10 +
        'This deletes the print queue, job history, logs and the stored ' +
        'pairing credentials in:' + #13#10 + AgentDataDir() + #13#10#13#10 +
        'Choose No if you plan to reinstall and want to keep this ' +
        'computer paired with your store.',
        mbConfirmation, MB_YESNO or MB_DEFBUTTON2);
      if Response = IDYES then
        DelTree(AgentDataDir(), True, True, True);
    end;
  end;
end;

{ Warn if an unsupported Windows build slips past MinVersion. }
function InitializeSetup(): Boolean;
begin
  Result := True;
  if not IsWin64 then
  begin
    MsgBox('{#AppName} requires 64-bit Windows 10 (1809) or newer.',
      mbCriticalError, MB_OK);
    Result := False;
  end;
end;
