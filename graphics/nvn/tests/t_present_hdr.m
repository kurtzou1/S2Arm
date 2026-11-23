// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// PR3b：present_mode 数学闭环 GPU 对拍（评审稿 v3 §2.4 模式矩阵 / §4 PR3b；形态照 nxnative #1176 的 t_present_hdr 适配本仓）。
//   生产 nvn_mtl.m 隔离编译进本单测（#include——真着色器上 GPU，present_encode 全链路）；前端替身按 t_nvn2 直调先例注入
//   （nvn2_hdr_snapshot_publish 合成快照 + nvn2_hdr_answer 同源答案入口直调 + setenv S2A_HDR，不照搬 nxnative 的 swforce 段）；
//   期望值 CPU 双精度复算（本文件自带 PQ / 肩部 / 矩阵参考式），容差 ±1 LSB（着色器 float32 对 CPU double 的固有差）。
//   ① off 不变量：S2A_HDR 缺省（vi 未答过）+ 8 位目标 ⇒ 平凡直通——与改前 trivial 采样着色器（本文件按改前源码原样编译的对照管线，
//      同一裁切 / 边缘钳制 / 采样器）逐字节一致：10 位源（含 512→128 的硬件换算）、8 位源、sRGB 源、float 源、alpha 透传。
//   ② 未答过的 10 位窗进 PQ 层目标：按 gamma SDR 解码、纸白 100 nit 编码（mode 2 语义——「vi 答过 HDR 才当 PQ 码值解码」的反面锁定）。
//   ③ mode 1（S3 兜底 + PR6 截图共用）：vi 答 on=1（S3 路径：S2A_HDR=on ∧ can 未持稳）后 HDR10 窗 → 8 位目标：
//      先 BT.2020→BT.709 矩阵（负值截断在矩阵后）→ 肩部压缩到 SDR 白 → 2.2 编码；灰阶逐档 + 橙色高光保色相（先压缩后转换会把
//      红绿比 6.9 压成 4.6——次序铁律锁定）+ 转换态 alpha 1。
//   ④ mode 2：8 位 SDR → PQ 层：SDR 白 255 = 纸白锚 100 nit、中灰 128 = 线性值、阴影按 2.2 解码不抬肩（码 16 = 2.2 下 sRGB 的约 1/2.3 光）、alpha 1。
//   ⑤ mode 3：float 线性 BT.709 → PQ 层：1.0 = 纸白、4.0 = 四倍、负值矩阵后才截断（scRGB 的广色域青保住其 BT.2020 值）；
//      ⑤b float 格式全集（RG11B10F 同走 mode 3——对齐 nxnative present_mode 的四款 float 源）。
//   ⑥ mode 0 PQ 直通：vi 答过后 HDR10 窗码值原样写 PQ 层（逐码相等——主路径，游戏已按 told peak 自 tone-map）。
//   ⑦ mode 4 滚降（无 metadata）：已告知 peak 在步进保持期（屏变暗、答案还没跟上）压过当前净空时——膝点下逐位直通、
//      肩部曲线（knee 300 / target 400 / 源峰 1580 = min(声明 1801, 已告知 1580)）、单调有界（≤ target+3 nit）、色相保持（各通道同缩放）、
//      三个门限（源峰 ≤ 1.05×target 不滚、knee > 0.9×target 不滚、已告知峰值追平净空后不滚）、缩放上屏与直通逐位一致。
//   ⑧ latch：答过 HDR 后回答转 SDR（S2A_HDR=off），present 仍按 PQ 解码游戏保持的 HDR10 窗（排空过渡帧的唯一不糊画面解法，nxnative 口径）；
//      游戏自降回 8 位窗后 off 恢复平凡直通。
//   ⑨ S2A_HDR_SDR_GAMMA=0（分段 sRGB 曲线，Q13 参数留可调）：mk 第二遍单独进程跑 mode 2 的 sRGB 期望（首遍缺省 2.2；
//      该开关读一次缓存，进程内不换——所以分进程）。
//   ⑩ PR-A（#625 第二阶段）：SDR→HDR 扩张（BT.2446-1 §4.2 逆映射 present_itm；mode 2 参数化 p[2]=sdr nits / p[3]=target nits，
//      双零 = off）：门全分支（engage/净空夹顶/target=sdr 不 engage/mode 1/4 金标）+ 合成参数直驱对拍（端点 400/600/1000 精确、
//      段界 156/157/252/253、饱和色、非设计点 sdr=203/target=600、负值防护、灰阶 256 码单调）+ off 金标（改前 mode 2 单式对照
//      逐字节 + 守卫短路逐字节 + 与生产链路逐字节）。红态（无实现）：门用例显式红 + 扩张对拍全红。
//   ⑪ PR #2080 评审第 1 轮（要改①）·独立判据：⑩ 的对拍期望由 itm_ref（present_itm 同一逆式的 CPU 转写）复算——只能证
//      GPU/CPU 算得一致、证不了公式本身对（公式写错则两边一起错、单测照样绿）。本组期望 = 输入本身：BT.2446-1 §4.1 Method A
//      前向式（HDR→SDR，标准正文给的方向——Table 2 三段 EETF 与 ρ 式 + Table 3 色彩校正 + BT.2020 Y'CbCr→RGB，逐系数照标准
//      印出值直写）作用于 present_itm 的 GPU 输出应回到输入。灰阶几档 + 灰阶 256 码全扫 + 饱和色 + 两处段界与段界缝内样本；
//      sdr=100/target=400（缺省）与 sdr=100/target=1000（标准设计点）两组；探针着色器直调生产 present_itm 文本
//      （K_PRESENT_ITM_MSL——与 src_msl 同一份），RGBA32F 线性直出（不经 PQ 10 位量化——其 ~1e-3 量级量化噪声会淹没
//      段界不连续判据）；容差 1.5e-3 按三段 EETF 段界不连续定（段 1/2 交界两段式差 5.46e-4 经 ρ_SDR 归一放大 ≈1.48 ⇒
//      输入信号域 ≈8.1e-4——见 ⑪ 注释）。红态（无实现）：探针无生产文本可编，显式红。
// PQ 层目标（RGB10A2）在 PR3b 阶段还没有真层（PR4 落地）：②④⑤⑥⑦ 的 RGB10A2 目标是单测直接建的——验的是转换数学与管线接线，
//   真机路径随 PR4/PR5 验收（§4 PR3b 的时点口径）。S3 真机路径同理：vi 门控接线是 PR5，本测经同源答案入口直调驱动。
#ifndef T_PRESENT_HDR_SOURCE
#define T_PRESENT_HDR_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include T_PRESENT_HDR_SOURCE
#include "../gfx/nvn/nvn_hdr_policy.h"   // PR3a 已合入的快照/答案入口声明（基线上 nvn_mtl.m 还不引它，测试自己引——红态也编得过）
#include <math.h>

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
// 改前 trivial 采样着色器（present_pipeline 旧源码原样）：off 不变量的对照管线——mode 0 与它逐字节一致
static const char *k_trivial_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct Crop { float4 rect; float4 edge; };\n"
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }\n";

// CPU 双精度参考式（nxnative t_present_hdr 同式）：ST 2084 码值 ↔ nit、SDR 2.2 解 / 编码、分段 sRGB、有理肩部
static double pq_code(double nits) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double y = pow(nits / 10000.0, m1);
    return pow((c1 + c2 * y) / (1 + c3 * y), m2) * 1023.0;
}
static double pq_nits(double code) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double e = pow(code / 1023.0, 1.0 / m2);
    return 10000.0 * pow(fmax(e - c1, 0) / (c2 - c3 * e), 1.0 / m1);
}
static double sdr_dec(double c) { return pow(c, 2.2); }                 // Q13 缺省口径（S2A_HDR_SDR_GAMMA 不设）
static double sdr_enc(double l) { return pow(l, 1.0 / 2.2); }
static double srgb_dec(double c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
static double shoulder(double m, double k, double t, double s) {        // present_shoulder 的双精度参考式
    if (!(m > k)) return m;
    double a = t - k, x = m - k; return fmin(k + x / (1 + x * (1 / a - 1 / fmax(s - k, a))), t);
}

#define N 8
static uint8_t t_src_alpha = 255;   // src8 的 alpha
static id<MTLTexture> src10(const unsigned c[N][3]) {   // N×1 RGB10A2 源：10 位码值 r/g/b、alpha 3（不透明）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint32_t w[N];
    for (int i = 0; i < N; i++) w[i] = c[i][0] | c[i][1] << 10 | c[i][2] << 20 | 3u << 30;
    [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:w bytesPerRow:sizeof w];
    return t;
}
static id<MTLTexture> src8(const uint8_t c[N][3], MTLPixelFormat pf) {   // N×1 8 位源（RGBA8 / RGBA8_sRGB：字节原样，sRGB 经非 sRGB 视图读）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint8_t b[N * 4];
    for (int i = 0; i < N; i++) { b[4 * i] = c[i][0]; b[4 * i + 1] = c[i][1]; b[4 * i + 2] = c[i][2]; b[4 * i + 3] = t_src_alpha; }
    [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:b bytesPerRow:sizeof b];
    return t;
}
static id<MTLTexture> src16f(const float c[N][3]) {   // N×1 RGBA16Float 源：线性光（float 窗）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; __fp16 h[N * 4];
    for (int i = 0; i < N; i++) { for (int k = 0; k < 3; k++) h[4 * i + k] = (__fp16)c[i][k]; h[4 * i + 3] = 1; }
    [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:h bytesPerRow:sizeof h];
    return t;
}
static double t_alpha[N];   // 上一次 run 的 alpha（0-1）
static id<MTLTexture> dst_tex(MTLPixelFormat fmt, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [g_dev newTextureWithDescriptor:d];
}
// 生产 present 全链路（present_encode → present_blit：模式化着色器 + UV 常量缓冲 p[0..7]）；out 取 RGB 0-1023（RGB10A2）或 0-255（8 位目标）
static int run(id<MTLTexture> src, MTLPixelFormat fmt, double out[N][3]) {
    id<MTLTexture> dst = dst_tex(fmt, N, 1); id<MTLCommandBuffer> cb = [g_q commandBuffer];
    if (!present_encode(cb, src, dst, NULL)) { printf("SETUP FAIL present_encode 返回 0（目标格式 %lu）\n", (unsigned long)fmt); return 0; }
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("SETUP FAIL 命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return 0; }
    if (fmt == MTLPixelFormatRGB10A2Unorm) {   // PQ 层目标：10 位码值
        uint32_t w[N]; [dst getBytes:w bytesPerRow:sizeof w fromRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0];
        for (int i = 0; i < N; i++) { for (int k = 0; k < 3; k++) out[i][k] = w[i] >> (10 * k) & 0x3ff; t_alpha[i] = (w[i] >> 30) / 3.0; }
    } else {   // 8 位目标
        uint8_t b[N * 4]; [dst getBytes:b bytesPerRow:sizeof b fromRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0];
        for (int i = 0; i < N; i++) { for (int k = 0; k < 3; k++) out[i][k] = b[4 * i + k]; t_alpha[i] = b[4 * i + 3] / 255.0; }
    }
    return 1;
}
// 改前 trivial 采样（对照管线）：同尺寸目标、同裁切 / 边缘钳制 / 采样器 / uv——off 不变量的逐字节基准
static id<MTLRenderPipelineState> trivial_pso(MTLPixelFormat fmt) {
    static id<MTLRenderPipelineState> ps[2]; int i = fmt == MTLPixelFormatRGB10A2Unorm;
    if (!ps[i]) {
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_trivial_msl) options:nil error:&e];
        if (!lib) { printf("SETUP FAIL 对照着色器编译：%s\n", e.localizedDescription.UTF8String); return nil; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = fmt;
        ps[i] = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!ps[i]) { printf("SETUP FAIL 对照管线：%s\n", e.localizedDescription.UTF8String); return nil; }
    }
    return ps[i];
}
static int trivial_run(id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLRenderPipelineState> pso = trivial_pso(dst.pixelFormat);
    if (!pso) return 0;
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setFragmentTexture:present_raw_src(src) atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0];
    float uv[8] = {0, 0, 1, 1, 0.5f / N, 0.5f, (N - 0.5f) / N, 0.5f};   // 与 present_blit 无裁切同尺寸的 uv 同值
    [en setFragmentBytes:uv length:sizeof uv atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}
static int bytes_equal(id<MTLTexture> a, id<MTLTexture> b) {   // 逐字节比（同格式同尺寸）
    NSUInteger w = a.width, h = a.height;
    size_t n = (size_t)w * h * 4; uint8_t *x = malloc(n), *y = malloc(n);   // 两目标都是 4 字节 / 像素
    [a getBytes:x bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    [b getBytes:y bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    int same = !memcmp(x, y, n); free(x); free(y); return same;
}
static int present_into(id<MTLTexture> src, id<MTLTexture> dst) {   // 生产 present 全链路画进给定目标并提交（①⑦⑧ 的逐字节对照用）
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    if (!present_encode(cb, src, dst, NULL)) { printf("SETUP FAIL present_encode 返回 0（目标格式 %lu）\n", (unsigned long)dst.pixelFormat); return 0; }
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("SETUP FAIL 命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return 0; }
    return 1;
}

// ---------- ⑩ PR-A（#625 第二阶段）：SDR→HDR 扩张（BT.2446-1 §4.2 逆映射 present_itm；mode 2 参数化 p[2]=sdr nits / p[3]=target nits）----------
//   生产链路的 p 由 nvn2_hdr_present 填（PR-A 期扩张双参恒 0,0——开关解析在 PR-B，设计稿 §2.4 填充落点），扩张用例以
//   合成参数直驱生产 fs（t_present_hdr 既有形态的合成版：直调纯函数 / 直驱着色器）；期望值 CPU 双精度复算 ±1 LSB（同 ①-⑨ 口径）。
//   红态（无 PR-A 实现）：门用例显式红（hdr_present_fill 扩张双参不在位）+ 扩张对拍全红（基线 mode 2 无扩张分支）。

// BT.2446-1 §4.2（Method A）逆色调映射 CPU 双精度参考（设计稿 §2.2 逐段转写——gamescope 通用解析式同式，libplacebo
//   前向段式交叉验证：4.604=4×1.1510、2.302=2×1.1510、4.83307641=2.7811²−4×1.1510×0.6302 逐系数对上）。
//   入：线性光（BT.2020 基色，1.0 = sdr_nits）；出：线性光（1.0 = target_nits）。
//   段界 0.7399/0.9909：标准自身段 1/2 交界有不连续（~6e-4）——期望按同式复算、不假设严格单调（设计稿 §2.2 实测登记）。
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
// 全链期望（扩张态，10 位 PQ 码）：线性 BT.709 光 → 709→2020 矩阵 → present_itm × target/纸白 → PQ 编码（纸白 100）
static void itm_expect_lin(const double lin709[3], double sdr, double target, double out[3]) {
    static const double m[3][3] = {{0.627404, 0.329283, 0.043313}, {0.069097, 0.919540, 0.011362}, {0.016391, 0.088013, 0.895595}};   // kRec709To2020 各行（shader 同一矩阵）
    double l2[3], o[3];
    for (int k = 0; k < 3; k++) l2[k] = m[k][0] * lin709[0] + m[k][1] * lin709[1] + m[k][2] * lin709[2];
    itm_ref(l2, sdr, target, o);
    for (int k = 0; k < 3; k++) out[k] = pq_code(o[k] * target);
}
static void itm_expect8(int r, int g, int b, double sdr, double target, double out[3]) {   // 8 位码 → γ2.2 解码后同链
    double lin[3] = { sdr_dec(r / 255.0), sdr_dec(g / 255.0), sdr_dec(b / 255.0) };
    itm_expect_lin(lin, sdr, target, out);
}

// 改前 mode 2 单式对照着色器（冻结自基线源码的 mode 2 表达式与它用的 helper/矩阵——off 不变量的逐字节基准：
//   p[2]=p[3]=0 ⇒ 生产 fs 守卫短路 ⇒ 与本式同一式；k_trivial_msl 对照 mode 0 的同款先例）
static const char *k_mode2_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct Crop { float4 rect; float4 edge; float4 mode; float4 xf; };\n"
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
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {\n"
    "    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));\n"
    "    return float4(present_linear_to_pq(kRec709To2020 * present_sdr_to_linear(v.rgb, c.xf.z), c.mode.y), 1.0);\n"
    "}\n";
static id<MTLRenderPipelineState> syn_pso_prod(void) {   // 生产库（真着色器上 GPU——同一段 fs，PR-A 的 present_itm 分支在内）
    static id<MTLRenderPipelineState> pso;
    if (!pso) {
        present_pso_init();   // g_present_vs / g_present_fs（①-⑧ 的生产链路已建过；显式再保一次）
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = g_present_vs; pd.fragmentFunction = g_present_fs;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGB10A2Unorm;
        NSError *e = nil;
        pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!pso) { printf("SETUP FAIL 扩张驱动管线（生产 fs）：%s\n", e.localizedDescription.UTF8String ?: "?"); return nil; }
    }
    return pso;
}
static id<MTLRenderPipelineState> syn_pso_mode2(void) {   // 改前 mode 2 单式对照管线
    static id<MTLRenderPipelineState> pso;
    if (!pso) {
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_mode2_msl) options:nil error:&e];
        if (!lib) { printf("SETUP FAIL 对照着色器（改前 mode 2 单式）编译：%s\n", e.localizedDescription.UTF8String ?: "?"); return nil; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGB10A2Unorm;
        pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!pso) { printf("SETUP FAIL 对照管线：%s\n", e.localizedDescription.UTF8String ?: "?"); return nil; }
    }
    return pso;
}
static id<MTLTexture> syn_src8(const uint8_t px[][3], int n, MTLPixelFormat pf) {   // n×1 8 位源（⑩ 灰阶/饱和色/段界样本）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:n height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint8_t b[n * 4];
    for (int i = 0; i < n; i++) { b[4 * i] = px[i][0]; b[4 * i + 1] = px[i][1]; b[4 * i + 2] = px[i][2]; b[4 * i + 3] = 255; }
    [t replaceRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0 withBytes:b bytesPerRow:n * 4];
    return t;
}
static id<MTLTexture> syn_render(id<MTLTexture> src, id<MTLRenderPipelineState> pso, const float p[8]) {   // 合成参数直驱：p[0..7] 进 uv[8..15]
    NSUInteger n = src.width;
    id<MTLTexture> dst = dst_tex(MTLPixelFormatRGB10A2Unorm, n, 1);
    if (!pso) return nil;
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setFragmentTexture:present_raw_src(src) atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0];
    float uv[16] = {0, 0, 1, 1, 0.5f / n, 0.5f, (n - 0.5f) / n, 0.5f, p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]};   // rect/edge 同 trivial_run 的 texel 心对齐
    [en setFragmentBytes:uv length:sizeof uv atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("SETUP FAIL 扩张驱动命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return nil; }
    return dst;
}
static int tex10(id<MTLTexture> t, double out[][3], double alpha[], int n) {   // RGB10A2 读回 10 位码（+alpha；t_alpha 全局只有 8 槽，不碰）
    uint32_t *w = malloc((size_t)n * sizeof *w);
    if (!w) return 0;
    [t getBytes:w bytesPerRow:(NSUInteger)n * sizeof *w fromRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0];
    for (int i = 0; i < n; i++) { for (int k = 0; k < 3; k++) out[i][k] = (double)(w[i] >> (10 * k) & 0x3ff); if (alpha) alpha[i] = (w[i] >> 30) / 3.0; }
    free(w);
    return 1;
}

#ifdef HDR_SDR_MAP_FILL   // ⑪ 探针与独立判据参考（PR #2080 评审第 1 轮）：present_itm 文本随实现提交进 nvn_mtl.m（K_PRESENT_ITM_MSL）——
                           // 红态无此宏：⑪ 走显式红分支，本段编译出局（探针 MSL 引用 K_PRESENT_ITM_MSL，编不过红态就没意义）
// ---------- ⑪ 独立判据参考：BT.2446-1 §4.1 Method A 前向 TMO（HDR→SDR）——Table 2 + Table 3 逐系数照标准印出值直写 ----------
//   独立于被测逆式：不用 present_itm / itm_ref 的任何一份（⑩ 的 itm_ref 是同一逆式的 CPU 转写，只能证 GPU/CPU 一致）。
//   L_HDR = target / L_SDR = sdr 与 present_itm 的参数对应（标准 §4.2 的 ITM 即本前向式的逐段代数逆——fwd 作用于
//   present_itm 的输出应回到输入，是公式正确性的独立判据）。系数用标准印出值：Y' = 0.2627R'+0.6780G'+0.0593B'、
//   EETF 1.0770 / −1.1510Y'p²+2.7811Y'p−0.6302 / 0.5Y'p+0.5（段界 0.7399/0.9909）、色彩校正 1.4746/1.8814/
//   f(Y'SDR)=Y'SDR/(1.1Y')、Y'TMO=Y'SDR−max(0.1C'r,0)、BT.2020 Y'CbCr→RGB（1.4746/0.16455/0.57135/1.8814，
//   BT.2446-1 Table 4 的 f⁻¹ 结构同系数）。标准印出 4 位值对 present_itm 精确 BT.2020 系数的舍入差 ~2e-6（远小于容差）。
//   入 lin：线性光（1.0 = target）；出 out：SDR R'G'B'（γ 域，1.0 = sdr）。黑（Y'=0 ⇒ R'=G'=B'=0）：f 的 0/0 不取，
//   连续极限 = 黑（Table 4 的 SC「1 if Y'=0」同款口径）。
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
// 段界缝内灰样本（⑪ 容差依据的直测点）：y_c 取段 1/2 交界两段式的中缝（f1(0.7399)=0.796872 与 f2(0.7399)=0.797419
//   之中点）——缝内的 y_c 不在前向 EETF 的值域里，present_itm 的段界兜底分支把它带回段 1 一侧 ⇒ round-trip 偏差 =
//   缝宽 5.46e-4 经 ρ_SDR 归一（Table 2 步骤 3 的逆变换，该点斜率 ≈1.48）放大 ≈8.1e-4——容差 1.5e-3 的主要构成。
//   构造全用前向侧公式（f1/f2 边界值 + Table 2 步骤 3 + γ 2.4），不经被测逆式。
static double itm_gap_lin(double sdr) {
    double lo = 1.0770 * 0.7399, hi = -1.1510 * 0.7399 * 0.7399 + 2.7811 * 0.7399 - 0.6302;   // f1(0.7399) / f2(0.7399)
    double yc = (lo + hi) * 0.5;
    double rho_sdr = 1.0 + 32.0 * pow(sdr / 10000.0, 1.0 / 2.4);
    double y_sdr = (pow(rho_sdr, yc) - 1.0) / (rho_sdr - 1.0);   // Table 2 步骤 3 逆取输入灰信号
    return pow(y_sdr, 2.4);   // 灰的线性 = γ 域信号 ^2.4
}
// ⑪ 探针着色器：生产 present_itm 文本（K_PRESENT_ITM_MSL——nvn_mtl.m 的 src_msl 同一份）+ 线性直出 RGBA32F。
//   不经生产 fs 的 mode 2 链（PQ 编码 10 位量化 ~1e-3 量级噪声会淹没段界 6e-4 判据）——直测 present_itm 本体。
static const char *k_itm_probe_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct IP { float4 rect; float4 edge; float4 q; float4 pad; };\n"   // 16 字布局同 syn_render 的 uv[16]：rect/edge + q.x=sdr、q.y=target
    K_PRESENT_ITM_MSL
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant IP& c [[buffer(0)]]) {\n"
    "    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));\n"
    "    return float4(present_itm(v.rgb, c.q.x, c.q.y), 1.0);\n"
    "}\n";
static id<MTLSamplerState> itm_probe_samp(void) {   // 最近邻（32 位 float 纹理的线性滤波在 Metal 无谓依赖设备档——探针只要逐位读回）
    static id<MTLSamplerState> s;
    if (!s) { MTLSamplerDescriptor *d = [MTLSamplerDescriptor new]; d.minFilter = d.magFilter = MTLSamplerMinMagFilterNearest; s = [g_dev newSamplerStateWithDescriptor:d]; }
    return s;
}
// ⑪ 探针直驱：n×1 线性 float 输入（RGBA32F）→ 生产 present_itm 文本 → RGBA32F 线性读回（1.0 = target 域）
static int itm_probe(const float lin[][3], int n, double sdr, double target, double out[][3]) {
    static id<MTLRenderPipelineState> pso;
    if (!pso) {
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_itm_probe_msl) options:nil error:&e];
        if (!lib) { printf("SETUP FAIL 探针着色器（present_itm 文本）编译：%s\n", e.localizedDescription.UTF8String ?: "?"); return 0; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!pso) { printf("SETUP FAIL 探针管线：%s\n", e.localizedDescription.UTF8String ?: "?"); return 0; }
    }
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:n height:1 mipmapped:NO];
    sd.storageMode = MTLStorageModeShared; sd.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [g_dev newTextureWithDescriptor:sd];
    { float *b = malloc((size_t)n * 4 * sizeof *b);
      for (int i = 0; i < n; i++) { b[4 * i] = lin[i][0]; b[4 * i + 1] = lin[i][1]; b[4 * i + 2] = lin[i][2]; b[4 * i + 3] = 1; }
      [src replaceRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0 withBytes:b bytesPerRow:(NSUInteger)n * 4 * sizeof *b]; free(b); }
    id<MTLTexture> dst = dst_tex(MTLPixelFormatRGBA32Float, n, 1);
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setFragmentTexture:src atIndex:0]; [en setFragmentSamplerState:itm_probe_samp() atIndex:0];
    float uv[16] = {0, 0, 1, 1, 0.5f / n, 0.5f, (n - 0.5f) / n, 0.5f, (float)sdr, (float)target, 0, 0, 0, 0};
    [en setFragmentBytes:uv length:sizeof uv atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("SETUP FAIL 探针命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return 0; }
    float *b = malloc((size_t)n * 4 * sizeof *b);
    [dst getBytes:b bytesPerRow:(NSUInteger)n * 4 * sizeof *b fromRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0];
    for (int i = 0; i < n; i++) { out[i][0] = b[4 * i]; out[i][1] = b[4 * i + 1]; out[i][2] = b[4 * i + 2]; }
    free(b);
    return 1;
}
// ⑪ round-trip 判据本体：探针输出 → fwd_tmo（标准前向式）→ 应回到输入信号（γ 域）；容差 ITM_RT_TOL。
//   lin/n_in 由调用方成对给（n_in = 纹理里 float 线性值的 ^(1/2.4)，双精度复算——期望不经被测逆式）。
#define ITM_RT_TOL 1.5e-3   // 段界不连续（缝宽 5.46e-4 × ρ_SDR 斜率 1.48 ≈ 8.1e-4）+ 饱和色系数舍入 ~2e-6 + float32 噪声，余量 ≈1.85×
static int itm_rt_check(const float lin[][3], int n, double sdr, double target, double *maxerr, char *why, int whylen) {
    double (*out)[3] = malloc((size_t)n * sizeof *out);
    int ran = itm_probe(lin, n, sdr, target, out), bad = 0;
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
#endif   // HDR_SDR_MAP_FILL（⑪ 探针与独立判据参考）

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    unsetenv("S2A_HDR"); if (!getenv("T_PRESENT_HDR_GAMMA0")) unsetenv("S2A_HDR_SDR_GAMMA");   // ⑨ 第二遍进程带着 S2A_HDR_SDR_GAMMA=0 起：别在这里清掉
    unsetenv("S2A_ANTI_ALIASING"); unsetenv("S2A_SCALING_FILTER"); unsetenv("S2A_CPATCH_ON");
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    mtl_init();
    if (getenv("T_PRESENT_HDR_GAMMA0")) {   // ⑨ 第二遍进程（mk 起的）：S2A_HDR_SDR_GAMMA=0 的分段 sRGB 曲线（读一次缓存，分进程才换得动）
        setenv("S2A_HDR", "on", 1);
        uint8_t c[N][3] = {{255, 255, 255}, {128, 128, 128}, {64, 64, 64}, {32, 32, 32}, {16, 16, 16}, {8, 8, 8}, {4, 4, 4}, {0, 0, 0}};
        double o[N][3]; int ran = run(src8(c, MTLPixelFormatRGBA8Unorm), MTLPixelFormatRGB10A2Unorm, o), bad = 0;
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][1] - pq_code(srgb_dec(c[i][1] / 255.0) * 100)) > 1.0;
        CHECK(ran && !bad, "⑨ SDR gamma=0：SDR 源按分段 sRGB 曲线解码（码 16 的光是 2.2 的 2.3 倍——抬肩可见）");
        return failures != 0;
    }
    double o[N][3];

    // ① off 不变量（latch 未置、8 位目标 = 现状全部真实路径）：与改前 trivial 采样逐字节一致
    {
        unsigned g[N][3]; for (int i = 0; i < N; i++) { unsigned code = (unsigned)(i * 146); g[i][0] = g[i][1] = g[i][2] = code; }   // 0..1022 扫一排
        id<MTLTexture> s10 = src10(g), d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1), d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s10, d1) && trivial_run(s10, d2) && bytes_equal(d1, d2),
              "① off：10 位源码值扫描 → 8 位目标 = 改前 trivial 采样逐字节一致（含 512→128 的纯格式换算）");
        uint8_t c[N][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}, {1, 2, 3}, {200, 100, 50}, {16, 16, 16}, {0, 0, 0}};
        t_src_alpha = 0; id<MTLTexture> s8 = src8(c, MTLPixelFormatRGBA8Unorm); t_src_alpha = 255;
        d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1); d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s8, d1) && trivial_run(s8, d2) && bytes_equal(d1, d2),
              "① off：8 位源（alpha 0）→ 8 位目标 = trivial 逐字节一致（alpha 原样透传）");
        id<MTLTexture> s8s = src8(c, MTLPixelFormatRGBA8Unorm_sRGB);
        d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1); d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s8s, d1) && trivial_run(s8s, d2) && bytes_equal(d1, d2),
              "① off：sRGB 源经非 sRGB 视图原样字节 → 8 位目标 = trivial 逐字节一致（scan-out 语义不变）");
        float f[N][3] = {{1, 1, 1}, {0.25f, 0.5f, 0.75f}, {4, 4, 4}, {0, 0, 0}, {-1, -1, -1}, {2, 1, 0}, {99, 0.01f, 0.5f}, {0.5f, 0.5f, 0.5f}};
        id<MTLTexture> sf = src16f(f);
        d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1); d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(sf, d1) && trivial_run(sf, d2) && bytes_equal(d1, d2),
              "① off：float 源 → 8 位目标 = trivial 逐字节一致（float 窗到 SDR 目标原样直通）");
        CHECK(run(src10(g), MTLPixelFormatRGBA8Unorm, o) && fabs(o[3][0] - lround(438 / 1023.0 * 255)) <= 1,   // 3×146 = 438
              "① off：10 位码 438 → 8 位 = 硬件换算 %d（期望 %d，±1）", (int)o[3][0], (int)lround(438 / 1023.0 * 255));
    }

    // ② 未答过的 10 位窗 → PQ 层目标：按 gamma SDR 解码、纸白 100 nit 编码（mode 2；答过才当 PQ 码值的反面）
    {
        unsigned g[N][3]; for (int i = 0; i < N; i++) { unsigned code = (unsigned)(i * 131 + 5); g[i][0] = g[i][1] = g[i][2] = code; }
        int ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o), bad = 0, at = -1;
        for (int i = 0; ran && i < N; i++) if (fabs(o[i][1] - pq_code(sdr_dec(g[i][1] / 1023.0) * 100)) > 1.0) { bad++; if (at < 0) at = i; }
        if (bad) printf("② 首个不符：码 %d 出 %d（期望 %.1f）\n", (int)g[at][1], (int)o[at][1], pq_code(sdr_dec(g[at][1] / 1023.0) * 100));
        CHECK(ran && !bad, "② 未答过：10 位窗进 PQ 层按 gamma SDR 解码、100 nit 编码（mode 2，不当 PQ 码值）");
        unsigned c512[N][3]; for (int i = 0; i < N; i++) c512[i][0] = c512[i][1] = c512[i][2] = 512;
        CHECK(run(src10(c512), MTLPixelFormatRGB10A2Unorm, o) && fabs(o[0][1] - pq_code(sdr_dec(512 / 1023.0) * 100)) <= 1.0,
              "② 未答过：10 位码 512 = 半灰 → %d（期望 pq(%.1f nit)±1）", (int)o[0][1], sdr_dec(512 / 1023.0) * 100);
    }

    // ③ mode 1（S3 兜底 + PR6 截图共用）：vi 答 on=1（S3 路径）后 HDR10 窗 → 8 位目标。
    //   声明范围（PR1 存储的 vi Set* 值）在本单测二进制里驱动不到：vi 注册表条目经 nvn2_vi_entry 取，ounce 判定
    //   （s2a_platform_ounce，宿主对象 svc_mem.o 的 NPDM 读数）在单测里恒 0——源峰的 min(声明, 已告知) 落已告知一侧验证
    //   （已告知 400 nit = 4 纸白），声明侧（min 取声明，DKB 声明低于告知的形态）随 PR5 元数据消费接线验收
    {
        setenv("S2A_HDR", "on", 1);
        hdr_snapshot pub = {.potential_edr = 2.0, .current_headroom = 4.0, .s1_ready = 0, .paper_white = 100};
        nvn2_hdr_snapshot_publish(&pub);   // can 未持稳 / s1_ready=0 → S3 强制路径
        hdr_decision d = nvn2_hdr_answer(1, 1000);
        CHECK(d.mode == HDR_S3 && d.vi_on == 1 && d.vi_fmt == 1 && d.vi_peak == 400, "③ 前端替身：S3 强制路径答 on=1 / fmt=1 / peak=400（headroom 4）");
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGBA8Unorm, o), bad = 0;
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][0] - 255.0 * sdr_enc(shoulder(pq_nits(g[i][0]) / 100.0, 0.75, 1, 4))) > 1.0;
        CHECK(ran && !bad && o[6][0] >= 254, "③ mode 1：灰阶沿肩部——暗部中灰照 SDR（≤75 nit），亮灰压进 SDR 白（源峰 400 nit 精确落白）");
        CHECK(ran && t_alpha[0] == 1.0 && t_alpha[N - 1] == 1.0, "③ mode 1：转换态 alpha 写 1");
        unsigned c[N][3]; for (int i = 0; i < N; i++) { c[i][0] = c[i][1] = c[i][2] = 400; }
        c[7][0] = (unsigned)lround(pq_code(1000)); c[7][1] = (unsigned)lround(pq_code(300)); c[7][2] = 0;   // 橙色高光：BT.2020 1000/300/0 nit
        ran = run(src10(c), MTLPixelFormatRGBA8Unorm, o);
        double v[3] = {pq_nits(c[7][0]) / 100.0, pq_nits(c[7][1]) / 100.0, 0}, m709[3];
        static const double m[3][3] = {{1.660491, -0.587641, -0.072850}, {-0.124550, 1.132900, -0.008349}, {-0.018151, -0.100579, 1.118730}};
        for (int k = 0; k < 3; k++) m709[k] = fmax(m[k][0] * v[0] + m[k][1] * v[1] + m[k][2] * v[2], 0);
        double mx = fmax(fmax(m709[0], m709[1]), m709[2]), fs = shoulder(mx, 0.75, 1, 4) / mx, e[3];
        for (int k = 0; k < 3; k++) e[k] = 255.0 * sdr_enc(fmin(m709[k] * fs, 1));
        double rg_lin = sdr_dec(o[7][0] / 255.0) / sdr_dec(o[7][1] / 255.0);
        CHECK(ran && fabs(o[7][0] - e[0]) <= 1.0 && fabs(o[7][1] - e[1]) <= 1.0 && fabs(o[7][2] - e[2]) <= 1.0 && fabs(rg_lin - m709[0] / m709[1]) < 0.4,
              "③ mode 1：橙色高光（BT.2020 1000/300/0）保色相——先矩阵后肩部（红绿线性比 %.2f，保持 %.2f；先压缩后转换会变 4.6）", rg_lin, m709[0] / m709[1]);
    }

    // ④ mode 2：8 位 SDR → PQ 层（纸白锚 100 nit；SDR 白 255 = 100 nit、黑 = 码 0、阴影 2.2 不抬肩）
    {
        uint8_t c[N][3] = {{255, 255, 255}, {128, 128, 128}, {64, 64, 64}, {32, 32, 32}, {16, 16, 16}, {8, 8, 8}, {4, 4, 4}, {0, 0, 0}};
        int ran = run(src8(c, MTLPixelFormatRGBA8Unorm), MTLPixelFormatRGB10A2Unorm, o), bad = 0;
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][1] - pq_code(sdr_dec(c[i][1] / 255.0) * 100)) > 1.0;
        CHECK(ran && !bad && fabs(o[0][1] - pq_code(100)) <= 1.0 && o[7][1] <= 1,
              "④ mode 2：SDR 白 255 = 纸白 100 nit、中灰 128 = 线性值、黑 = 码 0（各档 ±1）");
        CHECK(ran && !bad && o[4][1] < pq_code(srgb_dec(16 / 255.0) * 100) - 10,
              "④ mode 2：阴影（码 16）按 2.2 解码——不抬到分段 sRGB 的 2.3 倍光");
        t_src_alpha = 0; ran = run(src8(c, MTLPixelFormatRGBA8Unorm), MTLPixelFormatRGB10A2Unorm, o); t_src_alpha = 255;
        CHECK(ran && t_alpha[0] == 1.0 && t_alpha[N - 1] == 1.0, "④ mode 2：转换态 alpha 写 1（源 alpha 0 也写 1）");
    }

    // ⑤ mode 3：float 线性 BT.709 → PQ 层（1.0 = 纸白；负值矩阵后才截断——scRGB 广色域保真）
    {
        float f[N][3] = {{1, 1, 1}, {0.5f, 0.5f, 0.5f}, {4, 4, 4}, {0, 0, 0}, {-1, -1, -1}, {-0.05f, 1, 1}, {1, 1, 1}, {1, 1, 1}};
        int ran = run(src16f(f), MTLPixelFormatRGB10A2Unorm, o);
        CHECK(ran && fabs(o[0][1] - pq_code(100)) <= 1.0 && fabs(o[1][1] - pq_code(50)) <= 1.0 && fabs(o[2][1] - pq_code(400)) <= 1.0,
              "⑤ mode 3：float 源是线性光——1.0 = 纸白 100 nit、0.5 = 50、4.0 = 400（不当 sRGB 解码）");
        CHECK(ran && o[3][1] <= 1 && o[4][1] <= 1, "⑤ mode 3：0 与负 float 值 = 黑");
        CHECK(ran && fabs(o[5][0] - pq_code(0.34122 * 100)) <= 1.0,
              "⑤ mode 3：BT.709 外的负红（scRGB -0.05,1,1）在矩阵后才截断——红 = 34.1 nit（先截断会是 37.3）");
        CHECK(ran && t_alpha[5] == 1.0, "⑤ mode 3：转换态 alpha 写 1");
        // ⑤b mode 3 的 float 格式全集对齐（nxnative present_mode：RG11B10Float / RGB9E5Float 与 RGBA16/32Float 同为线性 BT.709 源——
        //    只认 16/32F 会让这两款窗进 PQ 层时被当未知格式原样直通，浮点字节被当 PQ 码值）。RG11B10F 源用硬编码浮点字
        //    （R/G 11 位：1.0 / 0.5 = 指数 15 / 14、尾数 0；B 10 位：4.0 = 指数 17、尾数 0——都是精确值），全排同一像素 → 矩阵 → PQ 层，期望 CPU 双精度复算
        {
            uint32_t words[N]; for (int i = 0; i < N; i++) words[i] = 960u | 896u << 11 | 544u << 22;   // (R,G,B) = (1, 0.5, 4)
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG11B10Float width:N height:1 mipmapped:NO];
            d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:words bytesPerRow:sizeof words];
            static const double m7[3][3] = {{0.627404, 0.329283, 0.043313}, {0.069097, 0.919540, 0.011362}, {0.016391, 0.088013, 0.895595}};   // kRec709To2020 各行（shader 同一矩阵）
            double lin[3] = {1, 0.5, 4}, e[3];
            for (int k = 0; k < 3; k++) e[k] = m7[k][0] * lin[0] + m7[k][1] * lin[1] + m7[k][2] * lin[2];
            int r2 = run(t, MTLPixelFormatRGB10A2Unorm, o);
            CHECK(r2 && fabs(o[0][0] - pq_code(e[0] * 100)) <= 1.0 && fabs(o[0][1] - pq_code(e[1] * 100)) <= 1.0 && fabs(o[0][2] - pq_code(e[2] * 100)) <= 1.0,
                  "⑤b mode 3：RG11B10Float 源按线性 BT.709 进矩阵 → PQ（%.1f / %.1f / %.1f nit，±1）——float 格式全集对齐 nxnative", e[0] * 100, e[1] * 100, e[2] * 100);
        }
    }

    // ⑥ mode 0 PQ 直通：vi 答过后 HDR10 窗码值原样写 PQ 层（主路径——游戏已按 told peak 自 tone-map）
    {
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o), same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == g[i][k];
        CHECK(ran && same, "⑥ mode 0：vi 答过 HDR 后，HDR10 窗码值原样直通 PQ 层（逐码相等）");
        CHECK(ran && t_alpha[0] == 1.0, "⑥ mode 0：直通态 alpha 原样（码值 3/3）");
    }

    // ⑦ mode 4 滚降（无 metadata；已告知 peak 在步进保持期压过变暗的屏——PR3b 唯一真实触发形态，PR5 步进接线后常态）
    {
        hdr_snapshot pub = {.potential_edr = 16.0, .current_headroom = 16.0, .s1_ready = 0, .paper_white = 100};
        nvn2_hdr_snapshot_publish(&pub);
        nvn2_hdr_answer(1, 2000);   // 候选 1580 出带 → 等 1s 持稳（答案与已告知 peak 都还 400）
        hdr_decision d = nvn2_hdr_answer(1, 3100);
        CHECK(d.vi_on == 1 && d.vi_peak == 1580, "⑦ 前端替身：headroom 16 持稳后已告知 peak = 1580 nit");
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o), same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == g[i][k];
        CHECK(ran && same, "⑦ 门限①：headroom 16（target 1600）下源峰 1580 ≤ 1.05×target → 不滚降，码值原样");
        pub.current_headroom = 4.0; nvn2_hdr_snapshot_publish(&pub);   // 屏变暗：净空 400，已告知 peak 1580 还在保持期
        const double rn[N] = {100, 203, 300, 350, 400, 1580, 10000, 10000};   // 第 5 位 = 源峰本身（已告知 1580）：肩部把它精确落在 target 上
        unsigned r[N][3]; for (int i = 0; i < N; i++) r[i][0] = r[i][1] = r[i][2] = (unsigned)lround(pq_code(rn[i]));
        ran = run(src10(r), MTLPixelFormatRGB10A2Unorm, o);
        int under = 1, mono = 1, curve = 0;
        for (int i = 0; ran && i < 2; i++) for (int k = 0; k < 3; k++) under &= o[i][k] == r[i][k];
        for (int i = 0; ran && i < N; i++) { if (i) mono &= o[i][1] >= o[i - 1][1]; under &= pq_nits(o[i][1]) <= 403; }
        for (int i = 2; ran && i < 6; i++) curve += fabs(o[i][1] - pq_code(shoulder(rn[i], 300, 400, 1580))) <= 1.0;
        CHECK(ran && under, "⑦ 滚降：膝点（300 nit）以下码值逐位原样；以上有界（≤ target+3 nit）");
        CHECK(ran && mono && curve == 4, "⑦ 滚降：300/350/400/1580 nit 在肩部曲线上（knee 300 / target 400 / 源峰 1580 精确落 target，±1）且单调");
        CHECK(ran && fabs(pq_nits(o[5][1]) - 400) < 4, "⑦ 滚降：源峰 1580 nit 落在 target 400 nit 上（±4）");
        unsigned col[N][3]; for (int i = 0; i < N; i++) { col[i][0] = (unsigned)lround(pq_code(1000)); col[i][1] = (unsigned)lround(pq_code(500)); col[i][2] = (unsigned)lround(pq_code(100)); }
        ran = run(src10(col), MTLPixelFormatRGB10A2Unorm, o);
        double rr = pq_nits(o[0][0]), gg = pq_nits(o[0][1]), bb = pq_nits(o[0][2]);
        CHECK(ran && rr <= 403 && fabs(gg / rr - 0.5) < 0.03 && fabs(bb / rr - 0.1) < 0.01, "⑦ 滚降：色（1000/500/100 nit）各通道同缩放保色相");
        {   // 缩放上屏（膝点以下整排）：滚降态（已告知 1580 还在保持期）先跑，直通态（追平后）后跑——滚降不碰采样路径
            const double lo[N] = {0.1, 10, 80, 120, 203, 250, 280, 290};
            unsigned lw[N][3]; for (int i = 0; i < N; i++) lw[i][0] = lw[i][1] = lw[i][2] = (unsigned)lround(pq_code(lo[i]));
            id<MTLTexture> s = src10(lw), d1 = dst_tex(MTLPixelFormatRGB10A2Unorm, 13, 1);
            CHECK(present_into(s, d1), "⑦ 滚降：膝点以下的缩放上屏（13×1 目标）可跑");
            nvn2_hdr_answer(1, 4200);   // 候选 400 出带 → 等持稳
            d = nvn2_hdr_answer(1, 5300);
            CHECK(d.vi_on == 1 && d.vi_peak == 400, "⑦ 前端替身：已告知 peak 追平净空（400 @ headroom 4）");
            id<MTLTexture> d2 = dst_tex(MTLPixelFormatRGB10A2Unorm, 13, 1);
            CHECK(present_into(s, d2) && bytes_equal(d1, d2), "⑦ 滚降：膝点以下的缩放上屏与直通逐位一致（滚降不碰采样）");
        }
        ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o); same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == g[i][k];
        CHECK(ran && same, "⑦ 门限②：已告知追平后源峰 400 ≤ 1.05×target 420 → 不滚降，码值原样");
        pub.current_headroom = 1.05; nvn2_hdr_snapshot_publish(&pub);   // 净空 105：膝点 100 > 0.9×105 → 白上没余量，不硬滚
        ran = run(src10(r), MTLPixelFormatRGB10A2Unorm, o); same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == r[i][k];
        CHECK(ran && same, "⑦ 门限③：knee 100 > 0.9×target 105 → 不滚降（让屏去截断，不硬滚）");
        pub.current_headroom = 4.0; nvn2_hdr_snapshot_publish(&pub);
    }

    // ⑧ latch：答过 HDR 后回答转 SDR（off），present 仍按 PQ 解码游戏保持的 HDR10 窗；游戏自降回 8 位窗后 off 恢复平凡直通
    {
        setenv("S2A_HDR", "off", 1);
        hdr_decision d = nvn2_hdr_answer(1, 6000);
        CHECK(d.mode == HDR_S0 && d.vi_on == 0 && d.vi_fmt == 0 && d.vi_peak == 0, "⑧ 前端替身：off 后回答转 SDR（on=0 / fmt=0 / peak=0）");
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGBA8Unorm, o), bad = 0;   // 源峰 = min(声明 1801, 已告知 400) = 400 → s = 4（与 ③ 同参）
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][0] - 255.0 * sdr_enc(shoulder(pq_nits(g[i][0]) / 100.0, 0.75, 1, 4))) > 1.0;
        CHECK(ran && !bad, "⑧ latch：off 后 HDR10 窗仍按 PQ 解码（mode 1）——排空过渡帧不糊画面（已告知 400、源峰 400 同 ③）");
        uint8_t c[N][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}, {1, 2, 3}, {200, 100, 50}, {16, 16, 16}, {0, 0, 0}};
        id<MTLTexture> s8 = src8(c, MTLPixelFormatRGBA8Unorm), d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1), d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s8, d1) && trivial_run(s8, d2) && bytes_equal(d1, d2),
              "⑧ off：游戏自降回 8 位窗后恢复平凡直通（与改前 trivial 逐字节一致）");
        unsetenv("S2A_HDR");
    }

    // ⑩ PR-A（#625 第二阶段）：SDR→HDR 扩张（BT.2446-1 §4.2 逆映射 present_itm；mode 2 参数化 p[2]=sdr nits / p[3]=target nits）。
    //    门全分支（§5.1 用例 2，t_nvn2 V4 段范式——合成参数直调纯函数）+ 合成参数直驱对拍（用例 3/4：端点/段界/饱和色/
    //    非设计点/负值防护/灰阶 256 码单调）+ off 金标（用例 1：改前 mode 2 单式对照逐字节 + 守卫短路逐字节 + 与生产链路逐字节）。
    {
        // —— 门全分支：hdr_present_fill 的扩张双参（sdr/target nits，§2.4 填充落点）——
#ifdef HDR_SDR_MAP_FILL   // PR-A 实现在位标记（nvn_hdr_policy.h 同版定义；红态无此宏 → 门用例显式红：三态流 test-only / negctl 保持可编译可跑）
        float p[8];
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 4.0, 0, 0, 2.2, 0.0, 0.0);
        CHECK(p[0] == 2.0f && p[1] == 100.0f && p[2] == 0.0f && p[3] == 0.0f && p[6] == 2.2f && p[4] == 0.0f && p[5] == 0.0f && p[7] == 0.0f,
              "⑩ 门：S4 关（0,0）⇒ 纯 mode 2（p[2]=p[3]=0，p 布局照旧）");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 0.0, 0, 0, 2.2, 100.0, 400.0);
        CHECK(p[2] == 0.0f && p[3] == 0.0f, "⑩ 门：headroom 0（无净空读数）⇒ 不扩张");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, NAN, 0, 0, 2.2, 100.0, 400.0);
        CHECK(p[2] == 0.0f && p[3] == 0.0f, "⑩ 门：headroom NaN ⇒ 不扩张（mode 4 门同款口径）");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 1.2, 0, 0, 2.2, 100.0, 400.0);
        CHECK(p[2] == 0.0f && p[3] == 0.0f, "⑩ 门：headroom 1.2（ceiling 120 < 地板 125）⇒ 不扩张");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 1.0, 0, 0, 2.2, 100.0, 400.0);
        CHECK(p[2] == 0.0f && p[3] == 0.0f, "⑩ 门：headroom 1.0（ceiling 100 ≤ max(sdr, 地板)）⇒ 不扩张");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 1.5, 0, 0, 2.2, 203.0, 400.0);
        CHECK(p[2] == 0.0f && p[3] == 0.0f, "⑩ 门：ceiling 150 ≤ sdr 203（sdr 调高时地板随之上移）⇒ 不扩张");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 1.3, 0, 0, 2.2, 100.0, 400.0);
        CHECK(p[2] == 100.0f && p[3] == 130.0f, "⑩ 门：headroom 1.3 ⇒ engage（p[2]=100、p[3]=ceiling 130——净空夹顶）");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 4.0, 0, 0, 2.2, 100.0, 1000.0);
        CHECK(p[2] == 100.0f && p[3] == 400.0f, "⑩ 门：设置 1000 > ceiling 400 ⇒ p[3]=400（净空物理上限约束）");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 10.0, 0, 0, 2.2, 100.0, 600.0);
        CHECK(p[2] == 100.0f && p[3] == 600.0f, "⑩ 门：engage ⇒ p[2]=sdr 100、p[3]=effective target 600");
        hdr_present_fill(p, HDR_PF_SDR8, HDR_PT_PQ10, 0, 10.0, 0, 0, 2.2, 100.0, 100.0);
        CHECK(p[2] == 0.0f && p[3] == 0.0f, "⑩ 门：target=sdr ⇒ 不 engage（严格大于：target ≤ sdr 会压暗/重塑，§2.2 实测）");
        hdr_present_fill(p, HDR_PF_HDR10, HDR_PT_SDR8, 1, 4.0, 1801, 400, 2.2, 100.0, 400.0);
        CHECK(p[0] == 1.0f && p[2] == 0.75f && p[3] == 1.0f && p[4] == 4.0f && p[6] == 2.2f,
              "⑩ 门：mode 1 的 p[2]/p[3]（0.75/1 纸白倍数）不受扩张参数影响（各自分支金标）");
        hdr_present_fill(p, HDR_PF_HDR10, HDR_PT_PQ10, 1, 4.0, 1801, 1580, 2.2, 100.0, 600.0);
        CHECK(p[0] == 4.0f && p[2] == 300.0f && p[3] == 400.0f && p[4] == 1580.0f,
              "⑩ 门：mode 4 滚降的 p[2]/p[3]（knee 300 / target 400 nit）不受扩张参数影响（各自分支金标）");
#else
        CHECK(0, "⑩ 门：hdr_present_fill 扩张双参（sdr/target nits）不在位——PR-A 实现缺位（红态；基线 fill 8 参，p[2]=p[3] 恒 0）");
#endif

        // —— off 金标（用例 1）+ 守卫（用例 4）：合成参数直驱生产 fs ——
        {
            uint8_t c8[8][3] = {{255,255,255},{199,199,199},{157,157,157},{128,128,128},{64,64,64},{16,16,16},{1,1,1},{0,0,0}};
            float poff[8] = {2, 100, 0, 0, 0, 0, 2.2f, 0};   // off：p[2]=p[3]=0（生产链路缺省同参）
            id<MTLTexture> s = syn_src8(c8, 8, MTLPixelFormatRGBA8Unorm);
            id<MTLTexture> d_prod = syn_render(s, syn_pso_prod(), poff), d_cmp = syn_render(s, syn_pso_mode2(), poff);
            if (d_prod && d_cmp && !bytes_equal(d_prod, d_cmp)) {   // 调试转储：逐像素差
                uint32_t x[8], y2[8];
                [d_prod getBytes:x bytesPerRow:sizeof x fromRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0];
                [d_cmp getBytes:y2 bytesPerRow:sizeof y2 fromRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0];
                for (int i = 0; i < 8; i++) if (x[i] != y2[i]) printf("⑩ off 金标差：像素 %d 生 %08x 期 %08x\n", i, x[i], y2[i]);
            }
            CHECK(d_prod && d_cmp && bytes_equal(d_prod, d_cmp),
                  "⑩ off 金标：p[2]=p[3]=0 的生产 fs 与改前 mode 2 单式逐字节一致（off 不变量）");
            float peq[8] = {2, 100, 100, 100, 0, 0, 2.2f, 0};   // 守卫用例：p[2]=p[3]=100（相等、>0——target=sdr 形）
            id<MTLTexture> d_eq = syn_render(s, syn_pso_prod(), peq);
            CHECK(d_eq && bytes_equal(d_prod, d_eq),
                  "⑩ 守卫：p[2]=p[3]=100（target=sdr）⇒ 着色器守卫 p[3] > p[2] 短路 ⇒ 与纯 mode 2 逐字节一致");
            id<MTLTexture> d_chain = dst_tex(MTLPixelFormatRGB10A2Unorm, 8, 1);
            CHECK(present_into(s, d_chain) && bytes_equal(d_prod, d_chain),
                  "⑩ 驱动器：合成参数 0,0 直驱与生产链路（present_encode → nvn2_hdr_present 取参）逐字节一致");
        }

        // —— 端点 + 灰阶 256 码全扫（用例 3/4）：CPU 双精度参考 ±1、单调允许段界微降 ——
        {
            uint8_t ramp[256][3];
            for (int i = 0; i < 256; i++) ramp[i][0] = ramp[i][1] = ramp[i][2] = (uint8_t)i;
            float p400[8] = {2, 100, 100, 400, 0, 0, 2.2f, 0};
            id<MTLTexture> d = syn_render(syn_src8(ramp, 256, MTLPixelFormatRGBA8Unorm), syn_pso_prod(), p400);
            double (*o2)[3] = malloc(sizeof(double[256][3])), al[256], e[3];
            CHECK(d && tex10(d, o2, al, 256), "⑩ 扩张灰阶 256 码可跑（sdr=100/target=400）");
            int bad = 0, mono = 0;
            for (int i = 0; i < 256; i++) {
                itm_expect8(i, i, i, 100.0, 400.0, e);
                if (fabs(o2[i][1] - e[1]) > 1.0) { bad++; if (bad == 1) printf("⑩ 首个不符：码 %d 出 %.1f（期望 %.1f）\n", i, o2[i][1], e[1]); }
                if (i) mono += o2[i][1] < o2[i - 1][1] - 1.0;   // 单调：降 >1 LSB 记违例（段界微降 <1 LSB + float32 噪声被容；期望按同式复算、不假设严格单调）
            }
            CHECK(!bad, "⑩ 扩张灰阶 256 码对拍（sdr=100/target=400，±1：三段全分支——段 1 尾码 156 / 段 2 首码 157 与 199 / 段 3 首码 253 与 254/255）");
            CHECK(mono == 0, "⑩ 扩张灰阶 256 码单调（降 >1 LSB 违例 %d 处；段界不连续实测登记在档）", mono);
            CHECK(fabs(o2[255][1] - pq_code(400.0)) <= 1.0 && o2[0][1] <= 1.0,
                  "⑩ 端点：白 255 → target 400 精确（pq_code(400)=%.1f，±1）；黑 → 0", pq_code(400.0));
            CHECK(al[0] == 1.0 && al[255] == 1.0, "⑩ 扩张态 alpha 写 1（转换态 alpha 语义不变）");
            free(o2);
        }

        // —— 饱和色（用例 3）：纯红/绿/蓝/黄/青/品红三通道对拍 ±1（保色调 col_scale 由同式参考锁定）——
        {
            uint8_t c8[6][3] = {{255,0,0},{0,255,0},{0,0,255},{255,255,0},{0,255,255},{255,0,255}};
            float p400[8] = {2, 100, 100, 400, 0, 0, 2.2f, 0};
            id<MTLTexture> d = syn_render(syn_src8(c8, 6, MTLPixelFormatRGBA8Unorm), syn_pso_prod(), p400);
            double o3[6][3], e[3];
            CHECK(d && tex10(d, o3, NULL, 6), "⑩ 扩张饱和色可跑");
            int bad = 0;
            for (int i = 0; i < 6; i++) {
                itm_expect8(c8[i][0], c8[i][1], c8[i][2], 100.0, 400.0, e);
                for (int k = 0; k < 3; k++) if (fabs(o3[i][k] - e[k]) > 1.0) { bad++; if (bad == 1) printf("⑩ 首个不符：%d 号色通道 %d 出 %.1f（期望 %.1f）\n", i, k, o3[i][k], e[k]); }
            }
            CHECK(!bad, "⑩ 扩张饱和色（红/绿/蓝/黄/青/品红）三通道对拍 ±1（sdr=100/target=400）");
        }

        // —— 端点 600/1000（用例 3：白→target 精确三点）+ 段界样本重跑 ——
        {
            uint8_t c8[8][3] = {{255,255,255},{0,0,0},{128,128,128},{156,156,156},{157,157,157},{252,252,252},{253,253,253},{199,199,199}};
            for (int ti = 0; ti < 2; ti++) {
                double t = ti ? 1000.0 : 600.0;
                float pt[8] = {2, 100, 100, (float)t, 0, 0, 2.2f, 0};
                id<MTLTexture> d = syn_render(syn_src8(c8, 8, MTLPixelFormatRGBA8Unorm), syn_pso_prod(), pt);
                double o4[8][3], e[3];
                CHECK(d && tex10(d, o4, NULL, 8), "⑩ 扩张端点可跑（target %.0f）", t);
                int bad = 0;
                for (int i = 0; i < 8; i++) {
                    int v = c8[i][0];
                    itm_expect8(v, v, v, 100.0, t, e);
                    for (int k = 0; k < 3; k++) if (fabs(o4[i][k] - e[k]) > 1.0) bad++;
                }
                CHECK(!bad && fabs(o4[0][1] - pq_code(t)) <= 1.0 && o4[1][1] <= 1.0,
                      "⑩ 端点（target %.0f）：白 → pq_code(%.0f)=%.1f 精确 ±1、黑 → 0、段界 156/157/252/253 与 199 全对拍", t, t, pq_code(t));
            }
        }

        // —— 非设计点参数组（用例 3：sdr=203/target=600——通用解析式的意义所在，Table 4 路径在此无定义）——
        {
            uint8_t c8[8][3] = {{255,255,255},{0,0,0},{1,1,1},{16,16,16},{128,128,128},{199,199,199},{252,252,252},{253,253,253}};
            float pt[8] = {2, 100, 203, 600, 0, 0, 2.2f, 0};   // p[2]=sdr 203 / p[3]=target 600
            id<MTLTexture> d = syn_render(syn_src8(c8, 8, MTLPixelFormatRGBA8Unorm), syn_pso_prod(), pt);
            double o5[8][3], e[3];
            CHECK(d && tex10(d, o5, NULL, 8), "⑩ 非设计点可跑（sdr=203/target=600）");
            int bad = 0;
            for (int i = 0; i < 8; i++) {
                int v = c8[i][0];
                itm_expect8(v, v, v, 203.0, 600.0, e);
                for (int k = 0; k < 3; k++) if (fabs(o5[i][k] - e[k]) > 1.0) bad++;
            }
            CHECK(!bad && fabs(o5[0][1] - pq_code(600.0)) <= 1.0, "⑩ 非设计点对拍（sdr=203/target=600，±1；白 → 600 精确）");
        }
        // —— 负值输入防护（用例 3：max(n,0) 与 saturate——float 源负通道解码钳 0 → 恰黑 col_scale 兜底 → 黑；超白样本 saturate 有界）——
        {
            float f[8][3] = {{1,1,1},{-1,-1,-1},{0,0,0},{-0.05f,1,1},{-1,0.5f,0},{-3,2,0.25f},{2,1,0.5f},{1,1,1}};
            float p400[8] = {2, 100, 100, 400, 0, 0, 2.2f, 0};
            id<MTLTexture> d = syn_render(src16f(f), syn_pso_prod(), p400);
            double o6[8][3], e[3];
            CHECK(d && tex10(d, o6, NULL, 8), "⑩ 负值/超白输入可跑（float 源，扩张态）");
            int bad = 0;
            for (int i = 0; i < 8; i++) {
                double lin[3] = { pow(fmax(f[i][0], 0.0), 2.2), pow(fmax(f[i][1], 0.0), 2.2), pow(fmax(f[i][2], 0.0), 2.2) };
                itm_expect_lin(lin, 100.0, 400.0, e);
                for (int k = 0; k < 3; k++) if (fabs(o6[i][k] - e[k]) > 1.0) bad++;
            }
            CHECK(!bad && o6[1][0] <= 1.0 && o6[1][1] <= 1.0 && o6[1][2] <= 1.0,
                  "⑩ 负值防护：负通道 → 黑（≤1 码——max(n,0) 路径）、恰黑无 NaN（col_scale 兜底）、超白样本 saturate 有界对拍");
        }
    }

    // ⑪ PR #2080 评审第 1 轮（要改①）·独立判据：BT.2446-1 §4.1 Method A 前向式（HDR→SDR，标准正文给的方向——
    //    fwd_tmo 逐系数照标准印出值直写）作用于 present_itm 的 GPU 输出，应回到输入。期望 = 输入本身（灰阶几档 +
    //    灰阶 256 码全扫 + 饱和色 + 两处段界与段界缝内样本），不经 present_itm / itm_ref 任何一份生成——⑩ 的对拍
    //    期望是同一逆式的 CPU 转写（itm_ref），只能证 GPU/CPU 算得一致、证不了公式本身对（公式写错则两边一起错、
    //    单测照样绿）。探针（上方 itm_probe）直调生产 present_itm 文本、RGBA32F 线性直出，不经 PQ 10 位量化。
    //    容差 1.5e-3 按三段 EETF 段界不连续定：段 1/2 交界（Y'p=0.7399 ↔ Y'c 0.7969）两段前向式相差 5.46e-4
    //    （0.796872 / 0.797419——标准原文的不连续，段 2/3 交界 0.9909 ↔ 0.9955 处仅 5.1e-6），经 ρ_SDR 归一
    //    （Table 2 步骤 3 的逆，段界处斜率 ≈1.48）到输入信号域 ≈8.1e-4；段界外样本双精度 round-trip 偏差 <1e-15、
    //    饱和色 ~2e-6（标准印出系数对 present_itm 精确 BT.2020 系数的舍入差）、着色器 float32 噪声 ~1e-6 量级。
#ifdef HDR_SDR_MAP_FILL
    {
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
            int rt = itm_rt_check(lin, 11, 100.0, t, &err, why, sizeof why);   // 变量名避开 CHECK 宏内的局部 ok（宏体自带 int ok=!!(c)，同名会被遮蔽）
            CHECK(rt, "⑪ 灰阶 round-trip（sdr=100/target=%.0f）：fwd_tmo(present_itm(x)) = x，容差 1.5e-3（实测最大 %.2e%s%s）",
                  t, err, rt ? "" : "；", rt ? "" : why);
        }
        // —— 灰阶 256 码全扫（sdr=100/target=400）：全灰域回输入 ——
        {
            static float lin[256][3];
            for (int i = 0; i < 256; i++) { double l = pow(i / 255.0, 2.2); lin[i][0] = lin[i][1] = lin[i][2] = (float)l; }
            int rt = itm_rt_check(lin, 256, 100.0, 400.0, &err, why, sizeof why);
            CHECK(rt, "⑪ 灰阶 256 码全扫 round-trip（sdr=100/target=400）：全灰域回到输入，容差 1.5e-3（实测最大 %.2e%s%s）",
                  err, rt ? "" : "；", rt ? "" : why);
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
            int rt = itm_rt_check(lin, 6, 100.0, 400.0, &err, why, sizeof why);
            CHECK(rt, "⑪ 饱和色 round-trip（红/绿/蓝/黄/青/品红，sdr=100/target=400）：三通道回到输入，容差 1.5e-3（实测最大 %.2e%s%s）",
                  err, rt ? "" : "；", rt ? "" : why);
        }
    }
#else
    CHECK(0, "⑪ 独立判据：present_itm 不在位——PR-A 实现缺位（红态：探针无生产文本可编，前向式 round-trip 无从测起）");
#endif

    printf("%s t_present_hdr：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
