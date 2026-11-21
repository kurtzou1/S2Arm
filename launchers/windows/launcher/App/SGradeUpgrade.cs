using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// <summary>S 级优化升级（11-18 维护者：点了才升、可批量，名字写明批量升级、有全选；同 Mac S2ArmLauncherModel+SGradeUpgrade.swift）。
/// 排队只在作业层一份（sgradeUpgradeBatch，两端共用；关掉升级页 / 窗口队列照常跑）：界面只提交 / 追加号、调停止（sgradeUpgradeStop）、读状态。
/// 状态来源：跑队列作业的事件（type=batch 每款 start / end，整款进度 sgradeProgress 带 gameId）实时更新；队列在跑时每 1.5 秒查 sgradeUpgradeStatus；
/// 都盖在游戏库 catalog 的 sgradeState / sgradeProgress 上。这款封面画进度、主按钮（装到 iPhone / 出包）写「正在升级 xx%」/「排队中」不可点</summary>
public sealed partial class EnvironmentWindow
{
    /// <summary>游戏号 → (状态, 进度)：事件与状态查询来的实时值</summary>
    private readonly Dictionary<string, (string State, double? Progress)> sgradeLive = new(StringComparer.OrdinalIgnoreCase);
    private SGradeBatch? sgradeBatchLive;
    private bool sgradePolling;
    private readonly Dictionary<string, string> sgradeErrors = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>升级页上勾选的款</summary>
    private readonly HashSet<string> sgradeSelected = new(StringComparer.OrdinalIgnoreCase);

    private string? SGradeState(string id) => sgradeLive.TryGetValue(id, out var l) ? l.State : catalog?.Games.FirstOrDefault(g => g.Id == id)?.SGradeState;
    /// <summary>这款正在升级或排队（含旧字段 sgradeUpgrading）</summary>
    private bool SGradeBusy(string id) => SGradeState(id) is "running" or "queued"
        || (SGradeState(id) is null && (catalog?.Games.Any(g => g.Id == id && g.SGradeUpgrading) ?? false));
    private bool SGradeUpgrading(LibraryGame game) => SGradeBusy(game.Id);
    private bool SGradeQueued(string id) => SGradeState(id) == "queued";
    private double? SGradeProgress(LibraryGame game) => SGradeState(game.Id) != "running" ? null
        : sgradeLive.TryGetValue(game.Id, out var l) && l.Progress is { } p ? p : game.SGradeProgress;
    /// <summary>这一批：第几款 / 共几款（没在跑为 null）</summary>
    private SGradeBatch? sgradeBatch => (sgradeBatchLive ?? catalog?.SGradeBatch) is { Running: true } b ? b : null;

    /// <summary>主按钮上的字：排着的「排队中」；在升的「正在升级 xx%」，没有百分比写「正在升级…」</summary>
    private string SGradeUpgradingTitle(LibraryGame game) => SGradeQueued(game.Id) ? T("sgrade.upgrade.queued")
        : SGradeProgress(game) is { } p ? T("sgrade.upgrading").Replace("{0}", ((int)Math.Floor(p * 100)).ToString())
        : T("sgrade.upgrading.wait");

    /// <summary>这款还有没补上的段（作业层 sgradeScan 的 bfPending：iPhone / Mac 包任一边要补）；没给这个字段（旧版作业层）当作要补</summary>
    private static bool SGradePending(JsonElement g) =>
        !g.TryGetProperty("bfPending", out var bf) || bf.ValueKind != JsonValueKind.Object || bf.EnumerateObject().Any(p => p.Value.ValueKind == JsonValueKind.True);

    /// <summary>这一行不能点也不能勾：在升 / 排队、刚做完，或已没有要补的段（被停 / 轮到时在玩的除外，可再点）</summary>
    private bool SGradeLocked(string id, bool pending)
    {
        if (SGradeBusy(id) || SGradeState(id) == "done") return true;
        if (SGradeState(id) is "incomplete" or "skipped") return false;
        return !pending;
    }

    /// <summary>升级页行按钮上的字：在升「正在升级 37%」、排着「排队中」、做完 / 已没有要补的「已完成」、轮到时在玩「正在玩，稍后再升」、被停 / 出错「继续升级」、其余「升级」</summary>
    private string SGradeRowTitle(string id, bool pending = true)
    {
        var game = catalog?.Games.FirstOrDefault(g => g.Id == id);
        return SGradeState(id) switch
        {
            "running" => game is not null && SGradeProgress(game) is { } v ? T("sgrade.upgrade.rowProgress").Replace("{0}", ((int)Math.Floor(v * 100)).ToString()) : T("sgrade.upgrade.rowBusy"),
            "queued" => T("sgrade.upgrade.queued"),
            "done" => T("sgrade.upgrade.done"),
            "skipped" => T("sgrade.upgrade.skipped"),
            "incomplete" => T("sgrade.upgrade.resume"),
            _ => SGradeBusy(id) ? T("sgrade.upgrade.rowBusy") : SGradeLocked(id, pending) ? T("sgrade.upgrade.done") : T("sgrade.upgrade.row"),
        };
    }

    /// <summary>单款「升级」或「批量升级所选」：都提交给作业层队列（没在跑就由这次的作业跑队列，在跑就追加到队尾、作业立刻返回）</summary>
    private void UpgradeSGrade(IEnumerable<string> ids)
    {
        var list = ids.Where(id => !SGradeBusy(id)).ToList();
        if (list.Count == 0) return;
        foreach (var id in list) { sgradeLive[id] = ("queued", null); sgradeErrors.Remove(id); sgradeSelected.Remove(id); }   // 先画排队中，以作业层为准
        Render();
        // 轮询不在这里起：作业层收下号、写好队列之前查到的是「没在跑」，轮询会当场停、还会把刚画的排队中清掉。
        //   本次作业跑队列：第一条 batch 事件（队列已写好）起轮询（IngestSGrade）；追加到在跑的队列：作业立刻返回，返回后起轮询；
        //   作业结束（整批做完 / 被停）再读一次状态收尾，页底回到「批量升级所选」
        _ = RunSGradeBatchAsync(list);
    }

    private async Task RunSGradeBatchAsync(List<string> ids)
    {
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("sgradeUpgradeBatch", "", new Dictionary<string, object?> { ["gameIds"] = ids }),
                e => Dispatcher.UIThread.Post(() => IngestSGrade(e)), CancellationToken.None);
            if (!job.Report.Succeeded && job.Report.State != "cancelled" && ids.Count == 1) sgradeErrors[ids[0]] = job.Report.Message;   // 提交没成：就近写原因，不弹框；玩家点「停止」不算失败
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("S2Arm sgradeUpgradeBatch: " + error.Message); }
        if (await ReadSGradeStatusAsync()) _ = PollSGradeAsync();
        await RefreshLibraryAsync();
        Render();
    }

    /// <summary>停止整批：排着的不做，在升的那款作业层按记号保留已做完的段（显示「升级未完成」），已做完的不动</summary>
    private void StopSGrade() => _ = StopSGradeAsync();
    private async Task StopSGradeAsync()
    {
        try { await PackJobClient.RunAsync(PackRequest("sgradeUpgradeStop", ""), null, CancellationToken.None); }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("S2Arm sgradeUpgradeStop: " + error.Message); }
        await ReadSGradeStatusAsync();
        await RefreshLibraryAsync();
        Render();
    }

    /// <summary>跑队列作业的一条事件：batch start → 在升（0）；batch end → 结局；带 sgradeProgress → 整款进度（只增不减，SGradeLiveProgress）；index / count → 批次</summary>
    private void IngestSGrade(JsonElement e)
    {
        if (!e.TryGetProperty("gameId", out var g) || g.ValueKind != JsonValueKind.String || g.GetString() is not { Length: > 0 } id) return;
        if (e.TryGetProperty("index", out var i) && i.ValueKind == JsonValueKind.Number && e.TryGetProperty("count", out var n) && n.ValueKind == JsonValueKind.Number)
            sgradeBatchLive = new SGradeBatch(true, i.GetInt32(), n.GetInt32());
        if (e.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String && t.GetString() == "batch")
        {
            _ = PollSGradeAsync();   // 队列已在作业层写好：从这里起轮询（只起一个）
            var phase = e.TryGetProperty("phase", out var ph) && ph.ValueKind == JsonValueKind.String ? ph.GetString() : null;
            if (phase == "start") sgradeLive[id] = ("running", 0);
            else if (phase == "end")
            {
                var status = e.TryGetProperty("status", out var st) && st.ValueKind == JsonValueKind.String ? st.GetString() ?? "done" : "done";
                sgradeLive[id] = (status is "updated" or "unchanged" ? "done" : status, null);
                if (status == "failed" && e.TryGetProperty("reason", out var r) && r.ValueKind == JsonValueKind.String) sgradeErrors[id] = r.GetString() ?? "";
                _ = RefreshLibraryAsync();
            }
        }
        else if (SGradeLiveProgress.FromEvent(e) is { } p)
            sgradeLive[id] = ("running", sgradeLive.TryGetValue(id, out var old) ? SGradeLiveProgress.Running(p, old.State, old.Progress) : SGradeLiveProgress.Running(p, null, null));
        Render();
    }

    /// <summary>队列在跑时每 1.5 秒查一次作业层状态（只起一个轮询）；跑过、停了再重读一次游戏库</summary>
    private async Task PollSGradeAsync()
    {
        if (sgradePolling) return;
        sgradePolling = true;
        var ran = false;
        try
        {
            while (await ReadSGradeStatusAsync()) { ran = true; await Task.Delay(1500); }
        }
        finally { sgradePolling = false; }
        if (!ran) return;   // 一次都没在跑：游戏库不用重读
        await RefreshLibraryAsync();
        Render();
    }

    /// <summary>读 sgradeUpgradeStatus，更新各款状态与批次；返回队列是否还在跑</summary>
    private async Task<bool> ReadSGradeStatusAsync()
    {
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("sgradeUpgradeStatus", ""), null, CancellationToken.None);
            if (!job.Report.Succeeded) return false;
            var r = job.Report.Result;
            sgradeBatchLive = SGradeBatch.Parse(r);
            var before = new Dictionary<string, (string State, double? Progress)>(sgradeLive, StringComparer.OrdinalIgnoreCase);   // 在升的款与之前的值取较大（只增不减）
            sgradeLive.Clear();
            if (r.TryGetProperty("games", out var games) && games.ValueKind == JsonValueKind.Array)
                foreach (var g in games.EnumerateArray())
                    if (g.TryGetProperty("gameId", out var id) && id.GetString() is { Length: > 0 } gid && g.TryGetProperty("state", out var st) && st.GetString() is { } state)
                    {
                        double? p = g.TryGetProperty("progress", out var pe) && pe.ValueKind == JsonValueKind.Number ? pe.GetDouble() : null;
                        sgradeLive[gid] = (state, state != "running" ? p : before.TryGetValue(gid, out var old) ? SGradeLiveProgress.Running(p, old.State, old.Progress) : SGradeLiveProgress.Running(p, null, null));
                    }
            Render();
            return sgradeBatchLive.Running;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("S2Arm sgradeUpgradeStatus: " + error.Message); return false; }
    }

    /// <summary>启动后头一次读到游戏库：作业层队列还在跑（上次窗口关了、队列照跑）就接着轮询；只看这一次，轮询结束后的重读不再触发</summary>
    private bool sgradeResumeChecked;
    private void ResumeSGradeWatch()
    {
        if (sgradeResumeChecked || catalog is null) return;
        sgradeResumeChecked = true;
        if (catalog.SGradeBatch is { Running: true }) _ = PollSGradeAsync();
    }

    /// <summary>升级中的封面（小图标）：压暗一层、中间百分比（没有百分比写「…」）、底部进度条（不定进度时满条半透明）</summary>
    private Control WithSGradeProgress(LibraryGame game, Control cover, int size)
    {
        if (!SGradeUpgrading(game)) return cover;
        var p = SGradeProgress(game);
        var grid = new Avalonia.Controls.Grid();
        grid.Children.Add(cover);
        grid.Children.Add(new Avalonia.Controls.Border { Background = new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromArgb(115, 0, 0, 0)), CornerRadius = new Avalonia.CornerRadius(8) });
        var queued = SGradeQueued(game.Id);   // 排着的只写「排队中」、不画在走的进度（不冒充在升）
        grid.Children.Add(new Avalonia.Controls.TextBlock { Text = queued ? T("sgrade.upgrade.queued") : p is { } v ? ((int)Math.Floor(v * 100)) + "%" : "…", FontSize = Math.Max(11, size / 5.0), FontWeight = Avalonia.Media.FontWeight.Bold,
            Foreground = Avalonia.Media.Brushes.White, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        if (!queued) grid.Children.Add(new Avalonia.Controls.ProgressBar { Minimum = 0, Maximum = 1, Value = p ?? 0, IsIndeterminate = p is null, Height = 4, MinHeight = 4,
            Foreground = Avalonia.Media.Brush.Parse("#E8C46A"), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Bottom, Margin = new Avalonia.Thickness(6, 0, 6, 6) });
        Avalonia.Automation.AutomationProperties.SetAutomationId(grid, "card.sgradeUpgrading");
        return grid;
    }

    /// <summary>选中区一行：升级没成的原因（红）/ 上次中途退出没做完「升级未完成，点 S 级优化继续」（金，点了打开升级页）</summary>
    private Control? SGradeLine(LibraryGame game)
    {
        if (SGradeUpgrading(game)) return null;
        if (sgradeErrors.TryGetValue(game.Id, out var why))
            return new Avalonia.Controls.TextBlock { Text = why, Foreground = Avalonia.Media.Brush.Parse("#FF6B6B"), FontSize = 13, TextWrapping = Avalonia.Media.TextWrapping.Wrap, MaxWidth = 720 };
        if (!game.SGradeIncomplete) return null;
        var b = new Avalonia.Controls.Button { Content = T("sgrade.upgrade.incomplete"), Background = Avalonia.Media.Brushes.Transparent, Padding = new Avalonia.Thickness(0),
            Foreground = Avalonia.Media.Brush.Parse("#E8C46A"), FontSize = 13 };
        b.Click += (_, _) => OpenSGradeUpgrade();
        Avalonia.Automation.AutomationProperties.SetAutomationId(b, "sgrade.incomplete." + game.Id);
        return b;
    }

}
