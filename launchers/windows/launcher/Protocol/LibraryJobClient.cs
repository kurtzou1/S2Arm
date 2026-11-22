// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

public sealed record LibraryJobOutput(LibraryJobResult Report, ProbeOutput Output);

public static class LibraryJobClient
{
    public static async Task<LibraryJobOutput> RunAsync(LauncherPaths paths, string privateRoot, string library,
        string? libraryId, string operation, IReadOnlyList<string>? selectedPaths, CancellationToken cancellationToken, string? moveFrom = null, bool partialResults = false, string? probe = null, string? jobId = null, bool startup = false, bool freeDefault = false, IReadOnlyCollection<string>? accept = null, IReadOnlyDictionary<string, object?>? fields = null, string? gameId = null)
    {
        // 操作名不在前端设白名单（同 PackJobClient，11-15）：原样交引擎，引擎不认识的回失败结果「不支持的任务类型。」
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
        // diagnosticsUpload（pack/jobs/diag_upload.py）：gameId / operations / summary / extra 原样进请求
        //   import：「重新添加原件…」带 expectGameId（#1961，只认这一款，选错了作业层拒、不记进库）
        if (operation is "diagnosticsUpload" or "import") foreach (var (key, value) in fields ?? new Dictionary<string, object?>()) payload[key] = value;
        JobLanguage.Stamp(payload);
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
        // 出包页 S 级优化（11-13，pack/jobs/patches.py match）：这款命中了哪些社区补丁；resources = 启动器目录（随包补丁快照 CommunityPatches/ 在这里）
        if (operation == "patchMatch")
        {
            if (string.IsNullOrEmpty(gameId)) throw new ArgumentException("patchMatch needs a game.");
            payload["gameId"] = gameId; payload["resources"] = Path.GetFullPath(AppContext.BaseDirectory);
        }
        if (operation is "keys" or "diagnostics")
        {
            if (selectedPaths?.Count != 1) throw new ArgumentException("Choose exactly one file.");
            payload["path"] = selectedPaths[0];
        }
        using var request = PrivateJobRequest.Create(privateRoot, JsonOut.Serialize(payload));
        var info = EnvironmentProbe.StartInfo(paths, request.FilePath);
        info.Arguments = "/d /v:off /s /c \"\"%S2A_UI_RUNTIME%\\s2arm_env.cmd\" && cd /d \"%S2A_UI_ENGINE%\" && python -X utf8 pack/jobs/main.py run --request \"%S2A_UI_REQUEST%\"\"";
        using var forcedStop = new CancellationTokenSource();
        var running = EnvironmentProbe.RunProcessAsync(info, forcedStop.Token, 8 * 1024 * 1024);
        var interrupted = Task.Delay(Timeout.Infinite, cancellationToken);
        var cancelRequested = false;
        if (await Task.WhenAny(running, interrupted) != running)
        {
            cancelRequested = true;
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
        LibraryJobResult report;
        try { report = LibraryJobResult.Parse(output.StandardOutput, output.ExitCode, jobId, operation); }
        catch (LibraryProtocolException error)
        {
            throw new LibraryProtocolException(error.Message + "\nExit: " + output.ExitCode + "\n" + output.StandardError, error);
        }
        // 3 秒内结束且作业自己报「已取消」= 取消生效：按取消抛给调用方（同 3 秒没结束的强停分支）。作业抢在取消前真跑完（succeeded / failed）才照真实结局返回（社区贡献者补丁 #7）。
        //   原先这里一律正常返回 state=cancelled 的结果，调用方当成「完成」处理（Windows 测试「accepted library cancellation」在任何机器上都红）
        if (cancelRequested && report.State == "cancelled") throw new OperationCanceledException(cancellationToken);
        return new(report, output);
    }
}
