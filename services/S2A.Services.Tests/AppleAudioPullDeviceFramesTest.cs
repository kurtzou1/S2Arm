// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Apple;   // 平台例外：苹果音频后端的环容量 / 配速水位派生（纯函数，不碰设备，各平台都能跑）
using System;

namespace S2A.Services.Tests
{
    // D-BEKN（#2157 评审 #15，玩家 #1308 的 Mac M4 内置扬声器）：设备 IO 周期 4096 帧（≈85 ms）下，拉取环固定 1024 帧
    //   （≈21.3 ms）一次回调不够拿、每拍欠载出爆音。判定 ApplePullHardwareDeviceSession.S2ADeriveRingFrames /
    //   S2ADeriveDepthFrames（环 = 下一 2 的幂 ≥ max(1024, IO×2)；水位 = min(环, IO + 1/4 IO + 1024)）。期望按语义手算：
    // ① IO 读不到（0）：环按缺省 1024，水位 0（不抬高，AudioProcessor 用自己的 30 ms 地板）
    // ② IO 512（小设备）：环 1024——与固定 1024 的旧行为逐字节一致；水位截在环容量 1024
    // ③ IO 1024：环 2048，水位 2304 截在环容量 2048（上限生效）
    // ④ IO 4096（D-BEKN 那台）：环 8192，水位 6144——一个 IO 周期再加 1/4 周期 + 1024 帧余量，回调拿走 4096 帧后不欠载
    // ⑤ IO 5120（非 2 的幂）：环 16384（下一 2 的幂 ≥ 2×IO），水位 7424
    static class AppleAudioPullDeviceFramesTest
    {
        [SoloTest("--apple-audio-device-frames")]
        private static int Check()
        {
            int bad = 0;
            void Row(string name, int expectRing, int expectDepth, int io)
            {
                int ring = ApplePullHardwareDeviceSession.S2ADeriveRingFrames(io);
                int depth = ApplePullHardwareDeviceSession.S2ADeriveDepthFrames(io, ring);
                bool ok = ring == expectRing && depth == expectDepth;
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 环自适应 {name}：IO {io} 帧 → 环 {expectRing} / 水位 {expectDepth} → 实际 环 {ring} / 水位 {depth}");
            }

            Row("① IO 读不到", 1024, 0, 0);
            Row("② IO 512（旧行为不变）", 1024, 1024, 512);
            Row("③ IO 1024（水位截在环容量）", 2048, 2048, 1024);
            Row("④ IO 4096（D-BEKN 那台）", 8192, 6144, 4096);
            Row("⑤ IO 5120（非 2 的幂）", 16384, 7424, 5120);

            // 兜底核对：水位要么为 0（IO 读不到），要么 ≥ 一个 IO 周期（回调拿走一整拍后环内不欠载的前提）
            for (int io = 1; io <= 65536; io += 517)
            {
                int ring = ApplePullHardwareDeviceSession.S2ADeriveRingFrames(io);
                int depth = ApplePullHardwareDeviceSession.S2ADeriveDepthFrames(io, ring);

                if (depth != 0 && depth < io)
                {
                    bad++;
                    Console.WriteLine($"✗ 环自适应 兜底：IO {io} → 水位 {depth} < 一个 IO 周期");
                }
            }

            Console.WriteLine(bad == 0 ? "环自适应 派生全部符合" : $"环自适应 派生有 {bad} 行不符");
            return bad == 0 ? 0 : 1;
        }
    }
}
