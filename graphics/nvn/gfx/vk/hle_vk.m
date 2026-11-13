// Vulkan → Metal layer for games that render with Vulkan (Hades: The Forge renderer). The game's vk* imports bind to the functions here through the host's import
// table (hle.h swhle); the Vulkan loader (subsdk0) and NVIDIA's driver (subsdk1) are not loaded. vkGet{Instance,Device}ProcAddr look names up in the same table
// (a name ending in KHR is also tried without it, for extensions promoted to core 1.1); every name the game asks for is logged once.
// Model:
//   · one physical device shaped like the Switch's Tegra X1: Vulkan 1.1, one queue family, 3 memory types on one heap;
//   · device memory = one shared-storage MTLBuffer, created on the first buffer bind or map (memory that only backs images never gets one); images are
//     standalone private MTLTextures and ignore their memory binding, except linear 2D images, whose texture is made over the bound buffer;
//   · command buffers are recorded into a host list and replayed at vkQueueSubmit into one MTLCommandBuffer on this layer's own queue, which then signals g_ev
//     with the next value; fences complete from the completion handler; semaphores and pipeline barriers do nothing (one serial queue, Metal tracks hazards);
//     queries are results of their submit: timestamps its completion time, occlusion counts from a visibility buffer;
//   · shaders come from the offline library built by dm/gfx/tools/vk_shaders.py (<DM_MSL_DIR>/vk/): a module is found by the hash of its SPIR-V, and its table
//     row says which Metal slot each (set, binding) went to (an array of n descriptors: n slots from there; push constants: their own buffer slot);
//     vertex buffers sit at slot 30 - binding;
//   · swapchain images are registered with the NVN layer's present path (mtl_ext_tex), which shows a frame once g_ev reaches the value of the frame's last submit.
// Environment: DM_VK_LOG=1 logs object creation; DM_VK_CAPTURE=<dir> writes every SPIR-V module the game creates (sh_capture).
// 弱链接[host,nvntest]：s2a_vk_xlate（设备上 SPIR-V 翻译，graphics/metal gal_vkx.m 提供；不链通用渲染器的宿主 / NVN 单测没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,nvntest]：s2a_vk_xlate_vin（同上，按管线顶点格式重翻顶点着色器，vk_vin.inc）
#define VK_NO_PROTOTYPES
#include "../../host/hle.h"
#include "../nvn/nvn_mtl.h"
#include "../nvn/nvn_fps.h"
#include "vk_lib.h"
#include "../tex/nvn_bcdec.h"   // 显卡不认 BC 时在 CPU 上解（vk_no_bc）
#include "../../../metal/gal_samp_caps.h"   // 采样器 LOD 偏置在本机 GPU 上原生生效没有（s2a_lodbias_native，直连 / 通用同一份判法，#800）
#include <vulkan/vulkan_core.h>
#include <vulkan/vulkan_vi.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <math.h>
#include <stdatomic.h>
#include <time.h>
#include <dirent.h>
#include <sys/stat.h>
#include <TargetConditionals.h>
#include <errno.h>

double nvn_be_presented_time(uint64_t n); void dm_perf_present(double iv_ms);   // nvn_mtl.m: when present n reached the screen (s; < 0 dropped, 0 not yet); S2Arm frames.tsv (host_adapt.m)
int nvn_be_fps_target(void);   // nvn_mtl.m: 60, or 30 when the frame rate is halved
int nvn_be_link_active(void); int nvn_be_link_wait_tick(int vsyncs, uint64_t timeout_ns);   // nvn_mtl.m: whether the display link presents, and the wait for its ticks
void dm_vi_layer_crop(int c[4]);   // hle_vi.c: x, y, w, h the game last cropped its layer to (all 0 = none)
int mtl_gpu_go(void); int mtl_gpu_cb_error(NSError *e, const char *where, uint64_t seq);   // nvn_mtl.m：GPU 安全停的门与唯一判定点（11-07）
void s2a_direct_gpu_error(const char *desc);   // S2Arm 改（graphics/nvn/host_adapt.m）：命令缓冲报错 → 直连异常（打红行，不切换）（同 nvn_mtl.m）
void s2a_sleep_ns(int64_t ns);   // S2Arm 原生层（runtime/src/thread.c）：按时睡，不受游戏线程 QoS utility 的定时器余量放宽

#define VLOG(...) LOG("[vk] " __VA_ARGS__)
#define RED1(...) do { static int once_; if (!once_) { once_ = 1; LOG("[vk] 【红】 " __VA_ARGS__); } } while (0)
static int g_log;
static _Atomic int g_stopping;
int dm_gfx_session_stopping(void);
static int vk_stopping(void) { return atomic_load(&g_stopping) || dm_gfx_session_stopping(); }
#define OLOG(...) do { if (g_log) VLOG(__VA_ARGS__); } while (0)

// VK: one Vulkan function, checked against its PFN_ type and registered in the host's import table under its own name
#define VK(name, ret, ...)                                                                       \
    static ret h_##name(__VA_ARGS__);                                                            \
    static const PFN_##name chk_##name __attribute__((unused)) = h_##name;                       \
    __attribute__((used, section("__DATA,swhle"))) static const hle_ent e_##name = {#name, (void *)h_##name}; \
    static ret h_##name(__VA_ARGS__)
// VKB: the same, run on the thread's big host stack (hle_bigstack.c; register arguments only): for the functions that call into Metal on game threads, whose stacks can be small
#define VKB(name, ret, ...)                                                                      \
    static ret h_##name(__VA_ARGS__) __attribute__((used));                                      \
    static const PFN_##name chk_##name __attribute__((unused)) = h_##name;                       \
    extern const char h_##name##_bs[];                                                           \
    __asm__(".text\n.p2align 2\n.globl _h_" #name "_bs\n.private_extern _h_" #name "_bs\n_h_" #name "_bs:\n" \
            "    adrp x16, _h_" #name "@PAGE\n    add x16, x16, _h_" #name "@PAGEOFF\n    b _dm_bigstack_enter\n"); \
    __attribute__((used, section("__DATA,swhle"))) static const hle_ent e_##name = {#name, (void *)h_##name##_bs}; \
    __attribute__((used, section("__DATA,swvkb"))) static const char *const vkb_##name = #name;  /* S2Arm 改：登记要跑在宿主栈上的名字（host_adapt.m 经切栈桩交出）*/ \
    static ret h_##name(__VA_ARGS__)

static uint32_t umin(uint32_t a, uint32_t b) { return a < b ? a : b; }
static uint32_t umax(uint32_t a, uint32_t b) { return a > b ? a : b; }

// ---------- Formats ----------
enum { K_COLOR, K_INT, K_DEPTH, K_DS, K_STENCIL, K_BLOCK };
typedef struct { VkFormat vk; MTLPixelFormat pf; MTLVertexFormat vf; uint8_t bytes, bw, bh, kind; } fmt_t;   // bytes per texel, or per block (bw x bh) for compressed formats
#define FC(v, p, x, b) {VK_FORMAT_##v, MTLPixelFormat##p, MTLVertexFormat##x, b, 1, 1, K_COLOR}
#define FI(v, p, x, b) {VK_FORMAT_##v, MTLPixelFormat##p, MTLVertexFormat##x, b, 1, 1, K_INT}
#define FD(v, p, b, k) {VK_FORMAT_##v, MTLPixelFormat##p, MTLVertexFormatInvalid, b, 1, 1, k}
#define FB(v, p, b, w, h) {VK_FORMAT_##v, MTLPixelFormat##p, MTLVertexFormatInvalid, b, w, h, K_BLOCK}
#define FV(v, x, b) {VK_FORMAT_##v, MTLPixelFormatInvalid, MTLVertexFormat##x, b, 1, 1, K_COLOR}
static const fmt_t g_fmts[] = {
    FC(R8_UNORM, R8Unorm, UCharNormalized, 1), FC(R8_SNORM, R8Snorm, CharNormalized, 1), FI(R8_UINT, R8Uint, UChar, 1), FI(R8_SINT, R8Sint, Char, 1),
    FC(R8G8_UNORM, RG8Unorm, UChar2Normalized, 2), FC(R8G8_SNORM, RG8Snorm, Char2Normalized, 2), FI(R8G8_UINT, RG8Uint, UChar2, 2), FI(R8G8_SINT, RG8Sint, Char2, 2),
    FC(R8G8B8A8_UNORM, RGBA8Unorm, UChar4Normalized, 4), FC(R8G8B8A8_SNORM, RGBA8Snorm, Char4Normalized, 4), FI(R8G8B8A8_UINT, RGBA8Uint, UChar4, 4),
    FI(R8G8B8A8_SINT, RGBA8Sint, Char4, 4), FC(R8G8B8A8_SRGB, RGBA8Unorm_sRGB, Invalid, 4),
    FC(B8G8R8A8_UNORM, BGRA8Unorm, UChar4Normalized_BGRA, 4), FC(B8G8R8A8_SRGB, BGRA8Unorm_sRGB, Invalid, 4),
    FC(A8B8G8R8_UNORM_PACK32, RGBA8Unorm, UChar4Normalized, 4), FC(A8B8G8R8_SRGB_PACK32, RGBA8Unorm_sRGB, Invalid, 4),
    FC(A2B10G10R10_UNORM_PACK32, RGB10A2Unorm, UInt1010102Normalized, 4), FI(A2B10G10R10_UINT_PACK32, RGB10A2Uint, Invalid, 4),
    FC(B10G11R11_UFLOAT_PACK32, RG11B10Float, FloatRG11B10, 4), FC(E5B9G9R9_UFLOAT_PACK32, RGB9E5Float, FloatRGB9E5, 4),
    FC(R5G6B5_UNORM_PACK16, B5G6R5Unorm, Invalid, 2),
    FC(R16_UNORM, R16Unorm, UShortNormalized, 2), FC(R16_SNORM, R16Snorm, ShortNormalized, 2), FI(R16_UINT, R16Uint, UShort, 2), FI(R16_SINT, R16Sint, Short, 2),
    FC(R16_SFLOAT, R16Float, Half, 2),
    FC(R16G16_UNORM, RG16Unorm, UShort2Normalized, 4), FC(R16G16_SNORM, RG16Snorm, Short2Normalized, 4), FI(R16G16_UINT, RG16Uint, UShort2, 4),
    FI(R16G16_SINT, RG16Sint, Short2, 4), FC(R16G16_SFLOAT, RG16Float, Half2, 4),
    FC(R16G16B16A16_UNORM, RGBA16Unorm, UShort4Normalized, 8), FC(R16G16B16A16_SNORM, RGBA16Snorm, Short4Normalized, 8),
    FI(R16G16B16A16_UINT, RGBA16Uint, UShort4, 8), FI(R16G16B16A16_SINT, RGBA16Sint, Short4, 8), FC(R16G16B16A16_SFLOAT, RGBA16Float, Half4, 8),
    FI(R32_UINT, R32Uint, UInt, 4), FI(R32_SINT, R32Sint, Int, 4), FC(R32_SFLOAT, R32Float, Float, 4),
    FI(R32G32_UINT, RG32Uint, UInt2, 8), FI(R32G32_SINT, RG32Sint, Int2, 8), FC(R32G32_SFLOAT, RG32Float, Float2, 8),
    FI(R32G32B32_UINT, Invalid, UInt3, 12), FI(R32G32B32_SINT, Invalid, Int3, 12), FC(R32G32B32_SFLOAT, Invalid, Float3, 12),
    FI(R32G32B32A32_UINT, RGBA32Uint, UInt4, 16), FI(R32G32B32A32_SINT, RGBA32Sint, Int4, 16), FC(R32G32B32A32_SFLOAT, RGBA32Float, Float4, 16),
    FD(D16_UNORM, Depth16Unorm, 2, K_DEPTH), FD(X8_D24_UNORM_PACK32, Depth32Float, 4, K_DEPTH), FD(D32_SFLOAT, Depth32Float, 4, K_DEPTH),
    FD(S8_UINT, Stencil8, 1, K_STENCIL), FD(D24_UNORM_S8_UINT, Depth32Float_Stencil8, 4, K_DS), FD(D32_SFLOAT_S8_UINT, Depth32Float_Stencil8, 8, K_DS),
    FB(BC1_RGB_UNORM_BLOCK, BC1_RGBA, 8, 4, 4), FB(BC1_RGB_SRGB_BLOCK, BC1_RGBA_sRGB, 8, 4, 4), FB(BC1_RGBA_UNORM_BLOCK, BC1_RGBA, 8, 4, 4),
    FB(BC1_RGBA_SRGB_BLOCK, BC1_RGBA_sRGB, 8, 4, 4), FB(BC2_UNORM_BLOCK, BC2_RGBA, 16, 4, 4), FB(BC2_SRGB_BLOCK, BC2_RGBA_sRGB, 16, 4, 4),
    FB(BC3_UNORM_BLOCK, BC3_RGBA, 16, 4, 4), FB(BC3_SRGB_BLOCK, BC3_RGBA_sRGB, 16, 4, 4), FB(BC4_UNORM_BLOCK, BC4_RUnorm, 8, 4, 4),
    FB(BC4_SNORM_BLOCK, BC4_RSnorm, 8, 4, 4), FB(BC5_UNORM_BLOCK, BC5_RGUnorm, 16, 4, 4), FB(BC5_SNORM_BLOCK, BC5_RGSnorm, 16, 4, 4),
    FB(BC6H_UFLOAT_BLOCK, BC6H_RGBUfloat, 16, 4, 4), FB(BC6H_SFLOAT_BLOCK, BC6H_RGBFloat, 16, 4, 4), FB(BC7_UNORM_BLOCK, BC7_RGBAUnorm, 16, 4, 4),
    FB(BC7_SRGB_BLOCK, BC7_RGBAUnorm_sRGB, 16, 4, 4),
    FB(ASTC_4x4_UNORM_BLOCK, ASTC_4x4_LDR, 16, 4, 4), FB(ASTC_4x4_SRGB_BLOCK, ASTC_4x4_sRGB, 16, 4, 4), FB(ASTC_5x5_UNORM_BLOCK, ASTC_5x5_LDR, 16, 5, 5),
    FB(ASTC_5x5_SRGB_BLOCK, ASTC_5x5_sRGB, 16, 5, 5), FB(ASTC_6x6_UNORM_BLOCK, ASTC_6x6_LDR, 16, 6, 6), FB(ASTC_6x6_SRGB_BLOCK, ASTC_6x6_sRGB, 16, 6, 6),
    FB(ASTC_8x8_UNORM_BLOCK, ASTC_8x8_LDR, 16, 8, 8), FB(ASTC_8x8_SRGB_BLOCK, ASTC_8x8_sRGB, 16, 8, 8),
    // Vertex-only formats: integers read as unnormalized floats (USCALED / SSCALED, Metal converts the integer formats to the shader's float type) and three components.
    // Super Mario Galaxy's GX vertex data is mostly these (positions as R16G16B16_SSCALED, colours as R8G8B8A8_USCALED…)
    FV(R8_USCALED, UChar, 1), FV(R8_SSCALED, Char, 1), FV(R8G8_USCALED, UChar2, 2), FV(R8G8_SSCALED, Char2, 2),
    FV(R8G8B8_UNORM, UChar3Normalized, 3), FV(R8G8B8_SNORM, Char3Normalized, 3), FV(R8G8B8_USCALED, UChar3, 3), FV(R8G8B8_SSCALED, Char3, 3),
    FV(R8G8B8_UINT, UChar3, 3), FV(R8G8B8_SINT, Char3, 3), FV(R8G8B8A8_USCALED, UChar4, 4), FV(R8G8B8A8_SSCALED, Char4, 4),
    FV(R16_USCALED, UShort, 2), FV(R16_SSCALED, Short, 2), FV(R16G16_USCALED, UShort2, 4), FV(R16G16_SSCALED, Short2, 4),
    FV(R16G16B16_UNORM, UShort3Normalized, 6), FV(R16G16B16_SNORM, Short3Normalized, 6), FV(R16G16B16_USCALED, UShort3, 6), FV(R16G16B16_SSCALED, Short3, 6),
    FV(R16G16B16_UINT, UShort3, 6), FV(R16G16B16_SINT, Short3, 6), FV(R16G16B16_SFLOAT, Half3, 6),
    FV(R16G16B16A16_USCALED, UShort4, 8), FV(R16G16B16A16_SSCALED, Short4, 8),
};
static const fmt_t *g_fmt_by[VK_FORMAT_ASTC_12x12_SRGB_BLOCK + 1];
static void fmt_init(void) { for (size_t i = 0; i < sizeof g_fmts / sizeof *g_fmts; i++) g_fmt_by[g_fmts[i].vk] = &g_fmts[i]; }
static const fmt_t *fmt_of(VkFormat f) {
    static pthread_once_t once = PTHREAD_ONCE_INIT; pthread_once(&once, fmt_init);
    return (unsigned)f < sizeof g_fmt_by / sizeof *g_fmt_by ? g_fmt_by[f] : NULL;
}
static int fmt_has_depth(const fmt_t *f) { return f && (f->kind == K_DEPTH || f->kind == K_DS); }
static int fmt_has_stencil(const fmt_t *f) { return f && (f->kind == K_STENCIL || f->kind == K_DS); }

// ---------- Device-wide state ----------
static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_q;
static id<MTLSharedEvent> g_ev;                 // signalled with ++g_ev_val at the end of every submit
static id<MTLDepthStencilState> g_dss_off;      // pipelines without depth / stencil
static uint64_t g_ev_val;                       // under g_qmu
static _Atomic uint64_t g_done;                 // highest value whose command buffer has completed
static pthread_mutex_t g_qmu = PTHREAD_MUTEX_INITIALIZER, g_done_mu = PTHREAD_MUTEX_INITIALIZER, g_mem_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_done_cv = PTHREAD_COND_INITIALIZER;
static _Atomic uint64_t g_n_draw, g_n_pass, g_n_submit, g_n_copy, g_n_pso, g_mem_bytes;
static _Atomic uint64_t g_render_encoders, g_indirect_buffers, g_indirect_bytes;
void dm_vk_indirect_stats(uint64_t *encoders, uint64_t *buffers, uint64_t *bytes) {
    *encoders = atomic_load(&g_render_encoders); *buffers = atomic_load(&g_indirect_buffers); *bytes = atomic_load(&g_indirect_bytes);
}

// Shader table (<DM_MSL_DIR>/vk/vk_shaders.tsv): resource kind u / b / t / s / c, its (set, binding) in the game's SPIR-V and the Metal slot it was moved to;
// kind p is the push-constant block (set and binding 0), whose bytes are set straight into its buffer slot
typedef struct { char kind; uint8_t set, slot, count; uint16_t binding; } shres;   // count: an array of descriptors, elements in slots slot … slot + count − 1
typedef struct { char key[17]; int frag, comp, nres; shres res[24]; uint16_t wg[3]; } shinfo;   // comp: a compute shader, wg its workgroup size (table token w:x.y=z)
static shinfo *g_sh; static int g_nsh;
static id<MTLLibrary> g_lib;
static int g_vk_lb_emu;   // #800：本机 GPU 的采样器 LOD 偏置不生效（gal_samp_caps.h 实测：M3 等；系统早于 26 也算；S2A_SAMP_EMU=1 强制）→ 带偏置的采样器不设偏置，着色器加（vk_lbias.inc）
static int sh_cmp(const void *a, const void *b) { return memcmp(((const shinfo *)a)->key, ((const shinfo *)b)->key, 16); }
// 表一行的资源栏（空格分隔 kind:set.binding=slot[*count]，计算着色器另有 w:x.y=z）→ shinfo；离线库表与设备现编（vk_rt.inc）共用
// strtok_r（11-09 根修）：现编队列 s2a.vk.rt 是并发队列，几支同时编好时各自的 rt_finish 都进这里；strtok 的游标全进程共用一个，
//   互相踩会丢字段——守望 t_vk_core ㉑ 计算那支丢了 w:（工作组大小），补建判「不是计算着色器或没有工作组大小」、派发被安全网跳过
static void sh_parse(shinfo *s, char *res) {
    char *save = NULL;
    for (char *t = res ? strtok_r(res, " ", &save) : NULL; t; t = strtok_r(NULL, " ", &save)) {
        char k; unsigned st, b, sl, n = 1;
        if (t[0] == 'w') { unsigned x, y, z; if (sscanf(t, "w:%u.%u=%u", &x, &y, &z) == 3) { s->wg[0] = (uint16_t)x; s->wg[1] = (uint16_t)y; s->wg[2] = (uint16_t)z; } continue; }
        if (sscanf(t, "%c:%u.%u=%u*%u", &k, &st, &b, &sl, &n) < 4 || !n || sl + n > 31 || s->nres == 24) { LOG("[vk] 【红】 cannot parse a resource entry of shader table %s: %s", s->key, t); continue; }
        s->res[s->nres++] = (shres){k, (uint8_t)st, (uint8_t)sl, (uint8_t)n, (uint16_t)b};
    }
}
static void sh_load(void) {
    const char *d = getenv("DM_MSL_DIR"); char p[1024];
    if (!d) { LOG("[vk] 【红】 DM_MSL_DIR not set: the Vulkan shader library cannot be found"); return; }
    snprintf(p, sizeof p, "%s/vk/vk_shaders.tsv", d);
    FILE *f = fopen(p, "r");
    if (!f) { LOG("[vk] 【红】 cannot open %s (run dm/gfx/tools/vk_shaders.py first)", p); return; }
    char line[4096]; int cap = 0;
    if (!fgets(line, sizeof line, f) || strncmp(line, S2A_VK_LIB_TAG, strlen(S2A_VK_LIB_TAG)) || atoi(line + strlen(S2A_VK_LIB_TAG)) != S2A_VK_LIB_ABI) {
        LOG("[vk] 【红】 shader table %s is not of library version %d (first line: %.60s): rebuild the package", p, S2A_VK_LIB_ABI, line); fclose(f); return;
    }
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *rest = line, *key = strsep(&rest, "\t"), *stage = strsep(&rest, "\t"), *res = strsep(&rest, "\t\n");   // strsep keeps the empty resource field of a shader without resources
        if (!key || !stage || strlen(key) != 16) continue;
        if (g_nsh == cap) { cap = cap ? cap * 2 : 128; g_sh = realloc(g_sh, cap * sizeof *g_sh); }
        shinfo *s = &g_sh[g_nsh++]; memset(s, 0, sizeof *s);
        memcpy(s->key, key, 16); s->frag = !strcmp(stage, "frag"); s->comp = !strcmp(stage, "comp");
        sh_parse(s, res);
    }
    fclose(f);
    qsort(g_sh, g_nsh, sizeof *g_sh, sh_cmp);   // looked up by key (Super Mario Galaxy creates over 3,000 modules at boot)
    // 表只有表头（RomFS 里没有 SPIR-V、游戏运行时生成的款，出包不起局，vk_shaders.py --header-only）：没有库可载，全部设备首遇现编（vk_rt.inc）
    if (!g_nsh) { LOG("[vk] 离线库 0 支（%s 只有表头）：全部设备首遇现编", p); return; }
    snprintf(p, sizeof p, "%s/vk/vk_shaders.metallib", d);
    NSError *err = nil;
    g_lib = [g_dev newLibraryWithURL:[NSURL fileURLWithPath:@(p)] error:&err];
    if (!g_lib) LOG("[vk] 【红】 shader library failed to load %s: %s", p, err.localizedDescription.UTF8String);
}
// Vulkan 款的直连库在不在、口径对不对（直连起手判定 runtime/src/gfxmode.c；与 sh_load 同口径，同 GL 的 s2a_gl_lib_ready）：
//   <游戏数据>/shaders/direct/vk/vk_shaders.tsv 第一行是本宿主的口径（vk_lib.h）→ 就绪；表有着色器行时还要有非空的 vk_shaders.metallib。
//   只有表头（RomFS 里没有 SPIR-V、出包不起局，vk_shaders.py --header-only）也算就绪：sh_load 不装库、全部设备首遇现编（vk_rt.inc）
//   （11-05 Minecraft 复判批 c1105_mc：只认「有库有行」，表头包被判不就绪、退通用模式，首帧前崩在 DMA）
int s2a_vk_lib_ready(const char *game_data) {
    char p[1200], line[256]; struct stat st;
    if (!game_data || !*game_data) return 0;
    snprintf(p, sizeof p, "%s/shaders/direct/vk/vk_shaders.tsv", game_data);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    int ok = fgets(line, sizeof line, f) && !strncmp(line, S2A_VK_LIB_TAG, strlen(S2A_VK_LIB_TAG)) && atoi(line + strlen(S2A_VK_LIB_TAG)) == S2A_VK_LIB_ABI, rows = 0;
    if (!ok) LOG("【红】 直连 Vulkan 库口径不符（要 %d，%s 第一行：%.60s）：不算就绪，请按当前 main 重出包", S2A_VK_LIB_ABI, p, line);
    // 按整行数（同 s2a_gl_lib_ready：超 256 字节的行被 fgets 切开，后半截不算新行）
    for (int start = 1; ok && fgets(line, sizeof line, f); start = strchr(line, '\n') != NULL) if (start && line[0] != '#' && line[0] != '\n') rows++;
    fclose(f);
    if (ok && rows) { snprintf(p, sizeof p, "%s/shaders/direct/vk/vk_shaders.metallib", game_data); if (stat(p, &st) || !st.st_size) { LOG("【红】 直连 Vulkan 表有 %d 行却没有库 %s：不算就绪", rows, p); return 0; } }
    return ok;
}
static const shinfo *sh_find(const char *key) { shinfo k; memcpy(k.key, key, 16); return g_nsh ? bsearch(&k, g_sh, g_nsh, sizeof *g_sh, sh_cmp) : NULL; }

static void rt_preload(void);   // vk_rt.inc
static void dev_init_once(void) {
    @autoreleasepool {
        g_dev = (__bridge id<MTLDevice>)mtl_device();
        g_q = [g_dev newCommandQueueWithMaxCommandBufferCount:64]; g_q.label = @"vk";
        g_ev = [g_dev newSharedEvent];
        g_dss_off = [g_dev newDepthStencilStateWithDescriptor:[MTLDepthStencilDescriptor new]];
        sh_load();
        g_vk_lb_emu = !s2a_lodbias_native(g_dev);
        rt_preload();   // 上次设备现编持久化的（vk_rt.inc）
        VLOG("Metal device %s; %d shader table entries", g_dev.name.UTF8String, g_nsh);
    }
}
static pthread_mutex_t g_init_mu = PTHREAD_MUTEX_INITIALIZER;
static void dev_init(void) {
    pthread_mutex_lock(&g_init_mu);
    if (!g_dev) { atomic_store(&g_stopping, 0); dev_init_once(); }
    pthread_mutex_unlock(&g_init_mu);
}

// ---------- Objects ----------
// Dispatchable handles: their first word is where a loader keeps its dispatch table
typedef struct debug_callback debug_callback;
struct VkInstance_T { void *loader; pthread_mutex_t debug_mu; pthread_cond_t debug_cv; debug_callback *debug; VkAllocationCallbacks allocator; int custom_allocator; struct VkInstance_T *session_next; };
static VkInstance g_instances;
struct VkPhysicalDevice_T { void *loader; };
struct VkDevice_T { void *loader; };
struct VkQueue_T { void *loader; };
static struct VkPhysicalDevice_T g_pdev; static struct VkDevice_T g_device; static struct VkQueue_T g_queue;

struct VkSurfaceKHR_T { void *win; };
struct VkDeviceMemory_T { VkDeviceSize size; uint32_t type; __strong id<MTLBuffer> buf; _Atomic(void *) raw; };
struct VkBuffer_T { VkDeviceSize size; VkBufferUsageFlags usage; VkDeviceMemory mem; VkDeviceSize off; };
struct VkBufferView_T { VkBuffer buf; const fmt_t *f; VkDeviceSize off, range; __strong id<MTLTexture> tex; };
struct VkImage_T { __strong id<MTLTexture> tex; const fmt_t *f; VkFormat fmt; VkImageType type; uint32_t w, h, d, mips, layers, samples; VkDeviceSize size; uint64_t serial; uint32_t wid; int swap; uint32_t ext_w, ext_h;   // wid：宽屏核心的贴图号（vk_widen.inc）；w 是游戏的宽，贴图可能被放宽
                  VkImageUsageFlags usage; uint32_t pitch; uint32_t bc; uint64_t mem, bc_orig;   // mem：贴图实际分配字节（Metal allocatedSize，记账用）；bc_orig：解压图按原 BC 格式本该占的字节   // bc：显卡不认 BC 时这张图建成了解压格式，这里记原来的 BC 格式号（nvn_bcdec 的编号；0 = 不是这种图）；pitch: row pitch of a linear image (its texture is made over the bound memory), 0 otherwise
                  VkImageView views; };   // 本图像的视图链（宽屏按内容判画布后重建存储时按原参数重派生，vk_widen.inc wd_promote）
struct VkImageView_T { __strong id<MTLTexture> tex; VkImage img; uint32_t wid, gw, gh;   // wid / gw / gh：宽屏核心的视图号与游戏看到的宽高
                      VkImageView vnext; MTLPixelFormat pf; MTLTextureType tt; uint32_t lv0, lvn, ly0, lyn; MTLTextureSwizzleChannels sw; int whole; };   // 派生参数（whole = 就是图像本身的贴图）
struct VkSampler_T { __strong id<MTLSamplerState> s; float lb; };   // lb：本机 GPU 不认的 LOD 偏置（g_vk_lb_emu），着色器模拟加它；0 = 没有或在采样器上
struct rt_ent;
struct VkShaderModule_T { const shinfo *si; __strong id<MTLFunction> fn, fn_d; char key[17]; int tried_d; struct rt_ent *rt; __strong NSData *spv; uint32_t vin_s, vin_u; };   // spv：g_vk_lb_emu 时 / 顶点输入有整型时留的 SPIR-V（LOD 偏置模拟变体、顶点输入重翻在设备上重翻用，vk_se_fn / vk_vin.inc）   // vin_s / vin_u：顶点入口有符号 / 无符号整型输入的 location 位（vk_vin.inc vin_scan）   // rt：离线库里没有、交设备现编的那一份（vk_rt.inc）   // fn_d: the dual-source variant vk_<key>_d, looked up on first use
struct VkPipelineCache_T { int unused; };
// Query pool: a result is valid once the submit that wrote it has completed (g_done >= ticket). Timestamps are the completion time of their submit (in ns,
// timestampPeriod 1), the same for every timestamp of one submit; occlusion results are copied from the submit's visibility buffer when it completes
struct VkQueryPool_T { VkQueryType type; uint32_t n; uint64_t *val, *ticket; };
struct VkSemaphore_T { int unused; };
// Event: its state as the host sees it. vkCmdSetEvent / vkCmdResetEvent take effect when their submit completes (later than the GPU reaches them, never earlier:
// a host that polls sees it set once the work before it is done); vkCmdWaitEvents orders like a barrier on the one serial queue (see replay)
struct VkEvent_T { _Atomic int set; };
struct VkSamplerYcbcrConversion_T { int unused; };
#define FENCE_NONE UINT64_MAX
struct VkFence_T { _Atomic uint64_t val; };   // 0 = signalled; FENCE_NONE = unsignalled with nothing pending; otherwise signalled once g_done reaches it

#define MAXB 64
typedef struct { uint32_t binding, count, base; VkDescriptorType type; int dyn, imm; } lbind;   // base: first element in a set's array; dyn: first dynamic offset in the set (-1 if not dynamic)
struct VkDescriptorSetLayout_T { uint32_t n, total, ndyn; lbind b[MAXB]; int8_t idx[128]; VkSampler *imm; };
// A descriptor holds the Metal objects it was written with (retained), as a hardware descriptor holds a copy of the object's handle: a set may still name a view, sampler
// or buffer the game has destroyed (the hardware reads it only when a draw samples it), and the replay binds every element of an array the shader takes. Descriptors
// used to point at this layer's view / sampler / buffer structs, and Super Mario Galaxy 2 crashed reading a freed view's texture from element 1 of its 8-texture array
// when the ship took off after its first galaxy (GitHub issue 68). buf / off: the buffer's memory and its offset there plus the descriptor's; tex: an image view's
// texture or a texel buffer's
typedef struct { __strong id<MTLBuffer> buf; VkDeviceSize off, range; __strong id<MTLTexture> tex; __strong id<MTLSamplerState> smp; uint32_t wid, gw, gh; float lb; } desc_t;   // lb：采样器的模拟 LOD 偏置（VkSampler_T.lb）   // range 0 = 到缓冲末尾；wid / gw / gh：图像视图的宽屏号与游戏宽高
struct VkDescriptorPool_T { struct VkDescriptorSet_T *sets; };
struct VkDescriptorSet_T { VkDescriptorSetLayout L; VkDescriptorPool pool; struct VkDescriptorSet_T *prev, *next; desc_t *d; };   // d: L->total descriptors (ARC objects: no flexible array)
struct VkDescriptorUpdateTemplate_T { uint32_t n; VkDescriptorUpdateTemplateEntry e[]; };
struct VkPipelineLayout_T { uint32_t nset, pc_size; VkDescriptorSetLayout set[8]; };   // pc_size: end of the highest push-constant range

typedef struct { VkFormat fmt; VkAttachmentLoadOp load, sload; VkAttachmentStoreOp store, sstore; } ratt;
typedef struct { uint32_t ncol; int col[8], res[8], depth; } rsub;   // one subpass: its color / resolve / depth-stencil attachments (-1 = unused)
// Subpasses are run as Metal passes one after the other (vkCmdNextSubpass ends one and starts the next); first / last: the subpass an attachment is first / last used in,
// which picks its load action (its own load op at first use, otherwise load) and store action (its own store op at last use, otherwise store)
struct VkRenderPass_T { uint32_t natt, nsub; ratt att[16]; rsub sub[8]; int8_t first[16], last[16]; };
struct VkFramebuffer_T { uint32_t n, w, h, layers; VkImageView v[16]; };
struct VkPipeline_T {
    __strong id<MTLRenderPipelineState> pso; __strong id<MTLDepthStencilState> dss;
    const shinfo *vs, *fs; uint32_t vb_mask; VkPipelineLayout layout;
    MTLPrimitiveType prim; MTLCullMode cull; MTLWinding wind; MTLTriangleFillMode fill; MTLDepthClipMode clip;
    int bias; float bias_c, bias_s, bias_cl; float blend[4]; uint32_t sref_f, sref_b;
    int dyn_vp, dyn_sc, has_vp, has_sc; MTLViewport vp; VkRect2D sc;
    uint32_t dyn;   // DYN_*: state the command buffer sets (vkCmdSet*), the pipeline's own values for it are ignored
    int feat;       // built without something the host lacks (a stage Metal has not): its draws count as dropped for a missing feature, not an error
    int gs;         // 管线带几何阶段（Metal 没有，按原图元画，没扩展）：用到它的绘制常驻计数（维护者 10-25：真画到了带截图回来做，计算预处理 / 实例化四边形）
    uint32_t sub;   // the subpass it was made for
    __strong MTLDepthStencilDescriptor *dsd; __strong NSMutableDictionary *dss_dyn;   // dynamic stencil masks: the state to vary and the states made per mask set
    __strong id<MTLComputePipelineState> cps; const shinfo *cs;   // a compute pipeline
    // #800 LOD 偏置模拟变体（g_vk_lb_emu，vk_se_pso / vk_se_cps）：片元 / 计算那支的 SPIR-V 与键、建管线的描述（片元），第一次有绘制 / 派发绑了带模拟偏置的采样器时现建；
    //   se_state 0 没试 / 1 有 / 2 做不了（那些绘制不加偏置，报红一次）；se_slot：表的缓冲槽（这支没用到的最高槽）；se_dual：管线用的是双源混合入口 vk_<键>_d
    __strong NSData *se_spv; __strong MTLRenderPipelineDescriptor *se_pd; __strong id<MTLRenderPipelineState> pso_se; __strong id<MTLComputePipelineState> cps_se;
    int se_state, se_slot, se_dual; char se_key[17];
    // 等现编的管线（11-05 Minecraft：离线库 0 支、全部设备首遇现编，建管线时它的着色器还在后台编）：句柄照交、照常成功，描述先存下（pend_pd / 计算管线 pend_c），
    //   着色器编好后第一次绘制 / 派发补建（pipe_finish / cpipe_finish）；编好之前的绘制照安全网跳过。原先顶点着色器在编的整条交空句柄回失败码（游戏不重试就永久缺这条），
    //   片元着色器在编的建成「没有片元函数」的管线、编好也不补（静默不出颜色）。指现编条目（rt_ent，整个进程不释放），不指模块：游戏建完管线可以销毁模块
    __strong MTLRenderPipelineDescriptor *pend_pd; struct rt_ent *pend_v, *pend_f, *pend_c; int pend_dual; __strong NSData *pend_spv;
};
struct VkCommandPool_T { struct VkCommandBuffer_T *cbs; };
struct VkCommandBuffer_T { void *loader; VkCommandPool pool; struct VkCommandBuffer_T *prev, *next; uint8_t *buf; size_t n, cap; };
struct VkSwapchainKHR_T { uint32_t n, next; VkImage img[4]; uint64_t ticket[4]; };

enum { DYN_BIAS = 1, DYN_BLEND = 2, DYN_SREF = 4, DYN_SCMP = 8, DYN_SWR = 16 };
// Draws the layer drops (the direct mode's picture check, graphics/nvn/host/pic_watch.inc): feat = the host lacks what the draw needs; err = its pipeline or pass could not be made
static _Atomic uint64_t g_bad_feat, g_bad_err;
void dm_vk_bad_draws(uint64_t *feat, uint64_t *err) { *feat = atomic_load(&g_bad_feat); *err = atomic_load(&g_bad_err); }
// 审计 1800（P2-3 / P2-4）：入口照旧回成功、能力位照旧报 1，但这一笔本身越界 / 用了宿主没做的能力——首例一行红 + 计数。
//   改返回码或清能力位会改游戏走的分支，要真机读数（哪款、多频繁）再定；下标顺序是导出口径（tests/vk_core ⑯ 按它读）。
//   映射 / 视图越界、管线建不成（P1-45 / P1-46）已改回失败码 + 空句柄（审计 #1534），不再在这里计数
enum { OKB_MAP_TYPE0, OKB_PRESENT_IDX, OKB_FEAT_ROBUST, OKB_FEAT_SSR, OKB_N };
static _Atomic uint64_t g_okb[OKB_N];
uint64_t dm_vk_ok_but_bad(int k) { return k >= 0 && k < OKB_N ? atomic_load(&g_okb[k]) : 0; }
static void *zalloc(size_t n) { void *p = calloc(1, n); if (!p) die("[vk] out of memory %zu", n); return p; }
typedef enum { O_PLAIN, O_MEMORY, O_BUFFER_VIEW, O_IMAGE, O_IMAGE_VIEW, O_SAMPLER, O_SHADER,
    O_PIPELINE, O_LAYOUT, O_SET, O_COMMAND, O_QUERY } object_kind;
typedef struct vk_object { struct vk_object *next; void *ptr; object_kind kind; } vk_object;
static vk_object *g_objects;
static pthread_mutex_t g_object_mu = PTHREAD_MUTEX_INITIALIZER;
static void *obj_alloc(size_t size, object_kind kind) {
    void *ptr = zalloc(size); vk_object *node = zalloc(sizeof *node); node->ptr = ptr; node->kind = kind;
    pthread_mutex_lock(&g_object_mu); node->next = g_objects; g_objects = node; pthread_mutex_unlock(&g_object_mu);
    return ptr;
}
static void obj_free(void *ptr) {
    if (!ptr) return;
    pthread_mutex_lock(&g_object_mu);
    vk_object **link = &g_objects; while (*link && (*link)->ptr != ptr) link = &(*link)->next;
    if (!*link) die("[vk] freeing an unregistered object %p", ptr);
    vk_object *node = *link; *link = node->next;
    pthread_mutex_unlock(&g_object_mu);
    free(node); free(ptr);
}
static VkResult debug_instance_create(const VkInstanceCreateInfo *, const VkAllocationCallbacks *, VkInstance *);
static void debug_instance_destroy(VkInstance, const VkAllocationCallbacks *);

// ---------- Instance and physical device ----------
static VkResult fill_names(const char *const *names, uint32_t n, uint32_t *count, VkExtensionProperties *p) {
    if (!p) { *count = n; return VK_SUCCESS; }
    uint32_t k = umin(*count, n);
    for (uint32_t i = 0; i < k; i++) {
        memset(&p[i], 0, sizeof p[i]); strlcpy(p[i].extensionName, names[i], sizeof p[i].extensionName); p[i].specVersion = 1;
        if (!strcmp(names[i], VK_EXT_DEBUG_UTILS_EXTENSION_NAME)) p[i].specVersion = VK_EXT_DEBUG_UTILS_SPEC_VERSION;
        if (!strcmp(names[i], VK_EXT_DEBUG_REPORT_EXTENSION_NAME)) p[i].specVersion = VK_EXT_DEBUG_REPORT_SPEC_VERSION;
        if (!strcmp(names[i], VK_EXT_DEBUG_MARKER_EXTENSION_NAME)) p[i].specVersion = VK_EXT_DEBUG_MARKER_SPEC_VERSION;
    }
    *count = k; return k < n ? VK_INCOMPLETE : VK_SUCCESS;
}
static const char *const g_inst_ext[] = {"VK_KHR_surface", "VK_NN_vi_surface", "VK_KHR_get_physical_device_properties2", VK_EXT_DEBUG_UTILS_EXTENSION_NAME, VK_EXT_DEBUG_REPORT_EXTENSION_NAME};
static const char *const g_dev_ext[] = {"VK_KHR_swapchain", "VK_KHR_descriptor_update_template", "VK_KHR_maintenance1", "VK_KHR_get_memory_requirements2",
                                        "VK_KHR_dedicated_allocation", "VK_KHR_bind_memory2", VK_EXT_DEBUG_MARKER_EXTENSION_NAME};
// VK_AMD_draw_indirect_count 与 multiDrawIndirect 的入口照样登记、能查到，但不宣告：哈迪斯 1.0.38233 见到这两项会在标题菜单卡住（一次也不调它们；
//   10-25 Spare-host 上同一份代码宣告 0 / 3 局到 MARK、不宣告 3 / 3），游戏没启用扩展时本来就不该调
static void join_names(char *out, size_t n, const char *const *names, uint32_t count) {
    out[0] = 0; size_t o = 0;
    for (uint32_t i = 0; i < count && o + 2 < n; i++) o += snprintf(out + o, n - o, "%s%s", i ? " " : "", names[i]);
    if (!count) strlcpy(out, "none", n);
}

VK(vkEnumerateInstanceVersion, VkResult, uint32_t *v) { *v = VK_API_VERSION_1_1; return VK_SUCCESS; }
VK(vkEnumerateInstanceLayerProperties, VkResult, uint32_t *n, VkLayerProperties *p) { (void)p; *n = 0; return VK_SUCCESS; }
VK(vkEnumerateInstanceExtensionProperties, VkResult, const char *layer, uint32_t *n, VkExtensionProperties *p) {
    if (layer) { *n = 0; return VK_ERROR_LAYER_NOT_PRESENT; }
    return fill_names(g_inst_ext, sizeof g_inst_ext / sizeof *g_inst_ext, n, p);
}
static _Atomic int g_vk_used;
int s2a_vk_front_used(void) { return atomic_load(&g_vk_used); }   // 帧录（nvn_frame_rec.inc）：本款走 Vulkan 前端，NVN 回放层录不到
VK(vkCreateInstance, VkResult, const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *out) {
    atomic_store(&g_vk_used, 1);
    g_log = getenv("DM_VK_LOG") != NULL;
    const VkApplicationInfo *ai = ci->pApplicationInfo; char ext[512];
    join_names(ext, sizeof ext, ci->ppEnabledExtensionNames, ci->enabledExtensionCount);
    VLOG("CreateInstance: application %s, engine %s, API %u.%u; extensions %s; %u layers", ai && ai->pApplicationName ? ai->pApplicationName : "-",
         ai && ai->pEngineName ? ai->pEngineName : "-", ai ? VK_API_VERSION_MAJOR(ai->apiVersion) : 0, ai ? VK_API_VERSION_MINOR(ai->apiVersion) : 0, ext, ci->enabledLayerCount);
    return debug_instance_create(ci, a, out);
}
VK(vkDestroyInstance, void, VkInstance i, const VkAllocationCallbacks *a) { debug_instance_destroy(i, a); }
VK(vkEnumeratePhysicalDevices, VkResult, VkInstance i, uint32_t *n, VkPhysicalDevice *p) {
    (void)i; if (!p) { *n = 1; return VK_SUCCESS; }
    if (!*n) return VK_INCOMPLETE;
    *n = 1; p[0] = &g_pdev; return VK_SUCCESS;
}
// The current frontend exposes one physical device, hence exactly one singleton group.
// sType / pNext belong to the caller; only the first physicalDeviceCount handles are defined.
VK(vkEnumeratePhysicalDeviceGroups, VkResult, VkInstance i, uint32_t *n, VkPhysicalDeviceGroupProperties *p) {
    (void)i; if (!p) { *n = 1; return VK_SUCCESS; }
    uint32_t k = umin(*n, 1); *n = k;
    if (!k) return VK_INCOMPLETE;
    p[0].physicalDeviceCount = 1; p[0].physicalDevices[0] = &g_pdev; p[0].subsetAllocation = VK_FALSE;
    return VK_SUCCESS;
}
// Properties and limits: a Tegra X1 under NVIDIA's Switch driver, except where Metal is stricter
static void pdev_props(VkPhysicalDeviceProperties *p) {
    memset(p, 0, sizeof *p);
    p->apiVersion = VK_API_VERSION_1_1; p->driverVersion = VK_MAKE_API_VERSION(0, 1, 0, 0); p->vendorID = 0x10de; p->deviceID = 0x92ba;
    p->deviceType = VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU; strlcpy(p->deviceName, "NVIDIA Tegra X1 (nvgpu)", sizeof p->deviceName);
    VkPhysicalDeviceLimits *l = &p->limits;
    l->maxImageDimension1D = l->maxImageDimension2D = l->maxImageDimensionCube = 16384; l->maxImageDimension3D = 2048; l->maxImageArrayLayers = 2048;
    l->maxTexelBufferElements = 1u << 27; l->maxUniformBufferRange = 65536; l->maxStorageBufferRange = 1u << 30; l->maxPushConstantsSize = 256;
    l->maxMemoryAllocationCount = 4096; l->maxSamplerAllocationCount = 4000; l->bufferImageGranularity = 1024; l->maxBoundDescriptorSets = 8;
    l->maxPerStageDescriptorSamplers = 16; l->maxPerStageDescriptorUniformBuffers = 15; l->maxPerStageDescriptorStorageBuffers = 16;
    l->maxPerStageDescriptorSampledImages = 31; l->maxPerStageDescriptorStorageImages = 8; l->maxPerStageDescriptorInputAttachments = 8; l->maxPerStageResources = 128;
    l->maxDescriptorSetSamplers = 4000; l->maxDescriptorSetUniformBuffers = 90; l->maxDescriptorSetUniformBuffersDynamic = 15;
    l->maxDescriptorSetStorageBuffers = 96; l->maxDescriptorSetStorageBuffersDynamic = 16; l->maxDescriptorSetSampledImages = 4096;
    l->maxDescriptorSetStorageImages = 4096; l->maxDescriptorSetInputAttachments = 8;
    l->maxVertexInputAttributes = 31; l->maxVertexInputBindings = 14; l->maxVertexInputAttributeOffset = 2047; l->maxVertexInputBindingStride = 2048; l->maxVertexOutputComponents = 128;
    l->maxFragmentInputComponents = 128; l->maxFragmentOutputAttachments = 8; l->maxFragmentDualSrcAttachments = 1; l->maxFragmentCombinedOutputResources = 16;
    l->maxComputeSharedMemorySize = 32768; l->maxComputeWorkGroupCount[0] = l->maxComputeWorkGroupCount[1] = l->maxComputeWorkGroupCount[2] = 65535;
    l->maxComputeWorkGroupInvocations = 1024; l->maxComputeWorkGroupSize[0] = l->maxComputeWorkGroupSize[1] = 1024; l->maxComputeWorkGroupSize[2] = 64;
    l->subPixelPrecisionBits = 8; l->subTexelPrecisionBits = 8; l->mipmapPrecisionBits = 8; l->maxDrawIndexedIndexValue = 0xffffffffu; l->maxDrawIndirectCount = 0xffffffffu;
    l->maxSamplerLodBias = 15; l->maxSamplerAnisotropy = 16; l->maxViewports = 1; l->maxViewportDimensions[0] = l->maxViewportDimensions[1] = 16384;
    l->viewportBoundsRange[0] = -32768; l->viewportBoundsRange[1] = 32767; l->viewportSubPixelBits = 8;
    l->minMemoryMapAlignment = 64; l->minTexelBufferOffsetAlignment = 256; l->minUniformBufferOffsetAlignment = 256; l->minStorageBufferOffsetAlignment = 256;
    l->minTexelOffset = -8; l->maxTexelOffset = 7; l->minTexelGatherOffset = -32; l->maxTexelGatherOffset = 31;
    l->minInterpolationOffset = -0.5f; l->maxInterpolationOffset = 0.4375f; l->subPixelInterpolationOffsetBits = 4;
    l->maxFramebufferWidth = l->maxFramebufferHeight = 16384; l->maxFramebufferLayers = 2048;
    l->framebufferColorSampleCounts = l->framebufferDepthSampleCounts = l->framebufferStencilSampleCounts = l->framebufferNoAttachmentsSampleCounts = 0x7;
    l->maxColorAttachments = 8; l->sampledImageColorSampleCounts = l->sampledImageIntegerSampleCounts = l->sampledImageDepthSampleCounts = l->sampledImageStencilSampleCounts = 0x7;
    l->storageImageSampleCounts = 1; l->maxSampleMaskWords = 1; l->timestampComputeAndGraphics = 1; l->timestampPeriod = 1;
    l->maxClipDistances = 8; l->maxCullDistances = 0; l->maxCombinedClipAndCullDistances = 8; l->discreteQueuePriorities = 2;
    l->pointSizeRange[0] = 1; l->pointSizeRange[1] = 511; l->lineWidthRange[0] = l->lineWidthRange[1] = 1; l->pointSizeGranularity = 0.0625f; l->lineWidthGranularity = 0;
    l->strictLines = 1; l->standardSampleLocations = 1; l->optimalBufferCopyOffsetAlignment = 256; l->optimalBufferCopyRowPitchAlignment = 256; l->nonCoherentAtomSize = 64;
}
static void pdev_feats(VkPhysicalDeviceFeatures *f) {
    memset(f, 0, sizeof *f);
    f->robustBufferAccess = f->fullDrawIndexUint32 = f->imageCubeArray = f->independentBlend = f->sampleRateShading = f->dualSrcBlend = 1;
    f->drawIndirectFirstInstance = f->depthClamp = f->depthBiasClamp = f->fillModeNonSolid = f->largePoints = f->samplerAnisotropy = 1;
    f->textureCompressionBC = f->textureCompressionASTC_LDR = f->occlusionQueryPrecise = f->fragmentStoresAndAtomics = 1;
    f->shaderImageGatherExtended = f->shaderClipDistance = f->shaderResourceMinLod = 1;
}
static void pdev_mem(VkPhysicalDeviceMemoryProperties *m) {
    memset(m, 0, sizeof *m);
    const VkMemoryPropertyFlags dl = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, hv = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    m->memoryTypeCount = 3;
    m->memoryTypes[0] = (VkMemoryType){dl, 0}; m->memoryTypes[1] = (VkMemoryType){dl | hv, 0}; m->memoryTypes[2] = (VkMemoryType){dl | hv | VK_MEMORY_PROPERTY_HOST_CACHED_BIT, 0};
    m->memoryHeapCount = 1; m->memoryHeaps[0] = (VkMemoryHeap){3ull << 30, VK_MEMORY_HEAP_DEVICE_LOCAL_BIT};
}
static void dedicated_req(void *pn) {
    for (VkBaseOutStructure *s = pn; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS) { VkMemoryDedicatedRequirements *d = (void *)s; d->prefersDedicatedAllocation = d->requiresDedicatedAllocation = VK_FALSE; }
}
VK(vkGetPhysicalDeviceProperties, void, VkPhysicalDevice pd, VkPhysicalDeviceProperties *p) { (void)pd; pdev_props(p); }
VK(vkGetPhysicalDeviceProperties2, void, VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) { (void)pd; pdev_props(&p->properties); }
VK(vkGetPhysicalDeviceFeatures, void, VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) { (void)pd; pdev_feats(f); }
VK(vkGetPhysicalDeviceFeatures2, void, VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) { (void)pd; pdev_feats(&f->features); }
VK(vkGetPhysicalDeviceMemoryProperties, void, VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *m) { (void)pd; pdev_mem(m); }
VK(vkGetPhysicalDeviceMemoryProperties2, void, VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties2 *m) { (void)pd; pdev_mem(&m->memoryProperties); }
VK(vkGetPhysicalDeviceQueueFamilyProperties, void, VkPhysicalDevice pd, uint32_t *n, VkQueueFamilyProperties *p) {
    (void)pd; if (!p) { *n = 1; return; }
    if (!*n) return;
    *n = 1; p[0] = (VkQueueFamilyProperties){VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT, 16, 64, {1, 1, 1}};   // every VkQueue is the same serial Metal queue
}
VK(vkGetPhysicalDeviceFormatProperties, void, VkPhysicalDevice pd, VkFormat format, VkFormatProperties *p) {
    (void)pd; memset(p, 0, sizeof *p);
    const fmt_t *f = fmt_of(format); if (!f) return;
    if (f->vf != MTLVertexFormatInvalid) p->bufferFeatures |= VK_FORMAT_FEATURE_VERTEX_BUFFER_BIT;
    if (f->pf == MTLPixelFormatInvalid) return;
    VkFormatFeatureFlags t = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT | VK_FORMAT_FEATURE_BLIT_SRC_BIT;
    if (f->kind != K_INT && f->kind != K_STENCIL) t |= VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    if (f->kind == K_COLOR || f->kind == K_INT) {
        t |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT;
        if (f->kind == K_COLOR) t |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
        p->bufferFeatures |= VK_FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER_BIT;
    }
    if (f->kind == K_DEPTH || f->kind == K_DS || f->kind == K_STENCIL) t |= VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    p->optimalTilingFeatures = t;
    p->linearTilingFeatures = f->kind == K_COLOR || f->kind == K_INT ? t : 0;
}
VK(vkGetPhysicalDeviceImageFormatProperties, VkResult, VkPhysicalDevice pd, VkFormat format, VkImageType type, VkImageTiling tiling, VkImageUsageFlags usage,
   VkImageCreateFlags flags, VkImageFormatProperties *p) {
    (void)pd; const fmt_t *f = fmt_of(format);
    if (!f || f->pf == MTLPixelFormatInvalid) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    memset(p, 0, sizeof *p);
    p->maxExtent = type == VK_IMAGE_TYPE_3D ? (VkExtent3D){2048, 2048, 2048} : (VkExtent3D){16384, type == VK_IMAGE_TYPE_1D ? 1 : 16384, 1};
    p->maxMipLevels = 15; p->maxArrayLayers = type == VK_IMAGE_TYPE_3D ? 1 : 2048;
    p->sampleCounts = type == VK_IMAGE_TYPE_2D && tiling == VK_IMAGE_TILING_OPTIMAL && !(flags & VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT) &&
                      (usage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)) ? 0x7 : 1;
    p->maxResourceSize = 1ull << 32;
    return VK_SUCCESS;
}
VK(vkGetImageSparseMemoryRequirements, void, VkDevice d, VkImage i, uint32_t *n, VkSparseImageMemoryRequirements *r) { (void)d; (void)i; (void)r; *n = 0; }
// Vulkan 1.1 core queries (VK_KHR_get_physical_device_properties2 is advertised, so its *2KHR names resolve here too): the 1.0 answers in the *2 structures.
// Sparse resources and external memory / fences / semaphores are not supported: the features stay off and the queries say so, as the specification allows
VK(vkGetPhysicalDeviceFormatProperties2, void, VkPhysicalDevice pd, VkFormat format, VkFormatProperties2 *p) { h_vkGetPhysicalDeviceFormatProperties(pd, format, &p->formatProperties); }
VK(vkGetPhysicalDeviceImageFormatProperties2, VkResult, VkPhysicalDevice pd, const VkPhysicalDeviceImageFormatInfo2 *i, VkImageFormatProperties2 *p) {
    for (VkBaseInStructure *e = (VkBaseInStructure *)i->pNext; e; e = (VkBaseInStructure *)e->pNext)
        if (e->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO && ((const VkPhysicalDeviceExternalImageFormatInfo *)e)->handleType) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    for (VkBaseOutStructure *e = p->pNext; e; e = e->pNext) {
        if (e->sType == VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES) memset(&((VkExternalImageFormatProperties *)e)->externalMemoryProperties, 0, sizeof(VkExternalMemoryProperties));
        if (e->sType == VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_IMAGE_FORMAT_PROPERTIES) ((VkSamplerYcbcrConversionImageFormatProperties *)e)->combinedImageSamplerDescriptorCount = 1;
    }
    return h_vkGetPhysicalDeviceImageFormatProperties(pd, i->format, i->type, i->tiling, i->usage, i->flags, &p->imageFormatProperties);
}
VK(vkGetPhysicalDeviceQueueFamilyProperties2, void, VkPhysicalDevice pd, uint32_t *n, VkQueueFamilyProperties2 *p) {
    if (!p) { h_vkGetPhysicalDeviceQueueFamilyProperties(pd, n, NULL); return; }
    if (!*n) return;
    h_vkGetPhysicalDeviceQueueFamilyProperties(pd, n, &p[0].queueFamilyProperties);
}
VK(vkGetPhysicalDeviceSparseImageFormatProperties, void, VkPhysicalDevice pd, VkFormat f, VkImageType t, VkSampleCountFlagBits s, VkImageUsageFlags u, VkImageTiling ti, uint32_t *n, VkSparseImageFormatProperties *p) {
    (void)pd; (void)f; (void)t; (void)s; (void)u; (void)ti; (void)p; *n = 0;
}
VK(vkGetPhysicalDeviceSparseImageFormatProperties2, void, VkPhysicalDevice pd, const VkPhysicalDeviceSparseImageFormatInfo2 *i, uint32_t *n, VkSparseImageFormatProperties2 *p) { (void)pd; (void)i; (void)p; *n = 0; }
VK(vkGetImageSparseMemoryRequirements2, void, VkDevice d, const VkImageSparseMemoryRequirementsInfo2 *i, uint32_t *n, VkSparseImageMemoryRequirements2 *r) { (void)d; (void)i; (void)r; *n = 0; }
VK(vkGetPhysicalDeviceExternalBufferProperties, void, VkPhysicalDevice pd, const VkPhysicalDeviceExternalBufferInfo *i, VkExternalBufferProperties *p) {
    (void)pd; (void)i; memset(&p->externalMemoryProperties, 0, sizeof p->externalMemoryProperties);
}
VK(vkGetPhysicalDeviceExternalFenceProperties, void, VkPhysicalDevice pd, const VkPhysicalDeviceExternalFenceInfo *i, VkExternalFenceProperties *p) {
    (void)pd; (void)i; p->exportFromImportedHandleTypes = p->compatibleHandleTypes = 0; p->externalFenceFeatures = 0;
}
VK(vkGetPhysicalDeviceExternalSemaphoreProperties, void, VkPhysicalDevice pd, const VkPhysicalDeviceExternalSemaphoreInfo *i, VkExternalSemaphoreProperties *p) {
    (void)pd; (void)i; p->exportFromImportedHandleTypes = p->compatibleHandleTypes = 0; p->externalSemaphoreFeatures = 0;
}

// ---------- Surface ----------
static VkExtent2D surf_ext(void) { return dm_opmode() ? (VkExtent2D){1920, 1080} : (VkExtent2D){1280, 720}; }
VK(vkCreateViSurfaceNN, VkResult, VkInstance i, const VkViSurfaceCreateInfoNN *ci, const VkAllocationCallbacks *a, VkSurfaceKHR *out) {
    (void)i; (void)a; VkSurfaceKHR s = obj_alloc(sizeof *s, O_PLAIN); s->win = ci->window; *out = s;
    VLOG("CreateViSurfaceNN window %p", ci->window); return VK_SUCCESS;
}
VK(vkDestroySurfaceKHR, void, VkInstance i, VkSurfaceKHR s, const VkAllocationCallbacks *a) { (void)i; (void)a; obj_free(s); }
VK(vkGetPhysicalDeviceSurfaceSupportKHR, VkResult, VkPhysicalDevice pd, uint32_t fam, VkSurfaceKHR s, VkBool32 *ok) { (void)pd; (void)s; *ok = fam == 0; return VK_SUCCESS; }
VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR, VkResult, VkPhysicalDevice pd, VkSurfaceKHR s, VkSurfaceCapabilitiesKHR *c) {
    (void)pd; (void)s; memset(c, 0, sizeof *c);
    c->minImageCount = 2; c->maxImageCount = 4; c->currentExtent = surf_ext(); c->minImageExtent = (VkExtent2D){1, 1}; c->maxImageExtent = (VkExtent2D){1920, 1080};
    // INHERIT as well: Super Mario Galaxy creates its swapchain with preTransform INHERIT and asserts when the surface does not list it (transforms are ignored here)
    c->maxImageArrayLayers = 1; c->currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR; c->supportedCompositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    c->supportedTransforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR | VK_SURFACE_TRANSFORM_INHERIT_BIT_KHR;
    c->supportedUsageFlags = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    return VK_SUCCESS;
}
VK(vkGetPhysicalDeviceSurfaceFormatsKHR, VkResult, VkPhysicalDevice pd, VkSurfaceKHR s, uint32_t *n, VkSurfaceFormatKHR *f) {
    (void)pd; (void)s;
    static const VkSurfaceFormatKHR fs[] = {{VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}, {VK_FORMAT_R8G8B8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR},
                                            {VK_FORMAT_B8G8R8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}, {VK_FORMAT_R8G8B8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}};
    const uint32_t k = sizeof fs / sizeof *fs;
    if (!f) { *n = k; return VK_SUCCESS; }
    uint32_t m = umin(*n, k); memcpy(f, fs, m * sizeof *fs); *n = m; return m < k ? VK_INCOMPLETE : VK_SUCCESS;
}
VK(vkGetPhysicalDeviceSurfacePresentModesKHR, VkResult, VkPhysicalDevice pd, VkSurfaceKHR s, uint32_t *n, VkPresentModeKHR *m) {
    (void)pd; (void)s; if (!m) { *n = 1; return VK_SUCCESS; }
    if (!*n) return VK_INCOMPLETE;
    *n = 1; m[0] = VK_PRESENT_MODE_FIFO_KHR; return VK_SUCCESS;
}

// ---------- Device and queue ----------
VK(vkEnumerateDeviceLayerProperties, VkResult, VkPhysicalDevice pd, uint32_t *n, VkLayerProperties *p) { (void)pd; (void)p; *n = 0; return VK_SUCCESS; }
VK(vkEnumerateDeviceExtensionProperties, VkResult, VkPhysicalDevice pd, const char *layer, uint32_t *n, VkExtensionProperties *p) {
    (void)pd; if (layer) { *n = 0; return VK_ERROR_LAYER_NOT_PRESENT; }
    VkResult r = fill_names(g_dev_ext, sizeof g_dev_ext / sizeof *g_dev_ext, n, p);
    return r;
}
VKB(vkCreateDevice, VkResult, VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *out) {
    (void)pd; (void)a; dev_init();
    char ext[512]; join_names(ext, sizeof ext, ci->ppEnabledExtensionNames, ci->enabledExtensionCount);
    uint32_t nq = 0; for (uint32_t i = 0; i < ci->queueCreateInfoCount; i++) nq += ci->pQueueCreateInfos[i].queueCount;
    VLOG("CreateDevice: %u queues; extensions %s", nq, ext);
    // P2-3：pdev_feats 报了 robustBufferAccess / sampleRateShading，宿主没做越界读夹紧、也不按样本跑片元——游戏真打开时记一笔（能力位照旧，待读数定）
    const VkPhysicalDeviceFeatures *ef = ci->pEnabledFeatures;
    for (const VkBaseInStructure *s = ci->pNext; !ef && s; s = s->pNext) if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) ef = &((const VkPhysicalDeviceFeatures2 *)s)->features;
    if (ef && ef->robustBufferAccess) { g_okb[OKB_FEAT_ROBUST]++; RED1("CreateDevice 打开了 robustBufferAccess：宿主没做越界读夹紧（能力位照旧报 1，待读数定）"); }
    if (ef && ef->sampleRateShading) { g_okb[OKB_FEAT_SSR]++; RED1("CreateDevice 打开了 sampleRateShading：宿主不按样本跑片元（能力位照旧报 1，待读数定）"); }
    *out = &g_device; return VK_SUCCESS;
}
VK(vkDestroyDevice, void, VkDevice d, const VkAllocationCallbacks *a) { (void)d; (void)a; }
VK(vkGetDeviceQueue, void, VkDevice d, uint32_t fam, uint32_t idx, VkQueue *q) { (void)d; (void)fam; (void)idx; *q = &g_queue; }
VK(vkGetDeviceQueue2, void, VkDevice d, const VkDeviceQueueInfo2 *i, VkQueue *q) { (void)d; *q = i->flags ? NULL : &g_queue; }   // no protected queues
// One physical device, so a device group of one: every memory heap is local to it (the query is only defined between two different devices)
VK(vkGetDeviceGroupPeerMemoryFeatures, void, VkDevice d, uint32_t heap, uint32_t local, uint32_t remote, VkPeerMemoryFeatureFlags *f) {
    (void)d; (void)heap; (void)local; (void)remote;
    *f = VK_PEER_MEMORY_FEATURE_COPY_SRC_BIT | VK_PEER_MEMORY_FEATURE_COPY_DST_BIT | VK_PEER_MEMORY_FEATURE_GENERIC_SRC_BIT | VK_PEER_MEMORY_FEATURE_GENERIC_DST_BIT;
}
VK(vkGetDeviceMemoryCommitment, void, VkDevice d, VkDeviceMemory m, VkDeviceSize *bytes) { (void)d; (void)m; *bytes = 0; }   // no lazily allocated memory type is offered

// ---------- Memory and buffers ----------
static id<MTLBuffer> mem_buf(VkDeviceMemory m) {
    void *r = atomic_load_explicit(&m->raw, memory_order_acquire);
    if (r) return (__bridge id<MTLBuffer>)r;
    pthread_mutex_lock(&g_mem_mu);
    if (!m->buf) {
        m->buf = [g_dev newBufferWithLength:m->size ? m->size : 16 options:MTLResourceStorageModeShared];
        if (!m->buf) LOG("[vk] 【红】 cannot create an MTLBuffer of %llu bytes", (unsigned long long)m->size);
        else { atomic_store_explicit(&m->raw, (__bridge void *)m->buf, memory_order_release); g_mem_bytes += m->size; }
    }
    pthread_mutex_unlock(&g_mem_mu);
    return m->buf;
}
VK(vkAllocateMemory, VkResult, VkDevice d, const VkMemoryAllocateInfo *ai, const VkAllocationCallbacks *a, VkDeviceMemory *out) {
    (void)d; (void)a;
    if (ai->memoryTypeIndex >= 3) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    VkDeviceMemory m = obj_alloc(sizeof *m, O_MEMORY); m->size = ai->allocationSize; m->type = ai->memoryTypeIndex;
    OLOG("AllocateMemory %p %llu bytes type %u", (void *)m, (unsigned long long)m->size, m->type);
    *out = m; return VK_SUCCESS;
}
VKB(vkFreeMemory, void, VkDevice d, VkDeviceMemory m, const VkAllocationCallbacks *a) {
    (void)d; (void)a; if (!m) return;
    if (m->buf) g_mem_bytes -= m->size;
    m->buf = nil; obj_free(m);
}
VKB(vkMapMemory, VkResult, VkDevice d, VkDeviceMemory m, VkDeviceSize off, VkDeviceSize size, VkMemoryMapFlags fl, void **pp) {
    (void)d; (void)fl;
    if (m->type == 0) { g_okb[OKB_MAP_TYPE0]++; RED1("mapped invisible memory (type 0)"); }
    // P1-45：偏移 / 范围超出这块内存（规范要求 offset < size；size 不是整块时 0 < size ≤ size − offset）：交出的指针会越界，回映射失败（vkMapMemory 唯一的失败码），不交指针
    if (off >= m->size || (size != VK_WHOLE_SIZE && (!size || size > m->size - off))) {
        RED1("vkMapMemory 越界：偏移 %llu 大小 %llu，内存 %llu 字节：回 VK_ERROR_MEMORY_MAP_FAILED", (unsigned long long)off, (unsigned long long)size, (unsigned long long)m->size);
        return VK_ERROR_MEMORY_MAP_FAILED;
    }
    id<MTLBuffer> b = mem_buf(m); if (!b) return VK_ERROR_MEMORY_MAP_FAILED;
    *pp = (uint8_t *)b.contents + off; return VK_SUCCESS;
}
VK(vkUnmapMemory, void, VkDevice d, VkDeviceMemory m) { (void)d; (void)m; }
VK(vkFlushMappedMemoryRanges, VkResult, VkDevice d, uint32_t n, const VkMappedMemoryRange *r) { (void)d; (void)n; (void)r; return VK_SUCCESS; }   // shared storage is coherent
VK(vkInvalidateMappedMemoryRanges, VkResult, VkDevice d, uint32_t n, const VkMappedMemoryRange *r) { (void)d; (void)n; (void)r; return VK_SUCCESS; }

VK(vkCreateBuffer, VkResult, VkDevice d, const VkBufferCreateInfo *ci, const VkAllocationCallbacks *a, VkBuffer *out) {
    (void)d; (void)a; VkBuffer b = obj_alloc(sizeof *b, O_PLAIN); b->size = ci->size; b->usage = ci->usage; *out = b; return VK_SUCCESS;
}
VK(vkDestroyBuffer, void, VkDevice d, VkBuffer b, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(b); }
VK(vkGetBufferMemoryRequirements, void, VkDevice d, VkBuffer b, VkMemoryRequirements *r) {
    (void)d; r->alignment = 256; r->size = (b->size + 255) & ~255ull; r->memoryTypeBits = 7;   // 256: Metal's constant-buffer offset alignment on the Mac
}
VK(vkGetBufferMemoryRequirements2, void, VkDevice d, const VkBufferMemoryRequirementsInfo2 *i, VkMemoryRequirements2 *r) {
    h_vkGetBufferMemoryRequirements(d, i->buffer, &r->memoryRequirements); dedicated_req(r->pNext);
}
VKB(vkBindBufferMemory, VkResult, VkDevice d, VkBuffer b, VkDeviceMemory m, VkDeviceSize off) {
    (void)d; b->mem = m; b->off = off; return mem_buf(m) ? VK_SUCCESS : VK_ERROR_OUT_OF_DEVICE_MEMORY;
}
VKB(vkBindBufferMemory2, VkResult, VkDevice d, uint32_t n, const VkBindBufferMemoryInfo *bi) {
    for (uint32_t i = 0; i < n; i++) { VkResult r = h_vkBindBufferMemory(d, bi[i].buffer, bi[i].memory, bi[i].memoryOffset); if (r) return r; }
    return VK_SUCCESS;
}
VK(vkCreateBufferView, VkResult, VkDevice d, const VkBufferViewCreateInfo *ci, const VkAllocationCallbacks *a, VkBufferView *out) {
    (void)d; (void)a;
    // P1-45：偏移 / 范围越出缓冲（规范：offset < size；range 不是整段时 offset + range ≤ size）——不建，回失败码、交空句柄（vkCreateBufferView 只有内存类失败码，取设备内存那条）
    VkDeviceSize bsz = ci->buffer->size;
    if (ci->offset >= bsz || (ci->range != VK_WHOLE_SIZE && (!ci->range || ci->range > bsz - ci->offset))) {
        RED1("vkCreateBufferView 越界：偏移 %llu 范围 %llu，缓冲 %llu 字节：回 VK_ERROR_OUT_OF_DEVICE_MEMORY", (unsigned long long)ci->offset, (unsigned long long)ci->range, (unsigned long long)bsz);
        *out = VK_NULL_HANDLE; return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    VkBufferView v = obj_alloc(sizeof *v, O_BUFFER_VIEW); v->buf = ci->buffer; v->f = fmt_of(ci->format); v->off = ci->offset; v->range = ci->range;
    if (!v->f || v->f->pf == MTLPixelFormatInvalid) RED1("buffer view format %d not mapped", ci->format);
    *out = v; return VK_SUCCESS;
}
VK(vkDestroyBufferView, void, VkDevice d, VkBufferView v, const VkAllocationCallbacks *a) { (void)d; (void)a; if (v) { v->tex = nil; obj_free(v); } }
static id<MTLTexture> bview_tex(VkBufferView v) {   // texel buffer as a linear texture over the buffer's storage, made at first use
    if (v->tex || !v->f || v->f->pf == MTLPixelFormatInvalid || !v->buf->mem) return v->tex;
    VkDeviceSize range = v->range == VK_WHOLE_SIZE ? v->buf->size - v->off : v->range, n = range / v->f->bytes;
    MTLTextureDescriptor *td = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:v->f->pf width:n resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
    v->tex = [mem_buf(v->buf->mem) newTextureWithDescriptor:td offset:v->buf->off + v->off bytesPerRow:n * v->f->bytes];
    if (!v->tex) RED1("cannot create the texel buffer (offset %llu)", (unsigned long long)(v->buf->off + v->off));
    return v->tex;
}

// ---------- Images, views, samplers ----------
static VkDeviceSize img_bytes(const fmt_t *f, uint32_t w, uint32_t h, uint32_t d, uint32_t mips, uint32_t layers, uint32_t samples) {
    VkDeviceSize s = 0;
    for (uint32_t m = 0; m < mips; m++) {
        uint32_t mw = umax(1, w >> m), mh = umax(1, h >> m), md = umax(1, d >> m);
        s += (VkDeviceSize)((mw + f->bw - 1) / f->bw) * ((mh + f->bh - 1) / f->bh) * md * f->bytes;
    }
    return s * layers * samples;
}
static uint32_t wd_new_id(void); static uint32_t wd_image(uint32_t id, uint32_t w, uint32_t h, int rebuild, uint32_t *rh); static void wd_track(VkImage im, int on); static void wd_view(uint32_t id, uint32_t parent, int level, uint32_t w0); static void wd_release(uint32_t id);   // vk_widen.inc
// 不认 BC 压缩格式的显卡（A15 / A16 及更早，MTLDevice.supportsBCTextureCompression = NO）：用 BC 格式建贴图会被 Metal 校验中止（#542：首帧前崩，pixelFormat 152 = BC7）。
// 做法同 NVN 那条路（nvn_mtl.m no_bc）：图像建成解压后的格式，缓冲 → 图像的上传在 CPU 上解码（tex/nvn_bcdec.c）。DM_TEST_NO_BC=1 在任何机器上强制走这条路（Mac 上验）。
// 特性位与格式能力照报「支持 BC」：游戏的资源只有 BC，报不支持它也拿不出别的。
static int vk_no_bc(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_TEST_NO_BC"); int t = e && *e && strcmp(e, "0"); v = t || ![g_dev supportsBCTextureCompression];
        if (v) LOG("[vk] 显卡不认 BC 压缩格式%s：BC 图像建成解压格式，上传时解码", t ? "（测试开关 DM_TEST_NO_BC）" : ""); }
    return v;
}
// 贴图内存账（#542：A16 标题画面进程足迹顶到单进程上限 ~4.1 GB 被系统结束，Vulkan 层原先没有贴图占用读数）：
//   全部私有贴图的实际分配字节，其中「显卡不认 BC、建成解压格式」那部分，以及它们按原 BC 格式本该占多少。出图时总量变化满 64 MB 打一行
static _Atomic uint64_t g_tex_mem, g_tex_n, g_bc_mem, g_bc_n, g_bc_orig;
static uint64_t g_frames;   // 已上屏帧数（定义在 frame_end 旁）
static void tex_mem_note(VkImage im, int add) {
    if (!im->mem) return; int64_t sg = add ? 1 : -1;
    atomic_fetch_add(&g_tex_mem, (uint64_t)(sg * (int64_t)im->mem)); atomic_fetch_add(&g_tex_n, (uint64_t)sg);
    if (im->bc) { atomic_fetch_add(&g_bc_mem, (uint64_t)(sg * (int64_t)im->mem)); atomic_fetch_add(&g_bc_n, (uint64_t)sg); atomic_fetch_add(&g_bc_orig, (uint64_t)(sg * (int64_t)im->bc_orig)); }
}
static void tex_mem_report(void) {
    static uint64_t last; uint64_t t = atomic_load(&g_tex_mem);
    if ((t > last ? t - last : last - t) < (64ull << 20)) return; last = t;
    LOG("[vk] 贴图内存：%llu 张共 %llu MB；其中 BC 解压建图 %llu 张 %llu MB（原 BC 格式本该 %llu MB）；Metal 设备已分配 %llu MB（第 %llu 帧）",
        (unsigned long long)atomic_load(&g_tex_n), (unsigned long long)(t >> 20), (unsigned long long)atomic_load(&g_bc_n), (unsigned long long)(atomic_load(&g_bc_mem) >> 20),
        (unsigned long long)(atomic_load(&g_bc_orig) >> 20), (unsigned long long)(g_dev.currentAllocatedSize >> 20), (unsigned long long)g_frames);
}
// BC 的 VkFormat → nvn_bcdec 的格式号与解压后的 VkFormat；不是 BC 回 0
static uint32_t vk_bc_map(VkFormat f, VkFormat *plain) {
    switch (f) {
        case VK_FORMAT_BC1_RGB_UNORM_BLOCK: *plain = VK_FORMAT_R8G8B8A8_UNORM; return 0x41;
        case VK_FORMAT_BC1_RGBA_UNORM_BLOCK: *plain = VK_FORMAT_R8G8B8A8_UNORM; return 0x42;
        case VK_FORMAT_BC2_UNORM_BLOCK: *plain = VK_FORMAT_R8G8B8A8_UNORM; return 0x43;
        case VK_FORMAT_BC3_UNORM_BLOCK: *plain = VK_FORMAT_R8G8B8A8_UNORM; return 0x44;
        case VK_FORMAT_BC1_RGB_SRGB_BLOCK: *plain = VK_FORMAT_R8G8B8A8_SRGB; return 0x45;
        case VK_FORMAT_BC1_RGBA_SRGB_BLOCK: *plain = VK_FORMAT_R8G8B8A8_SRGB; return 0x46;
        case VK_FORMAT_BC2_SRGB_BLOCK: *plain = VK_FORMAT_R8G8B8A8_SRGB; return 0x47;
        case VK_FORMAT_BC3_SRGB_BLOCK: *plain = VK_FORMAT_R8G8B8A8_SRGB; return 0x48;
        case VK_FORMAT_BC4_UNORM_BLOCK: *plain = VK_FORMAT_R8_UNORM; return 0x49;
        case VK_FORMAT_BC4_SNORM_BLOCK: *plain = VK_FORMAT_R8_SNORM; return 0x4a;
        case VK_FORMAT_BC5_UNORM_BLOCK: *plain = VK_FORMAT_R8G8_UNORM; return 0x4b;
        case VK_FORMAT_BC5_SNORM_BLOCK: *plain = VK_FORMAT_R8G8_SNORM; return 0x4c;
        case VK_FORMAT_BC7_UNORM_BLOCK: *plain = VK_FORMAT_R8G8B8A8_UNORM; return 0x4d;
        case VK_FORMAT_BC7_SRGB_BLOCK: *plain = VK_FORMAT_R8G8B8A8_SRGB; return 0x4e;
        case VK_FORMAT_BC6H_SFLOAT_BLOCK: *plain = VK_FORMAT_R16G16B16A16_SFLOAT; return 0x4f;
        case VK_FORMAT_BC6H_UFLOAT_BLOCK: *plain = VK_FORMAT_R16G16B16A16_SFLOAT; return 0x50;
        default: return 0;
    }
}
VKB(vkCreateImage, VkResult, VkDevice d, const VkImageCreateInfo *ci, const VkAllocationCallbacks *a, VkImage *out) {
    (void)d; (void)a; dev_init();
    const fmt_t *f = fmt_of(ci->format);
    if (!f || f->pf == MTLPixelFormatInvalid) { LOG("[vk] 【红】 image format %d not mapped", ci->format); return VK_ERROR_FORMAT_NOT_SUPPORTED; }
    uint32_t bc = 0;   // 显卡不认 BC：这张图用解压后的格式建（表项整个换掉：之后图像的尺寸 / 视图 / 图像间拷贝都按不压缩的算），im->bc 记原格式供上传时解码
    const fmt_t *f_orig = f;
    if (f->kind == K_BLOCK && vk_no_bc()) { VkFormat plain = VK_FORMAT_UNDEFINED; uint32_t n = vk_bc_map(ci->format, &plain); const fmt_t *pf2 = n ? fmt_of(plain) : NULL;
        if (pf2 && pf2->pf != MTLPixelFormatInvalid) { bc = n; f = pf2; } }
    // Linear 2D images with one level and layer alias their memory, as on the Switch: the texture is made over the bound buffer at vkBindImageMemory, with rows at
    // Metal's linear-texture alignment (which vkGetImageSubresourceLayout reports). Super Mario Galaxy fills staging images from the CPU this way and samples a 4x4 one
    if (ci->tiling == VK_IMAGE_TILING_LINEAR && ci->imageType == VK_IMAGE_TYPE_2D && ci->mipLevels <= 1 && ci->arrayLayers <= 1 && ci->samples <= 1 && f->kind != K_BLOCK && !fmt_has_depth(f) && !fmt_has_stencil(f)) {
        NSUInteger al = [g_dev minimumLinearTextureAlignmentForPixelFormat:f->pf]; if (!al) al = 256;
        VkImage im = obj_alloc(sizeof *im, O_IMAGE);
        im->f = f; im->fmt = ci->format; im->type = ci->imageType; im->w = ci->extent.width; im->h = umax(1, ci->extent.height); im->d = im->mips = im->layers = im->samples = 1;
        im->usage = ci->usage; im->pitch = (uint32_t)(((NSUInteger)im->w * f->bytes + al - 1) / al * al); im->size = (VkDeviceSize)im->pitch * im->h;
        OLOG("CreateImage %p %ux%u format %d linear (pitch %u) usage %#x", (void *)im, im->w, im->h, ci->format, im->pitch, ci->usage);
        *out = im; return VK_SUCCESS;
    }
    if (ci->tiling == VK_IMAGE_TILING_LINEAR) RED1("linear image %ux%u format %d levels %u layers %u: content does not follow the bound memory", ci->extent.width, ci->extent.height, ci->format, ci->mipLevels, ci->arrayLayers);
    @autoreleasepool {
        uint32_t layers = umax(1, ci->arrayLayers), samples = umax(1, ci->samples);
        int cube = (ci->flags & VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT) && layers % 6 == 0;
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        uint32_t wid = wd_new_id(), tw = ci->extent.width, th = umax(1, ci->extent.height);   // 能当渲染附件的二维图像问宽屏核心要实际宽 / 高（核心关 / 不放宽 = 原宽高；窄屏加高 = 放高高）
        if (ci->imageType == VK_IMAGE_TYPE_2D && !cube && (ci->usage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT))) tw = wd_image(wid, tw, th, 1, &th);
        td.pixelFormat = f->pf; td.width = tw; td.height = th; td.depth = umax(1, ci->extent.depth);
        td.mipmapLevelCount = umax(1, ci->mipLevels); td.sampleCount = samples;
        if (ci->imageType == VK_IMAGE_TYPE_3D) td.textureType = MTLTextureType3D;
        // 一维图像建成高度 1 的二维贴图：Vulkan 允许一维图像做渲染附件，Metal 不许一维贴图做附件（校验层中止，哈迪斯 1.0.38233）；着色器里的一维采样出包时同样翻成二维
        //   （vk_shaders.py --msl-texture-1d-as-2d，库口径 2），两边类型一致
        else if (ci->imageType == VK_IMAGE_TYPE_1D) td.textureType = layers > 1 ? MTLTextureType2DArray : MTLTextureType2D;
        else if (samples > 1) td.textureType = layers > 1 ? MTLTextureType2DMultisampleArray : MTLTextureType2DMultisample;
        else if (cube) td.textureType = layers > 6 ? MTLTextureTypeCubeArray : MTLTextureTypeCube;
        else td.textureType = layers > 1 ? MTLTextureType2DArray : MTLTextureType2D;
        td.arrayLength = cube ? layers / 6 : layers;
        MTLTextureUsage u = MTLTextureUsageShaderRead;
        if (ci->usage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT)) u |= MTLTextureUsageRenderTarget;
        // vkCmdClearColorImage / vkCmdClearDepthStencilImage / vkCmdBlitImage into a transfer destination render into it (vk_core.inc); compressed formats are never rendered
        if ((ci->usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT) && f->kind != K_BLOCK) u |= MTLTextureUsageRenderTarget;
        if (ci->usage & VK_IMAGE_USAGE_STORAGE_BIT) u |= MTLTextureUsageShaderWrite;
        // 图像原子（审计 #1534 P1-66，MSL 3.1 原生贴图原子）：Vulkan 里 R32 整数存储图像能不能做原子看格式能力、不看用途位；Metal 文档要 MTLTextureUsageShaderAtomic
        //   （iOS 17 / macOS 14 起），同 graphics/metal/gal_tex.m atomic_usage、直连 NVN tex_atomic_usage
        if ((u & MTLTextureUsageShaderWrite) && (f->pf == MTLPixelFormatR32Uint || f->pf == MTLPixelFormatR32Sint)) u |= MTLTextureUsageShaderAtomic;
        // 深度模板图像的模板视图（vkCreateImageView 取模板方面）在 Metal 里是 X32_Stencil8 视图，Metal 只许带「格式视图」用法的贴图这样取；
        //   Vulkan 取模板方面不要求可变格式标志，所以深度模板图像一律带上（Metal 校验层下不带会在第一次取视图时中止进程；有无此用法同尺寸贴图占用相同，上游 10-24 实测）
        if ((ci->flags & VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT) || f->kind == K_DS) u |= MTLTextureUsagePixelFormatView;
        td.usage = u; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
        if (!t) { LOG("[vk] 【红】 cannot create image %ux%ux%u format %d levels %u layers %u", ci->extent.width, ci->extent.height, ci->extent.depth, ci->format, ci->mipLevels, layers); return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
        VkImage im = obj_alloc(sizeof *im, O_IMAGE);
        im->tex = t; im->f = f; im->bc = bc; im->fmt = ci->format; im->type = ci->imageType; im->w = ci->extent.width; im->h = umax(1, ci->extent.height); im->d = (uint32_t)td.depth; im->wid = wid;   // 游戏的宽高（存储可能被放宽 / 加高）
        im->mips = (uint32_t)td.mipmapLevelCount; im->layers = layers; im->samples = samples; im->size = img_bytes(f, im->w, im->h, im->d, im->mips, layers, samples);
        OLOG("CreateImage %p %ux%ux%u format %d levels %u layers %u usage %#x", (void *)im, im->w, im->h, im->d, ci->format, im->mips, layers, ci->usage);
        im->mem = t.allocatedSize; if (bc) im->bc_orig = img_bytes(f_orig, im->w, im->h, im->d, im->mips, layers, samples); tex_mem_note(im, 1);
        wd_track(im, 1);   // 本层存储可重建：宽屏核心按内容判成画布时按贴图号找回它（vk_widen.inc）
        *out = im;
    }
    return VK_SUCCESS;
}
VKB(vkDestroyImage, void, VkDevice d, VkImage im, const VkAllocationCallbacks *a) { (void)d; (void)a; if (im) { tex_mem_note(im, 0); wd_track(im, 0); wd_release(im->wid); im->tex = nil; obj_free(im); } }
VK(vkGetImageMemoryRequirements, void, VkDevice d, VkImage im, VkMemoryRequirements *r) {
    (void)d; r->alignment = 4096; r->size = (im->size + 4095) & ~4095ull; r->memoryTypeBits = 7;
}
VK(vkGetImageMemoryRequirements2, void, VkDevice d, const VkImageMemoryRequirementsInfo2 *i, VkMemoryRequirements2 *r) {
    h_vkGetImageMemoryRequirements(d, i->image, &r->memoryRequirements); dedicated_req(r->pNext);
}
VK(vkGetImageSubresourceLayout, void, VkDevice d, VkImage im, const VkImageSubresource *sr, VkSubresourceLayout *l) {   // a linear image's own pitch; others tightly packed, mip levels then layers
    (void)d; const fmt_t *f = im->f; VkDeviceSize off = 0;
    if (im->pitch) { l->offset = 0; l->rowPitch = im->pitch; l->depthPitch = l->arrayPitch = l->size = im->size; return; }
    for (uint32_t m = 0; m < sr->mipLevel && m < im->mips; m++) off += img_bytes(f, umax(1, im->w >> m), umax(1, im->h >> m), umax(1, im->d >> m), 1, im->layers, im->samples);
    uint32_t w = umax(1, im->w >> sr->mipLevel), h = umax(1, im->h >> sr->mipLevel), dd = umax(1, im->d >> sr->mipLevel);
    l->rowPitch = (VkDeviceSize)((w + f->bw - 1) / f->bw) * f->bytes; l->depthPitch = l->rowPitch * ((h + f->bh - 1) / f->bh);
    l->arrayPitch = l->depthPitch * dd; l->size = l->arrayPitch; l->offset = off + l->arrayPitch * sr->arrayLayer;
}
VKB(vkBindImageMemory, VkResult, VkDevice d, VkImage im, VkDeviceMemory m, VkDeviceSize off) {   // other images keep their own storage
    (void)d; if (!im->pitch) return VK_SUCCESS;
    id<MTLBuffer> b = mem_buf(m); if (!b) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:im->f->pf width:im->w height:im->h mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.resourceOptions = MTLResourceStorageModeShared;
        td.usage = MTLTextureUsageShaderRead | (im->usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT ? MTLTextureUsageRenderTarget : 0) | (im->usage & VK_IMAGE_USAGE_STORAGE_BIT ? MTLTextureUsageShaderWrite : 0);
        im->tex = [b newTextureWithDescriptor:td offset:off bytesPerRow:im->pitch];
    }
    if (!im->tex) { LOG("[vk] 【红】 cannot create linear image %ux%u format %d (offset %llu pitch %u)", im->w, im->h, im->fmt, (unsigned long long)off, im->pitch); return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
    return VK_SUCCESS;
}
VKB(vkBindImageMemory2, VkResult, VkDevice d, uint32_t n, const VkBindImageMemoryInfo *bi) {
    for (uint32_t i = 0; i < n; i++) { VkResult r = h_vkBindImageMemory(d, bi[i].image, bi[i].memory, bi[i].memoryOffset); if (r) return r; }
    return VK_SUCCESS;
}

static MTLTextureSwizzle swz(VkComponentSwizzle s, MTLTextureSwizzle own) {
    switch (s) {
        case VK_COMPONENT_SWIZZLE_ZERO: return MTLTextureSwizzleZero;
        case VK_COMPONENT_SWIZZLE_ONE: return MTLTextureSwizzleOne;
        case VK_COMPONENT_SWIZZLE_R: return MTLTextureSwizzleRed;
        case VK_COMPONENT_SWIZZLE_G: return MTLTextureSwizzleGreen;
        case VK_COMPONENT_SWIZZLE_B: return MTLTextureSwizzleBlue;
        case VK_COMPONENT_SWIZZLE_A: return MTLTextureSwizzleAlpha;
        default: return own;
    }
}
static void h_vkDestroyImageView(VkDevice d, VkImageView v, const VkAllocationCallbacks *a);   // 建不成时收掉半个视图
VKB(vkCreateImageView, VkResult, VkDevice d, const VkImageViewCreateInfo *ci, const VkAllocationCallbacks *a, VkImageView *out) {
    (void)d; (void)a;
    VkImage im = ci->image; const fmt_t *f = fmt_of(ci->format);
    if (im->bc && f && f->kind == K_BLOCK) { VkFormat plain = VK_FORMAT_UNDEFINED; f = vk_bc_map(ci->format, &plain) ? fmt_of(plain) : NULL; }   // 解压图上的 BC 视图：换成解压后的对应格式（UNORM / sRGB 两种视图各归各的）
    MTLPixelFormat pf = f && f->pf != MTLPixelFormatInvalid ? f->pf : im->f->pf;
    const VkImageSubresourceRange *r = &ci->subresourceRange;
    if (r->aspectMask == VK_IMAGE_ASPECT_STENCIL_BIT && pf == MTLPixelFormatDepth32Float_Stencil8) pf = MTLPixelFormatX32_Stencil8;
    uint32_t lv = r->levelCount == VK_REMAINING_MIP_LEVELS ? im->mips - r->baseMipLevel : r->levelCount;
    uint32_t ly = r->layerCount == VK_REMAINING_ARRAY_LAYERS ? im->layers - r->baseArrayLayer : r->layerCount;
    MTLTextureType tt;
    switch (ci->viewType) {
        case VK_IMAGE_VIEW_TYPE_1D: tt = MTLTextureType2D; break;             // 一维按二维（见 vkCreateImage）
        case VK_IMAGE_VIEW_TYPE_1D_ARRAY: tt = MTLTextureType2DArray; break;
        case VK_IMAGE_VIEW_TYPE_3D: tt = MTLTextureType3D; break;
        case VK_IMAGE_VIEW_TYPE_CUBE: tt = MTLTextureTypeCube; break;
        case VK_IMAGE_VIEW_TYPE_CUBE_ARRAY: tt = MTLTextureTypeCubeArray; break;
        case VK_IMAGE_VIEW_TYPE_2D_ARRAY: tt = im->samples > 1 ? MTLTextureType2DMultisampleArray : MTLTextureType2DArray; break;
        default: tt = im->samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D; break;
    }
    // P1-45：子资源范围越出图像（起始级别 / 层超出，REMAINING 减出下溢）——不建视图，回失败码、交空句柄（vkCreateImageView 只有内存类失败码，取设备内存那条）
    if (!lv || (uint64_t)r->baseMipLevel + lv > im->mips || (im->type != VK_IMAGE_TYPE_3D && tt != MTLTextureType3D && (!ly || (uint64_t)r->baseArrayLayer + ly > im->layers))) {
        RED1("vkCreateImageView 范围越界：级别 %u+%u（共 %u）层 %u+%u（共 %u）：回 VK_ERROR_OUT_OF_DEVICE_MEMORY", r->baseMipLevel, lv, im->mips, r->baseArrayLayer, ly, im->layers);
        *out = VK_NULL_HANDLE; return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    int bc1rgb = im->fmt == VK_FORMAT_BC1_RGB_UNORM_BLOCK || im->fmt == VK_FORMAT_BC1_RGB_SRGB_BLOCK;   // Metal decodes BC1 with punch-through alpha; Vulkan's RGB variant has none
    MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsMake(swz(ci->components.r, MTLTextureSwizzleRed), swz(ci->components.g, MTLTextureSwizzleGreen),
                                                                 swz(ci->components.b, MTLTextureSwizzleBlue), bc1rgb ? MTLTextureSwizzleOne : swz(ci->components.a, MTLTextureSwizzleAlpha));
    int ident = sw.red == MTLTextureSwizzleRed && sw.green == MTLTextureSwizzleGreen && sw.blue == MTLTextureSwizzleBlue && sw.alpha == MTLTextureSwizzleAlpha;
    VkImageView v = obj_alloc(sizeof *v, O_IMAGE_VIEW); v->img = im;
    v->pf = pf; v->tt = tt; v->lv0 = r->baseMipLevel; v->lvn = lv; v->ly0 = r->baseArrayLayer; v->lyn = ly; v->sw = sw; v->vnext = im->views; im->views = v;
    v->wid = wd_new_id(); v->gw = umax(1, im->w >> r->baseMipLevel); v->gh = umax(1, im->h >> r->baseMipLevel); wd_view(v->wid, im->wid, (int)r->baseMipLevel, v->gw);
    v->whole = pf == im->tex.pixelFormat && tt == im->tex.textureType && !r->baseMipLevel && lv == im->mips && !r->baseArrayLayer && ly == im->layers && ident;
    if (v->whole) v->tex = im->tex;
    else @autoreleasepool {
        v->tex = [im->tex newTextureViewWithPixelFormat:pf textureType:tt levels:NSMakeRange(r->baseMipLevel, lv)
                                                  slices:NSMakeRange(tt == MTLTextureType3D ? 0 : r->baseArrayLayer, tt == MTLTextureType3D ? 1 : ly) swizzle:sw];
    }
    if (!v->tex && im->tex) {   // Metal 建不出视图：同越界，回失败码、交空句柄（图像本身没建成时视图照旧留空，图像那一步已回过失败码）
        LOG("[vk] 【红】 cannot create image view: format %d → %lu type %lu levels %u+%u layers %u+%u", im->fmt, (unsigned long)pf, (unsigned long)tt, r->baseMipLevel, lv, r->baseArrayLayer, ly);
        h_vkDestroyImageView(d, v, a); *out = VK_NULL_HANDLE; return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    *out = v; return VK_SUCCESS;
}
VKB(vkDestroyImageView, void, VkDevice d, VkImageView v, const VkAllocationCallbacks *a) {
    (void)d; (void)a; if (!v) return;
    if (v->img) for (VkImageView *pp = &v->img->views; *pp; pp = &(*pp)->vnext) if (*pp == v) { *pp = v->vnext; break; }   // 摘出图像的视图链（游戏可以先毁图像：那时图像已不在，不摘）
    wd_release(v->wid); v->tex = nil; obj_free(v);
}

static MTLSamplerAddressMode addr_mode(VkSamplerAddressMode m) {
    switch (m) {
        case VK_SAMPLER_ADDRESS_MODE_REPEAT: return MTLSamplerAddressModeRepeat;
        case VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT: return MTLSamplerAddressModeMirrorRepeat;
        case VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER: return MTLSamplerAddressModeClampToBorderColor;
        case VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE: return MTLSamplerAddressModeMirrorClampToEdge;
        default: return MTLSamplerAddressModeClampToEdge;
    }
}
VKB(vkCreateSampler, VkResult, VkDevice d, const VkSamplerCreateInfo *ci, const VkAllocationCallbacks *a, VkSampler *out) {
    (void)d; (void)a; dev_init();
    @autoreleasepool {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = ci->minFilter == VK_FILTER_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.magFilter = ci->magFilter == VK_FILTER_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.mipFilter = ci->mipmapMode == VK_SAMPLER_MIPMAP_MODE_LINEAR ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
        sd.sAddressMode = addr_mode(ci->addressModeU); sd.tAddressMode = addr_mode(ci->addressModeV); sd.rAddressMode = addr_mode(ci->addressModeW);
        sd.maxAnisotropy = ci->anisotropyEnable ? (NSUInteger)fminf(fmaxf(ci->maxAnisotropy, 1), 16) : 1;
        if (ci->compareEnable) sd.compareFunction = (MTLCompareFunction)ci->compareOp;   // VkCompareOp and MTLCompareFunction share their values
        sd.borderColor = ci->borderColor >= VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE ? MTLSamplerBorderColorOpaqueWhite :
                         ci->borderColor >= VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK ? MTLSamplerBorderColorOpaqueBlack : MTLSamplerBorderColorTransparentBlack;
        sd.lodMinClamp = ci->minLod; sd.lodMaxClamp = ci->maxLod;
        sd.normalizedCoordinates = !ci->unnormalizedCoordinates;
        // LOD bias: Vulkan clamps it to ±maxSamplerLodBias (15, reported above; Super Mario Galaxy 2 asks for 1.0 on some samplers). Metal has it on the sampler from macOS / iOS 26
        //   (lodBias, S4.6, [-16, 15.999]), and only some GPUs apply it (#800, gal_samp_caps.h: M5 / M4 Pro yes, M3 silently not): where this GPU does not (g_vk_lb_emu, systems before 26
        //   too) the sampler carries none and the draws that bind it run the pipeline's emulation variant, which adds it to each sample's LOD (vk_lbias.inc, vk_se_pso)
        VkSampler s = obj_alloc(sizeof *s, O_SAMPLER);
        if (ci->mipLodBias != 0) {
            float b = fminf(fmaxf(ci->mipLodBias, -15.0f), 15.0f);
            if (g_vk_lb_emu) s->lb = b; else if (@available(macOS 26.0, iOS 26.0, *)) sd.lodBias = b;
        }
        s->s = [g_dev newSamplerStateWithDescriptor:sd];
        if (!s->s) LOG("[vk] 【红】 cannot create the sampler");
        *out = s;
    }
    return VK_SUCCESS;
}
VKB(vkDestroySampler, void, VkDevice d, VkSampler s, const VkAllocationCallbacks *a) { (void)d; (void)a; if (s) { s->s = nil; obj_free(s); } }
// Sampler Y′CbCr conversion: the feature (samplerYcbcrConversion) is not offered, so a game may not create one; one that does gets a handle and a report
VK(vkCreateSamplerYcbcrConversion, VkResult, VkDevice d, const VkSamplerYcbcrConversionCreateInfo *ci, const VkAllocationCallbacks *a, VkSamplerYcbcrConversion *out) {
    (void)d; (void)a; RED1("sampler Y'CbCr conversion (format %d) not supported: the feature is not offered", ci->format); *out = obj_alloc(sizeof **out, O_PLAIN); return VK_SUCCESS;
}
VK(vkDestroySamplerYcbcrConversion, void, VkDevice d, VkSamplerYcbcrConversion c, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(c); }

// ---------- Descriptor sets ----------
static int is_dyn(VkDescriptorType t) { return t == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC || t == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC; }
VK(vkCreateDescriptorSetLayout, VkResult, VkDevice d, const VkDescriptorSetLayoutCreateInfo *ci, const VkAllocationCallbacks *a, VkDescriptorSetLayout *out) {
    (void)d; (void)a;
    if (ci->bindingCount > MAXB) { LOG("[vk] 【红】 descriptor set layout with %u bindings, over %d", ci->bindingCount, MAXB); return VK_ERROR_OUT_OF_HOST_MEMORY; }
    VkDescriptorSetLayout L = obj_alloc(sizeof *L, O_LAYOUT); memset(L->idx, -1, sizeof L->idx);
    const VkDescriptorSetLayoutBinding *src[MAXB];
    for (uint32_t i = 0; i < ci->bindingCount; i++) {   // sorted by binding number: the order dynamic offsets are consumed in
        uint32_t j = i; src[i] = &ci->pBindings[i];
        while (j && src[j - 1]->binding > src[j]->binding) { const VkDescriptorSetLayoutBinding *t = src[j]; src[j] = src[j - 1]; src[j - 1] = t; j--; }
    }
    int nimm = 0;
    for (uint32_t i = 0; i < ci->bindingCount; i++) {
        const VkDescriptorSetLayoutBinding *b = src[i]; lbind *o = &L->b[L->n];
        if (b->binding >= 128) { LOG("[vk] 【红】 binding number %u over 127", b->binding); continue; }
        o->binding = b->binding; o->count = b->descriptorCount; o->type = b->descriptorType; o->base = L->total; o->dyn = -1;
        if (is_dyn(b->descriptorType)) { o->dyn = (int)L->ndyn; L->ndyn += b->descriptorCount; }
        o->imm = b->pImmutableSamplers && (b->descriptorType == VK_DESCRIPTOR_TYPE_SAMPLER || b->descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
        nimm += o->imm;
        L->idx[b->binding] = (int8_t)L->n++; L->total += b->descriptorCount;
    }
    if (nimm) {
        L->imm = zalloc(umax(1, L->total) * sizeof *L->imm);
        for (uint32_t i = 0, k = 0; i < ci->bindingCount; i++) {
            const VkDescriptorSetLayoutBinding *b = src[i]; if (b->binding >= 128) continue;
            if (L->b[k].imm) memcpy(&L->imm[L->b[k].base], b->pImmutableSamplers, b->descriptorCount * sizeof *L->imm);
            k++;
        }
    }
    if (L->ndyn > 16) LOG("[vk] 【红】 %u dynamic offsets in one set, over 16", L->ndyn);
    *out = L; return VK_SUCCESS;
}
VK(vkGetDescriptorSetLayoutSupport, void, VkDevice d, const VkDescriptorSetLayoutCreateInfo *ci, VkDescriptorSetLayoutSupport *out) {
    (void)d; int ok = ci->bindingCount <= MAXB;   // the limits vkCreateDescriptorSetLayout keeps (binding numbers below 128, at most MAXB bindings)
    for (uint32_t i = 0; ok && i < ci->bindingCount; i++) ok = ci->pBindings[i].binding < 128;
    out->supported = ok ? VK_TRUE : VK_FALSE;
}
VK(vkDestroyDescriptorSetLayout, void, VkDevice d, VkDescriptorSetLayout L, const VkAllocationCallbacks *a) { (void)d; (void)L; (void)a; }   // kept: sets allocated from it still read it
VK(vkCreateDescriptorPool, VkResult, VkDevice d, const VkDescriptorPoolCreateInfo *ci, const VkAllocationCallbacks *a, VkDescriptorPool *out) {
    (void)d; (void)ci; (void)a; *out = obj_alloc(sizeof **out, O_PLAIN); return VK_SUCCESS;
}
static void set_free(VkDescriptorSet s) {
    VkDescriptorPool p = s->pool;
    if (s->prev) s->prev->next = s->next; else p->sets = s->next;
    if (s->next) s->next->prev = s->prev;
    for (uint32_t k = 0; k < s->L->total; k++) s->d[k] = (desc_t){0};   // releases what the descriptors hold
    free(s->d); obj_free(s);
}
VK(vkResetDescriptorPool, VkResult, VkDevice d, VkDescriptorPool p, VkDescriptorPoolResetFlags f) { (void)d; (void)f; while (p->sets) set_free(p->sets); return VK_SUCCESS; }
VK(vkDestroyDescriptorPool, void, VkDevice d, VkDescriptorPool p, const VkAllocationCallbacks *a) { (void)a; if (p) { h_vkResetDescriptorPool(d, p, 0); obj_free(p); } }
VK(vkAllocateDescriptorSets, VkResult, VkDevice d, const VkDescriptorSetAllocateInfo *ai, VkDescriptorSet *out) {
    (void)d;
    for (uint32_t i = 0; i < ai->descriptorSetCount; i++) {
        VkDescriptorSetLayout L = ai->pSetLayouts[i];
        VkDescriptorSet s = obj_alloc(sizeof *s, O_SET); s->d = zalloc(umax(1, L->total) * sizeof(desc_t));
        s->L = L; s->pool = ai->descriptorPool; s->next = s->pool->sets; if (s->next) s->next->prev = s; s->pool->sets = s;
        if (L->imm) for (uint32_t k = 0; k < L->total; k++) { s->d[k].smp = L->imm[k] ? L->imm[k]->s : nil; s->d[k].lb = L->imm[k] ? L->imm[k]->lb : 0; }
        out[i] = s;
    }
    return VK_SUCCESS;
}
VK(vkFreeDescriptorSets, VkResult, VkDevice d, VkDescriptorPool p, uint32_t n, const VkDescriptorSet *s) {
    (void)d; (void)p; for (uint32_t i = 0; i < n; i++) if (s[i]) set_free(s[i]);
    return VK_SUCCESS;
}
// Element `elem` of `binding`; an index past the binding's count continues into the next bindings (Vulkan's consecutive-binding updates)
static desc_t *set_elem(VkDescriptorSet s, uint32_t binding, uint32_t elem, const lbind **lb) {
    const VkDescriptorSetLayout L = s->L; int i = binding < 128 ? L->idx[binding] : -1;
    if (i < 0) { RED1("write descriptor: binding %u not in the layout", binding); return NULL; }
    while (elem >= L->b[i].count) { elem -= L->b[i].count; if (++i >= (int)L->n) { RED1("write descriptor past the end of the layout (binding %u)", binding); return NULL; } }
    *lb = &L->b[i]; return &s->d[L->b[i].base + elem];
}
static void desc_write(desc_t *e, const lbind *lb, VkDescriptorType t, const VkDescriptorImageInfo *ii, const VkDescriptorBufferInfo *bi, const VkBufferView *bv) {
    switch (t) {
        case VK_DESCRIPTOR_TYPE_SAMPLER: if (!lb->imm) { e->smp = ii->sampler ? ii->sampler->s : nil; e->lb = ii->sampler ? ii->sampler->lb : 0; } break;
        case VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: e->tex = ii->imageView ? ii->imageView->tex : nil; if (!lb->imm) { e->smp = ii->sampler ? ii->sampler->s : nil; e->lb = ii->sampler ? ii->sampler->lb : 0; }
            e->wid = ii->imageView ? ii->imageView->wid : 0; e->gw = ii->imageView ? ii->imageView->gw : 0; e->gh = ii->imageView ? ii->imageView->gh : 0; break;
        case VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE: case VK_DESCRIPTOR_TYPE_STORAGE_IMAGE: case VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT: e->tex = ii->imageView ? ii->imageView->tex : nil;
            e->wid = ii->imageView ? ii->imageView->wid : 0; e->gw = ii->imageView ? ii->imageView->gw : 0; e->gh = ii->imageView ? ii->imageView->gh : 0; break;
        case VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER: case VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER: e->tex = *bv ? bview_tex(*bv) : nil; break;
        case VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER: case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: case VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC: case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC: {
            VkBuffer b = bi->buffer; e->buf = b && b->mem ? mem_buf(b->mem) : nil; e->off = b ? b->off + bi->offset : 0; e->range = bi->range == VK_WHOLE_SIZE ? 0 : bi->range; break;   // a buffer is bound to its memory before it is written
        }
        default: RED1("descriptor type %d not implemented", t); break;
    }
}
VK(vkUpdateDescriptorSets, void, VkDevice d, uint32_t nw, const VkWriteDescriptorSet *w, uint32_t nc, const VkCopyDescriptorSet *c) {
    (void)d;
    for (uint32_t i = 0; i < nw; i++)
        for (uint32_t j = 0; j < w[i].descriptorCount; j++) {
            const lbind *lb; desc_t *e = set_elem(w[i].dstSet, w[i].dstBinding, w[i].dstArrayElement + j, &lb); if (!e) break;
            desc_write(e, lb, w[i].descriptorType, w[i].pImageInfo ? &w[i].pImageInfo[j] : NULL, w[i].pBufferInfo ? &w[i].pBufferInfo[j] : NULL,
                       w[i].pTexelBufferView ? &w[i].pTexelBufferView[j] : NULL);
        }
    for (uint32_t i = 0; i < nc; i++)
        for (uint32_t j = 0; j < c[i].descriptorCount; j++) {
            const lbind *la, *lb; desc_t *s = set_elem(c[i].srcSet, c[i].srcBinding, c[i].srcArrayElement + j, &la), *t = set_elem(c[i].dstSet, c[i].dstBinding, c[i].dstArrayElement + j, &lb);
            if (s && t) *t = *s;
        }
}
VK(vkCreateDescriptorUpdateTemplate, VkResult, VkDevice d, const VkDescriptorUpdateTemplateCreateInfo *ci, const VkAllocationCallbacks *a, VkDescriptorUpdateTemplate *out) {
    (void)d; (void)a;
    if (ci->templateType != VK_DESCRIPTOR_UPDATE_TEMPLATE_TYPE_DESCRIPTOR_SET) RED1("descriptor update template type %d not implemented", ci->templateType);
    VkDescriptorUpdateTemplate t = obj_alloc(sizeof *t + ci->descriptorUpdateEntryCount * sizeof(VkDescriptorUpdateTemplateEntry), O_PLAIN);
    t->n = ci->descriptorUpdateEntryCount; memcpy(t->e, ci->pDescriptorUpdateEntries, t->n * sizeof *t->e);
    *out = t; return VK_SUCCESS;
}
VK(vkDestroyDescriptorUpdateTemplate, void, VkDevice d, VkDescriptorUpdateTemplate t, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(t); }
VK(vkUpdateDescriptorSetWithTemplate, void, VkDevice d, VkDescriptorSet s, VkDescriptorUpdateTemplate t, const void *data) {
    (void)d;
    for (uint32_t i = 0; i < t->n; i++) {
        const VkDescriptorUpdateTemplateEntry *en = &t->e[i];
        for (uint32_t j = 0; j < en->descriptorCount; j++) {
            const uint8_t *p = (const uint8_t *)data + en->offset + j * en->stride;
            const lbind *lb; desc_t *e = set_elem(s, en->dstBinding, en->dstArrayElement + j, &lb); if (!e) break;
            desc_write(e, lb, en->descriptorType, (const VkDescriptorImageInfo *)p, (const VkDescriptorBufferInfo *)p, (const VkBufferView *)p);
        }
    }
}
VK(vkCreatePipelineLayout, VkResult, VkDevice d, const VkPipelineLayoutCreateInfo *ci, const VkAllocationCallbacks *a, VkPipelineLayout *out) {
    (void)d; (void)a; VkPipelineLayout l = obj_alloc(sizeof *l, O_PLAIN);
    if (ci->setLayoutCount > 8) LOG("[vk] 【红】 pipeline layout with %u sets, over 8", ci->setLayoutCount);
    l->nset = umin(ci->setLayoutCount, 8); memcpy(l->set, ci->pSetLayouts, l->nset * sizeof *l->set);
    for (uint32_t i = 0; i < ci->pushConstantRangeCount; i++) l->pc_size = umax(l->pc_size, ci->pPushConstantRanges[i].offset + ci->pPushConstantRanges[i].size);
    if (l->pc_size > 256) { LOG("[vk] 【红】 push constant range %u bytes, over 256", l->pc_size); l->pc_size = 256; }
    *out = l; return VK_SUCCESS;
}
VK(vkDestroyPipelineLayout, void, VkDevice d, VkPipelineLayout l, const VkAllocationCallbacks *a) { (void)d; (void)l; (void)a; }   // kept: pipelines point at it

// ---------- Render passes, framebuffers ----------
VK(vkCreateRenderPass, VkResult, VkDevice d, const VkRenderPassCreateInfo *ci, const VkAllocationCallbacks *a, VkRenderPass *out) {
    (void)d; (void)a;
    if (ci->attachmentCount > 16 || !ci->subpassCount || ci->subpassCount > 8) { LOG("[vk] 【红】 render pass: %u attachments, %u subpasses", ci->attachmentCount, ci->subpassCount); return VK_ERROR_OUT_OF_HOST_MEMORY; }
    VkRenderPass rp = obj_alloc(sizeof *rp, O_PLAIN); rp->natt = ci->attachmentCount; rp->nsub = ci->subpassCount;
    memset(rp->first, -1, sizeof rp->first); memset(rp->last, -1, sizeof rp->last);
    for (uint32_t i = 0; i < rp->natt; i++) {
        const VkAttachmentDescription *at = &ci->pAttachments[i];
        rp->att[i] = (ratt){at->format, at->loadOp, at->stencilLoadOp, at->storeOp, at->stencilStoreOp};
    }
    for (uint32_t k = 0; k < rp->nsub; k++) {
        const VkSubpassDescription *sp = &ci->pSubpasses[k]; rsub *o = &rp->sub[k];
        o->ncol = umin(sp->colorAttachmentCount, 8);
        for (uint32_t i = 0; i < o->ncol; i++) {
            uint32_t c = sp->pColorAttachments[i].attachment, r = sp->pResolveAttachments ? sp->pResolveAttachments[i].attachment : VK_ATTACHMENT_UNUSED;
            o->col[i] = c == VK_ATTACHMENT_UNUSED || c >= rp->natt ? -1 : (int)c; o->res[i] = r == VK_ATTACHMENT_UNUSED || r >= rp->natt ? -1 : (int)r;
        }
        o->depth = sp->pDepthStencilAttachment && sp->pDepthStencilAttachment->attachment < rp->natt ? (int)sp->pDepthStencilAttachment->attachment : -1;
        // an attachment counts as used by a subpass that renders into, resolves into or reads it (input attachments are read as textures, written by an earlier subpass)
        int used[16] = {0};
        for (uint32_t i = 0; i < o->ncol; i++) { if (o->col[i] >= 0) used[o->col[i]] = 1; if (o->res[i] >= 0) used[o->res[i]] = 1; }
        if (o->depth >= 0) used[o->depth] = 1;
        for (uint32_t i = 0; i < sp->inputAttachmentCount; i++) if (sp->pInputAttachments[i].attachment < rp->natt) used[sp->pInputAttachments[i].attachment] = 1;
        for (uint32_t i = 0; i < rp->natt; i++) if (used[i]) { if (rp->first[i] < 0) rp->first[i] = (int8_t)k; rp->last[i] = (int8_t)k; }
    }
    *out = rp; return VK_SUCCESS;
}
VK(vkDestroyRenderPass, void, VkDevice d, VkRenderPass rp, const VkAllocationCallbacks *a) { (void)d; (void)rp; (void)a; }   // kept: recorded commands may still name it
VK(vkCreateFramebuffer, VkResult, VkDevice d, const VkFramebufferCreateInfo *ci, const VkAllocationCallbacks *a, VkFramebuffer *out) {
    (void)d; (void)a;
    if (ci->attachmentCount > 16) { LOG("[vk] 【红】 framebuffer with %u attachments", ci->attachmentCount); return VK_ERROR_OUT_OF_HOST_MEMORY; }
    VkFramebuffer fb = obj_alloc(sizeof *fb, O_PLAIN); fb->n = ci->attachmentCount; fb->w = ci->width; fb->h = ci->height; fb->layers = ci->layers;
    memcpy(fb->v, ci->pAttachments, fb->n * sizeof *fb->v);
    *out = fb; return VK_SUCCESS;
}
VK(vkDestroyFramebuffer, void, VkDevice d, VkFramebuffer fb, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(fb); }
VK(vkGetRenderAreaGranularity, void, VkDevice d, VkRenderPass rp, VkExtent2D *g) { (void)d; (void)rp; *g = (VkExtent2D){1, 1}; }   // Metal renders any area

// ---------- Shaders and pipelines ----------
// DM_VK_CAPTURE=<dir> (Mac): every SPIR-V module the game creates is written to <dir>/<key>.spv. Super Mario Galaxy generates its GX shaders as SPIR-V at run time
// (over 3,000 at boot, from the pipeline database), so no game file holds them; vk_shaders.py translates a capture folder like a RomFS
static void sh_capture(const char *key, const void *code, size_t n) {
    static const char *dir; static int init;
    if (!init) { init = 1; dir = getenv("DM_VK_CAPTURE"); if (dir) VLOG("shader capture → %s", dir); }
    if (!dir) return;
    char p[1024]; snprintf(p, sizeof p, "%s/%s.spv", dir, key);
    if (access(p, F_OK) == 0) return;
    char t[1100]; snprintf(t, sizeof t, "%s.%d.tmp", p, getpid());
    FILE *f = fopen(t, "wb"); if (!f) { RED1("shader capture cannot write to %s", dir); return; }
    int ok = fwrite(code, 1, n, f) == n; ok &= fclose(f) == 0;
    if (ok) rename(t, p); else unlink(t);   // whole files only: a capture run may be killed at any time
}
#include "vk_rt.inc"
#include "vk_lbias.inc"   // #800：LOD 偏置改写（vk_lb_rewrite）
#include "vk_vin.inc"   // 顶点输入整型符号性：换同宽格式 / 按管线格式重翻顶点着色器
// 偏置模拟变体的表槽：这支没用到的最高缓冲槽（u / b / p 占的槽之外；片元阶段没有顶点流），-1 = 没有空槽
static int vk_se_slot(const shinfo *si) {
    uint32_t used = 0;
    for (int i = 0; si && i < si->nres; i++) { const shres *r = &si->res[i]; if (r->kind == 'u' || r->kind == 'b' || r->kind == 'p') for (int k = 0; k < (r->kind == 'p' ? 1 : r->count); k++) if (r->slot + k < 31) used |= 1u << (r->slot + k); }
    for (int k = 30; k >= 0; k--) if (!(used >> k & 1)) return k;
    return -1;
}
// 现出一支的偏置模拟版函数（同步，提交线程第一次要它时；耗时记一行）：设备上重翻这支的 SPIR-V（s2a_vk_xlate，与出包 vk_shaders.py 同口径，资源栏必须与离线库那行一致），
//   入口 vk_<键>（双源混合管线用 vk_<键>_d）经 vk_lb_rewrite 加偏置、表在 se_slot，现编。nil = 做不了（why 写原因）
static id<MTLFunction> vk_se_fn(VkPipeline p, const shinfo *si, char *why, size_t cap) {
    if (!s2a_vk_xlate) { snprintf(why, cap, "这份宿主没有设备上的 SPIR-V 翻译（graphics/metal gal_vkx.m）"); return nil; }
    if (!si || (p->se_slot = vk_se_slot(si)) < 0) { snprintf(why, cap, "没有空的缓冲槽放偏置表"); return nil; }
    char *msl = NULL, *msl_d = NULL, res[2048], err[512]; int stage = 0; id<MTLFunction> fn = nil;
    int rc = s2a_vk_xlate(p->se_spv.bytes, p->se_spv.length / 4, p->se_key, &msl, &msl_d, res, sizeof res, &stage, err, sizeof err);
    shinfo t; memset(&t, 0, sizeof t); if (!rc) sh_parse(&t, res);
    const char *src = p->se_dual ? msl_d : msl; char entry[40]; snprintf(entry, sizeof entry, "vk_%s%s", p->se_key, p->se_dual ? "_d" : "");
    char *out = NULL; int left = 0, n = 0;
    if (rc || !src) snprintf(why, cap, "设备上重翻失败（%d）：%.300s", rc, err);
    else if (t.nres != si->nres || memcmp(t.res, si->res, sizeof *si->res * (size_t)si->nres)) snprintf(why, cap, "设备上重翻出的资源栏与离线库那行不同（翻译口径漂了）");
    else if ((n = vk_lb_rewrite(src, entry, p->se_slot, &out, &left)) <= 0) snprintf(why, cap, n < 0 ? "认不出入口 %s" : "入口 %s 里没有能加偏置的采样", entry);
    else {
        fn = rt_fn(out, entry, why, cap);
        if (fn && left) { static int k; if (k++ < 16) LOG("[vk] 【红】 偏置模拟：%s 有 %d 处采样没加偏置（比较采样 / 采样器数组 / 入口外函数）", p->se_key, left); }
    }
    free(msl); free(msl_d); free(out);
    return fn;
}
// 管线的偏置模拟版（片元 / 计算），第一次要时建、之后复用；建不出（se_state 2）返回 nil，那些绘制照原样（不加偏置），报红一次
static id vk_se_obj(VkPipeline p, int comp) {
    if (p->se_state == 1) return comp ? (id)p->cps_se : (id)p->pso_se;
    if (p->se_state == 2 || !p->se_spv) return nil;
    @autoreleasepool {
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); char why[600] = ""; NSError *e = nil;
        id<MTLFunction> fn = vk_se_fn(p, comp ? p->cs : p->fs, why, sizeof why);
        if (fn && comp) { p->cps_se = [g_dev newComputePipelineStateWithFunction:fn error:&e]; if (!p->cps_se) snprintf(why, sizeof why, "建计算管线失败：%s", e.localizedDescription.UTF8String); }
        else if (fn) { MTLRenderPipelineDescriptor *d = [p->se_pd copy]; d.fragmentFunction = fn; p->pso_se = d ? [g_dev newRenderPipelineStateWithDescriptor:d error:&e] : nil;
            if (!p->pso_se) snprintf(why, sizeof why, "建渲染管线失败：%s", e ? e.localizedDescription.UTF8String : "没有描述"); }
        p->se_state = (comp ? p->cps_se != nil : p->pso_se != nil) ? 1 : 2;
        if (p->se_state == 1) LOG("[vk] 偏置模拟：%s 的%s管线建好（%.1f ms，表在 %d 号缓冲槽）", p->se_key, comp ? "计算" : "渲染", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, p->se_slot);
        else { static int k; if (k++ < 16) LOG("[vk] 【红】 偏置模拟：%s 绑了本机 GPU 不认 LOD 偏置的采样器，模拟版建不出（%s）：这些绘制不加偏置", p->se_key, why); }
    }
    return p->se_state == 1 ? (comp ? (id)p->cps_se : (id)p->pso_se) : nil;
}
VKB(vkCreateShaderModule, VkResult, VkDevice d, const VkShaderModuleCreateInfo *ci, const VkAllocationCallbacks *a, VkShaderModule *out) {
    (void)d; (void)a; dev_init();
    uint8_t h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(ci->pCode, (CC_LONG)ci->codeSize, h);
    VkShaderModule m = obj_alloc(sizeof *m, O_SHADER);
    for (int i = 0; i < 8; i++) snprintf(m->key + 2 * i, 3, "%02x", h[i]);
    sh_capture(m->key, ci->pCode, ci->codeSize);
    vin_scan(ci->pCode, ci->codeSize / 4, &m->vin_s, &m->vin_u);
    if (g_vk_lb_emu || m->vin_s || m->vin_u) m->spv = [NSData dataWithBytes:ci->pCode length:ci->codeSize];   // #800：偏置模拟变体要在设备上重翻它（vk_se_fn）；顶点输入格式与符号性不一致时重翻（vk_vin.inc）
    m->si = sh_find(m->key);
    @autoreleasepool { if (m->si && g_lib) m->fn = [g_lib newFunctionWithName:[NSString stringWithFormat:@"vk_%s", m->key]]; }
    if (!m->fn) { m->rt = rt_get(m->key, ci->pCode, ci->codeSize); mod_ready(m); }   // 离线库没有：设备现编（已编好 / 上次持久化的直接用，否则后台编，编好前建的管线照安全网跳过）
    else OLOG("CreateShaderModule %s", m->key);
    *out = m; return VK_SUCCESS;
}
VKB(vkDestroyShaderModule, void, VkDevice d, VkShaderModule m, const VkAllocationCallbacks *a) { (void)d; (void)a; if (m) { m->fn = m->fn_d = nil; m->spv = nil; obj_free(m); } }
// Pipeline caches hold nothing: the game's initial data is NVIDIA's binary cache (Super Mario Galaxy's data/database/vulkan/*.cache), and Metal keeps its own
VK(vkCreatePipelineCache, VkResult, VkDevice d, const VkPipelineCacheCreateInfo *ci, const VkAllocationCallbacks *a, VkPipelineCache *out) {
    (void)d; (void)ci; (void)a; *out = obj_alloc(sizeof **out, O_PLAIN); return VK_SUCCESS;
}
VK(vkDestroyPipelineCache, void, VkDevice d, VkPipelineCache c, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(c); }
VK(vkGetPipelineCacheData, VkResult, VkDevice d, VkPipelineCache c, size_t *n, void *data) { (void)d; (void)c; (void)data; *n = 0; return VK_SUCCESS; }
VK(vkMergePipelineCaches, VkResult, VkDevice d, VkPipelineCache dst, uint32_t n, const VkPipelineCache *src) { (void)d; (void)dst; (void)n; (void)src; return VK_SUCCESS; }

static MTLBlendFactor blend_f(VkBlendFactor f) {
    static const MTLBlendFactor t[] = {MTLBlendFactorZero, MTLBlendFactorOne, MTLBlendFactorSourceColor, MTLBlendFactorOneMinusSourceColor, MTLBlendFactorDestinationColor,
        MTLBlendFactorOneMinusDestinationColor, MTLBlendFactorSourceAlpha, MTLBlendFactorOneMinusSourceAlpha, MTLBlendFactorDestinationAlpha, MTLBlendFactorOneMinusDestinationAlpha,
        MTLBlendFactorBlendColor, MTLBlendFactorOneMinusBlendColor, MTLBlendFactorBlendAlpha, MTLBlendFactorOneMinusBlendAlpha, MTLBlendFactorSourceAlphaSaturated,
        MTLBlendFactorSource1Color, MTLBlendFactorOneMinusSource1Color, MTLBlendFactorSource1Alpha, MTLBlendFactorOneMinusSource1Alpha};
    return (unsigned)f < sizeof t / sizeof *t ? t[f] : MTLBlendFactorOne;
}
static MTLColorWriteMask write_mask(VkColorComponentFlags m) {   // the bit order is reversed: Vulkan R = 1 … A = 8, Metal R = 8 … A = 1
    return (m & VK_COLOR_COMPONENT_R_BIT ? MTLColorWriteMaskRed : 0) | (m & VK_COLOR_COMPONENT_G_BIT ? MTLColorWriteMaskGreen : 0) |
           (m & VK_COLOR_COMPONENT_B_BIT ? MTLColorWriteMaskBlue : 0) | (m & VK_COLOR_COMPONENT_A_BIT ? MTLColorWriteMaskAlpha : 0);
}
static MTLStencilDescriptor *stencil_d(const VkStencilOpState *s) {   // VkStencilOp / VkCompareOp share their values with Metal's
    MTLStencilDescriptor *d = [MTLStencilDescriptor new];
    d.stencilCompareFunction = (MTLCompareFunction)s->compareOp; d.stencilFailureOperation = (MTLStencilOperation)s->failOp;
    d.depthFailureOperation = (MTLStencilOperation)s->depthFailOp; d.depthStencilPassOperation = (MTLStencilOperation)s->passOp;
    d.readMask = s->compareMask; d.writeMask = s->writeMask;
    return d;
}
static MTLViewport vp_of(const VkViewport *v) { return (MTLViewport){v->x, v->y, v->width, v->height, v->minDepth, v->maxDepth}; }   // the shaders flip y, so the viewport stays as given
static int src1_factor(VkBlendFactor f) { return f >= VK_BLEND_FACTOR_SRC1_COLOR && f <= VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA; }
static int dual_source(const VkPipelineColorBlendStateCreateInfo *cb) {   // a blend factor reads the second source
    for (uint32_t i = 0; cb && i < cb->attachmentCount; i++) {
        const VkPipelineColorBlendAttachmentState *b = &cb->pAttachments[i];
        if (b->blendEnable && (src1_factor(b->srcColorBlendFactor) || src1_factor(b->dstColorBlendFactor) || src1_factor(b->srcAlphaBlendFactor) || src1_factor(b->dstAlphaBlendFactor))) return 1;
    }
    return 0;
}
static int rt_state(struct rt_ent *e) { return e ? atomic_load_explicit(&e->state, memory_order_acquire) : 1; }
static VkPipeline pipe_make(const VkGraphicsPipelineCreateInfo *ci) {
    VkPipeline p = obj_alloc(sizeof *p, O_PIPELINE); p->layout = ci->layout;
    @autoreleasepool {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        char keys[64] = ""; int dual = dual_source(ci->pColorBlendState); VkShaderModule vm = NULL; uint32_t u8 = 0, u16 = 0;
        for (uint32_t s = 0; s < ci->stageCount; s++) {
            const VkPipelineShaderStageCreateInfo *st = &ci->pStages[s]; VkShaderModule m = st->module;
            if (st->pSpecializationInfo && st->pSpecializationInfo->mapEntryCount) RED1("specialization constants not implemented");
            mod_ready(m);
            struct rt_ent *wait = !m->fn && m->rt && atomic_load_explicit(&m->rt->state, memory_order_acquire) == 0 ? m->rt : NULL;   // 它那份现编还在编
            if (st->stage == VK_SHADER_STAGE_VERTEX_BIT) { pd.vertexFunction = m->fn; p->vs = m->si; p->pend_v = wait; vm = m; }
            else if (st->stage == VK_SHADER_STAGE_FRAGMENT_BIT) {
                if (dual && m->fn) {   // pipelines may be built on several threads
                    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; pthread_mutex_lock(&mu);
                    if (!m->tried_d) { m->tried_d = 1; m->fn_d = [g_lib newFunctionWithName:[NSString stringWithFormat:@"vk_%s_d", m->key]]; }
                    pthread_mutex_unlock(&mu);
                }
                pd.fragmentFunction = dual && m->fn_d ? m->fn_d : m->fn; p->fs = m->si; p->pend_f = wait;
                if (wait) { p->pend_dual = dual; p->pend_spv = m->spv; }
                if (m->spv && m->fn) { p->se_spv = m->spv; p->se_dual = dual && m->fn_d; memcpy(p->se_key, m->key, 17); }   // #800：偏置模拟变体（vk_se_pso）
            }
            else { RED1("shader stage %#x not implemented", st->stage); p->feat = 1; if (st->stage == VK_SHADER_STAGE_GEOMETRY_BIT) p->gs = 1; }
            strlcat(keys, s ? " " : "", sizeof keys); strlcat(keys, m->key, sizeof keys);
        }
        if (!pd.vertexFunction && !p->pend_v) { LOG("[vk] 【红】 pipeline has no usable vertex shader (%s)", keys); return p; }
        const VkPipelineVertexInputStateCreateInfo *vi = ci->pVertexInputState;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        uint32_t used = 0;   // bindings some mapped attribute reads: Metal's validation rejects a buffer layout no attribute uses
        for (uint32_t i = 0; vi && i < vi->vertexAttributeDescriptionCount; i++) {
            const VkVertexInputAttributeDescription *at = &vi->pVertexAttributeDescriptions[i]; const fmt_t *f = fmt_of(at->format);
            if (!f || f->vf == MTLVertexFormatInvalid || at->location >= 31 || at->binding >= 14) { LOG("[vk] 【红】 vertex attribute %u format %d not mapped", at->location, at->format); continue; }
            vd.attributes[at->location].format = vin_fix(vm, at->location, f->vf, &u8, &u16); vd.attributes[at->location].offset = at->offset; vd.attributes[at->location].bufferIndex = 30 - at->binding;
            used |= 1u << at->binding;
        }
        for (uint32_t i = 0; vi && i < vi->vertexBindingDescriptionCount; i++) {
            const VkVertexInputBindingDescription *b = &vi->pVertexBindingDescriptions[i];
            if (b->binding >= 14) { LOG("[vk] 【红】 vertex binding %u over 13", b->binding); continue; }
            if (!(used >> b->binding & 1)) continue;
            MTLVertexBufferLayoutDescriptor *l = vd.layouts[30 - b->binding];
            if (b->stride) { l.stride = b->stride; l.stepFunction = b->inputRate == VK_VERTEX_INPUT_RATE_INSTANCE ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex; l.stepRate = 1; }
            else { l.stride = 16; l.stepFunction = MTLVertexStepFunctionConstant; l.stepRate = 0; }
            p->vb_mask |= 1u << b->binding;
        }
        pd.vertexDescriptor = vd;
        if (u8 | u16) {   // 8 / 16 位无符号格式喂有符号输入：用按本管线格式重翻的那支顶点着色器（vk_vin.inc）
            rt_ent *v = vin_variant(vm, u8, u16); int vs = rt_state(v);
            if (vs == 2) { LOG("[vk] 【红】 pipeline (%s): the vertex shader retranslated for its integer attribute formats is not usable", keys); return p; }
            if (vs == 1) { pd.vertexFunction = v->fn; p->vs = &v->si; p->pend_v = NULL; } else { pd.vertexFunction = nil; p->pend_v = v; }
        }
        switch (ci->pInputAssemblyState ? ci->pInputAssemblyState->topology : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST) {
            case VK_PRIMITIVE_TOPOLOGY_POINT_LIST: p->prim = MTLPrimitiveTypePoint; pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint; break;
            case VK_PRIMITIVE_TOPOLOGY_LINE_LIST: p->prim = MTLPrimitiveTypeLine; pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassLine; break;
            case VK_PRIMITIVE_TOPOLOGY_LINE_STRIP: p->prim = MTLPrimitiveTypeLineStrip; pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassLine; break;
            case VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP: p->prim = MTLPrimitiveTypeTriangleStrip; break;
            case VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: p->prim = MTLPrimitiveTypeTriangle; break;
            default: RED1("primitive topology %d not implemented", ci->pInputAssemblyState->topology); p->prim = MTLPrimitiveTypeTriangle; break;
        }
        const VkPipelineRasterizationStateCreateInfo *rs = ci->pRasterizationState;
        p->cull = !rs || rs->cullMode == VK_CULL_MODE_NONE ? MTLCullModeNone : rs->cullMode == VK_CULL_MODE_FRONT_BIT ? MTLCullModeFront : rs->cullMode == VK_CULL_MODE_BACK_BIT ? MTLCullModeBack : MTLCullModeNone;
        if (rs && rs->cullMode == VK_CULL_MODE_FRONT_AND_BACK) RED1("culling both front and back faces not implemented");
        p->wind = rs && rs->frontFace == VK_FRONT_FACE_CLOCKWISE ? MTLWindingClockwise : MTLWindingCounterClockwise;   // framebuffer winding is the same once the shaders flip y
        p->fill = rs && rs->polygonMode == VK_POLYGON_MODE_LINE ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        p->clip = rs && rs->depthClampEnable ? MTLDepthClipModeClamp : MTLDepthClipModeClip;
        if (rs && rs->depthBiasEnable) { p->bias = 1; p->bias_c = rs->depthBiasConstantFactor; p->bias_s = rs->depthBiasSlopeFactor; p->bias_cl = rs->depthBiasClamp; }
        if (rs && rs->rasterizerDiscardEnable) pd.rasterizationEnabled = NO;
        const VkPipelineMultisampleStateCreateInfo *ms = ci->pMultisampleState;
        pd.rasterSampleCount = ms ? umax(1, ms->rasterizationSamples) : 1; pd.alphaToCoverageEnabled = ms && ms->alphaToCoverageEnable;
        if (ms && ms->sampleShadingEnable) RED1("pipeline with sampleShadingEnable (min %g): fragments run per pixel, not per sample (P2-3, 待读数定)", ms->minSampleShading);
        VkRenderPass rp = ci->renderPass; p->sub = ci->subpass < rp->nsub ? ci->subpass : 0; const rsub *sp = &rp->sub[p->sub];
        const VkPipelineColorBlendStateCreateInfo *cb = ci->pColorBlendState;
        if (cb && cb->logicOpEnable) RED1("logic op blending not implemented");
        for (uint32_t i = 0; i < sp->ncol; i++) {
            int at = sp->col[i]; if (at < 0) continue;
            const fmt_t *f = fmt_of(rp->att[at].fmt); MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[i];
            ca.pixelFormat = f ? f->pf : MTLPixelFormatInvalid;
            if (cb && i < cb->attachmentCount) {
                const VkPipelineColorBlendAttachmentState *b = &cb->pAttachments[cb->attachmentCount > 1 ? i : 0];
                ca.writeMask = write_mask(b->colorWriteMask);
                if (b->blendEnable && f && f->kind == K_COLOR) {
                    ca.blendingEnabled = YES;
                    ca.sourceRGBBlendFactor = blend_f(b->srcColorBlendFactor); ca.destinationRGBBlendFactor = blend_f(b->dstColorBlendFactor); ca.rgbBlendOperation = (MTLBlendOperation)b->colorBlendOp;
                    ca.sourceAlphaBlendFactor = blend_f(b->srcAlphaBlendFactor); ca.destinationAlphaBlendFactor = blend_f(b->dstAlphaBlendFactor); ca.alphaBlendOperation = (MTLBlendOperation)b->alphaBlendOp;
                }
            }
        }
        if (cb) memcpy(p->blend, cb->blendConstants, sizeof p->blend);
        const fmt_t *df = sp->depth >= 0 ? fmt_of(rp->att[sp->depth].fmt) : NULL;
        if (fmt_has_depth(df)) pd.depthAttachmentPixelFormat = df->pf;
        if (fmt_has_stencil(df)) pd.stencilAttachmentPixelFormat = df->pf;
        const VkPipelineDepthStencilStateCreateInfo *ds = ci->pDepthStencilState;
        if (df && ds) {
            MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
            if (fmt_has_depth(df) && ds->depthTestEnable) { dd.depthCompareFunction = (MTLCompareFunction)ds->depthCompareOp; dd.depthWriteEnabled = ds->depthWriteEnable != 0; }
            if (fmt_has_stencil(df) && ds->stencilTestEnable) { dd.frontFaceStencil = stencil_d(&ds->front); dd.backFaceStencil = stencil_d(&ds->back); p->sref_f = ds->front.reference; p->sref_b = ds->back.reference; }
            if (ds->depthBoundsTestEnable) RED1("depth bounds test not implemented");
            p->dss = [g_dev newDepthStencilStateWithDescriptor:dd];
            if (fmt_has_stencil(df) && ds->stencilTestEnable) p->dsd = dd;   // kept for dynamic stencil masks (made into states at draw time, see pre_draw)
        } else p->dss = g_dss_off;
        const VkPipelineDynamicStateCreateInfo *dy = ci->pDynamicState;
        for (uint32_t i = 0; dy && i < dy->dynamicStateCount; i++) {
            VkDynamicState s = dy->pDynamicStates[i];
            if (s == VK_DYNAMIC_STATE_VIEWPORT) p->dyn_vp = 1; else if (s == VK_DYNAMIC_STATE_SCISSOR) p->dyn_sc = 1;
            else if (s == VK_DYNAMIC_STATE_DEPTH_BIAS) p->dyn |= DYN_BIAS; else if (s == VK_DYNAMIC_STATE_BLEND_CONSTANTS) p->dyn |= DYN_BLEND;
            else if (s == VK_DYNAMIC_STATE_STENCIL_REFERENCE) p->dyn |= DYN_SREF;
            else if (s == VK_DYNAMIC_STATE_LINE_WIDTH) {}   // Metal draws lines 1 pixel wide; vkCmdSetLineWidth reports a width other than 1
            else if (s == VK_DYNAMIC_STATE_DEPTH_BOUNDS) {}   // matters only with the depth bounds test on, which is reported where the depth-stencil state is made
            // baked into Metal's depth-stencil state: with the stencil test on, a state per mask set is made at draw time (they matter only then)
            else if (s == VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK) p->dyn |= DYN_SCMP;
            else if (s == VK_DYNAMIC_STATE_STENCIL_WRITE_MASK) p->dyn |= DYN_SWR;
            else RED1("dynamic state %d not implemented", s);
        }
        const VkPipelineViewportStateCreateInfo *vs = ci->pViewportState;
        if (!p->dyn_vp && vs && vs->pViewports && vs->viewportCount) { p->vp = vp_of(&vs->pViewports[0]); p->has_vp = 1; }
        if (!p->dyn_sc && vs && vs->pScissors && vs->scissorCount) { p->sc = vs->pScissors[0]; p->has_sc = 1; }
        if (p->pend_v || p->pend_f) {   // 着色器还在现编：描述存下，编好后第一次绘制补建（pipe_finish）
            p->pend_pd = pd; static _Atomic int n; if (n++ < 20) LOG("[vk] 现编：管线 (%s) 的着色器还在编，句柄先交，编好后第一次绘制补建（第 %llu 帧）", keys, (unsigned long long)g_frames);
            return p;
        }
        NSError *err = nil;
        p->pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!p->pso) { static int n; if (n++ < 20) LOG("[vk] 【红】 cannot build the pipeline (%s): %s", keys, err.localizedDescription.UTF8String); }
        else g_n_pso++;
        if (p->pso && p->se_spv) p->se_pd = pd;   // 偏置模拟变体照同一份描述建，只换片元函数
    }
    return p;
}
static _Atomic uint64_t g_pend_made, g_pend_bad;   // 等现编的管线：补建成 / 着色器编不过（补不成，绘制照安全网跳过）
void dm_vk_pend_stats(uint64_t *made, uint64_t *bad) { *made = g_pend_made; *bad = g_pend_bad; }
// 等现编的渲染管线：它等的着色器都编好就照存下的描述补建（绘制线程调；几条队列可能同时回放，加锁）
static void pipe_finish(VkPipeline p) {
    if (p->pso || !p->pend_pd) return;
    if (!rt_state(p->pend_v) || !rt_state(p->pend_f)) return;   // 还在编：这笔照安全网跳过
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; pthread_mutex_lock(&mu);
    if (!p->pso && p->pend_pd) @autoreleasepool {
        MTLRenderPipelineDescriptor *pd = p->pend_pd; p->pend_pd = nil;
        if (rt_state(p->pend_v) == 2 || rt_state(p->pend_f) == 2) { g_pend_bad++; LOG("[vk] 【红】 现编：管线等的着色器编不过（%s），这条管线的绘制照安全网跳过", rt_state(p->pend_v) == 2 ? p->pend_v->key : p->pend_f->key); }
        else {
            if (p->pend_v) { pd.vertexFunction = p->pend_v->fn; p->vs = &p->pend_v->si; }
            if (p->pend_f) {
                pd.fragmentFunction = p->pend_dual && p->pend_f->fn_d ? p->pend_f->fn_d : p->pend_f->fn; p->fs = &p->pend_f->si;
                if (p->pend_spv) { p->se_spv = p->pend_spv; p->se_dual = p->pend_dual && p->pend_f->fn_d; memcpy(p->se_key, p->pend_f->key, 17); }   // #800：偏置模拟变体
            }
            NSError *err = nil; p->pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!p->pso) { g_pend_bad++; LOG("[vk] 【红】 现编：补建管线被 Metal 拒（%s）", err.localizedDescription.UTF8String); }
            else { g_n_pso++; g_pend_made++; if (p->se_spv) p->se_pd = pd; }
        }
        p->pend_spv = nil;
    }
    pthread_mutex_unlock(&mu);
}
static void h_vkDestroyPipeline(VkDevice d, VkPipeline p, const VkAllocationCallbacks *a);   // 建不成的那一项当场收掉（vkCreateComputePipelines 同）
VKB(vkCreateGraphicsPipelines, VkResult, VkDevice d, VkPipelineCache c, uint32_t n, const VkGraphicsPipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *out) {
    (void)d; (void)c; (void)a; dev_init();
    VkResult rc = VK_SUCCESS;
    for (uint32_t i = 0; i < n; i++) {
        out[i] = pipe_make(&ci[i]);
        // P1-46：建不成（没有可用顶点着色器 / Metal 拒）：这一项交 VK_NULL_HANDLE、整批回失败码，其余照建（规范：实现尽量建全部，失败的那几项填空句柄）
        if (!out[i]->pso && !out[i]->pend_pd) { RED1("vkCreateGraphicsPipelines：管线没建成：交空句柄、回 VK_ERROR_OUT_OF_DEVICE_MEMORY"); h_vkDestroyPipeline(d, out[i], a); out[i] = VK_NULL_HANDLE; rc = VK_ERROR_OUT_OF_DEVICE_MEMORY; }
    }
    return rc;
}
VKB(vkDestroyPipeline, void, VkDevice d, VkPipeline p, const VkAllocationCallbacks *a) { (void)d; (void)a; if (p) { p->pso = nil; p->dss = nil; p->dsd = nil; p->dss_dyn = nil; p->cps = nil; p->se_spv = nil; p->se_pd = nil; p->pso_se = nil; p->cps_se = nil; p->pend_pd = nil; p->pend_spv = nil; obj_free(p); } }

// ---------- Command buffers: recording ----------
enum { C_BRP = 1, C_ERP, C_PIPE, C_SETS, C_VB, C_IB, C_VP, C_SC, C_DRAWI, C_COPYB, C_COPYB2I, C_DRAW, C_PUSH, C_COPYI, C_COPYI2B, C_QRESET, C_QTS, C_QBEGIN, C_QEND, C_BIAS, C_BLEND, C_SREF, C_INDIRECT, C_BARRIER,
       C_EVENT, C_WAITEV, C_SMASK, C_FILL, C_UPDATE, C_CLRIMG, C_CLRATT, C_BLIT, C_RESOLVE, C_QCOPY, C_CPIPE, C_CSETS, C_DISPATCH, C_DISPATCHI, C_EXEC, C_NEXTSP, C_DEBUG_LABEL };
typedef struct { uint32_t op, size; } chdr;
typedef struct { VkRenderPass rp; VkFramebuffer fb; VkRect2D area; uint32_t nclear; VkClearValue clear[]; } c_brp;
typedef struct { VkPipeline p; } c_pipe;
typedef struct { uint32_t first, n, ndyn; VkDescriptorSet s[8]; uint32_t dyn[]; } c_sets;
typedef struct { uint32_t first, n; VkBuffer b[14]; VkDeviceSize o[14]; } c_vb;
typedef struct { VkBuffer b; VkDeviceSize o; VkIndexType t; } c_ib;
typedef struct { VkViewport v; } c_vp;
typedef struct { VkRect2D r; } c_sc;
typedef struct { float v[4]; } c_f4;   // C_BIAS: constant, clamp, slope; C_BLEND: the four constants
typedef struct { uint32_t face, ref; } c_sref;
typedef struct { uint32_t count, inst, first; int32_t voff; uint32_t first_inst; } c_drawi;
typedef struct { VkBuffer src, dst; uint32_t n; VkBufferCopy r[]; } c_copyb;
typedef struct { VkBuffer src; VkImage dst; uint32_t n; VkBufferImageCopy r[]; } c_copyb2i;
typedef struct { uint32_t count, inst, first, first_inst; } c_draw;
typedef struct { VkBuffer args, count; VkDeviceSize offset, count_offset; uint32_t max, stride, indexed; } c_indirect;
enum { B_SHADER_WRITE = 1, B_INDIRECT_READ = 2 };
typedef struct { uint32_t access; } c_barrier;
typedef struct { uint32_t off, size; uint8_t data[]; } c_push;
typedef struct { VkImage src, dst; uint32_t n; VkImageCopy r[]; } c_copyi;
typedef struct { VkImage src; VkBuffer dst; uint32_t n; VkBufferImageCopy r[]; } c_copyi2b;
typedef struct { VkQueryPool q; uint32_t first, n; } c_query;
// vk_core.inc
typedef struct { VkEvent e; int set; } c_event;
typedef struct { uint32_t n; VkEvent e[]; } c_waitev;
typedef struct { uint32_t face, wr, mask; } c_smask;   // wr: 0 比较掩码，1 写掩码
typedef struct { VkBuffer dst; VkDeviceSize off, size; uint32_t data; } c_fill;
typedef struct { VkBuffer dst; VkDeviceSize off, size; uint8_t data[]; } c_update;
typedef struct { VkImage im; int ds; VkClearValue v; uint32_t n; VkImageSubresourceRange r[]; } c_clrimg;
typedef struct { uint32_t na, nr; VkClearAttachment a[9]; VkClearRect r[]; } c_clratt;
typedef struct { VkImage src, dst; VkFilter filter; uint32_t n; VkImageBlit r[]; } c_blit;
typedef struct { VkImage src, dst; uint32_t n; VkImageResolve r[]; } c_resolve;
typedef struct { VkQueryPool q; uint32_t first, n; VkBuffer dst; VkDeviceSize off, stride; VkQueryResultFlags fl; } c_qcopy;
typedef struct { uint32_t x, y, z, bx, by, bz; } c_dispatch;
typedef struct { VkBuffer b; VkDeviceSize off; } c_dispatchi;
typedef struct { uint32_t n; VkCommandBuffer cb[]; } c_exec;
static void *rec(VkCommandBuffer cb, uint32_t op, size_t sz) {
    size_t need = (sizeof(chdr) + sz + 7) & ~(size_t)7;
    if (cb->n + need > cb->cap) {
        size_t c = cb->cap ? cb->cap * 2 : 4096; while (c < cb->n + need) c *= 2;
        cb->buf = realloc(cb->buf, c); if (!cb->buf) die("[vk] out of command buffer memory %zu", c); cb->cap = c;
    }
    chdr *h = (chdr *)(cb->buf + cb->n); h->op = op; h->size = (uint32_t)need; cb->n += need;
    return h + 1;
}
VK(vkCreateCommandPool, VkResult, VkDevice d, const VkCommandPoolCreateInfo *ci, const VkAllocationCallbacks *a, VkCommandPool *out) {
    (void)d; (void)ci; (void)a; *out = obj_alloc(sizeof **out, O_PLAIN); return VK_SUCCESS;
}
static void cb_free(VkCommandBuffer cb) {
    VkCommandPool p = cb->pool;
    if (cb->prev) cb->prev->next = cb->next; else p->cbs = cb->next;
    if (cb->next) cb->next->prev = cb->prev;
    free(cb->buf); obj_free(cb);
}
VK(vkDestroyCommandPool, void, VkDevice d, VkCommandPool p, const VkAllocationCallbacks *a) { (void)d; (void)a; if (p) { while (p->cbs) cb_free(p->cbs); obj_free(p); } }
VK(vkTrimCommandPool, void, VkDevice d, VkCommandPool p, VkCommandPoolTrimFlags f) { (void)d; (void)p; (void)f; }   // command buffers keep no pooled memory to give back
VK(vkResetCommandPool, VkResult, VkDevice d, VkCommandPool p, VkCommandPoolResetFlags f) { (void)d; (void)f; for (VkCommandBuffer c = p->cbs; c; c = c->next) c->n = 0; return VK_SUCCESS; }
VK(vkAllocateCommandBuffers, VkResult, VkDevice d, const VkCommandBufferAllocateInfo *ai, VkCommandBuffer *out) {
    (void)d;
    for (uint32_t i = 0; i < ai->commandBufferCount; i++) {
        VkCommandBuffer cb = obj_alloc(sizeof *cb, O_COMMAND); cb->pool = ai->commandPool;
        cb->next = cb->pool->cbs; if (cb->next) cb->next->prev = cb; cb->pool->cbs = cb;
        out[i] = cb;
    }
    return VK_SUCCESS;
}
VK(vkFreeCommandBuffers, void, VkDevice d, VkCommandPool p, uint32_t n, const VkCommandBuffer *cbs) { (void)d; (void)p; for (uint32_t i = 0; i < n; i++) if (cbs[i]) cb_free(cbs[i]); }
VK(vkBeginCommandBuffer, VkResult, VkCommandBuffer cb, const VkCommandBufferBeginInfo *bi) { (void)bi; cb->n = 0; return VK_SUCCESS; }
VK(vkEndCommandBuffer, VkResult, VkCommandBuffer cb) { (void)cb; return VK_SUCCESS; }
VK(vkResetCommandBuffer, VkResult, VkCommandBuffer cb, VkCommandBufferResetFlags f) { (void)f; cb->n = 0; return VK_SUCCESS; }
VK(vkCmdBeginRenderPass, void, VkCommandBuffer cb, const VkRenderPassBeginInfo *bi, VkSubpassContents sc) {
    (void)sc; uint32_t nc = umin(bi->clearValueCount, 16);
    c_brp *c = rec(cb, C_BRP, sizeof *c + nc * sizeof(VkClearValue));
    c->rp = bi->renderPass; c->fb = bi->framebuffer; c->area = bi->renderArea; c->nclear = nc;
    if (nc) memcpy(c->clear, bi->pClearValues, nc * sizeof(VkClearValue));
}
VK(vkCmdEndRenderPass, void, VkCommandBuffer cb) { rec(cb, C_ERP, 0); }
VK(vkCmdBindPipeline, void, VkCommandBuffer cb, VkPipelineBindPoint bp, VkPipeline p) {
    ((c_pipe *)rec(cb, bp == VK_PIPELINE_BIND_POINT_COMPUTE ? C_CPIPE : C_PIPE, sizeof(c_pipe)))->p = p;
}
VK(vkCmdBindDescriptorSets, void, VkCommandBuffer cb, VkPipelineBindPoint bp, VkPipelineLayout l, uint32_t first, uint32_t n, const VkDescriptorSet *s, uint32_t ndyn, const uint32_t *dyn) {
    (void)l;
    c_sets *c = rec(cb, bp == VK_PIPELINE_BIND_POINT_COMPUTE ? C_CSETS : C_SETS, sizeof *c + ndyn * sizeof(uint32_t));
    c->first = first; c->n = umin(n, 8); c->ndyn = ndyn; memcpy(c->s, s, c->n * sizeof *s); if (ndyn) memcpy(c->dyn, dyn, ndyn * sizeof *dyn);
}
VK(vkCmdBindVertexBuffers, void, VkCommandBuffer cb, uint32_t first, uint32_t n, const VkBuffer *b, const VkDeviceSize *o) {
    c_vb *c = rec(cb, C_VB, sizeof *c); c->first = first; c->n = first < 14 ? umin(n, 14 - first) : 0;
    memcpy(c->b, b, c->n * sizeof *b); memcpy(c->o, o, c->n * sizeof *o);
}
VK(vkCmdBindIndexBuffer, void, VkCommandBuffer cb, VkBuffer b, VkDeviceSize o, VkIndexType t) { c_ib *c = rec(cb, C_IB, sizeof *c); c->b = b; c->o = o; c->t = t; }
VK(vkCmdSetViewport, void, VkCommandBuffer cb, uint32_t first, uint32_t n, const VkViewport *v) { if (!first && n) ((c_vp *)rec(cb, C_VP, sizeof(c_vp)))->v = v[0]; }
VK(vkCmdSetScissor, void, VkCommandBuffer cb, uint32_t first, uint32_t n, const VkRect2D *r) { if (!first && n) ((c_sc *)rec(cb, C_SC, sizeof(c_sc)))->r = r[0]; }
// Dynamic state (Vulkan 1.1 §25 / §26): a pipeline that lists it ignores its own value and draws with the value set last in the command buffer; at the start of a command buffer
// the value is undefined, and the layer takes 0 there (no offset, zero constants), the same as a register cleared at reset
VK(vkCmdSetDepthBias, void, VkCommandBuffer cb, float c, float clamp, float slope) { c_f4 *x = rec(cb, C_BIAS, sizeof(c_f4)); x->v[0] = c; x->v[1] = clamp; x->v[2] = slope; x->v[3] = 0; }
VK(vkCmdSetBlendConstants, void, VkCommandBuffer cb, const float k[4]) { memcpy(((c_f4 *)rec(cb, C_BLEND, sizeof(c_f4)))->v, k, 4 * sizeof *k); }
VK(vkCmdSetStencilReference, void, VkCommandBuffer cb, VkStencilFaceFlags face, uint32_t ref) { c_sref *x = rec(cb, C_SREF, sizeof(c_sref)); x->face = face; x->ref = ref; }
VK(vkCmdSetLineWidth, void, VkCommandBuffer cb, float w) { (void)cb; if (w != 1.0f) RED1("line width %.2f: Metal draws lines 1 pixel wide", w); }
VK(vkCmdDrawIndexed, void, VkCommandBuffer cb, uint32_t count, uint32_t inst, uint32_t first, int32_t voff, uint32_t first_inst) {
    *(c_drawi *)rec(cb, C_DRAWI, sizeof(c_drawi)) = (c_drawi){count, inst, first, voff, first_inst};
}
VK(vkCmdCopyBuffer, void, VkCommandBuffer cb, VkBuffer src, VkBuffer dst, uint32_t n, const VkBufferCopy *r) {
    c_copyb *c = rec(cb, C_COPYB, sizeof *c + n * sizeof *r); c->src = src; c->dst = dst; c->n = n; memcpy(c->r, r, n * sizeof *r);
}
VK(vkCmdCopyBufferToImage, void, VkCommandBuffer cb, VkBuffer src, VkImage dst, VkImageLayout lay, uint32_t n, const VkBufferImageCopy *r) {
    (void)lay; c_copyb2i *c = rec(cb, C_COPYB2I, sizeof *c + n * sizeof *r); c->src = src; c->dst = dst; c->n = n; memcpy(c->r, r, n * sizeof *r);
}
VK(vkCmdDraw, void, VkCommandBuffer cb, uint32_t count, uint32_t inst, uint32_t first, uint32_t first_inst) {
    *(c_draw *)rec(cb, C_DRAW, sizeof(c_draw)) = (c_draw){count, inst, first, first_inst};
}
VK(vkCmdDrawIndirect, void, VkCommandBuffer cb, VkBuffer b, VkDeviceSize off, uint32_t count, uint32_t stride) {
    *(c_indirect *)rec(cb, C_INDIRECT, sizeof(c_indirect)) = (c_indirect){b, NULL, off, 0, count, stride, 0};
}
VK(vkCmdDrawIndexedIndirect, void, VkCommandBuffer cb, VkBuffer b, VkDeviceSize off, uint32_t count, uint32_t stride) {
    *(c_indirect *)rec(cb, C_INDIRECT, sizeof(c_indirect)) = (c_indirect){b, NULL, off, 0, count, stride, 1};
}
VK(vkCmdDrawIndirectCountAMD, void, VkCommandBuffer cb, VkBuffer b, VkDeviceSize off, VkBuffer count, VkDeviceSize count_off, uint32_t max, uint32_t stride) {
    *(c_indirect *)rec(cb, C_INDIRECT, sizeof(c_indirect)) = (c_indirect){b, count, off, count_off, max, stride, 0};
}
VK(vkCmdDrawIndexedIndirectCountAMD, void, VkCommandBuffer cb, VkBuffer b, VkDeviceSize off, VkBuffer count, VkDeviceSize count_off, uint32_t max, uint32_t stride) {
    *(c_indirect *)rec(cb, C_INDIRECT, sizeof(c_indirect)) = (c_indirect){b, count, off, count_off, max, stride, 1};
}
VK(vkCmdPushConstants, void, VkCommandBuffer cb, VkPipelineLayout l, VkShaderStageFlags st, uint32_t off, uint32_t size, const void *v) {
    (void)l; (void)st;
    if (off >= 256 || size > 256 - off) { RED1("push constant out of range: offset %u length %u", off, size); return; }
    c_push *c = rec(cb, C_PUSH, sizeof *c + size); c->off = off; c->size = size; memcpy(c->data, v, size);
}
VK(vkCmdCopyImage, void, VkCommandBuffer cb, VkImage src, VkImageLayout sl, VkImage dst, VkImageLayout dl, uint32_t n, const VkImageCopy *r) {
    (void)sl; (void)dl; c_copyi *c = rec(cb, C_COPYI, sizeof *c + n * sizeof *r); c->src = src; c->dst = dst; c->n = n; memcpy(c->r, r, n * sizeof *r);
}
VK(vkCmdCopyImageToBuffer, void, VkCommandBuffer cb, VkImage src, VkImageLayout lay, VkBuffer dst, uint32_t n, const VkBufferImageCopy *r) {
    (void)lay; c_copyi2b *c = rec(cb, C_COPYI2B, sizeof *c + n * sizeof *r); c->src = src; c->dst = dst; c->n = n; memcpy(c->r, r, n * sizeof *r);
}
VK(vkCmdResetQueryPool, void, VkCommandBuffer cb, VkQueryPool q, uint32_t first, uint32_t n) { *(c_query *)rec(cb, C_QRESET, sizeof(c_query)) = (c_query){q, first, n}; }
VK(vkCmdWriteTimestamp, void, VkCommandBuffer cb, VkPipelineStageFlagBits st, VkQueryPool q, uint32_t i) { (void)st; *(c_query *)rec(cb, C_QTS, sizeof(c_query)) = (c_query){q, i, 1}; }
VK(vkCmdBeginQuery, void, VkCommandBuffer cb, VkQueryPool q, uint32_t i, VkQueryControlFlags f) { (void)f; *(c_query *)rec(cb, C_QBEGIN, sizeof(c_query)) = (c_query){q, i, 1}; }
VK(vkCmdEndQuery, void, VkCommandBuffer cb, VkQueryPool q, uint32_t i) { *(c_query *)rec(cb, C_QEND, sizeof(c_query)) = (c_query){q, i, 1}; }
// Metal tracks hazards between encoders. Keep the two ends of in-pass shader-write dependencies
// (also when spread over a chain of barriers) so pre-pass indirect masking cannot silently read old data.
VK(vkCmdPipelineBarrier, void, VkCommandBuffer cb, VkPipelineStageFlags s, VkPipelineStageFlags d, VkDependencyFlags f, uint32_t nm, const VkMemoryBarrier *m,
   uint32_t nb, const VkBufferMemoryBarrier *b, uint32_t ni, const VkImageMemoryBarrier *i) {
    (void)f; (void)ni; (void)i;
    VkAccessFlags src = 0, dst = 0;
    for (uint32_t k = 0; k < nm; k++) { src |= m[k].srcAccessMask; dst |= m[k].dstAccessMask; }
    for (uint32_t k = 0; k < nb; k++) { src |= b[k].srcAccessMask; dst |= b[k].dstAccessMask; }
    VkPipelineStageFlags shaders = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_TESSELLATION_CONTROL_SHADER_BIT |
        VK_PIPELINE_STAGE_TESSELLATION_EVALUATION_SHADER_BIT | VK_PIPELINE_STAGE_GEOMETRY_SHADER_BIT |
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT |
        VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT | VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    uint32_t access = 0;
    if ((s & shaders) && (src & (VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT))) access |= B_SHADER_WRITE;
    if ((d & (VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT | VK_PIPELINE_STAGE_ALL_COMMANDS_BIT)) &&
        (dst & (VK_ACCESS_INDIRECT_COMMAND_READ_BIT | VK_ACCESS_MEMORY_READ_BIT))) access |= B_INDIRECT_READ;
    if (access) ((c_barrier *)rec(cb, C_BARRIER, sizeof(c_barrier)))->access = access;
}

#include "vk_debug.inc"

// ---------- Command buffers: replay at submit ----------
// 每次 submit 的查询票号与结果。每个查询段占 8 字节；Metal 新建 render encoder 会重置 visibility buffer，
// 因此每段结束后在同一 command buffer 中拷到 results，再在提交完成时写回查询池。无需 26 才有的 accumulate 属性。
typedef struct { VkQueryPool q; uint32_t idx, slot; int add; } occ_t;
typedef struct {
    uint64_t v; id<MTLBuffer> vis, results, indirect; uint32_t nvis, cap; occ_t *occ;
    NSUInteger indirect_used;
    id<MTLBuffer> stage; NSUInteger stage_used;              // vkCmdUpdateBuffer data and vkCmdCopyQueryPoolResults inputs of this submit (sized by the pre-scan)
    struct { VkEvent e; int set; } *ev; uint32_t nev, evcap;   // vkCmdSetEvent / vkCmdResetEvent, applied in order when the submit completes
    id<MTLFence> fc, fw; int fsig;   // 屏障围栏（fence_barrier）：fc 本次提交跑过游戏着色器的编码器收尾时更新、fsig = 更新过；fw 上一个源方含着色器写的屏障交下来、之后新开的编码器都等它
} subq_t;
enum { SET_OLD = 4 };
typedef struct {
    id<MTLCommandBuffer> cb; id<MTLRenderCommandEncoder> re; id<MTLBlitCommandEncoder> be; id<MTLComputeCommandEncoder> ce;
    VkPipeline pipe, applied, cpipe; int applied_se; uint32_t rt_w, rt_h;   // applied_se：applied 那条设的是它的偏置模拟版（#800）
    struct { VkDescriptorSet s; uint32_t dyn[16]; } set[8], cset[8];   // descriptor sets bound for graphics / for compute (Vulkan keeps one list per bind point)
    struct { VkDescriptorSet s; uint32_t dyn[16]; } old[2][8][SET_OLD]; uint8_t nold[2][8];   // 每个集号上被换下来的集（新的在前，[0] 图形 / [1] 计算）：set_of 按绑定号往回找
    uint32_t smask[2][2];                // dynamic stencil compare [0] and write [1] masks, front / back
    const void *brp; uint32_t sub;       // the render pass being run (its begin command, c_brp) and its current subpass
    VkBuffer vb[14]; VkDeviceSize vbo[14];
    VkBuffer ib; VkDeviceSize ibo; MTLIndexType it; uint32_t isz;
    VkViewport vp; VkRect2D sc; int have_vp, have_sc, vp_dirty, sc_dirty;
    float bias[3], blend[4]; uint32_t sref[2]; uint32_t dyn_set, dyn_dirty;   // dynamic state of this command buffer (dyn_set: DYN_* set at least once)
    uint8_t pc[256]; uint64_t pc_seq;   // pc_seq：推常量这份内容的序号（全局单调，g_pc_seq）：宽屏核心按它判推常量变没变（同一块 pc 地址每笔都一样，vk_widen.inc）
    subq_t *sq; int sw;   // sw：开着的计算 / 渲染编码器跑过游戏着色器（可能写存储图像 / 缓冲），收尾或遇屏障时更新围栏
    NSUInteger indirect_next; uint32_t indirect_deps; int indirect_failed;
    uint32_t vis_first;                  // 本 encoder 首个 visibility slot
    VkQueryPool occ_q; uint32_t occ_idx;   // an active query continues in a new visibility slot after an encoder split
    // The current render pass: its descriptor (attachments created with deferred store actions) and the store actions it ends with; cut = its encoder was ended
    // for a copy in the middle of the pass and is resumed (loading the attachments) at the next draw
    MTLRenderPassDescriptor *rpd; MTLStoreAction st_col[8], st_d, st_s; int cut;
    VkImage swap_img;                    // 本子遍画进的交换链图像（记本帧画到的范围，上屏裁切用；不是交换链 = NULL）
    int ra_part; int8_t pres[8][2]; uint32_t npres;   // P1-69：本子遍 renderArea 没盖满帧缓冲（绘制剪裁与它取交）；要按区域解析的（多重采样附件，解析附件）对，子遍收尾时解析（part_resolve）
} rs_t;
static uint64_t g_pc_seq;   // 推常量内容序号（g_qmu 里加：回放只在提交里）
// 着色器读的 (set, binding) 取哪个集（11-05 Minecraft：换了 set 0 布局多一个绑定 65 的管线、没重绑 set 0，0.65 在当前绑的集里没有）：
//   当前绑在这个集号上的集有这个绑定就用它；没有就往回找本命令缓冲里这个集号上先前绑过、有这个绑定的最近那个集——绑定按绑定号各占一格，
//   绑新集只盖新集布局里有的那几格，其余格留着上一次的（NVIDIA 驱动按绑定号占硬件槽，同 Vulkan 层把每个 (set, binding) 落成独立槽的做法）。
//   Vulkan 规范把这种「布局不兼容、被扰动的集」算未定义；原先找不到就跳过不绑，Metal 那个槽留着上一笔别的着色器绑的东西（别的缓冲 / 贴图），画面随绘制顺序乱跳。
//   *dyn：那个集绑定时的动态偏移；*old：取的是先前那个集（1）还是当前的（0）
static VkDescriptorSet set_of(rs_t *s, int st, uint32_t set, uint32_t binding, const uint32_t **dyn, int *old) {
    *dyn = NULL; *old = 0; if (set >= 8 || binding >= 128) return NULL;
    int c = st == 2; VkDescriptorSet ds = (c ? s->cset : s->set)[set].s;
    if (!ds) return NULL;
    int bi = ds->L->idx[binding];
    if (bi >= 0 && ds->L->b[bi].count) { *dyn = (c ? s->cset : s->set)[set].dyn; return ds; }
    for (uint32_t k = 0; k < s->nold[c][set]; k++) {
        VkDescriptorSet o = s->old[c][set][k].s; int oi = o->L->idx[binding];
        if (oi >= 0 && o->L->b[oi].count) { *dyn = s->old[c][set][k].dyn; *old = 1; return o; }
    }
    return ds;   // 都没有：交当前集，调用方按「不在布局里」报
}
// 回放 vkCmdBindDescriptorSets：换下来的集推进 old（同一个集再绑不重复记）
static void set_bind(rs_t *s, int c, uint32_t si, VkDescriptorSet ds, const uint32_t *dyn, uint32_t ndyn, uint32_t *k) {
    typeof(s->set[0]) *cur = &(c ? s->cset : s->set)[si];
    if (cur->s && cur->s != ds) {
        uint32_t n = s->nold[c][si] < SET_OLD ? s->nold[c][si] + 1u : SET_OLD;
        memmove(&s->old[c][si][1], &s->old[c][si][0], (n - 1) * sizeof s->old[c][si][0]);
        s->old[c][si][0].s = cur->s; memcpy(s->old[c][si][0].dyn, cur->dyn, sizeof cur->dyn); s->nold[c][si] = (uint8_t)n;
    }
    cur->s = ds;
    for (uint32_t j = 0; ds && j < ds->L->ndyn; j++, (*k)++) if (j < 16) cur->dyn[j] = *k < ndyn ? dyn[*k] : 0;
}
#include "vk_widen.inc"
#define DONE_RING 1024
static uint64_t g_done_ns[DONE_RING];   // completion time of submit v at [v % DONE_RING] (timestamp query results)
// 源方含着色器写的屏障落成 Metal 围栏（审计 #1534 P1-66）：Metal 的自动冒险跟踪不把贴图原子算作写，计算编码器里做了贴图原子、同一命令缓冲里随后的拷贝 / 渲染编码器
//   会和它重叠、读到原子之前的值（M5 Max、macOS 26.4.1 独立 Metal 程序：渲染清 → 计算原子 → 拷贝读 60 次里 55–57 次读回清的值；普通 write 0/60；
//   原子之后另开计算编码器读 0/60；编码器内 memoryBarrier 不管用、围栏 0/60）。所以照 Vulkan 语义：跑过游戏着色器的计算 / 渲染编码器收尾（或遇屏障）时更新本次提交的
//   当前围栏，屏障把它交成「要等的」并换一个新的当前围栏（一个编码器不同时等和更新同一个围栏），屏障之后新开的编码器都先等它
static void fence_sig(rs_t *s) {
    subq_t *q = s->sq; if (!s->sw || !q) return;
    if (!q->fc) q->fc = [g_dev newFence];
    if (s->ce) [s->ce updateFence:q->fc]; else if (s->re) [s->re updateFence:q->fc afterStages:MTLRenderStageVertex | MTLRenderStageFragment]; else return;
    s->sw = 0; q->fsig = 1;
}
static void end_blit(rs_t *s);
static void fence_barrier(rs_t *s) {
    fence_sig(s); subq_t *q = s->sq; if (!q || !q->fsig) return;   // 上个屏障以来没有着色器写：要等的还是上一个（之前的写已由它排在前面）
    q->fw = q->fc; q->fc = nil; q->fsig = 0;
    end_blit(s);   // 屏障前开着的拷贝编码器没等过：屏障之后的拷贝另开一个
}
static id<MTLComputeCommandEncoder> new_ce(rs_t *s) { id<MTLComputeCommandEncoder> e = [s->cb computeCommandEncoder]; if (e && s->sq && s->sq->fw) [e waitForFence:s->sq->fw]; return e; }
static id<MTLBlitCommandEncoder> new_be(rs_t *s) { id<MTLBlitCommandEncoder> e = [s->cb blitCommandEncoder]; if (e && s->sq && s->sq->fw) [e waitForFence:s->sq->fw]; return e; }
static id<MTLRenderCommandEncoder> new_re(rs_t *s, MTLRenderPassDescriptor *d) {
    id<MTLRenderCommandEncoder> e = [s->cb renderCommandEncoderWithDescriptor:d];
    if (e && s->sq && s->sq->fw) [e waitForFence:s->sq->fw beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
    return e;
}
static void end_blit(rs_t *s) { if (s->be) { [s->be endEncoding]; s->be = nil; } }
static void end_ce(rs_t *s) { if (s->ce) { fence_sig(s); [s->ce endEncoding]; s->ce = nil; } }
static void part_resolve(rs_t *s);   // vk_core.inc
static MTLStoreAction keep(MTLStoreAction a) { return a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionStore; }
static void end_rp(rs_t *s, int final) {   // final: the pass's own store actions; otherwise everything is stored, to be loaded again when the pass resumes
    if (!s->re) { if (final && s->npres) part_resolve(s); return; }   // 切遍后没再画就收尾：切遍时多重采样内容已整张存下，照样按区域解析
    MTLRenderPassDescriptor *d = s->rpd;
    for (int i = 0; i < 8; i++) if (d.colorAttachments[i].texture) [s->re setColorStoreAction:final ? s->st_col[i] : keep(s->st_col[i]) atIndex:i];
    if (d.depthAttachment.texture) [s->re setDepthStoreAction:final ? s->st_d : MTLStoreActionStore];
    if (d.stencilAttachment.texture) [s->re setStencilStoreAction:final ? s->st_s : MTLStoreActionStore];
    fence_sig(s); [s->re endEncoding]; s->re = nil;
    subq_t *q = s->sq;
    if (q && q->nvis > s->vis_first) {
        id<MTLBlitCommandEncoder> be = [s->cb blitCommandEncoder];
        if (!be) die("[vk] cannot preserve occlusion query segments");
        NSUInteger off = (NSUInteger)s->vis_first * 8, len = (NSUInteger)(q->nvis - s->vis_first) * 8;
        [be copyFromBuffer:q->vis sourceOffset:off toBuffer:q->results destinationOffset:off size:len];
        [be endEncoding];
    }
    if (final && s->npres) part_resolve(s);
}
// A copy inside a render pass, which NVIDIA's driver runs: Super Mario Galaxy copies from its EFB in the middle of a pass (vkCmdCopyImage). The encoder ends here and
// the pass resumes at its next draw (resume_rp); without that, the rest of the pass's draws were dropped
static id<MTLBlitCommandEncoder> blit(rs_t *s, uint32_t op) {
    if (s->re) { static int n; if (n++ < 3) OLOG("copy inside a render pass (command %u): the pass is split and the next draw continues it", op); end_rp(s, 0); s->cut = 1; }
    end_ce(s);
    if (!s->be) s->be = new_be(s);
    return s->be;
}
static void occlusion_segment(rs_t *s, int add) {
    subq_t *q = s->sq;
    if (!q->vis || q->nvis >= q->cap) die("[vk] occlusion segment capacity exhausted");
    q->occ[q->nvis] = (occ_t){s->occ_q, s->occ_idx, q->nvis, add};
    [s->re setVisibilityResultMode:MTLVisibilityResultModeCounting offset:q->nvis * 8]; q->nvis++;
}
static void resume_rp(rs_t *s) {
    end_blit(s); end_ce(s);
    MTLRenderPassDescriptor *d = s->rpd;
    for (int i = 0; i < 8; i++) if (d.colorAttachments[i].texture) d.colorAttachments[i].loadAction = MTLLoadActionLoad;
    if (d.depthAttachment.texture) d.depthAttachment.loadAction = MTLLoadActionLoad;
    if (d.stencilAttachment.texture) d.stencilAttachment.loadAction = MTLLoadActionLoad;
    s->vis_first = s->sq->nvis;
    s->re = new_re(s, d); s->cut = 0;
    if (s->re) g_render_encoders++;
    s->applied = NULL; s->vp_dirty = s->sc_dirty = 1;
    if (s->occ_q) occlusion_segment(s, 1);
}
static MTLLoadAction load_a(VkAttachmentLoadOp o) { return o == VK_ATTACHMENT_LOAD_OP_CLEAR ? MTLLoadActionClear : o == VK_ATTACHMENT_LOAD_OP_LOAD ? MTLLoadActionLoad : MTLLoadActionDontCare; }
static MTLStoreAction store_a(VkAttachmentStoreOp o) { return o == VK_ATTACHMENT_STORE_OP_DONT_CARE ? MTLStoreActionDontCare : MTLStoreActionStore; }
// 渲染附件的实际宽：帧缓冲宽按这张视图的放宽比换算（没放宽 = 帧缓冲宽），不超过贴图宽
static uint32_t rt_width(VkFramebuffer fb, VkImageView v) {
    uint32_t tw = (uint32_t)v->tex.width, w = v->gw && tw != v->gw ? (uint32_t)((uint64_t)fb->w * tw / v->gw) : fb->w;
    return umin(w, tw);
}
// 同上，高：帧缓冲高按这张视图的加高比换算（窄屏加高，没加高 = 帧缓冲高），不超过贴图高
static uint32_t rt_height(VkFramebuffer fb, VkImageView v) {
    uint32_t th = (uint32_t)v->tex.height, h = v->gh && th != v->gh ? (uint32_t)((uint64_t)fb->h * th / v->gh) : fb->h;
    return umin(h, th);
}
static void prepare_indirect(rs_t *s, VkCommandBuffer cb, size_t start);
static void do_clratt(rs_t *s, const c_clratt *x, int game);   // vk_core.inc
// Opens subpass s->sub of the render pass being run: an attachment loads by its own load op where the pass first uses it and is loaded after that; it stores by its
// own store op where the pass last uses it and is stored before that (the next subpass, a separate Metal pass, reads it back)
static void open_sub(rs_t *s) {
    const c_brp *c = s->brp; VkRenderPass rp = c->rp; VkFramebuffer fb = c->fb; const rsub *sp = &rp->sub[s->sub]; int k = (int)s->sub;
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor]; s->swap_img = NULL;
    // P1-69：renderArea 没盖满帧缓冲（Vulkan 1.1 §7.4：加载 / 存储 / 解析只作用于区域内的像素，区域外保持原样）。Metal 的加载 / 存储动作作用于整张附件，
    //   所以这时首用的附件一律「加载」进来、末用的一律「存储」出去，加载 = 清除的改成开遍后按区域清（vkCmdClearAttachments 同一条路：游戏坐标、宽屏换算、夹进附件、夹空跳过）。
    //   区域盖满（通常情况）时原样，不多一笔
    const VkRect2D *ar = &c->area;
    int part = ar->offset.x > 0 || ar->offset.y > 0 || (int64_t)ar->offset.x + ar->extent.width < fb->w || (int64_t)ar->offset.y + ar->extent.height < fb->h;
    s->ra_part = part; s->npres = 0;
    _Alignas(c_clratt) uint8_t clrb[sizeof(c_clratt) + sizeof(VkClearRect)]; c_clratt *clr = (c_clratt *)clrb; clr->na = 0; clr->nr = 1;
    clr->r[0] = (VkClearRect){*ar, 0, 1};
    uint32_t w = UINT32_MAX, h = UINT32_MAX;   // 宽 / 高按附件实际宽高取最小（附件可能被宽屏放宽 / 窄屏加高，不能先拿游戏的帧缓冲宽高封顶；rt_width / rt_height 已按帧缓冲换算）
    for (uint32_t i = 0; i < sp->ncol; i++) {
        int a = sp->col[i]; if (a < 0 || (uint32_t)a >= fb->n) continue;
        const ratt *at = &rp->att[a]; MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[i];
        int first = rp->first[a] == k, last = rp->last[a] == k;
        ca.texture = fb->v[a]->tex; w = umin(w, rt_width(fb, fb->v[a])); h = umin(h, rt_height(fb, fb->v[a]));
        if (fb->v[a]->img && fb->v[a]->img->swap) s->swap_img = fb->v[a]->img;
        ca.loadAction = first && !part ? load_a(at->load) : MTLLoadActionLoad; s->st_col[i] = last && !part ? store_a(at->store) : MTLStoreActionStore; ca.storeAction = MTLStoreActionUnknown;
        if (first && at->load == VK_ATTACHMENT_LOAD_OP_CLEAR && (uint32_t)a < c->nclear) {
            const float *f = c->clear[a].color.float32; ca.clearColor = MTLClearColorMake(f[0], f[1], f[2], f[3]);
            if (part && clr->na < 8) clr->a[clr->na++] = (VkClearAttachment){VK_IMAGE_ASPECT_COLOR_BIT, i, c->clear[a]};
        }
        int r = sp->res[i];
        if (r >= 0 && (uint32_t)r < fb->n) {
            if (part && fb->v[r]->tex.pixelFormat == fb->v[a]->tex.pixelFormat) { s->pres[s->npres][0] = (int8_t)a; s->pres[s->npres][1] = (int8_t)r; s->npres++; continue; }   // P1-69：多重采样整张存下（part 时 st_col 已是存储），收尾按区域解析
            ca.resolveTexture = fb->v[r]->tex; s->st_col[i] = s->st_col[i] == MTLStoreActionDontCare ? MTLStoreActionMultisampleResolve : MTLStoreActionStoreAndMultisampleResolve;
            if (part) RED1("renderArea (%d,%d) %ux%u 小于帧缓冲 %ux%u 且多重采样附件与解析附件像素格式不同：解析仍作用于整张附件（区域外也被解析覆盖）", ar->offset.x, ar->offset.y, ar->extent.width, ar->extent.height, fb->w, fb->h);
        }
    }
    if (sp->depth >= 0 && (uint32_t)sp->depth < fb->n) {
        int a = sp->depth; const ratt *at = &rp->att[a]; const fmt_t *f = fmt_of(at->fmt); id<MTLTexture> t = fb->v[a]->tex;
        int first = rp->first[a] == k, last = rp->last[a] == k;
        w = umin(w, rt_width(fb, fb->v[a])); h = umin(h, rt_height(fb, fb->v[a]));
        if (fmt_has_depth(f)) {
            d.depthAttachment.texture = t; d.depthAttachment.loadAction = first && !part ? load_a(at->load) : MTLLoadActionLoad; s->st_d = last && !part ? store_a(at->store) : MTLStoreActionStore;
            d.depthAttachment.storeAction = MTLStoreActionUnknown;
            if ((uint32_t)a < c->nclear) d.depthAttachment.clearDepth = c->clear[a].depthStencil.depth;
            if (part && first && at->load == VK_ATTACHMENT_LOAD_OP_CLEAR && (uint32_t)a < c->nclear) clr->a[clr->na++] = (VkClearAttachment){VK_IMAGE_ASPECT_DEPTH_BIT, 0, c->clear[a]};
        }
        if (fmt_has_stencil(f)) {
            d.stencilAttachment.texture = t; d.stencilAttachment.loadAction = first && !part ? load_a(at->sload) : MTLLoadActionLoad; s->st_s = last && !part ? store_a(at->sstore) : MTLStoreActionStore;
            d.stencilAttachment.storeAction = MTLStoreActionUnknown;
            if ((uint32_t)a < c->nclear) d.stencilAttachment.clearStencil = c->clear[a].depthStencil.stencil;
            if (part && first && at->sload == VK_ATTACHMENT_LOAD_OP_CLEAR && (uint32_t)a < c->nclear) {   // 同一附件的深度清已在表里就并成一项（表 9 项 = 8 色 + 1 深度模板）
                if (clr->na && clr->a[clr->na - 1].aspectMask == VK_IMAGE_ASPECT_DEPTH_BIT) clr->a[clr->na - 1].aspectMask |= VK_IMAGE_ASPECT_STENCIL_BIT;
                else clr->a[clr->na++] = (VkClearAttachment){VK_IMAGE_ASPECT_STENCIL_BIT, 0, c->clear[a]};
            }
        }
    }
    if (!sp->ncol && sp->depth < 0) { d.renderTargetWidth = fb->w; d.renderTargetHeight = fb->h; d.defaultRasterSampleCount = 1; }
    if (w == UINT32_MAX) w = fb->w;
    if (h == UINT32_MAX) h = fb->h;
    if (g_wd > 0) {   // 宽屏核心：本遍的颜色目标 0 / 深度目标（视图号）
        int c0 = sp->ncol ? sp->col[0] : -1;
        wd_targets(c0 >= 0 && (uint32_t)c0 < fb->n ? fb->v[c0]->wid : 0, sp->depth >= 0 && (uint32_t)sp->depth < fb->n ? fb->v[sp->depth]->wid : 0);
    }
    if (s->sq && s->sq->vis) d.visibilityResultBuffer = s->sq->vis;
    s->vis_first = s->sq->nvis;
    s->rpd = d; s->re = new_re(s, d);
    if (s->re) g_render_encoders++;
    s->applied = NULL; s->rt_w = w; s->rt_h = h;
    // Dynamic viewport and scissor persist across render passes within a command buffer, as in Vulkan; the render target's size stands in only until the game sets them.
    // Resetting them at every pass drew Super Mario Galaxy's handheld UI 1.5x too big: it sets a 1280x720 viewport once and then draws through several passes into its 1920x1080 swapchain
    uint32_t gw = g_wd > 0 ? umin(w, fb->w) : w;   // 默认视口 / 裁剪按游戏坐标（放宽时核心再换算）
    if (!s->have_vp) s->vp = (VkViewport){0, 0, (float)gw, (float)h, 0, 1};
    if (!s->have_sc) s->sc = (VkRect2D){{0, 0}, {gw, h}};
    s->vp_dirty = s->sc_dirty = 1;
    if (clr->na && s->re) do_clratt(s, clr, 1);   // P1-69：按 renderArea 清（在遮挡查询接上之前：这几笔不计入查询）
    if (s->occ_q) occlusion_segment(s, 1);   // a query active across vkCmdNextSubpass continues in the next Metal pass
    g_n_pass++;
}
static void begin_rp(rs_t *s, const c_brp *c, VkCommandBuffer cb, size_t start) {
    end_blit(s); end_ce(s);
    end_rp(s, 1); s->cut = 0;
    prepare_indirect(s, cb, start);
    s->brp = c; s->sub = 0; open_sub(s);
}
// Binds a shader's resources from the descriptor sets bound for its pipeline's bind point. st: 0 vertex, 1 fragment (render encoder), 2 compute (compute encoder)
#define SETB(st, buf, off, slot) do { if ((st) == 2) [s->ce setBuffer:(buf) offset:(off) atIndex:(slot)]; else if (st) [s->re setFragmentBuffer:(buf) offset:(off) atIndex:(slot)]; else [s->re setVertexBuffer:(buf) offset:(off) atIndex:(slot)]; } while (0)
#define SETT(st, tex, slot) do { if ((st) == 2) [s->ce setTexture:(tex) atIndex:(slot)]; else if (st) [s->re setFragmentTexture:(tex) atIndex:(slot)]; else [s->re setVertexTexture:(tex) atIndex:(slot)]; } while (0)
#define SETS(st, smp, slot) do { if ((st) == 2) [s->ce setSamplerState:(smp) atIndex:(slot)]; else if (st) [s->re setFragmentSamplerState:(smp) atIndex:(slot)]; else [s->re setVertexSamplerState:(smp) atIndex:(slot)]; } while (0)
static void bind_res(rs_t *s, const shinfo *si, int st) {
    if (!si) return;
    VkPipeline pipe = st == 2 ? s->cpipe : s->pipe;
    for (int i = 0; i < si->nres; i++) {
        const shres *r = &si->res[i];
        if (r->kind == 'p') continue;   // bind_push
        const uint32_t *dyn; int old; VkDescriptorSet ds = set_of(s, st, r->set, r->binding, &dyn, &old);
        if (!ds) { RED1("shader %s: set %u is not bound", si->key, r->set); continue; }
        if (old) { static int n; if (!n++) LOG("[vk] shader %s: %u.%u is not in the set bound at %u; it reads the last set bound there that has it (a binding stays until a set with it is bound)", si->key, r->set, r->binding, r->set); }
        const VkDescriptorSetLayout L = ds->L; int bi = r->binding < 128 ? L->idx[r->binding] : -1;
        if (bi < 0 || !L->b[bi].count) {
            char have[256] = ""; size_t o = 0;
            for (uint32_t k = 0; k < L->n && o + 8 < sizeof have; k++) o += snprintf(have + o, sizeof have - o, " %u", L->b[k].binding);
            const VkPipelineLayout pl = pipe->layout; const VkDescriptorSetLayout PL = pl && r->set < pl->nset ? pl->set[r->set] : NULL;
            RED1("shader %s: %u.%u is not in the bound set's layout %p (it has:%s); the pipeline layout's set %u is %p%s", si->key, r->set, r->binding, (void *)L, have, r->set, (void *)PL,
                 PL && r->binding < 128 && PL->idx[r->binding] >= 0 ? ", which has this binding: the set was not rebound with the pipeline" : "");
            continue;
        }
        const lbind *lb = &L->b[bi]; uint32_t n = umin(r->count, lb->count);
        for (uint32_t k = 0; k < n; k++) {
            const desc_t *e = &ds->d[lb->base + k]; NSUInteger slot = r->slot + k;
            switch (r->kind) {
                case 'u': case 'b': {
                    if (!e->buf) { RED1("shader %s: buffer %u.%u[%u] is empty", si->key, r->set, r->binding, k); break; }
                    VkDeviceSize off = e->off; if (lb->dyn >= 0 && lb->dyn + k < 16) off += dyn[lb->dyn + k];
                    SETB(st, e->buf, off, slot);
                    break;
                }
                case 't': case 'c': {
                    if (!e->tex) { RED1("shader %s: texture %u.%u[%u] is empty", si->key, r->set, r->binding, k); break; }
                    if (__builtin_expect(g_wd_remap != nil, 0)) wd_fresh((desc_t *)e);   // 描述符里存的是重建前的贴图（宽屏按内容判画布，vk_widen.inc）
                    SETT(st, e->tex, slot);
                    if (r->kind == 'c' && e->smp) SETS(st, e->smp, slot);
                    break;
                }
                case 's':
                    if (!e->smp) { RED1("shader %s: sampler %u.%u[%u] is empty", si->key, r->set, r->binding, k); break; }
                    SETS(st, e->smp, slot);
                    break;
            }
        }
    }
}
// #800：这笔绘制 / 派发绑的采样器里有没有本机 GPU 不认的 LOD 偏置（desc_t.lb）：有就按采样器槽填偏置表 tb（其余 0，零表项的采样与原样逐位相等），返回 1
static int vk_se_table(rs_t *s, const shinfo *si, int st, float tb[31][4]) {
    if (!g_vk_lb_emu || !si) return 0;
    int any = 0; memset(tb, 0, sizeof(float) * 31 * 4);
    for (int i = 0; i < si->nres; i++) {
        const shres *r = &si->res[i]; if (r->kind != 's' && r->kind != 'c') continue;
        const uint32_t *dyn; int old; VkDescriptorSet ds = set_of(s, st, r->set, r->binding, &dyn, &old); if (!ds) continue;
        int bi = r->binding < 128 ? ds->L->idx[r->binding] : -1; if (bi < 0) continue;
        const lbind *lb = &ds->L->b[bi]; uint32_t n = umin(r->count, lb->count);
        for (uint32_t k = 0; k < n && r->slot + k < 31; k++) { float b = ds->d[lb->base + k].lb; if (b != 0) { tb[r->slot + k][0] = b; any = 1; } }
    }
    return any;
}
static void bind_push(rs_t *s, const shinfo *si, int st) {   // the push-constant block (kind p): the whole range of the pipeline layout, at least 16 bytes
    if (!si) return;
    for (int i = 0; i < si->nres; i++) {
        if (si->res[i].kind != 'p') continue;
        const VkPipelineLayout l = (st == 2 ? s->cpipe : s->pipe)->layout; uint32_t n = (umax(l ? l->pc_size : 0, 16) + 15) & ~15u;
        if (st == 2) [s->ce setBytes:s->pc length:n atIndex:si->res[i].slot];
        else if (st) [s->re setFragmentBytes:s->pc length:n atIndex:si->res[i].slot]; else [s->re setVertexBytes:s->pc length:n atIndex:si->res[i].slot];
    }
}
// Dynamic stencil masks (with the stencil test on): Metal keeps them in the depth-stencil state, so a state is made per mask set and kept with the pipeline
static id<MTLDepthStencilState> dss_masks(rs_t *s, VkPipeline p) {
    MTLDepthStencilDescriptor *d = p->dsd;
    uint32_t cf = p->dyn & DYN_SCMP ? s->smask[0][0] : d.frontFaceStencil.readMask, cb = p->dyn & DYN_SCMP ? s->smask[0][1] : d.backFaceStencil.readMask;
    uint32_t wf = p->dyn & DYN_SWR ? s->smask[1][0] : d.frontFaceStencil.writeMask, wb = p->dyn & DYN_SWR ? s->smask[1][1] : d.backFaceStencil.writeMask;
    NSNumber *key = @(((uint64_t)(cf & 0xff) << 24) | ((uint64_t)(cb & 0xff) << 16) | ((wf & 0xff) << 8) | (wb & 0xff));
    if (!p->dss_dyn) p->dss_dyn = [NSMutableDictionary new];
    id<MTLDepthStencilState> st = p->dss_dyn[key]; if (st) return st;
    MTLDepthStencilDescriptor *c = [d copy];
    c.frontFaceStencil.readMask = cf; c.backFaceStencil.readMask = cb; c.frontFaceStencil.writeMask = wf; c.backFaceStencil.writeMask = wb;
    st = [g_dev newDepthStencilStateWithDescriptor:c]; if (st) p->dss_dyn[key] = st;
    return st ? st : p->dss;
}
static void wd_page_clear(rs_t *s);   // vk_core.inc
static int pre_draw(rs_t *s) {
    if (!s->re && s->cut) resume_rp(s);
    VkPipeline p = s->pipe; id<MTLRenderCommandEncoder> re = s->re;
    if (!re) { RED1("draw outside a render pass"); g_bad_err++; return 0; }
    if (p && !p->pso) pipe_finish(p);   // 等现编的管线：着色器编好了就在这里补建
    if (!p || !p->pso) { if (p && p->feat) g_bad_feat++; else g_bad_err++; return 0; }
    if (p->gs) {   // 去掉几何阶段画的（宽点 / 宽线画成 1 像素）：第 1、2、4、8… 笔各记一行
        static _Atomic uint64_t n_gs; uint64_t k = ++n_gs;
        if (!(k & (k - 1))) LOG("[vk] 【黄】 几何阶段管线的绘制第 %llu 笔（第 %llu 帧，图元 %d）：Metal 没有几何着色器，按原图元画、没扩展", (unsigned long long)k, (unsigned long long)g_frames, (int)p->prim);
    }
    int wd = wd_draw(s, p, s->rpd.colorAttachments[0].texture != nil);   // 宽屏核心 ①–③（关时 0）；画法 g_wd_mode 换算视口 / 裁剪，绑完资源后 wd_emit 出数
    if (g_wd_side_on || g_wd_row_on) wd_page_clear(s);   // 宽屏：本笔起原比例页，先清两侧条带（窄屏另清上下两条）（清附件置 applied = NULL，下面整套状态重设）
    if (g_wd > 0) s->vp_dirty = s->sc_dirty = 1;
    // #800：绑了本机 GPU 不认 LOD 偏置的采样器 → 这条管线的偏置模拟版（vk_se_obj，第一次现建），绑完资源后给它偏置表
    float se_tb[31][4]; id<MTLRenderPipelineState> se_ps = vk_se_table(s, p->fs, 1, se_tb) ? vk_se_obj(p, 0) : nil;
    int fresh = s->applied != p || s->applied_se != (se_ps != nil);
    if (fresh) {
        [re setRenderPipelineState:se_ps ? se_ps : p->pso]; s->applied_se = se_ps != nil; [re setDepthStencilState:p->dss ? p->dss : g_dss_off];
        [re setCullMode:p->cull]; [re setFrontFacingWinding:p->wind]; [re setTriangleFillMode:p->fill]; [re setDepthClipMode:p->clip];
        [re setDepthBias:p->bias ? p->bias_c : 0 slopeScale:p->bias ? p->bias_s : 0 clamp:p->bias ? p->bias_cl : 0];
        [re setBlendColorRed:p->blend[0] green:p->blend[1] blue:p->blend[2] alpha:p->blend[3]];
        [re setStencilFrontReferenceValue:p->sref_f backReferenceValue:p->sref_b];
        if (p->has_vp && (!s->applied || !s->applied->has_vp || memcmp(&s->applied->vp, &p->vp, sizeof p->vp))) s->vp_dirty = 1;
        if (p->has_sc) s->sc_dirty = 1;
        s->applied = p;
    }
    if (p->dyn && (fresh || s->dyn_dirty)) {
        if ((p->dyn & ~s->dyn_set) && p->bias) { static int once; if (!once) { once = 1; VLOG("a pipeline draws with dynamic state %#x the command buffer never set: taken as 0", p->dyn & ~s->dyn_set); } }
        if (p->dyn & DYN_BIAS) [re setDepthBias:p->bias ? s->bias[0] : 0 slopeScale:p->bias ? s->bias[2] : 0 clamp:p->bias ? s->bias[1] : 0];
        if (p->dyn & DYN_BLEND) [re setBlendColorRed:s->blend[0] green:s->blend[1] blue:s->blend[2] alpha:s->blend[3]];
        if (p->dyn & DYN_SREF) [re setStencilFrontReferenceValue:s->sref[0] backReferenceValue:s->sref[1]];
        if ((p->dyn & (DYN_SCMP | DYN_SWR)) && p->dsd) [re setDepthStencilState:dss_masks(s, p)];
    }
    s->dyn_dirty = 0;
    if (s->swap_img) {   // 本帧画进交换链的范围 = 各笔视口右下角的最大值（游戏坐标；负高的视口取上下两端的大者）：上屏按它裁（同 GL 层 0 号帧缓冲口径）
        MTLViewport u = p->has_vp ? p->vp : vp_of(&s->vp); VkImage im = s->swap_img;
        double x1 = fmax(u.originX, u.originX + u.width), y1 = fmax(u.originY, u.originY + u.height);
        uint32_t ex = x1 <= 0 ? 0 : x1 >= im->w ? im->w : (uint32_t)ceil(x1), ey = y1 <= 0 ? 0 : y1 >= im->h ? im->h : (uint32_t)ceil(y1);
        if (ex > im->ext_w) im->ext_w = ex; if (ey > im->ext_h) im->ext_h = ey;
    }
    if (s->vp_dirty) {
        MTLViewport v = p->has_vp ? p->vp : vp_of(&s->vp);
        if (g_wd > 0) { float x = (float)v.originX, w = (float)v.width, y = (float)v.originY, h = (float)v.height; s2a_widen_map_viewport(g_wd_mode, &x, &w); s2a_widen_map_viewport_y(g_wd_mode, &y, &h); v.originX = x; v.width = w; v.originY = y; v.height = h; }   // 窄屏：上下多画（s2a_widen_ky > 1）
        [re setViewport:v]; s->vp_dirty = 0;
    }
    if (s->sc_dirty) {   // Metal requires the scissor to lie inside the render target
        VkRect2D r = p->has_sc ? p->sc : s->sc;
        if (s->ra_part && s->brp) {   // P1-69：剪裁与 renderArea 取交（§7.4：区域外的附件内容保持不变；游戏坐标，下面再按宽屏换算）
            const VkRect2D *a = &((const c_brp *)s->brp)->area;
            int64_t x0 = r.offset.x > a->offset.x ? r.offset.x : a->offset.x, y0 = r.offset.y > a->offset.y ? r.offset.y : a->offset.y;
            int64_t x1 = (int64_t)r.offset.x + r.extent.width, y1 = (int64_t)r.offset.y + r.extent.height, ax1 = (int64_t)a->offset.x + a->extent.width, ay1 = (int64_t)a->offset.y + a->extent.height;
            if (x1 > ax1) x1 = ax1;
            if (y1 > ay1) y1 = ay1;
            r = (VkRect2D){{(int32_t)x0, (int32_t)y0}, {(uint32_t)(x1 > x0 ? x1 - x0 : 0), (uint32_t)(y1 > y0 ? y1 - y0 : 0)}};
        }
        if (g_wd > 0) { int32_t x = r.offset.x, w = (int32_t)r.extent.width, y = r.offset.y, h = (int32_t)r.extent.height; s2a_widen_map_scissor(g_wd_mode, &x, &w); s2a_widen_map_scissor_y(g_wd_mode, &y, &h);
                        r.offset.x = x; r.extent.width = (uint32_t)(w < 0 ? 0 : w); r.offset.y = y; r.extent.height = (uint32_t)(h < 0 ? 0 : h); }
        // 同通用层 gal_state.m 的夹法：原点夹进 [0, 目标]，宽高 = 夹后右下减原点、不足取 0（P1-22：旧写法在整块落在左 / 上外侧时把原点收成负数再转无符号）
        int64_t x0 = r.offset.x < 0 ? 0 : r.offset.x, y0 = r.offset.y < 0 ? 0 : r.offset.y;
        int64_t x1 = (int64_t)r.offset.x + r.extent.width, y1 = (int64_t)r.offset.y + r.extent.height;
        if (x1 > s->rt_w) x1 = s->rt_w;
        if (y1 > s->rt_h) y1 = s->rt_h;
        if (x0 > s->rt_w) x0 = s->rt_w;
        if (y0 > s->rt_h) y0 = s->rt_h;
        [re setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 > x0 ? x1 - x0 : 0), (NSUInteger)(y1 > y0 ? y1 - y0 : 0)}]; s->sc_dirty = 0;
    }
    bind_res(s, p->vs, 0); bind_res(s, p->fs, 1); bind_push(s, p->vs, 0); bind_push(s, p->fs, 1);
    if (se_ps) [re setFragmentBytes:se_tb length:sizeof se_tb atIndex:(NSUInteger)p->se_slot];
    if (wd) wd_emit(s);
    for (uint32_t i = 0; i < 14; i++)
        if (p->vb_mask >> i & 1) {
            VkBuffer b = s->vb[i]; if (!b || !b->mem) { RED1("vertex buffer %u not bound", i); g_bad_err++; return 0; }
            [re setVertexBuffer:mem_buf(b->mem) offset:b->off + s->vbo[i] atIndex:30 - i];
        }
    s->sw = 1; return 1;
}
// Vulkan and Metal indirect records have the same 4/5 uint32 words (baseVertex remains signed bits).
// The count and records may have been written earlier in this submission, so only the GPU reads them.
static const char indirect_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void vk_indirect_mask(device const uint *src [[buffer(0)]], device const uint *count [[buffer(1)]],\n"
" device uint *dst [[buffer(2)]], constant uint2 &p [[buffer(3)]], uint i [[thread_position_in_grid]]) {\n"
" bool live = i < *count; for (uint w = 0; w < p.y; w++) dst[ulong(i)*p.y+w] = live ? src[ulong(i)*p.x+w] : 0u; }\n";
static void indirect_error(const char *message) {
    LOG("[vk] 【红】 indirect draw: %s", message); g_bad_err++; s2a_direct_gpu_error(message);
}
static int indirect_range(VkBuffer b, VkDeviceSize offset, VkDeviceSize length) {
    return b && b->mem && offset <= b->size && length <= b->size - offset &&
           b->off <= b->mem->size && b->size <= b->mem->size - b->off;
}
static NSUInteger indirect_size(const c_indirect *x) {
    // Each execution gets its own aligned slice, including repeated execution of one recorded command buffer.
    return ((NSUInteger)x->max * (x->indexed ? 20 : 16) + 15) & ~(NSUInteger)15;
}
static int indirect_valid(const c_indirect *x) {
    uint32_t words = x->indexed ? 5 : 4;
    uint32_t stride = !x->count && x->max == 1 ? words * 4 : x->stride;
    VkDeviceSize span = (VkDeviceSize)(x->max - 1) * stride + words * 4;
    return stride >= words * 4 && !(stride % 4) && !(x->offset % 4) && indirect_range(x->args, x->offset, span) &&
        (!x->count || (!(x->count_offset % 4) && indirect_range(x->count, x->count_offset, 4)));
}
enum { ID_DRAWN = 1, ID_WRITE = 2, ID_BLOCKED = 4 };
static uint32_t indirect_dependency(uint32_t deps, const chdr *h) {
    const void *c = h + 1;
    switch (h->op) {
        case C_DRAW: { const c_draw *x = c; if (x->count && x->inst) deps |= ID_DRAWN; break; }
        case C_DRAWI: { const c_drawi *x = c; if (x->count && x->inst) deps |= ID_DRAWN; break; }
        case C_INDIRECT: if (((const c_indirect *)c)->max) deps |= ID_DRAWN; break;
        case C_BARRIER: {
            uint32_t access = ((const c_barrier *)c)->access;
            if ((deps & ID_DRAWN) && (access & B_SHADER_WRITE)) deps |= ID_WRITE;
            if ((deps & ID_WRITE) && (access & B_INDIRECT_READ)) deps |= ID_BLOCKED;
            break;
        }
        // Nonstandard in-pass copies can also write aliased, buffer-backed images. Do not pre-read any
        // later count draw in that pass; retain the existing copy path and report the unsupported combination.
        case C_COPYB: case C_COPYB2I: case C_COPYI: case C_COPYI2B: deps |= ID_BLOCKED; break;
    }
    return deps;
}
// Walks the pass's commands from start to its end (into the secondary command buffers it executes, in the order they run); returns 1 at the end of the pass
static int prep_walk(rs_t *s, VkCommandBuffer cb, size_t start, id<MTLComputeCommandEncoder> __strong *ce, uint32_t *deps) {
    static id<MTLComputePipelineState> ps;   // replay is serialized by g_qmu
    for (size_t o = start; o < cb->n;) {
        const chdr *h = (const chdr *)(cb->buf + o); o += h->size;
        if (h->op == C_ERP) return 1;
        if (h->op == C_EXEC) {
            const c_exec *x = (const c_exec *)(h + 1);
            for (uint32_t i = 0; i < x->n; i++) if (prep_walk(s, x->cb[i], 0, ce, deps)) return 1;
            continue;
        }
        if (h->op == C_INDIRECT) {
            const c_indirect *x = (const c_indirect *)(h + 1);
            if (x->count && x->max) {
                NSUInteger offset = s->sq->indirect_used; s->sq->indirect_used += indirect_size(x);
                if (!(*deps & ID_BLOCKED) && !s->indirect_failed && indirect_valid(x)) {
                    if (!ps) {
                        NSError *e = nil;
                        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(indirect_msl) options:nil error:&e];
                        id<MTLFunction> fn = [lib newFunctionWithName:@"vk_indirect_mask"];
                        ps = fn ? [g_dev newComputePipelineStateWithFunction:fn error:&e] : nil;
                        if (!ps) { indirect_error(e.localizedDescription.UTF8String ?: "cannot create indirect masking pipeline"); s->indirect_failed = 1; }
                    }
                    id<MTLBuffer> args = mem_buf(x->args->mem), count = mem_buf(x->count->mem);
                    if (!args || !count) { indirect_error("argument/count buffer allocation failed"); s->indirect_failed = 1; }
                    if (!s->indirect_failed && !*ce) {
                        *ce = new_ce(s);
                        if (!*ce) { indirect_error("cannot create indirect masking encoder"); s->indirect_failed = 1; }
                        else [*ce setComputePipelineState:ps];
                    }
                    if (!s->indirect_failed) {
                        [*ce setBuffer:args offset:x->args->off + x->offset atIndex:0];
                        [*ce setBuffer:count offset:x->count->off + x->count_offset atIndex:1];
                        [*ce setBuffer:s->sq->indirect offset:offset atIndex:2];
                        uint32_t params[2] = {x->stride / 4, x->indexed ? 5 : 4};
                        [*ce setBytes:params length:sizeof params atIndex:3];
                        [*ce dispatchThreads:MTLSizeMake(x->max, 1, 1) threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)64, ps.maxTotalThreadsPerThreadgroup), 1, 1)];
                    }
                }
            }
        }
        *deps = indirect_dependency(*deps, h);
    }
    return 0;
}
static void prepare_indirect(rs_t *s, VkCommandBuffer cb, size_t start) {
    id<MTLComputeCommandEncoder> ce = nil; uint32_t deps = 0;
    s->indirect_next = s->sq->indirect_used; s->indirect_deps = 0; s->indirect_failed = 0;
    prep_walk(s, cb, start, &ce, &deps);
    if (ce) [ce endEncoding];
}
static void draw_indirect(rs_t *s, const c_indirect *x) {
    if (!x->max) return;
    if (!s->re && !s->cut) { indirect_error("draw outside a render pass"); return; }
    NSUInteger packed_offset = s->indirect_next;
    if (x->count) s->indirect_next += indirect_size(x);
    if (!indirect_valid(x)) { indirect_error("argument/count buffer range or stride is invalid"); return; }
    if (x->indexed && (!s->ib || !s->ib->mem)) { indirect_error("index buffer not bound"); return; }
    uint32_t words = x->indexed ? 5 : 4;
    // Core fixed-count calls ignore stride for zero/one draw; count variants always require a valid stride.
    uint32_t stride = !x->count && x->max == 1 ? words * 4 : x->stride;
    id<MTLBuffer> args = mem_buf(x->args->mem);
    NSUInteger offset = x->args->off + x->offset;
    if (!args) { indirect_error("argument buffer allocation failed"); return; }
    if (x->count) {
        if (s->indirect_deps & ID_BLOCKED) { indirect_error("count draw after an in-pass shader-write dependency or copy is unsupported"); return; }
        if (s->indirect_failed) return;
        args = s->sq->indirect; offset = packed_offset; stride = words * 4;
    }
    if (!pre_draw(s)) return;
    id<MTLBuffer> indices = x->indexed ? mem_buf(s->ib->mem) : nil;
    if (x->indexed && !indices) { indirect_error("index buffer allocation failed"); return; }
    for (uint32_t i = 0; i < x->max; i++) {
        NSUInteger at = offset + (NSUInteger)i * stride;
        if (x->indexed) [s->re drawIndexedPrimitives:s->pipe->prim indexType:s->it indexBuffer:indices indexBufferOffset:s->ib->off + s->ibo indirectBuffer:args indirectBufferOffset:at];
        else [s->re drawPrimitives:s->pipe->prim indirectBuffer:args indirectBufferOffset:at];
    }
    g_n_draw += x->max;   // encoded draws; the GPU masks entries past min(count, max) to zero
}
#include "vk_core.inc"
static void replay_cmds(rs_t *s, VkCommandBuffer cb) {
    for (size_t o = 0; o < cb->n;) {
        const chdr *h = (const chdr *)(cb->buf + o); const void *c = h + 1; o += h->size;
        switch (h->op) {
            case C_BRP: begin_rp(s, c, cb, o); break;
            case C_DEBUG_LABEL: debug_replay_label(cb, c); break;
            case C_ERP: end_rp(s, 1); s->cut = 0; s->rpd = nil; s->brp = NULL; break;
            case C_PIPE: s->pipe = ((const c_pipe *)c)->p; break;
            case C_CPIPE: s->cpipe = ((const c_pipe *)c)->p; break;
            case C_CSETS: {
                const c_sets *x = c; uint32_t k = 0;
                for (uint32_t i = 0; i < x->n && x->first + i < 8; i++) set_bind(s, 1, x->first + i, x->s[i], x->dyn, x->ndyn, &k);
                break;
            }
            case C_EVENT: do_event(s, c); break;
            case C_WAITEV: do_waitev(s, c); break;
            case C_SMASK: { const c_smask *x = c; if (x->face & VK_STENCIL_FACE_FRONT_BIT) s->smask[x->wr][0] = x->mask; if (x->face & VK_STENCIL_FACE_BACK_BIT) s->smask[x->wr][1] = x->mask;
                            s->dyn_set |= x->wr ? DYN_SWR : DYN_SCMP; s->dyn_dirty = 1; break; }
            case C_FILL: do_fill(s, c); break;
            case C_UPDATE: do_update(s, c); break;
            case C_CLRIMG: do_clrimg(s, c); break;
            case C_CLRATT: do_clratt(s, c, 1); break;
            case C_BLIT: do_blit(s, c); break;
            case C_RESOLVE: do_resolve(s, c); break;
            case C_QCOPY: do_qcopy(s, c); break;
            case C_DISPATCH: do_dispatch(s, c); break;
            case C_DISPATCHI: do_dispatchi(s, c); break;
            case C_EXEC: { const c_exec *x = c; for (uint32_t i = 0; i < x->n; i++) replay_cmds(s, x->cb[i]); break; }
            case C_NEXTSP: next_subpass(s); break;
            case C_SETS: {
                const c_sets *x = c; uint32_t k = 0;
                for (uint32_t i = 0; i < x->n && x->first + i < 8; i++) set_bind(s, 0, x->first + i, x->s[i], x->dyn, x->ndyn, &k);
                break;
            }
            case C_VB: { const c_vb *x = c; for (uint32_t i = 0; i < x->n; i++) { s->vb[x->first + i] = x->b[i]; s->vbo[x->first + i] = x->o[i]; } break; }
            case C_IB: { const c_ib *x = c; s->ib = x->b; s->ibo = x->o; s->it = x->t == VK_INDEX_TYPE_UINT32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16; s->isz = x->t == VK_INDEX_TYPE_UINT32 ? 4 : 2; break; }
            case C_VP: s->vp = ((const c_vp *)c)->v; s->vp_dirty = 1; s->have_vp = 1; break;
            case C_SC: s->sc = ((const c_sc *)c)->r; s->sc_dirty = 1; s->have_sc = 1; break;
            case C_BIAS: memcpy(s->bias, ((const c_f4 *)c)->v, sizeof s->bias); s->dyn_set |= DYN_BIAS; s->dyn_dirty = 1; break;
            case C_BLEND: memcpy(s->blend, ((const c_f4 *)c)->v, sizeof s->blend); s->dyn_set |= DYN_BLEND; s->dyn_dirty = 1; break;
            case C_SREF: { const c_sref *x = c; if (x->face & VK_STENCIL_FACE_FRONT_BIT) s->sref[0] = x->ref; if (x->face & VK_STENCIL_FACE_BACK_BIT) s->sref[1] = x->ref;
                           s->dyn_set |= DYN_SREF; s->dyn_dirty = 1; break; }
            case C_DRAWI: {
                const c_drawi *x = c;
                if (!x->count || !x->inst || !pre_draw(s)) break;
                if (!s->ib || !s->ib->mem) { RED1("index buffer not bound"); g_bad_err++; break; }
                [s->re drawIndexedPrimitives:s->pipe->prim indexCount:x->count indexType:s->it indexBuffer:mem_buf(s->ib->mem)
                           indexBufferOffset:s->ib->off + s->ibo + (VkDeviceSize)x->first * s->isz instanceCount:x->inst baseVertex:x->voff baseInstance:x->first_inst];
                g_n_draw++;
                break;
            }
            case C_COPYB: {
                const c_copyb *x = c; if (!x->src->mem || !x->dst->mem) { RED1("a copied buffer has no bound memory"); break; }
                id<MTLBlitCommandEncoder> be = blit(s, h->op); id<MTLBuffer> sb = mem_buf(x->src->mem), db = mem_buf(x->dst->mem);
                for (uint32_t i = 0; i < x->n; i++) {
                    const VkBufferCopy *r = &x->r[i];   // P1-68：源 / 目标范围越出所绑内存的那一条不编码（同填充 / 更新 mem_range_ok）
                    if (!mem_range_ok(x->src, sb, r->srcOffset, r->size) || !mem_range_ok(x->dst, db, r->dstOffset, r->size)) {
                        RED1("vkCmdCopyBuffer 越界：源偏移 %llu、目标偏移 %llu、大小 %llu（源 %llu / 目标 %llu 字节）：这一条不编码", (unsigned long long)r->srcOffset, (unsigned long long)r->dstOffset,
                             (unsigned long long)r->size, (unsigned long long)x->src->size, (unsigned long long)x->dst->size);
                        continue;
                    }
                    [be copyFromBuffer:sb sourceOffset:x->src->off + r->srcOffset toBuffer:db destinationOffset:x->dst->off + r->dstOffset size:r->size];
                }
                g_n_copy += x->n;
                break;
            }
            case C_COPYB2I: {
                const c_copyb2i *x = c; VkImage im = x->dst; const fmt_t *f = im->f;
                if (g_wd > 0 && im->tex && im->tex.width != im->w) RED1("宽屏：往放宽的图像上传没换算（写进左边游戏宽度）");
                if (!x->src->mem || !im->tex) { RED1("the upload buffer has no bound memory or the image was not created"); break; }
                id<MTLBlitCommandEncoder> be = blit(s, h->op); id<MTLBuffer> sb = mem_buf(x->src->mem);
                for (uint32_t i = 0; i < x->n; i++) {
                    const VkBufferImageCopy *r = &x->r[i];
                    uint32_t rl = r->bufferRowLength ? r->bufferRowLength : r->imageExtent.width, ih = r->bufferImageHeight ? r->bufferImageHeight : r->imageExtent.height;
                    if (im->bc) {   // 显卡不认 BC：缓冲里是压缩块（按原格式的块行排），解成像素放进一块临时缓冲再传；图像本身是解压格式
                        const fmt_t *bf = fmt_of(im->fmt); uint32_t w = r->imageExtent.width, hh = r->imageExtent.height, nl = r->imageSubresource.layerCount;
                        NSUInteger cbpr = (NSUInteger)((rl + bf->bw - 1) / bf->bw) * bf->bytes, cbpi = cbpr * ((ih + bf->bh - 1) / bf->bh), dpr = (NSUInteger)w * f->bytes;
                        VkDeviceSize need = buf_box_bytes(bf, bf->bytes, cbpr, cbpi, w, hh, 1);
                        if (im->type == VK_IMAGE_TYPE_3D || r->imageExtent.depth > 1) { RED1("显卡不认 BC：三维 BC 图像的上传没接（这一条不编码）"); continue; }
                        if (!img_box_ok(im, r->imageSubresource.mipLevel, r->imageSubresource.baseArrayLayer, nl, r->imageOffset, r->imageExtent) ||
                            !mem_range_ok(x->src, sb, r->bufferOffset, (VkDeviceSize)(nl - 1) * cbpi + need)) {
                            RED1("vkCmdCopyBufferToImage 越界（解压 BC）：图像 (%d,%d) %u×%u 级 %u 层 %u+%u，缓冲偏移 %llu：这一条不编码", r->imageOffset.x, r->imageOffset.y, w, hh,
                                 r->imageSubresource.mipLevel, r->imageSubresource.baseArrayLayer, nl, (unsigned long long)r->bufferOffset);
                            continue;
                        }
                        id<MTLBuffer> tmp = [g_dev newBufferWithLength:dpr * hh * nl options:MTLResourceStorageModeShared];
                        if (!tmp) { RED1("显卡不认 BC：解码用的临时缓冲分不出来（%lu 字节）", (unsigned long)(dpr * hh * nl)); continue; }
                        const uint8_t *src = (const uint8_t *)sb.contents + x->src->off + r->bufferOffset; uint8_t *dst = tmp.contents; int bad = 0;
                        for (uint32_t l = 0; l < nl; l++) bad |= nvn_bc_decode(im->bc, src + l * cbpi, cbpr, w, hh, dst + l * dpr * hh, dpr);
                        if (bad) { RED1("显卡不认 BC：格式 %#x 解码失败（这一条不编码）", im->bc); continue; }
                        for (uint32_t l = 0; l < nl; l++)
                            [be copyFromBuffer:tmp sourceOffset:l * dpr * hh sourceBytesPerRow:dpr sourceBytesPerImage:dpr * hh sourceSize:MTLSizeMake(w, hh, 1) toTexture:im->tex
                              destinationSlice:r->imageSubresource.baseArrayLayer + l destinationLevel:r->imageSubresource.mipLevel destinationOrigin:MTLOriginMake(r->imageOffset.x, r->imageOffset.y, 0)];
                        continue;
                    }
                    NSUInteger bpr = (NSUInteger)((rl + f->bw - 1) / f->bw) * f->bytes, bpi = bpr * ((ih + f->bh - 1) / f->bh);
                    int is3d = im->type == VK_IMAGE_TYPE_3D;
                    // P1-68：图像盒子出图（负原点 / 越出这一级 / 级别层越界）或缓冲读出所绑内存的那一条不编码
                    VkDeviceSize need = buf_box_bytes(f, f->bytes, bpr, bpi, r->imageExtent.width, r->imageExtent.height, is3d ? r->imageExtent.depth : 1);
                    if (!img_box_ok(im, r->imageSubresource.mipLevel, r->imageSubresource.baseArrayLayer, r->imageSubresource.layerCount, r->imageOffset, r->imageExtent) ||
                        !mem_range_ok(x->src, sb, r->bufferOffset, (is3d ? 0 : (VkDeviceSize)(r->imageSubresource.layerCount - 1) * bpi) + need)) {
                        RED1("vkCmdCopyBufferToImage 越界：图像 (%d,%d,%d) %u×%u×%u 级 %u 层 %u+%u（图像 %ux%u、%u 级 %u 层），缓冲偏移 %llu：这一条不编码", r->imageOffset.x, r->imageOffset.y, r->imageOffset.z,
                             r->imageExtent.width, r->imageExtent.height, r->imageExtent.depth, r->imageSubresource.mipLevel, r->imageSubresource.baseArrayLayer, r->imageSubresource.layerCount,
                             im->w, im->h, im->mips, im->layers, (unsigned long long)r->bufferOffset);
                        continue;
                    }
                    MTLBlitOption opt = f->kind == K_DS ? (r->imageSubresource.aspectMask & VK_IMAGE_ASPECT_STENCIL_BIT ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionDepthFromDepthStencil) : MTLBlitOptionNone;
                    for (uint32_t l = 0; l < (is3d ? 1 : r->imageSubresource.layerCount); l++)
                        [be copyFromBuffer:sb sourceOffset:x->src->off + r->bufferOffset + l * bpi sourceBytesPerRow:bpr sourceBytesPerImage:is3d || im->layers > 1 ? bpi : 0
                                sourceSize:MTLSizeMake(r->imageExtent.width, r->imageExtent.height, is3d ? r->imageExtent.depth : 1) toTexture:im->tex
                          destinationSlice:is3d ? 0 : r->imageSubresource.baseArrayLayer + l destinationLevel:r->imageSubresource.mipLevel
                         destinationOrigin:MTLOriginMake(r->imageOffset.x, r->imageOffset.y, is3d ? r->imageOffset.z : 0) options:opt];
                }
                g_n_copy += x->n;
                break;
            }
            case C_DRAW: {
                const c_draw *x = c;
                if (!x->count || !x->inst || !pre_draw(s)) break;
                [s->re drawPrimitives:s->pipe->prim vertexStart:x->first vertexCount:x->count instanceCount:x->inst baseInstance:x->first_inst];
                g_n_draw++;
                break;
            }
            case C_INDIRECT: draw_indirect(s, c); break;
            case C_BARRIER: if (((const c_barrier *)c)->access & B_SHADER_WRITE) fence_barrier(s); break;   // 其余跨编码器依赖靠 Metal 的冒险跟踪；间接绘制的依赖见 indirect_dependency
            case C_PUSH: { const c_push *x = c; memcpy(s->pc + x->off, x->data, x->size); s->pc_seq = ++g_pc_seq; break; }
            case C_COPYI: {
                const c_copyi *x = c; VkImage a = x->src, b = x->dst;
                if (!a->tex || !b->tex) { RED1("a copied image was not created"); break; }
                if (a->tex.pixelFormat != b->tex.pixelFormat) { RED1("image copy between different formats (%d → %d) not implemented", a->fmt, b->fmt); break; }
                id<MTLBlitCommandEncoder> be = blit(s, h->op);
                for (uint32_t i = 0; i < x->n; i++) {
                    const VkImageCopy *r = &x->r[i]; int a3 = a->type == VK_IMAGE_TYPE_3D, b3 = b->type == VK_IMAGE_TYPE_3D;
                    uint32_t nl = a3 ? 1 : r->srcSubresource.layerCount;
                    int32_t sx = r->srcOffset.x, dx = r->dstOffset.x; uint32_t sw = r->extent.width, dw = r->extent.width;   // 宽屏：两边各按自己的放宽换算（vk_widen.inc）
                    { static int nlog; if (g_log && nlog < 200 && (a->tex.width != a->w || b->tex.width != b->w || a->pitch || b->pitch)) { nlog++; OLOG("CopyImage %p %ux%u（贴图宽 %lu%s）→ %p %ux%u（贴图宽 %lu%s）区域 x %d 宽 %u → x %d", (void *)a, a->w, a->h, (unsigned long)a->tex.width, a->pitch ? "、线性" : "",
                        (void *)b, b->w, b->h, (unsigned long)b->tex.width, b->pitch ? "、线性" : "", r->srcOffset.x, r->extent.width, r->dstOffset.x); } }   // DM_VK_LOG：宽屏合成链定因（10-30 银河2）
                    wd_map_span(a, r->srcSubresource.mipLevel, &sx, &sw); wd_map_span(b, r->dstSubresource.mipLevel, &dx, &dw);
                    int32_t sy = r->srcOffset.y, dy = r->dstOffset.y; uint32_t sh = r->extent.height, dh = r->extent.height;   // 纵向同理（窄屏加高，wd_map_span_y）
                    wd_map_span_y(a, r->srcSubresource.mipLevel, &sy, &sh); wd_map_span_y(b, r->dstSubresource.mipLevel, &dy, &dh);
                    // 放宽 / 加高的与没放宽 / 没加高的图像之间：两边各按自己的存储换算后尺寸不等 → 缩放拷贝（同 NVN 层 copy_t2t：两边矩形各按自己贴图的比例缩放，
                    //   比例不等时成缩放画）。按游戏坐标拼一条 Blit 交 do_blit（它再各自换算、缩放画），之后重新取拷贝编码器。
                    //   11-02 银河2 Duo 外屏：1024×576 没加高的图像拷进加高到 702 的目标，按较矮的拷，目标下面 126 行一直是旧内容
                    if ((sw != dw || sh != dh) && sw && dw && sh && dh && !a3 && !b3 && a->samples <= 1 && a->f->kind == K_COLOR && b->f->kind == K_COLOR && (b->tex.usage & MTLTextureUsageRenderTarget)) {
                        _Alignas(c_blit) uint8_t bb[sizeof(c_blit) + sizeof(VkImageBlit)]; c_blit *bl = (c_blit *)bb; bl->src = a; bl->dst = b; bl->filter = VK_FILTER_LINEAR; bl->n = 1;
                        bl->r[0] = (VkImageBlit){.srcSubresource = r->srcSubresource, .dstSubresource = r->dstSubresource,
                            .srcOffsets = {{r->srcOffset.x, r->srcOffset.y, 0}, {r->srcOffset.x + (int32_t)r->extent.width, r->srcOffset.y + (int32_t)r->extent.height, 1}},
                            .dstOffsets = {{r->dstOffset.x, r->dstOffset.y, 0}, {r->dstOffset.x + (int32_t)r->extent.width, r->dstOffset.y + (int32_t)r->extent.height, 1}}};
                        do_blit(s, bl); be = blit(s, h->op); continue;
                    }
                    if (sw != dw) RED1("宽屏：放宽 / 没放宽的图像之间拷贝（源宽 %u、目标宽 %u），按较窄的拷", sw, dw);
                    if (sh != dh) RED1("宽屏：加高 / 没加高的图像之间拷贝（源高 %u、目标高 %u），按较矮的拷", sh, dh);
                    uint32_t cw = sw < dw ? sw : dw, ch = sh < dh ? sh : dh;
                    // P1-68：级别 / 层越界的那一条不编码；矩形（存储坐标）夹进两边这一级（clamp_span，同 Blit 等尺寸与局部解析），夹空不编码。界内的原样整块拷
                    uint32_t sm = r->srcSubresource.mipLevel, dm = r->dstSubresource.mipLevel;
                    if (!a->bc != !b->bc) { RED1("显卡不认 BC：解压后的 BC 图像与别的格式之间按块拷贝没接（这一条不编码）"); continue; }
                    if (!img_sub_ok(a, sm, r->srcSubresource.baseArrayLayer, nl) || !img_sub_ok(b, dm, r->dstSubresource.baseArrayLayer, b3 ? 1 : nl)) {
                        RED1("vkCmdCopyImage 级别 / 层越界：源级 %u 层 %u+%u（%u 级 %u 层）→ 目标级 %u 层 %u（%u 级 %u 层）：这一条不编码", sm, r->srcSubresource.baseArrayLayer, nl, a->mips, a->layers,
                             dm, r->dstSubresource.baseArrayLayer, b->mips, b->layers);
                        continue;
                    }
                    int64_t X0 = sx, Y0 = sy, Z0 = a3 ? r->srcOffset.z : 0, X1 = dx, Y1 = dy, Z1 = b3 ? r->dstOffset.z : 0;
                    int64_t cw2 = clamp_span(&X0, &X1, cw, umax(1, (uint32_t)a->tex.width >> sm), umax(1, (uint32_t)b->tex.width >> dm));
                    int64_t ch2 = clamp_span(&Y0, &Y1, ch, umax(1, (uint32_t)a->tex.height >> sm), umax(1, (uint32_t)b->tex.height >> dm));
                    int64_t cd2 = clamp_span(&Z0, &Z1, a3 ? r->extent.depth : 1, a3 ? umax(1, (uint32_t)a->tex.depth >> sm) : 1, b3 ? umax(1, (uint32_t)b->tex.depth >> dm) : 1);
                    if (cw2 != cw || ch2 != ch || cd2 != (a3 ? r->extent.depth : 1))
                        RED1("vkCmdCopyImage 矩形越界：源 (%d,%d) → 目标 (%d,%d) %u×%u，夹成 %lld×%lld%s", sx, sy, dx, dy, cw, ch, (long long)cw2, (long long)ch2, cw2 > 0 && ch2 > 0 && cd2 > 0 ? "" : "（夹空，不编码）");
                    for (uint32_t l = 0; l < nl && cw2 > 0 && ch2 > 0 && cd2 > 0; l++)
                        [be copyFromTexture:a->tex sourceSlice:a3 ? 0 : r->srcSubresource.baseArrayLayer + l sourceLevel:sm
                               sourceOrigin:MTLOriginMake((NSUInteger)X0, (NSUInteger)Y0, (NSUInteger)Z0)
                                 sourceSize:MTLSizeMake((NSUInteger)cw2, (NSUInteger)ch2, (NSUInteger)cd2) toTexture:b->tex
                           destinationSlice:b3 ? 0 : r->dstSubresource.baseArrayLayer + l destinationLevel:dm
                          destinationOrigin:MTLOriginMake((NSUInteger)X1, (NSUInteger)Y1, (NSUInteger)Z1)];
                }
                g_n_copy += x->n;
                break;
            }
            case C_COPYI2B: {   // read-back into a buffer (shared storage: the CPU sees it once the submit's fence has signalled)
                const c_copyi2b *x = c; VkImage im = x->src; const fmt_t *f = im->f;
                if (g_wd > 0 && im->tex && (im->tex.width != im->w || im->tex.height != im->h)) RED1("宽屏：从放宽 / 加高的图像读回缓冲没换算（按游戏宽高读左上）");
                if (!x->dst->mem || !im->tex) { RED1("the readback buffer has no bound memory or the image was not created"); break; }
                id<MTLBlitCommandEncoder> be = blit(s, h->op); id<MTLBuffer> db = mem_buf(x->dst->mem);
                for (uint32_t i = 0; i < x->n; i++) {
                    const VkBufferImageCopy *r = &x->r[i]; int is3d = im->type == VK_IMAGE_TYPE_3D;
                    if (im->bc) { RED1("显卡不认 BC：解压后的 BC 图像读回缓冲没接（游戏要的是压缩块，这里只有解出来的像素；这一条不编码）"); continue; }
                    uint32_t rl = r->bufferRowLength ? r->bufferRowLength : r->imageExtent.width, ih = r->bufferImageHeight ? r->bufferImageHeight : r->imageExtent.height;
                    MTLBlitOption opt = MTLBlitOptionNone; NSUInteger tb = f->bytes;
                    if (f->kind == K_DS) {   // one aspect: Metal writes 4-byte depth or 1-byte stencil, as Vulkan's buffer layout for that aspect
                        int st = r->imageSubresource.aspectMask & VK_IMAGE_ASPECT_STENCIL_BIT;
                        opt = st ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionDepthFromDepthStencil; tb = st ? 1 : 4;
                    }
                    NSUInteger bpr = f->kind == K_BLOCK ? (NSUInteger)((rl + f->bw - 1) / f->bw) * f->bytes : rl * tb, bpi = bpr * ((ih + f->bh - 1) / f->bh);
                    // P1-68：图像盒子出图或缓冲写出所绑内存的那一条不编码
                    VkDeviceSize need = buf_box_bytes(f, f->kind == K_BLOCK ? f->bytes : tb, bpr, bpi, r->imageExtent.width, r->imageExtent.height, is3d ? r->imageExtent.depth : 1);
                    if (!img_box_ok(im, r->imageSubresource.mipLevel, r->imageSubresource.baseArrayLayer, r->imageSubresource.layerCount, r->imageOffset, r->imageExtent) ||
                        !mem_range_ok(x->dst, db, r->bufferOffset, (is3d ? 0 : (VkDeviceSize)(r->imageSubresource.layerCount - 1) * bpi) + need)) {
                        RED1("vkCmdCopyImageToBuffer 越界：图像 (%d,%d,%d) %u×%u×%u 级 %u 层 %u+%u（图像 %ux%u、%u 级 %u 层），缓冲偏移 %llu：这一条不编码", r->imageOffset.x, r->imageOffset.y, r->imageOffset.z,
                             r->imageExtent.width, r->imageExtent.height, r->imageExtent.depth, r->imageSubresource.mipLevel, r->imageSubresource.baseArrayLayer, r->imageSubresource.layerCount,
                             im->w, im->h, im->mips, im->layers, (unsigned long long)r->bufferOffset);
                        continue;
                    }
                    for (uint32_t l = 0; l < (is3d ? 1 : r->imageSubresource.layerCount); l++)
                        [be copyFromTexture:im->tex sourceSlice:is3d ? 0 : r->imageSubresource.baseArrayLayer + l sourceLevel:r->imageSubresource.mipLevel
                               sourceOrigin:MTLOriginMake(r->imageOffset.x, r->imageOffset.y, is3d ? r->imageOffset.z : 0)
                                 sourceSize:MTLSizeMake(r->imageExtent.width, r->imageExtent.height, is3d ? r->imageExtent.depth : 1)
                                   toBuffer:db destinationOffset:x->dst->off + r->bufferOffset + l * bpi destinationBytesPerRow:bpr destinationBytesPerImage:bpi options:opt];
                }
                g_n_copy += x->n;
                break;
            }
            case C_QRESET: { const c_query *x = c; for (uint32_t i = 0; i < x->n && x->first + i < x->q->n; i++) x->q->ticket[x->first + i] = FENCE_NONE; break; }
            case C_QTS: { const c_query *x = c; if (x->first < x->q->n) x->q->ticket[x->first] = s->sq->v; break; }
            case C_QBEGIN: {
                const c_query *x = c; subq_t *q = s->sq;
                if (!s->re && s->cut) resume_rp(s);
                if (x->q->type != VK_QUERY_TYPE_OCCLUSION) { RED1("query type %d not implemented", x->q->type); break; }
                if (!s->re || !q->vis || q->nvis == q->cap || x->first >= x->q->n) { RED1("occlusion query outside a render pass or past the buffer"); break; }
                s->occ_q = x->q; s->occ_idx = x->first; occlusion_segment(s, 0);
                x->q->ticket[x->first] = q->v;
                break;
            }
            case C_QEND: if (s->re) [s->re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0]; s->occ_q = NULL; break;
            default: LOG("[vk] 【红】 unknown command %u in the command buffer", h->op); return;
        }
        if (s->rpd) s->indirect_deps = indirect_dependency(s->indirect_deps, h);
    }
}
static void replay(rs_t *s, VkCommandBuffer cb) {
    replay_cmds(s, cb);
    if (s->re || s->cut) { RED1("render pass not ended when the command buffer ended"); end_rp(s, 1); s->cut = 0; }
    end_blit(s); end_ce(s);
}

// ---------- Queue, fences, semaphores ----------
static int fence_done(VkFence f) { uint64_t v = atomic_load(&f->val); return v != FENCE_NONE && atomic_load(&g_done) >= v; }
static void done_advance(uint64_t v) {
    pthread_mutex_lock(&g_done_mu);
    if (v > atomic_load(&g_done)) atomic_store(&g_done, v);
    pthread_cond_broadcast(&g_done_cv);
    pthread_mutex_unlock(&g_done_mu);
}
// 每帧 GPU 时间（frames.tsv 的 gpu_us，host_adapt.m 取）：提交时记它属于哪一帧（下一次上屏 = 已上屏帧数 + 1），完成回调里累加这次提交的 GPU 时间；
//   帧上屏后（closed）且这一帧的提交全部完成（pend 0）才给读数
#define GT_N 64
static struct { uint64_t f; double ms; int pend, closed; } g_gt[GT_N];
static pthread_mutex_t g_gt_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_frames;   // 已上屏帧数（frame_end 加）
double dm_vk_gpu_ms(uint64_t n) {
    pthread_mutex_lock(&g_gt_mu); double r = g_gt[n % GT_N].f == n && g_gt[n % GT_N].closed && !g_gt[n % GT_N].pend ? g_gt[n % GT_N].ms : -1; pthread_mutex_unlock(&g_gt_mu);
    return r;
}
static void gt_close(uint64_t f) {
    pthread_mutex_lock(&g_gt_mu);
    if (g_gt[f % GT_N].f != f) g_gt[f % GT_N] = (typeof(g_gt[0])){f, 0, 0, 0};
    g_gt[f % GT_N].closed = 1;
    pthread_mutex_unlock(&g_gt_mu);
}
// What a submit needs before it is encoded: visibility slots for its queries (and their splits), the indirect-count area, the staging area. Walks into executed
// secondary command buffers
static void prescan(subq_t *sq, VkCommandBuffer c, uint32_t *splits, NSUInteger *indirect, NSUInteger *stage, uint32_t *qn, uint32_t *qcmds, int *too_big) {
    for (size_t o = 0; o < c->n; o += ((const chdr *)(c->buf + o))->size) {
        const chdr *h = (const chdr *)(c->buf + o); const void *x = h + 1;
        switch (h->op) {
            case C_QBEGIN: sq->cap++; break;
            case C_COPYB: case C_COPYB2I: case C_COPYI: case C_COPYI2B: case C_FILL: case C_UPDATE: case C_CLRIMG: case C_BLIT: case C_RESOLVE: case C_QCOPY: case C_DISPATCH:
            case C_DISPATCHI: case C_NEXTSP: (*splits)++; break;
            default: break;
        }
        if (h->op == C_UPDATE) *stage += (NSUInteger)(((const c_update *)x)->size + 15) & ~(NSUInteger)15;
        if (h->op == C_QCOPY) { *qn += ((const c_qcopy *)x)->n; (*qcmds)++; }
        if (h->op == C_INDIRECT && ((const c_indirect *)x)->count) {
            NSUInteger bytes = indirect_size(x);
            if (bytes > g_dev.maxBufferLength || *indirect > g_dev.maxBufferLength - bytes) *too_big = 1; else *indirect += bytes;
        }
        if (h->op == C_EXEC) { const c_exec *e = x; for (uint32_t i = 0; i < e->n; i++) prescan(sq, e->cb[i], splits, indirect, stage, qn, qcmds, too_big); }
    }
}
VKB(vkQueueSubmit, VkResult, VkQueue q, uint32_t n, const VkSubmitInfo *si, VkFence f) {
    if (vk_stopping()) return VK_ERROR_DEVICE_LOST;
    (void)q; dm_gfx_enter();   // blocks while the app is in the background (iOS allows no GPU work there)
    @autoreleasepool {
        pthread_mutex_lock(&g_qmu);
        if (vk_stopping()) { pthread_mutex_unlock(&g_qmu); dm_gfx_leave(); return VK_ERROR_DEVICE_LOST; }
        id<MTLCommandBuffer> cb = [g_q commandBuffer];
        wd_promote(cb);   // 宽屏核心上次提交里按内容判成画布的图像：本次回放前重建成放宽存储（vk_widen.inc）
        subq_t *sq = zalloc(sizeof *sq); sq->v = g_ev_val + 1;
        uint32_t splits = 0, qn = 0, qcmds = 0; NSUInteger indirect_bytes = 0, stage_bytes = 0; int too_big = 0;
        for (uint32_t i = 0; i < n; i++)   // one slot per query plus each possible encoder split while a query is active; staging for updates and query copies
            for (uint32_t j = 0; j < si[i].commandBufferCount; j++) prescan(sq, si[i].pCommandBuffers[j], &splits, &indirect_bytes, &stage_bytes, &qn, &qcmds, &too_big);
        if (too_big) { free(sq); pthread_mutex_unlock(&g_qmu); dm_gfx_leave(); return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
        if (indirect_bytes) {
            sq->indirect = [g_dev newBufferWithLength:indirect_bytes options:MTLResourceStorageModePrivate];
            if (!sq->indirect) { free(sq); pthread_mutex_unlock(&g_qmu); dm_gfx_leave(); return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
            g_indirect_buffers++; g_indirect_bytes += indirect_bytes;
        }
        if (sq->cap) {
            sq->cap += splits;
            sq->vis = [g_dev newBufferWithLength:(NSUInteger)sq->cap * 8 options:MTLResourceStorageModeShared];
            sq->results = [g_dev newBufferWithLength:(NSUInteger)sq->cap * 8 options:MTLResourceStorageModeShared];
            if (!sq->vis || !sq->results) die("[vk] cannot allocate occlusion query buffers");
            memset(sq->vis.contents, 0, (NSUInteger)sq->cap * 8);
            sq->occ = zalloc(sq->cap * sizeof *sq->occ);
        }
        if (qcmds) stage_bytes += (NSUInteger)qn * 24 + (NSUInteger)(sq->cap ? sq->cap : 1) * 4 * qn + (NSUInteger)qcmds * 32;
        if (stage_bytes) {
            sq->stage = [g_dev newBufferWithLength:stage_bytes options:MTLResourceStorageModeShared];
            if (!sq->stage) { free(sq->occ); free(sq); pthread_mutex_unlock(&g_qmu); dm_gfx_leave(); return VK_ERROR_OUT_OF_DEVICE_MEMORY; }
        }
        for (uint32_t i = 0; i < n; i++)
            for (uint32_t j = 0; j < si[i].commandBufferCount; j++) { rs_t s = {0}; s.cb = cb; s.sq = sq; s.pc_seq = ++g_pc_seq; replay(&s, si[i].pCommandBuffers[j]); }
        uint64_t v = ++g_ev_val, fr = g_frames + 1;
        pthread_mutex_lock(&g_gt_mu); if (g_gt[fr % GT_N].f != fr) g_gt[fr % GT_N] = (typeof(g_gt[0])){fr, 0, 0, 0}; g_gt[fr % GT_N].pend++; pthread_mutex_unlock(&g_gt_mu);
        [cb encodeSignalEvent:g_ev value:v];
        if (f) atomic_store(&f->val, v);
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            if (c.error && !mtl_gpu_cb_error(c.error, "vk", v)) { static int k; if (k++ < 20) LOG("[vk] 【红】 command buffer error (submission %llu): %s", (unsigned long long)v, c.error.localizedDescription.UTF8String); s2a_direct_gpu_error(c.error.localizedDescription.UTF8String); }
            g_done_ns[v % DONE_RING] = now_ns();
            { double dt = (c.GPUEndTime - c.GPUStartTime) * 1e3; pthread_mutex_lock(&g_gt_mu);
              if (g_gt[fr % GT_N].f == fr) { if (dt > 0) g_gt[fr % GT_N].ms += dt; g_gt[fr % GT_N].pend--; } pthread_mutex_unlock(&g_gt_mu); }
            if (sq->nvis) { const uint64_t *r = sq->results.contents; for (uint32_t k = 0; k < sq->nvis; k++) {
                const occ_t *o = &sq->occ[k]; uint64_t v = r[o->slot];
                if (o->add) o->q->val[o->idx] += v; else o->q->val[o->idx] = v;
            } }
            for (uint32_t k = 0; k < sq->nev; k++) atomic_store(&sq->ev[k].e->set, sq->ev[k].set);   // vkCmdSetEvent / vkCmdResetEvent, in command order
            sq->vis = nil; sq->results = nil; sq->indirect = nil; sq->stage = nil; sq->fc = sq->fw = nil; free(sq->occ); free(sq->ev); free(sq);
            done_advance(v);   // after the results: a query is read as available once g_done reaches its ticket
        }];
        if (mtl_gpu_go()) [cb commit];   // GPU 安全停后不交
        g_n_submit++;
        pthread_mutex_unlock(&g_qmu);
    }
    dm_gfx_leave();
    return VK_SUCCESS;
}
VK(vkQueueBindSparse, VkResult, VkQueue q, uint32_t n, const VkBindSparseInfo *bi, VkFence f) {
    (void)q; (void)bi; if (n) RED1("sparse binding not implemented");
    if (f) atomic_store(&f->val, 0);
    return n ? VK_ERROR_FEATURE_NOT_PRESENT : VK_SUCCESS;
}
static void wait_done(uint64_t v) {
    pthread_mutex_lock(&g_done_mu);
    while (atomic_load(&g_done) < v && !vk_stopping()) pthread_cond_wait(&g_done_cv, &g_done_mu);
    pthread_mutex_unlock(&g_done_mu);
}
void dm_vk_drain(void) { pthread_mutex_lock(&g_qmu); uint64_t v = g_ev_val; pthread_mutex_unlock(&g_qmu); wait_done(v); }   // dm_gfx_suspend (hle_nvn.c)
VKB(vkQueueWaitIdle, VkResult, VkQueue q) { (void)q; pthread_mutex_lock(&g_qmu); uint64_t v = g_ev_val; pthread_mutex_unlock(&g_qmu); wait_done(v); return vk_stopping() ? VK_ERROR_DEVICE_LOST : VK_SUCCESS; }
VKB(vkDeviceWaitIdle, VkResult, VkDevice d) { (void)d; return h_vkQueueWaitIdle(&g_queue); }
VK(vkCreateFence, VkResult, VkDevice d, const VkFenceCreateInfo *ci, const VkAllocationCallbacks *a, VkFence *out) {
    (void)d; (void)a; VkFence f = obj_alloc(sizeof *f, O_PLAIN); atomic_store(&f->val, ci->flags & VK_FENCE_CREATE_SIGNALED_BIT ? 0 : FENCE_NONE); *out = f; return VK_SUCCESS;
}
VK(vkDestroyFence, void, VkDevice d, VkFence f, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(f); }
VK(vkResetFences, VkResult, VkDevice d, uint32_t n, const VkFence *f) { (void)d; for (uint32_t i = 0; i < n; i++) atomic_store(&f[i]->val, FENCE_NONE); return VK_SUCCESS; }
VK(vkGetFenceStatus, VkResult, VkDevice d, VkFence f) { (void)d; return fence_done(f) ? VK_SUCCESS : VK_NOT_READY; }
VKB(vkWaitForFences, VkResult, VkDevice d, uint32_t n, const VkFence *fs, VkBool32 all, uint64_t timeout) {
    (void)d; uint64_t t0 = now_ns(); int warned = 0;
    pthread_mutex_lock(&g_done_mu);
    for (;;) {
        if (vk_stopping()) { pthread_mutex_unlock(&g_done_mu); return VK_ERROR_DEVICE_LOST; }
        uint32_t k = 0; for (uint32_t i = 0; i < n; i++) k += fence_done(fs[i]);
        if (all ? k == n : k > 0) { pthread_mutex_unlock(&g_done_mu); return VK_SUCCESS; }
        uint64_t el = now_ns() - t0;
        if (el >= timeout) { pthread_mutex_unlock(&g_done_mu); return VK_TIMEOUT; }
        if (!warned && el > 5000000000ull) { warned = 1; LOG("[vk] 【红】 fence wait over 5 s (%u fences, %u done; a fence never submitted never completes)", n, k); }
        uint64_t left = timeout - el, step = left < 100000000ull ? left : 100000000ull;
        struct timespec ts = {(time_t)(step / 1000000000ull), (long)(step % 1000000000ull)};
        pthread_cond_timedwait_relative_np(&g_done_cv, &g_done_mu, &ts);
    }
}
VK(vkCreateQueryPool, VkResult, VkDevice d, const VkQueryPoolCreateInfo *ci, const VkAllocationCallbacks *a, VkQueryPool *out) {
    (void)d; (void)a;
    if (ci->queryType != VK_QUERY_TYPE_TIMESTAMP && ci->queryType != VK_QUERY_TYPE_OCCLUSION) LOG("[vk] 【红】 query pool type %d not implemented", ci->queryType);
    VkQueryPool q = obj_alloc(sizeof *q, O_QUERY); q->type = ci->queryType; q->n = ci->queryCount;
    q->val = zalloc(umax(1, q->n) * sizeof *q->val); q->ticket = zalloc(umax(1, q->n) * sizeof *q->ticket);
    for (uint32_t i = 0; i < q->n; i++) q->ticket[i] = FENCE_NONE;
    VLOG("query pool %p: type %d, %u queries", (void *)q, q->type, q->n);
    *out = q; return VK_SUCCESS;
}
VK(vkDestroyQueryPool, void, VkDevice d, VkQueryPool q, const VkAllocationCallbacks *a) { (void)d; (void)a; if (q) { free(q->val); free(q->ticket); obj_free(q); } }
VKB(vkGetQueryPoolResults, VkResult, VkDevice d, VkQueryPool q, uint32_t first, uint32_t n, size_t size, void *data, VkDeviceSize stride, VkQueryResultFlags fl) {
    (void)d; VkResult res = VK_SUCCESS; int w64 = fl & VK_QUERY_RESULT_64_BIT, av = fl & VK_QUERY_RESULT_WITH_AVAILABILITY_BIT;
    for (uint32_t i = 0; i < n && first + i < q->n; i++) {
        uint32_t k = first + i; uint64_t t = q->ticket[k];
        if (t != FENCE_NONE && (fl & VK_QUERY_RESULT_WAIT_BIT)) wait_done(t);   // a query no submit has written yet stays unavailable instead of waiting forever
        int ok = t != FENCE_NONE && atomic_load(&g_done) >= t;
        uint8_t *p = (uint8_t *)data + (size_t)i * stride; if ((size_t)(p - (uint8_t *)data) + (w64 ? 8 : 4) * (av ? 2 : 1) > size) break;
        if (ok || (fl & VK_QUERY_RESULT_PARTIAL_BIT)) {
            uint64_t v = !ok ? 0 : q->type == VK_QUERY_TYPE_TIMESTAMP ? g_done_ns[t % DONE_RING] : q->val[k];
            if (w64) memcpy(p, &v, 8); else { uint32_t v32 = (uint32_t)v; memcpy(p, &v32, 4); }
        }
        if (av) { uint64_t a1 = ok; if (w64) memcpy(p + 8, &a1, 8); else { uint32_t a32 = ok; memcpy(p + 4, &a32, 4); } }
        if (!ok) res = VK_NOT_READY;
    }
    return res;
}
VK(vkCreateSemaphore, VkResult, VkDevice d, const VkSemaphoreCreateInfo *ci, const VkAllocationCallbacks *a, VkSemaphore *out) {
    (void)d; (void)ci; (void)a; *out = obj_alloc(sizeof **out, O_PLAIN); return VK_SUCCESS;   // every submit runs in order on one queue: waits are already satisfied
}
VK(vkDestroySemaphore, void, VkDevice d, VkSemaphore s, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(s); }
VK(vkCreateEvent, VkResult, VkDevice d, const VkEventCreateInfo *ci, const VkAllocationCallbacks *a, VkEvent *out) { (void)d; (void)ci; (void)a; *out = obj_alloc(sizeof **out, O_PLAIN); return VK_SUCCESS; }
VK(vkDestroyEvent, void, VkDevice d, VkEvent e, const VkAllocationCallbacks *a) { (void)d; (void)a; obj_free(e); }
VK(vkGetEventStatus, VkResult, VkDevice d, VkEvent e) { (void)d; return atomic_load(&e->set) ? VK_EVENT_SET : VK_EVENT_RESET; }
VK(vkSetEvent, VkResult, VkDevice d, VkEvent e) { (void)d; atomic_store(&e->set, 1); return VK_SUCCESS; }
VK(vkResetEvent, VkResult, VkDevice d, VkEvent e) { (void)d; atomic_store(&e->set, 0); return VK_SUCCESS; }

// ---------- Swapchain and present ----------
VKB(vkCreateSwapchainKHR, VkResult, VkDevice d, const VkSwapchainCreateInfoKHR *ci, const VkAllocationCallbacks *a, VkSwapchainKHR *out) {
    (void)d; (void)a; dev_init();
    const fmt_t *f = fmt_of(ci->imageFormat);
    if (!f || f->pf == MTLPixelFormatInvalid) { LOG("[vk] 【红】 swap chain format %d not mapped", ci->imageFormat); return VK_ERROR_FORMAT_NOT_SUPPORTED; }
    VkSwapchainKHR sc = obj_alloc(sizeof *sc, O_PLAIN); sc->n = umin(umax(ci->minImageCount, 2), 4);
    @autoreleasepool {
        for (uint32_t i = 0; i < sc->n; i++) {
            uint32_t wid = wd_new_id(), th = ci->imageExtent.height, tw = wd_image(wid, ci->imageExtent.width, th, 0, &th);   // 交换链图像同样是放宽 / 加高的渲染目标（上屏时核心按屏幕比裁）
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f->pf width:tw height:th mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | (ci->imageUsage & VK_IMAGE_USAGE_STORAGE_BIT ? MTLTextureUsageShaderWrite : 0);
            td.storageMode = MTLStorageModePrivate;
            VkImage im = obj_alloc(sizeof *im, O_IMAGE);
            im->tex = [g_dev newTextureWithDescriptor:td]; im->f = f; im->fmt = ci->imageFormat; im->type = VK_IMAGE_TYPE_2D;
            im->w = ci->imageExtent.width; im->h = ci->imageExtent.height; im->d = im->mips = im->layers = im->samples = 1; im->wid = wid;
            im->serial = mtl_ext_tex((__bridge void *)im->tex); im->swap = 1;
            sc->img[i] = im;
        }
    }
    VLOG("swap chain %ux%u format %d, %u images (at least %u requested), present mode %d", ci->imageExtent.width, ci->imageExtent.height, ci->imageFormat, sc->n, ci->minImageCount, ci->presentMode);
    *out = sc; return VK_SUCCESS;
}
VKB(vkDestroySwapchainKHR, void, VkDevice d, VkSwapchainKHR sc, const VkAllocationCallbacks *a) {
    (void)d; (void)a; if (!sc) return;
    for (uint32_t i = 0; i < sc->n; i++) { if (sc->ticket[i]) nvn_be_present_wait(sc->ticket[i]); wd_release(sc->img[i]->wid); sc->img[i]->tex = nil; obj_free(sc->img[i]); }   // the present path keeps its own reference to each texture
    obj_free(sc);
}
VK(vkGetSwapchainImagesKHR, VkResult, VkDevice d, VkSwapchainKHR sc, uint32_t *n, VkImage *out) {
    (void)d; if (!out) { *n = sc->n; return VK_SUCCESS; }
    uint32_t k = umin(*n, sc->n); memcpy(out, sc->img, k * sizeof *out); *n = k; return k < sc->n ? VK_INCOMPLETE : VK_SUCCESS;
}
static uint64_t g_next_acq;   // pacing without the display link: the earliest time of the next acquire (one frame period after the previous one)
VKB(vkAcquireNextImageKHR, VkResult, VkDevice d, VkSwapchainKHR sc, uint64_t timeout, VkSemaphore sem, VkFence f, uint32_t *idx) {
    (void)d; (void)timeout; (void)sem;
    uint32_t i = sc->next++ % sc->n;
    uint64_t period = nvn_fps_period_ns(1000000000ull / (uint64_t)nvn_be_fps_target()), now = now_ns();
    // Paced by the display link when it runs, as NVN's acquire (hle_nvn.c nvnWindowAcquireTexture): FIFO presents one frame per vsync. A clock of our own drifts against the screen:
    // Super Mario Galaxy 2 on an iPhone put two frames into some display-link ticks and none into others (about one tick in seven), and on a Mac window it ran at 30 fps
    if (nvn_be_link_active() && nvn_be_link_wait_tick((int)(60 / nvn_be_fps_target()), 2 * period)) g_next_acq = now_ns() + period;
    else {
        if (g_next_acq > now) s2a_sleep_ns((int64_t)(g_next_acq - now));   // 不用 nanosleep：游戏线程 utility 下多睡约 100 ms（10-26 Mac 银河 2 标题页 118 ms / 帧）
        now = now_ns(); g_next_acq = g_next_acq && now < g_next_acq + period ? g_next_acq + period : now + period;
    }
    if (sc->ticket[i]) nvn_be_present_wait(sc->ticket[i]);   // its previous present has been shown, so drawing into it again is safe
    if (vk_stopping()) return VK_ERROR_DEVICE_LOST;
    if (f) atomic_store(&f->val, 0);
    *idx = i; return VK_SUCCESS;
}
static void frame_end(void) {
    static uint64_t pd, pp, ps, pc;
    uint64_t f = ++g_frames, dr = g_n_draw, pa = g_n_pass, su = g_n_submit, co = g_n_copy;
    gt_close(f);   // 这一帧的提交到此为止（GPU 时间等它们全部完成后可读）
    if (f <= 3 || f % 300 == 0)
        VLOG("frame %llu: draws %llu, passes %llu, submits %llu, copies %llu (since the last record, %llu frames); pipelines so far %llu, buffer memory %.1f MB", (unsigned long long)f, (unsigned long long)(dr - pd),
             (unsigned long long)(pa - pp), (unsigned long long)(su - ps), (unsigned long long)(co - pc), (unsigned long long)(f <= 3 ? 1 : 300), (unsigned long long)g_n_pso, g_mem_bytes / 1048576.0);
    if (f <= 3 || f % 300 == 0) { pd = dr; pp = pa; ps = su; pc = co; }
    dm_guest_frame_tick();
    // On-screen interval of the present 8 presents back (its presented callback has arrived by then), as the NVN layer reports it (hle_nvn.c): the present path numbers
    // presents by ticket, and a Vulkan game's presents are the only ones, so present n is ticket n; −1 = the system dropped it, 0 = no reading
    if (f > 9) { double a = nvn_be_presented_time(f - 8), b = nvn_be_presented_time(f - 9); dm_perf_present(a < 0 ? -1 : a > 0 && b > 0 ? (a - b) * 1e3 : 0); }
}
void dm_vk_stats(uint64_t *frames, uint64_t *draws, uint64_t *passes) { *frames = g_frames; *draws = atomic_load(&g_n_draw); *passes = atomic_load(&g_n_pass); }   // S2Arm 改（graphics/nvn/host_adapt.m）：直连帧数 / 自动玩家每帧绘制数
VKB(vkQueuePresentKHR, VkResult, VkQueue q, const VkPresentInfoKHR *pi) {
    if (vk_stopping()) return VK_ERROR_DEVICE_LOST;
    (void)q; dm_gfx_enter();
    if (vk_stopping()) { dm_gfx_leave(); return VK_ERROR_DEVICE_LOST; }
    pthread_mutex_lock(&g_qmu); uint64_t v = g_ev_val; pthread_mutex_unlock(&g_qmu);
    int vi[4]; dm_vi_layer_crop(vi);   // the vi layer crop (hle_vi.c): Super Mario Galaxy shows the top-left 1280x720 of its 1920x1080 swapchain in handheld mode
    for (uint32_t i = 0; i < pi->swapchainCount; i++) {
        VkSwapchainKHR sc = pi->pSwapchains[i]; uint32_t k = pi->pImageIndices[i];
        // P2-4：下标越出交换链张数时不上屏、这一条结果与返回值照旧是成功——记一笔（改失败码待读数定）
        if (k >= sc->n) { g_okb[OKB_PRESENT_IDX]++; RED1("vkQueuePresentKHR 下标 %u 越出交换链 %u 张：不上屏，照旧回 VK_SUCCESS（待读数定）", k, sc->n); }
        // 游戏给了 vi 层裁切就用它；没给（S2Arm 的 vi 在服务层，还没导出）就按本帧画进这张交换链图像的范围裁（GL 层同口径：游戏按自己的层尺寸画，不查询表面）
        int crop[4] = {vi[0], vi[1], vi[2], vi[3]};
        if (k < sc->n && !crop[2] && !crop[3]) {
            VkImage im = sc->img[k];
            if (im->ext_w && im->ext_h && (im->ext_w < im->w || im->ext_h < im->h)) {
                crop[2] = (int)im->ext_w; crop[3] = (int)im->ext_h;
                static uint32_t lw, lh; if (lw != im->ext_w || lh != im->ext_h) { lw = im->ext_w; lh = im->ext_h; LOG("[vk] 上屏取交换链图像左上 %ux%u（本帧画到的范围，图像 %ux%u；游戏没给 vi 层裁切）", lw, lh, im->w, im->h); }
            }
            im->ext_w = im->ext_h = 0;
        }
        if (k < sc->n && g_wd > 0) wd_present(sc->img[k]->wid, sc->img[k]->w, sc->img[k]->h, crop);   // 宽屏：裁剪框按放宽换算（不裁时给整张放宽后的范围）
        int fit = crop[2] > 0 && crop[3] > 0 && k < sc->n && (uint32_t)(crop[0] + crop[2]) <= sc->img[k]->tex.width && (uint32_t)(crop[1] + crop[3]) <= sc->img[k]->h;
        if (k < sc->n) sc->ticket[k] = mtl_present_ext(sc->img[k]->serial, nvn_fps_period(1.0 / nvn_be_fps_target()), (__bridge void *)g_ev, v, fit ? crop : NULL);
        if (pi->pResults) pi->pResults[i] = VK_SUCCESS;
    }
    dm_gfx_leave();
    tex_mem_report();
    frame_end();
    return VK_SUCCESS;
}

// ---------- Function lookup ----------
static void *vk_lookup(const char *name) {
    static const hle_ent *sec; static unsigned long sz;
    if (!name || strncmp(name, "vk", 2)) return NULL;
    if (!sec) sec = (const hle_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swhle", &sz);
    void *fn = NULL; size_t n = strlen(name);
    for (int pass = 0; pass < 2 && !fn; pass++) {
        size_t len = pass ? n - 3 : n;
        if (pass && (n < 4 || strcmp(name + n - 3, "KHR"))) break;   // second pass: an extension function promoted to core under the name without KHR
        for (unsigned long i = 0; i < sz / sizeof *sec && !fn; i++) if (!strncmp(sec[i].name, name, len) && !sec[i].name[len]) fn = sec[i].fn;
    }
    static const char *seen[512]; static int nseen; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    int known = 0; for (int i = 0; i < nseen; i++) if (!strcmp(seen[i], name)) { known = 1; break; }
    if (!known && nseen < 512) { seen[nseen++] = strdup(name); VLOG("lookup %s → %s", name, fn ? "host implementation" : "none (returns null)"); }
    pthread_mutex_unlock(&mu);
    return fn;
}
void *dm_vk_lookup(const char *name) { return vk_lookup(name); }   // S2Arm 改：给 S2Arm 装载器 / 适配层（host_adapt.m）按名字取实现
VK(vkGetInstanceProcAddr, PFN_vkVoidFunction, VkInstance i, const char *name) { (void)i; return (PFN_vkVoidFunction)vk_lookup(name); }
VK(vkGetDeviceProcAddr, PFN_vkVoidFunction, VkDevice d, const char *name) { (void)d; return (PFN_vkVoidFunction)vk_lookup(name); }

#include "vk_session.inc"
