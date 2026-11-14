// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// Switch 2 程序在 ProgramSetShaders 时就交后台预取（#674）：NVN2 阶段的正式键在首次绘制时算（keys_hash 在 SetShaders 不算），
//   原先连预取也一起跳过，Switch 2 游戏的每个着色器库都在提交线程首次绘制时现场加载。
// 生产引导 → 写一份 Switch 2 布局的 NPDM 置平台位（同 t_nvn_gva）→ 真程序对象 ProgramSetShaders 一个 NVN2 阶段 → 看预取有没有被叫到。
// 期望不跑被测实现得出：控制段 / 代码按 t_nvn2.c K 段的字节造，键 291eb4556e0fcc0c 是那里 Python hashlib 按 nvn2.h 规则算的。
//   ① 代码在已登记的池里：预取收到键 291eb4556e0fcc0c
//   ② 代码地址不在任何池里（还没映射）：预取不被叫到（没有可哈希的代码，不猜）
// 反证：去掉 hle_nvn.c SetShaders 循环里 keys_hash_early 那一行 → ① 红
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../gfx/nvn/nvn_mtl.m"

uint64_t s2a_npdm_window_need(const char *npdm);   // runtime/src/svc_mem.c：读 NPDM，Switch 2 的 ACID 布局置平台位（nvn2_on）
extern void *h_nvnBootstrapLoader(const char *name);
static unsigned checks;
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p != NULL); return p; }
#define API(name) ((NVNT_##name)load(#name))
enum { POOL_SIZE = 4 << 20, CODE_OFF = 0x7000 };

static void ounce_on(void) {   // Switch 2 布局的 NPDM（ACID 魔数在 ACID +0x300），经原生层读一遍置平台位
    char path[1024]; const char *td = getenv("TMPDIR"); snprintf(path, sizeof path, "%s/t_nvn_ounce_prefetch_npdm_XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(path); REQUIRE(fd >= 0);
    static uint8_t npdm[0x80 + 0x400]; memcpy(npdm, "META", 4); uint32_t acid = 0x80; memcpy(npdm + 0x78, &acid, 4); memcpy(npdm + 0x80 + 0x300, "ACID", 4);
    REQUIRE(write(fd, npdm, sizeof npdm) == (ssize_t)sizeof npdm);
    close(fd); s2a_npdm_window_need(path); unlink(path);
}
static int asked(NSString *key) {
    os_unfair_lock_lock(&g_shpre_mu); int r = [g_shpre_seen containsObject:key]; os_unfair_lock_unlock(&g_shpre_mu);
    return r;
}
static void nvn2_control(uint8_t ctl[0xe0]) {   // t_nvn2.c K 段：ctl[i] = (i*7+3)&0xff，魔数、+4 版本、+0x44 代码长 64
    for (int i = 0; i < 0xe0; i++) ctl[i] = (uint8_t)(i * 7 + 3);
    uint32_t v = NVN2_CTL_MAGIC; memcpy(ctl, &v, 4); v = NVN2_CTL_VERSION; memcpy(ctl + 4, &v, 4); v = 64; memcpy(ctl + 0x44, &v, 4);
}

int main(void) { @autoreleasepool {
    ounce_on(); REQUIRE(nvn2_on());
    char map[] = "/tmp/t_nvn_ounce_prefetch.XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd);
    setenv("DM_NVN_SHMAP", map, 1);   // 空着色器表：预取拿到键后查不到阶段就丢掉，本测只看它有没有被叫到
    NVNdevice device; NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    uint8_t *memory; REQUIRE(posix_memalign((void **)&memory, 65536, POOL_SIZE) == 0); memset(memory, 0, POOL_SIZE);
    NVNmemoryPool pool; NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
    for (int i = 0; i < 64; i++) memory[CODE_OFF + i] = (uint8_t)(i * 13 + 5);   // t_nvn2.c K 段的代码字节

    // ① 代码在池里
    static uint8_t ctl[0xe0]; nvn2_control(ctl);
    NVNshaderData sd = {API(nvnMemoryPoolGetBufferAddress)(&pool) + CODE_OFF, ctl};
    static NVNprogram prog; REQUIRE(API(nvnProgramInitialize)(&prog, &device)); REQUIRE(API(nvnProgramSetShaders)(&prog, 1, &sd));
    int a1 = asked(@"291eb4556e0fcc0c");

    // ② 代码地址不在任何池里：换一份控制段（+0x28 改一位，键随之不同），代码地址指向池外
    static uint8_t ctl2[0xe0]; nvn2_control(ctl2); ctl2[0x28] ^= 1;
    NVNshaderData sd2 = {API(nvnMemoryPoolGetBufferAddress)(&pool) + POOL_SIZE + 0x100000, ctl2};
    static NVNprogram prog2; REQUIRE(API(nvnProgramInitialize)(&prog2, &device)); REQUIRE(API(nvnProgramSetShaders)(&prog2, 1, &sd2));
    os_unfair_lock_lock(&g_shpre_mu); NSUInteger n_seen = g_shpre_seen.count; os_unfair_lock_unlock(&g_shpre_mu);

    int bad = 0;
    printf("%s ① 代码在池里：期望 预取收到 291eb4556e0fcc0c → %s\n", a1 ? "✓" : "✗", a1 ? "收到" : "没被叫到（SetShaders 跳过了 Switch 2 阶段的预取）"); bad |= !a1;
    printf("%s ② 代码不在池里：期望 预取一共只收到 1 个键 → %lu 个\n", n_seen == 1 ? "✓" : "✗", (unsigned long)n_seen); bad |= n_seen != 1;
    printf("%s t_nvn_ounce_prefetch：Switch 2 程序在 SetShaders 时交后台预取（%u 项检查）\n", bad ? "✗" : "✓", checks + 2);
    unlink(map);
    return bad;
} }
