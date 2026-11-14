// 档位梯子·宿主侧（判定在 qladder.c，单测 runtime/tests/t_qladder.c）：直连上屏每帧经 s2a_qp_frame（runtime/src/qprompt_host.c）调 s2a_ql_host_frame。
//   梯子种类按本局运行时状态定（不查按款表）：有真帧率来源（帧率表 / 社区补丁，s2a_fps_real_source）且 60 帧开关开着 = 原生 30 帧靠补丁 → 三档；否则两档（帧率归游戏）。
//   上限 = 玩家选的运行模式（#352，维护者 11-09：手机缺省掌机、玩家可自己开主机，Mac 缺省主机；launchers/shared/game_settings.v1.json docked）：
//     梯子只在它之下降档、回升也只回到它，不自己升到主机。原先首次从最高档 = 主机起，盖掉了 iPhone 的缺省掌机和玩家选的掌机。
//   运行模式只归玩家：梯子不改主机 / 掌机（起局不改、局中不切）。游戏按模式开关玩法（例：一款体育游戏两人以上要求 TV 模式，
//     掌机模式下弹「请把主机放进底座」），梯子降到掌机等于替玩家关掉这些玩法。梯子只调 60 帧补丁那一半；两档款（帧率归游戏）没有可调的，不跑。
//   档位记忆：<Documents>/ladder.txt 一行「kind=<1|2> tier=<n>」，一款一个 App、一台机一个容器 = 自然按机按款；首次从上限起。
//     起局（苹果 s2a_ql_boot / 安卓 s2a_ql_boot_mode）只读记下的档，不动 S2A_DOCKED；60 帧那半在第一帧按档压回 / 放开（s2a_fps_hold，热切）。
//   换档执行：60 帧当场热切（s2a_fps_hold）。三档款的底档（原「掌机 30 帧」）现在与 30 帧档效果相同：压回 30 帧、不切模式。
//   开关：S2A_LADDER=0 关；自动化局（s2a_unattended）缺省关、S2A_LADDER=1 才开（普查 / 测量局要固定档位）。
#include "native.h"
#include "s2a_qladder.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include "s2a_unattended.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int s2a_fps_real_source(void); int s2a_fps_enabled(void); void s2a_fps_hold(int hold);
void s2a_ios_fps_capped(int reason);   // runtime/src/fps.c 弱定义（Mac / 单测不说），ios/app.m 强定义：横幅
__attribute__((weak)) double s2a_gpu_busy_ms(void) { return -1; }   // 直连层 graphics/nvn hle_nvn.c 强定义
__attribute__((weak)) int dm_thermal_now(void) { return -1; }        // iOS ios/app.m、Mac runtime/src/host_main.c 强定义

static int g_on = -1, g_tier0 = -1, g_top_docked = 1;   // g_tier0：ladder.txt 里记的帧数档（-1 = 没记过）；g_top_docked：上限是不是主机
static char g_path[1100];
static int ladder_on(void) {
    if (g_on < 0) { const char *e = getenv("S2A_LADDER"); g_on = e && *e ? strcmp(e, "0") != 0 : !s2a_unattended(); }
    return g_on;
}
static void save(int kind, int tier) {
    if (!g_path[0]) return;
    char tmp[1200]; snprintf(tmp, sizeof tmp, "%s.tmp", g_path);
    FILE *f = fopen(tmp, "w"); if (!f) { LOG("【红】档位梯子：记不下档位（%s 打不开）", tmp); return; }
    fprintf(f, "kind=%d tier=%d\n", kind, tier); fclose(f);
    if (rename(tmp, g_path)) LOG("【红】档位梯子：记不下档位（改名失败）");
}
// 起局读档（两个入口共用）：docked = 玩家选的运行模式，当上限、也就是本局的运行模式。记下的档只管帧率那半，不改运行模式
static void boot(int docked, const char *from) {
    s2a_docs_path(g_path, sizeof g_path, "ladder.txt");
    FILE *f = fopen(g_path, "r"); int k = 0, t = -1;
    if (f) { if (fscanf(f, "kind=%d tier=%d", &k, &t) != 2) k = 0, t = -1; fclose(f); }
    // 只认帧数档（kind=1）。旧版两档款写的 kind=2 是运行模式（主机 / 掌机），#519 起模式只归玩家：忽略，升级后回到玩家选的模式
    if (k == S2A_QL_FPS && t >= 0 && t <= 2) g_tier0 = t;
    else if (k == S2A_QL_MODE) LOG("档位梯子：ladder.txt 里旧版记的运行模式档（kind=2 tier=%d）不再认，按玩家选的模式", t);
    g_top_docked = docked;
    LOG("档位梯子：运行模式 %s（%s），梯子不改", g_top_docked ? "主机" : "掌机", from);
}
// 苹果起局（host_main.c host_run，iOS 画面设置注入之后、服务层与宽屏装表读 S2A_DOCKED 之前）：
//   此刻环境里的 S2A_DOCKED 就是玩家选的运行模式（iOS 设置页写的，缺省掌机；Mac 启动器缺省主机）；没有 = 主机，Mac 的缺省。
//   固定档位的测量局关梯子（S2A_LADDER=0，自动化局缺省关）
void s2a_ql_boot(void) {
    if (!ladder_on()) return;
    const char *d = getenv("S2A_DOCKED");
    if (!d) setenv("S2A_DOCKED", "1", 1);   // 没设 = 主机（Mac 缺省），服务层 / 宽屏装表读到的与上限一致
    boot(d ? strcmp(d, "1") == 0 : 1, d ? "玩家设置" : "没设，按主机");
}
// 安卓起局（android/native/runtime/runtime.c，#528 第 6 项）：运行模式由 App 经服务请求的 console_mode 给（0 掌机 / 1 主机，缺省掌机），
//   不经环境变量 S2A_DOCKED。这里不读也不写 S2A_DOCKED：上面那个入口没设时会写成 1，安卓掌机局的服务层与宽屏装表就被带成主机
void s2a_ql_boot_mode(int docked) {
    if (!ladder_on()) return;
    boot(docked != 0, "App 设置");
}
static const char *tier_name(int t) {   // 只有三档款跑梯子
    static const char *f[] = {"60 帧", "30 帧", "30 帧（底档）"};
    return f[t < 0 ? 0 : t > 2 ? 2 : t];
}
static int g_ready, g_idle, g_hold_last = -1;   // g_idle：两档款，梯子没有可调的
static void apply(int t, int boot) {
    int hold = !s2a_ql_fps60(t), note = s2a_ql_fps_note(boot, g_hold_last, hold, s2a_fps_enabled(), s2a_unattended());
    g_hold_last = hold; s2a_fps_hold(hold);
    if (note >= 0) s2a_ios_fps_capped(note);
}
// 每次上屏（qprompt_host.c s2a_qp_frame）调：game = 这一帧是局内游戏画面（s2a_qp_game）；dt 与上一帧间隔；game_itv 游戏自设交换间隔
void s2a_ql_host_frame(uint64_t now, int game, uint64_t dt, int game_itv) {
    if (!ladder_on() || g_idle) return;
    if (!g_ready) { g_ready = 1;
        if (!(s2a_fps_real_source() && s2a_fps_enabled())) { g_idle = 1; LOG("档位梯子：两档款（帧率归游戏），运行模式归玩家，没有可调的，不跑"); return; }
        int t = g_tier0 >= 0 ? g_tier0 : 0;
        s2a_ql_setup(S2A_QL_FPS, t); s2a_ql_top(s2a_ql_top_tier(S2A_QL_FPS, g_top_docked)); t = s2a_ql_tier(); apply(t, 1);
        LOG("档位梯子：三档（60 → 30 → 30 底档，本款靠 60 帧补丁；不改运行模式），起始档 %s（%s）",
            tier_name(t), g_tier0 >= 0 ? "上次稳定档，不超过运行模式" : "首次，从运行模式起");
    }
    int t = s2a_ql_frame(now, game, dt, s2a_gpu_busy_ms(), dm_thermal_now(), game_itv);
    if (s2a_ql_stable_now()) { save(S2A_QL_FPS, s2a_ql_tier()); LOG("档位梯子：%s 稳住 2 分钟，记成本机本款的最后稳定档", tier_name(s2a_ql_tier())); }
    if (t < 0) return;
    double fps, slow, gpu; int th; s2a_ql_last(&fps, &slow, &gpu, &th); int why = s2a_ql_why();
    LOG("档位梯子：换到 %s（%s；上个窗口 %.1f 帧/秒、慢帧 %.1f%%、GPU 忙 %.0f%%、热状态 %d）", tier_name(t),
        why == S2A_QL_WHY_FPS ? "局内帧率达不到本档目标" : "GPU 余量够 2 分钟，升一档", fps, slow, gpu, th);
    if (why != S2A_QL_WHY_UP) save(S2A_QL_FPS, t);   // 降档立刻记（上一档不稳）；升档等稳住 2 分钟再记
    apply(t, 0);
}
int s2a_ql_host_on(void) { return ladder_on(); }
