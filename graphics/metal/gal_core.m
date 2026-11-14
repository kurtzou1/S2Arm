// GAL Metal 后端：第 1 块「核心与同步」——设备 / Metal 4 队列 / 命令分配器轮换 / 驻留集 / 编码器 / 同步对象 / 延后释放。
// 栅栏：一条共享事件 g_gev 既当提交栅栏（本模块递增的 g_gfence），也承载 Gpu 层的同步号（create_sync 记「同步号 → 栅栏值」）。
#import "gal_internal.h"
#include <stdatomic.h>
#include <unistd.h>
#include <pthread.h>
#include "gal_abi_hash.h"   // 构建时生成（Makefile → tools/abi_hash.py）
#include "gal_pstat.h"
#include "gal_gpuwd.h"
#include "mtl_slot.h"   // 全机 Metal 客户进程名额（建设备前拿）   // GPU 挂死看门狗（T10 / #635，缺省关）：见 gal_gpuwd.h 顶部与 gal_commit 的接线点
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <sys/sysctl.h>
#include <dirent.h>
#include <errno.h>
static _Atomic int g_session_feedback;
static _Atomic int g_archive_stopping, g_archive_write_error, g_pso_write_error;
static _Atomic uint64_t g_archive_epoch;

// ---------- 选路径与 Metal 3 主队列（gal_be.h 表中「选路径」「驻留」两行；卡 M3-4）----------
// 这两段刻意放在 Metal 4 可用性区（GAL_MTL4_ZONE_BEGIN）之外：区内声明都标「macOS 26 / iOS 26 起」，@available 会按 26 折叠，
// 而这里要在 macOS 15 / iOS 18 上真的执行（Metal 3 兼容路径的下限就是它们）。
id<MTLCommandQueue> g_cq3;   // Metal 3 兼容路径的主队列（缺省 Metal 4 路径下为 nil）；同一个 MTLResidencySet 用 addResidencySet 挂它
// 临时闸（10-23 M3-4）：Metal 3 运行时（M3-5～M3-8：提交 / 编码器 / 参数绑定 / 管线编译）合齐前，26 以下的兼容路径先不真的启用——
// 半套路径下初始化会成功，但首次出图就要碰 26 才有的接口（unrecognized selector 直接崩），比原来干脆报红更难排查（铁律：未实现就报红，不兜底）。
// 合齐后把 GAL_M3_RUNTIME_READY 改成 1；26 上用 NXGAL_BE=mtl3 的强制开关不受这道闸影响（A/B 与单测照跑）。
// 要在老系统上提前验初始化 / 后续卡，可显式 NXGAL_M3_RUNTIME=1 放行。
#define GAL_M3_RUNTIME_READY 0
static int m3_runtime_enabled(void) { const char *e = getenv("NXGAL_M3_RUNTIME"); return GAL_M3_RUNTIME_READY || (e && *e == '1'); }
static id<MTLCommandBuffer> g_cb3;   // Metal 3 路径在录的命令缓冲（每次新开；Metal 4 路径下恒为 nil）
// Metal 3 编码器（gal_be.h 表中「编码器」；卡 M3-6）：老接口没有 barrierAfterQueueStages，编码器之间的全序（Metal 4 的 enc_barrier）用同一个栅栏
// g_fence3 串起来——每个编码器开头等它、收尾前更新它；同一队列上跨命令缓冲同样成立（预载缓冲排在在录缓冲之前提交）。
// 资源虽按缺省（有跟踪）建，但经参数缓冲 / gpuAddress 间接访问的不在跟踪范围里，不能只靠跟踪排序
static id<MTLFence> g_fence3;
static id<MTLCommandBuffer> g_pcb3; static id<MTLBlitCommandEncoder> g_penc3;   // Metal 3 预载：单独一条命令缓冲，提交时排在在录缓冲之前（同 Metal 4 的 g_pcb）
static uint64_t g_m3_skip[4];   // Metal 3 下参数绑定（M3-7）未合入而跳过的：0 绘制 1 派发 2 遍内清屏 3 辅助绘制（单测钩子 nxgal_test_m3enc 读）
static uint64_t g_m3_split;     // Metal 3 下同一 blit 编码器里第二条起拆成新编码器的次数（老 blit 编码器没有编码器内屏障）
// Metal 3 延后释放按「命令缓冲完成」放，不按主栅栏：老接口不保留引用的命令缓冲要求它引用的对象活到完成为止，
// 主栅栏是缓冲尾 encodeSignalEvent 写的，比完成回调早一拍（Metal 校验层 25 局抓到 2 次「对象在命令缓冲仍需要时被销毁」）
static _Atomic uint64_t g_cb3_done;
static id<MTLSharedEvent> g_pev3; static uint64_t g_pev3_n;   // Metal 3 预载缓冲做完时写的事件：在录缓冲推进主栅栏之前等它（在录缓冲里没有编码器时也保证预载先做完）
static int be_forced_mtl3(void) { const char *e = getenv("NXGAL_BE"); return e && !strcmp(e, "mtl3"); }   // 26 上强制走 Metal 3（A/B 用，缺省关）
// 选后端：26 起缺省 Metal 4 主路径；26 以下只有 Metal 3 兼容路径（驻留集与老队列 addResidencySet 是 macOS 15 / iOS 18 起）。
// *compat = 1 表示「26 以下缺省走 Metal 3」（与 26 上强制区分：强制才打「（强制）」）。返回 GAL_BE_NONE = 系统太老。
static int gal_be_select(int *compat) {
    if (@available(macOS 26.0, iOS 26.0, *)) return be_forced_mtl3() ? GAL_BE_MTL3 : GAL_BE_MTL4;
    if (@available(macOS 15.0, iOS 18.0, *)) { if (compat) *compat = 1; return GAL_BE_MTL3; }
    return GAL_BE_NONE;
}

GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
id<MTLDevice> g_gdev;
id<MTL4CommandQueue> g_gq;
id<MTL4CommandBuffer> g_gcb;
id<MTLResidencySet> g_gres;
id<MTL4Compiler> g_gcomp;
static id<MTLSharedEvent> g_gev;
int g_gal_be;                                   // 选定的后端（gal_be.h）
static uint64_t g_gfence;                      // 最后一次提交的栅栏值
// 非录制线程读回用的一次性命令缓冲走自己的事件与计数（g_bgev / g_bgfence），不占主栅栏号。
// 原因（10-21 暗黑2 Mac 第 110 帧 InvalidResource）：主栅栏号 g_gfence + 1 是「在录命令缓冲」的身份（延后释放、临时内存、已用区间登记、gal_cb_id 都按它记），
// 渲染线程录到一半时客体线程的读回若也从 g_gfence 取号，在录命令缓冲提交时拿到的号比录制期间记下的大 1：
// 挂在旧号上的延后释放随读回完成就被放掉并移出驻留集，而在录命令缓冲里还引用着它（宽屏层重新放宽换贴图时的旧贴图即此）
static id<MTLSharedEvent> g_bgev; static uint64_t g_bgfence;
static uint64_t g_cb_fence;                     // 当前在录命令缓冲开录时的身份 g_gfence + 1：提交时核对没被别处挪动（不等即报红）
#define GAL_NALLOC 8   // 每帧约 3 次提交（出图 + Gpu 层建同步对象各刷一次）：8 个约 2–3 帧在途，CPU 编下一帧不等上一帧 GPU 做完
static id<MTL4CommandAllocator> g_galloc[GAL_NALLOC]; uint64_t g_galloc_fence[GAL_NALLOC]; static int g_galloc_cur = -1;   // 栅栏表不加 static：单测占住前几个逼挑后面的（t_nobreak 用例 17 ⑦）
static uint64_t g_galloc_used[GAL_NALLOC];
static uint32_t g_galloc_ncb[GAL_NALLOC];   // 各主分配器自上次 reset 起托过几次提交（NXGAL_CA_SHARE）
uint64_t g_ca_switch, g_ca_reuse;           // 换分配器 / 共用分配器开命令缓冲的次数（单测 / 诊断）
int gal_ca_share_test = -1;                 // 单测：≥ 0 时代替环境变量
static int ca_share(void) { if (gal_ca_share_test >= 0) return gal_ca_share_test; static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_CA_SHARE"); v = e && *e ? atoi(e) : 0; if (v < 0) v = 0; } return v; }   // 各主分配器最近一次被挑中时的帧号（闲置放掉用，见 ca_trim）
// 诊断 NXGAL_BP_DIAG=1（缺省关，帧率能耗线 10-23）：反压（gal_cb_begin 等命令分配器）拆成「等的是哪类提交」，并给 GPU 忙碌占比、每帧提交数，
// 在真机上区分：① GPU 跟不上（GPU 忙 ≈ 100%，反压只是 CPU 闲等）；② 提交太碎（读回 / 同步逼出的小提交把 8 个分配器很快轮完，GPU 并不满）；③ 别的
// 提交来由：0 其他 1 等待型（gal_finish：读回 / 等全部）2 出图 3 建同步号 4 等同步号 5 计数器 6 渲染遍收尾提交 7 外部刷（nxgal_flush）
enum { CW_N = 8 };
static int g_cwhy; static uint8_t g_galloc_why[GAL_NALLOC];
static int bp_diag(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_BP_DIAG"); v = e && *e == '1'; } return v; }
static _Atomic uint64_t g_bpd_commits[CW_N], g_bpd_gpu_ns[CW_N], g_bpd_wait_n[CW_N], g_bpd_wait_ns[CW_N];
// 预载命令缓冲（同 Ryujinx Vulkan 后端 PipelineBase.GetPreloadCommandBuffer）：写「本次提交还没用到的区间」的拷贝录进它，提交时排在在录命令缓冲之前，
// 不切开在录命令缓冲里的渲染通道。分配器与主分配器同号轮换（同一栅栏回收）
static id<MTL4CommandAllocator> g_palloc[GAL_NALLOC]; static id<MTL4CommandBuffer> g_pcb; static id<MTL4ComputeCommandEncoder> g_penc; static int g_penc_used;
static int g_gres_dirty;
// 遍前段（帧率能耗线 10-21，帧级调度的插入点）：开渲染遍时把在录命令缓冲收成一段（已有内容的话）、新开一段录这一遍，两段之间可按需插一个「遍前」命令缓冲（gal_prepass_enc）：
// 录进它的命令提交时排在本遍那段之前、上一段之后——等于在开遍之前做，不切开这一遍。各段按序进同一次提交（预载、各段、遍前段交错、在录段），同一栅栏。
// 只给「前 2 帧同序号的遍里有操作想挪到遍前」（gal_prepass_want 按本帧第几个渲染遍记）的遍分段：每个命令缓冲固定从分配器取一块
//（Mac 实测带渲染遍的约 2.27 MB、只有计算的约 0.5 MB，与录了多少命令几乎无关；分配器按高水位留着、GAL_NALLOC 个轮换）。
// 10-21 改前「最近 2 帧有任何一次想挪就每遍都分段」：暗黑3 每帧约 28 遍、挪动只有零星几次，8 个主分配器涨到 344–417 MB（Mac），
// 真机 GPU 驱动区（虚存标签 100）多 740 MB、低区 1297 → 534 MB，管线归档被低区账本拒开、现建 1 → 63。猜不中的遍照旧切遍（正确性不变），下一帧学到。
// 分配器要比历史高水位多托一个命令缓冲时先向低区账本申请（ca_admit），申请不到这一遍不分段、照旧切遍。NXGAL_PREPASS_OFF=1 关（一律录进在录流、切遍）
static void **g_segs; static int g_nsegs, g_capsegs;      // 已收的段（CFBridgingRetain 的命令缓冲，按提交序）
static int g_gcb_work;                                     // 在录段里录过编码器
static int g_pre_ok;                                       // 当前渲染遍开在段首：可以给它插遍前段
static id g_xalloc[GAL_NALLOC]; static id g_xcb, g_xenc; static int g_xenc_used;   // 遍前段：分配器（与主分配器同号轮换）、当前遍的遍前命令缓冲与计算编码器
static uint64_t g_prepass_frame = UINT64_MAX;              // 最近一次有操作想挪到遍前所在帧（单测开关 gal_prepass_test_any 用）
enum { PW_BITS = 1024 };
static uint64_t g_pw[3][PW_BITS / 64], g_pw_frame[3];       // 帧 f 里想挪到遍前的遍序号位图（f % 3 一格；格里记的不是这一帧就当空）
static uint32_t g_pass_ord, g_cur_ord = UINT32_MAX;         // 本帧已开渲染遍数、当前遍是本帧第几个
static uint64_t g_ord_frame;
static uint32_t g_cur_grp, g_grp_base; static uint64_t g_grp_frame;   // 当前渲染遍开在本帧第几个目标组（gal_pass.m g_rt_group_seq）：开遍预整理间接计数认遍用
extern uint32_t g_rt_group_seq; extern int g_icnt_hook;
uint32_t gal_pass_group(void) { return g_cur_grp; }
void gal_icnt_prebegin(uint32_t grp, id (*enc)(void));   // gal_draw.m
int gal_prepass_test_any;   // 单测：最近 2 帧有过挪动就每遍分段（用例 10–15 测挪动本身，不靠帧结构；预测另测）
uint64_t g_seg_n[2];        // 分段：开成 / 账本不给（单测 / 诊断）
static int g_ca_n;          // 本提交周期在主分配器上开过的命令缓冲数
// 每次提交最多分 SEG_CAP 段：分配器按同时存活的命令缓冲取块、按高水位留着，一次提交里分段扎堆（加载期一阵挪动）会把那个分配器撑高、再也不缩；
// 超了这一遍照旧切遍（10-21 暗黑3 Mac：按遍序号预测后 30 秒分段 241 次，主分配器仍 170 MB，关遍前段 48 MB）
enum { SEG_CAP = 4 };
static int g_ca_max;        // 单个提交周期里 g_ca_n 的最大值（诊断）
static int ca_admit(void);  // 见低区账本一节
static int64_t ca_note(int pick);
static void ca_trim(uint64_t done, int pick);
static id ca_new(void) { NSError *e = nil; return [g_gdev newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:&e]; }   // 主 / 预载分配器（起账与闲置放掉后重建共用）
static int pw_get(uint64_t f, uint32_t o) { int s = (int)(f % 3); return f && g_pw_frame[s] == f && o < PW_BITS && (g_pw[s][o >> 6] >> (o & 63) & 1); }
// 段表先腾位、再结束旧命令缓冲（P1-44）：扩不了就返回 0，调用方走「不分段」那条现成退路（同账本不给），已录的段和在录命令缓冲都不动
static int segs_room(void) {
    if (g_nsegs < g_capsegs) return 1;
    int nc = g_capsegs ? g_capsegs * 2 : 256; void **ns = gal_grow(g_segs, (size_t)nc, sizeof *g_segs, "命令段表"); if (!ns) return 0;
    g_segs = ns; g_capsegs = nc; return 1;
}
static void segs_push(id cb) { g_segs[g_nsegs++] = (void *)CFBridgingRetain(cb); }   // 调用方先 segs_room()
static void pre_close(void) { if (g_xenc) { [g_xenc endEncoding]; g_xenc = nil; } if (g_xcb) { [g_xcb endCommandBuffer]; g_xcb = nil; } }
static int prepass_off(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_PREPASS_OFF"); v = e && *e == '1'; } return v; }
// 同步号提交照上游（NXGAL_SYNC_LAZY_ALL=1，帧率能耗线 10-22 塞尔达 A/B 用）：Ryujinx Vulkan SyncManager.Create 对非严格同步号不提交（挂在当前命令缓冲上），
// 有人等才提交（WaitSync 打断 GPU 线程刷）；严格的当场提交。缺省（关）：只在渲染遍里挂起，遍外当场提交，挂起的在这一遍收尾时提交。
// 塞尔达真机每帧约 16.7 次提交、主分配器环 8 个只够领先 GPU 半帧（botw_1022053636_1：编码线程每帧等分配器 8.9 ms）
// 同局交替（S2A_ALT，runtime/src/alt.c；帧率能耗线 10-24 巫师3 提交碎片：每帧 4.1 次真提交里 60% 来自遍外建同步号）：NXGAL_SYNC_LAZY_ALL=1 且在交替时，
//   关段照缺省（遍外当场提交）、开段照上游；不交替（-1）就是一直开。弱定义：没链原生层（GAL 单测）时恒 -1
__attribute__((weak)) int s2a_alt_phase(void) { return -1; }
int g_sync_lazy_all = -1;   // 单测可直接置
static int sync_lazy_all(void) {
    if (g_sync_lazy_all < 0) { const char *e = getenv("NXGAL_SYNC_LAZY_ALL"); g_sync_lazy_all = e && *e == '1'; }
    return g_sync_lazy_all && s2a_alt_phase() != 0; }
static void commit_site_note(void);   // 诊断 NXGAL_COMMIT_WHY（见 wait_site_note 后）
// 严格同步号当场提交（缺省关；单测可直接置 g_sync_strict_commit）。两个开关任一打开：
//   NXGAL_SYNC_STRICT_COMMIT=1：只开这一项（10-22 帧率能耗线拆出：塞尔达游戏线程写 GPU 改过的页先回写，等懒同步号时连带等后录进同一命令缓冲的整帧渲染；
//     同包 A/B 读回 17160 → 8468 ms、帧率 27.81 → 27.59 不退，当时用的是下一个开关，同时改了同步点推进，不是纯单变量）；
//   S2A_SYNCPT_HOSTSYNC=1：与 Ryujinx 0151「同步点等主机同步做完再推进」一起开
int g_sync_strict_commit = -1;
static int sync_strict_commit(void) {
    if (g_sync_strict_commit < 0) { const char *e = getenv("S2A_SYNCPT_HOSTSYNC"), *c = getenv("NXGAL_SYNC_STRICT_COMMIT"); g_sync_strict_commit = (e && *e == '1') || (c && *c == '1'); }
    return g_sync_strict_commit; }
static id g_genc; static int g_genc_kind;       // 当前编码器：1 渲染 2 拷贝 / 计算
// 当前渲染遍里有操作想挪到遍前：记下本帧这个遍序号（之后 2 帧同序号的遍分段）
void gal_prepass_want(void) {
    g_prepass_frame = g_gp_frame;
    if (g_genc_kind != 1 || g_cur_ord >= PW_BITS) return;
    int s = (int)(g_gp_frame % 3);
    if (g_pw_frame[s] != g_gp_frame) { memset(g_pw[s], 0, sizeof g_pw[s]); g_pw_frame[s] = g_gp_frame; }
    g_pw[s][g_cur_ord >> 6] |= 1ull << (g_cur_ord & 63);
}
static int g_genc_used;                          // 拷贝编码器里已录了几条（第二条起前面加编码器内屏障）
void (*gal_on_enc_end)(void);
uint64_t g_gp_t[GP_N], g_gp_n[GP_N];
uint64_t g_rs_n[RS_N], g_rs_b[RS_N], g_rs_t[RS_N];
int g_gp_time;
_Atomic uint64_t g_gp_gpu_ns, g_gp_cmdbufs;
uint64_t g_gp_frame = 1; int g_gp_commit_present;
static _Atomic uint64_t g_fr_acc[8], g_last_fr_ns, g_last_fr;
NXGAL_API double nxgal_last_gpu_ms(uint64_t *frame) { uint64_t f = g_last_fr; if (frame) *frame = f; return f ? g_last_fr_ns / 1e6 : 0; }
// 测量用：给本进程的 Metal 3 命令缓冲（MoltenVK 用的那种，不是本渲染器的 Metal 4）挂提交钩子，GPU 时间累计进同一组计数（out[2*GP_N]）。
// 只给参照渲染器量 GPU 时间用（galreplay perf GALREPLAY_PERF_REF=1）；返回 1 = 已挂
GAL_MTL4_ZONE_END
#include <objc/runtime.h>
GAL_MTL4_ZONE_BEGIN
NXGAL_API int32_t nxgal_perf_hook_mtl3(void) {
    static int done; if (done) return 1;
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [d newCommandQueue];
        NSMutableSet *classes = [NSMutableSet set];
        [classes addObject:[[q commandBuffer] class]]; [classes addObject:[[q commandBufferWithUnretainedReferences] class]];
        for (Class c in classes) {
            Method m = class_getInstanceMethod(c, @selector(commit)); if (!m) continue;
            IMP orig = method_getImplementation(m);
            IMP n = imp_implementationWithBlock(^(id self) {
                [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> b) {
                    if (b.GPUEndTime > b.GPUStartTime) g_gp_gpu_ns += (uint64_t)((b.GPUEndTime - b.GPUStartTime) * 1e9);
                    g_gp_cmdbufs++;
                }];
                ((void (*)(id, SEL))orig)(self, @selector(commit));
            });
            method_setImplementation(m, n);
        }
    }
    done = 1; return 1;
}
// ---------- 按遍拆账（诊断）：NXGAL_PERF_PASSCOMMIT=1 每结束一个渲染编码器就提交，命令缓冲 = 一遍，GPU 时间带标签记进环形表 ----------
uint32_t g_pass_w, g_pass_h, g_pass_fmt, g_pass_draws, g_pass_kind;   // 当前（在录）这遍的标签；kind 1 渲染 2 拷贝 / 计算
uint64_t g_pass_ld, g_pass_st;                                         // 这遍附件读入 / 存回字节
static uint64_t g_pass_ka, g_pass_kb; static int g_pass_kset;           // 这遍首条绘制 / 派发的着色器键（按遍汇总 pass_agg 用）
static void *g_end_pc[3], *g_pass_why[3];   // 渲染编码器最近一次结束的调用链 / 本遍开遍前上一遍收于哪（按遍汇总）
extern int g_pass_cont;                    // 本遍与上一遍附件：1 完全相同 2 部分共用 0 无关（gal_pass.m）
static uint64_t g_rw_total, g_wait_ns_total;                           // 逐帧累计（nxgal_frame_totals）：附件读写字节、CPU 等 GPU 纳秒（读回 / 同步号：要 GPU 的结果）
// 命令分配器环反压（编下一帧要等最老一帧在 GPU 上做完 = GPU 跟不上）的等待单记：它是 GPU 瓶颈、不是读回，混进 rb_us 会把 GPU 瓶颈误报成读回阻塞
// （10-21 暗黑2 双线程后 18 → 25.7 帧/秒、瓦数降，rb_us 却 21 → 41 秒 / 60 秒，闸门报「读回阻塞严重退步」）
static uint64_t g_bp_ns_total;
static void gal_wait_acc(uint64_t fence, uint64_t *acc);
#define PASS_RING 4096
static struct { uint32_t w, h, fmt, draws, kind; uint64_t ns, ld, st; } g_pass_ring[PASS_RING];
static _Atomic uint32_t g_pass_n;
static int g_passcommit = -1, g_in_commit;
NXGAL_API int32_t nxgal_perf_passes(uint64_t *out, int32_t max, int32_t reset) {   // 每条 8 个 u64：宽 高 格式 绘制数 类别 GPU 纳秒 附件读入字节 存回字节；返回条数
    uint32_t n = g_pass_n < PASS_RING ? g_pass_n : PASS_RING; if ((int32_t)n > max) n = (uint32_t)max;
    for (uint32_t i = 0; i < n; i++) { uint64_t *o = out + 8 * i; o[0] = g_pass_ring[i].w; o[1] = g_pass_ring[i].h; o[2] = g_pass_ring[i].fmt; o[3] = g_pass_ring[i].draws; o[4] = g_pass_ring[i].kind; o[5] = g_pass_ring[i].ns; o[6] = g_pass_ring[i].ld; o[7] = g_pass_ring[i].st; }
    if (reset) g_pass_n = 0;
    return (int32_t)n;
}
// 逐帧累计（常开、不清零；调用方按上屏差分写 frames.tsv）：0 绘制 1 渲染遍 2 上传（预载拷贝 + 内联上传）3 附件读写字节 4 CPU 等 GPU 纳秒
uint64_t gal_draw_count(void);
// 按 QoS 起一条原生线程跑托管入口（方案 8a-3 线程按核）：.NET 自己建的线程带显式调度参数，pthread_set_qos_class_self_np 返回 EPERM（10-19 实测），
// 所以宿主侧要按核分配的长期线程（渲染循环等）由这里用 pthread_attr_set_qos_class_np 建。fn 是托管 UnmanagedCallersOnly 入口。返回 0 成功
typedef struct { void (*fn)(void *); void *arg; char name[64]; } gal_targ;
static void *gal_thread_tramp(void *p) {
    gal_targ t = *(gal_targ *)p; free(p);
    pthread_setname_np(t.name);
    t.fn(t.arg); return NULL;
}
NXGAL_API int32_t nxgal_thread_start(void (*fn)(void *), void *arg, int32_t qos, const char *name) {
    gal_targ *t = malloc(sizeof *t); if (!t) return -1; t->fn = fn; t->arg = arg; snprintf(t->name, sizeof t->name, "%s", name ? name : "nxgal");
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_set_qos_class_np(&a, (qos_class_t)qos, 0); pthread_attr_setstacksize(&a, 8u << 20);
    pthread_t th; int rc = pthread_create(&th, &a, gal_thread_tramp, t);
    pthread_attr_destroy(&a); if (rc) { free(t); return rc; }
    pthread_detach(th); return 0;
}
@interface GalJoinThread : NSObject { @public pthread_t thread; dispatch_semaphore_t done; _Atomic int joining; int result; } @end
@implementation GalJoinThread @end
NXGAL_API int32_t nxgal_thread_start_joinable(void (*fn)(void *), void *arg, int32_t qos, const char *name, uintptr_t *thread) {
    *thread = 0;
    gal_targ *t = malloc(sizeof *t); if (!t) return ENOMEM;
    t->fn = fn; t->arg = arg; snprintf(t->name, sizeof t->name, "%s", name ? name : "nxgal");
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_set_qos_class_np(&a, (qos_class_t)qos, 0); pthread_attr_setstacksize(&a, 8u << 20);
    GalJoinThread *join = [GalJoinThread new]; join->done = dispatch_semaphore_create(0);
    int rc = pthread_create(&join->thread, &a, gal_thread_tramp, t);
    pthread_attr_destroy(&a); if (rc) { free(t); return rc; }
    *thread = (uintptr_t)CFBridgingRetain(join); return 0;
}
NXGAL_API int32_t nxgal_thread_join(uintptr_t thread) {
    if (!thread) return EINVAL;
    GalJoinThread *join = (__bridge GalJoinThread *)(void *)thread;
    if (!atomic_exchange(&join->joining, 1)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            join->result = pthread_join(join->thread, NULL);
            dispatch_semaphore_signal(join->done);
        });
    }
    // A managed completion event precedes pthread TLS destructors. Keep the
    // native handle and all session owners alive if those destructors hang.
    if (dispatch_semaphore_wait(join->done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) return ETIMEDOUT;
    int result = join->result;
    if (!result) CFBridgingRelease((void *)thread);
    else dispatch_semaphore_signal(join->done);
    return result;
}
// NXGAL_PERF_TIME=1：本帧渲染器顶层分段合计 > 15 ms（NXGAL_PERF_TIME_MS 可改）时打一行逐段拆账（各段 > 0.5 ms 的时间与次数）+ 建资源与驻留集记账（全列、不截断）。每帧调一次（渲染线程）。
// 分段有嵌套：pso / pso_build / bind / dyn / xcwait 都在 draw 里（pso_build 又在 pso 里），合计只加顶层段，嵌套段照列、标「⊂draw」——
// 原先全加，10-20 动森第 176 帧把约 90 ms 的建管线加了三遍，报成 284 ms、误判「约 180 ms 不在渲染器」（同帧 frames.tsv wall 132 ms）
uint64_t g_set_kind[3];   // bind_stage 参数集：[0] 整块重写 [1] 增量 [2] 照用（gal_draw.m 计）
static void frame_breakdown(void) {
    static const char *const nm[GP_N] = {"draw", "pso", "pso_build", "bind", "dyn", "upload", "clear", "commit", "wait", "xcwait", "present", "copy", "renc", "cenc", "preload", "inlineup", "setreuse", "mirrorw", "mirror", "idxalign", "pso_open", "pso_arch"};
    static const char *const rn[RS_N] = {"建贴图", "上传暂存", "建缓冲", "驻留集加入", "驻留集提交"};
    static uint64_t pt[GP_N], pn[GP_N], qn[RS_N], qb[RS_N], qt[RS_N], fno, sk0[3];
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    static const uint8_t nested[GP_N] = {[GP_PSO] = 1, [GP_PSO_BUILD] = 1, [GP_BIND] = 1, [GP_DYN] = 1, [GP_XCWAIT] = 1, [GP_PSO_OPEN] = 1, [GP_PSO_ARCH] = 1};
    uint64_t sum = 0; fno++;
    for (int k = 0; k < GP_N; k++) if (!nested[k]) sum += g_gp_t[k] - pt[k];
    static double thr = -1; if (thr < 0) { const char *v = getenv("NXGAL_PERF_TIME_MS"); thr = v ? atof(v) : 15; }   // 打印阈值毫秒（缺省 15；设 0 每帧都打，A/B 比分段用）
    if (sum * tb.numer / tb.denom > thr * 1e6) {
        char b[2048]; int o = snprintf(b, sizeof b, "帧 %llu 渲染器顶层分段合计 %.1f ms：", (unsigned long long)fno, sum * tb.numer / tb.denom / 1e6);
        for (int k = 0; k < GP_N; k++) { uint64_t d = (g_gp_t[k] - pt[k]) * tb.numer / tb.denom;
            if (d > 500000) o += snprintf(b + o, sizeof b - (size_t)o, " %s%s %.1f ms×%llu", nm[k], nested[k] ? "⊂draw" : "", d / 1e6, (unsigned long long)(g_gp_n[k] - pn[k])); }
        for (int k = 0; k < RS_N; k++) o += snprintf(b + o, sizeof b - (size_t)o, "｜%s %llu 次 %.1f MB %.2f ms", rn[k], (unsigned long long)(g_rs_n[k] - qn[k]),
            (g_rs_b[k] - qb[k]) / 1048576.0, (g_rs_t[k] - qt[k]) * tb.numer / tb.denom / 1e6);
        o += snprintf(b + o, sizeof b - (size_t)o, "｜参数集 整写 %llu / 增量 %llu / 照用 %llu", (unsigned long long)(g_set_kind[0] - sk0[0]), (unsigned long long)(g_set_kind[1] - sk0[1]), (unsigned long long)(g_set_kind[2] - sk0[2]));
        GLOG("%s", b);
    }
    memcpy(sk0, g_set_kind, sizeof sk0);
    memcpy(pt, g_gp_t, sizeof pt); memcpy(pn, g_gp_n, sizeof pn); memcpy(qn, g_rs_n, sizeof qn); memcpy(qb, g_rs_b, sizeof qb); memcpy(qt, g_rs_t, sizeof qt);
}
NXGAL_API void nxgal_frame_totals(uint64_t out[6]) {
    out[0] = gal_draw_count(); out[1] = g_gp_n[GP_RENC]; out[2] = g_gp_n[GP_PRELOAD] + g_gp_n[GP_INLINEUP];
    out[3] = g_rw_total + g_pass_ld + g_pass_st; out[4] = __atomic_load_n(&g_wait_ns_total, __ATOMIC_RELAXED); out[5] = __atomic_load_n(&g_bp_ns_total, __ATOMIC_RELAXED);
    if (g_gp_time) frame_breakdown();
}
NXGAL_API int32_t nxgal_perf_read(uint64_t *out, int32_t n, int32_t reset) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    for (int k = 0; k < GP_N && 2 * k + 1 < n; k++) { out[2 * k] = g_gp_t[k] * tb.numer / tb.denom; out[2 * k + 1] = g_gp_n[k]; }
    if (n > 2 * GP_N + 1) { out[2 * GP_N] = g_gp_gpu_ns; out[2 * GP_N + 1] = g_gp_cmdbufs; }
    if (reset) { memset(g_gp_t, 0, sizeof g_gp_t); memset(g_gp_n, 0, sizeof g_gp_n); g_gp_gpu_ns = 0; g_gp_cmdbufs = 0; }
    return GP_N;
}

// ---------- 导出入口全局锁 ----------
GAL_MTL4_ZONE_END
#include <os/lock.h>
GAL_MTL4_ZONE_BEGIN
// 入口中途换命令缓冲检查：同一入口里先登记了已用区间 / 分了临时内存（都挂在当时的命令缓冲上），中途提交后又开新命令缓冲，
// 之后录的命令会依赖已随旧命令缓冲走掉的登记 / 内存（登记丢 → 写入误走预载；临时内存随旧栅栏回收）。提交只许在入口之间（同 Flush）
uint32_t g_entry_dirty; static int g_entry_committed; uint64_t g_entry_midcb;
static os_unfair_lock g_api_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic(pthread_t) g_api_owner; static int g_api_depth;
uint64_t g_api_contended;
int gal_api_enter(void) {
    pthread_t me = pthread_self();
    if (g_api_owner == me) { g_api_depth++; return 1; }
    if (!os_unfair_lock_trylock(&g_api_lock)) { g_api_contended++; os_unfair_lock_lock(&g_api_lock); }
    g_entry_dirty = 0; g_entry_committed = 0; g_api_owner = me; g_api_depth = 1; return 1;
}
// 懒同步（帧级调度，帧率能耗线 10-21；NXGAL_PREPASS_OFF=1 退回）：渲染遍开着时来的 create_sync 不当场提交（那会切开这一遍），登记成挂起（栅栏 0），
// 这一遍自然收尾时（gal_enc_end → 出入口提交）一并提交、回填栅栏；有人等它就当场提交（wait_sync）。塞尔达每帧 3–4 次「派发后紧跟建同步号」，
// 派发挪到遍前段后切遍落在同步号上
static int g_sync_pending;
uint64_t g_sync_lazy;   // 挂起过的同步号数（单测 / 诊断）
static void sync_fill(uint64_t f);
static int g_passcommit_due;   // 诊断 NXGAL_PERF_PASSCOMMIT：本次入口里结束过编码器，出入口时提交（见 gal_enc_end）；也用于长命令缓冲切分（GAL_CB_SPLIT_DRAWS）
static uint32_t g_cb_draws;     // 当前命令缓冲里的绘制 + 派发数（gal_hang_note 累计，提交清零）
// 长命令缓冲切分（10-20 iPhone 动森进岛第一帧 6945 绘制 / 369 遍进了一个命令缓冲，GPU 跑超 3 秒被看门狗判卡死）：累计这么多条后，在下一次结束渲染编码器处
// （不在遍中间切，不增加附件读写）出入口时提交，命令缓冲变短、栅栏持续前进。NXGAL_CB_SPLIT_DRAWS=<n> 改，0 关
// GPU 空闲即提交（10-23 原生层线 (b')，缺省关；NXGAL_IDLE_COMMIT=<最少绘制数> 开）：渲染遍收尾时 GPU 已做完全部已提交的活
//   （signaledValue ≥ 最后提交的栅栏）、在录命令缓冲里攒够这么多条绘制，就在出入口提交——GPU 闲着时不让它干等录制，
//   游戏随后等读回时，前面的活多半已经做完。GPU 忙时一笔不加（同时存活的命令缓冲不涨，命令分配器高水位不涨）。
//   最少绘制数防 GPU 很轻的游戏每遍都提交、把提交开销堆到 CPU 上。和长缓冲切分、懒同步共用 g_passcommit_due：一次出口最多提交一次
int gal_idle_commit_test = -1;   // 单测：≥ 0 时代替环境变量
static uint64_t g_idle_commits;
static uint32_t idle_commit_min(void) {
    if (gal_idle_commit_test >= 0) return (uint32_t)gal_idle_commit_test;
    static int64_t n = -1; if (n < 0) { const char *v = getenv("NXGAL_IDLE_COMMIT"); n = v && *v ? atoll(v) : 0; } return (uint32_t)n;
}
// 按编码器数 / 分配器字节切分（帧率能耗线 10-24，正确性修复、缺省开）：怪猎一帧 700–1047 遍、每遍绘制很少，按绘制数切不动，
//   一个命令缓冲托上千个编码器，命令分配器涨到 540–738 MB（对照 156–182 MB），Metal 驱动 AGX DataBufferAllocator::grow 中止进程（原生层线 3 局同签名）。
//   在录命令缓冲的编码器数到 NXGAL_CB_SPLIT_ENCS（缺省 256）、或主分配器到 NXGAL_CB_SPLIT_MB（缺省 32 MB）时，同长缓冲切分：在下一次结束编码器处、出入口时提交
//   （入口之间提交 = 一次 Flush，不丢绘制、不改顺序）。8 个主分配器轮换，最坏合计约 8 × 上限；0 = 不按这一项切
int gal_cb_split_encs_test = -1, gal_cb_split_bytes_test = -1;   // 单测：≥ 0 时代替环境变量（字节）
static uint32_t g_cb_encs; uint64_t g_cb_cap_commits;
static uint32_t cb_split_encs(void) { if (gal_cb_split_encs_test >= 0) return (uint32_t)gal_cb_split_encs_test; static int64_t n = -1; if (n < 0) { const char *v = getenv("NXGAL_CB_SPLIT_ENCS"); n = v && *v ? atoll(v) : 256; } return (uint32_t)n; }
static uint64_t cb_split_bytes(void) { if (gal_cb_split_bytes_test >= 0) return (uint64_t)gal_cb_split_bytes_test; static int64_t n = -1; if (n < 0) { const char *v = getenv("NXGAL_CB_SPLIT_MB"); n = (v && *v ? atoll(v) : 32) << 20; } return (uint64_t)n; }
int gal_cb_split_draws_test = -1;   // 单测：≥ 0 时代替环境变量
static uint32_t cb_split_draws(void) { if (gal_cb_split_draws_test >= 0) return (uint32_t)gal_cb_split_draws_test; static int64_t n = -1; if (n < 0) { const char *v = getenv("NXGAL_CB_SPLIT_DRAWS"); n = v && *v ? atoll(v) : 1000; } return (uint32_t)n; }
void gal_api_leave(int *tok) {
    (void)tok;
    if (g_api_depth == 1 && g_passcommit_due) { g_passcommit_due = 0; g_cwhy = 6; gal_commit(); }
    if (--g_api_depth == 0) { g_api_owner = 0; os_unfair_lock_unlock(&g_api_lock); }
}

// ---------- 热状态 ----------
// ProcessInfo.thermalState：初始化时一行、之后每 10 秒一行、变化时立即一行（系统通知），行内带起局后秒数。
// 状态一变就记，故任一时刻（如「S2A 标记 MARK」那行）的热状态 = 它之前最近一条「[gal] 热状态」行。能耗局 / 闪退现场（是否过热被杀）用；缺省开，零开销（10 秒一次定时器）
static void thermal_log(const char *why) {
    static const char *const nm[] = {"nominal 正常", "fair 偏热", "serious 严重", "critical 危急"};
    static uint64_t t0; static mach_timebase_info_data_t tb; if (!tb.denom) { mach_timebase_info(&tb); t0 = mach_absolute_time(); }
    NSInteger st = NSProcessInfo.processInfo.thermalState;
    GLOG("热状态 %s（%s，起局后 %.0f 秒）", st >= 0 && st < 4 ? nm[st] : "未知", why, (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9);
}
static void thermal_start(void) {
    static dispatch_source_t tm; static id obs; if (tm) return;
    thermal_log("初始化");
    tm = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(tm, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(tm, ^{ thermal_log("每 10 秒"); });
    dispatch_resume(tm);
    obs = [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; thermal_log("变化"); }];
}

// ---------- 分配失败现场 ----------
// 建缓冲 / 暂存失败时附的读数：分清「进程内存到顶」（实占贴近上限、余量≈0）与「Metal 自己拒」（余量还多）
#include <mach/mach.h>
#if TARGET_OS_IOS
#include <os/proc.h>
#endif
GAL_MTL4_ZONE_END
#include <dlfcn.h>
GAL_MTL4_ZONE_BEGIN
// 另附低区空洞（原生层 runtime/src/vawin.c s2a_low_holes，运行时查找；单测 / 回放不链原生层时读 0）：
// iPhone 上 64 GB 窗口占满后，≤256 MB 的共享缓冲只能进 4 GB 到窗口底之间的空洞，空洞耗尽时 Metal 拒建而物理内存余量还多
const char *gal_mem_note(void) {
    static _Thread_local char b[384];
    uint64_t ht = 0, hl = 0; void (*holes)(uint64_t *, uint64_t *) = (void (*)(uint64_t *, uint64_t *))dlsym(RTLD_DEFAULT, "s2a_low_holes");
    if (holes) holes(&ht, &hl);
    task_vm_info_data_t vi; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    double fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) == KERN_SUCCESS ? vi.phys_footprint / 1048576.0 : -1;
#if TARGET_OS_IOS
    double av = os_proc_available_memory() / 1048576.0;
#else
    double av = -1;
#endif
    snprintf(b, sizeof b, "进程实占 %.0f MB，可用余量 %.0f MB（-1 = 本平台无此读数），Metal 已分配 %.0f MB，低区空洞合计 %llu MB、最大一块 %llu MB（0 = 无原生层读数）",
             fp, av, g_gdev ? g_gdev.currentAllocatedSize / 1048576.0 : -1, (unsigned long long)(ht >> 20), (unsigned long long)(hl >> 20));
    return b;
}
void *gal_grow(void *p, size_t n, size_t elem, const char *what) {
    void *q = elem && n <= SIZE_MAX / elem ? realloc(p, n * elem) : NULL;
    if (!q) { static int nfail; if (nfail++ < 8) GLOG("【红】%s扩到 %zu 项（每项 %zu 字节）失败（第 %d 次）：保留原表、这次不加项；%s", what, n, elem, nfail, gal_mem_note()); }
    return q;
}

// ---------- 驻留集 ----------
void gal_res_add(id<MTLAllocation> a) { if (!a) return; RS_SCOPE(RS_RESADD); [g_gres addAllocation:a]; g_gres_dirty = 1; }
void gal_res_remove(id<MTLAllocation> a) { if (!a) return; [g_gres removeAllocation:a]; g_gres_dirty = 1; }

// ---------- 延后释放：挂在「当前在录命令提交后的栅栏」上 ----------
typedef struct { void *obj; uint64_t fence; int res; } dead_ent;
static dead_ent *g_dead; static int g_ndead, g_capdead;
void gal_release_later(id obj, int residency) {
    if (!obj) return;
    if (g_ndead == g_capdead) {   // 审计 P1-67：表扩不动就不登记、对象一直留着不放（漏一个对象，换不提前放掉 GPU 可能还在用的）
        int nc = g_capdead ? g_capdead * 2 : 256; dead_ent *nd = gal_grow(g_dead, (size_t)nc, sizeof *g_dead, "延后释放表");
        if (!nd) { (void)(__bridge_retained void *)obj; return; }
        g_dead = nd; g_capdead = nc;
    }
    // 在录命令缓冲（若有）提交时的栅栏 = g_gfence + 1；没有在录的，最后一次提交完成即可放
    g_dead[g_ndead++] = (dead_ent){(__bridge_retained void *)obj, g_gcb || g_cb3 ? g_gfence + 1 : g_gfence, residency};   // Metal 3 在录的是 g_cb3
}
static void dead_reap(void) {
    uint64_t done = g_gev.signaledValue; int keep = 0;
    if (g_gal_be != GAL_BE_MTL4) { uint64_t c = atomic_load(&g_cb3_done); if (c < done) done = c; }   // Metal 3：按完成回调（见 g_cb3_done）
    for (int i = 0; i < g_ndead; i++) {
        if (g_dead[i].fence <= done) { id o = (__bridge_transfer id)g_dead[i].obj; if (g_dead[i].res) gal_res_remove(o); o = nil; }
        else g_dead[keep++] = g_dead[i];
    }
    g_ndead = keep;
}

// ---------- 临时数据：4 MB 共享缓冲成块，按提交栅栏回收 ----------
#define TR_CHUNK (4u << 20)
typedef struct { id<MTLBuffer> buf; uint64_t fence; uint8_t *cpu; uint64_t gpu; uint32_t len; } tr_chunk;   // fence = 0：在用（当前提交）；cpu / gpu / len：建块时记下的 contents / gpuAddress / length（块内恒定，热路径不再取强引用、不发 objc 消息）
static tr_chunk *g_tr; static int g_ntr; static int g_tr_cur = -1; static uint32_t g_tr_off;
static tr_chunk *g_tg; static int g_ntg; static int g_tg_cur = -1; static uint32_t g_tg_off;   // GPU 临时池（私有存储，见 gal_transient_gpu）
// GPU 临时池按帧回收的窗口（见 tg_trim）：每 TG_EPOCH 帧一段、留 TG_NEP 段峰值；池总字节；累计回收；全程峰值
#define TG_EPOCH 30
#define TG_NEP 8
static uint64_t g_tg_epk[TG_NEP], g_tg_ep = UINT64_MAX, g_tg_total, g_tg_freed_n, g_tg_freed_b, g_tg_peak_all;
uint64_t gal_cb_id(void) { return g_gfence + 1; }   // 在录（或下一个）命令缓冲提交后的栅栏值，作「本次提交」的标识
uint64_t gal_done_fence(void) { return g_gev.signaledValue; }
// 单测故障注入（tests/t_draw.m）：非 0 时换块路径当作建块失败（不复用旧块、不建新块）；只在换块慢路径上读，热路径零开销
int gal_tr_test_fail;
int gal_newbuf_test_fail;
// 单测：两池累计请求字节（分界核对：只给 GPU 用的走 GPU 池、CPU 要写的走共享池）
static uint64_t g_tr_req, g_tg_req;
void gal_pool_req(uint64_t *shared, uint64_t *gpu) { *shared = g_tr_req; *gpu = g_tg_req; }
void *gal_transient(uint32_t size, uint32_t align, uint64_t *gpu) {
    g_entry_dirty = 1; g_tr_req += size;
    if (!align) align = 16;
    uint32_t off = (g_tr_off + align - 1) & ~(align - 1);
    if (g_tr_cur < 0 || off + size > g_tr[g_tr_cur].len) {
        if (g_tr_cur >= 0) g_tr[g_tr_cur].fence = UINT64_MAX;   // 用满：挂到本次提交的栅栏（提交时改成真值）
        uint64_t done = g_gev.signaledValue; int pick = -1;
        for (int i = 0; i < g_ntr && !gal_tr_test_fail; i++) if (g_tr[i].fence && g_tr[i].fence != UINT64_MAX && g_tr[i].fence <= done && g_tr[i].len >= size) { pick = i; break; }
        if (pick < 0) {
            NSUInteger len = size > TR_CHUNK ? size : TR_CHUNK;
            id<MTLBuffer> b = gal_tr_test_fail ? nil : [g_gdev newBufferWithLength:len options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
            // 建不出：报红返回 NULL（*gpu = 0），调用方跳过本次绘制 / 清屏 / 拷贝；不把空块记进块表（原先记 nil 块、返回 NULL + 偏移，
            // 10-20 丝之歌测试设备2 第 24 帧 clr_draw 往 NULL 写清屏参数 SIGSEGV）
            if (!b) {
                static int nfail; uint64_t inflight = 0, total = 0;
                for (int i = 0; i < g_ntr; i++) { total += g_tr[i].buf.length; if (!g_tr[i].fence || g_tr[i].fence == UINT64_MAX || g_tr[i].fence > done) inflight++; }
                if (nfail++ < 8) GLOG("【红】临时内存：建 %lu 字节共享块失败（第 %d 次；已有 %d 块共 %llu MB，在途 %llu 块；已完成栅栏 %llu / 已提交 %llu）：%s",
                                      (unsigned long)len, nfail, g_ntr, (unsigned long long)(total >> 20), (unsigned long long)inflight,
                                      (unsigned long long)done, (unsigned long long)g_gfence, gal_mem_note());
                g_tr_cur = -1; g_tr_off = 0; *gpu = 0;
                return NULL;
            }
            // 块表扩不了（P1-44）：同上面建块失败，报红返回 NULL；新块 b 不进表、随作用域放掉，旧表原样
            __typeof__(g_tr) nt = gal_grow(g_tr, (size_t)g_ntr + 1, sizeof *g_tr, "临时内存块表");
            if (!nt) { g_tr_cur = -1; g_tr_off = 0; *gpu = 0; return NULL; }
            g_tr = nt; memset((void *)&g_tr[g_ntr], 0, sizeof *g_tr);
            gal_res_add(b); g_tr[g_ntr].buf = b; g_tr[g_ntr].cpu = (uint8_t *)b.contents; g_tr[g_ntr].gpu = b.gpuAddress; g_tr[g_ntr].len = (uint32_t)b.length; pick = g_ntr++;
        }
        g_tr[pick].fence = 0; g_tr_cur = pick; off = 0;
    }
    g_tr_off = off + size;
    // 热路径（每次绘制几次）：读建块时记下的地址，不取强引用、不发消息（10-23 原生层线：Mac 塞尔达回放绘制路径 objc 引用计数约 1/4 出在这里）
    if (!gal_draw_fixed()) { id<MTLBuffer> b = g_tr[g_tr_cur].buf; *gpu = b.gpuAddress + off; return (uint8_t *)b.contents + off; }   // 旧路径（A/B）
    *gpu = g_tr[g_tr_cur].gpu + off;
    return g_tr[g_tr_cur].cpu + off;
}
void gal_buf_va_note(char *o, size_t n);
void gal_tg_note(char *o, size_t n);
// ---------- 线程自动释放池轮换（帧率能耗线 10-24）----------
// C# 起的线程（Metal 编码线程 S2A.GPU、GPU 模拟线程 S2A.GPU.Emu）没有释放池：GAL 入口里被自动释放的对象挂在线程的隐式池上、直到线程退出才放。
// 实测（t_pool）：无池线程上「建 2 MB 缓冲 → 清 → 读回 → 删」50 次，Metal 已分配 +100 MB 全不回落；不读回的对照 +0（读回入口里有一次自动释放）。
// iPhone 上共享缓冲在低区映射（标签 100），这样漏掉的缓冲一直占低区。轮换 = 弹出本线程上次推入的池（放掉这期间的自动释放对象）再推一个；
// 只在入口最外层调（弹出会连带弹掉其上的池，嵌在 @autoreleasepool 里调会弄坏外层块）；主线程有 UIKit 的池，不做事
void *objc_autoreleasePoolPush(void); void objc_autoreleasePoolPop(void *);
uint64_t g_pool_cycles;   // 单测 / 诊断
NXGAL_API void nxgal_pool_cycle(void) {
    static __thread void *t;
    if (pthread_main_np()) return;
    if (t) objc_autoreleasePoolPop(t);
    t = objc_autoreleasePoolPush(); g_pool_cycles++;
}
extern uint64_t g_ca_cap_refuse;   // 命令分配器总额度拒绝分段次数（见 ca_admit）
extern uint64_t g_ca_trim_n, g_ca_trim_bytes;   // 命令分配器闲置放掉（见 ca_trim）
extern uint64_t g_cb_cap_commits;   // 按编码器数 / 分配器字节切分的提交次数（见 cb_split_encs）
NXGAL_API void nxgal_va_note(char *o, size_t n) {   // 地址账（诊断）：临时内存块 / 待放对象 / 驻留集 / Metal 已分配 + 缓冲账
    uint64_t tot = 0, big = 0; int nbig = 0; for (int i = 0; i < g_ntr; i++) { uint64_t l = g_tr[i].buf.length; tot += l; if (l > TR_CHUNK) { big += l; nbig++; } }
    uint64_t tg = 0; for (int i = 0; i < g_ntg; i++) tg += g_tg[i].buf.length;
    char tgn[160]; gal_tg_note(tgn, sizeof tgn);
    char bn[900]; gal_buf_va_note(bn, sizeof bn);
    // 命令分配器（命令缓冲的命令内存，驱动映射进进程、虚存标签 100 IOAccelerator，不计入 Metal 已分配）：主 / 预载 / 遍前段各 GAL_NALLOC 个，按高水位留着
    uint64_t ca[3] = {0, 0, 0};
    for (int i = 0; i < GAL_NALLOC; i++) { ca[0] += g_galloc[i].allocatedSize; ca[1] += g_palloc[i].allocatedSize; ca[2] += (uint64_t)[g_xalloc[i] allocatedSize]; }
    // 各主分配器 MB / 距上次被挑中的帧数：看稳态实际轮转几个（闲置放掉 NXGAL_CA_TRIM 的依据）
    char cad[GAL_NALLOC * 16 + 128]; int cl = 0;
    for (int i = 0; i < GAL_NALLOC && cl < (int)sizeof cad; i++) cl += snprintf(cad + cl, sizeof cad - cl, "%s%.0f/%llu", i ? " " : "", g_galloc[i].allocatedSize / 1048576.0, (unsigned long long)(g_gp_frame - g_galloc_used[i]));
    if (cl < (int)sizeof cad) snprintf(cad + cl, sizeof cad - cl, "；闲置放掉 %llu 次 %.0f MB；按编码器数 / 字节切分提交 %llu 次", (unsigned long long)g_ca_trim_n, g_ca_trim_bytes / 1048576.0, (unsigned long long)g_cb_cap_commits);
    snprintf(o, n, "临时内存 %d 块 %llu MB（大于 4 MB 的 %d 块 %llu MB）、GPU 临时内存（私有）%d 块 %llu MB（%s）；待放对象 %d；驻留集 %.0f MB；Metal 已分配 %.0f MB；命令分配器 主 %.0f / 预载 %.0f / 遍前 %.0f MB（遍前分段 %llu 次、账本不给 %llu 次、总额度不给 %llu 次、单次提交最多 %d 个主命令缓冲；各主分配器 MB/闲置帧 %s；提交 %llu 次，其中 GPU 空闲即提交 %llu 次）；%s", g_ntr, (unsigned long long)(tot >> 20), nbig, (unsigned long long)(big >> 20), g_ntg, (unsigned long long)(tg >> 20), tgn,
             g_ndead, g_gres.allocatedSize / 1048576.0, g_gdev.currentAllocatedSize / 1048576.0, ca[0] / 1048576.0, ca[1] / 1048576.0, ca[2] / 1048576.0, (unsigned long long)g_seg_n[0], (unsigned long long)g_seg_n[1], (unsigned long long)g_ca_cap_refuse, g_ca_max, cad, (unsigned long long)g_gfence, (unsigned long long)g_idle_commits, bn);
}
// ---------- 只给 GPU 用的临时数据：私有存储成块，按提交栅栏回收（同上，CPU 不读不写）----------
// 共享缓冲映射进进程地址空间；iPhone 上 VAMM 款（窗口 64 GB 全占）宿主只剩低区约 2 GB 地址，Metal 共享缓冲、GC、malloc、线程栈都挤在那里。
// 私有存储不映射进进程（本机探针：8×32 MB 私有缓冲进程标签 100 增长 0 MB，共享 +256 MB；巫师3 真机 Metal 已分配 898 MB 而低区 IOAccelerator 483 MB）。
// 曲面展开（点 / 索引上限各 16 MB）、索引转换输出这类只由 GPU 读写的大块走这里（10-21 巫师3 真机共享临时块 35 块 320 MB 吃空低区）。
// 选块用最合身的空闲块（不把大块耗在小请求上，免得大请求总找不到空闲块而新建）；块按 4 MB 起、大请求按 4 MB 取整
int gal_tg_test_fail;   // 单测故障注入：非 0 时换块路径当作建块失败
// 单测：清空 GPU 临时池（调用方先 gal_finish，块全已完成）
void gal_tg_test_reset(void) { for (int i = 0; i < g_ntg; i++) { gal_res_remove(g_tg[i].buf); g_tg[i].buf = nil; } g_ntg = 0; g_tg_cur = -1; g_tg_off = 0; g_tg_total = 0; memset(g_tg_epk, 0, sizeof g_tg_epk); g_tg_ep = UINT64_MAX; g_tg_peak_all = 0; }
// 按帧回收（10-23 巫师3 真机：池只建不还，0→240→340 MB 阶梯上涨、整块在驻留集里计入实占）：
//   每 TG_EPOCH 帧一段，记这段里「同时占用」（在用 + GPU 未做完）的峰值；上限 = 近 TG_NEP 段（约 8 秒）最大峰值 + 一块余量。
//   每次提交后，池总量超上限就释放 GPU 已做完的空闲块（先放最大的），移出驻留集。场景高峰过去约 8 秒后池缩回，平稳场景上限盖住峰值、不来回建删
uint64_t gal_tg_test_frames;   // 单测：加到出图次数上，模拟过了多少帧（产品恒 0）
static int tg_free(int i, uint64_t done) { return g_tg[i].fence && g_tg[i].fence != UINT64_MAX && g_tg[i].fence <= done && i != g_tg_cur; }
static void tg_note_busy(void) {   // 换块慢路径 / 提交时调：记本段同时占用峰值
    uint64_t done = g_gev.signaledValue, busy = 0;
    for (int i = 0; i < g_ntg; i++) if (!tg_free(i, done) || i == g_tg_cur) busy += g_tg[i].len;
    uint64_t ep = (gal_present_count() + gal_tg_test_frames) / TG_EPOCH;
    if (ep != g_tg_ep) { for (uint64_t e = (g_tg_ep == UINT64_MAX || ep - g_tg_ep > TG_NEP) ? ep - TG_NEP + 1 : g_tg_ep + 1; e <= ep; e++) g_tg_epk[e % TG_NEP] = 0; g_tg_ep = ep; }
    if (busy > g_tg_epk[ep % TG_NEP]) g_tg_epk[ep % TG_NEP] = busy;
    if (busy > g_tg_peak_all) g_tg_peak_all = busy;
}
static uint64_t tg_cap(void) { uint64_t m = 0; for (int e = 0; e < TG_NEP; e++) if (g_tg_epk[e] > m) m = g_tg_epk[e]; return m + TR_CHUNK; }
static void tg_trim(void) {   // 提交后调：超上限就放 GPU 已做完的空闲块
    if (!g_ntg) return;
    tg_note_busy();
    uint64_t cap = tg_cap(), done = g_gev.signaledValue;
    while (g_tg_total > cap) {
        int pick = -1;
        for (int i = 0; i < g_ntg; i++) if (tg_free(i, done) && (pick < 0 || g_tg[i].len > g_tg[pick].len)) pick = i;
        if (pick < 0) break;
        g_tg_total -= g_tg[pick].len; g_tg_freed_n++; g_tg_freed_b += g_tg[pick].len;
        gal_res_remove(g_tg[pick].buf); g_tg[pick].buf = nil;
        g_ntg--; if (pick != g_ntg) { g_tg[pick] = g_tg[g_ntg]; if (g_tg_cur == g_ntg) g_tg_cur = pick; }
        memset((void *)&g_tg[g_ntg], 0, sizeof *g_tg);
    }
}
void gal_tg_note(char *o, size_t n) {   // 地址账用：近 8 秒峰值 / 上限 / 累计回收
    snprintf(o, n, "近 %d 帧峰值 %llu MB、上限 %llu MB、全程峰值 %llu MB、已回收 %llu 块 %llu MB", TG_EPOCH * TG_NEP,
             (unsigned long long)((tg_cap() - TR_CHUNK) >> 20), (unsigned long long)(tg_cap() >> 20), (unsigned long long)(g_tg_peak_all >> 20),
             (unsigned long long)g_tg_freed_n, (unsigned long long)(g_tg_freed_b >> 20));
}
uint64_t gal_tg_freed(void) { return g_tg_freed_n; }   // 单测：累计回收块数
void gal_tg_stats(int *n, uint64_t *bytes) { uint64_t t = 0; for (int i = 0; i < g_ntg; i++) t += g_tg[i].buf.length; *n = g_ntg; *bytes = t; }   // 单测：GPU 临时池块数 / 字节
uint64_t gal_transient_gpu(uint32_t size, uint32_t align) {
    g_entry_dirty = 1; g_tg_req += size;
    if (!align) align = 16;
    uint32_t off = (g_tg_off + align - 1) & ~(align - 1);
    if (g_tg_cur < 0 || off + size > g_tg[g_tg_cur].len) {
        if (g_tg_cur >= 0) g_tg[g_tg_cur].fence = UINT64_MAX;
        uint64_t done = g_gev.signaledValue; int pick = -1;
        for (int i = 0; i < g_ntg && !gal_tg_test_fail; i++) if (g_tg[i].fence && g_tg[i].fence != UINT64_MAX && g_tg[i].fence <= done && g_tg[i].len >= size
                                                                && (pick < 0 || g_tg[i].len < g_tg[pick].len)) pick = i;
        if (pick < 0) {
            NSUInteger len = size > TR_CHUNK ? (size + TR_CHUNK - 1) / TR_CHUNK * TR_CHUNK : TR_CHUNK;
            id<MTLBuffer> b = gal_tg_test_fail ? nil : [g_gdev newBufferWithLength:len options:MTLResourceStorageModePrivate];
            if (!b) {
                static int nfail; uint64_t total = 0; for (int i = 0; i < g_ntg; i++) total += g_tg[i].buf.length;
                if (nfail++ < 8) GLOG("【红】GPU 临时内存：建 %lu 字节私有块失败（第 %d 次；已有 %d 块共 %llu MB）：%s", (unsigned long)len, nfail, g_ntg, (unsigned long long)(total >> 20), gal_mem_note());
                g_tg_cur = -1; g_tg_off = 0; return 0;
            }
            // 审计 P1-67：块表扩不动（gal_grow 报红、留原表）同建不出块：这次不给临时内存，新块随 ARC 放掉（还没进驻留集）
            __typeof__(g_tg) ng = gal_grow(g_tg, (size_t)g_ntg + 1, sizeof *g_tg, "GPU 临时池块表"); if (!ng) { g_tg_cur = -1; g_tg_off = 0; return 0; }
            g_tg = ng; memset((void *)&g_tg[g_ntg], 0, sizeof *g_tg);
            gal_res_add(b); g_tg[g_ntg].buf = b; g_tg[g_ntg].gpu = b.gpuAddress; g_tg[g_ntg].len = (uint32_t)b.length; pick = g_ntg++; g_tg_total += b.length;
        }
        g_tg[pick].fence = 0; g_tg_cur = pick; off = 0;
        tg_note_busy();
    }
    g_tg_off = off + size;
    if (!gal_draw_fixed()) return g_tg[g_tg_cur].buf.gpuAddress + off;   // 旧路径（A/B）
    return g_tg[g_tg_cur].gpu + off;
}
static void transient_retire(uint64_t f) {   // 提交时：本次提交用过的块都挂上这次的栅栏；当前块下次从头用新块
    for (int i = 0; i < g_ntr; i++) if (g_tr[i].fence == UINT64_MAX || (i == g_tr_cur && g_tr_off)) g_tr[i].fence = f;
    if (g_tr_cur >= 0 && g_tr[g_tr_cur].fence) g_tr_cur = -1;
    g_tr_off = 0;
    for (int i = 0; i < g_ntg; i++) if (g_tg[i].fence == UINT64_MAX || (i == g_tg_cur && g_tg_off)) g_tg[i].fence = f;
    if (g_tg_cur >= 0 && g_tg[g_tg_cur].fence) g_tg_cur = -1;
    g_tg_off = 0;
}

// 每 10 秒一行（墙钟窗口内的增量）：GPU 忙碌占比 = 各提交 GPU 执行时长之和 / 墙钟；按来由的提交数、GPU 时长、反压等它的次数与时长
static void bp_diag_note(void) {
    static uint64_t t0, f0, c0[CW_N], g0[CW_N], wn0[CW_N], ws0[CW_N];
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t now = mach_absolute_time() * tb.numer / tb.denom;
    if (!t0) { t0 = now; f0 = g_gp_frame; for (int i = 0; i < CW_N; i++) { c0[i] = g_bpd_commits[i]; g0[i] = g_bpd_gpu_ns[i]; wn0[i] = g_bpd_wait_n[i]; ws0[i] = g_bpd_wait_ns[i]; } return; }
    if (now - t0 < 10000000000ull) return;
    static const char *nm[CW_N] = { "其他", "等待型", "出图", "建同步号", "等同步号", "计数器", "遍收尾", "外部刷" };
    char b[1200]; int o = 0; uint64_t gsum = 0, csum = 0, wsum = 0;
    for (int i = 0; i < CW_N; i++) { gsum += g_bpd_gpu_ns[i] - g0[i]; csum += g_bpd_commits[i] - c0[i]; wsum += g_bpd_wait_ns[i] - ws0[i]; }
    uint64_t fr = g_gp_frame - f0; double wall = (double)(now - t0);
    o += snprintf(b + o, sizeof b - o, "[反压拆账] %.1f 秒 %llu 帧：GPU 忙 %.0f%%，提交 %llu 次（每帧 %.1f），反压 %.0f ms；按来由（提交 / GPU ms / 反压等它 次·ms）：", wall / 1e9,
                  (unsigned long long)fr, 100.0 * gsum / wall, (unsigned long long)csum, fr ? (double)csum / fr : 0.0, wsum / 1e6);
    for (int i = 0; i < CW_N && o < (int)sizeof b - 80; i++) { uint64_t c = g_bpd_commits[i] - c0[i], wn = g_bpd_wait_n[i] - wn0[i]; if (!c && !wn) continue;
        o += snprintf(b + o, sizeof b - o, " %s %llu / %.0f / %llu·%.0f", nm[i], (unsigned long long)c, (g_bpd_gpu_ns[i] - g0[i]) / 1e6, (unsigned long long)wn, (g_bpd_wait_ns[i] - ws0[i]) / 1e6); }
    GLOG("%s", b);
    t0 = now; f0 = g_gp_frame; for (int i = 0; i < CW_N; i++) { c0[i] = g_bpd_commits[i]; g0[i] = g_bpd_gpu_ns[i]; wn0[i] = g_bpd_wait_n[i]; ws0[i] = g_bpd_wait_ns[i]; }
}
static void ets_cb(id cb, int tag);   // 编码器时间戳：命令缓冲级一格（见 ets_note 前）
// ---------- 命令缓冲与编码器 ----------
static pthread_t g_cb_thread; static int g_cb_thread_set;   // 最近开命令缓冲的线程 = 渲染线程（见 gal_readback_enc）
void gal_cb_begin(void) {
    if (g_gcb || g_cb3) return;
    if (g_gal_be != GAL_BE_MTL4) {
        // Metal 3 兼容路径（gal_be.h 表中「命令提交 / 分配器」）：每次新开一条命令缓冲，没有分配器轮换、没有分段提交。
        // 栅栏身份与 Metal 4 同口径（g_gfence + 1）：延后释放 / 临时内存 / 已用区间 / 同步号都按这个号记
        // commandBufferWithUnretainedReferences 返回的是 autorelease 对象：本函数会从 C# 线程直接进来，那些线程上没有自动释放池，
        // 不包池的话每提交一条命令缓冲就漏一份（10-22 同类坑：C# 线程上的 ObjC 入口要自己包）。赋给静态强引用后池排空也不影响存活。
        @autoreleasepool { g_cb3 = [g_cq3 commandBufferWithUnretainedReferences]; }
        if (!g_cb3) { GRED_ONCE("Metal 3：建命令缓冲失败（%s）", gal_mem_note()); return; }
        g_cb_thread = pthread_self(); g_cb_thread_set = 1;
        g_cb_fence = g_gfence + 1;
        return;
    }
    // 分配器跨提交共用（NXGAL_CA_SHARE=<n>，缺省 0 = 每次提交换一个；帧率能耗线 10-24，性能取舍，真机达标再翻）：Metal 4 只要求分配器上的命令缓冲全部执行完才能 reset，
    //   同一分配器可以接着开下一个命令缓冲。原先每次提交都换分配器，提交频率与 8 个分配器轮换绑死：塞尔达逐遍提交（132 次 / 帧）读回 6.3 → 1.1 ms / 帧，
    //   但 GPU 只忙 70% 时编码线程就等分配器环 15.6 ms / 帧。共用后一个分配器接着托至多 n 次提交（且主分配器 < 16 MB），轮换按量不按次，
    //   提交频率和反压脱钩；被轮出去的分配器照旧等它最后一次提交的栅栏到了才 reset
    int share = ca_share();
    if (share > 0 && g_galloc_cur >= 0 && g_galloc_ncb[g_galloc_cur] < (uint32_t)share && g_galloc[g_galloc_cur].allocatedSize < (16u << 20)) {
        int pick = g_galloc_cur; g_galloc_ncb[pick]++; g_ca_reuse++;
        ca_note(pick); g_galloc_used[pick] = g_gp_frame; g_ca_n = 1; g_gcb_work = 0;
        g_gcb = [g_gdev newCommandBuffer];
        [g_gcb beginCommandBufferWithAllocator:g_galloc[pick]]; ets_cb(g_gcb, 9);
        g_cb_thread = pthread_self(); g_cb_thread_set = 1;
        g_cb_fence = g_gfence + 1;
        if (g_api_depth > 0 && g_entry_committed && g_entry_dirty) { g_entry_midcb++; GRED_ONCE("【缺陷】入口中途提交后又开新命令缓冲，而本入口已登记已用区间 / 分过临时内存：之后的命令会依赖随旧命令缓冲走掉的登记与内存（见 g_entry_dirty 注释）"); }
        return;
    }
    // 挑一个已完成的分配器（栅栏值 ≤ 已完成值）；都在用就等最老的那个（Metal 4：分配器必须等其命令执行完才能 reset）
    int pick = -1; uint64_t done = g_gev.signaledValue, oldest = UINT64_MAX;
    for (int i = 0; i < GAL_NALLOC; i++) { if (g_galloc_fence[i] <= done) { pick = i; break; } if (g_galloc_fence[i] < oldest) { oldest = g_galloc_fence[i]; pick = i; } }
    if (g_galloc_fence[pick] > done) {
        uint64_t b0 = bp_diag() ? __atomic_load_n(&g_bp_ns_total, __ATOMIC_RELAXED) : 0;
        gal_wait_acc(g_galloc_fence[pick], &g_bp_ns_total);
        if (bp_diag()) { int w = g_galloc_why[pick] < CW_N ? g_galloc_why[pick] : 0; atomic_fetch_add(&g_bpd_wait_n[w], 1); atomic_fetch_add(&g_bpd_wait_ns[w], __atomic_load_n(&g_bp_ns_total, __ATOMIC_RELAXED) - b0); }
    }
    ca_note(pick); ca_trim(done, pick); g_galloc_used[pick] = g_gp_frame;
    g_galloc_cur = pick; [g_galloc[pick] reset]; [g_palloc[pick] reset]; g_ca_n = 1; g_galloc_ncb[pick] = 1; g_ca_switch++;
    if (!g_xalloc[pick]) g_xalloc[pick] = [g_gdev newCommandAllocator];
    [g_xalloc[pick] reset]; g_gcb_work = 0;
    g_gcb = [g_gdev newCommandBuffer];
    [g_gcb beginCommandBufferWithAllocator:g_galloc[pick]]; ets_cb(g_gcb, 9);
    g_cb_thread = pthread_self(); g_cb_thread_set = 1;
    g_cb_fence = g_gfence + 1;
    if (g_api_depth > 0 && g_entry_committed && g_entry_dirty) { g_entry_midcb++; GRED_ONCE("【缺陷】入口中途提交后又开新命令缓冲，而本入口已登记已用区间 / 分过临时内存：之后的命令会依赖随旧命令缓冲走掉的登记与内存（见 g_entry_dirty 注释）"); }
}

// ---------- 非录制线程的读回（同 Ryujinx Vulkan 后端 BackgroundResources）----------
// Ryujinx 多线程后端里，客体线程会直调 GetBufferData / 后台上下文里的贴图读回，这时渲染线程可能正录到一半（跨多个入口开着编码器）。
// 入口锁只保证单个入口互斥；在客体线程上提交 / 结束渲染线程在录的命令缓冲，会把它的通道切开，Metal 侧也会出断言（10-18 架构线 a8f45e0 去后端串行锁实测）。
// 规矩：调用线程不是渲染线程（最近开命令缓冲的线程）时，读回不碰在录的那一个命令缓冲，也不等与被读对象无关的工作（按需同步，同 Ryujinx Vulkan 后端）：
//   缓冲：只等它自己的 GPU 写（gbuf.wfence，且不超过已提交的，gal_buf.m nxgal_buf_get_data）；
//   贴图：在后台读回队列 g_bgq 上的一次性命令缓冲里拷，自己提交自己等——同 Vulkan BackgroundResources 走独立的 BackgroundQueue：
//   与主队列之间不建依赖，被读贴图的 GPU 写由 Gpu 层先等同步号保证做完（TextureGroupHandle.Sync → WaitSync），之后主队列上的无关工作不等。
//   g_bgq 是老队列（Metal 3 接口，挂同一驻留集，同空闲保驻留 keepres_main）：只做拷贝，不新增 Metal 4 直接调用（gal_be.h 棘轮），Metal 3 兼容路径照用
// 10-21 改前：后台读回排在主队列上、开头一道队列级屏障，等全部已提交工作做完；渲染线程刚提交、没在录（g_gcb 空）时客体线程还被当成录制线程，
//   在客体线程上开主命令缓冲、提交并等全部已提交（gal_finish）。暗黑2 客体线程每帧回写一张 256×256×4 D16 阴影贴图、塞尔达每帧上百次缓冲回写，
//   每次都等满在途的一整帧 GPU 工作：真机读回阻塞 18–20 秒 / 60 秒
int gal_on_rec_thread(void) { return !g_cb_thread_set || pthread_equal(pthread_self(), g_cb_thread); }
static id<MTLCommandQueue> g_bgq;   // 后台读回队列（见上）
static id<MTLCommandBuffer> g_bg_cb; static id<MTLBlitCommandEncoder> g_bg_enc;
id gal_readback_enc(void) {
    if (gal_on_rec_thread()) return gal_blit_enc();
    if (g_bg_enc) return g_bg_enc;   // 同一次读回的几段拷贝写暂存缓冲互不重叠，不需要屏障
    g_bg_cb = [g_bgq commandBuffer]; g_bg_enc = [g_bg_cb blitCommandEncoder];   // 后台队列上之前的读回都已等完，开头不需要屏障
    return g_bg_enc;
}
static void sub_note(void);   // 空闲保驻留（见下）：主队列提交时刻
static void wait_site_note(uint64_t ns, int rb);   // 诊断 NXGAL_WAIT_SITE（见 gal_wait_acc 前）
void gal_readback_finish(void) {
    if (!g_bg_enc) { gal_finish(); return; }
    [g_bg_enc endEncoding];
    if (g_gres_dirty) { RS_SCOPE(RS_RESCOMMIT); [g_gres commit]; g_gres_dirty = 0; }   // 暂存缓冲刚进驻留集
    // 用读回自己的事件计数，不动主栅栏号（见 g_bgev 注释）
    uint64_t f = ++g_bgfence; [g_bg_cb encodeSignalEvent:g_bgev value:f];
    [g_bg_cb addCompletedHandler:^(id<MTLCommandBuffer> c) { if (c.error) gal_gpu_error_exit("后台读回", c.error); }];
    gal_gate_enter();
    [g_bg_cb commit];
    gal_gate_leave(); sub_note();
    // 诊断：渲染线程正录到一半时发生的后台读回次数（旧代码每次都让在录命令缓冲的身份错位一位），按 1 / 2 / 4 … 次打一行
    if (g_gcb) { static uint64_t nmid; uint64_t k = ++nmid; if (!(k & (k - 1))) GLOG("录制中途的后台读回：第 %llu 次（在录命令缓冲身份 %llu，主栅栏号不动）", (unsigned long long)k, (unsigned long long)g_cb_fence); }
    g_bg_enc = nil; g_bg_cb = nil;
    if (g_bgev.signaledValue >= f) return;
    GP_SCOPE(GP_WAIT);
    uint64_t t0 = mach_absolute_time();
    // 3 秒没等到同主栅栏判卡死（gal_gpu_stall_exit：Mac 即退，iPhone 报警续等）
    if (![g_bgev waitUntilSignaledValue:f timeoutMS:3000]) gal_gpu_stall_exit(g_bgev, "后台读回栅栏", f, g_bgev.signaledValue);
    { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); uint64_t ns = (mach_absolute_time() - t0) * tb.numer / tb.denom;
      __atomic_fetch_add(&g_wait_ns_total, ns, __ATOMIC_RELAXED); wait_site_note(ns, 1); }
}
uint64_t gal_committed_fence(void) { return g_gfence; }

// 诊断 NXGAL_TRACE_ENC=1：按调用点统计「结束渲染编码器」与「新开拷贝 / 计算编码器」，进程退出时打印（查通道被谁切开）
GAL_MTL4_ZONE_END
#include <dlfcn.h>
#include <execinfo.h>
GAL_MTL4_ZONE_BEGIN
typedef struct { void *pc[3]; uint64_t n; int kind; } enc_site;
static enc_site g_esite[256]; static int g_nesite;
static void esite_dump(void) {
    for (int i = 0; i < g_nesite; i++) for (int j = i + 1; j < g_nesite; j++) if (g_esite[j].n > g_esite[i].n) { enc_site t = g_esite[i]; g_esite[i] = g_esite[j]; g_esite[j] = t; }
    for (int i = 0; i < g_nesite && i < 30; i++) {
        fprintf(stderr, "[enc] %s %8llu ", g_esite[i].kind ? "开拷贝" : "结束渲染", (unsigned long long)g_esite[i].n);
        for (int k = 0; k < 3; k++) { Dl_info d; const char *nm = dladdr(g_esite[i].pc[k], &d) && d.dli_sname ? d.dli_sname : "?"; fprintf(stderr, " ← %s", nm); }
        fprintf(stderr, "\n"); }
}
// 按帧：NXGAL_TRACE_ENC=1 时每帧出图前调；本帧渲染遍 ≥ NXGAL_TRACE_ENC_PASSES（缺省 150）就打本帧的切遍调用点排行，然后清零（进岛重帧 374 遍 / 3.35 GB 附件读写，查谁切的）
static int g_esite_on = -1;
uint32_t g_copy_why[8];   // gal_buf.m nxgal_buf_copy：本帧缓冲拷贝没挪进预载的原因计数
void gal_esite_frame_end(void) {
    if (g_esite_on <= 0) return;
    static uint64_t last; static int th = -1; if (th < 0) { const char *v = getenv("NXGAL_TRACE_ENC_PASSES"); th = v && *v ? atoi(v) : 150; }
    uint64_t now = g_gp_n[GP_RENC], d = now - last; last = now;
    if ((int)d >= th) { fprintf(stderr, "[enc] ===== 帧 %llu：渲染遍 %llu，切遍调用点排行 =====\n", (unsigned long long)g_gp_frame, (unsigned long long)d); esite_dump();
        fprintf(stderr, "[enc] 缓冲拷贝没挪进预载：同缓冲 %u / 源被 GPU 写 %u / 源在录流写 %u / 源镜像待拷回 %u / 目标被 GPU 写 %u / 目标在录流写 %u / 目标已被用到 %u / 预载关 %u\n",
                g_copy_why[0], g_copy_why[1], g_copy_why[2], g_copy_why[3], g_copy_why[4], g_copy_why[5], g_copy_why[6], g_copy_why[7]);
        { extern uint64_t g_disp_why[6]; fprintf(stderr, "[enc] 遍内派发没挪到遍前（累计）：本遍有存储写 %llu / 缓冲有待拷回镜像 %llu / 用到本遍附件 %llu / 写的图像本遍用过 %llu / 遍前段没开 %llu / 要写的缓冲区间本遍已用 %llu\n",
            (unsigned long long)g_disp_why[0], (unsigned long long)g_disp_why[1], (unsigned long long)g_disp_why[2], (unsigned long long)g_disp_why[3], (unsigned long long)g_disp_why[4], (unsigned long long)g_disp_why[5]);
          extern uint64_t g_icnt_n[2], g_icnt_pre, g_icnt_nopre[2]; fprintf(stderr, "[enc] 间接计数整理（累计）：预载 %llu／遍前段 %llu／在录流 %llu；没进预载：参数被本命令缓冲 GPU 写 %llu、在录流上传 / 待拷回 %llu\n",
            (unsigned long long)g_icnt_pre, (unsigned long long)g_icnt_n[1], (unsigned long long)g_icnt_n[0], (unsigned long long)g_icnt_nopre[0], (unsigned long long)g_icnt_nopre[1]);
          extern uint64_t g_pclr_pre, g_pclr_why[3]; fprintf(stderr, "[enc] 落实挂起清屏（累计）：进遍前段 %llu／没挪：没开渲染遍 %llu、被清贴图本遍用过 %llu、遍前段没开 %llu\n",
            (unsigned long long)g_pclr_pre, (unsigned long long)g_pclr_why[0], (unsigned long long)g_pclr_why[1], (unsigned long long)g_pclr_why[2]);
          extern uint64_t g_texcp_n[2], g_cp_why[5]; fprintf(stderr, "[enc] 贴图拷贝（累计，NXGAL_TEXCOPY_PRE=1 才计）：遍前段 %llu／在录流 %llu；没挪：没开渲染遍 %llu、源本遍写过 %llu、目标本遍用过 %llu、不是直接拷贝 %llu、遍前段没开 %llu\n",
            (unsigned long long)g_texcp_n[1], (unsigned long long)g_texcp_n[0], (unsigned long long)g_cp_why[0], (unsigned long long)g_cp_why[1], (unsigned long long)g_cp_why[2], (unsigned long long)g_cp_why[3], (unsigned long long)g_cp_why[4]); } }
    g_nesite = 0; memset(g_copy_why, 0, sizeof g_copy_why);
}
static void esite_note(void *unused, int kind) {
    (void)unused;
    if (g_esite_on < 0) { g_esite_on = getenv("NXGAL_TRACE_ENC") != NULL; if (g_esite_on) atexit(esite_dump); }
    if (!g_esite_on) return;
    void *bt[8]; int n = backtrace(bt, 8); void *pc[3] = {n > 2 ? bt[2] : 0, n > 3 ? bt[3] : 0, n > 4 ? bt[4] : 0};
    for (int i = 0; i < g_nesite; i++) if (!memcmp(g_esite[i].pc, pc, sizeof pc) && g_esite[i].kind == kind) { g_esite[i].n++; return; }
    if (g_nesite < 256) { g_esite[g_nesite] = (enc_site){{pc[0], pc[1], pc[2]}, 1, kind}; g_nesite++; }
}
static int g_ets_gidx;   // 编码器时间戳：当前录制编码器的格（见 ets_note）
static void enc_fence_update3(id e, int render);   // Metal 3：编码器收尾前更新 g_fence3（见 enc_barrier）
void gal_enc_end(void) {
    if (!g_genc) return;
    if (g_genc_kind == 1) esite_note(__builtin_return_address(0), 0);
    int was_render = g_genc_kind == 1;
    if (was_render && g_passcommit > 0) { void *bt[4]; int n = backtrace(bt, 4); for (int i = 0; i < 3; i++) g_end_pc[i] = i + 1 < n ? bt[i + 1] : 0; }
    if (was_render && PSTAT_ON()) gal_pstat_mark(PS_END);
    if (g_gal_be != GAL_BE_MTL4) enc_fence_update3(g_genc, was_render);
    [g_genc endEncoding]; g_genc = nil; g_genc_kind = 0; g_genc_used = 0; g_ets_gidx = -1;
    if (was_render) g_pre_ok = 0;
    if (was_render && gal_on_enc_end) gal_on_enc_end();
    if (g_passcommit < 0) { const char *v = getenv("NXGAL_PERF_PASSCOMMIT"); g_passcommit = v && *v == '1'; }
    // 诊断：一遍一个命令缓冲。不在这里当场提交，记下来到入口返回时提交：结束编码器常发生在入口中途（如绘制准备时已在旧命令缓冲上记了
    // 本次要用的缓冲区间，随后结束上一个编码器），当场提交会让这些记录落到已提交的那个，之后的写入误走预载、提前改掉在录绘制要读的数据
    // （10-18 测试设备1 计数器局花屏：头发没了、散景失控；Mac galrec4 开此开关第 1 帧 174.9 万像素不一致）。入口之间提交等同一次 Flush，总是合法
    if (g_passcommit && !g_in_commit) g_passcommit_due = 1;
    if (was_render && !g_in_commit && cb_split_draws() && g_cb_draws >= cb_split_draws()) g_passcommit_due = 1;   // 长命令缓冲切分
    g_cb_encs++;
    if (!g_in_commit && !g_passcommit_due && ((cb_split_encs() && g_cb_encs >= cb_split_encs()) || (cb_split_bytes() && g_galloc_cur >= 0 && g_galloc[g_galloc_cur].allocatedSize >= cb_split_bytes()))) { g_passcommit_due = 1; g_cb_cap_commits++; }   // 按编码器数 / 分配器字节切分
    if (was_render && !g_in_commit && g_sync_pending && !sync_lazy_all()) g_passcommit_due = 1;   // 懒同步：这一遍收了，出入口时提交、回填挂起的同步号
    if (was_render && !g_in_commit && !g_passcommit_due && idle_commit_min() && g_cb_draws >= idle_commit_min() && g_gev.signaledValue >= g_gfence) { g_passcommit_due = 1; g_idle_commits++; }   // GPU 空闲即提交（见 idle_commit_min）
}

// 编码器之间全序：前面所有阶段的写对后面所有阶段可见（正确性优先；按需收窄留给性能阶段）
// 拆账实验开关（只量时间，画面不保证对）：NXGAL_PERF_NOBAR=1 去掉编码器间全阶段屏障；NXGAL_PERF_NOTEXBAR=1 贴图屏障不拆渲染通道
static int perf_flag(const char *k) { const char *v = getenv(k); return v && *v == '1'; }
static int g_nobar = -1;
static void enc_barrier(id e) {
    if (g_nobar < 0) g_nobar = perf_flag("NXGAL_PERF_NOBAR");
    if (g_nobar) return;
    if (g_gal_be != GAL_BE_MTL4) {
        // Metal 3：老编码器没有队列级阶段屏障，开头等 g_fence3（前一个编码器收尾时更新过），后一个编码器的所有阶段不早于前一个结束
        if (!g_fence3) g_fence3 = [g_gdev newFence];
        if ([e conformsToProtocol:@protocol(MTLRenderCommandEncoder)]) [(id<MTLRenderCommandEncoder>)e waitForFence:g_fence3 beforeStages:MTLRenderStageVertex];
        else [(id<MTLBlitCommandEncoder>)e waitForFence:g_fence3];   // blit / 计算编码器的选择子同名
        return;
    }
    [(id<MTL4CommandEncoder>)e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
}
// 同一拷贝 / 计算编码器里相邻两条之间的屏障（Metal 4 同一编码器内不保证先后：写后读、两次写同一段会乱序，nvn_mtl 10-15 t_ubv 抓到）
// ---------- 编码器时间戳（诊断 NXGAL_ENC_TS=1，缺省关）----------
// 4 秒冻结（10-22）：MTL4 回执只有整次提交的 error 与起止时间，没有逐编码器状态（Metal 3 的 errorOptions / 编码器 executionStatus 在 MTL4 没有）。
// 打开后每次提交配一个时间戳计数堆，每个编码器开头写一次、在录段尾写一次；执行超过 NXGAL_ENC_TS_MS（缺省 1000）就在回执里解出、按时间排序，
// 打出间隔最大的编码器。编码器之间是全序屏障（enc_barrier），后一个开始不早于前一个结束，间隔 ≈ 前一个编码器的执行时间。
enum { ETS_RING = 16, ETS_N = 2048 };
typedef struct { uint8_t tag; uint16_t w, h, fmt; uint32_t draws; uint64_t a, b; } ets_ent;   // a / b：首条绘制的顶点 / 片元着色器键（派发：计算着色器键）
static int g_ets_on = -1; static __strong id g_ets_heap[ETS_RING]; static ets_ent *g_ets_meta[ETS_RING]; static _Atomic int g_ets_busy[ETS_RING];
static int g_ets_slot = -1, g_ets_gidx = -1; static uint32_t g_ets_n; static unsigned g_ets_next;
static const char *const g_ets_tagn[] = {"在录段尾", "渲染遍", "拷贝 / 计算", "预载", "开遍整理", "遍前计算", "遍前清屏", "预载内一条", "预载缓冲尾", "主缓冲头", "遍前段头"};
// 堆格复用前的旧值（每次回执都解出存下）：下一次同一格解出来还是这个值 = 本次没写上（编码器没执行到 / 被丢弃），不当时间戳用。
// 10-22 怪猎 mhrise_1022065048_1：不剔旧值时预载内各条加 4 秒间隔累计 5.7 s，超过整次执行 4.02 s
static uint64_t *g_ets_old[ETS_RING];
// 本次提交拿一个堆（没有就拿）；堆上一次提交的回执还没处理完：本次提交不记（不等，不改时序）
static int ets_slot_ok(void) {
    if (g_ets_on < 0) {
        g_ets_on = perf_flag("NXGAL_ENC_TS");
        // 计数堆与编码器时间戳是 Metal 4 才有的（底稿表第 8 项）：Metal 3 下不做，开了也关掉并说一声
        if (g_ets_on > 0 && g_gal_be != GAL_BE_MTL4) { GLOG("编码器时间戳（NXGAL_ENC_TS）：Metal 3 路径下不支持，关掉"); g_ets_on = 0; }
    }
    if (g_ets_on <= 0) return 0;
    if (g_ets_slot < 0) {
        unsigned s = g_ets_next % ETS_RING;
        if (atomic_load(&g_ets_busy[s])) return 0;
        if (!g_ets_heap[s]) {
            g_ets_heap[s] = gal_be_ts_heap(g_gdev, ETS_N); g_ets_meta[s] = calloc(ETS_N, sizeof(ets_ent)); g_ets_old[s] = calloc(ETS_N, sizeof(uint64_t));
            if (!g_ets_heap[s] || !g_ets_meta[s] || !g_ets_old[s]) { GLOG("【红】编码器时间戳：建计数堆失败，关掉"); g_ets_on = 0; return 0; }
        }
        g_ets_next++; atomic_store(&g_ets_busy[s], 1); g_ets_slot = (int)s; g_ets_n = 0;
    }
    // 最后一格留给在录段尾
    return g_ets_n < ETS_N - 1;
}
// 命令缓冲级一格（编码器之间；前面的工作做完才写）：预载缓冲尾 / 主缓冲头 / 遍前段头，分开「卡在缓冲交接」与「卡在某个编码器里」
static void ets_cb(id cb, int tag) {
    if (!ets_slot_ok()) return;
    uint32_t i = g_ets_n++; ets_ent *m = &g_ets_meta[g_ets_slot][i]; memset(m, 0, sizeof *m); m->tag = (uint8_t)tag;
    gal_be_ts_cb(cb, g_ets_heap[g_ets_slot], i);
}
static void ets_note(id e, int tag) {
    if (!ets_slot_ok()) return;
    uint32_t i = g_ets_n++; ets_ent *m = &g_ets_meta[g_ets_slot][i]; memset(m, 0, sizeof *m); m->tag = (uint8_t)tag;
    if (tag == 1 || tag == 2) g_ets_gidx = (int)i;
    gal_be_ts_enc(e, tag == 1 || tag == 6, g_ets_heap[g_ets_slot], i);
}
// 绘制 / 派发记到当前录制编码器（g_genc）那一格：首条的遍尺寸与着色器键、条数
static void ets_draw(int kind, uint64_t a, uint64_t b) {
    if (g_ets_slot < 0 || g_ets_gidx < 0) return;
    ets_ent *m = &g_ets_meta[g_ets_slot][g_ets_gidx];
    if (!m->draws++) { m->w = (uint16_t)g_pass_w; m->h = (uint16_t)g_pass_h; m->fmt = (uint16_t)g_pass_fmt; m->a = a; m->b = kind == 2 ? 0 : b; }
}
// 提交时：在录段尾写一格，交出本次提交的堆（返回槽号，没记返回 -1）
static int ets_seal(id cb, uint32_t *n) {
    int s = g_ets_slot; g_ets_slot = -1; g_ets_gidx = -1; *n = 0;
    if (s < 0) return -1;
    ets_ent *m = &g_ets_meta[s][g_ets_n]; memset(m, 0, sizeof *m);
    gal_be_ts_cb(cb, g_ets_heap[s], g_ets_n); *n = g_ets_n + 1;
    return s;
}
static const uint64_t *g_ets_sort_ts;
static int ets_cmp(const void *x, const void *y) { uint64_t a = g_ets_sort_ts[*(const uint32_t *)x], b = g_ets_sort_ts[*(const uint32_t *)y]; return a < b ? -1 : a > b; }
// 回执线程上调：解出、排序、打间隔最大的 3 个；放回堆
// 汇总（NXGAL_ENC_TS_AGG=1，诊断，须同开 NXGAL_ENC_TS=1）：每次提交按时间排好的相邻两格之差记到前一格的编码器上，
// 按「类型 + 遍尺寸格式 + 首条着色器键（预载内一条按调用点）」累加，每 10 秒打累计耗时前 15（每帧均摊 = 累计 / 帧数）。
// 编码器之间是全序屏障，差值 ≈ 该编码器的 GPU 执行时间。10-22 塞尔达 GPU 每帧约 29 ms：找占大头的遍与着色器
enum { AGG_N = 2048 };
static struct { uint8_t tag; uint16_t w, h, fmt; uint64_t a, b; uint64_t tk, n; } g_agg[AGG_N];
static void ets_agg(int s, const uint64_t *ts, const uint32_t *ix, uint32_t v, double ms_tick) {
    static int on = -1; if (on < 0) on = perf_flag("NXGAL_ENC_TS_AGG");
    if (!on) return;
    static uint64_t f0, last, miss;
    if (!f0) f0 = g_gp_frame + 1;
    for (uint32_t j = 0; j + 1 < v; j++) {
        const ets_ent *m = &g_ets_meta[s][ix[j]]; uint64_t dt = ts[ix[j + 1]] - ts[ix[j]];
        uint64_t h = (m->a * 0x9E3779B97F4A7C15ull) ^ (m->b * 0xC2B2AE3D27D4EB4Full) ^ ((uint64_t)m->tag << 48 | (uint64_t)m->w << 32 | (uint64_t)m->h << 16 | m->fmt);
        unsigned k = (unsigned)(h % AGG_N), t;
        for (t = 0; t < AGG_N; t++, k = (k + 1) % AGG_N) {
            if (!g_agg[k].n) { g_agg[k].tag = m->tag; g_agg[k].w = m->w; g_agg[k].h = m->h; g_agg[k].fmt = m->fmt; g_agg[k].a = m->a; g_agg[k].b = m->b; break; }
            if (g_agg[k].tag == m->tag && g_agg[k].w == m->w && g_agg[k].h == m->h && g_agg[k].fmt == m->fmt && g_agg[k].a == m->a && g_agg[k].b == m->b) break;
        }
        if (t == AGG_N) { miss++; continue; }
        g_agg[k].tk += dt; g_agg[k].n++;
    }
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t now = mach_absolute_time() * tb.numer / tb.denom;
    if (now - last < 10000000000ull) return;
    last = now;
    uint64_t fr = g_gp_frame >= f0 ? g_gp_frame - f0 + 1 : 1, tot = 0;
    for (int k = 0; k < AGG_N; k++) tot += g_agg[k].tk;
    GLOG("[编码器汇总] 帧 %llu（累计 %llu 帧）：编码器 GPU 时间合计 %.1f ms/帧，前 15（累计耗时；每帧均摊 / 次数 / 平均每次）：", (unsigned long long)g_gp_frame, (unsigned long long)fr, tot * ms_tick / fr);
    static uint8_t done[AGG_N]; memset(done, 0, sizeof done);
    for (int r = 0; r < 15; r++) {
        int b = -1; for (int k = 0; k < AGG_N; k++) if (g_agg[k].n && !done[k] && (b < 0 || g_agg[k].tk > g_agg[b].tk)) b = k;
        if (b < 0) break;
        done[b] = 1;
        char cs[96] = ""; Dl_info di;
        if ((g_agg[b].tag == 3 || g_agg[b].tag == 7) && g_agg[b].a && dladdr((void *)g_agg[b].a, &di))
            snprintf(cs, sizeof cs, "，调用点 %s+%#lx", strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname, (unsigned long)((char *)g_agg[b].a - (char *)di.dli_fbase));
        GLOG("[编码器汇总]   %.2f ms/帧（%.1f%%）×%llu 平均 %.3f ms：%s%s 遍 %ux%u 格式 %u 首条 %016llx / %016llx", g_agg[b].tk * ms_tick / fr, tot ? 100.0 * g_agg[b].tk / tot : 0.0,
             (unsigned long long)g_agg[b].n, g_agg[b].tk * ms_tick / g_agg[b].n, g_ets_tagn[g_agg[b].tag], cs, g_agg[b].w, g_agg[b].h, g_agg[b].fmt, (unsigned long long)g_agg[b].a, (unsigned long long)g_agg[b].b);
    }
    if (miss) GLOG("[编码器汇总]   表满没记 %llu 次", (unsigned long long)miss);
}
static void ets_done(int s, uint32_t n, uint64_t fence, uint64_t fr, uint64_t ns) {
    if (s < 0) return;
    static double lim = -1; if (lim < 0) { const char *v = getenv("NXGAL_ENC_TS_MS"); lim = v ? atof(v) : 1000; }
    static _Atomic int left = 20;
    int slow = ns / 1e6 >= lim;
    @autoreleasepool {
        static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; pthread_mutex_lock(&mu);
        static uint64_t ts[ETS_N]; static uint32_t ix[ETS_N]; static uint8_t used[ETS_N]; static double ms_tick;
        if (!ms_tick) { uint64_t hz = [g_gdev queryTimestampFrequency]; ms_tick = hz ? 1e3 / (double)hz : 1e-6; }
        NSData *d = gal_be_ts_resolve(g_ets_heap[s], n);
        size_t st = d && n ? d.length / n : 0; uint32_t v = 0, stale = 0;
        for (uint32_t i = 0; i < n && st >= 8; i++) {
            memcpy(&ts[i], (const uint8_t *)d.bytes + i * st, 8);
            int ok = ts[i] && ts[i] != UINT64_MAX && ts[i] != g_ets_old[s][i];
            if (ts[i] && ts[i] == g_ets_old[s][i]) stale++;
            g_ets_old[s][i] = ts[i];
            if (ok) ix[v++] = i;
        }
        g_ets_sort_ts = ts; qsort(ix, v, sizeof *ix, ets_cmp);
        ets_agg(s, ts, ix, v, ms_tick);
        if (!slow || atomic_fetch_sub(&left, 1) <= 0) { pthread_mutex_unlock(&mu); atomic_store(&g_ets_busy[s], 0); return; }
        memset(used, 0, v);
        GLOG("编码器时间戳：栅栏 %llu（帧 %llu）执行 %.0f ms，编码器 + 段尾 %u 格、有效 %u 格；间隔最大的（编码器之间全序屏障，间隔 ≈ 该编码器执行时间）：", (unsigned long long)fence, (unsigned long long)fr, ns / 1e6, n, v);
        for (int k = 0; k < 3 && v > 1; k++) {
            uint32_t best = 0; uint64_t bg = 0;
            for (uint32_t j = 0; j + 1 < v; j++) { uint64_t g = ts[ix[j + 1]] - ts[ix[j]]; if (!used[j] && g > bg) { bg = g; best = j; } }
            if (!bg) break;
            // 间隔两侧的格都打（时间戳写在编码器开头：间隔 ≈ 前一格那个编码器的执行时间；后一格一并列出以便核对）
            GLOG("  间隔 %.1f ms（开始 +%.1f ms，提交内第 %u → %u 个开始）：", bg * ms_tick, (ts[ix[best]] - ts[ix[0]]) * ms_tick, best, best + 1);
            for (int side = 0; side < 2; side++) {
                uint32_t q = ix[best + side]; const ets_ent *m = &g_ets_meta[s][q];
                // 预载 / 预载内一条：a 是调用点（镜像内偏移，atos -o <宿主> -l 0x100000000 符号化）
                char cs[128] = ""; Dl_info di;
                if ((m->tag == 3 || m->tag == 7) && m->a && dladdr((void *)m->a, &di))
                    snprintf(cs, sizeof cs, "，调用点 %s+%#lx", strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname, (unsigned long)((char *)m->a - (char *)di.dli_fbase));
                GLOG("    %s #%u %s%s：遍 %ux%u 格式 %u、绘制 / 派发 %u 条、首条 %016llx / %016llx", side ? "后" : "前", q, g_ets_tagn[m->tag], cs,
                     m->w, m->h, m->fmt, m->draws, (unsigned long long)m->a, (unsigned long long)m->b);
            }
            used[best] = 1;
        }
        if (v < n) GLOG("  没写上的格 %u 个（编码器没执行到 / 被丢弃；其中与上次同格旧值相同 %u 个）", n - v, stale);
        pthread_mutex_unlock(&mu);
    }
    atomic_store(&g_ets_busy[s], 0);
}
// 预载编码器里逐条定位（10-22 怪猎两次 4 秒冻结都卡在预载编码器）：第二条起每条命令前写一格（前面的命令做完才写），
// 格里记调用点（gal_preload_enc 的返回地址）；第一条记在预载编码器那一格上（ets_caller）
static void ets_mid(id e, void *ra) {
    if (g_ets_on <= 0 || g_ets_slot < 0 || g_ets_n >= ETS_N - 1) return;
    uint32_t i = g_ets_n++; ets_ent *m = &g_ets_meta[g_ets_slot][i]; memset(m, 0, sizeof *m); m->tag = 7; m->a = (uint64_t)ra;
    gal_be_ts_cmp_precise(e, g_ets_heap[g_ets_slot], i);
}
static void ets_caller(void *ra) { if (g_ets_on > 0 && g_ets_slot >= 0 && g_ets_n) g_ets_meta[g_ets_slot][g_ets_n - 1].a = (uint64_t)ra; }
// 诊断 NXGAL_ENC_LABEL=1（缺省关）：建编码器时写标签「S2A 类型号 遍尺寸 格式 #本帧第几个编码器」，xctrace GPU 区间表（metal-gpu-intervals 的 event-label）按标签汇总逐遍 GPU 时间。
//   10-24 实测标签要在建编码器时就写：原先第一条绘制时才写（为带上首条着色器键），塞尔达 Metal System Trace 里 301 个编码器 / 帧只有零星几个带标签
//   类型号同 enc_open 的 tag：1 渲染 2 计算 3 预载计算 4 开遍整理 5 遍前计算 6 遍前渲染
static void enc_open(id e, int tag) {
    enc_barrier(e); ets_note(e, tag);
    static int on = -1; if (on < 0) on = perf_flag("NXGAL_ENC_LABEL");
    if (on) { static uint64_t fr; static uint32_t seq; if (fr != g_gp_frame) { fr = g_gp_frame; seq = 0; }
        int render = tag == 1 || tag == 6;
        [e setLabel:[NSString stringWithFormat:@"S2A %d %ux%u f%u #%u", tag, render ? g_pass_w : 0, render ? g_pass_h : 0, render ? g_pass_fmt : 0, seq++]]; }
}
static void enc_fence_update3(id e, int render) {
    if (g_nobar || !g_fence3) return;
    if (render) [(id<MTLRenderCommandEncoder>)e updateFence:g_fence3 afterStages:MTLRenderStageVertex | MTLRenderStageFragment];
    else [(id<MTLBlitCommandEncoder>)e updateFence:g_fence3];
}
// Metal 3 参数绑定（gal_be.h 表中「参数绑定」，卡 M3-7）还没合入：用到 Metal 4 参数表的绘制 / 派发在老编码器上会直接崩（选择子不认），
// 先报红跳过（铁律：未实现就报红，不兜底）。返回 1 = 本次跳过。what：0 绘制 1 派发 2 遍内清屏 3 辅助绘制。M3-7 合入时连同调用点一起删
int gal_m3_unbound(int what) {
    if (g_gal_be != GAL_BE_MTL3) return 0;
    static const char *const n[] = {"绘制", "计算派发", "遍内清屏", "辅助绘制（贴图 blit / 解析）"};
    uint64_t k = ++g_m3_skip[what & 3];
    if (!(k & (k - 1))) GLOG("【红】Metal 3：参数绑定（M3-7 #114）未合入，%s跳过（第 %llu 次）", n[what & 3], (unsigned long long)k);
    return 1;
}
static id blit_enc3(void);
static id cmp_enc3(void);
static void enc_seq_barrier(id e) { [e barrierAfterEncoderStages:MTLStageBlit | MTLStageDispatch beforeEncoderStages:MTLStageBlit | MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice]; }
id<MTL4ComputeCommandEncoder> gal_blit_enc(void) {
    if (g_gal_be != GAL_BE_MTL4) return blit_enc3();
    // 挂起清屏不在这里落实（10-19 起挂在贴图上）：纯缓冲拷贝 / 索引转换 / 顶点重排用不到贴图；碰贴图的拷贝 / 读写在 gal_tex.m 入口按涉及的贴图 gal_pass_clears_touch
    if (g_genc_kind == 2) {
        // 同一编码器内 Metal 4 不保证先后：「写后读同一段」「两次写同一段」会乱序（nvn_mtl 10-15 t_ubv 抓到），相邻两条之间加屏障
        if (g_genc_used++) enc_seq_barrier(g_genc);
        return g_genc;
    }
    esite_note(__builtin_return_address(0), 1);
    gal_pass_close(); gal_enc_end(); gal_cb_begin();   // 只收渲染通道：挂起清屏留在贴图上（碰贴图的拷贝在 gal_tex.m 入口已按涉及的贴图落实）
    if (PSTAT_ON()) gal_pstat_mark(PS_ENC2);
    id<MTL4ComputeCommandEncoder> e = [g_gcb computeCommandEncoder]; enc_open(e, 2); g_gp_n[GP_CENC]++; g_gcb_work = 1;
    g_genc = e; g_genc_kind = 2; g_genc_used = 1; return e;
}
// Metal 3 的拷贝编码器（MTLBlitCommandEncoder）：老 blit 编码器没有编码器内屏障，第二条起收掉当前编码器重开一个（编码器之间靠 g_fence3 全序）。
// 调用方拿到后录一条（或一组互不重叠的）拷贝，与 Metal 4 下 gal_blit_enc 的用法一致
static id blit_enc3(void) {
    if (g_genc_kind == 2) g_m3_split++;
    esite_note(__builtin_return_address(0), 1);
    gal_pass_close(); gal_enc_end(); gal_cb_begin();
    if (!g_cb3) return nil;
    if (PSTAT_ON()) gal_pstat_mark(PS_ENC2);
    id e; @autoreleasepool { e = [g_cb3 blitCommandEncoder]; }
    enc_open(e, 2); g_gp_n[GP_CENC]++;
    g_genc = e; g_genc_kind = 2; g_genc_used = 1; return e;
}
// Metal 3 的计算编码器（g_genc_kind 3）：编码器内相邻两条用 memoryBarrierWithScope（计算编码器的这个 iOS 12 起就有；渲染编码器的 iOS 上不可用，不用）
static id cmp_enc3(void) {
    if (g_genc_kind == 3) { if (g_genc_used++) [(id<MTLComputeCommandEncoder>)g_genc memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures]; return g_genc; }
    esite_note(__builtin_return_address(0), 1);
    gal_pass_close(); gal_enc_end(); gal_cb_begin();
    if (!g_cb3) return nil;
    if (PSTAT_ON()) gal_pstat_mark(PS_ENC2);
    id e; @autoreleasepool { e = [g_cb3 computeCommandEncoder]; }
    enc_open(e, 2); g_gp_n[GP_CENC]++;
    g_genc = e; g_genc_kind = 3; g_genc_used = 1; return e;
}
// 计算派发用的编码器（gal_internal.h）：Metal 4 拷贝与计算同一个编码器（= gal_blit_enc）；Metal 3 分开，派发走计算编码器
id gal_cmp_enc(void) {
    if (g_gal_be == GAL_BE_MTL4) return gal_blit_enc();
    return gal_m3_unbound(1) ? nil : cmp_enc3();
}
// Metal 3 预载：单独一条命令缓冲上的 blit 编码器，提交时排在在录缓冲之前（gal_commit_mtl3）。开头等 g_fence3、收尾更新它；
// 在录缓冲里比预载先开的编码器不等预载——预载只写本次提交还没用到的区间（调用方保证，同 Metal 4），它们不读这些区间
static id preload_enc3(void) {
    if (g_penc3) {
        // 同 blit_enc3：老 blit 编码器没有编码器内屏障，第二条起换一个编码器
        enc_fence_update3(g_penc3, 0); [g_penc3 endEncoding]; g_m3_split++;
        @autoreleasepool { g_penc3 = [g_pcb3 blitCommandEncoder]; }
        enc_barrier(g_penc3); g_penc_used = 1; return g_penc3;
    }
    gal_cb_begin();
    if (!g_cb3) return nil;
    @autoreleasepool { g_pcb3 = [g_cq3 commandBufferWithUnretainedReferences]; g_pcb3.label = @"S2A 预载"; g_penc3 = [g_pcb3 blitCommandEncoder]; }
    enc_barrier(g_penc3); g_gp_n[GP_CENC]++; g_penc_used = 1;
    return g_penc3;
}
// 预载里的计算派发（顶点重排 / 间接计数整理）：Metal 4 同 gal_preload_enc；Metal 3 的预载是 blit 编码器，派发等参数绑定合入后再分
id gal_preload_cmp_enc(void) {
    if (g_gal_be == GAL_BE_MTL4) return gal_preload_enc();
    gal_m3_unbound(1); return nil;
}
id<MTL4ComputeCommandEncoder> gal_preload_enc(void) {
    if (g_gal_be != GAL_BE_MTL4) return preload_enc3();
    // 同一预载编码器里两条拷贝可能写同一段、顶点重排派发读前面拷贝写的段：相邻两条之间加屏障（同 gal_blit_enc，含派发阶段）
    if (g_penc) {
        if (g_penc_used++) { enc_seq_barrier(g_penc); ets_mid(g_penc, __builtin_return_address(0)); }
        return g_penc;
    }
    gal_cb_begin();
    g_pcb = [g_gdev newCommandBuffer]; [g_pcb beginCommandBufferWithAllocator:g_palloc[g_galloc_cur]];
    g_penc = [g_pcb computeCommandEncoder]; enc_open(g_penc, 3); ets_caller(__builtin_return_address(0)); g_gp_n[GP_CENC]++; g_penc_used = 1;
    return g_penc;
}
// 开遍预整理用的计算编码器：在录段里、本遍渲染编码器之前（开遍时没有别的编码器开着），用完即收
static id g_pre_enc;
static id prebegin_enc(void) {
    if (g_gal_be != GAL_BE_MTL4) { gal_m3_unbound(1); return nil; }   // 只做间接计数整理（派发）
    if (!g_pre_enc) { g_pre_enc = [g_gcb computeCommandEncoder]; enc_open(g_pre_enc, 4); g_gp_n[GP_CENC]++; g_gcb_work = 1; }
    else enc_seq_barrier(g_pre_enc);
    return g_pre_enc;
}
static uint64_t g_pass_serial = 1;   // 渲染遍序号（开遍 +1）：缓冲「本遍已用区间」的键（gal_buf.m puse）、参数集复用的同遍条件（gal_draw.m）
uint64_t gal_pass_serial(void) { return g_pass_serial; }
id<MTL4RenderCommandEncoder> gal_render_begin_desc(MTL4RenderPassDescriptor *d) {
    gal_enc_end(); gal_cb_begin(); g_pass_serial++;
    if (g_gal_be != GAL_BE_MTL4) {
        // Metal 3：d 是 gal_be_pass_desc 建的 MTLRenderPassDescriptor。不分遍前段（分段靠 Metal 4 的命令分配器；g_pre_ok 恒 0，遍前段请求一律回在录流）
        memcpy(g_pass_why, g_end_pc, sizeof g_pass_why);
        pre_close(); g_pre_ok = 0;
        if (g_ord_frame != g_gp_frame) { g_ord_frame = g_gp_frame; g_pass_ord = 0; }
        g_cur_ord = g_pass_ord++;
        if (g_grp_frame != g_gp_frame) { g_grp_frame = g_gp_frame; g_grp_base = g_rt_group_seq; }
        g_cur_grp = g_rt_group_seq - g_grp_base;
        g_icnt_hook = 0;
        if (!g_cb3) return nil;
        id e; @autoreleasepool { e = [g_cb3 renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d]; }
        if (!e) { GRED_ONCE("Metal 3：开渲染编码器失败（%ux%u）", (unsigned)d.renderTargetWidth, (unsigned)d.renderTargetHeight); return nil; }
        enc_open(e, 1); g_gp_n[GP_RENC]++;
        g_genc = e; g_genc_kind = 1; return e;
    }
    memcpy(g_pass_why, g_end_pc, sizeof g_pass_why);
    // 遍前段（见 g_segs）：最近 2 帧有操作想挪到遍前才分段（分段每遍多一个命令缓冲，不用的游戏不付）；上一遍的遍前段到此收口
    pre_close(); g_pre_ok = 0;
    if (g_ord_frame != g_gp_frame) { g_ord_frame = g_gp_frame; g_pass_ord = 0; }
    g_cur_ord = g_pass_ord++;
    int want = gal_prepass_test_any ? g_prepass_frame != UINT64_MAX && g_prepass_frame + 2 >= g_gp_frame
                                    : pw_get(g_gp_frame - 1, g_cur_ord) || pw_get(g_gp_frame - 2, g_cur_ord);
    if (!prepass_off() && want) {
        if (!g_gcb_work) g_pre_ok = 1;
        else if (g_ca_n <= SEG_CAP && segs_room() && ca_admit()) { [g_gcb endCommandBuffer]; segs_push(g_gcb); g_gcb = [g_gdev newCommandBuffer]; [g_gcb beginCommandBufferWithAllocator:g_galloc[g_galloc_cur]]; ets_cb(g_gcb, 9); g_gcb_work = 0; if (++g_ca_n > g_ca_max) g_ca_max = g_ca_n; g_pre_ok = 1; }
        g_seg_n[!g_pre_ok]++;
    }
    if (g_grp_frame != g_gp_frame) { g_grp_frame = g_gp_frame; g_grp_base = g_rt_group_seq; }
    g_cur_grp = g_rt_group_seq - g_grp_base;
    // 间接计数预整理（gal_draw.m）：上一帧同一目标组里出现过的间接计数，开遍前在本段里先整理好，遍里的绘制直接取结果、不切遍也不要遍前段
    if (g_icnt_hook) { g_icnt_hook = 0; gal_icnt_prebegin(g_cur_grp, prebegin_enc); if (g_pre_enc) { [g_pre_enc endEncoding]; g_pre_enc = nil; } }
    id<MTL4RenderCommandEncoder> e = [g_gcb renderCommandEncoderWithDescriptor:d]; enc_open(e, 1); g_gp_n[GP_RENC]++; g_gcb_work = 1;
    g_genc = e; g_genc_kind = 1; return e;
}
id gal_cur_enc(int *kind) { if (kind) *kind = g_genc_kind; return g_genc; }
// 当前渲染遍的遍前计算编码器（见 g_segs）：遍开在段首才有，否则返回 nil（调用方照旧在录流里做、切遍）。录进它的命令在本遍之前执行，
// 只能读本遍开始前就定了的数据（调用方保证：本遍里没有存储写）
static int pre_cb(void) {   // 当前遍的遍前命令缓冲（没有就建、进段序列，排在本遍那段之前）
    if (!g_pre_ok || g_genc_kind != 1) return 0;
    if (!g_xcb) { if (!segs_room()) return 0;   // 段表扩不了：同「没有遍前段」，调用方照旧在录流里做
        g_xcb = [g_gdev newCommandBuffer]; [g_xcb beginCommandBufferWithAllocator:g_xalloc[g_galloc_cur]]; ets_cb(g_xcb, 10); segs_push(g_xcb); }
    return 1;
}
id gal_prepass_enc(void) {
    if (!pre_cb()) return nil;
    if (g_xenc) { if (g_xenc_used++) enc_seq_barrier(g_xenc); return g_xenc; }
    g_xenc = [g_xcb computeCommandEncoder]; enc_open(g_xenc, 5); g_gp_n[GP_CENC]++; g_xenc_used = 1;
    return g_xenc;
}
// 当前渲染遍的遍前段里开一个渲染编码器（落实挂起清屏用，帧级调度）：先收遍前段的计算编码器（编码器之间全序屏障，前面录的照序在前）；
// 调用方录完自己 endEncoding。遍前段不可用返回 nil（调用方照旧在录流里做、切遍）
id gal_prepass_render(id d) {
    if (!pre_cb()) return nil;
    if (g_xenc) { [g_xenc endEncoding]; g_xenc = nil; }
    id e = [g_xcb renderCommandEncoderWithDescriptor:d]; enc_open(e, 6); g_gp_n[GP_RENC]++;
    return e;
}

// ---------- GPU 卡死机械保护（10-19 本机 13:50 内核恐慌：一局卡死 GPU，等栅栏「继续等」，WindowServer 卡在 Metal 提交 120 秒后看门狗重启整机）----------
// 任一 CPU 侧等 GPU（提交栅栏 / 出图定格 / 计数结果）超过 GAL_STALL_MS（3 秒）：判【红】、写现场、立刻 _exit(86)，不做优雅退出——
// 进程退出才会释放它占着的 GPU 队列，系统才能恢复。
// 命令缓冲执行出错（自己挂死 / 越界缺页，或被别的进程的 GPU 错误连坐丢弃）同样判红、写现场、_exit(86)（10-19 维护者裁定，撤掉 f6a7933「重建队列、在途命令作废后照常跑」）：
// 被丢弃的命令里有缓冲上传 / 拷贝，显卡层以为已写好，照常跑只会把一次错误扩散成之后的缺页与画错且不报红——10-19 本机 15:31–15:53 四局（mkfs2 / mkt2_pw1 / nine10 acnh_A、mk8d_B）
// 都是先被连坐重建、之后自己缺页
#define GAL_STALL_MS 3000
#define GAL_STALL_IOS_S 20   // iPhone：3 秒后再等至多这么多秒（栅栏前进就重新计时），回执报错立即退
// 卡死现场：每个命令缓冲记前 HANG_N 个绘制 / 派发（常开，每条几次写内存），按栅栏号进 HANG_RING 槽；卡死 / 出错时打出所有未完成命令缓冲的清单
#define HANG_N 48
#define HANG_RING 32
typedef struct { uint8_t kind; uint16_t w, h, fmt; uint64_t a, b; uint32_t n; } hang_ent;   // kind 1 绘制（a 顶点 b 片元着色器键）2 派发（a 计算着色器键，n 线程组数）
typedef struct { uint64_t fence; uint32_t n, total; hang_ent e[HANG_N]; } hang_cb;
static hang_cb g_hang_cur, g_hang_ring[HANG_RING];
uint64_t gal_pass_first_vs(void) { return g_pass_kset ? g_pass_ka : 0; }   // 本遍首条绘制的顶点着色器键（gal_draw.m NXGAL_PROG_COUNT 用）
void gal_hang_note(int kind, const gal_prog *pg, uint32_t n) {
    hang_cb *c = &g_hang_cur; c->total++; g_cb_draws++;
    if (pg && !g_pass_kset) { g_pass_kset = 1; g_pass_ka = kind == 2 ? pg->stage_hash[0] : pg->stage_hash[1]; g_pass_kb = kind == 2 ? 0 : pg->stage_hash[5]; }
    if (pg && g_ets_slot >= 0) ets_draw(kind, kind == 2 ? pg->stage_hash[0] : pg->stage_hash[1], pg->stage_hash[5]);
    if (c->n >= HANG_N || !pg) return;
    hang_ent *x = &c->e[c->n++]; x->kind = (uint8_t)kind; x->w = (uint16_t)g_pass_w; x->h = (uint16_t)g_pass_h; x->fmt = (uint16_t)g_pass_fmt; x->n = n;
    x->a = kind == 2 ? pg->stage_hash[0] : pg->stage_hash[1]; x->b = kind == 2 ? 0 : pg->stage_hash[5];
}
static void hang_seal(uint64_t fence) { g_hang_cur.fence = fence; g_hang_ring[fence % HANG_RING] = g_hang_cur; g_hang_cur.n = g_hang_cur.total = 0; g_cb_draws = 0; g_cb_encs = 0; }
static void hang_cb_dump(const char *what, uint64_t f) {
    const hang_cb *c = &g_hang_ring[f % HANG_RING];
    if (c->fence != f) { GLOG("  %s 栅栏 %llu：无记录（读回 / 后台提交，或已被后来的缓冲挤出记录环）", what, (unsigned long long)f); return; }
    GLOG("  %s 栅栏 %llu：%u 条（记前 %u 条）", what, (unsigned long long)f, c->total, c->n);
    for (uint32_t i = 0; i < c->n; i++) { const hang_ent *x = &c->e[i];
        if (x->kind == 2) GLOG("    #%u 派发 计算 %016llx 线程组 %u（遍 %ux%u 格式 %u）", i, (unsigned long long)x->a, x->n, x->w, x->h, x->fmt);
        else GLOG("    #%u 绘制 顶点 %016llx 片元 %016llx（遍 %ux%u 格式 %u）", i, (unsigned long long)x->a, (unsigned long long)x->b, x->w, x->h, x->fmt); }
}
static void hang_dump(void) {
    uint64_t done = g_gev.signaledValue;
    for (uint64_t f = done + 1; f <= g_gfence && f <= done + HANG_RING; f++) hang_cb_dump("未完成命令缓冲", f);
}
// 原生层全线程现场（s2a_native.h v2.9）。弱缺省：显卡层单测不链原生层时为空操作；宿主 / iOS 包链原生层时强定义覆盖
__attribute__((weak)) int s2a_dump_threads(const char *why) { (void)why; return 0; }
static atomic_int g_gpu_exiting;
static void gal_gpu_exit(const char *head) {
    if (atomic_exchange(&g_gpu_exiting, 1)) { for (;;) pause(); }   // 另一线程已在写现场并退出
    GLOG("【红】%s，立即退出进程（退出码 86）。现场：提交栅栏 %llu / 已完成 %llu，帧 %llu，最后在录的通道 %ux%u 格式 %u 绘制 %u 类 %u",
         head, (unsigned long long)g_gfence, (unsigned long long)g_gev.signaledValue, (unsigned long long)g_gp_frame, g_pass_w, g_pass_h, g_pass_fmt, g_pass_draws, g_pass_kind);
    hang_dump();
    nxgal_bounds_report();   // 越界 / 循环到上限计数（计数关着时为空操作）：卡死前留一份
    s2a_dump_threads(head);  // 全线程现场（原生层 tdump.c：名字 / QoS / 回溯，写 host.log 与 Documents/threads.txt），定是谁卡住了 GPU 等待
    fflush(NULL); _exit(86);
}
void gal_gpu_stall_exit(id<MTLSharedEvent> ev, const char *what, uint64_t want, uint64_t have) {
#if TARGET_OS_IPHONE
    // iPhone：GPU 还在跑（回执没报错）的长命令缓冲不算挂死——10-20 动森进岛第一帧一个命令缓冲 6945 绘制，GPU 跑超 3 秒、栅栏不动、回执无错误码，原先 3 秒即杀是误判。
    // 3 秒起每秒报警一行，继续等到栅栏前进或系统回执报错（走 gal_gpu_error_exit），满 GAL_STALL_IOS_S 秒才判卡死。Mac 照旧 3 秒即退（本机卡死 GPU 曾拖到整机看门狗重启）
    if (!g_gpu_exiting) {
        uint64_t f0 = g_gev.signaledValue;
        for (int s = 0; s < GAL_STALL_IOS_S && !atomic_load(&g_gpu_exiting); s++) {
            // 先核再报：改前先打再核，睡 1 秒后等的那个已经做完时仍打一行「已 N 秒」（带此刻已前进的主栅栏），读着像「栅栏早到了、等的人没醒」（10-22 暗黑3 被当成丢唤醒，实为一个命令缓冲执行 4007 ms）
            uint64_t got = ev.signaledValue;
            if (got >= want) { if (s) GLOG("GPU 慢：等%s %llu 约 %d 秒后已完成（等的事件已到 %llu），继续", what, (unsigned long long)want, 3 + s, (unsigned long long)got); return; }   // 等的那个已经做完：调用方照常往下走
            GLOG("【红】GPU 慢：等%s %llu 已 %d 秒（等的事件已到 %llu；主栅栏已完成 %llu / 提交 %llu），系统回执没报错，继续等", what, (unsigned long long)want, 3 + s, (unsigned long long)got, (unsigned long long)g_gev.signaledValue, (unsigned long long)g_gfence);
            if (g_gev.signaledValue > f0) { f0 = g_gev.signaledValue; s = -1; }   // 栅栏在前进：GPU 没停，重新计时
            usleep(1000000);
        }
    }
    static atomic_int g_stalled;
    // iPhone：再等至多 5 秒让卡住的命令缓冲的执行回执到达（Hang / PageFault / InnocentVictim 错误码由回执里的 error 带出，走 gal_gpu_error_exit 打现场）。
    // Mac 不等：本机卡死 GPU 曾拖到 WindowServer 看门狗重启整机，3 秒即退是机械保护
    if (!atomic_exchange(&g_stalled, 1)) { GLOG("GPU 卡死：等%s %llu 超过 %d 秒（已到 %llu），再等至多 5 秒取执行回执错误码", what, (unsigned long long)want, GAL_STALL_MS / 1000, (unsigned long long)have);
        for (int i = 0; i < 50 && !atomic_load(&g_gpu_exiting); i++) usleep(100000); }
#endif
    char h[200]; snprintf(h, sizeof h, "GPU 卡死：等%s %llu 超过 %d 秒（已到 %llu；回执没带错误码）", what, (unsigned long long)want, GAL_STALL_MS / 1000, (unsigned long long)have); gal_gpu_exit(h);
}
// 连坐丢弃（InnocentVictim：GPU 因别处出错复位，本缓冲无辜被丢）不说明谁肇事。10-21 测试设备2 巫师3 第 1111 帧主队列只收到这一条就退了，肇事者没留下：
// 第一条是连坐时不在回执线程里退（两条队列的回执可能同一线程送达，堵住就收不到另一条），另起线程等至多 1 秒，期间别的回执照打（带队列名）再退；
// 1 秒内没有第二条 = 肇事者不在本进程的两条队列里。非连坐错误（本缓冲自己挂死 / 缺页）照旧当场退
static char g_err_head[1200];
static void *gpu_victim_wait(void *a) {
    (void)a; extern atomic_int g_gpu_errs;
    for (int i = 0; i < 20 && atomic_load(&g_gpu_errs) < 2; i++) usleep(50000);
    if (atomic_load(&g_gpu_errs) < 2) GLOG("【红】GPU 连坐丢弃后 1 秒内没收到本进程别的命令缓冲出错回执：肇事者不在主队列 / 上屏队列（别的进程或系统组件）");
    gal_gpu_exit(g_err_head); return NULL;
}
atomic_int g_gpu_errs;
void gal_gpu_error_exit(const char *who, NSError *err) {
    const char *d = err.description.UTF8String; int k = atomic_fetch_add(&g_gpu_errs, 1);
    if (k > 0) { GLOG("【红】GPU %s命令缓冲执行出错（第 %d 条回执，栅栏已完成 %llu / 提交 %llu）：%s", *who ? who : "主队列", k + 1, (unsigned long long)g_gev.signaledValue, (unsigned long long)g_gfence, d); return; }
    snprintf(g_err_head, sizeof g_err_head, "GPU %s命令缓冲执行出错：%s", who, d);
    pthread_t t;
    if (strstr(d, "InnocentVictim") && !pthread_create(&t, NULL, gpu_victim_wait, NULL)) {
        GLOG("GPU %s命令缓冲被连坐丢弃（InnocentVictim）：等至多 1 秒收本进程其余回执、找肇事者再退", *who ? who : "主队列"); pthread_detach(t); return; }
    gal_gpu_exit(g_err_head);
}
// 主队列回执出错：先打出这个缓冲自己（按栅栏号）录下的绘制 / 派发清单——10-21 巫师3 测试设备1 第 1110 帧肇事回执是 GPU 地址缺页，
// 但退出时栅栏已全部完成、未完成清单为空，不知道缺页的是哪个缓冲、画的什么
void gal_gpu_error_cb(NSError *err, uint64_t fence) {
    if (!atomic_load(&g_gpu_exiting)) hang_cb_dump(strstr(err.description.UTF8String, "InnocentVictim") ? "被连坐的命令缓冲" : "出错的命令缓冲", fence);
    gal_gpu_error_exit("", err);
}
NXGAL_API void nxgal_test_fence_stall(void) { GAL_API_LOCK(); gal_wait(++g_gfence); }   // iPhone 上 3 + 20 秒后才退   // 单测钩子：等一个永不发信号的栅栏（期望 3 秒内 _exit(86)）
NXGAL_API void nxgal_test_cb_error(void) { gal_gpu_error_exit("（单测）", [NSError errorWithDomain:@"MTL4CommandQueueErrorDomain" code:2 userInfo:nil]); }   // 单测钩子：命令缓冲报错路径（期望 _exit(86)）
// 单测钩子：连坐丢弃路径（期望先打「被连坐丢弃」，1 秒内收第二条回执照打，然后 _exit(86)）
NXGAL_API void nxgal_test_cb_victim(int second) {
    gal_gpu_error_exit("", [NSError errorWithDomain:@"S2A单测" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)"}]);
    if (second) { usleep(200000); gal_gpu_error_exit("上屏", [NSError errorWithDomain:@"S2A单测" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Page fault（单测）"}]); }
    for (;;) pause();
}
// ---------- 后台闸门（10-20 维护者 测试设备1 塞尔达：切后台后还在提交，系统拒「Insufficient Permission (to submit GPU work from background)」，走出错退出）----------
// iOS 规矩：App 进后台后不许再向 GPU 提交，进后台前已提交的要做完。全部提交口（主队列 gal_commit / 非录制线程读回 / 出图队列）进出都过这道闸：
// 关闸（App 失去前台，app.m）= 不放新的提交者进来、等已在闸内的出去、再等已提交的工作在 GPU 上做完；开闸（回前台）= 放行，被挡的接着提交，游戏不重开
static pthread_mutex_t g_hold_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_hold_cv = PTHREAD_COND_INITIALIZER;
static int g_hold, g_in_gate;
void gal_gate_enter(void) { pthread_mutex_lock(&g_hold_mu); while (g_hold) pthread_cond_wait(&g_hold_cv, &g_hold_mu); g_in_gate++; pthread_mutex_unlock(&g_hold_mu); }
void gal_gate_leave(void) { pthread_mutex_lock(&g_hold_mu); if (--g_in_gate == 0) pthread_cond_broadcast(&g_hold_cv); pthread_mutex_unlock(&g_hold_mu); }
int gal_gate_held(void) { pthread_mutex_lock(&g_hold_mu); int h = g_hold; pthread_mutex_unlock(&g_hold_mu); return h; }
NXGAL_API void nxgal_gpu_hold(int on, const char *why) {
    uint64_t t0 = mach_absolute_time(); static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    pthread_mutex_lock(&g_hold_mu);
    if (!on) { int was = g_hold; g_hold = 0; pthread_cond_broadcast(&g_hold_cv); pthread_mutex_unlock(&g_hold_mu); if (was) GLOG("GPU 闸门：开（%s），恢复提交", why); return; }
    if (g_hold) { pthread_mutex_unlock(&g_hold_mu); return; }
    g_hold = 1;
    // 进后台：设备归档立刻写盘（iOS 之后可能直接杀进程）
    gal_pso_dev_flush("进后台");
    // 闸内的提交者（出图线程可能卡在取画布上，≤1 秒）出去后，已提交的栅栏值才是全集
    struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 3;
    while (g_in_gate > 0) if (pthread_cond_timedwait(&g_hold_cv, &g_hold_mu, &dl)) break;
    int left = g_in_gate; uint64_t f = g_gfence;
    pthread_mutex_unlock(&g_hold_mu);
    int ok = !g_gev || [g_gev waitUntilSignaledValue:f timeoutMS:3000];
    int pok = gal_present_drain(3000);
    double ms = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
    if (left || !ok || !pok) GLOG("【红】GPU 闸门：关（%s）没收干净：闸内还剩 %d 个提交者、主队列栅栏 %llu %s、出图队列 %s（%.0f ms）", why, left, (unsigned long long)f, ok ? "已做完" : "3 秒没做完", pok ? "已做完" : "3 秒没做完", ms);
    else GLOG("GPU 闸门：关（%s），停止提交，已提交的做完（主队列栅栏 %llu，%.1f ms）", why, (unsigned long long)f, ms);
}
// ---------- 空闲保驻留（10-21 帧率能耗线）----------
// GPU 空闲约 1 秒，驱动就把队列挂着的整套驻留集（本进程 600–900 MB）放掉；requestResidency 挡不住（当时的空闲驻留探针 S2A_PROBE_RESIDENT 实测，10-28 已删，读数见 docs/坑记录.md；Mac MTL4 队列实测）。
// 读盘 / 建管线这类 2 秒以上的长帧之后，下一条命令缓冲要一次重钉整套，iPhone 上钉不全（IOGPUCommandDescriptor::prepare preparedBytes < requiredBytes），
// GPU 踩到没钉的页，4.00 秒后驱动判通道超时（AGX Channel error 2）——怪猎 / 暗黑2 场景切换的 4 秒冻结。
// 机制：主队列 300 ms 没提交，就在另一条挂同一驻留集的队列上提交一条只写 4 字节的命令缓冲，驻留一直保持，不再整段重钉。
// 正常出帧（≤ 33 ms 一次提交）永远不触发；过后台闸门（进后台不提交）
static _Atomic uint64_t g_sub_ns;   // 主队列最近一次提交（CLOCK_UPTIME_RAW 纳秒）
static void sub_note(void) { atomic_store_explicit(&g_sub_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), memory_order_relaxed); }
static void *keepres_main(void *arg) {
    (void)arg; pthread_setname_np("gal-keepres");
    // 老队列（Metal 3 接口，iOS 18 / macOS 15 起可挂驻留集，见 gal_be.h）：不新增 Metal 4 直接调用，Metal 3 兼容路径同样适用
    id<MTLCommandQueue> q; id<MTLBuffer> b; uint64_t n = 0, eps = 0;
    @autoreleasepool {
        q = [g_gdev newCommandQueue]; b = [g_gdev newBufferWithLength:16 options:MTLResourceStorageModePrivate];
        if (!q || !b) { GLOG("【红】空闲保驻留：建队列 / 缓冲失败，不保活"); return NULL; }
        [q addResidencySet:g_gres];
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    // 心跳时刻单独记（hb），不写进主队列提交时刻：否则下一轮把自己的心跳当成主队列恢复提交，长空闲里每 300 ms 假报一次「恢复提交」（10-21 马车8 卡死局）
    // 恢复 = 主队列提交时刻离开了进入空闲时记下的值（idle_last）
    int idle = 0; uint64_t hb = 0, idle_last = 0;
    for (;;) {
        usleep(100000);
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), last = atomic_load_explicit(&g_sub_ns, memory_order_relaxed);
        if (idle && last != idle_last) { GLOG("空闲保驻留：主队列恢复提交，本次空闲保活 %llu 条", (unsigned long long)n); idle = 0; n = 0; }
        // 心跳之间也按主队列的口径算：距主队列提交与上次心跳中较晚者满 300 ms 才再发
        if (!last || now - (last > hb ? last : hb) < 300000000ull) continue;
        if (!idle) { idle = 1; idle_last = last; eps++; if (eps <= 20) GLOG("空闲保驻留：主队列 %.0f ms 没提交，开始保活（第 %llu 次）", (now - last) / 1e6, (unsigned long long)eps); }
        @autoreleasepool {
            gal_gate_enter();
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be fillBuffer:b range:NSMakeRange(0, 4) value:0]; [be endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; dispatch_semaphore_signal(done); }];
            [cb commit];
            gal_gate_leave();
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC));
        }
        n++;
        hb = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    }
    return NULL;
}
// ---------- 提交与等待 ----------
// 按遍汇总（NXGAL_PERF_PASSCOMMIT=1 时，诊断）：一遍一个命令缓冲，回执里按「遍尺寸 格式 类别 首条着色器键」累加 GPU 执行时间与附件读写，
// 每 10 秒打累计前 20（每帧均摊 = 累计 / 帧数）。10-22 塞尔达逐遍拆账：编码器时间戳跨计算 / 渲染两通道排序不能当执行时间，xctrace 标签导不出
static void pass_agg(uint64_t efr, uint32_t w, uint32_t h, uint32_t fmt, uint32_t draws, uint32_t kind, uint64_t ns, uint64_t ld, uint64_t st, uint64_t ka, uint64_t kb, int cont, void *w0, void *w1, void *w2) {
    enum { PA_N = 2048 };
    static struct { uint32_t w, h, fmt, kind; uint64_t ka, kb, ns, n, draws, ld, st, nc1, nc2; void *why[3]; } t[PA_N];
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static uint64_t f0, last, miss;
    pthread_mutex_lock(&mu);
    // 逐遍日志（诊断，NXGAL_PASS_LOG=<文件>，缺省关）：每遍一行「帧（提交时的帧号）宽 高 格式 类别 绘制数 GPU ns 首条顶点键」，按固定帧段比 A/B（汇总按秒打、窗口不定）
    { static FILE *pl; static int pli = -1; if (pli < 0) { const char *v = getenv("NXGAL_PASS_LOG"); char pp[1024];
          if (v && *v && *v != '/') { snprintf(pp, sizeof pp, "%s/Documents/%s", getenv("HOME") ? getenv("HOME") : ".", v); v = pp; }   // 相对路径按 $HOME/Documents（真机局 --pull 拉回）
          pl = v && *v ? fopen(v, "w") : NULL; pli = pl != NULL; }
      if (pl) fprintf(pl, "%llu\t%u\t%u\t%u\t%u\t%u\t%llu\t%016llx\n", (unsigned long long)efr, w, h, fmt, kind, draws, (unsigned long long)ns, (unsigned long long)ka); }
    if (!f0) f0 = g_gp_frame + 1;
    uint64_t hh = (ka * 0x9E3779B97F4A7C15ull) ^ (kb * 0xC2B2AE3D27D4EB4Full) ^ ((uint64_t)w << 40 | (uint64_t)h << 20 | (uint64_t)fmt << 4 | kind);
    unsigned k = (unsigned)(hh % PA_N), i;
    for (i = 0; i < PA_N; i++, k = (k + 1) % PA_N) {
        if (!t[k].n) { t[k].w = w; t[k].h = h; t[k].fmt = fmt; t[k].kind = kind; t[k].ka = ka; t[k].kb = kb; break; }
        if (t[k].w == w && t[k].h == h && t[k].fmt == fmt && t[k].kind == kind && t[k].ka == ka && t[k].kb == kb) break;
    }
    if (i == PA_N) miss++;
    else { t[k].ns += ns; t[k].n++; t[k].draws += draws; t[k].ld += ld; t[k].st += st;
        if (cont == 1) t[k].nc1++; else if (cont == 2) t[k].nc2++;
        if (cont) { t[k].why[0] = w0; t[k].why[1] = w1; t[k].why[2] = w2; } }
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t now = mach_absolute_time() * tb.numer / tb.denom;
    static double iv = -1; if (iv < 0) { const char *v = getenv("NXGAL_PASS_AGG_S"); iv = v ? atof(v) : 10; }   // 打印间隔秒（单测正对照设 0）
    if (now - last >= (uint64_t)(iv * 1e9)) {
        last = now;
        uint64_t fr = g_gp_frame >= f0 ? g_gp_frame - f0 + 1 : 1, tot = 0;
        for (int j = 0; j < PA_N; j++) tot += t[j].ns;
        GLOG("[按遍汇总] 帧 %llu（累计 %llu 帧）：GPU 合计 %.2f ms/帧，前 20（每帧均摊 / 占比 / 次数 / 平均每次 / 平均绘制数 / 每次读入 + 存回 MB）：", (unsigned long long)g_gp_frame, (unsigned long long)fr, tot / 1e6 / fr);
        static uint8_t done[PA_N]; memset(done, 0, sizeof done);
        for (int r = 0; r < 20; r++) {
            int b = -1; for (int j = 0; j < PA_N; j++) if (t[j].n && !done[j] && (b < 0 || t[j].ns > t[b].ns)) b = j;
            if (b < 0) break;
            done[b] = 1;
            GLOG("[按遍汇总]   %.2f ms/帧 %4.1f%% ×%llu 平均 %.3f ms 绘制 %.0f 读入 %.1f + 存回 %.1f MB：%s %ux%u 格式 %u 首条 %016llx / %016llx", t[b].ns / 1e6 / fr, tot ? 100.0 * t[b].ns / tot : 0.0,
                 (unsigned long long)t[b].n, t[b].ns / 1e6 / t[b].n, (double)t[b].draws / t[b].n, t[b].ld / 1048576.0 / t[b].n, t[b].st / 1048576.0 / t[b].n,
                 t[b].kind == 1 ? "渲染" : "拷贝 / 计算", t[b].w, t[b].h, t[b].fmt, (unsigned long long)t[b].ka, (unsigned long long)t[b].kb);
            if (t[b].nc1 || t[b].nc2) {
                const char *nm[3] = {"?", "?", "?"}; Dl_info di;
                for (int q = 0; q < 3; q++) if (t[b].why[q] && dladdr(t[b].why[q], &di) && di.dli_sname) nm[q] = di.dli_sname;
                GLOG("[按遍汇总]       与上一遍附件完全相同 %llu 次、部分共用 %llu 次；上一遍收于 %s ← %s ← %s", (unsigned long long)t[b].nc1, (unsigned long long)t[b].nc2, nm[0], nm[1], nm[2]);
            }
        }
        if (miss) GLOG("[按遍汇总]   表满没记 %llu 次", (unsigned long long)miss);
    }
    pthread_mutex_unlock(&mu);
}
// Metal 3 提交（gal_be.h 表中「命令提交 / 分配器」）：每条命令缓冲单独提交，完成回调替代 MTL4CommitFeedback，栅栏仍用 g_gev 递增。
// 没有分配器轮换 / 分段 / MTL4CommitOptions；遍前段 Metal 3 下不分（gal_render_begin_desc），预载是单独一条老命令缓冲（preload_enc3），排在在录缓冲之前提交。
// GPU 挂死看门狗接线（gal_gpuwd.m，T10 / #635，NXGAL_GPU_WD_MS 不设 = 关、不建线程）。
// 与上面 gal_gpu_stall_exit 的分工写在 gal_gpuwd.h 顶部：那个长在「等栅栏的那条线程」里，本模块长在一条独立线程上，
// 只按「提交时刻 → 现在」算年龄，所以全部线程都堵在无超时的 Metal 调用里时它照样能判、能退。
// 现场（帧号 / 本批绘制数 / 最后在录通道）由提交线程在登记时填进 gal_gpuwd_scene，看门狗判死时只格式化这些整数，
//   不回调这里、不读 g_pass_* 现值、不调 g_gev.signaledValue（审计 #772 F-gpuwd-scene-live）。日志走 GLOG，行格式与其余读数一致
static void gpuwd_log(const char *line) { GLOG("%s", line); }
static void gpuwd_wire(void) {
    static int done;
    if (done) return;
    done = 1;
    gal_gpuwd_set_log(gpuwd_log);
}
static uint64_t gal_commit_mtl3(void) {
    // 同 Metal 4：先落缓冲的挂起拷回（可能开拷贝编码器）、收渲染通道
    g_in_commit = 1;
    gal_buf_commit_flush();
    gal_pass_close();
    if (!g_cb3) { g_in_commit = 0; return g_gfence; }
    gal_enc_end();
    g_in_commit = 0;
    if (g_gres_dirty) { RS_SCOPE(RS_RESCOMMIT); [g_gres commit]; g_gres_dirty = 0; }
    uint64_t fr = g_gp_frame; int last = g_gp_commit_present;
    if (last) { g_gp_commit_present = 0; g_gp_frame++; }
    uint64_t cfence = g_gfence + 1;
    uint32_t cdraws3 = g_cb_draws, cencs3 = g_cb_encs;   // hang_seal 会清零，登记看门狗前先留一份
    hang_seal(cfence);
    gpuwd_wire(); gal_gpuwd_on_commit(cfence, &(gal_gpuwd_scene){cdraws3, cencs3, fr, g_pass_w, g_pass_h, g_pass_fmt, g_pass_draws, g_pass_kind});
    if (g_pcb3) {
        // 预载收尾：更新 g_fence3（在录缓冲里此后开的编码器等它），再写事件让在录缓冲推进主栅栏前等预载做完
        enc_fence_update3(g_penc3, 0); [g_penc3 endEncoding]; g_penc3 = nil;
        if (!g_pev3) g_pev3 = [g_gdev newSharedEvent];
        [g_pcb3 encodeSignalEvent:g_pev3 value:++g_pev3_n];
        [g_cb3 encodeWaitForEvent:g_pev3 value:g_pev3_n];
    }
    [g_cb3 encodeSignalEvent:g_gev value:cfence];
    atomic_fetch_add(&g_session_feedback, 1);
    [g_cb3 addCompletedHandler:^(id<MTLCommandBuffer> c) {
        uint64_t ns = c.GPUEndTime > c.GPUStartTime ? (uint64_t)((c.GPUEndTime - c.GPUStartTime) * 1e9) : 0;
        g_gp_gpu_ns += ns; g_gp_cmdbufs++;
        g_fr_acc[fr & 7] += ns;
        if (last) { g_last_fr_ns = g_fr_acc[fr & 7]; g_fr_acc[fr & 7] = 0; g_last_fr = fr; }
        gal_cnt_on_cb_done(cfence, c.GPUEndTime);
        gal_gpuwd_on_done(cfence);   // 看门狗（缺省关）：同队列按提交序完成，栅栏连续推进
        if (c.error) gal_gpu_error_cb(c.error, cfence);
        uint64_t o = atomic_load(&g_cb3_done); while (o < cfence && !atomic_compare_exchange_weak(&g_cb3_done, &o, cfence)) {}
        atomic_fetch_sub(&g_session_feedback, 1);
    }];
    gal_gate_enter();
    // 预载先提交：同一队列按提交序开始，预载编码器收尾更新的 g_fence3 排在在录缓冲各编码器之前
    if (g_pcb3) { [g_pcb3 commit]; g_pcb3 = nil; }
    [g_cb3 commit];   // Metal 3 的命令缓冲没有 endCommandBuffer：直接 commit
    gal_gate_leave();
    uint64_t f = ++g_gfence;
    if (f != g_cb_fence) GRED_ONCE("【缺陷】Metal 3 在录命令缓冲提交时的栅栏 %llu ≠ 开录时的身份 %llu：录制期间有别的提交占了主栅栏号", (unsigned long long)f, (unsigned long long)g_cb_fence);
    g_cb3 = nil;
    if (g_api_depth > 0) g_entry_committed = 1;
    sync_fill(f);
    sub_note();
    transient_retire(f);
    tg_trim();
    dead_reap();
    gal_cnt_on_commit();
    return f;
}
uint64_t gal_commit(void) {
    if (g_gal_be != GAL_BE_MTL4) return gal_commit_mtl3();
    GP_SCOPE(GP_COMMIT);
    int cwhy = g_cwhy; g_cwhy = 0;
    g_in_commit = 1;
    gal_buf_commit_flush();
    gal_icnt_batch_flush();   // 预载里攒的间接计数整理：预载编码器收口前一个派发做完（gal_draw.m）
    gal_pass_close();   // 挂起清屏不随提交落实：之后要观察它的只有读回 / 出图 / 采样，各自入口已按涉及的贴图落实
    if (!g_gcb) { g_in_commit = 0; return g_gfence; }
    commit_site_note();
    gal_enc_end();
    g_in_commit = 0;
    if (g_gres_dirty) { RS_SCOPE(RS_RESCOMMIT); [g_gres commit]; g_gres_dirty = 0; }
    uint32_t ets_n; int ets_s = ets_seal(g_gcb, &ets_n);
    [g_gcb endCommandBuffer]; pre_close(); g_pre_ok = 0;
    // 提交序：预载、已收的各段（含遍前段）、在录段
    static __unsafe_unretained id *bufs; static int capb;
    if (capb < g_nsegs + 2) { capb = g_nsegs + 2; bufs = (__unsafe_unretained id *)realloc((void *)bufs, (size_t)capb * sizeof *bufs); }
    int nb = 0, cpre = g_pcb != nil;
    if (g_pcb) { [g_penc endEncoding]; ets_cb(g_pcb, 8); [g_pcb endCommandBuffer]; bufs[nb++] = g_pcb; }
    for (int i = 0; i < g_nsegs; i++) bufs[nb++] = (__bridge id)g_segs[i];
    bufs[nb++] = g_gcb;
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    uint64_t fr = g_gp_frame; int last = g_gp_commit_present;
    uint32_t lw = g_pass_w, lh = g_pass_h, lf = g_pass_fmt, ld = g_pass_draws, lk = g_pass_kind; g_pass_draws = 0; g_pass_kind = 2;
    uint64_t lka = g_pass_ka, lkb = g_pass_kb; g_pass_kset = 0; g_pass_ka = g_pass_kb = 0;
    int lcont = lk == 1 ? g_pass_cont : 0; void *lw0 = g_pass_why[0], *lw1 = g_pass_why[1], *lw2 = g_pass_why[2];
    uint64_t lld = g_pass_ld, lst = g_pass_st; g_pass_ld = g_pass_st = 0; g_rw_total += lld + lst;
    if (last) { g_gp_commit_present = 0; g_gp_frame++; }
    uint64_t cfence = g_gfence + 1; uint32_t cdraws = g_cb_draws, cencs = g_cb_encs;
    if (last) cwhy = 2;
    if (g_galloc_cur >= 0) g_galloc_why[g_galloc_cur] = (uint8_t)cwhy;
    if (bp_diag()) atomic_fetch_add(&g_bpd_commits[cwhy], 1);
    static mach_timebase_info_data_t ctb; if (!ctb.denom) mach_timebase_info(&ctb);
    double tc = (double)mach_absolute_time() * ctb.numer / ctb.denom / 1e9;   // 与 GPUStartTime 同一主机时基（秒）
    hang_seal(cfence);
    // 在 commit 之前登记：提交瞬间就挂死也覆盖得到。通道读数用清零前留下的 lw..lk（g_pass_draws / g_pass_kind 上面已改成 0 / 2）
    gpuwd_wire(); gal_gpuwd_on_commit(cfence, &(gal_gpuwd_scene){cdraws, cencs, fr, lw, lh, lf, ld, lk});
    atomic_fetch_add(&g_session_feedback, 1);
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        uint64_t ns = f.GPUEndTime > f.GPUStartTime ? (uint64_t)((f.GPUEndTime - f.GPUStartTime) * 1e9) : 0;
        // 慢命令缓冲拆「排队（提交 → GPU 开始）/ 执行（开始 → 结束）」：M1 iPhone 读回等 4 秒，分清是排在前面的活还是本缓冲自己慢
        double qms = f.GPUStartTime > 0 ? (f.GPUStartTime - tc) * 1e3 : -1;
        static double slow = -1; if (slow < 0) { const char *v = getenv("NXGAL_SLOWCB_MS"); slow = v ? atof(v) : 100; }   // 阈值可调：正对照用 1
        if (ns / 1e6 > slow || qms > slow) GLOG("【红】慢命令缓冲：栅栏 %llu（帧 %llu，绘制 + 派发 %u%s）排队 %.0f ms、执行 %.0f ms", (unsigned long long)cfence, (unsigned long long)fr, cdraws, cpre ? "，带预载" : "", qms, ns / 1e6);
        g_gp_gpu_ns += ns; g_gp_cmdbufs++;
        if (bp_diag()) atomic_fetch_add(&g_bpd_gpu_ns[cwhy], ns);
        gal_cnt_on_cb_done(cfence, f.GPUEndTime);   // 时间戳计数（S2A_GPU_TS）：这次提交的 GPU 结束时刻
        gal_gpuwd_on_done(cfence);   // 看门狗（缺省关）：一次提交一个回执，栅栏连续推进
        if (g_passcommit > 0) pass_agg(fr, lw, lh, lf, ld, lk, ns, lld, lst, lka, lkb, lcont, lw0, lw1, lw2);
        if (g_passcommit > 0) { uint32_t k = g_pass_n++; if (k < PASS_RING) { g_pass_ring[k].w = lw; g_pass_ring[k].h = lh; g_pass_ring[k].fmt = lf; g_pass_ring[k].draws = ld; g_pass_ring[k].kind = lk; g_pass_ring[k].ns = ns; g_pass_ring[k].ld = lld; g_pass_ring[k].st = lst; } }
        // 同队列命令缓冲按提交序完成：帧末（出图）那个完成时，同帧之前的都已完成并记进槽里
        g_fr_acc[fr & 7] += ns;
        if (last) {
            g_last_fr_ns = g_fr_acc[fr & 7]; g_fr_acc[fr & 7] = 0; g_last_fr = fr;
            static int pf = -1; if (pf < 0) pf = getenv("NXGAL_GPU_FRAMES") != NULL;   // 诊断：每帧 GPU 时间（同帧各命令缓冲 GPU 段之和）
            if (pf) fprintf(stderr, "[gpu] 帧 %llu %.2f ms\n", (unsigned long long)fr, g_last_fr_ns / 1e6);
        }
        ets_done(ets_s, ets_n, cfence, fr, ns);
        if (f.error) gal_gpu_error_cb(f.error, cfence);
        atomic_fetch_sub(&g_session_feedback, 1);
    }];
    gal_gate_enter();
    [g_gq commit:(__unsafe_unretained id<MTL4CommandBuffer> *)bufs count:nb options:o];
    for (int i = 0; i < g_nsegs; i++) CFBridgingRelease(g_segs[i]);
    g_nsegs = 0; g_pcb = nil; g_penc = nil;
    if (g_api_depth > 0) g_entry_committed = 1;
    uint64_t f = ++g_gfence; [g_gq signalEvent:g_gev value:f];
    sync_fill(f);
    gal_gate_leave();
    // 在录期间按 g_cb_fence 记下的延后释放 / 临时内存 / 已用区间都以为本缓冲的栅栏是它；不等 = 有人在录制中途挪了主栅栏号，那些登记全错位
    sub_note();
    if (f != g_cb_fence) GRED_ONCE("【缺陷】在录命令缓冲提交时的栅栏 %llu ≠ 开录时的身份 %llu：录制期间有别的提交占了主栅栏号，挂在旧号上的延后释放会早放（命令缓冲引用失效资源）", (unsigned long long)f, (unsigned long long)g_cb_fence);
    g_galloc_fence[g_galloc_cur] = f; g_gcb = nil;
    if (bp_diag()) bp_diag_note();
    transient_retire(f);
    tg_trim();
    dead_reap();
    gal_cnt_on_commit();
    return f;
}
uint64_t gal_done(void) { return g_gev.signaledValue; }
// 诊断 NXGAL_WAIT_SITE=1（缺省关）：CPU 等 GPU 按调用链累计毫秒 / 次数 / 单次最长，每 5 秒打一次累计 ≥ 100 ms 的（镜像内偏移，atos -o <宿主> -l 0x100000000 符号化）。
// 统计全部等栅栏：rb = 读回 / 同步号（frames.tsv rb_us，含非录制线程读回的一次性命令缓冲 gal_readback_finish），bp = 分配器环反压（gpuq_us）。
// 10-21 怪猎村子每帧近 1 秒的旧 rb_us 实为 gal_cb_begin 等命令分配器（GPU 每帧执行近 700 ms），读回全局只 74 次；之后 frames.tsv 拆成 rb_us 与 gpuq_us。
// 调用链取 8 层（原 3 层只到 nxgal_* 入口，分不出 Gpu 层哪个调用点：WaitForAndFlushRanges / TextureGroupHandle.Sync / 读回各走哪条）；线程名与是否渲染线程也进键（同一调用链在客体线程与渲染线程上分开记）
__attribute__((noinline)) static void wait_site_note(uint64_t ns, int rb) {
    static int ws = -1; if (ws < 0) ws = getenv("NXGAL_WAIT_SITE") != NULL;
    if (!ws) return;
    // 打印门槛 NXGAL_WAIT_SITE_MIN_MS（缺省 100 ms，与原来硬编码值一致）：读回量小的游戏（丝之歌实测每局
    // 只有 2 帧非零、合计 4 ms）在 100 ms 门槛下一条都不打，调小才看得见分布。缺省行为不变。
    static uint64_t MINNS = 0; if (!MINNS) { const char *v = getenv("NXGAL_WAIT_SITE_MIN_MS"); double ms = v ? atof(v) : 100.0; if (ms <= 0) ms = 100.0; MINNS = (uint64_t)(ms * 1e6); if (!MINNS) MINNS = 100000000ull; }
    // 调用链深度 NXGAL_WAIT_SITE_DEPTH（缺省 8，最多 24）：10-22 八方2 每帧贴图回写只看到 FlushAction，看不到 GPU 线程上是谁触发的
    enum { K = 128, DMAX = 24 };
    static int D = -1; if (D < 0) { const char *v = getenv("NXGAL_WAIT_SITE_DEPTH"); D = v ? atoi(v) : 8; if (D < 1) D = 1; if (D > DMAX) D = DMAX; }
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    static void *kp[K][DMAX]; static uint64_t kn[K], kc[K], kmax[K], last; static char kt[K][24]; static uint8_t kk[K];
    void *bt[DMAX + 2]; int n = backtrace(bt, D + 2);
    int rec = gal_on_rec_thread();
    char tn[24] = {0}; pthread_getname_np(pthread_self(), tn, sizeof tn);
    pthread_mutex_lock(&mu);
    int i; for (i = 0; i < K && kp[i][0]; i++) { int same = kk[i] == (uint8_t)(rb * 2 + rec) && !strcmp(kt[i], tn); for (int f = 0; f < D && same; f++) same = kp[i][f] == (f + 2 < n ? bt[f + 2] : 0); if (same) break; }
    if (i < K) { if (!kp[i][0]) { for (int f = 0; f < D; f++) kp[i][f] = f + 2 < n ? bt[f + 2] : 0; kk[i] = (uint8_t)(rb * 2 + rec); memcpy(kt[i], tn, sizeof tn); }
        kn[i] += ns; kc[i]++; if (ns > kmax[i]) kmax[i] = ns; }
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t now = mach_absolute_time() * tb.numer / tb.denom;
    if (now - last > 5000000000ull) { last = now;
        for (int j = 0; j < K && kp[j][0]; j++) { if (kn[j] < MINNS) continue;
            fprintf(stderr, "[waitsite] %s %.0f ms ×%llu 最长 %.1f ms 线程 %s%s", kk[j] >> 1 ? "rb" : "bp", kn[j] / 1e6, (unsigned long long)kc[j], kmax[j] / 1e6, kt[j][0] ? kt[j] : "?", kk[j] & 1 ? "（录制）" : "（非录制）");
            for (int f = 0; f < D; f++) { Dl_info di; if (kp[j][f] && dladdr(kp[j][f], &di)) fprintf(stderr, " ← %s+%#lx", strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname, (unsigned long)((char *)kp[j][f] - (char *)di.dli_fbase)); else if (kp[j][f]) fprintf(stderr, " ← %p", kp[j][f]); }
            fputc('\n', stderr); } }
    pthread_mutex_unlock(&mu);
}
// 诊断 NXGAL_COMMIT_WHY=1（缺省关）：真提交按调用链（gal_commit 往上 6 层）计次，每 10 秒打一次累计前 12 的（镜像内偏移，atos -o <宿主> -l 0x100000000 符号化）
__attribute__((noinline)) static void commit_site_note(void) {
    static int on = -1; if (on < 0) on = getenv("NXGAL_COMMIT_WHY") != NULL;
    if (!on) return;
    enum { K = 64, D = 6 };
    static void *kp[K][D]; static uint64_t kc[K], tot, last;
    void *bt[D + 2]; int n = backtrace(bt, D + 2);
    int i; for (i = 0; i < K && kp[i][0]; i++) { int same = 1; for (int f = 0; f < D && same; f++) same = kp[i][f] == (f + 2 < n ? bt[f + 2] : 0); if (same) break; }
    if (i < K) { if (!kp[i][0]) for (int f = 0; f < D; f++) kp[i][f] = f + 2 < n ? bt[f + 2] : 0; kc[i]++; }
    tot++;
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t now = mach_absolute_time() * tb.numer / tb.denom;
    if (now - last < 10000000000ull) return;
    last = now;
    fprintf(stderr, "[commitsite] 累计提交 %llu 次（帧 %llu），按调用链：\n", (unsigned long long)tot, (unsigned long long)g_gp_frame);
    for (int r = 0; r < 12; r++) {
        int b = -1; for (int j = 0; j < K && kp[j][0]; j++) if (kc[j] && !(kc[j] >> 63) && (b < 0 || kc[j] > kc[b])) b = j;
        if (b < 0) break;
        fprintf(stderr, "[commitsite]   ×%llu", (unsigned long long)kc[b]);
        for (int f = 0; f < D; f++) { Dl_info di; if (kp[b][f] && dladdr(kp[b][f], &di)) fprintf(stderr, " ← %s+%#lx", strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname, (unsigned long)((char *)kp[b][f] - (char *)di.dli_fbase)); }
        fputc('\n', stderr);
        kc[b] |= 1ull << 63;
    }
    for (int j = 0; j < K; j++) kc[j] &= ~(1ull << 63);
}
// 等栅栏，等的时长记进 acc（只在真要等时计）：读回 / 同步号 → g_wait_ns_total（frames.tsv rb_us、读回阻塞闸门）；分配器环反压 → g_bp_ns_total（gpuq_us）
// Metal 3：主栅栏到了再等这条命令缓冲的完成回调（见 g_cb3_done）——调用方等完常直接放掉它引用的对象（读回暂存等），
// 不保留引用的老命令缓冲要求对象活到完成。完成回调紧跟缓冲尾的栅栏写，通常只差几微秒；没到就一直等、每 3 秒报一次红——
// 不能超时返回：调用方随后放掉对象，等于把「回调不到」这个该停下来查的缺陷变成释放后使用（#136 审查意见）
static void cb3_done_wait(uint64_t fence) {
    uint64_t t0 = 0, next = 3;
    for (int i = 0; atomic_load(&g_cb3_done) < fence; i++) {
        if (i < 100) { sched_yield(); continue; }
        if (!t0) t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        usleep(100);
        uint64_t s = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000000000ull;
        if (s >= next) { GLOG("【红】Metal 3：栅栏 %llu 已到、命令缓冲完成回调 %llu 秒未到（已完成 %llu），继续等", (unsigned long long)fence, (unsigned long long)s, (unsigned long long)atomic_load(&g_cb3_done)); next = s + 3; }
    }
}
static void gal_wait_acc_(uint64_t fence, uint64_t *acc);
static void gal_wait_acc(uint64_t fence, uint64_t *acc) { gal_wait_acc_(fence, acc); if (fence && g_gal_be != GAL_BE_MTL4) cb3_done_wait(fence); }
static void gal_wait_acc_(uint64_t fence, uint64_t *acc) {
    if (!fence || g_gev.signaledValue >= fence) return;
    GP_SCOPE(GP_WAIT);
    uint64_t t0 = mach_absolute_time();
    for (int ms = 0; ![g_gev waitUntilSignaledValue:fence timeoutMS:200]; ms += 200) {
        if (ms + 200 >= GAL_STALL_MS) { gal_gpu_stall_exit(g_gev, "栅栏", fence, g_gev.signaledValue); break; } }   // iPhone 上等到才返回
    { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); uint64_t ns = (mach_absolute_time() - t0) * tb.numer / tb.denom;
      __atomic_fetch_add(acc, ns, __ATOMIC_RELAXED); wait_site_note(ns, acc == &g_wait_ns_total); }
}
void gal_wait(uint64_t fence) { gal_wait_acc(fence, &g_wait_ns_total); }
int gal_wait_fence_timeout(uint64_t fence, int ms) { return g_gev.signaledValue >= fence || [g_gev waitUntilSignaledValue:fence timeoutMS:(uint64_t)(ms > 0 ? ms : 1)]; }
void gal_finish(void) { g_cwhy = 1; gal_wait(gal_commit()); dead_reap(); }

// ---------- 同步号 → 栅栏值 ----------
// create_sync 提交到目前为止的全部命令，记「同步号 → 栅栏值」；wait_sync 等对应栅栏；current_sync 返回已完成的最大同步号
typedef struct { uint64_t id, fence; } sync_ent;
static sync_ent *g_sync; static int g_nsync, g_capsync;
static pthread_mutex_t g_sync_mu = PTHREAD_MUTEX_INITIALIZER;
static void sync_fill(uint64_t f) {   // 提交后：挂起的同步号回填这次的栅栏
    if (!g_sync_pending) return;
    pthread_mutex_lock(&g_sync_mu);
    for (int i = 0; i < g_nsync; i++) if (!g_sync[i].fence) g_sync[i].fence = f;
    g_sync_pending = 0;
    pthread_mutex_unlock(&g_sync_mu);
}

NXGAL_API void nxgal_create_sync(uint64_t id, int strict) { GAL_API_LOCK();
    SW_SCOPE(SW_COMMIT, 3);   // 调度测算：游戏的同步点要求提交（懒同步可免：真等它时才提交）
    int k; gal_cur_enc(&k);
    uint64_t f = 0;
    // 上游口径（sync_lazy_all）：非严格的都挂起；没有在录的命令缓冲时之前的都已提交，直接记已提交栅栏
    // NXGAL_SYNC_STRICT_COMMIT=1 或 S2A_SYNCPT_HOSTSYNC=1（见 sync_strict_commit，缺省关）：严格的当场提交（照上游 Vulkan SyncManager.Create：
    // strict 即 FlushAllCommands），否则严格同步号在渲染遍里挂到遍收尾才提交，同步点推进被拖到遍收尾。关时照旧：遍内挂起
    int lazy = !(strict && sync_strict_commit()) && !prepass_off() && (k == 1 || (sync_lazy_all() && !strict));
    if (lazy && sync_lazy_all() && !g_gcb && !g_cb3) f = g_gfence;
    else if (lazy) { g_sync_pending = 1; g_sync_lazy++; } else { g_cwhy = 3; f = gal_commit(); }
    pthread_mutex_lock(&g_sync_mu);
    // 审计 P1-67：表扩不动就不登记这个号（gal_grow 报红）：等它时走「未登记 = 等全部已提交」那条（nxgal_wait_sync），慢但不错
    int room = g_nsync < g_capsync;
    if (!room) { int nc = g_capsync ? g_capsync * 2 : 64; sync_ent *ns = gal_grow(g_sync, (size_t)nc, sizeof *g_sync, "同步号表"); if (ns) { g_sync = ns; g_capsync = nc; room = 1; } }
    if (room) g_sync[g_nsync++] = (sync_ent){id, f};
    pthread_mutex_unlock(&g_sync_mu);
}
static int ws_diag(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_WAITSYNC_DIAG"); v = e && *e == '1'; } return v; }
static void ws_note(int cls, int rec, uint64_t ticks) {
    static _Atomic uint64_t n[2][4], ns[2][4], mx[2][4]; static _Atomic uint64_t last;
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t d = ticks * tb.numer / tb.denom; rec = !!rec;
    atomic_fetch_add(&n[rec][cls], 1); atomic_fetch_add(&ns[rec][cls], d);
    uint64_t m = atomic_load(&mx[rec][cls]); while (d > m && !atomic_compare_exchange_weak(&mx[rec][cls], &m, d)) {}
    uint64_t now = mach_absolute_time() * tb.numer / tb.denom, l = atomic_load(&last);
    if (now - l < 10000000000ull || !atomic_compare_exchange_strong(&last, &l, now)) return;
    static const char *nm[4] = { "当时还没提交", "已提交未做完", "已做完", "未登记" };
    char b[800]; int o = 0;
    for (int r = 0; r < 2; r++) { o += snprintf(b + o, sizeof b - o, "%s：", r ? "录制线程" : "客体线程");
        for (int c = 0; c < 4; c++) o += snprintf(b + o, sizeof b - o, " %s %llu 次 %.0f ms（最长 %.1f）", nm[c], (unsigned long long)n[r][c], ns[r][c] / 1e6, mx[r][c] / 1e6);
        o += snprintf(b + o, sizeof b - o, "；"); }
    GLOG("[等同步号拆账] 累计 %s", b);
}
NXGAL_API void nxgal_wait_sync(uint64_t id) { GAL_API_LOCK();
    SW_SCOPE(SW_READBACK, 1);
    uint64_t f = 0; int found = 0;
    pthread_mutex_lock(&g_sync_mu);
    for (int i = g_nsync - 1; i >= 0; i--) if (g_sync[i].id == id) { f = g_sync[i].fence; found = 1; break; }
    // 比已登记的最小号还小 = 早已完成并被清掉
    if (!found && g_nsync && id < g_sync[0].id) found = 1;
    pthread_mutex_unlock(&g_sync_mu);
    // 挂起的（懒同步）：当场提交。调用者不是录制线程也提交——它拿着入口锁，录制线程此刻不在任何入口里；不提交的话，
    // 录制线程若不再来命令（客体正等这个同步号），这一遍永远不收、挂起永远不提交，就死锁了
    // 诊断 NXGAL_WAITSYNC_DIAG=1（缺省关，帧率能耗线 10-23 零拷贝方案 §6）：等同步号按「要等的那次同步当时还没提交（当场提交，连整个在录缓冲一起等）/
    // 已提交、GPU 还没做完 / 已做完 / 未登记」分类计次数与等待时长，录制线程与客体线程分开；每 10 秒一行。前者占大头 → 杠杆在早提交；中者 → GPU 本身慢
    int wcls = !found ? 3 : !f ? 0 : g_gev.signaledValue >= f ? 2 : 1;
    if (found && !f) { g_cwhy = 4; f = gal_commit(); }
    // 非录制线程（多线程后端的客体线程直调）不提交别人在录的命令缓冲，只等已提交的（见 gal_readback_enc）
    if (!found) { GRED_ONCE("等未登记的同步号 %llu：按等全部已提交处理", (unsigned long long)id); f = gal_on_rec_thread() ? gal_commit() : g_gfence; }
    if (!ws_diag()) { gal_wait(f); return; }
    uint64_t t0 = mach_absolute_time(); gal_wait(f); ws_note(wcls, gal_on_rec_thread(), mach_absolute_time() - t0);
}
NXGAL_API uint64_t nxgal_current_sync(void) { GAL_API_LOCK();
    uint64_t done = g_gev.signaledValue, best = 0;
    pthread_mutex_lock(&g_sync_mu);
    int keep = 0, last_done = -1;
    for (int i = 0; i < g_nsync; i++) { if (!g_sync[i].fence) break; if (g_sync[i].fence <= done) { last_done = i; if (g_sync[i].id > best) best = g_sync[i].id; } }   // 挂起的（栅栏 0）还没提交：它和之后的都没完成
    // 已完成的只留最大那个（id 单调，表按 id 升序；之后 wait 比它小的走「早已完成」分支）
    if (last_done > 0) { keep = g_nsync - last_done; memmove(g_sync, g_sync + last_done, keep * sizeof *g_sync); g_nsync = keep; }
    pthread_mutex_unlock(&g_sync_mu);
    return best;
}

// ---------- 其余核心入口 ----------
NXGAL_API uint64_t nxgal_abi_hash(void) { return NXGAL_ABI_HASH; }
// 设备是否原生支持 BC1–7 压缩贴图（能力表据此报，不按平台写死：A 系列新机型在 iOS 上也支持，报不支持会让 Gpu 层在 CPU 上解成未压缩、采样带宽涨 4–8 倍）
// ---------- 管线二进制归档（Metal 4 原生：MTL4Archive 查找 + MTL4PipelineDataSetSerializer 收描述）----------
// 首遇建管线在 iPhone 上是秒级长帧的主因（10-19 测试设备1 首局 1955 帧建 129 个 639 ms），着色器已全量静态翻译，管线也要预建：
//   NXGAL_PSO_ARCHIVE=<归档路径>：随包的 Metal 二进制归档（metal-tt 离线编）；每次建管线先按同一描述查它（MTL4Archive newXxxPipelineStateWithDescriptor），
//     查不到再现建。命中 / 未命中计数进初始化后的日志与 nxgal_pso_cache_stats。
//   NXGAL_PSO_SCRIPT=<文件.json>：收管线描述——编译器挂 CaptureDescriptors 序列化器，每次出图（nxgal_present）本帧有新管线就整份重写一次
//     serializeAsPipelinesScript 的输出（metal-tt 的输入格式；先写临时文件再改名，进程被杀也留完整的上一版）；nxgal_shutdown 再写一次。
//   NXGAL_PSO_ARCHIVE_OUT=<路径.metallib>：收本机 GPU 的管线二进制（CaptureBinaries），写法同上（真机种子局直接产 iOS 归档）。
//     与 NXGAL_PSO_SCRIPT 互斥：序列化器两位同开时导出 0 字节且不报错（翻译核心线 10-16 实测、本线 10-19 复现），同开只收描述并报红。
static id<MTL4Archive> g_pso_arch; static id<MTL4PipelineDataSetSerializer> g_pso_ser;
// Metal 3 归档独立试验，缺省关；只读包片与可写设备片不共用对象。
static id<MTLBinaryArchive> g_pso_arch3;
static int m3_archive_on(void) {
    if (gal_be_kind() != GAL_BE_MTL3) return 0;
    static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_M3_ARCHIVE"); on = v && !strcmp(v, "1"); } return on;
}
static id binary_archive3(NSString *path, NSError **e) {
    MTLBinaryArchiveDescriptor *d = [MTLBinaryArchiveDescriptor new];
    if (path) d.url = [NSURL fileURLWithPath:path];
    return [g_gdev newBinaryArchiveWithDescriptor:d error:e];
}
// FailOnBinaryArchiveMiss 禁止借系统编译缓存或现编冒充本归档命中。不修改调用者描述。
static id archive_pipeline3(id archive, id desc, int compute, NSError **e) {
    Class expected = compute ? MTLComputePipelineDescriptor.class : MTLRenderPipelineDescriptor.class;
    if (![desc isKindOfClass:expected]) {
        GRED_ONCE("Metal 3 归档只接受原生旧管线描述（收到 %s）", desc ? class_getName([desc class]) : "空");
        if (e) *e = [NSError errorWithDomain:@"s2a.gal" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Metal 3 归档管线描述类型不对"}];
        return nil;
    }
    id copy = [desc copy];
    if (compute) {
        MTLComputePipelineDescriptor *d = copy; d.binaryArchives = @[archive];
        return [g_gdev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:e];
    }
    MTLRenderPipelineDescriptor *d = copy; d.binaryArchives = @[archive];
    return [g_gdev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:e];
}
// ---------- 着色器包分片归档：按需开片 + 「管线描述 → 片号」索引（10-21 巫师3 起局约 100 秒必崩）----------
// 根因（原生层线现场低区读数）：MTL4Archive 打开时按文件大小 1:1 占地址，138 片 1032 MB 开局全开，占满 64 GB 窗口的款低区只剩 1.3 GB 左右，
//   随后归档片「unable to open file」、Metal 内部 fscache 空指针崩。离线库 metallib 不整片映射（235 片 922 MB 只涨 8 MB），不动。
// 改法：nxgal_pso_archive_open_dir 只登记各片路径与索引 gal_pso.idx，建管线时按描述里的函数名查索引、只开那一片；
//   开片前向原生层「低区统一账」申请（runtime/include/s2a_lowva.h，运行时 dlsym 取 s2a_lowva，取不到 = 单测 / 回放，不记账不设限），
//   账本不给就这片不开（首遇现建）；开成记账。门槛（低区 / 句柄余量）全归账本算，本文件不写。
//   开了不关、不登记腾退回调：iPhone 上关片不还地址（10-21 真机探针 witcher3_1021201918_2：放掉归档对象、管线留着，这片 .bin 的文件映射原块到 2 秒仍在），
//   关片只销账、地址照占，账本以为腾出来了会多放行，再开同一片还多映射一份（原生层线审）。
// 索引（graphics/tools/shbake/pso_gen.py 写）：魔数 "GPSI"、u32 版本 1、u32 条数 n、u32 0，再 n 条 { u64 键, u32 片号, u32 0 } 按键升序；
//   键 = FNV-1a 64(各阶段函数名按 顶点,片元 / 计算 用「,」连接)，与 pso_gen.py pname 同一串。
// 与 runtime/include/s2a_lowva.h 同一布局（版本 1）。不 include 它：渲染器自成一体——xc_key.sh / widen_lib_key.sh 只取 graphics/metal 与 graphics/third_party 两棵树单独编、算缓存键，
//   include 原生层头文件就编不过（10-21 门禁 xc_key_test 红）。布局靠运行时 size / version 校验；原生层改结构须升 S2A_LOWVA_VERSION
typedef uint64_t (*s2a_lowva_evict_fn)(void *ctx, uint64_t want);
typedef struct s2a_lowva_api {
    uint32_t size, version;
    int  (*user)(const char *name, s2a_lowva_evict_fn evict, void *ctx);
    int  (*acquire)(int user, uint64_t bytes, uint64_t contig, int optional, const char *what);
    void (*note)(int user, int64_t delta);
    void (*fail)(int user, uint64_t bytes, const char *what);
    void (*snapshot)(uint64_t *holes, uint64_t *largest, uint64_t *reserve, uint64_t *untracked, uint64_t *tracked);
} s2a_lowva_api;
static NSData *g_pso_idx; static uint32_t g_pso_nidx;
static NSData *g_pso_slots;
static NSMutableArray *g_pa_obj; static NSArray<NSString *> *g_pa_path; static uint64_t *g_pa_bytes;
static NSMutableDictionary<NSString *, NSNumber *> *g_pa_slot;
static pthread_mutex_t g_pa_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pa_changed = PTHREAD_COND_INITIALIZER;
static uint8_t *g_pa_opening;
static const s2a_lowva_api *g_lv; static int g_lv_me;
// 取原生层低区账本（取不到 = 单测 / 回放，不记账不设限；版本 / 大小不符当没有）。只缓存 dlsym 到的取账本函数、每次调它：
// 原生层恒返回同一个；单测的仿真账本只在部分用例里返回非空（t_prog --arch-lazy），缓存「取不到」会让后面的用例接不上
static const s2a_lowva_api *lv_get(void) {
    static int looked; static const s2a_lowva_api *(*get)(void);
    if (!looked) { looked = 1; get = (const s2a_lowva_api *(*)(void))dlsym(RTLD_DEFAULT, "s2a_lowva"); }
    const s2a_lowva_api *lv = get ? get() : NULL;
    if (!lv) return NULL;
    if (lv->size >= sizeof(s2a_lowva_api) && lv->version == 1) return lv;
    GRED_ONCE("原生层低区账本版本 / 大小不符（%u / %u），渲染器不记账", lv->version, lv->size);
    return NULL;
}
// 命令分配器进低区账（见遍前段注释）：不可腾退。每次换分配器时按三个分配器的实占记账（只归因）；
// 遍前分段要让某个主分配器比它历史高水位多托一个命令缓冲时，先按一块的上界申请（可选），申请不到这一遍不分段、照旧切遍
enum { CA_CB_BYTES = 5 << 20 };   // 一次分段最多多出主段一个命令缓冲 + 遍前段一个（Mac 实测带渲染遍的 2.27 MB / 只有计算的 0.5 MB），取上界
static int g_ca_user; static uint64_t g_ca_bytes[GAL_NALLOC]; static int g_ca_hw[GAL_NALLOC];
// 分段多出来的命令缓冲的总额度（帧率能耗线 10-24，NXGAL_CA_EXTRA_MAX=<n>，缺省 8；负数 = 不限，即旧行为）：各主分配器高水位里超过 1 个命令缓冲的部分合计不超过 n，
// 超了这一遍不分段、照旧切遍（同账本不给）。起因：异度神剑3 测试设备2（xc3_1024021643_2）遍前分段 5852 次、每次提交都顶到 5 个主命令缓冲，
// 8 个主分配器都长到能托 5 个，主分配器 159 MB（iPhone 每个命令缓冲约 4 MB）、低区耗尽 OOM；不分段时 8 个合计约 18 MB。单测置 g_ca_extra_max
// 缺省翻成 8 的依据：测试设备2 同包 dd5259ef2 A/B（xc3-1024062834-82538）：A 不限，命令分配器 241 MB、第 3694 帧 OutOfMemoryException 崩溃；
//   B =8，命令分配器 127 MB、5028 帧不崩；每帧绘制 1289 / 1288，读回 1653 / 1646 ms，遍前分段 20069 / 19977 次（几乎没少）。被拒次数记在地址账行「总额度不给」
int g_ca_extra_max = -2;   // -2 未读环境变量；-1 不限
uint64_t g_ca_cap_refuse;  // 因总额度不分段的次数（单测 / 诊断）
static int ca_extra_max(void) { if (g_ca_extra_max == -2) { const char *v = getenv("NXGAL_CA_EXTRA_MAX"); g_ca_extra_max = v && *v ? atoi(v) : 8; if (g_ca_extra_max < -1) g_ca_extra_max = -1; } return g_ca_extra_max; }
void gal_ca_test_fresh(void) {   // 单测：GPU 做完后把各组分配器都换成新建的空分配器（量单帧高水位，不带前面用例留下的）
    for (int i = 0; i < GAL_NALLOC; i++) { if (g_galloc_fence[i] > g_gev.signaledValue) continue; g_galloc[i] = ca_new(); g_palloc[i] = ca_new(); g_xalloc[i] = nil; g_ca_hw[i] = 0; ca_note(i); }
}
uint64_t gal_ca_max_bytes(void) { uint64_t m = 0; for (int i = 0; i < GAL_NALLOC; i++) { uint64_t b = g_galloc[i].allocatedSize; if (b > m) m = b; } return m; }   // 单测 / 诊断：最大的主分配器
void gal_ca_test_reset(void) { memset(g_ca_hw, 0, sizeof g_ca_hw); }   // 单测：清各主分配器的命令缓冲高水位（前面用例每遍分段把它抬高了）
static int ca_user(const s2a_lowva_api *lv) { if (!g_ca_user) g_ca_user = lv->user("命令分配器", NULL, NULL); return g_ca_user; }
static int64_t ca_note(int pick) {   // 返回这次记进账本的增减（0 = 没记）
    const s2a_lowva_api *lv = lv_get();
    if (!lv || pick < 0) return 0;
    uint64_t b = g_galloc[pick].allocatedSize + g_palloc[pick].allocatedSize + (uint64_t)[g_xalloc[pick] allocatedSize];
    int64_t d = (int64_t)b - (int64_t)g_ca_bytes[pick];
    if (d) { lv->note(ca_user(lv), d); g_ca_bytes[pick] = b; }
    return d;
}
// 闲置放掉（帧率能耗线 10-24，NXGAL_CA_TRIM=<帧数>，缺省 120 帧；=0 不放。是低区 OOM 的修复、不是性能取舍，直接缺省开）：MTL4 命令分配器 reset 不还内存、按高水位一直留着，
//   挑分配器又是「下标最小的已完成者」——稳态只轮转前几个，后面的只在反压时用到一次就把那次的高水位一直占着。
//   异度神剑3 测试设备1（xc3_1024121611_1）：额度 8 照样拒了 13.5 万次，主分配器仍 0 → 197 MB（8 个平均 25 MB），占满低区账本的可拒份额，管线归档被拒开、转现建。
//   已完成（栅栏 ≤ 已完成值）且连续 n 帧没被挑中的分配器整组（主 / 预载 / 遍前段）换成新建的空分配器：内存还给驱动，再用到时按那次的量重新长
// 低区吃紧时放得更勤（10-24 怪猎 eab349aff 加载期：低区空洞 69 MB 时 8 个主分配器 8–18 MB 都在 11 帧内用过，120 帧阈值一个都放不到，随后管线归档开片 FATAL）：
//   渲染器向低区账本申请被拒过（命令分配器多托命令缓冲 / 管线归档开片）之后 600 帧内，闲置阈值降到 2 帧
uint64_t g_lv_press_frame = UINT64_MAX;   // 最近一次低区账本拒绝渲染器申请时的帧号（UINT64_MAX = 没拒过）
uint64_t g_ca_trim_n, g_ca_trim_bytes;   // 放掉的次数 / 字节（地址账行与单测读）
int64_t g_ca_trim_noted;   // 放掉这一动作本身记进低区账本的增减（单测读：账面总额同时被别的分配 / 命令缓冲改，比总额会随 GPU 完成时机抖）
int g_ca_trim = -1;                      // -1 未读环境变量；单测直接置
static void ca_trim(uint64_t done, int pick) {
    if (g_ca_trim < 0) { const char *v = getenv("NXGAL_CA_TRIM"); g_ca_trim = v && *v ? atoi(v) : 120; if (g_ca_trim < 0) g_ca_trim = 0; }
    if (!g_ca_trim) return;
    uint64_t th = g_lv_press_frame != UINT64_MAX && g_gp_frame - g_lv_press_frame < 600 && g_ca_trim > 2 ? 2 : (uint64_t)g_ca_trim;
    for (int i = 0; i < GAL_NALLOC; i++) {
        if (i == pick || g_galloc_fence[i] > done || g_gp_frame - g_galloc_used[i] <= th) continue;
        uint64_t b = g_galloc[i].allocatedSize + g_palloc[i].allocatedSize + (uint64_t)[g_xalloc[i] allocatedSize];
        if (b <= CA_CB_BYTES) continue;   // 空的 / 只剩一个命令缓冲的量：放了也省不下多少
        id a = ca_new(), p = ca_new();
        if (!a || !p) return;   // 建不出来就留着旧的（下次再试）
        g_galloc[i] = a; g_palloc[i] = p; g_xalloc[i] = nil; g_ca_hw[i] = 0;
        g_ca_trim_noted += ca_note(i);   // 账面按新分配器（0）销掉这组记过的量
        g_ca_trim_n++; g_ca_trim_bytes += b; g_galloc_used[i] = g_gp_frame;
    }
}
static int ca_admit(void) {
    int c = g_galloc_cur;
    if (g_ca_n < g_ca_hw[c]) return 1;   // 高水位以内：分配器复用已有的块
    int lim = ca_extra_max();
    if (lim >= 0) {
        int extra = 0; for (int i = 0; i < GAL_NALLOC; i++) extra += g_ca_hw[i] > 1 ? g_ca_hw[i] - 1 : 0;
        int add = (g_ca_n + 1) - (g_ca_hw[c] > 1 ? g_ca_hw[c] : 1);
        if (extra + add > lim) { g_ca_cap_refuse++; return 0; }
    }
    const s2a_lowva_api *lv = lv_get();
    if (lv) {
        // 不需要连续（contig 0）；申请只当判定，过了当场销掉在途额度（同 pa_get）——实占全按 ca_note 的分配器增量记，免得账面多挂在途
        int u = ca_user(lv);
        if (lv->acquire(u, CA_CB_BYTES, 0, 1, "命令分配器：遍前分段多一个命令缓冲") != 0) { g_lv_press_frame = g_gp_frame; return 0; }
        lv->note(u, CA_CB_BYTES); lv->note(u, -(int64_t)CA_CB_BYTES);
    }
    g_ca_hw[c] = g_ca_n + 1;
    return 1;
}
static uint64_t g_pa_st[5];   // 0 开片 1 腾退关片（NXGAL_PSO_ARCH_CAP_MB 设了才有） 2 账本不给开 3 开失败 4 当前已开字节
// 腾退（10-24 异度神剑3 测试设备2 低区 OOM：开片 4 → 225 MB、193 个文件映射，账上「不可腾退」；缺省关，真机实验定）：
//   NXGAL_PSO_ARCH_CAP_MB = 已开片总字节上限（0 / 不设 = 不腾退，照旧开了不关）；超了按最近最少使用放掉冷片的归档对象（销账），再用到时重开。
//   iPhone 上放掉归档对象是否真还地址未定（10-21 探针 witcher3_1021201918_2：管线留着时映射 2 秒后仍在；10-24 Mac 探针：2 秒内消失）——
//   所以缺省关，测试设备2 实局读原生层收局「低区文件映射」定。g_pa_tick：各片最近一次被取的序号（LRU）
static uint64_t *g_pa_tick, g_pa_clock;
static uint64_t pa_cap(void) { static int64_t v = -1; if (v < 0) { const char *e = getenv("NXGAL_PSO_ARCH_CAP_MB"); v = e && *e ? (int64_t)(atof(e) * 1048576.0) : 0; } return (uint64_t)v; }   // 可写小数（单测按字节定）
// 表锁下调：为再开 need 字节腾地方（不动 keep 片、在开的片）；返回放掉的字节
static uint64_t pa_evict_locked(int keep, uint64_t need) {
    uint64_t cap = pa_cap(), freed = 0;
    if (!cap) return 0;
    while (g_pa_st[4] + need > cap) {
        int v = -1; uint64_t best = UINT64_MAX;
        for (int i = 0; i < (int)g_pa_obj.count; i++) if (i != keep && g_pa_obj[i] != (id)NSNull.null && !g_pa_opening[i] && g_pa_tick[i] < best) { best = g_pa_tick[i]; v = i; }
        if (v < 0) break;
        g_pa_obj[v] = NSNull.null; g_pa_st[4] -= g_pa_bytes[v]; g_pa_st[1]++; freed += g_pa_bytes[v];
        if (g_lv) g_lv->note(g_lv_me, -(int64_t)g_pa_bytes[v]);
        if (g_pa_st[1] <= 8 || !(g_pa_st[1] & (g_pa_st[1] - 1))) GLOG("管线归档腾退：放掉 %s（%.1f MB，第 %llu 次），已开 %.1f MB / 上限 %.0f MB", g_pa_path[v].lastPathComponent.UTF8String, g_pa_bytes[v] / 1048576.0,
            (unsigned long long)g_pa_st[1], g_pa_st[4] / 1048576.0, cap / 1048576.0);
    }
    return freed;
}
// 单测只延迟真实开片：waiting=0 已 claim 且不持锁；waiting=1 持表锁、只可通知，不能阻塞。
__attribute__((weak)) void gal_pso_test_open_hook(const char *path, int waiting) { (void)path; (void)waiting; }
static void pa_open_publish(int n, id o, int bad, uint64_t b) {
    pthread_mutex_lock(&g_pa_mu);
    if (o) { g_pa_obj[n] = o; g_pa_st[0]++; g_pa_st[4] += b; g_pa_tick[n] = ++g_pa_clock; }
    if (bad) { NSMutableArray *ps = [g_pa_path mutableCopy]; ps[n] = @""; g_pa_path = ps; }
    g_pa_opening[n] = 0;
    pthread_cond_broadcast(&g_pa_changed);
    pthread_mutex_unlock(&g_pa_mu);
}
// 同片只有一个线程申请和开片；热片只拿表锁，不等其他片的 I/O / 低区账本。
// 数组可在等待 / 开片期间增长，所以解锁后只保留槽号、字节数和路径强引用。
// 限时打开一片归档（Metal 4）。11-14 macOS 27.2.1 实测：系统打开 Xcode 27.1 编的、含图形与计算管线的归档时在 MTL4ArchiveImpl::loadFromURL 里死循环、
//   永不返回（采样栈全在系统代码里；只含顶点函数的能开，旧系统版本编的报「不兼容」不卡）——游戏卡在第一次建管线。打开放到后台线程，
//   等 S2A_PSO_OPEN_TIMEOUT_MS（缺省 8000）毫秒；到点没回来：本局不再开任何出包归档（以后每片直接返回空、按首遇现建），报红一次。
//   卡住的那条后台线程停不下来，会一直占一个核到退出（系统调用里没有取消点），日志写明；比整局卡死好
static _Atomic int g_pa_hung;
__attribute__((weak)) void gal_pso_test_open_stall(void) {}   // 单测注入：模拟系统打开卡住（tests/t_psoopen.m）
static id pa_open_timed(NSString *path, NSError **err);
int gal_pso_open_timed_probe(const char *path, int *hung) {   // 单测入口：限时打开一次，返回 1 = 得到归档对象；*hung = 本局是否已停用
    NSError *e = nil; id o = pa_open_timed(@(path), &e); if (hung) *hung = atomic_load(&g_pa_hung); return o != nil;
}
static id pa_open_timed(NSString *path, NSError **err) {
    if (atomic_load(&g_pa_hung)) { if (err) *err = [NSError errorWithDomain:@"s2a.gal" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"本局出包归档已停用（之前一片打开卡死）"}]; return nil; }
    static int ms = -1; if (ms < 0) { const char *v = getenv("S2A_PSO_OPEN_TIMEOUT_MS"); ms = v && atoi(v) > 0 ? atoi(v) : 8000; }
    __block id got = nil; __block NSError *ge = nil; dispatch_semaphore_t done = dispatch_semaphore_create(0); NSString *p = [path copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ gal_pso_test_open_stall(); NSError *e2 = nil; id o = [g_gdev newArchiveWithURL:[NSURL fileURLWithPath:p] error:&e2]; got = o; ge = e2; dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * 1000000))) {
        atomic_store(&g_pa_hung, 1);
        GLOG("【红】管线归档 %s：系统打开 %d ms 没返回（Metal 载入卡死），本局停用全部出包归档、按首遇现建；卡住的后台线程会一直占一个核到退出", p.lastPathComponent.UTF8String, ms);
        if (err) *err = [NSError errorWithDomain:@"s2a.gal" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"系统打开归档超时"}];
        return nil;
    }
    if (err) *err = ge;
    return got;
}
static id pa_get(int n) {
    pthread_mutex_lock(&g_pa_mu);
    while (1) {
        if (n < 0 || n >= (int)g_pa_path.count || !g_pa_path[n].length) { pthread_mutex_unlock(&g_pa_mu); return nil; }
        id cached = g_pa_obj[n];
        if (cached != (id)NSNull.null) { g_pa_tick[n] = ++g_pa_clock; pthread_mutex_unlock(&g_pa_mu); return cached; }
        if (!g_pa_opening[n]) break;
        gal_pso_test_open_hook([g_pa_path[n] UTF8String], 1);
        pthread_cond_wait(&g_pa_changed, &g_pa_mu);
    }
    g_pa_opening[n] = 1;
    uint64_t b = g_pa_bytes[n]; NSString *path = g_pa_path[n];
    pa_evict_locked(n, b);   // 设了上限：先腾出这片的地方（放掉冷片归档对象、销账），再向账本申请
    const s2a_lowva_api *lv = g_lv; int lv_me = g_lv_me;
    pthread_mutex_unlock(&g_pa_mu);
    gal_pso_test_open_hook(path.UTF8String, 0);
    const char *what = path.lastPathComponent.UTF8String;
    if (lv && lv->acquire(lv_me, b, b, 1, what) != 0) {
        g_lv_press_frame = g_gp_frame;
        // 账本不给开 = 正常路径（比例上限 / 地址不够时的设计行为），后果是首遇现建、归首局格：标「【首遇】」不标「【红】」，不染红能玩格（原生层线 10-21）
        // 每片第一次被拒必打一行（片数几百封顶）：首局现建按分片对账要全名单（10-21 暗黑3 三局按 2 的幂次打，名单不全、拒开与描述不符分不清）
        static NSMutableIndexSet *refl; pthread_mutex_lock(&g_pa_mu); uint64_t k = ++g_pa_st[2]; if (!refl) refl = [NSMutableIndexSet indexSet];
        int first = ![refl containsIndex:(NSUInteger)n]; if (first) [refl addIndex:(NSUInteger)n]; NSUInteger nref = refl.count; pthread_mutex_unlock(&g_pa_mu);
        if (first) { uint64_t T = 0, B = 0, R = 0, U = 0, A = 0; lv->snapshot(&T, &B, &R, &U, &A);
            GLOG("【首遇】管线归档 %s（%.1f MB）低区账本不给开（第 %llu 次、第 %lu 片）：空洞合计 %.0f MB、最大 %.0f MB、保留 %.0f MB、拦不到 %.0f MB、账面 %.0f MB；这片不开、首遇现建", what, b / 1048576.0,
                 (unsigned long long)k, (unsigned long)nref, T / 1048576.0, B / 1048576.0, R / 1048576.0, U / 1048576.0, A / 1048576.0); }
        pa_open_publish(n, nil, 0, 0);
        return nil;
    }
    // pso_open：开一片归档的墙钟（10-22 马车8 场景切换首帧建管线 196 次 124.5 ms、全是归档命中，拆「开片」与「从归档取」）
    GP_SCOPE(GP_PSO_OPEN);
    NSError *e = nil; id o = gal_be_kind() == GAL_BE_MTL3 ? binary_archive3(path, &e) : pa_open_timed(path, &e);
    if (!o) {
        NSError *u = e.userInfo[NSUnderlyingErrorKey];
        GLOG("【红】管线归档 %s 载入失败：%s（域 %s 码 %ld；底层 %s 码 %ld：POSIX 24 = 句柄用尽、12 = 内存 / 地址不够）", what, e.localizedDescription.UTF8String, e.domain.UTF8String, (long)e.code,
             u ? u.domain.UTF8String : "-", u ? (long)u.code : 0L);
        pthread_mutex_lock(&g_pa_mu); g_pa_st[3]++; pthread_mutex_unlock(&g_pa_mu);
        if (lv) {
            // 是不是地址 / 句柄真不够了（原生层线审）：此刻余量不够或底层 POSIX 12 / 24 → 列账报红退出（再往下走 Metal 会在内部空指针崩）；
            // 否则是这片文件本身的问题：报红后这片作废（以后不再开），照常首遇现建，不为一片坏文件杀游戏
            uint64_t T = 0, B = 0, R = 0, U = 0, A = 0; lv->snapshot(&T, &B, &R, &U, &A);
            long pc = u && [u.domain isEqualToString:NSPOSIXErrorDomain] ? (long)u.code : 0;
            if (T < R + b || B < (256ull << 20) + b || pc == 12 || pc == 24) lv->fail(lv_me, b, what);
            // acquire 记的申请额度销掉：先转实占再放（账本不用加接口）
            lv->note(lv_me, (int64_t)b); lv->note(lv_me, -(int64_t)b);
            GLOG("【红】管线归档 %s：地址 / 句柄够（空洞合计 %.0f MB、最大 %.0f MB、保留 %.0f MB），按文件本身坏处理：这片作废、首遇现建", what, T / 1048576.0, B / 1048576.0, R / 1048576.0);
        }
        // 这片作废：路径置空，以后取它直接返回空（没有账本时同样不再反复试开）
        pa_open_publish(n, nil, 1, 0);
        return nil;
    }
    if (lv) lv->note(lv_me, (int64_t)b);
    pa_open_publish(n, o, 0, b);
    return o;
}
// 包片和设备片共用稳定槽。坏片路径置空后仍保留片号，不重复登记和试开。
static int pa_register_path(NSString *path) {
    pthread_mutex_lock(&g_pa_mu);
    if (!g_pa_slot) g_pa_slot = [NSMutableDictionary dictionary];
    NSNumber *known = g_pa_slot[path];
    if (!known) {
        NSMutableArray *paths = g_pa_path ? [g_pa_path mutableCopy] : [NSMutableArray array];
        known = @(paths.count); [paths addObject:path]; g_pa_path = paths; g_pa_slot[path] = known;
        if (!g_pa_obj) g_pa_obj = [NSMutableArray array];
        [g_pa_obj addObject:NSNull.null]; g_pa_bytes = realloc(g_pa_bytes, paths.count * sizeof *g_pa_bytes);
        g_pa_bytes[known.unsignedIntegerValue] = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileSize;
        g_pa_opening = realloc(g_pa_opening, paths.count * sizeof *g_pa_opening); g_pa_opening[known.unsignedIntegerValue] = 0;
        g_pa_tick = realloc(g_pa_tick, paths.count * sizeof *g_pa_tick); g_pa_tick[known.unsignedIntegerValue] = 0;
    }
    pthread_mutex_unlock(&g_pa_mu);
    return known.intValue;
}
static NSString *g_pso_script, *g_pso_arch_out; static uint64_t g_pso_hit, g_pso_miss, g_pso_new, g_pso_build_ns;
static _Atomic uint64_t g_pso_build_max;   // 最长一次现建（mach 时基，同 g_pso_build_ns）：开发浮层「首遇现建 最长」读
static void pso_cache_init(MTL4CompilerDescriptor *cd) {
    const char *a = getenv("NXGAL_PSO_ARCHIVE"), *sc = getenv("NXGAL_PSO_SCRIPT"), *ao = getenv("NXGAL_PSO_ARCHIVE_OUT");
    if (a && *a) { NSError *e = nil; g_pso_arch = [g_gdev newArchiveWithURL:[NSURL fileURLWithPath:@(a).stringByExpandingTildeInPath] error:&e];   // iOS 上给 ~/Documents/…
        GLOG("%s管线归档 %s：%s", g_pso_arch ? "" : "【红】", a, g_pso_arch ? "已载入" : e.localizedDescription.UTF8String); }
    if (sc && *sc && ao && *ao) GLOG("【红】NXGAL_PSO_SCRIPT 与 NXGAL_PSO_ARCHIVE_OUT 互斥（同开导出 0 字节），只收描述");
    if (sc && *sc) g_pso_script = @(sc).stringByExpandingTildeInPath; else if (ao && *ao) g_pso_arch_out = @(ao).stringByExpandingTildeInPath;
    if (g_pso_script || g_pso_arch_out) { MTL4PipelineDataSetSerializerDescriptor *sd = [MTL4PipelineDataSetSerializerDescriptor new];
        sd.configuration = g_pso_script ? MTL4PipelineDataSetSerializerConfigurationCaptureDescriptors : MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
        g_pso_ser = [g_gdev newPipelineDataSetSerializerWithDescriptor:sd]; cd.pipelineDataSetSerializer = g_pso_ser;
        GLOG("收管线%s → %s", g_pso_script ? "描述" : "二进制", (g_pso_script ?: g_pso_arch_out).UTF8String); }
}
static void pso_cache_init3(void) {
    if (!m3_archive_on()) return;
    const char *a = getenv("NXGAL_PSO_ARCHIVE");
    if (a && *a) { NSError *e = nil; g_pso_arch3 = binary_archive3(@(a).stringByExpandingTildeInPath, &e);
        GLOG("%sMetal 3 管线归档 %s：%s", g_pso_arch3 ? "" : "【红】", a, g_pso_arch3 ? "已载入" : e.localizedDescription.UTF8String); }
    if (getenv("NXGAL_PSO_SCRIPT") || getenv("NXGAL_PSO_ARCHIVE_OUT"))
        GLOG("【红】Metal 3 不支持 Metal 4 描述/归档收集输出；设备持久归档请使用 NXGAL_PSO_DEV");
}
// 着色器包里的管线归档（graphics/tools/shader_pack.sh 出包时 applegpu-nt 按 GPU 架构 × 系统大版本编，文件名 gal_pso.<架构名>.<ios|macos><大版本>.<分片>.bin）：
// 按本机 MTLDevice.architecture 与系统大版本选文件——GPU 二进制绑定系统里的 GPU 编译器，大版本不同即「not compatible with current OS」
//（10-20 测试设备2 iOS 27 载入 26.5 SDK 出的归档 73 片全部失败）；没有本版本的归档 = 首遇现建并报红（设计.md「归档与系统版本」），
// nxgal_init 之后、建第一个管线之前调（运行时着色器包装载 graphics/loop/ShaderPack.cs）。返回 0 = 已载入；1 = 包里没有本机架构的归档；-1 = 载入失败
// 内部管线预建：渲染器自己的几条管线（定格 / 上屏 / 顶点重排 / 索引转换，都是运行时编辅助 MSL）原本第一次用到才建，落在首局里（10-20 测试设备2 首帧 2 个、第 73 帧 1 个）；
// 渲染循环起来、着色器包装好之后、第一帧之前调一次。耗时打一行，不计 pso_n
int gal_warm_restride(void); int gal_warm_idx(void); void gal_warm_present(void); void gal_warm_clear(void); void gal_warm_tex(void); void gal_warm_tess(void);
static int g_pso_warming;   // nxgal_warm_internal 期间：内部管线预建，不计入现建（首局判据只看游戏遇到时现建）
// 内部管线预建在 nxgal_warm_internal 之外的入口（gal_state.m 载入特化组合表时建清屏基础管线）：同样不计入现建。可嵌套
void gal_pso_warming_push(void) { g_pso_warming++; }
void gal_pso_warming_pop(void) { g_pso_warming--; }
int gal_pso_warming(void) { return g_pso_warming; }
static double pso_ns_ms(uint64_t t) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)t * tb.numer / tb.denom / 1e6; }
static double pso_ms(uint64_t t0) { return pso_ns_ms(mach_absolute_time() - t0); }
NXGAL_API void nxgal_warm_internal(void) { GAL_API_LOCK();
    if (!g_gdev) return;
    uint64_t t0 = mach_absolute_time(); g_pso_warming++;
    @autoreleasepool { gal_warm_present(); gal_warm_restride(); gal_warm_idx(); gal_warm_clear(); gal_warm_tex(); gal_warm_tess(); gal_warm_spec_combos(); }
    g_pso_warming--;
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    GLOG("内部管线预建（定格 / 上屏 / 顶点重排 / 索引转换 + 间接计数 / 曲面细分器 3 支 / 清屏 50 支基础（附件 -1 与 0–7 × 三种分量 × 采样 1 / 4，gal_warm_clear）/ 拷贝 4 支基础 + 3 支深度模板）：%.1f ms", (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6);
}
// ---------- 后台编译入口（10-22）----------
// MTL4Compiler 挂了序列化器（设备归档）后走异步接口（completionHandler）会在 Metal 内部段错误（MTLHashKey::getHashTools；Mac 26.4 最小复现
//   ~/.s2arm/run/s2arm/gfxsh/linked/p2/p4.m：不挂 4/4 成、挂 2/2 崩），所以渲染器的后台编译一律在自己的队列上调同步接口。
//   同时最多 2 条（不和渲染线程抢核：判据「后台编译不掉帧格、不升能耗」）；blk 拿到当前主编译器
//   设备归档开着时 blk 拿到的是挂序列化器的那个编译器（后台编的都收进归档），编译期间持读锁：序列化器写盘与同一编译器上的并发现编撞车会在 Metal 内部段错误
//   （10-22 测试设备1 动森 10 秒防抖写盘处 dispatch_data_create_map 崩两局；Mac 最小复现 p2/p5.m：同编译器并发 2/2 崩、另一编译器并发 3/3 不崩），写盘持写锁。
//   渲染线程上的编译（特化、顶不上时的阻塞现编）一律走不挂序列化器的主编译器，不等写盘
static dispatch_queue_t g_bgc_q; static dispatch_semaphore_t g_bgc_sem;
static id g_dev_comp; static pthread_rwlock_t g_ser_rw = PTHREAD_RWLOCK_INITIALIZER;
static void bgc_init(void) { static dispatch_once_t once; dispatch_once(&once, ^{ g_bgc_q = dispatch_queue_create("s2a.compile_bg", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0)); g_bgc_sem = dispatch_semaphore_create(2); }); }
// 单测钩子（tests/t_psowait.m）：占住（on = 1）/ 放开（0）后台编译的 2 个槽，模拟渲染线程要的管线排在后台积压后面
NXGAL_API void nxgal_test_bg_hold(int on) {
    bgc_init(); static int held;
    if (on && !held) { for (int i = 0; i < 2; i++) dispatch_semaphore_wait(g_bgc_sem, DISPATCH_TIME_FOREVER); held = 1; }
    else if (!on && held) { for (int i = 0; i < 2; i++) dispatch_semaphore_signal(g_bgc_sem); held = 0; }
}
void gal_compile_bg(void (^blk)(id comp)) {
    bgc_init();
    id c = g_dev_comp ?: g_gcomp; int ser = g_dev_comp != nil;
    dispatch_async(g_bgc_q, ^{ dispatch_semaphore_wait(g_bgc_sem, DISPATCH_TIME_FOREVER);
        if (ser) pthread_rwlock_rdlock(&g_ser_rw);
        @autoreleasepool { blk(c); }
        if (ser) pthread_rwlock_unlock(&g_ser_rw);
        dispatch_semaphore_signal(g_bgc_sem); });
}
// 设备归档缺省根：Application Support/S2A/pso_dev；老位置 Caches/S2A/pso_dev 在而新位置不在 → 整个挪过来；S2A 目录标不进 iCloud 备份
static NSString *pso_dev_default_root(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = NSHomeDirectory(), *s2a = [home stringByAppendingPathComponent:@"Library/Application Support/S2A"];
    NSString *dir = [s2a stringByAppendingPathComponent:@"pso_dev"], *old = [home stringByAppendingPathComponent:@"Library/Caches/S2A/pso_dev"];
    NSError *e = nil;
    if (![fm createDirectoryAtPath:s2a withIntermediateDirectories:YES attributes:nil error:&e]) GLOG("【红】设备归档根建不出：%s", e.localizedDescription.UTF8String);
    if (![[NSURL fileURLWithPath:s2a] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&e]) GLOG("【红】设备归档根标不进备份失败：%s", e.localizedDescription.UTF8String);
    if (![fm fileExistsAtPath:dir] && [fm fileExistsAtPath:old]) {
        if ([fm moveItemAtPath:old toPath:dir error:&e]) GLOG("设备归档：老位置 Library/Caches/S2A/pso_dev 挪到 Application Support");
        else GLOG("【红】设备归档从老位置挪不过来（%s），这次从空归档开始", e.localizedDescription.UTF8String);
    }
    return dir;
}
// ---------- 设备归档（10-22 维护者：设备上现编的完整版与特化结果进 App 自己的持久归档，下次启动先读它；不靠系统 Metal 编译缓存——它被我们设了 64 MB 上限，会挤掉）----------
// 目录：$HOME/Library/Application Support/S2A/pso_dev/<包键>.<GPU 架构>.<系统内部版本>/（换包 / 系统升级 = 新目录，旧条目自然不用；NXGAL_PSO_DEV_DIR 换根）。
//   v0.3.0 起不放 Library/Caches：系统空间紧时会清 Caches，玩家下次进局又得现编；Application Support 不被清，整个 S2A 目录标「不进 iCloud 备份」（可再生、不占玩家备份）。
//   老版本留在 Library/Caches/S2A/pso_dev 的归档：新位置还没有时整个挪过来（同一容器内改名，不拷数据），已编过的不丢。
//   包键 = 着色器目录的 shader_pack.key（出包 stage_shaders.sh 写），没有就用 gal_pso.idx 的大小 + 修改时间。
// 收：登记着色器包时另建一个挂序列化器（只收二进制）的编译器，后台编的（gal_compile_bg：链接版背后的完整版、特化结果按完整描述、桩、函数体）都用它、都收；
//   渲染线程上阻塞现编的那条走主编译器（不挂序列化器，不等写盘），编完另交后台再编一次收进来（dev_capture）。
//   Mac 实测（~/.s2arm/run/s2arm/gfxsh/linked/p2、p3）：写一次即清空、之后只收新的；特化结果不收 → 特化后按完整描述后台再编一条让它收（gal_pso_dev_capture）；
//   每条约 22 KB，写盘约 3.4 ms / 条；带序列化器现编每条 8.2 → 12.6 ms（40 条交替）。挂序列化器后不能走 Metal 异步接口（见 gal_compile_bg）
// 写：有新条目时防抖 10 秒在后台串行队列写一个新文件 dev.<毫秒>.bin，同时往 dev.idx 追加「键串 FNV-1a 64 → 文件」行；进后台（nxgal_gpu_hold 关闸）立刻写；nxgal_shutdown 也写。
//   iOS 杀进程不走正常退出，所以不能只靠退出时写。不裁剪、不淘汰（10-22 维护者：盘大，多存换速度划得来）
// 读：登记包时只读 dev.idx、把各文件登记成包归档的追加分片（同一套按需开片 + 低区账本 pa_get，10-22 维护者：约束只有映射占的地址）；
//   包归档查不到的描述按键查 dev.idx → 只开那几片。命中另计（判「包归档覆盖」时要把它算进没命中）
// 缺省：iOS 开、Mac 关（Mac 局与门禁要每局同口径）；NXGAL_PSO_DEV=1 / 0 强开 / 关
static NSString *pso_pname(id d); static uint64_t pso_fnv(NSString *k);
static NSString *g_dev_dir; static dispatch_queue_t g_dev_q; static id g_dev_ser;
static id<MTLBinaryArchive> g_dev_arch3;   // 仅 g_dev_q 访问 add/serialize，已落盘片由 pa_get 另开只读对象
static dispatch_group_t g_dev_async3;
static int g_dev3_active;   // 初始化后不变，其他线程不读串行队列正在轮换的 strong archive 指针
static NSMutableArray<NSDictionary *> *g_dev_desc3;   // 本批真实成功 add 的描述，失败后可独立重建，不能重用已序列化对象
static NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *g_dev_ix;   // 键 → 分片号（pa_get 下标）
static NSMutableArray<NSString *> *g_dev_pend; static pthread_mutex_t g_dev_mu = PTHREAD_MUTEX_INITIALIZER;   // 收下还没写盘的条目键串
static _Atomic int g_dev_sched; static _Atomic uint64_t g_dev_hit, g_dev_wrote, g_dev_files, g_dev_nf, g_dev_mb;
static int dev_on(void) {
    const char *v = getenv("NXGAL_PSO_DEV");
#if TARGET_OS_IPHONE
    return !(v && *v == '0');
#else
    return v && *v == '1';
#endif
}
NSString *gal_pso_dev_dir(void) { return g_dev_dir; }
static NSArray<NSNumber *> *dev_shards(NSString *k) { if (!k || !g_dev_ix) return nil; pthread_mutex_lock(&g_dev_mu); NSArray *a = [g_dev_ix[@(pso_fnv(k))] copy]; pthread_mutex_unlock(&g_dev_mu); return a; }
// 查不中分三种（10-24 真机热局命中 0：马车8 登记 2 键、同样 2 条又特化又收一遍；Mac 单测 t_psodev 是通的）：
//   g_dev_miss[0] 键不在 dev.idx（写入与查找的函数名串不同）；[1] 键在、片开不出（低区账本拒 / 文件坏）；[2] 片开了、归档按描述取不到（描述不完全相同）
static _Atomic uint64_t g_dev_look, g_dev_miss[3];
void gal_pso_dev_miss(uint64_t out[4]) { out[0] = g_dev_look; out[1] = g_dev_miss[0]; out[2] = g_dev_miss[1]; out[3] = g_dev_miss[2]; }
static id dev_find(id d, int compute) {
    if (gal_be_kind() == GAL_BE_MTL3 && !m3_archive_on()) return nil;
    if (!g_dev_ix) return nil;
    g_dev_look++;
    NSString *pn = pso_pname(d); NSArray<NSNumber *> *sh = dev_shards(pn);
    if (!sh.count) { if (g_dev_miss[0]++ < 4) GLOG("设备归档查不中（键不在索引）：%s", pn.UTF8String); return nil; }
    int opened = 0;
    for (NSNumber *n in sh) @autoreleasepool { id a = pa_get(n.intValue); if (!a) continue; opened++;
        id p = nil; NSError *e = nil;
        if (gal_be_kind() == GAL_BE_MTL3) p = archive_pipeline3(a, d, compute, &e);
        else if (compute) p = [a newComputePipelineStateWithDescriptor:d error:&e]; else p = [a newRenderPipelineStateWithDescriptor:d error:&e];
        if (p) { g_dev_hit++; return p; }
        if (g_dev_miss[2] < 4) GLOG("设备归档查不中（片开了、按描述取不到）：%s（%s）", pn.UTF8String, e ? e.localizedDescription.UTF8String : "无错误信息"); }
    g_dev_miss[opened ? 2 : 1]++;
    return nil;
}
static void dev_remove3(NSString *path) {
    NSError *e = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&e] &&
        !([e.domain isEqualToString:NSCocoaErrorDomain] && e.code == NSFileNoSuchFileError))
        { atomic_store(&g_archive_write_error, 1); GLOG("【红】Metal 3 设备归档本次失败产物清理失败（%s）：%s", path.lastPathComponent.UTF8String, e.localizedDescription.UTF8String); }
}
// 串行队列内写入。归档、索引全部提交成功才轮换和清键；失败保留当前批以便下一次 flush 重试。
static void dev_write3(const char *why) {
    g_dev_sched = 0;
    if (!g_dev_pend.count) return;
    NSError *e = nil;
    NSString *fn = [NSString stringWithFormat:@"dev.%@.bin", NSUUID.UUID.UUIDString];
    NSString *path = [g_dev_dir stringByAppendingPathComponent:fn], *tmp = [path stringByAppendingString:@".tmp"];
    // 先准备索引，读/写失败不能触及当前 archive 的序列化状态。
    NSString *index = [g_dev_dir stringByAppendingPathComponent:@"dev.idx"], *itmp = [index stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    NSMutableData *data = [NSMutableData data];
    if ([[NSFileManager defaultManager] fileExistsAtPath:index]) {
        NSData *old = [NSData dataWithContentsOfFile:index options:0 error:&e];
        if (!old) { atomic_store(&g_archive_write_error, 1); GLOG("【红】Metal 3 设备归档索引读失败：%s", e.localizedDescription.UTF8String); return; }
        [data appendData:old];
    }
    for (NSString *k in g_dev_pend) [data appendData:[[NSString stringWithFormat:@"%016llx\t%@\n", (unsigned long long)pso_fnv(k), fn] dataUsingEncoding:NSUTF8StringEncoding]];
    if (![data writeToFile:itmp options:0 error:&e]) {
        atomic_store(&g_archive_write_error, 1);
        GLOG("【红】Metal 3 设备归档索引写失败：%s", e.localizedDescription.UTF8String);
        dev_remove3(itmp); return;
    }
    // serializeToURL 后对象可能依赖输出文件。每次从保留的真实描述重建一次性写盘对象，
    // 失败先放掉它再删除本次文件；下次尝试不依赖这份已删除的序列化状态。
    id<MTLBinaryArchive> writing = binary_archive3(nil, &e);
    if (!writing) {
        atomic_store(&g_archive_write_error, 1);
        GLOG("【红】Metal 3 设备归档写盘批次建不出：%s", e.localizedDescription.UTF8String); dev_remove3(itmp); return;
    }
    id<MTLBinaryArchive> next = binary_archive3(nil, &e);
    if (!next) {
        atomic_store(&g_archive_write_error, 1);
        GLOG("【红】Metal 3 设备归档写盘批次建不出：%s", e.localizedDescription.UTF8String); dev_remove3(itmp); return;
    }
    for (NSDictionary *entry in g_dev_desc3) {
        id d = entry[@"descriptor"];
        BOOL ok = [entry[@"compute"] boolValue] ? [writing addComputePipelineFunctionsWithDescriptor:d error:&e] : [writing addRenderPipelineFunctionsWithDescriptor:d error:&e];
        if (!ok) { atomic_store(&g_archive_write_error, 1); GLOG("【红】Metal 3 设备归档写盘批次重建失败：%s", e.localizedDescription.UTF8String); dev_remove3(itmp); return; }
    }
    if (![writing serializeToURL:[NSURL fileURLWithPath:tmp] error:&e]) {
        atomic_store(&g_archive_write_error, 1);
        GLOG("【红】Metal 3 设备归档序列化失败（%s）：%s", why, e.localizedDescription.UTF8String);
        writing = nil; dev_remove3(tmp); dev_remove3(itmp); return;
    }
    if (rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation)) {
        atomic_store(&g_archive_write_error, 1);
        GLOG("【红】Metal 3 设备归档提交失败（%s）：%s", why, strerror(errno));
        writing = nil; dev_remove3(tmp); dev_remove3(itmp); return;
    }
    if (rename(itmp.fileSystemRepresentation, index.fileSystemRepresentation)) {
        atomic_store(&g_archive_write_error, 1);
        GLOG("【红】Metal 3 设备归档索引提交失败：%s", strerror(errno));
        writing = nil; dev_remove3(itmp); dev_remove3(path); return;
    }
    NSNumber *slot = @(pa_register_path(path));
    pthread_mutex_lock(&g_dev_mu);
    if (!g_dev_ix) g_dev_ix = [NSMutableDictionary dictionary];
    for (NSString *k in g_dev_pend) { NSNumber *key = @(pso_fnv(k)); NSMutableArray *a = g_dev_ix[key];
        if (!a) g_dev_ix[key] = a = [NSMutableArray array]; if (![a containsObject:slot]) [a addObject:slot]; }
    NSUInteger count = g_dev_pend.count; [g_dev_pend removeAllObjects];
    pthread_mutex_unlock(&g_dev_mu);
    [g_dev_desc3 removeAllObjects]; g_dev_arch3 = next; g_dev_wrote += count; g_dev_files++;
    atomic_store(&g_archive_write_error, 0);
    GLOG("Metal 3 设备归档写盘（%s）：%lu 条 → %s；累计写 %llu 条 / %llu 文件", why, (unsigned long)count, fn.UTF8String,
         (unsigned long long)g_dev_wrote, (unsigned long long)g_dev_files);
}
static void dev_write(const char *why) {
    if (g_dev3_active) { NSString *reason = @(why); dispatch_async(g_dev_q, ^{ @autoreleasepool { dev_write3(reason.UTF8String); } }); return; }
    if (!g_dev_ser || !g_dev_dir) return;
    dispatch_async(g_dev_q, ^{ @autoreleasepool {
        g_dev_sched = 0;
        pthread_mutex_lock(&g_dev_mu); NSUInteger n0 = g_dev_pend.count; pthread_mutex_unlock(&g_dev_mu);
        if (!n0) return;
        static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
        uint64_t t0 = mach_absolute_time(); struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        NSString *fn = [NSString stringWithFormat:@"dev.%lld%03ld.bin", (long long)ts.tv_sec, ts.tv_nsec / 1000000], *f = [g_dev_dir stringByAppendingPathComponent:fn];
        NSString *tmp = [f stringByAppendingString:@".tmp"]; NSError *e = nil;
        pthread_rwlock_wrlock(&g_ser_rw);
        BOOL ok = [g_dev_ser serializeAsArchiveAndFlushToURL:[NSURL fileURLWithPath:tmp] error:&e];
        pthread_rwlock_unlock(&g_ser_rw);
        // 写盘期间新收的条目可能落进本文件也可能落进下一个：这批键全记给本文件，写盘期间到的再留给下一个文件也记一遍（键 → 多片，查到哪片算哪片）
        pthread_mutex_lock(&g_dev_mu); NSArray *keys = [g_dev_pend copy]; pthread_mutex_unlock(&g_dev_mu);
        // 「没东西可写」（这段时间新现编的全是不收的）不算错
        if (!ok) { if (!e || [e.localizedDescription rangeOfString:@"Nothing"].location == NSNotFound) {
                atomic_store(&g_archive_write_error, 1); GLOG("【红】设备归档写盘失败（%s）：%s", why, e ? e.localizedDescription.UTF8String : "无错误信息");
            } else { pthread_mutex_lock(&g_dev_mu); [g_dev_pend removeObjectsInRange:NSMakeRange(0, n0)]; pthread_mutex_unlock(&g_dev_mu); }
            return; }
        if (rename(tmp.fileSystemRepresentation, f.fileSystemRepresentation)) {
            atomic_store(&g_archive_write_error, 1); GLOG("【红】设备归档提交失败：%s", strerror(errno)); return;
        }
        NSMutableString *lines = [NSMutableString string]; for (NSString *k in keys) [lines appendFormat:@"%016llx\t%@\n", (unsigned long long)pso_fnv(k), fn];
        FILE *ix = fopen([g_dev_dir stringByAppendingPathComponent:@"dev.idx"].fileSystemRepresentation, "a");
        if (!ix) { atomic_store(&g_archive_write_error, 1); GLOG("【红】设备归档索引追加失败：%s", strerror(errno)); return; }
        int wrote = fputs(lines.UTF8String, ix), closed = fclose(ix);
        if (wrote == EOF || closed) { atomic_store(&g_archive_write_error, 1); GLOG("【红】设备归档索引写入失败：%s", strerror(errno)); return; }
        pthread_mutex_lock(&g_dev_mu); [g_dev_pend removeObjectsInRange:NSMakeRange(0, n0)]; pthread_mutex_unlock(&g_dev_mu);
        atomic_store(&g_archive_write_error, 0);
        g_dev_wrote += keys.count; g_dev_files++;
        GLOG("设备归档写盘（%s）：%lu 条 → %s（%.0f KB，%.1f ms）；累计写 %llu 条 / %llu 个文件、本局命中 %llu", why, (unsigned long)keys.count, fn.UTF8String,
             [[NSFileManager defaultManager] attributesOfItemAtPath:f error:nil].fileSize / 1024.0, (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6,
             (unsigned long long)g_dev_wrote, (unsigned long long)g_dev_files, (unsigned long long)g_dev_hit);
    } });
}
// 现编了一条（会被序列化器收下的）：记下键串，防抖 10 秒写盘
static void dev_note_key(NSString *k) {
    if ((!g_dev_ser && !g_dev3_active) || !k.length) return;
    pthread_mutex_lock(&g_dev_mu); [g_dev_pend addObject:k]; pthread_mutex_unlock(&g_dev_mu);
    if (atomic_load(&g_archive_stopping)) return;
    if (atomic_exchange(&g_dev_sched, 1)) return;
    uint64_t epoch = atomic_load(&g_archive_epoch);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), g_dev_q, ^{
        if (epoch == atomic_load(&g_archive_epoch) && !atomic_load(&g_archive_stopping)) dev_write("防抖 10 秒");
    });
}
static void dev_note_new(id d) { dev_note_key(pso_pname(d)); }
void gal_pso_dev_flush(const char *why) {
    if (g_dev3_active) {
        // completion 不拿 GAL_API_LOCK：即使 shutdown/进后台持该锁，也能等到最后一条收录。
        dispatch_group_wait(g_dev_async3, DISPATCH_TIME_FOREVER);
        dispatch_sync(g_dev_q, ^{ @autoreleasepool { dev_write3(why); } });
        return;
    }
    dev_write(why);
}
// 特化那一维的持久化：特化结果序列化器不收（p2 实测），改为运行时特化出一条后，在后台按完整描述（颜色格式 / 混合 / 写掩码都定）编一条完整管线让它收；
//   下次启动 gal_state.m 先按完整描述查设备归档，命中就不再特化（不依赖系统 Metal 缓存）。每种（基础管线 × 组合）只收一次
static _Atomic uint64_t g_dev_cap[5];   // 0 起 1 收下 2 失败（非连接中断的真失败） 3 连接中断后延迟重试的次数 4 重试用尽仍没收下
static void dev_capture3(id descriptor, int compute) {
    if (!g_dev3_active) return;
    Class expected = compute ? MTLComputePipelineDescriptor.class : MTLRenderPipelineDescriptor.class;
    if (![descriptor isKindOfClass:expected]) {
        g_dev_cap[2]++; GLOG("【红】Metal 3 设备归档收录的描述类型不对"); return;
    }
    id d = [descriptor copy];
    if (compute) [(MTLComputePipelineDescriptor *)d setBinaryArchives:@[]]; else [(MTLRenderPipelineDescriptor *)d setBinaryArchives:@[]];
    NSString *key = pso_pname(d); if (!key.length) { GLOG("【红】Metal 3 设备归档描述缺函数名，不能登记"); return; }
    g_dev_cap[0]++;
    dispatch_async(g_dev_q, ^{ @autoreleasepool {
        NSError *e = nil;
        BOOL ok = compute ? [g_dev_arch3 addComputePipelineFunctionsWithDescriptor:d error:&e] : [g_dev_arch3 addRenderPipelineFunctionsWithDescriptor:d error:&e];
        if (ok) { g_dev_cap[1]++; [g_dev_desc3 addObject:@{@"descriptor": d, @"compute": @(compute)}]; dev_note_key(key); }
        else { g_dev_cap[2]++; GLOG("【红】Metal 3 设备归档收录失败（%s）：%s", key.UTF8String, e.localizedDescription.UTF8String); }
    } });
}
id gal_pso_dev_lookup(id d) { return dev_find(d, 0); }
// 编译服务连接中断（XPC_ERROR_CONNECTION_INTERRUPTED，10-23 巫师3 冷局进程实占 4.7 GB 时）：系统在内存压力下先杀 MTLCompilerService，
//   Metal 自己已当场重试过几次（报错原文「after multiple retries」），立刻再试多半还撞上，所以隔 30 / 120 / 300 秒再排进后台编译（同样受 2 路并发限制），
//   不报红；三次都没收下记「重试用尽」一行（不是【红】：这条下次启动首遇时照样现编、再走一遍收录，不会永久缺）。别的编译错误照旧报红
static int dev_xpc_lost(NSError *e) { return e && ([e.localizedDescription rangeOfString:@"XPC_ERROR_CONNECTION_INTERRUPTED"].location != NSNotFound ||
                                                   [e.localizedDescription rangeOfString:@"interrupted connection"].location != NSNotFound); }
static void dev_capture_try(id d, int compute, int attempt, uint64_t epoch) {
    if (epoch != atomic_load(&g_archive_epoch) || atomic_load(&g_archive_stopping)) return;
    gal_compile_bg(^(id c) { NSError *e = nil; id p = nil;
        if (epoch != atomic_load(&g_archive_epoch) || atomic_load(&g_archive_stopping)) return;
        if (compute) p = [c newComputePipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e]; else p = [c newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e];
        if (p) { g_dev_cap[1]++; dev_note_new(d); if (attempt) GLOG("设备归档：编译服务中断后第 %d 次重试收下", attempt); return; }
        if (dev_xpc_lost(e)) {
            static const int delay_s[3] = {30, 120, 300};
            if (attempt < 3) { g_dev_cap[3]++; static _Atomic int nl; if (nl++ < 4) GLOG("设备归档：编译服务连接中断（系统内存压力下编译服务被回收），%d 秒后重试（第 %d 次）", delay_s[attempt], attempt + 1);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay_s[attempt] * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ dev_capture_try(d, compute, attempt + 1, epoch); });
                return; }
            g_dev_cap[4]++; static _Atomic int ng; if (ng++ < 4) GLOG("设备归档：编译服务连接中断，重试 3 次仍没收下（下次启动首遇时再收）");
            return;
        }
        g_dev_cap[2]++; static _Atomic int n; if (n++ < 4) GLOG("【红】设备归档：后台再编一次收进来失败：%s", e.localizedDescription.UTF8String);
    });
}
static void dev_capture(id d, int compute) {
    if (gal_be_kind() == GAL_BE_MTL3) { dev_capture3(d, compute); return; }
    if (!g_dev_ser) return;
    g_dev_cap[0]++; dev_capture_try(d, compute, 0, atomic_load(&g_archive_epoch));
}
void gal_pso_dev_capture(id d) { dev_capture(d, 0); }
void gal_pso_dev_stats(uint64_t out[6]) { out[0] = g_dev_hit; out[1] = g_dev_wrote; out[2] = g_dev_files; out[3] = g_dev_cap[0]; out[4] = g_dev_cap[1]; out[5] = g_dev_cap[2]; }
// 登记前半：定目录、换挂序列化器的编译器（包归档登记之前做：之后现编的都收）
static void dev_open(const char *dir) {
    if (gal_be_kind() == GAL_BE_MTL3 && !m3_archive_on()) return;
    if (g_dev_dir || !dev_on() || g_pso_ser) return;   // 收集工具（NXGAL_PSO_SCRIPT / ARCHIVE_OUT）已挂序列化器：让给它
    NSString *key = [NSString stringWithContentsOfFile:[@(dir) stringByAppendingPathComponent:@"shader_pack.key"] encoding:NSUTF8StringEncoding error:nil];
    key = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!key.length) { NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:[@(dir) stringByAppendingPathComponent:@"gal_pso.idx"] error:nil];
        key = at ? [NSString stringWithFormat:@"i%llx-%llx", (unsigned long long)at.fileSize, (unsigned long long)at.fileModificationDate.timeIntervalSince1970] : @"nopack"; }
    if (key.length > 40) key = [key substringToIndex:40];
    char osv[64] = ""; size_t ol = sizeof osv; sysctlbyname("kern.osversion", osv, &ol, NULL, 0);
    const char *root = getenv("NXGAL_PSO_DEV_DIR");
    NSString *base = root && *root ? @(root).stringByExpandingTildeInPath : pso_dev_default_root();
    NSString *name = [NSString stringWithFormat:@"%@.xc%u.%@.%s", key, NXGAL_XC_VERSION, g_gdev.architecture.name, osv];
    if (gal_be_kind() == GAL_BE_MTL3) name = [name stringByAppendingString:@".mtl3"];
    NSString *d = [base stringByAppendingPathComponent:name];
    NSError *e = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:&e]) { GLOG("【红】设备归档目录建不出：%s", e.localizedDescription.UTF8String); return; }
    if (gal_be_kind() == GAL_BE_MTL3) {
        g_dev_arch3 = binary_archive3(nil, &e); g_dev_async3 = dispatch_group_create();
        g_dev_desc3 = [NSMutableArray array];
        g_dev3_active = g_dev_arch3 != nil;
        if (!g_dev_arch3) GLOG("【红】Metal 3 设备归档建不出（%s），只读不收", e.localizedDescription.UTF8String);
    } else {
        id ser = nil, c = gal_be_capture_compiler(g_gdev, &ser, &e);
        if (!c) GLOG("【红】设备归档：挂序列化器的编译器建不出（%s），只读不收", e.localizedDescription.UTF8String);
        else { g_dev_ser = ser; g_dev_comp = c; }
    }
    g_dev_pend = [NSMutableArray array]; g_dev_q = dispatch_queue_create("s2a.pso_dev", DISPATCH_QUEUE_SERIAL); g_dev_dir = d;
}
// 登记后半（包归档登记之后）：dev.idx 读进键表，各文件追加成 pa_get 的分片（按需开、过低区账本）；索引里指向已不存在的文件的行不要
static void dev_register(void) {
    if (!g_dev_dir) return;
    NSString *ixs = [NSString stringWithContentsOfFile:[g_dev_dir stringByAppendingPathComponent:@"dev.idx"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary<NSString *, NSNumber *> *slot = [NSMutableDictionary dictionary]; NSMutableDictionary *index = [NSMutableDictionary dictionary]; uint64_t bytes = 0; unsigned nl = 0;
    for (NSString *ln in [ixs componentsSeparatedByString:@"\n"]) {
        NSArray *c = [ln componentsSeparatedByString:@"\t"]; if (c.count != 2) continue;
        NSString *f = c[1]; NSNumber *n = slot[f];
        if (!n) { NSString *pth = [g_dev_dir stringByAppendingPathComponent:f]; NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:pth error:nil]; if (!at) continue;
            n = @(pa_register_path(pth)); slot[f] = n; bytes += at.fileSize; }
        unsigned long long k = strtoull([c[0] UTF8String], NULL, 16); NSMutableArray *a = index[@(k)]; if (!a) index[@(k)] = a = [NSMutableArray array];
        if (![a containsObject:n]) [a addObject:n]; nl++;
    }
    pthread_mutex_lock(&g_dev_mu); g_dev_ix = index; pthread_mutex_unlock(&g_dev_mu);
    // 账本：包归档没登记成功（本机没有包归档）时也要接上
    const s2a_lowva_api *lv = lv_get();
    if (lv && !g_lv) { g_lv_me = lv->user("管线归档", NULL, NULL); g_lv = lv; }
    g_dev_nf = slot.count; g_dev_mb = bytes;
    GLOG("设备归档：%s 登记 %lu 个文件（%.1f MB）、索引 %u 行 / %lu 键，按需开片、低区账本%s；新现编收进来、防抖 10 秒 / 进后台写盘", g_dev_dir.lastPathComponent.UTF8String,
         (unsigned long)slot.count, bytes / 1048576.0, nl, (unsigned long)g_dev_ix.count, g_lv ? "已接" : "没有（不设限）");
}
// 本机型号标识（hw.machine：iPhone18,2 / iPad16,3；Mac 上是 arm64，型号另在 hw.model）：归档登记 / 不匹配行带上，诊断包与正式局日志即「型号 → 架构」实测对照
//   （出包查架构用 Xcode 自带 device_traits.db，见 pack/jobs/target.py；这里的读数可与它对照）
static const char *s2a_hw_model(void) {
    static char m[64];
    if (!m[0]) { size_t n = sizeof m; if (sysctlbyname(TARGET_OS_IPHONE ? "hw.machine" : "hw.model", m, &n, NULL, 0) != 0) snprintf(m, sizeof m, "?"); }
    return m;
}
static int32_t pso_open_dir(const char *dir) {
    @autoreleasepool {
        if (!g_gdev || !dir) return -1;
        if (gal_be_kind() == GAL_BE_MTL3 && !m3_archive_on()) {
            GLOG("Metal 3 管线归档缺省关闭（NXGAL_M3_ARCHIVE=1 开启），首遇按完整描述现建"); return 1;
        }
#if TARGET_OS_IPHONE
        const char *plat = "ios";
#else
        const char *plat = "macos";
#endif
        long major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        NSString *arch = [NSString stringWithFormat:@"gal_pso.%@.", g_gdev.architecture.name], *pre = [NSString stringWithFormat:@"%@%s%ld.", arch, plat, major];
        NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(dir) error:nil];
        NSArray *fs = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@ AND SELF ENDSWITH '.bin'", pre]];
        if (!fs.count) {
            // 包里实际出了哪些「架构.平台大版本」（10-23：原先只在本机架构名下找，包按别的架构出时报「包里有：无」，诊断包看不出包是给谁出的）。
            //   出包按目标设备的 GPU 架构 + 系统大版本出一份（S2A_PSO_ARCHS / S2A_PSO_OS，pack/jobs/target.py）：架构不同 = 包不是给这台设备出的；只差系统大版本 = 系统升级过
            NSMutableSet<NSString *> *have = [NSMutableSet set]; int same_arch = 0;
            for (NSString *f in [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'gal_pso.' AND SELF ENDSWITH '.bin'"]]) {
                NSArray *c = [f componentsSeparatedByString:@"."]; if (c.count < 4) continue;
                [have addObject:[NSString stringWithFormat:@"%@ %@", c[1], c[2]]]; if ([c[1] isEqualToString:g_gdev.architecture.name]) same_arch = 1;
            }
            const char *why = !have.count ? "包里没有任何管线归档" : same_arch ? "系统大版本对不上（系统升级过？）：请按本机当前系统重新出包"
                                                                            : "GPU 架构对不上（包不是给这台设备出的）：请按本机重新出包（出包时连上本机或在列表里选本机型号）";
            GLOG("【红】管线归档与本机不匹配：本机型号 %s、架构 %s、%s %ld；包里有：%s——%s。首遇全部现建", s2a_hw_model(), g_gdev.architecture.name.UTF8String, plat, major,
                 have.count ? [have.allObjects componentsJoinedByString:@"，"].UTF8String : "无", why);
            return 1;
        }
        NSError *e = nil; NSData *ix = [NSData dataWithContentsOfFile:[@(dir) stringByAppendingPathComponent:@"gal_pso.idx"] options:NSDataReadingMappedIfSafe error:&e];
        const uint32_t *h = ix.length >= 16 ? ix.bytes : NULL;
        if (!h || h[0] != 0x49535047u || h[1] != 1 || 16 + (uint64_t)h[2] * 16 != ix.length) {
            GLOG("【红】管线归档：%s/gal_pso.idx 缺或坏（%s），归档不用、首遇现建", dir, ix ? "魔数 / 版本 / 长度不符" : e.localizedDescription.UTF8String); return -1; }
        // 下标 = 片号（文件名 <前缀><片号>.bin），缺的片号留空串
        NSMutableArray<NSString *> *paths = [NSMutableArray array]; uint64_t bytes = 0;
        for (NSString *f in fs) {
            int n = [f substringWithRange:NSMakeRange(pre.length, f.length - pre.length - 4)].intValue;
            while ((int)paths.count <= n) [paths addObject:@""];
            paths[n] = [@(dir) stringByAppendingPathComponent:f];
        }
        // 重登记不能释放已有对象：管线可能还持有旧映射，再开会重复占地址。
        NSMutableData *slotdata = [NSMutableData dataWithLength:paths.count * sizeof(uint32_t)]; uint32_t *slots = slotdata.mutableBytes;
        for (NSUInteger i = 0; i < paths.count; i++) {
            slots[i] = paths[i].length ? (uint32_t)pa_register_path(paths[i]) : UINT32_MAX;
            if (paths[i].length) bytes += [[NSFileManager defaultManager] attributesOfItemAtPath:paths[i] error:nil].fileSize;
        }
        pthread_mutex_lock(&g_pa_mu);
        g_pso_slots = slotdata; g_pso_idx = ix; g_pso_nidx = h[2];
        pthread_mutex_unlock(&g_pa_mu);
        // 运行时收来的特化组合表（gal_state.m 通用特化预热；出包 speccombo.py 收各款各局「特化组合」行）：跟归档同目录，有就后台补预热
        if (gal_be_kind() == GAL_BE_MTL4) { NSString *sc = [@(dir) stringByAppendingPathComponent:@"spec_combos.tsv"]; if ([[NSFileManager defaultManager] fileExistsAtPath:sc]) gal_spec_combo_load(sc.UTF8String); }
        // 低区统一账（原生层，运行时取；版本 / 大小不符当没有）
        const s2a_lowva_api *lv = lv_get();
        if (lv && !g_lv) { g_lv_me = lv->user("管线归档", NULL, NULL); g_lv = lv; }
        GLOG("管线归档已登记：%lu 片共 %.1f MB、索引 %u 条（本机型号 %s、架构 %s、%s %ld），按需开片，低区账本%s", (unsigned long)fs.count, bytes / 1048576.0, g_pso_nidx,
             s2a_hw_model(), g_gdev.architecture.name.UTF8String, plat, major, g_lv ? "已接" : "没有（不设限）"); return 0;
    }
}
// 管线描述的键串：所引用函数名逗号相连（顶点、片元、计算；出包 pso_gen.py pname 同口径）；有函数取不到名字返回 nil
static NSString *pso_pname(id d) {
    NSMutableString *k = [NSMutableString string];
    BOOL old = [d isKindOfClass:MTLRenderPipelineDescriptor.class] || [d isKindOfClass:MTLComputePipelineDescriptor.class];
    for (NSString *sel in old ? @[@"vertexFunction", @"fragmentFunction", @"computeFunction"] : @[@"vertexFunctionDescriptor", @"fragmentFunctionDescriptor", @"computeFunctionDescriptor"]) {
        SEL s = NSSelectorFromString(sel); if (![d respondsToSelector:s]) continue;
        id f = ((id (*)(id, SEL))objc_msgSend)(d, s); if (!f) continue;
        if (![f respondsToSelector:@selector(name)]) return nil;
        if (k.length) [k appendString:@","]; [k appendString:[f name]];
    }
    return k;
}
NSString *gal_pso_pname(id d) { return pso_pname(d); }
static uint64_t pso_fnv(NSString *k) { uint64_t x = 0xcbf29ce484222325ull; for (const unsigned char *c = (const unsigned char *)k.UTF8String; *c; c++) x = (x ^ *c) * 0x100000001b3ull; return x; }
NXGAL_API int32_t nxgal_pso_archive_open_dir(const char *dir) { GAL_API_LOCK();
    if (g_gdev && dir) dev_open(dir);
    int32_t r = pso_open_dir(dir);
    dev_register();
    // 管线预取用表（gal_state.m）：包归档与设备归档都登记好、低区账本接上之后再载，后台取管线时两边都查得到、开片照记账（包里没有本机归档时设备归档照样能取）
    if (g_gdev && dir && gal_be_kind() == GAL_BE_MTL4) { NSString *pu = [@(dir) stringByAppendingPathComponent:@"pso_use.tsv"]; if ([[NSFileManager defaultManager] fileExistsAtPath:pu]) gal_pso_pf_load(pu.UTF8String); }
    return r;
}
// 按键串（管线 = 所引用函数名逗号相连，shbake/pso_gen.py 同口径）查索引 → 那一片归档（按需开）；不在索引里返回空
static id pso_arch_for_key(NSString *k) {
    pthread_mutex_lock(&g_pa_mu); NSData *index = g_pso_idx, *slotdata = g_pso_slots; uint32_t nidx = g_pso_nidx; pthread_mutex_unlock(&g_pa_mu);
    if (!index) return nil;
    uint64_t x = pso_fnv(k);
    const uint8_t *t = (const uint8_t *)index.bytes + 16; const uint32_t *slots = slotdata.bytes; uint32_t lo = 0, hi = nidx;
    while (lo < hi) { uint32_t m = (lo + hi) / 2; uint64_t v; memcpy(&v, t + m * 16, 8); if (v == x) { uint32_t c; memcpy(&c, t + m * 16 + 8, 4); return c < slotdata.length / sizeof *slots ? pa_get((int)slots[c]) : nil; } if (v < x) lo = m + 1; else hi = m; }
    return nil;
}
// 按描述里的函数名查索引 → 那一片归档（按需开）；不在索引里返回空
static id pso_arch_for(id d) {
    if (!g_pso_idx) return nil;
    NSString *k = pso_pname(d); return k ? pso_arch_for_key(k) : nil;
}
static id pso_pack_find3(id d, int compute) {
    if (!m3_archive_on()) return nil;
    id p = g_pso_arch3 ? archive_pipeline3(g_pso_arch3, d, compute, nil) : nil;
    if (!p) @autoreleasepool { id a = pso_arch_for(d); if (a) p = archive_pipeline3(a, d, compute, nil); }
    return p;
}
void gal_pso_arch_stats(uint64_t out[5]) { pthread_mutex_lock(&g_pa_mu); memcpy(out, g_pa_st, sizeof g_pa_st); pthread_mutex_unlock(&g_pa_mu); }
static void pso_note(int hit, uint64_t t0) {
    if (g_pso_warming) return;
    if (hit) g_pso_hit++; else { uint64_t d = mach_absolute_time() - t0; g_pso_miss++; g_pso_build_ns += d; if (d > atomic_load(&g_pso_build_max)) atomic_store(&g_pso_build_max, d);
        if ((g_pso_arch || g_pso_idx) && !(g_pso_miss & (g_pso_miss - 1))) GLOG("管线归档未命中第 %llu 个（已命中 %llu），现建", (unsigned long long)g_pso_miss, (unsigned long long)g_pso_hit); }
    g_pso_new++;
}
// 诊断（10-21 首局根治 ③）：索引查到片号、归档按描述却没命中 = 运行时描述与出包基础管线（shbake/pso_gen.py：片元输出留空、拓扑未指定、采样数 1、
//   alpha-to-coverage / alpha-to-one 关、顶点自取不带描述符）有字段不同。打出可能不同的那几个字段，定哪些维度要出包枚举；第 1、2、4… 次打一行
static uint64_t g_pso_mm;
static void pso_arch_mismatch(id d) {
    uint64_t n = ++g_pso_mm; if (n & (n - 1)) return;
    id vf = [d respondsToSelector:@selector(vertexFunctionDescriptor)] ? [d vertexFunctionDescriptor] : nil;
    id ff = [d respondsToSelector:@selector(fragmentFunctionDescriptor)] ? [d fragmentFunctionDescriptor] : nil;
    id ca = [d respondsToSelector:@selector(colorAttachments)] ? [[d colorAttachments] objectAtIndexedSubscript:0] : nil;
    GLOG("管线归档描述不符（第 %llu 次）：顶点 %s 片元 %s；采样数 %lu、拓扑类 %lu、光栅化 %d、a2c %ld、a2one %ld、顶点描述符 %s、颜色 0 格式 %lu", (unsigned long long)n,
         [vf respondsToSelector:@selector(name)] ? [[vf name] UTF8String] : "-", [ff respondsToSelector:@selector(name)] ? [[ff name] UTF8String] : "-",
         [d respondsToSelector:@selector(rasterSampleCount)] ? (unsigned long)[d rasterSampleCount] : 0ul,
         [d respondsToSelector:@selector(inputPrimitiveTopology)] ? (unsigned long)[d inputPrimitiveTopology] : 0ul,
         [d respondsToSelector:@selector(isRasterizationEnabled)] ? (int)[d isRasterizationEnabled] : -1,
         [d respondsToSelector:@selector(alphaToCoverageState)] ? (long)[d alphaToCoverageState] : -1l,
         [d respondsToSelector:@selector(alphaToOneState)] ? (long)[d alphaToOneState] : -1l,
         [d respondsToSelector:@selector(vertexDescriptor)] && [d vertexDescriptor] ? "有" : "无",
         ca && [ca respondsToSelector:@selector(pixelFormat)] ? (unsigned long)[ca pixelFormat] : 0ul);
}
// 只查归档、不现建（管线预取）：包归档 → 设备归档
id<MTLRenderPipelineState> gal_pso_arch_lookup(id d) {
    if (gal_be_kind() == GAL_BE_MTL3) return pso_pack_find3(d, 0) ?: dev_find(d, 0);
    id<MTLRenderPipelineState> p = g_pso_arch ? [g_pso_arch newRenderPipelineStateWithDescriptor:d error:nil] : nil;
    if (!p) @autoreleasepool { id a = pso_arch_for(d); if (a) p = [a newRenderPipelineStateWithDescriptor:d error:nil]; }
    return p ?: dev_find(d, 0);
}
// 特化结果与漏掉的基础管线预编进包（10-22 维护者：iPhone 上「特化与程序无关、靠系统缓存复用」不成立——动森冷启动预热成功的组合照样慢 3.0 ms；
//   首局格残留的现建：运行时才出现的程序配对、宽线 _wl / 无点大小 _np 入口、写层号要定拓扑的，出包程序表都没覆盖）：
//   游戏程序（函数名 s<16 位十六进制>[_后缀]）每次运行时真特化 / 阻塞现建，按完整描述记一行（全是 Metal 枚举数值，本进程同一行只记一次）：
//   「特化管线 v2 <顶点函数> <片元函数|-> <拓扑类> <采样数> <a2c> <a2one> <光栅化> <槽:格式:写掩码:混合开:运算:源:目标:alpha 运算:源:目标>…」——颜色定了的（特化结果 / 直接现建的完整管线）；
//   「特化管线 b2 <顶点> <片元|-> <拓扑类> <采样数> <a2c> <a2one> <光栅化>」——颜色留空的基础管线。
//   出包 graphics/tools/shbake/specpipe.py 按款收成表，pso_gen.py 按完整描述出管线进包归档；运行时特化前先按完整描述查包归档（gal_pso_pack_lookup）再查设备归档，都没有才特化
id<MTLRenderPipelineState> gal_pso_pack_lookup(id d) {
    if (gal_be_kind() == GAL_BE_MTL3) return pso_pack_find3(d, 0);
    if (!g_pso_arch && !g_pso_idx) return nil;
    id<MTLRenderPipelineState> p = g_pso_arch ? [g_pso_arch newRenderPipelineStateWithDescriptor:d error:nil] : nil;
    if (!p) @autoreleasepool { id a = pso_arch_for(d); if (a) p = [a newRenderPipelineStateWithDescriptor:d error:nil]; }
    return p;
}
void gal_pso_note_desc(id d) {
    // Metal 3 描述没有 vertexFunctionDescriptor（函数字段叫 vertexFunction）：这张表是 Metal 4 出包归档的输入（颜色 / 混合都按 Metal 4 字段收），
    //   Metal 3 的包归档由 M3-9（#116）另出，这里不按 Metal 4 字段强行取值
    if (![d respondsToSelector:@selector(vertexFunctionDescriptor)]) return;
    static NSMutableSet *seen; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    id vf = [d vertexFunctionDescriptor], ff = [d fragmentFunctionDescriptor];
    NSString *vn = [vf respondsToSelector:@selector(name)] ? [vf name] : nil, *fn = ff && [ff respondsToSelector:@selector(name)] ? [ff name] : @"-";
    // 只记游戏程序：s<16 位十六进制>，可带 _wl / _np 等后缀（渲染器内部管线另走内部预建）
    if (!vn || vn.length < 17 || [vn characterAtIndex:0] != 's' || (vn.length > 17 && [vn characterAtIndex:17] != '_')) return;
    id c0 = [[d colorAttachments] objectAtIndexedSubscript:0]; int base = [[c0 valueForKey:@"pixelFormat"] unsignedLongValue] == MTLPixelFormatUnspecialized;
    NSMutableString *l = [NSMutableString stringWithFormat:@"%s %@ %@ %lu %lu %ld %ld %d", base ? "b2" : "v2", vn, fn, (unsigned long)[d inputPrimitiveTopology], (unsigned long)[d rasterSampleCount],
        [[d valueForKey:@"alphaToCoverageState"] longValue], [[d valueForKey:@"alphaToOneState"] longValue], (int)[d isRasterizationEnabled]];
    for (int i = 0; i < 8 && !base; i++) { id c = [[d colorAttachments] objectAtIndexedSubscript:(NSUInteger)i]; if ([c pixelFormat] == MTLPixelFormatInvalid) continue;
        [l appendFormat:@" %d:%lu:%lu:%ld:%ld:%ld:%ld:%ld:%ld:%ld", i, (unsigned long)[c pixelFormat], [[c valueForKey:@"writeMask"] unsignedLongValue], [[c valueForKey:@"blendingState"] longValue],
            [[c valueForKey:@"rgbBlendOperation"] longValue], [[c valueForKey:@"sourceRGBBlendFactor"] longValue], [[c valueForKey:@"destinationRGBBlendFactor"] longValue],
            [[c valueForKey:@"alphaBlendOperation"] longValue], [[c valueForKey:@"sourceAlphaBlendFactor"] longValue], [[c valueForKey:@"destinationAlphaBlendFactor"] longValue]]; }
    pthread_mutex_lock(&mu); if (!seen) seen = [NSMutableSet set];
    int dup = [seen containsObject:l]; if (!dup) [seen addObject:l]; pthread_mutex_unlock(&mu);
    if (!dup) GLOG("特化管线 %s", l.UTF8String);
}
// ---------- Metal 3 管线编译（gal_be.h「管线与归档」「管线特化」Metal 3 列；卡 M3-8 / #115）----------
// Metal 3 的完整描述查 MTLBinaryArchive（NXGAL_M3_ARCHIVE=1，缺省关）；没有特化，归档未命中按完整描述现建。
//   照记「管线现建」计数（pso_note）与逐条行，不静默；内部管线（gal_pass / gal_present / gal_tex）仍出 Metal 4 描述，给了就报红，不兜底
static const char *fn3_nm(id f) { return f && [f respondsToSelector:@selector(name)] ? [[f name] UTF8String] : "-"; }
static id<MTLRenderPipelineState> pso_new_render3(id d, NSError **e) {
    uint64_t t0 = mach_absolute_time();
    if (![d isKindOfClass:[MTLRenderPipelineDescriptor class]]) {
        static int n; if (n++ < 8) GLOG("【红】Metal 3：渲染管线描述不是 MTLRenderPipelineDescriptor（%s），建不了", d ? class_getName([d class]) : "空");
        if (e) *e = [NSError errorWithDomain:@"s2a.gal" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Metal 3：渲染管线描述类型不对"}];
        return nil;
    }
    MTLRenderPipelineDescriptor *rd = d;
    if (!rd.vertexFunction) {
        static int n; if (n++ < 8) GLOG("【红】Metal 3：渲染管线描述没有顶点函数（库里取不到），建不了");
        if (e) *e = [NSError errorWithDomain:@"s2a.gal" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Metal 3：渲染管线描述没有顶点函数"}];
        return nil;
    }
    id<MTLRenderPipelineState> p = nil; NSError *keep = nil;
    { GP_SCOPE(GP_PSO_ARCH); p = gal_pso_arch_lookup(rd); }
    int hit = p != nil;
    int capture = !hit && g_dev3_active;
    if (capture) dispatch_group_enter(g_dev_async3);
    if (!p) @autoreleasepool { NSError *x = nil; p = [g_gdev newRenderPipelineStateWithDescriptor:rd error:&x]; keep = x; }   // 池：错误对象在池里生成，先接住再出池
    if (e) *e = keep;
    if (p) {
        pso_note(hit, t0);
        if (!hit && !g_pso_warming) { dev_capture(rd, 0);
            GLOG("管线现建：顶点 %s 片元 %s（%.1f ms，第 %llu 条，Metal 3 完整描述）", fn3_nm(rd.vertexFunction), fn3_nm(rd.fragmentFunction), pso_ms(t0), (unsigned long long)g_pso_miss); }
    }
    if (capture) dispatch_group_leave(g_dev_async3);
    return p;
}
// Metal 3 计算描述：gal_be_compute_desc 出的是 Metal 4 形态（库 + 函数名，带常量时另包一层），老接口要 MTLFunction。
//   两种输入都收：已经是 MTLComputePipelineDescriptor 的直接用；否则按里面的函数描述（含常量值）转一条，不静默丢常量
static id pso_compute3_desc(id d) {
    if (!d) return nil;
    if ([d isKindOfClass:[MTLComputePipelineDescriptor class]]) return d;
    id fd = [d respondsToSelector:@selector(computeFunctionDescriptor)] ? [d computeFunctionDescriptor] : nil;
    if (!fd) return nil;
    MTLFunctionConstantValues *cv = nil;
    if ([fd respondsToSelector:@selector(functionDescriptor)]) {   // 常量特化那层
        cv = [fd valueForKey:@"constantValues"]; fd = [fd valueForKey:@"functionDescriptor"];
    }
    id lib = [fd respondsToSelector:@selector(library)] ? [fd valueForKey:@"library"] : nil;
    NSString *nm = [fd respondsToSelector:@selector(name)] ? [fd valueForKey:@"name"] : nil;
    if (!lib || !nm.length) return nil;
    NSError *x = nil; id<MTLFunction> f = cv ? [lib newFunctionWithName:nm constantValues:cv error:&x] : [lib newFunctionWithName:nm];
    if (!f) { static int n; if (n++ < 8) GLOG("【红】Metal 3：库里取不到计算函数 %s%s%s", nm.UTF8String, x ? "：" : "", x ? x.localizedDescription.UTF8String : ""); return nil; }
    MTLComputePipelineDescriptor *c3 = [MTLComputePipelineDescriptor new];
    c3.computeFunction = f;
    return c3;
}
static id<MTLComputePipelineState> pso_new_compute3(id d, NSError **e) {
    uint64_t t0 = mach_absolute_time();
    id c3 = pso_compute3_desc(d);
    if (!c3) {
        static int n; if (n++ < 8) GLOG("【红】Metal 3：计算管线描述转不出带函数的 MTLComputePipelineDescriptor（%s），建不了", d ? class_getName([d class]) : "空");
        if (e) *e = [NSError errorWithDomain:@"s2a.gal" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Metal 3：计算管线描述没有函数"}];
        return nil;
    }
    id<MTLComputePipelineState> p = nil; NSError *keep = nil;
    { GP_SCOPE(GP_PSO_ARCH); p = pso_pack_find3(c3, 1) ?: dev_find(c3, 1); }
    int hit = p != nil;
    int capture = !hit && g_dev3_active;
    if (capture) dispatch_group_enter(g_dev_async3);
    if (!p) @autoreleasepool { NSError *x = nil; p = [g_gdev newComputePipelineStateWithDescriptor:c3 options:MTLPipelineOptionNone reflection:nil error:&x]; keep = x; }
    if (e) *e = keep;
    if (p) {
        pso_note(hit, t0);
        if (!hit && !g_pso_warming) { dev_capture(c3, 1);
            GLOG("管线现建：计算 %s（%.1f ms，第 %llu 条，Metal 3）", fn3_nm([(MTLComputePipelineDescriptor *)c3 computeFunction]), pso_ms(t0), (unsigned long long)g_pso_miss); }
    }
    if (capture) dispatch_group_leave(g_dev_async3);
    return p;
}
id<MTLRenderPipelineState> gal_new_render_pso(MTL4PipelineDescriptor *d, NSError **e) {
    if (gal_be_kind() == GAL_BE_MTL3) return pso_new_render3(d, e);
    uint64_t t0 = mach_absolute_time();
    // 着色器包分片归档：索引直查那一片（不再逐片试）。包自动释放池：取到的归档随这次建完即放，不留到外层池排空（关掉的片才真放映射）
    id<MTLRenderPipelineState> p = nil;
    { GP_SCOPE(GP_PSO_ARCH);   // 从归档取的墙钟（含查索引与开片，开片另记 pso_open）
    p = g_pso_arch ? [g_pso_arch newRenderPipelineStateWithDescriptor:d error:nil] : nil;
    if (!p) @autoreleasepool { id a = pso_arch_for(d); if (a) { p = [a newRenderPipelineStateWithDescriptor:d error:nil]; if (!p) pso_arch_mismatch(d); } }
    if (!p) p = dev_find(d, 0); }
    int hit = p != nil; if (!p) { p = [g_gcomp newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:e]; if (p && !g_pso_warming) { dev_capture(d, 0); gal_pso_note_desc(d); } }
    if (p) pso_note(hit, t0);
    // 现建全量记一行（10-21 起不再只打前 16 条；判据「起局到收局全程单条 > 1 ms 的现建 0」靠它逐条核）：函数名区分游戏程序（s<键>）与渲染器内部管线，带耗时与序号
    if (!hit && !g_pso_warming) {
        id dd = d, vf = [dd respondsToSelector:@selector(vertexFunctionDescriptor)] ? [dd vertexFunctionDescriptor] : nil, ff = [dd respondsToSelector:@selector(fragmentFunctionDescriptor)] ? [dd fragmentFunctionDescriptor] : nil;   // 按 id 问，不写 Metal 4 类名（MTL4 棘轮）
        GLOG("管线现建：顶点 %s 片元 %s（%.1f ms，第 %llu 条）", [vf respondsToSelector:@selector(name)] ? [[vf name] UTF8String] : "-", [ff respondsToSelector:@selector(name)] ? [[ff name] UTF8String] : "-",
             pso_ms(t0), (unsigned long long)g_pso_miss);
    }
    return p;
}
// 异步现建（首局根治 B，安全网，见 gal_internal.h）：归档没命中的基础管线不在绘制线程上等编译（暗黑3 单条 281–671 ms），交 MTL4 编译器异步任务；
//   编好后下一次绘制取用，「管线现建」行在取用时照记（耗时 = 起任务到编完），首局判据计数口径不变；内部管线预建期间（g_pso_warming）不走这里
// claimed：谁来编（0 没人；1 已有一方认领）——后台槽拿到时认领，等待方（gal_pso_job_wait）先试认领、认到就在本线程上编，不排在后台积压后面；
// refs：后台块与取用方各持一份（等待方认领后编完取走、后台块之后才轮到，不能读已释放的作业），两边都放手才释放
struct gal_pso_job { _Atomic int done, claimed, refs; uint64_t t0, t1; void *p, *d; char vs[48], fs[48]; dispatch_semaphore_t sem; int inl; };
static void pso_job_unref(gal_pso_job *j) { if (atomic_fetch_sub(&j->refs, 1) == 1) { if (j->d) CFRelease(j->d); free(j); } }
static _Atomic int g_pso_inflight; uint64_t g_pso_wait_inline;   // g_pso_wait_inline：等待方认领、当场编的条数（单测 / 诊断读）
   // 异步现建在编条数（慢特化行报）
// 缺省关（单测 / 录放逐像素要确定性）：产品局由渲染循环 graphics/loop/RenderLoop.cs 设 NXGAL_PSO_ASYNC=1 打开
int gal_pso_async_on(void) { static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_PSO_ASYNC"); on = v && *v == '1'; } return on && !g_pso_warming; }
static void fn_name(id f, char *o, size_t n) { snprintf(o, n, "%s", [f respondsToSelector:@selector(name)] ? [[f name] UTF8String] : "-"); }
// Metal 3 异步现建：老接口一直有的 newRenderPipelineStateWithDescriptor:completionHandler:（没有编译器任务选项）。
//   claimed 一次置 1：老接口没有「等待方认领、当场编」这条路，等待方睡在信号量上；取用时 gal_pso_job_take 照记「管线现建」（同 Metal 4 口径）
static gal_pso_job *pso_new_render3_async(id d, id<MTLRenderPipelineState> *hit) {
    *hit = nil;
    if (![d isKindOfClass:[MTLRenderPipelineDescriptor class]]) {
        static int n; if (n++ < 8) GLOG("【红】Metal 3：异步现建的描述不是 MTLRenderPipelineDescriptor（%s），建不了", d ? class_getName([d class]) : "空");
        return NULL;
    }
    uint64_t t0 = mach_absolute_time();
    MTLRenderPipelineDescriptor *rd = m3_archive_on() ? [d copy] : d;
    { GP_SCOPE(GP_PSO_ARCH); *hit = gal_pso_arch_lookup(rd); }
    if (*hit) { pso_note(1, t0); return NULL; }
    int capture = g_dev3_active;
    if (capture) dispatch_group_enter(g_dev_async3);
    gal_pso_job *j = calloc(1, sizeof *j); j->t0 = mach_absolute_time(); j->sem = dispatch_semaphore_create(0); j->refs = 2; atomic_store(&j->claimed, 1); g_pso_inflight++;
    snprintf(j->vs, sizeof j->vs, "%s", fn3_nm(rd.vertexFunction)); snprintf(j->fs, sizeof j->fs, "%s", fn3_nm(rd.fragmentFunction));
    [g_gdev newRenderPipelineStateWithDescriptor:rd completionHandler:^(id<MTLRenderPipelineState> q, NSError *er) {
        if (!q) GLOG("【红】管线异步现建失败（Metal 3，顶点 %s 片元 %s）：%s", j->vs, j->fs, er.localizedDescription.UTF8String);
        if (q && capture) dev_capture3(rd, 0);
        j->p = q ? (void *)CFBridgingRetain(q) : NULL; j->t1 = mach_absolute_time(); g_pso_inflight--; atomic_store(&j->done, 1); dispatch_semaphore_signal(j->sem);
        if (capture) dispatch_group_leave(g_dev_async3);
        pso_job_unref(j);   // 本块与取用方各持一份：取用后由后放手的一方释放
    }];
    return j;
}
gal_pso_job *gal_new_render_pso_async(id d, id<MTLRenderPipelineState> *hit) {
    if (gal_be_kind() == GAL_BE_MTL3) return pso_new_render3_async(d, hit);
    uint64_t t0 = mach_absolute_time();
    id<MTLRenderPipelineState> p = nil;
    { GP_SCOPE(GP_PSO_ARCH); p = gal_pso_arch_lookup(d); }
    if (p) { pso_note(1, t0); *hit = p; return NULL; }
    *hit = nil; gal_pso_note_desc(d);
    gal_pso_job *j = calloc(1, sizeof *j); j->t0 = t0; j->sem = dispatch_semaphore_create(0); j->refs = 2; j->d = (void *)CFBridgingRetain(d); g_pso_inflight++;
    id dd = d; fn_name([dd respondsToSelector:@selector(vertexFunctionDescriptor)] ? [dd vertexFunctionDescriptor] : nil, j->vs, sizeof j->vs);
    fn_name([dd respondsToSelector:@selector(fragmentFunctionDescriptor)] ? [dd fragmentFunctionDescriptor] : nil, j->fs, sizeof j->fs);
    gal_compile_bg(^(id c) {
        if (atomic_exchange(&j->claimed, 1)) { pso_job_unref(j); return; }   // 等待方已认领、在它线程上编了
        NSError *e = nil; id<MTLRenderPipelineState> q = [c newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e];
        if (!q) GLOG("【红】管线异步现建失败（顶点 %s 片元 %s）：%s", j->vs, j->fs, e.localizedDescription.UTF8String);
        if (q) dev_note_new(d);
        j->p = q ? (void *)CFBridgingRetain(q) : NULL; j->t1 = mach_absolute_time(); g_pso_inflight--; atomic_store(&j->done, 1); dispatch_semaphore_signal(j->sem);
        pso_job_unref(j);
    });
    return j;
}
// 在绘制线程上要这条管线（同原阻塞现建；计数与「管线现建」行照记）。后台还没开始编（作业排在后台槽 2 条 UTILITY 的积压后面：
//   每条现建都另排一条收进设备归档的后台活，10-24 测试设备1 xc3_1024150549_1 第 1259 帧渲染线程在这里等了 10 秒以上）→ 认领下来用主编译器（不挂序列化器）当场编，
//   之后照同步现建口径另排一条后台收进设备归档；后台已在编的照等它
id<MTLRenderPipelineState> gal_pso_job_wait(gal_pso_job *j) {
    if (!atomic_exchange(&j->claimed, 1)) {
        NSError *e = nil; id d = (__bridge id)j->d; id<MTLRenderPipelineState> q = [g_gcomp newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e];
        if (!q) GLOG("【红】管线现建失败（顶点 %s 片元 %s）：%s", j->vs, j->fs, e.localizedDescription.UTF8String);
        else dev_capture(d, 0);
        j->p = q ? (void *)CFBridgingRetain(q) : NULL; j->t1 = mach_absolute_time(); g_pso_inflight--; j->inl = 1; atomic_store(&j->done, 1); g_pso_wait_inline++;
    } else dispatch_semaphore_wait(j->sem, DISPATCH_TIME_FOREVER);
    int done; return gal_pso_job_take(j, &done);
}
id<MTLRenderPipelineState> gal_pso_job_take(gal_pso_job *j, int *done) {
    if (!atomic_load(&j->done)) { *done = 0; return nil; }
    *done = 1; id<MTLRenderPipelineState> p = j->p ? CFBridgingRelease(j->p) : nil;
    if (p) { g_pso_miss++; g_pso_build_ns += j->t1 - j->t0; g_pso_new++; if (j->t1 - j->t0 > atomic_load(&g_pso_build_max)) atomic_store(&g_pso_build_max, j->t1 - j->t0);
        if ((g_pso_arch || g_pso_idx) && !(g_pso_miss & (g_pso_miss - 1))) GLOG("管线归档未命中第 %llu 个（已命中 %llu），异步现建", (unsigned long long)g_pso_miss, (unsigned long long)g_pso_hit);
        GLOG("管线现建：顶点 %s 片元 %s（%.1f ms，第 %llu 条，%s）", j->vs, j->fs, pso_ns_ms(j->t1 - j->t0), (unsigned long long)g_pso_miss, j->inl ? "后台没轮到、绘制线程当场编" : "异步"); }
    pso_job_unref(j); return p;
}
// 管线特化（gal_be.h「管线特化」）：从片元输出留空的基础管线按 d 里的颜色格式 / 混合 / 写掩码特化；不计入现建（g_pso_miss），另计 g_pso_spec
static uint64_t g_pso_spec, g_pso_spec_ns, g_pso_spec_max, g_pso_spec_slow;
uint64_t gal_pso_spec_count(void) { return g_pso_spec; }
// 异步特化（通用特化预热，gal_state.m）：在编译器线程上做，不计入运行时特化读数；done 在编译器线程上回调（失败给 nil）
void gal_specialize_render_pso_async(id d, id<MTLRenderPipelineState> base, void (^done)(id<MTLRenderPipelineState>)) {
    gal_compile_bg(^(id c) { done([c newRenderPipelineStateBySpecializationWithDescriptor:d pipeline:base error:nil]); });
}
int gal_pso_can_specialize(void) { static int on = -1; if (on < 0) { const char *v = getenv("NXGAL_PSO_SPECIALIZE"); on = !(v && *v == '0'); } return on && gal_be_kind() == GAL_BE_MTL4; }   // =0 关（A/B）；Metal 3 没有特化接口
void gal_pso_unspecialize_color(MTL4RenderPipelineDescriptor *d, int i) {
    MTL4RenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
    c.pixelFormat = MTLPixelFormatUnspecialized; c.blendingState = MTL4BlendStateUnspecialized; c.writeMask = MTLColorWriteMaskUnspecialized;
    c.sourceRGBBlendFactor = c.destinationRGBBlendFactor = c.sourceAlphaBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorUnspecialized;
    c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationUnspecialized;
}
int gal_xc_busy(void);
// 慢特化行的管线摘要：顶点 / 片元函数名 + 每个有格式的颜色槽「槽:格式/掩码/混合开关」
static void spec_desc(id d, char *o, size_t n) {
    char vs[48], fs[48]; fn_name([d vertexFunctionDescriptor], vs, sizeof vs); fn_name([d fragmentFunctionDescriptor], fs, sizeof fs);
    int w = snprintf(o, n, "顶点 %s 片元 %s 颜色", vs, fs);
    for (int i = 0; i < 8 && w > 0 && (size_t)w < n; i++) { id c = [[d colorAttachments] objectAtIndexedSubscript:(NSUInteger)i];
        if ([c pixelFormat] == MTLPixelFormatInvalid) continue;
        w += snprintf(o + w, n - (size_t)w, " %d:%lu/%lx/%ld", i, (unsigned long)[c pixelFormat], [[c valueForKey:@"writeMask"] unsignedLongValue], [[c valueForKey:@"blendingState"] longValue]);
        if ([[c valueForKey:@"blendingState"] longValue] == 1 && w > 0 && (size_t)w < n)
            w += snprintf(o + w, n - (size_t)w, "(%ld,%ld,%ld,%ld,%ld,%ld)", [[c valueForKey:@"rgbBlendOperation"] longValue], [[c valueForKey:@"sourceRGBBlendFactor"] longValue], [[c valueForKey:@"destinationRGBBlendFactor"] longValue],
                          [[c valueForKey:@"alphaBlendOperation"] longValue], [[c valueForKey:@"sourceAlphaBlendFactor"] longValue], [[c valueForKey:@"destinationAlphaBlendFactor"] longValue]);
        static const char *const sn[4] = {"不在表", "在编", "成功", "失败"};
        if (w > 0 && (size_t)w < n) w += snprintf(o + w, n - (size_t)w, "[预热%s]", sn[gal_spec_combo_status(c) & 3]); }
}
id<MTLRenderPipelineState> gal_specialize_render_pso(MTL4RenderPipelineDescriptor *d, id<MTLRenderPipelineState> base, NSError **e) {
    uint64_t t0 = mach_absolute_time();
    id<MTLRenderPipelineState> p = [g_gcomp newRenderPipelineStateBySpecializationWithDescriptor:d pipeline:base error:e];
    // 特化读数（判据「中位 0 ms 的运行时特化不计入，但要有读数证明」）：每次累计、记最长；单次 > 1 ms 逐条报（应为 0），每 1/2/4/8… 次打一行汇总
    if (p) { uint64_t dt = mach_absolute_time() - t0; g_pso_spec++; g_pso_spec_ns += dt; if (dt > g_pso_spec_max) g_pso_spec_max = dt;
        double ms = pso_ms(t0);
        // 单次 > 1 ms 算首遇延迟（10-21 判据），归首局格、不进能玩格：标「【首遇】」不标「【红】」（tools/redline.py 见「【红】」即计宿主报红、能玩格红）
        if (ms > 1.0) { g_pso_spec_slow++; char sd[400]; spec_desc(d, sd, sizeof sd);
            GLOG("【首遇】管线特化慢：%.1f ms（第 %llu 次特化，累计慢 %llu 次）：%s；当时在编 异步管线 %d 条、着色器 %d 支", ms, (unsigned long long)g_pso_spec, (unsigned long long)g_pso_spec_slow,
                 sd, (int)g_pso_inflight, gal_xc_busy()); }
        if (!(g_pso_spec & (g_pso_spec - 1))) GLOG("管线特化：%llu 次，累计 %.1f ms、最长 %.2f ms、单次 > 1 ms %llu 次", (unsigned long long)g_pso_spec, pso_ns_ms(g_pso_spec_ns), pso_ns_ms(g_pso_spec_max), (unsigned long long)g_pso_spec_slow); }
    return p;
}
// 特化探针（不计入运行时特化读数）：返回耗时 ms，失败返回 -1。启动时量「部分掩码 / 混合 × 格式」头一次特化是否真编译、是否跨进程被系统缓存记住
double gal_specialize_probe(id d, id<MTLRenderPipelineState> base) {
    uint64_t t0 = mach_absolute_time(); NSError *e = nil;
    id p = [g_gcomp newRenderPipelineStateBySpecializationWithDescriptor:d pipeline:base error:&e];
    return p ? pso_ms(t0) : -1;
}
id<MTLComputePipelineState> gal_new_compute_pso(MTL4ComputePipelineDescriptor *d, NSError **e) {
    if (gal_be_kind() == GAL_BE_MTL3) return pso_new_compute3(d, e);
    uint64_t t0 = mach_absolute_time();
    id<MTLComputePipelineState> p = g_pso_arch ? [g_pso_arch newComputePipelineStateWithDescriptor:d error:nil] : nil;
    if (!p) @autoreleasepool { id a = pso_arch_for(d); if (a) p = [a newComputePipelineStateWithDescriptor:d error:nil]; }
    if (!p) p = dev_find(d, 1);
    int hit = p != nil; if (!p) { p = [g_gcomp newComputePipelineStateWithDescriptor:d compilerTaskOptions:nil error:e]; if (p && !g_pso_warming) dev_capture(d, 1); }
    if (p) pso_note(hit, t0);
    if (!hit && !g_pso_warming) { id cf = d.computeFunctionDescriptor; GLOG("管线现建：计算 %s（%.1f ms，第 %llu 条）", [cf respondsToSelector:@selector(name)] ? [[cf name] UTF8String] : "-", pso_ms(t0), (unsigned long long)g_pso_miss); }
    return p;
}
void gal_pso_cache_flush(void) {
    if (!g_pso_ser || !g_pso_new) return;
    g_pso_new = 0; NSError *e = nil;
    if (g_pso_script) { NSData *js = [g_pso_ser serializeAsPipelinesScriptWithError:&e]; NSString *tmp = [g_pso_script stringByAppendingString:@".tmp"];
        if (!js || ![js writeToFile:tmp atomically:NO] || rename(tmp.fileSystemRepresentation, g_pso_script.fileSystemRepresentation)) { atomic_store(&g_pso_write_error, 1); static int n; if (n++ < 3) GLOG("【红】写管线描述失败：%s", e ? e.localizedDescription.UTF8String : "写文件失败"); } }
    if (g_pso_arch_out) { NSString *tmp = [g_pso_arch_out.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@"tmp_" stringByAppendingString:g_pso_arch_out.lastPathComponent]];   // 保留扩展名
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        if (![g_pso_ser serializeAsArchiveAndFlushToURL:[NSURL fileURLWithPath:tmp] error:&e] || rename(tmp.fileSystemRepresentation, g_pso_arch_out.fileSystemRepresentation)) { atomic_store(&g_pso_write_error, 1); static int n; if (n++ < 3) GLOG("【红】写管线归档失败：%s", e ? e.localizedDescription.UTF8String : strerror(errno)); } }
}
NXGAL_API int nxgal_pso_inflight(void) { return atomic_load(&g_pso_inflight); }
NXGAL_API uint64_t nxgal_pso_build_max_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return atomic_load(&g_pso_build_max) * tb.numer / tb.denom; }   // 不拿锁：单个原子量
NXGAL_API void nxgal_pso_cache_stats(uint64_t out[4]) { GAL_API_LOCK(); static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    out[0] = g_pso_hit; out[1] = g_pso_miss; out[2] = g_pso_build_ns * tb.numer / tb.denom; out[3] = g_pso_arch != nil || g_pso_arch3 != nil || g_pso_idx != nil; }   // g_pso_build_ns 累计的是 mach 时基，这里换成纳秒

// ---------- 内部辅助库后台预编（见 gal_internal.h GH_*）----------
static id<MTLLibrary> g_hlib[GH_N]; static NSError *g_herr[GH_N]; static dispatch_semaphore_t g_hsem[GH_N]; static int g_hdone[GH_N]; static _Atomic uint64_t g_hns[GH_N];
static NSString *helper_src(int k) { if (k == GH_TESS) return gal_tess_msl(); if (k >= GH_SMAA_EDGE) return gal_aa_msl(k - GH_SMAA_EDGE); NSString *const s[GH_TESS] = {k_restride_msl, k_idx_msl, k_dt_msl, k_clear_msl, k_present_msl, k_tex_msl}; return s[k]; }
static const char *const k_helper_name[GH_N] = {"顶点重排", "索引转换", "DrawTexture", "清屏", "出图", "贴图转换", "曲面细分器", "SMAA 边缘", "SMAA 权重", "SMAA 混合"};
// 离线辅助库（10-23 维护者：渲染器运行时现编内部辅助 MSL 违反「全量预编、首遇零延迟」，且走系统级函数编译缓存，负载下卡住 gate-host 门禁三次）：
//   辅助库源码由 gal_xc --helpers 导出、出库时 xcrun metal -std=metal4.0 编成 gal_helper_<键>.<源码哈希>.metallib（运行时缺省即 metal4.0 + 快速数学，两边一致）；
//   运行时按源码哈希找：NXGAL_HELPER_DIR → App 包 Resources/gal_helpers → 可执行文件旁 gal_helpers/ → libnxgal 旁 gal_helpers/。
//   找到就 newLibraryWithURL 载入（不编译）；找不到才现编，并计入 nxgal_helper_compiles（单测断言它为 0）。源码一改哈希就变，旧库自然不用
static const char *const k_helper_key[GH_N] = {"restride", "idx", "dt", "clear", "present", "tex", "tess", "smaa_edge", "smaa_blend", "smaa_neighbour"};
static _Atomic uint64_t g_hcompiles;
static NSString *helper_hash(int k) { return [NSString stringWithFormat:@"%016llx", (unsigned long long)gal_spv_hash(helper_src(k).UTF8String, (uint32_t)strlen(helper_src(k).UTF8String))]; }
static NSArray<NSString *> *helper_dirs(void) {
    static NSArray *dirs; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *a = [NSMutableArray array];
        const char *e = getenv("NXGAL_HELPER_DIR"); if (e && *e) [a addObject:@(e)];
        NSString *res = NSBundle.mainBundle.resourcePath; if (res) [a addObject:[res stringByAppendingPathComponent:@"gal_helpers"]];
        char exe[4096]; uint32_t n = sizeof exe; if (_NSGetExecutablePath(exe, &n) == 0) [a addObject:[[@(exe) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"gal_helpers"]];
        Dl_info di; if (dladdr((const void *)&gal_helper_lib, &di) && di.dli_fname) [a addObject:[[@(di.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"gal_helpers"]];
        dirs = a; });
    return dirs;
}
static NSString *helper_base(int k) { return [NSString stringWithFormat:@"gal_helper_%s.%@", k_helper_key[k], helper_hash(k)]; }
static id<MTLLibrary> helper_offline(int k) {
    NSString *f = [helper_base(k) stringByAppendingString:@".metallib"];
    const char *e = getenv("NXGAL_HELPER_DIR");
    NSString *explicit_dir = e && *e ? @(e) : nil;
    for (NSString *d in helper_dirs()) {
        // 自动搜索根是 Metal 4 产物；Metal 3 只取兼容子目录，不串用根目录。
        // NXGAL_HELPER_DIR 始终是调用方显式选好的目录，保留原样，不按名字猜后端。
        NSString *dir = gal_be_kind() == GAL_BE_MTL3 && ![d isEqualToString:explicit_dir]
                      ? [d stringByAppendingPathComponent:@"m3"] : d;
        NSString *p = [dir stringByAppendingPathComponent:f]; if (![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
        NSError *e = nil; id<MTLLibrary> lib = [g_gdev newLibraryWithURL:[NSURL fileURLWithPath:p] error:&e];
        if (lib) return lib;
        GLOG("【红】内部辅助库「%s」离线库载不进（%s）：%s", k_helper_name[k], p.fileSystemRepresentation, e.localizedDescription.UTF8String);
    }
    return nil;
}
NXGAL_API uint64_t nxgal_helper_compiles(void) { return g_hcompiles; }
// gal_xc --helpers 用：第 k 个辅助库的键与源码（k 越界返回空）
NXGAL_API const char *nxgal_helper_src(int32_t k, const char **base) {
    if (k < 0 || k >= GH_N) return NULL;
    static char b[GH_N][96]; if (base) { snprintf(b[k], sizeof b[k], "%s", helper_base(k).UTF8String); *base = b[k]; }
    return helper_src(k).UTF8String;
}
// 后台编一个辅助库（已开编的不重复）；gal_helper_lib 首用时等它。有离线库就当场载入、不编
void gal_helper_kick(int k) {
    if (g_hsem[k] || g_hdone[k]) return;
    uint64_t t0 = mach_absolute_time();
    id<MTLLibrary> off = helper_offline(k);
    if (off) { g_hlib[k] = off; g_hns[k] = mach_absolute_time() - t0; g_hdone[k] = 2; return; }
    g_hcompiles++;
    g_hsem[k] = dispatch_semaphore_create(0);
    [g_gdev newLibraryWithSource:helper_src(k) options:nil completionHandler:^(id<MTLLibrary> lib, NSError *err) {
        g_hlib[k] = lib; g_herr[k] = err; g_hns[k] = mach_absolute_time() - t0; dispatch_semaphore_signal(g_hsem[k]); }];
}
// 曲面与 AA 按需载入：默认关闭 AA 的游戏不付加载开销；曲面首个程序建出时再 kick（gal_prog.m）。
void gal_helpers_prewarm(void) { for (int k = 0; k < GH_TESS; k++) gal_helper_kick(k); }
id<MTLLibrary> gal_helper_lib(int k, NSError **e) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    if (!g_hdone[k]) {
        uint64_t t0 = mach_absolute_time();
        if (g_hsem[k]) dispatch_semaphore_wait(g_hsem[k], DISPATCH_TIME_FOREVER);
        else if ((g_hlib[k] = helper_offline(k))) { g_hns[k] = mach_absolute_time() - t0; g_hdone[k] = 2; }   // 没预编（单测等不经 nxgal_init 的路径）：先找离线库
        else { NSError *err = nil; g_hcompiles++; g_hlib[k] = [g_gdev newLibraryWithSource:helper_src(k) options:nil error:&err]; g_herr[k] = err; g_hns[k] = mach_absolute_time() - t0; }
        if (!g_hdone[k]) g_hdone[k] = 1;
        GLOG("内部辅助库「%s」：%s %.1f ms，首用时等 %.1f ms", k_helper_name[k], g_hdone[k] == 2 ? "离线库载入" : "现编", g_hns[k] * tb.numer / tb.denom / 1e6, (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6);
        g_hdone[k] = 1;
    } else if (g_hdone[k] == 2) {
        GLOG("内部辅助库「%s」：离线库载入 %.1f ms", k_helper_name[k], g_hns[k] * tb.numer / tb.denom / 1e6); g_hdone[k] = 1;
    }
    if (e) *e = g_herr[k];
    return g_hlib[k];
}

// 设备能力当场查询（能力表不按平台写死）：out[0] 位 = NXGAL_CAP_*，out[1] 计算着色器共享内存上限（字节），out[2] 建议工作集上限（字节，能力表 maximumGpuMemory）
static void dev_caps(uint64_t out[4]) {
    id<MTLDevice> d = g_gdev; memset(out, 0, 4 * sizeof *out); if (!d) return;
    int apple1 = [d supportsFamily:MTLGPUFamilyApple1], apple2 = [d supportsFamily:MTLGPUFamilyApple2];
    out[0] = (d.supportsBCTextureCompression ? NXGAL_CAP_BC : 0) | (apple2 ? NXGAL_CAP_ASTC : 0) | (apple1 ? NXGAL_CAP_ETC2 | NXGAL_CAP_PACKED16 : 0)
           | ([d supportsFamily:MTLGPUFamilyApple6] ? NXGAL_CAP_ASTC_HDR : 0);
    out[1] = d.maxThreadgroupMemoryLength; out[2] = d.recommendedMaxWorkingSetSize;
}
NXGAL_API void nxgal_device_caps(uint64_t out[4]) { GAL_API_LOCK(); dev_caps(out); }
NXGAL_API void nxgal_barrier(int kind) { GAL_API_LOCK();
    SW_SCOPE(SW_MEMBAR, 1);
    // 编码器之间已全序（enc_barrier）：结束当前编码器即满足 Barrier / CommandBufferBarrier 语义。
    // TextureBarrier（渲染目标写 → 之后采样）在 TBDR 上只有「之后的绘制采样当前通道的附件」才要拆通道（附件还在片上没存回）：
    // 渲染通道开着时只挂起，下次绘制前查这次绘制采样 / 绑图像的贴图是否与当前附件同一底层存储，是才拆（gal_pass_texbar_check）。
    // 动森进岛每帧 TextureBarrier 62 次，原先每次拆通道（附件整张存回再读入）
    // Barrier / CommandBufferBarrier（帧率能耗线 10-21；NXGAL_BARRIER_SPLIT=1 退回旧做法：一律拆遍）：同 Ryujinx Vulkan 后端 BarrierBatch.FlushMemoryBarrier，
    // 只有屏障前后有存储写（存储缓冲可写 / 图像）时才真要下发。渲染通道开着时只挂起，下次绘制前看本遍已有 / 这次绘制的存储写再定拆不拆（gal_pass_membar_split）；
    // 遍外的写（计算派发、拷贝）与本遍之间本来就隔着编码器全序屏障。马车8 每帧约 1 次，原先每次拆遍
    // Metal 3 同一套判定：渲染编码器的 memoryBarrierWithScope 在 iOS 上不可用（SDK 标 API_UNAVAILABLE(ios)），遍内要屏障时照样拆遍（gal_pass_membar_split），
    // 拆开的两个编码器之间由栅栏 g_fence3 排序
    int k; gal_cur_enc(&k);
    if (kind >= 2 && k == 1) { gal_pass_texbar_arm(); return; }
    static int split = -1; if (split < 0) { const char *v = getenv("NXGAL_BARRIER_SPLIT"); split = v && *v == '1'; }
    if (k == 1 && !split) { gal_pass_membar_arm(); return; }
    gal_enc_end();
}
NXGAL_API void nxgal_flush(void) { GAL_API_LOCK(); SW_SCOPE(SW_COMMIT, 3); g_cwhy = 7; gal_commit(); }

NXGAL_API int nxgal_init(int debug_level) { GAL_API_LOCK();
    atomic_store(&g_archive_stopping, 0); atomic_store(&g_dev_sched, 0);
    (void)debug_level;
    void gal_present_begin_session(void); gal_present_begin_session();
    if (g_gdev) return 0;
    // 选后端（gal_be.h 表中「选路径」）：26 起缺省 Metal 4 主路径；26 以下走 Metal 3 兼容路径（下限 macOS 15 / iOS 18，驻留集与老队列挂接要到那时才有）；
    // 26 上用 NXGAL_BE=mtl3 强制走 Metal 3（A/B 用，缺省关）。Metal 4 专有对象只在选到 GAL_BE_MTL4 时建，老系统上不碰。
    int compat = 0;
    g_gal_be = gal_be_select(&compat);
    if (g_gal_be == GAL_BE_NONE) { GLOG("【红】系统低于 macOS 15 / iOS 18：驻留集与老队列挂接没有，Metal 3 兼容路径也做不了，渲染器不可用"); return -2; }
    if (g_gal_be == GAL_BE_MTL3) {
        GLOG("后端：Metal 3（%s）", compat ? "兼容" : "强制");
        // 临时闸（见文件头 GAL_M3_RUNTIME_READY）：Metal 3 运行时合齐前，26 以下缺省不启用，直接报红退出；NXGAL_M3_RUNTIME=1 放行（提前验初始化 / 后续卡）
        if (compat && !m3_runtime_enabled()) { GLOG("【红】Metal 3 运行时（提交 / 编码器 / 参数绑定 / 管线编译）尚未合齐：26 以下系统暂不支持（NXGAL_M3_RUNTIME=1 可放行试验）"); return -2; }
        if (compat) GLOG("【注】Metal 3 运行时尚未合齐、NXGAL_M3_RUNTIME=1 放行：本版在老系统上只完成初始化，绘制会失败");
    }
    { void gal_state_init(void); gal_state_init(); }
    @autoreleasepool {
        s2a_mtl_slot_take("nxgal_init");   // 全机 Metal 客户进程名额（mtl_slot.h）：建设备前拿，持有到进程退出
        g_gdev = MTLCreateSystemDefaultDevice(); if (!g_gdev) { GLOG("【红】没有 Metal 设备"); return -1; }
        fprintf(stderr, "[画] 满屏判据 已开\n");   // 测试契约 §4：画面格的满屏项靠这行判「已测」（判据本体在 gal_present.m，常开）
        NSError *e = nil;
        // 驻留集两边共用（macOS 15 / iOS 18 起）：Metal 4 挂 MTL4CommandQueue，Metal 3 用 addResidencySet 挂普通 MTLCommandQueue（gal_be.h 表中「驻留」）
        MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; rd.initialCapacity = 4096;
        g_gres = [g_gdev newResidencySetWithDescriptor:rd error:&e]; if (!g_gres) { GLOG("【红】建驻留集失败"); return -1; }
        if (g_gal_be == GAL_BE_MTL4) {
            g_gq = [g_gdev newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&e];
            if (!g_gq) { GLOG("【红】建 MTL4CommandQueue 失败：%s", e.localizedDescription.UTF8String); return -1; }
            [g_gq addResidencySet:g_gres];
        } else {
            // Metal 3 兼容路径：普通 MTLCommandQueue + 同一个驻留集挂老队列。图层上的 residencySet 是 26 才有的，老路径不用（上屏由出图命令缓冲管）
            g_cq3 = [g_gdev newCommandQueue];
            if (!g_cq3) { GLOG("【红】建 MTLCommandQueue（Metal 3 兼容路径）失败"); return -1; }
            [g_cq3 addResidencySet:g_gres];
        }
        g_bgq = [g_gdev newCommandQueue]; if (!g_bgq) { GLOG("【红】建后台读回队列失败"); return -1; }
        [g_bgq addResidencySet:g_gres];
        if (g_gal_be == GAL_BE_MTL4) {
            for (int i = 0; i < GAL_NALLOC; i++) {
                g_galloc[i] = ca_new();
                g_palloc[i] = ca_new();
                if (!g_galloc[i] || !g_palloc[i]) { GLOG("【红】建命令分配器失败"); return -1; }
            }
            MTL4CompilerDescriptor *cd = [MTL4CompilerDescriptor new];
            pso_cache_init(cd);
            g_gcomp = [g_gdev newCompilerWithDescriptor:cd error:&e];
            if (!g_gcomp) { GLOG("【红】建 MTL4Compiler 失败：%s", e.localizedDescription.UTF8String); return -1; }
        } else pso_cache_init3();
        g_gev = [g_gdev newSharedEvent];
        g_bgev = [g_gdev newSharedEvent];
        { pthread_t th; if (pthread_create(&th, NULL, keepres_main, NULL) == 0) pthread_detach(th); else GLOG("【红】空闲保驻留：起线程失败"); }
        { const char *v = getenv("NXGAL_PERF_TIME"); g_gp_time = v && *v == '1'; }
        gal_helpers_prewarm();
        { void gal_thrcpu_start(void); gal_thrcpu_start(); }   // 诊断 S2A_THR_CPU=<秒>（gal_thrcpu.m），缺省关
        thermal_start();   // 热状态记录（初始化 / 每 10 秒 / 变化）
        { uint64_t c[4]; dev_caps(c);
          GLOG("初始化：设备 %s；能力（MTLDevice 当场查询）：BC 压缩贴图 %s，ASTC %s（HDR %s），ETC2 %s，16 位紧凑格式 %s，计算共享内存 %llu KB，建议工作集 %.2f GB",
               g_gdev.name.UTF8String, c[0] & NXGAL_CAP_BC ? "原生支持" : "不支持", c[0] & NXGAL_CAP_ASTC ? "支持" : "不支持", c[0] & NXGAL_CAP_ASTC_HDR ? "支持" : "不支持",
               c[0] & NXGAL_CAP_ETC2 ? "支持" : "不支持", c[0] & NXGAL_CAP_PACKED16 ? "支持" : "不支持", (unsigned long long)(c[1] >> 10), c[2] / 1073741824.0); }
    }
    return 0;
}
NXGAL_API void nxgal_request_stop(void) {
    void gal_present_request_stop(void); gal_present_request_stop();
    pthread_mutex_lock(&g_hold_mu); g_hold = 0; pthread_cond_broadcast(&g_hold_cv); pthread_mutex_unlock(&g_hold_mu);
}
NXGAL_API int nxgal_shutdown_session(void) { GAL_API_LOCK();
    nxgal_request_stop();
    if (!g_gdev) return 0;
    // Invalidate old delayed retries/debounce writes. Immutable descriptors
    // remain owned by their blocks, but may no longer enqueue work for this run.
    atomic_store(&g_archive_stopping, 1); atomic_fetch_add(&g_archive_epoch, 1);
    uint64_t fence = gal_commit();
    if (!gal_wait_fence_timeout(fence, 10000)) { GLOG("【红】重启：GAL GPU 栅栏未完成"); return -ETIMEDOUT; }
    uint64_t until = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 10000000000ull;
    while (atomic_load(&g_session_feedback) || atomic_load(&g_pso_inflight)) {
        if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= until) { GLOG("【红】重启：GAL 完成回调/管线作业未完成"); return -ETIMEDOUT; }
        usleep(1000);
    }
    // Metal 3 completion leaves its capture group after decrementing inflight.
    // Keep session owners alive until that final capture has also finished.
    if (g_dev3_active && dispatch_group_wait(g_dev_async3, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        GLOG("【红】重启：Metal 3 归档收录回调未完成"); return -ETIMEDOUT;
    }
    int gal_present_shutdown_session(void); int gal_prog_drain_session(void); int gal_prog_reset_session(void);
    int e = gal_present_shutdown_session(); if (e) return e;
    e = gal_prog_drain_session(); if (e) return e;
    if (g_bgc_q) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_barrier_async(g_bgc_q, ^{ dispatch_semaphore_signal(done); });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) return -ETIMEDOUT;
    }
    dispatch_queue_t flushQueue = g_dev_q ?: dispatch_queue_create("s2a.gal.session.flush", DISPATCH_QUEUE_SERIAL);
    atomic_store(&g_pso_write_error, 0);
    dispatch_async(flushQueue, ^{ @autoreleasepool { gal_pso_cache_flush(); } });
    // The normal M3 flush blocks synchronously. Shutdown instead queues the
    // same write and includes it in the bounded drain below.
    if (g_dev3_active) dispatch_async(g_dev_q, ^{ @autoreleasepool { dev_write3("会话结束"); } });
    else gal_pso_dev_flush("会话结束");
    {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(flushQueue, ^{ dispatch_semaphore_signal(done); });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) return -ETIMEDOUT;
    }
    if (atomic_load(&g_archive_write_error) || atomic_load(&g_pso_write_error)) return -EIO;
    e = gal_prog_reset_session(); if (e) return e;
    dead_reap();
    void gal_pass_reset_session(void); void gal_draw_reset_session(void);
    void gal_buf_reset_session(void); void gal_tex_reset_session(void); void gal_cnt_reset_session(void); void gal_state_init(void);
    gal_pass_reset_session(); gal_draw_reset_session();
    gal_cnt_reset_session(); gal_tex_reset_session(); gal_buf_reset_session();
    dead_reap(); gal_state_init();
    pthread_mutex_lock(&g_sync_mu); free(g_sync); g_sync = NULL; g_nsync = g_capsync = g_sync_pending = 0; pthread_mutex_unlock(&g_sync_mu);
    g_cb_thread_set = 0; g_gp_frame = 0; g_gp_commit_present = 0;
    return 0;
}
NXGAL_API void nxgal_shutdown(void) { int e = nxgal_shutdown_session(); if (e) GLOG("【红】GAL 会话释放失败 (%d)", e); }
// 单测钩子（graphics/metal/tests/t_m3enc.m）：Metal 3 编码器读数。out[]：0 当前编码器类型（1 渲染 2 blit 3 计算），1 blit 拆编码器次数，
// 2–5 因参数绑定未合入跳过的 绘制 / 派发 / 遍内清屏 / 辅助绘制，6 栅栏已建，7 Metal 3 预载缓冲在录
NXGAL_API void nxgal_test_m3enc(uint64_t out[8]) {
    out[0] = (uint64_t)g_genc_kind; out[1] = g_m3_split; for (int i = 0; i < 4; i++) out[2 + i] = g_m3_skip[i]; out[6] = g_fence3 != nil; out[7] = g_pcb3 != nil;
}
// 单测钩子：Metal 3 计算编码器本体（派发要参数绑定，M3-7 合入前 gal_cmp_enc 报红返回 nil）——取 cmp_enc3 直接录 setBuffer 绑定的派发，
// 核编码器开 / 收、栅栏与编码器内屏障。Metal 4 路径返回 nil
NXGAL_API id nxgal_test_m3_cmp_enc(void) { return g_gal_be == GAL_BE_MTL3 ? cmp_enc3() : nil; }
// 单测钩子（graphics/metal/tests/t_m3be.c）：这次初始化选的后端与建出来的对象。out[]：0 = gal_be_kind()，1 = Metal 3 主队列已建，2 = Metal 4 主队列已建，
// 3 = 驻留集已建，4 = Metal 4 编译器已建（Metal 3 路径下不该建）
NXGAL_API void nxgal_test_be(int32_t out[5]) {
    out[0] = gal_be_kind(); out[1] = g_cq3 != nil; out[2] = g_gq != nil; out[3] = g_gres != nil; out[4] = g_gcomp != nil;
}
GAL_MTL4_ZONE_END
