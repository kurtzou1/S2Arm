// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// 出包编排作业 export 的事件与请求（剃刀 H13）：JSON 按 pack/jobs/export_plan.py 打出的形状手写（step / child / stepEnded、终态 paused），期望值手写，不跑被测实现推导。
public static class ExportStreamCases
{
    private static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();

    public static void Run(Action<bool, string> check)
    {
        const string step = """{"type":"step","state":"running","step":{"gameId":"G1","platform":"iphone","task":"exp-1-2","index":2,"count":3}}""";
        check(ExportStream.Read(Json(step)) is ExportStream.Started { Where: { GameId: "G1", Platform: "iphone", Task: "exp-1-2", Index: 2, Count: 3 } }, "export: step");
        var progress = ExportStream.Read(Json("""{"type":"child","state":"running","step":{"gameId":"G1","platform":"iphone","task":"exp-1-2"},"event":{"type":"progress","done":1,"total":2}}"""));
        check(progress is ExportStream.Child { Where.GameId: "G1" } c && c.Inner.GetProperty("done").GetInt32() == 1 && ExportStream.ChildResult(c.Inner) is null, "export: child progress passed through");
        var failed = (ExportStream.Child)ExportStream.Read(Json("""
{"type":"child","state":"running","step":{"gameId":"G1","platform":"iphone","task":"exp-1-2"},
 "event":{"type":"result","state":"failed","message":"磁盘空间不足","result":{},"diagnostics":[{"code":"disk_full","summary":"磁盘空间不足"}]}}
"""))!;
        check(ExportStream.ChildResult(failed.Inner) is { State: "failed", Message: "磁盘空间不足" } r && r.Diagnostics[0].GetProperty("code").GetString() == "disk_full", "export: child result for the failure page");
        var ended = ExportStream.Read(Json("""
{"type":"stepEnded","state":"running","step":{"gameId":"G1","platform":"iphone","task":"exp-1-2","index":2,"count":3},
 "outcome":{"state":"completed","message":"操作完成","output":"D:\\x.ipa","ipa":"D:\\x.ipa","ipaBytes":1234,"packBytes":5678}}
"""));
        check(ended is ExportStream.Ended { Outcome: { State: "completed", Ipa: "D:\\x.ipa", IpaBytes: 1234, PackBytes: 5678, Code: null } }, "export: stepEnded outcome");
        check(ended is ExportStream.Ended { Outcome.Notes.Count: 0 }, "export: no notes → empty");
        var noted = ExportStream.Read(Json("""
{"type":"stepEnded","state":"running","step":{"gameId":"G1","platform":"iphone","task":"exp-1-2","index":2,"count":3},
 "outcome":{"state":"completed","message":"","notes":["这款有 27 处用了兼容写法",3,""]}}
"""));
        check(noted is ExportStream.Ended { Outcome.Notes: ["这款有 27 处用了兼容写法"] }, "export: degrade notes kept, non-strings and blanks dropped");
        check(ExportStream.Read(Json("""{"type":"heartbeat","state":"running"}""")) is null && ExportStream.Read(Json("""{"type":"stage","state":"running"}""")) is null, "export: own events ignored");
        Rejects(() => ExportStream.Read(Json("""{"type":"stepEnded","step":{"gameId":"G1","platform":"iphone"},"outcome":{"state":"queued"}}""")), "export: unknown outcome state rejected", check);
        Rejects(() => ExportStream.Read(Json("""{"type":"step","step":{"platform":"iphone"}}""")), "export: step without game rejected", check);

        // 终态 paused：机读原因与停在第几款；读事件流时 paused 配退出码 0
        var reader = new JobEventReader("exp-1", "export");
        reader.Accept("""{"schema":1,"jobId":"exp-1","taskId":"exp-1","operation":"export","seq":1,"type":"result","state":"paused","message":"启动器退出了","result":{"pausedReason":"launcher_exit","stoppedAt":2},"diagnostics":[]}""");
        var report = reader.Finish(0);
        check(ExportStream.Paused(report) is { Reason: "launcher_exit", StoppedAt: 2 }, "export: paused reason and stop point");
        check(ExportStream.Paused(new LibraryJobResult("succeeded", "", Json("{}"), default)) is null, "export: completed is not paused");
        var wrongExit = new JobEventReader("exp-2", "export");
        wrongExit.Accept("""{"schema":1,"jobId":"exp-2","taskId":"exp-2","operation":"export","seq":1,"type":"result","state":"paused","message":"","result":{},"diagnostics":[]}""");
        Rejects(() => wrongExit.Finish(1), "export: paused with a failure exit rejected", check);

        // 请求：计划进 plan，信封不带 gameId；iPhone 那步要的壳与随包资源带上
        var plan = ExportStream.InlinePlan("G1", "第一款", ["iphone"], "D:\\Games", spaceOverride: true);
        var paths = new LauncherPaths("C:\\S2Arm\\Engine", "C:\\S2Arm\\Runtime", "C:\\S2Arm\\Shell");
        var payload = PackJobClient.Payload(new(paths, "C:\\priv", "C:\\lib", "LIB", "export", "", new Dictionary<string, object?> { ["plan"] = plan }), "exp-3");
        var body = Json(JsonSerializer.Serialize(payload));
        check(!body.TryGetProperty("gameId", out _) && body.GetProperty("operation").GetString() == "export", "export: no gameId on the envelope");
        check(body.TryGetProperty("shellDir", out _) && body.TryGetProperty("resources", out _) && body.GetProperty("parentPid").GetInt32() == Environment.ProcessId, "export: shell, resources, parentPid");
        var p = body.GetProperty("plan");
        check(p.GetProperty("source").GetString() == "inline" && p.GetProperty("location").GetString() == "D:\\Games" && p.GetProperty("spaceOverride").GetBoolean(), "export: inline plan fields");
        check(p.GetProperty("items")[0].GetProperty("platforms").EnumerateArray().Select(x => x.GetString()).SequenceEqual(["iphone"]), "export: plan platforms");
        var noLocation = ExportStream.InlinePlan("G1", "G1", ["iphone"], null, false);
        check(!noLocation.ContainsKey("location") && !noLocation.ContainsKey("spaceOverride") && (string?)ExportStream.BatchPlan()["source"] == "batch", "export: optional fields omitted; batch plan");
    }

    private static void Rejects(Action action, string label, Action<bool, string> check)
    {
        try { action(); check(false, label); }
        catch (LibraryProtocolException) { check(true, label); }
    }
}
