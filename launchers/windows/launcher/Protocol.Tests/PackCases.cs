// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// Export / install pages: expected values are worked out by hand from the rules in pack/jobs/milestones.py and the Mac adapter's
// Milestones.swift (not by running the C# port), and from the request / result shapes in pack/jobs (ipa, install, community).
public static class PackCases
{
    public static void Run(Action<bool, string> check)
    {
        // ---- incremental event stream ----
        const string stream = """
{"schema":1,"jobId":"j","taskId":"j","seq":1,"type":"plan","operation":"ipa","state":"running","milestone":null,"milestones":[{"id":"unpack","label":"解包","purpose":"p","expected":null,"source":"none","samples":0,"reuse":false}]}
{"schema":1,"jobId":"j","taskId":"j","seq":2,"type":"stage","operation":"ipa","state":"running","milestone":"unpack","message":"解包"}
{"schema":1,"jobId":"j","taskId":"j","seq":3,"type":"result","operation":"ipa","state":"succeeded","message":"操作完成","result":{"ipa":"C:\\lib\\iPhone\\G\\dbz.ipa"}}
""";
        var lines = stream.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var reader = new JobEventReader("j", "ipa");
        var seen = lines.Select(reader.Accept).Count(e => e is not null);
        check(seen == 3 && reader.Finish(0).Succeeded, "stream: three events, success with exit 0");
        void RejectStream(IEnumerable<string> input, int exit, string label)
        {
            var r = new JobEventReader("j", "ipa");
            try { foreach (var line in input) r.Accept(line); r.Finish(exit); }
            catch (LibraryProtocolException) { check(true, label); return; }
            throw new Exception("accepted " + label);
        }
        RejectStream(lines, 1, "stream: success result with exit 1");
        RejectStream(lines.Take(2), 0, "stream: EOF without result");
        RejectStream([lines[1], lines[0]], 0, "stream: seq must increase");
        RejectStream(lines.Append(lines[2].Replace("\"seq\":3", "\"seq\":4")), 0, "stream: nothing after the result");
        RejectStream([lines[0].Replace("\"jobId\":\"j\"", "\"jobId\":\"other\"")], 0, "stream: another job's event");
        RejectStream([lines[0].Replace("\"operation\":\"ipa\"", "\"operation\":\"install\"")], 0, "stream: another operation");
        RejectStream([lines[1].Replace("\"state\":\"running\"", "\"state\":\"failed\"")], 1, "stream: terminal state without result event");

        // ---- milestone estimate (hand-worked) ----
        // a: history 100 s (3 samples); b: history 200 s (2 samples); c: reused, no reuse record (0 s).
        var plan = new List<Milestone>
        {
            new("a", "A", "", 100, "history", 3, false), new("b", "B", "", 200, "history", 2, false), new("c", "C", "", null, "reuse", 0, true)
        };
        var started = new Dictionary<string, double> { ["a"] = 0, ["b"] = 120 };
        var at = new MilestoneEstimate(plan, "b", started, null, 180);
        // calibration = a actual 120 ÷ record 100 = 1.2; b remaining = max(200×1.2 − 60, 24) = 180; c adds 0.
        check(Math.Abs(at.Calibration - 1.2) < 1e-9, "estimate: calibration 1.2");
        check(at.Remaining is { } r1 && Math.Abs(r1 - 180) < 1e-9, "estimate: remaining 180 s");
        check(at.HistorySamples == 2, "estimate: fewest history samples from the current step on");
        check(Math.Abs(at.Fill(1) - 0.25) < 1e-9 && at.Fill(0) == 1 && at.Fill(2) == 0, "estimate: fill 1 / 0.25 / 0");
        check(Math.Abs(at.TotalElapsed - 180) < 1e-9 && Math.Abs(at.StepElapsed - 60) < 1e-9, "estimate: elapsed 180 / step 60");
        var rate = at with { MeasuredStep = 60 };
        // 本步按实测速率还需 60（MilestoneTrack 给），后面一步复用 0 → 整单 60
        check(rate.Remaining is { } r2 && Math.Abs(r2 - 60) < 1e-9, "estimate: current step by its real rate");
        check(at.StepRemainingByRate is null && (at with { Fraction = 0.5 }).StepRemainingByRate is null, "estimate: no live counter rate, no step rate (fraction alone is not a rate)");

        // ---- 本步还需按计数器自身斜率（#944：直连库翻译 35 分钟后换编批库 MB 计数器，原先已用时间里含翻译、头 5 % 不给）----
        var slope = new MilestoneTrack();
        void Feed(MilestoneTrack tr, string json, double t) { using var d = JsonDocument.Parse(json); tr.Ingest(d.RootElement, t); }
        Feed(slope, """{"type":"plan","milestones":[{"id":"direct","label":"D","purpose":""}]}""", 0);
        Feed(slope, """{"type":"progress","milestone":"direct","doneUnits":99084,"totalUnits":99084}""", 90);
        Feed(slope, """{"type":"progress","milestone":"direct","doneUnits":0,"totalUnits":64490}""", 100);   // 换计数器：从这一条起算
        Feed(slope, """{"type":"progress","milestone":"direct","doneUnits":10,"totalUnits":64490}""", 101);
        check(slope.Estimate(101).StepRemainingByRate is null, "slope: under 2 s of counting, no rate");
        Feed(slope, """{"type":"progress","milestone":"direct","doneUnits":1000,"totalUnits":64490}""", 110);
        // 1000 ÷ 10 s = 100 /s → (64490 − 1000) ÷ 100 = 634.9 s（1.55 % 也给）；10 s 后倒数到 624.9
        check(slope.Estimate(120).StepRemainingByRate is { } s1 && Math.Abs(s1 - 624.9) < 1e-9, "slope: counter's own rate, counted down between events");
        Feed(slope, """{"type":"progress","milestone":"direct","doneUnits":5,"totalUnits":99084}""", 130);
        check(slope.Estimate(131).StepRemainingByRate is null, "slope: a new counter starts its rate over");
        Feed(slope, """{"type":"progress","milestone":"direct","doneUnits":500,"totalUnits":99084}""", 140);
        Feed(slope, """{"type":"progress","milestone":"ipa","doneUnits":600,"totalUnits":99084}""", 150);
        check(slope.Estimate(150).StepRemainingByRate is null, "slope: a new step starts its rate over");
        var unknown = new MilestoneEstimate([plan[0], plan[1], new("d", "D", "", 99, "none", 0, false)], "b", started, null, 180);
        check(unknown.Remaining is null, "estimate: a later step without a local record gives no total");
        check(new MilestoneEstimate(plan, null, started, null, 180).Remaining is null, "estimate: no current step, no total");
        var clamp = new MilestoneEstimate(plan, "b", new Dictionary<string, double> { ["a"] = 0, ["b"] = 1000 }, null, 1000);
        check(Math.Abs(clamp.Calibration - 3) < 1e-9, "estimate: calibration clamped to 3");

        // ---- milestone track ----
        var track = new MilestoneTrack();
        foreach (var line in lines.Take(2)) { using var d = JsonDocument.Parse(line); track.Ingest(d.RootElement, 10); }
        using (var progress = JsonDocument.Parse("""{"type":"progress","milestone":"unpack","doneUnits":25,"totalUnits":100,"message":"解包 25/100"}"""))
            track.Ingest(progress.RootElement, 15);
        check(track.Plan.Count == 1 && track.Current == "unpack" && track.Started["unpack"] == 10, "track: plan and step start");
        check(track.Fraction == 0.25 && track.Message == "解包 25/100", "track: real fraction and message");
        using (var message = JsonDocument.Parse("""{"type":"message","milestone":"unpack","message":"解包已完成，正在校验"}"""))
            track.Ingest(message.RootElement, 16);
        check(track.Fraction is null && track.Message.Contains("校验"), "track: finalization message clears stale 100% fraction");   // 社区贡献者补丁 #8 附带的用例
        check(track.Plan[0].Measured is null, "track: no local record means no expected time");
        track.Finish(40);
        check(track.Duration("unpack") == 30, "track: last step ends at the job end");

        // 整单进度只认作业层的 overall、只增不减（11-11「91% 又跳回 40%」）：中间夹一个更小的值（乱序 / 重发），读数不回退；成功结果到 1
        var whole = new MilestoneTrack();
        check(whole.Overall is null, "overall: absent until the backend sends it");
        var sent = new[] { "0.12", "0.40", "0.35", "0.91", "1.0" };
        var expected = new[] { 0.12, 0.40, 0.40, 0.91, 1.0 };   // 手算：取到目前为止的最大值
        for (var i = 0; i < sent.Length; i++)
        {
            using var d = JsonDocument.Parse("{\"type\":\"progress\",\"milestone\":\"direct\",\"overall\":" + sent[i] + ",\"doneUnits\":1,\"totalUnits\":5}");
            whole.Ingest(d.RootElement, i);
            check(whole.Overall == expected[i], $"overall: reading after sending {sent[i]} is {expected[i]}");
        }
        check(whole.Overall == 1.0, "overall: success reaches 100%");

        // ---- checklist results ----
        const string checklist = """
{"gameId":"G","items":[{"id":"package","ok":true,"waiting":false,"title":"t","detail":"","who":"human"},
 {"id":"impactor","ok":false,"waiting":false,"title":"t","detail":"d","who":"human","url":"https://github.com/claration/impactor/releases/tag/v2.7.2"},
 {"id":"connected","ok":false,"waiting":false,"title":"t","detail":"d","who":"human"}],"ready":false,"device":"","account":""}
""";
        using (var doc = JsonDocument.Parse(checklist))
        {
            var ready = InstallReadiness.Parse(doc.RootElement);
            check(!ready.Ready && ready.Items.Count == 3 && ready.Items[1].OfficialUrl?.Host == "github.com" && ready.Items[2].OfficialUrl is null,
                "checklist: backend official URL kept only where given");
        }
        void RejectChecklist(string json, string label)
        {
            using var doc = JsonDocument.Parse(json);
            try { InstallReadiness.Parse(doc.RootElement); }
            catch (LibraryProtocolException) { check(true, label); return; }
            throw new Exception("accepted " + label);
        }
        // 剃刀 W7：不安全链接 / 不认识的动作只丢这一项的链接 / 动作，整份清单照常（期望按规则手写）
        using (var doc = JsonDocument.Parse(checklist.Replace("https://github.com", "http://github.com")))
        {
            var r = InstallReadiness.Parse(doc.RootElement);
            check(r.Items.Count == 3 && r.Items[1].OfficialUrl is null && r.Items[1].Id == "impactor", "checklist: non-HTTPS link dropped for that item only");
        }
        using (var doc = JsonDocument.Parse(checklist.Replace("\"who\":\"human\"}],", "\"who\":\"human\",\"action\":\"futureAction\"}],")))
        {
            var r = InstallReadiness.Parse(doc.RootElement);
            check(r.Items.Count == 3 && r.Items[2].Action is null && !r.Items[2].Ok, "checklist: unknown action dropped for that item only");
        }
        using (var doc = JsonDocument.Parse(checklist.Replace("\"ready\":false", "\"ready\":true")))
            check(InstallReadiness.Parse(doc.RootElement) is { Ready: true } r && r.Items.Any(i => !i.Ok), "checklist: backend ready with advisory open items is accepted");
        RejectChecklist("{}", "checklist: malformed");
        // #487：deviceKind（后端按 USB 产品号认 iPad）；旧后端没有这个字段读成 ""
        using (var doc = JsonDocument.Parse(checklist.Replace("\"account\":\"\"", "\"account\":\"\",\"deviceKind\":\"ipad\"")))
            check(InstallReadiness.Parse(doc.RootElement).DeviceKind == "ipad", "checklist: deviceKind ipad kept");
        using (var doc = JsonDocument.Parse(checklist))
            check(InstallReadiness.Parse(doc.RootElement).DeviceKind == "", "checklist: no deviceKind reads as empty");
        // 11-07 bundled Impactor: the backend asks for a launcher-local step by name only (openImpactor), never a path or an unknown verb
        const string bundledChecklist = """
{"gameId":"G","items":[{"id":"impactor","ok":true,"waiting":false,"title":"t","detail":"","who":"human","url":null,"action":null},
 {"id":"impactor_login","ok":false,"waiting":false,"title":"t","detail":"d","who":"human","url":null,"action":"openImpactor"}],"ready":false,"device":"","account":""}
""";
        using (var doc = JsonDocument.Parse(bundledChecklist))
        {
            var ready = InstallReadiness.Parse(doc.RootElement);
            check(ready.Items[1].Action == "openImpactor" && ready.Items[1].OfficialUrl is null && ready.Items[0].Action is null,
                "checklist: bundled Impactor sign-in step carries the openImpactor action and no download link");
        }
        using (var doc = JsonDocument.Parse(bundledChecklist.Replace("\"openImpactor\"", "\"C:/x.exe\"")))
            check(InstallReadiness.Parse(doc.RootElement).Items[1].Action is null, "checklist: unknown / path action never becomes an action (dropped, razor W7)");

        // ---- request body ----
        var paths = new LauncherPaths(Path.Combine(Path.GetTempPath(), "E"), Path.Combine(Path.GetTempPath(), "R"), Path.Combine(Path.GetTempPath(), "S"));
        var ipa = PackJobClient.Payload(new(paths, Path.GetTempPath(), Path.GetTempPath(), "lib-id", "ipa", "0100FD70134FA000"), "win-1");
        check((string?)ipa["operation"] == "ipa" && (string?)ipa["gameId"] == "0100FD70134FA000" && (string?)ipa["libraryId"] == "lib-id" &&
              (string?)ipa["shellDir"] == Path.GetFullPath(paths.Shell) && (int?)ipa["parentPid"] == Environment.ProcessId &&
              (string?)ipa["resources"] == Path.GetFullPath(AppContext.BaseDirectory),
            "request: ipa carries game, library id, bundled shell, bundled resources (fonts) and launcher pid");
        foreach (var op in new[] { "installCheck", "install", "installRemove", "installRestore" })
        {
            var r = PackJobClient.Payload(new(paths, Path.GetTempPath(), Path.GetTempPath(), "lib-id", op, "0100FD70134FA000"), "win-2");
            check((string?)r["resources"] == Path.GetFullPath(AppContext.BaseDirectory) && (op == "install") == r.ContainsKey("shellDir"),
                $"request: {op} carries the launcher folder (bundled Impactor); only install carries the shell");
        }
        // 开发者证书（v0.2.4）：属于这台电脑、不属于某款游戏 → 不带 gameId；密码只走 Secrets（作业进程环境），请求体里没有
        var cert = PackJobClient.Payload(new(paths, Path.GetTempPath(), Path.GetTempPath(), "lib-id", "devCert", "",
            new Dictionary<string, object?> { ["action"] = "import", ["p12Path"] = "C:/c.p12", ["profilePath"] = "C:/p.mobileprovision" },
            new Dictionary<string, string> { ["S2A_DEVCERT_PASSWORD"] = "pw-secret" }), "win-3");
        check((string?)cert["operation"] == "devCert" && !cert.ContainsKey("gameId") && (string?)cert["action"] == "import" &&
              !JsonSerializer.Serialize(cert).Contains("pw-secret"),
            "request: devCert needs no game and never carries the password");
        // 装到 iPhone 的方式 / 更新 iPhone 上的 S2Arm（v0.3.0，install.install_mode_job / update_phone）：属于这台电脑 / 这台手机，不带 gameId；
        //   都带随包资源（Impactor），installUpdate 还要组装容器，同 install 带预编壳
        check(PackJobClient.Operations.Contains("installMode") && PackJobClient.Operations.Contains("installUpdate"),
            "request: installMode / installUpdate are launcher operations");
        var mode = PackJobClient.Payload(new(paths, Path.GetTempPath(), Path.GetTempPath(), "lib-id", "installMode", "",
            new Dictionary<string, object?> { ["mode"] = "device" }), "win-5");
        check((string?)mode["mode"] == "device" && !mode.ContainsKey("gameId") && !mode.ContainsKey("shellDir") &&
              (string?)mode["resources"] == Path.GetFullPath(AppContext.BaseDirectory), "request: installMode needs no game, carries mode and resources");
        var update = PackJobClient.Payload(new(paths, Path.GetTempPath(), Path.GetTempPath(), "lib-id", "installUpdate", "",
            new Dictionary<string, object?> { ["acceptStale"] = true }), "win-6");
        check(update["acceptStale"] is true && !update.ContainsKey("gameId") && (string?)update["shellDir"] == Path.GetFullPath(paths.Shell) &&
              (string?)update["resources"] == Path.GetFullPath(AppContext.BaseDirectory), "request: installUpdate needs no game, carries acceptStale, shell and resources");
        check(PackJobClient.Operations.Contains("delete"), "request: delete (remove the whole game, saves kept) is a launcher operation since library layout v3");
        foreach (var (operation, extra, label) in new (string, Dictionary<string, object?>?, string)[]
        {
            ("launch", null, "request: operations outside export / install / remove / library layout refused (Windows does not run games)"),
            ("communitySave", null, "request: game options are not a launcher operation (维护者 11-07)"),
            ("install", new() { ["gameId"] = "other" }, "request: extra fields cannot replace the envelope")
        })
        {
            try { PackJobClient.Payload(new(paths, Path.GetTempPath(), Path.GetTempPath(), "lib-id", operation, "G", extra), "win-3"); }
            catch (ArgumentException) { check(true, label); continue; }
            throw new Exception("accepted " + label);
        }

        // ---- library layout v3 (pack/jobs/library.py move_game / relink_game / forget_game / clean kind=cache, ipa location) ----
        var where = Path.Combine(Path.GetTempPath(), "Games");
        Dictionary<string, object?> V3(string op, Dictionary<string, object?>? extra) =>
            PackJobClient.Payload(new(paths, Path.GetTempPath(), Path.GetTempPath(), "lib-id", op, "0100FD70134FA000", extra), "win-4");
        var move = V3("moveGame", new() { ["location"] = where });
        check((string?)move["operation"] == "moveGame" && (string?)move["gameId"] == "0100FD70134FA000" && (string?)move["location"] == where &&
              !move.ContainsKey("shellDir") && !move.ContainsKey("resources"), "request: moveGame carries game and target location, no shell / resources");
        check((string?)V3("relinkGame", new() { ["folder"] = where })["folder"] == where, "request: relinkGame carries the chosen folder");
        check(V3("forgetGame", null).Count == move.Count - 1, "request: forgetGame is the bare envelope");
        check((string?)V3("clean", new() { ["kind"] = "cache" })["kind"] == "cache", "request: clean kind=cache accepted");
        // 释放空间（同 Mac FreeSpaceView）：spaceFree 带这款和勾选的部件列表，原样交给 pack/jobs/library.py space_free
        var free = V3("spaceFree", new() { ["parts"] = new[] { "shaders", "ipa" } });
        check((string?)free["operation"] == "spaceFree" && (string?)free["gameId"] == "0100FD70134FA000" && free["parts"] is string[] { Length: 2 } ps && ps[0] == "shaders" && ps[1] == "ipa",
              "request: spaceFree carries the game and the chosen parts");
        check((string?)V3("ipa", new() { ["location"] = where })["location"] == where && !V3("ipa", null).ContainsKey("location"),
            "request: ipa location optional, passed through when chosen");
        foreach (var (operation, extra, label) in new (string, Dictionary<string, object?>?, string)[]
        {
            ("moveGame", null, "request: moveGame without a location refused"),
            ("moveGame", new() { ["location"] = "Games" }, "request: relative move target refused"),
            ("relinkGame", null, "request: relinkGame without a folder refused"),
            ("ipa", new() { ["location"] = "" }, "request: empty export location refused"),
            ("clean", null, "request: clean without kind refused"),
            ("clean", new() { ["kind"] = "all" }, "request: clean other than the cache refused")
        })
        {
            try { V3(operation, extra); }
            catch (ArgumentException) { check(true, label); continue; }
            throw new Exception("accepted " + label);
        }
    }
}
