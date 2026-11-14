// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Memory;
using System;
using System.Diagnostics;
using System.Threading;

namespace S2A.Services.Tests
{
    // 渲染按输出在途深度定节拍（AudioProcessor.S2ADepthWait，11-13 0400486024DEC000 Mac 局第 26 秒断音）。一拍 = 240 帧 = 5 ms，目标深度缺省 30 ms = 1440 帧。
    //   驱动链同宿主：兼容层（Ryujinx 自己包）→ 声音峰值包装（Exports.cs）→ 假设备（第一版只认直接会话，宿主里经两层包装深度读不到、整个修复没生效，Mac 局才看出来）。
    //   假设备按 48 kHz 墙钟消耗（在途 = 交过的 − 已播的，播不出没交的）。每「渲染」一次 = 真路径 HardwareDeviceImpl.AppendBuffer 交 240 帧，再调 Wait。
    //   期望手算（不跑被测实现）：
    //   ① 稳态 300 ms：先连续补到 1440 帧（6 拍），之后设备每 5 ms 吃 240 帧、补一拍 → 渲染 6 + 60 = 66 次（取 58–74）；收尾在途 = Wait 刚放行时（刚跌破 1440）再扣睡醒误差（非实时线程约 ≤ 10 ms = 480 帧）→ 960–1920
    //   ② 稳态后线程停 60 ms（设备吃掉 2880 帧 > 在途，排空）：不扔拍（S2ASkippedPeriods 仍 0），连续补 6 拍到 ≥ 1440 帧，补满用时 < 5 ms（不等墙钟）
    //   ③ 设备交还即丢（iOS 时间轴跑前，在途永远 0）：不空转。墙钟上限 = 欠 8 拍起算、可超前深度 + 1 拍：先连续 8 + 6 + 1 = 15 拍，之后 5 ms 一拍
    //      → 300 ms 共 15 + 60 = 75 次（取 60–85；空转会是成千上万次）
    static class AudioDepthPaceTest
    {
        private const int Rate = 48000;

        private sealed class FakeSession : HardwareDeviceSessionOutputBase, IS2AOutputDepth
        {
            private readonly bool _dropAll;
            private readonly long _t0 = Stopwatch.GetTimestamp();
            private long _given;

            public FakeSession(bool dropAll) : base(null, SampleFormat.PcmInt16, Rate, 2)
            {
                _dropAll = dropAll;
            }

            public long S2ABufferedFrames
            {
                get
                {
                    if (_dropAll)
                    {
                        return 0;
                    }

                    long played = (Stopwatch.GetTimestamp() - _t0) * Rate / Stopwatch.Frequency;

                    lock (this)
                    {
                        // 播不出没交的：排空后墙钟照走，起点挪到现在
                        return Math.Max(0, _given - played);
                    }
                }
            }

            public override void QueueBuffer(AudioBuffer buffer)
            {
                long played = (Stopwatch.GetTimestamp() - _t0) * Rate / Stopwatch.Frequency;

                lock (this)
                {
                    _given = Math.Max(_given, played) + (long)buffer.DataSize / 4;
                }
            }

            public override void Dispose() { }
            public override void PrepareToClose() { }
            public override void SetVolume(float volume) { }
            public override float GetVolume() => 1f;
            public override void Start() { }
            public override void Stop() { }
            public override ulong GetPlayedSampleCount() => 0;
            public override bool WasBufferFullyConsumed(AudioBuffer buffer) => true;
        }

        private sealed class FakeDriver(bool dropAll) : IHardwareDeviceDriver
        {
            private readonly ManualResetEvent _update = new(false), _pause = new(true);
            public float Volume { get; set; } = 1f;
            public static bool IsSupported => true;
            public FakeSession Session0;

            public IHardwareDeviceSession OpenDeviceSession(IHardwareDeviceDriver.Direction direction, IVirtualMemoryManager memoryManager, SampleFormat sampleFormat, uint sampleRate, uint channelCount)
            {
                var s = new FakeSession(dropAll);
                Session0 ??= s;
                return s;
            }

            public ManualResetEvent GetUpdateRequiredEvent() => _update;
            public ManualResetEvent GetPauseEvent() => _pause;
            public bool SupportsDirection(IHardwareDeviceDriver.Direction direction) => true;
            public bool SupportsSampleRate(uint sampleRate) => true;
            public bool SupportsSampleFormat(SampleFormat sampleFormat) => true;
            public bool SupportsChannelCount(uint channelCount) => channelCount == 2;
            public void Dispose() { }
        }

        private static IHardwareDeviceDriver Chain(IHardwareDeviceDriver real) =>
            new Ryujinx.Audio.Backends.CompatLayer.CompatLayerHardwareDeviceDriver(new S2A.Services.AudioPeakDriver(real));

        private static readonly short[] Period = new short[240 * 2];

        // 渲染一拍（只喂会话 0，同游戏只开一个渲染器）再按节拍等
        private static void Render(AudioProcessor p)
        {
            p.OutputDevices[0].AppendBuffer(Period, 2);
            p.Wait();
        }

        private static int RenderFor(AudioProcessor p, long ms)
        {
            long end = Stopwatch.GetTimestamp() + ms * Stopwatch.Frequency / 1000;
            int n = 0;

            while (Stopwatch.GetTimestamp() < end)
            {
                Render(p);
                n++;
            }

            return n;
        }

        [SoloTest("--audio-depth-pace")]
        private static int Check()
        {
            int bad = 0;

            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 渲染按深度定节拍 {name}：{expect} → {actual}");
            }

            var drv = new FakeDriver(false);
            var p = new AudioProcessor();
            IHardwareDeviceDriver chain = Chain(drv);
            p.Start(chain);
            Interlocked.Exchange(ref AudioProcessor.S2ASkippedPeriods, 0);

            int n1 = RenderFor(p, 300);
            long b1 = drv.Session0.S2ABufferedFrames;
            Row("① 稳态 300 ms 渲染次数", "58–74", n1.ToString(), n1 >= 58 && n1 <= 74);
            Row("① 稳态收尾在途帧", "960–1920", b1.ToString(), b1 >= 960 && b1 <= 1920);

            Thread.Sleep(60);
            long b2 = drv.Session0.S2ABufferedFrames;
            long t = Stopwatch.GetTimestamp();
            int n2 = 0;

            while (drv.Session0.S2ABufferedFrames < 1440 && n2 < 100)
            {
                Render(p);
                n2++;
            }

            double fillMs = (Stopwatch.GetTimestamp() - t) * 1000.0 / Stopwatch.Frequency;
            Row("② 停 60 ms 后在途", "0", b2.ToString(), b2 == 0);
            Row("② 补满 1440 帧的渲染次数", "6–7", n2.ToString(), n2 >= 6 && n2 <= 7);
            Row("② 补满用时", "< 5 ms", $"{fillMs:F2} ms", fillMs < 5);
            long skipped = Interlocked.Read(ref AudioProcessor.S2ASkippedPeriods);
            Row("② 扔拍数", "0", skipped.ToString(), skipped == 0);

            p.Stop();
            chain.Dispose();   // 声音峰值驱动同一时刻只许一个（宿主每局一个）

            var drv3 = new FakeDriver(true);
            var p3 = new AudioProcessor();
            p3.Start(Chain(drv3));
            int n3 = RenderFor(p3, 300);
            Row("③ 交还即丢 300 ms 渲染次数（不空转）", "60–85", n3.ToString(), n3 >= 60 && n3 <= 85);

            return bad == 0 ? 0 : 1;
        }
    }
}
