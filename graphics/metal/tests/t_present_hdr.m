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
// ⑥ PR-A（#625 第二阶段）：SDR→HDR 扩张（BT.2446-1 §4.2 逆映射 present_itm；k_present_msl 的 mode 2 参数化——
//    p.mode.z=sdr nits / p.mode.w=target nits，双零 = off）——合成参数直驱生产 gal 源（k_present_msl 的 pr_fs_hdr，
//    真着色器上 GPU；生产链路的 p 经 nvn2_hdr_present 取、PR-A 期恒 0,0），与 nvn 侧 t_present_hdr ⑩ 同一份期望
//    （CPU 双精度参考复算 ±1）；off 金标对冻结的改前 mode 2 单式逐字节。红态（无实现）：对拍全红。
// ⑦ PR #2080 评审第 1 轮（要改①）·独立判据（gal 副本——与 nvn 侧 ⑪ 同判据、同一组样本）：⑥ 的对拍期望由 itm_ref
//    （present_itm 同一逆式的 CPU 转写）复算——只能证 GPU/CPU 算得一致、证不了公式本身对（公式写错则两边一起错、
//    单测照样绿）。本组期望 = 输入本身：BT.2446-1 §4.1 Method A 前向式（HDR→SDR，标准正文给的方向）作用于
//    present_itm 的 GPU 输出应回到输入；灰阶几档 + 灰阶 256 码全扫 + 饱和色 + 两处段界与段界缝内样本，sdr=100/
//    target=400 与 100/1000 两组；探针直调生产 present_itm 文本（gal_present.m 独立导出的 k_present_itm_msl——
//    k_present_msl 拼进 pr_fs_hdr 的同一份，运行时按名取），RGBA32F 线性直出（不经 PQ 10 位量化）；容差 1.5e-3
//    按三段 EETF 段界不连续定（段 1/2 交界两段式差 5.46e-4 经 ρ_SDR 归一放大 ≈1.48 ⇒ 输入信号域 ≈8.1e-4——见 ⑦ 注释）。
//    红态（基线无 k_present_itm_msl 导出）：探针无文本可编，显式红。
#include "../gal_abi.h"
#include "../gal_formats.h"
#include "../../nvn/gfx/nvn/nvn_hdr_policy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include <dlfcn.h>   // ⑦ dlsym 按名取 gal_present.m 独立导出的 k_present_itm_msl（同 gal_present.m 跨层可选符号的按名先例；红态基线无此符号 = 取不到）
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

// ---------- ⑥ PR-A（#625 第二阶段）：SDR→HDR 扩张（BT.2446-1 §4.2 逆映射 present_itm；k_present_msl 的 mode 2 参数化——
//   p.mode.z = sdr nits / p.mode.w = target nits，HP 槽位与直连 Crop 一一对应）----------
//   生产链路的 p 经 dlsym 同一入口 nvn2_hdr_present 取（PR-A 期扩张双参恒 0,0——开关解析在 PR-B，设计稿 §2.4 填充落点），
//   扩张用例以合成 HP 直驱生产 gal 源（k_present_msl——链接进本单测的生产源码，真着色器上 GPU）；
//   期望值 CPU 双精度参考复算 ±1 LSB（与 PR3b t_present_hdr nvn 侧同一份期望——两份副本同测）。
//   红态（无 PR-A 实现）：gal 源无扩张分支 ⇒ 对拍全红。
extern NSString *const k_present_msl;   // gal_present.m 的生产出图变体源（链接同树生产源码——同 PR7 的生产接缝口径）

// BT.2446-1 §4.2（Method A）逆色调映射 CPU 双精度参考（设计稿 §2.2 逐段转写——gamescope 通用解析式同式；
//   nvn 侧 t_present_hdr 同式）。入：线性光（BT.2020 基色，1.0 = sdr_nits）；出：线性光（1.0 = target_nits）。
static void itm_ref(const double lin[3], double sdr_nits, double target_nits, double out[3]) {
    static const double k2020[3] = {0.262698338956556, 0.678008765772817, 0.0592928952706273};   // BT.2020 亮度系数（gamescope 同值）
    const double kR = 1.47460332208689, kB = 1.88141420945875;   // 2 − 2·k2020.r / 2 − 2·k2020.b
    double n[3] = { pow(fmax(lin[0], 0.0), 1.0 / 2.4), pow(fmax(lin[1], 0.0), 1.0 / 2.4), pow(fmax(lin[2], 0.0), 1.0 / 2.4) };   // γ 压缩
    double y = k2020[0] * n[0] + k2020[1] * n[1] + k2020[2] * n[2];   // Y'tmo（BT.2020 亮度变换）
    double cb = (n[2] - y) / kB, cr = (n[0] - y) / kR;   // C'b / C'r
    double y_sdr = y + fmax(0.1 * cr, 0.0);   // 亮度调整（逆）
    double p_sdr = 1.0 + 32.0 * pow(sdr_nits / 10000.0, 1.0 / 2.4);
    double y_c = log(y_sdr * (p_sdr - 1.0) + 1.0) / log(p_sdr);   // psdr 归一
    double y_p0 = y_c / 1.0770, y_p1 = (-2.7811 + sqrt(4.83307641 - 4.604 * y_c)) / -2.302, y_p2 = (y_c - 0.5) / 0.5;   // 三段逆式
    double y_p;
    if (y_p0 <= 0.7399) y_p = y_p0;
    else if (y_p1 > 0.7399 && y_p1 < 0.9909) y_p = y_p1;
    else if (y_p2 >= 0.9909) y_p = y_p2;
    else y_p = y_p1;   // 段界浮点兜底（gamescope 同款：误差 <0.001）
    double p_hdr = 1.0 + 32.0 * pow(target_nits / 10000.0, 1.0 / 2.4);
    double y_ = (pow(p_hdr, y_p) - 1.0) / (p_hdr - 1.0);   // phdr 归一（Y'hdr）
    double col_scale = y_ > 0.0 ? y_sdr / (1.1 * y_) : 1.0;   // 保色调标量（恰黑兜底 1.0——黑→黑精确，无 gamescope 的 0/0=NaN）
    double o[3];
    o[2] = cb * kB / col_scale + y_;
    o[0] = cr * kR / col_scale + y_;
    o[1] = (y_ - (k2020[0] * o[0] + k2020[2] * o[2])) / k2020[1];   // 亮度逆推 G'（白仍是白）
    for (int k = 0; k < 3; k++) out[k] = pow(fmin(fmax(o[k], 0.0), 1.0), 2.4);   // saturate 后回线性
}
// 全链期望（扩张态，10 位 PQ 码）：8 位码 → γ2.2 解码 → 709→2020 矩阵 → present_itm × target/纸白 → PQ 编码（纸白 100）
static void itm_expect8(int r, int g, int b, double sdr, double target, double out[3]) {
    static const double m[3][3] = {{0.627404, 0.329283, 0.043313}, {0.069097, 0.919540, 0.011362}, {0.016391, 0.088013, 0.895595}};   // kRec709To2020 各行（shader 同一矩阵）
    double lin[3] = { sdr_dec(r / 255.0), sdr_dec(g / 255.0), sdr_dec(b / 255.0) };
    double l2[3], o[3];
    for (int k = 0; k < 3; k++) l2[k] = m[k][0] * lin[0] + m[k][1] * lin[1] + m[k][2] * lin[2];
    itm_ref(l2, sdr, target, o);
    for (int k = 0; k < 3; k++) out[k] = pq_code(o[k] * target);
}

// 改前 mode 2 单式对照着色器（冻结自基线 gal_present.m 的 mode 2 表达式与它用的 helper/矩阵——off 不变量的逐字节基准：
//   p.mode.z=p.mode.w=0 ⇒ 生产 pr_fs_hdr 守卫短路 ⇒ 与本式同一式；k_trivial_msl 对照直通的同款先例）
static const char *k_mode2_msl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VO { float4 p [[position]]; float2 uv; };\n"
    "vertex VO pr_vs(uint vid [[vertex_id]]) {\n"
    "  float2 uv = float2((vid << 1) & 2, vid & 2); VO o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct HP { float4 mode; float4 xf; };\n"
    "constant float3x3 kRec709To2020 = float3x3(float3(0.627404, 0.069097, 0.016391), float3(0.329283, 0.919540, 0.088013), float3(0.043313, 0.011362, 0.895595));\n"
    "static inline float3 present_sdr_to_linear(float3 c, float g) {\n"
    "    if (g > 0.0) return pow(max(c, float3(0.0)), float3(g));\n"
    "    float3 lo = c * (1.0 / 12.92);\n"
    "    float3 hi = pow((c + 0.055) * (1.0 / 1.055), float3(2.4));\n"
    "    return select(hi, lo, c <= 0.04045);\n"
    "}\n"
    "static inline float3 present_linear_to_pq(float3 l, float paper) {\n"
    "    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;\n"
    "    float3 ym = pow(max(l * (paper / 10000.0), float3(1e-30)), float3(m1));\n"
    "    return pow((c1 + c2 * ym) / (1.0 + c3 * ym), float3(m2));\n"
    "}\n"
    "fragment float4 pr_fs_cmp(VO in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant HP &p [[buffer(0)]]) {\n"
    "  float4 v = float4(t.sample(s, in.uv).rgb, 1.0);\n"
    "  return float4(present_linear_to_pq(kRec709To2020 * present_sdr_to_linear(v.rgb, p.xf.z), p.mode.y), 1.0); }\n";
static id<MTLRenderPipelineState> g_syn_pso_prod, g_syn_pso_cmp;
static id<MTLRenderPipelineState> syn_pso(int prod) {
    id<MTLRenderPipelineState> pso = prod ? g_syn_pso_prod : g_syn_pso_cmp;
    if (pso) return pso;
    NSError *e = nil;
    id<MTLLibrary> lib = prod ? [g_tdev newLibraryWithSource:k_present_msl options:nil error:&e]
                              : [g_tdev newLibraryWithSource:@(k_mode2_msl) options:nil error:&e];
    if (!lib) { printf("  %s 编不出：%s\n", prod ? "生产 gal 出图源（k_present_msl）" : "对照着色器（改前 mode 2 单式）", e.localizedDescription.UTF8String ?: "?"); return nil; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"pr_vs"];
    d.fragmentFunction = [lib newFunctionWithName:prod ? @"pr_fs_hdr" : @"pr_fs_cmp"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGB10A2Unorm;
    pso = [g_tdev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!pso) { printf("  合成驱动管线建不出：%s\n", e.localizedDescription.UTF8String ?: "?"); return nil; }
    if (prod) g_syn_pso_prod = pso; else g_syn_pso_cmp = pso;
    return pso;
}
static id<MTLTexture> syn_src(const uint8_t px[][3], int n) {   // n×1 BGRA8 源（内存字节 b,g,r,a——同 mk_bgra_src / tsrc 口径；px 按 RGB 给）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:n height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_tdev newTextureWithDescriptor:d]; uint8_t b[n * 4];
    for (int i = 0; i < n; i++) { b[4 * i] = px[i][2]; b[4 * i + 1] = px[i][1]; b[4 * i + 2] = px[i][0]; b[4 * i + 3] = 255; }
    [t replaceRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0 withBytes:b bytesPerRow:n * 4];
    return t;
}
static id<MTLTexture> syn_dst(int n) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:n height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [g_tdev newTextureWithDescriptor:d];
}
static id<MTLSamplerState> syn_samp(void) {
    static id<MTLSamplerState> s;
    if (!s) { MTLSamplerDescriptor *d = [MTLSamplerDescriptor new]; d.minFilter = d.magFilter = MTLSamplerMinMagFilterNearest; d.sAddressMode = d.tAddressMode = MTLSamplerAddressModeClampToEdge; s = [g_tdev newSamplerStateWithDescriptor:d]; }
    return s;
}
// 合成参数直驱：p[0..7] 进 constant HP（mode/xf 两组并一行）；pr_fs_hdr 采样同款 in.uv 全幅三顶点 + 最近邻 1:1 逐像素
static id<MTLTexture> syn_run(id<MTLTexture> src, id<MTLRenderPipelineState> pso, const float p[8]) {
    if (!pso) return nil;
    int n = (int)src.width;
    id<MTLTexture> dst = syn_dst(n);
    id<MTLCommandBuffer> cb = [g_tq commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso]; [e setFragmentTexture:src atIndex:0]; [e setFragmentSamplerState:syn_samp() atIndex:0];
    [e setFragmentBytes:p length:8 * sizeof(float) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("  扩张驱动命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return nil; }
    return dst;
}
static int syn_read(id<MTLTexture> t, uint32_t out[], int n) {   // RGB10A2 逐像素 32 位读回（10 位码 + alpha 位）
    [t getBytes:out bytesPerRow:(NSUInteger)n * 4 fromRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0];
    return 1;
}

// ---------- ⑦ PR #2080 评审第 1 轮（要改①）·独立判据（gal 副本，与 nvn 侧 ⑪ 同判据同样本）----------
//   ⑥ 的对拍期望由 itm_ref（present_itm 同一逆式的 CPU 转写）复算——只能证 GPU/CPU 算得一致、证不了公式本身对
//   （公式写错则两边一起错、单测照样绿）。本组期望 = 输入本身：BT.2446-1 §4.1 Method A 前向式（HDR→SDR，标准
//   正文给的方向）作用于 present_itm 的 GPU 输出应回到输入——前向式逐系数照标准印出值直写（Table 2 三段 EETF 与
//   ρ 式 + Table 3 色彩校正 + BT.2020 Y'CbCr→RGB），独立于被测逆式的任何一份。

// BT.2446-1 §4.1 Method A 前向 TMO（Table 2 + Table 3 逐系数照标准印出值直写；L_HDR = target / L_SDR = sdr 与
//   present_itm 参数对应）。入 lin：线性光（1.0 = target）；出 out：SDR R'G'B'（γ 域，1.0 = sdr）。黑（Y'=0 ⇒
//   R'=G'=B'=0）：f 的 0/0 不取、连续极限 = 黑（Table 4 的 SC「1 if Y'=0」同款口径）。
static void fwd_tmo(const double lin[3], double sdr, double target, double out[3]) {
    double rp = pow(fmax(lin[0], 0.0), 1.0 / 2.4), gp = pow(fmax(lin[1], 0.0), 1.0 / 2.4), bp = pow(fmax(lin[2], 0.0), 1.0 / 2.4);   // Table 2 非线性传输
    double y = 0.2627 * rp + 0.6780 * gp + 0.0593 * bp;   // Table 2 亮度
    double rho_hdr = 1.0 + 32.0 * pow(target / 10000.0, 1.0 / 2.4);
    double yp = log(1.0 + (rho_hdr - 1.0) * y) / log(rho_hdr);   // Table 2 步骤 1
    double yc;   // Table 2 步骤 2：三段 EETF（段界 0.7399 / 0.9909——两处交界两段式各自不连续，段 1/2 处差 5.46e-4、段 2/3 处 5.1e-6，标准原文）
    if (yp <= 0.7399) yc = 1.0770 * yp;
    else if (yp < 0.9909) yc = -1.1510 * yp * yp + 2.7811 * yp - 0.6302;
    else yc = 0.5 * yp + 0.5;
    double rho_sdr = 1.0 + 32.0 * pow(sdr / 10000.0, 1.0 / 2.4);
    double ysdr = (pow(rho_sdr, yc) - 1.0) / (rho_sdr - 1.0);   // Table 2 步骤 3
    if (y <= 0.0) { out[0] = out[1] = out[2] = 0.0; return; }   // 黑
    double f = ysdr / (1.1 * y);   // Table 3 色彩缩放
    double cb = f * (bp - y) / 1.8814, cr = f * (rp - y) / 1.4746;   // Table 3 色差
    double ytmo = ysdr - fmax(0.1 * cr, 0.0);   // Table 3 亮度调整
    out[0] = ytmo + 1.4746 * cr;   // BT.2020 Y'CbCr→RGB
    out[1] = ytmo - 0.16455 * cb - 0.57135 * cr;
    out[2] = ytmo + 1.8814 * cb;
}
// 段界缝内灰样本（⑦ 容差依据的直测点）：y_c 取段 1/2 交界两段式的中缝（f1(0.7399)=0.796872 与 f2(0.7399)=0.797419
//   之中点）——缝内 y_c 不在前向 EETF 的值域里，present_itm 的段界兜底分支带回段 1 一侧 ⇒ round-trip 偏差 = 缝宽
//   5.46e-4 经 ρ_SDR 归一（该点斜率 ≈1.48）放大 ≈8.1e-4（容差 1.5e-3 的主要构成）。构造全用前向侧公式。
static double itm_gap_lin(double sdr) {
    double lo = 1.0770 * 0.7399, hi = -1.1510 * 0.7399 * 0.7399 + 2.7811 * 0.7399 - 0.6302;   // f1(0.7399) / f2(0.7399)
    double yc = (lo + hi) * 0.5;
    double rho_sdr = 1.0 + 32.0 * pow(sdr / 10000.0, 1.0 / 2.4);
    double y_sdr = (pow(rho_sdr, yc) - 1.0) / (rho_sdr - 1.0);   // Table 2 步骤 3 逆取输入灰信号
    return pow(y_sdr, 2.4);   // 灰的线性 = γ 域信号 ^2.4
}
// gal_present.m 独立导出的 present_itm 文本（k_present_msl 拼进 pr_fs_hdr 的同一份；实现提交起导出——红态基线
//   无此符号，dlsym 取不到 ⇒ nil ⇒ ⑦ 显式红，可编译可跑；同 gal_present.m 跨层可选符号的按名取先例）
static NSString *itm_msl_text(void) {
    NSString *const *slot = (NSString *const *)dlsym(RTLD_DEFAULT, "k_present_itm_msl");
    return slot ? *slot : nil;
}
// ⑦ 探针着色器源：生产 present_itm 文本 + 线性直出 RGBA32F（不经生产 pr_fs_hdr 的 PQ 编码 10 位量化 ~1e-3 量级
//   噪声会淹没段界 6e-4 判据——直测 present_itm 本体）。16 字 buffer 布局同 syn_run：rect/edge + q.x=sdr、q.y=target。
static NSString *k_itm_probe_msl(NSString *itm_msl) {
    return [@("#include <metal_stdlib>\nusing namespace metal;\n"
        "struct VO { float4 p [[position]]; float2 uv; };\n"
        "vertex VO pr_vs(uint vid [[vertex_id]]) { float2 uv = float2((vid << 1) & 2, vid & 2); VO o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
        "struct IP { float4 rect; float4 edge; float4 q; float4 pad; };\n")
        stringByAppendingString:[itm_msl stringByAppendingString:
        @"fragment float4 pr_fs_itm(VO in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant IP& c [[buffer(0)]]) {\n"
        "  float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));\n"
        "  return float4(present_itm(v.rgb, c.q.x, c.q.y), 1.0);\n"
        "}\n"]];
}
// ⑦ 探针直驱：n×1 线性 float 输入（RGBA32F）→ 生产 present_itm 文本 → RGBA32F 线性读回（1.0 = target 域）
static int itm_probe(NSString *itm_msl, const float lin[][3], int n, double sdr, double target, double out[][3]) {
    static id<MTLRenderPipelineState> pso;
    if (!pso) {
        NSError *e = nil; id<MTLLibrary> lib = [g_tdev newLibraryWithSource:k_itm_probe_msl(itm_msl) options:nil error:&e];
        if (!lib) { printf("  探针着色器（present_itm 文本）编不出：%s\n", e.localizedDescription.UTF8String ?: "?"); return 0; }
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"pr_vs"]; d.fragmentFunction = [lib newFunctionWithName:@"pr_fs_itm"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        pso = [g_tdev newRenderPipelineStateWithDescriptor:d error:&e];
        if (!pso) { printf("  探针管线建不出：%s\n", e.localizedDescription.UTF8String ?: "?"); return 0; }
    }
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:n height:1 mipmapped:NO];
    sd.storageMode = MTLStorageModeShared; sd.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [g_tdev newTextureWithDescriptor:sd];
    { float *b = malloc((size_t)n * 4 * sizeof *b);
      for (int i = 0; i < n; i++) { b[4 * i] = lin[i][0]; b[4 * i + 1] = lin[i][1]; b[4 * i + 2] = lin[i][2]; b[4 * i + 3] = 1; }
      [src replaceRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0 withBytes:b bytesPerRow:(NSUInteger)n * 4 * sizeof *b]; free(b); }
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:n height:1 mipmapped:NO];
    dd.storageMode = MTLStorageModeShared; dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> dst = [g_tdev newTextureWithDescriptor:dd];
    id<MTLCommandBuffer> cb = [g_tq commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setFragmentTexture:src atIndex:0]; [en setFragmentSamplerState:syn_samp() atIndex:0];   // 最近邻（syn_samp 同款）：逐位读回
    float uv[16] = {0, 0, 1, 1, 0.5f / n, 0.5f, (n - 0.5f) / n, 0.5f, (float)sdr, (float)target, 0, 0, 0, 0};
    [en setFragmentBytes:uv length:sizeof uv atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("  探针命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return 0; }
    float *b = malloc((size_t)n * 4 * sizeof *b);
    [dst getBytes:b bytesPerRow:(NSUInteger)n * 4 * sizeof *b fromRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0];
    for (int i = 0; i < n; i++) { out[i][0] = b[4 * i]; out[i][1] = b[4 * i + 1]; out[i][2] = b[4 * i + 2]; }
    free(b);
    return 1;
}
// ⑦ round-trip 判据本体（同 nvn 侧 ⑪）：探针输出 → fwd_tmo（标准前向式）→ 应回到输入信号（γ 域）；容差 ITM_RT_TOL。
#define ITM_RT_TOL 1.5e-3   // 段界不连续（缝宽 5.46e-4 × ρ_SDR 斜率 1.48 ≈ 8.1e-4）+ 饱和色系数舍入 ~2e-6 + float32 噪声，余量 ≈1.85×
static int itm_rt_check(NSString *itm_msl, const float lin[][3], int n, double sdr, double target, double *maxerr, char *why, int whylen) {
    double (*out)[3] = malloc((size_t)n * sizeof *out);
    int ran = itm_probe(itm_msl, lin, n, sdr, target, out), bad = 0;
    *maxerr = 0.0;
    for (int i = 0; ran && i < n; i++) {
        double back[3];
        fwd_tmo(out[i], sdr, target, back);
        for (int k = 0; k < 3; k++) {
            double e = fabs(back[k] - pow((double)lin[i][k], 1.0 / 2.4));
            if (e > *maxerr) *maxerr = e;
            if (e > ITM_RT_TOL && !bad && whylen > 0) snprintf(why, whylen, "样本 %d 通道 %d：fwd→ %.6f 期望 %.6f（偏差 %.2e）", i, k, back[k], pow((double)lin[i][k], 1.0 / 2.4), e);
            if (e > ITM_RT_TOL) bad++;
        }
    }
    free(out);
    return ran && !bad;
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

    // ⑥ PR-A（#625 第二阶段）：SDR→HDR 扩张（BT.2446-1 §4.2 逆映射 present_itm；k_present_msl 的 mode 2 参数化——
    //    p.mode.z=sdr nits / p.mode.w=target nits，双零 = off）——合成参数直驱生产 gal 源（pr_fs_hdr，真着色器上 GPU），
    //    与 nvn 侧 t_present_hdr ⑩ 同一份期望（CPU 双精度参考复算 ±1）。红态（基线无扩张分支）对拍全红。
    {
        printf("· SDR→HDR 扩张：合成参数直驱生产 pr_fs_hdr（off 金标逐字节 / 端点 400/600/1000 / 段界 / 饱和色 / 非设计点 / 灰阶 256 码）\n");
        // off 金标（§5.1 用例 1，gal 副本）+ 守卫（用例 4）
        {
            uint8_t c8[8][3] = {{255,255,255},{199,199,199},{157,157,157},{128,128,128},{64,64,64},{16,16,16},{1,1,1},{0,0,0}};
            float poff[8] = {2, 100, 0, 0, 0, 0, 2.2f, 0};
            uint32_t w1[8], w2[8];
            id<MTLTexture> d_prod = syn_run(syn_src(c8, 8), syn_pso(1), poff);
            id<MTLTexture> d_cmp = syn_run(syn_src(c8, 8), syn_pso(0), poff);
            int ok = d_prod && d_cmp && syn_read(d_prod, w1, 8) && syn_read(d_cmp, w2, 8) && !memcmp(w1, w2, sizeof w1);
            CHECK(ok, "⑥ off 金标：p.mode.z=p.mode.w=0 的生产 pr_fs_hdr 与改前 mode 2 单式逐字节一致（off 不变量——gal 副本）");
            float peq[8] = {2, 100, 100, 100, 0, 0, 2.2f, 0};   // 守卫用例：p.mode.z=p.mode.w=100（target=sdr 形）
            id<MTLTexture> d_eq = syn_run(syn_src(c8, 8), syn_pso(1), peq);
            ok = d_eq && syn_read(d_eq, w2, 8) && !memcmp(w1, w2, sizeof w1);
            CHECK(ok, "⑥ 守卫：p.mode.z=p.mode.w=100（target=sdr）⇒ 守卫短路 ⇒ 与纯 mode 2 逐字节一致（gal 副本）");
        }
        // 端点 + 灰阶 256 码全扫（sdr=100/target=400）：CPU 双精度参考 ±1、单调允许段界微降
        {
            uint8_t ramp[256][3];
            for (int i = 0; i < 256; i++) ramp[i][0] = ramp[i][1] = ramp[i][2] = (uint8_t)i;
            float p400[8] = {2, 100, 100, 400, 0, 0, 2.2f, 0};
            id<MTLTexture> d = syn_run(syn_src(ramp, 256), syn_pso(1), p400);
            uint32_t *w = malloc(256 * sizeof *w);
            CHECK(d && syn_read(d, w, 256), "⑥ 扩张灰阶 256 码可跑（sdr=100/target=400）");
            int bad = 0, mono = 0;
            double e[3];
            for (int i = 0; i < 256; i++) {
                itm_expect8(i, i, i, 100.0, 400.0, e);
                double g = (double)(w[i] >> 10 & 0x3ff);
                if (fabs(g - e[1]) > 1.0) { bad++; if (bad == 1) printf("⑥ 首个不符：码 %d 出 %.1f（期望 %.1f）\n", i, g, e[1]); }
                if (i) mono += g < (double)(w[i - 1] >> 10 & 0x3ff) - 1.0;   // 单调：降 >1 LSB 记违例（段界微降 <1 LSB + float32 噪声被容）
            }
            CHECK(!bad, "⑥ 扩张灰阶 256 码对拍（sdr=100/target=400，±1：三段全分支——段 1 尾码 156 / 段 2 首码 157 与 199 / 段 3 首码 253 与 254/255）");
            CHECK(mono == 0, "⑥ 扩张灰阶 256 码单调（降 >1 LSB 违例 %d 处；段界不连续实测登记在档）", mono);
            CHECK(fabs((double)(w[255] >> 10 & 0x3ff) - pq_code(400.0)) <= 1.0 && (double)(w[0] & 0x3ff) <= 1.0,
                  "⑥ 端点：白 255 → target 400 精确（pq_code(400)=%.1f，±1）；黑 → 0", pq_code(400.0));
            CHECK((w[0] >> 30) == 3 && (w[255] >> 30) == 3, "⑥ 扩张态 alpha 写 1（RGB10A2 alpha 位 = 3）");
            free(w);
        }
        // 饱和色（红/绿/蓝/黄/青/品红）三通道对拍 ±1（保色调 col_scale 由同式参考锁定）
        {
            uint8_t c8[6][3] = {{255,0,0},{0,255,0},{0,0,255},{255,255,0},{0,255,255},{255,0,255}};
            float p400[8] = {2, 100, 100, 400, 0, 0, 2.2f, 0};
            id<MTLTexture> d = syn_run(syn_src(c8, 6), syn_pso(1), p400);
            uint32_t w[6];
            double e[3];
            CHECK(d && syn_read(d, w, 6), "⑥ 扩张饱和色可跑");
            int bad = 0;
            for (int i = 0; i < 6; i++) {
                itm_expect8(c8[i][0], c8[i][1], c8[i][2], 100.0, 400.0, e);
                for (int k = 0; k < 3; k++) {
                    double g = (double)(w[i] >> (10 * k) & 0x3ff);
                    if (fabs(g - e[k]) > 1.0) { bad++; if (bad == 1) printf("⑥ 首个不符：%d 号色通道 %d 出 %.1f（期望 %.1f）\n", i, k, g, e[k]); }
                }
            }
            CHECK(!bad, "⑥ 扩张饱和色（红/绿/蓝/黄/青/品红）三通道对拍 ±1（sdr=100/target=400）");
        }
        // 端点 600/1000：白→target 精确三点 + 段界样本重跑
        {
            uint8_t c8[8][3] = {{255,255,255},{0,0,0},{128,128,128},{156,156,156},{157,157,157},{252,252,252},{253,253,253},{199,199,199}};
            for (int ti = 0; ti < 2; ti++) {
                double t = ti ? 1000.0 : 600.0;
                float pt[8] = {2, 100, 100, (float)t, 0, 0, 2.2f, 0};
                id<MTLTexture> d = syn_run(syn_src(c8, 8), syn_pso(1), pt);
                uint32_t w[8];
                double e[3];
                CHECK(d && syn_read(d, w, 8), "⑥ 扩张端点可跑（target %.0f）", t);
                int bad = 0;
                for (int i = 0; i < 8; i++) {
                    int v = c8[i][0];
                    itm_expect8(v, v, v, 100.0, t, e);
                    for (int k = 0; k < 3; k++) if (fabs((double)(w[i] >> (10 * k) & 0x3ff) - e[k]) > 1.0) bad++;
                }
                CHECK(!bad && fabs((double)(w[0] >> 10 & 0x3ff) - pq_code(t)) <= 1.0 && (double)(w[1] & 0x3ff) <= 1.0,
                      "⑥ 端点（target %.0f）：白 → pq_code(%.0f)=%.1f 精确 ±1、黑 → 0、段界 156/157/252/253 与 199 全对拍", t, t, pq_code(t));
            }
        }
        // 非设计点参数组（sdr=203/target=600——通用解析式的意义所在，Table 4 路径在此无定义）
        {
            uint8_t c8[8][3] = {{255,255,255},{0,0,0},{1,1,1},{16,16,16},{128,128,128},{199,199,199},{252,252,252},{253,253,253}};
            float pt[8] = {2, 100, 203, 600, 0, 0, 2.2f, 0};
            id<MTLTexture> d = syn_run(syn_src(c8, 8), syn_pso(1), pt);
            uint32_t w[8];
            double e[3];
            CHECK(d && syn_read(d, w, 8), "⑥ 非设计点可跑（sdr=203/target=600）");
            int bad = 0;
            for (int i = 0; i < 8; i++) {
                int v = c8[i][0];
                itm_expect8(v, v, v, 203.0, 600.0, e);
                for (int k = 0; k < 3; k++) if (fabs((double)(w[i] >> (10 * k) & 0x3ff) - e[k]) > 1.0) bad++;
            }
            CHECK(!bad && fabs((double)(w[0] >> 10 & 0x3ff) - pq_code(600.0)) <= 1.0, "⑥ 非设计点对拍（sdr=203/target=600，±1；白 → 600 精确）");
        }
    }

    // ⑦ PR #2080 评审第 1 轮（要改①）·独立判据（gal 副本）：BT.2446-1 §4.1 Method A 前向式（HDR→SDR，标准正文给的方向
    //    ——fwd_tmo 逐系数照标准印出值直写）作用于 present_itm 的 GPU 输出，应回到输入。期望 = 输入本身（灰阶几档 +
    //    灰阶 256 码全扫 + 饱和色 + 两处段界与段界缝内样本），不经 present_itm / itm_ref 任何一份生成——⑥ 的对拍期望是
    //    同一逆式的 CPU 转写（itm_ref），只能证 GPU/CPU 算得一致、证不了公式本身对（公式写错则两边一起错、单测照样绿）。
    //    探针直调生产 present_itm 文本（gal_present.m 独立导出的 k_present_itm_msl）、RGBA32F 线性直出，不经 PQ 10 位量化。
    //    容差 1.5e-3 按三段 EETF 段界不连续定：段 1/2 交界（Y'p=0.7399 ↔ Y'c 0.7969）两段前向式相差 5.46e-4
    //    （0.796872 / 0.797419——标准原文的不连续，段 2/3 交界 0.9909 ↔ 0.9955 处仅 5.1e-6），经 ρ_SDR 归一（Table 2
    //    步骤 3 的逆，段界处斜率 ≈1.48）到输入信号域 ≈8.1e-4；段界外样本双精度 round-trip 偏差 <1e-15、饱和色 ~2e-6
    //    （标准印出系数对 present_itm 精确 BT.2020 系数的舍入差）、着色器 float32 噪声 ~1e-6 量级。
    {
        NSString *itm_msl = itm_msl_text();   // gal_present.m 独立导出的 present_itm 文本（红态基线无此导出 → nil）
        if (!itm_msl) {
            CHECK(0, "⑦ 独立判据：present_itm 文本不在位——PR-A 实现缺位（红态：探针无生产文本可编，前向式 round-trip 无从测起）");
        } else {
            char why[160];
            double err;
            // —— 灰阶几档（含两处段界两侧 156/157、252/253）+ 段界缝内样本：sdr=100/target=400（缺省组）与 100/1000（标准设计点）——
            const int grays[] = {0, 16, 64, 128, 156, 157, 199, 252, 253, 255};
            for (int ti = 0; ti < 2; ti++) {
                double t = ti ? 1000.0 : 400.0;
                float lin[11][3];
                double gap = itm_gap_lin(100.0);
                for (int i = 0; i < 10; i++) { double l = pow(grays[i] / 255.0, 2.2); lin[i][0] = lin[i][1] = lin[i][2] = (float)l; }   // 灰：γ2.2 解码（矩阵对灰 = 恒等）
                lin[10][0] = lin[10][1] = lin[10][2] = (float)gap;   // 段界缝内灰（构造见 itm_gap_lin——全前向侧公式）
                int ok = itm_rt_check(itm_msl, lin, 11, 100.0, t, &err, why, sizeof why);
                CHECK(ok, "⑦ 灰阶 round-trip（sdr=100/target=%.0f）：fwd_tmo(present_itm(x)) = x，容差 1.5e-3（实测最大 %.2e%s%s）",
                      t, err, ok ? "" : "；", ok ? "" : why);
            }
            // —— 灰阶 256 码全扫（sdr=100/target=400）：全灰域回输入 ——
            {
                static float lin[256][3];
                for (int i = 0; i < 256; i++) { double l = pow(i / 255.0, 2.2); lin[i][0] = lin[i][1] = lin[i][2] = (float)l; }
                int ok = itm_rt_check(itm_msl, lin, 256, 100.0, 400.0, &err, why, sizeof why);
                CHECK(ok, "⑦ 灰阶 256 码全扫 round-trip（sdr=100/target=400）：全灰域回到输入，容差 1.5e-3（实测最大 %.2e%s%s）",
                      err, ok ? "" : "；", ok ? "" : why);
            }
            // —— 饱和色几个（红/绿/蓝/黄/青/品红，BT.709 8 位全饱和 → γ2.2 解码 → 709→2020 矩阵——生产输入链同式）——
            {
                static const uint8_t sat[6][3] = {{255,0,0},{0,255,0},{0,0,255},{255,255,0},{0,255,255},{255,0,255}};
                static const double m[3][3] = {{0.627404, 0.329283, 0.043313}, {0.069097, 0.919540, 0.011362}, {0.016391, 0.088013, 0.895595}};   // kRec709To2020 各行（shader 同一矩阵）
                float lin[6][3];
                for (int i = 0; i < 6; i++) {
                    double l709[3] = { pow(sat[i][0] / 255.0, 2.2), pow(sat[i][1] / 255.0, 2.2), pow(sat[i][2] / 255.0, 2.2) };
                    for (int k = 0; k < 3; k++) lin[i][k] = (float)(m[k][0] * l709[0] + m[k][1] * l709[1] + m[k][2] * l709[2]);
                }
                int ok = itm_rt_check(itm_msl, lin, 6, 100.0, 400.0, &err, why, sizeof why);
                CHECK(ok, "⑦ 饱和色 round-trip（红/绿/蓝/黄/青/品红，sdr=100/target=400）：三通道回到输入，容差 1.5e-3（实测最大 %.2e%s%s）",
                      err, ok ? "" : "；", ok ? "" : why);
            }
        }
    }

    nxgal_window_set_layer(NULL);
    nxgal_tex_release(t_g); nxgal_tex_release(t_c);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
