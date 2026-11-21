using System;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Services.Tests
{
    // 离线机（无联网权限 = Switch 离线：只有回环接口）不碰宿主网络。期望按 Switch / FreeBSD 网络栈语义写：
    //   建 / 绑 socket 照常；去别的主机 connect / sendto 回 ENETUNREACH（101，无路由）；回环 UDP 本地送达；回环 TCP 无监听 ECONNREFUSED（111）；
    //   空队列非阻塞收 EAGAIN（11）；sfdnsres 的 localhost 答 127.0.0.1、数字地址照答、别的名字 HostNotFound（1）。
    // 旧版每个 bsd socket 都是宿主真 socket（暗黑2 起局建 UDP 绑端口 0，iOS 随即弹「允许使用无线数据」盖住游戏），去外网的 sendto 真发出去。
    public static unsafe partial class Program
    {
        [DllImport("libc", SetLastError = true)]
        private static extern int getsockname(int fd, byte* addr, ref uint len);

        [DllImport("libc")]
        private static extern int getdtablesize();

        // 本进程里宿主 AF_INET / AF_INET6 socket 个数（macOS：sockaddr 第 1 字节是族，AF_INET 2、AF_INET6 30）
        private static int HostInetSockets()
        {
            int n = 0;
            byte* sa = stackalloc byte[128];

            for (int fd = 0; fd < getdtablesize(); fd++)
            {
                uint len = 128;

                if (getsockname(fd, sa, ref len) == 0 && (sa[1] == 2 || sa[1] == 30))
                {
                    n++;
                }
            }

            return n;
        }

        private static void OfflineNetwork(uint sm)
        {
            uint bsd = Call(sm, Msg.Cmif(1, Name8("bsd:u"))).Move[0];
            Msg reg = Msg.Cmif(0, new byte[0x30]);
            reg.SendPid = true;
            reg.Copy.Add(0xFFFF8001);
            Call(bsd, reg);

            byte* addr = _game + 0x7900, data = _game + 0x7A00, rbuf = _game + 0x7B00, raddr = _game + 0x7C00;

            (int Ret, int Errno) R(Reply r) => (*(int*)r.Data, *(int*)(r.Data + 4));

            // nn::socket::sockaddr_in { u8 len; u8 family; u16 port（大端）; u8 addr[4]; u8 zero[8] }
            void SockAddr(byte a0, byte a1, byte a2, byte a3, int port)
            {
                new Span<byte>(addr, 16).Clear();
                addr[0] = 16;
                addr[1] = 2;
                addr[2] = (byte)(port >> 8);
                addr[3] = (byte)port;
                addr[4] = a0; addr[5] = a1; addr[6] = a2; addr[7] = a3;
            }

            int Socket(int type) => R(Call(bsd, Msg.Cmif(2, Bytes(2, type, 0)))).Ret;

            (int Ret, int Errno) WithAddr(uint cmd, int fd)
            {
                Msg m = Msg.Cmif(cmd, Bytes(fd));
                m.A.Add(((ulong)addr, 16));
                return R(Call(bsd, m));
            }

            (int Ret, int Errno) SendTo(int fd, string text)
            {
                Encoding.ASCII.GetBytes(text).CopyTo(new Span<byte>(data, 0x40));
                Msg m = Msg.Cmif(11, Bytes(fd, 0));
                m.A.Add(((ulong)data, (ulong)text.Length));
                m.A.Add(((ulong)addr, 16));
                return R(Call(bsd, m));
            }

            (int Ret, int Errno) RecvFrom(int fd)
            {
                // 标志 0x80 = MSG_DONTWAIT
                Msg m = Msg.Cmif(9, Bytes(fd, 0x80));
                m.B.Add(((ulong)rbuf, 0x40));
                m.B.Add(((ulong)raddr, 16));
                return R(Call(bsd, m));
            }

            int before = HostInetSockets();

            // 暗黑2 起局那一步：UDP（AF_INET、SOCK_DGRAM、协议 0）绑 0.0.0.0:0
            int udp = Socket(2);
            SockAddr(0, 0, 0, 0, 0);
            var bind = WithAddr(13, udp);
            int afterBind = HostInetSockets() - before;

            Msg gsn = Msg.Cmif(16, Bytes(udp));
            gsn.B.Add(((ulong)raddr, 16));
            Call(bsd, gsn);
            int port = raddr[2] << 8 | raddr[3];

            SockAddr(203, 0, 113, 1, 9);
            var far = SendTo(udp, "hi");

            int udp2 = Socket(2);
            SockAddr(127, 0, 0, 1, port);
            var loop = SendTo(udp2, "hi");
            var got = RecvFrom(udp);
            string gotText = got.Ret > 0 ? Encoding.ASCII.GetString(rbuf, got.Ret) : "";
            string gotFrom = $"{raddr[4]}.{raddr[5]}.{raddr[6]}.{raddr[7]}";
            var empty = RecvFrom(udp);

            // 非阻塞 TCP（类型 SOCK_STREAM | 创建标志 NonBlocking << 28）
            int tcp = Socket(1 | (2 << 28));
            SockAddr(203, 0, 113, 1, 80);
            var tcpFar = WithAddr(14, tcp);
            int tcp2 = Socket(1 | (2 << 28));
            SockAddr(127, 0, 0, 1, port);
            var tcpLoop = WithAddr(14, tcp2);

            int afterAll = HostInetSockets() - before;

            foreach (int fd in new[] { udp, udp2, tcp, tcp2 })
            {
                Call(bsd, Msg.Cmif(26, Bytes(fd)));
            }

            Check("bsd 离线：建 UDP + 绑 0.0.0.0:0 / 宿主网络 socket 增量（绑后 / 全部 4 个 socket 收发后）",
                "fd ≥ 0、绑定 0/0、本地端口 ≥ 49152；增量 0 / 0",
                $"fd {(udp >= 0 ? "≥ 0" : udp.ToString())}、绑定 {bind.Ret}/{bind.Errno}、本地端口 {(port >= 49152 ? "≥ 49152" : port.ToString())}；增量 {afterBind} / {afterAll}");
            Check("bsd 离线：sendto 203.0.113.1:9 / 回环 sendto 127.0.0.1 → recvfrom / 再收（队列空）",
                "-1 errno 101；2 errno 0 → 2「hi」来自 127.0.0.1；-1 errno 11",
                $"{far.Ret} errno {far.Errno}；{loop.Ret} errno {loop.Errno} → {got.Ret}「{gotText}」来自 {gotFrom}；{empty.Ret} errno {empty.Errno}");
            Check("bsd 离线：非阻塞 TCP connect 203.0.113.1:80 / 127.0.0.1 无监听",
                "-1 errno 101 / -1 errno 111",
                $"{tcpFar.Ret} errno {tcpFar.Errno} / {tcpLoop.Ret} errno {tcpLoop.Errno}");

            // sfdnsres GetHostByNameRequest(u32 enable_nsd_resolve, u32 timeout, u64 pid, pid, buffer<5> host, buffer<6> hostent) -> (netdb errno, gai errno, size)
            uint dns = Call(sm, Msg.Cmif(1, Name8("sfdnsres"))).Move[0];

            (int NetDb, int Gai, int Size, bool Loopback, bool Any) Resolve(string name)
            {
                byte* hostIn = _game + 0x7D00, hostOut = _game + 0x7E00;
                new Span<byte>(hostIn, 0x100).Clear();
                new Span<byte>(hostOut, 0x100).Clear();
                Encoding.ASCII.GetBytes(name).CopyTo(new Span<byte>(hostIn, 0x100));
                Msg m = Msg.Cmif(2, Bytes(0, 0, 0UL));
                m.SendPid = true;
                m.A.Add(((ulong)hostIn, (ulong)name.Length + 1));
                m.B.Add(((ulong)hostOut, 0x100));
                Reply r = Call(dns, m);
                // hostent 序列化：h_name\0、别名数（大端 u32）、别名…、h_addrtype（u16）、h_length（u16）、地址数（大端 u32）、地址…
                // 只核一个 4 字节地址、内容是 127.0.0.1（字节序不在本改动范围，两种都认）
                int p = name.Length + 1;
                int aliases = hostOut[p] << 24 | hostOut[p + 1] << 16 | hostOut[p + 2] << 8 | hostOut[p + 3];
                p += 4 + 4;
                int count = hostOut[p] << 24 | hostOut[p + 1] << 16 | hostOut[p + 2] << 8 | hostOut[p + 3];
                byte* a = hostOut + p + 4;
                bool loopback = aliases == 0 && count == 1 &&
                    ((a[0] == 127 && a[1] == 0 && a[2] == 0 && a[3] == 1) || (a[0] == 1 && a[1] == 0 && a[2] == 0 && a[3] == 127));

                bool any = aliases == 0 && count == 1 && a[0] == 0 && a[1] == 0 && a[2] == 0 && a[3] == 0;

                return (*(int*)r.Data, *(int*)(r.Data + 4), *(int*)(r.Data + 8), loopback, any);
            }

            // GetAddrInfoRequest（命令 6）：host、service、hints 三个 A 缓冲，回 packed addrinfo；只核 netdb / gai / 序列化长度
            (int NetDb, int Gai, int Size) AddrInfo(string name, string service, int hintFlags = -1)
            {
                byte* hostIn = _game + 0x7D00, serviceIn = _game + 0x7D80, hostOut = _game + 0x7E00;
                new Span<byte>(hostIn, 0x80).Clear();
                new Span<byte>(serviceIn, 0x80).Clear();
                new Span<byte>(hostOut, 0x100).Clear();
                Encoding.ASCII.GetBytes(name).CopyTo(new Span<byte>(hostIn, 0x80));
                Encoding.ASCII.GetBytes(service).CopyTo(new Span<byte>(serviceIn, 0x80));
                Msg m = Msg.Cmif(6, Bytes(0, 0, 0UL));
                m.SendPid = true;
                m.A.Add(((ulong)hostIn, (ulong)name.Length + 1));
                m.A.Add(((ulong)serviceIn, (ulong)service.Length + 1));
                if (hintFlags < 0)
                {
                    m.A.Add(((ulong)hostOut, 0));
                }
                else
                {
                    // hints：packed addrinfo 头 6 个大端 u32（magic 0xBEEFCAFE、flags、family 2、socktype 2、protocol 0、地址长 0），没有地址
                    byte* hints = _game + 0x7CC0;
                    uint[] hw = { 0xBEEFCAFE, (uint)hintFlags, 2, 2, 0, 0 };
                    for (int i = 0; i < 6; i++) System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(new Span<byte>(hints + 4 * i, 4), hw[i]);
                    m.A.Add(((ulong)hints, 24));
                }
                m.B.Add(((ulong)hostOut, 0x100));
                Reply r = Call(dns, m);

                return (*(int*)r.Data, *(int*)(r.Data + 4), *(int*)(r.Data + 8));
            }

            var lh = Resolve("localhost");
            var ex = Resolve("telemetry-in.battle.net");
            Check("sfdnsres 离线：GetHostByName localhost / telemetry-in.battle.net",
                "netdb 0、gai 0、长度 > 0、唯一地址 127.0.0.1 / netdb 1、长度 0",
                $"netdb {lh.NetDb}、gai {lh.Gai}、长度 {(lh.Size > 0 ? "> 0" : lh.Size.ToString())}、{(lh.Loopback ? "唯一地址" : "地址不是唯一的")} 127.0.0.1 / netdb {ex.NetDb}、长度 {ex.Size}");

            // 数字地址不用 DNS：gethostbyname 先按 inet_aton 解析、getaddrinfo 先按数字主机解析，离线机照样答（WWZ 离线模式本机服务端
            // GetHostByName("0.0.0.0") 取绑定地址，旧版回 HostNotFound，服务端起不来，客户端一直停在「Connecting to WWZ Services」）
            var any = Resolve("0.0.0.0");
            var lo = Resolve("127.0.0.1");
            var gai = AddrInfo("127.0.0.1", "48800");
            Check("sfdnsres 离线：GetHostByName 0.0.0.0 / 127.0.0.1，GetAddrInfo 127.0.0.1",
                "netdb 0、gai 0、长度 > 0、唯一地址 0.0.0.0 / netdb 0、唯一地址 127.0.0.1 / netdb 0、gai 0、长度 > 0",
                $"netdb {any.NetDb}、gai {any.Gai}、长度 {(any.Size > 0 ? "> 0" : any.Size.ToString())}、{(any.Any ? "唯一地址 0.0.0.0" : "地址不是唯一的 0.0.0.0")} / " +
                $"netdb {lo.NetDb}、{(lo.Loopback ? "唯一地址" : "地址不是唯一的")} 127.0.0.1 / " +
                $"netdb {gai.NetDb}、gai {gai.Gai}、长度 {(gai.Size > 0 ? "> 0" : gai.Size.ToString())}");

            // 没有主机名（getaddrinfo(NULL, port, hints)，#5a3e66 0100D58012E12000 断网时这样调）不用 DNS：hints 带 AI_PASSIVE（1）→ 0.0.0.0（绑本机服务端），
            //   不带 → 127.0.0.1（POSIX getaddrinfo）。回包 = packed addrinfo 头 24 字节 + sockaddr_in（长度、族、端口、4 字节地址），地址在 +28。旧版回 netdb 1、长度 0
            byte* gaiOut = _game + 0x7E00;
            var gp = AddrInfo("", "7777", 1);
            byte[] ap = new ReadOnlySpan<byte>(gaiOut + 28, 4).ToArray();
            var gl = AddrInfo("", "7777", 0);
            byte[] al = new ReadOnlySpan<byte>(gaiOut + 28, 4).ToArray();
            int glType = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(new ReadOnlySpan<byte>(gaiOut + 12, 4)), glProto = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(new ReadOnlySpan<byte>(gaiOut + 16, 4));
            var gn = AddrInfo("", "7777");
            byte[] an = new ReadOnlySpan<byte>(gaiOut + 28, 4).ToArray();
            int gnType = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(new ReadOnlySpan<byte>(gaiOut + 12, 4)), gnProto = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(new ReadOnlySpan<byte>(gaiOut + 16, 4));
            // 回环的 4 字节同上面 hostent 的核法两种字节序都认（序列化字节序不在本改动范围）
            static string Lo(byte[] a) => (a[0] == 127 && a[1] == 0 && a[2] == 0 && a[3] == 1) || (a[0] == 1 && a[1] == 0 && a[2] == 0 && a[3] == 127) ? "回环" : string.Join(".", a);
            Check("sfdnsres 离线：GetAddrInfo 空主机名 + AI_PASSIVE / 空主机名不带 / 空主机名无 hints",
                "netdb 0、gai 0、长度 > 0、地址 0.0.0.0 / netdb 0、gai 0、地址 回环 / netdb 0、gai 0、地址 回环",
                $"netdb {gp.NetDb}、gai {gp.Gai}、长度 {(gp.Size > 0 ? "> 0" : gp.Size.ToString())}、地址 {string.Join(".", ap)} / " +
                $"netdb {gl.NetDb}、gai {gl.Gai}、地址 {Lo(al)} / netdb {gn.NetDb}、gai {gn.Gai}、地址 {Lo(an)}");

            // 回的 addrinfo 带 socket 类型 / 协议（11-21 D-TVB8 同一款：原先一律 0，游戏拿 0 建 socket 被拒、读空指针崩）。期望手写：hints 类型 2（数据报）→ 类型 2、协议 17（UDP）、
            //   一条（长度 = 一条 + 4 字节结尾）；没 hints → 数据报 / UDP 与流 / TCP 两条（FreeBSD 顺序，第一条 2 / 17），长度 = 两条 + 4
            Check("sfdnsres：GetAddrInfo 回的类型 / 协议（hints 数据报 / 无 hints）",
                "类型 2、协议 17 / 第一条类型 2、协议 17、两条",
                $"类型 {glType}、协议 {glProto} / 第一条类型 {gnType}、协议 {gnProto}、{(gn.Size == 2 * (gl.Size - 4) + 4 ? "两条" : $"长度 {gn.Size}（一条 {gl.Size}）")}");

            // 会等宿主网络的模块（sfdnsres / ssl）不和通用锁上的服务串行：联网时一次慢解析只挡它自己（不让所有游戏线程跟着停帧）。
            // 正对照：两个 nifm 会话在同一串行域
            uint nif1 = Call(sm, Msg.Cmif(1, Name8("nifm:u"))).Move[0];
            uint nif2 = Call(sm, Msg.Cmif(1, Name8("nifm:u"))).Move[0];
            var tDns = (HleTarget)Dispatcher.Instance.GetSession(FakeNative.CookieOf(dns));
            var tNif1 = (HleTarget)Dispatcher.Instance.GetSession(FakeNative.CookieOf(nif1));
            var tNif2 = (HleTarget)Dispatcher.Instance.GetSession(FakeNative.CookieOf(nif2));
            Check("服务串行域：sfdnsres 与 nifm（通用锁）/ nifm 与 nifm",
                "不同 / 同",
                $"{(tDns.SharesLockWith(tNif1) ? "同" : "不同")} / {(tNif1.SharesLockWith(tNif2) ? "同" : "不同")}");
        }
    }
}
