// t_red.py 的 GPU 执行器：采样器着色器模拟对拍（#800、缺口族 31）。
//   归约：期望 = 本机原生归约生效（Apple10）时取 Metal 26 原生 reductionMode 采样器（按采样器自己的过滤）的读数（另核它等于 CPU 手算），不生效（非 Apple10）时取 CPU 手算；
//     真结果 = 不带归约的采样器 + 着色器 s2a_rs（表项由 nvn_red_entry 填）。过滤组合含最近点 / 混合 / mip 近邻（11-01 起）
//   任意边界色：期望 = CPU 按过滤定义手算（界内纹素加权 + 界外权重 × 自定义色）；真结果 = 着色器 s2a_bs（表里透明黑 / 不透明白两个采样器各采一次再混）
// 用法：t_red_run <核 MSL> <位置文件>（k2 / ka / kb* 由 t_red.py 写：S2A.Dsh RED_HELP + 对拍核）。每个（采样器配置 × 贴图）一行 ✓ / ✗，退出 0 = 全过
//   t_red_run --dc <原样核> <改写主体>：#529 定点深度比较参考值限制（见 dc_run）
//   t_red_run --bias|--cmp <计算 MSL> <片元 MSL> <计算主体> <片元主体>：LOD 偏置对拍（#800；--cmp 是深度比较采样，缺口族 31），前两份是原样翻译（main0），后两份是 S2A.Dsh FsLb
//   改写后的主体（偏置从参数块成员 s2a_lb 读；片元那几份另带 vs_main），见 bias_run
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "nvn_red.h"
#include "../../metal/gal_samp_caps.h"   // s2a_lodbias_native：本机原生偏置生效没有（生效才另核原生一路）

enum { W = 8, NL = 4 };
static int fail;
static uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
// 每级、每层、每个纹素各一个值（k / 1023，相邻差得开）：游戏的金字塔每级自己写，这里也每级独立
static float val(int kind, int lv, int x, int y, int layer) {
    uint32_t h = (uint32_t)x * 73856093u ^ (uint32_t)y * 19349663u ^ (uint32_t)lv * 83492791u ^ (uint32_t)layer * 2654435761u ^ (uint32_t)kind * 40503u;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15; return (float)(h & 1023u) / 1023.0f;
}
// kind 0 R32Float 2D、1 R32Float 2D 数组（2 层）、2 Depth32Float 2D；8×8、4 级，经拷贝编码器从缓冲写入
static id<MTLTexture> make_tex(id<MTLDevice> dev, id<MTLCommandQueue> cq, int kind) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind == 1 ? MTLTextureType2DArray : MTLTextureType2D; d.pixelFormat = kind == 2 ? MTLPixelFormatDepth32Float : MTLPixelFormatR32Float;
    d.width = d.height = W; d.mipmapLevelCount = NL; d.arrayLength = kind == 1 ? 2 : 1; d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    id<MTLBuffer> up = [dev newBufferWithLength:W * W * 4 * NL * 2 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; size_t off = 0;
    for (int l = 0; l < NL; l++) for (int a = 0; a < (kind == 1 ? 2 : 1); a++) {
        int w = W >> l; float *p = (float *)((uint8_t *)up.contents + off);
        for (int y = 0; y < w; y++) for (int x = 0; x < w; x++) p[y * w + x] = val(kind, l, x, y, a);
        [be copyFromBuffer:up sourceOffset:off sourceBytesPerRow:(NSUInteger)w * 4 sourceBytesPerImage:kind == 1 ? (NSUInteger)w * w * 4 : 0 sourceSize:MTLSizeMake(w, w, 1)
                 toTexture:t destinationSlice:a destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
        off += (size_t)w * w * 4;
    }
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; return t;
}
typedef struct { int red, minf, magf, wrap; } cfg;
// CPU 按定义手算的归约期望（不跑被测实现）：LOD > 0 用缩小过滤（NVN minf 奇数 = 线性）、否则放大过滤；mip：无 → 只读第 0 级；近邻（minf 2 / 3）→ LOD 钳 [0, 3] 后取 ceil(l − 0.5) 一级
//   （11-01 M5 Max 实测 Metal 的最近 mip：0.5 → 0、1.5 → 1）；线性（minf 4 / 5）→ 小数时两级都算。每级：最近点取 floor(c × 尺寸) 一个纹素；线性取双线性足迹里权重非零的纹素
//   （坐标小数部分为 0 的那一侧不参与）；基准纹素加偏移 (ox, oy)，寻址按 NVN 模式折回，越界（夹边框）取边框色 bc，逐纹素取 min / max。
//   old = 1：旧实现的口径（mip 近邻也按两级算，= 旧原生路径把 mip 过滤强改线性），只用来反证
static int wrap_i(int i, int n, int m) {
    switch (m) {
    case 1: { int r = i % n; return r < 0 ? r + n : r; }   // 重复
    case 6: { int p = 2 * n, r = i % p; if (r < 0) r += p; return r < n ? r : p - 1 - r; }   // 镜像重复
    case 3: { int k = i < 0 ? -1 - i : i; return k < n ? k : n - 1; }   // 镜像夹边
    case 5: return i < 0 || i >= n ? -1 : i;   // 夹边框
    default: return i < 0 ? 0 : i >= n ? n - 1 : i;   // 夹边
    }
}
static float cpu_red_(int kind, cfg c, float u, float v, float lod, int layer, int ox, int oy, float bc, int old) {
    int lin = lod > 0 ? c.minf & 1 : c.magf != 0, mip = c.minf <= 1 ? 0 : c.minf <= 3 && !old ? 1 : 2;
    float l = mip == 0 ? 0 : lod < 0 ? 0 : lod > NL - 1 ? NL - 1 : lod; if (mip == 1) l = ceilf(l - 0.5f);
    int l0 = (int)floorf(l), nl = l > l0 ? 2 : 1, first = 1; float r = 0;
    for (int k = 0; k < nl; k++) { int lv = l0 + k, w = W >> lv;
        float fx = u * w - (lin ? 0.5f : 0), fy = v * w - (lin ? 0.5f : 0); int x0 = (int)floorf(fx), y0 = (int)floorf(fy), nx = lin && fx > x0 ? 2 : 1, ny = lin && fy > y0 ? 2 : 1;
        for (int j = 0; j < ny; j++) for (int i = 0; i < nx; i++) { int xi = wrap_i(x0 + ox + i, w, c.wrap), yj = wrap_i(y0 + oy + j, w, c.wrap);
            float t = xi < 0 || yj < 0 ? bc : val(kind, lv, xi, yj, kind == 1 ? layer : 0); r = first ? t : c.red == 2 ? fmaxf(r, t) : fminf(r, t); first = 0; } }
    return r;
}
static float cpu_red(int kind, cfg c, float u, float v, float lod, int layer, int ox, int oy, float bc) { return cpu_red_(kind, c, u, v, lod, layer, ox, oy, bc, 0); }
// 边界色那一组的贴图：RGBA32Float 8×8、4 级（kind 0 2D、1 2D 数组 2 层），通道 ch 的值 = val(10 + ch, …)
static id<MTLTexture> rgba_tex(id<MTLDevice> dev, id<MTLCommandQueue> cq, int kind) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind ? MTLTextureType2DArray : MTLTextureType2D; d.pixelFormat = MTLPixelFormatRGBA32Float;
    d.width = d.height = W; d.mipmapLevelCount = NL; d.arrayLength = kind ? 2 : 1; d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d]; static float px[W * W * 4];
    for (int l = 0; l < NL; l++) for (int a = 0; a < (kind ? 2 : 1); a++) { int w = W >> l;
        for (int y = 0; y < w; y++) for (int x = 0; x < w; x++) for (int ch = 0; ch < 4; ch++) px[(y * w + x) * 4 + ch] = val(10 + ch, l, x, y, a);
        [t replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l slice:a withBytes:px bytesPerRow:(NSUInteger)w * 16 bytesPerImage:0]; }
    (void)cq; return t;
}
// CPU 按过滤定义手算的普通（不归约）采样，通道 ch：LOD > 0 缩小过滤否则放大（线性 = 双线性权重、最近点 = floor(c × 尺寸) 一个纹素）；mip 无 → 第 0 级、近邻 → ceil(l − 0.5)、
//   线性 → 两级按小数混合；寻址 s 按 c.wrap、t 按 wt（NVN 模式折回），越界取边界色 C[ch]
static double cpu_avg(int kind, cfg c, int wt, float u, float v, float lod, int layer, int ox, int oy, int ch, const float C[4]) {
    int lin = lod > 0 ? c.minf & 1 : c.magf != 0, mip = c.minf <= 1 ? 0 : c.minf <= 3 ? 1 : 2;
    float l = mip == 0 ? 0 : lod < 0 ? 0 : lod > NL - 1 ? NL - 1 : lod; if (mip == 1) l = ceilf(l - 0.5f);
    int l0 = (int)floorf(l), nl = l > l0 ? 2 : 1; double r = 0, fl = l - l0;
    for (int k = 0; k < nl; k++) { int lv = l0 + k, w = W >> lv; double wl = nl == 1 ? 1 : k ? fl : 1 - fl, s = 0;
        double fx = (double)u * w - (lin ? 0.5 : 0), fy = (double)v * w - (lin ? 0.5 : 0); int x0 = (int)floor(fx), y0 = (int)floor(fy); double ax = fx - x0, ay = fy - y0;
        for (int j = 0; j < (lin ? 2 : 1); j++) for (int i = 0; i < (lin ? 2 : 1); i++) {
            double wgt = lin ? (i ? ax : 1 - ax) * (j ? ay : 1 - ay) : 1; int xi = wrap_i(x0 + ox + i, w, c.wrap), yj = wrap_i(y0 + oy + j, w, wt);
            s += wgt * (xi < 0 || yj < 0 ? C[ch] : val(10 + ch, lv, xi, yj, kind ? layer : 0)); }
        r += wl * s; }
    return r;
}
// 建法照 nvn_mtl.m samp_desc：native = 26 一路（带 reductionMode，过滤照采样器自己的），plain = 老系统一路（不带归约）；LOD 钳 0..1000 同 nvnSamplerBuilderSetDefaults；
//   bc ≥ 0：边界色强制为该 Metal 值（0 透明黑 / 2 不透明白：边界色模拟的两个采样器），否则按 nvn_samp_border 分档
static id<MTLSamplerState> make_samp_(id<MTLDevice> dev, cfg c, int wt, const float border[4], int native, int bc) {
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.magFilter = c.magf ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.minFilter = (c.minf == 1 || c.minf == 3 || c.minf == 5) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = c.minf <= 1 ? MTLSamplerMipFilterNotMipmapped : (c.minf == 2 || c.minf == 3) ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    d.sAddressMode = d.rAddressMode = (MTLSamplerAddressMode)nvn_samp_wrap(c.wrap); d.tAddressMode = (MTLSamplerAddressMode)nvn_samp_wrap(wt);
    d.lodMinClamp = 0; d.lodMaxClamp = 1000; d.borderColor = (MTLSamplerBorderColor)(bc >= 0 ? bc : nvn_samp_border(border, NULL)); d.supportArgumentBuffers = YES;
    if (native) { if (@available(macOS 26.0, *)) d.reductionMode = c.red == 1 ? MTLSamplerReductionModeMinimum : MTLSamplerReductionModeMaximum; }
    return [dev newSamplerStateWithDescriptor:d];
}
static id<MTLSamplerState> make_samp(id<MTLDevice> dev, cfg c, const float border[4], int native) { return make_samp_(dev, c, c.wrap, border, native, -1); }
static id<MTLComputePipelineState> mk_pipe(id<MTLDevice> dev, id<MTLLibrary> lib, const char *n) {
    NSError *e = nil; id<MTLFunction> f = [lib newFunctionWithName:@(n)]; return f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil;
}
// ---- LOD 偏置（#800）：贴图 R32Float 8×8、4 级，第 L 级全部纹素 = L（kind 0 2D、1 2D 数组 2 层、2 立方体）；采样器最近点 + mip 线性 → 读数 = 夹到 [0, 3] 的实际 LOD ----
// cmp：深度比较那一路——Depth32Float，第 L 级全部深度 = 0.1 + 0.25 L；比较 LESS（参考值 < 深度 → 1），着色器对参考值 0.2 / 0.45 / 0.7 各比一次求和 = 所采级号，
//   最近点 + mip 线性 → 和 = 夹到 [0, 3] 的实际 LOD（同普通采样那一路）。深度贴图不能共享存储：经拷贝编码器写入
static id<MTLTexture> dep_tex(id<MTLDevice> dev, id<MTLCommandQueue> cq, int kind) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new]; int ns = kind == 1 ? 2 : kind == 2 ? 6 : 1;
    d.textureType = kind == 1 ? MTLTextureType2DArray : kind == 2 ? MTLTextureTypeCube : MTLTextureType2D; d.pixelFormat = MTLPixelFormatDepth32Float;
    d.width = d.height = W; d.mipmapLevelCount = NL; d.arrayLength = kind == 1 ? 2 : 1; d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d]; id<MTLBuffer> up = [dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; float *px = (float *)up.contents;
    for (int i = 0; i < W * W; i++) px[i] = 0;
    for (int l = 0; l < NL; l++) { int w = W >> l;
        for (int sl = 0; sl < ns; sl++) { id<MTLBuffer> b = [dev newBufferWithLength:(NSUInteger)w * w * 4 options:MTLResourceStorageModeShared]; float *q = (float *)b.contents;
            for (int i = 0; i < w * w; i++) q[i] = 0.1f + 0.25f * (float)l;
            [be copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:(NSUInteger)w * 4 sourceBytesPerImage:(NSUInteger)w * w * 4 sourceSize:MTLSizeMake(w, w, 1) toTexture:t destinationSlice:sl destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)]; } }
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; return t;
}
static id<MTLTexture> lvl_tex(id<MTLDevice> dev, int kind) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind == 1 ? MTLTextureType2DArray : kind == 2 ? MTLTextureTypeCube : MTLTextureType2D; d.pixelFormat = MTLPixelFormatR32Float;
    d.width = d.height = W; d.mipmapLevelCount = NL; d.arrayLength = kind == 1 ? 2 : 1; d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d]; float px[W * W];
    for (int l = 0; l < NL; l++) { int w = W >> l; for (int i = 0; i < w * w; i++) px[i] = (float)l;
        for (int sl = 0; sl < (kind == 1 ? 2 : kind == 2 ? 6 : 1); sl++) [t replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l slice:sl withBytes:px bytesPerRow:(NSUInteger)w * 4 bytesPerImage:0]; }
    return t;
}
static float cl3(float x) { return x < 0 ? 0 : x > NL - 1 ? NL - 1 : x; }
static id<MTLLibrary> lib_of(id<MTLDevice> dev, const char *p, const char *what, int *lbid) {   // lbid：源码里 s2a_lb 参数块成员的 id（没有 = -1）
    NSError *e = nil; NSString *src = [NSString stringWithContentsOfFile:@(p) encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> l = src ? [dev newLibraryWithSource:src options:nil error:&e] : nil;
    if (!l) printf("✗ 编%s失败：%s\n", what, e.localizedDescription.UTF8String);
    if (lbid) { NSRange r = src ? [src rangeOfString:@"s2a_lb [[id("] : NSMakeRange(NSNotFound, 0); *lbid = r.location == NSNotFound ? -1 : [src substringFromIndex:NSMaxRange(r)].intValue; }
    return l;
}
// 四路：v 0 主体（fs_lb 改写过）+ 带偏置的采样器 + 零表（Apple10 那一路：采样器原生加偏置，表写 0）；v 1 主体 + 不带偏置的采样器 + 表写 b（本机不原生那一路）；
//   v 2 原样 main0 + 带偏置的采样器。v 0 必须与 v 2 逐位相等（任何 GPU：同一个采样器、零表就是原采样）；
//   v 3 原样 main0 + 不带偏置的采样器 = 改写前本机不吃采样器偏置时的样子（反证：b ≠ 0 时必须有对不上手算的）
enum { NV = 4 };
static int bias_run(const char *csp, const char *fsp, const char *csl, const char *fsl, int cmp) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> cq = [dev newCommandQueue]; NSError *e = nil;
    int native = s2a_lodbias_native(dev); const char *wh = cmp ? "比较采样 " : "";
    printf("✓ %sLOD 偏置：本机原生偏置%s（%s）\n", wh, native ? "生效，另核原生一路等于期望" : "不生效，只核模拟一路与零表一路", dev.name.UTF8String);
    int lbc = -1, lbf = -1;
    id<MTLLibrary> lc = lib_of(dev, csp, "计算核", NULL), lf = lib_of(dev, fsp, "片元核", NULL), lcl = lib_of(dev, csl, "计算主体", &lbc), lfl = lib_of(dev, fsl, "片元主体", &lbf);
    if (!lc || !lf || !lcl || !lfl) return 1;
    if (lbc < 0 || lbf < 0) { printf("✗ 主体源码里没有 s2a_lb 成员（计算 %d / 片元 %d）\n", lbc, lbf); return 1; }
    id<MTLLibrary> cl[NV] = {lcl, lcl, lc, lc}, fl[NV] = {lfl, lfl, lf, lf};
    id<MTLFunction> cf[NV], ff[NV]; id<MTLComputePipelineState> cps[NV]; id<MTLRenderPipelineState> rps[NV]; id<MTLArgumentEncoder> ace[NV], afe[NV];
    for (int v = 0; v < NV; v++) {
        cf[v] = [cl[v] newFunctionWithName:@"main0"]; ff[v] = [fl[v] newFunctionWithName:@"main0"];
        if (!cf[v] || !ff[v]) { printf("✗ 缺 main0（第 %d 路）\n", v); return 1; }
        cps[v] = [dev newComputePipelineStateWithFunction:cf[v] error:&e];
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new]; rd.vertexFunction = [fl[v] newFunctionWithName:@"vs_main"]; rd.fragmentFunction = ff[v];
        rd.colorAttachments[0].pixelFormat = rd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA32Float; rps[v] = [dev newRenderPipelineStateWithDescriptor:rd error:&e];
        if (!cps[v] || !rps[v]) { printf("✗ 建管线失败：%s\n", e.localizedDescription.UTF8String); return 1; }
        ace[v] = [cf[v] newArgumentEncoderWithBufferIndex:0]; afe[v] = [ff[v] newArgumentEncoderWithBufferIndex:0];
    }
    { NSUInteger a0 = ace[0].encodedLength, a2 = ace[2].encodedLength, b0 = afe[0].encodedLength, b2 = afe[2].encodedLength;
      int ok = a0 == a2 + 8 && b0 == b2 + 8; fail |= !ok; printf("%s 主体的参数块比原样多一个 8 字节成员（计算 %lu / %lu，片元 %lu / %lu）\n", ok ? "✓" : "✗", (unsigned long)a0, (unsigned long)a2, (unsigned long)b0, (unsigned long)b2); }
    id<MTLTexture> tx[3]; for (int k = 0; k < 3; k++) tx[k] = cmp ? dep_tex(dev, cq, k) : lvl_tex(dev, k);
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:W height:W mipmapped:NO]; od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt[NV][2]; for (int v = 0; v < NV; v++) for (int a = 0; a < 2; a++) rt[v][a] = [dev newTextureWithDescriptor:od];
    id<MTLBuffer> cout = [dev newBufferWithLength:NV * 2 * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> tz = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared], tb = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];   // 1024：比较采样另读表后半段 [192 + id]（#529），表要覆盖到那里   // s2a_lb 表：零表 / 采样器成员 1、3、5 写 b
    id<MTLBuffer> cab[NV], fab[NV];
    for (int v = 0; v < NV; v++) { cab[v] = [dev newBufferWithLength:ace[v].encodedLength options:MTLResourceStorageModeShared]; fab[v] = [dev newBufferWithLength:afe[v].encodedLength options:MTLResourceStorageModeShared]; }
    static const float B[] = {0, 1, -0.5f, 1.25f, 2.5f, -1, 0.75f};
    for (unsigned bi = 0; bi < sizeof B / sizeof *B; bi++) { float b = B[bi];
        id<MTLSamplerState> ss[2];   // [0] 带偏置（v 0 / v 2）[1] 不带（v 1：偏置在表里）
        for (int v = 0; v < 2; v++) { MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; sd.mipFilter = MTLSamplerMipFilterLinear;
            sd.lodMinClamp = 0; sd.lodMaxClamp = 1000; if (!v) sd.lodBias = b; sd.supportArgumentBuffers = YES; if (cmp) sd.compareFunction = MTLCompareFunctionLess;
            ss[v] = [dev newSamplerStateWithDescriptor:sd]; }
        memset(tz.contents, 0, tz.length); memset(tb.contents, 0, tb.length);
        for (int id_ = 1; id_ <= 5; id_ += 2) ((float *)tb.contents)[id_] = b;   // = nvn_mtl.m lb_fill：表下标 = 采样器成员的参数块 id
        id<MTLCommandBuffer> cb = [cq commandBuffer];
        for (int v = 0; v < NV; v++) {
            id<MTLSamplerState> sv = ss[v == 1 || v == 3]; id<MTLBuffer> tq = v == 1 ? tb : tz;
            [ace[v] setArgumentBuffer:cab[v] offset:0]; [afe[v] setArgumentBuffer:fab[v] offset:0];
            for (int k = 0; k < 3; k++) { [ace[v] setTexture:tx[k] atIndex:2 * k]; [ace[v] setSamplerState:sv atIndex:2 * k + 1]; [afe[v] setTexture:tx[k] atIndex:2 * k]; [afe[v] setSamplerState:sv atIndex:2 * k + 1]; }
            *(uint64_t *)[ace[v] constantDataAtIndex:6] = cout.gpuAddress + 32 * (uint64_t)v;
            if (v < 2) { *(uint64_t *)[ace[v] constantDataAtIndex:(NSUInteger)lbc] = tq.gpuAddress; *(uint64_t *)[afe[v] constantDataAtIndex:(NSUInteger)lbf] = tq.gpuAddress; }
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:cps[v]]; [ce setBuffer:cab[v] offset:0 atIndex:0];
            for (int k = 0; k < 3; k++) [ce useResource:tx[k] usage:MTLResourceUsageRead]; [ce useResource:cout usage:MTLResourceUsageWrite]; [ce useResource:tq usage:MTLResourceUsageRead];
            [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            for (int a = 0; a < 2; a++) { rp.colorAttachments[a].texture = rt[v][a]; rp.colorAttachments[a].loadAction = MTLLoadActionClear; rp.colorAttachments[a].storeAction = MTLStoreActionStore; }
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:rps[v]]; [re setFragmentBuffer:fab[v] offset:0 atIndex:0];
            for (int k = 0; k < 3; k++) [re useResource:tx[k] usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            [re useResource:tq usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
        }
        [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { printf("✗ %s偏置 %g：命令缓冲出错 %s\n", wh, b, cb.error.localizedDescription.UTF8String); return 1; }
        // 期望（手算）。计算：(隐式 0 + b, level(1) + b, gradient(LOD 1) + b, min_lod_clamp(0) 隐式 max(0 + b, 0))，(数组隐式 + b, 数组 level(2) + b, 立方体 level(1) + b, 0)
        //   片元：(隐式 + b, bias(0.5) + b, level(1) + b, gradient(LOD 1) + b)，(带偏移隐式 + b, 数组隐式 + b, 数组 bias(0.5) + b, min_lod_clamp(0) 隐式 + b)
        const float ec[8] = {cl3(b), cl3(1 + b), cl3(1 + b), cl3(b), cl3(b), cl3(2 + b), cl3(1 + b), 0};
        const float ef[8] = {cl3(b), cl3(0.5f + b), cl3(1 + b), cl3(1 + b), cl3(b), cl3(b), cl3(0.5f + b), cl3(b)};
        static const char *cn[8] = {"计算隐式", "计算 level(1)", "计算 gradient", "计算 min_lod_clamp(0)", "计算数组隐式", "计算数组 level(2)", "计算立方体 level(1)", "计算 0"};
        static const char *fn[8] = {"片元隐式", "片元 bias(0.5)", "片元 level(1)", "片元 gradient", "片元隐式带偏移", "片元数组隐式", "片元数组 bias(0.5)", "片元 min_lod_clamp(0)"};
        static float fo[NV][2][W * W * 4];
        for (int v = 0; v < NV; v++) for (int a = 0; a < 2; a++) [rt[v][a] getBytes:fo[v][a] bytesPerRow:W * 16 fromRegion:MTLRegionMake2D(0, 0, W, W) mipmapLevel:0];
        // 模拟一路 gradient 形态的容差：偏置只能乘进导数，硬件从导数算 LOD 有量化。普通采样 2/256 级；比较采样 3/256 级（11-01 M5 Max 偏置 1.25 实测差 2.007/256）
        const float gtol = cmp ? 3.0f / 256 : 2.0f / 256;
        for (int v = native ? 0 : 1; v < 2; v++) {
            const float *co = (const float *)cout.contents + 8 * v; int bad = 0; char first[200] = "";
            for (int c = 0; c < 8; c++) { float tol = v && c == 2 ? gtol : 0; if (!(fabsf(co[c] - ec[c]) <= tol)) { bad++; if (!first[0]) snprintf(first, sizeof first, "%s 期望 %g 实得 %.9g", cn[c], ec[c], co[c]); } }
            for (int c = 0; c < 8; c++) { float tol = v && c == 3 ? gtol : 0;
                for (int px = 0; px < W * W; px++) if (!(fabsf(fo[v][c / 4][4 * px + c % 4] - ef[c]) <= tol)) { bad++; if (!first[0]) snprintf(first, sizeof first, "%s 像素 %d 期望 %g 实得 %.9g", fn[c], px, ef[c], fo[v][c / 4][4 * px + c % 4]); break; } }
            fail |= bad != 0;
            printf("%s %s偏置 %g %s：计算 8 项 + 片元 8 项 × 64 像素等于手算（逐位；模拟一路 gradient 容差 %g/256 级）%s%s\n", bad ? "✗" : "✓", wh, b, v ? "模拟（主体 + 表写 b + 不带偏置的采样器）" : "原生（主体 + 零表 + 采样器 lodBias）", gtol * 256, bad ? "，首个不等：" : "", first);
        }
        if (b != 0) {   // 反证 v 3：原样 main0 + 不带偏置的采样器（改写前、本机不吃采样器偏置时）与手算对不上的项数（16 项里，要 > 0）
            const float *co = (const float *)cout.contents + 8 * 3; int nb = 0;
            for (int c = 0; c < 8; c++) nb += co[c] != ec[c] && !(c == 7);
            for (int c = 0; c < 8; c++) nb += fo[3][c / 4][c % 4] != ef[c];
            fail |= nb == 0; printf("%s %s偏置 %g 反证：原样 main0 + 不带偏置的采样器（改写前不吃采样器偏置的 GPU）对不上手算 %d / 15 项（要 > 0）\n", nb ? "✓" : "✗", wh, b, nb);
        }
        { const float *c0 = (const float *)cout.contents; int same = !memcmp(c0, c0 + 16, 32) && !memcmp(fo[0], fo[2], sizeof fo[0]);
          fail |= !same; printf("%s %s偏置 %g：主体 + 零表与原样 main0（同一个带偏置的采样器）计算 / 片元读回逐位相等\n", same ? "✓" : "✗", wh, b); }
        if (b == 0) {   // 这一轮两种采样器都不偏：模拟一路（表写 0）与原样 main0 逐位相等
            const float *c0 = (const float *)cout.contents; int same = !memcmp(c0 + 8, c0 + 16, 32) && !memcmp(fo[1], fo[2], sizeof fo[0]);
            fail |= !same; printf("%s %s偏置 0：主体（表写 0）与原样 main0 计算 / 片元读回逐位相等\n", same ? "✓" : "✗", wh);
        }
    }
    return fail;
}

// ---- #529 定点深度比较：计算核读 depth2d（Depth32Float 8×8 一级，深度全 1.0）、采样器 LessEqual，sample_compare 参考值 1.1 与 0.5 各一次 → cs_s0[0].xy ----
//   主体（fs_lb 改写过，参考值 = (s2a_lb[192 + 采样器 id] != 0 ? saturate(r) : (r))）跑两遍：表后半段写 0（浮点深度客体）/ 写 1（定点深度客体）；原样 main0 跑一遍。
//   期望（手算，LessEqual：参考值 ≤ 深度 → 1）：标志 0 → (0, 1)；标志 1 → 1.1 限制成 1.0 → (1, 1)；原样 → (0, 1)（反证：Metal 的 Depth32Float 比较不会自己限制参考值）
static int dc_run(const char *orig, const char *body) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> cq = [dev newCommandQueue]; NSError *e = nil; int lbid = -1, bad = 0;
    id<MTLLibrary> lo = lib_of(dev, orig, "原样核", NULL), lb = lib_of(dev, body, "改写主体", &lbid);
    if (!lo || !lb) return 1;
    if (lbid < 0) { printf("✗ 改写主体里没有 s2a_lb 成员\n"); return 1; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:W mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead; id<MTLTexture> tx = [dev newTextureWithDescriptor:d];
    id<MTLBuffer> up = [dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; for (int i = 0; i < W * W; i++) ((float *)up.contents)[i] = 1.0f;
    { id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
      [be copyFromBuffer:up sourceOffset:0 sourceBytesPerRow:W * 4 sourceBytesPerImage:W * W * 4 sourceSize:MTLSizeMake(W, W, 1) toTexture:tx destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
      [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.compareFunction = MTLCompareFunctionLessEqual; sd.supportArgumentBuffers = YES; id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd];
    id<MTLBuffer> out = [dev newBufferWithLength:3 * 16 options:MTLResourceStorageModeShared], tab[2];
    for (int f = 0; f < 2; f++) { tab[f] = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; memset(tab[f].contents, 0, 1024); ((float *)tab[f].contents)[192 + 1] = (float)f; }   // = nvn_mtl.m lb_fill：[LB_DC + 采样器成员 id]
    id<MTLLibrary> ls[3] = {lb, lb, lo};
    for (int r = 0; r < 3; r++) {
        id<MTLFunction> fn = [ls[r] newFunctionWithName:@"main0"]; id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&e] : nil;
        if (!ps) { printf("✗ 建管线失败（第 %d 路）：%s\n", r, e.localizedDescription.UTF8String); return 1; }
        id<MTLArgumentEncoder> ae = [fn newArgumentEncoderWithBufferIndex:0]; id<MTLBuffer> ab = [dev newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
        [ae setArgumentBuffer:ab offset:0]; [ae setTexture:tx atIndex:0]; [ae setSamplerState:ss atIndex:1];
        *(uint64_t *)[ae constantDataAtIndex:6] = out.gpuAddress + 16 * (uint64_t)r;
        if (r < 2) *(uint64_t *)[ae constantDataAtIndex:(NSUInteger)lbid] = tab[r].gpuAddress;
        id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:ps]; [ce setBuffer:ab offset:0 atIndex:0];
        [ce useResource:tx usage:MTLResourceUsageRead]; [ce useResource:out usage:MTLResourceUsageWrite]; if (r < 2) [ce useResource:tab[r] usage:MTLResourceUsageRead];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { printf("✗ 命令缓冲出错（第 %d 路）：%s\n", r, cb.error.localizedDescription.UTF8String); return 1; }
    }
    const float *o = (const float *)out.contents; static const float want[3][2] = {{0, 1}, {1, 1}, {0, 1}};
    static const char *nm[3] = {"改写主体 + 表标志 0（浮点深度客体）", "改写主体 + 表标志 1（定点深度客体）", "原样 main0（反证：Metal 不限制参考值）"};
    for (int r = 0; r < 3; r++) { int ok = o[4 * r] == want[r][0] && o[4 * r + 1] == want[r][1]; bad |= !ok;
        printf("%s 定点深度比较 %s：参考值 1.1 / 0.5 比深度 1.0（LessEqual）期望 %g / %g 实得 %g / %g\n", ok ? "✓" : "✗", nm[r], want[r][0], want[r][1], o[4 * r], o[4 * r + 1]); }
    return bad;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 6 && (!strcmp(argv[1], "--bias") || !strcmp(argv[1], "--cmp"))) return bias_run(argv[2], argv[3], argv[4], argv[5], !strcmp(argv[1], "--cmp"));
    if (argc == 4 && !strcmp(argv[1], "--dc")) return dc_run(argv[2], argv[3]);   // #529
    if (argc < 3) { fprintf(stderr, "用法：t_red_run <核 MSL> <位置文件> | --bias|--cmp <计算 MSL> <片元 MSL> <计算主体> <片元主体>\n"); return 2; }
    if (@available(macOS 26.0, *)) {} else { printf("✗ t_red_run：要 macOS 26（原生 reductionMode / lodBias 属性）\n"); return 1; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> cq = [dev newCommandQueue];
    // R32Float / Depth32Float 的线性过滤要设备支持 32 位浮点过滤；不支持时原生归约的期望没有意义，直接报红
    { int ok = dev.supports32BitFloatFiltering; fail |= !ok; printf("%s 设备支持 32 位浮点线性过滤（%s）\n", ok ? "✓" : "✗", dev.name.UTF8String); if (!ok) return 1; }
    NSError *e = nil; NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> lib = src ? [dev newLibraryWithSource:src options:nil error:&e] : nil;
    if (!lib) { printf("✗ 编核失败：%s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> k2 = mk_pipe(dev, lib, "k2"), ka = mk_pipe(dev, lib, "ka"), k2o = mk_pipe(dev, lib, "k2o");
    if (!k2 || !ka || !k2o) { printf("✗ 建核失败\n"); return 1; }
    static float P[8192][4]; int n = 0; FILE *f = fopen(argv[2], "r"); if (!f) { printf("✗ 读不到位置文件\n"); return 1; }
    while (n < 8192 && fscanf(f, "%f %f %f %f", &P[n][0], &P[n][1], &P[n][2], &P[n][3]) == 4) n++;
    fclose(f);
    id<MTLBuffer> bp = [dev newBufferWithBytes:P length:16 * (NSUInteger)n options:MTLResourceStorageModeShared], bq = [dev newBufferWithLength:sizeof(nvn_se_ent) options:MTLResourceStorageModeShared];
    id<MTLBuffer> bo[2] = {[dev newBufferWithLength:8 * (NSUInteger)n options:MTLResourceStorageModeShared], [dev newBufferWithLength:8 * (NSUInteger)n options:MTLResourceStorageModeShared]};
    const float white[4] = {1, 1, 1, 1};
    // CPU：NVN 包裹模式 → Metal 寻址模式整张表（审计缺口族 31）。期望按两边枚举语义：0/7 夹边 → ClampToEdge 0、1 重复 → Repeat 2、2/3 镜像夹边 → MirrorClampToEdge 1、
    //   4 镜像夹边框 → MirrorClampToEdge 1（Metal 没有镜像夹边框，保住镜像那半；旧表收成夹边框色 5，镜像整段丢）、5 夹边框 → ClampToBorderColor 5、6 镜像重复 → MirrorRepeat 3
    { static const int want[8] = {0, 2, 1, 1, 1, 5, 3, 0}; int ok = 1; for (int w = 0; w < 8; w++) ok &= nvn_samp_wrap(w) == want[w];
      fail |= !ok; printf("%s NVN 包裹模式 0–7 → Metal 寻址模式（4 → %d，期望 1）\n", ok ? "✓" : "✗", nvn_samp_wrap(4)); }
    // CPU：一个纹素的足迹（放大最近点、缩小最近点且 mip 无 / 近邻：NVN minf 0 / 2、magf 0）归约 = 原采样，表项为 0；其余过滤组合（含最近点 + mip 线性、缩小放大混合）表项不为 0
    { nvn_se_ent e1, e2, e3; int r1 = nvn_red_entry(0, 1, 0, 0, 7, 7, 7, 0, 0, 1000, 0, white, &e1), r2 = nvn_red_entry(0, 1, 2, 0, 7, 7, 7, 0, 0, 1000, 0, white, &e2),
        r3 = nvn_red_entry(0, 2, 4, 0, 7, 7, 7, 0, 0, 1000, 0, white, &e3);
      int ok = !r1 && !r2 && r3 && e3.q[0] == 2 && e3.q[6] == 8; fail |= !ok;
      printf("%s 一个纹素足迹的归约采样器表项为 0（最近点无 mip %d / 最近点 mip 近邻 %d，期望 0 / 0）；最近点 + mip 线性 max 表项模式 %g 过滤码 %g（期望 2 / 8）\n", ok ? "✓" : "✗", r1, r2, e3.q[0], e3.q[6]); }
    static const char *kn[3] = {"R32Float 2D", "R32Float 2D 数组", "Depth32Float 2D"}, *fnm[6] = {"最近点无 mip", "线性无 mip", "最近点 + mip 近邻", "线性 + mip 近邻", "最近点 + mip 线性", "线性 + mip 线性"};
    static const char *wn[8] = {"", "重复", "", "镜像夹边", "", "夹边框（白）", "镜像重复", "夹边"};
    // 过滤组合：前 3 个（放大线性）× 5 种寻址是 #800 原有的；后 9 个（含最近点 / 混合，缺口族 31）× 夹边 / 夹边框两种寻址
    static const int FL[12][2] = {{1, 1}, {3, 1}, {5, 1}, {0, 1}, {2, 1}, {4, 1}, {4, 0}, {5, 0}, {3, 0}, {1, 0}, {0, 0}, {2, 0}}, WR[5] = {7, 1, 6, 3, 5}, WRN[2] = {7, 5};
    int rnat = s2a_reduce_native(dev);
    printf("✓ 本机原生 min / max 归约%s（%s）\n", rnat ? "生效（Apple10）：期望取原生读数，另核等于 CPU 手算" : "不生效（非 Apple10）：期望取 CPU 手算", dev.name.UTF8String);
    for (int kind = 0; kind < 3; kind++) { id<MTLTexture> t = make_tex(dev, cq, kind);
      for (int var = 0; var < (kind == 0 ? 2 : 1); var++) { id<MTLComputePipelineState> ps = kind == 1 ? ka : var ? k2o : k2;
        for (int red = 1; red <= 2; red++) for (int fi = 0; fi < 12; fi++) for (int wi = 0; wi < (fi < 3 ? 5 : 2); wi++) {
            cfg c = {red, FL[fi][0], FL[fi][1], fi < 3 ? WR[wi] : WRN[wi]}; nvn_se_ent q;
            int need = nvn_red_entry(0, red, c.minf, c.magf, c.wrap, c.wrap, c.wrap, 0, 0, 1000, 0, white, &q); memcpy(bq.contents, &q, sizeof q);
            int one = c.magf == 0 && (c.minf == 0 || c.minf == 2);   // 一个纹素的足迹：表项 0，着色器原样采
            for (int s = 0; s < 2; s++) {   // s 0：原生归约采样器（期望）；s 1：不带归约的采样器（着色器归约 = 真结果，原采样 = 反证）
                id<MTLSamplerState> sm = make_samp(dev, c, white, !s);
                id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:ps]; [ce setTexture:t atIndex:0]; [ce setSamplerState:sm atIndex:0];
                [ce setBuffer:bq offset:0 atIndex:0]; [ce setBuffer:bp offset:0 atIndex:1]; [ce setBuffer:bo[s] offset:0 atIndex:2];
                [ce dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake(MIN(n, 64), 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
            }
            // 期望：本机原生归约（Apple10，gal_samp_caps.h s2a_reduce_native）时 = 原生采样器的读数，另核它等于 CPU 手算；非 Apple10（原生归约被静默忽略，10-28 gate-host / Spare-host）= CPU 手算
            const float *nat = bo[0].contents, *pl = bo[1].contents; int eq = 0, avg = 0, first = -1, cpu_eq = 0, oldd = 0;
            for (int i = 0; i < n; i++) { float x = cpu_red(kind, c, P[i][0], P[i][1], P[i][2], (int)P[i][3], var ? 1 : 0, var ? -1 : 0, white[0]), want = rnat ? nat[2 * i] : x;
                float got = one ? pl[2 * i] : pl[2 * i + 1];   // 一个纹素的足迹：表项 0，变体走 s2a_bs 原样采（= 不带归约的采样器），核里直调的 s2a_rs 不算数
                if (fb(want) == fb(got)) eq++; else if (first < 0) first = i; avg += fb(want) != fb(pl[2 * i]); cpu_eq += fb(x) == fb(nat[2 * i]);
                oldd += fb(cpu_red_(kind, c, P[i][0], P[i][1], P[i][2], (int)P[i][3], var ? 1 : 0, var ? -1 : 0, white[0], 1)) != fb(x); }
            int mipn = c.minf == 2 || c.minf == 3;   // mip 近邻：旧口径（两级）必须有对不上的
            int ok = eq == n && need == !one && (one ? avg == 0 : avg > 0) && (!rnat || cpu_eq == n) && (!mipn || oldd > 0); fail |= !ok;
            printf("%s %s%s %s %s%s %s：%s → 着色器归约逐位相等 %d / %d，平均采样对不上 %d 处（%s）", ok ? "✓" : "✗", kn[kind], var ? "（偏移 1,-1）" : "",
                   red == 1 ? "min" : "max", fnm[c.minf], c.magf ? "" : "、放大最近点", wn[c.wrap], rnat ? "原生归约" : "CPU 手算（本机原生归约不生效）", eq, n, avg, one ? "一个纹素：要 0、表项 0" : "要 > 0");
            if (rnat) printf("，原生 = CPU 手算 %d / %d", cpu_eq, n);
            if (mipn) printf("，旧口径（mip 近邻按两级）对不上 %d 处（要 > 0）", oldd);
            if (first >= 0) printf("；首个不等 u %g v %g lod %g 层 %g：期望 %.9g 着色器 %.9g", P[first][0], P[first][1], P[first][2], P[first][3], rnat ? nat[2 * first] : cpu_red(kind, c, P[first][0], P[first][1], P[first][2], (int)P[first][3], var ? 1 : 0, var ? -1 : 0, white[0]), pl[2 * first + !one]);
            putchar('\n');
        } } }
    // ---- 任意边界色（缺口族 31）：RGBA32Float 8×8、4 级（2D / 2D 数组 2 层），每级每纹素每通道各一个值；采样器夹边框，边界色 C 不是 Metal 三种之一
    //   期望 = CPU 按过滤定义手算（cpu_avg：界内纹素按双线性 / 最近点权重、mip 线性按小数混合，界外权重 × C），容差 1e-5（位置都在 1/256 格点，过滤权重精确，只差浮点舍入）；
    //   真结果 = s2a_bs（表项 1：nvn_red_entry 填、s0 / s1 = 同一采样器的透明黑 / 不透明白边界版）。反证：绑定的采样器（Metal 最近的三种之一 = 改前）对不上 > 0；
    //   零表项时 s2a_bs = 原采样逐位
    {
        static const float C[4] = {0.25f, 0.5f, 0.75f, 0.6f};
        id<MTLComputePipelineState> kb = mk_pipe(dev, lib, "kb"), kbo = mk_pipe(dev, lib, "kbo"), kba = mk_pipe(dev, lib, "kba");
        if (!kb || !kbo || !kba) { printf("✗ 建边界色核失败\n"); return 1; }
        id<MTLBuffer> bt = [dev newBufferWithLength:2 * sizeof(nvn_se_ent) options:MTLResourceStorageModeShared], bz = [dev newBufferWithLength:2 * sizeof(nvn_se_ent) options:MTLResourceStorageModeShared];
        memset(bz.contents, 0, bz.length);
        id<MTLBuffer> b4[2] = {[dev newBufferWithLength:32 * (NSUInteger)n options:MTLResourceStorageModeShared], [dev newBufferWithLength:32 * (NSUInteger)n options:MTLResourceStorageModeShared]};
        static const int BF[6][2] = {{5, 1}, {3, 1}, {1, 1}, {0, 0}, {4, 0}, {2, 1}}, BW[3][2] = {{5, 5}, {5, 1}, {1, 5}};
        for (int kind = 0; kind < 2; kind++) { id<MTLTexture> t = rgba_tex(dev, cq, kind);
          for (int var = 0; var < (kind == 0 ? 2 : 1); var++) { id<MTLComputePipelineState> ps = kind ? kba : var ? kbo : kb;
            for (int fi = 0; fi < 6; fi++) for (int wi = 0; wi < 3; wi++) {
                cfg c = {0, BF[fi][0], BF[fi][1], BW[wi][0]}; int wt = BW[wi][1]; nvn_se_ent q[2]; memset(q, 0, sizeof q);
                int need = nvn_red_entry(1, 0, c.minf, c.magf, c.wrap, wt, c.wrap, 0, 0, 1000, 0, C, &q[1]);
                id<MTLSamplerState> sb = make_samp_(dev, c, wt, C, 0, -1), s0 = make_samp_(dev, c, wt, C, 0, 0), s1 = make_samp_(dev, c, wt, C, 0, 2);
                q[1].s0 = s0.gpuResourceID._impl; q[1].s1 = s1.gpuResourceID._impl; memcpy(bt.contents, q, sizeof q);
                for (int z = 0; z < 2; z++) {   // z 0：表写 C；z 1：零表
                    id<MTLCommandBuffer> cb = [cq commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                    [ce setComputePipelineState:ps]; [ce setTexture:t atIndex:0]; [ce setSamplerState:sb atIndex:0];
                    [ce setBuffer:z ? bz : bt offset:0 atIndex:0]; [ce setBuffer:bp offset:0 atIndex:1]; [ce setBuffer:b4[z] offset:0 atIndex:2];
                    [ce dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake(MIN(n, 64), 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
                }
                const float *o = b4[0].contents, *oz = b4[1].contents; int eq = 0, old = 0, zs = 0, first = -1; float mx = 0;
                for (int i = 0; i < n; i++) { int ok1 = 1, od = 0;
                    for (int ch = 0; ch < 4; ch++) { float x = cpu_avg(kind, c, wt, P[i][0], P[i][1], P[i][2], (int)P[i][3], var ? 1 : 0, var ? -1 : 0, ch, C), d = fabsf(o[8 * i + 4 + ch] - x);
                        mx = d > mx ? d : mx; ok1 &= d <= 1e-5f; od |= fabsf(o[8 * i + ch] - x) > 1e-5f; }
                    eq += ok1; old += od; if (!ok1 && first < 0) first = i;
                    zs += !memcmp(oz + 8 * i, oz + 8 * i + 4, 16); }
                int ok = need && q[1].q[3] == 1 && eq == n && old > 0 && zs == n; fail |= !ok;
                printf("%s 边界色 (0.25,0.5,0.75,0.6) RGBA32Float %s%s %s%s 寻址 s %d t %d：s2a_bs 等于手算 %d / %d（最大差 %.2g，容差 1e-5），改前（Metal 最近的三种之一）对不上 %d 处（要 > 0），"
                       "零表项 = 原采样逐位 %d / %d", ok ? "✓" : "✗", kind ? "2D 数组" : "2D", var ? "（偏移 1,-1）" : "", fnm[c.minf], c.magf ? "" : "、放大最近点", c.wrap, wt, eq, n, mx, old, zs, n);
                if (first >= 0) printf("；首个不等 u %g v %g lod %g 层 %g：期望 R %.9g 着色器 R %.9g", P[first][0], P[first][1], P[first][2], P[first][3],
                                       cpu_avg(kind, c, wt, P[first][0], P[first][1], P[first][2], (int)P[first][3], var ? 1 : 0, var ? -1 : 0, 0, C), o[8 * first + 4]);
                putchar('\n');
            } } }
    }
    return fail;
} }
