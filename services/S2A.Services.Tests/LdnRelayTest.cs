using LibHac.Common;
using LibHac.Loader;
using LibHac.Ns;
using Ryujinx.HLE.HOS.Services.Ldn.Types;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu;
using Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.Types;
using Ryujinx.HLE.HOS.Services.Sockets.Bsd.Proxy;
using Ryujinx.HLE.Loaders.Processes;
using Ryujinx.Horizon;
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    // 本地无线联机中继：两个 Ryujinx RyuLdn 客户端（游戏 ldn:u 背后那一份，LdnMasterProxyClient）连同一个 LdnRelay。
    //   期望按 nn::ldn 语义写：A 建房后 B 按本地通信号扫到 1 个房间（人数 1、主机名 / 广告数据原样），别的本地通信号扫到 0 个；
    //   B 进房成功，A 收到同步、人数变 2；A 关网后 B 被断开。虚拟 IP 在 10.114.0.0/16。
    public static unsafe partial class Program
    {
        [SoloTest("--ldn-manual-client")]
        private static int LdnManualClient()
        {
            Environment.SetEnvironmentVariable("S2A_LDN_SERVER", "127.0.0.1");
            Environment.SetEnvironmentVariable("S2A_LDN_RELAY", "0");
            Host.BeginLanDiscoverySession();
            try
            {
                var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static;
                typeof(Host).GetMethod("StartLdnRelay", flags).Invoke(null, null);
                Host.OnLdnInitializing();
                return Host.LdnRelayHosted || Host.LdnLan || Host.LdnAutoTried ? 1 : 0;
            }
            finally { Host.StopLanDiscovery(); }
        }

        [SoloTest("--ldn-manual-listen")]
        private static int LdnManualListen()
        {
            // 独立进程：在 Host 首次访问前设环境。实际检查 socket 绑定，不只检查配置字符串。
            Environment.SetEnvironmentVariable("S2A_LDN_SERVER", "127.0.0.1");
            Environment.SetEnvironmentVariable("S2A_LDN_RELAY", "1");
            Environment.SetEnvironmentVariable("S2A_LDN_LISTEN", "0.0.0.0");
            Ryujinx.HLE.S2AHooks.LdnPort = FreeTcpPort(IPAddress.Any);
            Host.BeginLanDiscoverySession();
            try
            {
                var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static;
                typeof(Host).GetMethod("StartLdnRelay", flags).Invoke(null, null);
                var relay = (LdnRelay)typeof(Host).GetField("_ldnRelay", flags).GetValue(null);
                if (relay == null || relay.Endpoint is not IPEndPoint endpoint || !endpoint.Address.Equals(IPAddress.Any)) return 1;
                using TcpClient client = new();
                client.Connect(IPAddress.Loopback, Ryujinx.HLE.S2AHooks.LdnPort);
                Console.WriteLine("指定模式：全部网卡监听、回环连接成功、不启动发现");
                return Host.LdnLan ? 1 : 0;
            }
            finally { Host.StopLanDiscovery(); }
        }

        [SoloTest("--lan-provider-lifecycle")]
        private static int LanProviderLifecycle()
        {
            int failures = 0;
            void Expect(bool ok, string name) { Console.WriteLine($"{name}: {(ok ? "✓" : "✗")}"); if (!ok) failures++; }
            long red = Red.Total;
            // 审计 P1-59：发现起不来的原因对界面可读（Host.LanUnavailable，导出 S2A_LanState）：独立进程起始 0；没登记 provider +1；
            //   有 provider 但端口无效 / 启动返回负 errno +2；成功启动不清。旧代码不记 → 判红
            Expect(Host.LanUnavailable == 0, "原因位起始 0");
            Expect(!Host.StartLanDiscovery() && !Host.LdnLan && Red.Total == red + 1, "未登记报红而非崩溃/假成功");
            Expect(Host.LanUnavailable == 1, "没登记 provider 记原因位 1（界面据此说明这台设备不能局域网联机）");
            Host.StopLanDiscovery();
            FakeNative.Install();
            Host.BeginLanDiscoverySession();
            int port = Ryujinx.HLE.S2AHooks.LdnPort;
            try
            {
                Ryujinx.HLE.S2AHooks.LdnPort = 65536;
                Expect(!Host.StartLanDiscovery() && FakeNative.LdnLanStarts == 0, "越界端口不截断/不调 provider");
                Expect(Host.LanUnavailable == 3, "端口无效记原因位 2");
                Ryujinx.HLE.S2AHooks.LdnPort = 41234;
                FakeNative.LdnLanAvailable = 0;
                Expect(!Host.StartLanDiscovery() && !Host.LdnLan && FakeNative.LdnLanStarts == 1, "负 errno 保持发现不可用");
                FakeNative.LdnLanAvailable = 1;
                Expect(Host.StartLanDiscovery() && Host.StartLanDiscovery() && Host.LdnLan && FakeNative.LdnLanStarts == 2 && FakeNative.LdnLanPort == 41234, "start 幂等且传实际端口");
                Expect(Host.LanUnavailable == 3 && ((delegate* unmanaged<int>)&LdnExports.LanState)() == 3, "成功启动不清原因位；S2A_LanState 导出同值");
                Host.StopLanDiscovery(); Host.StopLanDiscovery();
                Expect(!Host.LdnLan && FakeNative.LdnLanStops == 1, "重复 stop 只停一次有效会话");
                Host.OnLdnInitializing();
                Expect(!Host.StartLanDiscovery() && FakeNative.LdnLanStarts == 2 && !Host.LdnRelayHosted, "退出后旧请求不能复活 LAN / relay");
                Host.BeginLanDiscoverySession();
                Expect(Host.StartLanDiscovery() && FakeNative.LdnLanStarts == 3, "stop 后可再次 start");
                Host.StopLanDiscovery();
                Expect(FakeNative.LdnLanStops == 2, "第二会话独立停止");
            }
            finally { Ryujinx.HLE.S2AHooks.LdnPort = port; }
            return failures == 0 ? 0 : 1;
        }

        [SoloTest("--lan-shutdown-guest", Booted = true)]
        private static void LanShutdownGuest() => LanShutdownPath("GuestJoined");

        [SoloTest("--lan-shutdown-process", Booted = true)]
        private static void LanShutdownProcess() => LanShutdownPath("ProcessExit");

        private static void LanShutdownPath(string mode)
        {
            Check($"{mode}: LAN 启动", "True", Host.StartLanDiscovery().ToString());
            int before = FakeNative.LdnLanStops;
            Exports.AfterGuestJoinedShutdown = static _ => { }; // 本例只测服务退场，不断言 GPU / 真机
            var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static;
            Type shutdownMode = typeof(Exports).GetNestedType("ShutdownMode", System.Reflection.BindingFlags.NonPublic);
            typeof(Exports).GetMethod("ShutdownManaged", flags).Invoke(null, new object[] { Enum.Parse(shutdownMode, mode), "LAN regression" });
            Check($"{mode}: 退出路径有效 stop 一次", "1", (FakeNative.LdnLanStops - before).ToString());
            Host.StopLanDiscovery();
            Check($"{mode}: 再停幂等", "1", (FakeNative.LdnLanStops - before).ToString());
        }

        // 本地联机按需自动开（10-28 双人成行：玩家不该先去设置里找开关）：没给 S2A_LDN_SERVER、缺省离线 → 游戏第一次初始化 ldn:u 时
        //   ① 原生层没有局域网发现（Mac，弱符号回 0）：自动模式回退到 ldn_mitm，让 Mac 也能连 Switch；
        //   ② 有（iOS ldn_lan.m）：局域网发现被调（程序号 = 游戏的）、联机模式切 LdnRyu、中继先指本机 127.0.0.1、本进程托管中继（全部网卡，产品 30456、单测临时端口）；
        //   ③ 之后局域网选举改指（S2A_LdnSetServer）→ 建房（OpenAccessPoint）时客户端换到新中继，不等下一次 Initialize；
        //   ④ 本机中继建房 / 解散 → 原生层收到「有房间」标记 1 / 0（Bonjour 发布名加 / 去「!」，选举优先有房间的中继）。
        //   期望按 ldn 服务语义与上面的设计手写
        private static int _ldnPortDefault;

        // 空闲端口：先让系统分一个再放掉（单测不碰真实中继端口 30456，多棵工作树同时跑也不撞固定端口）
        private static int FreeTcpPort(IPAddress address)
        {
            TcpListener probe = new(address, 0);
            probe.Start();
            int port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            return port;
        }

        // 夹具：ldn 的 SetGameVersion / -1 本地通信号解析 / 权限检查都按调用方 pid 读 ProcessLoader 里的
        //   进程元数据。真机上由 Application.Register（解包里的 npdm / nacp）登记；本套件不读真包，
        //   按同一登记口给假游戏补一条（npdm 用仓库夹具 Homebrew.npdm，nacp 只填本用例读的三项）。
        private static void RegisterLdnProcessMetadata()
        {
            string npdmPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
                "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm"));
            MetaLoader metaLoader = new();
            metaLoader.Load(File.ReadAllBytes(npdmPath)).ThrowIfFailure();
            metaLoader.GetNpdm(out Npdm npdm).ThrowIfFailure();

            BlitStruct<ApplicationControlProperty> nacp = new(1);
            Encoding.ASCII.GetBytes("s2a-ldn").CopyTo(nacp.Value.Title[0].Name.AsSpan());
            Encoding.ASCII.GetBytes("1.0.0").CopyTo(nacp.Value.DisplayVersion.AsSpan());
            nacp.Value.LocalCommunicationId[0] = 0x0100A5A5A5A50000;

            Host.Device.Processes.S2ARegisterApplication(new ProcessResult(metaLoader, nacp, false, false, null,
                FakeNative.GamePid, 0, npdm.Meta.MainThreadPriority, npdm.Meta.MainThreadStackSize,
                Host.Device.System.State.DesiredTitleLanguage));
        }

        private static bool EnsureLdnProcessMetadata()
        {
            if (Host.Device.Processes.TryGetProcess(FakeNative.GamePid, out _)) return false;
            RegisterLdnProcessMetadata();
            return true;
        }

        private static void LdnAutoLan(uint sm)
        {
            bool addedProcess = EnsureLdnProcessMetadata();
            Ryujinx.HLE.HleConfiguration cfg = Host.Device.Configuration;
            int port = Ryujinx.HLE.S2AHooks.LdnPort;
            Check("联机端口：产品缺省 Ryujinx LanPlayPort；单测改到系统分配的临时端口", "缺省 30456、单测不是 30456",
                $"缺省 {_ldnPortDefault}、单测{(port != 30456 && port > 0 ? "不是 30456" : $" {port}")}");
            Check("联机自动开：前提（没给 S2A_LDN_SERVER、缺省离线、原生层局域网发现没被调过）", "null、Disabled、0 次",
                $"{Host.LdnServer ?? "null"}、{cfg.MultiplayerMode}、{FakeNative.LdnLanStarts} 次");

            uint ldnu = Call(sm, Msg.Cmif(1, Name8("ldn:u"))).Move[0];
            uint svc = Call(ldnu, Msg.Cmif(0)).Move[0];   // CreateUserLocalCommunicationService
            var service = (Dispatcher.Instance.GetSession(FakeNative.CookieOf(svc)) as HleTarget)?.Service as IUserLocalCommunicationService;
            Msg Init() { Msg m = Msg.Cmif(402, Bytes(0u, 0u)); m.SendPid = true; return m; }   // Initialize(ip, mask, pid)

            // ① Mac：没有局域网发现
            FakeNative.LdnLanAvailable = 0;
            long red0 = Red.Total;
            Reply i1 = Call(svc, Init());
            Reply oap0 = Call(svc, Msg.Cmif(200));   // OpenAccessPoint：初始化失败后的后续调用
            Check("联机自动开：原生层provider 返回负 errno → 自动模式回退 ldn_mitm、发现被调 1 次、后续调用成功（不把空客户端往后传）",
                "0x0、LdnMitm、1 次、0x0、+1",
                $"0x{i1.Result:X}、{cfg.MultiplayerMode}、{FakeNative.LdnLanStarts} 次、0x{oap0.Result:X}、+{Red.Total - red0}");
            Call(svc, Msg.Cmif(401));   // Finalize

            // ①b 调用方没登记进程项（元数据缺失）：发现可用、模式 LdnRyu 时初始化也要报红一次并回失败码，
            //   后续调用同回，不放行 -1 本地通信号解析 / 权限检查 / SetGameVersion 当成功
            svc = Call(ldnu, Msg.Cmif(0)).Move[0];
            service = (Dispatcher.Instance.GetSession(FakeNative.CookieOf(svc)) as HleTarget)?.Service as IUserLocalCommunicationService;
            if (!Host.Device.Processes.TryGetProcess(FakeNative.GamePid, out var savedProcess))
                throw new InvalidOperationException("LDN negative control requires registered process metadata");
            try
            {
                Host.Device.Processes.ClearProcess(FakeNative.GamePid);
                cfg.MultiplayerMode = Ryujinx.Common.Configuration.Multiplayer.MultiplayerMode.LdnRyu;
                cfg.MultiplayerLdnServer = "127.0.0.1";
                red0 = Red.Total;
                Reply im = Call(svc, Init());
                Reply oap1 = Call(svc, Msg.Cmif(200));   // OpenAccessPoint：初始化失败后的后续调用
                Check("联机：进程元数据缺失（调用方没登记进程项）→ Initialize 回失败码、后续调用同回、只报红一次（不放行成功）",
                    "0x40CB、+1、0x40CB",
                    $"0x{im.Result:X}、+{Red.Total - red0}、0x{oap1.Result:X}");
                Check("联机：进程元数据缺失 → 不建客户端，NetworkClient 与客户端目标都为空（不留半截客户端）",
                    "NetworkClient 空、目标 null",
                    $"NetworkClient {(service?.NetworkClient == null ? "空" : $"残留 {service.NetworkClient.GetType().Name}")}、目标 {(service?.S2ANetworkClientServer == null ? "null" : service.S2ANetworkClientServer)}");
                Call(svc, Msg.Cmif(401));   // Finalize
            }
            finally
            {
                cfg.MultiplayerMode = Ryujinx.Common.Configuration.Multiplayer.MultiplayerMode.Disabled;
                Host.Device.Processes.S2ARegisterApplication(savedProcess);
            }

            // ② iOS：有局域网发现（新开一个服务会话：上面 ① 的会话 Finalize 后状态未必回到 None，再 Initialize 不会重走「首次初始化」）
            svc = Call(ldnu, Msg.Cmif(0)).Move[0];
            service = (Dispatcher.Instance.GetSession(FakeNative.CookieOf(svc)) as HleTarget)?.Service as IUserLocalCommunicationService;
            Host.LdnAutoTried = false;
            FakeNative.LdnLanAvailable = 1;
            red0 = Red.Total;
            Reply i2 = Call(svc, Init());
            Check("联机自动开：有局域网发现（iOS）→ 初始化成功、切 LdnRyu、中继 127.0.0.1、发现被调（程序号 = 游戏）、不报红",
                "0x0、LdnRyu、127.0.0.1、2 次 程序号对、+0",
                $"0x{i2.Result:X}、{cfg.MultiplayerMode}、{cfg.MultiplayerLdnServer}、{FakeNative.LdnLanStarts} 次 程序号{(FakeNative.LdnLanProgramId == FakeNative.ProgramId() ? "对" : $" 0x{FakeNative.LdnLanProgramId:X}")}、+{Red.Total - red0}");
            Check("联机 provider 接收实际临时端口而非固定 30456", port.ToString(), FakeNative.LdnLanPort.ToString());
            Check("联机自动开：本进程在单测临时端口托管中继（全部网卡）、客户端连同一端口", $"托管了 0.0.0.0:{port}",
                Host.LdnRelayHosted ? $"托管了 0.0.0.0:{port}" : "没托管（临时端口被抢）");

            Host.SetLdnServer(null);
            Check("选举 NULL：清旧地址并离线，发现 provider 保持活动", "Disabled、、True", $"{cfg.MultiplayerMode}、{cfg.MultiplayerLdnServer}、{Host.LdnLan}");
            Host.SetLdnServer("127.0.0.1");
            Check("选举恢复候选：重新启用而非重启发现", "LdnRyu、127.0.0.1、2", $"{cfg.MultiplayerMode}、{cfg.MultiplayerLdnServer}、{FakeNative.LdnLanStarts}");

            // ③ 选举改指 → 建房时换客户端（OpenAccessPoint 只在 Initialized 态、建接入点对象之前换）
            INetworkClient clientBefore = service?.NetworkClient;
            Host.SetLdnServer("127.0.0.7");
            Reply oap = Call(svc, Msg.Cmif(200));   // OpenAccessPoint
            bool swapped = service != null && !ReferenceEquals(clientBefore, service.NetworkClient);
            Check("联机自动开：选举改指 127.0.0.7 → 建房时客户端换到新中继（初始化后不用重来）", "OpenAccessPoint 0x0、客户端已换、目标 127.0.0.7",
                $"OpenAccessPoint 0x{oap.Result:X}、客户端{(swapped ? "已换" : "没换")}、目标 {service?.S2ANetworkClientServer ?? "?"}");
            Call(svc, Msg.Cmif(201));   // CloseAccessPoint
            Call(svc, Msg.Cmif(401));   // Finalize
            Host.SetLdnServer("127.0.0.1");

            // ③b 先开站点、后选举（审计 #723 P1）：局域网发现在第一次 Initialize 才起，游戏可能在 Bonjour 选举出结果之前就 OpenStation；
            //   站点开一次、扫描多次，选举改指之后的下一次 Scan 就要用新中继，不用退出联机界面重开
            {
                Call(svc, Init());   // 前面用例 Finalize 后可能仍是 Initialized（回 0xC0CB），不判
                Reply ost = Call(svc, Msg.Cmif(300));   // OpenStation
                INetworkClient stBefore = service?.NetworkClient;
                string stTarget0 = service?.S2ANetworkClientServer ?? "?";
                Host.SetLdnServer("127.0.0.8");
                ScanFilter sf = default;
                sf.Flag = ScanFilterFlag.LocalCommunicationId;
                sf.NetworkId.IntentId.LocalCommunicationId = 0x0100A5A5A5A50000;
                byte[] req = new byte[8 + System.Runtime.InteropServices.Marshal.SizeOf<ScanFilter>()];
                System.Runtime.InteropServices.MemoryMarshal.Write(req.AsSpan(0, 8), in System.Runtime.CompilerServices.Unsafe.AsRef(0UL));
                System.Runtime.InteropServices.MemoryMarshal.Write(req.AsSpan(8), in sf);
                Msg sc = Msg.Cmif(102, req);
                byte* sbuf = _game + 0xB000;
                sc.B.Add(((ulong)sbuf, (ulong)(2 * System.Runtime.InteropServices.Marshal.SizeOf<NetworkInfo>())));
                Reply scr = Call(svc, sc);
                bool stSwapped = service != null && !ReferenceEquals(stBefore, service.NetworkClient);
                Check("联机自动开：先 OpenStation（中继 127.0.0.1）、后选举改指 127.0.0.8 → 下一次 Scan 已用新中继、不用重开站点（审计 #723 P1）",
                    "OpenStation 0x0、开站时目标 127.0.0.1、Scan 0x0、客户端已换、目标 127.0.0.8",
                    $"OpenStation 0x{ost.Result:X}、开站时目标 {stTarget0}、Scan 0x{scr.Result:X}、客户端{(stSwapped ? "已换" : "没换")}、目标 {service?.S2ANetworkClientServer ?? "?"}");
                Call(svc, Msg.Cmif(301));   // CloseStation
                Call(svc, Msg.Cmif(401));   // Finalize
                Host.SetLdnServer("127.0.0.1");
            }

            // ③c 先开接入点、写广告数据、后选举改指（审计 #748 P1）：建房前换中继客户端，游戏已写的广告数据要原样跟着房间发出去；
            //   私有建房没写过广告数据也要建得成（与公开建房同样按空广告）。改指写成「127.1」：字符串变了（触发换客户端），IPAddress.Parse 后仍是 127.0.0.1、连本进程托管的中继（客户端只认 IP 字面量，选举给的也是 IP），
            //   另起一个客户端扫描就能看到建出的房间。本地通信号给 -1 = 取游戏 nacp 里的第一个（服务端 NeedsRealId）
            if (Host.LdnRelayHosted)
            {
                byte* mem = (byte*)FakeNative.Alloc(0x1000);
                Msg Create(bool priv)
                {
                    byte[] sec = new byte[0x44]; sec[0] = (byte)SecurityMode.Retail;   // SecurityConfig：模式 u16、口令长 u16、口令 0x40
                    byte[] user = new byte[0x30]; Encoding.UTF8.GetBytes("Host-AP").CopyTo(user, 0);
                    NetworkConfig nc = default;
                    nc.IntentId.LocalCommunicationId = -1;
                    nc.NodeCountMax = 2;
                    byte[] ncb = new byte[System.Runtime.InteropServices.Marshal.SizeOf<NetworkConfig>()];
                    System.Runtime.InteropServices.MemoryMarshal.Write(ncb, in nc);
                    Msg m = priv ? Msg.Cmif(203, Bytes(sec, new byte[0x20], user, 0u, ncb)) : Msg.Cmif(202, Bytes(sec, user, 0u, ncb));
                    if (priv)
                    {
                        m.X.Add(((ulong)(mem + 0x800), (ulong)System.Runtime.InteropServices.Marshal.SizeOf<AddressList>()));
                    }
                    return m;
                }
                LdnMasterProxyClient scanner = new("127.0.0.1", port, cfg);
                try
                {
                    Call(svc, Init());
                    Reply oap3 = Call(svc, Msg.Cmif(200));   // OpenAccessPoint（中继 127.0.0.1）
                    byte[] ad = Encoding.ASCII.GetBytes("ad-before-election");
                    new Span<byte>(mem, ad.Length).Clear(); ad.CopyTo(new Span<byte>(mem, ad.Length));
                    Msg sa = Msg.Cmif(206); sa.A.Add(((ulong)mem, (ulong)ad.Length));   // SetAdvertiseData
                    Reply sar = Call(svc, sa);
                    INetworkClient apBefore = service?.NetworkClient;
                    Host.SetLdnServer("127.1");
                    Reply cr = Call(svc, Create(false));   // CreateNetwork：入口里按新中继换客户端
                    bool apSwapped = service != null && !ReferenceEquals(apBefore, service.NetworkClient);
                    NetworkInfo[] rooms = scanner.Scan(0, default);
                    string got = "扫到 0 个房间";
                    foreach (NetworkInfo r in rooms)
                    {
                        if (Encoding.UTF8.GetString(r.Ldn.Nodes[0].UserName.AsSpan()).TrimEnd('\0') == "Host-AP")
                        {
                            got = $"广告「{Encoding.ASCII.GetString(r.Ldn.AdvertiseData.AsSpan()[..r.Ldn.AdvertiseDataSize])}」";
                        }
                    }
                    Check("联机：先开接入点写广告数据（中继 127.0.0.1）、后选举改指 → 建房换到新客户端、房间带原广告数据（审计 #748 P1）",
                        "OpenAccessPoint 0x0、SetAdvertiseData 0x0、CreateNetwork 0x0、客户端已换、广告「ad-before-election」",
                        $"OpenAccessPoint 0x{oap3.Result:X}、SetAdvertiseData 0x{sar.Result:X}、CreateNetwork 0x{cr.Result:X}、客户端{(apSwapped ? "已换" : "没换")}、{got}");
                    Call(svc, Msg.Cmif(204));   // DestroyNetwork
                    Call(svc, Msg.Cmif(201));   // CloseAccessPoint

                    Reply oap4 = Call(svc, Msg.Cmif(200));
                    Host.SetLdnServer("127.0.0.1");
                    Reply crp;
                    try { crp = Call(svc, Create(true)); }
                    catch (Exception e) { crp = default; got = $"{e.GetType().Name}（{(e.InnerException ?? e).GetType().Name}：{(e.InnerException ?? e).Message}）Exception"; }
                    Check("联机：私有建房前没写广告数据、且刚选举改指 → 建房成功（按空广告，不把空引用交给编码）",
                        "OpenAccessPoint 0x0、CreateNetworkPrivate 0x0", $"OpenAccessPoint 0x{oap4.Result:X}、CreateNetworkPrivate {(got.EndsWith("Exception") ? got : $"0x{crp.Result:X}")}");
                    Call(svc, Msg.Cmif(204));
                    Call(svc, Msg.Cmif(201));
                    Call(svc, Msg.Cmif(401));   // Finalize
                }
                finally
                {
                    scanner.DisconnectAndStop();
                    Host.SetLdnServer("127.0.0.1");
                }
            }
            else
            {
                // 没托管到中继（临时端口被别的进程抢了）：两条照样登记、对不上判红，不静默跳过（审计 #814 F-ldn-748-skip：原先没有这支，#748 的回归在这种环境下等于没跑、套件仍绿）
                string why = $"未测（临时端口 {port} 被别的进程抢了，本进程没托管中继）";
                Check("联机：先开接入点写广告数据（中继 127.0.0.1）、后选举改指 → 建房换到新客户端、房间带原广告数据（审计 #748 P1）", "已测", why);
                Check("联机：私有建房前没写广告数据、且刚选举改指 → 建房成功（按空广告，不把空引用交给编码）", "已测", why);
            }

            // ④ 本机中继有 / 没有房间 → 原生层收到标记（只有本进程托管到了中继才测得了）
            if (Host.LdnRelayHosted)
            {
                LdnMasterProxyClient a = new("127.0.0.1", port, cfg);
                try
                {
                    CreateAccessPointRequest create = default;
                    create.SecurityConfig.SecurityMode = SecurityMode.Retail;
                    create.NetworkConfig.IntentId.LocalCommunicationId = 0x0100A5A5A5A50000;
                    create.NetworkConfig.NodeCountMax = 2;
                    bool created = a.CreateNetwork(create, Array.Empty<byte>());
                    bool on = WaitFor(() => FakeNative.LdnLanHostingLast == 1, 2000);
                    a.DisconnectNetwork();
                    bool off = WaitFor(() => FakeNative.LdnLanHostingLast == 0, 2000);
                    Check("联机自动开：本机中继建房 / 解散 → 局域网发布「有房间」标记 1 / 0", "建房成功、1、0", $"建房{(created ? "成功" : "失败")}、{(on ? "1" : FakeNative.LdnLanHostingLast.ToString())}、{(off ? "0" : FakeNative.LdnLanHostingLast.ToString())}");
                }
                finally
                {
                    a.DisconnectAndStop();
                    SocketHelpers.UnregisterProxy();
                }
            }
            else
            {
                Check("联机自动开：本机中继建房 / 解散 → 局域网发布「有房间」标记 1 / 0", "已测", $"未测（临时端口 {port} 被别的进程抢了，本进程没托管中继）");
            }

            FakeNative.HandleClose(svc);
            FakeNative.HandleClose(ldnu);
            // 还原成离线：后面的用例按离线机跑
            cfg.MultiplayerMode = Ryujinx.Common.Configuration.Multiplayer.MultiplayerMode.Disabled;
            if (addedProcess) Host.Device.Processes.ClearProcess(FakeNative.GamePid);
        }

        // 房间数回调按发生顺序发布（审计 #814 F-ldn-room-stale）：两个入口先后改房间数、各自放锁后通知，最后一次发布的必须是当前房间数。
        //   造最坏交错：第一次回调（房间数 1）停在发布前；这时房间解散、另一线程通知；再放行第一次。期望按语义手写：最后发布 0、共发布 1 → 0 两次。
        //   中继不监听（只用房间表与通知），房间直接塞进私有表
        private static void LdnRoomCountOrder()
        {
            LdnRelay relay = new(IPAddress.Loopback, 0);
            var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
            var rooms = (System.Collections.IList)typeof(LdnRelay).GetField("_rooms", flags).GetValue(relay);
            object relayLock = typeof(LdnRelay).GetField("_lock", flags).GetValue(relay);
            var notify = typeof(LdnRelay).GetMethod("NotifyRoomCount", flags);
            object room = Activator.CreateInstance(typeof(LdnRelay).GetNestedType("Room", System.Reflection.BindingFlags.NonPublic), true);
            var published = new System.Collections.Concurrent.ConcurrentQueue<int>();
            using ManualResetEventSlim firstIn = new(false), release = new(false);
            int calls = 0;
            relay.RoomCountChanged = n =>
            {
                if (Interlocked.Increment(ref calls) == 1) { firstIn.Set(); release.Wait(5000); }
                published.Enqueue(n);
            };
            lock (relayLock) { rooms.Add(room); }
            Thread a = new(() => notify.Invoke(relay, null));
            a.Start();
            firstIn.Wait(5000);
            lock (relayLock) { rooms.Remove(room); }
            Thread b = new(() => notify.Invoke(relay, null));
            b.Start();
            b.Join(300);   // 修好后 b 等第一次发布完再读；修前 b 直接发布 0
            release.Set();
            a.Join(5000); b.Join(5000);
            Check("联机：房间数回调按发生顺序发布（第一次停在发布前、期间解散另一线程通知）→ 最后发布 = 当前房间数（审计 #814 F-ldn-room-stale）",
                "发布 1 → 0、最后 0、当前 0", $"发布 {string.Join(" → ", published)}、最后 {(published.IsEmpty ? "无" : published.ToArray()[^1].ToString())}、当前 {relay.RoomCount}");
            relay.Dispose();
        }

        // 虚拟 IP 回绕不撞在用地址（审计 #859 F-ldn-ip-wrap）：A 建房一直占着第一个地址 10.114.0.1；B 反复建房 / 离开。
        //   分配游标在 /16 里递增、跳过 .0 / .255，第 65025 次回到 10.114.0.1——起点直接设到回绕前（0xFFFE = 10.114.255.254），B 走 6 轮就跨过回绕。
        //   期望按语义手写：B 每轮拿到的地址都不等于 A 的、都在网段里且不以 .0 / .255 结尾、离开即还（6 轮里第 1 轮的地址后面还能再分到不要求）。
        //   中继不监听，会话不连接（发包在未连接会话上直接丢弃），经私有的建房 / 离开入口走真实分配与归还
        private static void LdnIpWrap()
        {
            LdnRelay relay = new(IPAddress.Loopback, 0);
            var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
            Type sessionType = typeof(LdnRelay).GetNestedType("Session", System.Reflection.BindingFlags.NonPublic);
            var onCreate = typeof(LdnRelay).GetMethod("OnCreate", flags);
            var leave = typeof(LdnRelay).GetMethod("Leave", flags);
            var nextHost = typeof(LdnRelay).GetField("_nextHost", flags);
            var ipField = sessionType.GetField("Ip");
            NetworkConfig nc = default;
            nc.NodeCountMax = 2;

            uint Create(object s)
            {
                onCreate.Invoke(relay, [s, default(SecurityConfig), default(UserConfig), nc, default(Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Types.RyuNetworkConfig), Array.Empty<byte>()]);
                return (uint)ipField.GetValue(s);
            }

            object a = Activator.CreateInstance(sessionType, relay);
            uint ipA = Create(a);
            nextHost.SetValue(relay, 0xFFFEu);
            var got = new System.Collections.Generic.List<string>();
            bool hit = false, bad = false;

            for (int i = 0; i < 6; i++)
            {
                object b = Activator.CreateInstance(sessionType, relay);
                uint ip = Create(b);
                hit |= ip == ipA;
                bad |= (ip & 0xFFFF0000) != 0x0A720000 || (ip & 0xFF) == 0 || (ip & 0xFF) == 0xFF;
                got.Add($"{(ip >> 8) & 0xFF}.{ip & 0xFF}");
                leave.Invoke(relay, [b, false]);
            }

            Check("联机：虚拟 IP 回绕不撞在用地址（A 占 10.114.0.1，B 从 10.114.255.254 起反复建房 / 离开 6 轮，审计 #859 F-ldn-ip-wrap）",
                "A 10.114.0.1、B 没撞 A、地址都合法", $"A 10.114.{(ipA >> 8) & 0xFF}.{ipA & 0xFF}、B {(hit ? $"撞了 A（{string.Join(" ", got)}）" : "没撞 A")}、地址{(bad ? "有不合法" : "都合法")}");

            // 用尽：可分的 256 × 254 = 65024 个地址全登记为在用 → 再建房分不到地址，不建房、报红 +1（期望按网段算：末字节 1..254）
            var inUse = (System.Collections.Generic.HashSet<uint>)typeof(LdnRelay).GetField("_ipsInUse", flags).GetValue(relay);
            for (uint h = 0; h <= 0xFFFF; h++)
            {
                if ((h & 0xFF) is not 0 and not 0xFF)
                {
                    inUse.Add(0x0A720000 | h);
                }
            }
            int roomsFull = relay.RoomCount;
            long redFull = Red.Total;
            uint ipFull = Create(Activator.CreateInstance(sessionType, relay));
            Check("联机：虚拟 IP 用尽（65024 个全在用）→ 建房分不到地址、不建房、报红（审计 #859 F-ldn-ip-wrap）", "在用 65024、IP 0、房间数不变、报红 +1",
                $"在用 {inUse.Count}、IP {ipFull}、房间数{(relay.RoomCount == roomsFull ? "不变" : $" {roomsFull} → {relay.RoomCount}")}、报红 +{Red.Total - redFull}");
            leave.Invoke(relay, [a, false]);
            relay.Dispose();
        }

        private static void LdnRelayRoundTrip()
        {
            int port = FreeTcpPort(IPAddress.Loopback);

            LdnRelay relay = LdnRelay.TryHost(IPAddress.Loopback, port);
            Check("联机中继：回环口托管", "托管成功", relay != null ? "托管成功" : "托管失败");
            LdnRelay second = LdnRelay.TryHost(IPAddress.Loopback, port);
            Check("联机中继：端口已被托管时第二个进程不再托管", "不托管", second == null ? "不托管" : "又托管了一个");
            second?.Dispose();

            if (relay == null)
            {
                return;
            }

            LdnMasterProxyClient a = new("127.0.0.1", port, Host.Device.Configuration);
            LdnMasterProxyClient b = new("127.0.0.1", port, Host.Device.Configuration);
            NetworkInfo aLast = default, bLast = default;
            bool bConnected = false;
            AutoResetEvent aChanged = new(false), bChanged = new(false);
            a.NetworkChange += (_, e) => { aLast = e.Info; aChanged.Set(); };
            b.NetworkChange += (_, e) => { bLast = e.Info; bConnected = e.Connected; bChanged.Set(); };

            try
            {
                const long lcid = 0x0100C2500FC20000;   // 本地通信号取程序号（游戏 nmeta 里缺省如此）

                CreateAccessPointRequest create = default;
                create.SecurityConfig.SecurityMode = SecurityMode.Retail;
                create.NetworkConfig.IntentId.LocalCommunicationId = lcid;
                create.NetworkConfig.IntentId.SceneId = 7;
                create.NetworkConfig.NodeCountMax = 8;
                create.NetworkConfig.LocalCommunicationVersion = 3;
                Encoding.UTF8.GetBytes("Host-A").CopyTo(create.UserConfig.UserName.AsSpan());
                byte[] advertise = Encoding.ASCII.GetBytes("room-advert");

                bool created = a.CreateNetwork(create, advertise);
                uint ipA = a.Config.ProxyIp;
                Check("联机：A 建房", "成功、虚拟 IP 在 10.114.0.0/16", $"{(created ? "成功" : "失败")}、{((ipA & 0xFFFF0000) == 0x0A720000 ? "虚拟 IP 在 10.114.0.0/16" : $"虚拟 IP 0x{ipA:X8}")}");

                ScanFilter filter = default;
                filter.Flag = ScanFilterFlag.LocalCommunicationId;
                filter.NetworkId.IntentId.LocalCommunicationId = lcid;
                NetworkInfo[] found = b.Scan(0, filter);
                Check("联机：B 按本地通信号扫描", "1 个房间", $"{found.Length} 个房间");

                if (found.Length == 1)
                {
                    NetworkInfo r = found[0];
                    string name = Encoding.UTF8.GetString(r.Ldn.Nodes[0].UserName.AsSpan()).TrimEnd('\0');
                    string adv = Encoding.ASCII.GetString(r.Ldn.AdvertiseData.AsSpan()[..r.Ldn.AdvertiseDataSize]);
                    Check("联机：扫到的房间内容", "人数 1/8、场景 7、主机 Host-A、广告 room-advert、主机 IP = A 的虚拟 IP",
                        $"人数 {r.Ldn.NodeCount}/{r.Ldn.NodeCountMax}、场景 {r.NetworkId.IntentId.SceneId}、主机 {name}、广告 {adv}、主机 IP {(r.Ldn.Nodes[0].Ipv4Address == ipA ? "= A 的虚拟 IP" : $"0x{r.Ldn.Nodes[0].Ipv4Address:X8}")}");
                }

                // 外来异常包（11-01 全量审计 P0-7）：SSID 长度 40 的扫描过滤器、数据只有 4 字节的扫描包，都只断那一条连接、报红，中继照常服务。
                //   期望按语义手写：SSID 过滤扫到 0 个、截断包报红 +1、之后正常扫描仍 1 个；旧代码（只接 InvalidOperationException、按 SSID 长度切片）进程直接退出
                {
                    ScanFilter bad = default;
                    bad.Flag = ScanFilterFlag.Ssid;
                    bad.Ssid.Length = 40;
                    int badFound = b.Scan(0, bad).Length;
                    long redBad = Red.Total;
                    using (TcpClient raw = new())
                    {
                        raw.Connect(IPAddress.Loopback, port);
                        byte[] cut = new RyuLdnProtocol().Encode(Ryujinx.HLE.HOS.Services.Ldn.UserServiceCreator.LdnRyu.Types.PacketId.Scan, 0);   // 包头合法、数据 4 字节（扫描过滤器远不止 4 字节）
                        raw.GetStream().Write(cut, 0, cut.Length);
                        Thread.Sleep(500);
                    }
                    ScanFilter ok = default;
                    ok.Flag = ScanFilterFlag.LocalCommunicationId;
                    ok.NetworkId.IntentId.LocalCommunicationId = lcid;
                    Check("联机中继：外来异常包（SSID 长 40 / 截断的扫描包）只断那条连接", "SSID 过滤 0 个、截断包报红 +1、之后正常扫描 1 个",
                        $"SSID 过滤 {badFound} 个、截断包报红 +{Red.Total - redBad}、之后正常扫描 {b.Scan(0, ok).Length} 个");
                }

                long redIdle = Red.Total;
                // 房主改成拒绝一切加入（开局锁房）：别人扫不到；改回接受又扫得到
                aChanged.Reset();
                a.SetStationAcceptPolicy(AcceptPolicy.RejectAll);
                aChanged.WaitOne(2000);
                int locked = b.Scan(0, filter).Length;
                aChanged.Reset();
                a.SetStationAcceptPolicy(AcceptPolicy.AcceptAll);
                aChanged.WaitOne(2000);
                Check("联机：房主锁房 / 解锁后扫描", "0 个 / 1 个", $"{locked} 个 / {b.Scan(0, filter).Length} 个");

                // 空闲超过客户端 6 秒不活动上限（LdnMasterProxyClient.InactiveTimeout，没进房间时到点主动断开）后再扫：要能重连、照样扫到
                Thread.Sleep(7000);
                Check("联机：空闲 7 秒后再扫描", "1 个房间、无报红", $"{b.Scan(0, filter).Length} 个房间、{(Red.Total == redIdle ? "无报红" : $"报红 +{Red.Total - redIdle}")}");

                filter.NetworkId.IntentId.LocalCommunicationId = lcid + 1;
                Check("联机：别的本地通信号扫描", "0 个房间", $"{b.Scan(0, filter).Length} 个房间");

                if (found.Length == 1)
                {
                    ConnectRequest join = default;
                    join.SecurityConfig.SecurityMode = SecurityMode.Retail;
                    join.LocalCommunicationVersion = 3;
                    join.NetworkInfo = found[0];
                    Encoding.UTF8.GetBytes("Guest-B").CopyTo(join.UserConfig.UserName.AsSpan());
                    aChanged.Reset();
                    NetworkError err = b.Connect(join);
                    bool synced = aChanged.WaitOne(2000);
                    Check("联机：B 进房", "None、B 拿到节点 1、A 收到同步人数 2",
                        $"{err}、B {(bLast.Ldn.Nodes[1].IsConnected == 1 && bLast.Ldn.Nodes[1].Ipv4Address == b.Config.ProxyIp ? "拿到节点 1" : "没拿到节点 1")}、A {(synced ? $"收到同步人数 {aLast.Ldn.NodeCount}" : "2 秒内没收到同步")}");

                    bChanged.Reset();
                    a.DisconnectNetwork();
                    bool dropped = bChanged.WaitOne(2000);
                    Check("联机：A 关网", "B 被断开", dropped && !bConnected ? "B 被断开" : "B 没被断开");
                }
            }
            finally
            {
                a.DisconnectAndStop();
                b.DisconnectAndStop();
                relay.Dispose();
                SocketHelpers.UnregisterProxy();   // 客户端收到 ProxyConfig 时登记了全进程 LDN 代理，后续用例按离线机跑
            }

            // 局域网选举改中继（ios/ldn_lan.m → S2A_LdnSetServer → Host.SetLdnServer）：改到运行中的配置，游戏下次初始化 ldn:u 就用新地址
            string before = Host.Device.Configuration.MultiplayerLdnServer;
            Host.SetLdnServer("192.168.31.77");
            string after = Host.Device.Configuration.MultiplayerLdnServer;
            Host.SetLdnServer("192.168.31.77");
            Check("联机：局域网选举改中继地址", "改到 192.168.31.77、重复设置不变", $"{(after == "192.168.31.77" ? "改到 192.168.31.77" : $"没改（{after}）")}、{(Host.Device.Configuration.MultiplayerLdnServer == after ? "重复设置不变" : "又变了")}");
            Host.Device.Configuration.MultiplayerLdnServer = before;

            // 中继连不上（端口没人监听）：扫描回 0 个房间，并且报红（原先只是静默空列表，看不出是没人建房还是连不上）
            LdnMasterProxyClient c = new("127.0.0.1", port, Host.Device.Configuration);
            long red0 = Red.Total;
            ScanFilter any = default;
            int n = c.Scan(0, any).Length;
            Check("联机：中继连不上", "0 个房间、报红 +1", $"{n} 个房间、报红 +{Red.Total - red0}");
            c.DisconnectAndStop();
        }
    }
}
