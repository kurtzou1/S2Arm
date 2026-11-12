// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 出包编排作业 export 的事件（剃刀 H13，pack/jobs/export_plan.py 文件头）：每一步开始 step、子作业事件原样转发 child、每一步结束 stepEnded；
/// 终态 paused 时结果里有 pausedReason（disk_full / launcher_exit）与 stoppedAt（停在第几款）。界面只按这些机读字段显示，不猜文字。
/// </summary>
public static class ExportStream
{
    public sealed record Step(string GameId, string Platform, string Task, int Index, int Count);

    /// <summary>一步的结局（stepEnded.outcome）：State = completed / failed / cancelled</summary>
    /// <param name="Notes">出成了、但有阶段降级继续（v0.3.1，产物根 degrade.*.tsv 的「玩家提示」）：完成卡逐条显示；没有为空</param>
    public sealed record Outcome(string State, string Message, string? Code, string? Output, string? Ipa, long? IpaBytes, long? PackBytes, IReadOnlyList<string>? Notes = null);

    public abstract record Event(Step Where);
    public sealed record Started(Step Where) : Event(Where);
    /// <summary>子作业的一条事件（原样）</summary>
    public sealed record Child(Step Where, JsonElement Inner) : Event(Where);
    public sealed record Ended(Step Where, Outcome Outcome) : Event(Where);

    /// <summary>编排作业的一条事件 → 上面三种之一；心跳、阶段等编排作业自己的事件返回 null</summary>
    public static Event? Read(JsonElement e)
    {
        var type = Text(e, "type");
        if (type is not ("step" or "child" or "stepEnded") || !e.TryGetProperty("step", out var s) || s.ValueKind != JsonValueKind.Object) return null;
        var where = new Step(Text(s, "gameId") ?? "", Text(s, "platform") ?? "", Text(s, "task") ?? "", Number(s, "index") ?? 0, Number(s, "count") ?? 0);
        if (where.GameId.Length == 0 || where.Platform.Length == 0) throw new LibraryProtocolException("export step without game / platform");
        switch (type)
        {
            case "step": return new Started(where);
            case "child":
                if (!e.TryGetProperty("event", out var inner) || inner.ValueKind != JsonValueKind.Object) throw new LibraryProtocolException("export child without event");
                return new Child(where, inner);
            default:
                if (!e.TryGetProperty("outcome", out var o) || o.ValueKind != JsonValueKind.Object || Text(o, "state") is not ("completed" or "failed" or "cancelled") || Text(o, "state") is not { } state)
                    throw new LibraryProtocolException("export stepEnded without a known outcome state");
                return new Ended(where, new Outcome(state, Text(o, "message") ?? "", Text(o, "code"), Text(o, "output"), Text(o, "ipa"), Long(o, "ipaBytes"), Long(o, "packBytes"), Strings(o, "notes")));
        }
    }

    /// <summary>子作业的终态事件（child 里 type = result）→ 同单个作业的 LibraryJobResult（失败页的原因 / 建议照旧从这里读）；不是终态返回 null</summary>
    public static LibraryJobResult? ChildResult(JsonElement inner)
    {
        if (Text(inner, "type") != "result" || Text(inner, "state") is not { } state) return null;
        return new(state, Text(inner, "message") ?? "", inner.TryGetProperty("result", out var r) ? r.Clone() : default,
            inner.TryGetProperty("diagnostics", out var d) ? d.Clone() : default);
    }

    public sealed record Pause(string Reason, int StoppedAt);

    /// <summary>编排作业终态 paused 的原因与停在第几款；不是 paused 返回 null</summary>
    public static Pause? Paused(LibraryJobResult report) =>
        report.State == "paused" && report.Result.ValueKind == JsonValueKind.Object && Text(report.Result, "pausedReason") is { } reason
            ? new(reason, Number(report.Result, "stoppedAt") ?? 0) : null;

    /// <summary>就地出（出包页单款）的计划：不写批次文件</summary>
    public static Dictionary<string, object?> InlinePlan(string gameId, string name, IReadOnlyList<string> platforms, string? location, bool spaceOverride)
    {
        var plan = new Dictionary<string, object?>
        {
            ["source"] = "inline",
            ["items"] = new List<object> { new Dictionary<string, object?> { ["gameId"] = gameId, ["name"] = name, ["platforms"] = platforms } }
        };
        if (!string.IsNullOrEmpty(location)) plan["location"] = location;
        if (spaceOverride) plan["spaceOverride"] = true;
        return plan;
    }

    /// <summary>按批次文件出（批量出包、继续 / 重试之后）</summary>
    public static Dictionary<string, object?> BatchPlan() => new() { ["source"] = "batch" };

    private static string? Text(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } t ? t : null;
    private static int? Number(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : null;
    private static IReadOnlyList<string> Strings(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString() ?? "").Where(x => x.Length > 0).ToList() : [];

    private static long? Long(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) ? n : null;
}
