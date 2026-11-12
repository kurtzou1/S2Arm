// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

// 批量出包（v0.2.4，照 Mac S2ArmLauncherModel+Batch.swift / BatchExportView.swift）：一次放进多款 → 识别完列成清单，每款勾平台
// （Windows 只出 iPhone，Mac 一栏置灰）→ 一批共用一个存放位置 → 起一个出包编排作业（export，剃刀 H13）一款接一款地出。
// 清单、状态和规则（下一个出谁、磁盘满暂停、继续 / 重试 / 取消、汇总）在共用后端 pack/jobs/batch.py，执行在 pack/jobs/export_plan.py，这里只发起作业、画状态。
public sealed partial class EnvironmentWindow
{
    /// <summary>出包前清单里的一行：识别出来的一款，勾没勾 iPhone；不能出的写原因（缺密钥、缺文件），勾选置灰、不进批次</summary>
    private sealed class BatchRow(string id, string name, bool iphone, string? problem)
    {
        public string Id { get; } = id;
        public string Name { get; } = name;
        public bool Iphone { get; set; } = iphone;
        public string? Problem { get; } = problem;
    }

    private List<BatchRow> batchDraft = [];
    private IReadOnlyList<ImportOutcome.Unrecognized> batchUnrecognized = [];
    // 后端批次（batch.py 的结果，出包中途关掉启动器也在）；这批是不是正在一款接一款地出；玩家点了取消、等正在出的那款停下
    private BatchState? batchState;
    private bool batchRunning, batchStopping;
    private string batchError = "";
    /// <summary>控制口 POST /batch 指定的每款平台（AI 操作同 Mac：可以要 Mac，这台出不了的记失败「这台电脑出不了这个平台的包」）；界面清单为 null，按勾选出 iPhone</summary>
    private Dictionary<string, string[]>? batchControlPlatforms;

    /// <summary>放进来的几款列成清单（导入完多于 1 款时调）：iPhone 默认跟着出包页的勾选；缺东西的款写原因。正在出一批时只回到清单页</summary>
    private void OpenBatch(IReadOnlyList<string> ids, IReadOnlyList<ImportOutcome.Unrecognized> unrecognized)
    {
        if (batchRunning) { Navigate("batch"); return; }
        batchDraft = ids.Select(id => catalog?.Games.FirstOrDefault(g => string.Equals(g.Id, id, StringComparison.OrdinalIgnoreCase) && !g.Hidden))
            .OfType<LibraryGame>().Select(g =>
            {
                var problem = g.Missing.Count > 0 ? T("library.requirements") + " · " + string.Join(" / ", g.Missing)
                    : g.NeedsKeys && catalog?.KeysReady != true ? T("batch.keys") : null;
                return new BatchRow(g.Id, g.Name, exportIos, problem);   // 缺东西的款也照勾（只写原因，v0.3.1 不预先挡）：作业层核实，真缺就这一款失败、不挡后面
            }).ToList();
        batchUnrecognized = unrecognized;
        batchState = null; batchError = "";   // 新清单出包时 create 会盖掉上一批；没出包就退出时重读回来（CloseBatchDraft）
        locationsFor = null;   // 存放位置按第一款重读（剩余空间是当时的）
        Navigate("batch");
    }

    private LibraryGame? BatchGame(string id) => catalog?.Games.FirstOrDefault(g => g.Id == id && !g.Hidden);

    /// <summary>页面（同出包页的 DockPanel：内容滚动、底栏固定）；不是清单页返回 false</summary>
    private bool RenderBatchPage()
    {
        if (page != "batch") return false;
        EnsureTicker();
        var content = new StackPanel { Spacing = 18, Margin = new Thickness(32, 32, 32, 24), MaxWidth = 960 };
        content.Children.Add(Action("export.back", LeaveBatch));
        var title = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 16 };
        title.Children.Add(Label(T("batch.title"), 30));
        var hint = Muted(T("batch.hint")); hint.VerticalAlignment = VerticalAlignment.Bottom;
        Grid.SetColumn(hint, 1); title.Children.Add(hint);
        content.Children.Add(title);
        if (batchState is { } state)
        {
            content.Children.Add(Label(T("batch.summary").Replace("{0}", state.Summary.Total.ToString())
                .Replace("{1}", state.Summary.Completed.ToString()).Replace("{2}", state.Summary.Failed.ToString()), 16));
            if (state.Paused == "disk_full") { var paused = Muted(T("batch.paused"), 14); paused.Foreground = Brush.Parse("#FFC857"); content.Children.Add(paused); }
            // 上次没出完（启动器退出 / 取消）：说停在第几款，底栏「继续」只出还没出的（剃刀 H13）
            else if (!batchRunning && state.Summary.Pending + state.Summary.Cancelled > 0 && state.StoppedAt > 0)
            { var stopped = Muted(T("batch.stopped_at").Replace("{0}", state.StoppedAt.ToString()), 14); AutomationId(stopped, "batch.stopped_at"); content.Children.Add(stopped); }
        }
        if (batchError.Length > 0) content.Children.Add(new TextBlock { Text = B(batchError), FontSize = 13, Foreground = Brush.Parse("#E55"), TextWrapping = TextWrapping.Wrap });
        if (batchState is null) RenderBatchDraft(content); else RenderBatchProgress(content, batchState);

        Control? top = PhonePill() is null ? null
            : new Border { Padding = new Thickness(32, 14, 32, 0), Child = LiveSlot(PhonePill), HorizontalAlignment = HorizontalAlignment.Right };
        ShowPage("batch", content, top, BatchBottomBar());
        return true;
    }

    // ---- 出包前 ----

    private void RenderBatchDraft(StackPanel content)
    {
        if (batchDraft.FirstOrDefault() is { } first && BatchGame(first.Id) is { } firstGame) content.Children.Add(LocationRow(firstGame, "batch.location"));
        var ok = batchDraft.ToList();
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), ColumnSpacing = 10, Margin = new Thickness(14, 6, 14, 0) };
        head.Children.Add(Muted(T("batch.game")));
        var allIphone = Action("batch.all", () =>
        {
            var all = ok.All(r => r.Iphone);
            foreach (var r in ok) r.Iphone = !all;
            Render();
        }, ok.Count > 0 && !batchRunning);
        allIphone.Content = T("batch.all") + " iPhone";
        AutomationId(allIphone, "batch.all.iphone");
        Grid.SetColumn(allIphone, 1); head.Children.Add(allIphone);
        var allMac = Action("batch.all", () => { }, false);   // Windows 出不了 Mac 版：置灰
        allMac.Content = T("batch.all") + " Mac";
        AutomationId(allMac, "batch.all.mac");
        Grid.SetColumn(allMac, 2); head.Children.Add(allMac);
        content.Children.Add(head);
        // Mac 一栏置灰的原因写出来（同单款出包页 Mac 卡片「仅 Mac 可出」）
        var macOnly = Muted(T("batch.mac_only")); macOnly.HorizontalAlignment = HorizontalAlignment.Right; macOnly.Margin = new Thickness(14, 0, 14, 0);
        AutomationId(macOnly, "batch.mac_only");
        content.Children.Add(macOnly);
        foreach (var row in batchDraft)
        {
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto"), ColumnSpacing = 14 };
            line.Children.Add(BatchCover(row.Id));
            var name = Label(row.Name, 15); name.VerticalAlignment = VerticalAlignment.Center; name.TextWrapping = TextWrapping.NoWrap; name.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetColumn(name, 1); line.Children.Add(name);
            if (row.Problem is { } problem)   // 只提示、不挡（v0.3.1）：原因写在名字下面，照样能勾
            {
                line.Children.Remove(name);
                var named = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
                named.Children.Add(name);
                var why = Muted(problem); why.Foreground = Brush.Parse("#FFC857"); why.TextWrapping = TextWrapping.Wrap;
                named.Children.Add(why);
                Grid.SetColumn(named, 1); line.Children.Add(named);
            }
            {
                var iphone = new CheckBox { Content = "iPhone", IsChecked = row.Iphone, IsEnabled = !batchRunning, MinWidth = 96, VerticalAlignment = VerticalAlignment.Center };
                AutomationId(iphone, "batch.iphone." + row.Id);
                iphone.IsCheckedChanged += (_, _) => { row.Iphone = iphone.IsChecked == true; Render(); };
                Grid.SetColumn(iphone, 2); line.Children.Add(iphone);
                var mac = new CheckBox { Content = "Mac", IsChecked = false, IsEnabled = false, MinWidth = 70, VerticalAlignment = VerticalAlignment.Center };
                AutomationId(mac, "batch.mac." + row.Id);
                Grid.SetColumn(mac, 3); line.Children.Add(mac);
            }
            content.Children.Add(Card(line, 12));
        }
        foreach (var source in batchUnrecognized)
        {
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 14 };
            line.Children.Add(new Border { Width = 64, Height = 36, CornerRadius = new CornerRadius(6), Background = Brush.Parse("#26262A"),
                Child = new TextBlock { Text = "?", FontSize = 18, Foreground = Brush.Parse("#8C8A85"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
            var name = Label(source.FileName, 15); name.VerticalAlignment = VerticalAlignment.Center; name.TextWrapping = TextWrapping.NoWrap; name.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetColumn(name, 1); line.Children.Add(name);
            var why = Muted(T("batch.unrecognized").Replace("{0}", B(source.Reason))); why.Foreground = Brush.Parse("#E05C5C"); why.VerticalAlignment = VerticalAlignment.Center; why.MaxWidth = 360;
            Grid.SetColumn(why, 2); line.Children.Add(why);
            content.Children.Add(Card(line, 12));
        }
    }

    // ---- 出包中 / 出完 ----

    private void RenderBatchProgress(StackPanel content, BatchState state)
    {
        foreach (var item in state.Items)
        {
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 14 };
            line.Children.Add(BatchCover(item.GameId));
            var text = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            var name = Label(item.Name, 15); name.TextWrapping = TextWrapping.NoWrap; name.TextTrimming = TextTrimming.CharacterEllipsis;
            text.Children.Add(name);
            foreach (var p in item.Platforms)   // 正在出的那行带当前阶段：活格子，计时器每秒只刷新它
            {
                var (gameId, platform, result) = (item.GameId, p, item.Result(p));
                text.Children.Add(result.State == "running" ? LiveSlot(() => BatchPlatformLine(gameId, platform, result)) : BatchPlatformLine(gameId, platform, result));
            }
            Grid.SetColumn(text, 1); line.Children.Add(text);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            if (item.Any("failed"))
            {
                if (item.Platforms.Any(p => item.Result(p).Code == "disk_full")) actions.Children.Add(Action("batch.free", OpenStorage, !PackBusy));   // 同出包失败页「释放空间」
                var retry = Action("batch.retry", () => _ = BatchCommandAsync("retry", ["--game", item.GameId]), !PackBusy);
                AutomationId(retry, "batch.retry." + item.GameId);
                actions.Children.Add(retry);
            }
            if (item.Platforms.Contains("iphone") && item.Result("iphone").State == "completed" && BatchGame(item.GameId) is { } game)
                actions.Children.Add(Action("batch.install", () => { selectedGame = game.Id; readinessFor = null; Navigate("install"); }, !PackBusy));
            Grid.SetColumn(actions, 2); line.Children.Add(actions);
            content.Children.Add(Card(line, 12));
        }
    }

    private Control BatchPlatformLine(string gameId, string platform, BatchResult r)
    {
        var running = r.State == "running" && packRunning && packGame?.Id == gameId;
        var text = (platform == "iphone" ? "iPhone" : "Mac") + " · " + T("batch.state." + r.State);
        if (running && packTrack.Plan.FirstOrDefault(m => m.Id == packTrack.Current) is { } stage) text += " · " + B(stage.Label);
        if (r.State == "pending" && r.Interrupted) text += " · " + T("batch.interrupted");
        if (r.State == "failed" && r.Message.Length > 0) text += "：" + B(r.Message);
        var (mark, color) = r.State switch
        {
            "completed" => ("✓", "#52C87A"), "failed" => ("✕", "#E05C5C"), "running" => ("●", "#FFC857"), "cancelled" => ("–", "#8C8A85"), _ => ("○", "#8C8A85")
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(new TextBlock { Text = mark, FontSize = 13, Foreground = Brush.Parse(color) });
        var label = new TextBlock { Text = text, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, MaxWidth = 560,
            Foreground = r.State == "failed" ? Brush.Parse("#E05C5C") : Brush.Parse("#A8A6A1") };
        row.Children.Add(label);
        return row;
    }

    private Control BatchCover(string gameId)
    {
        Control cover = BatchGame(gameId) is { } game ? GameCover(game, 48) : new Border { Width = 48, Height = 48, Background = Brush.Parse("#26262A") };
        return new Border { Width = 48, Height = 48, CornerRadius = new CornerRadius(6), ClipToBounds = true, Child = cover, VerticalAlignment = VerticalAlignment.Center };
    }

    // ---- 底栏 ----

    private Control BatchBottomBar()
    {
        var inner = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*,Auto"), ColumnSpacing = 12 };
        void Put(Control c, int column) { Grid.SetColumn(c, column); inner.Children.Add(c); }
        if (batchState is null)
        {
            var count = batchDraft.Count(r => r.Iphone);
            var start = Primary(T("batch.start").Replace("{0}", count.ToString()), () => _ = StartBatchAsync(), count > 0 && !PackBusy && !libraryBusy && !batchRunning);
            AutomationId(start, "batch.start");
            Put(start, 3);
        }
        else if (batchRunning)
        {
            var cancel = Action("batch.cancel", StopBatch, !batchStopping);
            AutomationId(cancel, "batch.cancel");
            Put(cancel, 3);
        }
        else
        {
            // 暂停着（磁盘满）只给「重试」：它解除暂停、重出失败的那个平台；「继续」不解除暂停（审计 P1-164，同 Mac）
            if (batchState.Summary.Failed > 0 || batchState.Paused is not null) Put(Action("batch.retry_failed", () => _ = BatchCommandAsync("retry"), !PackBusy), 0);
            if (batchState.Paused is null && (batchState.Summary.Cancelled > 0 || batchState.Summary.Pending > 0))
            {
                var resume = Action("batch.resume", () => _ = BatchCommandAsync("resume"), !PackBusy);
                AutomationId(resume, "batch.resume");
                Put(resume, 1);
            }
            var close = Action("batch.close", () => _ = CloseBatchAsync());
            AutomationId(close, "batch.close");
            Put(close, 3);
        }
        return new Border { BorderBrush = Brush.Parse("#12FFFFFF"), BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(32, 14), Child = inner };
    }

    /// <summary>顶栏胶囊（同 Mac batchPill）：正在出一批，或上次还有没出完的；点了回清单页</summary>
    private Button? BatchPill()
    {
        if (page == "batch" || !(batchRunning || (batchState?.Unfinished ?? 0) > 0)) return null;
        var pill = new Button
        {
            Content = batchRunning ? T("batch.title") : T("batch.unfinished").Replace("{0}", batchState!.Unfinished.ToString()),
            Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(16), Background = Brush.Parse("#29292D"), Foreground = Ink
        };
        AutomationId(pill, "top.batch");
        pill.Click += (_, _) => { if (!libraryBusy) importDialog = null; Navigate("batch"); };
        return pill;
    }

    // ---- 流程 ----

    /// <summary>后端跑一条批次命令，结果换上 batchState；失败写在页面上，返回 false</summary>
    private async Task<bool> BatchRunAsync(string command, IEnumerable<string>? arguments = null)
    {
        var outcome = await BatchClient.RunAsync(paths, privateRoot, command, arguments);
        if (outcome.Error is { } error) { batchError = error; return false; }
        batchError = "";
        batchState = outcome.State;
        return true;
    }

    /// <summary>点「出包（N 款）」：后端建批次（一批共用出包页选的存放位置），起出包编排作业一款接一款地出</summary>
    /// <param name="installAfter">「更新并重新出这几款」排的批：整批出完逐款装到 iPhone（InstallModePage.cs BatchFinishedAsync）</param>
    private async Task StartBatchAsync(bool installAfter = false)
    {
        if (batchRunning || PackBusy) return;
        batchInstallAfter = installAfter;   // 每批自己定：界面 / 控制口建的批不接着装
        var control = batchControlPlatforms; batchControlPlatforms = null;
        var entries = control is null
            ? batchDraft.Where(r => r.Iphone).Select(r => new BatchClient.Entry(r.Id, r.Name, ["iphone"])).ToList()
            : batchDraft.Where(r => control.ContainsKey(r.Id)).Select(r => new BatchClient.Entry(r.Id, r.Name, control[r.Id])).ToList();
        if (entries.Count == 0) return;
        var location = locationsFor == batchDraft[0].Id && exportLocation.Length > 0 ? exportLocation : null;
        if (!await BatchRunAsync("create", ["--json", BatchClient.CreateJson(entries, location)]) || batchState is null) { Render(); return; }
        batchDraft = []; batchUnrecognized = [];
        RunBatchExport();
    }

    /// <summary>按批次文件起出包编排作业（剃刀 H13，pack/jobs/export_plan.py）：下一个出谁、记账、磁盘满暂停、这台电脑出不了的平台都在后端；
    /// 这里只显示它的事件（ExportPages.cs OnExportEvent），留在清单页看整批进度（单款进度页可从游戏库胶囊打开）</summary>
    private void RunBatchExport()
    {
        batchRunning = true; batchStopping = false; batchError = "";
        packJob = BeginJob(JobKind.Pack);
        sessionHidden = true;
        Render();
        packOperation = RunExportAsync(ExportStream.BatchPlan(), batch: true);
    }

    /// <summary>编排作业结束（ExportPages.cs RunExportAsync 收尾调）：重读批次；整批出完接着装（更新发起的那批）</summary>
    private async Task BatchExportEndedAsync(LibraryJobResult? report, string? error)
    {
        batchRunning = false; batchStopping = false;
        await ReloadBatchAsync();
        if (error is not null) batchError = error;
        else if (report is { State: "failed" }) batchError = report.Message;   // 编排作业自己失败（批次记录写不进、已有一个在出）：原因写在清单页
        Render();
        if (batchState is { Summary.Done: true }) _ = BatchFinishedAsync();
    }

    /// <summary>底栏「取消」：取消编排作业，它把正在出的那步停下，正在出的和没开始的记已取消（已出好的保留）</summary>
    private void StopBatch()
    {
        batchStopping = true;
        packJob?.Cancellation.Cancel();
        Render();
    }

    /// <summary>继续出剩下的（取消后 / 启动器退出后重开）、重试失败的（给游戏号只重试这一款；磁盘满那款释放空间后也走这里）：
    /// 后端改好批次再起编排作业，只出还没出的</summary>
    private async Task BatchCommandAsync(string command, IEnumerable<string>? arguments = null)
    {
        if (packRunning) return;
        if (!await BatchRunAsync(command, arguments)) { Render(); return; }
        if (batchRunning) { Render(); return; }
        RunBatchExport();
    }

    /// <summary>返回：出包中 / 出完都只是离开清单页（批次留着，顶栏胶囊能回来）；出包前的清单不要了，重读上一批（可能还有没出完的）</summary>
    private void LeaveBatch()
    {
        if (batchState is null && !batchRunning) { batchDraft = []; batchUnrecognized = []; _ = ReloadBatchAsync(); }
        Navigate("library");
    }

    /// <summary>「完成」：这批的结果看完了，清掉批次（不影响已出好的包）</summary>
    private async Task CloseBatchAsync()
    {
        if (batchRunning) { Navigate("library"); return; }
        if (await BatchRunAsync("clear")) batchState = null;
        batchDraft = []; batchUnrecognized = [];
        Navigate("library");
    }

    private async Task ReloadBatchAsync()
    {
        if (await BatchRunAsync("show")) Render();
    }

    /// <summary>启动器刚打开：上次没出完的批次读回来（正在出的那款记成被打断、重新排队），顶栏胶囊提示继续。没有批次时后端报错，不显示</summary>
    private async Task RecoverBatchAsync()
    {
        var outcome = await BatchClient.RunAsync(paths, privateRoot, "recover");
        if (outcome.State is null) return;
        batchState = outcome.State;
        Render();
    }
}
