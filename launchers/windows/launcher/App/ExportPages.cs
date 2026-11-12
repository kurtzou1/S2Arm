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
    private void OpenBundledImpactor()
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(BundledImpactor) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(BundledImpactor)! });
            if (p is null) installDiagnostics = T("process.start_failed");
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or InvalidOperationException)
        { installDiagnostics = T("process.start_failed") + " " + error.Message; }
        Render();
    }

    private const string PlatformIos = "ios";
    private bool exportIos = true;
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
    private string revealProblem = "";   // 「显示 IPA」「打开游戏文件夹」找不到目标时的提示（不打开空的资源管理器）
    // 当前 / 最近一次手机作业属于哪一款（#308：原先只有一份「当前安装」状态、没记是哪款，回游戏库再点别的游戏，进度会画到那款上）。
    //   installSeen：跑完后玩家回安装页看过结果没有；没看过时顶栏胶囊一直在。进度计数来自作业事件 done / total / unit（推资源包按字节，机上解包按包）
    private string? installGameId, installGameName;
    private long? installDone, installTotal;
    private string installUnit = "";
    private DateTime installRateAt; private long installRateBase; private double? installRate;
    private bool installSeen = true;

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

    /// 顶栏胶囊（#308，Mac 同款）：装机在跑 → 「正在装到 iPhone：X · 查看进度」；跑完没回去看 → 「已装到 / 没装完 · 查看」。正看着这款的安装页时不显示
    private Button? PhonePill()
    {
        if (installGameId is null || (!installBusy && installSeen) || (page == "install" && SelectedGame?.Id == installGameId)) return null;
        var key = installBusy ? "install.pill.running" : installState == "succeeded" ? "install.pill.done" : installState == "needsPlayer" ? "install.pill.needs_player" : "install.pill.failed";
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

        // 底部操作栏
        var bottomBar = RenderBottomBar();

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

    /// <summary>The build tab opens the progress page while a pack is running or its result is on screen.</summary>
    private void OpenBuild()
    {
        locationsFor = null;   // 出包页每次打开都重读存放位置（剩余空间是当时的）
        if (packRunning || (packState == "succeeded" && packGame?.Id == selectedGame)) { Navigate("progress"); return; }
        Navigate("build");
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
        body.Children.Add(Muted(T("batch.hint")));   // 批量出包（v0.2.4）：添加游戏一次放进多款，导入完列成清单连续出包

        // platforms
        var heading = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        heading.Children.Add(Label(T("export.platforms"), 16));
        var existing = Action(PadKey("export.install_existing"), () => { readinessFor = null; Navigate("install"); }, !BusyFor(game) || installBusy);   // 装机中也能进装机页：看别的游戏时提示「另一款正在装 · 查看那一款」
        Grid.SetColumn(existing, 1); heading.Children.Add(existing);
        body.Children.Add(heading);
        var tiles = new UniformGrid { Columns = 4 };
        foreach (var platform in new[] { PlatformIos, "mac", "android", "ohos" })
        {
            var open = platform == PlatformIos;
            var on = open && exportIos;
            var tile = new StackPanel { Spacing = 10 };
            var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            top.Children.Add(Label(T("export.platform." + platform), 16));
            var mark = Label(open ? (on ? "☑" : "☐") : "🔒", 16);
            Grid.SetColumn(mark, 1); top.Children.Add(mark);
            tile.Children.Add(top);
            tile.Children.Add(Muted(T(platform switch
            {
                PlatformIos => "export.note.ios", "mac" => "export.note.mac_only", _ => "export.soon"
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
            card.Click += (_, _) => { exportIos = !exportIos; Render(); };
            tiles.Children.Add(card);
        }
        body.Children.Add(tiles);
        body.Children.Add(LocationRow(game));
        if (exportIos) body.Children.Add(InstallModeLine());   // 装到 iPhone：一键装（Apple ID / 我的开发者证书）或导出 + 「更改」去环境检查（v0.3.0，InstallModePage.cs）

        // action bar
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16 };
        var blocker = ExportBlocker(game);
        var reason = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        reason.Children.Add(Muted(blocker ?? T("export.hint"), 14));
        if (ExportBlockerKind(game) == "keys") reason.Children.Add(Action("nav.library", () => Navigate("library")));
        bar.Children.Add(reason);
        var start = Primary(T("export.start"), () => StartPack(game), !ExportStops(game));   // 缺文件 / 缺 keys 只在左边提示，不置灰（作业层核实）
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
        _ => null,
    };

    /// <summary>挡路的是哪一类（按种类判，不拿显示文案做字符串相等，剃刀 W10）：platform / files / keys / busy；null = 能出。</summary>
    /// <summary>挡不挡开始：缺文件（files）/ 缺 keys（keys）只提示、不挡（v0.3.1「拿不准不停」，同 Mac ExportBlocker.stopsStart）——
    /// 两项来自游戏库读数、可能是旧的；出包作业开头自己核（library.requirement_errors：input_missing / keys_missing），真缺才停</summary>
    private bool ExportStops(LibraryGame game) => ExportBlockerKind(game) is { } kind && kind is not ("files" or "keys");

    private string? ExportBlockerKind(LibraryGame game)
    {
        if (!exportIos) return "platform";
        if (game.Missing.Count > 0) return "files";
        if (game.NeedsKeys && catalog?.KeysReady != true) return "keys";
        if (BusyFor(game) || busy || batchRunning) return "busy";   // 只锁正在装的那款（后端安装不占出包执行锁）；批量出包进行中两款之间也不插单款
        return null;
    }

    private PackJobClient.Request PackRequest(string operation, string gameId, IReadOnlyDictionary<string, object?>? extra = null) =>
        new(paths, privateRoot, connectedFolder!, libraryId!, operation, gameId, extra);

    // ---- pack job ----

    private void StartPack(LibraryGame game, bool spaceOverride = false)
    {
        if (ExportStops(game)) return;
        // 「仍然出包」重试沿用这一款上次选的位置；出包页没读到这款时不传，后端按这款现在的位置
        if (!spaceOverride || packGame?.Id != game.Id) packLocation = locationsFor == game.Id && exportLocation.Length > 0 ? exportLocation : null;
        ResetPack(game);
        Navigate("progress");
        packOperation = RunPackAsync(game, spaceOverride);
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
        packIpaBytes = null; packPackBytes = null; packNotes = []; packSpace = null; sessionHidden = false; packFailureCode = null;
        exportStepEnded = false; exportChildReport = null;
    }

    /// <summary>出包页单款：同批量出包走出包编排作业（剃刀 H13），计划只有这一款的 iPhone、不写批次文件</summary>
    private Task RunPackAsync(LibraryGame game, bool spaceOverride) =>
        RunExportAsync(ExportStream.InlinePlan(game.Id, game.Name, ["iphone"], packLocation, spaceOverride), batch: false);

    // 这一步收到 stepEnded 没有（没收到 = 编排作业在第一步前就结束了：被拒、已有一个在出、取消）；子作业的终态（失败页的原因 / 建议从这里读）
    private bool exportStepEnded;
    private LibraryJobResult? exportChildReport;

    /// <summary>跑一个出包编排作业：每一步的开始 / 子作业事件 / 结局都由 OnExportEvent 显示；取消 = 取消这个作业（它把正在出的那步停下）</summary>
    private async Task RunExportAsync(Dictionary<string, object?> plan, bool batch)
    {
        var front = packJob!;
        LibraryJobOutput? job = null;
        string? error = null, endState = null;
        try
        {
            job = await PackJobClient.RunAsync(PackRequest("export", "", new Dictionary<string, object?> { ["plan"] = plan }),
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
                Render();
                if (batch) _ = BatchExportEndedAsync(job?.Report, error);
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
                packSummary = o.Message; packIpa = o.Ipa; packIpaBytes = o.IpaBytes; packPackBytes = o.PackBytes; packNotes = o.Notes ?? []; packFailureCode = o.Code;
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
        leftCol.Children.Add(LiveSlot(() => packSpace is { } sp ? SpaceCard(sp) : null));   // 空间事件随时到：每秒刷新这一格
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

            // 两个大按钮
            var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
            var install = Primary(T(PadKey("export.done.install")), () => { readinessFor = null; Navigate("install"); });
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
            result.Children.Add(Muted(T("export.win.done.installNote"), 12));

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

    /// 「复制错误摘要」：正文由作业层 report.py 生成（Mac / Windows 同一份）；没有作业记录才用 fallback。
    /// operations 为 null：这种失败没有作业记录（环境检查），直接用 fallback。
    private Button CopyReportButton(string? gameId, string[]? operations, Func<string> fallback)
    {
        var copy = new Button { Content = T("export.fail.copy"), Padding = new Thickness(16, 9),
            Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
        copy.Click += async (_, _) =>
        {
            var extra = System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["app"] = AppVersion,
                ["checks"] = (report?.Checks ?? []).Where(c => c.Status != "ok")
                    .Select(c => new Dictionary<string, string> { ["name"] = c.Name, ["message"] = c.Message }).ToList()
            });
            var text = (operations is null ? null : await JobReportClient.RunAsync(paths, privateRoot, gameId, operations, extra)) ?? fallback();
            if (TopLevel.GetTopLevel(this)?.Clipboard is { } clipboard) await clipboard.SetTextAsync(text);
            copy.Content = T("export.fail.copied");
        };
        return copy;
    }

    // ---- error summary for clipboard (only when the job left no record) ----

    private string ErrorSummary(LibraryGame game)
    {
        var lines = new List<string>
        {
            "S2Arm 出包失败报告", "",
            "游戏：" + game.Name,
            "版本：" + game.Version,
            "程序号：" + game.Id,
            "原包大小：" + FormatBytes(game.TotalBytes),
            "",
            "本体 / 更新 / DLC：" + (game.BaseVersion ?? "-") + " / " + (game.UpdateVersion ?? "-") + " / " + game.DlcCount,
            "",
            "错误：", packSummary,
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
        body.Children.Add(Label(T(PadKey("install.title")), 22));
        body.Children.Add(Muted(T("install.description"), 14));
        body.Children.Add(Muted(T("install.container_note"), 14));
        body.Children.Add(Muted(T("install.legacy_note"), 14));
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
            else if (!item.Ok && item.Action == "openImpactor")
            {
                // 签名身份（Apple ID 在 Impactor 里登录 / 开发者证书）统一在环境检查「装到 iPhone 的方式」里设（v0.3.0）
                var open = new Button { Content = T("install.mode.go_settings"), Background = Accent, Foreground = Canvas,
                    Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
                AutomationId(open, "install.go_settings");
                open.Click += (_, _) => Navigate("settings");
                Grid.SetColumn(open, 2); row.Children.Add(open);
            }
            list.Children.Add(row);
        }
        if (readiness is { Device.Length: > 0 }) list.Children.Add(Muted(T("install.device") + " · " + readiness.Device));
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
        var recheck = Action("action.recheck", () => _ = CheckInstallAsync(), !installChecking && !installBusy);
        recheck.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(recheck);
        var start = Primary(T("install.start"), () => _ = InstallAsync(game), !installBusy && !packRunning);   // 不按清单置灰（同 Mac InstallView）：真做不下去的作业层开头判、回真实原因
        AutomationId(start, "install.start");
        buttons.Children.Add(start);
        var remove = new Button { Content = T("install.remove_game"), IsEnabled = !installBusy && !packRunning,
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
            var restore = new Button { Content = T("install.restore"), IsEnabled = !installBusy && !packRunning,
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
            other.Children.Add(Muted(T(installBusy ? "install.pill.running" : installState == "succeeded" ? "install.pill.done" : installState == "needsPlayer" ? "install.pill.needs_player" : "install.pill.failed").Replace("{0}", installGameName ?? installGameId).Replace("{1}", InstallTargetLabel)));
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
    private Control InstallStateCard(LibraryGame game)
    {
        // 装机 / 续签 / 删除 / 装回：同一张结局卡（PhoneJobCard.cs，同 Mac PhoneJobPanel）；Apple ID 登录过期另给「打开 Impactor 重新登录」
        var notes = new List<string>();
        if (installState == "succeeded" && installTrack.Kind == "install" && installOpenToFinish) notes.Add(T("install.done.open"));
        var state = new StackPanel { Spacing = 16 };
        state.Children.Add(PhoneJobCard(installTrack, installState, installMessage, installDiagnostics, game.Id, notes));
        if (installState is "failed" && installCode == "apple_session_expired")
        {
            // Apple ID 登录过期（Apple 1100）：打开 Impactor 让玩家自己重新登录（密码不经手），登录好再点一次「装到 iPhone」
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
    internal static readonly IReadOnlyDictionary<string, string> ConfirmCodes = new Dictionary<string, string>
    {
        ["container_would_drop"] = "acceptDropped", ["save_backup_failed"] = "acceptNoBackup", ["container_stale"] = "acceptStale",
    };

    /// <summary>可确认的停装码要问的那句标题：文案表有 errors.&lt;码&gt;.title 就用它，没有用通用的 install.drop_title</summary>
    private string ConfirmTitle(string? code) => code is { Length: > 0 } && text.Has("errors." + code + ".title") ? T("errors." + code + ".title") : T("install.drop_title");

    /// <summary>控制口请求里带的确认参数（acceptDropped / acceptNoBackup / acceptStale）</summary>
    private static HashSet<string> AcceptFlags(ControlRequest r) => ConfirmCodes.Values.Where(r.Flag).ToHashSet();

    /// <summary>accept：玩家已同意的确认参数（ConfirmCodes 的值，逐次累积）。ask = false（控制口）原样失败、不弹确认，由调用方带参数再发。</summary>
    private async Task InstallAsync(LibraryGame game, IReadOnlySet<string>? accept = null, bool ask = true)
    {
        if (installBusy) return;
        accept ??= new HashSet<string>();
        var front = BeginPhoneJob(game, "");
        string? dropAsk = null, askCode = null;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("install", game.Id, AcceptExtra(accept, InstallDevice(game))), e => Dispatcher.UIThread.Post(() => IngestPhoneEvent(e)), front.Token, front.Next());
            if (ask && JobCode(job) is { } c && ConfirmCodes.ContainsKey(c)) { dropAsk = job.Report.Message; askCode = c; }
            installedTo = job.Report.Succeeded ? InstalledLabel(job.Report.Result) : "";
            installCode = job.Report.Succeeded ? null : JobCode(job);
            installState = job.Report.State;
            installMessage = job.Report.Succeeded && job.Report.Result.TryGetProperty("device", out var device) && device.ValueKind == JsonValueKind.String
                ? T("install.device") + " · " + device.GetString() : job.Report.Message;
            // 资源传完但电脑没拉起 App 解开（作业结果 unpackPending，11-09 #336）：不显示「已装到 iPhone」，显示还差的一步和原因 / 办法
            if (job.Report.Succeeded && job.Report.Result.TryGetProperty("unpackPending", out var pending) && pending.ValueKind == JsonValueKind.String)
            { installState = "needsPlayer"; installMessage = pending.GetString() ?? ""; }
            installOpenToFinish = job.Report.Succeeded && job.Report.Result.TryGetProperty("openToFinish", out var open) && open.ValueKind == JsonValueKind.True;
            installDiagnostics = JobDiagnostics(job);
            installTrack.Finish(job, GameName);
        }
        catch (LibraryProtocolException error) { installState = "invalid"; installDiagnostics = error.Message; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or
            OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { installState = "failed"; installDiagnostics = error.Message; }
        finally { EndJob(front); readinessFor = null; Render(); }
        if (dropAsk is not null && await ConfirmInstallActionAsync("install.drop", dropAsk, ConfirmTitle(askCode)))
            await InstallAsync(game, new HashSet<string>(accept) { ConfirmCodes[askCode!] });
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

    private static string? JobCode(LibraryJobOutput job)
    {
        if (job.Report.Diagnostics.ValueKind != JsonValueKind.Array) return null;
        foreach (var d in job.Report.Diagnostics.EnumerateArray())
            if (d.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.String) return code.GetString();
        return null;
    }

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
    internal static readonly IReadOnlyDictionary<string, string> LibraryConfirmCodes = new Dictionary<string, string>
    {
        ["library_in_cloud"] = "acceptCloud", ["library_folder_not_empty"] = "acceptForeign",
    };

    /// <summary>setup 没成、失败码是认得出的风险、这一项还没确认过：问「仍然继续 / 先不」；同意就把对应参数加进 accept 返回 true，调用方带着它重发（参数累积）</summary>
    private async Task<bool> ConfirmLibraryAsync(LibraryJobOutput setup, HashSet<string> accept)
    {
        if (setup.Report.Succeeded || JobCode(setup) is not { } code || !LibraryConfirmCodes.TryGetValue(code, out var flag) || accept.Contains(flag)) return false;
        if (!await ConfirmInstallActionAsync("install.drop", setup.Report.Message, ConfirmTitle(code))) return false;
        accept.Add(flag);
        return true;
    }

    /// <summary>Confirm dialog for a phone-side action; texts are &lt;prefix&gt;_title / _body / _confirm.</summary>
    private async Task<bool> ConfirmInstallActionAsync(string prefix, string? bodyText = null, string? titleText = null)
    {
        if (installBusy || packRunning) return false;
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
        var confirm = new Button { Content = T(prefix + "_confirm"), Padding = new Thickness(16, 9),
            Background = Accent, Foreground = Canvas, CornerRadius = new CornerRadius(8) };
        AutomationId(confirm, prefix + "_confirm");
        confirm.Click += (_, _) => { confirmed = true; dialog.Close(); };
        buttons.Children.Add(confirm);
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        return confirmed;
    }

    /// <summary>installRemove / installRestore; texts are &lt;prefix&gt;_running / _done / _failed.</summary>
    private async Task RunPhoneJobAsync(LibraryGame game, string operation, string prefix, IReadOnlySet<string>? accept = null, bool ask = true)
    {
        if (installBusy || packRunning) return;
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
        finally { EndJob(front); Render(); }
        if (dropAsk is not null && await ConfirmInstallActionAsync("install.drop", dropAsk, ConfirmTitle(askCode)))
            await RunPhoneJobAsync(game, operation, prefix, new HashSet<string>(accept) { ConfirmCodes[askCode!] });
    }

    /// <summary>Closing while a pack runs: cancel through the job control plane first, then close.</summary>
    private async void ClosePackAsync(object? sender, WindowClosingEventArgs args)
    {
        if (!packRunning) return;
        args.Cancel = true;
        batchRunning = false;   // 关窗口不算取消整批：批次里这款留着「正在出」，下次打开 recover 记成被打断、重新排队（同 Mac）
        packJob?.Cancellation.Cancel();
        if (packOperation is { } operation) await operation;
        await Dispatcher.UIThread.InvokeAsync(() => { }, DispatcherPriority.Background);
        Close();
    }
}
