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
    test_tbuf_int_as_float_fit();

    API(nvnCommandBufferFinalize)(&commands); API(nvnQueueFinalize)(&queue);
    API(nvnMemoryPoolFinalize)(&pool); API(nvnDeviceFinalize)(&device); free(memory);
    printf("%s t_nvn_tex_fixes: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}}
