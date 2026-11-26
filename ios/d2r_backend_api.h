// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#pragma once

#import <UIKit/UIKit.h>

#define S2A_D2R_BACKEND_ABI 2

typedef struct {
    unsigned version;
    // All calls into this interface come from the main thread.
    UIViewController *(*prepare)(NSURL *documents, NSString *romfs, NSString *sessionRoot,
                                 CGRect bounds, NSString **reason);
    void (*start)(void);
    void (*focus)(int event);
    void (*stop)(void);
} S2AD2RBackend;

typedef const S2AD2RBackend *(*S2AD2RBackendEntry)(void);
