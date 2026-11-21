// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

// S 级升级页「补丁是别的版本的」写哪个版本（维护者 11-15）：期望按规则手写。
public static class SGradeVersionsCases
{
    public static void Run(Action<bool, string> check)
    {
        check(SGradeVersions.Pick(["1.0.0", "1.1.0", "1.0.4"], "1.0.2") == ("1.0.4", true), "sgrade versions: nearest newer one");
        check(SGradeVersions.Pick(["1.0.0", "1.2.0"], "1.3.0") == ("1.2.0", false), "sgrade versions: only older ones -> the newest older one, no downgrade advice");
        check(SGradeVersions.Pick(["1.10"], "1.9") == ("1.10", true), "sgrade versions: compared by segment (1.10 > 1.9)");
        check(SGradeVersions.Pick([], "1.0") is null, "sgrade versions: nothing to say");
        // S 级升级进度（玩家报修 D-QNA9）：事件先给整款 0.6，再来一条段内计数器的普通 progress（1/10）不认；轮询慢一拍的 0.5 不回退
        using (var counter = System.Text.Json.JsonDocument.Parse("{\"type\":\"progress\",\"done\":1,\"total\":10}"))
            check(SGradeLiveProgress.FromEvent(counter.RootElement) is null, "sgrade progress: a stage counter's done / total is not the game's progress");
        using (var whole = System.Text.Json.JsonDocument.Parse("{\"done\":1,\"total\":10,\"sgradeProgress\":0.65}"))
            check(SGradeLiveProgress.FromEvent(whole.RootElement) == 0.65, "sgrade progress: sgradeProgress is the game's progress");
        check(SGradeLiveProgress.Running(0.5, "running", 0.6) == 0.6, "sgrade progress: a late poll does not go back");
        check(SGradeLiveProgress.Running(0.7, "running", 0.6) == 0.7, "sgrade progress: moves forward");
        check(SGradeLiveProgress.Running(null, "running", 0.7) == 0.7, "sgrade progress: no reading keeps the running value");
        check(SGradeLiveProgress.Running(0.1, "done", 1.0) == 0.1, "sgrade progress: a new run starts from its own reading");
    }
}
