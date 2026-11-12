// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

public sealed record LibraryJobOutput(LibraryJobResult Report, ProbeOutput Output);

public static class LibraryJobClient
{
    public static async Task<LibraryJobOutput> RunAsync(LauncherPaths paths, string privateRoot, string library,
        string? libraryId, string operation, IReadOnlyList<string>? selectedPaths, CancellationToken cancellationToken, string? moveFrom = null, bool partialResults = false, string? probe = null, string? jobId = null, bool startup = false, bool freeDefault = false, IReadOnlyCollection<string>? accept = null)
    {
        if (operation is not ("setup" or "catalog" or "keys" or "import" or "diagnostics" or "locations" or "storageOverview" or "spaceSurvey"))
            throw new ArgumentException("Unsupported library operation.", nameof(operation));
        cancellationToken.ThrowIfCancellationRequested();
        privateRoot = Path.GetFullPath(privateRoot);
        // jobId：前端作业登记先取好的任务号（控制口 /cancel 按它核对）；不给就现取
        jobId ??= "win-" + Guid.NewGuid().ToString("N");
        var payload = new Dictionary<string, object?>
        {
            ["schema"] = 1, ["jobId"] = jobId, ["operation"] = operation,
            ["privateRoot"] = privateRoot, ["library"] = Path.GetFullPath(library),
            ["engineDir"] = Path.GetFullPath(paths.Engine), ["libraryId"] = libraryId
        };
        if (selectedPaths is not null) payload["paths"] = selectedPaths;
        if (moveFrom is not null) payload["moveFrom"] = Path.GetFullPath(moveFrom);
        // 库路径规则只在作业层 setup（剃刀 W19）：带上启动器安装目录（库不能放在它里面或包含它），
        //   freeDefault = 玩家没选过位置，缺省位置被别的文件占着时由 setup 换到旁边，结果里的 library 是实际位置
        if (operation == "setup")
        {
            payload["installDir"] = Path.GetFullPath(AppContext.BaseDirectory);
            if (freeDefault) payload["freeDefault"] = true;
            // accept：玩家在换库确认里同意过的参数（v0.3.1：acceptCloud 云盘同步目录、acceptForeign 有别的文件的文件夹、acceptFormat exFAT / FAT32 盘），逐次累积
            foreach (var key in accept ?? []) payload[key] = true;
        }
        // 逐来源结果（pack/jobs/library.py import_games）：认不出的来源不挡别的，结果里带 sources（批量出包清单列出认不出的文件）
        if (partialResults && operation == "import") payload["partialResults"] = true;
        // 存放位置表另查一个刚选的文件夹所在盘会不会让解包多占数倍空间（#444，pack/jobs/library.py list_locations）
        if (probe is not null && operation == "locations") payload["probe"] = Path.GetFullPath(probe);
        // 启动器这次打开后的第一次 catalog（剃刀 H14）：作业层只在这一次清残留、判一天一次的任务目录清理
        if (startup && operation == "catalog") payload["startup"] = true;
        if (operation is "keys" or "diagnostics")
        {
            if (selectedPaths?.Count != 1) throw new ArgumentException("Choose exactly one file.");
            payload["path"] = selectedPaths[0];
        }
        using var request = PrivateJobRequest.Create(privateRoot, JsonSerializer.Serialize(payload));
        var info = EnvironmentProbe.StartInfo(paths, request.FilePath);
        info.Arguments = "/d /v:off /s /c \"\"%S2A_UI_RUNTIME%\\s2arm_env.cmd\" && cd /d \"%S2A_UI_ENGINE%\" && python -X utf8 pack/jobs/main.py run --request \"%S2A_UI_REQUEST%\"\"";
        using var forcedStop = new CancellationTokenSource();
        var running = EnvironmentProbe.RunProcessAsync(info, forcedStop.Token, 8 * 1024 * 1024);
        var interrupted = Task.Delay(Timeout.Infinite, cancellationToken);
        if (await Task.WhenAny(running, interrupted) != running)
        {
            await PackJobClient.CancelAsync(paths, request.FilePath, privateRoot, jobId);   // 同一份取消（剃刀 W17）
            // 点取消时作业恰好已经跑完：照它的真实结局走，不一律报已中断（社区贡献者补丁 #7，原先只在 PackJobClient）
            if (await Task.WhenAny(running, Task.Delay(TimeSpan.FromSeconds(3))) != running)
            {
                forcedStop.Cancel(); // Last resort only for the process tree this invocation owns.
                try { await running; }
                catch (Exception error) when (error is OperationCanceledException or IOException) { }
                throw new OperationCanceledException(cancellationToken);
            }
        }
        var output = await running;
        try { return new(LibraryJobResult.Parse(output.StandardOutput, output.ExitCode, jobId, operation), output); }
        catch (LibraryProtocolException error)
        {
            throw new LibraryProtocolException(error.Message + "\nExit: " + output.ExitCode + "\n" + output.StandardError, error);
        }
    }
}
