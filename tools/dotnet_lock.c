// 同一棵树的 C# 编译串行（门禁用，tools/gate.sh 开头现编到 $L/bin/dotnet，各步 DOTNET 与 PATH 都指它）：
//   编译类子命令（build / publish / restore / pack / msbuild / test / clean）先拿 <仓库>/build/.dotnet_build.lock 的内核文件锁，
//   再 fork 子进程 exec 真 dotnet，锁只留在本进程（打开时带 O_CLOEXEC，子进程不继承），子进程退出即放锁、退出码原样传回；
//   其余子命令（dotnet x.dll …）直接 exec。收到 TERM / INT / HUP 转给子进程。
//   为什么不 exec 后让 dotnet 自己攥着锁（11-11 门禁机挂死）：dotnet build 会拉起常驻的 Roslyn 编译服务 VBCSCompiler
//   （MSBUILDDISABLENODEREUSE 只关 MSBuild 节点、关不了它），它继承锁的文件描述符、构建结束后不退，锁一直不放，
//   之后每份 build 都卡在等锁（CPU 0、被无进展看门狗判挂死），graphics/gate.sh 在门禁机上连挂两次。
//   为什么是 C 不是脚本（11-11）：脚本解释器 /bin/bash 受 SIP 保护，启动时清掉 DYLD_* 环境变量——services/tests/t_native_provider.sh
//   用 env DYLD_INSERT_LIBRARIES=… "$DOTNET" 注入原生符号，经脚本包装一层就丢了、服务层单测红。编出来的程序不受 SIP 限制，DYLD_* 原样传给真 dotnet。
//   关 MSBuild 常驻节点（MSBUILDDISABLENODEREUSE=1：常驻节点构建后仍攥着输出文件）；等锁每 30 秒打一行（免被无进展看门狗判挂死）。
//   真 dotnet：S2A_DOTNET_REAL，没给就找 ~/.dotnet/dotnet、再按 PATH 找（跳过自己）；锁文件：S2A_DOTNET_LOCK（tools/gate.sh 给，缺省不拿锁）
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const char *find_real(const char *self, char *out) {
    char me[PATH_MAX], c[PATH_MAX], r[PATH_MAX]; const char *home = getenv("HOME"), *path = getenv("PATH");
    if (!realpath(self, me)) { if (strchr(self, '/')) return NULL; me[0] = 0; }
    if (home) { snprintf(c, sizeof c, "%s/.dotnet/dotnet", home); if (access(c, X_OK) == 0 && realpath(c, r) && strcmp(r, me)) { snprintf(out, PATH_MAX, "%s", c); return out; } }
    for (const char *p = path; p && *p; ) {
        const char *e = strchr(p, ':'); size_t n = e ? (size_t)(e - p) : strlen(p);
        snprintf(c, sizeof c, "%.*s/dotnet", (int)n, p);
        if (n && access(c, X_OK) == 0 && realpath(c, r) && (!me[0] || strcmp(r, me))) { snprintf(out, PATH_MAX, "%s", c); return out; }
        p = e ? e + 1 : NULL; }
    return NULL; }

static volatile pid_t g_child;
static void forward(int sig) { if (g_child > 0) kill(g_child, sig); }

int main(int argc, char **argv) {
    const char *real = getenv("S2A_DOTNET_REAL"), *lk = getenv("S2A_DOTNET_LOCK");
    // 调用方用 env -i 只传 DOTNET（如启动器作业环境的单测）时 S2A_DOTNET_REAL 不在：自己找真 dotnet——~/.dotnet/dotnet，再按 PATH 找（跳过自己）
    static char found[PATH_MAX];
    if (!real || !*real) real = find_real(argv[0], found);
    if (!real) { fprintf(stderr, "dotnet_lock：找不到真 dotnet（没有 S2A_DOTNET_REAL、~/.dotnet/dotnet，PATH 里也没有别的 dotnet）\n"); return 127; }
    setenv("MSBUILDDISABLENODEREUSE", "1", 1);
    static const char *verbs[] = { "build", "publish", "restore", "pack", "msbuild", "test", "clean", NULL };
    int build = 0;
    for (int i = 0; argc > 1 && verbs[i]; i++) if (!strcmp(argv[1], verbs[i])) build = 1;
    // 编译并发封顶（11-13 维护者机器风扇狂转：dotnet build 不带 -m 时 dotnet 自己补「-maxcpucount」= 全部核，编一个 romfs_index 拉起 17 个 MSBuild 节点、瞬时约 11 核；
    //   根目录 Directory.Build.rsp 压不住——命令行里的 -maxcpucount 优先）：编译类子命令没自己给 -m 的，紧跟子命令补 -m:<S2A_DOTNET_M，缺省 4>（0 = 不补）。
    //   实测 romfs_index 全量编：节点 17 → 3，用时 11 → 8 秒（节点多反而慢）。调用方显式给了 -m / -maxcpucount 的（如 t_dsh.sh 按 DSH_J）原样不动
    static char mopt[32]; const char *mn = getenv("S2A_DOTNET_M"); if (!mn || !*mn) mn = "4";
    if (build && strcmp(argv[1], "restore") && strcmp(mn, "0")) {
        int has = 0;
        for (int i = 2; i < argc && !has; i++) {
            const char *a = argv[i];
            if (!strcmp(a, "--")) break;
            if (*a == '-' || *a == '/') { a += (a[0] == '-' && a[1] == '-') ? 2 : 1;
                if (!strncasecmp(a, "maxcpucount", 11) || (tolower((unsigned char)a[0]) == 'm' && (a[1] == 0 || a[1] == ':'))) has = 1; }
        }
        if (!has) {
            snprintf(mopt, sizeof mopt, "-m:%s", mn);
            char **nv = calloc((size_t)argc + 2, sizeof *nv);
            if (nv) { nv[0] = argv[0]; nv[1] = argv[1]; nv[2] = mopt; for (int i = 2; i < argc; i++) nv[i + 1] = argv[i]; nv[argc + 1] = NULL; argv = nv; argc++; }
        }
    }
    int locked = 0;
    if (build && lk && *lk) {
        int fd = open(lk, O_RDWR | O_CREAT | O_CLOEXEC, 0644);   // 子进程（真 dotnet 及它拉起的常驻编译服务）不继承
        if (fd >= 0) {
            time_t t0 = time(NULL), last = t0;
            while (!(locked = flock(fd, LOCK_EX | LOCK_NB) == 0)) {
                if (errno != EWOULDBLOCK && errno != EINTR) break;   // 锁不可用（文件系统不支持等）：不拿锁照跑
                time_t now = time(NULL);
                if (now - last >= 30) { last = now; fprintf(stderr, "等本树 C# 构建锁（%s）已 %ld 秒：别的步正在编 C#\n", lk, (long)(now - t0)); }
                usleep(200000);
            }
            if (time(NULL) - t0 >= 2) fprintf(stderr, "C# 构建锁：等了 %ld 秒\n", (long)(time(NULL) - t0));
        }
    }
    argv[0] = (char *)real;
    if (locked) {
        pid_t pid = fork();
        if (pid == 0) { execv(real, argv); fprintf(stderr, "dotnet_lock：起不来 %s（%s）\n", real, strerror(errno)); _exit(127); }
        if (pid > 0) {
            g_child = pid;
            struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = forward;
            sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
            int st = 0;
            while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
            if (WIFEXITED(st)) return WEXITSTATUS(st);
            if (WIFSIGNALED(st)) { signal(WTERMSIG(st), SIG_DFL); raise(WTERMSIG(st)); return 128 + WTERMSIG(st); }
            return 1;
        }
        // fork 失败：照旧 exec（锁的 fd 带 CLOEXEC，exec 后放掉——这一份不串行，好过不跑）
    }
    execv(real, argv);
    fprintf(stderr, "dotnet_lock：起不来 %s（%s）\n", real, strerror(errno));
    return 127;
}
