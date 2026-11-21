// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// PR6：截图/判定/录像走与 present 相同的 mode 1 副本（评审稿 v3 §4 PR6 / §3 A9、B8 行；模式数学与闭环基建复用 PR3b）。
//   生产 nvn_mtl.m 隔离编译进本单测（#include——grab_present / shot / 满屏判据族全链路，真 Metal 设备）；前端替身按 t_present_hdr 先例注入
//   （nvn2_hdr_snapshot_publish 合成快照 + nvn2_hdr_answer 同源答案入口直调 + setenv S2A_HDR）；期望值 CPU 双精度复算
//   （本文件自带 PQ / 肩部 / 矩阵参考式，照抄 t_present_hdr），容差 ±1 LSB（着色器 float32 对 CPU double 的固有差）。
//   ① off：8 位窗的 grab（判定/录像与 grab 同一份字节）= 平凡直通字节（BGRA 序、alpha 透传）逐字节一致——PR6 零回归锁。
//   ② 前端替身：S3 强制路径答 on=1 / fmt=1 / peak=400（headroom 4）——latch 置位（vi 答过），同 t_present_hdr ③。
//   ③ HDR10 窗的 grab = mode 1 副本：先 BT.2020→BT.709 矩阵（负值截断在矩阵后）再肩部压缩到 SDR 白、2.2 编码——灰阶逐档 ±1 +
//      橙色高光保色相（先压缩后转换红绿比 6.9→4.6 的反面锁定）+ 转换态 alpha 写 1。录像（宿主侧整帧消费）与自动玩家截图同走这份字节。
//   ④ fit_judge 在 PQ 源上无误报：64×9 的 PQ 源（左 1/4 是 20 nit 暗场、其余 10000 nit 高光）经 grab 的 mode 1 副本判 → 内容判据 0 红
//      （mode 1 副本里 20 nit = 123/255，带外 255——369/765 不算暗带）；同一画面的平凡直通字节（无转换时的形态：20 nit = 91/255，
//      273/765 < 0.4×765）判 → 「暗带」红（连续两次、st[1] 置位）——转换是判据不误报的前提；再判 mode 1 副本 → 恢复 0 红。
//   ⑤ 截图（shot，DM_NVN_SHOT / shot 队列同一条路）：未答过的 10 位窗 / float 窗 / vi 答过的 HDR10 窗都经 present 同一离屏编码出 PNG
//      （前两者平凡直通、后者 mode 1 副本）——本 PR 的实现点（基线上 shot 对非 8 位窗红失败、不出文件）；8 位窗（off 态 / on+latch 态）
//      照旧逐字节（off 不变量：非 8 位才进新分支）。倒影层已随上游移除（§3 B7），无相关项；nxnative 三产物形态（SDR PNG + rgb10a2 raw +
//      10 位 HEIC PQ）列 PR8+，本测不含。
//   ⑥ DM_NVN_SHOT_OUT（第二遍进程，mk 起）：显式尺寸照旧优先——HDR 源出 64×9 PNG = present_encode 同一参考字节（该分支先于本 PR 已在，
//      锁本 PR 合并不动它）。
#ifndef T_PRESENT_SHOTS_SOURCE
#define T_PRESENT_SHOTS_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include T_PRESENT_SHOTS_SOURCE
#include "../gfx/nvn/nvn_hdr_policy.h"   // PR3a/PR3b 已合入的快照/答案/模式声明（本测直调替身）
#include <dispatch/dispatch.h>
#include <math.h>
#include <sched.h>
#include <unistd.h>

static unsigned checks, failures;
// 内部变量名不带 ok：调用处常见 `CHECK(ok, ...)` 传名 ok 的局部——宏体里的 `int ok = !!(c)` 会按声明遮蔽读到自己未初始化的值
#define CHECK(c, ...) do { checks++; int pass_=!!(c); failures+=!pass_; printf("%s ",pass_?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// CPU 双精度参考式（照抄 t_present_hdr，与生产着色器同式）：ST 2084 码值 ↔ nit、SDR 2.2 编码、有理肩部
static double pq_code(double nits) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double y = pow(nits / 10000.0, m1);
    return pow((c1 + c2 * y) / (1 + c3 * y), m2) * 1023.0;
}
static double pq_nits(double code) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double e = pow(code / 1023.0, 1.0 / m2);
    return 10000.0 * pow(fmax(e - c1, 0.0) / (c2 - c3 * e), 1.0 / m1);
}
static double sdr_enc(double l) { return pow(l, 1.0 / 2.2); }
static double shoulder(double m, double k, double t, double s) {
    if (!(m > k)) return m;
    double a = t - k, x = m - k; return fmin(k + x / (1 + x * (1 / a - 1 / fmax(s - k, a))), t);
}
// mode 1（S3 兜底 + 本 PR 截图共用）CPU 期望：先矩阵（负值截断在矩阵后）再肩部压缩、2.2 编码；vi 答过 peak=400 → 源峰 s = 4（纸白倍数）
static void mode1(const double nits[3], double out[3]) {
    static const double m[3][3] = {{1.660491, -0.587641, -0.072850}, {-0.124550, 1.132900, -0.008349}, {-0.018151, -0.100579, 1.118730}};   // kRec2020To709 各行（shader 同一矩阵）
    double v[3], m709[3];
    for (int k = 0; k < 3; k++) v[k] = pq_nits(pq_code(nits[k])) / 100.0;   // 10 位码值往返（源就是按码值存的）
    for (int k = 0; k < 3; k++) m709[k] = fmax(m[k][0] * v[0] + m[k][1] * v[1] + m[k][2] * v[2], 0);
    double mx = fmax(fmax(m709[0], m709[1]), m709[2]), fs = mx > 0.75 ? shoulder(mx, 0.75, 1, 4) / mx : 1.0;   // 着色器 present_shoulder：max ≤ 膝点时原样返回（n 不缩放），没有除法——纯黑（mx=0）除 0 会 NaN
    for (int k = 0; k < 3; k++) out[k] = 255.0 * sdr_enc(fmin(m709[k] * fs, 1));
}

static id<MTLTexture> dst_tex(MTLPixelFormat fmt, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [g_dev newTextureWithDescriptor:d];
}
// W×H 的 10 位源：每像素 10 位码值（r=g=b=pq_code(nits)，灰场）；alpha 3（不透明）
static id<MTLTexture> src10_gray(const double *nits, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint32_t *px = malloc(w * h * 4);
    for (NSUInteger i = 0; i < w * h; i++) { uint32_t c = (uint32_t)lround(pq_code(nits[i])); px[i] = c | c << 10 | c << 20 | 3u << 30; }
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4]; free(px);
    return t;
}
// 8×2 的 10 位源：第 0 行灰阶（nits[0..7]）、第 1 行彩色（nits_col 每像素 3 通道）；闭环对拍用
static id<MTLTexture> src10_rows(const double nits[8], const double nits_col[8][3]) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:8 height:2 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint32_t px[16];
    for (int i = 0; i < 8; i++) { uint32_t c = (uint32_t)lround(pq_code(nits[i])); px[i] = c | c << 10 | c << 20 | 3u << 30; }
    for (int i = 0; i < 8; i++) { px[8 + i] = 3u << 30; for (int k = 0; k < 3; k++) px[8 + i] |= (uint32_t)lround(pq_code(nits_col[i][k])) << (10 * k); }
    [t replaceRegion:MTLRegionMake2D(0, 0, 8, 2) mipmapLevel:0 withBytes:px bytesPerRow:8 * 4];   // 一行 8 像素 = 32 字节（不能给 sizeof px：那是两行的量）
    return t;
}
static id<MTLTexture> src8(const uint8_t c[8][4]) {   // 8×1 的 RGBA8 源（alpha 透传锁用）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint8_t b[32];
    for (int i = 0; i < 8; i++) { b[4 * i] = c[i][0]; b[4 * i + 1] = c[i][1]; b[4 * i + 2] = c[i][2]; b[4 * i + 3] = c[i][3]; }
    [t replaceRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0 withBytes:b bytesPerRow:sizeof b];
    return t;
}
static id<MTLTexture> src16f(const float c[8][3]) {   // 8×1 的 RGBA16Float 源（线性光，float 窗）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:8 height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; __fp16 h[32];
    for (int i = 0; i < 8; i++) { for (int k = 0; k < 3; k++) h[4 * i + k] = (__fp16)c[i][k]; h[4 * i + 3] = 1; }
    [t replaceRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0 withBytes:h bytesPerRow:sizeof h];
    return t;
}
// 改前 trivial 采样着色器（照抄 t_present_hdr 的对照管线：同裁切 / 边缘钳制 / 采样器）——非 8 位窗「无转换时」的字节形态参考
static const char *k_trivial_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct Crop { float4 rect; float4 edge; };\n"
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }\n";
static id<MTLRenderPipelineState> t_trivial_pso(MTLPixelFormat fmt) {
    static id<MTLRenderPipelineState> p;
    if (!p) {
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_trivial_msl) options:nil error:&e];
        if (!lib) { printf("SETUP FAIL 对照着色器编译：%s\n", e.localizedDescription.UTF8String); return nil; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = fmt;
        p = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!p) { printf("SETUP FAIL 对照管线：%s\n", e.localizedDescription.UTF8String); return nil; }
    }
    return p;
}
static int t_trivial(id<MTLTexture> src, id<MTLTexture> dst) {   // 改前 trivial 采样画进目标并提交（返回 1 = 成）
    id<MTLRenderPipelineState> pso = t_trivial_pso(dst.pixelFormat);
    if (!pso) return 0;
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setFragmentTexture:present_raw_src(src) atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0];
    float uv[8] = {0, 0, 1, 1, 0.5f / dst.width, 0.5f / dst.height, (dst.width - 0.5f) / dst.width, (dst.height - 0.5f) / dst.height};   // 与 present_blit 无裁切同尺寸的 uv 同值
    [en setFragmentBytes:uv length:sizeof uv atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}
static uint8_t *tex_bytes(id<MTLTexture> t) {   // 整张读回（4 字节 / 像素）
    uint8_t *b = malloc(t.width * t.height * 4);
    [t getBytes:b bytesPerRow:t.width * 4 fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
    return b;
}
// grab 副本取一张（真实路径：mtl_grab_next_present 预约 + grab_present 直调，无窗口局同一条路）；字节 / 令牌进 g_*（回调里字节只在调用内有效：拷一次）
static uint8_t *g_grab; static size_t g_grab_w, g_grab_h, g_grab_row; static uint64_t g_tok;
static int grab_once(id<MTLTexture> src, NSUInteger w, NSUInteger h) {
    while (mtl_grab_inflight()) sched_yield();
    static dispatch_semaphore_t got; static int got_init; if (!got_init++) got = dispatch_semaphore_create(0);
    g_grab_w = g_grab_h = 0; g_tok = 0;
    mtl_grab_next_present(^(const uint8_t *b, size_t bw, size_t bh, size_t brow) {
        if (b) { g_grab = realloc(g_grab, brow * bh); if (g_grab) { memcpy(g_grab, b, brow * bh); g_grab_w = bw; g_grab_h = bh; g_grab_row = brow; g_tok = mtl_grab_fit_token(); } }
        dispatch_semaphore_signal(got);
    });
    grab_present(src, NULL, CGSizeMake(w, h), 1);
    if (dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) return 0;
    while (mtl_grab_inflight()) sched_yield();
    return g_grab && g_grab_w == w && g_grab_h == h && g_grab_row == w * 4;
}
// PNG → RGBA（透明度固定 255，照抄 t_nvn_rscale 的读回）；返回 1 = 读到
static int png_read(const char *path, uint8_t *rgba, size_t cap, size_t *w, size_t *h) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageSourceRef src = url ? CGImageSourceCreateWithURL(url, NULL) : NULL; CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL; int ok = 0;
    if (img) { *w = CGImageGetWidth(img); *h = CGImageGetHeight(img);
        if (*w * *h * 4 <= cap) { CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef c = CGBitmapContextCreate(rgba, *w, *h, 8, *w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
            if (c) { CGContextSetBlendMode(c, kCGBlendModeCopy); CGContextDrawImage(c, CGRectMake(0, 0, *w, *h), img); CGContextRelease(c); ok = 1; for (size_t i = 0; i < *w * *h; i++) rgba[4 * i + 3] = 255; }
            CGColorSpaceRelease(cs); } }
    if (img) CGImageRelease(img); if (src) CFRelease(src); if (url) CFRelease(url);
    return ok;
}
static char *png_new(void) {   // 新的临时 PNG 路径（/tmp；mkstemp 只认结尾 XXXXXX，后缀拼出来）
    static char base[] = "/tmp/t_present_shots_XXXXXX";
    int fd = mkstemp(base);
    if (fd < 0) return NULL;
    close(fd); unlink(base);
    char *p = malloc(sizeof base + 8); snprintf(p, sizeof base + 8, "%s.png", base); return p;
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    // 环境收口：本测自管 S2A_HDR / 截图与上屏诊断开关，别吃外面带进来的。DM_NVN_SHOT_OUT 例外：
    //   第二遍进程（mk 起，T_PRESENT_SHOTS_SHOTOUT=1）正是带它进来测它的显式尺寸优先——那一遍留着
    int shotout = getenv("T_PRESENT_SHOTS_SHOTOUT") != NULL;
    unsetenv("S2A_HDR"); unsetenv("S2A_HDR_SDR_GAMMA"); unsetenv("S2A_HDR_PEAK");
    unsetenv("S2A_ANTI_ALIASING"); unsetenv("S2A_SCALING_FILTER"); unsetenv("S2A_CPATCH_ON"); unsetenv("S2A_RES_SCALE");
    if (!shotout) unsetenv("DM_NVN_SHOT_OUT");
    unsetenv("DM_NVN_SHOT"); unsetenv("DM_NVN_TEXDUMP"); unsetenv("DM_NVN_TEXSNAP"); unsetenv("DM_NVN_REGLUM");
    unsetenv("DM_NVN_DEFER_AB"); unsetenv("DM_NVN_UDC_AB"); unsetenv("S2A_WIDEN_NARROW"); unsetenv("S2A_FRAME_REC"); unsetenv("S2A_FRAME_REC_RED");
    // 满屏判据红帧 PNG 的落点圈进临时目录（s2a_docs_path 缺省进 $HOME/Documents；t_nvn_m3 同款）：别把测试残留写进真机文档目录
    char docs[] = "/tmp/t_present_shots_docs.XXXXXX"; if (mkdtemp(docs)) setenv("S2A_DOCS", docs, 1);
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    mtl_init();
    present_pipeline(MTLPixelFormatBGRA8Unorm);   // g_blit_samp 就绪（t_trivial 与生产同款采样器）

    // ⑥（第二遍进程）：DM_NVN_SHOT_OUT 显式尺寸照旧优先——HDR 源出 64×9 PNG = present_encode 同一参考字节
    if (getenv("T_PRESENT_SHOTS_SHOTOUT")) {
        setenv("S2A_HDR", "on", 1);
        hdr_snapshot pub = {.potential_edr = 2.0, .current_headroom = 4.0, .s1_ready = 0, .paper_white = 100};
        nvn2_hdr_snapshot_publish(&pub);   // can 未持稳 / s1_ready=0 → S3 强制路径（同下 ②）
        nvn2_hdr_answer(1, 1000);
        double fn[64 * 9];
        for (NSUInteger x = 0; x < 64; x++) for (NSUInteger y = 0; y < 9; y++) fn[y * 64 + x] = x < 16 ? 20.0 : 10000.0;   // 左 1/4 暗场、其余高光（同 ④ 的源）
        id<MTLTexture> s = src10_gray(fn, 64, 9), ref = dst_tex(MTLPixelFormatBGRA8Unorm, 64, 9);
        id<MTLCommandBuffer> cb = [g_q commandBuffer];
        int ran = present_encode(cb, s, ref, NULL); [cb commit]; [cb waitUntilCompleted];
        uint8_t *rb = ran && cb.status == MTLCommandBufferStatusCompleted ? tex_bytes(ref) : NULL;
        char *path = png_new(); int ok = 0;
        if (path) { shot(s, path, 1, NULL); uint8_t png[64 * 9 * 4]; size_t w = 0, h = 0;
            if (png_read(path, png, sizeof png, &w, &h)) { unlink(path); ok = w == 64 && h == 9;
                for (NSUInteger i = 0; ok && i < 64 * 9; i++) {   // 参考是 BGRA、PNG 读回 RGBA：同像素比 RGB
                    if (png[4 * i] != rb[4 * i + 2] || png[4 * i + 1] != rb[4 * i + 1] || png[4 * i + 2] != rb[4 * i]) ok = 0; } }
            else ok = 0; free(path); }
        CHECK(rb && ok, "⑥ DM_NVN_SHOT_OUT=64x9：显式尺寸照旧优先——HDR 源出 64×9 PNG = present_encode 同一参考字节（该分支先于本 PR 已在，锁定合并不动它）");
        printf("%s t_present_shots：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
        return failures != 0;
    }

    // ---------- off 态（vi 未答过）：非 8 位窗走 present 同一平凡直通副本；8 位窗照旧 ----------
    // ① 8 位窗 grab（判定/录像同一份字节）：平凡直通、BGRA 序、alpha 透传——逐字节一致（零回归锁）
    {
        uint8_t c[8][4] = {{255, 0, 0, 0}, {0, 255, 0, 64}, {0, 0, 255, 255}, {255, 255, 255, 255}, {1, 2, 3, 7}, {200, 100, 50, 128}, {16, 16, 16, 192}, {0, 0, 0, 255}};
        int ran = grab_once(src8(c), 8, 1), same = 0;
        for (int i = 0; ran && i < 8; i++)   // grab 出 BGRA（B,G,R,A 顺序）：平凡直通 = 源 RGBA 换序、alpha 原样
            same += g_grab[4 * i] == c[i][2] && g_grab[4 * i + 1] == c[i][1] && g_grab[4 * i + 2] == c[i][0] && g_grab[4 * i + 3] == c[i][3];
        CHECK(ran && same == 8, "① off：8 位窗的 grab = 平凡直通字节（BGRA 序、alpha 透传）逐字节一致（判定/录像与 grab 同一份字节）");
    }
    // ⑤a 8 位窗截图（off 态）：read == src 照旧——PNG 逐字节 = 源字节（零回归锁，本 PR 不动 8 位路径）
    {
        uint8_t c[8][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}, {1, 2, 3, 255}, {200, 100, 50, 255}, {16, 16, 16, 255}, {0, 0, 0, 255}};
        char *path = png_new(); int ok = 0; uint8_t png[8 * 4]; size_t w = 0, h = 0;
        if (path) { shot(src8(c), path, 1, NULL);
            if (png_read(path, png, sizeof png, &w, &h)) { unlink(path); ok = w == 8 && h == 1;
                for (int i = 0; ok && i < 8; i++) if (png[4 * i] != c[i][0] || png[4 * i + 1] != c[i][1] || png[4 * i + 2] != c[i][2]) ok = 0; }
            else ok = 0; free(path); }
        CHECK(ok, "⑤a off：8 位窗截图照旧——read == src 原样字节出 PNG（本 PR 只动非 8 位源）");
    }
    // ⑥ 未答过的 10 位窗截图：与 present 同一平凡直通副本（10 位码值按硬件换算进 8 位）——本 PR 实现点（基线上红失败不出文件）
    {
        const double nits[8] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        id<MTLTexture> s = src10_gray(nits, 8, 1), ref = dst_tex(MTLPixelFormatBGRA8Unorm, 8, 1);
        char *path = png_new(); int ok = 0; uint8_t png[8 * 4]; size_t w = 0, h = 0;
        if (path && t_trivial(s, ref)) { uint8_t *rb = tex_bytes(ref); shot(s, path, 1, NULL);
            if (png_read(path, png, sizeof png, &w, &h)) { unlink(path); ok = w == 8 && h == 1;
                for (int i = 0; ok && i < 8; i++) if (png[4 * i] != rb[4 * i + 2] || png[4 * i + 1] != rb[4 * i + 1] || png[4 * i + 2] != rb[4 * i]) ok = 0; }
            else ok = 0; free(rb); }
        else ok = 0;
        if (path) free(path);
        CHECK(ok, "⑥ 截图：未答过的 10 位窗走 present 同一平凡直通副本（PNG 写成且逐字节 = 改前 trivial 采样参考）");
    }
    // ⑦ float 窗截图：与 present 同一平凡直通副本（float 值按硬件钳换进 8 位）——本 PR 实现点（基线上红失败不出文件）
    {
        float f[8][3] = {{1, 1, 1}, {0.25f, 0.5f, 0.75f}, {4, 4, 4}, {0, 0, 0}, {-1, -1, -1}, {2, 1, 0}, {99, 0.01f, 0.5f}, {0.5f, 0.5f, 0.5f}};
        id<MTLTexture> s = src16f(f), ref = dst_tex(MTLPixelFormatBGRA8Unorm, 8, 1);
        char *path = png_new(); int ok = 0; uint8_t png[8 * 4]; size_t w = 0, h = 0;
        if (path && t_trivial(s, ref)) { uint8_t *rb = tex_bytes(ref); shot(s, path, 1, NULL);
            if (png_read(path, png, sizeof png, &w, &h)) { unlink(path); ok = w == 8 && h == 1;
                for (int i = 0; ok && i < 8; i++) if (png[4 * i] != rb[4 * i + 2] || png[4 * i + 1] != rb[4 * i + 1] || png[4 * i + 2] != rb[4 * i]) ok = 0; }
            else ok = 0; free(rb); }
        else ok = 0;
        if (path) free(path);
        CHECK(ok, "⑦ 截图：float 窗走 present 同一平凡直通副本（PNG 写成且逐字节 = 改前 trivial 采样参考）");
    }

    // ---------- on 态（S3 强制路径）：HDR10 窗的 grab / 判据 / 截图 = mode 1 副本 ----------
    setenv("S2A_HDR", "on", 1);
    hdr_snapshot pub = {.potential_edr = 2.0, .current_headroom = 4.0, .s1_ready = 0, .paper_white = 100};
    nvn2_hdr_snapshot_publish(&pub);   // can 未持稳 / s1_ready=0 → S3 强制路径（评审稿 §2.3 第 3 条）
    hdr_decision d = nvn2_hdr_answer(1, 1000);
    CHECK(d.mode == HDR_S3 && d.vi_on == 1 && d.vi_fmt == 1 && d.vi_peak == 400, "② 前端替身：S3 强制路径答 on=1 / fmt=1 / peak=400（headroom 4，latch 置位）");

    // ③ HDR10 窗 grab = mode 1 副本（先矩阵后肩部）：灰阶逐档 + 橙色高光保色相，±1 LSB；转换态 alpha 写 1
    {
        const double nits[8] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        const double col[8][3] = {{1000, 300, 0}, {100, 100, 100}, {10000, 10000, 10000}, {0, 1000, 0}, {500, 500, 500}, {0, 0, 0}, {203, 203, 203}, {3000, 100, 0}};
        int ran = grab_once(src10_rows(nits, col), 8, 2), bad = 0;
        double e[3];
        for (int i = 0; ran && i < 8; i++) {   // 第 0 行：灰阶沿肩部（暗部中灰照 SDR、亮灰压进 SDR 白）
            mode1((double[3]){nits[i], nits[i], nits[i]}, e);
            for (int k = 0; k < 3; k++) bad += fabs(g_grab[4 * i + k] - e[2 - k]) > 1.0;   // grab 是 BGRA 序
            bad += g_grab[4 * i + 3] != 255;
        }
        for (int i = 0; ran && i < 8; i++) {   // 第 1 行：彩色（橙色高光 1000/300/0 保色相 + 各档）
            mode1(col[i], e);
            for (int k = 0; k < 3; k++) bad += fabs(g_grab[4 * (8 + i) + k] - e[2 - k]) > 1.0;
            bad += g_grab[4 * (8 + i) + 3] != 255;
        }
        CHECK(ran && !bad, "③ HDR10 窗 grab = mode 1 副本：先 BT.2020→BT.709 矩阵（负值截断在矩阵后）再肩部压缩到 SDR 白、2.2 编码（灰阶 + 彩色 ±1，alpha 写 1）——录像与自动玩家截图同走这一份字节");
    }

    // ④ fit_judge 在 PQ 源上无误报：mode 1 副本判 0 红；同一画面的平凡直通字节（无转换形态）判「暗带」红（连续两次）——转换是前提；再判恢复
    {
        double fn[64 * 9];
        for (NSUInteger x = 0; x < 64; x++) for (NSUInteger y = 0; y < 9; y++) fn[y * 64 + x] = x < 16 ? 20.0 : 10000.0;   // 左 1/4 暗场（mode 1 = 123/255）、其余高光（255）
        id<MTLTexture> s = src10_gray(fn, 64, 9), ref = dst_tex(MTLPixelFormatBGRA8Unorm, 64, 9);
        uint8_t *triv = t_trivial(s, ref) ? tex_bytes(ref) : NULL;   // 无转换时的字节形态：20 nit = 91/255 → 暗带门内（< 0.4×255×3）
        g_present_n = 30;   // fit_pick 的间隔（至少隔 30 次出图一次）：本测直调 grab_present，present 计数由本测推进
        int ran = grab_once(s, 64, 9);
        int clean = ran && g_tok && mtl_fit_judge_shot(g_tok, g_grab, 64, 9, 64 * 4);
        CHECK(ran && clean && !mtl_fit_bad(1) && mtl_fit_last(NULL, NULL) == 0, "④ fit_judge 无误报：PQ 源经 grab 的 mode 1 副本（20 nit = 123/255）判 → 内容判据 0 红");
        g_present_n += 30; ran = grab_once(s, 64, 9);
        int red1 = ran && g_tok && triv && mtl_fit_judge_shot(g_tok, triv, 64, 9, 64 * 4);
        CHECK(ran && red1 && mtl_fit_last(NULL, NULL) == 3 && !mtl_fit_bad(1), "④ 反面：同一画面的平凡直通字节（20 nit = 91/255）判「暗带」（kind 3；首次只计数、st[1] 仍未置位）");
        g_present_n += 30; ran = grab_once(s, 64, 9);
        int red2 = ran && g_tok && triv && mtl_fit_judge_shot(g_tok, triv, 64, 9, 64 * 4);
        CHECK(ran && red2 && mtl_fit_bad(1), "④ 反面再判：连续第二次「暗带」→ st[1] 置位（无转换形态确会误报，转换是判据不误报的前提）");
        g_present_n += 30; ran = grab_once(s, 64, 9);
        int rec = ran && g_tok && mtl_fit_judge_shot(g_tok, g_grab, 64, 9, 64 * 4);
        CHECK(ran && rec && !mtl_fit_bad(1) && mtl_fit_last(NULL, NULL) == 0, "④ 恢复：mode 1 副本再判 → 0 红（PQ 源上无误报的用例闭环）");
        free(triv);
    }

    // ⑧ HDR10 窗截图 = mode 1 副本（PNG 写成、逐像素对拍）——本 PR 实现点（基线上红失败不出文件）
    {
        const double nits[8] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        const double col[8][3] = {{1000, 300, 0}, {100, 100, 100}, {10000, 10000, 10000}, {0, 1000, 0}, {500, 500, 500}, {0, 0, 0}, {203, 203, 203}, {3000, 100, 0}};
        id<MTLTexture> s = src10_rows(nits, col);
        char *path = png_new(); int ok = 0; uint8_t png[8 * 2 * 4]; size_t w = 0, h = 0;
        if (path) { shot(s, path, 1, NULL);
            if (png_read(path, png, sizeof png, &w, &h)) { unlink(path); ok = w == 8 && h == 2;
                double e[3];
                for (int i = 0; ok && i < 8; i++) { mode1((double[3]){nits[i], nits[i], nits[i]}, e);
                    for (int k = 0; k < 3; k++) if (fabs(png[4 * i + k] - e[k]) > 1.0) ok = 0; }
                for (int i = 0; ok && i < 8; i++) { mode1(col[i], e);
                    for (int k = 0; k < 3; k++) if (fabs(png[4 * (8 + i) + k] - e[k]) > 1.0) ok = 0; } }
            else ok = 0; free(path); }
        CHECK(ok, "⑧ 截图：HDR10 窗走 mode 1 副本（先矩阵后肩部）——PNG 写成且逐像素对拍 ±1（与 present 同一编码）");
    }
    // ⑤b 8 位窗截图（on 态 + latch 已置）：8 位源照旧不进新分支——PNG 逐字节 = 源字节（off 不变量的 PR6 侧）
    {
        uint8_t c[8][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}, {1, 2, 3, 255}, {200, 100, 50, 255}, {16, 16, 16, 255}, {0, 0, 0, 255}};
        char *path = png_new(); int ok = 0; uint8_t png[8 * 4]; size_t w = 0, h = 0;
        if (path) { shot(src8(c), path, 1, NULL);
            if (png_read(path, png, sizeof png, &w, &h)) { unlink(path); ok = w == 8 && h == 1;
                for (int i = 0; ok && i < 8; i++) if (png[4 * i] != c[i][0] || png[4 * i + 1] != c[i][1] || png[4 * i + 2] != c[i][2]) ok = 0; }
            else ok = 0; free(path); }
        CHECK(ok, "⑤b on+latch：8 位窗截图照旧——源非 8 位才进 mode 1 分支（8 位源字节级零变化）");
    }

    printf("%s t_present_shots：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
