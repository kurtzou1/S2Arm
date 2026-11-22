// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 推游戏遇到手机上旧 App（#1842，作业层 install.external_app_outdated）：失败码 phone_app_outdated 带 accept（experience.v1.json），
//   界面按通用确认走——弹「仍然继续 / 取消」，点了带 acceptOldApp 重推。经真实入口 ConfirmInstallActionAsync（InstallAsync 问确认就调它）弹窗、截图。
//   期望手写：① phone_app_outdated 认作要确认的码，对应参数 acceptOldApp；② 弹窗标题 = 体验表标题（{0} 填设备），正文 = 作业给的那句；③ 有「仍然继续」键；
//   ④ phone_app_incompatible 不是确认码（拦下、只有「重试」）。调用方核退出码 0 和末行「✓」
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;

static class ConfirmProbe
{
    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        int fails = 0;
        void Check(string name, bool ok, string got = "") { Console.WriteLine($"{(ok ? "通" : "不通")} {name}{(ok ? "" : "（实际 " + got + "）")}"); if (!ok) fails++; }
        foreach (var lang in new[] { "zh-Hans", "en" })
        {
        var w = new EnvironmentWindow { Width = 1280, Height = 900 };
        try
        {
            w.Show(); Dispatcher.UIThread.RunJobs();
            (w.GetType().GetProperty("language", BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMemberException("language")).SetValue(w, lang); Call(w, "Render"); Dispatcher.UIThread.RunJobs();
            bool zh = lang == "zh-Hans";
            var codes = (IReadOnlyDictionary<string, string>)Prop(w, "ConfirmCodes")!;
            Check("phone_app_outdated 是确认码、参数 acceptOldApp", codes.TryGetValue("phone_app_outdated", out var flag) && flag == "acceptOldApp", flag ?? "无");
            Check("phone_app_incompatible 不是确认码（拦下）", !codes.ContainsKey("phone_app_incompatible"));
            const string body = "这台 iPhone 上的 S2Arm 是 0.6.2，比电脑上的 0.6.7 旧，部分修复要更新 App 才生效：在这台电脑的游戏库最前面「S2Arm」卡点「更新 S2Arm」装成 0.6.7（之后这台电脑就认它），或回到当初装它的那台电脑更新。也可以先照旧推。";
            var title = (string)Call(w, "ConfirmTitle", "phone_app_outdated")!;
            Check($"[{lang}] 标题取体验表、填设备", title.Contains("S2Arm") && title.Contains(zh ? "旧版" : "older version") && !title.Contains("{0}"), title);
            var task = (Task<bool>)Call(w, "ConfirmInstallActionAsync", "install.drop", body, title, "phone_app_outdated", null)!;
            Window? dialog = null;
            for (int i = 0; i < 200 && dialog is null; i++) { Dispatcher.UIThread.RunJobs(); dialog = w.OwnedWindows.FirstOrDefault(); }
            Check("弹出确认窗", dialog is not null);
            if (dialog is not null)
            {
                for (int i = 0; i < 20; i++) Dispatcher.UIThread.RunJobs();
                var texts = dialog.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text ?? "").ToList();
                var buttons = dialog.GetVisualDescendants().OfType<Button>().Select(b => b.Content?.ToString() ?? "").ToList();
                // 正文 = 作业给的那句；英文界面按对照表（launchers/macos/adapter/.../Localizable.json，{0}… 按顺序填）译成英文
                Check($"[{lang}] 正文 = 作业给的那句", zh ? texts.Contains(body) : texts.Any(x => x.StartsWith("S2Arm on this iPhone is 0.6.2, older than 0.6.7 on this computer") && x.Contains("Update S2Arm to install 0.6.7") && x.EndsWith("You can also push anyway.")), string.Join(" | ", texts));
                Check($"[{lang}] 有「仍然继续」", buttons.Any(b => b.Contains(zh ? "继续" : "Continue")), string.Join(" | ", buttons));
                var bmp = dialog.CaptureRenderedFrame();
                if (bmp is not null) { using var s = File.Create(Path.Combine(outDir, $"push_old_app_confirm_{lang}.png")); bmp.Save(s); Console.WriteLine($"  saved: push_old_app_confirm_{lang}.png"); }
                else Check("截到弹窗画面", false, "no frame");
                dialog.Close();
                for (int i = 0; i < 50 && !task.IsCompleted; i++) Dispatcher.UIThread.RunJobs();
                Check("关掉 = 不继续", task.IsCompleted && task.Result == false);
            }
        }
        catch (Exception e) { fails++; Console.WriteLine($"不通 {(e is TargetInvocationException { InnerException: { } x } ? x : e).Message}"); }
        finally { try { w.Close(); Dispatcher.UIThread.RunJobs(); } catch (Exception) { } }
        }
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} 推游戏遇到旧 App 的确认页：不通 {fails}");
        return fails == 0 ? 0 : 1;
    }
    static object? Prop(object o, string name) =>
        (o.GetType().GetProperty(name, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMemberException(name)).GetValue(o);
    static object? Call(object o, string name, params object?[] args) =>
        (o.GetType().GetMethod(name, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMethodException(name)).Invoke(o, args);
}
