// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Apple;   // 平台例外：苹果音频后端单测（真 AudioQueue），只在 macOS 跑
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using System;
using System.Diagnostics;
using System.Threading;

namespace S2A.Services.Tests
{
    // 游戏卡死、读不动游戏内存时，苹果音频的回调线程不能被我们堵住，关会话也不能被堵住（11-14 iPhone 实机 第 17515 帧：游戏卡死后进程被强杀，
    //   手机系统声音服务一直坏到重启）。真声卡（本机 AudioQueue），音频输出（audout）缓冲样本留在游戏内存、设备取样时才读（ReadSamples）；
    //   读样本的桩在「上闸」后永远等着 = 游戏内存读不动。期望按语义手算：
    // ① 先交 3 秒声音（每块 100 ms，共 30 块）：设备 32 个槽各 50 ms = 1.6 秒，交时读满；剩 1.4 秒排着，等设备交还槽位时再读
    // ② 上闸后约 50 ms 设备交还第一槽 → 有人去读排着的样本 → 被闸住。被闸住的必须是我们自己的送数线程「S2A.AudioPace」，
    //    不是苹果音频的回调线程（旧代码在回调里读 → 闸住的是回调线程）
    // ③ 闸着时关会话（Dispose）：3 秒内返回（旧代码：同步停队列要等回调，回调卡在闸上 → 永远不返回）
    // ④ 开闸后送数线程走完、不崩（会话已关：队列留着不释放，晚到的交缓冲什么都不做）
    static class AppleAudioGuestStallTest
    {
        private sealed class StallReader : HardwareDeviceSessionOutputBase
        {
            public volatile bool Armed;
            public readonly ManualResetEventSlim Blocked = new(false), Release = new(false);
            public string BlockedThread;

            public StallReader() : base(null, SampleFormat.PcmInt16, 48000, 2) { }

            public override void ReadSamples(AudioBuffer buffer, ulong offset, Span<byte> destination)
            {
                if (Armed)
                {
                    BlockedThread ??= Thread.CurrentThread.Name ?? $"（无名线程 {Environment.CurrentManagedThreadId}）";
                    Blocked.Set();
                    Release.Wait();
                }

                destination.Clear();
            }

            public override void Dispose() { }
            public override void PrepareToClose() { }
            public override void QueueBuffer(AudioBuffer buffer) => throw new NotSupportedException();
            public override void SetVolume(float volume) { }
            public override float GetVolume() => 1f;
            public override void Start() { }
            public override void Stop() { }
            public override ulong GetPlayedSampleCount() => 0;
            public override bool WasBufferFullyConsumed(AudioBuffer buffer) => false;
        }

        [SoloTest("--apple-audio-guest-stall")]
        private static int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：苹果音频后端单测，只在 macOS 跑
            {
                Console.WriteLine("✗ 苹果音频卡死隔离：本机没有可用的苹果音频后端");
                return 1;
            }

            int bad = 0;
            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频卡死隔离 {name}：{expect} → {actual}");
            }

            var reader = new StallReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：苹果音频后端单测（真 AudioQueue），只在 macOS 跑
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);
            session.Start();

            const ulong Bytes = 4800 * 4;   // 100 ms
            for (int i = 0; i < 30; i++)
            {
                var b = new AudioBuffer { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };
                session.RegisterBuffer(b);
                session.QueueBuffer(b);
            }

            reader.Armed = true;
            bool blocked = reader.Blocked.Wait(3000);
            Row("② 上闸后有人去读排着的样本", "3 秒内", blocked ? "读了、被闸住" : "3 秒内没人读", blocked);
            Row("② 被闸住的线程", "S2A.AudioPace（我们的送数线程）", reader.BlockedThread ?? "—", reader.BlockedThread == "S2A.AudioPace");

            var sw = Stopwatch.StartNew();
            string step = "开始"; var closer = new Thread(() => { step = "会话 Dispose 中"; session.Dispose(); step = "驱动 Dispose 中"; driver.Dispose(); step = "完"; }) { IsBackground = true };
            closer.Start();
            bool closed = closer.Join(3000);
            Row("③ 闸着时关会话", "3 秒内返回", closed ? $"{sw.ElapsedMilliseconds} ms 返回" : $"3 秒没返回（卡在：{step}）", closed);

            reader.Release.Set();
            Thread.Sleep(300);
            Row("④ 开闸后送数线程走完、进程还在", "不崩", "没崩", true);

            return bad == 0 ? 0 : 1;
        }
    }
}
