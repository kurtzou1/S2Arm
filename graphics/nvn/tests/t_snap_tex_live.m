// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 快照恢复建贴图前判内存池还在不在（D-S68N：iPhone 0.6.9 恢复时 tex_mtl → tex_rd_size 读 t->pool->mem，池对象所在页已不可访问，两局同址 SIGBUS）。
//   含生产 nvn_mtl.m 源码（同 t_res_site.m 写法）。期望按语义手写：
//   ① 池对象在一页 PROT_NONE 上：判不活、不崩（原先直接读它的 magic / mem 就是 SIGBUS）；② 池对象可读但 magic 已被收尾清成 0：不活；
//   ③ 池对象可读、magic = POOL：活；④ 不在池里的贴图（pool 为空）：照旧交给 tex_mtl（活）。不活的计数 = 2
#ifndef SNAP_TEX_LIVE_SOURCE
#define SNAP_TEX_LIVE_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include SNAP_TEX_LIVE_SOURCE
#include <sys/mman.h>

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)

int main(void) { @autoreleasepool {
    size_t pg = (size_t)getpagesize();
    uint8_t *page = mmap(NULL, 2 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (page == MAP_FAILED) { printf("FAIL mmap\n"); return 1; }
    pool_t *dead = (pool_t *)page, *live = (pool_t *)(page + pg);
    memset(page, 0, 2 * pg);
    dead->magic = MAGIC('P', 'O', 'O', 'L'); live->magic = MAGIC('P', 'O', 'O', 'L');
    static uint8_t storage[4096];
    tex_t t = {0}; t.mem = storage;
    g_snap_dead_tex = 0;
    mprotect(page, pg, PROT_NONE);   // 游戏把池所在内存撤成不可访问
    t.pool = dead; CHECK(!snap_tex_live(&t), "① 池对象在不可访问的页上：判不活、不读它（原先 SIGBUS）");
    mprotect(page, pg, PROT_READ | PROT_WRITE); dead->magic = 0;   // 池还在可读内存里、已收尾（nvnMemoryPoolFinalize 清 magic）
    CHECK(!snap_tex_live(&t), "② 池已收尾（magic 0）：不活");
    t.pool = live; CHECK(snap_tex_live(&t), "③ 池对象可读、magic = POOL：活");
    t.pool = NULL; CHECK(snap_tex_live(&t), "④ 不在池里的贴图：照旧交给 tex_mtl");
    CHECK(g_snap_dead_tex == 2, "不活的计数 %d（期望 2）", g_snap_dead_tex);
    printf("%s t_snap_tex_live：%u 项，失败 %u\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
} }
