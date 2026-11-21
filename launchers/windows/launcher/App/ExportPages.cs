// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

// 出包页 → 出包进度 → 装到 iPhone（#1629 后续片，启动器线）。交互照 Mac 新前端 ExportView / ExportSessionView / InstallView：
// 游戏信息 + 平台卡（Windows 只出 iPhone / iPad；macOS 仅 Mac 可出；安卓、鸿蒙即将上线）→ 开始出包。没有「游戏选项」（维护者 11-07 拍板）：
// 语言跟设备、移动端掌机、60 帧缺省开起不来自动降级、满屏缺省通用 + 补丁，全由后端 / App 定，出包页不给开关；
// 进度只用作业层里程碑事件的真读数（MilestoneEstimate 与 Mac 适配层同一规则）；装机前清单 installCheck 全齐才可 install。
// 游戏库页交过来的只有当前连接（connectedFolder / libraryId）、目录（catalog）和选中的 selectedGame；本文件不改游戏库。
public sealed partial class EnvironmentWindow
{
    // Impactor bundled with the launcher zip (launchers/windows/bundle_win.py, pinned by SHA-256; same layout as pack/jobs/impactor.py BUNDLE_DIR).
    private static string BundledImpactor => Path.Combine(AppContext.BaseDirectory, "ThirdParty", "Impactor", "Impactor-windows-x86_64-portable.exe");

    // First Apple ID sign-in happens in Impactor itself (the password never passes through S2Arm); the checklist re-asks every 5 s and ticks when done.
    private void OpenBundledImpactor() => TryOpenBundledImpactor();

    private bool TryOpenBundledImpactor()
    {
        var ok = false;
        try
        {
            using var p = Process.Start(new ProcessStartInfo(BundledImpactor) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(BundledImpactor)! });
            if (p is null) installDiagnostics = T("process.start_failed"); else ok = true;
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or InvalidOperationException)
        { installDiagnostics = T("process.start_failed") + " " + error.Message; }
        Render();
        return ok;
    }

    /// <summary>装机前清单当前呈现的落点（11-19 契约，同 Mac state.presented）：清单按钮 / 控制口 /install-action 做成了记 action 名；换页（Navigate）、/dismiss 清空</summary>
    private string? presented;

    /// <summary>装机前清单按钮的唯一派发（11-19 维护者：test.3 Mac 清单 Apple ID 按钮把人引到环境检查和 Xcode；Windows 同口径核出两处——
    /// impactor_login 数据说 openImpactor、说明写「点『打开 Impactor』」，按钮却是「去设置」跳设置页；package 没好没有按钮）。
    /// 项上的 action 是按钮落点的唯一来源；控制口 /install-action 走这同一个函数。→ 做成了没有</summary>
    /// game：清单那一款；确认页的另一条路（更新页不属于哪一款）传 null，只有 openExport 要它
    private bool RunInstallAction(string action, LibraryGame? game)
    {
        switch (action)
        {
            case "openExport": if (game is null) return false; selectedGame = game.Id; OpenBuild(); break;   // 这款的出包页（同游戏库「出包」）
            case "openImpactor": if (!TryOpenBundledImpactor()) return false; break;   // 随包 Impactor：Apple ID 在它里面登录
            case "devCertSettings": Navigate("settings"); break;   // 设置页「装到 iPhone 的方式」：开发者证书在那里导入 / 切换
            default: return false;
        }
        presented = action;   // 换页（OpenBuild / Navigate）先清空，这里再记
        Render();
        return true;
    }

    /// <summary>按钮文案键只认共享体验表 install_landing.actions（结构 9：两端一处给出，不在这里另写一份）</summary>
    private string? InstallActionLabel(string action) => text.InstallActionLabel(action);

    private const string PlatformIos = "ios";
    private const string PlatformTv = "tvos";
    private bool exportIos = true;
    /// <summary>出包页勾了 Apple TV（11-16 维护者：Windows 出 Apple TV 包后导出安装包 .ipa，玩家自己签名装到电视）</summary>
    private bool exportTv;
    // 安卓（开关后，缺省关：作业层 androidDevices 回报 enabled 才开卡，pack/jobs/android_export.py）：出 APK，选了手机就接着装（adb 序列号）
    private bool exportAndroid;
    private bool androidEnabled;
    private bool androidProbed;
    private List<(string Serial, string State, string Model)> androidPhones = [];
    private string? androidPhoneChoice;   // null = 只连着一台可用的就装它；"" = 不装、只出 APK
    // 存放位置（游戏库结构 v3）：locations 作业读回的各位置、为哪款读的、出包页选中的文件夹（"" = 还没定，不传，后端按这款现在的位置）
    private StorageLocations? locations;
    private string? locationsFor;
    private string exportLocation = "";
    /// <summary>「选择其他文件夹…」选的路径所在盘的提示原因（#444；null = 没问题；已登记的位置看 StorageLocation.Slack）。</summary>
    private readonly Dictionary<string, LocationSlack?> probedSlack = new(StringComparer.OrdinalIgnoreCase);
    private const string OtherFolder = "__other__";
    // pack job
    private LibraryGame? packGame;
    private FrontJob? packJob;   // 当前这款出包的作业登记（ResetPack 登记、RunPackAsync 收尾撤；JobSlots.cs）
    private Task? packOperation;
    private MilestoneTrack packTrack = new();
    private DateTime packStarted;
    private double? packSeconds;
    private string packState = "";   // "" | running | succeeded | failed | cancelled | invalid
    private string packSummary = "", packDiagnostics = "";
    private string? packFailureCode;
    private string? packIpa;
    private string? packLocation;
    private long? packIpaBytes, packPackBytes;
    /// <summary>这一单降级继续的玩家提示（作业层 notes，v0.3.1）：完成卡逐条显示</summary>
    private IReadOnlyList<string> packNotes = [];
    private JsonElement? packBoost;   // 补丁打入结果（ExportStream.Outcome.Boost，11-14）
    private PackSpace? packSpace;
    // in-progress capsule (shown while session is hidden)
    private bool sessionHidden;
    // finished results per game id, so player can review after going back to library
    private readonly Dictionary<string, (string state, string ipa, long? ipaBytes, long? packBytes, double seconds)> finishedPacks = new(StringComparer.Ordinal);
    // install
    private InstallReadiness? readiness;
    private string readinessRaw = "";   // 上次清单的原文：复查结果没变就不重画（CheckInstallAsync）
    /// <summary>上次装机清单认出连着的是 iPad：这几处入口写「装到 iPad」（键名加 _ipad，#487）；没认出照旧写 iPhone。</summary>
    private string PadKey(string key) => readiness?.DeviceKind == "ipad" ? key + "_ipad" : key;
    private string? readinessFor;
    /// 这次实际装上的那台（装机结果的 deviceKind / deviceName；Windows 设备服务给不出名字时只有类型）：「已装到 iPad」不写死 iPhone
    private string installedTo = "";
    private string InstallTargetLabel => installedTo.Length > 0 ? installedTo :
        readiness?.DeviceKind switch { "ipad" => "iPad", "iphone" => "iPhone", _ => "iPhone / iPad" };
    private bool installChecking, installCheckFailed;
    private bool customizing;
    private string customizeError = "";
    // A checklist that could not be read must not lock the player out: start and let the install job give the real reason.
    private string installState = "", installMessage = "", installDiagnostics = "";
    /// <summary>上一次装机失败的错误码（apple_session_expired 时失败页给「打开 Impactor 重新登录」，重新登录完自动再装）</summary>
    private string? installCode;
    private bool installOpenToFinish;   // 刚装完的那次是单一 IMG：成功卡片多写一句「打开 S2Arm 会自动完成安装」（作业结果 openToFinish）
    private string installTrustName = "";   // 这次签名的证书名（作业结果 trustName）：成功卡片「点「<名字>」→ 信任」；Windows 上作业读不到时为空，退回不带名字的说法
    private string revealProblem = "";   // 「显示 IPA」「打开游戏文件夹」找不到目标时的提示（不打开空的资源管理器）
    // 当前 / 最近一次手机作业属于哪一款（#308：原先只有一份「当前安装」状态、没记是哪款，回游戏库再点别的游戏，进度会画到那款上）。
    //   installSeen：跑完后玩家回安装页看过结果没有；没看过时顶栏胶囊一直在。进度计数来自作业事件 done / total / unit（推资源包按字节，机上解包按包）
    private string? installGameId, installGameName;
    private long? installDone, installTotal;
    private string installUnit = "";
    private DateTime installRateAt; private long installRateBase; private double? installRate;
    private bool installSeen = true;
    /// <summary>最近一次单款装机（InstallAsync）原样再发一次：失败页「重试」</summary>
    private Func<Task>? lastInstall;

    /// 开始一个手机作业：登记（只锁这一款）、记下是哪一款、清掉上次的计数
    private FrontJob BeginPhoneJob(LibraryGame game, string message, string kind = "install")
    {
        var job = BeginJob(JobKind.Phone, game.Id);
        installTrack.Begin(kind, InstallTargetLabel);   // 手机作业结局卡（PhoneJobCard.cs）的过程与事实
        installState = "running"; installMessage = message; installDiagnostics = "";
        installGameId = game.Id; installGameName = game.Name; installSeen = false;
        installDone = installTotal = null; installUnit = ""; installRate = null;
        Render();
        return job;
    }

    /// 作业事件 → 安装页文字与计数（推资源包：已传 / 本次待传字节；机上解包：k / n 包）。单位变了（传完进解包）计数与速度重新算
    private void IngestPhoneEvent(JsonElement e)
    {
        installTrack.Ingest(e);
        if (e.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String && m.GetString() is { Length: > 0 } text) installMessage = text;
        if (e.TryGetProperty("done", out var d) && d.ValueKind == JsonValueKind.Number && e.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number && t.GetInt64() > 0)
        {
            var unit = e.TryGetProperty("unit", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() ?? "" : "";
            var done = d.GetInt64(); var total = t.GetInt64();
            if (unit != installUnit || total != installTotal || done < (installDone ?? 0)) { installRateAt = DateTime.UtcNow; installRateBase = done; installRate = null; }
            else if ((DateTime.UtcNow - installRateAt).TotalSeconds >= 3 && done > installRateBase)
                installRate = (done - installRateBase) / (DateTime.UtcNow - installRateAt).TotalSeconds;
            installDone = done; installTotal = total; installUnit = unit;
        }
        RefreshLive();   // 只刷新顶栏胶囊和安装页的进度格子：装大游戏的十几分钟里玩家可能在翻游戏库，整页重画会打断他
    }

    /// 回到正在装 / 刚装完的那一款的安装页（同一个作业，不新起安装）
    private void OpenPhoneJob()
    {
        if (installGameId is null) return;
        libraryFolder = libraryFolderBox.Text ?? libraryFolder;
        selectedGame = installGameId; readinessFor = null; Navigate("install");
    }

    /// 顶栏胶囊（#308，Mac 同款）：装机在跑 → 「正在推到 iPhone：X · 查看进度」；跑完没回去看 → 「已装到 / 没装完 · 查看」。正看着这款的安装页时不显示
    private Button? PhonePill()
    {
        if (installGameId is null || (!installBusy && installSeen) || (page == "install" && SelectedGame?.Id == installGameId)) return null;
        var key = installBusy ? (installExport ? "install.pill.exporting" : "install.pill.running")
            : installState == "succeeded" ? (installTrack.ExportFolder.Length > 0 ? "install.pill.exported" : "install.pill.done")
            : installState == "needsPlayer" ? "install.pill.needs_player" : installExport ? "install.pill.exportFailed" : "install.pill.failed";
        var text = T(key).Replace("{0}", installGameName ?? installGameId).Replace("{1}", InstallTargetLabel);
        if (installBusy && installDone is { } d && installTotal is { } t && t > 0) text += " · " + (100 * d / t) + "%";
        var pill = new Button { Content = text, Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(16),
            Background = Brush.Parse("#29292D"), Foreground = Ink };
        Avalonia.Automation.AutomationProperties.SetAutomationId(pill, "install.pill");
        pill.Click += (_, _) => OpenPhoneJob();
        return pill;
    }

    /// 计数那一行：「42% · 8.5 GB / 13.0 GB · 21.2 MB/s · 还剩约 4 分钟」或「机上解包 15 / 28」；没有计数 → 空
    private string PhoneProgressText()
    {
        if (installDone is not { } done || installTotal is not { } total || total <= 0) return "";
        var parts = new List<string> { (100 * done / total) + "%" };
        if (installUnit == "B")
        {
            parts.Add(FormatBytes(done) + " / " + FormatBytes(total));
            if (installRate is { } rate && rate > 0)
            {
                parts.Add(FormatBytes((long)rate) + "/s");
                var left = (total - done) / rate;
                parts.Add(T("install.eta").Replace("{0}", left < 90 ? Math.Max(1, (int)left) + T("install.eta_seconds") : (int)Math.Round(left / 60) + T("install.eta_minutes")));
            }
        }
        else parts.Add(done + " / " + total + (installUnit.Length > 0 ? " " + installUnit : ""));
        return string.Join(" · ", parts);
    }
    private DateTime lastCheck = DateTime.MinValue;
    private DispatcherTimer? ticker;

    private bool PackBusy => packRunning || installBusy;

    /// 因为「有任务在跑」而置灰的按钮：悬停说明在等哪个任务、为什么（维护者 11-11：同一时间只跑一个任务是单壳方案的特点，不改，但要说清）。
    ///   置灰的控件缺省不弹提示，所以打开 ShowOnDisabled；不忙时什么都不挂
    private void BusyHint(Control c)
    {
        if (!PackBusy) return;
        var (action, name) = packRunning ? (T("busy.export"), packGame?.Name) : (T("busy.install"), installGameName);
        var hint = T("busy.hint").Replace("{0}", action).Replace("{1}", string.IsNullOrEmpty(name) ? "" : T("busy.game").Replace("{0}", name));
        ToolTip.SetTip(c, hint); ToolTip.SetShowOnDisabled(c, true);
    }
    /// 这款现在能不能动（选、出包、移动、清缓存、删除）：只问作业登记（JobSlots.cs FrontJob.Blocks）——游戏库 / 导入 / 出包 / 释放空间在跑时都不能；
    /// 装机在跑时只锁正在装的那款（玩家装一款大游戏的十几分钟里别的照常用）。原先漏了导入：导入中还能点出包（启动器剃刀 W20）
    private bool BusyFor(LibraryGame game) => jobs.Any(j => j.Blocks(game.Id));
    /// <summary>这款的手机作业（装机 / 导出已出好的）现在点不了：出包和别的手机作业不挡（排队），导入 / 游戏库 / 释放空间等照旧挡；已排上的也灰</summary>
    private bool PhoneBlockedFor(LibraryGame game) => jobs.Any(j => j.Kind is not (JobKind.Pack or JobKind.Phone) && j.Blocks(game.Id)) || PhoneQueued(game.Id);
    private LibraryGame? SelectedGame => catalog?.Games.FirstOrDefault(g => g.Id == selectedGame && !g.Hidden);
    private static double Clock => DateTime.UtcNow.Subtract(DateTime.UnixEpoch).TotalSeconds;

    /// <summary>Pages owned by this file; false = not one of them.</summary>
    private bool RenderPackPages(StackPanel body)
    {
        if (page is not ("build" or "progress" or "install" or "phoneupdate")) return false;
        EnsureTicker();
        if (page == "progress" && packGame is null) page = "build";

        // 底栏固定在窗口底部：用 DockPanel 把 content+bottomBar 分开
        var contentBody = new StackPanel { Spacing = 20, Margin = new Thickness(32, 32, 32, 0) };

        if (page == "build") RenderExport(contentBody);
        else if (page == "progress") RenderProgress(contentBody);
        else if (page == "phoneupdate") contentBody.Children.Add(Card(PhoneUpdateCard()));   // 更新手机上的 S2Arm（InstallModePage.cs）
        else RenderInstall(contentBody);

        // 底部操作栏：出包选择页、装机页左上角已有同去游戏库的「← 游戏库」，不再在底栏重复一个（11-14 体验梳理）；
        //   进度页（停止 / 回游戏库）与手机更新页（没有别的返回入口）照旧
        var bottomBar = page is "build" or "install" ? null : RenderBottomBar();

        // 出包 / 进度 / 装机页没有游戏库页那条顶栏：胶囊放在这些页顶部，在哪页都找得回装机（#308）；装机进度事件只刷新胶囊这一格
        Control? top = PhonePill() is null ? null
            : new Border { Padding = new Thickness(32, 14, 32, 0), Child = LiveSlot(PhonePill), HorizontalAlignment = HorizontalAlignment.Right };
        ShowPage(page, contentBody, top, bottomBar);
        return true;
    }

    private Control RenderBottomBar()
    {
        var bar = new Border
        {
            Background = Brushes.Transparent, BorderBrush = Brush.Parse("#12FFFFFF"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(32, 14)
        };
        var inner = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };

        if (page == "progress" && packRunning)
        {
            var stop = new Button { Content = T("progress.stop"), IsEnabled = packJob is not null,
                Padding = new Thickness(16, 9), Background = Brush.Parse("#29292D"), Foreground = Ink,
                CornerRadius = new CornerRadius(8) };
            AutomationId(stop, "progress.stop");
            stop.Click += (_, _) => packJob?.Cancellation.Cancel();
            inner.Children.Add(stop);

            var backBtn = new Button { Content = T("export.running.back"), Padding = new Thickness(16, 9),
                Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
            backBtn.Click += (_, _) => { sessionHidden = true; Navigate("library"); };
            inner.Children.Add(backBtn);
        }
        else if (page == "progress" && !packRunning)
        {
            var backLib = new Button { Content = T("nav.library"), Padding = new Thickness(16, 9),
                Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
            Avalonia.Automation.AutomationProperties.SetAutomationId(backLib, "top.library");   // 同游戏库页顶栏（自动化按 id 找，不靠文字）
            backLib.Click += (_, _) => Navigate("library");
            inner.Children.Add(backLib);
        }
        else
        {
            var backLib = new Button { Content = T("nav.library"), Padding = new Thickness(16, 9),
                Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
            Avalonia.Automation.AutomationProperties.SetAutomationId(backLib, "top.library");   // 同游戏库页顶栏（自动化按 id 找，不靠文字）
            backLib.Click += (_, _) => Navigate("library");
            inner.Children.Add(backLib);
        }

        bar.Child = inner;
        return bar;
    }

    private void EnsureTicker()
    {
        if (ticker is not null) return;
        ticker = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        ticker.Tick += (_, _) =>
        {
            if (page is "progress" or "batch" && packRunning) RefreshLive();   // 计时 / 进度 / 当前阶段只刷新各自的格子（清单页也画正在出的阶段），不整页重画
            // The checklist changes when the player plugs a phone in or installs Impactor: re-ask every 5 s while visible, idle and in front
            //   （剃刀 W13：窗口不在前台就不问，原先后台也每 5 秒起作业；切回来立刻问一次，见下面 Activated）
            if (IsActive && page == "install" && !installBusy && !installChecking && DateTime.UtcNow - lastCheck > TimeSpan.FromSeconds(5))
                _ = CheckInstallAsync();
        };
        Activated += (_, _) => { if (page == "install" && !installBusy && !installChecking) _ = CheckInstallAsync(); };
        ticker.Start();
        Closed += (_, _) => ticker.Stop();
    }

    /// <summary>打开选中这款的出包页：正在出的 / 刚出完的就是这款 → 进度页；别的款在出时打开这款自己的出包页（点开始会排在后面），
    ///   不带到正在出的那款的进度页（玩家反馈：A 在出包时点 B 的出包，进的是 A 的页面）</summary>
    private void OpenBuild()
    {
        locationsFor = null;   // 出包页每次打开都重读存放位置（剩余空间是当时的）
        if (packGame?.Id == selectedGame && (packRunning || packState == "succeeded")) { Navigate("progress"); return; }
        Navigate("build");
    }

    /// <summary>「12 秒」「4 分 12 秒」「1 小时 3 分」：共用文案 duration.*（同 Mac ExportSessionView.duration exact），放进句子里读</summary>
    private string Spoken(double seconds)
    {
        var s = (int)Math.Round(Math.Max(0, seconds));
        string F(string id, int a, int b = 0) => T("duration." + id).Replace("{0}", a.ToString()).Replace("{1}", b.ToString());
        return s >= 3600 ? F("hm", s / 3600, s % 3600 / 60) : s >= 60 ? F("ms", s / 60, s % 60) : F("s", s);
    }

    private static string Duration(double seconds)
    {
        var s = (int)Math.Round(Math.Max(0, seconds));
        return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }

    private Button Primary(string text, Action handler, bool enabled = true)
    {
        var button = new Button { Content = text, IsEnabled = enabled, Background = Accent, Foreground = Canvas,
            Padding = new Thickness(26, 12), CornerRadius = new CornerRadius(24), FontSize = 16, FontWeight = FontWeight.SemiBold };
        button.Click += (_, _) => handler();
        return button;
    }

    private TextBlock Muted(string text, double size = 13) => new()
    {
        Text = B(text), FontSize = size, TextWrapping = TextWrapping.Wrap, Foreground = Brush.Parse("#A8A6A1")
    };

    private Control GameHeader(LibraryGame game)
    {
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 24 };
        var coverButton = new Button { Content = GameCover(game, 120), Background = Brushes.Transparent, Padding = new Thickness(0), IsEnabled = !BusyFor(game) && !customizing };
        coverButton.Click += (_, _) => _ = ChooseCoverAsync(game);
        ToolTip.SetTip(coverButton, T("custom.cover.help"));
        AutomationId(coverButton, "export.cover");
        header.Children.Add(coverButton);
        var title = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var nameButton = new Button { Content = Label(game.Name, 30), Background = Brushes.Transparent, Padding = new Thickness(0), IsEnabled = !BusyFor(game) && !customizing };
        nameButton.Click += (_, _) => _ = RenameGameAsync(game);
        ToolTip.SetTip(nameButton, T("custom.name.help"));
        AutomationId(nameButton, "export.name");
        title.Children.Add(nameButton);
        if (game.CustomCover)
        {
            var reset = new Button { Content = T("custom.cover.reset"), Background = Brushes.Transparent, Foreground = Brush.Parse("#9A9AA0"), Padding = new Thickness(0), FontSize = 13, IsEnabled = !BusyFor(game) && !customizing };
            reset.Click += (_, _) => _ = CustomizeAsync(game, null, "");
            AutomationId(reset, "export.cover.reset");
            title.Children.Add(reset);
        }
        if (customizeError.Length > 0) title.Children.Add(new TextBlock { Text = customizeError, FontSize = 13, Foreground = Brush.Parse("#E55"), TextWrapping = TextWrapping.Wrap });
        title.Children.Add(Muted(game.Version.Length == 0 ? T("export.version_unknown") : T("library.version") + " · " + game.Version, 14));
        if (game.Missing.Count > 0)
            title.Children.Add(Muted(T("library.requirements") + " · " + string.Join(" / ", game.Missing)));
        Grid.SetColumn(title, 1); header.Children.Add(title);
        return header;
    }

    // ---- export page ----

    private void RenderExport(StackPanel body)
    {
        var game = SelectedGame;
        body.Children.Add(Action("export.back", () => Navigate("library")));
        if (game is null || connectedFolder is null || libraryId is null)
        {
            body.Children.Add(Label(T("export.no_game"), 18));
            return;
        }
        body.Children.Add(GameHeader(game));
        body.Children.Add(SGradeCard(game));   // S 级优化（Beta，11-13，同 Mac SGradeCard.swift）：这款这个版本命中了哪些社区补丁，命中的出包时自动打入
        if (DownstreamRow(game) is { } downstream) body.Children.Add(downstream);   // 移植方案（#1272，同 Mac ExportView downstream）：选过才出，能「更改」

        // platforms
        var heading = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        heading.Children.Add(Label(T("export.platforms"), 16));
        var existing = Action(PadKey("export.install_existing"), () => { readinessFor = null; Navigate("install"); }, !PhoneBlockedFor(game));   // 装机中也能进装机页：看别的游戏时提示「另一款正在装 · 查看那一款」
        Grid.SetColumn(existing, 1); heading.Children.Add(existing);
        body.Children.Add(heading);
        if (!androidProbed) { androidProbed = true; _ = LoadAndroidPhonesAsync(); }   // 安卓卡开不开由作业层回报（开关缺省关：关着照旧「即将推出」）
        var tiles = new UniformGrid { Columns = 5 };
        foreach (var platform in new[] { PlatformIos, PlatformTv, "mac", "android", "ohos" })
        {
            var open = platform == PlatformIos || platform == PlatformTv || (platform == "android" && androidEnabled);   // Apple TV 不藏不锁（维护者 11-16）：安装包没带 tvOS 预编壳时出包作业照实报
            var on = open && (platform == PlatformTv ? exportTv : platform == "android" ? exportAndroid : exportIos);
            var tile = new StackPanel { Spacing = 10 };
            var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            top.Children.Add(Label(T("export.platform." + platform), 16));
            var mark = Label(open ? (on ? "☑" : "☐") : "🔒", 16);
            Grid.SetColumn(mark, 1); top.Children.Add(mark);
            tile.Children.Add(top);
            tile.Children.Add(Muted(T(platform switch
            {
                PlatformIos => "export.note.ios", PlatformTv => "export.note.tvos_win",
                "mac" => "export.note.mac_only", "android" when androidEnabled => "export.note.android", _ => "export.soon"
            })));
            var card = new Button
            {
                Content = tile, IsEnabled = open && !BusyFor(game), Margin = new Thickness(0, 0, 12, 0), Padding = new Thickness(18),
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Stretch, MinHeight = 120, CornerRadius = new CornerRadius(14),
                Background = on ? Brush.Parse("#2A2722") : Surface, Foreground = Ink, Opacity = open ? 1 : 0.5,
                BorderBrush = on ? Accent : Brush.Parse("#2A2A2E"), BorderThickness = new Thickness(on ? 1.5 : 1)
            };
            AutomationId(card, "export.platform." + platform);
            card.Click += (_, _) => { if (platform == PlatformTv) exportTv = !exportTv; else if (platform == "android") exportAndroid = !exportAndroid; else exportIos = !exportIos; Render(); };
            tiles.Children.Add(card);
        }
        body.Children.Add(tiles);
        body.Children.Add(LocationRow(game));
        if (exportAndroid && androidEnabled) body.Children.Add(AndroidPhoneRow(game));   // 出好装到哪台安卓手机；不选 / 没连 = 只出 APK
        if (exportIos) body.Children.Add(IosAfterPackPicker(game));   // 出完之后：装到 iPhone（下面是签名身份）/ 导出自签 IPA（11-16 维护者：一个入口、两条分叉各走到底）

        // action bar
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16 };
        var blocker = ExportBlocker(game);
        var reason = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        // 别的款正在出：说清点开始会排在它后面、它出完自动开始（同一时刻作业层只出一款：出包占整库的执行锁、吃满内存与 CPU）
        var behind = blocker is null && (packRunning || batchRunning) && packGame is { } running && running.Id != game.Id ? running : null;
        reason.Children.Add(Muted(blocker ?? (behind is not null ? T("export.queue.behind").Replace("{0}", behind.Name) : T("export.hint")), 14));
        if (ExportBlockerKind(game) == "keys") reason.Children.Add(Action("nav.library", () => Navigate("library")));
        bar.Children.Add(reason);
        var start = Primary(T(behind is not null ? "export.action.queue" : !exportIos ? "export.start" : IosAfterPack == "export" ? "export.start.selfsign" : "export.start.install"), () => StartPackBranch(game), !ExportStops(game));   // 缺文件 / 缺 keys 只在左边提示，不置灰（作业层核实）
        AutomationId(start, "export.start");
        Grid.SetColumn(start, 1); bar.Children.Add(start);
        body.Children.Add(Card(bar, 18));
    }

    /// <summary>存放位置（游戏库结构 v3，照 Mac ExportView.locationRow）：这款游戏的文件夹放在哪；换了位置，出包前先整个搬过去（存档跟着走）。
    /// 缺省：这款现在的位置（ok / offline）→ 上次用的位置 → 默认位置（StorageLocations.DefaultFor）。
    /// 批量出包清单页也用这一行（一批共用一个存放位置，按第一款读位置表），标题换成 batch.location。</summary>
    private Control LocationRow(LibraryGame game, string titleKey = "export.location.title")
    {
        if (locationsFor != game.Id)
        {
            locationsFor = game.Id; locations = null;
            exportLocation = game.Location is { State: "ok" or "offline" } here ? here.Path : "";
            _ = LoadLocationsAsync(game);
        }
        var rows = locations?.Rows ?? [];
        var options = new List<(string path, string label)>();
        foreach (var r in rows)
        {
            // 显示具体路径，不显示卷名（同 Mac 出包页）：同一块盘上的几个位置卷名一样，只给卷名分不清是哪个文件夹
            var name = r.Path;
            options.Add((r.Path, r.Connected
                ? T("export.location.free").Replace("{0}", name).Replace("{1}", r.FreeBytes is { } free ? FormatBytes(free) : "?")
                : T("export.location.offline").Replace("{0}", name)));
        }
        // 「选择其他文件夹…」选的、或位置表还没读回时这款现在的位置
        if (exportLocation.Length > 0 && !options.Any(o => SameFolder(o.path, exportLocation))) options.Add((exportLocation, exportLocation));
        var box = new ComboBox { MinWidth = 300, IsEnabled = !BusyFor(game), VerticalAlignment = VerticalAlignment.Center };
        foreach (var (path, label) in options) box.Items.Add(new ComboBoxItem { Content = label, Tag = path });
        box.Items.Add(new ComboBoxItem { Content = T("export.location.other"), Tag = OtherFolder });
        box.SelectedIndex = options.FindIndex(o => SameFolder(o.path, exportLocation));
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is not ComboBoxItem { Tag: string value }) return;
            if (value == OtherFolder) _ = ChooseLocationAsync();
            else { exportLocation = value; Avalonia.Threading.Dispatcher.UIThread.Post(Render); }   // 换位置后重画：下面那行提示跟着变
        };
        AutomationId(box, "export.location");
        var line = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16 };
        var title = Label(T(titleKey), 16); title.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(title);
        Grid.SetColumn(box, 1); line.Children.Add(box);
        if (SlackFor(exportLocation) is not { } why) return Card(line, 14);
        // #444：只提示不拦，原因说对（同 Mac ExportView.locationRow）：大簇「每个小文件至少占 N、多占数倍」/ 不是 NTFS「出包可能失败」
        var text = why.Reason == "cluster" ? T("export.location.slack_cluster_win").Replace("{0}", FormatBytes(why.ClusterBytes)) : T("export.location.slack_format_win");
        var slack = new TextBlock { Text = "⚠ " + text, FontSize = 13, TextWrapping = Avalonia.Media.TextWrapping.Wrap,
            Foreground = new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#FFC73D")) };
        AutomationId(slack, "export.location.slack");
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(line); stack.Children.Add(slack);
        return Card(stack, 14);
    }

    private LocationSlack? SlackFor(string path) =>
        locations?.Rows.FirstOrDefault(r => SameFolder(r.Path, path)) is { } row ? row.Slack : probedSlack.TryGetValue(path, out var slack) ? slack : null;

    // ---- S 级优化（Beta，11-13 维护者：根据游戏和版本自动匹配社区补丁并展示，命中的默认打上；同 Mac launchers/macos/frontend/Sources/NX2Apple/SGradeCard.swift）----
    private string? sgradeFor; private JsonElement? sgrade; private bool sgradeFailed;

    // 金色（11-13 维护者：这个功能很牛，做得精致高级、显眼一点，用金色版 logo 的 S）：金色毛玻璃双色 S（上半香槟金、下半玫瑰金，
    //   launchers/macos/Branding/make_s_gold.py 由应用图标生成），卡片的标题 / 描边 / 图标钮同一套配色；命中时整张亮起来（同 Mac SGradeCard.swift）
    private static readonly Color SGoldHi = Color.FromRgb(255, 235, 179), SGold = Color.FromRgb(237, 196, 107), SRose = Color.FromRgb(237, 158, 133);
    private Bitmap? sGoldBitmap;
    private Bitmap SGoldImage()
    {
        if (sGoldBitmap is not null) return sGoldBitmap;
        using var stream = Avalonia.Platform.AssetLoader.Open(new Uri("avares://S2Arm/Assets/SGold.png"));
        return sGoldBitmap = Bitmap.DecodeToWidth(stream, 192);
    }
    private static Color A(Color c, double alpha) => Color.FromArgb((byte)Math.Round(alpha * 255), c.R, c.G, c.B);
    private static LinearGradientBrush Diag(params (Color c, double at)[] stops)
    {
        var g = new LinearGradientBrush { StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative) };
        foreach (var (c, at) in stops) g.GradientStops.Add(new GradientStop(c, at));
        return g;
    }


    private Control SGradeCard(LibraryGame game)
    {
        if (sgradeFor != game.Id) { sgradeFor = game.Id; sgrade = null; sgradeFailed = false; _ = LoadSGradeAsync(game); }
        var stack = new StackPanel { Spacing = 12 };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9 };
        title.Children.Add(new TextBlock { Text = T("export.sgrade.title"), FontSize = 18, FontWeight = FontWeight.Bold, VerticalAlignment = VerticalAlignment.Center,
            Foreground = new LinearGradientBrush { StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 0, RelativeUnit.Relative),
                GradientStops = { new GradientStop(SGoldHi, 0), new GradientStop(SGold, 0.5), new GradientStop(SRose, 1) } } });
        title.Children.Add(new Border { BorderBrush = new SolidColorBrush(A(SGold, 0.55)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(999),
            Padding = new Thickness(7, 1.5), VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = "BETA", FontSize = 9.5, FontWeight = FontWeight.Bold, LetterSpacing = 1.4, Foreground = new SolidColorBrush(SGold) } });
        // 出包时打入（v0.4.0 维护者：Beta 功能出包页默认勾上，玩家可取消；取消 = 这次出包不带社区补丁与金手指，同 Mac SGradeCard.swift）
        var on = !SGradeOff().Contains(game.Id);
        var check = new CheckBox { Content = T("export.sgrade.toggle"), IsChecked = on, VerticalAlignment = VerticalAlignment.Center, FontSize = 12.5 };
        check.Click += (_, _) => SetSGrade(game.Id, check.IsChecked == true);
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        head.Children.Add(title); Grid.SetColumn(check, 1); head.Children.Add(check);
        stack.Children.Add(head);
        var lit = false;
        if (sgradeFailed) stack.Children.Add(Muted(T("export.sgrade.unknown"), 12));
        else if (sgrade is not { } r) stack.Children.Add(Muted(T("export.sgrade.loading"), 12.5));
        else
        {
            var exact = r.TryGetProperty("exact", out var e) ? e : default;
            int Hit(string cat) => exact.ValueKind == JsonValueKind.Object && exact.TryGetProperty(cat, out var n) ? n.GetInt32() : 0;
            int total = Hit("widescreen") + Hit("fps") + Hit("cheat");
            // 满屏 / 帧率解锁 / 金手指固定三行（11-15 维护者定：三项金色字 + 金色 S，三端一致）。Windows 不跑游戏：只写会打进包里的东西、
            //   进了包在哪开关（iPhone 齿轮菜单）；画面补丁只进 Mac 版，Windows 出的是 iPhone 包，不列
            var rows = new StackPanel { Spacing = 10 };
            void Row(string titleText, string note, bool dim = false, Control? action = null)
            {
                var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 11, Opacity = dim ? 0.55 : 1 };
                row.Children.Add(new Image { Source = SGoldImage(), Width = 22, Height = 22, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 0, 0) });
                var text = new StackPanel { Spacing = 2 };
                text.Children.Add(new TextBlock { Text = titleText, FontSize = 14, FontWeight = FontWeight.Bold,
                    Foreground = new LinearGradientBrush { StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 0, RelativeUnit.Relative),
                        GradientStops = { new GradientStop(SGoldHi, 0), new GradientStop(SGold, 1) } } });
                text.Children.Add(new TextBlock { Text = note, FontSize = 12, Foreground = new SolidColorBrush(Color.FromRgb(168, 168, 173)), TextWrapping = TextWrapping.Wrap });
                Grid.SetColumn(text, 1); row.Children.Add(text);
                if (action is not null) { action.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(action, 2); row.Children.Add(action); }
                rows.Children.Add(row);
            }
            // 满屏跨版本（patches.match port，同 Mac SGradeCard）：这份没有同版本的满屏补丁、别的版本有 → 出包时尝试移植
            var port = r.TryGetProperty("port", out var pp) && pp.ValueKind == JsonValueKind.True;
            string portText = "";
            if (port)
            {
                var pv = r.TryGetProperty("portVersions", out var pvs) && pvs.ValueKind == JsonValueKind.Array ? pvs.EnumerateArray().Select(v => v.GetString() ?? "").Where(v => v.Length > 0).Take(3).ToList() : new List<string>();
                portText = T("export.sgrade.port").Replace("{0}", pv.Count > 0 ? string.Join(language == "en" ? ", " : "、", pv) : T("export.sgrade.port.any"));
            }
            Row(T("sgrade.row.fs"), Hit("widescreen") > 0 ? T("sgrade.win.patch") : port ? portText : T("sgrade.win.fs.own"));
            Row(T("sgrade.row.fps"), Hit("fps") > 0 ? T("sgrade.win.patch") : T("sgrade.win.fps.fi"));
            Row(T("sgrade.row.cheats"), Hit("cheat") > 0 ? T("export.sgrade.hit.cheat").Replace("{0}", Hit("cheat").ToString()) : T("sgrade.cheats.none"), dim: Hit("cheat") == 0);
            // Mod（11-15 维护者「打包页增加 mod 导入，S 级优化又升级了」，同 Mac SGradeCard）：带代码补丁的 mod 出包时编进程序；按钮打开这款的 Mod 页（ModsPage.cs）导入
            var modBtn = new Button { Content = T("export.sgrade.mod.import"), FontSize = 12.5 };
            modBtn.Click += (_, _) => OpenMods(game);
            Avalonia.Automation.AutomationProperties.SetAutomationId(modBtn, "export.sgrade.mod.import");
            var modAct = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };   // mod 格式说明「？」放在「导入 Mod」旁（11-17，ModsPage.cs ModHelp）
            modAct.Children.Add(ModHelp()); modAct.Children.Add(modBtn);
            Row(T("export.sgrade.cat.mod"), Hit("mod") > 0 ? T("export.sgrade.hit.mod").Replace("{0}", Hit("mod").ToString()) : T("export.sgrade.mod.note"), action: modAct);
            var build = r.TryGetProperty("build", out var b) ? b.GetString() ?? "" : "";
            // 补丁按版本生效（11-14 维护者）：写明对应玩家这份游戏的哪个版本；列出的别的版本不会打入（同 Mac SGradeCard）
            var ver = r.TryGetProperty("version", out var vv) ? vv.GetString() ?? "" : "";
            var mine = ver.Length > 0 ? ver : (build.Length > 16 ? build[..16] : build).ToUpperInvariant();
            // 满屏（通用满屏）与帧率解锁（补帧）没有补丁也能用：三行总是列出，卡片总是亮
            lit = true; stack.Children.Add(rows);
            if (total > 0) stack.Children.Add(Muted(T("export.sgrade.hit.version").Replace("{0}", mine), 12));
            else if (build.Length == 0) stack.Children.Add(Muted(T("export.sgrade.later"), 12));
            if (total > 0 || port) stack.Children.Add(Muted(T("export.sgrade.hit.note"), 12));
            if (total == 0 && !port)
            {
                if (build.Length > 0) stack.Children.Add(Muted(T("export.sgrade.none").Replace("{0}", mine), 12));   // 没解过包的「出包时核对」上面已写
                if (r.TryGetProperty("others", out var others) && others.ValueKind == JsonValueKind.Array && others.GetArrayLength() > 0)
                {
                    var sep = language == "en" ? ", " : "、";
                    var (open, close) = language == "en" ? (" (", ")") : ("（", "）");
                    var parts = others.EnumerateArray().Take(6).Select(o => o.GetProperty("version").GetString() + open +
                        string.Join(sep, o.GetProperty("cats").EnumerateArray().Select(c => T("export.sgrade.cat." + c.GetString()))) + close);
                    stack.Children.Add(Muted(T(build.Length == 0 ? "export.sgrade.listed" : "export.sgrade.others") + string.Join(language == "en" ? "; " : "；", parts), 12));
                }
            }
        }
        if (!on) { while (stack.Children.Count > 1) stack.Children.RemoveAt(1); stack.Children.Add(Muted(T("export.sgrade.off"), 12)); lit = false; }
        var size = lit ? 56 : 44;
        var s = new Image { Source = SGoldImage(), Width = size, Height = size, VerticalAlignment = VerticalAlignment.Top, Opacity = lit || sgrade is null ? 1 : 0.7,
            Effect = new DropShadowEffect { Color = SGold, BlurRadius = lit ? 22 : 8, OffsetX = 0, OffsetY = 0, Opacity = lit ? 0.55 : 0.18 } };
        var row0 = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 18 };
        row0.Children.Add(s); Grid.SetColumn(stack, 1); row0.Children.Add(stack);
        var glow = new RadialGradientBrush { Center = new RelativePoint(0, 0, RelativeUnit.Relative), GradientOrigin = new RelativePoint(0, 0, RelativeUnit.Relative),
            RadiusX = new RelativeScalar(0.9, RelativeUnit.Relative), RadiusY = new RelativeScalar(1.6, RelativeUnit.Relative),
            GradientStops = { new GradientStop(A(SGold, lit ? 0.18 : 0.06), 0), new GradientStop(A(SGold, 0), 1) } };
        return new Border
        {
            CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1), Background = new SolidColorBrush(Color.FromRgb(26, 26, 28)),
            BorderBrush = Diag((A(SGoldHi, lit ? 0.75 : 0.30), 0), (A(SGold, 0.12), 0.5), (A(SRose, lit ? 0.55 : 0.18), 1)),
            BoxShadow = lit ? BoxShadows.Parse("0 6 22 0 #24EDC46B") : default,
            Child = new Border { CornerRadius = new CornerRadius(16), Background = glow, Padding = new Thickness(22, 20), Child = row0 },
        };
    }

    // 「出包时打入」取消过的款（按程序号记在私有目录 sgrade-off.json；没记过 = 勾上）
    private HashSet<string>? sgradeOff;
    private string SGradeOffPath => Path.Combine(privateRoot, "sgrade-off.json");
    private HashSet<string> SGradeOff()
    {
        if (sgradeOff is not null) return sgradeOff;
        try { sgradeOff = JsonOut.ReadStringSet(File.ReadAllText(SGradeOffPath)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { sgradeOff = []; }
        return sgradeOff;
    }
    private void SetSGrade(string gameId, bool on)
    {
        var set = SGradeOff();
        if (on) set.Remove(gameId); else set.Add(gameId);
        try { Directory.CreateDirectory(privateRoot); File.WriteAllText(SGradeOffPath, JsonOut.Serialize(set)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }   // 记不住只影响下次进页面的初值；这次出包照当前勾选
        Render();
    }

    private async Task LoadSGradeAsync(LibraryGame game)
    {
        if (connectedFolder is null || libraryId is null) return;
        try
        {
            var job = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder, libraryId, "patchMatch", null, CancellationToken.None, gameId: game.Id);
            if (sgradeFor != game.Id) return;
            if (job.Report.Succeeded && job.Report.Result.ValueKind == JsonValueKind.Object) sgrade = job.Report.Result.Clone(); else sgradeFailed = true;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception or KeyNotFoundException) { sgradeFailed = true; }
        if (page is "build" or "batch") Render();
    }

    /// <summary>问作业层：安卓出包开没开（开关只在后端读）、adb 列出哪些手机；选过的那台不在了就清掉选择</summary>
    private async Task LoadAndroidPhonesAsync()
    {
        if (connectedFolder is null || libraryId is null) return;
        try
        {
            var job = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder, libraryId, "androidDevices", null, CancellationToken.None);
            if (!job.Report.Succeeded || job.Report.Result.ValueKind != JsonValueKind.Object) return;
            var res = job.Report.Result;
            androidEnabled = res.TryGetProperty("enabled", out var en) && en.ValueKind == JsonValueKind.True;
            var phones = new List<(string, string, string)>();
            if (res.TryGetProperty("devices", out var list) && list.ValueKind == JsonValueKind.Array)
                foreach (var d in list.EnumerateArray())
                    if (d.TryGetProperty("serial", out var serial) && serial.GetString() is { Length: > 0 } sn)
                        phones.Add((sn, d.TryGetProperty("state", out var st) ? st.GetString() ?? "" : "", d.TryGetProperty("model", out var m) ? m.GetString() ?? "" : ""));
            androidPhones = phones;
            if (androidPhoneChoice is { Length: > 0 } pick && !phones.Any(p => p.Item1 == pick)) androidPhoneChoice = null;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception or KeyNotFoundException) { return; }
        if (page is "build") Render();
    }

    /// <summary>出好装到哪台：玩家选的 &gt; 只连着一台可用的就是它 &gt; null（只出 APK）</summary>
    private string? AndroidPhone =>
        androidPhoneChoice is { } pick ? (pick.Length == 0 ? null : pick)
        : androidPhones.Where(p => p.State == "device").ToList() is { Count: 1 } one ? one[0].Serial : null;

    private Control AndroidPhoneRow(LibraryGame game)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(Muted(T("export.android.device"), 14));
        if (androidPhones.Count == 0) row.Children.Add(Muted(T("export.android.none"), 13));
        else
        {
            var box = new ComboBox { MinWidth = 300, IsEnabled = !BusyFor(game), VerticalAlignment = VerticalAlignment.Center };
            foreach (var (serial, state, model) in androidPhones)
            {
                var name = model.Length > 0 ? model : serial;
                box.Items.Add(new ComboBoxItem { Content = state == "device" ? name : T("export.android.unauthorized").Replace("{0}", name), Tag = serial });
            }
            box.Items.Add(new ComboBoxItem { Content = T("export.android.skip"), Tag = "" });
            var current = AndroidPhone ?? "";
            box.SelectedIndex = box.Items.Cast<ComboBoxItem>().ToList().FindIndex(i => (string?)i.Tag == current);
            box.SelectionChanged += (_, _) => { if (box.SelectedItem is ComboBoxItem { Tag: string value }) androidPhoneChoice = value; };
            AutomationId(box, "export.android");
            row.Children.Add(box);
        }
        row.Children.Add(Action("export.android.refresh", () => _ = LoadAndroidPhonesAsync()));
        return row;
    }

    private async Task LoadLocationsAsync(LibraryGame game, string? probe = null)
    {
        if (connectedFolder is null || libraryId is null) return;
        try
        {
            var job = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder, libraryId, "locations", null, CancellationToken.None, probe: probe);
            if (!job.Report.Succeeded || locationsFor != game.Id) return;
            locations = StorageLocations.Parse(job.Report.Result);
            if (probe is not null && locations.Probed) probedSlack[probe] = locations.ProbeSlack;
            if (exportLocation.Length == 0) exportLocation = locations.DefaultFor(game.Location);
        }
        // 读不回位置表同 Mac：下拉框只剩这款现在的位置和「选择其他文件夹…」，不选就不传，后端按这款现在的位置出包
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception or KeyNotFoundException) { return; }
        if (page is "build" or "batch") Render();
    }

    private async Task ChooseLocationAsync()
    {
        try
        {
            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = T("export.location.title") });
            if (folders.Count > 0)
            {
                exportLocation = LocalPath(folders[0]);
                if (catalog?.Games.FirstOrDefault(g => g.Id == locationsFor) is { } game) _ = LoadLocationsAsync(game, exportLocation);   // 查这块盘会不会让解包多占数倍空间（#444）
            }
        }
        catch (IOException) { }   // 不是本地文件夹：不换
        Render();   // 取消时下拉框退回原来选的那项
    }

    private static bool SameFolder(string a, string b) =>
        string.Equals(a.TrimEnd('\\', '/'), b.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);

    private static void AutomationId(Control control, string id) => Avalonia.Automation.AutomationProperties.SetAutomationId(control, id);

    /// <summary>Why export cannot start now (null = it can). Order as the Mac export page: platform → game files → keys → busy.</summary>
    private string? ExportBlocker(LibraryGame game) => ExportBlockerKind(game) switch
    {
        "platform" => T("export.block.no_platform"),
        "files" => T("library.requirements") + " · " + string.Join(" / ", game.Missing),
        "keys" => T("export.block.keys"),
        "busy" => T("export.block.busy"),
        "queued" => T("export.queue.waiting").Replace("{0}", packGame?.Name ?? ""),
        _ => null,
    };

    /// <summary>挡路的是哪一类（按种类判，不拿显示文案做字符串相等，剃刀 W10）：platform / files / keys / busy；null = 能出。</summary>
    /// <summary>挡不挡开始：缺文件（files）/ 缺 keys（keys）只提示、不挡（v0.3.1「拿不准不停」，同 Mac ExportBlocker.stopsStart）——
    /// 两项来自游戏库读数、可能是旧的；出包作业开头自己核（library.requirement_errors：input_missing / keys_missing），真缺才停</summary>
    private bool ExportStops(LibraryGame game) => ExportBlockerKind(game) is { } kind && kind is not ("files" or "keys");

    private string? ExportBlockerKind(LibraryGame game)
    {
        if (!exportIos && !exportTv && !(exportAndroid && androidEnabled)) return "platform";
        if (game.Missing.Count > 0) return "files";
        if (game.NeedsKeys && catalog?.KeysReady != true) return "keys";
        if (exportQueue.Any(q => q.Game.Id == game.Id)) return "queued";
        // 出包（单款或批量）在跑时别的款不挡、点了就排队，出完接着出（同 Mac S2ArmLauncherModel.export，「不许堵门」）；
        //   正在出的这款本身、别的作业锁着这款（装机只锁装的那款，导入 / 游戏库 / 释放空间锁全部）、环境检查中照旧挡
        if (LockedNow(game)) return "busy";
        return null;
    }

    /// <summary>这款现在被锁着、不能起出包：环境检查中、别的作业锁着这款（出包作业除外，那种排队）、或正在出的就是这款</summary>
    private bool LockedNow(LibraryGame game) =>
        busy || jobs.Any(j => j.Kind != JobKind.Pack && j.Blocks(game.Id)) || ((packRunning || batchRunning) && packGame?.Id == game.Id);

    private PackJobClient.Request PackRequest(string operation, string gameId, IReadOnlyDictionary<string, object?>? extra = null) =>
        new(paths, privateRoot, connectedFolder!, libraryId!, operation, gameId, extra);

    // ---- pack job ----

    /// <summary>出包在跑时点「开始出包」的款：按点的顺序排着，前一个出完（单款或一批）接着出（同 Mac exportQueue）</summary>
    private readonly List<(LibraryGame Game, bool SpaceOverride, string? Location)> exportQueue = new();

    // ---- 下游深度方案（#1272，同 Mac DownstreamConfirmSheet）：这款有下游项目做的专门移植时，导出 iPhone 前问玩家一次用哪套；
    //   选完记下（downstreamChoice 作业，"" = 仍用原版）再接着出，之后的出包 / 装机作业按记下的选择分流。出包页「移植方案」一行能改 ----
    private string downstreamError = "";

    /// <summary>界面上点「开始出包 / 导出自签包」：这款有下游方案、还没选过、这次出 iPhone → 先弹确认页，选完接着出；关掉确认页 = 这次不出。
    /// 控制口（AI 操作）直接走 StartPack，不弹页</summary>
    private async Task StartPackAskedAsync(LibraryGame game)
    {
        if (game.Downstream is { Choice: null } && exportIos)
        {
            if (!await ChooseDownstreamAsync(game)) { selfSignAfterPack.Remove(game.Id); Render(); return; }
            game = catalog?.Games.FirstOrDefault(g => g.Id == game.Id) ?? game;
        }
        StartPack(game);
    }

    /// <summary>弹确认页、记下选择、重读游戏库；没选（关掉）或记不下 → false（原因写在出包页「移植方案」下）</summary>
    private async Task<bool> ChooseDownstreamAsync(LibraryGame game)
    {
        if (game.Downstream is not { } offer || await AskDownstreamAsync(game, offer) is not { } scheme) return false;
        downstreamError = "";
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("downstreamChoice", game.Id, new Dictionary<string, object?> { ["scheme"] = scheme }), null, CancellationToken.None);
            if (!job.Report.Succeeded) downstreamError = job.Report.Message;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { downstreamError = error.Message; }
        if (downstreamError.Length > 0) { Render(); return false; }
        await RunLibraryAsync("catalog", null);
        Render();
        return true;
    }

    /// <summary>确认页（文案全部来自登记表，游戏名用玩家游戏包里的名字）：「仍用原版方案」→ ""，推荐方案 → 方案 id（物理上做不出来时置灰、写原因），关掉 → null</summary>
    private async Task<string?> AskDownstreamAsync(LibraryGame game, DownstreamOffer offer)
    {
        if (offer.Text(language) is not { } text) return null;
        var dialog = NewDialog(text.Title, 560);
        string? choice = null;
        var body = new StackPanel { Spacing = 14, Margin = new Thickness(28) };
        body.Children.Add(Label(text.Title, 20));
        body.Children.Add(Muted(game.Name, 13));
        var reading = new StackPanel { Spacing = 10 };
        reading.Children.Add(new TextBlock { Text = text.Body, FontSize = 14, TextWrapping = TextWrapping.Wrap });
        foreach (var point in text.Points) reading.Children.Add(new TextBlock { Text = "✓  " + point, FontSize = 13, TextWrapping = TextWrapping.Wrap, Foreground = Brush.Parse("#A8A6A1") });
        body.Children.Add(new ScrollViewer { Content = reading, MaxHeight = 360 });   // 说明长时在这里滚，按钮始终在窗口里
        if (!offer.Eligible) { var why = Muted(offer.Why(language), 13); AutomationId(why, "downstream.reason"); body.Children.Add(why); }
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var original = DialogButton(text.Original, false, () => { choice = ""; dialog.Close(); });
        AutomationId(original, "downstream.original");
        var recommend = DialogButton(text.Recommend, true, () => { choice = offer.Id; dialog.Close(); });
        recommend.IsEnabled = offer.Eligible;
        AutomationId(recommend, "downstream.recommend");
        buttons.Children.Add(original); buttons.Children.Add(recommend);
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        return choice;
    }

    /// <summary>出包页「移植方案」：选过才出，写当前用哪套、「更改」弹同一个确认页（只记下选择，不顺带出包）；没选过不出（导出 iPhone 时会问）</summary>
    private Control? DownstreamRow(LibraryGame game)
    {
        if (game.Downstream is not { Choice: { } choice } offer) return null;
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(Label(T("export.downstream.group"), 16));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var current = new TextBlock { Text = choice.Length == 0 ? offer.Text(language)?.Original ?? "" : offer.Name, FontSize = 15, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        AutomationId(current, "export.downstream");
        row.Children.Add(current);
        var change = Action("export.downstream.change", () => _ = ChooseDownstreamAsync(game), !BusyFor(game));
        Grid.SetColumn(change, 1); row.Children.Add(change);
        panel.Children.Add(Card(row, 16));
        panel.Children.Add(Muted(downstreamError.Length > 0 ? downstreamError : T("export.downstream.note"), 13));
        return panel;
    }

    private void StartPack(LibraryGame game, bool spaceOverride = false)
    {
        if (ExportStops(game)) return;
        // 「仍然出包」重试沿用这一款上次选的位置；出包页没读到这款时不传，后端按这款现在的位置
        var location = !spaceOverride || packGame?.Id != game.Id ? (locationsFor == game.Id && exportLocation.Length > 0 ? exportLocation : null) : packLocation;
        if (packRunning || batchRunning)
        {
            exportQueue.Add((game, spaceOverride, location));
            Render();
            return;
        }
        packLocation = location;
        ResetPack(game);
        Navigate("progress");
        packOperation = RunPackAsync(game, spaceOverride);
    }

    /// <summary>出包（单款或一批）收尾后、以及任何作业收尾后（EndJob）接着出排队的下一款。排头那款被别的作业暂时锁着
    ///   （出包收尾紧跟着刷新游戏库，那一下所有款都锁着）就原样留在排头、等下一个作业收尾再看；只有这款已不在游戏库、或出 iPhone 关了才从队里拿掉。
    /// 不跳出包页：玩家正看着别的页就留在原页，状态在顶栏和出包页看得到</summary>
    private void PumpExportQueue()
    {
        while (!packRunning && !batchRunning && exportQueue.Count > 0)
        {
            var (queued, spaceOverride, location) = exportQueue[0];
            var game = catalog?.Games.FirstOrDefault(g => g.Id == queued.Id && !g.Hidden);
            if (game is not null && (exportIos || exportTv) && LockedNow(game)) return;   // 暂时锁着：留在排头，等作业收尾再来
            exportQueue.RemoveAt(0);
            if (game is null || !exportIos && !exportTv) continue;   // 已不在游戏库 / 平台都没勾：拿掉，接着下一款
            var watching = page == "progress";
            packLocation = location;
            ResetPack(game);
            if (watching) Navigate("progress"); else sessionHidden = true;
            packOperation = RunPackAsync(game, spaceOverride);
        }
        Render();
    }

    /// 开始出一款前清掉上一款的出包状态，并登记这次出包的作业（出包页「开始出包」）
    private void ResetPack(LibraryGame game)
    {
        ResetPackView(game);
        packJob = BeginJob(JobKind.Pack, game.Id);
    }

    /// 只清显示：批量出包时编排作业一步换一款，作业登记一批只有一份（BatchPage.cs RunBatchExport）
    private void ResetPackView(LibraryGame game)
    {
        packGame = game; packState = "running"; packTrack = new(); packStarted = DateTime.UtcNow;
        packSeconds = null; packSummary = ""; packDiagnostics = ""; packIpa = null;
        packIpaBytes = null; packPackBytes = null; packNotes = []; packBoost = null; packSpace = null; sessionHidden = false; packFailureCode = null;
        exportStepEnded = false; exportChildReport = null;
    }

    /// <summary>出包页单款：同批量出包走出包编排作业（剃刀 H13），计划只有这一款勾了的平台（iPhone / Apple TV）、不写批次文件</summary>
    private Task RunPackAsync(LibraryGame game, bool spaceOverride)
    {
        var platforms = new List<string>();
        if (exportIos) platforms.Add("iphone");
        if (exportTv) platforms.Add("appletv");
        if (exportAndroid && androidEnabled) platforms.Add("android");
        var plan = ExportStream.InlinePlan(game.Id, game.Name, platforms, packLocation, spaceOverride);
        if (platforms.Contains("android") && AndroidPhone is { } serial) plan["androidSerial"] = serial;   // 出好接着装到这台安卓手机（export_plan → installSerial）
        if (SGradeOff().Contains(game.Id)) plan["sgrade"] = false;   // 出包页取消「S 级优化（Beta）」：这次不带社区补丁与金手指（pack/jobs/patches.py prepare）
        return RunExportAsync(plan, batch: false, mode: selfSignAfterPack.Contains(game.Id) ? "export" : null);
    }

    // 这一步收到 stepEnded 没有（没收到 = 编排作业在第一步前就结束了：被拒、已有一个在出、取消）；子作业的终态（失败页的原因 / 建议从这里读）
    private bool exportStepEnded;
    private LibraryJobResult? exportChildReport;

    /// <summary>跑一个出包编排作业：每一步的开始 / 子作业事件 / 结局都由 OnExportEvent 显示；取消 = 取消这个作业（它把正在出的那步停下）</summary>
    private LibraryGame? exportAfterPack;   // 这次出完要接着导出的那款（出包作业收尾后起导出）
    /// <summary>「导出自签包」点在没出过包的款上：这几款出完 iPhone 包接着导出（不是装机）</summary>
    private readonly HashSet<string> selfSignAfterPack = new();
    /// <summary>出包页选了「出完装到 iPhone」的款：iPhone 包出好接着装（同 selfSignAfterPack，走装机）</summary>
    private readonly HashSet<string> installAfterPack = new();
    private LibraryGame? installAfterPackGame;
    /// <summary>出包页「出完之后」玩家选的那条路（install / export），记在私有目录（ios-after-export 在 = 导出自签）；「更新 iPhone 上的 S2Arm」也按它走</summary>
    private string IosAfterPack
    {
        get => File.Exists(Path.Combine(privateRoot, "ios-after-export")) ? "export" : "install";
        set
        {
            try { PrivateJobRequest.EnsurePrivateRoot(privateRoot); var f = Path.Combine(privateRoot, "ios-after-export"); if (value == "export") File.WriteAllBytes(f, []); else File.Delete(f); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>玩家选了「出完导出自签 IPA」：自动装到手机（连上就更新、新版首启横幅）一律跳过，玩家自己签名安装</summary>

    /// <summary>出包页的「开始」：出 iPhone 时按「出完之后」那条路一步走完（装到 iPhone / 导出自签包）</summary>
    private void StartPackBranch(LibraryGame game)
    {
        if (exportIos) { if (IosAfterPack == "export") selfSignAfterPack.Add(game.Id); else installAfterPack.Add(game.Id); }
        _ = StartPackAskedAsync(game);
    }

    /// <summary>出包页「出完之后」：两张卡二选一（同 Mac IosAfterPackPicker）；装到 iPhone 时下面接签名身份那一行</summary>
    private Control IosAfterPackPicker(LibraryGame game)
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(Muted(T("export.after.title"), 13));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), ColumnSpacing = 12 };
        var i = 0;
        foreach (var (id, title, note) in new[] { ("install", "export.after.install", "export.after.install_note"), ("export", "export.after.export", "export.after.export_note") })
        {
            var on = IosAfterPack == id;
            var text = new StackPanel { Spacing = 4 };
            text.Children.Add(Label((on ? "● " : "○ ") + T(title), 15));
            var n = Muted(T(note), 12); n.TextWrapping = TextWrapping.Wrap; text.Children.Add(n);
            var card = new Button { Content = text, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Top,   // 两张卡同高（说明长短不同也不错位）
                Padding = new Thickness(14, 12), CornerRadius = new CornerRadius(12), Foreground = Ink,
                Background = on ? Brush.Parse("#2A2722") : Surface, BorderBrush = on ? Accent : Brush.Parse("#2A2A2E"), BorderThickness = new Thickness(on ? 1.5 : 1) };
            AutomationId(card, "export.after." + id);
            card.Click += (_, _) => { IosAfterPack = id; Render(); };
            Grid.SetColumn(card, i++); row.Children.Add(card);
        }
        panel.Children.Add(row);
        if (IosAfterPack != "export") panel.Children.Add(InstallModeLine());
        panel.Children.Add(Card(LayoutCards(game.Id), 14));   // 装到手机 / 导出两种去向都按这款的出法走（0.6.4）：出法两张卡 + 卡片下方一行提示
        return panel;
    }

    /// <summary>这次装机作业是导出自签包：进度 / 结局按导出写，装机页只画结局卡、不画装机清单</summary>
    private bool installExport;

    /// <summary>游戏库「导出自签包」（11-15 维护者：导出不是装法，按钮常驻、1 下开始导出、不经装机清单）：iPhone 包能直接导出（新格式）的直接导出；
    ///   没出过、或包是旧格式的先出 iPhone 包再导出（玩家点的是导出，就把导出做完）</summary>
    private void ExportSelfSign(LibraryGame game)
    {
        libraryFolder = libraryFolderBox.Text ?? libraryFolder;
        selectedGame = game.Id;
        if (game.IphoneExportable) { _ = InstallAsync(game, export: true); Navigate("install"); return; }
        selfSignAfterPack.Add(game.Id);
        if (ExportStops(game)) { selfSignAfterPack.Remove(game.Id); OpenBuild(); return; }   // 出不了（缺文件 / 没勾 iPhone 等）：去出包页看原因
        _ = StartPackAskedAsync(game);
    }

    private async Task RunExportAsync(Dictionary<string, object?> plan, bool batch, string? mode = null)
    {
        var front = packJob!;
        LibraryJobOutput? job = null;
        string? error = null, endState = null;
        try
        {
            var extra = new Dictionary<string, object?> { ["plan"] = plan };
            if (mode is not null) extra["mode"] = mode;   // 这次出包是为了导出自签包：作业层步骤名照自签路写（子作业照带）
            job = await PackJobClient.RunAsync(PackRequest("export", "", extra),
                e => Dispatcher.UIThread.Post(() => OnExportEvent(e, batch)), front.Token, front.Next());
        }
        catch (LibraryProtocolException e) { endState = "invalid"; error = e.Message; }
        catch (OperationCanceledException) { endState = "cancelled"; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or
            PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { endState = "failed"; error = e.Message; }
        finally
        {
            // 事件还在排队：排在它们后面收尾
            Dispatcher.UIThread.Post(() =>
            {
                if (!exportStepEnded && packGame is not null && !batch)
                {
                    // 第一步还没结束编排作业就停了：整个作业的结局就是这一款的结局（被拒、已有一个在出、取消、起不来）
                    packTrack.Finish(Clock); packSeconds = (DateTime.UtcNow - packStarted).TotalSeconds;
                    packState = endState ?? (job!.Report.State == "succeeded" ? "failed" : job.Report.State);
                    packSummary = job?.Report.Message ?? "";
                    packDiagnostics = job is not null ? JobDiagnostics(job) : error ?? "";
                    packFailureCode = job is not null ? DiagnosticCode(job.Report.Diagnostics) : null;
                }
                EndJob(front); if (packJob == front) packJob = null;
                AfterArtifactJob(); Render();
                if (batch) _ = BatchExportEndedAsync(job?.Report, error);
                else if (exportAfterPack is { } g) { exportAfterPack = null; selfSignAfterPack.Remove(g.Id); _ = InstallAsync(g, export: true); }
                else if (installAfterPackGame is { } ig) { installAfterPackGame = null; installAfterPack.Remove(ig.Id); _ = InstallAsync(ig); Navigate("install"); }   // 选了「出完装到 iPhone」：接着装
                else if (packGame is { } pg) { selfSignAfterPack.Remove(pg.Id); installAfterPack.Remove(pg.Id); }   // 出包没成（起不来 / 失败 / 取消）：标记清掉，这款以后正常出包不再当导出画
                if (!batch) PumpExportQueue();
            });
        }
    }

    /// <summary>编排作业的一条事件（UI 线程）：step 换到这一款、child 喂进度、stepEnded 记这一款的结局</summary>
    private void OnExportEvent(JsonElement e, bool batch)
    {
        ExportStream.Event? ev;
        try { ev = ExportStream.Read(e); }
        catch (LibraryProtocolException error) { if (batch) batchError = error.Message; else packDiagnostics = error.Message; return; }
        switch (ev)
        {
            case ExportStream.Started started:
                if (batch && BatchGame(started.Where.GameId) is { } next) { packLocation = batchState?.Location; ResetPackView(next); sessionHidden = true; }
                exportStepEnded = false; exportChildReport = null;
                if (batch) _ = ReloadBatchAsync(); else Render();
                break;
            case ExportStream.Child child:
                packTrack.Ingest(child.Inner, Clock);
                // space event: { "type": "space", "space": { "volumes": [...] } }
                if (child.Inner.TryGetProperty("type", out var et) && et.GetString() == "space" && child.Inner.TryGetProperty("space", out var sp))
                    packSpace = PackSpace.TryParse(sp);
                if (ExportStream.ChildResult(child.Inner) is { } report) exportChildReport = report;
                break;
            case ExportStream.Ended ended:
                var o = ended.Outcome;
                packTrack.Finish(Clock); packSeconds = (DateTime.UtcNow - packStarted).TotalSeconds;
                packState = o.State == "completed" ? "succeeded" : o.State;
                packSummary = o.Message; packIpa = o.Ipa; packIpaBytes = o.IpaBytes; packPackBytes = o.PackBytes; packNotes = o.Notes ?? []; packBoost = o.Boost; packFailureCode = o.Code;
                if (ended.Where.Platform == "appletv" && o.State == "completed") packNotes = [.. packNotes, T("export.done.tvos_win")];   // Windows 出好 Apple TV 包并导出了安装包：说清在哪、自己签名装
                packDiagnostics = exportChildReport is { } r
                    ? JobDiagnostics(new LibraryJobOutput(r, new ProbeOutput(r.State == "succeeded" ? 0 : r.State == "cancelled" ? 130 : 1, "", "")))
                    : o.Message;
                exportStepEnded = true;
                // 出好了（卡片上的 iPhone 就绪状态要更新）或换了存放位置：重读游戏库，出包页下次重读位置表（社区贡献者补丁 #7）
                var game = BatchGame(ended.Where.GameId);
                if (packState == "succeeded" || packLocation is not null && game is not null && !SameFolder(packLocation, game.Location?.Path ?? ""))
                { locationsFor = null; _ = RefreshLibraryAsync(); }   // 在忙就补刷（剃刀 W8）
                if (packState == "succeeded")
                {
                    readinessFor = null;
                    if (packGame is not null) finishedPacks[packGame.Id] = (packState, packIpa ?? "", packIpaBytes, packPackBytes, packSeconds ?? 0);
                    // 「导出自签包」点在没出过包的款上：出好就接着导出（D-9ZF9，同 Mac exportSink）；导出不连手机、不签名，等这次出包作业收尾后起
                    if (!batch && packGame is not null && selfSignAfterPack.Contains(packGame.Id)) exportAfterPack = packGame;
                    else if (!batch && packGame is not null && installAfterPack.Contains(packGame.Id)) installAfterPackGame = packGame;
                }
                if (batch) _ = ReloadBatchAsync();
                Render();
                break;
        }
    }

    /// 「本次操作与处理建议」折叠区：给玩家看的原因与建议，同一句只出现一次（9120 时原先同一段中文重复三遍）。
    /// 作业层的失败事实（failureSummary：阶段、末行原文，常是英文）不放这里，只在「复制错误摘要」里带走
    private string JobDiagnostics(LibraryJobOutput job)
    {
        var lines = new List<string> { job.Report.Message, T("diagnostics.exit_code") + ": " + job.Output.ExitCode };
        void Add(string? line)
        {
            if (string.IsNullOrWhiteSpace(line)) return;
            line = line.Trim();
            if (!lines.Any(l => l == line || l.Contains(line))) lines.Add(line);   // 已有（或被更长的一句包含）就不重复
        }
        if (job.Report.Diagnostics.ValueKind == JsonValueKind.Array)
            foreach (var diagnostic in job.Report.Diagnostics.EnumerateArray())
            {
                if (diagnostic.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.String)
                { Add(T("errors." + code.GetString() + ".title")); Add(T("errors." + code.GetString() + ".detail")); }
                foreach (var key in new[] { "summary", "suggestion" })
                    if (diagnostic.TryGetProperty(key, out var message) && message.ValueKind == JsonValueKind.String) Add(message.GetString());
            }
        if (!string.IsNullOrWhiteSpace(job.Output.StandardError)) Add(job.Output.StandardError);
        return string.Join("\n", lines);
    }

    private void RenderProgress(StackPanel body)
    {
        var game = packGame!;
        var elapsed = packSeconds ?? (DateTime.UtcNow - packStarted).TotalSeconds;
        var estimate = packTrack.Estimate(Clock);

        // Top action bar: back button + in-progress capsule
        var topBar = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 12 };
        topBar.Children.Add(Action("export.back", () =>
        {
            if (packRunning) { sessionHidden = true; Navigate("library"); } else Navigate("build");
        }));
        if (packRunning && !sessionHidden)
        {
            var hint = Muted(T("export.hint"), 12); hint.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(hint, 1); topBar.Children.Add(hint);
        }
        body.Children.Add(topBar);

        // Two-column layout: left=game info + space, right=progress
        var twoCol = new Grid { ColumnDefinitions = new ColumnDefinitions("260,*"), ColumnSpacing = 36 };

        // ---- LEFT: game info panel + disk space ----
        var leftCol = new StackPanel { Spacing = 16 };
        leftCol.Children.Add(GameInfoPanel(game));
        leftCol.Children.Add(LiveSlot(() => packSpace is { } sp && packState != "succeeded" ? SpaceCard(sp) : null));   // 空间事件随时到：每秒刷新这一格；只在出包成功后收起（11-14 体验梳理：成功页还挂着出包前的「预计占用」）；在出、失败照显示——磁盘满失败时「要多少 / 剩多少」正是点「释放空间」要看的（开发甲核）
        twoCol.Children.Add(leftCol);

        // ---- RIGHT: heading + overall + steps / results ----
        var rightCol = new StackPanel { Spacing = 20 };
        Grid.SetColumn(rightCol, 1);

        // Status dot + label + platform
        var statusRow = new WrapPanel { Orientation = Orientation.Horizontal };
        var (statusText, statusColor) = packState switch
        {
            "running" => (T("progress.running"), "#FFC857"),
            "succeeded" => (T("progress.done"), "#52C87A"),
            "cancelled" => (T("progress.cancelled"), "#8C8A85"),
            _ => (T("progress.failed"), "#E05C5C")
        };
        var dot = new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(5),
            Background = Brush.Parse(statusColor), Margin = new Thickness(0, 4, 8, 0) };
        statusRow.Children.Add(dot);
        var statusLabel = Label(statusText, 14); statusLabel.FontWeight = FontWeight.Bold;
        statusLabel.Foreground = Brush.Parse(statusColor); statusRow.Children.Add(statusLabel);
        var platLabel = Muted(" · " + T("export.platform.ios"), 14);
        platLabel.Margin = new Thickness(2, 0, 0, 0); statusRow.Children.Add(platLabel);
        rightCol.Children.Add(statusRow);

        if (packRunning || packState == "")
        {
            // 每秒变的只有这两块：活格子，计时器只换它们（EnsureTicker）
            rightCol.Children.Add(LiveSlot(() => OverallSection(packTrack.Estimate(Clock), packSeconds ?? (DateTime.UtcNow - packStarted).TotalSeconds)));
            rightCol.Children.Add(LiveSlot(() => StepsSection(packTrack.Estimate(Clock))));
            // 取消和回到游戏库按钮在底栏（RenderBottomBar）
        }
        else
        {
            // 成功页：ResultSection 包含步骤折叠，不单独显示步骤列表
            rightCol.Children.Add(ResultSection(game, elapsed, estimate));
        }
        twoCol.Children.Add(rightCol);
        body.Children.Add(twoCol);

        if (packDiagnostics.Length > 0)
            body.Children.Add(new Expander { Header = T("library.job_diagnostics"), IsExpanded = packState is "failed" or "invalid",
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Content = new TextBox { Text = packDiagnostics, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 260 } });
    }

    // ---- game info panel (left column) ----

    private Control GameInfoPanel(LibraryGame game)
    {
        var panel = new StackPanel { Spacing = 12 };
        // Cover artwork
        var cover = GameCover(game, 220);
        if (cover is Border b) b.CornerRadius = new CornerRadius(10);
        panel.Children.Add(cover);
        // Name
        var name = Label(game.Name, 20); name.FontWeight = FontWeight.Bold;
        name.TextWrapping = TextWrapping.Wrap; name.MaxHeight = 72;
        panel.Children.Add(name);
        // Info rows
        void InfoRow(StackPanel p, string label, string value, bool mono = false)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(0, 0, 0, 0) };
            var lbl = Muted(label, 12); row.Children.Add(lbl);
            var val = Label(value, 13); val.FontWeight = FontWeight.SemiBold;
            if (mono) val.FontFamily = new FontFamily("Consolas,Courier New,monospace");
            val.HorizontalAlignment = HorizontalAlignment.Right; val.TextWrapping = TextWrapping.NoWrap;
            val.MaxWidth = 140; val.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetColumn(val, 1); row.Children.Add(val);
            // divider
            var border = new Border { BorderBrush = Brush.Parse("#28282C"), BorderThickness = new Thickness(0,0,0,1), Child = row, Padding = new Thickness(0, 6) };
            p.Children.Add(border);
        }
        var rows = new StackPanel { Spacing = 0 };
        InfoRow(rows, T("export.info.version"), game.Version.Length > 0 ? game.Version : "-");
        InfoRow(rows, T("export.info.base"), game.BaseVersion ?? T("export.info.none"));
        InfoRow(rows, T("export.info.update"), game.UpdateVersion ?? T("export.info.none"));
        var dlcText = game.DlcCount > 0
            ? T("export.info.dlcCount").Replace("{0}", game.DlcCount.ToString())
            : T("export.info.none");
        InfoRow(rows, T("export.info.dlc"), dlcText);
        var sizeText = game.TotalBytes > 0 ? FormatBytes(game.TotalBytes) : "-";
        InfoRow(rows, T("export.info.size"), sizeText);
        InfoRow(rows, T("export.info.program"), game.Id, mono: true);
        panel.Children.Add(rows);
        return Card(panel, 14);
    }

    // ---- disk space card ----

    private Control SpaceCard(PackSpace sp)
    {
        var card = new StackPanel { Spacing = 8 };
        card.Children.Add(Label(T("export.space.title"), 13));
        if (sp.NeedBytes is { } need && sp.FreeBytes is { } free && free > 0)
        {
            var fill = Math.Min(1.0, (double)need / free);
            var barOuter = new Border { Height = 6, CornerRadius = new CornerRadius(3),
                Background = Brush.Parse("#2E2E32") };
            var barInner = new Border { Height = 6, CornerRadius = new CornerRadius(3),
                Background = need > free ? Brush.Parse("#E05C5C") : Brush.Parse("#FFF0D6"),
                HorizontalAlignment = HorizontalAlignment.Left };
            // width set via a measure pass substitute: use a Grid with star/auto
            var barGrid = new Grid { ColumnDefinitions = new ColumnDefinitions($"{fill}*,{1-fill}*") };
            barGrid.Children.Add(new Border { Background = need > free ? Brush.Parse("#E05C5C") : Brush.Parse("#FFF0D6"),
                CornerRadius = new CornerRadius(3) });
            barGrid.Children.Add(new Border());   // filler
            Grid.SetColumn(barGrid.Children[1], 1);
            barOuter.Child = barGrid;
            card.Children.Add(barOuter);
        }
        var figRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*") };
        var needBlock = new StackPanel { Spacing = 2 };
        needBlock.Children.Add(Muted(T("export.space.need"), 11));
        needBlock.Children.Add(Label(sp.NeedBytes is { } nb ? FormatBytes(nb) : "—", 14));
        figRow.Children.Add(needBlock);
        var freeBlock = new StackPanel { Spacing = 2 };
        freeBlock.Children.Add(Muted(T("export.space.free"), 11));
        freeBlock.Children.Add(Label(sp.FreeBytes is { } fb ? FormatBytes(fb) : "—", 14));
        Grid.SetColumn(freeBlock, 1); figRow.Children.Add(freeBlock);
        card.Children.Add(figRow);
        if (sp.Basis is "measured" or "rule")
            card.Children.Add(Muted(T("export.space.basis." + sp.Basis), 11));
        return Card(card, 14);
    }

    // ---- overall progress (big %, segmented bar, three times) ----

    private Control OverallSection(MilestoneEstimate estimate, double elapsed)
    {
        var plan = packTrack.Plan;
        var fraction = OverallFraction(estimate, plan, packTrack.Overall);
        var section = new StackPanel { Spacing = 12 };

        // Big %
        var pctRow = new WrapPanel { Orientation = Orientation.Horizontal };
        var pct = Label($"{(int)(fraction * 100)}%", 52); pct.FontWeight = FontWeight.Black;
        pct.Margin = new Thickness(0, 0, 10, 0);
        pctRow.Children.Add(pct);
        var overallLbl = Muted(T("export.overall"), 14);
        overallLbl.VerticalAlignment = VerticalAlignment.Bottom; overallLbl.Margin = new Thickness(0, 0, 0, 8);
        pctRow.Children.Add(overallLbl);
        section.Children.Add(pctRow);

        // Segmented bar
        if (plan.Count > 0) section.Children.Add(SegmentedBar(estimate, plan));

        // Three time figures
        var times = new WrapPanel { Orientation = Orientation.Horizontal };
        void TimeFigure(string label, string value, bool accent = false)
        {
            var cell = new StackPanel { Spacing = 3, Margin = new Thickness(0, 0, 36, 0) };
            cell.Children.Add(Muted(label, 12));
            var v = Label(value, 26); v.FontWeight = FontWeight.Bold;
            if (accent) v.Foreground = Accent;
            cell.Children.Add(v);
            times.Children.Add(cell);
        }
        TimeFigure(T("progress.elapsed"), Duration(elapsed));
        if (packRunning)
        {
            if (estimate.Remaining is { } rem)
            {
                TimeFigure(T("progress.remaining"), Duration(rem), accent: true);
                TimeFigure(T("progress.finish_at"), DateTime.Now.AddSeconds(rem).ToString("HH:mm"));
            }
            else if (estimate.StepRemainingByRate is { } stepRem)
                TimeFigure(T("progress.remaining"), Duration(stepRem), accent: true);
        }
        section.Children.Add(times);

        // History/rate note
        if (packRunning && plan.Count > 0)
        {
            if (estimate.Remaining is not null && estimate.HistorySamples > 0)
                section.Children.Add(Muted(string.Format(T("progress.basis"), estimate.HistorySamples) +
                    (estimate.StepRemainingByRate is not null ? " · " + T("progress.by_rate") : ""), 12));
            else if (estimate.Remaining is null && estimate.StepRemainingByRate is null)
                section.Children.Add(Muted(T("progress.no_history"), 12));
        }
        return section;
    }

    /// <summary>作业层给了整单进度就用它（只增不减）；没有时照旧按各步估计</summary>
    private static double OverallFraction(MilestoneEstimate estimate, IReadOnlyList<Milestone> plan, double? overall)
    {
        if (overall is { } o) return o;
        if (plan.Count == 0) return 0;
        var weights = Weights(plan); var total = weights.Sum();
        var thisPlatform = total > 0 ? plan.Select((m, k) => estimate.Fill(k) * weights[k]).Sum() / total : 0;
        return Math.Min(1, thisPlatform);
    }

    private static double[] Weights(IReadOnlyList<Milestone> plan)
    {
        var measured = plan.Select(m => m.Measured ?? -1).ToArray();
        return measured.Contains(-1) || measured.Sum() <= 0
            ? plan.Select(_ => 1.0).ToArray()
            : measured.Select(v => Math.Max(v, 1)).ToArray();
    }

    // ---- segmented bar with sweep — 铺满父容器宽度 ----

    /// <summary>第 k 段的填充：有整单进度就按同一套权重从它切出这一段（各段与大百分比一致、只增不减），否则照旧按估计</summary>
    private double SegmentFill(MilestoneEstimate estimate, IReadOnlyList<Milestone> plan, int k)
    {
        if (packTrack.Overall is not { } o) return estimate.Fill(k);
        var w = Weights(plan); var total = w.Sum(); var before = w.Take(k).Sum();
        return k < w.Length && w[k] > 0 && total > 0 ? Math.Clamp((o * total - before) / w[k], 0, 1) : 0;
    }

    private Control SegmentedBar(MilestoneEstimate estimate, IReadOnlyList<Milestone> plan)
    {
        var weights = Weights(plan); var total = Math.Max(weights.Sum(), 1);
        // 用 Grid 按权重分配列宽，确保铺满右栏
        var colDefs = string.Join(",", weights.Select(w => $"{w}*"));
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions(colDefs), Height = 10, ColumnSpacing = 3 };
        for (var k = 0; k < plan.Count; k++)
        {
            var fill = SegmentFill(estimate, plan, k);
            var active = k == estimate.Index && packRunning;
            var seg = new Grid();
            seg.ColumnDefinitions = new ColumnDefinitions($"{fill}*,{Math.Max(0, 1 - fill)}*");
            seg.Children.Add(new Border { Background = Brush.Parse("#222226"), CornerRadius = new CornerRadius(2), [Grid.ColumnSpanProperty] = 2 });
            if (fill > 0)
                seg.Children.Add(new Border { Background = active ? Accent : Brush.Parse("#B8A07A"), CornerRadius = new CornerRadius(2) });
            Grid.SetColumn(seg, k); bar.Children.Add(seg);
        }
        return bar;
    }

    // ---- steps list ----

    private Control StepsSection(MilestoneEstimate estimate)
    {
        var steps = new StackPanel { Spacing = 12 };
        if (packTrack.Plan.Count == 0)
        {
            steps.Children.Add(Muted(T(packRunning ? "progress.preparing" : "progress.no_steps")));
            return steps;
        }
        for (var k = 0; k < packTrack.Plan.Count; k++)
        {
            var m = packTrack.Plan[k];
            var isRunning = k == estimate.Index && packRunning;
            var isDone = k < (estimate.Index ?? (packRunning ? 0 : packTrack.Plan.Count));
            var skipped = isDone && !packTrack.Started.ContainsKey(m.Id);

            // 图标：运行中=实心圆点（呼吸效果通过色差模拟），完成=绿对勾，排队=空心圆
            var markText = isRunning ? "●" : isDone ? (skipped ? "↺" : "✓") : "○";
            var markColor = isRunning ? "#FFC857" : isDone ? (skipped ? "#8C8A85" : "#52C87A") : "#4A4A50";

            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("28,*,Auto"), ColumnSpacing = 10 };
            var markLbl = new TextBlock { Text = markText, FontSize = isRunning ? 18 : 15,
                Foreground = Brush.Parse(markColor), VerticalAlignment = VerticalAlignment.Top };
            row.Children.Add(markLbl);

            var content = new StackPanel { Spacing = 4 };
            var nameLbl = Label((k + 1) + ". " + B(m.Label), isRunning ? 16 : 14);
            if (isRunning) nameLbl.FontWeight = FontWeight.Bold;
            if (!isDone && !isRunning) nameLbl.Foreground = Brush.Parse("#8C8A85");
            content.Children.Add(nameLbl);
            if (m.Purpose.Length > 0)
            {
                var purpose = Muted(m.Purpose, 12); content.Children.Add(purpose);
            }
            if (isRunning)
            {
                var fill = estimate.Fill(k);
                content.Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Value = fill, Height = 6,
                    IsIndeterminate = packTrack.Fraction is null && m.Measured is null,
                    Foreground = Accent, Margin = new Thickness(0, 4, 0, 0) });
                var details = new List<string>();
                if (packTrack.Fraction is { } f) details.Add($"{(int)(f * 100)}%");
                if (estimate.StepRemainingByRate is { } sr)
                    details.Add(T("export.step.left").Replace("{0}", Duration(sr)));
                if (packTrack.Message.Length > 0) details.Add(packTrack.Message);
                // 上次前进 N 秒前（#1770）：计数停着、这个数一直涨 = 真卡住；隔几秒就归零 = 后台在走
                if (packTrack.SinceAdvance(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0) is { } since)
                    details.Add(T("export.step.advanced").Replace("{0}", Spoken(Math.Max(1, since))));
                // 这一行每秒都可能变（百分比 / 剩余 / 作业消息有无、长短）：恒占一行、不换行，下面的步骤不跟着上下跳
                var detail = Muted(details.Count > 0 ? string.Join(" · ", details) : "\u00A0", 12);
                detail.TextWrapping = TextWrapping.NoWrap; detail.TextTrimming = TextTrimming.CharacterEllipsis;
                content.Children.Add(detail);
            }
            Grid.SetColumn(content, 1); row.Children.Add(content);

            // 单步用时：从该步骤自己的开始时间算，不用全局时钟基准
            string rightText;
            if (isRunning)
            {
                // StepElapsed 是从该步开始的秒数
                rightText = T("progress.step") + " " + Duration(estimate.StepElapsed);
            }
            else if (isDone)
            {
                rightText = packTrack.Duration(m.Id) is { } d ? Duration(d) : m.Reuse ? T("progress.reuse") : T("progress.skipped");
            }
            else
            {
                rightText = m.Measured is { } ex && ex > 0 ? T("export.step.expected").Replace("{0}", Duration(ex)) : "";
            }
            var side = Muted(rightText, 12); side.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(side, 2); row.Children.Add(side);
            steps.Children.Add(row);
        }
        return steps;
    }

    // ---- result section (success / failure / cancelled) ----

    // ---- result section (success / failure / cancelled) ----

    /// <summary>出包完成页「S 级加强已就位」（同 Mac BoostBanner：金色 S + 标题 + 这次配好的条数 + 去哪开）；条数全是 0 = null（不出）</summary>
    private Control? BoostBanner(JsonElement? boost)
    {
        if (boost is not { ValueKind: JsonValueKind.Object } b) return null;
        int N(string k) => b.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
        var parts = new[] { ("cheats", "export.boost.cheats"), ("fps", "export.boost.fps"), ("widescreen", "export.boost.widescreen"), ("gfx", "export.boost.gfx") }
            .Where(p => N(p.Item1) > 0).Select(p => T(p.Item2).Replace("{0}", N(p.Item1).ToString())).ToList();
        if (parts.Count == 0) return null;
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 22 };
        row.Children.Add(new Image { Source = SGoldImage(), Width = 84, Height = 84, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center });
        var text = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = T("export.boost.title"), FontSize = 24, FontWeight = FontWeight.Black, Foreground = Diag((SGoldHi, 0), (SGold, 0.5), (SRose, 1)) });
        text.Children.Add(new TextBlock { Text = string.Join(" · ", parts), FontSize = 15, FontWeight = FontWeight.SemiBold, Foreground = Ink, TextWrapping = TextWrapping.Wrap });
        text.Children.Add(WrappedMuted(T("export.boost.hint.win"), 13));   // 金手指在哪开按平台各写各的（Mac 版 export.boost.hint 写 Mac 启动设置）
        Grid.SetColumn(text, 1); row.Children.Add(text);
        var card = new Border { Child = row, Padding = new Thickness(22, 18), CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(A(SGold, 0.08)), BorderBrush = new SolidColorBrush(A(SGold, 0.35)) };
        AutomationId(card, "result.boost");
        return card;
    }

    /// 补丁打入结果（11-14 维护者：哪些打上了、哪些没打上和为什么；不影响成败）：每份 = (名字, {applied, failed, error})，名字空 = 不写标题行。
    ///   同 Mac SGradeResultView（launchers/macos/frontend/Sources/NX2Apple/SGradeResult.swift）；都没有内容 = null（不出这块）
    internal Control? SGradeResultPanel(IEnumerable<(string Name, JsonElement Res)> results, bool cheats = true)
    {
        string Cat(string c) => T("export.sgrade.cat." + (c is "widescreen" or "fps" or "gfx" or "cheat" or "mod" ? c : "gfx"));
        IEnumerable<JsonElement> Arr(JsonElement r, string k) => r.TryGetProperty(k, out var a) && a.ValueKind == JsonValueKind.Array ? a.EnumerateArray() : [];
        string S(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        int Cheats(JsonElement r) => cheats && r.TryGetProperty("cheats", out var n) && n.ValueKind == JsonValueKind.Number ? n.GetInt32() : 0;
        var list = results.Where(r => Arr(r.Res, "applied").Any() || Arr(r.Res, "failed").Any() || S(r.Res, "error").Length > 0 || Cheats(r.Res) > 0).ToList();
        if (list.Count == 0) return null;
        var box = new StackPanel { Spacing = 8 };
        AutomationId(box, "result.sgrade");
        var title = Label(T("sgrade.result.title"), 15); title.FontWeight = FontWeight.SemiBold; box.Children.Add(title);
        foreach (var (name, res) in list)
        {
            if (list.Count > 1 && name.Length > 0) { var h = Label(name, 13.5); h.FontWeight = FontWeight.SemiBold; box.Children.Add(h); }
            if (S(res, "error").Length > 0) box.Children.Add(WrappedMuted("✕ " + T("sgrade.result.error"), 13));
            var applied = Arr(res, "applied").Select(a => Cat(S(a, "cat")) + " · " + S(a, "name")).ToList();
            if (applied.Count > 0) box.Children.Add(WrappedMuted("✓ " + T("sgrade.result.applied") + string.Join(language == "en" ? ", " : "、", applied), 13));
            if (Cheats(res) > 0) box.Children.Add(WrappedMuted("✓ " + T("export.sgrade.hit.cheat").Replace("{0}", Cheats(res).ToString()), 13));
            foreach (var f in Arr(res, "failed"))
                box.Children.Add(WrappedMuted("⚠ " + T("sgrade.result.failed").Replace("{0}", S(f, "name")).Replace("{1}", Cat(S(f, "cat"))).Replace("{2}", T("sgrade." + S(f, "why"))), 13));
        }
        box.Children.Add(WrappedMuted(T("sgrade.result.note"), 12));
        return new Border { Child = box, Padding = new Thickness(16), CornerRadius = new CornerRadius(14), Background = new SolidColorBrush(Color.FromArgb(10, 255, 255, 255)) };
    }

    private Control ResultSection(LibraryGame game, double elapsed, MilestoneEstimate? estimate = null)
    {
        var result = new StackPanel { Spacing = 20, VerticalAlignment = VerticalAlignment.Center };
        if (packState == "succeeded")
        {
            // 绿对勾（84 大小）
            var seal = new Border { Width = 84, Height = 84, CornerRadius = new CornerRadius(42), HorizontalAlignment = HorizontalAlignment.Left,
                Background = Brush.Parse("#40D678"),
                Child = new TextBlock { Text = "✓", FontSize = 44, FontWeight = FontWeight.Black,
                    Foreground = Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center } };
            result.Children.Add(seal);
            result.Children.Add(Label(T("export.done.title"), 40));
            result.Children.Add(Muted(T("export.done.ios"), 16));

            // 三个大数字
            var stats = new WrapPanel { Orientation = Orientation.Horizontal };
            void BigStat(string label, string value)
            {
                var cell = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 44, 0) };
                cell.Children.Add(Muted(label, 13));
                var v = Label(value, 32); v.FontWeight = FontWeight.Black;
                cell.Children.Add(v);
                stats.Children.Add(cell);
            }
            BigStat(T("export.done.time"), Duration(elapsed));
            if (packIpaBytes is { } ib) BigStat(T("export.done.ipa"), FormatBytes(ib));
            if (packPackBytes is { } pb) BigStat(T("export.done.pack"), FormatBytes(pb));
            result.Children.Add(stats);
            if (packNotes.Count > 0)   // 降级继续的玩家提示（作业层原句）：出成了照常给按钮，这里说清哪里用了兼容做法（同 Mac ExportSessionView）
            {
                var notes = new StackPanel { Spacing = 6 };
                AutomationId(notes, "progress.notes");
                var head = new TextBlock { Text = "⚠ " + T("export.done.notes"), FontSize = 14, FontWeight = FontWeight.Bold, Foreground = Brush.Parse("#FFC857") };
                notes.Children.Add(head);
                foreach (var note in packNotes) notes.Children.Add(WrappedMuted(note, 13));
                result.Children.Add(notes);
            }
            if (BoostBanner(packBoost) is { } bb) result.Children.Add(bb);   // 「S 级加强已就位」（同 Mac ExportSessionView BoostBanner）
            if (SGradeResultPanel(packBoost is { } pbst ? [("", pbst)] : [], cheats: false) is { } sgr) result.Children.Add(sgr);   // 金手指条数横幅里已写   // 补丁打入结果：打上 / 没打上（同 Mac SGradeResultView，11-14）

            // 两个大按钮
            var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
            // 这次出包是为了导出自签包：按钮与说明照导出写（不写「一键装到 iPhone」），点了直接导出（D-9ZF9）
            var selfSign = packGame is not null && selfSignAfterPack.Contains(packGame.Id);
            var install = selfSign
                ? Primary(T("library.hero.selfSign"), () => { if (packGame is { } g) ExportSelfSign(g); })
                : Primary(T(PadKey("export.done.install")), () => { readinessFor = null; if (!installBusy) installExport = false; Navigate("install"); });
            AutomationId(install, "progress.install");
            install.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(install);
            // IPA 是装机时组装、整个游戏库共用一份（默认位置根 S2Arm.ipa）：出包这步没有 IPA，只给「打开游戏文件夹」（按索引找这款实际所在的位置）
            if (!string.IsNullOrEmpty(packIpa))
            {
                var reveal = Action("progress.reveal_ipa", () => Reveal(packIpa));
                reveal.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(reveal);
            }
            var folder = Action("progress.open_game_folder", () => OpenGameFolder(game));
            AutomationId(folder, "progress.open_game_folder");
            folder.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(folder);
            result.Children.Add(buttons);
            if (revealProblem.Length > 0) result.Children.Add(Muted(revealProblem, 13));
            result.Children.Add(Muted(T(selfSign ? "export.done.exportNote" : "export.win.done.installNote"), 12));

            // 详细记录（折叠步骤列表）
            if (estimate is not null)
            {
                var detail = new Expander
                {
                    Header = T("export.detail.title"),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Content = StepsSection(estimate)
                };
                result.Children.Add(detail);
            }
        }
        else if (packState is "failed" or "invalid")
        {
            if (packSummary.Length > 0) result.Children.Add(Label(packSummary, 16));
            var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
            var retry = Action("progress.again", () => Navigate("build"));
            retry.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(retry);
            if (packFailureCode == "disk_full")   // 磁盘预算偏保守：和 Mac 一样允许玩家自己决定继续
            {
                var space = Action("space.title", OpenStorage, !BusyFor(game));   // 同 Mac 出包失败页「释放空间」
                AutomationId(space, "export.fix.space");
                space.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(space);
                var proceed = Action("export.fix.continue", () => StartPack(game, spaceOverride: true), !BusyFor(game));
                proceed.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(proceed);
            }
            if (packState == "failed")
            {
                var copy = CopyReportButton(game.Id, ["ipa"], () => ErrorSummary(game));
                buttons.Children.Add(copy);
            }
            result.Children.Add(buttons);
            if (packState == "failed") result.Children.Add(ReportHintText());
            var feedback = new WrapPanel { Orientation = Orientation.Horizontal };
            feedback.Children.Add(Muted(T("export.fail.feedback"), 12));
            var gh = new Button { Content = T("export.fail.github"), Background = Transparent,
                Foreground = Accent, Padding = new Thickness(6, 0), FontSize = 12 };
            gh.Click += async (_, _) => await OpenOfficialAsync(new Uri("https://github.com/jhaizhou-ops/S2Arm/issues"));
            feedback.Children.Add(gh);
            var xBtn = new Button { Content = T("export.fail.x"), Background = Transparent,
                Foreground = Accent, Padding = new Thickness(6, 0), FontSize = 12 };
            xBtn.Click += async (_, _) => await OpenOfficialAsync(new Uri("https://x.com/happyjoejiang"));
            feedback.Children.Add(xBtn);
            result.Children.Add(feedback);
        }
        else if (packState == "cancelled")
        {
            result.Children.Add(Label(T("progress.cancelled"), 18));
            result.Children.Add(Action("progress.again", () => Navigate("build")));
        }
        return result;
    }


    // ---- error summary for clipboard (only when the job left no record) ----

    private string ErrorSummary(LibraryGame game)
    {
        var lines = new List<string>
        {
            T("failcopy.title"), "",
            T("failcopy.game").Replace("{0}", game.Name),
            T("failcopy.version").Replace("{0}", game.Version),
            T("failcopy.titleId").Replace("{0}", game.Id),
            T("failcopy.size").Replace("{0}", FormatBytes(game.TotalBytes)),
            "",
            T("failcopy.parts").Replace("{0}", game.BaseVersion ?? "-").Replace("{1}", game.UpdateVersion ?? "-").Replace("{2}", game.DlcCount.ToString()),
            "",
            T("failcopy.error"), B(packSummary),
            "", packDiagnostics
        };
        return string.Join("\n", lines);
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes >= 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024 * 1024):0.##} GB";
        if (bytes >= 1024L * 1024) return $"{bytes / (1024.0 * 1024):0.##} MB";
        if (bytes >= 1024L) return $"{bytes / 1024.0:0.##} KB";
        return bytes + " B";
    }

    private static readonly IBrush Transparent = Brushes.Transparent;

    private void Reveal(string path)
    {
        // 路径不在就说清楚，不把空参数交给资源管理器（原先 /select, 后面是空串，打开一个什么都没选中的空窗口）
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) { revealProblem = T("reveal.ipa_missing"); Render(); return; }
        revealProblem = "";
        try
        {
            // Explorer selects the file; the path goes in as one argument, never through a shell.
            if (OperatingSystem.IsWindows()) Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select," + path } })?.Dispose();
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        { packDiagnostics += "\n" + T("process.start_failed") + "\n" + error.Message; Render(); }
    }

    // ---- install page ----

    private void RenderInstall(StackPanel body)
    {
        var game = SelectedGame ?? packGame;
        body.Children.Add(Action("export.back", () => Navigate("library")));   // 回游戏库首页（原先回「出包到」页）；装机在后台照跑，顶栏胶囊能回来（#308）
        if (game is null || connectedFolder is null || libraryId is null) { body.Children.Add(Label(T("export.no_game"), 18)); return; }
        if (readinessFor != game.Id && !installChecking) { readinessFor = game.Id; readiness = null; installCheckFailed = false; _ = CheckInstallAsync(); }
        body.Children.Add(GameHeader(game));
        if (installExport && installState != "" && installGameId == game.Id)
        {
            // 导出自签包的进度 / 完成（11-15 维护者：不出现 Apple ID、数据线、检查清单、装回、删除）：标题 + 结局卡（导出文件夹可点、怎么自签安装）
            body.Children.Add(Label(T("library.hero.selfSign"), 22));
            if (!installBusy) installSeen = true;
            body.Children.Add(LiveSlot(() => InstallStateCard(game, showsOperation: false)));
            return;
        }
        body.Children.Add(Label(T(PadKey("install.title")), 22));
        body.Children.Add(Muted(T("install.description"), 14));
        body.Children.Add(Muted(T("install.container_note"), 14));
        body.Children.Add(Muted(T("install.legacy_note"), 14));
        EnsureInstallMode();
        body.Children.Add(Card(LayoutCards(game.Id), 14));   // 这款推成通用 S2Arm 里的一款还是独立 App（0.6.3）：缺省跟随设置，单款可改；卡片下方一行提示（0.6.4）
        if (File.Exists(BundledImpactor)) body.Children.Add(Muted(T("install.third_party")));   // 随包第三方工具要写明（11-07 维护者 随包下发）

        var list = new StackPanel { Spacing = 12 };
        if (readiness is null) list.Children.Add(Muted(T(installChecking ? "install.checking" : "install.no_report")));
        foreach (var item in readiness?.Items ?? [])
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("28,*,Auto"), ColumnSpacing = 10 };
            row.Children.Add(Label(item.Ok ? "✓" : item.Waiting ? "…" : "○", 16));
            var text = new StackPanel { Spacing = 4 };
            // Titles / details are backend text (Chinese); the English interface shows them as they come.
            text.Children.Add(Label(item.Title, 15));
            if (item.Detail.Length > 0) text.Children.Add(Muted(item.Detail));
            Grid.SetColumn(text, 1); row.Children.Add(text);
            if (!item.Ok && item.OfficialUrl is { } url)
            {
                var official = new Button { Content = T("action.open_official"), Background = Accent, Foreground = Canvas,
                    Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
                official.Click += async (_, _) => await OpenOfficialAsync(url);
                Grid.SetColumn(official, 2); row.Children.Add(official);
            }
            else if (!item.Ok && item.Action is { } act && InstallActionLabel(act) is { } label)
            {
                // 按钮落点只看项上的 action（11-19 契约）：openImpactor 直接打开随包 Impactor（原先写「去设置」跳设置页，和说明「点『打开 Impactor』」对不上），
                //   openExport 去这款的出包页（原先 package 没好没有按钮），devCertSettings 去设置页；控制口 /install-action 走同一个 RunInstallAction
                var open = new Button { Content = T(label), Background = Accent, Foreground = Canvas,
                    Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
                AutomationId(open, "install.action." + act);
                open.Click += (_, _) => RunInstallAction(act, game);
                Grid.SetColumn(open, 2); row.Children.Add(open);
            }
            list.Children.Add(row);
        }
        if (readiness is { Device.Length: > 0 }) list.Children.Add(Muted(T("install.device") + " · " + readiness.Device));
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
        var recheck = Action("action.recheck", () => _ = CheckInstallAsync(), !installChecking && !installBusy);
        recheck.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(recheck);
        var queued = PhoneQueued(game.Id);   // 别的作业在跑也能点（排队）；只有这款已排上、或正在推这一款时置灰
        var pushing = PhonePushing(game.Id);   // D-YXDW：原先这款正在推时按钮照样能点，点一下就给同一款再排一单（推完又推一遍）
        var start = Primary(T(pushing ? "install.start.pushing" : queued ? "install.start.queued" : "install.start"), () => _ = InstallAsync(game), !queued && !pushing);   // 不按清单置灰（同 Mac InstallView）：真做不下去的作业层开头判、回真实原因
        AutomationId(start, "install.start");
        buttons.Children.Add(start);
        if (queued)   // 已排队：手机上前一个作业完成、或这款出完包后自动接着装（同 Mac 装机窗）
        {
            var note = Muted(T("install.queued"), 13); AutomationId(note, "install.queued");
            list.Children.Add(note);
        }
        var remove = new Button { Content = T("install.remove_game"), IsEnabled = !queued,
            Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8),
            Background = Brush.Parse("#29292D"), Foreground = Ink, Margin = new Thickness(12, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center };
        AutomationId(remove, "install.remove_game");
        remove.Click += (_, _) => _ = ConfirmRemoveAsync(game);
        buttons.Children.Add(remove);
        BusyHint(start); BusyHint(remove);   // 出包 / 装机在跑时置灰：悬停说在等谁、为什么（同 Mac BusyHint.swift）
        if (game.IphoneRestorable)
        {
            // 手机上的 S2Arm 换了新版运行层（只换宿主）后不好用：装回上一版（installRestore，同 Mac 装机页）
            var restore = new Button { Content = T("install.restore"), IsEnabled = !queued,
                Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8),
                Background = Brush.Parse("#29292D"), Foreground = Ink, Margin = new Thickness(12, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center };
            AutomationId(restore, "install.restore");
            restore.Click += (_, _) => _ = ConfirmRestoreAsync(game);
            BusyHint(restore);
            buttons.Children.Add(restore);
        }
        if (readiness is { IpaPath.Length: > 0 } located)   // 装机时组装的那份（默认位置根 S2Arm.ipa），还没装过就没有
        {
            var reveal = Action("progress.reveal_ipa", () => Reveal(located.IpaPath));
            reveal.Margin = new Thickness(12, 0, 0, 0);
            AutomationId(reveal, "install.reveal_ipa");
            buttons.Children.Add(reveal);
        }
        var openFolder = Action("progress.open_game_folder", () => OpenGameFolder(game));
        openFolder.Margin = new Thickness(12, 0, 0, 0);
        AutomationId(openFolder, "install.open_game_folder");
        buttons.Children.Add(openFolder);
        list.Children.Add(buttons);
        if (revealProblem.Length > 0) list.Children.Add(Muted(revealProblem, 13));
        body.Children.Add(Card(list));

        if (installState != "" && installGameId is not null && installGameId != game.Id)
        {
            // 正在装 / 刚装完的是另一款：这里不画它的进度（原先会画到当前这款上），给一个回去的入口
            var other = new StackPanel { Spacing = 8 };
            other.Children.Add(Muted(T(installBusy ? "install.pill.running" : installState == "succeeded" ? (installTrack.ExportFolder.Length > 0 ? "install.pill.exported" : "install.pill.done") : installState == "needsPlayer" ? "install.pill.needs_player" : "install.pill.failed").Replace("{0}", installGameName ?? installGameId).Replace("{1}", InstallTargetLabel)));
            other.Children.Add(Action("install.pill.open", OpenPhoneJob));
            body.Children.Add(Card(other));
        }
        else if (installState != "")
        {
            if (!installBusy) installSeen = true;   // 回到这款的安装页看过结果，顶栏胶囊收起
            body.Children.Add(LiveSlot(() => InstallStateCard(game)));   // 装机进度事件只刷新这一格（IngestPhoneEvent）
        }
        // 作业诊断并进结局卡的「详细过程」（PhoneJobCard），不再另挂一个展开框
    }

    /// 安装页的状态卡：标题、进度条、已推 / 剩余、作业说明、复制错误摘要
    private Control InstallStateCard(LibraryGame game, bool showsOperation = true)
    {
        // 装机 / 续签 / 删除 / 装回：同一张结局卡（PhoneJobCard.cs，同 Mac PhoneJobPanel）；Apple ID 登录过期另给「打开 Impactor 重新登录」
        var notes = new List<string>();
        // 独立 App：主屏上点这款的名字打开（不是「打开 S2Arm」那句）
        if (installState == "succeeded" && installTrack.Kind == "install" && installTrack.Standalone && !installExport) notes.Add(T("app.done.open").Replace("{0}", installTrack.AppName));
        else if (installState == "succeeded" && installTrack.Kind == "install" && installOpenToFinish) notes.Add(T("install.done.open"));
        // 第一次打开前信任开发者（同 Mac InstallView doneNotes）：读到证书名就写要点哪一项，读不到退回不带名字的说法；导出模式不连手机，不写
        if (installState == "succeeded" && installTrack.Kind == "install" && !installExport)
            notes.Add(installTrustName.Length > 0 ? T("install.done.trustNamed").Replace("{0}", installTrustName) : T("install.done.trust"));
        var state = new StackPanel { Spacing = 16 };
        // 单款装机（不是导出）没走成：「重试」原样重发这一单（同样的确认参数、同一台）；独立 App 成功页的「完成」收起结局卡
        var retry = installState is "failed" or "interrupted" or "invalid" && !installExport && installTrack.Kind == "install" && lastInstall is { } again && installGameId == game.Id
            ? () => { _ = again(); } : (Action?)null;
        state.Children.Add(PhoneJobCard(installTrack, installState, installMessage, installDiagnostics, game.Id, notes, showsOperation: showsOperation, retry: retry,
            finish: () => { installState = ""; installSeen = true; revealProblem = ""; Navigate("library"); },
            switchExport: installState is "failed" or "interrupted" && !installExport && installTrack.Kind == "install" ? () => { IosAfterPack = "export"; ExportSelfSign(game); } : null));
        if (installState is "failed" && installChoice is { } choice)   // 装着不止一个 S2Arm、还没选：就在这页选，选好自动重推这一款
        {
            var phone = new PhoneOverview.Phone(choice.Device, "", true, false, null, false, null, null, null, [], NeedsChoice: true, Candidates: choice.Candidates);
            state.Children.Add(ConsoleChooser(phone, false, bid => _ = ChooseAppAsync(choice.Device, bid)));
        }
        if (installState is "failed" && installCode is "apple_session_expired" or "apple_not_signed_in")
        {
            // Apple ID 登录过期（Apple 1100）/ 还没登录：打开 Impactor 让玩家自己重新登录（密码不经手），登录好再点一次「推到 iPhone」
            var relogin = Action("install.relogin", OpenBundledImpactor, File.Exists(BundledImpactor) && !installBusy);
            AutomationId(relogin, "install.relogin");
            state.Children.Add(relogin);
        }
        return Card(state);
    }

    private async Task CheckInstallAsync()
    {
        var game = SelectedGame ?? packGame;
        if (installChecking || installBusy || game is null || connectedFolder is null || libraryId is null) return;
        installChecking = true; lastCheck = DateTime.UtcNow;
        // 每 5 秒重查一次清单：结果和上次一样就不重画（原先每次都整页重画，玩家滚到下面会被拉一下）
        var before = (readiness is null, readinessRaw, installCheckFailed, installDiagnostics);   // 换了一款（readiness 清空）必重画
        try
        {
            // 装过的款（续签 / 重装）清单只看当初那台；没装过的看唯一连着的那台（清单把它的设备号报回来，装机就带它）
            var job = await PackJobClient.RunAsync(PackRequest("installCheck", game.Id, DeviceExtra(game.IphoneInstallDevice)), null, CancellationToken.None);
            if (readinessFor == game.Id)
            {
                if (job.Report.Succeeded) { readiness = InstallReadiness.Parse(job.Report.Result); readinessRaw = job.Report.Result.GetRawText(); installCheckFailed = false; }
                else { installDiagnostics = JobDiagnostics(job); installCheckFailed = true; }
            }
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { installDiagnostics = error.Message; installCheckFailed = true; }
        finally
        {
            installChecking = false; lastCheck = DateTime.UtcNow;
            if (page == "install" && before != (readiness is null, readinessRaw, installCheckFailed, installDiagnostics)) Render();
        }
    }

    /// <summary>
    /// 作业层认得出、玩家同意就能继续的停装码 → 续跑时带的参数（同 Mac S2ArmLauncherModel.confirmCodes）。
    /// 维护者 11-11：「玩家都主动点装机了……能认出的问题让用户确认，用户确认可以继续装，认不出的直接装」。
    /// container_would_drop：手机上别的电脑装的游戏这次带不上；save_backup_failed：覆盖前没能备份手机上的存档；container_stale：旧资源包要按新版重出。
    /// </summary>
    /// 11-19 结构 9：表只在共享体验表 errors 的 accept 一处（Mac 读同一处），不在这里另写——原先两端各写一份，Mac 缺 cert_revoke_confirm。
    private IReadOnlyDictionary<string, string> ConfirmCodes => text.ConfirmFlags;

    /// <summary>可确认的停装码要问的那句标题：文案表有 errors.&lt;码&gt;.title 就用它，没有用通用的 install.drop_title</summary>
    private string ConfirmTitle(string? code) => code is { Length: > 0 } && text.Has("errors." + code + ".title") ? T("errors." + code + ".title") : T("install.drop_title");

    /// <summary>控制口请求里带的确认参数（acceptDropped / acceptNoBackup / acceptStale）</summary>
    private HashSet<string> AcceptFlags(ControlRequest r) => ConfirmCodes.Values.Where(r.Flag).ToHashSet();

    /// <summary>accept：玩家已同意的确认参数（ConfirmCodes 的值，逐次累积）。ask = false（控制口）原样失败、不弹确认，由调用方带参数再发。</summary>
    /// <param name="export">游戏库「导出自签包」：不连手机、不签名，出到文件夹（作业层 install 请求带 mode = export，不带设备）</param>
    /// <param name="device">装到哪台（总控台「续签」带那台的设备号）；不给 = 清单报回来的那台 / 装机记录里的那台（InstallDevice）</param>
    private async Task InstallAsync(LibraryGame game, IReadOnlySet<string>? accept = null, bool ask = true, bool export = false, string? device = null)
    {
        if (PhonePushing(game.Id) || PhoneQueued(game.Id)) return;   // 这一款已在推 / 已排上：不重复排（按钮已置灰；控制口来的重复请求也挡在这）。排队的那单出队后才执行、确认后的续推在前一单结束后才发，都不受影响
        if (QueuePhone(game.Id, () => InstallAsync(game, accept, ask, export, device))) return;   // 出包在跑不挡；手机上装机在跑 / 这款正在出包 → 排队
        accept ??= new HashSet<string>();
        var target = export ? "" : device ?? InstallDevice(game);
        var sent = accept;
        lastInstall = () => InstallAsync(game, sent, ask, export, target);   // 失败页「重试」：同样的参数再发一次
        installExport = export; installChoice = null;
        var front = BeginPhoneJob(game, "");
        string? dropAsk = null, askCode = null;
        try
        {
            var extra = AcceptExtra(accept, target) ?? new Dictionary<string, object?>();
            if (export) extra["mode"] = "export";
            if (!HomeWidget) extra["widget"] = false;   // 玩家关了「装到 iPhone 时带主屏小组件」
            var job = await PackJobClient.RunAsync(PackRequest("install", game.Id, extra), e => Dispatcher.UIThread.Post(() => IngestPhoneEvent(e)), front.Token, front.Next());
            if (ask && JobCode(job) is { } c && ConfirmCodes.ContainsKey(c)) { dropAsk = job.Report.Message; askCode = c; }
            installedTo = job.Report.Succeeded ? InstalledLabel(job.Report.Result) : "";
            installCode = job.Report.Succeeded ? null : JobCode(job);
            installChoice = !job.Report.Succeeded && PhoneOverview.ChoiceFacts(job.Report.Diagnostics) is { } choice
                ? new PushChoice(choice.Device, choice.Candidates, job.Report.Message, () => InstallAsync(game, accept, ask, export, device)) : null;
            installState = job.Report.State;
            installMessage = job.Report.Succeeded && job.Report.Result.TryGetProperty("device", out var on) && on.ValueKind == JsonValueKind.String
                ? T("install.device") + " · " + on.GetString() : job.Report.Message;
            // 资源传完但电脑没拉起 App 解开（作业结果 unpackPending，11-09 #336）：不显示「已推到 iPhone」，显示还差的一步和原因 / 办法
            if (job.Report.Succeeded && job.Report.Result.TryGetProperty("unpackPending", out var pending) && pending.ValueKind == JsonValueKind.String)
            { installState = "needsPlayer"; installMessage = pending.GetString() ?? ""; }
            installOpenToFinish = job.Report.Succeeded && job.Report.Result.TryGetProperty("openToFinish", out var open) && open.ValueKind == JsonValueKind.True;
            installTrustName = job.Report.Succeeded && job.Report.Result.TryGetProperty("trustName", out var trust) && trust.ValueKind == JsonValueKind.String ? trust.GetString() ?? "" : "";
            installDiagnostics = JobDiagnostics(job);
            installTrack.Finish(job, GameName);
            // 导出自签包：打开放好的文件夹。独立 App 导出不自动开（成功页 B 有「在资源管理器中显示」「打开说明」）
            if (job.Report.Succeeded && installTrack.ExportFolder.Length > 0 && !installTrack.Standalone) OpenFolder(installTrack.ExportFolder);
        }
        catch (LibraryProtocolException error) { installState = "invalid"; installDiagnostics = error.Message; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or
            OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { installState = "failed"; installDiagnostics = error.Message; }
        finally { EndJob(front); readinessFor = null; DynamicFinished(installState); AfterArtifactJob(); Render(); }
        if (dropAsk is not null && await ConfirmInstallActionAsync("install.drop", dropAsk, ConfirmTitle(askCode), askCode, game))
            await InstallAsync(game, new HashSet<string>(accept) { ConfirmCodes[askCode!] }, export: export, device: device);
    }

    /// 装到哪台：清单报回来的那台（续签时就是当初那台，在线才有），没有就是装机记录里的那台（不在线时作业层如实说「它不在线」）。
    /// 作业层收不到设备号就拒绝、不自己挑（11-11：续签时同网的 iPad 被装上）
    private string InstallDevice(LibraryGame game) =>
        readiness is { Device.Length: > 0 } r && readinessFor == game.Id ? r.Device : game.IphoneInstallDevice;

    private string GameName(string id) => catalog?.Games.FirstOrDefault(g => string.Equals(g.Id, id, StringComparison.OrdinalIgnoreCase))?.Name ?? id;

    private static string InstalledLabel(JsonElement result)
    {
        string S(string k) => result.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        var kind = S("deviceKind"); var name = S("deviceName");
        if (kind.Length == 0) kind = "iPhone / iPad";
        return name.Length > 0 ? kind + "「" + name + "」" : kind;
    }

    private static Dictionary<string, object?>? DeviceExtra(string device) => device.Length > 0 ? new() { ["device"] = device } : null;

    private static Dictionary<string, object?>? AcceptExtra(IReadOnlySet<string> accept, string device = "")
    {
        var extra = new Dictionary<string, object?>();
        foreach (var key in accept) extra[key] = true;
        if (device.Length > 0) extra["device"] = device;
        return extra.Count > 0 ? extra : null;
    }

    private static string? JobCode(LibraryJobOutput job) => job.Report.FailureCode;

    private async Task ChooseCoverAsync(LibraryGame game)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = T("custom.cover.help"), AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType(T("custom.cover.help")) { Patterns = ["*.jpg", "*.jpeg", "*.png"] }]
        });
        if (files.Count == 1 && files[0].TryGetLocalPath() is { } path) await CustomizeAsync(game, null, path);
    }

    private async Task RenameGameAsync(LibraryGame game)
    {
        var dialog = new Window
        {
            Title = T("custom.name.title"), Width = 420, SizeToContent = SizeToContent.Height,
            CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Canvas, Foreground = Ink,
            FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope")
        };
        string? result = null;
        var body = new StackPanel { Spacing = 16, Margin = new Thickness(28) };
        body.Children.Add(Label(T("custom.name.title"), 20));
        var box = new TextBox { Text = game.Name, MaxLength = 64 };
        AutomationId(box, "export.name.input");
        body.Children.Add(box);
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        Button DialogButton(string key, bool primary, Action click)
        {
            var button = new Button { Content = T(key), Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(8), Margin = new Thickness(12, 0, 0, 0),
                Background = primary ? Accent : Brush.Parse("#29292D"), Foreground = primary ? Canvas : Ink };
            button.Click += (_, _) => { click(); dialog.Close(); };
            buttons.Children.Add(button);
            return button;
        }
        if (game.CustomName) DialogButton("custom.name.reset", false, () => result = "");
        DialogButton("action.cancel", false, () => { });
        AutomationId(DialogButton("custom.save", true, () => result = box.Text ?? ""), "export.name.save");
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        if (result is not null) await CustomizeAsync(game, result, null);
    }

    /// <summary>name / coverPath: null leaves it alone, empty restores the default.</summary>
    private async Task CustomizeAsync(LibraryGame game, string? name, string? coverPath)
    {
        if (customizing || BusyFor(game)) return;
        customizing = true; customizeError = ""; Render();
        var extra = new Dictionary<string, object?>();
        if (name is not null) extra["name"] = name;
        if (coverPath is not null) extra["coverPath"] = coverPath;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("customize", game.Id, extra), null, CancellationToken.None);
            if (!job.Report.Succeeded) customizeError = job.Report.Message;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { customizeError = error.Message; }
        finally { customizing = false; }
        if (customizeError.Length == 0) await RunLibraryAsync("catalog", null);
        Render();
    }

    private async Task ConfirmRemoveAsync(LibraryGame game)
    {
        if (await ConfirmInstallActionAsync("install.remove")) await RunPhoneJobAsync(game, "installRemove", "install.remove");
    }

    private async Task ConfirmRestoreAsync(LibraryGame game)
    {
        if (await ConfirmInstallActionAsync("install.restore")) await RunPhoneJobAsync(game, "installRestore", "install.restore");
    }

    /// <summary>换游戏库 setup 撞上认得出的风险 → 问玩家时带的参数（同 Mac S2ArmLauncherModel.libraryConfirmCodes）：
    /// library_in_cloud 选的文件夹在云盘同步目录里；library_folder_not_empty 文件夹里已有别的文件、又不是游戏库（S2Arm 只动自己建的文件）</summary>
    /// 同一张表（共享体验表 errors 的 accept；library_bad_format 带 accept_ui，由选盘页 LibraryDrivePicker 带 acceptFormat，不在这里问）
    private IReadOnlyDictionary<string, string> LibraryConfirmCodes => text.ConfirmFlags;

    /// <summary>setup 没成、失败码是认得出的风险、这一项还没确认过：问「仍然继续 / 先不」；同意就把对应参数加进 accept 返回 true，调用方带着它重发（参数累积）</summary>
    private async Task<bool> ConfirmLibraryAsync(LibraryJobOutput setup, HashSet<string> accept)
    {
        if (setup.Report.Succeeded || JobCode(setup) is not { } code || !LibraryConfirmCodes.TryGetValue(code, out var flag) || accept.Contains(flag)) return false;
        if (!await ConfirmInstallActionAsync("install.drop", setup.Report.Message, ConfirmTitle(code))) return false;
        accept.Add(flag);
        return true;
    }

    /// <summary>Confirm dialog for a phone-side action; texts are &lt;prefix&gt;_title / _body / _confirm.</summary>
    /// askCode：作业层的可确认停装码；它在共享体验表登记了 alternate（如新建证书确认的「改用已有证书」）就多画一个并列按钮，
    /// 点了不重发（返回 false）、按 alternate 的动作走装机前清单同一个派发 RunInstallAction（devCertSettings = 设置页签名方式那一栏）
    private async Task<bool> ConfirmInstallActionAsync(string prefix, string? bodyText = null, string? titleText = null, string? askCode = null, LibraryGame? game = null)
    {
        var dialog = new Window
        {
            Title = titleText ?? T(prefix + "_title"), Width = 420, SizeToContent = SizeToContent.Height,
            CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Canvas, Foreground = Ink,
            FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope")
        };
        var confirmed = false;
        var body = new StackPanel { Spacing = 16, Margin = new Thickness(28) };
        body.Children.Add(Label(titleText ?? T(prefix + "_title"), 20));
        body.Children.Add(Muted(bodyText ?? T(prefix + "_body"), 14));
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = T("action.cancel"), Padding = new Thickness(16, 9),
            Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8),
            Margin = new Thickness(0, 0, 12, 0) };
        cancel.Click += (_, _) => dialog.Close();
        buttons.Children.Add(cancel);
        string? alternate = null;
        if (askCode is { Length: > 0 } && text.ConfirmAlternates.TryGetValue(askCode, out var alt))
        {
            var other = new Button { Content = T(alt.Label), Padding = new Thickness(16, 9),
                Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8),
                Margin = new Thickness(0, 0, 12, 0) };
            AutomationId(other, prefix + "_alternate");
            other.Click += (_, _) => { alternate = alt.Action; dialog.Close(); };
            buttons.Children.Add(other);
        }
        var confirm = new Button { Content = T(prefix + "_confirm"), Padding = new Thickness(16, 9),
            Background = Accent, Foreground = Canvas, CornerRadius = new CornerRadius(8) };
        AutomationId(confirm, prefix + "_confirm");
        confirm.Click += (_, _) => { confirmed = true; dialog.Close(); };
        buttons.Children.Add(confirm);
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        if (alternate is not null) RunInstallAction(alternate, game);
        return confirmed;
    }

    /// <summary>installRemove / installRestore; texts are &lt;prefix&gt;_running / _done / _failed.</summary>
    private async Task RunPhoneJobAsync(LibraryGame game, string operation, string prefix, IReadOnlySet<string>? accept = null, bool ask = true)
    {
        if (QueuePhone(game.Id, () => RunPhoneJobAsync(game, operation, prefix, accept, ask))) return;   // 同 InstallAsync
        accept ??= new HashSet<string>();
        var front = BeginPhoneJob(game, T(prefix + "_running"), operation);
        string? dropAsk = null, askCode = null;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest(operation, game.Id, AcceptExtra(accept, game.IphoneInstallDevice is { Length: > 0 } d ? d : InstallDevice(game))), e => Dispatcher.UIThread.Post(() => IngestPhoneEvent(e)), front.Token, front.Next());
            if (ask && JobCode(job) is { } c && ConfirmCodes.ContainsKey(c)) { dropAsk = job.Report.Message; askCode = c; }
            installState = job.Report.State;
            installMessage = job.Report.Succeeded ? T(prefix + "_done") : job.Report.Message;
            installDiagnostics = JobDiagnostics(job);
            installTrack.Finish(job, GameName);
        }
        catch (LibraryProtocolException error) { installState = "invalid"; installDiagnostics = error.Message; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or
            OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { installState = "failed"; installMessage = T(prefix + "_failed"); installDiagnostics = error.Message; }
        finally { EndJob(front); AfterArtifactJob(); Render(); }
        if (dropAsk is not null && await ConfirmInstallActionAsync("install.drop", dropAsk, ConfirmTitle(askCode), askCode, game))
            await RunPhoneJobAsync(game, operation, prefix, new HashSet<string>(accept) { ConfirmCodes[askCode!] });
    }

    /// <summary>Closing while a pack runs: cancel through the job control plane first, then close.</summary>
    private async void ClosePackAsync(object? sender, WindowClosingEventArgs args)
    {
        if (!packRunning || closeAnyway) return;
        args.Cancel = true;
        batchRunning = false;   // 关窗口不算取消整批：批次里这款留着「正在出」，下次打开 recover 记成被打断、重新排队（同 Mac）
        CloseLog("关窗口：出包在跑，先取消、等它收尾再关");
        await WaitJobsEndAsync(JobKind.Pack);
        await Dispatcher.UIThread.InvokeAsync(() => { }, DispatcherPriority.Background);
        Close();
    }
}
