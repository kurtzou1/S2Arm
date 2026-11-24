// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// <summary>「打开 Impactor」前怎么对待机器上已有的 Impactor（D-W2H5，Windows 0.6.9）：Impactor 只许一个实例，已有一个在跑时新拉起的打一句
/// 「Another instance is already running; exiting.」就退出——那个在跑的若窗口没出来（卡在后台 / 托盘），玩家点「打开 Impactor」、直接点 exe 都没反应，
/// 一直登录不了，装机报 apple_not_signed_in。判法纯数据，窗口与进程操作在 App（ExportPages.cs TryOpenBundledImpactor）</summary>
public static class ImpactorInstance
{
    public enum Step { Launch, Focus, RestartOwn, AskClose }

    /// <param name="Path">进程映像路径（读不到为空串）</param><param name="HasWindow">有主窗口句柄</param><param name="Name">进程名（给玩家看的）</param>
    public sealed record Running(string Path, bool HasWindow, string Name);

    public const string AlreadyRunningLine = "Another instance is already running";

    /// <summary>进程名像 Impactor（随包的 Impactor-windows-x86_64-portable、装的 plumeimpactor / Impactor）</summary>
    public static bool IsImpactorName(string processName) => processName.Contains("impactor", StringComparison.OrdinalIgnoreCase);

    /// <summary>没有在跑的 → 照常启动；有带窗口的 → 把它调到前台（随包那份优先）；只有随包那份、没窗口 → 结束它重开（只动随包 exe 自己，按完整路径认）；
    /// 只有别的副本、没窗口 → 请玩家在任务管理器里结束它（不替玩家结束不是我们装的程序）</summary>
    public static (Step Step, Running? Target) Decide(IReadOnlyList<Running> running, string bundledPath)
    {
        if (running.Count == 0) return (Step.Launch, null);
        bool Own(Running r) => r.Path.Length > 0 && string.Equals(System.IO.Path.GetFullPath(r.Path), System.IO.Path.GetFullPath(bundledPath), StringComparison.OrdinalIgnoreCase);
        var shown = running.Where(r => r.HasWindow).OrderByDescending(Own).FirstOrDefault();
        if (shown is not null) return (Step.Focus, shown);
        var own = running.FirstOrDefault(Own);
        if (own is not null && running.All(Own)) return (Step.RestartOwn, own);
        return (Step.AskClose, running.First(r => !Own(r)));
    }

    /// <summary>新拉起的 Impactor 日志里有「已有实例、退出」那句（启动后追加的那一段）</summary>
    public static bool SaysAlreadyRunning(string appendedLog) => appendedLog.Contains(AlreadyRunningLine, StringComparison.Ordinal);
}
