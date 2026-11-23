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
    // D-J7ZC 巫师3 iPad 中止：iOS 音频中断期间系统停了输出队列、设备不交还，游戏约 1 秒收不到交还就自己关掉音频输出重开，
    //   巫师3 的重开路径没先销毁上一个 SystemEvent，OpenDefaultAudioOut 中止。修法：中断期间改走无设备播放，按采样率照常交还（AppleHardwareDeviceSession._virtual）。
    //   真声卡（本机 AudioQueue），测试钩子 S2A_AUDIO_TEST_NOTE_AT=1:2500：开播后第 1 秒投递 began、暂停队列（同系统停播），2.5 秒后投递 ended。期望按语义手算：
    // ① 钩子到点生效（一行「测试钩子…模拟中断…2500 ms 后投递 ended」）
    // ② 看门狗（每 250 ms 一拍）1 秒内见 began，改走无设备播放（一行「系统通知：中断开始 … 改走无设备播放」）
    // ③ 中断期间游戏照常收到交还、按采样率：钩子后 0.5–1.5 秒这 1 秒里播完 38400–57600 帧（48000 × 0.8–1.2；排着 8 秒声音，不缺数据）
    //   负控：撤掉进入无设备播放（watchdog 的 began 分支与兜底分支），③ 只剩在途收回的零头、远小于 38400
    // ④ ended 后 1 秒内回到设备：一行「系统通知：中断结束 … 结束无设备播放 … 重新开播 rc=0」
    // ⑤ 回到设备后照常播：之后播完涨到 ≥ 24000 帧（11-22 门禁偶发红：负载高时墙钟 1.5 秒里只播完 22479 帧；判的是「回到设备后在播」，
    //   按条件等播完帧数，10 秒为卡死上限，队列没播起来照样红）
    static class AppleAudioInterruptVirtualTest
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

        [SoloTest("--apple-audio-interrupt-virtual")]
        private static int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：苹果音频后端单测，只在 macOS 跑
            {
                Console.WriteLine("✗ 苹果音频中断无设备播放：本机没有可用的苹果音频后端");
                return 1;
            }

            Environment.SetEnvironmentVariable("S2A_AUDIO_TEST_NOTE_AT", "1:2500");   // 会话类首次用到前设好（钩子是静态只读字段）
            var log = new StringWriter(); TextWriter err = Console.Error;
            Console.SetError(TextWriter.Synchronized(log));

            int bad = 0;
            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频中断无设备播放 {name}：{expect} → {actual}");
            }
            bool WaitLog(string s, int ms) { var sw = Stopwatch.StartNew(); while (sw.ElapsedMilliseconds < ms) { if (log.ToString().Contains(s)) return true; Thread.Sleep(10); } return log.ToString().Contains(s); }
            string Line(string s) { foreach (string l in log.ToString().Split('\n')) if (l.Contains(s)) return l.Trim(); return "—"; }

            var reader = new ToneReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：苹果音频后端单测（真 AudioQueue），只在 macOS 跑
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);
            session.Start();

            const ulong Bytes = 4800 * 4;   // 100 ms
            for (int i = 0; i < 80; i++)
            {
                var b = new AudioBuffer { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };
                session.RegisterBuffer(b);
                session.QueueBuffer(b);
            }

            bool hook = WaitLog("测试钩子", 3000);
            var sinceHook = Stopwatch.StartNew();
            Row("① 钩子到点生效", "3 秒内一行「模拟中断…2500 ms 后投递 ended」", hook ? Line("测试钩子") : "没生效", hook && Line("测试钩子").Contains("2500 ms 后投递 ended"));

            bool virt = WaitLog("改走无设备播放", 1000);
            string vl = Line("改走无设备播放");
            Row("② 见 began 改走无设备播放", "1 秒内、因「系统通知：中断开始」", virt ? vl : "没改", virt && vl.Contains("系统通知：中断开始"));

            while (sinceHook.ElapsedMilliseconds < 500) Thread.Sleep(5);
            ulong p0 = session.GetPlayedSampleCount();
            long t0 = sinceHook.ElapsedMilliseconds;
            while (sinceHook.ElapsedMilliseconds < t0 + 1000) Thread.Sleep(5);
            ulong during = session.GetPlayedSampleCount() - p0;
            Row("③ 中断期间按采样率交还", "1 秒播完 38400–57600 帧", $"{during} 帧", during >= 38400 && during <= 57600);

            bool back = WaitLog("结束无设备播放", 3000);
            string bl = Line("结束无设备播放");
            Row("④ ended 后回到设备", "一行「系统通知：中断结束…结束无设备播放…重新开播 rc=0」", back ? bl : "没回", back && bl.Contains("系统通知：中断结束") && bl.Contains("重新开播 rc=0"));

            ulong p1 = session.GetPlayedSampleCount(), after = 0;
            var sw5 = Stopwatch.StartNew();
            while ((after = session.GetPlayedSampleCount() - p1) < 24000 && sw5.ElapsedMilliseconds < 10000) Thread.Sleep(20);
            Row("⑤ 回到设备后照常播", "10 秒内播完涨到 ≥ 24000 帧", $"{after} 帧（{sw5.ElapsedMilliseconds} ms）", after >= 24000);

            session.Dispose(); driver.Dispose();
            Console.SetError(err);
            return bad == 0 ? 0 : 1;
        }
    }
}
