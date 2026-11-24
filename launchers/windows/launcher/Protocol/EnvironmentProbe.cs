// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

public sealed record LauncherPaths(string Engine, string Runtime, string Shell)
{
    public static LauncherPaths Defaults(string executableDirectory) => new(
        Path.Combine(executableDirectory, "Engine"), Path.Combine(executableDirectory, "Runtime"),
        Path.Combine(executableDirectory, "Shell"));

    /// <summary>设置页三个输入框的值换进来；空的（输入框还没画出来、或被清空）保留原路径。空路径从来不是有效设置：
    /// 原先照抄空串，环境检查 Path.GetFullPath("") 抛 ArgumentException，检查作业还没起就悄悄失败（没人等那个任务），
    /// 之后每次检查都一样，界面停在「正在检查这台电脑」（D-97FT）</summary>
    public LauncherPaths Edited(string? engine, string? runtime, string? shell) => new(
        string.IsNullOrWhiteSpace(engine) ? Engine : engine, string.IsNullOrWhiteSpace(runtime) ? Runtime : runtime,
        string.IsNullOrWhiteSpace(shell) ? Shell : shell);
}

public sealed record ProbeOutput(int ExitCode, string StandardOutput, string StandardError);

public static class EnvironmentProbe
{
    public static ProcessStartInfo StartInfo(LauncherPaths paths, string requestFile)
    {
        paths = new(Path.GetFullPath(paths.Engine), Path.GetFullPath(paths.Runtime), paths.Shell);
        if (!Directory.Exists(paths.Engine) || !Directory.Exists(paths.Runtime) ||
            !File.Exists(Path.Combine(paths.Runtime, "s2arm_env.cmd")))
            throw new DirectoryNotFoundException("Configured engine/runtime or s2arm_env.cmd is missing.");
        // The fixed command expands each path once, inside quotes. No CALL (double expansion).
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"))
        {
            WorkingDirectory = paths.Engine, UseShellExecute = false, CreateNoWindow = true,
            // stdin is a pipe the launcher closes at once (EOF), never inherited: S2Arm.exe is a GUI process whose own stdin handle
            // is invalid, and Python in the job hands that to every child it spawns → subprocess fails "[WinError 6] invalid handle"
            // (tianyan 11-07: merge_extract.py cp, step 4 of the iPhone export). Callers start the process with StartProcess.
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        // cmd.exe does not use CommandLineToArgvW: ArgumentList would add C-style quote escapes.
        // This is constant shell code; user paths enter only through environment variables.
        info.Arguments = "/d /v:off /s /c \"\"%S2A_UI_RUNTIME%\\s2arm_env.cmd\" && cd /d \"%S2A_UI_ENGINE%\" && python -X utf8 pack/jobs/winenv.py --json --request \"%S2A_UI_REQUEST%\"\"";
        info.Environment["S2A_UI_RUNTIME"] = paths.Runtime;
        info.Environment["S2A_UI_ENGINE"] = paths.Engine;
        info.Environment["S2A_UI_REQUEST"] = Path.GetFullPath(requestFile);
        // bundle_win.py owns this layout: prepared tools belong to the selected engine snapshot.
        info.Environment["S2A_ENGINE"] = paths.Engine;
        info.Environment["S2A_PREBUILT_TOOLS"] = Path.Combine(paths.Engine, "Binaries", "Prepare");
        info.Environment["S2A_FONTS"] = Path.Combine(AppContext.BaseDirectory, "Fonts");
        return info;
    }

    /// <summary>引擎或运行时不在：通常是在压缩包里直接打开了 S2Arm.exe，系统只解出了这一个文件。</summary>
    public static bool BundleIncomplete(LauncherPaths paths) =>
        !Directory.Exists(Path.GetFullPath(paths.Engine)) || !File.Exists(Path.Combine(Path.GetFullPath(paths.Runtime), "s2arm_env.cmd"));

    public static async Task<ProbeOutput> RunAsync(LauncherPaths paths, CancellationToken cancellationToken)
    {
        var requestFile = Path.GetTempFileName();
        try
        {
            await File.WriteAllTextAsync(requestFile, JsonOut.Serialize(new Dictionary<string, object?>
                { ["schema"] = 1, ["target"] = "ios", ["shell"] = Path.GetFullPath(paths.Shell), ["resources"] = Path.GetFullPath(AppContext.BaseDirectory) }), cancellationToken);
            return await RunProcessAsync(StartInfo(paths, requestFile), cancellationToken);
        }
        finally { File.Delete(requestFile); }
    }

    /// <summary>Starts a job process built by <see cref="StartInfo"/> and closes its stdin (EOF): no job reads it.</summary>
    internal static Process StartProcess(ProcessStartInfo startInfo)
    {
        var process = new Process { StartInfo = startInfo };
        process.Start();
        if (startInfo.RedirectStandardInput) process.StandardInput.Close();
        return process;
    }

    internal static async Task<ProbeOutput> RunProcessAsync(ProcessStartInfo startInfo, CancellationToken cancellationToken, int outputLimit = 2 * 1024 * 1024)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var process = StartProcess(startInfo);
        using var stop = linked.Token.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
        });
        async Task<string> Capture(StreamReader reader, int maximum)
        {
            try { return await ReadAsync(reader, maximum, linked.Token); }
            catch { linked.Cancel(); throw; }
        }
        var stdout = Capture(process.StandardOutput, outputLimit);
        var stderr = Capture(process.StandardError, 128 * 1024);
        try
        {
            await Task.WhenAll(process.WaitForExitAsync(linked.Token), stdout, stderr);
            return new(process.ExitCode, stdout.Result, stderr.Result);
        }
        catch
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            throw;
        }
    }

    private static async Task<string> ReadAsync(StreamReader reader, int maximum, CancellationToken cancellationToken)
    {
        var result = new StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken)) != 0)
        {
            if (result.Length + count > maximum) throw new IOException("Environment output exceeded display limit.");
            result.Append(buffer, 0, count);
        }
        return result.ToString();
    }
}
