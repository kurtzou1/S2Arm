// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 设置页「诊断码」一栏（#1449，作业层 pack/jobs/diagcode.py；同 Mac DiagCodeView.swift）：维护者在帖子里给的诊断码粘进来点「使用」，
//   下次把那款推到 iPhone 时写进手机、生效一局后自动失效。不是常驻选项：没粘过就只有一行说明和输入框。
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private string diagCodeResult = "";

    private Control DiagCodeCard()
    {
        var box = new StackPanel { Spacing = 10 };
        box.Children.Add(Label(T("settings.diagCode"), 16));
        box.Children.Add(Muted(T("settings.diagCode.hint"), 12.5));
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10 };
        var input = new TextBox { PlaceholderText = "S2A-DIAG1-…", AcceptsReturn = false };
        AutomationId(input, "settings.diagCode.input");
        row.Children.Add(input);
        Button? use = null;
        use = Action("settings.diagCode.use", async () =>
        {
            use!.IsEnabled = false;
            var r = await DiagCodeJobAsync(new() { ["action"] = "set", ["code"] = input.Text ?? "" });
            use.IsEnabled = true;
            diagCodeResult = r is { Succeeded: true } ? B(Str(r.Result, "message")) : B(r?.Message is { Length: > 0 } m ? m : T("settings.diagCode"));
            if (r is { Succeeded: true }) input.Text = "";
            Render();
        });
        Grid.SetColumn(use, 1); row.Children.Add(use);
        box.Children.Add(row);
        if (diagCodeResult.Length > 0)
        {
            var said = new TextBlock { Text = diagCodeResult, FontSize = 12.5, Foreground = Ink, TextWrapping = TextWrapping.Wrap };
            AutomationId(said, "settings.diagCode.result");
            box.Children.Add(said);
        }
        return Card(box);
    }

    private async Task<LibraryJobResult?> DiagCodeJobAsync(Dictionary<string, object?> extra)
    {
        if (connectedFolder is null || libraryId is null) return null;
        try
        {
            var job = await PackJobClient.RunAsync(new(paths, privateRoot, connectedFolder, libraryId, "diagCode", "", extra, null), null, CancellationToken.None);
            return job.Report;
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }
}
