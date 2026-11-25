// 帧率上限取值（graphics/nvn/gfx/nvn/nvn_fps.c，直连三后端与浮层共用的口径）。期望值全部手算。
//   ① 纯函数 nvn_fps_parse：0、24–1000 的十进制整数认；其它（空、负号、空格、尾随字符、越界、前导 + 号）不认
//   ② 起局读环境一次：每个取值单独起一个子进程，坏值必须退出（abort），好值的周期 = max(原周期, 1/上限)
//   负对照：把 nvn_fps_parse 改回只认 0/30/60/120，① 的 144 / 165 / 240 / 24 / 1000 与 ② 的 144 起局都应红
#include "../gfx/nvn/nvn_fps.h"
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// 桩（11-25 #502）：帧率被补丁抬高了没有——子进程环境 T_RAISED=0 / 1，缺省 1（原有 ② 判上限本身，照旧按抬高了算）
int s2a_fps_raised(void) { const char *e = getenv("T_RAISED"); return !e || *e != '0'; }
static int g_bad, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_bad++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static char g_exe[4096];

static int env_self(const char *v) {
    if (v) setenv("S2A_FPS", v, 1); else unsetenv("S2A_FPS");
    printf("limit=%d p0=%.9f p60=%.9f\n", nvn_fps_limit(), nvn_fps_period(0), nvn_fps_period(1.0 / 60));
    return 0;
}
static int env_probe(const char *v, int *limit, double *p0, double *p60) {
    int fd[2]; if (pipe(fd)) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        close(fd[0]); dup2(fd[1], STDOUT_FILENO); close(fd[1]);
        int null = open("/dev/null", O_WRONLY); if (null >= 0) dup2(null, STDERR_FILENO);
        char *a[4] = {"t_nvn_fps", "--env", (char *)v, NULL};
        execv(g_exe, a); _exit(97);
    }
    close(fd[1]); char buf[256] = {0}; ssize_t n = read(fd[0], buf, sizeof buf - 1); close(fd[0]);
    int st = 0; waitpid(pid, &st, 0);
    if (n <= 0 || !WIFEXITED(st) || WEXITSTATUS(st)) return -1;
    return sscanf(buf, "limit=%d p0=%lf p60=%lf", limit, p0, p60) == 3 ? 0 : -1;
}
static void env_ok(const char *v, int el, double ep0, double ep60) {
    int l = -9; double p0 = -9, p60 = -9; int rc = env_probe(v, &l, &p0, &p60);
    CHECK(rc == 0 && l == el && fabs(p0 - ep0) < 1e-9 && fabs(p60 - ep60) < 1e-9,
          "起局 S2A_FPS=%s：期望 上限%d 周期(0)=%.6f 周期(1/60)=%.6f；实得 返回%d 上限%d %.6f %.6f", v ? v : "（未设）", el, ep0, ep60, rc, l, p0, p60);
}
static void env_dies(const char *v) {
    int l; double a, b;
    CHECK(env_probe(v, &l, &a, &b) == -1, "起局 S2A_FPS=%s：坏值必须退出", v);
}

int main(int argc, char **argv) {
    if (!realpath(argv[0], g_exe)) snprintf(g_exe, sizeof g_exe, "%s", argv[0]);
    if (argc >= 2 && !strcmp(argv[1], "--env")) return env_self(argc >= 3 ? argv[2] : NULL);
    if (argc >= 4 && !strcmp(argv[1], "--mx")) {   // ③ 子进程：S2A_FPS=<argv2>、T_RAISED=<argv3>，打印游戏周期 1/30、1/60 的生效周期
        if (strcmp(argv[2], "-")) setenv("S2A_FPS", argv[2], 1); else unsetenv("S2A_FPS");
        setenv("T_RAISED", argv[3], 1); printf("%.9f %.9f\n", nvn_fps_period(1.0 / 30), nvn_fps_period(1.0 / 60)); return 0; }
    if (argc >= 2 && !strcmp(argv[1], "--rs")) {   // ④ 子进程：同一进程里起局 30，再三次「进程内重启」各换一次环境后重读，打印四次读数
        setenv("S2A_FPS", "30", 1); int a0 = nvn_fps_limit_set();
        setenv("S2A_FPS", "0", 1); nvn_fps_session_reset(); int a1 = nvn_fps_limit_set();
        setenv("S2A_FPS", "60", 1); nvn_fps_session_reset(); int a2 = nvn_fps_limit_set();
        unsetenv("S2A_FPS"); nvn_fps_session_reset(); int a3 = nvn_fps_limit_set();
        printf("%d %d %d %d\n", a0, a1, a2, a3); return 0; }

    // ①
    static const struct { const char *v; int e; } P[] = {
        {"0", 0}, {"30", 30}, {"60", 60}, {"120", 120}, {"24", 24}, {"144", 144}, {"165", 165}, {"240", 240}, {"1000", 1000}, {"075", 75},
        {"", -1}, {"23", -1}, {"1001", -1}, {"-1", -1}, {"+60", -1}, {" 60", -1}, {"60 ", -1}, {"30abc", -1}, {"display", -1}, {"00000060", -1}, {"9999", -1},
    };
    for (size_t i = 0; i < sizeof P / sizeof *P; i++) {
        int got = nvn_fps_parse(P[i].v);
        CHECK(got == P[i].e, "nvn_fps_parse(\"%s\")：期望 %d，实得 %d", P[i].v, P[i].e, got);
    }
    CHECK(nvn_fps_parse(NULL) == -1, "nvn_fps_parse(NULL)：期望 -1");

    // ② 周期：上限只把周期拉长；60 帧的周期在 ≥ 60 的上限下原样
    env_ok(NULL, 0, 0, 1.0 / 60);
    env_ok("0", 0, 0, 1.0 / 60);
    env_ok("30", 30, 1.0 / 30, 1.0 / 30);
    env_ok("120", 120, 1.0 / 120, 1.0 / 60);
    env_ok("144", 144, 1.0 / 144, 1.0 / 60);
    env_ok("24", 24, 1.0 / 24, 1.0 / 24);
    env_ok("1000", 1000, 1.0 / 1000, 1.0 / 60);
    env_dies("12");
    env_dies("30abc");
    env_dies("1001");

        // ③ 玩家上限只压补丁抬上去的那部分（11-25 #502：原生 60、无补丁的款，上限 30 → 半速慢动作）。期望（手算，秒）：
    //   原生 30（没抬高、游戏周期 1/30）：上限 30 → 1/30，不限 → 1/30；原生 60（没抬高、1/60）：上限 30 → 1/60（不压），不限 → 1/60；
    //   补丁 60（抬高了、1/60）：上限 30 → 1/30，不限 → 1/60。旧码（不看抬高）原生 60 × 上限 30 得 1/30 = 慢
    { static const struct { const char *cls; int game; const char *raised, *cap; double want; } M[] = {
        {"原生30", 30, "0", "30", 1.0 / 30}, {"原生30", 30, "0", "-", 1.0 / 30}, {"原生60", 60, "0", "30", 1.0 / 60}, {"原生60", 60, "0", "-", 1.0 / 60},
        {"补丁60", 60, "1", "30", 1.0 / 30}, {"补丁60", 60, "1", "-", 1.0 / 60} };
      for (size_t i = 0; i < sizeof M / sizeof *M; i++) {
        int fd[2]; if (pipe(fd)) { CHECK(0, "③ pipe"); continue; }
        pid_t pid = fork();
        if (pid == 0) { close(fd[0]); dup2(fd[1], STDOUT_FILENO); close(fd[1]); int null = open("/dev/null", O_WRONLY); if (null >= 0) dup2(null, STDERR_FILENO);
            char *a[5] = {"t_nvn_fps", "--mx", (char *)M[i].cap, (char *)M[i].raised, NULL}; execv(g_exe, a); _exit(97); }
        close(fd[1]); char buf[128] = {0}; ssize_t n = read(fd[0], buf, sizeof buf - 1); close(fd[0]); int st = 0; waitpid(pid, &st, 0);
        double p30 = -1, p60 = -1; if (n > 0) sscanf(buf, "%lf %lf", &p30, &p60);
        double got = M[i].game == 30 ? p30 : p60;
        CHECK(fabs(got - M[i].want) < 1e-9, "③ %s × 上限 %s：期望周期 %.6f，实得 %.6f", M[i].cls, strcmp(M[i].cap, "-") ? M[i].cap : "不限", M[i].want, got);
      } }
    // ④ 进程内重启重读（#502 D-XTV7：设置 30 → 60 → 不限各点一次「立即重启」，旧码整个进程仍按 30）。期望（手算）：30 0 60 0；旧码（只读一次）30 30 30 30
    { int fd[2]; if (pipe(fd)) CHECK(0, "④ pipe"); else {
        pid_t pid = fork();
        if (pid == 0) { close(fd[0]); dup2(fd[1], STDOUT_FILENO); close(fd[1]); int null = open("/dev/null", O_WRONLY); if (null >= 0) dup2(null, STDERR_FILENO);
            char *a[3] = {"t_nvn_fps", "--rs", NULL}; execv(g_exe, a); _exit(97); }
        close(fd[1]); char buf[128] = {0}; ssize_t n = read(fd[0], buf, sizeof buf - 1); close(fd[0]); int st = 0; waitpid(pid, &st, 0);
        int r[4] = {-1, -1, -1, -1}; if (n > 0) sscanf(buf, "%d %d %d %d", &r[0], &r[1], &r[2], &r[3]);
        CHECK(r[0] == 30 && r[1] == 0 && r[2] == 60 && r[3] == 0, "④ 进程内重启重读：期望 30 0 60 0，实得 %d %d %d %d", r[0], r[1], r[2], r[3]);
    } }
    printf("%s t_nvn_fps：帧率上限取值 %d 项 → %s\n", g_bad ? "✗" : "✓", g_n, g_bad ? "有不符合项" : "全过");   // 放最后：③ ④ 也算进来（原先在 ③ 之前打，后面红了这行仍是「全过」）
    return g_bad != 0;
}
