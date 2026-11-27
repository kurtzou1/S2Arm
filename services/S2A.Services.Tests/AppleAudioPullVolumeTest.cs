// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Apple;   // 平台例外：苹果音频后端单测（真 AudioUnit 拉取），只在 macOS 跑
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using System;
using System.Diagnostics;
using System.Threading;

namespace S2A.Services.Tests
{
    // #2157 只留一种传输：播放中途改音量。音量在 pace 线程写环前逐块生效（ApplyVolume，供给侧时机：
    //   中途改音量只影响之后写入的块，回调内零音量运算）。期望按语义手算（真声卡、2ch、每块 100 ms、排着 4 秒声音）：
    // ① 会话类型 = ApplePullHardwareDeviceSession
    // ② 播放中途 SetVolume 两次（0.25 → 0.75）：GetVolume 读回最后设的值
    // ③ 流不断：两次改音量前后各播 1 秒，三段每段播完涨 ≥ 48000 帧（15 秒为卡死上限）；全程无异常（改音量在 pace 侧、不碰回调）
    static class AppleAudioPullVolumeTest
    {
        private sealed class ToneReader : HardwareDeviceSessionOutputBase
        {
            public ToneReader() : base(null, SampleFormat.PcmInt16, 48000, 2) { }

            public override void ReadSamples(AudioBuffer buffer, ulong offset, Span<byte> destination) => destination.Fill(0x10);
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

        [SoloTest("--apple-audio-pull-volume")]
        private static int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：苹果音频后端单测，只在 macOS 跑
            {
                Console.WriteLine("✗ 苹果音频拉取中途改音量：本机没有可用的苹果音频后端");
                return 1;
            }

            int bad = 0;
            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频拉取改音量 {name}：{expect} → {actual}");
            }

            var reader = new ToneReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：苹果音频后端单测（真 AudioUnit 拉取），只在 macOS 跑
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);

            Row("① 会话类型", "ApplePullHardwareDeviceSession", session.GetType().Name, session is ApplePullHardwareDeviceSession);

            session.Start();

            const ulong Bytes = 4800 * 4;   // 100 ms
            for (int i = 0; i < 40; i++)
            {
                var b = new AudioBuffer { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };
                session.RegisterBuffer(b);
                session.QueueBuffer(b);
            }

            ulong WaitPlayed(ulong floor, int ms)
            {
                var sw = Stopwatch.StartNew();
                ulong p = session.GetPlayedSampleCount();
                while (p < floor && sw.ElapsedMilliseconds < ms) { Thread.Sleep(20); p = session.GetPlayedSampleCount(); }
                return p;
            }

            ulong p1 = WaitPlayed(48000, 15000);
            session.SetVolume(0.25f);
            ulong p2 = WaitPlayed(p1 + 48000, 15000);
            session.SetVolume(0.75f);
            ulong p3 = WaitPlayed(p2 + 48000, 15000);

            Row("② 改音量读回", "GetVolume = 0.75（最后设的值）", $"{session.GetVolume()}", Math.Abs(session.GetVolume() - 0.75f) < 0.001f);
            Row("③ 流不断", "三段各 ≥ 48000 帧（1 秒/段）", $"{p1} / {p2 - p1} / {p3 - p2} 帧", p1 >= 48000 && p2 - p1 >= 48000 && p3 - p2 >= 48000);

            session.Dispose(); driver.Dispose();
            return bad == 0 ? 0 : 1;
        }
    }
}
