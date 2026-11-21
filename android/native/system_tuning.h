/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// A4（#48）：系统游戏模式 = 省电档时直连 present 周期取 max(原周期, 33.3 ms)。
// Java 轮询 GameManager.getGameMode() 后经 NativeBridge.setBatteryCap 写；直连 present_period 每帧读。
void s2a_android_set_battery_limit(int enabled);
int s2a_android_battery_limit(void);
uint64_t s2a_android_limit_frame_period(uint64_t period_ns);

// A3（#48）：直连 present_period 每帧登记最终周期，Java 轮询后经 Surface.setFrameRate 投显示刷新率。
// 0 = 还没上过屏 / 无上限路径。
void s2a_android_present_note(uint64_t period_ns);
uint64_t s2a_android_present_ns(void);

// 本局最短周期：本局游戏登记过的最短 present 周期，不短于 60 帧（16,666,667 ns），再按省电档取上限；0 = 本局还没登记，或当前登记的是 0（无上限路径）。
// 动态间隔的游戏掉到 30 / 20 帧后「实际帧率 = 当前周期」，按当前周期判永远不慢；托底判定与 ADPF 目标改对本局最短周期比，
// 时钟才留在游戏能升回去的位置。开局（createGame）与停局（stopGame）清零。
#define S2A_ANDROID_PERIOD_FLOOR_NS 16666667ull
void s2a_android_session_period_reset(void);
uint64_t s2a_android_session_period_ns(void);

#ifdef __cplusplus
}
#endif
