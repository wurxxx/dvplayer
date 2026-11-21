; DVPlayer 的 Inno Setup 安装脚本。
;
; build-release.ps1 用 /D 传入：
;   /DAppVersion=0.1.0
;   /DSourceDir=<payload 绝对路径>
;   /DOutputDir=<输出目录>
;
; 直接编译（调试）：
;   ISCC.exe DvPlayer.iss

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#ifndef SourceDir
  #define SourceDir "..\..\..\out\release\payload"
#endif

#ifndef OutputDir
  #define OutputDir "..\..\..\out\release"
#endif

#ifndef SetupIcon
  #define SetupIcon "..\DvPlayer\Assets\DvPlayer.ico"
#endif

#ifndef VersionInfo
  #define VersionInfo "0.1.0.0"
#endif

[Setup]
AppId={{CDC8E12F-C17E-4205-AB12-A294FE2A8F5B}
AppName=DVPlayer
AppVersion={#AppVersion}
AppVerName=DVPlayer {#AppVersion}
AppPublisher=DvPlayer
DefaultDirName={autopf}\DvPlayer
DefaultGroupName=DVPlayer
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\DvPlayer.exe
UninstallDisplayName=DVPlayer
OutputDir={#OutputDir}
OutputBaseFilename=DvPlayer-{#AppVersion}-win-x64-setup
SetupIconFile={#SetupIcon}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#VersionInfo}
VersionInfoProductName=DVPlayer
VersionInfoDescription=DVPlayer 安装程序

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
CreateDesktopIcon=创建桌面快捷方式
LaunchApp=运行 DVPlayer

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\DVPlayer"; Filename: "{app}\DvPlayer.exe"
Name: "{autodesktop}\DVPlayer"; Filename: "{app}\DvPlayer.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\DvPlayer.exe"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent
