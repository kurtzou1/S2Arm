// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#import "play_layout.h"

// Where the lower-area reflection sits (root-view coordinates): the game area mirrored about the middle of the
// gap between the game area and the controls, i.e. the game area's size starting at the top of the controls.
// CGRectNull when the layout is not split. The picture inside it is drawn upright and flipped by the layer.
CGRect S2APlayReflectionFrame(S2APlayLayout layout);
// Whether the lower half gets a mirrored copy: only on a device with a real fold (layout.division from the hinge).
BOOL S2APlayReflectionWanted(S2APlayLayout layout);
#if TARGET_OS_IPHONE
@class CALayer, CAMetalLayer;
@protocol CAMetalDrawable;
// Main thread; the host retains one game layer per root. Both renderers keep their own frame / drawable size.
void s2a_ios_attach_game_layer(UIView *root, CALayer *game);
void S2APlayReflectionLayout(UIView *root, S2APlayLayout layout);
// Any thread, from a renderer's present of `game`. While the lower-area reflection is showing, returns a drawable of
// the reflection layer (same device / pixel format as `game`, a quarter of the game layer's pixels) for the renderer to
// draw this frame's picture into, upright, in the same command buffer as the game present, and present it with it.
// Otherwise nil. Never blocks the present: with two reflection frames still on their way to the screen it skips.
id<CAMetalDrawable> s2a_ios_reflection_drawable(CAMetalLayer *game);
#endif
