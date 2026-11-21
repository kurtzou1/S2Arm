// PR7：gal 通用路径 HDR 策略一致性闭环（评审稿 v3 §4 PR7 / §2.2 接缝「gal_present.m 只读」/ §2.3 判定次序 / §2.4 模式矩阵）。
//   生产 gal 全链路（render_to = 上屏同一段编码——真着色器上 GPU）+ 生产策略存储（graphics/nvn/gfx/nvn/nvn2.c
//   经 Makefile 链进本单测：gal 经 dlsym 接缝（RTLD_DEFAULT，同 gal_present.m ap_direct 先例——宿主里由直连图形层给，
//   本测试里命中可执行文件里的生产强定义）取到的就是这份生产实现；发布 / 开机预挂 / 排空喂入 / present 参数全走 nvn2_hdr_* 入口）。
//   期望值 CPU 双精度复算（±1 LSB，同 PR3b t_present_hdr 口径）；off 不变量对改前 trivial 采样着色器（gal_present.m pr_fs
//   原样拷贝成本文件对照管线）逐字节比对。三态流的 test-only / negctl 态红由此而来：基线（无 PR7 实现）上 gal 不接策略抽象——
//   层不切 PQ、PQ 目标直通不转换，②③④ 红。
// ① off 不变量（S2A_HDR 缺省）：render_to（8 位 / 10 位目标都直通——改前 gal 无 PQ 层逻辑）与改前 trivial 逐字节一致；
//    出图层不被碰（BGRA8Unorm + sRGB tag + 无 wantsEDR）。
// ② PQ 层进入（S2A_HDR=on + 合成快照 s1_ready=1 + 生产入口 nvn2_hdr_preattach 开机预挂进层簿记）：gal 按快照层态
//    应用 S1 配置（§2.3 S1 行：RGB10A2Unorm + kCGColorSpaceITUR_2100_PQ + wantsExtendedDynamicRangeContent）。
// ③ mode 2 闭环对拍（§2.3 判定次序 2「层不因源切回」+ §2.4 mode 2）：SDR 定格源 → PQ 层目标按纸白 100 nit 编码
//    （SDR 白 255 = 100 nit、中灰 128 = 线性值、阴影按 2.2 解码不抬肩、彩色经 BT.709→BT.2020 矩阵、转换态 alpha 写 1
//    ——同 PR3b ④/⑤ 口径）；8 位目标恒平凡直通（开关无关：mode 1 需 HDR10 源，gal 出图源恒 SDR 定格贴图）。
// ④ PQ→SDR 切回（S2A_HDR 回 off + 排空喂入两帧）：切回的层保留 PQ 色彩空间——gal 必须显式重设 sRGB tag
//    （§2.3 注意事项①：不设则无色彩匹配、字节直进屏幕原生 primaries，P3 屏过饱和）；存储侧层簿记同步归 0。
// ⑤ off 不变量回归（排空切回后）：render_to 恢复 trivial 逐字节（off ⇒ 出图恒 S0 直通——两处同时回退）。
#include "../gal_abi.h"
#include "../gal_formats.h"
#include "../../nvn/gfx/nvn/nvn_hdr_policy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <objc/runtime.h>
#include <objc/message.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// nvn2.c 的宿主替身（同 graphics/nvn/tests/t_nvn2.c 文案：宿主不链进本单测）：vi_max_res 读的主机 / 掌机档
int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && !strcmp(d, "1"); }
// nvn_gob_switch2：定义在 nvn_deswizzle.c（贴图解交错用的 GOB 次序档）——本单测不走贴图路径，只补链接
//   （nvn2_device_init 写它；同 t_nvn_storage_copy.m 的 extern 声明）
int nvn_gob_switch2;

// ---------- CPU 双精度参考式（PR3b t_present_hdr 同式；PQ 侧与 nvn_hdr_policy.h hdr_pq_code 同参）----------
static double pq_code(double nits) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double y = pow(nits / 10000.0, m1);
    return pow((c1 + c2 * y) / (1.0 + c3 * y), m2) * 1023.0;
}
static double sdr_dec(double c) { return pow(c, 2.2); }   // Q13 缺省口径（S2A_HDR_SDR_GAMMA 不设）
static double srgb_dec(double c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }   // 分段 sRGB 曲线（会抬暗部）

#define N 8
static nxgal_tex_info info2d(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }
static nxgal_crop crop_full(void) { nxgal_crop c = {0, 0, 0, 0, 0, 0, 1, 16, 9}; return c; }   // 拉伸满幅：8×1 帧 → 8×1 目标 1:1，无缩放插值
// BGRA8 源（内存字节 b,g,r,a——同 t_present.c「BGRA 源：内存字节原样」：定格贴图字节 = 源字节，出图采样的是它）
static uint32_t mk_bgra_src(const uint8_t px[N][4]) {
    nxgal_tex_info i = info2d(N, 1, F_B8G8R8A8Unorm, 4);
    uint32_t t = nxgal_tex_create(&i);
    uint8_t d[N * 4];
    for (int i = 0; i < N; i++) { d[4 * i] = px[i][0]; d[4 * i + 1] = px[i][1]; d[4 * i + 2] = px[i][2]; d[4 * i + 3] = 255; }
    nxgal_tex_set_data(t, 0, 0, NULL, d, sizeof d);
    return t;
}
static uint32_t mk_gray_src(void) {   // 灰阶（同 PR3b ④ 的档位）：SDR 白 / 中灰 / 阴影 / 黑
    static const uint8_t v[N] = {255, 128, 64, 32, 16, 8, 4, 0};
    uint8_t px[N][4];
    for (int i = 0; i < N; i++) { px[i][0] = px[i][1] = px[i][2] = v[i]; px[i][3] = 255; }
    return mk_bgra_src(px);
}
static uint32_t mk_color_src(void) {  // 彩色（BT.709 外的分量，走矩阵才对得上——同 PR3b ⑤b 思路）
    uint8_t px[N][4] = {{200, 100, 50, 255}, {255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}, {10, 200, 180, 255}, {128, 64, 220, 255}, {255, 128, 255, 255}};
    return mk_bgra_src((const uint8_t (*)[4])px);
}

// ---------- 出图层读数（objc_msgSend——同 t_present.c 的层夹具）----------
typedef struct { double w, h; } cgsz;
static MTLPixelFormat layer_pf(id L) { return (MTLPixelFormat)((unsigned long (*)(id, SEL))objc_msgSend)(L, sel_registerName("pixelFormat")); }
static BOOL layer_wants_edr(id L) { return (BOOL)((long (*)(id, SEL))objc_msgSend)(L, sel_registerName("wantsExtendedDynamicRangeContent")); }
static const char *layer_cs_name(id L) {   // 层色彩空间名（CGColorSpaceGetName——同 front_mac.m screen_edr_note 的读法；静态缓冲，单测单线程够用）
    static char out[64];
    out[0] = 0;
    CGColorSpaceRef cs = ((CGColorSpaceRef (*)(id, SEL))objc_msgSend)(L, sel_registerName("colorspace"));
    if (cs) { CFStringRef nm = CGColorSpaceGetName(cs); if (nm) CFStringGetCString(nm, out, sizeof out, kCFStringEncodingUTF8); }
    return out;
}
static void ref_cs_name(CFStringRef which, char out[64]) {   // 对照名：同一套 CGColorSpaceCreateWithName 的官方名
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(which);
    out[0] = 0;
    if (cs) { CFStringRef nm = CGColorSpaceGetName(cs); if (nm) CFStringGetCString(nm, out, 64, kCFStringEncodingUTF8); CGColorSpaceRelease(cs); }
}
static int layer_cs_is(id L, CFStringRef which) {
    char b[64]; ref_cs_name(which, b);
    const char *a = layer_cs_name(L);
    return a[0] && b[0] && !strcmp(a, b);
}
static id mk_layer(void) {
    id cls = (id)objc_getClass("CAMetalLayer");
    id L = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("layer"));
    ((id (*)(id, SEL))objc_msgSend)(L, sel_registerName("retain"));
    return L;
}
static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
static void msleep(double ms) { struct timespec ts = {0, (long)(ms * 1e6)}; nanosleep(&ts, NULL); }
// 出图直到层读数变化（排空 / 切回要出图线程的节流 tick 跟上：每 20ms 出一帧等 250ms 节流窗过去，墙钟上限 3 秒）
static int present_until(uint32_t t, int (*pred)(id), id L, const char *what) {
    double t0 = now_s();
    nxgal_crop c = crop_full();
    while (now_s() - t0 < 3.0) {
        if (pred(L)) return 1;
        nxgal_present(t, &c);
        msleep(20);
    }
    printf("  等层%s超过 3 秒（现 pixelFormat %lu）\n", what, (unsigned long)layer_pf(L));
    return pred(L);
}
static int pf_is_pq(id L) { return layer_pf(L) == MTLPixelFormatRGB10A2Unorm; }
static int pf_is_sdr8(id L) { return layer_pf(L) == MTLPixelFormatBGRA8Unorm; }

// ---------- 改前 trivial 采样（gal_present.m pr_vs / pr_fs 原样拷贝）：off 不变量的对照管线 ----------
static const char *k_trivial_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct VO { float4 p [[position]]; float2 uv; };\n"
    "vertex VO pr_vs(uint vid [[vertex_id]]) {\n"
    "  float2 uv = float2((vid << 1) & 2, vid & 2); VO o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "fragment float4 pr_fs(VO in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return float4(t.sample(s, in.uv).rgb, 1.0); }\n";
static id<MTLDevice> g_tdev; static id<MTLCommandQueue> g_tq;
static void tdev_init(void) { if (!g_tdev) { g_tdev = MTLCreateSystemDefaultDevice(); g_tq = [g_tdev newCommandQueue]; } }
static id<MTLRenderPipelineState> trivial_pso(MTLPixelFormat fmt) {
    static id<MTLRenderPipelineState> ps[8]; static MTLPixelFormat pfs[8];
    for (int i = 0; i < 8; i++) if (ps[i] && pfs[i] == fmt) return ps[i];
    NSError *e = nil; id<MTLLibrary> lib = [g_tdev newLibraryWithSource:@(k_trivial_msl) options:nil error:&e];
    if (!lib) { printf("  对照管线源码编不出：%s\n", e.localizedDescription.UTF8String ?: "?"); return nil; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"pr_vs"]; d.fragmentFunction = [lib newFunctionWithName:@"pr_fs"];
    d.colorAttachments[0].pixelFormat = fmt;
    id<MTLRenderPipelineState> p = [g_tdev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) { printf("  对照管线建不出（格式 %lu）：%s\n", (unsigned long)fmt, e.localizedDescription.UTF8String ?: "?"); return nil; }
    for (int i = 0; i < 8; i++) if (!ps[i]) { ps[i] = p; pfs[i] = fmt; break; }
    return p;
}
static id<MTLTexture> tsrc(const uint8_t px[N][4]) {   // 对照源贴图：与 GAL 源同一份字节
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_tdev newTextureWithDescriptor:d];
    uint8_t b[N * 4];
    for (int i = 0; i < N; i++) { b[4 * i] = px[i][0]; b[4 * i + 1] = px[i][1]; b[4 * i + 2] = px[i][2]; b[4 * i + 3] = 255; }
    [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:b bytesPerRow:sizeof b];
    return t;
}
static int trivial_run(id<MTLTexture> dst, id<MTLTexture> src) {   // 改前出图同款：最近邻（set_scaling(1)）满幅画三顶点
    id<MTLRenderPipelineState> pso = trivial_pso(dst.pixelFormat);
    if (!pso) return 0;
    id<MTLCommandBuffer> cb = [g_tq commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    [e setRenderPipelineState:pso]; [e setFragmentTexture:src atIndex:0]; [e setFragmentSamplerState:[g_tdev newSamplerStateWithDescriptor:sd] atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}
static id<MTLTexture> tdst(MTLPixelFormat fmt) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [g_tdev newTextureWithDescriptor:d];
}
// ①/③ 的逐字节与对拍核心：render_to（生产出图同一段编码）与对照管线各画一份同尺寸目标，逐字节比
static void check_rt_bytes(const char *name, int fmt_gal, MTLPixelFormat fmt_mtl, const uint8_t px[N][4]) {
    nxgal_tex_info di = info2d(N, 1, fmt_gal, 4);
    uint32_t d = nxgal_tex_create(&di);
    int rc = nxgal_window_render_to(d);
    CHECK(rc == 0, "%s：render_to 返回 %d", name, rc);
    uint8_t got[N * 4], want[N * 4];
    uint64_t n = nxgal_tex_get_data(d, 0, 0, got, sizeof got);
    CHECK(n == sizeof got, "%s：读回 %llu 字节（期望 %llu）", name, (unsigned long long)n, (unsigned long long)sizeof got);
    id<MTLTexture> td = tdst(fmt_mtl);
    int ok = trivial_run(td, tsrc(px));
    CHECK(ok, "%s：对照管线画不出来", name);
    [td getBytes:want bytesPerRow:sizeof want fromRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0];
    int same = !memcmp(got, want, sizeof want);
    CHECK(same, "%s：与改前 trivial 采样逐字节一致 实得 %02x%02x%02x%02x 期望 %02x%02x%02x%02x", name,
          got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
    nxgal_tex_release(d);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    unsetenv("S2A_HDR"); unsetenv("S2A_HDR_SDR_GAMMA");   // ① 起步 = off 缺省；S2A_HDR_SDR_GAMMA 缺省 2.2（期望值同口径）
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    nxgal_window_set_scaling(1, 0);   // 最近邻：与对照管线同款采样器，1:1 无插值、期望可逐字节手算
    tdev_init();
    static const uint8_t v[N] = {255, 128, 64, 32, 16, 8, 4, 0};
    uint8_t gray[N][4];
    for (int i = 0; i < N; i++) { gray[i][0] = gray[i][1] = gray[i][2] = v[i]; gray[i][3] = 255; }
    uint8_t col[N][4] = {{200, 100, 50, 255}, {255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}, {10, 200, 180, 255}, {128, 64, 220, 255}, {255, 128, 255, 255}};
    uint32_t t_g = mk_gray_src(), t_c = mk_color_src();
    nxgal_crop c = crop_full();
    id L = mk_layer();
    CHECK(L != NULL, "建 CAMetalLayer 失败");

    // ① off 不变量：S2A_HDR 缺省——出图与改前 trivial 逐字节（8 位 / 10 位目标都直通）+ 出图层不被碰
    {
        printf("· off 缺省：render_to 与改前 trivial 逐字节（BGRA8 / RGB10A2 目标）；层不被碰（BGRA8 + sRGB + 无 wantsEDR）\n");
        nxgal_present(t_g, &c);
        check_rt_bytes("① off：BGRA8 目标", F_B8G8R8A8Unorm, MTLPixelFormatBGRA8Unorm, (const uint8_t (*)[4])gray);
        check_rt_bytes("① off：RGB10A2 目标（改前无 PQ 层逻辑——trivial 直通）", F_R10G10B10A2Unorm, MTLPixelFormatRGB10A2Unorm, (const uint8_t (*)[4])gray);
        nxgal_window_set_size(N, 1);
        nxgal_window_set_layer((__bridge void *)L);
        for (int k = 0; k < 3; k++) nxgal_present(t_g, &c);
        for (double t0 = now_s(); now_s() - t0 < 3.0; ) {   // 等出图线程落定（至少上一屏一帧）
            uint64_t s[4]; nxgal_window_stats(s); msleep(10);
            if (s[1] >= 1) break;
        }
        CHECK(layer_pf(L) == MTLPixelFormatBGRA8Unorm, "① off：出图层格式应保持 BGRA8Unorm（不碰层）实得 %lu", (unsigned long)layer_pf(L));
        CHECK(layer_cs_is(L, kCGColorSpaceSRGB), "① off：出图层色彩空间应保持 sRGB tag 实得「%s」", layer_cs_name(L));
        CHECK(!layer_wants_edr(L), "① off：wantsExtendedDynamicRangeContent 应保持 NO");
    }

    // ② PQ 层进入：S2A_HDR=on + 合成快照（s1_ready=1、can 预挂即持稳）→ gal 按快照层态应用 S1 配置（创建点重入）
    {
        printf("· S2A_HDR=on + 预挂：出图层应切 PQ（RGB10A2Unorm + BT.2100 PQ + wantsEDR）\n");
        setenv("S2A_HDR", "on", 1);
        hdr_snapshot pub = {.potential_edr = 2.0, .current_headroom = 4.0, .s1_ready = 1, .paper_white = 100};
        nvn2_hdr_snapshot_publish(&pub);
        nvn2_hdr_preattach(1, 1000);   // 生产入口：开机预挂（can 直接按持稳记——进层簿记 layer_pq=1）
        hdr_snapshot s; nvn2_hdr_snapshot_probe(&s);
        CHECK(s.layer_pq == 1, "② 前置：生产存储侧预挂应置层簿记 layer_pq=1（can_settled=%d s1_ready=%d）", s.can_settled, s.s1_ready);
        nxgal_window_set_layer((__bridge void *)L);   // 创建点重入（层已在）：gal 应按快照层态应用——预挂过的层直接 PQ
        CHECK(layer_pf(L) == MTLPixelFormatRGB10A2Unorm, "② 出图层应切 PQ（RGB10A2Unorm）：S2A_HDR=on + 预挂后 gal 按快照层态应用 S1 配置 实得 %lu", (unsigned long)layer_pf(L));
        CHECK(layer_cs_is(L, kCGColorSpaceITUR_2100_PQ), "② 出图层色彩空间应标 BT.2100 PQ（kCGColorSpaceITUR_2100_PQ）实得「%s」", layer_cs_name(L));
        CHECK(layer_wants_edr(L), "② 出图层应开 wantsExtendedDynamicRangeContent（S1 主路径）");
        nxgal_crop cc = crop_full(); nxgal_present(t_g, &cc);   // PQ 层上出图不崩（出图线程 / PSO 全链路）
        for (double t0 = now_s(); now_s() - t0 < 3.0; ) { uint64_t s4[4]; nxgal_window_stats(s4); msleep(10); if (s4[1] >= 2) break; }
    }

    // ③ mode 2 闭环对拍：SDR 定格源 → PQ 层目标（render_to = 上屏同一段编码）
    {
        printf("· mode 2 对拍：SDR 源按纸白 100 nit 编进 PQ（灰阶各档 ±1、彩色走矩阵、alpha 写 1）；8 位目标恒直通\n");
        nxgal_present(t_g, &c);
        {   // 灰阶：SDR 白 255 = 100 nit、中灰 128 = 线性值、阴影 2.2 不抬肩、黑 = 码 0
            nxgal_tex_info di = info2d(N, 1, F_R10G10B10A2Unorm, 4);
            uint32_t d = nxgal_tex_create(&di);
            CHECK(nxgal_window_render_to(d) == 0, "③ render_to（RGB10A2 目标）应返回 0");
            uint32_t w[N]; uint64_t n = nxgal_tex_get_data(d, 0, 0, w, sizeof w);
            CHECK(n == sizeof w, "③ 读回 %llu 字节（期望 %llu）", (unsigned long long)n, (unsigned long long)sizeof w);
            int bad = 0, at = -1;
            for (int i = 0; i < N; i++) {
                double e = pq_code(sdr_dec(v[i] / 255.0) * 100.0);
                if (fabs((double)(w[i] & 0x3ff) - e) > 1.0) { bad++; if (at < 0) at = i; }
            }
            if (bad) printf("③ 首个不符：码 %d 出 %d（期望 %.1f）\n", v[at], (int)(w[at] & 0x3ff), pq_code(sdr_dec(v[at] / 255.0) * 100.0));
            CHECK(!bad, "③ mode 2：灰阶按 2.2 解码、纸白 100 nit 编码（255=%d 128=%d 16=%d 0=%d，各档 ±1）",
                  (int)(w[0] & 0x3ff), (int)(w[1] & 0x3ff), (int)(w[4] & 0x3ff), (int)(w[7] & 0x3ff));
            CHECK(n == sizeof w && (w[0] >> 30) == 3, "③ mode 2：转换态 alpha 写 1（RGB10A2 alpha 位 = 3）");
            CHECK(n == sizeof w && (double)(w[4] & 0x3ff) < pq_code(srgb_dec(16 / 255.0) * 100.0) - 10,
                  "③ mode 2：阴影（码 16）按 2.2 解码——不抬到分段 sRGB 的 2.3 倍光");
            nxgal_tex_release(d);
        }
        {   // 彩色：BT.709→BT.2020 矩阵（shader 列参的行 = PR3b ⑤b 同一行列式）
            nxgal_present(t_c, &c);
            nxgal_tex_info di = info2d(N, 1, F_R10G10B10A2Unorm, 4);
            uint32_t d = nxgal_tex_create(&di);
            CHECK(nxgal_window_render_to(d) == 0, "③ render_to（彩色帧，RGB10A2 目标）应返回 0");
            uint32_t w[N]; uint64_t n = nxgal_tex_get_data(d, 0, 0, w, sizeof w);
            static const double m7[3][3] = {{0.627404, 0.329283, 0.043313}, {0.069097, 0.919540, 0.011362}, {0.016391, 0.088013, 0.895595}};   // kRec709To2020 各行
            int bad = 0, at = -1;
            for (int i = 0; i < (int)(n / 4); i++) {
                double lin[3] = {sdr_dec(col[i][2] / 255.0), sdr_dec(col[i][1] / 255.0), sdr_dec(col[i][0] / 255.0)};   // BGRA 内存 → RGB
                for (int k = 0; k < 3; k++) {
                    double e = pq_code((m7[k][0] * lin[0] + m7[k][1] * lin[1] + m7[k][2] * lin[2]) * 100.0);
                    int got = (int)(w[i] >> (10 * k) & 0x3ff);
                    if (fabs((double)got - e) > 1.0) { bad++; if (at < 0) { at = i * 3 + k; printf("③ 首个不符：像素 %d 通道 %d 出 %d（期望 %.1f）\n", i, k, got, e); } }
                }
            }
            CHECK(!bad, "③ mode 2：彩色经 BT.709→BT.2020 矩阵后编进 PQ（各通道 ±1）");
            nxgal_tex_release(d);
        }
        // 8 位目标恒平凡直通（开关无关）：mode 1 需 HDR10 源，gal 出图源恒 SDR 定格贴图
        nxgal_present(t_g, &c);
        check_rt_bytes("③ 8 位目标恒直通（S2A_HDR=on 也不转换）", F_B8G8R8A8Unorm, MTLPixelFormatBGRA8Unorm, (const uint8_t (*)[4])gray);
    }

    // ④ PQ→SDR 切回：S2A_HDR 回 off（排空喂入两帧）→ 层切回 SDR 并显式重设 sRGB tag（注意事项①）
    {
        printf("· 回 off + 排空：层应切回 SDR 并显式重设 sRGB tag；存储侧层簿记归 0\n");
        CHECK(layer_pf(L) == MTLPixelFormatRGB10A2Unorm, "④ 前置：回退开关前层应仍持 PQ 实得 %lu", (unsigned long)layer_pf(L));
        setenv("S2A_HDR", "off", 1);
        CHECK(present_until(t_g, pf_is_sdr8, L, "排空切回 SDR"), "④ 排空后出图层应切回 SDR（BGRA8Unorm）实得 %lu", (unsigned long)layer_pf(L));
        CHECK(layer_cs_is(L, kCGColorSpaceSRGB), "④ 切回的层保留 PQ 色彩空间——必须显式重设 sRGB tag（评审稿 §2.3 注意事项①）实得「%s」", layer_cs_name(L));
        CHECK(!layer_wants_edr(L), "④ 切回后 wantsExtendedDynamicRangeContent 应回 NO");
        hdr_snapshot s; nvn2_hdr_snapshot_probe(&s);
        CHECK(s.layer_pq == 0, "④ 存储侧层簿记应随排空归 0（layer_pq=%d）", s.layer_pq);
    }

    // ⑤ off 不变量回归：排空切回后 render_to 恢复 trivial 逐字节（off ⇒ 出图恒 S0 直通）
    {
        printf("· off 回归：render_to 恢复 trivial 逐字节（RGB10A2 目标不转换）\n");
        nxgal_present(t_g, &c);
        check_rt_bytes("⑤ off 回归：RGB10A2 目标恢复直通", F_R10G10B10A2Unorm, MTLPixelFormatRGB10A2Unorm, (const uint8_t (*)[4])gray);
    }

    nxgal_window_set_layer(NULL);
    nxgal_tex_release(t_g); nxgal_tex_release(t_c);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
