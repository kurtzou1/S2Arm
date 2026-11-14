// S2Arm（不是上游文件）：「S 级优化升级」页（v0.4.0，同 Mac launchers/macos/frontend/Sources/NX2Apple/SGradeUpgradeView.swift；
//   11-14 维护者：Windows 出包和 macOS 使用者一样多，功能和体验对齐 macOS）。已经装在 iPhone 上 / 导出过的游戏不用重出包就补上 S 级优化：
//   打开即跑 sgradeScan（pack/jobs/sgrade.py）：逐款找原始程序、按启动器内置补丁库看这个版本能补什么 → 分组：可升级 / 没有对应补丁 / 出包时选了不打入 /
//   没找到原始程序（要重新出包覆盖更新）。一款都升不了只给「确认」；有可升级的 iPhone 款给「插上手机，一键升级并安装」「自签导出 IPA」
//   （installUpdate + sgradeUpgrade，只换程序、资源包不推；结果页列打上 / 没打上，PhoneJobCard.cs）。Windows 不运行游戏，没有 Mac 那句「下次启动自动生效」
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private bool sgradeOpen;
    private bool sgradeScanning;
    private JsonElement? sgradeScan;
    private string sgradeScanError = "";

    private void OpenSGradeUpgrade()
    {
        if (libraryId is null || libraryBusy || PackBusy) return;
        sgradeOpen = true; sgradeScan = null; sgradeScanError = "";
        Render();   // 页面渲染时发起查找（RenderSGradeUpgrade：还没结果、也没在查 → ScanSGradeAsync）
    }

    private async Task ScanSGradeAsync()
    {
        sgradeScanning = true;   // 由渲染发起，页面此刻已画着「正在查找」，不再重入渲染
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("sgradeScan", "", null), null, CancellationToken.None);
            if (job.Report.Succeeded && job.Report.Result.ValueKind == JsonValueKind.Object) sgradeScan = job.Report.Result.Clone();
            else sgradeScanError = job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException)
        { sgradeScanError = error.Message; }
        finally { sgradeScanning = false; Dispatcher.UIThread.Post(Render); }
    }

    /// <summary>游戏库页标题行的入口（同 Mac LauncherView+Library 的「S 级优化升级」按钮：金色 S + 字）</summary>
    private Control SGradeUpgradeEntry()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new Image { Source = SGoldImage(), Width = 18, Height = 18, Stretch = Stretch.Uniform });
        row.Children.Add(new TextBlock { Text = T("sgrade.upgrade.button"), FontSize = 13.5, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var b = new Button { Content = row, IsEnabled = !libraryBusy && !PackBusy, Padding = new Thickness(12, 6) };
        b.Click += (_, _) => OpenSGradeUpgrade();
        Avalonia.Automation.AutomationProperties.SetAutomationId(b, "library.sgradeUpgrade");
        return b;
    }

    private void RenderSGradeUpgrade(StackPanel body)
    {
        string X(string k) => T("sgrade.upgrade." + k);
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        head.Children.Add(new Image { Source = SGoldImage(), Width = 34, Height = 34, Stretch = Stretch.Uniform });
        head.Children.Add(new TextBlock { Text = X("title"), FontSize = 22, FontWeight = FontWeight.Bold, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Diag((SGoldHi, 0), (SGold, 0.5), (SRose, 1)) });
        body.Children.Add(head);
        var box = new StackPanel { Spacing = 14 };
        AutomationId(box, "sgrade.upgrade");
        void Close() { sgradeOpen = false; Render(); }
        void OkRow() { var ok = Primary(X("ok"), Close); AutomationId(ok, "sgrade.upgrade.ok"); box.Children.Add(ok); }
        if (sgradeScanError.Length > 0) { box.Children.Add(WrappedMuted(B(sgradeScanError), 14)); OkRow(); body.Children.Add(Card(box)); return; }
        if (sgradeScan is not { } scan)   // 还在查（sgradeScanning）
        {
            if (!sgradeScanning) _ = ScanSGradeAsync();
            box.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4 });
            box.Children.Add(Muted(X("scanning"), 13));
            body.Children.Add(Card(box)); return;
        }
        string S(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        int N(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
        bool Bo(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
        var all = scan.TryGetProperty("games", out var gs) && gs.ValueKind == JsonValueKind.Array ? gs.EnumerateArray().ToList() : [];
        var found = all.Where(g => S(g, "program") is { Length: > 0 } p && p != "none").ToList();
        var yes = found.Where(g => N(g, "total") > 0 && !Bo(g, "off")).ToList();
        var no = found.Where(g => N(g, "total") == 0).ToList();
        var off = found.Where(g => N(g, "total") > 0 && Bo(g, "off")).ToList();
        var missing = all.Where(g => !found.Contains(g)).ToList();
        string Gains(JsonElement g)
        {
            var p = g.TryGetProperty("patches", out var pp) && pp.ValueKind == JsonValueKind.Object ? pp : default;
            int C(string k) => p.ValueKind == JsonValueKind.Object ? N(p, k) : 0;
            var parts = new List<string>();
            if (C("widescreen") > 0) parts.Add(X("cat.widescreen"));
            if (C("fps") > 0) parts.Add(X("cat.fps"));
            if (C("gfx") > 0) parts.Add(X("cat.gfx"));
            if (C("cheat") > 0) parts.Add(X("cat.cheat").Replace("{0}", C("cheat").ToString()));
            return string.Join(language == "en" ? ", " : "、", parts);
        }
        void Group(string title, IEnumerable<JsonElement> rows, bool gold = false, bool gains = false)
        {
            if (title.Length > 0)
            {
                var t = new TextBlock { Text = title, FontSize = 13.5, FontWeight = FontWeight.SemiBold };
                if (gold) t.Foreground = new SolidColorBrush(SGold);
                box.Children.Add(t);
            }
            foreach (var g in rows)
            {
                var line = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
                line.Children.Add(new TextBlock { Text = S(g, "name"), FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
                if (gains) { var gtx = Muted(Gains(g), 12); Grid.SetColumn(gtx, 1); line.Children.Add(gtx); }
                box.Children.Add(line);
            }
        }
        if (found.Count == 0) { box.Children.Add(WrappedMuted(X("nothing"), 14)); OkRow(); }
        else if (yes.Count == 0)
        {
            if (no.Count > 0) { box.Children.Add(WrappedMuted(X("none"), 14)); Group("", no); }
            if (off.Count > 0) Group(X("off"), off);
            OkRow();
        }
        else
        {
            box.Children.Add(Label(X("found").Replace("{0}", found.Count.ToString()), 14));
            Group(X("yes"), yes, gold: true, gains: true);
            if (no.Count > 0) Group(X("no"), no);
            if (off.Count > 0) Group(X("off"), off);
            if (missing.Count > 0) Group(X("missing"), missing);
            if (yes.Any(g => Bo(g, "iphone")))
            {
                box.Children.Add(WrappedMuted(X("iphoneNote"), 12));
                var buttons = new WrapPanel { Orientation = Orientation.Horizontal };
                var install = Primary(X("install"), () => { sgradeOpen = false; _ = UpdatePhoneAsync(false, [], mode: "device", sgradeUpgrade: true); }, !installBusy && !PackBusy);
                AutomationId(install, "sgrade.upgrade.install"); install.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(install);
                var export = Action("sgrade.upgrade.export", () => { sgradeOpen = false; _ = UpdatePhoneAsync(false, [], mode: "export", sgradeUpgrade: true); }, !installBusy && !PackBusy);
                export.Margin = new Thickness(0, 0, 12, 0); buttons.Children.Add(export);
                buttons.Children.Add(Action("sgrade.upgrade.close", Close));
                box.Children.Add(buttons);
            }
            else OkRow();
        }
        body.Children.Add(Card(box));
    }
}
