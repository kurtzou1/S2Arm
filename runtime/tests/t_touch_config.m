// 游戏声明触屏配置 → 自动切仅触屏（ios/touch_config.m；11-04 维护者定，脑锻炼标题页只认触屏）。桩掉 vpad.m 的切方案入口、提示条、上屏帧数，期望手写：
//   ① 首帧前服务层递模式：返回 0（下一拍再递），不切
//   ② 首帧后递模式 2：返回 1；跑一圈主线程后切方案入口被调 1 次、参数 (on 1, manual 0, "游戏声明触屏配置")；切了（1）→ 提示 1 次，文案（手写）指左上角齿轮 → 显示按键（齿轮菜单第一项）
//   ③ 玩家手动选过（切方案入口回 0）：入口照调，不提示
//   ④ 切方案失败（回 -1）：不提示
//   ⑤ 无人值守局（S2A_AUTOPLAY=1）：照切，不提示
#import <Foundation/Foundation.h>
#include <stdlib.h>
#import "../../ios/touch_config.m"
static uint64_t g_frames; static int g_set_calls, g_set_on = -9, g_set_manual = -9, g_set_ret, g_notices; static char g_why[64];
uint64_t s2a_ap_frames(void) { return g_frames; }
int s2a_vpad_set_touch_only(int on, int manual, const char *why) {
    g_set_calls++; g_set_on = on; g_set_manual = manual; snprintf(g_why, sizeof g_why, "%s", why ? why : ""); return g_set_ret;
}
static NSString *g_body;
void s2a_dprompt_notice(NSString *title, NSString *body, double delay, double seconds) { (void)title; (void)delay; (void)seconds; g_body = body; g_notices++; }
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
static void spin(void) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]; }
int main(void) { @autoreleasepool {
    unsetenv("S2A_AUTOPLAY");
    int r = s2a_vpad_touch_configured(2); spin();
    CK(r == 0 && g_set_calls == 0, "① 首帧前：返回 0、不切（实得 %d、切 %d 次）", r, g_set_calls);
    g_frames = 1; g_set_ret = 1;
    r = s2a_vpad_touch_configured(2); spin();
    CK(r == 1 && g_set_calls == 1 && g_set_on == 1 && g_set_manual == 0 && !strcmp(g_why, "游戏声明触屏配置") && g_notices == 1
       && [g_body isEqualToString:@"已切到触屏操作：这款游戏用触屏点菜单。左上角齿轮 → 显示按键，可以切回按键。"],
       "② 首帧后：返回 1、切 1 次 (1, 0, 游戏声明触屏配置)、提示 1 次、文案指齿轮 → 显示按键（实得 %d、%d 次 (%d, %d, %s)、提示 %d「%s」）", r, g_set_calls, g_set_on, g_set_manual, g_why, g_notices, g_body.UTF8String);
    g_set_ret = 0; g_notices = 0;
    r = s2a_touchcfg_apply(2);
    CK(r == 0 && g_set_calls == 2 && g_notices == 0, "③ 玩家手动选过：入口照调（第 2 次）、回 0、不提示（实得 %d、%d 次、提示 %d）", r, g_set_calls, g_notices);
    g_set_ret = -1;
    r = s2a_touchcfg_apply(2);
    CK(r == -1 && g_notices == 0, "④ 切方案失败：回 -1、不提示（实得 %d、提示 %d）", r, g_notices);
    setenv("S2A_AUTOPLAY", "1", 1); g_set_ret = 1;
    r = s2a_touchcfg_apply(2);
    CK(r == 1 && g_notices == 0, "⑤ 无人值守：照切（回 1）、不提示（实得 %d、提示 %d）", r, g_notices);
    printf(bad ? "✗ t_touch_config：%d 项不符\n" : "✓ t_touch_config：全过\n", bad);
    return bad != 0;
} }
