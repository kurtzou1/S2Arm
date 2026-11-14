using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static void PressA(ref GamepadInput input) => input.Buttons |= ControllerKeys.A;
        [UnmanagedCallersOnly] private static int AutoplayTwoPads() => 2;
        [UnmanagedCallersOnly] private static uint AutoplayP2Right() => 1u << 14;   // S2A_AP_RIGHT（十字键右）
        [UnmanagedCallersOnly] private static uint AutoplayP1Left() => 1u << 12;    // S2A_AP_LEFT（十字键左）：自动玩家给一号的键

        // 本机双手柄（强制本地合作，如双人成行：游戏要两个已连接的手柄才进得了游戏）。期望按真机：
        //   ① 单手柄（缺省）配 Player1 Pro → 只有 Player1 连着，Player2 样式 0（负对照：不多出第二格）
        //   ② 手柄设置小程序声明至少 2 人 → 应答 true，Player1、Player2 都连着且是 Pro（FullKey = 1）
        //   ③ 第二个手柄镜像第一个的输入：只给主手柄按 A，Player2 的全键当前条也有 A（位 0）
        //   ④ 自动玩家要 2 个手柄（s2a_autoplay_pads = 2，没有小程序）→ 采样泵自己开到 2；它单给二号手柄的十字键右只到 Player2，Player1 没有；
        //     它给一号的十字键左只到 Player1、不镜像到 Player2（二号归自动玩家管）
        [SoloTest("--two-pads", Booted = true)]
        private static void TwoPadsTest()
        {
            var ui = Host.Device.UIHandler;
            uint Style(int i) => (uint)Host.Device.Hid.SharedMemory.Npads[i].InternalState.StyleSet;
            ulong Buttons(int i) => (ulong)Host.Device.Hid.SharedMemory.Npads[i].InternalState.FullKey.GetCurrentEntryRef().Buttons;
            void Settle(System.Func<bool> done) { for (int k = 0; k < 100 && !done(); k++) Thread.Sleep(10); }

            InputPump.Stop();
            InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
            Settle(() => Style(0) == 1);
            Thread.Sleep(100);
            string single = $"{InputPump.Pads} 个 {Style(0)} / {Style(1)}";

            var P = new[] { PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3 };
            bool ok = ui.DisplayMessageDialog(new Ryujinx.HLE.HOS.Applets.ControllerAppletUIArgs
            {
                PlayerCountMin = 2, PlayerCountMax = 2, SupportedPlayers = P, IsDocked = false,
                SupportedStyles = ControllerType.ProController | ControllerType.Handheld | ControllerType.JoyconPair,
            });
            Settle(() => Style(1) == 1);
            string two = $"{ok.ToString().ToLower()} {InputPump.Pads} 个 {Style(0)} / {Style(1)}";

            InputPump.InputHook = &PressA;
            Settle(() => (Buttons(1) & 1) != 0);
            string mirror = $"{Buttons(0) & 1} / {Buttons(1) & 1}";
            InputPump.InputHook = null;

            InputPump.Stop();   // 收局回到 S2A_AP_PADS 给的个数（缺省 1）
            string reset = $"{InputPump.Pads} 个";

            InputPump.AutoplayPads = &AutoplayTwoPads;
            InputPump.AutoplayKeys2 = &AutoplayP2Right;
            InputPump.AutoplayKeys1 = &AutoplayP1Left;
            InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
            Settle(() => Style(1) == 1 && (Buttons(1) & (1u << 14)) != 0 && (Buttons(0) & (1u << 12)) != 0);
            string p2 = $"{InputPump.Pads} 个 {Style(1)} 右 {(Buttons(0) >> 14) & 1} / {(Buttons(1) >> 14) & 1} 左 {(Buttons(0) >> 12) & 1} / {(Buttons(1) >> 12) & 1}";
            InputPump.AutoplayKeys1 = null;
            InputPump.AutoplayPads = null;
            InputPump.AutoplayKeys2 = null;
            InputPump.Stop();
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 还原，不影响后面的用例

            Check("双手柄：单手柄缺省只连 Player1（Player1 / Player2 样式）", "1 个 1 / 0", single);
            Check("双手柄：小程序要至少 2 人 → 两格都连成 Pro", "true 2 个 1 / 1", two);
            Check("双手柄：第二个镜像第一个的输入（只给主手柄按 A，Player1 / Player2 的 A 位）", "1 / 1", mirror);
            Check("双手柄：收局回到缺省手柄数", "1 个", reset);
            Check("双手柄：自动玩家要 2 个 → 接上 Player2；单给二号的十字键右只到 Player2、给一号的左不镜像（手柄数 样式 右 / 左 Player1 / Player2）", "2 个 1 右 0 / 1 左 1 / 0", p2);
        }

        // 手柄设置 / 选用户小程序在共用 HostUi 上的应答判据（#1574：安卓撤掉专用 ControllerAppletAnswer 后与 iOS 同一份）。
        //   对位原安卓 ControllerAppletTests 判据：掌机样式被收 → 留掌机、只收 Pro / 底座 → Player1 配 Pro、
        //   底座只收掌机号 → 报红回 false；已配好仍连验第 3 次报红交回、计数复位；单只 Joy-Con 按真机横握一只配上。
        //   双人部分由上面 TwoPadsTest ②③④ 覆盖：要至少 2 人 → SetPads 开第二格、两格都连 Pro、输入镜像、收局复位。
        [SoloTest("--hostui-applets", Booted = true)]
        private static void HostUiAppletAnswers()
        {
            var ui = Host.Device.UIHandler;
            uint Style(int i) => (uint)Host.Device.Hid.SharedMemory.Npads[i].InternalState.StyleSet;
            void Settle(System.Func<bool> done) { for (int k = 0; k < 100 && !done(); k++) Thread.Sleep(10); }
            PlayerIndex[] all =
            {
                PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3, PlayerIndex.Player4,
                PlayerIndex.Player5, PlayerIndex.Player6, PlayerIndex.Player7, PlayerIndex.Player8, PlayerIndex.Handheld,
            };
            Ryujinx.HLE.HOS.Applets.ControllerAppletUIArgs Args(int min, ControllerType styles, bool docked, PlayerIndex[] players) =>
                new() { PlayerCountMin = min, PlayerCountMax = 4, SupportedPlayers = players, IsDocked = docked, SupportedStyles = styles };
            ControllerType handOrPro = ControllerType.Handheld | ControllerType.ProController;

            Check("手柄小程序装配：服务层登记的宿主界面是共用 HostUi", "HostUi", ui.GetType().Name);

            // 掌机样式被收（缺省已配掌机）：应答保留掌机；已配好仍连验不过连来 3 次 → 报红交回游戏（不停局），计数复位
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);
            Settle(() => Style((int)PlayerIndex.Handheld) == (uint)ControllerType.Handheld);
            var stay = Args(1, handOrPro, false, all);
            bool s1 = ui.DisplayMessageDialog(stay), s2 = ui.DisplayMessageDialog(stay);
            long red0 = Red.Total;
            bool s3 = ui.DisplayMessageDialog(stay);
            bool s4 = ui.DisplayMessageDialog(stay);
            Check("手柄小程序：掌机被收应答保留；已配好仍连验第 3 次报红、之后复位", "True True → False +1红 → True",
                $"{s1} {s2} → {s3} +{Red.Total - red0}红 → {s4}");
            Check("手柄小程序：保留后掌机格样式不变", $"{(uint)ControllerType.Handheld}", Style((int)PlayerIndex.Handheld).ToString());

            // 只收 Pro：第一可用手柄号配 Pro
            var proOnly = Args(0, ControllerType.ProController, false, new[] { PlayerIndex.Player1, PlayerIndex.Player2 });
            Check("手柄小程序：只收 Pro → Player1 配 Pro", $"True / {(uint)ControllerType.ProController}",
                $"{ui.DisplayMessageDialog(proOnly)} / {Style((int)PlayerIndex.Player1)}");

            // 底座：掌机号不可用 → Player1 配 Pro
            var docked = Args(1, handOrPro, true, all);
            Check("手柄小程序：底座配 Player1 Pro（不收掌机格）", $"True / {(uint)ControllerType.ProController}",
                $"{ui.DisplayMessageDialog(docked)} / {Style((int)PlayerIndex.Player1)}");

            // 底座且只收掌机号：一个手柄配不出 → 报红回 false（不停局、不改配）
            red0 = Red.Total;
            var dockedHand = Args(1, ControllerType.Handheld, true, all);
            Check("手柄小程序：底座只收掌机 → 报红、false", "False / +1红",
                $"{ui.DisplayMessageDialog(dockedHand)} / +{Red.Total - red0}红");

            // 只收单只 Joy-Con（Zumba 类）：按真机横握一只确认配上（样式只给左只就配左只）
            var joyLeft = Args(1, ControllerType.JoyconLeft, false, all);
            Check("手柄小程序：只收单只 Joy-Con 左 → Player1 配左只", $"True / {(uint)ControllerType.JoyconLeft}",
                $"{ui.DisplayMessageDialog(joyLeft)} / {Style((int)PlayerIndex.Player1)}");

            // 只声明 Joy-Con 2 左 / 右只位（例：两人各横握一只 Joy-Con 2 的项目，样式 掌机 | bit 13 | bit 14）：连着 Joy-Con 2 时照 StyleSupported 认、配单只；
            //   负对照：没连 Joy-Con 2（只认一代位）→ 照旧报红回 false
            var j2Single = Args(1, ControllerType.Handheld | (ControllerType)((1 << 13) | (1 << 14)), true, all);
            Host.Device.Hid.Npads.SetJoycon2(true);
            bool j2ok = ui.DisplayMessageDialog(j2Single);
            Settle(() => (Style((int)PlayerIndex.Player1) & 0xfff) == (uint)ControllerType.JoyconRight);
            Check("手柄小程序：只收 Joy-Con 2 单只位、连着 Joy-Con 2 → Player1 配右只", $"True / {(uint)ControllerType.JoyconRight}",
                $"{j2ok} / {Style((int)PlayerIndex.Player1) & 0xfff}");
            Host.Device.Hid.Npads.SetJoycon2(false);
            red0 = Red.Total;
            Check("手柄小程序：负对照：没连 Joy-Con 2 → 报红、false", "False / +1红", $"{ui.DisplayMessageDialog(j2Single)} / +{Red.Total - red0}红");

            // 选用户：只有一个用户 = AccountManager.LastOpenedUser（01006F8002326000岛民按建档用户号认人）
            Check("选用户小程序：回 LastOpenedUser",
                Host.Device.System.AccountManager.LastOpenedUser.UserId.ToString(),
                ui.ShowPlayerSelectDialog().UserId.ToString());

            InputPump.Stop();
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 还原，不影响其它用例
        }
    }
}
