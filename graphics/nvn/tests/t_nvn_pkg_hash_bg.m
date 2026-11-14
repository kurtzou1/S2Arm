// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// 打包贴图首次上传的逐页哈希不在提交线程上算（#674）。0400486024DEC000 读档进场景，一帧首次上传 643 张贴图（332 MB、21,900 页），哈希 124 ms：
//   游戏是经别的映射（同一批页的别名、GPU 拷贝）把内容写进去的，宿主这个地址上还没有页表项，CPU 第一次读每页缺页一次。改成交后台串行队列去算。
// 公开 NVN 接口 + 生产 nvn_mtl.m（包含）+ 真 Metal 设备 + 真写保护缺页。期望按 NVN 语义和「谁读了存储」手写，与被测实现无关：
//   贴图 16×16 RGBA8，存储整块填同一字节 v → 读出 v / 255。测试把 nvn_dirty_protect 包一层：对「布防」的那页，在正常加写保护之后再设成不可访问，
//   第一个读它的线程进信号处理，记下是哪个线程、放开成只读后接着读。
//   ① 首次上传：提交线程（本测试的主线程）不读贴图存储；读它的是别的线程。读出 0x40
//   ② 首次上传之后 CPU 往同页写同样的字节：下一次提交「同字节跳过」+1、不重传，仍读 0x40（后台算的哈希是对的）
//   ③ 第二张贴图首次上传：后台哈希读存储时先被扣住；这次提交的 GPU 已读走 0x40，再由 CPU 改成 0xA0、放行后台哈希 → 下一次提交读到 0xA0
//      （哈希若在 GPU 读之后才取到新字节、又被当成有效，查脏页时新旧一致，旧上传就被留下）
// 反证（11-13 手工核过）：同一测试编 main 的 nvn_mtl.m：① 读存储的是主线程（红），②③ 通；去掉 pkg_upload_ 里后台哈希结束时的 nvn_dirty_since_span
//   判定（一律当有效）：③ 读到 0x40（红）
#define nvn_dirty_protect test_dirty_protect
#include "../gfx/nvn/nvn_mtl.m"
#undef nvn_dirty_protect
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>

void nvn_dirty_protect(const void *addr, size_t len);
extern void *h_nvnBootstrapLoader(const char *name);
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNtexturePool tpool;
static uint8_t *memory; static unsigned checks, fails;
enum { POOL_SIZE = 16 << 20, TEX_OFF = 5 << 20, TEX2_OFF = 6 << 20, TEX_BYTES = 1 << 16, OUT_OFF = 4 << 20 };
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *api(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))

// 布防：下一次给 [g_arm_lo, g_arm_hi) 加写保护时再设成不可访问；第一个读它的线程记进 g_reader，g_hold 置位时非主线程在信号处理里等到放行
static pthread_t g_main;
static _Atomic uintptr_t g_arm_lo, g_arm_hi; static _Atomic int g_armed, g_closed, g_hold, g_reads, g_reader_main;
void test_dirty_protect(const void *a, size_t n) {
    nvn_dirty_protect(a, n);
    uintptr_t lo = atomic_load(&g_arm_lo), hi = atomic_load(&g_arm_hi);
    if (atomic_load(&g_armed) && (uintptr_t)a < hi && (uintptr_t)a + n > lo) {
        atomic_store(&g_armed, 0); REQUIRE(!mprotect((void *)lo, hi - lo, PROT_NONE)); atomic_store(&g_closed, 1); }
}
static void arm(uint8_t *p) { size_t pg = nvn_dirty_page_size(); uintptr_t lo = (uintptr_t)p & ~(pg - 1);
    atomic_store(&g_arm_lo, lo); atomic_store(&g_arm_hi, lo + pg); atomic_store(&g_reads, 0); atomic_store(&g_reader_main, -1); atomic_store(&g_armed, 1); }
static void on_sig(int s, siginfo_t *si, void *uc) {
    uintptr_t a = (uintptr_t)si->si_addr;
    if (atomic_load(&g_closed) && a >= atomic_load(&g_arm_lo) && a < atomic_load(&g_arm_hi)) {
        int main_ = pthread_equal(pthread_self(), g_main) != 0;
        if (atomic_fetch_add(&g_reads, 1) == 0) atomic_store(&g_reader_main, main_);
        if (!main_) while (atomic_load(&g_hold)) usleep(1000);
        int one = 1; if (atomic_compare_exchange_strong(&g_closed, &one, 0)) mprotect((void *)atomic_load(&g_arm_lo), atomic_load(&g_arm_hi) - atomic_load(&g_arm_lo), PROT_READ);
        return;   // 重做这次访问：只读页上的读直接成；写再缺页一次，走下面的写保护跟踪
    }
    if (s2a_direct_fault(si->si_addr, 1, uc)) return;
    signal(s, SIG_DFL);
}
static int wait_reads(void) { for (int i = 0; i < 2000 && !atomic_load(&g_reads); i++) usleep(1000); return atomic_load(&g_reads); }

static prog_t g_pg; static float *g_out;
static void draw_read(int slot) {   // 计算着色器从纹理槽 3（句柄 = ID slot）read 第一个像素写进存储缓冲
    S.tex_base = 0; S.tex[5][3] = (uint64_t)slot; S.cprog = &g_pg; S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)g_out, .size = 16}; g_args_dirty[5] = 1;
    p_dispatch d = {.x = 1, .y = 1, .z = 1}; dispatch(&d);
}
static float sub_end(void) {
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); return g_out[0];
}
static float read_once(int slot) { nvn_be_sub_begin(); draw_read(slot); return sub_end(); }
static int near(float a, int v) { return fabsf(a - v / 255.0f) < 1e-3f; }
static void tex_make(NVNtexture *t, int off, int slot, uint8_t v) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device); API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&b, 16, 16); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetStorage)(&b, &pool, off); REQUIRE(API(nvnTextureInitialize)(t, &b));
    static uint8_t px[16 * 16 * 4]; memset(px, v, sizeof px);
    NVNcopyRegion r = {0, 0, 0, 16, 16, 1}; API(nvnTextureWriteTexels)(t, NULL, &r, px);   // CPU 写过 → 打包贴图（按客体内存上传、跟踪脏页）
    API(nvnTexturePoolRegisterTexture)(&tpool, slot, t, NULL);
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); g_main = pthread_self();
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(!posix_memalign((void **)&memory, 65536, POOL_SIZE)); memset(memory, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
    REQUIRE(API(nvnTexturePoolInitialize)(&tpool, &pool, 1 << 20, 512));
    NVNtexture t1 = {0}, t2 = {0}; tex_make(&t1, TEX_OFF, 0, 0x40); tex_make(&t2, TEX2_OFF, 1, 0x40);
    NSError *err = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { texture2d<float> t [[id(0)]]; device float4 *out [[id(1)]]; };\n"
        "kernel void rd(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0) a.out[0] = a.t.read(uint2(0)); }\n" options:o error:&err];
    REQUIRE(lib);
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"rd"]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
    NSDictionary *refl = @{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
        @{ @"kind": @"tex", @"reg": @3, @"arg_id": @0, @"msl_type": @"texture2d<float>" }, @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @1, @"rw": @YES } ] };
    char e2[512]; REQUIRE(!nvn_refl_from_json(refl, &cs->rf, e2, sizeof e2));
    memset(&g_pg, 0, sizeof g_pg); g_pg.magic = MAGIC('P', 'R', 'O', 'G'); g_pg.serial = nvn_new_serial();
    NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(g_pg.serial, np);
    g_out = (float *)(memory + OUT_OFF);
    uint8_t *st1 = memory + TEX_OFF, *st2 = memory + TEX2_OFF;

    arm(st1); float v = read_once(0); int n = wait_reads(), m = atomic_load(&g_reader_main);
    VERIFY(n && m == 0, "① 首次上传：读贴图存储的%s（期望 别的线程；读了 %d 次）", !n ? "线程 没有" : m ? "是提交线程" : "是别的线程", n);
    VERIFY(near(v, 0x40), "① 读到 0x40（得 %.4f）", v);

    uint64_t s0 = g_pkg_same, u0 = g_pkg_reuploads;
    memset(st1, 0x40, TEX_BYTES); v = read_once(0);
    VERIFY(g_pkg_same == s0 + 1 && g_pkg_reuploads == u0 && near(v, 0x40), "② 同页写同样字节：同字节跳过 %llu → %llu（期望 +1）、重传 %llu → %llu（期望不变）、读 %.4f（期望 0x40）",
           (unsigned long long)s0, (unsigned long long)g_pkg_same, (unsigned long long)u0, (unsigned long long)g_pkg_reuploads, v);

    atomic_store(&g_hold, 1); arm(st2); v = read_once(1);
    VERIFY(near(v, 0x40), "③ 第二张首次上传：这次提交读到 0x40（得 %.4f）", v);
    memset(st2, 0xA0, TEX_BYTES); atomic_store(&g_hold, 0); (void)wait_reads();
    v = read_once(1);
    VERIFY(near(v, 0xA0), "③ GPU 读走之后 CPU 改成 0xA0、后台哈希才取 → 下一次提交读到 0xA0（得 %.4f）", v);

    printf("%s t_nvn_pkg_hash_bg：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
