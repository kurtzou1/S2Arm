using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志：HOSBinderDriverServer 的 TransactParcel（0）/ TransactParcelAuto（3）里的纯只读查询事务
        //   （IGraphicBufferProducer.Query=9、GetBufferInfo=16、GetBufferHistory=17）不改服务状态、不建句柄，不进日志；
        //   否则常驻的 HOSBinderDriverServer 会话随游玩时长线性积压（实测每帧调 ListFrameHistory 的游戏 2.5 小时把 SOH 撑到 383 MB、撞托管堆上限触发持续 GC 抖动卡死）。
        //   Connect / SetPreallocatedBuffer / RequestBuffer / DequeueBuffer / QueueBuffer / CancelBuffer 等改状态事务以及 AdjustRefcount(1) / GetNativeHandle(2) 照常进日志。
        [SoloTest("--snap-binder-query-log")]
        private static unsafe int SnapBinderQueryLog()
        {
            var rows = new List<(string N, string E, string A)>();
            static byte[] BuildCmif(long cmd, int binderId, uint code, bool domain = false)
            {
                // HIPC 头 8 B + 可选 16 B 域头 + CMIF 头 16 B ("SFCI" + 0 + cmd) + 参数 12 B (binderId, code, flags)
                int sfciOff = domain ? 24 : 8;
                byte[] buf = new byte[sfciOff + 16 + 12];
                BitConverter.GetBytes(4u).CopyTo(buf, 0);
                BitConverter.GetBytes(0x49434653u).CopyTo(buf, sfciOff);       // "SFCI"
                BitConverter.GetBytes(cmd).CopyTo(buf, sfciOff + 8);
                BitConverter.GetBytes(binderId).CopyTo(buf, sfciOff + 16);
                BitConverter.GetBytes(code).CopyTo(buf, sfciOff + 20);
                return buf;
            }
            static bool Dropped(string n, long cmd, byte[] msg)
            {
                if (SnapLog.Drop(n, cmd)) return true;
                fixed (byte* p = msg) return SnapLog.DropBinderQuery(n, cmd, p, msg.Length);
            }
            const string Svc = "HOSBinderDriverServer";
            int RunSession(int frames, long transactCmd, bool domain = false)
            {
                int logged = 0;
                void Send(long cmd, uint code = 0) { if (!Dropped(Svc, cmd, BuildCmif(cmd, 1, code, domain))) logged++; }
                // 开局建状态：AdjustRefcount(1) + GetNativeHandle(2) + Connect(10) + SetPreallocatedBuffer(14)×3 + RequestBuffer(1)×3 = 9 条
                Send(1);
                Send(2);
                Send(transactCmd, 10);
                for (int s = 0; s < 3; s++) Send(transactCmd, 14);
                for (int s = 0; s < 3; s++) Send(transactCmd, 1);
                // 游玩期间每帧纯查询：GetBufferHistory(17) + Query(9) + GetBufferInfo(16)
                for (int f = 0; f < frames; f++)
                {
                    Send(transactCmd, 17);
                    Send(transactCmd, 9);
                    Send(transactCmd, 16);
                }
                return logged;
            }
            int auto1m = RunSession(3600, 3), auto10m = RunSession(36000, 3);
            int legacy1m = RunSession(3600, 0), dom1m = RunSession(3600, 3, domain: true);
            rows.Add(("① TransactParcelAuto(3) 跑 1 分钟 / 10 分钟进日志条数", "9 / 9", $"{auto1m} / {auto10m}"));
            rows.Add(("② TransactParcel(0) 与域消息各跑 1 分钟进日志条数", "9 / 9", $"{legacy1m} / {dom1m}"));

            // ③ 所有改状态的 IGraphicBufferProducer 事务都必须保留（不误丢）
            uint[] stateful = [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14];
            int kept = 0;
            foreach (uint code in stateful) if (!Dropped(Svc, 3, BuildCmif(3, 1, code))) kept++;
            rows.Add(("③ 13 种改状态事务全部保留（不误丢）", $"{stateful.Length}", $"{kept}"));

            // ④ 负对照：规则关掉后 10 分钟进日志 > 10 万条（复现随游玩时长线性暴涨）
            SnapLog.BinderQueryRulesOn = false;
            try
            {
                int neg = RunSession(36000, 3);
                rows.Add(("④ 负对照：规则关掉，10 分钟 > 10 万条", "是", neg > 100000 ? "是" : $"否（{neg}）"));
            }
            finally { SnapLog.BinderQueryRulesOn = true; }

            int failures = 0;
            foreach ((string n, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
