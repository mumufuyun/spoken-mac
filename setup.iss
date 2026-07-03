; Spoken Inno Setup install script
; Generates Windows installer (.exe)
;
; Usage:
;   ISCC setup.iss
;
; Requirements:
;   - Inno Setup 6.x
;   - PyInstaller output: dist\Spoken\ (onedir mode)

#define MyAppName "Spoken"
#define MyAppVersion "1.6.0"
#define MyAppPublisher "Spoken Team"
#define MyAppURL "https://github.com/example/spoken"
#define MyAppExeName "Spoken.exe"

[Setup]
AppId={{8B5C1D7E-9F2A-4E3B-8C1D-5E6F7A8B9C0D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}

DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}

OutputBaseFilename=Spoken-Setup-{#MyAppVersion}
OutputDir=C:\Users\linchen\Desktop\Spoken-Build
SetupIconFile=spoken.ico

Compression=lzma2/max
SolidCompression=yes
LZMAUseSeparateProcess=yes

PrivilegesRequired=admin

WizardStyle=modern
WizardSizePercent=100

UninstallDisplayIcon={app}\spoken.ico
UninstallDisplayName={#MyAppName}

DisableProgramGroupPage=yes
DisableWelcomePage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; onedir 模式：拷贝整个 dist\Spoken\ 目录
Source: "dist\Spoken\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\Spoken\_internal\*"; DestDir: "{app}\_internal"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "spoken.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\spoken.ico"
Name: "{group}\查看配置文件"; Filename: "{win}\explorer.exe"; Parameters: "%APPDATA%\Spoken"
Name: "{group}\{cm:ProgramOnTheWeb,{#MyAppName}}"; Filename: "{#MyAppURL}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\spoken.ico"

[Registry]
Root: HKCU; Subkey: "SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Spoken"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\{#MyAppName}"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/f /im {#MyAppExeName}"; Flags: skipifdoesntexist runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  ExplorerDir: String;
  AppDataPath: String;
begin
  if CurStep = ssPostInstall then
  begin
    // 获取关键路径
    AppDataPath := ExpandConstant('{localappdata}');
    ExplorerDir := AppDataPath + '\Microsoft\Windows\Explorer';
    
    // 1. 删除用户级图标缓存数据库（Windows 10/11）
    Exec('cmd.exe', '/c del /f /q "' + AppDataPath + '\IconCache.db" 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('cmd.exe', '/c del /f /q "' + ExplorerDir + '\iconcache_*.db" 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('cmd.exe', '/c del /f /q "' + ExplorerDir + '\*cache*" 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    
    // 2. 刷新 Windows 图标缓存
    Exec('cmd.exe', '/c ie4uinit.exe -show 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('cmd.exe', '/c ie4uinit.exe -ClearIconCache 2>nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    
    // 3. 通知系统图标关联已更改
    Exec('cmd.exe', '/c powershell -Command "Add-Type -TypeDefinition \''using System; using System.Runtime.InteropServices; public class Shell32 { [DllImport(\"shell32.dll\")] public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2); }\''; [Shell32]::SHChangeNotify(0x08000000, 0, 0, 0)"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    
    // 4. 修复旧版快捷键配置
    Exec('cmd.exe', '/c powershell -Command "$cfg=[System.Environment]::GetFolderPath(''ApplicationData'')+''\Spoken\config.toml''; if(Test-Path $cfg){$c=Get-Content $cfg -Raw -Encoding UTF8; if($c -match ''win\+space''){$c=$c -replace ''win\+space'',''alt+r''; Set-Content $cfg $c -Encoding UTF8 -NoNewline}}"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    
    // 5. 后台延迟重启 Explorer（避免黑屏）— 在10秒后执行，不阻塞安装完成
    Exec('powershell.exe', '-Command "Start-Sleep -Seconds 10; Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; Start-Process explorer.exe"', '', SW_HIDE, ewNoWait, ResultCode);
  end;
end;

function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/f /im {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(500);
  Result := True;
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
end;
