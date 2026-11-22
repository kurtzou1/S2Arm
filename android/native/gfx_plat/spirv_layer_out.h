// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_SPIRV_LAYER_OUT_H
#define S2A_SPIRV_LAYER_OUT_H
#include <stddef.h>
#include <stdint.h>
// 顶点 / 几何阶段的 SPIR-V 是否写渲染目标层号（BuiltIn Layer = 9）：OpDecorate（71）或 OpMemberDecorate（72）带
// BuiltIn（11）Layer。这两个阶段里 Layer 只能是输出，出现即是写。用途：这种程序按分层通道画（每个图元按层号落到附件的
// 对应层），同 iOS nvn_mtl.m 的 layer_out。字流不合法（魔数 / 长度 / 指令字数）一律答 0。
static inline int s2a_spirv_writes_layer(const uint32_t *w, size_t bytes) {
    if (!w || bytes < 20 || bytes % 4 || w[0] != 0x07230203u) return 0;
    const size_t words = bytes / 4;
    for (size_t i = 5; i < words;) {
        const unsigned n = w[i] >> 16, op = w[i] & 65535u;
        if (!n || n > words - i) return 0;
        if (op == 71 && n >= 4 && w[i + 2] == 11 && w[i + 3] == 9) return 1;
        if (op == 72 && n >= 5 && w[i + 3] == 11 && w[i + 4] == 9) return 1;
        i += n;
    }
    return 0;
}
#endif
