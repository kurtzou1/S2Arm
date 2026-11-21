// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Threading;

namespace S2A.Services
{
    // 声音输出起不来 / 中途没了 → 无声输出、打一条红行，游戏照常跑（11-18 维护者，#1301 选项 a：只有物理上做不下去才停）。
    // 包在平台声音驱动外（Exports.CreateAudioDriver，苹果 / 安卓 / 鸿蒙共用）：
    //   建驱动抛异常 → 整个换成 Ryujinx 哑驱动；开输出会话、Start / QueueBuffer 等会话调用抛异常，或平台报「输出线程死了」（ReportOutputFailure）
    //   → 该驱动下所有输出会话改走无声：缓冲按交来即播完计数、照常唤醒音频系统，不再碰真实设备。
    // 每个驱动只打第一条红行（之后的失败只换无声、不再报），不走严格模式中止。输入方向（麦克风）不包：照旧抛给调用方。
    public sealed class AudioFallbackDriver : IHardwareDeviceDriver
    {
        internal const string RedLine = "声音输出起不来，改无声输出（游戏照常跑）";

        private readonly IHardwareDeviceDriver _real;
        private readonly ConcurrentDictionary<Session, byte> _sessions = new();
        private static AudioFallbackDriver _active;
        private int _silent;
        private int _reported;

        public AudioFallbackDriver(IHardwareDeviceDriver real)
        {
            _real = real ?? throw new ArgumentNullException(nameof(real));
            Volatile.Write(ref _active, this);
        }

        internal IHardwareDeviceDriver Real => _real;
        public static bool IsSupported => true;

        // IHardwareDeviceDriver 带静态抽象成员，不能当 Func<> 的类型参数
        public delegate IHardwareDeviceDriver DriverFactory();

        // 已经整体换成无声（之后新开的输出会话直接无声，不再去碰真实设备）
        public bool Silent => Volatile.Read(ref _silent) != 0;

        // 建平台驱动本身就失败：报红一次，换哑驱动（还是包一层，便于之后统一）
        public static IHardwareDeviceDriver Create(DriverFactory factory)
        {
            IHardwareDeviceDriver real;
            try { real = factory(); }
            catch (Exception error)
            {
                Red.Report(RedLine, "建声音驱动失败：" + error.Message, allowFailFast: false);
                var dummy = new AudioFallbackDriver(new DummyHardwareDeviceDriver());
                dummy._reported = 1;
                return dummy;
            }
            return new AudioFallbackDriver(real);
        }

        // 平台输出线程报错（鸿蒙 OHAudio 喂数线程、设备被拔 / 被抢占）：当前驱动整体改无声。回 false = 没有在用的驱动，调用方照旧处理
        public static bool ReportOutputFailure(Exception error)
        {
            AudioFallbackDriver active = Volatile.Read(ref _active);
            if (active == null) return false;
            active.GoSilent(error, "输出中途失败");
            return true;
        }

        private void GoSilent(Exception error, string where)
        {
            Interlocked.Exchange(ref _silent, 1);
            foreach (Session session in _sessions.Keys) session.Fail();
            if (Interlocked.Exchange(ref _reported, 1) == 0)
            {
                Red.Report(RedLine, $"{where}：{error.GetType().Name}: {error.Message}", allowFailFast: false);
            }
        }

        public float Volume { get => _real.Volume; set => _real.Volume = value; }

        public IHardwareDeviceSession OpenDeviceSession(IHardwareDeviceDriver.Direction direction, IVirtualMemoryManager memoryManager,
            SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            if (direction != IHardwareDeviceDriver.Direction.Output)
            {
                return _real.OpenDeviceSession(direction, memoryManager, sampleFormat, sampleRate, channelCount);
            }

            HardwareDeviceSessionOutputBase real = null;
            if (!Silent)
            {
                try
                {
                    IHardwareDeviceSession opened = _real.OpenDeviceSession(direction, memoryManager, sampleFormat, sampleRate, channelCount);
                    real = opened as HardwareDeviceSessionOutputBase;
                    if (real == null)
                    {
                        // 包不了（不是输出基类）：原样交回，不做回退（各平台驱动都是这个基类，这里只防将来）
                        return opened;
                    }
                }
                catch (Exception error)
                {
                    GoSilent(error, "开输出会话失败");
                }
            }

            var session = new Session(this, real, memoryManager, sampleFormat, sampleRate == 0 ? Ryujinx.Audio.Constants.TargetSampleRate : sampleRate,
                channelCount == 0 ? 2 : channelCount);
            _sessions.TryAdd(session, 0);
            if (Silent) session.Fail();   // GoSilent 发生在本会话登记之前也要覆盖到
            return session;
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
            Interlocked.CompareExchange(ref _active, null, this);
            foreach (Session session in _sessions.Keys) session.Dispose();
            try { _real.Dispose(); }
            catch (Exception error) when (Silent)
            {
                Console.Error.WriteLine("[声] 无声输出后释放声音驱动失败（已忽略）：" + error.Message);
            }
        }

        // 继承 HardwareDeviceSessionOutputBase：Ryujinx 兼容层与 AudioPeakDriver 都要求真实会话是这个基类
        private sealed class Session : HardwareDeviceSessionOutputBase, IS2AOutputDepth
        {
            private readonly AudioFallbackDriver _owner;
            private readonly object _lock = new();
            private HardwareDeviceSessionOutputBase _real;   // null = 无声
            private HardwareDeviceSessionOutputBase _orphan; // 改无声时摘下的真实会话：不再调用，Dispose 时释放
            private ulong _silentPlayed;                       // 改无声以后「播完」的样本数（接在真实会话最后读数之后）
            private ulong _realPlayed;
            private float _volume = 1f;
            private int _disposed;

            public Session(AudioFallbackDriver owner, HardwareDeviceSessionOutputBase real, IVirtualMemoryManager memoryManager,
                SampleFormat sampleFormat, uint sampleRate, uint channelCount)
                : base(real?.MemoryManager ?? memoryManager, real?.RequestedSampleFormat ?? sampleFormat,
                       real?.RequestedSampleRate ?? sampleRate, real?.RequestedChannelCount ?? channelCount)
            {
                _owner = owner;
                _real = real;
            }

            public long S2ABufferedFrames
            {
                get
                {
                    HardwareDeviceSessionOutputBase real = Volatile.Read(ref _real);
                    return real is IS2AOutputDepth depth ? depth.S2ABufferedFrames : -1;
                }
            }

            // 改无声：记下真实会话最后的已播样本数，之后不再调真实会话（它留到 Dispose 时再释放：可能正是它的线程在报错）
            internal void Fail()
            {
                lock (_lock)
                {
                    HardwareDeviceSessionOutputBase real = _real;
                    if (real == null) return;
                    try { _realPlayed = real.GetPlayedSampleCount(); } catch { }
                    _orphan = real;
                    Volatile.Write(ref _real, null);
                }
            }

            // 真实会话上的一次调用；抛异常 = 整个驱动改无声，本次按无声处理（回 false 由调用方走无声分支）
            private bool Try(Action<HardwareDeviceSessionOutputBase> call, string what)
            {
                HardwareDeviceSessionOutputBase real = Volatile.Read(ref _real);
                if (real == null) return false;
                try { call(real); return true; }
                catch (Exception error)
                {
                    _owner.GoSilent(error, what);
                    return false;
                }
            }

            public override void Start() => Try(s => s.Start(), "开始播放失败");
            public override void Stop() => Try(s => s.Stop(), "暂停失败");
            public override void PrepareToClose() => Try(s => s.PrepareToClose(), "关闭前准备失败");

            public override void QueueBuffer(AudioBuffer buffer)
            {
                if (Try(s => s.QueueBuffer(buffer), "送缓冲失败")) return;
                Interlocked.Add(ref _silentPlayed, GetSampleCount(buffer));
                _owner.GetUpdateRequiredEvent().Set();   // 同 Ryujinx 哑会话：交来即播完，叫醒音频系统回收
            }

            public override bool RegisterBuffer(AudioBuffer buffer)
            {
                bool ok = false;
                if (Try(s => ok = s.RegisterBuffer(buffer), "登记缓冲失败")) return ok;
                return base.RegisterBuffer(buffer);
            }

            public override void UnregisterBuffer(AudioBuffer buffer)
            {
                if (Try(s => s.UnregisterBuffer(buffer), "撤回缓冲失败")) return;
                HardwareDeviceSessionOutputBase orphan = _orphan;   // 改无声前登记在真实会话里的缓冲：照样还给它的样本队列
                if (orphan != null) { try { orphan.UnregisterBuffer(buffer); } catch { } }
            }

            public override bool WasBufferFullyConsumed(AudioBuffer buffer)
            {
                bool consumed = true;
                if (Try(s => consumed = s.WasBufferFullyConsumed(buffer), "查缓冲失败")) return consumed;
                return true;
            }

            public override void SetVolume(float volume)
            {
                _volume = volume;
                Try(s => s.SetVolume(volume), "设音量失败");
            }

            public override float GetVolume()
            {
                float volume = _volume;
                Try(s => volume = s.GetVolume(), "读音量失败");
                return volume;
            }

            public override ulong GetPlayedSampleCount()
            {
                ulong played = 0;
                if (Try(s => played = s.GetPlayedSampleCount(), "读播放进度失败")) return played;
                return _realPlayed + Interlocked.Read(ref _silentPlayed);
            }

            public override void Dispose()
            {
                if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
                _owner._sessions.TryRemove(this, out _);
                HardwareDeviceSessionOutputBase real;
                lock (_lock) { real = _real ?? _orphan; _real = null; _orphan = null; }
                if (real == null) return;
                try { real.Dispose(); }
                catch (Exception error)
                {
                    // 正常路径的释放失败照旧往上报；已经无声的会话（设备已经没了）释放失败只记一行
                    if (!_owner.Silent) throw;
                    Console.Error.WriteLine("[声] 无声输出后释放真实会话失败（已忽略）：" + error.Message);
                }
            }
        }
    }
}
