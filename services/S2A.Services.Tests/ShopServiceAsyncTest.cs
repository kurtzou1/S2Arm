// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // 商店异步接口 nn::ec::IShopServiceAsync（#790：0100C3601518C000 起局调 Prepare，原先所有命令都是「未知命令」）：生产 HIPC/CMIF 分发走一遍
    //   nim:eca → CreateServerInterface → CreateAccessorInterface → CreateAsyncInterface → Prepare(两个 A 缓冲) → Request → GetSize → Read(偏移 0, B 缓冲) → GetErrorCode → Cancel。
    //   期望按协议手写：没有商店，请求当场完成、回空 JSON 对象「{}」（2 字节）、错误码 0；Read 越过末尾读 0 字节；Cancel 后 GetSize 回 0。
    //   CreateAsyncInterface 回对象 + 这次请求自己的完成事件（复制句柄，同协议文档与 Eden）：Request 前暗、Request 后亮（游戏在 Request 后等它；
    //   只回对象时 0100C3601518C000 在 Request 后一直等、一帧不画，11-13 Mac 局实测）
    public static unsafe partial class Program
    {
        [SoloTest("--nim-shop-async", Booted = true)]
        static void ShopServiceAsync()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint eca = Call(sm, Msg.Cmif(1, Name8("nim:eca"))).Move[0];
            uint tmem = FakeNative.TmemCreate((ulong)(_game + 0x8000), 0x4000, 3);   // CreateServerInterface(pid, 传输内存, u64)：服务当场关掉传输内存
            Msg cs = Msg.Cmif(0, BitConverter.GetBytes(0x4000UL)); cs.SendPid = true; cs.Copy.Add(tmem);
            uint server = Call(eca, cs).Move[0];
            uint accessor = Call(server, Msg.Cmif(0, new byte[8])).Move[0];
            Reply create = Call(accessor, Msg.Cmif(0, new byte[8]));
            Check("商店异步：CreateAsyncInterface 回一个对象 + 一个复制句柄（完成事件）", "0 / 1 / 1", $"{create.Result} / {create.Move.Count} / {create.Copy.Count}");
            uint async = create.Move[0], done = create.Copy.Count == 1 ? create.Copy[0] : 0;
            bool Lit() => done != 0 && FakeNative.Events.TryGetValue(FakeNative.CookieOf(done), out bool on) && on;
            Check("商店异步：Request 前完成事件暗", "暗", Lit() ? "亮" : "暗");

            byte* path = _game + 0x2000, post = _game + 0x2100, buf = _game + 0x2200;
            Encoding.ASCII.GetBytes("/v1/demo\0").CopyTo(new Span<byte>(path, 9));
            Msg prepare = Msg.Cmif(5); prepare.A.Add(((ulong)path, 9)); prepare.A.Add(((ulong)post, 0));
            Check("商店异步：Prepare（命令 5）回成功（原先未知命令）", 0u, Call(async, prepare).Result);
            Check("商店异步：Request（命令 4）回成功", 0u, Call(async, Msg.Cmif(4)).Result);
            Check("商店异步：Request 后完成事件亮（当场完成）", "亮", Lit() ? "亮" : "暗");

            Reply size = Call(async, Msg.Cmif(1));
            Check("商店异步：GetSize = 2（空 JSON 对象「{}」）", "0 / 2", $"{size.Result} / {*(ulong*)size.Data}");
            new Span<byte>(buf, 16).Fill(0xAA);
            Msg read = Msg.Cmif(2, BitConverter.GetBytes(0UL)); read.B.Add(((ulong)buf, 16));
            Reply r = Call(async, read);
            Check("商店异步：Read(0) 读回 2 字节「{}」、后面不碰", "0 / 2 / {} / AA",
                  $"{r.Result} / {*(ulong*)r.Data} / {Encoding.ASCII.GetString(new ReadOnlySpan<byte>(buf, 2))} / {buf[2]:X2}");
            Msg past = Msg.Cmif(2, BitConverter.GetBytes(5UL)); past.B.Add(((ulong)buf, 16));
            Reply rp = Call(async, past);
            Check("商店异步：Read 越过末尾读 0 字节", "0 / 0", $"{rp.Result} / {*(ulong*)rp.Data}");
            Reply err = Call(async, Msg.Cmif(3));
            Check("商店异步：GetErrorCode = 0", "0 / 0", $"{err.Result} / {*(uint*)err.Data}");
            Check("商店异步：Cancel 回成功", 0u, Call(async, Msg.Cmif(0)).Result);
            Check("商店异步：Cancel 后 GetSize = 0", 0UL, *(ulong*)Call(async, Msg.Cmif(1)).Data);

            FakeNative.HandleClose(async); if (done != 0) FakeNative.HandleClose(done); FakeNative.HandleClose(accessor); FakeNative.HandleClose(server); FakeNative.HandleClose(eca); FakeNative.HandleClose(sm);
        }
    }
}
