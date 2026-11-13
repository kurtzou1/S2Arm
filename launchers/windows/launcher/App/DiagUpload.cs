// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// 「上传给开发者」（11-13 诊断一键上传，取代原来的「复制错误摘要」与「导出诊断包」两个入口，同 Mac UploadDiagnosticsSheet）：
///   点了先说清传什么、不传什么，玩家确认才传；作业层（pack/jobs/diag_upload.py）打一份和导出相同的脱敏包、带上这次失败的错误摘要，
///   传完只给一个短码、只复制码。上传没成（服务没开通 / 没网 / 被拒收）就说明原因、退回「导出诊断包」。
///   还没选游戏库（欢迎页的环境检查失败）也照传：库路径给作业层的缺省「<私有目录>/unconfigured」（同 Mac JobClient），打包不依赖游戏库（11-13 故障报修）。
public sealed partial class EnvironmentWindow
{
    private bool diagUploadOpen;

    private Button CopyReportButton(string? gameId, string[]? operations, Func<string> fallback)
    {
        var button = new Button { Content = T("diag.upload.button"), Padding = new Thickness(16, 9),
            Background = Brush.Parse("#29292D"), Foreground = Ink, CornerRadius = new CornerRadius(8) };
        AutomationId(button, "diag.upload");
        button.Click += async (_, _) => await UploadDiagnosticsAsync(gameId, operations, fallback, button);
        return button;
    }

    /// 报错页统一的一句「故障报修」指引（11-13，同 Mac ReportHint）：文字只在共享规格 report.hint 一处（SharedText.ReportHint）；凡有「上传给开发者」的报错页都挂它
    private TextBlock ReportHintText()
    {
        var hint = new TextBlock { Text = text.ReportHint(language), FontSize = 12.5, Foreground = Brush.Parse("#8C8A85"), TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0) };
        AutomationId(hint, "report.hint");
        return hint;
    }

    private Dictionary<string, object?> ReportExtra() => new()
    {
        ["app"] = AppVersion,
        ["checks"] = (report?.Checks ?? []).Where(c => c.Status != "ok")
            .Select(c => new Dictionary<string, string> { ["name"] = c.Name, ["message"] = c.Message }).ToList()
    };

    private async Task UploadDiagnosticsAsync(string? gameId, string[]? operations, Func<string> fallback, Button? origin = null)
    {
        if (diagUploadOpen) return;
        diagUploadOpen = true;
        try
        {
            var dialog = new Window
            {
                Title = T("diag.upload.button"), Width = 480, SizeToContent = SizeToContent.Height, CanResize = false,
                WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Canvas, Foreground = Ink,
                FontFamily = new FontFamily("avares://S2Arm/Assets/Fonts#Manrope")
            };
            var body = new StackPanel { Spacing = 14, Margin = new Thickness(28) };
            dialog.Content = body;
            Button Action(string key, string id, bool primary = false)
            {
                var b = new Button { Content = T(key), Padding = new Thickness(16, 9), CornerRadius = new CornerRadius(8), Margin = new Thickness(12, 0, 0, 0),
                    Background = Brush.Parse(primary ? "#3A3A40" : "#29292D"), Foreground = Ink };
                AutomationId(b, id);
                return b;
            }
            WrapPanel Row(params Button[] buttons)
            {
                var row = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                foreach (var b in buttons) row.Children.Add(b);
                return row;
            }
            var exported = false;
            void Confirm()
            {
                body.Children.Clear();
                body.Children.Add(Label(T("diag.upload.button"), 20));
                body.Children.Add(Muted(T("diag.upload.what"), 14));
                body.Children.Add(Muted(T("diag.upload.not"), 14));
                var cancel = Action("diag.upload.cancel", "diag.upload.cancel"); cancel.Click += (_, _) => dialog.Close();
                var send = Action("diag.upload.send", "diag.upload.send", true); send.Click += async (_, _) => await Send();
                body.Children.Add(Row(cancel, send));
            }
            async Task Send()
            {
                body.Children.Clear();
                body.Children.Add(Label(T("diag.upload.button"), 20));
                body.Children.Add(Muted(T("diag.upload.sending"), 14));
                var fields = new Dictionary<string, object?> { ["extra"] = ReportExtra() };
                if (gameId is not null) fields["gameId"] = gameId;
                if (operations is not null) fields["operations"] = operations; else { var f = fallback(); if (!string.IsNullOrWhiteSpace(f)) fields["summary"] = f; }
                string? code = null, why = null, issueUrl = null, repo = null;
                try
                {
                    var job = await LibraryJobClient.RunAsync(paths, privateRoot, connectedFolder ?? Path.Combine(privateRoot, "unconfigured"), libraryId, "diagnosticsUpload", null, CancellationToken.None, fields: fields);
                    if (job.Report.Succeeded && job.Report.Result.ValueKind == JsonValueKind.Object && job.Report.Result.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String)
                    {
                        code = c.GetString();
                        // 预填好的新帖页与仓库地址由作业层给（pack/jobs/diag_upload.py issue_url，Mac / iOS 同格式）
                        if (job.Report.Result.TryGetProperty("issueUrl", out var u) && u.ValueKind == JsonValueKind.String) issueUrl = u.GetString();
                        if (job.Report.Result.TryGetProperty("repo", out var r) && r.ValueKind == JsonValueKind.String) repo = r.GetString();
                    }
                    else why = job.Report.Succeeded ? T("diag.upload.noCode") : job.Report.Message;
                }
                catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
                    InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception)
                { why = error.Message; }
                body.Children.Clear();
                body.Children.Add(Label(T("diag.upload.button"), 20));
                if (!string.IsNullOrEmpty(code))
                {
                    body.Children.Add(Muted(T("diag.upload.done"), 14));
                    var codeText = new SelectableTextBlock { Text = code, FontSize = 26, FontWeight = FontWeight.SemiBold, FontFamily = new FontFamily("Consolas, monospace"), Foreground = Ink };
                    AutomationId(codeText, "diag.upload.code");
                    var copy = Action("diag.upload.copy", "diag.upload.copy");
                    copy.Click += async (_, _) =>
                    {
                        if (TopLevel.GetTopLevel(dialog)?.Clipboard is { } clipboard) await clipboard.SetTextAsync(code);
                        copy.Content = T("export.fail.copied");
                    };
                    var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                    line.Children.Add(codeText); line.Children.Add(copy);
                    body.Children.Add(line);
                    body.Children.Add(Muted(T("diag.upload.repo").Replace("{0}", repo ?? "github.com/jhaizhou-ops/S2Arm"), 13));
                    var done = Action("diag.upload.close", "diag.upload.close"); done.Click += (_, _) => dialog.Close();
                    if (issueUrl is { Length: > 0 } link && Uri.TryCreate(link, UriKind.Absolute, out var target) && target.Scheme == Uri.UriSchemeHttps)
                    {
                        var post = Action("diag.upload.github", "diag.upload.github", true);   // 主按钮：系统浏览器打开预填好诊断码 / 版本 / 平台的新帖页
                        post.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target.AbsoluteUri) { UseShellExecute = true });
                        body.Children.Add(Row(done, post));
                    }
                    else body.Children.Add(Row(done));
                }
                else
                {
                    var failed = Muted(why ?? T("diag.upload.noCode"), 14); failed.Foreground = Brush.Parse("#E5735F");
                    AutomationId(failed, "diag.upload.failed");
                    body.Children.Add(failed);
                    var close = Action("diag.upload.close", "diag.upload.close"); close.Click += (_, _) => dialog.Close();
                    var export = Action("diag.upload.export", "diag.upload.export", true); export.Click += (_, _) => { exported = true; dialog.Close(); };
                    body.Children.Add(Row(close, export));
                }
            }
            Confirm();
            await dialog.ShowDialog(this);
            if (exported) await ExportDiagnosticsAsync();   // 退回导出：同游戏库「更多」里原来的导出（选保存位置、作业层脱敏打包）
        }
        finally { diagUploadOpen = false; }
    }
}
