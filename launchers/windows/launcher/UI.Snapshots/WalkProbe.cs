// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 玩家走查截图（0.6.4「更新 / 导出」验收的一部分，不代替人读）：6 个玩家角色从打开启动器走到在手机上玩，每一步按真实页面状态离屏画整页，
//   存「角色_步骤_说明.png」，同名 .txt 记屏幕上的字（自上而下、自左而右），供走查记录逐字引用。不跑作业、不连设备：每步的状态直接放进窗口。
//   用法：UI.Snapshots --walk-probe <目录>；末行「✓ 走查截图」。
using System.Reflection;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class WalkProbe
{
    const BindingFlags F = BindingFlags.NonPublic | BindingFlags.Instance;
    static string outDir = "";
    static int shots;

    const string Phone = "UDID-PHONE-1";      // 夹具设备号（不是真设备）
    const string Pad = "UDID-PAD-1";

    public static int Run(string dir)
    {
        outDir = dir; Directory.CreateDirectory(dir);
        var game = new LibraryGame("0100F00D00000000", "示例游戏", "v1.2.0", "", false, [], false, null, false,
            [new("base", "0100F00D00000000", 0, "v1.2.0", 6_000_000_000L, "extract")]);
        var ready = game with { IphoneReady = true, IphoneExportable = true };
        var other = new LibraryGame("0100F00E00000000", "另一款游戏", "v1.0.0", "", false, [], true, null, false,
            [new("base", "0100F00E00000000", 0, "v1.0.0", 2_000_000_000L, "extract")], IphoneExportable: true);

        Role1(game, ready, other);
        Role2(ready, other);
        Role3(ready, other);
        Role4(ready, other);
        Role5(ready, other);
        Role6(ready, other);
        Console.WriteLine($"✓ 走查截图：{shots} 张");
        return 0;
    }

    // ---- 角色 ① 第一次用、免费 Apple ID、手机上没装 S2Arm、这款从没做过 iPhone 版 ----
    static void Role1(LibraryGame game, LibraryGame ready, LibraryGame other)
    {
        var w = NewWindow();
        // 1 打开启动器：第一次，正在检查这台电脑
        var env = BeginJob(w, "Environment", null);
        Set(w, "catalog", null); Set(w, "report", null); Set(w, "summaryKey", "environment.checking");
        Shot(w, "1_01_第一次打开_正在检查电脑", "library");
        EndJob(w, env);
        // 2 检查结果：缺 Apple 设备支持（Apple Devices）
        Set(w, "report", EnvironmentReport.Parse("""
        {"schema":1,"ready":false,"checks":[
         {"id":"host","name":"Windows 64位","status":"ok","ok":true,"message":"就绪","code":null,"action":null,"blocking":true},
         {"id":"metal","name":"官方Windows Metal编译器","status":"ok","ok":true,"message":"已装","code":null,"action":null,"blocking":true},
         {"id":"impactor","name":"Impactor（签名装机）","status":"ok","ok":true,"message":"Impactor 2.7.3 + plumesign。","code":null,"action":null,"blocking":true},
         {"id":"apple_driver","name":"Apple移动设备支持","status":"missing","ok":false,"message":"没找到Apple设备支持。查过：本机usbmux端口 127.0.0.1:27015：连不上；服务 Apple Mobile Device Service：没装（商店版 Apple Devices 不注册这个服务，属正常）；商店版 Apple Devices：没装","code":"win_apple_driver_missing","action":"install","blocking":true,"url":"https://apps.microsoft.com/detail/9np83lwlpz9k"}]}
        """, 1));
        Set(w, "summaryKey", "environment.not_ready");
        Shot(w, "1_02_环境检查_缺Apple设备支持", "library");
        // 3 装好 Apple Devices、回到窗口自动重查：全部通过，第 2 步添加游戏
        Set(w, "report", EnvironmentReport.Parse("""{"schema":1,"ready":true,"checks":[{"id":"host","name":"Windows 64位","status":"ok","ok":true,"message":"就绪","code":null,"action":null}]}""", 0));
        Set(w, "summaryKey", "environment.ready");
        Shot(w, "1_03_环境就绪_添加游戏", "library");
        // 4 选好游戏文件、还差密钥
        Set(w, "pendingImportPaths", new[] { @"D:\Switch\示例游戏.nsp" });
        Set(w, "catalog", new LibraryCatalog([], false, ""));
        Library(w, [], keys: false); Set(w, "pendingImportPaths", new[] { @"D:\Switch\示例游戏.nsp" });
        Shot(w, "1_04_选好游戏_放入密钥", "library");
        // 5 导入完成：欢迎页右下的下一步
        Set(w, "pendingImportPaths", Array.Empty<string>());
        Library(w, [game]); Set(w, "welcomeGameId", game.Id);
        Shot(w, "1_05_导入完成_下一步", "library");
        Set(w, "welcomeGameId", null);
        // 6 游戏库：这款没做过 iPhone 版
        var bare = PhoneJson(Phone, "我的 iPhone", "iPhone", installed: false, by: null);
        Library(w, [game, other], phones: [bare]);
        Set(w, "selectedGame", game.Id);
        Shot(w, "1_06_游戏库_大卡", "library");
        // 7 导出确认页：缺省 Apple ID、手机还没装 S2Arm、这款要先做好
        OpenExport(w, game);
        Shot(w, "1_07_导出确认页", "exportgame");
        // 8 点「去 S2Arm 卡」：总控台这台手机
        Set(w, "consoleDevice", Phone); Set(w, "selectedGame", "s2arm.console");
        Shot(w, "1_08_S2Arm卡_还没装", "library");
        // 9 点「安装 S2Arm」：没登录 Apple ID → 失败
        PhoneUpdate(w, "failed", "还没用 Apple ID 登录：签名前要先登录。", code: "apple_not_signed_in",
            suggestion: "Impactor 里还没登录 Apple ID：在装机页点「打开 Impactor」→「设置」→「添加账号」，用你的 Apple ID 登录（邮箱、密码、手机上的验证码，输入前切到英文输入法）。");
        Shot(w, "1_09_安装S2Arm_没登录AppleID", "phoneupdate");
        // 10 登录后重试：装好
        PhoneUpdate(w, "succeeded", "");
        Shot(w, "1_10_安装S2Arm_装好", "phoneupdate");
        // 11 回导出确认页、勾上这台、开始 → 先在电脑上做好 iPhone 版（出包进度）
        var installed = PhoneJson(Phone, "我的 iPhone", "iPhone", installed: true, by: "launcher", current: true);
        Library(w, [game, other], phones: [installed]);
        OpenExport(w, game); Picked(w, Phone);
        Shot(w, "1_11_导出确认页_装好S2Arm后勾上", "exportgame");
        Packing(w, game, [Phone]);
        Shot(w, "1_12_开始_先做iPhone版_出包进度", "progress");
        Shot(w, "1_13_开始_先做iPhone版_导出页", "exportgame");
        ClearPack(w);
        // 14 推到这台：在推 / 装好
        Library(w, [ready, other], phones: [installed]);
        var job = Pushing(w, ready, "appleId", "shell", [Phone], Phone, "把这款的资源推进 iPhone");
        Shot(w, "1_14_推到iPhone_进行中", "exportgame");
        EndJob(w, job);
        Done(w, ready, "appleId", "shell", (Phone, "succeeded", "", null));
        Shot(w, "1_15_推到iPhone_已装到这台", "exportgame");
        w.Close(); Dispatcher.UIThread.RunJobs();
    }

    // ---- 角色 ② 用买来的 P12（分发证书）----
    static void Role2(LibraryGame ready, LibraryGame other)
    {
        var w = NewWindow();
        var phone = PhoneJson(Phone, "我的 iPhone", "iPhone", installed: false, by: null);
        Library(w, [ready, other], phones: [phone]);
        Set(w, "selectedGame", ready.Id);
        Shot(w, "2_01_打开启动器_游戏库", "library");
        // 设置 → 签名身份：点「我的证书」打开导入弹窗
        Shot(w, "2_02_设置_签名身份", "settings");
        var dialog = OpenDialog(w, "ImportDevCertAsync");
        if (dialog is not null) { ShotWindow(dialog, "2_03_导入证书弹窗"); dialog.Close(); Dispatcher.UIThread.RunJobs(); }
        // 导入好：分发证书（照常导入，独立 App 能用；通用 S2Arm 那条有提示）
        Set(w, "devCert", (JsonElement?)J("""
        {"imported":true,"active":true,"cert":{"blocking":[],"warnings":[],"distribution":true,
         "teamName":"示例公司","teamId":"ABCDE12345","certExpires":"2027-05-01","profileExpires":"2027-05-01",
         "bundleId":"com.example.*","wildcard":true,"allDevices":false,"deviceCount":3,"deviceListed":true,"missingEntitlements":[],"requestText":""}}
        """));
        Set(w, "signChoice", "devCert"); Set(w, "layout", "standalone"); Set(w, "layoutRecommend", "standalone"); Set(w, "layoutRecommendWhy", "distribution");
        Shot(w, "2_04_设置_证书已导入", "settings");
        // 导出确认页：缺省「我的证书」+ 独立 App
        OpenExport(w, ready);
        Shot(w, "2_05_导出确认页", "exportgame");
        Picked(w, Phone);
        Shot(w, "2_06_导出确认页_勾上iPhone", "exportgame");
        Done(w, ready, "devCert", "standalone", (Phone, "succeeded", "", null));
        Shot(w, "2_07_已装到这台", "exportgame");
        w.Close(); Dispatcher.UIThread.RunJobs();
    }

    // ---- 角色 ③ AltStore / SideStore 装了 S2Arm（自签）----
    static void Role3(LibraryGame ready, LibraryGame other)
    {
        var w = NewWindow();
        var ext = PhoneJson(Phone, "", "iPhone", installed: true, by: "external", bundle: "com.sidestore.s2arm", certImported: false);
        Set(w, "signChoice", "external");
        Library(w, [ready, other], phones: [ext]);
        Set(w, "selectedGame", ready.Id);
        Shot(w, "3_01_打开启动器_游戏库", "library");
        OpenExport(w, ready);
        Shot(w, "3_02_导出确认页_自签_证书没导入", "exportgame");
        // 在手机上 S2Arm 里导入证书后回来重新查
        var extOk = PhoneJson(Phone, "", "iPhone", installed: true, by: "external", bundle: "com.sidestore.s2arm", certImported: true);
        Library(w, [ready, other], phones: [extOk]);
        OpenExport(w, ready); Picked(w, Phone);
        Shot(w, "3_03_导出确认页_自签_勾上", "exportgame");
        Done(w, ready, "none", "shell", (Phone, "succeeded", "", null));
        Shot(w, "3_04_已装到这台", "exportgame");
        w.Close(); Dispatcher.UIThread.RunJobs();
    }

    // ---- 角色 ④ 同时有 iPhone 和 iPad ----
    static void Role4(LibraryGame ready, LibraryGame other)
    {
        var w = NewWindow();
        var p = PhoneJson(Phone, "我的 iPhone", "iPhone", installed: true, by: "launcher", current: true, state: "suggested");
        var d = PhoneJson(Pad, "客厅 iPad", "iPad", installed: true, by: "launcher", current: true, state: null);
        Library(w, [ready, other], phones: [p, d]);
        Set(w, "selectedGame", ready.Id);
        Shot(w, "4_01_打开启动器_游戏库", "library");
        OpenExport(w, ready);
        Shot(w, "4_02_导出确认页_两台", "exportgame");
        Picked(w, Phone, Pad);
        Shot(w, "4_03_导出确认页_两台都勾", "exportgame");
        var job = Pushing(w, ready, "appleId", "shell", [Phone, Pad], Phone, "把这款的资源推进 iPhone", (Phone, "waiting"), (Pad, "waiting"));
        Shot(w, "4_04_逐台_第一台在推第二台排队", "exportgame");
        EndJob(w, job);
        Done(w, ready, "appleId", "shell", (Phone, "succeeded", "", null), (Pad, "failed", "你选的那台设备现在连不上：插上数据线，或让它和电脑在同一个 Wi-Fi。", "device_not_connected"));
        Shot(w, "4_05_逐台_iPad没连上", "exportgame");
        Done(w, ready, "appleId", "shell", (Phone, "succeeded", "", null), (Pad, "succeeded", "", null));
        Shot(w, "4_06_逐台_重试后两台都好", "exportgame");
        w.Close(); Dispatcher.UIThread.RunJobs();
    }

    // ---- 角色 ⑤ 手机没连、只想导出文件 ----
    static void Role5(LibraryGame ready, LibraryGame other)
    {
        var w = NewWindow();
        var off = PhoneJson(Phone, "我的 iPhone", "iPhone", installed: true, by: "launcher", current: true, online: false);
        Library(w, [ready, other], phones: [off]);
        Set(w, "selectedGame", ready.Id);
        Shot(w, "5_01_打开启动器_游戏库", "library");
        OpenExport(w, ready);
        Shot(w, "5_02_导出确认页_手机没连", "exportgame");
        Library(w, [ready, other], phones: []);
        OpenExport(w, ready);
        Shot(w, "5_03_导出确认页_没有设备", "exportgame");
        FolderExport(w, ready, "running");
        Shot(w, "5_04_导出到文件夹_进行中", "exportgame");
        FolderExport(w, ready, "succeeded");
        Shot(w, "5_05_导出到文件夹_导出好了", "exportgame");
        w.Close(); Dispatcher.UIThread.RunJobs();
    }

    // ---- 角色 ⑥ 游戏旧了想更新（建议更新）----
    static void Role6(LibraryGame ready, LibraryGame other)
    {
        var w = NewWindow();
        var p = PhoneJson(Phone, "我的 iPhone", "iPhone", installed: true, by: "launcher", current: true, state: "suggested");
        Library(w, [ready, other], phones: [p]);
        var hints = (Dictionary<string, string[]>)Get(w, "updateHints")!;
        hints[ready.Id] = ["rewriter", "shader"];
        Set(w, "selectedGame", other.Id);
        Shot(w, "6_01_打开启动器_列表上建议更新角标", "library");
        Set(w, "selectedGame", ready.Id);
        Shot(w, "6_02_选中这款_更新这款", "library");
        ((System.Collections.IDictionary)Get(w, "gameUpdating")!)[ready.Id] = ((double?)0.4, "重编着色器库");
        var job = BeginJob(w, "Update", ready.Id);
        Shot(w, "6_03_更新中", "library");
        EndJob(w, job);
        ((System.Collections.IDictionary)Get(w, "gameUpdating")!).Clear();
        ((Dictionary<string, string[]>)Get(w, "updateHints")!).Remove(ready.Id);
        ((System.Collections.IDictionary)Get(w, "gameUpdated")!)[ready.Id] = (true, "", (IReadOnlyList<string>)[]);   // 作业 updateGame 成功、没剩原因
        Shot(w, "6_04_更新完_无需更新", "library");
        OpenExport(w, ready);
        Shot(w, "6_05_导出确认页_已装旧版这款", "exportgame");
        Picked(w, Phone);
        Done(w, ready, "appleId", "shell", (Phone, "succeeded", "", null));
        Shot(w, "6_06_已装到这台", "exportgame");
        w.Close(); Dispatcher.UIThread.RunJobs();
    }

    // ---- 状态放置 ----

    static EnvironmentWindow NewWindow()
    {
        var w = new EnvironmentWindow { Width = 1180, Height = 900 };
        w.Show(); Settle(w);
        Set(w, "language", "zh-Hans");
        Set(w, "installModeTried", true); Set(w, "layoutKnown", true); Set(w, "signChoice", "appleId"); Set(w, "layout", "shell");
        Set(w, "layoutRecommend", "shell"); Set(w, "layoutRecommendWhy", "appleId");   // 同作业 installMode：Apple ID 签推荐通用 S2Arm
        Set(w, "devCert", (JsonElement?)J("""{"imported":false,"active":false,"cert":null}"""));
        Set(w, "devCertFor", "mock-lib-id");
        Set(w, "report", EnvironmentReport.Parse("""{"schema":1,"ready":true,"checks":[]}""", 0));
        return w;
    }

    static void Library(EnvironmentWindow w, IReadOnlyList<LibraryGame> games, bool keys = true, IReadOnlyList<object>? phones = null)
    {
        Set(w, "catalog", new LibraryCatalog(games, keys, keys ? "密钥已就绪" : ""));
        Set(w, "connectedFolder", @"C:\Users\player\S2Arm"); Set(w, "libraryId", "mock-lib-id"); Set(w, "librarySummary", "library.completed");
        Set(w, "updateHintsFor", "mock-lib-id");
        Set(w, "phoneOverview", phones is null ? null : PhoneOverview.Parse(J(JsonSerializer.Serialize(new { phones }))));
    }

    static object PhoneJson(string device, string name, string kind, bool installed, string? by, bool current = false, bool online = true,
        string? state = "notPushed", string bundle = "", bool? certImported = null)
    {
        var d = new Dictionary<string, object?> { ["device"] = device, ["name"] = name, ["kind"] = kind, ["installed"] = installed, ["installedBy"] = by,
            ["shellCurrent"] = current, ["online"] = online ? "usb" : null, ["bundleId"] = bundle, ["signMode"] = by == "external" ? "external" : "appleId",
            ["games"] = state is null ? Array.Empty<object>() : new object[] { new Dictionary<string, object?> { ["gameId"] = "0100F00D00000000", ["state"] = state, ["reasons"] = new[] { "shader" } } } };
        if (certImported is { } ci) d["certImported"] = ci;
        if (by == "external") d["actions"] = new[] { "exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity" };
        return d;
    }

    static void OpenExport(EnvironmentWindow w, LibraryGame g)
    {
        var overview = Get(w, "phoneOverview");
        w.GetType().GetMethod("OpenExport", F)!.Invoke(w, [g, null, null]);
        var until = DateTime.UtcNow.AddSeconds(20);
        while (Get(w, "exportProbing") is true && DateTime.UtcNow < until) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(20); }
        Set(w, "phoneOverview", overview);   // 本机没有引擎，现查作业失败会保持上次的值；这里再放一次，免得被清
    }

    static void Picked(EnvironmentWindow w, params string[] devices)
    {
        var set = (HashSet<string>)Get(w, "exportPicked")!;
        foreach (var d in devices) set.Add(d);
    }

    static object NewRun(EnvironmentWindow w, LibraryGame g, string sign, string layout, IReadOnlyList<string> devices)
    {
        var t = w.GetType().GetNestedType("ExportRun", BindingFlags.NonPublic)!;
        var run = Activator.CreateInstance(t, [g.Id, sign, layout, devices])!;
        ((System.Collections.IDictionary)Get(w, "exportRuns")!)[g.Id] = run;
        Set(w, "selectedGame", g.Id);
        return run;
    }

    static System.Collections.IDictionary Rows(object run) => (System.Collections.IDictionary)run.GetType().GetField("Rows")!.GetValue(run)!;

    static void Done(EnvironmentWindow w, LibraryGame g, string sign, string layout, params (string Device, string State, string Message, string? Code)[] rows)
    {
        var run = NewRun(w, g, sign, layout, rows.Select(r => r.Device).ToList());
        foreach (var r in rows) Rows(run)[r.Device] = (r.State, r.Message, r.Code);
    }

    static object Pushing(EnvironmentWindow w, LibraryGame g, string sign, string layout, IReadOnlyList<string> devices, string now, string message,
        params (string Device, string State)[] rows)
    {
        var run = NewRun(w, g, sign, layout, devices);
        foreach (var d in devices) Rows(run)[d] = ("waiting", "", (string?)null);
        var job = BeginJob(w, "Phone", g.Id);
        Set(w, "installGameId", g.Id); Set(w, "installGameName", g.Name); Set(w, "installDevice", now); Set(w, "installMessage", message);
        Set(w, "installState", "running"); Set(w, "installDone", (long?)2_400_000_000L); Set(w, "installTotal", (long?)6_000_000_000L); Set(w, "installUnit", "B");
        return job;
    }

    static void FolderExport(EnvironmentWindow w, LibraryGame g, string state)
    {
        var run = NewRun(w, g, "none", "shell", []);
        Rows(run)[""] = (state == "running" ? "waiting" : state, "", (string?)null);
        var track = Get(w, "installTrack")!;
        void T(string f, object? v) => track.GetType().GetField(f)!.SetValue(track, v);
        T("Kind", "install"); T("Started", DateTime.UtcNow.AddSeconds(-35));
        Set(w, "installExport", true); Set(w, "installGameId", g.Id); Set(w, "installGameName", g.Name); Set(w, "installState", state);
        if (state == "succeeded")
        {
            T("Ended", (DateTime?)DateTime.UtcNow); T("ExportFolder", @"C:\Users\player\S2Arm\S2Arm 游戏包"); T("ExportGames", 1); T("ExportBytes", (long?)6_200_000_000L);
            T("ExportFresh", new List<string> { "示例游戏.img" });
        }
    }

    static void Packing(EnvironmentWindow w, LibraryGame g, IReadOnlyList<string> devices)
    {
        var run = NewRun(w, g, "appleId", "shell", devices);
        run.GetType().GetField("Packing")!.SetValue(run, true);
        foreach (var d in devices) Rows(run)[d] = ("waiting", "", (string?)null);
        var job = BeginJob(w, "Pack", g.Id);
        _ = job;   // 出包在跑（packRunning 由作业槽推出来），ClearPack 收掉
        Set(w, "packGame", g); Set(w, "packState", "running"); Set(w, "packStarted", DateTime.UtcNow.AddSeconds(-95));
        var track = new MilestoneTrack();
        track.Ingest(J("""
          {"type":"plan","milestone":null,"milestones":[
          {"id":"unpack","label":"解包","purpose":"读出游戏程序和资源，合并更新与 DLC。","expected":120,"source":"history","samples":3,"reuse":false},
          {"id":"prepare","label":"准备资源","purpose":"整理 DLC 和宽屏界面布局，同时在后台把游戏代码改写成苹果设备能直接运行的形式。","expected":300,"source":"history","samples":3,"reuse":false},
          {"id":"ipa","label":"编 App 与签名","purpose":"编出 iPhone / iPad 版程序、签名，并打好要推进手机的资源包。","expected":60,"source":"history","samples":3,"reuse":false}]}
          """), 0);
        track.Ingest(J("""{"type":"stage","milestone":"prepare","message":""}"""), DateTime.UtcNow.Subtract(DateTime.UnixEpoch).TotalSeconds - 20);
        Set(w, "packTrack", track);
    }

    static void ClearPack(EnvironmentWindow w)
    {
        foreach (var job in ((System.Collections.IList)Get(w, "jobs")!).Cast<object>().ToList())
            if (job.GetType().GetProperty("Kind")!.GetValue(job)!.ToString() == "Pack") EndJob(w, job);
        Set(w, "packGame", null); Set(w, "packState", "");
        ((System.Collections.IDictionary)Get(w, "exportRuns")!).Clear();
    }

    static void PhoneUpdate(EnvironmentWindow w, string state, string message, string? code = null, string suggestion = "", bool firstInstall = true)
    {
        var track = Get(w, "updateTrack")!;
        track.GetType().GetMethod("Begin")!.Invoke(track, ["installUpdate", "iPhone「我的 iPhone」"]);
        void T(string f, object? v) => track.GetType().GetField(f)!.SetValue(track, v);
        if (firstInstall) T("TextKind", "installShell");   // 同 UpdatePhoneAsync(firstInstall: true)
        Set(w, "updateFirstInstall", firstInstall);
        T("Started", DateTime.UtcNow.AddSeconds(-50));
        if (state != "running") T("Ended", (DateTime?)DateTime.UtcNow);
        T("Suggestion", suggestion); T("Version", "0.6.4"); T("Device", "iPhone「我的 iPhone」");
        if (state == "succeeded") { T("PackBytes", (long?)0L); T("PackFiles", (int?)0); }
        Set(w, "updateState", state); Set(w, "updateMessage", message);
        if (Has(w, "updateCode")) Set(w, "updateCode", code);
    }

    // ---- 截图与文字 ----

    static void Shot(EnvironmentWindow w, string name, string page)
    {
        Set(w, "page", page);
        Call(w, "Render"); Settle(w);
        FullPage(w);
        Save(w, name);
    }

    /// <summary>整页：把窗口拉到放得下整页内容的高度再截（滚动区内容高 + 顶 / 底栏）</summary>
    static void FullPage(EnvironmentWindow w)
    {
        w.Height = 4000; Settle(w); Call(w, "Render"); Settle(w);
        var scroll = (ScrollViewer)Get(w, "pageScroll")!;
        var body = ((Decorator)Get(w, "pageBody")!).Child;
        // 内容比窗口矮时滚动区会撑满（Extent = 视口），按内容自己要的高度算
        var content = body is null ? scroll.Extent.Height : Math.Min(scroll.Extent.Height, body.DesiredSize.Height);
        var need = content + (w.ClientSize.Height - scroll.Viewport.Height);
        w.Height = Math.Max(700, Math.Ceiling(need) + 8); Settle(w); Call(w, "Render"); Settle(w);
    }

    static void Save(Window w, string name)
    {
        var bmp = w.CaptureRenderedFrame();
        if (bmp is null) { Console.WriteLine("  WARN no frame: " + name); return; }
        using (var s = File.Create(Path.Combine(outDir, name + ".png"))) bmp.Save(s, new PngBitmapEncoderOptions());
        File.WriteAllText(Path.Combine(outDir, name + ".txt"), ScreenText(w), Encoding.UTF8);
        shots++; Console.WriteLine("  saved: " + name);
    }

    static void ShotWindow(Window d, string name)
    {
        d.Width = 560; Settle(d); Save(d, name);
    }

    /// <summary>屏幕上的字：可见的文字与按钮，按位置自上而下、自左而右；按钮记成【按钮】，不可点的记成【按钮·灰】，勾选框记 ☐ / ☑</summary>
    static string ScreenText(Window w)
    {
        var items = new List<(double Y, double X, string Text)>();
        foreach (var c in w.GetVisualDescendants().OfType<Control>())
        {
            if (!c.IsEffectivelyVisible || c.Bounds.Width <= 0) continue;
            string? text = c switch
            {
                Button b when b is not RadioButton && b is not CheckBox && b.Content is string s => (b.IsEffectivelyEnabled ? "【" : "【灰·") + s + "】",
                TextBlock t when t.FindAncestorOfType<Button>() is { Content: string } => null,
                TextBlock t when t.FindAncestorOfType<TextBox>() is not null => null,
                TextBlock t => t.Text,
                TextBox tb => "［输入框：" + (tb.Text ?? "") + "］",
                ComboBox cb => "［下拉：" + (cb.SelectedItem is ComboBoxItem { Content: string ci } ? ci : cb.SelectedItem?.ToString() ?? "") + "］",
                _ => null,
            };
            if (c is RadioButton rb) text = (rb.IsChecked == true ? "◉ " : "○ ") + (rb.IsEffectivelyEnabled ? "" : "（灰）");
            if (c is CheckBox cbx) text = (cbx.IsChecked == true ? "☑ " : "☐ ") + (cbx.IsEffectivelyEnabled ? "" : "（灰）");
            if (string.IsNullOrWhiteSpace(text)) continue;
            var p = c.TranslatePoint(new Point(0, 0), w);
            if (p is null) continue;
            items.Add((Math.Round(p.Value.Y / 6) * 6, p.Value.X, text!.Replace("\n", " ⏎ ")));
        }
        var sb = new StringBuilder();
        foreach (var line in items.OrderBy(i => i.Y).ThenBy(i => i.X).GroupBy(i => i.Y))
            sb.AppendLine(string.Join("  ", line.Select(i => i.Text)));
        return sb.ToString();
    }

    static Window? OpenDialog(EnvironmentWindow w, string method)
    {
        Set(w, "page", "settings"); Call(w, "Render"); Settle(w);
        _ = (Task)w.GetType().GetMethod(method, F)!.Invoke(w, null)!;
        Settle(w);
        return w.OwnedWindows.LastOrDefault();
    }

    // ---- 反射小工具 ----
    static object BeginJob(EnvironmentWindow w, string kind, string? gameId) =>
        w.GetType().GetMethod("BeginJob", F)!.Invoke(w, [Enum.Parse(w.GetType().GetNestedType("JobKind", BindingFlags.NonPublic)!, kind), gameId])!;
    static void EndJob(EnvironmentWindow w, object job) => w.GetType().GetMethod("EndJob", F)!.Invoke(w, [job]);
    static JsonElement J(string s) => JsonDocument.Parse(s).RootElement.Clone();
    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }
    static void Call(object target, string method) => (target.GetType().GetMethod(method, F, null, Type.EmptyTypes, null) ?? throw new MissingMethodException(method)).Invoke(target, null);
    static object? Get(object obj, string field) => obj.GetType().GetField(field, F)?.GetValue(obj) ?? obj.GetType().GetProperty(field, F)?.GetValue(obj);
    static bool Has(object obj, string field) => obj.GetType().GetField(field, F) is not null;
    static void Set(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, F);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        var pi = obj.GetType().GetProperty(field, F | BindingFlags.Public);
        if (pi is { CanWrite: true }) { pi.SetValue(obj, value); return; }
        throw new MissingMemberException(field);
    }
}
