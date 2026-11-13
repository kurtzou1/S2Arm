using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Hid;
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // R5：键盘区共享内存。改前全库没有真实写入方（IHidServer.ActivateKeyboard 只写一条空状态、上游残留的
        //   Ryujinx.Input 键盘路径不被驱动），读键盘区的游戏（快捷键类）按什么都没反应；现在 InputPump 每次
        //   HID 提交把宿主原始键态写进 KeyboardDevice。位图位序 = HID usage 码（W=0x1A；修饰键 LeftShift=0xE1
        //   落在 RawData[3] bit 33），修饰键字段 = KeyboardModifier。软键盘开着（TextInput.Open）给全零，同手柄清零的口径。
        //   单测不链原生库：宿主导出 s2a_kb_read 用替身注入（InputPump._kbRead），native 侧位图推导由 Mac 输入单测对拍
        //   （launchers/macos/Tests/input_test.m 的 test_keyboard_hid）
        [SoloTest("--keyboard-hid", Booted = true)]
        private static void KeyboardHidTest()
        {
            var device = Host.Device;
            InputPump.Stop();
            InputPump._kbRead = null;
            InputPump.SetPrimary(device, PlayerIndex.Player1, ControllerType.ProController);
            device.Hid.Keyboard.Active = true;   // 游戏调 ActivateKeyboard 之后才写键盘区（KeyboardDevice 的 Active 门）
            try
            {
                SettleKeyboard("0 0 0 0 mods None");
                Check("R5：宿主没喂键态时键盘区保持空（同改前，Activate 只见空状态）",
                    "0 0 0 0 mods None", KeyboardBits(device));

                InputPump.Stop();
                InputPump._kbRead = &FakeKbRead;
                InputPump.SetPrimary(device, PlayerIndex.Player1, ControllerType.ProController);
                SettleKeyboard("4000000 0 0 200000000 mods Shift");
                Check("R5：宿主键态写进键盘区（位图 = HID usage 码、修饰键字段 = KeyboardModifier）",
                    "4000000 0 0 200000000 mods Shift", KeyboardBits(device));

                TextInput.BeginHook = (_, _) => 1;   // 平台输入框替身：rc==1 = 挂起即开框（同 SwkbdHostInputTest）
                TextInput.CancelHook = _ => { };    // 单测进程没有原生库：关框也走替身
                IDisposable box = TextInput.Begin(new SoftwareKeyboardUIArgs(), (ok, text) => { });
                SettleKeyboard("0 0 0 0 mods None");
                Check("R5：软键盘开着给全零（同手柄清零的口径：玩家在打字，按键不进游戏）",
                    "0 0 0 0 mods None", KeyboardBits(device));
                box.Dispose();
                TextInput.BeginHook = null; TextInput.CancelHook = null;
                SettleKeyboard("4000000 0 0 200000000 mods Shift");
                Check("R5：收框后键态恢复", "4000000 0 0 200000000 mods Shift", KeyboardBits(device));
            }
            finally
            {
                TextInput.BeginHook = null; TextInput.CancelHook = null;
                InputPump.Stop();
                InputPump._kbRead = null;
            }
        }

        private static string KeyboardBits(Ryujinx.HLE.Switch device)
        {
            ref var entry = ref device.Hid.SharedMemory.Keyboard.GetCurrentEntryRef();
            return $"{entry.Keys.RawData[0]:x} {entry.Keys.RawData[1]:x} {entry.Keys.RawData[2]:x} {entry.Keys.RawData[3]:x} mods {entry.Modifiers}";
        }

        private static void SettleKeyboard(string target)
        {
            for (int k = 0; k < 300 && KeyboardBits(Host.Device) != target; k++) Thread.Sleep(10);   // 泵按 16 ms 一拍，3 秒足够
        }

        [UnmanagedCallersOnly]
        private static void FakeKbRead(ulong* keys, uint* modifiers)
        {
            keys[0] = 1UL << 0x1A;   // W（HID usage 0x1A）
            keys[3] = 1UL << 33;    // 修饰键 LeftShift（usage 0xE1 → 第 4 个 64 位段 bit 33）
            *modifiers = 2;         // KeyboardModifier.Shift
        }
    }
}
