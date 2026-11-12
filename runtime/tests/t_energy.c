// 能耗分账单测（runtime/src/energy.c）：审计 P1-85——按线程号记账的表 1024 格只增不删，进程内重启每局新建一批线程，
//   累计不同线程号满 1024 后找空位的 while 没有步数上限，主线程心跳（app.m 每 10 秒 s2a_energy_log）在这里转死。
// 期望手写：5 轮、每轮起 300 条线程（采样时都活着）、采一次、全部退出 = 1500 个不同线程号经过表；每一次采样都返回、写出一行。
//   旧实现第 4 轮满表后死循环，alarm 30 秒把它变成红（不是挂住）
#include "../src/native.h"
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>


static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_go, g_up;
static void *hold(void *a) {
    (void)a; pthread_mutex_lock(&g_mu); g_up++; pthread_cond_broadcast(&g_cv);
    while (!g_go) pthread_cond_wait(&g_cv, &g_mu);
    pthread_mutex_unlock(&g_mu); return NULL;
}
static void timeout(int s) { (void)s; static const char m[] = "✗ t_energy：采样 30 秒没返回（线程表满后死循环）\n"; write(1, m, sizeof m - 1); _exit(1); }

// GPU 忙 ms/s（#647）：分母是 GPU 时钟差、不是墙钟差。期望手写：0.2 秒墙钟里入账了 300 ms GPU 忙、GPU 时钟走了 500 ms（慢帧后补入账）→ 600 ms/s
//   （按墙钟是 1500，超过一条 GPU 时间线的物理上限）；没有直连层 / 时钟读不到 = -1；这段没有帧入账 = 0
static int busy_rate_cases(void) {
    struct { s2a_esnap a, b; double want; const char *what; } c[] = {
        { { .wall = 0, .ok_g = 1, .gpu_ms = 100, .gpu_clk_ms = 1000 }, { .wall = 200000000, .ok_g = 1, .gpu_ms = 400, .gpu_clk_ms = 1500 }, 600, "慢帧后补入账" },
        { { .wall = 0, .ok_g = 0 }, { .wall = 500000000, .ok_g = 0 }, -1, "没有直连层" },
        { { .wall = 0, .ok_g = 1, .gpu_ms = 5, .gpu_clk_ms = -1 }, { .wall = 500000000, .ok_g = 1, .gpu_ms = 9, .gpu_clk_ms = -1 }, -1, "时钟读不到" },
        { { .wall = 0, .ok_g = 1, .gpu_ms = 70, .gpu_clk_ms = 900 }, { .wall = 500000000, .ok_g = 1, .gpu_ms = 70, .gpu_clk_ms = 900 }, 0, "这段没有帧入账" },
    };
    int bad = 0;
    for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
        double got = s2a_gpu_busy_rate(&c[i].a, &c[i].b);
        if (got != c[i].want) { printf("✗ t_energy：GPU 忙（%s）期望 %.1f，实得 %.1f\n", c[i].what, c[i].want, got); bad++; }
    }
    return bad;
}

int main(void) {
    signal(SIGALRM, timeout); alarm(30);
    int bad = busy_rate_cases();
    printf("%s t_energy：GPU 忙按 GPU 时钟算 4 例，错 %d 例\n", bad ? "✗" : "✓", bad);
    enum { ROUNDS = 5, PER = 300 };
    char line[2048]; int ok = 0;
    for (int r = 0; r < ROUNDS; r++) {
        pthread_t th[PER]; g_go = 0; g_up = 0;
        for (int i = 0; i < PER; i++) if (pthread_create(&th[i], NULL, hold, NULL)) { printf("✗ t_energy：起线程失败（第 %d 轮第 %d 条）\n", r, i); return 1; }
        pthread_mutex_lock(&g_mu); while (g_up < PER) pthread_cond_wait(&g_cv, &g_mu); pthread_mutex_unlock(&g_mu);
        ok += s2a_energy_capture(line, sizeof line) >= 0 && line[0];
        pthread_mutex_lock(&g_mu); g_go = 1; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
        for (int i = 0; i < PER; i++) pthread_join(th[i], NULL);
    }
    printf("%s t_energy：%d 轮、经过 %d 个不同线程号，采样返回并写出 %d / %d 次（期望 %d）\n", ok == ROUNDS ? "✓" : "✗", ROUNDS, ROUNDS * PER, ok, ROUNDS, ROUNDS);
    return ok == ROUNDS && !bad ? 0 : 1;
}
