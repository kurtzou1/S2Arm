// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// #2191 出包时只挡正在出的那一款（维护者 11-16：出包、装机这类互斥「纯属多余」，只在真有冲突时互斥）。无头窗口按真实右键菜单查，期望手写：
//   出包 A 时：B 的金手指 / mod / 删除 / 移动 / 上传诊断能点；A 自己的金手指 / mod / 删除 / 移动 / 清缓存不能点（出包读写 A 的这些文件、拿 A 的按款锁）；
//   清缓存对 B 也不能点（后端拿执行锁独占并清共用编译缓存，见 JobSlots.PackHoldsAll）；A 的上传诊断能点（只读日志）。
//   批量出包（作业登记不带游戏号）换到 B 时：只挡 B，A 放开。
// 调用方核退出码 0 和末行「✓」。
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Threading;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class PackMutexProbe
{
    const BindingFlags F = BindingFlags.NonPublic | BindingFlags.Instance;

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var fails = new List<string>();
        try
        {
            var lib = Path.Combine(outDir, "library");
            LibraryGame Game(string id, string name)
            {
                var folder = Path.Combine(lib, "games", name); Directory.CreateDirectory(folder);
                return new(id, name, "v1.0.0", "", false, [], Location: new GameLocation("ok", folder, folder, "C:", true));
            }
            var a = Game("0100F00E00000000", "packing-a");
            var b = Game("0100F00F00000000", "other-b");
            var w = new EnvironmentWindow { Width = 1180, Height = 900 };
            w.Show(); Settle(w);
            Set(w, "catalog", new LibraryCatalog([a, b], true, "密钥已就绪"));
            Set(w, "connectedFolder", lib); Set(w, "libraryId", "probe-lib"); Set(w, "librarySummary", "library.completed");
            Set(w, "updateHintsFor", "probe-lib");
            w.GetType().GetMethod("ResetPack", F)!.Invoke(w, [a]);   // 同出包页「开始出包」：登记 A 的出包作业（不起后端）
            Settle(w);
            var mb = Menu(w, b); var ma = Menu(w, a);
            foreach (var id in new[] { "cheats", "mods", "delete", "move", "diag" })
                Check(fails, $"出包 A 时 B 的「{id}」能点", mb.GetValueOrDefault(id) == true);
            foreach (var id in new[] { "cheats", "mods", "delete", "move", "clearCache", "export" })
                Check(fails, $"出包 A 时 A 自己的「{id}」不能点（会冲突）", ma.GetValueOrDefault(id) == false);
            Check(fails, "出包 A 时 B 的「clearCache」不能点（执行锁独占 + 共用编译缓存）", mb.GetValueOrDefault("clearCache") == false);
            Check(fails, "出包 A 时 A 的「diag」能点（只读日志）", ma.GetValueOrDefault("diag") == true);
            // 批量出包：作业登记不带游戏号，编排作业换到 B
            var packJob = Get(w, "packJob")!;
            w.GetType().GetMethod("EndJob", F)!.Invoke(w, [packJob]); Set(w, "packJob", null);
            var batchJob = w.GetType().GetMethod("BeginJob", F)!.Invoke(w, [Enum.Parse(w.GetType().GetNestedType("JobKind", BindingFlags.NonPublic)!, "Pack"), null])!;
            Set(w, "packJob", batchJob);
            w.GetType().GetMethod("ResetPackView", F)!.Invoke(w, [b]);
            Settle(w);
            Check(fails, "批量出包换到 B：B 的金手指不能点", Menu(w, b).GetValueOrDefault("cheats") == false);
            Check(fails, "批量出包换到 B：A 的金手指能点", Menu(w, a).GetValueOrDefault("cheats") == true);
            w.Close(); Settle(w);
        }
        catch (Exception e) { fails.Add($"探针自身出错：{e.GetType().Name}: {e.Message}\n{e.StackTrace}"); }
        foreach (var f in fails) Console.WriteLine("不通 " + f);
        Console.WriteLine($"{(fails.Count == 0 ? "✓" : "✗")} 出包只挡正在出的那款：不通 {fails.Count}");
        return fails.Count == 0 ? 0 : 1;
    }

    static Dictionary<string, bool> Menu(EnvironmentWindow w, LibraryGame g)
    {
        var menu = (ContextMenu)w.GetType().GetMethod("CardMenu", F)!.Invoke(w, [g])!;
        return menu.Items.OfType<MenuItem>().Select(i => (Id: Avalonia.Automation.AutomationProperties.GetAutomationId(i) ?? "", i.IsEnabled))
            .Where(x => x.Id.StartsWith("library.card.")).ToDictionary(x => x.Id["library.card.".Length..], x => x.IsEnabled);
    }
    static void Check(List<string> fails, string what, bool ok) { Console.WriteLine((ok ? "通 " : "不通 ") + what); if (!ok) fails.Add(what); }
    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }
    static object? Get(object obj, string field) => obj.GetType().GetField(field, F)?.GetValue(obj) ?? obj.GetType().GetProperty(field, F)?.GetValue(obj);
    static void Set(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, F);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        (obj.GetType().GetProperty(field, F | BindingFlags.Public) ?? throw new MissingMemberException(field)).SetValue(obj, value);
    }
}
