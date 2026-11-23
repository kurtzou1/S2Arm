// 远端「真的慢」判据（Mac 的「地址空间不够这款」提示条按它出，far.c 逐秒账调；纯函数，单测 runtime/tests/t_far_slow.c）：
//   每秒缺页代执行次数 ≥ S2A_FAR_SLOW_PER_SEC 连续 S2A_FAR_SLOW_SECS 秒才算——每次代执行约 5–10 µs（起局自测 5.5 µs），2 万次 / 秒 ≈ 每秒 0.1–0.2 秒花在缺页上，玩家看得出卡。
//   开局一阵（11-22 一款格斗游戏：第 1 秒 2368 次、之后 0 次）不算：那是 SDK 初始化碰一下伸出段，玩家感觉不到
#pragma once
#include <stdint.h>
#define S2A_FAR_SLOW_PER_SEC 20000ull
#define S2A_FAR_SLOW_SECS 3
// 喂这一秒的缺页数，*streak 是连续达标的秒数（调用方持有，初值 0）；连续达标刚好满 S2A_FAR_SLOW_SECS 秒的那一次回 1，其余回 0（只报一次由调用方管）
static inline int s2a_far_slow_step(int *streak, uint64_t per_sec) {
    *streak = per_sec >= S2A_FAR_SLOW_PER_SEC ? *streak + 1 : 0;
    return *streak == S2A_FAR_SLOW_SECS;
}
