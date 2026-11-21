/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */
#include "system_tuning.h"
#include <stdatomic.h>

static _Atomic int battery_limit;
static _Atomic uint64_t present_ns;

void s2a_android_set_battery_limit(int enabled) { atomic_store(&battery_limit, !!enabled); }
int s2a_android_battery_limit(void) { return atomic_load(&battery_limit); }
uint64_t s2a_android_limit_frame_period(uint64_t period_ns) {
    const uint64_t min_ns = 33333334ull;  // ceil(1 second / 30), applied to the final period
    return s2a_android_battery_limit() && period_ns < min_ns ? min_ns : period_ns;
}

// 本局最短周期（参照 BananaNative vka_dev.c vka_floor_period_ns）：登记值只降不升，开局 / 停局清零。
static _Atomic uint64_t session_min_ns;

void s2a_android_present_note(uint64_t period_ns) {
    atomic_store(&present_ns, period_ns);
    if (!period_ns) return;
    uint64_t m = atomic_load(&session_min_ns);
    while ((!m || period_ns < m) && !atomic_compare_exchange_weak(&session_min_ns, &m, period_ns)) {}
}
uint64_t s2a_android_present_ns(void) { return atomic_load(&present_ns); }
void s2a_android_session_period_reset(void) { atomic_store(&session_min_ns, 0); }
uint64_t s2a_android_session_period_ns(void) {
    uint64_t m = atomic_load(&session_min_ns);
    if (!m || !atomic_load(&present_ns)) return 0;   // 当前登记 0（无上限路径）：同原先一样没有判据
    if (m < S2A_ANDROID_PERIOD_FLOOR_NS) m = S2A_ANDROID_PERIOD_FLOOR_NS;
    return s2a_android_limit_frame_period(m);   // 省电档开着时仍按 30 帧判，不因开档前记下的 16.7 ms 去托底
}
