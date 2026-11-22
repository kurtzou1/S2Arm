using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    // 本地多手柄（Mac 游戏窗口双人 / 四人分屏）：宿主导出 s2a_vpad_read_pad 时二号起各读各的槽；
    //   没导出时（iOS 壳 / 安卓 / 旧宿主）保持原路径，第二格仍镜像第一格。纯逻辑，不 boot 真机。
    public static unsafe partial class Program
    {
        // 假的按槽读取器：第 index 槽只按第 index 位，摇杆按槽位给不同值（用来分辨是不是各读各的）
        [UnmanagedCallersOnly]
        private static uint FakePadRead(int index, int* sticks)
        {
            sticks[0] = index * 100; sticks[1] = -index * 100;
            sticks[2] = index * 10; sticks[3] = -index * 10;
            return 1u << index;
        }

        [SoloTest("--multi-pad")]
        private static int MultiPad()
        {
            int bad = 0;
            void Row(string what, string expect, string actual)
            {
                bool ok = expect == actual; if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 多手柄 {what}：{expect} → {actual}");
            }

            // ① 走哪条路径：有导出、开了 ≥2 格、且确实 ≥2 只手柄在线才各读各的
            Row("导出 + 2 格 + 2 只在线 → 各读各的", "True", InputPump.UsePerPadInput(true, 2, PlayerIndex.Player2, 2).ToString());
            Row("导出 + 4 格 + 4 只在线 → 各读各的", "True", InputPump.UsePerPadInput(true, 4, PlayerIndex.Player2, 4).ToString());
            //   手柄设置小程序要「至少 2 人」时会 SetPads(2)：只接一只 _pads 也是 2，必须仍走镜像（槽 1 没人）
            Row("导出 + 2 格 + 只有 1 只在线 → 镜像", "False", InputPump.UsePerPadInput(true, 2, PlayerIndex.Player2, 1).ToString());
            Row("导出 + 2 格 + 一只都没接 → 镜像", "False", InputPump.UsePerPadInput(true, 2, PlayerIndex.Player2, 0).ToString());
            Row("导出 + 1 格 → 单手柄原路径", "False", InputPump.UsePerPadInput(true, 1, PlayerIndex.Player2, 1).ToString());
            // ② 没导出（iOS 壳 / 安卓 / 旧宿主）：不接管，第二格继续镜像第一格
            Row("没导出 + 2 格 → 镜像", "False", InputPump.UsePerPadInput(false, 2, PlayerIndex.Player2, 2).ToString());
            Row("没导出 + 4 格 → 镜像", "False", InputPump.UsePerPadInput(false, 4, PlayerIndex.Player2, 4).ToString());

            // ③ 4 格各读各的：玩家号依次往后，按键 / 摇杆都来自自己那一槽（不是第一格的副本）
            var states = new List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1 } };
            InputPump.FillPadStates(states, 4, PlayerIndex.Player2, &FakePadRead, 0);
            Row("4 格的条数", "4", states.Count.ToString());
            Row("4 格的玩家号", "Player1 Player2 Player3 Player4", string.Join(" ", states.ConvertAll(s => s.PlayerId.ToString())));
            Row("4 格的按键", "0 2 4 8", string.Join(" ", states.ConvertAll(s => ((uint)s.Buttons).ToString())));
            Row("4 格的左摇杆 X", "0 100 200 300", string.Join(" ", states.ConvertAll(s => s.LStick.Dx.ToString())));

            // ④ 自动玩家接管二号手柄时的「2:键」并进第 2 格（槽 1 = 玩家 2），不扩散到第 3 格
            states = new List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1 } };
            InputPump.FillPadStates(states, 3, PlayerIndex.Player2, &FakePadRead, 1u << 14);
            Row("自动玩家键只进第二格", "False True False",
                string.Join(" ", states.ConvertAll(s => ((s.Buttons & (ControllerKeys)(1u << 14)) != 0).ToString())));

            // ⑤ 玩家号越过 Player8 回绕到 Player1（与 SetPrimary 同一套）：槽 0 是玩家 1，实体从槽 1 起
            states = new List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1 } };
            InputPump.FillPadStates(states, 4, PlayerIndex.Player7, &FakePadRead, 0);
            Row("越过 Player8 回绕", "Player1 Player7 Player8 Player1",
                string.Join(" ", states.ConvertAll(s => s.PlayerId.ToString())));

            // ⑥ 单手柄：只留槽 0，不凭空多出第二格
            states = new List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1 }, new() { PlayerId = PlayerIndex.Player2 }, new() { PlayerId = PlayerIndex.Player3 } };
            InputPump.FillPadStates(states, 1, PlayerIndex.Player2, &FakePadRead, 0);
            Row("回到 1 格只剩槽 0", "1", states.Count.ToString());

            // ⑦ 稀疏玩家槽位图：P1 断开时 P2（槽 1）与 P8（槽 7）保持原位，只把在线槽位送进 Npads
            Row("位图上限裁剪（2 人上限）", "2", InputPump.ClampMask(0b1000_0010, 2).ToString());
            Row("位图最高槽位（P2 + P8）", "8", InputPump.HighestSlotCount(0b1000_0010).ToString());
            states = new List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1 } };
            InputPump.FillPadStates(states, 8, PlayerIndex.Player2, &FakePadRead, 0);
            var connected = new List<GamepadInput>(8);
            InputPump.FilterConnectedStates(states, connected, 0b1000_0010);
            Row("稀疏位图只保留 P2 与 P8", "Player2 Player8", string.Join(" ", connected.ConvertAll(s => s.PlayerId.ToString())));
            InputPump.FilterConnectedStates(states, connected, 0b1000_0011);
            Row("P1 重连后恢复 P1 + P2 + P8", "Player1 Player2 Player8", string.Join(" ", connected.ConvertAll(s => s.PlayerId.ToString())));

            // ⑧ 只断开「本局占过、现在空了」的槽（期望手写）：小程序要 2 人 / 自动玩家开的二号格从没被实体手柄占过 → 照旧配上
            Row("只接一只、开到 2 格（小程序 / 自动玩家）：两格都配", "3", InputPump.ConfiguredMask(2, 0b01, 0b01).ToString());
            Row("两只都接过、P1 断开：只配 P2", "2", InputPump.ConfiguredMask(2, 0b10, 0b11).ToString());
            Row("两只都接过、P2 断开：只配 P1", "1", InputPump.ConfiguredMask(2, 0b01, 0b11).ToString());
            Row("三只接过、P2 断开：配 P1 + P3", "5", InputPump.ConfiguredMask(3, 0b101, 0b111).ToString());
            Row("P2 重连：三格都回来", "7", InputPump.ConfiguredMask(3, 0b111, 0b111).ToString());
            Row("宿主没导出位图：走原来的连续配法", "-1", InputPump.ConfiguredMask(2, -1, 0).ToString());

            Console.WriteLine($"{(bad == 0 ? "🟢" : "🔴")} 多手柄输入单测：24 项，不符 {bad}");
            return bad == 0 ? 0 : 1;
        }
    }
}
