// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 「怎么签、怎么装」收成一套 + 更新 iPhone 上的 S2Arm（v0.3.0，同 Mac InstallModeViews.swift / S2ArmLauncherModel+InstallMode.swift）。
//   装到 iPhone 的方式存在作业层 install.json（installMode 作业，Mac / Windows 同一份）：一键装到 iPhone（签名身份 = Apple ID（在 Impactor 里登录）/
//   我的开发者证书，沿用 DevCertPage.cs 那套）或导出自己签名安装（导出作业合入前置灰）。
//   InstallModeCard：环境检查里的一张卡；InstallModeLine：出包页原来的「签名方式」二选一换成一行只读 + 「更改」（去环境检查）。
//   更新：游戏库顶栏按钮（catalog phoneUpdates：设备记录的壳号比本版旧）→ 有要重新出包的款先三选一 → installUpdate 作业只换壳、不重推资源；
//   选了「更新并重新出这几款」：更新成功后把它们排进批量出包（只出 iPhone），整批出完逐款装上。
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private string installMode = "device";      // installMode 作业读回的 mode：device / export（没读到按一键装）
    private bool exportAvailable;                // 导出作业合入前恒为 false：导出一项置灰
    private bool installModeTried, installModeLoading;
    // 更新作业：正在跑 / 计数；结果没看过时顶栏留一个可点掉的提示（"" = 成功，否则失败原因）
    private bool phoneUpdating;
    private long? updateDone, updateTotal;
    private string? updateOutcome;
    /// <summary>更新手机上的 S2Arm 这一单的状态（running / succeeded / failed / cancelled）：更新页的结局卡（PhoneJobCard）按它画</summary>
    private string updateState = "", updateMessage = "";
    private (bool AcceptStale, IReadOnlyList<string> Repack, IReadOnlySet<string> Accept) lastUpdate = (false, [], new HashSet<string>());
    /// <summary>更新页 drop 态问的是哪个码（ConfirmCodes 的键）：「仍然继续」带上它对应的参数</summary>
    private string updateAskCode = "";

    /// <summary>更新页（page = "phoneupdate"）：结局卡 + 失败重试 + 挤掉确认（页内）</summary>
    private Control PhoneUpdateCard() => PhoneJobCard(updateTrack, updateState, updateMessage, updateDiagnostics, null,
        retry: updateState is "failed" or "invalid" or "interrupted" ? () => _ = UpdatePhoneAsync(lastUpdate.AcceptStale, lastUpdate.Repack, lastUpdate.Accept) : null,
        confirmDrop: () => _ = UpdatePhoneAsync(lastUpdate.AcceptStale, lastUpdate.Repack,
            new HashSet<string>(lastUpdate.Accept) { ConfirmCodes.GetValueOrDefault(updateAskCode, "acceptDropped") }),
        dropTitle: ConfirmTitle(updateAskCode),
        cancelDrop: () => { updateState = ""; updateOutcome = null; Navigate("library"); });
    private string updateDiagnostics = "";
    /// <summary>这一批是「更新并重新出这几款」排的：整批出完（没暂停、没取消）逐款装到 iPhone（BatchFinishedAsync）</summary>
    private bool batchInstallAfter;

    /// <summary>顶栏按钮对应的那台（多台时取第一台，同 Mac：作业里按连着的那台自己的记录再判一遍）</summary>
    private PhoneUpdate? PhoneUpdateTarget => catalog?.PhoneUpdates.FirstOrDefault();

    /// <summary>读 / 改装到 iPhone 的方式（installMode 作业：带 mode 就改，不带只读）。游戏库没连上时不读，按一键装显示</summary>
    private async Task RefreshInstallModeAsync(string? set = null)
    {
        if (connectedFolder is null || libraryId is null || (installModeLoading && set is null)) return;
        installModeTried = true; installModeLoading = true;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("installMode", "", set is null ? null : new Dictionary<string, object?> { ["mode"] = set }),
                null, CancellationToken.None);
            if (job.Report.Succeeded)
            {
                installMode = Str(job.Report.Result, "mode") == "export" ? "export" : "device";
                exportAvailable = Flag(job.Report.Result, "exportAvailable");
            }
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { }
        finally { installModeLoading = false; }
        Render();
    }

    /// <summary>页面要用到装法时（出包页那一行、顶栏更新按钮）还没读过就读一次；读失败不反复重试，进环境检查页会再读</summary>
    private void EnsureInstallMode()
    {
        if (!installModeTried && !installModeLoading) _ = RefreshInstallModeAsync();
    }

    // ---- 环境检查：装到 iPhone 的方式 ----

    private Control InstallModeCard()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(Label(T("install.mode.title"), 16));
        panel.Children.Add(Muted(T("install.mode.note"), 12.5));
        panel.Children.Add(InstallModeOption("device", T("install.mode.device"), T("install.mode.device_note"), true));
        if (installMode == "device")
        {
            // 签名身份：开发者证书一栏照用出包页原来那套（导入 / 换 / 删、体检明细）；Apple ID 在随包 Impactor 里登录
            var identity = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 12, Margin = new Thickness(28, 0, 0, 0) };
            identity.Children.Add(DevCertRow(T("install.mode.identity"), T("install.mode.identity_impactor"), card: false));
            var impactor = Action("action.open_impactor", OpenBundledImpactor, File.Exists(BundledImpactor));
            impactor.VerticalAlignment = VerticalAlignment.Top;
            AutomationId(impactor, "env.installMode.open_impactor");
            Grid.SetColumn(impactor, 1); identity.Children.Add(impactor);
            panel.Children.Add(identity);
        }
        panel.Children.Add(InstallModeOption("export", T("install.mode.export"),
            T("install.mode.export_note") + (exportAvailable ? "" : "\n" + T("install.mode.export_soon")), exportAvailable));
        var card = Card(panel);
        AutomationId(card, "env.installMode");
        return card;
    }

    private Control InstallModeOption(string mode, string title, string note, bool enabled)
    {
        var text = new StackPanel { Spacing = 3 };
        text.Children.Add(Label(title, 14));
        text.Children.Add(Muted(note, 12.5));
        var option = new RadioButton
        {
            GroupName = "installMode", Content = text, IsChecked = installMode == mode, IsEnabled = enabled && !PackBusy && !installModeLoading,
            Opacity = enabled ? 1 : 0.5, HorizontalAlignment = HorizontalAlignment.Stretch
        };
        AutomationId(option, "env.installMode." + mode);
        option.IsCheckedChanged += (_, _) => { if (option.IsChecked == true && installMode != mode) _ = RefreshInstallModeAsync(mode); };
        return option;
    }

    // ---- 出包页：现在按哪种方式装 + 「更改」 ----

    private Control InstallModeLine()
    {
        EnsureInstallMode();
        if (devCert is null && !devCertLoading) _ = RefreshDevCertAsync();
        var devcertOn = devCert is { } st && Flag(st, "active");
        var summary = installMode == "export" ? T("install.mode.export")
            : T("install.mode.device") + "（" + T(devcertOn ? "export.sign.devcert" : "export.sign.appleId") + "）";
        var line = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 12 };
        var text = Muted(T("install.mode.summary").Replace("{0}", summary), 13.5); text.VerticalAlignment = VerticalAlignment.Center;
        AutomationId(text, "export.installMode");
        line.Children.Add(text);
        var change = Action("install.mode.change", () => Navigate("settings"));
        AutomationId(change, "export.installMode.change");
        Grid.SetColumn(change, 1); line.Children.Add(change);
        return Card(line, 14);
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
        EnsureInstallMode();
        var button = new Button
        {
            Content = T(installMode == "export" ? "update.button.export" : "update.button.device"), IsEnabled = !ControlBusy && !batchRunning,
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
    private async Task UpdatePhoneAsync(bool acceptStale, IReadOnlyList<string> repack, IReadOnlySet<string>? accept = null, bool ask = true)
    {
        if (installBusy || packRunning || connectedFolder is null || libraryId is null) return;
        accept ??= new HashSet<string>();
        lastUpdate = (acceptStale, repack, accept);   // 失败页「重试」/ 挤掉确认的「仍然继续」按同样的参数再来
        var front = BeginJob(JobKind.Phone); phoneUpdating = true; updateOutcome = null; updateDiagnostics = ""; updateDone = updateTotal = null;
        updateState = "running";
        updateTrack.Begin("installUpdate", InstallTargetLabel); updateMessage = "";   // 实际装上的那台作业结束后按结果改（PhoneJobTrack.Finish）
        updateTrack.Version = UpdateClient.CurrentVersion(InstallDir);
        Navigate("phoneupdate");   // 自己的一页：进行中 → 成功 / 失败（原先只有顶栏一个胶囊，失败原因被截断）
        var succeeded = false;
        string? dropAsk = null;
        try
        {
            // 更新哪台：壳旧了的那台（phoneUpdates 的设备记录键），作业层不自己挑
            var extra = new Dictionary<string, object?>();
            if (acceptStale) extra["acceptStale"] = true;
            foreach (var key in accept) extra[key] = true;
            if (PhoneUpdateTarget is { Device.Length: > 0 } target) extra["device"] = target.Device;
            var job = await PackJobClient.RunAsync(PackRequest("installUpdate", "", extra.Count > 0 ? extra : null),
                e => Dispatcher.UIThread.Post(() => IngestUpdateEvent(e)), front.Token, front.Next());
            succeeded = job.Report.Succeeded;
            updateTrack.Finish(job, GameName);
            updateState = job.Report.State;
            if (ask && JobCode(job) is { } c && ConfirmCodes.ContainsKey(c)) { dropAsk = job.Report.Message; updateAskCode = c; }
            updateOutcome = succeeded ? "" : job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
            updateMessage = succeeded ? "" : updateOutcome;
            updateDiagnostics = succeeded ? "" : JobDiagnostics(job);
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { updateOutcome = error.Message.Length > 0 ? error.Message : error.GetType().Name; updateMessage = updateOutcome; updateState = error is OperationCanceledException ? "cancelled" : "failed"; updateTrack.Ended = DateTime.UtcNow; }
        finally { EndJob(front); phoneUpdating = false; Render(); }
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
            if (installBusy || packRunning || batchRunning || BatchGame(id) is not { } game) return;
            selectedGame = game.Id; readinessFor = game.Id; readiness = null; installCheckFailed = false;
            Navigate("install");
            await CheckInstallAsync();   // 只为拿到装到哪台（InstallDevice）；清单没全勾也照装，作业层报真实原因
            await InstallAsync(game);
            if (installState is not ("succeeded" or "needsPlayer")) return;
        }
    }

    /// <summary>GET /state 的 installMode / phoneUpdates（形状同 Mac S2ArmControl）</summary>
    private Dictionary<string, object?> ControlInstallMode() => new() { ["mode"] = installMode, ["exportAvailable"] = exportAvailable };

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
