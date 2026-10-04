; TaraxacumDraw Windows 安装包脚本（Inno Setup 6）
; 编译：ISCC.exe windows\packaging\setup.iss
; 输出：dist\TaraxacumDraw-Setup-1.0.0-windows-x64.exe

[Setup]
AppId={{7C1E5A90-6D2B-4E8A-9C3F-1A2B3C4D5E6F}}
AppName=TaraxacumDraw
AppVersion=1.0.0
AppPublisher=TaraxacumDraw Project
DefaultDirName={autopf}\TaraxacumDraw
DefaultGroupName=TaraxacumDraw
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=TaraxacumDraw-Setup-1.0.0-windows-x64
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\TaraxacumDraw"; Filename: "{app}\taraxacum_draw.exe"
Name: "{group}\Uninstall TaraxacumDraw"; Filename: "{uninstallexe}"
Name: "{autodesktop}\TaraxacumDraw"; Filename: "{app}\taraxacum_draw.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\taraxacum_draw.exe"; Description: "{cm:LaunchProgram,TaraxacumDraw}"; Flags: nowait postinstall skipifsilent
