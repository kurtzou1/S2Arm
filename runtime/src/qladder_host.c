// 档位梯子·宿主侧（判定在 qladder.c，单测 runtime/tests/t_qladder.c / t_qladder_host.c）：直连上屏每帧经 s2a_qp_frame（runtime/src/qprompt_host.c）调 s2a_ql_host_frame。
//   只有直连上屏会调到这里；不走直连的游戏不进梯子。直连里没有 GPU 读数的局，判定层不降不升（#1688）。
//   梯子只跑「原生 30 帧靠补丁」的款：有真帧率来源（帧率表 / 社区补丁，s2a_fps_real_source）且 60 帧开关开着；否则帧率归游戏，没有可调的，不跑。
//   运行模式只归玩家：梯子不改主机 / 掌机。游戏按模式开关玩法（例：一款体育游戏两人以上要求 TV 模式），梯子只调 60 帧补丁那一半（s2a_fps_hold，热切）。
//   不跨局记档（#1688）：每局从 60 帧起。原先降档写进 <Documents>/ladder.txt、下局从记下的档起，一局掉帧之后每局都压在 30 帧，玩家开 60 帧像没用；旧文件不再读。
//   压回 30 帧时告诉玩家（s2a_ios_fps_capped(4)：iOS ios/app.m、Mac macos/front_mac.m 横幅，带「再试 60 帧」按钮 → s2a_ql_retry60）。
//   开关：S2A_LADDER=0 关；自动化局（s2a_unattended）缺省关、S2A_LADDER=1 才开（普查 / 测量局要固定档位）。
#include "native.h"
#include "s2a_qladder.h"
#include "s2a_unattended.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
int s2a_fps_real_source(void); int s2a_fps_enabled(void); void s2a_fps_hold(int hold);
void s2a_ios_fps_capped(int reason);   // runtime/src/fps.c 弱定义（单测不说），ios/app.m、macos/front_mac.m 强定义：横幅
__attribute__((weak)) double s2a_gpu_busy_ms(void) { return -1; }   // 直连层 graphics/nvn hle_nvn.c 强定义
__attribute__((weak)) int dm_thermal_now(void) { return -1; }        // iOS ios/app.m、Mac runtime/src/host_main.c 强定义
__attribute__((weak)) int s2a_host_focused(void) { return 1; }       // runtime/src/os.c 强定义（平台壳写：iOS 前后台、Mac 失焦）
__attribute__((weak)) int s2a_host_sleeping(void) { return 0; }      // runtime/src/os.c 强定义（iOS 后台、Mac 系统睡眠）

static int g_on = -1;
static int ladder_on(void) {
    if (g_on < 0) { const char *e = getenv("S2A_LADDER"); g_on = e && *e ? strcmp(e, "0") != 0 : !s2a_unattended(); }
    return g_on;
}
static const char *tier_name(int t) { return t ? "30 帧" : "60 帧"; }
static int g_ready, g_idle, g_hold_last = -1, g_nogpu_said;   // g_idle：帧率归游戏，梯子没有可调的
static _Atomic int g_retry;   // 玩家要再试 60 帧（任意线程置位，上屏线程下一帧执行）
static void apply(int t, int quiet) {
    int hold = !s2a_ql_fps60(t), note = s2a_ql_fps_note(quiet, g_hold_last, hold, s2a_fps_enabled(), s2a_unattended());
    g_hold_last = hold; s2a_fps_hold(hold);
    if (note >= 0) s2a_ios_fps_capped(note);
}
// 横幅「再试 60 帧」按钮 / 局中重开 60 帧开关（runtime/src/fps.c s2a_fps_set_enabled）调；任意线程
void s2a_ql_retry60(void) { atomic_store(&g_retry, 1); }
// 每次上屏（qprompt_host.c s2a_qp_frame）调：game = 这一帧是局内游戏画面（s2a_qp_game）；dt 与上一帧间隔；game_itv 游戏自设交换间隔
void s2a_ql_host_frame(uint64_t now, int game, uint64_t dt, int game_itv) {
    if (!ladder_on() || g_idle) return;
    if (!g_ready) { g_ready = 1;
        if (!(s2a_fps_real_source() && s2a_fps_enabled())) { g_idle = 1; LOG("档位梯子：帧率归游戏（没有 60 帧补丁或 60 帧没开），没有可调的，不跑"); return; }
        s2a_ql_setup(); apply(0, 1);
        LOG("档位梯子：两档（60 帧 → 30 帧，本款靠 60 帧补丁；不改运行模式），每局从 60 帧起");
    }
    if (atomic_exchange(&g_retry, 0)) { s2a_ql_retry(now); apply(0, 1); LOG("档位梯子：玩家要再试 60 帧，放开 60 帧"); }
    // #1949：失焦 / 睡眠时系统给游戏降速，那段帧率说明不了跑不跑得动：丢掉在攒的窗口，回前台后空等几秒再计时
    if (!s2a_host_focused() || s2a_host_sleeping()) { s2a_ql_away(now); return; }
    double gpu = s2a_gpu_busy_ms();
    if (gpu < 0 && !g_nogpu_said) { g_nogpu_said = 1; LOG("档位梯子：这一局没有 GPU 读数，判不了是不是跑不动，不降档，照玩家选的 60 帧跑"); }
    int t = s2a_ql_frame(now, game, dt, gpu, dm_thermal_now(), game_itv);
    if (t < 0) return;
    double fps, slow, gp; int th; s2a_ql_last(&fps, &slow, &gp, &th); int why = s2a_ql_why();
    LOG("档位梯子：换到 %s（%s；上个窗口 %.1f 帧/秒、慢帧 %.1f%%、GPU 忙 %.0f%%、热状态 %d）%s", tier_name(t),
        why == S2A_QL_WHY_FPS ? "局内帧率达不到本档目标" : "GPU 余量够 2 分钟，升一档", fps, slow, gp, th,
        s2a_ql_cpu_bound() ? "；GPU 没跑满，是 CPU 跟不上：本局不再按 GPU 余量升回 60 帧" : "");
    apply(t, 0);
}
int s2a_ql_host_on(void) { return ladder_on(); }
