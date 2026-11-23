// 绘制与编码（分片「绘制」，#272）。本层自己的经典 Metal 队列（Metal 3 / 4 都能跑）：一帧一个命令缓冲，交换 / glFlush / glFinish 时提交并 signal 本层共享事件。
// 渲染编码器按「当前帧缓冲」开，帧缓冲变了或要清屏时收。存储按 GL 行序（第 0 行在底）：视口高度取负，视口 / 裁剪直接用 GL 坐标，上屏翻转（egl.m）。
// 最小集：glDrawArrays / glDrawElements、glFlush / glFinish；顶点格式 float / half / (u)byte / (u)short / (u)int ×1–4、归一化 10:10:10:2 打包；关掉的数组读常量 (0,0,0,1)；
// 八路颜色附件与各路单源混合 / 写掩码、深度 / 模板测试、多边形偏移、剔除；目标按 FBO 路由解析（颜色可全空）。
// 另：实例绘制（glDrawElementsInstanced + glVertexAttribDivisor）、多重采样目标（管线光栅样本数随附件）、查询对象（遮挡 = Metal 可见性计数、
//   经过时间 = 命令缓冲 GPU 时间、生成图元数 = 按绘制参数精确计数）、同步对象（栅栏 = 本层共享事件的提交序号）。
#include "gl_int.h"
#include <errno.h>
#include <unistd.h>
const char gl_slice_gl_draw = 1;   // 分片锚（gl_core.m 引用：静态链接时整片进来，见 gl_int.h「分片锚」）

enum { GL_POINTS = 0, GL_LINES = 1, GL_LINE_STRIP = 3, GL_TRIANGLES = 4, GL_TRIANGLE_STRIP = 5, GL_TRIANGLE_FAN = 6, GL_BYTE = 0x1400, GL_UNSIGNED_BYTE = 0x1401, GL_SHORT = 0x1402,
       GL_UNSIGNED_SHORT = 0x1403, GL_INT = 0x1404, GL_UNSIGNED_INT = 0x1405, GL_HALF_FLOAT = 0x140B,
       GL_UNSIGNED_INT_2_10_10_10_REV = 0x8368, GL_INT_2_10_10_10_REV = 0x8D9F,
       GL_FLOAT = 0x1406, GL_DEPTH_BUFFER_BIT = 0x100, GL_STENCIL_BUFFER_BIT = 0x400, GL_COLOR_BUFFER_BIT = 0x4000, GL_FRONT = 0x0404, GL_BACK = 0x0405, GL_FRONT_AND_BACK = 0x0408, GL_CW = 0x0900,
       GL_INVALID_ENUM = 0x0500, GL_INVALID_VALUE = 0x0501, GL_INVALID_OPERATION = 0x0502, GL_OUT_OF_MEMORY = 0x0505 };
#define CTX(ret) do { if (!gl_cur) { GLRED1("%s：没有当前上下文", __func__); return ret; } } while (0)
void s2a_direct_gpu_error(const char *desc);   // graphics/nvn/host_adapt.m：GPU 报错 → 直连异常（打红行，不切换）
int mtl_gpu_go(void); int mtl_gpu_cb_error(NSError *e, const char *where, uint64_t seq);   // nvn_mtl.m：GPU 安全停的门与唯一判定点（11-07）

id<MTLDevice> gl_dev; id<MTLSharedEvent> gl_ev;
static id<MTLCommandQueue> g_q; static id<MTLCommandBuffer> g_cb; static id<MTLRenderCommandEncoder> g_re; static id<MTLBlitCommandEncoder> g_be;
static gl_target g_rt;            // 开着的渲染编码器目标快照，按片元输出排列
static uint64_t g_ev_val;
static _Atomic uint64_t g_done;
static _Atomic int g_stopping;
static dispatch_group_t g_completions;
static GLbitfield g_pend;         // 挂起的清除（下一遍以清除开），只属于 g_pt 这组附件
static gl_target g_pt;            // 清除调用时的完整附件快照；路由随后变化也不串目标
static float g_pc[GL_COLOR_TARGETS][4], g_pd; static int g_ps; static uint32_t g_pend_colors;
static NSMutableDictionary *g_dss;
static NSMutableDictionary *g_clear_pso, *g_clear_dss;
static id<MTLLibrary> g_clear_lib;
#include "gl_widen.inc"   // 宽屏第三层（缺省开，S2A_WIDEN_DIRECT=0 关）
// DrawArrays 共用以 0 为锚的索引前缀，只增不减；first 由绘制时的 baseVertex 带入。
static id<MTLBuffer> g_array_fan;
static GLsizei g_array_fan_count;
// 遮挡查询：Metal 可见性结果缓冲（每格 8 字节样本计数）。查询活动期间每开一遍 / 每次查询起止都换一格新格（同一格只在一遍里计数），
//   查询的结果 = 它起止之间各格之和；格按单调序号环形复用（VIS_N 格），复用前把还没取结果、又覆盖到这格的查询先结算
enum { VIS_N = 65536, CBT_N = 4096 };
static id<MTLBuffer> g_vis; static uint64_t g_vis_next, g_vis_seq[VIS_N]; static int g_occ, g_re_vis;   // g_occ：活动的遮挡查询个数；g_re_vis：开着的渲染编码器带可见性缓冲
static double g_cbt[CBT_N][2];   // 第 v 次提交的命令缓冲 GPU 起止时间（秒，完成回调写；经过时间查询用）
static uint64_t g_prims;         // 已发出绘制的图元总数（生成图元数查询用）
static void vis_slot(id<MTLRenderCommandEncoder> re);
static void gl_query_session_reset(void);

void gl_dev_init(void) {
    if (g_q) return;
    gl_dev = (__bridge id<MTLDevice>)mtl_device(); g_q = [gl_dev newCommandQueueWithMaxCommandBufferCount:64];
    g_q.label = @"gl"; gl_ev = [gl_dev newSharedEvent]; g_dss = [NSMutableDictionary new];
    g_completions = dispatch_group_create();
}
id<MTLCommandBuffer> gl_cmd(void) { gl_dev_init(); if (!g_cb) g_cb = [g_q commandBuffer]; return g_cb; }
void gl_buffer_ref(struct gl_buffer *b) { b->last_use = g_ev_val + 1; }
uint64_t gl_seq_ref(void) { return g_ev_val + 1; }
int gl_seq_busy(uint64_t seq) { return seq > atomic_load_explicit(&g_done, memory_order_acquire); }
int gl_buffer_busy(const struct gl_buffer *b) { return b->last_use > atomic_load_explicit(&g_done, memory_order_acquire); }
void gl_end_enc(void) { if (g_re) { [g_re endEncoding]; g_re = nil; g_rt = (gl_target){0}; g_re_vis = 0; } if (g_be) { [g_be endEncoding]; g_be = nil; } }
static int same_target(const gl_target *a, const gl_target *b) {
    if (a->dep != b->dep || a->sten != b->sten || a->w != b->w || a->h != b->h || a->fb != b->fb) return 0;
    for (int i = 0; i < GL_COLOR_TARGETS; i++) if (a->col[i] != b->col[i]) return 0;
    return 1;
}
// 目标的样本数（多重采样渲染缓冲）：各附件一致由帧缓冲完整性保证（gl_fb.m fb_status）
static NSUInteger rt_samples(const gl_target *t) {
    for (int i = 0; i < GL_COLOR_TARGETS; i++) if (t->col[i]) return t->col[i].sampleCount;
    return t->dep ? t->dep.sampleCount : t->sten ? t->sten.sampleCount : 1;
}
static int has_color(const gl_target *t) { for (int i = 0; i < GL_COLOR_TARGETS; i++) if (t->col[i]) return 1; return 0; }
static uint32_t color_id(const gl_target *t) { for (int i = 0; i < GL_COLOR_TARGETS; i++) if (t->col[i]) return t->cid[i]; return 0; }
static id<MTLRenderCommandEncoder> open_pass(const gl_target *t) {
    int clr = g_pend && same_target(t, &g_pt); GLbitfield pend = clr ? g_pend : 0;
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
    // GL 的有效区域是全部附件的交集；NONE 全关时仍需要一个有效的光栅样本数。
    d.renderTargetWidth = t->w; d.renderTargetHeight = t->h; d.defaultRasterSampleCount = rt_samples(t);
    if (g_occ) d.visibilityResultBuffer = g_vis;   // 遮挡查询活动：本遍计数（开遍后 vis_slot 设计数格）
    for (int i = 0; i < GL_COLOR_TARGETS; i++) if (t->col[i]) {
        d.colorAttachments[i].texture = t->col[i]; d.colorAttachments[i].storeAction = MTLStoreActionStore;
        d.colorAttachments[i].loadAction = (pend & GL_COLOR_BUFFER_BIT) && (g_pend_colors & (1u << i)) ? MTLLoadActionClear : MTLLoadActionLoad;
        d.colorAttachments[i].clearColor = MTLClearColorMake(g_pc[i][0], g_pc[i][1], g_pc[i][2], g_pc[i][3]);
    }
    if (t->dep && t->fake_dep) { d.depthAttachment.texture = t->dep; d.depthAttachment.loadAction = MTLLoadActionDontCare; d.depthAttachment.storeAction = MTLStoreActionDontCare; }
    else if (t->dep) {
        d.depthAttachment.texture = t->dep; d.depthAttachment.storeAction = MTLStoreActionStore; d.depthAttachment.clearDepth = g_pd;
        d.depthAttachment.loadAction = pend & GL_DEPTH_BUFFER_BIT ? MTLLoadActionClear : MTLLoadActionLoad;
    }
    if (t->sten) {
        d.stencilAttachment.texture = t->sten; d.stencilAttachment.storeAction = MTLStoreActionStore; d.stencilAttachment.clearStencil = (uint32_t)g_ps & 0xff;
        d.stencilAttachment.loadAction = pend & GL_STENCIL_BUFFER_BIT ? MTLLoadActionClear : MTLLoadActionLoad;
    }
    if (clr) { g_pend = 0; g_pend_colors = 0; g_pt = (gl_target){0}; }
    gl_n_passes++;
    g_re = [gl_cmd() renderCommandEncoderWithDescriptor:d]; g_rt = *t; g_re_vis = g_occ != 0;
    if (g_re_vis) vis_slot(g_re);
    wd_targets(color_id(t), t->did);   // 宽屏核心目前按一个主颜色目标判画法
    if (gl_cur) gl_cur->dirty = ~0u;   // 新编码器：状态全部重设
    return g_re;
}
// 挂起的清除属于别的附件组（清完换了帧缓冲、没画就走）：单独开一遍兑现
static void flush_pend(void) {
    if (!g_pend) return;
    gl_target t = g_pt;
    gl_end_enc(); open_pass(&t); gl_end_enc();
}
// 假深度：GL 目标没有深度附件、程序的片元写 gl_FragDepth 时挂一张同尺寸的私有深度贴图（Metal 不许写深度的管线没有深度附件；GL 没深度缓冲时深度写入直接作废）。
//   按尺寸缓存一张，开遍不读不存；深度测试恒过、不写（dss）。FINAL FANTASY VII：每帧主画面那几笔写深度、目标没深度，原先建管线失败整帧黑
static id<MTLTexture> fake_depth(NSUInteger w, NSUInteger h, NSUInteger samples) {
    static id<MTLTexture> cache[4]; int k = samples >= 8 ? 3 : samples >= 4 ? 2 : samples >= 2 ? 1 : 0; id<MTLTexture> t = cache[k];   // 按样本数各一张（Metal 要求附件样本数一致）
    if (!t || t.width < w || t.height < h) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:MAX(w, t ? t.width : 0) height:MAX(h, t ? t.height : 0) mipmapped:NO];
        if (samples > 1) { d.textureType = MTLTextureType2DMultisample; d.sampleCount = samples; }
        d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate; t = cache[k] = [gl_dev newTextureWithDescriptor:d];
    }
    return t;
}
id<MTLRenderCommandEncoder> gl_render_enc(void) {
    gl_target t; if (!gl_draw_target(&t)) return nil;
    if (!t.dep && gl_cur) { struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog); if (p && p->writes_depth) { t.dep = fake_depth(t.w, t.h, rt_samples(&t)); t.fake_dep = 1; } }
    if (g_pend && !same_target(&t, &g_pt)) flush_pend();
    if (g_re && same_target(&t, &g_rt) && !g_pend) return g_re;
    gl_end_enc(); return open_pass(&t);
}
id<MTLBlitCommandEncoder> gl_blit_enc(void) {
    flush_pend();   // 拷贝必须看到此前 glClear 的内容，即使还没开过渲染遍。
    if (g_re) gl_end_enc(); if (!g_be) g_be = [gl_cmd() blitCommandEncoder]; return g_be;
}
static MTLColorWriteMask color_mask(int i) {
    const GLboolean *mask = gl_cur->color[i].mask;
    return (mask[0] ? MTLColorWriteMaskRed : 0) | (mask[1] ? MTLColorWriteMaskGreen : 0) |
           (mask[2] ? MTLColorWriteMaskBlue : 0) | (mask[3] ? MTLColorWriteMaskAlpha : 0);
}
// GL 行序存储：裁剪坐标直接对应贴图行。先夹到附件边界，负坐标不转换成 NSUInteger。
static MTLScissorRect scissor_rect(NSUInteger width, NSUInteger height) {
    if (!(gl_cur->enable & GLE_SCISSOR)) return (MTLScissorRect){0, 0, width, height};
    int64_t x0 = gl_cur->sc[0], y0 = gl_cur->sc[1];
    int64_t x1 = x0 + gl_cur->sc[2], y1 = y0 + gl_cur->sc[3];
    x0 = MAX(0, MIN(x0, (int64_t)width)); x1 = MAX(0, MIN(x1, (int64_t)width));
    y0 = MAX(0, MIN(y0, (int64_t)height)); y1 = MAX(0, MIN(y1, (int64_t)height));
    return (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
}
static MTLPixelFormat fmt_of(id<MTLTexture> t) { return t ? t.pixelFormat : MTLPixelFormatInvalid; }
static id<MTLRenderPipelineState> clear_pipeline(const gl_target *t, const MTLColorWriteMask writes[GL_COLOR_TARGETS]) {
    gl_dev_init();
    if (!g_clear_pso) { g_clear_pso = [NSMutableDictionary new]; g_clear_dss = [NSMutableDictionary new]; }
    NSMutableString *key = [NSMutableString stringWithFormat:@"%lu:%lu:s%lu", (unsigned long)fmt_of(t->dep), (unsigned long)fmt_of(t->sten), (unsigned long)rt_samples(t)];
    for (int i = 0; i < GL_COLOR_TARGETS; i++) if (t->col[i])
        [key appendFormat:@"|c%d:%lu:%lu", i, (unsigned long)fmt_of(t->col[i]), (unsigned long)writes[i]];
    id hit = g_clear_pso[key]; if (hit) return hit == NSNull.null ? nil : hit;   // 建失败存 NSNull：同一组合不再每笔重建（11-01）
    id<MTLRenderPipelineState> ps;
    NSError *error = nil;
    if (!g_clear_lib) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 gl_clear_v(uint i [[vertex_id]], constant float &z [[buffer(0)]]) {"
            " const float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],z,1); }\n"
            "struct gl_clear_out { float4 c0 [[color(0)]], c1 [[color(1)]], c2 [[color(2)]], c3 [[color(3)]],"
            " c4 [[color(4)]], c5 [[color(5)]], c6 [[color(6)]], c7 [[color(7)]]; };\n"
            "fragment gl_clear_out gl_clear_f(constant float4 &c [[buffer(0)]]) { return {c,c,c,c,c,c,c,c}; }\n";
        g_clear_lib = [gl_dev newLibraryWithSource:src options:nil error:&error];
        if (!g_clear_lib) { GLOG("【红】 清除辅助着色器编译失败：%s", error.localizedDescription.UTF8String); return nil; }
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [g_clear_lib newFunctionWithName:@"gl_clear_v"]; pd.fragmentFunction = has_color(t) ? [g_clear_lib newFunctionWithName:@"gl_clear_f"] : nil;
    for (int i = 0; i < GL_COLOR_TARGETS; i++) {
        pd.colorAttachments[i].pixelFormat = fmt_of(t->col[i]); pd.colorAttachments[i].writeMask = writes[i];
    }
    pd.depthAttachmentPixelFormat = fmt_of(t->dep); pd.stencilAttachmentPixelFormat = fmt_of(t->sten); pd.rasterSampleCount = rt_samples(t);
    ps = [gl_dev newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!ps) { GLOG("【红】 清除管线创建失败：%s", error.localizedDescription.UTF8String); g_clear_pso[key] = NSNull.null; return nil; }
    g_clear_pso[key] = ps; return ps;
}
static id<MTLDepthStencilState> clear_depth_stencil(GLbitfield mask) {
    BOOL depth = (mask & GL_DEPTH_BUFFER_BIT) != 0;
    uint32_t stencil = mask & GL_STENCIL_BUFFER_BIT ? gl_cur->stencil_wmask[0] & 0xff : 0;
    NSNumber *key = @(depth | (stencil << 1)); id<MTLDepthStencilState> state = g_clear_dss[key]; if (state) return state;
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = MTLCompareFunctionAlways; d.depthWriteEnabled = depth;
    if (stencil) {
        MTLStencilDescriptor *s = [MTLStencilDescriptor new]; s.stencilCompareFunction = MTLCompareFunctionAlways;
        s.depthStencilPassOperation = MTLStencilOperationReplace; s.writeMask = stencil;
        d.frontFaceStencil = s; d.backFaceStencil = s;
    }
    state = [gl_dev newDepthStencilStateWithDescriptor:d];
    if (!state) { GLOG("【红】 清除深度模板状态创建失败"); return nil; }
    g_clear_dss[key] = state; return state;
}
// 宽屏原比例回退（widen_fallback.inc wd_fb_want_self）：游戏这帧不清世界目标、直接画（植物大战僵尸加载页一类），第一笔之前把颜色附件 0 的两侧带写成哨兵
//   （黑、alpha WD_P2_DA），帧末采样看游戏有没有画到；同 wd_page_clear 走清除辅助管线，之后 setup 照常设这笔的全部状态
static void wd_self_sentinel(id<MTLRenderCommandEncoder> re) {
    int i0 = -1; for (int i = 0; i < GL_COLOR_TARGETS && i0 < 0; i++) if (g_rt.col[i]) i0 = i;
    uint32_t r5[5]; if (i0 < 0 || !wd_fb_want_self(g_rt.cid[i0], g_rt.col[i0], r5)) return;
    const float sent[4] = {0, 0, 0, (float)WD_P2_DA}; static const float z = 0;
    MTLColorWriteMask writes[GL_COLOR_TARGETS] = {MTLColorWriteMaskNone}; writes[i0] = MTLColorWriteMaskAll;
    id<MTLRenderPipelineState> ps = clear_pipeline(&g_rt, writes); id<MTLDepthStencilState> ds = clear_depth_stencil(0);
    if (!ps || !ds) return;
    [re setRenderPipelineState:ps]; [re setDepthStencilState:ds]; [re setCullMode:MTLCullModeNone]; [re setDepthBias:0 slopeScale:0 clamp:0];
    [re setViewport:(MTLViewport){0, 0, g_rt.w, g_rt.h, 0, 1}];
    [re setVertexBytes:&z length:sizeof z atIndex:0]; [re setFragmentBytes:sent length:sizeof sent atIndex:0];
    if (g_re_vis) [re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    uint32_t xs[2] = {r5[0], r5[0] + r5[1] - r5[4]};
    for (int k = 0; k < 2; k++) { NSUInteger x = xs[k], w = r5[4], y = r5[2], h = r5[3];
        if (x >= g_rt.w || y >= g_rt.h) continue; if (x + w > g_rt.w) w = g_rt.w - x; if (y + h > g_rt.h) h = g_rt.h - y;
        [re setScissorRect:(MTLScissorRect){x, y, w, h}]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    if (g_re_vis) vis_slot(re);
}
// 宽屏：本笔起 16:9 原比例页（s2a_widen_page_sides）——画这笔前把颜色附件两侧条带整高清成全 0（同通用模式 ClearCols），走清除辅助管线；之后 setup 照常设这笔的全部状态
static void wd_page_clear(id<MTLRenderCommandEncoder> re) {
    g_wd_side_on = 0;
    if (!has_color(&g_rt)) return;
    static const float zero[4] = {0, 0, 0, 0}; static const float z = 0;
    MTLColorWriteMask writes[GL_COLOR_TARGETS]; for (int i = 0; i < GL_COLOR_TARGETS; i++) writes[i] = MTLColorWriteMaskAll;
    id<MTLRenderPipelineState> ps = clear_pipeline(&g_rt, writes); id<MTLDepthStencilState> ds = clear_depth_stencil(0);
    if (!ps || !ds) return;
    [re setRenderPipelineState:ps]; [re setDepthStencilState:ds]; [re setCullMode:MTLCullModeNone]; [re setDepthBias:0 slopeScale:0 clamp:0];
    [re setViewport:(MTLViewport){0, 0, g_rt.w, g_rt.h, 0, 1}];
    [re setVertexBytes:&z length:sizeof z atIndex:0]; [re setFragmentBytes:zero length:sizeof zero atIndex:0];
    if (g_re_vis) [re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];   // 清除不计入遮挡查询（GL 只数绘制的样本）
    for (int i = 0; i < 4; i += 2) {
        long x0 = g_wd_sides[i] < 0 ? 0 : g_wd_sides[i], x1 = g_wd_sides[i + 1] > (long)g_rt.w ? (long)g_rt.w : g_wd_sides[i + 1];
        if (x1 > x0) { [re setScissorRect:(MTLScissorRect){(NSUInteger)x0, 0, (NSUInteger)(x1 - x0), g_rt.h}]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    }
    if (g_re_vis) vis_slot(re);
}
void gl_clear(GLbitfield mask) {
    gl_target t; if (!mask || !gl_draw_target(&t)) return;
    MTLColorWriteMask writes[GL_COLOR_TARGETS]; uint32_t color_bits = 0; int full_writes = 1;
    for (int i = 0; i < GL_COLOR_TARGETS; i++) {
        writes[i] = t.col[i] && (mask & GL_COLOR_BUFFER_BIT) ? color_mask(i) : MTLColorWriteMaskNone;
        if (writes[i]) color_bits |= 1u << i;
        if (writes[i] && writes[i] != MTLColorWriteMaskAll) full_writes = 0;
    }
    if (!color_bits) mask &= ~(GLbitfield)GL_COLOR_BUFFER_BIT;
    if (!t.dep) mask &= ~(GLbitfield)GL_DEPTH_BUFFER_BIT;
    if (!t.sten) mask &= ~(GLbitfield)GL_STENCIL_BUFFER_BIT;
    MTLScissorRect rect = scissor_rect(t.w, t.h); uint32_t cid = color_id(&t); long guest_w = (long)rect.width;   // 换算前的客体裁剪宽（原比例回退的剪裁清屏哨兵用）
    if (gl_cur->enable & GLE_SCISSOR) wd_map_clear(cid ? cid : t.did, &rect, t.w, t.h);
    if (!mask || !rect.width || !rect.height) return;
    BOOL full = rect.x == 0 && rect.y == 0 && rect.width == t.w && rect.height == t.h;
    // loadAction 清整张附件；GL 只能清共同有效区域，尺寸不等时走裁剪绘制。
    for (int i = 0; i < GL_COLOR_TARGETS; i++) if (writes[i] && (t.col[i].width != t.w || t.col[i].height != t.h)) full = NO;
    if ((mask & GL_DEPTH_BUFFER_BIT) && (t.dep.width != t.w || t.dep.height != t.h)) full = NO;
    if ((mask & GL_STENCIL_BUFFER_BIT) && (t.sten.width != t.w || t.sten.height != t.h)) full = NO;
    if (full && full_writes &&
        (!(mask & GL_STENCIL_BUFFER_BIT) || (gl_cur->stencil_wmask[0] & 0xff) == 0xff)) {
        if (g_pend && !same_target(&t, &g_pt)) flush_pend();
        gl_end_enc(); g_pend |= mask;
        g_pt = t; g_pend_colors |= color_bits;
        for (int i = 0; i < GL_COLOR_TARGETS; i++) if (color_bits & (1u << i)) { memcpy(g_pc[i], gl_cur->clear_color, sizeof g_pc[i]); wd_fb_gl_clear_full(&t, i, g_pc[i]); }   // 宽屏原比例回退：世界目标的清屏 alpha 挪成哨兵
        if (mask & GL_DEPTH_BUFFER_BIT) g_pd = gl_cur->clear_depth;
        if (mask & GL_STENCIL_BUFFER_BIT) g_ps = gl_cur->clear_stencil;
        return;
    }
    id<MTLRenderPipelineState> ps = clear_pipeline(&t, writes);
    if (!ps) { gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return; }
    id<MTLDepthStencilState> ds = clear_depth_stencil(mask);
    if (!ds) { gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return; }
    id<MTLRenderCommandEncoder> re = gl_render_enc();
    if (!re) { GLOG("【红】 清除没有绘制目标"); gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return; }
    // 先兑现挂起的整屏清除；当前值由 setBytes 当场复制，不受随后修改 clear 状态影响。
    [re setRenderPipelineState:ps]; [re setDepthStencilState:ds]; [re setCullMode:MTLCullModeNone]; [re setDepthBias:0 slopeScale:0 clamp:0];
    [re setViewport:(MTLViewport){0, 0, t.w, t.h, 0, 1}]; [re setScissorRect:rect];
    [re setStencilReferenceValue:(uint32_t)gl_cur->clear_stencil & 0xff];   // GL 取附件位数的低位；Metal 的 reference 超范围会饱和。
    [re setVertexBytes:&gl_cur->clear_depth length:sizeof gl_cur->clear_depth atIndex:0];
    if (has_color(&t)) { float cc[4]; memcpy(cc, gl_cur->clear_color, sizeof cc);
        if (mask & GL_COLOR_BUFFER_BIT) wd_fb_gl_clear_rect(&t, cc, full_writes, rect, guest_w);   // 宽屏原比例回退：世界目标的剪裁清屏也放哨兵
        [re setFragmentBytes:cc length:sizeof cc atIndex:0]; }
    if (g_re_vis) [re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];   // 清除不计入遮挡查询
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (g_re_vis) vis_slot(re);
    // 不切遍：清除不计游戏 draw；下一笔绘制在 setup 里重设管线 / 深度模板 / 视口 / 裁剪 / 模板参考值 / 深度偏移。
}
uint64_t gl_commit(void) {
    if (gl_session_stopping()) return g_ev_val;
    flush_pend();   // 只清不画的一帧：清除也要落到贴图上
    gl_end_enc();
    id<MTLCommandBuffer> cb = gl_cmd(); uint64_t v = ++g_ev_val;
    [cb encodeSignalEvent:gl_ev value:v];
    // GPU 安全停：先判再挂回调（D-TMM9）。原先先 enter + 挂完成回调、停了再手动 leave，可不交的命令缓冲释放时 Metal 照样调完成回调，
    //   同一次 enter 被 leave 两次 → dispatch_group_leave 陷阱（信号 5）。停了就不进组、不挂回调、不交
    if (!mtl_gpu_go()) { g_cb = nil; return v; }
    dispatch_group_t completions = g_completions;
    dispatch_group_enter(completions);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        if (c.error && !mtl_gpu_cb_error(c.error, "gl", v)) { GLOG("【红】 命令缓冲报错（第 %llu 次提交）：%s", (unsigned long long)v, c.error.localizedDescription.UTF8String); s2a_direct_gpu_error(c.error.localizedDescription.UTF8String); }
        g_cbt[v % CBT_N][0] = c.GPUStartTime; g_cbt[v % CBT_N][1] = c.GPUEndTime;   // 先写时间再发布完成序号（读方 acquire g_done 后读）
        // 同一队列按提交顺序执行；完成回调即使交错，也不能把完成序号退回。
        uint64_t done = atomic_load_explicit(&g_done, memory_order_relaxed);
        while (done < v && !atomic_compare_exchange_weak_explicit(&g_done, &done, v, memory_order_release, memory_order_relaxed)) {}
        dispatch_group_leave(completions);
    }];
    [cb commit];
    g_cb = nil;
    return v;
}
_Atomic uint64_t gl_wait_n, gl_wait_ns;
void gl_wait(uint64_t v) {
    if (!v || gl_ev.signaledValue >= v) return;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    while (!gl_session_stopping() && gl_ev.signaledValue < v && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0 < 5000000000ull)
        [gl_ev waitUntilSignaledValue:v timeoutMS:50];
    if (!gl_session_stopping() && gl_ev.signaledValue < v) GLOG("【红】 等 GPU 超过 5 秒（第 %llu 次提交）", (unsigned long long)v);
    gl_wait_n++; gl_wait_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
}
void dm_gl_drain(void) { if (gl_ev) gl_wait(g_ev_val); }
int gl_session_stopping(void) { return atomic_load(&g_stopping); }
int dm_gl_request_stop(void) { atomic_store(&g_stopping, 1); return 0; }
int dm_gl_shutdown_session(void) {
    // Caller has joined every guest thread and drained the shared present queue.
    // The shared event can signal before completion handlers finish. Wait for
    // those handlers too, so none can touch counters or report an old GPU error
    // after the next session starts. On timeout retain all resources.
    if (!gl_session_stopping()) return -EBUSY;
    if (g_completions && dispatch_group_wait(g_completions, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) return -ETIMEDOUT;
    gl_end_enc(); g_cb = nil; g_pend = 0; g_pt = (gl_target){0}; g_rt = (gl_target){0};
    gl_egl_session_reset(); gl_fb_session_reset(); gl_tex_session_reset();
    gl_prog_session_reset(); gl_buf_session_reset(); wd_session_reset();
    g_q = nil; gl_ev = nil; gl_dev = nil; g_completions = nil;
    g_dss = nil; g_clear_pso = nil; g_clear_dss = nil; g_clear_lib = nil;
    g_array_fan = nil; g_array_fan_count = 0;
    gl_query_session_reset(); g_vis = nil; g_vis_next = 0; memset(g_vis_seq, 0, sizeof g_vis_seq); g_occ = g_re_vis = 0; g_prims = 0;
    g_pend_colors = 0;
    memset(g_pc, 0, sizeof g_pc); g_pd = 0; g_ps = 0;
    g_ev_val = 0; atomic_store(&g_done, 0);
    gl_n_frames = gl_n_draws = gl_n_passes = gl_bad_feat = gl_bad_err = gl_wait_n = gl_wait_ns = 0;
    atomic_store(&g_stopping, 0);
    return 0;
}
GLB(glFlush, void, void) { @autoreleasepool { CTX(); gl_commit(); }}
GLB(glFinish, void, void) { @autoreleasepool { CTX(); gl_wait(gl_commit()); }}

// ---------- 管线 ----------
static MTLVertexFormat vfmt(const gl_attrib *a) {
    int n = a->size, no = a->norm != 0;
    static const MTLVertexFormat fl[] = {MTLVertexFormatFloat, MTLVertexFormatFloat2, MTLVertexFormatFloat3, MTLVertexFormatFloat4},
        hf[] = {MTLVertexFormatHalf, MTLVertexFormatHalf2, MTLVertexFormatHalf3, MTLVertexFormatHalf4},
        ub[] = {MTLVertexFormatUChar, MTLVertexFormatUChar2, MTLVertexFormatUChar3, MTLVertexFormatUChar4},
        ubn[] = {MTLVertexFormatUCharNormalized, MTLVertexFormatUChar2Normalized, MTLVertexFormatUChar3Normalized, MTLVertexFormatUChar4Normalized},
        sb[] = {MTLVertexFormatChar, MTLVertexFormatChar2, MTLVertexFormatChar3, MTLVertexFormatChar4},
        sbn[] = {MTLVertexFormatCharNormalized, MTLVertexFormatChar2Normalized, MTLVertexFormatChar3Normalized, MTLVertexFormatChar4Normalized},
        us[] = {MTLVertexFormatUShort, MTLVertexFormatUShort2, MTLVertexFormatUShort3, MTLVertexFormatUShort4},
        usn[] = {MTLVertexFormatUShortNormalized, MTLVertexFormatUShort2Normalized, MTLVertexFormatUShort3Normalized, MTLVertexFormatUShort4Normalized},
        ss[] = {MTLVertexFormatShort, MTLVertexFormatShort2, MTLVertexFormatShort3, MTLVertexFormatShort4},
        ssn[] = {MTLVertexFormatShortNormalized, MTLVertexFormatShort2Normalized, MTLVertexFormatShort3Normalized, MTLVertexFormatShort4Normalized},
        ui[] = {MTLVertexFormatUInt, MTLVertexFormatUInt2, MTLVertexFormatUInt3, MTLVertexFormatUInt4},
        si[] = {MTLVertexFormatInt, MTLVertexFormatInt2, MTLVertexFormatInt3, MTLVertexFormatInt4};
    if (n < 1 || n > 4) return MTLVertexFormatInvalid;
    switch (a->type) {
        case GL_FLOAT: return fl[n - 1];
        case GL_HALF_FLOAT: return hf[n - 1];
        case GL_UNSIGNED_BYTE: return no ? ubn[n - 1] : ub[n - 1];
        case GL_BYTE: return no ? sbn[n - 1] : sb[n - 1];
        case GL_UNSIGNED_SHORT: return no ? usn[n - 1] : us[n - 1];
        case GL_SHORT: return no ? ssn[n - 1] : ss[n - 1];
        case GL_UNSIGNED_INT: return no ? MTLVertexFormatInvalid : ui[n - 1];   // 32 位整数归一化 Metal 没有
        case GL_INT: return no ? MTLVertexFormatInvalid : si[n - 1];
        // 10:10:10:2 打包（ES 3.0 只许 size 4）：归一化走 Metal 的 1010102 归一化格式（有符号的换算 max(c / (2^(b−1) − 1), −1) 与 GL 规范一致）。
        // 不归一化时 GL 要整数原值转浮点（1023 → 1023.0），Metal 没有这种顶点格式，仍不画（缺口族 43 后续项）
        case GL_UNSIGNED_INT_2_10_10_10_REV: return no && n == 4 ? MTLVertexFormatUInt1010102Normalized : MTLVertexFormatInvalid;
        case GL_INT_2_10_10_10_REV: return no && n == 4 ? MTLVertexFormatInt1010102Normalized : MTLVertexFormatInvalid;
    }
    return MTLVertexFormatInvalid;
}
static uint32_t vsize(const gl_attrib *a) {
    int b = a->type == GL_FLOAT || a->type == GL_INT || a->type == GL_UNSIGNED_INT ? 4 : a->type == GL_HALF_FLOAT || a->type == GL_SHORT || a->type == GL_UNSIGNED_SHORT ? 2 : 1;
    return (uint32_t)a->size * (uint32_t)b;
}
static MTLBlendOperation blend_op(GLenum e) {
    switch (e) {
        case 0x8006: return MTLBlendOperationAdd;
        case 0x8007: return MTLBlendOperationMin;
        case 0x8008: return MTLBlendOperationMax;
        case 0x800A: return MTLBlendOperationSubtract;
        case 0x800B: return MTLBlendOperationReverseSubtract;
    }
    die("[gl] 无效混合方程 %#x", e);
}
static MTLBlendFactor blend_factor(GLenum f, int alpha) {
    switch (f) {
        case 0: return MTLBlendFactorZero;
        case 1: return MTLBlendFactorOne;
        case 0x0300: return alpha ? MTLBlendFactorSourceAlpha : MTLBlendFactorSourceColor;
        case 0x0301: return alpha ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusSourceColor;
        case 0x0302: return MTLBlendFactorSourceAlpha;
        case 0x0303: return MTLBlendFactorOneMinusSourceAlpha;
        case 0x0304: return MTLBlendFactorDestinationAlpha;
        case 0x0305: return MTLBlendFactorOneMinusDestinationAlpha;
        case 0x0306: return alpha ? MTLBlendFactorDestinationAlpha : MTLBlendFactorDestinationColor;
        case 0x0307: return alpha ? MTLBlendFactorOneMinusDestinationAlpha : MTLBlendFactorOneMinusDestinationColor;
        case 0x0308: return alpha ? MTLBlendFactorOne : MTLBlendFactorSourceAlphaSaturated;
        case 0x8001: return alpha ? MTLBlendFactorBlendAlpha : MTLBlendFactorBlendColor;
        case 0x8002: return alpha ? MTLBlendFactorOneMinusBlendAlpha : MTLBlendFactorOneMinusBlendColor;
        case 0x8003: return MTLBlendFactorBlendAlpha;
        case 0x8004: return MTLBlendFactorOneMinusBlendAlpha;
    }
    die("[gl] 无效混合因子 %#x", f);
}
static id<MTLRenderPipelineState> pso_get(struct gl_program *p, struct gl_vao *v, int cull_all, int *feat) {
    NSMutableString *k = [NSMutableString stringWithFormat:@"%lu:%lu:%d:s%lu", (unsigned long)fmt_of(g_rt.dep), (unsigned long)fmt_of(g_rt.sten), cull_all, (unsigned long)rt_samples(&g_rt)];
    for (int i = 0; i < GL_COLOR_TARGETS; i++) if (g_rt.col[i]) {
        const gl_color_state *c = &gl_cur->color[i]; int blend = c->blend;
        [k appendFormat:@"|c%d:%lu:%lu:%d", i, (unsigned long)fmt_of(g_rt.col[i]), (unsigned long)color_mask(i), blend];
        if (blend) [k appendFormat:@":%x:%x:%x:%x:%x:%x", c->eq[0], c->eq[1], c->factor[0], c->factor[1], c->factor[2], c->factor[3]];
    }
    for (int i = 0; i < p->nattr; i++) { const gl_attrib *a = &v->a[p->attr[i].loc]; [k appendFormat:@"|%d:%lu:%d:%u", p->attr[i].slot, a->enabled ? (unsigned long)vfmt(a) : 0ul, a->enabled ? a->stride : -1, a->enabled ? a->divisor : 0]; }
    id hit = p->pso[k]; if (hit) return hit == NSNull.null ? nil : hit;   // 建失败存 NSNull：同一组合不再每笔重建（11-01）
    id<MTLRenderPipelineState> ps;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = p->fn[0]; pd.fragmentFunction = cull_all ? nil : p->fn[1];
    pd.depthAttachmentPixelFormat = fmt_of(g_rt.dep); pd.stencilAttachmentPixelFormat = fmt_of(g_rt.sten); pd.rasterSampleCount = rt_samples(&g_rt);
    for (int i = 0; i < GL_COLOR_TARGETS; i++) {
        const gl_color_state *c = &gl_cur->color[i];
        MTLRenderPipelineColorAttachmentDescriptor *a = pd.colorAttachments[i]; a.pixelFormat = fmt_of(g_rt.col[i]);
        a.writeMask = cull_all ? MTLColorWriteMaskNone : color_mask(i);
        if (c->blend && g_rt.col[i]) {
            a.blendingEnabled = YES;
            a.rgbBlendOperation = blend_op(c->eq[0]); a.alphaBlendOperation = blend_op(c->eq[1]);
            a.sourceRGBBlendFactor = blend_factor(c->factor[0], 0); a.destinationRGBBlendFactor = blend_factor(c->factor[1], 0);
            a.sourceAlphaBlendFactor = blend_factor(c->factor[2], 1); a.destinationAlphaBlendFactor = blend_factor(c->factor[3], 1);
        }
    }
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    for (int i = 0; i < p->nattr; i++) {
        int s = p->attr[i].slot; const gl_attrib *a = &v->a[p->attr[i].loc];
        vd.attributes[s].offset = 0; vd.attributes[s].bufferIndex = 30 - s;   // 每个属性一个缓冲槽（偏移在绑定时给），同 Vulkan 层的 30 − 绑定号
        if (!a->enabled) {   // 关掉的数组：GL 的缺省当前属性 (0, 0, 0, 1)，常量步进
            vd.attributes[s].format = MTLVertexFormatFloat4; vd.layouts[30 - s].stride = 16;
            vd.layouts[30 - s].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[30 - s].stepRate = 0; continue;
        }
        MTLVertexFormat f = vfmt(a); if (f == MTLVertexFormatInvalid) { GLRED1("顶点格式 类型 %#x × %d（归一化 %u）没实现", a->type, a->size, a->norm); *feat = 1; return nil; }
        NSUInteger stride = a->stride ? (NSUInteger)a->stride : vsize(a);
        if (stride & 3) { GLRED1("顶点步长 %lu 不是 4 的倍数（Metal 不收）", (unsigned long)stride); *feat = 1; return nil; }
        vd.attributes[s].format = f; vd.layouts[30 - s].stride = stride;
        if (a->divisor) { vd.layouts[30 - s].stepFunction = MTLVertexStepFunctionPerInstance; vd.layouts[30 - s].stepRate = a->divisor; }   // glVertexAttribDivisor
    }
    pd.vertexDescriptor = vd;
    NSError *e = nil; ps = [gl_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { static int n; if (n++ < 20) GLOG("【红】 建管线失败：%s", e.localizedDescription.UTF8String); p->pso[k] = NSNull.null; return nil; }
    p->pso[k] = ps; return ps;
}
static MTLStencilOperation stencil_op(GLenum o) {
    switch (o) { case 0: return MTLStencilOperationZero; case 0x1E01: return MTLStencilOperationReplace; case 0x1E02: return MTLStencilOperationIncrementClamp;
                 case 0x1E03: return MTLStencilOperationDecrementClamp; case 0x150A: return MTLStencilOperationInvert; case 0x8507: return MTLStencilOperationIncrementWrap;
                 case 0x8508: return MTLStencilOperationDecrementWrap; }
    return MTLStencilOperationKeep;
}
// 没有深度附件 = 深度测试恒过、不写；没有模板附件 = 模板测试恒过（规范：帧缓冲没有该缓冲时如同测试关闭）
static id<MTLDepthStencilState> dss(void) {
    int on = (gl_cur->enable & GLE_DEPTH) && g_rt.dep && !g_rt.fake_dep; GLenum fn = on ? gl_cur->depth_func : 0x0207; int w = on && gl_cur->depth_mask;
    int son = (gl_cur->enable & GLE_STENCIL) && g_rt.sten;
    NSString *k = son ? [NSString stringWithFormat:@"%x:%d:%x:%x:%x:%x:%x:%x|%x:%x:%x:%x:%x:%x", fn, w,
                         gl_cur->stencil_func[0], gl_cur->stencil_op[0][0], gl_cur->stencil_op[0][1], gl_cur->stencil_op[0][2], gl_cur->stencil_mask[0] & 0xff, gl_cur->stencil_wmask[0] & 0xff,
                         gl_cur->stencil_func[1], gl_cur->stencil_op[1][0], gl_cur->stencil_op[1][1], gl_cur->stencil_op[1][2], gl_cur->stencil_mask[1] & 0xff, gl_cur->stencil_wmask[1] & 0xff]
                       : [NSString stringWithFormat:@"%x:%d", fn, w];
    id<MTLDepthStencilState> st = g_dss[k]; if (st) return st;
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new]; d.depthWriteEnabled = w;
    d.depthCompareFunction = fn >= 0x0200 && fn <= 0x0207 ? (MTLCompareFunction)(fn - 0x0200) : MTLCompareFunctionAlways;   // GL_NEVER..GL_ALWAYS 与 Metal 同序
    if (son) for (int f = 0; f < 2; f++) {
        MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
        GLenum sf = gl_cur->stencil_func[f]; sd.stencilCompareFunction = sf >= 0x0200 && sf <= 0x0207 ? (MTLCompareFunction)(sf - 0x0200) : MTLCompareFunctionAlways;
        sd.stencilFailureOperation = stencil_op(gl_cur->stencil_op[f][0]); sd.depthFailureOperation = stencil_op(gl_cur->stencil_op[f][1]); sd.depthStencilPassOperation = stencil_op(gl_cur->stencil_op[f][2]);
        sd.readMask = gl_cur->stencil_mask[f] & 0xff; sd.writeMask = gl_cur->stencil_wmask[f] & 0xff;
        if (f) d.backFaceStencil = sd; else d.frontFaceStencil = sd;
    }
    st = [gl_dev newDepthStencilStateWithDescriptor:d]; g_dss[k] = st; return st;
}
// 本笔有没有启用的客户端内存顶点数组（属性没绑缓冲）：有才需要算顶点范围
static int client_attrs(void) {
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog); struct gl_vao *v = gl_vao_cur();
    if (!p || !v) return 0;
    for (int i = 0; i < p->nattr; i++) { const gl_attrib *a = &v->a[p->attr[i].loc]; if (a->enabled && !a->buf) return 1; }
    return 0;
}
// 一笔绘制前：取管线、设状态、绑 uniform 块与顶点缓冲。vend = 本笔读到的最大顶点号 + 1（只客户端内存顶点数组用：拷这么多顶点）；instances = 实例数（有除数的客户端数组按它拷）。
//   返回编码器（nil = 这笔丢掉，已计数）
static id<MTLRenderCommandEncoder> setup(MTLPrimitiveType primitive, uint32_t vend, uint32_t instances) {
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog);
    if (!p || !p->linked) { gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return nil; }
    if (!gl_prog_fns(p)) { gl_bad_err++; return nil; }   // 现编的阶段第一次画：等它那一支 Metal 编完（坏了不画，红已在现编处报）
    struct gl_vao *v = gl_vao_cur(); if (!v) { gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return nil; }
    for (int i = 0; i < p->nattr; i++) {   // 规范：绘制读映射着的缓冲是 GL_INVALID_OPERATION（不画）；持久映射除外（GL 4.5 §6.3.2）
        const gl_attrib *a = &v->a[p->attr[i].loc]; struct gl_buffer *b = a->enabled && a->buf ? gl_name_get(&gl_buffers, a->buf) : NULL;
        if (b && b->map_access && !(b->map_bits & 0x40)) { gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return nil; }
    }
    // 组 mip / cube 要开 blit；必须在本笔的渲染编码器和任何绘制状态之前准备。
    if (p->nsmp && !gl_tex_prepare(p)) { gl_bad_feat++; return nil; }
    id<MTLRenderCommandEncoder> re = gl_render_enc(); if (!re) { GLRED1("没有绘制表面"); gl_bad_err++; return nil; }
    // Metal 没有双面剔除。保留顶点执行，三角形去掉片元函数并用空裁剪禁止深度 / 模板样本。
    // 不关 rasterizationEnabled：现有带位置输出的顶点函数不符合 Metal 对 void 返回的要求。
    int cull_all = (gl_cur->enable & GLE_CULL) && gl_cur->cull == GL_FRONT_AND_BACK &&
                   (primitive == MTLPrimitiveTypeTriangle || primitive == MTLPrimitiveTypeTriangleStrip);
    int feat = 0; id<MTLRenderPipelineState> ps = pso_get(p, v, cull_all, &feat);
    if (!ps) { if (feat) gl_bad_feat++; else gl_bad_err++; return nil; }
    int wd_emit_n = wd_draw(p, has_color(&g_rt));   // 宽屏 ①–③（关时 0、g_wd_mode 不用）
    if (g_wd_side_on) wd_page_clear(re);
    if (g_wd > 0) wd_self_sentinel(re);   // 宽屏原比例回退：本帧没清屏的世界目标，第一笔之前在两侧带放哨兵（同在设这笔状态之前）   // 宽屏：本笔起原比例页，先清两侧条带（在设这笔的状态之前：清除会改掉管线 / 视口 / 裁剪）
    [re setRenderPipelineState:ps]; [re setDepthStencilState:dss()];
    [re setStencilFrontReferenceValue:(uint32_t)gl_cur->stencil_ref[0] & 0xff backReferenceValue:(uint32_t)gl_cur->stencil_ref[1] & 0xff];
    for (int i = 0; i < GL_COLOR_TARGETS; i++) if (gl_cur->color[i].blend) {
        [re setBlendColorRed:gl_cur->blend_color[0] green:gl_cur->blend_color[1] blue:gl_cur->blend_color[2] alpha:gl_cur->blend_color[3]]; break;
    }
    // 视口：存储按 GL 行序，高度取负翻转；GL 的 y（自底向上）就是存储行号。宽屏 ④：横向按本笔画法换算（关时原样）
    double vx = gl_cur->vp[0], vw = gl_cur->vp[2], vy = gl_cur->vp[1], vh = gl_cur->vp[3]; wd_map_vp(&vx, &vw, &vy, &vh);   // 窄屏加高：纵向同样按本笔画法换算（GL 行序，pad 上下对称）
    [re setViewport:(MTLViewport){vx, vy + vh, vw, -vh, gl_cur->depth_range[0], gl_cur->depth_range[1]}];
    if (!g_rt.fb) gl_surface_extent(gl_cur->vp[0] + gl_cur->vp[2], gl_cur->vp[1] + gl_cur->vp[3]);
    MTLScissorRect sc = cull_all ? (MTLScissorRect){0, 0, 0, 0} : scissor_rect(g_rt.w, g_rt.h); if (!cull_all && (gl_cur->enable & GLE_SCISSOR)) wd_map_sc(&sc, g_rt.w, g_rt.h);
    [re setScissorRect:sc];
    // 多边形偏移：GL 的 factor × 斜率 + units × 最小可分辨差 = Metal 的 slopeScale / depthBias（只对三角形，Metal 同样只偏移面）
    if (gl_cur->enable & GLE_POLY_OFFSET) [re setDepthBias:gl_cur->poly_units slopeScale:gl_cur->poly_factor clamp:0]; else [re setDepthBias:0 slopeScale:0 clamp:0];
    // 正反面：视口翻转把窗口里的绕向反了过来，GL 的逆时针为正面 → Metal 按顺时针认
    [re setFrontFacingWinding:gl_cur->front == GL_CW ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [re setCullMode:!(gl_cur->enable & GLE_CULL) ? MTLCullModeNone : gl_cur->cull == GL_FRONT ? MTLCullModeFront : gl_cur->cull == GL_BACK ? MTLCullModeBack : MTLCullModeNone];
    [re setTriangleFillMode:gl_cur->poly_mode == 0x1B01 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];   // glPolygonMode：GL_LINE 线框；GL_POINT Metal 没有（gl_fb.m 设时已报红）
    for (int st = 0; st < 2; st++) if (p->ub[st] && p->ub_slot[st] >= 0) {
        if (p->ub_size[st] <= 4096) { if (st) [re setFragmentBytes:p->ub[st] length:(NSUInteger)p->ub_size[st] atIndex:(NSUInteger)p->ub_slot[st]]; else [re setVertexBytes:p->ub[st] length:(NSUInteger)p->ub_size[st] atIndex:(NSUInteger)p->ub_slot[st]]; }
        else { GLRED1("默认 uniform 块 %d 字节超过 4 KB 没实现", p->ub_size[st]); gl_bad_feat++; return nil; }
    }
    if (wd_emit_n) wd_emit(re);   // 宽屏 ⑤：有改写的默认块换成改写后的字节
    for (int k = 0; k < p->nblk; k++) {   // 命名统一块：绑定点上 glBindBufferBase 给的缓冲（存储随 BufferData / SubData 换新，已编码的绘制持有旧存储）
        struct gl_buffer *b = gl_name_get(&gl_buffers, gl_cur->ubo[p->blk[k].binding]);
        if (!b || !b->buf) { GLRED1("统一块 %s 的绑定点 %u 上没有缓冲（游戏没 glBindBufferBase）：不画", p->blk[k].name, p->blk[k].binding); gl_bad_feat++; return nil; }
        size_t off = (size_t)gl_cur->ubo_off[p->blk[k].binding];
        if (off + (size_t)p->blk[k].size > b->size) GLRED1("统一块 %s 要 %d 字节，绑定点缓冲只有 %zu 字节", p->blk[k].name, p->blk[k].size, b->size - off);
        gl_buffer_ref(b);
        if (p->blk[k].slot[0] >= 0) [re setVertexBuffer:b->buf offset:off atIndex:(NSUInteger)p->blk[k].slot[0]];
        if (p->blk[k].slot[1] >= 0) [re setFragmentBuffer:b->buf offset:off atIndex:(NSUInteger)p->blk[k].slot[1]];
    }
    if (p->nsmp && !gl_tex_bind(re, p)) { gl_bad_feat++; return nil; }
    for (int i = 0; i < p->nattr; i++) {
        int s = p->attr[i].slot; const gl_attrib *a = &v->a[p->attr[i].loc];
        if (!a->enabled) {   // 关掉的数组读当前通用属性（glVertexAttrib*，上下文状态；setBytes 当场复制，之后改不影响这笔）
            [re setVertexBytes:gl_cur->attr_cur[p->attr[i].loc] length:sizeof gl_cur->attr_cur[0] atIndex:(NSUInteger)(30 - s)]; continue;
        }
        if (!a->buf) {   // 客户端内存顶点数组：拷本笔读到的 [0, vend) 个顶点（有除数的按实例：ceil(实例数 / 除数) 个；≤ 4 KB 走 setVertexBytes，否则临时缓冲；命令缓冲持有到 GPU 用完）
            uint32_t n = a->divisor ? (instances + a->divisor - 1) / a->divisor : vend;
            NSUInteger stride = a->stride ? (NSUInteger)a->stride : vsize(a), bytes = n ? (NSUInteger)(n - 1) * stride + vsize(a) : 0;
            if (!a->off || !bytes) { GLRED1("属性 %s 是客户端内存顶点数组，但地址为空或本笔没有顶点", p->attr[i].name); gl_bad_err++; return nil; }
            if (bytes <= 4096) [re setVertexBytes:(const void *)a->off length:bytes atIndex:(NSUInteger)(30 - s)];
            else {
                id<MTLBuffer> cb = [gl_dev newBufferWithBytes:(const void *)a->off length:bytes options:MTLResourceStorageModeShared];
                if (!cb) { GLOG("【红】 客户端内存顶点数组拷贝分配失败（%lu 字节）", (unsigned long)bytes); gl_bad_err++; return nil; }
                [re setVertexBuffer:cb offset:0 atIndex:(NSUInteger)(30 - s)];
            }
            continue;
        }
        struct gl_buffer *b = gl_name_get(&gl_buffers, a->buf);
        if (!b || !b->buf) { GLRED1("属性 %s 的缓冲没有存储", p->attr[i].name); gl_bad_err++; return nil; }
        [re setVertexBuffer:b->buf offset:(NSUInteger)a->off atIndex:(NSUInteger)(30 - s)];
        gl_buffer_ref(b);
    }
    return re;
}
static int prim(GLenum mode, MTLPrimitiveType *t) {
    switch (mode) { case GL_POINTS: *t = MTLPrimitiveTypePoint; return 1; case GL_LINES: *t = MTLPrimitiveTypeLine; return 1; case GL_LINE_STRIP: *t = MTLPrimitiveTypeLineStrip; return 1;
                    case GL_TRIANGLES: case GL_TRIANGLE_FAN: *t = MTLPrimitiveTypeTriangle; return 1; case GL_TRIANGLE_STRIP: *t = MTLPrimitiveTypeTriangleStrip; return 1; }
    return 0;   // 环线 / 带邻接的：Metal 没有，要改写索引（本片补）
}
static uint32_t fan_index(const uint8_t *src, GLenum type, NSUInteger i) {
    if (!src) return (uint32_t)i;
    if (type == GL_UNSIGNED_BYTE) return src[i];
    if (type == GL_UNSIGNED_SHORT) { uint16_t v; memcpy(&v, src + i * sizeof v, sizeof v); return v; }
    uint32_t v; memcpy(&v, src + i * sizeof v, sizeof v); return v;
}
// GL 的第 i 个三角形是 (0,i,i+1)，缺省 flat 值来自最后一个顶点；Metal 从第一个取。
// 循环移位为 (i+1,0,i) 保持绕向，保留原顶点号与 provoking vertex；32 位目标不截断任何输入索引。
static id<MTLBuffer> fan_indices(const uint8_t *src, GLenum type, GLsizei count) {
    NSUInteger triangles = (NSUInteger)count - 2;
    if (triangles > gl_dev.maxBufferLength / (3 * sizeof(uint32_t))) {
        GLOG("【红】 glDraw 三角扇索引转换超过 Metal 缓冲上限"); gl_set_error(GL_OUT_OF_MEMORY); gl_bad_err++; return nil;
    }
    id<MTLBuffer> buffer = [gl_dev newBufferWithLength:triangles * 3 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!buffer) { GLOG("【红】 glDraw 三角扇索引转换分配失败"); gl_set_error(GL_OUT_OF_MEMORY); gl_bad_err++; return nil; }
    uint32_t *dst = buffer.contents, anchor = fan_index(src, type, 0), previous = fan_index(src, type, 1);
    for (NSUInteger i = 0; i < triangles; i++) {
        uint32_t current = fan_index(src, type, i + 2);
        dst[i * 3] = current; dst[i * 3 + 1] = anchor; dst[i * 3 + 2] = previous; previous = current;
    }
    return buffer;
}
// 本笔生成的图元数（GL_PRIMITIVES_GENERATED：没有几何 / 曲面细分着色器，图元数由图元类型与顶点数唯一决定）
static uint64_t prim_count(GLenum mode, GLsizei count) {
    uint64_t n = (uint64_t)count;
    switch (mode) { case GL_POINTS: return n; case GL_LINES: return n / 2; case GL_LINE_STRIP: return n >= 2 ? n - 1 : 0;
                    case GL_TRIANGLES: return n / 3; case GL_TRIANGLE_STRIP: case GL_TRIANGLE_FAN: return n >= 3 ? n - 2 : 0; }
    return 0;
}
// glDrawArrays / glDrawArraysInstanced 共用：instances 个实例
static void draw_arrays(GLenum mode, GLint first, GLsizei count, GLsizei instances) {
    MTLPrimitiveType t; if (first < 0 || count < 0 || instances < 0) { gl_set_error(GL_INVALID_VALUE); return; }
    if (!prim(mode, &t)) { GLRED1("图元 %#x 没实现", mode); gl_bad_feat++; return; }
    if (!count || !instances || (mode == GL_TRIANGLE_FAN && count < 3)) return;
    NSUInteger ni = (NSUInteger)instances;
    if (mode == GL_TRIANGLE_FAN) { @autoreleasepool {
        if (g_array_fan_count < count) {
            NSUInteger limit = gl_dev.maxBufferLength / (3 * sizeof(uint32_t)) + 2;
            if (limit > INT32_MAX) limit = INT32_MAX;
            if ((NSUInteger)count > limit) { GLOG("【红】 glDraw 三角扇索引转换超过 Metal 缓冲上限"); gl_set_error(GL_OUT_OF_MEMORY); gl_bad_err++; return; }
            NSUInteger capacity = g_array_fan_count ? (NSUInteger)g_array_fan_count : 3;
            while (capacity < (NSUInteger)count) capacity = capacity > limit / 2 ? limit : capacity * 2;
            id<MTLBuffer> indices = fan_indices(NULL, 0, (GLsizei)capacity); if (!indices) return;
            g_array_fan = indices; g_array_fan_count = (GLsizei)capacity;
        }
        id<MTLRenderCommandEncoder> re = setup(MTLPrimitiveTypeTriangle, (uint32_t)first + (uint32_t)count, (uint32_t)instances); if (!re) return;
        [re drawIndexedPrimitives:t indexCount:((NSUInteger)count - 2) * 3 indexType:MTLIndexTypeUInt32 indexBuffer:g_array_fan indexBufferOffset:0 instanceCount:ni baseVertex:(NSInteger)first baseInstance:0]; gl_n_draws++; g_prims += prim_count(mode, count) * ni;
    } return; }
    id<MTLRenderCommandEncoder> re = setup(t, (uint32_t)first + (uint32_t)count, (uint32_t)instances); if (!re) return;
    [re drawPrimitives:t vertexStart:(NSUInteger)first vertexCount:(NSUInteger)count instanceCount:ni]; gl_n_draws++; g_prims += prim_count(mode, count) * ni;
}
GLB(glDrawArrays, void, GLenum mode, GLint first, GLsizei count) { @autoreleasepool { CTX(); draw_arrays(mode, first, count, 1); }}
GLB(glDrawArraysInstanced, void, GLenum mode, GLint first, GLsizei count, GLsizei instances) { @autoreleasepool { CTX(); draw_arrays(mode, first, count, instances); }}
// glDrawElements / glDrawElementsInstanced / glDrawElementsBaseVertex 共用：instances 个实例（gl_InstanceID 0..instances−1，有除数的属性按实例步进）；
//   bv：每个索引加上的基准顶点（GL 3.2 BaseVertex，LÖVE 画四边形批用它）
static void draw_elements(GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instances, GLint bv) {
    MTLPrimitiveType t; if (count < 0 || instances < 0) { gl_set_error(GL_INVALID_VALUE); return; }
    if (!prim(mode, &t)) { GLRED1("图元 %#x 没实现", mode); gl_bad_feat++; return; }
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT) { gl_set_error(GL_INVALID_ENUM); return; }
    if (!count || !instances || (mode == GL_TRIANGLE_FAN && count < 3)) return;
    struct gl_vao *v = gl_vao_cur(); struct gl_buffer *ib = v ? gl_name_get(&gl_buffers, v->ebo) : NULL;
    if (ib && ib->map_access && !(ib->map_bits & 0x40)) { gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return; }   // 映射着的元素数组缓冲不许画（规范；持久映射除外）
    if (ib && (ib->map_bits & 0x40)) { ib->idx16 = nil; ib->fan32_cache = nil; }   // 持久映射着：游戏随时改索引，按内容缓存的副本不能沿用
    NSUInteger ni = (NSUInteger)instances;
    size_t esz = type == GL_UNSIGNED_BYTE ? 1 : type == GL_UNSIGNED_SHORT ? 2 : 4;
    if (!ib || !ib->buf) { @autoreleasepool {   // 没绑元素数组缓冲 = 客户端内存索引（indices 是游戏内存地址）：每笔拷成临时索引缓冲（三角扇照样展开、ubyte 扩成 ushort）
        const uint8_t *src = indices; if (!src) { GLRED1("glDrawElements：客户端内存索引地址为空"); gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return; }
        uint32_t vend = 0; if (client_attrs()) for (GLsizei i = 0; i < count; i++) vend = MAX(vend, (uint32_t)((int64_t)fan_index(src, type, (NSUInteger)i) + bv + 1));
        id<MTLBuffer> ix; NSUInteger n = (NSUInteger)count; MTLIndexType it = type == GL_UNSIGNED_INT ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
        if (mode == GL_TRIANGLE_FAN) { ix = fan_indices(src, type, count); n = ((NSUInteger)count - 2) * 3; it = MTLIndexTypeUInt32; }
        else if (type == GL_UNSIGNED_BYTE) { ix = [gl_dev newBufferWithLength:n * sizeof(uint16_t) options:MTLResourceStorageModeShared]; uint16_t *d = ix.contents; for (NSUInteger i = 0; d && i < n; i++) d[i] = src[i]; }
        else ix = [gl_dev newBufferWithBytes:src length:n * esz options:MTLResourceStorageModeShared];
        if (!ix) { GLOG("【红】 glDrawElements 客户端内存索引拷贝分配失败（%d 个）", count); gl_bad_err++; return; }
        id<MTLRenderCommandEncoder> re = setup(t, vend, (uint32_t)instances); if (!re) return;
        [re drawIndexedPrimitives:t indexCount:n indexType:it indexBuffer:ix indexBufferOffset:0 instanceCount:ni baseVertex:bv baseInstance:0]; gl_n_draws++; g_prims += prim_count(mode, count) * ni;
    } return; }
    @autoreleasepool {
        id<MTLBuffer> indexBuffer = ib->buf; NSUInteger offset = (NSUInteger)(uintptr_t)indices;
        NSUInteger indexCount = (NSUInteger)count; MTLIndexType indexType = type == GL_UNSIGNED_INT ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
        if (mode == GL_TRIANGLE_FAN) {
            size_t elementSize = type == GL_UNSIGNED_BYTE ? 1 : type == GL_UNSIGNED_SHORT ? 2 : 4;
            if (offset > ib->size || (size_t)count > (ib->size - offset) / elementSize) {
                GLRED1("glDrawElements：三角扇索引范围超出元素数组缓冲"); gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return;
            }
            // 每版 EBO 内容按区间与类型缓存多份；写入整表失效，已编码命令保留旧快照。不切遍、不等 GPU。
            NSString *key = [NSString stringWithFormat:@"%zu:%d:%x", (size_t)offset, count, type];
            id<MTLBuffer> converted = ib->fan32_cache[key];
            if (!converted) {
                converted = fan_indices((const uint8_t *)ib->buf.contents + offset, type, count); if (!converted) return;
                if (!ib->fan32_cache) ib->fan32_cache = [NSMutableDictionary new];
                ib->fan32_cache[key] = converted;
            }
            indexBuffer = converted;
            offset = 0; indexCount = ((NSUInteger)count - 2) * 3; indexType = MTLIndexTypeUInt32;
        } else if (type == GL_UNSIGNED_BYTE) {
            if (offset > ib->size || (size_t)count > ib->size - offset) {
                GLRED1("glDrawElements：ubyte 索引范围超出元素数组缓冲"); gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return;
            }
            // 当前 GL 缓冲只有 CPU 写。每版内容整块零扩展一次，之后所有绘制复用不可变副本；
            // BufferData / SubData 使缓存失效，旧副本由已编码命令保留。不切渲染遍、不等 GPU。
            if (!ib->idx16) {
                if (ib->size > gl_dev.maxBufferLength / sizeof(uint16_t)) { GLOG("【红】 glDrawElements 索引转换超过 Metal 缓冲上限"); gl_set_error(GL_OUT_OF_MEMORY); gl_bad_err++; return; }
                NSUInteger bytes = ib->size * sizeof(uint16_t);
                id<MTLBuffer> converted = [gl_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
                if (!converted) { GLOG("【红】 glDrawElements 索引转换分配失败（%zu 字节）", (size_t)bytes); gl_set_error(GL_OUT_OF_MEMORY); gl_bad_err++; return; }
                const uint8_t *src = ib->buf.contents; uint16_t *dst = converted.contents;
                for (size_t i = 0; i < ib->size; i++) dst[i] = src[i];   // 未启用 primitive restart，255 仍是普通索引。
                ib->idx16 = converted;
            }
            indexBuffer = ib->idx16; offset *= sizeof(uint16_t);
        }
        uint32_t vend = 0;
        if (client_attrs()) {   // 客户端内存顶点数组配元素数组缓冲：从缓冲里的索引算顶点范围
            size_t o = (size_t)(uintptr_t)indices;
            if (o > ib->size || (size_t)count > (ib->size - o) / esz) { GLRED1("glDrawElements：索引范围超出元素数组缓冲"); gl_set_error(GL_INVALID_OPERATION); gl_bad_err++; return; }
            for (GLsizei i = 0; i < count; i++) vend = MAX(vend, (uint32_t)((int64_t)fan_index((const uint8_t *)ib->buf.contents + o, type, (NSUInteger)i) + bv + 1));
        }
        id<MTLRenderCommandEncoder> re = setup(t, vend, (uint32_t)instances); if (!re) return;
        if (type != GL_UNSIGNED_BYTE && mode != GL_TRIANGLE_FAN) gl_buffer_ref(ib);   // 转换的原 EBO 只在上面被 CPU 读取。
        // 普通 commandBuffer 保留编码时引用的资源，临时索引或失效缓存均活到本次 GPU 提交完成。
        [re drawIndexedPrimitives:t indexCount:indexCount indexType:indexType indexBuffer:indexBuffer indexBufferOffset:offset instanceCount:ni baseVertex:bv baseInstance:0];
        gl_n_draws++; g_prims += prim_count(mode, count) * ni;
    }
}
GLB(glDrawElements, void, GLenum mode, GLsizei count, GLenum type, const void *indices) { @autoreleasepool { CTX(); draw_elements(mode, count, type, indices, 1, 0); }}
GLB(glDrawElementsInstanced, void, GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instances) { @autoreleasepool { CTX(); draw_elements(mode, count, type, indices, instances, 0); }}
GLB(glDrawElementsBaseVertex, void, GLenum mode, GLsizei count, GLenum type, const void *indices, GLint bv) { @autoreleasepool { CTX(); draw_elements(mode, count, type, indices, 1, bv); }}

// ---------- 查询对象（glGenQueries / glBeginQuery / glEndQuery / glGetQueryObject*） ----------
// 遮挡（SAMPLES_PASSED / ANY_SAMPLES_PASSED(_CONSERVATIVE)）：Metal 可见性计数，结果 = 起止之间各计数格之和（ANY 类回 0 / 1）；
// 经过时间（TIME_ELAPSED）：起止各提交一次，结果 = 期间命令缓冲在 GPU 上的起止时间差（纳秒；GL 语义含期间 GPU 空闲）；
// 生成图元数（PRIMITIVES_GENERATED）：起止之间绘制的图元数（本层没有几何着色器，按图元类型与顶点数精确）；变换反馈写出图元数：本层没有变换反馈，恒 0（规范值）。
// 结果都在期间命令完成后才可取：取 QUERY_RESULT 时没提交的先提交再等（同驱动的隐式刷新），取 AVAILABLE 不等
enum { GL_SAMPLES_PASSED = 0x8914, GL_ANY_SAMPLES_PASSED = 0x8C2F, GL_ANY_SAMPLES_PASSED_CONSERVATIVE = 0x8D6A, GL_TIME_ELAPSED = 0x88BF,
       GL_PRIMITIVES_GENERATED = 0x8C87, GL_TF_PRIMITIVES_WRITTEN = 0x8C88, GL_QUERY_RESULT = 0x8866, GL_QUERY_RESULT_AVAILABLE = 0x8867, GL_QUERY_RESULT_NO_WAIT = 0x9194, NQT = 6 };
typedef struct { GLenum target; int active, done; uint64_t s0, s1, seq0, seq, p0, result; } gl_query;   // s0/s1：计数格区间；seq0/seq：期间第一 / 最后一次提交序号；done：结果已结算
static gl_names g_queries; static GLuint g_qactive[NQT];
static gl_query *g_qpend[256]; static int g_nqpend;   // 已结束、没结算的遮挡查询（复用计数格前要先结算覆盖到的）
static int qt_index(GLenum t) {
    switch (t) { case GL_SAMPLES_PASSED: return 0; case GL_ANY_SAMPLES_PASSED: return 1; case GL_ANY_SAMPLES_PASSED_CONSERVATIVE: return 2;
                 case GL_TIME_ELAPSED: return 3; case GL_PRIMITIVES_GENERATED: return 4; case GL_TF_PRIMITIVES_WRITTEN: return 5; }
    return -1;
}
static int occlusion(GLenum t) { return t == GL_SAMPLES_PASSED || t == GL_ANY_SAMPLES_PASSED || t == GL_ANY_SAMPLES_PASSED_CONSERVATIVE; }
static void qpend_drop(gl_query *q) { for (int i = 0; i < g_nqpend; i++) if (g_qpend[i] == q) { g_qpend[i] = g_qpend[--g_nqpend]; return; } }
// 结算（期间命令已完成）：遮挡按格求和，时间按命令缓冲 GPU 时间
static void q_settle(gl_query *q) {
    if (q->done) return;
    if (occlusion(q->target)) {
        uint64_t sum = 0; const uint64_t *vis = g_vis.contents;
        for (uint64_t i = q->s0; i < q->s1; i++) sum += vis[i % VIS_N];
        q->result = q->target == GL_SAMPLES_PASSED ? sum : sum != 0; qpend_drop(q);
    } else if (q->target == GL_TIME_ELAPSED) {
        double t0 = g_cbt[q->seq0 % CBT_N][0], t1 = g_cbt[q->seq % CBT_N][1];
        q->result = t1 > t0 ? (uint64_t)llround((t1 - t0) * 1e9) : 0;
    }
    q->done = 1;
}
// 结果可取：期间最后一次提交已完成。没提交的：wait = 1 先提交再等（QUERY_RESULT），否则只提交（AVAILABLE 反复查必须最终为真）
static int q_ready(gl_query *q, int wait) {
    if (q->done) return 1;
    if (q->seq >= gl_seq_ref()) gl_commit();
    if (wait) {   // 共享事件先于完成回调到达：再等完成回调把完成序号与 GPU 时间写好（通常微秒级，上限 1 秒）
        gl_wait(q->seq);
        for (int i = 0; i < 20000 && gl_ev.signaledValue >= q->seq && gl_seq_busy(q->seq); i++) usleep(50);
    }
    if (gl_seq_busy(q->seq)) return 0;
    q_settle(q); return 1;
}
// 换一格新计数格并在编码器上开始计数（格先清零：同一格只在一遍里用）。复用到的格还有没结算的查询覆盖 → 先结算（等它的提交完成）
static void vis_slot(id<MTLRenderCommandEncoder> re) {
    uint64_t i = g_vis_next++, k = i % VIS_N;
    if (i >= VIS_N) for (int j = 0; j < g_nqpend; j++) { gl_query *q = g_qpend[j];
        if (q->s0 <= i - VIS_N && i - VIS_N < q->s1) { if (q->seq < gl_seq_ref()) { gl_wait(q->seq); q_settle(q); j = -1; continue; }
            GLRED1("遮挡查询：同一次提交里用了超过 %d 格计数格，查询 %llu 格前的结果被覆盖", VIS_N, (unsigned long long)VIS_N); qpend_drop(q); q->done = 1; j = -1; } }
    if (g_vis_seq[k] && gl_seq_busy(g_vis_seq[k]) && g_vis_seq[k] < gl_seq_ref()) gl_wait(g_vis_seq[k]);   // 上一轮用这格的提交还在跑：等它写完再清
    ((uint64_t *)g_vis.contents)[k] = 0; g_vis_seq[k] = gl_seq_ref();
    [re setVisibilityResultMode:MTLVisibilityResultModeCounting offset:(NSUInteger)(k * 8)];
}
// 遮挡计数的边界（查询开始 / 结束）：后面的样本记进新格。开着的编码器没带可见性缓冲 → 收掉，下一笔开遍时带上
static void vis_boundary(void) {
    if (!g_re) return;
    if (!g_re_vis) { if (g_occ) gl_end_enc(); return; }
    if (g_occ) vis_slot(g_re); else [g_re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
}
static void query_destroy(void *o) { free(o); }
static gl_names g_syncs;
static void gl_query_session_reset(void) { gl_names_clear(&g_queries, query_destroy); gl_names_clear(&g_syncs, free); memset(g_qactive, 0, sizeof g_qactive); g_nqpend = 0; }
GL(glGenQueries, void, GLsizei n, GLuint *out) {
    CTX(); if (n < 0) { gl_set_error(GL_INVALID_VALUE); return; }
    for (GLsizei i = 0; i < n; i++) out[i] = gl_name_new(&g_queries, calloc(1, sizeof(gl_query)));
}
static void query_end(int k);
GL(glDeleteQueries, void, GLsizei n, const GLuint *names) {
    CTX(); if (n < 0) { gl_set_error(GL_INVALID_VALUE); return; }
    for (GLsizei i = 0; i < n; i++) {
        gl_query *q = gl_name_get(&g_queries, names[i]); if (!q) continue;
        if (q->active) for (int k = 0; k < NQT; k++) if (g_qactive[k] == names[i]) query_end(k);   // 删活动查询 = 先结束它
        qpend_drop(q); free(gl_name_del(&g_queries, names[i]));
    }
}
GLB(glBeginQuery, void, GLenum target, GLuint name) { @autoreleasepool {
    CTX(); int k = qt_index(target); if (k < 0) { GLRED1("glBeginQuery 目标 %#x 没实现", target); gl_set_error(GL_INVALID_ENUM); return; }
    gl_query *q = gl_name_get(&g_queries, name);
    if (!q || g_qactive[k] || q->active || (q->target && q->target != target)) { gl_set_error(GL_INVALID_OPERATION); return; }
    gl_dev_init(); qpend_drop(q);
    *q = (gl_query){.target = target, .active = 1};
    if (occlusion(target)) {
        if (!g_vis) { g_vis = [gl_dev newBufferWithLength:VIS_N * 8 options:MTLResourceStorageModeShared]; if (!g_vis) { gl_set_error(GL_OUT_OF_MEMORY); q->active = 0; return; } }
        q->s0 = g_vis_next; g_occ++; vis_boundary();   // 边界上换的新格（或下一遍开遍的格）序号就是 s0
    } else if (target == GL_TIME_ELAPSED) { gl_commit(); q->seq0 = gl_seq_ref(); }   // 期间的命令从下一个命令缓冲起
    else if (target == GL_PRIMITIVES_GENERATED) q->p0 = g_prims;
    g_qactive[k] = name;
}}
static void query_end(int k) {
    gl_query *q = gl_name_get(&g_queries, g_qactive[k]); g_qactive[k] = 0; if (!q) return;
    q->active = 0;
    if (occlusion(q->target)) { g_occ--; q->s1 = g_vis_next; vis_boundary(); if (g_nqpend < 256) g_qpend[g_nqpend++] = q; else { gl_wait(gl_commit()); q->seq = g_ev_val; q_settle(q); return; } }
    else if (q->target == GL_TIME_ELAPSED) { gl_commit(); q->seq = g_ev_val; return; }
    else if (q->target == GL_PRIMITIVES_GENERATED) q->result = g_prims - q->p0;
    else q->result = 0;   // 变换反馈写出图元数：没有变换反馈
    q->seq = gl_seq_ref();
}
GLB(glEndQuery, void, GLenum target) { @autoreleasepool {
    CTX(); int k = qt_index(target); if (k < 0) { gl_set_error(GL_INVALID_ENUM); return; }
    if (!g_qactive[k]) { gl_set_error(GL_INVALID_OPERATION); return; }
    query_end(k);
}}
// 取结果：64 位结果按目标类型饱和到 32 位（规范：超出可表示范围取最大值）
static int query_result(GLuint name, GLenum what, uint64_t *out) {
    gl_query *q = gl_name_get(&g_queries, name);
    if (!q || !q->target || q->active) { gl_set_error(GL_INVALID_OPERATION); return 0; }
    if (what == GL_QUERY_RESULT_AVAILABLE) { *out = (uint64_t)q_ready(q, 0); return 1; }
    if (what == GL_QUERY_RESULT) { if (!q_ready(q, 1)) { gl_set_error(GL_INVALID_OPERATION); return 0; } *out = q->result; return 1; }   // 等满 5 秒仍没完成（gl_wait 已报红）
    if (what == GL_QUERY_RESULT_NO_WAIT) { if (!q_ready(q, 0)) return 0; *out = q->result; return 1; }   // 没完成：不写
    gl_set_error(GL_INVALID_ENUM); return 0;
}
GLB(glGetQueryObjectiv, void, GLuint name, GLenum what, GLint *v) { @autoreleasepool { CTX(); uint64_t r; if (query_result(name, what, &r)) *v = r > INT32_MAX ? INT32_MAX : (GLint)r; }}
GLB(glGetQueryObjectivARB, void, GLuint name, GLenum what, GLint *v) { @autoreleasepool { CTX(); uint64_t r; if (query_result(name, what, &r)) *v = r > INT32_MAX ? INT32_MAX : (GLint)r; }}
GLB(glGetQueryObjectuiv, void, GLuint name, GLenum what, GLuint *v) { @autoreleasepool { CTX(); uint64_t r; if (query_result(name, what, &r)) *v = r > UINT32_MAX ? UINT32_MAX : (GLuint)r; }}

// ---------- 同步对象（glFenceSync / glClientWaitSync / glWaitSync / glDeleteSync） ----------
// 栅栏 = 「此前全部命令完成」= 本层共享事件到达当前命令缓冲的提交序号（同一队列按序执行）。GLsync 句柄 = 名字表的名字。
// 别的队列的栅栏（nvnSyncCreateGLSync：NVN 层提交栅栏的共享事件与栅栏号）：ev 非空，客户端等在 CPU 上等那个事件，服务端等编码进本层命令缓冲（跨队列真等）
enum { GL_SYNC_GPU_COMMANDS_COMPLETE = 0x9117, GL_SYNC_FLUSH_COMMANDS_BIT = 1, GL_ALREADY_SIGNALED = 0x911A, GL_TIMEOUT_EXPIRED = 0x911B,
       GL_CONDITION_SATISFIED = 0x911C, GL_WAIT_FAILED = 0x911D };
typedef struct { uint64_t seq; void *ev; uint64_t val; } gl_sync;   // ev / val：别的队列的共享事件与要等到的值（NULL = 本层栅栏 seq）
// NVN 层（hle_nvn.c）用：从别的队列的共享事件建 GL 同步对象，回 GLsync 句柄（0 = 分配失败）
uint64_t gl_sync_from_event(void *ev, uint64_t val) {
    gl_dev_init(); gl_sync *f = calloc(1, sizeof *f); if (f) { f->ev = ev; f->val = val; }
    return gl_name_new(&g_syncs, f);
}
// GL 同步对象 → 要等的共享事件与值（本层栅栏 = 本层共享事件与提交序号）；句柄无效回 0。*committed：本层栅栏所在的命令缓冲已提交（没提交时别的队列要等到 GL 下次提交）
int gl_sync_event(uint64_t h, void **ev, uint64_t *val, int *committed) {
    gl_dev_init(); gl_sync *f = h <= 0xFFFFFFFFu ? gl_name_get(&g_syncs, (GLuint)h) : NULL; if (!f) return 0;
    if (f->ev) { *ev = f->ev; *val = f->val; *committed = 1; } else { *ev = (__bridge void *)gl_ev; *val = f->seq; *committed = f->seq < gl_seq_ref(); }
    return 1;
}
GL(glFenceSync, GLsync, GLenum cond, GLbitfield flags) {
    CTX(NULL); if (cond != GL_SYNC_GPU_COMMANDS_COMPLETE) { gl_set_error(GL_INVALID_ENUM); return NULL; }
    if (flags) { gl_set_error(GL_INVALID_VALUE); return NULL; }
    gl_sync *f = calloc(1, sizeof *f); if (f) f->seq = gl_seq_ref();
    return (GLsync)(uintptr_t)gl_name_new(&g_syncs, f);
}
GL(glDeleteSync, void, GLsync sync) {
    CTX(); if (!sync) return;   // 0 静默忽略（规范）
    gl_sync *f = gl_name_del(&g_syncs, (GLuint)(uintptr_t)sync); if (!f) { gl_set_error(GL_INVALID_VALUE); return; } free(f);
}
// 客户端等：栅栏还在当前命令缓冲里就先提交（不管有没有 FLUSH 位：不提交就永远等不到；规范允许实现随时刷新），再按超时（纳秒）真等
GLB(glClientWaitSync, GLenum, GLsync sync, GLbitfield flags, GLuint64 timeout) { @autoreleasepool {
    CTX(GL_WAIT_FAILED); gl_sync *f = gl_name_get(&g_syncs, (GLuint)(uintptr_t)sync);
    if (!f) { gl_set_error(GL_INVALID_VALUE); return GL_WAIT_FAILED; }
    if (flags & ~(GLbitfield)GL_SYNC_FLUSH_COMMANDS_BIT) { gl_set_error(GL_INVALID_VALUE); return GL_WAIT_FAILED; }
    if (f->ev) {   // 别的队列的栅栏：CPU 上等它的共享事件
        id<MTLSharedEvent> e = (__bridge id<MTLSharedEvent>)f->ev; if (e.signaledValue >= f->val) return GL_ALREADY_SIGNALED; if (!timeout) return GL_TIMEOUT_EXPIRED;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        while (e.signaledValue < f->val && !gl_session_stopping()) {
            uint64_t el = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0; if (el >= timeout) return GL_TIMEOUT_EXPIRED;
            uint64_t ms = (timeout - el) / 1000000 + 1; [e waitUntilSignaledValue:f->val timeoutMS:ms > 50 ? 50 : ms];
        }
        return e.signaledValue >= f->val ? GL_CONDITION_SATISFIED : GL_TIMEOUT_EXPIRED;
    }
    if (!gl_seq_busy(f->seq)) return GL_ALREADY_SIGNALED;
    if (f->seq >= gl_seq_ref()) gl_commit();
    if (!timeout) return gl_seq_busy(f->seq) ? GL_TIMEOUT_EXPIRED : GL_ALREADY_SIGNALED;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    while (gl_ev.signaledValue < f->seq && !gl_session_stopping()) {
        uint64_t el = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0; if (el >= timeout) return GL_TIMEOUT_EXPIRED;
        uint64_t left = timeout - el, ms = left / 1000000 + 1; [gl_ev waitUntilSignaledValue:f->seq timeoutMS:ms > 50 ? 50 : ms];
    }
    return gl_ev.signaledValue >= f->seq ? GL_CONDITION_SATISFIED : GL_TIMEOUT_EXPIRED;
}}
// 服务端等：之后的命令要在栅栏之后执行。本层栅栏：本层只有一条按序执行的队列，栅栏前的命令必然先完成，无需编码等待（等自己所在的命令缓冲会死锁）；
//   别的队列的栅栏（NVN）：收掉开着的编码器，在本层命令缓冲里编码等它的共享事件，之后编码的命令在 GPU 上排在它后面（之前编码的不受影响）
GLB(glWaitSync, void, GLsync sync, GLbitfield flags, GLuint64 timeout) { @autoreleasepool {
    CTX(); gl_sync *f = gl_name_get(&g_syncs, (GLuint)(uintptr_t)sync); if (!f) { gl_set_error(GL_INVALID_VALUE); return; }
    if (flags || timeout != 0xFFFFFFFFFFFFFFFFull) { gl_set_error(GL_INVALID_VALUE); return; }   // 只允许 flags 0、超时 GL_TIMEOUT_IGNORED
    if (!f->ev) return;
    id<MTLSharedEvent> e = (__bridge id<MTLSharedEvent>)f->ev; if (e.signaledValue >= f->val) return;
    gl_end_enc(); [gl_cmd() encodeWaitForEvent:e value:f->val];
}}

// 查同步对象属性（GL 4.6 §4.1.3）：类型 = SYNC_FENCE、条件 = GPU_COMMANDS_COMPLETE、标志 = 0、状态 = 到没到。
//   状态只查不等；栅栏还在当前命令缓冲里就先提交（同 glClientWaitSync：游戏轮询状态不 flush 的话永远等不到）。
//   原先落在空实现上什么都不写，游戏读到自己栈上的旧值
GLB(glGetSynciv, void, GLsync sync, GLenum what, GLsizei count, GLsizei *length, GLint *values) { @autoreleasepool {
    CTX(); gl_sync *f = gl_name_get(&g_syncs, (GLuint)(uintptr_t)sync);
    if (!f) { gl_set_error(GL_INVALID_VALUE); return; }
    if (count < 0) { gl_set_error(GL_INVALID_VALUE); return; }
    GLint v;
    switch (what) {
        case 0x9112: v = 0x9116; break;                       // OBJECT_TYPE → SYNC_FENCE
        case 0x9113: v = GL_SYNC_GPU_COMMANDS_COMPLETE; break; // SYNC_CONDITION
        case 0x9115: v = 0; break;                            // SYNC_FLAGS
        case 0x9114: {                                        // SYNC_STATUS → SIGNALED 0x9119 / UNSIGNALED 0x9118
            int done;
            if (f->ev) done = ((__bridge id<MTLSharedEvent>)f->ev).signaledValue >= f->val;
            else { if (gl_seq_busy(f->seq) && f->seq >= gl_seq_ref()) gl_commit(); done = !gl_seq_busy(f->seq) || gl_ev.signaledValue >= f->seq; }   // 同 glClientWaitSync：事件到了就算到（完成回调记 g_done 稍后）
            v = done ? 0x9119 : 0x9118; break; }
        default: GLRED1("glGetSynciv 参数 %#x 没实现", what); gl_set_error(GL_INVALID_ENUM); return;
    }
    if (count >= 1 && values) { values[0] = v; if (length) *length = 1; } else if (length) *length = 0;
}}

// ---------- 即时存档：排空 + 查询 / 同步对象 ----------
int gl_snap_drain(void) {
    if (!g_q) return 1;
    uint64_t v = gl_commit(); gl_wait(v);
    if (gl_ev.signaledValue < v) return 0;
    return !g_completions || !dispatch_group_wait(g_completions, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}
// 查询：存档时全部结算（排空后都能结算），存目标与结果；进行中的查询（开着没结束）恢复后照原样算「开着」，计数从恢复后重新累计
// 同步对象：排空后全部已到，恢复成「已到」（本层栅栏 seq 0；别的队列的栅栏不再引用那个事件）
enum { GQ_NAME = 1, GQ_TARGET, GQ_ACTIVE, GQ_RESULT, GY_NAME = 1, GQ_ACT = 1 };
int gl_draw_snap_save(FILE *f) {
    sfw w; sfw_sec(&w, f, "gl.query", 1);
    for (GLuint i = 1; i < g_queries.n; i++) { gl_query *q = g_queries.v[i]; if (!q) continue; if (!q->active) q_settle(q);
        sfw_rec(&w); GLSF_W(&w, GQ_NAME, i); GLSF_W(&w, GQ_TARGET, q->target); GLSF_W(&w, GQ_ACTIVE, q->active); GLSF_W(&w, GQ_RESULT, q->result); sfw_end_rec(&w); }
    if (sfw_end(&w)) return -1;
    sfw_sec(&w, f, "gl.qact", 1); sfw_rec(&w); GLSF_W(&w, GQ_ACT, g_qactive); sfw_end_rec(&w); if (sfw_end(&w)) return -1;
    sfw_sec(&w, f, "gl.sync", 1);
    for (GLuint i = 1; i < g_syncs.n; i++) if (g_syncs.v[i]) { sfw_rec(&w); GLSF_W(&w, GY_NAME, i); sfw_end_rec(&w); }
    return sfw_end(&w);
}
int gl_draw_snap_restore(FILE *f) {
    sfr r; int bad = sfr_sec(&r, f, "gl.query", 1) != 0;
    while (!bad && sfr_rec(&r) == 1) { GLuint nm = 0; GLSF_R(&r, GQ_NAME, nm); gl_query *q = calloc(1, sizeof *q); if (!nm || !q) { free(q); continue; }
        GLSF_R(&r, GQ_TARGET, q->target); GLSF_R(&r, GQ_ACTIVE, q->active); GLSF_R(&r, GQ_RESULT, q->result); q->done = !q->active;
        if (q->active) { q->s0 = q->s1 = g_vis_next; }
        if (!gl_name_put(&g_queries, nm, q)) { free(q); bad = 1; } }
    sfr_done(&r);
    if (!bad && !sfr_sec(&r, f, "gl.qact", 1)) { while (sfr_rec(&r) == 1) GLSF_R(&r, GQ_ACT, g_qactive); } else bad = 1;
    sfr_done(&r);
    if (!bad && sfr_sec(&r, f, "gl.sync", 1)) bad = 1;
    while (!bad && sfr_rec(&r) == 1) { GLuint nm = 0; GLSF_R(&r, GY_NAME, nm); gl_sync *y = calloc(1, sizeof *y); if (!nm || !y) { free(y); continue; } if (!gl_name_put(&g_syncs, nm, y)) { free(y); bad = 1; } }
    sfr_done(&r);
    return bad ? -1 : 0;
}
