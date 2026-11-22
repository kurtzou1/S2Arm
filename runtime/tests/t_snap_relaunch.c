// t_snap_relaunch：Mac 进程内接不上快照时原地重新执行自己（runtime/src/snaprelaunch.c s2a_snap_relaunch）。期望手写：
//   ① 相对路径不执行、回非 0，环境不留 S2A_SNAP_RESTORE
//   ② 绝对路径：本进程换成新映像（同一个 pid），新映像里 S2A_SNAP_RESTORE = 给的路径、S2A_SNAP_SAVE_ROLLBACK = 1（rollback = 1）、
//      一次性测试开关 S2A_SNAP_AT / S2A_SNAP_RESTART_AT 已去掉、调用前开着的 fd 9（不带 CLOEXEC）已关、标准输出照旧能写
//   反证：去掉 POSIX_SPAWN_CLOEXEC_DEFAULT → ② 的 fd 9 还开着、红；去掉 POSIX_SPAWN_SETEXEC → pid 不同、红
#include "../src/native.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int s2a_snap_relaunch(const char *dir, int rollback);
static int eqs(const char *a, const char *b) { return a && b && !strcmp(a, b); }
int main(void) {
    const char *again = getenv("T_RELAUNCHED");
    if (again) {   // 新映像
        int bad = 0; char pid[32]; snprintf(pid, sizeof pid, "%d", (int)getpid());
        if (!eqs(again, pid)) { printf("✗ ② pid 变了（原 %s，现 %s）\n", again, pid); bad++; }
        if (!eqs(getenv("S2A_SNAP_RESTORE"), "/tmp/s2a_t_relaunch/snapshot")) { printf("✗ ② S2A_SNAP_RESTORE = %s\n", getenv("S2A_SNAP_RESTORE") ?: "空"); bad++; }
        if (!eqs(getenv("S2A_SNAP_SAVE_ROLLBACK"), "1")) { printf("✗ ② S2A_SNAP_SAVE_ROLLBACK 没带上\n"); bad++; }
        if (getenv("S2A_SNAP_AT") || getenv("S2A_SNAP_RESTART_AT")) { printf("✗ ② 一次性测试开关没去掉\n"); bad++; }
        if (fcntl(9, F_GETFD) != -1) { printf("✗ ② fd 9 带到了新映像\n"); bad++; }
        printf("%s t_snap_relaunch：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
    }
    if (!s2a_snap_relaunch("rel/snapshot", 0) || getenv("S2A_SNAP_RESTORE")) { printf("✗ ① 相对路径应拒绝、不留环境\n"); return 1; }
    printf("✓ ① 相对路径拒绝\n");
    char pid[32]; snprintf(pid, sizeof pid, "%d", (int)getpid()); setenv("T_RELAUNCHED", pid, 1);
    setenv("S2A_SNAP_AT", "30", 1); setenv("S2A_SNAP_RESTART_AT", "3", 1);
    int fd = open("/dev/null", O_RDONLY); if (fd < 0 || dup2(fd, 9) != 9) { printf("✗ 准备 fd 9 失败\n"); return 1; }
    fflush(stdout);
    s2a_snap_relaunch("/tmp/s2a_t_relaunch/snapshot", 1);
    printf("✗ ② 回来了：没换成新映像\n"); return 1;
}
