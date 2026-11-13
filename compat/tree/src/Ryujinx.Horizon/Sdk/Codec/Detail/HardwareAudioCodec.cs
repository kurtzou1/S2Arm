using Ryujinx.Common.Logging;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.OsTypes;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using Ryujinx.Memory;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Ryujinx.Horizon.Sdk.Codec.Detail
{
    // S2Arm：Switch 2 的硬件音频编解码会话 hwacod（hwopus #100 取得），Opus 解码交给 ADSP。
    //   协议从游戏自带、带符号的 sdk 模块（nn::codec::hwacod::shim）反汇编得出，社区实现只当线索：
    //   - IClientSession #2 / #3 回实例 / ADSP 管理器的工作区大小（#0 / #1 是不带末尾版本号 u32 的旧形），#11 开管理会话（#10 是不带属性位、不递 pid 的旧形）：
    //     入 0x60 字节共享内存参数（WorkBufferSizeCalculator::GetSharedMemoryParameter）+ 传输内存大小 + 客户端工作区地址 / 大小，
    //     复制句柄 2 个（传输内存、客户端进程）；出 u32 会话令牌、管理会话对象、复制句柄 1 个（完成事件）。
    //   - 管理会话 #0 建实例（u32 实例号 + X 缓冲 0x120 字节参数），#1 销毁实例，#10 递一批 16 字节任务（AutoSelect 缓冲）。
    //   - 工作区 = 客户端进程内存：IO 缓冲区（第 i 块输入在 i × (输入 + 输出)，输出紧跟输入）+ 完成环（头 0x80：服务端写序号 +4、客户端读序号 +0x44；
    //     条目 0x40 字节、共 IO 块数 + 1 条）。服务端按任务解码、写输出与完成条目、推进写序号，最后亮完成事件；客户端 UpdateProcessResult 收。
    //   - 传输内存是 ADSP 自己的状态区，这里解码在宿主做，不碰它（只持有句柄、会话关时关）。
    [StructLayout(LayoutKind.Sequential, Size = 0x8)]
    struct HardwareAudioCodecRegion
    {
        public uint Size;
        public uint Offset;
    }

    // WorkBufferSizeCalculator::GetSharedMemoryParameter 的 0x60 字节（版本 1）
    [StructLayout(LayoutKind.Sequential, Size = 0x60)]
    struct HardwareAudioCodecSharedMemoryParameter
    {
        public uint Version;
        public HardwareAudioCodecRegion AdspManager;    // 以下三段在传输内存里
        public HardwareAudioCodecRegion Instances;
        public HardwareAudioCodecRegion AdspRing;
        public uint TransferMemorySize;
        public HardwareAudioCodecRegion IoBuffers;      // 以下两段在客户端工作区里
        public HardwareAudioCodecRegion ResultRing;
        public uint WorkAreaSize;
        public uint InstanceSize;
        public uint InstanceCount;
        public uint IoInputSize;
        public uint IoOutputSize;
        public uint IoBufferCount;
    }

    // IClientSession #11 的入参（CMIF 数据区 0x90 字节）
    [StructLayout(LayoutKind.Sequential, Size = 0x90)]
    struct HardwareAudioCodecOpenArgs
    {
        public HardwareAudioCodecSharedMemoryParameter Shared;
        public uint Version;                             // SDK 填 1
        public uint Padding;
        public ulong TransferMemorySize;
        public ulong WorkAreaAddress;
        public ulong WorkAreaSize;
        public ulong Properties;                         // HardwareAudioCodecManagerProperty 位
        public ulong Reserved;
    }

    // IClientSession #10 的入参（旧形，CMIF 数据区 0x80 字节）
    [StructLayout(LayoutKind.Sequential, Size = 0x80)]
    struct HardwareAudioCodecOpenArgsOld
    {
        public HardwareAudioCodecSharedMemoryParameter Shared;
        public ulong TransferMemorySize;
        public ulong WorkAreaAddress;
        public ulong WorkAreaSize;
        public ulong Reserved;
    }

    // 实例参数（0x120 字节）：variant 下标 0 = Stub、1 = Opus、2 = Opus 多流、3 = 空；之后是参数体
    [StructLayout(LayoutKind.Sequential, Size = 0x120)]
    unsafe struct HardwareAudioCodecParameter
    {
        public ulong Kind;
        public int SampleRate;
        public int ChannelCount;
        public long FrameDurationNs;
        public int TotalStreamCount;
        public int StereoStreamCount;
        public fixed byte ChannelMappings[0x100];
    }

    // 管理会话 #10 的一条任务（TaskProducer::RegisterTask / CreateHeader）
    [StructLayout(LayoutKind.Sequential, Size = 0x10)]
    struct HardwareAudioCodecTask
    {
        public ushort Token;
        public ushort Instance;
        public ushort IoBuffer;
        public ushort Sequence;
        public uint InputSize;
        public byte Reset;
        public byte Last;                                // 一批的最后一条（Execute 置 1）
        public ushort Padding;
    }

    // 完成环的一条（HardwareAudioCodecManager::UpdateProcessResult 读 +2 +4 +8 +0x10 +0x14）
    [StructLayout(LayoutKind.Sequential, Size = 0x40)]
    struct HardwareAudioCodecResult
    {
        public ushort Token;
        public ushort Instance;
        public ushort IoBuffer;
        public ushort Sequence;
        public long ProcessingTimeNs;
        public uint OutputSize;
        public uint Result;
    }

    interface IHardwareAudioCodecClientSession : IServiceObject
    {
        Result GetInstanceWorkBufferSizeOld(out uint size, in HardwareAudioCodecParameter parameter);
        Result GetAdspManagerWorkBufferSizeOld(out uint size, uint ioBufferCount);
        Result GetInstanceWorkBufferSize(out uint size, in HardwareAudioCodecParameter parameter, uint version);
        Result GetAdspManagerWorkBufferSize(out uint size, uint ioBufferCount, uint version);
        Result OpenManagerOld(out uint token, out IHardwareAudioCodecManagerSession manager, out int eventHandle, HardwareAudioCodecOpenArgsOld args, int transferMemoryHandle, int processHandle);
        Result OpenManager(out uint token, out IHardwareAudioCodecManagerSession manager, out int eventHandle, HardwareAudioCodecOpenArgs args, int transferMemoryHandle, int processHandle, ulong pid);
    }

    interface IHardwareAudioCodecManagerSession : IServiceObject
    {
        Result CreateInstance(uint instance, in HardwareAudioCodecParameter parameter);
        Result DestroyInstance(uint instance);
        Result Execute(ReadOnlySpan<HardwareAudioCodecTask> tasks);
    }

    partial class HardwareAudioCodecClientSession : IHardwareAudioCodecClientSession
    {
        // 这两块大小只决定客户端给 ADSP 留多大传输内存，宿主解码不用它：取一页，与参数无关（CanInstantiate 按管理器开时的大小比，不会因参数不同而判不下）
        internal const uint InstanceWorkBufferSize = 0x1000;
        internal const uint AdspManagerWorkBufferSize = 0x1000;

        private static int s_token;

        [CmifCommand(0)]
        public Result GetInstanceWorkBufferSizeOld(out uint size, [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x120)] in HardwareAudioCodecParameter parameter)
        {
            size = InstanceWorkBufferSize;

            return Result.Success;
        }

        [CmifCommand(1)]
        public Result GetAdspManagerWorkBufferSizeOld(out uint size, uint ioBufferCount)
        {
            size = AdspManagerWorkBufferSize;

            return Result.Success;
        }

        [CmifCommand(2)]
        public Result GetInstanceWorkBufferSize(out uint size, [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x120)] in HardwareAudioCodecParameter parameter, uint version)
        {
            size = InstanceWorkBufferSize;

            return Result.Success;
        }

        [CmifCommand(3)]
        public Result GetAdspManagerWorkBufferSize(out uint size, uint ioBufferCount, uint version)
        {
            size = AdspManagerWorkBufferSize;

            return Result.Success;
        }

        [CmifCommand(10)]
        public Result OpenManagerOld(
            out uint token,
            out IHardwareAudioCodecManagerSession manager,
            [CopyHandle] out int eventHandle,
            HardwareAudioCodecOpenArgsOld args,
            [CopyHandle] int transferMemoryHandle,
            [CopyHandle] int processHandle)
        {
            return Open(out token, out manager, out eventHandle, in args.Shared, args.WorkAreaAddress, args.WorkAreaSize, transferMemoryHandle, processHandle);
        }

        [CmifCommand(11)]
        public Result OpenManager(
            out uint token,
            out IHardwareAudioCodecManagerSession manager,
            [CopyHandle] out int eventHandle,
            HardwareAudioCodecOpenArgs args,
            [CopyHandle] int transferMemoryHandle,
            [CopyHandle] int processHandle,
            [ClientProcessId] ulong pid)
        {
            return Open(out token, out manager, out eventHandle, in args.Shared, args.WorkAreaAddress, args.WorkAreaSize, transferMemoryHandle, processHandle);
        }

        private static Result Open(
            out uint token,
            out IHardwareAudioCodecManagerSession manager,
            out int eventHandle,
            in HardwareAudioCodecSharedMemoryParameter shared,
            ulong workAreaAddress,
            ulong workAreaSize,
            int transferMemoryHandle,
            int processHandle)
        {
            IVirtualMemoryManager memory = HorizonStatic.Syscall.GetMemoryManagerByProcessHandle(processHandle);
            ulong ringEnd = (ulong)shared.ResultRing.Offset + 0x80 + ((ulong)shared.IoBufferCount + 1) * 0x40;
            ulong ioEnd = (ulong)shared.IoBuffers.Offset + (ulong)shared.IoBufferCount * ((ulong)shared.IoInputSize + shared.IoOutputSize);

            // 布局越出客户端交来的工作区 = 参数版本或布局与这份实现对不上：回参数错误、句柄关掉，不去写游戏的别处内存
            if (memory == null || shared.Version != 1 || shared.IoBufferCount == 0 || ringEnd > workAreaSize || ioEnd > workAreaSize)
            {
                Logger.Warning?.Print(LogClass.ServiceAudio, $"[S2A hwacod] 开管理会话的参数对不上：版本 {shared.Version}、IO {shared.IoBufferCount} 块 × ({shared.IoInputSize} + {shared.IoOutputSize})、完成环偏移 0x{shared.ResultRing.Offset:X}、工作区 0x{workAreaSize:X}");
                HorizonStatic.Syscall.CloseHandle(transferMemoryHandle);
                HorizonStatic.Syscall.CloseHandle(processHandle);
                token = 0;
                manager = null;
                eventHandle = 0;

                return CodecResult.OpusBadArg;
            }

            token = (uint)(System.Threading.Interlocked.Increment(ref s_token) & 0xFFFF);
            HardwareAudioCodecManagerSession session = new((ushort)token, memory, in shared, workAreaAddress, transferMemoryHandle, processHandle);
            eventHandle = session.EventHandle;
            manager = session;

            return Result.Success;
        }
    }

    partial class HardwareAudioCodecManagerSession : IHardwareAudioCodecManagerSession, IDisposable
    {
        // 完成条目的结果码：SDK（opus::hw::DequeuePcmInterleavedData…）只接 模块 111、描述 33–43，转成 OpusResult 1–11 交给游戏，其余中止。
        //   与旧 hwopus 同一套 OpusResult：4 = 坏包（旧路径服务端回 0x226F 时 SDK 也转成 4）、6 = 包长不对、7 = PCM 缓冲不够
        internal static readonly Result BrokenPacket = new(111, 33 + 4 - 1);
        internal static readonly Result InvalidPacketSize = new(111, 33 + 6 - 1);
        internal static readonly Result InsufficientPcmBuffer = new(111, 33 + 7 - 1);

        private readonly ushort _token;
        private readonly IVirtualMemoryManager _memory;
        private readonly HardwareAudioCodecSharedMemoryParameter _shared;
        private readonly ulong _ioBase;
        private readonly ulong _ringBase;
        private readonly uint _ringCount;
        private readonly Dictionary<uint, Instance> _instances = new();
        private SystemEventType _event;
        private int _transferMemoryHandle;
        private int _processHandle;
        private byte[] _input = [];
        private byte[] _output = [];

        public int EventHandle { get; }

        private sealed class Instance : IDisposable
        {
            public ulong Kind;
            public int ChannelCount;
            public HardwareOpusDecoder Decoder;   // Stub 为 null

            public void Dispose() => Decoder?.Dispose();
        }

        public HardwareAudioCodecManagerSession(ushort token, IVirtualMemoryManager memory, in HardwareAudioCodecSharedMemoryParameter shared, ulong workAreaAddress, int transferMemoryHandle, int processHandle)
        {
            _token = token;
            _memory = memory;
            _shared = shared;
            _ioBase = workAreaAddress + shared.IoBuffers.Offset;
            _ringBase = workAreaAddress + shared.ResultRing.Offset;
            _ringCount = shared.IoBufferCount + 1;
            _transferMemoryHandle = transferMemoryHandle;
            _processHandle = processHandle;

            Os.CreateSystemEvent(out _event, EventClearMode.AutoClear, interProcess: true).AbortOnFailure();
            EventHandle = Os.GetReadableHandleOfSystemEvent(ref _event);
        }

        [CmifCommand(0)]
        public unsafe Result CreateInstance(uint instance, [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer, 0x120)] in HardwareAudioCodecParameter parameter)
        {
            if (instance >= _shared.InstanceCount)
            {
                return CodecResult.OpusBadArg;
            }

            Instance created = new() { Kind = parameter.Kind, ChannelCount = parameter.ChannelCount };

            try
            {
                switch (parameter.Kind)
                {
                    case 0:
                        break;
                    case 1:
                        created.Decoder = HardwareOpusDecoder.CreateForAudioCodec(parameter.SampleRate, parameter.ChannelCount, 0, 0, null);
                        break;
                    case 2:
                        byte[] mapping = new byte[Math.Clamp(parameter.ChannelCount, 0, 0x100)];

                        fixed (byte* m = parameter.ChannelMappings)
                        {
                            new ReadOnlySpan<byte>(m, mapping.Length).CopyTo(mapping);
                        }

                        created.Decoder = HardwareOpusDecoder.CreateForAudioCodec(parameter.SampleRate, parameter.ChannelCount, parameter.TotalStreamCount, parameter.StereoStreamCount, mapping);
                        break;
                    default:
                        return CodecResult.OpusBadArg;
                }
            }
            catch (ArgumentException error)
            {
                Logger.Warning?.Print(LogClass.ServiceAudio, $"[S2A hwacod] 建实例 {instance} 失败：{error.Message}");

                return CodecResult.OpusBadArg;
            }

            if (_instances.Remove(instance, out Instance old))
            {
                old.Dispose();
            }

            _instances[instance] = created;

            return Result.Success;
        }

        [CmifCommand(1)]
        public Result DestroyInstance(uint instance)
        {
            if (_instances.Remove(instance, out Instance old))
            {
                old.Dispose();
            }

            return Result.Success;
        }

        [CmifCommand(10)]
        public Result Execute([Buffer(HipcBufferFlags.In | HipcBufferFlags.AutoSelect)] ReadOnlySpan<HardwareAudioCodecTask> tasks)
        {
            uint stride = _shared.IoInputSize + _shared.IoOutputSize;

            if (_input.Length < _shared.IoInputSize)
            {
                _input = new byte[_shared.IoInputSize];
            }

            if (_output.Length < _shared.IoOutputSize)
            {
                _output = new byte[_shared.IoOutputSize];
            }

            foreach (ref readonly HardwareAudioCodecTask task in tasks)
            {
                long start = Stopwatch.GetTimestamp();
                uint outputSize = 0;
                Result result;

                if (task.IoBuffer >= _shared.IoBufferCount || !_instances.TryGetValue(task.Instance, out Instance instance))
                {
                    result = CodecResult.OpusBadArg;
                }
                else
                {
                    ulong input = _ioBase + (ulong)task.IoBuffer * stride;
                    Span<byte> inData = _input.AsSpan(0, (int)Math.Min(task.InputSize, _shared.IoInputSize));
                    Span<byte> outData = _output.AsSpan(0, (int)_shared.IoOutputSize);

                    _memory.Read(input, inData);
                    result = Process(instance, inData, outData, task.Reset != 0, out outputSize);

                    if (outputSize != 0)
                    {
                        _memory.Write(input + _shared.IoInputSize, outData[..(int)outputSize]);
                    }
                }

                PushResult(new HardwareAudioCodecResult
                {
                    Token = task.Token,
                    Instance = task.Instance,
                    IoBuffer = task.IoBuffer,
                    Sequence = task.Sequence,
                    ProcessingTimeNs = (long)Stopwatch.GetElapsedTime(start).TotalNanoseconds,
                    OutputSize = outputSize,
                    Result = (uint)result.ErrorCode,
                });
            }

            Os.SignalSystemEvent(ref _event);

            return Result.Success;
        }

        private static Result Process(Instance instance, ReadOnlySpan<byte> input, Span<byte> output, bool reset, out uint outputSize)
        {
            outputSize = 0;

            // Stub：不解码，原样交回输入（SDK 给它的输入 / 输出同大小）
            if (instance.Decoder == null)
            {
                int n = Math.Min(input.Length, output.Length);
                input[..n].CopyTo(output);
                outputSize = (uint)n;

                return Result.Success;
            }

            // 输入是 Opus 包头（大端包长 + final range）+ 包，与旧 hwopus 相同（SDK GetFirstInputDataSize 按包头取整包）
            if (input.Length < 8 || BinaryPrimitives.ReadUInt32BigEndian(input) > (uint)(input.Length - 8))
            {
                return InvalidPacketSize;
            }

            Result result = instance.Decoder.DecodeForAudioCodec(input, output, reset, out int samples);

            if (result == CodecResult.InvalidLength)
            {
                return InsufficientPcmBuffer;
            }

            if (result.IsFailure)
            {
                return BrokenPacket;
            }

            outputSize = (uint)(samples * instance.ChannelCount * sizeof(short));

            return Result.Success;
        }

        private void PushResult(in HardwareAudioCodecResult entry)
        {
            uint write = _memory.Read<uint>(_ringBase + 4);

            if (write >= _ringCount)
            {
                write = 0;
            }

            _memory.Write(_ringBase + 0x80 + (ulong)write * 0x40, entry);
            _memory.Write(_ringBase + 4, write + 1 == _ringCount ? 0u : write + 1);
        }

        public void Dispose()
        {
            foreach (Instance instance in _instances.Values)
            {
                instance.Dispose();
            }

            _instances.Clear();
            Os.DestroySystemEvent(ref _event);

            if (_transferMemoryHandle != 0)
            {
                HorizonStatic.Syscall.CloseHandle(_transferMemoryHandle);
                _transferMemoryHandle = 0;
            }

            if (_processHandle != 0)
            {
                HorizonStatic.Syscall.CloseHandle(_processHandle);
                _processHandle = 0;
            }
        }
    }
}
