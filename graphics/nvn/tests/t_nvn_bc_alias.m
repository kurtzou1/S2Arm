// 块压缩贴图的未压缩别名（nvn_mtl.m g_bcal：bcal_note / bcal_sync）。11-06 无人深空：植物、晶体、树干表面一片彩虹噪点。
//   游戏用计算着色器（genmipmap_comp_compressbc1 / 5 / 7）把程序生成的贴图压成 BC：往一张 RG32UI / RGBA32UI 图像里写，一个像素就是一个 BC 块，
//   采样的是同一段存储上的 BC 贴图。Switch 上两者是同一段内存；这里原先是两张互不相通的 Metal 贴图，BC 贴图读的是游戏内存里的旧字节。
// 本单测走公开 NVN 接口：一张 8x8 BC1（RGBA_DXT1）贴图和一张同存储的 2x2 RG32UI 贴图，用 CopyBufferToTexture 往 RG32UI 写 4 个已知的 BC1 块（GPU 写），
//   再 CopyTextureToBuffer 读 BC 贴图的块（解析发生在提交里，命令顺序在写之后），最后用 Metal 计算着色器逐像素读 BC 贴图（硬件 BC1 解码）。
// 期望按 BC1 解码规则手算（不跑被测实现）：端点 RGB565 展开到 8 位（5 位 ×255/31、6 位 ×255/63）；c0 > c1 时四色：p2 = (2·c0 + c1) / 3、p3 = (c0 + 2·c1) / 3，
//   c0 ≤ c1 时三色加透明：p2 = (c0 + c1) / 2、p3 = 透明黑（alpha 0）；索引 2 位一个像素，第 (x, y) 像素 = 位 2·(4y + x)。容差 ±3/255（硬件插值舍入）。
//   块 0：c0 = F800 红、c1 = 001F 蓝，索引每行 0xE4 → 一行依次 红 / 蓝 / (170,0,85) / (85,0,170)
//   块 1：c0 = 07E0 绿、c1 = 0000，索引全 0 → 全绿
//   块 2：c0 = FFFF 白、c1 = 0000 黑，索引全 2 → 全 (170,170,170)
//   块 3：c0 = 0000、c1 = FFFF（三色模式），索引全 3 → 透明黑（alpha 0）
// 三种情形各判 CopyTextureToBuffer 读回的块字节 + 64 个像素：
//   A 无人深空次序：BC 贴图的存储里先有 CPU 留下的旧字节（0xA5），GPU 写 RG32UI 之后 BC 贴图才第一次被用 → 应 = 已知块
//   B 增量：BC 贴图先被用过一次（存储全 0，读回全 0），之后 GPU 写 RG32UI，再用 → 应 = 已知块（第一次读回应全 0）
//   C 负对照：关掉同步（g_bcal_off），按 A 的次序 → 读回不等于已知块（说明 A 的通过靠的是同步，不是巧合）
//   E 写入者早已出了已释放贴图环：GPU 写 RG32UI 后 Finalize，再过 600 张贴图，BC 贴图才第一次用 → 应 = 已知块（#951 菜单缩略图）
//   D CPU 后写为准：GPU 写 RG32UI 之后，CPU 往同一段存储写进另外 4 个块（8x8 BC1 只占一个 GOB，块 (bx, by) 在 GOB 内偏移 8·(2·by + bx)），BC 贴图再第一次被用 → 应 = CPU 写的块
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
static void *api(const char *name) { void *p = h_nvnBootstrapLoader(name); if (!p) { printf("✗ 取不到 %s\n", name); exit(1); } return p; }
#define API(name) ((NVNT_##name)api(#name))
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }   // CPU 写受写保护的游戏内存：交给生产的缺页处理（脏页记账），同 t_nvn_firstuse
static void on_alarm(int s) { (void)s; static const char m[] = "✗ t_nvn_bc_alias：60 秒没返回\n"; write(1, m, sizeof m - 1); _exit(1); }
enum { POOL = 16 << 20, CMD = 1 << 20, SRC = 2 << 20, OUT = 3 << 20, W = 8 };
static NVNdevice dev; static NVNqueue q; static NVNmemoryPool pool; static NVNcommandBuffer cmd; static uint8_t control[16384], *mem; static NVNbufferAddress base;
static const uint16_t C0[4] = {0xF800, 0x07E0, 0xFFFF, 0x0000}, C1[4] = {0x001F, 0x0000, 0x0000, 0xFFFF};
static const uint32_t IDX[4] = {0xE4E4E4E4u, 0x00000000u, 0xAAAAAAAAu, 0xFFFFFFFFu};
static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void blocks(uint8_t out[32]) {   // 块 (bx, by) 放在 RG32UI 的 (bx, by)，CopyBufferToTexture 的缓冲按行紧排：块 0、块 1、块 2、块 3
    for (int b = 0; b < 4; b++) { memcpy(out + 8 * b, &C0[b], 2); memcpy(out + 8 * b + 2, &C1[b], 2); memcpy(out + 8 * b + 4, &IDX[b], 4); }
}
static void rgb565(uint16_t c, int o[3]) { o[0] = (c >> 11 & 31) * 255 / 31; o[1] = (c >> 5 & 63) * 255 / 63; o[2] = (c & 31) * 255 / 31; }
static void expect_px(int x, int y, int o[4]) {   // 文件头的 BC1 规则
    int b = (y / 4) * 2 + x / 4, i = (int)(IDX[b] >> (2 * (4 * (y % 4) + x % 4)) & 3), a[3], c[3]; rgb565(C0[b], a); rgb565(C1[b], c); o[3] = 255;
    for (int k = 0; k < 3; k++) {
        if (C0[b] > C1[b]) o[k] = i == 0 ? a[k] : i == 1 ? c[k] : i == 2 ? (2 * a[k] + c[k]) / 3 : (a[k] + 2 * c[k]) / 3;
        else o[k] = i == 0 ? a[k] : i == 1 ? c[k] : i == 2 ? (a[k] + c[k]) / 2 : 0;
    }
    if (C0[b] <= C1[b] && i == 3) o[3] = 0;
}
static void tex(NVNtexture *t, NVNformat f, int w, ptrdiff_t off) {
    NVNtextureBuilder tb; API(nvnTextureBuilderSetDefaults)(&tb); API(nvnTextureBuilderSetDevice)(&tb, &dev); API(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(&tb, w, w); API(nvnTextureBuilderSetFormat)(&tb, f); API(nvnTextureBuilderSetLevels)(&tb, 1);
    API(nvnTextureBuilderSetStorage)(&tb, &pool, off); if (!API(nvnTextureInitialize)(t, &tb)) { printf("✗ 贴图\n"); exit(1); }
}
static void run(void (^rec)(void)) {   // 录一个命令缓冲、提交、等 GPU 做完
    API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, 0, CMD); API(nvnCommandBufferBeginRecording)(&cmd); rec();
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&cmd); API(nvnQueueSubmitCommands)(&q, 1, &h); API(nvnQueueFinish)(&q);
    if (mtl_last_commit_error()) { printf("✗ GPU 报错\n"); exit(1); }
}
static void gpu_write(NVNtexture *rg) {   // GPU 往 RG32UI 写 4 个块（拷贝目的 = GPU 写，与计算着色器的图像写同记一笔 gpw_mark）
    run(^{ NVNcopyRegion r = {0, 0, 0, 2, 2, 1}; API(nvnCommandBufferCopyBufferToTexture)(&cmd, base + SRC, rg, NULL, &r, 0); });
}
static void read_blocks(NVNtexture *bc, uint8_t out[32]) {   // BC 贴图在提交里被用一次：块字节拷进缓冲
    memset(mem + OUT, 0x5A, 32);
    run(^{ NVNcopyRegion r = {0, 0, 0, W, W, 1}; API(nvnCommandBufferCopyTextureToBuffer)(&cmd, bc, NULL, &r, base + OUT, 0); });
    memcpy(out, mem + OUT, 32);
}
static int sample(NVNtexture *bc) {   // Metal 计算着色器逐像素读 BC 贴图（硬件解码），返回和手算不符的像素数
    static id<MTLComputePipelineState> ps;
    if (!ps) { NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void k(texture2d<float, access::read> t [[texture(0)]], device float4 *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) { o[g.y * 8 + g.x] = t.read(g); }\n" options:nil error:&e];
        ps = lib ? [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e] : nil; if (!ps) { printf("✗ 采样着色器：%s\n", e.localizedDescription.UTF8String); exit(1); } }
    id<MTLTexture> t = tex_mtl((const tex_t *)bc); if (!t) { printf("✗ BC 贴图没有 Metal 贴图\n"); exit(1); }
    id<MTLBuffer> o = [g_dev newBufferWithLength:W * W * 16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> cq = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setTexture:t atIndex:0]; [ce setBuffer:o offset:0 atIndex:0]; [ce dispatchThreads:MTLSizeMake(W, W, 1) threadsPerThreadgroup:MTLSizeMake(W, W, 1)];
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const float *f = o.contents; int bad = 0, shown = 0;
    for (int y = 0; y < W; y++) for (int x = 0; x < W; x++) { int e[4], d = 0; expect_px(x, y, e);
        for (int k = 0; k < 4; k++) { int v = (int)lrintf(f[4 * (y * W + x) + k] * 255.f); if (abs(v - e[k]) > 3) d = 1; }
        if (d) { bad++; if (shown++ < 2) printf("    像素 (%d,%d) 期望 %d,%d,%d,%d 实得 %.0f,%.0f,%.0f,%.0f\n", x, y, e[0], e[1], e[2], e[3],
                 f[4 * (y * W + x)] * 255, f[4 * (y * W + x) + 1] * 255, f[4 * (y * W + x) + 2] * 255, f[4 * (y * W + x) + 3] * 255); } }
    return bad;
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); signal(SIGALRM, on_alarm); alarm(60);
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    char map[] = "/tmp/t_bcal_map_XXXXXX", user[] = "/tmp/t_bcal_user_XXXXXX"; int fd = mkstemp(map); close(fd); fd = mkstemp(user); close(fd);
    setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); if (!API(nvnDeviceInitialize)(&dev, &db)) { printf("✗ 设备\n"); return 1; }
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &dev); API(nvnQueueInitialize)(&q, &qb); mtl_init(); g_wd = 0;
    if (posix_memalign((void **)&mem, 65536, POOL)) return 1; memset(mem, 0, POOL);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &dev);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, POOL); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolInitialize)(&pool, &pb); base = API(nvnMemoryPoolGetBufferAddress)(&pool);
    API(nvnCommandBufferInitialize)(&cmd, &dev); API(nvnCommandBufferAddControlMemory)(&cmd, control, sizeof control);
    uint8_t want[32], got[32], zero[32] = {0}; blocks(want); memcpy(mem + SRC, want, 32);
    printf("DEVICE %s Metal %s 编码线程 %s\n", g_dev.name.UTF8String, g_m3 ? "3" : "4", getenv("DM_NVN_ENC_THREAD") ? getenv("DM_NVN_ENC_THREAD") : "缺省");
    // A：无人深空次序
    { static NVNtexture bc, rg; memset(mem + (4 << 20), 0xA5, 4096); tex(&bc, NVN_FORMAT_RGBA_DXT1, W, 4 << 20); tex(&rg, NVN_FORMAT_RG32UI, 2, 4 << 20);
      gpu_write(&rg); read_blocks(&bc, got);
      CHECK(!memcmp(got, want, 32), "A 旧字节在先、GPU 写后首次使用：BC 贴图读回的块 = 写进 RG32UI 的 4 个块");
      int bad = sample(&bc); CHECK(!bad, "A 硬件解码的 64 个像素与手算一致（不符 %d）", bad); }
    // B：增量
    { static NVNtexture bc, rg; tex(&bc, NVN_FORMAT_RGBA_DXT1, W, 5 << 20); tex(&rg, NVN_FORMAT_RG32UI, 2, 5 << 20);
      read_blocks(&bc, got); CHECK(!memcmp(got, zero, 32), "B GPU 写之前先用一次：读回全 0（存储里本来就是 0）");
      gpu_write(&rg); read_blocks(&bc, got);
      CHECK(!memcmp(got, want, 32), "B 之后 GPU 写 RG32UI、再用：读回 = 4 个块（增量同步）");
      int bad = sample(&bc); CHECK(!bad, "B 64 个像素与手算一致（不符 %d）", bad); }
    // C：负对照
    { static NVNtexture bc, rg; g_bcal_off = 1; memset(mem + (6 << 20), 0xA5, 4096); tex(&bc, NVN_FORMAT_RGBA_DXT1, W, 6 << 20); tex(&rg, NVN_FORMAT_RG32UI, 2, 6 << 20);
      gpu_write(&rg); read_blocks(&bc, got); int bad = sample(&bc); g_bcal_off = 0;
      CHECK(memcmp(got, want, 32) != 0 && bad > 0, "C 负对照（关掉同步）：读回不是那 4 个块、像素不符 %d 个（同步确实是 A 通过的原因）", bad); }
    // D：CPU 后写为准
    { static NVNtexture bc, rg; uint8_t cpu[32]; for (int i = 0; i < 32; i++) cpu[i] = (uint8_t)(0x11 * (i % 8) + 3);
      tex(&bc, NVN_FORMAT_RGBA_DXT1, W, 7 << 20); tex(&rg, NVN_FORMAT_RG32UI, 2, 7 << 20);
      gpu_write(&rg); memcpy(mem + (7 << 20), cpu, 32); API(nvnMemoryPoolFlushMappedRange)(&pool, 7 << 20, 512);
      read_blocks(&bc, got); CHECK(!memcmp(got, cpu, 32), "D GPU 写之后 CPU 又改写了这段存储：BC 贴图读回的是 CPU 写的块（不被 GPU 那次写盖掉）"); }
    // E：写入者早已出了「已释放贴图」环（11-13 #951 菜单缩略图）：GPU 写 RG32UI 后游戏 Finalize 它，之后又有 600 张贴图写过、Finalize（环只留最近 512 张），
    //   BC 贴图这时才第一次用 → 仍应 = 已知块（原先按序号 / 共享表都取不到写入者，字节不拷、读成旧字节）
    { static NVNtexture bc, rg, dummy; memset(mem + (8 << 20), 0xA5, 4096); tex(&bc, NVN_FORMAT_RGBA_DXT1, W, 8 << 20); tex(&rg, NVN_FORMAT_RG32UI, 2, 8 << 20);
      gpu_write(&rg); API(nvnTextureFinalize)(&rg);
      for (int i = 0; i < 600; i++) { tex(&dummy, NVN_FORMAT_RG32UI, 2, (9 << 20) + (ptrdiff_t)i * 4096); gpu_write(&dummy); API(nvnTextureFinalize)(&dummy); }
      read_blocks(&bc, got);
      CHECK(!memcmp(got, want, 32), "E 写入者 Finalize 后又过了 600 张贴图、BC 贴图才用：读回的块 = 写进去的 4 个块");
      int bad = sample(&bc); CHECK(!bad, "E 64 个像素与手算一致（不符 %d）", bad); }
    printf("%s t_nvn_bc_alias：%u 项，不符 %u（Metal %s）\n", failures ? "✗" : "✓", checks, failures, g_m3 ? "3" : "4");
    return failures != 0;
} }
