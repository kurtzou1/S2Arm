// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

// 批量出包（v0.2.4）：一批的清单、每款每个平台出到哪了、下一个出谁、磁盘满暂停、继续 / 重试 / 取消、汇总，全在共用后端 pack/jobs/batch.py（Mac 同一份）。
// 这里只跑它的命令、读它打印的那行 JSON；界面按 Next 一款接一款地发起单款出包。

/// <summary>一款里一个平台的结果（batch.py results[平台]）。Interrupted：上次关掉启动器时正在出，recover 后重新排队。</summary>
public sealed record BatchResult(string State, string Message, string? Code, string? Output, bool Interrupted);

/// <summary>批次里的一款：要出的平台按页面顺序（先 iPhone 后 Mac）。</summary>
public sealed record BatchItem(string GameId, string Name, IReadOnlyList<string> Platforms, IReadOnlyDictionary<string, BatchResult> Results)
{
    public BatchResult Result(string platform) => Results[platform];
    public bool Any(string state) => Platforms.Any(p => Results[p].State == state);
}

/// <summary>按款数的汇总（batch.py summary）；Done = 没有还没出完的、也没暂停。</summary>
public sealed record BatchSummary(int Total, int Completed, int Failed, int Cancelled, int Pending, bool Done);

/// <summary>后端给出的下一步：哪款的哪个平台。</summary>
public sealed record BatchStep(string GameId, string Platform);


/// <summary>batch.py show / 各命令打印的批次。</summary>
public sealed record BatchState(IReadOnlyList<BatchItem> Items, string? Location, string? Paused, BatchStep? Next, BatchSummary Summary)
{
    public static readonly string[] Platforms = ["iphone", "mac"];
    public static readonly string[] States = ["pending", "running", "completed", "failed", "cancelled"];

    /// <summary>还没出完的款数（还有平台没出的 + 取消的；暂停着时失败的也算，等「重试」）：顶栏「上次还有 N 款没出完」（同 Mac，审计 P1-168）。</summary>
    public int Unfinished => Summary.Pending + Summary.Cancelled + (Paused is not null ? Summary.Failed : 0);

    /// <summary>{} → null（没有批次）；形状不对抛 FormatException。</summary>
    public static BatchState? Parse(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) throw new FormatException("批次结果不是对象。");
        if (!root.TryGetProperty("batch", out var batch)) return null;
        if (batch.ValueKind != JsonValueKind.Object || !batch.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array)
            throw new FormatException("批次缺 items。");
        var list = new List<BatchItem>();
        foreach (var item in items.EnumerateArray())
        {
            var gid = Text(item, "gameId") ?? throw new FormatException("批次里有一款缺 gameId。");
            var platforms = item.TryGetProperty("platforms", out var ps) && ps.ValueKind == JsonValueKind.Array
                ? ps.EnumerateArray().Select(p => p.GetString() ?? "").ToList() : throw new FormatException("批次里有一款缺 platforms。");
            if (platforms.Count == 0 || platforms.Any(p => !Platforms.Contains(p))) throw new FormatException("平台不对：" + gid);
            var results = new Dictionary<string, BatchResult>(StringComparer.Ordinal);
            foreach (var p in platforms)
            {
                if (!item.TryGetProperty("results", out var rs) || rs.ValueKind != JsonValueKind.Object || !rs.TryGetProperty(p, out var r) || r.ValueKind != JsonValueKind.Object)
                    throw new FormatException("缺结果：" + gid + " " + p);
                var state = Text(r, "state") ?? "";
                if (!States.Contains(state)) throw new FormatException("状态不对：" + state);
                results[p] = new(state, Text(r, "message") ?? "", Text(r, "code"), Text(r, "output"),
                    r.TryGetProperty("interrupted", out var i) && i.ValueKind == JsonValueKind.True);
            }
            list.Add(new(gid, Text(item, "name") ?? gid, platforms, results));
        }
        BatchStep? next = null;
        if (root.TryGetProperty("next", out var n) && n.ValueKind == JsonValueKind.Object)
            next = new(Text(n, "gameId") ?? throw new FormatException("next 缺 gameId。"), Text(n, "platform") ?? throw new FormatException("next 缺 platform。"));
        if (!root.TryGetProperty("summary", out var s) || s.ValueKind != JsonValueKind.Object) throw new FormatException("批次缺 summary。");
        int Count(string key) => s.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
        var summary = new BatchSummary(Count("total"), Count("completed"), Count("failed"), Count("cancelled"), Count("pending"),
            s.TryGetProperty("done", out var d) && d.ValueKind == JsonValueKind.True);
        return new(list, Text(batch, "location"), Text(batch, "paused"), next, summary);
    }

    /// <summary>重开启动器后说「上次停在第几款」（从 1 数）：被打断的那款（启动器退出时正在出、后端重新排队并记 interrupted）；
    /// 没有被打断的就是第一款还有平台排着队的；都没有是 0</summary>
    public int StoppedAt
    {
        get
        {
            int First(Func<BatchResult, bool> hit) { for (var n = 0; n < Items.Count; n++) if (Items[n].Platforms.Any(p => hit(Items[n].Results[p]))) return n + 1; return 0; }
            var interrupted = First(r => r.State == "pending" && r.Interrupted);
            return interrupted > 0 ? interrupted : First(r => r.State is "pending" or "running");
        }
    }

    private static string? Text(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } t ? t : null;
}

/// <summary>一条批次命令的结果：State = 批次（没有批次时为 null），Error = 后端的 {error} 或跑不起来 / 读不懂的原因。</summary>
public sealed record BatchOutcome(BatchState? State, string? Error);

/// <summary>跑 pack/jobs/batch.py（随包 Python 的标准库，同 UpdateClient）。</summary>
public static class BatchClient
{
    /// <summary>出包前清单里勾好的一款（没勾平台的款不进批次）。</summary>
    public sealed record Entry(string GameId, string Name, IReadOnlyList<string> Platforms);

    /// <summary>控制口 POST /batch 的 games（同 Mac S2ArmControl）：[{gameId, platforms:[mac|iphone]}]，platforms 缺省 iphone、ios 认作 iphone；
    /// 同一款给两次按第一次。形状不对给错误句（控制口回 400）。</summary>
    public static (IReadOnlyList<(string GameId, string[] Platforms)> Games, string? Error) ControlGames(JsonElement body)
    {
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty("games", out var games) || games.ValueKind != JsonValueKind.Array || games.GetArrayLength() == 0)
            return ([], "games 要给 [{gameId, platforms:[mac|iphone]}]");
        var list = new List<(string, string[])>();
        foreach (var g in games.EnumerateArray())
        {
            if (g.ValueKind != JsonValueKind.Object || !g.TryGetProperty("gameId", out var id) || id.ValueKind != JsonValueKind.String || id.GetString() is not { Length: > 0 } gid)
                return ([], "games 里每项要有 gameId");
            string[] ps = g.TryGetProperty("platforms", out var p) && p.ValueKind == JsonValueKind.Array
                ? p.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString()! : "").Select(x => x == "ios" ? "iphone" : x).Distinct().ToArray()
                : ["iphone"];
            if (ps.Length == 0 || ps.Any(x => x is not ("iphone" or "mac"))) return ([], "platforms 只认 mac / iphone");
            if (!list.Any(x => string.Equals(x.Item1, gid, StringComparison.OrdinalIgnoreCase))) list.Add((gid, ps));
        }
        return (list, null);
    }

    /// <summary>create --json 的内容：{items:[{gameId,name,platforms}], location}；location 空 = 不传，后端按每款现在的位置。</summary>
    public static string CreateJson(IEnumerable<Entry> entries, string? location) => JsonSerializer.Serialize(new Dictionary<string, object?>
    {
        ["items"] = entries.Select(e => new Dictionary<string, object?> { ["gameId"] = e.GameId, ["name"] = e.Name, ["platforms"] = e.Platforms }).ToList(),
        ["location"] = string.IsNullOrEmpty(location) ? null : location
    });

    /// <summary>读 batch.py 打印的那行 JSON（null = 没跑起来 / 没输出）。</summary>
    public static BatchOutcome Read(JsonElement? line)
    {
        if (line is not { } root) return new(null, "batch.py 没有输出。");
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("error", out var error))
            return new(null, error.ValueKind == JsonValueKind.String ? error.GetString() : error.ToString());
        try { return new(BatchState.Parse(root), null); }
        catch (Exception e) when (e is FormatException or InvalidOperationException) { return new(null, e.Message); }
    }

    /// <summary>跑一条批次命令：show / create / mark / recover / cancel / resume / retry / clear。</summary>
    public static async Task<BatchOutcome> RunAsync(LauncherPaths paths, string privateRoot, string command, IEnumerable<string>? arguments = null)
    {
        var line = await UpdateClient.RunScriptAsync(paths, "batch.py",
            new[] { command, "--private-root", Path.GetFullPath(privateRoot) }.Concat(arguments ?? []), null, TimeSpan.FromSeconds(30));
        return Read(line);
    }
}

/// <summary>导入作业（partialResults）结果里批量出包要的：放进来的各款游戏号（按出现顺序去重，已在库里的也算），和认不出的来源（文件名 + 原因）。</summary>
public static class ImportOutcome
{
    public sealed record Unrecognized(string FileName, string Reason, string? Code);

    public static IReadOnlyList<string> GameIds(JsonElement result)
    {
        var ids = new List<string>();
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("imports", out var imports) && imports.ValueKind == JsonValueKind.Array)
            foreach (var row in imports.EnumerateArray())
                if (row.ValueKind == JsonValueKind.Object && row.TryGetProperty("id", out var id) && id.GetString() is { Length: > 0 } gid && !ids.Contains(gid, StringComparer.OrdinalIgnoreCase))
                    ids.Add(gid);
        return ids;
    }

    /// <summary>#797：这次放进来、但游戏库里只有更新 / DLC 没有本体的游戏号（导入结果 imports[].missingBase，按整批加完后的库判）。</summary>
    public static IReadOnlyList<string> MissingBase(JsonElement result)
    {
        var ids = new List<string>();
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("imports", out var imports) && imports.ValueKind == JsonValueKind.Array)
            foreach (var row in imports.EnumerateArray())
                if (row.ValueKind == JsonValueKind.Object && row.TryGetProperty("missingBase", out var m) && m.ValueKind == JsonValueKind.True
                    && row.TryGetProperty("id", out var id) && id.GetString() is { Length: > 0 } gid && !ids.Contains(gid, StringComparer.OrdinalIgnoreCase))
                    ids.Add(gid);
        return ids;
    }

    public static IReadOnlyList<Unrecognized> Failed(JsonElement result)
    {
        var rows = new List<Unrecognized>();
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("sources", out var sources) && sources.ValueKind == JsonValueKind.Array)
            foreach (var row in sources.EnumerateArray())
            {
                if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("status", out var status) || status.GetString() != "failed") continue;
                string S(string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
                rows.Add(new(S("fileName").Length > 0 ? S("fileName") : Path.GetFileName(S("path")), S("reason"), S("code") is { Length: > 0 } c ? c : null));
            }
        return rows;
    }
}
