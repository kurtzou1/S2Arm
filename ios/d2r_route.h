// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#pragma once
#import "d2r_backend_api.h"

BOOL s2a_d2r_matches(const char *titleID);
BOOL s2a_d2r_open(UIWindow *window, NSString **reason);
void s2a_d2r_focus(int event);
void s2a_d2r_stop(void);
BOOL s2a_d2r_is_active(void);
