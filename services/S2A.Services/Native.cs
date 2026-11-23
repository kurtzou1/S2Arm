using System.Runtime.InteropServices;

namespace S2A.Services
{
    // 原生层 ↔ C# 接口（runtime/include/s2a_native.h，docs/接口_原生层.md）的 C# 侧声明。
    // 布局与头文件逐字段一致；头文件改了这里同步改。

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct LanDiscoveryV1
    {
        public uint Abi;
        public delegate* unmanaged<ulong, ushort, int> Start;
        public delegate* unmanaged<int, void> SetHosting;
        public delegate* unmanaged<void> Stop;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct SvcCtx
    {
        public uint Num;        // 调用号
        public uint Thread;     // 当前游戏线程句柄
        public ulong* Regs;     // 门帧 x0..x30，可读可写
        public byte* Tlr;       // 当前线程 ThreadLocalRegion（IPC 消息在 +0）
        public ulong Obj;       // 0x21/0x22/0x23：会话句柄解出的 cookie
        public uint ObjKind;
        public uint Pad;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct CsApi
    {
        public uint Size;
        public uint Pad;
        public delegate* unmanaged<SvcCtx*, int> Svc;
        public delegate* unmanaged<uint, ulong, void> HandleClosed;
        public delegate* unmanaged<uint, void> ThreadExit;
        public delegate* unmanaged<byte*, void> Shutdown;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MemInfo
    {
        public ulong Base, Size;
        public uint State, Attr, Perm, Pad;
    }

    // 远端描述符（接口 v2.13，runtime/src/far.c s2a_far_desc）：Dir == 0 = 远端没开；否则游戏地址 va ∈ [Lo, Lo + 2^36) 时
    // ((long*)Dir)[(va - Lo) >> 21] = 该 2 MiB 块「影子 − 游戏」的差值（0 = 这块没映射）。原生层只在布局时写一次（早于 S2A_Init）
    [StructLayout(LayoutKind.Sequential)]
    public struct FarDesc
    {
        public ulong Lo;
        public nint Dir;
    }

    public enum ObjKind : uint
    {
        None, Thread, EventR, EventW, Session, Shmem, Tmem, Port, CsOther,
        Process, // 待原生层接口 v2：0xFFFF8001 当复制句柄递给服务时
    }

    public static class SvcResult
    {
        public const int Unhandled = 0;
        public const int Handled = 1;
    }

    // 原生层导出函数表。生产：UseLinked() 指到同进程静态链接的 s2a_*；单测：测试工程填托管假实现。
    // 用函数指针而不是接口：热路径零分配、无虚调用开销，且两种实现互不知道对方。
    public static unsafe class Native
    {
        public static delegate*<uint, ulong, uint> HandleNew;
        public static delegate*<uint, uint*, ulong*, int> HandleGet;
        public static delegate*<uint, int> HandleClose;
        public static delegate*<uint*, uint*, ulong> EventCreate;
        public static delegate*<ulong, void> EventSignal;
        public static delegate*<ulong, void> EventClear;
        public static delegate*<ulong, void> EventRelease;
        public static delegate*<ulong, uint> EventDupRead;
        public static delegate*<ulong, void> EventRetain;
        public static delegate*<void*, ulong, uint> ShmemWrap;
        public static delegate*<uint, ulong*, ulong*, uint*, int> TmemGet;
        public static delegate*<ulong, MemInfo*, int> MemQuery;
        // [va, va + size) 全已映射（不并段；IsRangeMapped 每次托管写都调，别名区逐段 MemQuery 会把整段并出来）
        public static delegate*<ulong, ulong, int> MemMapped;
        public static delegate*<ulong> ProcessId;
        public static delegate*<ulong> ProgramId;
        public static delegate*<CsApi*, int> RegisterCs;
        public static delegate*<int> ScreenW;   // 接口 v2.5：游戏 1080 高对应的屏幕宽（1920 = 16:9 不加宽）；测试里为 null
        public static delegate*<int> ScreenH;   // 10-26 任意宽高比：1920 宽对应的屏幕高（> 1080 = 屏幕比 16:9 窄、上下多画）；测试里为 null
        public static delegate*<int> WidenGame; // 接口 v2.6：游戏自己出宽图（屏宽 > 1920 且启用了宽屏点）回 1；S2A_Init 起有定值
        public static delegate*<int> WidenLayout; // 游戏界面布局也是宽的（第二层启用了界面布局尺寸点 lytsz）回 1；S2A_Init 起有定值
        public static delegate*<int> WidenFull; // 接口 v2.11：第三层整套放宽这一档位闭环验过回 1（没验过 = 16:9 原比例居中留黑边）
        public static delegate*<int> HostFocused;      // 接口 v2.15：平台壳报的焦点（iOS 前台 / Mac 有焦点 = 1）；测试里为 null
        public static delegate*<int, void> FocusSuspendSet;   // 接口 v2.15：游戏焦点处理模式是否 AlwaysSuspend（失焦即冻结，AppletStateMgr）告诉平台壳
        public static delegate*<int> ConsoleMode;      // 接口 v2.15：平台壳设的掌机 0 / 主机 1，-1 = 没设过
        public static delegate*<int> HostSleeping;     // 接口 v2.15：iOS 后台 / Mac 系统睡眠 = 1
        public static delegate*<int, void> AppletOpenAdd;   // 接口 v2.18：系统小程序开着的个数 +1 / -1，报给原生停帧看门（Dispatcher 接到 S2AHooks）；测试里为 null
        public static delegate*<int> GuestFrozen;      // 接口 v2.17：客机冻结状态；音频暂停跟随它，不跟随焦点本身
        public static delegate*<int> GfxMode;   // 双轨图形模式（runtime/include/s2a_gfx_mode.h）：0 通用 / 1 直连，起局判定后不变；测试里为 null
        public static delegate*<byte*, void> BootMark;   // 接口 v2.7：起局分段计时，打「[起局] <段> +ms（本段 ms）」；测试里为 null
        public static delegate* unmanaged<ulong> GuestTick;
        public static delegate* unmanaged<ulong> GuestTickHz;   // 接口 v2.16：计数器频率（Switch 2 是 31.25 MHz）；旧原生层没有 = 19.2 MHz
        public static delegate* unmanaged<long> ClockUnseen;   // 接口 v2.14：游戏计数器没看到的宿主时长（ns）；见 NativeTickSource.UnseenNs
        public static delegate* unmanaged<delegate* unmanaged<void>, void> ClockRegisterCatchup;   // 接口 v2.14：登记补时回调（NativeTickSource.BindCatchUp 调）
        public static delegate* unmanaged<int> DetMode;                     // 接口 v2.10：确定性档（0 = 关）
        public static delegate* unmanaged<ulong, void*, ulong, void> DetHostWrite;   // 接口 v2.10：宿主写游戏内存（确定性档按序记 / 重放）   // 接口 v2.8：游戏读到的系统计数器（19.2 MHz，同 mrs cntpct 门 / svc GetSystemTick）
        // Registered by platform composition before Boot; table and callbacks live
        // until process exit. Same-pointer registration is idempotent, not replaceable.
        public static LanDiscoveryV1* LanDiscovery { get; private set; }
        private static readonly object _lanRegistrationLock = new();
        public static bool RegisterLanDiscovery(LanDiscoveryV1* provider)
        {
            lock (_lanRegistrationLock)
            {
                if (provider == null || provider->Abi != 1 || provider->Start == null ||
                    provider->SetHosting == null || provider->Stop == null)
                {
                    Red.Report("联机发现登记无效", "需要 ABI 1 和完整 start/hosting/stop", allowFailFast: false);
                    return false;
                }
                if (LanDiscovery != null && LanDiscovery != provider)
                {
                    Red.Report("联机发现不能替换 provider", allowFailFast: false);
                    return false;
                }
                LanDiscovery = provider;
                return true;
            }
        }
        // 接口 v2.13：远端描述符（s2a_far_desc_get 回的地址）。恒非空：原生层没有这个导出（单测 / 别的平台）时指向一份全零的（= 远端没开），
        //   GuestMemory 热路径只判一次 Dir 是否为 0
        private static readonly FarDesc* FarFallback = (FarDesc*)NativeMemory.AllocZeroed((nuint)sizeof(FarDesc));
        public static FarDesc* Far = FarFallback;

        private static readonly object _linkLock = new();
        private static nint _linkedOwner;
        private static bool _linkedExplicitOwner;
        // #1422：兜底绑定时记下的「哪些可选导出成对存在」。同一个句柄被显式 owner 升级时要用它们补跑
        // 显式模式的成对检查（兜底会把不成对的组悄悄清零，升级不能因此放过）。
        private static bool _linkedHasMode, _linkedHasWrite, _linkedHasUnseen, _linkedHasCatchup;
        // #1422：平台装配登记的兜底 owner，以及「本平台必须登记」的标记（共用层不判断平台）。
        private static nint _fallbackOwner;
        private static bool _fallbackOwnerRequired, _notedMissingFallbackOwner;

        // 起局打点：段名传 NUL 结尾的 UTF-8 字面量（"…\0"u8），不分配
        public static void Mark(System.ReadOnlySpan<byte> stage)
        {
            if (BootMark != null)
            {
                fixed (byte* p = stage)
                {
                    BootMark(p);
                }
            }
        }

        public static bool Ready
        {
            get { lock (_linkLock) return HandleNew != null; }
        }

        // 返回值约定自检（对拍真原生层）：C# 判成败的每个导出各取一个结果确定的调用，与本文件的用法比；不符逐条报红，回不符条数。
        // 起因：s2a_handle_close 约定两边反向各改一次，关句柄必判失败、01006F8002326000起局 3 秒中止
        public static int SelfCheck()
        {
            int bad = 0;
            uint r;
            ulong ev = EventCreate(&r, null);

            if (ev == 0 || r == 0)
            {
                Red.Report("原生接口自检：s2a_event_create 建不出事件");
                return 1;
            }

            uint kind;
            ulong cookie;
            bad += Expect("s2a_handle_get(有效句柄)", HandleGet(r, &kind, &cookie), 1);
            bad += Expect("s2a_handle_get(0xFFFF8001 进程伪句柄)", HandleGet(0xFFFF8001, &kind, &cookie), 1);
            bad += Expect("s2a_handle_close(有效句柄)", HandleClose(r), 1);
            bad += Expect("s2a_handle_get(已关句柄)", HandleGet(r, &kind, &cookie), 0);   // 不对已关句柄调 close：原生层会为它打诊断红行
            EventRelease(ev);

            if (MemQuery != null)
            {
                MemInfo info;
                bad += Expect("s2a_mem_query", MemQuery((ulong)&info, &info), 0);
            }

            return bad;
        }

        private static int Expect(string call, int got, int want)
        {
            if (got == want)
            {
                return 0;
            }

            Red.Report($"原生接口自检：{call} 回 {got}，服务层按 {want} 判（返回值约定两边不一致）");
            return 1;
        }

        // Apple 的既有入口：可选确定性导出缺一项仍按整组缺失处理。
        //
        // #1422：安卓上原生层是 System.loadLibrary 加载的 .so，「主程序句柄」（可执行）在 RTLD_LOCAL
        // 下看不见它的导出，于是兜底绑定查不到 s2a_clock_unseen_ns / s2a_clock_register_catchup（v2.14）
        // 等可选导出，每局报一条红（符号其实在 .dynsym 里；JNI_OnLoad 里 promote 到 RTLD_GLOBAL 也无效——
        // bionic 不对已加载库做事后可见性升级）。修法不是共用层判断平台，而是**平台登记的兜底 owner**：
        // 平台装配在 Boot 前调 RegisterFallbackOwner()，兜底就绑定它。
        public static void UseLinked() => UseLinked(FallbackOwner(), false);

        // 平台登记点：兜底绑定（无参 UseLinked）应该用哪个 provider 句柄，由平台装配在 Boot 前登记。
        // 共用层不认识平台；「本平台必须登记」也由登记方自己声明，兜底时若还没登记就红一次，
        // 让「登记早于第一次兜底绑定」成为可检查的前提，而不是靠运气。
        public static void RegisterFallbackOwner(nint owner, bool required)
        {
            lock (_linkLock)
            {
                _fallbackOwner = owner;
                _fallbackOwnerRequired = required;
            }
        }

        private static nint FallbackOwner()
        {
            lock (_linkLock)
            {
                if (_fallbackOwner != 0) return _fallbackOwner;
                if (_fallbackOwnerRequired && !_notedMissingFallbackOwner)
                {
                    _notedMissingFallbackOwner = true;
                    Red.Report("平台已声明兜底绑定必须由装配登记 provider owner，但这次兜底发生在登记之前（#1422）："
                        + "本次仍用主程序句柄，安卓上会因此缺少 .so 的可选导出");
                }
            }

            return NativeLibrary.GetMainProgramHandle();
        }

        // composition 持有实际原生 provider 的库句柄直到进程结束。在任何消费者
        // 启动前调用；只绑定一次，同 owner 重复调用幂等，不支持热换或卸载。
        // 仅约束动态 extras 的来源，不代替 DirectPInvoke 链接审计或 game-ready 判定。
        public static void UseLinked(nint exportOwner) => UseLinked(exportOwner, true);

        internal static void UseLinked(nint exportOwner, bool explicitOwner)
        {
            if (exportOwner == 0)
            {
                throw new System.ArgumentException("原生 provider 句柄不能为空", nameof(exportOwner));
            }

            lock (_linkLock)
            {
                if (_linkedOwner != 0)
                {
                    if (_linkedOwner == exportOwner && _linkedExplicitOwner == explicitOwner) return;
                    if (_linkedOwner == exportOwner && !_linkedExplicitOwner && explicitOwner)
                    {
                        // #1422：同一个句柄先被无参兜底绑过、随后被显式 owner 确认——只把「权威来源」
                        // 标记升级，不重解析（同一句柄的导出集合相同）。否则安卓起局路径随后那次
                        // UseLinked(request->NativeOwner) 会抛「已绑定、不支持更换合同」，把整局打红。
                        // 显式模式的成对检查必须补跑：兜底那次遇到不成对的组会悄悄清零，升级若不再核对，
                        // 显式模式的严格性就被绕过了。用绑定时记下的解析结果重跑两条规则，不成对照显式规则抛错。
                        if (_linkedHasMode != _linkedHasWrite)
                        {
                            throw new System.InvalidOperationException("原生确定性导出 s2a_det_mode / s2a_det_host_write 必须成对提供");
                        }

                        if (_linkedHasUnseen != _linkedHasCatchup)
                        {
                            throw new System.InvalidOperationException("原生补时导出 s2a_clock_unseen_ns / s2a_clock_register_catchup 必须成对提供");
                        }

                        _linkedExplicitOwner = true;
                        return;
                    }
                    if (_linkedOwner != exportOwner || _linkedExplicitOwner != explicitOwner)
                    {
                        throw new System.InvalidOperationException("原生 provider 已绑定，不支持更换 owner 或绑定合同");
                    }

                    return;
                }

                // 先查完整候选，再发布所有槽。显式 owner 的半组确定性接口是错误；
                // 全部缺失在诊断构建中合法，不能残留先前注入的可选指针。
                bool hasMode = NativeLibrary.TryGetExport(exportOwner, "s2a_det_mode", out nint dm);
                bool hasWrite = NativeLibrary.TryGetExport(exportOwner, "s2a_det_host_write", out nint dw);
                bool hasTick = NativeLibrary.TryGetExport(exportOwner, "s2a_guest_tick", out nint tick);
                bool hasTickHz = NativeLibrary.TryGetExport(exportOwner, "s2a_guest_tick_hz", out nint tickHz);   // 平台例外：与上一行 s2a_guest_tick 同组的可选导出，同一 owner 查找口径（安卓原生层在 loadLibrary 的 .so 里）；旧原生层 / 诊断构建没有它就按 19.2 MHz（NativeTickSource）
                bool hasFar = NativeLibrary.TryGetExport(exportOwner, "s2a_far_desc_get", out nint farExport);
                // 接口 v2.14（#863）补时两导出与其它可选导出同一查找口径（11-01：原先固定查主程序句柄，安卓上原生层在 System.loadLibrary 的 .so 里，查不到、每局报红）
                bool hasUnseen = NativeLibrary.TryGetExport(exportOwner, "s2a_clock_unseen_ns", out nint unseen);
                bool hasCatchup = NativeLibrary.TryGetExport(exportOwner, "s2a_clock_register_catchup", out nint catchup);
                FarDesc* far = hasFar ? (FarDesc*)((delegate* unmanaged<void*>)farExport)() : null;
                if (hasMode != hasWrite)
                {
                    if (explicitOwner)
                    {
                        throw new System.InvalidOperationException("原生确定性导出 s2a_det_mode / s2a_det_host_write 必须成对提供");
                    }

                    dm = dw = 0;
                }

                if (hasUnseen != hasCatchup)
                {
                    if (explicitOwner)
                    {
                        throw new System.InvalidOperationException("原生补时导出 s2a_clock_unseen_ns / s2a_clock_register_catchup 必须成对提供");
                    }

                    hasUnseen = hasCatchup = false;
                }

                if (!hasUnseen && !explicitOwner)
                {
                    Red.Report("原生层没有 s2a_clock_unseen_ns / s2a_clock_register_catchup（接口 v2.14）：游戏日历会落后后台与睡眠时长");
                }

                if (!hasTick && !explicitOwner)
                {
                    Red.Report("原生层没有 s2a_guest_tick（接口 v2.8）：Ryujinx 时钟与游戏计数器零点不同，游戏时间会差出宿主开机时长");
                }

                HandleGet = &Imports.s2a_handle_get;
                HandleClose = &Imports.s2a_handle_close;
                EventCreate = &Imports.s2a_event_create;
                EventSignal = &Imports.s2a_event_signal;
                EventClear = &Imports.s2a_event_clear;
                EventRelease = &Imports.s2a_event_release;
                EventDupRead = &Imports.s2a_event_dup_read;
                EventRetain = &Imports.s2a_event_retain;
                ShmemWrap = &Imports.s2a_shmem_wrap;
                TmemGet = &Imports.s2a_tmem_get;
                MemQuery = &Imports.s2a_mem_query;
                MemMapped = &Imports.s2a_mem_mapped;
                ProcessId = &Imports.s2a_process_id;
                ProgramId = &Imports.s2a_program_id;
                RegisterCs = &Imports.s2a_register_cs;
                ScreenW = &Imports.s2a_screen_w;
                ScreenH = &Imports.s2a_screen_h;
                WidenGame = &Imports.s2a_widen_game;
                WidenLayout = &Imports.s2a_widen_layout;
                WidenFull = &Imports.s2a_widen_full;
                GfxMode = &Imports.s2a_gfx_mode;
                HostFocused = &Imports.s2a_host_focused;
                FocusSuspendSet = &Imports.s2a_focus_suspend_set;
                ConsoleMode = &Imports.s2a_console_mode;
                HostSleeping = &Imports.s2a_host_sleeping;
                AppletOpenAdd = &Imports.s2a_applet_open_add;
                GuestFrozen = &Imports.s2a_guest_frozen;
                BootMark = &Imports.s2a_boot_mark;
                DetMode = (delegate* unmanaged<int>)dm;
                DetHostWrite = (delegate* unmanaged<ulong, void*, ulong, void>)dw;
                GuestTick = (delegate* unmanaged<ulong>)tick;
                GuestTickHz = hasTickHz ? (delegate* unmanaged<ulong>)tickHz : null;
                ClockUnseen = hasUnseen ? (delegate* unmanaged<long>)unseen : null;
                ClockRegisterCatchup = hasUnseen ? (delegate* unmanaged<delegate* unmanaged<void>, void>)catchup : null;
                Far = far != null ? far : FarFallback;
                HandleNew = &Imports.s2a_handle_new;
                _linkedHasMode = hasMode;
                _linkedHasWrite = hasWrite;
                _linkedHasUnseen = hasUnseen;
                _linkedHasCatchup = hasCatchup;
                _linkedExplicitOwner = explicitOwner;
                _linkedOwner = exportOwner;
            }
        }

        // 同进程静态链接（iOS / Mac NativeAOT 用 DirectPInvoke 绑定到 s2a_native）
        // nn::ro 装 / 卸 NRO（Host.HookNro 登记进 S2AHooks；返回码见 Ryujinx.HLE/S2AHooks.cs）
        internal static unsafe int NroMap(byte* sha256, ulong size, ulong bss, ulong* mapped) => Imports.s2a_nro_map(sha256, size, bss, mapped);
        internal static int NroUnmap(ulong mapped) => Imports.s2a_nro_unmap(mapped);
        internal static unsafe int NroKeep(byte* sha256, byte* data, ulong size) => Imports.s2a_nro_keep(sha256, data, size);

        internal static class Imports
        {
            private const string Lib = "s2a_native";

            [DllImport(Lib)] public static extern unsafe int s2a_nro_map(byte* sha256, ulong size, ulong bss, ulong* mapped);
            [DllImport(Lib)] public static extern int s2a_nro_unmap(ulong mapped);
            [DllImport(Lib)] public static extern unsafe int s2a_nro_keep(byte* sha256, byte* data, ulong size);

            [DllImport(Lib)] public static extern uint s2a_handle_new(uint kind, ulong cookie);
            [DllImport(Lib)] public static extern int s2a_session_prepare();
            [DllImport(Lib)] public static extern int s2a_session_rebuild_supported();
            [DllImport(Lib)] public static extern uint s2a_session_generation();
            [DllImport(Lib)] public static extern int s2a_session_service_failed(uint generation);
            [DllImport(Lib)] public static extern void s2a_session_process_exit(uint generation);
            [DllImport(Lib)] public static extern int s2a_host_session_state();
            // 系统键盘桥接（runtime/src/text_input.c，TextInput.cs）：0 = 平台没登记输入框（安卓 / 开发宿主）或无人值守
            [DllImport(Lib)] public static extern unsafe int s2a_host_text_input(long id, byte* json, delegate* unmanaged<long, int, byte*, void> cb);
            [DllImport(Lib)] public static extern void s2a_host_text_input_cancel(long id);
            [DllImport(Lib)] public static extern int s2a_thread_session_joined();
            [DllImport(Lib)] public static extern int s2a_gate_inflight();
            [DllImport(Lib)] public static extern int s2a_handle_get(uint h, uint* kind, ulong* cookie);
            [DllImport(Lib)] public static extern int s2a_handle_close(uint h);
            [DllImport(Lib)] public static extern int s2a_screen_w();
            [DllImport(Lib)] public static extern int s2a_screen_h();
            [DllImport(Lib)] public static extern int s2a_widen_game();
            [DllImport(Lib)] public static extern int s2a_widen_layout();
            [DllImport(Lib)] public static extern int s2a_widen_full();
            [DllImport(Lib)] public static extern int s2a_gfx_mode();
            [DllImport(Lib)] public static extern int s2a_host_focused();
            [DllImport(Lib)] public static extern void s2a_focus_suspend_set(int on);
            [DllImport(Lib)] public static extern int s2a_console_mode();
            [DllImport(Lib)] public static extern int s2a_host_sleeping();
            [DllImport(Lib)] public static extern void s2a_applet_open_add(int d);
            [DllImport(Lib)] public static extern int s2a_guest_frozen();
            [DllImport(Lib)] public static extern void s2a_boot_mark(byte* stage);
            [DllImport(Lib)] public static extern ulong s2a_event_create(uint* hRead, uint* hWrite);
            [DllImport(Lib)] public static extern void s2a_event_signal(ulong ev);
            [DllImport(Lib)] public static extern void s2a_event_clear(ulong ev);
            [DllImport(Lib)] public static extern void s2a_event_release(ulong ev);
            [DllImport(Lib)] public static extern uint s2a_event_dup_read(ulong ev);
            [DllImport(Lib)] public static extern void s2a_event_retain(ulong ev);
            [DllImport(Lib)] public static extern uint s2a_shmem_wrap(void* host, ulong size);
            [DllImport(Lib)] public static extern int s2a_tmem_get(uint h, ulong* addr, ulong* size, uint* perm);
            [DllImport(Lib)] public static extern int s2a_mem_query(ulong addr, MemInfo* info);
            [DllImport(Lib)] public static extern int s2a_mem_mapped(ulong addr, ulong size);
            [DllImport(Lib)] public static extern ulong s2a_process_id();
            [DllImport(Lib)] public static extern ulong s2a_program_id();
            [DllImport(Lib)] public static extern int s2a_register_cs(CsApi* api);
        }
    }
}
