// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// 0.6.0 iPhone 总控台（同 Mac PhoneConsoleTests）。期望按《0.6.0 极简流程》界面一节手写：
//   首位卡状态行自上而下取第一条成立的；没选过时管连着的那台，再不然管最近同步过的那台；开关关着不出
internal static class PhoneOverviewCases
{
    public static void Run(Action<bool, string> check)
    {
        static JsonElement J(string s) => JsonDocument.Parse(s).RootElement.Clone();
        check(PhoneOverview.Parse(J("""{}""")) is null, "console: no phones key (old job layer) → no first card");
        var o = PhoneOverview.Parse(J("""{"phones":[ {"device":"D1","name":"我的手机","installed":true,"shellCurrent":false,"online":null,"lastSeen":1999990000,"signMode":"devCert", "games":[{"gameId":"0100a","state":"suggested","reasons":["hostAbi"]},{"gameId":"0100B","state":"needsData","dataOnComputer":false},{"gameId":"0100C","state":"weird"}]}, {"device":"D2","name":"旧手机","lastSeen":1999000000}]}"""))!;
        var p = o.Phones[0];
        check(o.Phones.Count == 2 && p.SignMode == "devCert" && !p.ShellCurrent, "console: phone fields parsed");
        check(p.Probed && p.KnownOffline && !o.Phones[1].Probed, "console: online key present and null = probed and offline; absent = not probed");
        check(string.Join(",", p.Games.Select(g => g.GameId)) == "0100A,0100B" && p.Games[1].DataOnComputer == false, "console: ids upper-cased, unknown states dropped");

        // 独立 App（0.6.4，作业 apps）：游戏号转大写、秒转时刻；缺游戏号的丢掉；旧作业层不带 = 空。期望手写
        var sa = PhoneOverview.Parse(J("""{"phones":[{"device":"D1","apps":[{"gameId":"010026300ba4a000","bundleId":"io.s2arm.games.t.010026300ba4a000","shellCurrent":false,"signedAt":1000,"expiresAtEstimate":865000},{"bundleId":"x"}]},{"device":"D2"}]}"""))!;
        check(sa.Phones[0].Apps is { Count: 1 } la && la[0] == new PhoneOverview.App("010026300BA4A000", "io.s2arm.games.t.010026300ba4a000", false,
            DateTimeOffset.FromUnixTimeSeconds(1000), DateTimeOffset.FromUnixTimeSeconds(865000)) && (sa.Phones[1].Apps?.Count ?? 0) == 0, "console: standalone apps parsed");

        var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
        PhoneOverview.Phone Ph(bool installed = true, bool current = true, double? expires = 6 * 86_400 - 60, bool probed = false, string? online = null,
            PhoneOverview.GameState[]? games = null, string device = "D1", DateTimeOffset? seen = null) =>
            new(device, "我的手机", installed, current, expires is { } e ? now.AddSeconds(e) : null, probed, online, seen, "appleId",
                (games ?? []).Select((s, i) => new PhoneOverview.Game("G" + i, s, s == PhoneOverview.GameState.Suggested ? ["shader"] : [], true)).ToArray());
        string K(PhoneOverview.Phone? x, int done = 0, int total = 0) { var (k, a) = PhoneOverview.Status(x, now, done, total); return k + (a.Length > 0 ? ":" + string.Join(",", a) : ""); }
        check(K(null) == "console.status.introduce", "status: nothing seen → intro card");
        check(K(Ph(installed: false, probed: true, seen: now)) == "console.status.notConnected:" + now, "status: offline before not-installed");
        check(K(Ph(installed: false, probed: true)) == "console.status.notConnectedNever", "status: offline, never synced");
        check(K(Ph(), 1, 3) == "console.status.updating:2,3", "status: updating shows the current one");
        check(K(Ph(installed: false)) == "console.status.notInstalled", "status: not installed");
        check(K(Ph(current: false, expires: -10)) == "console.status.appOutdated", "status: new app before expiry");
        check(K(Ph(expires: -10)) == "console.status.expired", "status: expired");
        check(K(Ph(expires: 86_400 + 5, games: [PhoneOverview.GameState.Suggested])) == "console.status.expiring:2", "status: a day and a bit = 2 days; expiring before suggested");
        check(K(Ph(games: [PhoneOverview.GameState.Suggested, PhoneOverview.GameState.Suggested, PhoneOverview.GameState.Latest])) == "console.status.suggested:2", "status: suggested count");
        check(K(Ph(games: [PhoneOverview.GameState.Latest])) == "console.status.ok:6", "status: ok with days");
        check(K(Ph(expires: null)) == "console.status.okNoDays", "status: no estimate (certificate) → no days");

        var two = new PhoneOverview([Ph(device: "OLD", seen: now.AddSeconds(-99)), Ph(device: "NEW", seen: now)]);
        check(two.Pick(null)?.Device == "NEW", "pick: most recently synced");
        var online = new PhoneOverview([Ph(device: "OLD", probed: true, online: "usb", seen: now.AddSeconds(-99)), Ph(device: "NEW", seen: now)]);
        check(online.Pick(null)?.Device == "OLD" && online.Pick("NEW")?.Device == "NEW", "pick: connected one first; a chosen one wins");

        // 11-19 自签走查结构 4、5：别的工具（AltStore / SideStore）装的 S2Arm（同 Mac PhoneConsoleTests；期望按作业契约 host_update.phone_overview 手写）
        const string alt = "io.s2arm.games.example01";
        var ext = PhoneOverview.Parse(J("""{"phones":[{"device":"ALT-1","name":"备用手机","installed":true,"installedBy":"external","bundleId":"io.s2arm.games.example01","shellCurrent":null,"signMode":"external","online":"usb","actions":["exportShellIpa","pushS2arm","exportS2arm","handOverIdentity"],"games":[]}, {"device":"P1","installed":true,"installedBy":"launcher","bundleId":"io.example.one","shellCurrent":true}, {"device":"OLD","installed":true,"shellCurrent":true}, {"device":"NEW","installedBy":"weird"}]}"""))!;
        var a1 = ext.Phones[0];
        check(a1.InstalledBy == "external" && a1.External && a1.BundleId == alt && !a1.ShellCurrent && a1.Actions!.SequenceEqual(["exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity"]),
            "external: installedBy / bundleId / actions parsed, shellCurrent null → false");
        check(ext.Phones[1].InstalledBy == "launcher" && ext.Phones[2].InstalledBy is null && ext.Phones[3].InstalledBy is null && ext.Phones[2].Actions!.Count == 0,
            "external: old job without installedBy → null; unknown value → null; no actions → empty");
        check(K(a1) == "console.status.externalApp", "status: external app has its own state (not notInstalled / appOutdated / expired)");
        check(K(a1 with { Online = null }) == "console.status.notConnectedNever", "status: offline still comes first");
        string Acts(PhoneOverview.Phone x) => string.Join(",", PhoneOverview.Actions(x));
        check(Acts(a1) == "exportShellIpa,pushS2arm,exportS2arm,handOverIdentity", "actions: external → the four job buttons in order");
        check(Acts(a1 with { Actions = ["installShell", "renewShell", "handOverIdentity", "bogus"] }) == "handOverIdentity", "actions: external never shows install / renew, unknown dropped");
        check(Acts(a1 with { Actions = [] }) == "exportShellIpa,pushS2arm,exportS2arm,handOverIdentity", "actions: external without job actions → the four defaults");
        check(Acts(Ph()) == "renewShell,handOverIdentity,updateSelected" && Acts(Ph(installed: false)).StartsWith("installShell,") && Acts(Ph(current: false)).StartsWith("updateShell,"),
            "actions: launcher phones keep install / update / renew + identity + update selected");
        var st = ext.ConsoleState();
        Dictionary<string, object?> Inst(int i) => (Dictionary<string, object?>)st[i]["installed"]!;
        check((string?)Inst(0)["by"] == "other" && (string?)Inst(0)["bundleId"] == alt && st[0]["device"] as string == "ALT-1", "state: external → installed.by other with its bundle id");
        var acts0 = (List<string>)st[0]["actions"]!;
        check(!acts0.Contains("installShell") && acts0.Contains("handOverIdentity"), "state: acceptance — external phone has handOverIdentity and no installShell");
        check((string?)Inst(1)["by"] == "s2arm" && Inst(2)["by"] is null && Inst(3)["bundleId"] is null, "state: launcher → s2arm; unknown → null; no bundle → null");
        // 同一台 iPhone 上装着不止一个 S2Arm：玩家选、选一次记住（同 Mac PhoneConsoleTests；期望按作业契约 host_update.phone_overview needsChoice / candidates 手写）
        const string own = "io.s2arm.games.example02";
        const string cands = """[{"bundleId":"io.s2arm.games.example01","team":"TEAMALT","byThisLauncher":false,"identityTeam":"TEAMALT"},{"bundleId":"io.s2arm.games.example02","team":"TEAMOWN","byThisLauncher":true,"identityTeam":null}]""";
        var duo = PhoneOverview.Parse(J("""{"phones":[{"device":"DUO-1","installed":true,"bundleId":"","shellCurrent":null,"signMode":null,"online":"usb","needsChoice":true,"actions":["chooseApp"],"candidates":""" + cands + ""","games":[]},"""
            + """{"device":"P1","installed":true,"installedBy":"launcher","bundleId":"io.s2arm.games.example02","shellCurrent":true,"candidates":""" + cands + """},"""
            + """{"device":"OLD","installed":true},{"device":"BAD","candidates":[{"team":"TEAMALT"},{"bundleId":"","team":"X"}]}]}"""))!;
        var d0 = duo.Phones[0];
        check(d0.NeedsChoice && !duo.Phones[1].NeedsChoice && !duo.Phones[2].NeedsChoice, "choose: needsChoice parsed; absent = false");
        check(d0.Candidates!.SequenceEqual([new PhoneOverview.Candidate(alt, "TEAMALT", false, "TEAMALT"), new PhoneOverview.Candidate(own, "TEAMOWN", true, null)]),
            "choose: candidates in job order, identityTeam null → null");
        check(d0.Installed && d0.BundleId == "" && d0.InstalledBy is null, "choose: needsChoice phone is installed with no current bundle");
        check(duo.Phones[1].Candidates!.Count == 2 && duo.Phones[2].Candidates!.Count == 0 && duo.Phones[3].Candidates!.Count == 0, "choose: chosen keeps candidates; none = empty; candidates without bundle id dropped");
        check(K(d0) == "console.status.chooseApp" && K(d0 with { Online = null }) == "console.status.notConnectedNever", "status: choose after offline, before everything else");
        check(Acts(Ph(installed: false)) == "installShell,updateSelected", "actions: no S2Arm on the phone yet → no hand-over-identity button (nothing to hand it to)");
        check(Acts(d0) == "chooseApp", "actions: needsChoice → only chooseApp (no install / update)");
        check(Acts(duo.Phones[1]) == "renewShell,handOverIdentity,updateSelected,chooseApp", "actions: chosen with several candidates → change entry at the end");
        check(Acts(a1) == "exportShellIpa,pushS2arm,exportS2arm,handOverIdentity", "actions: only one S2Arm → no change entry");
        string L(PhoneOverview.Candidate c) => string.Join(",", PhoneOverview.CandidateLabelKeys(c));
        check(L(new(alt, "TEAMALT", false, null)) == "console.choose.byOther", "label: another tool");
        check(L(new(alt, "TEAMALT", false, "TEAMALT")) == "console.choose.byOther,console.choose.certImported", "label: certificate team matches → imported");
        check(L(new(alt, "TEAMALT", false, "TEAMOTHER")) == "console.choose.byOther" && L(new(alt, "", false, null)) == "console.choose.byOther", "label: team mismatch / empty → not imported");
        check(L(new(own, "TEAMOWN", true, null)) == "console.choose.byLauncher", "label: this launcher");
        var ds = duo.ConsoleState();
        var dc = (List<Dictionary<string, object?>>)ds[0]["candidates"]!;
        check((bool)ds[0]["needsChoice"]! && ((Dictionary<string, object?>)ds[0]["installed"]!)["bundleId"] is null && ((List<string>)ds[0]["actions"]!).SequenceEqual(["chooseApp"]),
            "state: needsChoice, no current bundle, only chooseApp");
        check(dc.Count == 2 && (string?)dc[0]["bundleId"] == alt && (bool)dc[1]["byThisLauncher"]! && dc[1]["identityTeam"] is null && (string?)dc[0]["team"] == "TEAMALT", "state: candidates carried");
        check(!(bool)ds[1]["needsChoice"]! && (string?)((Dictionary<string, object?>)ds[1]["installed"]!)["bundleId"] == own, "state: chosen one is installed.bundleId");
        // 推送失败「装着不止一个、还没选」：诊断 facts {device, candidates}（install.owner_for_push）→ 失败页就地列候选（期望手写）
        var facts = PhoneOverview.ChoiceFacts(J("""[{"code":"phone_app_choice_required","severity":"error","facts":{"device":"DUO-1","candidates":""" + cands + """}}]"""));
        check(facts is { } f && f.Device == "DUO-1" && f.Candidates.SequenceEqual([new PhoneOverview.Candidate(alt, "TEAMALT", false, "TEAMALT"), new PhoneOverview.Candidate(own, "TEAMOWN", true, null)]),
            "choice facts: device and candidates from the push failure");
        check(PhoneOverview.ChoiceFacts(J("""[{"code":"device_not_ready","severity":"error","facts":{"device":"DUO-1","candidates":""" + cands + """}}]""")) is null
            && PhoneOverview.ChoiceFacts(J("""[{"code":"phone_app_choice_required","severity":"error"}]""")) is null
            && PhoneOverview.ChoiceFacts(J("""[{"code":"phone_app_choice_required","facts":{"device":"DUO-1","candidates":[]}}]""")) is null
            && PhoneOverview.ChoiceFacts(J("{}")) is null, "choice facts: other code / no facts / no candidates / not an array → null");
        // 「更新所选」有款没推成：诊断 facts.games 逐款结果（install.push_selected）→ 失败款与原因（作业层原句），重试只推失败款（期望手写）
        var pushFailed = J("""[{"code":"resource_transfer_failed","severity":"error","summary":"资源包写进 iPhone 时中断","facts":{"games":[{"gameId":"0100aaaa","ok":false,"code":"resource_transfer_failed","message":"资源包写进 iPhone 时中断"},{"gameId":"0100BBBB","ok":true},{"gameId":"0100CCCC","ok":false,"code":"pack_missing","message":"这款资源包缺件"}]}}]""");
        var pf = PhoneOverview.PushFailures(pushFailed);
        check(pf.SequenceEqual([new PhoneOverview.PushFailure("0100AAAA", "resource_transfer_failed", "资源包写进 iPhone 时中断"), new PhoneOverview.PushFailure("0100CCCC", "pack_missing", "这款资源包缺件")]),
            "push failures: failed games with code and reason, in push order, succeeded one left out");
        check(PhoneOverview.RetryOrder(pf) is { } ro && ro.SequenceEqual(["0100AAAA", "0100CCCC"]), "push retry: only the failed games");
        var stopped = PhoneOverview.PushFailures(J("""[{"code":"device_not_connected","severity":"error","summary":"手机没连上"}]"""));
        check(stopped.Count == 0 && PhoneOverview.RetryOrder(stopped) is null && PhoneOverview.PushFailures(J("{}")).Count == 0,
            "push failures: whole-round stop has no per-game results → retry resumes");
    }
}
