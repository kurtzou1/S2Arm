// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 参数块「只换了统一缓冲」就打补丁、不整块重编（encode_args_ / args_ubo_patchable，照 nxnative adaff735，MIT；11-13 能耗性能线）。直接包含生产 nvn_mtl.m，走生产 state_op / encode_args。
// 期望按构造写死：片元着色器两项绑定 cb0（参数 0）+ 界长表（参数 1，NVN_RB_UBOLEN），池 64 KB：
//   ① cb0 = 池头 4096 字节，整块编：整块 +1；参数 0 = 池头的 GPU 地址 A，界长表 4096 / 16 = 256
//   ② OP_BIND_UBO 把 cb0 换到池头 + 8192、512 字节：打补丁 +1、整块 +0；参数 0 = A + 8192，界长表 512 / 16 = 32（随新绑定重算）
//   ③ 什么都不变再编：复用 +1，参数块就是 ② 那一块
//   ④ 对照：同一状态强制整块重编（args_dirty_all），参数 0 与界长表与 ② 补出来的逐位相同
//   ⑤ 白名单外的着色器（多一项 TEXU：句柄从统一缓冲里读）换 cb0：整块 +1、打补丁 +0
//   ⑥ 换 cb0 的同时换了贴图绑定（g_args_dirty）：整块 +1、打补丁 +0
// 反证：args_ubo_patchable 恒返回 0 → ② 打补丁 +0、整块 +1（红）；补丁不重算界长表 → ② 界长表仍 256（红）
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/mman.h>
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static NvShader *cb_shader(int extra_kind) {
    NvShader *sh = [NvShader new]; sh->stage = 1; sh->arg_len = 24; strcpy(sh->key, "t_args_patch");
    sh->rf.nb = extra_kind ? 3 : 2; sh->rf.b = calloc(3, sizeof *sh->rf.b);
    sh->rf.b[0].kind = NVN_RB_CBUF; sh->rf.b[0].reg = 0; sh->rf.b[0].aid = 0;
    sh->rf.b[1].kind = NVN_RB_UBOLEN; sh->rf.b[1].aid = 1;
    if (extra_kind) { sh->rf.b[2].kind = extra_kind; sh->rf.b[2].reg = 1; sh->rf.b[2].aid = 2; }
    return sh;
}
static uint64_t slot(NvShader *sh, int i) { return ((const uint64_t *)((const uint8_t *)sh->ab_buf.contents + sh->ab_off))[i]; }
static uint32_t table0(NvShader *sh) {
    uint64_t g = slot(sh, 1);
    for (NSArray *list in @[g_sub_arenas, g_arenas]) for (NvArena *a in list) if (g >= a->gpu && g < a->gpu + a->len) return *(const uint32_t *)(a->cpu + (g - a->gpu));
    REQUIRE(!"界长表地址不在任何暂存块里"); return 0;
}
static void bind_cb0(uint64_t addr, uint64_t size) { p_bind_buf b = {1, 0, addr, size}; state_op(OP_BIND_UBO, &b, sizeof b); }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init(); arena_begin();
    size_t psz = 65536; uint8_t *pool = mmap(NULL, psz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(pool != MAP_FAILED);
    nvn_be_pool_add(pool, psz);
    NvShader *sh = cb_shader(0);
    uint64_t e0 = g_stat_args_enc, p0 = g_stat_args_patch, r0 = g_stat_args_reuse;
    bind_cb0((uint64_t)(uintptr_t)pool, 4096); args_dirty_all(); encode_args(nil, sh, 1, 0);
    uint64_t A = slot(sh, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && table0(sh) == 256, "① 整块编：整块 +%llu（期望 1）、界长表 %u（期望 256）", (unsigned long long)(g_stat_args_enc - e0), table0(sh));
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 8192, 512); encode_args(nil, sh, 1, 0);
    VERIFY(g_stat_args_patch == p0 + 1 && g_stat_args_enc == e0, "② 只换 cb0：打补丁 +%llu、整块 +%llu（期望 1 / 0）", (unsigned long long)(g_stat_args_patch - p0), (unsigned long long)(g_stat_args_enc - e0));
    uint64_t s0 = slot(sh, 0); uint32_t t2 = table0(sh);
    VERIFY(s0 == A + 8192 && t2 == 32, "② 补出来的参数 0 = A + 8192（实差 %lld）、界长表 %u（期望 32）", (long long)(s0 - A), t2);
    r0 = g_stat_args_reuse; id<MTLBuffer> b2 = sh->ab_buf; size_t o2 = sh->ab_off;
    encode_args(nil, sh, 1, 0);
    VERIFY(g_stat_args_reuse == r0 + 1 && sh->ab_buf == b2 && sh->ab_off == o2, "③ 不变再编：复用 +%llu（期望 1）、仍是 ② 那一块", (unsigned long long)(g_stat_args_reuse - r0));
    args_dirty_all(); encode_args(nil, sh, 1, 0);
    VERIFY(slot(sh, 0) == s0 && table0(sh) == t2, "④ 同状态整块重编：参数 0 %s、界长表 %u（与 ② 补出来的 %u 比）", slot(sh, 0) == s0 ? "相同" : "不同", table0(sh), t2);
    NvShader *tu = cb_shader(NVN_RB_TEXU);
    bind_cb0((uint64_t)(uintptr_t)pool, 4096); args_dirty_all(); encode_args(nil, tu, 1, 0);
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 4096, 4096); encode_args(nil, tu, 1, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && g_stat_args_patch == p0, "⑤ 白名单外（带 TEXU）换 cb0：整块 +%llu、打补丁 +%llu（期望 1 / 0）", (unsigned long long)(g_stat_args_enc - e0), (unsigned long long)(g_stat_args_patch - p0));
    encode_args(nil, sh, 1, 0);   // sh 回到当前状态
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 16384, 256); g_args_dirty[1] = 1; encode_args(nil, sh, 1, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && g_stat_args_patch == p0 && slot(sh, 0) == A + 16384, "⑥ 换 cb0 同时别的绑定也变：整块 +%llu、打补丁 +%llu（期望 1 / 0）、参数 0 = A + 16384", (unsigned long long)(g_stat_args_enc - e0), (unsigned long long)(g_stat_args_patch - p0));
    // ⑦ DRV0 / DRV2 驱动常量段按暂存代号缓存：SSBO/句柄未变时强制重编直接复用原 GPU 指针，变更或换暂存代号时立刻失效重建
    NvShader *ds = [NvShader new]; ds->stage = 1; ds->arg_len = 16; strcpy(ds->key, "t_drv_cache");
    ds->rf.nb = 2; ds->rf.b = calloc(2, sizeof *ds->rf.b);
    ds->rf.b[0].kind = NVN_RB_DRV0; ds->rf.b[0].aid = 0; ds->rf.drv_read[0] = 1;
    ds->rf.b[1].kind = NVN_RB_DRV2; ds->rf.b[1].aid = 1; ds->rf.drv_read[2] = 1;
    uint64_t h0 = g_drv_cache_hits;
    args_dirty_all(); encode_args(nil, ds, 1, 0);
    uint64_t d0 = slot(ds, 0), d2 = slot(ds, 1);
    VERIFY(g_drv_cache_hits == h0 && d0 && d2, "⑦a 首次编 DRV0/DRV2：未命中缓存（+%llu）、地址非空", (unsigned long long)(g_drv_cache_hits - h0));
    h0 = g_drv_cache_hits;
    args_dirty_all(); encode_args(nil, ds, 1, 0);
    VERIFY(g_drv_cache_hits == h0 + 2 && slot(ds, 0) == d0 && slot(ds, 1) == d2, "⑦b 绑定未变强制重编：命中缓存 +%llu（期望 2）、复用同一 DRV0/DRV2 地址", (unsigned long long)(g_drv_cache_hits - h0));
    S.ssbo[1][0].addr = (uint64_t)(uintptr_t)pool; S.ssbo[1][0].size = 256; S.tex[1][0] = 42;
    h0 = g_drv_cache_hits;
    args_dirty_all(); encode_args(nil, ds, 1, 0);
    uint64_t d0_new = slot(ds, 0), d2_new = slot(ds, 1);
    VERIFY(g_drv_cache_hits == h0 && d0_new != d0 && d2_new != d2, "⑦c SSBO 与句柄变更后重编：缓存失效（+%llu）、分配新 DRV0/DRV2 地址", (unsigned long long)(g_drv_cache_hits - h0));
    arena_begin(); h0 = g_drv_cache_hits;
    args_dirty_all(); encode_args(nil, ds, 1, 0);
    VERIFY(g_drv_cache_hits == h0, "⑦d 换暂存代号（arena_begin）后重编：缓存失效（+%llu）", (unsigned long long)(g_drv_cache_hits - h0));
  }
    printf("%s t_nvn_args_patch：%u 项，失败 %u\n", failures ? "✗" : "✓", checks, failures); return failures ? 1 : 0;
}
