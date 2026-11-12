// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 出包页「签名方式」一栏 + 导入开发者证书弹窗（v0.2.4，作业层 pack/jobs/devcert.py；同 Mac DevCertViews.swift）。
//   Apple ID 签名 / 我的开发者证书 二选一；选了证书列团队、到期、包名、设备列表，问题黄字（不挡）、根本签不了红字。
//   密码只经环境变量交给导入那一次作业（PackJobClient.Request.Secrets），不写进请求文件；后端用 DPAPI 加密存在本机。
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
    private JsonElement? devCert;          // devCert status 作业的结果：imported / active / cert
    private bool devCertLoading;
    // 渲染里自动读证书状态：每个游戏库只读一次，没连库不读。读的结果回来要 Render，Render 又会画到这一栏——没连库时作业同步返回 null，
    //   原先「devCert 还是空、又不在读」就再读一次 → Render → 再读……无限递归栈溢出，引导页（还没建库）点设置键当场闪退。显式刷新（进设置页、导入后）照旧直接调
    private string? devCertFor;
    private void EnsureDevCert()
    {
        if (libraryId is null || devCertFor == libraryId || devCertLoading) return;
        devCertFor = libraryId; _ = RefreshDevCertAsync();
    }

    private string S(string id) => T("export.sign." + id);

    private async Task<LibraryJobResult?> DevCertJobAsync(Dictionary<string, object?> extra, IReadOnlyDictionary<string, string>? secrets = null)
    {
        if (connectedFolder is null || libraryId is null) return null;
        try
        {
            var job = await PackJobClient.RunAsync(new(paths, privateRoot, connectedFolder, libraryId, "devCert", "", extra, secrets), null, CancellationToken.None);
            return job.Report;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }

    private async Task RefreshDevCertAsync()
    {
        devCertLoading = true;
        var r = await DevCertJobAsync(new() { ["action"] = "status" });
        devCertLoading = false;
        if (r is { Succeeded: true }) devCert = r.Result.Clone();
        if (page is "build" or "settings") Render();
    }

    private static string Str(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    private static bool Flag(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;

    /// <param name="title">一栏标题（缺省「签名方式」）；环境检查「装到 iPhone 的方式」卡里叫「签名身份」。</param>
    /// <param name="appleIdTitle">Apple ID 那一项的名字（缺省「Apple ID 签名」）；环境检查卡里叫「Apple ID（在 Impactor 里登录）」。</param>
    /// <param name="card">false = 只要内容不包卡片（嵌在别的卡片里时）。</param>
    private Control DevCertRow(string? title = null, string? appleIdTitle = null, bool card = true)
    {
        if (devCert is null) EnsureDevCert();
        var st = devCert;
        var imported = st is { } s0 && Flag(s0, "imported");
        var active = st is { } s1 && Flag(s1, "active");
        var panel = new StackPanel { Spacing = 10 };
        var line = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), ColumnSpacing = 8 };
        var heading = Label(title ?? S("title"), 16); heading.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(heading);
        Button Mode(string key, bool on, Action handler, string? text = null)
        {
            var b = new Button { Content = text ?? S(key), Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8),
                Background = on ? Accent : Brush.Parse("#29292D"), Foreground = on ? Canvas : Ink };
            AutomationId(b, "export.sign." + key);
            b.Click += (_, _) => handler();
            return b;
        }
        var apple = Mode("appleId", !active, () => _ = SetDevCertAsync(false), appleIdTitle);
        var mine = Mode("devcert", active, () => { if (imported) _ = SetDevCertAsync(true); else _ = ImportDevCertAsync(); });
        Grid.SetColumn(apple, 1); line.Children.Add(apple);
        Grid.SetColumn(mine, 2); line.Children.Add(mine);
        panel.Children.Add(line);
        if (active && st is { } s && s.TryGetProperty("cert", out var c) && c.ValueKind == JsonValueKind.Object)
        {
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("120,*"), RowSpacing = 4, Margin = new Thickness(4, 4, 0, 0) };
            var rows = new List<(string, string)>
            {
                (S("team"), Str(c, "teamName").Length > 0 ? $"{Str(c, "teamName")}（{Str(c, "teamId")}）" : Str(c, "teamId")),
                (S("certExpires"), Str(c, "certExpires")), (S("profileExpires"), Str(c, "profileExpires")), (S("bundle"), Str(c, "bundleId")),
                (S("devices"), Flag(c, "allDevices") ? S("devices.all")
                    : S(c.TryGetProperty("deviceListed", out var dl) && dl.ValueKind != JsonValueKind.Null ? (dl.ValueKind == JsonValueKind.True ? "devices.listed" : "devices.missing") : "devices.unknown")
                        .Replace("{0}", c.TryGetProperty("deviceCount", out var n) && n.ValueKind == JsonValueKind.Number ? n.GetInt32().ToString() : "0"))
            };
            for (var i = 0; i < rows.Count; i++)
            {
                grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
                var k = Muted(rows[i].Item1, 13); Grid.SetRow(k, i); grid.Children.Add(k);
                var v = new SelectableTextBlock { Text = rows[i].Item2.Length > 0 ? rows[i].Item2 : "-", FontSize = 13, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap };
                Grid.SetRow(v, i); Grid.SetColumn(v, 1); grid.Children.Add(v);
            }
            panel.Children.Add(grid);
            foreach (var (list, color) in new[] { ("blocking", "#E5675F"), ("warnings", "#E8C65A") })
                if (c.TryGetProperty(list, out var items) && items.ValueKind == JsonValueKind.Array)
                    foreach (var w in items.EnumerateArray())
                        panel.Children.Add(new TextBlock { Text = (list == "blocking" ? "✕ " : "⚠ ") + Str(w, "text"), FontSize = 12.5,
                            TextWrapping = TextWrapping.Wrap, Foreground = Brush.Parse(color) });
            var actions = new WrapPanel { Orientation = Orientation.Horizontal };
            var replace = new Button { Content = S("replace"), Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8),
                Background = Brush.Parse("#29292D"), Foreground = Ink, Margin = new Thickness(0, 0, 10, 0) };
            AutomationId(replace, "export.sign.replace");
            replace.Click += (_, _) => _ = ImportDevCertAsync();
            var delete = new Button { Content = S("delete"), Padding = new Thickness(14, 8), CornerRadius = new CornerRadius(8),
                Background = Brush.Parse("#29292D"), Foreground = Ink };
            AutomationId(delete, "export.sign.delete");
            delete.Click += (_, _) => _ = DeleteDevCertAsync();
            actions.Children.Add(replace); actions.Children.Add(delete);
            panel.Children.Add(actions);
        }
        panel.Children.Add(Muted(S("switchNote"), 12.5));
        return card ? Card(panel, 14) : panel;
    }

    private async Task SetDevCertAsync(bool on)
    {
        await DevCertJobAsync(new() { ["action"] = "use", ["active"] = on });
        await RefreshDevCertAsync();
    }

    private async Task DeleteDevCertAsync()
    {
        if (!await ConfirmAsync(S("deleteConfirm"), S("delete"))) return;
        await DevCertJobAsync(new() { ["action"] = "delete" });
        await RefreshDevCertAsync();
    }

    private async Task<bool> ConfirmAsync(string bodyText, string confirmText)
    {
        var dialog = NewDialog(S("delete"), 420);
        var confirmed = false;
        var body = new StackPanel { Spacing = 16, Margin = new Thickness(28) };
        body.Children.Add(Muted(bodyText, 14));
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(DialogButton(S("sheet.cancel"), false, () => dialog.Close()));
        buttons.Children.Add(DialogButton(confirmText, true, () => { confirmed = true; dialog.Close(); }));
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        return confirmed;
    }

    private Window NewDialog(string title, double width) => new()
    {
        Title = title, Width = width, SizeToContent = SizeToContent.Height, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
        Background = Canvas, Foreground = Ink, FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope")
    };

    private Button DialogButton(string text, bool primary, Action handler)
    {
        var b = new Button { Content = text, Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, primary ? 0 : 12, 0),
            Background = primary ? Accent : Brush.Parse("#29292D"), Foreground = primary ? Canvas : Ink };
        b.Click += (_, _) => handler();
        return b;
    }

    /// <summary>导入弹窗：选 .p12 与 .mobileprovision、输密码、点导入；失败原因留在弹窗里，成了自动关并切到证书签名。</summary>
    private async Task ImportDevCertAsync()
    {
        var dialog = NewDialog(S("sheet.title"), 560);
        string p12 = "", profile = "";
        var body = new StackPanel { Spacing = 14, Margin = new Thickness(28) };
        body.Children.Add(Label(S("sheet.title"), 20));
        Control Pick(string key, string[] patterns, string id, Action<string> set)
        {
            var box = new StackPanel { Spacing = 6 };
            box.Children.Add(Label(S(key), 13));
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10 };
            var shown = Muted(S("sheet.drop"), 12.5); shown.VerticalAlignment = VerticalAlignment.Center; shown.TextTrimming = TextTrimming.CharacterEllipsis; shown.TextWrapping = TextWrapping.NoWrap;
            row.Children.Add(shown);
            var choose = DialogButton(S("sheet.choose"), false, async () =>
            {
                var files = await dialog.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
                {
                    Title = S(key), AllowMultiple = false, FileTypeFilter = [new FilePickerFileType(S(key)) { Patterns = patterns }]
                });
                if (files.Count > 0 && files[0].TryGetLocalPath() is { } path) { set(path); shown.Text = path; shown.Foreground = Ink; }
            });
            AutomationId(choose, "export.sign.sheet.choose." + id);
            Grid.SetColumn(choose, 1); row.Children.Add(choose);
            box.Children.Add(new Border { Child = row, Background = Surface, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 8) });
            return box;
        }
        body.Children.Add(Pick("sheet.p12", ["*.p12", "*.pfx"], "p12", p => p12 = p));
        body.Children.Add(Pick("sheet.profile", ["*.mobileprovision"], "profile", p => profile = p));
        body.Children.Add(Label(S("sheet.password"), 13));
        var password = new TextBox { PasswordChar = '•', RevealPassword = false };
        AutomationId(password, "export.sign.sheet.password");
        body.Children.Add(password);
        body.Children.Add(Muted(S("sheet.passwordNote"), 12));
        var failure = new TextBlock { FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Foreground = Brush.Parse("#E5675F"), IsVisible = false };
        AutomationId(failure, "export.sign.sheet.failure");
        body.Children.Add(failure);
        var working = Muted(S("sheet.working"), 12.5); working.IsVisible = false;
        var buttons = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        buttons.Children.Add(working);
        var cancel = DialogButton(S("sheet.cancel"), false, () => dialog.Close());
        Grid.SetColumn(cancel, 1); buttons.Children.Add(cancel);
        Button? go = null;
        go = DialogButton(S("sheet.import"), true, async () =>
        {
            if (p12.Length == 0 || profile.Length == 0) return;
            go!.IsEnabled = false; working.IsVisible = true; failure.IsVisible = false;
            var r = await DevCertJobAsync(new() { ["action"] = "import", ["p12Path"] = p12, ["profilePath"] = profile },
                new Dictionary<string, string> { ["S2A_DEVCERT_PASSWORD"] = password.Text ?? "" });
            working.IsVisible = false; go.IsEnabled = true;
            if (r is { Succeeded: true }) { password.Text = ""; dialog.Close(); return; }
            failure.Text = r?.Message is { Length: > 0 } m ? m : T("export.sign.sheet.title");
            failure.IsVisible = true;
        });
        AutomationId(go, "export.sign.sheet.import");
        Grid.SetColumn(go, 2); buttons.Children.Add(go);
        body.Children.Add(buttons);
        dialog.Content = body;
        await dialog.ShowDialog(this);
        await RefreshDevCertAsync();
    }
}
