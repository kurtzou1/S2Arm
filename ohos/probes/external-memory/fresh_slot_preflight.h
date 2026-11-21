// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Only the app's claimed pre-engine diagnostic session may call this function.
// The caller must require a process restart before admitting any game afterward.
// logFd stays owned by the caller and must refer to a regular result file.
__attribute__((visibility("default"))) int S2AFreshSlotPreflight(int logFd);
#ifdef __cplusplus
}
#endif
