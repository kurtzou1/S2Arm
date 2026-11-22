// #276 实体手柄按住 Home 退出的决策表（runtime/include/s2a_home_quit.h），期望按头文件注释手写；再对 front_mac.m 做接线断言
#include "../include/s2a_home_quit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int failures, checks;
static void check(int ok, const char *what) { checks++; if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); } }
#define S 1000000000ull
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "用法：t_home_quit <front_mac.m>\n"); return 2; }
    s2a_hq_state s = {0};
    // 按住 Home 1.9 秒不弹，满 2 秒弹
    check(s2a_hq_step(&s, 10 * S, true, true, false, false) == S2A_HQ_NONE, "按下当帧不弹");
    check(s2a_hq_step(&s, 10 * S + 19 * S / 10, true, true, false, false) == S2A_HQ_NONE, "1.9 秒不弹");
    check(s2a_hq_step(&s, 12 * S, true, true, false, false) == S2A_HQ_OPEN && s.open, "满 2 秒弹确认");
    // 弹出后 Home 还按着、再松开：不算「再按 Home 取消」
    check(s2a_hq_step(&s, 12 * S + 1, true, true, false, false) == S2A_HQ_NONE, "弹出后 Home 仍按着不取消");
    check(s2a_hq_step(&s, 13 * S, false, false, false, false) == S2A_HQ_NONE && s.open, "松开 Home 确认还开着");
    // 按 A 退出
    check(s2a_hq_step(&s, 14 * S, false, false, true, false) == S2A_HQ_QUIT && !s.open, "按 A 退出");
    // 中途松手重新计时
    s = (s2a_hq_state){0};
    s2a_hq_step(&s, 1 * S, true, true, false, false); s2a_hq_step(&s, 2 * S, false, false, false, false);
    check(s2a_hq_step(&s, 3 * S + S / 2, true, true, false, false) == S2A_HQ_NONE, "松手后重新计时（1.5 秒前的不算）");
    check(s2a_hq_step(&s, 5 * S + S / 2, true, true, false, false) == S2A_HQ_OPEN, "重新按满 2 秒才弹");
    // B 取消、Home 再按取消、30 秒超时取消
    s2a_hq_step(&s, 6 * S, false, false, false, false);
    check(s2a_hq_step(&s, 7 * S, false, false, false, true) == S2A_HQ_CANCEL && !s.open, "按 B 取消");
    s = (s2a_hq_state){0}; s2a_hq_step(&s, 1 * S, true, true, false, false); s2a_hq_step(&s, 3 * S, true, true, false, false);
    s2a_hq_step(&s, 4 * S, false, false, false, false);
    check(s2a_hq_step(&s, 5 * S, true, true, false, false) == S2A_HQ_CANCEL, "确认开着再按 Home 取消");
    s = (s2a_hq_state){0}; s2a_hq_step(&s, 1 * S, true, true, false, false); s2a_hq_step(&s, 3 * S, true, true, false, false);
    s2a_hq_step(&s, 4 * S, false, false, false, false);
    check(s2a_hq_step(&s, 32 * S, false, false, false, false) == S2A_HQ_NONE, "3 秒弹出、32 秒（29 秒）还不收");
    check(s2a_hq_step(&s, 33 * S, false, false, false, false) == S2A_HQ_CANCEL, "满 30 秒没理会自动取消");
    // 没开确认时按 A / B 什么都不做（游戏照常收）
    s = (s2a_hq_state){0};
    check(s2a_hq_step(&s, 1 * S, false, false, true, true) == S2A_HQ_NONE, "平时按 A / B 不触发");
    // 「+」「-」同按（trigger 真、Home 假）也能弹
    check(s2a_hq_step(&s, 2 * S, true, false, false, false) == S2A_HQ_NONE && s2a_hq_step(&s, 4 * S, true, false, false, false) == S2A_HQ_OPEN, "+ - 同按 2 秒也弹");
    // 接线：front_mac.m 读 buttonHome、退出走 shutdown（同 ⌘Q）、确认期间不发布手柄输入
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f); char *t = malloc(n + 1); fread(t, 1, n, f); t[n] = 0; fclose(f);
    check(strstr(t, "pad.buttonHome") != NULL, "front_mac.m 读手柄 Home");
    check(strstr(t, "s2a_hq_step(") != NULL, "front_mac.m 用 s2a_hq_step 决策");
    check(strstr(t, "case S2A_HQ_QUIT: [g_delegate shutdown]") != NULL, "A 退出走 shutdown（同 ⌘Q / 关窗）");
    // 本地多手柄（#282）后按槽位采样：确认条开着 = muted（手柄这一路看 pads_live，关了失焦暂停时失焦不静音手柄；键鼠 kbd_muted 照旧看焦点），各槽清零，再由同一处 publish_input 发出（旧 ABI 与 pad.c 两份状态都发 0），多手柄槽位也是 0
    check(strstr(t, "BOOL muted = !pads_live() || g_hq.open, kbd_muted = !focused || g_hq.open;") != NULL && strstr(t, "memset(slot_buttons, 0, sizeof slot_buttons)") != NULL &&
          strstr(t, "publish_input(slot_buttons[0], slot_sticks[0]);") != NULL, "确认期间游戏不收手柄输入（旧 ABI、pad.c 与多手柄槽位都发 0）");
    if (failures) { fprintf(stderr, "t_home_quit：%d/%d 项不符\n", failures, checks); return 1; }
    printf("✓ t_home_quit：%d 项（按住 2 秒弹、松手重计、A 退出、B / Home / 30 秒取消、+ - 同按、接线）\n", checks);
    return 0;
}
