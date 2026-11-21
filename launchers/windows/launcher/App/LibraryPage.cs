// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.VisualTree;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private string page = "library";
    private string libraryFolder = "";
    private string? libraryMoveFrom;
    private string? connectedFolder, libraryId, selectedGame;
    private LibraryCatalog? catalog;
    private string librarySummary = "library.disconnected", libraryDiagnostics = "";
    private bool closingLibrary;
    private Task? libraryOperation;
    private TextBox libraryFolderBox = new();
    private readonly Dictionary<string, Bitmap> covers = new(StringComparer.OrdinalIgnoreCase);
    private readonly string privateRoot = ResolvePrivateRoot();

    private void Navigate(string destination)
    {
        CapturePaths();
        presented = null;   // 清单按钮的落点只算当前这一页（ExportPages.cs RunInstallAction 换页后再记）
        if (page == "library") libraryFolder = libraryFolderBox.Text ?? "";
        messagesOpen = false;   // 顶栏导航离开「消息」页
        sgradeOpen = false;     // 也离开「S 级优化升级」页
        cheatsFor = null;       // 和「金手指」页
        modsFor = null;         // 和「Mod」页
        if (destination == "settings" && page != "settings") settingsFrom = page;   // 设置页左上「返回」回到这里（出包页点「更改」进来就回出包页）
        page = destination;
        if (destination != "library") welcomeHome = false;   // 品牌名带去的欢迎页只管这一次回首页，去了别的页就回到平常
        // 环境检查页每次打开读一次装到 iPhone 的方式和开发者证书（InstallModePage.cs / DevCertPage.cs）
        if (destination == "settings") { _ = RefreshInstallModeAsync(); if (!devCertLoading) _ = RefreshDevCertAsync(); }
        Render();
    }

    /// <summary>
    /// 换库 / 刷新时丢掉封面缓存。不能当场 Dispose：这时窗口里还挂着上一次 Render 建的界面，封面 Image 引用着这些位图；
    /// 一让出界面线程（await 作业）排版就去量已释放的位图，Avalonia 渲染循环里抛 ObjectDisposedException，0.1.7 上整个窗口空掉
    /// （玩家反馈「点连接或创建游戏库闪退」，Windows 实机按原样复现：库里有一款带封面就必崩，事件 1026 堆栈 Bitmap.get_Size ← Image.MeasureOverride）。
    /// 先记下它们和当时的窗口内容，等窗口内容换成新界面（旧界面脱离窗口、不再排版）再释放；窗口关掉时一并释放。
    /// </summary>
    private void ClearCovers()
    {
        if (covers.Count == 0) return;
        retiredCovers.Add((Content, covers.Values.ToList()));
        covers.Clear();
    }

    private readonly List<(object? Content, List<Bitmap> Covers)> retiredCovers = [];

    /// <summary>窗口内容已经不是退役时那份的封面才释放（Render 末尾、窗口关闭时调）</summary>
    private void DisposeRetiredCovers(bool all = false)
    {
        for (var i = retiredCovers.Count - 1; i >= 0; i--)
        {
            if (!all && ReferenceEquals(retiredCovers[i].Content, Content)) continue;
            foreach (var cover in retiredCovers[i].Covers) cover.Dispose();
            retiredCovers.RemoveAt(i);
        }
    }

    private async void CloseLibraryAsync(object? sender, WindowClosingEventArgs args)
    {
        if (!libraryBusy || closeAnyway) return;
        args.Cancel = true;
        if (closingLibrary) return;   // 第一次进来的那份在等，等完它自己再关
        closingLibrary = true;
        CloseLog("关窗口：游戏库作业在跑，先取消、等它收尾再关");
        await WaitJobsEndAsync(JobKind.Library);
        closingLibrary = false;
        Close();
    }

    private Border Card(Control content, int padding = 20) => new()
    {
        Background = Surface, CornerRadius = new CornerRadius(12), Padding = new Thickness(padding), Child = content
    };

    /// <summary>顶部大图：只认这款文件夹里的商店横图（LibraryGame.BannerFile），按 1600 宽解码（铺满整条也不糊）；读不出就 null、退回封面卡片</summary>
    private Bitmap? HeroBanner(LibraryGame game)
    {
        if (connectedFolder is null || game.BannerFile() is not { } path) return null;
        try
        {
            if (new FileInfo(path).Length > 16 * 1024 * 1024) return null;
            // 缓存键另起：没有自带图标的款 cover 也指向 banner.jpg，封面卡片按 240 宽解码的那份不能拿来铺大图
            if (!covers.TryGetValue(path + "#hero", out var image))
            {
                using var file = File.OpenRead(path);
                image = Bitmap.DecodeToWidth(file, 1600);
                covers.Add(path + "#hero", image);
            }
            return image;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    /// <summary>封面 + 已打上 S 级优化的左上角金色 S（同 Mac LauncherView+Library SGradeBadge：只有 S、没有框和底色，叠三层更实、加投影）</summary>
    /// <summary>数据校验不过的说明（作业层原句，六种语言在对照表；同 Mac LauncherView+Home integritySkippedNote）</summary>
    private const string IntegritySkippedNote = "这份游戏文件里有数据和原版对不上（多半是改版 / 整合版，或个别块损坏），已跳过完整性校验照常导入。";

    private Control GameCover(LibraryGame game, int size)
    {
        var cover = WithSGradeProgress(game, WithUpdateHintBadge(game, WithIntegrityBadge(game, GameCoverImage(game, size), size), size), size);
        if (!game.SGrade) return cover;
        var s = Math.Max(20, size / 3.2);
        var badge = new Panel { Width = s, Height = s, Margin = new Thickness(3), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Effect = new DropShadowEffect { Color = Color.FromArgb(115, 0, 0, 0), BlurRadius = s * 0.24, OffsetX = 0, OffsetY = s * 0.04 } };
        for (var k = 0; k < 3; k++) badge.Children.Add(new Image { Source = SGoldImage(), Stretch = Stretch.Uniform });
        Avalonia.Automation.AutomationProperties.SetAutomationId(badge, "card.sgrade");
        return new Panel { Width = size, Height = size, Children = { cover, badge } };
    }

    /// <summary>选中区的黄字说明（同 Mac 状态行下那句）：卡片角标只有「!」，手柄玩家看不到悬停说明</summary>
    private Control? IntegrityLine(LibraryGame game) => game.IntegritySkipped
        ? new TextBlock { Text = "⚠ " + B(IntegritySkippedNote), Foreground = Brush.Parse("#FFD60A"), FontSize = 13, TextWrapping = TextWrapping.Wrap, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Left }
        : null;

    /// <summary>导入时数据校验不过、照常导入的款（11-17）：封面右下角黄色「!」，悬停说明</summary>
    private Control WithIntegrityBadge(LibraryGame game, Control cover, int size)
    {
        if (!game.IntegritySkipped) return cover;
        var d = Math.Max(16, size / 5.0);
        var badge = new Border { Width = d, Height = d, CornerRadius = new CornerRadius(d / 2), Margin = new Thickness(4),
            Background = Brush.Parse("#99000000"), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Child = new TextBlock { Text = "!", FontWeight = FontWeight.Bold, FontSize = d * 0.62, Foreground = Brush.Parse("#FFD60A"),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
        ToolTip.SetTip(badge, B(IntegritySkippedNote));
        Avalonia.Automation.AutomationProperties.SetName(badge, B(IntegritySkippedNote));
        Avalonia.Automation.AutomationProperties.SetAutomationId(badge, "card.integritySkipped");
        return new Panel { Width = size, Height = size, Children = { cover, badge } };
    }

    private Control GameCoverImage(LibraryGame game, int size)
    {
        // Only a backend-provided local cover in this library is considered; never load a remote URL.
        try
        {
            // 只认这款自己文件夹里的封面（LibraryGame.CoverFile：按 catalog 给的文件夹认，英文名文件夹也行，#330）
            if (connectedFolder is not null && game.CoverFile() is { } path && new FileInfo(path).Length <= 16 * 1024 * 1024)
            {
                if (!covers.TryGetValue(path, out var image))
                {
                    using var file = File.OpenRead(path);
                    image = Bitmap.DecodeToWidth(file, 240);
                    covers.Add(path, image);
                }
                return new Image { Source = image, Width = size, Height = size, Stretch = Stretch.UniformToFill };
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { }
        return new Border { Width = size, Height = size, CornerRadius = new CornerRadius(8),
            Background = Brush.Parse("#303035"), Padding = new Thickness(size / 8),
            Child = new Image
            {
                Source = LoadWordmark(),
                Stretch = Stretch.Uniform
            } };
    }

    private Bitmap? wordmarkBitmap;
    private Bitmap LoadWordmark()
    {
        if (wordmarkBitmap is not null) return wordmarkBitmap;
        using var stream = Avalonia.Platform.AssetLoader.Open(new Uri("avares://S2Arm/Assets/Wordmark.png"));
        return wordmarkBitmap = Bitmap.DecodeToWidth(stream, 480);
    }

    /// <summary>顶部选中游戏的主操作（有横图的大图叠加、无横图的封面卡片两分支共用）：只有两件事——更新（做过 iPhone 版才有，ExportFlow.cs）+「导出…」
    /// （0.6.4 改版，维护者 11-21：原先的「推到 iPhone」「导出自签包」「更新这款 = 推」并进导出确认页；出包页只从右键菜单「出包」进，给其它平台用）。</summary>
    private StackPanel HeroActions(LibraryGame hero)
    {
        var heroActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 6, 0, 0) };
        heroActions.Children.Add(LiveSlot(() => UpdateButton(hero)));   // 更新中只换这一格（进度事件）
        var upgrading = SGradeUpgrading(hero);   // 这款在升 S 级优化：按钮上直接写进度、不可点（11-18 维护者）
        var exportEnabled = !PhoneBlockedFor(hero) && !upgrading && hero.LocationState is not ("missing" or "offline");   // 出包 / 手机作业在跑也能去（导出那一单自己排队）
        var exportText = upgrading ? SGradeUpgradingTitle(hero) : T("library.hero.export");
        // 一次只一颗主色：建议更新时更新是主色、导出退成次按钮
        var export = UpdateStateOf(hero) == ExportChoice.Update.Suggested
            ? Action("library.hero.export", () => OpenExport(hero), exportEnabled)
            : Primary(exportText, () => OpenExport(hero), exportEnabled);
        if (upgrading) export.Content = exportText;
        export.VerticalAlignment = VerticalAlignment.Center;
        AutomationId(export, "library.hero.export");
        heroActions.Children.Add(export);
        return heroActions;
    }

    private void RenderLibrary(StackPanel body)
    {
        body.Children.Add(Label(T("library.title"), 23));
        if (catalog is null) body.Children.Add(Label(T("library.description")));   // 「连接游戏库…」只在还没连上时说
        // 游戏库放在了某个 S2Arm 程序文件夹里（多半是旧压缩包版解压出来的那个）：换装安装版后清理旧文件夹、或更新换壳，都会连游戏库一起删（v0.3.0 安装程序）
        if (ProgramFolderAround(connectedFolder) is { } program)
        {
            var warn = new StackPanel { Spacing = 10 };
            warn.Children.Add(Label(T("library.inside_program").Replace("{0}", program)));
            warn.Children.Add(Action("library.inside_program.move", () => BeginPicker(ChangeLibraryAsync), !libraryBusy && !PackBusy));
            body.Children.Add(new Border { Background = Brush.Parse("#2A1F14"), CornerRadius = new CornerRadius(12), Padding = new Thickness(16, 12), Child = warn });
        }

        // In-progress capsule: shown when a pack is running and the session is hidden
        if (packRunning && sessionHidden)
        {
            var elapsed = (DateTime.UtcNow - packStarted).TotalSeconds;
            var estimate = packTrack.Estimate(Clock);
            var fraction = OverallFraction(estimate, packTrack.Plan, packTrack.Overall);
            var capsuleBar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16 };
            var left = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            left.Children.Add(Muted(T("progress.running") + " · " + (packGame?.Name ?? ""), 13));
            left.Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Value = fraction, Height = 4, Foreground = Accent });
            capsuleBar.Children.Add(left);
            var back = Primary(T("export.pill.running"), () => { sessionHidden = false; Navigate("progress"); });
            back.Padding = new Thickness(14, 8); back.CornerRadius = new CornerRadius(16);
            Grid.SetColumn(back, 1); capsuleBar.Children.Add(back);
            body.Children.Add(new Border { Background = Brush.Parse("#1D1D20"), CornerRadius = new CornerRadius(12),
                Padding = new Thickness(16, 12), Child = capsuleBar });
        }

        EnsureUpdateHints();
        var games = catalog?.Games.Where(g => !g.Hidden).ToArray() ?? [];
        var hero = ConsoleSelected ? null : games.FirstOrDefault(g => g.Id == selectedGame) ?? games.FirstOrDefault();
        if (ConsoleSelected) body.Children.Add(ConsolePanel());   // 选中首位「S2Arm」：大图区换成 iPhone 总控台
        if (hero is not null && HeroBanner(hero) is { } heroBanner)
        {
            // 顶部大图（11-14 维护者：「换成用 banner」）：商店横图 1920×1080 铺满整条，标题压在底部渐变上；没有横图的款退回下面的封面卡片
            var art = new Grid { Height = 280 };
            art.Children.Add(new Image { Source = heroBanner, Stretch = Stretch.UniformToFill, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center });
            art.Children.Add(new Border { Background = new LinearGradientBrush { StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.Parse("#000E0E10"), 0.35), new GradientStop(Color.Parse("#E60E0E10"), 1) } } });
            var overlay = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(28, 0, 28, 22) };
            overlay.Children.Add(Muted(T(selectedGame is null ? "library.title" : "library.selected"), 14));
            overlay.Children.Add(Label(hero.Name, 32));
            overlay.Children.Add(Muted(T("library.version") + " · " + hero.Version, 14));
            if (IntegrityLine(hero) is { } heroNote) overlay.Children.Add(heroNote);
            if (SGradeLine(hero) is { } sgNote) overlay.Children.Add(sgNote);
            if (UpdateReasonLines(hero) is { } heroHint) overlay.Children.Add(heroHint);
            overlay.Children.Add(HeroActions(hero));   // 有横图时按钮也叠在底部渐变上（v0.4.5 修：说明写着「常驻」，之前只画了大图）
            if (UpdateOutcomeLines(hero) is { } heroDone) overlay.Children.Add(heroDone);
            art.Children.Add(overlay);
            body.Children.Add(new Border { CornerRadius = new CornerRadius(16), ClipToBounds = true, Child = art });
        }
        else if (hero is not null)
        {
            var banner = new Grid { ColumnDefinitions = new ColumnDefinitions("100,*"), ColumnSpacing = 24 };
            banner.Children.Add(GameCover(hero, 100));
            var title = new StackPanel { Spacing = 8 };
            title.Children.Add(Label(T(selectedGame is null ? "library.title" : "library.selected")));
            title.Children.Add(Label(hero.Name, 28));
            title.Children.Add(Label(T("library.version") + " · " + hero.Version));
            if (IntegrityLine(hero) is { } heroNote) title.Children.Add(heroNote);
            if (SGradeLine(hero) is { } sgNote) title.Children.Add(sgNote);
            if (UpdateReasonLines(hero) is { } heroHint) title.Children.Add(heroHint);
            title.Children.Add(HeroActions(hero));
            if (UpdateOutcomeLines(hero) is { } heroDone) title.Children.Add(heroDone);
            Grid.SetColumn(title, 1); banner.Children.Add(title); body.Children.Add(Card(banner, 20));
        }

        var connection = new StackPanel { Spacing = 10 };
        connection.Children.Add(Label(T("library.folder")));
        libraryFolderBox = new TextBox { Text = libraryFolder, IsEnabled = !libraryBusy };
        Avalonia.Automation.AutomationProperties.SetAutomationId(libraryFolderBox, "library.folder");
        connection.Children.Add(libraryFolderBox);
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
        void AddButton(string key, Action action, bool enabled = true)
        {
            var button = Action(key, action, enabled && !libraryBusy); button.Margin = new Thickness(0, 0, 10, 8);
            buttons.Children.Add(button);
        }
        AddButton("library.choose_folder", () => BeginPicker(ChooseLibraryAsync));
        AddButton("library.connect", () => ConnectTypedFolder(libraryFolderBox.Text));
        AddButton("library.refresh", () => BeginLibrary("catalog"), libraryId is not null);
        connection.Children.Add(buttons);
        connection.Children.Add(Label(T("library.source_hint")));
        if (catalog is null) body.Children.Add(Card(connection));   // 连上以后游戏库位置只在「设置 → 存放位置」（入口整理）

        var status = new StackPanel { Spacing = 8 };
        status.Children.Add(Label(T(librarySummary), 18));
        // 失败时原因直接写在这里（第一行就是作业 / 输入校验给的人话），不用再展开「本次操作与处理建议」才看得到
        if (librarySummary is "library.failed" or "library.invalid_result" && libraryDiagnostics.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() is { Length: > 0 } why)
            status.Children.Add(Muted(why, 14));
        if (LibraryDrivePicker() is { } drives) status.Children.Add(drives);   // 游戏库盘格式不对：列出能放的盘，点了就建（v0.3.1）
        if (libraryBusy) status.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4 });
        // 状态卡只在有事时出现：还没连上 / 正在操作 / 没做成。原先卡里的密钥、导入按钮挪走了：
        //   导入游戏统一走顶栏「添加游戏」，密钥与磁盘空间在「设置」（入口整理）
        if (catalog is null || libraryBusy || librarySummary is "library.failed" or "library.invalid_result" or "library.interrupted")
            body.Children.Add(Card(status));

        if (catalog is not null && games.Length > 0)   // 「S 级优化升级」入口（同 Mac 游戏库标题行，v0.4.0）
            body.Children.Add(new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, Children = { SGradeUpgradeEntry() } });
        if (catalog is not null && phoneOverview is not null) body.Children.Add(ConsoleRow());   // 首位固定「S2Arm」（0.6.0 开关后面），不算进游戏数
        foreach (var game in games)
        {
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("72,*,Auto"), ColumnSpacing = 18 };
            line.Children.Add(GameCover(game, 72));
            var detail = new StackPanel { Spacing = 5 };
            detail.Children.Add(Label(game.Name, 18));
            detail.Children.Add(Label(T("library.version") + " · " + game.Version));
            if (game.Missing.Count > 0)
                detail.Children.Add(Label(T("library.requirements") + " · " + string.Join(" / ", game.Missing)));
            // iPhone / Mac dual status line
            detail.Children.Add(GameStatusLine(game));
            detail.Children.Add(GameSizesLine(game.Sizes));   // 这款各部分大小（游戏库结构 v3「查」，StoragePage.cs）
            // 这款放在哪：只在不在默认存放位置时写（游戏库本身的位置在「设置 → 存放位置」）
            if (game.Location is { State: "ok", IsDefault: false } where)
                detail.Children.Add(Muted(T("library.location.at").Replace("{0}", where.Folder.Length > 0 ? where.Folder : where.Path), 12));
            Grid.SetColumn(detail, 1); line.Children.Add(detail);
            // 卡片上的按钮只有「导出…」（同大卡；0.6.4 改版拆掉「推到 iPhone」，原先没出过包的款这里写「选择这款游戏」却打开出包页）；游戏文件找不到 → 重新指定 / 移除
            var missing = game.LocationState == "missing";
            var select = missing
                ? Action("library.select", () => _ = MissingAsync(game), !BusyFor(game))
                : Action("library.hero.export", () => OpenExport(game), !PhoneBlockedFor(game) && game.LocationState != "offline" && !SGradeUpgrading(game));   // 出包 / 手机作业在跑也能去（排队）；升 S 级优化中不可点
            if (SGradeUpgrading(game)) select.Content = SGradeUpgradingTitle(game);
            select.VerticalAlignment = VerticalAlignment.Center;
            // secondary: show past result if one exists and game is not currently running
            if (finishedPacks.TryGetValue(game.Id, out _) && !(packRunning && packGame?.Id == game.Id))
            {
                var actionCol = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
                actionCol.Children.Add(select);
                var results = Action("library.hero.results", () =>
                { libraryFolder = libraryFolderBox.Text ?? ""; selectedGame = game.Id; Navigate("progress"); }, !BusyFor(game));
                actionCol.Children.Add(results);
                Grid.SetColumn(actionCol, 2); line.Children.Add(actionCol);
            }
            else
            {
                Grid.SetColumn(select, 2); line.Children.Add(select);
            }
            var card = Card(line, 12);
            card.ContextMenu = CardMenu(game);
            // 点卡片（按钮以外）= 选中这款，顶部大卡换成它（更新按钮在那里；0.6.4 前列表卡只能点按钮进出包页）；找不到游戏文件时弹「重新指定文件夹 / 从游戏库移除」
            if (!ConsoleSelected && game.Id == hero?.Id) { card.BorderBrush = Accent; card.BorderThickness = new Thickness(1.5); }
            card.Tapped += (_, e) =>
            {
                if ((e.Source as Visual)?.FindAncestorOfType<Button>(includeSelf: true) is not null) return;
                if (game.LocationState == "missing") _ = MissingAsync(game); else SelectGame(game);
            };
            AutomationId(card, "library.card." + game.Id);
            body.Children.Add(card);
        }
        if (catalog is not null && games.Length == 0) body.Children.Add(Label(T("library.empty"), 18));
        if (libraryDiagnostics.Length > 0)
            body.Children.Add(new Expander { Header = T("library.job_diagnostics"), IsExpanded = librarySummary is "library.failed" or "library.invalid_result" or "library.interrupted",
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Content = new TextBox { Text = libraryDiagnostics, IsReadOnly = true, AcceptsReturn = true,
                    TextWrapping = TextWrapping.Wrap, MaxHeight = 240 } });
    }

    /// <summary>iPhone / Mac dual status line for a game card — mirrors Mac statusLine(game).</summary>
    private Control GameStatusLine(LibraryGame game)
    {
        string text; string color;
        // 免费签名还剩几天（作业层只在那台手机现在用的就是启动器免费签的那份时给；玩家关了「免费签名到期提醒」→ null，只写「已推到 iPhone」）
        var freeDays = FreeSignReminder.On(privateRoot) ? game.FreeSignDaysLeft(DateTimeOffset.UtcNow) : null;
        // Running or queued
        if (packRunning && packGame?.Id == game.Id)
        {
            text = T("s2arm.job.running"); color = "#FFC857";
        }
        // 存放位置（游戏库结构 v3）：移动硬盘没插 → 灰色「未连接」，插回来重读游戏库就恢复；文件夹没了 → 红字，点卡片重新指定或移除
        // 未连接给具体路径（同出包页下拉框）：卷名会重名（系统盘都叫「系统盘」），看不出是哪个位置没连上
        else if (game.LocationState == "offline")
        {
            text = T("library.location.offline").Replace("{0}", game.Location!.Path.Length > 0 ? game.Location.Path : game.Location.Volume); color = "#4A4A50";
        }
        else if (game.LocationState == "missing")
        {
            text = T("library.location.missing"); color = "#E05C5C";
        }
        else
        {
            var parts = new List<string>();
            if (game.IphoneReady)
            {
                if (game.IphoneInstalledAt is not null)
                {
                    if (freeDays is { } daysLeft)
                        parts.Add(daysLeft == 0 ? T("library.status.expired") : T("library.status.installed").Replace("{0}", daysLeft.ToString()));
                    else parts.Add(T("library.status.installedPaid"));
                }
                else parts.Add(T("library.status.iphone"));
            }
            if (parts.Count == 0)
            {
                text = T("s2arm.library.notPrepared"); color = "#4A4A50";
                goto render;
            }
            text = string.Join(" · ", parts);
            color = game.IphoneInstalledAt is not null && freeDays == 0 ? "#E05C5C" : "#52C87A";
        }
        render:
        var dot = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4),
            Background = Brush.Parse(color), Margin = new Thickness(0, 3, 6, 0), VerticalAlignment = VerticalAlignment.Top };
        var lbl = new TextBlock { Text = text, FontSize = 12, Foreground = Brush.Parse(color), TextWrapping = TextWrapping.Wrap };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(dot); row.Children.Add(lbl);
        if (game.IphoneReady && game.IphoneInstalledAt is not null && freeDays is not null && !(packRunning && packGame?.Id == game.Id) && game.LocationState is not ("offline" or "missing"))
        {
            // 「×」= 不再提醒（关掉设置里的「免费签名到期提醒」，重新打开恢复；维护者 11-20：玩家换成自签后提醒挂着取消不了）
            var dismiss = new Button { Content = "✕", FontSize = 10, Padding = new Thickness(5, 0), Margin = new Thickness(6, 0, 0, 0), MinHeight = 0,
                Background = Brushes.Transparent, Foreground = Brush.Parse("#8C8A85"), VerticalAlignment = VerticalAlignment.Top };
            ToolTip.SetTip(dismiss, T("library.banner.dismiss"));
            Avalonia.Automation.AutomationProperties.SetAutomationId(dismiss, "library.renew.dismiss");
            dismiss.Click += (_, e) => { e.Handled = true; SetFreeSignReminder(false); };
            row.Children.Add(dismiss);
        }
        return row;
    }


    /// <summary>游戏卡片右键菜单（游戏库结构 v3，照 Mac cardMenu；Windows 只出 iPhone 包，没有开始游戏 / 启动设置）：
    /// 出包、在资源管理器中显示、移动到其他位置、清除缓存、从 iPhone 删除这款、删除这款游戏（delete 作业：删游戏文件夹与出包产物，存档和原件保留，同 Mac）。
    /// 位置未连接 / 找不到时出包、移动、清缓存不可用。</summary>
    private ContextMenu CardMenu(LibraryGame game)
    {
        var idle = !BusyFor(game);
        var menu = new ContextMenu();
        void Add(string text, string id, Action action, bool enabled)
        {
            var item = new MenuItem { Header = text, IsEnabled = enabled };
            item.Click += (_, _) => action();
            AutomationId(item, "library.card." + id);
            menu.Items.Add(item);
        }
        Add(T("nav.build"), "export", () => { libraryFolder = libraryFolderBox.Text ?? ""; selectedGame = game.Id; OpenBuild(); }, idle && game.Reachable);
        Add(T("cheats.page.menu"), "cheats", () => OpenCheats(game), idle);
        Add(T("mods.page.menu"), "mods", () => OpenMods(game), idle);   // 资源替换 mod：看 / 导入 / 删除（ModsPage.cs，同 Mac 启动设置里的「资源 Mod」）   // 金手指：看 / 导入（CheatsPage.cs，同 Mac 启动设置里的金手指）
        menu.Items.Add(new Separator());
        Add(T("library.menu.revealWindows"), "reveal", () => RevealGame(game), (game.Location?.Path ?? "").Length > 0 && game.LocationState != "offline");
        Add(T("library.menu.move"), "move", () => BeginPicker(() => MoveGameAsync(game)), idle && game.Reachable && game.LocationState != "none");
        Add(T("library.menu.clearCache"), "clearCache", () => BeginGameJob("clean", game, new() { ["kind"] = "cache" }), idle && game.Reachable);
        menu.Items.Add(new Separator());
        Add(T("install.remove_game"), "remove", () => { libraryFolder = libraryFolderBox.Text ?? ""; selectedGame = game.Id; Navigate("install"); _ = ConfirmRemoveAsync(game); },
            !libraryBusy && !PhoneQueued(game.Id));
        Add(T("game.diag"), "diag", () => _ = UploadDiagnosticsAsync(game.Id, null, () => ""), idle);   // 同 Mac「更多 → 上传给开发者」；上传没成在弹窗里退回导出
        Add(T("game.delete"), "delete", () => _ = ConfirmDeleteAsync(game), idle);
        return menu;
    }

    /// <summary>在资源管理器中显示这款的文件夹（选中它）；还没有文件夹（找不到 / 没出过包）就打开所在的存放位置。</summary>
    private void RevealGame(LibraryGame game)
    {
        if (!ShowGameFolder(game)) { librarySummary = "library.failed"; libraryDiagnostics = T("reveal.folder_missing"); Render(); }
    }

    /// <summary>出包完成页 / 装机页的「打开游戏文件夹」：找不到时在按钮下方提示（revealProblem），不打开空窗口</summary>
    private void OpenGameFolder(LibraryGame game)
    {
        revealProblem = ShowGameFolder(game) ? "" : T("reveal.folder_missing");
        Render();
    }

    /// <summary>在资源管理器里选中这款游戏的文件夹（catalog 给的 location.folder：按索引解析、可能在玩家另选的存放位置，不按游戏号拼）。
    /// 文件夹不在时打开它所在的存放位置；两个都不在 → false（调用方提示）</summary>
    private bool ShowGameFolder(LibraryGame game)
    {
        var folder = game.Location?.Folder ?? "";
        var select = folder.Length > 0 && Directory.Exists(folder);
        var target = select ? folder : game.Location?.Path ?? "";
        // 路径来自后端目录：只认存在的绝对路径；Windows 路径不会带引号，带了就不拼进命令行
        if (target.Length == 0 || !Path.IsPathFullyQualified(target) || target.Contains('"') || !Directory.Exists(target)) return false;
        try
        {
            using var process = Process.Start(new ProcessStartInfo("explorer.exe", select ? "/select,\"" + target + "\"" : "\"" + target + "\"") { UseShellExecute = false });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        { librarySummary = "library.failed"; libraryDiagnostics = T("process.start_failed") + " " + error.Message; Render(); }
        return true;
    }

    /// <summary>界面上显示的文件夹路径：存在就做成链接，点一下在资源管理器里打开（文件则选中它），玩家不用对着路径复制；不在（外接盘没插）只显示文字。
    /// 同 Mac NXLauncher PathLink</summary>
    private Control PathLink(string path, double size = 12)
    {
        var isDir = path.Length > 0 && Path.IsPathFullyQualified(path) && !path.Contains('"') && Directory.Exists(path);
        var isFile = !isDir && path.Length > 0 && Path.IsPathFullyQualified(path) && !path.Contains('"') && File.Exists(path);
        if (!isDir && !isFile) return Muted(path, size);
        var text = new TextBlock { Text = path, FontSize = size, TextWrapping = TextWrapping.Wrap, Foreground = Brush.Parse("#A8A6A1") };
        var link = new Button { Content = text, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand), HorizontalAlignment = HorizontalAlignment.Left };
        ToolTip.SetTip(link, T("path.open"));
        link.PointerEntered += (_, _) => { text.TextDecorations = TextDecorations.Underline; text.Foreground = Ink; };
        link.PointerExited += (_, _) => { text.TextDecorations = null; text.Foreground = Brush.Parse("#A8A6A1"); };
        link.Click += (_, _) =>
        {
            if (!OperatingSystem.IsWindows()) return;
            try { using var process = Process.Start(new ProcessStartInfo("explorer.exe", isDir ? "\"" + path + "\"" : "/select,\"" + path + "\"") { UseShellExecute = false }); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or IOException) { }
        };
        return link;
    }

    private async Task MoveGameAsync(LibraryGame game)
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = T("library.menu.move") });
        if (folders.Count == 0) return;
        await RunGameJobAsync("moveGame", game, new() { ["location"] = LocalPath(folders[0]) });
    }

    private async Task RelinkGameAsync(LibraryGame game)
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = T("library.missing.pick") });
        if (folders.Count == 0) return;
        await RunGameJobAsync("relinkGame", game, new() { ["folder"] = LocalPath(folders[0]) });
    }

    private bool deleteOpen;

    /// <summary>「删除这款游戏」确认（同 Mac 的 game.delete 弹窗）：确认后跑 delete 作业。</summary>
    /// <summary>导出诊断包（diagnostics 作业，同 Mac / 控制口 /diagnostics export）：「上传给开发者」没成时退回这里（DiagUpload.cs），玩家选保存位置，作业层脱敏打包。</summary>
    private async Task ExportDiagnosticsAsync()
    {
        if (connectedFolder is null || libraryId is null || libraryBusy) return;
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { Title = T("diag.upload.export"), SuggestedFileName = $"S2Arm-{T("diag.fileWord")}-{DateTime.Now:MMdd-HHmm}.zip", DefaultExtension = "zip" });
        if (file?.TryGetLocalPath() is not { } output) return;
        var front = BeginJob(JobKind.Library); librarySummary = "library.working"; Render();
        try
        {
            var job = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder, libraryId, "diagnostics", [output], front.Token, jobId: front.Next());
            DisplayJob(job);
            librarySummary = job.Report.Succeeded ? "library.completed" : "library.failed";
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception)
        { librarySummary = "library.failed"; libraryDiagnostics += "\n" + error.Message; }
        finally { EndJob(front); Render(); }
    }

    private async Task ConfirmDeleteAsync(LibraryGame game)
    {
        if (deleteOpen || BusyFor(game)) return;
        deleteOpen = true;
        var confirmed = false;
        try
        {
            var dialog = new Window
            {
                Title = T("game.delete.title").Replace("{0}", game.Name), Width = 460, SizeToContent = SizeToContent.Height,
                CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Background = Canvas, Foreground = Ink,
                FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope")
            };
            var body = new StackPanel { Spacing = 16, Margin = new Thickness(28) };
            body.Children.Add(Label(T("game.delete.title").Replace("{0}", game.Name), 20));
            body.Children.Add(Muted(T("game.delete.body"), 14));
            if (game.OnPhone) body.Children.Add(Muted(T("game.delete.onPhone"), 14));   // 下次往这台手机装游戏时，手机上的这款会打不开（同 Mac）
            var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            var cancel = new Button { Content = T("action.cancel"), Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(8), Margin = new Thickness(12, 0, 0, 0),
                Background = Brush.Parse("#29292D"), Foreground = Ink };
            cancel.Click += (_, _) => dialog.Close();
            AutomationId(cancel, "library.delete.cancel");
            var delete = new Button { Content = T("game.delete.confirm"), Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(8), Margin = new Thickness(12, 0, 0, 0),
                Background = Brush.Parse("#C0392B"), Foreground = Ink };
            delete.Click += (_, _) => { confirmed = true; dialog.Close(); };
            AutomationId(delete, "library.delete.confirm");
            buttons.Children.Add(cancel); buttons.Children.Add(delete);
            body.Children.Add(buttons);
            dialog.Content = body;
            await dialog.ShowDialog(this);
        }
        finally { deleteOpen = false; }
        if (confirmed) BeginGameJob("delete", game);
    }

    private bool missingOpen;

    /// <summary>「找不到游戏文件」（照 Mac missingFor 弹窗）：重新指定文件夹… / 从游戏库移除（磁盘上的文件不动）/ 取消。</summary>
    private async Task MissingAsync(LibraryGame game)
    {
        if (missingOpen || BusyFor(game)) return;
        missingOpen = true;
        string? answer = null;
        try
        {
            var dialog = new Window
            {
                Title = T("library.missing.title").Replace("{0}", game.Name), Width = 460, SizeToContent = SizeToContent.Height,
                CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Background = Canvas, Foreground = Ink,
                FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope")
            };
            var body = new StackPanel { Spacing = 16, Margin = new Thickness(28) };
            body.Children.Add(Label(T("library.missing.title").Replace("{0}", game.Name), 20));
            body.Children.Add(Muted(T("library.missing.body"), 14));
            var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            void Add(string text, string? result, bool primary, string id)
            {
                var button = new Button { Content = text, Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(8), Margin = new Thickness(12, 0, 0, 0),
                    Background = primary ? Accent : Brush.Parse("#29292D"), Foreground = primary ? Canvas : Ink };
                button.Click += (_, _) => { answer = result; dialog.Close(); };
                AutomationId(button, "library.missing." + id);
                buttons.Children.Add(button);
            }
            Add(T("action.cancel"), null, false, "cancel");
            Add(T("library.missing.forget"), "forget", false, "forget");
            Add(T("library.missing.relink"), "relink", true, "relink");
            body.Children.Add(buttons);
            dialog.Content = body;
            await dialog.ShowDialog(this);
        }
        finally { missingOpen = false; }
        if (answer == "relink") BeginPicker(() => RelinkGameAsync(game));
        else if (answer == "forget") BeginGameJob("forgetGame", game);
    }

    private void BeginGameJob(string operation, LibraryGame game, Dictionary<string, object?>? extra = null)
    {
        if (libraryBusy) return;
        libraryFolder = libraryFolderBox.Text ?? "";
        libraryOperation = RunGameJobAsync(operation, game, extra);
    }

    /// <summary>一款游戏的游戏库作业（游戏库结构 v3：moveGame / relinkGame / forgetGame / clean kind=cache / delete）：忙碌、结果与诊断同 RunLibraryAsync，成功后重读游戏库。</summary>
    private async Task RunGameJobAsync(string operation, LibraryGame game, Dictionary<string, object?>? extra = null)
    {
        if (BusyFor(game) || connectedFolder is null || libraryId is null) return;
        var front = BeginJob(JobKind.Library, game.Id); librarySummary = "library.working"; libraryDiagnostics = ""; Render();
        var succeeded = false;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest(operation, game.Id, extra), null, front.Token, front.Next());
            DisplayJob(job);
            succeeded = job.Report.Succeeded;
            librarySummary = succeeded ? "library.completed" : "library.failed";
        }
        catch (LibraryProtocolException error)
        { librarySummary = "library.invalid_result"; libraryDiagnostics += "\n" + error.Message; }
        catch (OperationCanceledException)
        { librarySummary = "library.interrupted"; }
        catch (Exception error)
        {
            // 游戏库作业由玩家输入驱动（目录填什么都有可能：末尾反斜杠、不存在、不可写、非法字符、在启动器自己的目录里）：
            //   任何异常都报成「操作未完成」并带原因，不让它逃出去（玩家反馈：点「连接或创建游戏库」闪退）
            librarySummary = "library.failed"; libraryDiagnostics += "\n" + error.GetType().Name + ": " + error.Message;
            LauncherCrash.Log(error, "library job");
        }
        finally
        { EndJob(front); Render(); }
        if (!succeeded || closingLibrary) return;
        if ((operation == "forgetGame" || operation == "delete") && selectedGame == game.Id) selectedGame = null;
        locationsFor = null;   // 位置表的剩余空间 / 这款的位置变了：出包页下次重读
        await RunLibraryAsync("catalog", null);
    }


    private void BeginPicker(Func<Task> picker)
    {
        if (libraryBusy) return;
        libraryFolder = libraryFolderBox.Text ?? "";
        libraryOperation = GuardPickerAsync(picker);
    }

    private async Task GuardPickerAsync(Func<Task> picker)
    {
        try { await picker(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        { librarySummary = "library.failed"; libraryDiagnostics = error.Message; Render(); }
    }

    // 系统自动生成的文件（Windows 资源管理器 desktop.ini / Thumbs.db、从 Mac 拷来的 .DS_Store）：判空文件夹时不算数（同作业层 layout.OS_JUNK）
    private static readonly HashSet<string> OsJunk = new(StringComparer.OrdinalIgnoreCase) { ".DS_Store", "desktop.ini", "Thumbs.db" };
    private static bool IsOsJunk(string name) => OsJunk.Contains(name) || name.StartsWith("._", StringComparison.Ordinal);   // ._ 开头：访达往非 APFS 盘拷东西留下的附属文件

    private static string LocalPath(IStorageItem item) => item.Path.IsFile ? Path.GetFullPath(item.Path.LocalPath)
        : throw new IOException("The selected item does not have a local filesystem path.");

    private async Task ChooseLibraryAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = T("library.choose_folder") });
        if (folders.Count == 0) return;
        libraryFolder = LocalPath(folders[0]); Render();
    }

    private string LibraryPreference => LibraryPaths.PreferenceFile(privateRoot);

    // 旧默认库（私有目录下的 DefaultLibrary）被作业层同盘改名到 %USERPROFILE%\S2Arm 后，设置里的旧路径按搬库标记换成新位置（游戏库结构 P3）
    private string SavedLibrary() => LibraryPaths.SavedLibrary(privateRoot);

    /// <summary>游戏库所在路径往上，最近的一个 S2Arm 程序文件夹（有 S2Arm.exe 和 Engine\）；没有为 null</summary>
    internal static string? ProgramFolderAround(string? library)
    {
        if (string.IsNullOrEmpty(library)) return null;
        try
        {
            for (var d = new DirectoryInfo(Path.GetFullPath(library)); d is not null; d = d.Parent)
                if (File.Exists(Path.Combine(d.FullName, "S2Arm.exe")) && Directory.Exists(Path.Combine(d.FullName, "Engine")))
                    return Path.TrimEndingDirectorySeparator(d.FullName);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { }
        return null;
    }

    private async Task ChangeLibraryAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = T("library.choose_folder") });
        if (folders.Count == 0) return;
        var folder = LocalPath(folders[0]);
        // 有游戏、选的是空文件夹才问；已有游戏库或含旧产物的文件夹由作业层直接打开 / 认领
        libraryMoveFrom = null;
        if (connectedFolder is not null && catalog is { Games.Count: > 0 } && !Directory.EnumerateFileSystemEntries(folder).Any(e => !IsOsJunk(Path.GetFileName(e))))
        {
            var choice = await AskMoveLibraryAsync();
            if (choice is null) return;
            if (choice.Value) libraryMoveFrom = connectedFolder;
        }
        ConnectLibrary(folder);
    }

    /// <summary>true = 搬过去，false = 新建空游戏库，null = 取消。</summary>
    private async Task<bool?> AskMoveLibraryAsync()
    {
        var dialog = new Window
        {
            Title = T("library.move_title"), Width = 460, SizeToContent = SizeToContent.Height,
            CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Canvas, Foreground = Ink,
            FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope")
        };
        bool? answer = null;
        var body = new StackPanel { Spacing = 16, Margin = new Thickness(28) };
        body.Children.Add(Label(T("library.move_title"), 20));
        body.Children.Add(Muted(T("library.move_body"), 14));
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        void Add(string text, bool? result, bool primary)
        {
            var button = new Button { Content = text, Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(8), Margin = new Thickness(12, 0, 0, 0),
                Background = primary ? Accent : Brush.Parse("#29292D"), Foreground = primary ? Canvas : Ink };
            button.Click += (_, _) => { answer = result; dialog.Close(); };
            buttons.Children.Add(button);
        }
        Add(T("action.cancel"), null, false);
        Add(T("library.move_empty"), false, false);
        Add(T("library.move_confirm"), true, true);
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        return answer;
    }

    /// <summary>「连接或创建游戏库」：输入框里的路径先规范（LibraryFolderInput），再走和「选择游戏库目录」同一条会记住位置的路径。
    /// 原先这个按钮走 BeginLibrary("setup")，连上了却不写设置，重开启动器又回到缺省库（玩家反馈「游戏库位置改不了」）。</summary>
    private void ConnectTypedFolder(string? input)
    {
        if (libraryBusy) return;
        var r = LibraryFolderInput.Normalize(input);
        if (r.Folder is null)
        {
            libraryFolder = input ?? ""; librarySummary = "library.failed"; libraryDiagnostics = T(r.ErrorKey!); Render();
            return;
        }
        libraryMoveFrom = null;
        ConnectLibrary(r.Folder);
    }

    /// <summary>换到新位置：连上后记下来，下次启动还用它。路径同样过一遍规范（选目录 / 控制口来的也一样）。</summary>
    private void ConnectLibrary(string folder)
    {
        var r = LibraryFolderInput.Normalize(folder);
        if (r.Folder is null) { librarySummary = "library.failed"; libraryDiagnostics = T(r.ErrorKey!); Render(); return; }
        folder = r.Folder;
        var previous = connectedFolder;
        connectedFolder = null; libraryId = null;
        libraryFolder = folder;
        libraryOperation = SwitchLibraryAsync(folder, previous);
    }

    private async Task SwitchLibraryAsync(string folder, string? previous)
    {
        await EnsureLibraryAsync(folder, () => { });
        // 换不过去（D-3P26：选在启动器自己的文件夹里，作业层正确拒绝）：原先旧库也一并断开、设置页却写着新路径，玩家以为改好了，
        //   重开又是原来的。现在连回原来那个库，失败原因留着（设置页游戏库一行下面常驻，换成功才清）
        if (connectedFolder is null && previous is not null && !SameFolder(previous, folder))
        {
            var why = libraryFailure;
            libraryFolder = previous;
            await EnsureLibraryAsync(previous, () => { });
            libraryFailure = why; importError = why; Render();
            return;
        }
        if (connectedFolder is null) return;
        try { PrivateJobRequest.EnsurePrivateRoot(privateRoot); File.WriteAllText(LibraryPreference, folder); }
        catch (UnauthorizedAccessException error) { importError = NoWrite(error, connectedFolder ?? libraryFolder); Render(); }
        catch (IOException error) { importError = error.Message; Render(); }
    }

    /// <summary>设置页「导入密钥」（游戏原件统一走顶栏「添加游戏」）</summary>
    private async Task ChooseKeysAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions {
            Title = T("library.choose_keys"), AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType(T("library.import_keys")) { Patterns = ["prod.keys", "*.keys"] }] });
        if (files.Count == 0) return;
        await RunLibraryAsync("keys", files.Select(LocalPath).ToArray());
    }

    private void BeginLibrary(string operation)
    {
        if (libraryBusy) return;
        libraryFolder = libraryFolderBox.Text ?? "";
        libraryOperation = RunLibraryAsync(operation, null);
    }

    /// <summary>游戏库作业在跑时又要刷新（出包 / 装机完、换页）：记一笔，这一轮结束后补刷一次（剃刀 W8：原先直接丢掉，刚出好的状态要等下一次别的刷新）。</summary>
    private bool catalogAgain;

    /// <summary>刷新游戏库：作业在跑就只记一笔（那一轮完了补刷），不在跑才起并记下这次作业（关库时要等它，不能被一个立刻返回的任务盖掉）。</summary>
    private Task RefreshLibraryAsync()
    {
        if (libraryBusy) { catalogAgain = true; return Task.CompletedTask; }
        return libraryOperation = RunLibraryAsync("catalog", null);
    }

    private async Task RunLibraryAsync(string operation, string[]? selectedPaths)
    {
        if (libraryBusy) { if (operation == "catalog") catalogAgain = true; return; }
        // 作业一律发给已连上的库（connectedFolder）；输入框里的路径只给「连接」按钮用（ConnectTypedFolder）。原先这里拿输入框草稿和已连的库比、
        //   不一样就断开：输入框只在游戏库页重建，别的页上读到的是空框，导入密钥 / 一键出包后游戏库被误断开（社区贡献者补丁 #6）
        if (operation != "setup" && (connectedFolder is null || libraryId is null)) return;
        var front = BeginJob(JobKind.Library); librarySummary = operation == "catalog" ? "library.loading" : "library.working";
        libraryDiagnostics = ""; Render();
        string? otherLibrary = null;   // 这个位置是另一个游戏库（library_id_mismatch）时的说明：作业收尾后问玩家要不要改用它
        try
        {
            if (operation == "setup")
            {
                connectedFolder = null; libraryId = null; catalog = null; selectedGame = null; ClearCovers();
                var folder = Path.GetFullPath(libraryFolder);
                var accept = new HashSet<string>();
                var setup = await LibraryJobClient.RunAsync(paths, privateRoot, folder, null, "setup", null, front.Token, jobId: front.Next());
                while (await ConfirmLibraryAsync(setup, accept))   // 认得出的风险（云盘目录 / 有别的文件）：讲清后果、玩家选「仍然继续」就带上对应参数重来（v0.3.1）
                    setup = await LibraryJobClient.RunAsync(paths, privateRoot, folder, null, "setup", null, front.Token, jobId: front.Next(), accept: accept);
                DisplayJob(setup);
                if (!setup.Report.Succeeded) { librarySummary = "library.failed"; return; }
                var connection = LibraryConnection.Parse(setup.Report.Result);
                connectedFolder = connection.Folder; libraryId = connection.Id; libraryFolder = connectedFolder;
            }
            else if (operation != "catalog")
            {
                var output = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder!, libraryId, operation, selectedPaths, front.Token, jobId: front.Next());
                DisplayJob(output);
                if (!output.Report.Succeeded) { librarySummary = "library.failed"; if (JobCode(output) == "library_id_mismatch") otherLibrary = output.Report.Message; return; }
            }
            var listing = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder!, libraryId, "catalog", null, front.Token, jobId: front.Next(), startup: TakeStartupCatalog());
            DisplayJob(listing);
            if (!listing.Report.Succeeded) { librarySummary = "library.failed"; if (JobCode(listing) == "library_id_mismatch") otherLibrary = listing.Report.Message; return; }
            catalog = LibraryCatalog.Parse(listing.Report.Result); ClearCovers();
            if (selectedGame is not null && !catalog.Games.Any(g => g.Id == selectedGame && !g.Hidden))
            {
                // #1392 读数：清空选中之前记一行（logs/launcher-crash.log）——选中的款、是缺席还是 Hidden、目录总款数、当时的出包款与状态
                var present = catalog.Games.FirstOrDefault(g => g.Id == selectedGame);
                LauncherCrash.Log(null, $"library.select.clear selected={selectedGame} state={(present is null ? "absent" : "hidden")} catalog={catalog.Games.Count} pack={packGame?.Id ?? "null"}/{(packState == "" ? "null" : packState)} result=cleared");
                selectedGame = null;
            }
            librarySummary = "library.completed";
            ResumeSGradeWatch();   // S 级批量升级队列还在跑就接着读进度（SGradeUpgrade.cs）
            _ = PreparePhoneUpdateAsync();   // 新版启动器头一次读到要更新的手机：后台准备 iPhone App 更新（PhoneAutoUpdate.cs）
        }
        catch (LibraryProtocolException error)
        { librarySummary = "library.invalid_result"; libraryDiagnostics += "\n" + error.Message; }
        catch (OperationCanceledException)
        { librarySummary = "library.interrupted"; }
        catch (Exception error)
        {
            // 游戏库作业由玩家输入驱动（目录填什么都有可能：末尾反斜杠、不存在、不可写、非法字符、在启动器自己的目录里）：
            //   任何异常都报成「操作未完成」并带原因，不让它逃出去（玩家反馈：点「连接或创建游戏库」闪退）
            librarySummary = "library.failed"; libraryDiagnostics += "\n" + error.GetType().Name + ": " + error.Message;
            LauncherCrash.Log(error, "library job");
        }
        finally
        { EndJob(front); Render(); }
        // 另一个游戏库（11-17 维护者：说清是哪个、让玩家点一下确认，不直接拒、不悄悄改用）：「仍然继续」= 对这个文件夹重走选库（已有库直接打开、记下它的库号）
        if (otherLibrary is not null && connectedFolder is not null && !closingLibrary
            && await ConfirmInstallActionAsync("install.drop", otherLibrary, ConfirmTitle("library_id_mismatch")))
        {
            libraryFolder = connectedFolder;
            await RunLibraryAsync("setup", null);
            return;
        }
        if (catalogAgain && !closingLibrary) { catalogAgain = false; await RunLibraryAsync("catalog", null); }
    }

    private void DisplayJob(LibraryJobOutput job)
    {
        libraryDiagnostics = job.Report.Message + "\n" + T("diagnostics.exit_code") + ": " + job.Output.ExitCode;
        if (job.Report.Diagnostics.ValueKind == JsonValueKind.Array)
            foreach (var diagnostic in job.Report.Diagnostics.EnumerateArray())
            {
                if (diagnostic.TryGetProperty("code", out var code))
                {
                    var value = code.GetString();
                    libraryDiagnostics += "\n" + T("errors." + value + ".title") + "\n" + T("errors." + value + ".detail");
                }
                foreach (var key in new[] { "summary", "suggestion" })
                    if (diagnostic.TryGetProperty(key, out var message) && message.ValueKind == JsonValueKind.String)
                        libraryDiagnostics += "\n" + message.GetString();
            }
        if (!string.IsNullOrWhiteSpace(job.Output.StandardError)) libraryDiagnostics += "\n" + job.Output.StandardError;
    }
}
