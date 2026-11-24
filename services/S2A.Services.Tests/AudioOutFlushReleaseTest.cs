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
    // #2157 作者推演的两处（期望按 NVN / audout 语义手写）：
    //   混合态：交 1、2、3，硬件放完 1、游戏没取 → Flush：取放回 = [1, 2, 3]，返回 True（作废了在播的 2、3）。原先 1 被弹掉清槽，只取回 [2, 3]
    //   已追加未交硬件：硬件位 4 个交满 1–4，再追加 5（追加时硬件有空位就立即交，所以要先交满）→ Flush：返回 True、取放回 = [1..5]；之后 Update，硬件队列里不出现 5。
    //     原先这段走不到：返回 False、5 随下一次 Update 交给硬件播出来
    //   只有已放回、没有在播 / 已追加：Flush 返回 False、已放回的照常可取
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

            // 混合态：已放回未取走的缓冲不丢
            var hwM = new FakeHw(); var evM = new FakeEvent(); var m = NewOut(hwM, evM);
            for (ulong t = 1; t <= 3; t++) { var ub = new AudioUserBuffer { Data = 0x1000 * t, DataSize = 0x100 }; m.AppendBuffer(t, ref ub); }
            m.Update(); hwM.Consumed.Add(1); m.Update();
            string fm = Try(() => m.FlushBuffers().ToString());
            string rm = Try(() => string.Join(",", Released(m)));
            Check("混合态 Flush：返回 True、取放回 = [1,2,3]（已放回未取的 1 不丢）", fm == "True" && rm == "1,2,3", $"返回 {fm}、[{rm}]");

            // 已追加、还没交给硬件的缓冲一并作废：硬件位（4）交满 1–4，再追加 5（留在已追加区）
            var hwA = new FakeHw(); var evA = new FakeEvent(); var a = NewOut(hwA, evA);
            for (ulong t = 1; t <= 5; t++) { var ub = new AudioUserBuffer { Data = 0x1000 * t, DataSize = 0x100 }; a.AppendBuffer(t, ref ub); }
            Check("前提：硬件位交满 1–4，5 还没交给硬件", hwA.Queued.Count == 4 && !hwA.Queued.Contains(5), string.Join(",", hwA.Queued));
            string fa = Try(() => a.FlushBuffers().ToString());
            a.Update();
            string ra = Try(() => string.Join(",", Released(a)));
            Check("追加后立刻 Flush：返回 True、取放回 = [1,2,3,4,5]、之后 Update 硬件队列里没有 5", fa == "True" && ra == "1,2,3,4,5" && !hwA.Queued.Contains(5), $"返回 {fa}、[{ra}]、硬件队列 {string.Join(",", hwA.Queued)}");

            // 只有已放回：没有作废任何缓冲
            var hwR = new FakeHw(); var evR = new FakeEvent(); var r = NewOut(hwR, evR);
            var ur = new AudioUserBuffer { Data = 0x1000, DataSize = 0x100 }; r.AppendBuffer(1, ref ur);
            r.Update(); hwR.Consumed.Add(1); r.Update();
            string fr = Try(() => r.FlushBuffers().ToString());
            string rr = Try(() => string.Join(",", Released(r)));
            Check("只有已放回时 Flush：返回 False、取放回 = [1]", fr == "False" && rr == "1", $"返回 {fr}、[{rr}]");

            Console.WriteLine(bad == 0 ? "audout Flush 放回环：全过" : $"audout Flush 放回环：{bad} 项不通");
            return bad == 0 ? 0 : 1;
        }
    }
}
