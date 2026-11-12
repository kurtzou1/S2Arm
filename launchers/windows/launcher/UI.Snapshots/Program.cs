// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Avalonia Headless snapshot runner: 欢迎页 + 出包页各状态 → PNG。
// 只用于截图验收，不进发布包。VisualTests 已并入本工程。
using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Headless;
using Avalonia.Skia;
using Avalonia.Themes.Fluent;
using Avalonia.Styling;
using Avalonia.Threading;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

// --scroll-probe <目录>：各页滚到中间后连续刷新，逐帧读控件屏幕坐标、存帧图（跳动验收，ScrollProbe.cs）
var scrollProbe = args.Length > 0 && args[0] == "--scroll-probe";
if (scrollProbe) args = args[1..];
// --flicker-probe <目录>：出包 / 装机在跑时按真实刷新路径刷 30 拍，量进度条被换次数、新建控件数、画面帧变化（闪烁验收，FlickerProbe.cs）
var flickerProbe = args.Length > 0 && args[0] == "--flicker-probe";
if (flickerProbe) args = args[1..];
var outDir = args.Length > 0 ? args[0] : Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
    ".s2arm/run/s2arm/cmdr/evidence/launcher/win");
Directory.CreateDirectory(outDir);

AppBuilder.Configure<SnapshotApp>()
    .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false })
    .With(new SkiaOptions())
    .UseSkia()
    .SetupWithoutStarting();
if (scrollProbe) { Environment.Exit(ScrollProbe.Run(outDir)); }
if (flickerProbe) { Environment.Exit(FlickerProbe.Run(outDir)); }

// ── 统一夹具游戏（不用固定游戏名字符串以外的占位）────────────────────
static LibraryGame MockGame(bool keysReady = true) => new(
    "0100B040192FA000", "Fire Emblem: Fortune's Weave", "v1.0.1",
    "", false, [], keysReady, keysReady ? DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 86400.0 : null,
    true, [new("base", "0100B040192FA000", 917504, "v1.0.1", 31_000_000_000L, "")]);

static LibraryCatalog MockCatalog(bool keysReady = true)
{
    var game = MockGame(keysReady);
    return new LibraryCatalog([game], keysReady, keysReady ? "密钥已就绪" : "");
}

// ── 单窗口复用：欢迎页场景 ──────────────────────────────────────────────
static EnvironmentReport FakeReport(bool ready) => EnvironmentReport.Parse(
    ready
    ? "{\"schema\":1,\"ready\":true,\"checks\":[{\"id\":\"host\",\"name\":\"Windows 64位\",\"status\":\"ok\",\"ok\":true,\"message\":\"就绪\",\"code\":null,\"action\":null}]}"
    : "{\"schema\":1,\"ready\":false,\"checks\":[{\"id\":\"python\",\"name\":\"Python\",\"status\":\"missing\",\"ok\":false,\"message\":\"需要 Python 3.11\",\"code\":\"python_missing\",\"action\":\"安装 Python\",\"url\":\"https://www.python.org\"}]}",
    ready ? 0 : 1);

var welcome = new EnvironmentWindow();
welcome.Width = 1280; welcome.Height = 900;
welcome.Show();
Dispatcher.UIThread.RunJobs();

void SaveW(string name, Action<EnvironmentWindow> setup)
{
    setup(welcome);
    SetW(welcome, "page", "library");
    CallW(welcome, "Render");
    Dispatcher.UIThread.RunJobs();
    var bmp = welcome.CaptureRenderedFrame();
    if (bmp is not null) { using var s = File.OpenWrite(Path.Combine(outDir, name + ".png")); bmp.Save(s); Console.WriteLine("  saved: " + name); }
    else Console.WriteLine("  WARN no frame: " + name);
}

SaveW("01_welcome_empty", w => { SetW(w, "report", null); SetW(w, "busy", false); SetW(w, "catalog", null); });
SaveW("02_welcome_env_checking", w => { SetW(w, "busy", true); SetW(w, "summaryKey", "environment.checking"); });
SaveW("03_welcome_env_ready_no_games", w => { SetW(w, "busy", false); SetW(w, "report", FakeReport(true)); SetW(w, "catalog", null); });
SaveW("04_welcome_games_chosen", w => {
    SetW(w, "report", FakeReport(true));
    SetW(w, "pendingImportPaths", new[] { "/tmp/fe_fortune.nsz" });
});
// 新电脑第一次打开：别的都就绪、只差 Metal 编译器（玩家要自己去 Apple 官网装）——欢迎页第 1 步的分步说明与「打开官方页面」
SaveW("04b_welcome_metal_missing", w => {
    SetW(w, "catalog", null);
    SetW(w, "report", EnvironmentReport.Parse(
        "{\"schema\":1,\"ready\":false,\"checks\":[{\"id\":\"host\",\"name\":\"Windows 64位\",\"status\":\"ok\",\"ok\":true,\"message\":\"就绪\",\"code\":null,\"action\":null,\"blocking\":true}," +
        "{\"id\":\"metal\",\"name\":\"官方Windows Metal编译器\",\"status\":\"missing\",\"ok\":false,\"message\":\"没装\",\"code\":\"metal_missing\",\"action\":\"install\",\"blocking\":true," +
        "\"url\":\"https://developer.apple.com/download/all/?q=metal%20developer%20tools%20for%20windows\"}]}", 1));
});
SaveW("05_welcome_oneclick", w => {
    SetW(w, "report", FakeReport(true));
    SetW(w, "welcomeGameId", MockGame().Id);
    SetW(w, "catalog", MockCatalog());
    SetW(w, "connectedFolder", "/tmp/s2arm-library");
    SetW(w, "libraryId", "mock-lib-id");
});
// 顶部公告条（v0.2.3）：内容取仓库里那份 docs/site/notice.json（启动器实际读的同一份），中 / 英各一张
var noticeDir = new DirectoryInfo(AppContext.BaseDirectory);
while (noticeDir is not null && !File.Exists(Path.Combine(noticeDir.FullName, "docs/site/notice.json"))) noticeDir = noticeDir.Parent;
var noticeJson = File.ReadAllText(Path.Combine(noticeDir?.FullName ?? throw new FileNotFoundException("docs/site/notice.json"), "docs/site/notice.json"));
SaveW("06_notice_zh", w => { SetW(w, "notice", (JsonElement?)JsonDocument.Parse(noticeJson).RootElement); SetW(w, "language", "zh-Hans"); });
SaveW("07_notice_en", w => { SetW(w, "language", "en"); });
SetW(welcome, "notice", null); SetW(welcome, "language", "zh-Hans");

welcome.Close();
Dispatcher.UIThread.RunJobs();

// ── 单窗口复用：出包页场景 ──────────────────────────────────────────────
var pack = new EnvironmentWindow();
pack.Width = 1280; pack.Height = 900;
pack.Show();
Dispatcher.UIThread.RunJobs();

void SaveP(string name, Action setup)
{
    setup();
    Dispatcher.UIThread.RunJobs();
    var bmp = pack.CaptureRenderedFrame();
    if (bmp is not null) { using var s = File.OpenWrite(Path.Combine(outDir, name + ".png")); bmp.Save(s); Console.WriteLine("  saved: " + name); }
    else Console.WriteLine("  WARN no frame: " + name);
}

InjectMockGame(pack, ready: false);
SaveP("win_01_export_select", () => Navigate(pack, "build"));

InjectMockProgress(pack, fraction: 0.05, stepIndex: 0, running: true);
SaveP("win_02_export_progress_running", () => Navigate(pack, "progress"));

InjectMockProgress(pack, fraction: 0.60, stepIndex: 1, running: true);
SaveP("win_03_export_progress_mid", () => Navigate(pack, "progress"));

InjectMockProgress(pack, fraction: 1.0, stepIndex: -1, running: false, state: "succeeded",
    ipaBytes: 1_200_000_000L, packBytes: 3_400_000_000L, elapsed: 247);
SaveP("win_04_export_success", () => Navigate(pack, "progress"));
// 降级继续（v0.3.1）：出成了，完成卡下方逐条列作业层给的玩家提示
SetW(pack, "packNotes", (object?)new List<string> { "这款有 27 处用了兼容写法，个别场景可能不稳定，遇到请反馈", "3 支着色器首次遇到时现编，开头可能稍卡" });
SaveP("win_04b_export_success_notes", () => Navigate(pack, "progress"));
SetW(pack, "packNotes", (object?)new List<string>());

InjectMockProgress(pack, fraction: 0.12, stepIndex: 0, running: false, state: "failed",
    summary: "磁盘空间不足，无法继续出包。");
SaveP("win_05_export_failed", () => Navigate(pack, "progress"));

InjectMockGame(pack, ready: true);
SaveP("win_06_library_iphone_ready", () => Navigate(pack, "library"));

InjectMockGame(pack, ready: false);
InjectMockProgress(pack, fraction: 0.35, stepIndex: 1, running: true);
SetW(pack, "sessionHidden", true);
SaveP("win_07_library_capsule", () => Navigate(pack, "library"));

// 「打开游戏文件夹」找不到文件夹：按钮下方说明原因，不打开空的资源管理器
InjectMockProgress(pack, fraction: 1.0, stepIndex: -1, running: false, state: "succeeded",
    ipaBytes: 1_200_000_000L, packBytes: 3_400_000_000L, elapsed: 247);
SetW(pack, "revealProblem", "找不到这款游戏的文件夹：所在的磁盘可能没接上，或文件夹被移走了。");
SaveP("win_08_export_success_folder_missing", () => Navigate(pack, "progress"));
SetW(pack, "revealProblem", "");

// 更新手机上的 S2Arm（v0.3.1 重做：进行中 / 成功 / 失败三态同一张结局卡，PhoneJobCard.cs；11-11 维护者「成功了也看不出成功」）
//   updateTrack 用作业层真实事件喂（调它的 Begin / Ingest），状态与结局事实按作业结果设
void PhoneTrackEvents(params string[] events)
{
    var track = GetW(pack, "updateTrack")!;
    track.GetType().GetMethod("Begin")!.Invoke(track, ["installUpdate", "iPhone「我的 iPhone」"]);
    foreach (var e in events) track.GetType().GetMethod("Ingest")!.Invoke(track, [JsonDocument.Parse(e).RootElement.Clone()]);
}
void TrackField(string field, object? value) { var track = GetW(pack, "updateTrack")!; track.GetType().GetField(field)!.SetValue(track, value); }
PhoneTrackEvents(
    """{"type":"stage","stage":"找签名账号与 iPhone","message":"找签名账号与 iPhone","stageIndex":1,"stageCount":6,"overall":0.0}""",
    """{"type":"stage","stage":"把这款放进手机上的 S2Arm","message":"把这款放进手机上的 S2Arm","stageIndex":2,"stageCount":6,"overall":0.17}""",
    """{"type":"stage","stage":"用你的 Apple ID 签名","message":"用你的 Apple ID 签名","stageIndex":4,"stageCount":6,"overall":0.5}""",
    """{"type":"stage","stage":"装到 iPhone","message":"装到 iPhone","stageIndex":5,"stageCount":6,"overall":0.62}""");
SetW(pack, "updateState", "running");
SaveP("win_20_phone_update_running", () => Navigate(pack, "phoneupdate"));
TrackField("Started", DateTime.UtcNow.AddSeconds(-47)); TrackField("Ended", (DateTime?)DateTime.UtcNow);
TrackField("PackBytes", (long?)0L); TrackField("PackFiles", (int?)0); TrackField("Version", "0.3.0");
SetW(pack, "updateState", "succeeded");
SaveP("win_21_phone_update_done", () => Navigate(pack, "phoneupdate"));
// 失败示例用真正做不下去的情况（签名失败）；认得出的风险走 drop 态让玩家确认，不当失败（维护者 11-11）
TrackField("Suggestion", "在 Impactor 里重新登录你的 Apple ID，再点一次。");
SetW(pack, "updateMessage", "签名没成功：Impactor 里的 Apple ID 登录已过期。");
SetW(pack, "updateState", "failed");
SaveP("win_22_phone_update_failed", () => Navigate(pack, "phoneupdate"));
SetW(pack, "updateMessage", "这次会让手机上的 1 款游戏暂时不能玩：示例游戏。它们不是在这台电脑上装的，存档和资源包都还在手机上，到原来那台电脑上再点一次「装到 iPhone」就能回来。");
SetW(pack, "updateState", "drop");
SaveP("win_23_phone_update_drop", () => Navigate(pack, "phoneupdate"));

// 封面兜底：游戏包没带图标时用商店横图（banner.jpg），在方形卡片里铺满裁切；没有横图才是 S2Arm 标志
var bannerSrc = Environment.GetEnvironmentVariable("S2A_SNAPSHOT_BANNER") ?? "";
if (File.Exists(bannerSrc))
{
    var folder = Path.Combine(Path.GetTempPath(), "s2a-snap-" + Guid.NewGuid().ToString("N"), "games", "Home Sheep Home");
    Directory.CreateDirectory(folder);
    File.Copy(bannerSrc, Path.Combine(folder, "banner.jpg"));
    var withBanner = MockGame(true) with { Id = "010076000F6B8000", Name = "送小羊回家: 农场末日", Cover = Path.Combine(folder, "banner.jpg"),
        Location = new GameLocation("ok", Path.GetDirectoryName(Path.GetDirectoryName(folder))!, folder, "", true) };
    var noCover = MockGame(true) with { Id = "010024B00F9D0000", Name = "泰拉瑞亚", Cover = "" };
    SetW(pack, "catalog", new LibraryCatalog([withBanner, noCover, MockGame(true)], true, "密钥已就绪"));
    SetW(pack, "connectedFolder", Path.GetDirectoryName(Path.GetDirectoryName(folder))!);
    SaveP("win_09_library_banner_fallback", () => Navigate(pack, "library"));
}

// 出包页「签名方式」（v0.2.3 开发者证书签名，DevCertPage.cs）：Apple ID 模式；证书模式（团队、到期、包名、设备核对、缺权限黄字）。
//   devCert 直接放作业结果（不跑 devCert 作业）；窗口加高，免得签名一栏落在首屏外
pack.Height = 1300;
InjectMockGame(pack, ready: true);
SetW(pack, "exportIos", true);
SetW(pack, "devCert", JsonDocument.Parse("{\"imported\":false,\"active\":false,\"cert\":null}").RootElement.Clone());
SaveP("win_10_export_sign_appleid", () => Navigate(pack, "build"));
SetW(pack, "devCert", JsonDocument.Parse("""
{"imported":true,"active":true,"cert":{"blocking":[],"warnings":[
 {"id":"devcert_entitlements","text":"描述文件没开「扩展寻址」权限：小游戏照常，大游戏可能内存不够闪退。可在开发者网站给这个 App ID 打开后重新下载描述文件。"},
 {"id":"devcert_expiring","text":"证书将于 2026-11-30 到期（还剩 20 天）：到期后 App 打不开，记得提前换新。"}],
 "teamName":"S2Arm Test Co","teamId":"ABCDE12345","certExpires":"2026-11-30","profileExpires":"2027-05-29",
 "bundleId":"io.s2arm.games.abcde12345","wildcard":true,"allDevices":false,"deviceCount":1,"deviceListed":null}}
""").RootElement.Clone());
SaveP("win_11_export_sign_devcert", () => Navigate(pack, "build"));

// 批量出包清单页（BatchPage.cs）：出包前（勾选、Mac 置灰、缺密钥、缺文件、认不出）；出完有成有败（磁盘满暂停、释放空间、重试、装到 iPhone、上次被打断）。
//   清单由 OpenBatch 按游戏库生成；出完的状态直接放 batch.py 形状的结果（不跑 batch.py）
pack.Height = 900;
static LibraryGame BatchMock(string id, string name, string format, IReadOnlyList<string>? missing = null) => MockGame(true) with
{
    Id = id, Name = name, Missing = missing ?? [], Packages = [new("base", id, 0, "v1.0.0", 4_000_000_000L, format)]
};
SetW(pack, "catalog", new LibraryCatalog([
    BatchMock("0100AAAA00000000", "星海远征", "extract"), BatchMock("0100BBBB00000000", "Pixel Garden", "extract"),
    BatchMock("0100CCCC00000000", "雪原小镇", "nsp"), BatchMock("0100DDDD00000000", "Clockwork Isles", "extract", ["本体"]),
    BatchMock("0100EEEE00000000", "Harbor Lights", "extract")], false, ""));
SetW(pack, "connectedFolder", "/tmp/s2arm-library");
SetW(pack, "libraryId", "mock-lib-id");
SetW(pack, "batchState", null);
CallW(pack, "OpenBatch", new List<string> { "0100AAAA00000000", "0100BBBB00000000", "0100CCCC00000000", "0100DDDD00000000", "0100EEEE00000000" },
    new List<ImportOutcome.Unrecognized> { new("readme.txt", "不是 NSP、XCI 或解包好的游戏文件夹。", "input_type_unsupported") });
SaveP("win_12_batch_draft", () => { });
SetW(pack, "batchState", BatchClient.Read(JsonDocument.Parse("""
{"batch":{"schema":1,"location":null,"paused":"disk_full","items":[
 {"gameId":"0100AAAA00000000","name":"星海远征","platforms":["iphone"],"results":{"iphone":{"state":"completed","output":"/tmp/a.ipa"}}},
 {"gameId":"0100BBBB00000000","name":"Pixel Garden","platforms":["iphone"],"results":{"iphone":{"state":"failed","message":"游戏文件读不出来，可能已损坏。","code":"content_unreadable"}}},
 {"gameId":"0100EEEE00000000","name":"Harbor Lights","platforms":["iphone"],"results":{"iphone":{"state":"failed","message":"磁盘空间不足，无法继续出包。","code":"disk_full"}}},
 {"gameId":"0100CCCC00000000","name":"雪原小镇","platforms":["iphone"],"results":{"iphone":{"state":"pending","interrupted":true}}}]},
 "next":null,"summary":{"total":4,"completed":1,"failed":2,"cancelled":0,"pending":1,"done":false}}
""").RootElement.Clone()).State);
SaveP("win_13_batch_done_mixed", () => Navigate(pack, "batch"));

// 入口整理对照：已连库的游戏库页（一款在默认位置、一款在外接盘，后者卡片写「存放在 …」）、设置页（库根有 S2Arm.ipa），窗口拉高看全
SetW(pack, "batchState", null);
pack.Height = 1500;
var tidyLib = Path.Combine(Path.GetTempPath(), "s2a-snap-" + Guid.NewGuid().ToString("N"), "S2Arm");
Directory.CreateDirectory(tidyLib);
File.WriteAllBytes(Path.Combine(tidyLib, "S2Arm.ipa"), []);
var atDefault = MockGame(true) with { Location = new GameLocation("ok", tidyLib, Path.Combine(tidyLib, "games", "Fortune's Weave"), "", true) };
var elsewhere = MockGame(true) with { Id = "010024B00F9D0000", Name = "泰拉瑞亚", IphoneInstalledAt = null,
    Location = new GameLocation("ok", "D:\\S2Arm Games", "D:\\S2Arm Games\\games\\Terraria", "移动硬盘 (D:)", false) };
SetW(pack, "catalog", new LibraryCatalog([atDefault, elsewhere], true, "密钥已就绪"));
SetW(pack, "selectedGame", null);
SetW(pack, "connectedFolder", tidyLib);
SetW(pack, "libraryFolder", tidyLib);
SetW(pack, "libraryId", "mock-lib-id");
SetW(pack, "librarySummary", "library.completed");
SetW(pack, "libraryDiagnostics", "");
SetW(pack, "report", FakeReport(true));
SetW(pack, "summaryKey", "environment.ready");
SaveP("tidy_01_library_connected", () => Navigate(pack, "library"));
// 游戏库选到 exFAT 盘（setup 报 library_bad_format，v0.3.1）：原因下面列出能放游戏库的 NTFS / ReFS 盘和剩余空间，点「放到这里」就建
SetW(pack, "catalog", null); SetW(pack, "connectedFolder", null); SetW(pack, "libraryId", null);
SetW(pack, "librarySummary", "library.failed");
SetW(pack, "libraryDiagnostics", "这个盘是 EXFAT，可以用，但按现有 2 款游戏算，出包会多占约 61 GB；放在 NTFS 格式的盘上更省空间。");
SetW(pack, "libraryFailCode", "library_bad_format"); SetW(pack, "libraryFailFolder", "E:\\S2Arm Library");
SetW(pack, "drivesOverride", (object?)new List<(string Root, string Format, long Free)> { ("C:\\", "NTFS", 212_000_000_000L), ("D:\\", "NTFS", 1_480_000_000_000L) }.OrderByDescending(d => d.Free).ToList());
SetW(pack, "importDialog", new ImportDialogState(ImportKind.Games));   // 连不上库时游戏库页是欢迎页，原因显示在「添加游戏」弹窗里
SetW(pack, "importError", "游戏库没连上（E:\\S2Arm Library）：这个盘是 EXFAT，可以用，但按现有 2 款游戏算，出包会多占约 61 GB；放在 NTFS 格式的盘上更省空间。");
SaveP("win_24_library_bad_format_drives", () => Navigate(pack, "library"));
SetW(pack, "importDialog", null); SetW(pack, "importError", "");
SetW(pack, "libraryFailCode", null); SetW(pack, "drivesOverride", null);
SetW(pack, "catalog", new LibraryCatalog([atDefault, elsewhere], true, "密钥已就绪")); SetW(pack, "connectedFolder", tidyLib); SetW(pack, "libraryId", "mock-lib-id");
SetW(pack, "librarySummary", "library.completed"); SetW(pack, "libraryDiagnostics", "");
pack.Height = 2100;   // 设置页最长：装机方式 + 环境检查 + 运行路径都要在一张图里
SaveP("tidy_02_settings", () => Navigate(pack, "settings"));
pack.Height = 900;

pack.Close();
Dispatcher.UIThread.RunJobs();
Console.WriteLine("done.");

// ── 辅助函数 ─────────────────────────────────────────────────────────────
static void SetW(object obj, string field, object? value)
{
    var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance);
    if (fi is not null) { fi.SetValue(obj, value); return; }
    var pi = obj.GetType().GetProperty(field, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public);
    // 只读属性（如 busy：剃刀锁一族后改为按作业登记算出）设不了：跳过并提示，别让后面的场景全截不出来
    if (pi is not null) { if (pi.CanWrite) pi.SetValue(obj, value); else Console.Error.WriteLine($"跳过只读属性 {field}（场景里这一项按实际状态显示）"); return; }
    throw new MissingMemberException($"Field/property not found: {field}");
}

static object? GetW(object obj, string field)
    => obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(obj);

static void CallW(object target, string method, params object?[] methodArgs)
{
    var m = target.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance)
        ?? throw new InvalidOperationException("missing method " + method);
    m.Invoke(target, methodArgs);
}

static void Navigate(EnvironmentWindow w, string pg)
    => w.GetType().GetMethod("Navigate", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(w, [pg]);

static void InjectMockGame(EnvironmentWindow w, bool ready)
{
    var game = MockGame(ready);
    var catalog = MockCatalog(ready);
    SetW(w, "catalog", catalog);
    SetW(w, "selectedGame", game.Id);
    SetW(w, "connectedFolder", "/tmp/s2arm-library");
    SetW(w, "libraryId", "mock-lib-id");
    SetW(w, "librarySummary", "library.completed");
    if (!ready) return;
    var finishedPacks = (Dictionary<string, (string state, string ipa, long? ipaBytes, long? packBytes, double seconds)>)
        GetW(w, "finishedPacks")!;
    finishedPacks[game.Id] = ("succeeded", "/tmp/game.ipa", 1_200_000_000L, 3_400_000_000L, 247);
}

static void InjectMockProgress(EnvironmentWindow w, double fraction, int stepIndex, bool running,
    string state = "running", string? summary = null, long? ipaBytes = null, long? packBytes = null,
    double elapsed = 0)
{
    var game = MockGame(false);
    SetW(w, "packGame", game);
    SetW(w, "packState", state);
    SetW(w, "packRunning", running);
    SetW(w, "packStarted", elapsed > 0 ? DateTime.UtcNow.AddSeconds(-elapsed) : DateTime.UtcNow.AddSeconds(-30));
    if (!running && elapsed > 0) SetW(w, "packSeconds", (object?)elapsed);
    if (summary is not null) SetW(w, "packSummary", summary);
    if (ipaBytes is not null) SetW(w, "packIpaBytes", (object?)ipaBytes);
    if (packBytes is not null) SetW(w, "packPackBytes", (object?)packBytes);
    if (ipaBytes is not null) SetW(w, "packIpa", "/tmp/game.ipa");

    var track = new MilestoneTrack();
    var planJson = """
[{"id":"unpack","label":"解包","purpose":"读出游戏程序和资源，合并更新与 DLC。","expected":120,"source":"history","samples":3,"reuse":false},
 {"id":"prepare","label":"准备资源","purpose":"整理 DLC 和宽屏界面布局，同时在后台把游戏代码改写成苹果设备能直接运行的形式。","expected":80,"source":"history","samples":3,"reuse":false},
 {"id":"ipa","label":"编 App 与签名","purpose":"编出 iPhone / iPad 版程序、签名，并打好要推进手机的资源包。","expected":40,"source":"history","samples":3,"reuse":false}]
""";
    var planEvent = JsonDocument.Parse($$"""{"type":"plan","milestone":null,"milestones":{{planJson}}}""");
    track.Ingest(planEvent.RootElement, 0);
    // 用真实 Clock 基准注入步骤开始时间，避免 StepElapsed 溢出
    double realClock = DateTime.UtcNow.Subtract(DateTime.UnixEpoch).TotalSeconds;
    if (stepIndex >= 0)
    {
        var ids = new[] { "unpack", "prepare", "ipa" };
        var milestoneEvent = JsonDocument.Parse($$"""{"type":"stage","milestone":"{{ids[stepIndex]}}","message":""}""");
        track.Ingest(milestoneEvent.RootElement, realClock - 30);
    }
    if (!running && state == "succeeded") track.Finish(elapsed > 0 ? elapsed : 30);
    SetW(w, "packTrack", track);

    var spaceJson = """{"volumes":[{"role":"library","needBytes":79890000000,"freeBytes":153420000000,"basis":"rule","enough":true}]}""";
    using var spaceDoc = JsonDocument.Parse(spaceJson);
    SetW(w, "packSpace", PackSpace.TryParse(spaceDoc.RootElement));
}

public sealed class SnapshotApp : Application
{
    public override void Initialize()
    {
        RequestedThemeVariant = ThemeVariant.Dark;
        Styles.Add(new FluentTheme());
    }
}
