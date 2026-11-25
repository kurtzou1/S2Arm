// GAL Metal 后端：第 7 块「出图」（IWindow）。语义照 Ryujinx Vulkan 后端 Window.Present（~/xbl/ref/ryujinx/src/Ryujinx.Graphics.Vulkan/Window.cs）。
//
// 两段：
//   ① 定格（Gpu 线程，主队列 g_gq，按命令顺序）：把游戏帧按 ImageCrop 裁切、按 FlipX / FlipY 翻转，逐像素（read，无滤波）画进一张
//      「定格贴图」（裁切尺寸、BGRA8Unorm、Shared 存储，alpha 置 1）。源贴图一律按恒等分量映射、非 sRGB 视图取原始字节
//      （同 Vulkan 端 BlitColor 的 SetTextureAndSamplerIdentitySwizzle；sRGB 视图取原始字节同 GetData）。
//      定格贴图 = 截图内容（与 Ryujinx 截图同口径：裁切后、未做窗口缩放；Ryujinx 把翻转交给保存方做，这里直接做好，C# 端交出时 flip 置 false），
//      抗锯齿开启时由它生成同尺寸的后处理贴图，后处理后再缩放上屏；原始截图始终取定格贴图。
//      游戏在 present 之后立刻往原贴图里画下一帧也不影响已定格的这一帧。
//   ② 上屏（出图线程，独立队列 g_pq）：取最新一张定格贴图，按宽高比 / 拉伸（Ryujinx 同一套整数算法）、缩放过滤（双线性 / 最近）
//      画进 CAMetalLayer 的 drawable 并呈现；信箱余下清黑。GPU 侧用共享事件等①那次提交做完再读。
//
// 节拍 / 线程：nextDrawable 在 drawable 用尽时会阻塞（显示同步下最长一个刷新周期，iOS 实测约 30 ms，取不到 1 秒超时返回空）。
//   Gpu 线程同时在执行游戏的全部 GPU 命令，堵在这里 = 整个游戏卡住，所以取 drawable 放到出图线程；两者之间是「信箱」：
//   出图线程总取最新的一张，没来得及上屏的旧帧直接被顶掉（计「顶掉」）。这正是 Vulkan 端 Switch / Custom 模式选的 Mailbox 语义
//   （Window.cs ChooseSwapPresentMode）；帧率节拍由 Ryujinx 的 SurfaceFlinger 按 VSyncMode 与交换间隔定（测试上限 S2A_FPS 也落在那里，
//   从生产端限住），后端不再限速；最短显示间隔 = 合成节拍（nxgal_window_set_min_interval，交换间隔变了由 SurfaceFlinger 调）。
//   VSyncMode：0 Switch / 2 Custom → 显示同步开（Mac displaySyncEnabled = YES，不撕裂）；1 Unbounded → Mac 关显示同步（同 Vulkan Immediate）。
//   iOS 无 displaySyncEnabled（恒同步）；30 帧档的口：nxgal_window_set_min_interval（每张至少显示多久，presentAfterMinimumDuration）。
// 没有图层（单测 / 无窗口跑）：①照做（计数、可截图），②不做。
#import "gal_internal.h"
#include <dlfcn.h>
#include "gal_pstat.h"
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
// PR7：同一策略抽象（评审稿 v3 §2.2 接缝「gal_present.m 只读」/ §4 PR7）：层态与出图模式经直连层的 nvn2_hdr_* 入口只读
//   （存储与层状态机在 graphics/nvn/gfx/nvn/nvn2.c——gal 不各自判，策略单源）；纯 C 不引平台头，gal 同样能包
#include "../nvn/gfx/nvn/nvn_hdr_policy.h"

// ---------- 定格贴图环 ----------
#define NSLOT 12   // 平时至多用 6 张（按需建，空槽不占内存）；逐帧亮度 / 存帧诊断另钉至多 LQN 张
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
typedef struct {
    id<MTLTexture> tex, post; int w, h, aa;
    uint64_t fence;              // 写它的那次提交之后在 g_gq 上发的 g_pev 值
    int presenting, reading;     // 出图线程在读（直到它的命令缓冲做完）/ 截图在读
    int stretched; float ax, ay; // 这一帧的 ImageCrop 宽高比参数
    uint64_t frame, t_sig;       // 出图时间表诊断（NXGAL_PRESENT_TRACE）：定格时的帧号、渲染线程发 g_pev 的时刻（CLOCK_UPTIME_RAW 纳秒）
} pslot;
static pslot g_slot[NSLOT];
static int g_latest = -1;        // 最近一次出图写的那张（截图 / render_to 取它）
static int g_pending = -1;       // 等出图线程取的那张（信箱）
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static _Atomic int g_session_stop;
static id<MTLSharedEvent> g_pev; static uint64_t g_pev_n;   // 定格完成事件（Gpu 线程在 g_gq 上发）
static id<MTLResidencySet> g_pset;                          // 定格贴图的驻留集（给出图队列用）

// 窗口设置（g_mu 护）
static CAMetalLayer *g_layer;
static int g_vsync;              // VSyncMode
static int g_filter;             // ScalingFilter：0 Bilinear 1 Nearest 2 Fsr 3 Area
static int g_antialiasing;       // AntiAliasing：None 0 / SMAA Low..Ultra 2..5（1 = 旧 Fxaa 值，按 SMAA Medium）；随帧冻结
static int g_req_w, g_req_h;     // SetSize（0 = 用图层自己的 drawableSize）
static float g_min_interval;     // 秒；0 = 不限

static _Atomic uint64_t g_n_present, g_n_shown, g_n_dropped, g_n_nodrawable;
static _Atomic uint64_t g_disp_us, g_n_disp_drop; static double g_disp_prev;   // 最近两次真正上屏的间隔（微秒）、交了却没上屏的次数（上屏回调线程写）

typedef struct { int x, y, w, h; } irect;   // 上屏目标矩形（dst_rect 出）

// ---------- 满屏判据（10-19 动森开局语言页：交换链 1920 宽、界面按 2348 排，画面偏移被切；出图尺寸又被写死 16:9）----------
// 两类各自记状态，由满屏变不满屏记一行【红】、恢复记一行（真机局 / 本机局按「【红】出图未满屏」判红）：
//   几何：上屏时画面没占满屏宽（信箱左右留边 > 2 像素），或拉伸档下画面与屏幕宽高比差 > 1%（被拉变形）；画面整幅纯黑时不报（开机黑帧屏上看不出留边，见 fit_geom）
//   内容：出图比 16:9 宽时，定格图 16:9 外侧黑带纯黑、带内侧有内容（游戏只画了中间 16:9）；每 30 次出图抽一次、连续 2 次才算
//         另：贴边暗带（某一遍没铺满放宽宽度，不是纯黑：10-22 八方2 镇上右侧近黑带星点），一侧整段明显暗于内侧、断口直、对侧不暗（见 dark_band）
//   例外（10-20 维护者 拍板）：游戏自己画死 16:9、没有更宽内容可补的页面（马车8 标题图）按原比例居中留黑边、不拉伸，判合格——
//   只认「两侧都是黑带（居中）且宽屏包装层标了本帧是 16:9 原比例页」（nxgal_present_pillar：整画布 16:9 图片且从没被 GPU 写过 = 纯 CPU 供图）；
//   GPU 画出来却没被宽屏扩到的 16:9 页包装层不标，照样报红（不把真该宽没宽的放过去）
//   另一种（10-21 马车8 比赛前读盘页，nxgal_present_pillar(2)）：两侧本帧被放宽内容画过（放宽后的场景转场压黑、读盘遮盖层只盖 16:9 画布），黑是游戏画的，同样不判
//   第三种（10-22 巫师3 读盘页，nxgal_present_pillar(3)）：上屏内容里没有任何读到改写镜头矩阵的绘制画的东西 = 没有可扩视野的内容（读盘原画是图集取块、界面层居中画），同样不判
//   第四种（10-22 塞尔达标题页，nxgal_present_pillar(4)）：游戏自己出宽图时这一帧全是 2D 合成，排版归游戏，同样不判
//   贴边暗带（dark_band）只在 0 / 2 时判：2 只说明两侧被放宽内容画过（黑是游戏画的），某一遍没铺满放宽宽度的暗带照样要抓（10-22 八方2 右带反证：旧版 2 也跳过，局内从没报过）
static _Atomic int g_pillar;
void nxgal_present_pillar(int32_t on) { atomic_store(&g_pillar, on >= 2 && on <= 4 ? on : on != 0); }
#define FJ_LOG GLOG
#include "fit_judge.h"
static fj_state g_fj;   // 判法本体在 fit_judge.h（与直连上屏共用）
static void fit_note(int kind, int bad, const char *why) { fj_note(&g_fj, kind, bad, why, atomic_load(&g_n_present)); }
static dispatch_queue_t fit_dq(void) {   // 满屏内容判据的串行队列（见 fit_judge）
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("s2a.fit_judge", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    return q; }
static void fit_wait(void) { dispatch_sync(fit_dq(), ^{}); }   // 等队列上在判的判完（单测读数前）
uint64_t gal_present_unfit(void) { fit_wait(); return atomic_load(&g_fj.n_unfit); }   // 判为没铺满 / 判为原比例页的出图次数（单测读）
uint64_t gal_present_pillar_n(void) { fit_wait(); return atomic_load(&g_fj.n_pillar); }
uint64_t gal_present_judged(void) { fit_wait(); return atomic_load(&g_fj.last_seq); }   // 内容判定做完的张数（单测等「钉住的图真判到了」用）
// 几何：上屏那一刻只记状态与原因、不立刻报红——整幅纯黑的帧（开机头几帧、黑场）屏上看不出左右留边，按 维护者 满屏定义不算没满屏
// （10-21 塞尔达 botw_1021220623_1：开机第 1 次出图 1920×1080 全黑报了几何红，第 2 次起恢复）。由内容判据钉住的定格图（GPU 做完后）确认：
// 钉住时与判时几何都没满屏、且这张图有内容（取 5 列，任一列不全黑）才报；恢复照常即时记。
// 几何没满屏时请求下一次出图就钉一张（g_geo_pin_req），不等每 30 次的钉点：几帧内报出（无头机 gate-host 离屏图层取不到画布、出图慢，单测只能出几次图）
static _Atomic int g_geo_bad, g_geo_pin_req; static int g_fit_geo; static char g_geo_why[160]; static pthread_mutex_t g_geo_mu = PTHREAD_MUTEX_INITIALIZER;
// 不在宽屏已验证名单的款（10-26 维护者：一律 16:9 原比例加黑边，runtime/src/widen.c widen_verified）：原生层屏幕宽按 1920，左右黑边是设计如此，几何不报。
//   原生层判定时设 S2A_WIDEN_NARROW=1（本层不链原生层符号：iOS 链接不收未定义的弱引用）
static int fit_narrow(void) { const char *e = getenv("S2A_WIDEN_NARROW"); return e && !strcmp(e, "1"); }
static void fit_geom(int sw, int sh, int iw, int ih, irect r, int stretched) {
    char why[160] = "";
    if (fit_narrow() && !stretched) { atomic_store(&g_geo_bad, 0); fit_note(0, 0, why); return; }
    if (r.w < sw - 2) snprintf(why, sizeof why, "画面 %dx%d 上屏只占 %d / %d 像素宽（左右留边）", iw, ih, r.w, sw);
    else if (stretched && fabs((double)iw * sh - (double)sw * ih) > 0.01 * (double)sw * ih) snprintf(why, sizeof why, "画面 %dx%d 拉伸到屏幕 %dx%d（宽高比 %.3f → %.3f，变形）", iw, ih, sw, sh, (double)iw / ih, (double)sw / sh);
    if (why[0]) { pthread_mutex_lock(&g_geo_mu); memcpy(g_geo_why, why, sizeof why); pthread_mutex_unlock(&g_geo_mu); atomic_store(&g_geo_bad, 1); atomic_store(&g_geo_pin_req, 1); }
    else { atomic_store(&g_geo_bad, 0); fit_note(0, 0, why); }
}
static void tex_col(void *t, int x, uint8_t *buf) { id<MTLTexture> q = (__bridge id<MTLTexture>)t; [q getBytes:buf bytesPerRow:4 fromRegion:MTLRegionMake2D(x, 0, 1, q.height) mipmapLevel:0]; }
static void tex_row(void *t, int y, uint8_t *px) { id<MTLTexture> q = (__bridge id<MTLTexture>)t; [q getBytes:px bytesPerRow:q.width * 4 fromRegion:MTLRegionMake2D(0, y, q.width, 1) mipmapLevel:0]; }
static fj_src tex_src(id<MTLTexture> t) { return (fj_src){(int)t.width, (int)t.height, (__bridge void *)t, tex_col, tex_row}; }

// ---------- PR7：HDR 上屏策略接缝（评审稿 v3 §4 PR7 / §2.2「gal_present.m 只读」/ §2.3 判定次序）----------
//   同一策略抽象（nvn_hdr_policy.h，直连层 PR3a/PR3b/PR4 已接）：gal 只读——层态经 nvn2_hdr_snapshot_probe、出图模式经
//   nvn2_hdr_present、每帧排空喂入经 nvn2_hdr_tick_frame（层状态机与 vi 门控在宿主 / 直连层，gal 不判）。
//   跨层可选符号按名字取（dlsym 一次，同下方 ap_direct 先例）：渲染器单测与 libnxgal.dylib 不链直连层，取不到就按
//   无 HDR = 现状行为；宿主里直连图形层与 gal 静态链进同一可执行文件（graphics/build.mk），符号恒在。
static struct {
    int (*hdr_switch)(void);
    int (*hdr_layer_sw)(void);
    int (*hdr_present)(float p[8], int src_pf, int dst_pt);
    void (*hdr_snapshot_probe)(hdr_snapshot *out);
    void (*hdr_tick_frame)(int sw, int frame_is_pq);
} g_hdr; static int g_hdr_look;
static int hdr_api(void) {
    if (!g_hdr_look) {
        g_hdr_look = 1;
        g_hdr.hdr_switch = (int (*)(void))dlsym(RTLD_DEFAULT, "nvn2_hdr_switch");
        g_hdr.hdr_layer_sw = (int (*)(void))dlsym(RTLD_DEFAULT, "nvn2_hdr_layer_sw");   // PR-B 终稿：层视角开关（排空喂入用）——与 hdr_switch 同源同宿主，整组同进同出
        g_hdr.hdr_present = (int (*)(float *, int, int))dlsym(RTLD_DEFAULT, "nvn2_hdr_present");
        g_hdr.hdr_snapshot_probe = (void (*)(hdr_snapshot *))dlsym(RTLD_DEFAULT, "nvn2_hdr_snapshot_probe");
        g_hdr.hdr_tick_frame = (void (*)(int, int))dlsym(RTLD_DEFAULT, "nvn2_hdr_tick_frame");
        if (!g_hdr.hdr_switch || !g_hdr.hdr_layer_sw || !g_hdr.hdr_present || !g_hdr.hdr_snapshot_probe || !g_hdr.hdr_tick_frame)
            g_hdr.hdr_present = NULL;   // 整组要不全有要不全无：直连层是一整体，部分缺失 = 不认识的宿主——按无 HDR
    }
    return g_hdr.hdr_present != NULL;
}

// PR7：层配置的两态物理属性（§2.3 S0/S1 行 + 注意事项①）。S0 的色彩空间必须显式重设（kCGColorSpaceSRGB）——
//   从 PQ 层切回的层保留 PQ 色彩空间，设 NULL 则无色彩匹配、字节直进屏幕原生 primaries（P3 屏过饱和）。
//   CAEDRMetadata 两态都不挂（默认关——PR8+ 经 S2A_HDR_META 实验）。tvOS SDK 没有 wantsEDR 属性（同 host_adapt.m 口径）。
static void hdr_layer_set_props(CAMetalLayer *l, int pq, CGColorSpaceRef cs_pq, CGColorSpaceRef cs_srgb) {
    l.pixelFormat = pq ? MTLPixelFormatRGB10A2Unorm : MTLPixelFormatBGRA8Unorm;
    l.colorspace = pq ? cs_pq : cs_srgb;   // S1 = BT.2100 PQ；S0 = 显式 sRGB tag（创建与切回同一份配置——注意事项①）
#if !TARGET_OS_TV
    l.wantsExtendedDynamicRangeContent = pq ? YES : NO;
#endif
}
// PR7：把快照层态（hdr_layer_config 同一份配置）应用到 gal 出图层。层持不持 PQ（快照 layer_pq，宿主 tick 状态机维护）
//   是唯一输入：off 缺省 / can 不行 / 排空未完成都落 S0（off ⇒ 从不进层——preattach / tick_can 都让位，缺省路径零变化）。
//   gal 侧 applied 簿记幂等（宿主侧 Mac 也对同一出图层按同一快照应用——同值重复写无扰）。iOS 层属性只在主线程改
//   （同下方 drawableSize 先例——出图线程直接设会开隐式 CATransaction 连带布局 UIKit 视图）：异步设、不等它——
//   这期间几帧按旧格式出（模式选路按层实际格式走，不崩）。
static _Atomic int g_hdr_layer_pq_applied;   // gal 侧已应用的层态：-1 未知 / 0 S0 / 1 S1（set_layer 创建点归位、摘层归 -1）
static void gal_hdr_layer_apply_to(CAMetalLayer *l, int pq) {
    int was = atomic_exchange(&g_hdr_layer_pq_applied, pq);
    if (was == pq) return;   // 已是这个层态（宿主侧同快照同配置的重复 apply 也由此幂等）
    static CGColorSpaceRef cs_pq, cs_srgb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cs_pq = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);   // BT.2100 PQ（§2.3 S1 行）
        cs_srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);         // 显式 sRGB tag（§2.3 注意事项①）
    });
    if (pq) GLOG("出图：层切 PQ（RGB10A2Unorm + BT.2100 PQ + wantsExtendedDynamicRangeContent；CAEDRMetadata 默认不挂，PR8+ 实验项）");
    else if (was >= 0) GLOG("出图：层切回 SDR（BGRA8Unorm + 显式 sRGB tag——从 PQ 层切回的层保留 PQ 色彩空间，必须显式重设；评审稿 §2.3 注意事项①）");
#if TARGET_OS_IPHONE
    CAMetalLayer *L = l; int p = pq;
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        hdr_layer_set_props(L, p, cs_pq, cs_srgb);
        [CATransaction commit];
    });
#else
    hdr_layer_set_props(l, pq, cs_pq, cs_srgb);
#endif
}
// PR7：层态跟随（出图线程，present_prep——层配置要在取 drawable 前落定）。层持 PQ 时不过节流（排空切回要几帧内跟上，
//   切回即显式重设 sRGB tag）；SDR 层（缺省路径）按事件档节流 250ms 探进不进层（同宿主 tick 频率——S2A_HDR=off 缺省
//   在层簿记上让位，layer_pq 恒 0，零写）。
static void gal_hdr_tick(CAMetalLayer *l) {
    if (!l || !hdr_api()) return;
    if (atomic_load_explicit(&g_hdr_layer_pq_applied, memory_order_relaxed) != 1) {
        static uint64_t last_ns;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (last_ns && now - last_ns < 250000000ull) return;
        last_ns = now;
    }
    hdr_snapshot s;
    g_hdr.hdr_snapshot_probe(&s);
    gal_hdr_layer_apply_to(l, s.layer_pq);
}
// PR7：创建点应用（nxgal_window_set_layer）——探快照层态再应用（off ⇒ layer_pq 恒 0 与已应用态一致：零写）
static void gal_hdr_layer_apply(CAMetalLayer *l) {
    if (!l || !hdr_api()) return;
    hdr_snapshot s;
    g_hdr.hdr_snapshot_probe(&s);
    gal_hdr_layer_apply_to(l, s.layer_pq);
}
// PR7：present_mode 变体选路（§2.4 模式矩阵 / §4 PR7；模式判定走 nvn2_hdr_present——与直连路径同一单源）。
//   gal 出图源恒为 SDR 定格贴图（cap_fs 固定 BGRA8Unorm——§2.3 判定次序 2 的「8 位窗」）⇒ 可达模式域 = {平凡直通,
//   mode 2（SDR→PQ 按纸白 100 nit 编码，层不因源切回）}。8 位目标（S0 缺省路径）一次格式比较直通——off 不变量、
//   快路径零锁。layer_path（出图层 present_one）：层格式即事实（PQ 层 + off 的排空过渡帧也按 mode 2 编码——SDR 内容
//   正确编进 PQ 层不糊画面；直连路径 nvn2_hdr_present 同判）；render_to（诊断）：off 缺省直通（与改前逐字节一致——
//   读开关，诊断路径事件档频率）。
static int present_hdr_uv(float p[8], MTLPixelFormat dst_pf, int layer_path) {
    for (int i = 0; i < 8; i++) p[i] = 0.0f;
    if (dst_pf != MTLPixelFormatRGB10A2Unorm) return HDR_PV_TRIVIAL;
    if (!hdr_api()) return HDR_PV_TRIVIAL;
    if (!layer_path && g_hdr.hdr_switch() == HDR_OFF) return HDR_PV_TRIVIAL;
    return g_hdr.hdr_present(p, HDR_PF_SDR8, HDR_PT_PQ10);
}

// ---------- 着色器 ----------
// PR-A（#625 第二阶段）：present_itm 的 MSL 文本——S4「SDR 转 HDR」扩张曲线（ITU-R BT.2446-1 §4.2〔Method A〕逆色调
//   映射通用解析式，设计稿 §2.2 逐段转写；手写 MSL——公式源自 ITU 免费标准文本，未复制 gamescope/libplacebo 任何代码
//   文本，登记 THIRD_PARTY_LICENSES.md）。k_present_msl（pr_fs_hdr 的 fs 源）与单测独立判据
//   （graphics/metal/tests/t_present_hdr.m ⑦ 的探针着色器，经独立导出的 k_present_itm_msl 取同一份文本）共用——
//   与直连副本 nvn_mtl.m 同式（「数学逐条对齐……两处同改」惯例，K_PRESENT_ITM_MSL 同款宏化）。
//   不用 Table 4 快速路径：target 由设置+净空推导，非 100→1000 设计点。
//   勘误登记（上游评审 PR #2080 第 1 轮自 THIRD_PARTY_LICENSES.md 挪入——本仓无单测佐证的技术勘误不进对外出处声明）：
//   gamescope 的 Table 4 快速路径常数 c2 误写 1.2328（正确 1.2528——ITU-R BT.2446-1 Table 4〔第 12 页〕官方原文；
//   libplacebo 的 Table 4 形逆同用 1.2528，两处独立源互证）。本仓用通用解析式、不走 Table 4，不受该笔误影响——
//   复核者若拿 gamescope 的 Table 4 常数对拍会踩坑，登记于此。
//   入 n：线性光（BT.2020 基色，1.0 = sdr_nits）；出：线性光（1.0 = target_nits——调用侧乘 target/纸白 喂 present_linear_to_pq）。
#define K_GAL_ITM_MSL \
"static inline float3 present_itm(float3 n, float sdr_nits, float target_nits) {\n" \
"  const float3 k2020 = float3(0.262698338956556, 0.678008765772817, 0.0592928952706273);   // BT.2020 亮度系数（gamescope 同值）\n" \
"  const float kR = 1.47460332208689, kB = 1.88141420945875;   // 2 − 2·k2020.r / 2 − 2·k2020.b\n" \
"  n = pow(max(n, float3(0.0)), float3(1.0 / 2.4));   // γ 压缩（线性 → 码值域）\n" \
"  float y = dot(n, k2020);   // Y'tmo（BT.2020 亮度变换）\n" \
"  float cb = (n.b - y) / kB, cr = (n.r - y) / kR;   // C'b / C'r\n" \
"  float y_sdr = y + max(0.1 * cr, 0.0);   // 亮度调整（逆）：Y'sdr = Y'tmo + max(0.1·C'r, 0)\n" \
"  float p_sdr = 1.0 + 32.0 * pow(sdr_nits / 10000.0, 1.0 / 2.4);\n" \
"  float y_c = log(y_sdr * (p_sdr - 1.0) + 1.0) / log(p_sdr);   // psdr 归一\n" \
"  float y_p0 = y_c / 1.0770;   // 段 1 逆式（前向 Y'c = 1.0770·Y'p）\n" \
"  float y_p1 = (-2.7811 + sqrt(4.83307641 - 4.604 * y_c)) / -2.302;   // 段 2 逆式（前向二次段的代数逆）\n" \
"  float y_p2 = (y_c - 0.5) / 0.5;   // 段 3 逆式（前向 Y'c = 0.5·Y'p + 0.5）\n" \
"  float y_p;\n" \
"  if (y_p0 <= 0.7399) y_p = y_p0;   // 段界 0.7399 / 0.9909（libplacebo 同值；标准自身段 1/2 交界有不连续 ~6e-4——对拍期望按同式复算，不假设严格单调）\n" \
"  else if (y_p1 > 0.7399 && y_p1 < 0.9909) y_p = y_p1;\n" \
"  else if (y_p2 >= 0.9909) y_p = y_p2;\n" \
"  else y_p = y_p1;   // 段界浮点兜底（gamescope 同款：误差 <0.001）\n" \
"  float p_hdr = 1.0 + 32.0 * pow(target_nits / 10000.0, 1.0 / 2.4);\n" \
"  float y_ = (pow(p_hdr, y_p) - 1.0) / (p_hdr - 1.0);   // phdr 归一（Y'hdr）\n" \
"  float col_scale = y_ > 0.0 ? y_sdr / (1.1 * y_) : 1.0;   // 保色调标量（gamescope else 0 会得 0/0=NaN——恰黑本就该出黑，兜底 1.0 后黑→黑精确）\n" \
"  float3 o;\n" \
"  o.b = cb * kB / col_scale + y_;   // 色度按 col_scale 重建（逆方向除）\n" \
"  o.r = cr * kR / col_scale + y_;\n" \
"  o.g = (y_ - (k2020.r * o.r + k2020.b * o.b)) / k2020.g;   // 亮度逆推 G'（白仍是白）\n" \
"  return pow(clamp(o, float3(0.0), float3(1.0)), float3(2.4));   // saturate 后回线性\n" \
"}\n"
NSString *const k_present_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VO { float4 p [[position]]; float2 uv; };\n"
"vertex VO pr_vs(uint vid [[vertex_id]]) {\n"
"  float2 uv = float2((vid << 1) & 2, vid & 2); VO o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
// 定格：按像素坐标反查源像素（裁切起点 + 翻转），钳在贴图内，read 不滤波；alpha 置 1（同 Vulkan 端出图 clearAlpha）
"struct CP { int2 org; int2 size; int2 flip; int2 tmax; };\n"
"fragment float4 cap_fs(VO in [[stage_in]], texture2d<float> t [[texture(0)]], constant CP &p [[buffer(0)]]) {\n"
"  int2 q = int2(in.p.xy);\n"
"  int2 s = int2(p.flip.x ? p.size.x - 1 - q.x : q.x, p.flip.y ? p.size.y - 1 - q.y : q.y) + p.org;\n"
"  s = clamp(s, int2(0), p.tmax); return float4(t.read(uint2(s)).rgb, 1.0); }\n"
// 上屏：视口 = 目标矩形，按采样器（双线性 / 最近，边缘钳位）缩放
"fragment float4 pr_fs(VO in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
"  return float4(t.sample(s, in.uv).rgb, 1.0); }\n"
// PR7：present_mode 变体（评审稿 v3 §2.4 / §4 PR7）——数学与直连路径 nvn_mtl.m fs 的六分支逐条对齐
//   （ST 2084 EOTF/逆 EOTF、BT.709↔BT.2020 矩阵、present_shoulder 有理肩部；两处同改）。参数经 UV 常量缓冲
//   p[0..7]（nvn_hdr_policy.h hdr_present_fill 同一布局，mode/xf 两组并一行）：p[0]=模式号 / p[1]=纸白（nit）/
//   p[2]=knee / p[3]=target；p[4]=源峰 / p[5]=膝点码值 / p[6]=SDR gamma。gal 可达模式域 = {0 平凡直通（不走本
//   变体——present_one 直接走 pr_fs，逐字节同改前）, 2}；其余分支与直连路径同码备用（gal 出图源恒 SDR 定格，
//   未来源域扩展时数学已在位）。采样同 pr_fs（裁切在 cap_fs 已做，这里整幅）；gal 出图层不透明——alpha 恒 1。
"struct HP { float4 mode; float4 xf; };\n"
// 线性 BT.709 与 BT.2020（ITU-R BT.2087；每行和 = 1，白仍是白。Metal 的 float3x3 按列取参——这里的列即矩阵的列）
"constant float3x3 kRec709To2020 = float3x3(float3(0.627404, 0.069097, 0.016391), float3(0.329283, 0.919540, 0.088013), float3(0.043313, 0.011362, 0.895595));\n"
"constant float3x3 kRec2020To709 = float3x3(float3(1.660491, -0.124550, -0.018151), float3(-0.587641, 1.132900, -0.100579), float3(-0.072850, -0.008349, 1.118730));\n"
// SDR 图像码值 ↔ 线性光（BT.709 基色、D65）：gamma g 的纯幂曲线（g > 0），g = 0 时分段 sRGB 曲线（会抬暗部：码 16 = 2.2 的 2.3 倍光）
"static inline float3 present_sdr_to_linear(float3 c, float g) {\n"
"    if (g > 0.0) return pow(max(c, float3(0.0)), float3(g));\n"
"    float3 lo = c * (1.0 / 12.92);\n"
"    float3 hi = pow((c + 0.055) * (1.0 / 1.055), float3(2.4));\n"
"    return select(hi, lo, c <= 0.04045);\n"
"}\n"
"static inline float3 present_linear_to_sdr(float3 l, float g) {\n"
"    if (g > 0.0) return pow(max(l, float3(0.0)), float3(1.0 / g));\n"
"    float3 lo = l * 12.92;\n"
"    float3 hi = 1.055 * pow(l, float3(1.0 / 2.4)) - 0.055;\n"
"    return select(hi, lo, l <= 0.0031308);\n"
"}\n"
// ST 2084 EOTF：码值 → 绝对亮度（10000 nit = 1.0）再除纸白（1.0 = 屏的 SDR 白，其上是净空）
"static inline float3 present_pq_to_linear(float3 e, float paper) {\n"
"    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;\n"
"    float3 ep = pow(max(e, float3(0.0)), float3(1.0 / m2));\n"
"    float3 num = max(ep - c1, float3(0.0));\n"
"    float3 den = max(c2 - c3 * ep, float3(1e-6));\n"
"    return 10000.0 * pow(num / den, float3(1.0 / m1)) / paper;\n"
"}\n"
// ST 2084 逆 EOTF：1.0 = 纸白的线性光 → 码值。pow 的底恒正（快速数学下安全）
"static inline float3 present_linear_to_pq(float3 l, float paper) {\n"
"    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;\n"
"    float3 ym = pow(max(l * (paper / 10000.0), float3(1e-30)), float3(m1));\n"
"    return pow((c1 + c2 * ym) / (1.0 + c3 * ym), float3(m2));\n"
"}\n"
// 有理肩部：膝点 k 以上、最亮通道 m 向 target t 压缩，各通道同缩放保色相（线性光、目标基色、无负值）。
// 膝点处斜率 1、单调升、源峰 s 精确落 t（s ≤ t 时只在 t 截断）；每像素一次除法
"static inline float3 present_shoulder(float3 n, float k, float t, float s) {\n"
"  float m = max(max(n.r, n.g), n.b);\n"
"  if (!(m > k)) return n;\n"
"  float a = t - k, x = m - k, f = min(k + x / (1.0 + x * (1.0 / a - 1.0 / max(s - k, a))), t);\n"
"  return n * (f / m);\n"
"}\n"
// PR-A（#625 第二阶段）：S4「SDR 转 HDR」扩张曲线 present_itm 的 MSL 文本（K_GAL_ITM_MSL——上方定义；与直连副本
//   nvn_mtl.m 同式〔「数学逐条对齐……两处同改」惯例、勘误与登记注释同在宏定义处〕，独立导出 k_present_itm_msl）
K_GAL_ITM_MSL
"fragment float4 pr_fs_hdr(VO in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant HP &p [[buffer(0)]]) {\n"
"    float4 v = float4(t.sample(s, in.uv).rgb, 1.0);\n"
"    if (p.mode.x > 3.5) {   // 4：PQ 层无 metadata——游戏可能画过屏当前净空的，膝点码值（xf.y）以上压进屏峰（mode.w）\n"
"        if (max(max(v.r, v.g), v.b) > p.xf.y) v.rgb = present_linear_to_pq(present_shoulder(present_pq_to_linear(v.rgb, 1.0), p.mode.z, p.mode.w, p.xf.x), 1.0);\n"
"    } else if (p.mode.x > 2.5) {   // 3：float 源（线性 BT.709）按纸白编成 HDR10；负值在矩阵后才截断，scRGB 的广色域保住其 BT.2020 值\n"
"        v = float4(present_linear_to_pq(max(kRec709To2020 * clamp(v.rgb, -65504.0, 65504.0), 0.0), p.mode.y), 1.0);\n"
// PR-A（#625 第二阶段）：mode 2 参数化扩展——S4「SDR 转 HDR」扩张（BT.2446A 逆映射 present_itm；矩阵提前到曲线之前——
//   BT.2446A 的 Y'CbCr 变换按 BT.2020 设计，扩张必须在 709→2020 矩阵之后）。p.mode.z = sdr nits（p[2]）、
//   p.mode.w = target nits（p[3]）——双零 = 不扩张（off 判定，nvn_hdr_policy.h hdr_present_fill 的 engage 门；
//   HP 槽位与直连 Crop 一一对应）。engage 守卫 p.mode.z > 0.0 && p.mode.w > p.mode.z——严格大于：target ≤ sdr 会
//   压暗/重塑（设计稿 §2.2 实测），绝不进曲线。未 engage 路径与改前同一式、同一输入、同一求值次序（仅中间量命名）——
//   逐字节一致（off 不变量；gal 的 mode 0 平凡直通不经本变体，off 路径零触碰）。
"    } else if (p.mode.x > 1.5) {\n"
"      float3 lin2 = kRec709To2020 * present_sdr_to_linear(v.rgb, p.xf.z);\n"
"      if (p.mode.z > 0.0 && p.mode.w > p.mode.z)\n"
"        lin2 = present_itm(lin2, p.mode.z, p.mode.w) * (p.mode.w / p.mode.y);\n"   // 扩张：1.0=sdr nits 入 → 1.0=target nits 出 → 纸白相对域
"      v = float4(present_linear_to_pq(lin2, p.mode.y), 1.0);\n"
"    }\n"
"    else if (p.mode.x > 0.5) v = float4(present_linear_to_sdr(saturate(present_shoulder(max(kRec2020To709 * present_pq_to_linear(v.rgb, p.mode.y), 0.0), p.mode.z, p.mode.w, p.xf.x)), p.xf.z), 1.0);   // 1：先矩阵后肩部——BT.709 后压缩，保高光层次与色相\n"
"    return v; }\n";
// PR-A（#625 第二阶段）：present_itm 文本独立导出（与 k_present_msl 拼进 pr_fs_hdr 的同一份——上方 K_GAL_ITM_MSL）。
//   单测独立判据（PR #2080 评审第 1 轮，graphics/metal/tests/t_present_hdr.m ⑦）经 dlsym 按名取它编探针着色器上 GPU
//   直测 present_itm 本体（RGBA32F 线性直出，不经 PQ 10 位量化）——探针测的就是生产文本，不是手抄副本。
NSString *const k_present_itm_msl = @K_GAL_ITM_MSL;
typedef struct { int32_t org[2], size[2], flip[2], tmax[2]; } cap_params;

static id<MTLLibrary> g_plib;
static id<MTLRenderPipelineState> g_cap_pso;
static struct { MTLPixelFormat f; id<MTLRenderPipelineState> p; } g_pr_pso[4]; static int g_npr;   // 上屏管线按目标格式（g_mu 护：出图线程读）
static struct { MTLPixelFormat f; id<MTLRenderPipelineState> p; } g_prh_pso[4]; static int g_nprh;   // PR7：present_mode 变体管线按目标格式（同款表；g_mu 护）
static id g_pth_t, g_rth_t;   // PR7：变体参数表（buffer 0 = p[8] UV 常量缓冲、texture 0、sampler 0；出图线程 / Gpu 线程 render_to 各一）。类型记号不落本文件（MTL4 棘轮只许减：Metal 4 专有类型经 gal_be.h / 型擦除 id，同 gal_aa.m 参数表先例）
static id<MTLSamplerState> g_smp_lin, g_smp_near;
static id<MTL4ArgumentTable> g_cap_t, g_rt_t;   // Gpu 线程用：定格 / render_to

static MTL4LibraryFunctionDescriptor *pfn(NSString *name) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = g_plib; f.name = name; return f; }
static id<MTLRenderPipelineState> mk_pso(NSString *fs, MTLPixelFormat fmt) {
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    d.vertexFunctionDescriptor = pfn(@"pr_vs"); d.fragmentFunctionDescriptor = pfn(fs);
    d.rasterSampleCount = 1; d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    d.colorAttachments[0].pixelFormat = fmt;
    NSError *e = nil;
    id<MTLRenderPipelineState> p = gal_new_render_pso(d, &e);
    if (!p) GLOG("【红】出图管线（%s，格式 %lu）编译失败：%s", fs.UTF8String, (unsigned long)fmt, e.localizedDescription.UTF8String);
    return p;
}
static id<MTL4ArgumentTable> mk_tab(void) {
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1; ad.maxTextureBindCount = 1; ad.maxSamplerStateBindCount = 1;
    NSError *e = nil; id<MTL4ArgumentTable> t = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
    if (!t) GLOG("【红】出图参数表建不出：%s", e.localizedDescription.UTF8String);
    return t;
}
static id<MTLSamplerState> mk_smp(MTLSamplerMinMagFilter f) {
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.minFilter = d.magFilter = f; d.sAddressMode = d.tAddressMode = MTLSamplerAddressModeClampToEdge; d.supportArgumentBuffers = YES;
    return [g_gdev newSamplerStateWithDescriptor:d];
}
// Gpu 线程上调（或 set_layer 前已初始化过）
static int p_init(void) {
    if (g_cap_pso) return 1;
    if (!g_gdev) { GRED_ONCE("出图：nxgal_init 之前调用"); return 0; }
    NSError *e = nil;
    g_plib = gal_helper_lib(GH_PRESENT, &e);
    if (!g_plib) { GLOG("【红】出图着色器编译失败：%s", e.localizedDescription.UTF8String); return 0; }
    g_smp_lin = mk_smp(MTLSamplerMinMagFilterLinear); g_smp_near = mk_smp(MTLSamplerMinMagFilterNearest);
    g_cap_t = mk_tab(); g_rt_t = mk_tab();
    g_pth_t = mk_tab(); g_rth_t = mk_tab();   // PR7：变体参数表（建不出在用点各自回退平凡直通并已记红，不拖垮 SDR 现状路径）
    g_pev = [g_gdev newSharedEvent];
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; rd.initialCapacity = NSLOT;
    g_pset = [g_gdev newResidencySetWithDescriptor:rd error:&e];
    g_cap_pso = mk_pso(@"cap_fs", MTLPixelFormatBGRA8Unorm);
    return g_cap_pso && g_cap_t && g_rt_t && g_pev && g_pset && g_smp_lin && g_smp_near;
}
// 内部管线预建（nxgal_warm_internal 调）：定格（p_init）+ 上屏 BGRA8Unorm——10-20 M2 首局要求现建 0，原本首帧现编 MSL + 建管线
static id<MTLRenderPipelineState> pr_pso_get(MTLPixelFormat f, int compile);
void gal_warm_present(void) { if (p_init()) pr_pso_get(MTLPixelFormatBGRA8Unorm, 1); }
// 上屏管线：Gpu 线程上编（出图线程只查表）
static id<MTLRenderPipelineState> pr_pso_get(MTLPixelFormat f, int compile) {
    pthread_mutex_lock(&g_mu);
    id<MTLRenderPipelineState> p = nil;
    for (int i = 0; i < g_npr; i++) if (g_pr_pso[i].f == f) { p = g_pr_pso[i].p; break; }
    pthread_mutex_unlock(&g_mu);
    if (p || !compile) return p;
    if (g_npr >= 4) { GRED_ONCE("出图：上屏目标格式超过 4 种"); return nil; }
    p = mk_pso(@"pr_fs", f); if (!p) return nil;
    pthread_mutex_lock(&g_mu); g_pr_pso[g_npr].f = f; g_pr_pso[g_npr].p = p; g_npr++; pthread_mutex_unlock(&g_mu);
    return p;
}
// PR7：变体管线（pr_fs_hdr）查表 / 现编——同 pr_pso_get 的表形态（Gpu 线程编，出图线程只查表）
static id<MTLRenderPipelineState> pr_hdr_pso_get(MTLPixelFormat f, int compile) {
    pthread_mutex_lock(&g_mu);
    id<MTLRenderPipelineState> p = nil;
    for (int i = 0; i < g_nprh; i++) if (g_prh_pso[i].f == f) { p = g_prh_pso[i].p; break; }
    pthread_mutex_unlock(&g_mu);
    if (p || !compile) return p;
    if (g_nprh >= 4) { GRED_ONCE("出图：变体上屏目标格式超过 4 种"); return nil; }
    p = mk_pso(@"pr_fs_hdr", f); if (!p) return nil;
    pthread_mutex_lock(&g_mu); g_prh_pso[g_nprh].f = f; g_prh_pso[g_nprh].p = p; g_nprh++; pthread_mutex_unlock(&g_mu);
    return p;
}

// ---------- 宽高比：Ryujinx Window.Present 同一套（float 运算、int 截断、整数除 2 居中）----------
static irect dst_rect(int W, int H, int stretched, float ax, float ay) {
    if (!(ax > 0) || !(ay > 0)) stretched = 1;   // 宽高比缺失（0 / 非数）按拉伸，免得除零
    float rx = stretched ? 1.0f : fminf(1.0f, H * ax / (W * ay));
    float ry = stretched ? 1.0f : fminf(1.0f, W * ay / (H * ax));
    int dw = (int)(W * rx), dh = (int)(H * ry);
    // 截断后离满屏不足 1 像素（比例只差小数位）就铺满：不到一像素的信箱看不出，留下的那一列 / 行黑却看得出
    // （10-21 真机 2868×1320 屏出图 1564×720：W·rx = 2867.35 → 2867，右侧 1 列黑，宽屏界面线截屏量出）
    if (W - W * rx < 1.0f) dw = W;
    if (H - H * ry < 1.0f) dh = H;
    return (irect){(W - dw) / 2, (H - dh) / 2, dw, dh};
}
// 上屏编码（drawable 与 render_to 共用）：目标 W×H，信箱外清黑
static MTL4RenderPassDescriptor *pr_pass(id<MTLTexture> dst, irect r) {
    MTL4RenderPassDescriptor *d = [MTL4RenderPassDescriptor new];
    d.colorAttachments[0].texture = dst; d.colorAttachments[0].storeAction = MTLStoreActionStore;
    int full = r.x == 0 && r.y == 0 && r.w == (int)dst.width && r.h == (int)dst.height;
    d.colorAttachments[0].loadAction = full ? MTLLoadActionDontCare : MTLLoadActionClear;
    d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    d.renderTargetWidth = dst.width; d.renderTargetHeight = dst.height;
    return d;
}
static void pr_encode(id<MTL4RenderCommandEncoder> e, id<MTL4ArgumentTable> t, id<MTLRenderPipelineState> p, id<MTLTexture> src, irect r, int filter) {
    if (r.w <= 0 || r.h <= 0) return;
    [t setTexture:src.gpuResourceID atIndex:0];
    [t setSamplerState:(filter == 1 ? g_smp_near : g_smp_lin).gpuResourceID atIndex:0];
    [e setArgumentTable:t atStages:MTLRenderStageFragment];
    [e setRenderPipelineState:p];
    [e setViewport:(MTLViewport){r.x, r.y, r.w, r.h, 0, 1}];
    [e setScissorRect:(MTLScissorRect){(NSUInteger)r.x, (NSUInteger)r.y, (NSUInteger)r.w, (NSUInteger)r.h}];
    [e setCullMode:MTLCullModeNone];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}
// PR7：变体上屏编码——pr_encode 同款几何 / 采样 + UV 常量缓冲 p[8]（buffer 0 = 参数地址，模式 / 纸白 / 膝点 / 源峰 / gamma）。
//   Metal 4 专有类型不落本文件（MTL4 棘轮只许减）：编码器 / 参数表 / 绑定经 gal_be.h 的入口（参数绑定一行，同 gal_aa.m aa_pass 先例）。
static void pr_encode_hdr(id e, id t, id<MTLRenderPipelineState> p, id<MTLTexture> src, irect r, int filter, uint64_t p_gpu) {
    if (r.w <= 0 || r.h <= 0) return;
    gal_be_table_texture(t, src, 0);
    gal_be_table_sampler(t, filter == 1 ? g_smp_near : g_smp_lin, 0);
    gal_be_table_address(t, p_gpu, 0);
    [e setArgumentTable:t atStages:MTLRenderStageFragment];
    [e setRenderPipelineState:p];
    [e setViewport:(MTLViewport){r.x, r.y, r.w, r.h, 0, 1}];
    [e setScissorRect:(MTLScissorRect){(NSUInteger)r.x, (NSUInteger)r.y, (NSUInteger)r.w, (NSUInteger)r.h}];
    [e setCullMode:MTLCullModeNone];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

// ---------- 出图线程 ----------
static id<MTL4CommandQueue> g_pq;
static id<MTLSharedEvent> g_pdone; static uint64_t g_pdone_n;   // 出图命令缓冲完成事件（分配器复用前等）
#define NPALLOC 2
static id<MTL4CommandAllocator> g_palloc[NPALLOC]; static uint64_t g_palloc_fence[NPALLOC];
static id<MTL4ArgumentTable> g_pt;
// PR7：变体参数缓冲按分配器槽轮转（出图线程独占）——同槽上一用家在下面的 ev_wait（g_pdone）里已确认完成，写无竞态
static id<MTLBuffer> g_pth_buf[NPALLOC];
static uint64_t gal_hdr_pth_fill(int a, const float p[8]) {
    if (!g_pth_buf[a]) {
        g_pth_buf[a] = [g_gdev newBufferWithLength:32 options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        if (!g_pth_buf[a]) { GRED_ONCE("出图：HDR 变体参数缓冲建不出"); return 0; }
    }
    memcpy(g_pth_buf[a].contents, p, 32);
    return g_pth_buf[a].gpuAddress;
}
static void ev_wait(id<MTLSharedEvent> ev, uint64_t v, const char *what) {
    // GPU 工作事件（定格完成，主队列发）3 秒不到即判卡死退出（gal_core.m）；上屏分配器等的是出图队列交给显示，受显示节拍 / 前后台影响（iOS 进后台本就拿不到画布），
    // 不算 GPU 卡死，照旧只记红继续等
    if (ev == g_pev) { if (ev.signaledValue < v && ![ev waitUntilSignaledValue:v timeoutMS:3000]) gal_gpu_stall_exit(ev, what, v, ev.signaledValue); return; }
    while (ev.signaledValue < v && ![ev waitUntilSignaledValue:v timeoutMS:10000])
        GLOG("【红】出图：等%s %llu 超过 10 秒（已到 %llu），继续等", what, (unsigned long long)v, (unsigned long long)ev.signaledValue);
}
int gal_present_drain(int timeout_ms) { uint64_t v = g_pdone_n; return !g_pdone || g_pdone.signaledValue >= v || [g_pdone waitUntilSignaledValue:v timeoutMS:timeout_ms]; }
static void slot_unpresent(int s) { pthread_mutex_lock(&g_mu); g_slot[s].presenting--; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu); }

#if TARGET_OS_IPHONE
#endif
static CAMetalLayer *g_applied; static int g_applied_vsync = -1; static CGSize g_applied_size;   // 出图线程独占
static int present_prep(CAMetalLayer *layer, int s, int vsync, int rw, int rh) {
    gal_hdr_tick(layer);   // PR7：层态跟随（S2A_HDR 非 off 时进层 / 排空切回 + sRGB 重设，§4 PR7）——层配置要在取 drawable 前落定
    CAMetalLayer *applied = g_applied; int applied_vsync = g_applied_vsync; CGSize applied_size = g_applied_size;
    id<MTLRenderPipelineState> pso = pr_pso_get(layer.pixelFormat, 0);
    if (!pso) { GRED_ONCE("出图线程：图层格式 %lu 没有上屏管线", (unsigned long)layer.pixelFormat); slot_unpresent(s); return 0; }
    if (layer != applied) {
        if (applied) [g_pq removeResidencySet:applied.residencySet];
        [g_pq addResidencySet:layer.residencySet]; applied = layer; applied_vsync = -1; applied_size = (CGSize){0, 0};
    }
#if TARGET_OS_OSX
    if (vsync != applied_vsync) { layer.displaySyncEnabled = vsync != 1; applied_vsync = vsync; }
#else
    (void)vsync; (void)applied_vsync;
#endif
    if (rw > 0 && rh > 0 && (applied_size.width != rw || applied_size.height != rh)) {
        applied_size = CGSizeMake(rw, rh);
#if TARGET_OS_IPHONE
        // iOS：图层属性只在主线程改。出图线程直接设 drawableSize 会在本线程开隐式 CATransaction，提交时连带布局 UIKit 视图——
        //   iPadOS 27 判「后台线程改布局引擎」抛 NSInternalInconsistencyException 退出（D-HHEG，第一次出图碰上主线程有待布局时）。
        //   交主线程异步设（不等它：主线程可能正等出图），这期间的几帧按旧可画尺寸出（上屏按画布实际尺寸算区域，见 present_one）
        CAMetalLayer *L = layer; CGSize sz = applied_size;
        dispatch_async(dispatch_get_main_queue(), ^{ [CATransaction begin]; [CATransaction setDisableActions:YES]; L.drawableSize = sz; [CATransaction commit]; });
#else
        layer.drawableSize = applied_size;
#endif
    }
    g_applied = applied; g_applied_vsync = applied_vsync; g_applied_size = applied_size;
    return 1;
}
static void present_one(CAMetalLayer *layer, id<CAMetalDrawable> dr, int s, pslot sl, int filter, float mi) {
    id<MTLRenderPipelineState> pso = pr_pso_get(layer.pixelFormat, 0);
    id<MTLTexture> dt = dr.texture;
    irect r = dst_rect((int)dt.width, (int)dt.height, sl.stretched, sl.ax, sl.ay);
    fit_geom((int)dt.width, (int)dt.height, sl.w, sl.h, r, sl.stretched);

    // 定格那次提交做完再出图：在 CPU 上等，不在 GPU 上等（10-22 帧率能耗线，4 秒冻结根因）。
    // 旧做法 [g_pq waitForEvent:g_pev] 让出图命令缓冲带着跨队列等待先进 GPU 渲染通道，主队列这一帧的渲染编码器（要做完才发这个事件）
    // 排在同一硬件渲染通道里它的后面——循环等待，直到驱动约 4 秒超时打破（xctrace mhrise_1022075608_2：两次冻结里渲染通道整 4 秒空闲、
    // 计算通道照常；空窗后第一个执行的就是出图命令缓冲，主队列紧跟着恢复）。NXGAL_PRESENT_GPUWAIT=1 退回旧做法（A/B 用）。
    // 出图线程不判卡死（真卡死由渲染线程的栅栏看门狗判），久等只记红继续等
    static int gpuwait = -1; if (gpuwait < 0) { const char *v = getenv("NXGAL_PRESENT_GPUWAIT"); gpuwait = v && *v == '1'; }
    // 出图时间表（诊断 NXGAL_PRESENT_TRACE=1，缺省关；10-22 原生层线对齐 nvhost 同步点用）：每次出图在上屏回调里打一行「[出图表]」，
    // 时刻全是 CLOCK_UPTIME_RAW 纳秒（= mach_absolute_time 基准，presentedTime 同基准换算）
    static int trace = -1; if (trace < 0) { const char *v = getenv("NXGAL_PRESENT_TRACE"); trace = v && *v == '1'; }
    uint64_t t_w0 = trace ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
    if (!gpuwait) while (g_pev.signaledValue < sl.fence && ![g_pev waitUntilSignaledValue:sl.fence timeoutMS:10000])
        GLOG("【红】出图：等定格完成 %llu 超过 10 秒（已到 %llu），继续等", (unsigned long long)sl.fence, (unsigned long long)g_pev.signaledValue);
    uint64_t t_w1 = trace ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0, sv = trace ? g_pev.signaledValue : 0;
    int a = (int)(g_pdone_n % NPALLOC);
    ev_wait(g_pdone, g_palloc_fence[a], "上屏分配器");
    [g_palloc[a] reset];
    // PR7：present_mode 变体选路（§4 PR7 / §2.3 判定次序 2）：PQ 层（RGB10A2）上 SDR 定格源按 mode 2 编码（纸白 100 nit，
    //   层不因源切回）；8 位目标零成本直通（下方 else 走原路——逐字节同改前）
    float hp[8];
    int pv = present_hdr_uv(hp, layer.pixelFormat, 1);
    if (pv != HDR_PV_TRIVIAL && pv != HDR_PV_TO_PQ) { GRED_ONCE("出图：策略给的模式 %d 不在 gal 可达域（SDR 定格源 → {直通, mode 2}），本帧按原样直通", pv); pv = HDR_PV_TRIVIAL; }
    id<MTLRenderPipelineState> pso_h = pv == HDR_PV_TO_PQ ? pr_hdr_pso_get(layer.pixelFormat, 0) : nil;
    uint64_t hp_gpu = pso_h ? gal_hdr_pth_fill(a, hp) : 0;
    id<MTL4CommandBuffer> cb = [g_gdev newCommandBuffer];
    [cb beginCommandBufferWithAllocator:g_palloc[a]];
    id<MTL4RenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pr_pass(dt, r)];
    if (pso_h && hp_gpu && g_pth_t) pr_encode_hdr(e, g_pth_t, pso_h, sl.aa ? sl.post : sl.tex, r, filter, hp_gpu);
    else pr_encode(e, g_pt, pso, sl.aa ? sl.post : sl.tex, r, filter);
    [e endEncoding];
    [cb endCommandBuffer];
    if (gpuwait) [g_pq waitForEvent:g_pev value:sl.fence];   // 旧做法（A/B）：定格那次提交做完再读，在 GPU 上等
    [g_pq waitForDrawable:dr];
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        if (f.error) gal_gpu_error_exit("上屏", f.error);
        slot_unpresent(s);
    }];
    id<MTL4CommandBuffer> bufs[] = {cb};
    [g_pq commit:bufs count:1 options:o];
    uint64_t t_c = trace ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
    [g_pq signalDrawable:dr];
    uint64_t v = ++g_pdone_n; [g_pq signalEvent:g_pdone value:v]; g_palloc_fence[a] = v;
    [dr addPresentedHandler:^(id<MTLDrawable> d) {   // 画面真正上屏的时刻（显示节拍）：frames.tsv 的 disp_us 用；presentedTime 为 0 = 没上屏（被丢）
        CFTimeInterval t = d.presentedTime;
        if (trace) GLOG("[出图表] 帧 %llu 栅栏 %llu 发事件 %llu 等待开始 %llu 等到 %llu（栅栏已到 %llu%s）提交 %llu 上屏 %llu", (unsigned long long)sl.frame, (unsigned long long)sl.fence,
                        (unsigned long long)sl.t_sig, (unsigned long long)t_w0, (unsigned long long)t_w1, (unsigned long long)sv, gpuwait ? "，GPU 侧等" : "", (unsigned long long)t_c,
                        t > 0 ? (unsigned long long)(t * 1e9) : 0ull);
        if (t <= 0) { atomic_fetch_add(&g_n_disp_drop, 1); return; }
        double p = g_disp_prev; g_disp_prev = t; if (p > 0) atomic_store(&g_disp_us, (uint64_t)((t - p) * 1e6));
    }];
    if (mi > 0) [dr presentAfterMinimumDuration:mi]; else [dr present];
    gal_gate_leave();
    atomic_fetch_add(&g_n_shown, 1);
}
static void *present_main(void *arg) {
    (void)arg;
    pthread_setname_np("nxgal-present");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    for (;;) @autoreleasepool {
        pthread_mutex_lock(&g_mu);
        while (g_pending < 0 || !g_layer) {
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 1;
            pthread_cond_timedwait(&g_cv, &g_mu, &ts);   // 空闲等新帧（1 秒醒一次，不影响语义）
        }
        int s = g_pending; g_pending = -1; g_slot[s].presenting++;
        pslot sl = g_slot[s];
        CAMetalLayer *layer = g_layer; int vsync = g_vsync, filter = g_filter, rw = g_req_w, rh = g_req_h; float mi = g_min_interval;
        pthread_mutex_unlock(&g_mu);

        if (!present_prep(layer, s, vsync, rw, rh)) continue;
        gal_gate_enter();   // 后台闸门（gal_core.m）：进后台后不取画布、不提交
        // 11-01 审计 P2-5（需读数再定，先后顺序不改）：取画布在闸内。量这次等了多久、此刻有没有关闸请求，取不到的与慢的（≥ 100 ms）照实记，不再一律写成「1 秒超时」
        uint64_t t_nd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        id<CAMetalDrawable> dr = [layer nextDrawable];
        unsigned long long nd_ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t_nd) / 1000000;
        if (!dr) {
            gal_gate_leave(); atomic_fetch_add(&g_n_nodrawable, 1);
            static int nnd; if (nnd++ < 8) GLOG("【红】出图线程：nextDrawable 取不到（第 %d 次；等了 %llu ms，此刻%s关闸请求），这一帧不上屏", nnd, nd_ms, gal_gate_held() ? "有" : "无");
            slot_unpresent(s); continue;
        }
        if (nd_ms >= 100) { static int nslow; if (nslow++ < 8) GLOG("出图线程：nextDrawable 等了 %llu ms（闸内；第 %d 次 ≥ 100 ms，此刻%s关闸请求）", nd_ms, nslow, gal_gate_held() ? "有" : "无"); }
        present_one(layer, dr, s, sl, filter, mi);
    }
    return NULL;
}
static int pq_start(void) {   // g_mu 下调
    if (g_pq) return 1;
    NSError *e = nil;
    g_pq = [g_gdev newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&e];
    if (!g_pq) { GLOG("【红】出图队列建不出：%s", e.localizedDescription.UTF8String); return 0; }
    for (int i = 0; i < NPALLOC; i++) { g_palloc[i] = [g_gdev newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:&e]; if (!g_palloc[i]) { g_pq = nil; return 0; } }
    g_pdone = [g_gdev newSharedEvent]; g_pt = mk_tab();
    [g_pq addResidencySet:g_pset];
    pthread_t th; if (pthread_create(&th, NULL, present_main, NULL)) { GLOG("【红】出图线程起不来"); g_pq = nil; return 0; }
    pthread_detach(th);
    return 1;
}

// ---------- 导出入口 ----------
NXGAL_API void nxgal_window_set_layer(void *ca_metal_layer) { GAL_API_LOCK();
    CAMetalLayer *L = (__bridge CAMetalLayer *)ca_metal_layer;
    if (L && !g_gdev) { GRED_ONCE("nxgal_window_set_layer：nxgal_init 之前调用，忽略"); return; }   // 出图队列 / 线程在 Gpu 线程下次 present 时起
    pthread_mutex_lock(&g_mu);
    if (L) {
        L.device = g_gdev;
        L.pixelFormat = MTLPixelFormatBGRA8Unorm;   // 同 Vulkan 端交换链 B8G8R8A8Unorm（帧里是伽马编码值，原样写出）
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);   // 同 Vulkan 端 SrgbNonlinear 表面：按 sRGB 做色彩匹配（广色域屏不过饱和）
        if (cs) { L.colorspace = cs; CGColorSpaceRelease(cs); }
        L.maximumDrawableCount = 3;
        // PR7：上面刚强制设过 S0——gal 侧层簿记归 0（进层 / 切回从这里起算）
        atomic_store(&g_hdr_layer_pq_applied, 0);
    } else {
        atomic_store(&g_hdr_layer_pq_applied, -1);   // 摘层：簿记未知
    }
    g_layer = L;
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mu);
    if (L) gal_hdr_layer_apply(L);   // PR7 创建点：off ⇒ layer_pq 恒 0 与已应用态一致（零写，零变化）；on/auto + 预挂过的层直接 PQ（同直连层 front_metal_layer 取用点先例，§4 PR4 ①）
}

NXGAL_API void nxgal_window_set_size(int32_t w, int32_t h) { GAL_API_LOCK(); pthread_mutex_lock(&g_mu); g_req_w = w; g_req_h = h; pthread_mutex_unlock(&g_mu); }
NXGAL_API void nxgal_window_set_vsync(int32_t mode) { GAL_API_LOCK(); pthread_mutex_lock(&g_mu); g_vsync = mode; pthread_mutex_unlock(&g_mu); }
// 不拿导出入口全局锁：只写 g_mu 护的一个值；SurfaceFlinger 合成线程持它自己的锁时调（交换间隔变了，见 RenderLoop.cs）
NXGAL_API void nxgal_window_set_min_interval(float seconds) { pthread_mutex_lock(&g_mu); g_min_interval = seconds > 0 ? seconds : 0; pthread_mutex_unlock(&g_mu); }
NXGAL_API void nxgal_window_set_scaling(int32_t filter, float level) { GAL_API_LOCK();
    (void)level;   // 只有 FSR 用（锐化强度）
    if (filter == 2) GRED_ONCE("缩放过滤 FSR 未实现，按双线性（后续：MetalFX 空间放大 / RCAS）");
    if (filter == 3) GRED_ONCE("缩放过滤 Area 未实现，按双线性");
    pthread_mutex_lock(&g_mu); g_filter = filter == 1 ? 1 : 0; pthread_mutex_unlock(&g_mu);
}
NXGAL_API void nxgal_window_set_antialiasing(int32_t mode) {
    if (mode < 0 || mode > 5) { GLOG("【红】抗锯齿模式 %d 无效", mode); return; }
    pthread_mutex_lock(&g_mu); g_antialiasing = mode; pthread_mutex_unlock(&g_mu);
}

// 最近两次画面真正上屏的间隔（微秒，0 = 还没有 / 无显示层）：比在渲染线程上记 Present 调用时刻准（后者带记时抖动，M0 首局 ±2 ms）
NXGAL_API uint64_t nxgal_display_interval_us(void) { return atomic_load(&g_disp_us); }
NXGAL_API void nxgal_window_stats(uint64_t out[4]) { GAL_API_LOCK();
    out[0] = atomic_load(&g_n_present); out[1] = atomic_load(&g_n_shown); out[2] = atomic_load(&g_n_dropped); out[3] = atomic_load(&g_n_nodrawable);
}

// 源贴图的取用视图：恒等分量映射、非 sRGB、2D 第 0 级第 0 层。临时视图由调用方在定格命令缓冲开始后挂延后释放。
static id<MTLTexture> src_view(gal_tex *t) {
    id<MTLTexture> x = t->tex;
    MTLPixelFormat f = x.pixelFormat;
    if (f == MTLPixelFormatRGBA8Unorm_sRGB) f = MTLPixelFormatRGBA8Unorm;
    else if (f == MTLPixelFormatBGRA8Unorm_sRGB) f = MTLPixelFormatBGRA8Unorm;
    MTLTextureSwizzleChannels id4 = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    MTLTextureSwizzleChannels sw = x.swizzle;
    int ident = sw.red == id4.red && sw.green == id4.green && sw.blue == id4.blue && sw.alpha == id4.alpha;
    if (f == x.pixelFormat && ident && x.textureType == MTLTextureType2D && x.mipmapLevelCount == 1) return x;
    // 从底层贴图直接建（视图的视图在 Metal 校验层下读成全 0：驻留按底层贴图算，见单测「分量映射视图」）
    NSUInteger lv = 0, sl = 0; id<MTLTexture> root = x;
    while (root.parentTexture) { lv += root.parentRelativeLevel; sl += root.parentRelativeSlice; root = root.parentTexture; }
    id<MTLTexture> v = [root newTextureViewWithPixelFormat:f textureType:MTLTextureType2D levels:NSMakeRange(lv, 1) slices:NSMakeRange(sl, 1) swizzle:id4];
    return v;
}

// 贴边暗带（10-22 八方2 镇上：放宽后某一遍计算着色器按原宽判越界，右 142 列没人写，场景右侧约 20% 被盖成近黑、只剩星点 / 小地图——
// 不是纯黑，旧判法「外侧整列纯黑」看不见）：一侧从图边到第 x 列整段明显比紧挨的内侧暗，且多数行在同一列有台阶（直的断口）。
// 判据：带宽 ≥ 宽/50 且 ≥ 4；逐抽样行：带外紧挨 s 列（s = max(2, 宽/32)）平均 ≥ 8 且整段暗带平均 < 它 × 0.4 的行 ≥ 50%（夜景内侧只有 15 上下：10-22 八方2 断帧 62–74% / 修好 8–24%），
// 断口两侧各 4 列有台阶（带内 < 带外 × 0.6）的行 ≥ 40%，
// 且整带平均 < 同宽内侧平均 × 0.4、对侧同宽一段 ≥ 暗带 × 1.5（只认一侧）、带内平滑（横向相邻差 < 带均值 × 0.08）。贴脸暗物体有纹理不算（10-22 怪猎门柱 0.11–0.2、八方2 缺块 0.035）。渐暗（没有台阶）、不贴边的暗竖条、两侧都暗的 logo 页、纯 2D 页不算。只在出图比 16:9 宽时判（同黑带）；返回带起点列（右侧）/ 带终点列（左侧），没有 = −1
// 内容判据（见文件头「满屏判据」）：判一张已做完的定格图
// 10-30：判据不在出图（渲染）线程上跑——这里在入口锁里，判一次要几十次逐列 getBytes（接缝判据 a04532dbe 起更多），直连同类问题让 d2r 慢帧 2.4%。
//   出图线程只钉槽、拍下当时的几何状态，判交给串行队列 fit_dq()（g_fj 的 streak / buf 与 fit_judge.h 的静态缓冲只在这条队列上碰）；判完队列自己放槽
static int g_fit_run = -1;   // g_fit_run：正在队列上判的槽（-1 = 没有；g_mu 下读写）
typedef struct { int geo, kind; uint64_t n; char why[160]; } fit_snap;   // 钉住那张判的时刻的几何状态（块里不能直接捕获数组）
static void fit_judge(id<MTLTexture> qt, int geo, const char *gw, int kind, uint64_t n) {   // 判一张已做完的定格图（判法见 fit_judge.h fj_judge）；只在 fit_dq() 上调
    fj_src s = tex_src(qt); fj_judge(&g_fj, &s, geo, gw, kind, n);   // 不在宽屏已验证名单：16:9 原比例页（种类 1），见 fit_narrow
}
// 内容判据钉帧周期（出图次数）：产品 30；单测（t_present 满屏判据段）设短，每轮出图次数按它等比缩，判据节奏不变（10-22 画面·着色器线：那段 57 秒、门禁并发下顶过 300 秒）
static int g_fit_period = 30;
void gal_present_fit_period(int n) { g_fit_period = n >= 2 ? n : 30; }
static int g_fit_q = -1;   // 内容判据钉住、等 GPU 做完的定格槽（-1 = 没有）
// 逐帧诊断（不开零开销）：每次出图钉住最新的定格图（队列至多 LQN 张），GPU 做完后在之后的出图里按序取，不等 GPU、不漏帧（队列满才漏，记「漏」）。
//   NXGAL_LUMA_LOG=1：取 16 行、隔列求 RGB 平均，记「亮度 第 N 次出图」一行；
//   NXGAL_FRAME_CAP=a-b（第 a..b 次出图）或 mark+K:N（MARK 后跳 K 次再存 N 次；MARK 由服务层 nxgal_frame_cap_arm 通知）：窗口内每帧整幅灰度（(R+G+B)/3）
//     追加写进 NXGAL_FRAME_CAP_OUT（缺省 Documents/framecap.bin；相对路径按 $HOME/Documents）：每帧 12 字节头（出图序号、宽、高，u32 小端）+ 宽×高字节。
// 用途：真机闪烁 / 贴图错位按帧量（10-22 暗黑2 营地：真机录像拿回 Mac 回放不闪，单开关真机对照要真机上的逐帧亮度与位移）
#define LQN 6
static int g_lq[LQN], g_lqh, g_lqc; static uint64_t g_lqn[LQN], g_lq_last, g_lq_miss;
static int g_diag_luma = -1, g_diag_cap;
static _Atomic uint64_t g_cap_lo = UINT64_MAX, g_cap_hi; static int g_cap_skip, g_cap_n; static FILE *g_cap_f; static uint64_t g_cap_done;
NXGAL_API void nxgal_frame_cap_arm(void) {   // 服务层在 MARK 时调（mark+K:N 窗口）：从下一次出图起跳 K 次、存 N 次
    if (!g_cap_n || atomic_load(&g_cap_lo) != UINT64_MAX) return;
    uint64_t lo = atomic_load(&g_n_present) + 1 + (uint64_t)g_cap_skip;
    atomic_store(&g_cap_hi, lo + (uint64_t)g_cap_n - 1); atomic_store(&g_cap_lo, lo);
    GLOG("存帧：MARK 后开窗，第 %llu..%llu 次出图", (unsigned long long)lo, (unsigned long long)(lo + (uint64_t)g_cap_n - 1));
}
static void diag_init(void) {
    const char *v = getenv("NXGAL_LUMA_LOG"); g_diag_luma = v && *v == '1';
    if (g_diag_luma) GLOG("NXGAL_LUMA_LOG=1：逐帧记出图亮度（诊断）");
    const char *c = getenv("NXGAL_FRAME_CAP");
    if (c && *c) {
        unsigned long long a = 0, b = 0; int k = 0, n = 0;
        if (sscanf(c, "mark+%d:%d", &k, &n) == 2 || sscanf(c, "mark:%d", &n) == 1) { g_cap_skip = k; g_cap_n = n; g_diag_cap = n > 0; }
        else if (sscanf(c, "%llu-%llu", &a, &b) == 2 && b >= a) { atomic_store(&g_cap_hi, b); atomic_store(&g_cap_lo, a); g_diag_cap = 1; }
        if (!g_diag_cap) GLOG("【红】NXGAL_FRAME_CAP=%s 看不懂（a-b 或 mark+K:N）", c);
        else {
            const char *o = getenv("NXGAL_FRAME_CAP_OUT"); char p[1100];
            if (o && *o == '/') snprintf(p, sizeof p, "%s", o);
            else snprintf(p, sizeof p, "%s/Documents/%s", getenv("HOME") ? getenv("HOME") : ".", o && *o ? o : "framecap.bin");
            g_cap_f = fopen(p, "wb");
            if (!g_cap_f) { GLOG("【红】存帧：打不开 %s", p); g_diag_cap = 0; }
            else GLOG("存帧：NXGAL_FRAME_CAP=%s → %s", c, p);
        }
    }
}
static void luma_log(id<MTLTexture> t, uint64_t n) {
    static uint8_t *row; static int cap; int w = (int)t.width, h = (int)t.height, dy = h >= 16 ? h / 16 : 1;
    if (cap < w * 4) { free(row); row = malloc((size_t)w * 4); cap = row ? w * 4 : 0; }
    if (!row) return;
    uint64_t sum = 0, k = 0;
    for (int y = dy / 2; y < h; y += dy) {
        [t getBytes:row bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, y, w, 1) mipmapLevel:0];
        for (int x = 0; x < w; x += 2) { sum += (uint64_t)row[4 * x] + row[4 * x + 1] + row[4 * x + 2]; k += 3; }
    }
    GLOG("亮度 第 %llu 次出图：%.3f", (unsigned long long)n, k ? (double)sum / (double)k : 0.0);
}
static void cap_write(id<MTLTexture> t, uint64_t n) {
    static uint8_t *px, *g; static size_t cap; int w = (int)t.width, h = (int)t.height; size_t np = (size_t)w * h;
    if (cap < np) { free(px); free(g); px = malloc(np * 4); g = malloc(np); cap = px && g ? np : 0; }
    if (!cap) return;
    [t getBytes:px bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    for (size_t i = 0; i < np; i++) g[i] = (uint8_t)(((unsigned)px[4 * i] + px[4 * i + 1] + px[4 * i + 2]) / 3);
    uint32_t hd[3] = {(uint32_t)n, (uint32_t)w, (uint32_t)h};
    fwrite(hd, sizeof hd, 1, g_cap_f); fwrite(g, 1, np, g_cap_f);
    if (++g_cap_done == (uint64_t)(atomic_load(&g_cap_hi) - atomic_load(&g_cap_lo) + 1)) { fflush(g_cap_f); GLOG("存帧：%llu 帧已写完（漏 %llu 帧）", (unsigned long long)g_cap_done, (unsigned long long)g_lq_miss); }
}
static int diag_want(uint64_t n) { return g_diag_luma || (g_diag_cap && n >= atomic_load(&g_cap_lo) && n <= atomic_load(&g_cap_hi)); }
// 自动玩家（测试层）：最近一帧的绘制数——上屏时按累计绘制数差分
uint64_t gal_draw_count(void);
static _Atomic uint64_t g_ap_draws, g_ap_prev;
// 双轨直连模式（runtime/include/s2a_gfx_mode.h）：本渲染器不起，自动玩家的两个信号改由直连图形层给（graphics/nvn/host_adapt.m）。
//   运行时按名字取（只取一次）：渲染器单测与 libnxgal.dylib 不链原生层 / 直连层，取不到就按通用走
static uint32_t (*g_dir_draws)(void); static int32_t (*g_dir_shot)(void *, int32_t, int32_t *, int32_t *);
static int ap_direct(void) {
    static int v = -1;
    if (v < 0) {
        int (*mode)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_gfx_mode");
        g_dir_draws = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "s2a_direct_ap_draws");
        g_dir_shot = (int32_t (*)(void *, int32_t, int32_t *, int32_t *))dlsym(RTLD_DEFAULT, "s2a_direct_screenshot");
        v = mode && mode() == 1 && g_dir_draws && g_dir_shot;
    }
    return v;
}
uint32_t s2a_ap_passes(void) { static uint32_t (*dp)(void); static int once; if (!once) { once = 1; dp = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "s2a_direct_ap_passes"); } return ap_direct() && dp ? dp() : 0; }   // 每帧渲染遍数：只有直连层给（普查只出直连），通用模式 0 = 没有这路信号
uint32_t s2a_ap_draws(void) { if (ap_direct()) return g_dir_draws(); uint64_t d = atomic_load(&g_ap_draws); return d > UINT32_MAX ? UINT32_MAX : (uint32_t)d; }   // 签名见 tests/autoplay/autoplay_host.h
static uint64_t g_npresent;
uint64_t gal_present_count(void) { return g_npresent; }
static _Atomic int g_out_w, g_out_h;   // 最近一次出图的源矩形宽高
NXGAL_API void nxgal_out_size(int *w, int *h) { *w = atomic_load_explicit(&g_out_w, memory_order_relaxed); *h = atomic_load_explicit(&g_out_h, memory_order_relaxed); }
NXGAL_API void nxgal_present(uint32_t tex, const nxgal_crop *crop) { nxgal_pool_cycle();   // 先于入口锁与任何 @autoreleasepool：上一帧本线程的自动释放对象在这里放掉
    if (atomic_load(&g_session_stop)) return;
    GAL_API_LOCK(); gal_rtd_frame_end();
    // 实时声明（gal_rt.m，缺省关）：本线程 = Metal 编码线程，帧周期 = 最短显示间隔（SurfaceFlinger 按交换间隔设），没设按 60 帧
    if (gal_rt_on()) { float mi = g_min_interval; gal_rt_tick(mi > 0 ? mi * 1000.0 : 1000.0 / 60); }
    SW_SCOPE(SW_PRESENT, 1);
    GP_SCOPE(GP_PRESENT);
    { uint64_t d = gal_draw_count(); atomic_store(&g_ap_draws, d - atomic_exchange(&g_ap_prev, d)); }
    { static uint64_t np; if (gal_spvx_counting() && ++np % 600 == 0) gal_bounds_report_delta(); }
    g_npresent++;
    gal_tex *t = gal_tex_get(tex);
    if (!t) { GRED_ONCE("出图：贴图 %u 无效，跳过", tex); return; }
    nxgal_crop c = crop ? *crop : (nxgal_crop){0, 0, 0, 0, 0, 0, 1, 0, 0};
    int TW = (int)t->tex.width, TH = (int)t->tex.height;
    // 源矩形：同 Window.cs:368–388（左右都为 0 = 整宽；否则 [Left, Right)；上下同理）
    int x0 = 0, x1 = TW, y0 = 0, y1 = TH;
    if (c.left != 0 || c.right != 0) { x0 = c.left; x1 = c.right; }
    if (c.top != 0 || c.bottom != 0) { y0 = c.top; y1 = c.bottom; }
    int cw = x1 - x0, ch = y1 - y0;
    atomic_store_explicit(&g_out_w, cw, memory_order_relaxed); atomic_store_explicit(&g_out_h, ch, memory_order_relaxed);   // 开发浮层「满屏 出图」读（nxgal_out_size）
    { static int lt, lw, lh, lx0, ly0, lx1, ly1, ls; static float lax, lay; static uint64_t n, nchg;   // 出图参数变化时记一行（查满屏 / 信箱：开局几页与进岛的差别）；前 32 次变化照记、之后每 1000 次一行（同上限频）
      n++; if (TW != lw || TH != lh || x0 != lx0 || y0 != ly0 || x1 != lx1 || y1 != ly1 || c.stretched != ls || c.aspect_x != lax || c.aspect_y != lay || !lt) {
        lt = 1; lw = TW; lh = TH; lx0 = x0; ly0 = y0; lx1 = x1; ly1 = y1; ls = c.stretched; lax = c.aspect_x; lay = c.aspect_y;
        if (nchg++ < 32 || nchg % 1000 == 0) GLOG("出图参数（第 %llu 次出图起，第 %llu 次变化）：贴图 %dx%d，源 [%d,%d)×[%d,%d)，拉伸 %d，宽高比 %g:%g，翻转 %d/%d", (unsigned long long)n, (unsigned long long)nchg, TW, TH, x0, x1, y0, y1, c.stretched, c.aspect_x, c.aspect_y, c.flip_x, c.flip_y); } }
    if (cw <= 0 || ch <= 0 || cw > 16384 || ch > 16384) { GLOG("【红】出图裁切无效：L%d R%d T%d B%d（贴图 %dx%d），跳过", c.left, c.right, c.top, c.bottom, TW, TH); return; }
    @autoreleasepool {
        if (!p_init()) return;
        // 内容判据：每 30 次出图钉住当时最新的定格图（reading +1 防复用），GPU 做完后在之后的出图里判，不跳过——
        // 旧做法到点只看一眼、没做完就跳过：连续出图时最新那张总是刚提交的，整机高负载下几乎每次都跳过，判据与单测都随负载漂（10-21 门禁 66/67）
        // 先判掉已做完的那张，再看到没到点钉新的（反过来到点恰逢上一张刚做完时会丢掉这次钉点）
        {
            pthread_mutex_lock(&g_mu);
            int q = g_fit_q; id<MTLTexture> qt = q >= 0 && g_fit_run < 0 && g_pev.signaledValue >= g_slot[q].fence ? g_slot[q].tex : nil;   // 队列上一张还没判完就先不交（不排长队）
            pthread_mutex_unlock(&g_mu);
            if (qt) {   // 交给判据队列：拍下此刻的几何状态（同旧做法在这一刻读），槽的 reading 由队列判完再放
                fit_snap sn; pthread_mutex_lock(&g_geo_mu); memcpy(sn.why, g_geo_why, sizeof sn.why); pthread_mutex_unlock(&g_geo_mu);
                sn.geo = g_fit_geo && atomic_load(&g_geo_bad); sn.kind = fit_narrow() ? 1 : atomic_load(&g_pillar); sn.n = atomic_load(&g_n_present);
                pthread_mutex_lock(&g_mu); g_fit_q = -1; g_fit_run = q; pthread_mutex_unlock(&g_mu);
                dispatch_async(fit_dq(), ^{
                    fit_judge(qt, sn.geo, sn.why, sn.kind, sn.n);
                    pthread_mutex_lock(&g_mu); g_slot[q].reading--; g_fit_run = -1; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
                });
            }
            pthread_mutex_lock(&g_mu);
            if (g_fit_q < 0 && (atomic_load(&g_n_present) % g_fit_period == g_fit_period - 1 || atomic_exchange(&g_geo_pin_req, 0)) && g_latest >= 0 && g_slot[g_latest].tex) { g_fit_q = g_latest; g_slot[g_fit_q].reading++; g_fit_geo = atomic_load(&g_geo_bad); }
            pthread_mutex_unlock(&g_mu);
        }
        if (g_diag_luma < 0) diag_init();
        if (g_diag_luma || g_diag_cap) {
            // 先按序取掉已做完的，再钉最新那张（与内容判据同理）
            for (;;) {
                pthread_mutex_lock(&g_mu);
                int q = g_lqc ? g_lq[g_lqh] : -1; uint64_t qn = g_lqc ? g_lqn[g_lqh] : 0;
                id<MTLTexture> qt = q >= 0 && g_pev.signaledValue >= g_slot[q].fence ? g_slot[q].tex : nil;
                pthread_mutex_unlock(&g_mu);
                if (!qt) break;
                if (g_diag_luma) luma_log(qt, qn);
                if (g_diag_cap && qn >= atomic_load(&g_cap_lo) && qn <= atomic_load(&g_cap_hi)) cap_write(qt, qn);
                pthread_mutex_lock(&g_mu); g_slot[q].reading--; g_lqh = (g_lqh + 1) % LQN; g_lqc--; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
            }
            uint64_t n = atomic_load(&g_n_present);
            pthread_mutex_lock(&g_mu);
            if (n != g_lq_last && g_latest >= 0 && g_slot[g_latest].tex && diag_want(n)) {
                if (g_lqc < LQN) { int k = (g_lqh + g_lqc) % LQN; g_lq[k] = g_latest; g_lqn[k] = n; g_lqc++; g_slot[g_latest].reading++; }
                else g_lq_miss++;
                g_lq_last = n;
            }
            pthread_mutex_unlock(&g_mu);
        }
        // 挑一张空闲定格贴图（不是最新、没人读）；至多 1 最新 + 2 上屏中 + 截图在读 + 判据钉 1 张 + 逐帧诊断钉 LQN 张，NSLOT 张总有空的
        pthread_mutex_lock(&g_mu);
        int s = -1;
        for (int waited = 0; s < 0; ) {
            for (int i = 0; i < NSLOT; i++) if (i != g_latest && !g_slot[i].presenting && !g_slot[i].reading) { s = i; break; }
            if (s >= 0) break;
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 2;
            if (pthread_cond_timedwait(&g_cv, &g_mu, &ts) && !waited++) GLOG("【红】出图：定格贴图 2 秒没有空闲的（上屏 / 截图占着），继续等");
        }
        int antialiasing = g_antialiasing;
        pthread_mutex_unlock(&g_mu);
        pslot *sl = &g_slot[s];
        if (!sl->tex || sl->w != cw || sl->h != ch) {
            if (sl->tex) { [g_pset removeAllocation:sl->tex]; gal_release_later(sl->tex, 1); }
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:cw height:ch mipmapped:NO];
            d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
            sl->tex = [g_gdev newTextureWithDescriptor:d]; sl->w = cw; sl->h = ch;
            if (!sl->tex) { GLOG("【红】定格贴图建不出 %dx%d", cw, ch); sl->w = sl->h = 0; return; }
            gal_res_add(sl->tex); [g_pset addAllocation:sl->tex]; [g_pset commit];
        }
        if (sl->post && ((int)sl->post.width != cw || (int)sl->post.height != ch)) {
            [g_pset removeAllocation:sl->post]; gal_release_later(sl->post, 1); sl->post = nil; [g_pset commit];
        }
        if (antialiasing && !sl->post) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:cw height:ch mipmapped:NO];
            d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            sl->post = [g_gdev newTextureWithDescriptor:d];
            if (!sl->post) { GLOG("【红】抗锯齿输出贴图建不出 %dx%d", cw, ch); return; }
            gal_res_add(sl->post); [g_pset addAllocation:sl->post]; [g_pset commit];
        }
        id<MTLTexture> src = src_view(t);
        if (!src) { GLOG("【红】出图：源贴图视图建不出（格式 %d）", t->info.format); return; }
        // ① 定格：主队列、按命令顺序（之前所有命令画完的内容）
        gal_pass_clears_touch(t->root); gal_pass_close();   // 只落实出图源贴图自己的挂起清屏，别的继续挂到下一帧
        // 遍统计（NXGAL_PSTAT）：出图源按「读」记，本帧到此为界算账
        if (PSTAT_ON()) { gal_pstat_use((__bridge void *)t->root, PS_READ, 0, 0); gal_pstat_frame(); }
        MTL4RenderPassDescriptor *d = [MTL4RenderPassDescriptor new];
        d.colorAttachments[0].texture = sl->tex; d.colorAttachments[0].loadAction = MTLLoadActionDontCare; d.colorAttachments[0].storeAction = MTLStoreActionStore;
        d.renderTargetWidth = cw; d.renderTargetHeight = ch;
        // 临时内存取不到（gal_transient 已报红）：本次定格跳过，在开通道之前判
        uint64_t gpu; cap_params *p = gal_transient(sizeof *p, 16, &gpu); if (!p) return;
        id<MTL4RenderCommandEncoder> e = gal_render_begin_desc(d);
        // src_view 可在上次 present 已提交、当前命令缓冲尚未开始时创建。
        // 必须在此挂到当前提交的 fence；挂到上一 fence 会让连续 sRGB 帧在校验层下读成 0。
        if (src != t->tex) gal_release_later(src, 0);
        *p = (cap_params){{x0, y0}, {cw, ch}, {c.flip_x ? 1 : 0, c.flip_y ? 1 : 0}, {(int)src.width - 1, (int)src.height - 1}};
        [g_cap_t setTexture:src.gpuResourceID atIndex:0]; [g_cap_t setAddress:gpu atIndex:0];
        [e setArgumentTable:g_cap_t atStages:MTLRenderStageFragment];
        [e setRenderPipelineState:g_cap_pso];
        [e setViewport:(MTLViewport){0, 0, cw, ch, 0, 1}];
        [e setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)cw, (NSUInteger)ch}];
        [e setCullMode:MTLCullModeNone];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        gal_enc_end();
        g_genc_serial++;
        // 抗锯齿编码失败（管线 / 查找表 / 临时内存 / 线性视图建不出，gal_aa.m 已报红；11-01 审计 P1-25）：结束可能还开着的计算编码器，
        //   这一帧按不做抗锯齿上屏（sl->aa = 0：上屏与处理后截图都取定格贴图）。原先直接返回：不提交、不交出图线程，失败持续时画面停在上一帧 / 黑屏
        if (antialiasing && !gal_aa_encode(sl->tex, sl->post, antialiasing)) {
            gal_enc_end(); antialiasing = 0;
            static int naa; if (naa++ < 8) GLOG("【红】出图：抗锯齿编码失败（第 %d 次），这一帧不做抗锯齿上屏", naa);
        }
        { void gal_esite_frame_end(void); gal_esite_frame_end(); }   // 诊断 NXGAL_TRACE_ENC：本帧切遍多时打调用点排行
        g_gp_commit_present = 1; gal_commit();   // 同 Vulkan 端 Present 里的 FlushAllCommands
        gal_pso_cache_flush();   // 收管线描述 / 二进制：本帧有新管线才写（无开关时直接返回）
        uint64_t v = ++g_pev_n; [g_gq signalEvent:g_pev value:v];
        // 上屏管线（图层格式）在 Gpu 线程编好，出图线程只查表
        pthread_mutex_lock(&g_mu); CAMetalLayer *layer = g_layer; pthread_mutex_unlock(&g_mu);
        if (layer) {
            MTLPixelFormat lpf = layer.pixelFormat;   // 读一次（与改前同一处读）：管线预编 / 下面的 PQ 门共用
            pr_pso_get(lpf, 1);
            if (lpf == MTLPixelFormatRGB10A2Unorm) {   // PR7：PQ 层——变体管线一并预编（首帧 / 首切换无现编卡顿，T11 口径）+ 排空喂入
                //   （层持 PQ 才可能要排空——门在层格式上，SDR 层缺省路径零新增开销，同直连路径 nvn_mtl.m 形态；
                //   PQ 窗口 = 游戏出图源是 RGB10A2：排空途中又见清零重等——无 HDR 帧落进 SDR 层）
                pr_hdr_pso_get(MTLPixelFormatRGB10A2Unorm, 1);
                if (hdr_api()) g_hdr.hdr_tick_frame(g_hdr.hdr_layer_sw(), t->tex.pixelFormat == MTLPixelFormatRGB10A2Unorm);   // sw = 层视角开关（PR-B 终稿）：S4 开而玩家 off 时喂玩家开关会把 SDR 帧两帧排空、层掉回 S0（gal 源恒 8 位 SDR），S4 失载体——故喂层视角
            }
        }
        pthread_mutex_lock(&g_mu);
        sl->frame = g_gp_frame - 1; sl->t_sig = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); sl->aa = antialiasing;
        sl->fence = v; sl->stretched = c.stretched != 0; sl->ax = c.aspect_x; sl->ay = c.aspect_y;
        // 加宽（画幅线）生效时游戏出图本身就比 Ryujinx 呈现参数的宽高比（缺省 16:9）宽：按出图源矩形的像素宽高比等比铺（与屏同比即铺满）。
        // 10-19 iPhone 动森出图 1564x720（2.17）被按 16:9 信箱成 2346/2868 宽、两边黑边。比呈现参数窄或相等时照旧（横向缩放渲染的游戏源矩形比显示窄，按源比会压扁）；不用拉伸
        if (!sl->stretched && sl->ax > 0 && sl->ay > 0 && cw > 0 && ch > 0 && (float)cw * sl->ay > (float)ch * sl->ax * 1.01f) { sl->ax = (float)cw; sl->ay = (float)ch; }
        g_latest = s;
        // NXGAL_NO_PRESENT=1（能耗减法实验 B，诊断用）：游戏照画、定格照做（截图 / 自动玩家照常），不交上屏线程——不取 drawable、不缩放上屏、不进合成器
        static int no_present = -1; if (no_present < 0) { const char *e = getenv("NXGAL_NO_PRESENT"); no_present = e && atoi(e); if (no_present) GLOG("NXGAL_NO_PRESENT=1：只定格不上屏（能耗减法实验）"); }
        if (!no_present && g_layer && pq_start()) {
            if (g_pending >= 0) atomic_fetch_add(&g_n_dropped, 1);   // 信箱里没来得及上屏的旧帧被顶掉
            g_pending = s;
            pthread_cond_broadcast(&g_cv);
        }
        pthread_mutex_unlock(&g_mu);
        atomic_fetch_add(&g_n_present, 1);
    }
}

// 截图：最近一次出图的定格内容（裁切 + 翻转后、窗口缩放前；BGRA8、行紧排、alpha = 255）。任意线程可调。
// 返回字节数（w × h × 4）；out 为空或 cap 不够时只填 w / h 并返回所需字节数；还没出过图返回 0
// 不拿渲染器全局锁（GAL_API_LOCK）：只碰定格槽（g_mu + reading 计数防复用）、定格完成事件与槽里的贴图，同出图线程。
// 10-19 iPhone 动森四局「GPU 卡死：等定格完成 N（已到 N−1）」根因：自动玩家截图持着全局锁等定格完成，渲染线程被这把锁挡住
// （Ryujinx 报 GPU processing thread is too slow），推进定格的提交出不去，3 秒后判卡死退出；栅栏其实全做完了（A 局 1064 / 1064）
static int32_t screenshot(void *out, int32_t cap, int32_t *w, int32_t *h, int processed) {
    pthread_mutex_lock(&g_mu);
    int s = g_latest;
    if (s < 0) { pthread_mutex_unlock(&g_mu); if (w) *w = 0; if (h) *h = 0; return 0; }
    pslot sl = g_slot[s];
    int32_t need = sl.w * sl.h * 4;
    if (w) *w = sl.w; if (h) *h = sl.h;
    if (!out || cap < need) { pthread_mutex_unlock(&g_mu); return need; }
    g_slot[s].reading++;
    pthread_mutex_unlock(&g_mu);
    ev_wait(g_pev, sl.fence, "定格完成");
    [(processed && sl.aa ? sl.post : sl.tex) getBytes:out bytesPerRow:(NSUInteger)sl.w * 4 fromRegion:MTLRegionMake2D(0, 0, sl.w, sl.h) mipmapLevel:0];
    pthread_mutex_lock(&g_mu); g_slot[s].reading--; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
    return need;
}
NXGAL_API int32_t nxgal_screenshot(void *out, int32_t cap, int32_t *w, int32_t *h) { if (ap_direct()) return g_dir_shot(out, cap, w, h); return screenshot(out, cap, w, h, 0); }
NXGAL_API int32_t nxgal_screenshot_processed(void *out, int32_t cap, int32_t *w, int32_t *h) { return screenshot(out, cap, w, h, 1); }


// 最近一帧的出图源尺寸（游戏自己的渲染像素，cw×ch）+ 呈现参数 + 拉伸标记：触屏直通把屏幕点换算成
// 游戏像素时用这一组——触点的坐标空间就是游戏出图的空间，不必去猜「显示宽是多少、宽屏点生效没有」。
// 上屏矩形由调用方按 dst_rect（本文件 183 行）同一套算式得出，避免两边各算一遍差半像素。
// 还没出过图 / 直连模式返回 0。
NXGAL_API int nxgal_present_frame(int32_t *w, int32_t *h, float *ax, float *ay, int32_t *stretched) {
    pthread_mutex_lock(&g_mu);
    int s = g_latest; int32_t iw = 0, ih = 0; float a = 0, b = 0; int32_t st = 0;
    if (s >= 0 && s < NSLOT) { iw = g_slot[s].w; ih = g_slot[s].h; a = g_slot[s].ax; b = g_slot[s].ay; st = g_slot[s].stretched; }
    pthread_mutex_unlock(&g_mu);
    if (w) *w = iw; if (h) *h = ih; if (ax) *ax = a; if (ay) *ay = b; if (stretched) *stretched = st;
    return iw > 0 && ih > 0;
}

// 把最近一帧按当前窗口设置（宽高比 / 拉伸、缩放过滤）画进 GAL 贴图 dst（整张当窗口），与上屏同一段编码。Gpu 线程调用；诊断与单测用。
// 返回 0 = 已编码；-1 = 还没出过图 / 目标无效
NXGAL_API int32_t nxgal_window_render_to(uint32_t dst) { GAL_API_LOCK();
    gal_tex *t = gal_tex_get(dst);
    if (!t) return -1;
    @autoreleasepool {
        if (!p_init()) return -1;
        pthread_mutex_lock(&g_mu);
        int s = g_latest; pslot sl = s >= 0 ? g_slot[s] : (pslot){0}; int filter = g_filter;
        pthread_mutex_unlock(&g_mu);
        if (s < 0) return -1;
        id<MTLRenderPipelineState> p = pr_pso_get(t->tex.pixelFormat, 1); if (!p) return -1;
        // PR7：render_to = 上屏同一段编码——PQ 层目标（RGB10A2）上同走 present_mode 变体（§4 PR7）；off 缺省直通
        //   （读开关——诊断路径，事件档频率；与改前逐字节一致）
        float hp[8];
        int pv = present_hdr_uv(hp, t->tex.pixelFormat, 0);
        if (pv != HDR_PV_TRIVIAL && pv != HDR_PV_TO_PQ) { GRED_ONCE("出图：策略给的模式 %d 不在 gal 可达域（SDR 定格源 → {直通, mode 2}）", pv); pv = HDR_PV_TRIVIAL; }
        irect r = dst_rect((int)t->tex.width, (int)t->tex.height, sl.stretched, sl.ax, sl.ay);
        gal_pass_clears_touch(t->root); gal_pass_close();
        id<MTL4RenderCommandEncoder> e = gal_render_begin_desc(pr_pass(t->tex, r));
        if (pv == HDR_PV_TO_PQ) {
            id<MTLRenderPipelineState> ph = pr_hdr_pso_get(t->tex.pixelFormat, 1);
            uint64_t pg = 0; float *q = gal_transient((uint32_t)sizeof hp, 16, &pg);   // Gpu 线程临时池（同 cap_params）
            if (ph && g_rth_t && q) { memcpy(q, hp, sizeof hp); pr_encode_hdr(e, g_rth_t, ph, sl.aa ? sl.post : sl.tex, r, filter, pg); }
            else pr_encode(e, g_rt_t, p, sl.aa ? sl.post : sl.tex, r, filter);   // 变体建不出（已记红）：退回平凡直通，别黑帧
        } else pr_encode(e, g_rt_t, p, sl.aa ? sl.post : sl.tex, r, filter);
        gal_enc_end();
        g_genc_serial++;
    }
    return 0;
}
void gal_present_request_stop(void) {
    atomic_store(&g_session_stop, 1);
    pthread_mutex_lock(&g_mu); g_pending = -1; g_latest = -1; g_layer = nil;
    pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
}
void gal_present_begin_session(void) { atomic_store(&g_session_stop, 0); }
int gal_present_shutdown_session(void) {
    gal_present_request_stop();
    pthread_mutex_lock(&g_mu);
    if (g_fit_q >= 0) { g_slot[g_fit_q].reading--; g_fit_q = -1; }
    while (g_lqc) { g_slot[g_lq[g_lqh]].reading--; g_lqh = (g_lqh + 1) % LQN; g_lqc--; }
    struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 10;
    for (;;) {
        int busy = 0; for (int i = 0; i < NSLOT; i++) busy |= g_slot[i].presenting || g_slot[i].reading;
        if (!busy) break;
        if (pthread_cond_timedwait(&g_cv, &g_mu, &dl) == ETIMEDOUT) { pthread_mutex_unlock(&g_mu); return -ETIMEDOUT; }
    }
    if (g_applied) [g_pq removeResidencySet:g_applied.residencySet];
    g_applied = nil; g_applied_vsync = -1; g_applied_size = (CGSize){0, 0};
    for (int i = 0; i < NSLOT; i++) {
        if (g_slot[i].tex) { gal_res_remove(g_slot[i].tex); [g_pset removeAllocation:g_slot[i].tex]; }
        if (g_slot[i].post) { gal_res_remove(g_slot[i].post); [g_pset removeAllocation:g_slot[i].post]; }
        g_slot[i] = (pslot){0};
    }
    [g_pset commit];
    g_req_w = g_req_h = g_vsync = g_filter = g_antialiasing = 0; g_min_interval = 0;
    atomic_store(&g_hdr_layer_pq_applied, -1);   // PR7：收局簿记归位（下局 set_layer 创建点重新起算）
    g_lqh = 0; g_lq_last = g_lq_miss = 0;
    if (g_cap_f) { fclose(g_cap_f); g_cap_f = NULL; }
    g_diag_luma = -1; g_diag_cap = g_cap_skip = g_cap_n = 0; g_cap_lo = UINT64_MAX; g_cap_hi = g_cap_done = 0;
    g_n_present = g_n_shown = g_n_dropped = g_n_nodrawable = g_disp_us = g_n_disp_drop = g_npresent = 0; g_disp_prev = 0;
    g_out_w = g_out_h = 0; g_ap_draws = g_ap_prev = 0;
    pthread_mutex_unlock(&g_mu);
    return 0;
}
GAL_MTL4_ZONE_END
