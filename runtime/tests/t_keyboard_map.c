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
// 两份键位逐字段相同（不用 memcmp：结构体里有填充字节）
static int kbd_same(const s2a_input_config *a, const s2a_input_config *b) {
    for (int i = 0; i < S2A_INPUT_TARGET_COUNT; i++)
        if (a->keyboard[i].code != b->keyboard[i].code || a->keyboard[i].modifiers != b->keyboard[i].modifiers || a->mouse[i] != b->mouse[i] || a->gamepad[i] != b->gamepad[i]) return 0;
    for (int i = 0; i < S2A_INPUT_AXIS_COUNT; i++) if (a->axes[i].source != b->axes[i].source || a->axes[i].invert != b->axes[i].invert) return 0;
    return a->deadzone == b->deadzone && a->sensitivity_x == b->sensitivity_x && a->sensitivity_y == b->sensitivity_y && a->mouse_camera == b->mouse_camera
        && a->invert_x == b->invert_x && a->invert_y == b->invert_y && a->recenter == b->recenter && a->back_buttons[0] == b->back_buttons[0] && a->back_buttons[1] == b->back_buttons[1];
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
    if (argc != 5) { fprintf(stderr, "用法：t_keyboard_map <front_mac.m> <controller.m> <keyboard.m> <keyboard_settings.m>\n"); return 2; }

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
    // ⑨ 导入键位（#1987）：改键页「导入键位…」读进来的文件走 s2a_kbd_import——先看大小，再交共用解析器；失败不动当前键位
    {
        // Mac 启动器格式的标准键位（手写，照 input_config.c:466 的缺省键码表与 validate_input 的字段；没绑的按键位不写）
        static const char mac_standard[] =
            "{\"schema\": 1,\n"
            " \"keyboard\": {\"A\": {\"code\": 14}, \"B\": {\"code\": 56}, \"X\": {\"code\": 49}, \"LS\": {\"code\": 59}, \"RS\": {\"code\": 8},\n"
            "   \"L\": {\"code\": 12}, \"R\": {\"code\": 5}, \"ZR\": {\"code\": 15}, \"PLUS\": {\"code\": 48}, \"MINUS\": {\"code\": 46},\n"
            "   \"LEFT\": {\"code\": 123}, \"UP\": {\"code\": 126}, \"RIGHT\": {\"code\": 124}, \"DOWN\": {\"code\": 125},\n"
            "   \"LS_LEFT\": {\"code\": 0}, \"LS_UP\": {\"code\": 13}, \"LS_RIGHT\": {\"code\": 2}, \"LS_DOWN\": {\"code\": 1}},\n"
            " \"mouse\": {\"Y\": 0, \"ZL\": 1},\n"
            " \"gamepad\": {\"A\": \"east\", \"B\": \"south\", \"X\": \"north\", \"Y\": \"west\", \"LS\": \"leftStick\", \"RS\": \"rightStick\",\n"
            "   \"L\": \"leftShoulder\", \"R\": \"rightShoulder\", \"ZL\": \"leftTrigger\", \"ZR\": \"rightTrigger\", \"PLUS\": \"menu\", \"MINUS\": \"options\",\n"
            "   \"LEFT\": \"dpadLeft\", \"UP\": \"dpadUp\", \"RIGHT\": \"dpadRight\", \"DOWN\": \"dpadDown\"},\n"
            " \"axes\": {\"LX\": {\"source\": \"leftX\"}, \"LY\": {\"source\": \"leftY\"}, \"RX\": {\"source\": \"rightX\"}, \"RY\": {\"source\": \"rightY\"}},\n"
            " \"deadzone\": 0.15,\n"
            " \"mouseOptions\": {\"mode\": \"camera\", \"sensitivityX\": 1, \"sensitivityY\": 1}}\n";
        s2a_input_config got, want, before;
        s2a_input_config_default(&want);
        s2a_kbd_default(&got);
        check(s2a_kbd_import(mac_standard, sizeof mac_standard - 1, &got) == S2A_KBD_IMPORT_OK && kbd_same(&got, &want),
              "导入 Mac 启动器格式的标准键位 → 与共用缺省逐项相同（不替玩家补 iPad 多绑的 Y / ZL / 右摇杆）");
        // 改过的键位（含修饰键、鼠标键、鼠标选项）：导出再导入，逐项相同
        s2a_input_config mine; s2a_kbd_default(&mine);
        mine.keyboard[0] = (s2a_input_key){14, 1}; mine.mouse[1] = 2; mine.mouse_camera = 0; mine.sensitivity_x = 2.5; mine.invert_y = 1; mine.recenter = 0;
        char out[4096]; int n = s2a_kbd_config_json(&mine, out, sizeof out);
        s2a_kbd_default(&got);
        check(n > 0 && s2a_kbd_import(out, (size_t)n, &got) == S2A_KBD_IMPORT_OK && kbd_same(&got, &mine), "改过的键位导出再导入，逐项相同（含修饰键、鼠标键、鼠标选项）");
        // 大小：上限内（有效 JSON 后面补空白到正好上限）收；多 1 字节就拒，不交给解析器、不动当前键位
        size_t limit = S2A_KBD_IMPORT_MAX_BYTES;
        char *big = malloc(limit + 1);
        if (big) {
            memset(big, ' ', limit + 1); memcpy(big, mac_standard, sizeof mac_standard - 1);
            s2a_kbd_default(&got);
            check(s2a_kbd_import(big, limit, &got) == S2A_KBD_IMPORT_OK && kbd_same(&got, &want), "正好上限大小（有效 JSON 补空白）→ 收");
            s2a_kbd_default(&got); before = got;
            check(s2a_kbd_import(big, limit + 1, &got) == S2A_KBD_IMPORT_TOO_LARGE && kbd_same(&got, &before), "超过上限 1 字节 → 拒（太大），当前键位不动");
            free(big);
        } else check(0, "分配大文件缓冲");
        // 坏文件：各自给出对应的错误，当前键位不动
        static const char dup[] = "{\"schema\": 1, \"keyboard\": {\"A\": {\"code\": 14}, \"B\": {\"code\": 14}}, \"mouse\": {}, \"gamepad\": {}, \"axes\": {},"
                                  " \"deadzone\": 0.15, \"mouseOptions\": {\"mode\": \"camera\", \"sensitivityX\": 1, \"sensitivityY\": 1}}";
        static const char v2[] = "{\"schema\": 2}";
        s2a_kbd_default(&got); before = got;
        check(s2a_kbd_import("{", 1, &got) == S2A_INPUT_CONFIG_JSON && kbd_same(&got, &before), "读不出 JSON → JSON 错，当前键位不动");
        check(s2a_kbd_import("", 0, &got) == S2A_INPUT_CONFIG_JSON && kbd_same(&got, &before), "空文件 → JSON 错");
        check(s2a_kbd_import(v2, sizeof v2 - 1, &got) == S2A_INPUT_CONFIG_SCHEMA && kbd_same(&got, &before), "schema 不是 1 → 版本错");
        check(s2a_kbd_import(dup, sizeof dup - 1, &got) == S2A_INPUT_CONFIG_DUPLICATE && kbd_same(&got, &before), "同一个键绑两个按键位 → 重复错");
    }

    char *ctl = slurp(argv[2]), *kbd = slurp(argv[3]);
    check(ctl && kbd, "读得到 controller.m 与 keyboard.m");
    if (ctl && kbd) {
        check(count_in(ctl, "s2a_kbd_merge(&buttons, axes, kb_buttons, kb_sticks)") >= 2, "controller.m：系统手柄与 NS2 Pro 玩家 1 都并进键盘（同 Mac 槽 0）");
        {   // 手柄改键接线（#1606 ④）：sample_extended 出口按这一款键位映射一次（玩家 1 与槽 1–3 共用这一个出口）
            char *se = body_of(ctl, "static void sample_extended(");
            check(se && count_in(se, "s2a_pad_map(s2a_ios_pad_map_config(), &buttons, axes)") == 1, "controller.m：sample_extended 出口照这一款键位做手柄改键");
            check(count_in(kbd, "const s2a_input_config *s2a_ios_pad_map_config(void)") == 1 && count_in(kbd, "return &g_map;") == 1, "keyboard.m：手柄改键读的是改键页同一份 g_map");
            free(se);
        }
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

    // ⑩ 改键页的导入 / 导出接线（UIKit 在 Mac 宿主上编不了，接线靠文本钉住；语法另由 keyboard_map.mk 用 iOS SDK 查）
    char *page = slurp(argv[4]);
    check(page != NULL, "读得到 keyboard_settings.m");
    if (page) {
        check(count_in(page, "initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES") == 1, "导入：选文件面板只认 JSON、以副本方式读（同触屏布局页）");
        check(count_in(page, "s2a_kbd_import(") == 1, "导入：读进来的内容交 s2a_kbd_import（先查大小再解析）");
        check(count_in(page, "initForExportingURLs:") == 1, "导出：用选文件面板导出（同触屏布局页，不走分享面板）");
        check(count_in(page, "s2a_kbd_config_json(") == 1 && count_in(page, "s2a_kbd_store_save(game, app, &_map, _mouseOff)") == 1,
              "导出写 schema 1 JSON；存盘交 keyboard_store（写的是同一份 JSON，t_keyboard_store ② 核逐字相同）");
        // 「使用鼠标 / 触控板」开关（#2072）：存、设为默认都带上；读进来、恢复默认 / 撤销后重读；关了鼠标时「…」里的鼠标键置灰
        check(count_in(page, "s2a_kbd_store_set_default(game, app, &_map, _mouseOff)") == 1 && count_in(page, "_mouseOff = load_mouse_off()") == 2,
              "鼠标开关：存与设为默认都交 keyboard_store；进页面、恢复默认 / 设默认 / 撤销后都重读");
        check(count_in(page, "if (_mouseOff) pick.attributes = UIMenuElementAttributesDisabled;") == 1 && count_in(page, "((UIControl *)cell.accessoryView).enabled = !_mouseOff;") == 1,
              "鼠标开关关掉：「…」里的鼠标键和鼠标组下面几行置灰");
        char *cancel = body_of(page, "- (void)documentPickerWasCancelled:");
        check(cancel && count_in(cancel, "cleanExport") == 1, "导出取消也清掉临时目录");
        free(cancel);
        static const char *const errs[] = {"kbd.import.err.read", "kbd.import.err.tooLarge", "kbd.import.err.json", "kbd.import.err.schema", "kbd.import.err.duplicate", "kbd.import.err.invalid"};
        int all = 1; for (size_t i = 0; i < sizeof errs / sizeof *errs; i++) all &= count_in(page, errs[i]) >= 1;
        check(all, "导入失败的每一类都有自己的说法（读不了 / 太大 / 不是 JSON / 版本不对 / 重复绑定 / 内容无效）");
        // 新加的「管理键位」组不能被当成按键位行（refreshVisibleRows / 点击原先按「不是鼠标组就是按键位」处理）
        char *refresh = body_of(page, "- (void)refreshVisibleRows"), *select = body_of(page, "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:");
        check(refresh && count_in(refresh, "kManageSection") >= 1, "refreshVisibleRows 跳过「管理键位」组");
        check(select && count_in(select, "kManageSection") >= 1, "点「管理键位」组的行走导入 / 导出，不进录键");
        free(refresh); free(select);
        // #2071：每行「…」菜单的清除交 s2a_kbd_clear_target（键盘、鼠标一起清），不再只置键盘那半
        check(count_in(page, "s2a_kbd_clear_target(&page->_map, target)") == 1, "行内「清除按键设置」交 s2a_kbd_clear_target");
        check(count_in(page, "_map.keyboard[target] = (s2a_input_key){-1, 0}") == 0, "行内清除不再只置键盘那半");
    }
    free(page);

    // ⑪ 清除一个按键位（#2071）：同一行显示的键盘键和鼠标键一起清；别的按键位、手柄、鼠标选项不动。期望值手推
    {
        s2a_input_config d; s2a_kbd_default(&d);   // 缺省：Y = F + 左键（鼠标 0），ZL = Z + 右键（鼠标 1）
        s2a_input_config c = d;
        c.keyboard[0].modifiers = 1;                // A = ⇧E：带修饰键也要一起清掉
        s2a_kbd_clear_target(&c, 3);
        check(c.keyboard[3].code == -1 && c.keyboard[3].modifiers == 0 && c.mouse[3] == -1, "清除 Y：键盘 F 和鼠标左键都清掉");
        s2a_kbd_clear_target(&c, 0);
        check(c.keyboard[0].code == -1 && c.keyboard[0].modifiers == 0 && c.mouse[0] == -1, "清除 A：键盘 ⇧E 清掉、修饰键归零");
        s2a_input_config want = d;
        want.keyboard[3] = (s2a_input_key){-1, 0}; want.mouse[3] = -1; want.keyboard[0] = (s2a_input_key){-1, 0};
        check(kbd_same(&c, &want), "其余按键位（ZL 的右键、手柄、摇杆轴）与鼠标选项不动");
        s2a_input_config edge = d;
        s2a_kbd_clear_target(&edge, -1); s2a_kbd_clear_target(&edge, S2A_INPUT_TARGET_COUNT);
        check(kbd_same(&edge, &d), "按键位号越界：什么都不改");
    }

    // 实体手柄改键 s2a_pad_map（#1606 ④，同 Mac map_pad_inputs）：期望值手推
    {
        s2a_input_config d; s2a_kbd_default(&d);
        int same = 1;
        for (int i = 0; i < 16; i++) {
            uint32_t b = 1u << i; int32_t st[4] = {1000, -2000, 3000, -4000};
            s2a_pad_map(&d, &b, st);
            same &= b == (1u << i) && st[0] == 1000 && st[1] == -2000 && st[2] == 3000 && st[3] == -4000;
        }
        check(same, "手柄改键：缺省配置 16 个键逐个按、摇杆四轴都原样出来");
        uint32_t home = (1u << 16) | 1u; int32_t z[4] = {0};
        s2a_pad_map(&d, &home, z);
        check(home == ((1u << 16) | 1u), "手柄改键：Home 扩展位 bit16 原样保留");

        s2a_input_config swap = d; swap.gamepad[0] = 1; swap.gamepad[1] = 0;   // 目标 A ← 物理 south、目标 B ← 物理 east
        uint32_t e = 1u << 0, so = 1u << 1; int32_t s1[4] = {0}, s2[4] = {0};
        s2a_pad_map(&swap, &e, s1); s2a_pad_map(&swap, &so, s2);
        check(e == (1u << 1) && so == (1u << 0), "手柄改键：A / B 对调后按 east 出 B、按 south 出 A");

        s2a_input_config up = d; up.gamepad[13] = -1; up.gamepad[17] = 13;   // 目标 UP 不绑；目标 LS_UP ← 物理 dpadUp
        uint32_t du = 1u << 13; int32_t s3[4] = {0};
        s2a_pad_map(&up, &du, s3);
        check(du == 0 && s3[0] == 0 && s3[1] == 32767, "手柄改键：十字键上改成左摇杆上 → 不出按键位、左摇杆 Y = +32767");

        s2a_input_config inv = d; inv.axes[1].invert = 1; inv.axes[0].source = -1;
        uint32_t nb = 0; int32_t s4[4] = {5000, -2000, 0, 0};
        s2a_pad_map(&inv, &nb, s4);
        check(s4[0] == 0 && s4[1] == 2000, "手柄改键：左 X 不绑 → 0；左 Y 取反 -2000 → 2000");

        s2a_input_config right = d; right.gamepad[18] = 14;   // 目标 LS_RIGHT ← 物理 dpadRight（十字键右照旧也出按键位）
        uint32_t dr = 1u << 14; int32_t s5[4] = {30000, 0, 0, 0};
        s2a_pad_map(&right, &dr, s5);
        check(dr == (1u << 14) && s5[0] == 32767, "手柄改键：按键绑摇杆方向与源轴叠加，夹到 +32767");

        uint32_t keep = 0x5; int32_t s6[4] = {7, 8, 9, 10};
        s2a_pad_map(NULL, &keep, s6);
        check(keep == 0x5 && s6[0] == 7 && s6[3] == 10, "手柄改键：没有配置原样不动");
    }

    if (failures) { fprintf(stderr, "✗ t_keyboard_map：%d/%d 项不通\n", failures, checks); return 1; }
    printf("✓ t_keyboard_map：%d 项（键码表与 Mac 逐项相同、iPad 缺省、按键 / 摇杆 / 组合键同 Mac、并进手柄、键盘区、schema 1 往返、导入 / 导出、接线）\n", checks);
    return 0;
}
