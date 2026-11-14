// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

/// <summary>覆盖更新的进程调用（下载、校验、替换、回滚都在 pack/jobs/updater.py）。只用随包 Python 的标准库，不需要运行环境脚本。</summary>
public static class UpdateClient
{
    /// <summary>安装包打进去的版本号（bundle_win.py 写）；开发版没有这个文件，就不提示更新。</summary>
    public static string CurrentVersion(string installDir)
    {
        try { return File.ReadAllText(Path.Combine(installDir, "version.txt")).Trim(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return ""; }
    }

    private static ProcessStartInfo Start(string python, IEnumerable<string> arguments)
    {
        var info = new ProcessStartInfo(python)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8
        };
        foreach (var argument in new[] { "-X", "utf8", "-B", "-I" }.Concat(arguments)) info.ArgumentList.Add(argument);
        return info;
    }

    /// <summary>跑一条 updater 命令，逐行交 JSON，返回最后一行；起不来或超时返回 null。</summary>
    public static Task<JsonElement?> RunAsync(LauncherPaths paths, IEnumerable<string> command, Action<JsonElement>? onEvent, TimeSpan limit) =>
        RunScriptAsync(paths, "updater.py", command, onEvent, limit);

    /// <summary>用随包 Python 跑 pack/jobs 下一个只用标准库的脚本（updater.py、batch.py），逐行交 JSON，返回最后一行；起不来或超时返回 null。
    /// 超时 / 读失败时连子进程树一起结束：不然超时的下载还在后台跑，玩家点重试会再起一份同时写同一个暂存目录。</summary>
    internal static async Task<JsonElement?> RunScriptAsync(LauncherPaths paths, string script, IEnumerable<string> command, Action<JsonElement>? onEvent, TimeSpan limit)
    {
        var python = Path.Combine(Path.GetFullPath(paths.Runtime), "python", "python.exe");
        var scriptPath = Path.Combine(Path.GetFullPath(paths.Engine), "pack", "jobs", script);
        JsonElement? last = null;
        using var cancel = new CancellationTokenSource(limit);
        Process? process = null;
        try
        {
            process = Process.Start(Start(python, new[] { scriptPath }.Concat(command)))!;
            process.StandardInput.Close();
            var drain = process.StandardError.ReadToEndAsync(cancel.Token);
            while (await process.StandardOutput.ReadLineAsync(cancel.Token) is { } line)
            {
                try { using var document = JsonDocument.Parse(line); last = document.RootElement.Clone(); }
                catch (JsonException) { continue; }
                onEvent?.Invoke(last.Value);
            }
            await process.WaitForExitAsync(cancel.Token);
            await drain;
            return last;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or System.ComponentModel.Win32Exception or InvalidOperationException) { return last; }
        finally
        {
            try { if (process is { HasExited: false }) { process.Kill(entireProcessTree: true); process.WaitForExit(TimeSpan.FromSeconds(5)); } }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
            process?.Dispose();
        }
    }
}
