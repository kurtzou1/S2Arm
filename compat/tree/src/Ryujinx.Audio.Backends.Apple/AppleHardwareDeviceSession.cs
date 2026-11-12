using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Runtime.Versioning;
using Ryujinx.Audio.Backends.Apple.Native;   // 平台例外：Apple 后端平台实现内部引用本平台 Native 布局类型
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;

namespace Ryujinx.Audio.Backends.Apple
{
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    class AppleHardwareDeviceSession : HardwareDeviceSessionOutputBase
    {
        // S2Arm: a pool of 32 device buffers of up to 50 ms each, filled as soon as samples are queued (DeviceBufferPump), instead of
        // 3 buffers of 10 ms refilled only from the device callback. 50 ms holds a whole game buffer (witcher3 audout: 1024 frames =
        // 21.3 ms; at 20 ms each one went out as 960 + 64 frames, two hand-backs per buffer)
        private const int NumBuffers = 32;
        private const int BufferMilliseconds = 50;
        // S2Arm (10-22 杂音): 起播前预充的在途下限（毫秒，约 3 个游戏缓冲 21.3 ms）。凑够才让设备开播，一开声就有深度；
        // 安静游戏凑不够时 StartFallbackMilliseconds 后照常开播。
        private const int PrimeMilliseconds = 64;
        private const long StartFallbackMilliseconds = 100;
        // S2Arm (11-09): renderer output (audren; AudioBuffer.Data holds the samples, see AudioBuffer.cs) is a steady 5 ms
        // producer and does not have audout's small-queue start underruns, which the 64 ms pre-roll was added for. A renderer
        // session lowers the start gate to 0 on its first buffer: with the push pump the 64 ms pre-roll otherwise becomes
        // permanent in-flight depth (Mac built-in speakers, synthetic audren producer: 115 ms with 64 ms pre-roll vs 55 ms with 0). The cushion
        // depth and the push / anti-GC behavior are unchanged. S2A_AUDIO_RENDERER_PRIME_MS=<ms> for A/B (default 0; 64 = old).
        private const int RendererPrimeMilliseconds = 0;
        private static readonly int _rendererPrimeMilliseconds = ParsePrime(Environment.GetEnvironmentVariable("S2A_AUDIO_RENDERER_PRIME_MS"));

        private readonly AppleHardwareDeviceDriver _driver;
        // S2Arm: queued buffers as (identifier, sample count) in a ring under _queueLock, instead of ConcurrentQueue<AppleAudioBuffer>:
        // that allocated an object per buffer, and its TryPeek marks the segment as preserved so dequeues never free slots
        // and every few buffers a new segment is allocated. Only the head can be partially played (_headPlayed).
        private (ulong DriverIdentifier, ulong SampleCount)[] _queued = new (ulong, ulong)[16];
        private int _queuedHead;
        private int _queuedCount;
        private ulong _headPlayed;
        private readonly object _queueLock = new();
        // S2Arm: queued samples (guest buffers pulled on demand, renderer output copied into at most 1 s of audio), instead of a
        // DynamicRingBuffer copy of everything queued; see AudioSampleQueue. The pump moves them into the device buffers
        private Pump _pump;
        private AudioSampleQueue _samples;
        // S2Arm (11-02 Pokopia iPhone 断续): queued samples count as played for the game one device pull ahead of the hand-backs
        //   (see PlaybackCredit); bursts of hand-backs ≤ 2 ms apart are one pull; the lead is at most 100 ms
        private PlaybackCredit _credit;
        // S2Arm (11-06 时之笛 iPhone 读档后永久静音): the queue's timeline ran ahead of the samples after it ran dry once (see QueueTimelineWatch).
        //   Counted on the device callback (hand-backs that left nothing in flight, bytes handed back), read by the watchdog every tick
        private QueueTimelineWatch _timeline;
        private int _zeroReturns;
        private long _returnedBytes, _timelineTicks;
        // S2Arm (11-02 Pokopia iPhone 杂音): releases each queued buffer when the credit's play head reaches its end, one per buffer
        //   like a Switch (see PlaybackCredit), instead of a whole device pull at each hand-back. Woken by hand-backs and new buffers
        private readonly AutoResetEvent _paceEvent = new(false);
        private const int CreditBurstGapMicroseconds = 2000;
        private const int CreditMaxLeadMilliseconds = 100;
        private readonly ManualResetEvent _updateRequiredEvent;

        private readonly AudioQueueOutputCallback _callbackDelegate;
        // Free must clear the actual field: calling it on a readonly GCHandle frees
        // a defensive copy, leaving a stale slot that another object can reuse.
        private GCHandle _gcHandle;
        private bool _disposed;

        private nint _audioQueue;
        private readonly nint[] _audioQueueBuffers = new nint[NumBuffers];
        // S2Arm (11-12 #767): 交还回调的缓冲→槽号查表——建队时随缓冲整表建好、原子发布（见 CreateQueue），回调免锁只读
        //   （见 OutputCallback）；回调是实时线程、每次交还都走，不该每次对 32 槽线性扫
        private Dictionary<nint, int> _bufferSlots;

        // S2Arm (#189): guest bytes/frame (6-channel PCM16) and device bytes/frame (stereo after the explicit downmix
        //   stage). Equal for every other configuration.
        private readonly int _guestBytesPerFrame;
        private readonly int _deviceChannelCount;
        // S2Arm (#189): null when the 6-channel stream goes to the queue as is (native, the default) or the session is not 6-channel.
        private readonly AppleOutputProcessor _processor;
        private readonly ConvertingReader _convertingReader;
        private byte[] _convertedData;

        private readonly int _bytesPerFrame;

        private ulong _playedSampleCount;
        private bool _started;
        private bool _primeConfigured;   // S2Arm (11-09): the first queued buffer decided the renderer/audout start gate (see ConfigurePrimeFloor)
        private bool _rendererProducer;  // S2Arm (11-12 功耗): 同一个首缓冲定性——渲染器（audren）缓冲样本在 Data 里、audout 客体缓冲 Data 空，用于播完唤醒的门（见 ProcessPlayedSamples）
        // S2Arm (10-22 杂音): AudioQueue 是否已 AudioQueueStart（预充满足或兜底后才启播）；_startTicks = Start 时刻
        private bool _queueRunning;
        private long _startTicks;
        private float _volume = 1f;

        private readonly object _lock = new();

        // S2Arm: underrun counters / S2A_AUDIO_WAV capture, see S2AOutputDiag
        private readonly S2AOutputDiag _diag;

        // S2Arm (10-23 维护者 塞尔达「杂音后没声」): 输出流自愈。开着播、在途有数据，设备却超过 StallMs 不回调 = 设备停了
        //   （系统停了队列：会话被打断 / 路由切换 / 媒体服务重置……，我们不会收到任何通知，之前就此永久没声）：
        //   iOS 重新激活音频会话 → 同步停队列 → 收回在途缓冲 → 重新排进去 → 开播。看门狗线程每 250 ms 查一次已登记会话。
        //   S2A_AUDIO_HEAL=0 关（同包 A/B）；S2A_AUDIO_TEST_STALL_AT=<秒>：开播后到点暂停一次队列（模拟系统停播，测试用）
        private const int StallMs = 1000;
        private const int HealBackoffMs = 2000;
        private static readonly bool _healOn = Environment.GetEnvironmentVariable("S2A_AUDIO_HEAL") != "0";
        private static readonly int _testStallAtS = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_STALL_AT"), out int s) ? s : 0;
        private static readonly AppleHardwareDeviceSession[] _watched = new AppleHardwareDeviceSession[8];
        private static int _watchdogStarted;
        private long _lastCallbackTicks;
        private long _lastHealTicks;
        private int _heals;
        private bool _testStallDone;
        // 测试钩子：S2A_AUDIO_TEST_PRODUCER_STALL_AT=<秒>:<毫秒> —— 开播后到点在送声音的入口（QueueBuffer）睡一次，模拟 GC 停顿卡住生产方、吃光缓冲垫
        private static readonly (int AtS, int Ms) _testProdStall = ParseProdStall(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_PRODUCER_STALL_AT"));
        private bool _testProdStallDone;
        private static (int, int) ParseProdStall(string v)
        {
            if (string.IsNullOrEmpty(v)) return (0, 0);
            string[] p = v.Split(':');
            return p.Length == 2 && int.TryParse(p[0], out int a) && int.TryParse(p[1], out int m) ? (a, m) : (0, 0);
        }

        private static int ParsePrime(string v)
        {
            return int.TryParse(v, out int ms) && ms >= 0 ? ms : RendererPrimeMilliseconds;
        }
        private static readonly int _testNoteAtS = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_NOTE_AT"), out int n) ? n : 0;
        private static readonly int _testResetAtS = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_RESET_AT"), out int r) ? r : 0;
        private bool _testNoteDone, _testResetDone;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void AudioQueueOutputCallback(
            nint userData,
            nint audioQueue,
            nint buffer);

        public AppleHardwareDeviceSession(
            AppleHardwareDeviceDriver driver,
            IVirtualMemoryManager memoryManager,
            SampleFormat requestedSampleFormat,
            uint requestedSampleRate,
            uint requestedChannelCount)
            : base(memoryManager, requestedSampleFormat, requestedSampleRate, requestedChannelCount)
        {
            _driver = driver;
            _updateRequiredEvent = driver.GetUpdateRequiredEvent();
            _callbackDelegate = OutputCallback;
            _guestBytesPerFrame = BackendHelper.GetSampleSize(requestedSampleFormat) * (int)requestedChannelCount;
            _deviceChannelCount = (int)requestedChannelCount;

            // S2Arm (#189): 显式下混——S2A_AUDIO_OUT=sys 时 6 声道混音在交给 AudioQueue 前由系统 AudioConverter 折成立体声。
            //   渲染器自己的回落下混（游戏没给 DownMixParameter 时 [1.0, 0.707, 0.251, 0.707]）没有归一化：FL+FC 各 0.9
            //   折到 1.536（2632/4800 采样削波）、六路全 0.9 折到 2.399（3484/4800 削波）；系统的显式下混归一化
            //   （前 0.4142、中置 / 同侧环绕 0.2929、LFE 丢弃，最坏 0.4142+2×0.2929=1.0）不削波。帧数不变，
            //   泵 / 播放信用 / 缓冲释放节奏不变，换档不改延迟；缺省 native 不走这里，行为同现状（渲染器自己下混）
            if (requestedChannelCount == 6)
            {
                string configuredMode = Environment.GetEnvironmentVariable("S2A_AUDIO_OUT");
                AppleOutputMode mode = AppleOutputModeSelector.FromEnvironment();

                if (mode != AppleOutputMode.Native)
                {
                    if (requestedSampleFormat != SampleFormat.PcmInt16)
                    {
                        Console.Error.WriteLine($"[声] 【红】S2A_AUDIO_OUT={mode} 只支持 PCM16 的 5.1（本次 {requestedSampleFormat}）：按 native 直交 AudioQueue");
                    }
                    else
                    {
                        _deviceChannelCount = 2;
                        _processor = AppleOutputProcessor.Create(mode, (int)requestedSampleRate, MaxFrames);
                        Console.Error.WriteLine($"[声] 5.1→2.0 档「{AppleOutputModeSelector.ModeName(_processor.EffectiveMode)}」：6 声道 FL FR FC LFE BL BR → 2 声道（S2A_AUDIO_OUT；一片最多 {MaxFrames} 帧）" +
                            (_processor.InitError != null ? $"；【红】器件没建起来，这一路按矩阵下混：{_processor.InitError}" : ""));
                    }
                }
                else if (!string.IsNullOrWhiteSpace(configuredMode))
                {
                    Console.Error.WriteLine("[声] 5.1→2.0 档「native」：显式保持现状（渲染器自己下混）");
                }
            }

            _bytesPerFrame = BackendHelper.GetSampleSize(requestedSampleFormat) * _deviceChannelCount;
            _diag = S2AOutputDiag.Create(_bytesPerFrame, _deviceChannelCount, (int)requestedSampleRate, BackendHelper.GetSampleSize(requestedSampleFormat) * 8);
            _convertingReader = _processor != null ? new ConvertingReader(this, _processor) : null;

            _gcHandle = GCHandle.Alloc(this, GCHandleType.Normal);

            SetupAudioQueue();
            S2AWatch(this, true);
            new Thread(PaceLoop) { IsBackground = true, Name = "S2A.AudioPace" }.Start();
        }

        // S2Arm: 登记 / 注销看门狗（固定 8 槽，看门狗线程扫数组不分配）
        private static void S2AWatch(AppleHardwareDeviceSession s, bool add)
        {
            lock (_watched)
            {
                for (int i = 0; i < _watched.Length; i++)
                {
                    if (add ? _watched[i] == null : _watched[i] == s)
                    {
                        _watched[i] = add ? s : null;
                        break;
                    }
                }
            }

            if (add && Interlocked.Exchange(ref _watchdogStarted, 1) == 0)
            {
                new Thread(S2AWatchdogLoop) { IsBackground = true, Name = "S2A.AudioHeal" }.Start();
            }
        }

        private static void S2AWatchdogLoop()
        {
            S2AAudioNotes.Install();

            while (true)
            {
                Thread.Sleep(250);

                long now = Stopwatch.GetTimestamp();
                int notes = S2AAudioNotes.TakePending();

                // Removing a session during Dispose waits for a watchdog pass that already
                // selected it, so it cannot recover or touch a disposed AudioQueue.
                lock (_watched)
                for (int i = 0; i < _watched.Length; i++)
                {
                    AppleHardwareDeviceSession s = Volatile.Read(ref _watched[i]);

                    if (s == null)
                    {
                        continue;
                    }

                    s.S2ATestHooks(now);
                    s.S2APrimeFallback();

                    // 主路径：系统通知。中断结束 → 重新激活 + 重启；媒体服务重置 → 重建队列
                    if ((notes & (S2AAudioNotes.Ended | S2AAudioNotes.Reset)) != 0)
                    {
                        s.S2ARecover((notes & S2AAudioNotes.Reset) != 0 ? "系统通知：媒体服务重置" : "系统通知：中断结束", (notes & S2AAudioNotes.Reset) != 0, now, false);
                    }
                    else
                    {
                        s.S2ACheckStall(now);
                    }
                }
            }
        }

        // 测试钩子（缺省全关）：S2A_AUDIO_TEST_STALL_AT 外部停队列（只能靠兜底接）；S2A_AUDIO_TEST_NOTE_AT 模拟一次中断
        //   （投递 began → 像系统那样停队列 → 投递 ended，走主路径）；S2A_AUDIO_TEST_RESET_AT 投递一次媒体服务重置
        private void S2ATestHooks(long now)
        {
            if (!_started || !_queueRunning)
            {
                return;
            }

            long since = now - _startTicks;

            if (_testStallAtS > 0 && !_testStallDone && since >= (long)_testStallAtS * Stopwatch.Frequency)
            {
                _testStallDone = true;
                int rc = AudioQueuePause(_audioQueue);
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testStallAtS} 秒外部暂停输出队列（不发任何通知，模拟系统悄悄停播），rc={rc}");
            }

            if (_testNoteAtS > 0 && !_testNoteDone && since >= (long)_testNoteAtS * Stopwatch.Frequency)
            {
                _testNoteDone = true;
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testNoteAtS} 秒模拟中断（投递 began → 停队列 → 投递 ended）");
                S2AAudioNotes.PostForTest("AVAudioSessionInterruptionNotification", 1);
                AudioQueuePause(_audioQueue);
                S2AAudioNotes.PostForTest("AVAudioSessionInterruptionNotification", 0);
            }

            if (_testResetAtS > 0 && !_testResetDone && since >= (long)_testResetAtS * Stopwatch.Frequency)
            {
                _testResetDone = true;
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testResetAtS} 秒模拟媒体服务重置");
                S2AAudioNotes.PostForTest("AVAudioSessionMediaServicesWereResetNotification", -1);
            }
        }

        // S2Arm (10-24 #164 动森开场视频黑屏): 预充期的兜底启播要有人按时检查。原先只在 Start / 交下一块缓冲时检查：
        //   视频播放器经 AudioOut 只交一块 1024 帧（21 ms < 预充下限 64 ms）、等它播完才交下一块，没人再来检查，设备永不开播，
        //   游戏线程空转等这块播完、视频按声音时钟一帧不要（iPad 局：输出 #2 回调 0 次、交设备 1024 帧，整段视频全黑）。看门狗每 250 ms 补一次检查
        private void S2APrimeFallback()
        {
            if (!Volatile.Read(ref _started) || _queueRunning)
            {
                return;
            }

            lock (_lock)
            {
                MaybeStartQueue();
            }
        }

        // 兜底：开着播、在途有数据，设备却超过 StallMs 不回调。每次触发都打【红】，带上最近一条系统通知，免得悄悄盖住别的毛病
        private void S2ACheckStall(long now)
        {
            int zero = Interlocked.Exchange(ref _zeroReturns, 0);
            long returned = Interlocked.Exchange(ref _returnedBytes, 0), elapsed = now - _timelineTicks;

            _timelineTicks = now;

            if (!_started || !_queueRunning)
            {
                _timeline.Reset();

                return;
            }

            if (_timeline.Tick(zero, returned, elapsed) && now - _lastHealTicks >= (long)HealBackoffMs * Stopwatch.Frequency / 1000)
            {
                S2ARecover($"队列时间轴跑到声音前面（这 {elapsed * 1000 / Stopwatch.Frequency} ms 交还 {returned / _bytesPerFrame} 帧、{zero} 次交还后在途为 0：欠载后交的缓冲排在已过去的时刻，没播就交还）",
                           false, now, false);

                return;
            }

            long stall = now - Volatile.Read(ref _lastCallbackTicks);

            if (stall < (long)StallMs * Stopwatch.Frequency / 1000 || _pump.InFlightBytes == 0)
            {
                return;
            }

            if (!_healOn)
            {
                if (_heals++ == 0)
                {
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：设备 {stall * 1000 / Stopwatch.Frequency} ms 没有回调（在途 {_pump.InFlightBytes / _bytesPerFrame} 帧），自愈已关（S2A_AUDIO_HEAL=0）");
                }

                return;
            }

            // 系统中断期间（见过 began、没见 ended）声音在别人手里，重启多半失败：拉长间隔，不刷屏
            int backoff = S2AAudioNotes.Interrupted ? HealBackoffMs * 5 : HealBackoffMs;

            if (now - _lastHealTicks < (long)backoff * Stopwatch.Frequency / 1000)
            {
                return;
            }

            // Full thread dumps suspend every other thread while collecting stacks.
            // Opt in explicitly for diagnosis; normal audio recovery must not pause the game.
            if (s_stallDumpOn && Interlocked.Increment(ref s_stallDumps) <= 3)
            {
                try
                {
                    s2a_dump_threads($"声音设备 {stall * 1000 / Stopwatch.Frequency} ms 没有回调");
                }
                catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
                {
                    // 宿主之外（服务层单测直接跑托管代码）没有原生库：现场只是诊断，不影响下面的自愈
                    Console.Error.WriteLine($"[声] 全线程现场不可用（{e.GetType().Name}）");
                }
            }

            S2ARecover($"兜底：设备 {stall * 1000 / Stopwatch.Frequency} ms 没有回调{(S2AAudioNotes.Interrupted ? "（系统中断中）" : "")}，最近系统通知 {S2AAudioNotes.Last}", false, now, true);
        }

        private static readonly bool s_stallDumpOn = Environment.GetEnvironmentVariable("S2A_AUDIO_STALL_DUMP") == "1";
        private static int s_stallDumps;

        [DllImport("s2a_native")]
        private static extern int s2a_dump_threads(string why);   // runtime/src/tdump.c：全线程宿主栈（自动玩家卡住、崩溃时同一份）

        // 恢复输出流：iOS 重新激活会话 → 同步停队列（重置时重建）→ 收回在途 → 重新排进去 → 开播
        private void S2ARecover(string why, bool rebuild, long now, bool red)
        {
            if (!_healOn)
            {
                Console.Error.WriteLine($"[声] {why}；自愈已关（S2A_AUDIO_HEAL=0），不处理");

                return;
            }

            lock (_lock)
            {
                if (_audioQueue == nint.Zero)
                {
                    return;
                }

                _lastHealTicks = now;
                long inFlightFrames = _pump.InFlightBytes / _bytesPerFrame;
                bool active = _driver.S2AReactivateSession();
                int stopRc = 0, newRc = 0;
                // 停 / 重建期间泵不交缓冲（审计 P1-27）：同步停队列时缓冲经回调交还，回调和游戏线程的 Pump 此时什么都不交；
                //   原先它们照交，收回又把队列仍持有的缓冲放回池里、这里再交一次 = 同一块缓冲入队两次。停失败（缓冲可能还在队列里）不收回
                int reclaimed = _pump.Restart(() =>
                {
                    stopRc = AudioQueueStop(_audioQueue, true);

                    if (!rebuild)
                    {
                        return stopRc;
                    }

                    AudioQueueDispose(_audioQueue, true);
                    newRc = CreateQueue();

                    return 0;   // 旧队列连同它的缓冲已销毁：在途的槽全部收回
                });

                // 收回的真实样本没播，但当作已播完：让游戏的缓冲照常放回去（丢掉不到 1.6 秒声音），内部补垫不计入完成额度
                if (reclaimed > 0)
                {
                    _credit.Reclaimed(reclaimed);
                    S2ACredit();
                }

                int startRc = -1;

                // 游戏自己停着播（Stop）就只恢复好队列，等它 Start
                if (_started && newRc == 0)
                {
                    _pump.Pump();
                    S2ACredit();
                    startRc = AudioQueueStart(_audioQueue, nint.Zero);
                    _queueRunning = startRc == 0;
                }
                else
                {
                    _queueRunning = false;
                }

                Volatile.Write(ref _lastCallbackTicks, Stopwatch.GetTimestamp());

                Console.Error.WriteLine($"[声] {(red ? "【红】" : "")}输出 #{_diag.Index}：{why}（在途 {inFlightFrames} 帧）→ {(rebuild ? "重建" : "重启")}输出队列（第 {++_heals} 次）：" +
                    $"{(OperatingSystem.IsIOS() ? $"重新激活音频会话 {(active ? "成功" : "失败")}、" : "")}停队列 rc={stopRc}、收回 {reclaimed / _bytesPerFrame} 帧" +
                    $"{(rebuild ? $"、新建队列 rc={newRc}" : "")}、重新开播 rc={startRc}{(startRc == 0 ? "" : "（没开播：游戏停着或开播失败，下一笔声音到时再试）")}");
            }
        }

        private void SetupAudioQueue()
        {
            lock (_lock)
            {
                int result = CreateQueue();

                if (result != 0)
                {
                    throw new InvalidOperationException($"AudioQueueNewOutput failed: {result}");
                }

                _pump = new Pump(this, (int)BufferBytes);
                _samples = _pump.Samples;
                _credit = new PlaybackCredit(_bytesPerFrame, (long)_bytesPerFrame * RequestedSampleRate,
                                             (long)_bytesPerFrame * RequestedSampleRate * CreditMaxLeadMilliseconds / 1000,
                                             Stopwatch.Frequency * CreditBurstGapMicroseconds / 1_000_000);
                _timeline = new QueueTimelineWatch((long)_bytesPerFrame * RequestedSampleRate);
            }
        }

        private uint BufferBytes => RequestedSampleRate * BufferMilliseconds / 1000 * (uint)_bytesPerFrame;

        // S2Arm (#189): a downmix slice holds at most one device buffer worth of frames
        private int MaxFrames => (int)(RequestedSampleRate * BufferMilliseconds / 1000);

        // S2Arm (#189): frame count of a queued buffer in device bytes. Equivalent to the base helper for native
        //   sessions; for a folded 6-channel session DataSize holds stereo bytes, so RequestedChannelCount must not be used.
        private ulong GetFrameCount(AudioBuffer buffer) => buffer.DataSize / (ulong)_bytesPerFrame;

        // S2Arm: 建 AudioQueue 和它的 32 个缓冲（起会话与媒体服务重置后重建共用）。缓冲放回同一个数组：泵按槽号取，换队列不用换泵
        private int CreateQueue()
        {
            // S2Arm (#189): the queue is in the device format — stereo when the explicit downmix folds the 6-channel
            //   stream first (the 6-channel PCM16 the renderer produces is _deviceChannelCount's business), 6-channel otherwise
            AudioStreamBasicDescription format = AppleHardwareDeviceDriver.GetAudioFormat(RequestedSampleFormat, RequestedSampleRate, (uint)_deviceChannelCount);   // 平台例外：Apple 后端平台实现内部的队列格式（#189）
            nint callbackPtr = Marshal.GetFunctionPointerForDelegate(_callbackDelegate);
            nint userData = GCHandle.ToIntPtr(_gcHandle);
            int result = AudioQueueNewOutput(ref format, callbackPtr, userData, nint.Zero, nint.Zero, 0, out _audioQueue);

            if (result != 0)
            {
                _audioQueue = nint.Zero;

                return result;
            }

            // S2Arm（#189）：6 声道队列声明 5.1 布局（起会话与重建共用这条路径）：不声明时系统隐式 6→2 只复制
            //   FL/FR，中置（对白）与环绕整段丢失；真 5.1 设备声明后按布局直通。设置失败按无布局继续（打出【红】，
            //   行为同旧），真 5.1 设备探建时已验过布局可用。显式下混的队列是 2 声道（折叠已在前），不设布局
            if (_deviceChannelCount == 6)
            {
                AudioChannelLayout layout = new AudioChannelLayout
                {
                    AudioChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A,
                    AudioChannelBitmap = 0,
                    NumberChannelDescriptions = 0
                };

                int layoutResult = AudioQueueSetProperty(
                    _audioQueue,
                    kAudioQueueProperty_ChannelLayout,
                    ref layout,
                    (uint)Marshal.SizeOf<AudioChannelLayout>());

                if (layoutResult != 0)
                {
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：声明 5.1 布局失败 rc={layoutResult}（按无布局继续，中置 / 环绕可能丢失）");
                }
            }

            // S2Arm (11-12 #767): 缓冲→槽号表随缓冲一起整表建好再原子发布：重建期间旧队列迟到的交还
            //   查旧表命中 / 查新表落空，都同旧数组扫描的「查不到就返回」，见不到半张表
            Dictionary<nint, int> bufferSlots = new(NumBuffers);

            for (int i = 0; i < NumBuffers; i++)
            {
                AudioQueueAllocateBuffer(_audioQueue, BufferBytes, out _audioQueueBuffers[i]);
                bufferSlots[_audioQueueBuffers[i]] = i;
            }

            Volatile.Write(ref _bufferSlots, bufferSlots);

            return 0;
        }

        // S2Arm: the device side of DeviceBufferPump: pool buffer i is _audioQueueBuffers[i]
        private sealed unsafe class Pump : DeviceBufferPump
        {
            private readonly AppleHardwareDeviceSession _s;

            public Pump(AppleHardwareDeviceSession s, int bufferBytes)
                // S2Arm (10-22 杂音): 起播前预充 PrimeMilliseconds 的在途下限（约 3 个游戏缓冲），凑够才让设备开播
                : base(NumBuffers, bufferBytes, s._bytesPerFrame, s._bytesPerFrame * (int)s.RequestedSampleRate,
                       (long)s._bytesPerFrame * s.RequestedSampleRate * PrimeMilliseconds / 1000)
            {
                _s = s;
            }

            // S2Arm (11-03 太鼓 iPhone 断续): 不取设备播放时钟（DeviceClock 留缺省 MinValue：补垫不补）。11-02 太鼓爆音修复在每次交还时调
            //   AudioQueueGetCurrentTime（问音频服务进程）判补垫，iPhone 上这个调用本身打乱输出：调用每 10 秒有 5–18 次超过 10 ms（最长约 50 ms），
            //   每次都碰上设备交还和游戏交声音一起停 40–50 ms、设备吃空断音约 55 ms。测试设备1 太鼓同包 A/B 各 74 秒：每 100 ms 调一次 → 交设备
            //   >30 ms 空档 42 次、回调最长间隔 55–67 ms；完全不调 → 0 次、21.6–21.8 ms（= 一拉，同修复前的别的款）。
            //   补垫原为欠载后重建缓冲深度（10-23 马车8）；放回提前量（PlaybackCredit，11-02）让客人始终比交还多送一拉，欠载后深度随之回来

            protected override Span<byte> SlotData(int slot)
            {
                AudioQueueBuffer* buffer = (AudioQueueBuffer*)_s._audioQueueBuffers[slot];

                return new Span<byte>((void*)buffer->AudioData, (int)buffer->AudioDataBytesCapacity);
            }

            protected override void Submit(int slot, int bytes)
            {
                nint bufferPtr = _s._audioQueueBuffers[slot];
                AudioQueueBuffer* buffer = (AudioQueueBuffer*)bufferPtr;

                _s.ApplyVolume(buffer->AudioData, bytes);
                buffer->AudioDataByteSize = (uint)bytes;
                _s._diag.OnSubmit(new ReadOnlySpan<byte>((void*)buffer->AudioData, bytes), InFlightBytes - bytes);

                AudioQueueEnqueueBuffer(_s._audioQueue, bufferPtr, 0, nint.Zero);
            }

            protected override void OnReturned(int bytes, long inFlightAfter)
            {
                _s._diag.OnReturned(bytes, inFlightAfter);
                Interlocked.Add(ref _s._returnedBytes, bytes);

                if (inFlightAfter == 0)
                {
                    Interlocked.Increment(ref _s._zeroReturns);
                }
            }

            // S2Arm (10-23 马车8 杂音): 欠载后补静音垫。这里在游戏的 AppendBuffer 线程上，只记数（零分配，服务层零分配单测守着）；
            //   行由 S2AOutputDiag 的 10 秒汇报线程打
            protected override void OnCushion(int bytes, long zeroTicks, long lateFrames) => _s._diag.OnCushion(bytes / _s._bytesPerFrame, zeroTicks, lateFrames);
        }

        private void OutputCallback(nint userData, nint audioQueue, nint bufferPtr)
        {
            Ryujinx.Common.S2AThreadAlloc.Tick("CoreAudio 回调"); // S2Arm: per-thread allocation accounting
            Volatile.Write(ref _lastCallbackTicks, Stopwatch.GetTimestamp()); // S2Arm: 停播看门狗（S2ACheckStall）

            if (bufferPtr == nint.Zero)
                return;

            // S2Arm (11-12 #767): 槽号改查表（建表见 CreateQueue）：实时回调里不再对 32 槽线性扫；
            //   查不到（重建后旧队列的迟到交还）照旧直接返回——本回调从不解引用未认出的指针，同旧扫描
            if (!Volatile.Read(ref _bufferSlots).TryGetValue(bufferPtr, out int bufferIndex))
                return;

            // S2Arm: recycle every returned device buffer, but advance guest progress only for its queued-sample bytes,
            //   one device pull ahead of the hand-backs (PlaybackCredit)
            int bytesPlayed = _pump.Returned(bufferIndex);
            _credit.Returned(bytesPlayed, Stopwatch.GetTimestamp());
            _diag.SetLead(_credit.LeadBytes / _bytesPerFrame);

            if (_started)
            {
                _pump.Pump();
            }

            S2ACredit();
            _paceEvent.Set();
        }

        // S2Arm (11-02): release what now counts as played (handed back, or submitted and passed by the credit's play head)
        private void S2ACredit()
        {
            int bytes = _credit.Take(_pump.SubmittedSampleBytes, Stopwatch.GetTimestamp());

            if (bytes > 0)
            {
                ProcessPlayedSamples(bytes);
            }
        }

        // S2Arm (11-02 Pokopia iPhone 杂音): sleep until the head buffer is due (its unplayed rest passed by the play head), release it,
        //   repeat; with nothing queued, or the head beyond the cap, wait for a hand-back or a new buffer
        private void PaceLoop()
        {
            while (!Volatile.Read(ref _disposed))
            {
                S2ACredit();

                long rest;
                lock (_queueLock)
                {
                    rest = _queuedCount == 0 ? -1 : (long)(_queued[_queuedHead].SampleCount - _headPlayed) * _bytesPerFrame;
                }

                long ticks = rest < 0 ? long.MaxValue : _credit.TicksUntil(rest, _pump.SubmittedSampleBytes, Stopwatch.GetTimestamp());

                if (ticks == long.MaxValue)
                {
                    _paceEvent.WaitOne();
                }
                else if (ticks > 0)
                {
                    _paceEvent.WaitOne((int)Math.Min(1000, (ticks * 1000 + Stopwatch.Frequency - 1) / Stopwatch.Frequency));
                }
            }
        }

        private void ProcessPlayedSamples(int bytesPlayed)
        {
            // S2Arm (#189): device bytes (stereo after the explicit downmix); the base helper would use the requested
            //   6 channels. Frame counts are preserved by the fold, so guest and device frames agree.
            ulong samplesPlayed = (ulong)bytesPlayed / (ulong)_bytesPerFrame;
            ulong remaining = samplesPlayed;
            bool needUpdate = false;

            lock (_queueLock)
            {
                while (remaining > 0 && _queuedCount > 0)
                {
                    ulong sampleCount = _queued[_queuedHead].SampleCount;
                    ulong take = Math.Min(sampleCount - _headPlayed, remaining);

                    _headPlayed += take;
                    remaining -= take;

                    if (_headPlayed == sampleCount)
                    {
                        _queuedHead = (_queuedHead + 1) % _queued.Length;
                        _queuedCount--;
                        _headPlayed = 0;
                        needUpdate = true;
                    }

                    Interlocked.Add(ref _playedSampleCount, take);
                }
            }

            // S2Arm (11-12 功耗): 播完需要唤醒 AudioManager.Worker 的只有 audout 的客体缓冲——Worker 醒来只做
            //   AudioOutputManager.Update / AudioInputManager.Update（AudioManagers 的接线），即 audout / audin 会话的
            //   缓冲释放；audren 游戏自己的更新事件在 5 ms 渲染线程上直接 Signal（AudioRenderSystem.SendCommands）。
            //   渲染器会话每个 5 ms 块播完也置一次事件：纯 audren 游戏把 Worker 每秒叫醒约 200 次，只为扫两圈空
            //   会话数组。生产方定性来自首个缓冲（见 ConfigurePrimeFloor）；audout / audsmx 客体缓冲照旧唤醒。
            if (needUpdate && !_rendererProducer)
            {
                _updateRequiredEvent.Set();
            }
        }

        private unsafe void ApplyVolume(nint dataPtr, int byteSize)
        {
            float volume = Math.Clamp(_volume * _driver.Volume, 0f, 1f);
            if (volume >= 0.999f)
                return;

            int sampleCount = byteSize / BackendHelper.GetSampleSize(RequestedSampleFormat);

            switch (RequestedSampleFormat)
            {
                case SampleFormat.PcmInt16:
                    short* s16 = (short*)dataPtr;
                    for (int i = 0; i < sampleCount; i++)
                        s16[i] = (short)(s16[i] * volume);
                    break;

                case SampleFormat.PcmFloat:
                    float* f32 = (float*)dataPtr;
                    for (int i = 0; i < sampleCount; i++)
                        f32[i] *= volume;
                    break;

                case SampleFormat.PcmInt32:
                    int* s32 = (int*)dataPtr;
                    for (int i = 0; i < sampleCount; i++)
                        s32[i] = (int)(s32[i] * volume);
                    break;

                case SampleFormat.PcmInt8:
                    sbyte* s8 = (sbyte*)dataPtr;
                    for (int i = 0; i < sampleCount; i++)
                        s8[i] = (sbyte)(s8[i] * volume);
                    break;
            }
        }

        // S2Arm (11-09): the first buffer tells the producer apart. Renderer output (audren) carries its samples in Data;
        // an AudioOut guest buffer keeps them in guest memory (Data == null, SampleReader set by RegisterBuffer). The latter
        // keeps the 64 ms pre-roll that fixed audout's start underruns; the former starts on its first 5 ms block.
        // S2Arm (11-12 功耗): 定性顺带记给播完唤醒的门用（见 ProcessPlayedSamples）。
        private void ConfigurePrimeFloor(AudioBuffer buffer)
        {
            if (_primeConfigured)
            {
                return;
            }

            _primeConfigured = true;
            _rendererProducer = buffer.Data != null;

            if (buffer.Data == null || _rendererPrimeMilliseconds == PrimeMilliseconds)
            {
                return;
            }

            _pump.SetPrimeFloor((long)_bytesPerFrame * RequestedSampleRate * _rendererPrimeMilliseconds / 1000);
        }

        // S2Arm (#189): guest buffers (no Data array) are folded while the device reads them (AudioSampleQueue ->
        //   ReadSamples through SampleReader), so the samples stay in guest memory and the session's frame accounting,
        //   credit and release cadence are unchanged. The buffer's size is told in device bytes from here on.
        public override bool RegisterBuffer(AudioBuffer buffer)
        {
            if (buffer.DataPointer == 0)
            {
                return false;
            }

            if (_processor == null)
            {
                return base.RegisterBuffer(buffer);
            }

            ulong frames = buffer.DataSize / (ulong)_guestBytesPerFrame;

            buffer.DataSize = frames * (ulong)_bytesPerFrame;
            _convertingReader.Inner = buffer.SampleReader ?? this;
            buffer.SampleReader = _convertingReader;

            return true;
        }

        public override void QueueBuffer(AudioBuffer buffer)
        {
            ConfigurePrimeFloor(buffer);

            if (_testProdStall.AtS > 0 && !_testProdStallDone && _started && Stopwatch.GetTimestamp() - _startTicks >= (long)_testProdStall.AtS * Stopwatch.Frequency)
            {
                _testProdStallDone = true;
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testProdStall.AtS} 秒生产方停 {_testProdStall.Ms} ms（模拟 GC 停顿）");
                Thread.Sleep(_testProdStall.Ms);
            }

            // S2Arm (#189): renderer buffers (Data) are copied in by AudioSampleQueue right below, so one staging
            //   array can be reused; the queue never reads it after Enqueue returns. Guest bytes (6-channel) are
            //   folded to device bytes (stereo) first; the frame count is unchanged.
            if (_processor != null && buffer.Data != null)
            {
                int frames = buffer.Data.Length / _guestBytesPerFrame;
                int outputBytes = frames * _bytesPerFrame;

                if (_convertedData == null || _convertedData.Length != outputBytes)
                {
                    _convertedData = new byte[outputBytes];
                }

                _processor.Process(buffer.Data.AsSpan(0, frames * _guestBytesPerFrame), _convertedData);
                buffer.Data = _convertedData;
                buffer.DataSize = (ulong)outputBytes;
            }

            ulong sampleCount = GetFrameCount(buffer);

            // S2Arm (11-02): register before its samples can be submitted: submitted samples may count as played at once (PlaybackCredit),
            //   and played samples must find their buffer in _queued
            lock (_queueLock)
            {
                if (_queuedCount == _queued.Length)
                {
                    var grown = new (ulong, ulong)[_queued.Length * 2];

                    for (int i = 0; i < _queuedCount; i++)
                    {
                        grown[i] = _queued[(_queuedHead + i) % _queued.Length];
                    }

                    _queued = grown;
                    _queuedHead = 0;
                }

                _queued[(_queuedHead + _queuedCount) % _queued.Length] = (buffer.DataPointer, sampleCount);
                _queuedCount++;
            }

            _samples.Enqueue(buffer);

            if (_started)
            {
                _pump.Pump();
                S2ACredit();
                _paceEvent.Set();
                // S2Arm (10-22 杂音): 预充期排进设备但未启播——凑够下限的这一笔到了就开播
                if (!_queueRunning)
                {
                    lock (_lock)
                    {
                        MaybeStartQueue();
                    }
                }
            }
        }

        public override void Start()
        {
            lock (_lock)
            {
                if (_started)
                    return;

                _started = true;
                _diag.SetStarted(true);
                _startTicks = Stopwatch.GetTimestamp();
                _pump.Pump();
                S2ACredit();

                Volatile.Write(ref _lastCallbackTicks, _startTicks); // S2Arm: 停播看门狗从开播时刻起算

                if (_queueRunning)
                {
                    // 从 Stop 的暂停恢复：队列已预充过，直接续播
                    AudioQueueStart(_audioQueue, nint.Zero);
                }
                else
                {
                    // 首次启播：先 pre-roll，在途凑够下限（或兜底超时）再 AudioQueueStart
                    MaybeStartQueue();
                }
            }
        }

        // S2Arm (10-22 杂音): 在途达预充下限（或 Start 后超过兜底时限）才让设备开播，起播有深度不掐边欠载。_lock 内调。
        private void MaybeStartQueue()
        {
            if (_queueRunning || !_started)
            {
                return;
            }

            if (!_pump.PrimedForStart &&
                (Stopwatch.GetTimestamp() - _startTicks) * 1000 / Stopwatch.Frequency >= StartFallbackMilliseconds)
            {
                _pump.ForcePrimed();
            }

            if (_pump.PrimedForStart)
            {
                _queueRunning = true;
                Volatile.Write(ref _lastCallbackTicks, Stopwatch.GetTimestamp()); // S2Arm: 停播看门狗从真开播起算
                AudioQueueStart(_audioQueue, nint.Zero);
            }
        }

        public override void Stop()
        {
            lock (_lock)
            {
                if (!_started)
                    return;

                _started = false;
                _diag.SetStarted(false);
                AudioQueuePause(_audioQueue);
                _pump.ResetClock();   // 暂停期间播放时钟怎么走不确定：续播后重新学交还相位
            }
        }

        public override ulong GetPlayedSampleCount()
            => Interlocked.Read(ref _playedSampleCount);

        public override float GetVolume() => _volume;
        public override void SetVolume(float volume) => _volume = volume;

        public override bool WasBufferFullyConsumed(AudioBuffer buffer)
        {
            lock (_queueLock)
            {
                return _queuedCount == 0 || _queued[_queuedHead].DriverIdentifier != buffer.DataPointer;
            }
        }

        public override void PrepareToClose() { }
        // S2Arm: the buffer goes back to the game (Stop / FlushBuffers / Dispose) possibly before it was played: keep what it held
        public override void UnregisterBuffer(AudioBuffer buffer) => _samples.Release(buffer);

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                // Match the watchdog's lock order (_watched, then _lock), and wait
                // for a pass that already selected this session before closing it.
                S2AWatch(this, false);
                lock (_lock)
                {
                    if (_disposed) return;
                    Stop();
                    _queueRunning = false;

                    if (_audioQueue != nint.Zero)
                    {
                        AudioQueueStop(_audioQueue, true);
                        int result = AudioQueueDispose(_audioQueue, true);
                        if (result != 0)
                            throw new InvalidOperationException($"AudioQueueDispose failed: {result}; callback handle retained");
                        _audioQueue = nint.Zero;
                    }

                    _processor?.Dispose();   // S2Arm (#189): the explicit downmix stage (AudioConverter) goes with the queue

                    // Synchronous queue disposal completes callbacks before their
                    // handle is released. A repeated Dispose cannot free a reused slot.
                    if (_gcHandle.IsAllocated) _gcHandle.Free();
                    _diag.Dispose();
                    _driver.Unregister(this);
                    Volatile.Write(ref _disposed, true);
                    _paceEvent.Set();
                }
            }
        }

        public override void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        // S2Arm (#189): the SampleReader the audio queue uses for guest buffers. It maps the device byte offset
        //   (stereo after folding) back to the guest stream (6-channel) and folds only the frames the queue asks for.
        private sealed class ConvertingReader : HardwareDeviceSessionOutputBase
        {
            private readonly AppleOutputProcessor _processor;
            private readonly int _guestBytesPerFrame;
            private readonly int _deviceBytesPerFrame;
            private HardwareDeviceSessionOutputBase _inner;
            private byte[] _scratch = Array.Empty<byte>();

            public ConvertingReader(AppleHardwareDeviceSession owner, AppleOutputProcessor processor)   // 平台例外：Apple 后端平台实现内部的下混读代理（#189）
                : base(owner.MemoryManager, owner.RequestedSampleFormat, owner.RequestedSampleRate, owner.RequestedChannelCount)
            {
                _processor = processor;
                _guestBytesPerFrame = owner._guestBytesPerFrame;
                _deviceBytesPerFrame = owner._bytesPerFrame;
            }

            public HardwareDeviceSessionOutputBase Inner
            {
                set => _inner = value;
            }

            public override void ReadSamples(AudioBuffer buffer, ulong offset, Span<byte> destination)
            {
                int frames = destination.Length / _deviceBytesPerFrame;
                int outputBytes = frames * _deviceBytesPerFrame;

                if (frames == 0)
                {
                    destination.Clear();

                    return;
                }

                int inputBytes = frames * _guestBytesPerFrame;

                if (_scratch.Length < inputBytes)
                {
                    _scratch = new byte[inputBytes];
                }

                ReadOnlySpan<byte> input = _scratch.AsSpan(0, inputBytes);
                ulong guestOffset = offset / (ulong)_deviceBytesPerFrame * (ulong)_guestBytesPerFrame;

                _inner.ReadSamples(buffer, guestOffset, _scratch.AsSpan(0, inputBytes));
                _processor.Process(input, destination[..outputBytes]);

                if (destination.Length > outputBytes)
                {
                    destination[outputBytes..].Clear();
                }
            }

            public override void Dispose() => throw new NotSupportedException();
            public override void PrepareToClose() => throw new NotSupportedException();
            public override void QueueBuffer(AudioBuffer buffer) => throw new NotSupportedException();
            public override void SetVolume(float volume) => throw new NotSupportedException();
            public override float GetVolume() => throw new NotSupportedException();
            public override void Start() => throw new NotSupportedException();
            public override void Stop() => throw new NotSupportedException();
            public override ulong GetPlayedSampleCount() => throw new NotSupportedException();
            public override bool WasBufferFullyConsumed(AudioBuffer buffer) => throw new NotSupportedException();
        }
    }
}
