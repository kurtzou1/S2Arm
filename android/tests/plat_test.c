// Host-side smoke test for the Android plat.h implementation.  On a device the
// same binary also exercises the Bionic TSD paths.
#include "../../platform/plat.h"
#include "s2a_native.h"
#include "s2a_window.h"   // S2A_WIN_SIZE：安卓窗口真值（原先写死 64 GiB，11-14 窗口放大后过时：本用例只在 Linux 建、Mac 门禁不跑）

#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdatomic.h>
#include <time.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define CHECK(cond, what) do { \
    if (!(cond)) { fprintf(stderr, "plat android: FAILED %s (line %d)\n", what, __LINE__); return 1; } \
} while (0)

static volatile sig_atomic_t g_hit;

// Read the actual protection of the mapping containing addr from
// /proc/self/maps.  This observes state without changing it (unlike mprotect).
static int maps_prot(const void *addr, size_t size, char *out, size_t n) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return -1;
    char line[512];
    unsigned long want = (unsigned long)(uintptr_t)addr;
    while (fgets(line, sizeof line, f)) {
        unsigned long lo = 0, hi = 0;
        char perms[8] = {0};
        if (sscanf(line, "%lx-%lx %7s", &lo, &hi, perms) == 3
            && lo <= want && want <= hi && size <= hi - want) {
            snprintf(out, n, "%s", perms);
            fclose(f);
            return 0;
        }
    }
    fclose(f);
    return -1;
}

#ifdef S2A_UNIT_TEST
void plat_vm_test_set_protect_fail(int on);
void plat_vm_test_set_restore_fail(int on);
void plat_log_test_set_writer(int (*writer)(int, const char *, const char *));
uint64_t plat_log_test_dropped(void);
unsigned plat_log_test_capacity(void);
#endif

void plat_log_write(int level, const char *utf8);
int plat_sleep_until(uint64_t deadline_ns);
int plat_thread_qos(int cls);
int plat_thread_realtime(uint64_t period_ns, uint64_t computation_ns, uint64_t constraint_ns);

enum {
    TEST_PLAT_QOS_BACKGROUND = 1,
    TEST_PLAT_QOS_UTILITY = 2,
    TEST_PLAT_QOS_DEFAULT = 3,
    TEST_PLAT_QOS_USER_INITIATED = 4,
    TEST_PLAT_QOS_USER_INTERACTIVE = 5,
};

#if defined(__linux__)
static volatile sig_atomic_t sleep_signal_seen;
static void sleep_signal_handler(int sig) { (void)sig; sleep_signal_seen = 1; }
static void *interrupt_sleep(void *arg) {
    pthread_t target = *(pthread_t *)arg;
    usleep(1000);
    return (void *)(intptr_t)pthread_kill(target, SIGUSR2);
}

typedef struct { int rc; int nice_value; } qos_test_result;

static void *qos_test_thread(void *arg) {
    qos_test_result *result = arg;
    result->rc = plat_thread_qos(TEST_PLAT_QOS_BACKGROUND);
    errno = 0;
    result->nice_value = getpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid));
    if (result->nice_value == -1 && errno != 0) result->rc = errno;
    return NULL;
}

#endif

#if defined(__linux__) && defined(S2A_UNIT_TEST)
static atomic_int log_started, log_block_finished, log_summary_seen, log_entries_seen, log_truncated_seen;
static uint64_t log_reported_drops;
static int log_stub(int priority, const char *tag, const char *text) {
    if (strcmp(text, "block-writer") == 0) {
        if (priority != 5 || strcmp(tag, "S2Arm") != 0) return -1;
        atomic_store(&log_started, 1);
        struct timespec delay = { .tv_sec = 1 };
        while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
        atomic_store(&log_block_finished, 1);
    } else if (sscanf(text, "丢了 %" SCNu64 " 条日志", &log_reported_drops) == 1) {
        atomic_store(&log_summary_seen, 1);
    } else if (strcmp(text, "queued") == 0) {
        atomic_fetch_add(&log_entries_seen, 1);
    } else if (text[0] == 'x') {
        size_t n = strlen(text);
        if (n == 1022 && text[n-1] == 'x') atomic_store(&log_truncated_seen, 1);
    }
    return 0;
}

static int wait_for_log(atomic_int *flag, int minimum) {
    uint64_t deadline = plat_now_ns() + 5000000000ull;
    while (atomic_load(flag) < minimum && plat_now_ns() < deadline) usleep(1000);
    return atomic_load(flag) >= minimum;
}

typedef struct { uint64_t max_ns; } log_producer_result;
static void *log_producer(void *arg) {
    log_producer_result *result = arg;
    for (int i = 0; i < 2500; i++) {
        uint64_t start = plat_now_ns();
        plat_log_write(2, "queued");
        uint64_t elapsed = plat_now_ns() - start;
        if (elapsed > result->max_ns) result->max_ns = elapsed;
    }
    return NULL;
}

static int plat_log_tests(void) {
    plat_log_test_set_writer(log_stub);
    uint64_t start = plat_now_ns();
    plat_log_write(3, "block-writer");
    uint64_t first_ns = plat_now_ns() - start;
    // 「不阻塞」按事件判、不按墙钟（11-01 #1042：首次调用含惰性起写线程，高负载下偶发超 1 ms）：写线程被桩永久卡住
    //   （log_block_finished 始终 0）时下面 1 万 + 4×2500 次调用全部返回、丢弃数精确相等，即证明生产者从不等写线程；
    //   实现若改成等写线程，本测试卡死、由门禁超时判红。耗时只打印作参考
    CHECK(wait_for_log(&log_started, 1), "writer entered blocking log stub");
    uint64_t max_ns = 0;
    for (int i = 0; i < 10000; i++) {
        start = plat_now_ns();
        plat_log_write(2, "queued");
        uint64_t elapsed = plat_now_ns() - start;
        if (elapsed > max_ns) max_ns = elapsed;
    }
    uint64_t lost = 10000u - plat_log_test_capacity();
    CHECK(plat_log_test_dropped() == lost, "overflow count equals dropped entries");
    CHECK(!atomic_load(&log_block_finished), "writer remains blocked for concurrent producers");
    pthread_t producers[4];
    log_producer_result results[4] = {0};
    for (int i = 0; i < 4; i++) CHECK(pthread_create(&producers[i], NULL, log_producer, &results[i]) == 0, "create log producer");
    uint64_t multi_max_ns = 0;
    for (int i = 0; i < 4; i++) {
        CHECK(pthread_join(producers[i], NULL) == 0, "join log producer");
        if (results[i].max_ns > multi_max_ns) multi_max_ns = results[i].max_ns;
    }
    CHECK(!atomic_load(&log_block_finished), "writer remained blocked through concurrent burst");
    lost += 10000;
    CHECK(plat_log_test_dropped() == lost, "concurrent full-queue drops counted exactly");
    CHECK(wait_for_log(&log_summary_seen, 1), "worker emits loss summary");
    CHECK(log_reported_drops == lost, "loss summary reports exact overflow count");
    CHECK(wait_for_log(&log_entries_seen, (int)plat_log_test_capacity()), "worker drains queued entries");
    char long_utf8[1100];
    memset(long_utf8, 'x', sizeof long_utf8);
    long_utf8[1022] = (char)0xe4; long_utf8[1023] = (char)0xb8; long_utf8[1024] = (char)0xad;
    long_utf8[sizeof long_utf8 - 1] = 0;
    plat_log_write(2, long_utf8);
    CHECK(wait_for_log(&log_truncated_seen, 1), "truncation preserves UTF-8 boundary");
    printf("async log: 10000 calls, max %llu ns, first %llu ns; concurrent 10000 max %llu ns; dropped %llu\n",
           (unsigned long long)max_ns, (unsigned long long)first_ns,
           (unsigned long long)multi_max_ns, (unsigned long long)lost);
    return 0;
}
#endif

static int plat_adapter_tests(void) {
#if defined(__linux__) && defined(S2A_UNIT_TEST)
    CHECK(plat_log_tests() == 0, "async logging");
#endif
    CHECK(plat_sleep_until(0) == EINVAL, "sleep rejects zero deadline");
#if defined(__linux__)
    CHECK(plat_sleep_until(1) == 0, "sleep on expired deadline succeeds");
    uint64_t max_late_ns = 0;
    for (int i = 0; i < 200; i++) {
        uint64_t deadline = plat_now_ns() + 2000000ull;
        CHECK(plat_sleep_until(deadline) == 0, "absolute sleep succeeds");
        uint64_t woke = plat_now_ns();
        CHECK(woke >= deadline, "absolute sleep never returns early");
        if (woke - deadline > max_late_ns) max_late_ns = woke - deadline;
    }
    printf("absolute sleep: 200/200 not early; max late %llu ns\n", (unsigned long long)max_late_ns);
    struct sigaction action = {0}, old_action;
    action.sa_handler = sleep_signal_handler;
    sigemptyset(&action.sa_mask);
    CHECK(sigaction(SIGUSR2, &action, &old_action) == 0, "install sleep interrupt handler");
    pthread_t target = pthread_self(), interrupter;
    CHECK(pthread_create(&interrupter, NULL, interrupt_sleep, &target) == 0, "create interrupter");
    uint64_t interrupted_deadline = plat_now_ns() + 50000000ull;
    CHECK(plat_sleep_until(interrupted_deadline) == 0, "interrupted sleep resumes");
    CHECK(sleep_signal_seen && plat_now_ns() >= interrupted_deadline, "signal received and deadline honored");
    void *signal_result = NULL;
    CHECK(pthread_join(interrupter, &signal_result) == 0 && signal_result == NULL, "join interrupter");
    CHECK(sigaction(SIGUSR2, &old_action, NULL) == 0, "restore signal handler");

#endif
    CHECK(plat_thread_qos(0) == EINVAL && plat_thread_qos(6) == EINVAL,
          "qos rejects unknown classes");
#if defined(__linux__)
    qos_test_result qos = {0, -1};
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, qos_test_thread, &qos) == 0, "create qos test thread");
    CHECK(pthread_join(thread, NULL) == 0, "join qos test thread");
    CHECK(qos.rc == 0 && qos.nice_value == 10, "background qos maps to Android background priority");

#endif
    CHECK(plat_thread_realtime(0, 1, 1) == EINVAL, "realtime rejects zero period");
    CHECK(plat_thread_realtime(1000000, 500000, 800000) == ENOTSUP,
          "realtime capability is explicitly unsupported");

    return 0;
}

static void on_usr1(int sig, siginfo_t *si, void *ctx) {
    (void)sig;
    (void)si;
    (void)ctx;
    g_hit = 1;
}

static int vm_tests(size_t pg) {
    void *p = NULL;
    CHECK(plat_vm_reserve(pg * 2, pg, 1ull << 39, &p) == 0 && p, "vm reserve");
    CHECK(plat_vm_protect(p, pg, PLAT_PROT_READ | PLAT_PROT_WRITE) == 0, "vm protect RW");
    ((volatile uint8_t *)p)[0] = 0x5a;
    CHECK(((volatile uint8_t *)p)[0] == 0x5a, "vm protect made the page writable");
    CHECK(plat_vm_protect(p, pg, PLAT_PROT_READ) == 0, "vm protect R");
    CHECK(plat_vm_protect(p, pg, 1u << 7) == EINVAL, "vm protect rejects unknown bits");
    CHECK(plat_vm_protect((uint8_t *)p + 1, pg, PLAT_PROT_READ) == EINVAL, "vm protect rejects misalignment");
    CHECK(munmap(p, pg * 2) == 0, "vm reserve unmap");

    void *sentinel = (void *)0x1234;
    CHECK(plat_vm_reserve(pg, pg, 0, &sentinel) == EINVAL && sentinel == (void *)0x1234,
          "vm reserve keeps out unchanged on error");
    CHECK(plat_vm_reserve(pg, pg, 1ull << 39, NULL) == EINVAL, "vm reserve rejects null out");

    int fd = (int)syscall(SYS_memfd_create, "plat-alias", 0);
    CHECK(fd >= 0, "memfd_create");
    CHECK(ftruncate(fd, (off_t)pg) == 0, "memfd ftruncate");
    void *src = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    CHECK(src != MAP_FAILED, "mmap shared source");
    void *dst = NULL;
    CHECK(plat_vm_reserve(pg, pg, 1ull << 39, &dst) == 0 && dst, "alias dst reserve");
    CHECK(plat_vm_alias(dst, src, pg, PLAT_PROT_READ | PLAT_PROT_WRITE) == 0, "vm alias");
    ((volatile uint8_t *)src)[0] = 0x33;
    CHECK(((volatile uint8_t *)dst)[0] == 0x33, "alias sees source write");
    ((volatile uint8_t *)dst)[1] = 0x44;
    CHECK(((volatile uint8_t *)src)[1] == 0x44, "alias write reaches source");
    CHECK(plat_vm_alias(dst, src, pg, 1u << 7) == EINVAL, "vm alias rejects unknown bits");
    CHECK(plat_vm_alias((uint8_t *)dst + 1, src, pg, PLAT_PROT_READ) == EINVAL, "vm alias rejects misalignment");
    CHECK(munmap(dst, pg) == 0, "alias dst unmap");

#ifdef S2A_UNIT_TEST
    // alias succeeds, the post-alias protect fails, and the restore succeeds:
    // return the protect error, dst must still be a PROT_NONE reservation.
    void *block3 = NULL;
    CHECK(plat_vm_reserve(pg * 2, pg, 1ull << 39, &block3) == 0 && block3, "protect-fail dst reserve");
    void *dst3 = (uint8_t *)block3 + pg;   // adjacent PROT_NONE VMA may merge after restore
    plat_vm_test_set_protect_fail(1);
    int e3 = plat_vm_alias(dst3, src, pg, PLAT_PROT_READ | PLAT_PROT_WRITE);
    plat_vm_test_set_protect_fail(0);
    CHECK(e3 == EACCES, "alias returns protect failure");
    char prot[8] = {0};
    CHECK(maps_prot(dst3, pg, prot, sizeof prot) == 0, "protect-fail dst still mapped");
    CHECK(strcmp(prot, "---p") == 0, "protect-fail restore left dst PROT_NONE");
    CHECK(munmap(block3, pg * 2) == 0, "protect-fail dst unmap");

    // Same, but the restore itself fails: EIO means the caller must treat the
    // window as poisoned (do not use or reuse dst).
    void *block4 = NULL;
    CHECK(plat_vm_reserve(pg * 2, pg, 1ull << 39, &block4) == 0 && block4, "restore-fail dst reserve");
    void *dst4 = (uint8_t *)block4 + pg;
    plat_vm_test_set_protect_fail(1);
    plat_vm_test_set_restore_fail(1);
    int e4 = plat_vm_alias(dst4, src, pg, PLAT_PROT_READ | PLAT_PROT_WRITE);
    plat_vm_test_set_restore_fail(0);
    plat_vm_test_set_protect_fail(0);
    CHECK(e4 == EIO, "restore failure returns EIO");
    char prot4[8] = {0};
    CHECK(maps_prot(dst4, pg, prot4, sizeof prot4) == 0, "restore-fail dst still mapped");
    CHECK(strcmp(prot4, "---p") != 0, "restore-fail negative control is not silently repaired");
    CHECK(munmap(block4, pg * 2) == 0, "restore-fail dst cleanup");
#endif

    CHECK(munmap(src, pg) == 0, "alias src unmap");
    close(fd);

    // A failed alias must keep dst reserved: a private source is not aliasing-
    // capable on Linux, and dst must still accept a protection change.
    void *bad_src = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(bad_src != MAP_FAILED, "mmap private source");
    void *dst2 = NULL;
    CHECK(plat_vm_reserve(pg, pg, 1ull << 39, &dst2) == 0 && dst2, "failed alias dst reserve");
    CHECK(plat_vm_alias(dst2, bad_src, pg, PLAT_PROT_READ) != 0, "alias rejects private source");
    CHECK(plat_vm_protect(dst2, pg, PLAT_PROT_NONE) == 0, "failed alias keeps dst reserved");
    CHECK(munmap(dst2, pg) == 0, "failed alias dst unmap");
    CHECK(munmap(bad_src, pg) == 0, "private source unmap");
    return 0;
}

int main(void) {
    CHECK(plat_adapter_tests() == 0, "platform adapter tests");
    size_t pg = plat_page_size();
    CHECK(pg >= 4096 && (pg & (pg - 1)) == 0, "page size is a power of two");
    CHECK(vm_tests(pg) == 0, "vm tests");
    char dir[] = "/tmp/s2a-plat-layout-XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "layout temp directory");
    char npdm[256], detail[256]; snprintf(npdm, sizeof npdm, "%s/main.npdm", dir);
    s2a_layout layout; uint64_t need = 0;
    CHECK(plat_layout_override(npdm, 3, 80u << 20, 1, 0x7000000000ull,
                               S2A_WIN_SIZE, &layout, &need, detail, sizeof detail) == 0,
          "Android layout provider");
    CHECK(layout.win_size == need && layout.heap_size == 3284ull * (1ull << 20), "layout budget");
    CHECK(layout.alias_base >= layout.win_base &&
          layout.alias_base + layout.alias_size <= layout.win_base + layout.win_size,
          "Android VAMM alias stays in window");
    CHECK(plat_layout_override(npdm, 3, 0, 1, 0x7000000000ull,
                               S2A_WIN_SIZE, &layout, &need, detail, sizeof detail) == 0 &&
          layout.alias_base >= layout.win_base &&
          layout.alias_base + layout.alias_size <= layout.win_base + layout.win_size,
          "Android non-VAMM alias stays in window");
    CHECK(plat_layout_override(npdm, 2, 80u << 20, 1, 0x7000000000ull,
                               S2A_WIN_SIZE, &layout, &need, detail, sizeof detail) == EINVAL,
          "invalid address space fails");
    CHECK(rmdir(dir) == 0, "layout temp directory removed");

    uint64_t a = plat_now_ns();
    usleep(2000);
    uint64_t b = plat_now_ns();
    CHECK(a && b && b > a, "monotonic clock advances");

    plat_thread_t self = 0;
    CHECK(plat_thread_self(&self) == 0 && self != 0, "thread self");

    uintptr_t low = 0, high = 0;
    CHECK(plat_thread_stack_bounds(&low, &high) == 0 && low < high, "stack bounds");
    uintptr_t here = (uintptr_t)&low;
    CHECK(here > low && here < high, "current sp is inside the stack");

#if defined(__ANDROID__) && defined(__aarch64__)
    CHECK(plat_tsd_init() == 0, "tsd init");
    CHECK(plat_tsd_base() != 0, "tsd base");
    uint64_t off = 0;
    CHECK(plat_tsd_offset(1, &off) == 0 && off != 0, "tsd offset");
#else
    CHECK(plat_tsd_init() == ENOTSUP, "tsd init is ENOTSUP on the host");
    CHECK(plat_tsd_base() == 0, "tsd base is 0 on the host");
    uint64_t off = 0;
    CHECK(plat_tsd_offset(1, &off) == ENOTSUP, "tsd offset is ENOTSUP on the host");
#endif

    CHECK(plat_fault_altstack_init() == 0, "altstack init");
    CHECK(plat_fault_altstack_init() == 0, "altstack init is idempotent");
    CHECK(plat_fault_install(SIGUSR1, on_usr1, PLAT_FAULT_ONSTACK) == 0, "install SIGUSR1");
    g_hit = 0;
    raise(SIGUSR1);
    CHECK(g_hit == 1, "SIGUSR1 handler ran");
    signal(SIGUSR1, SIG_DFL);
    plat_fault_altstack_free();
    plat_fault_altstack_free();

    puts("plat android: ok");
    return 0;
}
