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
    //   ⑤⑥ 在途高于目标时退设备（11-27 落地声晚约半秒）：上限照墙钟一拍一拍地渲染，设备少播的部分（卡顿、设备钟慢）永远留在在途里。见 ⑤⑥ 处
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
            private long _lostNs;   // ⑥ 卡顿：这段时间设备没播（回调晚到 / 载入卡住），已播帧数少算这么多

            public void Hiccup(long ns) { lock (this) { _lostNs += ns; } }

            private long Played() => (long)((Clock.NowNs() - _t0 - Interlocked.Read(ref _lostNs)) * _speed * Rate / 1_000_000_000L);

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

                    long played = Played();

                    lock (this)
                    {
                        // 播不出没交的：排空后墙钟照走，起点挪到现在
                        return Math.Max(0, _given - played);
                    }
                }
            }

            public override void QueueBuffer(AudioBuffer buffer)
            {
                long played = Played();

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

            // ⑤ 设备钟比墙钟慢 2%（④ 的反方向）：渲染照墙钟时每秒多出 960 帧、永远排不掉。渲染 1400 拍（约 7 秒）：改前在途一路涨到约
            //   1440 + 0.02 × 7 s × 48000 ≈ 8160 帧；改后在途高于目标 + 2 拍（1920 帧）时每 32 拍多等一拍（−3.1% > 2%）→ 最后 100 拍交完的在途中位数
            //   ≤ 1440 + 2 × 240 + 480（睡醒误差）= 2400、退设备拍数 > 0
            var drv5 = new FakeDriver(false, 0.98);
            var p5 = new AudioProcessor();
            IHardwareDeviceDriver chain5 = Chain(drv5);
            p5.Start(chain5);
            Interlocked.Exchange(ref AudioProcessor.S2ADrains, 0);
            var d5 = new System.Collections.Generic.List<long>();
            RenderN(p5, 1300, drv5.Session0);
            RenderN(p5, 100, drv5.Session0, d5);
            d5.Sort();
            long m5 = d5.Count > 0 ? d5[d5.Count / 2] : -1;
            long dr5 = Interlocked.Read(ref AudioProcessor.S2ADrains);
            Row("⑤ 设备钟慢 2%、渲染 1400 拍后最后 100 拍在途中位数", "≤ 2400（退设备，不越积越多）", $"{m5}（退设备 {dr5} 拍）", m5 >= 0 && m5 <= 2400 && dr5 > 0);
            p5.Stop();
            chain5.Dispose();

            // ⑥ 稳态后设备卡顿 100 ms 没播（11-27 那局一次载入少播约 3400 帧，在途从约 2500 跳到排满、此后不降）：在途 +4800 帧。改前此后渲染照墙钟，
            //   在途停在约 1440 + 4800 = 6240；改后高出的部分按每秒约 48000 × 3.1% ≈ 1500 帧排掉，约 3.2 秒回到目标附近。卡顿后渲染 1000 拍（约 5 秒）：
            //   卡顿刚过的在途 ≥ 5000（确认卡顿生效）、最后 100 拍交完的在途中位数 ≤ 2400、全程不扔拍
            var drv6 = new FakeDriver(false);
            var p6 = new AudioProcessor();
            IHardwareDeviceDriver chain6 = Chain(drv6);
            p6.Start(chain6);
            Interlocked.Exchange(ref AudioProcessor.S2ASkippedPeriods, 0);
            RenderN(p6, 200, drv6.Session0);
            drv6.Session0.Hiccup(100_000_000L);
            long b6 = drv6.Session0.S2ABufferedFrames;
            var d6 = new System.Collections.Generic.List<long>();
            RenderN(p6, 900, drv6.Session0);
            RenderN(p6, 100, drv6.Session0, d6);
            d6.Sort();
            long m6 = d6.Count > 0 ? d6[d6.Count / 2] : -1;
            long sk6 = Interlocked.Read(ref AudioProcessor.S2ASkippedPeriods);
            Row("⑥ 卡顿 100 ms 刚过的在途", "≥ 5000", b6.ToString(), b6 >= 5000);
            Row("⑥ 卡顿后渲染 1000 拍、最后 100 拍在途中位数", "≤ 2400（多出的在途排掉）", m6.ToString(), m6 >= 0 && m6 <= 2400);
            Row("⑥ 扔拍数", "0", sk6.ToString(), sk6 == 0);
            p6.Stop();
            chain6.Dispose();

            // ⑦ 退设备一次至多一拍（#2300 复审）：额度最多攒 4 个，平时在目标附近不用、攒满。卡顿 100 ms 后的第一拍若在同一次 Wait 里连退 4 次，
            //   要到原定时刻后约 8 拍才渲染。稳态 200 拍（> 4 × 32，攒满）后卡顿，记卡顿后每一拍 Wait 的用时与该拍退设备次数：
            //   期望每拍至多退 1 次、最长一拍用时 ≤ 5 拍 = 25 ms（上限 4 拍 + 退 1 拍）；负控：不限次数时第一拍退 4 次、用时 35 ms（#2300 复审前的实现实测）
            var drv7 = new FakeDriver(false);
            var p7 = new AudioProcessor();
            IHardwareDeviceDriver chain7 = Chain(drv7);
            p7.Start(chain7);
            RenderN(p7, 200, drv7.Session0);
            drv7.Session0.Hiccup(100_000_000L);
            double maxWait7 = 0;
            long maxDrain7 = 0;

            for (int i = 0; i < 40; i++)
            {
                long d0 = Interlocked.Read(ref AudioProcessor.S2ADrains), t0 = Clock.NowNs();
                Render(p7);
                maxWait7 = Math.Max(maxWait7, (Clock.NowNs() - t0) / 1e6);
                maxDrain7 = Math.Max(maxDrain7, Interlocked.Read(ref AudioProcessor.S2ADrains) - d0);
            }

            Row("⑦ 额度攒满后卡顿，每拍退设备次数最多", "≤ 1", maxDrain7.ToString(), maxDrain7 <= 1);
            Row("⑦ 卡顿后 40 拍里最长一拍用时", "≤ 25 ms（至多晚 5 拍）", $"{maxWait7:F1} ms", maxWait7 <= 25);
            p7.Stop();
            chain7.Dispose();

            AudioProcessor.S2ATestClock = null;
            return bad == 0 ? 0 : 1;
        }
    }
}
