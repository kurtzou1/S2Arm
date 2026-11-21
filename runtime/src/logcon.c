// 控制台副本：原生层日志行同写一份到 g_s2a_confd（iOS 起局带 S2A_LOG_CONSOLE=1 时 = 原始 stdout，执行器 devicectl … launch --console 实时收）。
// 调用方只把行拷进 1 MB 环形缓冲（持锁 memcpy，不做系统调用），专用写线程阻塞写出：执行器读慢时整行排队、不丢不粘行，也不卡游戏线程；
//   环满才丢这一行并计数，写线程下一轮先补一行「[控制台] 环满丢 N 行」（host.log 照写全量）。执行器断开（写失败）→ 关副本，之后只写 host.log。
// 10-21 测试出包线：非阻塞直写版在一阵密集日志（宽屏首中 200 多行）时丢 11 行、1 处两行粘一行（部分写）。
#define S2A_LOGCON_IMPL
#include "native.h"
#include <fcntl.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <stdatomic.h>
#if defined(__ANDROID__) || defined(__OHOS__)
#include <signal.h>
#endif

enum { CON_RING = 1 << 20 };
static char con_ring[CON_RING];
static size_t con_head, con_tail;   // 累计写入 / 已写出字节数（单调增，下标取模）
static unsigned long con_drop;
// 同线程重入（信号处理里打日志——写跟踪缺页处理的「[track] 【红】…」、崩溃现场、SIGTERM 收局——恰好打断本线程 push 的临界区）：持着非递归锁再加锁 = 自锁死。
//   本线程在 push 里（线程局部标记）就不加锁、记一笔丢行返回（host.log 照写全量）；别的线程照常阻塞加锁（持锁者总会放，不丢行）。10-21 原生层线指出
static __thread int con_in;
static _Atomic unsigned long con_reent;
#ifdef S2A_UNIT_TEST
void (*s2a_logcon_test_inlock)(void);   // 单测：持锁时回调一次，模拟信号恰好打断临界区
#endif
static pthread_mutex_t con_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t con_cv = PTHREAD_COND_INITIALIZER;

void s2a_logcon_push(const char *p, size_t n) {
    if (con_in) { atomic_fetch_add(&con_reent, 1); return; }
    con_in = 1; pthread_mutex_lock(&con_mu);
    if (g_s2a_confd < 0) { pthread_mutex_unlock(&con_mu); con_in = 0; return; }
#ifdef S2A_UNIT_TEST
    if (s2a_logcon_test_inlock) { void (*f)(void) = s2a_logcon_test_inlock; s2a_logcon_test_inlock = 0; f(); }
#endif
    if (n > CON_RING - (con_head - con_tail)) con_drop++;
    else {
        for (size_t i = 0; i < n;) { size_t o = (con_head + i) % CON_RING, k = n - i; if (k > CON_RING - o) k = CON_RING - o; memcpy(con_ring + o, p + i, k); i += k; }
        con_head += n;
    }
    pthread_cond_signal(&con_cv); pthread_mutex_unlock(&con_mu); con_in = 0;
}

static int write_all(int fd, const char *p, size_t n) {
    while (n) { ssize_t w = write(fd, p, n); if (w <= 0) return -1; p += w; n -= (size_t)w; }
    return 0;
}

static void *con_writer(void *arg) { s2a_thread_name("s2a-logcon");
    int fd = (int)(intptr_t)arg;
#if defined(__ANDROID__) || defined(__OHOS__)
    // Linux 没有 F_SETNOSIGPIPE；只在日志写线程屏蔽，断管由 write/EPIPE 关闭副本。
    sigset_t blocked; sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    int mask_error = pthread_sigmask(SIG_BLOCK, &blocked, NULL);
    if (mask_error) die("控制台：无法屏蔽 SIGPIPE errno=%d", mask_error);
#endif
    for (;;) {
        pthread_mutex_lock(&con_mu);
        while (con_head == con_tail && !con_drop) pthread_cond_wait(&con_cv, &con_mu);
        size_t t = con_tail, o = t % CON_RING, k = con_head - t; if (k > CON_RING - o) k = CON_RING - o;
        unsigned long d = con_drop + atomic_exchange(&con_reent, 0); con_drop = 0;
        pthread_mutex_unlock(&con_mu);
        int bad = 0;
        if (k) bad = write_all(fd, con_ring + o, k);   // [t, t+k) 在 tail 前进之前不会被生产者覆盖，锁外读安全
        if (d && k && con_ring[o + k - 1] != '\n') { pthread_mutex_lock(&con_mu); con_drop += d; pthread_mutex_unlock(&con_mu); d = 0; }   // 这段在环尾截断了一行：丢行通知等行写完再补，不插进行中间
        if (!bad && d) { char m[128]; int l = snprintf(m, sizeof m, "[s2a] [控制台] 环满丢 %lu 行（host.log 照写全量）\n", d); bad = write_all(fd, m, (size_t)l); }
        pthread_mutex_lock(&con_mu); con_tail = t + k;
        if (bad) { g_s2a_confd = -1; con_tail = con_head; pthread_mutex_unlock(&con_mu); close(fd); return NULL; }
        pthread_mutex_unlock(&con_mu);
    }
}

// 退出前等写线程把环写空（最多 300 毫秒）：收局最后几行（「优雅退出完成」）紧挨 _exit 才打（10-21 真机：控制台比 host.log 少的正是这一行）。
//   lifecycle.c / crash.c 在 _exit 前显式调（_exit 不跑 atexit）；用 trylock：崩溃处理里也调，锁被崩掉的线程占着时不死等
void s2a_logcon_flush(void) {
    for (int i = 0; i < 300; i++) {
        if (pthread_mutex_trylock(&con_mu) == 0) { int done = g_s2a_confd < 0 || (con_head == con_tail && !con_drop); pthread_mutex_unlock(&con_mu); if (done) return; }
        struct timespec ts = { 0, 1000000 }; nanosleep(&ts, 0);
    }
}

int s2a_logcon_start(int fd) {
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
#if !defined(__ANDROID__) && !defined(__OHOS__)
    fcntl(fd, F_SETNOSIGPIPE, 1);
#endif
    pthread_t th; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    int r = pthread_create(&th, &a, con_writer, (void *)(intptr_t)fd); pthread_attr_destroy(&a);
    if (r) { close(fd); return -1; }
    g_s2a_confd = fd; atexit(s2a_logcon_flush); return 0;
}
