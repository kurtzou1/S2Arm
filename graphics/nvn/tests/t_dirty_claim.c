// 写跟踪「整段解保护」的认领：整段 mprotect(可写) 落地时，段内每一页都必须已被本线程认领（BUSY / BUSY_WRITABLE）。
// 反例：段内某页正被别的线程加保护（BUSY），本线程等它结束后若不重新认领就往下走，这页停在 PROT、没人认领；
// 第三个线程这时可以认领它（PROT -> BUSY 解保护，或之后 NONE -> BUSY 加保护），本线程随后的整段 mprotect 与
// 末尾「整段写 NONE」会盖掉别人的认领，留下「账上 PROT、内存可写」的漏检。这里在本线程下发整段 mprotect 的那一刻
// 查段内有没有仍是 PROT（= 没被认领）的页：期望 0 页。
#include "../gfx/nvn/nvn_dirty.h"
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static int (*g_hook)(void *, int, void *);
static void (*g_prep)(void *, size_t);
void dm_fault_hook_register(int (*fn)(void *addr, int is_write, void *uc)) { g_hook = fn; }
void dm_guest_write_prep_register(void (*fn)(void *addr, size_t len)) { g_prep = fn; }
void dm_log(const char *fmt, ...) { (void)fmt; }
extern int (*nvn_dirty_mp_hook)(void *addr, size_t len, int prot);

static uint8_t *g_m; static size_t g_pg; static const void *g_span;
static atomic_int g_park, g_parked, g_release, g_in_prep, g_seen, g_armed_at_rw, g_waited;
static void ms(int n) { struct timespec t = {0, n * 1000000L}; nanosleep(&t, NULL); }

static int hook(void *addr, size_t len, int prot) {
    uint8_t *a = addr;
    // 加保护方（T2）：把第 2 页停在 BUSY，直到放行
    if (prot == PROT_READ && a == g_m + 2 * g_pg && atomic_load(&g_park)) {
        atomic_store(&g_parked, 1);
        while (!atomic_load(&g_release)) ms(1);
    }
    // 解保护方（本线程）：整段 0..3 页下发可写的那一刻，段内不能还有 PROT 页
    if (prot == (PROT_READ | PROT_WRITE) && a == g_m && len == 4 * g_pg) {
        int armed = 0;
        for (int k = 0; k < 4; k++) armed += nvn_dirty_page_armed(g_span, g_m + k * g_pg);
        atomic_store(&g_armed_at_rw, armed); atomic_store(&g_seen, 1);
        atomic_store(&g_waited, atomic_load(&g_in_prep) && atomic_load(&g_release));
    }
    return 0;
}
static void *t2_protect(void *x) { (void)x; nvn_dirty_protect(g_m + 2 * g_pg, g_pg); return NULL; }
static void *releaser(void *x) { (void)x; ms(80); atomic_store(&g_release, 1); return NULL; }

int main(void) {
    g_pg = (size_t)getpagesize();
    nvn_dirty_set_chunk_pages(0);   // 逐页（苹果）：0..3 页合成一段、一次 mprotect
    g_m = mmap(NULL, 8 * g_pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    nvn_dirty_add_range(g_m, 8 * g_pg);
    g_span = nvn_dirty_span(g_m, 8 * g_pg);
    nvn_dirty_mp_hook = hook;
    nvn_dirty_protect(g_m, 2 * g_pg);
    nvn_dirty_protect(g_m + 3 * g_pg, g_pg);
    atomic_store(&g_park, 1);
    pthread_t t2, rl; pthread_create(&t2, NULL, t2_protect, NULL);
    while (!atomic_load(&g_parked)) ms(1);
    pthread_create(&rl, NULL, releaser, NULL);
    atomic_store(&g_in_prep, 1);
    g_prep(g_m, 4 * g_pg);           // 宿主写前解保护 0..3 页；第 2 页此刻 BUSY（T2 加保护中）
    pthread_join(t2, NULL); pthread_join(rl, NULL);

    int fails = 0;
    if (!atomic_load(&g_seen)) { printf("✗ 没走到整段 0..3 页的可写 mprotect（用例没覆盖到）\n"); fails++; }
    else if (!atomic_load(&g_waited)) { printf("✗ 本线程没在第 2 页上等过（时序没走到，用例无效）\n"); fails++; }
    else if (atomic_load(&g_armed_at_rw) != 0) { printf("✗ 整段可写 mprotect 下发时段内仍有 %d 页是 PROT（等完忙态没重新认领）\n", atomic_load(&g_armed_at_rw)); fails++; }
    else printf("✓ 整段可写 mprotect 下发时段内 4 页全部已认领（PROT 页 0，等过忙态 1 次）\n");
    for (int k = 0; k < 4; k++) g_m[k * g_pg] = 1;   // 解完后 0..3 页确实可写（写不进会崩）
    printf("%s t_dirty_claim\n", fails ? "✗" : "✓");
    return fails != 0;
}
