// 贴图→贴图拷贝补齐（nvn_mtl.m copy_t2t_ / copy_t2t_draw）：诊断里走到「texture→texture copy case not implemented」、这笔拷贝整个丢掉的几种情形，
//   各建一组：公开 NVN bootstrap → 真实录制 CopyTextureToTexture → Metal 提交 → 公开读回（ReadTexels），同 t_nvn_partial_clear 的搭法。
// 跑法：t_nvn_copy_fmt（native-test-nvn_copy_fmt 在 Metal 4 与 NXGAL_BE=mtl3 下各跑一遍）。
// 期望全部手算（源用清屏填成已知值，不跑被测实现），每组两条判据：
//   ① g_t2t_unimpl 不涨（修前每组 +1：这笔拷贝走到「没实现」、目标没写）；
//   ② 读回目标逐像素等于手算图，并带反证：目标里拷贝区域外的像素保持拷贝前的值（证明不是整张被盖）。
//   1 D32F 缩放、目标区域伸出目标存储（诊断 72 份）：64x48 源（0.25）缩拷到 32x24 目标的 (16,12) 起 32x24 区域 → 只有 x≥16 且 y≥12 的四分之一变 0.25，其余保持 0.75
//   2 D16 缩放（48 份）：64x48 源清成 1.0 → 32x24 目标（原 0）全为 0xFFFF
//   3 D32F_S8 → D32F 缩放（32 份）：源深度 0.25 → 32x24 D32F 全 0.25
//   4 D32F_S8 → R32F 同尺寸（3 份）：深度进颜色第一通道 → 64x48 R32F 全 0.25
//   5 R32UI 缩放（整数格式）：源左半 777、右半 12345 → 32x24 目标 x<16 为 777、其余 12345（整数按纹素读，最近点：目标 x 的中心映射到源 2x+1）
//   6 2D → 3D 的一片（4 份）：64x48 红拷进 64x48x4 的 3D 第 2 片 → 第 2 片全红，第 1 片保持 0
//   7 RGBA8_SRGB → R11G11B10F 缩放（jhaizhou-ops/S2Arm#1493）：源白 → 32x24 目标每像素 0x781E03C0（R11 / G11 的 1.0 = 指数 15 尾数 0 = 0x3C0，B10 的 1.0 = 0x1E0）
//   8 源层超出源贴图（D-4T8M：iPhone 上画法拷贝给只有 1 层的源建第 2 层的 2D 视图，Metal 校验断言整进程 abort）：64x48 一层 2D 源、源区域 z 偏移 1 缩拷到 32x24 →
//     不 abort、这笔不画，目标保持拷贝前的 0.5 灰（0xff808080）；修前在 newTextureView 上 abort
#include "nvn.h"
#include "nvn_protos.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern uint64_t g_t2t_unimpl;
extern int mtl_last_commit_error(void);

static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer commands; static void *storage;
static size_t texture_offset = 4 << 20; static unsigned checks, fails; static const char *phase = "初始化";
enum { POOL_SIZE = 64 << 20, COMMAND_SIZE = 1 << 20, W = 64, H = 48 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL [%s] %s:%d: %s\n", phase, __FILE__, __LINE__, #x); fails++; } } while (0)
static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); if (!e) { fprintf(stderr, "FAIL 找不到 %s\n", name); exit(1); } return e; }
#define API(name) ((NVNT_##name)load(#name))

static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    if (posix_memalign(&storage, 65536, POOL_SIZE)) exit(1);
    memset(storage, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static void make(NVNtexture *t, NVNformat fmt, int target, int w, int h, int d) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, target);
    if (target == NVN_TEXTURE_TARGET_3D) API(nvnTextureBuilderSetSize3D)(&b, w, h, d); else API(nvnTextureBuilderSetSize2D)(&b, w, h);
    API(nvnTextureBuilderSetFormat)(&b, fmt); API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    size_t al = API(nvnTextureBuilderGetStorageAlignment)(&b), sz = API(nvnTextureBuilderGetStorageSize)(&b);
    texture_offset = (texture_offset + al - 1) / al * al; REQUIRE(texture_offset + sz <= POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)texture_offset); texture_offset += sz;
    REQUIRE(API(nvnTextureInitialize)(t, &b));
}
static void clear_depth(NVNtexture *t, int w, int h, float v, int stencil) {
    API(nvnCommandBufferSetRenderTargets)(&commands, 0, NULL, NULL, t, NULL); API(nvnCommandBufferSetScissor)(&commands, 0, 0, w, h);
    API(nvnCommandBufferClearDepthStencil)(&commands, v, 1, stencil, 0xff);
}
static void clear_color(NVNtexture *t, int x, int y, int w, int h, const float c[4]) {
    const NVNtexture *ts[1] = {t}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL);
    API(nvnCommandBufferSetScissor)(&commands, x, y, w, h); API(nvnCommandBufferClearColor)(&commands, 0, c, 15);
}
static void clear_ui(NVNtexture *t, int x, int y, int w, int h, uint32_t v) {
    const NVNtexture *ts[1] = {t}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL);
    uint32_t c[4] = {v, 0, 0, 0}; API(nvnCommandBufferSetScissor)(&commands, x, y, w, h); API(nvnCommandBufferClearColorui)(&commands, 0, c, 15);
}
static void copy(NVNtexture *s, NVNcopyRegion sr, NVNtexture *d, NVNcopyRegion dr) {
    begin(); API(nvnCommandBufferCopyTextureToTexture)(&commands, s, NULL, &sr, d, NULL, &dr, 0); submit();
}
static void read(NVNtexture *t, int z, int w, int h, void *out, size_t bytes) {
    NVNcopyRegion r = {0, 0, z, w, h, 1}; memset(out, 0xA5, bytes); API(nvnTextureReadTexels)(t, NULL, &r, out);
}
// 32 位一像素的图逐像素比：want(x, y) 给期望值
static void cmp32(const uint32_t *got, int w, int h, uint32_t (*want)(int x, int y), const char *what) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        checks++;
        if (got[y * w + x] != want(x, y)) { fprintf(stderr, "FAIL [%s] %s (%d,%d) 得 %#x 期望 %#x\n", phase, what, x, y, got[y * w + x], want(x, y)); fails++; return; }
    }
    printf("  %s：%dx%d 逐像素相等\n", what, w, h);
}
static uint32_t fbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static uint32_t w1(int x, int y) { return fbits(x >= 16 && y >= 12 ? 0.25f : 0.75f); }
static uint32_t wq(int x, int y) { (void)x; (void)y; return fbits(0.25f); }
static uint32_t w5(int x, int y) { (void)y; return x < 16 ? 777u : 12345u; }
static uint32_t wred(int x, int y) { (void)x; (void)y; return 0xff0000ffu; }
static uint32_t wzero(int x, int y) { (void)x; (void)y; return 0; }
static uint32_t w7(int x, int y) { (void)x; (void)y; return 0x781E03C0u; }
static uint32_t wgrey(int x, int y) { (void)x; (void)y; return 0xff808080u; }
static void unimpl_is_zero(uint64_t u0) { printf("  走到「没实现」%llu 次（期望 0）\n", (unsigned long long)(g_t2t_unimpl - u0)); REQUIRE(g_t2t_unimpl == u0); }

int main(void) {
    setup();
    static uint32_t got[W * H * 4];
    NVNcopyRegion full = {0, 0, 0, W, H, 1}, half = {0, 0, 0, W / 2, H / 2, 1};

    phase = "1 D32F 缩放、目标区域伸出目标存储";
    { NVNtexture S, D; make(&S, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_TARGET_2D, W / 2, H / 2, 1);
      begin(); clear_depth(&S, W, H, 0.25f, 0); clear_depth(&D, W / 2, H / 2, 0.75f, 0); submit();
      uint64_t u0 = g_t2t_unimpl; copy(&S, full, &D, (NVNcopyRegion){16, 12, 0, W / 2, H / 2, 1}); unimpl_is_zero(u0);
      read(&D, 0, W / 2, H / 2, got, sizeof got); cmp32(got, W / 2, H / 2, w1, "目标：伸出部分裁掉，(16,12) 起的四分之一为 0.25、其余保持 0.75"); }

    phase = "2 D16 缩放";
    { NVNtexture S, D; make(&S, NVN_FORMAT_DEPTH16, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_DEPTH16, NVN_TEXTURE_TARGET_2D, W / 2, H / 2, 1);
      begin(); clear_depth(&S, W, H, 1.0f, 0); clear_depth(&D, W / 2, H / 2, 0.0f, 0); submit();
      uint64_t u0 = g_t2t_unimpl; copy(&S, full, &D, half); unimpl_is_zero(u0);
      read(&D, 0, W / 2, H / 2, got, sizeof got); const uint16_t *g16 = (const uint16_t *)got; int bad = 0;
      for (int i = 0; i < (W / 2) * (H / 2); i++) if (g16[i] != 0xFFFF) { bad = 1; fprintf(stderr, "FAIL [%s] 像素 %d 得 %#x 期望 0xffff\n", phase, i, g16[i]); break; }
      checks++; if (bad) fails++; else printf("  目标 32x24 全为 0xFFFF\n"); }

    phase = "3 D32F_S8 → D32F 缩放";
    { NVNtexture S, D; make(&S, NVN_FORMAT_DEPTH32F_STENCIL8, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_DEPTH32F, NVN_TEXTURE_TARGET_2D, W / 2, H / 2, 1);
      begin(); clear_depth(&S, W, H, 0.25f, 7); clear_depth(&D, W / 2, H / 2, 0.75f, 0); submit();
      uint64_t u0 = g_t2t_unimpl; copy(&S, full, &D, half); unimpl_is_zero(u0);
      read(&D, 0, W / 2, H / 2, got, sizeof got); cmp32(got, W / 2, H / 2, wq, "目标全 0.25"); }

    phase = "4 D32F_S8 → R32F 同尺寸";
    { NVNtexture S, D; make(&S, NVN_FORMAT_DEPTH32F_STENCIL8, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_R32F, NVN_TEXTURE_TARGET_2D, W, H, 1);
      const float c0[4] = {0.75f, 0, 0, 0};
      begin(); clear_depth(&S, W, H, 0.25f, 7); clear_color(&D, 0, 0, W, H, c0); submit();
      uint64_t u0 = g_t2t_unimpl; copy(&S, full, &D, full); unimpl_is_zero(u0);
      read(&D, 0, W, H, got, sizeof got); cmp32(got, W, H, wq, "目标 R32F 全 0.25"); }

    phase = "5 R32UI 缩放";
    { NVNtexture S, D; make(&S, NVN_FORMAT_R32UI, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_R32UI, NVN_TEXTURE_TARGET_2D, W / 2, H / 2, 1);
      begin(); clear_ui(&S, 0, 0, W, H, 12345); clear_ui(&S, 0, 0, W / 2, H, 777); clear_ui(&D, 0, 0, W / 2, H / 2, 1); submit();
      uint64_t u0 = g_t2t_unimpl; copy(&S, full, &D, half); unimpl_is_zero(u0);
      read(&D, 0, W / 2, H / 2, got, sizeof got); cmp32(got, W / 2, H / 2, w5, "目标 x<16 为 777、其余 12345"); }

    phase = "6 2D → 3D 的一片";
    { NVNtexture S, D; make(&S, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_3D, W, H, 4);
      const float red[4] = {1, 0, 0, 1};
      begin(); clear_color(&S, 0, 0, W, H, red); submit();
      uint64_t u0 = g_t2t_unimpl; copy(&S, full, &D, (NVNcopyRegion){0, 0, 2, W, H, 1}); unimpl_is_zero(u0);
      read(&D, 2, W, H, got, sizeof got); cmp32(got, W, H, wred, "3D 第 2 片全红");
      read(&D, 1, W, H, got, sizeof got); cmp32(got, W, H, wzero, "3D 第 1 片保持 0（反证：不是整张被盖）"); }

    phase = "7 RGBA8_SRGB → R11G11B10F 缩放（#1493）";
    { NVNtexture S, D; make(&S, NVN_FORMAT_RGBA8_SRGB, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_R11G11B10F, NVN_TEXTURE_TARGET_2D, W / 2, H / 2, 1);
      const float white[4] = {1, 1, 1, 1}, black[4] = {0, 0, 0, 0};
      begin(); clear_color(&S, 0, 0, W, H, white); clear_color(&D, 0, 0, W / 2, H / 2, black); submit();
      uint64_t u0 = g_t2t_unimpl; copy(&S, full, &D, half); unimpl_is_zero(u0);
      read(&D, 0, W / 2, H / 2, got, sizeof got); cmp32(got, W / 2, H / 2, w7, "目标每像素 0x781E03C0"); }

    phase = "8 源层超出源贴图（D-4T8M）";
    { NVNtexture S, D; make(&S, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_2D, W, H, 1); make(&D, NVN_FORMAT_RGBA8, NVN_TEXTURE_TARGET_2D, W / 2, H / 2, 1);
      const float white[4] = {1, 1, 1, 1}, grey[4] = {0.5f, 0.5f, 0.5f, 1};
      begin(); clear_color(&S, 0, 0, W, H, white); clear_color(&D, 0, 0, W / 2, H / 2, grey); submit();
      copy(&S, (NVNcopyRegion){0, 0, 1, W, H, 1}, &D, half);
      read(&D, 0, W / 2, H / 2, got, sizeof got); cmp32(got, W / 2, H / 2, wgrey, "目标保持拷贝前的灰（源第 1 层不存在，这笔不画、不 abort）"); }

    if (fails) { printf("✗ t_nvn_copy_fmt：%u 项里 %u 项不通\n", checks, fails); return 1; }
    printf("✓ t_nvn_copy_fmt：8 组 %u 项全过\n", checks);
    return 0;
}
