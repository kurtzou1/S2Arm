// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// <summary>
/// 0.6.0 iPhone 总控台（通用壳开关后面；同 Mac LauncherView+PhoneConsole / S2ArmLauncherModel+PhoneConsole，《0.6.0 极简流程》界面一节）：
/// 游戏库列表第一行固定「S2Arm」（不算进游戏数），选中它时上方大图区换成这台手机的总控台。开关关着 phoneOverview 为 null，什么都不出。
/// 本段接 ① 手机与 App、② 游戏同步、⑥ 帮助；③④⑤ 等对应作业进 main 后接。不加门、不加锁：要手机的按钮只在没连时灰并就近写原因。
/// </summary>
public sealed partial class EnvironmentWindow
{
    private const string ConsoleId = "s2arm.console";
    private PhoneOverview? phoneOverview;
    private string? consoleDevice;
    private readonly HashSet<string> consoleSelection = new(StringComparer.OrdinalIgnoreCase);
    private HashSet<string> consoleSeeded = new(StringComparer.OrdinalIgnoreCase);
    private FrontJob? consoleJob;                 // 「更新所选」那一单（作业 pushSelected）；null = 没在更新
    private int consoleDone, consoleTotal;        // 这一轮推完几款 / 共几款（作业 progress 事件 done / total）
    private string? consolePushing;               // 正在推的那款（progress 事件 current）
    // 「把签名身份交给手机」（作业 phoneIdentity）：这一单的状态（running / succeeded / failed / cancelled…）、失败原因与诊断、成功时 delivered
    private readonly PhoneJobTrack identityTrack = new();
    private string identityState = "", identityMessage = "", identityDiagnostics = "";
    private bool identityDelivered;
    // 「选用哪个 S2Arm」（作业 phoneChooseApp；同 Mac consoleChoosing / consoleChooseError / consoleRechoose）：正在记的包名、上一次没选成的原因（作业层原句）、选过了又点了「换一个」
    private string? consoleChoosing;
    private string consoleChooseError = "";
    private bool consoleRechoose;
    /// <summary>推送失败「装着不止一个 S2Arm、还没选」（phone_app_choice_required，诊断 facts {device, candidates}）：失败的那一页就地列候选，
    /// 选好（phoneChooseApp 成功）自动重推刚才那一次（同一台、同样的游戏）。installChoice = 推单款那页；consolePushChoice = 总控台「更新所选」</summary>
    private sealed record PushChoice(string Device, IReadOnlyList<PhoneOverview.Candidate> Candidates, string Message, Func<Task> Retry);
    private PushChoice? installChoice, consolePushChoice;
    /// <summary>「更新所选」没走成（作业层 #1756 整单按失败报；同 Mac pushSelected 失败页）：② 区写清每一款名字 + 原因（作业层原句）、给「重试」。
    /// Games = 逐款失败（PhoneOverview.PushFailures）；整轮停时为空，只写作业原因。Retry 只推没成的那几款、同一台</summary>
    private sealed record PushFailed(string Device, string Message, IReadOnlyList<PhoneOverview.PushFailure> Games, Func<Task> Retry);
    private PushFailed? consolePushFailed;
    private bool ConsoleUpdating => consoleJob is not null;
    private bool ConsoleSelected => phoneOverview is not null && selectedGame == ConsoleId;
    private PhoneOverview.Phone? ConsolePhone => phoneOverview?.Pick(consoleDevice);

    private async Task RefreshPhoneOverviewAsync(bool probe = false)
    {
        try
        {
            var extra = probe ? new Dictionary<string, object?> { ["probe"] = true } : null;
            if (extra is not null && consoleDevice is { Length: > 0 } d) extra["device"] = d;   // 带上总控台当前这台
            var job = await PackJobClient.RunAsync(PackRequest("phoneOverview", "", extra), null, CancellationToken.None);
            // 作业没成（现查超时、作业层报错）：保持上次的值（同 Mac loadPhoneOverview 失败只记日志）。原先置空，首位 S2Arm 行和总控台
            //   整块消失、页面跳回第一款；成功但作业层说开关关着 / 没有 phones 时 Parse 给 null，那才是真没有
            if (job.Report.Succeeded) phoneOverview = PhoneOverview.Parse(job.Report.Result);
            else Console.Error.WriteLine($"S2Arm phoneOverview: {job.Report.State} {job.Report.FailureCode} {job.Report.Message}");
            if (phoneOverview is not null && phoneOverview.Phones.All(p => p.Device != consoleDevice)) consoleDevice = null;
            SeedConsoleSelection();
        }
        // 读不到不弹框（首位卡是附带的入口），但不吞：记日志，保持上次的值
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("S2Arm phoneOverview: " + error.Message); }
        Render();
    }

    /// <summary>建议更新的默认勾上；玩家取消的不重勾，直到它的状态变了（同 Mac seedConsoleSelection）</summary>
    private void SeedConsoleSelection()
    {
        var suggested = (ConsolePhone?.Games ?? []).Where(g => g.State == PhoneOverview.GameState.Suggested).Select(g => g.GameId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var id in suggested.Except(consoleSeeded)) consoleSelection.Add(id);
        consoleSeeded = suggested;
    }

    /// <summary>手机在切换 / 页顶的叫法：有名字用名字；Windows 经 usbmuxd 读不到名字（AltStore 装的、没设备记录的那台），
    ///   原先直接写 40 位 UDID——改成「iPhone · 编号末 6 位」（同装机报错「编号末尾 XXXXXX」的口径，多台时还分得开）</summary>
    private static string PhoneLabel(PhoneOverview.Phone p) =>
        p.Name.Length > 0 ? p.Name : "iPhone · " + (p.Device.Length > 6 ? p.Device[^6..] : p.Device).ToUpperInvariant();

    private string Tf(string key, params object[] args) =>
        args.Select((a, i) => (a, i)).Aggregate(T(key), (s, x) => s.Replace("{" + x.i + "}", x.a is DateTimeOffset d ? d.LocalDateTime.ToString("g") : x.a.ToString()));

    private string ConsoleStatusText()
    {
        var (key, args) = PhoneOverview.Status(ConsolePhone, DateTimeOffset.Now, consoleDone, ConsoleUpdating ? Math.Max(consoleTotal, 1) : 0);
        // 「没连 iPhone」那两句写这台的类型（#1962：iPad 不写 iPhone），类型接在参数最后（notConnected 的 {1}、notConnectedNever 的 {0}）
        if (key.StartsWith("console.status.notConnected", StringComparison.Ordinal)) args = [.. args, SharedText.DeviceKind(ConsolePhone?.Kind)];
        return Tf(key, args);
    }

    /// <summary>「更新所选」/「推所选到 iPhone」（RunConsoleAction）：一单作业 pushSelected 按游戏库顺序推总控台这台（同 Mac updateSelected）。作业层一款失败接着推下一款，
    /// 换哪款都做不下去（没装 App / 手机断开）才整轮停；「停下」= 取消这一单，推完的留着</summary>
    /// <param name="resume">失败页「重试」且不知道逐款结果（整轮停）：按作业续推（没推到的 + 失败的），order 只作款数</param>
    private async Task PushSelectedAsync(IReadOnlyList<string> order, string device, bool resume = false)
    {
        if (QueuePhone(null, () => PushSelectedAsync(order, device, resume))) return;   // 手机上有作业在跑 → 排队
        var front = BeginJob(JobKind.Phone); consoleJob = front; consoleDone = 0; consoleTotal = order.Count; consolePushing = null; consolePushChoice = null; consolePushFailed = null;
        var state = "running";
        Render();
        try
        {
            var extra = resume ? new Dictionary<string, object?> { ["resume"] = true, ["device"] = device }
                : new Dictionary<string, object?> { ["gameIds"] = order.ToArray(), ["device"] = device };
            var job = await PackJobClient.RunAsync(PackRequest("pushSelected", "", extra), e => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
            {
                // 款数只认带 current（正在推的游戏号）的那条（pack/jobs/install.py push_selected 每款开头发 done = 已推款数、total = 款数）：
                //   推单款时作业里还有逐文件 / 字节的计数，原先也读成款数，界面写「正在更新 5307 / 5367 款」（D-4MPR）。同 Mac consoleProgress 只按每款一步算
                if (e.TryGetProperty("current", out var c) && c.ValueKind == System.Text.Json.JsonValueKind.String)
                {
                    consolePushing = c.GetString()?.ToUpperInvariant();
                    if (e.TryGetProperty("done", out var d) && d.ValueKind == System.Text.Json.JsonValueKind.Number) consoleDone = d.GetInt32();
                    if (e.TryGetProperty("total", out var t) && t.ValueKind == System.Text.Json.JsonValueKind.Number && t.GetInt32() > 0) consoleTotal = t.GetInt32();
                }
                Render();
            }), front.Token, front.Next());
            state = job.Report.State;
            if (!job.Report.Succeeded && PhoneOverview.ChoiceFacts(job.Report.Diagnostics) is { } choice)
                consolePushChoice = new PushChoice(choice.Device, choice.Candidates, job.Report.Message, () => PushSelectedAsync(order, device, resume));
            else if (state is "failed" or "interrupted" or "invalid")
            {   // 有款没推成：逐款原因写在 ② 区，「重试」只推没成的那几款（不知道逐款 = 整轮停 → 续推）
                var failed = PhoneOverview.PushFailures(job.Report.Diagnostics);
                var again = PhoneOverview.RetryOrder(failed);
                consolePushFailed = new PushFailed(device, job.Report.Message.Length > 0 ? job.Report.Message : state, failed,
                    () => again is not null ? PushSelectedAsync(again, device) : PushSelectedAsync(order, device, resume: true));
            }
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception)
        {
            state = error is OperationCanceledException ? "cancelled" : "failed"; Console.Error.WriteLine("S2Arm pushSelected: " + error.Message);
            if (state == "failed")   // 启动器这头没跑起来：同一页写原因，「重试」照原样再推一次
                consolePushFailed = new PushFailed(device, error.Message.Length > 0 ? error.Message : error.GetType().Name, [], () => PushSelectedAsync(order, device, resume));
        }
        finally { EndJob(front); consoleJob = null; consolePushing = null; DynamicFinished(state); Render(); }
        await RefreshPhoneOverviewAsync();
    }

    /// <summary>「把签名身份交给手机」：作业 phoneIdentity 把这台电脑的签名身份交给总控台这台手机上的 S2Arm（别的工具装的团队对得上也交；同 Mac phoneIdentity）。
    /// 成功记下 delivered（完成提示分「交好了」/「已经有了」）；失败用手机作业结局卡（PhoneJobCard：原因 + 下一步 + 复制错误摘要）</summary>
    private async Task PhoneIdentityAsync(string device, bool force = false)
    {
        if (connectedFolder is null || libraryId is null) return;
        if (QueuePhone(null, () => PhoneIdentityAsync(device, force))) return;   // 手机上有作业在跑 → 排队
        var front = BeginJob(JobKind.Phone);
        identityTrack.Begin("phoneIdentity", ConsolePhone is { Name.Length: > 0 } p ? p.Name : device);
        identityState = "running"; identityMessage = identityDiagnostics = ""; identityDelivered = false;
        Render();
        try
        {
            var extra = new Dictionary<string, object?> { ["device"] = device };
            if (force) extra["force"] = true;
            var job = await PackJobClient.RunAsync(PackRequest("phoneIdentity", "", extra),
                e => Avalonia.Threading.Dispatcher.UIThread.Post(() => { identityTrack.Ingest(e); Render(); }), front.Token, front.Next());
            identityTrack.Finish(job, GameName);
            identityState = job.Report.State;
            if (job.Report.Succeeded)
                identityDelivered = job.Report.Result.ValueKind == System.Text.Json.JsonValueKind.Object && job.Report.Result.TryGetProperty("delivered", out var d) && d.ValueKind == System.Text.Json.JsonValueKind.True;
            else { identityMessage = job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State; identityDiagnostics = JobDiagnostics(job); }
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception)
        { identityMessage = error.Message.Length > 0 ? error.Message : error.GetType().Name; identityState = error is OperationCanceledException ? "cancelled" : "failed"; identityTrack.Ended = DateTime.UtcNow; }
        finally { EndJob(front); DynamicFinished(identityState); Render(); }
    }

    /// <summary>「选用哪个 S2Arm」：作业 phoneChooseApp 核对它确在这台手机上后记进设备记录；成没成都重新现查总览（选的已不在 → 列表跟着变）。同 Mac chooseApp。
    /// 选成了、这台手机有推送因「还没选」停着（installChoice / consolePushChoice）：接着重推那一次</summary>
    private async Task ChooseAppAsync(string device, string bundleId)
    {
        if (consoleChoosing is not null) return;
        consoleChoosing = bundleId; consoleChooseError = "";
        Render();
        var chosen = false;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("phoneChooseApp", "", new Dictionary<string, object?> { ["device"] = device, ["bundleId"] = bundleId }), null, CancellationToken.None);
            if (job.Report.Succeeded) { consoleRechoose = false; chosen = true; }
            else consoleChooseError = job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception)
        { consoleChooseError = error.Message.Length > 0 ? error.Message : error.GetType().Name; }
        finally { consoleChoosing = null; }
        var retry = new List<Func<Task>>();
        if (chosen && installChoice?.Device == device) { retry.Add(installChoice.Retry); installChoice = null; }
        if (chosen && consolePushChoice?.Device == device) { retry.Add(consolePushChoice.Retry); consolePushChoice = null; }
        await RefreshPhoneOverviewAsync(probe: true);
        foreach (var again in retry) await again();
    }

    /// <summary>① 手机与 App 里的「选用哪个 S2Arm」：按作业给的顺序（包名排序）列出每一个，每个一颗按钮；只写事实（谁装的、证书导没导、团队号），不推荐。选过的再点「换一个」也到这里。
    /// 推送失败页（推单款、更新所选）也用它就地列候选
    /// pick：点了哪个包名怎么办；缺省走总控台按钮（RunConsoleAction，核对总览候选）。推单款失败页传 ChooseAppAsync（候选来自失败事实，不靠总览）</summary>
    private Control ConsoleChooser(PhoneOverview.Phone phone, bool offline, Action<string>? pick = null)
    {
        var box = new StackPanel { Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
        box.Children.Add(WrappedMuted(Tf("console.choose.title", SharedText.DeviceKind(phone.Kind)), 12.5));
        foreach (var c in phone.Candidates ?? [])
        {
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(new TextBlock { Text = (consoleChoosing == c.BundleId ? "⟳ " : "") + string.Join(" · ", PhoneOverview.CandidateLabelKeys(c).Select(T)), Foreground = Ink, FontSize = 13 });
            text.Children.Add(Muted(c.BundleId + (c.Team.Length > 0 ? " · " + Tf("console.choose.team", c.Team) : ""), 11));
            var button = new Button { Content = text, IsEnabled = !offline && consoleChoosing is null && !installBusy, Padding = new Thickness(16, 9),
                Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
            var bid = c.BundleId;
            button.Click += (_, _) => { if (pick is not null) pick(bid); else RunConsoleAction(PhoneOverview.Act.ChooseApp, phone.Device, bundleId: bid); };
            Avalonia.Automation.AutomationProperties.SetAutomationId(button, "console.chooseApp." + bid);
            box.Children.Add(button);
        }
        if (offline) box.Children.Add(new TextBlock { Text = Tf("console.offline", phone.Name.Length > 0 ? phone.Name : SharedText.DeviceKind(phone.Kind), SharedText.DeviceKind(phone.Kind)), Foreground = Brush.Parse("#FF9F0A"), FontSize = 12 });
        if (consoleChooseError.Length > 0) box.Children.Add(new TextBlock { Text = B(consoleChooseError), Foreground = Brush.Parse("#FF9F0A"), FontSize = 12, TextWrapping = TextWrapping.Wrap });
        if (!phone.NeedsChoice) box.Children.Add(Action("console.choose.cancel", () => { consoleRechoose = false; consoleChooseError = ""; Render(); }));
        Avalonia.Automation.AutomationProperties.SetAutomationId(box, "console.chooseApp");
        return box;
    }

    /// <summary>① 手机与 App 里的「把签名身份交给手机」（次要按钮 + 一行说明 + 进行中 / 完成提示 / 失败卡）</summary>
    private Control ConsoleIdentity(PhoneOverview.Phone phone, bool offline)
    {
        var box = new StackPanel { Spacing = 6, Margin = new Thickness(0, 6, 0, 0) };
        var running = identityState == "running";
        box.Children.Add(Action("console.button.identity", () => _ = PhoneIdentityAsync(phone.Device), !offline && !running));
        box.Children.Add(WrappedMuted(T("console.identity.note"), 12));
        if (running) box.Children.Add(new TextBlock { Text = "⟳ " + T("phone.status.running.phoneIdentity"), Foreground = Ink, FontSize = 12.5 });
        else if (identityState == "succeeded")
        {
            var done = new TextBlock { Text = T(identityDelivered ? "console.identity.done" : "console.identity.already"), Foreground = Brush.Parse("#30D158"), FontSize = 13, TextWrapping = TextWrapping.Wrap };
            Avalonia.Automation.AutomationProperties.SetAutomationId(done, "console.identity.result");
            box.Children.Add(done);
        }
        else if (identityState.Length > 0) box.Children.Add(PhoneJobCard(identityTrack, identityState, identityMessage, identityDiagnostics, null, showsOperation: false));
        Avalonia.Automation.AutomationProperties.SetAutomationId(box, "console.identity");
        return box;
    }

    /// <summary>介绍卡「连上 iPhone 开始」（11-19 自签走查结构 5，同 Mac consoleIntroStart）：先现查连着的手机（probe）；手机上已有 S2Arm
    /// （别的工具装的 → 总控台「用别的工具装的」那套按钮；启动器装的 → 它自己的状态）就停在总控台、不装第二个；什么都没装（或查不出）才接着原来的装机</summary>
    private async Task ConsoleIntroStartAsync()
    {
        await RefreshPhoneOverviewAsync(probe: true);
        if (ConsolePhone is { InstalledBy: not null } found) { consoleDevice = found.Device; Render(); return; }
        await UpdatePhoneAsync(false, [], device: ConsolePhone?.Device, firstInstall: true);
    }

    /// <summary>点总控台按钮（界面与控制口 POST /console-action 走这同一个函数；同 Mac runConsoleAction）。ids：推 / 导出哪几款（控制口可给；不给 = 勾选的、按游戏库顺序）。
    /// bundleId：chooseApp 选哪一个（必须是这台手机的候选之一）。→ 没做的原因（null = 已发起）</summary>
    private string? RunConsoleAction(string action, string device, IReadOnlyList<string>? ids = null, string? bundleId = null)
    {
        var shown = (catalog?.Games ?? []).Where(g => !g.Hidden).ToList();
        var order = ids?.Select(i => i.ToUpperInvariant()).ToList() ?? shown.Where(g => consoleSelection.Contains(g.Id)).Select(g => g.Id.ToUpperInvariant()).ToList();
        switch (action)
        {
            case PhoneOverview.Act.InstallShell:   // 第一次装：结局卡写「安装」，用 Apple ID 签的写清先信任再打开
                _ = UpdatePhoneAsync(false, [], device: device, firstInstall: true); break;
            case PhoneOverview.Act.UpdateShell or PhoneOverview.Act.RenewShell:
                _ = UpdatePhoneAsync(false, [], device: device); break;
            case PhoneOverview.Act.ExportShellIpa:   // 导出通用 S2Arm.ipa（作业 installUpdate + mode export → export_shell_ipa）：不连手机
                _ = UpdatePhoneAsync(false, [], mode: "export"); break;
            case PhoneOverview.Act.HandOverIdentity:
                _ = PhoneIdentityAsync(device); break;
            case PhoneOverview.Act.UpdateSelected or PhoneOverview.Act.PushS2arm:   // 别的工具装的也是同一单 pushSelected：作业层推未签名 .s2arm、手机自己签
                if (order.Count == 0) return "没选游戏";
                if (ConsoleUpdating) return "正在更新所选";
                _ = PushSelectedAsync(order, device); break;
            case PhoneOverview.Act.ExportS2arm:
                var picked = order.Select(id => shown.FirstOrDefault(g => string.Equals(g.Id, id, StringComparison.OrdinalIgnoreCase))).OfType<LibraryGame>().ToList();
                if (picked.Count == 0) return "没选游戏";
                foreach (var g in picked) ExportSelfSign(g);
                break;
            case PhoneOverview.Act.ChooseApp:
                var cands = phoneOverview?.Phones.FirstOrDefault(p => p.Device == device)?.Candidates ?? [];
                if (bundleId is null || cands.All(c => c.BundleId != bundleId)) return "bundleId 不在这台手机的候选里（此刻有：" + string.Join(" / ", cands.Select(c => c.BundleId)) + "）";
                if (consoleChoosing is not null) return "正在记下上一次的选择";
                _ = ChooseAppAsync(device, bundleId); break;
            default: return "不认识这个按钮";
        }
        return null;
    }

    private string ConsoleActionTitle(string action) => action switch
    {
        PhoneOverview.Act.InstallShell => T("console.button.install"),
        PhoneOverview.Act.UpdateShell => T("console.button.update"),
        PhoneOverview.Act.RenewShell => T("console.button.renew"),
        PhoneOverview.Act.ExportShellIpa => T("console.button.exportShellIpa"),
        PhoneOverview.Act.HandOverIdentity => T("console.button.identity"),
        PhoneOverview.Act.PushS2arm => Tf("console.button.pushS2arm", consoleSelection.Count),
        PhoneOverview.Act.ExportS2arm => Tf("console.button.exportS2arm", consoleSelection.Count),
        PhoneOverview.Act.ChooseApp => T("console.choose.change"),
        _ => Tf("console.updateSelected", consoleSelection.Count),
    };

    /// <summary>总控台按钮：文案按动作名取，自动化 id = console.&lt;动作名&gt;，点了走 RunConsoleAction</summary>
    private Button ConsoleButton(string action, string device, bool enabled, bool primary)
    {
        Button button;
        if (primary) button = Primary(ConsoleActionTitle(action), () => RunConsoleAction(action, device), enabled);
        else
        {   // 次要按钮同 Action 的样子（Action 按文案键取字，这里文案带勾选数，直接给字）
            button = new Button { Content = ConsoleActionTitle(action), IsEnabled = enabled, Padding = new Thickness(16, 9), Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
            button.Click += (_, _) => RunConsoleAction(action, device);
        }
        Avalonia.Automation.AutomationProperties.SetAutomationId(button, "console." + action);
        return button;
    }

    /// <summary>「停下」：取消这一单（推完的留着；没推完的那款下次续推）</summary>
    private void StopUpdateSelected() => consoleJob?.Cancellation.Cancel();

    /// <summary>游戏库列表第一行「S2Arm」</summary>
    private Control ConsoleRow()
    {
        var line = new Grid { ColumnDefinitions = new ColumnDefinitions("72,*,Auto"), ColumnSpacing = 18 };
        line.Children.Add(new Border { Width = 72, Height = 72, CornerRadius = new CornerRadius(12), Background = Brush.Parse("#202024"),
            Child = new TextBlock { Text = "📱 S2Arm", FontWeight = FontWeight.Bold, FontSize = 13, Foreground = Ink, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
        var detail = new StackPanel { Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        detail.Children.Add(Label(ConsolePhone is { } p && p.Name.Length > 0 ? p.Name : "S2Arm", 18));
        detail.Children.Add(Muted(ConsoleStatusText(), 13));
        Grid.SetColumn(detail, 1); line.Children.Add(detail);
        // 按钮写「打开」（走查：原先和游戏共用「选择这款游戏」，这一行是手机不是游戏）
        var open = Action("console.row.open", () => { selectedGame = ConsoleId; _ = RefreshPhoneOverviewAsync(probe: true); Render(); });
        AutomationId(open, "library.select");
        open.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(open, 2); line.Children.Add(open);
        Avalonia.Automation.AutomationProperties.SetAutomationId(line, "card." + ConsoleId);
        return Card(line, 14);
    }

    private Control ConsoleSection(string titleKey, Control content)
    {
        var box = new StackPanel { Spacing = 8 };
        box.Children.Add(Muted(T(titleKey), 12));
        box.Children.Add(content);
        return new Border { Background = Brush.Parse("#0DFFFFFF"), CornerRadius = new CornerRadius(12), Padding = new Thickness(16), Child = box };
    }

    /// <summary>选中首位时大图区的整页</summary>
    private Control ConsolePanel()
    {
        var phone = ConsolePhone;
        var page = new StackPanel { Spacing = 16 };
        if (phone is null)   // 只在 Mac / 电脑上玩的人：三句介绍 +「连上 iPhone 开始」，不出空表和灰按钮
        {
            page.Children.Add(Label(T("console.status.introduce"), 28));
            page.Children.Add(new TextBlock { Text = T("console.intro.body"), TextWrapping = TextWrapping.Wrap, MaxWidth = 620, Foreground = Ink });
            page.Children.Add(Primary(T("console.intro.start"), () => _ = ConsoleIntroStartAsync()));
            Avalonia.Automation.AutomationProperties.SetAutomationId(page, "console.intro");
            return Card(page, 24);
        }
        var offline = phone.KnownOffline;
        Control Offline() => new TextBlock { Text = Tf("console.offline", phone.Name.Length > 0 ? phone.Name : SharedText.DeviceKind(phone.Kind), SharedText.DeviceKind(phone.Kind)), Foreground = Brush.Parse("#FF9F0A"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };

        // 页顶：手机切换（多台）+ 状态；全部最新
        var head = new StackPanel { Spacing = 4 };
        if (phoneOverview!.Phones.Count > 1)
        {
            var pick = new ComboBox { ItemsSource = phoneOverview.Phones.Select(PhoneLabel).ToList(),
                SelectedIndex = phoneOverview.Phones.ToList().FindIndex(p => p.Device == phone.Device) };
            pick.SelectionChanged += (_, _) =>
            {   // 换了一台：现查它装了哪些 S2Arm
                if (pick.SelectedIndex < 0) return;
                consoleDevice = phoneOverview.Phones[pick.SelectedIndex].Device; consoleRechoose = false; consoleChooseError = "";
                SeedConsoleSelection(); Render(); _ = RefreshPhoneOverviewAsync(probe: true);
            };
            Avalonia.Automation.AutomationProperties.SetAutomationId(pick, "console.phonePicker");
            head.Children.Add(pick);
        }
        else head.Children.Add(Label(PhoneLabel(phone), 24));
        head.Children.Add(Muted(ConsoleStatusText(), 13));
        if (phone.Installed && phone.ShellCurrent && !phone.External && phone.Games.Count > 0 && phone.Games.All(g => g.State == PhoneOverview.GameState.Latest))
            head.Children.Add(new TextBlock { Text = "✓ " + T("console.allLatest"), Foreground = Brush.Parse("#30D158"), FontWeight = FontWeight.Bold });
        page.Children.Add(head);

        // ① 手机与 App：按钮集合与控制口 phoneConsole 同一个来源 PhoneOverview.Actions（启动器装的：安装 / 更新 / 续签 一颗；别的工具装的：导出 S2Arm.ipa）
        var actions = PhoneOverview.Actions(phone);
        var app = new StackPanel { Spacing = 8 };
        app.Children.Add(Label(ConsoleStatusText() + (phone.SignMode is { } m ? " · " + T("console.sign." + m) : "")));
        var pushChoice = consolePushChoice?.Device == phone.Device ? consolePushChoice : null;   // 「更新所选」因没选停着：候选列在 ② 失败处，这里不重复
        if (pushChoice is not null) { /* 候选在 ② */ }
        else if (phone.NeedsChoice || (consoleRechoose && (phone.Candidates?.Count ?? 0) > 1)) app.Children.Add(ConsoleChooser(phone, offline));
        else if ((phone.Candidates?.Count ?? 0) > 1)   // 选过了、装着不止一个：写正在用哪个 + 「换一个」
        {
            var cur = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            cur.Children.Add(new TextBlock { Text = Tf("console.choose.current", phone.BundleId), Foreground = Brush.Parse("#A0A0A8"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
            cur.Children.Add(Action("console.choose.change", () => { consoleChooseError = ""; consoleRechoose = true; Render(); }));
            app.Children.Add(cur);
        }
        if (phone.External) app.Children.Add(WrappedMuted(T("console.external.note"), 12));
        if (actions.FirstOrDefault(a => a is PhoneOverview.Act.InstallShell or PhoneOverview.Act.UpdateShell or PhoneOverview.Act.RenewShell or PhoneOverview.Act.ExportShellIpa) is { } appAction)
        {
            var appRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            var needsPhone = appAction != PhoneOverview.Act.ExportShellIpa;   // 导出 S2Arm.ipa 不连手机，没连也能点
            appRow.Children.Add(ConsoleButton(appAction, phone.Device, !(offline && needsPhone), primary: false));
            if (offline && needsPhone) appRow.Children.Add(Offline());
            app.Children.Add(appRow);
        }
        if (actions.Contains(PhoneOverview.Act.HandOverIdentity)) app.Children.Add(ConsoleIdentity(phone, offline));
        page.Children.Add(ConsoleSection("console.section.phone", app));

        // ①b 独立 App（一 App 一游戏，0.6.4；同 Mac consoleAppsSection）：每款一行——游戏名、包名、签名还剩几天 / 已到期、壳有新版时提示去「更新 iPhone 上的 S2Arm」
        if (phone.Apps is { Count: > 0 } standalone)
        {
            var list = new StackPanel { Spacing = 6 };
            Grid.SetIsSharedSizeScope(list, true);
            foreach (var sa in standalone)
            {
                // 名字 | 状态（吃剩余宽度、列内换行）| 续签：原先横排 StackPanel 不给子控件宽度上限，窄窗 / 英文时整行溢出卡片右边被裁（0.6.2 前端走查）
                var row = new Grid { ColumnSpacing = 10 };
                row.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Auto) { SharedSizeGroup = "consoleAppName" });   // 各行名字列同宽，状态列对齐
                row.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star)); row.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Auto));
                var names = new StackPanel { MinWidth = 180, MaxWidth = 320 };
                names.Children.Add(new TextBlock { Text = GameName(sa.GameId), Foreground = Ink, TextTrimming = TextTrimming.CharacterEllipsis });
                names.Children.Add(new TextBlock { Text = sa.BundleId, Foreground = Brush.Parse("#8A8A92"), FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis });
                row.Children.Add(names);
                var expired = sa.ExpiresAtEstimate is { } e0 && e0 <= DateTimeOffset.Now;
                var days = sa.ExpiresAtEstimate is { } e1 ? (int)Math.Ceiling((e1 - DateTimeOffset.Now).TotalDays) : (int?)null;
                var text = expired ? T("console.status.expired") : !sa.ShellCurrent ? T("console.app.outdated")
                    : days is null ? T("console.status.okNoDays") : days <= 2 ? Tf("console.status.expiring", days) : Tf("console.status.ok", days);
                var status = new TextBlock { Text = text, Foreground = Brush.Parse(sa.ShellCurrent && !expired ? "#30D158" : "#FF9F0A"), FontSize = 12.5,
                    TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(status, 1); row.Children.Add(status);
                // 续签：打开这款的导出确认页、预勾这一台（RenewApp）；游戏库里没有这款（删了）或这台不在线时置灰
                var owned = catalog?.Games.FirstOrDefault(g => string.Equals(g.Id, sa.GameId, StringComparison.OrdinalIgnoreCase));
                var renew = Action("console.app.renew", () => { if (owned is not null) RenewApp(owned, phone.Device); },
                    owned is not null && !offline && !PhonePushing(owned.Id) && !PhoneQueued(owned.Id));
                renew.VerticalAlignment = VerticalAlignment.Center;
                Avalonia.Automation.AutomationProperties.SetAutomationId(renew, "console.app.renew." + sa.GameId);
                Grid.SetColumn(renew, 2); row.Children.Add(renew);
                Avalonia.Automation.AutomationProperties.SetAutomationId(row, "console.app." + sa.GameId);
                list.Children.Add(row);
            }
            page.Children.Add(ConsoleSection("console.section.apps", list));
        }

        // ② 游戏同步
        var sync = new StackPanel { Spacing = 6 };
        Grid.SetIsSharedSizeScope(sync, true);
        // 0.5 → 0.6 升级后的老款（资源在、程序包不在：suggested + missing）排最上面、醒目标出，直到更新完（同 Mac consoleOrdered）
        PhoneOverview.Game RowOf(string id) => phone.Games.FirstOrDefault(x => string.Equals(x.GameId, id, StringComparison.OrdinalIgnoreCase))
                    ?? new PhoneOverview.Game(id.ToUpperInvariant(), PhoneOverview.GameState.NotPushed, [], null);
        static bool Legacy(PhoneOverview.Game g) => g.State == PhoneOverview.GameState.Suggested && g.Reasons.Contains("missing");
        var shown = (catalog?.Games ?? []).Where(g => !g.Hidden).ToList();
        foreach (var game in shown.Where(x => Legacy(RowOf(x.Id))).Concat(shown.Where(x => !Legacy(RowOf(x.Id)))))
        {
            var g = RowOf(game.Id);
            // 勾 | 游戏名（过长省略）| 状态（吃剩余宽度、列内换行）：原先横排 StackPanel，状态到 520px 才换行，窄窗 / 英文时溢出卡片被裁（同上）
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Auto));
            row.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Auto) { SharedSizeGroup = "consoleGameName" });   // 各行名字列同宽，状态列对齐
            row.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));
            var box = new CheckBox { IsChecked = consoleSelection.Contains(game.Id), IsEnabled = !ConsoleUpdating };
            box.IsCheckedChanged += (_, _) => { if (box.IsChecked == true) consoleSelection.Add(game.Id); else consoleSelection.Remove(game.Id); Render(); };
            row.Children.Add(box);
            var pushing = ConsoleUpdating && string.Equals(consolePushing, game.Id, StringComparison.OrdinalIgnoreCase);
            var name = new TextBlock { Text = (pushing ? "⟳ " : "") + game.Name, MinWidth = 180, MaxWidth = 320, Foreground = Ink, VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis };
            ToolTip.SetTip(name, game.Name);
            Grid.SetColumn(name, 1); row.Children.Add(name);
            var asApp = g.State == PhoneOverview.GameState.NotPushed && (phone.Apps ?? []).Any(x => string.Equals(x.GameId, game.Id, StringComparison.OrdinalIgnoreCase));
            var (text, color) = asApp ? (T("console.game.standalone"), "#C8C8CE") : Legacy(g) ? (T("console.legacy.badge"), "#FFC857") : g.State switch
            {
                PhoneOverview.GameState.Latest => (T("console.game.latest"), "#30D158"),
                PhoneOverview.GameState.Suggested => (T("update.hint.badge") + " · " + string.Join(" ", g.Reasons.Select(UpdateReasonKey).OfType<string>().Select(T)), "#FF9F0A"),
                PhoneOverview.GameState.NeedsData => (T(g.DataOnComputer == false ? "console.game.needsDataOriginal" : "console.game.needsData"), "#FFD60A"),
                _ => (T(g.DataOnComputer == false ? "console.game.notPushedNoData" : "console.game.notPushed"), "#A0A0A8"),
            };
            var state = new TextBlock { Text = text, Foreground = Brush.Parse(color), FontSize = 12.5, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(state, 2); row.Children.Add(state);
            Avalonia.Automation.AutomationProperties.SetAutomationId(row, "console.game." + game.Id.ToUpperInvariant());
            sync.Children.Add(row);
        }
        var run = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(0, 6, 0, 0) };
        if (!ConsoleUpdating)
        {
            // 启动器装的：更新所选；别的工具装的：推所选到 iPhone + 导出所选 .s2arm（导出不连手机，没连也能点）
            foreach (var a in actions.Where(a => a is PhoneOverview.Act.UpdateSelected or PhoneOverview.Act.PushS2arm or PhoneOverview.Act.ExportS2arm))
            {
                var push = a != PhoneOverview.Act.ExportS2arm;
                var enabled = consoleSelection.Count > 0 && !(push && offline);
                run.Children.Add(ConsoleButton(a, phone.Device, enabled, primary: push));
            }
            if (offline) run.Children.Add(Offline());
        }
        else
        {
            var done = consoleDone; var total = Math.Max(consoleTotal, 1);
            run.Children.Add(new ProgressBar { Minimum = 0, Maximum = Math.Max(total, 1), Value = done, Width = 240, VerticalAlignment = VerticalAlignment.Center });
            run.Children.Add(new TextBlock { Text = Tf("console.progress", Math.Min(done + 1, total), total) + (consolePushing is { } cur && catalog?.Games.FirstOrDefault(g => string.Equals(g.Id, cur, StringComparison.OrdinalIgnoreCase)) is { } cg ? " · " + cg.Name : ""), Foreground = Ink, VerticalAlignment = VerticalAlignment.Center });
            run.Children.Add(Action("console.stop", StopUpdateSelected));
        }
        sync.Children.Add(run);
        if (pushChoice is not null && !ConsoleUpdating)   // 「更新所选」失败：装着不止一个 S2Arm、还没选 → 就在这里选，选好自动接着推
        {
            sync.Children.Add(new TextBlock { Text = B(pushChoice.Message), Foreground = Brush.Parse("#FF9F0A"), FontSize = 12.5, TextWrapping = TextWrapping.Wrap });
            sync.Children.Add(ConsoleChooser(phone with { NeedsChoice = true, Candidates = pushChoice.Candidates }, offline, bid => _ = ChooseAppAsync(pushChoice.Device, bid)));
        }
        if (consolePushFailed is { } pushFailed && pushFailed.Device == phone.Device && !ConsoleUpdating)   // 「更新所选」有款没推成：每一款名字 + 原因、「重试」只推没成的
        {
            var fail = new StackPanel { Spacing = 4, Margin = new Thickness(0, 6, 0, 0) };
            var orange = Brush.Parse("#FF9F0A");
            fail.Children.Add(new TextBlock { Text = pushFailed.Games.Count > 0 ? Tf("console.pushFailed", pushFailed.Games.Count) : B(pushFailed.Message),
                Foreground = orange, FontWeight = FontWeight.Bold, TextWrapping = TextWrapping.Wrap });
            foreach (var g in pushFailed.Games)
                fail.Children.Add(new TextBlock { Text = GameName(g.GameId) + " · " + (g.Message.Length > 0 ? B(g.Message) : g.Code), Foreground = orange, FontSize = 12.5, TextWrapping = TextWrapping.Wrap });
            var retry = Action("phone.retry", () => _ = pushFailed.Retry(), enabled: !offline);
            Avalonia.Automation.AutomationProperties.SetAutomationId(retry, "console.pushRetry");
            var retryRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            retryRow.Children.Add(retry);
            if (offline) retryRow.Children.Add(Offline());
            fail.Children.Add(retryRow);
            Avalonia.Automation.AutomationProperties.SetAutomationId(fail, "console.pushFailed");
            sync.Children.Add(fail);
        }
        page.Children.Add(ConsoleSection("console.section.sync", sync));

        // ⑥ 帮助：重看第一次的引导、故障报修（同顶栏那颗）
        var help = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        help.Children.Add(Action("console.help.guide", () => { welcomeHome = true; Render(); }));
        help.Children.Add(Action("console.help.report", () => _ = UploadDiagnosticsAsync(null, null, () => "")));
        page.Children.Add(ConsoleSection("console.section.help", help));
        Avalonia.Automation.AutomationProperties.SetAutomationId(page, "console.panel");
        return Card(page, 24);
    }

    /// <summary>总控台独立 App 一行的「续签」：原先直接推到这台（单款装机）；0.6.4 起推只来自导出确认页，这里打开这款的导出确认页并预先勾上这一台
    ///   （确认页唯一的预勾例外：玩家点的就是「这台续签」；其余入口一律默认都不勾），签名 / 出法照确认页缺省，玩家点「开始」才推</summary>
    private void RenewApp(LibraryGame game, string device) => OpenExport(game, preDevice: device);

    // ---- 顶栏动态窗口（同 Mac S2ArmLauncherModel+PhoneConsole「顶栏动态窗口」）：有和 App 相关的作业时「游戏库」那颗显示进度，做完闪 ✓，失败 / 停下留「!」直到点开 ----
    private bool dynamicDone, dynamicAlert;

    private void DynamicFinished(string state)
    {
        if (phoneOverview is null) return;
        if (state is "succeeded" or "needsPlayer")
        {
            dynamicDone = true;
            _ = Task.Delay(2000).ContinueWith(_ => Avalonia.Threading.Dispatcher.UIThread.Post(() => { dynamicDone = false; Render(); }));
        }
        else if (state is "failed" or "interrupted" or "cancelled" or "invalid") dynamicAlert = true;
    }

    /// <summary>顶栏「游戏库」那颗此刻显示什么；null = 照旧</summary>
    private string? DynamicLibraryText()
    {
        if (phoneOverview is null) return null;
        if (ConsoleUpdating) return "⟳ " + Tf("dynamic.batch", Math.Min(consoleDone + 1, Math.Max(consoleTotal, 1)), Math.Max(consoleTotal, 1));
        if (identityState == "running") return "⟳ " + T("phone.title.phoneIdentity");   // 交签名身份占着手机槽：写它自己的名字，不借「更新 S2Arm」
        if (installBusy || phoneUpdating)
        {
            var pct = installDone is { } d && installTotal is { } t && t > 0 ? " " + (100 * d / t) + "%" : "";
            return "⟳ " + (installGameName is { Length: > 0 } n && installBusy ? n : T("console.button.update")) + pct;
        }
        if (dynamicAlert) return "! " + T("nav.library");
        if (dynamicDone) return "✓ " + T("nav.library");
        return null;
    }

    /// <summary>点动态窗口：直接到总控台（选中首位「S2Arm」），看过就收起「!」</summary>
    private void OpenConsoleFromTopBar()
    {
        dynamicAlert = false;
        ChangeSelectedGame(ConsoleId, "topBarConsole");
        Navigate("library");
    }

    /// <summary>不经玩家点那一款、由跳转把选中改到别处（玩家眼里同「选中丢了」，#1392）：改之前在 logs/launcher-crash.log 记一行 library.select.change——
    /// 从哪款改到哪、原因（rowConsole = 出包 / 装机行内「去 S2Arm 卡」；topBarConsole = 点顶栏动态窗口）、当时的出包款与状态。本来就是它就不记。</summary>
    private void ChangeSelectedGame(string to, string reason)
    {
        if (selectedGame != to)
            LauncherCrash.Log(null, $"library.select.change from={selectedGame ?? "null"} to={to} reason={reason} pack={packGame?.Id ?? "null"}/{(packState == "" ? "null" : packState)}");
        selectedGame = to;
    }
}
