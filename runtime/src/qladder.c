// 档位梯子判定（优雅降级，维护者 11-06；维护者定判据）。纯状态机：时间、帧、GPU、热状态都由调用方喂（热状态只记进日志，不参与判定），单测 runtime/tests/t_qladder.c。
//   只跑「60 帧靠补丁」的款（原生 30 帧、有真帧率来源、玩家开着 60 帧）：两档 0 = 60 帧、1 = 压回 30 帧（#1688：原先三档的「30 帧」与「30 帧底档」效果相同，回 60 要连升两次）。
//   只看局内游戏画面帧（菜单、加载、视频、过场不算，也不打断窗口），每攒满 30 秒局内画面判一次：
//   降档：实际帧率达不到本档目标（目标不低于游戏自设交换间隔对应的帧时长；慢帧 > 5%，慢帧 = 帧间隔 > 目标 × 1.5；或帧间隔中位 > 目标 × 1.05）。只看实际帧率，不看热状态：
//     11-13 维护者「不设自己挡自己的闸」——原先热状态 3（危急）强降一档、升档要热状态 ≤ 1，都删了；真热到系统降频，帧率掉下来照常按帧率降。
//   没有 GPU 读数（gpu_ms < 0）不降也不升：判不了是不是 GPU 跟不上，照玩家选的 60 帧跑（#1688）。
//   升档：GPU 忙占比 × 2（升一档的负载按翻倍估：30 → 60 帧）< 70%，这样的窗口连续攒满 2 分钟；离上次换档至少 5 分钟。
//   升档的前提是「GPU 是瓶颈」：在 60 帧档 GPU 没跑满（< 70%，与升档预估同一条线）还达不到目标，就是 CPU 跟不上，GPU 余量说明不了升回去撑得住。
//     这样降下来的，本局不再按 GPU 余量升回（11-17 一款派对游戏 iPad：60 帧档 46–58 帧、GPU 忙 15–49%，60 / 30 每 5 分钟来回切，玩家感觉是卡）。
//   不跨局记：每局从 60 帧起（玩家开的就是 60 帧；#1688 一局掉帧记成底档、之后每局都从底档起，开关像没用）。
//   玩家点「再试 60 帧」/ 局中重开 60 帧：s2a_ql_retry 回 60 帧档，清掉 CPU 跟不上的记号。
#include "s2a_qladder.h"
#include <stdlib.h>
#include <string.h>

#define QL_WIN_NS 30000000000ull        // 判定窗口：局内画面 30 秒
#define QL_UP_NS 120000000000ull        // 升档要攒满的达标时长 2 分钟
#define QL_UP_GAP_NS 300000000000ull    // 升档离上次换档至少 5 分钟
#define QL_GAP_NS 1000000000ull         // 帧间隔 ≥ 1 秒不算（暂停 / 后台 / 断档）
#define QL_RING 8192                    // 30 秒窗口最多帧数（≥ 120 帧/秒 × 30 秒 = 3600）

static struct {
    int on, tier, why, cpu_bound, no_up;   // no_up：本局因 CPU 跟不上从 60 帧降下来过，不再按 GPU 余量升回
    uint64_t win_ns, up_ns, last_change, gpu_t0, settle_until; double gpu0;   // settle_until：回前台后到这一刻之前的帧不进窗口
    uint32_t dt_us[QL_RING]; int nd;
    double l_fps, l_slow, l_gpu; int l_th;
} q;

void s2a_ql_setup(void) { memset(&q, 0, sizeof q); q.on = 1; q.gpu0 = -1; }
int s2a_ql_tier(void) { return q.tier; }
int s2a_ql_fps60(int tier) { return tier == 0; }
int s2a_ql_why(void) { return q.why; }
int s2a_ql_cpu_bound(void) { return q.cpu_bound; }
void s2a_ql_last(double *fps, double *slow, double *gpu, int *th) { *fps = q.l_fps; *slow = q.l_slow; *gpu = q.l_gpu; *th = q.l_th; }
static int cmpu(const void *a, const void *b) { uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b; return x < y ? -1 : x > y; }
// 换到 t（why 原因），清窗口与累计
static int go(uint64_t now, int t, int why) {
    q.tier = t; q.why = why; q.last_change = now; q.cpu_bound = 0;
    q.win_ns = q.up_ns = 0; q.nd = 0; q.gpu0 = -1;
    return t;
}
// #1949：不在前台的时段整段不算（系统降速不是跑不动）；回前台后空等 S2A_QL_SETTLE_NS，窗口从那之后重新计时。前台真实掉帧照常判
void s2a_ql_away(uint64_t now) { if (!q.on) return; q.win_ns = 0; q.nd = 0; q.gpu0 = -1; q.settle_until = now + S2A_QL_SETTLE_NS; }
void s2a_ql_retry(uint64_t now) { if (!q.on) return; q.no_up = 0; go(now, 0, S2A_QL_WHY_RETRY); }
int s2a_ql_frame(uint64_t now, int game, uint64_t dt, double gpu_ms, int thermal, int game_itv) {
    if (!q.on) return -1;
    if (!game || !dt || dt >= QL_GAP_NS) return -1;
    if (now < q.settle_until) return -1;   // 刚回前台：这几秒的帧（含后台留下的慢帧）不进窗口；GPU 起点从第一帧计时帧起
    if (q.gpu0 < 0 && gpu_ms >= 0) { q.gpu0 = gpu_ms; q.gpu_t0 = now; }
    if (q.nd < QL_RING) q.dt_us[q.nd++] = (uint32_t)(dt / 1000);
    q.win_ns += dt;
    if (q.win_ns < QL_WIN_NS) return -1;
    // 判一个窗口：目标帧时长 60 帧档 16.7 ms、30 帧档 33.3 ms，都不低于游戏自设间隔对应的帧时长（11-15 v0.4.0 自测）：
    //   标题 / 过场游戏自己设间隔 2 锁 30 帧，原先 60 帧档照 16.7 ms 判「达不到」，30 秒后把帧率补丁整局关掉。游戏自己限的帧不是我们跑不动，不降
    double itv_us = 1e6 / 60 * (game_itv >= 1 ? game_itv : 1);
    double target_us = q.tier == 0 ? 1e6 / 60 : 1e6 / 30;
    if (target_us < itv_us) target_us = itv_us;
    int slow = 0; for (int i = 0; i < q.nd; i++) slow += q.dt_us[i] > target_us * 1.5;
    qsort(q.dt_us, (size_t)q.nd, sizeof q.dt_us[0], cmpu);
    double med = q.nd ? q.dt_us[q.nd / 2] : 0, slow_pct = q.nd ? 100.0 * slow / q.nd : 0;
    double gpu_pct = q.gpu0 >= 0 && gpu_ms >= q.gpu0 && now > q.gpu_t0 ? 100.0 * (gpu_ms - q.gpu0) / ((double)(now - q.gpu_t0) / 1e6) : -1;
    q.l_fps = q.win_ns ? q.nd * 1e9 / (double)q.win_ns : 0; q.l_slow = slow_pct; q.l_gpu = gpu_pct; q.l_th = thermal;
    uint64_t win = q.win_ns; q.win_ns = 0; q.nd = 0; q.gpu0 = gpu_ms >= 0 ? gpu_ms : -1; q.gpu_t0 = now;
    if (gpu_pct < 0) { q.up_ns = 0; return -1; }   // 没有 GPU 读数：不降不升
    if (slow_pct > 5.0 || med > target_us * 1.05) {
        q.up_ns = 0;
        if (q.tier == 1) return -1;
        go(now, 1, S2A_QL_WHY_FPS);
        if (gpu_pct < 70.0) q.no_up = q.cpu_bound = 1;
        return 1;
    }
    if (gpu_pct * 2 < 70.0) q.up_ns += win; else q.up_ns = 0;
    if (q.tier == 1 && !q.no_up && q.up_ns >= QL_UP_NS && now - q.last_change >= QL_UP_GAP_NS) return go(now, 0, S2A_QL_WHY_UP);
    return -1;
}
