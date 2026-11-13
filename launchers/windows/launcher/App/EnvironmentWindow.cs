// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow : Window
{
    private static readonly IBrush Canvas = Brush.Parse("#0E0E10");
    private static readonly IBrush Surface = Brush.Parse("#19191C");
    private static readonly IBrush Ink = Brush.Parse("#F2F0EB");
    private static readonly IBrush Accent = Brush.Parse("#FFF0D6");
    private readonly SharedText text;
    private string language = "zh-Hans";
    private bool welcomeHome;   // 点了顶栏品牌名：游戏库页先显示欢迎页（点「游戏库」或去别的页就回到平常）
    private LauncherPaths paths = LauncherPaths.Defaults(AppContext.BaseDirectory);
    private EnvironmentReport? report;
    private DateTime lastAutoCheck = DateTime.MinValue;   // 回到窗口自动重查的上一次时刻（Activated，5 秒内不重复）
    private string summaryKey = "environment.idle";
    private string unexpectedError = "";

    /// <summary>Program.cs 全局兜底接住界面线程上没处理的异常后调：只在顶部报出来，不碰作业登记（启动器剃刀 W3）——
    /// 原先这里把忙碌标记清掉，正在跑的游戏库作业「看起来空闲」，玩家能再起一个并发作业。作业登记只由作业自己收尾时撤（JobSlots.cs EndJob）。</summary>
    internal void ReportUnexpected(Exception error, string logPath)
    {
        unexpectedError = error.GetType().Name + ": " + error.Message + "\n" + T("launcher.unexpected_log") + " " + logPath;
        try { Render(); } catch (Exception again) { LauncherCrash.Log(again, "render after unexpected"); }
    }
    private string diagnostics = "";
    private TextBox engine = new(), runtime = new(), shell = new();

    public EnvironmentWindow()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("S2Arm.experience.v1.json")
            ?? throw new FileNotFoundException("Shared experience resource is missing.");
        using var reader = new StreamReader(stream);
        var experience = reader.ReadToEnd();
        text = new SharedText(experience);
        PrivateJobRequest.Describe = (code, path) => T("private_root." + code).Replace("{0}", path);   // 私有目录用不了时的话按当前界面语言（#672）
        PrivateJobRequest.Note = note => LauncherCrash.Log(null, note);   // 私有目录自愈 / 收不紧记一笔（#754）
        using var table = Assembly.GetExecutingAssembly().GetManifestResourceStream("S2Arm.Localizable.json")
            ?? throw new FileNotFoundException("Localization table resource is missing.");
        using var tableReader = new StreamReader(table);
        backend = new BackendText(tableReader.ReadToEnd(), experience);
        MetalFolder.Load(privateRoot);   // 上次手动指定的 Metal 文件夹：设进本进程环境，环境检查 / 出包子进程继承
        Width = 1080; Height = 820; MinWidth = 760; MinHeight = 600;
        Background = Canvas; Foreground = Ink;
        FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope");
        Closed += (_, _) => { CancelJob(JobKind.Environment); ClearCovers(); DisposeRetiredCovers(all: true); CloseControl(); };
        Opened += (_, _) =>
        {
            StartControl(); FinishPendingUpdate(); SyncInstalledVersion(); _ = LoadInboxAsync();
            _ = RecoverBatchAsync();   // 上次没出完的批量出包读回来（BatchPage.cs）
            // 已有游戏库（存过位置，或默认位置建好过）就一启动连上，同 Mac：原先只有控制口开着才连，玩家默认不开，
            //   开机 catalog 为空、点「游戏库」一直是欢迎页（社区贡献者补丁 #1）。全新玩家照旧走欢迎页，不替他建库
            if (File.Exists(LibraryPreference) || File.Exists(Path.Combine(SavedLibrary(), ".s2arm-library.json"))) EnsureLibrary(() => { });
        };
        Closing += CloseLibraryAsync;
        Closing += ClosePackAsync;
        // 欢迎页进来自动触发环境检查；上次查出还有必需项没就绪（多半是 Metal 编译器，玩家去 Apple 官网装完切回来）时，回到窗口也重查——
        //   原先只在还没查过时查，玩家装好切回来还显示没装，要自己点「重新检查」或重开（11-11 新用户首装实测）。5 秒内不重复查
        Activated += (_, _) =>
        {
            if (busy || (report is not null && report.Ready) || DateTime.UtcNow - lastAutoCheck < TimeSpan.FromSeconds(5)) return;
            lastAutoCheck = DateTime.UtcNow; _ = CheckAsync();
        };
        DockPanel.SetDock(pageTop, Dock.Top); DockPanel.SetDock(pageBottom, Dock.Bottom);
        pageScroll.Content = pageBody;
        pageFrame.Children.Add(pageTop); pageFrame.Children.Add(pageBottom); pageFrame.Children.Add(pageScroll);
        Render();
    }

    // ── 页面外框（跳动根修，11-11）───────────────────────────────────────
    // 原先每次 Render() 都 new 一个 ScrollViewer：游戏库 / 存放位置 / 环境检查等页一重画就回到顶部；出包页、批量页
    //   事后 Post 到 Loaded 优先级再恢复滚动位置，但渲染优先级更高，中间那一帧照旧画在顶部——玩家看到整页每秒往下错一下、带重影。
    // 现在整窗只有一套外框：顶槽 / 底槽 + 同一个 ScrollViewer，重画只换里面的内容，滚动位置由它自己保持；只在换页时回到顶部。
    //   ScrollViewer 的直接内容也固定（pageBody）：换 ScrollViewer.Content 本身会让 Avalonia 把滚动位置归零（修前探针实测），只换 pageBody.Child。
    private readonly DockPanel pageFrame = new() { LastChildFill = true };
    private readonly ContentControl pageTop = new(), pageBottom = new();
    private readonly ScrollViewer pageScroll = new() { HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
    private readonly Decorator pageBody = new();
    private string pageScrollKey = "";

    /// <summary>把这一页的内容放进固定外框。key 不同（换了页 / 换成欢迎页、添加游戏弹窗）才回到顶部。</summary>
    private void ShowPage(string key, Control body, Control? top = null, Control? bottom = null)
    {
        if (key != pageScrollKey) { pageScroll.Offset = default; pageScrollKey = key; }
        pageTop.Content = top; pageBottom.Content = bottom; pageBody.Child = body;
        if (!ReferenceEquals(Content, pageFrame)) Content = pageFrame;
    }

    // 高频刷新（出包计时每秒、装机 / 更新进度事件）只换这些格子里的内容，不整页重画：整页重画会丢焦点、收起下拉框、重建封面。
    //   格子在整页 Render() 时登记、下次整页 Render() 清空；结构变了（开始 / 结束、换阶段以外的状态切换）仍走 Render()。
    private readonly List<(ContentControl Slot, Func<Control?> Build)> liveSlots = [];

    private ContentControl LiveSlot(Func<Control?> build)
    {
        var slot = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        Fill(slot, build());
        liveSlots.Add((slot, build));
        return slot;
    }

    // 闪烁根修（11-11，维护者「出包页面还在闪」）：活格子原先每秒把内容整块换成新建的控件——文字一样也是新控件，
    //   不确定进度条（首次出包没有历史用时）的来回动画每秒从头重来，看着一抽一抽；装机卡、批量页进度行同理。
    //   现在新建的内容只当「目标样子」：和屏上那份逐节点比，类型一样就把会变的属性拷过去（控件不换、动画不断），对不上的节点才整个替换。
    private static void Fill(ContentControl slot, Control? content)
    {
        if (!(slot.Content is Control old && content is not null && Patch(old, content))) slot.Content = content;
        slot.IsVisible = content is not null;
    }

    /// <summary>把 next 的可见属性拷到 old 上；返回 false = 结构对不上，调用方用 next 换掉 old。
    /// 只认纯展示控件（文字、进度条、边框、面板）；按钮、输入框等带事件或状态的控件一律换新，免得留着旧的点击回调。</summary>
    private static bool Patch(Control old, Control next)
    {
        if (old.GetType() != next.GetType() || old is not (TextBlock or ProgressBar or Border or Panel)) return false;
        foreach (var p in PatchedProperties)
            if (p.IsAttached || AvaloniaPropertyRegistry.Instance.IsRegistered(next, p))
            {
                if (next.IsSet(p)) old.SetValue(p, next.GetValue(p)); else if (old.IsSet(p)) old.ClearValue(p);
            }
        if (old is Grid og && next is Grid ng)
        {
            if (!SameLengths(og.ColumnDefinitions.Select(d => d.Width), ng.ColumnDefinitions.Select(d => d.Width)))
                og.ColumnDefinitions = new ColumnDefinitions(string.Join(",", ng.ColumnDefinitions.Select(d => d.Width.ToString())));
            if (!SameLengths(og.RowDefinitions.Select(d => d.Height), ng.RowDefinitions.Select(d => d.Height)))
                og.RowDefinitions = new RowDefinitions(string.Join(",", ng.RowDefinitions.Select(d => d.Height.ToString())));
        }
        if (old is Border ob && next is Border nb)
        {
            var nc = nb.Child; nb.Child = null;
            if (!(ob.Child is Control oc && nc is not null && Patch(oc, nc))) ob.Child = nc;
        }
        if (old is Panel o && next is Panel n)
        {
            var fresh = n.Children.ToList(); n.Children.Clear();
            for (var i = 0; i < fresh.Count; i++)
            {
                if (i < o.Children.Count && Patch(o.Children[i], fresh[i])) continue;
                if (i < o.Children.Count) o.Children[i] = fresh[i]; else o.Children.Add(fresh[i]);
            }
            while (o.Children.Count > fresh.Count) o.Children.RemoveAt(o.Children.Count - 1);
        }
        return true;
    }

    private static bool SameLengths(IEnumerable<GridLength> a, IEnumerable<GridLength> b) => a.SequenceEqual(b);

    /// 活格子里会随进度变的展示属性（只拷本地设过的值，没设的清掉、回到继承 / 主题值）
    private static readonly AvaloniaProperty[] PatchedProperties =
    [
        TextBlock.TextProperty, TextBlock.ForegroundProperty, TextBlock.FontSizeProperty, TextBlock.FontWeightProperty,
        TextBlock.TextWrappingProperty, TextBlock.TextTrimmingProperty,
        Avalonia.Controls.Primitives.RangeBase.MinimumProperty, Avalonia.Controls.Primitives.RangeBase.MaximumProperty,
        Avalonia.Controls.Primitives.RangeBase.ValueProperty, ProgressBar.IsIndeterminateProperty, Avalonia.Controls.Primitives.TemplatedControl.ForegroundProperty,
        Border.BackgroundProperty, Border.BorderBrushProperty, Border.BorderThicknessProperty, Border.CornerRadiusProperty, Border.PaddingProperty,
        Panel.BackgroundProperty, StackPanel.SpacingProperty, StackPanel.OrientationProperty, WrapPanel.OrientationProperty,
        Grid.ColumnSpacingProperty, Grid.RowSpacingProperty,
        Layoutable.MarginProperty, Layoutable.WidthProperty, Layoutable.HeightProperty, Visual.IsVisibleProperty,
        Layoutable.HorizontalAlignmentProperty, Layoutable.VerticalAlignmentProperty,
        Grid.ColumnProperty, Grid.RowProperty, Grid.ColumnSpanProperty, Grid.RowSpanProperty,
    ];

    private void RefreshLive()
    {
        if (importDialog?.Targeted == true) return;   // 拖放悬停时不动界面（同 RenderCore）
        foreach (var (slot, build) in liveSlots) Fill(slot, build());
    }

    private static readonly string DisplayVersion = "v" + (typeof(EnvironmentWindow).Assembly
        .GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.1.0");

    private string T(string key) => text.Get(key, language);
    private readonly BackendText backend;
    /// <summary>作业层来的中文原句（报错、阶段、检查项、进度说明）在英文界面下的显示；T() 的文案本来就是英文，原样通过。#361</summary>
    private string B(string value) => language == "en" ? backend.English(value) : value;
    private TextBlock Label(string value, double size = 14) => new()
    {
        Text = B(value), FontSize = size, FontWeight = size >= 18 ? FontWeight.SemiBold : FontWeight.Normal,
        TextWrapping = TextWrapping.Wrap
    };
    private Button Action(string key, Action handler, bool enabled = true)
    {
        var button = new Button { Content = T(key), IsEnabled = enabled, Padding = new Thickness(16, 9),
            Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
        Avalonia.Automation.AutomationProperties.SetAutomationId(button, key);   // 自动化按文案键找按钮（如 library.connect），不靠显示文字
        button.Click += (_, _) => handler();
        return button;
    }

    private void CapturePaths()
    {
        if (page == "settings") paths = new(engine.Text ?? "", runtime.Text ?? "", shell.Text ?? "");
    }

    private void Render()
    {
        try { RenderCore(); }
        finally { DisposeRetiredCovers(); }   // 新界面换上之后才释放旧封面（ClearCovers 说明）
    }

    private void RenderCore()
    {
        if (importDialog?.Targeted == true) { renderDeferred = true; return; }
        liveSlots.Clear();
        Title = T("app.title");
        var body = new StackPanel { Spacing = 20, Margin = new Thickness(32) };
        // ── 顶栏：品牌名（左，点了回欢迎页）+ 游戏库 / 添加游戏 / 设置（右）。界面语言、存放位置、密钥这类低频设置都在「设置」页（入口整理）
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var brand = new Button
        {
            Content = new TextBlock { Text = "S2Arm × NX2Apple", FontSize = 22, FontWeight = FontWeight.SemiBold, Foreground = Ink },
            Background = Brushes.Transparent, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center,
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand)
        };
        Avalonia.Automation.AutomationProperties.SetAutomationId(brand, "top.brand");
        brand.Click += (_, _) =>   // 社区贡献者补丁 #2：点品牌名回欢迎页（同「游戏库」：出包在跑就留在后台）
        {
            if (packRunning) sessionHidden = true;
            if (!libraryBusy) importDialog = null;
            welcomeHome = true; Navigate("library");
        };
        // 版本号（11-11 维护者：玩家截图时我们一眼看出是哪一版）：正式版 v0.3.0，开发版 v0.2.9-dev+短提交号（S2Arm.csproj 构建时算好）
        var versionLabel = new TextBlock { Text = DisplayVersion, FontSize = 12.5, FontWeight = FontWeight.SemiBold, Foreground = Brush.Parse("#8C8A85"),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 4, 0, 0) };
        Avalonia.Automation.AutomationProperties.SetAutomationId(versionLabel, "topbar.version");
        header.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { brand, versionLabel } });

        var rightBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10,
            VerticalAlignment = VerticalAlignment.Center };

        rightBar.Children.Add(LiveSlot(PhonePill));   // 装机进度事件只刷新这里（IngestPhoneEvent）
        if (BatchPill() is { } batchPill) rightBar.Children.Add(batchPill);
        rightBar.Children.Add(LiveSlot(PhoneUpdateControl));   // 更新 iPhone 上的 S2Arm（壳比本版旧才出现，InstallModePage.cs）；进度事件只刷新这里
        rightBar.Children.Add(LiveSlot(UpdateControls));   // 启动器自更新：下载百分比只刷新这里
        rightBar.Children.Add(MessagesButton());   // 消息：公告和更新说明（旧的只在这里）

        // 游戏库：任何页面都能回去；出包还在跑就留在后台
        var libraryBtn = new Button
        {
            Content = T("nav.library"), Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8),
            Background = page == "library" ? Accent : Brush.Parse("#29292D"), Foreground = page == "library" ? Canvas : Ink
        };
        Avalonia.Automation.AutomationProperties.SetAutomationId(libraryBtn, "top.library");
        libraryBtn.Click += (_, _) =>
        {
            if (packRunning) sessionHidden = true;
            welcomeGameId = null;   // 点「游戏库」就是要看游戏库：欢迎页记的那一款不再把它盖住（社区贡献者补丁 #1）
            welcomeHome = false;
            if (!libraryBusy) importDialog = null;   // 添加游戏弹窗开着也能直接从导航离开（同上 #3；正在导入时不关）
            Navigate("library");
        };
        rightBar.Children.Add(libraryBtn);

        // 添加游戏
        var addGameBtn = new Button
        {
            Content = T("action.add_game"), IsEnabled = !libraryBusy && !busy,   // 没连上库也能点：OpenWelcomeGames 先连默认库（社区贡献者补丁 #4）
            Padding = new Thickness(14, 8), Background = Brush.Parse("#29292D"), Foreground = Ink,
            CornerRadius = new CornerRadius(8)
        };
        addGameBtn.Click += (_, _) => OpenWelcomeGames();
        rightBar.Children.Add(addGameBtn);

        // 设置（原「环境检查」：出包环境检查是设置页里的一组卡；圆点照旧表示环境检查结果）
        var envDot = report?.Ready == true ? "● " : report is not null ? "○ " : "";
        var envCheckBtn = new Button
        {
            Content = envDot + T("nav.settings"), IsEnabled = !busy && !libraryBusy,
            Padding = new Thickness(14, 8),
            Background = page == "settings" ? Accent : Brush.Parse("#29292D"),
            Foreground = page == "settings" ? Canvas : Ink,
            CornerRadius = new CornerRadius(8)
        };
        Avalonia.Automation.AutomationProperties.SetAutomationId(envCheckBtn, "top.settings");
        envCheckBtn.Click += (_, _) => { if (!libraryBusy) importDialog = null; Navigate(page == "settings" ? "library" : "settings"); };
        rightBar.Children.Add(envCheckBtn);

        Grid.SetColumn(rightBar, 1); header.Children.Add(rightBar);
        body.Children.Add(header);
        AddNoticeBar(body);
        if (unexpectedError.Length > 0)
        {
            // 全局兜底接住的意外错误（Program.cs）：启动器不退出，在顶部说清楚、给日志位置，玩家可以关掉提示继续用
            var panel = new StackPanel { Spacing = 8 };
            panel.Children.Add(Label(T("launcher.unexpected"), 16));
            panel.Children.Add(Muted(unexpectedError));
            var dismiss = new Button { Content = T("launcher.unexpected_dismiss"), Padding = new Thickness(12, 6), CornerRadius = new CornerRadius(8),
                Background = Brush.Parse("#29292D"), Foreground = Ink };
            Avalonia.Automation.AutomationProperties.SetAutomationId(dismiss, "launcher.unexpected_dismiss");
            dismiss.Click += (_, _) => { unexpectedError = ""; Render(); };
            panel.Children.Add(dismiss);
            body.Children.Add(Card(panel));
        }
        if (RenderPackPages(body) || RenderBatchPage()) return;
        if (importDialog is not null)
        {
            RenderImportDialog(body);
            ShowPage("import", body);
            return;
        }
        if (updatePopup is not null)   // 打开时最多一个更新弹窗，只给最新一期（UpdateFlow.cs）
        {
            RenderUpdatePopup(body);
            ShowPage("update", body);
            return;
        }
        if (messagesOpen)
        {
            RenderMessages(body);
            ShowPage("messages", body);
            return;
        }
        if (page == "library" && (ShowsWelcome || welcomeHome))
        {
            RenderWelcome(body);
            ShowPage("welcome", body);
            return;
        }
        if (page == "storage")
        {
            RenderStorage(body);
            ShowPage("storage", body);
            return;
        }
        if (page == "library")
        {
            RenderLibrary(body);
            ShowPage("library", body);
            return;
        }
        RenderSettings(body);
        ShowPage(page, body);
    }

    /// <summary>设置页（入口整理）：界面语言 → 存放位置（游戏库 / iPhone 包 / 磁盘空间）→ 密钥 → 装机方式 → AI 操作 → 出包环境检查 → 运行路径（开发用）</summary>
    private void RenderSettings(StackPanel body)
    {
        body.Children.Add(Label(T("nav.settings"), 23));

        // 界面语言（原在顶栏）
        var languages = new ComboBox
        {
            ItemsSource = new[] { T("language.zh-Hans"), T("language.en") },
            SelectedIndex = language == "zh-Hans" ? 0 : 1, IsEnabled = !busy && !libraryBusy, MinWidth = 160
        };
        Avalonia.Automation.AutomationProperties.SetAutomationId(languages, "settings.language");
        languages.SelectionChanged += (_, _) => { CapturePaths(); language = languages.SelectedIndex == 0 ? "zh-Hans" : "en"; Render(); };
        body.Children.Add(Card(SettingRow(T("settings.language"), null, languages)));

        // 存放位置：游戏库、iPhone 包、磁盘空间集中在这一处（原先游戏库页、设置页各铺一份）；单款游戏放在哪只写在游戏库那款的卡片上
        var locations = new StackPanel { Spacing = 14 };
        locations.Children.Add(Label(T("settings.locations"), 16));
        var libraryButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (connectedFolder is { } openFolder) libraryButtons.Children.Add(Action("settings.open", () => OpenFolder(openFolder)));
        libraryButtons.Children.Add(Action("environment.library.change", () => BeginPicker(ChangeLibraryAsync), !libraryBusy && !PackBusy));
        // 还没连游戏库（引导页阶段）：照样能进设置页，没有的项写「还没设置」，不灰掉、不藏起整行
        var libraryPath = connectedFolder ?? (string.IsNullOrEmpty(libraryFolder) ? null : libraryFolder);
        locations.Children.Add(SettingRow(T("settings.locations.library"), T("environment.library.detail") + (libraryPath is null ? "\n" + T("settings.locations.not_set") : ""), libraryButtons, libraryPath));
        // 出 iPhone 包成功后组在游戏库根（pack/jobs/ipa.py refresh_library_ipa）
        var ipa = connectedFolder is null ? null : Path.Combine(connectedFolder, "S2Arm.ipa");
        var ipaReady = ipa is not null && File.Exists(ipa);
        locations.Children.Add(SettingRow(T("settings.locations.ipa"), ipaReady ? null : T("settings.locations.ipa_none"),
            ipaReady ? Action("progress.reveal_ipa", () => Reveal(ipa!)) : null, ipaReady ? ipa : null));
        locations.Children.Add(SettingRow(T("settings.locations.space"), libraryId is null ? T("settings.locations.not_set") : null,
            libraryId is null ? null : Action("storage.open", OpenStorage, !libraryBusy)));   // 没库时存储总览只有空页，先写「还没设置」，建好库再给按钮
        if (PrivateJobRequest.Warning is { } privateWarning) locations.Children.Add(Muted(privateWarning));   // 私有目录收不紧：照常用，这里说一句（#754）
        body.Children.Add(Card(locations));

        // 密钥（原在游戏库页状态卡）：状态 + 导入
        if (catalog is not null)
            body.Children.Add(Card(SettingRow(T("settings.keys"), catalog.KeysMessage,
                Action("library.import_keys", () => BeginPicker(ChooseKeysAsync), !libraryBusy))));

        body.Children.Add(InstallModeCard());   // 装到 iPhone 的方式（v0.3.0，InstallModePage.cs）

        var aiRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var aiText = new StackPanel { Spacing = 4 };
        aiText.Children.Add(Label(T("environment.ai.title"), 16));
        aiText.Children.Add(Label(aiControlError.Length > 0 ? aiControlError : T("environment.ai.detail")));
        aiRow.Children.Add(aiText);
        var aiToggle = new ToggleSwitch { IsChecked = aiControl, OnContent = "", OffContent = "", VerticalAlignment = VerticalAlignment.Center };
        aiToggle.IsCheckedChanged += (_, _) => { if (aiToggle.IsChecked != aiControl) SetAiControl(aiToggle.IsChecked == true); };
        Grid.SetColumn(aiToggle, 1); aiRow.Children.Add(aiToggle);
        body.Children.Add(Card(aiRow));

        // 出包环境检查：设置页里的一组卡
        var summary = new StackPanel { Spacing = 12 };
        summary.Children.Add(Label(T("environment.title"), 16));
        summary.Children.Add(Muted(T("environment.description")));
        summary.Children.Add(Label(T(summaryKey), 18));
        var check = new Button { Content = T(report is null ? "action.check" : "action.recheck"), IsEnabled = !busy,
            Background = Accent, Foreground = Canvas, Padding = new Thickness(20, 10), CornerRadius = new CornerRadius(8) };
        check.Click += async (_, _) => await CheckAsync();
        summary.Children.Add(check);
        body.Children.Add(new Border { Background = Surface, CornerRadius = new CornerRadius(10),
            Padding = new Thickness(20), Child = summary });

        if (report is not null)
        {
            foreach (var item in report.Checks)
            {
                var row = new StackPanel { Spacing = 6 };
                var advisory = item.Status != "ok" && !item.Blocking;   // 只提示、不挡流程
                var heading = Label(T(advisory ? "environment.status.advisory" : "environment.status." + item.Status) + " · " + item.Name, 16);
                if (advisory) heading.Foreground = Brush.Parse("#FFC857");
                row.Children.Add(heading);
                if (item.Code is not null && !advisory)
                {
                    row.Children.Add(Label(T("errors." + item.Code + ".title")));
                    row.Children.Add(Label(T("errors." + item.Code + ".detail")));
                }
                // Observed names/messages and recovery text remain backend data.
                row.Children.Add(Label(item.Message));
                if (item.HasAction)
                {
                    row.Children.Add(new Expander { Header = T("action.open_help"), Content = Label(item.Action!),
                        HorizontalAlignment = HorizontalAlignment.Stretch });
                }
                var line = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 20 };
                line.Children.Add(row);
                if (item.OfficialUrl is { } url)
                {
                    var official = new Button { Content = T("action.open_official"),
                        Background = Accent, Foreground = Canvas, Padding = new Thickness(16, 10),
                        CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
                    official.Click += async (_, _) => await OpenOfficialAsync(url);
                    Grid.SetColumn(official, 1); line.Children.Add(official);
                }
                body.Children.Add(new Border { Background = Surface, CornerRadius = new CornerRadius(10),
                    Padding = new Thickness(18), BorderBrush = item.Status == "ok" ? Brush.Parse("#3D8565") : Brush.Parse("#8C7344"),
                    BorderThickness = new Thickness(1), Child = line });
            }
        }
        else body.Children.Add(Label(T("environment.no_report")));

        // 运行路径（开发用）放最下面
        engine = new TextBox { Text = paths.Engine, IsEnabled = !busy };
        runtime = new TextBox { Text = paths.Runtime, IsEnabled = !busy };
        shell = new TextBox { Text = paths.Shell, IsEnabled = !busy };
        var settings = new StackPanel { Spacing = 8 };
        settings.Children.Add(Label(T("settings.description")));
        settings.Children.Add(Label(T("settings.engine"))); settings.Children.Add(engine);
        settings.Children.Add(Label(T("settings.runtime"))); settings.Children.Add(runtime);
        settings.Children.Add(Label(T("settings.shell"))); settings.Children.Add(shell);
        settings.Children.Add(Action("action.save_settings", CapturePaths, !busy));
        body.Children.Add(new Expander { Header = T("settings.title"), Content = settings,
            HorizontalAlignment = HorizontalAlignment.Stretch });

        if (diagnostics.Length != 0)
        {
            body.Children.Add(new Expander { Header = T("diagnostics.title"),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Content = new TextBox { Text = diagnostics, IsReadOnly = true, AcceptsReturn = true,
                    TextWrapping = TextWrapping.Wrap, MaxHeight = 260 } });
        }
        // Version: the same number the Mac launcher and the S2Arm on the iPhone show (written into the iPhone app at install).
        var version = Muted("S2Arm " + AppVersion, 12); version.HorizontalAlignment = HorizontalAlignment.Center;
        Avalonia.Automation.AutomationProperties.SetAutomationId(version, "env.version");
        body.Children.Add(version);
    }

    /// <summary>设置页的一行：标题、说明（可空）、右侧控件（可空）</summary>
    private Grid SettingRow(string title, string? detail, Control? right, string? path = null)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16 };
        var left = new StackPanel { Spacing = 4 };
        left.Children.Add(Label(title, 15));
        if (!string.IsNullOrEmpty(path)) left.Children.Add(PathLink(path));   // 路径：存在就做成可点的链接（LibraryPage.cs PathLink）
        if (!string.IsNullOrEmpty(detail)) left.Children.Add(Muted(detail));
        row.Children.Add(left);
        if (right is not null) { right.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(right, 1); row.Children.Add(right); }
        return row;
    }

    /// <summary>资源管理器打开一个文件夹（路径作为一个参数传，不经 shell；文件夹不在就不开）</summary>
    private void OpenFolder(string folder)
    {
        if (!Directory.Exists(folder)) return;
        try { if (OperatingSystem.IsWindows()) Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { folder } })?.Dispose(); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        { diagnostics = T("process.start_failed") + "\n" + error.Message; Render(); }
    }

    private async Task OpenOfficialAsync(Uri url)
    {
        try
        {
            if (await Launcher.LaunchUriAsync(url)) return;
            diagnostics = T("process.start_failed");
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            diagnostics = T("process.start_failed") + "\n" + error.Message;
        }
        Render();
    }

    private async Task CheckAsync()
    {
        if (busy) return;
        CapturePaths(); report = null; diagnostics = "";
        if (EnvironmentProbe.BundleIncomplete(paths)) { summaryKey = "environment.unzip_first"; Render(); return; }
        var job = BeginJob(JobKind.Environment);
        job.Cancellation.CancelAfter(TimeSpan.FromMinutes(2));
        summaryKey = "environment.checking"; Render();
        try
        {
            var output = await EnvironmentProbe.RunAsync(paths, job.Token);
            diagnostics = T("diagnostics.exit_code") + ": " + output.ExitCode + "\n" + output.StandardError;
            report = EnvironmentReport.Parse(output.StandardOutput, output.ExitCode);
            if (report.Error is not null)
            {
                summaryKey = "environment.failed";
                diagnostics += "\n" + report.Error.Code + "\n" + report.Error.Message;
            }
            else summaryKey = report.Ready ? "environment.ready" : "environment.not_ready";
        }
        catch (EnvironmentProtocolException error)
        {
            summaryKey = "protocol.invalid_report"; diagnostics += "\n" + error.Message;
        }
        catch (OperationCanceledException)
        {
            summaryKey = "process.interrupted";
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or ArgumentException or InvalidOperationException)
        {
            summaryKey = "process.start_failed"; diagnostics = error.Message;
        }
        finally
        {
            EndJob(job); Render();
        }
    }
}
