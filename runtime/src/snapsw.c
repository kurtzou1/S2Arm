// 即时存档开关（跨平台：苹果、安卓都编；安卓不做快照、不设这两个环境变量，恒为关）
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
// 即时存档开关的唯一定义处：图形层（弱引用）、服务层（P/Invoke，再在启动时转给音频两处）都读这里，不各自读环境变量。
//   能存 = 苹果端缺省开、S2A_SNAP_MODE=0 关（恢复局也能存：回到那一刻之后还能再存）；恢复中 = 现在设着 S2A_SNAP_RESTORE（现读）；s2a_snap_mode = 两者之一。
//   记日志（请求日志 / 句柄日志）= 能存且（不是恢复局，或恢复已完成）：恢复局里重放不记，恢复完成时把快照里的两份日志整份接过来当开头、序号接着编，之后照常记
static int g_snap_sw = -1;   // 位 0 能存、位 1 恢复中
static _Atomic int g_snap_live = -1;
// 能存：苹果端缺省开（0.6.0：玩家要真能用快照，设置里能关），S2A_SNAP_MODE=0 关（iPhone App / Mac 启动器作业层按玩家设置写）；
//   安卓不编快照引擎，恒关（设了 1 也不开）
static int snap_save_on(const char *m) {
#if defined(__APPLE__)
    return !(m && *m == '0');
#else
    (void)m; return 0;
#endif
}
static int snap_sw(void) {
    if (g_snap_sw < 0) { const char *m = getenv("S2A_SNAP_MODE"), *r = getenv("S2A_SNAP_RESTORE"); g_snap_sw = snap_save_on(m) | (r && *r) << 1; }
    return g_snap_sw;
}
// 这一局关掉即时存档（11-20：iOS 窗口放不下标准布局、窗口外也放不下命令记录区时，vawin.c 在构造期调）：只清「能存」，恢复中那一位不动；
//   原因码给菜单写一句玩家看得懂的提示（ios/vpad.m）。之后 s2a_snap_mode / s2a_snap_logging 都按关算
static int g_snap_off;
void s2a_snap_disable(int why) { snap_sw(); g_snap_sw &= ~1; g_snap_off = why; atomic_store(&g_snap_live, 0); }
int s2a_snap_off_reason(void) { return g_snap_off; }
int s2a_snap_saving(void) { return snap_sw() & 1; }
// 恢复中：每次现读 S2A_SNAP_RESTORE。进程内「回到这一刻」在宿主重启前才设它、恢复完 unsetenv，开局缓存的那一位跟不上——
//   iPhone 上重建时把这一局当成不在恢复，按本款学到的跨度收了窗口（59392 → 8192 MB），快照核对「窗口不符」拒绝恢复
int s2a_snap_restoring(void) { const char *r = getenv("S2A_SNAP_RESTORE"); return r && *r; }
int s2a_snap_mode(void) { return snap_sw() != 0 || s2a_snap_restoring(); }
int s2a_snap_logging(void) { int v = atomic_load(&g_snap_live); if (v < 0) { v = snap_sw() == 1; atomic_store(&g_snap_live, v); } return v; }
void s2a_snap_live_set(int on) { atomic_store(&g_snap_live, on ? 1 : 0); }
#if !defined(__APPLE__)
// 安卓：快照引擎（thread.c / snapshot.c 的苹果段）不编，开关恒关，服务层 C#（SnapLog.cs）不会真调下面三个；
//   NativeAOT 静态链接要求它 P/Invoke 的符号都有定义，给不做事的实现
int s2a_snap_need_handle(uint32_t h) { (void)h; return 0; }
int s2a_snap_replay_begin(int seq) { (void)seq; return 0; }
int s2a_snap_replay_end(int seq) { (void)seq; return 0; }
int s2a_snap_seq_live(int seq) { (void)seq; return 0; }
void s2a_snap_hlog_forget(int seq) { (void)seq; }
int s2a_snap_handle_use(uint32_t h, uint32_t *uid) { (void)h; *uid = 0; return -1; }
void s2a_snap_handle_unuse(uint32_t uid) { (void)uid; }
#endif
