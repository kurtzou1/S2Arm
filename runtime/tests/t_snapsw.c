// 即时存档开关（runtime/src/snapsw.c）两态：苹果端缺省开、S2A_SNAP_MODE=0 关；恢复局另算。期望按 0.6.0 口径手写（玩家要真能用快照，设置里能关）
#include "../src/snapsw.c"
#define S2A_SNAP_OFF_ADDRESS 1   // native.h（snapsw.c 不含它）
#include <stdio.h>
#include <string.h>
static int g_fail, g_ok;
static void reset(const char *mode, const char *restore) {
    if (mode) setenv("S2A_SNAP_MODE", mode, 1); else unsetenv("S2A_SNAP_MODE");
    if (restore) setenv("S2A_SNAP_RESTORE", restore, 1); else unsetenv("S2A_SNAP_RESTORE");
    g_snap_sw = -1; atomic_store(&g_snap_live, -1);
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
    if (g_fail) printf("✗ t_snapsw：%d 项不符（共 %d 项）\n", g_fail, g_ok + g_fail); else printf("✓ t_snapsw：0 处不符（共 %d 项）\n", g_ok);
    return g_fail ? 1 : 0;
}
