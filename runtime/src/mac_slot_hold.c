// 本机用显卡的活一本账：宿主自己拿 Mac 局槽（11-07 维护者）。只 macOS 宿主编进去；iOS / 安卓整个文件空。
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include "native.h"
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>
#include <limits.h>
#include <sys/wait.h>
extern char **environ;
// 本机用显卡的活一本账（11-07 维护者：09:48 本机显卡驱动 panic 时有个 1.6 GB 的 s2arm-host 不经 Mac 局槽直接起，属主查不到）：
//   起局 / 帧回放前宿主自己拿槽——调运行区仲裁副本的 hold 模式（维护方工具，规则只在那一份）替本进程排队；排满上限（S2A_MAC_SLOT_WAIT_S，
//   缺省 1800 秒）记【红】退 75、不起局。只在我方机器生效（运行区 s2arm/env/layout.env 在，判据同 tools/s2a_machine.sh；或显式 S2A_MAC_SLOT_BIN），
//   玩家机 / 单机不碰。调用方已拿着槽（S2A_MAC_SLOT_HELD=1：维护方工具 run / prio、runtime/run_mac.sh）不重复拿。
//   不拿的：出包期工具模式（Oodle / GLSLC，不碰显卡）、只解包、管线归档收集（出包期）。槽在进程退出时删（atexit）；被杀则下一个拿槽的人按 kill -0 收回
static char g_mac_slot[1024];
/* token：维护方工具 的令牌文件（0ffb77921 起）；不删则 rmdir 失败、槽漏到持有者死后才被收回 */
static void mac_slot_drop(void) { if (!g_mac_slot[0]) return; char h[1100]; snprintf(h, sizeof h, "%s/holder", g_mac_slot); unlink(h); snprintf(h, sizeof h, "%s/token", g_mac_slot); unlink(h); rmdir(g_mac_slot); g_mac_slot[0] = 0; }
// 快照恢复原地重开本进程（snaprelaunch.c，同一个 pid）之前调：槽是按 pid 记的持有者，新映像再去排队就是自己等自己（11-22 本机实测卡在「排队拿槽」）。
//   拿着槽就告诉新映像「已拿着」（S2A_MAC_SLOT_HELD=1）；槽随这个 pid 结束由仲裁脚本收（ms_busy 按持有者死活清）
void s2a_mac_slot_keep_across_exec(void) { if (g_mac_slot[0]) setenv("S2A_MAC_SLOT_HELD", "1", 1); }
void s2a_mac_slot_hold(const char *what) {
    const char *held = getenv("S2A_MAC_SLOT_HELD"), *rr = getenv("S2A_RUN_ROOT"), *home = getenv("HOME"), *b = getenv("S2A_MAC_SLOT_BIN");
    if (held && *held == '1') return;
    char root[900], bin[1024], le[1024], pid[16], nm[300], out[1024]; size_t got = 0; ssize_t r; int fd[2], st = 0; pid_t c;
    if (rr && *rr) strlcpy(root, rr, sizeof root); else snprintf(root, sizeof root, "%s/.s2arm/run", home ? home : "");
    if (b && *b) strlcpy(bin, b, sizeof bin);
    else {   // 仲裁副本按 layout.env 的真实路径找：运行区可以是逐项软链到真运行区的镜像（11-11 本机 ~/.s2arm/run/s2arm/env → ~/nx2ios/run/s2arm/env，
             //   bin 却是镜像里另建的真目录，按镜像拼路径找不到 mac_slot-now.sh，帧回放 / 直接起宿主一律报红退出）
        snprintf(le, sizeof le, "%s/s2arm/env/layout.env", root); if (access(le, F_OK)) return;
        char real[PATH_MAX], *e; if (realpath(le, real) && (e = strstr(real, "/env/layout.env")) && !e[15]) *e = 0; else snprintf(real, sizeof real, "%s/s2arm", root);
        snprintf(bin, sizeof bin, "%s/bin/mac_slot-now.sh", real); }
    if (access(bin, R_OK)) die("【红】Mac 局槽：我方机器缺运行区仲裁副本 %s，不起局", bin);
    snprintf(pid, sizeof pid, "%d", (int)getpid()); snprintf(nm, sizeof nm, "s2arm-host %s", what);
    if (pipe(fd)) die("【红】Mac 局槽：pipe 失败（errno %d）", errno);
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fd[1], 1); posix_spawn_file_actions_addclose(&fa, fd[0]); posix_spawn_file_actions_addclose(&fa, fd[1]);
    char *av[] = {"bash", bin, "hold", pid, nm, NULL};
    int e = posix_spawnp(&c, "bash", &fa, NULL, av, environ); posix_spawn_file_actions_destroy(&fa); close(fd[1]);
    if (e) { close(fd[0]); die("【红】Mac 局槽：起不了 bash（%d）", e); }
    LOG("Mac 局槽：%s 排队拿槽（本机用显卡的活上限见 tools/mac_slot.sh）", nm);
    while (got < sizeof out - 1 && (r = read(fd[0], out + got, sizeof out - 1 - got)) > 0) got += (size_t)r;
    close(fd[0]); out[got] = 0; while (got && (out[got - 1] == '\n' || out[got - 1] == '\r')) out[--got] = 0;
    while (waitpid(c, &st, 0) < 0 && errno == EINTR) {}
    if (!WIFEXITED(st) || WEXITSTATUS(st) || !got) {
        LOG("【红】Mac 局槽：%s 没拿到槽（hold 退出 %d；排队上限 S2A_MAC_SLOT_WAIT_S，缺省 1800 秒），不起局", nm, WIFEXITED(st) ? WEXITSTATUS(st) : -1);
        exit(75); }
    strlcpy(g_mac_slot, out, sizeof g_mac_slot); atexit(mac_slot_drop);
    LOG("Mac 局槽：%s 拿到 %s", nm, g_mac_slot);
    BOOT_MARK("等 Mac 局槽（只在我方机器排队）");   // 排队单独成一段：不打这行，排队时间全算进下一段「服务：C# 运行时起」，被读成运行时首启慢（11-18）
}
#endif
