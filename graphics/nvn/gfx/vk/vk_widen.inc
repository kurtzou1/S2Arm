// Vulkan 层接宽屏第三层核心（graphics/widen，接口 graphics/widen/export/s2a_widen.h，通用模式与 NVN 直连同一份识别 / 改写核心）。由 hle_vk.m 在录制 / 回放之间 #include。
// 调用顺序照核心约定（s2a_widen.h 第 3 节）：开渲染遍登记目标 → 每笔绘制 ① 视口快判 ② 各常量槽交给核心 ③ 定画法 ④ 视口 / 裁剪换算 ⑤ 各槽出数，有改写的槽绑改写后的字节。
// 与 NVN 直连那份（graphics/nvn/widen_glue.inc）的区别：Vulkan 层的贴图都由本层建（GPU 私有），所以「整套放宽」时渲染目标在建的时候就按核心给的宽建；
//   游戏看到的尺寸（vkGetImageMemoryRequirements、拷贝坐标、帧缓冲尺寸）不变，换算只在本层内。
// 开关同直连统一的 S2A_WIDEN_DIRECT（10-26 起缺省开，=0 关）；试第三层时另给 S2A_WIDEN_FULL=1（原生层 widen.c）。
// v1 范围：常量读法表没有（所有着色器按「整个绑定都读」）；顶点越界外推没有（离线翻译没加外推尾段，push 恒不交）；读片元坐标的程序不乘横向倍率（计数报出）。
#include "../../../widen/export/s2a_widen.h"
int s2a_screen_w(void); int s2a_screen_h(void); int s2a_widen_game(void); int s2a_widen_layout(void); int s2a_widen_full(void);   // runtime/src/widen.c

static int g_wd = -1;            // -1 未定；0 关；> 0 核心模式（S2A_WIDEN_UI / ALL / PILLAR）
static int32_t g_wd_sh;          // 所有着色器共用的句柄（没有读法表）
static _Atomic uint32_t g_wd_ids = 0x40000000u;   // 本层给核心的贴图号（图像 / 视图各一个）；与 NVN 层的序号不重叠
static pthread_mutex_t g_wd_mu = PTHREAD_MUTEX_INITIALIZER;   // 核心同一时刻一条线程：建图像（游戏线程）与回放（提交线程）都经这把锁
static int g_wd_mode;            // 本笔画法
static int32_t g_wd_sides[4]; static int g_wd_side_on;   // 本笔起了 16:9 原比例页：两侧条带（s2a_widen_page_sides），pre_draw 画这笔前清黑
static int32_t g_wd_rows[4]; static int g_wd_row_on;     // 同上，窄屏加高的目标：上下条带（s2a_widen_page_rows，行，整宽），一并清黑（同 NVN 层 10-28 B06）
static uint32_t g_wd_bound[2];   // 交给核心时非空的槽（位），顶点 / 片元；每笔只走这些和本笔用到的
static struct { const void *ptr; uint32_t len; uint64_t sub, pseq; } g_wd_b[2][32];   // sub：交给核心时所在的提交（g_ev_val，回放在 g_qmu 里、整次回放不变）；pseq：推常量槽的内容序号（其余 0）
// 改写副本复用（同 NVN 层 g_wd_last）：同一次提交、同一绑定、核心出数状态版本没变 → 上次的副本照用，不再调 ⑤、不再拷（10-26 哈迪斯：每笔新建 > 4 KB 缓冲、整段拷贝，CPU 0.17 → 0.78 核）
static struct { const void *ptr; uint32_t len; uint64_t sub, pseq; int64_t gen; __unsafe_unretained id<MTLBuffer> buf; NSUInteger off; } g_wd_last[2][32];
static uint64_t g_wd_reuse, g_wd_chunks;
static uint32_t g_wd_c0, g_wd_d0 = ~0u;    // 上次交给核心的颜色目标 0 / 深度目标
static uint64_t g_wd_draws, g_wd_core, g_wd_rw, g_wd_big, g_wd_fragx;
// 副本分配：按 1 MB 一块切（不再每笔新建缓冲）。块换下时记下本次提交完成时的信号值（回放在 g_qmu 里，本次提交结束时信号 g_ev_val + 1），
//   完成计数 g_done 到了就收回再用（池，最多 8 块；原生层线 10-26：哈迪斯每帧约 2 MB，不收回就是每秒一百多次 1 MB 分配）
static __strong id<MTLBuffer> g_wd_chunk; static NSUInteger g_wd_chunk_off;
static struct { __strong id<MTLBuffer> b; uint64_t until; } g_wd_pool[8]; static int g_wd_npool;
static id<MTLBuffer> wd_alloc(NSUInteger n, NSUInteger *off) {
    NSUInteger a = (g_wd_chunk_off + 255) & ~(NSUInteger)255;   // 常量缓冲偏移按 256 对齐（Metal 各平台上限）
    if (!g_wd_chunk || a + n > g_wd_chunk.length) {
        id<MTLBuffer> nb = nil; uint64_t done = atomic_load(&g_done);
        for (int i = 0; i < g_wd_npool && !nb; i++) if (g_wd_pool[i].until <= done && g_wd_pool[i].b.length >= n) { nb = g_wd_pool[i].b; g_wd_pool[i] = g_wd_pool[--g_wd_npool]; g_wd_pool[g_wd_npool].b = nil; }
        if (g_wd_chunk && g_wd_npool < 8) { g_wd_pool[g_wd_npool].b = g_wd_chunk; g_wd_pool[g_wd_npool].until = g_ev_val + 1; g_wd_npool++; }
        if (!nb) { nb = [g_dev newBufferWithLength:MAX((NSUInteger)1 << 20, n) options:MTLResourceStorageModeShared]; g_wd_chunks++; }
        g_wd_chunk = nb; a = 0;
    }
    g_wd_chunk_off = a + n; *off = a; return g_wd_chunk;
}
static uint8_t g_wd_scr[65536];
// S2A_WIDEN_PROF：宽屏钩子（wd_draw + wd_emit）每笔花的本线程用户态指令数（同 NVN 层，不受抢占 / 整机负载影响），每 300 帧统计行带上；不设不计
int thread_selfcounts(int type, void *buf, size_t nbytes);
static int g_wd_prof = -1; static uint64_t g_wd_prof_t, g_wd_prof_n;
static inline uint64_t wd_icount(void) { uint64_t c[2] = {0, 0}; thread_selfcounts(1, c, sizeof c); return c[0]; }

static int wd_on(void) {
    if (__builtin_expect(g_wd >= 0, 1)) return g_wd;
    pthread_mutex_lock(&g_wd_mu);
    if (g_wd < 0) {
        const char *e = getenv("S2A_WIDEN_DIRECT");
        if (e && !strcmp(e, "0")) { VLOG("宽屏核心：直连第三层关（S2A_WIDEN_DIRECT=0）"); g_wd = 0; }
        else {
            uint32_t fl = (s2a_widen_game() ? S2A_WIDEN_GAME : 0) | (s2a_widen_layout() ? S2A_WIDEN_LAYOUT : 0) | (s2a_widen_full() ? S2A_WIDEN_FULL : 0);
            int m = s2a_widen_init(s2a_screen_w(), s2a_screen_h(), fl);
            if (m != S2A_WIDEN_OFF) g_wd_sh = s2a_widen_shader(0, NULL, 0);
            VLOG("宽屏核心：屏幕宽 %d，标志 %#x，模式 %d（0 关 / 1 界面 / 2 整套放宽 / 3 黑边），k %.4f", s2a_screen_w(), fl, m, s2a_widen_k());
            g_wd = m == S2A_WIDEN_OFF ? 0 : m;
        }
    }
    pthread_mutex_unlock(&g_wd_mu);
    return g_wd;
}
static uint32_t wd_new_id(void) { return atomic_fetch_add(&g_wd_ids, 1) + 1; }
// 能当颜色 / 深度目标的图像：返回实际要建的宽（不放宽 = w），*rh = 实际要建的高（窄屏加高的 = 核心的放高高，s2a_widen_tex_h；不加高 = h；rh 可空）。
//   rebuild：存储由本层建、能在运行中重建（交换链图像不行）→ 尺寸不属 16:9 一族的交核心按内容判画布
//   11-02 银河2 Duo 外屏（屏比 16:9 窄）：原先只取宽、高照游戏建，核心却已登记加高、投影 y 乘 1/Ky、上屏竖裁按放高高取 → 画面纵向压扁、底部一整条黑
static uint32_t wd_image(uint32_t id, uint32_t w, uint32_t h, int rebuild, uint32_t *rh) {
    if (rh) *rh = h;
    if (wd_on() <= 0) return w;
    pthread_mutex_lock(&g_wd_mu); int r = s2a_widen_texture(id, (int)w, (int)h, 1.0f, S2A_WIDEN_USE_RT | (rebuild ? S2A_WIDEN_USE_REBUILD : 0)), th = s2a_widen_tex_h(id, (int)h); pthread_mutex_unlock(&g_wd_mu);
    if (rh && th > (int)h) *rh = (uint32_t)th;
    return r > 0 ? (uint32_t)r : w;
}
// ---------- 按内容判画布（10-30 银河2：场景画在 1920×1584 的 Wii EFB 上，尺寸不属 16:9 一族、建的时候不放宽） ----------
// 核心在某次提交里判出画布（s2a_widen_promoted），下一次提交回放前在这里重建：同参数、按核心给的新宽新建贴图，旧内容按 Hor 平移 (新宽 − 旧宽) / 2 拷进中间
//   （单采样；多重采样不拷，一帧瞬态），图像的视图按原参数在新贴图上重派生、重新交核心登记（父已放宽 → 视图按级放宽）。帧缓冲开渲染遍时读视图的贴图，自动用新的；
//   描述符里存的是重建前的贴图：旧 → 新记进 g_wd_remap，绑定时换（wd_fresh，只在发生过重建后才查）
static VkImage *g_wd_imgs; static uint32_t g_wd_nimg, g_wd_cimg;   // 本层建的图像（按贴图号找回）；g_qmu / 建图像在游戏线程，表本身在 g_wd_mu 里改
static NSMapTable<id<MTLTexture>, id<MTLTexture>> *g_wd_remap;     // 重建前的贴图 / 视图贴图 → 重建后的（键强引用：描述符里还有旧的，换完它就不再被用到）
static uint64_t g_wd_promoted;
static void wd_track(VkImage im, int on) {
    if (g_wd <= 0 || !im || !im->wid) return;
    pthread_mutex_lock(&g_wd_mu);
    if (on) { if (g_wd_nimg == g_wd_cimg) { g_wd_cimg = g_wd_cimg ? g_wd_cimg * 2 : 256; g_wd_imgs = realloc(g_wd_imgs, g_wd_cimg * sizeof *g_wd_imgs); if (!g_wd_imgs) abort(); } g_wd_imgs[g_wd_nimg++] = im; }
    else for (uint32_t i = 0; i < g_wd_nimg; i++) if (g_wd_imgs[i] == im) { g_wd_imgs[i] = g_wd_imgs[--g_wd_nimg]; break; }
    pthread_mutex_unlock(&g_wd_mu);
}
static void wd_fresh(desc_t *e) { id<MTLTexture> n = [g_wd_remap objectForKey:e->tex]; if (n) e->tex = n; }
static id<MTLTexture> wd_rederive(VkImageView v) {
    VkImage im = v->img; if (v->whole) return im->tex;
    return [im->tex newTextureViewWithPixelFormat:v->pf textureType:v->tt levels:NSMakeRange(v->lv0, v->lvn)
                                           slices:NSMakeRange(v->tt == MTLTextureType3D ? 0 : v->ly0, v->tt == MTLTextureType3D ? 1 : v->lyn) swizzle:v->sw];
}
static void wd_promote(id<MTLCommandBuffer> cb) {
    if (g_wd <= 0) return;
    uint32_t ids[16]; pthread_mutex_lock(&g_wd_mu); int n = s2a_widen_promoted(ids, 16); pthread_mutex_unlock(&g_wd_mu);
    for (int i = 0; i < n; i++) @autoreleasepool {
        VkImage im = NULL; pthread_mutex_lock(&g_wd_mu); for (uint32_t k = 0; k < g_wd_nimg && !im; k++) if (g_wd_imgs[k]->wid == ids[i]) im = g_wd_imgs[k]; pthread_mutex_unlock(&g_wd_mu);
        if (!im || !im->tex) { VLOG("【红】宽屏核心：判成画布的贴图 %u 本层找不到（已毁或不是本层建的），没重建", ids[i]); continue; }
        id<MTLTexture> old = im->tex; uint32_t h1 = im->h, w1 = wd_image(im->wid, im->w, im->h, 1, &h1);   // 核心已登记放宽 / 加高：同尺寸再问一次就是新宽 / 新高（窄屏晋升只加高，11-02）
        if (w1 <= old.width && h1 <= old.height) { VLOG("【红】宽屏核心：画布 %u 新尺寸 %ux%u 不比旧的 %lux%lu 大，没重建", ids[i], w1, h1, (unsigned long)old.width, (unsigned long)old.height); continue; }
        if (w1 < old.width) w1 = (uint32_t)old.width; if (h1 < old.height) h1 = (uint32_t)old.height;
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = old.textureType; td.pixelFormat = old.pixelFormat; td.width = w1; td.height = h1; td.depth = old.depth;
        td.mipmapLevelCount = old.mipmapLevelCount; td.sampleCount = old.sampleCount; td.arrayLength = old.arrayLength; td.usage = old.usage; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
        if (!t) { VLOG("【红】宽屏核心：画布 %u 新建 %ux%u 贴图失败，没重建", ids[i], w1, h1); continue; }
        if (old.sampleCount == 1) {
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            NSUInteger pad = (w1 - old.width) / 2, pady = (h1 - old.height) / 2, sl = old.arrayLength * (old.textureType == MTLTextureTypeCube || old.textureType == MTLTextureTypeCubeArray ? 6 : 1);
            for (NSUInteger l = 0; l < old.mipmapLevelCount; l++) {
                NSUInteger ow = MAX(old.width >> l, 1), nw = MAX(t.width >> l, 1), px = MIN(pad >> l, nw - MIN(ow, nw));
                NSUInteger oh = MAX(old.height >> l, 1), nh = MAX(t.height >> l, 1), py = MIN(pady >> l, nh - MIN(oh, nh));
                for (NSUInteger z = 0; z < sl; z++)
                    [be copyFromTexture:old sourceSlice:z sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(MIN(ow, nw), MIN(oh, nh), MAX(old.depth >> l, 1))
                              toTexture:t destinationSlice:z destinationLevel:l destinationOrigin:MTLOriginMake(px, py, 0)];
            }
            [be endEncoding];
        }
        if (!g_wd_remap) g_wd_remap = [NSMapTable strongToStrongObjectsMapTable];
        [g_wd_remap setObject:t forKey:old]; im->tex = t;
        int nv = 0;
        for (VkImageView v = im->views; v; v = v->vnext) {
            id<MTLTexture> ov = v->tex, nt = wd_rederive(v);
            if (!nt) { VLOG("【红】宽屏核心：画布 %u 的视图重派生失败（格式 %lu 类型 %lu）", ids[i], (unsigned long)v->pf, (unsigned long)v->tt); continue; }
            if (ov && ov != old) [g_wd_remap setObject:nt forKey:ov];
            v->tex = nt; wd_view(v->wid, im->wid, (int)v->lv0, v->gw); nv++;
        }
        g_wd_c0 = 0; g_wd_d0 = ~0u; g_wd_promoted++;   // 目标登记缓存作废：同一视图号在核心里已变成放宽目标
        VLOG("宽屏核心：按内容判画布重建图像 %u（%ux%u → 贴图 %ux%u，视图 %d 个，旧内容平移 %u 列 %u 行%s）", ids[i], im->w, im->h, w1, h1, nv, (w1 - (uint32_t)old.width) / 2, (h1 - (uint32_t)old.height) / 2, old.sampleCount == 1 ? "" : "，多重采样不拷");
    }
}
static void wd_view(uint32_t id, uint32_t parent, int level, uint32_t w0) {
    if (wd_on() <= 0) return;
    pthread_mutex_lock(&g_wd_mu); s2a_widen_view(id, parent, level, (int)w0); pthread_mutex_unlock(&g_wd_mu);
}
static void wd_release(uint32_t id) {
    if (g_wd <= 0 || !id) return;
    pthread_mutex_lock(&g_wd_mu); s2a_widen_release(id); pthread_mutex_unlock(&g_wd_mu);
}
static void wd_targets(uint32_t c0, uint32_t d0) {
    if (g_wd <= 0 || (c0 == g_wd_c0 && d0 == g_wd_d0)) return;
    pthread_mutex_lock(&g_wd_mu); s2a_widen_targets(c0, d0); pthread_mutex_unlock(&g_wd_mu);
    g_wd_c0 = c0; g_wd_d0 = d0;
}
// 一笔绘制的常量槽：shinfo 里 u（uniform 缓冲）与 p（推常量）的 Metal 槽 → 本笔它在 CPU 上的内容；*seq：推常量的内容序号（UBO 为 0）。
//   推常量在回放状态里恒是同一块 s->pc、每次 vkCmdPushConstants 原地覆盖：只按「同指针、同一次提交」跳过 / 复用，一次提交里第二笔起的推常量变化核心看不到、
//   出数副本还会把上一笔的矩阵绑给这一笔（10-29 银河2 方案 ⑨：投影在推常量偏移 48）。所以推常量另比内容序号
static int wd_cbuf(rs_t *s, const shinfo *si, int i, const void **ptr, uint32_t *len, uint64_t *seq) {
    const shres *r = &si->res[i]; *seq = 0;
    if (r->kind == 'p') { const VkPipelineLayout pl = s->pipe->layout; *ptr = s->pc; *len = pl ? pl->pc_size : 0; *seq = s->pc_seq; return 1; }
    if (r->kind != 'u' || r->count != 1) return 0;
    const uint32_t *dyn; int old; VkDescriptorSet ds = set_of(s, 0, r->set, r->binding, &dyn, &old); if (!ds) return 0;   // 同 bind_res 取集（hle_vk.m set_of）
    const VkDescriptorSetLayout L = ds->L; int bi = r->binding < 128 ? L->idx[r->binding] : -1; if (bi < 0) return 0;
    const lbind *lb = &L->b[bi]; const desc_t *e = &ds->d[lb->base]; if (!e->buf) return 0;
    VkDeviceSize off = e->off; if (lb->dyn >= 0 && lb->dyn < 16 && dyn) off += dyn[lb->dyn];
    VkDeviceSize n = e->range ? e->range : e->buf.length - off; if (off >= e->buf.length) return 0;
    if (n > e->buf.length - off) n = e->buf.length - off;
    if (n > sizeof g_wd_scr) n = sizeof g_wd_scr;
    *ptr = (const uint8_t *)e->buf.contents + off; *len = (uint32_t)n; return 1;
}
// ①–③：返回 1 = 本笔进了核心（之后视口按 g_wd_mode 换算、绑完资源再调 wd_emit）
static int wd_draw_(rs_t *s, VkPipeline p, int has_color);
static int wd_draw(rs_t *s, VkPipeline p, int has_color) {
    if (g_wd <= 0) return 0;
    if (__builtin_expect(g_wd_prof < 0, 0)) g_wd_prof = getenv("S2A_WIDEN_PROF") != NULL;
    if (!g_wd_prof) return wd_draw_(s, p, has_color);
    uint64_t c0 = wd_icount(); int r = wd_draw_(s, p, has_color); g_wd_prof_t += wd_icount() - c0; g_wd_prof_n++; return r;
}
static int wd_draw_(rs_t *s, VkPipeline p, int has_color) {
    g_wd_draws++;
    MTLViewport v = p->has_vp ? p->vp : vp_of(&s->vp);
    pthread_mutex_lock(&g_wd_mu);
    if (!s2a_widen_viewport((float)v.originX, (float)v.width, (float)v.height, 1.0f)) { g_wd_mode = S2A_WIDEN_KEEP; pthread_mutex_unlock(&g_wd_mu); return 0; }
    s2a_widen_draw_in in; memset(&in, 0, sizeof in);
    in.vp_x = (float)v.originX; in.vp_y = (float)v.originY; in.vp_w = (float)v.width; in.vp_h = (float)v.height; in.target_scale = 1; in.flags = has_color ? S2A_WIDEN_DRAW_COLOR : 0;
    const shinfo *sh[2] = {p->vs, p->fs};
    for (int st = 0; st < 2; st++) {
        uint32_t used = 0; const void *ptr[32] = {0}; uint32_t len[32] = {0}; uint64_t seq[32] = {0};
        if (sh[st]) { in.shader[st] = g_wd_sh; for (int i = 0; i < sh[st]->nres; i++) { int sl = sh[st]->res[i].slot; if (sl < 32 && wd_cbuf(s, sh[st], i, &ptr[sl], &len[sl], &seq[sl])) used |= 1u << sl; } }
        for (uint32_t m = used | g_wd_bound[st]; m; m &= m - 1) {   // 用到的槽 + 上一笔还挂着的（没用到的解绑）
            int sl = __builtin_ctz(m);
            if (g_wd_b[st][sl].ptr == ptr[sl] && g_wd_b[st][sl].len == len[sl] && g_wd_b[st][sl].pseq == seq[sl] && (!len[sl] || g_wd_b[st][sl].sub == g_ev_val)) continue;   // 同一次提交里同一块游戏内存不变（同 NVN 层）；推常量还要同内容序号
            s2a_widen_cbuf_bind(st, sl, ptr[sl], len[sl]); g_wd_b[st][sl].ptr = ptr[sl]; g_wd_b[st][sl].len = len[sl]; g_wd_b[st][sl].sub = g_ev_val; g_wd_b[st][sl].pseq = seq[sl];
            if (len[sl]) g_wd_bound[st] |= 1u << sl; else g_wd_bound[st] &= ~(1u << sl);
        }
    }
    static s2a_widen_tex tx[32]; int ntx = 0;   // 片元实际采样的贴图（核心据此认「采样了放宽 / 原生宽图」）
    for (int i = 0; p->fs && i < p->fs->nres && ntx < 32; i++) {
        const shres *r = &p->fs->res[i]; if (r->kind != 't' && r->kind != 'c') continue;
        const uint32_t *dyn; int old; VkDescriptorSet ds = set_of(s, 1, r->set, r->binding, &dyn, &old); if (!ds) continue;
        int bi = r->binding < 128 ? ds->L->idx[r->binding] : -1; if (bi < 0) continue;
        // 每个实际采样的图像都报（同 GL 层 gl_widen.inc：只报有宽屏号的，界面图集不在表里，空表被当成「只采小图」→ 界面层原样铺满、按游戏坐标偏左）：
        //   有宽屏号的报号与游戏宽高，其余报 0（不放宽、核心只看尺寸）
        const desc_t *e = &ds->d[ds->L->b[bi].base]; if (!e->wid && !e->tex) continue;
        tx[ntx++] = e->wid ? (s2a_widen_tex){e->wid, (int32_t)e->gw, (int32_t)e->gh, 1.0f, 0} : (s2a_widen_tex){0, (int32_t)e->tex.width, (int32_t)e->tex.height, 1.0f, 0};
    }
    in.tex = tx; in.ntex = ntx;
    s2a_widen_draw_out out; g_wd_mode = s2a_widen_draw(&in, &out);
    g_wd_side_on = (out.flags & S2A_WIDEN_OUT_PAGE_SIDES) && s2a_widen_page_sides(g_wd_sides);
    g_wd_row_on = (out.flags & S2A_WIDEN_OUT_PAGE_SIDES) && s2a_widen_page_rows(g_wd_rows);   // 窄屏：页只占中间 [pad, pad+h0) 行，上下两条没人写
    if (out.frag_scale_x != 1.0f) g_wd_fragx++;
    if (out.flags & S2A_WIDEN_OUT_NO_EMIT) { pthread_mutex_unlock(&g_wd_mu); g_wd_core++; return 0; }
    pthread_mutex_unlock(&g_wd_mu);
    g_wd_core++; return 1;
}
// ⑤：资源照原样绑完之后，有改写的槽换成改写后的字节：同一次提交、同一绑定、出数状态版本没变就复用上次的副本（核心约定，s2a_widen_state_gen），否则出数进分配块
static void wd_emit_(rs_t *s);
static void wd_emit(rs_t *s) { if (!g_wd_prof) { wd_emit_(s); return; } uint64_t c0 = wd_icount(); wd_emit_(s); g_wd_prof_t += wd_icount() - c0; }
static void wd_emit_(rs_t *s) {
    int any = 0, nb = 0; struct { int st, sl; __unsafe_unretained id<MTLBuffer> b; NSUInteger off; } bind[64];   // 锁里只出数，Metal 绑定在锁外做（原生层线 10-26）
    pthread_mutex_lock(&g_wd_mu);
    int64_t gen = s2a_widen_state_gen();
    for (int st = 0; st < 2; st++)
        for (uint32_t m = g_wd_bound[st]; m; m &= m - 1) {
            int sl = __builtin_ctz(m); uint32_t n = g_wd_b[st][sl].len; const void *p = g_wd_b[st][sl].ptr; uint64_t q = g_wd_b[st][sl].pseq;
            typeof(g_wd_last[0][0]) *L = &g_wd_last[st][sl];
            id<MTLBuffer> b = nil; NSUInteger off = 0;
            if (L->sub == g_ev_val && L->ptr == p && L->len == n && L->pseq == q && L->gen == gen) { b = L->buf; off = L->off; g_wd_reuse++; }
            else {
                if (n && s2a_widen_cbuf_emit(st, sl, g_wd_scr, n)) { b = wd_alloc(n, &off); memcpy((uint8_t *)b.contents + off, g_wd_scr, n); if (n > 4096) g_wd_big++; }
                L->sub = g_ev_val; L->ptr = p; L->len = n; L->pseq = q; L->gen = gen; L->buf = b; L->off = off;
            }
            if (!b) continue;
            any = 1; bind[nb].st = st; bind[nb].sl = sl; bind[nb].b = b; bind[nb].off = off; nb++;
        }
    pthread_mutex_unlock(&g_wd_mu);
    for (int i = 0; i < nb; i++) { if (bind[i].st) [s->re setFragmentBuffer:bind[i].b offset:bind[i].off atIndex:bind[i].sl]; else [s->re setVertexBuffer:bind[i].b offset:bind[i].off atIndex:bind[i].sl]; }
    g_wd_rw += any;
}
// 拷贝区域的横向换算（vkCmdCopyImage 等按游戏坐标给区域）：放宽的图像（贴图宽 ≠ 游戏宽）第 0 级按核心换算，其余级按比例；没放宽的原样。
//   10-25 哈迪斯：放宽后的场景最后经图像拷贝进交换链，区域没换算只拷了左 1280 列，右侧 284 列黑（直连线定位）
static void wd_map_span(VkImage im, uint32_t level, int32_t *x, uint32_t *w) {
    if (g_wd <= 0 || !im || !im->wid || !im->tex) return;
    uint32_t gw = im->w >> level ? im->w >> level : 1, tw = (uint32_t)im->tex.width >> level ? (uint32_t)im->tex.width >> level : 1;
    if (tw == gw) return;
    int64_t x0 = *x, x1 = (int64_t)*x + *w;
    if (!level) { pthread_mutex_lock(&g_wd_mu); x0 = s2a_widen_map_x(im->wid, (int)x0); x1 = s2a_widen_map_x(im->wid, (int)x1); pthread_mutex_unlock(&g_wd_mu); }
    else { x0 = x0 * tw / gw; x1 = x1 * tw / gw; }
    if (x1 > tw) x1 = tw; if (x0 < 0) x0 = 0;
    *x = (int32_t)x0; *w = x1 > x0 ? (uint32_t)(x1 - x0) : 0;
}
// 同上，纵向（窄屏加高的图像：存储高 ≠ 游戏高）：按存储高 ÷ 游戏高换算，同核心上屏竖裁 MapCropY 与 NVN 层 copy_t2t 的口径（起点向下、终点向上取整，盖住碰到的每一行）
static void wd_map_span_y(VkImage im, uint32_t level, int32_t *y, uint32_t *h) {
    if (g_wd <= 0 || !im || !im->wid || !im->tex) return;
    uint32_t gh = im->h >> level ? im->h >> level : 1, th = (uint32_t)im->tex.height >> level ? (uint32_t)im->tex.height >> level : 1;
    if (th == gh) return;
    int64_t y0 = (int64_t)*y * th / gh, y1 = (((int64_t)*y + *h) * th + gh - 1) / gh;
    if (y1 > th) y1 = th; if (y0 < 0) y0 = 0;
    *y = (int32_t)y0; *h = y1 > y0 ? (uint32_t)(y1 - y0) : 0;
}
// 上屏：核心定下一帧的出图目标，裁剪按放宽换算；crop 原地改（0 宽高 = 整张）
static void wd_present(uint32_t id, uint32_t w, uint32_t h, int crop[4]) {
    if (g_wd <= 0 || !id) return;
    pthread_mutex_lock(&g_wd_mu);
    s2a_widen_crop c = {0, (int32_t)w, 0, (int32_t)h, 16, 9};
    if (crop[2] > 0 && crop[3] > 0) { c.left = crop[0]; c.right = crop[0] + crop[2]; c.top = crop[1]; c.bottom = crop[1] + crop[3]; }
    s2a_widen_present(id, &c);
    crop[0] = c.left; crop[1] = c.top; crop[2] = c.right - c.left; crop[3] = c.bottom - c.top;
    static uint64_t n; if (++n % 300 == 0) { char line[4096]; s2a_widen_report(line, sizeof line);
        VLOG("宽屏核心：绘制 %llu（进核心 %llu、有改写 %llu、大于 4 KB 的新出副本 %llu、复用副本 %llu、副本分配块 %llu、读片元坐标要横向倍率 %llu；钩子 %llu 条指令 / 笔）；%s", (unsigned long long)g_wd_draws, (unsigned long long)g_wd_core,
             (unsigned long long)g_wd_rw, (unsigned long long)g_wd_big, (unsigned long long)g_wd_reuse, (unsigned long long)g_wd_chunks, (unsigned long long)g_wd_fragx, (unsigned long long)(g_wd_prof_n ? g_wd_prof_t / g_wd_prof_n : 0), line); g_wd_prof_t = g_wd_prof_n = 0; }
    pthread_mutex_unlock(&g_wd_mu);
}
