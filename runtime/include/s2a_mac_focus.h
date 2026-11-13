// Mac 游戏窗口「对游戏算不算在前台」（#279，Mac 宿主 macos/front_mac.m 用）：
//   游戏要玩家输入文字时，我们在游戏窗口上挂一个系统输入框 sheet（macos/textinput_mac.m）。sheet 一出来就抢走 key window，
//   原先游戏窗口在 windowDidResignKey 里无条件报失焦，游戏随即收到内联键盘 Disappear（Calc 0x80），把这次输入当取消，名字丢了。
//   真机上系统键盘就是游戏自己叫出来的，游戏在这期间并没有失焦，所以：App 仍 active、当前 key window 是我们登记中的输入框、
//   且它挂在游戏窗口上时，照旧算前台。切到别的 App、点到本 App 别的窗口（键位窗口等）、不是挂在游戏窗口上的弹框，照旧算失焦。
//   这里只管报给游戏的生命周期焦点；本机键鼠 / 手柄在输入框打开期间照旧停喂、复位（字是打进输入框的）。
//   纯逻辑、不碰 AppKit：放在头里是为了能在宿主上直接单测（runtime/tests/t_mac_focus.c）。
#ifndef S2A_MAC_FOCUS_H
#define S2A_MAC_FOCUS_H
#include <stdbool.h>

// app_active   = NSApp.isActive
// game_is_key  = 游戏窗口就是 key window
// key_is_input = 当前 key window 是 textinput_mac.m 登记中、还没答复的系统输入框
// key_on_game  = 当前 key window 的 sheetParent 就是游戏窗口
static inline bool s2a_mac_game_focused(bool app_active, bool game_is_key, bool key_is_input, bool key_on_game) {
    if (!app_active) return false;
    return game_is_key || (key_is_input && key_on_game);
}

#endif
