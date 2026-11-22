// 即时存档恢复（Mac）：菜单「回到上次存下的这一刻」走进程内重启，进程内重启不换窗口 / 命令记录区（窗口里是这一局游戏的映射），
//   快照清单记的落点与这一局不同就接不上（s2a_snap_fits_inplace 回 0：两局之间学到 / 没学到跨度、版本更新后宿主保留不同）。
//   Mac 没有 iPhone 那样的游戏库恢复入口，这里就是 Mac 的「库里恢复」：本进程原地重新执行自己（同一个 pid、同一组标准输入输出，
//   启动器照常等这个进程、照常收它的输出），带上快照的绝对路径 S2A_SNAP_RESTORE——新映像的构造期按快照清单原址占窗口与命令记录区
//   （vawin.c snap_win / cmd_arena_at_snapshot，0.6.0 起启动即恢复就走这条），起宿主时核对、按快照恢复。玩家看到的是游戏重开一下就回到那一刻。
//   别的文件句柄一律不带过去（POSIX_SPAWN_CLOEXEC_DEFAULT，只留 0 / 1 / 2）：客体内存文件后备是已 unlink 的大稀疏文件，带过去会一直占着磁盘。
//   一次性的测试开关（S2A_SNAP_AT / S2A_SNAP_RESTART_AT）在新映像里去掉，不再到点存 / 再回去。成功不返回；失败回非 0（原进程照常跑）
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#include <stdlib.h>
#include <string.h>
#include "native.h"
#if defined(__APPLE__) && TARGET_OS_OSX
#include <crt_externs.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
void s2a_logcon_flush(void);
int s2a_snap_relaunch(const char *dir, int rollback) {
    if (!dir || dir[0] != '/') { LOG("【红】即时存档恢复：重新起这一局要快照的绝对路径（给的是 %s）", dir ? dir : "空"); return -1; }
    char exe[PATH_MAX]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) { LOG("【红】即时存档恢复：取不到本程序路径，不能重新起这一局"); return -1; }
    setenv("S2A_SNAP_RESTORE", dir, 1);
    if (rollback) setenv("S2A_SNAP_SAVE_ROLLBACK", "1", 1); else unsetenv("S2A_SNAP_SAVE_ROLLBACK");
    const char *at = getenv("S2A_SNAP_AT"), *rat = getenv("S2A_SNAP_RESTART_AT");
    char *sat = at ? strdup(at) : NULL, *srat = rat ? strdup(rat) : NULL;
    unsetenv("S2A_SNAP_AT"); unsetenv("S2A_SNAP_RESTART_AT");
    { void (*keep)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "s2a_mac_slot_keep_across_exec"); if (keep) keep(); }   // 我方机器的 Mac 局槽按 pid 记，新映像不重排（mac_slot_hold.c）
    LOG("即时存档恢复：这一局的落点接不上快照，原地重新起这一局（同一进程、构造期按快照清单原址占窗口）：%s", dir);
    s2a_logcon_flush();
    posix_spawnattr_t a; posix_spawn_file_actions_t fa; int rc;
    if ((rc = posix_spawnattr_init(&a))) goto out;
    if ((rc = posix_spawn_file_actions_init(&fa))) { posix_spawnattr_destroy(&a); goto out; }
    rc = posix_spawnattr_setflags(&a, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT);
    for (int fd = 0; !rc && fd <= 2; fd++) rc = posix_spawn_file_actions_addinherit_np(&fa, fd);
    if (!rc) rc = posix_spawn(NULL, exe, &fa, &a, *_NSGetArgv(), *_NSGetEnviron());   // 成功不返回（本进程换成新映像）
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&a);
out:
    LOG("【红】即时存档恢复：原地重新起这一局失败（errno %d），这一局照常继续；快照还在", rc);
    unsetenv("S2A_SNAP_RESTORE"); unsetenv("S2A_SNAP_SAVE_ROLLBACK");
    if (sat) setenv("S2A_SNAP_AT", sat, 1);
    if (srat) setenv("S2A_SNAP_RESTART_AT", srat, 1);
    free(sat); free(srat);
    return rc ? rc : -1;
}
#else
int s2a_snap_relaunch(const char *dir, int rollback) { (void)dir; (void)rollback; return -1; }   // iPhone / 安卓不能重新执行自己：iPhone 走游戏库恢复（ios/vpad.m）
#endif
