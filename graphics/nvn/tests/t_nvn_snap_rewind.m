// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 即时快照恢复把栅栏号 / 出图票号倒回（nvn_snap.inc snap_seq_rewind）。直接包含生产 nvn_mtl.m，Metal 3（NXGAL_BE=mtl3），走真 present_now。
//   判据（期望值手写）：
//   ① 旧局 900 号票真上屏（槽 0 的占用号 = 900）后倒回到 10，同槽的 12 号票 2 s 内交掉
//      （负对照：不清占用号时 present_now 等 g_pq_done 追到 900，2 s 内不返回）；命令分配器的占用号同样清零
//   ② 旧局 900 号栅栏的 GPU 写入记录（大范围写入表、在途内联常量更新表）倒回后不算在途
//      （负对照：不清 g_gw_wide / g_ifw_head 时仍在途，ubo_wait_submitted 会在提交线程上等 900 号栅栏）
#include "../gfx/nvn/nvn_mtl.m"
#include "s2a_t_result.h"

static int bad, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) bad++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// 无窗口出图层：front_metal_layer（host_adapt.m Mac 分支）按名字 dlsym 这个符号
static CAMetalLayer *g_test_layer;
__attribute__((used, visibility("default"))) void *s2a_mac_front_layer(void) { return (__bridge void *)g_test_layer; }

// 指定票号走一次真上屏（照显示链接回调：present_now 之后推进 g_pq_done 并广播）
static tex_t g_tex; static _Atomic int g_tk_ret = -1, g_tk_done;
static void *ticket_thread(void *a) {
    uint64_t tk = (uint64_t)(uintptr_t)a; int r;
    @autoreleasepool { r = present_now(&g_tex, 1 / 60.0, tk, tk, NULL, nil, 0); }
    pthread_mutex_lock(&g_pq_mu); if (!r && tk > g_pq_done) g_pq_done = tk; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
    atomic_store(&g_tk_ret, r); atomic_store(&g_tk_done, 1); return NULL;
}
static int present_ticket(uint64_t tk, uint64_t ns, pthread_t *th) {
    atomic_store(&g_tk_done, 0); atomic_store(&g_tk_ret, -1); pthread_create(th, NULL, ticket_thread, (void *)(uintptr_t)tk);
    uint64_t t0 = now_ns(); while (!atomic_load(&g_tk_done) && now_ns() - t0 < ns) usleep(1000);
    return atomic_load(&g_tk_done);
}
static int wait_idle(uint64_t ns) {
    uint64_t t0 = now_ns(); int n;
    do { pthread_mutex_lock(&g_pq_mu); n = g_pq_inflight; pthread_mutex_unlock(&g_pq_mu); if (n) usleep(1000); } while (n && now_ns() - t0 < ns);
    return !n;
}

int main(void) {
    @autoreleasepool {
        char map[] = "/tmp/t_snap_rewind_map_XXXXXX"; int fd = mkstemp(map); if (fd < 0) return 2; close(fd); setenv("DM_NVN_SHMAP", map, 1);
        setenv("NXGAL_BE", "mtl3", 1); setenv("S2A_ANTI_ALIASING", "SmaaMedium", 1); setenv("S2A_SCALING_FILTER", "Bilinear", 1);
        mtl_init();
        VERIFY(g_m3, "Metal 3 后端（NXGAL_BE=mtl3）");
        pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 1; pthread_mutex_unlock(&g_pq_mu);   // 显示链接模式
        g_test_layer = [CAMetalLayer layer]; g_test_layer.drawableSize = CGSizeMake(128, 72);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:36 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> src = [g_dev newTextureWithDescriptor:td];
        memset(&g_tex, 0, sizeof g_tex); g_tex.magic = MAGIC('T', 'E', 'X', 0); g_tex.serial = mtl_ext_tex((__bridge void *)src);
        VERIFY(front_metal_layer() == (__bridge void *)g_test_layer, "无窗口出图层接上 front_metal_layer");
        g_present_stall_ns = 0;

        // ① 出图票号倒回后不等旧局的占用号
        pthread_t tt; int ok = present_ticket(900, 2000000000ull, &tt); if (ok) pthread_join(tt, NULL);
        VERIFY(ok && atomic_load(&g_tk_ret) == 1 && wait_idle(2000000000ull), "旧局 900 号票交掉并完成（返回 %d）", atomic_load(&g_tk_ret));
        pthread_mutex_lock(&g_pq_mu); uint64_t f0 = g_present_alloc_fence[0], d0 = g_pq_done; pthread_mutex_unlock(&g_pq_mu);
        VERIFY(f0 == 900 && d0 == 900, "槽 0 的占用号 %llu、已完成 %llu（= 900 / 900）", (unsigned long long)f0, (unsigned long long)d0);
        g_alloc_fence[0] = 900;
        // ② 旧局 900 号栅栏的 GPU 写入记录
        uint64_t wlo = 0x10000000ull, whi = wlo + ((uint64_t)(GW_PAGES + 1) << 12), ilo = 0x20000040ull; uint8_t ib[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        gw_put(wlo, whi, 900, 0); int iput = ifw_put(ilo, ilo + 8, ib, 900, 0);
        VERIFY(gw_live(wlo, whi) && iput && ifw_pending_fence(ilo, ilo + 8) == 900, "旧局 900 号栅栏的大范围写入与内联常量更新记在表里（在途）");
        snap_seq_rewind(7, 10);
        VERIFY(!gw_live(wlo, whi) && !gw_live(ilo, ilo + 8), "倒回后两处都不算在途（大范围 %d、内联 %llu；不清则 ubo_wait_submitted 等 900 号栅栏）", gw_live(wlo, whi), (unsigned long long)ifw_pending_fence(ilo, ilo + 8));
        pthread_mutex_lock(&g_pq_mu); uint64_t in1 = g_pq_in, d1 = g_pq_done, r1 = g_pq_read; pthread_mutex_unlock(&g_pq_mu);
        VERIFY(in1 == 10 && d1 == 10 && r1 == 10 && g_fence == 7 && g_done == 7, "倒回：票号 %llu / %llu / %llu（= 10），栅栏 %llu / %llu（= 7）",
               (unsigned long long)in1, (unsigned long long)d1, (unsigned long long)r1, (unsigned long long)g_fence, (unsigned long long)g_done);
        VERIFY(!g_alloc_fence[0], "命令分配器的占用号清零（%llu）", (unsigned long long)g_alloc_fence[0]);
        uint64_t t0 = now_ns(); ok = present_ticket(12, 2000000000ull, &tt);
        VERIFY(ok && atomic_load(&g_tk_ret) == 1, "倒回后同槽 12 号票 %.0f ms 交掉（2 s 内 %d，返回 %d；不清占用号则等 g_pq_done 追到 900）", (now_ns() - t0) / 1e6, ok, atomic_load(&g_tk_ret));
        if (!ok) { pthread_mutex_lock(&g_pq_mu); g_pq_done = 900; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu); }   // 放开卡住的线程，单测照常收尾
        pthread_join(tt, NULL); wait_idle(2000000000ull);
        unlink(map);
    }
    return S2A_T_RESULT("t_nvn_snap_rewind", bad);
}
