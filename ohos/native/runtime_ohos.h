// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
// The structures and service exports deliberately keep the mature runtime ABI.
// The shell must retain HostApi, native owner, lease, all paths and the DSO until
// process exit; synchronous return is not proof that guest threads have parked.
#include "../../android/native/runtime/runtime.h"
#ifdef __cplusplus
extern "C" {
#endif
int s2a_ohos_runtime_run(const struct s2a_android_runtime_request *request);
// Same request; consults <state>/graphics_mode (absent = unchanged v1 generic) and graphics.v1.json.
int s2a_ohos_runtime_run_selected(const struct s2a_android_runtime_request *request);
int s2a_ohos_graphics_mode(const char *state_dir);
int s2a_ohos_runtime_status(uint64_t session_id, struct s2a_android_runtime_status *status);
int s2a_ohos_runtime_request_stop(uint64_t session_id);
#ifdef __cplusplus
}
#endif
