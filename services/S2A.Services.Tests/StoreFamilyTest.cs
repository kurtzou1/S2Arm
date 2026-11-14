// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;

namespace S2A.Services.Tests
{
    // 商店家族里「开始任务 → 等完成事件 → 取结果」与购买事件（11-13：一款游戏在商店异步请求后永远等完成事件，同类全查）：生产 HIPC/CMIF 分发走一遍。
    //   ① ntc（网络时钟可用）：OpenEnsureNetworkClockAvailabilityService → GetFinishNotificationEvent（复制句柄）→ StartTask 后事件亮（离线也当场完成）
    //      → GetResult 离线回「网络时间不可用」（Time 2790-? 由兼容层定，这里只核不是 0）→ IsProcessing = 0 → GetServerTime 落在宿主当前时间 ±60 秒 → 100 / 101 回成功。
    //   ② aoc:u CreateEcPurchasedEventManager → SetDeliveryTarget（命令 1）回成功、PopPurchasedProductInfoWithUid（命令 4）回「没有已购信息」（同命令 3）。
    //   期望按协议文档（switchbrew NIM_services / NS_Services）与参考实现的回答手写
    public static unsafe partial class Program
    {
        [SoloTest("--store-family", Booted = true)]
        static void StoreFamily()
        {
            System.Text.Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];

            uint ntc = Call(sm, Msg.Cmif(1, Name8("ntc"))).Move[0];
            Reply open = Call(ntc, Msg.Cmif(0, BitConverter.GetBytes(0UL)));
            uint svc = open.Move.Count == 1 ? open.Move[0] : 0;
            Reply ge = Call(svc, Msg.Cmif(1));
            uint ev = ge.Copy.Count == 1 ? ge.Copy[0] : 0;
            bool Lit() => ev != 0 && FakeNative.Events.TryGetValue(FakeNative.CookieOf(ev), out bool on) && on;
            Check("网络时钟：打开服务 / 取完成事件（复制句柄）", "0 / 有 / 0 / 有", $"{open.Result} / {(svc != 0 ? "有" : "无")} / {ge.Result} / {(ev != 0 ? "有" : "无")}");
            Check("网络时钟：StartTask 前事件暗", "暗", Lit() ? "亮" : "暗");
            Check("网络时钟：StartTask 回成功、事件亮（离线也当场完成，等它的不会卡）", "0 / 亮", $"{Call(svc, Msg.Cmif(0)).Result} / {(Lit() ? "亮" : "暗")}");
            uint res = Call(svc, Msg.Cmif(2)).Result;
            Check("网络时钟：GetResult 离线回非 0（网络时间不可用）", "非 0", res != 0 ? "非 0" : "0");
            Reply proc = Call(svc, Msg.Cmif(4));
            Check("网络时钟：IsProcessing（命令 4）= 0", "0 / 0", $"{proc.Result} / {*(uint*)proc.Data}");
            Reply st = Call(svc, Msg.Cmif(5));
            long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds(), got = *(long*)st.Data;
            Check("网络时钟：GetServerTime（命令 5）落在宿主当前时间 ±60 秒", "0 / 是", $"{st.Result} / {(Math.Abs(got - now) <= 60 ? "是" : $"否（{got} 对 {now}）")}");
            Check("网络时钟：ntc 100 / 101（暂停 / 恢复自动校时）回成功", "0 / 0", $"{Call(ntc, Msg.Cmif(100)).Result} / {Call(ntc, Msg.Cmif(101)).Result}");

            uint aoc = Call(sm, Msg.Cmif(1, Name8("aoc:u"))).Move[0];
            Msg cm = Msg.Cmif(100); cm.SendPid = true;
            uint pem = Call(aoc, cm).Move[0];
            Msg sd = Msg.Cmif(1, BitConverter.GetBytes(0x0100A3501946E000UL)); sd.A.Add(((ulong)(_game + 0x3000), 0x10UL));
            Check("购买事件：SetDeliveryTarget（命令 1）回成功", 0u, Call(pem, sd).Result);
            uint p3 = Call(pem, Msg.Cmif(3)).Result, p4 = Call(pem, Msg.Cmif(4, new byte[16])).Result;
            Check("购买事件：PopPurchasedProductInfoWithUid（命令 4）回「没有已购信息」、与命令 3 相同", "非 0 / 相同", $"{(p4 != 0 ? "非 0" : "0")} / {(p4 == p3 ? "相同" : $"不同（{p3:X} 对 {p4:X}）")}");

            FakeNative.HandleClose(pem); FakeNative.HandleClose(aoc);
            if (ev != 0) FakeNative.HandleClose(ev);
            FakeNative.HandleClose(svc); FakeNative.HandleClose(ntc); FakeNative.HandleClose(sm);
        }
    }
}
