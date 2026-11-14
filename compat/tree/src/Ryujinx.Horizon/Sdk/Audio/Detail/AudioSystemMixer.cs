using Ryujinx.Audio;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Output;
using Ryujinx.Common;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Applet;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Ryujinx.Horizon.Sdk.Audio.Detail
{
    // S2Arm：Switch 2 的 audsmx:u（nn::audio::sysmix，系统混音器的外部流）。上游 Ryujinx 没有它，形状与语义从游戏自带 sdk 的客户端反推
    //   （时之笛 sdk：sysmix::detail::*Impl + CmifProxy 虚表 0xe63098 / 0xe631a0 / 0xe632b8 + 组包函数，见 compat/改动清单.md 本条）。
    //   nn::audio::OutputStreamImpl::Open = devmgr 300 / 401 → sysmix CreateStream → OpenStream →（有事件时）AcquireStreamDataEvent；
    //   Start / Stop = devmgr 700 AttachStream / 800 DetachStream（AudioDeviceManager.cs）；Close = ReleaseStreamDataEvent → CloseStream → 销毁对象。
    //   客户端连上就转域（CmifDomainProxyKind），所以本服务所在的服务器要开域（AudioUserIpcServer.cs）。
    //   声音数据不走 IPC：客户端把游戏给的工作缓冲排成「控制块 + 环形缓冲」，WriteOutputStream 只往环里抄样本、推写指针；
    //   服务端从同一块游戏内存读、推读指针（ExternalOutputStream）。
    //   只实现输出流开局路径要的命令；其余命令不进命令表（按未知命令报红），已实现的命令遇到 SDK 输出路径从不发的取值也报红，不回成功兜底。

    // nn::audio::StreamFormat（12 字节）：+0 采样格式（1..5，与 Ryujinx SampleFormat 同号）、+4 声道数、+8 采样率。
    //   依据：sysmix::detail::OpenStreamImpl 拿 +0 减 1 查每样本字节表 {1,2,4,4,4}、+4 乘进帧长；OutputStreamImpl::Open 拿 +8 × 设备延迟 ÷ 1e9 算最少帧数
    [StructLayout(LayoutKind.Sequential, Size = 0xC, Pack = 4)]
    struct StreamFormat
    {
        public uint SampleFormat;
        public int ChannelCount;
        public int SampleRate;

        public override readonly string ToString() => $"格式 {SampleFormat}、{ChannelCount} 声道、{SampleRate} Hz";
    }

    // devmgr 与 sysmix 共用的流登记：sysmix CreateStream 发流号，devmgr 700 / 800 按流号挂上 / 摘下虚拟设备
    sealed class ExternalStreamRegistry
    {
        private readonly Lock _lock = new();
        private readonly Dictionary<uint, ExternalOutputStream> _streams = new();
        private uint _nextId;

        public AudioOutputManager OutputManager { get; }

        public ExternalStreamRegistry(AudioOutputManager outputManager)
        {
            OutputManager = outputManager;
        }

        public uint Add(ExternalOutputStream stream)
        {
            lock (_lock)
            {
                uint id = ++_nextId;
                _streams.Add(id, stream);
                return id;
            }
        }

        public void Remove(uint id)
        {
            lock (_lock)
            {
                _streams.Remove(id);
            }
        }

        public ExternalOutputStream Get(uint id)
        {
            lock (_lock)
            {
                return _streams.GetValueOrDefault(id);
            }
        }
    }

    // 一条外部输出流的服务端：读游戏工作缓冲里的环，按块交给宿主声音输出（AudioOutputSystem，同 audout:u 用的会话），宿主播完交还才推读指针。
    //   工作缓冲布局（sysmix::detail 0x2b38d0 / 0x2b3c00 / GetStreamFreeFrameCountImpl 反推；B = 缓冲起点，页对齐）：
    //     B+0x0000 控制块 1（0x40 字节；客户端初始化时写 +0 字节 = 1，语义不知道，服务端不碰）
    //     B+0x0040 控制块 2（服务端的）：+4 = 读指针（帧号，0 ≤ 读 < 容量）；+0 客户端统计时取差值累加（语义不知道，服务端不写）
    //     B+0x1000 控制块 3（客户端的）：+4 = 写指针；+0 = 写不下丢掉的帧数（客户端自己累加）
    //     B+0x1040 环：容量 = OpenStream 的帧数 + 1 帧，帧长 = 每样本字节 × 声道数，交错存放
    //   （OpenStream 标志位 0 置位时环前还有 0x80 字节的时间戳表、写入走另一套带时间戳的协议，本实现不支持、报红）
    //   可写帧数 = 容量 − 1 − ((写 − 读) mod 容量)：读指针只在宿主交还（播完）后推进，游戏不会改写还在宿主手里的样本。
    sealed class ExternalOutputStream : IDisposable
    {
        public const ulong ServerBlockOffset = 0x40;
        public const ulong ClientBlockOffset = 0x1000;
        public const ulong RingOffset = 0x1040;
        public const ulong IndexOffset = 4;

        // 服务端搬运周期：每 5 ms 收一次宿主交还、交一次新样本（Switch 硬件一次取 240 帧 = 5 ms）。
        //   devmgr 401 回的设备延迟 = 2 个周期：交样本与收交还各最多晚一个周期，游戏缓冲短于它必断（OutputStreamImpl::Open 按它拒绝过短的缓冲）
        public const int PumpPeriodMs = 5;
        public const ulong MinimumLatencyNs = 2 * PumpPeriodMs * 1_000_000UL;

        private readonly Lock _lock = new();
        private readonly AudioOutputManager _outputManager;
        private readonly IVirtualMemoryManager _memory;
        private readonly Queue<(ulong Tag, int Frames)> _inFlight = new();
        private readonly ulong[] _released = new ulong[Constants.AudioDeviceBufferCountMax];

        private AudioOutputSystem _output;
        private int _capacity;
        private int _frameBytes;
        private int _chunkFrames;
        private int _read;
        private int _queued;
        private ulong _tag;
        private bool _attached;
        private bool _broken;
        private Thread _pump;
        private volatile bool _stopPump;

        public ulong Buffer { get; }
        public ulong Size { get; }
        public string Name { get; }
        public bool IsOpen => _output != null;
        public bool IsAttached => _attached;

        // 数据事件（AcquireStreamDataEvent 领走）：服务端每次推进读指针就触发
        public AudioEvent DataEvent { get; set; }

        public ExternalOutputStream(AudioOutputManager outputManager, IVirtualMemoryManager memory, ulong buffer, ulong size, string name)
        {
            _outputManager = outputManager;
            _memory = memory;
            Buffer = buffer;
            Size = size;
            Name = name;
        }

        // 宿主声音输出能直接播的格式：PcmInt16、48000 Hz、立体声或 5.1（AudioOutputSystem 只收这些；单声道会被它当立体声，不收）
        public static bool IsHostSupported(StreamFormat format)
        {
            return format.SampleFormat == (uint)SampleFormat.PcmInt16 && format.SampleRate == Constants.TargetSampleRate && format.ChannelCount is 2 or 6;
        }

        public void Open(StreamFormat format, int frameCount)
        {
            if (!IsHostSupported(format))
            {
                throw new NotImplementedException($"audsmx:u IExternalStreamSession 0：{format}（宿主声音输出只播 PcmInt16 / 48000 Hz / 2 或 6 声道）");
            }

            int frameBytes = 2 * format.ChannelCount;
            ulong ringEnd = RingOffset + (ulong)(frameCount + 1) * (ulong)frameBytes;

            if (frameCount < 1 || (Buffer & 0xFFF) != 0 || ringEnd > Size)
            {
                throw new NotImplementedException($"audsmx:u IExternalStreamSession 0：{frameCount} 帧的环放不进工作缓冲 0x{Buffer:X} + 0x{Size:X}（客户端自己会先拒绝，到这里说明布局没对上）");
            }

            AudioInputConfiguration configuration = new() { SampleRate = (uint)format.SampleRate, ChannelCount = (ushort)format.ChannelCount };

            ResultCode rc = _outputManager.OpenAudioOut(out _, out _, out AudioOutputSystem output, _memory, string.Empty, SampleFormat.PcmInt16, ref configuration);

            if (rc != ResultCode.Success)
            {
                throw new NotImplementedException($"audsmx:u IExternalStreamSession 0：宿主声音输出打不开（{rc}），不知道真机此时回哪个结果码");
            }

            lock (_lock)
            {
                _output = output;
                _capacity = frameCount + 1;
                _frameBytes = frameBytes;
                _chunkFrames = format.SampleRate * PumpPeriodMs / 1000;
                _read = 0;
                _queued = 0;
            }
        }

        public void Attach()
        {
            lock (_lock)
            {
                _queued = _read;
                _broken = false;
                _output.Start();
                _attached = true;
            }

            _stopPump = false;
            _pump = new Thread(PumpLoop) { Name = "S2A.audsmx.Pump", IsBackground = true };
            _pump.Start();
        }

        public void Detach()
        {
            _stopPump = true;
            _pump?.Join();
            _pump = null;

            lock (_lock)
            {
                if (!_attached)
                {
                    return;
                }

                CollectReleased();
                // 还在宿主手里没播完的块作废：读指针停在已播完处，下次挂上从那里重交
                _output.FlushBuffers();
                _output.Stop();
                _output.GetReleasedBuffer(_released, out _);
                _inFlight.Clear();
                _queued = _read;
                _attached = false;
            }
        }

        private void PumpLoop()
        {
            // S2Arm：与 audren 驱动线程同一套（AudioRendererManager.SendCommands、AudioProcessor.Work）：本线程每 5 ms 交一次样本、
            //   收一次交还，实时调度（超计算预算被内核降级；S2A_AUDIO_SCHED=utility / interactive 只设 QoS）；
            //   周期尾睡到绝对时限（Apple 上一次内核唤醒，mach_wait_until）替代 Thread.Sleep。原先普通线程（QoS 缺省）
            //   负载下几十 ms 才被调度一次（10-22 audren 实测：交接等调度每周期超期 27–34 ms、整批丢周期出杂音，见 S2ARealtime）；
            //   5 ms 网格只需平均守住：个别超期由游戏环（打开时须长于设备延迟 = 2 周期）+ 会话在途深度吸收
            long periodNs = PumpPeriodMs * 1_000_000L;
            Ryujinx.Common.S2ARealtime.Promote("audsmx 搬运线程", periodNs, periodNs / 2, periodNs);

            long next = PerformanceCounter.ElapsedNanoseconds;

            while (!_stopPump)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("audsmx 搬运"); // S2Arm: per-thread allocation accounting

                Pump();

                // 睡到本周期结束（绝对时限：网格不随每圈搬运工作量与调度延迟漂移）；错过周期就重锚网格——
                //   下一圈 Pump 本就把环里积攒的样本收拢成块一次交出，不连发补泵
                next += periodNs;
                long now = PerformanceCounter.ElapsedNanoseconds;

                if (now < next)
                {
                    Ryujinx.Common.PreciseSleep.PreciseSleepHelper.SleepUntilTimePointSingleWake(
                        PerformanceCounter.ElapsedTicks + (next - now) * PerformanceCounter.TicksPerMillisecond / 1_000_000);
                }
                else
                {
                    next = now;
                }
            }
        }

        // 一轮搬运：收宿主交还的块 → 推读指针、触发数据事件；读写指针 → 新写的样本按块交宿主
        public void Pump()
        {
            lock (_lock)
            {
                if (!_attached || _broken)
                {
                    return;
                }

                CollectReleased();

                uint write = _memory.Read<uint>(Buffer + ClientBlockOffset + IndexOffset);

                if (write >= (uint)_capacity)
                {
                    _broken = true;
                    Console.Error.WriteLine($"[声] 【红】audsmx:u 外部流「{Name}」：写指针 {write} 不在环里（容量 {_capacity} 帧），停止搬运");
                    return;
                }

                int available = ((int)write - _queued + _capacity) % _capacity;

                while (available > 0 && _inFlight.Count < _released.Length)
                {
                    int frames = Math.Min(Math.Min(available, _capacity - _queued), _chunkFrames);
                    AudioUserBuffer buffer = new()
                    {
                        Data = Buffer + RingOffset + (ulong)_queued * (ulong)_frameBytes,
                        DataSize = (ulong)frames * (ulong)_frameBytes,
                    };
                    buffer.Capacity = buffer.DataSize;

                    if (_output.AppendBuffer(++_tag, ref buffer) != ResultCode.Success)
                    {
                        break;
                    }

                    _inFlight.Enqueue((_tag, frames));
                    _queued = (_queued + frames) % _capacity;
                    available -= frames;
                }
            }
        }

        private void CollectReleased()
        {
            _output.GetReleasedBuffer(_released, out uint count);

            int frames = 0;

            for (int i = 0; i < count; i++)
            {
                if (!_inFlight.TryDequeue(out (ulong Tag, int Frames) block) || block.Tag != _released[i])
                {
                    _broken = true;
                    Console.Error.WriteLine($"[声] 【红】audsmx:u 外部流「{Name}」：宿主交还的块 {_released[i]} 不是最早交出的那块，停止搬运");
                    return;
                }

                frames += block.Frames;
            }

            if (frames > 0)
            {
                _read = (_read + frames) % _capacity;
                _memory.Write(Buffer + ServerBlockOffset + IndexOffset, (uint)_read);
                DataEvent?.Signal();
            }
        }

        public void Close()
        {
            Detach();

            lock (_lock)
            {
                _output?.Dispose();
                _output = null;
            }
        }

        public void Dispose()
        {
            Close();
        }
    }

    partial class AudioSystemMixerUserSessionManager : IServiceObject
    {
        private readonly ExternalStreamRegistry _registry;

        public AudioSystemMixerUserSessionManager(ExternalStreamRegistry registry)
        {
            _registry = registry;
        }

        // IUserSessionManager 0：带 pid、复制句柄 1 个（客户端本进程句柄，nn::dd::GetCurrentProcessHandle）、in u32 @0、u64 @8；回 IUserSession（域对象）。
        //   SDK 的 sysmix::detail::InitializeImpl 只发「u32 = 1、u64 = 0」，两者语义不知道，别的取值报红。
        //   进程句柄用来读写游戏工作缓冲（外部流的环在游戏内存里）
        [CmifCommand(0)]
        public Result OpenUserSession(out AudioSystemMixerUserSession session, [CopyHandle] int processHandle, uint kind, ulong reserved, [ClientProcessId] ulong pid)
        {
            if (kind != 1 || reserved != 0)
            {
                HorizonStatic.Syscall.CloseHandle(processHandle);

                throw new NotImplementedException($"audsmx:u IUserSessionManager 0：u32 {kind}、u64 0x{reserved:X}（SDK 只发 1、0，别的语义不知道）");
            }

            IVirtualMemoryManager memory = HorizonStatic.Syscall.GetMemoryManagerByProcessHandle(processHandle);

            session = new AudioSystemMixerUserSession(_registry, memory, processHandle);

            return Result.Success;
        }
    }

    partial class AudioSystemMixerUserSession : IServiceObject, IDisposable
    {
        // CreateStream 的标志：低 3 位 = 4 是「客户端写、服务端读」的输出流（客户端 WriteStreamImpl 要求 (标志 & 7) == 4）；
        //   0x20：OutputStreamImpl::Open 在声道数 < 6 或 OutputStreamFlag 位 0 置位时带上，语义不知道（本实现不因它改变行为）；
        //   0x40 / 0x80 来自 OutputStreamFlag 位 1 / 位 16，语义不知道 → 报红。时之笛两处开流（音频框架、动画播放）都是 0x24
        private const uint FlagClientWrites = 0x4;
        private const uint FlagKnownMask = 0x24;

        private readonly ExternalStreamRegistry _registry;
        private readonly IVirtualMemoryManager _memory;
        private int _processHandle;

        public AudioSystemMixerUserSession(ExternalStreamRegistry registry, IVirtualMemoryManager memory, int processHandle)
        {
            _registry = registry;
            _memory = memory;
            _processHandle = processHandle;
        }

        // 1 CreateStream：A 缓冲（流名，长度 = 字符串长）；带 pid；in u32 设备 @0（devmgr 401 回的档案 +0x220）、u32 标志 @4、aruid @8、
        //   u64 工作缓冲地址 @0x10、u64 长度 @0x18；回 u32 流号 @0（devmgr 700 / 800 用）+ IExternalStreamSession（域对象）
        [CmifCommand(1)]
        public Result CreateStream(
            out uint streamId,
            out AudioSystemMixerExternalStreamSession stream,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> name,
            uint device,
            uint flags,
            AppletResourceUserId appletResourceId,
            ulong buffer,
            ulong size,
            [ClientProcessId] ulong pid)
        {
            if (device != AudioDeviceManagerUserSession.VirtualOutputDeviceToken)
            {
                throw new NotImplementedException($"audsmx:u IUserSession 1：设备 {device} 不是 devmgr 401 回给客户端的本机虚拟输出设备");
            }

            if ((flags & 7) != FlagClientWrites || (flags & ~FlagKnownMask) != 0)
            {
                throw new NotImplementedException($"audsmx:u IUserSession 1：标志 0x{flags:X}（只认输出流 0x4 / 0x24，其余位语义不知道）");
            }

            int length = name.IndexOf((byte)0);
            ExternalOutputStream impl = new(_registry.OutputManager, _memory, buffer, size, Encoding.ASCII.GetString(length < 0 ? name : name[..length]));

            streamId = _registry.Add(impl);
            stream = new AudioSystemMixerExternalStreamSession(_registry, streamId, impl);

            return Result.Success;
        }

        public void Dispose()
        {
            if (_processHandle != 0)
            {
                HorizonStatic.Syscall.CloseHandle(_processHandle);
                _processHandle = 0;
            }
        }
    }

    partial class AudioSystemMixerExternalStreamSession : IServiceObject, IDisposable
    {
        // AcquireStreamDataEvent 的通知方式：输出流 / 输入流 / 注入都发 2，OutputRecorder 发 1
        private const uint NotificationModeOutput = 2;

        private readonly ExternalStreamRegistry _registry;
        private readonly uint _id;
        private readonly ExternalOutputStream _impl;
        private bool _disposed;

        public AudioSystemMixerExternalStreamSession(ExternalStreamRegistry registry, uint id, ExternalOutputStream impl)
        {
            _registry = registry;
            _id = id;
            _impl = impl;
        }

        // 0 OpenStream：in StreamFormat @0、s32 帧数 @0xc（环容量 − 1）、s32 @0x10（客户端拿它当写指针初值，输出流恒 0）、u32 标志 @0x14；只回结果码
        [CmifCommand(0)]
        public Result OpenStream(StreamFormat format, int frameCount, int initialWriteIndex, uint flags)
        {
            if (initialWriteIndex != 0 || flags != 0)
            {
                throw new NotImplementedException($"audsmx:u IExternalStreamSession 0：写指针初值 {initialWriteIndex}、标志 0x{flags:X}（输出流只发 0、0；标志位 0 = 带时间戳表的另一套环协议，没实现）");
            }

            if (_impl.IsOpen)
            {
                throw new NotImplementedException("audsmx:u IExternalStreamSession 0：流已打开又打开（不知道真机回哪个结果码）");
            }

            _impl.Open(format, frameCount);

            return Result.Success;
        }

        // 1 CloseStream：无入参，只回结果码（客户端先 devmgr 800 摘下再关）
        [CmifCommand(1)]
        public Result CloseStream()
        {
            if (!_impl.IsOpen || _impl.IsAttached)
            {
                throw new NotImplementedException($"audsmx:u IExternalStreamSession 1：流{(_impl.IsOpen ? "还挂在设备上" : "没打开")}就关（不知道真机回哪个结果码）");
            }

            _impl.Close();

            return Result.Success;
        }

        // 7 AcquireStreamDataEvent：in u32 通知方式 @0、s32 @4（OutputStreamImpl::Open 传游戏给的第 2 个帧数，游戏都给「缓冲帧数 − 1~5 ms」）；回复制句柄 1 个。
        //   方式 2 的确切触发条件不知道（可写帧数到阈值？每消费阈值帧？）。本实现：服务端每推进一次读指针就触发——是任一种真机条件的超集：
        //   等它的游戏（时之笛音频框架线程无超时 WaitSystemEvent 后查可写帧数）只会多醒、不会少醒。别的方式报红
        [CmifCommand(7)]
        public Result AcquireStreamDataEvent([CopyHandle] out int eventHandle, uint mode, int threshold)
        {
            if (mode != NotificationModeOutput || !_impl.IsOpen || _impl.DataEvent != null)
            {
                throw new NotImplementedException($"audsmx:u IExternalStreamSession 7：方式 {mode}、阈值 {threshold}、流{(_impl.IsOpen ? "" : "没")}打开、{(_impl.DataEvent != null ? "已领过事件" : "未领事件")}（只实现输出流的方式 2）");
            }

            _impl.DataEvent = new AudioEvent();
            eventHandle = _impl.DataEvent.GetReadableHandle();

            return Result.Success;
        }

        // 8 ReleaseStreamDataEvent：无入参，只回结果码
        [CmifCommand(8)]
        public Result ReleaseStreamDataEvent()
        {
            if (_impl.DataEvent == null || _impl.IsAttached)
            {
                throw new NotImplementedException($"audsmx:u IExternalStreamSession 8：{(_impl.DataEvent == null ? "没领过事件" : "流还挂在设备上")}");
            }

            AudioEvent dataEvent = _impl.DataEvent;
            _impl.DataEvent = null;
            dataEvent.Dispose();

            return Result.Success;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _registry.Remove(_id);
            _impl.Dispose();
            _impl.DataEvent?.Dispose();
            _impl.DataEvent = null;
        }
    }
}
