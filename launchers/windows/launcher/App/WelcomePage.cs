// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

// 欢迎页：游戏库为空（或刚导入第一款）时显示，同时是环境检查。
// 左列：App 介绍；右列：三步（准备这台电脑 → 添加游戏 → 放入密钥）。
// 回到窗口自动重查；导入成功后右下角「一键出包」。
// Windows 版不提 Xcode / Metal / iOS 平台组件，只列后端返回的 non-ok 检查项。
public sealed partial class EnvironmentWindow
{
    private enum WelcomeStep { Pc = 0, Games = 1, Keys = 2 }

    private bool ShowsWelcome =>
        catalog == null ||
        (catalog.Games.All(g => g.Hidden) && welcomeGameId == null) ||
        welcomeGameId != null;

    // 检查本身没做成不等于环境有问题：不拦玩家，真缺东西时出包会报具体原因
    private bool EnvironmentUnknown => !busy && (report is { Error: not null } ||
        (report is null && summaryKey is "process.start_failed" or "protocol.invalid_report" or "process.interrupted" or "environment.failed"));
    // PcReady = 可以往下走（真准备好，或检查本身没做成也不拦）；绿勾和「检查全部通过」只给真准备好的（剃刀 W5：没查成也打绿勾、写全部通过，文案对不上）
    private bool PcReady => report is { Ready: true } || EnvironmentUnknown;
    private bool PcChecked => report is { Ready: true };
    private bool GamesChosen => pendingImportPaths.Length > 0 || welcomeGameId != null;
    private bool KeysSettled => welcomeGameId != null ||
        (catalog?.KeysReady == true && !keysRejected) ||
        (pendingImportPaths.Length > 0 && catalog?.KeysReady == true);
    private WelcomeStep WelcomeCurrent =>
        !PcReady ? WelcomeStep.Pc : !GamesChosen ? WelcomeStep.Games : WelcomeStep.Keys;
    private bool WelcomeDone(WelcomeStep s) => s switch
    {
        WelcomeStep.Pc => PcChecked,
        WelcomeStep.Games => GamesChosen,
        WelcomeStep.Keys => KeysSettled,
        _ => false
    };
    private LibraryGame? WelcomeGame => welcomeGameId is null ? null
        : catalog?.Games.FirstOrDefault(g => g.Id == welcomeGameId && !g.Hidden);

    private void RenderWelcome(StackPanel body)
    {
        var outer = new Grid { ColumnDefinitions = new ColumnDefinitions("*,580") };

        // ── 左列：介绍 ──────────────────────────────────────────────────
        var intro = new StackPanel { Spacing = 0 };
        var journey = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        void JourneyNode(string label) => journey.Children.Add(new TextBlock
        {
            Text = label, FontSize = 17, FontWeight = FontWeight.Light, Foreground = Accent, Opacity = 0.75,
            VerticalAlignment = VerticalAlignment.Center
        });
        void JourneyBar() => journey.Children.Add(new Border
        { Width = 40, Height = 1, Background = Accent, Opacity = 0.35, VerticalAlignment = VerticalAlignment.Center });
        JourneyNode("Switch"); JourneyBar(); JourneyNode(T("welcome.win.journey.pc")); JourneyBar(); JourneyNode("iPhone");
        intro.Children.Add(journey);
        intro.Children.Add(Spacer(34));
        intro.Children.Add(BigTitle(T("welcome.win.title")));
        intro.Children.Add(Spacer(20));
        intro.Children.Add(Lead(T("welcome.win.lead")));
        intro.Children.Add(Spacer(14));
        intro.Children.Add(new TextBlock { Text = T("welcome.soon"), FontSize = 14, FontWeight = FontWeight.SemiBold,
            Foreground = Accent, Opacity = 0.75, TextWrapping = TextWrapping.Wrap });
        intro.VerticalAlignment = VerticalAlignment.Center;
        intro.Margin = new Thickness(48);
        Grid.SetColumn(intro, 0); outer.Children.Add(intro);

        // ── 右列：三步 ──────────────────────────────────────────────────
        var steps = new StackPanel { Spacing = 0, Margin = new Thickness(0, 44, 48, 44) };
        steps.Children.Add(WelcomeStepRow(WelcomeStep.Pc,
            T(PcChecked ? "welcome.win.step.pc.done" : EnvironmentUnknown ? "welcome.win.step.pc.unknown" : "welcome.win.step.pc.title"), false, PcContent()));
        steps.Children.Add(WelcomeStepRow(WelcomeStep.Games,
            T(GamesChosen ? "welcome.step.games.done" : "welcome.step.games.title"), false, GamesContent()));
        steps.Children.Add(WelcomeStepRow(WelcomeStep.Keys,
            T(KeysSettled ? "welcome.step.keys.done" : welcomeGameId != null ? "welcome.step.keys.notNeeded" : "welcome.step.keys.title"),
            true, KeysContent()));
        Grid.SetColumn(steps, 1); outer.Children.Add(steps);
        body.Children.Add(outer);

        // 右下角「一键出包」
        if (PcReady && welcomeGameId != null)
        {
            var oneclick = new Button
            {
                Content = T("welcome.oneclick"), Background = Accent, Foreground = Canvas,
                Padding = new Thickness(28, 12), CornerRadius = new CornerRadius(24),
                FontSize = 16, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Right
            };
            oneclick.Click += (_, _) => StartOneClick(WelcomeGame!);
            body.Children.Add(oneclick);
        }
    }

    private string? metalPickError;

    /// <summary>「已经装了但没识别到？手动指定安装文件夹」：在选的文件夹里找 metal.exe，找到就记住并重新检查，找不到写明找过哪几处。</summary>
    private async Task PickMetalFolderAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = T("welcome.win.metal.pick_title") });
        if (folders.Count == 0 || LocalPath(folders[0]) is not { Length: > 0 } folder) return;
        if (MetalFolder.Resolve(folder) is { } bin)
        {
            MetalFolder.Save(privateRoot, bin);
            metalPickError = null;
            await CheckAsync();
            return;
        }
        metalPickError = T("welcome.win.metal.pick_missing").Replace("{0}", folder).Replace("{1}", string.Join("、", MetalFolder.Candidates(folder)));
        Render();
    }

    private string EnvironmentSummary()
    {
        var lines = new List<string> { "S2Arm 环境检查未通过", "", "S2Arm：" + AppVersion,
            "系统：" + System.Runtime.InteropServices.RuntimeInformation.OSDescription, "" };
        lines.AddRange((report?.Checks ?? []).Where(c => c.Status != "ok").Select(c => $"{c.Name}（{c.Status}，{c.Code ?? "-"}）：{c.Message}"));
        lines.Add(""); lines.Add(diagnostics);
        return string.Join("\n", lines).Replace(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "~");
    }

    private Control GamesContent()
    {
        var panel = new StackPanel { Spacing = 8 };
        if (welcomeGameId != null)
        {
            var game = WelcomeGame;
            panel.Children.Add(Muted(game is not null ? game.Name : welcomeGameId));
            return panel;
        }
        if (pendingImportPaths.Length > 0)
        {
            var name = Path.GetFileName(pendingImportPaths[0]);
            var suffix = pendingImportPaths.Length > 1 ? $" +{pendingImportPaths.Length - 1}" : "";
            panel.Children.Add(Muted(name + suffix));
            return panel;
        }
        if (WelcomeCurrent == WelcomeStep.Games)
            panel.Children.Add(Muted(T("welcome.step.games.what")));
        // Xcode 下载很久：不是当前步骤也能先把游戏选了（Mac 同逻辑），但用次级按钮样式
        var btn = WelcomePrimary(T("welcome.step.games.action"), () => OpenWelcomeGames(), WelcomeCurrent == WelcomeStep.Games);
        panel.Children.Add(btn);
        return panel;
    }

    private Control KeysContent()
    {
        var panel = new StackPanel { Spacing = 8 };
        if (KeysSettled) return panel;   // 完成后标题已改，内容留空
        if (WelcomeCurrent == WelcomeStep.Keys)
        {
            panel.Children.Add(Muted(T("welcome.step.keys.what")));
            if (keysRejected)
                panel.Children.Add(new TextBlock { Text = T("welcome.keys.unusable"), FontSize = 13,
                    Foreground = Brush.Parse("#E55"), TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(WelcomePrimary(T("welcome.step.keys.action"), () => OpenWelcomeKeys(), true));
        }
        else
            panel.Children.Add(Muted(T("welcome.step.keys.skip")));
        return panel;
    }

    private Button WelcomePrimary(string text, Action handler, bool primary)
    {
        if (primary)
        {
            var btn = new Button
            {
                Content = text, Background = Accent, Foreground = Canvas,
                Padding = new Thickness(20, 10), CornerRadius = new CornerRadius(20),
                FontSize = 14, FontWeight = FontWeight.SemiBold
            };
            btn.Click += (_, _) => handler();
            return btn;
        }
        else
        {
            var btn = Action("", handler);
            btn.Content = text;
            return btn;
        }
    }

    private void OpenWelcomeGames()
    {
        if (libraryBusy) return;
        // 确保游戏库存在（没库就建一个私有默认库）
        importDialog = new ImportDialogState(ImportKind.Games); importError = ""; importNotice = "";   // 弹窗先开：建库失败的原因显示在弹窗里，不能点了没反应
        EnsureLibrary(() => { });
    }

    private void OpenWelcomeKeys()
    {
        if (libraryBusy) return;
        importDialog = new ImportDialogState(ImportKind.Keys); importError = "";   // 弹窗先开：建库失败的原因显示在弹窗里，不能点了没反应
        EnsureLibrary(() => { });
    }

    // 默认库：%USERPROFILE%\S2Arm（LibraryPaths.DefaultLibrary；玩家选过就用选的），如果还没连接就先 setup。
    private void EnsureLibrary(Action next)
    {
        if (connectedFolder is not null && libraryId is not null) { next(); Render(); return; }
        var defaultLib = SavedLibrary();
        // 玩家没选过位置：缺省位置被别的文件占着（多半是把 S2Arm 解压到了 %USERPROFILE%\S2Arm）时由作业层 setup 换到旁边（freeDefault，规则在
        //   pack/jobs/library.py setup，剃刀 W19），连上后记住实际位置。原先 setup 拒收后整个添加游戏卡死（v0.2.8 热修，「一直提示还有任务在进行」）
        freeDefault = !File.Exists(LibraryPreference);
        libraryFolder = defaultLib;
        libraryOperation = EnsureLibraryAsync(defaultLib, next);
    }

    /// <summary>这次连的是缺省库、玩家没选过位置（EnsureLibrary）：setup 换了位置就写进设置，下次启动直接连它</summary>
    private bool freeDefault;
    /// <summary>游戏库最近一次没连上的原因（建库作业的原话 / 异常）：添加游戏时显示它，不再说成「有任务在进行」</summary>
    private string libraryFailure = "";

    private async Task EnsureLibraryAsync(string folder, Action next)
    {
        if (connectedFolder is not null && libraryId is not null) { next(); Render(); return; }
        var front = BeginJob(JobKind.Library); librarySummary = "library.working"; Render();
        try
        {
            connectedFolder = null; libraryId = null; catalog = null; selectedGame = null; ClearCovers();
            PrivateJobRequest.EnsurePrivateRoot(privateRoot);
            var free = freeDefault; freeDefault = false;   // 文件夹由 setup 建（先过库路径规则，不在启动器目录里留空文件夹）
            var accept = new HashSet<string>();
            if (acceptFormatOnce) accept.Add("acceptFormat");   // 「仍然用这里」（LibraryDrivePicker）：这一次带 acceptFormat
            acceptFormatOnce = false;
            var setup = await LibraryJobClient.RunAsync(paths, privateRoot, folder, null, "setup", null, front.Token, libraryMoveFrom, jobId: front.Next(), freeDefault: free, accept: accept);
            while (await ConfirmLibraryAsync(setup, accept))   // 认得出的风险（云盘目录 / 有别的文件）：讲清后果、玩家选「仍然继续」就带上对应参数重来（v0.3.1）
                setup = await LibraryJobClient.RunAsync(paths, privateRoot, folder, null, "setup", null, front.Token, libraryMoveFrom, jobId: front.Next(), freeDefault: free, accept: accept);
            var moveFrom = libraryMoveFrom; libraryMoveFrom = null;
            DisplayJob(setup);
            libraryFailCode = setup.Report.Succeeded ? null : JobCode(setup); libraryFailMoveFrom = moveFrom; libraryFailFolder = folder;   // 盘格式不对时给「换一个存放位置」（LibraryDrivePicker）
            if (!setup.Report.Succeeded) { librarySummary = "library.failed"; importError = libraryFailure = LibraryFailed(folder, setup.Report.Message); return; }
            var conn = LibraryConnection.Parse(setup.Report.Result);
            connectedFolder = conn.Folder; libraryId = conn.Id; libraryFolder = connectedFolder; libraryFailure = "";
            if (free && !SameFolder(connectedFolder, folder))
            {
                try { File.WriteAllText(LibraryPreference, connectedFolder); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { libraryDiagnostics += "\n" + error.Message; }
            }
            var listing = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder, libraryId, "catalog", null, front.Token, jobId: front.Next(), startup: TakeStartupCatalog());
            DisplayJob(listing);
            if (listing.Report.Succeeded)
            { catalog = LibraryCatalog.Parse(listing.Report.Result); ClearCovers(); }
            librarySummary = "library.completed";
            next();
        }
        catch (LibraryProtocolException error)
        { librarySummary = "library.invalid_result"; libraryDiagnostics += "\n" + error.Message; importError = libraryFailure = LibraryFailed(folder, error.Message); }
        catch (OperationCanceledException) { librarySummary = "library.interrupted"; }
        catch (Exception error)   // 玩家输入驱动的连接 / 创建：任何异常都报出来、不逃出去（玩家反馈：点「连接或创建游戏库」闪退）
        { librarySummary = "library.failed"; libraryDiagnostics += "\n" + error.Message; importError = libraryFailure = LibraryFailed(folder, error.Message); }
        finally { EndJob(front); Render(); }
    }

    // 欢迎页「一键出包」：进入出包页（由 ExportPages.cs 渲染），留空壳等另一个任务填。
    public void StartOneClick(LibraryGame game)
    {
        welcomeGameId = null;
        selectedGame = game.Id;
        Navigate("build");
    }

    private static Canvas Spacer(double height) => new() { Height = height };

    private static TextBlock BigTitle(string text) => new()
    {
        Text = text, FontSize = 40, FontWeight = FontWeight.Bold, Foreground = Ink,
        TextWrapping = TextWrapping.Wrap, LineHeight = 48
    };

    private static TextBlock Lead(string text) => new()
    {
        Text = text, FontSize = 16, Foreground = Brush.Parse("#A8A6A1"),
        TextWrapping = TextWrapping.Wrap, MaxWidth = 440, LineHeight = 24, HorizontalAlignment = HorizontalAlignment.Left
    };

    private Control WelcomeStepRow(WelcomeStep step, string title, bool last, Control content)
    {
        var done = WelcomeDone(step);
        var active = step == WelcomeCurrent;
        var leftCol = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        var circle = new Border
        {
            Width = 30, Height = 30, CornerRadius = new CornerRadius(15),
            Background = done ? Brush.Parse("#3D8565") : Brushes.Transparent,
            BorderBrush = done ? Brushes.Transparent : (active ? Accent : Brush.Parse("#30FFFFFF")),
            BorderThickness = new Thickness(1.5),
            Child = new TextBlock
            {
                Text = done ? "✓" : ((int)step + 1).ToString(), FontSize = done ? 13 : 14,
                FontWeight = FontWeight.Bold, Foreground = done ? Canvas : (active ? Accent : Brush.Parse("#FFFFFF60")),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
            }
        };
        leftCol.Children.Add(circle);
        if (!last)
        {
            var line = new Border { Width = 1, Background = Brush.Parse("#FFFFFF1A"),
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
            Grid.SetRow(line, 1); leftCol.Children.Add(line);
        }
        var right = new StackPanel { Spacing = 10, Margin = new Thickness(0, 0, 0, last ? 0 : 30) };
        right.Children.Add(new TextBlock { Text = title, FontSize = active ? 22 : 18, FontWeight = FontWeight.Bold,
            Foreground = active || done ? Ink : Brush.Parse("#FFFFFF80"), TextWrapping = TextWrapping.Wrap });
        right.Children.Add(content);
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 16 };
        row.Children.Add(leftCol);
        Grid.SetColumn(right, 1); row.Children.Add(right);
        return row;
    }

    private Control PcContent()
    {
        var panel = new StackPanel { Spacing = 10 };
        if (busy)
        {
            panel.Children.Add(Muted(T("welcome.win.step.pc.checking")));
            panel.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4, MaxWidth = 200 });
            return panel;
        }
        if (PcChecked) { panel.Children.Add(Muted(T("welcome.win.step.pc.doneDetail"))); return panel; }
        if (EnvironmentUnknown)
        {
            // 没查成：说实话，可以先继续（真缺东西时出包会报具体原因），给重查 / 复制错误摘要
            panel.Children.Add(Muted(T("welcome.win.step.pc.unknownDetail")));
            var again = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
            again.Children.Add(Action("action.recheck", () => _ = CheckAsync(), !busy));
            again.Children.Add(CopyReportButton(null, null, EnvironmentSummary));
            panel.Children.Add(again);
            panel.Children.Add(ReportHintText());
            return panel;
        }
        if (report is null)
        {
            // 尚未检查：Activated 事件会自动触发；从压缩包里直接打开时不会有报告，要告诉玩家先解压
            panel.Children.Add(Muted(T(summaryKey == "environment.unzip_first" ? summaryKey : "welcome.win.step.pc.checking")));
            return panel;
        }
        panel.Children.Add(Muted(T("welcome.win.step.pc.what")));
        // 随包项先列；Metal 编译器要玩家自己装，放最后（OrderBy 稳定，其余顺序不变）
        foreach (var item in report.Checks.Where(c => c.Blocking).OrderBy(c => c.Id == "metal" ? 1 : 0))
        {
            var row = new StackPanel { Spacing = 4, Margin = new Thickness(0, 8, 0, 0) };
            row.Children.Add(new TextBlock { Text = item.Name, FontSize = 14.5, FontWeight = FontWeight.SemiBold,
                Foreground = Ink, TextWrapping = TextWrapping.Wrap });
            row.Children.Add(new TextBlock { Text = item.Id == "metal" && item.Status == "missing" ? T("welcome.win.metal.detail") : item.Message,
                FontSize = 13, Foreground = Brush.Parse("#A8A6A1"), TextWrapping = TextWrapping.Wrap });
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (item.OfficialUrl is { } url)
            {
                var official = Action("action.open_official", async () => await OpenOfficialAsync(url), !busy);
                btns.Children.Add(official);
            }
            if (item.Id == "metal") btns.Children.Add(Action("welcome.win.metal.pick", () => _ = PickMetalFolderAsync(), !busy));
            if (btns.Children.Count > 0) row.Children.Add(btns);
            if (item.Id == "metal" && metalPickError is { } pickError)
                row.Children.Add(new TextBlock { Text = pickError, FontSize = 13, Foreground = Brush.Parse("#E0A458"), TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(row);
        }
        var pcButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
        pcButtons.Children.Add(Action("action.recheck", () => _ = CheckAsync(), !busy));
        pcButtons.Children.Add(CopyReportButton(null, null, EnvironmentSummary));
        panel.Children.Add(pcButtons);
        panel.Children.Add(ReportHintText());
        return panel;
    }

    private string LibraryFailed(string folder, string reason) =>
        T("welcome.sheet.libraryFailed").Replace("{0}", folder).Replace("{1}", reason.Length > 0 ? reason : T("library.failed"));
}
