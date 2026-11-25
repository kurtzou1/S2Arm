// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// 无 BC 时解压管线在设备初始化时就交后台去建（#582）：bcd_pso 从源码现编解压核，每次启动约 230 ms，原先在第一张 BC 贴图上传时才建，挡在上传上。
// mtl_init（游戏里第一次登记内存池时进来，在第一张贴图上传之前）→ 看后台构建有没有起、用的时候还要不要现编。
//   ① DM_TEST_NO_BC=1：设备初始化后后台构建已起（g_bcd_pre 非空）；等它做完后 bcd_ready 拿到管线、且这一下不再现编
//      （判据：「编成功」那行在后台构建做完时已出现恰好 1 次，取用后仍是 1 次；耗时只作读数）
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


// 解压管线编成功时 bcd_pso 打一行「no BC: BC1–7 are decompressed on the GPU」（日志层写 fd 2）：把 fd 2 接到临时文件数这一行，
//   当「真编了一次」的事件（11-25 去墙钟：原判据「取用 < 5 ms」负载高时会漂）
static char g_errp[1024]; static int g_err_saved = -1;
static void err_capture(void) {
    const char *td = getenv("TMPDIR"); snprintf(g_errp, sizeof g_errp, "%s/t_nvn_bcd_prewarm_err_XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(g_errp); if (fd < 0) { printf("✗ 临时日志文件建不出\n"); exit(1); }
    fflush(stderr); g_err_saved = dup(2); dup2(fd, 2); close(fd);
}
static int built_lines(void) {   // 到目前为止「编成功」那行出现了几次
    fflush(stderr); FILE *f = fopen(g_errp, "r"); if (!f) return -1; char l[1024]; int n = 0;
    while (fgets(l, sizeof l, f)) if (strstr(l, "no BC: BC1–7 are decompressed on the GPU")) n++;
    fclose(f); return n;
}
static void err_restore(void) { if (g_err_saved >= 0) { fflush(stderr); dup2(g_err_saved, 2); close(g_err_saved); g_err_saved = -1; unlink(g_errp); } }

int main(void) { @autoreleasepool {
    const char *e = getenv("DM_TEST_NO_BC"); int want_nobc = e && *e && strcmp(e, "0");
    if (want_nobc) err_capture();
    mtl_init();
    if (want_nobc) {
        int started = g_bcd_pre != NULL;
        printf("%s ① 无 BC：设备初始化后解压管线后台构建%s\n", started ? "✓" : "✗", started ? "已起" : "没起");
        if (!started) { err_restore(); printf("✗ t_nvn_bcd_prewarm（DM_TEST_NO_BC=1）\n"); return 1; }
        dispatch_group_wait(g_bcd_pre, DISPATCH_TIME_FOREVER);
        int n0 = built_lines();   // 后台构建做完：应已编过恰好 1 次
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); id<MTLComputePipelineState> ps = bcd_ready(); double ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6;
        int n1 = built_lines(); err_restore();
        int ok = ps != nil && n0 == 1 && n1 == 1;
        printf("%s ① 用的时候：管线%s；编过 %d 次（后台构建做完时 %d 次，期望都是 1：后台建好、取用不再现编）（读数：取用 %.3f ms）\n", ok ? "✓" : "✗", ps ? "已在" : "没有", n1, n0, ms);
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
