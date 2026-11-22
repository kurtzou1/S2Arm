using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志：公共状态（ICommonStateGetter）的纯查询不进日志，日志不随游玩时长涨（D-4FFR：一款足球游戏每帧取性能模式，28 分钟 25.8 万条、97 MB，托管堆 GC 反复跑、出帧停住）。期望按剧本手算：
        //   ① 每帧查一次性能模式（6）、60 帧 × 28 分钟 = 100800 次 → 进日志 0 条；② 9 个纯查询各 1 次 → 0 条；③ 改状态 / 建句柄的 12 个命令（0 1 10 13 51 52 53 54 61 66 130 900）各 1 次 → 12 条；
        //   ④ 负对照：规则关掉，① 的 100800 次全进日志
        [SoloTest("--snap-stategetter-log")]
        private static int SnapStateGetterLog()
        {
            const string N = "Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.SystemAppletProxy.ICommonStateGetter";
            int Logged(IEnumerable<long> cmds) { int k = 0; foreach (long c in cmds) if (!SnapLog.Drop(N, c)) k++; return k; }
            IEnumerable<long> PerFrame(int frames) { for (int i = 0; i < frames; i++) yield return 6; }
            long[] queries = { 5, 6, 8, 9, 60, 62, 68, 91, 300 }, keep = { 0, 1, 10, 13, 51, 52, 53, 54, 61, 66, 130, 900 };
            const int Frames = 60 * 60 * 28;
            var rows = new List<(string N, string E, string A)>
            {
                ("① 每帧取性能模式、28 分钟 100800 次，进日志条数", "0", Logged(PerFrame(Frames)).ToString()),
                ("② 9 个纯查询各 1 次，进日志条数", "0", Logged(queries).ToString()),
                ("③ 改状态 / 建句柄的 12 个命令各 1 次，进日志条数", "12", Logged(keep).ToString()),
            };
            SnapLog.StateGetterQueryRulesOn = false;
            try { rows.Add(("④ 负对照：规则关掉，① 的 100800 次进日志条数", Frames.ToString(), Logged(PerFrame(Frames)).ToString())); }
            finally { SnapLog.StateGetterQueryRulesOn = true; }
            int failures = 0;
            foreach ((string n, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
