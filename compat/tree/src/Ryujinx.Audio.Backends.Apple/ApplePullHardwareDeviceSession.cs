using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Memory;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Runtime.Versioning;
using Ryujinx.Audio.Backends.Apple.Native;   // 平台例外：Apple 后端平台实现内部引用本平台 Native 布局类型
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;   // 平台例外：Apple 后端平台实现（拉取会话，#2157）

namespace Ryujinx.Audio.Backends.Apple   // 平台例外：Apple 后端平台实现（拉取会话，#2157）
{
    // S2Arm (#2157 只留一种传输，AudioUnit 拉取取代 AudioQueue): 全树唯一的输出会话——设备 render 回调按节拍从一个
    //   主机侧 SPSC 拉取环直接拉 PCM，环由送数（pace）线程从 AudioSampleQueue 填充并完成下混 / 音量 / 诊断，欠载帧在
    //   回调里填零。macOS 用 DefaultOutput（AUHAL 特化、跟随用户默认输出设备），iOS/tvOS 用 RemoteIO（输出总线缺省即开）。
    //   原 AudioQueue 输出会话（AppleHardwareDeviceSession）整文件删除：停交还 200 ms 交还永不停机制（7d090b2cb 形状）
    //   连同看门狗静态结构、S2AThawGraceStep 一并迁进本类，全树仍只有一份（收音会话 AppleHardwareDeviceSessionInput 无放回语义）。
    // 「设备已渲染帧数」取代「缓冲交还」成为账目地板（PlaybackCredit 原类不改）:pace 每轮把上轮以来回调消费的环字节
    //   喂 _credit.Returned;环内恒为排队样本（写者从不写零，欠载零在环外填），欠载不进账目、不损队列状态。
    // 回调实时纪律（对照 #767/#769 与既有回调注释「回调线程不得等我们的锁、不得读客机内存」）:零锁（SPSC 指针各单写者,
    //   Volatile.Read 即得）、零分配（S2AThreadAlloc.Tick 首行 + 栈上操作）、不读客机内存（重活全在 pace 线程）、
    //   不调系统 API（只 memcpy + 计时 + 事件置位）。
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    class ApplePullHardwareDeviceSession : HardwareDeviceSessionOutputBase, Ryujinx.Audio.Integration.IS2AOutputDepth, Ryujinx.Audio.Integration.IS2AIOAwareDepth
    {
        // 静默机制（§5.1）: pace 线程的「AudioSampleQueue.Read(含客机内存读)→下混/音量→写环」整段持 _writeLock,
        //   对齐泵锁覆盖 Samples.Read 的结构(DeviceBufferPump.Pump 持锁覆盖 Samples.Read, DeviceBufferPump.cs:211-266);
        //   看门狗 / Dispose 侧 TryEnter(200ms) 检测「pace 卡在读客机内存」,拿到锁才在锁内代写指针(丢弃环内样本、
        //   重置环账目),拿不到走泄漏路径(停器件、红字、不重置,对齐 _closedStuck)
        private readonly object _writeLock = new();
        private bool _suspended;   // Volatile:置位后 render 回调不读环、直接填零返回,pace 不动环

        private const int NumBuffers = 32;   // 无设备播放的虚拟槽位数(平移现有 NumBuffers 口径,只做墙钟记账)
        // S2Arm (10-22 杂音 → #2157 §4.3): 起播门槛对两类生产方统一为 0(首个排队样本入环即开播)。
        //   64 ms 地板是「AudioQueue 起播欠载」对策(欠载 = 掐边静音 + 队列饿空 + 时间轴跑前的连锁事故);
        //   拉取模型下欠载 = 回调对一拍填零(§ 欠载填零),无队列状态损坏、无时间轴概念,预充的动机消失——
        //   保留它反而把低供给会话(供给 < 64 ms)推向 100 ms 兜底开播,人为制造首发缺口。
        //   S2A_AUDIO_PULL_PRIME_MS=<ms>(缺省 0;64 = 复现旧 64 ms 起播地板,100 ms 兜底与 250 ms 看门狗补查随地板一并启用)
        //   是维护方单变量 A/B 诊断通道(对齐 S2A_AUDIO_RENDERER_PRIME_MS 先例,原 AudioQueue 会话的 ParsePrime 同款)
        private static readonly int _primeMs = ParsePullPrime(Environment.GetEnvironmentVariable("S2A_AUDIO_PULL_PRIME_MS"));
        private const long StartFallbackMilliseconds = 100;   // 仅 prime>0 时启用(原 AudioQueue 会话同款)
        // 拉取环(§3.2/§4.2): 主机侧定长数组环,容量 _ringFrames 帧 × bytesPerFrame。寻址为帧域:_ringFrames 是 2 的幂,
        //   _ringRead/_ringWrite 是单调递增的帧偏移,掩码 _ringMask(_ringFrames-1)作用于帧下标,字节落点 = 帧下标 ×
        //   _bytesPerFrame——字节域掩码在 6ch PCM16(12 B/帧,非 2 的幂)上必错位,帧域寻址根治(§4.2 必改)。
        //   SPSC:唯一写者 = pace 线程(先写字节、再 Volatile.Write 发布 _ringWrite);唯一读者 = render 回调
        //   (先 Volatile.Read 得可见量、再读环数组、消费完才发布 _ringRead)。环内存为托管 byte[],回调每次进入重新取
        //   字段引用转 Span,不跨调用持有非固定指针(GC compact 对其透明)
        // S2Arm (#2157 评审 #15,玩家 #1308 诊断 D-BEKN,Mac M4 内置扬声器): 容量/配速水位按设备实际 IO 周期取——
        //   固定 1024 帧(≈21.3 ms @48k)在 IO 周期 4096 帧(≈85 ms)的设备上,一次回调要 4096 帧、环里只有 1024 帧,
        //   每拍欠载出爆音。容量 = 下一 2 的幂 ≥ max(1024, IO周期×2)(IO ≤ 512 帧的设备恰为 1024,行为与固定 1024 时
        //   逐字节一致);配速水位 = min(容量, IO周期 + 1/4 周期 + 1024)(见 S2AIODepthFrames,AudioProcessor 拿它抬高
        //   自己的 30 ms 地板)。路由切换换了设备时重读 IO 周期、只增不减地换环(S2ARecover 恢复序列内,环账目已结清、
        //   回调已静止、pace 被 _suspended 挡住,三字段成组换)。测试钩子 S2A_AUDIO_TEST_DEVICE_FRAMES=<帧> 只改「读到的
        //   IO 周期」;派生是纯函数(services 侧单测)。iOS / tvOS 没有 HAL 设备属性,读不到按 0(= 不抬高,维持 1024)。
        private int _ringFrames;   // 2 的幂,≥ 1024,≥ 设备 IO 周期 × 2(ctor 按探测值定,S2ARecover 恢复序列内可只增不减地换)
        private byte[] _ring;
        private int _ringMask;   // 帧域掩码(_ringFrames-1),作用于帧下标;与 _ring/_ringFrames 成组换(见上)
        private int _deviceIOFrames;   // 设备实际 IO 周期帧数(ctor 探测;0 = 读不到/iOS。S2A_AUDIO_TEST_DEVICE_FRAMES 测试覆写)
        private long _ringRead, _ringWrite;   // 单调递增帧偏移(读写永不回绕出界);pace 写 _ringWrite、回调写 _ringRead
        private long _ringSampleWritten;      // 已写环的排队样本字节(pace 单写者;喂 PlaybackCredit.Take,对应 _pump.SubmittedSampleBytes)
        private long _virtualSampleWritten;   // 无设备播放已读出的排队样本字节(Interlocked;喂 PlaybackCredit.Take——信用判据「已提交才可算播完」的提交含虚拟读出,见 S2AVirtualSubmit)
        private int _ringUnderruns;            // 回调里环内可读不足一拍的次数(欠载拍在环外填零,§3.4)
        private byte[] _fill;                  // pace 填充中间缓冲(一次性分配,两段拷贝:ASQ 环绕段 + 环回绕下标;全程零运行期分配)
        private long _renderedFrames;          // 回调消费的环帧数(Interlocked;恒为排队样本帧——欠载零不进账目)
        private long _renderedAckFrames;       // 已喂 PlaybackCredit.Returned 的帧数(pace 单写者;恢复重置时看门狗在 _writeLock 内代写)
        private long _renderMaxTicks;          // 单次回调耗时的最大值(对齐 #1598「单次卡 ≥250 ms」的判定语义,非累计;看门狗 Exchange 取走清零)
        private long _callbackDepth;           // 在飞回调计数(Dispose/恢复的「Stop 后回调计数静止确认」兜底,§5.5)

        private readonly AppleHardwareDeviceDriver _driver;   // 平台例外：Apple 后端平台实现（拉取会话，#2157）
        // S2Arm: queued buffers as (identifier, sample count) in a ring under _queueLock(平移 AppleHardwareDeviceSession.cs:38-45)
        private (ulong DriverIdentifier, ulong SampleCount)[] _queued = new (ulong, ulong)[16];
        private int _queuedHead;
        private int _queuedCount;
        private ulong _headPlayed;
        private readonly object _queueLock = new();
        private AudioSampleQueue _samples;
        // S2Arm (11-02 Pokopia iPhone 断续 → 拉取档): 播放信用整类不改——地板从「设备交还」换成「设备已渲染」,
        //   pace 唤醒粒度 ≈ 一个设备拍,lead 自动学到 ≈ 一个拍(每拍一个 burst)
        private PlaybackCredit _credit;
        private readonly AutoResetEvent _paceEvent = new(false);
        private Thread _paceThread;   // 唯一环写者(复用现有 PaceLoop 线程形态,:66,294-295)
        /// <summary>S2Arm (11-19): the pace thread is still running after Dispose (stuck reading a hung game's buffer).
        /// The driver then keeps the shared update / pause events instead of disposing them.</summary>
        public bool S2APaceThreadAlive => _paceThread?.IsAlive == true;

        private nint _unit;
        private bool _unitRunning;
        private readonly AudioUnitInterop.AURenderCallback _renderDelegate;
        // Free must clear the actual field: calling it on a readonly GCHandle frees
        // a defensive copy, leaving a stale slot that another object can reuse.
        private GCHandle _gcHandle;
        private bool _disposed;
        private bool _closedStuck;   // S2Arm (11-14): Dispose left the unit allocated (TryEnter failed): pace returning later submits nothing
        private ulong _playedSampleCount;
        private bool _started;
        private bool _primeConfigured;   // 首个缓冲生产方定性(拉取档只给播完唤醒门用,§4.2;不再驱动门槛,§4.3)
        private bool _rendererProducer;
        private long _startTicks;
        private long _lastRenderTicks;
        private float _volume = 1f;
        private readonly object _lock = new();

        // S2Arm (D-J7ZC 巫师3 iOS 中断后中止 → 拉取档整体平移): 无设备播放。中断期间系统停了输出,设备不再渲染,
        //   游戏交出的声音一直不算播完——停掉真器件(在途的收回、照常记作播完),之后 pace 照常把声音读出但不进环,
        //   按采样率在墙钟上逐块「交还」(直接记播放信用,游戏看到的播放节奏与有设备时一样,只是没声)。
        //   「交还」位在拉取档 = 虚拟到期直接喂 _credit.Returned(替代 _returnedMask 的同一条路,:1096-1105 语义)
        private bool _virtual;
        private bool _virtualForInterrupt;   // S2Arm (11-23 交还永不停,移植自原 AudioQueue 会话): 这次无设备播放是不是因系统中断进的:是就等「中断结束」/ 每 10 秒试重新激活,不是就 VirtualProbeMs 后就试回设备
        private readonly object _virtualLock = new();
        private readonly int[] _virtualSlot = new int[NumBuffers];   // 这一块的帧数(拉取档没有设备槽号,直接记帧数)
        private readonly long[] _virtualDue = new long[NumBuffers];  // 这块按采样率播完的时刻(Stopwatch)
        private int _virtualHead, _virtualCount;
        private long _virtualEnd, _virtualFrames;   // 末块播完的时刻;本次无设备期间交还的帧数(只给日志)
        private long _virtualPausedAt;

        private readonly int _guestBytesPerFrame;
        private readonly int _deviceChannelCount;
        // S2Arm (#189): null when the 6-channel stream goes to the device as is (native, the default) or the session is not 6-channel.
        private readonly AppleOutputProcessor _processor;
        private readonly ConvertingReader _convertingReader;
        private byte[] _convertedData;

        private readonly int _bytesPerFrame;
        private readonly ManualResetEvent _updateRequiredEvent;
        private readonly S2AOutputDiag _diag;

        // S2Arm (10-23 声音停了自愈 → 判定面 §4.4): 停播(开播且环+排队非空,render 停 ≥ VirtualAfterMs)与回调卡死
        //   (单次 render ≥ EnqueueStuckMs)。iOS 队列时间轴跑前检测(QueueTimelineWatch)不适用:拉取模式没有
        //   「时刻已过的排队」概念(每拍现场拉),该误判类在拉取档结构性消失
        // S2Arm (11-23 D-GJCX / D-4T8M 宝可梦剑中止 → 交还永不停统一机制,逐项移植自 7d090b2cb 的原 AudioQueue 会话形状):
        //   游戏在跑、设备却不回调时(系统中断、路由切换、失焦而客机还没冻结……),不论原因超过 VirtualAfterMs 就改走
        //   无设备播放(按采样率照常交还),远早于游戏的 0.8–1 秒阈值;中断通知只是同一机制的更早触发(分派序见 S2AWatchdogLoop)。
        //   检测粒度:看门狗 250 ms × 阈值 200 ms → 停交还的最坏可见放回间隔 ≈ 450 ms(7d090b2cb 仓内测试断言口径 ≤600 ms)
        private const int VirtualAfterMs = 200;
        private const int VirtualProbeMs = 500;
        private const int HealBackoffMs = 2000;
        private const int EnqueueStuckMs = 250;
        private const int VerifyMaxMs = 30000;
        private const int ThawGraceMs = 1500;
        private const int CreditBurstGapMicroseconds = 2000;
        private const int CreditMaxLeadMilliseconds = 100;
        private long _lastHealTicks;
        private int _heals;
        private long _verifyTicks, _verifyPlayed0, _verifySeq;
        private int _verifyFails;
        private long _thawSeq = Interlocked.Read(ref Ryujinx.Audio.Integration.S2AGuestFreeze.Seq), _graceSeq = Interlocked.Read(ref Ryujinx.Audio.Integration.S2AGuestFreeze.Seq), _thawTicks;
        private static readonly bool _healOn = Environment.GetEnvironmentVariable("S2A_AUDIO_HEAL") != "0";

        // 测试钩子(缺省全关,服务层单测用;S2A_AUDIO_TEST_* 在拉取档照常生效,§6): 交设备卡死 → 回调内睡一次
        private static readonly (int AtS, int Ms) _testEnqStall = ParseProdStall(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_ENQ_STALL_AT"));
        private bool _testEnqStallDone;
        private static readonly int _testSlowAfterHeal = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_SLOW_AFTER_HEAL"), out int sh) ? sh : 0;
        private int _testSlowTick, _testSlowSaid;
        private static readonly int _testStallAtS = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_STALL_AT"), out int s) ? s : 0;
        private bool _testStallDone;
        // 测试钩子:S2A_AUDIO_TEST_DEVICE_FRAMES=<帧> —— 只改「读到的设备 IO 周期」(#2157 评审 #15 的「IO 4096 帧不欠载」
        //   用例用它在本机伪装大 IO 周期设备;真实设备不会被改,环/水位按伪装值自适应)
        private static readonly int _testDeviceFrames = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_DEVICE_FRAMES"), out int df) ? df : 0;
        private static readonly (int AtS, int Ms) _testProdStall = ParseProdStall(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_PRODUCER_STALL_AT"));
        private bool _testProdStallDone;
        private static readonly (int AtS, int Ms) _testNote = ParseNote(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_NOTE_AT"));
        private bool _testNoteEndDone;
        private static readonly int _testResetAtS = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_RESET_AT"), out int r) ? r : 0;
        private bool _testNoteDone, _testResetDone;
        // 模拟中断按整个进程只投一次（11-25 iOS 验收：两路输出会话各投一次，#1 在 #0 恢复途中又投了 began，第二段读数被搅混）：先到点的会话认领
        private static int s_testNoteClaimed;
        // 测试钩子:S2A_AUDIO_TEST_ROUTE_AT=<秒> —— 开播后到点经 S2AAudioNotes.PostForTest 走真实 NSNotificationCenter
        //   投递一条路由切换通知(声明/解析风格对齐 S2A_AUDIO_TEST_NOTE_AT;路由通知只记不动作,真停摆由 200 ms 兜底接住)
        private static readonly int _testRouteAtS = int.TryParse(Environment.GetEnvironmentVariable("S2A_AUDIO_TEST_ROUTE_AT"), out int rt) ? rt : 0;
        private bool _testRouteDone;

        private static int ParsePullPrime(string v)
        {
            return int.TryParse(v, out int ms) && ms >= 0 ? ms : 0;   // 非法/未设按缺省 0(对齐 S2A_AUDIO_RENDERER_PRIME_MS 的 ParsePrime 先例)
        }

        private static (int, int) ParseProdStall(string v)
        {
            if (string.IsNullOrEmpty(v)) return (0, 0);
            string[] p = v.Split(':');
            return p.Length == 2 && int.TryParse(p[0], out int a) && int.TryParse(p[1], out int m) ? (a, m) : (0, 0);
        }

        private static (int, int) ParseNote(string v)
        {
            if (int.TryParse(v, out int at))
            {
                return (at, 0);
            }

            return ParseProdStall(v);
        }

        [DllImport("s2a_native")]
        private static extern int s2a_dump_threads(string why);

        [DllImport("s2a_native")]
        private static extern int s2a_audio_volume();   // runtime/src/game_volume.c：游戏音量 0–100（#1186）

        // S2Arm (#2157 p99 保真): pace 线程承载放回链的第一跳(回调记账 → 信用 → 播完唤醒)。.NET 的 ThreadPriority 在
        //   macOS 只落 nice 值,唤醒时序不认它——并发负载下 pace 迟醒 ~9 ms(实测放回间隔 p99 由 21.4 抬到 30 ms 一带)。
        //   按苹果系统的 QoS 机制把本线程提到 user-interactive(0x21),唤醒调度与实际用户可感路径一致;失败(非苹果 /
        //   旧系统)按原样继续
        [DllImport("libpthread.dylib")]
        private static extern int pthread_set_qos_class_self_np(uint qos_class, int relative_priority);

        private static void S2AApplyPaceQos()
        {
            if (OperatingSystem.IsMacOS())   // 平台例外：Apple 后端平台实现（拉取会话，#2157）
            {
                try { pthread_set_qos_class_self_np(0x21, 0); } catch { /* 少见:按原样 */ }
            }
        }

        private static bool s_gameVolumeGone;   // 原生层没有这个导出（旧宿主 / 只链托管的单测）：按 100，不再试

        private static int S2AGameVolume()
        {
            if (s_gameVolumeGone)
                return 100;
            try { return s2a_audio_volume(); }
            catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException) { s_gameVolumeGone = true; return 100; }
        }

        public ApplePullHardwareDeviceSession(
            AppleHardwareDeviceDriver driver,   // 平台例外：Apple 后端平台实现（拉取会话，#2157）
            IVirtualMemoryManager memoryManager,
            SampleFormat requestedSampleFormat,
            uint requestedSampleRate,
            uint requestedChannelCount)
            : base(memoryManager, requestedSampleFormat, requestedSampleRate, requestedChannelCount)
        {
            _driver = driver;
            _updateRequiredEvent = driver.GetUpdateRequiredEvent();
            _renderDelegate = RenderCallback;
            _guestBytesPerFrame = BackendHelper.GetSampleSize(requestedSampleFormat) * (int)requestedChannelCount;
            _deviceChannelCount = (int)requestedChannelCount;

            // S2Arm (#189 → 拉取档 §5.2): 构造侧选档逻辑逐行平移(AppleHardwareDeviceSession.cs:240-284)——
            //   S2A_AUDIO_OUT=sys/matrix、S2A_AUDIO_DEVICE + VS 开关的优先级与红字退级、仅 PCM16 可折的约束,全部不变;
            //   AppleOutputProcessor 输出恒为 2ch PCM16,与拉取环完全兼容。帧数不变,环、账目、放回节奏全部沿用
            //   #610「泵、播放信用、缓冲释放节奏不变」的口径(本类把「泵」换成「环」,其余同)
            if (requestedChannelCount == 6)
            {
                string configuredMode = Environment.GetEnvironmentVariable("S2A_AUDIO_OUT");
                AppleOutputMode mode = AppleOutputModeSelector.FromEnvironment();
                AppleAudioDeviceType deviceType = AppleAudioDeviceTypeSelector.FromEnvironment();
                AppleOutputMode? spatialMode = deviceType switch
                {
                    AppleAudioDeviceType.BuiltInSpeakers when AppleAudioDeviceTypeSelector.VirtualSurround(deviceType) => AppleOutputMode.SpatialSpeakers,
                    AppleAudioDeviceType.Headphones when AppleAudioDeviceTypeSelector.VirtualSurround(deviceType) => AppleOutputMode.SpatialHeadphones,
                    _ => null,
                };

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
                else if (spatialMode != null)
                {
                    if (requestedSampleFormat != SampleFormat.PcmInt16)
                    {
                        Console.Error.WriteLine($"[声] 【红】设备类型 {AppleAudioDeviceTypeSelector.DeviceName(deviceType)} + VS 开只支持 PCM16 的 5.1（本次 {requestedSampleFormat}）：按 native 直交 AudioQueue");
                    }
                    else
                    {
                        _deviceChannelCount = 2;
                        _processor = AppleOutputProcessor.Create(spatialMode.Value, (int)requestedSampleRate, MaxFrames);
                        Console.Error.WriteLine($"[声] 5.1→2.0 虚拟环绕档「{AppleOutputModeSelector.ModeName(_processor.EffectiveMode)}」（设备类型 {AppleAudioDeviceTypeSelector.DeviceName(deviceType)}、VS 开、{requestedSampleFormat}）：6 声道 FL FR FC LFE BL BR → AUSM → 2 声道（一片最多 {MaxFrames} 帧）" +
                            (_processor.InitError != null ? $"；【红】器件没建起来，这一路按矩阵下混：{_processor.InitError}" : ""));
                    }
                }
                else if (!string.IsNullOrWhiteSpace(configuredMode))
                {
                    Console.Error.WriteLine("[声] 5.1→2.0 档「native」：显式保持现状（渲染器自己下混）");
                }
            }

            // S2Arm (#2157 只留一种传输 §4.1/§4.2): 无拒收分支——native 6ch(无折叠、真 5.1 设备)直通进拉取:
            //   器件 StreamFormat 按设备声道(6ch),CreateUnit 里声明 5.1 布局逐行对齐 AudioQueue 既有语义
            //   (不声明时系统隐式 6→2 只复制 FL/FR,中置对白与环绕整段丢失);iOS/tvOS 直接走 RemoteIO
            //   (RemoteIO 输出总线缺省即开,不需要 EnableIO;收音不走本单元——收音是独立 AudioQueue 会话)

            _bytesPerFrame = BackendHelper.GetSampleSize(requestedSampleFormat) * _deviceChannelCount;
            _deviceIOFrames = S2AProbeDeviceIOFrames();
            _ringFrames = S2ADeriveRingFrames(_deviceIOFrames);
            _ring = new byte[(long)_ringFrames * _bytesPerFrame];
            _ringMask = _ringFrames - 1;   // 帧域掩码:_ringFrames 固定 2 的幂,任意声道数(12 B/帧 6ch)下掩码安全
            _fill = new byte[Math.Min(_ring.Length, 4096)];   // 一次性分配的中间缓冲(§3.2,约 4 KB;不足整帧的字节不进环)
            _diag = S2AOutputDiag.Create(_bytesPerFrame, _deviceChannelCount, (int)requestedSampleRate, BackendHelper.GetSampleSize(requestedSampleFormat) * 8);
            Console.Error.WriteLine(_deviceIOFrames > 0
                ? $"[声] 输出 #{_diag.Index}：设备 IO 周期 {_deviceIOFrames} 帧 ≈ {_deviceIOFrames * 1000.0 / requestedSampleRate:F1} ms → 拉取环 {_ringFrames} 帧 ≈ {_ringFrames * 1000.0 / requestedSampleRate:F1} ms、配速水位 {S2ADeriveDepthFrames(_deviceIOFrames, _ringFrames)} 帧（S2Arm #2157 评审 #15）"
                : $"[声] 输出 #{_diag.Index}：设备 IO 周期读不到（iOS / tvOS 无 HAL 属性 / 读取失败）→ 拉取环按缺省 {_ringFrames} 帧");
            _convertingReader = _processor != null ? new ConvertingReader(this, _processor) : null;

            _gcHandle = GCHandle.Alloc(this, GCHandleType.Normal);
            try
            {
                SetupAudioUnit();
            }
            catch
            {
                // 建不起来:收掉半建的资源,句柄不留尾巴(驱动侧红字一行退 AudioQueue)
                if (_unit != nint.Zero)
                {
                    AudioUnitInterop.AudioOutputUnitStop(_unit);
                    AudioUnitInterop.AudioComponentInstanceDispose(_unit);
                    _unit = nint.Zero;
                }
                _diag.Dispose();
                _gcHandle.Free();
                throw;
            }

            S2AWatch(this, true);
            _paceThread = new Thread(PaceLoop) { IsBackground = true, Name = "S2A.AudioPace", Priority = ThreadPriority.Highest };
            _paceThread.Start();
        }

        // S2Arm: 登记 / 注销看门狗(固定 8 槽,看门狗线程扫数组不分配)——单一输出会话后静态结构住在本类
        //   (形状对齐原 AudioQueue 会话;8 槽上限的既有风险原样保留,与 v1 §2 口径一致)
        private static readonly ApplePullHardwareDeviceSession[] _watched = new ApplePullHardwareDeviceSession[8];
        private static int _watchdogStarted;

        private static void S2AWatch(ApplePullHardwareDeviceSession s, bool add)
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
                // 每 250 ms 一轮；客机解冻（回前台 / 失焦放开）时立刻醒来，当场重启输出器件（S2ACheckStall 的 #1384 分支），不等下一轮
                Ryujinx.Audio.Integration.S2AGuestFreeze.Thawed.WaitOne(250);

                long now = Stopwatch.GetTimestamp();
                int notes = S2AAudioNotes.TakePending();

                // Removing a session during Dispose waits for a watchdog pass that already
                // selected it, so it cannot recover or touch a disposed unit.
                lock (_watched)
                for (int i = 0; i < _watched.Length; i++)
                {
                    ApplePullHardwareDeviceSession s = Volatile.Read(ref _watched[i]);

                    if (s == null)
                    {
                        continue;
                    }

                    s.S2ATestHooks(now);

                    if (_primeMs > 0)
                    {
                        s.S2APrimeFallback();   // 仅 prime>0 时启用(S2A_AUDIO_PULL_PRIME_MS 语义,§4.3)
                    }

                    // 主路径:系统通知。中断结束 → 重新激活 + 重启;媒体服务重置 → 重建器件;路由切换(Route)换了输出
                    //   设备、IO 周期可能变大——环不够就走恢复序列换环(#2157 评审 #15,S2ARecover 内重读 IO 周期并
                    //   只增不减地换;环够就只更新读数,水位随 S2AIODepthFrames 自动跟随);其余路由停摆与平时一样
                    //   由下面的 200 ms 兜底接住(§4.4)
                    if ((notes & (S2AAudioNotes.Ended | S2AAudioNotes.Reset)) != 0)
                    {
                        s.S2ARecover((notes & S2AAudioNotes.Reset) != 0 ? "系统通知：媒体服务重置" : "系统通知：中断结束", (notes & S2AAudioNotes.Reset) != 0, now, false);
                    }
                    else if ((notes & S2AAudioNotes.Began) != 0)
                    {
                        s.S2AEnterVirtual("系统通知：中断开始");
                    }
                    else if ((notes & S2AAudioNotes.Route) != 0)
                    {
                        int routeIO = S2AProbeDeviceIOFrames();

                        if (routeIO > 0 && S2ADeriveRingFrames(routeIO) > Volatile.Read(ref s._ringFrames))
                        {
                            s.S2ARecover($"路由切换后设备 IO 周期 {routeIO} 帧(环 {s._ringFrames} 帧不够)", false, now, false);
                        }
                    }
                    else if (Volatile.Read(ref s._virtual))
                    {
                        s.S2AVirtualProbe(now);
                    }
                    else
                    {
                        s.S2ACheckStall(now);
                    }
                }
            }
        }

        // S2Arm (#189): a downmix slice holds at most 50 ms worth of frames(平移 MaxFrames 的口径,处理器内部分片用)
        private int MaxFrames => (int)(RequestedSampleRate / 20);

        // S2Arm (#189): frame count of a queued buffer in device bytes(平移 AppleHardwareDeviceSession.cs:807)
        private ulong GetFrameCount(AudioBuffer buffer) => buffer.DataSize / (ulong)_bytesPerFrame;

        private long RingBytes => (Volatile.Read(ref _ringWrite) - Volatile.Read(ref _ringRead)) * _bytesPerFrame;   // 帧偏移差 × 每帧字节

        // 测试钩子(缺省全关): S2A_AUDIO_TEST_STALL_AT 外部停器件(模拟系统悄悄停播,拉取档 = AudioOutputUnitStop);
        //   S2A_AUDIO_TEST_NOTE_AT 模拟一次中断;S2A_AUDIO_TEST_RESET_AT 投递一次媒体服务重置(平移 :366-416)
        private void S2ATestHooks(long now)
        {
            long since = now - _startTicks;

            // 持续一段的模拟中断:到点投递 ended(无设备播放时真器件没开着,放在下面的门前)
            if (_testNote.Ms > 0 && _testNoteDone && !_testNoteEndDone && since >= (long)_testNote.AtS * Stopwatch.Frequency + (long)_testNote.Ms * Stopwatch.Frequency / 1000)
            {
                _testNoteEndDone = true;
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 模拟中断 {_testNote.Ms} ms 到点，投递 ended");
                S2AAudioNotes.PostForTest("AVAudioSessionInterruptionNotification", 0);
            }

            if (!_started || !Volatile.Read(ref _unitRunning))
            {
                return;
            }

            if (_testStallAtS > 0 && !_testStallDone && since >= (long)_testStallAtS * Stopwatch.Frequency)
            {
                _testStallDone = true;
                int rc = AudioUnitInterop.AudioOutputUnitStop(_unit);
                // 日志措辞与原 AudioQueue 会话逐字节相同(仓内测试 grep 这行字,AppleAudioStallVirtualTest):
                //   拉取档的「暂停输出队列」等价物是停输出器件
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testStallAtS} 秒外部暂停输出队列（不发任何通知，模拟系统悄悄停播），rc={rc}");
            }

            if (_testNote.AtS > 0 && !_testNoteDone && since >= (long)_testNote.AtS * Stopwatch.Frequency)
            {
                _testNoteDone = true;
                if (Interlocked.Exchange(ref s_testNoteClaimed, 1) != 0)
                {
                    _testNoteEndDone = true;   // 别的会话已经投过：这一路不再投 began / ended
                    return;
                }
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testNote.AtS} 秒模拟中断（投递 began → 停器件 → {(_testNote.Ms > 0 ? $"{_testNote.Ms} ms 后" : "")}投递 ended）");
                S2AAudioNotes.PostForTest("AVAudioSessionInterruptionNotification", 1);
                AudioUnitInterop.AudioOutputUnitStop(_unit);

                if (_testNote.Ms == 0)
                {
                    S2AAudioNotes.PostForTest("AVAudioSessionInterruptionNotification", 0);
                }
            }

            if (_testSlowAfterHeal > 0 && _heals == _testSlowAfterHeal && Interlocked.Exchange(ref _testSlowSaid, 1) == 0)
            {
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 第 {_testSlowAfterHeal} 次重启后每拍只记四分之一成「播完」（器件有回调、交还照常，只算播了约四分之一）");
            }

            if (_testResetAtS > 0 && !_testResetDone && since >= (long)_testResetAtS * Stopwatch.Frequency)
            {
                _testResetDone = true;
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testResetAtS} 秒模拟媒体服务重置");
                S2AAudioNotes.PostForTest("AVAudioSessionMediaServicesWereResetNotification", -1);
            }

            if (_testRouteAtS > 0 && !_testRouteDone && since >= (long)_testRouteAtS * Stopwatch.Frequency)
            {
                _testRouteDone = true;
                Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testRouteAtS} 秒投递一条路由切换通知（真实 NSNotificationCenter 投递,只记不动作）");
                S2AAudioNotes.PostForTest("AVAudioSessionRouteChangeNotification", 0);
            }
        }

        // S2Arm (#164 → 拉取档 §4.3): prime 兜底检查只在拉取档启用了起播门槛(S2A_AUDIO_PULL_PRIME_MS>0)时存在
        private void S2APrimeFallback()
        {
            if (!Volatile.Read(ref _started) || Volatile.Read(ref _unitRunning))
            {
                return;
            }

            MaybeStartUnit();   // check-then-act 整段持 _lock(见 MaybeStartUnit),此处不再重复加锁
        }

        // 无设备播放中(见 _virtual):每 10 秒试一次重新激活音频会话(「中断结束」通知会漏)。中断还在时激活失败、不动
        private void S2AVirtualProbe(long now)
        {
            // 不是因系统中断进的(路由切换、失焦未冻结、设备悄悄停播……):设备多半马上能用,VirtualProbeMs 后就试回设备;
            //   回不去(重新开播失败 / 随后又不回调)再进无设备播放,游戏这期间一直收到交还(移植自 7d090b2cb 的原 AudioQueue 会话)
            if (!_virtualForInterrupt)
            {
                if (now - _lastHealTicks >= (long)VirtualProbeMs * Stopwatch.Frequency / 1000)
                {
                    S2ARecover($"无设备播放 {(now - _lastHealTicks) * 1000 / Stopwatch.Frequency} ms 后试回设备（不在系统中断里，最近系统通知 {S2AAudioNotes.Last}）", false, now, false);
                }

                return;
            }

            if (now - _lastHealTicks < (long)HealBackoffMs * 5 * Stopwatch.Frequency / 1000)
            {
                return;
            }

            _lastHealTicks = now;

            if ((OperatingSystem.IsIOS() || OperatingSystem.IsTvOS()) && _driver.S2AReactivateSession())   // 平台例外：tvOS 与 iOS 走同一分支;Mac 没有音频会话、不会因中断进来
            {
                S2ARecover("无设备播放中重新激活音频会话成功", false, now, false);
            }
        }

        // 解冻宽限的判定(纯函数,服务层单测 --apple-audio-thaw-grace 直接测):frozen / seq = 客机冻结状态与冻结次数;graceSeq / thawTicks = 上次见到的冻结次数、
        //   上次解冻时刻(调用方保存)。返回这一拍在不在宽限内(冻结中或解冻后 ThawGraceMs 内);rebase = 停播起算点要刷新到 now(冻结中、或刚看到一次新的解冻)
        internal static bool S2AThawGraceStep(bool frozen, long seq, ref long graceSeq, ref long thawTicks, long now, long freq, out bool rebase)
        {
            rebase = frozen || seq != graceSeq;
            if (!frozen && seq != graceSeq)
            {
                graceSeq = seq;
                thawTicks = now;
            }

            return frozen || (thawTicks != 0 && now - thawTicks < (long)ThawGraceMs * freq / 1000);
        }

        // S2Arm (拉取档 §4.4): 停播 / 回调卡死的兜底判定(单写者指针之外的全部读数都在看门狗线程上)
        private void S2ACheckStall(long now)
        {
            long renderMax = Interlocked.Exchange(ref _renderMaxTicks, 0);

            if (!_started || !Volatile.Read(ref _unitRunning))
            {
                _verifyTicks = 0;   // 游戏停播 / 没开播:这次重启不下结论

                return;
            }

            bool grace = false;
            if (!OperatingSystem.IsMacOS())   // 平台例外：苹果后端内部，Mac 解冻走 #1384 的重启(见下)
            {
                grace = S2AThawGraceStep(Ryujinx.Audio.Integration.S2AGuestFreeze.Frozen != 0, Interlocked.Read(ref Ryujinx.Audio.Integration.S2AGuestFreeze.Seq),
                                      ref _graceSeq, ref _thawTicks, now, Stopwatch.Frequency, out bool rebase);
                if (rebase)
                {
                    Volatile.Write(ref _lastRenderTicks, now);   // 冻结 / 挂起的时间不算「设备没有回调」
                }
            }

            // #1598 → 拉取档: 单次 render 回调卡 ≥ 250 ms = 输出器件卡死,与停播路径同一个动作(停 → 收回 → 重建开播)。
            //   各平台都接,退避同下;解冻宽限内一次慢按过渡处理、不重启(对齐 :491-504)
            if (!grace && renderMax * 1000 >= (long)EnqueueStuckMs * Stopwatch.Frequency && _healOn && now - _lastHealTicks >= (long)HealBackoffMs * Stopwatch.Frequency / 1000)
            {
                S2ARecover($"兜底：单次拉取回调卡了 {renderMax * 1000 / Stopwatch.Frequency} ms，输出器件卡死", false, now, true);

                return;
            }

            // S2Arm (#1384): 客机冻结(失焦暂停 / 进后台)放开后当场重启一次输出器件。原先只 macOS 重启(11-13 的前提「macOS 队列自己恢复」在部分外接输出上不成立)、
            //   iOS / tvOS 靠宽限等器件自己回来：11-25 iOS 验收回前台到首个回调 520 ms(判据 ≤200 ms),与 11-24 查的「iOS 解冻不当场重启」同一件事。
            //   各平台一样当场重启(iOS / tvOS 的 S2ARecover 同时重新激活音频会话);宽限照旧挡住解冻后头几拍的慢回调误判卡死
            long freezeSeq = Interlocked.Read(ref Ryujinx.Audio.Integration.S2AGuestFreeze.Seq);
            if (freezeSeq != _thawSeq && Ryujinx.Audio.Integration.S2AGuestFreeze.Frozen == 0)
            {
                _thawSeq = freezeSeq;
                S2ARecover($"客机解冻（失焦暂停 / 进后台放开，第 {freezeSeq} 次）：重启输出器件", false, now, false);

                return;
            }

            if (S2AVerifyRecover(now, freezeSeq))
            {
                return;
            }

            long stall = now - Volatile.Read(ref _lastRenderTicks);
            long buffered = RingBytes + _samples.Length;

            // 停播:开播且环+排队非空,render 回调停 ≥ VirtualAfterMs(拉取档没有 iOS 时间轴跑前检测,§4.4)。
            //   「在途数据」在拉取档 = 环内 + ASQ 排队(原 AudioQueue 会话的泵在途,一一对位)
            if (stall < (long)VirtualAfterMs * Stopwatch.Frequency / 1000 || buffered == 0)
            {
                return;
            }

            if (!_healOn)
            {
                if (_heals++ == 0)
                {
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：器件 {stall * 1000 / Stopwatch.Frequency} ms 没有回调（在途 {buffered / _bytesPerFrame} 帧），自愈已关（S2A_AUDIO_HEAL=0）");
                }

                return;
            }

            if (s_stallDumpOn && Interlocked.Increment(ref s_stallDumps) <= 3)
            {
                try
                {
                    s2a_dump_threads($"声音器件 {stall * 1000 / Stopwatch.Frequency} ms 没有回调");
                }
                catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
                {
                    Console.Error.WriteLine($"[声] 全线程现场不可用（{e.GetType().Name}）");
                }
            }

            // 交还永不停(见 VirtualAfterMs,移植自 7d090b2cb 的原 AudioQueue 会话):不论系统中断、路由切换还是别的原因,
            //   先改走无设备播放让游戏照常收到交还,回设备交给 S2AVirtualProbe(中断进入者等「中断结束」/ 每 10 秒重激活,
            //   非中断进入者 VirtualProbeMs 后就试回设备)——原先「中断分支 / 退避 / 直接重启」的三段尾巴删除,机制归一
            S2AEnterVirtual($"兜底：器件 {stall * 1000 / Stopwatch.Frequency} ms 没有回调{(S2AAudioNotes.Interrupted ? "（系统中断中）" : "")}，最近系统通知 {S2AAudioNotes.Last}");
        }

        private static readonly bool s_stallDumpOn = Environment.GetEnvironmentVariable("S2A_AUDIO_STALL_DUMP") == "1";
        private static int s_stallDumps;

        // #1632 / #1598 → 拉取档: 重启后按退避窗口核一次(平移 :627-664);「设备交还帧数」读数改为已渲染帧数(经 _diag 走的账)
        private bool S2AVerifyRecover(long now, long freezeSeq)
        {
            int windowMs = (int)Math.Min((long)HealBackoffMs << Math.Min(_verifyFails, 8), VerifyMaxMs);
            if (_verifyTicks == 0 || now - _verifyTicks < (long)windowMs * Stopwatch.Frequency / 1000)
            {
                return false;
            }

            long elapsed = now - _verifyTicks;
            long played = _diag.FramesPlayed - _verifyPlayed0, want = elapsed * RequestedSampleRate / Stopwatch.Frequency;
            _verifyTicks = 0;

            if (freezeSeq != _verifySeq || Ryujinx.Audio.Integration.S2AGuestFreeze.Frozen != 0)
            {
                return false;   // 期间失焦冻结过:交还少是因为游戏停了,不下结论
            }

            long ms = elapsed * 1000 / Stopwatch.Frequency;
            if (played * 2 >= want)
            {
                Console.Error.WriteLine($"[声] 输出 #{_diag.Index}：重启后设备恢复播放（{ms} ms 交还 {played} 帧，应约 {want} 帧）{(_verifyFails > 0 ? $"，此前连续 {_verifyFails} 次没恢复" : "")}");
                _verifyFails = 0;

                return false;
            }

            if (RingBytes + _samples.Length == 0)
            {
                return false;   // 设备手上没声音可播:交还少是游戏没送,不是设备没播
            }

            _verifyFails++;
            S2ARecover($"重启后设备没恢复播放：{ms} ms 交还 {played} 帧（应约 {want} 帧，不到一半），再重启（连续第 {_verifyFails} 次没恢复，" +
                       $"下次 {Math.Min((long)HealBackoffMs << Math.Min(_verifyFails, 8), VerifyMaxMs) / 1000} 秒后再核）", false, now, true);

            return true;
        }

        // 恢复输出流(§5.1 静默序列包裹): TryEnter 拿到 _writeLock → 置 _suspended → 停器件 → 锁内代写指针、重置环账目
        //   (环内样本丢弃记作播完) → 重建(媒体服务重置) → 清 _suspended;拿不到(pace 卡在读客机内存)走泄漏路径。
        //   「停 / 重建期间不交缓冲」(审计 P1-27)由 _suspended 挡住 pace 达成
        private void S2ARecover(string why, bool rebuild, long now, bool red)
        {
            if (!_healOn)
            {
                Console.Error.WriteLine($"[声] {why}；自愈已关（S2A_AUDIO_HEAL=0），不处理");

                return;
            }

            lock (_lock)
            {
                if (_unit == nint.Zero)
                {
                    return;
                }

                _lastHealTicks = now;
                long inFlightFrames = (RingBytes + _samples.Length) / _bytesPerFrame;
                bool active = _driver.S2AReactivateSession();
                int stopRc = 0, newRc = 0, reclaimed = 0;
                bool wasVirtual = Volatile.Read(ref _virtual);
                long virtualFrames = _virtualFrames;
                bool stopped = false;

                if (Monitor.TryEnter(_writeLock, TimeSpan.FromMilliseconds(200)))
                {
                    try
                    {
                        Volatile.Write(ref _suspended, true);
                        // 退出无设备播放(见 _virtual):真器件进入时已停空,此后没交过,无设备在途的记录随环账目一并清
                        if (wasVirtual)
                        {
                            reclaimed += S2AVirtualReclaimPendingLocked();   // 已读进虚拟槽、还没到点的帧记作播完(见该方法)
                            S2AVirtualClearLocked();
                            Volatile.Write(ref _virtual, false);
                        }

                        stopRc = AudioUnitInterop.AudioOutputUnitStop(_unit);
                        S2AWaitCallbacksQuiet();
                        stopped = stopRc == 0;

                        if (stopped)
                        {
                            reclaimed += S2AResetRingLocked(now);   // += :环内收回并进虚拟槽收回(上面 wasVirtual 分支),日志与 S2ACredit 一次结清

                            // S2Arm (#2157 评审 #15): 恢复序列里重读设备 IO 周期,环要不够就只增不减地换(S2ARingAdaptToIO,安全
                            //   前提见该方法);路由切换(换了输出设备)后 IO 周期变大的入口见 S2AWatchdogLoop 的 Route 分派。
                            //   CreateUnit 的 MaximumFramesPerSlice 与 ASQ 容量都按新 _ringFrames 取
                            S2ARingAdaptToIO(S2AProbeDeviceIOFrames());

                            if (rebuild)
                            {
                                AudioUnitInterop.AudioComponentInstanceDispose(_unit);
                                _unit = nint.Zero;
                                newRc = CreateUnit();   // 媒体服务重置:器件重建,设备缓冲请求随重建重发(对齐 #1066)
                            }
                        }
                    }
                    finally
                    {
                        Volatile.Write(ref _suspended, false);
                        Monitor.Exit(_writeLock);
                    }
                }
                else
                {
                    // pace 卡在读客机内存(泄漏路径,对齐 _closedStuck):停器件、红字、不重置环不释放下混器件
                    stopRc = AudioUnitInterop.AudioOutputUnitStop(_unit);
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：{why}——恢复时送数线程卡在读游戏内存（等了 200 ms），器件已停、环不重置（防写穿）");
                }

                _unitRunning = false;

                if (stopped && reclaimed > 0)
                {
                    S2ACredit();   // 收回的真实样本没播但当作已播完:让游戏的缓冲照常放回去(平移 :739-744 语义)
                }

                int startRc = -1;

                // 游戏自己停着播(Stop)就只恢复好器件,等它 Start;环此刻可能空——pace 醒来即补,欠载拍填零(§4.3)
                if (_started && stopped && _unit != nint.Zero && newRc == 0)
                {
                    _paceEvent.Set();
                    startRc = AudioUnitInterop.AudioOutputUnitStart(_unit);
                    _unitRunning = startRc == 0;
                }

                // 重启后核对(S2AVerifyRecover):开播成功才核,从此刻起算
                _verifyTicks = startRc == 0 ? Stopwatch.GetTimestamp() : 0;
                _verifyPlayed0 = _diag.FramesPlayed;
                _verifySeq = Interlocked.Read(ref Ryujinx.Audio.Integration.S2AGuestFreeze.Seq);
                Volatile.Write(ref _lastRenderTicks, Stopwatch.GetTimestamp());

                Console.Error.WriteLine($"[声] {(red ? "【红】" : "")}输出 #{_diag.Index}：{why}（在途 {inFlightFrames} 帧{(wasVirtual ? $"；结束无设备播放，期间按采样率交还 {virtualFrames} 帧" : "")}）→ {(rebuild ? "重建" : "重启")}输出器件（第 {++_heals} 次）：" +
                    $"{((OperatingSystem.IsIOS() || OperatingSystem.IsTvOS()) ? $"重新激活音频会话 {(active ? "成功" : "失败")}、" : "")}停器件 rc={stopRc}、收回 {reclaimed / _bytesPerFrame} 帧" +   // 平台例外：Apple 后端平台实现（拉取会话，#2157）
                    $"{(rebuild ? $"、重建器件 rc={newRc}" : "")}、重新开播 rc={startRc}{(startRc == 0 ? "" : "（没开播：游戏停着或开播失败，下一笔声音到时再试）")}");

                // 开播失败(系统中断还在、路由还没切好……):不论原因回到无设备播放,别让游戏等交还(见 VirtualAfterMs;
                //   移植自 7d090b2cb 的原 AudioQueue 会话——「且系统中断中」的限定已删,重启失败任何原因都回无设备播放)
                if (_started && startRc != 0)
                {
                    S2AEnterVirtual($"重新开播失败（rc={startRc}{(S2AAudioNotes.Interrupted ? "，系统中断中" : "")}）");
                }
            }
        }

        // _writeLock 内、器件已停、回调计数已静止:已渲染未记账部分照记交还(它们真播过了);环内未渲染样本丢弃、
        //   记作播完(Reclaimed,丢不到环容量 21 ms);读写指针归零(静默方代写,pace 回来后看到 _suspended 丢弃本轮)
        private int S2AResetRingLocked(long now)
        {
            long rendered = Interlocked.Read(ref _renderedFrames);
            long unackedBytes = (rendered - _renderedAckFrames) * _bytesPerFrame;
            long ringBytes = RingBytes;

            _renderedAckFrames = rendered;
            Volatile.Write(ref _ringRead, 0);
            Volatile.Write(ref _ringWrite, 0);

            if (unackedBytes > 0)
            {
                _credit.Returned((int)unackedBytes, now);
            }

            if (ringBytes > 0)
            {
                _credit.Reclaimed((int)ringBytes);
            }

            return (int)ringBytes;
        }

        // Stop 后回调计数静止确认(§5.5 实现顺序的兜底):AudioOutputUnitStop 返回后不再有新的回调调用这一同步语义
        //   是类比 AudioQueueDispose 的未验证推断,以计数 + 有界等待兜底;非实时路径
        private void S2AWaitCallbacksQuiet()
        {
            long deadline = Stopwatch.GetTimestamp() + Stopwatch.Frequency / 5;   // 有界 200 ms

            while (Interlocked.Read(ref _callbackDepth) > 0 && Stopwatch.GetTimestamp() < deadline)
            {
                Thread.Sleep(1);
            }
        }

        // 建立序列(§3.1,会话构造线程):找器件 → 建实例 → 设备 IO 缓冲请求('bsiz' 在初始化前发出)→ input scope
        //   element 0 设 StreamFormat(设备字节格式,折后 2ch)→ 设 render callback → MaximumFramesPerSlice=环容量帧数
        //   → AudioUnitInitialize。任一步 rc≠0 → 红字一行 + 抛 InvalidOperationException(驱动捕获后退 AudioQueue)
        private unsafe void SetupAudioUnit()
        {
            int result = CreateUnit();

            if (result != 0)
            {
                throw new InvalidOperationException($"AudioUnit pull setup failed: {result}");
            }

            // S2Arm (§4.2 ASQ 容量耦合修复): AudioSampleQueue 容量取 max(环字节, 4 × RingFrames × bytesPerFrame)——
            //   audout 深度上限 4 块、块长 = 测试夹具口径;原先「ASQ 容量 = 环字节」(≈21.3 ms)把多块 flush 的
            //   Release 拷入与渲染器深度截断成静音(AudioSampleQueue 超容量按静音播),max 后消除截断
            _samples = new AudioSampleQueue(Math.Max(_ring.Length, 4 * _ringFrames * _bytesPerFrame));
            _credit = new PlaybackCredit(_bytesPerFrame, (long)_bytesPerFrame * RequestedSampleRate,
                                         (long)_bytesPerFrame * RequestedSampleRate * CreditMaxLeadMilliseconds / 1000,
                                         Stopwatch.Frequency * CreditBurstGapMicroseconds / 1_000_000);
        }

        // 建输出器件(起会话与媒体服务重置后重建共用)。iOS/tvOS 走 RemoteIO(输出总线缺省即开),macOS 走 DefaultOutput
        private unsafe int CreateUnit()
        {
            AudioUnitInterop.AudioComponentDescription description = new()
            {
                ComponentType = AudioUnitInterop.kAudioUnitType_Output,
                ComponentSubType = (OperatingSystem.IsIOS() || OperatingSystem.IsTvOS())   // 平台例外：tvOS 与 iOS 走同一分支
                    ? AudioUnitInterop.kAudioUnitSubType_RemoteIO
                    : AudioUnitInterop.kAudioUnitSubType_DefaultOutput,   // macOS:跟随用户默认输出设备(与 AudioQueue 的缺省绑定语义一致)
                ComponentManufacturer = AudioUnitInterop.kAudioUnitManufacturer_Apple,
                ComponentFlags = 0,
                ComponentFlagsMask = 0,
            };

            nint component = AudioUnitInterop.AudioComponentFindNext(nint.Zero, ref description);

            if (component == nint.Zero)
            {
                Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：找不到输出器件（DefaultOutput AudioUnit）");
                return -1;
            }

            int result = AudioUnitInterop.AudioComponentInstanceNew(component, out _unit);

            if (result != 0)
            {
                _unit = nint.Zero;
                return result;
            }

            // 设备 IO 缓冲请求(平移 AppleHardwareDeviceSession.cs:880-930):'bsiz' 在 AU 初始化前发出,设备拍先到位;
            //   失败按设备默认继续(同现有容错)
            S2AApplyDeviceBufferFrames();
            S2ALogOutputDevice();

            // input scope element 0 的流格式 = 设备字节格式(折后 2ch,同 CreateQueue 的 :812-814 口径)
            AudioStreamBasicDescription format = AppleHardwareDeviceDriver.GetAudioFormat(RequestedSampleFormat, RequestedSampleRate, (uint)_deviceChannelCount);   // 平台例外：Apple 后端平台实现（拉取会话，#2157）

            result = AudioUnitInterop.AudioUnitSetProperty(_unit, AudioUnitInterop.kAudioUnitProperty_StreamFormat, AudioUnitInterop.kAudioUnitScope_Input, 0,
                &format, (uint)sizeof(AudioStreamBasicDescription));

            if (result != 0)
            {
                return result;
            }

            // S2Arm（#189 → §4.2，native 6ch 直通）：6 声道器件声明 5.1 布局（逐行对齐原 AudioQueue 会话 CreateQueue 的
            //   既有逻辑）：不声明时系统隐式 6→2 只复制 FL/FR，中置（对白）与环绕整段丢失；真 5.1 设备声明后按布局直通。
            //   设置失败按无布局继续（打出【红】，行为同旧），真 5.1 设备探建时已验过布局可用。显式下混的器件是 2 声道
            //   （折叠已在前），不设布局
            if (_deviceChannelCount == 6)
            {
                AudioChannelLayout layout = new AudioChannelLayout
                {
                    AudioChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A,
                    AudioChannelBitmap = 0,
                    NumberChannelDescriptions = 0
                };

                int layoutResult = AudioUnitInterop.AudioUnitSetProperty(
                    _unit,
                    AudioUnitInterop.kAudioUnitProperty_AudioChannelLayout,
                    AudioUnitInterop.kAudioUnitScope_Input,
                    0,
                    &layout,
                    (uint)sizeof(AudioChannelLayout));

                if (layoutResult != 0)
                {
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：声明 5.1 布局失败 rc={layoutResult}（按无布局继续，中置 / 环绕可能丢失）");
                }
            }

            AudioUnitInterop.AURenderCallbackStruct callback = new()
            {
                InputProc = Marshal.GetFunctionPointerForDelegate(_renderDelegate),   // 实例委托由会话字段持留 + GCHandle 防 GC(同 :290 先例)
                InputProcRefCon = GCHandle.ToIntPtr(_gcHandle),
            };

            result = AudioUnitInterop.AudioUnitSetProperty(_unit, AudioUnitInterop.kAudioUnitProperty_SetRenderCallback, AudioUnitInterop.kAudioUnitScope_Input, 0,
                &callback, (uint)sizeof(AudioUnitInterop.AURenderCallbackStruct));

            if (result != 0)
            {
                return result;
            }

            // AUHAL 拍大小可被系统 / 其他进程改动(#1066 实测设备 bsiz 会被保持):设为环容量帧数,防设备拍变大时回调超量
            uint maxFrames = (uint)_ringFrames;

            result = AudioUnitInterop.AudioUnitSetProperty(_unit, AudioUnitInterop.kAudioUnitProperty_MaximumFramesPerSlice, AudioUnitInterop.kAudioUnitScope_Global, 0,
                &maxFrames, sizeof(uint));

            if (result != 0)
            {
                return result;
            }

            return AudioUnitInterop.AudioUnitInitialize(_unit);
        }

        // S2Arm (11-14 设备缓冲 → 拉取档平移 AppleHardwareDeviceSession.cs:880-930): S2A_AUDIO_BUFFER_FRAMES 的
        //   16 倍数域请求,仅 macOS;失败按设备默认继续。DefaultOutput subtype 跟随用户默认设备,设备号从 AudioObject
        //   系统对象取(队列侧 'aqcd' 读不出的实测见原文注释)
        private void S2AApplyDeviceBufferFrames()
        {
            if (!OperatingSystem.IsMacOS())   // 平台例外：设备 IO 缓冲是 macOS HAL 属性，iOS 走 AVAudioSession
            {
                return;
            }

            int frames = AppleDeviceBufferFrames.FromEnvironment();

            if (frames == 0)
            {
                return;
            }

            AudioObjectPropertyAddress defaultOut = new()
            {
                Selector = kAudioHardwarePropertyDefaultOutputDevice,
                Scope = kAudioObjectPropertyScopeGlobal,
                Element = kAudioObjectPropertyElementMain
            };
            uint device = 0;
            uint deviceSize = sizeof(uint);

            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, ref defaultOut, 0, nint.Zero, ref deviceSize, ref device) != 0 || device == 0)
            {
                Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：读默认输出设备号失败，设备缓冲 {frames} 帧没请求（按设备默认继续）");
                return;
            }

            AudioObjectPropertyAddress address = new()
            {
                Selector = kAudioDevicePropertyBufferFrameSize,
                Scope = kAudioObjectPropertyScopeGlobal,
                Element = kAudioObjectPropertyElementMain
            };
            uint requested = (uint)frames;
            int setRc = AudioObjectSetPropertyData(device, ref address, 0, nint.Zero, sizeof(uint), ref requested);
            uint granted = 0;
            uint readSize = sizeof(uint);
            int getRc = AudioObjectGetPropertyData(device, ref address, 0, nint.Zero, ref readSize, ref granted);

            if (setRc != 0 || getRc != 0 || granted == 0)
            {
                Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：设备缓冲请求 {frames} 帧失败（set rc={setRc}、读回 rc={getRc}、值 {granted}）：按设备默认继续");
                return;
            }

            Console.Error.WriteLine($"[声] 输出 #{_diag.Index}：设备缓冲请求 {frames} 帧，设备实给 {granted} 帧 ≈ {granted * 1000.0 / RequestedSampleRate:F1} ms（只作用于本进程，其他 App 不受影响）");

            // S2Arm (#2157 评审 #15): 请求落地后按实给值自适应环——建器件序列里的探测(S2AProbeDeviceIOFrames)发生在
            //   请求之前,请求把 IO 周期改大时环要跟着大(此刻仍在建立序列单线程段,pace 尚未启动,成组换安全)
            S2ARingAdaptToIO((int)granted);
        }

        // S2Arm (#2157 评审 #15): 读系统默认输出设备的实际 IO 周期帧数(只读,不改设备;仅 macOS HAL,iOS / tvOS 无此
        //   属性)。读不到 / 非 macOS = 0(= 不自适应,维持 1024)。测试钩子 S2A_AUDIO_TEST_DEVICE_FRAMES 覆写返回值。
        private static int S2AProbeDeviceIOFrames()
        {
            if (_testDeviceFrames > 0)
            {
                return _testDeviceFrames;
            }

            if (!OperatingSystem.IsMacOS())   // 平台例外：HAL 设备属性只有 macOS
            {
                return 0;
            }

            AudioObjectPropertyAddress defaultOut = new()
            {
                Selector = kAudioHardwarePropertyDefaultOutputDevice,
                Scope = kAudioObjectPropertyScopeGlobal,
                Element = kAudioObjectPropertyElementMain
            };
            uint device = 0, deviceSize = sizeof(uint);

            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, ref defaultOut, 0, nint.Zero, ref deviceSize, ref device) != 0 || device == 0)
            {
                return 0;
            }

            AudioObjectPropertyAddress io = new()
            {
                Selector = kAudioDevicePropertyBufferFrameSize,
                Scope = kAudioObjectPropertyScopeGlobal,
                Element = kAudioObjectPropertyElementMain
            };
            uint frames = 0, framesSize = sizeof(uint);

            return AudioObjectGetPropertyData(device, ref io, 0, nint.Zero, ref framesSize, ref frames) == 0 && frames > 0 ? (int)frames : 0;
        }

        // S2Arm (#2157 评审 #15): IO 周期 → 环容量 / 配速水位(纯函数,services 侧单测)。环容量 = 下一 2 的幂 ≥
        //   max(1024, IO×2):IO ≤ 512 的设备恰为 1024(与固定 1024 时逐字节一致);配速水位 = min(环容量, IO + 1/4 IO +
        //   1024)(一次回调拿走一个 IO 周期后还留 1/4 周期 + 1024 帧余量;AudioProcessor 拿它与自己的 30 ms 地板取大)
        internal static int S2ADeriveRingFrames(int ioFrames)
        {
            long need = (long)Math.Max(ioFrames, 512) * 2;
            int ring = 1024;

            while (ring < need)
            {
                ring <<= 1;
            }

            return ring;
        }

        internal static int S2ADeriveDepthFrames(int ioFrames, int ringFrames)
        {
            if (ioFrames <= 0)
            {
                return 0;   // 读不到:不抬高,AudioProcessor 用自己的 30 ms 地板
            }

            long target = (long)ioFrames + ioFrames / 4 + 1024;

            return (int)Math.Min(target, ringFrames);
        }

        // S2Arm (#2157 评审 #15): 按读到的设备 IO 周期自适应环(只增不减)。调用点都在安全临界段——S2ARecover 的
        //   _writeLock + _suspended 内(环账目已结清、回调已静止、pace 被挡)与 SetupAudioUnit 建立序列单线程段
        //   (pace 尚未启动):环三字段成组换
        private void S2ARingAdaptToIO(int ioFrames)
        {
            if (ioFrames <= 0)
            {
                return;
            }

            if (S2ADeriveRingFrames(ioFrames) > _ringFrames)
            {
                int old = _ringFrames;
                Console.Error.WriteLine($"[声] 输出 #{_diag.Index}：设备 IO 周期 {_deviceIOFrames} → {ioFrames} 帧,拉取环 {old} → {S2ADeriveRingFrames(ioFrames)} 帧(只增不减地换,#2157 评审 #15)");
                _deviceIOFrames = ioFrames;
                _ringFrames = S2ADeriveRingFrames(ioFrames);
                _ring = new byte[(long)_ringFrames * _bytesPerFrame];
                _ringMask = _ringFrames - 1;
            }
            else if (ioFrames != _deviceIOFrames)
            {
                _deviceIOFrames = ioFrames;   // IO 周期变了但环够:只更新读数,配速水位随 S2AIODepthFrames 自动跟随
            }
        }

        // S2Arm (11-16 声音诊断 → 拉取档平移 AppleHardwareDeviceSession.cs:932-975): 建器件时记一行系统默认输出
        //   设备的传输方式、IO 周期、标称采样率、静音与音量。只读,不改设备;仅 macOS
        private void S2ALogOutputDevice()
        {
            if (!OperatingSystem.IsMacOS())   // 平台例外：HAL 设备属性只有 macOS
            {
                return;
            }

            AudioObjectPropertyAddress a = new() { Selector = kAudioHardwarePropertyDefaultOutputDevice, Scope = kAudioObjectPropertyScopeGlobal, Element = kAudioObjectPropertyElementMain };
            uint device = 0, size = sizeof(uint);

            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, ref a, 0, nint.Zero, ref size, ref device) != 0 || device == 0)
            {
                Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：读不到系统默认输出设备");
                return;
            }

            string U32(uint selector, uint scope)
            {
                AudioObjectPropertyAddress q = new() { Selector = selector, Scope = scope, Element = kAudioObjectPropertyElementMain };
                uint v = 0, n = sizeof(uint);
                return AudioObjectGetPropertyData(device, ref q, 0, nint.Zero, ref n, ref v) == 0 ? v.ToString() : null;
            }

            AudioObjectPropertyAddress t = new() { Selector = kAudioDevicePropertyTransportType, Scope = kAudioObjectPropertyScopeGlobal, Element = kAudioObjectPropertyElementMain };
            uint tran = 0, ts = sizeof(uint);
            string transport = AudioObjectGetPropertyData(device, ref t, 0, nint.Zero, ref ts, ref tran) == 0
                ? (tran switch
                {
                    0x626C746E => "内置", 0x626C7565 => "蓝牙", 0x626C6561 => "蓝牙低功耗", 0x75736220 => "USB", 0x68646D69 => "HDMI", 0x64707274 => "DisplayPort",
                    0x61697270 => "AirPlay", 0x67727570 => "聚合", 0x76697274 => "虚拟", 0x7468756E => "雷雳", 0x70636920 => "PCI", _ => $"其他 0x{tran:x8}",
                })
                : "读不到";
            AudioObjectPropertyAddress r = new() { Selector = kAudioDevicePropertyNominalSampleRate, Scope = kAudioObjectPropertyScopeGlobal, Element = kAudioObjectPropertyElementMain };
            double rate = 0; uint rs = sizeof(double);
            string rateText = AudioObjectGetPropertyDataDouble(device, ref r, 0, nint.Zero, ref rs, ref rate) == 0 ? $"{rate:F0} Hz" : "读不到";
            AudioObjectPropertyAddress vq = new() { Selector = kAudioDevicePropertyVolumeScalar, Scope = kAudioDevicePropertyScopeOutput, Element = kAudioObjectPropertyElementMain };
            float vol = 0; uint vs = sizeof(float);
            string volText = AudioObjectGetPropertyDataFloat(device, ref vq, 0, nint.Zero, ref vs, ref vol) == 0 ? $"{vol:F2}" : "主元素读不到（多为按声道调音量的设备）";
            string frames = U32(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
            string mute = U32(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput);
            Console.Error.WriteLine($"[声] 输出 #{_diag.Index}：系统默认输出设备 {device}，传输方式 {transport}、IO 周期 {frames ?? "读不到"} 帧、标称采样率 {rateText}（本会话 {RequestedSampleRate} Hz）、静音 {mute ?? "读不到"}、音量 {volText}");
        }

        // S2Arm (11-14 → 拉取档 §3.3): 设备 render 回调——唯一环读者。零锁(SPSC 指针各单写者)、零分配(Tick 首行 +
        //   栈上操作)、不读客机内存(重活全在 pace 线程)、不调系统 API(只 memcpy + 计时 + 事件置位)。
        //   环里只会有排队样本(写者从不写零),欠载部分 ioData 清零(SDK AudioUnitProperties.h:318-320 明文要求)、
        //   记欠载计数,不进账目;回调只记「消费了多少帧」,#769 评论预告的「交还回调只记槽位、收回挪到节拍线程」正是本形态
        private unsafe int RenderCallback(nint inRefCon, nint ioActionFlags, nint inTimeStamp, uint inBusNumber, uint inNumberFrames, nint ioData)
        {
            Ryujinx.Common.S2AThreadAlloc.Tick("CoreAudio 拉取回调"); // S2Arm: per-thread allocation accounting
            Interlocked.Increment(ref _callbackDepth);
            long t0 = Stopwatch.GetTimestamp();

            try
            {
                Volatile.Write(ref _lastRenderTicks, t0); // S2Arm: 停播看门狗(S2ACheckStall)

                if (ioData == nint.Zero)
                {
                    return 0;
                }

                AudioConverterInterop.AudioBuffer* buffer = (AudioConverterInterop.AudioBuffer*)(ioData + AudioConverterInterop.AudioBufferListBuffersOffset);
                int need = (int)Math.Min((long)inNumberFrames * _bytesPerFrame, (long)buffer->DataByteSize);
                int take = 0;
                long read = 0;

                // 静默机制(§5.1):置位后回调不读环、直接填零返回(停 / 重建 / Dispose 期间的防写穿)
                if (!Volatile.Read(ref _suspended))
                {
                    long write = Volatile.Read(ref _ringWrite);
                    read = _ringRead;   // 唯一读者:本回调(帧偏移)
                    long availFrames = write - read;

                    // 帧域寻址(§4.2):环内恒为整帧,消费按帧粒度;字节落点 = (帧下标 & mask) × _bytesPerFrame
                    int takeFrames = (int)Math.Min(availFrames, need / _bytesPerFrame);
                    take = takeFrames * _bytesPerFrame;

                    if (take > 0)
                    {
                        byte[] ring = _ring;
                        int mask = _ringMask;
                        int off = 0;

                        while (off < take)   // 环回绕:帧粒度两段拷贝(段长 = 到环尾的整帧数)
                        {
                            int fIdx = (int)((read + off / _bytesPerFrame) & mask);
                            int n = Math.Min((_ringFrames - fIdx) * _bytesPerFrame, take - off);
                            new Span<byte>(ring, fIdx * _bytesPerFrame, n).CopyTo(new Span<byte>((byte*)buffer->Data + off, n));
                            off += n;
                        }
                    }
                }

                if (need > take)
                {
                    new Span<byte>((byte*)buffer->Data + take, need - take).Clear();
                    Interlocked.Increment(ref _ringUnderruns);
                }

                if (buffer->DataByteSize > (uint)need)   // 设备给的槽大于本拍帧数:声明余量清零(SDK 要求填满 ioData)
                {
                    new Span<byte>((byte*)buffer->Data + need, (int)(buffer->DataByteSize - (uint)need)).Clear();
                }

                // 测试钩子:开播后到点,一次回调在计时窗口里睡这么久(模拟输出器件卡死,服务层单测 --apple-audio-enqueue-stuck 的等价物)
                if (_testEnqStall.AtS > 0 && !_testEnqStallDone && _started && t0 - _startTicks >= (long)_testEnqStall.AtS * Stopwatch.Frequency)
                {
                    _testEnqStallDone = true;
                    Console.Error.WriteLine($"[声] 测试钩子：输出 #{_diag.Index} 开播后第 {_testEnqStall.AtS} 秒一次拉取回调卡 {_testEnqStall.Ms} ms（模拟输出器件卡死）");
                    Thread.Sleep(_testEnqStall.Ms);
                }

                if (take > 0)
                {
                    Volatile.Write(ref _ringRead, read + take / _bytesPerFrame);   // 消费完才发布读者指针(单写者,帧偏移);欠载零不进账目
                    Interlocked.Add(ref _renderedFrames, take / _bytesPerFrame);
                    _paceEvent.Set();   // 记账、下混、补环全在 pace 线程(#769)
                }

                return 0;
            }
            finally
            {
                long dt = Stopwatch.GetTimestamp() - t0;

                if (dt > Volatile.Read(ref _renderMaxTicks))   // 单次最大(判定语义是「单次卡 ≥250 ms」,对齐 :1042-1044)
                {
                    Volatile.Write(ref _renderMaxTicks, dt);
                }

                Interlocked.Decrement(ref _callbackDepth);
            }
        }

        // S2Arm (11-02 → 拉取档): 送数线程——每轮先把手环以来回调消费的帧数喂播放信用(对应 _pump.Returned 的交还喂入点
        //   :1242),再补环、放回。等待节拍与现有 PaceLoop 相同:头一块缓冲的余量何时被播放头越过(PlaybackCredit.TicksUntil),
        //   每块一次唤醒(放回节拍跟墙钟,不跟回调粒度)
        private void PaceLoop()
        {
            S2AApplyPaceQos();   // 本线程承载放回链第一跳:QoS user-interactive(见方法注释),并发负载下迟醒由 9 ms 级压回

            while (!Volatile.Read(ref _disposed))
            {
                long now = Stopwatch.GetTimestamp();
                long virtualWait = S2AVirtualReturn(now);
                S2ADrainRendered(now);

                if (Volatile.Read(ref _virtual))
                {
                    FillVirtual();   // 无设备播放:读出样本按墙钟记「播完」时刻,不进环(§5.1 _virtual 家族)
                }
                else
                {
                    FillRing();     // 唯一环写者:ASQ(客机内存读)→下混/音量→写环,整段持 _writeLock
                }

                S2ACredit();
                MaybeStartUnit();

                long rest;
                lock (_queueLock)
                {
                    rest = _queuedCount == 0 ? -1 : (long)(_queued[_queuedHead].SampleCount - _headPlayed) * _bytesPerFrame;
                }

                long ticks = Math.Min(rest < 0 ? long.MaxValue : _credit.TicksUntil(rest, _ringSampleWritten + Interlocked.Read(ref _virtualSampleWritten), Stopwatch.GetTimestamp()), virtualWait);

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

        // pace 线程:上轮以来回调消费的环字节 → 播放信用地板(对应 S2ADrainReturned 的交还喂入,:1227-1251)
        private void S2ADrainRendered(long now)
        {
            long rendered = Interlocked.Read(ref _renderedFrames);
            long delta = rendered - _renderedAckFrames;

            if (delta <= 0)
            {
                return;
            }

            int bytes = (int)(delta * _bytesPerFrame);
            _renderedAckFrames = rendered;

            // 测试钩子(见 _testSlowAfterHeal):4 拍里 3 拍不记成「播完」(器件有回调、只算播了约四分之一)。
            //   平移对齐原版(OnReturned 先 +N、TestUnplay 再 -N,净 0):诊断的「已播」读数 4 拍只净 +N,
            //   信用照常无条件喂(钩子只欠报已播读数给重启后核对用,不改游戏放回节奏)——原先拉取版漏喂
            //   信用、诊断只减不加,放回慢 4 倍、FramesPlayed 负漂(S2AVerifyRecover 读数失真)
            _diag.OnReturned(bytes, (int)RingBytes);

            if (_testSlowAfterHeal > 0 && _heals == _testSlowAfterHeal && (++_testSlowTick & 3) != 0)
            {
                _diag.TestUnplay(bytes);
            }

            _credit.Returned(bytes, now);
            _diag.SetLead(_credit.LeadBytes / _bytesPerFrame);
        }

        // #1921 → 拉取档:队列时钟的等价读数。原 AudioQueue 会话读「队列时钟 − 交付量」(iOS 时间轴跑前检测 QueueTimelineWatch 用);
        //   拉取档没有队列时钟,等价不变量是「设备已渲染帧数 − 入环帧数」= −(环内在途 + 历次重启丢弃的帧),读数先已渲染、后已入环
        //   (已渲染的必已先入环,两读之间只会多入不会少入),结构上恒 ≤ 0——时间轴跑过交付量的误判类在拉取模型结构性消失(§4.4),
        //   重启(环重置)也不会翻正(丢弃的帧只让读数更负)。仓内单测 --apple-audio-queue-clock 经反射取这个读数核对,名字沿用原方法
        private long S2AQueuePastSubmitted()
        {
            if (_unit == nint.Zero || !Volatile.Read(ref _unitRunning))
            {
                return long.MinValue;
            }

            long rendered = Interlocked.Read(ref _renderedFrames);   // 先读已渲染
            long written = Interlocked.Read(ref _ringSampleWritten) / _bytesPerFrame;   // 后读已入环(帧)

            return rendered - written;
        }

        // S2Arm (拉取档 §3.2/§4.1): 唯一环写者(pace 线程)——把 AudioSampleQueue 读到的设备字节经下混/音量后写入环,
        //   只写到「环剩余空间」为止:环满即停,样本留在 ASQ 排队,这就是背压。整段持 _writeLock(含客机内存读:
        //   「pace 卡在读客机内存」表现为持锁,TryEnter 可检测,§5.1);欠载不在此补(回调里填零,§3.4)
        private void FillRing()
        {
            if (Volatile.Read(ref _suspended) || Volatile.Read(ref _closedStuck))
            {
                return;
            }

            lock (_writeLock)
            {
                if (Volatile.Read(ref _suspended) || Volatile.Read(ref _closedStuck))
                {
                    return;
                }

                while (true)
                {
                    long write = Volatile.Read(ref _ringWrite);
                    long read = Volatile.Read(ref _ringRead);
                    long freeFrames = _ringFrames - (write - read);   // 写者读指针只取可见量(保守:宁可少写,不越未读)

                    if (freeFrames <= 0)
                    {
                        return;   // 环满即背压:样本留在 ASQ,渲染器按输出深度节流(S2ADepthWait)
                    }

                    int n = (int)Math.Min(freeFrames * _bytesPerFrame, _fill.Length);
                    n -= n % _bytesPerFrame;

                    if (n <= 0)
                    {
                        return;
                    }

                    int got = _samples.Read(_fill.AsSpan(0, n));   // ASQ 环绕段语义;客机内存读在此锁内

                    if (got < _bytesPerFrame)
                    {
                        return;
                    }

                    int bytes = got - got % _bytesPerFrame;   // 整帧字节;零头留在 ASQ 下轮续

                    ApplyVolume(_fill.AsSpan(0, bytes));   // 音量(§5.3):pace 写环前,同「Submit 前泵锁内」的时机语义

                    int off = 0;
                    while (off < bytes)   // 环回绕:帧粒度两段拷贝(§4.2,字节落点 = (帧下标 & mask) × _bytesPerFrame)
                    {
                        int fIdx = (int)((write + off / _bytesPerFrame) & _ringMask);
                        int c = Math.Min((_ringFrames - fIdx) * _bytesPerFrame, bytes - off);
                        Buffer.BlockCopy(_fill, off, _ring, fIdx * _bytesPerFrame, c);
                        off += c;
                    }

                    int framesWritten = bytes / _bytesPerFrame;

                    Volatile.Write(ref _ringWrite, write + framesWritten);   // 先写字节、再发布写指针(SPSC 内存序,ARM64;帧偏移)
                    Interlocked.Add(ref _ringSampleWritten, bytes);   // Interlocked:S2AQueuePastSubmitted 在别的线程读,先读已渲染后读这里
                    _diag.OnSubmit(_fill.AsSpan(0, bytes), ((write + framesWritten) - read) * _bytesPerFrame - bytes);

                    if (got < n)
                    {
                        return;   // ASQ 读空:下轮唤醒再补
                    }
                }
            }
        }

        // 无设备播放中(见 _virtual):pace 读出样本、按墙钟逐块记「播完」时刻(不进环)。锁结构与 FillRing 一致
        private void FillVirtual()
        {
            if (Volatile.Read(ref _suspended) || Volatile.Read(ref _closedStuck))
            {
                return;
            }

            lock (_writeLock)
            {
                if (Volatile.Read(ref _suspended) || Volatile.Read(ref _closedStuck))
                {
                    return;
                }

                int free = NumBuffers - _virtualCount;

                while (free > 0)
                {
                    int n = Math.Min(_samples.Length, _fill.Length);
                    n -= n % _bytesPerFrame;

                    if (n <= 0)
                    {
                        return;
                    }

                    int got = _samples.Read(_fill.AsSpan(0, n));

                    if (got < _bytesPerFrame)
                    {
                        return;
                    }

                    int bytes = got - got % _bytesPerFrame;
                    ApplyVolume(_fill.AsSpan(0, bytes));
                    S2AVirtualSubmit(bytes);
                    free--;
                }
            }
        }

        // S2Arm (11-02 → 拉取档): release what now counts as played(rendered floor 或已提交且被播放头越过,见 PlaybackCredit)。
        //   「已提交」= 已从客机内存读出的字节:写环 + 无设备播放读出(原 AudioQueue 会话的无设备路径经泵提交、SubmittedSampleBytes
        //   同样照常增长;拉取档虚拟读出不进环,单记在这里并进提交量——否则无设备期间 Take 被「环提交冻结」钉住、游戏侧播完
        //   计数不动,交还永不停恰是要保证这条计数照常走)
        private void S2ACredit()
        {
            int bytes = _credit.Take(_ringSampleWritten + Interlocked.Read(ref _virtualSampleWritten), Stopwatch.GetTimestamp());

            if (bytes > 0)
            {
                ProcessPlayedSamples(bytes);
            }
        }

        private void ProcessPlayedSamples(int bytesPlayed)
        {
            // S2Arm (#189 → 拉取档): device bytes (stereo after the explicit downmix); frame counts are preserved by the fold(平移 :1293-1332)
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

            // S2Arm (11-12 功耗 → 拉取档 §4.2): 播完需要唤醒 AudioManager.Worker 的只有 audout 的客体缓冲(渲染器
            //   会话不置——纯 audren 游戏 Worker 仍零唤醒,#762 语义)。拉取模式下该事件的节拍源从「设备交还 burst」
            //   变为「render 增量 → pace → credit → played」(每设备拍一次,与现状每交还 burst 一次同数量级)
            if (needUpdate && !_rendererProducer)
            {
                _updateRequiredEvent.Set();
            }
        }

        // S2Arm (拉取档 §4.3): 起播门槛。prime=0(缺省)= 首个排队样本入环即 AudioOutputUnitStart;prime>0 =
        //   环内凑够 prime 毫秒(或 Start 后 100 ms 兜底,看门狗 S2APrimeFallback 每 250 ms 补查——仅 prime>0 时启用)
        private void MaybeStartUnit()
        {
            // S2Arm (代码评审必修): 起播决定整段持 _lock 做 check-then-act。Start / Stop / Dispose / S2ARecover
            //   全在 _lock 下跑、_unit 也只被它们改动;原 AudioQueue 等价物 MaybeStartQueue 三处调用全部持 _lock
            //   (AppleHardwareDeviceSession.cs:1500-1503、:1536、:449-152,注释明写「_lock 内调」),起播挪到 pace
            //   线程时丢了这把锁:与 Stop 交错会把器件在停播后重新开起来(环+排队照播,MaybeStartUnit 只开不停);
            //   与 Dispose / S2ARecover(rebuild) 交错,_unit 的检查与使用之间会被换成 nint.Zero——对已释放的 CoreAudio
            //   实例调 Start。pace 与看门狗的锁序 _lock→_writeLock 只在看门狗侧嵌套,pace 侧两把锁从不嵌套,无死锁。
            //   _suspended(静默序列)期间不开播:停 / 重建 / Dispose 进行中器件不在 pace 手里
            lock (_lock)
            {
                if (Volatile.Read(ref _unitRunning) || !_started || Volatile.Read(ref _virtual) || Volatile.Read(ref _suspended) || _unit == nint.Zero)
                {
                    return;
                }

                bool primed;

                if (_primeMs == 0)
                {
                    primed = Volatile.Read(ref _ringWrite) > Volatile.Read(ref _ringRead);   // 首块入环即开播
                }
                else
                {
                    long floorFrames = (long)_primeMs * RequestedSampleRate / 1000;
                    bool reached = (RingBytes / _bytesPerFrame) >= floorFrames;
                    primed = reached || (Stopwatch.GetTimestamp() - _startTicks) * 1000 / Stopwatch.Frequency >= StartFallbackMilliseconds;
                }

                if (!primed)
                {
                    return;
                }

                _unitRunning = true;
                Volatile.Write(ref _lastRenderTicks, Stopwatch.GetTimestamp()); // S2Arm: 停播看门狗从真开播起算
                int rc = AudioUnitInterop.AudioOutputUnitStart(_unit);

                if (rc != 0)
                {
                    _unitRunning = false;
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：AudioOutputUnitStart rc={rc}（没开播，下一笔声音到时再试）");
                }
            }
        }

        private unsafe void ApplyVolume(Span<byte> data)
        {
            // S2A：游戏音量(#1186,runtime/src/game_volume.c;按游戏存、局中齿轮菜单可改)乘进来;100 时同原来整段跳过
            //   (平移 ApplyVolume :1334-1369 的语义:同为供给侧、中途改音量只影响之后写入的块)
            float volume = Math.Clamp(_volume * _driver.Volume * (S2AGameVolume() / 100f), 0f, 1f);
            if (volume >= 0.999f)
                return;

            switch (RequestedSampleFormat)
            {
                case SampleFormat.PcmInt16:
                    foreach (ref short s in MemoryMarshal.Cast<byte, short>(data))
                        s = (short)(s * volume);
                    break;

                case SampleFormat.PcmFloat:
                    foreach (ref float f in MemoryMarshal.Cast<byte, float>(data))
                        f *= volume;
                    break;

                case SampleFormat.PcmInt32:
                    foreach (ref int v in MemoryMarshal.Cast<byte, int>(data))
                        v = (int)(v * volume);
                    break;

                case SampleFormat.PcmInt8:
                    foreach (ref sbyte b in MemoryMarshal.Cast<byte, sbyte>(data))
                        b = (sbyte)(b * volume);
                    break;
            }
        }

        // S2Arm (11-09/11-12 → 拉取档 §4.2): the first buffer tells the producer apart(renderer Data / audout 客体缓冲)。
        //   拉取档该定性只保留给播完唤醒门用(ProcessPlayedSamples),不再驱动起播门槛(§4.3 统一 0)
        private void ConfigurePrimeFloor(AudioBuffer buffer)
        {
            if (_primeConfigured)
            {
                return;
            }

            _primeConfigured = true;
            _rendererProducer = buffer.Data != null;
        }

        // S2Arm (#189 → 拉取档): guest buffers (no Data array) are folded while the pace thread reads them(平移 :1396-1415)
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

            // S2Arm (#189 → 拉取档): renderer buffers (Data) are folded here(平移 :1431-1444);guest bytes (6-channel)
            //   are folded by the pace thread while it reads them(ConvertingReader),帧数不变
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

            // S2Arm (11-02 → 拉取档): register before its samples can be submitted(平移 :1448-1467):
            //   submitted samples may count as played at once (PlaybackCredit), and played samples must find their buffer in _queued
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

            // 唯一环写者是 pace 线程:补环、起播、放回都由它做(现有 QueueBuffer 直接 Pump 的差异,§3.2 单写者不变量)
            _paceEvent.Set();
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

                Volatile.Write(ref _lastRenderTicks, _startTicks); // S2Arm: 停播看门狗从开播时刻起算

                if (Volatile.Read(ref _virtual))
                {
                    // 无设备播放中(见 _virtual):pace 已往无设备交,不碰真器件;Stop 时停住的块续上
                    S2AVirtualPause(false);
                }
                else if (Volatile.Read(ref _unitRunning))
                {
                    // 从 Stop 的暂停恢复:器件已预充过环,直接续播(播放信用地板直接是已渲染量,不需要重学交还相位)
                    int rc = AudioUnitInterop.AudioOutputUnitStart(_unit);

                    if (rc != 0)
                    {
                        _unitRunning = false;
                        Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：续播 AudioOutputUnitStart rc={rc}");
                    }
                }

                _paceEvent.Set();
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
                AudioUnitInterop.AudioOutputUnitStop(_unit);
                _unitRunning = false;

                if (Volatile.Read(ref _virtual))
                {
                    S2AVirtualPause(true);
                }
                // 拉取档不需要 ResetClock(§4.3):AudioQueue 档暂停后交还相位要重学,拉取档的地板直接是已渲染量
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

        // S2Arm (11-13 断音 → 拉取档): what the renderer paces by (AudioProcessor.S2ADepthWait): queued + written to the ring,
        //   not rendered yet——环内恒为排队样本,环 + ASQ 即在途;仅在播才报,否则 -1(平移 :1576-1578 的口径)
        public long S2ABufferedFrames => Volatile.Read(ref _unitRunning) && !Volatile.Read(ref _disposed)
            ? (RingBytes + _samples.Length) / _bytesPerFrame
            : -1;

        // S2Arm (#2157 评审 #15,IS2AIOAwareDepth): 本输出的配速水位——设备 IO 周期 + 1/4 周期 + 1024 帧,上限环容量
        //   (超出环容量的水位无意义);AudioProcessor 把它与自己的 30 ms 地板取大。读不到设备 IO 周期 = 0(不抬高)
        public long S2AIODepthFrames => S2ADeriveDepthFrames(_deviceIOFrames, _ringFrames);

        public override void PrepareToClose() { }
        // S2Arm: the buffer goes back to the game (Stop / FlushBuffers / Dispose) possibly before it was played: keep what it
        //   held——未读样本先拷进环(ASQ.Release 只拷未读段),已进拉取环但未渲染的样本照播(同「已交设备部分照播」语义,§5.4)
        public override void UnregisterBuffer(AudioBuffer buffer) => _samples.Release(buffer);

        // 无设备播放(见 _virtual)——拉取档的虚拟家族:这块从上一块播完起(或现在,取晚的)按采样率播完
        private void S2AVirtualSubmit(int bytes)
        {
            lock (_virtualLock)
            {
                long now = Stopwatch.GetTimestamp();
                _virtualEnd = Math.Max(now, _virtualEnd) + (long)(bytes / _bytesPerFrame) * Stopwatch.Frequency / RequestedSampleRate;
                int i = (_virtualHead + _virtualCount) % NumBuffers;
                _virtualSlot[i] = bytes / _bytesPerFrame;   // 拉取档没有设备槽号,直接记这块的帧数
                _virtualDue[i] = _virtualEnd;
                _virtualCount++;
                _virtualFrames += bytes / _bytesPerFrame;
            }

            Interlocked.Add(ref _virtualSampleWritten, bytes);   // 虚拟读出计入「已提交」(见 S2ACredit):无设备期间 Take 照常放行
            _paceEvent.Set();
        }

        // 送数线程:到点的无设备块交还(同设备回调:记播放信用、刷新回调时刻);返回下一块还要等的刻数(平移 :1087-1106)
        private long S2AVirtualReturn(long now)
        {
            lock (_virtualLock)
            {
                if (_virtualPausedAt != 0)
                {
                    return long.MaxValue;
                }

                long frames = 0;

                while (_virtualCount > 0 && _virtualDue[_virtualHead] <= now)
                {
                    frames += _virtualSlot[_virtualHead];
                    _virtualHead = (_virtualHead + 1) % NumBuffers;
                    _virtualCount--;
                    Volatile.Write(ref _lastRenderTicks, now);
                }

                if (frames > 0)
                {
                    _credit.Returned((int)(frames * _bytesPerFrame), now);
                }

                return _virtualCount > 0 ? _virtualDue[_virtualHead] - now : long.MaxValue;
            }
        }

        // 无设备播放退出时(S2ARecover 的 wasVirtual 分支,调用后紧接 S2AVirtualClearLocked):已从 ASQ 读进虚拟槽、
        //   还没到点的帧记作播完(Reclaimed)——对齐原 AudioQueue 会话退出无设备时对泵在途缓冲的收回口径(pump.Restart
        //   的收回 → credit.Reclaimed,游戏的缓冲照常放回)。拉取档原先只收回环(≤1024 帧),虚拟槽最多 32×1024 帧
        //   直接清掉、游戏侧对应缓冲永不放回,「每放回一块再交一块」的 audout 游戏断供(实测:回设备后 played 冻结)。
        //   返回字节数,并进 S2ARecover 的 reclaimed
        private int S2AVirtualReclaimPendingLocked()
        {
            lock (_virtualLock)
            {
                long pending = 0;

                for (int k = 0; k < _virtualCount; k++)
                {
                    pending += _virtualSlot[(_virtualHead + k) % NumBuffers];
                }

                if (pending > 0)
                {
                    _credit.Reclaimed((int)(pending * _bytesPerFrame));
                }

                return (int)(pending * _bytesPerFrame);
            }
        }

        // 停泵期间调(S2ARecover 的静默序列里):清掉无设备在途记录(平移 :1108-1116)
        private void S2AVirtualClearLocked()
        {
            lock (_virtualLock)
            {
                _virtualHead = _virtualCount = 0;
                _virtualEnd = _virtualPausedAt = 0;
            }
        }

        // 游戏 Stop / Start:同真器件的暂停——停着不交还,续播时余下的块按停了多久整体顺延(平移 :1118-1149)
        private void S2AVirtualPause(bool pause)
        {
            lock (_virtualLock)
            {
                long now = Stopwatch.GetTimestamp();

                if (pause)
                {
                    _virtualPausedAt = _virtualPausedAt == 0 ? now : _virtualPausedAt;

                    return;
                }

                if (_virtualPausedAt == 0)
                {
                    return;
                }

                long shift = now - _virtualPausedAt;
                _virtualPausedAt = 0;

                for (int k = 0; k < _virtualCount; k++)
                {
                    _virtualDue[(_virtualHead + k) % NumBuffers] += shift;
                }

                _virtualEnd = _virtualCount > 0 ? _virtualEnd + shift : 0;
            }

            _paceEvent.Set();
        }

        // 进入无设备播放(见 _virtual):停真器件、环内样本当播完(静默序列),之后 pace 往无设备交。停不下来(泄漏路径)就不进
        private void S2AEnterVirtual(string why)
        {
            lock (_lock)
            {
                if (_unit == nint.Zero || Volatile.Read(ref _virtual) || !_healOn)
                {
                    return;
                }

                long inFlightFrames = (RingBytes + _samples.Length) / _bytesPerFrame;
                int stopRc = 0;
                bool entered = false;

                if (Monitor.TryEnter(_writeLock, TimeSpan.FromMilliseconds(200)))
                {
                    try
                    {
                        Volatile.Write(ref _suspended, true);
                        stopRc = AudioUnitInterop.AudioOutputUnitStop(_unit);
                        S2AWaitCallbacksQuiet();

                        if (stopRc == 0)
                        {
                            S2AResetRingLocked(Stopwatch.GetTimestamp());   // 环内样本当播完(收回)
                            S2AVirtualClearLocked();
                            _virtualFrames = 0;
                            _virtualForInterrupt = S2AAudioNotes.Interrupted;   // 移植自 7d090b2cb:中断进入者等「中断结束」/ 每 10 秒重激活,非中断进入者 VirtualProbeMs 后就试回设备
                            Volatile.Write(ref _virtual, true);
                            entered = true;
                        }
                    }
                    finally
                    {
                        Volatile.Write(ref _suspended, false);
                        Monitor.Exit(_writeLock);
                    }
                }

                if (!entered)
                {
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：{why}，停输出器件失败（rc={stopRc} 或送数线程卡在读游戏内存），没改走无设备播放");

                    return;
                }

                _unitRunning = false;
                _lastHealTicks = Stopwatch.GetTimestamp();
                _paceEvent.Set();
                Console.Error.WriteLine($"[声] 输出 #{_diag.Index}：{why}（在途 {inFlightFrames} 帧）→ 停输出器件、环内样本当播完，改走无设备播放" +
                    "（游戏的声音按采样率当作播完交还，没声；设备能用了再回到设备）");
            }
        }

        // S2Arm (11-14 → 拉取档 §5.5): 会话释放。与现有逐条对齐:看门狗注销与锁序、_writeLock.TryEnter(200ms) 护栏
        //   (pace 仍会读客机内存,经 ASQ.Read → ReadSamples)、卡死时停器件 + _closedStuck + 不释放环与下混器件、
        //   pace 线程 1 秒不退则不 Unregister、驱动按存活保留共享事件。
        //   GCHandle 释放顺序(评审 F): AudioOutputUnitStop → 回调计数静止确认 → AudioComponentInstanceDispose → Free
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
                    _unitRunning = false;

                    bool leaked = false;

                    if (_unit != nint.Zero)
                    {
                        if (Monitor.TryEnter(_writeLock, TimeSpan.FromMilliseconds(200)))
                        {
                            try
                            {
                                Volatile.Write(ref _suspended, true);
                                AudioUnitInterop.AudioOutputUnitStop(_unit);
                                S2AWaitCallbacksQuiet();   // Stop 后回调计数静止确认(§5.5 顺序)
                                int result = AudioUnitInterop.AudioComponentInstanceDispose(_unit);
                                if (result != 0)
                                    throw new InvalidOperationException($"AudioComponentInstanceDispose failed: {result}; callback handle retained");
                                _unit = nint.Zero;
                            }
                            finally
                            {
                                Volatile.Write(ref _suspended, false);
                                Monitor.Exit(_writeLock);
                            }
                        }
                        else
                        {
                            Volatile.Write(ref _closedStuck, true);
                            AudioUnitInterop.AudioOutputUnitStop(_unit);
                            leaked = true;
                            Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：释放时送数线程卡在读游戏内存（等了 200 ms），器件已停、不释放（防止释放后它再往环里写）");
                        }
                    }

                    if (!leaked)
                    {
                        // S2Arm（#189 后续，评审 11-16）：VS / 下混档收局统计(只在有记录时打一行)
                        if (_processor != null && (_processor.FailureCount > 0 || _processor.ClippedSampleCount > 0))
                        {
                            Console.Error.WriteLine($"[声] 输出 #{_diag.Index} 收局：5.1→2.0 档「{AppleOutputModeSelector.ModeName(_processor.EffectiveMode)}」渲染失败 {_processor.FailureCount} 片、截幅 {_processor.ClippedSampleCount} 采样（int16 满幅计）");
                        }

                        _processor?.Dispose();   // S2Arm (#189): the explicit downmix stage goes with the unit
                        int underruns = Interlocked.Exchange(ref _ringUnderruns, 0);

                        if (underruns > 0)
                        {
                            Console.Error.WriteLine($"[声] 输出 #{_diag.Index} 收局：拉取环欠载 {underruns} 拍（回调填零，样本未丢失）");
                        }
                    }

                    // 器件销毁 + 回调计数静止之后才 Free(Synchronous disposal completes callbacks before their
                    //   handle is released 的类比推断,§5.5/§8;_suspended 兜底迟到回调)
                    if (_gcHandle.IsAllocated && !leaked) _gcHandle.Free();
                    _diag.Dispose();
                    Volatile.Write(ref _disposed, true);
                    _paceEvent.Set();
                }

                // S2Arm (11-19): wait for the pace thread to leave before returning(平移 :1641-1655)
                Thread pace = _paceThread;
                if (pace != null && pace != Thread.CurrentThread && !pace.Join(1000))
                {
                    Console.Error.WriteLine($"[声] 【红】输出 #{_diag.Index}：释放时送数线程 1 秒内没退出（卡在读游戏内存？），先放开");
                }
                else
                {
                    _driver.Unregister(this);
                }
            }
        }

        public override void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        // S2Arm (#189 → 拉取档): the SampleReader the pace thread uses for guest buffers(平移 :1667-1728)——
        //   maps the device byte offset (stereo after folding) back to the guest stream (6-channel) and folds only
        //   the frames asked for
        private sealed class ConvertingReader : HardwareDeviceSessionOutputBase
        {
            private readonly AppleOutputProcessor _processor;
            private readonly int _guestBytesPerFrame;
            private readonly int _deviceBytesPerFrame;
            private HardwareDeviceSessionOutputBase _inner;
            private byte[] _scratch = Array.Empty<byte>();

            public ConvertingReader(ApplePullHardwareDeviceSession owner, AppleOutputProcessor processor)   // 平台例外：Apple 后端平台实现内部的下混读代理（#189）
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
