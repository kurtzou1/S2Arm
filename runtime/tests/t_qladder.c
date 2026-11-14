// 档位梯子判定单测（runtime/src/qladder.c）：喂时间序列，期望按规则手算——
//   窗口 = 局内画面 30 秒；降档：慢帧（> 目标 × 1.5）> 5% 或中位 > 目标 × 1.05；热状态只有 3 强降；
//   升档：热 ≤ 1 且 GPU 占比 × 2 < 70% 攒满 2 分钟、离上次换档 ≥ 5 分钟（危急热降后 ≥ 10 分钟）；稳定 = 本档 2 分钟没降
#include "s2a_qladder.h"
#include <stdio.h>
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)
static double T, G;   // 当前时刻（秒）、GPU 忙累计（毫秒）
// 喂 sec 秒、每帧 ms 毫秒；game 局内画面；gpu GPU 忙占比；th 热状态；itv 游戏自设间隔。返回第一次换到的档（-1 没换），*at 换档时刻
static int feed(double sec, double ms, int game, double gpu, int th, int itv, double *at) {
    int got = -1;
    for (double end = T + sec; T < end - 1e-9; ) { T += ms / 1000; G += ms * gpu;
        int r = s2a_ql_frame((uint64_t)(T * 1e9), game, (uint64_t)(ms * 1e6), G, th, itv);
        if (r >= 0 && got < 0) { got = r; if (at) *at = T; } }
    return got;
}
static void fresh(int kind, int tier) { s2a_ql_setup(kind, tier); T = 1000; G = 0; }
int main(void) {
    double at = 0; int r;
    fresh(S2A_QL_FPS, 0);
    CHECK(s2a_ql_tiers() == 3 && s2a_ql_docked(0) && s2a_ql_fps60(0) && s2a_ql_docked(1) && !s2a_ql_fps60(1) && !s2a_ql_docked(2) && !s2a_ql_fps60(2), "三档款：主机60 / 主机30 / 掌机30");
    r = feed(110, 16.667, 1, 0.5, 0, 1, 0); CHECK(r < 0 && !s2a_ql_stable_now(), "主机60 稳 60 帧 110 秒：不换档、还没稳（2 分钟才算）");
    r = feed(15, 16.667, 1, 0.5, 0, 1, 0); CHECK(r < 0 && s2a_ql_stable_now() && !s2a_ql_stable_now(), "满 120 秒（第 4 个窗口）报稳一次、之后不重复报");
    fresh(S2A_QL_FPS, 0); r = feed(40, 33.333, 1, 0.9, 0, 1, &at);
    CHECK(r == 1 && s2a_ql_why() == S2A_QL_WHY_FPS && at - 1000 > 29.9 && at - 1000 < 30.1, "主机60 只跑出 30 帧：满一个窗口（30 秒）那一刻降到主机30（实 档 %d，第 %.2f 秒）", r, at - 1000);
    // 每 30 帧里 1 帧 33.3 ms（3.3% 慢帧）、中位 16.7：不降；每 10 帧 1 帧慢（10%）：降
    fresh(S2A_QL_FPS, 0); r = -1; for (int i = 0; i < 100 && r < 0; i++) { r = feed(0.4833, 16.667, 1, 0.5, 0, 1, 0); if (r < 0) r = feed(0.0333, 33.333, 1, 0.5, 0, 1, 0); }
    CHECK(r < 0, "慢帧约 3.3%%（每 29 帧 16.7 ms 夹 1 帧 33.3 ms）：不降（实 %d）", r);
    fresh(S2A_QL_FPS, 0); r = -1; for (int i = 0; i < 200 && r < 0; i++) { r = feed(0.15, 16.667, 1, 0.5, 0, 1, 0); if (r < 0) r = feed(0.0333, 33.333, 1, 0.5, 0, 1, 0); }
    CHECK(r == 1, "慢帧约 10%%（每 9 帧夹 1 帧 33.3 ms）：降到主机30（实 %d）", r);
    fresh(S2A_QL_FPS, 0); CHECK(feed(120, 16.667, 1, 0.9, 2, 1, 0) < 0, "热状态 2、帧率跟得上：不降（热机稳 60 是目标）");
    // 11-13 起热状态不参与判定（维护者：不设自己挡自己的闸）：危急、帧率跟得上 → 不降；升档也不看热状态
    fresh(S2A_QL_FPS, 0); CHECK(feed(120, 16.667, 1, 0.5, 3, 1, 0) < 0, "热状态 3（危急）、帧率跟得上 2 分钟：不降");
    // 升档：主机30 档、30 帧跟得上、GPU 20%（× 2 = 40% < 70%）、热 0：达标攒满 2 分钟，但离换档要 5 分钟 → 第 300 秒那个窗口升
    fresh(S2A_QL_FPS, 0); feed(30.01, 33.333, 1, 0.2, 0, 1, &at); double t0 = at;
    r = feed(320, 33.333, 1, 0.2, 0, 1, &at); CHECK(r == 0 && s2a_ql_why() == S2A_QL_WHY_UP && at - t0 > 299 && at - t0 < 301, "主机30 余量足：离换档 5 分钟那个窗口升回主机60（实 %d，换档后 %.1f 秒）", r, at - t0);
    fresh(S2A_QL_FPS, 1); CHECK(feed(600, 33.333, 1, 0.4, 0, 1, 0) < 0, "主机30、GPU 40%%（× 2 = 80%% ≥ 70%%）：10 分钟不升");
    fresh(S2A_QL_FPS, 1); r = feed(600, 33.333, 1, 0.2, 3, 1, &at); CHECK(r == 0 && at - 1000 > 120.1 && at - 1000 < 120.2, "主机30、热状态 3、GPU 20%%：余量够满 2 分钟（第 4 个窗口，每窗 901 帧 × 33.333 ms = 30.033 秒，4 窗 120.13 秒）就升，不看热状态（实 %d，第 %.2f 秒）", r, at - 1000);
    fresh(S2A_QL_FPS, 0); CHECK(feed(120, 33.333, 0, 0.9, 0, 1, 0) < 0, "菜单 / 加载（非局内画面）30 帧 2 分钟：不降");
    fresh(S2A_QL_FPS, 2); CHECK(feed(120, 50, 1, 0.9, 0, 1, 0) < 0, "最低档（掌机30）跟不上：没处可降，不换");
    fresh(S2A_QL_MODE, 0);
    CHECK(s2a_ql_tiers() == 2 && s2a_ql_docked(0) && !s2a_ql_docked(1) && !s2a_ql_fps60(0), "两档款：主机 / 掌机，帧率归游戏");
    CHECK(feed(120, 33.333, 1, 0.5, 0, 2, 0) < 0, "原生 30 帧（游戏间隔 2）跑 30 帧：跟得上，不降");
    r = feed(40, 50, 1, 0.9, 0, 2, 0); CHECK(r == 1, "原生 30 帧只跑出 20 帧：降到掌机（实 %d）", r);
    fresh(S2A_QL_MODE, 0); CHECK(feed(40, 33.333, 1, 0.9, 0, 1, 0) == 1, "原生 60 帧（间隔 1）只跑出 30：降到掌机");
    // #352 运行模式上限：玩家选掌机（iPhone 缺省）时梯子不自己升到主机；没有上限的同一段喂数会升（对照）
    CHECK(s2a_ql_top_tier(S2A_QL_FPS, 1) == 0 && s2a_ql_top_tier(S2A_QL_MODE, 1) == 0 && s2a_ql_top_tier(S2A_QL_FPS, 0) == 2 && s2a_ql_top_tier(S2A_QL_MODE, 0) == 1,
          "上限对应的档：主机 0；掌机 三档款 2、两档款 1");
    fresh(S2A_QL_MODE, 1); CHECK(feed(600, 16.667, 1, 0.2, 0, 1, 0) == 0, "对照：两档款在掌机、余量足（GPU 20%%）、没上限：10 分钟内升回主机");
    fresh(S2A_QL_MODE, 1); s2a_ql_top(1); CHECK(feed(600, 16.667, 1, 0.2, 0, 1, 0) < 0 && s2a_ql_tier() == 1, "两档款上限掌机：同样余量 10 分钟不升（停在掌机）");
    fresh(S2A_QL_FPS, 0); s2a_ql_top(2); CHECK(s2a_ql_tier() == 2, "三档款记下的主机60、上限掌机：拉到掌机30（实 %d）", s2a_ql_tier());
    CHECK(feed(600, 33.333, 1, 0.2, 0, 1, 0) < 0 && s2a_ql_tier() == 2, "三档款上限掌机：余量足 10 分钟不升");
    fresh(S2A_QL_FPS, 2); s2a_ql_top(0); r = feed(320, 33.333, 1, 0.2, 0, 1, 0); CHECK(r == 1, "上限主机（Mac / 玩家开了主机）：照旧升档（实 %d）", r);
    // 梯子压 / 放 60 帧时要不要告诉玩家（审计 P1-80 原因 4）：期望按「起局不说、没变不说、没开 60 帧 / 自动化局不说、压了说 4、放开说 0」手推
    { struct { int boot, last, hold, on, un, want; const char *why; } c[] = {
        {1, -1, 1, 1, 0, -1, "起局按记下的档压回：不说（每次开游戏都弹是噪音）"},
        {0, -1, 1, 1, 0, -1, "还没摆过档（last = -1）：不说"},
        {0, 0, 1, 1, 0, 4, "局中从 60 帧压回原帧率：说原因 4"},
        {0, 1, 0, 1, 0, 0, "局中放开回 60 帧：说已恢复"},
        {0, 1, 1, 1, 0, -1, "压着没变：不说"},
        {0, 0, 1, 0, 0, -1, "玩家没开 60 帧：不说"},
        {0, 0, 1, 1, 1, -1, "自动化局：不说"} };
      for (unsigned i = 0; i < sizeof c / sizeof *c; i++) { int got = s2a_ql_fps_note(c[i].boot, c[i].last, c[i].hold, c[i].on, c[i].un), ok = got == c[i].want;
        bad += !ok; printf("%s 提示 %s：期望 %d → 实 %d\n", ok ? "✓" : "✗", c[i].why, c[i].want, got); } }
    printf("%s t_qladder：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
