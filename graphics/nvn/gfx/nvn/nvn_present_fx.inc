// 直连上屏 MetalFX 空间放大（S2A_SCALING_FILTER=MetalFX，10-30 帧率能耗线）：游戏画面（裁剪后 cw×ch）比它在屏上的视口小时，先拷进本槽输入图（游戏尺寸，
//   与上屏抗锯齿同一步：开了抗锯齿就直接用抗锯齿的输出），MetalFX 放到视口尺寸，再 1:1 拷进可绘制图。替换双线性放大：画质更好，同时是「场景按较低内部分辨率画、
//   上屏放大回来」的放大器（内部比例见宽屏层）。不是放大（视口不比画面大）就照旧双线性。
// 截图 / 满屏判据（grab_present）明确仍按双线性：读的是上屏前的游戏图（自动玩家按它认路线，画质判据比的是游戏图本身，内部比例的差别就在这张图上）；
//   放大不改上屏视口，满屏几何判据不受影响。
// 不链 MetalFX 框架：类按名字从运行时取（首次用时 dlopen 系统框架），没有 MetalFX 的系统 / 设备整段回退双线性并报红一次。
// Metal 4：MetalFX 只有 MTL4FX 接口（编码进 Metal 4 命令缓冲，要一个 Metal 4 编译器）；前后两个上屏编码器的全屏障（enc_full_barrier_begin / _end）保证
//   「拷进输入 → MetalFX → 拷进可绘制图」按序执行。Metal 3：MTLFXSpatialScaler 直接编码进上屏命令缓冲，同一编码顺序。
#import <MetalFX/MetalFX.h>
#include <dlfcn.h>

@interface NvPresentFX : NSObject {
@public
    id<MTLTexture> input, output;
    id scaler;                     // MTLFXSpatialScaler（Metal 3）或 MTL4FXSpatialScaler（Metal 4）
    id<MTLBuffer> cropUV;          // Metal 4 输入拷贝的裁剪参数（同一命令缓冲里最后那次上屏拷贝用槽自己的 g_present_uv）
    id cropTable;
    NSUInteger iw, ih, ow, oh; BOOL m4;
    NSArray<id<MTLResource>> *resources;
    BOOL busy;                     // g_pq_mu 护；只由 GPU 完成回调清
}
@end
@implementation NvPresentFX @end
static NvPresentFX *g_present_fx_slots[4];

static Class present_fx_class(void) {
    static Class c; static int tried;
    if (!tried) {
        tried = 1;
        dlopen("/System/Library/Frameworks/MetalFX.framework/MetalFX", RTLD_LAZY);
        c = NSClassFromString(@"MTLFXSpatialScalerDescriptor");
        if (!c || ![c supportsDevice:g_dev]) { MLOG("【红】 MetalFX 空间放大在这台设备上不可用，上屏按双线性"); c = nil; }
    }
    return c;
}
API_AVAILABLE(macos(26.0), ios(26.0))
static id present_fx_compiler(void) {
    static id comp; static int tried;
    if (!tried) {
        tried = 1; NSError *e = nil;
        comp = [g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        if (!comp) MLOG("【红】 MetalFX：建 Metal 4 编译器失败 %s", e.localizedDescription.UTF8String);
    }
    return comp;
}
// 本槽的放大器与两张图（尺寸 / 后端变了才重建）；nil = 这一帧不用 MetalFX
static NvPresentFX *present_fx_prepare(int slot, NSUInteger iw, NSUInteger ih, NSUInteger ow, NSUInteger oh, BOOL m4) {
    NvPresentFX *old = g_present_fx_slots[slot];
    if (old && old->iw == iw && old->ih == ih && old->ow == ow && old->oh == oh && old->m4 == m4) return old;
    Class dc = present_fx_class();
    if (!dc) return nil;
    MTLFXSpatialScalerDescriptor *d = [dc new];
    d.inputWidth = iw; d.inputHeight = ih; d.outputWidth = ow; d.outputHeight = oh;
    d.colorTextureFormat = MTLPixelFormatBGRA8Unorm; d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;   // 上屏拷的是存储原字节（sRGB 编码值，present_raw_src），按感知空间处理
    id sc = nil;
    if (m4) { if (@available(macOS 26.0, iOS 26.0, *)) { id comp = present_fx_compiler(); if (comp) sc = [d newSpatialScalerWithDevice:g_dev compiler:comp]; } }
    else sc = [d newSpatialScalerWithDevice:g_dev];
    if (!sc) { RED_ONCE(71, "MetalFX：建空间放大器失败（%lux%lu → %lux%lu），上屏按双线性", (unsigned long)iw, (unsigned long)ih, (unsigned long)ow, (unsigned long)oh); return nil; }
    // Metal 4：放大器必须带栅栏（开 Metal 校验层时不带就断言 `_outputTextureBarrierStages not set`，公开接口里没有设屏障阶段的入口；10-30 本机实测带栅栏即过）。
    //   前后顺序仍由上屏编码器的队列级全屏障保证，栅栏只给 MetalFX 自己内部用
    if (m4) [(id<MTLFXSpatialScalerBase>)sc setFence:[g_dev newFence]];
    NvPresentFX *f = [NvPresentFX new];
    f->scaler = sc; f->iw = iw; f->ih = ih; f->ow = ow; f->oh = oh; f->m4 = m4;
    MTLTextureUsage cu = [(id<MTLFXSpatialScalerBase>)sc colorTextureUsage], ou = [(id<MTLFXSpatialScalerBase>)sc outputTextureUsage];
    f->input = present_aa_texture(MTLPixelFormatBGRA8Unorm, iw, ih, cu | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    f->output = present_aa_texture(MTLPixelFormatBGRA8Unorm, ow, oh, ou | MTLTextureUsageShaderRead);
    f->cropUV = [g_dev newBufferWithLength:8 * sizeof(float) options:MTLResourceStorageModeShared];
    if (!f->input || !f->output || !f->cropUV) { MLOG("【红】 MetalFX：图 / 缓冲分配失败"); return nil; }
    NSError *error = nil;
    if (!g_m3) { f->cropTable = tab_new(1, 1, 1, &error); if (!f->cropTable) { MLOG("【红】 MetalFX 参数表：%s", error.localizedDescription.UTF8String); return nil; } }
    // 调用方已等过本槽自己的 GPU 完成（busy），旧图可以退驻留
    if (old) for (id<MTLResource> r in old->resources) res_remove(r);
    f->resources = @[f->input, f->output, f->cropUV];
    for (id<MTLResource> r in f->resources) res_add(r);
    g_present_fx_slots[slot] = f;
    MLOG("直连上屏 MetalFX 空间放大：%lux%lu → %lux%lu（%s）", (unsigned long)iw, (unsigned long)ih, (unsigned long)ow, (unsigned long)oh, m4 ? "Metal 4" : "Metal 3");
    return f;
}
// 这一帧要不要 MetalFX、放到多大：画面（裁剪后）cw×ch 在可绘制图 dw×dh 上的视口比画面大才放大
static NvPresentFX *present_fx_for(int slot, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], BOOL m4) {
    if (!g_present_fx) return nil;
    double cw = crop && (crop[2] || crop[3]) ? crop[2] : (double)src.width, ch = crop && (crop[2] || crop[3]) ? crop[3] : (double)src.height;
    double ca = s2a_cpatch_present_aspect();   // 自适应画幅补丁开着：视口按当前画幅拉满（同 nvn_mtl.m present_blit）
    pf_vp pv = ca > 0 ? pf_viewport(dst.width, dst.height, ca, 1) : pf_viewport(dst.width, dst.height, cw, ch);
    NSUInteger ow = (NSUInteger)pv.w, oh = (NSUInteger)pv.h;
    if (ow <= (NSUInteger)cw + 1 && oh <= (NSUInteger)ch + 1) return nil;
    return present_fx_prepare(slot, (NSUInteger)cw, (NSUInteger)ch, ow, oh, m4);
}
// in（游戏尺寸，内容已就位）→ f->output（视口尺寸）
static void present_fx_encode(id cb, NvPresentFX *f, id<MTLTexture> in) {
    id<MTLFXSpatialScalerBase> s = f->scaler;
    s.colorTexture = in; s.outputTexture = f->output;
    s.inputContentWidth = f->iw; s.inputContentHeight = f->ih;
    [(id)s encodeToCommandBuffer:cb];
}
