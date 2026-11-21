// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct { CGFloat width; BOOL vertical, verticalButtons; } S2APromptLayout;
static inline S2APromptLayout S2APromptLayoutMake(CGFloat safeWidth, CGFloat widestButton, NSInteger count) {
    CGFloat width = MIN(560, MAX(0, safeWidth - 24));
    CGFloat buttonsWidth = widestButton * count + 8 * MAX(0, count - 1);
    BOOL compact = safeWidth < 600;
    if (!compact) width = MIN(width, safeWidth * .55);
    BOOL vertical = compact || width - 30 - buttonsWidth - 16 < 220;
    return (S2APromptLayout){width, vertical, vertical && buttonsWidth > width - 30};
}
