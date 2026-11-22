// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 游戏进行中连续回到快照不涨内存：快照恢复时登记进常驻集（res_add）的贴图，会话销毁（nvn_be_shutdown_session）要让它们出常驻集。直接包含生产 nvn_mtl.m。
//   判据（期望值手写）：
//   ① 等重建时写回的贴图（g_snap_ghost_pend）、只剩幽灵表持有的贴图（g_ghost）各一张，res_add 后放进表 → 会话销毁 → 都不在常驻集、两张表 0 条
//   反证：销毁处换回只放引用（hm_rel）→ 对应项红（仍在常驻集：常驻集强引用，每回一次快照留一批）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    alarm(60); unsetenv("NXGAL_BE");
    mtl_init();
    MTLTextureDescriptor *gd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    id<MTLTexture> gp = [g_dev newTextureWithDescriptor:gd], gh = [g_dev newTextureWithDescriptor:gd];
    { uint64_t gser = 0x77, hser = 0x78; res_add(gp); nvn_hm_put(&g_snap_ghost_pend, &gser, (void *)CFBridgingRetain(gp));
      res_add(gh); pthread_mutex_lock(&g_smu); hm_put_id(&g_ghost, &hser, gh); pthread_mutex_unlock(&g_smu);   // 只剩幽灵表持有的贴图（恢复放回的 / 已销毁序号的）
      pthread_mutex_lock(&g_res_mu); int pre = gp && gh && [g_res_objects containsObject:gp] && [g_res_objects containsObject:gh]; pthread_mutex_unlock(&g_res_mu); REQUIRE(pre); }
    REQUIRE(!nvn_be_shutdown_session()); nvn_be_begin_session();
    { pthread_mutex_lock(&g_res_mu); int in = [g_res_objects containsObject:gp], ih = [g_res_objects containsObject:gh]; pthread_mutex_unlock(&g_res_mu);
      CHECK(!in && !g_snap_ghost_pend.n,"① 待写回贴图销毁后还在常驻集 %d、待写回表 %u 条（期望都 0）",in,g_snap_ghost_pend.n);
      CHECK(!ih && !g_ghost.n,"① 幽灵表贴图销毁后还在常驻集 %d、幽灵表 %u 条（期望都 0）",ih,g_ghost.n); }
    printf("%s t_nvn_snap_resident：%u 项，%u 项失败\n",failures?"✗":"✓",checks,failures);
    return failures!=0;
} }
