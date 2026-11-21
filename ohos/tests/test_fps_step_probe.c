// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Host-only regression for the opt-in low-FPS A/B probe. No game data.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define S2A_OHOS_FPS_CORE_TEST 1
#include "../native/fps_ohos.c"

static _Alignas(8) unsigned char memory[32768];
static float step(void) {
    float value;
    memcpy(&value, memory + 16384 + 2040 * 8, sizeof value);
    return value;
}
int main(void) {
    const char *table =
        "abi s2a.ohos.fps.v1\nbuild 1234567890abcdef1234567890abcdef\n"
        "target 60\npresent display\nc main 0x0 word d503201f d503201f\n"
        "speed 2040 0.5 2.0\nslot 2042 i32 1\n"
        "present30 if slot 2042 == 0\n";
    s2a_ohos_fps_module module = {"main", memory, sizeof memory, 0, 16384, 16384, 16384};
    assert(s2a_ohos_fps_prepare_text(table, strlen(table),
           "1234567890abcdef1234567890abcdef", &module, 1) == 0);
    assert(s2a_ohos_fps_activate() == 0);
    assert(s2a_ohos_fps_present_at(1000000000) == 60);
    // Observed device cadence is ~250ms: unchanged default saturates at 2.
    assert(s2a_ohos_fps_present_at(1250000000) == 60);
    assert(step() == 2.0f);
    state.diagnostic_step_cap = 1.0f;
    assert(s2a_ohos_fps_present_at(1500000000) == 60);
    assert(step() == 1.0f);
    // Normal fast cadence retains the table floor, not the cap value.
    s2a_ohos_fps_present_at(1510000000);
    assert(step() == 0.5f);
    *state.slot_ptr[state.condition_slot] = 0;
    assert(s2a_ohos_fps_present_at(1760000000) == 30);
    assert(step() == 1.0f);
    s2a_ohos_fps_clear();
    assert(state.diagnostic_step_cap == 0);
    assert(s2a_ohos_fps_present_at(2000000000) == 0);
    puts("PASS: default 4fps cadence, diagnostic cap, fast cadence, cutscene gate, reset");
    return 0;
}
