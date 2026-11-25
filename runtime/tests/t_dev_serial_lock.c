// 开发机 Mac 局串行锁（runtime/src/dev_serial_lock.h）。期望手写：
//   ① 没有 $HOME/.s2arm/mac_game_lock → 返回 0、不等；② 配置了：第一个进程拿到（1），第二个进程同时起 → 要等第一个退出（返回 2；第一个局持锁到第二个已在排队循环里才放行）；
//   ③ S2A_MAC_GAME_LOCK_HELD=1 → 返回 0（外层已持）；④ 锁文件打不开 → -1、不等；
//   ⑥ 反证：持锁进程正常活着（真探测：不在退出中）、阈值 1 秒，排队者第一次探到后再等 ≥ 2 秒才放行 → 不轮换，等它退出才拿到（2），没有 .stuck 文件；
//   ⑦ 持锁进程卡在退出中（注入探测判它在退出中）、阈值 1 秒 → 轮换锁后拿到（3），旧锁改名 <锁>.stuck-<pid>，报警文件多一行点名 pid；持锁进程还活着也不影响
//   ⑧ 真探测：正常 sleep 的进程、本进程都判「不在退出中」
//   ⑤ 第一个局持锁期间，宿主工具模式（DM_OODLE_SERVE=1 / DM_OODLE_JOB=<文件> / DM_GLSLC_JOB=<文件>）的进程不取锁 → 返回 0、当场返回（不是 2）
#include <sys/types.h>
static int t_exiting(pid_t pid);
#define S2A_DSL_EXITING(pid) t_exiting(pid)
#include "../src/dev_serial_lock.h"
static pid_t t_fake_exiting;   // 注入：这个 pid 判「在退出中」，其余走真探测
static int t_probe_fd = -1;   // 排队者每探一次持锁进程就往这里写一个字节：父进程据此确认「它已在排队循环里」（事件判据，不靠墙钟）
static int t_exiting(pid_t pid) {
    if (t_probe_fd >= 0) { char c = 'p'; (void)!write(t_probe_fd, &c, 1); }
    return pid == t_fake_exiting ? 1 : s2a_dsl_exiting(pid);
}
#include "s2a_t_result.h"
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <signal.h>
#include <poll.h>
#ifndef T_PROBE_WAIT_S
#define T_PROBE_WAIT_S 120   // 兜底：排队者这么久都没探过持锁进程 = 排队循环没在跑（如退回成阻塞在 flock 上），当场报红，不等门禁步墙钟上限
#endif
// 等排队者的一次探测：1 收到、0 排队者已退出（EOF）、-1 兜底超时
static int t_probe_wait(int fd) {
    struct pollfd q = {fd, POLLIN, 0};
    if (poll(&q, 1, T_PROBE_WAIT_S * 1000) <= 0) return -1;
    char c; return read(fd, &c, 1) == 1 ? 1 : 0;
}
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
    int p[2], rel[2], probe[2], probe6[2]; if (pipe(p) || pipe(rel) || pipe(probe) || pipe(probe6)) return 2;   // probe6 单给 ⑥：② 的排队者退出前可能多探几次，余字节不能串进 ⑥
    pid_t a = fork();
    if (a == 0) { close(probe[1]); close(probe6[1]); int r = s2a_dev_serial_lock(); char c = (char)('0' + r); write(p[1], &c, 1); read(rel[0], &c, 1); _exit(0); }   // 第一个局：持锁到父进程放行
    char got; read(p[0], &got, 1);
    CHECK(got == '1', "② 第一个局当场拿到（%c）", got);
    double t0 = now();
    pid_t b = fork();
    if (b == 0) { close(probe6[1]); t_probe_fd = probe[1]; int r = s2a_dev_serial_lock(); _exit(r); }                                                            // 第二个局同时起
    static const char *const tool[][2] = {{"DM_OODLE_SERVE", "1"}, {"DM_OODLE_JOB", "/tmp/x.job"}, {"DM_GLSLC_JOB", "/tmp/x.glslcjob"}};
    for (int i = 0; i < 3; i++) {                                                                                      // ⑤ 局持锁时起工具宿主：都不排队
        pid_t c = fork();
        if (c == 0) { setenv(tool[i][0], tool[i][1], 1); _exit(s2a_dev_serial_lock()); }
        int sc; waitpid(c, &sc, 0);
        CHECK(WIFEXITED(sc) && WEXITSTATUS(sc) == 0, "⑤ 局持锁时工具模式（%s）不取锁、当场返回 0（实 %d）", tool[i][0], WEXITSTATUS(sc));
    }
    close(probe[1]);   // 写端只留给排队者：它提前退出（产品回归）时这里读到 EOF，不会卡死
    if (t_probe_wait(probe[0]) < 0) {
        CHECK(0, "② 排队者 %d 秒内没探过持锁进程（排队循环没在跑）", T_PROBE_WAIT_S);
        kill(b, SIGKILL); kill(a, SIGKILL); waitpid(b, NULL, 0); waitpid(a, NULL, 0);
        return S2A_T_RESULT("t_dev_serial_lock", fails);
    }
    write(rel[1], "r", 1);   // 第二个局已在排队循环里探过持锁进程 → 放第一个局退出
    int st; waitpid(b, &st, 0); double w = now() - t0;
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 2, "② 第二个局等第一个退出才拿到（返回 %d = 等过才拿到，等了 %.1f 秒）", WEXITSTATUS(st), w);   // 返回 2 由产品表明「等过」，不再用墙钟 ≥ 1 秒判（负载高时父进程取 t0 晚 → 假红）
    waitpid(a, &st, 0);
    // ⑥⑦ 持锁进程状态与锁轮换
    char alarm[1300], stuck[1400]; snprintf(alarm, sizeof alarm, "%s/alarm.log", home);
    f = fopen(cfg, "w"); fprintf(f, "%s\n%s\n", lk, alarm); fclose(f);
    setenv("S2A_MAC_LOCK_EXIT_STUCK_S", "1", 1);
    pid_t h = fork();
    if (h == 0) { close(probe6[1]); s2a_dev_serial_lock(); write(p[1], "h", 1); read(rel[0], &got, 1); _exit(0); }   // ⑥ 正常跑的长局：持锁到父进程放行
    read(p[0], &got, 1);
    pid_t w6 = fork();
    if (w6 == 0) { t_probe_fd = probe6[1]; _exit(s2a_dev_serial_lock()); }
    close(probe6[1]);
    // 排队者第一次探到持锁进程后，再继续收它的探测、直到离第一次 ≥ 2 秒（阈值 1 秒 + 1 秒余量）才放行持锁进程：
    //   期间每次探测都判「不在退出中」，越过阈值也不该轮换。按时间而不是按探测次数凑够阈值，产品轮询间隔改了也不会绿着失效；
    //   这只是放行前的最短等待，负载高只会等得更久，不作判据
    double t6 = 0;
    int pw;
    while ((pw = t_probe_wait(probe6[0])) == 1) { if (!t6) t6 = now(); else if (now() - t6 >= 2.0) break; }
    if (pw < 0) {
        CHECK(0, "⑥ 排队者 %d 秒内没探过持锁进程（排队循环没在跑）", T_PROBE_WAIT_S);
        kill(w6, SIGKILL); kill(h, SIGKILL); waitpid(w6, NULL, 0); waitpid(h, NULL, 0);
        return S2A_T_RESULT("t_dev_serial_lock", fails);
    }
    write(rel[1], "r", 1);
    waitpid(w6, &st, 0);
    snprintf(stuck, sizeof stuck, "%s.stuck-%ld", lk, (long)h);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 2 && access(stuck, F_OK) != 0, "⑥ 反证：持锁进程正常活着 → 不轮换、等它退出才拿到（返回 %d，.stuck 文件%s）",
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
