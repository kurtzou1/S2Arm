// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 顶栏「故障报修」验收（11-13：任何页面同一位置都能报修）：全新窗口在各页 / 各引导状态下渲染，
// 每一页都要找得到 AutomationId top.report 的按钮，且它在顶栏右侧那一排的最后一个（同一位置）；每页存一张帧图。
// 任何一页找不到、位置不对、渲染抛异常都算不通；调用方核退出码 0 和末行「✓」。
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;

static class ReportProbe
{
    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        int fails = 0;
        var states = new (string Name, Action<EnvironmentWindow> Setup)[]
        {
            ("引导页（没连游戏库）", _ => { }),
            ("设置页", w => SetW(w, "page", "settings")),
            ("存储页", w => { SetW(w, "page", "storage"); SetW(w, "welcomeHome", false); }),
            ("游戏库页（连了库、空库）", w => { SetW(w, "connectedFolder", Path.Combine(outDir, "empty-library")); SetW(w, "libraryId", "probe-library"); SetW(w, "page", "library"); }),
            ("消息页", w => SetW(w, "messagesOpen", true)),
        };
        foreach (var (name, setup) in states)
        {
            Exception? error = null;
            DispatcherUnhandledExceptionEventHandler trap = (_, e) => { error ??= e.Exception; e.Handled = true; };
            Dispatcher.UIThread.UnhandledException += trap;
            var w = new EnvironmentWindow { Width = 1280, Height = 900 };
            try
            {
                w.Show(); Dispatcher.UIThread.RunJobs();
                setup(w); CallW(w, "Render"); Dispatcher.UIThread.RunJobs();
                var buttons = w.GetVisualDescendants().OfType<Button>().ToList();
                var report = buttons.FirstOrDefault(b => Avalonia.Automation.AutomationProperties.GetAutomationId(b) == "top.report")
                    ?? throw new InvalidOperationException("找不到顶栏故障报修键（top.report）");
                if (report.Parent is not StackPanel bar || bar.Children.LastOrDefault() != report)
                    throw new InvalidOperationException("故障报修键不在顶栏右侧那一排的最后一个");
                var bmp = w.CaptureRenderedFrame();
                if (bmp is not null) { using var s = File.OpenWrite(Path.Combine(outDir, "report_" + name + ".png")); bmp.Save(s); }
            }
            catch (Exception e) { error ??= e; }
            finally { Dispatcher.UIThread.UnhandledException -= trap; try { w.Close(); Dispatcher.UIThread.RunJobs(); } catch (Exception) { } }
            if (error is null) Console.WriteLine($"通 {name}：顶栏最右有故障报修键");
            else { fails++; Console.WriteLine($"不通 {name}：{error.GetType().Name}: {error.Message}"); }
        }
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} 各页顶栏故障报修键：{states.Length} 页，不通 {fails}");
        return fails == 0 ? 0 : 1;
    }

    static void SetW(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        var pi = obj.GetType().GetProperty(field, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public)
            ?? throw new MissingMemberException(field);
        pi.SetValue(obj, value);
    }

    static void CallW(object obj, string method) =>
        (obj.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMethodException(method)).Invoke(obj, null);
}
