// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 引导页点设置键验收（玩家反馈：新手引导页右上角设置一点就闪退）：全新窗口（没连库、没密钥、没环境报告）在几种引导状态下
// 按真实点击路径触发顶栏设置键（AutomationId top.settings，RaiseEvent Click），跑完排队任务，任何异常（含界面线程上抛出的）都算不通；
// 栈溢出抓不住、进程直接退出（修前就是这样），所以调用方要核退出码 0 和末行「✓」。
using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;

static class SettingsProbe
{
    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        int fails = 0;
        var states = new (string Name, Action<EnvironmentWindow> Setup)[]
        {
            ("刚打开、还没连游戏库", _ => { }),   // 玩家反馈的闪退：读证书作业同步返回 null，渲染 → 读证书 → 渲染无限递归
            ("连了游戏库、读证书失败", w => { SetW(w, "connectedFolder", Path.Combine(outDir, "no-such-library")); SetW(w, "libraryId", "probe-library"); }),
        };
        foreach (var (name, setup) in states)
        {
            Exception? error = null;
            DispatcherUnhandledExceptionEventHandler trap = (_, e) => { error ??= e.Exception; e.Handled = true; };
            Dispatcher.UIThread.UnhandledException += trap;
            var w = new EnvironmentWindow { Width = 1280, Height = 900 };
            try
            {
                Console.WriteLine($"  [{name}] Show"); w.Show(); Dispatcher.UIThread.RunJobs();
                Console.WriteLine($"  [{name}] Render"); setup(w); CallW(w, "Render"); Dispatcher.UIThread.RunJobs();
                var button = w.GetVisualDescendants().OfType<Button>().FirstOrDefault(b => Avalonia.Automation.AutomationProperties.GetAutomationId(b) == "top.settings");
                if (button is null) throw new InvalidOperationException("找不到顶栏设置键（top.settings）");
                Console.WriteLine($"  [{name}] 点设置键"); button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Console.WriteLine($"  [{name}] 点完，跑排队任务");
                Dispatcher.UIThread.RunJobs();
                var page = GetW(w, "page") as string;
                if (page != "settings") throw new InvalidOperationException($"点了设置键没到设置页（page={page}）");
                var bmp = w.CaptureRenderedFrame();
                if (bmp is not null) { using var s = File.OpenWrite(Path.Combine(outDir, "settings_" + name + ".png")); bmp.Save(s); }
            }
            catch (Exception e) { error ??= e; }
            finally { Dispatcher.UIThread.UnhandledException -= trap; try { w.Close(); Dispatcher.UIThread.RunJobs(); } catch (Exception) { } }
            if (error is null) Console.WriteLine($"通 {name}：点设置键到了设置页、没有异常");
            else { fails++; Console.WriteLine($"不通 {name}：{error.GetType().Name}: {error.Message}\n{error.StackTrace}"); }
        }
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} 引导状态下点设置键：{states.Length} 种，不通 {fails}");
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

    static object? GetW(object obj, string field)
        => obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(obj);

    static void CallW(object target, string method)
        => (target.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new MissingMethodException(method)).Invoke(target, null);
}
