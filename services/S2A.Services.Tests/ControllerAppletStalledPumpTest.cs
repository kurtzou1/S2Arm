using System.Threading;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // 手柄设置小程序回 true 时，共享内存里已是新样式——不靠采样泵按时跑（11-22 根修：原先等泵最多 200 ms，
        //   本机负载 7 倍核数时泵线程没被调度，「只收单只 Joy-Con」读到 0，单测随负载时红时绿；游戏的重验读的是同一块共享内存）。
        //   做法：把采样泵卡在 InputHook 里（确定性地复现「泵没轮上」），再调小程序、读共享内存。
        //   期望 true 16（JoyRight）；反证：回到「等泵 200 ms」的旧写法，这一项稳定读到 true 0
        private static readonly ManualResetEventSlim s_pumpEntered = new(false), s_pumpRelease = new(false);

        private static void StallPumpHook(ref GamepadInput input)
        {
            s_pumpEntered.Set();
            s_pumpRelease.Wait(5000);   // 上限 5 秒：单测出错也不让泵永远卡住
        }

        private static void ControllerAppletStalledPumpTest()
        {
            var ui = Host.Device.UIHandler;
            var P = new[] { PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3, PlayerIndex.Player4 };
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 泵没起就起（SetPrimary 懒启动）
            var prev = InputPump.InputHook;
            s_pumpEntered.Reset(); s_pumpRelease.Reset();
            InputPump.InputHook = &StallPumpHook;
            bool stalled = s_pumpEntered.Wait(5000);   // 泵进了钩子 = 从现在起不再 Update，直到放开
            bool ok = ui.DisplayMessageDialog(new Ryujinx.HLE.HOS.Applets.ControllerAppletUIArgs { PlayerCountMin = 1, PlayerCountMax = 4, SupportedPlayers = P, IsDocked = false,
                SupportedStyles = ControllerType.JoyconLeft | ControllerType.JoyconRight });
            string style = ((uint)Host.Device.Hid.SharedMemory.Npads[0].InternalState.StyleSet).ToString();
            InputPump.InputHook = prev;
            s_pumpRelease.Set();
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 还原，不影响后面的用例
            Check("手柄设置小程序：采样泵卡住时回 true 也已写进共享内存（只收单只 Joy-Con → JoyRight=16）", "泵卡住 True / true 16",
                $"泵卡住 {stalled} / {ok.ToString().ToLower()} {style}");
        }
    }
}
