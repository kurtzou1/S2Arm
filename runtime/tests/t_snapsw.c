// 即时存档开关（runtime/src/snapsw.c）两态：苹果端缺省开、S2A_SNAP_MODE=0 关；恢复局另算。期望按 0.6.0 口径手写（玩家要真能用快照，设置里能关）
#define S2A_SNAPSW_TEST
#include "../src/snapsw.c"
static int g_pref = -1;   // ios/settings.m s2a_ios_snap_pref_off 的替身：-1 没存过、0 存为开、1 存为关
int s2a_ios_snap_pref_off(void) { return g_pref == 1; }
#define S2A_SNAP_OFF_ADDRESS 1   // native.h（snapsw.c 不含它）
#define S2A_SNAP_OFF_LOGCAP 2
#include <stdio.h>
#include <string.h>
static int g_fail, g_ok;
static void reset(const char *mode, const char *restore) {
    if (mode) setenv("S2A_SNAP_MODE", mode, 1); else unsetenv("S2A_SNAP_MODE");
    if (restore) setenv("S2A_SNAP_RESTORE", restore, 1); else unsetenv("S2A_SNAP_RESTORE");
    g_snap_sw = -1; atomic_store(&g_snap_live, -1); g_snap_off = 0;   // 每项从新开局算：上一项关掉的原因码不带过来
}
static void eq(const char *n, int want, int got) { if (want == got) g_ok++; else { g_fail++; printf("  不符：%s 期望 %d → 真结果 %d\n", n, want, got); } }
int main(void) {
    reset(NULL, NULL);  eq("① 没设：能存", 1, s2a_snap_saving()); eq("① 没设：记日志", 1, s2a_snap_logging()); eq("① 没设：不是恢复局", 0, s2a_snap_restoring());
    reset("0", NULL);   eq("② 设 0（玩家关）：不能存", 0, s2a_snap_saving()); eq("② 设 0：不记日志", 0, s2a_snap_logging()); eq("② 设 0：快照模式整体关", 0, s2a_snap_mode());
    reset("1", NULL);   eq("③ 设 1：能存", 1, s2a_snap_saving());
    reset("0", "/x");   eq("④ 关 + 恢复局：不能存", 0, s2a_snap_saving()); eq("④ 关 + 恢复局：是恢复局", 1, s2a_snap_restoring()); eq("④ 关 + 恢复局：快照模式开（要恢复）", 1, s2a_snap_mode());
    reset(NULL, "/x");  eq("⑤ 恢复局（开）：恢复中不记日志（恢复完才接上）", 0, s2a_snap_logging()); eq("⑤ 恢复局：能存", 1, s2a_snap_saving());
    // ⑥ 进程内回到这一刻：开局已读过开关（缓存），之后才设 S2A_SNAP_RESTORE、宿主重建——重建期间要认得是恢复局；恢复完 unsetenv 就不是了
    reset(NULL, NULL);  eq("⑥ 开局：不是恢复局", 0, s2a_snap_restoring());
    setenv("S2A_SNAP_RESTORE", "/x", 1); eq("⑥ 进程内设了恢复目录：是恢复局", 1, s2a_snap_restoring()); eq("⑥ 进程内恢复：快照模式开", 1, s2a_snap_mode());
    unsetenv("S2A_SNAP_RESTORE"); eq("⑥ 恢复完撤掉：不是恢复局", 0, s2a_snap_restoring());
    // ⑦ 这一局宿主关掉快照（vawin.c：iOS 窗口放不下标准布局、窗口外也放不下命令记录区）：不能存、不记日志、快照模式关，原因码 1 给菜单；没关过原因码 0
    reset(NULL, NULL);  eq("⑦ 没关过：原因 0", 0, s2a_snap_off_reason());
    s2a_snap_disable(S2A_SNAP_OFF_ADDRESS);
    eq("⑦ 关后：不能存", 0, s2a_snap_saving()); eq("⑦ 关后：不记日志", 0, s2a_snap_logging()); eq("⑦ 关后：快照模式关", 0, s2a_snap_mode()); eq("⑦ 关后：原因 1", 1, s2a_snap_off_reason());
    // ⑧ 选定游戏后放得下又重新打开（s2a_snap_reenable，vawin.c 选定游戏后补放快照区）：按 ⑦ 关的原因重开 → 能存、记日志、原因 0；
    //   原因码不对（2）不开；玩家自己关着（S2A_SNAP_MODE=0）不开；没关过不开（回 0）
    eq("⑧ 原因码不对不开", 0, s2a_snap_reenable(2)); eq("⑧ 原因码不对：仍不能存", 0, s2a_snap_saving());
    eq("⑧ 按原因 1 重开", 1, s2a_snap_reenable(S2A_SNAP_OFF_ADDRESS)); eq("⑧ 重开后：能存", 1, s2a_snap_saving()); eq("⑧ 重开后：记日志", 1, s2a_snap_logging());
    eq("⑧ 重开后：原因 0", 0, s2a_snap_off_reason()); eq("⑧ 已开着再重开：回 0", 0, s2a_snap_reenable(S2A_SNAP_OFF_ADDRESS));
    reset("0", NULL); s2a_snap_disable(S2A_SNAP_OFF_ADDRESS); eq("⑧ 玩家关着：不重开", 0, s2a_snap_reenable(S2A_SNAP_OFF_ADDRESS)); eq("⑧ 玩家关着：仍不能存", 0, s2a_snap_saving());
    // ⑨ 玩家在设置里关快照（键 S2ASnapshot = NO）、启动环境没给 S2A_SNAP_MODE：第一次读（构造期，vawin.c 据此决定占不占命令记录区 / 虚拟池区）就是关，来源写「玩家设置」；
    //   启动环境给了 1 照开（启动环境 > 用户设置）；设置为开 / 没存过 → 开。11-21 前设置只在开局写环境变量，构造期第一次读已缓存「开」
    g_pref = 1; reset(NULL, NULL); eq("⑨ 设置关：不能存", 0, s2a_snap_saving()); eq("⑨ 设置关：快照模式关（构造期不占地址）", 0, s2a_snap_mode()); eq("⑨ 设置关：来源是玩家设置", 1, !strcmp(s2a_snap_source(), "玩家设置（关）"));
    reset("1", NULL); eq("⑨ 设置关、启动环境给 1：能存", 1, s2a_snap_saving());
    g_pref = 0; reset(NULL, NULL); eq("⑨ 设置开：能存", 1, s2a_snap_saving());
    g_pref = -1; reset(NULL, NULL); eq("⑨ 没存过：能存", 1, s2a_snap_saving()); eq("⑨ 没存过：来源缺省", 1, !strcmp(s2a_snap_source(), "缺省"));
    // ⑩ 构造期因放不下关掉：依据写「本局放不下快照区」（不是设置来源「缺省」）；选定游戏后重开：依据回到设置来源
    g_pref = -1; reset(NULL, NULL); s2a_snap_disable(S2A_SNAP_OFF_ADDRESS);
    eq("⑩ 放不下关掉：依据写放不下", 1, !strcmp(s2a_snap_source(), "本局放不下快照区"));
    eq("⑩ 重开", 1, s2a_snap_reenable(S2A_SNAP_OFF_ADDRESS)); eq("⑩ 重开后：依据回到缺省", 1, !strcmp(s2a_snap_source(), "缺省"));
    // ⑪ 游戏库给不给「回到这一刻」（s2a_snap_restore_offered）：有快照 + 开着 → 给；有快照 + 本局因地址关 → 照样给；有快照 + 玩家设置关 → 不给；没快照 → 不给
    g_pref = -1; reset(NULL, NULL); eq("⑪ 开着、有快照：给", 1, s2a_snap_restore_offered(1)); eq("⑪ 开着、没快照：不给", 0, s2a_snap_restore_offered(0));
    g_pref = -1; reset(NULL, NULL); s2a_snap_disable(S2A_SNAP_OFF_ADDRESS); eq("⑪ 本局因地址关、有快照：照样给", 1, s2a_snap_restore_offered(1)); eq("⑪ 本局因地址关、没快照：不给", 0, s2a_snap_restore_offered(0));
    g_pref = 1; reset(NULL, NULL); eq("⑪ 玩家设置关、有快照：不给", 0, s2a_snap_restore_offered(1));
    g_pref = -1; reset("0", NULL); eq("⑪ 启动环境关、有快照：不给", 0, s2a_snap_restore_offered(1));
    // ⑫ 玩家点「存下这一刻」（s2a_snap_save_gate，s2a_snap_request_save 照回）：开着 0；本局请求日志超限放弃后 -3（界面专门提示，不报「稍后再试」）；
    //   因地址关 / 玩家关 -1；超限后已有快照照样给「回到这一刻」，依据写超限
    g_pref = -1; reset(NULL, NULL); eq("⑫ 开着：能存 0", 0, s2a_snap_save_gate());
    s2a_snap_disable(S2A_SNAP_OFF_LOGCAP); eq("⑫ 日志超限：-3", -3, s2a_snap_save_gate()); eq("⑫ 日志超限：不记日志", 0, s2a_snap_logging());
    eq("⑫ 日志超限、有快照：照样给回到这一刻", 1, s2a_snap_restore_offered(1)); eq("⑫ 日志超限：依据写超限", 1, !strcmp(s2a_snap_source(), "本局请求日志超过上限"));
    eq("⑫ 日志超限不按地址重开", 0, s2a_snap_reenable(S2A_SNAP_OFF_ADDRESS)); eq("⑫ 仍 -3", -3, s2a_snap_save_gate());
    g_pref = -1; reset(NULL, NULL); s2a_snap_disable(S2A_SNAP_OFF_ADDRESS); eq("⑫ 因地址关：-1", -1, s2a_snap_save_gate());
    g_pref = -1; reset("0", NULL); eq("⑫ 玩家关：-1", -1, s2a_snap_save_gate());
    if (g_fail) printf("✗ t_snapsw：%d 项不符（共 %d 项）\n", g_fail, g_ok + g_fail); else printf("✓ t_snapsw：0 处不符（共 %d 项）\n", g_ok);
    return g_fail ? 1 : 0;
}
