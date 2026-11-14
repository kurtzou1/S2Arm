// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

internal static class LibraryJobCases
{
    public static void Run(Action<bool, string> check)
    {
        // 封面按 catalog 给的这款文件夹认（#330：v0.2.0 起文件夹按英文名，原先按游戏号拼 games\<号>\ 一律退回占位图）
        var lib = Path.Combine(Path.GetTempPath(), "s2a-cover-" + Guid.NewGuid().ToString("N"));
        var english = Path.Combine(lib, "games", "Animal Crossing New Horizons");
        var byId = Path.Combine(lib, "games", "0100F38011CFE000");
        LibraryGame Game(string id, string cover, string folder, string state = "ok") =>
            new(id, "n", "", cover, false, Array.Empty<string>(), Location: new GameLocation(state, lib, folder, "", true));
        check(Game("01006F8002326000", Path.Combine(english, "cover.jpg"), english).CoverFile() == Path.Combine(english, "cover.jpg"), "cover: English-named game folder is shown");
        check(Game("0100F38011CFE000", Path.Combine(byId, "cover.jpg"), byId).CoverFile() == Path.Combine(byId, "cover.jpg"), "cover: game-id folder still shown");
        check(Game("01006F8002326000", Path.Combine(english, "cover.custom.0a1b2c3d.jpg"), english).CoverFile() is not null, "cover: custom cover in the English folder is shown");
        check(Game("01006F8002326000", Path.Combine(byId, "cover.jpg"), english).CoverFile() is null, "cover: another game's folder is refused");
        check(Game("01006F8002326000", Path.Combine(english, "banner.jpg"), english).CoverFile() == Path.Combine(english, "banner.jpg"), "cover: store banner is the fallback when the game has no icon");
        check(Game("01006F8002326000", Path.Combine(english, "icon.jpg"), english).CoverFile() is null, "cover: other file names are refused");
        check(Game("01006F8002326000", Path.Combine(english, "sub", "cover.jpg"), english).CoverFile() is null, "cover: nested paths are refused");
        check(Game("01006F8002326000", Path.Combine(english, "cover.jpg"), english, "offline").CoverFile() is null, "cover: offline location shows no cover");

        // 导入失败的去向：只有读取器确认通用密钥版本不足（keys_outdated）才引导换密钥；
        // 无法读取、缺票据、内容截断都不是换 prod.keys 能解决的。
        check(ImportFailureRoute.For("keys_missing", false) == ImportFailureRoute.ImportKeys, "missing prod.keys asks to import keys");
        check(ImportFailureRoute.For("keys_outdated", true) == ImportFailureRoute.ReplaceKeys, "outdated keys asks to replace keys");
        check(ImportFailureRoute.For("keys_outdated", false) == ImportFailureRoute.ShowMessage, "outdated keys without ready keys shows the message");
        foreach (var code in new[] { "content_unreadable", "ticket_missing", "content_truncated", "disk_full", null })
            check(ImportFailureRoute.For(code, true) == ImportFailureRoute.ShowMessage, "no key prompt for " + (code ?? "no code"));
        const string sample = """
        {"schema":1,"jobId":"catalog-test","taskId":"catalog-test","seq":1,"type":"stage","operation":"catalog","state":"running","message":"读取游戏库"}
        {"schema":1,"jobId":"catalog-test","taskId":"catalog-test","seq":2,"type":"result","operation":"catalog","state":"succeeded","message":"操作完成","result":{"games":[{"id":"0100000000000001","name":"Synthetic game","display":"1.2","cover":"","hidden":false,"missing":["Need base"],"ready":false}],"keys":{"ready":false,"verified":false,"message":"尚未导入"}}}
        """;
        var report = LibraryJobResult.Parse(sample, 0, "catalog-test", "catalog");
        check(report.Succeeded && report.Message == "操作完成", "jobs terminal result and exit agree");
        var catalog = LibraryCatalog.Parse(report.Result);
        check(catalog.Games.Count == 1 && catalog.Games[0].Name == "Synthetic game" &&
            catalog.Games[0].Version == "1.2" && !catalog.KeysReady, "handwritten catalog values preserved");
        check(catalog.Games[0].Missing.Single() == "Need base", "backend requirements preserved without UI inference");
        // #141：本体 + 2 个 DLC 同一个原件（sha256 相同，size 都是整个原件）：合计按原件算一次，每项自己的字节用 contentBytes；单项原件照旧用 size
        const string bundle = """
        {"schema":1,"jobId":"catalog-test","taskId":"catalog-test","seq":1,"type":"result","operation":"catalog","state":"succeeded","message":"操作完成","result":{"games":[{"id":"0100000000000002","name":"Bundle","display":"","cover":"","hidden":false,"missing":[],"packages":[{"type":"base","titleId":"0100000000000002","version":0,"display":"","size":15032385536,"format":"","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","contentBytes":15032180736},{"type":"dlc","titleId":"0100000000001003","version":0,"display":"","size":15032385536,"format":"","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","contentBytes":102400},{"type":"dlc","titleId":"0100000000001004","version":0,"display":"","size":15032385536,"format":"","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","contentBytes":102400},{"type":"dlc","titleId":"0100000000001005","version":0,"display":"","size":3145728,"format":"","sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","contentBytes":5242880}]}],"keys":{"ready":true,"verified":true,"message":""}}}
        """;
        var bundled = LibraryCatalog.Parse(LibraryJobResult.Parse(bundle, 0, "catalog-test", "catalog").Result).Games[0];
        check(bundled.TotalBytes == 15032385536L + 3145728L, "bundle: source total counts the shared file once");
        check(bundled.Packages!.Where(p => p.Type == "dlc" && p.Sha256.StartsWith('c')).All(p => bundled.OwnBytes(p) == 102400), "bundle: each DLC in the shared file shows its own bytes");
        check(bundled.OwnBytes(bundled.Packages![3]) == 3145728 && bundled.OwnBytes(bundled.Packages![0]) == 15032180736L, "bundle: single-package file keeps file size, base uses its own content");
        void Reject(string data, int exit, string label)
        {
            try { LibraryJobResult.Parse(data, exit, "catalog-test", "catalog"); }
            catch (LibraryProtocolException) { check(true, label); return; }
            throw new Exception("accepted " + label);
        }
        Reject(sample, 1, "successful result cannot hide failed process exit");
        Reject(sample.Split('\n')[0], 0, "EOF without terminal result is not success");
        Reject(sample.Replace("catalog-test", "other-job"), 0, "reject foreign task events");
        Reject(sample.Replace("\"operation\":\"catalog\"", "\"operation\":\"import\""), 0, "reject foreign operation events");
        Reject(sample.Replace("\"seq\":2", "\"seq\":1"), 0, "reject repeated sequence");
        Reject(sample.Replace("\"schema\":1", "\"schema\":2"), 0, "reject unknown event schema");
        Reject(sample + "\n" + sample.Split('\n')[0], 0, "no event after terminal result");
        Reject(sample.Replace("\"seq\":2", "\"seq\":2,\"seq\":3"), 0, "reject duplicate JSON fields");
        var failed = sample.Replace("succeeded", "failed");
        check(!LibraryJobResult.Parse(failed, 1, "catalog-test", "catalog").Succeeded, "backend failure remains failure");
        Reject(failed, 0, "failure result and zero exit disagree");
        Reject("not json", 0, "non JSON stdout rejected");
        var recorded = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "library-catalog.ndjson"));
        var empty = LibraryCatalog.Parse(LibraryJobResult.Parse(recorded, 0, "recorded-catalog", "catalog").Result);
        check(empty.Games.Count == 0 && !empty.KeysReady, "recorded real empty Windows catalogue has no games or keys");
        check(empty.KeysMessage == "尚未导入 prod.keys", "recorded backend key status stays verbatim");
        check(empty.PhoneUpdates.Count == 0, "catalog: no phoneUpdates field reads as an empty list");
        // 壳比本版旧的手机（pack/jobs/install.py phone_updates 的形状）：一台两款、其中一款要重新出包；不是数组 / 没有 device 的项不算
        const string updates = """
        {"games":[],"keys":{"ready":true,"message":""},"phoneUpdates":[
          {"device":"dev-key-1","name":"测试手机","fromShell":"s1","toShell":"s2",
           "games":[{"gameId":"0100A","name":"Alpha"},{"gameId":"0100B","name":""}],"stale":[{"gameId":"0100B","name":""}]},
          {"name":"no device"}]}
        """;
        // 剃刀 W10：要不要 prod.keys 只读作业层 catalog 的 needsKeys（不按包格式另算）：NUP 款后端说要（比如带了 NSP 的 DLC）就是要，没给就是不要
        const string keyed = """
        {"games":[{"id":"0100A","name":"A","display":"","cover":"","hidden":false,"missing":[],"packages":[{"type":"base","titleId":"0100A","version":0,"display":"","size":1,"format":"nup"}],"needsKeys":true,"onPhone":true},
                  {"id":"0100B","name":"B","display":"","cover":"","hidden":false,"missing":[],"packages":[{"type":"base","titleId":"0100B","version":0,"display":"","size":1,"format":"nsp"}]}],
         "keys":{"ready":false,"message":""}}
        """;
        using (var document = System.Text.Json.JsonDocument.Parse(keyed))
        {
            var g = LibraryCatalog.Parse(document.RootElement).Games;
            check(g[0].NeedsKeys && !g[1].NeedsKeys, "catalog: needsKeys comes from the backend field, not from package formats");
            check(g[0].OnPhone && !g[1].OnPhone, "catalog: onPhone (recorded on a phone; delete confirm warns it stops opening there) read from the backend field");
        }
        using (var document = System.Text.Json.JsonDocument.Parse(updates))
        {
            var u = LibraryCatalog.Parse(document.RootElement).PhoneUpdates;
            check(u.Count == 1 && u[0].Device == "dev-key-1" && u[0].Name == "测试手机" && u[0].FromShell == "s1" && u[0].ToShell == "s2",
                "catalog: phoneUpdates device, name and shells read; entry without device skipped");
            check(string.Join(",", u[0].Games.Select(g => g.Id + "=" + g.Name)) == "0100A=Alpha,0100B=0100B" &&
                  string.Join(",", u[0].Stale.Select(g => g.Id)) == "0100B", "catalog: phoneUpdates games / stale, empty name falls back to the game id");
        }
        using (var document = System.Text.Json.JsonDocument.Parse(updates.Replace("\"phoneUpdates\":[", "\"phoneUpdates\":null,\"x\":[")))
            check(LibraryCatalog.Parse(document.RootElement).PhoneUpdates.Count == 0, "catalog: phoneUpdates null reads as an empty list");
        using (var document = System.Text.Json.JsonDocument.Parse(updates.Replace(",\"stale\":[{\"gameId\":\"0100B\",\"name\":\"\"}]", "")))
            check(LibraryCatalog.Parse(document.RootElement).PhoneUpdates[0].Stale.Count == 0, "catalog: phoneUpdates entry without stale reads as none stale");
        var canonical = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "canonical-library"));
        using var setup = System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(new { library = canonical, libraryId = "legacy-id" }));
        LibraryConnection connection;
        try { connection = LibraryConnection.Parse(setup.RootElement); }
        catch (LibraryProtocolException error) { throw new Exception("backend library id is opaque", error); }
        check(connection.Id == "legacy-id" && connection.Folder == canonical, "backend canonical folder and opaque identifier preserved");
        foreach (var invalid in new[] { new {library="relative-library", libraryId="legacy-id"}, new {library=canonical, libraryId=""} })
        {
            using var document = System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(invalid));
            try { LibraryConnection.Parse(document.RootElement); throw new Exception("accepted invalid library connection"); }
            catch (LibraryProtocolException) { check(true, "reject invalid connection envelope"); }
        }
        foreach (var malformed in new[] { "{}", "{\"games\":[],\"keys\":{\"ready\":\"yes\",\"message\":\"\"}}" })
        {
            using var document = System.Text.Json.JsonDocument.Parse(malformed);
            try { LibraryCatalog.Parse(document.RootElement); throw new Exception("accepted malformed catalogue"); }
            catch (LibraryProtocolException) { check(true, "reject malformed catalogue"); }
        }

        // ---- library layout v3: game.location in catalog, locations job (shapes from pack/jobs/library.py catalog / location_rows) ----
        const string located = """
        {"games":[{"id":"A","name":"a","display":"","cover":"","hidden":false,"missing":[],"location":{"state":"offline","path":"E:\\S2Arm","folder":"","volume":"Games","default":false}},
                  {"id":"B","name":"b","display":"","cover":"","hidden":false,"missing":[]}],"keys":{"ready":true,"message":""}}
        """;
        using (var document = System.Text.Json.JsonDocument.Parse(located))
        {
            var games = LibraryCatalog.Parse(document.RootElement).Games;
            check(games[0].LocationState == "offline" && !games[0].Reachable && games[0].Location!.Path == "E:\\S2Arm" && games[0].Location!.Volume == "Games",
                "catalog: offline location kept with its path and volume, game not reachable");
            check(games[1].LocationState == "none" && games[1].Reachable && games[1].Location is null, "catalog: no location field reads as none, reachable");
        }
        using (var document = System.Text.Json.JsonDocument.Parse(located.Replace("\"offline\"", "\"lost\"")))
        {
            try { LibraryCatalog.Parse(document.RootElement); throw new Exception("accepted unknown location state"); }
            catch (LibraryProtocolException) { check(true, "catalog: unknown location state rejected"); }
        }
        const string rows = """
        {"locations":[{"id":"a","path":"/lib","volume":"系统盘","connected":true,"freeBytes":5000000000,"default":true},
                      {"id":"b","path":"/ext","volume":"Ext","connected":false,"freeBytes":null,"default":false},
                      {"id":"c","path":"/other","volume":"Other","connected":true,"freeBytes":10,"default":false}],"last":"c"}
        """;
        StorageLocations Locations(string json)
        {
            using var document = System.Text.Json.JsonDocument.Parse(json);
            return StorageLocations.Parse(document.RootElement);
        }
        var places = Locations(rows);
        check(places.Rows.Count == 3 && places.Rows[0].FreeBytes == 5000000000 && places.Rows[0].IsDefault && places.Rows[1].FreeBytes is null &&
              !places.Rows[1].Connected && places.Last == "c", "locations: rows, free space, connection and last id preserved");
        check(places.DefaultFor(new("offline", "/ext", "", "Ext", false)) == "/ext", "locations: default = where the game is now, even offline");
        check(places.DefaultFor(new("ok", "/lib", "/lib/games/A", "系统盘", true)) == "/lib", "locations: default = current location when ok");
        check(places.DefaultFor(new("missing", "/ext", "", "Ext", false)) == "/other" && places.DefaultFor(null) == "/other",
            "locations: missing / no location → the location used last");
        check(Locations(rows.Replace("\"last\":\"c\"", "\"last\":\"b\"")).DefaultFor(null) == "/lib", "locations: last one not connected → default location");
        try { Locations(rows.Replace("\"connected\":true,", "")); throw new Exception("accepted location without connected"); }
        catch (LibraryProtocolException) { check(true, "locations: row without connected rejected"); }
        // #444：存放位置所在盘会让出包多占空间 / 可能失败（后端 libloc.slack_reason）；probe = 刚选的文件夹
        check(places.Rows.All(r => r.Slack is null) && !places.Probed && places.ProbeSlack is null, "locations: no slack / probe fields read as none");
        var slack = Locations(rows.Replace("\"freeBytes\":10,", "\"freeBytes\":10,\"format\":\"exfat\",\"clusterBytes\":524288,\"slackWarning\":true,\"slackReason\":\"cluster\",")
            .Replace(",\"last\":\"c\"", ",\"last\":\"c\",\"probe\":{\"path\":\"E:\\\\games\",\"format\":\"fat32\",\"clusterBytes\":32768,\"slackWarning\":true,\"slackReason\":\"format\"}"));
        check(slack.Rows[2].Slack == new LocationSlack("cluster", 524288) && slack.Rows[0].Slack is null, "locations: slack reason and cluster size per row");
        check(slack.Probed && slack.ProbeSlack == new LocationSlack("format", 32768), "locations: probed folder's slack reason");
        var fine = Locations(rows.Replace(",\"last\":\"c\"", ",\"last\":\"c\",\"probe\":{\"path\":\"C:\\\\S2Arm\",\"format\":\"ntfs\",\"clusterBytes\":4096,\"slackWarning\":false,\"slackReason\":null}"));
        check(fine.Probed && fine.ProbeSlack is null, "locations: probed folder without a problem reads as probed, no slack");

        // ---- library layout v3 P4: catalog game.sizes, storageOverview job (shapes from pack/jobs/sizes.py for_catalog / overview) ----
        using (var document = System.Text.Json.JsonDocument.Parse(located.Replace("\"missing\":[],\"location\"",
            "\"missing\":[],\"sizes\":{\"imageMac\":0,\"imageIos\":6000000000,\"saves\":3,\"cache\":4,\"sources\":5,\"measured\":true},\"location\"")))
        {
            var games = LibraryCatalog.Parse(document.RootElement).Games;
            check(games[0].Sizes == new GameSizes(0, 6000000000, 3, 4, 5, true), "catalog: sizes read, iPhone size beyond Int32 kept");
            check(games[1].Sizes is null, "catalog: no sizes field reads as null (not counted)");
        }
        const string overview = """
        {"locations":[{"id":"a","path":"D:\\S2Arm","volume":"Data","connected":true,"default":true,"totalBytes":9000000000,"freeBytes":4000000000,"usedBytes":3000000000},
                      {"id":"b","path":"E:\\S2Arm","volume":"Ext","connected":false,"default":false}],
         "shared":[{"id":"hosts","bytes":10},{"id":"ipa","bytes":20},{"id":"toolCache","bytes":0},{"id":"temp","bytes":0},{"id":"logs","bytes":5}],
         "games":[{"gameId":"A","name":"Alpha","state":"ok","location":"D:\\S2Arm","sizes":{"imageMac":0,"imageIos":1,"saves":2,"cache":3,"sources":4,"measured":true}},
                  {"gameId":"B","name":"","state":"offline","location":"E:\\S2Arm","sizes":{"imageMac":0,"imageIos":0,"saves":0,"cache":0,"sources":7,"measured":false}}]}
        """;
        StorageOverview Overview(string json)
        {
            using var document = System.Text.Json.JsonDocument.Parse(json);
            return StorageOverview.Parse(document.RootElement);
        }
        var o = Overview(overview);
        check(o.Locations.Count == 2 && o.Locations[0].IsDefault && o.Locations[0].UsedBytes == 3000000000 && o.Locations[0].FreeBytes == 4000000000 &&
              o.Locations[0].TotalBytes == 9000000000, "overview: connected location keeps total / free / used beyond Int32");
        check(!o.Locations[1].Connected && o.Locations[1].FreeBytes is null && o.Locations[1].UsedBytes is null, "overview: offline location has no fake zero");
        check(string.Join(",", o.Shared.Select(p => p.Id + "=" + p.Bytes)) == "hosts=10,ipa=20,toolCache=0,temp=0,logs=5", "overview: shared parts in backend order");
        check(o.Games[0].Sizes == new GameSizes(0, 1, 2, 3, 4, true) && o.Games[1].Name == "B" && o.Games[1].State == "offline" && !o.Games[1].Sizes.Measured,
            "overview: game sizes; empty name falls back to the game id");
        try { Overview(overview.Replace("{\"id\":\"hosts\",\"bytes\":10}", "{\"id\":\"hosts\"}")); throw new Exception("accepted shared part without bytes"); }
        catch (LibraryProtocolException) { check(true, "overview: shared part without bytes rejected"); }
        try { Overview(overview.Replace("\"connected\":false,", "")); throw new Exception("accepted overview location without connected"); }
        catch (LibraryProtocolException) { check(true, "overview: location without connected rejected"); }
    }
}
