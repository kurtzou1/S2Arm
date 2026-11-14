// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // auddmg:u（Switch 2 虚拟音频设备管理，nn::audio::devmgr）：0400486024DEC000 GetDefaultVirtualOutputDevice → devmgr::Initialize 连不上就 Abort。
    //   报文按游戏 sdk 客户端组包函数反推的线上格式手写（0400486024DEC000 sdk 0x2ad8e0 / 0x2adde0 / 0x134360 / 0x1a3090 / 0x2ae280 / 0x2ae430 等）：
    //     管理对象 0：in u32 种类 @0（SDK 恒发 2）、aruid @8、u64 @0x10（恒 0），带 pid；回会话（move）
    //     会话 0  ：in bool @0、u32 功能 @4；B 缓冲 n×0x100；回 u32 个数 @0
    //     会话 100：in u32 功能 @0；B 缓冲 0x100
    //     会话 200：in u32 功能 @0；A 缓冲 = 设备名，长度 = 字符串长（不带 0）；只回结果码
    //     会话 500：in u32 功能 @0、u64 凭据 @8；A 缓冲设备名；回复制句柄；600 同入参、只回结果码
    //   期望不跑实现即可写出：宿主只有一个声音输出，名字与 audout:u ListAudioOuts 同一来源（本用例现场从 audout:u 取，再对字面 "DeviceOut"）；
    //   功能 1 = 输出；状态变化事件不触发。列输入设备（0 功能 2）回 0 个；负例：其余带功能 2（输入）的命令、未知设备名、未实现的 900 号 → 未知命令结果码（模块 10 描述 221）且各报红 1 次
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void AudDmgUserSession()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            byte* buf = FakeNative.Alloc(0x1000);
            bool strict = Red.Strict;
            Red.Strict = false;

            try
            {
                // 期望设备名：audout:u ListAudioOuts（命令 0，B 缓冲 0x100）回的那一个
                Reply go = Call(sm, Msg.Cmif(1, Name8("audout:u")));
                Msg lo = Msg.Cmif(0); lo.B.Add(((ulong)buf, 0x100));
                Reply lor = Call(go.Move[0], lo);
                string audoutName = *(int*)lor.Data == 1 ? Encoding.ASCII.GetString(new ReadOnlySpan<byte>(buf, 0x100)).TrimEnd('\0') : $"{*(int*)lor.Data} 个";
                Check("auddmg：期望来源 audout:u ListAudioOuts", "1 个、DeviceOut", $"1 个、{audoutName}");

                Reply gs = Call(sm, Msg.Cmif(1, Name8("auddmg:u")));
                Check("sm GetService(auddmg:u)", "结果 0、move 1 个会话", $"结果 {gs.Result}、move {gs.Move.Count} 个{(gs.Move.Count == 1 && FakeNative.KindOf(gs.Move[0]) == ObjKind.Session ? "会话" : "")}");

                if (gs.Move.Count != 1)
                {
                    return;
                }

                // 管理对象 0（同 SDK devmgr::Initialize：种类 2、aruid、0、带 pid）
                byte[] open = new byte[0x18];
                BitConverter.TryWriteBytes(open.AsSpan(0), 2u);
                BitConverter.TryWriteBytes(open.AsSpan(8), 0x1234UL);
                Msg om = Msg.Cmif(0, open); om.SendPid = true;
                Reply orr = Call(gs.Move[0], om);
                Check("auddmg IUserSessionManager 0（种类 2）", "结果 0、move 1 个会话", $"结果 {orr.Result}、move {orr.Move.Count} 个{(orr.Move.Count == 1 && FakeNative.KindOf(orr.Move[0]) == ObjKind.Session ? "会话" : "")}");

                if (orr.Move.Count != 1)
                {
                    return;
                }

                uint us = orr.Move[0];

                byte[] Fn(uint functionality) => BitConverter.GetBytes(functionality);

                // 0：同 SDK ListVirtualOutputDevices（bool 0、功能 1、8 项）
                new Span<byte>(buf, 8 * 0x100).Fill(0xCC);
                byte[] lp = new byte[8];
                BitConverter.TryWriteBytes(lp.AsSpan(4), 1u);
                Msg l = Msg.Cmif(0, lp); l.B.Add(((ulong)buf, 8 * 0x100));
                Reply lr = Call(us, l);
                string first = Encoding.ASCII.GetString(new ReadOnlySpan<byte>(buf, 0x100)).Split('\0')[0];
                Check("auddmg 0 ListVirtualDeviceNames（输出）", $"结果 0、1 个、{audoutName}、名字后补 0", $"结果 {lr.Result}、{*(int*)lr.Data} 个、{first}、名字后{(buf[first.Length] == 0 ? "补 0" : "没补 0")}");

                // 0：同 SDK ListVirtualInputDevices（bool 0、功能 2）：宿主不收音，没有虚拟输入设备 → 0 个、缓冲不碰、不报红（原先报红「功能 2」）
                new Span<byte>(buf, 0x100).Fill(0xCC);
                byte[] li = new byte[8];
                BitConverter.TryWriteBytes(li.AsSpan(4), 2u);
                Msg lin = Msg.Cmif(0, li); lin.B.Add(((ulong)buf, 8 * 0x100));
                long redIn = Red.Total;
                Reply lir = Call(us, lin);
                Check("auddmg 0 ListVirtualDeviceNames（输入，功能 2）", "结果 0、0 个、缓冲不碰、红 +0", $"结果 {lir.Result}、{*(int*)lir.Data} 个、缓冲{(buf[0] == 0xCC ? "不碰" : "被写")}、红 +{Red.Total - redIn}");

                // 100：缺省输出设备
                new Span<byte>(buf, 0x100).Fill(0xCC);
                Msg d = Msg.Cmif(100, Fn(1)); d.B.Add(((ulong)buf, 0x100));
                Reply dr = Call(us, d);
                string def = Encoding.ASCII.GetString(new ReadOnlySpan<byte>(buf, 0x100)).Split('\0')[0];
                Check("auddmg 100 GetDefaultVirtualDeviceName（输出）", $"结果 0、{audoutName}", $"结果 {dr.Result}、{def}");

                // 200：设备名按 SDK 只发字符串长（不带 0）
                int n = Encoding.ASCII.GetBytes(audoutName, new Span<byte>(buf, 0x100));
                Msg av = Msg.Cmif(200, Fn(1)); av.A.Add(((ulong)buf, (ulong)n));
                Check("auddmg 200 IsVirtualDeviceAvailable（本机输出名，长 = 字符串长）", "结果 0x0", $"结果 0x{Call(us, av).Result:X}");

                // 500 / 600：事件读端、不触发；同凭据释放成功
                byte[] ep = new byte[0x10];
                BitConverter.TryWriteBytes(ep.AsSpan(0), 1u);
                BitConverter.TryWriteBytes(ep.AsSpan(8), 0x7000_1000UL);
                Msg ac = Msg.Cmif(500, ep); ac.A.Add(((ulong)buf, (ulong)n));
                Reply acr = Call(us, ac);
                uint eh = acr.Copy.Count == 1 ? acr.Copy[0] : 0;
                bool fired;
                lock (FakeNative.Events) fired = eh != 0 && FakeNative.Events.TryGetValue(FakeNative.CookieOf(eh), out bool f) && f;
                Check("auddmg 500 AcquireVirtualDeviceStateChangeEvent", "结果 0、copy 1 个事件读端、未触发",
                    $"结果 {acr.Result}、copy {acr.Copy.Count} 个{(eh != 0 && FakeNative.KindOf(eh) == ObjKind.EventR ? "事件读端" : "")}、{(fired ? "已触发" : "未触发")}");
                Msg rl = Msg.Cmif(600, ep); rl.A.Add(((ulong)buf, (ulong)n));
                Check("auddmg 600 ReleaseVirtualDeviceStateChangeEvent（同凭据）", "结果 0x0", $"结果 0x{Call(us, rl).Result:X}");

                // 负例：语义不明的取值与未实现命令一律报红、回未知命令
                (string Name, Msg M)[] reds =
                [
                    ("100 功能 2（缺省输入设备：列输入设备已回 0 个，取缺省仍报红）", WithB(Msg.Cmif(100, Fn(2)), buf, 0x100)),
                    ("200 未知设备名", WithA(Msg.Cmif(200, Fn(1)), buf, Encoding.ASCII.GetBytes("Nope", new Span<byte>(buf, 0x100)))),
                    ("900 GetPhysicalDeviceName（未实现）", WithA(WithB(Msg.Cmif(900, Fn(1)), buf + 0x400, 0x100), buf, n)),
                ];

                foreach ((string name, Msg m) in reds)
                {
                    if (name.StartsWith("900"))
                    {
                        Encoding.ASCII.GetBytes(audoutName, new Span<byte>(buf, 0x100));
                    }

                    long red0 = Red.Total;
                    uint r = Call(us, m).Result;
                    Check($"auddmg 负例 {name}", $"结果 0x{Red.ResultUnknownCommand:X}、报红 +1", $"结果 0x{r:X}、报红 +{Red.Total - red0}");
                }
            }
            finally
            {
                Red.Strict = strict;
            }
        }

        private static Msg WithA(Msg m, byte* p, int size)
        {
            m.A.Add(((ulong)p, (ulong)size));
            return m;
        }

        private static Msg WithB(Msg m, byte* p, int size)
        {
            m.B.Add(((ulong)p, (ulong)size));
            return m;
        }
    }
}
