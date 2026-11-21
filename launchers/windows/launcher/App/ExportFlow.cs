// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 游戏库的两件事：更新 / 导出（0.6.4 改版，维护者 11-21 定稿；同 Mac 前端同一份作业层契约）。
//   更新：作业 updateGame，只在电脑上重做这一款（重编着色器库 + 按本版改写器刷新程序），不找设备、不推、不二次确认；
//         做过 iPhone 版的款才有按钮：有原因 = 主色「更新这款」+ 橙色原因行，全对上 = 灰色「无需更新」；做完重拉 updateHints，做不齐的黄字列在按钮下。
//   导出：一个入口「导出…」→ 导出确认页（page = "exportgame"）：① 怎么签名 ② 出法 ③ 导到哪（设备多选，默认都不勾 = 导出到文件夹并打开）→ 开始；
//         开始后同一页变逐台结果（每台一行、失败的单独重试）。原先的「推到 iPhone」「导出自签包」「更新这款 = 推」和出包页「出完之后」都并进这里。
//   判定规则（按钮三态、设备行可勾规则、起哪几单 install）在 Protocol/ExportChoice.cs，这里只画和串作业。
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    // ---- 更新这款（作业 updateGame）----

    /// <summary>正在更新的款：进度（作业 overall 或 done / total 折成 0–1，没有 = null）与当前步骤说明（作业原句）</summary>
    private readonly Dictionary<string, (double? Fraction, string Message)> gameUpdating = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>最近一次更新的结局：成没成、没成的原因（作业原句）、做不齐的黄字（诊断 update_incomplete 的玩家句）</summary>
    private readonly Dictionary<string, (bool Ok, string Message, IReadOnlyList<string> Warnings)> gameUpdated = new(StringComparer.OrdinalIgnoreCase);
    private bool GameUpdating(string? gameId) => gameId is not null && gameUpdating.ContainsKey(gameId);

    private ExportChoice.Update UpdateStateOf(LibraryGame game) => ExportChoice.UpdateState(game.IphoneReady, UpdateReasons(game));

    /// <summary>点「更新这款」：不二次确认，按钮当场变进度；做完拿结果里还剩的原因换掉提示（空 = 已是最新 → 灰色「无需更新」），再重拉一次 updateHints</summary>
    private async Task UpdateGameAsync(LibraryGame game)
    {
        if (GameUpdating(game.Id) || connectedFolder is null || libraryId is null) return;
        var front = BeginJob(JobKind.Update, game.Id);
        gameUpdating[game.Id] = (null, ""); gameUpdated.Remove(game.Id);
        Render();
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("updateGame", game.Id), e => Dispatcher.UIThread.Post(() =>
            {
                double? fraction = null;
                if (e.TryGetProperty("overall", out var o) && o.ValueKind == System.Text.Json.JsonValueKind.Number) fraction = o.GetDouble();
                else if (e.TryGetProperty("done", out var d) && d.ValueKind == System.Text.Json.JsonValueKind.Number &&
                         e.TryGetProperty("total", out var t) && t.ValueKind == System.Text.Json.JsonValueKind.Number && t.GetDouble() > 0) fraction = d.GetDouble() / t.GetDouble();
                var message = e.TryGetProperty("message", out var m) && m.ValueKind == System.Text.Json.JsonValueKind.String ? m.GetString() ?? "" : "";
                var was = gameUpdating.GetValueOrDefault(game.Id);
                if (gameUpdating.ContainsKey(game.Id)) gameUpdating[game.Id] = (fraction ?? was.Fraction, message.Length > 0 ? message : was.Message);
                RefreshLive();   // 只换按钮那一格（大卡按钮放在活格子里）
            }), front.Token, front.Next());
            var warnings = new List<string>();
            if (job.Report.Diagnostics.ValueKind == System.Text.Json.JsonValueKind.Array)
                foreach (var d in job.Report.Diagnostics.EnumerateArray())
                    if (d.TryGetProperty("code", out var c) && c.GetString() == "update_incomplete" &&
                        (d.TryGetProperty("summary", out var s) || d.TryGetProperty("message", out s)) && s.GetString() is { Length: > 0 } line && !warnings.Contains(line))
                        warnings.Add(line);
            if (job.Report.Succeeded && job.Report.Result.TryGetProperty("reasons", out var rs) && rs.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                var left = rs.EnumerateArray().Select(r => r.GetString() ?? "").Where(r => UpdateReasonKey(r) is not null).ToArray();
                if (left.Length > 0) updateHints[game.Id] = left; else updateHints.Remove(game.Id);
            }
            gameUpdated[game.Id] = (job.Report.Succeeded, job.Report.Succeeded ? "" : job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State, warnings);
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
        { gameUpdated[game.Id] = (false, error.Message.Length > 0 ? error.Message : error.GetType().Name, []); }
        finally { EndJob(front); gameUpdating.Remove(game.Id); Render(); }
        await RefreshUpdateHintsAsync();   // 判据照旧以 updateHints 为准（只读指纹、秒回）
    }

    /// <summary>大卡上的更新按钮（活格子：进度事件只换它）：没做过 iPhone 版 → null；更新中 → 不可点的进度；有原因 → 主色「更新这款」；全对上 → 灰色「无需更新」</summary>
    private Control? UpdateButton(LibraryGame game)
    {
        var state = UpdateStateOf(game);
        if (state == ExportChoice.Update.Hidden) return null;
        Button button;
        if (gameUpdating.TryGetValue(game.Id, out var now))
        {
            var text = "⟳ " + T("update.button.running") + (now.Fraction is { } f ? " " + (int)Math.Round(100 * Math.Clamp(f, 0, 1)) + "%" : "");
            button = Primary(text, () => { }, enabled: false);
            if (now.Message.Length > 0) ToolTip.SetTip(button, B(now.Message));
        }
        else if (state == ExportChoice.Update.Suggested)
            button = Primary(T("update.hint.button"), () => _ = UpdateGameAsync(game),
                !BusyFor(game) && game.LocationState is not ("missing" or "offline") && !SGradeUpgrading(game));
        else
        {
            button = Action("update.button.upToDate", () => { }, enabled: false);
            button.VerticalAlignment = VerticalAlignment.Center;
        }
        AutomationId(button, "library.hero.update");
        return button;
    }

    /// <summary>按钮上方：对不上几样写几行橙色原因 + 末行说点了会怎样（只在建议更新、没在更新时）</summary>
    private Control? UpdateReasonLines(LibraryGame game)
    {
        if (UpdateStateOf(game) != ExportChoice.Update.Suggested || GameUpdating(game.Id)) return null;
        var box = new StackPanel { Spacing = 4, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var r in UpdateReasons(game))
            box.Children.Add(new TextBlock { Text = "↻ " + T(UpdateReasonKey(r)!), Foreground = Brush.Parse("#FF9F0A"), FontSize = 13, TextWrapping = TextWrapping.Wrap });
        box.Children.Add(new TextBlock { Text = T("update.hint.tail"), Foreground = Brush.Parse("#A0A0A8"), FontSize = 12, TextWrapping = TextWrapping.Wrap });
        AutomationId(box, "update.hint");
        return box;
    }

    /// <summary>按钮下方：上次更新做不齐的黄字（不当失败）、没做成的原因</summary>
    private Control? UpdateOutcomeLines(LibraryGame game)
    {
        if (GameUpdating(game.Id) || !gameUpdated.TryGetValue(game.Id, out var done)) return null;
        var box = new StackPanel { Spacing = 4, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Left };
        // 做好了：说清只换了电脑上这份，设备上要换新版走「导出…」（走查：按钮变灰「无需更新」后，玩家以为手机上也更新了）
        if (done.Ok) box.Children.Add(new TextBlock { Text = "✓ " + T("update.done.next"), Foreground = Brush.Parse("#30D158"), FontSize = 13, TextWrapping = TextWrapping.Wrap });
        if (!done.Ok) box.Children.Add(new TextBlock { Text = "✕ " + B(done.Message), Foreground = Brush.Parse("#FF9F0A"), FontSize = 13, TextWrapping = TextWrapping.Wrap });
        foreach (var w in done.Warnings)
            box.Children.Add(new TextBlock { Text = "⚠ " + B(w), Foreground = Brush.Parse("#FFD60A"), FontSize = 13, TextWrapping = TextWrapping.Wrap });
        AutomationId(box, "update.outcome");
        return box;
    }

    // ---- 导出（导出确认页 → 逐台结果）----

    /// <summary>点了「开始」的一单：签名 / 出法 / 勾的设备（按列表顺序；空 = 导出到文件夹）、要不要先做 iPhone 版、每台的结局。
    /// Rows 的键是设备号，导出到文件夹那一行键为 ""；State：waiting（排着 / 在推，在推看 installDevice）/ succeeded / needsPlayer / failed / cancelled …</summary>
    private sealed class ExportRun(string gameId, string sign, string layout, IReadOnlyList<string> devices)
    {
        public string GameId { get; } = gameId;
        public string Sign { get; } = sign;
        public string Layout { get; } = layout;
        public IReadOnlyList<string> Devices { get; } = devices;
        public bool Packing;
        public string PackError = "";
        public readonly Dictionary<string, (string State, string Message, string? Code)> Rows = new(StringComparer.Ordinal);
        public bool Active => Packing || Rows.Values.Any(r => r.State == "waiting");
    }

    private readonly Dictionary<string, ExportRun> exportRuns = new(StringComparer.OrdinalIgnoreCase);
    private bool ExportRunPacking(string gameId) => exportRuns.TryGetValue(gameId, out var run) && run.Packing;

    // 确认页上玩家的选择（null = 跟缺省：签名跟设置、出法跟这款 / 设置）；勾了哪几台；正在现查设备
    private string? exportSignPick, exportLayoutPick;
    private readonly HashSet<string> exportPicked = new(StringComparer.Ordinal);
    private bool exportProbing;

    private bool CertImported => devCert is { } st && Flag(st, "imported");
    private string ExportSign => exportSignPick is { } pick && (pick != ExportChoice.DevCert || CertImported) ? pick : ExportChoice.DefaultSign(signChoice, CertImported);
    private string ExportLayout(LibraryGame game) => exportLayoutPick ?? layoutGames.GetValueOrDefault(game.Id) ?? layout;

    /// <summary>打开这款的导出确认页。上一单做完了再点 = 新的一单；还在做就回到那一单的逐台结果。
    /// preDevice：总控台独立 App「续签」= 导出到那一台——这是确认页上唯一会预先勾上设备的入口（其余一律默认都不勾，维护者 11-21 定）</summary>
    private void OpenExport(LibraryGame game, string? preDevice = null, string? sign = null)
    {
        libraryFolder = libraryFolderBox.Text ?? libraryFolder;
        selectedGame = game.Id;
        if (exportRuns.TryGetValue(game.Id, out var run) && !run.Active) exportRuns.Remove(game.Id);
        exportSignPick = sign; exportLayoutPick = null; exportPicked.Clear();
        if (preDevice is { Length: > 0 }) exportPicked.Add(preDevice);
        EnsureInstallMode();
        if (devCert is null) EnsureDevCert();
        Navigate("exportgame");
        if (!exportRuns.ContainsKey(game.Id)) _ = ProbeExportDevicesAsync();
    }

    /// <summary>设备列表来源 = 总控台同一个作业 phoneOverview（probe：现查连着的设备、各装着谁的 S2Arm）</summary>
    private async Task ProbeExportDevicesAsync()
    {
        exportProbing = true; Render();
        try { await RefreshPhoneOverviewAsync(probe: true); }
        finally { exportProbing = false; Render(); }
    }

    private IReadOnlyList<ExportChoice.DeviceRow> ExportRows(LibraryGame game, string sign, string lay) =>
        (phoneOverview?.Phones ?? []).Select(p => ExportChoice.Row(p, game.Id, sign, lay)).ToList();

    /// <summary>「iPhone · 我的 iPhone」「设备 · 编号末 6 位」：类型照作业回的写，读不到写「设备」</summary>
    private string ExportDeviceLabel(string kind, string name, string device) =>
        (kind.Length > 0 ? kind : T("export.device.kind.unknown")) + " · " + (name.Length > 0 ? name : (device.Length > 6 ? device[^6..] : device).ToUpperInvariant());

    private string ExportDeviceLabel(string device) =>
        phoneOverview?.Phones.FirstOrDefault(p => p.Device == device) is { } p ? ExportDeviceLabel(p.Kind, p.Name, p.Device) : ExportDeviceLabel("", "", device);

    /// <summary>导出到文件夹（控制口 /selfsign、总控台「导出所选 .s2arm」）：自签、不勾设备，直接开始这一单</summary>
    private void ExportSelfSign(LibraryGame game)
    {
        selectedGame = game.Id;
        if (exportRuns.TryGetValue(game.Id, out var run) && run.Active) { Navigate("exportgame"); return; }
        Navigate("exportgame");
        _ = BeginExportRunAsync(game, ExportChoice.SelfSign, ExportLayout(game), []);
    }

    /// <summary>确认页「开始」：只带勾着且此刻能勾的那几台（按列表顺序）</summary>
    private Task StartExportAsync(LibraryGame game)
    {
        var sign = ExportSign; var lay = ExportLayout(game);
        var devices = ExportRows(game, sign, lay).Where(r => r.Checkable && exportPicked.Contains(r.Device)).Select(r => r.Device).ToList();
        return BeginExportRunAsync(game, sign, lay, devices);
    }

    /// <summary>开始一单：layoutSet 记住这款的出法 → 要先做 iPhone 版就先出包（只出 iPhone，进度在出包进度页，出好由出包收尾接着 ContinueExportRun）→ 导出 / 逐台推</summary>
    private async Task BeginExportRunAsync(LibraryGame game, string sign, string lay, IReadOnlyList<string> devices)
    {
        var run = new ExportRun(game.Id, sign, lay, devices);
        foreach (var d in devices.DefaultIfEmpty("")) run.Rows[d] = ("waiting", "", null);
        exportRuns[game.Id] = run;
        Render();
        await SetLayoutAsync(lay, game.Id);   // 作业 layoutSet（开始前调一次）；记不下也照常往下走，install 作业按它记着的出法分流
        if (ExportChoice.NeedsPack(game.IphoneReady, game.IphoneExportable, devices.Count))
        {
            run.Packing = true;
            if (ExportStops(game)) { PackFailedForExport(game.Id, ExportBlocker(game)); return; }
            await StartPackAskedAsync(game);
            return;
        }
        ContinueExportRun(run);
    }

    /// <summary>iPhone 版好了：没勾设备 → 一单 install mode = export；勾了 → 从第一台起逐台排队，每台做完接下一台（ExportChoice.InstallRequests 同一规则）</summary>
    private void ContinueExportRun(ExportRun run)
    {
        run.Packing = false;
        var game = catalog?.Games.FirstOrDefault(g => string.Equals(g.Id, run.GameId, StringComparison.OrdinalIgnoreCase)) ?? (packGame?.Id == run.GameId ? packGame : null);
        if (game is null) { PackFailedForExport(run.GameId, T("export.no_game")); return; }
        RunExportRow(run, game, run.Devices.Count == 0 ? "" : run.Devices[0], chain: run.Devices.Count > 1);
        if (page == "progress" && packGame?.Id == run.GameId) { selectedGame = run.GameId; Navigate("exportgame"); }   // 正看着这款出包：做好了带回逐台结果
        else Render();
    }

    /// <summary>起一台（device = "" 是导出到文件夹）。chain：做完接列表里的下一台；单独「重试」不接</summary>
    private void RunExportRow(ExportRun run, LibraryGame game, string device, bool chain)
    {
        run.Rows[device] = ("waiting", "", null);
        var request = ExportChoice.InstallRequests(run.Sign, device.Length == 0 ? [] : [device])[0];
        _ = InstallAsync(game, export: request.ContainsKey("mode"), device: device.Length == 0 ? null : device, sign: (string?)request["sign"], onDone: (state, message, code) =>
        {
            run.Rows[device] = (state, message, code);
            var next = chain ? run.Devices.ToList().IndexOf(device) + 1 : 0;
            if (chain && next > 0 && next < run.Devices.Count) RunExportRow(run, game, run.Devices[next], chain: true);
            Render();
        });
    }

    /// <summary>导出那一单要先做 iPhone 版、没做成：停在「没做好」写原因（出包页 / 进度页有详情）</summary>
    private void PackFailedForExport(string gameId, string? why = null)
    {
        if (!exportRuns.TryGetValue(gameId, out var run)) return;
        run.Packing = false;
        run.PackError = why is { Length: > 0 } ? why : packSummary.Length > 0 ? packSummary : T("progress.failed");
        foreach (var key in run.Rows.Keys.ToList()) run.Rows[key] = ("notStarted", "", null);
        Render();
    }

    /// <summary>行内「去 S2Arm 卡」：游戏库首位总控台，切到这台（装 / 更新 S2Arm、交签名身份都在那里）</summary>
    private void OpenConsoleFor(string device)
    {
        consoleDevice = device;
        selectedGame = ConsoleId;
        Navigate("library");
        _ = RefreshPhoneOverviewAsync(probe: true);
    }

    private void RenderExportGame(StackPanel body)
    {
        var game = SelectedGame;
        body.Children.Add(Action("export.back", () => Navigate("library")));
        if (game is null || connectedFolder is null || libraryId is null) { body.Children.Add(Label(T("export.no_game"), 18)); return; }
        var head = new StackPanel { Spacing = 4 };
        head.Children.Add(Label(T("export.page.title").Replace("{0}", game.Name), 26));
        head.Children.Add(Muted(game.Version.Length == 0 ? T("export.version_unknown") : T("library.version") + " · " + game.Version, 13));
        body.Children.Add(head);
        if (exportRuns.TryGetValue(game.Id, out var run)) RenderExportRun(body, game, run);
        else RenderExportForm(body, game);
    }

    private Control ExportStep(string titleKey, Control content, string? id = null)
    {
        var box = new StackPanel { Spacing = 10 };
        box.Children.Add(Label(T(titleKey), 16));
        box.Children.Add(content);
        var card = Card(box, 18);
        if (id is not null) AutomationId(card, id);
        return card;
    }

    /// <param name="recommended">作业层按签名推荐的那种出法：后面加「· 推荐」（走查：新手看不懂两种出法该选哪个）</param>
    private RadioButton ExportOption(string group, string textKey, bool on, bool enabled, Action pick, string id, bool recommended = false)
    {
        var radio = new RadioButton { GroupName = group, Content = new TextBlock { Text = T(textKey) + (recommended ? " · " + T("export.layout.recommended") : ""), TextWrapping = TextWrapping.Wrap, FontSize = 14 },
            IsChecked = on, IsEnabled = enabled, Foreground = Ink };
        radio.IsCheckedChanged += (_, _) => { if (radio.IsChecked == true && !on) { pick(); Dispatcher.UIThread.Post(Render); } };
        AutomationId(radio, id);
        return radio;
    }

    private void RenderExportForm(StackPanel body, LibraryGame game)
    {
        var sign = ExportSign; var lay = ExportLayout(game);

        // ① 怎么签名：我的证书只在导入过证书时可选
        var signs = new StackPanel { Spacing = 6 };
        signs.Children.Add(ExportOption("exportSign", "export.sign.option.appleId", sign == ExportChoice.AppleId, true, () => exportSignPick = ExportChoice.AppleId, "exportgame.sign.appleId"));
        if (sign == ExportChoice.AppleId)
        {   // Apple ID 在随包 Impactor 里登录（密码不经过 S2Arm）：走查里第一次用的人不知道要先登录，装到一半才报「还没登录 Apple ID」
            var hint = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(28, -4, 0, 0) };
            hint.Children.Add(new TextBlock { Text = T("export.sign.option.appleId.note"), FontSize = 12, Foreground = Brush.Parse("#A8A6A1"), TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
            hint.Children.Add(InlineButton("action.open_impactor", OpenBundledImpactor, "exportgame.open_impactor", File.Exists(BundledImpactor)));
            signs.Children.Add(hint);
        }
        signs.Children.Add(ExportOption("exportSign", "export.sign.option.devCert", sign == ExportChoice.DevCert, CertImported, () => exportSignPick = ExportChoice.DevCert, "exportgame.sign.devCert"));
        if (!CertImported)
        {   // 没导入证书：就地导入（走查：原先只写「去设置里导入」，买了 P12 的人要自己翻设置页）
            var none = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(28, -4, 0, 0) };
            none.Children.Add(new TextBlock { Text = T("export.sign.option.devCert.none2"), FontSize = 12, Foreground = Brush.Parse("#8A8A92"), TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
            none.Children.Add(InlineButton("export.sign.option.devCert.import", () => _ = ImportCertForExportAsync(), "exportgame.import_cert"));
            signs.Children.Add(none);
        }
        signs.Children.Add(ExportOption("exportSign", "export.sign.option.none", sign == ExportChoice.SelfSign, true, () => exportSignPick = ExportChoice.SelfSign, "exportgame.sign.none"));
        body.Children.Add(ExportStep("export.page.sign", signs, "exportgame.sign"));

        // ② 出法：通用 S2Arm 里的一款 / 独立 App；下面一行按签名给的提示（同出法卡片下方那一行，LayoutNote）
        var lays = new StackPanel { Spacing = 6 };
        lays.Children.Add(ExportOption("exportLayout", "export.layout.option.shell", lay == "shell", true, () => exportLayoutPick = "shell", "exportgame.layout.shell", layoutRecommend == "shell"));
        lays.Children.Add(ExportOption("exportLayout", "export.layout.option.standalone", lay == "standalone", true, () => exportLayoutPick = "standalone", "exportgame.layout.standalone", layoutRecommend == "standalone"));
        // 选了独立 App：按 ① 这次选的签名方式给提示（作业 standaloneHints；显式 App ID 的描述文件只允许一个包名，装一款会顶掉前一款）；选通用 S2Arm 不出
        //   通用 S2Arm 只留一种：用分发证书签通用 S2Arm（游戏打不开），照设置页出法卡同一句
        var shellWarn = lay == "shell" && sign == ExportChoice.DevCert && layoutRecommendWhy == "distribution" ? ("layout.card.warn.distShell", "#FF9F0A") : ((string, string)?)null;
        if ((ExportChoice.StandaloneNote(standaloneHints, sign, lay) ?? shellWarn) is { } note)
        {
            var line = new TextBlock { Text = T(note.Key), TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Brush.Parse(note.Color) };
            AutomationId(line, "exportgame.layout.note");
            lays.Children.Add(line);
        }
        body.Children.Add(ExportStep("export.page.layout", lays, "exportgame.layout"));

        // ③ 导到哪：每台一行「类型 · 名字　这款状态」，可勾规则见 ExportChoice.Row；默认都不勾
        var devices = new StackPanel { Spacing = 8 };
        var rows = ExportRows(game, sign, lay);
        if (rows.Count == 0) devices.Children.Add(Muted(T(exportProbing ? "export.page.devices.checking" : "export.page.devices.none"), 13));
        foreach (var r in rows)
        {
            var on = r.Checkable && exportPicked.Contains(r.Device);
            var text = new StackPanel { Spacing = 2, Opacity = r.Checkable ? 1 : 0.6 };   // 勾不了的那台整行淡一号（框本身禁用时已变灰，文字颜色是自设的不会跟着变）
            var line = new WrapPanel { Orientation = Orientation.Horizontal };
            line.Children.Add(new TextBlock { Text = ExportDeviceLabel(r.Kind, r.Name, r.Device), FontSize = 14, Foreground = Ink, Margin = new Thickness(0, 0, 12, 0) });
            line.Children.Add(new TextBlock { Text = T(r.GameKey), FontSize = 13, Foreground = Brush.Parse(r.GameKey == "export.device.game.latest" ? "#30D158" : r.GameKey == "export.device.game.old" ? "#FF9F0A" : "#A0A0A8") });
            text.Children.Add(line);
            var device = r.Device;
            var box = new CheckBox { Content = text, IsChecked = on, IsEnabled = r.Checkable, VerticalAlignment = VerticalAlignment.Top };
            box.IsCheckedChanged += (_, _) => { if (box.IsChecked == true) exportPicked.Add(device); else exportPicked.Remove(device); Dispatcher.UIThread.Post(Render); };
            AutomationId(box, "exportgame.device." + r.Device);
            var row = new StackPanel { Spacing = 2 };
            row.Children.Add(box);
            if (r.NoteKey is { } nk)
            {
                // 行内提示在勾选框下面、缩进对齐设备名；「去 S2Arm 卡」紧跟在这句黄字后面（同一行），一看就是这一台的（原先浮在整块右侧、上下居中，看不出属于哪行）。
                //   按钮不放进勾选框的内容里：点它不会顺手勾上这台
                var noteRow = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(32, 0, 0, 0), Opacity = r.Checkable ? 1 : 0.6 };
                var noteText = new TextBlock { Text = T(nk), FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center,
                    Foreground = Brush.Parse(r.Checkable ? "#FFD60A" : "#8A8A92"), Margin = new Thickness(0, 0, 10, 0) };
                AutomationId(noteText, "exportgame.note." + r.Device);
                noteRow.Children.Add(noteText);
                if (r.ConsoleLink)
                {
                    var link = new Button { Content = T("export.device.openConsole"), FontSize = 12, Padding = new Thickness(10, 3), CornerRadius = new CornerRadius(6),
                        Background = Brush.Parse("#29292D"), Foreground = Ink, VerticalAlignment = VerticalAlignment.Center };
                    link.Click += (_, _) => OpenConsoleFor(device);
                    AutomationId(link, "exportgame.console." + r.Device);
                    noteRow.Children.Add(link);
                }
                row.Children.Add(noteRow);
            }
            devices.Children.Add(row);
        }
        var foot = new WrapPanel { Orientation = Orientation.Horizontal };
        foot.Children.Add(new TextBlock { Text = (exportProbing && rows.Count > 0 ? "⟳ " + T("export.page.devices.checking") + "　" : "") + T("export.page.devices.note"),
            FontSize = 12.5, Foreground = Brush.Parse("#A8A6A1"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0), TextWrapping = TextWrapping.Wrap });
        var again = Action("export.page.devices.refresh", () => _ = ProbeExportDevicesAsync(), !exportProbing);
        foot.Children.Add(again);
        devices.Children.Add(foot);
        body.Children.Add(ExportStep("export.page.devices", devices, "exportgame.devices"));

        // 没做好 iPhone 版：写明开始后会先在电脑上做好（不擅自开始）
        var picked = rows.Count(r => r.Checkable && exportPicked.Contains(r.Device));
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), ColumnSpacing = 12 };
        if (ExportChoice.NeedsPack(game.IphoneReady, game.IphoneExportable, picked))
        {
            var prep = new TextBlock { Text = T("export.page.prepare"), FontSize = 13, Foreground = Brush.Parse("#FFD60A"), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
            AutomationId(prep, "exportgame.prepare");
            bar.Children.Add(prep);
        }
        var cancel = Action("action.cancel", () => Navigate("library"));
        cancel.VerticalAlignment = VerticalAlignment.Center;
        AutomationId(cancel, "exportgame.cancel");
        Grid.SetColumn(cancel, 1); bar.Children.Add(cancel);
        // 按钮写这次会做什么：都不勾 =「导出到文件夹」，勾了 =「装到勾选的 N 台」（走查：只写「开始」，没勾设备的人不确定点了会怎样）
        var start = Primary(picked == 0 ? T("export.page.start.folder") : T("export.page.start.devices").Replace("{0}", picked.ToString()), () => _ = StartExportAsync(game),
            !PhoneBlockedFor(game) && game.LocationState is not ("missing" or "offline") && !SGradeUpgrading(game));
        AutomationId(start, "exportgame.start");
        Grid.SetColumn(start, 2); bar.Children.Add(start);
        body.Children.Add(Card(bar, 18));
    }

    private void RenderExportRun(StackPanel body, LibraryGame game, ExportRun run)
    {
        var signName = T(run.Sign switch { ExportChoice.DevCert => "export.sign.option.devCert", ExportChoice.SelfSign => "export.sign.option.none", _ => "export.sign.option.appleId" });
        var layName = T(run.Layout == "standalone" ? "export.layout.option.standalone" : "export.layout.option.shell");
        body.Children.Add(Muted(signName + " · " + layName, 13));
        var box = new StackPanel { Spacing = 12 };
        if (run.Packing || run.PackError.Length > 0)
        {
            var line = new TextBlock { Text = run.Packing ? "⟳ " + T("export.run.packing") : T("export.run.packFailed").Replace("{0}", B(run.PackError)),
                FontSize = 14, TextWrapping = TextWrapping.Wrap, Foreground = run.Packing ? Ink : Brush.Parse("#FF9F0A") };
            AutomationId(line, "exportgame.packing");
            box.Children.Add(line);
            if (packGame?.Id == game.Id) box.Children.Add(Action("export.run.viewPack", () => Navigate("progress")));
        }
        else if (run.Devices.Count == 0)
        {
            // 导出到文件夹：同原「导出自签包」的结局卡（导出文件夹可点、怎么自签安装；成功时已自动打开文件夹）
            if (installExport && installGameId == game.Id && installState != "") { if (!installBusy) installSeen = true; box.Children.Add(LiveSlot(() => InstallStateCard(game, showsOperation: false))); }
            else box.Children.Add(Muted(T("export.row.waiting"), 14));
        }
        else box.Children.Add(LiveSlot(() => ExportRunRows(game, run)));   // 推的进度事件只刷新这一格
        body.Children.Add(Card(box));
        // 独立 App 成功了：说清之前独立 App 里的存档怎么搬（普通说明文字，签名方式不论）
        if (ExportChoice.ShowsStandaloneSaveCarry(run.Layout, run.Rows.Values.Select(r => r.State)))
        {
            var carry = Muted(T("export.done.standaloneSaveCarry"), 13);
            AutomationId(carry, "exportgame.saveCarry");
            body.Children.Add(carry);
        }
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
        var done = Action(run.Active ? "export.running.back" : "export.run.done", () => Navigate("library"));   // 还在做时写「回到游戏库，后台继续」，不写「完成」
        done.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(done);
        var again = Action("export.run.again", () => OpenExport(game), !run.Active);
        AutomationId(again, "exportgame.again");
        buttons.Children.Add(again);
        body.Children.Add(buttons);
    }

    /// <summary>逐台结果：每台一行（名字 | 状态 | 重试 / 去 S2Arm 卡）；在推的那台写作业当前步骤与计数</summary>
    private Control ExportRunRows(LibraryGame game, ExportRun run)
    {
        var list = new StackPanel { Spacing = 10 };
        foreach (var device in run.Devices)
        {
            var (state, message, code) = run.Rows.GetValueOrDefault(device, ("waiting", "", null));
            var pushing = state == "waiting" && PhonePushing(game.Id) && installDevice == device;
            var (text, color) = state switch
            {
                "waiting" when pushing => ("⟳ " + (installMessage.Length > 0 ? B(installMessage) : T("export.row.running")) + (PhoneProgressText() is { Length: > 0 } pct ? " · " + pct : ""), "#F2F0EB"),
                "waiting" => (T("export.row.waiting"), "#A0A0A8"),
                "succeeded" => ("✓ " + T("export.row.done") + (run.Layout == "standalone" ? " · " + T("app.done.open").Replace("{0}", game.Name) : ""), "#30D158"),   // 独立 App：说清去主屏幕点哪个图标
                "needsPlayer" => (B(message), "#FFD60A"),
                "cancelled" => (T("phone.cancelled"), "#A0A0A8"),
                _ => ("✕ " + (message.Length > 0 ? B(message) : T("export.row.failed")), "#FF9F0A"),
            };
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 14 };
            row.Children.Add(new TextBlock { Text = ExportDeviceLabel(device), FontSize = 14, Foreground = Ink, MinWidth = 180, VerticalAlignment = VerticalAlignment.Center });
            var status = new TextBlock { Text = text, FontSize = 13, Foreground = Brush.Parse(color), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
            AutomationId(status, "exportgame.row." + device);
            Grid.SetColumn(status, 1); row.Children.Add(status);
            if (state is not ("waiting" or "succeeded" or "needsPlayer"))
            {
                var acts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
                if (code is "shell_install_required" or "shell_update_required") acts.Children.Add(Action("export.device.openConsole", () => OpenConsoleFor(device)));
                if (code is "apple_not_signed_in" or "apple_session_expired") acts.Children.Add(Action("action.open_impactor", OpenBundledImpactor, File.Exists(BundledImpactor)));   // 登录好点「重试」
                var retry = Action("phone.retry", () => { RunExportRow(run, game, device, chain: false); Render(); }, !PhonePushing(game.Id) || installDevice != device);
                AutomationId(retry, "exportgame.retry." + device);
                acts.Children.Add(retry);
                Grid.SetColumn(acts, 2); row.Children.Add(acts);
            }
            list.Children.Add(row);
        }
        return list;
    }

    /// <summary>行内小按钮（跟在一句说明后面）</summary>
    private Button InlineButton(string key, Action click, string id, bool enabled = true)
    {
        var b = new Button { Content = T(key), FontSize = 12, Padding = new Thickness(10, 3), CornerRadius = new CornerRadius(6), IsEnabled = enabled,
            Background = Brush.Parse("#29292D"), Foreground = Ink, VerticalAlignment = VerticalAlignment.Center };
        b.Click += (_, _) => click();
        AutomationId(b, id);
        return b;
    }

    /// <summary>导出确认页「导入证书…」：同设置里的导入弹窗；导好了这次就选「我的证书」</summary>
    private async Task ImportCertForExportAsync()
    {
        await ImportDevCertAsync();
        if (CertImported) exportSignPick = ExportChoice.DevCert;
        Render();
    }

    /// <summary>列表卡片 / 「建议更新」角标点了：选中这款，滚回顶部看大卡（更新按钮在那里）</summary>
    private void SelectGame(LibraryGame game)
    {
        libraryFolder = libraryFolderBox.Text ?? libraryFolder;
        selectedGame = game.Id;
        pageScroll.Offset = default;
        if (page != "library") Navigate("library"); else Render();
    }

    /// <summary>角标点击：按下就处理并吃掉事件（不冒泡到外面的封面按钮、卡片）</summary>
    private void ClickToSelect(Control control, LibraryGame game)
    {
        control.Cursor = new Cursor(StandardCursorType.Hand);
        control.PointerPressed += (_, e) => { e.Handled = true; SelectGame(game); };
    }
}
