// 档位梯子（优雅降级，维护者 11-06）：60 帧靠补丁的款跑不稳 60 帧时自动压回 30 帧，余量够了再放开。
//   判定在 runtime/src/qladder.c（纯状态机，单测 runtime/tests/t_qladder.c 喂时间序列），宿主接线在 runtime/src/qladder_host.c。
//   两档：0 = 60 帧（补丁放开）、1 = 压回 30 帧。不跨局记，每局从 60 帧起（#1688）。
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// 换档原因
enum { S2A_QL_WHY_NONE = 0, S2A_QL_WHY_FPS = 1, S2A_QL_WHY_UP = 3, S2A_QL_WHY_RETRY = 4 };   // 2（热状态危急强降）11-13 删：梯子只看实际帧率；4 = 玩家点「再试 60 帧」
void s2a_ql_setup(void);                 // 开局：从 60 帧档起
int s2a_ql_tier(void);                   // 当前档
int s2a_ql_fps60(int tier);              // 这一档 60 帧补丁开不开
// 每次上屏调一次：now 纳秒；game = 这一帧是局内游戏画面（菜单 / 加载 / 视频 / 过场不算，s2a_qp_game）；dt = 与上一帧的间隔纳秒；
//   gpu_ms = GPU 忙累计毫秒（s2a_gpu_busy_ms，< 0 = 没有读数：不降不升）；thermal = 热状态 0 正常 / 1 一般 / 2 严重 / 3 危急（-1 = 没有读数，只记日志）；
//   game_itv = 游戏自己设的交换间隔（目标帧时长不低于 itv × 1/60 秒）。
//   返回 -1 = 不换档；否则返回新档（调用方去切），s2a_ql_why() 说原因
int s2a_ql_frame(uint64_t now, int game, uint64_t dt, double gpu_ms, int thermal, int game_itv);
int s2a_ql_why(void);
// 刚才那次降档是 CPU 跟不上（GPU 没跑满仍达不到目标）：本局不再按 GPU 余量升回 60 帧（换档日志用）
int s2a_ql_cpu_bound(void);
// 玩家点「再试 60 帧」/ 局中重开 60 帧：回 60 帧档、清掉 CPU 跟不上的记号（没 setup 过不动）
void s2a_ql_retry(uint64_t now);
// 窗口不在前台（#1949：Mac 失焦 / 睡眠时系统给游戏降速，采样窗口里帧率掉下来就把 60 帧压成 30 帧、还记成 CPU 跟不上整局不升回）：
//   丢掉正在攒的窗口与 GPU 起点，回到前台后再空等 S2A_QL_SETTLE_NS 才重新计时；宿主侧每帧在失焦 / 睡眠时调
#define S2A_QL_SETTLE_NS 3000000000ull
void s2a_ql_away(uint64_t now);
// 最近一次判定窗口的读数（换档日志用）
void s2a_ql_last(double *fps, double *slow_pct, double *gpu_pct, int *thermal);
// 梯子换档压回 / 放开 60 帧时要不要告诉玩家（审计 P1-80 原因 4：原先梯子压帧不弹横幅，60 帧开关显示开着、画面已回原帧率，玩家不知道为什么）：
//   回 4 = 「这一局跑不稳 60 帧，已回原帧率」（带「再试 60 帧」按钮），0 = 「60 帧恢复」，-1 = 不说。起局摆档那一下不说、
//   压没变不说、玩家没开 60 帧不说、自动化局只记日志
static inline int s2a_ql_fps_note(int boot, int last_hold, int hold, int fps_on, int unattended) {
    if (boot || last_hold < 0 || hold == last_hold || !fps_on || unattended) return -1;
    return hold ? 4 : 0;
}
#ifdef __cplusplus
}
#endif
