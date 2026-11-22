// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
// 图形阶段存储图像读改写（红通道 +0.25），同时往颜色附件写绿色：
// 夹具里同一张图既当本通道的附件、又当存储图像时，这一笔必须被整笔跳过（附件里留着清屏值）。
layout(set=0,binding=0,rgba8) uniform image2D img;
layout(location=0) out vec4 color;
void main() {
    ivec2 p=ivec2(gl_FragCoord.xy)&(imageSize(img)-1);
    vec4 old=imageLoad(img,p);
    imageStore(img,p,vec4(old.r+0.25,old.gba));
    color=vec4(0,1,0,1);
}
