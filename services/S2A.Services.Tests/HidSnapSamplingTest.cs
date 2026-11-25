using Ryujinx.HLE;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 即时存档恢复后 HID 采样号接着数（#2199：陷阵之志回到这一刻后触屏必失效）。
    //   快照那一局 A 写了 50 条触屏、30 条手势（采样号 1..50 / 1..30）；恢复局 B 的共享内存是新建的。
    //   期望（按 HID 语义手写，不跑被测代码算）：B 放回 A 的环后，下一条触屏采样号 = 50 + 1 = 51，下一条手势 = 30 + 1 = 31。
    //   反证（不放回，即修前）：B 下一条触屏 = 0 + 1 = 1、手势 = 1，都小于游戏记着的 50 / 30，游戏当旧数据丢掉。
    //   格式不对（魔数错）：Restore 回 -1，B 的触屏环一条都不改（仍是 B 自己写的 7）
    public static partial class Program
    {
        [SoloTest("--hid-snap-sampling")]
        internal static unsafe int HidSnapSampling()
        {
            int bad = 0;
            void Check(string what, bool ok, string got) { Console.WriteLine($"{(ok ? "通过" : "不通")} {what}{(ok ? "" : $"：真结果 {got}")}"); if (!ok) bad++; }

            ref SharedMemory a = ref Fresh();
            for (int i = 0; i < 50; i++) Touch(ref a);
            ulong ga = GestureDevice.StartSampling(ref a.Gesture);
            for (int i = 0; i < 30; i++) GestureDevice.Write(ref a.Gesture, ref ga, default);
            var ms = new MemoryStream(); using (var w = new BinaryWriter(ms, System.Text.Encoding.UTF8, true)) S2AHidSnap.Save(ref a, w);

            ref SharedMemory b = ref Fresh();
            ms.Position = 0; int n; using (var r = new BinaryReader(ms, System.Text.Encoding.UTF8, true)) n = S2AHidSnap.Restore(ref b, r);
            Check("放回 4 个环", n == 4, n.ToString());
            ulong t = Touch(ref b);
            Check("恢复后下一条触屏采样号 = 51", t == 51, t.ToString());
            ulong gb = GestureDevice.StartSampling(ref b.Gesture); GestureDevice.Write(ref b.Gesture, ref gb, default);
            ulong g = b.Gesture.GetCurrentEntryRef().SamplingNumber;
            Check("恢复后下一条手势采样号 = 31", g == 31, g.ToString());

            ref SharedMemory c = ref Fresh();
            ulong tc = Touch(ref c); ulong gc = GestureDevice.StartSampling(ref c.Gesture); GestureDevice.Write(ref c.Gesture, ref gc, default);
            ulong gcv = c.Gesture.GetCurrentEntryRef().SamplingNumber;
            Check("反证：不放回时触屏从 1 起（小于游戏记着的 50）", tc == 1, tc.ToString());
            Check("反证：不放回时手势从 1 起（小于游戏记着的 30）", gcv == 1, gcv.ToString());

            ref SharedMemory d = ref Fresh();
            for (int i = 0; i < 7; i++) Touch(ref d);
            byte[] raw = ms.ToArray(); raw[0] ^= 0xFF;
            int nd; using (var r = new BinaryReader(new MemoryStream(raw))) nd = S2AHidSnap.Restore(ref d, r);
            ulong td = d.TouchScreen.GetCurrentEntryRef().SamplingNumber;
            Check("魔数错：回 -1", nd == -1, nd.ToString());
            Check("魔数错：触屏环不动（仍是 7）", td == 7, td.ToString());

            Console.WriteLine(bad == 0 ? "HID 采样号接续：全部通过" : $"HID 采样号接续：{bad} 项不通");
            return bad == 0 ? 0 : 1;
        }

        // SharedMemory 有 256 KB，数组装不下（运行时拒绝），放原生内存（单测进程跑完即退，不放）
        private static unsafe ref SharedMemory Fresh()
        {
            void* p = NativeMemory.AllocZeroed((nuint)Unsafe.SizeOf<SharedMemory>());
            ref SharedMemory m = ref Unsafe.AsRef<SharedMemory>(p); m = SharedMemory.Create(); return ref m;
        }

        // 同 TouchDevice.Update：新一条的采样号 = 环里最后一条 + 1。回新写的采样号
        private static ulong Touch(ref SharedMemory m)
        {
            ref TouchScreenState prev = ref m.TouchScreen.GetCurrentEntryRef();
            TouchScreenState s = new() { SamplingNumber = prev.SamplingNumber + 1 };
            m.TouchScreen.Write(ref s);
            return s.SamplingNumber;
        }
    }
}
