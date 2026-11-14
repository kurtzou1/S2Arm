// 撑不住就问玩家·宿主侧（判定在 qprompt.c，单测 runtime/tests/t_qprompt.c）：直连上屏每帧调 s2a_qp_frame（graphics/nvn hle_nvn.c）。
//   逐帧按运行时实际生效状态判（维护者 11-02，不查表）：帧率只算 60 帧真在生效（fps.c eff()：有来源、设置开着、没降档——本来 60 帧 / 没来源 / 关了 / 热降档都为假）的帧；
//   满屏只算画面真放宽了（屏宽 > 1920 或屏高 > 1080，且整套放宽 s2a_widen_full 或游戏自己出宽图 s2a_widen_game 在生效；玩家选退回 16:9 后钉成 1920×1080 自然不算）的帧。
//   没铺满 = 满屏线内容判据最近一次（2 秒内）结论是 1 黑带 / 2 接缝 / 3 暗带（扩展区异常）；4 几何、5 免判（原比例页 / 回退 / 纯 2D / 游戏自己画的黑）不算。
//   玩家包没有自动玩家截图、内容判据不会自己跑：本文件起一条线程，只在判定值得采样时（s2a_qp_fit_wanted：上一帧是局内游戏画面、画面真放宽、本局满屏提示还能问）每秒请求判一帧
//   （mtl_fit_sample，满屏线 nvn_mtl.m，判据不进上屏线程）；菜单 / 过场 / 视频 / 问过之后不取图，线程只空转（审计 P1-82：原先放宽着就每秒整帧离屏取图、问过也不停）。玩家问过的（App 设置）第一帧关掉。该问时调 s2a_ios_qprompt（ios/app.m 弹窗、记住选择、热切换）；
//   自动化局（s2a_unattended：执行器 / 普查 / 自动玩家起的局）照判、只记日志不弹
#include "native.h"
#include "s2a_qprompt.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include "s2a_unattended.h"
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
int s2a_fps_effective(void); int s2a_fps_real_source(void); int s2a_widen_game(void); int s2a_widen_full(void); int s2a_screen_w(void); int s2a_screen_h(void);
__attribute__((weak)) int mtl_fit_sample(void) { return 0; }   // 满屏线 graphics/nvn nvn_mtl.m：请求判下一帧（自动玩家挂着取图时让路返回 0）；没链直连层的宿主 / 单测用这个空实现
__attribute__((weak)) int mtl_fit_last(uint64_t *seq, uint64_t *present_n) { *seq = 0; *present_n = 0; return 0; }
__attribute__((weak)) int64_t s2a_widen_errors(void) { return 0; }   // 宽屏核心（graphics/widen/export WidenCApi）：导出入口异常累计；没链核心的宿主 / 单测用这个空实现   // 同上：最近一次内容判定种类（graphics/metal/fit_judge.h last_kind），seq 每判一次加一
// 宽屏（屏宽 > 1920）或高屏加高（屏高 > 1080：Duo 内屏 / iPad）都算放宽。11-05 前只看宽：Duo / iPad 上满屏取样线程从不取图、局内没铺满也从不问玩家退回
//   （旷野之息 Duo 局内场景只占画布 60%，宿主报红 0、提示 0）
static int fit_live(void) { return (s2a_screen_w() > 1920 || s2a_screen_h() > 1080) && (s2a_widen_full() || s2a_widen_game()); }
static _Atomic uint64_t g_fit_t;   // 最近一次拿到新内容判定的时刻
static _Atomic int g_fit_bad;      // 那次是不是扩展区异常（1 / 2 / 3）
static void *fit_sampler(void *a) {   // 画面放宽时每秒请求判一帧，读回结论
    (void)a; uint64_t seen = 0; int64_t errs = -1;
    for (;;) { sleep(1); if (!fit_live() || !s2a_qp_fit_wanted()) continue; mtl_fit_sample();
        // 判据新结论或核心异常计数涨了（s2a_qp_unfit_sample）：这一秒记一次结论。只有核心异常、判据没新结论时也记（核心异常本身就是画面不可靠）
        uint64_t seq, pn; int k = mtl_fit_last(&seq, &pn), fresh = seq && seq != seen; int64_t e = s2a_widen_errors(), e0 = errs;
        int bad = s2a_qp_unfit_sample(fresh ? k : -1, e, &errs);
        if (fresh || (e0 >= 0 && e > e0)) { seen = seq; atomic_store(&g_fit_bad, bad); atomic_store(&g_fit_t, now_ns()); } }
    return NULL;
}
__attribute__((weak)) int64_t s2a_widen_stretch(int which) { (void)which; return -1; }   // 宽屏核心（WidenCApi）：拉伸风险累计 0 对 / 1 拉伸 / 2 收窄；没链核心 -1
__attribute__((weak)) void s2a_ios_widen_auto(int hot, int why, int persist) { (void)hot; (void)why; (void)persist; }   // app.m：persist 时记进本 App 设置（下次起局 16:9）+ 一行横幅；Mac / 单测没有界面
#include "s2a_widen_remember.h"
#include <stdlib.h>
int s2a_widen_force_native(int on);
// 满屏自检自动退回（11-06 满屏泛化：大范围默认开的安全网，取代「问玩家要不要退回」）：一局最多一次。
//   why 1 = 满屏判据局内没铺满累计 20 秒（黑带 / 接缝 / 暗带 / 核心异常）；2 = 拉伸（场景 3D 笔按 k 横拉）；3 = 收窄（场景 3D 笔被收进中间 1/k）。
//   只放宽了宿主侧的款当场热切回 16:9（s2a_widen_force_native）；游戏自己出宽图的款（第二层值槽装载时填死）下次启动 16:9
static void widen_auto_revert(int why, int secs) {
    static int done; if (done) return; done = 1;
    int r = s2a_widen_force_native(1);
    // 记不记住本款：两次不同启动都触发才持久（runtime/src/widen_remember.c）；只一次的下次启动重新试满屏
    char path[1100]; s2a_docs_path(path, sizeof path, "widen_auto.txt");
    int n = r != 0 ? s2a_wr_note(path) : s2a_wr_load(path), persist = r != 0 && s2a_wr_persist(n);
    static const char *const w[] = {"", "局内满屏判据报没铺满", "场景 3D 画面被横向拉伸", "场景 3D 画面被收进中间"};
    LOG("满屏自检：过去 %d 秒%s，%s", secs, w[why < 1 || why > 3 ? 1 : why], r > 0 ? "已当场退回 16:9 原比例" : r < 0 ? "本款画面由游戏自己按宽屏画，当场退不回" : "画面没在放宽，不动");
    if (r != 0) LOG("满屏自检：第 %d 次启动触发退回，%s", n, persist ? "两次启动都触发，记住本款、之后起局 16:9" : "只记次数，下次启动重新试满屏");
    if (r != 0) s2a_ios_widen_auto(r > 0, why, persist);
}
// 拉伸风险窗口：局内游戏画面每攒满 30 秒取一次核心计数的差。场景 3D 笔里「拉伸 + 收窄」≥ 300 笔且占 ≥ 25%，连续两个窗口 → 自动退回。
//   阈值的意思：已验证款的场景 3D 笔都该读到改写镜头 / 游戏宽镜头 / 采样放宽贴图（风险 0）；偶发几笔（粒子、贴花没读镜头）占比远低于 1/4，连续两窗口排除一闪而过
static void stretch_window(int game, uint64_t dt) {
    static uint64_t win, secs; static int64_t o0 = -1, r0, q0; static int strikes;
    if (!game || !fit_live() || !dt || dt >= 1000000000ull) return;
    if (o0 < 0) { o0 = s2a_widen_stretch(0); r0 = s2a_widen_stretch(1); q0 = s2a_widen_stretch(2); return; }
    win += dt; if (win < 30000000000ull) return;
    secs += win / 1000000000ull; win = 0;
    int64_t o = s2a_widen_stretch(0), r = s2a_widen_stretch(1), q = s2a_widen_stretch(2), dO = o - o0, dR = r - r0, dQ = q - q0;
    o0 = o; r0 = r; q0 = q;
    int bad = dR + dQ >= 300 && 4 * (dR + dQ) >= dO + dR + dQ;
    strikes = bad ? strikes + 1 : 0;
    LOG("满屏自检：局内 30 秒场景 3D 笔 对 %lld、拉伸 %lld、收窄 %lld%s", (long long)dO, (long long)dR, (long long)dQ, bad ? (strikes >= 2 ? "，连续两窗口超线" : "，超线（再一个窗口就退回）") : "");
    if (strikes >= 2) widen_auto_revert(dR >= dQ ? 2 : 3, (int)secs);
}
__attribute__((weak)) int s2a_ios_qp_asked(int kind) { (void)kind; return 0; }   // app.m：玩家这款问过没有（记在本 App 设置）
__attribute__((weak)) void s2a_ios_qprompt(int kind, int secs) { (void)kind; (void)secs; }   // app.m：弹提示（secs = 文案里「过去 XX 秒」）；Mac 宿主没有界面
__attribute__((weak)) void s2a_ios_fps_native60(int on) { (void)on; }   // app.m：记住本款是不是原生 60 帧（设置页 60 帧那行据此显示「本款原生 60 帧」、开关置灰）
void s2a_ql_host_frame(uint64_t now, int game, uint64_t dt, int game_itv); int s2a_ql_host_on(void);   // 档位梯子（runtime/src/qladder_host.c）
void s2a_cpatch_frame(uint64_t now, int game, uint64_t dt);   // 社区补丁量效果（runtime/src/cpatch.c）
void s2a_qp_frame(uint32_t draws, int video, int cutscene, int game_itv) {
    static int cfg, quiet, native = -1; static uint64_t prev;
    if (!cfg) { cfg = 1; quiet = s2a_unattended();
        // 档位梯子开着时帧率不再问玩家：跟不上由梯子自动落档（维护者 11-06 优雅降级）；满屏照旧问
        int f = !s2a_ios_qp_asked(S2A_QP_FPS) && !s2a_ql_host_on(), w = !s2a_ios_qp_asked(S2A_QP_FIT);
        s2a_qp_config(f, w);
        pthread_t th; if (w && !pthread_create(&th, NULL, fit_sampler, NULL)) pthread_detach(th);
        LOG("撑不住就问玩家：帧率提示%s、满屏提示%s（开局 60 帧%s、宽屏%s）%s", f ? "可问" : s2a_ql_host_on() ? "交档位梯子" : "问过", w ? "可问" : "问过", s2a_fps_effective() ? "生效" : "没生效", fit_live() ? "生效" : "没生效",
            quiet ? "（自动化局：只记不弹）" : ""); }
    uint64_t t = now_ns(), ft = atomic_load(&g_fit_t); int unfit = atomic_load(&g_fit_bad) && ft && t - ft < 2000000000ull;
    // 帧率：只有真来源（表里 w / slot / speed / 改指令行、社区补丁）或游戏自设间隔 ≥ 2 时 60 帧才改得动；只有 present display 而游戏自己就设间隔 1 = 原生 60 帧，切了也一样，不问
    int real = s2a_fps_real_source();
    int r = s2a_qp_present(t, draws, video, cutscene, unfit, s2a_fps_effective() && (real || game_itv >= 2), fit_live(), game_itv);
    { uint64_t dt = prev ? t - prev : 0; stretch_window(s2a_qp_game(), dt); s2a_ql_host_frame(t, s2a_qp_game(), dt, game_itv); s2a_cpatch_frame(t, s2a_qp_game(), dt); prev = t; }   // 社区补丁量效果（runtime/src/cpatch.c）
    int n = s2a_qp_native60();
    if (n >= 0 && n != native) { native = n; int v = n == 1 && !real;
        LOG("原生 60 帧判定：%s（游戏画面里%s；%s）", v ? "是，设置页 60 帧那行显示「本款原生 60 帧」" : "否",
            n == 1 ? "游戏自设交换间隔累计 30 秒都是 1、帧间隔都在 20 ms 内" : "游戏自设过间隔 ≥ 2，或间隔是 1 但实际帧间隔多数超过 20 ms（游戏自己限帧）", real ? "有真帧率来源" : "没有真帧率来源");
        if (!quiet) s2a_ios_fps_native60(v); }
    if (!r) return;
    if (r == S2A_QP_FIT) { widen_auto_revert(1, s2a_qp_secs()); return; }   // 满屏不稳定不再问玩家：自动退回 16:9 并记住（11-06 满屏泛化，大范围默认开的安全网）
    LOG("撑不住就问玩家：过去 %d 秒%s%s", s2a_qp_secs(), r == S2A_QP_FPS ? "局内维持不住 60 帧（最近 30 秒 < 55 帧）" : "局内满屏判据报没铺满", quiet ? "，自动化局只记不弹" : "，弹提示");
    if (!quiet) s2a_ios_qprompt(r, s2a_qp_secs());
}
