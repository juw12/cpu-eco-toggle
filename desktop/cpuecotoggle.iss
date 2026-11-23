; CPUEcoToggle for Windows - per-user installer (no admin rights). build.py compiles it with:
;   iscc /DAppVersion=1.0.0 /DSourceDir=<dist\CPUEcoToggle> /DOutputDir=<dist> /DIconFile=<build\cpuecotoggle.ico> cpuecotoggle.iss
; Installs to %LOCALAPPDATA%\Programs\CPUEcoToggle, adds CPUEcoToggle to the Start menu (and optionally the desktop) and lists it
; in Settings > Apps. The window keeps its data (what you saved in it) in %LOCALAPPDATA%\CPUEcoToggle, which
; uninstalling leaves in place so a reinstall finds it again.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "dist\CPUEcoToggle"
#endif
#ifndef OutputDir
  #define OutputDir "dist"
#endif
#ifndef IconFile
  #define IconFile "build\cpuecotoggle.ico"
#endif

[Setup]
AppId={{E81247BA-698B-569E-A6DE-E1E1C366EEFB}
AppName=CPUEcoToggle
AppVersion={#AppVersion}
AppVerName=CPUEcoToggle {#AppVersion}
AppPublisher=Juwen Lie
AppPublisherURL=https://juw12.github.io/cpu-eco-toggle/
AppSupportURL=https://github.com/juw12/cpu-eco-toggle
DefaultDirName={autopf}\CPUEcoToggle
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=CPUEcoToggle-Windows-Setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\CPUEcoToggle.exe
UninstallDisplayName=CPUEcoToggle
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\CPUEcoToggle"; Filename: "{app}\CPUEcoToggle.exe"; Comment: "A Windows tray guard for a pinned CPU"
Name: "{userdesktop}\CPUEcoToggle"; Filename: "{app}\CPUEcoToggle.exe"; Comment: "A Windows tray guard for a pinned CPU"; Tasks: desktopicon

[Run]
Filename: "{app}\CPUEcoToggle.exe"; Description: "{cm:LaunchProgram,CPUEcoToggle}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\CPUEcoToggle.exe"; Parameters: "--stop"; Flags: runhidden waituntilterminated; RunOnceId: "StopCPUEcoToggle"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  { Updating: close an open CPUEcoToggle window first so its files can be replaced. }
  if FileExists(ExpandConstant('{app}\CPUEcoToggle.exe')) then
    Exec(ExpandConstant('{app}\CPUEcoToggle.exe'), '--stop', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
