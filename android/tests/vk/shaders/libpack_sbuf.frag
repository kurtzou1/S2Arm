// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
// 出包预编库的片元：两个只读存储缓冲，binding 10 = arg_id 1 × 6 + 片元阶段号 4、binding 22 = arg_id 3 × 6 + 4。
// 读各自的第 0 个 uint 当 RGBA8 颜色：左半屏读 binding 10（库里 sbuf reg 2），右半屏读 binding 22（库里 sbuf reg 9）。
layout(set = 0, binding = 10, std430) readonly buffer BufA { uint v[]; } a;
layout(set = 0, binding = 22, std430) readonly buffer BufB { uint v[]; } b;
layout(location = 0) out vec4 o;
void main() {
    o = unpackUnorm4x8(gl_FragCoord.x < 2.0 ? a.v[0] : b.v[0]);
}
