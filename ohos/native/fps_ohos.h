// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Explicit build-pinned tables only. No table means the original frame policy.
// Call start after module mapping/relocation, before module initializers. Failure
// must abort launch: signed code requiring a table cannot safely run without it.
int s2a_ohos_fps_start(const char *module_directory);
// Call exactly once at each guest present boundary, using a monotonic timestamp.
// Result: 0 = unchanged policy; 30 = cinematic; 60 = display target. This value
// does not claim the renderer is achieving that frame rate.
unsigned s2a_ohos_fps_present_at(uint64_t monotonic_ns);
unsigned s2a_ohos_fps_present_hook(void);
void s2a_ohos_fps_reset_clock(void);
unsigned s2a_ohos_fps_abi_v1(void);

// The same bounded core is exercised on the CPU without loading/playing a game.
typedef struct {
    const char *name;
    unsigned char *base;
    size_t size, data_offset, data_end, key_offset, key_size;
} s2a_ohos_fps_module;
int s2a_ohos_fps_prepare_text(const char *text, size_t length, const char *build_id,
                            const s2a_ohos_fps_module *modules, size_t count);
int s2a_ohos_fps_activate(void);
void s2a_ohos_fps_clear(void);
void s2a_ohos_fps_digest(const void *data, size_t size, char out[65]);
#ifdef __cplusplus
}
#endif
