// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// 批量出包：JSON 按 pack/jobs/batch.py 打印的形状手写（show / mark 后的 {batch, next, summary}、{} 、{error}），
// 期望值按 batch.py 文件头的规则手算（next 指向的那款、summary 按款数），不跑被测实现推导。
public static class BatchCases
{
    private static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();

    public static void Run(Action<bool, string> check)
    {
        // ---- 控制口 POST /batch 的 games（同 Mac S2ArmControl）----
        var (ctl, ctlError) = BatchClient.ControlGames(Json("""{"games":[{"gameId":"0100AAAA00000000","platforms":["mac","ios"]},{"gameId":"0100BBBB00000000"},{"gameId":"0100aaaa00000000","platforms":["iphone"]}]}"""));
        check(ctlError is null && ctl.Count == 2 && ctl[0].Platforms.SequenceEqual(["mac", "iphone"]) && ctl[1].Platforms.SequenceEqual(["iphone"]),
            "batch control: ios = iphone, platforms default iphone, same game twice keeps the first");
        foreach (var (body, why) in new[] { ("{}", "games"), ("""{"games":[]}""", "games"), ("""{"games":[{"platforms":["iphone"]}]}""", "gameId"),
                                            ("""{"games":[{"gameId":"X","platforms":["android"]}]}""", "platforms"), ("""{"games":[{"gameId":"X","platforms":[]}]}""", "platforms") })
            check(BatchClient.ControlGames(Json(body)).Error?.Contains(why) == true, "batch control: rejects " + body);

        // ---- 读批次 ----
        check(BatchClient.Read(Json("{}")) is { State: null, Error: null }, "batch: {} = no batch, no error");
        var gone = BatchClient.Read(Json("""{"error":"没有进行中的批次"}"""));
        check(gone.State is null && gone.Error == "没有进行中的批次", "batch: backend error text kept");
        check(BatchClient.Read(null) is { State: null, Error.Length: > 0 }, "batch: no output is an error");

        // 三款：A 两个平台都出好；B iPhone 失败（磁盘满，已暂停）、Mac 排队；C 上次被打断、重新排队
        const string show = """
{"batch":{"schema":1,"created":1762740000,"location":"D:\\S2Arm Games","paused":"disk_full","items":[
 {"gameId":"0100AAAA00000000","name":"Alpha","platforms":["iphone","mac"],"results":{"iphone":{"state":"completed","output":"D:\\a.ipa"},"mac":{"state":"completed"}}},
 {"gameId":"0100BBBB00000000","name":"Beta","platforms":["iphone","mac"],"results":{"iphone":{"state":"failed","message":"磁盘空间不足","code":"disk_full"},"mac":{"state":"pending"}}},
 {"gameId":"0100CCCC00000000","name":"Gamma","platforms":["iphone"],"results":{"iphone":{"state":"pending","interrupted":true}}}]},
 "next":null,
 "summary":{"total":3,"completed":1,"failed":0,"cancelled":0,"pending":2,"done":false}}
""";
        var state = BatchClient.Read(Json(show)).State!;
        check(state.Items.Count == 3 && state.Location == "D:\\S2Arm Games" && state.Paused == "disk_full", "batch: items, location, paused");
        check(state.Items[0].Result("iphone").Output == "D:\\a.ipa" && state.Items[0].Result("mac").State == "completed", "batch: completed results");
        var beta = state.Items[1].Result("iphone");
        check(beta.State == "failed" && beta.Code == "disk_full" && beta.Message == "磁盘空间不足" && state.Items[1].Any("failed"), "batch: failure with code and message");
        check(state.Items[2].Result("iphone").Interrupted && !state.Items[1].Result("mac").Interrupted, "batch: interrupted only where recover marked it");
        check(state.Summary is { Total: 3, Completed: 1, Failed: 0, Cancelled: 0, Pending: 2, Done: false }, "batch: summary counts (B still has mac pending)");
        check(state.Unfinished == 2, "batch: unfinished = pending 2 + cancelled 0");
        // 暂停着时失败的也算没出完（等「重试」，审计 P1-168）；没暂停时失败的不算
        var pausedFailed = BatchClient.Read(Json(show.Replace("\"failed\":0,\"cancelled\":0,\"pending\":2", "\"failed\":1,\"cancelled\":0,\"pending\":1"))).State!;
        check(pausedFailed.Unfinished == 2, "batch: paused counts failed as unfinished");
        var notPaused = BatchClient.Read(Json(show.Replace("\"paused\":\"disk_full\"", "\"paused\":null").Replace("\"failed\":0,\"cancelled\":0,\"pending\":2", "\"failed\":1,\"cancelled\":0,\"pending\":1"))).State!;
        check(notPaused.Unfinished == 1, "batch: not paused, failed goes to retry");
        // 停在第几款：C 被打断（启动器退出时正在出）→ 第 3 款，哪怕 B 也有排队的；没有被打断的才取第一款排着队的
        check(state.StoppedAt == 3, "batch: stopped at the interrupted game");
        check(BatchClient.Read(Json(show.Replace(",\"interrupted\":true", ""))).State!.StoppedAt == 2, "batch: no interrupted → first game with a pending platform");
        const string both = """
{"batch":{"schema":1,"location":null,"paused":null,"items":[
 {"gameId":"G1","name":"G1","platforms":["iphone","mac"],"results":{"iphone":{"state":"pending"},"mac":{"state":"pending"}}}]},
 "next":{"gameId":"G1","platform":"iphone"},"summary":{"total":1,"completed":0,"failed":0,"cancelled":0,"pending":1,"done":false}}
""";
        var fresh = BatchClient.Read(Json(both)).State!;
        check(fresh.Location is null, "batch: null location");
        check(fresh.StoppedAt == 1, "batch: nothing exported yet = stopped at game 1");
        // 全取消：两款都算没出完，没有下一步
        var cancelled = BatchClient.Read(Json(both.Replace("\"state\":\"pending\"", "\"state\":\"cancelled\"").Replace("\"next\":{\"gameId\":\"G1\",\"platform\":\"iphone\"}", "\"next\":null")
            .Replace("\"cancelled\":0,\"pending\":1", "\"cancelled\":1,\"pending\":0"))).State!;
        check(cancelled.Unfinished == 1 && cancelled.StoppedAt == 0, "batch: cancelled counts as unfinished, not a stop point");

        // 形状不对：报错，不当成没有批次
        check(BatchClient.Read(Json(both.Replace("\"state\":\"pending\"", "\"state\":\"queued\""))).Error is { Length: > 0 }, "batch: unknown state rejected");
        check(BatchClient.Read(Json(both.Replace("\"iphone\",\"mac\"", "\"iphone\",\"android\""))).Error is { Length: > 0 }, "batch: unknown platform rejected");
        check(BatchClient.Read(Json("""{"batch":{"items":[]}}""")).Error is { Length: > 0 }, "batch: missing summary rejected");
        check(BatchClient.Read(Json("[]")).Error is { Length: > 0 }, "batch: non-object rejected");

        // ---- 命令参数 ----
        var created = Json(BatchClient.CreateJson([new("G1", "第一款", ["iphone"]), new("G2", "Two", ["iphone", "mac"])], "D:\\Games"));
        var items = created.GetProperty("items").EnumerateArray().ToArray();
        check(items.Length == 2 && items[0].GetProperty("gameId").GetString() == "G1" && items[0].GetProperty("name").GetString() == "第一款", "create: game id and name");
        check(items[1].GetProperty("platforms").EnumerateArray().Select(p => p.GetString()).SequenceEqual(["iphone", "mac"]), "create: platforms in order");
        check(created.GetProperty("location").GetString() == "D:\\Games", "create: shared location");
        check(Json(BatchClient.CreateJson([new("G1", "G1", ["iphone"])], "")).GetProperty("location").ValueKind == JsonValueKind.Null, "create: empty location is null");

        // ---- 导入结果（partialResults）----
        var import = Json("""
{"imports":[{"id":"0100AAAA00000000","name":"a.nsp","duplicate":false},{"id":"0100AAAA00000000","name":"a-update.nsp","duplicate":false},
            {"id":"0100BBBB00000000","name":"b.xci","duplicate":true}],
 "sources":[{"id":"1","path":"D:\\in\\a.nsp","name":"Alpha","fileName":"a.nsp","needsKeys":true,"status":"imported","code":null,"reason":"","diagnostic":""},
            {"id":"2","path":"D:\\in\\bad.nsp","name":"bad.nsp","fileName":"bad.nsp","needsKeys":true,"status":"failed","code":"content_invalid","reason":"文件内容不对。","diagnostic":"x"},
            {"id":"3","path":"D:\\in\\old.nsp","name":"old.nsp","fileName":"old.nsp","needsKeys":true,"status":"failed","code":"keys_outdated","reason":"密钥版本不够。","diagnostic":""}]}
""");
        check(ImportOutcome.GameIds(import).SequenceEqual(["0100AAAA00000000", "0100BBBB00000000"]), "import: ids in order, base + update counted once, duplicates kept");
        var failed = ImportOutcome.Failed(import);
        check(failed.Count == 2 && failed[0] == new ImportOutcome.Unrecognized("bad.nsp", "文件内容不对。", "content_invalid"), "import: failed source with reason and code");
        check(failed[1].Code == "keys_outdated", "import: second failed source");
        check(ImportOutcome.GameIds(Json("""{"imports":[]}""")).Count == 0 && ImportOutcome.Failed(Json("""{"imports":[]}""")).Count == 0, "import: legacy shape without sources");
        // #797：缺本体的款（imports[].missingBase）去重、按出现顺序；没有这个键的旧结果 = 不缺
        check(ImportOutcome.MissingBase(import).Count == 0, "import: no missingBase key = nothing missing");
        check(ImportOutcome.MissingBase(Json("""{"imports":[{"id":"0100CCCC00000000","missingBase":true},{"id":"0100CCCC00000000","missingBase":true},{"id":"0100DDDD00000000","missingBase":false}]}"""))
            .SequenceEqual(["0100CCCC00000000"]), "import: missingBase ids deduped, false skipped");
    }
}
