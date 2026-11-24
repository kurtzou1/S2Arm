// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// #1961「更新这款」要整款重出时接着重出：作业 updateGame 的 update_incomplete 诊断带 facts.action，
// 前端照着排进「只出 iPhone、出完不装设备」的整款重出，并在按钮下写 update.repackNote。
// 期望值手写自作业层（pack/jobs/install.py refresh_local）与 Mac 前端同一口径（S2ArmLauncherModel+UpdateHints.swift），不照 C# 实现反推。
public static class UpdateRepackCases
{
    private static JsonElement J(string json) => JsonDocument.Parse(json).RootElement.Clone();

    public static void Run(Action<bool, string> check)
    {
        // ---- 诊断里的下一步：repack / relinkSource / 没有 / 形状不对 ----
        var repack = J("""[{"severity":"warning","code":"update_incomplete","summary":"要整款重新出包","facts":{"action":"repack"}}]""");
        check(UpdateRepack.Requested(repack) && !UpdateRepack.NeedsSource(repack), "diagnostics: facts.action = repack → whole rebuild, source is here");
        var relink = J("""[{"severity":"warning","code":"update_incomplete","summary":"原件也不在","facts":{"action":"relinkSource"}}]""");
        check(!UpdateRepack.Requested(relink) && UpdateRepack.NeedsSource(relink), "diagnostics: facts.action = relinkSource → ask for the original, no rebuild yet");
        var plain = J("""[{"severity":"warning","code":"update_incomplete","summary":"没装工具"}]""");
        check(!UpdateRepack.Requested(plain) && !UpdateRepack.NeedsSource(plain), "diagnostics: a warning without action asks for nothing");
        var other = J("""[{"code":"update_incomplete","facts":{"action":"somethingElse"}}]""");
        check(!UpdateRepack.Requested(other) && !UpdateRepack.NeedsSource(other), "diagnostics: an unknown action is ignored");
        // 别的诊断码带同名 facts 不算：只认 update_incomplete
        var wrongCode = J("""[{"code":"devcert","facts":{"action":"repack"}}]""");
        check(!UpdateRepack.Requested(wrongCode), "diagnostics: only update_incomplete may request a rebuild");
        check(!UpdateRepack.Requested(J("{}")) && !UpdateRepack.Requested(J("[]")) && !UpdateRepack.Requested(J("""[{"code":"update_incomplete","facts":"repack"}]""")),
            "diagnostics: non-array or non-object facts → no rebuild");
        check(!UpdateRepack.Requested(J("""[{"code":"update_incomplete","facts":{"action":true}}]""")), "diagnostics: non-textual action → no rebuild");

        // ---- 按钮下的小字：原因含 hostAbi，或上一次更新回了 repack ----
        check(!UpdateRepack.NoteNeeded(["shader"], false), "note: only a shader chain left → no whole-rebuild note");
        check(UpdateRepack.NoteNeeded(["hostAbi", "shader"], false), "note: hostAbi in the reasons → whole-rebuild note");
        check(!UpdateRepack.NoteNeeded([], false), "note: no reason and no last repack → nothing");
        check(UpdateRepack.NoteNeeded([], true), "note: last update returned repack → note stays even after the reasons clear");

        // ---- 排进批量出包的那一份：只有这款、只出 iPhone、出完不装设备 ----
        var plan = UpdateRepack.Plan("0100A00000000000");
        check(plan.GameIds.Count == 1 && plan.GameIds[0] == "0100A00000000000", "plan: only this game goes into the batch");
        check(plan.Platforms.Count == 1 && plan.Platforms.TryGetValue("0100A00000000000", out var platforms) &&
              platforms is ["iphone"], "plan: iPhone only");
        check(!plan.InstallAfterDevice, "plan: a whole rebuild is packed, not installed on a device");

        // ---- 接线：updateGame 结果 / 找回原件成功都走同一处重出；按钮下的小字挂在游戏库大卡上 ----
        string Source(string file) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "AppSource", file));
        var flow = Source("ExportFlow.cs");
        check(flow.Contains("UpdateRepack.Plan("), "wiring: the whole rebuild uses the shared plan (one game, iPhone only, no install)");
        string Body(string name, string file = "ExportFlow.cs")
        {
            var src = Source(file);
            var start = src.IndexOf(name, StringComparison.Ordinal);
            if (start < 0) return "";
            var end = src.IndexOf("\n    }", start, StringComparison.Ordinal);
            return end < 0 ? src[start..] : src[start..end];
        }
        var acceptUpdate = Body("Task AcceptUpdateReportAsync(");
        check(acceptUpdate.Contains("UpdateRepack.Requested(") && acceptUpdate.Contains("RepackWholeGameAsync(game)"),
            "wiring: updateGame result with action = repack queues this game's whole rebuild");
        check(Body("Task UpdateGameAsync(").Contains("AcceptUpdateReportAsync(game, job.Report)"),
            "wiring: the update job result reaches the repack decision");
        var acceptRelink = Body("Task AcceptRelinkReportAsync(");
        check(acceptRelink.Contains("report.Succeeded") && acceptRelink.Contains("RepackWholeGameAsync(game)"),
            "wiring: a found original queues this game's whole rebuild");
        var repackMethod = Body("Task RepackWholeGameAsync(");
        check(repackMethod.Contains("UpdateRepack.Plan(") && repackMethod.Contains("OpenBatch(") &&
              repackMethod.Contains("batchControlPlatforms") && repackMethod.Contains("StartBatchAsync(plan.InstallAfterDevice)"),
            "wiring: the rebuild reuses OpenBatch → iPhone-only control platforms → StartBatchAsync (no install after)");
        var note = Body("Control? UpdateRepackNote(");
        check(note.Contains("UpdateRepack.NoteNeeded(") && note.Contains("\"update.repackNote\""),
            "wiring: the note line is driven by NoteNeeded and uses update.repackNote");
        var library = Source("LibraryPage.cs");
        check(library.Contains("UpdateRepackNote(hero)"), "wiring: the game page draws the whole-rebuild note under the button");
    }
}
