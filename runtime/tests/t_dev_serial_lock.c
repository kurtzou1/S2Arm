// 开发机 Mac 局串行锁（runtime/src/dev_serial_lock.h）。期望手写：
//   ① 没有 $HOME/.s2arm/mac_game_lock → 返回 0、不等；② 配置了：第一个进程拿到（1），第二个进程同时起 → 要等第一个退出（等待 ≥ 1 秒、返回 2）；
//   ③ S2A_MAC_GAME_LOCK_HELD=1 → 返回 0（外层已持）；④ 锁文件打不开 → -1、不等；
//   ⑤ 第一个局持锁期间，宿主工具模式（DM_OODLE_SERVE=1 / DM_OODLE_JOB=<文件> / DM_GLSLC_JOB=<文件>）的进程不取锁 → 返回 0、当场返回（不是 2）
#include "../src/dev_serial_lock.h"
#include "s2a_t_result.h"
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
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
    setenv("S2A_MAC_GAME_LOCK_HELD", "1", 1);
    CHECK(s2a_dev_serial_lock() == 0, "③ 外层已持 → 0");
    unsetenv("S2A_MAC_GAME_LOCK_HELD");
    f = fopen(cfg, "w"); fprintf(f, "/没有这个目录/x.flock\n"); fclose(f);
    t0 = now();
    CHECK(s2a_dev_serial_lock() == -1, "④ 锁文件打不开 → -1、不等");   // 打不开就拿不到锁、无从等起：判返回值，不用墙钟 < 1 秒
    (void)t0;
    return S2A_T_RESULT("t_dev_serial_lock", fails);
}
