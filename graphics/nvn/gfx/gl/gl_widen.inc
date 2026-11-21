// GL 层接宽屏第三层核心（graphics/widen，接口 graphics/widen/export/s2a_widen.h，通用模式 / NVN 直连 / Vulkan 层同一份识别 / 改写核心）。由 gl_draw.m #include。
// 调用顺序照核心约定（s2a_widen.h 第 3 节）：开渲染遍登记目标 → 每笔绘制 ① 视口快判 ② 默认 uniform 块交给核心 ③ 定画法 ④ 视口 / 裁剪换算 ⑤ 出数，有改写的块绑改写后的字节。
// 与 Vulkan 层那份（graphics/nvn/gfx/vk/vk_widen.inc）的区别：GL 的纹理建的时候不知道会不会当附件（glTexImage2D 在前、glFramebufferTexture2D 在后），
//   所以不在建的时候放宽，而是第一次当附件解析（gl_fb.m gl_draw_target）时问核心，要放宽就另建一张放宽的影子贴图画进去；游戏的纹理对象、
//   它看到的尺寸都不变，采样它的地方（gl_tex.m gl_tex_bind）换成影子。窗口表面（0 号帧缓冲）建的时候就知道是渲染目标，egl.m 直接按核心给的宽建。
//   影子挂在游戏的纹理 / 渲染缓冲对象上（gl_wd_shadow），不按名字查：名字会被复用；对象第 0 级换了存储（TexImage / Storage / 渲染缓冲重设尺寸）或
//   CPU 往里上传过，影子作废（下次当附件重建，原图有 CPU 内容就先拷进影子左边游戏宽那段）。
// 开关同直连统一的 S2A_WIDEN_DIRECT（10-26 起缺省开，=0 关）；关时一律原样，逐像素等于不接。
// v1 范围（同 Vulkan v1）：读法表没用（默认块整块交核心）；uniform 缓冲对象 GL 层还没绑，不交；读片元坐标的程序不乘横向倍率（计数报出）；
//   影子只做第 0 级（附件挂别的级报红一次、不放宽）。GL 层还没有 glBlitFramebuffer / glCopyTexSubImage / glReadPixels，拷贝 / 读回的换算等它们加了再补。
#include "../../../widen/export/s2a_widen.h"
int s2a_screen_w(void); int s2a_screen_h(void); int s2a_widen_game(void); int s2a_widen_layout(void); int s2a_widen_full(void);   // runtime/src/widen.c

static int g_wd = -1;            // -1 未定；0 关；> 0 核心模式（S2A_WIDEN_UI / ALL / PILLAR）
static int32_t g_wd_sh;          // 所有着色器共用的句柄（没有读法表）
static _Atomic uint32_t g_wd_ids = 0x60000000u;   // 本层给核心的贴图号；与 NVN 层、Vulkan 层（0x40000000 起）的序号不重叠
static pthread_mutex_t g_wd_mu = PTHREAD_MUTEX_INITIALIZER;   // 核心同一时刻一条线程
static int g_wd_mode;            // 本笔画法
static int32_t g_wd_sides[4]; static int g_wd_side_on;   // 本笔起了 16:9 原比例页：两侧条带（s2a_widen_page_sides），setup 画这笔前清黑
static uint32_t g_wd_bound[2];   // 交给核心时非空的槽（位），顶点 / 片元
static struct { const void *ptr; uint32_t len; } g_wd_b[2][32];
static uint64_t g_wd_frame; static uint32_t g_wd_tc, g_wd_td; static long g_wd_tr0 = -2, g_wd_tr1, g_wd_trs = 1;   // 诊断：S2A_GL_WIDEN_TRACE=<起帧>-<止帧>[:<隔几帧>]，这些帧里每笔打一行（目标、视口、画法、采样贴图）
static uint64_t g_wd_draws, g_wd_core, g_wd_rw, g_wd_big, g_wd_fragx, g_wd_seed, g_wd_lost, g_wd_nosub;
static uint8_t g_wd_scr[65536];
static uint32_t *g_wd_gone, g_wd_ngone, g_wd_cgone;   // 作废影子的核心贴图号：glDelete* / 上传跑在游戏栈上不进核心，下一次开渲染遍时释放
void gl_wd_release_id(uint32_t id) {
    if (!id) return;
    pthread_mutex_lock(&g_wd_mu); s2a_widen_release(id); pthread_mutex_unlock(&g_wd_mu);
}

int gl_wd_on(void) {
    if (__builtin_expect(g_wd >= 0, 1)) return g_wd;
    pthread_mutex_lock(&g_wd_mu);
    if (g_wd < 0) {
        const char *e = getenv("S2A_WIDEN_DIRECT");
        if (e && !strcmp(e, "0")) { GLOG("宽屏核心：直连第三层关（S2A_WIDEN_DIRECT=0）"); g_wd = 0; }
        else {
            uint32_t fl = (s2a_widen_game() ? S2A_WIDEN_GAME : 0) | (s2a_widen_layout() ? S2A_WIDEN_LAYOUT : 0) | (s2a_widen_full() ? S2A_WIDEN_FULL : 0);
            int m = s2a_widen_init(s2a_screen_w(), s2a_screen_h(), fl);
            if (m != S2A_WIDEN_OFF) g_wd_sh = s2a_widen_shader(0, NULL, 0);
            GLOG("宽屏核心：屏幕宽 %d，标志 %#x，模式 %d（0 关 / 1 界面 / 2 整套放宽 / 3 黑边），k %.4f", s2a_screen_w(), fl, m, s2a_widen_k());
            g_wd = m == S2A_WIDEN_OFF ? 0 : m;
        }
    }
    pthread_mutex_unlock(&g_wd_mu);
    return g_wd;
}
uint32_t gl_wd_new_id(void) { return atomic_fetch_add(&g_wd_ids, 1) + 1; }
// 建窗口表面（egl.m）：核心给的宽（不放宽 = w）
// 窄屏加高（审计 P1-79「OpenGL 纵轴」，11-05 街霸 30 周年合集 Mac 1920×1350：核心按 ky 1.25 改写了投影，GL 层存储不加高、视口 / 剪刀 / 清屏只换横向，
//   画面上沿被裁、底部 90 行黑）：存储按核心给的高建（s2a_widen_tex_h），视口 / 剪刀按本笔画法纵向换算（同 NVN 直连 nvn_mtl.m），带剪刀的清屏按核心高 ÷ 游戏高换算。
//   核心贴图号 → 游戏高（带剪刀的清屏换算纵向用；附件 / 表面登记时记下）
#define WD_GH 1024
static struct { uint32_t id, gh; } g_wd_gh[WD_GH];
static void wd_gh_put(uint32_t id, uint32_t gh) {   // 持 g_wd_mu
    for (unsigned i = 0, k = id & (WD_GH - 1); i < WD_GH; i++, k = (k + 1) & (WD_GH - 1)) if (!g_wd_gh[k].id || g_wd_gh[k].id == id) { g_wd_gh[k].id = id; g_wd_gh[k].gh = gh; return; }
}
static uint32_t wd_gh_get(uint32_t id) {   // 持 g_wd_mu；0 = 不知道
    for (unsigned i = 0, k = id & (WD_GH - 1); i < WD_GH && g_wd_gh[k].id; i++, k = (k + 1) & (WD_GH - 1)) if (g_wd_gh[k].id == id) return g_wd_gh[k].gh;
    return 0;
}
uint32_t gl_wd_rt(uint32_t id, uint32_t w, uint32_t h, uint32_t *th) {
    *th = h; if (gl_wd_on() <= 0) return w;
    pthread_mutex_lock(&g_wd_mu); int r = s2a_widen_texture(id, (int)w, (int)h, 1.0f, S2A_WIDEN_USE_RT), rh = s2a_widen_tex_h(id, (int)h); wd_gh_put(id, h); pthread_mutex_unlock(&g_wd_mu);
    if (rh > (int)h) *th = (uint32_t)rh;
    return r > (int)w ? (uint32_t)r : w;
}
void gl_wd_drop(gl_wd_shadow *s, int lost) {   // 影子作废（调用方：重定义 / 上传 / 删；游戏栈，只挂起贴图号）
    if (!s->id) return;
    if (lost && s->tex != s->orig) { g_wd_lost++; GLRED1("宽屏：画进放宽影子的纹理又被 CPU 上传，影子作废、之前画进去的内容丢（计数见宽屏核心那行）"); }
    pthread_mutex_lock(&g_wd_mu);
    if (g_wd_ngone == g_wd_cgone) { uint32_t c = g_wd_cgone ? g_wd_cgone * 2 : 64, *v = realloc(g_wd_gone, c * sizeof *v); if (v) { g_wd_gone = v; g_wd_cgone = c; } }
    if (g_wd_ngone < g_wd_cgone) g_wd_gone[g_wd_ngone++] = s->id;
    pthread_mutex_unlock(&g_wd_mu);
    s->tex = s->orig = nil; s->id = 0;
}
// 帧缓冲附件（gl_fb.m gl_draw_target）：要放宽 → 放宽的影子（第一次见建、原图换过存储就重建）；不放宽 → 原图。*oid = 核心贴图号（关 = 0）
//   s = NULL：这个附件挂法没放宽（非第 0 级 / 立方体面），原样画
id<MTLTexture> gl_wd_att(gl_wd_shadow *s, id<MTLTexture> t, uint32_t *oid) {
    *oid = 0; if (!t || gl_wd_on() <= 0) return t;
    if (!s) { GLRED1("宽屏：附件挂在非第 0 级 / 立方体面没实现（只放宽 2D 第 0 级），这一张不放宽"); return t; }
    if (s->id && s->orig != t) gl_wd_drop(s, 0);
    if (!s->id) {
        uint32_t nid = gl_wd_new_id();
        pthread_mutex_lock(&g_wd_mu); int r = s2a_widen_texture(nid, (int)t.width, (int)t.height, 1.0f, S2A_WIDEN_USE_RT), rh = s2a_widen_tex_h(nid, (int)t.height); wd_gh_put(nid, (uint32_t)t.height); pthread_mutex_unlock(&g_wd_mu);
        s->orig = t; s->tex = t; s->id = nid;
        if (r < (int)t.width) r = (int)t.width;
        if (rh < (int)t.height) rh = (int)t.height;
        if (r > (int)t.width || rh > (int)t.height) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:(NSUInteger)r height:(NSUInteger)rh mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | (t.usage & MTLTextureUsagePixelFormatView); d.storageMode = MTLStorageModePrivate;
            if (t.sampleCount > 1) { d.textureType = MTLTextureType2DMultisample; d.sampleCount = t.sampleCount; }   // 多重采样渲染缓冲：影子样本数相同（Metal 要求一遍里附件样本数一致）
            id<MTLTexture> sh = [gl_dev newTextureWithDescriptor:d];
            if (!sh) GLRED1("宽屏：放宽影子贴图 %dx%d 建不出，按原尺寸画", r, rh);
            else {
                if (s->cpu) {   // 原图上传过内容（游戏可能不清除就在上面叠画）：先拷进影子左边游戏宽那段
                    [gl_blit_enc() copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1)
                                         toTexture:sh destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                    g_wd_seed++;
                }
                s->tex = sh;
            }
        }
    }
    *oid = s->id; return s->tex;
}
// 采样（gl_tex.m gl_tex_bind）：level0 = 游戏纹理第 0 级的存储，image = 本来要采的贴图。当过附件且放宽了 → 换成影子
id<MTLTexture> gl_wd_sample(gl_wd_shadow *s, id<MTLTexture> level0, id<MTLTexture> image) {
    if (g_wd <= 0 || !s->id) return image;
    if (s->orig != level0) { gl_wd_drop(s, 0); return image; }   // 第 0 级换了存储：影子过期
    if (s->tex == s->orig) return image;                          // 没放宽
    if (image != level0) { g_wd_nosub++; GLRED1("宽屏：放宽过的附件纹理按 mip 链 / 换位视图采样没实现，采原图（计数见宽屏核心那行）"); return image; }
    return s->tex;
}
static void wd_targets(uint32_t c0, uint32_t d0) {   // 开渲染遍（gl_draw.m open_pass，宿主栈）
    if (g_wd <= 0) return;
    pthread_mutex_lock(&g_wd_mu);
    for (uint32_t i = 0; i < g_wd_ngone; i++) s2a_widen_release(g_wd_gone[i]);
    g_wd_ngone = 0;
    s2a_widen_targets(c0, d0); g_wd_tc = c0; g_wd_td = d0;
    pthread_mutex_unlock(&g_wd_mu);
}
// 部分清除的裁剪框（gl_clear）：没有本笔画法，按颜色目标（没有就深度目标）的放宽换算两端
static void wd_map_clear(uint32_t id, MTLScissorRect *r, NSUInteger tw, NSUInteger th) {
    if (g_wd <= 0 || !id) return;
    pthread_mutex_lock(&g_wd_mu); int x0 = s2a_widen_map_x(id, (int)r->x), x1 = s2a_widen_map_x(id, (int)(r->x + r->width));
    long gh = (long)wd_gh_get(id), ch = gh ? (long)s2a_widen_tex_h(id, (int)gh) : 0; pthread_mutex_unlock(&g_wd_mu);
    if (x0 < 0) x0 = 0; if ((NSUInteger)x1 > tw) x1 = (int)tw;
    r->x = (NSUInteger)x0; r->width = x1 > x0 ? (NSUInteger)(x1 - x0) : 0;
    if (gh > 0 && ch > gh) {   // 纵向：核心高 ÷ 游戏高（同 NVN wd_clear_y：起点向下、终点向上取整）
        long y0 = (long)r->y * ch / gh, y1 = ((long)(r->y + r->height) * ch + gh - 1) / gh;
        if ((NSUInteger)y1 > th) y1 = (long)th;
        r->y = (NSUInteger)y0; r->height = y1 > y0 ? (NSUInteger)(y1 - y0) : 0;
    }
}
// ①–③：返回 1 = 本笔进了核心（之后视口按 g_wd_mode 换算，绑完 uniform 再调 wd_emit）
static void wd_trace(const char *why, int ntx, const s2a_widen_tex *tx) {
    if (g_wd_tr0 == -2) { const char *e = getenv("S2A_GL_WIDEN_TRACE"); g_wd_tr0 = -1; if (e && sscanf(e, "%ld-%ld:%ld", &g_wd_tr0, &g_wd_tr1, &g_wd_trs) < 2) g_wd_tr0 = -1; if (g_wd_trs < 1) g_wd_trs = 1; }
    if (g_wd_tr0 < 0 || (long)g_wd_frame < g_wd_tr0 || (long)g_wd_frame > g_wd_tr1 || ((long)g_wd_frame - g_wd_tr0) % g_wd_trs) return;
    char t[256] = ""; int o = 0;
    for (int i = 0; i < ntx && i < 4 && o < 200; i++) o += snprintf(t + o, sizeof t - (size_t)o, " %u:%dx%d", tx[i].id, tx[i].w, tx[i].h);
    const GLint *vp = gl_cur->vp;
    GLOG("宽屏追踪 帧 %llu 目标 c%u d%u 视口 %d,%d %dx%d → %s 画法 %d 采样%s", (unsigned long long)g_wd_frame, g_wd_tc, g_wd_td, vp[0], vp[1], vp[2], vp[3], why, g_wd_mode, ntx ? t : " 无");
}
// 原比例回退的两侧覆盖采样（widen_fallback.inc，与 NVN 直连共用一份）：GL 的后端钩子
#define WD_P2_LOG GLOG
#define WD_P2_DEV gl_dev
static int wd_p2_widen_on(void) { return g_wd > 0; }
static id<MTLCommandBuffer> wd_p2_cmdbuf(void) { return [g_q commandBuffer]; }   // egl.m 先 gl_commit 本帧再 gl_wd_present：同一队列按提交顺序，排在本帧之后
#include "../../widen_fallback.inc"
static int wd_draw(const struct gl_program *p, int has_color) {
    if (g_wd <= 0) return 0;
    g_wd_draws++;
    const GLint *vp = gl_cur->vp;
    pthread_mutex_lock(&g_wd_mu);
    if (!s2a_widen_viewport((float)vp[0], (float)vp[2], (float)vp[3], 1.0f)) { g_wd_mode = S2A_WIDEN_KEEP; pthread_mutex_unlock(&g_wd_mu); wd_trace("目标没放宽", 0, NULL); return 0; }
    s2a_widen_draw_in in; memset(&in, 0, sizeof in);
    in.vp_x = (float)vp[0]; in.vp_y = (float)vp[1]; in.vp_w = (float)vp[2]; in.vp_h = (float)vp[3]; in.target_scale = 1; in.flags = has_color ? S2A_WIDEN_DRAW_COLOR : 0;
    for (int st = 0; st < 2; st++) {
        uint32_t used = 0; const void *ptr[32] = {0}; uint32_t len[32] = {0}; int sl = p->ub_slot[st];
        in.shader[st] = g_wd_sh;
        if (p->ub[st] && sl >= 0 && sl < 32 && p->ub_size[st] > 0) { ptr[sl] = p->ub[st]; len[sl] = (uint32_t)p->ub_size[st]; used |= 1u << sl; }
        for (uint32_t m = used | g_wd_bound[st]; m; m &= m - 1) {   // 用到的槽 + 上一笔还挂着的（没用到的解绑）
            int s = __builtin_ctz(m);
            if (g_wd_b[st][s].ptr == ptr[s] && g_wd_b[st][s].len == len[s] && !len[s]) continue;
            s2a_widen_cbuf_bind(st, s, ptr[s], len[s]); g_wd_b[st][s].ptr = ptr[s]; g_wd_b[st][s].len = len[s];
            if (len[s]) g_wd_bound[st] |= 1u << s; else g_wd_bound[st] &= ~(1u << s);
        }
    }
    static s2a_widen_tex tx[16]; int ntx = 0;   // 片元实际采样的贴图（核心据此认「采样了放宽 / 原生宽图」）
    // 每个实际采样的贴图都报（核心按尺寸认「只采小图 / 背景的界面层」；只报放宽影子时界面图集不在表里，空表被当成只采小图 → 原样铺满，
    //   10-25 数码宝贝标题 / 字幕按游戏坐标画、整体偏左）：放宽过的报影子的核心贴图号，其余报 0（不放宽、核心只看尺寸）
    for (int k = 0; k < p->nsmp && ntx < 16; k++) {
        int unit = p->smp[k].unit, cube = !strcmp(p->smp[k].type, "samplerCube") || !strcmp(p->smp[k].type, "samplerCubeShadow"); if (unit < 0 || unit >= 32) continue;
        GLuint name = gl_cur->tex_unit[unit][cube]; uint32_t w = 0, h = 0; if (!gl_tex_unit_dims((GLuint)unit, cube, &w, &h)) continue;
        const gl_wd_shadow *s = cube ? NULL : gl_tex_wd(name);
        tx[ntx++] = (s2a_widen_tex){s && s->id ? s->id : 0, (int32_t)w, (int32_t)h, 1.0f, 0};
    }
    in.tex = tx; in.ntex = ntx;
    s2a_widen_draw_out out; g_wd_mode = s2a_widen_draw(&in, &out); wd_trace("进核心", ntx, tx);
    if ((g_wd_mode == S2A_WIDEN_HOR || g_p2_fb) && g_wd_tc && s2a_widen_pure2d()) wd_fb_vote(g_wd_tc, (uint32_t)g_rt.w, (uint32_t)g_rt.h);   // 纯 2D 世界目标（原比例回退）
    g_wd_side_on = (out.flags & S2A_WIDEN_OUT_PAGE_SIDES) && s2a_widen_page_sides(g_wd_sides);
    if (out.frag_scale_x != 1.0f) g_wd_fragx++;
    pthread_mutex_unlock(&g_wd_mu);
    g_wd_core++;
    return !(out.flags & S2A_WIDEN_OUT_NO_EMIT);
}
// ④：视口 / 裁剪横向换算（本笔画法）
static void wd_map_vp(double *x, double *w, double *y, double *h) {
    if (g_wd <= 0) return;
    float fx = (float)*x, fw = (float)*w, fy = (float)*y, fh = (float)*h; s2a_widen_map_viewport(g_wd_mode, &fx, &fw); s2a_widen_map_viewport_y(g_wd_mode, &fy, &fh);
    *x = fx; *w = fw; *y = fy; *h = fh;
}
static void wd_map_sc(MTLScissorRect *r, NSUInteger tw, NSUInteger th) {
    if (g_wd <= 0) return;
    int32_t x = (int32_t)r->x, w = (int32_t)r->width, y = (int32_t)r->y, h = (int32_t)r->height; s2a_widen_map_scissor(g_wd_mode, &x, &w); s2a_widen_map_scissor_y(g_wd_mode, &y, &h);
    if (x < 0) { w += x; x = 0; } if (w < 0) w = 0; if ((NSUInteger)x + (NSUInteger)w > tw) w = (int32_t)(tw > (NSUInteger)x ? tw - (NSUInteger)x : 0);
    if (y < 0) { h += y; y = 0; } if (h < 0) h = 0; if ((NSUInteger)y + (NSUInteger)h > th) h = (int32_t)(th > (NSUInteger)y ? th - (NSUInteger)y : 0);
    r->x = (NSUInteger)x; r->width = (NSUInteger)w; r->y = (NSUInteger)y; r->height = (NSUInteger)h;
}
// 大于 4 KB 的改写副本从 1 MB 一块的缓冲里切（同 Vulkan 层 wd_alloc；原先每笔新建 MTLBuffer，10-26 哈迪斯同一写法掉帧）；块被命令缓冲引用，换块时放掉本层的引用
static __strong id<MTLBuffer> g_wd_chunk; static NSUInteger g_wd_chunk_off;
static void wd_session_reset(void) {
    pthread_mutex_lock(&g_wd_mu);
    for (uint32_t i = 0; i < g_wd_ngone; i++) s2a_widen_release(g_wd_gone[i]);
    free(g_wd_gone); g_wd_gone = NULL; g_wd_ngone = g_wd_cgone = 0;
    g_wd_chunk = nil; g_wd_chunk_off = 0; g_wd = -1; g_wd_sh = 0;
    atomic_store(&g_wd_ids, 0x60000000u);
    g_wd_mode = g_wd_side_on = 0; memset(g_wd_sides, 0, sizeof g_wd_sides);
    memset(g_wd_bound, 0, sizeof g_wd_bound); memset(g_wd_b, 0, sizeof g_wd_b); memset(g_wd_gh, 0, sizeof g_wd_gh);
    g_wd_frame = g_wd_tc = g_wd_td = 0; g_wd_tr0 = -2; g_wd_tr1 = 0; g_wd_trs = 1;
    g_wd_draws = g_wd_core = g_wd_rw = g_wd_big = g_wd_fragx = g_wd_seed = g_wd_lost = g_wd_nosub = 0;
    pthread_mutex_unlock(&g_wd_mu);
}
static id<MTLBuffer> wd_alloc(NSUInteger n, NSUInteger *off) {
    NSUInteger a = (g_wd_chunk_off + 255) & ~(NSUInteger)255;
    if (!g_wd_chunk || a + n > g_wd_chunk.length) { g_wd_chunk = [gl_dev newBufferWithLength:MAX((NSUInteger)1 << 20, n) options:MTLResourceStorageModeShared]; a = 0; }
    g_wd_chunk_off = a + n; *off = a; return g_wd_chunk;
}
// ⑤：uniform 照原样绑完之后，有改写的槽换成改写后的字节（≤ 4 KB 走 setBytes，更大的进分配块）
static void wd_emit(id<MTLRenderCommandEncoder> re) {
    int any = 0;
    pthread_mutex_lock(&g_wd_mu);
    for (int st = 0; st < 2; st++)
        for (uint32_t m = g_wd_bound[st]; m; m &= m - 1) {
            int sl = __builtin_ctz(m); uint32_t n = g_wd_b[st][sl].len;
            if (!n || !s2a_widen_cbuf_emit(st, sl, g_wd_scr, n)) continue;
            any = 1;
            if (n <= 4096) { if (st) [re setFragmentBytes:g_wd_scr length:n atIndex:(NSUInteger)sl]; else [re setVertexBytes:g_wd_scr length:n atIndex:(NSUInteger)sl]; }
            else { NSUInteger off; id<MTLBuffer> b = wd_alloc(n, &off); memcpy((uint8_t *)b.contents + off, g_wd_scr, n); g_wd_big++;
                   if (st) [re setFragmentBuffer:b offset:off atIndex:(NSUInteger)sl]; else [re setVertexBuffer:b offset:off atIndex:(NSUInteger)sl]; }
        }
    pthread_mutex_unlock(&g_wd_mu);
    g_wd_rw += any;
}
// 上屏（egl.m eglSwapBuffers）：核心定下一帧的出图目标，裁剪按放宽换算；crop 原地改（0 宽高 = 整张，按游戏的表面尺寸）
void gl_wd_present(uint32_t id, uint32_t w, uint32_t h, int crop[4]) {
    // 满屏判据免判种类交给上屏层（同 widen_glue.inc wd_present；11-01 街霸合集：核心定了「16:9 原比例页」两侧清黑，GL 上屏没交种类，判据把原比例黑边判成未满屏 20 次）
    mtl_fit_pillar(0);
    if (g_wd <= 0 || !id) return;
    pthread_mutex_lock(&g_wd_mu);
    s2a_widen_crop c = {0, (int32_t)w, 0, (int32_t)h, 16, 9};
    if (crop[2] > 0 && crop[3] > 0) { c.left = crop[0]; c.right = crop[0] + crop[2]; c.top = crop[1]; c.bottom = crop[1] + crop[3]; }
    wd_fb_present_tex(id, w, h); wd_p2_present();   // 原比例回退：交上次两侧覆盖样本、起这一帧的采样（widen_fallback.inc）
    int pr = s2a_widen_present(id, &c); g_p2_fb = pr == 5; g_wd_frame++;
    mtl_fit_pillar(pr == 1 || pr == 2 || pr == 5 ? pr : 0);
    crop[0] = c.left; crop[1] = c.top; crop[2] = c.right - c.left; crop[3] = c.bottom - c.top;
    static uint64_t n; if (++n % 300 == 0) { char line[4096]; s2a_widen_report(line, sizeof line);
        GLOG("宽屏核心：绘制 %llu（进核心 %llu、有改写 %llu、大于 4 KB 的改写 %llu、读片元坐标要横向倍率 %llu；影子先拷原图内容 %llu、上传作废丢内容 %llu、"
             "按链 / 换位采样没换影子 %llu）；%s", (unsigned long long)g_wd_draws, (unsigned long long)g_wd_core,
             (unsigned long long)g_wd_rw, (unsigned long long)g_wd_big, (unsigned long long)g_wd_fragx, (unsigned long long)g_wd_seed, (unsigned long long)g_wd_lost,
             (unsigned long long)g_wd_nosub, line); }
    pthread_mutex_unlock(&g_wd_mu);
}
// 整幅清屏（gl_clear 挂起到下一遍 load-action）：颜色附件 i 是纯 2D 世界目标就把挂起的清屏 alpha 挪成哨兵
static void wd_fb_gl_clear_full(const gl_target *t, int i, float rgba[4]) {
    if (g_wd <= 0 || !t->cid[i] || !t->col[i] || !wd_p2_is_world(t->cid[i])) return;
    MTLClearColor cc = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
    wd_fb_arm_full(t->cid[i], t->col[i], (uint32_t)s2a_widen_tex_guest_w(t->cid[i], (int)t->col[i].width), &cc); rgba[3] = (float)cc.alpha;
}
// 带裁剪的清屏（画成三角形）：只认单个颜色附件（清除管线给所有附件同一颜色，改 alpha 不能波及别的附件）；g = 换算前的客体裁剪宽，sc = 换算到存储后的范围
static void wd_fb_gl_clear_rect(const gl_target *t, float rgba[4], int full_mask, MTLScissorRect sc, long g) {
    int n = 0, i0 = -1; for (int i = 0; i < GL_COLOR_TARGETS; i++) if (t->col[i]) { n++; if (i0 < 0) i0 = i; }
    if (g_wd <= 0 || n != 1 || !t->cid[i0] || !wd_p2_is_world(t->cid[i0])) return;
    wd_fb_arm_rect(t->cid[i0], t->col[i0], (uint32_t)s2a_widen_tex_guest_w(t->cid[i0], (int)t->col[i0].width), rgba, full_mask ? 0xf : 0, sc, g, (long)sc.width);
}

