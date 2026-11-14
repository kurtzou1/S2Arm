// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "nvn_vsync.h"
#include <stdio.h>

int nvn_vsync_start(uint32_t hz, nvn_vsync_fn fn, void* user, char* why, size_t why_size) {
  (void)hz;
  (void)fn;
  (void)user;
  if (why && why_size)
    snprintf(why, why_size, "OHOS display tick source is not connected");
  return -1;
}
void nvn_vsync_stop(void) {
  // start never registers a callback; the replay core uses its timed fallback.
}
