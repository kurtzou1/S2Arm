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
    // #2157 只留一种传输：会话层 flush 协同。服务层（Ryujinx.Audio/Common/AudioDeviceSession.cs，main 已合入的 flush 修复）在 FlushBuffers 时
    //   对 playing 缓冲走 UnregisterBuffer + Stop 路径的缓冲回收并发放回事件；拉取会话的 UnregisterBuffer = _samples.Release(buffer)
    //   （只拷未读段、放回给游戏），已进拉取环未渲染的样本照播（环拷贝语义，与 AudioQueue 档「已交设备部分照播」等价——帧数不变、环/账目/放回节奏不变）。
    //   期望按语义手算（真声卡、2ch、每块 100 ms）：
    // ① 会话类型 = ApplePullHardwareDeviceSession
    // ② 流起来：首块播完帧数涨到 ≥ 4800（0.1 秒）
    // ③ 对仍排着的块 UnregisterBuffer（= 服务层 flush 对 playing 缓冲的动作）后：已进环的样本照播——pace 在供给不断时把环补满
    //   （环容量 1024 帧），被 flush 的块留在环里的下限 = 一整环（1024 帧 ≈ 21 ms，播放信用还可再带一个 lead），
    //   播完帧数继续涨 ≥ 1024 后归静（ASQ 未读段已放回游戏、环里放完为止）
    // ④ flush 之后继续交块：链路照常放，播完帧数再涨 ≥ 4800；全程无异常
    //   负控不适用（服务层 18ae8b57 已修并已随 --audout-flush-release 在 main 固化）；本用例断言会话层等价。
    static class AppleAudioPullFlushTest
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

        [SoloTest("--apple-audio-pull-flush")]
        private static int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：苹果音频后端单测，只在 macOS 跑
            {
                Console.WriteLine("✗ 苹果音频拉取 flush 协同：本机没有可用的苹果音频后端");
                return 1;
            }

            int bad = 0;
            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频拉取 flush {name}：{expect} → {actual}");
            }

            var reader = new ToneReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：苹果音频后端单测（真 AudioUnit 拉取），只在 macOS 跑
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);

            Row("① 会话类型", "ApplePullHardwareDeviceSession", session.GetType().Name, session is ApplePullHardwareDeviceSession);

            const ulong Bytes = 4800 * 4;   // 100 ms
            AudioBuffer Mk(int i) => new() { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };

            session.Start();

            var b1 = Mk(1);
            var b2 = Mk(2);   // 仍排着的块（≈ ASQ + 环里各一段）——对它 UnregisterBuffer 模拟服务层 flush 的 playing 缓冲回收
            session.RegisterBuffer(b1);
            session.QueueBuffer(b1);
            session.RegisterBuffer(b2);
            session.QueueBuffer(b2);

            ulong WaitPlayed(ulong floor, int ms)
            {
                var sw = Stopwatch.StartNew();
                ulong p = session.GetPlayedSampleCount();
                while (p < floor && sw.ElapsedMilliseconds < ms) { Thread.Sleep(20); p = session.GetPlayedSampleCount(); }
                return p;
            }

            ulong p1 = WaitPlayed(4800, 10000);
            Row("② 流起来", "10 秒内播完涨到 ≥ 4800 帧", $"{p1} 帧", p1 >= 4800);

            session.UnregisterBuffer(b2);   // 只拷未读段放回游戏；已进环的样本照播
            ulong p3 = WaitPlayed(p1 + 1024, 5000);
            Row("③ flush 后已进环样本照播", "5 秒内播完再涨 ≥ 1024 帧（环内下限一整环）", $"{p3 - p1} 帧", p3 - p1 >= 1024);

            for (int i = 3; i < 8; i++)
            {
                var b = Mk(i);
                session.RegisterBuffer(b);
                session.QueueBuffer(b);
            }

            ulong p4 = WaitPlayed(p3 + 4800, 10000);
            Row("④ flush 之后续交照常放", "10 秒内播完再涨 ≥ 4800 帧", $"{p4 - p3} 帧", p4 - p3 >= 4800);

            session.Dispose(); driver.Dispose();
            return bad == 0 ? 0 : 1;
        }
    }
}
