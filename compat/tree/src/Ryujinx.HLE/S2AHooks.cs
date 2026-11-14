using Ryujinx.HLE.HOS.Services;

namespace Ryujinx.HLE
{
    // S2Arm: hooks for in-thread direct dispatch (services/S2A.Services sets them; when unset, behaviour is upstream's).
    // Game requests are served synchronously on the calling game thread instead of Ryujinx's ServerBase threads,
    // and the game's handle table / events live in S2Arm's native layer (docs/接口_原生层.md §4).
    static unsafe class S2AHooks
    {
        // IpcService.MakeObject (non-domain): register the new sub-session with the S2Arm dispatcher; returns a handle
        // in the serving process's handle table that the dispatcher turns into a game handle when the reply is written.
        public static delegate*<IpcService, int> MakeSession;

        // 游戏是 Switch 2 程序（NPDM 是 Switch 2 的 ACID 布局；services Application.Register 按 NpdmCompat 设）。只给语义随机型变的命令分派用
        public static bool Switch2;

        // GetDesiredLanguage when the game does not support the system language: try these in order before upstream's "first supported"
        // (the host passes the system's preferred languages, then Simplified / Traditional Chinese, then English). Null = upstream.
        public static Ryujinx.HLE.HOS.SystemState.TitleLanguage[] TitleLanguageFallback;

        // The system language was chosen explicitly (S2A_SYSTEM_LANGUAGE) rather than taken from the device: GetDesiredLanguage returns it
        // even when the game's control data declares no supported languages (otherwise American English, #401).
        public static bool ExplicitSystemLanguage;

        // KReadableEvent bound to a native event (KReadableEvent.S2ANativeEvent != 0): mirror Signal / Clear to it,
        // because the game waits on the native event (WaitSynchronization never enters C#).
        public static delegate*<ulong, void> EventSignal;
        public static delegate*<ulong, void> EventClear;

        // Horizon.StartNewServices: start a Horizon (new IPC framework) service on an S2Arm thread instead of a Ryujinx kernel process
        public static delegate*<Ryujinx.Horizon.ServiceEntry, void> StartHorizonService;

        // IPC buffer descriptors carry 39-bit addresses. On macOS the game's address window tops out at 2^39 and an alias region that does not
        // fit is extended above it, so bit 39 of a buffer there is lost when the game packs the descriptor; this restores it (native
        // svc_mem.c s2a_ipc_addr39: only when the 39-bit address is not a game address and adding bit 39 gives a mapped one). Null = as decoded.
        public static delegate* unmanaged<ulong, ulong> IpcAddr39;
        public static ulong FixIpcAddr(ulong a) => IpcAddr39 == null ? a : IpcAddr39(a);
        // ldr:ro LoadNro / UnloadNro (nn::ro). The NRO's code was rewritten at pack time like the exefs modules and is embedded in the app
        // (iOS cannot execute code loaded at run time); the native layer maps that image by the NRO file's SHA-256 (runtime/src/loader.c s2a_nro_map).
        // NroMap(sha256[32], nro size, bss size, out base) -> 0 ok, 1 not in the package, 2 size / bss mismatch, 3 already loaded, 4 module table full, 5 unsupported here.
        // NroUnmap(base) -> 0 ok, 1 not loaded. Null = upstream (Ryujinx kernel memory manager).
        public static delegate*<byte*, ulong, ulong, ulong*, int> NroMap;   // 宿主登记（services Native.NroMap → 原生核心 s2a_nro_map，DllImport 集中声明）
        public static delegate*<ulong, int> NroUnmap;
        public static bool NroHooked => NroMap != null;
        public static int NroUnmapAt(ulong mapped) => NroUnmap(mapped);

        // Upstream silently defaulted on missing data in a few places; those now report through here (S2Arm red list)
        public static System.Action<string> Red;

        // Platform JPEG encoding; null preserves the existing Skia implementation on default hosts.
        public static Ryujinx.HLE.UI.ScreenshotJpegEncoder EncodeScreenshotJpeg;

        // Game committed a file system (fsp-srv IFileSystem.Commit, i.e. a save): S2Arm records a marker in the touch-pad recording
        public static delegate*<void> SaveCommitted;

        // A command under Services.Fs failed (S2AFsFail): command name, result + path(s), and whether it is red
        // (false = a probing result the game is expected to handle: path not found / already exists, save data not found)
        public static System.Action<string, string, bool> FsFailed;
        // Service-owned physical memory. Null preserves upstream allocation; a supplied
        // factory transfers a block of the requested size to Switch's lifetime.
        public static System.Func<ulong, Ryujinx.Memory.MemoryBlock> CreateServiceMemory;

        // Tick source shared with the natively running game (null = Ryujinx's own Stopwatch-based TickSource)
        public static Ryujinx.Cpu.ITickSource TickSource;

        // Host time the shared tick source did not see, in ns with an arbitrary zero (game clock frozen in background, host asleep); null = none.
        // The steady clock adds its increase, like a real Switch whose RTC-based steady clock keeps running while the system tick stops in sleep
        public static System.Func<long> TickUnseenNs;

        // Called by the app shell on resume / wake (through native s2a_clock_catchup): the steady clock catches up the unseen time
        public static void SteadyClockCatchUp()
        {
            if (TickUnseenNs != null)
            {
                HOS.Services.Time.TimeManager.Instance.S2ASteadyClockCatchUp(TickUnseenNs());
            }
        }

        // Time zone system data (010000000000080E) as a directory: zoneinfo/<name> TZif files + binaryList.txt
        public static string TimeZoneDataDir;

        // Shared font system data (0100000000000810–0814) as a directory of the original .bfttf files
        public static string SharedFontDir;

        // System data archives (e.g. 0100000000000802 Mii resources) as directories <SystemDataRoot>/<016x id>/:
        // OpenSystemDataStorage gives the RomFS image of one (fs OpenDataStorageByDataId), null when absent
        public static string SystemDataRoot;
        public static System.Func<ulong, LibHac.Fs.IStorage> OpenSystemDataStorage;

        // A system data archive was asked for (id, entry point "MountSystemData" / "OpenDataStorageByDataId", present under SystemDataRoot):
        // S2Arm logs it once per id and entry, so a run shows which system data a game needs (pack/sysdata_need.tsv is built from these lines)
        public static System.Action<ulong, string, bool> SystemDataAsked;

        // Add-on content (DLC) registered by S2A from the game data directory (aoc.tsv + aoc/<idx>/):
        // OpenAocDataStorage gives the RomFS image of a registered DLC, null when it is licence-only (S2A reports red)
        public static System.Func<ulong, LibHac.Fs.IStorage> OpenAocDataStorage;

        // A Memory<byte> viewing game memory [va, va + size) in place (S2A: game addresses are host addresses); null = copy instead
        public static System.Func<ulong, int, System.Memory<byte>?> GuestView;

        // The game is initializing ldn:u (IUserLocalCommunicationService Initialize / InitializeOld), before the multiplayer mode is read:
        // S2A switches the configuration to LAN multiplayer on demand here (hosts the relay, starts Bonjour discovery), so that
        // only games that use local wireless ever touch the network or ask for the local-network permission
        public static System.Action LdnInitializing;

        // TCP port of the RyuLDN server the ldn:u client connects to (S2A hosts its relay on the same port).
        // Upstream's fixed LanPlayPort; tests point it at a free port so they never meet a real relay on 30456
        public static int LdnPort = Ryujinx.Common.SharedConstants.LanPlayPort;

        // System data the game's own pack lacks but S2A can synthesize (empty-but-valid archives such as 0806 / 0823 NgWord, 0802 Mii):
        // directory of the synthesized archive, null when it cannot. Consulted only after the game's own systemdata/<id>/, so real data wins
        public static System.Func<ulong, string> SystemDataFallback;

        public static string SystemDataDir(ulong id)
        {
            if (SystemDataRoot != null)
            {
                string dir = System.IO.Path.Combine(SystemDataRoot, id.ToString("X16"));

                if (System.IO.Directory.Exists(dir))
                {
                    return dir;
                }
            }

            return SystemDataFallback?.Invoke(id);
        }
    }
}
