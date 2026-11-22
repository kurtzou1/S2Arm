// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// DrawTexture（#1452）：按插值后的 uv 用游戏给的采样器读源，只写 color(0)。
#version 450
layout(set = 0, binding = 0) uniform sampler2D t;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 o;
void main() { o = texture(t, uv); }
