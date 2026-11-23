// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Apple;   // 平台例外：苹果音频后端单测（真 AudioQueue），只在 macOS 跑
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace S2A.Services.Tests
{
    // #1598 Mac 无声：输出队列卡死时，一次交设备（AudioQueueEnqueueBuffer）卡几百毫秒到几秒，渲染一拍里的「DSP」跟着拖到 2–7 秒、随后停流全无声；
    //   原兜底只看「设备 1 秒没回调且在途有数据」，生产方被交设备拖住时接不住，只有切窗口走解冻路径重启队列才恢复。
    //   真声卡（本机 AudioQueue），测试钩子 S2A_AUDIO_TEST_ENQ_STALL_AT=1:600 让开播后第 1 秒的一次交设备在计时窗口里睡 600 ms。期望按语义手算：
    // ① 钩子到点生效（打一行「测试钩子…交设备卡 600 ms」）
    // ② 看门狗（每 250 ms 一拍）在钩子后 3 秒内按「交设备卡了 ≥ 250 ms」重启输出队列：打「兜底：一次交设备…卡了 6xx ms」，重新开播 rc=0
    // ③ 重启后设备照常播：之后播完的帧数涨到 ≥ 24000（0.5 秒声音；排着 4 秒声音，不缺数据）
    //   等法（11-22 门禁偶发红：本机负载高时 1.5 秒里只播完 19165 帧，负载 40 时 33.6k、空闲时更多）：按条件等「播完涨到 24000」，
    //   10 秒为卡死上限——判的是「重启后在播」，不是「1.5 秒内播多快」。队列卡死不播时计数不涨，10 秒后照样红。
    //   ①② 的 3 秒同理放宽到 10 秒（看门狗线程被晚调度只会晚，不会让没发生的重启发生）
    //   负控：同一单测带 S2A_AUDIO_HEAL=0（自愈关）跑，② 红——证明 ② 测的是这条自愈
    static class AppleAudioEnqueueStuckTest
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

        [SoloTest("--apple-audio-enqueue-stuck")]
        private static int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：苹果音频后端单测，只在 macOS 跑
            {
                Console.WriteLine("✗ 苹果音频交设备卡死自愈：本机没有可用的苹果音频后端");
                return 1;
            }

            Environment.SetEnvironmentVariable("S2A_AUDIO_TEST_ENQ_STALL_AT", "1:600");   // 会话类首次用到前设好（钩子是静态只读字段）
            var log = new StringWriter(); TextWriter err = Console.Error;
            Console.SetError(TextWriter.Synchronized(log));

            int bad = 0;
            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频交设备卡死自愈 {name}：{expect} → {actual}");
            }
            bool WaitLog(string s, int ms) { var sw = Stopwatch.StartNew(); while (sw.ElapsedMilliseconds < ms) { if (log.ToString().Contains(s)) return true; Thread.Sleep(20); } return log.ToString().Contains(s); }
            string Line(string s) { foreach (string l in log.ToString().Split('\n')) if (l.Contains(s)) return l.Trim(); return "—"; }

            var reader = new ToneReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：苹果音频后端单测（真 AudioQueue），只在 macOS 跑
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);
            session.Start();

            const ulong Bytes = 4800 * 4;   // 100 ms
            for (int i = 0; i < 40; i++)
            {
                var b = new AudioBuffer { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };
                session.RegisterBuffer(b);
                session.QueueBuffer(b);
            }

            bool hook = WaitLog("测试钩子", 10000);
            Row("① 钩子到点生效", "10 秒内一行「交设备卡 600 ms」", hook ? Line("测试钩子") : "没生效", hook && Line("测试钩子").Contains("卡 600 ms"));

            bool healed = WaitLog("一次交设备（AudioQueueEnqueueBuffer）卡了", 10000);
            string hl = Line("一次交设备（AudioQueueEnqueueBuffer）卡了");
            Row("② 看门狗按交设备卡死重启输出队列", "10 秒内、重新开播 rc=0", healed ? hl : "没重启", healed && hl.Contains("重新开播 rc=0"));

            ulong p0 = session.GetPlayedSampleCount(), played = 0;
            var sw3 = Stopwatch.StartNew();
            while ((played = session.GetPlayedSampleCount() - p0) < 24000 && sw3.ElapsedMilliseconds < 10000) Thread.Sleep(20);
            Row("③ 重启后设备照常播", "10 秒内播完涨到 ≥ 24000 帧", $"{played} 帧（{sw3.ElapsedMilliseconds} ms）", played >= 24000);

            session.Dispose(); driver.Dispose();
            Console.SetError(err);
            return bad == 0 ? 0 : 1;
        }
    }
}
