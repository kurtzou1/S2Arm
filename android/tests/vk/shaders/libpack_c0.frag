// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
// 出包预编库的片元：c0（驱动常量段，UBO 0xA00 字节）在 binding 22 = arg_id 3 × 6 + 片元阶段号 4。
// 读 0x600（槽 15 存储缓冲地址低字）/ 0x604（高字）当 RGBA8 颜色：左半屏低字、右半屏高字。
layout(set = 0, binding = 22, std140) uniform C0 { uvec4 data[160]; } c0;
layout(location = 0) out vec4 o;
void main() {
    uvec4 d = c0.data[96];
    o = unpackUnorm4x8(gl_FragCoord.x < 2.0 ? d.x : d.y);
}
