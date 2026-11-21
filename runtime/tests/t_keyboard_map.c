// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 外接键盘（#1869）：ios/keyboard_map.h 的纯决策与 Mac（macos/front_mac.m）同规则。
//   期望值全部手写（键码表 / 位序 / 摇杆满量照 front_mac.m 的规则手算），不拿被测函数的输出当期望；
//   键码表另读 front_mac.m 原文逐项对照（两端各写一份，改了一边另一边就红）；
//   接线断言读 ios/controller.m、ios/keyboard.m 原文（GameController / UIKit 在 Mac 宿主上编不了，接线靠文本钉住）。
#include "../../ios/keyboard_map.h"
#include <stdlib.h>

static int failures, checks;
static void check(int ok, const char *what) {
    checks++;
    if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); }
}
static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *s = malloc((size_t)n + 1); if (!s) { fclose(f); return NULL; }
    size_t got = fread(s, 1, (size_t)n, f); fclose(f); s[got] = 0; return s;
}
static int count_in(const char *text, const char *needle) {
    int n = 0; size_t len = strlen(needle);
    for (const char *p = text; (p = strstr(p, needle)) != NULL; p += len) n++;
    return n;
}
// 取函数体：从签名到下一个行首的「}」（找不到返回空串，调用方照常断言即红）
static char *body_of(const char *text, const char *signature) {
    const char *p = strstr(text, signature), *e = p ? strstr(p, "\n}") : NULL;
    size_t n = e ? (size_t)(e - p) : 0;
    char *s = malloc(n + 1); if (!s) return NULL;
    if (n) memcpy(s, p, n);
    s[n] = 0; return s;
}
// 按着这些 Mac 键码（-1 结尾）→ 用 cfg 映射
static void press(const s2a_input_config *cfg, const int *codes, uint32_t *b, int32_t s[4]) {
    s2a_kbd_keys k = {{0, 0}};
    for (; *codes >= 0; codes++) s2a_kbd_set(&k, *codes, 1);
    s2a_kbd_map(cfg, &k, b, s);
}
// HID usage → Mac 键码（测试里反查键码表：iPad 照表逐个问系统，等价于这张反查）
static int mac_code(unsigned usage) {
    if (!usage || usage > 0xFF) return -1;
    for (int k = 0; k < 128; k++) if (s2a_kbd_mac_hid[k] == usage) return s2a_kbd_canonical(k);
    return -1;
}
static int sticks_are(const int32_t s[4], int32_t a, int32_t b, int32_t c, int32_t d) { return s[0] == a && s[1] == b && s[2] == c && s[3] == d; }

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "用法：t_keyboard_map <front_mac.m> <controller.m> <keyboard.m>\n"); return 2; }

    // ① 键码表与 front_mac.m 的 mac_key_hid 逐项相同（读原文里的 [0xNN] = 0xMM）
    char *mac = slurp(argv[1]);
    check(mac != NULL, "读得到 front_mac.m");
    if (mac) {
        uint8_t want[128] = {0}; int pairs = 0;
        const char *p = strstr(mac, "mac_key_hid[128] = {"), *end = p ? strstr(p, "};") : NULL;
        check(p && end, "front_mac.m 里找得到 mac_key_hid 表");
        for (; p && p < end; p++) {
            unsigned a, b;
            if (*p == '[' && sscanf(p, "[0x%x] = 0x%x", &a, &b) == 2 && a < 128) { want[a] = (uint8_t)b; pairs++; }
        }
        check(pairs >= 100, "mac_key_hid 读出百余项");
        // 左 Option（kVK 0x3A）/ 左 Control（kVK 0x3B）不对照：front_mac.m 把这两项写反了（见 keyboard_map.h 表头），iPad 用 HIToolbox 的对的值，单独断言
        int same = 1; for (int i = 0; i < 128; i++) if (i != 0x3A && i != 0x3B && want[i] != s2a_kbd_mac_hid[i]) { same = 0; fprintf(stderr, "  键码 %d：front_mac.m 0x%02x，keyboard_map.h 0x%02x\n", i, want[i], s2a_kbd_mac_hid[i]); }
        check(same, "keyboard_map.h 的键码表与 front_mac.m mac_key_hid 逐项相同（左 Option / 左 Control 除外）");
        free(mac);
    }

    // ② HID usage → Mac 键码（手写：HID 0x04 = A、Mac kVK_ANSI_A = 0 …；右修饰键并成左键码）
    check(mac_code(0x04) == 0, "HID A(0x04) → Mac 0");
    check(mac_code(0x1A) == 13, "HID W(0x1A) → Mac 13");
    check(mac_code(0x09) == 3, "HID F(0x09) → Mac 3");
    check(mac_code(0x2B) == 48, "HID Tab(0x2B) → Mac 48");
    check(mac_code(0x29) == 53, "HID Esc(0x29) → Mac 53");
    check(mac_code(0x50) == 123 && mac_code(0x4F) == 124 && mac_code(0x51) == 125 && mac_code(0x52) == 126, "HID 方向键 → Mac 123–126");
    check(mac_code(0xE1) == 56 && mac_code(0xE5) == 56, "左右 Shift 都 → 56");
    check(s2a_kbd_mac_hid[0x3A] == 0xE2 && s2a_kbd_mac_hid[0x3B] == 0xE0, "Mac 58 = kVK_Option → LeftAlt 0xE2、59 = kVK_Control → LeftControl 0xE0（HIToolbox Events.h）");
    check(mac_code(0xE0) == 59 && mac_code(0xE4) == 59, "左右 Control 都 → 59");
    check(mac_code(0xE2) == 58 && mac_code(0xE6) == 58, "左右 Option 都 → 58");
    check(mac_code(0xE3) == 55 && mac_code(0xE7) == 54, "Command 认得出（由调用方挡掉，同 Mac 不收 ⌘ 组合）");
    check(mac_code(0x39) == -1, "CapsLock 不进按键（同 Mac 只走锁定状态）");
    check(mac_code(0) == -1 && mac_code(0x100) == -1, "0 与越界 → -1");

    // ③ iPad 缺省键位 = 共用缺省 + #1869 维护方定的 Y=F、ZL=Z、右摇杆 IJKL（手写整张表，目标顺序同 input_config.c）
    s2a_input_config def; s2a_kbd_default(&def);
    const int want_keys[24] = {14,56,49,3,59,8,12,5,6,15,48,46,123,126,124,125,0,13,2,1,38,34,37,40};
    int keys_ok = 1; for (int i = 0; i < 24; i++) if (def.keyboard[i].code != want_keys[i] || def.keyboard[i].modifiers) keys_ok = 0;
    check(keys_ok, "iPad 缺省键盘键位 = 共用缺省 + Y=F、ZL=Z、RS=J/I/L/K");
    int dup = 0; for (int i = 0; i < 24; i++) for (int j = i + 1; j < 24; j++) if (def.keyboard[i].code == def.keyboard[j].code) dup = 1;
    check(!dup, "iPad 缺省键位没有重复绑定");
    s2a_input_config shared; s2a_input_config_default(&shared);
    check(shared.keyboard[3].code == -1 && shared.keyboard[8].code == -1 && shared.keyboard[20].code == -1, "共用缺省（Mac）不变：Y / ZL / 右摇杆仍不绑键盘");
    const char *dirs[8] = {"LS_LEFT", "LS_UP", "LS_RIGHT", "LS_DOWN", "RS_LEFT", "RS_UP", "RS_RIGHT", "RS_DOWN"};
    int order_ok = 1; for (int i = 0; i < 8; i++) if (strcmp(s2a_input_target_name(16 + i), dirs[i])) order_ok = 0;
    check(order_ok, "目标 16–23 的顺序与 front_mac.m action 的方向表一致");

    // ④ 按键 → 手柄（位序 A=0 B=1 X=2 Y=3 LS=4 RS=5 L=6 R=7 ZL=8 ZR=9 +=10 -=11 ←=12 ↑=13 →=14 ↓=15，同 front_mac.m targets）
    uint32_t b; int32_t s[4];
    press(&def, (const int[]){14, -1}, &b, s);  check(b == 1u << 0 && sticks_are(s, 0, 0, 0, 0), "E → A");
    press(&def, (const int[]){56, -1}, &b, s);  check(b == 1u << 1, "左 Shift → B");
    press(&def, (const int[]){49, -1}, &b, s);  check(b == 1u << 2, "空格 → X");
    press(&def, (const int[]){3, -1}, &b, s);   check(b == 1u << 3, "F → Y（iPad 叠加项）");
    press(&def, (const int[]){6, -1}, &b, s);   check(b == 1u << 8, "Z → ZL（iPad 叠加项）");
    press(&def, (const int[]){48, -1}, &b, s);  check(b == 1u << 10, "Tab → +");
    press(&def, (const int[]){46, -1}, &b, s);  check(b == 1u << 11, "M → -");
    press(&def, (const int[]){123, 126, -1}, &b, s); check(b == ((1u << 12) | (1u << 13)), "← ↑ → 十字键左上");
    press(&def, (const int[]){13, -1}, &b, s);  check(b == 0 && sticks_are(s, 0, 32767, 0, 0), "W → 左摇杆上满量");
    press(&def, (const int[]){13, 2, -1}, &b, s); check(sticks_are(s, 32767, 32767, 0, 0), "W+D → (32767, 32767)，同 Mac 不归一");
    press(&def, (const int[]){0, 2, -1}, &b, s); check(sticks_are(s, 0, 0, 0, 0), "A+D 抵消为 0");
    press(&def, (const int[]){1, 0, -1}, &b, s); check(sticks_are(s, -32767, -32767, 0, 0), "S+A → (-32767, -32767)");
    press(&def, (const int[]){34, 38, -1}, &b, s); check(sticks_are(s, 0, 0, -32767, 32767), "I+J → 右摇杆 (-32767, 32767)");
    press(&def, (const int[]){40, 37, -1}, &b, s); check(sticks_are(s, 0, 0, 32767, -32767), "K+L → 右摇杆 (32767, -32767)");
    press(&def, (const int[]){-1}, &b, s); check(b == 0 && sticks_are(s, 0, 0, 0, 0), "什么都没按 → 全零");

    // ⑤ 修饰键组合（front_mac.m sample_input：组合优先、用掉的修饰键不再单独触发）
    s2a_input_config combo; s2a_input_config_default(&combo);
    combo.keyboard[0] = (s2a_input_key){14, 1};   // A = Shift+E
    combo.keyboard[1] = (s2a_input_key){56, 0};   // B = Shift（单按）
    press(&combo, (const int[]){56, 14, -1}, &b, s); check(b == 1u << 0, "Shift+E → 只有 A，Shift 被组合用掉不再触发 B");
    press(&combo, (const int[]){56, -1}, &b, s);     check(b == 1u << 1, "单按 Shift → B");
    press(&combo, (const int[]){14, -1}, &b, s);     check(b == 0, "不按 Shift 的 E → 什么都不触发（A 要 Shift+E）");

    // ⑥ 并进实体手柄：或起来、相加后夹到 ±32767（front_mac.m pad_event_fast）
    uint32_t mb = 1u << 1; int32_t ms[4] = {30000, -30000, 100, 0}; const int32_t ks[4] = {32767, -32767, 0, 0};
    s2a_kbd_merge(&mb, ms, 1u << 0, ks);
    check(mb == 3u && sticks_are(ms, 32767, -32767, 100, 0), "手柄 B + 键盘 A；摇杆相加夹到 ±32767");

    // ⑦ HID 键盘区（front_mac.m publish_keyboard）：A 键 usage 0x04、左 Shift 0xE1；字段 Shift=2、Control=1、Option=4、CapsLock=0x100
    s2a_kbd_keys k = {{0, 0}}; uint64_t bits[4]; uint32_t mods;
    s2a_kbd_set(&k, 0, 1); s2a_kbd_set(&k, 56, 1);
    s2a_kbd_hid(&k, 0, bits, &mods);
    check(bits[0] == 1ULL << 0x04 && bits[3] == 1ULL << (0xE1 - 192) && bits[1] == 0 && bits[2] == 0 && mods == 2u, "A + 左 Shift → 位图 0x04、0xE1，字段 Shift");
    s2a_kbd_keys k2 = {{0, 0}}; s2a_kbd_set(&k2, 59, 1); s2a_kbd_set(&k2, 58, 1);
    s2a_kbd_hid(&k2, 1, bits, &mods);
    check(mods == (1u | 4u | 0x100u) && (bits[0] >> 0x39 & 1) && bits[3] == ((1ULL << (0xE0 - 192)) | (1ULL << (0xE2 - 192))), "Control + Option + CapsLock 锁定 → 字段 1|4|0x100，位图 0xE0、0xE2、0x39");

    // ⑧ schema 1 往返：写出来的 JSON 被共用解析器读回同一份（iPad 改键页按款存的格式）
    char json[4096]; s2a_input_config back;
    int n = s2a_kbd_config_json(&def, json, sizeof json);
    check(n > 0 && s2a_input_config_parse(json, (size_t)n, &back) == S2A_INPUT_CONFIG_OK && !memcmp(back.keyboard, def.keyboard, sizeof def.keyboard)
          && !memcmp(back.mouse, def.mouse, sizeof def.mouse) && !memcmp(back.gamepad, def.gamepad, sizeof def.gamepad) && !memcmp(back.axes, def.axes, sizeof def.axes)
          && back.deadzone == def.deadzone && back.mouse_camera == def.mouse_camera && back.recenter == def.recenter, "iPad 缺省写成 schema 1 再读回，逐项相同");
    n = s2a_kbd_config_json(&combo, json, sizeof json);
    check(n > 0 && s2a_input_config_parse(json, (size_t)n, &back) == S2A_INPUT_CONFIG_OK && back.keyboard[0].modifiers == 1 && back.keyboard[0].code == 14, "带修饰键的绑定写出再读回");
    check(s2a_kbd_config_json(&def, json, 16) == -1, "缓冲放不下 → -1");

    // ⑨ 接线：controller.m 照 Mac 选源（没有手柄走触屏源、有手柄并进系统手柄 / NS2 Pro），keyboard.m 采 GCKeyboard、挡 ⌘、喂键盘区
    char *ctl = slurp(argv[2]), *kbd = slurp(argv[3]);
    check(ctl && kbd, "读得到 controller.m 与 keyboard.m");
    if (ctl && kbd) {
        check(count_in(ctl, "s2a_kbd_merge(&buttons, axes, kb_buttons, kb_sticks)") >= 2, "controller.m：系统手柄与 NS2 Pro 玩家 1 都并进键盘（同 Mac 槽 0）");
        check(count_in(ctl, "s2a_pad_update(S2A_PAD_TOUCH, 1, buttons, sticks)") == 1, "controller.m：没有手柄时键盘按触屏源发布（同 Mac publish_pad_state）");
        check(count_in(ctl, "s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL)") == 1, "controller.m：系统手柄清零仍只在 clearSystem 一处（t_pad_liveness 的约束不破）");
        check(count_in(ctl, "s2a_vpad_touch_only() == 1") >= 1, "controller.m：触屏模式下手指不结束键盘接管");
        check(count_in(kbd, "coalescedKeyboard") >= 1 && count_in(kbd, "keyChangedHandler") >= 1, "keyboard.m：采 GCKeyboard.coalescedKeyboard 的 keyChangedHandler");
        check(count_in(kbd, "s2a_kbd_mac_hid[k]") >= 1 && count_in(kbd, "s2a_kbd_canonical(k)") >= 1 && count_in(kbd, "s2a_kbd_map(") >= 1, "keyboard.m：照 keyboard_map.h 的键码表问系统、并左右修饰键、映射");
        check(count_in(kbd, "s2a_kbd_hid(") >= 1 && count_in(kbd, "s2a_kb_update(") >= 1, "keyboard.m：原始键态喂 HID 键盘区（同 Mac R5）");
        check(count_in(kbd, "S2A_KBD_COMMAND") >= 1, "keyboard.m：⌘ 组合不收（同 Mac）");
        check(count_in(kbd, "s2a_kbd_default(") >= 1, "keyboard.m：没存过键位时用 iPad 缺省");
        // 切后台只放开按着的键、不结束接管（同系统手柄：回前台自动接回，虚拟按键不跳出来）；回前台键盘已不在才结束接管
        char *bg = body_of(kbd, "void s2a_ios_keyboard_background(void)"), *fg = body_of(kbd, "void s2a_ios_keyboard_foreground(void)");
        check(bg && count_in(bg, "release_keys()") == 1 && !count_in(bg, "release_all") && !count_in(bg, "s2a_ios_keyboard_end"), "keyboard.m：切后台只放开按着的键，接管保留");
        check(fg && count_in(fg, "coalescedKeyboard") >= 1 && count_in(fg, "release_all()") == 1, "keyboard.m：回前台键盘已不在 → 放开并结束接管");
        check(count_in(ctl, "s2a_ios_keyboard_foreground()") == 1, "controller.m：回前台时核对键盘还在不在");
        free(bg); free(fg);
    }
    free(ctl); free(kbd);

    if (failures) { fprintf(stderr, "✗ t_keyboard_map：%d/%d 项不通\n", failures, checks); return 1; }
    printf("✓ t_keyboard_map：%d 项（键码表与 Mac 逐项相同、iPad 缺省、按键 / 摇杆 / 组合键同 Mac、并进手柄、键盘区、schema 1 往返、接线）\n", checks);
    return 0;
}
