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
// iOS 上玩家在设置里关快照（键 S2ASnapshot = NO）：原先只由 ios/settings.m 在开局时（host_main → s2a_ios_load_graphics_settings）写 S2A_SNAP_MODE=0，
//   而这个开关在进程启动的构造期（vawin.c vawin_boot：命令记录区 / 虚拟池区占不占、占多大）就第一次读并缓存了，玩家关了也照开、地址照占（11-21 #f0490a 读码）。
//   启动环境没给 S2A_SNAP_MODE 时直接读设置（同 settings.m 的口径：显式存过且为假才关；启动环境 > 用户设置）
#if defined(__APPLE__)
// ios/settings.m 给强定义（读 NSUserDefaults 的 S2ASnapshot：显式存过且为假 → 1）；Mac 宿主不链它（启动器作业层按玩家设置写 S2A_SNAP_MODE），用下面的弱缺省
int s2a_ios_snap_pref_off(void);
#ifndef S2A_SNAPSW_TEST   // 单测（t_snapsw.c）自己给替身
__attribute__((weak)) int s2a_ios_snap_pref_off(void) { return 0; }   // 弱缺省：Mac 宿主 / 只链运行时的单测没有 ios/settings.m，按没关
#endif
static int snap_pref_off(void) { return s2a_ios_snap_pref_off(); }
#endif
static const char *g_snap_src = "缺省";   // 「能存」这一位按什么定的（构造期日志 / 诊断用）
static int snap_save_on(const char *m) {
#if defined(__APPLE__)
    if (!(m && *m)) { int off = snap_pref_off(); g_snap_src = off ? "玩家设置（关）" : "缺省"; return !off; }
    g_snap_src = "启动环境 S2A_SNAP_MODE";
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
// 构造期因 why 关掉的快照，选定游戏后又放得下（vawin.c s2a_window_snap_late，11-21）：玩家本来开着快照才重新打开，清原因码，「记日志」按新状态重算。回 1 = 重新打开了
int s2a_snap_reenable(int why) {
    if (!why || g_snap_off != why || !snap_save_on(getenv("S2A_SNAP_MODE"))) return 0;
    snap_sw(); g_snap_sw |= 1; g_snap_off = 0; atomic_store(&g_snap_live, -1); return 1;
}
// 本局构造期因放不下关掉（s2a_snap_disable）：「能存」这一位的依据就是它，不再报设置来源（11-21 真机：前一行黄字说放不下，这行却写「依据 缺省」）
// 游戏库长按卡片给不给「回到这一刻」（ios/app.m s2a_shell_snapshot_available；exists = 这款快照目录里有完整清单）：
//   玩家开着快照 → 给；这一局只是因地址放不下关了快照（s2a_snap_disable 的原因码，只有 S2A_SNAP_OFF_ADDRESS = 1）→ 照样给（11-22：已有快照不能变成看不见的文件，
//   恢复局按快照清单原址重占窗口与命令记录区，vawin.c snap_retake，不靠这一局的快照区）；玩家在设置里关了快照 → 不给（同改动前）
int s2a_snap_restore_offered(int exists) { snap_sw(); return exists && ((g_snap_sw & 1) || g_snap_off == 1); }
const char *s2a_snap_source(void) { snap_sw(); return g_snap_off ? "本局放不下快照区" : g_snap_src; }   // 原因码现在只有 S2A_SNAP_OFF_ADDRESS（native.h）
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
