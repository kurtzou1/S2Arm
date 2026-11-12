// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

/// <summary>One step of the job's plan event (pack/jobs/milestones.py). Expected seconds only come from this machine's history.</summary>
public sealed record Milestone(string Id, string Label, string Purpose, double? Expected, string? Source, int Samples, bool Reuse)
{
    /// <summary>Same rule as the Mac adapter (Milestones.swift): history with samples, or a reused step (0 s when no reuse record).</summary>
    public double? Measured => Source == "reuse" ? Expected ?? 0 : Source == "history" && Samples > 0 ? Expected : null;

    public static IReadOnlyList<Milestone> ParsePlan(JsonElement milestones)
    {
        var plan = new List<Milestone>();
        foreach (var m in milestones.EnumerateArray())
        {
            double? expected = m.TryGetProperty("expected", out var e) && e.ValueKind == JsonValueKind.Number ? e.GetDouble() : null;
            plan.Add(new(LibraryJobResult.Text(m, "id"), LibraryJobResult.Text(m, "label"), LibraryJobResult.Text(m, "purpose", true), expected,
                m.TryGetProperty("source", out var s) && s.ValueKind == JsonValueKind.String ? s.GetString() : null,
                m.TryGetProperty("samples", out var n) && n.ValueKind == JsonValueKind.Number ? n.GetInt32() : 0,
                m.TryGetProperty("reuse", out var r) && r.ValueKind == JsonValueKind.True));
        }
        return plan.AsReadOnly();
    }
}

/// <summary>
/// Time estimate of a milestone plan. Port of the Mac adapter's MilestoneEstimate (one rule for both launchers; only real readings,
/// 维护者 10-25): the current step's rate when it has a real fraction ≥ 5 %; a whole-job remaining time only when the current and every
/// later step have a local record, scaled by the calibration of the finished steps (actual ÷ record, clamped to 0.5–3).
/// </summary>
public sealed record MilestoneEstimate(IReadOnlyList<Milestone> Plan, string? Current, IReadOnlyDictionary<string, double> Started,
    double? Fraction, double Now)
{
    public int? Index { get { var i = Plan.ToList().FindIndex(m => m.Id == Current); return i < 0 ? null : i; } }
    public double StepElapsed => Current is not null && Started.TryGetValue(Current, out var s) ? Math.Max(0, Now - s) : 0;
    public double TotalElapsed => Started.Count == 0 ? 0 : Math.Max(0, Now - Started.Values.Min());

    public double Calibration
    {
        get
        {
            if (Index is not { } i || i == 0) return 1;
            double actual = 0, expected = 0;
            for (var k = 0; k < i; k++)
            {
                var m = Plan[k];
                if (!Started.TryGetValue(m.Id, out var s) || m.Measured is not { } e) continue;
                var end = Started.TryGetValue(Plan[k + 1].Id, out var next) ? next : Now;
                actual += Math.Max(0, end - s); expected += e;
            }
            return expected > 1 ? Math.Min(3, Math.Max(0.5, actual / expected)) : 1;
        }
    }

    public double? StepRemainingByRate =>
        Index is null || Fraction is not { } f || f < 0.05 || f >= 1 ? null : StepElapsed * (1 - f) / f;

    public double? Remaining
    {
        get
        {
            if (Index is not { } i) return null;
            var rest = Plan.Skip(i).Select(m => m.Measured).ToList();
            if (rest.Any(r => r is null) || Plan[i].Measured is not { } e) return null;
            var calibration = Calibration;
            var current = StepRemainingByRate ?? Math.Max(e * calibration - StepElapsed, e * calibration * 0.1);
            return current + rest.Skip(1).Sum(r => r!.Value) * calibration;
        }
    }

    public int HistorySamples => Index is { } i
        ? Plan.Skip(i).Where(m => m.Source == "history").Select(m => m.Samples).DefaultIfEmpty(0).Min() : 0;

    public double Fill(int k)
    {
        if (Index is not { } i) return 0;
        if (k < i) return 1;
        if (k > i) return 0;
        if (Fraction is { } f) return Math.Min(1, Math.Max(0, f));
        if (Plan[i].Measured is not { } e) return 0;
        return Math.Min(0.95, StepElapsed / Math.Max(1, e * Calibration));
    }
}

/// <summary>Milestone track of one job: the plan, the current milestone and when each step started on this machine (seconds).</summary>
public sealed class MilestoneTrack
{
    private readonly Dictionary<string, double> started = new(StringComparer.Ordinal);
    public IReadOnlyList<Milestone> Plan { get; private set; } = [];
    public string? Current { get; private set; }
    public double? Ended { get; private set; }
    public IReadOnlyDictionary<string, double> Started => started;
    /// <summary>Real done / total of the current step (progress events); null without a real count.</summary>
    public double? Fraction { get; private set; }
    /// <summary>整单进度（作业层每条事件的 overall，0–1，只增不减、成功才到 1；pack/jobs/overall.py）。大百分比与分段条只显示它，
    /// 不再按当前计数器自己拼（11-11 维护者：「百分比反复到 91% 又跳回 40%」）。没有的作业为 null，照旧</summary>
    public double? Overall { get; private set; }
    public string Message { get; private set; } = "";

    public void Ingest(JsonElement e, double now)
    {
        var type = e.TryGetProperty("type", out var t) ? t.GetString() : null;
        if (type == "plan" && e.TryGetProperty("milestones", out var milestones) && milestones.ValueKind == JsonValueKind.Array)
        {
            var plan = Milestone.ParsePlan(milestones);
            // The same steps re-sent (a step marked reused): keep elapsed time, swap estimates only.
            if (!plan.Select(m => m.Id).SequenceEqual(Plan.Select(m => m.Id))) { started.Clear(); Current = null; Ended = null; Fraction = null; }
            Plan = plan;
        }
        if (e.TryGetProperty("milestone", out var m) && m.ValueKind == JsonValueKind.String && m.GetString() is { Length: > 0 } id && id != Current)
        {
            Current = id; Fraction = null;
            started.TryAdd(id, now);
        }
        if (e.TryGetProperty("overall", out var o) && o.ValueKind == JsonValueKind.Number)
            Overall = Math.Max(Overall ?? 0, Math.Min(1, o.GetDouble()));
        if (type is "stage" or "message" or "cache") Fraction = null;   // 新的一句说明 = 上一个百分比不再代表当前在做的事（社区贡献者补丁 #8）
        if (type == "progress" && e.TryGetProperty("totalUnits", out var total) && total.ValueKind == JsonValueKind.Number && total.GetDouble() > 0 &&
            e.TryGetProperty("doneUnits", out var done) && done.ValueKind == JsonValueKind.Number)
            Fraction = Math.Min(1, Math.Max(0, done.GetDouble() / total.GetDouble()));
        if (type is "stage" or "progress" or "message" && e.TryGetProperty("message", out var text) && text.ValueKind == JsonValueKind.String &&
            text.GetString() is { Length: > 0 } message)
            Message = message;
    }

    public void Finish(double now) => Ended ??= now;

    public double? Duration(string id)
    {
        var k = Plan.ToList().FindIndex(m => m.Id == id);
        if (k < 0 || !started.TryGetValue(id, out var s)) return null;
        var later = Plan.Skip(k + 1).Where(m => started.ContainsKey(m.Id)).Select(m => started[m.Id]).ToList();
        double? end = later.Count > 0 ? later.Min() : Ended;
        return end is { } x ? Math.Max(0, x - s) : null;
    }

    public MilestoneEstimate Estimate(double now) => new(Plan, Current, new Dictionary<string, double>(started), Fraction, now);
}

/// <summary>Disk space budget from the pack job's space event (mirrors PackSpace in the Mac frontend).</summary>
public sealed record PackSpace(long? NeedBytes, long? FreeBytes, string Basis)
{
    public static PackSpace? TryParse(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        if (!e.TryGetProperty("volumes", out var vols) || vols.ValueKind != JsonValueKind.Array) return null;
        JsonElement? vol = null;
        foreach (var v in vols.EnumerateArray())
        {
            if (v.TryGetProperty("role", out var r) && r.GetString() == "library") { vol = v; break; }
            vol ??= v;
        }
        if (vol is not { } volume) return null;
        long? need = volume.TryGetProperty("needBytes", out var n) && n.ValueKind == JsonValueKind.Number ? n.GetInt64() : null;
        long? free = volume.TryGetProperty("freeBytes", out var f) && f.ValueKind == JsonValueKind.Number ? f.GetInt64() : null;
        var basis = volume.TryGetProperty("basis", out var b) && b.ValueKind == JsonValueKind.String ? b.GetString() ?? "" : "";
        return new(need, free, basis);
    }
}

/// <summary>One line of the pre-install checklist (pack/jobs/install.py readiness). Official URL only from the backend's own field.
/// Action is a closed set of launcher-local steps (openImpactor: open the Impactor bundled with the launcher); the backend never sends a path.</summary>
public sealed record InstallItem(string Id, bool Ok, bool Waiting, string Title, string Detail, string Who, Uri? OfficialUrl, string? Action = null)
{
    public static readonly IReadOnlySet<string> Actions = new HashSet<string>(StringComparer.Ordinal) { "openImpactor" };
}

/// <summary>DeviceKind：连着的设备是 "ipad" / "iphone"，读不出为 ""（#487：入口写「装到 iPad」；后端按 USB 产品号认）。</summary>
public sealed record InstallReadiness(IReadOnlyList<InstallItem> Items, bool Ready, string Device, string Account, string IpaPath = "", string DeviceKind = "")
{
    public static InstallReadiness Parse(JsonElement result)
    {
        try
        {
            LibraryJobResult.UniqueFields(result);
            var items = new List<InstallItem>();
            foreach (var i in result.GetProperty("items").EnumerateArray())
            {
                // 剃刀 W7：不认识的动作、不安全的链接只忽略这一项（这一项不给按钮 / 链接），不再整份清单作废——
                //   原先后端加一个新动作，前端就当「这次没查到手机状态」，玩家只能盲装
                Uri? url = null;
                if (i.TryGetProperty("url", out var u) && u.ValueKind == JsonValueKind.String &&
                    Uri.TryCreate(u.GetString(), UriKind.Absolute, out var parsed) &&
                    parsed.Scheme == Uri.UriSchemeHttps && parsed.Host.Length != 0 && parsed.UserInfo.Length == 0)
                    url = parsed;
                string? action = null;
                if (i.TryGetProperty("action", out var a) && a.ValueKind == JsonValueKind.String && InstallItem.Actions.Contains(a.GetString()!))
                    action = a.GetString();
                items.Add(new(LibraryJobResult.Text(i, "id"), i.GetProperty("ok").GetBoolean(),
                    i.TryGetProperty("waiting", out var w) && w.GetBoolean(), LibraryJobResult.Text(i, "title"),
                    LibraryJobResult.Text(i, "detail", true), i.TryGetProperty("who", out var who) ? who.GetString() ?? "" : "", url, action));
            }
            // ready is the backend's verdict: open items may be advisory (only a missing iPhone package blocks).
            return new(items.AsReadOnly(), result.GetProperty("ready").GetBoolean(), LibraryJobResult.Text(result, "device", true), LibraryJobResult.Text(result, "account", true),
                result.TryGetProperty("ipaPath", out var ipa) && ipa.ValueKind == JsonValueKind.String ? ipa.GetString() ?? "" : "",
                result.TryGetProperty("deviceKind", out var kind) && kind.ValueKind == JsonValueKind.String ? kind.GetString() ?? "" : "");
        }
        catch (Exception error) when (error is KeyNotFoundException or InvalidOperationException)
        { throw new LibraryProtocolException("Invalid install checklist.", error); }
    }
}
