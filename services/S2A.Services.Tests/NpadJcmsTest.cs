using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types;
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // hid 3110 InitializeJcms / 3111 FinalizeJcms（Joy-Con 2 光学鼠标缓冲，格式见 compat/tree/.../Hid/HidDevices/NpadJcms.cs）。
    //   期望手写，按随游戏 SDK 的 GetJcmsStates 读法（格 idx = npadId × 2 + 类型、每格 0x2c8 = RingLifo：+0x10 最新槽号、+0x18 笔数、
    //   +0x20 起 17 × 0x28）与游戏读法（状态 +0x08 序号、+0x10 / +0x14 每笔位移、+0x18 bit0 已连接 / bit1 贴着桌面）推出：
    //   ① 3110 交 0x4000 字节传输内存（缓冲先填 0xEE）→ 结果 0、在用、16 格笔数 0、格 0 缓冲格数 17
    //   ② Player1 右只（类型 1 → 格 1，偏移 0x2c8）没有鼠标读数推一笔 → 最新一笔已连接（属性 1）、位移 0、序号 1、顺序锁偶数（= 2）；格 0（左只）不写
    //   ③ 有读数：绝对坐标 (100, 200) → (130, 190)，贴着桌面 → 第二笔位移 (30, -10)、属性 3；时间差 8000 µs → 8,000,000 ns
    //   ④ 坐标回绕：32760 → -32766（16 位）→ 位移 +10；离开桌面（distance ≠ 0）→ 属性 1
    //   ⑤ 换成左只（格 0）→ 格 1 多写一笔未连接（属性 0），格 0 已连接
    //   ⑥ 推 20 笔 → 格 0 笔数封顶 16、最新槽号 = 写入笔数 mod 17
    //   ⑦ 缓冲太小（0x1000 < 0x2c80）→ 结果 0（不挡游戏）、报红 +1、不在用；3111 → 不在用、推数不写
    public static unsafe partial class Program
    {
        [SoloTest("--npad-jcms", Booted = true)]
        private static void NpadJcmsChannel()
        {
            byte* port = _game;
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(port, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)port).Regs[1];
            Msg init = Msg.Cmif(0, Bytes(0L));
            init.SendPid = true;
            Call(sm, init);
            Reply gh = Call(sm, Msg.Cmif(1, Name8("hid")));
            uint hid = gh.Move.Count == 1 ? gh.Move[0] : 0;
            NpadJcms jcms = Host.Device.Hid.Npads.Jcms;

            const ulong Size = 0x4000;
            byte* buf = _game + 0xA000;
            new Span<byte>(buf, (int)Size).Fill(0xEE);

            Msg Initialize(ulong size)
            {
                uint tm = FakeNative.TmemCreate((ulong)buf, size, 1);
                Msg m = Msg.Cmif(3110, Bytes(1L, size));
                m.SendPid = true;
                m.Copy.Add(tm);
                return m;
            }

            ulong U64(ulong off) => *(ulong*)(buf + off);
            int S32(ulong off) => *(int*)(buf + off);
            uint U32(ulong off) => *(uint*)(buf + off);
            ulong Slot(int npad, int type) => (ulong)(npad * 2 + type) * 0x2c8;
            ulong Count(ulong slot) => U64(slot + 0x18);
            // 最新一笔状态的起点（同 SDK：槽号 +0x10 指最新一笔，状态在 AtomicStorage 取样序号之后）
            ulong Latest(ulong slot) => slot + 0x20 + U64(slot + 0x10) * 0x28 + 8;
            string State(ulong s) => $"序号 {U64(s + 0x08)}、位移 ({S32(s + 0x10)}, {S32(s + 0x14)})、属性 {U32(s + 0x18)}";
            // 顺序锁（状态前 8 字节）：SDK 见奇数就一直重读（游戏主线程卡死），写完必须是偶数 = 序号 × 2
            string Seq(ulong s) => U64(s - 8) % 2 == 0 && U64(s - 8) == U64(s + 0x08) * 2 ? "偶数 = 序号 × 2" : $"{U64(s - 8)}（序号 {U64(s + 0x08)}）";

            // ①
            Reply en = Call(hid, Initialize(Size));
            ulong counts = 0;
            for (int i = 0; i < 16; i++) counts += Count((ulong)i * 0x2c8);
            Check("NpadJcms ① 3110 交 0x4000 字节传输内存", "结果 0、在用、16 格笔数合计 0、格 0 缓冲格数 17",
                $"结果 {en.Result}、{(jcms.Active ? "在用" : "不在用")}、16 格笔数合计 {counts}、格 0 缓冲格数 {U64(0x08)}");

            // ②
            jcms.Push(0, 1, false, 0, 0, false, 1000);
            Check("NpadJcms ② 右只没有鼠标读数：最新一笔", "笔数 1、序号 1、位移 (0, 0)、属性 1、顺序锁 偶数 = 序号 × 2；左只格笔数 0",
                $"笔数 {Count(Slot(0, 1))}、{State(Latest(Slot(0, 1)))}、顺序锁 {Seq(Latest(Slot(0, 1)))}；左只格笔数 {Count(Slot(0, 0))}");

            // ③
            jcms.Push(0, 1, true, 100, 200, true, 9000);
            jcms.Push(0, 1, true, 130, 190, true, 17000);
            ulong s3 = Latest(Slot(0, 1));
            Check("NpadJcms ③ 有读数、贴着桌面：位移是两笔之差、时间差纳秒", "序号 3、位移 (30, -10)、属性 3、时间差 8000000",
                $"{State(s3)}、时间差 {U64(s3)}");

            // ④
            jcms.Push(0, 1, true, 32760, 0, false, 25000);
            jcms.Push(0, 1, true, -32766, 0, false, 33000);
            Check("NpadJcms ④ 坐标回绕、离开桌面", "序号 5、位移 (10, 0)、属性 1", State(Latest(Slot(0, 1))));

            // ⑤
            jcms.Push(0, 0, false, 0, 0, false, 41000);
            Check("NpadJcms ⑤ 换成左只：右只格写一笔未连接、左只格已连接", "右只 序号 6、位移 (0, 0)、属性 0；左只 序号 1、位移 (0, 0)、属性 1",
                $"右只 {State(Latest(Slot(0, 1)))}；左只 {State(Latest(Slot(0, 0)))}");

            // ⑥
            for (int i = 0; i < 20; i++) jcms.Push(0, 0, true, (short)(i * 3), 0, true, 49000 + (ulong)i * 8000);
            Check("NpadJcms ⑥ 推 20 笔：笔数封顶、最新槽号、最新位移、顺序锁", "笔数 16、槽号 4、序号 21、位移 (3, 0)、属性 3、顺序锁 偶数 = 序号 × 2",
                $"笔数 {Count(Slot(0, 0))}、槽号 {U64(Slot(0, 0) + 0x10)}、{State(Latest(Slot(0, 0)))}、顺序锁 {Seq(Latest(Slot(0, 0)))}");

            // ⑥b 照 SDK GetJcmsStates 的读法读 16 笔（从最旧到最新：槽 = (最新槽号 − 笔数 + 18) mod 17；顺序锁奇数就重读、
            //   相邻两笔取样序号差不是 1 也重读）：读不下来 = 游戏主线程在 SDK 里一直重读（实机卡死）
            string SdkRead(ulong slot)
            {
                ulong tail = U64(slot + 0x10), n = Math.Min(U64(slot + 0x18), 16), prev = 0;
                for (ulong i = 0; i < n; i++)
                {
                    ulong e = slot + 0x20 + (tail + 18 - n + i) % 17 * 0x28;
                    if (U64(e) % 2 != 0) return $"第 {i} 笔顺序锁是奇数 {U64(e)}，SDK 会一直重读";
                    if (i > 0 && U64(e + 0x10) - prev != 1) return $"第 {i} 笔序号 {U64(e + 0x10)} 与前一笔 {prev} 不连续，SDK 会一直重读";
                    prev = U64(e + 0x10);
                }
                return $"读到 {n} 笔、最新序号 {prev}";
            }
            Check("NpadJcms ⑥b 照 SDK 读法读得下来（不卡死）", "读到 16 笔、最新序号 21", SdkRead(Slot(0, 0)));

            // ⑥c 一对（bothSides）：另一侧也写已连接、位移 0；换回单侧时另一侧写未连接
            jcms.Push(1, 1, true, 5, 5, true, 400000, bothSides: true);
            jcms.Push(1, 1, true, 9, 5, true, 408000, bothSides: true);
            string pairSides = $"右 {State(Latest(Slot(1, 1)))}；左 {State(Latest(Slot(1, 0)))}";
            jcms.Push(1, 1, true, 9, 5, true, 416000);
            Check("NpadJcms ⑥c 一对：左右两侧都已连接（另一侧位移 0）；改单侧后另一侧未连接",
                "右 序号 2、位移 (4, 0)、属性 3；左 序号 2、位移 (0, 0)、属性 1 → 左 属性 0",
                $"{pairSides} → 左 属性 {U32(Latest(Slot(1, 0)) + 0x18)}");

            // ⑥e 一对、两只都有鼠标（左右各自滑）：左只格、右只格各自求差，互不干扰（原先一对只送右只的，拿左只玩没反应）
            NpadJcms.Side L(short x, short y) => new() { Present = true, Known = true, X = x, Y = y, OnSurface = true };
            jcms.Push(3, L(100, 0), L(500, 0), 500000, pair: true);
            jcms.Push(3, L(90, 7), L(520, 0), 508000, pair: true);
            Check("NpadJcms ⑥e 一对两只都有鼠标：左右各自的位移", "左 位移 (-10, 7)、属性 3；右 位移 (20, 0)、属性 3",
                $"左 位移 ({S32(Latest(Slot(3, 0)) + 0x10)}, {S32(Latest(Slot(3, 0)) + 0x14)})、属性 {U32(Latest(Slot(3, 0)) + 0x18)}；右 位移 ({S32(Latest(Slot(3, 1)) + 0x10)}, {S32(Latest(Slot(3, 1)) + 0x14)})、属性 {U32(Latest(Slot(3, 1)) + 0x18)}");

            // ⑥g 好几位玩家一拍一起写（PushMany，#520：两人各横握一只 Joy-Con 2 的项目游戏两格都查）：P1 右只、P2 左只都已连接；
            //   负对照：下一拍只剩 P1 → P2 那格写未连接，P1 照旧（改前单人 Push 会把别人那格清掉）
            var two = new System.Collections.Generic.List<NpadJcms.Entry>
            {
                new() { NpadId = 4, Right = L(1, 1), TimestampUs = 600000 },
                new() { NpadId = 5, Left = L(2, 2), TimestampUs = 600000 },
            };
            jcms.PushMany(two);
            string both = $"P1 右 属性 {U32(Latest(Slot(4, 1)) + 0x18)}、P2 左 属性 {U32(Latest(Slot(5, 0)) + 0x18)}";
            jcms.PushMany(new[] { new NpadJcms.Entry { NpadId = 4, Right = L(3, 1), TimestampUs = 608000 } });
            Check("NpadJcms ⑥g 两位玩家各自的 Joy-Con 2 同时已连接；只剩 P1 时 P2 那格未连接",
                "P1 右 属性 3、P2 左 属性 3 → P1 右 属性 3、P2 左 属性 0",
                $"{both} → P1 右 属性 {U32(Latest(Slot(4, 1)) + 0x18)}、P2 左 属性 {U32(Latest(Slot(5, 0)) + 0x18)}");

            // ⑥d Joy-Con 2 样式位：游戏只收「掌机 | bit 12」（Joy-Con 2 一对）时，一代双 Joy-Con 不连；宿主报 Joy-Con 2 后连上、样式 = JoyDual | bit 12，
            //   输入照常写进 JoyDual 的 LIFO（内部按一代位走）；报回不是 Joy-Con 2 → 又断开
            NpadDevices npads = Host.Device.Hid.Npads;
            ControllerType supportedBefore = npads.SupportedStyleSets;
            npads.SupportedStyleSets = ControllerType.Handheld | (ControllerType)(1 << 12);
            npads.Configure(new ControllerConfig { Player = PlayerIndex.Player1, Type = ControllerType.JoyconPair });
            uint styleOff = (uint)npads.StyleOf(PlayerIndex.Player1);
            npads.SetJoycon2(true);
            uint styleOn = (uint)npads.StyleOf(PlayerIndex.Player1);
            npads.Update(new System.Collections.Generic.List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1, Buttons = (ControllerKeys)1 } });
            // 手柄设置小程序（ShowControllerSupport）同一判断：只收 Joy-Con 2 一对时认得连着的 Joy-Con 2（原先判没有可配的手柄、游戏反复重开卡住）
            bool appletOk = npads.Validate(1, 1, ControllerType.Handheld | (ControllerType)(1 << 12), out int appletCount, out PlayerIndex appletPrimary);
            npads.SetJoycon2(false);
            uint styleBack = (uint)npads.StyleOf(PlayerIndex.Player1);
            Check("NpadJcms ⑥d 只收 Joy-Con 2 一对时：一代不连 → Joy-Con 2 连上（JoyDual | bit 12）、输入照写、小程序认得 → 不是 Joy-Con 2 又断开",
                "样式 0x0 → 0x1004 → 0x0；小程序 True 1 Player1", $"样式 0x{styleOff:X} → 0x{styleOn:X} → 0x{styleBack:X}；小程序 {appletOk} {appletCount} {appletPrimary}");
            npads.SupportedStyleSets = supportedBefore;
            npads.Configure();

            // ⑥f 合入时补：Joy-Con 2 连着、游戏只声明一代样式（Switch 1 游戏）→ 样式值保持一代原样 JoyDual（0x4），不带它不认识的 bit 12；
            //   游戏随后声明加上 bit 12 → 重配一遍、样式 = JoyDual | bit 12（0x1004）
            npads.SupportedStyleSets = ControllerType.Handheld | ControllerType.JoyconPair;
            npads.Configure(new ControllerConfig { Player = PlayerIndex.Player1, Type = ControllerType.JoyconPair });
            npads.SetJoycon2(true);
            uint oldGame = (uint)npads.StyleOf(PlayerIndex.Player1);
            npads.SupportedStyleSets = ControllerType.Handheld | ControllerType.JoyconPair | (ControllerType)(1 << 12);
            uint newGame = (uint)npads.StyleOf(PlayerIndex.Player1);
            npads.SetJoycon2(false);
            Check("NpadJcms ⑥f Joy-Con 2 连着：只声明一代样式的游戏看到一代原样；声明了 bit 12 才带上",
                "样式 0x4 → 0x1004", $"样式 0x{oldGame:X} → 0x{newGame:X}");
            npads.SupportedStyleSets = supportedBefore;
            npads.Configure();

            // ⑦
            long red0 = Red.Total;
            Reply fin = Call(hid, Msg.Cmif(3111, Bytes(1L)));
            Reply small = Call(hid, Initialize(0x1000));
            ulong before = Count(Slot(0, 0));
            jcms.Push(0, 0, true, 0, 0, true, 300000);
            Check("NpadJcms ⑦ 3111 后、缓冲太小时：不挡游戏、报红、不写", "结果 0 / 0、报红 +1、不在用、格 0 笔数不变 16",
                $"结果 {fin.Result} / {small.Result}、报红 +{Red.Total - red0}、{(jcms.Active ? "在用" : "不在用")}、格 0 笔数不变 {before}");
        }
    }
}
