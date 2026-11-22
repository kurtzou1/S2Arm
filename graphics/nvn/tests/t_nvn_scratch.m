// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 帧暂存块的去留（nvn_mtl.m arena_new，#2062 D-ASC8：一款赛车游戏在 7.5 GB iPad 上单次要 75–188 MB 暂存，块只增不减、超上限等满 2 秒照建，
//   累计到 2.6–3.7 GB 后 Metal 拒绝，FATAL cannot allocate … frame scratch）。期望按规则手写（块都标成 GPU 已用完 = fence ≤ g_done）：
//   ① 最合适复用：空闲块 200 MB 在前、16 MB 在后，要 8 MB → 拿 16 MB 那块（原先先到先得拿 200 MB）
//   ② 超上限先还：空闲块 3 × 300 MB（都小于这次要的），要 400 MB → 从大到小还到「现有 + 400 ≤ 768 MB」：还 2 块，剩 300 MB 空闲 + 新建 400 MB，
//      合计 700 MB（原先不还，合计 1300 MB）；还掉的块从驻留集里拿掉
//   ③ 不超上限不还：空闲 1 × 100 MB，要 200 MB → 新建，空闲块留着
//   反证：arena_new 去掉超上限还块的循环 → ② 合计 1300、红；最合适改回先到先得 → ① 拿到 200 MB、红
#include "../gfx/nvn/nvn_mtl.m"
static int bad;
static void eq(uint64_t got, uint64_t want, const char *what) { printf("%s %s：%llu（期望 %llu）\n", got == want ? "✓" : "✗", what, (unsigned long long)got, (unsigned long long)want); if (got != want) bad++; }
static NvArena *blk(size_t mb) {   // 一块 GPU 已用完的空闲块（同 arena_new 建块的记账）
    NvArena *a = [NvArena new]; a->buf = [g_dev newBufferWithLength:mb << 20 options:MTLResourceStorageModeShared];
    a->gpu = a->buf.gpuAddress; a->cpu = (uint8_t *)a->buf.contents; a->len = a->buf.length; g_arena_bytes += a->len; a->fence = 1; [g_arenas addObject:a]; return a;
}
static void reset(void) { [g_arenas removeAllObjects]; g_arena_bytes = 0; }
int main(void) { @autoreleasepool {
    g_dev = MTLCreateSystemDefaultDevice(); if (!g_dev) { printf("✗ 没有 Metal 设备\n"); return 1; }
    g_arenas = [NSMutableArray array]; g_sub_arenas = [NSMutableArray array]; g_done = 1;
    pthread_mutex_lock(&g_mu);
    blk(200); NvArena *small = blk(16);
    NvArena *got = arena_new(8u << 20); eq(got == small, 1, "① 要 8 MB 拿 16 MB 那块（最合适）"); eq(g_arena_bytes >> 20, 216, "① 合计不变（MB）");
    reset(); blk(300); blk(300); blk(300);
    got = arena_new(400u << 20); eq(got->len >> 20, 400, "② 新建 400 MB"); eq(g_arena_bytes >> 20, 700, "② 合计（MB）"); eq(g_arenas.count, 1, "② 剩空闲块数");
    eq(g_arena_dropped, 2, "② 还掉的块数");
    reset(); uint64_t dropped = g_arena_dropped; blk(100);
    got = arena_new(200u << 20); eq(got->len >> 20, 200, "③ 新建 200 MB"); eq(g_arenas.count, 1, "③ 空闲块留着"); eq(g_arena_dropped - dropped, 0, "③ 没还块");
    pthread_mutex_unlock(&g_mu);
    printf("%s t_nvn_scratch：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}}
