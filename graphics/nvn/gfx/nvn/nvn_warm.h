// 管线预热进度（S2Arm 10-30，维护者 批：首次进游戏的加载页界面归真机线，进度接口归画面线）。纯 C，不要 GPU：nvn_mtl.m 接线，graphics/nvn/tests/t_nvn_warm.c 单测。
//   加载页的「什么时候停止等待」归前端（真机 / 原生线，10-30 对齐）：nvn_mtl.m 每 50 ms 调前端实现的 s2a_front_warm_tick(done, total)，返回 1 = 现在进游戏
//   （剩下的转后台）、0 = 继续等；开始时调一次 (0, total)，整张清单编完时必调一次 (total, total)（前端据此记「本包已完整预热」）。没链前端时弱定义返回 −1，
//   用下面的护栏兜底（Mac、单测）。
//   宿主读 s2a_warm_progress（任何线程，读的是原子量和一个小环，O(1)，不碰出图线程）；玩家点「先开始玩」调 s2a_warm_play_now：剩下的清单转后台继续，
//   之后首遇的管线按现有的首遇路径（后台编、编好前这笔绘制跳过，同 #800 B 的近似顶替）。
//   预热缺省编完整张清单（去掉 10-26 的 15 秒硬上限）；护栏：长时间没有进展（DM_PSO_PREPARE_STALL_MS，缺省 20 秒）或总时长超过宽松上限
//   （DM_PSO_PREPARE_MAX_MS，缺省 30 秒；11-22 #502 起只管没有前端的宿主，有加载页前端时只由玩家「先开始玩」或前端的无进展护栏放行；0 = 不设）就交还宿主（剩下的转后台 DM_PSO_BG_THREADS 路 utility）
#pragma once
#include <stdint.h>

typedef struct {
    int phase;       // WARM_*：没有清单 / 加载页（首帧在等）/ 后台继续 / 全部完成
    int why;         // 转后台的原因 WARM_WHY_*（phase 为后台或完成时有意义）
    long total;      // 本款预热清单的行数（管线 / 着色器）
    long done;       // 已完成的行数
    double rate;     // 本机实测速率：最近 WARM_RATE_WIN_NS 内每秒完成几行（窗口内样本不足时按已有样本算，没有样本 0）
    double elapsed;  // 预热开始以来的秒数
} s2a_warm_state;
enum { WARM_NONE, WARM_FRONT, WARM_BG, WARM_DONE };
enum { WARM_WHY_NONE, WARM_WHY_PLAYER, WARM_WHY_STALL, WARM_WHY_LIMIT, WARM_WHY_CONFIG, WARM_WHY_TAIL, WARM_WHY_LATER };   // LATER（11-27）：之后的启动、前端说本包已完整预热过，首帧前不等（nvn_mtl.m warm_prepare）；TAIL（11-06）：清单都已领走、只剩在编的几条，不再挡首帧（nvn_mtl.m warm_prepare）；CONFIG：DM_PSO_PREPARE=0（11-05 起缺省开、上限 15 s；11-02–11-05 曾缺省不开）一开始就在后台

int s2a_warm_progress(s2a_warm_state *out);   // 1 = 填好；out 为空返回 0
void s2a_warm_play_now(void);                // 玩家点了「先开始玩」：加载页结束，剩下的转后台

// 加载页该不该交还宿主：优先玩家；其次长时间没进展（idle = 距上次完成数变化）；最后总时长。0 = 继续等
static inline int warm_hold_why(uint64_t el_ns, uint64_t idle_ns, int play, uint64_t lim_ns, uint64_t stall_ns) {
    if (play) return WARM_WHY_PLAYER;
    if (stall_ns && idle_ns >= stall_ns) return WARM_WHY_STALL;
    if (lim_ns && el_ns >= lim_ns) return WARM_WHY_LIMIT;
    return WARM_WHY_NONE;
}

// 速率的滑动窗口：每隔 ≥ WARM_RING_GAP_NS 记一个 (时刻, 完成数) 样本，环里留最近 WARM_RING_N 个
#define WARM_RING_N 32
#define WARM_RING_GAP_NS 100000000ull    // 0.1 秒
#define WARM_RATE_WIN_NS 2000000000ull   // 2 秒
typedef struct { uint64_t t[WARM_RING_N]; long d[WARM_RING_N]; int n, h; } warm_ring;   // h：下一个写入位置
static inline void warm_ring_add(warm_ring *r, uint64_t t, long d) {
    if (r->n) { int last = (r->h + WARM_RING_N - 1) % WARM_RING_N; if (t < r->t[last] + WARM_RING_GAP_NS) return; }
    r->t[r->h] = t; r->d[r->h] = d; r->h = (r->h + 1) % WARM_RING_N; if (r->n < WARM_RING_N) r->n++;
}
// now 时刻完成 done 行：取窗口内最早的样本，(done − 它的完成数) / 间隔秒数；窗口里没有样本时用窗口之前最新的那个；没有样本或间隔为 0 返回 0
static inline double warm_ring_rate(const warm_ring *r, uint64_t now, long done, uint64_t win_ns) {
    int best = -1;
    for (int k = 0; k < r->n; k++) {
        int i = (r->h + WARM_RING_N - r->n + k) % WARM_RING_N;   // 从最老到最新
        if (r->t[i] > now) break;
        best = i; if (now - r->t[i] <= win_ns) break;   // 第一个落进窗口的就是窗口内最早的
    }
    if (best < 0 || now <= r->t[best]) return 0;
    return (double)(done - r->d[best]) * 1e9 / (double)(now - r->t[best]);
}
