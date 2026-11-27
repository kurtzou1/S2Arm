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
    // #2157 只留一种传输：native 6ch（无折叠、真 5.1 设备）直通进拉取——v1 的拉取档在 6ch 无折叠时红字拒收、整会话退 AudioQueue
    //   （v1 ApplePullHardwareDeviceSession 构造里直接 throw）；v2 删掉拒收分支，器件 StreamFormat 按设备声道（6ch）+ 声明 5.1 布局
    //   （MPEG_5_1_A，不声明时系统隐式 6→2 只复制 FL/FR、中置与环绕整段丢失）+ 12 B/帧的帧域环寻址（字节域掩码在 12 B/帧上必错位）。
    //   2ch 设备上该路径 = AUHAL 客户端 6ch 格式 + 设备 2ch、系统隐式下混（与 AudioQueue 6ch 队列同语义）；真 5.1 设备读数待维护方设备矩阵。
    //   期望按语义手算：
    // ① 会话类型 = ApplePullHardwareDeviceSession（不再拒收、不退 AudioQueue）
    // ② 开播后放回照常：播完帧数涨到 ≥ 4800（0.1 秒声音；排着 4 秒声音，不缺数据；10 秒为卡死上限）
    // ③ 全程无异常（布局声明失败按无布局继续、打【红】，行为同旧——不进判据）
    //   负控（commit 正文记录）：v1 代码上同一用例在构造里直接抛 InvalidOperationException（native 6ch 拒收），① 即红。
    static class AppleAudioPullNative6Test
    {
        private sealed class ToneReader : HardwareDeviceSessionOutputBase
        {
            public ToneReader() : base(null, SampleFormat.PcmInt16, 48000, 6) { }

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

        [SoloTest("--apple-audio-pull-native6")]
        private static int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：苹果音频后端单测，只在 macOS 跑
            {
                Console.WriteLine("✗ 苹果音频拉取 native 6ch 直通：本机没有可用的苹果音频后端");
                return 1;
            }

            Environment.SetEnvironmentVariable("S2A_AUDIO_OUT", null);   // native 路径：不显式下混
            int bad = 0;
            void Row(string name, string expect, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频拉取 native 6ch {name}：{expect} → {actual}");
            }

            var reader = new ToneReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：苹果音频后端单测（真 AudioUnit 拉取），只在 macOS 跑
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 6);

            Row("① 会话类型", "ApplePullHardwareDeviceSession（native 6ch 直通）", session.GetType().Name, session is ApplePullHardwareDeviceSession);

            session.Start();

            const ulong Bytes = 4800 * 12;   // 100 ms 的 6ch PCM16（12 B/帧）
            for (int i = 0; i < 40; i++)
            {
                var b = new AudioBuffer { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };
                session.RegisterBuffer(b);
                session.QueueBuffer(b);
            }

            ulong played = 0;
            var sw = Stopwatch.StartNew();
            while ((played = session.GetPlayedSampleCount()) < 4800 && sw.ElapsedMilliseconds < 10000) Thread.Sleep(20);
            Row("② 开播后放回照常", "10 秒内播完涨到 ≥ 4800 帧", $"{played} 帧（{sw.ElapsedMilliseconds} ms）", played >= 4800);

            session.Dispose(); driver.Dispose();
            return bad == 0 ? 0 : 1;
        }
    }
}
