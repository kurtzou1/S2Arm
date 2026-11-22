// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 顶点按需转换记下的索引范围（ix_range）在排进 GPU 写入时失效（vc_gpu_write）：按 1 MB 区域的反向索引只看写入碰到的区域里的范围，不随表大小整表扫（#2004）。
//   期望手写：① 精确判重叠——与范围相交的写入标失效，同一 1 MB 区域里不相交的不标；② 跨 3 个 1 MB 区域的范围，写到任一区域里与它相交处都标；
//   ③ 表里另有 30000 条范围、都在别的区域：一次写入看过的范围数只等于它所在区域那几条（2），不是 30000；④ 整表清空后桶也空，再写不碰已释放的条目
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define CHECK(x, ...) do { checks++; int ok = !!(x); failures += !ok; printf("%s ", ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static ir_ent *put(uint64_t ibuf, int32_t count, uint64_t n) {
    ir_key k = {ibuf, count, 1}; ir_ent *e = calloc(1, sizeof *e); nvn_hm_put(&g_ir, &k, e); e->lo = ibuf; e->n = n; ir_rgn_add(e); return e; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const uint64_t M = 1ull << 20, B = 0x7100000000ull;
    ir_ent *a = put(B + 0x1000, 100, 0x200), *b = put(B + 0x8000, 100, 0x200);   // 同一 1 MB 区域的两条
    vc_gpu_write(B + 0x1100, 0x10);
    CHECK(a->gpuw && !b->gpuw, "① 写 [0x1100, +0x10) 与 a 相交、与同区域的 b 不相交：a 失效 %d、b 失效 %d", a->gpuw, b->gpuw);
    ir_ent *w = put(B + 10 * M + 0xF0000, 200, 2 * M + 0x20000);   // 跨第 10、11、12 个 1 MB 区域
    vc_gpu_write(B + 12 * M + 0x100, 4);
    CHECK(w->gpuw, "② 跨 3 个区域的范围，写到第 3 个区域里相交处：失效 %d", w->gpuw);
    for (int i = 0; i < 30000; i++) put(B + 100 * M + (uint64_t)i * 0x1000, 1000 + i, 0x100);   // 别的区域里 30000 条
    uint64_t s0 = g_vc_scanned; vc_gpu_write(B + 0x9000, 4);
    CHECK(g_vc_scanned - s0 == 2, "③ 表里 %u 条，一次写入看过的范围数 %llu（期望 2：只看所在区域的 a、b）", g_ir.n, (unsigned long long)(g_vc_scanned - s0));
    ir_clear();
    s0 = g_vc_scanned; vc_gpu_write(B + 0x1000, 0x200); vc_gpu_write(B + 100 * M, 0x100000);
    CHECK(!g_ir.n && !g_ir_rgn.n && g_vc_scanned == s0, "④ 清空后条目 %u、区域桶 %u、再写看过 %llu 条（期望 0 / 0 / 0）", g_ir.n, g_ir_rgn.n, (unsigned long long)(g_vc_scanned - s0));
    printf("%s t_nvn_vc_write_index: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures); return failures != 0;
} }
