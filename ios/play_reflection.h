// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#import "play_layout.h"

// CAReplicatorLayer's center-relative transform; layout and bounds use root-view coordinates.
CGAffineTransform S2APlayReflectionTransform(S2APlayLayout layout, CGRect bounds);
#if TARGET_OS_IPHONE
@class CALayer;
// Main thread; the host retains one game layer per root. Both renderers keep their own frame / drawable size.
void s2a_ios_attach_game_layer(UIView *root, CALayer *game);
void S2APlayReflectionLayout(UIView *root, S2APlayLayout layout);
#endif
