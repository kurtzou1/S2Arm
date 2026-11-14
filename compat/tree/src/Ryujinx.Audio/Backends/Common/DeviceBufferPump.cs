using Ryujinx.Audio.Common;
using System;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.Audio.Backends.Common
{
    /// <summary>
    /// Feeds a device that consumes a fixed pool of buffers in submission order and hands each one back.
    /// </summary>
    // S2Arm: push, not pull. Upstream's Apple session refilled a device buffer only when the device handed one back (3 buffers of 10 ms)
    // and padded what the queue could not supply with silence. The callback that hands buffers back is managed code: a blocking GC
    // (or any stall of that thread) of more than ~30 ms starved the device although the game had up to ~85 ms queued, and every refill
    // that came short put silence in the middle of the stream (witcher3 on Mac, 170 s: 22 short refills, each after a burst of
    // hand-backs that followed a 30–470 ms callback gap; 13 of the 22 gaps > 30 ms fell inside a GC pause).
    // Here whatever is queued goes to the device as soon as a pool buffer is free, from the queueing thread too, so the device holds
    // everything the game queued and plays on through a stalled callback. Data buffers hold exactly the queued samples (whole
    // frames); an internal cushion uses a separate buffer and never contributes to queued-sample completion.
    public abstract class DeviceBufferPump
    {
        private readonly Lock _lock = new();
        private readonly int _slotBytes;
        private readonly int _bytesPerFrame;
        private readonly int[] _free;
        private int _freeCount;
        private readonly int[] _filled;
        private readonly int[] _sampleBytes; // Bytes originating in Samples; _filled also includes internal silence.
        private long _inFlightBytes;
        private long _submittedSampleBytes; // S2Arm (11-02): queued-sample bytes submitted so far (internal silence excluded), see PlaybackCredit
        // S2Arm (10-22 杂音): 起播前预充的在途下限（字节）。在途凑够它之前，缓冲已排进设备但不让设备开播（pre-roll），
        // 这样一开声就有深度，不会每个游戏缓冲边界掐边欠载（输出端每 21.3 ms 插静音 = 宽频噪声）。0 = 不设下限（旧行为）。
        private long _primeFloorBytes;
        private readonly long _cushionBytes;   // S2Arm: 补垫深度固定为构造时的预充深度；SetPrimeFloor 只改起播门槛，不改补垫
        private int _primed;   // 0/1，Volatile：在途首次达下限后置 1，之后一直 1（PrimedForStart）
        // S2Arm (10-23 马车8 杂音): 欠载后重建缓冲垫。开播后连续播放中途在途归零（一次 GC 停顿 / 渲染卡顿吃光了缓冲垫），
        //   游戏之后按实时节奏产出，产多少播多少，垫子永远补不回来：设备从此零余量播，每个 IO 周期都差一点（实测每秒约 42 次
        //   ≤4.8 ms 断口，就是杂音），直到收局。所以归零后 1 秒内再有数据，先补一块预充深度的静音再送：一次短停顿换回缓冲深度。
        //   延迟不累加（下一次卡顿先吃掉这块垫子）；归零超过 1 秒（游戏自己停了）不补。缺省开（10-23 马车8 测试设备1 同包 A/B 后翻缺省），S2A_AUDIO_CUSHION=0 关
        private static readonly bool _cushionOn = Environment.GetEnvironmentVariable("S2A_AUDIO_CUSHION") != "0";
        private long _zeroSince;   // 在途归零的时刻（Stopwatch；0 = 没归零 / 已补过）
        // S2Arm (11-02 太鼓爆音): 补垫只看设备播放时钟，不看在途记账。在途归零 ≠ 设备断了：设备（AudioQueue）把缓冲拷进自己的渲染缓冲就交还，
        //   交还时离真正播完还有约一个设备周期（Mac 实测交还时播放时钟比缓冲末尾早 620–750 帧）。按完成节奏供数的客人（太鼓：2 块 256 帧，
        //   交还一块马上补一块）每个设备周期都会让在途归零、0.1 ms 后就有新数据，设备其实没断；旧规则每次补 50 ms 静音，每 64 ms 只剩
        //   512 帧真声音（10 秒补垫 157 次 = 爆音、不连贯）。审计 P1-26 的「提前供数」判据挡住了单缓冲客人，挡不住双缓冲的。
        //   现在：设备每交还一块，记「播放时钟 − 这块在设备时间线上的末尾」（设备正常交还时的相位，最近 ClockWindow 次的最大值 = 基线）；
        //   归零后有新数据时，播放时钟越过已交声音末尾的量超出基线 + 容差，才是设备真的断了（卡顿吃光了垫），才补垫。
        //   AudioQueue 的时间线：缓冲不带时间戳时首尾相接（第 k 块从前面各块帧数之和开始），迟到的部分直接丢掉、播放时钟照走（11-02 Mac 小程序实测）
        private const int ClockWindow = 64;
        private const int ClockMinSamples = 8;
        private readonly long[] _slotEnd;          // 每个槽在设备时间线上的末尾（帧）
        private long _endFrames;                   // 已交设备的总帧数 = 设备时间线上已交声音的末尾
        private readonly long[] _clockPhase = new long[ClockWindow];   // 交还时「播放时钟 − 这块末尾」（帧）
        private int _clockN, _clockW;
        private readonly long _clockTolFrames;     // 判断断口的容差（帧）：新数据到达与交还之间的调度抖动
        // S2Arm (审计 P1-27): 设备停 / 重建期间不交缓冲（Restart）。交缓冲只在本泵锁下，设备仍持有的缓冲不会被再交一次
        private bool _suspended;

        /// <summary>
        /// Queued samples not yet submitted to the device.
        /// </summary>
        public AudioSampleQueue Samples { get; }

        /// <summary>
        /// S2Arm: true once in-flight first reached the prime floor. The device must not start playing before this
        /// (pre-roll); with floor 0 it is true from the first submit. Latches: stays true after a later drain.
        /// </summary>
        public bool PrimedForStart => Volatile.Read(ref _primed) != 0;

        protected DeviceBufferPump(int slots, int slotBytes, int bytesPerFrame, int maxCopiedBytes, long primeFloorBytes = 0, long clockTolFrames = 0)
        {
            _slotBytes = slotBytes / bytesPerFrame * bytesPerFrame;
            _bytesPerFrame = bytesPerFrame;
            _free = new int[slots];
            _filled = new int[slots];
            _sampleBytes = new int[slots];
            _slotEnd = new long[slots];
            _clockTolFrames = clockTolFrames;

            for (int i = slots - 1; i >= 0; i--)
            {
                _free[_freeCount++] = i;
            }

            _primeFloorBytes = primeFloorBytes / bytesPerFrame * bytesPerFrame;
            _cushionBytes = _primeFloorBytes;

            Samples = new AudioSampleQueue(maxCopiedBytes);
        }

        /// <summary>
        /// S2Arm: lower (or raise) the pre-roll floor before the device starts. A renderer-backed session (5 ms output,
        /// <see cref="Ryujinx.Audio.Common.AudioBuffer.Data"/> holds the samples) does not need the audout 64 ms pre-roll;
        /// the cushion depth is unaffected. Ignored once primed.
        /// </summary>
        public void SetPrimeFloor(long primeFloorBytes)
        {
            lock (_lock)
            {
                if (Volatile.Read(ref _primed) != 0)
                {
                    return;
                }

                _primeFloorBytes = primeFloorBytes / _bytesPerFrame * _bytesPerFrame;
            }
        }

        /// <summary>
        /// Bytes submitted to the device and not handed back yet.
        /// </summary>
        public long InFlightBytes => Interlocked.Read(ref _inFlightBytes);

        /// <summary>
        /// S2Arm: queued-sample bytes submitted to the device so far (internal silence excluded); their guest memory has been read.
        /// </summary>
        public long SubmittedSampleBytes => Interlocked.Read(ref _submittedSampleBytes);

        /// <summary>
        /// The memory of a pool buffer, at least slotBytes long.
        /// </summary>
        protected abstract Span<byte> SlotData(int slot);

        /// <summary>
        /// Submit pool buffer <paramref name="slot"/> holding <paramref name="bytes"/> bytes (called under the pump lock, in order).
        /// </summary>
        protected abstract void Submit(int slot, int bytes);

        /// <summary>
        /// A pool buffer of <paramref name="bytes"/> came back, <paramref name="inFlightAfter"/> bytes still in flight (under the pump lock).
        /// </summary>
        protected virtual void OnReturned(int bytes, long inFlightAfter)
        {
        }

        /// <summary>
        /// S2Arm: a cushion of <paramref name="bytes"/> bytes of silence was submitted after an underrun (under the pump lock);
        /// <paramref name="lateFrames"/>: how far the device clock had run past the end of the submitted audio, beyond its normal hand-back phase.
        /// </summary>
        protected virtual void OnCushion(int bytes, long zeroTicks, long lateFrames)
        {
        }

        /// <summary>
        /// S2Arm: the device's playback clock in frames, on the timeline the submitted buffers occupy back to back
        /// (AudioQueue: sample time of the queue's timeline); long.MinValue when unknown (no cushion is ever added then).
        /// </summary>
        protected virtual long DeviceClock() => long.MinValue;

        /// <summary>
        /// S2Arm: the device clock was paused, restarted or rebuilt: relearn its hand-back phase before judging gaps by it.
        /// </summary>
        public void ResetClock()
        {
            // S2Arm (11-14 iPhone 实机 声音服务卡死): no lock here. Stop (the game pausing, or closing) called this under the pump lock and
            //   waited for good behind a Pump stuck reading a stalled guest buffer; the pump applies the reset the next time it holds the lock
            Volatile.Write(ref _clockResetPending, 1);
        }

        private int _clockResetPending;

        // Under _lock
        private void ApplyClockResetLocked()
        {
            if (Interlocked.Exchange(ref _clockResetPending, 0) != 0)
            {
                _clockN = 0;
                _clockW = 0;
            }
        }

        // Under _lock. Frames the device clock is past the end of everything submitted, beyond the most it is past a buffer's end
        // when that buffer is handed back normally (≤ 0 = the device has not run dry); long.MinValue when there is no clock / no baseline yet
        private long DeviceLateLocked()
        {
            ApplyClockResetLocked();

            if (_clockN < ClockMinSamples)
            {
                return long.MinValue;
            }

            long now = DeviceClock();

            if (now == long.MinValue)
            {
                return long.MinValue;
            }

            long baseline = long.MinValue;
            int n = Math.Min(_clockN, ClockWindow);

            for (int i = 0; i < n; i++)
            {
                baseline = Math.Max(baseline, _clockPhase[i]);
            }

            return now - _endFrames - baseline;
        }

        // Under _lock: slot goes to the device, ending at _endFrames on its timeline
        private void SubmitLocked(int slot, int bytes)
        {
            _endFrames += bytes / _bytesPerFrame;
            _slotEnd[slot] = _endFrames;
            Submit(slot, bytes);
        }

        /// <summary>
        /// Move queued samples into free pool buffers and submit them.
        /// </summary>
        public void Pump()
        {
            lock (_lock)
            {
                while (_freeCount > 0 && !_suspended)
                {
                    int n = Math.Min(Samples.Length, _slotBytes) / _bytesPerFrame * _bytesPerFrame;

                    if (n == 0)
                    {
                        return;
                    }

                    // S2Arm: 欠载后先补一块静音重建缓冲垫（见 _cushionOn）；只在设备播放时钟证明真断了时补（见 _slotEnd）
                    if (_cushionOn && _primed != 0 && _zeroSince != 0 && Interlocked.Read(ref _inFlightBytes) == 0 && _freeCount > 1)
                    {
                        long zt = Stopwatch.GetTimestamp() - _zeroSince;
                        _zeroSince = 0;
                        long late = zt < Stopwatch.Frequency ? DeviceLateLocked() : long.MinValue;

                        if (late != long.MinValue && late > _clockTolFrames)
                        {
                            int z = (int)Math.Min(_cushionBytes, _slotBytes) / _bytesPerFrame * _bytesPerFrame;

                            if (z > 0)
                            {
                                int cs = _free[--_freeCount];
                                SlotData(cs)[..z].Clear();
                                _filled[cs] = z;
                                _sampleBytes[cs] = 0;
                                Interlocked.Add(ref _inFlightBytes, z);
                                OnCushion(z, zt, late);
                                SubmitLocked(cs, z);
                            }
                        }
                    }

                    _zeroSince = 0;
                    int slot = _free[--_freeCount];
                    int read = Samples.Read(SlotData(slot)[..n]);

                    _filled[slot] = read;
                    _sampleBytes[slot] = read;
                    Interlocked.Add(ref _submittedSampleBytes, read);
                    long inFlight = Interlocked.Add(ref _inFlightBytes, read);

                    // S2Arm: 在途凑够下限即可起播；闩锁后不再回退（一次欠载不该让后续重新 pre-roll）
                    if (_primed == 0 && inFlight >= _primeFloorBytes)
                    {
                        Volatile.Write(ref _primed, 1);
                    }

                    SubmitLocked(slot, read);
                }
            }
        }

        /// <summary>
        /// S2Arm: start the device anyway (prime floor could not be reached, e.g. a quiet game): latch primed so the
        /// caller's start gate opens. Only raises; never lowers.
        /// </summary>
        public void ForcePrimed()
        {
            Volatile.Write(ref _primed, 1);
        }

        /// <summary>
        /// S2Arm (11-14 iPhone 实机 声音服务卡死): stop submitting for good, if the pump lock comes free within <paramref name="wait"/>.
        /// False: a Pump is stuck inside (reading a stalled guest buffer, AudioSampleQueue.Read): the caller must not free the device's
        /// buffers, which that Pump still writes into and submits when it returns.
        /// </summary>
        public bool TrySuspend(TimeSpan wait)
        {
            if (!_lock.TryEnter(wait))
            {
                return false;
            }

            try
            {
                _suspended = true;
            }
            finally
            {
                _lock.Exit();
            }

            return true;
        }

        /// <summary>
        /// S2Arm (10-23 声音停了自愈；审计 P1-27 只留一个交缓冲的): stop (or rebuild) the device with no buffer submitted meanwhile.
        /// <paramref name="stopDevice"/> stops the device synchronously; buffers it hands back while stopping come through
        /// <see cref="Returned"/>, and a Pump from the callback or the queueing thread submits nothing until it returns (a buffer
        /// the device still holds must never be submitted again). It returns 0 when the device holds no buffer any more (stopped,
        /// or destroyed with its buffers): only then is every buffer still in flight put back into the pool.
        /// </summary>
        /// <returns>Queued-sample bytes reclaimed without being played, excluding internal silence.</returns>
        public int Restart(Func<int> stopDevice)
        {
            lock (_lock)
            {
                _suspended = true;
            }

            int rc = -1, reclaimed = 0;

            try
            {
                rc = stopDevice();
            }
            finally
            {
                lock (_lock)
                {
                    reclaimed = rc == 0 ? ReclaimAllLocked() : 0;
                    _suspended = false;
                }
            }

            return reclaimed;
        }

        // Under _lock
        private int ReclaimAllLocked()
        {
            int totalBytes = 0;
            int sampleBytes = 0;

            for (int slot = 0; slot < _filled.Length; slot++)
            {
                int bytes = _filled[slot];

                if (bytes == 0)
                {
                    continue;
                }

                _filled[slot] = 0;
                _free[_freeCount++] = slot;
                totalBytes += bytes;
                sampleBytes += _sampleBytes[slot];
                _sampleBytes[slot] = 0;
            }

            Interlocked.Add(ref _inFlightBytes, -totalBytes);
            _clockN = _clockW = 0;   // 设备停了 / 重建了：时间线从头算，重新学交还相位

            return sampleBytes;
        }

        /// <summary>
        /// The device handed pool buffer <paramref name="slot"/> back.
        /// </summary>
        /// <returns>Queued-sample bytes handed back (0 for internal silence or a slot not in flight).</returns>
        public int Returned(int slot)
        {
            lock (_lock)
            {
                int bytes = _filled[slot];

                if (bytes == 0 && Array.IndexOf(_free, slot, 0, _freeCount) >= 0)
                {
                    return 0;
                }

                int sampleBytes = _sampleBytes[slot];
                _sampleBytes[slot] = 0;
                _filled[slot] = 0;
                _free[_freeCount++] = slot;
                long inFlight = Interlocked.Add(ref _inFlightBytes, -bytes);

                ApplyClockResetLocked();

                if (bytes > 0 && !_suspended)
                {
                    // S2Arm: 设备正常交还时的相位（播放时钟 − 这块末尾），判断断口的基线（停 / 重建设备期间不读：队列可能正在销毁，停完反正重学）
                    long clock = DeviceClock();

                    if (clock != long.MinValue)
                    {
                        _clockPhase[_clockW] = clock - _slotEnd[slot];
                        _clockW = (_clockW + 1) % ClockWindow;
                        _clockN++;
                    }
                }

                if (inFlight == 0 && bytes > 0)
                {
                    _zeroSince = Stopwatch.GetTimestamp();
                }

                OnReturned(bytes, inFlight);

                return sampleBytes;
            }
        }
    }
}
