// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Renderer.Dsp;
using Ryujinx.Memory;
using System;
using System.Threading;

namespace S2A.Services.Tests
{
    // 渲染按输出在途深度定节拍（AudioProcessor.S2ADepthWait，11-13 0400486024DEC000 Mac 局第 26 秒断音）。一拍 = 240 帧 = 5 ms，目标深度缺省 30 ms = 1440 帧。
    //   驱动链同宿主：兼容层（Ryujinx 自己包）→ 声音峰值包装（Exports.cs）→ 假设备（第一版只认直接会话，宿主里经两层包装深度读不到、整个修复没生效，Mac 局才看出来）。
    //   假设备按 48 kHz 墙钟消耗（在途 = 交过的 − 已播的，播不出没交的）。每「渲染」一次 = 真路径 HardwareDeviceImpl.AppendBuffer 交 240 帧，再调 Wait。
    //   时钟（11-22 门禁偶发红：④ 在负载高时红、复跑不复现）：节拍与假设备都走同一个虚拟钟（AudioProcessor.S2ATestClock），时间只在节拍「睡」时拨过去，
    //   测试线程被系统晚调度多久都不改变读数。原先用真墙钟：线程分不到 CPU 时假设备照墙钟吃帧、渲染跟不上，量到的是调度不是节拍逻辑。
    //   期望手算（不跑被测实现）。判法和墙钟长短无关（11-17：原先数 300 ms 里渲染了几次，本机负载 42 时测试线程分不到 CPU 只渲染 48 次、假红）：
    //   固定渲染次数，判「用时不少于设备吃掉这些帧要的时间」= 节拍没跑在设备前面、没空转。机器忙只会让用时更长，不会假红；空转会是零点几毫秒
    //   ① 稳态渲染 66 拍：先连续补到 1440 帧（6 拍），之后设备每 5 ms 吃 240 帧、补一拍 → 后 60 拍至少用 60 × 5 = 300 ms（取 ≥ 240 ms 留睡醒误差）；
    //      每拍交完的在途帧（取中位数） = Wait 刚放行时（刚跌破 1440）再扣睡醒误差（非实时线程约 ≤ 10 ms = 480 帧）→ 960–1920
    //   ② 稳态后线程停 60 ms（设备吃掉 2880 帧 > 在途，排空）：不扔拍（S2ASkippedPeriods 仍 0），连续补 6 拍到 ≥ 1440 帧，补满用时 < 5 ms（不等墙钟）
    //   ③ 设备交还即丢（iOS 时间轴跑前，在途永远 0）：不空转。墙钟上限 = 欠 8 拍起算、可超前深度 + 1 拍：先连续 8 + 6 + 1 = 15 拍，之后 5 ms 一拍
    //      → 渲染 75 拍至少用 60 × 5 = 300 ms（取 ≥ 240 ms；空转会是零点几毫秒）
    static class AudioDepthPaceTest
    {
        private const int Rate = 48000;

        // 虚拟钟：现在 = 累计拨过的纳秒；睡到某一刻 = 把现在拨到那一刻（只往前拨）
        private sealed class VirtualClock : AudioProcessor.IS2AClock
        {
            private long _now = 1_000_000_000L;
            public long NowNs() => Interlocked.Read(ref _now);
            public void SleepUntilNs(long untilNs) { long cur; while ((cur = Interlocked.Read(ref _now)) < untilNs && Interlocked.CompareExchange(ref _now, untilNs, cur) != cur) { } }
            public void Advance(long ns) => Interlocked.Add(ref _now, ns);
        }

        private static readonly VirtualClock Clock = new();

        private sealed class FakeSession : HardwareDeviceSessionOutputBase, IS2AOutputDepth
        {
            private readonly bool _dropAll;
            private readonly double _speed;   // 设备时钟比墙钟快多少倍（④ 1.01 = 快 1%，#1957 设备钟快于墙钟）
            private readonly long _t0 = Clock.NowNs();
            private long _given;

            public FakeSession(bool dropAll, double speed = 1.0) : base(null, SampleFormat.PcmInt16, Rate, 2)
            {
                _dropAll = dropAll;
                _speed = speed;
            }

            public long S2ABufferedFrames
            {
                get
                {
                    if (_dropAll)
                    {
                        return 0;
                    }

                    long played = (long)((Clock.NowNs() - _t0) * _speed * Rate / 1_000_000_000L);

                    lock (this)
                    {
                        // 播不出没交的：排空后墙钟照走，起点挪到现在
                        return Math.Max(0, _given - played);
                    }
                }
            }

            public override void QueueBuffer(AudioBuffer buffer)
            {
                long played = (long)((Clock.NowNs() - _t0) * _speed * Rate / 1_000_000_000L);

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

        private sealed class FakeDriver(bool dropAll, double speed = 1.0) : IHardwareDeviceDriver
        {
            private readonly ManualResetEvent _update = new(false), _pause = new(true);
            public float Volume { get; set; } = 1f;
            public static bool IsSupported => true;
            public FakeSession Session0;

            public IHardwareDeviceSession OpenDeviceSession(IHardwareDeviceDriver.Direction direction, IVirtualMemoryManager memoryManager, SampleFormat sampleFormat, uint sampleRate, uint channelCount)
            {
                var s = new FakeSession(dropAll, speed);
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

        // 渲染 n 拍 → 用时（毫秒）
        private static double RenderN(AudioProcessor p, int n, FakeSession s = null, System.Collections.Generic.List<long> depths = null)
        {
            long t = Clock.NowNs();

            for (int i = 0; i < n; i++)
            {
                Render(p);
                if (s != null) depths?.Add(s.S2ABufferedFrames);   // 每拍交完立刻记一次在途帧（判中位数，见 ①）
            }

            return (Clock.NowNs() - t) / 1e6;
        }

        [SoloTest("--audio-depth-pace")]
        private static int Check()
        {
            int bad = 0;
            AudioProcessor.S2ATestClock = Clock;

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

            // 在途帧取「每拍交完那一刻」读数的中位数（合入运维 11-15：原先只在收尾读一次，测试线程那一刻被系统晚调度十几毫秒就读到 771、同一输入先红后绿；
            //   被测性质是节拍把深度维持在目标附近，一次瞬时读数不代表它）。期望区间不变：每拍交完 ≈ 目标 1440 ± 一拍 → 960–1920
            var depths = new System.Collections.Generic.List<long>();
            double ms1 = RenderN(p, 66, drv.Session0, depths);
            depths.Sort();
            long b1 = depths.Count > 0 ? depths[depths.Count / 2] : -1;
            Row("① 稳态渲染 66 拍用时（不跑在设备前面）", "≥ 240 ms", $"{ms1:F1} ms", ms1 >= 240);
            Row("① 稳态每拍交完的在途帧中位数", "960–1920", $"{b1}（{depths.Count} 拍，最小 {(depths.Count > 0 ? depths[0] : -1)}、最大 {(depths.Count > 0 ? depths[^1] : -1)}）", b1 >= 960 && b1 <= 1920);

            Clock.Advance(60_000_000L);
            long b2 = drv.Session0.S2ABufferedFrames;
            long t = Clock.NowNs();
            int n2 = 0;

            while (drv.Session0.S2ABufferedFrames < 1440 && n2 < 100)
            {
                Render(p);
                n2++;
            }

            double fillMs = (Clock.NowNs() - t) / 1e6;
            Row("② 停 60 ms 后在途", "0", b2.ToString(), b2 == 0);
            Row("② 补满 1440 帧的渲染次数", "6–7", n2.ToString(), n2 >= 6 && n2 <= 7);
            Row("② 补满用时", "< 5 ms", $"{fillMs:F2} ms", fillMs < 5);
            long skipped = Interlocked.Read(ref AudioProcessor.S2ASkippedPeriods);
            Row("② 扔拍数", "0", skipped.ToString(), skipped == 0);

            p.Stop();
            chain.Dispose();   // 声音峰值驱动同一时刻只许一个（宿主每局一个）

            var drv3 = new FakeDriver(true);
            var p3 = new AudioProcessor();
            IHardwareDeviceDriver chain3 = Chain(drv3);
            p3.Start(chain3);
            double ms3 = RenderN(p3, 75);
            Row("③ 交还即丢渲染 75 拍用时（不空转）", "≥ 240 ms", $"{ms3:F1} ms", ms3 >= 240);
            p3.Stop();
            chain3.Dispose();

            // ④ #1957 设备钟比墙钟快：渲染被墙钟上限压着时在途一路被吃光（那局 3 小时后零在途、爆音）。上限给的余量 = 目标 30 ms + 1 拍 + 欠 8 拍 ≈ 75 ms，
            //   设备快 2% 时约 3.75 秒吃光。渲染 1400 拍（约 7 秒，设备多吃约 140 ms > 75 ms）：期望最后 100 拍交完的在途中位数 ≥ 240、追设备拍数 > 0
            //   （不到目标一半时越过上限追设备，每 32 拍至多 1 拍 = +3.1% > 2%）；负控：改前的节拍（没有追设备）同一序列最后 100 拍中位数 = 240 以下（被吃光，只剩刚交的一拍）
            var drv4 = new FakeDriver(false, 1.02);
            var p4 = new AudioProcessor();
            IHardwareDeviceDriver chain4 = Chain(drv4);
            p4.Start(chain4);
            Interlocked.Exchange(ref AudioProcessor.S2ACatchUps, 0);
            var d4 = new System.Collections.Generic.List<long>();
            RenderN(p4, 1300, drv4.Session0);
            RenderN(p4, 100, drv4.Session0, d4);
            d4.Sort();
            long m4 = d4.Count > 0 ? d4[d4.Count / 2] : -1;
            long cu4 = Interlocked.Read(ref AudioProcessor.S2ACatchUps);
            Row("④ 设备钟快 2%、渲染 1400 拍后最后 100 拍在途中位数", "≥ 240（追设备，不被吃光）", $"{m4}（追设备 {cu4} 拍）", m4 >= 240 && cu4 > 0);
            p4.Stop();
            chain4.Dispose();

            AudioProcessor.S2ATestClock = null;
            return bad == 0 ? 0 : 1;
        }
    }
}
