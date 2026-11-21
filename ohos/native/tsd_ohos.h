// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { S2A_OHOS_TSDOFF_IDX = 4 };
// Logical base = real pthread key table - 8; slot = (key + 1) * 8.
// Key page slot 4 contains TP -> real table pointer's signed displacement.
int s2a_ohos_tsd_init(void);
uint64_t s2a_ohos_tsd_base(void);
int s2a_ohos_tsd_offset(uint32_t key, uint64_t *out);
int s2a_ohos_tsd_pointer_offset(int64_t *out);
#ifdef __cplusplus
}
#endif
