// 帧率表（10-26，体系提升方案 D「60 帧一律放开」）：按主程序构建号放开游戏的帧率上限。位置和改法取自社区资料（FPSLocker-Warehouse 等）指出的事实，
//   我方原生实现、实跑核过；补丁原文不进包、不进仓库。
// 表：<模块目录>/fps.tsv（出包按构建号从仓库 runtime/fps/<主程序构建号>.tsv 拷进来）；S2A_FPS_TABLE=<路径> 覆盖。
// 开关（维护者 10-27：60 帧缺省打进包，宿主设置里启停，关掉回原帧率）：起局时 S2A_FPS60=0 为关、否则开（帧率上限 S2A_FPS 不管本表）；运行中 s2a_fps_set_enabled 热切（设置页调）。
//   表不管开关都读：改写器打进代码的读槽指令一直在，槽必须有值（关时写 30 帧口径：速度槽 1.0、slot 行的关时值），否则游戏读到 0（塞尔达速度 0 冻住）。
//   关时：w 行写回首次读到的原值（起局就关则一处不写）；present display 只在起局开时设（起局关不设，L1 交换间隔按游戏），运行中关由 s2a_fps_present_hook 返回 1 退回游戏自己设的间隔；
//   word 改指令行已打进代码、改不回（日志黄一行）。
// 行（# 起注释）：
//   build <主程序构建号前 16 位>      与 s2a_main_build_id 不符整表不用（报红：表配错款 / 版本）
//   present display                  出图不按游戏设的间隔、每个显示节拍一帧（同 DM_PRESENT_INTERVAL=display，hle_nvn.c；只在没显式给时设）
//   w <模块> <偏移> i32|f32 <值> [*<偏移2>]   游戏数据区的值，装载后每 100 ms 写一次（游戏自己会改回的变量，如巫师3 的 LimitFPS）；只许写数据段。
//                                    带 *<偏移2>：<模块>+<偏移> 处是指针（游戏堆里的对象，如虚幻 4 控制台变量），写到「指针 + 偏移2」；指针为空（还没初始化）就等下一轮，
//                                    读写都走 vm_read_overwrite / vm_write（地址无效只返回错误，不崩）
//   w … if <模块> <偏移> u8|i32 ==|!= <值>   按条件写：每轮先读条件地址（数据段），条件成立才写这一条（如异度3：过场标志 ≠ 0 时切回 30 帧口径的那几条）
//   slot <槽> f32|i32 <值> [<关时值>]  主程序键页槽的值（改写器 c 行里 ldr_slot / bl_rec 用的槽，2032–2047）：开时写值、关时写关时值（缺省同值），开关一变写一次
//   speed <槽> <最小> <最大>           动态步长：游戏每次提交出图时，按真实帧间隔 ÷ (1/30 秒) 写进槽（f32），夹在 [最小, 最大]；
//                                    60 帧 0.5、掉到 30 帧自动回 1.0（塞尔达这类按帧推进的款，游戏速度函数改读这个槽）
//   speed <槽> <最小> <最大> <秒槽>    同上，另把同一步长换成秒（÷ 30）写进秒槽（关时 1/30）：游戏按 {倍率 / 30, 倍率} 写死一对时钟的地方（王国之泪布料 / 头发）改读这两槽
//   present30 if slot <槽> ==|!= <值>  条件成立时出图间隔退回游戏自己设的（如塞尔达预渲染过场要按 30 帧放）
//   c …                              改指令行（出包时由改写器读，runtime/rewriter），这里跳过
// 首次写入时日志记原值（核位置对不对：原值应是游戏的 30 帧口径）
// 随包表：fps.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单）
#include "native.h"
#include "s2a_unattended.h"
#include <errno.h>
static _Thread_local FILE *g_boot_file;
void s2a_fps_abort_boot_inputs(void) {
    FILE *file = g_boot_file; g_boot_file = NULL;
    if (file && fclose(file)) LOG("【红】失败装载的帧率表关闭失败 errno=%d", errno);
}
#include "../../platform/plat.h"
#include <unistd.h>
#include <stdatomic.h>
typedef struct { module_t *m; uint64_t off, off2, ch[6]; int f32, deref, nch, said, has_orig, has_off; uint32_t bits, orig, offbits; char what[48];   // ch：多级指针链（deref 时 <模块>+off 处是指针，前 nch−1 级再各取一次指针，最后一级 off2 = ch[nch−1] 是写入偏移）
                 module_t *cm; uint64_t coff; int csz, ceq; int32_t cval; } fps_w;   // cm：条件地址的模块（NULL = 无条件）；csz 1 / 4 字节；ceq 1 = 「==」0 = 「!=」
static fps_w g_fw[32]; static int g_nfw;
static module_t *g_fm;   // 主程序模块（键页槽所在）
static int g_spd_slot = -1, g_spd_sec = -1, g_p30_slot = -1, g_p30_eq; static float g_spd_lo, g_spd_hi; static int32_t g_p30_val;
static uint64_t g_present_last;
static uint8_t *g_key_rw;   // 按模块下标，g_mod_cap 项（第一次用时分配，会话复位释放）
// The loader and late display configuration may both request a writer. This
// lock owns creation/publication and join; the writer itself never takes it.
static pthread_mutex_t g_writer_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_writer_started, g_writer_closed, g_writer_admit, g_writer_error;
static pthread_t g_writer;
static _Atomic int g_writer_stop;
static int g_default_present;
static pthread_mutex_t g_control_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_ready;
// Called with writer_mu held, after the complete table has been published.
static void controls_ready(void) {
    pthread_mutex_lock(&g_control_mu); g_ready = 1; pthread_mutex_unlock(&g_control_mu);
    g_writer_admit = 1;
}
static void *key_slot(int slot) { return g_fm ? g_fm->base + g_fm->key_page_off + (uint64_t)slot * 8 : NULL; }
// 键页槽与帧步页（g_fs_page）是宿主自己的页，不是游戏数据：键页在安卓不进共享背板（android/native/module.c 映射时排除 text / 键页 / 补丁区），
//   帧步页是本文件的静态数组。两者都不能走 plat_guest_store32——安卓那条走客体 VM 的 checked 写（fps_provider.c），私有页 / 窗口外地址写不进就报红中止。
//   苹果 plat_guest_store32 本来就是这一句原子存，行为不变（#48 D2）
static void host_store32(void *p, uint32_t v) { __atomic_store_n((uint32_t *)p, v, __ATOMIC_RELAXED); }
// 起局开关只认 S2A_FPS60：S2A_FPS 是帧率上限（出图封顶，graphics/nvn nvn_fps.c、通用层 FramePacingPolicy），和游戏逻辑步长的 60 帧表是两件事
//   （#619 审计 F-fps-cap-disables-table：原先 S2A_FPS=30 也算关，设置页上限选 30、60 帧开关留开时起局仍按关写表）
// 11-11 维护者：出包默认就是游戏原本的帧率，60 帧改成玩家手动开——只有 S2A_FPS60=1（设置页 / 启动器按款开了）才开；没设或 0 一律回游戏原生帧率
static int fps_on_at_start(void) { const char *f = getenv("S2A_FPS60"); return f && !strcmp(f, "1"); }
static _Atomic int g_on = 1, g_have;   // g_on：60 帧开 / 关（运行中可切）；g_have：这款有表（设置页据此决定显不显示开关）
// 不按发热 / 低电量自动关 60 帧（11-13 维护者「不读电量、不设自己挡自己的闸」「不许堵门」）：玩家自己开的 60 帧不替他关，真热到系统降频是系统的事；
//   原先热状态危急或低电量模式开着就按关生效（审计 P1-80 / 情报 10-28 的降档原因 1 / 2），整段删了，帧率跟不跟得上交给实际帧率（宿主帧步、档位梯子按实测帧率）
// 3 = 逻辑速度同局 A/B 正在测原帧率那一段（自动玩家 tests/autoplay/autoplay.c speed_ab 调 s2a_fps_ab_set）：同档位梯子压回一条路生效——
//   帧率表 w 行写回原值、槽写关时值、出图间隔退回游戏自己设的（hle_nvn.c 看 s2a_fps_cap_reason）、社区帧率补丁跟随，所以测到的「关」就是玩家关 60 帧时的样子
static _Atomic int g_ab;   // 同局 A/B 阶段：0 照常、1 回原帧率、2 放开（普查 A/B 模式下给「60 帧没开」的款测开段用）
// 普查同局 A/B 模式（S2A_FPS_AB=1，tools/census 设，同时设 DM_PRESENT_INTERVAL=display）：60 帧没开的款（包内能力 fps60=0：没来源 / 强信号）
//   整局照原帧率跑（降档原因 3），普查五问读数不变；只在自动玩家测开段时放开（阶段 2）。60 帧开着的款不受影响
static int ab_mode(void) { const char *e = getenv("S2A_FPS_AB"); return e && !strcmp(e, "1"); }   // 每次读：单测中途设；每帧一次 getenv 不贵
// 档位梯子压回原生帧率（runtime/src/qladder.c，维护者 11-06 优雅降级）：60 帧开着、按档位暂时退回游戏原帧率，放开就回 60（与降档原因同一条热切路径，不动用户开关）
static _Atomic int g_hold;
static int eff(void) { return atomic_load(&g_on) && atomic_load(&g_ab) != 1 && !atomic_load(&g_hold); }   // 60 帧实际生效 = 用户开着、不在同局 A/B 的原帧率段、档位梯子没压
int s2a_fps_cap_reason(void) {
    int ab = atomic_load(&g_ab);
    if (ab == 1 || (ab != 2 && ab_mode() && !fps_on_at_start())) return 3;
    return atomic_load(&g_hold) ? 4 : 0;   // 4 = 档位梯子压回原帧率（s2a_fps_hold）；1 / 2（热 / 低电量）11-13 起不再有
}
// 运行中关 60 帧（玩家点「切回原生帧率」、档位梯子压回）能不能真退回原帧率：表里每条 w 行都写了关值才能（槽 / 速度 / 出图间隔本来就能热切）。
//   0 = 有 w 行没关值：运行中关只退出图间隔与槽，游戏自己的限帧变量留在 60 帧口径，要重启（下一局表从起局就关、游戏的值没人碰）才完全回原帧率。体验线提示据此写「重启后生效」
int s2a_fps_hot_revert_ok(void) { for (int i = 0; i < g_nfw; i++) if (!g_fw[i].has_off) return 0; return 1; }
int s2a_fps_effective(void) { return eff(); }   // 60 帧此刻真在生效（撑不住就问玩家 runtime/src/qprompt_host.c 逐帧读）
static struct { int sl; uint32_t on, off; } g_sl[16]; static int g_nsl, g_word_rows, g_present_row;   // g_present_row：表里有 present display
static void spd_store(float v) {   // 步长槽（30 帧为 1）与秒槽（÷ 30）同写
    host_store32(key_slot(g_spd_slot), *(uint32_t *)&v);
    if (g_spd_sec >= 0) { float sec = v / 30.0f; host_store32(key_slot(g_spd_sec), *(uint32_t *)&sec); }
}
static void slots_apply(int on) {   // 槽按开关写：slot 行开 / 关时值；速度槽关时固定 1.0（开时由钩子按帧间隔写）
    for (int i = 0; i < g_nsl; i++) host_store32(key_slot(g_sl[i].sl), on ? g_sl[i].on : g_sl[i].off);
    if (g_spd_slot >= 0 && !on) spd_store(1.0f);
}
// 社区帧率补丁（直连线 cpatch，双路 + 键页槽 2046 掩码）跟着同一个「60 帧开」走：开关一变（起局一次 + 运行中每次切）通知 cpatch 把帧率类那几位写成对应值。
//   弱定义缺省空实现 / 0 份：cpatch 运行时给强定义就覆盖（静态链接选强定义）。维护者 10-27：设置里一个开关管 60 帧
__attribute__((weak)) void s2a_cpatch_fps_follow(int on) { (void)on; }
__attribute__((weak)) int s2a_cpatch_fps_count(void) { return 0; }   // 本包收下的社区帧率补丁份数（设置页据此也显示开关）
static void cpatch_follow(int on) { s2a_cpatch_fps_follow(on); }
// 宿主帧步（10-29 维护者，调研 the reference port FRAME_STEP：维护者「高帧率时同时低功耗，而不是高帧率高功耗这个能力就不给玩家了」）：表里有 speed 行（按帧推进、游戏速度改读步长槽的款）
//   就把直连宿主的帧步状态页接上（graphics/nvn hle_nvn.c fstep_tick + nvn_fstep.h：每帧定「这一帧在屏上保持几个 vsync」，60 撑不住连续 3 帧迟到就稳定落到 30，
//   合身 30 帧再试 60，迟到的时间按每帧多 1 vsync 补回，游戏时间 = 真实时间），出图按它保持整数个 vsync（不再 32–45 帧来回抖、GPU 一直满跑）。
//   页布局（graphics/nvn/host/hle.h dm_fps_state）：+0 f32 目标帧率（0 = 帧步关）、+4 过场标记（1 = 按 30）、+0x20 宿主给下一帧的步长（vsync 数）。
//   步长槽改读 +0x20：步长 × 1/60 秒 ÷ 1/30 秒 = 步长 × 0.5（保持 1 → 0.5、2 → 1.0、补欠账时 +0.5）；通用模式没有帧步（+0x20 恒 0）照旧按真实帧间隔算。
//   S2A_FSTEP=0 不接（对照局）。强定义覆盖 hle_nvn.c 的弱定义
uint8_t *dm_fps_state;
static uint8_t g_fs_page[4096] __attribute__((aligned(16)));
static void fs_target(int on) {
    if (!dm_fps_state) return;
    float t = on ? 60.0f : 0.0f; uint32_t b; memcpy(&b, &t, 4); host_store32(dm_fps_state, b);
}
static int fs_step(void) { return dm_fps_state ? (int)plat_guest_load32((uintptr_t)(dm_fps_state + 0x20)) : 0; }
// 生效状态一变（用户开关或降档原因）：槽与社区帧率补丁按生效值写；w 行由写入线程每 100 ms 按 eff() 写
static void apply(void) { int e = eff(); slots_apply(e); cpatch_follow(e); fs_target(e); }
// 帧率表键页槽的当前值（graphics/nvn hle_nvn.c 每 300 帧「render targets」那行带出；11-02 塞尔达户外落 30 看动态分辨率系数 / 步长）：「2041=200 (0x43480000)」；类型表里没记，浮点与原始字都给
void s2a_fps_slots_note(char *buf, size_t n) {
    size_t o = 0; buf[0] = 0; if (!g_fm) return;
    for (int i = 0; i < g_nsl + (g_spd_slot >= 0) && o + 48 < n; i++) {
        int sl = i < g_nsl ? g_sl[i].sl : g_spd_slot; uint32_t v = plat_guest_load32((uintptr_t)key_slot(sl)); float f; memcpy(&f, &v, 4);
        o += (size_t)snprintf(buf + o, n - o, "%s%d=%g (%#x)", o ? ", " : "", sl, (double)f, v); }
}
// 档位梯子压回 / 恢复告诉玩家（ios/app.m 横幅「已暂时回到原生帧率」，runtime/src/qladder_host.c 调）。Mac / 单测没有界面
__attribute__((weak)) void s2a_ios_fps_capped(int reason) { (void)reason; }
// 同局 A/B（自动玩家调，任意线程）：phase 1 = 回原帧率（降档原因 3）、2 = 放开（开段）、0 = 照常（测完）。不改用户开关，只在自动化局里用。
//   没有帧率表的款（出图间隔由引擎推导或 DM_PRESENT_INTERVAL=display 放开）g_ready = 0，只靠降档原因让 hle_nvn.c 退回 / 放开游戏间隔
void s2a_fps_ab_set(int phase) {
    if (phase < 0 || phase > 2 || atomic_exchange(&g_ab, phase) == phase) return;
    pthread_mutex_lock(&g_control_mu); if (g_ready) apply(); pthread_mutex_unlock(&g_control_mu);
    LOG("帧率表：逻辑速度同局 A/B %s", phase == 1 ? "回游戏原帧率（降档原因 3）" : phase == 2 ? "放开（测开段）" : "测完，回到照常");
}
int s2a_fps_available(void) { return atomic_load(&g_have) || s2a_cpatch_fps_count() > 0; }
// 有能真改游戏帧率的来源：表里除 present display 外还有行（w / slot / speed / word 改指令），或社区帧率补丁。只有 present display（含引擎通用第一层）时，
//   游戏自己设交换间隔 1 就已是 60 帧、没东西可放开（撑不住就问玩家 / 设置页「本款原生 60 帧」，runtime/src/qprompt_host.c）
int s2a_fps_real_source(void) { return (atomic_load(&g_have) && (g_nfw > 0 || g_nsl > 0 || g_spd_slot >= 0 || g_word_rows > 0)) || s2a_cpatch_fps_count() > 0; }
int s2a_fps_enabled(void) { return atomic_load(&g_on); }
int s2a_fps_live(void) { return eff(); }   // 60 帧此刻真在生效（用户开 + 无降档 + 梯子没压）
void s2a_fps_hold(int hold) {
    pthread_mutex_lock(&g_control_mu);
    if (atomic_exchange(&g_hold, hold ? 1 : 0) != (hold ? 1 : 0)) { if (g_ready) apply(); LOG("帧率表：档位梯子%s", hold ? "压回游戏原帧率" : "放开，回 60 帧"); }
    pthread_mutex_unlock(&g_control_mu);
}
void s2a_fps_set_enabled(int on) {
    pthread_mutex_lock(&g_control_mu);
    on = !!on;
    if (!g_ready || atomic_exchange(&g_on, on) == on) { pthread_mutex_unlock(&g_control_mu); return; }
    apply();
    const char *pi = getenv("DM_PRESENT_INTERVAL"); int itv_off = on && g_present_row && !(pi && !strcmp(pi, "display"));
    LOG("帧率表：60 帧%s（运行中切换）%s%s", on ? "开" : "关，回游戏原生帧率", !on && g_word_rows ? "；【黄】改指令 word 行出包时已打进代码，关时保留" : "",
        itv_off ? "；【黄】起局时 60 帧关、出图间隔没放开，这一局仍按游戏间隔出图（重开局生效）" : "");
    pthread_mutex_unlock(&g_control_mu);
}
static module_t *mod_named(const char *n) { for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, n)) return &g_mod[i]; return NULL; }
// 原值按地址只记一次（同一地址可有多条互斥的条件行；后读到的那条读的是前一条写进去的值，不是游戏原值）
static void note_orig(fps_w *w, uint32_t old) {
    for (int j = 0; j < g_nfw; j++) { fps_w *o = &g_fw[j];
        if (o != w && o->has_orig && o->m == w->m && o->off == w->off && o->deref == w->deref && o->nch == w->nch && !memcmp(o->ch, w->ch, sizeof o->ch)) { w->orig = o->orig; w->has_orig = 1; return; } }
    w->orig = old; w->has_orig = 1;
}
static void *writer(void *a) { s2a_thread_name("s2a-fps-writer");
    (void)a; (void)plat_thread_name("s2a-帧率表");
    // 诊断（S2A_FPS_HOLD_AT=<起秒>-<止秒>，写入线程起来后计秒）：这段时间按档位梯子压回原帧率，验 60 ↔ 原帧率局中双向热切（frames.tsv 看帧间隔）
    long ha = -1, hb = -1; { const char *e = getenv("S2A_FPS_HOLD_AT"); if (e && sscanf(e, "%ld-%ld", &ha, &hb) != 2) ha = hb = -1; }
    for (unsigned k = 0; !atomic_load(&g_writer_stop); k++) {
        if (ha >= 0 && k % 10 == 0) { long sec = (long)(k / 10); if (sec == ha) s2a_fps_hold(1); else if (sec == hb) s2a_fps_hold(0); }
        int on = eff();
        for (int i = 0; i < g_nfw; i++) { fps_w *w = &g_fw[i]; uint32_t old;
            // 关时只写表里明写的关值（off）。不写回第一次读到的「原值」（11-02 原生崩溃线：那是游戏还没初始化时的快照——八方2 t.MaxFPS 0、
            //   巫师3 LimitFPS 0、怪猎上限 6000，写回去等于解除限帧；异度3 写回 −1 也退不回 30）。没有关值的行运行中关不了，重启后生效（s2a_fps_hot_revert_ok）
            if (!on && (!w->has_orig || !w->has_off)) continue;   // 起局就关（开时从没写过）：游戏自己的值没人动过，不碰
            uint32_t want = on ? w->bits : w->offbits;
            // 条件只管开时写哪个值；关值无条件
            if (on && w->cm) { const void *cp = w->cm->base + w->coff;
                int32_t cv = w->csz == 1 ? (int32_t)plat_guest_load8((uintptr_t)cp) : (int32_t)plat_guest_load32((uintptr_t)cp);
                if ((cv == w->cval) != w->ceq) continue; }
            if (w->deref) {   // 指针那一格在模块数据段（装载时核过）；目标在游戏堆，安全拷贝读写
                uint64_t ptr = plat_guest_load64((uintptr_t)(w->m->base + w->off)); int ok = 1;
                for (int j = 0; ok && j < w->nch - 1; j++) {   // 中间各级：ptr + ch[j] 处再取一个指针（游戏堆，按两次 32 位安全读）
                    uint32_t lo, hi; ok = ptr && ptr + w->ch[j] >= ptr && !plat_mem_read32(ptr + w->ch[j], &lo) && !plat_mem_read32(ptr + w->ch[j] + 4, &hi);
                    if (ok) ptr = (uint64_t)hi << 32 | lo; }
                if (!ok || !ptr || ptr + w->off2 < ptr || plat_mem_read32(ptr + w->off2, &old)) continue;
                if (!w->said) { float of; memcpy(&of, &old, 4); w->said = 1; note_orig(w, old);
                    LOG("帧率表：*(%s+%#llx)+%#llx（%s）原值 %s %g", w->m->name, (unsigned long long)w->off, (unsigned long long)w->off2, w->what, w->f32 ? "f32" : "i32", w->f32 ? (double)of : (double)(int32_t)old); }
                if (old != want && plat_mem_write32(ptr + w->off2, want) && w->said == 1) {
                    w->said = 2; LOG("【红】帧率表：*(%s+%#llx)+%#llx 写不进（目标页不可写）", w->m->name, (unsigned long long)w->off, (unsigned long long)w->off2); }
                continue; }
            uint32_t *p = (uint32_t *)(void *)(w->m->base + w->off); old = plat_guest_load32((uintptr_t)p);
            if (!w->said) { float of; memcpy(&of, &old, 4); w->said = 1; note_orig(w, old); LOG("帧率表：%s+%#llx（%s）原值 %s %g", w->m->name, (unsigned long long)w->off, w->what, w->f32 ? "f32" : "i32",
                                                                        w->f32 ? (double)of : (double)(int32_t)old); }
            if (old != want) plat_guest_store32((uintptr_t)p, want); }
        usleep(100000);
    }
    return NULL;
}
// 游戏每次提交出图时调（graphics/nvn hle_nvn.c present_period，游戏线程）：动态步长写槽；返回 1 = 这一帧出图间隔退回游戏自己设的（present30 条件成立）
//   两帧间隔 > 1 秒（读档、暂停、切后台）不更新：那一帧不是游戏帧，按它算的步长会让游戏猛跳一下
int s2a_fps_present_at(uint64_t now);   // 核心按传入的时间算（单测传精确时间戳）
int s2a_fps_present_hook(void) { return s2a_fps_present_at(plat_now_ns()); }
int s2a_fps_present_at(uint64_t now) {
    // 关着时也记，再开的第一帧按真实帧间隔算；换局时清零。
    if (!eff()) { g_present_last = now; return atomic_load(&g_have); }
    if (g_spd_slot >= 0) {
        int st = fs_step();
        if (st > 0) {   // 帧步在跑：步长是宿主定的整数 vsync，出图也按它保持
            float v = st * 0.5f; if (v < g_spd_lo) v = g_spd_lo; if (v > g_spd_hi) v = g_spd_hi;
            spd_store(v);
        } else if (g_present_last && now - g_present_last < 1000000000ull) {
            float v = (float)((double)(now - g_present_last) / (1e9 / 30.0)); if (v < g_spd_lo) v = g_spd_lo; if (v > g_spd_hi) v = g_spd_hi;
            spd_store(v); }
    }
    g_present_last = now;
    if (g_p30_slot >= 0) {
        int32_t cv = (int32_t)plat_guest_load32((uintptr_t)key_slot(g_p30_slot)); int p30 = (cv == g_p30_val) == g_p30_eq;
        if (dm_fps_state) host_store32(dm_fps_state + 4, (uint32_t)p30);   // 帧步在跑时过场靠这一位稳定按 30（出图间隔跟帧步，不看钩子返回值）
        return p30;
    }
    return 0;
}
// 键页改可写：装载器把键页封成只读，只有宽屏表（s2a_widen_load）会改回可写；帧率表写槽（slot / speed）和改写器 bl_rec 跳板的 str 也写这一页，
// 主程序没有宽屏表时当场写只读页会崩（原生层线 10-26 审出），所以有这几种行就自己改（同 widen.c 的写法）
static void key_rw(module_t *m) {
    if (!m) return;
    if (!g_key_rw && !(g_key_rw = calloc((size_t)g_mod_cap, 1))) die("帧率表键页标记 %d 项分配失败", g_mod_cap);
    if (g_key_rw[m - g_mod]) return;
    if (s2a_key_page_writable(m)) die("%s 键页改可写失败（帧率表槽）", m->name);
    g_key_rw[m - g_mod] = 1;
}
static int writer_start_locked(void) {
    if (g_writer_error) return g_writer_error;
    if (!g_writer_admit || g_writer_closed || g_writer_started) return 0;
    atomic_store(&g_writer_stop, 0);
    int error = pthread_create(&g_writer, NULL, writer, NULL);
    if (error) {
        atomic_store(&g_writer_stop, 1); g_writer_error = error;
        return error;
    }
    g_writer_started = 1;
    return 0;
}
static void start_published(int need_writer, int have_table) {
    pthread_mutex_lock(&g_writer_mu);
    // A stop that overlapped loader work cannot be undone by late publication.
    if (g_writer_closed) { pthread_mutex_unlock(&g_writer_mu); return; }
    atomic_store(&g_have, have_table);
    controls_ready();
    int error = need_writer ? writer_start_locked() : 0;
    pthread_mutex_unlock(&g_writer_mu);
    if (error) LOG("【红】帧率表写入线程创建失败：%d，未发布 writer，禁止退休会话", error);
}
void s2a_fps_start(const char *dir) {
    // The loader/coordinator serializes table parsing. It may die/longjmp from
    // cpatch_follow/key_rw, so never retain a mutex across that work or logging.
    pthread_mutex_lock(&g_writer_mu);
    int refused = g_writer_closed || g_writer_admit;
    if (!refused) {
        g_writer_admit = 0;
        pthread_mutex_lock(&g_control_mu); g_ready = 0; atomic_store(&g_have, 0); pthread_mutex_unlock(&g_control_mu);
    }
    pthread_mutex_unlock(&g_writer_mu);
    if (refused) { LOG("【红】帧率表尚未 reset 或已经发布，拒绝重复装载"); return; }
    atomic_store(&g_on, fps_on_at_start()); cpatch_follow(atomic_load(&g_on));   // 没有我方帧率表的款，社区帧率补丁也按这个开关定
    char path[1100]; const char *e = getenv("S2A_FPS_TABLE");
    if (e && *e) strlcpy(path, e, sizeof path); else snprintf(path, sizeof path, "%s/fps.tsv", dir);
    FILE *f = fopen(path, "r"); if (!f) { start_published(s2a_cpatch_fps_count() > 0, 0); return; }
    g_boot_file = f;
    char line[256]; int present = 0, bad = 0; const char *bid = s2a_main_build_id();
    while (fgets(line, sizeof line, f)) {
        // 超出缓冲的行（11-06 旷野之息表：中文注释 279 / 293 字节）：读完这一行剩下的部分丢掉，不当下一行解析（原先剩下那截报「不认的行」红）。
        //   超出的部分落在注释里（前半截已有 #）照常用；数据段本身超长整行报红、不用
        if (!strchr(line, '\n') && !feof(f)) { int ch; while ((ch = fgetc(f)) != EOF && ch != '\n') {}
            if (!strchr(line, '#')) { LOG("【红】帧率表 %s：行超过 %zu 字节且数据段没在其中结束，整行不用（前段：%.40s…）", path, sizeof line - 1, line); bad++; continue; } }
        char *h = strchr(line, '#'); if (h) *h = 0;
        char a[16], b[48], c[32], t[8], v[32], x[96] = "", cmod[48], coff[32], ct[8], cop[4], cval[32]; int cn = 0;
        char *iff = strstr(line, " if ");
        if (iff) { *iff = 0; cn = sscanf(iff + 4, "%47s %31s %7s %3s %31s", cmod, coff, ct, cop, cval); }
        char offv[32] = ""; { char *op = strstr(line, " off "); if (op) { *op = 0; sscanf(op + 5, "%31s", offv); } }   // w 行关值：w … <值> [*偏移] off <关值> [if …]——off 写在值 / 解引用之后、if 之前（从「 off 」截断，后面别的不认）；关 60 帧时写它，见 writer
        int n = sscanf(line, "%15s %47s %31s %7s %31s %95s", a, b, c, t, v, x);
        if (n <= 0) continue;
        // build 行：本包主程序构建号的前缀（仓库 runtime/fps/ 一律写 16 位十六进制 = 前 8 字节）。审计 P1-93：原先多短都认，「build 0」或几位前缀会套到别的版本上；
        //   现在至少 16 位且全是十六进制才算，不合格按对不上处理（整表不用、报红）
        if (!strcmp(a, "build") && n >= 2) { size_t bl = strlen(b); int ok = bl >= 16 && strspn(b, "0123456789abcdefABCDEF") == bl;
            if (!ok) LOG("【红】帧率表 %s 的 build 行「%s」不是至少 16 位的十六进制构建号：按对不上处理", path, b);
            if (!ok || strncasecmp(bid, b, bl)) { LOG("【红】帧率表 %s 是构建号 %s 的，本包主程序是 %s：整表不用", path, b, bid); fclose(f); g_boot_file = NULL; start_published(s2a_cpatch_fps_count() > 0, 0); return; } continue; }
        if (!strcmp(a, "present") && n >= 2 && !strcmp(b, "display")) { present = 1; continue; }
        if (!strcmp(a, "c")) { key_rw(mod_named(b)); if (n >= 4 && !strcmp(t, "word")) g_word_rows++; continue; }   // 改指令：出包时改写器已经打进去；bl_rec 跳板运行时写键页
        if (!strcmp(a, "slot") || !strcmp(a, "speed") || !strcmp(a, "present30")) {
            if (!g_fm) g_fm = mod_named("main");
            int sl = !strcmp(a, "present30") ? (cn >= 4 && !strcmp(cmod, "slot") ? atoi(coff) : -1) : atoi(b);
            if (!g_fm || sl < 2032 || sl > 2047) { LOG("【红】帧率表 %s：行「%s」的槽不在 2032–2047 或没有主程序", path, a); bad++; continue; }
            key_rw(g_fm);
            if (!strcmp(a, "slot") && (n == 4 || n == 5) && g_nsl < 16) { uint32_t bits, offb; const char *ov = n == 5 ? v : t;
                if (!strcmp(c, "f32")) { float fv = strtof(t, NULL), fo = strtof(ov, NULL); memcpy(&bits, &fv, 4); memcpy(&offb, &fo, 4); }
                else { int32_t iv = (int32_t)strtol(t, NULL, 0), io = (int32_t)strtol(ov, NULL, 0); memcpy(&bits, &iv, 4); memcpy(&offb, &io, 4); }
                g_sl[g_nsl].sl = sl; g_sl[g_nsl].on = bits; g_sl[g_nsl].off = offb; g_nsl++;
                LOG("帧率表：键页槽 %d 开 %s %s / 关 %s", sl, c, t, ov); continue; }
            if (!strcmp(a, "speed") && (n == 4 || n == 5)) { int ss = n == 5 ? atoi(v) : -1;
                if (n == 5 && (ss < 2032 || ss > 2047 || ss == sl)) { LOG("【红】帧率表 %s：speed 行的秒槽 %s 不在 2032–2047 或与步长槽相同", path, v); bad++; continue; }
                g_spd_slot = sl; g_spd_sec = ss; g_spd_lo = strtof(c, NULL); g_spd_hi = strtof(t, NULL);
                spd_store(1.0f); LOG("帧率表：动态步长写键页槽 %d%s，夹在 [%g, %g]", sl, ss >= 0 ? "（另写秒槽）" : "", (double)g_spd_lo, (double)g_spd_hi); continue; }
            if (!strcmp(a, "present30") && iff && (!strcmp(ct, "==") || !strcmp(ct, "!="))) { g_p30_slot = sl; g_p30_eq = !strcmp(ct, "=="); g_p30_val = (int32_t)strtol(cop, NULL, 0);
                LOG("帧率表：键页槽 %d %s %d 时出图间隔退回游戏自己设的", sl, ct, g_p30_val); continue; }
            LOG("【红】帧率表 %s：行「%s」写法不认", path, a); bad++; continue; }
        if (!strcmp(a, "w") && (n == 5 || (n == 6 && x[0] == '*')) && g_nfw < 32) {
            uint64_t ch[6]; int nch = 0;   // *<偏移>[*<偏移>…]：一级到六级指针链（FPSLocker 补丁的 [MAIN, 偏移, 链…]，tools/patch_fps_yaml.py 转）
            char *q = n == 6 ? x : NULL;
            while (q && *q == '*' && nch < 6) { char *e2; ch[nch++] = strtoull(q + 1, &e2, 16); if (e2 == q + 1) { nch = -1; break; } q = e2; }
            if (n == 6 && (nch <= 0 || *q)) nch = -1;   // 没有偏移、写法不对、超过六级都不收
            if (nch < 0) { LOG("【红】帧率表 %s：行「w %s %s %s %s %s」指针链写法不认（*偏移 至多六级），跳过", path, b, c, t, v, x); bad++; continue; }
            module_t *m = mod_named(b); uint64_t off = strtoull(c, NULL, 16);
            uint64_t end = m ? (m->patch_off < 0 ? m->image_size : (uint64_t)m->patch_off) : 0; int dr = n == 6;
            if (!m || off < m->data_off || off > end || end - off < (uint64_t)(dr ? 8 : 4) || off % (dr ? 8 : 4) || (strcmp(t, "i32") && strcmp(t, "f32"))) { LOG("【红】帧率表 %s：行「w %s %s %s %s %s」不在 %s 的数据段或类型不认，跳过", path, b, c, t, v, x, b); bad++; continue; }
            module_t *cm2 = NULL; uint64_t co = 0; int csz = 0;
            if (iff) {   // 条件：数据段里 1 / 4 字节、== / !=
                cm2 = cn == 5 ? mod_named(cmod) : NULL; co = cm2 ? strtoull(coff, NULL, 16) : 0; csz = !strcmp(ct, "u8") ? 1 : !strcmp(ct, "i32") ? 4 : 0;
                uint64_t cend = cm2 ? (cm2->patch_off < 0 ? cm2->image_size : (uint64_t)cm2->patch_off) : 0;
                if (!cm2 || !csz || co < cm2->data_off || co > cend || cend - co < (uint64_t)csz || co % (uint64_t)csz || (strcmp(cop, "==") && strcmp(cop, "!="))) {
                    LOG("【红】帧率表 %s：行「w %s %s …」的条件「if %s %s %s %s %s」不认或不在数据段，跳过", path, b, c, cmod, coff, ct, cop, cval); bad++; continue; } }
            fps_w *w = &g_fw[g_nfw++]; memset(w, 0, sizeof *w); w->m = m; w->off = off; w->f32 = !strcmp(t, "f32"); w->deref = dr;
            if (dr) { memcpy(w->ch, ch, sizeof ch); w->nch = nch; w->off2 = ch[nch - 1]; }
            if (cm2) { w->cm = cm2; w->coff = co; w->csz = csz; w->ceq = !strcmp(cop, "=="); w->cval = (int32_t)strtol(cval, NULL, 0); }
            if (w->f32) { float x = strtof(v, NULL); memcpy(&w->bits, &x, 4); } else { int32_t x = (int32_t)strtol(v, NULL, 0); memcpy(&w->bits, &x, 4); }
            if (offv[0]) { w->has_off = 1; if (w->f32) { float x = strtof(offv, NULL); memcpy(&w->offbits, &x, 4); } else { int32_t x = (int32_t)strtol(offv, NULL, 0); memcpy(&w->offbits, &x, 4); } }
            snprintf(w->what, sizeof w->what, "%s %s", t, v); continue; }
        LOG("【红】帧率表 %s：不认的行「%s」", path, line); bad++;
    }
    fclose(f); g_boot_file = NULL;
    // 出图间隔只在起局开时放开（关 = 三层都不动，L1 交换间隔按游戏）。原先开关都设 display、靠每帧钩子退回游戏间隔：出图虽回到游戏间隔，
    //   只看 display 模式的路径（hle_nvn.c nvn_game_fps → 帧节拍行 / 显示链接目标 / 浮层目标）照报 60（10-28 巫师3 关局：host.log「帧节拍 … 60 帧/秒」，frames.tsv 实测 30）。
    //   代价：起局关、运行中 s2a_fps_set_enabled(1) 不放开出图间隔（产品开关是起局环境变量 S2A_FPS60、下次启动生效，没有运行中开的调用方）
    g_present_row = present;
    if (present && atomic_load(&g_on) && !getenv("DM_PRESENT_INTERVAL") && !setenv("DM_PRESENT_INTERVAL", "display", 0)) g_default_present = 1;
    { const char *fe = getenv("S2A_FSTEP");
      if (g_spd_slot >= 0 && !(fe && !strcmp(fe, "0"))) { dm_fps_state = g_fs_page; LOG("帧率表：接宿主帧步（直连：每帧保持整数个 vsync，60 撑不住稳定 30、游戏速度不变；S2A_FSTEP=0 不接）"); } }
    slots_apply(atomic_load(&g_on)); fs_target(eff());
    { int no = 0; for (int i = 0; i < g_nfw; i++) no += !g_fw[i].has_off;
      if (no) LOG("帧率表：%d 条数据写入没写关值（off），运行中关 60 帧退不回这几处，重启后生效", no); }
    LOG("帧率表 %s：60 帧%s；出图间隔%s，数据写入 %d 处%s", path, atomic_load(&g_on) ? "开" : "关（S2A_FPS60=0，回游戏原生帧率）",
        present && atomic_load(&g_on) ? "放开（每个显示节拍一帧）" : present ? "按游戏（60 帧关：表里的 present display 不生效）" : "按游戏", g_nfw, bad ? "（有坏行，见上）" : "");
    start_published(1, 1);   // 包含只有槽/社区补丁的款；所有表读完后才允许创建写入线程。
}
static int writer_stop_locked(void) {
    g_writer_closed = 1; g_writer_admit = 0;
    pthread_mutex_lock(&g_control_mu); g_ready = 0; atomic_store(&g_have, 0); pthread_mutex_unlock(&g_control_mu);
    atomic_store(&g_writer_stop, 1);
    if (g_writer_error) return -1;
    if (g_writer_started) {
        int error = pthread_join(g_writer, NULL);
        if (error) { g_writer_error = error; return -1; }
        g_writer_started = 0;
    }
    return 0;
}
int s2a_fps_session_stop(void) {
    pthread_mutex_lock(&g_writer_mu);
    int result = writer_stop_locked();
    int error = g_writer_error;
    pthread_mutex_unlock(&g_writer_mu);
    if (result) LOG("【红】帧率表写入线程未能退休：%d，保留所有权/关闭准入", error);
    return result;
}
int s2a_fps_session_reset(void) {
    pthread_mutex_lock(&g_writer_mu);
    if (writer_stop_locked()) {
        int error = g_writer_error; pthread_mutex_unlock(&g_writer_mu);
        LOG("【红】帧率表写入线程未能退休：%d，保留所有权/关闭准入", error); return -1;
    }
    memset(g_fw, 0, sizeof g_fw); g_nfw = 0; g_fm = NULL;
    free(g_key_rw); g_key_rw = NULL;
    g_spd_slot = g_spd_sec = g_p30_slot = -1; g_p30_eq = g_p30_val = 0;
    g_spd_lo = g_spd_hi = 0; g_present_last = 0;
    dm_fps_state = NULL; memset(g_fs_page, 0, sizeof g_fs_page);
    memset(g_sl, 0, sizeof g_sl); g_nsl = g_word_rows = g_present_row = 0;
    atomic_store(&g_on, 1);
    const char *present = getenv("DM_PRESENT_INTERVAL");
    if (g_default_present && present && !strcmp(present, "display")) unsetenv("DM_PRESENT_INTERVAL");
    g_default_present = 0;
    g_writer_closed = 0; // cap_watch still waits for the next complete fps_start
    pthread_mutex_unlock(&g_writer_mu);
    return 0;
}
