// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 一键装到 iPhone 的签名身份 + 更新 iPhone 上的 S2Arm（v0.3.0，同 Mac InstallModeViews.swift / S2ArmLauncherModel+InstallMode.swift）。
//   签名身份 = Apple ID（在 Impactor 里登录）/ 我的开发者证书，沿用 DevCertPage.cs 那套。0.6.4 起推 / 导出只有游戏库「导出…」一个入口，
//   这次怎么签在导出确认页选（ExportFlow.cs），设置里这张卡给的是缺省。InstallModeCard：设置里的一张卡。
//   更新：游戏库顶栏按钮（catalog phoneUpdates：设备记录的壳号比本版旧）→ 有要重新出包的款先三选一 → installUpdate 作业只换壳、不重推资源；
//   选了「更新并重新出这几款」：更新成功后把它们排进批量出包（只出 iPhone），整批出完逐款装上。
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private bool exportAvailable;                // 作业层读回的 exportAvailable：只报给控制口（ControlInstallMode），界面不再据它置灰
    private bool installModeTried, installModeLoading;
    private string signChoice = "appleId";   // installMode 作业的 signChoice：appleId / devCert / external
    // 出法（0.6.3，installMode 作业）：layout = 缺省现在按哪种推（shell 通用 S2Arm / standalone 独立 App，一 App 一游戏）；layoutGames = 按款选过的
    private string layout = "shell";
    /// <summary>installMode 作业读回过出法：没读回（首次渲染、作业失败）时两张卡都不画选中——原先先把缺省「通用 S2Arm」画成选中，
    ///   读回后才跳到真实那张，读失败就一直显示错的（0.6.2 前端走查）</summary>
    private bool layoutKnown;
    private Dictionary<string, string> layoutGames = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>出法选「独立 App」时按签名方式给的那句提示的码（installMode / layoutSet 结果 standaloneHint：appleId / wildcard / external；null → ""，不显示）</summary>
    private string standaloneHint = "";
    /// <summary>作业层按签名带不带调试权限推荐的出法（installMode / layoutSet 结果 recommend：standalone / shell；null → ""，两张卡都不挂推荐）
    ///   与推荐依据（recommendWhy：distribution / devCertDebug / appleId / external / unknown）：卡片「✓ 根据你的…推荐」和卡片下方那一行按它选句</summary>
    private string layoutRecommend = "", layoutRecommendWhy = "";
    // 更新作业：正在跑 / 计数；结果没看过时顶栏留一个可点掉的提示（"" = 成功，否则失败原因）
    private bool phoneUpdating;
    private long? updateDone, updateTotal;
    private string? updateOutcome;
    /// <summary>更新手机上的 S2Arm 这一单的状态（running / succeeded / failed / cancelled）：更新页的结局卡（PhoneJobCard）按它画</summary>
    private string updateState = "", updateMessage = "";
    private (bool AcceptStale, IReadOnlyList<string> Repack, IReadOnlySet<string> Accept) lastUpdate = (false, [], new HashSet<string>());
    private string? lastUpdateMode;
    private bool lastUpdateSGrade;
    /// <summary>更新页 drop 态问的是哪个码（ConfirmCodes 的键）：「仍然继续」带上它对应的参数</summary>
    private string updateAskCode = "";

    /// <summary>更新页（page = "phoneupdate"）：结局卡 + 失败重试 + 挤掉确认（页内）</summary>
    /// <summary>更新页（page = "phoneupdate"）：结局卡；第一次装 S2Arm 且用 Apple ID 签的，成功时写「先信任再打开」；Apple ID 没登录 / 过期失败时卡下给「打开 Impactor」
    ///   （走查：失败页的下一步写着去装机页点「打开 Impactor」，改版后这条路上没有装机页，玩家卡住）</summary>
    private Control PhoneUpdateCard()
    {
        var box = new StackPanel { Spacing = 14 };
        box.Children.Add(PhoneUpdateJobCard());
        if (updateState is "failed" && updateCode is "apple_not_signed_in" or "apple_session_expired")
        {
            var impactor = Action("action.open_impactor", OpenBundledImpactor, File.Exists(BundledImpactor));
            AutomationId(impactor, "phoneupdate.open_impactor");
            box.Children.Add(impactor);
        }
        return box;
    }

    /// <summary>更新这一单的失败码（apple_not_signed_in 等：卡下给「打开 Impactor」）</summary>
    private string? updateCode;
    /// <summary>这一单是给还没装 S2Arm 的手机第一次装（总控台「安装 S2Arm」/ 介绍卡「连上 iPhone 开始」）</summary>
    private bool updateFirstInstall;

    private IReadOnlyList<string>? FirstInstallNotes() =>
        updateFirstInstall && updateState == "succeeded" && signChoice == "appleId" ? [T("install.done.trust")] : null;

    private Control PhoneUpdateJobCard() => PhoneJobCard(updateTrack, updateState, updateMessage, updateDiagnostics, null, FirstInstallNotes(),
        retry: updateState is "failed" or "invalid" or "interrupted" ? () => _ = UpdatePhoneAsync(lastUpdate.AcceptStale, lastUpdate.Repack, lastUpdate.Accept, mode: lastUpdateMode, sgradeUpgrade: lastUpdateSGrade, firstInstall: updateFirstInstall) : null,
        confirmDrop: () => _ = UpdatePhoneAsync(lastUpdate.AcceptStale, lastUpdate.Repack,
            new HashSet<string>(lastUpdate.Accept) { ConfirmCodes.GetValueOrDefault(updateAskCode, "acceptDropped") }, mode: lastUpdateMode, sgradeUpgrade: lastUpdateSGrade),
        dropTitle: ConfirmTitle(updateAskCode),
        cancelDrop: () => { updateState = ""; updateOutcome = null; Navigate("library"); },
        alternateDrop: UpdateDropAlternate(),
        switchExport: updateState is "failed" or "invalid" or "interrupted" && lastUpdateMode != "export" && !updateFirstInstall   // 第一次装时不给「改为导出自签包」：新手看不懂，失败原因下面的按钮（打开 Impactor / 重试）才是下一步
            ? () => { _ = UpdatePhoneAsync(lastUpdate.AcceptStale, lastUpdate.Repack, lastUpdate.Accept, mode: "export", sgradeUpgrade: lastUpdateSGrade); } : null);
    /// <summary>更新页 drop 态问的码有并列的另一条路（共享体验表 alternate，自签走查结构 7）：按钮文案键 + 点了做什么（不重发，走清单同一个派发）</summary>
    private (string Label, Action Run)? UpdateDropAlternate()
    {
        if (updateState != "drop" || !text.ConfirmAlternates.TryGetValue(updateAskCode, out var alt)) return null;
        return (alt.Label, () => { updateState = ""; updateOutcome = null; RunInstallAction(alt.Action, null); });
    }
    private string updateDiagnostics = "";
    /// <summary>这一批是「更新并重新出这几款」排的：整批出完（没暂停、没取消）逐款装到 iPhone（BatchFinishedAsync）</summary>
    private bool batchInstallAfter;

    /// <summary>顶栏按钮对应的那台（多台时取第一台，同 Mac：作业里按连着的那台自己的记录再判一遍）</summary>
    private PhoneUpdate? PhoneUpdateTarget => catalog?.PhoneUpdates.FirstOrDefault();

    /// <summary>读签名身份（installMode 作业只读；11-15 维护者：导出不再是装法，游戏库「导出自签包」常驻，旧版的装法设置由作业层迁移删掉）。游戏库没连上时不读</summary>
    private async Task RefreshInstallModeAsync()
    {
        if (connectedFolder is null || libraryId is null || installModeLoading) return;
        installModeTried = true; installModeLoading = true;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("installMode", ""), null, CancellationToken.None);
            if (job.Report.Succeeded)
            {
                exportAvailable = Flag(job.Report.Result, "exportAvailable");
                signChoice = Str(job.Report.Result, "signChoice") is { Length: > 0 } sc ? sc : "appleId";   // 签名方式三选一（自签走查结构 6）
                layout = Str(job.Report.Result, "layout") is { Length: > 0 } lo ? lo : "shell";
                layoutKnown = true;
                ReadLayoutRecommend(job.Report.Result);
                layoutGames = new(StringComparer.OrdinalIgnoreCase);
                if (job.Report.Result.TryGetProperty("layoutChoice", out var lc) && lc.ValueKind == JsonValueKind.Object &&
                    lc.TryGetProperty("games", out var lg) && lg.ValueKind == JsonValueKind.Object)
                    foreach (var g in lg.EnumerateObject()) if (g.Value.ValueKind == JsonValueKind.String) layoutGames[g.Name] = g.Value.GetString() ?? "";
            }
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { }
        finally { installModeLoading = false; }
        Render();
    }

    /// <summary>页面要用到签名身份时（出包页那一行）还没读过就读一次；读失败不反复重试，进设置页会再读</summary>
    private void EnsureInstallMode()
    {
        if (!installModeTried && !installModeLoading) _ = RefreshInstallModeAsync();
    }

    // ---- 设置：一键装到 iPhone 的签名身份（11-15 起没有装法切换）----

    private Control InstallModeCard()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(Label(T("install.mode.device"), 16));
        panel.Children.Add(Muted(T("install.mode.device_note"), 12.5));
        // 签名身份：开发者证书一栏照用出包页原来那套（导入 / 换 / 删、体检明细）；Apple ID 在随包 Impactor 里登录
        var identity = new StackPanel { Spacing = 4 };
        identity.Children.Add(DevCertRow(T("install.mode.identity"), T("install.mode.identity_impactor"), card: false));
        // 「打开 Impactor」是动作不是选项：做成 Apple ID 那段下面的文字链接（11-14 体验梳理，开发甲定）；用开发者证书签时不需要它，不显示
        if (!(devCert is { } dc && Flag(dc, "active")))
        {
            var impactor = new Button { Content = new TextBlock { Text = T("action.open_impactor"), TextDecorations = TextDecorations.Underline, Foreground = Accent, FontSize = 13 },
                Background = Brushes.Transparent, Padding = new Thickness(0, 2), HorizontalAlignment = HorizontalAlignment.Right,
                IsEnabled = File.Exists(BundledImpactor) };
            impactor.Click += (_, _) => OpenBundledImpactor();
            AutomationId(impactor, "env.installMode.open_impactor");
            identity.Children.Add(impactor);
        }
        panel.Children.Add(identity);
        panel.Children.Add(LayoutCards(null));
        var card = Card(panel);
        AutomationId(card, "env.installMode");
        return card;
    }

    // ---- 出法（0.6.3 维护者定，两种并存、玩家自选；两张并排卡片，同 Mac InstallLayoutRow）----

    private static readonly IBrush LayoutGold = Brush.Parse("#E8C65A");

    /// <summary>选「独立 App」时按签名方式给的提示码（作业 standaloneHints，导出确认页按这次选的签名取）</summary>
    private IReadOnlyDictionary<string, string> standaloneHints = new Dictionary<string, string>();

    private void ReadLayoutRecommend(JsonElement result)
    {
        standaloneHints = ExportChoice.StandaloneHints(result);
        standaloneHint = Str(result, "standaloneHint");
        layoutRecommend = Str(result, "recommend");
        layoutRecommendWhy = Str(result, "recommendWhy");
    }

    /// <summary>卡片下方那一行（只出一行，按顺序取第一个命中的；都不命中 → null）：(文案键, 颜色)。只提示不拦、不弹窗</summary>
    private (string Key, string Color)? LayoutNote(string now) =>
        now == "shell" && layoutRecommendWhy == "distribution" ? ("layout.card.warn.distShell", "#FF9F0A")
        : now == "standalone" && layoutRecommendWhy == "appleId" ? ("layout.card.warn.freeStandalone", "#FF9F0A")
        : now == "standalone" && layoutRecommendWhy == "external" ? ("install.layout.hint.external", "#FF9F0A")
        : now == "standalone" && standaloneHint == "wildcard" ? ("install.layout.hint.wildcard", "#FFD60A")
        : layoutRecommendWhy == "unknown" ? ("layout.card.unknown", "#A8A6A1")
        : null;

    /// <summary>出法两张卡（设置页 / 出包页 / 单款装机页共用）。gameId 为空 = 设置里的缺省（选中的是现在生效的那种：没选过时作业层按证书自动）；
    ///   给了 = 这款单独选；单独选过时右上给「跟随设置（当前：…）」撤掉。推荐那张底部「✓ 根据你的…推荐」，卡片下方一行按 LayoutNote 提示</summary>
    private Control LayoutCards(string? gameId)
    {
        EnsureInstallMode();
        string Name(string v) => T(v == "standalone" ? "install.layout.standalone" : "install.layout.shell");
        var own = gameId is null ? null : layoutGames.GetValueOrDefault(gameId);
        var now = own ?? layout;
        var panel = new StackPanel { Spacing = 10 };

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 12 };
        var title = Muted(T(gameId is null ? "install.layout.title" : "install.layout.game"), 13.5); title.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(title);
        if (gameId is not null && own is not null)
        {
            var follow = new Button { Content = new TextBlock { Text = T("install.layout.follow").Replace("{0}", Name(layout)), TextDecorations = TextDecorations.Underline,
                    Foreground = Brush.Parse("#A8A6A1"), FontSize = 12.5 },
                Background = Brushes.Transparent, Padding = new Thickness(0, 2), VerticalAlignment = VerticalAlignment.Center };
            follow.Click += (_, _) => _ = SetLayoutAsync(null, gameId);
            AutomationId(follow, "install.layout.follow");
            Grid.SetColumn(follow, 1); header.Children.Add(follow);
        }
        panel.Children.Add(header);

        Control OneCard(string value, string body, string badge, bool gold)
        {
            var on = (own is not null || layoutKnown) && now == value;
            var content = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,*,Auto"), RowSpacing = 6 };
            // 右上：角标 + 小问号（悬停展开原理说明，点一下也展开 / 收起；两张同一段）
            var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 6 };
            top.Children.Add(new Border { Background = gold ? LayoutGold : Brush.Parse("#5A5A60"), CornerRadius = new CornerRadius(9), Padding = new Thickness(8, 2),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = T(badge), FontSize = 11, FontWeight = FontWeight.Bold, TextWrapping = TextWrapping.Wrap,
                    Foreground = gold ? Brushes.Black : Brushes.White } });
            var help = new Button { Content = "?", FontSize = 11, FontWeight = FontWeight.Bold, Width = 20, Height = 20, Padding = new Thickness(0),
                CornerRadius = new CornerRadius(10), HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center, Background = Brush.Parse("#2E2E33"), Foreground = Brush.Parse("#A8A6A1") };
            ToolTip.SetTip(help, new TextBlock { Text = T("layout.card.why"), TextWrapping = TextWrapping.Wrap, MaxWidth = 420, FontSize = 13, LineHeight = 20 });
            ToolTip.SetShowDelay(help, 150); ToolTip.SetPlacement(help, PlacementMode.Bottom);
            help.Click += (_, e) => { ToolTip.SetIsOpen(help, !ToolTip.GetIsOpen(help)); e.Handled = true; };   // 不冒泡到卡片：点问号不算选这张
            Avalonia.Automation.AutomationProperties.SetName(help, T("layout.card.whyLabel"));
            AutomationId(help, "install.layout.why." + value);
            Grid.SetColumn(help, 1); top.Children.Add(help);
            content.Children.Add(top);
            // 圆点 + 标题：选中实心金点，没选灰圈
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new Avalonia.Controls.Shapes.Ellipse { Width = 12, Height = 12, VerticalAlignment = VerticalAlignment.Center,
                Fill = on ? LayoutGold : Brushes.Transparent, Stroke = on ? LayoutGold : Brush.Parse("#6E6E73"), StrokeThickness = 1.5 });
            head.Children.Add(Label(Name(value), 16));
            Grid.SetRow(head, 1); content.Children.Add(head);
            var text = Muted(T(body), 12.5);
            Grid.SetRow(text, 2); content.Children.Add(text);
            if (layoutRecommend == value)
            {
                var rec = new TextBlock { Text = "✓ " + T(layoutRecommendWhy is "distribution" or "devCertDebug" ? "layout.card.recommendCert" : "layout.card.recommendSign"),
                    FontSize = 12, FontWeight = FontWeight.SemiBold, Foreground = LayoutGold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
                AutomationId(rec, "install.layout.recommended." + value);
                Grid.SetRow(rec, 4); content.Children.Add(rec);
            }
            var card = new Button { Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,   // 两张卡同高，推荐那行贴底
                Padding = new Thickness(14, 12), CornerRadius = new CornerRadius(12), Foreground = Ink,
                Background = on ? Brush.Parse("#2A2722") : Surface, BorderBrush = on ? LayoutGold : Brush.Parse("#3A3A3F"), BorderThickness = new Thickness(on ? 2 : 1) };
            AutomationId(card, (gameId is null ? "install.layout." : "install.layout.game.") + value);
            // 点卡片 = 选它（不拦）；已经明确选的就是它时不重发
            card.Click += (_, _) => { if (!layoutKnown || (gameId is null ? layout : own) != value) _ = SetLayoutAsync(value, gameId); };
            return card;
        }
        var standalone = OneCard("standalone", "layout.card.standalone.body", "layout.card.standalone.badge", gold: true);
        var shell = OneCard("shell", "layout.card.shell.body", "layout.card.shell.badge", gold: false);
        // 并排；窄时（不到 520 宽）上下排
        var cards = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
        cards.Children.Add(standalone); cards.Children.Add(shell);
        void Arrange(bool wide)
        {
            cards.ColumnDefinitions = new ColumnDefinitions(wide ? "*,*" : "*");
            cards.RowDefinitions = new RowDefinitions(wide ? "Auto" : "Auto,Auto");
            Grid.SetColumn(shell, wide ? 1 : 0); Grid.SetRow(shell, wide ? 0 : 1);
        }
        var wideNow = true; Arrange(true);
        cards.SizeChanged += (_, e) => { var wide = e.NewSize.Width >= 520; if (wide != wideNow) { wideNow = wide; Arrange(wide); } };
        panel.Children.Add(cards);

        if (LayoutNote(now) is { } note)
        {
            var line = new TextBlock { Text = T(note.Key), TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Brush.Parse(note.Color) };
            AutomationId(line, "install.layout.note");
            panel.Children.Add(line);
        }
        AutomationId(panel, gameId is null ? "env.installLayout" : "install.layout");
        return panel;
    }

    /// <summary>作业 layoutSet：layout = shell / standalone / null（撤掉选择）；gameId 给了只管这一款。下次推到 iPhone 时作业层按它分流，这里不装任何东西</summary>
    private async Task SetLayoutAsync(string? value, string? gameId)
    {
        var args = new Dictionary<string, object?>();
        if (value is not null) args["layout"] = value;   // 不带 layout = 撤掉选择（作业层 c.r.get("layout") 为空）
        if (gameId is not null) args["gameId"] = gameId;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("layoutSet", "", args), null, CancellationToken.None);
            if (job.Report.Succeeded) ReadLayoutRecommend(job.Report.Result);
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { }
        await RefreshInstallModeAsync();
    }

    // ---- 游戏库顶栏：更新 iPhone 上的 S2Arm ----

    /// <summary>正在更新 → 进度（不可点）；更新完没看过 → 结果（点一下收起）；壳比本版旧 → 按钮；都不是 → null</summary>
    private Button? PhoneUpdateControl()
    {
        if (phoneUpdating)
        {
            var text = T("update.running") + (updateDone is { } d && updateTotal is { } t && t > 0 ? " · " + (100 * d / t) + "%" : "");
            var running = new Button { Content = text, Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(16),
                Background = Brush.Parse("#29292D"), Foreground = Ink };
            AutomationId(running, "top.phoneUpdate");
            running.Click += (_, _) => Navigate("phoneupdate");   // 回到更新页看进度
            return running;
        }
        if (updateOutcome is { } outcome)
        {
            var full = outcome.Length == 0 ? T("update.done") : T("update.confirm.title") + " · " + B(outcome);
            var shown = new TextBlock { Text = full, MaxWidth = 360, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
            if (outcome.Length > 0) shown.Foreground = Brush.Parse("#FFC857");
            var result = new Button { Content = shown, Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(16),
                Background = Brush.Parse("#29292D"), Foreground = Ink };
            ToolTip.SetTip(result, updateDiagnostics.Length > 0 ? full + "\n\n" + updateDiagnostics : full);
            AutomationId(result, "top.phoneUpdate.result");
            result.Click += (_, _) => { updateOutcome = null; Navigate("phoneupdate"); };   // 打开更新页看结局（胶囊随之收起）
            return result;
        }
        if (PhoneUpdateTarget is null) return null;
        var button = new Button
        {
            Content = T("update.button.device"), IsEnabled = !ControlBusy && !batchRunning,
            Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8), Background = Brush.Parse("#29292D"), Foreground = Ink
        };
        AutomationId(button, "top.phoneUpdate");
        button.Click += (_, _) => _ = RequestPhoneUpdateAsync();
        return button;
    }

    /// <summary>点更新：没有要重新出包的款直接更新；有就先三选一（更新并重新出这几款 / 只更新，其他稍后 / 取消）</summary>
    private async Task RequestPhoneUpdateAsync()
    {
        if (PhoneUpdateTarget is not { } u || ControlBusy || batchRunning) return;
        if (u.Stale.Count == 0) { await UpdatePhoneAsync(false, []); return; }
        var choice = await ConfirmPhoneUpdateAsync(u);
        if (choice is null) return;
        await UpdatePhoneAsync(true, choice == "repack" ? u.Stale.Select(g => g.Id).ToList() : []);
    }

    /// <summary>三选一弹窗（照 ConfirmInstallActionAsync 的写法）：返回 "repack" / "later"，取消或关窗为 null</summary>
    private async Task<string?> ConfirmPhoneUpdateAsync(PhoneUpdate u)
    {
        var dialog = NewDialog(T("update.confirm.title"), 460);
        string? choice = null;
        var body = new StackPanel { Spacing = 16, Margin = new Thickness(28) };
        body.Children.Add(Label(T("update.confirm.title"), 20));
        var names = string.Join(language == "en" ? ", " : "」「", u.Stale.Select(g => g.Name));
        body.Children.Add(Muted(T("update.confirm.body").Replace("{0}", names).Replace("{1}", (u.Games.Count - u.Stale.Count).ToString()), 14));
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = DialogButton(T("update.confirm.cancel"), false, () => dialog.Close());
        AutomationId(cancel, "update.confirm.cancel");
        var later = DialogButton(T("update.confirm.later"), false, () => { choice = "later"; dialog.Close(); });
        AutomationId(later, "update.confirm.later");
        var repack = DialogButton(T("update.confirm.repack"), true, () => { choice = "repack"; dialog.Close(); });
        AutomationId(repack, "update.confirm.repack");
        buttons.Children.Add(cancel); buttons.Children.Add(later); buttons.Children.Add(repack);
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        return choice;
    }

    /// <summary>
    /// installUpdate 作业（install.update_phone）。不走 RunPhoneJobAsync：那条是按款的（要 gameId、写进那款的装机页状态），
    /// 这里不属于哪一款，进度和结果画在顶栏；同样占着 installBusy，别的手机作业 / 出包在它跑时不开始。
    /// 结束后重读游戏库（按钮随检测结果消失）；repack 非空且更新成功 → 把这几款排进批量出包、只出 iPhone，整批出完逐款装上。
    /// </summary>
    /// acceptDropped / ask 同 InstallAsync：会让手机上别的电脑装的游戏暂时不能玩（container_would_drop）时，界面发起的弹同一个确认框、确认后带 acceptDropped 重跑；
    /// 控制口发起的不弹、原样失败，由调用方带 acceptDropped 再发（v0.3.0 只换壳验收：原先这条路没接确认，提示「确认继续再点一次」却永远过不去）
    /// mode / sgradeUpgrade：「S 级优化升级」页的两个按钮（SGradeUpgradePage.cs，同 Mac）——mode = device / export 这次按它装（不改设置里的装法），
    /// sgradeUpgrade = 壳已是本版也重组容器、给游戏程序补上 S 级优化（install.update_phone）
    private async Task UpdatePhoneAsync(bool acceptStale, IReadOnlyList<string> repack, IReadOnlySet<string>? accept = null, bool ask = true, string? mode = null, bool sgradeUpgrade = false, string? device = null,
        bool firstInstall = false)
    {
        if (connectedFolder is null || libraryId is null) return;
        // 没指定这次怎么走 = 装到手机（11-19 自签走查结构 8）：出包页「出完之后」只管出包页那一次，不当续签 / 更新的全局开关
        if (QueuePhone(null, () => UpdatePhoneAsync(acceptStale, repack, accept, ask, mode, sgradeUpgrade, device, firstInstall))) return;   // 出包在跑不挡；手机上有作业在跑 → 排队
        accept ??= new HashSet<string>();
        lastUpdate = (acceptStale, repack, accept);   // 失败页「重试」/ 挤掉确认的「仍然继续」按同样的参数再来
        lastUpdateMode = mode; lastUpdateSGrade = sgradeUpgrade;
        var front = BeginJob(JobKind.Phone); phoneUpdating = true; updateOutcome = null; updateDiagnostics = ""; updateDone = updateTotal = null;
        updateState = "running";
        updateTrack.Begin("installUpdate", InstallTargetLabel); updateMessage = "";
        updateFirstInstall = firstInstall && mode != "export"; updateCode = null;
        if (updateFirstInstall) updateTrack.TextKind = "installShell";   // 实际装上的那台作业结束后按结果改（PhoneJobTrack.Finish）
        updateTrack.Version = UpdateClient.CurrentVersion(InstallDir);
        Navigate("phoneupdate");   // 自己的一页：进行中 → 成功 / 失败（原先只有顶栏一个胶囊，失败原因被截断）
        var succeeded = false;
        string? dropAsk = null;
        try
        {
            // 更新哪台：壳旧了的那台（phoneUpdates 的设备记录键），作业层不自己挑
            var extra = new Dictionary<string, object?>();
            if (acceptStale) extra["acceptStale"] = true;
            if (mode is "device" or "export") extra["mode"] = mode;
            if (sgradeUpgrade) extra["sgradeUpgrade"] = true;
            foreach (var key in accept) extra[key] = true;
            // 更新哪台：自动更新（PhoneAutoUpdate.cs）带连着的那台；否则壳旧了的那台（phoneUpdates 的设备记录键），作业层不自己挑
            if (device is { Length: > 0 }) extra["device"] = device;
            else if (PhoneUpdateTarget is { Device.Length: > 0 } target) extra["device"] = target.Device;
            if (!HomeWidget) extra["widget"] = false;   // 玩家关了「装到 iPhone 时带主屏小组件」
            var job = await PackJobClient.RunAsync(PackRequest("installUpdate", "", extra.Count > 0 ? extra : null),
                e => Dispatcher.UIThread.Post(() => IngestUpdateEvent(e)), front.Token, front.Next());
            succeeded = job.Report.Succeeded;
            updateTrack.Finish(job, GameName);
            if (succeeded && updateTrack.ExportFolder.Length > 0) OpenFolder(updateTrack.ExportFolder);   // 导出模式的「导出新版 S2Arm」：打开放好的文件夹
            updateState = job.Report.State;
            if (ask && JobCode(job) is { } c && ConfirmCodes.ContainsKey(c)) { dropAsk = job.Report.Message; updateAskCode = c; }
            updateOutcome = succeeded ? "" : job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
            updateMessage = succeeded ? "" : updateOutcome;
            updateDiagnostics = succeeded ? "" : JobDiagnostics(job);
            updateCode = succeeded ? null : JobCode(job);
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { updateOutcome = error.Message.Length > 0 ? error.Message : error.GetType().Name; updateMessage = updateOutcome; updateState = error is OperationCanceledException ? "cancelled" : "failed"; updateTrack.Ended = DateTime.UtcNow; }
        finally { EndJob(front); phoneUpdating = false; DynamicFinished(updateState); AfterArtifactJob(); Render(); }
        // 会挤掉别处装的游戏：就在更新页里问（「仍然继续」/「先不」），不弹散的对话框（维护者 11-11：更新要有一页引导整个流程）
        if (dropAsk is not null) { updateState = "drop"; updateMessage = dropAsk; Render(); return; }
        await RefreshLibraryAsync();   // 游戏库作业在跑就记一笔、那一轮完了补刷（剃刀 W8），不再跳过
        if (!succeeded || repack.Count == 0 || batchRunning || PackBusy) return;
        OpenBatch(repack, []);
        batchControlPlatforms = batchDraft.ToDictionary(r => r.Id, _ => new[] { "iphone" });   // 只出 iPhone（缺东西的款 StartBatchAsync 自己跳过）
        await StartBatchAsync(installAfter: true);
    }

    private void IngestUpdateEvent(System.Text.Json.JsonElement e)
    {
        updateTrack.Ingest(e);
        if (e.TryGetProperty("done", out var d) && d.ValueKind == System.Text.Json.JsonValueKind.Number &&
            e.TryGetProperty("total", out var t) && t.ValueKind == System.Text.Json.JsonValueKind.Number && t.GetInt64() > 0)
        { updateDone = d.GetInt64(); updateTotal = t.GetInt64(); RefreshLive(); }   // 只刷新顶栏「更新中 · N%」那一格
    }

    /// <summary>批次出完（AdvanceBatchAsync 没有下一个了）：由更新发起的那批，出好的 iPhone 包逐款跑现有的装到 iPhone 流程（暂停 / 取消的不装）。
    /// 一款装前清单没齐或没装成就停在那一款的装机页，玩家看得到原因；后面的不再接着装（多半是同一个原因，比如手机没连）。</summary>
    private async Task BatchFinishedAsync()
    {
        if (!batchInstallAfter) return;
        batchInstallAfter = false;
        if (batchState is not { Paused: null } state) return;
        var ids = state.Items.Where(i => i.Platforms.Contains("iphone") && i.Result("iphone").State == "completed").Select(i => i.GameId).ToList();
        if (libraryOperation is { IsCompleted: false } reload) await reload;   // 最后一款出好后在重读游戏库：读完再装（iPhone 就绪状态）
        foreach (var id in ids)
        {
            if (batchRunning || BatchGame(id) is not { } game) return;   // 出包 / 别的装机在跑不停这串：InstallAsync 自己排队
            selectedGame = game.Id; readinessFor = game.Id; readiness = null; installCheckFailed = false;
            Navigate("install");
            await CheckInstallAsync();   // 只为拿到装到哪台（InstallDevice）；清单没全勾也照装，作业层报真实原因
            await InstallAsync(game);
            if (installState is not ("succeeded" or "needsPlayer")) return;
        }
    }

    /// <summary>GET /state 的 installMode / phoneUpdates（形状同 Mac S2ArmControl）</summary>
    private Dictionary<string, object?> ControlInstallMode() => new() { ["signMode"] = devCert is { } st && Flag(st, "active") ? "devcert" : "appleId", ["exportAvailable"] = exportAvailable };

    private List<Dictionary<string, object?>> ControlPhoneUpdates() => (catalog?.PhoneUpdates ?? []).Select(u => new Dictionary<string, object?>
    {
        ["device"] = u.Device, ["games"] = u.Games.Select(g => g.Id).ToList(), ["stale"] = u.Stale.Select(g => g.Id).ToList()
    }).ToList();

    /// <summary>POST /update-phone {acceptStale?, repack?, acceptDropped?}（同 Mac 控制口）：同顶栏按钮；有要重新出包的款没给 acceptStale → 409 列出它们</summary>
    private ControlReply ControlUpdatePhone(ControlRequest r)
    {
        if (ControlBusy || batchRunning) return Busy();
        if (PhoneUpdateTarget is not { } u)
            return ControlReply.Json(new Dictionary<string, object?> { ["ok"] = false, ["error"] = "按这台电脑的装机记录，手机上的 S2Arm 已是本版" }, 409);
        var accept = r.Flag("acceptStale");
        var stale = u.Stale.Select(g => new Dictionary<string, object?> { ["gameId"] = g.Id, ["name"] = g.Name }).ToList();
        if (r.Flag("ask"))   // 同玩家点顶栏按钮：有要重新出包的款弹三选一（玩家在窗口里选），没有就直接更新（同 Mac）
        {
            _ = RequestPhoneUpdateAsync();
            return ControlReply.Json(new Dictionary<string, object?> { ["ok"] = true, ["asked"] = u.Stale.Count > 0, ["stale"] = stale });
        }
        if (u.Stale.Count > 0 && !accept)
            return ControlReply.Json(new Dictionary<string, object?>
            {
                ["ok"] = false, ["error"] = "这几款要按新版重新出包，重新出包前暂时打不开：带 acceptStale 确认（repack 为真时更新完把它们排进批量出包、出完自动装）",
                ["stale"] = stale
            }, 409);
        _ = UpdatePhoneAsync(accept, r.Flag("repack") ? u.Stale.Select(g => g.Id).ToList() : [], AcceptFlags(r), ask: false);   // 同 /install
        return ControlReply.Json(new Dictionary<string, object?> { ["ok"] = true, ["stale"] = stale });
    }
}
