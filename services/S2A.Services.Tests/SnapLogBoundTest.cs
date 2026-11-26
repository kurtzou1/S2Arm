using System;
using System.Collections.Generic;
using System.Linq;
using S2A.Services;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志有界（维护者 11-19「快照日志要有界」；D-NXYJ：哈迪斯离线轮询 nifm，开局 40 秒 128 MB / 63.8 万条，托管堆涨到 abort）。
        //   用生产的规则（SnapLog.Drop / NifmLast / NifmTail）与上限判定（SnapLog.CapReached）+ 真 ReqTable，每条主日志 200 字节，期望值手算：
        //   ① nifm IRequest 提交 1 次后取请求状态 10 万次 → 主日志 0 条；存档末尾 2 条 = 那次提交 + 它之后第一次取状态
        //   ② 哈迪斯式循环（Ryujinx IRequest.cs：离线时一直重新提交）10 万轮「提交 + 取状态 3 次」→ 主日志 0 条；末尾 2 条 = 最后一轮的提交与它之后第一次取状态
        //      （11-26 Mac 实测：只拦查询时每轮仍记一对，2 分钟 29 万条撞 96 MB 上限、这一局即时存档被关）
        //   ③ 两个请求对象各自只留自己的：A 提交 + 取状态、B 只提交 → 末尾 3 条；提交前取状态（只读）→ 不留
        //   ④ 取结果 10 万次 → 0 条；取事件句柄 2 / 取消 3 / 设选项 11 各 1 次 → 主日志 3 条（照常记）
        //   ⑤ 规则管不到的服务每帧轮询 10 万次（上限设 1 MB）：日志字节 ≤ 1 MB + 一条 200 字节
        //   ⑥ 负对照（= 旧代码：规则关、不设上限）：② 的循环全进主日志 = 40 万条；⑤ 的 10 万次 = 2000 万字节，超过 ⑤ 的上界 → 判红
        [SoloTest("--snap-log-bound")]
        private static int SnapLogBound()
        {
            const string Nifm = "Ryujinx.HLE.HOS.Services.Nifm.StaticService.IRequest", Other = "Some.Unruled.IPolledService";
            const int Polls = 100000, EntBytes = 200;
            var keyA = new ReqTable.Key(0x1234, 7); var keyB = new ReqTable.Key(0x1234, 8);
            int seq = 0;
            // 生产判定（同 SnapLog.Begin）：Drop 的不记；nifm 提交 / 取状态归 NifmLast（按对象只留最后一对，不进主日志）；记之前超上限就停（CapLocked）
            //   tag：每条的内容标记（第几轮、第几条），核对末尾留的是哪一条
            long Run(ReqTable tab, string n, IEnumerable<(long C, int Tag)> cmds, long cap, ReqTable.Key key, out int kept)
            {
                kept = 0;
                foreach ((long c, int tag) in cmds)
                {
                    if (SnapLog.Drop(n, c) || SnapLog.NifmLast(n, c, key, () => BitConverter.GetBytes(tag))) continue;
                    if (SnapLog.CapReached(tab, cap)) continue;
                    tab.Add(seq++, new byte[EntBytes], key); kept++;
                }
                return tab.Bytes;
            }
            IEnumerable<(long, int)> Repeat(long c, int k) { for (int i = 0; i < k; i++) yield return (c, i); }
            IEnumerable<(long, int)> SubmitThenPoll() { yield return (4, -1); foreach (var x in Repeat(0, Polls)) yield return x; }
            IEnumerable<(long, int)> HadesLoop() { for (int r = 0; r < Polls; r++) { yield return (4, r * 10); yield return (0, r * 10 + 1); yield return (0, r * 10 + 2); yield return (0, r * 10 + 3); } }
            string Tail() => string.Join(",", SnapLog.NifmTail().Select(e => BitConverter.ToInt32(e, 0)));
            var rows = new List<(string N, string E, string A)>();

            SnapLog.NifmReset();
            Run(new ReqTable { Collecting = false }, Nifm, SubmitThenPoll(), long.MaxValue, keyA, out int k1);
            rows.Add(("① 提交 1 次后取请求状态 10 万次，主日志条数", "0", k1.ToString()));
            rows.Add(("① 存档末尾：提交、它之后第一次取状态（内容标记）", "-1,0", Tail()));

            SnapLog.NifmReset();
            Run(new ReqTable { Collecting = false }, Nifm, HadesLoop(), long.MaxValue, keyA, out int k2);
            rows.Add(("② 循环 10 万轮「提交 + 取状态 3 次」，主日志条数", "0", k2.ToString()));
            rows.Add(("② 存档末尾：最后一轮的提交与第一次取状态", $"{(Polls - 1) * 10},{(Polls - 1) * 10 + 1}", Tail()));

            SnapLog.NifmReset();
            Run(new ReqTable { Collecting = false }, Nifm, new (long, int)[] { (0, 100) }, long.MaxValue, keyB, out _);   // 提交前取状态：只读
            Run(new ReqTable { Collecting = false }, Nifm, new (long, int)[] { (4, 1), (0, 2), (0, 3) }, long.MaxValue, keyA, out _);
            Run(new ReqTable { Collecting = false }, Nifm, new (long, int)[] { (4, 5) }, long.MaxValue, keyB, out _);
            rows.Add(("③ 两个对象：A 提交 + 取状态、B 提交前取状态不留、只提交", "1,2,5", string.Join(",", Tail().Split(',').OrderBy(int.Parse))));

            SnapLog.NifmReset();
            Run(new ReqTable { Collecting = false }, Nifm, Repeat(1, Polls), long.MaxValue, keyA, out int k4);
            rows.Add(("④ 取结果 10 万次，进日志条数", "0", k4.ToString()));
            Run(new ReqTable { Collecting = false }, Nifm, new (long, int)[] { (2, 0), (3, 0), (11, 0) }, long.MaxValue, keyA, out int k4b);
            rows.Add(("④ 取事件句柄 / 取消 / 设选项各 1 次，进主日志条数", "3", k4b.ToString()));

            const long Cap = 1L << 20;
            long b5 = Run(new ReqTable { Collecting = false }, Other, Repeat(5, Polls), Cap, keyA, out _);
            rows.Add(("⑤ 规则管不到的服务轮询 10 万次，日志字节 ≤ 上限 + 一条", $"≤ {Cap + EntBytes}", b5 <= Cap + EntBytes ? $"≤ {Cap + EntBytes}" : b5.ToString()));

            SnapLog.NifmReset(); SnapLog.NifmRulesOn = false;
            try
            {
                Run(new ReqTable { Collecting = false }, Nifm, HadesLoop(), long.MaxValue, keyA, out int k6);
                rows.Add(("⑥ 负对照：nifm 规则关掉，② 的循环进主日志条数", (Polls * 4).ToString(), k6.ToString()));
                long b6 = Run(new ReqTable { Collecting = false }, Other, Repeat(5, Polls), long.MaxValue, keyA, out _);
                rows.Add(("⑥ 负对照（不设上限 = 旧代码）：日志字节超过 ⑤ 的上界", "超过", b6 > Cap + EntBytes ? "超过" : $"没超（{b6}）"));
            }
            finally { SnapLog.NifmRulesOn = true; SnapLog.NifmReset(); }
            int failures = 0;
            foreach ((string n, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
