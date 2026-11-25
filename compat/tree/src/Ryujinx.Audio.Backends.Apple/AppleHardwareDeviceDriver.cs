using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Common.Logging;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;
using System.Runtime.Versioning;
using Ryujinx.Audio.Backends.Apple.Native;
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;
using static Ryujinx.Audio.Integration.IHardwareDeviceDriver;

namespace Ryujinx.Audio.Backends.Apple
{
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    public sealed class AppleHardwareDeviceDriver : IHardwareDeviceDriver
    {
        private readonly ManualResetEvent _updateRequiredEvent;
        private readonly ManualResetEvent _pauseEvent;
        private readonly ConcurrentDictionary<AppleHardwareDeviceSession, byte> _sessions;
        private readonly bool _supportSurroundConfiguration;
        private readonly object _sessionLock = new();
        private bool _disposed;

        public float Volume { get; set; }

        public AppleHardwareDeviceDriver()
        {
            _updateRequiredEvent = new ManualResetEvent(false);
            _pauseEvent = new ManualResetEvent(true);
            _sessions = new ConcurrentDictionary<AppleHardwareDeviceSession, byte>();

            // S2A：能耗单变量开关（缺省全关，行为不变；同旧库 front_ios.m；10-20 动森新架构整机功率约为旧库 2 倍）：
            //   S2A_AUDIO_CH2=1 不试建 5.1、只报 2 声道（游戏自己出立体声，混音与系统降混都按 2 声道）
            //   S2A_AUDIO_SOLO=1 AVAudioSession 类别设 SoloAmbient；S2A_AUDIO_IO20=1 首选 IO 缓冲 20 ms
            //   S2A_AUDIO_STEREO=1 = 以上三项同开（减法实验拆项前的合并开关）
            bool all = Environment.GetEnvironmentVariable("S2A_AUDIO_STEREO") == "1";
            bool ch2 = all || Environment.GetEnvironmentVariable("S2A_AUDIO_CH2") == "1";
            bool solo = all || Environment.GetEnvironmentVariable("S2A_AUDIO_SOLO") == "1";
            bool io20 = all || Environment.GetEnvironmentVariable("S2A_AUDIO_IO20") == "1";
            _supportSurroundConfiguration = !ch2 && TestSurroundSupport(AppleOutputModeSelector.FromEnvironment());
            if (ch2) Console.Error.WriteLine("[S2A 声音] 只报 2 声道（S2A_AUDIO_CH2 / STEREO）");
            if (solo || io20) S2AConfigureSession(solo, io20);

            Volume = 1f;
        }

        private static unsafe void S2AConfigureSession(bool solo, bool io20)
        {
            if (!(OperatingSystem.IsIOS() || OperatingSystem.IsTvOS()))   // 平台例外：tvOS 与 iOS 走同一分支
            {
                Console.Error.WriteLine("[S2A 声音] 非 iOS，不设音频会话");
                return;
            }

            try
            {
                NativeLibrary.Load("/System/Library/Frameworks/AVFAudio.framework/AVFAudio");
                nint objc = NativeLibrary.Load("/usr/lib/libobjc.A.dylib");
                var getClass = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "objc_getClass");
                var selReg = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "sel_registerName");
                nint send = NativeLibrary.GetExport(objc, "objc_msgSend");
                nint Sel(string n) { byte[] b = System.Text.Encoding.UTF8.GetBytes(n + "\0"); fixed (byte* p = b) return selReg(p); }
                nint Cls(string n) { byte[] b = System.Text.Encoding.UTF8.GetBytes(n + "\0"); fixed (byte* p = b) return getClass(p); }
                nint session = ((delegate* unmanaged<nint, nint, nint>)send)(Cls("AVAudioSession"), Sel("sharedInstance"));
                byte[] cat = System.Text.Encoding.UTF8.GetBytes("AVAudioSessionCategorySoloAmbient\0");
                nint catStr;
                fixed (byte* p = cat) catStr = ((delegate* unmanaged<nint, nint, byte*, nint>)send)(Cls("NSString"), Sel("stringWithUTF8String:"), p);
                nint err = 0;
                byte okCat = solo ? ((delegate* unmanaged<nint, nint, nint, nint*, byte>)send)(session, Sel("setCategory:error:"), catStr, &err) : (byte)2;
                byte okIo = io20 ? ((delegate* unmanaged<nint, nint, double, nint*, byte>)send)(session, Sel("setPreferredIOBufferDuration:error:"), 0.020, &err) : (byte)2;
                byte okAct = ((delegate* unmanaged<nint, nint, byte, nint*, byte>)send)(session, Sel("setActive:error:"), 1, &err);
                double io = ((delegate* unmanaged<nint, nint, double>)send)(session, Sel("IOBufferDuration"));
                double rate = ((delegate* unmanaged<nint, nint, double>)send)(session, Sel("sampleRate"));
                Console.Error.WriteLine($"[S2A 声音] 会话：SoloAmbient {okCat}、首选 IO 20 ms {okIo}（1 成功 0 失败 2 未设）、激活 {okAct}；实际 IO 缓冲 {io * 1000:F1} ms、采样率 {rate:F0}");
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[S2A 声音] 【红】音频会话设置失败：{e.Message}");
            }
        }

        // S2Arm (10-23 声音停了自愈): iOS 上重新激活音频会话（系统打断 / 路由切换后队列要在激活的会话上才能再开播）。
        //   AppleHardwareDeviceSession 的停播看门狗调；非 iOS 返回 true 不做事。objc 指针首次取后缓存，之后调用不分配
        private static nint _avSession, _selSetActive, _msgSend;

        internal unsafe bool S2AReactivateSession()
        {
            if (!(OperatingSystem.IsIOS() || OperatingSystem.IsTvOS()))   // 平台例外：tvOS 与 iOS 走同一分支
            {
                return true;
            }

            try
            {
                if (_avSession == 0)
                {
                    NativeLibrary.Load("/System/Library/Frameworks/AVFAudio.framework/AVFAudio");
                    nint objc = NativeLibrary.Load("/usr/lib/libobjc.A.dylib");
                    var getClass = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "objc_getClass");
                    var selReg = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "sel_registerName");
                    _msgSend = NativeLibrary.GetExport(objc, "objc_msgSend");
                    nint cls, selShared;

                    fixed (byte* p = "AVAudioSession\0"u8) cls = getClass(p);
                    fixed (byte* p = "sharedInstance\0"u8) selShared = selReg(p);
                    fixed (byte* p = "setActive:error:\0"u8) _selSetActive = selReg(p);

                    _avSession = ((delegate* unmanaged<nint, nint, nint>)_msgSend)(cls, selShared);
                }

                nint err = 0;

                return ((delegate* unmanaged<nint, nint, byte, nint*, byte>)_msgSend)(_avSession, _selSetActive, 1, &err) != 0;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[声] 【红】重新激活音频会话失败：{e.Message}");

                return false;
            }
        }

        // S2Arm（#189）：试建 6 声道队列的 callback 不能传 NULL——macOS 27 起 AudioQueueNewOutput 对 NULL callback
        //   直接回 -50（kAudio_ParamError），与声道数无关（2 声道 + NULL 对照同红、2 声道 + 真实 callback 回 0），
        //   8 声道 HDMI 设备也会因此只拿到 2 声道。空实现即可（队列不 Start，不会被调）；静态字段持住委托
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void ProbeCallback(nint userData, nint audioQueue, nint buffer);

        private static readonly ProbeCallback _probeCallback = static (_, _, _) => { };

        // S2Arm（#189 后续，5.1 虚拟环绕）：上报几声道按用户显式选择的设备类型（S2A_AUDIO_DEVICE）定——
        //   builtin / headphones（仅显式选择时）：对应 VS 开关开（S2A_AUDIO_VS_SPEAKERS / S2A_AUDIO_VS_HEADPHONES）
        //     才上报 6——让游戏出 5.1、折叠在会话侧（AUSM 显式输出类型，.auto 在 5.1 路径上三路由实测全退化为
        //     ExternalSpeakers 普通平移，见 docs/坑记录.md）；VS 关报 2，游戏按 2ch 渲染（TV Sound 2ch 下混）。
        //     不看物理设备：VS 开时物理设备可以只有 2 声道（真实折叠在会话侧），VS 关时物理 6 声道也按用户选择报 2。
        //   未显式选择（Auto）与 external：按设备真实输出声道数判（#577 判据——试建成功不等于设备真能出 5.1，
        //     2 声道内置扬声器上 6 声道队列照样试建成功，读 kAudioQueueDeviceProperty_NumberChannels，与 HAL
        //     一致：DisplayPort 显示器 6、内置扬声器 2）：≥6 直通、<6 报 2 下混，永不虚拟环绕。未显式选择走这支
        //     是保住 5.1 设备玩家的缺省直通（评审 11-16：缺省不能把接 HDMI / DisplayPort 5.1 的玩家降成立体声）。
        //     真 5.1 设备的运行期 6 声道队列声明布局在会话侧（AppleHardwareDeviceSession.CreateQueue）。
        //   例外：S2A_AUDIO_OUT=sys / matrix 显式下混（内部 A/B）照报 5.1——渲染器的回落下混不归一化（六路全
        //     0.9 折到 2.399、3484/4800 采样削波），显式下混让 6 声道混音进会话、由系统 AudioConverter 归一化折叠
        //     （不削波）；S2A_AUDIO_CH2 / STEREO 仍在构造函数里优先强制立体声
        private bool TestSurroundSupport(AppleOutputMode outMode)
        {
            if (outMode != AppleOutputMode.Native)
            {
                Console.Error.WriteLine($"[S2A 声音] S2A_AUDIO_OUT 显式下混（{AppleOutputModeSelector.ModeName(outMode)}）：照报 5.1，6 声道混音进会话、在会话侧折成立体声");
                return true;
            }

            AppleAudioDeviceType deviceType = AppleAudioDeviceTypeSelector.FromEnvironment();

            // 只有玩家显式选了 builtin / headphones 才跳过探测、按 VS 开关定上报；未选择 = 按设备自动，external 也按设备判
            if (deviceType is AppleAudioDeviceType.BuiltInSpeakers or AppleAudioDeviceType.Headphones)
            {
                bool vs = AppleAudioDeviceTypeSelector.VirtualSurround(deviceType);

                Console.Error.WriteLine($"[S2A 声音] 设备类型 {AppleAudioDeviceTypeSelector.DeviceName(deviceType)}：虚拟环绕 {(vs ? "开" : "关")} → 上报 {(vs ? "6 声道，5.1 混音进会话、AUSM 折成立体声" : "2 声道，游戏 / 渲染器按自己的系数下混")}");

                return vs;
            }

            return ProbeRealChannels(deviceType);
        }

        // 单测钩子（产品路径恒 null，只有 InternalsVisibleTo 的测试程序集碰得到）：注入只替换原生调用结果，
        //   队列 / 布局计数器由与产品路径同一段流程记录；测试先设它再构造驱动、测完清回 null。
        internal static (int QueueRc, uint Channels, int ChannelsRc, int LayoutRc)? S2ATestProbe;
        internal static int S2ATestProbeFirstQueueChannels;
        internal static int S2ATestProbeSurroundQueueChannels;
        internal static int S2ATestProbeLayoutCalls;

        internal static bool NeedsSurroundProbe(int queueRc, int channelsRc, uint channels) =>
            queueRc == 0 && channelsRc == 0 && channels >= 6;

        // 真实声道判据（#577）：Auto（未显式选择）与 external 共用。先用 2 声道队列只读设备声道数；
        //   只有设备确实 ≥6 声道才另建 6 声道队列验布局，避免在 2 声道设备上写 5.1 布局影响自动模式输出。
        private bool ProbeRealChannels(AppleAudioDeviceType deviceType)
        {
            string source = AppleAudioDeviceTypeSelector.DeviceName(deviceType);
            S2ATestProbeFirstQueueChannels = 0;
            S2ATestProbeSurroundQueueChannels = 0;
            S2ATestProbeLayoutCalls = 0;

            try
            {
                int queueRc;
                uint deviceChannels;
                int channelsResult;
                int layoutResult;
                nint testQueue = 0;
                var injected = S2ATestProbe;
                AudioStreamBasicDescription format =
                    GetAudioFormat(SampleFormat.PcmFloat, Constants.TargetSampleRate, 2);
                S2ATestProbeFirstQueueChannels = (int)format.ChannelsPerFrame;

                queueRc = injected.HasValue
                    ? injected.Value.QueueRc
                    : AudioQueueNewOutput(
                        ref format,
                        Marshal.GetFunctionPointerForDelegate(_probeCallback),
                        nint.Zero,
                        nint.Zero,
                        nint.Zero,
                        0,
                        out testQueue);

                deviceChannels = 0;
                channelsResult = -1;
                layoutResult = -1;

                if (queueRc == 0)
                {
                    if (injected.HasValue)
                    {
                        deviceChannels = injected.Value.Channels;
                        channelsResult = injected.Value.ChannelsRc;
                    }
                    else
                    {
                        uint size = sizeof(uint);
                        channelsResult = AudioQueueGetProperty(
                            testQueue,
                            kAudioQueueDeviceProperty_NumberChannels,
                            out deviceChannels,
                            ref size);
                        AudioQueueDispose(testQueue, true);
                    }
                }

                if (NeedsSurroundProbe(queueRc, channelsResult, deviceChannels))
                {
                    format = GetAudioFormat(SampleFormat.PcmFloat, Constants.TargetSampleRate, 6);
                    S2ATestProbeSurroundQueueChannels = (int)format.ChannelsPerFrame;
                    queueRc = injected.HasValue
                        ? injected.Value.QueueRc
                        : AudioQueueNewOutput(
                            ref format,
                            Marshal.GetFunctionPointerForDelegate(_probeCallback),
                            nint.Zero,
                            nint.Zero,
                            nint.Zero,
                            0,
                            out testQueue);

                    if (queueRc == 0)
                    {
                        AudioChannelLayout layout = new AudioChannelLayout
                        {
                            AudioChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A,
                            AudioChannelBitmap = 0,
                            NumberChannelDescriptions = 0
                        };

                        S2ATestProbeLayoutCalls = 1;
                        if (injected.HasValue)
                        {
                            layoutResult = injected.Value.LayoutRc;
                        }
                        else
                        {
                            layoutResult = AudioQueueSetProperty(
                                testQueue,
                                kAudioQueueProperty_ChannelLayout,
                                ref layout,
                                (uint)Marshal.SizeOf<AudioChannelLayout>());
                            AudioQueueDispose(testQueue, true);
                        }
                    }
                }

                if (queueRc != 0)
                {
                    Console.Error.WriteLine($"[S2A 声音] {source}：试建探测队列失败：{queueRc}（按立体声上报）");
                    return false;
                }

                if (channelsResult != 0)
                {
                    Console.Error.WriteLine($"[S2A 声音] {source}：【红】读输出设备声道数失败：{channelsResult}（按立体声上报）");
                    return false;
                }

                if (deviceChannels < 6)
                {
                    Console.Error.WriteLine($"[S2A 声音] {source}：输出设备 {deviceChannels} 声道：上报立体声，由游戏 / 渲染器按自己的系数下混（不建 6 声道队列、不写 5.1 布局）");
                    return false;
                }

                if (layoutResult == 0)
                {
                    Console.Error.WriteLine($"[S2A 声音] {source}：输出设备 {deviceChannels} 声道：上报 5.1，运行期 6 声道会话声明 MPEG_5_1_A 布局");
                    return true;
                }

                Console.Error.WriteLine($"[S2A 声音] {source}：输出设备 {deviceChannels} 声道：5.1 布局设置 rc={layoutResult}（按立体声上报）");
                return false;
            }
            catch
            {
                return false;
            }
        }

        public static bool IsSupported => OperatingSystem.IsMacOSVersionAtLeast(10, 5) || (OperatingSystem.IsIOS() || OperatingSystem.IsTvOS());   // 平台例外：tvOS 与 iOS 走同一分支

        public ManualResetEvent GetUpdateRequiredEvent()
            => _updateRequiredEvent;

        public ManualResetEvent GetPauseEvent()
            => _pauseEvent;

        public IHardwareDeviceSession OpenDeviceSession(Direction direction, IVirtualMemoryManager memoryManager,
            SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            lock (_sessionLock)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                if (channelCount == 0)
                {
                    channelCount = 2;
                }

                if (sampleRate == 0)
                {
                    sampleRate = Constants.TargetSampleRate;
                }

                // S2Arm（#2151）：收音（Switch 2 外部输入流 / audin:u）：AudioQueue 输入，Mac 与 iOS 同一份
                if (direction == Direction.Input)
                {
                    return new AppleHardwareDeviceSessionInput(this, memoryManager, sampleFormat, sampleRate, channelCount);   // 平台例外：Apple 后端平台实现（收音会话，#2151）
                }

                AppleHardwareDeviceSession session = new(this, memoryManager, sampleFormat, sampleRate, channelCount);

                _sessions.TryAdd(session, 0);

                return session;
            }
        }

        internal bool Unregister(AppleHardwareDeviceSession session)
            => _sessions.TryRemove(session, out _);

        internal static AudioStreamBasicDescription GetAudioFormat(SampleFormat sampleFormat, uint sampleRate,
            uint channelCount)
        {
            uint formatFlags;
            uint bitsPerChannel;

            switch (sampleFormat)
            {
                case SampleFormat.PcmInt8:
                    formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 8;
                    break;
                case SampleFormat.PcmInt16:
                    formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 16;
                    break;
                case SampleFormat.PcmInt32:
                    formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 32;
                    break;
                case SampleFormat.PcmFloat:
                    formatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 32;
                    break;
                default:
                    throw new ArgumentException($"Unsupported sample format {sampleFormat}");
            }

            uint bytesPerFrame = (bitsPerChannel / 8) * channelCount;

            return new AudioStreamBasicDescription
            {
                SampleRate = sampleRate,
                FormatID = kAudioFormatLinearPCM,
                FormatFlags = formatFlags,
                BytesPerPacket = bytesPerFrame,
                FramesPerPacket = 1,
                BytesPerFrame = bytesPerFrame,
                ChannelsPerFrame = channelCount,
                BitsPerChannel = bitsPerChannel,
                Reserved = 0
            };
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        private void Dispose(bool disposing)
        {
            if (disposing)
            {
                lock (_sessionLock)
                {
                    if (_disposed) return;
                    bool paceAlive = false;
                    foreach (AppleHardwareDeviceSession session in _sessions.Keys)
                    {
                        session.Dispose();
                        paceAlive |= session.S2APaceThreadAlive;
                    }

                    // S2Arm (11-19): a session whose pace thread is still stuck in a hung game's buffer stays registered after its own
                    //   Dispose and may Set these events when it comes back; disposing them here made that Set throw ObjectDisposedException
                    //   on a background thread and abort the process. Keep them then (the GC collects them after the thread leaves).
                    if (!paceAlive)
                    {
                        _updateRequiredEvent.Dispose();
                        _pauseEvent.Dispose();
                    }

                    _disposed = true;
                }
            }
        }

        public bool SupportsDirection(Direction direction)
            => direction is Direction.Input or Direction.Output;

        public bool SupportsSampleRate(uint sampleRate) => true;

        public bool SupportsSampleFormat(SampleFormat sampleFormat)
            => sampleFormat != SampleFormat.PcmInt24;

        public bool SupportsChannelCount(uint channelCount)
            => channelCount != 6 || _supportSurroundConfiguration;

        // S2Arm（#189 后续，5.1 虚拟环绕第二片）：游戏看到的 active device 名字按玩家显式选择的设备类型定（VirtualDeviceSessionRegistry）：
        //   builtin → AudioBuiltInSpeakerOutput、headphones → AudioStereoJackOutput（USB / 蓝牙耳机选 Headphones 也报 StereoJack——
        //   设备类型语义的简化，不逐设备另报真实接口名）；未显式选择（Auto）与 external 不给名字 → 缺省 AudioTvOutput（缺省路径
        //   逐字节不变）。声道数不走这里：照旧看 SupportsChannelCount(6)（显式类型 + 虚拟环绕开时报 6，关时报 2）
        public string? S2AActiveDeviceName()
        {
            return AppleAudioDeviceTypeSelector.FromEnvironment() switch
            {
                AppleAudioDeviceType.BuiltInSpeakers => "AudioBuiltInSpeakerOutput",
                AppleAudioDeviceType.Headphones => "AudioStereoJackOutput",
                _ => null,
            };
        }
    }
}
