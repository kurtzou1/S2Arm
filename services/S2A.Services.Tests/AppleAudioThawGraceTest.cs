// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Apple;   // 平台例外：苹果音频后端的解冻宽限判定（纯函数，不碰 AudioQueue，各平台都能跑）
using System;

namespace S2A.Services.Tests
{
    // D-HTHG（11-22）：iOS 局回前台时看门狗把后台时间当「设备没有回调」、把系统重新激活会话时一次 500 ms 的交设备当「输出队列卡死」，各重启一次输出队列。
    //   判定 AppleHardwareDeviceSession.S2AThawGraceStep（宽限 1500 ms）。期望按语义手算，时钟频率取 1000（1 tick = 1 ms）：
    // ① 从没冻结过（seq 不变、thaw 0）：不在宽限、不刷新起算点
    // ② 冻结中（frozen）：在宽限、刷新起算点（被挂起的那段不算停播）；记下的解冻时刻不动
    // ③ 解冻后第一拍（seq 从 0 变 1，now 10000）：刷新起算点、在宽限、记下解冻时刻 10000、记下 seq 1
    // ④ 解冻后 1499 ms：在宽限、不再刷新；⑤ 1500 ms：出宽限（交设备再慢照旧按 #1598 重启）
    // ⑥ 再冻结一次再解冻（seq 2，now 20000）：重新进宽限
    static class AppleAudioThawGraceTest
    {
        private static bool Step(bool frozen, long seq, ref long graceSeq, ref long thawTicks, long now, long freq, out bool rebase) =>
            AppleHardwareDeviceSession.S2AThawGraceStep(frozen, seq, ref graceSeq, ref thawTicks, now, freq, out rebase);   // 平台例外：苹果音频后端的解冻宽限判定（纯函数）

        [SoloTest("--apple-audio-thaw-grace")]
        private static int Check()
        {
            int bad = 0;
            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 解冻宽限 {name}：{expect} → {actual}");
            }

            long gs = 0, tt = 0;
            bool g = Step(false, 0, ref gs, ref tt, 5000, 1000, out bool rb);
            Row("① 从没冻结", "不宽限、不刷新", $"宽限 {g}、刷新 {rb}", !g && !rb);
            g = Step(true, 1, ref gs, ref tt, 6000, 1000, out rb);
            Row("② 冻结中", "宽限、刷新、解冻时刻仍 0", $"宽限 {g}、刷新 {rb}、解冻时刻 {tt}", g && rb && tt == 0 && gs == 0);
            g = Step(false, 1, ref gs, ref tt, 10000, 1000, out rb);
            Row("③ 解冻后第一拍", "宽限、刷新、解冻时刻 10000、seq 1", $"宽限 {g}、刷新 {rb}、解冻时刻 {tt}、seq {gs}", g && rb && tt == 10000 && gs == 1);
            g = Step(false, 1, ref gs, ref tt, 11499, 1000, out rb);
            Row("④ 解冻后 1499 ms", "宽限、不刷新", $"宽限 {g}、刷新 {rb}", g && !rb);
            g = Step(false, 1, ref gs, ref tt, 11500, 1000, out rb);
            Row("⑤ 解冻后 1500 ms", "出宽限", $"宽限 {g}、刷新 {rb}", !g && !rb);
            Step(true, 2, ref gs, ref tt, 15000, 1000, out _);
            g = Step(false, 2, ref gs, ref tt, 20000, 1000, out rb);
            Row("⑥ 再冻结再解冻", "宽限、刷新、解冻时刻 20000", $"宽限 {g}、刷新 {rb}、解冻时刻 {tt}", g && rb && tt == 20000);
            return bad == 0 ? 0 : 1;
        }
    }
}
