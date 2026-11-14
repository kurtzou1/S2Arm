using Ryujinx.Audio.Output;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Applet;
using Ryujinx.Horizon.Sdk.OsTypes;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Collections.Generic;
using System.Text;

namespace Ryujinx.Horizon.Sdk.Audio.Detail
{
    // S2Arm：Switch 2 的 auddmg:u（nn::audio::devmgr，虚拟音频设备管理）。上游 Ryujinx、Eden-NX2 / NS2 都没有它，命令形状与语义只能从游戏自带
    //   sdk 的客户端反推（时之笛 / 金刚 / Raiders / Pokopia / 火纹五款 sdk 的 CmifProxy 虚表 + 组包函数 + 调用方，见 compat/改动清单.md 本条）。
    //   时之笛：nn::audio::GetDefaultVirtualOutputDevice → devmgr::Initialize 连不上 auddmg:u 即 Abort。
    //   外部输出流（OpenOutputStream / Start / Stop）还走 300 / 401 / 700 / 800，流本身在 audsmx:u（AudioSystemMixer.cs），两边经 ExternalStreamRegistry 按流号对上。
    //   只实现语义能定死的命令：虚拟输出设备就是宿主那一个声音输出（与 audout:u ListAudioOuts 同一来源），其余命令不进命令表、按未知命令报红；
    //   已实现的命令遇到 SDK 从不发的取值（输入设备、未知设备名、未知标志）也报红，不回成功兜底。
    partial class AudioDeviceManagerUserSessionManager : IServiceObject
    {
        private readonly ExternalStreamRegistry _registry;

        public AudioDeviceManagerUserSessionManager(ExternalStreamRegistry registry)
        {
            _registry = registry;
        }

        // IUserSessionManager 0：in u32 种类 @0、aruid @8、u64 @0x10，带 pid；回 IUserSession。
        //   SDK 的 devmgr::Initialize / CreateProxyContext 只发「种类 2、末字段 0」，别的取值语义不明
        [CmifCommand(0)]
        public Result OpenUserSession(out AudioDeviceManagerUserSession session, uint kind, AppletResourceUserId appletResourceId, ulong reserved, [ClientProcessId] ulong pid)
        {
            if (kind != 2 || reserved != 0)
            {
                throw new NotImplementedException($"auddmg:u IUserSessionManager 0：种类 {kind}、末字段 0x{reserved:X}（SDK 只发种类 2、末字段 0，别的语义不明）");
            }

            session = new AudioDeviceManagerUserSession(_registry);

            return Result.Success;
        }
    }

    partial class AudioDeviceManagerUserSession : IServiceObject, IDisposable
    {
        // nn::audio::devmgr::DeviceFunctionality：1 = 输出（GetDefaultVirtualOutputDevice / ListVirtualOutputDevices 发 1），
        //   2 = 输入（输入 / 注入设备发 2）。宿主声音后端不接收音（AppleHardwareDeviceDriver 只支持输出）：列输入设备回 0 个，其余带输入功能的命令报红
        private const uint FunctionalityOutput = 1;
        private const uint FunctionalityInput = 2;

        // 虚拟输出设备档案（401）+0x220 的 u32：OutputStreamImpl::Open 原样交给 sysmix CreateStream 当设备参数。
        //   真机的取值语义不知道；它只在本机 devmgr 与本机 audsmx:u 之间往返，取值是我方定的（同设备名 "DeviceOut"）
        public const uint VirtualOutputDeviceToken = 1;

        private const int VirtualDeviceProfileSize = 0x228;
        private const int ProfileLatencyOffset = 0x218;
        private const int ProfileDeviceTokenOffset = 0x220;

        private readonly ExternalStreamRegistry _registry;
        private SystemEventType _stateChangeEvent;
        private bool _stateChangeEventCreated;
        private readonly HashSet<ulong> _stateChangeCookies = new();

        public AudioDeviceManagerUserSession(ExternalStreamRegistry registry)
        {
            _registry = registry;
        }

        // 0 ListVirtualDeviceNames：in bool @0、u32 功能 @4；B 缓冲（每项 0x100 字节设备名）；回 u32 个数。
        //   SDK 的公开入口（列输出 / 输入 / 注入设备、取缺省设备 = 列 1 个）都发 bool = false
        [CmifCommand(0)]
        public Result ListVirtualDeviceNames(out int count, [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias)] Span<DeviceName> names, bool flag, uint functionality)
        {
            if (flag)
            {
                throw new NotImplementedException("auddmg:u IUserSession 0：bool 参数为 true（SDK 公开入口只发 false，true 的语义不明）");
            }

            // 列输入设备（功能 2）：宿主不收音，没有虚拟输入设备，回 0 个。SDK ListVirtualInputDevices 拿到 0 个，游戏不再开输入流（麦克风这一路直接返回）
            if (functionality == FunctionalityInput)
            {
                count = 0;

                return Result.Success;
            }

            RequireOutput(0, functionality);

            count = 0;

            foreach (string name in AudioOutputManager.ListAudioOuts())
            {
                if (count >= names.Length)
                {
                    break;
                }

                names[count++] = new DeviceName(name);
            }

            return Result.Success;
        }

        // 100 GetDefaultVirtualDeviceName：in u32 功能 @0；B 缓冲（0x100 字节设备名）。缺省设备 = 列表第一项（SDK 的 GetDefaultVirtualOutputDevice 就是列 1 个）
        [CmifCommand(100)]
        public Result GetDefaultVirtualDeviceName([Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias)] Span<DeviceName> name, uint functionality)
        {
            RequireOutput(100, functionality);

            if (name.Length == 0)
            {
                throw new NotImplementedException("auddmg:u IUserSession 100：设备名缓冲不足 0x100 字节");
            }

            name[0] = new DeviceName(AudioOutputManager.ListAudioOuts()[0]);

            return Result.Success;
        }

        // 200 IsVirtualDeviceAvailable：A 缓冲（设备名，长度 = 字符串长，不带结尾 0）；in u32 功能 @0；只回结果码（成功 = 可用）
        [CmifCommand(200)]
        public Result IsVirtualDeviceAvailable([Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> name, uint functionality)
        {
            RequireOutputDevice(200, name, functionality);

            return Result.Success;
        }

        // 300 IsVirtualDeviceStreamFormatSupported：A 缓冲（设备名）；in StreamFormat @0（12 字节）、u32 功能 @0xc；只回结果码（成功 = 支持）。
        //   宿主能直接播的格式回成功；不支持时真机回哪个结果码不知道 → 报红（游戏的 Open 随之失败，红行带着格式）
        [CmifCommand(300)]
        public Result IsVirtualDeviceStreamFormatSupported([Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> name, StreamFormat format, uint functionality)
        {
            RequireOutputDevice(300, name, functionality);

            if (!ExternalOutputStream.IsHostSupported(format))
            {
                throw new NotImplementedException($"auddmg:u IUserSession 300：{format} 宿主不能直接播，不知道真机回哪个结果码");
            }

            return Result.Success;
        }

        // 401 GetVirtualDeviceProfile：B 缓冲（档案 0x228 字节，客户端先清零）+ A 缓冲（设备名）；in u32 功能 @0；只回结果码。
        //   SDK 只读档案三处：+0x218 u64 = 设备延迟 ns（OutputStreamImpl::Open 要求缓冲帧数 ≥ 延迟 × 采样率 ÷ 1e9，否则拒绝；
        //   GetVirtualOutputDeviceProperties 抄到属性 +0x100）、+0x220 u32（交 sysmix CreateStream）、+0x108 u32（抄到属性 +0x108）。
        //   填前两处；+0x108 语义不知道、时之笛不读属性，不填（保持客户端的清零）。其余字节 SDK 不读
        [CmifCommand(401)]
        public Result GetVirtualDeviceProfile(
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias)] Span<byte> profile,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> name,
            uint functionality)
        {
            RequireOutputDevice(401, name, functionality);

            if (profile.Length < VirtualDeviceProfileSize)
            {
                throw new NotImplementedException($"auddmg:u IUserSession 401：档案缓冲 0x{profile.Length:X} 字节（SDK 给 0x228）");
            }

            BitConverter.TryWriteBytes(profile[ProfileLatencyOffset..], ExternalOutputStream.MinimumLatencyNs);
            BitConverter.TryWriteBytes(profile[ProfileDeviceTokenOffset..], VirtualOutputDeviceToken);

            return Result.Success;
        }

        // 500 AcquireVirtualDeviceStateChangeEvent：A 缓冲（设备名）；in u32 功能 @0、u64 @8（客户端自己的 SystemEventType 地址，作领取凭据，Release 发同一个）；
        //   回复制句柄（客户端按手动清除挂上）。宿主只有一个声音输出、状态从不变化，事件不触发
        [CmifCommand(500)]
        public Result AcquireVirtualDeviceStateChangeEvent([CopyHandle] out int eventHandle, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> name, uint functionality, ulong cookie)
        {
            RequireOutputDevice(500, name, functionality);

            if (!_stateChangeCookies.Add(cookie))
            {
                throw new NotImplementedException($"auddmg:u IUserSession 500：凭据 0x{cookie:X} 已领过事件、未释放");
            }

            if (!_stateChangeEventCreated)
            {
                Os.CreateSystemEvent(out _stateChangeEvent, EventClearMode.ManualClear, interProcess: true).AbortOnFailure();
                _stateChangeEventCreated = true;
            }

            eventHandle = Os.GetReadableHandleOfSystemEvent(ref _stateChangeEvent);

            return Result.Success;
        }

        // 600 ReleaseVirtualDeviceStateChangeEvent：A 缓冲（设备名）；in u32 功能 @0、u64 凭据 @8；只回结果码
        [CmifCommand(600)]
        public Result ReleaseVirtualDeviceStateChangeEvent([Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> name, uint functionality, ulong cookie)
        {
            RequireOutputDevice(600, name, functionality);

            if (!_stateChangeCookies.Remove(cookie))
            {
                throw new NotImplementedException($"auddmg:u IUserSession 600：凭据 0x{cookie:X} 没领过事件");
            }

            return Result.Success;
        }

        // 700 AttachStream：A 缓冲（设备名）；in u32 流号 @0（sysmix CreateStream 回的）、u32 功能 @4；只回结果码。
        //   OutputStreamImpl::Start 调它（不走 sysmix Engage）：挂上 = 宿主开始从环里取样本播
        [CmifCommand(700)]
        public Result AttachStream([Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> name, uint streamId, uint functionality)
        {
            RequireOutputDevice(700, name, functionality);

            ExternalOutputStream stream = _registry.Get(streamId);

            if (stream == null || !stream.IsOpen || stream.IsAttached)
            {
                throw new NotImplementedException($"auddmg:u IUserSession 700：流号 {streamId}{(stream == null ? " 没有" : stream.IsOpen ? " 已挂上" : " 没打开")}（不知道真机回哪个结果码）");
            }

            stream.Attach();

            return Result.Success;
        }

        // 800 DetachStream：in u32 流号 @0；只回结果码。OutputStreamImpl::Stop / Close 调它（失败客户端 Abort）
        [CmifCommand(800)]
        public Result DetachStream(uint streamId)
        {
            ExternalOutputStream stream = _registry.Get(streamId);

            if (stream == null || !stream.IsAttached)
            {
                throw new NotImplementedException($"auddmg:u IUserSession 800：流号 {streamId}{(stream == null ? " 没有" : " 没挂上")}（不知道真机回哪个结果码）");
            }

            stream.Detach();

            return Result.Success;
        }

        private static void RequireOutput(int command, uint functionality)
        {
            if (functionality != FunctionalityOutput)
            {
                throw new NotImplementedException($"auddmg:u IUserSession {command}：功能 {functionality}（只实现了输出 = 1；宿主不收音）");
            }
        }

        private static void RequireOutputDevice(int command, ReadOnlySpan<byte> name, uint functionality)
        {
            RequireOutput(command, functionality);

            int length = name.IndexOf((byte)0);
            string text = Encoding.ASCII.GetString(length < 0 ? name : name[..length]);

            if (Array.IndexOf(AudioOutputManager.ListAudioOuts(), text) < 0)
            {
                throw new NotImplementedException($"auddmg:u IUserSession {command}：设备名「{text}」不是本机虚拟设备（不知道真机对未知设备回哪个结果码）");
            }
        }

        public void Dispose()
        {
            if (_stateChangeEventCreated)
            {
                Os.DestroySystemEvent(ref _stateChangeEvent);
                _stateChangeEventCreated = false;
            }
        }
    }
}
