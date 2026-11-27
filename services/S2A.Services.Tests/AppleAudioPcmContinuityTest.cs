// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Apple;   // 平台例外：Mac 真 AudioUnit 拉取回归
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services.Tests
{
    // 苹果音频 PCM 连续性（真声卡，拉取档）：游戏交的样本按序列编号（左 1000+相位、右 2000+相位，相位 0..999 循环），在输出器件上挂渲染后
    //   通知（AudioUnitAddRenderNotify，PostRender）抓真正交给声卡的帧，逐帧核：相位连续、左右配对、没有重复 / 错序。
    //   钩子 S2A_AUDIO_TEST_STALL_AT=1：开播后第 1 秒外部停器件 → 改走无设备播放 → 试回设备，回来后再抓一段核一遍。
    //   无设备播放期间读出的样本当播完、不进声卡，所以只分段核（停播前 / 回到设备后），段间相位跳跃不算错。
    //   原写法在 AudioQueue 上挂处理抽头（#2211），拉取档取代 AudioQueue 后改挂输出器件的渲染通知，判据不变。
    static unsafe class AppleAudioPcmContinuityTest
    {
        private const int RingFrames = 1 << 20;
        private const uint PostRender = 1 << 3;   // kAudioUnitRenderAction_PostRender
        private static readonly int[] Ring = new int[RingFrames];
        private static long _written;
        private static int _overflow;
        private static int _tapErrors;
        private static int _capture;   // 1 = 抓帧；停播 / 换段时关
        private static readonly RenderNotify NotifyCallback = OnRender;
        private static readonly FieldInfo UnitField = typeof(ApplePullHardwareDeviceSession).GetField("_unit", BindingFlags.Instance | BindingFlags.NonPublic);   // 平台例外：取本平台真实输出器件

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeAudioBuffer
        {
            public uint Channels;
            public uint DataByteSize;
            public nint Data;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeAudioBufferList
        {
            public uint BufferCount;
            public NativeAudioBuffer First;
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int RenderNotify(nint refCon, uint* flags, nint timeStamp, uint bus, uint frames, nint ioData);

        [DllImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]   // 平台例外：Mac 真输出器件渲染通知
        private static extern int AudioUnitAddRenderNotify(nint unit, nint proc, nint refCon);

        [DllImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]   // 平台例外：Mac 真输出器件渲染通知
        private static extern int AudioUnitRemoveRenderNotify(nint unit, nint proc, nint refCon);

        private sealed class SequenceReader : HardwareDeviceSessionOutputBase
        {
            private long _next;

            public SequenceReader() : base(null, SampleFormat.PcmInt16, 48000, 2) { }

            public override void ReadSamples(AudioBuffer buffer, ulong offset, Span<byte> destination)
            {
                for (int i = 0; i < destination.Length; i += 4)
                {
                    int phase = (int)(_next++ % 1000);
                    short left = (short)(1000 + phase), right = (short)(2000 + phase);
                    BitConverter.TryWriteBytes(destination.Slice(i, 2), left);
                    BitConverter.TryWriteBytes(destination.Slice(i + 2, 2), right);
                }
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

        private static int OnRender(nint refCon, uint* flags, nint timeStamp, uint bus, uint frames, nint ioData)
        {
            if ((*flags & PostRender) == 0 || bus != 0 || Volatile.Read(ref _capture) == 0)
            {
                return 0;
            }

            NativeAudioBufferList* list = (NativeAudioBufferList*)ioData;

            if (list == null || list->BufferCount != 1 || list->First.Channels != 2 || list->First.DataByteSize < frames * 4 || list->First.Data == 0)
            {
                Interlocked.Increment(ref _tapErrors);
                return 0;
            }

            // 器件上交声卡的是 32 位浮点交错（实测 512 帧 4096 字节）；16 位交错照收（客机 PCM16 原样直交的路径）
            bool f32 = list->First.DataByteSize >= frames * 8;
            short* pcm = (short*)list->First.Data;
            float* fl = (float*)list->First.Data;

            for (uint i = 0; i < frames; i++)
            {
                int l, r;

                if (f32)
                {
                    l = Math.Clamp((int)MathF.Round(fl[2 * i] * 32768f), short.MinValue, short.MaxValue);
                    r = Math.Clamp((int)MathF.Round(fl[2 * i + 1] * 32768f), short.MinValue, short.MaxValue);
                }
                else
                {
                    l = pcm[2 * i];
                    r = pcm[2 * i + 1];
                }

                long at = Interlocked.Increment(ref _written) - 1;

                if (at < RingFrames)
                {
                    Ring[at] = (int)((uint)(ushort)l | ((uint)(ushort)r << 16));
                }
                else
                {
                    Interlocked.Exchange(ref _overflow, 1);
                }
            }

            return 0;
        }

        private static void ResetCapture()
        {
            Volatile.Write(ref _capture, 0);
            Thread.Sleep(50);   // 让在跑的那次回调收尾
            Volatile.Write(ref _written, 0);
            Volatile.Write(ref _overflow, 0);
            Volatile.Write(ref _tapErrors, 0);
        }

        private static (int Frames, int Mismatches, int ZeroFrames, int MaxZeroRun, int Overflow, int Errors) Snapshot()
        {
            long written = Math.Min(Volatile.Read(ref _written), RingFrames);
            int mismatches = 0, zeroFrames = 0, maxZeroRun = 0, zeroRun = 0, expected = -1;

            for (long i = 0; i < written; i++)
            {
                uint packed = (uint)Ring[i];
                int left = (int)(packed & 0xffff), right = (int)(packed >> 16);

                if (left == 0 && right == 0)
                {
                    zeroFrames++;
                    zeroRun++;
                    maxZeroRun = Math.Max(maxZeroRun, zeroRun);
                    continue;
                }

                zeroRun = 0;
                int phase = left - 1000;

                if (phase < 0 || phase >= 1000 || right != 2000 + phase)
                {
                    mismatches++;
                }

                if (expected >= 0 && phase != (expected + 1) % 1000)
                {
                    mismatches++;
                }

                expected = phase;
            }

            return ((int)written, mismatches, zeroFrames, maxZeroRun, Volatile.Read(ref _overflow), Volatile.Read(ref _tapErrors));
        }

        [SoloTest("--apple-audio-pcm-continuity")]
        private static int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：Mac 真 AudioUnit 拉取回归
            {
                Console.WriteLine("✗ 苹果音频 PCM 连续性：本机没有苹果音频后端");
                return 1;
            }

            Environment.SetEnvironmentVariable("S2A_AUDIO_TEST_STALL_AT", "1");
            var log = new StringWriter();
            TextWriter previous = Console.Error;
            Console.SetError(TextWriter.Synchronized(log));

            bool WaitLog(string text, int timeoutMs)
            {
                Stopwatch sw = Stopwatch.StartNew();

                while (sw.ElapsedMilliseconds < timeoutMs)
                {
                    if (log.ToString().Contains(text)) return true;
                    Thread.Sleep(5);
                }

                return log.ToString().Contains(text);
            }

            bool WaitFrames(int frames, int timeoutMs)
            {
                Stopwatch sw = Stopwatch.StartNew();

                while (Volatile.Read(ref _written) < frames && sw.ElapsedMilliseconds < timeoutMs)
                {
                    Thread.Sleep(5);
                }

                return Volatile.Read(ref _written) >= frames;
            }

            nint proc = Marshal.GetFunctionPointerForDelegate(NotifyCallback);
            var reader = new SequenceReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：Mac 真 AudioUnit 拉取回归
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);
            nint unit = session is ApplePullHardwareDeviceSession ? (nint)UnitField.GetValue(session) : 0;
            int attachRc = unit != 0 ? AudioUnitAddRenderNotify(unit, proc, 0) : -1;
            ResetCapture();
            Volatile.Write(ref _capture, 1);
            session.Start();

            const ulong Bytes = 4800 * 4;   // 100 ms

            for (int i = 0; i < 240; i++)
            {
                var buffer = new AudioBuffer { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };
                session.RegisterBuffer(buffer);
                session.QueueBuffer(buffer);
            }

            // 停播前一段：钩子第 1 秒停器件，这之前抓到的就是停播前的 PCM
            bool stalled = WaitLog("外部暂停输出队列", 5000) && WaitLog("改走无设备播放", 3000);
            Volatile.Write(ref _capture, 0);
            var before = Snapshot();

            // 回到设备后一段：器件若在恢复时重建，换到新器件上重挂通知
            bool retried = WaitLog("试回设备", 5000);
            nint unitAfter = session is ApplePullHardwareDeviceSession ? (nint)UnitField.GetValue(session) : 0;
            bool sameUnit = unitAfter == unit;
            int reattachRc = sameUnit ? 0 : unitAfter != 0 ? AudioUnitAddRenderNotify(unitAfter, proc, 0) : -1;
            ResetCapture();
            Volatile.Write(ref _capture, 1);
            WaitFrames(24000, 10000);
            Volatile.Write(ref _capture, 0);
            var after = Snapshot();

            if (unit != 0) AudioUnitRemoveRenderNotify(unit, proc, 0);
            if (!sameUnit && unitAfter != 0) AudioUnitRemoveRenderNotify(unitAfter, proc, 0);
            session.Dispose();
            driver.Dispose();
            Console.SetError(previous);

            int bad = 0;

            void Row(string name, string expected, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频 PCM 连续性 {name}：{expected} → {actual}");
            }

            Row("① 输出器件渲染通知", "拉取会话、器件上挂得上渲染后通知", $"拉取会话={session is ApplePullHardwareDeviceSession}、rc={attachRc}", attachRc == 0);
            Row("② 停器件后无设备播放并试回设备", "进入无设备播放后试回设备", $"进入={stalled}、重试={retried}", stalled && retried);
            Row("③ 停播前 PCM", "≥24000 帧、0 错序/重复、0 格式错误、最长零run ≤16384",
                $"帧 {before.Frames}、错 {before.Mismatches}、零 {before.ZeroFrames}/{before.MaxZeroRun}、溢出 {before.Overflow}、格式错 {before.Errors}",
                before.Frames >= 24000 && before.Mismatches == 0 && before.Errors == 0 && before.Overflow == 0 && before.MaxZeroRun <= 16384);
            Row("④ 回到设备后 PCM", "原器件或重挂的新器件上播 ≥24000 帧、0 错序/重复、最长零run ≤16384",
                $"{(sameUnit ? "原器件" : $"新器件 rc={reattachRc}")}、帧 {after.Frames}、错 {after.Mismatches}、零 {after.ZeroFrames}/{after.MaxZeroRun}、溢出 {after.Overflow}、格式错 {after.Errors}",
                reattachRc == 0 && after.Frames >= 24000 && after.Mismatches == 0 && after.Errors == 0 && after.Overflow == 0 && after.MaxZeroRun <= 16384);
            return bad == 0 ? 0 : 1;
        }
    }
}
