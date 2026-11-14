// S2Arm（不是上游文件）：Windows「金手指」页（11-14 维护者：Windows 功能与体验对齐 macOS）。Mac 在启动设置里看 / 搜 / 导入 / 开关金手指；
//   Windows 不运行游戏，开关只在 iPhone 上（进游戏后逐条开），所以这里做「看这款有哪些 + 导入 txt」：导入进这款游戏文件夹的 cheats/（pack/jobs/cheats.py
//   import_files，同 Mac），下次更新手机上的 S2Arm / 「S 级优化升级」时随包带到手机、要改游戏代码的条目同步编进程序（补丁记号算金手指内容，rewrite_refresh.sgrade_key）
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private LibraryGame? cheatsFor;
    private JsonElement? cheatsList;
    private string cheatsError = "";
    private bool cheatsLoading;

    private void OpenCheats(LibraryGame game)
    {
        cheatsFor = game; cheatsList = null; cheatsError = ""; cheatsLoading = false;
        Render();
    }

    private async Task LoadCheatsAsync()
    {
        if (cheatsFor is not { } game) return;
        cheatsLoading = true;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("community", game.Id, null), null, CancellationToken.None);
            if (job.Report.Succeeded && job.Report.Result.ValueKind == JsonValueKind.Object && job.Report.Result.TryGetProperty("cheats", out var ch))
                cheatsList = ch.Clone();
            else cheatsError = job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException)
        { cheatsError = error.Message; }
        finally { cheatsLoading = false; Dispatcher.UIThread.Post(Render); }
    }

    private async Task ImportCheatsAsync()
    {
        if (cheatsFor is not { } game) return;
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = true, Title = T("cheats.page.import"),
            FileTypeFilter = [new FilePickerFileType("txt") { Patterns = ["*.txt"] }]
        });
        var paths = files.Select(f => f.TryGetLocalPath()).Where(p => !string.IsNullOrEmpty(p)).Cast<object?>().ToList();
        if (paths.Count == 0) return;
        cheatsError = ""; cheatsList = null; cheatsLoading = true; Render();
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("communitySave", game.Id, new Dictionary<string, object?> { ["cheatsImport"] = paths }), null, CancellationToken.None);
            if (!job.Report.Succeeded) cheatsError = job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException)
        { cheatsError = error.Message; }
        cheatsLoading = false;
        await LoadCheatsAsync();
    }

    private void RenderCheats(StackPanel body)
    {
        if (cheatsFor is not { } game) return;
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), ColumnSpacing = 10 };
        head.Children.Add(Label(T("cheats.page.title").Replace("{0}", game.Name), 22));
        var import = Action("cheats.page.import", () => _ = ImportCheatsAsync(), !cheatsLoading && !libraryBusy);
        Grid.SetColumn(import, 1); head.Children.Add(import);
        var back = Action("cheats.page.back", () => { cheatsFor = null; Render(); });
        Grid.SetColumn(back, 2); head.Children.Add(back);
        body.Children.Add(head);
        var box = new StackPanel { Spacing = 10 };
        AutomationId(box, "cheats.page");
        box.Children.Add(WrappedMuted(T("cheats.page.note"), 13));
        if (cheatsError.Length > 0) box.Children.Add(WrappedMuted("⚠ " + B(cheatsError), 13));
        if (cheatsList is not { } list)
        {
            if (!cheatsLoading && cheatsError.Length == 0) _ = LoadCheatsAsync();
            if (cheatsError.Length == 0) { box.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4 }); }
            body.Children.Add(Card(box)); return;
        }
        string S(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        bool Bo(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
        var items = list.TryGetProperty("items", out var its) && its.ValueKind == JsonValueKind.Array ? its.EnumerateArray().ToList() : [];
        if (items.Count == 0) { box.Children.Add(Label(B(S(list, "reason")), 14)); body.Children.Add(Card(box)); return; }
        box.Children.Add(Label(T("cheats.page.count").Replace("{0}", items.Count(i => Bo(i, "ok")).ToString()), 14));
        foreach (var file in items.GroupBy(i => S(i, "file")))
        {
            var first = file.First();
            var from = S(first, "from") == "library" ? T("display.cheats.library").Replace("{0}", S(first, "repo")) : T("display.cheats.player");
            var author = S(first, "author");
            var t = new TextBlock { Text = file.Key, FontSize = 13.5, FontWeight = FontWeight.SemiBold };
            box.Children.Add(t);
            box.Children.Add(Muted(from + (author.Length > 0 ? " · " + T("display.cheats.author").Replace("{0}", author) : ""), 12));
            foreach (var it in file)
            {
                var line = S(it, "name");
                if (Bo(it, "fixed")) line += " · " + T("display.cheats.fixedAddress");
                if (!Bo(it, "ok")) line += " · " + B(S(it, "reason"));
                box.Children.Add(new TextBlock { Text = "· " + line, FontSize = 13, TextWrapping = TextWrapping.Wrap,
                    Foreground = Bo(it, "ok") ? Ink : Brush.Parse("#8C8A85") });
            }
        }
        body.Children.Add(Card(box));
    }
}
