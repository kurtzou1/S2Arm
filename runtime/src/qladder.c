// 档位梯子判定（优雅降级，维护者 11-06；维护者定判据）。纯状态机：时间、帧、GPU、热状态都由调用方喂（热状态只记进日志，不参与判定），单测 runtime/tests/t_qladder.c。
//   只看局内游戏画面帧（菜单、加载、视频、过场不算，也不打断窗口），每攒满 30 秒局内画面判一次：
//   降档：实际帧率达不到本档目标（慢帧 > 5%，慢帧 = 帧间隔 > 目标 × 1.5；或帧间隔中位 > 目标 × 1.05）。只看实际帧率，不看热状态：
//     11-13 维护者「不设自己挡自己的闸」——原先热状态 3（危急）强降一档、升档要热状态 ≤ 1，都删了；真热到系统降频，帧率掉下来照常按帧率降。
//   升档：GPU 忙占比 × 2（升一档的负载按翻倍估：30 → 60 帧、掌机 → 主机分辨率）< 70%，这样的窗口连续攒满 2 分钟；离上次换档至少 5 分钟。
//   稳定：进一档后连续 2 分钟局内画面没触发降档 = 这一档稳了（调用方记成最后稳定档，下次从这起）。
//   上限（s2a_ql_top）：玩家选的运行模式，升档到它为止（#352）。
#include "s2a_qladder.h"
#include <stdlib.h>
#include <string.h>

#define QL_WIN_NS 30000000000ull        // 判定窗口：局内画面 30 秒
#define QL_UP_NS 120000000000ull        // 升档要攒满的达标时长 2 分钟
#define QL_STABLE_NS 120000000000ull    // 稳定判定 2 分钟
#define QL_UP_GAP_NS 300000000000ull    // 升档离上次换档至少 5 分钟
#define QL_GAP_NS 1000000000ull         // 帧间隔 ≥ 1 秒不算（暂停 / 后台 / 断档）
#define QL_RING 8192                    // 30 秒窗口最多帧数（≥ 120 帧/秒 × 30 秒 = 3600）

static struct {
    int kind, n, tier, why, stable_said, top;
    uint64_t win_ns, up_ns, stable_ns, last_change, gpu_t0; double gpu0;
    uint32_t dt_us[QL_RING]; int nd;
    double l_fps, l_slow, l_gpu; int l_th;
} q;

void s2a_ql_setup(int kind, int tier) {
    memset(&q, 0, sizeof q); q.kind = kind == S2A_QL_FPS ? S2A_QL_FPS : S2A_QL_MODE; q.n = q.kind == S2A_QL_FPS ? 3 : 2;
    q.tier = tier < 0 ? 0 : tier >= q.n ? q.n - 1 : tier; q.gpu0 = -1;
}
void s2a_ql_top(int top) { q.top = top < 0 ? 0 : top >= q.n ? q.n - 1 : top; if (q.tier < q.top) q.tier = q.top; }
int s2a_ql_top_tier(int kind, int docked) { return docked ? 0 : kind == S2A_QL_FPS ? 2 : 1; }
int s2a_ql_tiers(void) { return q.n; }
int s2a_ql_tier(void) { return q.tier; }
int s2a_ql_docked(int tier) { return q.kind == S2A_QL_FPS ? tier < 2 : tier == 0; }
int s2a_ql_fps60(int tier) { return q.kind == S2A_QL_FPS && tier == 0; }
int s2a_ql_why(void) { return q.why; }
int s2a_ql_stable_now(void) { if (q.stable_said == 1) { q.stable_said = 2; return 1; } return 0; }
void s2a_ql_last(double *fps, double *slow, double *gpu, int *th) { *fps = q.l_fps; *slow = q.l_slow; *gpu = q.l_gpu; *th = q.l_th; }
static int cmpu(const void *a, const void *b) { uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b; return x < y ? -1 : x > y; }
// 换到 t（why 原因），清窗口与累计
static int go(uint64_t now, int t, int why) {
    q.tier = t; q.why = why; q.last_change = now;
    q.win_ns = q.up_ns = q.stable_ns = 0; q.nd = 0; q.stable_said = 0; q.gpu0 = -1;
    return t;
}
int s2a_ql_frame(uint64_t now, int game, uint64_t dt, double gpu_ms, int thermal, int game_itv) {
    if (!q.n) return -1;
    if (!game || !dt || dt >= QL_GAP_NS) return -1;
    if (q.gpu0 < 0 && gpu_ms >= 0) { q.gpu0 = gpu_ms; q.gpu_t0 = now; }
    if (q.nd < QL_RING) q.dt_us[q.nd++] = (uint32_t)(dt / 1000);
    q.win_ns += dt;
    if (q.win_ns < QL_WIN_NS) return -1;
    // 判一个窗口：目标帧时长（60 帧档 16.7 ms；30 帧档 33.3 ms；帧率归游戏的梯子按游戏自设交换间隔）
    double target_us = q.kind == S2A_QL_FPS ? (q.tier == 0 ? 1e6 / 60 : 1e6 / 30) : 1e6 / 60 * (game_itv >= 1 ? game_itv : 1);
    int slow = 0; for (int i = 0; i < q.nd; i++) slow += q.dt_us[i] > target_us * 1.5;
    qsort(q.dt_us, (size_t)q.nd, sizeof q.dt_us[0], cmpu);
    double med = q.nd ? q.dt_us[q.nd / 2] : 0, slow_pct = q.nd ? 100.0 * slow / q.nd : 0;
    double gpu_pct = q.gpu0 >= 0 && gpu_ms >= q.gpu0 && now > q.gpu_t0 ? 100.0 * (gpu_ms - q.gpu0) / ((double)(now - q.gpu_t0) / 1e6) : -1;
    q.l_fps = q.win_ns ? q.nd * 1e9 / (double)q.win_ns : 0; q.l_slow = slow_pct; q.l_gpu = gpu_pct; q.l_th = thermal;
    uint64_t win = q.win_ns; q.win_ns = 0; q.nd = 0; q.gpu0 = gpu_ms >= 0 ? gpu_ms : -1; q.gpu_t0 = now;
    if (slow_pct > 5.0 || med > target_us * 1.05) { q.stable_ns = 0; q.up_ns = 0; return q.tier < q.n - 1 ? go(now, q.tier + 1, S2A_QL_WHY_FPS) : -1; }
    q.stable_ns += win; if (q.stable_ns >= QL_STABLE_NS && !q.stable_said) q.stable_said = 1;
    if (gpu_pct >= 0 && gpu_pct * 2 < 70.0) q.up_ns += win; else q.up_ns = 0;
    if (q.tier > q.top && q.up_ns >= QL_UP_NS && (!q.last_change || now - q.last_change >= QL_UP_GAP_NS)) return go(now, q.tier - 1, S2A_QL_WHY_UP);
    return -1;
}
