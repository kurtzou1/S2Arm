using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services
{
    // 「有声」判据（测试契约：MARK 起 60 秒声音输出峰值，打「[声] 稳态窗口：输出峰值 X」）：
    // 包在真实声音驱动外，Ryujinx 每交给设备一块缓冲就扫一遍峰值（零分配）。自动玩家到 MARK 时经 s2a_ap_audio_mark 开窗。
    public sealed class AudioPeakDriver : IHardwareDeviceDriver
    {
        private readonly IHardwareDeviceDriver _real;
        private readonly ManualResetEventSlim _stop = new(false);
        private readonly System.Collections.Generic.List<Thread> _workers = new();
        private static AudioPeakDriver _active;
        private int _disposed;

        private static long _windowStart;     // Stopwatch 时间戳，0 = 未开窗
        private static int _peakBits;         // float 位模式（Interlocked 取最大）
        private static int _reported;
        private static int _segId = -1;       // 自动玩家 MARK 后段号（tests/autoplay/autoplay_host.h s2a_ap_seg_open）：普查提前收局要等稳态窗口报完
        private const double WindowSeconds = 60;

        public AudioPeakDriver(IHardwareDeviceDriver real)
        {
            _real = real;
            if (Interlocked.CompareExchange(ref _active, this, null) != null)
                throw new InvalidOperationException("上一局声音峰值驱动尚未释放");
            _windowStart = 0;
            _peakBits = _reported = 0;

            // S2A_AUDIO_WINDOW_AT=<秒>：起局这么多秒后还没到 MARK 就照样开窗（诊断：Mac 上帧率太低、自动玩家判不了 MARK 的局也能量有声，如怪猎村子 1 帧/秒）
            if (int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_WINDOW_AT"), out int at) && at > 0)
            {
                StartWorker(() =>
                {
                    if (_stop.Wait(TimeSpan.FromSeconds(at))) return;

                    if (Volatile.Read(ref _windowStart) == 0)
                    {
                        Console.Error.WriteLine($"[声] 起局 {at} 秒没到 MARK，按 S2A_AUDIO_WINDOW_AT 开窗");
                        Mark();
                    }
                }, "S2A.AudioPeakAt");
            }
        }

        public static bool IsSupported => true;

        // MARK：从此刻起算 60 秒窗口
        public static void Mark()
        {
            AudioPeakDriver active = Volatile.Read(ref _active);
            if (active == null) return;
            Interlocked.Exchange(ref _peakBits, 0);
            Interlocked.Exchange(ref _reported, 0);
            Interlocked.Exchange(ref _windowStart, Stopwatch.GetTimestamp());
            Console.Error.WriteLine("[声] 稳态窗口开始（60 秒）");
            SegOpen();
            active.StartWorker(() => { if (!active._stop.Wait(TimeSpan.FromSeconds(WindowSeconds))) Report(); }, "S2A.AudioPeak");
        }

        private void StartWorker(ThreadStart run, string name)
        {
            lock (_workers)
            {
                if (_stop.IsSet) return;
                Thread worker = new(run) { IsBackground = true, Name = name };
                _workers.Add(worker);
                worker.Start();
            }
        }

        // 稳态窗口登记成自动玩家的 MARK 后段（旁观段，不改出帧状态）：开窗登记、报完峰值销号；宿主里没链自动玩家（生产包）取不到导出就不登记
        private static unsafe void SegOpen()
        {
            SegClose();   // 重开窗（S2A_AUDIO_WINDOW_AT 先开过）：旧段先销号，只留一段
            if (NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_ap_seg_open", out nint p))   // 平台例外：自动玩家只在开发宿主里弱链接、生产包没有这个导出，进不了 Native.Imports 的 DllImport
            {
                fixed (byte* name = "声音稳态窗口\0"u8)
                {
                    Interlocked.Exchange(ref _segId, ((delegate* unmanaged<byte*, int, int>)p)(name, 0));
                }
            }
        }

        private static unsafe void SegClose()
        {
            int id = Interlocked.Exchange(ref _segId, -1);
            if (id >= 0 && NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_ap_seg_close", out nint p))   // 平台例外：同上（自动玩家导出）
            {
                ((delegate* unmanaged<int, void>)p)(id);
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "s2a_ap_audio_mark")]
        public static void MarkExport() => Mark();

        private static void Report()
        {
            if (Interlocked.Exchange(ref _reported, 1) == 0)
            {
                float peak = BitConverter.Int32BitsToSingle(Volatile.Read(ref _peakBits));
                Console.Error.WriteLine($"[声] 稳态窗口：输出峰值 {peak:F3}");
                SegClose();
            }
        }

        // 自动玩家打过 MARK 没有（GAL 录像 S2A_GALREC_FRAMES=mark… 按它开窗，services/aot/Compose.cs）
        public static bool Marked => Volatile.Read(ref _windowStart) != 0;

        internal static float CurrentPeak => BitConverter.Int32BitsToSingle(Volatile.Read(ref _peakBits));

        internal static void Observe(AudioBuffer buffer, SampleFormat format)
        {
            long start = Volatile.Read(ref _windowStart);

            if (start == 0 || Stopwatch.GetElapsedTime(start).TotalSeconds > WindowSeconds)
            {
                return;
            }

            if (buffer.Data != null)
            {
                Max(Peak(buffer.Data.AsSpan(0, (int)Math.Min((ulong)buffer.Data.Length, buffer.DataSize == 0 ? (ulong)buffer.Data.Length : buffer.DataSize)), format));
                return;
            }

            // 游戏缓冲（audout）样本留在游戏内存里（Ryujinx 补丁：登记不再整块复制），经 SampleReader 分块拉来扫，不建随缓冲长度走的数组
            if (buffer.SampleReader != null)
            {
                Span<byte> chunk = stackalloc byte[4096];

                for (ulong off = 0; off < buffer.DataSize; off += (ulong)chunk.Length)
                {
                    Span<byte> part = chunk[..(int)Math.Min((ulong)chunk.Length, buffer.DataSize - off)];
                    buffer.SampleReader.ReadSamples(buffer, off, part);
                    Max(Peak(part, format));
                }
            }
        }

        private static float Peak(ReadOnlySpan<byte> data, SampleFormat format)
        {
            float peak = 0;

            if (format == SampleFormat.PcmFloat)
            {
                foreach (float f in MemoryMarshal.Cast<byte, float>(data))
                {
                    peak = Math.Max(peak, Math.Abs(f));
                }
            }
            else if (format == SampleFormat.PcmInt16)
            {
                int max = 0;

                foreach (short v in MemoryMarshal.Cast<byte, short>(data))
                {
                    max = Math.Max(max, Math.Abs((int)v));
                }

                peak = max / 32768f;
            }

            return peak;
        }

        private static void Max(float peak)
        {
            int bits = BitConverter.SingleToInt32Bits(peak);
            int cur;

            // 非负浮点的位模式与数值同序，按整数取最大
            while (bits > (cur = Volatile.Read(ref _peakBits)) && Interlocked.CompareExchange(ref _peakBits, bits, cur) != cur)
            {
            }
        }

        public float Volume { get => _real.Volume; set => _real.Volume = value; }

        public IHardwareDeviceSession OpenDeviceSession(IHardwareDeviceDriver.Direction direction, IVirtualMemoryManager memoryManager, SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            IHardwareDeviceSession s = _real.OpenDeviceSession(direction, memoryManager, sampleFormat, sampleRate, channelCount);

            if (direction != IHardwareDeviceDriver.Direction.Output)
            {
                return s;
            }

            if (s is not HardwareDeviceSessionOutputBase output)
            {
                Red.Report("声音峰值：真实输出会话不是 HardwareDeviceSessionOutputBase，峰值不计", s.GetType().Name);
                return s;
            }

            return new Session(output);
        }

        public ManualResetEvent GetUpdateRequiredEvent() => _real.GetUpdateRequiredEvent();
        public ManualResetEvent GetPauseEvent() => _real.GetPauseEvent();
        public bool SupportsDirection(IHardwareDeviceDriver.Direction direction) => _real.SupportsDirection(direction);
        public bool SupportsSampleRate(uint sampleRate) => _real.SupportsSampleRate(sampleRate);
        public bool SupportsSampleFormat(SampleFormat sampleFormat) => _real.SupportsSampleFormat(sampleFormat);
        public bool SupportsChannelCount(uint channelCount) => _real.SupportsChannelCount(channelCount);
        public IHardwareDeviceDriver GetRealDeviceDriver() => _real.GetRealDeviceDriver();
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            Thread[] workers;
            lock (_workers)
            {
                if (_stop.IsSet) return;
                _stop.Set();
                workers = _workers.ToArray();
            }
            foreach (Thread worker in workers) worker.Join();
            _real.Dispose();
            Interlocked.CompareExchange(ref _active, null, this);
            _windowStart = 0;
            _peakBits = _reported = 0;
            _stop.Dispose();
        }

        // 继承 HardwareDeviceSessionOutputBase：Ryujinx 兼容层（声道降混 / 格式转换）包在本驱动外，要求真实会话是这个基类，
        // 原先只实现接口的包装让它抛「Real driver session class type isn't based on …」（暗黑2 FailFast、巫师3 音频异常）。
        // 兼容层转换后才交到这里，峰值按实际送硬件的格式算
        private sealed class Session : HardwareDeviceSessionOutputBase, Ryujinx.Audio.Integration.IS2AOutputDepth
        {
            private readonly HardwareDeviceSessionOutputBase _s;

            // 渲染按输出在途深度定节拍（11-13 断音）：把真实会话的深度透传上去
            public long S2ABufferedFrames => _s is Ryujinx.Audio.Integration.IS2AOutputDepth d ? d.S2ABufferedFrames : -1;

            public Session(HardwareDeviceSessionOutputBase s) : base(s.MemoryManager, s.RequestedSampleFormat, s.RequestedSampleRate, s.RequestedChannelCount)
            {
                _s = s;
            }

            public override void QueueBuffer(AudioBuffer buffer)
            {
                Observe(buffer, RequestedSampleFormat);
                _s.QueueBuffer(buffer);
            }

            public override bool RegisterBuffer(AudioBuffer buffer) => _s.RegisterBuffer(buffer);
            public override void UnregisterBuffer(AudioBuffer buffer) => _s.UnregisterBuffer(buffer);
            public override bool WasBufferFullyConsumed(AudioBuffer buffer) => _s.WasBufferFullyConsumed(buffer);
            public override void SetVolume(float volume) => _s.SetVolume(volume);
            public override float GetVolume() => _s.GetVolume();
            public override ulong GetPlayedSampleCount() => _s.GetPlayedSampleCount();
            public override void Start() => _s.Start();
            public override void Stop() => _s.Stop();
            public override void PrepareToClose() => _s.PrepareToClose();
            public override void Dispose() => _s.Dispose();
        }
    }
}
