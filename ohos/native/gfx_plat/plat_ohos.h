// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// Private host wiring, not an extension to the shared replay contract.
// Set directories before opening a session. Roots must already exist. NULL disables
// that output. Failure leaves the previous configuration intact. Returned paths from
// nvn_plat_dir remain valid for the process lifetime, including across sessions.
int nvn_ohos_set_dirs(const char* state_root, const char* files_root);
// Publish from the window lease callback; publish NULL before destroying its window.
// The host must retain the window throughout surface creation and session use.
void nvn_ohos_set_window(void* native, uint32_t width, uint32_t height);
// Install before replay starts; change only with no active session. A host with
// stop-the-world mapping transactions MUST supply its runtime's safepoint callback.
void nvn_ohos_set_safepoint(void (*fn)(void));
#ifdef __cplusplus
}
#endif
