// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 手机作业（装到 iPhone / 续签、从手机删一款、装回上一版、更新手机上的 S2Arm）的进行中与结局，一份（同 Mac PhoneJobPanel.swift）。
// 11-11 维护者看「更新 iPhone 上的 S2Arm」做完的页面：成功了还写「正在更新」、露出机读码、原始日志堆着、只换壳也说「资源包 0.0 GB 第一次全拷」、
//   成功失败分不清。三态分开：进行中（只增不减的整体进度 + 步骤）、成功（结论句 + 用时 + 推送情况）、失败（原因 + 下一步 + 复制错误摘要）；
//   过程记录只在「详细过程」里。Windows 原先更新手机只有顶栏一个胶囊，失败原因被截断、详情藏在悬停提示里：现在有自己的页（page = "phoneupdate"）。
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
    /// <summary>完成页「推到手机」（11-13）：推进手机上自签 S2Arm 的 .img 文件名（空 = 还没推）；推不成时作业给的一句「缺什么、怎么做」</summary>
    public List<string> Pushed = [];
    public string PushNote = "";
    public bool Pushing;

    public void Begin(string kind, string device)
    {
        Kind = kind; Device = device; Stages.Clear(); Log.Clear(); Overall = null; Step = Steps = null;
        Started = DateTime.UtcNow; Ended = null; Suggestion = ""; PackBytes = null; PackFiles = null; Skipped = []; Version = "";
        ExportFolder = ""; ExportGames = 0; ExportBytes = null; Pushed = []; PushNote = ""; Pushing = false;
    }

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
        if (r.TryGetProperty("exported", out var ex) && ex.ValueKind == JsonValueKind.True && r.TryGetProperty("outputPath", out var op) && op.ValueKind == JsonValueKind.String)
        {
            ExportFolder = op.GetString() ?? "";
            ExportGames = r.TryGetProperty("games", out var gs) && gs.ValueKind == JsonValueKind.Array ? gs.GetArrayLength() : 0;
            if (r.TryGetProperty("exportBytes", out var eb) && eb.ValueKind == JsonValueKind.Number) ExportBytes = eb.GetInt64();
        }
    }
}

public sealed partial class EnvironmentWindow
{
    private readonly PhoneJobTrack installTrack = new(), updateTrack = new();

    /// <summary>手机作业卡片。state：running / succeeded / needsPlayer / failed / invalid / interrupted / cancelled / drop（会挤掉别处装的游戏，页内确认）。
    /// retry：失败时的「重试」；confirmDrop / cancelDrop：drop 态的「仍然继续」/「先不」（在这页里问，不弹散的对话框）</summary>
    /// <summary>导出完成页「推到手机」：把「S2Arm 自签导出」里的完整 .img 推进手机上自签装好的 S2Arm（exportPush 作业，pack/jobs/install.py push_export）</summary>
    private async Task PushExportAsync(PhoneJobTrack tr, string? gameId)
    {
        if (tr.Pushing || connectedFolder is null) return;
        tr.Pushing = true; Render();
        try
        {
            var fields = new Dictionary<string, object?>();
            if (gameId is { Length: > 0 }) fields["gameId"] = gameId;
            var job = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder, libraryId, "exportPush", null, CancellationToken.None, fields: fields);
            var r = job.Report.Result;
            if (job.Report.Succeeded && r.ValueKind == JsonValueKind.Object && r.TryGetProperty("pushed", out var pu) && pu.ValueKind == JsonValueKind.Array)
            { tr.Pushed = pu.EnumerateArray().Select(x => x.GetString() ?? "").ToList(); tr.PushNote = ""; }
            else tr.PushNote = job.Report.Message;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { tr.PushNote = error.Message; }
        finally { tr.Pushing = false; Render(); }
    }

    private Control PhoneJobCard(PhoneJobTrack tr, string state, string message, string diagnostics, string? gameId, IReadOnlyList<string>? notes = null,
        Action? retry = null, Action? confirmDrop = null, Action? cancelDrop = null, string? dropTitle = null)
    {
        var device = tr.Device.Length > 0 ? tr.Device : T("phone.device.unknown");
        var panel = new StackPanel { Spacing = 22, HorizontalAlignment = HorizontalAlignment.Stretch };   // 撑满卡片、贴左（同别的卡片对齐）：进度条、详细过程不被压窄
        AutomationId(panel, "phone." + state);
        // 导出模式：装机 / 更新作业不连手机、出到文件夹。完成后看结果，进行中看当前装法
        var exporting = tr.Kind is "install" or "installUpdate" && (tr.ExportFolder.Length > 0 || state == "running" && installMode == "export");
        var title = Label(T(exporting ? "phone.title.export" : "phone.title." + tr.Kind), 18); title.FontWeight = FontWeight.Bold;   // 这是什么操作（维护者：只看得到「更新中 · …」一小行）
        AutomationId(title, "phone.operation");
        panel.Children.Add(title);
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
            choose.Children.Add(go); choose.Children.Add(notNow);
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
        else if (state == "succeeded" && tr.ExportFolder.Length > 0)
        {
            // 导出好了：放进哪个文件夹、几款、多大，怎么装一句话，打开文件夹（作业完成时已自动打开一次）
            panel.Children.Add(Seal("✓", "#40D678"));
            panel.Children.Add(Headline(T("phone.headline.export")));
            panel.Children.Add(WrappedMuted(T("phone.done.export").Replace("{0}", tr.ExportFolder), 17));
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
            // 推到手机（11-13，同 Mac）：推进去了说一句；没推成写作业给的原因（缺线 / 没信任 / 没装 S2Arm…）+「推到手机」重试
            var pushLine = WrappedMuted(tr.Pushed.Count > 0 ? T("phone.export.pushed").Replace("{0}", string.Join("、", tr.Pushed)) : tr.PushNote.Length > 0 ? tr.PushNote : T("phone.export.push_hint"), 14);
            AutomationId(pushLine, tr.Pushed.Count > 0 ? "phone.export.pushed" : "phone.export.pushNote");
            panel.Children.Add(pushLine);
            var folder = tr.ExportFolder;
            var actions = new WrapPanel { Orientation = Orientation.Horizontal };
            var open = Primary(T("phone.export.open"), () => OpenFolder(folder));
            AutomationId(open, "phone.export.open");
            actions.Children.Add(open);
            if (tr.Pushed.Count == 0)
            {
                var push = Primary(T(tr.Pushing ? "phone.export.pushing" : "phone.export.push"), () => _ = PushExportAsync(tr, gameId));
                push.IsEnabled = !tr.Pushing; push.Margin = new Thickness(12, 0, 0, 0);
                AutomationId(push, "phone.export.push");
                actions.Children.Add(push);
            }
            panel.Children.Add(actions);
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
            panel.Children.Add(Headline(T("phone.failed." + tr.Kind)));
            if (message.Length > 0) panel.Children.Add(WrappedMuted(B(message), 17));
            if (tr.Suggestion.Length > 0)
            {
                var next = new StackPanel { Spacing = 4 };
                var label = Muted(T("phone.next"), 12); label.FontWeight = FontWeight.Bold;
                next.Children.Add(label);
                var text = Label(B(tr.Suggestion), 15); text.TextWrapping = TextWrapping.Wrap;
                next.Children.Add(text);
                panel.Children.Add(next);
            }
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            if (retry is not null)
            {
                var again = Primary(T("phone.retry"), retry);
                AutomationId(again, "phone.retry");
                actions.Children.Add(again);
            }
            actions.Children.Add(CopyReportButton(gameId, [tr.Kind], () => message + "\n" + diagnostics));
            panel.Children.Add(actions);
            panel.Children.Add(ReportHintText());
        }
        var log = string.Join("\n", tr.Log.Select(B)) + (diagnostics.Length > 0 && state is not ("running" or "succeeded") ? "\n\n" + diagnostics : "");
        if (log.Trim().Length > 0) panel.Children.Add(DetailsToggle(T("phone.details"), log.Trim()));
        return panel;
    }

    /// <summary>「详细过程」：自己画的折叠头，箭头是矢量路径（Expander 的箭头是字体字形，部分 Windows 字体里没有，显示成一个「厂」字）</summary>
    private Control DetailsToggle(string header, string text)
    {
        var body = new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 260, IsVisible = false };
        var chevron = new Avalonia.Controls.Shapes.Path { Data = Geometry.Parse("M 0,0 L 5,5 L 0,10"), Stroke = Brush.Parse("#A8A6A1"), StrokeThickness = 1.6,
            Width = 7, Height = 11, VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = RelativePoint.Center };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(chevron);
        head.Children.Add(Muted(header, 14));
        var toggle = new Button { Content = head, Background = Brushes.Transparent, Padding = new Thickness(0, 4), BorderThickness = new Thickness(0) };
        AutomationId(toggle, "phone.details");
        toggle.Click += (_, _) => { body.IsVisible = !body.IsVisible; chevron.RenderTransform = body.IsVisible ? new RotateTransform(90) : null; };
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
