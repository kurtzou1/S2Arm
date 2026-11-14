// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// Switch 2 的两个从源码现编的计算核在设备初始化时就交后台去建（#674）：间接绘制换算核（ixc，Switch 2 的间接任务 / 网格绘制要它）和张量核顶替的平方核
//   （tensor_sq），原先在第一个 3D 场景里第一次用到时才建；系统编译缓存没命中时（新构建第一次启动、缓存被挤掉）挡在提交线程上（M4 上 24–160 / 74–118 ms）。
// mtl_init（游戏第一次登记内存池时进来，在第一帧绘制之前）→ 看后台构建有没有起、用的时候还要不要现编。
//   ① DM_TEST_OUNCE=1（写一份 Switch 2 布局的 NPDM 置平台位，同 t_nvn_gva）：两个后台构建都已起；等它们做完后 ixc_ready / tensor_sq_ready 拿到管线、
//      且这一下不再现编（< 5 ms）
//   ② DM_TEST_OUNCE=0：都不起，Switch 1 游戏不多编两条多半用不上的管线（照旧第一次用到时建）
// 反证：去掉 mtl_init 里的 ixc_prewarm(); tensor_sq_prewarm(); → ① 红
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "../gfx/nvn/nvn_mtl.m"

uint64_t s2a_npdm_window_need(const char *npdm);   // runtime/src/svc_mem.c：读 NPDM，Switch 2 的 ACID 布局置平台位（nvn2_on）
static int fails;
static void check(int ok, const char *what) { printf("%s %s\n", ok ? "✓" : "✗", what); fails += !ok; }
static void ounce_on(void) {   // Switch 2 布局的 NPDM（ACID 魔数在 ACID +0x300），经原生层读一遍置平台位
    char path[1024]; const char *td = getenv("TMPDIR"); snprintf(path, sizeof path, "%s/t_nvn_kern_prewarm_npdm_XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(path); if (fd < 0) { printf("✗ 临时 NPDM 建不出\n"); exit(1); }
    static uint8_t npdm[0x80 + 0x400]; memcpy(npdm, "META", 4); uint32_t acid = 0x80; memcpy(npdm + 0x78, &acid, 4); memcpy(npdm + 0x80 + 0x300, "ACID", 4);
    if (write(fd, npdm, sizeof npdm) != (ssize_t)sizeof npdm) { printf("✗ 临时 NPDM 写不进\n"); exit(1); }
    close(fd); s2a_npdm_window_need(path); unlink(path);
}
static double ms_since(uint64_t t0) { return (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6; }

int main(void) { @autoreleasepool {
    const char *e = getenv("DM_TEST_OUNCE"); int ounce = e && *e && strcmp(e, "0");
    if (ounce) ounce_on();
    if (!!nvn2_on() != ounce) { printf("✗ 平台位没按 DM_TEST_OUNCE=%d 置上\n", ounce); return 1; }
    mtl_init();
    const char *tag = ounce ? "DM_TEST_OUNCE=1" : "DM_TEST_OUNCE=0";
    if (ounce) {
        check(g_ixc_pre != NULL, g_ixc_pre ? "① Switch 2：设备初始化后间接绘制换算核后台构建已起" : "① Switch 2：设备初始化后间接绘制换算核后台构建没起");
        check(g_tsq_pre != NULL, g_tsq_pre ? "① Switch 2：设备初始化后张量核顶替平方核后台构建已起" : "① Switch 2：设备初始化后张量核顶替平方核后台构建没起");
        if (fails) { printf("✗ t_nvn_kern_prewarm（%s）：%d 项不符\n", tag, fails); return 1; }
        dispatch_group_wait(g_ixc_pre, DISPATCH_TIME_FOREVER); dispatch_group_wait(g_tsq_pre, DISPATCH_TIME_FOREVER);
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); int ix = ixc_ready(); double ms = ms_since(t0);
        char b[160]; snprintf(b, sizeof b, "① 用的时候：换算核%s，取用 %.3f ms（期望 < 5 ms，不再现编）", ix ? "已在" : "没有", ms); check(ix && ms < 5.0, b);
        t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); id<MTLComputePipelineState> sq = tensor_sq_ready(); ms = ms_since(t0);
        snprintf(b, sizeof b, "① 用的时候：平方核%s，取用 %.3f ms（期望 < 5 ms，不再现编）", sq ? "已在" : "没有", ms); check(sq != nil && ms < 5.0, b);
    } else {
        check(g_ixc_pre == NULL, g_ixc_pre ? "② 非 Switch 2：仍起了换算核后台构建" : "② 非 Switch 2：没起换算核后台构建");
        check(g_tsq_pre == NULL, g_tsq_pre ? "② 非 Switch 2：仍起了平方核后台构建" : "② 非 Switch 2：没起平方核后台构建");
    }
    if (fails) { printf("✗ t_nvn_kern_prewarm（%s）：%d 项不符\n", tag, fails); return 1; }
    printf("✓ t_nvn_kern_prewarm（%s）：%d 项\n", tag, ounce ? 4 : 2);
    return 0;
} }
