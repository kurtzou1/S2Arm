; SPDX-License-Identifier: Apache-2.0
; Copyright 2026 S2Arm contributors
;
; S2Arm Windows 安装程序（v0.3.0 起；Inno Setup 6.7，钉版见 installer.json）。
; 编译（Windows 出包机，发版脚本调）：ISCC.exe /DSourceDir=<解开的 S2Arm 目录> /DAppVersion=<0.3.0> /O<输出目录> S2Arm.iss
; 要解决的问题（不是为了好看）：
;   ① 解压位置太深撞长路径（#205、#461）→ 固定装到 %LOCALAPPDATA%\Programs\S2Arm（只装给当前用户、免管理员）。
;      包内最深相对路径 139 字符，加上这个位置（20 字符用户名约 60）约 200，低于作业层长路径处理阈值 240（pack/orch/winlong.py）。
;   ② 玩家在压缩包里直接双击 exe → 只有一个安装程序文件。
;   ③ 系统解压上万个小文件慢、下载标记传给每个文件 → 固实压缩整包一次解开，下载标记只在安装程序这一个文件上。
;   ④ 没有开始菜单入口、卸载只能手删 → 开始菜单 + 桌面图标，「设置 → 应用」里能卸载。
; 和现有机制的衔接：
;   - 只换壳更新：更新器（pack/jobs/updater.py）把安装目录整个改名换新（.s2arm-old / .s2arm-new），所以卸载程序放在安装目录外
;     （UninstallFilesDir），卸载按目录整删程序目录（更新后新增的文件不在安装记录里）。
;   - 数据都不在程序目录：私有目录 %LOCALAPPDATA%\S2Arm\WindowsLauncher、游戏库在玩家选的位置。卸载不碰它们。

#ifndef SourceDir
  #error 用 /DSourceDir=<解开的 S2Arm 目录> 指定要装的文件
#endif
#ifndef AppVersion
  #error 用 /DAppVersion=<版本号，如 0.3.0> 指定版本
#endif

[Setup]
; AppId 定下就不能改：卸载信息、升级识别都靠它
AppId={{E44C11E8-9CDE-42B0-BBF0-619FA69156F2}
AppName=S2Arm
AppVersion={#AppVersion}
AppVerName=S2Arm {#AppVersion}
AppPublisher=S2Arm contributors
AppPublisherURL=https://s2arm.com
AppSupportURL=https://github.com/jhaizhou-ops/S2Arm/issues
AppUpdatesURL=https://s2arm.com
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\S2Arm
PrivilegesRequired=lowest
; Inno Setup 6.7 起缺省给 Setup 自己开 Windows 的 RedirectionGuard（不让穿过普通用户建的目录联接 / 符号链接），
;   PrivilegesRequired=lowest 时会被 [Run] postinstall 拉起的进程继承（官方 whatsnew 写明，Inno 7 才修）：从完成页「现在打开 S2Arm」打开的
;   启动器和它起的出包作业都带着它，出包走的短路径入口（%LOCALAPPDATA%\S2A\j 下的目录联接）一碰就 WinError 448，每次出 iPhone 包必红。
;   我们按用户安装、不提权，这个防护防的提权攻击与我们无关；Setup 本来也不给装出来的应用开它，这里只关掉继承的副作用
RedirectionGuard=no
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableWelcomePage=yes
UninstallFilesDir={localappdata}\S2Arm\Uninstall
UninstallDisplayName=S2Arm
UninstallDisplayIcon={app}\S2Arm.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
#ifdef Fast
; 只给调界面用（ISCC /DFast）：不压缩，编得快；发版不带
Compression=none
#else
Compression=lzma2/max
SolidCompression=yes
#endif
OutputBaseFilename=S2Arm-windows-x64-setup
SetupIconFile=..\launcher\App\Assets\S2Arm.ico
WizardStyle=modern dark hidebevels includetitlebar
WizardSmallImageFile=
; 窗口底色同 DMG 新窗口与示意图（深黑）；设了底色后各面板透明，卡片 / 按钮 / 复选框都是自画素材（make_header.py）
WizardBackColor=#111113
CloseApplications=yes
RestartApplications=no
ShowLanguageDialog=no

[Languages]
Name: "zh"; MessagesFile: "compiler:Default.isl,zh-Hans.isl"

[Files]
Source: "header.bmp"; Flags: dontcopy
Source: "card.bmp"; Flags: dontcopy
Source: "bar.bmp"; Flags: dontcopy
Source: "track.bmp"; Flags: dontcopy
Source: "btn_install.bmp"; Flags: dontcopy
Source: "btn_finish.bmp"; Flags: dontcopy
Source: "btn_cancel.bmp"; Flags: dontcopy
Source: "check_on.bmp"; Flags: dontcopy
Source: "check_off.bmp"; Flags: dontcopy
Source: "bg.bmp"; Flags: dontcopy
Source: "dir_holders.ps1"; Flags: dontcopy
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; 重装 / 用安装程序升级：先清掉上一版的程序目录（只清安装包本身的几样，不碰玩家放进来的别的东西），免得旧版多出来的文件留在新版里
Type: filesandordirs; Name: "{app}\Engine"
Type: filesandordirs; Name: "{app}\Runtime"
Type: filesandordirs; Name: "{app}\Shell"
Type: filesandordirs; Name: "{app}\Fonts"
Type: filesandordirs; Name: "{app}\ThirdParty"
Type: filesandordirs; Name: "{app}\skill"

[Icons]
Name: "{userprograms}\S2Arm"; Filename: "{app}\S2Arm.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\S2Arm"; Filename: "{app}\S2Arm.exe"; WorkingDir: "{app}"; Check: WantDesktopIcon

[Run]
Filename: "{app}\S2Arm.exe"; WorkingDir: "{app}"; Description: "现在打开 S2Arm / Launch S2Arm now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 只删程序：安装目录整删（换壳更新后新增的文件不在安装记录里），连同更新器换壳留下的 .s2arm-old / .s2arm-new
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{app}.s2arm-old"
Type: filesandordirs; Name: "{app}.s2arm-new"

[Code]
{ 界面照 DMG 新窗口与已通过的示意图：深黑底、S2ARM 字标、奶油色进度 / 主按钮 / 勾选、圆角卡片、中英两句。素材由 make_header.py 生成（底色 #111113） }
const
  Ink = $EBF0F2;        { #F2F0EB }
  Muted = $9E9696;      { #96969E }
  Cream = $D6EAF5;      { #F5EAD6 }
  SlideMs = 3500;       { 轮播几秒换一张 }

var
  DesktopOn, LaunchOn: Boolean;
  DesktopImg, LaunchImg: TBitmapImage;
  PrimaryImg, FinishImg, SecondaryImg: TBitmapImage;
  BtnRight, BtnMid: Integer;
  BtnPanel: TPanel;
  WelcomePageID: Integer;
  PathText: TNewStaticText;
  SlideTitle, SlideSub, SlideDots: TNewStaticText;
  Bar: TBitmapImage;
  BarWidth, SlideIndex, SlideTimer: Integer;
  SlideCn, SlideEn: array of String;
  FinishedBuilt: Boolean;

function SetTimer(hWnd: LongWord; nIDEvent, uElapse: LongWord; lpTimerFunc: LongWord): LongWord; external 'SetTimer@user32.dll stdcall';
function KillTimer(hWnd: LongWord; uIDEvent: LongWord): LongWord; external 'KillTimer@user32.dll stdcall';

function WantDesktopIcon: Boolean;
begin
  Result := DesktopOn;
end;

function NewText(Parent: TWinControl; Left, Top, Width, Size: Integer; Color: Integer; Bold: Boolean; Caption: String): TNewStaticText;
begin
  Result := TNewStaticText.Create(WizardForm);
  Result.Parent := Parent;
  Result.Left := ScaleX(Left);
  Result.Top := ScaleY(Top);
  Result.AutoSize := False;
  Result.WordWrap := True;
  Result.Width := Width;
  Result.Font.Name := 'Microsoft YaHei UI';
  Result.Font.Size := Size;
  Result.Font.Color := Color;
  if Bold then Result.Font.Style := [fsBold];
  Result.Caption := Caption;
  Result.Height := ScaleY(Size * 2 + 8);
end;

function NewImage(Parent: TWinControl; FileName: String; Left, Top, Width, Height: Integer): TBitmapImage;
begin
  ExtractTemporaryFile(FileName);
  Result := TBitmapImage.Create(WizardForm);
  Result.Parent := Parent;
  Result.Bitmap.LoadFromFile(ExpandConstant('{tmp}\' + FileName));
  Result.Stretch := True;
  Result.Left := Left;
  Result.Top := Top;
  Result.Width := Width;
  Result.Height := Height;
end;

{ ---- 自画按钮：原按钮挪出可见区（回车 / Esc 照常由它响应，Inno 自己切文字和显隐不受影响），这里照着它同步文字、显隐，点击转给它 ---- }
const
  BM_CLICK = $00F5;
  WM_SETREDRAW = $000B;
  RDW_INVALIDATE = $0001; RDW_ERASE = $0004; RDW_ALLCHILDREN = $0080; RDW_UPDATENOW = $0100; RDW_FRAME = $0400;

function RedrawWindow(hWnd: HWND; lprcUpdate: Longint; hrgnUpdate: Longint; flags: UINT): BOOL; external 'RedrawWindow@user32.dll stdcall';

var
  RedrawLocked: Boolean;
  UnlockTimer: LongWord;

{ 翻页不留残影：自画按钮是画在窗体上的图，Inno 换页内容和我们在 CurPageChanged 里换按钮显隐不是同一次重画，
  中间窗体先画出「新页 + 旧按钮」那一帧（11-11 实机看到「安装」按钮残留一下才消失）。
  所以点下一步时先停掉窗体重画，换完页、同步完按钮（CurPageChanged 末尾）再一次性整窗重画。
  点「完成」不锁（窗口直接关） }
procedure UnlockRedraw;
begin
  if UnlockTimer <> 0 then begin KillTimer(0, UnlockTimer); UnlockTimer := 0; end;
  if not RedrawLocked then exit;
  RedrawLocked := False;
  SendMessage(WizardForm.Handle, WM_SETREDRAW, 1, 0);
  RedrawWindow(WizardForm.Handle, 0, 0, RDW_ERASE or RDW_FRAME or RDW_INVALIDATE or RDW_ALLCHILDREN or RDW_UPDATENOW);
end;

procedure OnUnlockTimer(Wnd: LongWord; Msg: LongWord; IdEvent: LongWord; Time: LongWord);
begin
  UnlockRedraw;
end;

{ 兜底：点下一步后没翻页（Inno 弹框拦下、回车路径没有 PressPrimary 的收尾）时，下一次消息循环空闲就放开重画。
  翻页时 CurPageChanged 先放开并撤掉这个计时器，它不参与正常翻页的那一帧 }
procedure LockRedraw;
begin
  if RedrawLocked then exit;
  RedrawLocked := True;
  SendMessage(WizardForm.Handle, WM_SETREDRAW, 0, 0);
  UnlockTimer := SetTimer(0, 0, 300, CreateCallback(@OnUnlockTimer));
end;

{ 点击转给原按钮：发标准的按钮点击消息，和回车 / 真鼠标点原按钮走同一条路（Inno 的翻页、校验、完成页 [Run] 都在原按钮里） }
procedure PressPrimary(Sender: TObject);
begin
  Log('自画主按钮被点：页 ' + IntToStr(WizardForm.CurPageID) + '，原按钮可用 ' + IntToStr(Ord(WizardForm.NextButton.Enabled)));
  if WizardForm.CurPageID = wpFinished then   { 嵌套判断：Pascal Script 的 and 不短路，别在别的页去读完成页的列表 }
    if WizardForm.RunList.Items.Count > 0 then
      WizardForm.RunList.Checked[0] := LaunchOn;   { 完成页「现在打开 S2Arm」：勾选状态来自自画复选框，照旧由 [Run] postinstall 执行 }
  SendMessage(WizardForm.NextButton.Handle, BM_CLICK, 0, 0);
  UnlockRedraw;   { 兜底：没翻页（被校验拦下）时也要放开重画；翻了页 CurPageChanged 已放开，这里空转 }
end;

procedure PressSecondary(Sender: TObject);
begin
  Log('自画次按钮被点：页 ' + IntToStr(WizardForm.CurPageID));
  SendMessage(WizardForm.CancelButton.Handle, BM_CLICK, 0, 0);
end;

procedure SyncButtons;
begin
  { 按钮文字画在图里（深色样式会把叠在上面的字强制画成浅色，奶油色底上看不见）：主按钮按原按钮当前的文字选「安装」/「完成」 }
  { 「安装」「完成」是两个独立的图，换页只切显隐、不重新读图（翻页那一帧不多一次重画） }
  FinishImg.Visible := WizardForm.NextButton.Visible and (Pos(SetupMessage(msgButtonFinish), WizardForm.NextButton.Caption) > 0);
  PrimaryImg.Visible := WizardForm.NextButton.Visible and not FinishImg.Visible;
  SecondaryImg.Visible := WizardForm.CancelButton.Visible;
  { 只有一个按钮时它靠右；两个时次按钮在主按钮左边 }
  PrimaryImg.Left := BtnRight - PrimaryImg.Width;
  FinishImg.Left := PrimaryImg.Left;
  if WizardForm.NextButton.Visible then begin
    SecondaryImg.Left := PrimaryImg.Left - ScaleX(12) - SecondaryImg.Width;
  end else
    SecondaryImg.Left := BtnRight - SecondaryImg.Width;
end;

procedure BuildButtons;
var
  N, C: TButton;
begin
  N := WizardForm.NextButton; C := WizardForm.CancelButton;
  BtnRight := N.Left + N.Width;
  BtnMid := N.Top + N.Height div 2 - ScaleY(10);   { 比原按钮略高：底边留出和示意图一样的空 }
  { 按钮放在自己的子窗口（面板）里，不直接画在窗体上：窗体上的图和页面容器（子窗口）有重叠，
    藏图时窗体只重画自己、画不到子窗口盖住的那条，旧按钮的上沿就一直留着（实机连帧测出的残影根因） }
  BtnPanel := TPanel.Create(WizardForm);
  BtnPanel.Parent := WizardForm;
  BtnPanel.BevelOuter := bvNone;
  BtnPanel.Width := ScaleX(144) + ScaleX(12) + ScaleX(160);
  BtnPanel.Height := ScaleY(40);
  BtnPanel.Left := BtnRight - BtnPanel.Width;
  BtnPanel.Top := BtnMid - ScaleY(20);
  BtnPanel.BringToFront;
  BtnRight := BtnPanel.Width;   { 以下按钮坐标都相对面板 }
  NewImage(BtnPanel, 'bg.bmp', 0, 0, BtnPanel.Width, BtnPanel.Height);   { 面板底色：深色样式不认面板的 Color（实机画成灰），铺纯底色图；先建、在按钮下面 }
  PrimaryImg := NewImage(BtnPanel, 'btn_install.bmp', 0, 0, ScaleX(160), ScaleY(40));
  FinishImg := NewImage(BtnPanel, 'btn_finish.bmp', 0, 0, ScaleX(160), ScaleY(40));
  FinishImg.OnClick := @PressPrimary; FinishImg.Cursor := crHand;
  SecondaryImg := NewImage(BtnPanel, 'btn_cancel.bmp', 0, 0, ScaleX(144), ScaleY(40));
  PrimaryImg.OnClick := @PressPrimary; PrimaryImg.Cursor := crHand;
  SecondaryImg.OnClick := @PressSecondary; SecondaryImg.Cursor := crHand;
  { 原按钮挪出可见区：仍是窗口的默认 / 取消按钮 }
  N.Left := -2000; C.Left := -2000; WizardForm.BackButton.Left := -2000;
  { 不参与 Tab 切换：否则键盘焦点会停在看不见的按钮上。回车（默认按钮）/ Esc（取消按钮）不靠 Tab，照常可用 }
  N.TabStop := False; C.TabStop := False; WizardForm.BackButton.TabStop := False;
end;

{ ---- 自画复选框：图（奶油色勾 / 描边空框）+ 文字，点哪都切换 ---- }
function CheckBitmap(On: Boolean): String;
begin
  if On then Result := ExpandConstant('{tmp}\check_on.bmp') else Result := ExpandConstant('{tmp}\check_off.bmp');
end;

procedure ToggleDesktop(Sender: TObject);
begin
  DesktopOn := not DesktopOn;
  DesktopImg.Bitmap.LoadFromFile(CheckBitmap(DesktopOn));
end;

procedure ToggleLaunch(Sender: TObject);
begin
  LaunchOn := not LaunchOn;
  LaunchImg.Bitmap.LoadFromFile(CheckBitmap(LaunchOn));
  { 同步写回原列表：回车键（原按钮仍是默认按钮）和点自画按钮走同一个勾选状态 }
  if WizardForm.RunList.Items.Count > 0 then WizardForm.RunList.Checked[0] := LaunchOn;
end;

function NewCheck(Parent: TWinControl; Left, Top: Integer; Caption: String; OnClick: TNotifyEvent): TBitmapImage;
var
  T: TNewStaticText;
begin
  ExtractTemporaryFile('check_off.bmp');
  Result := NewImage(Parent, 'check_on.bmp', ScaleX(Left), ScaleY(Top), ScaleX(18), ScaleY(18));
  Result.OnClick := OnClick; Result.Cursor := crHand;
  T := NewText(Parent, Left + 28, Top - 1, Parent.ClientWidth - ScaleX(Left + 28), 10, Ink, False, Caption);
  T.OnClick := OnClick; T.Cursor := crHand;
end;

{ 卖点：只写已经有的功能（README / 官网），不写游戏名；中文一句、英文一句。最后一张是从压缩包版迁过来的说明 }
procedure AddSlide(Cn, En: String);
var
  N: Integer;
begin
  N := GetArrayLength(SlideCn);
  SetArrayLength(SlideCn, N + 1); SetArrayLength(SlideEn, N + 1);
  SlideCn[N] := Cn; SlideEn[N] := En;
end;

procedure InitSlides;
begin
  AddSlide('一个 App 装下整个游戏库，只占开发者账号一个名额', 'One app holds your whole library, using a single App slot');
  AddSlide('原生运行，不是模拟器：游戏代码改写成 ARM64，画面直达 Metal', 'A native port, not an emulator: code runs as ARM64, graphics go straight to Metal');
  AddSlide('让 AI 帮你出包、装到手机，每一步都在启动器里看得见', 'Let an AI build and install for you, with every step visible in the launcher');
  AddSlide('存档在 iPhone 和 Mac 之间互通', 'Saves move freely between iPhone and Mac');
  AddSlide('每款游戏单独记住自己的画面设置', 'Each game remembers its own graphics settings');
  AddSlide('升级 S2Arm 不用重新出包，出好的游戏原样带进新版', 'Updating S2Arm keeps the games you built; no rebuild needed');
  AddSlide('以前用的是压缩包版？游戏库、设置、出好的包都照用', 'Used the zip version before? Your library and settings carry over');
end;

procedure ShowSlide;
var
  Dots: String;
  I: Integer;
begin
  SlideTitle.Caption := SlideCn[SlideIndex];
  SlideSub.Caption := SlideEn[SlideIndex];
  Dots := '';
  for I := 0 to GetArrayLength(SlideCn) - 1 do
    if I = SlideIndex then Dots := Dots + '●  ' else Dots := Dots + '○  ';
  SlideDots.Caption := Dots;
end;

procedure OnSlideTimer(Wnd: LongWord; Msg: LongWord; IdEvent: LongWord; Time: LongWord);
begin
  SlideIndex := (SlideIndex + 1) mod GetArrayLength(SlideCn);
  ShowSlide;
end;

procedure StopSlides;
begin
  if SlideTimer <> 0 then begin
    KillTimer(0, SlideTimer);
    SlideTimer := 0;
  end;
end;

procedure BuildHeader;
var
  Mark: TBitmapImage;
  Pill: TNewStaticText;
begin
  { 顶栏：左边 S2ARM 字标，右边平台标签；不要 Inno 默认的页标题 / 小图 }
  WizardForm.PageNameLabel.Visible := False;
  WizardForm.PageDescriptionLabel.Visible := False;
  WizardForm.WizardSmallBitmapImage.Visible := False;
  ExtractTemporaryFile('header.bmp');
  Mark := TBitmapImage.Create(WizardForm);
  Mark.Parent := WizardForm.MainPanel;
  Mark.Bitmap.LoadFromFile(ExpandConstant('{tmp}\header.bmp'));
  Mark.Stretch := True;
  Mark.Width := ScaleX(Mark.Bitmap.Width);
  Mark.Height := ScaleY(Mark.Bitmap.Height);
  Mark.Left := ScaleX(24);
  Mark.Top := (WizardForm.MainPanel.Height - Mark.Height) div 2;
  Pill := TNewStaticText.Create(WizardForm);
  Pill.Parent := WizardForm.MainPanel;
  Pill.Font.Name := 'Microsoft YaHei UI';
  Pill.Font.Size := 9;
  Pill.Font.Color := Muted;
  Pill.Caption := 'Windows · x64';
  Pill.Left := WizardForm.MainPanel.ClientWidth - Pill.Width - ScaleX(28);
  Pill.Top := (WizardForm.MainPanel.Height - Pill.Height) div 2;
end;

procedure BuildWelcome;
var
  Page: TWizardPage;
  W: Integer;
begin
  Page := CreateCustomPage(wpWelcome, '', '');
  WelcomePageID := Page.ID;
  W := Page.Surface.ClientWidth;
  NewText(Page.Surface, 0, 0, W, 22, Ink, True, '安装 S2Arm');
  NewText(Page.Surface, 0, 50, W, 10, Ink, False, '把启动器装到这台电脑上，开始菜单和桌面会有 S2Arm 图标。');
  NewText(Page.Surface, 0, 74, W, 9, Muted, False, 'Installs the S2Arm launcher with Start menu and desktop shortcuts.');
  NewImage(Page.Surface, 'card.bmp', 0, ScaleY(110), W, ScaleY(96));
  NewText(Page.Surface, 18, 122, W - ScaleX(36), 9, Muted, False, '安装位置 / Install location');
  PathText := NewText(Page.Surface, 18, 144, W - ScaleX(36), 10, Ink, False, '');   { 安装目录到页面显示时才定下来（CurPageChanged 填） }
  NewText(Page.Surface, 18, 170, W - ScaleX(36), 9, Muted, False, '路径短、不要管理员权限；游戏库和存档不放这里，卸载也不会动它们。');
  DesktopOn := True;
  DesktopImg := NewCheck(Page.Surface, 0, 226, '在桌面创建 S2Arm 图标 / Create a desktop shortcut', @ToggleDesktop);
end;

procedure BuildInstalling;
var
  P: TWinControl;
  W, Y: Integer;
begin
  { 安装中：大标题 + 自己画的奶油色进度条 + 卖点轮播卡片（11-11 定：中间的宣传语轮播，几秒换一张、带页点）。
    轮播只是计时器换字，不挡安装；装得快时一闪而过也不影响进度 }
  P := WizardForm.InstallingPage;
  W := P.ClientWidth;
  WizardForm.StatusLabel.Visible := False;
  WizardForm.FilenameLabel.Visible := False;
  WizardForm.ProgressGauge.Visible := False;
  NewText(P, 0, 0, W, 20, Ink, True, '正在安装…');
  NewText(P, 0, 46, W, 9, Muted, False, 'Installing S2Arm');
  NewImage(P, 'track.bmp', 0, ScaleY(84), W, ScaleY(8));
  BarWidth := W;
  Bar := NewImage(P, 'bar.bmp', 0, ScaleY(84), 0, ScaleY(8));
  Y := 116;
  NewImage(P, 'card.bmp', 0, ScaleY(Y), W, ScaleY(110));
  SlideTitle := NewText(P, 20, Y + 18, W - ScaleX(40), 12, Ink, True, '');
  SlideSub := NewText(P, 20, Y + 50, W - ScaleX(40), 9, Muted, False, '');
  SlideDots := NewText(P, 20, Y + 80, W - ScaleX(40), 8, Cream, False, '');
  SlideIndex := 0;
  ShowSlide;
end;

procedure InitializeWizard;
begin
  InitSlides;
  BuildHeader;
  BuildWelcome;
  BuildInstalling;
  BuildButtons;
end;

procedure BuildFinished;
var
  P: TWinControl;
  Mark: TBitmapImage;
  W: Integer;
begin
  { 完成页：和前两步一套（Inno 默认左侧插图藏掉）。完成页的文字 Inno 在进页时按消息重设，所以在这里（CurPageChanged）填 }
  P := WizardForm.FinishedPage;
  WizardForm.WizardBitmapImage2.Visible := False;
  WizardForm.FinishedLabel.Visible := False;
  W := P.ClientWidth - ScaleX(48);
  if not FinishedBuilt then begin
    FinishedBuilt := True;
    Mark := NewImage(P, 'header.bmp', ScaleX(24), ScaleY(18), 0, 0);
    Mark.Width := ScaleX(Mark.Bitmap.Width);
    Mark.Height := ScaleY(Mark.Bitmap.Height);
    NewText(P, 24, 112, W, 10, Ink, False, '以后从开始菜单或桌面打开 S2Arm；新版本在启动器里自动更新。');
    NewText(P, 24, 136, W, 9, Muted, False, 'Open S2Arm from the Start menu or desktop. Updates install themselves.');
    NewImage(P, 'card.bmp', ScaleX(24), ScaleY(176), W, ScaleY(96));
    NewText(P, 42, 188, W - ScaleX(36), 9, Muted, False, '卸载 / Uninstall');
    NewText(P, 42, 210, W - ScaleX(36), 10, Ink, False, '设置 → 应用 → 已安装的应用 → S2Arm → 卸载');
    NewText(P, 42, 236, W - ScaleX(36), 9, Muted, False, '只删程序本身；游戏库、存档、出好的 iPhone 包都保留。');
    with NewText(P, 0, 0, 0, 9, Muted, False, 'Windows · x64') do begin   { 顶栏右边的平台标签：三步统一 }
      AutoSize := True; WordWrap := False;
      Left := P.ClientWidth - Width - ScaleX(28);
      Top := Mark.Top + (Mark.Height - Height) div 2;
    end;
    LaunchOn := True;
    LaunchImg := NewCheck(P, 24, 296, '现在打开 S2Arm / Launch S2Arm now', @ToggleLaunch);
  end;
  WizardForm.RunList.Left := -2000;   { 原「现在打开」列表挪出可见区：勾选状态由自画复选框决定（PressPrimary 写回） }
  WizardForm.FinishedHeadingLabel.Caption := '装好了';
  WizardForm.FinishedHeadingLabel.Font.Name := 'Microsoft YaHei UI';
  WizardForm.FinishedHeadingLabel.Font.Size := 22;
  WizardForm.FinishedHeadingLabel.Left := ScaleX(24);
  WizardForm.FinishedHeadingLabel.Top := ScaleY(64);
  WizardForm.FinishedHeadingLabel.Width := W;
  WizardForm.FinishedHeadingLabel.Height := ScaleY(44);
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  if MaxProgress > 0 then
    Bar.Width := BarWidth * CurProgress div MaxProgress;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  { 鼠标点自画按钮、回车按原按钮都经过这里：翻页前停重画（见 LockRedraw） }
  if CurPageID <> wpFinished then LockRedraw;
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  { 装完自动翻到完成页不经过「下一步」：在装完这一步就停重画，完成页搭好（CurPageChanged）再一次性画出
    （实机连帧：不锁时完成页的字、复选框分两三帧陆续出来） }
  if CurStep = ssPostInstall then LockRedraw;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  SyncButtons;
  if CurPageID = WelcomePageID then begin
    PathText.Caption := WizardDirValue;
    WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall);
  end;
  if CurPageID = wpFinished then BuildFinished;
  if CurPageID = wpInstalling then begin
    SlideIndex := 0;
    ShowSlide;
    SlideTimer := SetTimer(0, 0, SlideMs, CreateCallback(@OnSlideTimer));
  end else
    StopSlides;
  { 新页内容 + 新按钮一起画出来。「准备安装」页只是去安装页路上的一站（实机连帧：会先闪出空白页 + 旧按钮），
    不在这里放开；它真停住（要关占用文件的程序等）时由 LockRedraw 的兜底计时器放开 }
  if CurPageID <> wpPreparing then UnlockRedraw;
end;

{ ---- 开装前关掉在跑的 S2Arm（11-11 维护者覆盖安装：Impactor 一直在跑、文件被占，装到一半弹英文「DeleteFile failed; code 5」；
  CloseApplications=yes 的重启管理器没把它关掉，删旧 Engine 时 refs 空目录跟着丢了）。可执行文件在安装目录下的进程（S2Arm、Impactor、plumesign……）
  在真正开始装（含 InstallDelete 删旧目录）之前找出来：问一句、一键关掉（连子进程一起），关不掉就点名、让玩家手动关，不在复制文件时才报错 ---- }
{ 占着安装目录的进程：调 dir_holders.ps1（只在安装时解到临时目录用，不装进安装目录）。
  Pids 返回进程号，函数值是给玩家看的名单（每行一个，空 = 没有）。KillPids 非空时先结束这些进程、再查一遍。
  查不了（PowerShell 起不来）返回空：不挡安装，后面还有 Inno 自己的重启管理器兜底。 }
function DirHolders(KillPids: String; var Pids: TArrayOfString): String;
var
  Script, OutFile, Params, Line: String;
  Lines: TArrayOfString;
  I, Tab, Code: Integer;
begin
  Result := '';
  SetArrayLength(Pids, 0);
  ExtractTemporaryFile('dir_holders.ps1');
  Script := ExpandConstant('{tmp}\dir_holders.ps1');
  OutFile := ExpandConstant('{tmp}\dir_holders.tsv');
  DeleteFile(OutFile);
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Script + '" -Dir "' + RemoveBackslashUnlessRoot(WizardDirValue) + '" -Out "' + OutFile + '"';
  if KillPids <> '' then Params := Params + ' -Kill "' + KillPids + '"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, Code) then exit;
  if not LoadStringsFromFile(OutFile, Lines) then exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Lines[I];
    Tab := Pos(#9, Line);
    if Tab = 0 then continue;
    SetArrayLength(Pids, GetArrayLength(Pids) + 1);
    Pids[GetArrayLength(Pids) - 1] := Copy(Line, 1, Tab - 1);
    Line := Copy(Line, Tab + 1, Length(Line));
    Tab := Pos(#9, Line);
    if Tab > 0 then Line := Copy(Line, 1, Tab - 1);
    Result := Result + '    ' + Line + #13#10;
  end;
end;

function JoinPids(Pids: TArrayOfString): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to GetArrayLength(Pids) - 1 do begin
    if Result <> '' then Result := Result + ',';
    Result := Result + Pids[I];
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Pids: TArrayOfString;
  Names: String;
begin
  Result := '';
  Names := DirHolders('', Pids);
  if Names = '' then exit;
  if SuppressibleMsgBox('S2Arm 还在运行，要先关掉才能安装：' + #13#10#13#10 + Names + #13#10 +
       '点「确定」帮你关掉它们（正在进行的出包、装到手机会中断），点「取消」退出安装。',
       mbConfirmation, MB_OKCANCEL, IDOK) <> IDOK then begin
    Result := '安装已取消：S2Arm 还在运行。关掉 S2Arm（以及 Impactor）后再运行安装程序。';
    exit;
  end;
  Names := DirHolders(JoinPids(Pids), Pids);
  if Names <> '' then
    Result := '这些程序没能关掉，请在任务管理器里手动结束后，再运行安装程序：' + #13#10#13#10 + Names;
end;

procedure DeinitializeSetup;
begin
  StopSlides;
end;
