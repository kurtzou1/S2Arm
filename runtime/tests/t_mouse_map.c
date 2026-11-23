// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 触控板 / 鼠标（#1869 PR 2）：ios/mouse_map.h 的纯决策与 Mac（macos/front_mac.m）同规则。
//   期望值全部手写（位序 / 摇杆满量 / × 1500 照 front_mac.m 手算），不拿被测函数的输出当期望；
//   换算系数与左键规则另读 front_mac.m 原文对照（两端各写一份，改了一边另一边就红）；
//   接线断言读 ios/ 原文（GameController / UIKit 在 Mac 宿主上编不了，接线靠文本钉住）。
#include "../../ios/keyboard_map.h"
#include "../../ios/mouse_map.h"
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
    const char *p = text ? strstr(text, signature) : NULL, *e = p ? strstr(p, "\n}") : NULL;
    size_t n = e ? (size_t)(e - p) : 0;
    char *s = malloc(n + 1); if (!s) return NULL;
    if (n) memcpy(s, p, n);
    s[n] = 0; return s;
}
static int sticks_are(const int32_t s[4], int32_t a, int32_t b, int32_t c, int32_t d) { return s[0] == a && s[1] == b && s[2] == c && s[3] == d; }
static s2a_mouse_state st(int touch_only, int hidden, int locked, int camera, int declared_default, int left_bound) {
    s2a_mouse_state s = {touch_only, hidden, locked, camera, declared_default, left_bound, 0}; return s;
}

int main(int argc, char **argv) {
    if (argc != 9) { fprintf(stderr, "用法：t_mouse_map <front_mac.m> <mouse.m> <keyboard.m> <vpad.m> <controller.m> <app.m> <tv_host.m> <runtime/build.mk>\n"); return 2; }
    char *mac = slurp(argv[1]);
    check(mac != NULL, "读得到 front_mac.m");

    // ① 换算系数与 Mac 同值（mouseMoved：deltaX × 1500、-deltaY × 1500）
    check(S2A_MOUSE_SCALE == 1500 && mac && count_in(mac, "e.deltaX * 1500") == 1 && count_in(mac, "-e.deltaY * 1500") == 1,
          "鼠标位移系数 = front_mac.m mouseMoved 的 1500");
    // Mac 左键规则原文：① 声明触屏 + 缺省键位 → 触屏，先于「转动视角」；② 仅按键模式下左键没映射 → 触屏
    char *ltouch = body_of(mac, "static BOOL left_click_touches(void)");
    const char *r1 = ltouch ? strstr(ltouch, "touch_declared) >= 0 && mouse_use_is_default()) return YES") : NULL, *r2 = ltouch ? strstr(ltouch, "if (camera_mouse()) return NO") : NULL;
    check(r1 && r2 && r1 < r2 && count_in(ltouch, "isEqual:@0]) return NO") == 1, "front_mac.m left_click_touches 仍是「① 声明触屏 + 缺省 → 触屏，先于转动视角；② 左键没映射 → 触屏」");
    char *mdef = body_of(mac, "static BOOL mouse_use_is_default(void)");
    check(mdef && count_in(mdef, "camera_mouse() && [left_targets(config) isEqualToSet:left_targets(default_config())]") == 1,
          "front_mac.m「没动过鼠标的用法」只比左键绑在哪、鼠标模式（#1987 维护方定，iPad s2a_mouse_use_default 同口径）");
    free(mdef);
    char *down = body_of(mac, "- (void)mouseDown:(NSEvent *)e");
    const char *d1 = down ? strstr(down, "left_click_touches()") : NULL, *d2 = down ? strstr(down, "camera_mouse()) { set_mouse_capture(YES); return; }") : NULL;
    check(d1 && d2 && d1 < d2 && count_in(down, "!mouse_captured") == 2, "front_mac.m mouseDown：没锁定时先看触屏、再看锁定，锁定后照映射");
    free(ltouch); free(down);

    // ② 缺省（同 Mac：s2a_input_config_default，iPad 键盘叠加项不动鼠标）：左键 = Y、右键 = ZL、转动视角、灵敏度 1、回中
    s2a_input_config c; s2a_kbd_default(&c);
    int others = 0; for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++) if (t != 3 && t != 8 && c.mouse[t] >= 0) others++;
    check(c.mouse[3] == 0 && c.mouse[8] == 1 && !others && c.mouse_camera == 1 && c.sensitivity_x == 1 && c.sensitivity_y == 1 && c.recenter == 1 && !c.invert_x && !c.invert_y,
          "iPad 缺省鼠标 = 左键 Y、右键 ZL、转动视角、灵敏度 1、回中、不反转");

    // ③ 鼠标键 → 按键位 / 摇杆（与键盘同一个 action）
    uint32_t b = 0; int32_t s[4] = {0};
    s2a_mouse_map(&c, 1u << 0, &b, s); check(b == 0x8 && sticks_are(s, 0, 0, 0, 0), "左键 → Y（0x8）");
    b = 0; s2a_mouse_map(&c, 1u << 1, &b, s); check(b == 0x100, "右键 → ZL（0x100）");
    b = 0; s2a_mouse_map(&c, 0x3u, &b, s); check(b == 0x108, "左右键一起 → Y | ZL");
    b = 0; s2a_mouse_map(&c, 1u << 2, &b, s); check(b == 0 && sticks_are(s, 0, 0, 0, 0), "中键缺省没绑 → 什么都不发");
    s2a_input_config m = c; m.mouse[21] = 2; m.mouse[16] = 4;   // RS_UP = 中键、LS_LEFT = 侧键 2
    b = 0; memset(s, 0, sizeof s); s2a_mouse_map(&m, (1u << 2) | (1u << 4), &b, s);
    check(b == 0 && sticks_are(s, -32767, 0, 0, 32767), "中键 → 右摇杆上满量、侧键 2 → 左摇杆左满量");
    b = 0; memset(s, 0, sizeof s); s2a_mouse_map(&m, 1u << 5, &b, s); check(b == 0 && sticks_are(s, 0, 0, 0, 0), "超出 0–4 的键不认");

    // ④ 位移 → 右摇杆增量（× 1500 × 灵敏度，反转乘 -1；dy 向上为正）
    int64_t ox, oy;
    s2a_mouse_delta(&c, 1, 1, &ox, &oy); check(ox == 1500 && oy == 1500, "灵敏度 1：(1, 1) → (1500, 1500)");
    s2a_mouse_delta(&c, -2.5, 0.25, &ox, &oy); check(ox == -3750 && oy == 375, "(-2.5, 0.25) → (-3750, 375)");
    m = c; m.sensitivity_x = 2; m.sensitivity_y = 0.5; m.invert_y = 1;
    s2a_mouse_delta(&m, 1, 1, &ox, &oy); check(ox == 3000 && oy == -750, "横 2、纵 0.5 且纵向反转：(1, 1) → (3000, -750)");
    m = c; m.invert_x = 1; s2a_mouse_delta(&m, 1, -1, &ox, &oy); check(ox == -1500 && oy == -1500, "横向反转：(1, -1) → (-1500, -1500)");

    // ⑤ 读一次消费一次（take_mouse_delta）
    int64_t acc[2] = {20000, -40000}, hold[2] = {0, 0};
    memset(s, 0, sizeof s); s2a_mouse_take(1, acc, hold, s);
    check(s[2] == 20000 && s[3] == -32767 && acc[0] == 0 && acc[1] == 0, "回中：这一拍 (20000, -40000) → 右摇杆 (20000, -32767)，攒的清零");
    memset(s, 0, sizeof s); s2a_mouse_take(1, acc, hold, s); check(s[2] == 0 && s[3] == 0, "回中：停手的下一拍右摇杆回 0");
    int64_t a2[2] = {20000, 0}, h2[2] = {0, 0};
    memset(s, 0, sizeof s); s2a_mouse_take(0, a2, h2, s); check(s[2] == 20000, "不回中：第一拍 20000");
    memset(s, 0, sizeof s); s2a_mouse_take(0, a2, h2, s); check(s[2] == 20000 && h2[0] == 20000, "不回中：停手后仍停在 20000");
    a2[0] = 20000; memset(s, 0, sizeof s); s2a_mouse_take(0, a2, h2, s); check(s[2] == 32767 && h2[0] == 32767, "不回中：保持量夹到 32767");
    int64_t a3[2] = {1000, 0}, h3[2] = {0, 0}; int32_t kb[4] = {0, 0, 32767, 0};
    s2a_mouse_take(1, a3, h3, kb); check(kb[2] == 32767, "与键盘的右摇杆满量相加后夹到 32767");

    // ⑥ 左键做什么（mouseDown + left_click_touches + iPad 两种模式）
    check(s2a_mouse_left(st(1, 0, 0, 1, 0, 1)) == S2A_MOUSE_PASS, "仅触屏：左键交给 UIKit 当手指");
    check(s2a_mouse_left(st(0, 0, 0, 1, 0, 1)) == S2A_MOUSE_PASS, "按键模式、虚拟按键显示着：左键点虚拟按键");
    check(s2a_mouse_left(st(0, 1, 1, 1, 0, 1)) == S2A_MOUSE_BUTTON, "已锁定：左键照映射（Y）");
    check(s2a_mouse_left(st(0, 1, 0, 1, 1, 1)) == S2A_MOUSE_TOUCH, "① 声明触屏 + 缺省键位：左键当触屏，先于转动视角");
    check(s2a_mouse_left(st(0, 1, 0, 1, 0, 1)) == S2A_MOUSE_LOCK, "转动视角、没锁定：点一下只锁定");
    check(s2a_mouse_left(st(0, 1, 0, 0, 0, 1)) == S2A_MOUSE_BUTTON, "② 不起作用模式、左键映射了：照映射");
    check(s2a_mouse_left(st(0, 1, 0, 0, 0, 0)) == S2A_MOUSE_TOUCH, "② 不起作用模式、左键没映射：当触屏");
    check(s2a_mouse_other_counts(st(1, 0, 0, 1, 0, 1)) && s2a_mouse_other_counts(st(0, 1, 0, 1, 0, 1)) && !s2a_mouse_other_counts(st(0, 0, 0, 1, 0, 1)),
          "右 / 中 / 侧键：仅触屏或虚拟按键收起时照映射，虚拟按键显示着时不进游戏");
    check(s2a_mouse_may_lock(st(0, 1, 0, 1, 0, 1)) && !s2a_mouse_may_lock(st(1, 1, 0, 1, 0, 1)) && !s2a_mouse_may_lock(st(0, 0, 0, 1, 0, 1)) && !s2a_mouse_may_lock(st(0, 1, 0, 0, 0, 1)),
          "只在按键模式、虚拟按键收起、转动视角时才能锁着");

    // ⑥a「玩家没动过鼠标的用法」（规则 ① 的缺省，#1987 维护方 11-22 定）：只看左键绑在哪个按键位上、鼠标模式，别的键改了不算
    s2a_input_config u; s2a_kbd_default(&u);
    check(s2a_mouse_use_default(&u), "缺省键位：没动过鼠标的用法");
    u.gamepad[0] = c.gamepad[1]; u.gamepad[1] = c.gamepad[0];
    check(s2a_mouse_use_default(&u), "所有游戏的默认只换了一组手柄键（A / B 对调）：仍算没动过，触屏游戏里左键照旧当触屏");
    s2a_kbd_default(&u); u.keyboard[0].code = 36;
    check(s2a_mouse_use_default(&u), "某款只改了一个键盘键（A → 回车）：仍算没动过");
    s2a_kbd_default(&u); u.sensitivity_x = 2; u.mouse[8] = -1;
    check(s2a_mouse_use_default(&u), "只改了灵敏度、右键不绑：左键和模式没动，仍算没动过");
    s2a_kbd_default(&u); u.mouse[3] = -1; u.mouse[9] = 0;
    check(!s2a_mouse_use_default(&u), "左键改绑成 ZR：动过，不接管（转动视角下点一下锁定）");
    check(s2a_mouse_left(st(0, 1, 0, 1, s2a_mouse_use_default(&u), 1)) == S2A_MOUSE_LOCK, "  ↳ 声明了触屏、左键改绑成 ZR：左键 = 只锁定（不当触屏）");
    s2a_kbd_default(&u); u.mouse[3] = -1; u.mouse_camera = 0;
    check(!s2a_mouse_use_default(&u), "鼠标模式改成不起作用、左键没绑：动过");
    check(s2a_mouse_left(st(0, 1, 0, 0, s2a_mouse_use_default(&u), 0)) == S2A_MOUSE_TOUCH, "  ↳ 按规则 ② 接管：左键当触屏");
    s2a_kbd_default(&u); u.mouse_camera = 0;
    check(!s2a_mouse_use_default(&u) && s2a_mouse_left(st(0, 1, 0, 0, 0, 1)) == S2A_MOUSE_BUTTON, "鼠标模式改成不起作用、左键仍绑 Y：动过，照映射发 Y");

    // ⑥b「使用鼠标 / 触控板」关掉（#2072）：其余 6 项怎么组合（64 种），左键都交给 UIKit 当手指、别的键不进游戏、不锁定
    int off_pass = 0, off_quiet = 0, on_differs = 0;
    for (int bits = 0; bits < 64; bits++) {
        s2a_mouse_state o = st(bits & 1, bits >> 1 & 1, bits >> 2 & 1, bits >> 3 & 1, bits >> 4 & 1, bits >> 5 & 1); o.off = 1;
        off_pass += s2a_mouse_left(o) == S2A_MOUSE_PASS;
        off_quiet += !s2a_mouse_other_counts(o) && !s2a_mouse_may_lock(o);
        s2a_mouse_state n = o; n.off = 0;
        on_differs += s2a_mouse_left(n) != S2A_MOUSE_PASS;
    }
    check(off_pass == 64, "关掉鼠标：64 种状态下左键都交给 UIKit 当手指（叫出虚拟按键 / 点画面）");
    check(off_quiet == 64, "关掉鼠标：64 种状态下右 / 中 / 侧键都不进游戏、都不锁定");
    check(on_differs == 16, "对照：开着鼠标时同样 64 种里有 16 种（按键模式、虚拟按键收起）左键不是当手指（关掉的断言不是白过）");
    s2a_mouse_state zero = {0};
    check(zero.off == 0 && s2a_mouse_left(st(0, 1, 0, 1, 0, 1)) == S2A_MOUSE_LOCK, "没写 off 的状态 = 开着（缺省打开，同 Mac）");

    // ⑦ 接线
    char *mouse = slurp(argv[2]), *kbd = slurp(argv[3]), *vpad = slurp(argv[4]), *ctl = slurp(argv[5]), *app = slurp(argv[6]);
    check(mouse && kbd && vpad && ctl && app, "读得到 mouse.m / keyboard.m / vpad.m / controller.m / app.m");
    if (mouse && kbd && vpad && ctl && app) {
        check(count_in(mouse, "GCMouseDidConnectNotification") >= 1 && count_in(mouse, "mouseMovedHandler") >= 1 && count_in(mouse, "pressedChangedHandler") >= 1,
              "mouse.m：采 GCMouse 的按键与位移");
        check(count_in(mouse, "s2a_mouse_left(") >= 1 && count_in(mouse, "s2a_mouse_delta(") >= 1 && count_in(mouse, "s2a_mouse_take(") >= 1 && count_in(mouse, "s2a_mouse_may_lock(") >= 1,
              "mouse.m：左键规则、位移换算、读一次消费一次、能不能锁都走 mouse_map.h");
        check(count_in(mouse, "setNeedsUpdateOfPrefersPointerLocked") >= 1 && count_in(mouse, "UIPointerLockStateDidChangeNotification") >= 1,
              "mouse.m：锁定走系统指针锁定，并看系统给没给");
        check(count_in(kbd, "s2a_mouse_map(") == 1 && count_in(kbd, "s2a_ios_mouse_escape(") == 1, "keyboard.m：鼠标键与键盘一起映射；Esc 先问鼠标要不要释放");
        check(count_in(vpad, "if (s2a_ios_mouse_take) s2a_ios_mouse_take(sticks);") == 1 && count_in(vpad, "if (s2a_ios_mouse_take) s2a_ios_mouse_take(out->axes);") == 1,
              "vpad.m：s2a_vpad_read 与 s2a_vpad_read_ex 都把鼠标位移加进右摇杆（同 Mac 两个导出）");
        check(count_in(vpad, "UITouchTypeIndirectPointer") >= 1, "vpad.m：触控板右键 / 中键的点击不当手指");
        char *watch = body_of(ctl, "- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {");
        check(watch && count_in(watch, "if (t.type != UITouchTypeIndirectPointer) { finger = YES; continue; }") == 1 && count_in(watch, "if (how == 0) finger = YES;") == 1
              && count_in(watch, "s2a_vpad_pointer_touch(t, 0)") == 1, "controller.m 触摸观察：只有手指（或 mouse.m 说当手指）才算碰屏幕；当触屏时转给 vpad.m");
        free(watch);
        check(count_in(app, "prefersPointerLocked { return s2a_ios_mouse_lock_wanted(); }") == 1, "app.m：游戏页照 mouse.m 声明要不要锁定指针");
        char *cur = body_of(mouse, "static s2a_mouse_state current_state(void)"), *cfg = body_of(mouse, "void s2a_ios_mouse_config(const s2a_input_config *c, int is_default, int off)"),
             *mv = body_of(mouse, "static void moved(float dx, float dy)");
        check(cur && count_in(cur, ".off = atomic_load(&g_off)") == 1, "mouse.m：左键 / 其他键 / 能不能锁的判断都带上开关（current_state）");
        check(cfg && count_in(cfg, "atomic_store(&g_off, off != 0)") == 1 && count_in(cfg, "if (off) {") == 1 && count_in(cfg, "unlock(\"关了鼠标 / 触控板\")") == 1
              && count_in(cfg, "atomic_store(&g_counted, 0)") == 1, "mouse.m：关掉时当场释放锁定、放开按着的鼠标键");
        check(mv && count_in(mv, "atomic_load(&g_off)") == 1, "mouse.m：关掉后系统还没收回锁定的那几拍，位移也不进右摇杆");
        free(cur); free(cfg); free(mv);
        check(count_in(kbd, "s2a_ios_mouse_config(&g_map, s2a_mouse_use_default(&g_map), [s2a_ios_settings_defaults() boolForKey:S2AMouseOffKey]);") == 1,
              "keyboard.m：装键位时把这款的开关（分层读取）一起交给 mouse.m");
        char *bg = body_of(mouse, "void s2a_ios_mouse_background(void)");
        check(bg && count_in(bg, "unlock(") >= 1, "mouse.m：切后台释放锁定（同 Mac 失焦释放，回来要再点一下）");
        free(bg);
    }
    // ⑧ Apple TV：tvOS 没有指针锁定 / buttonMask，mouse.m 不编（TVOS_EXCLUDE）；controller.m / keyboard.m / app.m 调到的入口由 tv_host.m 给空实现（同 #1951 合入时补的改键页）
    char *tv = slurp(argv[7]), *mk = slurp(argv[8]);
    check(tv && mk, "读得到 tv_host.m 与 runtime/build.mk");
    if (tv && mk) {
        const char *ex = strstr(mk, "TVOS_EXCLUDE :="), *ex_end = ex ? strstr(ex, "\nIOS_SRCS") : NULL;   // 排除清单（续行到 IOS_SRCS 之前）
        const char *hit = ex ? strstr(ex, "ios/mouse.m") : NULL;
        check(hit && ex_end && hit < ex_end, "runtime/build.mk：tvOS 不编 ios/mouse.m");
        static const char *const stand_ins[] = {"void s2a_ios_mouse_attach(UIView *root)", "int s2a_ios_mouse_lock_wanted(void)", "unsigned s2a_ios_mouse_buttons(void)",
            "void s2a_ios_mouse_config(const s2a_input_config *c, int is_default, int off)", "int s2a_ios_mouse_escape(void)", "void s2a_ios_mouse_sync(void)",
            "void s2a_ios_mouse_background(void)", "int s2a_ios_mouse_pointer(long button_mask)", "void s2a_vpad_pointer_touch(UITouch *touch, int phase)"};
        int all = 1; for (size_t i = 0; i < sizeof stand_ins / sizeof *stand_ins; i++) if (count_in(tv, stand_ins[i]) != 1) { all = 0; fprintf(stderr, "  tv_host.m 缺：%s\n", stand_ins[i]); }
        check(all, "tv_host.m：电视版给 mouse.m / vpad.m 被调到的 9 个入口空实现");
        check(ctl && count_in(ctl, "#if TARGET_OS_TV\n        int how = s2a_ios_mouse_pointer(0);") == 1, "controller.m：buttonMask 只在 iOS 读（tvOS 没有）");
    }
    free(tv); free(mk);
    free(mac); free(mouse); free(kbd); free(vpad); free(ctl); free(app);

    if (failures) { fprintf(stderr, "✗ t_mouse_map：%d/%d 项不通\n", failures, checks); return 1; }
    printf("✓ t_mouse_map：%d 项（系数与左键规则同 Mac 原文、缺省、鼠标键映射、位移换算、回中 / 不回中、左键规则表、没动过鼠标的判据、关掉鼠标、接线）\n", checks);
    return 0;
}
