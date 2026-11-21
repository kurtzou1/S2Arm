// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using System.Threading;
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;

namespace S2A.Services.Tests
{
    // 声音输出回退（AudioFallback.cs，#1301 维护者选 a）。期望按规则手写：
    //   ① 建驱动抛异常 → 包着哑驱动、一条红行；② 开输出会话抛异常（鸿蒙模拟器无主音频适配器）→ 无声会话：交来即播完、计数、叫醒音频系统，一条红行；
    //   ③ 会话开得了、Start 抛异常（OHAudio start failed: -2）→ 不往上抛，改无声，同一驱动再开会话直接无声、不再报；
    //   ④ 平台报输出中途失败（ReportOutputFailure，真机掉设备）→ 已在播的会话改无声、一条红行；没有在用的驱动回 false；
    //   ⑤ 严格模式（S2A_STRICT=1）下也不中止；⑥ 正常驱动：调用全部透传、不报红。
    static class AudioFallbackTest
    {
        private sealed class FakeSession(FakeDriver driver, SampleFormat format, uint rate, uint channels)
            : HardwareDeviceSessionOutputBase(null, format, rate, channels)
        {
            public int Queued, Started;
            public ulong Played;
            public override void Dispose() => driver.Disposed++;
            public override void PrepareToClose() { }
            public override void QueueBuffer(AudioBuffer buffer) { Queued++; Played += GetSampleCount(buffer); }
            public override void SetVolume(float volume) { }
            public override float GetVolume() => 1f;
            public override void Start() { if (driver.FailStart) throw new InvalidOperationException("OHAudio start failed: -2"); Started++; }
            public override void Stop() { }
            public override ulong GetPlayedSampleCount() => Played;
            public override bool WasBufferFullyConsumed(AudioBuffer buffer) => false;
        }

        private sealed class FakeDriver : IHardwareDeviceDriver
        {
            public bool FailOpen, FailStart;
            public int Disposed;
            public FakeSession Last;
            public readonly ManualResetEvent Update = new(false), Pause = new(true);
            public static bool IsSupported => true;
            public float Volume { get; set; } = 1f;
            public IHardwareDeviceSession OpenDeviceSession(IHardwareDeviceDriver.Direction direction, IVirtualMemoryManager memoryManager, SampleFormat sampleFormat, uint sampleRate, uint channelCount)
            {
                if (FailOpen) throw new InvalidOperationException("OHAudio output stream could not be opened: -1");
                return Last = new FakeSession(this, sampleFormat, sampleRate, channelCount);
            }
            public ManualResetEvent GetUpdateRequiredEvent() => Update;
            public ManualResetEvent GetPauseEvent() => Pause;
            public bool SupportsDirection(IHardwareDeviceDriver.Direction direction) => true;
            public bool SupportsSampleRate(uint sampleRate) => true;
            public bool SupportsSampleFormat(SampleFormat sampleFormat) => true;
            public bool SupportsChannelCount(uint channelCount) => true;
            public void Dispose() { }
        }

        private static IHardwareDeviceSession Open(IHardwareDeviceDriver d) =>
            d.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);

        private static AudioBuffer Buffer() => new() { DataPointer = 0x1000, DataSize = 4 * 240 };   // 240 帧立体声 16 位

        [SoloTest("--audio-fallback")]
        static int Run()
        {
            bool strict = Red.Strict;
            var log = Red.Log;
            var lines = new List<string>();
            int bad = 0;
            void Ck(bool ok, string what) { Console.WriteLine((ok ? "通 " : "不通 ") + what); if (!ok) bad++; }
            int Reds() => lines.FindAll(l => l.Contains(AudioFallbackDriver.RedLine)).Count;
            try
            {
                Red.Strict = true;   // ⑤ 严格模式也不能中止：一旦 FailFast，本进程直接没了，下面一行都打不出来
                Red.Reset();
                Red.Log = lines.Add;

                // ① 建驱动抛异常
                using (var d = (AudioFallbackDriver)AudioFallbackDriver.Create(() => throw new InvalidOperationException("no audio adapter")))
                {
                    Ck(d.Real is DummyHardwareDeviceDriver && Reds() == 1, $"① 建驱动失败：换哑驱动、红行 {Reds()} 条（期望 1）");
                }

                // ② 开输出会话抛异常
                Red.Reset(); lines.Clear();
                var fake = new FakeDriver { FailOpen = true };
                using (var d = (AudioFallbackDriver)AudioFallbackDriver.Create(() => fake))
                {
                    var s = (HardwareDeviceSessionOutputBase)Open(d);
                    s.Start();
                    fake.Update.Reset();
                    s.QueueBuffer(Buffer());
                    Ck(s.GetPlayedSampleCount() == 240 && s.WasBufferFullyConsumed(Buffer()) && fake.Update.WaitOne(0),
                       $"② 开会话失败：无声会话交来即播完（已播 {s.GetPlayedSampleCount()}，期望 240）、叫醒音频系统");
                    Ck(d.Silent && Reds() == 1, $"② 红行 {Reds()} 条（期望 1）");
                    s.Dispose();
                }

                // ③ Start 抛异常（模拟器 OHAudio start failed: -2）
                Red.Reset(); lines.Clear();
                fake = new FakeDriver { FailStart = true };
                using (var d = (AudioFallbackDriver)AudioFallbackDriver.Create(() => fake))
                {
                    var s = (HardwareDeviceSessionOutputBase)Open(d);
                    Exception thrown = null;
                    try { s.Start(); } catch (Exception e) { thrown = e; }
                    s.QueueBuffer(Buffer());
                    Ck(thrown == null && fake.Last.Queued == 0 && s.GetPlayedSampleCount() == 240, "③ Start 失败不往上抛，之后的缓冲不再送真实设备、按无声计数");
                    var s2 = (HardwareDeviceSessionOutputBase)Open(d);
                    s2.Start(); s2.QueueBuffer(Buffer());
                    Ck(Reds() == 1 && s2.GetPlayedSampleCount() == 240, $"③ 同一驱动再开会话直接无声、红行仍 {Reds()} 条（期望 1）");
                    s.Dispose(); s2.Dispose();
                    Ck(fake.Disposed == 1, $"③ 摘下的真实会话在 Dispose 时释放（{fake.Disposed} 次，期望 1）");
                }

                // ④ 平台报输出中途失败
                Red.Reset(); lines.Clear();
                fake = new FakeDriver();
                using (var d = (AudioFallbackDriver)AudioFallbackDriver.Create(() => fake))
                {
                    var s = (HardwareDeviceSessionOutputBase)Open(d);
                    s.Start(); s.QueueBuffer(Buffer());
                    Ck(fake.Last.Queued == 1 && !s.WasBufferFullyConsumed(Buffer()) && Reds() == 0, "⑥ 正常驱动：透传给真实会话、不报红");
                    Ck(AudioFallbackDriver.ReportOutputFailure(new InvalidOperationException("OHAudio wait failed: -5")), "④ 有在用的驱动：ReportOutputFailure 回 true");
                    s.QueueBuffer(Buffer());
                    Ck(fake.Last.Queued == 1 && s.WasBufferFullyConsumed(Buffer()) && s.GetPlayedSampleCount() == 480 && Reds() == 1,
                       $"④ 中途失败：已在播的会话改无声（已播 {s.GetPlayedSampleCount()}，期望 240 + 240）、红行 {Reds()} 条（期望 1）");
                    s.Dispose();
                }
                Ck(!AudioFallbackDriver.ReportOutputFailure(new InvalidOperationException("late")), "④ 驱动释放后：ReportOutputFailure 回 false（调用方照旧处理）");
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("声音回退：意外异常 " + error);
                bad++;
            }
            finally { Red.Log = log; Red.Strict = strict; Red.Reset(); }
            Console.WriteLine(bad == 0 ? "声音回退：全部符合" : $"声音回退：{bad} 项不符");
            return bad == 0 ? 0 : 1;
        }
    }
}
