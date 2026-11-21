// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 首位 S2Arm 总控台在最小窗口宽度 / 英文下不被裁（0.6.2 前端走查）：一台没名字的手机（Windows 经 usbmuxd 读不到名字）、
//   6 款都「还没推 · 电脑上资源删了」（最长那句状态）、一款独立 App；选中首位行，按 760 / 1080 宽 × 中 / 英各出一张图。
//   期望手写：① 游戏同步行、独立 App 行的右边缘都不超出窗口；② 页顶不写 40 位编号，写「iPhone · 编号末 6 位」；
//   ③ 总览作业失败时首位 S2Arm 行和总控台不消失（保持上次的值）；④ 出法没读回（作业失败）时两张卡都不画选中。调用方核退出码 0 和末行「✓」
using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class ConsoleProbe
{
    const string Udid = "FIXTURE-PHONE-WITHOUT-A-NAME-XXXXXCDEF01";   // 夹具：40 位、不是真设备号（末 6 位 CDEF01）

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var fails = new List<string>();
        var names = new[] { "The Legend of Fixture: Breath of the Long Test Name", "Fixture Kart 8 Deluxe", "霍格沃茨之遗（测试夹具）",
                            "电视台的山乡神曲风情（测试夹具）", "Original Fixture 4", "Original Fixture 5" };
        var games = names.Select((n, i) => new LibraryGame($"01000000000{i}0000", n, "v1.0.0", "", false, [], true, null, true, [])).ToList();
        var overview = PhoneOverview.Parse(JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["phones"] = new[] { new Dictionary<string, object?> {
                ["device"] = Udid, ["name"] = "", ["installed"] = false, ["shellCurrent"] = false, ["online"] = Udid, ["signMode"] = "appleId",
                ["games"] = games.Select(g => new Dictionary<string, object?> { ["gameId"] = g.Id, ["state"] = "notPushed", ["dataOnComputer"] = false }).ToArray(),
                ["apps"] = new[] { new Dictionary<string, object?> { ["gameId"] = games[0].Id, ["bundleId"] = "io.s2arm.games.abcdefghij.0100000000000000",
                    ["shellCurrent"] = false, ["expiresAtEstimate"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 5 * 86400.0 } } } }
        })).RootElement)!;
        foreach (var lang in new[] { "zh-Hans", "en" })
            foreach (var width in new[] { 760, 1080 })
            {
                var w = new EnvironmentWindow { Width = width, Height = 900 };
                w.Show(); Settle(w);
                Set(w, "language", lang);
                Set(w, "catalog", new LibraryCatalog(games, true, "密钥已就绪"));
                Set(w, "connectedFolder", "/tmp/s2arm-library"); Set(w, "libraryId", "mock-lib-id"); Set(w, "librarySummary", "library.completed");
                Set(w, "phoneOverview", overview); Set(w, "selectedGame", "s2arm.console"); Set(w, "page", "library");
                Call(w, "Render"); Settle(w);
                var tag = $"{lang}-{width}";
                Save(w, Path.Combine(outDir, $"console-{tag}.png"));
                var rows = w.GetVisualDescendants().OfType<Control>()
                    .Where(c => Avalonia.Automation.AutomationProperties.GetAutomationId(c) is { } id && (id.StartsWith("console.game.") || id.StartsWith("console.app.0"))).ToList();
                if (rows.Count < games.Count + 1) fails.Add($"{tag}：找到的同步 / 独立 App 行只有 {rows.Count} 行");
                foreach (var r in rows)
                {
                    // 行里每个文字 / 按钮的右边缘（换算到窗口坐标）都不能超出窗口内容区
                    foreach (var c in r.GetVisualDescendants().OfType<Control>().Where(c => c is TextBlock or Button).Prepend(r))
                    {
                        var p = c.TranslatePoint(new Point(c.Bounds.Width, 0), w);
                        if (p is { } q && q.X > w.ClientSize.Width + 0.5)
                            fails.Add($"{tag}：{Avalonia.Automation.AutomationProperties.GetAutomationId(r)} 里 {c.GetType().Name}「{(c as TextBlock)?.Text}」右边缘 {q.X:F0} 超出窗口 {w.ClientSize.Width:F0}");
                    }
                }
                var texts = w.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text ?? "").ToList();
                if (texts.Any(t => t.Contains(Udid))) fails.Add($"{tag}：页面上写了 40 位编号");
                if (!texts.Any(t => t == "iPhone · " + Udid[^6..])) fails.Add($"{tag}：页顶没有「iPhone · {Udid[^6..]}」");
                // ④ 出法两张卡：installMode 还没读回 / 读失败（这里没有引擎，作业必失败）时两张都不画选中（选中那张边框 2，没选 1）；
                //   原先先把缺省「通用 S2Arm」画成选中，读失败就一直显示错的
                Set(w, "page", "settings"); Call(w, "Render"); Settle(w);
                foreach (var v in new[] { "shell", "standalone" })
                {
                    var card = w.GetVisualDescendants().OfType<Button>().FirstOrDefault(b => Avalonia.Automation.AutomationProperties.GetAutomationId(b) == "install.layout." + v);
                    if (card is null) fails.Add($"{tag}：设置页找不到出法卡 install.layout.{v}");
                    else if (card.BorderThickness.Left > 1.5) fails.Add($"{tag}：出法没读回却把「{v}」画成选中");
                }
                Save(w, Path.Combine(outDir, $"layout-{tag}.png"));
                w.Close();
            }
        Console.WriteLine(fails.Count == 0 ? "✓ 总控台窄窗 / 英文不裁、页顶不写长编号、出法没读回不先画错" : "✗ 总控台：\n  " + string.Join("\n  ", fails));
        return fails.Count == 0 ? 0 : 1;
    }

    static void Save(Window w, string path)
    {
        var bmp = w.CaptureRenderedFrame();
        if (bmp is null) { Console.WriteLine("  WARN no frame: " + path); return; }
        using var s = File.OpenWrite(path); bmp.Save(s); Console.WriteLine("  saved: " + Path.GetFileName(path));
    }
    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }
    static void Call(object target, string method) =>
        (target.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance, null, Type.EmptyTypes, null) ?? throw new MissingMethodException(method)).Invoke(target, null);
    static void Set(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        (obj.GetType().GetProperty(field, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public) ?? throw new MissingMemberException(field)).SetValue(obj, value);
    }
}
