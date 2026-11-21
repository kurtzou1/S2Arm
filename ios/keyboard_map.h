// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 外接键盘（妙控键盘等）→ 手柄状态 / HID 键盘区的纯决策（#1869）。行为照 Mac（macos/front_mac.m）一份不差：
//   键位用同一套 schema 1（Mac 键码），iOS 在边界把 HID usage（GCKeyCode）翻成 Mac 键码；按键 → 手柄位、摇杆换算、修饰键组合的认法、
//   原始键态进 HID 键盘区，都与 front_mac.m 的 sample_input / action / publish_keyboard 同规则。纯 C、无 UIKit / GameController 依赖，
//   单测 runtime/tests/t_keyboard_map.c 在 Mac 上跑（含与 front_mac.m 键码表逐项对照）。
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "s2a_input_config.h"

// Mac 键码（HIToolbox kVK_*）→ HID usage：除左 Option / 左 Control 两项外与 macos/front_mac.m 的 mac_key_hid 逐项相同（t_keyboard_map 读 front_mac.m 原文对照）。
//   那两项照 HIToolbox Events.h（kVK_Option = 0x3A、kVK_Control = 0x3B）与 Mac 输入单测的本意（ctrl 59→0xE0、option 58→0xE2）：
//   front_mac.m 写成了 0x3A→0xE0、0x3B→0xE2（左右对调）。iPad 反查键码要靠这张表，照抄会把 Control 认成 Option，所以这里用对的值。
//   0 = 不进键盘区。右修饰键（60 / 62 / 61）在 s2a_kbd_mac_code 里并成左键码，同 front_mac.m flagsChanged
static const uint8_t s2a_kbd_mac_hid[128] = {
    [0x00] = 0x04, [0x01] = 0x16, [0x02] = 0x07, [0x03] = 0x09,   // A S D F
    [0x04] = 0x0B, [0x05] = 0x0A, [0x06] = 0x1D, [0x07] = 0x1B,   // H G Z X
    [0x08] = 0x06, [0x09] = 0x19, [0x0B] = 0x05, [0x0C] = 0x14,   // C V B Q
    [0x0D] = 0x1A, [0x0E] = 0x08, [0x0F] = 0x15, [0x10] = 0x1C,   // W E R Y
    [0x11] = 0x17, [0x12] = 0x1E, [0x13] = 0x1F, [0x14] = 0x20,   // T 1 2 3
    [0x15] = 0x21, [0x16] = 0x23, [0x17] = 0x22, [0x18] = 0x2E,   // 4 6 5 =
    [0x19] = 0x26, [0x1A] = 0x24, [0x1B] = 0x2D, [0x1C] = 0x25,   // 9 7 - 8
    [0x1D] = 0x27, [0x1E] = 0x30, [0x1F] = 0x12, [0x20] = 0x18,   // 0 ] O U
    [0x21] = 0x2F, [0x22] = 0x0C, [0x23] = 0x13, [0x24] = 0x28,   // [ I P Return
    [0x25] = 0x0F, [0x26] = 0x0D, [0x27] = 0x34, [0x28] = 0x0E,   // L J ' K
    [0x29] = 0x33, [0x2A] = 0x31, [0x2B] = 0x36, [0x2C] = 0x38,   // ; \ , /
    [0x2D] = 0x11, [0x2E] = 0x10, [0x2F] = 0x37, [0x30] = 0x2B,   // N M . Tab
    [0x31] = 0x2C, [0x32] = 0x35, [0x33] = 0x2A, [0x35] = 0x29,   // Space ` 退格 Esc
    [0x36] = 0xE7, [0x37] = 0xE3, [0x38] = 0xE1, [0x3A] = 0xE2,   // 右⌘ 左⌘（组合键 keyDown: 已交系统，备用）⇧ ⌥
    [0x3B] = 0xE0, [0x3C] = 0xE5, [0x3D] = 0xE6, [0x3E] = 0xE4,   // ⌃ 右⇧ 右⌥ 右⌃
    [0x40] = 0x6C, [0x41] = 0x63, [0x43] = 0x55, [0x45] = 0x57,   // F17 小键盘. 小键盘* 小键盘+
    [0x47] = 0x53, [0x4B] = 0x54, [0x4C] = 0x58, [0x4E] = 0x56,   // 小键盘Clear 小键盘/ 小键盘Enter 小键盘-
    [0x4F] = 0x6D, [0x50] = 0x6E, [0x51] = 0x67, [0x52] = 0x62,   // F18 F19 小键盘= 小键盘0
    [0x53] = 0x59, [0x54] = 0x5A, [0x55] = 0x5B, [0x56] = 0x5C,   // 小键盘1 2 3 4
    [0x57] = 0x5D, [0x58] = 0x5E, [0x59] = 0x5F, [0x5A] = 0x6F,   // 小键盘5 6 7 F20
    [0x5B] = 0x60, [0x5C] = 0x61, [0x5D] = 0x89, [0x5F] = 0x85,   // 小键盘8 9 JIS円 JIS小键盘,
    [0x60] = 0x3E, [0x61] = 0x3F, [0x62] = 0x40, [0x63] = 0x3C,   // F5 F6 F7 F3
    [0x64] = 0x41, [0x65] = 0x42, [0x67] = 0x44, [0x69] = 0x68,   // F8 F9 F11 F13
    [0x6A] = 0x6B, [0x6B] = 0x69, [0x6D] = 0x43, [0x6F] = 0x45,   // F16 F14 F10 F12
    [0x71] = 0x6A, [0x72] = 0x49, [0x73] = 0x4A, [0x74] = 0x4B,   // F15 Help(=Insert) Home PageUp
    [0x75] = 0x4C, [0x76] = 0x3D, [0x77] = 0x4D, [0x78] = 0x3B,   // ForwardDelete F4 End F2
    [0x79] = 0x4E, [0x7A] = 0x3A, [0x7B] = 0x50, [0x7C] = 0x4F,   // PageDown F1 ← →
    [0x7D] = 0x51, [0x7E] = 0x52,                                  // ↓ ↑
};

// 右修饰键并成左键码（60→56、62→59、61→58，同 front_mac.m flagsChanged 与 Mac 键位编辑器的约定）
static inline int s2a_kbd_canonical(int code) { return code == 60 ? 56 : code == 62 ? 59 : code == 61 ? 58 : code; }
enum { S2A_KBD_ESC = 53, S2A_KBD_SHIFT = 56, S2A_KBD_OPTION = 58, S2A_KBD_CONTROL = 59, S2A_KBD_COMMAND = 55, S2A_KBD_COMMAND_RIGHT = 54 };
// 修饰键位：Shift 1、Control 2、Option 4（同 front_mac.m 的 modifiers 与 schema 1 的 modifiers 字段）
static inline unsigned s2a_kbd_mod_bit(int code) { return code == S2A_KBD_SHIFT ? 1u : code == S2A_KBD_CONTROL ? 2u : code == S2A_KBD_OPTION ? 4u : 0u; }

// 按着的键（Mac 键码 0–127 一位一键；修饰键按并过的左键码记）
typedef struct { uint64_t bits[2]; } s2a_kbd_keys;
static inline int s2a_kbd_held(const s2a_kbd_keys *k, int code) { return code >= 0 && code < 128 && (k->bits[code >> 6] >> (code & 63) & 1); }
static inline void s2a_kbd_set(s2a_kbd_keys *k, int code, int down) {
    if (code < 0 || code >= 128) return;
    if (down) k->bits[code >> 6] |= 1ULL << (code & 63); else k->bits[code >> 6] &= ~(1ULL << (code & 63));
}
static inline unsigned s2a_kbd_mods(const s2a_kbd_keys *k) {
    return (s2a_kbd_held(k, S2A_KBD_SHIFT) ? 1u : 0u) | (s2a_kbd_held(k, S2A_KBD_CONTROL) ? 2u : 0u) | (s2a_kbd_held(k, S2A_KBD_OPTION) ? 4u : 0u);
}

// iPad 键盘缺省键位 = 共用缺省 s2a_input_config_default，再加维护方在 #1869 定的三项（只对 iPad 键盘生效，不改 Mac）：
//   Y = F、ZL = Z、右摇杆 = I / J / K / L。理由：iPad 只接键盘时没有鼠标接管这三项（Mac 交给鼠标），不绑就用不了
static inline void s2a_kbd_default(s2a_input_config *c) {
    s2a_input_config_default(c);
    c->keyboard[3].code = 3;     // Y  = F
    c->keyboard[8].code = 6;     // ZL = Z
    c->keyboard[20].code = 38;   // RS_LEFT  = J
    c->keyboard[21].code = 34;   // RS_UP    = I
    c->keyboard[22].code = 37;   // RS_RIGHT = L
    c->keyboard[23].code = 40;   // RS_DOWN  = K
}

// 一个目标生效（front_mac.m action）：0–15 = Switch 按键位 A B X Y LS RS L R ZL ZR + - ← ↑ → ↓；
//   16–23 = 摇杆方向 LS_LEFT LS_UP LS_RIGHT LS_DOWN RS_LEFT RS_UP RS_RIGHT RS_DOWN，每个方向给满量 ±32767、相反方向抵消（不归一到圆内）
static inline void s2a_kbd_action(int target, uint32_t *buttons, int32_t sticks[4]) {
    if (target < 16) { *buttons |= 1u << target; return; }
    int i = target - 16, axis = (i < 4 ? 0 : 2) + (i % 2);
    sticks[axis] += (i % 4 == 0 || i % 4 == 3) ? -32767 : 32767;
}
// 按着的键 → 手柄按键位 + 摇杆（front_mac.m sample_input 的键盘段）：先认带修饰键的组合（修饰键要全按着），
//   用掉的修饰键不再单独算（Shift+E 绑 A 时，同时按着的 Shift 不再触发「Shift 绑 B」）；再认不带修饰键的
static inline void s2a_kbd_map(const s2a_input_config *c, const s2a_kbd_keys *k, uint32_t *buttons, int32_t sticks[4]) {
    *buttons = 0; memset(sticks, 0, 4 * sizeof *sticks);
    unsigned mods = s2a_kbd_mods(k), consumed = 0;
    for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++) {
        const s2a_input_key *b = &c->keyboard[t];
        if (b->code >= 0 && b->modifiers && (mods & b->modifiers) == b->modifiers && s2a_kbd_held(k, b->code)) {
            s2a_kbd_action(t, buttons, sticks); consumed |= b->modifiers;
        }
    }
    for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++) {
        const s2a_input_key *b = &c->keyboard[t];
        if (b->code < 0 || b->modifiers) continue;
        if (!(consumed & s2a_kbd_mod_bit(b->code)) && s2a_kbd_held(k, b->code)) s2a_kbd_action(t, buttons, sticks);
    }
}
// 并进实体手柄（front_mac.m pad_event_fast：槽 0 = 第一只手柄 + 键盘）：按键或起来、摇杆相加后夹到 ±32767
static inline void s2a_kbd_merge(uint32_t *buttons, int32_t sticks[4], uint32_t kb_buttons, const int32_t kb_sticks[4]) {
    *buttons |= kb_buttons;
    for (int i = 0; i < 4; i++) {
        int64_t v = (int64_t)sticks[i] + kb_sticks[i];
        sticks[i] = (int32_t)(v > 32767 ? 32767 : v < -32767 ? -32767 : v);
    }
}
// HID 键盘区（front_mac.m publish_keyboard，R5）：按着的键按 usage 置位（修饰键也进位图 0xE0–0xE2）；
//   modifiers 字段 Control=1、Shift=2、LeftAlt=4、CapsLock=0x100（同服务层 KeyboardModifier）。CapsLock 锁定时位图 0x39 与字段 bit8 都置
static inline void s2a_kbd_hid(const s2a_kbd_keys *k, int caps_locked, uint64_t bits[4], uint32_t *mods) {
    memset(bits, 0, 4 * sizeof *bits); *mods = 0;
    for (int code = 0; code < 128; code++) {
        unsigned usage = s2a_kbd_held(k, code) ? s2a_kbd_mac_hid[code] : 0;
        if (usage) bits[usage >> 6] |= 1ULL << (usage & 63);
    }
    if (caps_locked) { bits[0x39 >> 6] |= 1ULL << (0x39 & 63); *mods |= 1u << 8; }
    unsigned m = s2a_kbd_mods(k);
    if (m & 1) *mods |= 1u << 1;   // Shift → KeyboardModifier.Shift
    if (m & 2) *mods |= 1u << 0;   // Control
    if (m & 4) *mods |= 1u << 2;   // Option → LeftAlt
}

// 键位写成 schema 1 JSON（s2a_input_config_parse 读得回同一份；iPad 改键页按款存的就是它，与 Mac 启动器 input.json 同格式）。
//   返回写入字节数（不含结尾 0），放不下返回 -1
static inline int s2a_kbd_config_json(const s2a_input_config *c, char *out, size_t n) {
    static const char *const pads[] = {"east", "south", "north", "west", "leftStick", "rightStick", "leftShoulder", "rightShoulder",
                                       "leftTrigger", "rightTrigger", "menu", "options", "dpadLeft", "dpadUp", "dpadRight", "dpadDown"};
    static const char *const axes_src[] = {"leftX", "leftY", "rightX", "rightY"}, *const axes_dst[] = {"LX", "LY", "RX", "RY"};
    size_t at = 0; int w;
#define S2A_KBD_PUT(...) do { w = snprintf(out + at, at < n ? n - at : 0, __VA_ARGS__); if (w < 0 || (at += (size_t)w) >= n) return -1; } while (0)
    S2A_KBD_PUT("{\"schema\":1,\"keyboard\":{");
    for (int t = 0, first = 1; t < S2A_INPUT_TARGET_COUNT; t++) if (c->keyboard[t].code >= 0) {
        S2A_KBD_PUT("%s\"%s\":{\"code\":%d,\"modifiers\":%u}", first ? "" : ",", s2a_input_target_name(t), c->keyboard[t].code, c->keyboard[t].modifiers); first = 0;
    }
    S2A_KBD_PUT("},\"mouse\":{");
    for (int t = 0, first = 1; t < S2A_INPUT_TARGET_COUNT; t++) if (c->mouse[t] >= 0) {
        S2A_KBD_PUT("%s\"%s\":%d", first ? "" : ",", s2a_input_target_name(t), c->mouse[t]); first = 0;
    }
    S2A_KBD_PUT("},\"gamepad\":{");
    for (int t = 0, first = 1; t < S2A_INPUT_TARGET_COUNT; t++) if (c->gamepad[t] >= 0 && c->gamepad[t] < 16) {
        S2A_KBD_PUT("%s\"%s\":\"%s\"", first ? "" : ",", s2a_input_target_name(t), pads[c->gamepad[t]]); first = 0;
    }
    S2A_KBD_PUT("},\"axes\":{");
    for (int a = 0, first = 1; a < S2A_INPUT_AXIS_COUNT; a++) if (c->axes[a].source >= 0 && c->axes[a].source < 4) {
        S2A_KBD_PUT("%s\"%s\":{\"source\":\"%s\",\"invert\":%s}", first ? "" : ",", axes_dst[a], axes_src[c->axes[a].source], c->axes[a].invert ? "true" : "false"); first = 0;
    }
    S2A_KBD_PUT("}");
    if (c->back_buttons[0] >= 0 || c->back_buttons[1] >= 0) {
        S2A_KBD_PUT(",\"backButtons\":{");
        if (c->back_buttons[0] >= 0 && c->back_buttons[0] < 16) S2A_KBD_PUT("\"GL\":\"%s\"", pads[c->back_buttons[0]]);
        if (c->back_buttons[1] >= 0 && c->back_buttons[1] < 16) S2A_KBD_PUT("%s\"GR\":\"%s\"", c->back_buttons[0] >= 0 ? "," : "", pads[c->back_buttons[1]]);
        S2A_KBD_PUT("}");
    }
    S2A_KBD_PUT(",\"deadzone\":%.17g,\"mouseOptions\":{\"mode\":\"%s\",\"sensitivityX\":%.17g,\"sensitivityY\":%.17g,\"invertX\":%s,\"invertY\":%s,\"recenter\":%s}}",
                c->deadzone, c->mouse_camera ? "camera" : "off", c->sensitivity_x, c->sensitivity_y,
                c->invert_x ? "true" : "false", c->invert_y ? "true" : "false", c->recenter ? "true" : "false");
#undef S2A_KBD_PUT
    return (int)at;
}
