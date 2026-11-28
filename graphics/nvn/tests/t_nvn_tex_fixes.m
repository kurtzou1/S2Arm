// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 直连 Metal 后端贴图根修回归（nvn_mtl.m）：真实 Metal GPU + 公开 NVN 对象。期望值手写，不由被测实现推出：
//   ① TARGET_BUFFER（未设 IMAGE）默认带 MTLTextureUsageShaderWrite：绑进图像槽排升级（img_wr_note / img_wr_upgrade）后仍是同一对象（没被换）；改前无 ShaderWrite 会被换成升级后的新对象
//   ② 同存储双 tex_cpu_content NvPkg（[alias] split）：GPU 写其中一个（Copy / Clear）后，另一个同存储对象读到新内容
//   ③ 32-bit 整数 TextureBuffer 绑到 float 声明图像/纹理槽（img_fit / tex_float_fit）：零拷贝返回同缓冲的 R32Float 视图
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>

extern void *h_nvnBootstrapLoader(const char *name);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *api(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))

enum { POOL_SIZE = 16 << 20 };
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static uint8_t *memory;

static void fault(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static void begin_cmd(void) { API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, 1 << 20); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit_cmd(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(!mtl_last_commit_error());
}

static void test_tbuf_shader_write(void) {
    size_t off = 2 << 20;
    uint32_t *p = (uint32_t *)(memory + off);
    for (int i = 0; i < 64; i++) p[i] = 0x100u + (uint32_t)i;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_BUFFER);
    API(nvnTextureBuilderSetSize1D)(&b, 64);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R32UI);
    API(nvnTextureBuilderSetFlags)(&b, 0);   // 故意不设 NVN_TEXTURE_FLAGS_IMAGE
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture t = {0}; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    nvn_be_reg_tex(12, (const tex_t *)&t, NULL);
    nvn_be_sub_begin();
    id<MTLTexture> m1 = tex_mtl((const tex_t *)&t);
    os_unfair_lock_lock(&g_rmu); img_wr_note(12); os_unfair_lock_unlock(&g_rmu);
    img_wr_upgrade();   // 图像槽写入前的升级：缺 ShaderWrite 的会被 tex_upgrade 换成新对象
    id<MTLTexture> m2 = tex_mtl((const tex_t *)&t);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    CHECK(m1 != nil && (m1.usage & MTLTextureUsageShaderWrite) != 0,
          "① TARGET_BUFFER R32UI（未设 IMAGE）默认带 ShaderWrite：usage=%#lx", (unsigned long)m1.usage);
    CHECK(m1 != nil && m1 == m2,
          "① 排进图像写升级后仍是同一对象、没被换（m1=%p m2=%p）", (__bridge void *)m1, (__bridge void *)m2);
    API(nvnTextureFinalize)(&t);
}

static void test_dual_nvpkg_alias_split(void) {
    enum { N = 4, READ_OFF = 1 << 20 };
    size_t off = 3 << 20;
    // 填满 half 1.0 (0x3C00)
    uint16_t *hp = (uint16_t *)(memory + off);
    for (size_t i = 0; i < (64u << 10) / 2; i++) hp[i] = 0x3C00;

    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_3D);
    API(nvnTextureBuilderSetSize3D)(&b, N, N, N);
    API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA16F);
    API(nvnTextureBuilderSetFlags)(&b, 0);   // 两者皆走 tex_cpu_content -> NvPkg
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);

    NVNtexture ta = {0}, tb = {0};
    REQUIRE(API(nvnTextureInitialize)(&ta, &b));
    REQUIRE(API(nvnTextureInitialize)(&tb, &b));

    // 先把 ta、tb 都解析成 NvPkg
    nvn_be_sub_begin();
    id<MTLTexture> ma = tex_mtl((const tex_t *)&ta);
    id<MTLTexture> mb = tex_mtl((const tex_t *)&tb);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(ma != nil && mb != nil);
    REQUIRE([tex_get(((const tex_t *)&ta)->serial) isKindOfClass:[NvPkg class]]);
    REQUIRE([tex_get(((const tex_t *)&tb)->serial) isKindOfClass:[NvPkg class]]);

    // 通过 ta 做 GPU 清屏（0.25, 0.5, 0.75, 1.0）
    static const float clr[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    NVNcopyRegion whole = {0, 0, 0, N, N, N};
    begin_cmd();
    API(nvnCommandBufferClearTexture)(&commands, &ta, NULL, &whole, clr, 15);
    submit_cmd();

    // 通过 tb 读回，必须看到 GPU 写进 ta 的颜色（half 0.25 = 0x3400, 0.5 = 0x3800, 0.75 = 0x3A00, 1.0 = 0x3C00）
    memset(memory + READ_OFF, 0, N * N * N * 8);
    NVNbufferAddress dst = API(nvnMemoryPoolGetBufferAddress)(&pool) + READ_OFF;
    begin_cmd();
    API(nvnCommandBufferCopyTextureToBuffer)(&commands, &tb, NULL, &whole, dst, 0);
    submit_cmd();

    const uint16_t *out = (const uint16_t *)(memory + READ_OFF);
    CHECK(out[0] == 0x3400 && out[1] == 0x3800 && out[2] == 0x3A00 && out[3] == 0x3C00,
          "② 同存储双 NvPkg（tex_cpu_content）：GPU 写 ta 后 tb 读到新色 expected=(0x3400,0x3800,0x3a00,0x3c00) actual=(%#x,%#x,%#x,%#x)",
          out[0], out[1], out[2], out[3]);

    API(nvnTextureFinalize)(&ta);
    API(nvnTextureFinalize)(&tb);
}

static void test_dual_nvpkg_ft_written(void) {
    enum { N = 4, READ_OFF = 1 << 20 };
    size_t off = 5 << 20;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_3D);
    API(nvnTextureBuilderSetSize3D)(&b, N, N, N);
    API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA16F);
    API(nvnTextureBuilderSetFlags)(&b, 0);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);

    NVNtexture ta = {0}, tb = {0};
    REQUIRE(API(nvnTextureInitialize)(&ta, &b));
    REQUIRE(API(nvnTextureInitialize)(&tb, &b));
    // 初始化之后 CPU 写池页（触发 nvn_ft_written 路径，而非 tex_cpu_content）
    uint16_t *hp = (uint16_t *)(memory + off);
    for (size_t i = 0; i < (64u << 10) / 2; i++) hp[i] = 0x3C00;

    nvn_be_sub_begin();
    id<MTLTexture> ma = tex_mtl((const tex_t *)&ta);
    id<MTLTexture> mb = tex_mtl((const tex_t *)&tb);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(ma != nil && mb != nil);
    REQUIRE([tex_get(((const tex_t *)&ta)->serial) isKindOfClass:[NvPkg class]]);
    REQUIRE([tex_get(((const tex_t *)&tb)->serial) isKindOfClass:[NvPkg class]]);

    static const float clr[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    NVNcopyRegion whole = {0, 0, 0, N, N, N};
    begin_cmd();
    API(nvnCommandBufferClearTexture)(&commands, &ta, NULL, &whole, clr, 15);
    submit_cmd();

    memset(memory + READ_OFF, 0, N * N * N * 8);
    NVNbufferAddress dst = API(nvnMemoryPoolGetBufferAddress)(&pool) + READ_OFF;
    begin_cmd();
    API(nvnCommandBufferCopyTextureToBuffer)(&commands, &tb, NULL, &whole, dst, 0);
    submit_cmd();

    const uint16_t *out = (const uint16_t *)(memory + READ_OFF);
    CHECK(out[0] == 0x3400 && out[1] == 0x3800 && out[2] == 0x3A00 && out[3] == 0x3C00,
          "④ 同存储双 NvPkg（nvn_ft_written）：GPU 写 ta 后 tb 读到新色 expected=(0x3400,0x3800,0x3a00,0x3c00) actual=(%#x,%#x,%#x,%#x)",
          out[0], out[1], out[2], out[3]);

    API(nvnTextureFinalize)(&ta);
    API(nvnTextureFinalize)(&tb);
}

static void test_tbuf_int_as_float_fit(void) {
    size_t off = 4 << 20;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_BUFFER);
    API(nvnTextureBuilderSetSize1D)(&b, 64);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R32UI);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture t = {0}; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    nvn_be_reg_tex(10, (const tex_t *)&t, NULL);

    nvn_be_sub_begin();
    id<MTLTexture> mt = tex_mtl((const tex_t *)&t); REQUIRE(mt != nil);
    os_unfair_lock_lock(&g_rmu);
    uint64_t rid1 = 0, rid2 = 0;
    id<MTLTexture> iv = img_fit(10, mt, NVN_DPF_FLOAT, &rid1);
    id<MTLTexture> fv = tex_float_fit(10, mt, &rid2);
    os_unfair_lock_unlock(&g_rmu);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));

    CHECK(iv != nil && iv.pixelFormat == MTLPixelFormatR32Float && iv.buffer == mt.buffer && iv.bufferOffset == mt.bufferOffset && rid1 != 0,
          "③ img_fit(R32UI TextureBuffer, FLOAT)：返回同缓冲 R32Float 视图（iv=%p pf=%lu）", (__bridge void *)iv, (unsigned long)iv.pixelFormat);
    CHECK(fv != nil && fv.pixelFormat == MTLPixelFormatR32Float && fv.buffer == mt.buffer && fv.bufferOffset == mt.bufferOffset && rid2 != 0,
          "③ tex_float_fit(R32UI TextureBuffer)：返回同缓冲 R32Float 视图（fv=%p pf=%lu）", (__bridge void *)fv, (unsigned long)fv.pixelFormat);
    API(nvnTextureFinalize)(&t);
}

static void test_dual_nvpkg_ft_flush(void) {
    // ⑤ ft_flush / nvn_ft_poll 经 nvn_be_tex_cpu_inferred 标出的 NvPkg，在同存储另一张共享贴图被 GPU 写后并入共享贴图
    const int W = 64, H = 64;
    size_t off = 5 << 20, src_off = (5 << 20) + 0x40000;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, W, H);
    API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA_DXT1);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    size_t sz = API(nvnTextureBuilderGetStorageSize)(&b);
    memset(memory + off, 0, sz);

    NVNtexture ta = {0}, tb = {0};
    REQUIRE(API(nvnTextureInitialize)(&ta, &b));
    API(nvnMemoryPoolFlushMappedRange)(&pool, (ptrdiff_t)off, (ptrdiff_t)sz);   // ft_flush → nvn_be_tex_cpu_inferred

    nvn_be_sub_begin();
    id<MTLTexture> ma = tex_mtl((const tex_t *)&ta);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(ma != nil && [tex_get(((const tex_t *)&ta)->serial) isKindOfClass:[NvPkg class]]);

    REQUIRE(API(nvnTextureInitialize)(&tb, &b));
    const size_t lin_sz = (W / 4) * (H / 4) * 8;
    memset(memory + src_off, 0x5A, lin_sz);
    NVNbufferAddress base = API(nvnMemoryPoolGetBufferAddress)(&pool);
    NVNcopyRegion whole = {0, 0, 0, W, H, 1};
    begin_cmd();
    API(nvnCommandBufferCopyBufferToTexture)(&commands, base + src_off, &tb, NULL, &whole, 0);
    submit_cmd();

    const size_t read_off = 1 << 20;
    memset(memory + read_off, 0, lin_sz);
    begin_cmd();
    API(nvnCommandBufferCopyTextureToBuffer)(&commands, &ta, NULL, &whole, base + read_off, 0);
    submit_cmd();

    size_t bad = 0;
    for (size_t i = 0; i < lin_sz; i++) bad += (memory[read_off + i] != 0x5A);
    CHECK(bad == 0, "⑤ ft_flush 推断的 NvPkg 在同存储 GPU 写后并入共享贴图（bad=%zu/%zu）", bad, lin_sz);

    API(nvnTextureFinalize)(&ta);
    API(nvnTextureFinalize)(&tb);
}

static void test_storage_upload_gpw_and_nvpkg_ph(void) {
    // ⑥a CopyBufferToTexture 后 storage_move 不得提前 gpw_unmark 清掉 GPU 归属
    const int SIDE = 8;
    size_t off1 = 6 << 20, off2 = (6 << 20) + 0x20000, src_off = (6 << 20) + 0x40000;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, SIDE, SIDE);
    API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
    size_t sz = API(nvnTextureBuilderGetStorageSize)(&b);

    memset(memory + off1, 0, sz);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off1);
    NVNtexture tg = {0}; REQUIRE(API(nvnTextureInitialize)(&tg, &b));
    memset(memory + src_off, 0x33, SIDE * SIDE * 4);
    NVNbufferAddress base = API(nvnMemoryPoolGetBufferAddress)(&pool);
    NVNcopyRegion whole = {0, 0, 0, SIDE, SIDE, 1};
    // 编码 CopyBufferToTexture 但先不提交 GPU：t->mem 尚未被 move_bytes 写入，gpw_stale 必须仍标记为陈旧
    nvn_be_sub_begin();
    p_copy_b2t cb2t = {0};
    cb2t.src = base + src_off; cb2t.tex = (const tex_t *)&tg; cb2t.r = whole;
    copy_b2t(&cb2t);
    uint64_t *runs = NULL, stale_b = 0;
    int nr = gpw_stale(((const tex_t *)&tg)->mem, ((const tex_t *)&tg)->L.size, &runs, &stale_b);
    free(runs);
    uint64_t fg = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fg, 10000000000ull));
    CHECK(nr > 0 && stale_b > 0,
          "⑥a CopyBufferToTexture 编码期（move_bytes 尚未执行）不提前 gpw_unmark（nr=%d stale_b=%llu）", nr, (unsigned long long)stale_b);
    API(nvnTextureFinalize)(&tg);

    // ⑥b NvPkg 贴图经 CopyBufferToTexture 后，texture_storage_upload 不改写 t->mem 破坏 pk->ph，同页邻居 CPU 写不触发误局部重传
    memset(memory + off2, 0x11, sz);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off2);
    NVNtexture tp = {0}; REQUIRE(API(nvnTextureInitialize)(&tp, &b));
    API(nvnMemoryPoolFlushMappedRange)(&pool, (ptrdiff_t)off2, (ptrdiff_t)sz);
    nvn_be_sub_begin();
    id<MTLTexture> mp = tex_mtl((const tex_t *)&tp);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(mp != nil && [tex_get(((const tex_t *)&tp)->serial) isKindOfClass:[NvPkg class]]);
    // 等待后台首传页哈希落地（PH_OK）
    NvPkg *pk = tex_get(((const tex_t *)&tp)->serial);
    for (int i = 0; i < 200 && pk->ph && !ph_usable(pk->ph, pk->nph); i++) usleep(1000);
    REQUIRE(pk->ph && ph_usable(pk->ph, pk->nph));

    memset(memory + src_off, 0x77, SIDE * SIDE * 4);
    begin_cmd();
    API(nvnCommandBufferCopyBufferToTexture)(&commands, base + src_off, &tp, NULL, &whole, 0);
    submit_cmd();

    uint64_t partial_before = g_pkg_partial;
    memory[off2 + sz + 64] = 0xBB;   // 同 16 KB 宿主页邻居 CPU 写
    const size_t read_off = 1 << 20;
    memset(memory + read_off, 0, SIDE * SIDE * 4);
    begin_cmd();
    API(nvnCommandBufferCopyTextureToBuffer)(&commands, &tp, NULL, &whole, base + read_off, 0);
    submit_cmd();

    size_t bad = 0;
    for (size_t i = 0; i < SIDE * SIDE * 4; i++) bad += (memory[read_off + i] != 0x77);
    CHECK(g_pkg_partial == partial_before && bad == 0,
          "⑥b NvPkg CopyBufferToTexture 后同页邻居写不误触发局部重传且纹素保持 0x77（partial +%llu bad=%zu）",
          (unsigned long long)(g_pkg_partial - partial_before), bad);
    API(nvnTextureFinalize)(&tp);
}

static void test_draw_img_prescan_int_as_float(void) {
    size_t off = 9 << 20;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, 8, 8);
    API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R32UI);
    API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_COMPRESSIBLE);   // 无 IMAGE：初始无 ShaderWrite / PixelFormatView
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture t = {0}; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    nvn_be_reg_tex(30, (const tex_t *)&t, NULL);

    nvn_be_sub_begin();
    id<MTLTexture> m0 = tex_mtl((const tex_t *)&t);
    REQUIRE(m0 != nil);
    S.img[1][0] = 30;
    NvShader *fs = [NvShader new]; fs->stage = 1; fs->rf.nb = 1; fs->rf.b = calloc(1, sizeof *fs->rf.b);
    fs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .dtt = (uint8_t)MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .rw = 1};
    NvShader *noimg = [NvShader new]; noimg->stage = 1; noimg->rf.nb = 0;

    img_wr_prescan(noimg, 1);
    img_wr_prescan(fs, 1);
    int had_wr = g_imwr_npend > 0, had_fit = g_imfit_npend > 0;
    if (g_imwr_npend) img_wr_upgrade();
    if (g_imfit_npend) img_fit_upgrade();
    id<MTLTexture> m1 = tex_mtl((const tex_t *)&t);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));

    CHECK(noimg->has_img == 1 && fs->has_img == 2,
          "⑦a img_wr_prescan has_img 缓存：无图像=%u（期望 1）、有图像=%u（期望 2）", noimg->has_img, fs->has_img);
    CHECK(had_wr && had_fit && m1 != nil && (m1.usage & MTLTextureUsageShaderWrite) && (m1.usage & MTLTextureUsagePixelFormatView),
          "⑦b 片元 NVN_RB_IMG R32UI→float 预检升级：queued wr=%d fit=%d，升级后 usage=%#lx",
          had_wr, had_fit, (unsigned long)m1.usage);
    S.img[1][0] = 0;
    API(nvnTextureFinalize)(&t);
}

static void test_x32_stencil_swizzle_and_override(void) {
    size_t off = 10 << 20;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, 4, 4);
    API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_DEPTH32F_STENCIL8);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture dtex = {0}; REQUIRE(API(nvnTextureInitialize)(&dtex, &b));

    API(nvnTextureBuilderSetDepthStencilMode)(&b, NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL);
    NVNtexture stex = {0}; REQUIRE(API(nvnTextureInitialize)(&stex, &b));   // UE4 CustomStencil 模式：同存储、不设 Swizzle

    NVNtextureView sview; API(nvnTextureViewSetDefaults)(&sview);
    API(nvnTextureViewSetDepthStencilMode)(&sview, NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL);
    API(nvnTextureViewSetSwizzle)(&sview, NVN_TEXTURE_SWIZZLE_ZERO, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_ZERO, NVN_TEXTURE_SWIZZLE_ONE);

    nvn_be_reg_tex(32, (const tex_t *)&stex, NULL);
    nvn_be_reg_tex(33, (const tex_t *)&dtex, (const view_t *)&sview);

    begin_cmd();
    API(nvnCommandBufferSetRenderTargets)(&commands, 0, NULL, NULL, &dtex, NULL);
    API(nvnCommandBufferSetScissor)(&commands, 0, 0, 4, 4);
    API(nvnCommandBufferClearDepthStencil)(&commands, 0.5f, 1, 0x37, 0xff);
    submit_cmd();

    nvn_be_sub_begin();
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> mv_default = (__bridge id<MTLTexture>)tex_by_id_ptr(32);
    id<MTLTexture> mv_explicit = (__bridge id<MTLTexture>)tex_by_id_ptr(33);
    os_unfair_lock_unlock(&g_rmu);
    REQUIRE(mv_default && mv_explicit);

    // 真 Metal 计算核经 texture2d<float>.read() + as_type<uint4> 读四通道，验证 .r/.g/.b/.a
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void rd(texture2d<float> t [[texture(0)]], device uint4 *out [[buffer(0)]]) { out[0] = as_type<uint4>(t.read(uint2(0, 0))); }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&err]; REQUIRE(lib);
    id<MTLComputePipelineState> cps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rd"] error:&err]; REQUIRE(cps);
    id<MTLBuffer> ob = [g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    memset(ob.contents, 0xff, 32);
    // 直接通过 Metal3 / Metal4 独立队列跑一次读回确认真实像素值
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));

    id<MTLCommandQueue> q = [g_dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> c1 = [cb computeCommandEncoder];
    [c1 setComputePipelineState:cps];
    [c1 setTexture:mv_default atIndex:0]; [c1 setBuffer:ob offset:0 atIndex:0];
    [c1 dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [c1 setTexture:mv_explicit atIndex:0]; [c1 setBuffer:ob offset:16 atIndex:0];
    [c1 dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [c1 endEncoding]; [cb commit]; [cb waitUntilCompleted];
    REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    const uint32_t *res = (const uint32_t *)ob.contents;
    CHECK(mv_default.pixelFormat == MTLPixelFormatX32_Stencil8 &&
          mv_default.swizzle.red == MTLTextureSwizzleRed && mv_default.swizzle.green == MTLTextureSwizzleRed &&
          mv_default.swizzle.blue == MTLTextureSwizzleRed && mv_default.swizzle.alpha == MTLTextureSwizzleRed &&
          res[0] == 0x37u && res[1] == 0x37u && res[2] == 0x37u && res[3] == 0x37u,
          "⑧a X32_Stencil8 默认复制四通道 (R,R,R,R)：GPU 读出 (%#x,%#x,%#x,%#x)", res[0], res[1], res[2], res[3]);
    CHECK(mv_explicit.pixelFormat == MTLPixelFormatX32_Stencil8 &&
          res[4] == 0u && res[5] == 0x37u && res[6] == 0u && res[7] == 1u,
          "⑧b 显式 SetSwizzle(0,R,0,1) 不被覆盖：GPU 读出 (%#x,%#x,%#x,%#x)", res[4], res[5], res[6], res[7]);
    API(nvnTextureFinalize)(&stex);
    API(nvnTextureFinalize)(&dtex);
}

static void test_tbuf_atomic_and_ghost_view_reuse(void) {
    size_t off = 11 << 20;
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_BUFFER);
    API(nvnTextureBuilderSetSize1D)(&b, 64);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_R32UI);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off);
    NVNtexture t = {0}; REQUIRE(API(nvnTextureInitialize)(&t, &b));
    nvn_be_reg_tex(34, (const tex_t *)&t, NULL);
    API(nvnTextureFinalize)(&t);

    nvn_be_sub_begin();
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> m1 = (__bridge id<MTLTexture>)tex_by_id_ptr(34);
    os_unfair_lock_unlock(&g_rmu);
    REQUIRE(m1 != nil);
    uint64_t up0 = g_pfv_upgrades;
    S.img[5][0] = 34;
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->rf.has_atomic_image = 1; cs->rf.nb = 1;
    cs->rf.b = calloc(1, sizeof *cs->rf.b);
    cs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 0, .dtt = (uint8_t)MTLTextureTypeTextureBuffer, .dpf = NVN_DPF_UINT, .rw = 1, .atomic_image = 1};
    int atomic_ok = img_atomic_prepare(cs, 5);
    uint64_t up1 = g_pfv_upgrades;
    int atomic_ok2 = img_atomic_prepare(cs, 5);
    uint64_t up2 = g_pfv_upgrades;
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> m_atomic = (__bridge id<MTLTexture>)tex_by_id_ptr(34);
    os_unfair_lock_unlock(&g_rmu);
    S.img[5][0] = 0;
    free(cs->rf.b); cs->rf.b = NULL;
    REQUIRE(nvn_be_wait(nvn_be_sub_commit(), 10000000000ull));

    // 挤掉幽灵环：在独立提交里解析 NGHOST + 32 个其它已销毁缓冲纹理，使 34 号的 serial 出环
    nvn_be_sub_begin();
    for (int i = 0; i < NGHOST + 32; i++) {
        API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)(off + 4096 + (size_t)i * 256));
        NVNtexture x = {0}; REQUIRE(API(nvnTextureInitialize)(&x, &b));
        tex_t sx = *(const tex_t *)&x;
        API(nvnTextureFinalize)(&x);
        REQUIRE(tex_mtl(&sx) != nil);
    }
    REQUIRE(nvn_be_wait(nvn_be_sub_commit(), 10000000000ull));

    nvn_be_sub_begin();
    uint64_t gen_before = g_ser_gen;
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> m2 = (__bridge id<MTLTexture>)tex_by_id_ptr(34);
    os_unfair_lock_unlock(&g_rmu);
    uint64_t gen_after_lookup = g_ser_gen;
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull));

    // main 70dd12655：R32 整数可写缓冲贴图建时就带原子与格式视图用途，首次原子也不用升级（0 次，不是 1 次）
    CHECK(atomic_ok && atomic_ok2 && tex_atomic_usage(m_atomic) && up1 == up0 && up2 == up1,
          "⑨a TARGET_BUFFER R32UI 建时就带原子用途、全程零升级（upgrades %llu→%llu→%llu）",
          (unsigned long long)up0, (unsigned long long)up1, (unsigned long long)up2);
    CHECK(m2 == m_atomic && tex_atomic_usage(m2) && gen_after_lookup == gen_before && g_ser_gen == gen_before,
          "⑨b 幽灵环挤出后仍复用已登记 TARGET_BUFFER 视图（m1=%p m2=%p ser_gen %llu→%llu→%llu）",
          (__bridge void *)m_atomic, (__bridge void *)m2, (unsigned long long)gen_before,
          (unsigned long long)gen_after_lookup, (unsigned long long)g_ser_gen);
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct sigaction sa = {0}; sa.sa_sigaction = fault; sa.sa_flags = SA_SIGINFO;
    sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);

    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
    REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(!posix_memalign((void **)&memory, 65536, POOL_SIZE)); memset(memory, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
    REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);

    test_tbuf_shader_write();
    test_dual_nvpkg_alias_split();
    test_dual_nvpkg_ft_written();
    test_tbuf_int_as_float_fit();
    test_dual_nvpkg_ft_flush();
    test_storage_upload_gpw_and_nvpkg_ph();
    test_draw_img_prescan_int_as_float();
    test_x32_stencil_swizzle_and_override();
    test_tbuf_atomic_and_ghost_view_reuse();

    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&pool); API(nvnDeviceFinalize)(&device); free(memory);
    printf("%s t_nvn_tex_fixes: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}}
