// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 计算管线现建慢行（vkCreateComputePipelines 超过 3 毫秒，开关 nvk_hitch_log）的文本。
// 前缀「计算管线编译 X 毫秒」保持原样（长帧归因脚本按它取毫秒）；后面补计算阶段键（实际交给后端的 shader_src.key，
// 现编 / 出库都有）与出库标记：出库版再带交给 Vulkan 的模块摘要前 4 字节。键全零 = 调用方没给键，写「键 -」。
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

static inline int nvn_vk_compute_pipe_line(char *out, size_t n, double ms, const uint8_t key[8], int lib, const uint8_t digest[32]) {
    int zero = 1;
    for (int i = 0; i < 8; i++) if (key[i]) zero = 0;
    int o = snprintf(out, n, "计算管线编译 %.1f 毫秒", ms);
    if (o < 0 || (size_t)o >= n) return o;
    if (zero) o += snprintf(out + o, n - (size_t)o, " 键 -");
    else {
        o += snprintf(out + o, n - (size_t)o, " 键 ");
        for (int i = 0; i < 8 && (size_t)o < n; i++) o += snprintf(out + o, n - (size_t)o, "%02x", key[i]);
    }
    if ((size_t)o < n) o += snprintf(out + o, n - (size_t)o, lib ? " 出库 摘要 %02x%02x%02x%02x…" : " 现编", digest[0], digest[1], digest[2], digest[3]);
    return o;
}
