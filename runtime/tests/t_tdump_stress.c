// 全线程现场 s2a_dump_threads（压力）不能在「别的线程已挂起」时调要锁的函数（11-14 停帧看门打到一半断）。
// 夹具：一条线程不停建 / 收线程（pthread 线程表锁，pthread_from_mach_thread_np 要它），一条不停 dlopen / dlclose（dyld 写锁，dladdr 要它），
//   两条 malloc / free，一条阻塞在条件变量上；连打 300 次现场。
// 期望（按原理，不跑被测实现推）：挂起期间只做内核调用的实现每次都打完（出「现场完」），30 秒看门不触发；
//   挂起后边取边 dladdr 的旧实现会碰上被挂起的线程正持着 dyld 锁 → 本线程卡死 → 看门退出 2（负对照手动换回旧 tdump.c 看）
#include "../src/native.h"
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
module_t *module_of(const void *p) { (void)p; return NULL; }
int s2a_dump_threads(const char *why);
static atomic_int g_stop;
static void *noop(void *a) { return a; }
static void *spin_threads(void *a) { (void)a; while (!atomic_load(&g_stop)) { pthread_t x; if (!pthread_create(&x, NULL, noop, NULL)) pthread_join(x, NULL); } return NULL; }
static void *spin_dlopen(void *a) { (void)a; while (!atomic_load(&g_stop)) { void *h = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW | RTLD_LOCAL); if (h) dlclose(h); } return NULL; }
static void *spin_malloc(void *a) { (void)a; while (!atomic_load(&g_stop)) { void *p = malloc(4096); if (p) memset(p, 1, 64); free(p); } return NULL; }
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static void *block(void *a) { (void)a; pthread_mutex_lock(&mu); while (!atomic_load(&g_stop)) pthread_cond_wait(&cv, &mu); pthread_mutex_unlock(&mu); return NULL; }
static void *watchdog(void *a) { (void)a; sleep(30); fprintf(stderr, "✗ t_tdump_stress：30 秒没打完 300 次现场（卡死）\n"); _exit(2); return NULL; }
int main(void) {
    char tmpl[] = "/tmp/t_tdump_stress_XXXXXX"; int fd = mkstemp(tmpl); if (fd < 0) return 1;
    g_s2a_logfd = fd;   // 现场行写临时文件，事后数
    pthread_t t[5];
    pthread_create(&t[0], NULL, spin_threads, NULL); pthread_create(&t[1], NULL, spin_dlopen, NULL);
    pthread_create(&t[2], NULL, spin_malloc, NULL); pthread_create(&t[3], NULL, spin_malloc, NULL);
    pthread_create(&t[4], NULL, block, NULL);
    pthread_t w; pthread_create(&w, NULL, watchdog, NULL);
    int rounds = 300, min_threads = 1 << 30;
    for (int i = 0; i < rounds; i++) { int n = s2a_dump_threads("t_tdump_stress"); if (n < min_threads) min_threads = n; }
    atomic_store(&g_stop, 1); pthread_mutex_lock(&mu); pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
    for (int i = 0; i < 5; i++) pthread_join(t[i], NULL);
    lseek(fd, 0, SEEK_SET); size_t cap = 1 << 26; char *buf = malloc(cap); ssize_t len = read(fd, buf, cap - 1); close(fd); unlink(tmpl);
    if (len < 0) len = 0; buf[len] = 0;
    int heads = 0, tails = 0; for (char *p = buf; (p = strstr(p, "===== 全线程现场")); p++) heads++; for (char *p = buf; (p = strstr(p, "===== 现场完")); p++) tails++;
    int ok = heads == rounds && tails == rounds && min_threads >= 7;   // 主线程 + 5 条夹具线程 + 看门线程（建收线程那条瞬时还会多一条）
    printf("%s t_tdump_stress：%d 次现场，开头 %d / 结尾 %d（期望各 %d），每次至少 %d 条线程（期望 ≥ 7），没有卡死\n", ok ? "✓" : "✗", rounds, heads, tails, rounds, min_threads);
    return ok ? 0 : 1;
}
