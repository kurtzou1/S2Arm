using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志：HID 取握持方式（GetNpadJoyHoldType 121）是纯查询，不进日志（D-3F4A：每帧查一次，110002 条、32 MB）
        //   ① 每帧查一次、60 帧 × 28 分钟 = 100800 次 → 进日志 0 条；② 设握持方式（120）、设支持的手柄类型（100）、激活手柄（103）各 1 次 → 3 条
        [SoloTest("--snap-hid-query-log")]
        private static int SnapHidQueryLog()
        {
            const string N = "Ryujinx.HLE.HOS.Services.Hid.IHidServer";
            int Logged(IEnumerable<long> cmds) { int k = 0; foreach (long c in cmds) if (!SnapLog.Drop(N, c)) k++; return k; }
            IEnumerable<long> PerFrame(int frames) { for (int i = 0; i < frames; i++) yield return 121; }
            const int Frames = 60 * 60 * 28;
            var rows = new List<(string N, string E, string A)>
            {
                ("① 每帧取握持方式、28 分钟 100800 次，进日志条数", "0", Logged(PerFrame(Frames)).ToString()),
                ("② 改状态的 3 个命令（120 / 100 / 103）各 1 次，进日志条数", "3", Logged(new long[] { 120, 100, 103 }).ToString()),
            };
            int failures = 0;
            foreach ((string n, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
