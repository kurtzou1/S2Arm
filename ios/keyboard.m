// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 外接键盘（妙控键盘等，#1869）：GCKeyboard 采键 → ios/keyboard_map.h（规则同 Mac macos/front_mac.m）→ ios/controller.m 照 Mac 选源发布；
//   原始键态同时喂 HID 键盘区（s2a_kb_update，同 Mac R5）。鼠标键（ios/mouse.m）并进同一份（s2a_mouse_map，同 Mac sample_input）。
//   每次按键事件都把键码表里的键全部重查一遍（buttonForKeyCode:），不自己记增减：切后台、⌘ 组合吞掉抬起事件时，下一次事件就对齐。
//   ⌘ 按着时新按下的键交给系统、不进游戏，松开前一直不算（同 Mac：⌘ 组合的 keyDown 交系统）。CapsLock 只记锁定状态，不进按键（同 Mac）。
//   键位：起局点名的 S2A_INPUT_CONFIG（开发 / 自动化）> 这款在改键页存的 > iPad 缺省（s2a_kbd_default）。
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include "keyboard.h"
#include "keyboard_map.h"
#include "mouse_map.h"
#include "input_config.h"
#include "settings.h"
#include "native.h"
#include "s2a_pad.h"
#include <stdatomic.h>
#include <stdlib.h>

static dispatch_queue_t g_queue;               // = controller.m 的输入队列；下面这些只在它上面动
static s2a_kbd_keys g_held;                     // 按着、算数的键（Mac 键码，修饰键已并成左键码）
static s2a_kbd_keys g_swallowed;                // ⌘ 按着时按下的键：交给系统，松开前不算
static int g_caps, g_caps_down, g_muted;        // CapsLock 锁定 / CapsLock 正按着（只认按下沿翻转）/ 改键页开着
static s2a_input_config g_map;
static int g_map_loaded;
static void (^g_record)(int code, unsigned modifiers);   // 改键页在录键：下一次按下的键交给它
static _Atomic int g_connected;

static void load_map(void) {
    const char *env = getenv("S2A_INPUT_CONFIG");
    const s2a_input_config *named = s2a_ios_input_config_current();
    if (env && *env && named) { g_map = *named; g_map_loaded = 1; return; }   // 起局点名的键位优先（开发 / 自动化，同 Mac 起局）
    NSString *json = [s2a_ios_settings_defaults() stringForKey:S2AKeyboardMapKey];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || s2a_input_config_parse(data.bytes, data.length, &g_map) != S2A_INPUT_CONFIG_OK) {
        if (data.length) LOG("【黄】外接键盘：这款存的键位读不懂，先用缺省键位");
        s2a_kbd_default(&g_map);
    }
    g_map_loaded = 1;
    // 鼠标那几项（模式 / 灵敏度 / 左键绑没绑 / 鼠标用法是不是缺省）和「使用鼠标 / 触控板」开关（#2072，分层读取：本款没设过看所有游戏的默认）同步给 mouse.m
    s2a_ios_mouse_config(&g_map, s2a_mouse_use_default(&g_map), [s2a_ios_settings_defaults() boolForKey:S2AMouseOffKey]);
}
// 这一款的键位（含手柄 gamepad / axes 段）：实体系统手柄改键也用这一份（controller.m sample_extended，#1606 ④）。只在输入队列上调（同 g_map 的其余读写）
const s2a_input_config *s2a_ios_pad_map_config(void) {
    if (!g_map_loaded) load_map();
    return &g_map;
}
// 现在按着的键：照键码表逐个问系统（⌘ 不进按键，同 Mac）
static void poll_keys(GCKeyboardInput *input, s2a_kbd_keys *now) {
    memset(now, 0, sizeof *now);
    for (int k = 0; k < 128; k++) {
        unsigned usage = s2a_kbd_mac_hid[k];
        if (!usage || k == S2A_KBD_COMMAND || k == S2A_KBD_COMMAND_RIGHT) continue;
        if ([input buttonForKeyCode:(GCKeyCode)usage].isPressed) s2a_kbd_set(now, s2a_kbd_canonical(k), 1);
    }
}
static int command_down(GCKeyboardInput *input) {
    return [input buttonForKeyCode:(GCKeyCode)0xE3].isPressed || [input buttonForKeyCode:(GCKeyCode)0xE7].isPressed;
}
// 算一份交出去：HID 键盘区先落键态，再交 controller.m 发布（唤醒泵，同 s2a_pad.h 约定）。改键页开着时发全零（同 Mac 失焦口径）
static void publish(int pressed) {
    uint32_t buttons = 0; int32_t sticks[4] = {0}; uint64_t bits[4] = {0}; uint32_t mods = 0;
    if (!g_muted) {
        if (!g_map_loaded) load_map();
        s2a_kbd_map(&g_map, &g_held, &buttons, sticks);
        s2a_mouse_map(&g_map, s2a_ios_mouse_buttons(), &buttons, sticks);   // 鼠标键与键盘一起算（同 Mac sample_input）
        s2a_kbd_hid(&g_held, g_caps, bits, &mods);
    }
    s2a_kb_update(bits, mods);
    s2a_ios_keyboard_publish(buttons, sticks, pressed && !g_muted);
}
static void key_changed(GCKeyboardInput *input, GCKeyCode code) {
    if ((unsigned)code == 0x39) {   // CapsLock：按下沿翻转锁定状态
        BOOL down = [input buttonForKeyCode:(GCKeyCode)0x39].isPressed;
        if (down && !g_caps_down) g_caps = !g_caps;
        g_caps_down = down;
    }
    s2a_kbd_keys now, fresh;
    poll_keys(input, &now);
    for (int i = 0; i < 2; i++) {
        g_swallowed.bits[i] &= now.bits[i];   // 松开了就不再吞
        fresh.bits[i] = now.bits[i] & ~g_held.bits[i] & ~g_swallowed.bits[i];
    }
    if (s2a_kbd_held(&fresh, S2A_KBD_ESC) && s2a_ios_mouse_escape()) {   // 鼠标锁着时 Esc 只释放，这一下不进游戏（同 Mac），松开前不算
        s2a_kbd_set(&g_swallowed, S2A_KBD_ESC, 1); s2a_kbd_set(&fresh, S2A_KBD_ESC, 0);
    }
    if (command_down(input)) {   // ⌘ 组合：新按下的键交系统
        for (int i = 0; i < 2; i++) { g_swallowed.bits[i] |= fresh.bits[i]; fresh.bits[i] = 0; }
    }
    for (int i = 0; i < 2; i++) g_held.bits[i] = now.bits[i] & ~g_swallowed.bits[i];
    int pressed = (fresh.bits[0] | fresh.bits[1]) != 0;
    if (g_record && pressed) {   // 改键页录键（同 Mac 启动器 InputKeyRecorder）：Esc 取消；单按修饰键录成那个键；别的键带上按着的修饰键
        int key = -1;
        for (int k = 0; k < 128 && key < 0; k++) if (s2a_kbd_held(&fresh, k)) key = k;
        unsigned mods = s2a_kbd_mod_bit(key) ? 0 : s2a_kbd_mods(&now);
        if (key == S2A_KBD_ESC) { key = -1; mods = 0; }
        void (^done)(int, unsigned) = g_record; g_record = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(key, mods); });
    }
    publish(pressed);
}
static void attach_keyboard(GCKeyboard *keyboard) {
    if (!keyboard || !g_queue) return;
    keyboard.handlerQueue = g_queue;
    keyboard.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
        (void)key; (void)pressed;
        key_changed(input, code);
    };
    atomic_store(&g_connected, 1);
    LOG("外接键盘：已连接（%s）", keyboard.vendorName.UTF8String ?: "GCKeyboard");
}
// 放开全部按键（输入队列）；接管保留
static void release_keys(void) {
    memset(&g_held, 0, sizeof g_held); memset(&g_swallowed, 0, sizeof g_swallowed); g_caps_down = 0;
    publish(0);
}
// 放开全部按键、结束接管（输入队列）：键盘没了
static void release_all(void) {
    release_keys();
    s2a_ios_keyboard_end();
}
void s2a_ios_keyboard_attach(void) {
    if (g_queue) return;
    g_queue = s2a_ios_input_queue();
    if (!g_queue) return;
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        attach_keyboard([n.object isKindOfClass:GCKeyboard.class] ? n.object : GCKeyboard.coalescedKeyboard);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n;
        if (GCKeyboard.coalescedKeyboard) return;   // 还接着别的键盘
        atomic_store(&g_connected, 0);
        LOG("外接键盘：已断开");
        dispatch_async(g_queue, ^{ g_caps = 0; release_all(); });
    }];
    attach_keyboard(GCKeyboard.coalescedKeyboard);   // 起局前就接着的
}
// 切后台：按着的键收不到抬起，先放开；接管保留（同系统手柄回前台自动接回，虚拟按键不跳出来）
void s2a_ios_keyboard_background(void) {
    dispatch_queue_t queue = g_queue;
    if (queue) dispatch_async(queue, ^{ release_keys(); });
}
// 回前台（主线程）：后台期间键盘拔了、断开通知又没到时，在这里结束接管
void s2a_ios_keyboard_foreground(void) {
    dispatch_queue_t queue = g_queue;
    if (!queue || GCKeyboard.coalescedKeyboard || !atomic_load(&g_connected)) return;
    atomic_store(&g_connected, 0);
    LOG("外接键盘：回前台时已不在");
    dispatch_async(queue, ^{ g_caps = 0; release_all(); });
}
int s2a_ios_keyboard_connected(void) { return atomic_load(&g_connected); }
void s2a_ios_keyboard_reload(void) {
    dispatch_queue_t queue = g_queue;
    if (queue) dispatch_async(queue, ^{ load_map(); publish(0); });
}
void s2a_ios_keyboard_set_muted(int muted) {
    if (muted) s2a_ios_mouse_background();   // 改键页开着：鼠标也释放、放开
    dispatch_queue_t queue = g_queue;
    if (queue) dispatch_async(queue, ^{ g_muted = muted != 0; if (!g_muted) g_record = nil; publish(0); });
}
void s2a_ios_keyboard_mouse_changed(int pressed) { publish(pressed); }
void s2a_ios_keyboard_record(void (^done)(int code, unsigned modifiers)) {
    dispatch_queue_t queue = g_queue;
    void (^copy)(int, unsigned) = [done copy];
    if (queue) dispatch_async(queue, ^{ g_record = copy; });
}
