// S2Arm 宽屏第三层核心（graphics/widen，NativeAOT 导出 s2a_widen_*，头文件 graphics/widen/export/s2a_widen.h）接进直连回放层：直连模式也走同一份识别 / 改写核心（docs/设计_直连架构.md §12.4）。
// 由 graphics/nvn/gfx/nvn/nvn_mtl.m 在 encode_args 之前 #include（要用回放层的 S / R / g_pass / arena_alloc / cb_len）；nvn_mtl.m 里只加几行调用，改动清单 docs/直连图形层_改动清单.md 记。
// 调用点：draw() 视口前 wd_draw（目标 → 每槽常量 bind → 定画法 → 每槽 emit 进暂存）；视口 / 裁剪按画法换算；encode_args 常量槽有改写就绑暂存；
//         贴图释放 wd_release；上屏 wd_present；提交开始 wd_sub_begin（读数行）。屏幕就是 16:9（宽 ≤ 1920 且高 ≤ 1080，s2a_widen_init 回 OFF；10-26 起比 16:9 窄的屏走加高、不是 OFF）时全部是一次判断就返回。
// v1 范围（动森 = UI 模式：游戏经第二层自己出宽图，核心只把界面层收回 16:9 原尺寸居中）：
//   - 没有离线常量读法表（cbuf_use.tsv 还没出）：所有着色器登记成同一个「整个绑定都读」的句柄；
//   - 顶点着色器带外推尾段（直连库链版本 c407c4b309b7 起，NvShader.push）时登记可外推、把核心给的 push[4] 交给回放层（g_wd_push → 13 号槽），全画布遮罩 / 底按通用模式那样边上推到屏幕边；
//   - 片元采样贴图只报直接绑在纹理槽上的（同 draw_samples_rt 的查法；从常量里取的无绑定句柄不报、平铺寻址不报）；程序读不读片元坐标不报；顶点外推 push[4] 不传（着色器没改过，登记不带 S2A_WIDEN_SH_PUSH）；计算派发不接（不改写 = 读游戏内存原值）；
//   - 这次提交里有 GPU 侧写（内嵌常量更新 / 拷贝）落在绑定上的槽不用改写副本（CPU 此刻读到的不是 GPU 执行时的内容），记数 g_wd_skip_pend。
#include "../widen/export/s2a_widen.h"
int s2a_screen_w(void); int s2a_screen_h(void); int s2a_widen_game(void); int s2a_widen_layout(void); int s2a_widen_full(void);
unsigned s2a_screen_gen(void); int s2a_screen_switch(int w, int h);   // runtime/src/widen.c：运行中换屏的代数 / 直接换（Mac 模拟 S2A_REASPECT_AT）
int s2a_autoplay_on(void) __attribute__((weak_import));   // tests/autoplay（S2A_CS=1 的宿主链进来）：自动玩家在跑   // runtime/src/widen.c（第二 / 三层结果，两种图形模式同一来源）

int thread_selfcounts(int type, void *buf, size_t nbytes);
uint32_t nvn_be_tex_live_n(void); int nvn_be_tex_is_live(uint64_t ser);   // nvn_mtl.m：活着的贴图对象数、这个序号还活着
static int g_wd_prof = -1; static uint64_t g_wd_prof_t, g_wd_prof_n;   // S2A_WIDEN_PROF=1：挂点指令数（读数行报每次提交 / 每笔的指令数）
// 满屏判据「游戏自己出宽图的纯 2D 帧」免判（种类 4）按内容来历认（同通用模式 WidenTexture.Scene3D）：贴图序号 → 内容里有 3D 场景。g_wd_mu 护。
//   被开了深度测试 / 深度写的绘制画过、被采样了带此标记贴图的绘制画过、计算着色器写过（保守）→ 标；整张拷入随源；颜色清屏作废。上屏贴图不带标记 = 这一帧全是 2D 合成。
//   原先按帧记「上次上屏以来有没有深度绘制」：11-13 旷野之息 Pro Max 读盘提示页每帧都有 64×64 离屏 3D 小图（Mac 局 YI3D 打点 3641 / 2863 次首笔深度绘制在 64×64 / 1280×720），
//   纯 2D 的读盘页被判成有 3D，两侧原比例黑边报「出图未满屏」红（玩家看到的也只是这一页，局内铺满）
#define WD_S3D 8192
static uint64_t g_wd_s3d[WD_S3D]; static int g_wd_s3d_n;   // 开放寻址：存「内容里有 3D」的贴图序号（没有 = 没标）
static unsigned wd_s3d_slot(uint64_t ser) { return (unsigned)((ser * 0x9E3779B97F4A7C15ull) >> 51) & (WD_S3D - 1); }
static int wd_s3d_has(uint64_t ser) {
    if (!ser) return 0; unsigned k = wd_s3d_slot(ser);
    for (int i = 0; i < WD_S3D && g_wd_s3d[k]; i++, k = (k + 1) & (WD_S3D - 1)) if (g_wd_s3d[k] == ser) return 1;
    return 0;
}
static void wd_s3d_set(uint64_t ser, int on) {
    if (!ser) return; unsigned k = wd_s3d_slot(ser);
    for (int i = 0; i < WD_S3D && g_wd_s3d[k]; i++, k = (k + 1) & (WD_S3D - 1)) if (g_wd_s3d[k] == ser) {
        if (on) return;
        g_wd_s3d[k] = 0; g_wd_s3d_n--;   // 删：后面同簇的项往回挪（同 wd_release_now）
        for (unsigned j = (k + 1) & (WD_S3D - 1); g_wd_s3d[j]; j = (j + 1) & (WD_S3D - 1)) {
            unsigned h = wd_s3d_slot(g_wd_s3d[j]);
            if ((j > k && (h <= k || h > j)) || (j < k && h <= k && h > j)) { g_wd_s3d[k] = g_wd_s3d[j]; g_wd_s3d[j] = 0; k = j; }
        }
        return;
    }
    if (!on) return;
    if (g_wd_s3d_n >= WD_S3D * 3 / 4) { static int once; if (!once++) MLOG("【红】 S2Arm widen: 3D-content table full (%d textures); further ones are not marked (the fit check may skip a 2D-only frame exemption wrongly)", g_wd_s3d_n); return; }
    g_wd_s3d[k] = ser; g_wd_s3d_n++;
}
static uint64_t g_wd_rs_gpu;   // 本笔片元阶段的支持缓冲副本（render_scale[0] = 片元坐标倍率），0 = 用静态那份（wd_rscale）
static const uint8_t *g_wd_rs_data;   // CPU view of that same completed arena block; never survives submission/reset
static float g_wd_fsc = 1.0f, g_wd_fsyc = 1.0f;   // 本笔片元坐标倍率（横 / 纵；wd_rscale 记，内部分辨率 rs_support 在它上面乘本遍比例）
static int g_wd = -1;          // -1 未定；0 关（OFF）；> 0 开（核心模式）
static int32_t g_wd_sh, g_wd_sh_push;   // 没读法表时所有着色器共用的句柄；顶点着色器带外推尾段（NvShader.push，直连库 s2a_push）的用可外推句柄
static int g_wd_mode;          // 本笔绘制的画法（s2a_widen_draw）
static int g_wd_uvx; static uint64_t g_wd_uvx_n;   // 本笔按 16:9 几何画（原样 / 界面原尺寸居中 / 16:9 页：采样放宽贴图要读中间区，见 uvx_fill）；换算过的笔数
static float g_wd_uvext;   // 本笔带纹理半透明叠加层推满（S2A_WIDEN_OUT_UV_EXTEND）：目标画布放宽比 k，没放宽的贴图横向采样以 0.5 为中心放大 k 倍（见 uvx_fill）；0 = 不放
static void wd_uvx_set(int m) { int on = m == S2A_WIDEN_KEEP || m == S2A_WIDEN_CENTER || m == S2A_WIDEN_PAGE; if (on != g_wd_uvx) { g_wd_uvx = on; g_args_dirty[1] = 1; } }
static int32_t g_wd_sides[4]; static int g_wd_side_on;   // 本笔起了 16:9 原比例页：两侧条带（s2a_widen_page_sides），draw() 画这笔前清黑
static int32_t g_wd_rows[4]; static int g_wd_row_on;     // 同上，窄屏加高的目标：上下条带（s2a_widen_page_rows，行），draw() 画这笔前一并清黑（10-28 B06）
static uint64_t g_wd_gpu[6][16];   // 本笔各阶段各槽改写后的暂存区 GPU 地址（0 = 照原样零拷贝绑游戏内存）
static uint8_t g_wd_had[6];        // 上一笔这一阶段有改写：这一笔参数块不能复用上一笔的
static struct { uint64_t gpu, ptr, sub; uint32_t len; const uint8_t *data; int64_t gen; } g_wd_last[6][16];   // 上一次出数：同一次提交、同绑定、核心状态版本没变就直接复用（不调出数）；版本变了但内容相同也复用副本地址
static uint16_t g_wd_bound[6];     // 交给核心时非空的槽（位）：每笔只走这些和本笔用到的，不扫满 16 槽
static struct { uint64_t ptr; uint32_t len; uint64_t sub; } g_wd_b[6][16];   // 交给核心的绑定（同一次提交里游戏内存不变：同一绑定只比一次影子）
static uint64_t g_wd_c0, g_wd_d0 = ~0ull;  // 上次交给核心的颜色目标 0 / 深度目标
static uint64_t g_wd_draws, g_wd_core, g_wd_rw_draws, g_wd_copies, g_wd_reuse, g_wd_skip_pend, g_wd_light;   // 绘制 / 其中进核心的（画在放宽区域）/ 有改写副本的 / 改写副本因 GPU 侧写不用的
static uint8_t g_wd_scr[65536];   // emit 先写这里，有改写才拷进本次提交的暂存区（NVN 常量绑定上限 64 KB）
// 这次提交里有内嵌常量更新落在绑定上（游戏内存此刻还不是 GPU 执行这笔时读到的内容）：按回放层的影子拼出 GPU 会读到的内容放进这里交给核心，改写照常用上（见 wd_cb_view）
static uint8_t *g_wd_cbv[6][16]; static uint16_t g_wd_viewm[6];   // 各阶段各槽的内容副本（首次用时分配 64 KB）；本笔交给核心的是副本的槽（位）
static uint64_t g_wd_disp, g_wd_disp_wide, g_wd_disp_flat;   // 进核心的派发 / 其中写放宽图像且补了组数 / 写放宽图像但不按像素铺（照原样）
static uint64_t g_wd_view_n;   // 按影子交给核心的槽次（读数行）
// 按影子交的槽里，副本与上次交给核心的是同一份影子（同一段同样的字节）、绑定也没变的：不再交核心（核心逐字节比完也是「没变」），出数同提交内复用上次。
//   11-02 怪猎真机：直连每笔每槽都把均 5 KB 副本交核心整段比，帧 3900→4200 每帧 4207 次、比 20.4 MB、真变的只 170 KB，提交线程每帧 1.24 亿条指令里九成在这条路
static uint16_t g_wd_vsame[6]; static uint64_t g_wd_view_skip, g_wd_view_reuse, g_wd_view_ranged;
static int g_wd_vd = -1;   // S2A_WIDEN_VIEWDELTA=0：关（A/B 与等价单测用），每笔照旧整段交核心
static int wd_vd_on(void) { if (g_wd_vd < 0) { const char *e = getenv("S2A_WIDEN_VIEWDELTA"); g_wd_vd = !(e && !strcmp(e, "0")); } return g_wd_vd; }
// 各副本里现在是哪一份影子（ubp_get 的 g_ubp_q；0 = 不是影子：没拷过 / 延后表 ubd_read 写的）；影子拷进副本 / 副本已是这份不拷的次数（单测）
static uint64_t g_wd_cbq[6][16], g_wd_cbv_copy, g_wd_cbv_same, g_wd_cbv_delta;
static uint32_t g_wd_dr[2 * UBP_DMAX]; static int g_wd_dn;
// 副本现在装的是哪一段（拼它时的地址与长度）：副本按「阶段 × 槽」各一份，同一槽可在同一代延后表 / 同一份影子里先后绑到别处，下面三条复用路径都要同一段才成立
//   （11-02 丝之歌跳台后主画面消失：reg1 在 0xe00 每物体矩阵与 0x3b00 之间换绑，延后表增量只叠「序号 ≥ 上次」的更新到装着另一段的副本上，精灵矩阵错成一点）
static uint64_t g_wd_cp[6][16]; static uint32_t g_wd_cn[6][16];
static uint64_t g_wd_ug[6][16]; static uint32_t g_wd_us[6][16];   // 副本由延后更新拼成时：那时的延后表代号（g_ubd_gen，0 = 不是）与下一个序号（g_ubd_seq）——同代里之后的更新序号都 ≥ 它   // wd_cb_view 回 3 时：副本与上次交出的那份只在这些 [lo, hi) 段里不同（交核心时只比这些）
static uint64_t g_wd_frame; static long g_wd_tr0 = -2, g_wd_tr1, g_wd_trs = 1;   // 诊断：S2A_NVN_WIDEN_TRACE=<起帧>-<止帧>[:<隔几帧>]（帧 = 上屏次数），这些帧里每笔打一行（目标、视口、画法、换算后视口、采样贴图）、每次上屏打一行（同 GL 的 S2A_GL_WIDEN_TRACE）
static pthread_mutex_t g_wd_mu = PTHREAD_MUTEX_INITIALIZER;   // 核心同一时刻一条线程：每次调核心时短暂持锁（一笔绘制 / 一次上屏 / 一次释放），不跨整段提交——上屏线程最多等一笔（10-24：原先整段提交持锁，上屏可能被挡 ~10 ms）
// 已登记给核心的渲染目标：贴图序号 → 宽高（开放寻址；尺寸变了重登记）
enum { WD_T = 8192 };
static struct { uint64_t ser; uint32_t w, h, r, rh; } g_wd_t[WD_T]; static int g_wd_nt;   // r: the core's width for it (s2a_widen_texture; > w = widened storage, tex_widen)
// 待生效的释放：游戏 Finalize 贴图对象时（wd_release，任意线程）核心还不能忘——录好还没回放的绘制仍要画进 / 采样它（贴图序号不复用，晚删只多占一项）。
//   10-26 马车8 直连宽屏标题：临时目标 75966 刚画完（按放宽画）就被释放，回放里下一笔 6070 采样它时核心已不认它是放宽目标，当成 CPU 供图起了第二次 16:9 原比例页，
//   2706 再采样 6070 又平移一次，视频整体右移 3 × 142。排进来的释放等「释放之后开始的那次提交」回放完（wd_sub_end）才交给核心删：
//   wd_sub_begin 记下此刻已排的条数 g_wd_npr_arm，本次提交回放完只删这些；回放中途排进来的留到下一次提交结束
enum { WD_PR = 4096 };
static uint64_t g_wd_pr[WD_PR]; static int g_wd_npr, g_wd_npr_arm;

static int wd_tr_on(void) {
    if (g_wd_tr0 == -2) { const char *e = getenv("S2A_NVN_WIDEN_TRACE"); g_wd_tr0 = -1; if (e && sscanf(e, "%ld-%ld:%ld", &g_wd_tr0, &g_wd_tr1, &g_wd_trs) < 2) g_wd_tr0 = -1; if (g_wd_trs < 1) g_wd_trs = 1; }
    return g_wd_tr0 >= 0 && (long)g_wd_frame >= g_wd_tr0 && (long)g_wd_frame <= g_wd_tr1 && !(((long)g_wd_frame - g_wd_tr0) % g_wd_trs);
}
static const char *g_wd_fskey = "-";   // 追踪行带上本笔片元着色器键（wd_draw_ 设）
// ---------- 横向无细节按内容判（11-01，根因族 2「叠加层没推满」）----------
// 核心按尺寸判「拉宽看不出」不过、又没有内容结论的贴图会在 s2a_widen_draw_out.want_flat 点名（WidenSession.OnlyFlat）。这里量它的横向高频细节：
//   上屏时在旧队列上等本帧提交事件（贴图已上传 / 画好）后跑计算内核 wd_flat，32 行 × 全宽，每点取预乘透明度颜色的横向二阶差，超过 WD_FLAT_D2 的点占比 ≤ WD_FLAT_RATIO
//   = 横向平滑；结果按贴图序号记（下一笔起交给核心：S2A_WIDEN_TEX_FLAT_KNOWN / _CONTENT），并按游戏内存里贴图字节的内容哈希写磁盘缓存
//   （S2A_WIDEN_FLAT_CACHE，缺省 ~/Library/Caches/s2a_widen_flat.tsv），下次进同一页点名当场命中、不等量测。只量 2D 贴图，别的类型记有细节
enum { WD_FLAT_PEND = 1, WD_FLAT_DONE = 0x100 };   // 表里的值：WD_FLAT_PEND = 量着；WD_FLAT_DONE | 贴图标志（S2A_WIDEN_TEX_FLAT_KNOWN 起的那几位）= 量完的结论
#define WD_FLAT_NO (WD_FLAT_DONE | S2A_WIDEN_TEX_FLAT_KNOWN)
#define WD_FLAT_SEAM 15u   // 首末列平均最大通道差 ≤ 15/255 = 首尾无缝（平铺设计）
#define WD_FLAT_D2 0.10f
#define WD_FLAT_RATIO 0.01
static const char k_wd_flat_msl[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void wd_flat(texture2d<float, access::sample> t [[texture(0)]], device atomic_uint *o [[buffer(0)]], constant uint4 &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "  if (p.w == 1u) {\n"   // 第二遍（11-06）：逐行（全部行）与本行中点比，差 > 0.10 的点计入 o[6]——ROW_CONST 要求一个都没有（图集里稀疏的精灵 / 细环不会被 32 行抽样漏掉）
    "    if (g.x >= p.x || g.y >= p.y) return;\n"
    "    constexpr sampler s1(coord::pixel, filter::nearest, address::clamp_to_edge); float y1 = float(g.y) + 0.5f;\n"
    "    float4 q = t.sample(s1, float2(float(g.x) + 0.5f, y1)), m1 = t.sample(s1, float2(float(p.x / 2u) + 0.5f, y1)); q.rgb *= q.a; m1.rgb *= m1.a; float4 v1 = abs(q - m1);\n"
    "    if (max(max(v1.r, v1.g), max(v1.b, v1.a)) > 0.10f) atomic_fetch_add_explicit(&o[6], 1u, memory_order_relaxed);\n"
    "    return; }\n"
    "  if (g.x == 0 || g.x + 1 >= p.x || g.y >= p.z) return;\n"
    "  constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);\n"
    "  float y = (float(g.y) + 0.5f) * float(p.y) / float(p.z);\n"
    "  float4 a = t.sample(s, float2(float(g.x) - 0.5f, y)), b = t.sample(s, float2(float(g.x) + 0.5f, y)), c = t.sample(s, float2(float(g.x) + 1.5f, y));\n"
    "  a.rgb *= a.a; b.rgb *= b.a; c.rgb *= c.a;\n"
    "  float4 d = abs(a - 2.0f * b + c);\n"
    "  bool hf = max(max(d.r, d.g), max(d.b, d.a)) > " "0.10f" ";\n"
    "  atomic_fetch_add_explicit(&o[0], 1u, memory_order_relaxed); if (hf) atomic_fetch_add_explicit(&o[1], 1u, memory_order_relaxed);\n"
    "  uint eb = max(p.x / 16u, 2u); if (g.x < eb || g.x + eb >= p.x) { atomic_fetch_add_explicit(&o[2], 1u, memory_order_relaxed); if (hf) atomic_fetch_add_explicit(&o[3], 1u, memory_order_relaxed); }\n"
    "  if (g.x == 1u) { float4 l = t.sample(s, float2(0.5f, y)), r = t.sample(s, float2(float(p.x) - 0.5f, y)); l.rgb *= l.a; r.rgb *= r.a; float4 e = abs(l - r);\n"
    "    atomic_fetch_add_explicit(&o[4], uint(max(max(e.r, e.g), max(e.b, e.a)) * 255.0f), memory_order_relaxed); atomic_fetch_add_explicit(&o[5], 1u, memory_order_relaxed); }\n"
    "}\n";
static nvn_hmap g_wd_flat = {.klen = 8};            // 贴图序号 → WD_FLAT_*（持 g_wd_flat_mu）
static nvn_hmap g_wd_flat_hash = {.klen = 8};       // 内容哈希 → WD_FLAT_DONE | 贴图标志（磁盘缓存的内存副本）
static pthread_mutex_t g_wd_flat_mu = PTHREAD_MUTEX_INITIALIZER;
typedef struct { uint64_t ser, hash; __unsafe_unretained id<MTLTexture> tex; } wd_flat_job;
static wd_flat_job g_wd_flat_q[16]; static int g_wd_flat_n;   // 本帧点名、待量（提交线程，持 g_wd_mu）
static uint64_t g_wd_flat_hits, g_wd_flat_runs, g_wd_flat_yes;
static const char *wd_flat_path(void) {
    static char p[1024]; if (p[0]) return p;
    const char *e = getenv("S2A_WIDEN_FLAT_CACHE"), *h = getenv("HOME");
    if (e && *e) snprintf(p, sizeof p, "%s", e); else snprintf(p, sizeof p, "%s/Library/Caches/s2a_widen_flat3.tsv", h ? h : ".");   // 3：值是贴图标志位（11-01 加边缘平滑 / 首尾无缝；11-06 加行内不变 ROW_CONST，旧文件没量这项、不沿用）
    return p;
}
static void wd_flat_load(void) {   // 持 g_wd_flat_mu；第一次用时读一次磁盘缓存
    static int done; if (done) return; done = 1;
    FILE *f = fopen(wd_flat_path(), "r"); if (!f) return;
    char ln[64]; int n = 0;
    while (fgets(ln, sizeof ln, f)) { unsigned long long h; int v; if (sscanf(ln, "%llx\t%d", &h, &v) == 2 && (v & S2A_WIDEN_TEX_FLAT_KNOWN) && !(v & ~0x3e)) { uint64_t k = h; nvn_hm_put(&g_wd_flat_hash, &k, (void *)(uintptr_t)(WD_FLAT_DONE | (unsigned)v)); n++; } }
    fclose(f); MLOG("宽屏·按内容判横向细节：磁盘缓存 %d 条（%s）", n, wd_flat_path());
}
static uint32_t wd_flat_flags(uint64_t ser) {   // 交给核心的贴图标志
    pthread_mutex_lock(&g_wd_flat_mu); uintptr_t v = (uintptr_t)nvn_hm_get(&g_wd_flat, &ser); pthread_mutex_unlock(&g_wd_flat_mu);
    return (v & WD_FLAT_DONE) ? (uint32_t)(v & 0x3e) : 0;
}
static int wd_rt_seen(uint64_t ser);   // 持 g_wd_mu：这张贴图当过渲染目标（宽屏登记表里有）
static void wd_flat_want(const tex_t *t) {   // 提交线程、持 g_wd_mu：核心点名这张
    uint64_t ser = t->serial;
    pthread_mutex_lock(&g_wd_flat_mu); wd_flat_load();
    if (nvn_hm_get(&g_wd_flat, &ser)) { pthread_mutex_unlock(&g_wd_flat_mu); return; }
    // 只量随包贴图（游戏内存里 CPU 给的静态内容，内容哈希才有意义）：渲染目标 / GPU 写过的贴图内容每帧在变，量那一刻可能是空的，
    //   量成「平滑」就会被推满拉宽（异度3 热缓存局：948×440 的场景合成目标量成平滑，标志层出重影），一律按有细节、不进磁盘缓存
    pthread_mutex_unlock(&g_wd_flat_mu);
    int pkg = [tex_get(t->serial) isKindOfClass:[NvPkg class]];
    pthread_mutex_lock(&g_wd_flat_mu);
    //   不随包、但不是渲染目标 / 不被着色器写的贴图（游戏运行时从缓冲区拷进去的静态图：马力欧惊奇标题主视觉与底纹，11-01）照样量，只是没有内容哈希、不进磁盘缓存；
    //   渲染目标 / 着色器写的由下面 ok 排除
    //   虚拟池（稀疏）贴图不算内容哈希：它只能按页表读（hle_nvn.c nvn_sparse_copy），池自己的地址段只有对齐主机页的映射才真挂上，直接读没挂的页 SIGBUS
    //   （11-05 旷野之息开局动画后闪退 3/3，地址落在虚拟池 0x126c00000+0x7300000 里；渲染器自己的整张哈希一向跳过 pk->sparse）。照常量，只是不进磁盘缓存
    int sparse = t->pool && nvn_sparse_pool(t->pool);
    uint64_t h = pkg && !sparse && t->mem && t->L.size && t->L.size <= (16u << 20) ? full_hash(t->mem, t->L.size) ^ ((uint64_t)t->d.width << 40 ^ (uint64_t)t->d.height << 20 ^ t->d.format) : 0;
    uintptr_t hv = h ? (uintptr_t)nvn_hm_get(&g_wd_flat_hash, &h) : 0;
    if (hv) { nvn_hm_put(&g_wd_flat, &ser, (void *)hv); g_wd_flat_hits++; pthread_mutex_unlock(&g_wd_flat_mu); return; }   // 磁盘缓存命中：下一笔起就是结论
    pthread_mutex_unlock(&g_wd_flat_mu);   // tex_mtl 自己要拿别的锁，不持量测表锁调
    id<MTLTexture> mt = g_wd_flat_n < 16 ? tex_mtl(t) : nil;
    // 排除画过的：真被绑成颜色 / 深度附件过的（宽屏登记表 g_wd_t 里有，wd_rt_seen）或游戏的着色器会写的。不按 MTLTextureUsageRenderTarget 判——
    //   本后端普通贴图建的时候也带这个用途，按它判就一张都量不了（11-01 马力欧惊奇标题页：底纹 / 主视觉全被记成有细节、一次没量）。
    //   着色器写也不看用途位：GPU 解 BC 的贴图（bc_gpu_dec）建时带写用途给解码内核一次性写；游戏声明的 NVN 图像标志只说「能当图像绑」，
    //   马力欧惊奇 640x640 底纹（随包、用途 0x3）两样都不是真被写。真被着色器按可写图像绑过的，绑定那一刻 wd_flat_written 记成有细节，
    //   这里只排除没有图像标志、也不是 BC 解码却带写用途的（img_wr_note 绑定时升级过 = 真被写过）
    int gw = mt && (mt.usage & MTLTextureUsageShaderWrite) && !bc_gpu_dec(t) && !(t->d.flags & NVN_TEXTURE_FLAGS_IMAGE);
    int ok = mt && mt.textureType == MTLTextureType2D && mt.sampleCount <= 1 && !gw && !wd_rt_seen(t->serial);
    pthread_mutex_lock(&g_wd_flat_mu); nvn_hm_put(&g_wd_flat, &ser, (void *)(uintptr_t)(ok ? WD_FLAT_PEND : WD_FLAT_NO)); pthread_mutex_unlock(&g_wd_flat_mu);
    if (!ok) { static int n; if (n++ < 16) MLOG("宽屏·按内容判横向细节：贴图 ser=%llu %ux%u 不量、记有细节（%s；用途 %#lx、类型 %lu、采样数 %lu、当过渲染目标 %d、随包 %d）", (unsigned long long)ser, t->d.width, t->d.height,
        !mt ? "取不到贴图" : g_wd_flat_n >= 16 ? "本帧待量满 16" : gw ? "游戏着色器会写" : wd_rt_seen(ser) ? "当过渲染目标" : "非 2D / 多重采样", mt ? (unsigned long)mt.usage : 0ul, mt ? (unsigned long)mt.textureType : 0ul, mt ? (unsigned long)mt.sampleCount : 0ul, wd_rt_seen(ser), pkg); return; }
    g_wd_flat_q[g_wd_flat_n++] = (wd_flat_job){ser, h, (__bridge id<MTLTexture>)CFBridgingRetain(mt)};
}
// nvn_mtl.m 着色器按可写图像绑定一张贴图时调：它的内容会被 GPU 改写，量过的结论作废，记成有细节（不进磁盘缓存：按内容哈希的那条仍是原内容的结论）
static void wd_flat_written(uint64_t ser) {
    static _Thread_local uint64_t last; if (ser == last) return; last = ser;   // 同一张连续绑定（每笔都绑）只记一次
    pthread_mutex_lock(&g_wd_flat_mu); nvn_hm_put(&g_wd_flat, &ser, (void *)(uintptr_t)WD_FLAT_NO); pthread_mutex_unlock(&g_wd_flat_mu);
}
static id<MTLComputePipelineState> wd_flat_pso(void) {
    static id<MTLComputePipelineState> ps; static int failed;
    if (!ps && !failed) { NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_wd_flat_msl) options:nil error:&e]; id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"wd_flat"] : nil;
        ps = fn ? [g_dev newComputePipelineStateWithFunction:fn error:&e] : nil;
        if (!ps) { failed = 1; MLOG("【红】 宽屏·按内容判横向细节：计算管线建不出（%s），照尺寸规则", e.localizedDescription.UTF8String); } }
    return ps;
}
static void wd_flat_flush(void) {   // 上屏（持 g_wd_mu）：本帧点名的贴图一起量
    int n = g_wd_flat_n; if (!n) return; g_wd_flat_n = 0;
    id<MTLComputePipelineState> ps = wd_flat_pso();
    id<MTLCommandBuffer> cb = ps ? (g_m3 ? [g_q3 commandBuffer] : [g_q commandBuffer]) : nil;
    id<MTLBuffer> ob = cb ? [g_dev newBufferWithLength:(NSUInteger)n * 28 options:MTLResourceStorageModeShared] : nil;   // 每张 7 个计数：总点 / 高频 / 边缘带点 / 边缘带高频 / 首末列差和 / 行数 / 与行中点差大的点
    wd_flat_job *jobs = malloc(sizeof(wd_flat_job) * (size_t)n); if (jobs) memcpy(jobs, g_wd_flat_q, sizeof(wd_flat_job) * (size_t)n);
    if (!cb || !ob || !jobs) { pthread_mutex_lock(&g_wd_flat_mu); for (int i = 0; i < n; i++) { nvn_hm_put(&g_wd_flat, &g_wd_flat_q[i].ser, (void *)(uintptr_t)WD_FLAT_NO); CFBridgingRelease((__bridge CFTypeRef)g_wd_flat_q[i].tex); } pthread_mutex_unlock(&g_wd_flat_mu); free(jobs); return; }
    memset(ob.contents, 0, (size_t)n * 28);
    if (!g_m3 && g_ev && g_fence) [cb encodeWaitForEvent:g_ev value:g_fence];   // 本帧画 / 传这些贴图的提交做完（旧队列与 g_q4 不保序）
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder]; [e setComputePipelineState:ps];
    for (int i = 0; i < n; i++) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)(__bridge void *)jobs[i].tex; uint32_t p[4] = {(uint32_t)t.width, (uint32_t)t.height, 32, 0};
        [e setTexture:t atIndex:0]; [e setBuffer:ob offset:(NSUInteger)i * 28 atIndex:0]; [e setBytes:p length:sizeof p atIndex:1];
        [e dispatchThreads:MTLSizeMake(t.width, 32, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        uint32_t p1[4] = {(uint32_t)t.width, (uint32_t)t.height, 0, 1}; [e setBytes:p1 length:sizeof p1 atIndex:1];   // 第二遍：全部行的行内变化
        [e dispatchThreads:MTLSizeMake(t.width, t.height, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    }
    [e endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        const uint32_t *r = ob.contents; FILE *f = NULL;
        pthread_mutex_lock(&g_wd_flat_mu);
        for (int i = 0; i < n; i++) {
            const uint32_t *ri = r + 7 * i;
            int flat = !c.error && ri[0] && (double)ri[1] / ri[0] <= WD_FLAT_RATIO, edge = !c.error && ri[2] && (double)ri[3] / ri[2] <= WD_FLAT_RATIO,
                seam = !c.error && ri[5] && ri[4] / ri[5] <= WD_FLAT_SEAM, rowc = !c.error && ri[0] && ri[6] == 0;   // 全部行里一个行内变化点都没有
            unsigned fl = S2A_WIDEN_TEX_FLAT_KNOWN | (flat ? S2A_WIDEN_TEX_FLAT_CONTENT : 0) | (edge ? S2A_WIDEN_TEX_EDGE_SMOOTH : 0) | (seam ? S2A_WIDEN_TEX_SEAMLESS_U : 0) | (rowc ? S2A_WIDEN_TEX_ROW_CONST : 0);
            nvn_hm_put(&g_wd_flat, &jobs[i].ser, (void *)(uintptr_t)(WD_FLAT_DONE | fl)); g_wd_flat_runs++; g_wd_flat_yes += flat;
            if (jobs[i].hash && !c.error) { nvn_hm_put(&g_wd_flat_hash, &jobs[i].hash, (void *)(uintptr_t)(WD_FLAT_DONE | fl));
                if (!f) f = fopen(wd_flat_path(), "a"); if (f) fprintf(f, "%016llx\t%u\n", (unsigned long long)jobs[i].hash, fl); }
            if (g_wd_flat_runs <= 64) MLOG("宽屏·按内容判横向细节：贴图 ser=%llu %lux%lu 横向高频点 %u / %u、行内变化点 %u、边缘带 %u / %u、首末列平均差 %u → %s%s%s%s", (unsigned long long)jobs[i].ser,
                (unsigned long)((__bridge id<MTLTexture>)(__bridge void *)jobs[i].tex).width, (unsigned long)((__bridge id<MTLTexture>)(__bridge void *)jobs[i].tex).height, ri[1], ri[0], ri[6], ri[3], ri[2], ri[5] ? ri[4] / ri[5] : 0,
                flat ? "平滑（铺满画布的界面层可推满）" : "有细节", !flat && edge ? "、边缘带平滑（半透明叠加可外扩、钳边）" : "", seam ? "、首尾无缝" : "", rowc ? "、行内不变（原尺寸居中层可收缩）" : "");
            CFBridgingRelease((__bridge CFTypeRef)jobs[i].tex);
        }
        pthread_mutex_unlock(&g_wd_flat_mu);
        if (f) fclose(f); free(jobs);
    }];
    [cb commit];
}
// ---------- 原比例回退的两侧覆盖采样（11-01，根因族 1「放宽后一侧游戏没画到」）：机制在 widen_fallback.inc（NVN / GL 直连共用），这里给 NVN 的后端钩子与旧名包装 ----------
static int wd_on(void);
#define WD_P2_LOG MLOG
#define WD_P2_DEV g_dev
static int wd_p2_widen_on(void) { return wd_on() > 0; }
static id<MTLCommandBuffer> wd_p2_cmdbuf(void) {   // 旧队列上先等本帧提交事件（Metal 4 队列按提交顺序执行）
    id<MTLCommandBuffer> cb = g_m3 ? [g_q3 commandBuffer] : [g_q commandBuffer];
    if (cb && !g_m3 && g_ev && g_fence) [cb encodeWaitForEvent:g_ev value:g_fence];
    return cb;
}
#include "widen_fallback.inc"
// nvn_mtl.m 颜色清屏（整幅、load-action）记下清屏色之后调：这张是纯 2D 世界目标就把 alpha 挪成哨兵
static void wd_p2_clear(const tex_t *t, MTLClearColor *cc) {
    if (!wd_p2_on() || !t || !wd_p2_is_world(t->serial) || wd_on() <= 0) return;
    wd_fb_arm_full(t->serial, tex_mtl(t), t->d.width, cc);
}
// nvn_mtl.m 带剪裁的颜色清屏（画成三角形）调（见 wd_fb_arm_rect）
static void wd_p2_clear_tri(const tex_t *t, float *rgba, int mask, MTLScissorRect sc, long gw, long cw) {
    if (!wd_p2_on() || !t || !wd_p2_is_world(t->serial) || wd_on() <= 0) return;
    wd_fb_arm_rect(t->serial, tex_mtl(t), t->d.width, rgba, mask, sc, gw, cw);
}
// 游戏这帧不清世界目标：nvn_mtl.m 每笔画前调（见 wd_fb_want_self），返回 1 时调用方在这笔之前把两侧带写成哨兵
static int wd_p2_want_self(const tex_t *c0, uint32_t r5[5]) {
    if (!c0 || !wd_p2_on() || wd_on() <= 0 || !wd_p2_is_world(c0->serial) || (g_p2_armed && g_p2_armed_ser == c0->serial)) return 0;
    int si = wd_p2_slot(c0->serial); if (si < 0 || g_p2_srect[si][4] < 4) return 0;
    return wd_fb_want_self(c0->serial, tex_mtl(c0), r5);
}
static void wd_trace(const char *why, const s2a_widen_draw_in *in, int ntx, const s2a_widen_tex *tx) {   // 持 g_wd_mu 调
    if (!wd_tr_on()) return;
    const tex_t *c0 = R.has_rt && R.rt.n > 0 ? R.rt.color[0] : NULL;
    char t[512] = ""; int o = 0;
    for (int i = 0; i < ntx && i < 8 && o < 440; i++) o += snprintf(t + o, sizeof t - (size_t)o, " %u:%dx%d", tx[i].id, tx[i].w, tx[i].h);
    float x = in->vp_x, w = in->vp_w; if (g_wd_mode != S2A_WIDEN_KEEP) s2a_widen_map_viewport(g_wd_mode, &x, &w);
    MLOG("S2Arm widen trace: frame %llu target c%llu %ux%u d%llu viewport %.1f,%.1f %.1fx%.1f -> %s mode %d -> x %.1f w %.1f%s sides %d [%d,%d)[%d,%d) samples%s fs %.16s",
         (unsigned long long)g_wd_frame, (unsigned long long)g_wd_c0, c0 ? (unsigned)c0->d.width : 0, c0 ? (unsigned)c0->d.height : 0, (unsigned long long)g_wd_d0,
         in->vp_x, in->vp_y, in->vp_w, in->vp_h, why, g_wd_mode, x, w, R.has_sc ? "" : " (no scissor)", g_wd_side_on, g_wd_sides[0], g_wd_sides[1], g_wd_sides[2], g_wd_sides[3], ntx ? t : " none", g_wd_fskey);
}
// 一个着色器在宽屏核心里的句柄：直连库带读法（json cbuf_use，同通用模式离线表）的按自己的读法登记一次（核心据此只认这个着色器真读的常量 vec4，
// 判「读了被改写的矩阵」不再按整个绑定区间算）；没读法的（旧库）用共用句柄。绘制线程调
static int32_t wd_sh(int st, NvShader *sh) {
    uint32_t fl = st == 0 && sh->push ? S2A_WIDEN_SH_PUSH : 0;
    if (sh->cbu && !sh->wsh) { int32_t h = s2a_widen_shader(st, sh->cbu.UTF8String, fl); sh->wsh = h > 0 ? h : -1; }
    return sh->wsh > 0 ? sh->wsh : fl ? g_wd_sh_push : g_wd_sh;
}
// 片元采样一张贴图的标志：合并句柄（贴图号 | 采样器号 << 20）的采样器横向重复寻址（NVN 1 重复 / 6 镜像重复）= 平铺采样（同通用模式 TILE_U：
// 核心不拿平铺贴图当 16:9 页面源，地面 / 水面纹理恰好 16:9 也不会把整笔判成页面）。持 g_rmu 调
static uint32_t wd_tex_flags(uint64_t h) {
    int sid = (int)(h >> 20 & 0xfffff);
    return sid > 0 && sid < g_nsreg && g_sreg_ok[sid] && (g_sreg[sid].ws == 1 || g_sreg[sid].ws == 6) ? S2A_WIDEN_TEX_TILE_U : 0;
}
static int wd_on(void) {
    if (__builtin_expect(g_wd >= 0, 1)) return g_wd;
    // 缺省开（10-26 维护者：「满屏是目标，不是可选项」，放宽存储 tex_widen 同支合入）；S2A_WIDEN_DIRECT=0 关（对照 / 排查用）。关时第二层（游戏自己出宽图）照旧
    // 宽屏关着、自动玩家开着（测试局）：起只观察会话（S2A_WIDEN_OBSERVE）——不放宽、不改写，只从常量里认镜头位姿给自动玩家 s2a_ap_cam
    //   （10-25 维护者：马车8 直连判不到 MARK，直连没有镜头位姿；通用模式由包装层 CameraTrack 给）。玩家局（没有自动玩家）照旧一次判断就返回
    uint32_t obs = 0;
    { const char *e = getenv("S2A_WIDEN_DIRECT"); if (e && !strcmp(e, "0")) {
        if (!(s2a_autoplay_on && s2a_autoplay_on())) { MLOG("S2Arm widen core off in direct mode (S2A_WIDEN_DIRECT=0)"); return g_wd = 0; }
        obs = S2A_WIDEN_OBSERVE; } }
    uint32_t fl = obs ? obs : (s2a_widen_game() ? S2A_WIDEN_GAME : 0) | (s2a_widen_layout() ? S2A_WIDEN_LAYOUT : 0) | (s2a_widen_full() ? S2A_WIDEN_FULL : 0);
    int m = s2a_widen_init(s2a_screen_w(), s2a_screen_h(), fl);
    if (m != S2A_WIDEN_OFF) { g_wd_sh = s2a_widen_shader(0, NULL, 0); g_wd_sh_push = s2a_widen_shader(0, NULL, S2A_WIDEN_SH_PUSH); s2a_widen_set_geom_cb(wd_geom_cb); }   // 几何判据回调（nvn_mtl.m wd_geom_cb，11-06）
    g_wd = m == S2A_WIDEN_OFF ? 0 : m;
    MLOG("S2Arm widen core: screen width %d, flags %#x, mode %d (0 off / 1 ui / 2 all / 3 pillar), k %.4f", s2a_screen_w(), fl, m, s2a_widen_k());
    return g_wd;
}
static unsigned wd_slot(uint64_t ser) { return (unsigned)((ser * 0x9E3779B97F4A7C15ull) >> 51) & (WD_T - 1); }
static int wd_rt_seen(uint64_t ser) {   // 持 g_wd_mu
    if (!ser) return 0; unsigned k = wd_slot(ser);
    for (int i = 0; i < WD_T; i++, k = (k + 1) & (WD_T - 1)) { if (g_wd_t[k].ser == ser) return 1; if (!g_wd_t[k].ser) return 0; }
    return 0;
}
static int wd_pr_has(uint64_t ser) { for (int i = 0; i < g_wd_npr; i++) if (g_wd_pr[i] == ser) return 1; return 0; }   // 持 g_wd_mu 调；只在新登记时查
// 当渲染目标用的贴图：登记给核心，核心据宽高判原生宽 / 16:9 一族；返回核心给的宽（没登记上 = 原宽）。
//   vpr / vpb = 这笔视口右边 / 下边（游戏坐标；0 = 开遍时还不知道）。存储放不宽的（tex_widen_why）等第一笔绘制再登记：放宽 / 加高后画的这块（vpr × k、vpb × ky）都装得进存储才带 USE_RT
//   （马车8 交换链 1920 宽、游戏只画 1280，放宽 1564 装得下），装不下的不带（核心约定游戏内存的存储不放宽，按原宽画、当图片认）。
//   10-26 巫师3 直连标志视频：1280 宽缓冲存储的 Y / U / V 平面按放宽登记，核心把它们起成右移 142 的原比例页，存储装不下，清掉的左条带合成后左侧 11.1% 品红
// 诊断 S2A_WIDEN_DENY=<宽>x<高>[,<宽>x<高>…]：这些游戏尺寸的渲染目标不登记放宽（存储保持游戏宽，按原样画）。真机二分「某一族中间层放宽后出错」用
//   （11-02 派对：泛光链 576x324 第 1 级放宽条带只在真机算出彩块，Mac 回放同笔正常）
static int wd_denied(const tex_t *t) {
    static int n = -1; static uint32_t dw[8], dh[8];
    if (n < 0) { n = 0; const char *e = getenv("S2A_WIDEN_DENY");
        for (const char *q = e; q && *q && n < 8; q = strchr(q, ',') ? strchr(q, ',') + 1 : q + strlen(q)) { unsigned w, h; if (sscanf(q, "%ux%u", &w, &h) == 2) { dw[n] = w; dh[n] = h; n++; } }
        if (n) MLOG("S2Arm widen: S2A_WIDEN_DENY 生效，%d 种尺寸的渲染目标不放宽（诊断）", n); }
    for (int i = 0; i < n; i++) if (t->d.width == dw[i] && t->d.height == dh[i]) return 1;
    return 0;
}
static void wd_pr_apply(int n);
static uint32_t wd_tex(const tex_t *t, float vpr, float vpb) {
    if (!t || !t->serial) return t ? t->d.width : 0;
    int dead = 0;
    if (wd_denied(t)) return t->d.width;
    unsigned k = wd_slot(t->serial);
    for (int i = 0; i < WD_T; i++, k = (k + 1) & (WD_T - 1)) {
        if (g_wd_t[k].ser == t->serial) { if (g_wd_t[k].w == t->d.width && g_wd_t[k].h == t->d.height) return g_wd_t[k].r; break; }
        // 新登记前核这张贴图还活着（10-25 荒野之息直连局：登记 4008 时活着的贴图只有 854，登记只涨不跌、6144 时表满）：绘制是录进命令缓冲、之后在回放线程上回放的，
        //   游戏提交完常当场 Finalize 临时渲染目标——释放（游戏线程 wd_release）先于回放里的登记，表里那时还没有、删不掉，回放再登记进来就永远没人删。
        //   已释放的贴图（释放先删存活表再取本表锁删登记，登记在本表锁里查存活：两边谁先都不漏）照登记、同时排进待生效释放，下一次提交做完就删，表照样不涨。
        //   原先直接不登记：11-05 旷野之息 Duo 局内，游戏 Finalize 了场景目标对象（1280×720，存储已加高到 900）、录好的命令每帧照样往里画，这些笔不进核心、
        //   按游戏尺寸画在 900 行存储的顶部 720 行，底部 180 行黑（没进核心按目标汇总：「未登记、对象已释放」× 每 300 次提交 3600 笔）
        //   排着待生效释放的照登记（录在 Finalize 之前的绘制还要按放宽画），释放生效时一并删
        if (!g_wd_t[k].ser && !nvn_be_tex_is_live(t->serial) && !wd_pr_has(t->serial)) dead = 1;
        if (!g_wd_t[k].ser) { if (g_wd_nt >= WD_T * 3 / 4) { static int once; if (!once++) MLOG("【红】 S2Arm widen: render target table full (%d registered, %u texture objects live)", g_wd_nt, nvn_be_tex_live_n()); return t->d.width; } g_wd_nt++; break; }
    }
    uint32_t use = S2A_WIDEN_USE_RT;
    if (tex_widen_why(t)) {
        if (vpr <= 0) { if (!g_wd_t[k].ser) g_wd_nt--; return t->d.width; }   // 开遍时：等第一笔绘制
        if ((NSUInteger)ceilf(vpr * s2a_widen_k() - 0.01f) > rs_cw(tex_mtl(t))) use = 0;   // canvas (such storages are never scaled either: same value)
        // 高同理（窄屏加高）：11-05 旷野之息 Duo（k 1、ky 1.25）只核宽，720 高的放不宽存储照登成可加高，核心按 900 行画、底部 180 行黑
        if ((NSUInteger)ceilf(vpb * s2a_widen_ky() - 0.01f) > rs_ch(tex_mtl(t))) use = 0;
    }
    int r = s2a_widen_texture((uint32_t)t->serial, (int)t->d.width, (int)t->d.height, 1.0f, use), rh = s2a_widen_tex_h((uint32_t)t->serial, (int)t->d.height);
    g_wd_t[k].ser = t->serial; g_wd_t[k].w = t->d.width; g_wd_t[k].h = t->d.height; g_wd_t[k].r = r > (int)t->d.width ? (uint32_t)r : t->d.width;
    g_wd_t[k].rh = rh > (int)t->d.height ? (uint32_t)rh : t->d.height;   // narrower screen: the core's height (s2a_widen_tex_h)
    if (dead) { if (g_wd_npr == WD_PR) wd_pr_apply(WD_PR / 2); g_wd_pr[g_wd_npr++] = t->serial; }   // 已释放的：排进待生效释放（见上）
    return g_wd_t[k].r;
}
// The core's width for a texture wd_tex registered (otherwise its own width). Holding g_wd_mu
static uint32_t wd_tex_r(const tex_t *t) {
    if (!t || !t->serial) return t ? t->d.width : 0;
    unsigned k = wd_slot(t->serial);
    for (int i = 0; i < WD_T && g_wd_t[k].ser; i++, k = (k + 1) & (WD_T - 1)) if (g_wd_t[k].ser == t->serial) return g_wd_t[k].r ? g_wd_t[k].r : t->d.width;
    return t->d.width;
}
// The core's height for a texture wd_tex registered (narrower screen; otherwise its own height). Holding g_wd_mu
static uint32_t wd_tex_h(const tex_t *t) {
    if (!t || !t->serial) return t ? t->d.height : 0;
    unsigned k = wd_slot(t->serial);
    for (int i = 0; i < WD_T && g_wd_t[k].ser; i++, k = (k + 1) & (WD_T - 1)) if (g_wd_t[k].ser == t->serial) return g_wd_t[k].rh ? g_wd_t[k].rh : t->d.height;
    return t->d.height;
}
// 开渲染遍、解析附件之前（nvn_mtl.m rp_begin_ex_，此时没有开着的遍，放宽存储的拷贝可以排）：本遍颜色 / 深度目标登记给核心，核心给的宽比存储宽就换成放宽的存储（tex_widen）。
//   原先只在画第一笔时登记、存储一直是游戏的宽：核心按放宽给视口，全屏处理每一遍把画面横向拉 k 倍、右边被裁（10-26 马车8 直连宽屏标题视频右移）。只出界面层的 UI 模式核心不放宽，一次判断就返回
// 运行中换屏（10-27 Duo 合上切外屏 1.455、展开回内屏 1.422；维护者：宽屏坚持原生满屏，换了屏按新比例出图、不留边不裁边）：原生层屏幕宽 / 高变了（s2a_screen_gen）
//   就在这里（开渲染遍前、没有开着的遍）换核心比例——核心换一份帧状态（贴图登记全清、K / Ky 重定），这里清掉登记表与出数 / 绑定缓存；之后每个渲染目标用到时按新尺寸
//   重新登记，把新请求交给 tex_widen；现有存储只增容量，不随较小请求缩容（尺寸契约分别保留请求和实际容量）。
//   新比例不用放宽时（换到 16:9 屏）仍交原游戏尺寸请求（g_wd_restore），不改变只增容量策略。S2A_REASPECT_AT=<上屏帧>:<宽>x<高>[,…]：Mac 上到这一帧模拟换屏（测试用）
static unsigned g_wd_gen; static int g_wd_restore; static uint64_t g_wd_reaspects;
int s2a_nvn_reaspect_ok(void) { return g_wd >= 0; }   // graphics/nvn/host_adapt.m：NVN 直连的宽屏核心已起会话（Vulkan / GL 直连从不走这里，换屏时它们不改比例）
static void wd_reaspect_sim(void) {
    static int n = -1; static struct { uint64_t f; int w, h; } at[8];
    if (n < 0) { n = 0; const char *e = getenv("S2A_REASPECT_AT");
        while (e && *e && n < 8) { unsigned long long f; int w, h, k = 0; if (sscanf(e, "%llu:%dx%d%n", &f, &w, &h, &k) != 3) break; at[n].f = f; at[n].w = w; at[n].h = h; n++; e += k; if (*e == ',') e++; } }
    for (int i = 0; i < n; i++) if (at[i].f && g_wd_frame >= at[i].f) { s2a_screen_switch(at[i].w, at[i].h); at[i].f = 0; }
}
static void wd_reaspect(void) {
    wd_reaspect_sim();
    unsigned gen = s2a_screen_gen(); if (gen == g_wd_gen || g_wd < 0) return;
    pthread_mutex_lock(&g_wd_mu);
    int was = g_wd, m = s2a_widen_reaspect(s2a_screen_w(), s2a_screen_h());
    memset(g_wd_t, 0, sizeof g_wd_t); g_wd_nt = 0;
    memset(g_wd_last, 0, sizeof g_wd_last); memset(g_wd_b, 0, sizeof g_wd_b); memset(g_wd_bound, 0, sizeof g_wd_bound); memset(g_wd_had, 1, sizeof g_wd_had);
    g_wd_c0 = 0; g_wd_d0 = ~0ull;
    if (m != S2A_WIDEN_OFF && !g_wd_sh) { g_wd_sh = s2a_widen_shader(0, NULL, 0); g_wd_sh_push = s2a_widen_shader(0, NULL, S2A_WIDEN_SH_PUSH); }
    g_wd = m == S2A_WIDEN_OFF ? 0 : m; g_wd_restore = was > 0 && g_wd == 0;
    pthread_mutex_unlock(&g_wd_mu);
    g_wd_gen = gen; g_wd_reaspects++; g_args_dirty[0] = g_args_dirty[1] = 1;
    MLOG("S2Arm widen: screen changed to %dx%d at present %llu: core mode %d → %d, k %.4f ky %.4f; widened render targets are rebuilt at the new size as they are next used",
         s2a_screen_w(), s2a_screen_h(), (unsigned long long)g_wd_frame, was, m, s2a_widen_k(), s2a_widen_ky());
}
static void wd_widen_rts(void) {
    wd_reaspect();
    if (g_wd <= 0) {
        if (g_wd_restore) for (int i = -1; i < R.rt.n && i < 8; i++) { const tex_t *t = i < 0 ? R.rt.depth : R.rt.color[i]; if (t) tex_widen(t, t->d.width, t->d.height); }   // 换到 16:9 屏：交原尺寸请求，保留容量
        return;
    }
    for (int i = -1; i < R.rt.n && i < 8; i++) {
        const tex_t *t = i < 0 ? R.rt.depth : R.rt.color[i]; if (!t) continue;
        pthread_mutex_lock(&g_wd_mu); uint32_t r = wd_tex(t, 0, 0), rh = wd_tex_h(t); pthread_mutex_unlock(&g_wd_mu);
        id<MTLTexture> mt = g_wd_reaspects ? tex_mtl(t) : nil;   // 换过屏才查：把当前请求交给既有只增容量策略
        if (r > t->d.width || rh > t->d.height || (mt && (rs_cw(mt) != t->d.width || rs_ch(mt) != t->d.height))) {
            id<MTLTexture> was = tex_mtl(t);
            if (tex_widen(t, r, rh) && tex_mtl(t) != was) wd_pclr_apply(t);   // 这次刚换成放宽存储：本帧放宽前那次整张清除在新存储上再清一遍（右侧放宽条带也是清除值，见 nvn_mtl.m wd_pclr_note）
        }
    }
}
// Downsample（多重采样解析）的目标（10-30 直连缺陷表 Fit Boxing / 哆啦A梦牧场物语 / 植物大战僵尸：「Downsample case not implemented: 1564x720 2 samples → 1280x720 1 sample」）：
//   源是放宽过的多重采样渲染目标，目标是游戏同尺寸的单样本贴图，建时不当渲染目标、核心没登记，存储仍是游戏宽 → 两边不同宽，解析整笔跳过，那一遍的画面没了（同几款满屏判据
//   「某列起明显变暗、某一遍没铺满放宽宽度」）。目标装的是源的画面，与源同族：游戏尺寸相同时按渲染目标登记给核心（wd_tex，存储放不宽的照旧不带 USE_RT），核心给的宽高比存储大就换成
//   放宽的存储（tex_widen，同 wd_widen_rts），之后照常整张解析。游戏尺寸不同但宽高比相同（缩放解析，11-02 数码宝贝物语 时空异客 1920x1080 4 样本 → 1280x720）同理：
//   整张源铺到整张目标，目标不随源放宽就把放宽的画面横向压进游戏宽。宽高比不同的不管。
//   同一游戏尺寸、源矩形与目标矩形相同的普通贴图拷贝也走这里（11-02 马里奥和索尼克东京2020：每帧把放宽的 1920x1080 画布拷进没放宽的交换链，两边按各自存储换算成了压缩拷贝、上屏 16:9）
static void wd_widen_resolve_dst(const tex_t *src, const tex_t *dst) {
    if (g_wd <= 0 || (uint64_t)src->d.width * dst->d.height != (uint64_t)dst->d.width * src->d.height || src->d.depth > 1 || dst->d.depth > 1) return;
    // 源没放宽也没加高才不管：原先只看宽，窄屏加高（k 1）下源从不变宽，加高的多重采样目标解析进的单样本贴图不登记、不加高——11-05 哆啦A梦牧场 Duo 标题：
    //   54（1280×720 两样本，加高到 900）解析进 55（1280×720），55 没登记，上屏那笔把它当 16:9 图片居中原尺寸盖在中间（CenterNative），
    //   上下条带露出底下拉满的场景，第 90 / 810 行两条接缝。加高与放宽同一口径（同 ⑪ 同尺寸拷贝目的随源放宽）
    id<MTLTexture> s = tex_mtl(src); if (!s || (rs_cw(s) <= src->d.width && rs_ch(s) <= src->d.height)) return;   // the source is neither widened nor made taller
    pthread_mutex_lock(&g_wd_mu); uint32_t r = wd_tex(dst, 0, 0), rh = wd_tex_h(dst); pthread_mutex_unlock(&g_wd_mu);
    if (r <= dst->d.width && rh <= dst->d.height) return;
    id<MTLTexture> d = tex_mtl(dst); if (d && rs_cw(d) >= r && rs_ch(d) >= rh) return;
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }   // tex_widen swaps the storage: no pass or blit may still hold the old one
    static uint64_t n; int ok = tex_widen(dst, r, rh);
    if (n++ < 4) MLOG("S2Arm widen: copy / Downsample destination ser=%llu %ux%u %s %ux%u (its source ser=%llu is widened)", (unsigned long long)dst->serial, dst->d.width, dst->d.height,
                      ok ? "widened to" : "could not be widened to", r, rh, (unsigned long long)src->serial);
}
static void wd_release_now(uint64_t ser) {   // 持 g_wd_mu 调。开放寻址删除：后面同簇的项往回挪
    wd_s3d_set(ser, 0);
    unsigned k = wd_slot(ser);
    for (int i = 0; i < WD_T && g_wd_t[k].ser; i++, k = (k + 1) & (WD_T - 1)) if (g_wd_t[k].ser == ser) {
        s2a_widen_release((uint32_t)ser); g_wd_t[k].ser = 0; g_wd_nt--;
        for (unsigned j = (k + 1) & (WD_T - 1); g_wd_t[j].ser; j = (j + 1) & (WD_T - 1)) {
            unsigned h = wd_slot(g_wd_t[j].ser);
            if ((j > k && (h <= k || h > j)) || (j < k && h <= k && h > j)) { g_wd_t[k] = g_wd_t[j]; g_wd_t[j].ser = 0; k = j; }
        }
        break;
    }
}
static void wd_pr_apply(int n) {   // 持 g_wd_mu 调：前 n 条排着的释放生效
    for (int i = 0; i < n; i++) wd_release_now(g_wd_pr[i]);
    memmove(g_wd_pr, g_wd_pr + n, (size_t)(g_wd_npr - n) * sizeof g_wd_pr[0]); g_wd_npr -= n; g_wd_npr_arm = g_wd_npr_arm > n ? g_wd_npr_arm - n : 0;
}
static void wd_release(uint64_t ser) {
    if (g_wd <= 0 || !ser) return;
    pthread_mutex_lock(&g_wd_mu);
    if (wd_tr_on()) MLOG("S2Arm widen trace: frame %llu release tex %llu (applied after the next submission replays)", (unsigned long long)g_wd_frame, (unsigned long long)ser);
    if (g_wd_npr == WD_PR) { static int once; if (!once++) MLOG("【红】 S2Arm widen: pending texture release queue full (%d): oldest released now", WD_PR); wd_pr_apply(WD_PR / 2); }
    g_wd_pr[g_wd_npr++] = ser;
    pthread_mutex_unlock(&g_wd_mu);
}
// 不经 wd_draw 的编码：光栅化丢弃下为写入而跑的顶点着色器（nvn_geometry.inc sx_draw）、变换反馈捕获（nvn_mtl.m tf_draw）。这两类绘制只产出数据给后面的绘制读、
//   不上屏，宽屏不改写它们；丢掉上一笔常规绘制留下的改写副本，encode_args 照原样零拷贝绑游戏内存。11-01 异度3：骨骼矩阵着色器 cf66cef403c57845 把上一笔绘制的
//   改写副本当成自己的 c3（两次调用绑到同一份副本），写出的 664 个矩阵全错，场景物件被拉成巨型三角形；丢掉后 664 个与按原样输入在 GPU 上算的结果全符
static void wd_drop(void) { for (int st = 0; st < 5; st++) if (g_wd_had[st]) { for (int r = 0; r < 16; r++) g_wd_gpu[st][r] = 0; g_wd_had[st] = 0; g_args_dirty[st] = 1; } }
// 没进核心的笔（s2a_widen_viewport 返回 0、整笔原样画）按目标汇总，常驻：每 300 次提交一行，列这一段里笔数最多的 8 个目标——
//   序号、游戏尺寸、颜色 / 深度、格式、NVN 标志、登记表里核心给的宽高（没登记 = 游戏尺寸）、第一笔视口、笔数；印完清零，下一段重新数（标题 / 加载 / 局内各段分开看）。
//   11-05 旷野之息 Duo（k 1、ky 1.25）：总账 31% 的笔没进核心、游戏内画面只占 900 行目标的顶部 720 行，旧日志只有总数、点不出是哪张目标。持 g_wd_mu 调
#define WD_SK 32
static struct { uint64_t ser, n; uint32_t w, h, fmt, fl, rw, rh; float vx, vy, vw, vh; int depth, reg, live; const char *why; } g_wd_sk[WD_SK];
static uint64_t g_wd_sk_n, g_wd_sk_other;
static void wd_skip_note(const tex_t *c0, const tex_t *d0, const s2a_widen_draw_in *in) {
    const tex_t *t = c0 ? c0 : d0; uint64_t s = t ? t->serial : 0; int i = 0;
    g_wd_sk_n++;
    while (i < WD_SK && g_wd_sk[i].n && g_wd_sk[i].ser != s) i++;
    if (i == WD_SK) { g_wd_sk_other++; return; }
    if (!g_wd_sk[i].n) {
        g_wd_sk[i].ser = s; g_wd_sk[i].depth = !c0 && d0;
        g_wd_sk[i].w = t ? t->d.width : 0; g_wd_sk[i].h = t ? t->d.height : 0; g_wd_sk[i].fmt = t ? (uint32_t)t->d.format : 0; g_wd_sk[i].fl = t ? (uint32_t)t->d.flags : 0;
        g_wd_sk[i].rw = t ? wd_tex_r(t) : 0; g_wd_sk[i].rh = t ? wd_tex_h(t) : 0;
        { unsigned k = wd_slot(s); g_wd_sk[i].reg = 0; for (int j = 0; t && j < WD_T && g_wd_t[k].ser; j++, k = (k + 1) & (WD_T - 1)) if (g_wd_t[k].ser == s) { g_wd_sk[i].reg = 1; break; } }
        g_wd_sk[i].live = t ? nvn_be_tex_is_live(s) : 0; g_wd_sk[i].why = t ? tex_widen_why(t) : NULL;
        g_wd_sk[i].vx = in->vp_x; g_wd_sk[i].vy = in->vp_y; g_wd_sk[i].vw = in->vp_w; g_wd_sk[i].vh = in->vp_h;
    }
    g_wd_sk[i].n++;
}
static void wd_skip_flush(void) {
    if (!g_wd_sk_n) return;
    char b[1600]; int o = 0, used[WD_SK] = {0};
    for (int k = 0; k < 8 && o < (int)sizeof b - 200; k++) {
        int best = -1; for (int i = 0; i < WD_SK && g_wd_sk[i].n; i++) if (!used[i] && (best < 0 || g_wd_sk[i].n > g_wd_sk[best].n)) best = i;
        if (best < 0) break; used[best] = 1;
        o += snprintf(b + o, sizeof b - (size_t)o, "；%s%llu %ux%u 格式 %#x 标志 %#x %s%s%s 核心给 %ux%u 首笔视口 %.0f,%.0f %.0fx%.0f × %llu", g_wd_sk[best].depth ? "深度 " : "",
                      (unsigned long long)g_wd_sk[best].ser, g_wd_sk[best].w, g_wd_sk[best].h, g_wd_sk[best].fmt, g_wd_sk[best].fl,
                      g_wd_sk[best].reg ? "已登记" : "未登记", g_wd_sk[best].live ? "" : "、对象已释放", g_wd_sk[best].why ? g_wd_sk[best].why : "", g_wd_sk[best].rw, g_wd_sk[best].rh,
                      g_wd_sk[best].vx, g_wd_sk[best].vy, g_wd_sk[best].vw, g_wd_sk[best].vh, (unsigned long long)g_wd_sk[best].n);
    }
    MLOG("S2Arm widen: 没进核心的笔（近 300 次提交）%llu 笔，按目标（序号 游戏尺寸 … × 笔数，前 8）%s%s", (unsigned long long)g_wd_sk_n, b,
         g_wd_sk_other ? "；另有表满没记的" : "");
    memset(g_wd_sk, 0, sizeof g_wd_sk); g_wd_sk_n = g_wd_sk_other = 0;
}
static void wd_sub_begin(void) { g_wd_rs_data = NULL; if (g_wd_rs_gpu) { g_wd_rs_gpu = 0; g_args_dirty[1] = 1; } if (wd_on() <= 0) return; pthread_mutex_lock(&g_wd_mu); g_wd_npr_arm = g_wd_npr; pthread_mutex_unlock(&g_wd_mu); }
static void wd_sub_end(void) {   // 提交结束：本次提交开始前排的释放生效；每 300 次提交打一行读数（核心统计 + 本线程托管分配增量，判据：稳态增量 0）
    if (g_wd <= 0) return;
    pthread_mutex_lock(&g_wd_mu); wd_pr_apply(g_wd_npr_arm); pthread_mutex_unlock(&g_wd_mu);
    static uint64_t n, a0; static int has_a0;
    if (++n % 300 == 0) {
        pthread_mutex_lock(&g_wd_mu);
        uint64_t a = s2a_widen_alloc_bytes(); char line[1024]; s2a_widen_report(line, sizeof line);   // 增量取在出统计行之前：统计行本身分配（字符串）不算进渲染路径
        MLOG("S2Arm widen: submits %llu, draws %llu (depth-write 3D draws past the core %llu, into core %llu, rewritten %llu with %llu new copies, %llu slot results reused, slots given as the GPU will read them %llu, skipped slots with GPU-side writes %llu), dispatches %llu (writing widened images: groups widened %llu, not per pixel %llu), 16:9 sampling remaps %llu, managed alloc +%llu bytes; hook %llu K instr/submit %llu instr/draw; %s", (unsigned long long)n, (unsigned long long)g_wd_draws, (unsigned long long)g_wd_light, (unsigned long long)g_wd_core,
             (unsigned long long)g_wd_rw_draws, (unsigned long long)g_wd_copies, (unsigned long long)g_wd_reuse, (unsigned long long)g_wd_view_n, (unsigned long long)g_wd_skip_pend, (unsigned long long)g_wd_disp, (unsigned long long)g_wd_disp_wide, (unsigned long long)g_wd_disp_flat, (unsigned long long)g_wd_uvx_n, (unsigned long long)(has_a0 ? a - a0 : 0), (unsigned long long)(g_wd_prof_t / 300 / 1000), (unsigned long long)(g_wd_prof_n ? g_wd_prof_t / g_wd_prof_n : 0), line); g_wd_prof_t = g_wd_prof_n = 0;
        MLOG("S2Arm widen: render targets registered %d (table %d), texture objects live %u; shadow slots unchanged since last hand-over %llu (not re-bound, results reused %llu), handed over by their updated pieces only %llu, whole %llu",
             g_wd_nt, WD_T, nvn_be_tex_live_n(), (unsigned long long)g_wd_view_skip, (unsigned long long)g_wd_view_reuse, (unsigned long long)g_wd_view_ranged,
             (unsigned long long)(g_wd_view_n - g_wd_view_skip - g_wd_view_ranged));   // 两数对照：登记数一路涨而存活数不涨 = 登记漏还
        wd_skip_flush();
        a0 = s2a_widen_alloc_bytes(); has_a0 = 1;
        pthread_mutex_unlock(&g_wd_mu);
    }
}
// 一笔绘制（draw() 定视口之前）：① 目标 ② 各阶段各槽绑定 ③ 定画法 ⑤ 各槽出数（有改写的拷进暂存区，encode_args 绑它）。④ 视口 / 裁剪换算在 draw() 里按 g_wd_mode 做
// 这笔绘制时 GPU 会读到的 [p, p + n)：这次提交里落在它上面的只有内嵌常量更新时，按回放层的影子拼出来（全被本遍延后的更新盖住 = ubd_read；
//   部分盖住 / 前几遍的更新 = ubp_get，同 encode_args 给这个槽绑的内容），放进 g_wd_cbv[st][r]；有拷贝 / 填充等 CPU 看不到内容的写时返回 0。
//   10-26 丝之歌直连菜单：logo / 标题字所在的投影常量每遍用内嵌更新写，这里原先不用改写副本、照原值画，画法却仍是 Hor（视口 × k）→ 界面横向拉宽 k 倍
static int wd_cb_view(int st, int r, uint64_t p, uint32_t n) {
    static int on = -1; if (on < 0) { const char *e = getenv("S2A_WIDEN_UBVIEW"); on = !(e && !strcmp(e, "0")); }   // S2A_WIDEN_UBVIEW=0：关（A/B 用），同改前不用改写副本
    if (!on || n > sizeof g_wd_scr) return 0;
    if (!g_wd_cbv[st][r] && !(g_wd_cbv[st][r] = malloc(sizeof g_wd_scr))) return 0;
    int here = g_wd_cp[st][r] == p && g_wd_cn[st][r] == n;   // 副本装的就是这一段
    g_wd_cp[st][r] = p; g_wd_cn[st][r] = n;   // 下面每条成功的出口都让副本装这一段（失败出口 return 0 前复原）
    if (g_nubd && ubd_hits(p, p + n) && ubd_covers(p, p + n)) {   // 整段被延后更新盖住：按延后更新拼
        // 3：副本是同一代延后表上次拼的这一段——延后表同代里只增不减（被新更新整个盖住的旧项才删，它的字节在新项里），两次之间只差序号 ≥ 上次的那些更新：
        //   只把它们按序叠上去（每字节仍以最新的写为准），段表 = 它们落在这一段里的区间
        const ubd_ent *ov[UBD_OV], *e; int k = ubd_overlaps(p, p + n, ov, UBD_OV, &e);
        if (here && k > 0 && g_wd_ug[st][r] == g_ubd_gen && g_wd_cbq[st][r] == 0) {
            int nd = 0; uint32_t s0 = g_wd_us[st][r];
            for (int i = 0; i < k && nd < UBP_DMAX; i++) if (ov[i]->seq >= s0) {
                ubd_lay1(ov[i], p, p + n, g_wd_cbv[st][r]);
                uint32_t a = (uint32_t)((ov[i]->lo > p ? ov[i]->lo : p) - p), b = (uint32_t)((ov[i]->hi < p + n ? ov[i]->hi : p + n) - p);
                int j = nd++; while (j > 0 && g_wd_dr[2 * (j - 1)] > a) { g_wd_dr[2 * j] = g_wd_dr[2 * (j - 1)]; g_wd_dr[2 * j + 1] = g_wd_dr[2 * (j - 1) + 1]; j--; }
                g_wd_dr[2 * j] = a; g_wd_dr[2 * j + 1] = b; }
            int over = 0; for (int i = 0; i < k; i++) over += ov[i]->seq >= s0;
            if (over <= UBP_DMAX) {
                int m = 0; for (int i = 0; i < nd; i++) { if (m && g_wd_dr[2 * (m - 1) + 1] >= g_wd_dr[2 * i]) { if (g_wd_dr[2 * i + 1] > g_wd_dr[2 * (m - 1) + 1]) g_wd_dr[2 * (m - 1) + 1] = g_wd_dr[2 * i + 1]; }
                                                         else { g_wd_dr[2 * m] = g_wd_dr[2 * i]; g_wd_dr[2 * m + 1] = g_wd_dr[2 * i + 1]; m++; } }
                g_wd_us[st][r] = g_ubd_seq; g_wd_dn = m;
                if (!m) { g_wd_cbv_same++; return 2; }   // 上次之后没有落在这一段的新更新：内容没变
                g_wd_cbv_delta++; return 3; } }
        ubd_lay(p, p + n, g_wd_cbv[st][r], ov, k);   // 同 ubd_read
        g_wd_cbq[st][r] = 0; g_wd_ug[st][r] = g_ubd_gen; g_wd_us[st][r] = g_ubd_seq; return 1; }
    g_wd_ug[st][r] = 0;   // 下面按影子拼：不再是延后表那条线
    uint64_t g; const uint8_t *c;
    if (!ubp_get(p, p + n, &g, &c)) { g_wd_cp[st][r] = here ? p : 0; g_wd_cn[st][r] = here ? n : 0; return 0; }
    // 副本里已经是这一份影子（g_ubp_q 每份影子各一，同一份 = 同一段同样的字节）：不再拷。常量块每遍部分更新一次、每笔都绑时，
    //   影子从缓存原样交回（ubp_get），原先每笔仍把它整段拷进副本一遍
    if (here && g_wd_cbq[st][r] == g_ubp_q) { g_wd_cbv_same++; return 2; }   // 2：副本已是这一份影子（内容与上次交出时逐字节相同）
    // 3：副本是这份影子续拼自的上一份（ubp_get 的 g_ubp_prevq），两份只在更新段 g_ubp_d 里不同——只拷这些段，段表留给交核心那一步（wd_bind_stage 只让核心比这些段）
    if (here && g_ubp_nd > 0 && g_wd_cbq[st][r] && g_wd_cbq[st][r] == g_ubp_prevq) {
        ubq_cpu(g_ubp_q);
        for (int i = 0; i < g_ubp_nd; i++) { uint32_t a = g_ubp_d[2 * i], b = g_ubp_d[2 * i + 1] < n ? g_ubp_d[2 * i + 1] : n; if (b > a) memcpy(g_wd_cbv[st][r] + a, c + a, b - a); }
        memcpy(g_wd_dr, g_ubp_d, 2 * (size_t)g_ubp_nd * sizeof *g_wd_dr); g_wd_dn = g_ubp_nd;
        g_wd_cbq[st][r] = g_ubp_q; g_wd_cbv_delta++; return 3; }
    // made here, on this thread: no hand-off to the copy worker and back
    ubq_cpu(g_ubp_q); memcpy(g_wd_cbv[st][r], c, n); g_wd_cbq[st][r] = g_ubp_q; g_wd_cbv_copy++; return 1;
}
// 一个阶段的常量槽交给核心（绘制 / 派发的 ②）：用到的槽 + 上一次还挂着的槽（没用到的要解绑）。持 g_wd_mu 调
static void wd_bind_stage(int st, NvShader *sh) {
    uint16_t used = 0;
    if (sh) for (int i = 0; i < sh->rf.nb; i++) if (sh->rf.b[i].kind == NVN_RB_CBUF && sh->rf.b[i].reg < 16) used |= (uint16_t)(1u << sh->rf.b[i].reg);
    for (uint32_t m = used | g_wd_bound[st]; m; m &= m - 1) {
        int r = __builtin_ctz(m); const p_bind_buf *u = &S.ubo[st][r]; uint64_t p = 0; uint32_t n = 0;
        if ((used >> r & 1) && u->addr) { n = (uint32_t)cb_len(sh, r, u->size); p = u->addr; }
        int v = n && (pend_hits(p, n) || (g_nubd && ubd_hits(p, p + n))) ? wd_cb_view(st, r, p, n) : 0;
        if (v) {   // 每笔重绑：副本内容随这次提交里的更新变；与上次交出的是同一份影子、同一绑定时核心已有这些字节，不再交
            uint16_t bit = (uint16_t)(1u << r);
            int again = wd_vd_on() && (g_wd_viewm[st] & bit) && g_wd_b[st][r].ptr == p && g_wd_b[st][r].len == n;   // 上次交给核心的就是这个槽这一处（同一副本缓冲、同长）
            if (v == 2 && again) { g_wd_vsame[st] |= bit; g_wd_view_skip++; }
            else if (v == 3 && again) { s2a_widen_cbuf_bind_ranges(st, r, g_wd_cbv[st][r], n, g_wd_dr, g_wd_dn); g_wd_vsame[st] &= (uint16_t)~bit; g_wd_view_ranged++; }
            else { s2a_widen_cbuf_bind(st, r, g_wd_cbv[st][r], n); g_wd_vsame[st] &= (uint16_t)~bit; }
            g_wd_viewm[st] |= bit; g_wd_view_n++;
            g_wd_b[st][r].ptr = p; g_wd_b[st][r].len = n; g_wd_b[st][r].sub = 0; g_wd_bound[st] |= (uint16_t)(1u << r); continue;
        }
        g_wd_viewm[st] &= (uint16_t)~(1u << r); g_wd_vsame[st] &= (uint16_t)~(1u << r);
        if (g_wd_b[st][r].ptr == p && g_wd_b[st][r].len == n && (!n || g_wd_b[st][r].sub == g_sub_serial)) continue;
        s2a_widen_cbuf_bind(st, r, (const void *)(uintptr_t)p, n);
        g_wd_b[st][r].ptr = p; g_wd_b[st][r].len = n; g_wd_b[st][r].sub = g_sub_serial;
        if (n) g_wd_bound[st] |= (uint16_t)(1u << r); else g_wd_bound[st] &= (uint16_t)~(1u << r);
    }
}
// 一个阶段各槽出数（绘制 / 派发的 ⑤）：有改写的拷进本次提交的暂存区，encode_args 绑 g_wd_gpu[st][r]。返回这一阶段有没有改写。持 g_wd_mu 调
static int wd_emit_stage(int st, int64_t gen, int no_emit, int *skipped) {
    int had = 0, same = 1; uint64_t prev[16]; memcpy(prev, g_wd_gpu[st], sizeof prev);
    for (uint32_t m = g_wd_had[st] ? 0xffff : 0; m; m &= m - 1) g_wd_gpu[st][__builtin_ctz(m)] = 0;
    for (uint32_t m = no_emit ? 0 : g_wd_bound[st]; m; m &= m - 1) {
        int r = __builtin_ctz(m); uint32_t n = g_wd_b[st][r].len; uint64_t p = g_wd_b[st][r].ptr;
        typeof(g_wd_last[0][0]) *L = &g_wd_last[st][r];
        int view = g_wd_viewm[st] >> r & 1;   // 交给核心的是 GPU 会读到的内容（影子）：改写副本可用，但内容每笔可能变，不复用上次
        if (view && (g_wd_vsame[st] >> r & 1) && L->sub == g_arena_gen && L->ptr == p && L->len == n && L->gen == gen) {   // 内容同上次、核心状态没变：出数同上次
            g_wd_gpu[st][r] = L->gpu; had |= L->gpu != 0; g_wd_view_reuse++; continue; }
        if (!view && L->sub == g_arena_gen && L->ptr == p && L->len == n && L->gen == gen &&   // 同提交同绑定、核心状态没变：出数与上次相同
            !(L->gpu && (pend_hits(p, n) || (g_nubd && ubd_hits(p, p + n))))) { g_wd_gpu[st][r] = L->gpu; had |= L->gpu != 0; g_wd_reuse++; continue; }   // 副本之后排了 GPU 侧写就不能再用
        uint64_t g = 0;
        if (s2a_widen_cbuf_emit(st, r, g_wd_scr, n <= sizeof g_wd_scr ? n : (uint32_t)sizeof g_wd_scr)) {
            if (!view && (pend_hits(p, n) || (g_nubd && ubd_hits(p, p + n)))) { g_wd_skip_pend++; (*skipped)++; }   // GPU 侧写（拷贝 / 填充等）落在绑定上、拼不出 GPU 会读到的内容：不用改写副本
            else if (L->sub == g_arena_gen && L->ptr == p && L->len == n && L->gpu && !memcmp(L->data, g_wd_scr, n)) g = L->gpu;
            else { id<MTLBuffer> ab; size_t o = arena_alloc(n, &ab); uint8_t *d = (uint8_t *)ab.contents + o; memcpy(d, g_wd_scr, n); g = ab.gpuAddress + o; L->data = d; g_wd_copies++; }
        }
        L->gpu = g; L->ptr = p; L->len = n; L->sub = g_arena_gen; L->gen = gen;
        g_wd_gpu[st][r] = g; had |= g != 0;
    }
    same = !memcmp(prev, g_wd_gpu[st], sizeof prev);
    if (!same) g_args_dirty[st] = 1;   // 改写副本地址变了（或改写停了，换回游戏内存）就重编；和上一笔完全一样时上一笔编好的参数块照用
    g_wd_had[st] = (uint8_t)had;
    return had;
}
// 画面分层图集按需放宽（同通用模式 WidenRenderer.BeforeDraw → WidenTexture.ForceWiden，10-23 八方2 走动右侧拉丝那套的第 ② 件）：开遍前调。
//   这笔的目标是没放宽、没绑深度的单层 2D 颜色图，而程序在片元 / 顶点阶段采样了放宽过的颜色图（读放宽的外延内容：景深散点按放宽源铺精灵、合成遍按放宽画布读）
//   → 问核心（s2a_widen_layer_widen）它是不是两层竖拼的分层图集，是就把存储放宽；开着的遍收掉，按放宽存储重开
static int wd_fmt_ds(MTLPixelFormat f) { return f == MTLPixelFormatDepth16Unorm || f == MTLPixelFormatDepth32Float || f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatStencil8 || f == MTLPixelFormatX32_Stencil8; }
static int wd_samples_wide(const NvShader *sh, int st) {
    if (!sh) return 0;
    int hit = 0; pthread_mutex_lock(&g_rmu);
    for (int i = 0; i < sh->rf.nb && !hit; i++) { const nvn_rbind *b = &sh->rf.b[i]; if (b->kind != NVN_RB_TEX) continue;
        int tid = (int)(tex_slot_h(S.tex[st], S.img[st], b->reg) & 0xfffff);
        if (tid < 0 || tid >= g_ntreg || !g_treg[tid].ok || !g_treg[tid].t.d.width) continue;
        void *tv = NULL; tex_fast_rid(tid, &tv);
        id<MTLTexture> m = (__bridge id<MTLTexture>)tv;   // 横向放宽或窄屏加高过（11-07 小小梦魇3 Duo：源只加高不加宽，原先只认宽，泛光链从没进 LayerWiden）
        hit = m && (rs_cw(m) > g_treg[tid].t.d.width || rs_ch(m) > g_treg[tid].t.d.height) && !wd_fmt_ds(m.pixelFormat); }
    pthread_mutex_unlock(&g_rmu);
    return hit;
}
static void wd_layer_widen(NvProg *pr) {
    static uint64_t n;
    if (wd_on() <= 0 || !pr || !R.has_rt || R.rt.n < 1 || !R.rt.color[0] || R.rt.depth) return;
    const tex_t *c0 = R.rt.color[0];
    if (c0->d.depth > 1 || c0->d.samples > 1 || (R.rt.has_cview[0] && R.rt.cview[0].set_levels && R.rt.cview[0].base_level)) return;
    id<MTLTexture> mt = tex_mtl(c0); if (!mt || rs_cw(mt) != c0->d.width || rs_ch(mt) != c0->d.height || wd_fmt_ds(mt.pixelFormat)) return;
    if (!wd_samples_wide(pr->sh[1], 1) && !wd_samples_wide(pr->sh[0], 0)) return;
    int w1 = s2a_widen_layer_widen((uint32_t)c0->serial, (int)c0->d.width, (int)c0->d.height);
    int h1 = s2a_widen_tex_h((uint32_t)c0->serial, (int)c0->d.height);   // 窄屏：核心按加高登记（宽不变），存储按核心给的高放宽（11-07 小小梦魇3 Duo 泛光链）
    if (w1 <= (int)c0->d.width && h1 <= (int)c0->d.height) return;
    if (!tex_widen(c0, (NSUInteger)(w1 > (int)c0->d.width ? w1 : (int)c0->d.width), h1 > (int)c0->d.height ? (NSUInteger)h1 : 0)) return;
    if (g_enc) rp_end();
    if (n++ < 8) MLOG("S2Arm widen: layered atlas ser=%llu %ux%u widened to %d (first read of widened content as its target)", (unsigned long long)c0->serial, c0->d.width, c0->d.height, w1);
}
static void wd_draw_(NvProg *pr);
// 片元坐标倍率（同通用模式 WidenRenderer 写 render_scale[0]）：Ryujinx 翻译的片元着色器把片元坐标除以 support_buffer.render_scale[0]（InstEmitAttribute），
//   放宽目标上按 ScaleK / Hor 画、读片元坐标的程序要看到客体坐标（核心同时给屏幕尺寸常量原值），倍率 = 目标放宽比 k；直连原先恒为 1：
//   片元坐标是放宽像素 0..1564、屏幕尺寸常量却是原值 1280，屏幕空间算法取图错位（10-26 巫师3 时间抗锯齿那一遍：整幅成双、错位叠进历史帧；通用模式同核心无此现象）。
//   取图倍率（同通用模式 WidenRenderer.WriteTexScales，Ryujinx TextureBindingsManager.UpdateScale 的语义）：着色器整数取图 / 读图像的坐标 × render_scale[下标]、
//   textureSize ÷ |它|，下标由翻译器认出（json tex_scales，wd_tex_scales 按所绑贴图的放宽比填）。
//   有不是 1 的值时给这一笔一份静态支持缓冲的副本，只改 render_scale 的横向值（纵向 render_scale_y 在 1440 保持 1，翻译器补丁 0206 语义，见 support_buf）；同一次提交里同样的值复用
static void wd_rscale(float fs, int n, const uint8_t *ix, const float *v, float fsy, const float *vy) {   // fsy / vy：纵向（窄屏加高，render_scale_y 在 1440 + 16 i）；vy 可空 = 全 1
    static uint64_t last_gpu, last_sub; static const uint8_t *last_data; static float last_fs, last_fsy, lv[72], lvy[72]; static uint8_t lix[72]; static int ln;
    if (n < 0 || n > 72) MDIE("widen: invalid texture-scale count %d", n);
    float vy1[72]; for (int i = 0; i < n; i++) { if (ix[i] < 1 || ix[i] > 72) MDIE("widen: invalid texture-scale index %u", ix[i]); vy1[i] = vy ? vy[i] : 1.0f; }
    if (!(fsy > 0)) fsy = 1.0f;
    g_wd_fsc = fs > 0 ? fs : 1.0f; g_wd_fsyc = fsy;
    int any = (fs > 0 && fs != 1.0f) || fsy != 1.0f; for (int i = 0; i < n; i++) any |= v[i] != 1.0f || vy1[i] != 1.0f;
    if (!any) { g_wd_rs_data = NULL; if (g_wd_rs_gpu) { g_wd_rs_gpu = 0; g_args_dirty[1] = 1; } return; }
    if (!(fs > 0)) fs = 1.0f;
    if (!(g_wd_rs_data && last_gpu && last_sub == g_arena_gen && last_fs == fs && last_fsy == fsy && ln == n && !memcmp(lix, ix, (size_t)n) && !memcmp(lv, v, sizeof *v * (size_t)n) && !memcmp(lvy, vy1, sizeof *vy1 * (size_t)n))) {
        id<MTLBuffer> ab; size_t o = arena_alloc(4096, &ab); uint8_t *d = (uint8_t *)ab.contents + o;
        memcpy(d, support_buf().contents, 4096); memcpy(d + 192, &fs, 4); memcpy(d + 1440, &fsy, 4);   // render_scale[i] 在 192 + 16 i、render_scale_y[i] 在 1440 + 16 i（取 .x）
        for (int i = 0; i < n; i++) { memcpy(d + 192 + 16 * ix[i], &v[i], 4); memcpy(d + 1440 + 16 * ix[i], &vy1[i], 4); }
        last_gpu = ab.gpuAddress + o; last_data = d; last_sub = g_arena_gen; last_fs = fs; last_fsy = fsy; ln = n; memcpy(lix, ix, (size_t)n); memcpy(lv, v, sizeof *v * (size_t)n); memcpy(lvy, vy1, sizeof *vy1 * (size_t)n);
    }
    g_wd_rs_data = last_data;
    if (g_wd_rs_gpu != last_gpu) { g_wd_rs_gpu = last_gpu; g_args_dirty[1] = 1; }
}
// 片元着色器各取图倍率下标的值（同 WidenRenderer.WriteTexScales）：所绑贴图的横向放宽比 r = 实际存储宽 ÷ 客体宽；r = 1 写 1，r 等于目标放宽比 tk（ScaleK / Hor 画法下目标的
//   放宽比，其余画法 1）写 −r（Ryujinx 负倍率：按真实片元坐标插值，⌊客体坐标⌋·r + mod(片元坐标, r)），否则写 r。只在着色器所有整数取图都经过缩放（scale_exact）时写；
//   不然这个程序按真实像素坐标画（同通用模式 RealPx：不除片元坐标、不写取图倍率）。返回项数
// 调用方已持 g_rmu（encode_args_ 遍历绑定时持着它：内部分辨率 rs_support 从那里调）；不持锁的调用方用下面的 wd_tex_scales
static int wd_tex_scales_locked(const NvShader *fs, float tk, uint8_t *ix, float *v, float tky, float *vy) {   // tky / vy：纵向同理（窄屏加高的贴图：实际存储高 ÷ 客体高）
    int n = 0; if (!fs || fs->exact != 1) return 0;
    for (int i = 0; i < fs->nts; i++) {
        unsigned reg = fs->ts[i].reg; uint64_t h = fs->ts[i].img ? (reg < 32 ? S.img[1][reg] : 0) : tex_slot_h(S.tex[1], S.img[1], reg); int tid = (int)(h & 0xfffff);
        float r = 1.0f, ry = 1.0f;
        if (tid >= 0 && tid < g_ntreg && g_treg[tid].ok && g_treg[tid].t.d.width > 0) { void *tv = NULL; tex_fast_rid(tid, &tv);
            NSUInteger mw = tv ? ((__bridge id<MTLTexture>)tv).width : 0; if (mw && mw != g_treg[tid].t.d.width) r = (float)mw / (float)g_treg[tid].t.d.width;
            NSUInteger mh = tv ? ((__bridge id<MTLTexture>)tv).height : 0; if (mh && g_treg[tid].t.d.height && mh != g_treg[tid].t.d.height) ry = (float)mh / (float)g_treg[tid].t.d.height; }
        // 诊断（11-04 Switch 2 一维 TLD.LZ 折行读核查）：取图倍率落在缓冲贴图上的条目（折行读的坐标经过这一倍率）；倍率不为 1 的点名前 8 例，计数进 mtl_tb2_stats 那行
        { void *tv = NULL; if (tid > 0 && tid < g_ntreg && g_treg[tid].ok) tex_fast_rid(tid, &tv);
          if (tv && ((__bridge id<MTLTexture>)tv).textureType == MTLTextureTypeTextureBuffer) { g_wd_ts_tbuf++;
              if ((r != 1.0f || ry != 1.0f) && g_wd_ts_tbuf_scaled++ < 8) MLOG("【红】 scaled fetch on a texture buffer: shader slot %u, texture ID %d, scale %g x %g", reg, tid, r, ry); } }
        ix[n] = fs->ts[i].idx; vy[n] = ry == 1.0f ? 1.0f : ry == tky ? -ry : ry; v[n++] = r == 1.0f ? 1.0f : r == tk ? -r : r;
    }
    return n;
}
static int wd_tex_scales(const NvShader *fs, float tk, uint8_t *ix, float *v, float tky, float *vy) {
    pthread_mutex_lock(&g_rmu); int n = wd_tex_scales_locked(fs, tk, ix, v, tky, vy); pthread_mutex_unlock(&g_rmu); return n;
}
// 计算派发（nvn_mtl.m dispatch()，编参数块之前、没有开着的遍）：同通用模式 WidenRenderer.DispatchCompute。
//   ① 程序写的存储图像登记给核心、16:9 一族的换成放宽的存储（tex_widen，同开遍时的渲染目标）——只靠计算写的图原先从不登记，一直是游戏的宽；
//      后面按放宽坐标读它的遍（片元坐标取样）读过右边缘、夹边成横条（10-26 八方2 西康宁湾海道：右侧 18.2% = 1 − 1/k 拉丝，856 宽存储、k 1.222）
//   ② 写了放宽图像、派发按像素铺：X 组数补到放宽宽度（s2a_widen_groups_x）；不按像素铺的照原样派、计数
//   ③ 计算阶段常量槽交给核心（同绘制 ②），s2a_widen_dispatch 定改写，出数进 g_wd_gpu[5]（encode_args 绑改写副本）
static void wd_dispatch(NvShader *cs, uint32_t *gx, uint32_t *gy, int indirect) {   // gy：窄屏加高的图像同样补 Y 组数
    if (wd_on() <= 0 || !cs) return;
    tex_t im[8]; int nim = 0;
    pthread_mutex_lock(&g_rmu);
    for (int i = 0; i < cs->rf.nb && nim < 8; i++) { const nvn_rbind *b = &cs->rf.b[i]; if (b->kind != NVN_RB_IMG || b->reg >= 32) continue;
        int tid = (int)(S.img[5][b->reg] & 0xfffff);
        if (tid >= 0 && tid < g_ntreg && g_treg[tid].ok && g_treg[tid].t.serial) im[nim++] = g_treg[tid].t; }
    pthread_mutex_unlock(&g_rmu);
    int on_wide = 0, nx = -1, ny = -1;
    uint32_t wide_ser[8]; int nwide = 0;
    for (int i = 0; i < nim; i++) {
        pthread_mutex_lock(&g_wd_mu); uint32_t r = wd_tex(&im[i], 0, 0), rh = wd_tex_h(&im[i]);
        if (r <= im[i].d.width && rh <= im[i].d.height) s2a_widen_gpu_wrote((uint32_t)im[i].serial, 0);   // 放不宽 / 不放宽的也是 GPU 写的，不是 CPU 供图（原比例页的来源只认 CPU 供图）
        pthread_mutex_unlock(&g_wd_mu);
        if ((r <= im[i].d.width && rh <= im[i].d.height) || !tex_widen(&im[i], r, rh)) continue;
        on_wide = 1; if (r > im[i].d.width) wide_ser[nwide++] = (uint32_t)im[i].serial;
        if (nx < 0 && !indirect && r > im[i].d.width) nx = s2a_widen_groups_x((int)*gx, (int)*gy, (int)im[i].d.width, (int)r, (int)im[i].d.height);
        if (ny < 0 && !indirect && rh > im[i].d.height) ny = s2a_widen_groups_x((int)*gy, (int)*gx, (int)im[i].d.height, (int)rh, (int)im[i].d.width);   // 纯函数，两轴对调即纵向
    }
    pthread_mutex_lock(&g_wd_mu);
    // 组数补到放宽宽度的派发整张写了放宽图像（含两侧带）：报给核心，本帧两侧有确定内容（S2A_WIDEN_DRAW_WRITES 的约定；没补到的派发两侧没写，不报）
    if (nx > 0) for (int i = 0; i < nwide; i++) s2a_widen_gpu_wrote(wide_ser[i], 0);
    if (g_wd == S2A_WIDEN_UI) for (int i = 0; i < nim; i++) wd_s3d_set(im[i].serial, 1);   // 满屏判据：计算着色器写过的图像保守算有 3D（同通用模式 WidenTexture.Scene3D）
    g_wd_disp++;
    if (on_wide) { if (nx > 0 || ny > 0) { if (nx > 0) *gx = (uint32_t)nx; if (ny > 0) *gy = (uint32_t)ny; g_wd_disp_wide++; } else g_wd_disp_flat++; }
    wd_bind_stage(5, cs);
    int32_t sh[6] = {0, 0, 0, 0, 0, wd_sh(5, cs)};
    s2a_widen_dispatch(sh, nim && !on_wide);
    int skipped = 0; wd_emit_stage(5, s2a_widen_state_gen(), 0, &skipped);
    if (wd_tr_on()) { char il[160] = ""; for (int i = 0, o = 0; i < nim && o < (int)sizeof il - 24; i++) o += snprintf(il + o, sizeof il - o, " %llu:%ux%u", (unsigned long long)im[i].serial, im[i].d.width, im[i].d.height);
        MLOG("S2Arm widen trace: frame %llu dispatch %s: %d image(s)%s%s, groups x %u%s", (unsigned long long)g_wd_frame, cs->key, nim, il, on_wide ? " widened" : "", *gx, nx < 0 && on_wide ? " (not per pixel, as given)" : ""); }
    pthread_mutex_unlock(&g_wd_mu);
}
static void wd_draw(NvProg *pr) {
    if (__builtin_expect(g_wd_prof < 0, 0)) g_wd_prof = getenv("S2A_WIDEN_PROF") != NULL;
    pthread_mutex_lock(&g_wd_mu);
    if (!g_wd_prof) wd_draw_(pr);
    else { uint64_t c0[2] = {0, 0}, c1[2] = {0, 0}; thread_selfcounts(1, c0, sizeof c0); wd_draw_(pr); thread_selfcounts(1, c1, sizeof c1); g_wd_prof_t += c1[0] - c0[0]; g_wd_prof_n++; }   // 本线程用户态指令数（不受抢占影响）
    pthread_mutex_unlock(&g_wd_mu);
}
// 片元实际采样的贴图表（贴图槽 TEX + 常量缓冲里的无绑定句柄 TEXU），持 g_rmu 调；wd_draw_ 进核心的笔与跳过核心的铺满层登记（s2a_widen_note_fill）共用
static int wd_frag_tex(__unsafe_unretained NvShader *fs, s2a_widen_tex *tx, tex_t *txt) {
    int ntx = 0;
    // 贴图槽（TEX）与常量缓冲里的无绑定句柄（TEXU，单个或数组：元素 k 在 +8k），取法同回放层 encode_args。原先只收 TEX：10-31 丝之歌暂停页（Unity，全是 TEXU）
    //   每笔都报「采样 无」，核心当纯色底收进中间再外推，暂停时的场景快照右移 106 像素、两侧露出旧帧（帧回放定因）
    for (int i = 0; i < fs->rf.nb && ntx < 64; i++) { const nvn_rbind *b = &fs->rf.b[i]; if (b->kind != NVN_RB_TEX && b->kind != NVN_RB_TEXU) continue;
        for (int k = 0; k < (b->kind == NVN_RB_TEXU && b->n ? b->n : 1) && ntx < 64; k++) {
            uint64_t h; int tid;
            if (b->kind == NVN_RB_TEX) { h = tex_slot_h(S.tex[1], S.img[1], b->reg); tid = (int)(h & 0xfffff); }
            else { uint32_t u = b->n ? ubo_handle(1, b->reg, b->off + 8 * k) : ubo_packed(1, b); tid = ubo_tex_id(u); int sid = ubo_samp_id(u); h = (uint64_t)(uint32_t)tid | (uint64_t)(uint32_t)sid << 20; }
            if (tid < 0 || tid >= g_ntreg || !g_treg[tid].ok || !g_treg[tid].t.serial) continue;
            const tex_t *t = &g_treg[tid].t; tx[ntx] = (s2a_widen_tex){(uint32_t)t->serial, (int32_t)t->d.width, (int32_t)t->d.height, 1.0f, wd_tex_flags(h) | wd_flat_flags(t->serial)}; txt[ntx++] = *t; } }
    return ntx;
}
// 一笔绘制的内容来历（持 g_wd_mu 调，Ui 模式）：开了深度测试 / 写深度，或片元采样了带 3D 标记的贴图 → 这笔的各颜色目标标 3D（同通用模式 WidenRenderer s3d：只标不清）
static void wd_s3d_draw(NvProg *pr, int depth) {
    int on = depth;
    __unsafe_unretained NvShader *fs = pr ? pr->sh[1] : nil;
    if (!on && fs && g_wd_s3d_n) {
        pthread_mutex_lock(&g_rmu);
        for (int i = 0; !on && i < fs->rf.nb; i++) { const nvn_rbind *b = &fs->rf.b[i]; if (b->kind != NVN_RB_TEX && b->kind != NVN_RB_TEXU) continue;
            for (int k = 0; !on && k < (b->kind == NVN_RB_TEXU && b->n ? b->n : 1); k++) {
                int tid;
                if (b->kind == NVN_RB_TEX) tid = (int)(tex_slot_h(S.tex[1], S.img[1], b->reg) & 0xfffff);
                else tid = ubo_tex_id(b->n ? ubo_handle(1, b->reg, b->off + 8 * k) : ubo_packed(1, b));
                if (tid >= 0 && tid < g_ntreg && g_treg[tid].ok && wd_s3d_has(g_treg[tid].t.serial)) on = 1; } }
        pthread_mutex_unlock(&g_rmu);
    }
    if (on && R.has_rt) for (int i = 0; i < R.rt.n && i < 8; i++) if (R.rt.color[i]) wd_s3d_set(R.rt.color[i]->serial, 1);
}
// 回放层的颜色清屏 / 整张拷贝 / 计算写图像报来（持 g_wd_mu 调）：清屏作废，拷贝随源，计算写保守算 3D（同通用模式）
static void wd_s3d_cleared(uint64_t ser) { if (g_wd == S2A_WIDEN_UI) wd_s3d_set(ser, 0); }
static void wd_s3d_copied(uint64_t dst, uint64_t src) { if (g_wd == S2A_WIDEN_UI) wd_s3d_set(dst, wd_s3d_has(src)); }
static void wd_draw_(NvProg *pr) {
    g_wd_fskey = pr && pr->sh[1] ? pr->sh[1]->key : "-";
    const tex_t *c0 = R.has_rt && R.rt.n > 0 ? R.rt.color[0] : NULL, *d0 = R.has_rt ? R.rt.depth : NULL;
    uint64_t cs = c0 ? c0->serial : 0, ds = d0 ? d0->serial : 0;
    s2a_widen_draw_in in; memset(&in, 0, sizeof in);
    if (S.has_vp) { in.vp_x = S.vp[0][0]; in.vp_y = S.vp[0][1]; in.vp_w = S.vp[0][2]; in.vp_h = S.vp[0][3]; }
    else { NSUInteger tw = 0, th = 0; rt_dims(&tw, &th); id<MTLTexture> ra = c0 ? tex_mtl(c0) : d0 ? tex_mtl(d0) : nil;   // canvas units (internal resolution), each axis by the target's own storage ÷ canvas
           double rsx = ra && rs_cw(ra) ? (double)ra.width / rs_cw(ra) : 1.0, rsy = ra && rs_ch(ra) ? (double)ra.height / rs_ch(ra) : 1.0; in.vp_w = (float)(tw / rsx); in.vp_h = (float)(th / rsy); }
    float vpr = in.vp_x + fabsf(in.vp_w), vpb = in.vp_y + fabsf(in.vp_h); wd_tex(c0, vpr, vpb); wd_tex(d0, vpr, vpb);   // 视口右边 / 下边：存储放不宽的目标按它定登不登记成可放宽（见 wd_tex）
    if (cs != g_wd_c0 || ds != g_wd_d0) { s2a_widen_targets((uint32_t)cs, (uint32_t)ds); g_wd_c0 = cs; g_wd_d0 = ds; }
    g_wd_draws++;
    if (g_wd == S2A_WIDEN_UI) wd_s3d_draw(pr, d0 && (S.ds.dt || S.ds.dw));   // 满屏判据：画进去的内容有没有 3D 场景（按内容来历，见 g_wd_s3d）
    if (!s2a_widen_viewport(in.vp_x, in.vp_w, in.vp_h, 1.0f)) {   // 没画在放宽 / 原生宽区域：核心只会原样，整笔跳过（各槽零拷贝绑游戏内存）
        g_wd_mode = S2A_WIDEN_KEEP; wd_uvx_set(g_wd_mode); wd_rscale(1.0f, 0, NULL, NULL, 1.0f, NULL); wd_trace("target not widened", &in, 0, NULL); wd_skip_note(c0, d0, &in);
        // 铺满整张颜色目标 0 的笔：只交采样表登记整屏副本来历（核心 WidenSession.NoteFill），不改画法。11-02 塞尔达直连菜单：模糊缩图链 782×360 → 320×180 的 16:9 一环
        //   在 Ui 模式下不进核心，菜单底图采样 320×180 认不出是整屏副本，按界面层收进中间 16:9、右侧 213 列黑
        if (c0 && pr->sh[1] && fabsf(in.vp_x) < 0.5f && fabsf(in.vp_w) >= c0->d.width - 0.5f && fabsf(in.vp_h) >= c0->d.height - 0.5f) {
            static s2a_widen_tex ftx[64]; static tex_t ftxt[64]; pthread_mutex_lock(&g_rmu); int fn = wd_frag_tex(pr->sh[1], ftx, ftxt); pthread_mutex_unlock(&g_rmu);
            if (fn > 0) s2a_widen_note_fill((uint32_t)c0->serial, (int)c0->d.width, (int)c0->d.height, ftx, fn); }
        for (int st = 0; st < 5; st++) if (g_wd_had[st]) { for (int r = 0; r < 16; r++) g_wd_gpu[st][r] = 0; g_wd_had[st] = 0; g_args_dirty[st] = 1; }
        return;
    }
    in.target_scale = 1; in.flags = (c0 ? S2A_WIDEN_DRAW_COLOR | S2A_WIDEN_DRAW_WRITES : 0) | (c0 && !(S.color.blend_en & 1) && (S.chmask.mask & 0xf) == 0xf ? S2A_WIDEN_DRAW_OPAQUE : 0) | (pr->sh[1] && pr->sh[1]->fragc && pr->sh[1]->exact != 0 ? S2A_WIDEN_DRAW_FRAGCOORD : 0)
               | (d0 && S.ds.dt && S.ds.dw ? S2A_WIDEN_DRAW_DEPTH_WRITE : 0) | (g_wd_inst > 1 ? S2A_WIDEN_DRAW_INSTANCED : 0) | (g_wd_vc > 6 ? S2A_WIDEN_DRAW_PATCHES : 0);   // 写深度（同 pso 的 depthWriteEnabled：要深度目标与深度测试）：核心不外推   // 读片元坐标：核心给屏幕尺寸常量原值、片元坐标按 frag_scale_x 除回客体坐标；
    //   本回放层把颜色清屏（OP_CLEAR_COLOR → s2a_widen_target_cleared）、贴图拷贝（copy_t2t）、计算写图像（wd_dispatch）都报给核心：核心据此判放宽目标两侧带本帧有没有确定内容（S2A_WIDEN_DRAW_WRITES）；
    //   颜色目标 0 不混合、四通道全写 = 不透明（S2A_WIDEN_DRAW_OPAQUE：本帧第一笔不透明铺满全宽就不用先清两侧）
    static s2a_widen_tex tx[64]; static tex_t txt[64]; int ntx = 0; __unsafe_unretained NvShader *fs = pr->sh[1];   // 片元实际采样的贴图：核心据此认「采样了放宽 / 原生宽图」与上屏的合成源
    if (fs) { pthread_mutex_lock(&g_rmu); ntx = wd_frag_tex(fs, tx, txt);
        pthread_mutex_unlock(&g_rmu);
        // 共享存储的另一个序号（回放层 g_alias：同池同偏移同描述 = 同一张 MTLTexture）：存储已被放宽（比游戏给的宽宽）、这个序号却没登记过——它就是放宽过的 GPU 内容，
        //   补登记成渲染目标（核心据此认「采样了放宽图」，不当 CPU 供图起 16:9 原比例页）。10-26 八方2：场景图 1802（896 宽）与放宽到 1094 的目标共用存储，
        //   采样它的那笔被起成页、按原宽 896 平移 99 画，清晰层只铺中间、右侧拉丝
        // 同一组贴图（序号逐个相同）且 g_ser_gen 没变（存储换过 / 放宽 / 重传都会加，同贴图 ID 视图缓存的失效条件）：上一笔已按同样的存储登记过，不再逐张取 MTLTexture
        //   （11-02 塞尔达回放：tex_mtl 占提交线程 4%，进核心的笔 83% 与上一笔采样同一组贴图）
        static uint64_t fl_ser[64], fl_gen = ~0ull; static int fl_n = -1;
        int fl_same = ntx == fl_n && fl_gen == g_ser_gen; for (int i = 0; fl_same && i < ntx; i++) fl_same = fl_ser[i] == txt[i].serial;
        if (!fl_same) { for (int i = 0; i < ntx; i++) { id<MTLTexture> mt = tex_mtl(&txt[i]); if (mt && rs_cw(mt) > txt[i].d.width) wd_tex(&txt[i], 0, 0); fl_ser[i] = txt[i].serial; }
                        fl_n = ntx; fl_gen = g_ser_gen; } }
    in.tex = tx; in.ntex = ntx;
    // 写深度 3D 笔旁路（核心 WidenSession.DrawLight，满屏线审）：游戏自出宽图、原生宽场景目标、开深度测试且写深度 → 核心只记账、画法 ScaleK、出数 0，
    //   不交常量（wd_bind_stage）、不出数（wd_emit_stage）。胶水与核心两边的「上次交过什么」都没动，下一笔全量照常比对续交
    if ((in.flags & S2A_WIDEN_DRAW_DEPTH_WRITE)) { s2a_widen_draw_out lo; memset(&lo, 0, sizeof lo);
        if (s2a_widen_draw_light(&in, &lo)) {
            g_wd_mode = S2A_WIDEN_SCALEK; wd_uvx_set(g_wd_mode); g_wd_light++;
            // 颜色目标 0 存储 ÷ 客体的倍率：只随这张目标与存储代（g_ser_gen：换存储 / 放宽 / 重传都加）变，按两者记住，不每笔取 MTLTexture（11-02 塞尔达回放：旁路笔每笔一次 tex_mtl，占提交线程约 2%）
            static uint64_t lk_ser, lk_gen = ~0ull; static float lk_tk = 1.0f, lk_tky = 1.0f;
            float tk = 1.0f, tky = 1.0f; if (c0 && c0->d.width) {
                if (c0->serial != lk_ser || g_ser_gen != lk_gen) { id<MTLTexture> cm = tex_mtl(c0); NSUInteger mw = cm.width, mh = cm.height;
                    lk_tk = mw ? (float)mw / (float)c0->d.width : 1.0f; lk_tky = mh && c0->d.height ? (float)mh / (float)c0->d.height : 1.0f; lk_ser = c0->serial; lk_gen = g_ser_gen; }
                tk = lk_tk; tky = lk_tky; }
            uint8_t six[72]; float sv[72], svy[72]; int sn = wd_tex_scales(pr->sh[1], tk, six, sv, tky, svy);
            int fc = (in.flags & S2A_WIDEN_DRAW_FRAGCOORD) != 0;
            wd_rscale(fc ? lo.frag_scale_x : 1.0f, sn, six, sv, fc ? s2a_widen_frag_scale_y() : 1.0f, svy);
            g_wd_side_on = g_wd_row_on = 0;
            if (pr->sh[0] && pr->sh[0]->push) memset(g_wd_push, 0, sizeof g_wd_push);
            if (g_wd_uvext != 0) { g_wd_uvext = 0; g_args_dirty[1] = 1; }
            for (int st = 0; st < 5; st++) if (g_wd_had[st]) { for (int r = 0; r < 16; r++) g_wd_gpu[st][r] = 0; g_wd_had[st] = 0; g_args_dirty[st] = 1; }
            wd_trace("light", &in, ntx, tx);
            return;
        } }
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (sh) in.shader[st] = wd_sh(st, sh); wd_bind_stage(st, sh); }
    s2a_widen_draw_out out; g_wd_mode = s2a_widen_draw(&in, &out); wd_uvx_set(g_wd_mode);
    // 纯 2D 帧：数各目标的 HOR 笔数（上屏时取最多的作世界目标）。回退中没有笔按放宽画，改数全部笔——
    //   否则回退期间游戏换了目标（植物大战僵尸开机黑屏回退后第 335 次出图起）新目标进不了小环，再不放哨兵、回退锁死
    if ((g_wd_mode == S2A_WIDEN_HOR || g_p2_fb) && c0 && s2a_widen_pure2d()) {
        wd_fb_vote(c0->serial, c0->d.width, c0->d.height); }   // 纯 2D 世界目标（原比例回退的两侧覆盖采样）
    // 颜色目标 0 的 MTLTexture 从这里到出数只取一次（下面两处要它的尺寸）：放宽目标存储（wd_tex / tex_widen）都在上面，这一段不再改它，两次取到的是同一张
    //   同一颜色目标、g_ser_gen 没变时沿用上一笔取到的那张（同上：存储一换代数就变）
    static __strong id<MTLTexture> c0_last; static uint64_t c0_ser = ~0ull, c0_gen = ~0ull;
    id<MTLTexture> c0m = nil; int c0m_ok = 0;
    if (c0 && c0->serial == c0_ser && c0_gen == g_ser_gen) { c0m = c0_last; c0m_ok = 1; }
    { float tk = 1.0f, tky = 1.0f; if ((g_wd_mode == S2A_WIDEN_SCALEK || g_wd_mode == S2A_WIDEN_HOR) && c0 && c0->d.width) { if (!c0m_ok) { c0m = tex_mtl(c0); c0m_ok = 1; } NSUInteger mw = c0m.width, mh = c0m.height; if (mw) tk = (float)mw / (float)c0->d.width; if (mh && c0->d.height) tky = (float)mh / (float)c0->d.height; }
      uint8_t six[72]; float sv[72], svy[72]; int sn = wd_tex_scales(pr->sh[1], tk, six, sv, tky, svy);
      int fc = (in.flags & S2A_WIDEN_DRAW_FRAGCOORD) != 0;
      wd_rscale(fc ? out.frag_scale_x : 1.0f, sn, six, sv, fc ? s2a_widen_frag_scale_y() : 1.0f, svy); }
    g_wd_side_on = (out.flags & S2A_WIDEN_OUT_PAGE_SIDES) && s2a_widen_page_sides(g_wd_sides);
    g_wd_row_on = (out.flags & S2A_WIDEN_OUT_PAGE_SIDES) && s2a_widen_page_rows(g_wd_rows);   // 窄屏：页只占中间 [pad, pad+h0) 行，上下两条没人写（10-28 B06）
    wd_trace("core", &in, ntx, tx);
    int64_t gen = s2a_widen_state_gen();
    if (pr->sh[0] && pr->sh[0]->push) memcpy(g_wd_push, out.push, sizeof g_wd_push);
    { float ue = 0; if ((out.flags & S2A_WIDEN_OUT_UV_EXTEND) && c0 && c0->d.width) { if (!c0m_ok) { c0m = tex_mtl(c0); c0m_ok = 1; } id<MTLTexture> ct = c0m; if (ct && rs_cw(ct) > c0->d.width) ue = (float)rs_cw(ct) / (float)c0->d.width; }
      if (ue != g_wd_uvext) { g_wd_uvext = ue; g_args_dirty[1] = 1; } }
    if (c0m_ok && c0) { c0_last = c0m; c0_ser = c0->serial; c0_gen = g_ser_gen; }
    if (out.want_flat) for (int i = 0; i < ntx; i++) if (tx[i].id == out.want_flat) { wd_flat_want(&txt[i]); break; }   // 核心点名：这张只因尺寸被判有细节、还没量过   // 顶点外推参数（S2A_WIDEN_PUSH_SLOT，回放层 bind_vbufs 绑；不外推的笔核心给 0）
    int any = 0, skipped = 0;
    for (int st = 0; st < 5; st++) any |= wd_emit_stage(st, gen, out.flags & S2A_WIDEN_OUT_NO_EMIT, &skipped);
    g_wd_rw_draws += any; g_wd_core++;
    if (skipped && wd_tr_on()) MLOG("S2Arm widen trace: frame %llu   ^ mode %d: %d rewritten slot(s) not used (GPU-side write pending in this submission), drawn with the game's values", (unsigned long long)g_wd_frame, g_wd_mode, skipped);
}
// 16:9 采样换算（离线 dmsh_build.py fs_uvx 给片元每次 2D 归一化采样套 x' = x·(1 + q.x) + q.y，q = s2a_uvx[贴图成员 id]）：按 16:9 几何画的笔（原样 / 界面原尺寸居中 / 16:9 页，g_wd_uvx）
//   采样到存储被放宽过的贴图（tex_widen：游戏给的宽 gw < 存储宽）时读它中间的 16:9 区：a = gw / 存储宽，q = (a − 1, (1 − a) / 2)；放宽内容按页面居中摆（1280 → 1564 的 142 = (1564 − 1280) / 2）。
//   其余贴图、其余画法全 0 = 原坐标逐位不变（10-26 马车8 主菜单：起页那笔整张采放宽图被压成 ×0.818，磨砂底板的模糊跟着错位）。持 g_rmu 调（encode_args 循环里）
//   纵向同理（10-28 B06，窄屏加高：存储高 > 游戏高 gh）：a_y = gh / 存储高，q.z = a_y − 1，q.w = (1 − a_y) / 2，读中间 [pad, pad+gh) 行；只加高不放宽的贴图不再跳过
//   （原先 L428 只比宽：4:3 时按 16:9 几何画的笔把 1440 行整张读进 1080 行 → ×0.75）。离线 fs_uvx 同步加 y 项，须重出直连库。
// 族 2 外扩采样要不要换钳边（nvn_mtl.m 绑采样器时调，持 g_rmu）：没放宽的贴图，除了「横向重复寻址 + 首尾无缝」的平铺图（按平铺延续），一律横向钳边——
//   重复寻址会把另一边绕进来（马力欧惊奇标题主视觉）；能走到外扩的贴图都量过边缘带平滑（WidenSession.OnlyExtensible），钳边就是边缘的平滑延续
static int wd_uvext_clamp(int tid, int wrap_s) {   // 持 g_rmu：只用不加锁的 tex_fast_rid（tex_mtl 会再拿 g_rmu，自锁）
    void *tv = NULL; tex_fast_rid(tid, &tv); __unsafe_unretained id<MTLTexture> mt = (__bridge id<MTLTexture>)tv;
    if (!mt || rs_cw(mt) > g_treg[tid].t.d.width) return 0;   // 放宽过的贴图自带两侧内容、不外扩
    int rep = wrap_s == 1 || wrap_s == 6;
    return !(rep && (wd_flat_flags(g_treg[tid].t.serial) & S2A_WIDEN_TEX_SEAMLESS_U));
}
static uint64_t uvx_fill(NvShader *sh, int nvn_stage) {
    static id<MTLBuffer> zero; static uint64_t zero_gpu; static float q[1024][4];
    if (!zero) { zero = [g_dev newBufferWithLength:sizeof q options:MTLResourceStorageModeShared]; res_add(zero); zero_gpu = zero.gpuAddress; }
    if ((!g_wd_uvx && g_wd_uvext <= 0) || nvn_stage != 1) return zero_gpu;
    int top = -1;
    for (int i = 0; i < sh->rf.nb; i++) {
        const nvn_rbind *b = &sh->rf.b[i]; if (b->kind != NVN_RB_TEX || b->aid >= 1024) continue;
        int tid = (int)(tex_slot_h(S.tex[1], S.img[1], b->reg) & 0xfffff); if (tid < 0 || tid >= g_ntreg || !g_treg[tid].ok) continue;
        void *tv = NULL; tex_fast_rid(tid, &tv); __unsafe_unretained id<MTLTexture> t = (__bridge id<MTLTexture>)tv; if (!t || t.textureType == MTLTextureTypeTextureBuffer) continue;
        NSUInteger lv = t.parentTexture ? t.parentRelativeLevel : 0, gw = MAX((NSUInteger)g_treg[tid].t.d.width >> lv, 1ul), gh = MAX((NSUInteger)g_treg[tid].t.d.height >> lv, 1ul);
        if (g_wd_uvext > 0) {   // 族 2 带纹理半透明叠加层推满：只给没放宽的贴图套 x' = 0.5 + (x − 0.5)·k（放宽过的贴图自带两侧内容，原坐标就对）
            if (rs_cw(t) > gw) continue;
            if (top < b->aid) { for (int k = top + 1; k <= b->aid; k++) memset(q[k], 0, sizeof q[k]); top = b->aid; }
            q[b->aid][0] = g_wd_uvext - 1.0f; q[b->aid][1] = (1.0f - g_wd_uvext) * 0.5f; q[b->aid][2] = q[b->aid][3] = 0; continue; }
        if (rs_cw(t) <= gw && rs_ch(t) <= gh) continue;   // canvas, as a / ay below: a widened storage the internal resolution scaled can be narrower than the game (k 1.22 × s 0.5)
        if (top < b->aid) { for (int k = top + 1; k <= b->aid; k++) memset(q[k], 0, sizeof q[k]); top = b->aid; }
        float a = rs_cw(t) > gw ? (float)gw / (float)rs_cw(t) : 1.0f, ay = rs_ch(t) > gh ? (float)gh / (float)rs_ch(t) : 1.0f;   // canvas: normalized, so the internal resolution does not change it   // 没放宽 / 没加高的一边 = 1 → 该轴 q 恰为 0
        q[b->aid][0] = a - 1.0f; q[b->aid][1] = (1.0f - a) * 0.5f; q[b->aid][2] = ay - 1.0f; q[b->aid][3] = (1.0f - ay) * 0.5f;
    }
    if (top < 0) return zero_gpu;
    g_wd_uvx_n++;
    id<MTLBuffer> ab; size_t o = arena_alloc(sizeof q[0] * (size_t)(top + 1), &ab); memcpy((uint8_t *)ab.contents + o, q, sizeof q[0] * (size_t)(top + 1));
    return ab.gpuAddress + o;
}
static void wd_present(const tex_t *t, int crop[4]) {   // 上屏：核心定下一帧的出图目标；裁剪按放宽换算（UI 模式不放宽，原样）
    atomic_store(&g_fit_pillar, 0);   // 满屏判据（nvn_mtl.m fit_*）的免判种类，同通用模式 nxgal_present_pillar：1 = 核心说这帧是 16:9 原比例页；2 = 核心说上屏贴图两侧是放宽内容画的（黑是游戏画的）；4 = 游戏自己出宽图（UI 模式）、这一帧全是 2D 合成（排版归游戏）
    if (wd_on() <= 0 || !t) return;
    pthread_mutex_lock(&g_wd_mu);
    wd_flat_flush();   // 本帧核心点名的贴图一起量（按内容判横向细节）
    if (t) wd_fb_present_tex(t->serial, t->d.width, t->d.height);
    wd_p2_present();   // 原比例回退：交上次两侧覆盖样本、起这一帧的采样
    s2a_widen_crop c = {0, 0, 0, 0, 16, 9};
    if (crop[2] || crop[3]) { c.left = crop[0]; c.right = crop[0] + crop[2]; c.top = crop[1]; c.bottom = crop[1] + crop[3]; }
    else { c.right = (int32_t)t->d.width; c.bottom = (int32_t)t->d.height; }
    s2a_widen_crop c_in = c; int pr = s2a_widen_present((uint32_t)t->serial, &c), pil = pr == 1 || pr == 2 || pr == 5 ? pr : g_wd == S2A_WIDEN_UI && !wd_s3d_has(t->serial) ? 4 : 0; g_p2_fb = pr == 5; atomic_store(&g_fit_pillar, pil);
    { static int last = -1, n; if (pil != last && n < 64) { n++; MLOG("[画] 满屏判据免判种类 %d → %d（第 %llu 次出图起，上屏贴图 ser=%llu %ux%u；4 = 游戏自己出宽图且上屏内容没有 3D 来历）", last, pil, (unsigned long long)g_wd_frame, (unsigned long long)t->serial, (unsigned)t->d.width, (unsigned)t->d.height); } last = pil; }
    if (wd_tr_on()) MLOG("S2Arm widen trace: frame %llu present tex %llu %ux%u crop [%d,%d) -> [%d,%d) rows [%d,%d)", (unsigned long long)g_wd_frame, (unsigned long long)t->serial, (unsigned)t->d.width, (unsigned)t->d.height, c_in.left, c_in.right, c.left, c.right, c.top, c.bottom);
    g_wd_frame++;
    if (crop[2] || crop[3] || pr == 5) { crop[0] = c.left; crop[2] = c.right - c.left; crop[1] = c.top; crop[3] = c.bottom - c.top; }   // 竖向：窄屏加高的出图按加高换算行（宽屏时核心原样返回）；回退（5）收了裁剪框的游戏没给也要交
    pthread_mutex_unlock(&g_wd_mu);
}
