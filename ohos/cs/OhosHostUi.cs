// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Applets;
using S2A.Services;
using System;

namespace S2A.Android.Aot
{
    // 鸿蒙宿主界面直接登记共用 HostUi（services/S2A.Services/Host.cs），与安卓 / iOS 同一套策略：
    // 错误提示 / 选用户 / 手柄设置 / 软键盘零配置自动应答，其余未接界面报红一次后按契约回包、不停局。
    // 平台只注册前台软键盘：经鸿蒙私有、带类型的 broker 弹真实输入框；取消 / 失败回 null = 不确认。
    internal static class OhosHostUi
    {
        internal static HostUi Create(OhosKeyboard keyboard = null)
        {
            keyboard ??= new OhosKeyboard();
            return new HostUi { SoftwareKeyboard = args => Keyboard(keyboard, args) };
        }

        private static string Keyboard(OhosKeyboard keyboard, SoftwareKeyboardUIArgs args)
        {
            try
            {
                return keyboard.Display(args, out string text) ? text : null;
            }
            catch (Exception error)
            {
                Red.Report("鸿蒙软键盘应答失败", error.Message);
                return null;
            }
        }
    }
}
