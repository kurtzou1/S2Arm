using System;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    // HID 条目固定周期写入（D-2T9N）：输入不变时也按 InputPump.HidSamplePeriodUs 醒一次、写一条 Npad 条目（采样号 +1）。
    //   期望值手算：周期 5000 µs，格点 = 起点 + k × 5000，取严格晚于 now 的第一个。纯逻辑，不 boot 真机。
    public static partial class Program
    {
        [SoloTest("--hid-sample")]
        private static int HidSample()
        {
            int bad = 0;
            void Row(string what, string expect, string actual)
            {
                bool ok = expect == actual; if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} HID 采样周期 {what}：{expect} → {actual}");
            }

            // 玩家实测：8 ms 症状消失、12 ms 仍轻微；周期必须 ≤ 8000 µs
            Row("周期不超过 8 ms", "True", (InputPump.HidSamplePeriodUs <= 8_000).ToString());
            Row("首轮从 now 起算一个周期", "6000", InputPump.NextSample(0, 1_000).ToString());
            Row("还没到格点：不动", "6000", InputPump.NextSample(6_000, 3_000).ToString());
            Row("正好到格点：取下一个", "11000", InputPump.NextSample(6_000, 6_000).ToString());
            Row("过了格点 1 µs：取下一个", "11000", InputPump.NextSample(6_000, 6_001).ToString());
            Row("晚醒好几个周期：跳到 now 之后的格点、不漂移", "21000", InputPump.NextSample(6_000, 17_500).ToString());

            // 输入不变的一段：只有采样格点在推，连续三次醒来间隔都不超过一个周期
            ulong next = 0, now = 1_000, worst = 0;
            for (int i = 0; i < 3; i++)
            {
                next = InputPump.NextSample(next, now);
                worst = Math.Max(worst, next - now);
                now = next + (i == 1 ? 700UL : 0UL);   // 第二次晚醒 0.7 ms
            }
            Row("输入不变时最长等待", "5000", worst.ToString());
            Row("晚醒后仍落在原格点上", "16000", next.ToString());

            Console.WriteLine($"{(bad == 0 ? "🟢" : "🔴")} HID 采样周期单测：8 项，不符 {bad}");
            return bad == 0 ? 0 : 1;
        }
    }
}
