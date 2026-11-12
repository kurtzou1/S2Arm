// 本像素证明（scr_proof / uv_proof）的拒绝条件（10-30 帧率能耗线；画面线审：左下角原点、视口 swizzle 都会把 y 翻成镜像行，必须拒）。
// 直接编生产源码 nvn_mtl.m，只摆状态、调函数，不替换任何生产符号；期望值按条件手写：正例 1 个，其余每一条单独破坏一个条件，期望 0；
//   push_late = 1（⑤ 片上读取，外推参数在 draw_widen 后核）时带外推尾段可证（11-02 塞尔达：被一刀切拒的笔外推参数 405/405 为 0）
#ifndef NVN_PROOF_SOURCE
#define NVN_PROOF_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_PROOF_SOURCE

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NvProg *g_tp; static NvShader *g_tvs;
static void base_state(void) {   // 正例：左上角原点、视口不 swizzle、视口 = 0,0,1280,720 = 目标、顶点 locn6 是屏幕坐标、宽屏关、无几何 / 曲面 / 图层
    atomic_store(&g_origin_ll, 0); memset(S.vp_sw, 0, sizeof S.vp_sw);
    S.has_vp = 1; S.vp[0][0] = 0; S.vp[0][1] = 0; S.vp[0][2] = 1280; S.vp[0][3] = 720;
    g_pass.tw = 1280; g_pass.th = 720; g_pass.cw = 1280; g_pass.ch = 720; g_pass.rs = 1.0; g_wd = 0;   // 开遍时三者一起定（rp_begin_ex_）：画布 = 存储 / 比例，没缩时画布就是存储
    g_tvs->rf.scr_uv = 1u << 6; g_tvs->layer_out = 0; g_tvs->push = 0;
    for (int st = 0; st < 6; st++) g_tp->sh[st] = nil;
    g_tp->sh[0] = g_tvs;
}

int main(void) {
    @autoreleasepool {
        g_tp = [NvProg new]; g_tvs = [NvShader new]; g_tvs->stage = 0;
        base_state(); CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 1, "正例：左上角原点、无 swizzle、视口满、locn6 屏幕坐标 → 可证");
        base_state(); CHECK(scr_proof(g_tp, g_tvs, 5, 0, NULL) == 0, "插值量 locn5 没有屏幕坐标事实 → 不证");
        base_state(); atomic_store(&g_origin_ll, 1); CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "左下角原点（视口上下翻转）→ 不证");
        base_state(); S.vp_sw[0][1] = 1; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "视口 swizzle 非零（y 取反）→ 不证");
        base_state(); S.vp_sw[0][3] = 2; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "视口 swizzle 非零（w 分量）→ 不证");
        base_state(); S.vp[0][2] = 1279; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "视口没覆盖整个目标 → 不证");
        base_state(); S.has_vp = 0; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "没设视口 → 不证");
        base_state(); g_wd = 1; g_tvs->push = 1; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "宽屏开且顶点带外推尾段 → 不证");
        base_state(); g_wd = 1; g_tvs->push = 0; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 1, "宽屏开但顶点不读外推参数 → 可证");
        // push_late（⑤ 片上读取：判定早于 draw_widen，外推参数改由 draw() 在算出后核、非零则这一笔不外推）：带外推尾段不再在这里拒；其余条件照旧
        base_state(); g_wd = 1; g_tvs->push = 1; CHECK(scr_proof(g_tp, g_tvs, 6, 1, NULL) == 1, "push_late：宽屏开且顶点带外推尾段 → 可证（外推参数事后核）");
        base_state(); g_wd = 1; g_tvs->push = 1; g_tvs->layer_out = 1; CHECK(scr_proof(g_tp, g_tvs, 6, 1, NULL) == 0, "push_late：带外推尾段但写图层 → 不证");
        base_state(); g_wd = 1; g_tvs->push = 1; S.vp[0][2] = 1279; CHECK(scr_proof(g_tp, g_tvs, 6, 1, NULL) == 0, "push_late：视口没覆盖整个目标 → 不证");
        base_state(); g_tvs->layer_out = 1; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "顶点写图层 → 不证");
        base_state(); g_tp->sh[2] = g_tvs; CHECK(scr_proof(g_tp, g_tvs, 6, 0, NULL) == 0, "带几何阶段 → 不证");
        // 满屏加宽了读的附件的存储（画布 1600×1125），这一笔视口仍是游戏尺寸 1600×900（11-12 Mac 1920×1350 满屏局实测形态）：带附件可证，期望按条件手写
        {   tex_t a = {0}; a.d.width = 1600; a.d.height = 900;
            #define WD_STATE() do { base_state(); g_wd = 2; g_pass.cw = 1600; g_pass.ch = 1125; S.vp[0][2] = 1600; S.vp[0][3] = 900; } while (0)
            WD_STATE(); CHECK(scr_proof(g_tp, g_tvs, 6, 1, &a) == 1, "满屏加宽、视口 = 附件游戏尺寸 1600×900、原点左上 → 可证");
            WD_STATE(); CHECK(scr_proof(g_tp, g_tvs, 6, 1, NULL) == 0, "同上但不给附件（跨遍合并的调用）→ 不证");
            WD_STATE(); g_wd = 0; CHECK(scr_proof(g_tp, g_tvs, 6, 1, &a) == 0, "满屏没在加宽（g_wd 0）→ 不证");
            WD_STATE(); S.vp[0][3] = 899; CHECK(scr_proof(g_tp, g_tvs, 6, 1, &a) == 0, "视口比附件游戏尺寸少一行 → 不证");
            WD_STATE(); S.vp[0][1] = 225; CHECK(scr_proof(g_tp, g_tvs, 6, 1, &a) == 0, "视口原点不在 0,0 → 不证");
            WD_STATE(); g_pass.rs = 0.5; CHECK(scr_proof(g_tp, g_tvs, 6, 1, &a) == 0, "内部分辨率缩放中（画布单位另算）→ 不证");
            WD_STATE(); g_pass.ch = 900; S.vp[0][3] = 900; CHECK(scr_proof(g_tp, g_tvs, 6, 1, &a) == 1, "画布没加宽、视口盖满画布 → 照原规则可证");
            WD_STATE(); atomic_store(&g_origin_ll, 1); CHECK(scr_proof(g_tp, g_tvs, 6, 1, &a) == 0, "满屏视口但左下角原点 → 不证");
            #undef WD_STATE
        }
        base_state(); atomic_store(&g_origin_ll, 1); CHECK(vp_y_upper_left() == 0, "uv_proof 同一约定：左下角原点 → 不满足");
        base_state(); S.vp_sw[0][0] = 1; CHECK(vp_y_upper_left() == 0, "uv_proof 同一约定：视口 swizzle 非零 → 不满足");
    }
    {   // 片上读的视图通道顺序（swz_ident_for）：格式有的分量必须原样，缺的分量取贴图读缺省 0 / 0 / 1（帧缓冲按 float4 读缺的分量苹果 GPU 给 0 / 0 / 1，11-02 实测）。期望按规则手写
        #define SW(r, g, b, a) ((MTLTextureSwizzleChannels){MTLTextureSwizzle##r, MTLTextureSwizzle##g, MTLTextureSwizzle##b, MTLTextureSwizzle##a})
        CHECK(swz_ident_for(MTLPixelFormatR32Float, SW(Red, Zero, Zero, One)) == 1, "R32Float 视图 (R,0,0,1)：等于恒等（塞尔达附件 7）");
        CHECK(swz_ident_for(MTLPixelFormatR32Float, SW(Red, Green, Blue, Alpha)) == 1, "R32Float 严格恒等");
        CHECK(swz_ident_for(MTLPixelFormatR32Float, SW(Red, Zero, Zero, Zero)) == 0, "R32Float 视图 A 给 0：帧缓冲读得 1 → 不等");
        CHECK(swz_ident_for(MTLPixelFormatR32Float, SW(Red, One, Zero, One)) == 0, "R32Float 视图 G 给 1：帧缓冲读得 0 → 不等");
        CHECK(swz_ident_for(MTLPixelFormatR32Float, SW(Zero, Zero, Zero, One)) == 0, "R32Float 视图 R 换成 0：有的分量没原样 → 不等");
        CHECK(swz_ident_for(MTLPixelFormatRG11B10Float, SW(Red, Green, Blue, One)) == 1, "RG11B10Float 视图 (R,G,B,1)：缺 A 补 1 → 等");
        CHECK(swz_ident_for(MTLPixelFormatRG32Float, SW(Red, Green, Zero, One)) == 1, "RG32Float 视图 (R,G,0,1) → 等");
        CHECK(swz_ident_for(MTLPixelFormatRG32Float, SW(Red, Red, Zero, One)) == 0, "RG32Float 视图 G 换成 R → 不等");
        CHECK(swz_ident_for(MTLPixelFormatRGBA8Unorm, SW(Red, Green, Blue, One)) == 0, "RGBA8 视图 A 给 1（RGBX）：格式有 A、帧缓冲读真 A → 不等");
        CHECK(swz_ident_for(MTLPixelFormatBGRA8Unorm, SW(Blue, Green, Red, Alpha)) == 0, "BGRA8 视图换 R/B → 不等");
        CHECK(swz_ident_for(MTLPixelFormatRGBA16Float, SW(Red, Green, Blue, Alpha)) == 1, "四分量严格恒等 → 等");
        #undef SW
        atomic_store(&g_origin_ll, 0);
    }
    printf("%s t_nvn_screen_proof：%u 项，%u 处不符\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}
