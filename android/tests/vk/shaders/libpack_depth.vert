// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
// 出包预编库的只有顶点阶段的深度程序：无顶点输入的全屏三角形，z 固定 0.5（深度 0..1，同库的 near = 0 口径）。
void main() {
    vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.5, 1.0);
}
