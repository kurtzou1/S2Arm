// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 装机卡片「详细过程」点开后不被进度刷新收起（D-237B：玩家「点详细信息，点开就自动收起，看不到内容」）：装机在跑时，
//   每个进度事件走 IngestPhoneEvent → RefreshLive，重建装机进度格子，卡片连同折叠区一起新建。期望手写：
//   ① 点开前收起；② 点开后展开；③ 再来 5 个进度事件（真实入口 IngestPhoneEvent）仍展开、内容里有最新一条；④ 再点一次收起，再来事件仍收起。
//   负对照：展开状态只在控件自己身上（修前），③ 不通。调用方核退出码 0 和末行「✓」。
using System.Reflection;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class DetailsProbe
{
    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var w = new EnvironmentWindow { Width = 1280, Height = 800 };
        w.Show(); Settle(w);
        var fails = new List<string>();
        object? phoneJob = null;
        try
        {
            var game = new LibraryGame("0100000000010000", "测试游戏 A", "v1.0.0", "", false, [], true,
                DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 86400.0, true, [new("base", "0100000000010000", 0, "v1.0.0", 4_000_000_000L, "extract")]);
            Set(w, "catalog", new LibraryCatalog([game], true, "密钥已就绪"));
            Set(w, "selectedGame", game.Id); Set(w, "connectedFolder", "/tmp/s2arm-library"); Set(w, "libraryId", "mock-lib-id");
            Set(w, "librarySummary", "library.completed");
            phoneJob = w.GetType().GetMethod("BeginJob", BindingFlags.Instance | BindingFlags.NonPublic)!   // 装机在跑（installBusy 由作业槽推出来）
                .Invoke(w, [Enum.Parse(w.GetType().GetNestedType("JobKind", BindingFlags.NonPublic)!, "Phone"), game.Id]);
            Set(w, "installState", "running"); Set(w, "installMessage", "正在连接 iPhone");
            Set(w, "installGameId", game.Id); Set(w, "installGameName", game.Name); Set(w, "installSeen", false);
            Event(w, "把这款的程序推进 iPhone");
            w.GetType().GetMethod("Navigate", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(w, ["install"]); Settle(w);
            Check(fails, "① 点开前收起", Open(w) == false);
            Toggle(w); Settle(w);
            Check(fails, "② 点开后展开", Open(w) == true);
            for (var i = 1; i <= 5; i++) Event(w, $"重编着色器库（第 {i} 段）");
            Settle(w);
            Check(fails, "③ 来 5 个进度事件后仍展开", Open(w) == true);
            Check(fails, "③ 内容里有最新一条", Body(w)?.Text?.Contains("重编着色器库（第 5 段）") == true);
            Toggle(w); Settle(w);
            Event(w, "推资源包"); Settle(w);
            Check(fails, "④ 收起后再来事件仍收起", Open(w) == false);
        }
        finally
        {
            if (phoneJob is not null) w.GetType().GetMethod("EndJob", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(w, [phoneJob]);
            w.Close(); Dispatcher.UIThread.RunJobs();
        }
        if (fails.Count > 0) { Console.WriteLine("✗ 装机卡片详细过程：" + string.Join("；", fails)); return 1; }
        Console.WriteLine("✓ 装机卡片详细过程点开后不被进度刷新收起");
        return 0;
    }

    static void Check(List<string> fails, string name, bool ok) { Console.WriteLine($"  {(ok ? "通过" : "不通")}：{name}"); if (!ok) fails.Add(name); }

    static void Event(EnvironmentWindow w, string message)
    {
        var e = JsonDocument.Parse(JsonSerializer.Serialize(new Dictionary<string, object> { ["type"] = "message", ["message"] = message })).RootElement;
        (w.GetType().GetMethod("IngestPhoneEvent", BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMethodException("IngestPhoneEvent")).Invoke(w, [e]);
        Settle(w);
    }

    static Button? ToggleButton(EnvironmentWindow w) => w.GetVisualDescendants().OfType<Button>()
        .FirstOrDefault(b => Avalonia.Automation.AutomationProperties.GetAutomationId(b) == "phone.details" && b.IsEffectivelyVisible);

    static TextBox? Body(EnvironmentWindow w) => (ToggleButton(w)?.Parent as StackPanel)?.Children.OfType<TextBox>().FirstOrDefault();

    static bool? Open(EnvironmentWindow w) => Body(w)?.IsVisible;

    static void Toggle(EnvironmentWindow w)
        => (ToggleButton(w) ?? throw new InvalidOperationException("装机卡片上找不到「详细过程」")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }

    static void Set(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        (obj.GetType().GetProperty(field, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public) ?? throw new MissingMemberException(field)).SetValue(obj, value);
    }
}
