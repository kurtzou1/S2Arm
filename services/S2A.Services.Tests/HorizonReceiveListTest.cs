// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // 审计 #1534 P1-81：Horizon 服务应答的指针缓冲放不进游戏的接收区时，游戏的 SendSyncRequest 要收内核错误，不收成功。
    // 期望值按上游 KServerSession.Reply / GetReceiveListAddress 手写：接收列表类型 0（没给）、类型 2 一块缓冲容量不够、
    //   类型 ≥3 序号那块容量不够或地址 0 → OutOfResource（模块 1、描述 103 → 0xCE01）；
    //   类型 1（接收区紧跟应答消息）放得下 → 成功，描述符地址指向消息缓冲里应答之后、0x10 对齐处，数据在那里。
    // 用 AudioOut #8 GetReleasedAudioOutBuffersAuto（Horizon 服务，B 地址 0 = 改用指针缓冲，指针输出长度 0x40）。
    public static unsafe partial class Program
    {
        [SoloTest("--horizon-recv-list", Booted = true)]
        private static void HorizonReceiveList()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
            uint aout = Call(sm, Msg.Cmif(1, Name8("audout:u"))).Move[0];
            byte* nameIn = _game + 0x6800, nameOut = _game + 0x6900, ub = _game + 0x6A00, pcm = _game + 0x6C00, cbuf = _game + 0x6E00;
            new Span<byte>(nameIn, 0x100).Clear();
            Msg oo = Msg.Cmif(1, Bytes(48000u, 0xCAFE0002u, 0UL));
            oo.SendPid = true;
            oo.Copy.Add(0xFFFF8001);
            oo.A.Add(((ulong)nameIn, 0x100));
            oo.B.Add(((ulong)nameOut, 0x100));
            Reply oor = Call(aout, oo);
            uint ses = oor.Move.Count == 1 ? oor.Move[0] : 0;
            Call(ses, Msg.Cmif(1)); // Start

            void Append(ulong tag)
            {
                // AudioUserBuffer { 下一块, 数据, 容量, 数据长, 数据偏移 }
                *(ulong*)ub = 0; *(ulong*)(ub + 8) = (ulong)pcm; *(ulong*)(ub + 16) = 0x100; *(ulong*)(ub + 24) = 0x100; *(ulong*)(ub + 32) = 0;
                Msg ap = Msg.Cmif(3, Bytes(tag));
                ap.A.Add(((ulong)ub, 0x28));
                Call(ses, ap);
            }

            Msg Released(int mode, ulong cAddr, ulong cSize)
            {
                Msg gr = Msg.Cmif(8, Bytes(0u, 0x40u)); // 原始数据偏移 4：指针输出长度 0x40
                gr.B.Add((0, 0));   // AutoSelect：B 地址 0 = 改用指针缓冲
                if (cSize != 0 || cAddr != 0) gr.C.Add((cAddr, cSize));
                gr.RecvListMode = mode;
                return gr;
            }

            ulong Raw(Msg m)
            {
                m.Write(_tlr);
                (int rc, ulong[] r) = Svc(0x21, FakeNative.CookieOf(ses));
                return rc == SvcResult.Handled ? r[0] : 0xDEAD;
            }

            // 放不下的四种：服务已经答完（缓冲照样被取走），应答送不到游戏
            Append(0x81000001);
            Check("P1-81 接收列表类型 3、C 缓冲 0x20 < 0x40", "0xCE01", $"0x{Raw(Released(3, (ulong)cbuf, 0x20)):X}");
            Check("P1-81 接收列表类型 3、C 缓冲地址 0", "0xCE01", $"0x{Raw(Released(3, 0, 0x40)):X}");
            // 类型 2：一块缓冲收全部，起点 0x10 对齐后容量 0x20 放不下 0x40
            Check("P1-81 接收列表类型 2、一块缓冲 0x20 < 0x40", "0xCE01", $"0x{Raw(Released(2, (ulong)cbuf, 0x20)):X}");
            Check("P1-81 接收列表类型 0（游戏没给接收列表）", "0xCE01", $"0x{Raw(Released(0, 0, 0)):X}");

            // 类型 1：接收区在消息缓冲里应答之后，放得下 → 成功、标签在描述符指向的地址（且落在本消息缓冲内应答之后）
            ulong tag = 0x81000011;
            Append(tag);
            uint count = 0;
            ulong rc1 = 0, at = 0;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            while (count == 0 && sw.ElapsedMilliseconds < 5000)
            {
                rc1 = Raw(Released(1, 0, 0));
                if (rc1 != 0) break;
                Reply rp = Reply.Parse(_tlr);
                count = *(uint*)rp.Data;
                uint* w = (uint*)_tlr;
                at = (ulong)w[3] | ((ulong)((w[2] >> 12) & 0xF) << 32) | ((ulong)((w[2] >> 6) & 0x7) << 36);   // X 描述符：首个（应答无句柄）
                if (count == 0) System.Threading.Thread.Sleep(10);
            }
            bool inside = at >= (ulong)_tlr + 8 && at + 0x40 <= (ulong)_tlr + 0x100 && (at & 0xF) == 0;
            // 上面四次放不下的调用时第一块可能还没播完（音频线程按时刻放出，机器忙时更明显），没被取走就和这一块一起读到：
            //   计数 2、第 1 项 0x81000001（#921 作者报的偶发红）。判据只看这次读到的缓冲：最后一项是这一块，前面若有只能是第一块
            ulong last = inside && count >= 1 && count <= 8 ? *(ulong*)(at + (count - 1) * 8) : 0;
            bool prefixOk = inside && (count == 1 || (count == 2 && *(ulong*)at == 0x81000001));
            Check("P1-81 接收列表类型 1（接收区紧跟应答消息）放得下", $"rc 0x0、末项标签 0x{tag:X}、此前只可能有第一块、地址在消息缓冲内应答之后且 16 对齐",
                $"rc 0x{rc1:X}、末项标签 0x{last:X}、{(prefixOk ? "此前只可能有第一块" : $"计数 {count} 前项不对")}、地址{(inside ? "在消息缓冲内应答之后且 16 对齐" : $" 0x{at:X} 不在消息缓冲内")}");
        }
    }
}
