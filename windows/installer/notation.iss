; Inno Setup script for the Windows installer. CI (builds.yml) calls it with
;   iscc /DAppVersion=0.0.2 /DSourceDir=<Release folder> /DOutDir=<where to write> /DRedist=<file name of vc_redist.x64.exe next to this script, or nothing>
; Per-user install by default (no administrator rights); the user may choose "for all users" in the dialog.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef Redist
  #define Redist ""
#endif
#ifndef OutDir
  #define OutDir "."
#endif

[Setup]
; never change this GUID: Windows uses it to find the previous version and update it in place
AppId={{6B0E7C1A-3D55-4B7B-9F0C-2E4A7D1B8C11}
AppName=Notation
AppVersion={#AppVersion}
AppPublisher=Notation contributors
AppPublisherURL=https://github.com/nfa04/notation
DefaultDirName={autopf}\Notation
DefaultGroupName=Notation
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename=Notation-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\notation.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
#if Redist != ""
Source: "{#Redist}"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsVcRedist
#endif

[Icons]
Name: "{autoprograms}\Notation"; Filename: "{app}\notation.exe"
Name: "{autodesktop}\Notation"; Filename: "{app}\notation.exe"; Tasks: desktopicon

[Registry]
; the notation:// links of invitations and device pairing open the app (per user or per machine, as installed)
Root: HKA; Subkey: "Software\Classes\notation"; ValueType: string; ValueData: "URL:Notation"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\notation"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\notation\DefaultIcon"; ValueType: string; ValueData: "{app}\notation.exe,0"
Root: HKA; Subkey: "Software\Classes\notation\shell\open\command"; ValueType: string; ValueData: """{app}\notation.exe"" ""%1"""

[Run]
#if Redist != ""
Filename: "{tmp}\{#Redist}"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing the Visual C++ runtime..."; Check: NeedsVcRedist; Flags: waituntilterminated
#endif
Filename: "{app}\notation.exe"; Description: "Start Notation"; Flags: nowait postinstall skipifsilent

[Code]
// Flutter's Windows runner needs the Visual C++ 2015-2022 runtime; most PCs have it, a fresh one may not.
function NeedsVcRedist: Boolean;
var
  Installed: Cardinal;
begin
  Result := not (RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) and (Installed = 1));
end;
