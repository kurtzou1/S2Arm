// 档位梯子（优雅降级，维护者 11-06：「主机60帧、主机30帧、掌机30帧……有些游戏原生就是60帧，那就是两档。这个要跟游戏本身适配」）：
//   判定在 runtime/src/qladder.c（纯状态机，单测 runtime/tests/t_qladder.c 喂时间序列），宿主接线在 runtime/src/qladder_host.c。
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// 梯子种类（运行时按游戏生成，不查按款表）：
//   S2A_QL_FPS  有 60 帧来源（帧率表 / 社区补丁）的原生 30 帧款：0 主机60 → 1 主机30 → 2 掌机30
//   S2A_QL_MODE 没有可切的帧率来源（原生 60 帧，或原生 30 帧没补丁）：0 主机 → 1 掌机，帧率跟游戏自己
enum { S2A_QL_FPS = 1, S2A_QL_MODE = 2 };
// 换档原因
enum { S2A_QL_WHY_NONE = 0, S2A_QL_WHY_FPS = 1, S2A_QL_WHY_UP = 3 };   // 2（热状态危急强降）11-13 删：梯子只看实际帧率
void s2a_ql_setup(int kind, int tier);   // 换局：种类与起始档（0 = 最高档）
// 最高可到的档（setup 之后调）：玩家选的运行模式是上限（#352，维护者 11-09：手机缺省掌机、玩家可自己开主机），梯子只在它之下降档、回升也不越过它；
//   当前档高于上限的拉到上限。setup 缺省上限 0（最高档）
void s2a_ql_top(int top);
int s2a_ql_top_tier(int kind, int docked);   // 这种梯子里「主机 / 掌机」上限对应的档：主机 0；掌机 = 最高的掌机档（三档款 2，两档款 1）
int s2a_ql_tiers(void);                  // 这把梯子几档（3 / 2）
int s2a_ql_tier(void);                   // 当前档
int s2a_ql_docked(int tier);             // 这一档是不是主机档
int s2a_ql_fps60(int tier);              // 这一档 60 帧补丁开不开（S2A_QL_MODE 恒 0：帧率归游戏自己）
// 每次上屏调一次：now 纳秒；game = 这一帧是局内游戏画面（菜单 / 加载 / 视频 / 过场不算，s2a_qp_game）；dt = 与上一帧的间隔纳秒；
//   gpu_ms = GPU 忙累计毫秒（s2a_gpu_busy_ms，< 0 = 没有读数）；thermal = 热状态 0 正常 / 1 一般 / 2 严重 / 3 危急（-1 = 没有读数）；
//   game_itv = 游戏自己设的交换间隔（S2A_QL_MODE 的目标帧时长 = itv × 1/60 秒）。
//   返回 -1 = 不换档；否则返回新档（调用方去切），s2a_ql_why() 说原因
int s2a_ql_frame(uint64_t now, int game, uint64_t dt, double gpu_ms, int thermal, int game_itv);
int s2a_ql_why(void);
// 这一档已经稳了（在本档连续 2 分钟局内画面没触发降档）：调用方据此把它记成「最后稳定档」；每次进新档后第一次稳住返回 1，之后返回 0
int s2a_ql_stable_now(void);
// 最近一次判定窗口的读数（换档日志用）
void s2a_ql_last(double *fps, double *slow_pct, double *gpu_pct, int *thermal);
// 梯子换档压回 / 放开 60 帧时要不要告诉玩家（审计 P1-80 原因 4：原先梯子压帧不弹横幅，60 帧开关显示开着、画面已回原帧率，玩家不知道为什么）：
//   回 4 = 「本机暂时跑不稳 60 帧，已回原帧率」，0 = 「60 帧恢复」，-1 = 不说。起局按上次稳定档摆好那一下不说（每次开游戏都弹就成了噪音）、
//   压没变不说、玩家没开 60 帧不说（同热 / 低电量降档）、自动化局只记日志
static inline int s2a_ql_fps_note(int boot, int last_hold, int hold, int fps_on, int unattended) {
    if (boot || last_hold < 0 || hold == last_hold || !fps_on || unattended) return -1;
    return hold ? 4 : 0;
}
#ifdef __cplusplus
}
#endif
