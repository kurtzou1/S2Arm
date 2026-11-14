// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // 本机日志扫出的「未实现服务命令」逐条补：每条按 23.0.1 系统接口转储的出入参形状核回包。期望按协议手写，不跑被测实现算。
    //   ① sfdnsres IResolver 13 GetNameInfoRequestWithOptions：入 0x18（@0 u32 flags）+ pid，缓冲 [A 地址, B 主机名, B 服务名, 0x21 选项]，出 3 个 i32
    //      （gai 错误、主机错误、errno）。本机不联网：主机名回数字地址、服务名回端口数字；NI_NAMEREQD 不联网 = EAI_NONAME 8 / HOST_NOT_FOUND 1；
    //      非 IPv4 = EAI_FAMILY 5；主机名缓冲放不下 = EAI_OVERFLOW 14
    //   ② ILibraryAppletAccessor 170：无入参、回 1 个复制句柄（事件读端、不触发），重复调回同一句柄；原先只回成功、不带句柄
    //   ③ auddmg:u IUserSession 0 列输入设备（功能 2）：宿主不收音，回 0 个、结果 0；原先报红
    //   ④ vi IApplicationDisplayService 2103（21.0.0+，无名）：无入参、出 0x18 字节；回成功、出参全 0（TLS 先填 0xCC，看 0x18 字节确实被写成 0）；原先报未实现
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void SvcGapsResolverNameInfo()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Reply gs = Call(sm, Msg.Cmif(1, Name8("sfdnsres")));
            Check("sm GetService(sfdnsres)", "结果 0、move 1 个", $"结果 {gs.Result}、move {gs.Move.Count} 个");
            if (gs.Move.Count != 1) return;
            uint res = gs.Move[0];

            byte* sa = _game + 0x3000, host = _game + 0x3100, serv = _game + 0x3200, opts = _game + 0x3300;

            (int Gai, int Herr, int Errno, string Host, string Serv) NameInfo(byte family, uint flags, ulong hostSize)
            {
                new Span<byte>(sa, 16).Clear();
                sa[0] = 16; sa[1] = family; sa[2] = 0x1F; sa[3] = 0x90;   // 端口 8080（大端）
                sa[4] = 192; sa[5] = 168; sa[6] = 1; sa[7] = 20;
                new Span<byte>(host, 0x100).Fill(0xCC); new Span<byte>(serv, 0x20).Fill(0xCC);
                byte[] input = new byte[0x18];
                BitConverter.TryWriteBytes(input.AsSpan(0), flags);
                Msg m = Msg.Cmif(13, input); m.SendPid = true;
                m.A.Add(((ulong)sa, 16)); m.B.Add(((ulong)host, hostSize)); m.B.Add(((ulong)serv, 0x20)); m.A.Add(((ulong)opts, 0x10));
                Reply r = Call(res, m);
                int* o = (int*)r.Data;
                string Str(byte* p, ulong n) { int len = new ReadOnlySpan<byte>(p, (int)n).IndexOf((byte)0); return len < 0 ? "（无结尾 0）" : Encoding.ASCII.GetString(p, len); }
                return r.Result != 0 ? ((int)r.Result, -1, -1, "", "") : (o[0], o[1], o[2], Str(host, hostSize), Str(serv, 0x20));
            }

            var a = NameInfo(2, 0, 0x100);
            Check("sfdnsres 13：IPv4、flags 0（不联网回数字地址 + 端口）", "0 / 0 / 0 / 192.168.1.20 / 8080", $"{a.Gai} / {a.Herr} / {a.Errno} / {a.Host} / {a.Serv}");
            var b = NameInfo(2, 0x4, 0x100);
            Check("sfdnsres 13：NI_NAMEREQD 不联网", "8 / 1 / 0", $"{b.Gai} / {b.Herr} / {b.Errno}");
            var c = NameInfo(28, 0, 0x100);
            Check("sfdnsres 13：非 IPv4 地址族", "5 / 0 / 0", $"{c.Gai} / {c.Herr} / {c.Errno}");
            var d = NameInfo(2, 0x2, 8);
            Check("sfdnsres 13：主机名缓冲 8 字节放不下「192.168.1.20」", "14", $"{d.Gai}");

            FakeNative.HandleClose(res); FakeNative.HandleClose(sm);
        }

        [SvcCase]
        private static void SvcGapsLibraryAppletCmd170()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Reply goe = Call(sm, Msg.Cmif(1, Name8("appletOE")));
            uint oe = goe.Move.Count == 1 ? goe.Move[0] : 0;
            Msg cd = Msg.Cmif(0); cd.Type = 5;
            int root = *(int*)Call(oe, cd).Data;

            Reply Domain(Msg m, int obj)
            {
                m.DomainObject = obj;
                m.Write(_tlr);
                Svc(0x21, FakeNative.CookieOf(oe));
                return Reply.ParseDomain(_tlr);
            }

            int OutObj(Reply r) => *(int*)r.Data;

            Msg opx = Msg.Cmif(0, Bytes(0UL)); opx.SendPid = true;
            int proxy = OutObj(Domain(opx, root));                                  // OpenApplicationProxy
            int creator = OutObj(Domain(Msg.Cmif(11), proxy));                      // GetLibraryAppletCreator
            int accessor = OutObj(Domain(Msg.Cmif(0, Bytes(0x17, 0)), creator));    // CreateLibraryApplet(0x17, mode 0)

            Reply r1 = Domain(Msg.Cmif(170), accessor);
            uint h = r1.Copy.Count == 1 ? r1.Copy[0] : 0;
            bool fired;
            lock (FakeNative.Events) fired = h != 0 && FakeNative.Events.TryGetValue(FakeNative.CookieOf(h), out bool f) && f;
            Check("ILibraryAppletAccessor 170：回 1 个复制句柄（事件读端、未触发）", "结果 0、copy 1 个事件读端、未触发",
                $"结果 {r1.Result}、copy {r1.Copy.Count} 个{(h != 0 && FakeNative.KindOf(h) == ObjKind.EventR ? "事件读端" : "")}、{(fired ? "已触发" : "未触发")}");
            Reply r2 = Domain(Msg.Cmif(170), accessor);
            Check("ILibraryAppletAccessor 170：再调回同一个事件", "同一个", r2.Copy.Count == 1 && FakeNative.CookieOf(r2.Copy[0]) == FakeNative.CookieOf(h) ? "同一个" : "不同");

            FakeNative.HandleClose(oe); FakeNative.HandleClose(sm);
        }

        [SvcCase]
        private static void SvcGapsViCmd2103()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Reply gvi = Call(sm, Msg.Cmif(1, Name8("vi:u")));
            uint viu = gvi.Move.Count == 1 ? gvi.Move[0] : 0;
            Reply gds = Call(viu, Msg.Cmif(0, Bytes(0u)));                         // GetDisplayService
            uint ids = gds.Move.Count == 1 ? gds.Move[0] : 0;
            new Span<byte>(_tlr, 0x100).Fill(0xCC);
            Reply r = Call(ids, Msg.Cmif(2103));
            bool zero = r.Result == 0 && new ReadOnlySpan<byte>(r.Data, 0x18).IndexOfAnyExcept((byte)0) < 0;
            Check("vi IApplicationDisplayService 2103：回成功、出 0x18 字节全 0", "结果 0、全 0", $"结果 {r.Result}、{(zero ? "全 0" : "不是全 0")}");
            FakeNative.HandleClose(ids); FakeNative.HandleClose(viu); FakeNative.HandleClose(sm);
        }
    }
}
