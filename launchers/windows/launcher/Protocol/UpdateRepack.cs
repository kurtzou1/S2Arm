// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 「更新这款」要整款重出时接着重出（#1961，同 Mac S2ArmLauncherModel+UpdateHints.swift 的口径）：
/// 作业 updateGame 结束时，update_incomplete 诊断的 facts.action 说清下一步——
/// repack = 要从原件整款重出、原件在；relinkSource = 原件也不在，先「重新添加原件…」（找回后同样接着整款重出）。
/// 前端照着做：按钮下写 T("update.repackNote")，并把这款排进「只出 iPhone、出完不装设备」的批量出包。
/// </summary>
public static class UpdateRepack
{
    /// <summary>要整款重出、原件在（诊断 update_incomplete 的 facts.action = "repack"）</summary>
    public static bool Requested(JsonElement diagnostics) => ActionOf(diagnostics) == "repack";

    /// <summary>原件不在、先找回（诊断 update_incomplete 的 facts.action = "relinkSource"）</summary>
    public static bool NeedsSource(JsonElement diagnostics) => ActionOf(diagnostics) == "relinkSource";

    private static string? ActionOf(JsonElement diagnostics)
    {
        if (diagnostics.ValueKind != JsonValueKind.Array) return null;
        foreach (var d in diagnostics.EnumerateArray())
            if (d.ValueKind == JsonValueKind.Object && d.TryGetProperty("code", out var code) && code.GetString() == "update_incomplete" &&
                d.TryGetProperty("facts", out var facts) && facts.ValueKind == JsonValueKind.Object &&
                facts.TryGetProperty("action", out var action) && action.ValueKind == JsonValueKind.String)
                return action.GetString();
        return null;
    }

    /// <summary>按钮下写不写 T("update.repackNote")：原因里有 hostAbi（宿主约定号变了，换库 / 刷程序都消不掉），
    /// 或上一次 updateGame 回了 action = repack（那时原因可能已清空、按钮变「无需更新」，同样要写）</summary>
    public static bool NoteNeeded(IEnumerable<string> reasons, bool lastRepack) =>
        lastRepack || reasons.Contains("hostAbi", StringComparer.Ordinal);

    /// <summary>整款重出排进批量出包的那一份：清单只有这款、只出 iPhone 一份、出完不装设备（同 Mac：玩家点的是「更新电脑上这份」，不连手机）</summary>
    public static WholeRepackPlan Plan(string gameId) =>
        new([gameId], new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase) { [gameId] = ["iphone"] }, InstallAfterDevice: false);
}

/// <summary>整款重出要排进批量出包的一份：GameIds 放进清单；Platforms 按款给平台；InstallAfterDevice = 出完要不要接着装到设备。</summary>
public sealed record WholeRepackPlan(IReadOnlyList<string> GameIds, IReadOnlyDictionary<string, string[]> Platforms, bool InstallAfterDevice);
