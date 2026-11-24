using Ryujinx.Audio.Common;
using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // audout Flush 的放回环账目（AudioDeviceSession.FlushBuffers）：
    //   交给硬件 3 个、一个都没放完 → Flush：游戏取放回拿到 [1, 2, 3]、放回事件发过；
    //   之后追加 4、硬件放完 4 → 游戏取放回拿到 [4]（不抛）；再追加 5，ContainsBuffer(5) = true（扫整个环不撞空槽）。
    //   Flush 时没有在播缓冲：取放回为空、不多发事件（与原先一致）。
    //   反证：原先在播缓冲被直接弹掉、放回下标不动，第二步取放回读到空槽 → NullReferenceException（宿主闪退）
    public static partial class Program
    {
        [SoloTest("--audout-flush-release")]
        internal static int AudOutFlushRelease()
        {
            int bad = 0;
            void Check(string what, bool ok, string got) { Console.WriteLine($"{(ok ? "通过" : "不通")} {what}{(ok ? "" : $"：真结果 {got}")}"); if (!ok) bad++; }
            string Try(Func<string> f) { try { return f(); } catch (Exception e) { return e.GetType().Name; } }

            var hw = new FakeHw(); var ev = new FakeEvent(); var o = NewOut(hw, ev);
            for (ulong t = 1; t <= 3; t++) { var ub = new AudioUserBuffer { Data = 0x1000 * t, DataSize = 0x100 }; o.AppendBuffer(t, ref ub); }
            o.Update();
            Check("Flush 前 3 个都交给了硬件", hw.Queued.Count == 3, string.Join(",", hw.Queued));
            int sig0 = ev.Signals;
            o.FlushBuffers();
            Check("Flush 发了放回事件", ev.Signals > sig0, $"+{ev.Signals - sig0}");
            string r1 = Try(() => string.Join(",", Released(o)));
            Check("Flush 后取放回 = [1,2,3]", r1 == "1,2,3", r1);

            var u4 = new AudioUserBuffer { Data = 0x4000, DataSize = 0x100 }; o.AppendBuffer(4, ref u4);
            hw.Consumed.Add(4); o.Update();
            string r2 = Try(() => string.Join(",", Released(o)));
            Check("之后放完 4，取放回 = [4]", r2 == "4", r2);
            var u5 = new AudioUserBuffer { Data = 0x5000, DataSize = 0x100 }; o.AppendBuffer(5, ref u5);
            string c5 = Try(() => o.ContainsBuffer(5).ToString());
            Check("追加 5 后 ContainsBuffer(5) = True", c5 == "True", c5);

            // 没有在播缓冲时 Flush：行为与原先一致
            var hwE = new FakeHw(); var evE = new FakeEvent(); var e = NewOut(hwE, evE);
            int sigE = evE.Signals;
            e.FlushBuffers();
            string rE = Try(() => string.Join(",", Released(e)));
            Check("空会话 Flush：取放回为空、不发事件", rE == "" && evE.Signals == sigE, $"[{rE}] +{evE.Signals - sigE}");

            Console.WriteLine(bad == 0 ? "audout Flush 放回环：全过" : $"audout Flush 放回环：{bad} 项不通");
            return bad == 0 ? 0 : 1;
        }
    }
}
