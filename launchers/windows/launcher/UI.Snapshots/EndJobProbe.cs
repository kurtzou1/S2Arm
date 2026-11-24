// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 出包作业收尾必须先撤作业登记（JobSlots.cs EndJob 的约定「收尾第一件事就调」）：出包客户端抛出 RunExportAsync catch 列表之外的异常时，
//   原先收尾回调先读 job!.Report（job 为空）就空引用，EndJob 跳过，作业登记永远留着，所有游戏右键里的出包 / 金手指 / 删除一直灰到重开启动器。
// 无头窗口按真实页面跑，期望手写：出包计划里放一个 JsonOut 写不了的值（键不是字符串的字典 → NotSupportedException，不在 catch 列表里），
//   起单款出包；跑完后作业登记清空、这款不再忙、右键「金手指」可点、出包页显示失败而不是一直在出。
// 调用方核退出码 0 和末行「✓」。
using System.Collections;
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Threading;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class EndJobProbe
{
    const BindingFlags F = BindingFlags.NonPublic | BindingFlags.Instance;

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var fails = new List<string>();
        Exception? uiError = null;
        DispatcherUnhandledExceptionEventHandler trap = (_, e) => { uiError ??= e.Exception; e.Handled = true; };
        Dispatcher.UIThread.UnhandledException += trap;
        try
        {
            var lib = Path.Combine(outDir, "library"); Directory.CreateDirectory(lib);
            var folder = Path.Combine(lib, "games", "probe"); Directory.CreateDirectory(folder);
            var game = new LibraryGame("0100F00D00000000", "probe", "v1.0.0", "", false, [], Location: new GameLocation("ok", folder, folder, "C:", true));
            var w = new EnvironmentWindow { Width = 1180, Height = 900 };
            w.Show(); Settle(w);
            Set(w, "catalog", new LibraryCatalog([game], true, "密钥已就绪"));
            Set(w, "connectedFolder", lib); Set(w, "libraryId", "probe-lib"); Set(w, "librarySummary", "library.completed");
            Set(w, "updateHintsFor", "probe-lib");
            w.GetType().GetMethod("ResetPack", F)!.Invoke(w, [game]);   // 同出包页「开始出包」：登记出包作业
            Check(fails, "起出包后这款在忙（前提）", Busy(w, game));
            var plan = new Dictionary<string, object?> { ["items"] = new Hashtable { [1] = "键不是字符串" } };   // JsonOut 抛 NotSupportedException
            var task = (Task)w.GetType().GetMethod("RunExportAsync", F)!.Invoke(w, [plan, false, null])!;
            var until = DateTime.UtcNow.AddSeconds(20);
            while (!task.IsCompleted && DateTime.UtcNow < until) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(20); }
            Settle(w);
            var inner = task.Exception?.InnerException;
            Check(fails, $"出包客户端抛的是 catch 列表之外的异常（{inner?.GetType().Name}）", inner is NotSupportedException);
            var jobs = (IList)Get(w, "jobs")!;
            Check(fails, $"收尾后作业登记清空（剩 {jobs.Count} 条）", jobs.Count == 0);
            Check(fails, "收尾后这款不再忙", !Busy(w, game));
            Check(fails, $"出包页显示失败（{Get(w, "packState")}）", (string?)Get(w, "packState") == "failed");
            Check(fails, $"收尾回调没有抛异常（{uiError?.GetType().Name}: {uiError?.Message}{uiError?.StackTrace?.Split('\n').FirstOrDefault()}）", uiError is null);
            var menu = (ContextMenu)w.GetType().GetMethod("CardMenu", F)!.Invoke(w, [game])!;
            var cheats = menu.Items.OfType<MenuItem>().FirstOrDefault(i => Avalonia.Automation.AutomationProperties.GetAutomationId(i) == "library.card.cheats");
            Check(fails, $"右键「金手指」可点（{cheats?.IsEnabled}）", cheats?.IsEnabled == true);
            w.Close(); Settle(w);
        }
        catch (Exception e) { fails.Add($"探针自身出错：{e.GetType().Name}: {e.Message}\n{e.StackTrace}"); }
        finally { Dispatcher.UIThread.UnhandledException -= trap; }
        foreach (var f in fails) Console.WriteLine("不通 " + f);
        Console.WriteLine($"{(fails.Count == 0 ? "✓" : "✗")} 出包异常收尾撤登记：不通 {fails.Count}");
        return fails.Count == 0 ? 0 : 1;
    }

    static bool Busy(EnvironmentWindow w, LibraryGame g) => (bool)w.GetType().GetMethod("BusyFor", F)!.Invoke(w, [g])!;
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
