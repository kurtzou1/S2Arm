// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 手机作业（装到 iPhone / 续签、从手机删一款、装回上一版、更新手机上的 S2Arm）的进行中与结局，一份（同 Mac PhoneJobPanel.swift）。
// 11-11 维护者看「更新 iPhone 上的 S2Arm」做完的页面：成功了还写「正在更新」、露出机读码、原始日志堆着、只换壳也说「资源包 0.0 GB 第一次全拷」、
//   成功失败分不清。三态分开：进行中（只增不减的整体进度 + 步骤）、成功（结论句 + 用时 + 推送情况）、失败（原因 + 下一步 + 复制错误摘要）；
//   过程记录只在「详细过程」里。Windows 原先更新手机只有顶栏一个胶囊，失败原因被截断、详情藏在悬停提示里：现在有自己的页（page = "phoneupdate"）。
using System.Diagnostics;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// <summary>一个手机作业的过程与结局事实（从作业事件和作业结果来，不猜）</summary>
internal sealed class PhoneJobTrack
{
    public string Kind = "install";
    /// <summary>「详细过程」玩家点开了没有：卡片随进度事件重建（RefreshLive），展开状态记在这里，重建照旧展开（D-237B：点开就自动收起）</summary>
    public bool DetailsOpen;
    public readonly List<string> Stages = [];
    public readonly List<string> Log = [];
    public double? Overall;
    public int? Step, Steps;
    public DateTime Started = DateTime.UtcNow;
    public DateTime? Ended;
    public string Suggestion = "";
    public string Device = "";
    public long? PackBytes;
    public int? PackFiles;
    public List<string> Skipped = [];
    public string Version = "";
    /// <summary>导出模式（装法「导出，自己签名安装」）：放进的文件夹、几款、多大（作业结果 exported / outputPath / games / exportBytes）；一键装为空</summary>
    public string ExportFolder = "";
    public int ExportGames;
    public long? ExportBytes;
    /// <summary>这次新写的 .img 文件名与沿用上次导出的款数（#1132，作业结果 fresh / reused）：有沿用才在完成页点名「.img 只要拷这几个」</summary>
    public List<string> ExportFresh = [];
    public int ExportReused;
    public List<string> ExportUnwritten = [];   // 只新写点的那款时，这次没写 .img 的别的款（作业结果 unwritten，游戏名）
    /// <summary>这次补进 S 级优化的各款：(游戏名, {applied, failed, error})（作业结果 sgrade，pack/jobs/install.py；完成页列打上 / 没打上，11-14）</summary>
    public List<(string Name, JsonElement Res)> SGrade = [];
    /// <summary>「更新 S2Arm」装完后这台手机上的 0.5.x 老款（作业结果 legacy：资源在、程序包不在，这台电脑能更新的）与它们那台的设备记录键（legacyDevice）；
    /// 要回装它的电脑更新的只记名字（legacyElsewhere）。成功页接着列出、默认全勾，点「更新这 N 款」走 pushSelected（同 Mac PhoneJobPanel legacySection）</summary>
    public List<(string Id, string Name)> Legacy = [];
    public List<string> LegacyElsewhere = [];
    public string LegacyDevice = "";
    /// <summary>独立 App（出法 standalone，0.6.4）：作业结果 layout = standalone 时成功页换成 A（直装）/ B（导出 exported）。
    ///   直装：appName / expiresAt（Unix 秒）/ expiresKnown（false = 估算）/ ipaPath；导出：s2armPath / resourcePath / resourceLinked / signedWith / nextSteps / readmePath</summary>
    public bool Standalone, StandaloneExported;
    public string DeviceName = "", AppName = "", GameFolder = "", IpaPath = "", ReadmePath = "", S2armPath = "", ResourcePath = "", SignedWithMode = "", SignedWithName = "";
    public long? IpaBytes, S2armBytes, ResourceBytes;
    public bool ResourceLinked, ExpiresKnown;
    public DateTimeOffset? ExpiresAt;
    public List<string> NextSteps = [];
    /// <summary>失败结果带 appInstalled：独立 App 已装上、资源没推完（失败页标题换成「App 已装上，资源没推完」）</summary>
    public bool AppInstalled;

    public void Begin(string kind, string device)
    {
        Kind = kind; Device = device; Stages.Clear(); Log.Clear(); Overall = null; Step = Steps = null;
        Started = DateTime.UtcNow; Ended = null; Suggestion = ""; PackBytes = null; PackFiles = null; Skipped = []; Version = "";
        ExportFolder = ""; ExportGames = 0; ExportBytes = null; ExportFresh = []; ExportReused = 0; ExportUnwritten = []; SGrade = [];
        Legacy = []; LegacyElsewhere = []; LegacyDevice = ""; DetailsOpen = false;
        Standalone = StandaloneExported = ResourceLinked = ExpiresKnown = AppInstalled = false; ExpiresAt = null; IpaBytes = S2armBytes = ResourceBytes = null; NextSteps = [];
        DeviceName = AppName = GameFolder = IpaPath = ReadmePath = S2armPath = ResourcePath = SignedWithMode = SignedWithName = "";
    }

    private static string Str(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    private static long? Long(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;

    /// <summary>作业事件：阶段进步骤列表、整体进度只认作业层 overall（只增不减）、说明行进过程记录</summary>
    public void Ingest(JsonElement e)
    {
        var type = e.TryGetProperty("type", out var t) ? t.GetString() : null;
        if (e.TryGetProperty("overall", out var o) && o.ValueKind == JsonValueKind.Number) Overall = Math.Max(Overall ?? 0, Math.Min(1, o.GetDouble()));
        if (e.TryGetProperty("stageIndex", out var i) && i.ValueKind == JsonValueKind.Number) Step = i.GetInt32();
        if (e.TryGetProperty("stageCount", out var n) && n.ValueKind == JsonValueKind.Number) Steps = n.GetInt32();
        var message = e.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() ?? "" : "";
        if (type == "stage" && e.TryGetProperty("stage", out var s) && s.GetString() is { Length: > 0 } stage && (Stages.Count == 0 || Stages[^1] != stage)) Stages.Add(stage);
        if (type is "stage" or "message" && message.Length > 0 && (Log.Count == 0 || Log[^1] != message)) Log.Add(message);
    }

    /// <summary>作业结束：结局事实取自作业结果（实际装上的那台、这次推了多少、哪几款被跳过）</summary>
    public void Finish(LibraryJobOutput job, Func<string, string> gameName)
    {
        Ended = DateTime.UtcNow;
        if (job.Report.Diagnostics.ValueKind == JsonValueKind.Array)
            foreach (var d in job.Report.Diagnostics.EnumerateArray())
                if (Suggestion.Length == 0 && d.ValueKind == JsonValueKind.Object && d.TryGetProperty("suggestion", out var sg) && sg.GetString() is { Length: > 0 } next) Suggestion = next;
        var r = job.Report.Result;
        if (r.ValueKind != JsonValueKind.Object) return;
        var kind = r.TryGetProperty("deviceKind", out var k) ? k.GetString() ?? "" : "";
        var name = r.TryGetProperty("deviceName", out var dn) ? dn.GetString() ?? "" : "";
        if (kind.Length > 0 || name.Length > 0) Device = name.Length > 0 ? (kind.Length > 0 ? kind : "iPhone / iPad") + "「" + name + "」" : kind;
        if (r.TryGetProperty("packBytes", out var pb) && pb.ValueKind == JsonValueKind.Number) PackBytes = pb.GetInt64();
        if (r.TryGetProperty("packFiles", out var pf) && pf.ValueKind == JsonValueKind.Number) PackFiles = pf.GetInt32();
        if (r.TryGetProperty("skipped", out var sk) && sk.ValueKind == JsonValueKind.Array)
            Skipped = sk.EnumerateArray().Select(x => gameName(x.GetString() ?? "")).ToList();
        if (r.TryGetProperty("legacy", out var lg) && lg.ValueKind == JsonValueKind.Array)
            Legacy = lg.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.Object && x.TryGetProperty("gameId", out _))
                .Select(x => ((x.GetProperty("gameId").GetString() ?? "").ToUpperInvariant(), x.TryGetProperty("name", out var nm) ? nm.GetString() ?? "" : "")).ToList();
        if (r.TryGetProperty("legacyElsewhere", out var le) && le.ValueKind == JsonValueKind.Array)
            LegacyElsewhere = le.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.Object)
                .Select(x => x.TryGetProperty("name", out var nm) ? nm.GetString() ?? "" : x.TryGetProperty("gameId", out var gi) ? gi.GetString() ?? "" : "").Where(x => x.Length > 0).ToList();
        if (r.TryGetProperty("legacyDevice", out var ld) && ld.ValueKind == JsonValueKind.String) LegacyDevice = ld.GetString() ?? "";
        if (r.TryGetProperty("sgrade", out var sg2) && sg2.ValueKind == JsonValueKind.Object)
            SGrade = sg2.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal).Select(p => (gameName(p.Name), p.Value.Clone())).ToList();
        // 失败结果带 appInstalled（main.py app_installed_result）：App 装上了、资源没推完
        AppInstalled = r.TryGetProperty("appInstalled", out var ai) && ai.ValueKind == JsonValueKind.Object;
        if (Str(r, "layout") == "standalone")
        {
            Standalone = true;
            StandaloneExported = r.TryGetProperty("exported", out var sx) && sx.ValueKind == JsonValueKind.True;
            DeviceName = name; AppName = Str(r, "appName"); GameFolder = Str(r, "gameFolder"); IpaPath = Str(r, "ipaPath"); ReadmePath = Str(r, "readmePath");
            S2armPath = Str(r, "s2armPath"); ResourcePath = Str(r, "resourcePath");
            IpaBytes = Long(r, "ipaBytes"); S2armBytes = Long(r, "s2armBytes"); ResourceBytes = Long(r, "resourceBytes");
            ResourceLinked = r.TryGetProperty("resourceLinked", out var rl) && rl.ValueKind == JsonValueKind.True;
            ExpiresKnown = r.TryGetProperty("expiresKnown", out var ek) && ek.ValueKind == JsonValueKind.True;
            if (r.TryGetProperty("expiresAt", out var ea) && ea.ValueKind == JsonValueKind.Number)
                ExpiresAt = DateTimeOffset.FromUnixTimeMilliseconds((long)(ea.GetDouble() * 1000));
            if (r.TryGetProperty("signedWith", out var sw) && sw.ValueKind == JsonValueKind.Object) { SignedWithMode = Str(sw, "mode"); SignedWithName = Str(sw, "name"); }
            if (r.TryGetProperty("nextSteps", out var ns) && ns.ValueKind == JsonValueKind.Array)
                NextSteps = ns.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString() ?? "").Where(x => x.Length > 0).ToList();
        }
        if (r.TryGetProperty("exported", out var ex) && ex.ValueKind == JsonValueKind.True && r.TryGetProperty("s2armPath", out var sp) && sp.ValueKind == JsonValueKind.String)
        {   // 一款导出成两件套（.s2arm + 硬链接过去的 .img）：完成页「打开文件夹」指「S2Arm 游戏包」文件夹
            ExportFolder = Path.GetDirectoryName(sp.GetString() ?? "") ?? "";
            ExportGames = 1;
            if (r.TryGetProperty("s2armBytes", out var sb) && sb.ValueKind == JsonValueKind.Number) ExportBytes = sb.GetInt64();
        }
        else if (r.TryGetProperty("exported", out var ex2) && ex2.ValueKind == JsonValueKind.True && r.TryGetProperty("outputPath", out var op) && op.ValueKind == JsonValueKind.String)
        {   // 导出通用 S2Arm.ipa（不带游戏）
            ExportFolder = Path.GetDirectoryName(op.GetString() ?? "") ?? "";
            ExportGames = 0;
            if (r.TryGetProperty("exportBytes", out var eb) && eb.ValueKind == JsonValueKind.Number) ExportBytes = eb.GetInt64();
            if (r.TryGetProperty("fresh", out var fr) && fr.ValueKind == JsonValueKind.Array) ExportFresh = fr.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x.Length > 0).ToList();
            if (r.TryGetProperty("reused", out var ru) && ru.ValueKind == JsonValueKind.Number) ExportReused = ru.GetInt32();
            if (r.TryGetProperty("unwritten", out var uw) && uw.ValueKind == JsonValueKind.Array) ExportUnwritten = uw.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x.Length > 0).ToList();
        }
    }
}

public sealed partial class EnvironmentWindow
{
    private readonly PhoneJobTrack installTrack = new(), updateTrack = new();
    private readonly HashSet<string> legacyOff = new(StringComparer.OrdinalIgnoreCase);   // 「更新这 N 款」里玩家取消勾的老款（缺省全勾）

    /// <summary>0.5.x 老款：装好 App 的同一页接着列出、默认全勾，点「更新这 N 款」按「更新所选」逐款推（排队、有进度、可停）；别处装的只写一行（同 Mac legacySection）</summary>
    private Control LegacyPanel(PhoneJobTrack tr)
    {
        var box = new StackPanel { Spacing = 8, Margin = new Thickness(0, 10, 0, 0) };
        if (tr.Legacy.Count > 0)
        {
            var title = Label(T("phone.legacy.title").Replace("{0}", tr.Legacy.Count.ToString()), 20); title.FontWeight = FontWeight.Black; title.Foreground = Brush.Parse("#FFC857");
            box.Children.Add(title);
            box.Children.Add(WrappedMuted(T("phone.legacy.note"), 14));
            foreach (var (id, name) in tr.Legacy)
            {
                var cb = new CheckBox { Content = name.Length > 0 ? name : id, IsChecked = !legacyOff.Contains(id) };
                cb.IsCheckedChanged += (_, _) => { if (cb.IsChecked == true) legacyOff.Remove(id); else legacyOff.Add(id); Render(); };
                Avalonia.Automation.AutomationProperties.SetAutomationId(cb, "phone.legacy." + id);
                box.Children.Add(cb);
            }
            var picked = tr.Legacy.Where(g => !legacyOff.Contains(g.Id)).Select(g => g.Id).ToList();
            var go = Primary(T("phone.legacy.button").Replace("{0}", picked.Count.ToString()), () => { if (picked.Count > 0) _ = PushSelectedAsync(picked, tr.LegacyDevice); }, picked.Count > 0 && tr.LegacyDevice.Length > 0);
            Avalonia.Automation.AutomationProperties.SetAutomationId(go, "phone.legacy.update");
            box.Children.Add(go);
        }
        if (tr.LegacyElsewhere.Count > 0)
            box.Children.Add(WrappedMuted(T("phone.legacy.elsewhere").Replace("{0}", tr.LegacyElsewhere.Count.ToString()).Replace("{1}", string.Join("、", tr.LegacyElsewhere)), 14));
        return box;
    }

    /// <summary>手机作业卡片。state：running / succeeded / needsPlayer / failed / invalid / interrupted / cancelled / drop（会挤掉别处装的游戏，页内确认）。
    /// retry：失败时的「重试」；confirmDrop / cancelDrop：drop 态的「仍然继续」/「先不」（在这页里问，不弹散的对话框）</summary>
    private Control PhoneJobCard(PhoneJobTrack tr, string state, string message, string diagnostics, string? gameId, IReadOnlyList<string>? notes = null,
        Action? retry = null, Action? confirmDrop = null, Action? cancelDrop = null, string? dropTitle = null, bool showsOperation = true, Action? switchExport = null,
        (string Label, Action Run)? alternateDrop = null, Action? finish = null)
    {
        var device = tr.Device.Length > 0 ? tr.Device : T("phone.device.unknown");
        var panel = new StackPanel { Spacing = 22, HorizontalAlignment = HorizontalAlignment.Stretch };   // 撑满卡片、贴左（同别的卡片对齐）：进度条、详细过程不被压窄
        AutomationId(panel, "phone." + state);
        // 导出自签包：装机 / 更新作业不连手机、出到文件夹。完成后看结果，进行中看这次会话
        var exporting = tr.Kind is "install" or "installUpdate" && (tr.ExportFolder.Length > 0 || state == "running" && (tr.Kind == "install" ? installExport : lastUpdateMode == "export"));
        var title = Label(T(exporting ? "phone.title.export" : "phone.title." + tr.Kind), 18); title.FontWeight = FontWeight.Bold;   // 这是什么操作（维护者：只看得到「更新中 · …」一小行）
        AutomationId(title, "phone.operation");
        if (showsOperation) panel.Children.Add(title);   // 外层已用大标题写明是什么操作（导出自签包页）时不再画，免得「导出自签包」下面又一行「导出，自己签名安装」
        if (state == "drop")
        {
            panel.Children.Add(Seal("!", "#FFC857"));
            panel.Children.Add(Headline(dropTitle ?? T("install.drop_title")));
            if (message.Length > 0) panel.Children.Add(WrappedMuted(B(message), 16));
            var choose = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            var go = Primary(T("install.drop_confirm"), () => confirmDrop?.Invoke(), confirmDrop is not null);
            AutomationId(go, "phone.drop.confirm");
            var notNow = Action("phone.drop.cancel", () => cancelDrop?.Invoke(), cancelDrop is not null);
            AutomationId(notNow, "phone.drop.cancel");
            choose.Children.Add(go);
            // 这个码有并列的另一条路（共享体验表 alternate，如新建证书确认的「改用已有证书」）：玩家自己选，点了不重发、去那个动作的落点
            if (alternateDrop is { } other)
            {
                var alt = Action(other.Label, other.Run);
                AutomationId(alt, "phone.drop.alternate");
                choose.Children.Add(alt);
            }
            choose.Children.Add(notNow);
            panel.Children.Add(choose);
            return panel;
        }
        if (state == "running")
        {
            var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            status.Children.Add(new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(4.5), Background = Brush.Parse("#FFC857"), VerticalAlignment = VerticalAlignment.Center });
            status.Children.Add(new TextBlock { Text = T(exporting ? "phone.status.running.export" : "phone.status.running." + tr.Kind), FontSize = 14, FontWeight = FontWeight.Bold, Foreground = Brush.Parse("#FFC857") });
            if (!exporting) status.Children.Add(Muted("· " + device, 13));
            panel.Children.Add(status);
            var value = tr.Overall ?? 0;
            var pct = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            var big = Label((int)(value * 100) + "%", 54); big.FontWeight = FontWeight.Black;
            pct.Children.Add(big);
            var label = Muted(T("export.overall"), 14); label.VerticalAlignment = VerticalAlignment.Bottom; label.Margin = new Thickness(0, 0, 0, 10);
            pct.Children.Add(label);
            panel.Children.Add(pct);
            panel.Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Value = value, Height = 10, Foreground = Brush.Parse("#F3E7D3"), CornerRadius = new CornerRadius(5) });
            // 「需要你动手」的醒目提示只在 Mac（钥匙串授权，作业事件 keychainPrompt）：Windows 装机走 Impactor 命令行，过程中不停下来等玩家
            //   （Apple ID 登录过期直接以 apple_session_expired 失败、失败页给「打开 Impactor 重新登录」），没有要提示的时刻
            var steps = new StackPanel { Spacing = 10 };
            for (var k = 0; k < tr.Stages.Count; k++)
            {
                var current = k == tr.Stages.Count - 1;
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                row.Children.Add(new TextBlock { Text = current ? "●" : "✓", Width = 22, TextAlignment = TextAlignment.Center, FontSize = current ? 13 : 16,
                    Foreground = current ? Brush.Parse("#FFC857") : Brush.Parse("#40D678"), VerticalAlignment = VerticalAlignment.Center });
                var name = current ? Label(B(tr.Stages[k]), 16) : Muted(B(tr.Stages[k]), 14);
                if (current) name.FontWeight = FontWeight.Bold;
                row.Children.Add(name);
                steps.Children.Add(row);
            }
            if (tr.Steps is { } total && total > tr.Stages.Count)
            {
                var more = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                more.Children.Add(new TextBlock { Text = "○", Width = 22, TextAlignment = TextAlignment.Center, Foreground = Brush.Parse("#5A5A60") });
                more.Children.Add(Muted(T("phone.steps.more").Replace("{0}", (total - tr.Stages.Count).ToString()), 14));
                steps.Children.Add(more);
            }
            panel.Children.Add(steps);
        }
        else if (state == "succeeded" && tr.Standalone && tr.StandaloneExported) StandaloneExportDone(panel, tr, finish);   // 成功页 B：独立 App 导出
        else if (state == "succeeded" && tr.Standalone) StandaloneInstallDone(panel, tr, notes, finish);   // 成功页 A：独立 App 直装
        else if (state == "succeeded" && tr.ExportFolder.Length > 0)
        {
            // 导出好了：放进哪个文件夹、几款、多大，怎么装一句话，打开文件夹（作业完成时已自动打开一次）
            panel.Children.Add(Seal("✓", "#40D678"));
            panel.Children.Add(Headline(T("phone.headline.export")));
            panel.Children.Add(WrappedMuted(T("phone.done.export").Replace("{0}", tr.ExportFolder), 17));
            if (tr.ExportReused > 0)   // #1132：有沿用上次导出的款才点名（第一次导出全是新写的，不多这一句；同 Mac PhoneJobPanel）
            {
                var fresh = Label(tr.ExportFresh.Count == 0 ? T("phone.done.export.same")
                    : T("phone.done.export.fresh").Replace("{0}", string.Join("、", tr.ExportFresh)).Replace("{1}", tr.ExportReused.ToString()), 15);
                fresh.FontWeight = FontWeight.SemiBold; fresh.TextWrapping = TextWrapping.Wrap;
                AutomationId(fresh, "phone.export.fresh");
                panel.Children.Add(fresh);
            }
            if (tr.ExportUnwritten.Count > 0)   // 只新写了点的那款：别的款这次没写 .img（同 Mac PhoneJobPanel）
            {
                var unwritten = Label(T("phone.done.export.unwritten").Replace("{0}", string.Join("、", tr.ExportUnwritten)), 15);
                unwritten.FontWeight = FontWeight.SemiBold; unwritten.TextWrapping = TextWrapping.Wrap;
                AutomationId(unwritten, "phone.export.unwritten");
                panel.Children.Add(unwritten);
            }
            var stats = new WrapPanel { Orientation = Orientation.Horizontal };
            void Stat(string label, string value)
            {
                var cell = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 44, 0) };
                cell.Children.Add(Muted(label, 13));
                var v = Label(value, 28); v.FontWeight = FontWeight.Black;
                cell.Children.Add(v);
                stats.Children.Add(cell);
            }
            if (tr.Ended is { } end) Stat(T("phone.stat.time"), Duration((end - tr.Started).TotalSeconds));
            Stat(T("phone.stat.games"), tr.ExportGames.ToString());
            if (tr.ExportBytes is { } size) Stat(T("phone.stat.size"), FormatBytes(size));
            panel.Children.Add(stats);
            panel.Children.Add(WrappedMuted(T("phone.fact.export"), 14));
            if (tr.Skipped.Count > 0) panel.Children.Add(WrappedMuted(T("phone.fact.export_skipped").Replace("{0}", string.Join("、", tr.Skipped)), 14));
            var folder = tr.ExportFolder;
            var actions = new WrapPanel { Orientation = Orientation.Horizontal };
            var open = Primary(T("phone.export.open"), () => OpenFolder(folder));
            AutomationId(open, "phone.export.open");
            actions.Children.Add(open);
            panel.Children.Add(actions);
            if (SGradeResultPanel(tr.SGrade) is { } sgr) panel.Children.Add(sgr);   // 补进 S 级优化的各款：打上 / 没打上（11-14）
        }
        else if (state is "succeeded" or "needsPlayer")
        {
            var done = state == "succeeded";
            panel.Children.Add(Seal(done ? "✓" : "!", done ? "#40D678" : "#FFC857"));
            panel.Children.Add(Headline(T(done ? "phone.headline." + tr.Kind : "install.needs_player").Replace("{0}", device)));
            if (done)
            {
                var sentence = T("phone.done." + tr.Kind).Replace("{0}", device).Replace("{1}", tr.Version.Length > 0 ? "v" + tr.Version : "");
                panel.Children.Add(Muted(sentence, 17));
                var stats = new WrapPanel { Orientation = Orientation.Horizontal };
                void Stat(string label, string value)
                {
                    var cell = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 44, 0) };
                    cell.Children.Add(Muted(label, 13));
                    var v = Label(value, 28); v.FontWeight = FontWeight.Black;
                    cell.Children.Add(v);
                    stats.Children.Add(cell);
                }
                if (tr.Ended is { } end) Stat(T("phone.stat.time"), Duration((end - tr.Started).TotalSeconds));
                Stat(T("phone.stat.device"), device);
                if (tr.Kind is "install" or "installUpdate") Stat(T("phone.stat.games"), (tr.PackBytes ?? 0) == 0 ? T("phone.stat.no_push") : FormatBytes(tr.PackBytes ?? 0));
                panel.Children.Add(stats);
                var lines = new List<string>();
                if (tr.Kind is "install" or "installUpdate")
                {
                    lines.Add((tr.PackBytes ?? 0) == 0 ? T("phone.fact.no_push")
                        : T("phone.fact.pushed").Replace("{0}", FormatBytes(tr.PackBytes ?? 0)).Replace("{1}", (tr.PackFiles ?? 0).ToString()));
                    if (tr.Skipped.Count > 0) lines.Add(T("phone.fact.skipped").Replace("{0}", string.Join("、", tr.Skipped)));
                }
                foreach (var line in lines.Concat(notes ?? [])) panel.Children.Add(WrappedMuted(line, 14));
                if (SGradeResultPanel(tr.SGrade) is { } sgr) panel.Children.Add(sgr);   // 补进 S 级优化的各款：打上 / 没打上（11-14）
                if (tr.Kind == "installUpdate" && (tr.Legacy.Count > 0 || tr.LegacyElsewhere.Count > 0)) panel.Children.Add(LegacyPanel(tr));
            }
            else if (message.Length > 0) panel.Children.Add(WrappedMuted(B(message), 16));
        }
        else if (state == "cancelled")
        {
            panel.Children.Add(Seal("✕", "#8C8A85"));
            panel.Children.Add(Headline(T("phone.cancelled")));
        }
        else
        {
            panel.Children.Add(Seal("!", "#E05C5C"));
            // 独立 App 装上了、资源没推完（失败结果 appInstalled）：标题说清 App 在手机上了，下一步加「重试只推剩下的」
            panel.Children.Add(Headline(T(tr.AppInstalled ? "app.failed.partial" : exporting ? "phone.failed.export" : "phone.failed." + tr.Kind)));
            if (message.Length > 0) panel.Children.Add(WrappedMuted(B(message), 17));
            var nextLines = new List<string>();
            if (tr.Suggestion.Length > 0) nextLines.Add(B(tr.Suggestion));
            if (tr.AppInstalled) nextLines.Add(T("app.failed.partialNext"));
            if (nextLines.Count > 0)
            {
                var next = new StackPanel { Spacing = 4 };
                var label = Muted(T("phone.next"), 12); label.FontWeight = FontWeight.Bold;
                next.Children.Add(label);
                foreach (var line in nextLines)
                {
                    var text = Label(line, 15); text.TextWrapping = TextWrapping.Wrap;
                    next.Children.Add(text);
                }
                panel.Children.Add(next);
            }
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            if (retry is not null)
            {
                var again = Primary(T("phone.retry"), retry);
                AutomationId(again, "phone.retry");
                actions.Children.Add(again);
            }
            if (switchExport is not null)   // 装到 iPhone / 更新没走成（没连手机、签不上…）：换另一条路——导出自签包，不连手机也能走完
            {
                var sw = Action("phone.switch_export", switchExport);
                AutomationId(sw, "phone.switchExport");
                actions.Children.Add(sw);
            }
            actions.Children.Add(CopyReportButton(gameId, [tr.Kind], () => message + "\n" + diagnostics));
            panel.Children.Add(actions);
            panel.Children.Add(ReportHintText());
        }
        var log = string.Join("\n", tr.Log.Select(B)) + (diagnostics.Length > 0 && state is not ("running" or "succeeded") ? "\n\n" + diagnostics : "");
        if (log.Trim().Length > 0) panel.Children.Add(DetailsToggle(T("phone.details"), log.Trim(), tr));
        return panel;
    }

    /// <summary>成功页的一格数据：小标题 + 大字值（同上面「用时 / 设备」那排）</summary>
    private Control StatCell(string label, string value, double size = 28)
    {
        var cell = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 44, 8) };
        cell.Children.Add(Muted(label, 13));
        var v = Label(value, size); v.FontWeight = FontWeight.Black; v.TextWrapping = TextWrapping.Wrap;
        cell.Children.Add(v);
        return cell;
    }

    /// <summary>短日期按当前界面语言写（zh-Hans / en / ja / es / fr / zh-Hant 都是 .NET 认得的文化名；认不得退回系统的）</summary>
    private string ShortDate(DateTimeOffset at)
    {
        System.Globalization.CultureInfo culture;
        try { culture = System.Globalization.CultureInfo.GetCultureInfo(language); }
        catch (System.Globalization.CultureNotFoundException) { culture = System.Globalization.CultureInfo.CurrentCulture; }
        return at.LocalDateTime.ToString("d", culture);
    }

    /// <summary>成功页 A（独立 App 直装，作业结果 layout = standalone）：装到哪台、手机上的名字、到期（真值 / 估算）、这次推了多少；
    ///   怎么打开 + 信任（notes 由装机页给）；「在资源管理器中显示」选中游戏文件夹里那份 ipa、「完成」收起卡片</summary>
    private void StandaloneInstallDone(StackPanel panel, PhoneJobTrack tr, IReadOnlyList<string>? notes, Action? finish)
    {
        panel.Children.Add(Seal("✓", "#40D678"));
        var device = tr.DeviceName.Length > 0 ? tr.DeviceName : tr.Device.Length > 0 ? tr.Device : T("phone.device.unknown");
        panel.Children.Add(Headline(T("app.done.title").Replace("{0}", device)));
        var stats = new WrapPanel { Orientation = Orientation.Horizontal };
        if (tr.AppName.Length > 0) stats.Children.Add(StatCell(T("app.done.name"), tr.AppName));
        if (tr.ExpiresAt is { } until)
        {
            var days = Math.Max(0, (int)Math.Ceiling((until - DateTimeOffset.Now).TotalDays));
            var expires = T(tr.ExpiresKnown ? "app.done.expiresValue" : "app.done.expiresEstimate").Replace("{0}", ShortDate(until)).Replace("{1}", days.ToString());
            var cell = StatCell(T("app.done.expires"), expires, 22);
            AutomationId(cell, "app.done.expires");
            stats.Children.Add(cell);
        }
        stats.Children.Add(StatCell(T("app.done.data"), (tr.PackFiles ?? 0) == 0 && (tr.PackBytes ?? 0) == 0 ? T("app.done.pushedNone")
            : T("app.done.pushed").Replace("{0}", (tr.PackFiles ?? 0).ToString()).Replace("{1}", FormatBytes(tr.PackBytes ?? 0)), 22));
        panel.Children.Add(stats);
        foreach (var line in notes ?? []) panel.Children.Add(WrappedMuted(line, 14));
        if (SGradeResultPanel(tr.SGrade) is { } sgr) panel.Children.Add(sgr);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var ipa = tr.IpaPath;
        var reveal = Action("app.done.revealWindows", () => Reveal(ipa), System.IO.File.Exists(ipa));
        AutomationId(reveal, "app.done.reveal");
        actions.Children.Add(reveal);
        var done = Primary(T("app.done.finish"), () => finish?.Invoke(), finish is not null);
        AutomationId(done, "app.done.finish");
        actions.Children.Add(done);
        panel.Children.Add(actions);
    }

    /// <summary>成功页 B（独立 App 导出，layout = standalone 且 exported）：放在这款的游戏文件夹、文件清单、签没签、下一步（作业层按界面语言写好的 nextSteps 原样列）、
    ///   README 说明；「在资源管理器中显示」选中 ipa、「打开说明」用系统默认程序打开 README、「完成」收起卡片。不自动打开文件夹</summary>
    private void StandaloneExportDone(StackPanel panel, PhoneJobTrack tr, Action? finish)
    {
        panel.Children.Add(Seal("✓", "#40D678"));
        panel.Children.Add(Headline(T("app.export.title").Replace("{0}", tr.AppName)));
        if (tr.GameFolder.Length > 0) panel.Children.Add(WrappedMuted(T("app.export.folder").Replace("{0}", tr.GameFolder), 16));
        var files = new StackPanel { Spacing = 4 };
        var filesLabel = Muted(T("app.export.files"), 12); filesLabel.FontWeight = FontWeight.Bold;
        files.Children.Add(filesLabel);
        void AddFile(string path, long? bytes, string note = "")
        {
            var row = Label(Path.GetFileName(path) + (bytes is { } b ? " · " + FormatBytes(b) : "") + (note.Length > 0 ? " · " + note : ""), 15); row.TextWrapping = TextWrapping.Wrap;
            files.Children.Add(row);
        }
        if (tr.IpaPath.Length > 0) AddFile(tr.IpaPath, tr.IpaBytes);
        if (tr.S2armPath.Length > 0) AddFile(tr.S2armPath, tr.S2armBytes);
        if (tr.ResourcePath.Length > 0 && tr.ResourceLinked) AddFile(tr.ResourcePath, tr.ResourceBytes, T("app.export.noExtraSpace"));   // 硬链接：按实际大小报，注「不另占空间」
        AutomationId(files, "app.export.files");
        panel.Children.Add(files);
        if (tr.ResourcePath.Length > 0 && !tr.ResourceLinked)   // 盘不支持硬链接：.img 留在原处，说清在哪
        {
            var elsewhere = Label(T("app.export.imgElsewhere").Replace("{0}", tr.ResourcePath), 14); elsewhere.TextWrapping = TextWrapping.Wrap;
            elsewhere.Foreground = Brush.Parse("#E8C65A");
            AutomationId(elsewhere, "app.export.imgElsewhere");
            panel.Children.Add(elsewhere);
        }
        var signed = WrappedMuted(tr.SignedWithMode == "devCert" ? T("app.export.signedCert").Replace("{0}", tr.SignedWithName) : T("app.export.unsigned"), 14);
        AutomationId(signed, "app.export.signed");
        panel.Children.Add(signed);
        if (tr.NextSteps.Count > 0)
        {
            var next = new StackPanel { Spacing = 4 };
            var label = Muted(T("phone.next"), 12); label.FontWeight = FontWeight.Bold;
            next.Children.Add(label);
            for (var k = 0; k < tr.NextSteps.Count; k++)
            {
                var text = Label((k + 1) + ". " + tr.NextSteps[k], 15); text.TextWrapping = TextWrapping.Wrap;
                next.Children.Add(text);
            }
            AutomationId(next, "app.export.next");
            panel.Children.Add(next);
        }
        if (tr.ReadmePath.Length > 0) panel.Children.Add(WrappedMuted(T("app.export.readme").Replace("{0}", Path.GetFileName(tr.ReadmePath)), 14));
        if (SGradeResultPanel(tr.SGrade) is { } sgr) panel.Children.Add(sgr);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var ipa = tr.IpaPath; var readme = tr.ReadmePath;
        var reveal = Action("app.done.revealWindows", () => Reveal(ipa), System.IO.File.Exists(ipa));
        AutomationId(reveal, "app.done.reveal");
        actions.Children.Add(reveal);
        var open = Action("app.export.openReadme", () => OpenWithDefault(readme), System.IO.File.Exists(readme));
        AutomationId(open, "app.export.openReadme");
        actions.Children.Add(open);
        var done = Primary(T("app.done.finish"), () => finish?.Invoke(), finish is not null);
        AutomationId(done, "app.done.finish");
        actions.Children.Add(done);
        panel.Children.Add(actions);
    }

    /// <summary>用系统默认程序打开一个文件（README）：按 shell 关联打开；文件不在就不开（按钮已按文件在不在置灰）</summary>
    private void OpenWithDefault(string path)
    {
        if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path)) return;
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose(); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        { installDiagnostics += "\n" + T("process.start_failed") + "\n" + error.Message; Render(); }
    }

    /// <summary>「详细过程」：自己画的折叠头，箭头是矢量路径。原注释说「Expander 的箭头是字体字形、显示成厂字」是误判：
    /// Fluent Expander 的箭头本来就是矢量路径，那次看到的怪形是截图截在箭头旋转动画中途（11-14 体验梳理查实）。自绘这一个保留：样式与本卡片一致、没有动画</summary>
    private Control DetailsToggle(string header, string text, PhoneJobTrack tr)
    {
        var body = new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 260, IsVisible = tr.DetailsOpen };
        var chevron = new Avalonia.Controls.Shapes.Path { Data = Geometry.Parse("M 0,0 L 5,5 L 0,10"), Stroke = Brush.Parse("#A8A6A1"), StrokeThickness = 1.6,
            Width = 7, Height = 11, VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = RelativePoint.Center };
        if (tr.DetailsOpen) chevron.RenderTransform = new RotateTransform(90);
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(chevron);
        head.Children.Add(Muted(header, 14));
        var toggle = new Button { Content = head, Background = Brushes.Transparent, Padding = new Thickness(0, 4), BorderThickness = new Thickness(0) };
        AutomationId(toggle, "phone.details");
        toggle.Click += (_, _) => { tr.DetailsOpen = body.IsVisible = !body.IsVisible; chevron.RenderTransform = body.IsVisible ? new RotateTransform(90) : null; };
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(toggle); stack.Children.Add(body);
        return stack;
    }

    private static Border Seal(string glyph, string color) => new()
    {
        Width = 84, Height = 84, CornerRadius = new CornerRadius(42), HorizontalAlignment = HorizontalAlignment.Left, Background = Brush.Parse(color),
        Child = new TextBlock { Text = glyph, FontSize = 44, FontWeight = FontWeight.Black, Foreground = Brushes.Black,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
    };

    private TextBlock Headline(string text)
    {
        var t = Label(text, 40); t.FontWeight = FontWeight.Black; t.TextWrapping = TextWrapping.Wrap;
        AutomationId(t, "phone.title");
        return t;
    }

    private TextBlock WrappedMuted(string text, double size)
    {
        var t = Muted(text, size); t.TextWrapping = TextWrapping.Wrap;
        return t;
    }
}
