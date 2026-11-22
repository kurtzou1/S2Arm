// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// 同一张贴图同时挂在两个颜色槽（nvn_mtl.m rt_dup_slot / rtdup_attach / rtdup_flush）：后一个槽画进影子，遍末把它写过的通道并回原贴图。
//   现场：程序 010051F0207B2000 的诊断里「color slot %d holds the same texture as an earlier slot」红 99 行，90 行是 1 号槽只写透明度（掩码 0x8）、
//   0 号槽写 RGB——原先 1 号槽干脆不接，透明度整遍丢。
// 构造（期望按语义手写，与被测实现无关）：一张 4x4 RGBA8 贴图，初值每个像素 (10,20,30,40)。一遍里同时绑到 0 号、1 号颜色槽；一次全屏绘制，
//   0 号写掩码 RGB、输出 (100,110,120,130)/255，1 号写掩码 A、输出 (200,210,220,230)/255。Switch 上两个槽各写各的通道，
//   期望整张贴图 16 个像素 = (100,110,120,230)：RGB 来自 0 号（130 被掩掉），A 来自 1 号（200,210,220 被掩掉）。
// 反证：改前 1 号槽不挂（rp_begin_ex 里 `if (rt_dup_slot(&R.rt, i)) continue;`），透明度保持初值 40 → 读回 (100,110,120,40)，① 失败。
//   Metal 3 / Metal 4 两种后端都跑（runtime/tests/mk/nvn_rt_dup.mk：NXGAL_BE=mtl4 / mtl3）。
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { W = 4 };

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[i], 0, 1); }\n"
"struct O { float4 a [[color(0)]]; float4 b [[color(1)]]; };\n"
"fragment O two() { O o; o.a = float4(100, 110, 120, 130) / 255.0; o.b = float4(200, 210, 220, 230) / 255.0; return o; }\n";

static NvShader *shader(id<MTLLibrary> lib, NSString *name, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:name]; REQUIRE(s->fn);
    strlcpy(s->key, stage ? "cccccccccccccccc_d" : "dddddddddddddddd_d", sizeof s->key);
    s->rf.pos_attr = -1; s->rf.has_user = stage ? 2 : 1;
    if (stage) { s->rf.color_known = 1; s->rf.color_mask = 3; }
    return s;
}
static void put(id<MTLTexture> t, const uint8_t px[4]) {   // every pixel = px, written on a queue of its own (the texture may be private)
    id<MTLBuffer> b = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; REQUIRE(b);
    for (int i = 0; i < W * W; i++) memcpy((uint8_t *)b.contents + 4 * i, px, 4);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:W * 4 sourceBytesPerImage:W * W * 4 sourceSize:MTLSizeMake(W, W, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
}
static void get(id<MTLTexture> t, uint8_t *out) {
    id<MTLBuffer> b = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; REQUIRE(b);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    memcpy(out, b.contents, W * W * 4);
}
static void finish(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    char map[] = "/tmp/t_rt_dup_map_XXXXXX", user[] = "/tmp/t_rt_dup_user_XXXXXX";
    int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd); fd = mkstemp(user); REQUIRE(fd >= 0); close(fd);
    setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    setenv("DM_NVN_TBDR", "0", 1); mtl_init(); printf("BACKEND Metal%d\n", g_m3 ? 3 : 4);
    const op_hdr empty = {OP_END, sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *error = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    if (!lib) fprintf(stderr, "MSL %s\n", error.localizedDescription.UTF8String); REQUIRE(lib);
    NvProg *program = [NvProg new]; program->sh[0] = shader(lib, @"triangle", 0); program->sh[1] = shader(lib, @"two", 1);
    prog_t p = {.magic = MAGIC('P','R','O','G'), .serial = nvn_new_serial()}; serial_put(p.serial, program);
    uint8_t *memory = NULL; REQUIRE(!posix_memalign((void **)&memory, 65536, 1 << 20));
    const uint8_t init[4] = {10, 20, 30, 40};
    for (int i = 0; i < (1 << 20) / 4; i++) memcpy(memory + 4 * i, init, 4);   // guest bytes hold the same pixels (any layout: every texel is equal)
    pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
    *pool = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = 1 << 20}; nvn_be_pool_add(memory, 1 << 20);
    tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T','E','X',0); t.serial = nvn_new_serial();
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .flags = NVN_TEXTURE_FLAGS_IMAGE, .width = W, .height = W, .depth = 1, .levels = 1};
    t.pool = pool; t.off = 0; t.mem = memory; nvn_tex_layout(&t.d, &t.L); nvn_be_tex_init(&t); REQUIRE(tex_mtl(&t));
    put(tex_mtl(&t), init);

    uint64_t made0 = g_rtdup_made, merged0 = g_rtdup_merged;
    nvn_be_sub_begin(); state_reset(); S.prog = &p;
    rp_flush(); memset(&R.rt, 0, sizeof R.rt); R.rt.n = 2; R.rt.color[0] = &t; R.rt.color[1] = &t; R.has_rt = 1; g_pso_dirty = 1; args_dirty_all();
    S.chmask.mask = 0x7u | (0x8u << 4);   // slot 0: RGB, slot 1: A
    R.has_sc = 0;
    const p_draw d = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; draw(&d, NULL);
    finish();
    uint8_t px[W * W * 4]; get(tex_mtl(&t), px); int good = 0;
    for (int i = 0; i < W * W; i++) good += px[4 * i] == 100 && px[4 * i + 1] == 110 && px[4 * i + 2] == 120 && px[4 * i + 3] == 230;
    CHECK(good == W * W, "① 0 号槽写 RGB (100,110,120)、1 号槽（同一张贴图）写 A (230)：期望 16 个像素 = (100,110,120,230)，实测 %d / 16（第 0 个 %d,%d,%d,%d）",
          good, px[0], px[1], px[2], px[3]);
    CHECK(g_rtdup_made > made0 && g_rtdup_merged == merged0 + 1, "② 1 号槽经影子画、遍末并回一次（影子新建 %llu、并回 %llu）",
          (unsigned long long)(g_rtdup_made - made0), (unsigned long long)(g_rtdup_merged - merged0));
    unlink(map); unlink(user);
} printf("%s t_nvn_rt_dup: %u checks, %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4); return failures ? 1 : 0; }
