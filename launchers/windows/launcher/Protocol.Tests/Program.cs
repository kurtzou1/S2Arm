// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

var assertions = 0;
void Check(bool condition, string label)
{
    assertions++;
    if (!condition) throw new Exception(label);
}
void Reject(string json, int exitCode, string label)
{
    try { EnvironmentReport.Parse(json, exitCode); }
    catch (EnvironmentProtocolException) { assertions++; return; }
    throw new Exception("accepted " + label);
}

// Handwritten observations; expected states come from WINDOWS_ENV.md, not the parser.
const string sample = """
{"schema":1,"ready":false,"checks":[
 {"id":"host","name":"Windows","status":"ok","ok":true,"message":"64 bit","source":"host","requiredFor":["prepare","ipa"],"group":"system","code":null,"action":null,"help":"64 bit","detected":null},
 {"id":"metal","name":"Metal","status":"missing","ok":false,"message":"not found","source":"tools","requiredFor":["prepare","ipa"],"group":"system","code":"win_metal_missing","action":"Install official tools, then check again.","help":"not found","detected":null},
 {"id":"disk","name":"Disk","status":"error","ok":false,"message":"probe failed","source":"disk","requiredFor":["prepare","ipa"],"group":"system","code":"win_check_failed","action":"Check permissions.","help":"probe failed","detected":null}
]}
""";
var report = EnvironmentReport.Parse(sample, 1);
Check(!report.Ready && report.Checks.Count == 3, "three observations, not ready");
Check(report.Checks[0].Status == "ok" && !report.Checks[0].HasAction, "ok has no action");
Check(report.Checks[1].Status == "missing" && report.Checks[1].HasAction, "missing has action");
Check(report.Checks[2].Status == "error" && report.Checks[2].Code == "win_check_failed", "error preserved");
Check(report.Checks[1].Action == "Install official tools, then check again.", "backend action preserved as text");
var linked = EnvironmentReport.Parse(sample.Replace("\"id\":\"metal\"",
    "\"url\":\"https://developer.apple.com/metal/tools/\",\"id\":\"metal\""), 1);
Check(linked.Checks[1].OfficialUrl is Uri official &&
    official.AbsoluteUri == "https://developer.apple.com/metal/tools/", "backend official URL retained separately from recovery text");
foreach (var url in new[] { "file:///C:/Windows/notepad.exe", "javascript:alert(1)",
                           "https://user:password@example.com/", "relative/path", "http://example.com/" })
    Check(EnvironmentReport.Parse(sample.Replace("\"id\":\"metal\"", $"\"url\":\"{url}\",\"id\":\"metal\""), 1) is var u &&
          u.Checks[1].OfficialUrl is null && u.Checks.Count == 3, "unsafe official URL dropped for that check only (razor W6)");
foreach (var status in new[] { "mismatch", "unverified", "user-selected" })
{
    var changed = EnvironmentReport.Parse(sample.Replace("\"missing\"", $"\"{status}\""), 1);
    Check(changed.Checks[1].Status == status && !changed.Ready, "preserve " + status);
}
const string ready = """
{"schema":1,"ready":true,"checks":[{"id":"host","name":"Windows","status":"ok","ok":true,"message":"ok","source":"host","requiredFor":["prepare","ipa"],"group":"system","code":null,"action":null,"help":"ok","detected":null}]}
""";
Check(EnvironmentReport.Parse(ready.Replace("\"id\":\"host\"", "\"url\":\"https://example.com/\",\"id\":\"host\""), 0).Ready,
    "a link on an ok check is the backend's call (razor W6)");
Check(report.Checks[0].OfficialUrl is null && report.Checks[2].OfficialUrl is null,
    "checks without official destinations have no link");
Check(EnvironmentReport.Parse(sample.Replace("\"id\":\"metal\"", "\"url\":42,\"id\":\"metal\""), 1).Checks[1].OfficialUrl is null, "non textual official URL dropped");
Check(EnvironmentReport.Parse(ready, 0).Ready, "successful ready report");
foreach (var code in new[] { "invalid_request", "winenv_recovery_contract" })
{
    var errorJson = """
    {"schema":1,"ready":false,"checks":[],"error":{"code":"CODE","message":"request rejected"}}
    """.Replace("CODE", code);
    var error = EnvironmentReport.Parse(errorJson, 2);
    Check(error.Error?.Code == code && !error.Ready && error.Checks.Count == 0, "preserve request error " + code);
    Check(EnvironmentReport.Parse(errorJson, 1).Error?.Code == code, "request error kept whatever the exit code (razor W6)");
}
Reject("", 0, "empty output");
Reject("not json", 1, "non JSON output");
Reject("[]", 1, "array root");
Reject(sample.Replace("\"schema\":1", "\"schema\":2"), 1, "unknown schema");
Reject(sample.Replace("\"schema\":1", "\"schema\":true"), 1, "boolean schema");
Reject(sample.Replace("\"ready\":false,", ""), 1, "missing ready");
Check(EnvironmentReport.Parse(sample.Replace("\"ready\":false", "\"ready\":true"), 0).Ready,
    "backend owns readiness; deferred checks must not be reclassified by client");
// 剃刀 W6：前端不再替后端核对报告——退出码、状态名、ok 与状态、id 重复、缺恢复码都按后端给的原样保留（期望按规则手写）
Check(EnvironmentReport.Parse(ready, 1).Ready && !EnvironmentReport.Parse(sample, 0).Ready && EnvironmentReport.Parse(sample, 75).Checks.Count == 3,
    "readiness is the backend's field, not inferred from the exit code");
Check(EnvironmentReport.Parse(sample.Replace("\"missing\"", "\"pending\""), 1).Checks[1] is { Status: "pending", Blocking: true },
    "a status the client does not know is kept and, without a blocking field, treated as not ok");
Check(EnvironmentReport.Parse(sample.Replace("\"status\":\"missing\",\"ok\":false", "\"status\":\"missing\",\"ok\":true"), 1).Checks.Count == 3, "ok / status disagreement is not the client's to judge");
Check(EnvironmentReport.Parse(sample.Replace("\"id\":\"metal\"", "\"id\":\"host\""), 1).Checks.Count == 3, "duplicate check id kept");
Reject(sample.Replace("\"schema\":1", "\"schema\":1,\"schema\":1"), 1, "duplicate root field");
Reject(sample.Replace("\"status\":\"missing\"", "\"status\":\"ok\",\"status\":\"missing\""), 1, "duplicate observation field");
Reject(sample.Replace("\"action\":\"Check permissions.\"", "\"action\":42"), 1, "non textual action");
Check(EnvironmentReport.Parse(sample.Replace("\"code\":\"win_metal_missing\"", "\"code\":null"), 1).Checks[1].Code is null, "missing failure code kept as none");
Check(EnvironmentReport.Parse("""{"schema":1,"ready":false,"checks":[]}""", 1) is { Ready: false, Checks.Count: 0 }, "empty regular report parsed as given");
Check(EnvironmentReport.Parse(sample.Replace("\"schema\":1", "\"future\":{},\"schema\":1"), 1).Checks.Count == 3, "additive fields tolerated");
var shared = new SharedText("""
{"schema":1,"contract":"s2a.experience.v1","launcher":{"note":"official items contract","items":[{"id":"action.check","zh-Hans":"检查","en":"Check"}]},"errors":{"items":[]}}
""");
Check(shared.Get("action.check", "zh-Hans") == "检查", "shared Chinese text");
Check(shared.Get("action.check", "en") == "Check", "shared English text");
Check(shared.Get("absent", "en") == "[absent]", "missing key is placeholder, not copied text");
// 11-19 结构 9：确认码表、原因表只在共享体验表一处，Windows 经 SharedText 读（原先各写一份：Windows 缺 libGen、两端缺 shaderMiss）
{
    var dir = new DirectoryInfo(AppContext.BaseDirectory);
    while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "launchers", "shared", "experience.v1.json"))) dir = dir.Parent;
    var real = new SharedText(File.ReadAllText(Path.Combine(dir!.FullName, "launchers", "shared", "experience.v1.json")));
    Check(real.ConfirmFlags.TryGetValue("cert_revoke_confirm", out var crf) && crf == "acceptCertRevoke", "shared tables: cert_revoke_confirm carries acceptCertRevoke");
    Check(real.ConfirmAlternates.TryGetValue("cert_revoke_confirm", out var cra) && cra.Action == "devCertSettings" && cra.Label == "confirm.alternate.useExistingCert"
        && real.InstallActionLabel("devCertSettings") is not null && real.Has("confirm.alternate.useExistingCert") && !real.ConfirmAlternates.ContainsKey("save_backup_failed"),
        "shared tables: cert_revoke_confirm offers 'use an existing certificate' (devCertSettings, no resend)");
    Check(real.ConfirmFlags.TryGetValue("library_in_cloud", out var lic) && lic == "acceptCloud" && !real.ConfirmFlags.ContainsKey("library_bad_format"),
        "shared tables: library confirms come from the same table; accept_ui codes (drive picker) stay out of the generic confirm");
    Check(real.UpdateReasonKey("libGen") == "update.hint.reason.shader" && real.UpdateReasonKey("shaderMiss") == "update.hint.reason.shader" && real.UpdateReasonKey("other") is null,
        "shared tables: libGen / shaderMiss have a reason text, unknown reasons show nothing");
}
var languageKeys = new SharedText("""
{"schema":1,"contract":"s2a.experience.v1","launcher":{"items":[{"id":"language.zh-Hans","zh-Hans":"简体中文","en":"Simplified Chinese"},{"id":"language.en","zh-Hans":"英文","en":"English"}]},"errors":{"items":[]}}
""");
Check(languageKeys.Get("language.en", "en") == "English", "language id is not mistaken for a translated leaf");
var extraLanguage = new SharedText("""
{"schema":1,"contract":"s2a.experience.v1","launcher":{"items":[{"id":"action.check","zh-Hans":"检查","en":"Check","ja":"確認"}]},"errors":{"items":[]}}
""");
Check(extraLanguage.Get("action.check", "ja") == "確認", "a language column beyond zh-Hans / en is read");
Check(extraLanguage.Get("action.check", "fr") == "Check", "a language without this key's translation falls back to English");
var overlaid = new SharedText("""
{"schema":1,"contract":"s2a.experience.v1","launcher":{"items":[{"id":"a","zh-Hans":"检查","en":"Check"},{"id":"b","zh-Hans":"出包","en":"Export"}]},"errors":{"items":[]}}
""");
overlaid.AddOverlay("zh-Hant", """{"launcher":{"a":"檢查"}}"""); overlaid.AddOverlay("ja", """{"launcher":{"a":"確認"}}""");
Check(overlaid.Get("a", "zh-Hant") == "檢查" && overlaid.Get("a", "ja") == "確認", "overlay text wins for its language");
Check(overlaid.Get("b", "zh-Hant") == "出包" && overlaid.Get("b", "ja") == "Export", "missing overlay key: zh-Hant falls back to Simplified Chinese, others to English");
var backendOverlay = new BackendText("""[{"source":"游戏已停止。","en":"Game stopped."},{"source":"还剩 {0} 款","en":"{0} left"}]""", """{"schema":1}""");
backendOverlay.AddOverlay("zh-Hant", """{"text":{"游戏已停止。":"遊戲已停止。"}}"""); backendOverlay.AddOverlay("ja", """{"text":{"还剩 {0} 款":"残り {0} 本"}}""");
Check(backendOverlay.Translate("游戏已停止。", "zh-Hant") == "遊戲已停止。" && backendOverlay.Translate("还剩 3 款", "ja") == "残り 3 本", "backend overlay: whole sentence and pattern");
Check(backendOverlay.Translate("还剩 3 款", "zh-Hant") == "还剩 3 款" && backendOverlay.Translate("游戏已停止。", "ja") == "Game stopped.", "backend overlay fallback: zh-Hant keeps the source, ja falls back to English");
Check(backendOverlay.Translate("游戏已停止。", "zh-Hans") == "游戏已停止。" && backendOverlay.Translate("游戏已停止。", "en") == "Game stopped.", "backend: zh-Hans source and English unchanged");
void RejectResource(string items, string label)
{
    var json = "{\"schema\":1,\"contract\":\"s2a.experience.v1\",\"launcher\":{\"items\":" + items + "},\"errors\":{\"items\":[]}}";
    try { _ = new SharedText(json); }
    catch (FormatException) { assertions++; return; }
    throw new Exception("accepted resource " + label);
}
RejectResource("""[{"id":"action.check","zh-Hans":"检查","en":"Check"},{"id":"action.check","zh-Hans":"再次","en":"Again"}]""", "duplicate id");
RejectResource("""[{"id":"action.check","zh-Hans":"检查"}]""", "missing English");
RejectResource("""[{"id":"action.check","zh-Hans":" ","en":"Check"}]""", "empty Chinese");
RejectResource("""[{"id":"","zh-Hans":"检查","en":"Check"}]""", "empty id");
RejectResource("{}", "non-array items");
var advisory = EnvironmentReport.Parse("""
{"schema":1,"ready":true,"checks":[
 {"id":"impactor","name":"Impactor","status":"missing","ok":false,"blocking":false,"message":"not found","source":"s","requiredFor":["install"],"group":"system","code":"impactor_missing","action":"get it"}
]}
""", 0);
Check(advisory.Ready && !advisory.Checks[0].Blocking, "signing tool is advisory and does not block");
Check(report.Checks[1].Blocking, "reports without the field still block on anything not ok");
// D-97FT：设置页输入框还没画出来（Text 为 null）或被清空时，空值不覆盖原路径；原先抄成空串，环境检查 GetFullPath("") 抛异常、界面停在「正在检查」。期望手写
var defaults = LauncherPaths.Defaults(Path.Combine(Path.GetTempPath(), "s2arm-paths"));
Check(defaults.Edited(null, null, null) == defaults, "blank settings boxes keep the existing launcher paths");
Check(defaults.Edited("", "  ", null) == defaults, "empty or whitespace settings never become empty paths");
var edited = defaults.Edited("D:\\E", null, "D:\\S");
Check(edited == new LauncherPaths("D:\\E", defaults.Runtime, "D:\\S"), "filled settings boxes replace only their own path");
Check(!string.IsNullOrEmpty(Path.GetFullPath(defaults.Edited("", "", "").Engine)), "edited paths stay usable by the environment check");
LibraryJobCases.Run(Check);
PhoneOverviewCases.Run(Check);
ExportChoiceCases.Run(Check);
LibraryFolderCases.Run(Check);
MetalFolderCases.Run(Check);
JsonOutCases.Run(Check);
LauncherLanguageCases.Run(Check);
SGradeVersionsCases.Run(Check);
PackCases.Run(Check);
UpdateRepackCases.Run(Check);
BatchCases.Run(Check);
ExportStreamCases.Run(Check);
BackendTextCases.Run(Check);
await WindowsLibraryCases.Run(Check);
await WindowsProbeCases.Run(Check);
await ControlPortCases.Run(Check);
await UpdateClientCases.Run(Check);
Console.WriteLine($"Launcher protocol: {assertions} assertions passed");
