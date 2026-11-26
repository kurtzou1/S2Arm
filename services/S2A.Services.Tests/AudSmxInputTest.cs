// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    // audsmx:u 外部输入流（麦克风，#2151）：0400486024DEC000 开局调 PurgeInputStream 不判空，输入流开不起来即崩。
    //   报文按游戏 sdk 的 InputStreamImpl::Open / Start / Stop（0x1f66c0 / 0x1f6ce0 / 0x1f6c90）反推，同 AudSmxTest.cs 的输出流、方向相反：
    //     auddmg 300 / 401 功能 2 + 设备名 "TrueRawAudioIn"（游戏发的输入设备名，#2151）；401 档案 +0x220 = 输入设备令牌（交 CreateStream）
    //     audsmx CreateStream 标志 2（服务端写）；OpenStream 写指针初值 0、标志 0；AcquireStreamDataEvent 方式 2；auddmg 700 功能 2 / 800
    //   输入方向的环（sdk 0x2b21d0 / 0x2b4760）：B+0x1004 = 服务端写指针，B+0x44 = 客户端读指针，B+0x1040 起环，容量 = 帧数 + 1。
    //   单测宿主的声音驱动不收音（哑会话：交来的块立即写满静音），期望不跑实现即可写出：
    //     ① 游戏不读时服务端最多写到「环满」= 容量 − 1 帧，不覆盖没读的样本；读走一半后写指针按模容量接着推
    //     ② 环里写出的全是 0（交出前清零：游戏先填的 0x5A 被覆盖成静音，不是旧数据）
    //     ③ 按墙钟限速：大环（1 秒）不读时，写指针 ≤ 48 × 已过毫秒 + 一块（240 帧），不会被哑会话瞬间灌满
    public static unsafe partial class Program
    {
        [SvcCase]
        private static void AudSmxInputStream()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            byte* buf = FakeNative.Alloc(0x1000);
            bool strict = Red.Strict;
            Red.Strict = false;

            try
            {
                uint smx = Call(sm, Msg.Cmif(1, Name8("audsmx:u"))).Move[0];
                Reply D(Msg m, int obj)
                {
                    m.DomainObject = obj; m.Write(_tlr); Svc(0x21, FakeNative.CookieOf(smx));
                    if (m.DomainRequestType == 2) return new Reply();
                    try { return Reply.ParseDomain(_tlr); } catch (InvalidOperationException) { return Reply.Parse(_tlr); }
                }

                Msg cv = Msg.Cmif(0); cv.Type = 5;
                int root = *(int*)Call(smx, cv).Data;
                Msg om = Msg.Cmif(0, Bytes(1u, 0u, 0UL)); om.SendPid = true; om.Copy.Add(0xFFFF8001);
                int userSession = *(int*)D(om, root).Data;

                Reply gd = Call(sm, Msg.Cmif(1, Name8("auddmg:u")));
                Msg dm = Msg.Cmif(0, Bytes(2u, 0u, 0x1234UL, 0UL)); dm.SendPid = true;
                uint dev = Call(gd.Move[0], dm).Move[0];
                int inLen = Encoding.ASCII.GetBytes("TrueRawAudioIn", new Span<byte>(buf, 0x100));

                // auddmg 300 / 401（功能 2）：单声道 / 立体声 PcmInt16、单声道 PcmFloat 支持；档案给输入令牌 2、延迟 10 ms
                foreach ((uint f, int ch) in new[] { (2u, 1), (2u, 2), (5u, 1) })
                {
                    Msg m = Msg.Cmif(300, Bytes(f, ch, 48000, 2u)); m.A.Add(((ulong)buf, (ulong)inLen));
                    Check($"auddmg 300 输入格式 {f} / {ch} 声道 / 48000", "结果 0x0", $"结果 0x{Call(dev, m).Result:X}");
                }

                byte* profile = buf + 0x400;
                new Span<byte>(profile, 0x228).Fill(0xCC);
                Msg pf = Msg.Cmif(401, Bytes(2u)); pf.B.Add(((ulong)profile, 0x228)); pf.A.Add(((ulong)buf, (ulong)inLen));
                uint pfr = Call(dev, pf).Result;
                Check("auddmg 401 输入设备档案：令牌 / 延迟", "结果 0、2、10000000 ns", $"结果 {pfr}、{*(uint*)(profile + 0x220)}、{*(ulong*)(profile + 0x218)} ns");

                // CreateStream（设备 = 输入令牌、标志 2）→ OpenStream（PcmInt16 单声道 48 kHz、960 帧）→ 事件
                byte* work = SmxWorkBuffer();
                new Span<byte>(work + 0x1040, SmxCapacity * 2).Fill(0x5A);   // 游戏内存里的旧数据：服务端写出的必须是静音
                int nameLen = Encoding.ASCII.GetBytes("InputStream", new Span<byte>(buf + 0x800, 0x100));
                Msg cs = Msg.Cmif(1, Bytes(2u, 2u, 0x1234UL, (ulong)work, (ulong)SmxWorkSize)); cs.SendPid = true; cs.A.Add(((ulong)buf + 0x800, (ulong)nameLen));
                Reply csr = D(cs, userSession);
                uint streamId = *(uint*)csr.Data;
                int streamObj = *(int*)(csr.Data + 4);
                Check("audsmx CreateStream（输入：设备 2、标志 2）", "结果 0、流号 ≥ 1", $"结果 {csr.Result}、流号 {(streamId >= 1 ? "≥ 1" : streamId.ToString())}");
                Check("audsmx OpenStream（输入 PcmInt16 / 1 声道 / 48 kHz / 960 帧）", "结果 0x0", $"结果 0x{D(Msg.Cmif(0, Bytes(2u, 1, 48000, SmxFrames, 0, 0u)), streamObj).Result:X}");
                Reply aer = D(Msg.Cmif(7, Bytes(2u, 240)), streamObj);
                uint dataEvent = aer.Copy.Count == 1 ? aer.Copy[0] : 0;
                Check("audsmx AcquireStreamDataEvent（输入，方式 2）", "结果 0、copy 1 个", $"结果 {aer.Result}、copy {aer.Copy.Count} 个");

                // 700 挂上（功能 2）：游戏不读，等到环满（960 帧 = 20 ms 墙钟，给 2 秒）
                Msg at = Msg.Cmif(700, Bytes(streamId, 2u)); at.A.Add(((ulong)buf, (ulong)inLen));
                Check("auddmg 700 AttachStream（输入）", "结果 0x0", $"结果 0x{Call(dev, at).Result:X}");
                bool full = SmxWaitWrite(work, SmxFrames, 2000);
                Thread.Sleep(50);   // 环满后再多给几个周期：写指针不得越过读指针
                bool fired;
                lock (FakeNative.Events) fired = dataEvent != 0 && FakeNative.Events.TryGetValue(FakeNative.CookieOf(dataEvent), out bool f) && f;
                int nonZero = 0;
                for (int i = 0; i < SmxCapacity * 2; i++) nonZero += work[0x1040 + i] != 0 && i < SmxFrames * 2 ? 1 : 0;
                Check("audsmx 输入流不读时写满环：写指针（B+0x1004）/ 读指针不碰 / 写出的样本非零字节数 / 数据事件",
                    "960、0、0、已触发", $"{*(uint*)(work + 0x1004)}{(full ? "" : "（2 秒未到）")}、{*(uint*)(work + 0x44)}、{nonZero}、{(fired ? "已触发" : "未触发")}");

                // 客户端读走 480 帧（推读指针）：服务端接着写，写指针 = (960 + 480) mod 961 = 479
                *(uint*)(work + 0x44) = 480;
                bool r2 = SmxWaitWrite(work, 479, 2000);
                Thread.Sleep(50);
                Check("audsmx 读走 480 帧后跨环尾接着写：写指针", "479", $"{*(uint*)(work + 0x1004)}{(r2 ? "" : "（2 秒未到）")}");

                // 收尾（同 InputStreamImpl::Close）：800 → 8 → 1 → 销毁
                Check("auddmg 800 DetachStream（输入）", "结果 0x0", $"结果 0x{Call(dev, Msg.Cmif(800, Bytes(streamId))).Result:X}");
                Check("audsmx ReleaseStreamDataEvent / CloseStream（输入）", "结果 0x0 / 0x0", $"结果 0x{D(Msg.Cmif(8), streamObj).Result:X} / 0x{D(Msg.Cmif(1), streamObj).Result:X}");
                Msg del = Msg.Cmif(0); del.DomainRequestType = 2; D(del, streamObj);

                // ③ 墙钟限速：1 秒的环（48000 帧单声道 PcmInt16，环尾 0x1040 + 48001 × 2 = 0x18482），不读，挂上后 300 ms 量写指针
                const int BigFrames = 48000;
                const int BigSize = 0x19000;
                byte* raw = FakeNative.Alloc(BigSize + 0x1000);
                byte* big = (byte*)(((ulong)raw + 0xFFF) & ~0xFFFUL);
                new Span<byte>(big, BigSize).Clear();
                Msg cs2 = Msg.Cmif(1, Bytes(2u, 2u, 0x1234UL, (ulong)big, (ulong)BigSize)); cs2.SendPid = true; cs2.A.Add(((ulong)buf + 0x800, (ulong)nameLen));
                Reply cs2r = D(cs2, userSession);
                uint bigId = *(uint*)cs2r.Data;
                int bigObj = *(int*)(cs2r.Data + 4);
                D(Msg.Cmif(0, Bytes(2u, 1, 48000, BigFrames, 0, 0u)), bigObj);
                Msg at2 = Msg.Cmif(700, Bytes(bigId, 2u)); at2.A.Add(((ulong)buf, (ulong)inLen));
                Stopwatch sw = Stopwatch.StartNew();
                Call(dev, at2);
                Thread.Sleep(300);
                uint w = *(uint*)(big + 0x1004);
                long ms = sw.ElapsedMilliseconds;
                Check("audsmx 输入流按墙钟限速：300 ms 后写指针 ≤ 48 × 已过毫秒 + 240、且 > 0", "成立",
                    w > 0 && w <= 48 * ms + 240 ? "成立" : $"不成立（写指针 {w}、已过 {ms} ms、上限 {48 * ms + 240}）");
                Call(dev, Msg.Cmif(800, Bytes(bigId)));
                D(Msg.Cmif(1), bigObj);
                Msg delBig = Msg.Cmif(0); delBig.DomainRequestType = 2; D(delBig, bigObj);

                // 负例：设备与标志对不上、输入功能配输出流、宿主收不了的格式 → 报红、回未知命令
                byte* work2 = SmxWorkBuffer();
                Msg cso = Msg.Cmif(1, Bytes(1u, 0x24u, 0x1234UL, (ulong)work2, (ulong)SmxWorkSize)); cso.SendPid = true; cso.A.Add(((ulong)buf + 0x800, (ulong)nameLen));
                Reply csor = D(cso, userSession);
                uint outId = *(uint*)csor.Data;
                D(Msg.Cmif(0, Bytes(2u, 2, 48000, SmxFrames, 0, 0u)), *(int*)(csor.Data + 4));
                (string Name, Func<uint> Send)[] reds =
                [
                    ("CreateStream 输入令牌 + 输出标志 0x24", () => { Msg m = Msg.Cmif(1, Bytes(2u, 0x24u, 0x1234UL, (ulong)work2, (ulong)SmxWorkSize)); m.SendPid = true; m.A.Add(((ulong)buf + 0x800, (ulong)nameLen)); return D(m, userSession).Result; }),
                    ("CreateStream 输出令牌 + 输入标志 2", () => { Msg m = Msg.Cmif(1, Bytes(1u, 2u, 0x1234UL, (ulong)work2, (ulong)SmxWorkSize)); m.SendPid = true; m.A.Add(((ulong)buf + 0x800, (ulong)nameLen)); return D(m, userSession).Result; }),
                    ("CreateStream 输入令牌 + 标志 0x22（0x20 输入方向没见过）", () => { Msg m = Msg.Cmif(1, Bytes(2u, 0x22u, 0x1234UL, (ulong)work2, (ulong)SmxWorkSize)); m.SendPid = true; m.A.Add(((ulong)buf + 0x800, (ulong)nameLen)); return D(m, userSession).Result; }),
                    ("auddmg 700 输出流配功能 2", () => { Msg m = Msg.Cmif(700, Bytes(outId, 2u)); m.A.Add(((ulong)buf, (ulong)inLen)); return Call(dev, m).Result; }),
                    ("auddmg 300 输入 PcmInt8", () => { Msg m = Msg.Cmif(300, Bytes(1u, 1, 48000, 2u)); m.A.Add(((ulong)buf, (ulong)inLen)); return Call(dev, m).Result; }),
                    ("auddmg 300 输入 6 声道", () => { Msg m = Msg.Cmif(300, Bytes(2u, 6, 48000, 2u)); m.A.Add(((ulong)buf, (ulong)inLen)); return Call(dev, m).Result; }),
                    ("auddmg 300 输入 32000 Hz", () => { Msg m = Msg.Cmif(300, Bytes(2u, 1, 32000, 2u)); m.A.Add(((ulong)buf, (ulong)inLen)); return Call(dev, m).Result; }),
                ];

                foreach ((string name, Func<uint> send) in reds)
                {
                    long red0 = Red.Total;
                    uint r = send();
                    Check($"audsmx 输入负例 {name}", $"结果 0x{Red.ResultUnknownCommand:X}、报红 +1", $"结果 0x{r:X}、报红 +{Red.Total - red0}");
                }

                FakeNative.HandleClose(dev);
                FakeNative.HandleClose(gd.Move[0]);
                FakeNative.HandleClose(smx);
            }
            finally
            {
                Red.Strict = strict;
                FakeNative.HandleClose(sm);
            }
        }

        private static bool SmxWaitWrite(byte* b, uint want, int ms)
        {
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < ms)
            {
                if (*(uint*)(b + 0x1004) == want) return true;
                Thread.Sleep(2);
            }
            return *(uint*)(b + 0x1004) == want;
        }
    }
}
