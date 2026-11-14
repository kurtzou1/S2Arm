// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// 无 BC 时解压管线在设备初始化时就交后台去建（#582）：bcd_pso 从源码现编解压核，每次启动约 230 ms，原先在第一张 BC 贴图上传时才建，挡在上传上。
// mtl_init（游戏里第一次登记内存池时进来，在第一张贴图上传之前）→ 看后台构建有没有起、用的时候还要不要现编。
//   ① DM_TEST_NO_BC=1：设备初始化后后台构建已起（g_bcd_pre 非空）；等它做完后 bcd_ready 拿到管线、且这一下不再现编（< 5 ms）
//   ② DM_TEST_NO_BC=0 且显卡支持 BC：不起后台构建（g_bcd_pre 为空），有 BC 的机器不多编一条用不上的管线
// 反证：去掉 mtl_init 末尾的 bcd_prewarm() → ① 红
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../gfx/nvn/nvn_mtl.m"


int main(void) { @autoreleasepool {
    const char *e = getenv("DM_TEST_NO_BC"); int want_nobc = e && *e && strcmp(e, "0");
    mtl_init();
    if (want_nobc) {
        int started = g_bcd_pre != NULL;
        printf("%s ① 无 BC：设备初始化后解压管线后台构建%s\n", started ? "✓" : "✗", started ? "已起" : "没起");
        if (!started) { printf("✗ t_nvn_bcd_prewarm（DM_TEST_NO_BC=1）\n"); return 1; }
        dispatch_group_wait(g_bcd_pre, DISPATCH_TIME_FOREVER);
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); id<MTLComputePipelineState> ps = bcd_ready(); double ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6;
        int ok = ps != nil && ms < 5.0;
        printf("%s ① 用的时候：管线%s，取用 %.3f ms（期望 < 5 ms，不再现编）\n", ok ? "✓" : "✗", ps ? "已在" : "没有", ms);
        if (!ok) { printf("✗ t_nvn_bcd_prewarm（DM_TEST_NO_BC=1）\n"); return 1; }
        printf("✓ t_nvn_bcd_prewarm（DM_TEST_NO_BC=1）：2 项\n");
    } else {
        if (![g_dev supportsBCTextureCompression]) { printf("✓ t_nvn_bcd_prewarm（DM_TEST_NO_BC=0）：本机显卡不支持 BC，② 不适用，跳过\n"); return 0; }
        int started = g_bcd_pre != NULL;
        printf("%s ② 有 BC：%s后台构建\n", started ? "✗" : "✓", started ? "仍起了" : "没起");
        if (started) { printf("✗ t_nvn_bcd_prewarm（DM_TEST_NO_BC=0）\n"); return 1; }
        printf("✓ t_nvn_bcd_prewarm（DM_TEST_NO_BC=0）：1 项\n");
    }
    return 0;
} }
