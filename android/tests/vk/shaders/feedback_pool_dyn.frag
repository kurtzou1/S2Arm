// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
layout(set=0,binding=0) uniform texture2D images[3];
layout(set=0,binding=1) uniform sampler samp;
layout(push_constant) uniform PC { uint idx; } pc;
layout(location=0) out vec4 color;
void main() {
    // 整池数组里的下标由推送常量给（运行时才知道，整笔 draw 内一致）：
    // 夹具把它指向「本通道正在写的那张附件」，也就是整池数组真去读写着的图。
    ivec2 p=ivec2(gl_FragCoord.xy);
    color=texelFetch(sampler2D(images[pc.idx],samp),p,0)+vec4(0.25,0,0,0);
}
