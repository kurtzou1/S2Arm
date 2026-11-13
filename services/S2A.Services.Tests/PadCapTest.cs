using System.Threading;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // #809：游戏要 1 人、连着两个手柄时，手柄设置小程序的自动应答原先照配两格，小程序重验「已连 2 > 上限 1」不过、反复重开（一局 2780 次）。
        //   期望按真机（多连的手柄不分给游戏，直到下次小程序放宽）：
        //   ① 先要 2 人 → 两格都连（前提）；② 再要 1–1 人 → 应答 true、只剩 Player1 连着、Player2 样式 0，小程序的重验 Validate(1, 1) 过；
        //   ③ 之后想再开到 2 格（多连的手柄 / 自动玩家）→ 仍 1 格；④ 下次小程序放宽到 2 人 → 又两格都连
        [SoloTest("--pad-cap", Booted = true)]
        private static void PadCapTest()
        {
            var ui = Host.Device.UIHandler;
            uint Style(int i) => (uint)Host.Device.Hid.SharedMemory.Npads[i].InternalState.StyleSet;
            void Settle(System.Func<bool> done) { for (int k = 0; k < 100 && !done(); k++) Thread.Sleep(10); }
            var P = new[] { PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3 };
            ControllerType styles = ControllerType.ProController | ControllerType.JoyconPair;
            Ryujinx.HLE.HOS.Applets.ControllerAppletUIArgs Args(int min, int max) =>
                new() { PlayerCountMin = min, PlayerCountMax = max, SupportedPlayers = P, IsDocked = true, SupportedStyles = styles };

            InputPump.Stop();
            InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
            bool ok2 = ui.DisplayMessageDialog(Args(2, 2));
            Settle(() => Style(1) == 1);
            string two = $"{ok2.ToString().ToLower()} {InputPump.Pads} 个 {Style(0)} / {Style(1)}";

            bool ok1 = ui.DisplayMessageDialog(Args(1, 1));
            Settle(() => Style(1) == 0);
            bool valid = Host.Device.Hid.Npads.Validate(1, 1, styles, out int count, out PlayerIndex primary);
            string one = $"{ok1.ToString().ToLower()} {InputPump.Pads} 个 {Style(0)} / {Style(1)} 重验 {valid.ToString().ToLower()} {count} {primary}";

            InputPump.SetPads(Host.Device, 2);
            Thread.Sleep(50);
            string capped = $"{InputPump.Pads} 个 {Style(1)}";

            bool okAgain = ui.DisplayMessageDialog(Args(2, 2));
            Settle(() => Style(1) == 1);
            string again = $"{okAgain.ToString().ToLower()} {InputPump.Pads} 个 {Style(0)} / {Style(1)}";

            InputPump.Stop();
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 还原，不影响后面的用例

            Check("人数上限：先要 2 人 → 两格都连（前提；应答 手柄数 Player1 / Player2 样式）", "true 2 个 1 / 1", two);
            Check("人数上限：再要 1–1 人 → 只留 Player1、小程序重验通过（应答 手柄数 样式 重验 已连 主手柄）", "true 1 个 1 / 0 重验 true 1 Player1", one);
            Check("人数上限：之后再想开到 2 格 → 仍 1 格（手柄数 Player2 样式）", "1 个 0", capped);
            Check("人数上限：下次小程序放宽到 2 人 → 又两格都连", "true 2 个 1 / 1", again);
        }
    }
}
