// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// DrawTexture（#1452）：4 个顶点的条带盖满视口（视口 = 目的矩形）。位置是 NVN 裁剪空间，视口与窗口原点的换算同普通绘制；
// uv (u0, v0) 在 (-1, +1) 那一角、(u1, v1) 在 (+1, -1) 那一角（对照 iOS nvn_mtl.m draw_tex 的 dt_vs）。
#version 450
layout(push_constant) uniform P { vec4 uv; } p;   // u0 v0 u1 v1
layout(location = 0) out vec2 o_uv;
void main() {
    vec2 c = vec2(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1));
    o_uv = mix(p.uv.xy, p.uv.zw, c);
    gl_Position = vec4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
}
