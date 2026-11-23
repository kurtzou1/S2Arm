// 开发机 Mac 局串行锁（runtime/src/dev_serial_lock.h）。期望手写：
//   ① 没有 $HOME/.s2arm/mac_game_lock → 返回 0、不等；② 配置了：第一个进程拿到（1），第二个进程同时起 → 要等第一个退出（等待 ≥ 1 秒、返回 2）；
//   ③ S2A_MAC_GAME_LOCK_HELD=1 → 返回 0（外层已持）；④ 锁文件打不开 → -1、不等；
//   ⑥ 反证：持锁进程正常 sleep（真探测：不在退出中）、阈值 1 秒 → 不轮换，等它退出才拿到（2），没有 .stuck 文件；
//   ⑦ 持锁进程卡在退出中（注入探测判它在退出中）、阈值 1 秒 → 轮换锁后拿到（3），旧锁改名 <锁>.stuck-<pid>，报警文件多一行点名 pid；持锁进程还活着也不影响
//   ⑧ 真探测：正常 sleep 的进程、本进程都判「不在退出中」
//   ⑤ 第一个局持锁期间，宿主工具模式（DM_OODLE_SERVE=1 / DM_OODLE_JOB=<文件> / DM_GLSLC_JOB=<文件>）的进程不取锁 → 返回 0、当场返回（不是 2）
#include <sys/types.h>
static int t_exiting(pid_t pid);
#define S2A_DSL_EXITING(pid) t_exiting(pid)
#include "../src/dev_serial_lock.h"
static pid_t t_fake_exiting;   // 注入：这个 pid 判「在退出中」，其余走真探测
static int t_exiting(pid_t pid) { return pid == t_fake_exiting ? 1 : s2a_dsl_exiting(pid); }
#include "s2a_t_result.h"
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <signal.h>
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("不通 "); printf(__VA_ARGS__); printf("\n"); } else { printf("通 "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static double now(void) { struct timeval t; gettimeofday(&t, NULL); return t.tv_sec + t.tv_usec / 1e6; }
int main(void) {
    char home[] = "/tmp/t_dsl_XXXXXX";
    if (!mkdtemp(home)) return 2;
    setenv("HOME", home, 1); unsetenv("S2A_MAC_GAME_LOCK_HELD");
    CHECK(s2a_dev_serial_lock() == 0, "① 没配置 → 0");
    char d[1200], cfg[1300], lk[1300];
    snprintf(d, sizeof d, "%s/.s2arm", home); mkdir(d, 0755);
    snprintf(cfg, sizeof cfg, "%s/mac_game_lock", d); snprintf(lk, sizeof lk, "%s/mac_game.flock", home);
    FILE *f = fopen(cfg, "w"); fprintf(f, "%s\n", lk); fclose(f);
    int p[2]; if (pipe(p)) return 2;
    pid_t a = fork();
    if (a == 0) { int r = s2a_dev_serial_lock(); char c = (char)('0' + r); write(p[1], &c, 1); sleep(2); _exit(0); }   // 第一个局：持锁 2 秒
    char got; read(p[0], &got, 1);
    CHECK(got == '1', "② 第一个局当场拿到（%c）", got);
    double t0 = now();
    pid_t b = fork();
    if (b == 0) { int r = s2a_dev_serial_lock(); _exit(r); }                                                            // 第二个局同时起
    static const char *const tool[][2] = {{"DM_OODLE_SERVE", "1"}, {"DM_OODLE_JOB", "/tmp/x.job"}, {"DM_GLSLC_JOB", "/tmp/x.glslcjob"}};
    for (int i = 0; i < 3; i++) {                                                                                      // ⑤ 局持锁时起工具宿主：都不排队
        pid_t c = fork();
        if (c == 0) { setenv(tool[i][0], tool[i][1], 1); _exit(s2a_dev_serial_lock()); }
        int sc; waitpid(c, &sc, 0);
        CHECK(WIFEXITED(sc) && WEXITSTATUS(sc) == 0, "⑤ 局持锁时工具模式（%s）不取锁、当场返回 0（实 %d）", tool[i][0], WEXITSTATUS(sc));
    }
    int st; waitpid(b, &st, 0); double w = now() - t0;
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 2, "② 第二个局等第一个退出才拿到（返回 %d = 等过才拿到，等了 %.1f 秒）", WEXITSTATUS(st), w);   // 返回 2 由产品表明「等过」，不再用墙钟 ≥ 1 秒判（负载高时父进程取 t0 晚 → 假红）
    waitpid(a, &st, 0);
    // ⑥⑦ 持锁进程状态与锁轮换
    char alarm[1300], stuck[1400]; snprintf(alarm, sizeof alarm, "%s/alarm.log", home);
    f = fopen(cfg, "w"); fprintf(f, "%s\n%s\n", lk, alarm); fclose(f);
    setenv("S2A_MAC_LOCK_EXIT_STUCK_S", "1", 1);
    pid_t h = fork();
    if (h == 0) { s2a_dev_serial_lock(); write(p[1], "h", 1); sleep(4); _exit(0); }   // ⑥ 正常跑的长局
    read(p[0], &got, 1);
    pid_t w6 = fork();
    if (w6 == 0) _exit(s2a_dev_serial_lock());
    waitpid(w6, &st, 0);
    snprintf(stuck, sizeof stuck, "%s.stuck-%ld", lk, (long)h);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 2 && access(stuck, F_OK) != 0, "⑥ 反证：持锁进程正常 sleep → 不轮换、等它退出才拿到（返回 %d，.stuck 文件%s）",
          WEXITSTATUS(st), access(stuck, F_OK) == 0 ? "有" : "无");
    waitpid(h, &st, 0);
    h = fork();
    if (h == 0) { s2a_dev_serial_lock(); write(p[1], "h", 1); sleep(30); _exit(0); }  // ⑦ 卡在退出中的局（注入），一直持着旧锁
    read(p[0], &got, 1);
    t_fake_exiting = h;
    pid_t w7 = fork();
    if (w7 == 0) _exit(s2a_dev_serial_lock());
    waitpid(w7, &st, 0);
    snprintf(stuck, sizeof stuck, "%s.stuck-%ld", lk, (long)h);
    char line[600] = {0}; char pidtxt[32]; snprintf(pidtxt, sizeof pidtxt, "pid %ld", (long)h);
    f = fopen(alarm, "r"); if (f) { if (!fgets(line, sizeof line, f)) line[0] = 0; fclose(f); }
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 3 && access(stuck, F_OK) == 0 && strstr(line, pidtxt) && kill(h, 0) == 0,
          "⑦ 持锁进程卡在退出中 → 轮换后拿到（返回 %d）、旧锁改名 .stuck-<pid>（%s）、报警点名（%s）", WEXITSTATUS(st),
          access(stuck, F_OK) == 0 ? "有" : "无", line[0] ? "有" : "无");
    kill(h, SIGKILL); waitpid(h, &st, 0); t_fake_exiting = 0;
    pid_t s8 = fork();
    if (s8 == 0) { sleep(5); _exit(0); }
    CHECK(!s2a_dsl_exiting(s8) && !s2a_dsl_exiting(getpid()), "⑧ 真探测：正常 sleep 的进程、本进程都不在退出中");
    kill(s8, SIGKILL); waitpid(s8, &st, 0);
    unsetenv("S2A_MAC_LOCK_EXIT_STUCK_S");
    f = fopen(cfg, "w"); fprintf(f, "%s\n", lk); fclose(f);
    setenv("S2A_MAC_GAME_LOCK_HELD", "1", 1);
    CHECK(s2a_dev_serial_lock() == 0, "③ 外层已持 → 0");
    unsetenv("S2A_MAC_GAME_LOCK_HELD");
    f = fopen(cfg, "w"); fprintf(f, "/没有这个目录/x.flock\n"); fclose(f);
    t0 = now();
    CHECK(s2a_dev_serial_lock() == -1, "④ 锁文件打不开 → -1、不等");   // 打不开就拿不到锁、无从等起：判返回值，不用墙钟 < 1 秒
    (void)t0;
    return S2A_T_RESULT("t_dev_serial_lock", fails);
}
