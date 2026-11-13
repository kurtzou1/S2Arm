using LibHac.Tools.FsSystem;
using Ryujinx.Audio.Integration;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Configuration.Multiplayer;
using Ryujinx.Common.Logging;
using Ryujinx.Cpu;
using Ryujinx.Graphics.GAL;
using Ryujinx.HLE;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.SystemState;
using Ryujinx.HLE.UI;
using Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy.Types;
using System;
using System.IO;

namespace S2A.Services
{
    // 起 Ryujinx 的 Switch 侧（HLE / Horizon / 声音 / 显卡逻辑），不建 Ryujinx 的游戏进程：游戏由原生层原生执行。
    public static class Host
    {
        // 主机 / 掌机档（维护者 10-20 晚：「那就把开关调回掌机档吧，不让咱们被困在这里无法推进」；主机档保留作可选项）。
        //   缺省掌机：DockedMode 假（apm 性能模式 / 操作模式 / 变更事件都由 Ryujinx 按它回答）；外接手柄样式独立由 InputPump 配置。S2A_DOCKED=1 只切主机档及初始手柄配置。
        private static Lazy<bool> LegacyDocked = new(() => Environment.GetEnvironmentVariable("S2A_DOCKED") == "1");
        private static Lazy<SystemLanguage> LegacyLanguage = new(PickLanguage);
        internal static void ResumeAudioForShutdown()
        {
            Device?.AudioDeviceDriver.GetPauseEvent().Set();
        }

        public static void DisposeAudioForShutdown()
        {
            ResumeAudioForShutdown();
            HorizonHost.DisposeAudio();
        }

        public static HostConfiguration Configuration { get; private set; }

        // 用户通道（ExecuteProgram 的程序序号 + UnpopToUserChannel 的数据）：进程级，跨进程内重启存活。
        //   Ryujinx 真值：通道由界面层持有，停模拟、按 Index 重新加载同一文件后还是同一个对象，所以重启后 GetPreviousProgramIndex 回 0（首启 -1）、
        //   重启前 Unpop 的数据还能 Pop 到。原先每次建会话新建一个，重启后两样都丢
        internal static readonly UserChannelPersistence Channel = new();

        // 单测替身：设了就代替原生 s2a_host_restart（返回值同其约定：0 = 已受理）
        internal static Func<int> RestartHook;

        // 发起进程内重启（runtime/src/session.c s2a_host_restart → host_main.c s2a_host_rebuild，同设置页「立刻重启」）：只受理、异步执行，
        //   旧客体 / 服务 / 图形由退休线程收，不在调用线程等。返回 0 = 已受理；-1 没有运行中的会话；-2 缺生命周期支持（安卓没有这个导出）；-3 另一次重启 / 前后台切换在进行
        internal static unsafe int RequestRestart()
        {
            if (RestartHook != null) return RestartHook();
            if (!System.Runtime.InteropServices.NativeLibrary.TryGetExport(System.Runtime.InteropServices.NativeLibrary.GetMainProgramHandle(), "s2a_host_restart", out nint restart)) return -2;   // 平台例外：进程内重启只在苹果宿主提供（安卓桩没有 s2a_host_restart，进不了 Native.Imports 的 DllImport）
            return ((delegate* unmanaged<delegate* unmanaged<int, byte*, nint, void>, nint, int>)restart)(&RestartFinished, 0);
        }

        // 单测替身：设了就代替原生 s2a_host_select_program（返回值同其约定）
        internal static Func<int, int> SelectProgramHook;

        // 多程序合集：登记下一局装哪一支程序的模块（runtime/src/programs.c s2a_host_select_program，只登记、不重启）。
        //   0 = 已登记；-1 = 原生模块目录里没有这个序号；-2 = 宿主没登记根目录；-4 = 没有这个导出（安卓不提供进程内重建）
        internal static unsafe int SelectProgram(int index)
        {
            if (SelectProgramHook != null) return SelectProgramHook(index);
            if (!System.Runtime.InteropServices.NativeLibrary.TryGetExport(System.Runtime.InteropServices.NativeLibrary.GetMainProgramHandle(), "s2a_host_select_program", out nint select)) return -4;   // 平台例外：同 s2a_host_restart，只在苹果宿主提供
            return ((delegate* unmanaged<int, int>)select)(index);
        }

        [System.Runtime.InteropServices.UnmanagedCallersOnly]
        private static unsafe void RestartFinished(int result, byte* detail, nint context)
        {
            string why = System.Runtime.InteropServices.Marshal.PtrToStringUTF8((nint)detail) ?? "";
            if (result == 0) Console.Error.WriteLine($"S2A 同程序重启：新会话已启动（程序序号 {Channel.Index}，上一序号 {Channel.PreviousIndex}）：{why}");
            else Red.Report("同程序重启失败", why, allowFailFast: false);
        }

        public static bool Docked => Configuration?.Docked ?? LegacyDocked.Value;

        internal static void ReloadSessionEnvironment()
        {
            LegacyDocked = new(() => Environment.GetEnvironmentVariable("S2A_DOCKED") == "1");
            LegacyLanguage = new(PickLanguage);
        }

        // 本地无线联机中继地址（IP 或主机名，端口缺省 Ryujinx LanPlayPort 30456，单测改到临时端口：S2AHooks.LdnPort）：Mac 多开给 127.0.0.1，第一个起来的进程托管中继、其余连它；
        //   S2A_LDN_RELAY=1 时非回环地址也就地托管（手机局域网当主机）。不给 = 不联机
        public static string LdnServer { get; } = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("S2A_LDN_SERVER")) ? null : Environment.GetEnvironmentVariable("S2A_LDN_SERVER");
        // 局域网模式（同一 Wi-Fi 多台设备，ios/ldn_lan.m）：每台都在全部网卡上托管中继并用 Bonjour 发布，大家按同一规则选出同一台中继，
        //   原生层经 S2A_LdnSetServer 随时改指，游戏下一次建房 / 加入（ldn:u OpenAccessPoint / OpenStation）用新地址。
        //   进入方式两种：S2A_LDN_SERVER=lan 起局即开（开发 / 调试）；没给 S2A_LDN_SERVER 时游戏第一次初始化 ldn:u 自动开（OnLdnInitializing）——
        //   玩家不用去设置里拨开关，不用联机的游戏也永远不碰网络、不弹「本地网络」授权
        public static bool LdnLan => _lan;
        private static bool _lan;
        private static bool _lanStopping;
        private static bool _lanSessionStopped;
        private static readonly object _lanLock = new();
        private static LdnRelay _ldnRelay;
        private static string _ldnServerNow;
        private static readonly object _ldnSelectionLock = new();
        private static bool _ldnSelectionAvailable = true;
        // 自动开只试一次（原生层没有局域网发现就一直离线）；单测两条路径都要走，可以复位
        internal static bool LdnAutoTried { get; set; }
        internal static bool LdnRelayHosted => _ldnRelay != null;
        // 本进程里局域网发现起不来的原因，位或累计、只增不减（审计 P1-59）：1 宿主没有局域网发现（没登记 provider，如 Mac）；
        //   2 有 provider 但程序号 / 端口无效或启动返回失败。界面经 S2A_LanState（LdnExports）读，非 0 就给玩家说明（Mac：front_mac.m 横幅）
        internal static int LanUnavailable => System.Threading.Volatile.Read(ref _lanUnavailable);
        private static int _lanUnavailable;

        // 游戏初始化 ldn:u：按需启动已登记的平台发现；显式中继地址不自动发现。
        internal static void OnLdnInitializing()
        {
            lock (_lanLock)
            {
                if (_lanSessionStopped || LdnAutoTried || LdnServer != null)
                {
                    return;
                }

                LdnAutoTried = true;

                if (!StartLanDiscovery()) return;

                Logger.SetEnable(LogLevel.NetLog, true);
                StartLdnRelay();
                ApplyLanSelection();
                Console.Error.WriteLine($"[S2A 联机] 游戏初始化 ldn:u：自动进入局域网模式，先用中继 {Device.Configuration.MultiplayerLdnServer}（Bonjour 选举结果在建房 / 加入时生效）");
            }
        }

        // Host session retirement is terminal even though the platform provider
        // itself supports stop/start. Only the next Boot opens a new session.
        internal static void BeginLanDiscoverySession()
        {
            lock (_lanLock)
            {
                if (_lanStopping || _lan) throw new InvalidOperationException("上一联机会话未停止");
                _lanSessionStopped = false;
                LdnAutoTried = false;
            }
        }

        internal static unsafe bool StartLanDiscovery()
        {
            lock (_lanLock)
            {
                if (_lanSessionStopped) return false;
                if (_lanStopping)
                {
                    Red.Report("联机发现仍在停止", allowFailFast: false);
                    return false;
                }
                if (_lan) return true;
                var provider = Native.LanDiscovery;
                int port = Ryujinx.HLE.S2AHooks.LdnPort;
                if (provider == null || Native.ProgramId == null || port < 1 || port > ushort.MaxValue)
                {
                    System.Threading.Interlocked.Or(ref _lanUnavailable, provider == null ? 1 : 2);
                    Red.Report("联机发现不可用", "未登记 provider 或程序号/端口无效", allowFailFast: false);
                    return false;
                }
                int result = provider->Start(Native.ProgramId(), (ushort)port);
                if (result != 0)
                {
                    System.Threading.Interlocked.Or(ref _lanUnavailable, 2);
                    Red.Report("联机发现启动失败", $"错误码 {result}", allowFailFast: false);
                    return false;
                }
                _lan = true;
                return true;
            }
        }

        internal static unsafe void StopLanDiscovery()
        {
            LdnRelay relay;
            lock (_lanLock)
            {
                _lanSessionStopped = true;
                if (_lanStopping) return;
                if (_ldnRelay != null) _ldnRelay.RoomCountChanged = null;
                if (_lan) Native.LanDiscovery->Stop();
                _lan = false;
                relay = _ldnRelay;
                _ldnRelay = null;
                lock (_ldnSelectionLock)
                {
                    _ldnServerNow = null;
                    _ldnSelectionAvailable = true;
                }
                LdnAutoTried = false;
                _lanStopping = true;
            }
            try
            {
                // A relay callback may be waiting for _lanLock. Never join it
                // while holding that lock; it now observes _lan == false.
                relay?.Stop();
                relay?.Dispose();
            }
            finally
            {
                lock (_lanLock) _lanStopping = false;
            }
        }

        // 原生层（局域网选举）改用哪台中继：游戏下一次建房 / 加入生效（已在房间里的不打断）
        public static void SetLdnServer(string server)
        {
            // Never take _lanLock here: provider Stop may wait for this callback.
            lock (_ldnSelectionLock)
            {
                if (string.IsNullOrEmpty(server)) server = null;
                bool available = server != null;
                if (server == _ldnServerNow && available == _ldnSelectionAvailable) return;
                _ldnServerNow = server;
                _ldnSelectionAvailable = available;
                ApplyLanSelection();
                Console.Error.WriteLine(available
                    ? $"[S2A 联机] 中继改用 {server}:{Ryujinx.HLE.S2AHooks.LdnPort}"
                    : "[S2A 联机] 暂无局域网候选，保持离线");
            }
        }

        private static void ApplyLanSelection()
        {
            lock (_ldnSelectionLock)
            {
                if (Device == null) return;
                Device.Configuration.MultiplayerMode = _ldnSelectionAvailable ? MultiplayerMode.LdnRyu : MultiplayerMode.Disabled;
                Device.Configuration.MultiplayerLdnServer = _ldnSelectionAvailable ? (_ldnServerNow ?? "127.0.0.1") : string.Empty;
            }
        }

        private static void StartLdnRelay()
        {
            lock (_lanLock)
            {
                if (!_lanSessionStopped) StartLdnRelayLocked();
            }
        }

        private static void StartLdnRelayLocked()
        {
            System.Net.IPAddress address;

            if (_ldnRelay != null)
            {
                return;
            }

            if (LdnLan)
            {
                address = System.Net.IPAddress.Any;   // 局域网：别的设备要连得进来
            }
            else if (LdnServer == null || !System.Net.IPAddress.TryParse(LdnServer, out address) ||
                !(System.Net.IPAddress.IsLoopback(address) || Environment.GetEnvironmentVariable("S2A_LDN_RELAY") == "1"))
            {
                return;
            }

            string where = LdnLan ? "全部网卡" : LdnServer;
            _ldnRelay = LdnRelay.TryHost(address, Ryujinx.HLE.S2AHooks.LdnPort);
            Console.Error.WriteLine(_ldnRelay != null ? $"[S2A 联机] 本进程托管中继 {where}:{Ryujinx.HLE.S2AHooks.LdnPort}" : $"[S2A 联机] 中继 {where}:{Ryujinx.HLE.S2AHooks.LdnPort} 已由别的进程托管，本进程只当客户端");

            if (_ldnRelay != null && LdnLan)
            {
                // 本机中继有了房间 → Bonjour 发布名加「!」标记（没了去掉）：各设备选举优先有房间的中继，建房早于对方进联机菜单也能被找到
                _ldnRelay.RoomCountChanged = static n =>
                {
                    unsafe
                    {
                        lock (_lanLock)
                        {
                            if (_lan) Native.LanDiscovery->SetHosting(n > 0 ? 1 : 0);
                        }
                    }
                };
            }
        }

        // 系统语言：显式 S2A_SYSTEM_LANGUAGE 优先，否则跟设备系统首选语言（维护者 10-20：装上默认中文版，系统本身是中文）；地区不随语言变（缺省 USA，S2A_REGION 可改）
        // 带配置的会话（平台装配）：平台给了系统语言标签就按它映射，映射不了退回装配显式给的 Language；不碰 CoreFoundation（#1073）
        public static SystemLanguage Language => Configuration == null ? LegacyLanguage.Value
            : Configuration.SystemLanguageTag is Func<string> tag && SystemLocale.Map(tag()) is SystemLanguage mapped ? mapped
            : Configuration.Language;

        private static SystemLanguage PickLanguage()
        {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("S2A_SYSTEM_LANGUAGE")))
            {
                SystemLanguage l = EnvEnum("S2A_SYSTEM_LANGUAGE", SystemLanguage.AmericanEnglish);
                Console.Error.WriteLine($"[S2A 语言] 系统语言 {l}（依据：S2A_SYSTEM_LANGUAGE）");
                return l;
            }

            SystemLanguage d = SystemLocale.FromUi(Environment.GetEnvironmentVariable("S2A_UI_LANGUAGE"), SystemLocale.Preferred(), out string why);
            Console.Error.WriteLine($"[S2A 语言] 系统语言 {d}（依据：{why}）");
            return d;
        }

        public static Switch Device { get; private set; }
        private static bool _loggerInstalled;

        internal static void ShutdownSessionServices(Action checkFailure = null, Action stopHorizon = null)
        {
            Dispatcher dispatcher = Dispatcher.Instance;
            checkFailure?.Invoke();
            dispatcher.CloseSessions();
            checkFailure?.Invoke();
            if (stopHorizon == null) HorizonHost.Stop();
            else stopHorizon();
            checkFailure?.Invoke();
            NativeTickSource.StopCatchUp();
            checkFailure?.Invoke();
            DisposeAudioForShutdown();
            checkFailure?.Invoke();
            Device.System.ServiceTable.Dispose();
            checkFailure?.Invoke();
            dispatcher.Reset();
            checkFailure?.Invoke();
            Device.Dispose();
            checkFailure?.Invoke();
        }

        internal static void FinishShutdownSession()
        {
            // GPU callbacks 已退出，才清除 guest view、静态服务与设备引用。
            HorizonHost.Reset();
            GuestMemory.ResetSession();
            Application.Reset();
            Aoc.Reset();
            SystemDataSeen.Clear();
            Ryujinx.HLE.S2ASessionState.End();
            Ryujinx.HLE.S2AHooks.CreateServiceMemory = null;
            Device = null;
            Configuration = null;
            MemDiag.FootprintProvider = null;
            ReloadSessionEnvironment();
            // 启动闸随会话退休放开：进程内重启（设置页切 60 帧「立刻重启」）的新会话还要 Boot 一次。原先只在 Boot 失败时放开，
            //   11-02 测试设备1 一款第一方动作冒险游戏自动复现：窗口重建过了，新会话 Boot 抛「S2A 服务层已开始启动」、会话 2 FAILED
            lock (SaveTransfer.HostGate) SaveTransfer.HostStarted = false;
        }

        // 已打过「[S2A 系统数据]」行的（号, 入口）：每号每入口只打一次
        private static readonly System.Collections.Generic.HashSet<(ulong, string)> SystemDataSeen = new();

        // baseDir：Ryujinx 系统数据根（系统存档、bis、账号等）。iOS 为 App 沙盒内目录，Mac 由起局方给。
        // 找不到时区数据目录时，从宿主自带的 IANA 时区库一次性生成（与 systemdata/make_tzdata.sh 同一转换：取 TZif2 的 64 位段）
        private static string GenerateTimeZoneData(string baseDir)
        {
            const string Src = "/usr/share/zoneinfo";
            string dst = Path.Combine(baseDir, "tzdata");

            if (File.Exists(Path.Combine(dst, "binaryList.txt")))
            {
                return dst;
            }

            if (!Directory.Exists(Src))
            {
                return null;
            }

            string tmp = dst + ".tmp";

            if (Directory.Exists(tmp))
            {
                Directory.Delete(tmp, true);
            }

            System.Collections.Generic.List<string> names = [];

            foreach (string f in Directory.EnumerateFiles(Src, "*", SearchOption.AllDirectories))
            {
                string rel = Path.GetRelativePath(Src, f);

                if (!char.IsAsciiLetterUpper(rel[0]) || rel.StartsWith("posix/") || rel.StartsWith("right/") || rel.Contains('.'))
                {
                    continue;
                }

                byte[] b = File.ReadAllBytes(f);

                if (b.Length < 44 || b[0] != 'T' || b[1] != 'Z' || b[2] != 'i' || b[3] != 'f' || b[4] < '2')
                {
                    continue;
                }

                int Be(int o) => System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(b.AsSpan(o));
                int v1 = Be(32) * 5 + Be(36) * 6 + Be(40) + Be(28) * 8 + Be(24) + Be(20);

                if (44 + v1 + 4 > b.Length || b[44 + v1] != 'T')
                {
                    continue;
                }

                string outFile = Path.Combine(tmp, "zoneinfo", rel);
                Directory.CreateDirectory(Path.GetDirectoryName(outFile));
                File.WriteAllBytes(outFile, b[(44 + v1)..]);
                names.Add(rel);
            }

            names.Sort(StringComparer.Ordinal);
            File.WriteAllLines(Path.Combine(tmp, "binaryList.txt"), names);

            if (Directory.Exists(dst))
            {
                Directory.Delete(dst, true);
            }

            Directory.Move(tmp, dst);
            Console.Error.WriteLine($"S2A 时区数据：从宿主 IANA 库生成 {names.Count} 个区 → {dst}");
            return dst;
        }

        private static string FirstDirWith(string file, params string[] dirs)
        {
            foreach (string d in dirs)
            {
                if (!string.IsNullOrEmpty(d) && File.Exists(Path.Combine(d, file)))
                {
                    return d;
                }
            }

            return null;
        }

        private static string TimeZoneDataDir(HostConfiguration configuration)
        {
            string game = configuration?.GameDirectory ?? Environment.GetEnvironmentVariable("S2A_GAME_DATA");
            string[] candidates =
            [
                string.IsNullOrEmpty(game) ? null : Path.Combine(game, "systemdata", "010000000000080E"),
                configuration == null ? Environment.GetEnvironmentVariable("S2A_TZDATA") : null,
            ];

            foreach (string c in candidates)
            {
                if (!string.IsNullOrEmpty(c) && File.Exists(Path.Combine(c, "binaryList.txt")))
                {
                    return c;
                }
            }

            return null;
        }

        internal sealed class InvalidSessionTimeZoneException : InvalidOperationException
        {
            internal InvalidSessionTimeZoneException(string zone)
                : base("Session time zone is absent from game system data: " + zone) { }
        }

        // Validate before constructing renderer/audio resources. Host.Boot checks
        // again at use time; this preflight does not eliminate filesystem races.
        internal static void ValidateConfigurationTimeZone(HostConfiguration configuration)
        {
            if (configuration == null || configuration.TimeZone == "UTC") return;
            string data = TimeZoneDataDir(configuration);
            if (data == null || !File.Exists(Path.Combine(data, "zoneinfo", configuration.TimeZone)))
                throw new InvalidSessionTimeZoneException(configuration.TimeZone);
        }

        // 固定起始时钟（同真值 Ryujinx 命令行定的系统时间，画面对拍用）：S2A_SYSTEM_TIME=<Unix 秒>，游戏开机时的系统时间 = 该值，之后照常走。
        // Ryujinx 的 SystemTimeOffset 加在宿主 UTC 上
        private static long SystemTimeOffset()
        {
            string v = Environment.GetEnvironmentVariable("S2A_SYSTEM_TIME");

            if (string.IsNullOrEmpty(v))
            {
                return 0;
            }

            if (!long.TryParse(v, out long t))
            {
                Red.Report("S2A_SYSTEM_TIME 不是 Unix 秒", v);
                return 0;
            }

            return t - DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        }

        // 环境变量按枚举名取值（如 Japanese / Japan），没给用缺省，给错报红
        private static T EnvEnum<T>(string name, T fallback) where T : struct, Enum
        {
            string v = Environment.GetEnvironmentVariable(name);

            if (string.IsNullOrEmpty(v))
            {
                return fallback;
            }

            if (Enum.TryParse(v, ignoreCase: true, out T r) && Enum.IsDefined(r))
            {
                return r;
            }

            Red.Report($"{name} 不是 {typeof(T).Name} 的取值", v);
            return fallback;
        }

        private static unsafe void HookIpcAddr39()
        {
            if (System.Runtime.InteropServices.NativeLibrary.TryGetExport(System.Runtime.InteropServices.NativeLibrary.GetMainProgramHandle(), "s2a_ipc_addr39", out nint f))
            {
                Ryujinx.HLE.S2AHooks.IpcAddr39 = (delegate* unmanaged<ulong, ulong>)f;
                Ryujinx.Horizon.S2AHorizonHooks.IpcAddr39 = (delegate* unmanaged<ulong, ulong>)f;
            }
        }

        // 原生核心 s2a_nro_map / s2a_nro_unmap（runtime/src/loader.c，各端 DirectPInvoke 静态链）：按 Native 集中声明的导入登记，不按名找导出（平台扫描门禁）
        private static unsafe void HookNro()
        {
            Ryujinx.HLE.S2AHooks.NroMap = &Native.NroMap;
            Ryujinx.HLE.S2AHooks.NroUnmap = &Native.NroUnmap;
        }

        private static unsafe System.Memory<byte>? GuestViewOf(ulong va, int size) =>
            GuestMemory.Det ? null : new Ryujinx.Memory.NativeMemoryManager<byte>((byte*)va, size).Memory;

        public static Dispatcher Boot(IRenderer renderer, IHardwareDeviceDriver audio, string baseDir, HostConfiguration configuration = null,
            Action<Exception> serviceFailure = null)
        {
            lock (SaveTransfer.HostGate)
            {
                if (SaveTransfer.HostStarted) throw new InvalidOperationException("S2A 服务层已开始启动");
                SaveTransfer.HostStarted = true;
            }
            try
            {
                BeginLanDiscoverySession();
                return BootCore(renderer, audio, baseDir, configuration, serviceFailure);
            }
            catch
            {
                lock (SaveTransfer.HostGate)
                {
                    if (Device == null) SaveTransfer.HostStarted = false;
                }
                throw;
            }
        }

        private static Dispatcher BootCore(IRenderer renderer, IHardwareDeviceDriver audio, string baseDir,
            HostConfiguration configuration, Action<Exception> serviceFailure)
        {
            // 带配置的会话只用平台登记的读数：没给就是「取不到」（-1），不落到苹果 libSystem（#1073）
            MemDiag.FootprintProvider = configuration == null ? null : configuration.MemoryFootprint ?? (() => -1);
            MemDiag.Startup();   // 起局一行 GC 配置 / 进程内存；S2A_MEMPROBE=1 时先做托管内存上限探测

            if (Device != null)
            {
                throw new InvalidOperationException("S2A 服务层已启动");
            }
            Ryujinx.Common.S2AShutdown.Reset();
            Ryujinx.HLE.S2ADirect.BeginSession();
            Red.Reset();
            Logger.S2AResetStubHits();
            Ryujinx.Common.S2AThreadAlloc.ResetSession();

            Configuration = configuration;
            // 持久数据根（系统存档、bis、账号）：平台装配给了 SaveDirectory 就用它（#1073），否则照旧用起局方给的 baseDir
            if (configuration?.SaveDirectory != null) baseDir = configuration.SaveDirectory;

            // Ryujinx 日志：关逐条调用级（Trace / Debug）；「桩」级单独计数——上游对一部分命令写了占位实现（记一行 Stubbed 后回成功），
            // 那是参照实现的取舍，不算我方缺口，但要看得见：每个桩首次打一行【桩】，退出汇总
            Logger.SetEnable(LogLevel.Trace, false);
            Logger.SetEnable(LogLevel.Debug, false);
            Logger.SetEnable(LogLevel.Stub, true);   // 上游 Logger 缺省不建 Stub 级（Logger.Stub 为 null），不开就一条桩都收不到、汇总行假空
            Logger.SetEnable(LogLevel.Guest, true);  // 游戏经 lm 写的日志（八方2 SDK 初始化自退的原因就写在里面），排查常要，量小
            Logger.SetEnable(LogLevel.NetLog, LdnServer != null);   // 开了联机才打：RyuLdn 客户端连上 / 断开 / 出错只在这一级（排查中继连不上、扫描没结果）
            if (!_loggerInstalled)
            {
                Logger.Updated += static (_, e) =>
                {
                    if (e.Level == LogLevel.Stub) Red.Stub(e.Message);
                };
                _loggerInstalled = true;
            }

            Ryujinx.HLE.S2AHooks.Red = static what => Red.Report(what);
            Ryujinx.HLE.S2AHooks.LdnInitializing = OnLdnInitializing;   // 游戏第一次初始化 ldn:u → 按需进局域网模式（见 OnLdnInitializing）
            // fs 命令失败（上游原样把结果回给游戏、不打日志；游戏不查结果就会在远处崩，如 10-26 普查双点医院开文件失败后拿空文件对象写存档）
            Ryujinx.HLE.S2AHooks.FsFailed = static (what, detail, red) =>
            {
                if (red)
                {
                    Red.Report($"fs 失败：{what}", detail);
                }
                else
                {
                    Red.Note($"[fs] 没有 {what}", detail);
                }
            };
            Directory.CreateDirectory(baseDir);

            // 时区系统数据（010000000000080E）：游戏数据目录的 systemdata/ 下，或 S2A_TZDATA 指定；内容是 IANA 时区库（services/systemdata/make_tzdata.sh 生成）
            string tz = TimeZoneDataDir(configuration) ?? (configuration == null ? GenerateTimeZoneData(baseDir) : null);
            Ryujinx.HLE.S2AHooks.TimeZoneDataDir = tz;
            // 共享字体（0100000000000810–0814 的原始 .bfttf）：游戏数据的 systemdata/fonts/，或 S2A_SHARED_FONT_DIR
            Ryujinx.HLE.S2AHooks.SharedFontDir = FirstDirWith("nintendo_udsg-r_std_003.bfttf",
                string.IsNullOrEmpty(configuration?.GameDirectory ?? Environment.GetEnvironmentVariable("S2A_GAME_DATA")) ? null : Path.Combine(configuration?.GameDirectory ?? Environment.GetEnvironmentVariable("S2A_GAME_DATA"), "systemdata", "fonts"),
                configuration == null ? Environment.GetEnvironmentVariable("S2A_SHARED_FONT_DIR") : null);

            // 系统数据（如 0100000000000802 Mii 资源、0100000000000823 屏蔽词）：游戏数据的 systemdata/<号>/，按需打开的 RomFS 镜像（同游戏 RomFS）
            string game = configuration?.GameDirectory ?? Environment.GetEnvironmentVariable("S2A_GAME_DATA");
            Ryujinx.HLE.S2AHooks.SystemDataRoot = string.IsNullOrEmpty(game) ? null : Path.Combine(game, "systemdata");
            // 游戏内存原地视图（游戏地址 = 宿主地址）：AM 传输内存存储不再按大小拷一份托管数组；确定性档要经 det 写回，不给视图（照旧拷贝）
            Ryujinx.HLE.S2AHooks.GuestView = GuestViewOf;
            // IPC 缓冲描述符地址补回第 39 位（macOS 别名区伸到 2^39 之上，native svc_mem.c s2a_ipc_addr39）；宿主没导出（单测）= 原样
            HookIpcAddr39();
            // nn::ro 装 NRO（ldr:ro LoadNro / UnloadNro）：映射出包时改写好、编进 App 的 NRO 映像（runtime/src/loader.c s2a_nro_map）；上游路径要 Ryujinx 内核进程对象，S2Arm 没有，一律走原生
            HookNro();
            Ryujinx.HLE.S2AHooks.OpenSystemDataStorage = static id =>
                Ryujinx.HLE.S2AHooks.SystemDataDir(id) is string dir ? Application.RomFsFromDirectory(dir) : null;
            // 游戏 / 系统服务要了哪个系统数据号：每号每入口打一行（出包期核对表 pack/sysdata_need.tsv 按这行普查；缺的号随后由上游路径报红）
            Ryujinx.HLE.S2AHooks.SystemDataAsked = static (id, via, found) =>
            {
                lock (SystemDataSeen)
                {
                    if (!SystemDataSeen.Add((id, via)))
                    {
                        return;
                    }
                }

                Console.Error.WriteLine($"[S2A 系统数据] {id:X16} {(found ? "在" : "缺")} {via}");
            };

            Native.Mark("服务：时区 / 字体 / 系统数据\0"u8);

            // 设备时区：S2A_TIMEZONE（IANA 名，对真值 / 带存档起局时与真值同为 UTC）优先，否则跟宿主
            string zoneWanted = configuration?.TimeZone ?? Environment.GetEnvironmentVariable("S2A_TIMEZONE");
            string deviceZone = configuration == null && tz != null && File.Exists(Path.Combine(tz, "zoneinfo", TimeZoneInfo.Local.Id)) ? TimeZoneInfo.Local.Id : "UTC";

            if (!string.IsNullOrEmpty(zoneWanted))
            {
                if ((configuration != null && zoneWanted == "UTC") || (tz != null && File.Exists(Path.Combine(tz, "zoneinfo", zoneWanted))))
                {
                    deviceZone = zoneWanted;
                }
                else
                {
                    if (configuration != null) throw new InvalidSessionTimeZoneException(zoneWanted);
                    Red.Report("S2A_TIMEZONE 在时区数据里没有", zoneWanted);
                }
            }

            Directory.CreateDirectory(baseDir);
            AppDataManager.Initialize(baseDir);

            VirtualFileSystem vfs = VirtualFileSystem.CreateInstance();
            LibHacHorizonManager libHac = new();
            libHac.InitializeFsServer(vfs);
            libHac.InitializeArpServer();
            libHac.InitializeBcatServer();
            libHac.InitializeSystemClients();

            ContentManager content = new(vfs);
            content.LoadEntries(); // Ryujinx 界面启动时做的一步；不做则 Horizon 服务（ngc 等）挂载系统数据时查不到存储位置而崩
            AccountManager account = new(libHac.RyujinxClient, null);
            UserChannelPersistence channel = Channel;   // 进程级，跨重启存活（见 Channel）

            if (LdnServer == "lan") StartLanDiscovery();
            // 游戏不支持系统语言时的退路：只从宿主主语言出发（Host.Language：显式指定 → 平台标签 → 宿主首选第一项），见 SystemLocale.TitleFallback
            Ryujinx.HLE.S2AHooks.TitleLanguageFallback = SystemLocale.TitleFallback(Language);
            // 显式指定的系统语言（env.txt 也算）：游戏的控制数据没声明支持语言时仍按它回（IApplicationFunctions.GetDesiredLanguage）
            Ryujinx.HLE.S2AHooks.ExplicitSystemLanguage = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("S2A_SYSTEM_LANGUAGE"));
            HleConfiguration config = new HleConfiguration(
                MemoryConfiguration.MemoryConfiguration4GiB,
                Language,                         // 缺省跟设备系统首选语言（SystemLocale.cs）；带存档 / 对真值时 S2A_SYSTEM_LANGUAGE 与存档语言一致（如01006F8002326000存档 Japanese）
                configuration?.Region ?? EnvEnum("S2A_REGION", RegionCode.USA),
                VSyncMode.Switch,
                enableDockedMode: Docked,         // 缺省掌机档（维护者 10-20 晚）；S2A_DOCKED=1 切主机（以后做成玩家设置）
                enablePtc: false,                 // 不用 Ryujinx 的 CPU 翻译缓存
                ITickSource.RealityTickScalar,
                enableInternetAccess: false,
                IntegrityCheckLevel.None,
                fsGlobalAccessLogMode: 0,
                systemTimeOffset: configuration == null ? SystemTimeOffset() : 0,
                timeZone: deviceZone,             // 设备时区跟宿主（有时区数据时）
                MemoryManagerMode.SoftwarePageTable, // 只承载服务自有内存；共享后备由平台 composition 决定
                ignoreMissingServices: false,     // 铁律 2：缺服务 / 缺命令必须报红
                AspectRatio.Fixed16x9,
                audioVolume: 1.0f,
                useHypervisor: false,
                multiplayerLanInterfaceId: "0",
                !LdnLan && (LdnServer == null || LdnServer == "lan") ? MultiplayerMode.Disabled : MultiplayerMode.LdnRyu,
                multiplayerDisableP2p: true,      // 不开 UPnP 直连，数据全走中继
                multiplayerLdnPassphrase: Environment.GetEnvironmentVariable("S2A_LDN_PASSPHRASE") ?? string.Empty,
                multiplayerLdnServer: LdnLan ? (_ldnServerNow ?? "127.0.0.1") : LdnServer == "lan" ? string.Empty : LdnServer ?? string.Empty,   // 局域网：选举出结果前先用本机中继
                enableGdbStub: false,
                gdbStubPort: 0,
                debuggerSuspendOnStart: false,
                customVSyncInterval: 60)
                .Configure(vfs, libHac, content, account, channel, renderer, audio, configuration?.UserInterface ?? new HostUi());

            // Horizon 新框架服务在 Switch 构造时启动：挂钩要先装（服务改由我方线程以原生系统调用启动）
            GuestMemory memory = new();
            // Install the single failure owner only after configuration and time
            // zone validation, but before any Horizon service thread can start.
            if (serviceFailure != null) HorizonHost.ObserveFailures(serviceFailure);
            HorizonHost.InstallHooks(memory);

            // 计数器与游戏同源（见 NativeTickSource）：Horizon 建内核 / 时间服务时取用
            Ryujinx.HLE.S2AHooks.TickSource = NativeTickSource.Available ? new NativeTickSource() : null;
            Ryujinx.HLE.S2AHooks.TickUnseenNs = NativeTickSource.UnseenAvailable ? NativeTickSource.UnseenNs : null;   // 稳态时钟补后台 / 睡眠时长（#863）

            // The native Android alias operation requires shared backing from creation.
            // Keep the CPU software page table; this only selects the service-owned block.
            Ryujinx.HLE.S2AHooks.CreateServiceMemory = configuration?.ServiceMemoryFactory;
            Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg = configuration?.ScreenshotEncoder ?? Exports.ScreenshotEncoder;
            StartLdnRelay();
            Device = new Switch(config);
            if (_lan) ApplyLanSelection();
            Native.Mark("服务：Ryujinx Switch 建（Horizon 服务线程起）\0"u8);

            // Ryujinx 在游戏进程 Start 时做的一步（ProcessResult.Start）：带设备重载内容表，顺带初始化时区、证书、共享字体
            content.LoadEntries(Device);

            Dispatcher d = new(Device, memory);
            HorizonHost.Ready();
            NativeTickSource.BindCatchUp();
            Lifecycle.Attach();   // 焦点 / 底座 / 失焦暂停接线（接口 v2.15，缺口扫描族 1 / 2）
            if (configuration == null)
            {
                if (serviceFailure != null)
                    HorizonHost.WaitServicesReady(Device.System.ServiceTable, TimeSpan.FromSeconds(10));
                else if (!Device.System.ServiceTable.WaitServicesReady(10_000))
                    throw new TimeoutException("Horizon 服务未在 10 秒内全部登记就绪，禁止启动游戏");
            }
            Native.Mark("服务：内容表 / 分发器就绪\0"u8);
            return d;
        }
    }

    // 系统小程序 / 宿主界面：S2Arm 的苹果侧界面未接前一律报红（不假装用户点了确定）。
    // 手柄设置、选用户、软键盘和错误提示提供零配置应答；其他未接界面按 Red 严格模式策略处理。
    // 各端共用（public）：Android 登记的也是这份实现，平台相关部分经挂点接进来。
    public sealed class HostUi : IHostUIHandler, IAsyncTextInput
    {
        public IHostUITheme HostUITheme => null;

        // Apple 系统输入框异步接口；未登记时小程序回落到 DisplayInputDialog。
        public IDisposable BeginTextInput(SoftwareKeyboardUIArgs args, Action<bool, string> done) => TextInput.Begin(args, done);

        // 前台软键盘的平台挂点：Android 登记真实 broker；未登记时使用零配置应答。
        public Func<SoftwareKeyboardUIArgs, string> SoftwareKeyboard { get; set; }

        // 软键盘（前台）：真机上直接按确定 = 交回游戏给的默认文本；没有默认文本就交一个合法短名（数字键盘交 0）。
        // 长度下限 / 上限与游戏自校验由 Ryujinx 小程序按配置处理
        public bool DisplayInputDialog(SoftwareKeyboardUIArgs args, out string userText)
        {
            if (SoftwareKeyboard != null)
            {
                userText = SoftwareKeyboard(args);
                return userText != null;
            }

            userText = !string.IsNullOrEmpty(args.InitialText) ? args.InitialText : args.KeyboardMode == KeyboardMode.Numeric ? "0" : "Player";
            Console.Error.WriteLine($"S2A 软键盘小程序自动应答：「{userText}」（模式 {args.KeyboardMode}，长度 {args.StringLengthMin}–{args.StringLengthMax}，标题「{args.HeaderText}」）");
            return true;
        }

        public bool DisplayMessageDialog(string title, string message)
        {
            Red.Report("宿主界面未接：消息框", title);
            return false;
        }

        private int _controllerStuck;

        // 手柄设置小程序：真机上唯一手柄按「确定」即被分到游戏收的第一个手柄号。这里把唯一的虚拟手柄改配过去
        // （已发现外接手柄时优先 Pro / 双 Joy-Con；否则掌机能收就留掌机），等 HID 采样泵写进共享内存后回 true，
        // 小程序循环重验通过即回游戏。已配好仍连着 3 次不过 = 游戏要的配置一个手柄给不了（如要 2 人起），报红交回游戏
        public bool DisplayMessageDialog(ControllerAppletUIArgs args)
        {
            // 游戏声明至少 2 人（强制本地合作）：真机上要再连一个手柄，这里开出第二个虚拟手柄（InputPump.SetPads，镜像第一个的输入）
            // 先按上限收回多的（#809：要 1 人、连着两个时原先照配两格，重验不过反复重开），再按下限补开
            InputPump.CapPads(Host.Device, args.PlayerCountMax);
            if (args.PlayerCountMin > InputPump.Pads) InputPump.SetPads(Host.Device, args.PlayerCountMin);
            var players = new System.Collections.Generic.List<PlayerIndex>(args.SupportedPlayers);
            PlayerIndex player;
            ControllerType type;
            ControllerType externalType = (args.SupportedStyles & ControllerType.ProController) != 0 ? ControllerType.ProController
                                        : (args.SupportedStyles & ControllerType.JoyconPair) != 0 ? ControllerType.JoyconPair : ControllerType.None;

            if ((InputPump.ExternalController || InputPump.Pads > 1) && players.Exists(p => p != PlayerIndex.Handheld) && externalType != ControllerType.None)
            {
                (player, type) = (players.Find(p => p != PlayerIndex.Handheld), externalType);
            }
            else if (!args.IsDocked && (args.SupportedStyles & ControllerType.Handheld) != 0 && players.Contains(PlayerIndex.Handheld))
            {
                (player, type) = (PlayerIndex.Handheld, ControllerType.Handheld);
            }
            else
            {
                player = players.Find(p => p != PlayerIndex.Handheld);
                // 游戏只收单只 Joy-Con（如 Zumba：样式 JoyconLeft / JoyconRight）：真机上小程序让玩家横握一只确认，HID 照报这只的物理键、
                //   方向由游戏按样式自己解释（Ryujinx 同样不旋转）。唯一的虚拟手柄改配成单只：优先右只（有 + 和 ABXY），不收再左只
                ControllerType single = (args.SupportedStyles & ControllerType.JoyconRight) != 0 ? ControllerType.JoyconRight
                                      : (args.SupportedStyles & ControllerType.JoyconLeft) != 0 ? ControllerType.JoyconLeft : ControllerType.None;
                type = externalType != ControllerType.None ? externalType : single;

                if (!players.Exists(p => p != PlayerIndex.Handheld) || type == ControllerType.None)
                {
                    Red.Report("手柄设置小程序：没有可配的手柄号 / 样式", $"样式 {args.SupportedStyles} 手柄号 {string.Join(",", players)}");
                    return false;
                }
            }

            // 这里可选的 Pro / Handheld / JoyconPair / JoyconLeft / JoyconRight 与共享内存 FullKey / Handheld / JoyDual / JoyLeft / JoyRight 位值相同。
            uint expectedStyle = (uint)type;
            if (InputPump.Player == player && (uint)Host.Device.Hid.SharedMemory.Npads[(int)player].InternalState.StyleSet == expectedStyle)
            {
                if (++_controllerStuck >= 3)
                {
                    Red.Report("手柄设置小程序：一个手柄满足不了游戏要求", $"人数 {args.PlayerCountMin}–{args.PlayerCountMax} 样式 {args.SupportedStyles} 手柄号 {string.Join(",", players)}");
                    _controllerStuck = 0;
                    return false;
                }
            }
            else
            {
                _controllerStuck = 0;
                InputPump.SetPrimary(Host.Device, player, type);
            }

            // 等采样泵（约 16 ms 一拍）把新样式写进共享内存，小程序的重验读的是那里
            for (int i = 0; i < 20 && (uint)Host.Device.Hid.SharedMemory.Npads[(int)player].InternalState.StyleSet != expectedStyle; i++)
            {
                System.Threading.Thread.Sleep(10);
            }

            string pads = InputPump.SecondPlayer != PlayerIndex.Unknown ? $"两个手柄配到 {InputPump.Player} + {InputPump.SecondPlayer}" : $"唯一手柄配到 {player}";
            Console.Error.WriteLine($"S2A 手柄设置小程序自动应答：{pads}（{type}）；游戏要 人数 {args.PlayerCountMin}–{args.PlayerCountMax} 样式 {args.SupportedStyles}");
            return true;
        }

        public bool DisplayCabinetDialog(out string userText)
        {
            Red.Report("宿主界面未接：amiibo 设置");
            userText = null;
            return false;
        }

        public void DisplayCabinetMessageDialog() => Red.Report("宿主界面未接：amiibo 消息");

        // 同程序重启（刺客信条 艾吉奥合集：标题页按 A 后 ExecuteProgram(ExecuteProgram, 0) 要求用同一程序重启）。
        //   Ryujinx 真值（界面层）：通道记 PreviousIndex = Index、Index = value，停模拟、按 Index 重新加载同一个包里的那支程序。
        //   同序号或 RestartProgram 走进程内重启；别的序号 = 多程序合集切程序（索尼克×夏特 世代重启：主菜单选游戏后 ExecuteProgram(1)），
        //   包里有这一支（游戏数据 programs/<n>/ 与原生模块目录都在）就同一条重启通道切过去，没有就报红、不改通道、不重启
        public void ExecuteProgram(Switch device, ProgramSpecifyKind kind, ulong value)
        {
            UserChannelPersistence channel = Host.Channel;
            bool same = kind == ProgramSpecifyKind.RestartProgram || (kind == ProgramSpecifyKind.ExecuteProgram && value == (ulong)channel.Index);
            if (!same)
            {
                SwitchProgram(channel, kind, value);
                return;
            }
            channel.ExecuteProgram(kind, value);
            int rc = Host.RequestRestart();
            if (rc != 0) Red.Report("ExecuteProgram：同程序重启发起失败", $"{kind} 序号 {value}，s2a_host_restart = {rc}");
            else Console.Error.WriteLine($"S2A 同程序重启：游戏请求 {kind} 序号 {value}，已发起进程内重启（上一序号 {channel.PreviousIndex}）");
        }

        // 切到同一个包里的另一支程序。顺序：核包里有 → 原生登记下一局序号 → 发起重启 → 受理了才改通道。
        //   重启受理后旧局要先停稳（含正在答这条请求的服务线程返回），新局 Application.Register 才读通道，所以受理后再改通道不会被抢先读；
        //   没受理就把原生登记改回当前序号、通道不动——游戏继续跑当前程序，GetPreviousProgramIndex 不被污染
        private static void SwitchProgram(UserChannelPersistence channel, ProgramSpecifyKind kind, ulong value)
        {
            string why = $"{kind} 序号 {value}，当前序号 {channel.Index}";
            if (kind != ProgramSpecifyKind.ExecuteProgram)
            {
                Red.Report("ExecuteProgram：未支持的程序指定方式", why);   // SubApplicationProgram：Ryujinx 也未实现（NotImplementedException）
                return;
            }
            int count = Application.ProgramCount(Application.GameDir);
            if (value >= (ulong)count)
            {
                Red.Report("ExecuteProgram：多程序合集包里没有这一支程序", $"{why}，游戏数据里 {count} 支（序号 0..{count - 1}，序号 n 在 programs/<n>/）");
                return;
            }
            int index = (int)value;
            int rc = Host.SelectProgram(index);
            if (rc != 0)
            {
                Red.Report("ExecuteProgram：多程序合集切程序未受理（原生）", $"{why}，s2a_host_select_program = {rc}");
                return;
            }
            rc = Host.RequestRestart();
            if (rc != 0)
            {
                int back = Host.SelectProgram(channel.Index);
                Red.Report("ExecuteProgram：多程序合集切程序重启发起失败", $"{why}，s2a_host_restart = {rc}，原生登记改回当前序号 = {back}");
                return;
            }
            channel.ExecuteProgram(kind, value);
            Console.Error.WriteLine($"S2A 多程序合集：游戏请求切到序号 {value}，已发起进程内重启（上一序号 {channel.PreviousIndex}）");
        }

        // 错误小程序（游戏用 nn::err::ShowError 显示系统错误码 / 自定义文案）：真机上玩家看完按确定回游戏，这里自动按确定（返回 false = 没按「详情」）。
        //   第四个零配置自动应答的小程序；文案进标准错误（没有系统固件时是上游的通用文案，错误码在标题里）
        public bool DisplayErrorAppletDialog(string title, string message, string[] buttonsText, (uint Module, uint Description)? errorCode = null)
        {
            Console.Error.WriteLine($"S2A 错误小程序自动应答（确定）：{title}｜{message.Replace("\n", " ").Trim()}");
            return false;
        }

        public IDynamicTextInputHandler CreateDynamicTextInputHandler()
        {
            Red.Report("宿主界面未接：内嵌软键盘");
            return null;
        }

        // 选用户小程序：答当前用户——游戏库里选的本地玩家（LocalPlayer.cs，#623）；带存档起局时是存档的用户（Saves.SelectUser）。玩家已在起局前选过，这里不再弹
        public UserProfile ShowPlayerSelectDialog()
        {
            UserProfile user = Host.Device.System.AccountManager.LastOpenedUser;
            Console.Error.WriteLine($"S2A 选用户小程序自动应答：{user.UserId}");
            return user;
        }

        public void TakeScreenshot() => Red.Report("宿主界面未接：截图");
    }
}
