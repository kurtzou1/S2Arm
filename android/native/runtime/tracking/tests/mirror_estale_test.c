// Linux host/ARM64 容器夹具（#1184）：镜像世代搅动 + 真实换页与写路径的竞争。
// 模式（argv[1]）：
//   churn <us> <page>  旧夹具：churn 页与写页不相交，只验证 ESTALE 有界重试不丢字节。
//   swap in|unmap <page>
//       并发换「写页本身」：换页事务改 lastp/act 并 mremap 新物理页；写者用两个钩子停在
//       「别名到手、前提已复核、尚未 memcpy」处。红（修复前）：换页不等待在途写者，写者把旧
//       GPU 数据 memcpy 进换入的新页（in 模式内容出现 0xA5），或写进 mirror_end 装的 PROT_READ
//       零页触发 SIGSEGV（unmap 模式）。绿：mirror_begin 先等在途写者归零，写者只写旧页，
//       重试前 lastp/act 已重置，于是退回正常路径，新页只可能是 0x5a。
//   d2 <page>           前提复核失败路径注入 unalias EINVAL（别名栈错位）：修复前被吞掉，
//       修复后必须报红 FATAL（SIGABRT）。
//   precise <page>      restore_precise 在世代搅动下重试；16K 模型用观察子页验证哈希记账
//       不因失败轮写已落地而伪报脏。
//   writer-timeout <page> mirror_begin 在写者计数不归零时的有界等待：超限必须报红 FATAL。
// 结构：memfd+MAP_SHARED guest 区（mremap(old_size=0) 需要共享 backing）；mirror_init 建第二窗口，
//       staging 提交全部位 → alias 走镜像路。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../../../../../graphics/track/s2a_track.h"
#include "../runtime.h"
#include "../../../../../graphics/track/track_platform.h"
#include "../mirror.h"
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static size_t host_page, model_page;
static uint8_t *arena;
static int arena_pages = 96;
static int vm_installed;
int s2a_android_fault_dispatch_installed(void) { return 1; }
int s2a_android_tracking_vm_ready(void) { return vm_installed; }
int s2a_android_fault_dispatch_ready(void) { return 1; }
int s2a_track_test_pagesize(void) { return (int)model_page; }

extern void (*s2a_track_test_write_alias_acquired)(void);
extern void (*s2a_track_test_write_alias_ready)(void);
extern void (*s2a_track_test_write_alias_retry)(void);

static int write_pages = 32, churn_pages = 32, iters = 200000;
static long churn_us;                                                 // 世代对间隔 µs：0=无稳定窗（对抗），>0=有稳定窗（真实）
static _Atomic int churn_stop;
static _Atomic uint64_t churn_rounds;

static void *churn_thread(void *arg) {
    uintptr_t base = (uintptr_t)arena + (size_t)write_pages * model_page;
    (void)arg;
    uint64_t i = 0;
    while (!atomic_load_explicit(&churn_stop, memory_order_relaxed)) {
        s2a_android_mirror_begin(base + (size_t)(i % churn_pages) * model_page, model_page);
        s2a_android_mirror_end(base + (size_t)(i % churn_pages) * model_page, model_page, 1, 1);
        i++;
        if (churn_us > 0) {                                            // 忙等稳定窗（usleep 会被写循环饿死）
            struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
            uint64_t deadline = (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec + (uint64_t)churn_us * 1000ull;
            for (;;) { clock_gettime(CLOCK_MONOTONIC, &t); if ((uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec >= deadline) break; }
        }
    }
    atomic_store_explicit(&churn_rounds, i, memory_order_relaxed);
    return NULL;
}

static uint64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

// ---------- swap 模式：写者与换页按固定相位交错 ----------
// step 单调递增，每轮占 8 个相位：1=写者停在 memcpy 前，2=换页开始，3=换页提交完成，
// 4=写者第一次尝试结束（已 memcpy/已解别名），5=检查页内容完成，6=写调用返回，7=下一轮可开始。
static _Atomic int swap_step;
static int swap_active, swap_base, swap_unmap;
static int swap_iterations = 32;

static void step_advance(int value) {
    int current = atomic_load_explicit(&swap_step, memory_order_relaxed);
    if (value > current) atomic_store_explicit(&swap_step, value, memory_order_release);
}
static int step_wait(int value, long ms) {
    uint64_t deadline = now_ns() + (uint64_t)ms * 1000000ull;
    while (atomic_load_explicit(&swap_step, memory_order_acquire) < value) {
        if (now_ns() >= deadline) return 0;
        sched_yield();
    }
    return 1;
}
static void swap_ready(void) {                       // 前提复核已通过、memcpy 之前
    if (!swap_active) return;
    step_advance(swap_base + 1);
    step_wait(swap_base + 3, 30);                    // 绿：换页被写者计数挡住，等到超时；红：换页已完成
}
static void swap_retry(void) {                       // 第一次尝试已结束（计数已放），即将重试
    if (!swap_active) return;
    step_advance(swap_base + 4);
    step_wait(swap_base + 5, 5000);
}

static int page_has(const uint8_t *page, size_t size, uint8_t needle) {
    for (size_t i = 0; i < size; i++) if (page[i] == needle) return 1;
    return 0;
}

static int run_swap_child(void) {
    uintptr_t p = (uintptr_t)arena;
    static uint8_t pattern[16384];
    memset(pattern, 0xa5, sizeof pattern);
    s2a_track_test_write_alias_ready = swap_ready;
    s2a_track_test_write_alias_retry = swap_retry;
    swap_active = 1;
    int rounds = swap_unmap ? 1 : swap_iterations;
    for (int i = 0; i < rounds; i++) {
        swap_base = i * 8;
        s2a_track_reprotect(p, model_page, S2A_TRACK_NONE);          // lastp=NONE、act 置位 → 写走别名
        s2a_track_write_untracked(p, pattern, model_page, 1);
        step_advance(swap_base + 6);
        if (!step_wait(swap_base + 7, 5000)) { fprintf(stderr, "[estale-fixture] 【红】写者等待下一轮超时\n"); return 5; }
    }
    fprintf(stderr, "[estale-fixture] swap-%s 写者完成 %d 轮\n", swap_unmap ? "unmap" : "in", rounds);
    return 0;
}

static int swap_loop(void) {
    uintptr_t p = (uintptr_t)arena;
    int rounds = swap_unmap ? 1 : swap_iterations;
    for (int i = 0; i < rounds; i++) {
        int b = i * 8;
        if (!step_wait(b + 1, 5000)) { fprintf(stderr, "[estale-fixture] 【红】等写者就位超时\n"); return 5; }
        step_advance(b + 2);                                             // mirror_begin 会在这里等写者计数（修复后）
        int error = s2a_track_backing_begin(p, model_page, 0);
        if (error) { fprintf(stderr, "[estale-fixture] 【红】backing_begin errno=%d\n", error); return 5; }
        s2a_android_mirror_begin(p, model_page);
        if (swap_unmap) {
            if (mmap((void *)p, model_page, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED) return 5;
        } else {
            if (mmap((void *)p, model_page, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_SHARED | MAP_ANONYMOUS, -1, 0) == MAP_FAILED) return 5;
            memset((void *)p, 0x5a, model_page);                          // 新换入页的已知内容
        }
        s2a_track_backing_reset_before_publish(p, model_page);
        s2a_android_mirror_end(p, model_page, !swap_unmap, 1);
        if (swap_unmap) {                                                 // 让写者重试的正常路径有可写页；mirror 仍是只读零页
            if (mmap((void *)p, model_page, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_SHARED | MAP_ANONYMOUS, -1, 0) == MAP_FAILED) return 5;
            memset((void *)p, 0x5a, model_page);
        }
        s2a_track_backing_end(p, model_page, !swap_unmap, 1);
        step_advance(b + 3);
        if (!step_wait(b + 4, 5000)) { fprintf(stderr, "[estale-fixture] 【红】等写者第一次尝试结束超时\n"); return 5; }
        if (!swap_unmap) {                                                // 只有 in 模式能保留「旧数据进新页」的证据
            if (page_has((const uint8_t *)p, model_page, 0xa5)) {
                fprintf(stderr, "[estale-fixture] RED: 换入页出现写者的旧 GPU 数据 0xa5（第 %d 轮）\n", i);
                return 3;
            }
        }
        step_advance(b + 5);
        if (!step_wait(b + 6, 5000)) { fprintf(stderr, "[estale-fixture] 【红】等写调用返回超时\n"); return 5; }
        step_advance(b + 7);
    }
    fprintf(stderr, "[estale-fixture] swap-%s 换页完成 %d 轮，新页未被旧数据污染\n", swap_unmap ? "unmap" : "in", rounds);
    return 0;
}
static _Atomic int swapper_rc;
static void *swap_thread_main(void *arg) {
    (void)arg;
    atomic_store(&swapper_rc, swap_loop());
    return NULL;
}

// ---------- d2 模式：前提复核失败时 unalias 返回 EINVAL（别名栈错位） ----------
static _Atomic int d2_armed;
static void d2_acquired(void) {
    if (!atomic_exchange(&d2_armed, 0)) return;
    void *other = NULL;
    uintptr_t q = (uintptr_t)arena + model_page;
    int error = s2a_track_platform_alias(q, model_page, PROT_READ, &other);   // 压入另一个别名的栈帧
    if (error || !other) { fprintf(stderr, "[estale-fixture] 【红】d2 注入别名失败 errno=%d\n", error); _exit(9); }
    s2a_track_backing_reset((uintptr_t)arena, model_page);                    // 前提失效 → 走 unalias+return 0 路径
}
static int run_d2_child(void) {
    static uint8_t pattern[16384];
    memset(pattern, 0xa5, sizeof pattern);
    s2a_track_test_write_alias_acquired = d2_acquired;
    atomic_store(&d2_armed, 1);
    s2a_track_reprotect((uintptr_t)arena, model_page, S2A_TRACK_NONE);
    s2a_track_write_untracked((uintptr_t)arena, pattern, model_page, 1);
    fprintf(stderr, "[estale-fixture] RED: unalias EINVAL 被吞掉（子进程正常返回）\n");
    return 0;
}

// ---------- precise 模式：restore_precise 重试 + 观察子页哈希记账 ----------
// 确定性竞争（11-26）：原先只靠 churn 线程与 2000 次恢复碰运气，整套满载时 churn 线程可能一轮都没排上，
//   用例判「没测到竞争」红（门禁 1 次 / 单跑 0 次）。这里先排定次序逼出一次：辅助线程在 churn 页开换页事务（世代变奇数）
//   并按住 → 主线程恢复，拿别名必遇奇数世代、进入等待 → 辅助线程看到等待计数涨了才结束事务放行。不靠调度，
//   等不到等待计数（恢复没守奇数世代）本身就是红。
static _Atomic int force_state;   // 0 空闲 / 1 事务已开 / 2 已放行
static void *force_thread(void *arg) {
    uintptr_t page = (uintptr_t)arena + (size_t)write_pages * model_page;
    uint64_t waits0 = *(const uint64_t *)arg;
    s2a_android_mirror_begin(page, model_page);
    atomic_store_explicit(&force_state, 1, memory_order_release);
    uint64_t deadline = now_ns() + 5000ull * 1000000ull;
    while (s2a_android_mirror_test_waits() == waits0 && now_ns() < deadline) sched_yield();
    s2a_android_mirror_end(page, model_page, 1, 1);
    atomic_store_explicit(&force_state, 2, memory_order_release);
    return NULL;
}
static int precise_forced_round(uintptr_t p, uint8_t value) {
    uint64_t waits0 = s2a_android_mirror_test_waits();
    pthread_t t;
    atomic_store(&force_state, 0);
    if (pthread_create(&t, NULL, force_thread, &waits0)) return 2;
    while (atomic_load_explicit(&force_state, memory_order_acquire) != 1) sched_yield();
    s2a_track_restore_precise(p + 8192 + 16, &value, 1);   // 事务开着：必须等到放行才落笔
    pthread_join(t, NULL);
    if (s2a_android_mirror_test_waits() == waits0) { fprintf(stderr, "[estale-fixture] 【红】换页事务开着时精确恢复没等世代回偶数\n"); return 9; }
    if (((const uint8_t *)p)[8192 + 16] != value) { fprintf(stderr, "[estale-fixture] 【红】排定竞争后恢复未落到页上\n"); return 4; }
    return 0;
}
static int run_precise_child(void) {
    if (model_page < 16384) { fprintf(stderr, "[estale-fixture] SKIP precise: 需要 16K 模型\n"); return 0; }
    uintptr_t p = (uintptr_t)arena;
    pthread_t t;
    s2a_track_reprotect(p, model_page, S2A_TRACK_READ);                       // 整页要保护
    s2a_track_write_quiet(p + 4096 + 16, 1);                                  // 解开页：sub1 记脏，sub0/2/3 转观察
    uint64_t retries0 = s2a_android_mirror_test_retries(), waits0 = s2a_android_mirror_test_waits();
    for (int i = 0; i < 16; i++) {   // 排定的竞争先做、在 churn 线程起来之前：换页事务同一时刻只许开一个（mirror_begin 遇奇数世代即报红）
        int rc = precise_forced_round(p, (i & 1) ? 0x5a : 0xa5);
        if (rc) return rc;
    }
    if (pthread_create(&t, NULL, churn_thread, NULL)) return 2;
    for (int i = 0; i < 2000; i++) {
        uint8_t value = (i & 1) ? 0x5a : 0xa5;
        s2a_track_restore_precise(p + 8192 + 16, &value, 1);                  // 世代搅动下会 ESTALE/等偶数重试
    }
    atomic_store(&churn_stop, 1);
    pthread_join(t, NULL);
    uint8_t final = 0x99;
    s2a_track_restore_precise(p + 8192 + 16, &final, 1);
    if (((const uint8_t *)p)[8192 + 16] != 0x99) { fprintf(stderr, "[estale-fixture] 【红】restore 未落到页上\n"); return 4; }
    s2a_track_batch batch;
    s2a_track_drain(&batch);
    int dirty_restored = 0, dirty_cpu = 0;
    for (unsigned i = 0; i < batch.nranges; i++) {
        uint64_t a = batch.ranges[i].addr, e = a + batch.ranges[i].size;
        if (a <= p + 8192 + 16 && p + 8192 + 16 < e) dirty_restored = 1;
        if (a <= p + 4096 + 16 && p + 4096 + 16 < e) dirty_cpu = 1;
    }
    s2a_track_drain_done();
    uint64_t retries = s2a_android_mirror_test_retries() - retries0;
    uint64_t waits = s2a_android_mirror_test_waits() - waits0;
    fprintf(stderr, "[estale-fixture] precise retries=%llu waits=%llu churn=%llu\n",
            (unsigned long long)retries, (unsigned long long)waits, (unsigned long long)atomic_load(&churn_rounds));
    if (!dirty_cpu) { fprintf(stderr, "[estale-fixture] 【红】观察页上的普通 CPU 写没报脏\n"); return 6; }
    if (dirty_restored) { fprintf(stderr, "[estale-fixture] 【红】精确恢复伪报观察子页脏（哈希记账被重试破坏）\n"); return 7; }
    if (retries + waits < 16) { fprintf(stderr, "[estale-fixture] 【红】排定的 16 轮竞争没有全部记到世代等待 / 重试（%llu）\n", (unsigned long long)(retries + waits)); return 8; }
    return 0;
}

// ---------- writer-timeout 模式：有界等待超限必须 FATAL ----------
static int run_writer_timeout_child(void) {
    s2a_android_mirror_test_timeout_us(20000);
    s2a_track_platform_writer_enter();                                        // 模拟卡住的在途写者
    s2a_android_mirror_begin((uintptr_t)arena, model_page);                  // 必须等超时并报红 FATAL
    s2a_track_platform_writer_leave();
    fprintf(stderr, "[estale-fixture] RED: 写入计数不归零时 mirror_begin 未报红\n");
    return 0;
}

// ---------- churn 模式：旧夹具 ----------
static int child_main(void) {
    uint8_t buf[64];
    for (int i = 0; i < iters; i++) {
        uintptr_t a = (uintptr_t)arena + (size_t)(i % write_pages) * model_page;
        s2a_track_reprotect(a, model_page, S2A_TRACK_NONE);            // act+want 置位 → rf_apply → NONE
        memset(buf, 0xa0 + (i & 0x3f), sizeof buf);
        s2a_track_write_untracked(a, buf, sizeof buf, 1);              // write_via_alias → 命中则 ESTALE→FATAL（红）
        if (i % 4096 == 4095) { fprintf(stderr, "[estale-fixture] iter=%d seq=%llu\n", i + 1, (unsigned long long)s2a_android_mirror_sequence()); }
    }
    // 字节级判据：停搅动后再做一次已知样式写，解开保护后逐字节比对（修复必须保证无半截写）
    atomic_store(&churn_stop, 1);
    uintptr_t a = (uintptr_t)arena;
    s2a_track_reprotect(a, model_page, S2A_TRACK_NONE);
    memset(buf, 0x7e, sizeof buf);
    s2a_track_write_untracked(a, buf, sizeof buf, 1);
    s2a_track_reprotect(a, model_page, S2A_TRACK_READ);
    if (memcmp(arena, buf, sizeof buf)) {
        fprintf(stderr, "[estale-fixture] 【红】回写后页内容不符（半截写/错字节）\n");
        return 3;
    }
    fprintf(stderr, "[estale-fixture] iters=%d 页内容逐字节一致\n", iters);
    return 0;
}

static int setup(void) {
    host_page = (size_t)sysconf(_SC_PAGESIZE);
    if (!model_page) model_page = host_page;
    if (model_page < host_page || model_page % host_page || model_page > 16384) {
        fprintf(stderr, "[estale-fixture] SKIP model=%zu host=%zu\n", model_page, host_page);
        return 1;
    }
    size_t bytes = (size_t)arena_pages * model_page;
    int fd = memfd_create("s2a-estale", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)bytes)) { perror("memfd"); return 2; }
    void *reserved = mmap(NULL, bytes + model_page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reserved == MAP_FAILED) { perror("reserve"); return 2; }
    uintptr_t aligned = ((uintptr_t)reserved + model_page - 1) & ~(uintptr_t)(model_page - 1);
    arena = mmap((void *)aligned, bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    if (arena != (void *)aligned) { perror("arena mmap"); return 2; }
    memset(arena, 0x11, bytes);
    s2a_track_prepare();
    s2a_track_set_readflush(1);
    s2a_track_set_walias(1);
    s2a_android_mirror_configure(1);   // 本夹具验证「开」路径；缺省关由 mirror_switch_test 覆盖
    s2a_android_mirror_init((uintptr_t)arena, bytes);
    uintptr_t mb = s2a_android_mirror_test_base();
    if (!mb) { fprintf(stderr, "[estale-fixture] mirror_init 未建窗口\n"); return 2; }
    s2a_android_mirror_begin((uintptr_t)arena, bytes);
    s2a_android_mirror_end((uintptr_t)arena, bytes, 1, 1);   // staging 提交，全部位置位
    // ⑧ 回归：不碰镜像窗的事务不得翻世代（修复前这里 seq +2，在途别名全部 ESTALE）
    uint64_t seq0 = s2a_android_mirror_sequence();
    uintptr_t outside = (uintptr_t)arena + bytes + (16ull << 20);
    s2a_android_mirror_begin(outside, model_page);
    s2a_android_mirror_end(outside, model_page, 0, 0);
    if (s2a_android_mirror_sequence() != seq0) { fprintf(stderr, "[estale-fixture] 【红】窗外事务翻了世代\n"); return 7; }
    void *probe = NULL;
    int error = s2a_track_platform_alias((uintptr_t)arena, model_page, PROT_READ | PROT_WRITE, &probe);
    if (error || (uintptr_t)probe != mb) {                                 // 必须走镜像别名路，否则 ESTALE 无从触发
        fprintf(stderr, "[estale-fixture] alias 未走镜像路 error=%d probe=%p mirror=%#lx\n", error, probe, (unsigned long)mb);
        return 2;
    }
    if (s2a_track_platform_unalias(probe, model_page)) { fprintf(stderr, "[estale-fixture] 首轮 unalias 失败\n"); return 2; }
    fprintf(stderr, "[estale-fixture] mirror=%#lx model=%zu host=%zu\n", (unsigned long)mb, model_page, host_page);
    return 0;
}

static const char *mode = "churn";
static int expect_abort;   // d2 / writer-timeout：子进程必须 FATAL

static int spawn(void) {
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }
    if (pid == 0) {
        int rc;
        if (!strcmp(mode, "swap")) {
            pthread_t t;
            if (pthread_create(&t, NULL, swap_thread_main, NULL)) return 2;
            rc = run_swap_child();
            pthread_join(t, NULL);
            int src = atomic_load(&swapper_rc);
            if (src) rc = src;   // 污染证据优先于写者等下一轮超时
            s2a_android_mirror_report("estale-end");
        } else if (!strcmp(mode, "d2")) rc = run_d2_child();
        else if (!strcmp(mode, "precise")) rc = run_precise_child();
        else if (!strcmp(mode, "writer-timeout")) rc = run_writer_timeout_child();
        else {
            pthread_t t;
            if (pthread_create(&t, NULL, churn_thread, NULL)) return 2;
            rc = child_main();
            pthread_join(t, NULL);
            fprintf(stderr, "[estale-fixture] churn_rounds=%llu\n", (unsigned long long)atomic_load(&churn_rounds));
            s2a_android_mirror_report("estale-end");
        }
        _exit(rc);
    }
    int status = 0, waited = 0;
    while (waited < 90000) {                                               // 90s 上限
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) break;
        usleep(200000); waited += 200;
    }
    if (waited >= 90000) { kill(pid, SIGKILL); waitpid(pid, &status, 0); fprintf(stderr, "[estale-fixture] timeout\n"); return 4; }
    if (expect_abort) {
        if (WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT) { fprintf(stderr, "[estale-fixture] GREEN: 已报红 FATAL（SIGABRT）\n"); return 0; }
        fprintf(stderr, "[estale-fixture] RED: 预期 FATAL/SIGABRT，实际 status=%#x\n", status);
        return 1;
    }
    if (WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT) {
        if (!strcmp(mode, "churn") && !churn_us) {   // 对抗模式：无稳定窗下有界重试必耗尽 → FATAL 带 errno=116 是修复后的预期 fail-closed
            fprintf(stderr, "[estale-fixture] OK-ABORT: 对抗搅动下有界耗尽 fail-closed（看上行 errno=116）\n");
            return 0;
        }
        fprintf(stderr, "[estale-fixture] RED: SIGABRT——ESTALE/换页竞争未被救回\n");
        return 1;
    }
    if (WIFSIGNALED(status)) {
        fprintf(stderr, "[estale-fixture] RED: 子进程被信号 %d 终止（swap unmap 模式 = 写进只读镜像零页）\n", WTERMSIG(status));
        return 1;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 3) {
        fprintf(stderr, "[estale-fixture] RED: 子进程报告页内容被旧数据污染\n");
        return 1;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        if (!strcmp(mode, "churn") && !churn_us) { fprintf(stderr, "[estale-fixture] 对抗搅动竟跑满轮数（应耗尽）\n"); return 6; }
        fprintf(stderr, "[estale-fixture] GREEN: %s 完成\n", mode);
        return 0;
    }
    fprintf(stderr, "[estale-fixture] 子进程异常 status=%#x\n", status);
    return 5;
}

int main(int argc, char **argv) {
    if (argc > 1) mode = argv[1];
    if (argc > 2) {
        if (!strcmp(mode, "churn") || !strcmp(mode, "precise")) churn_us = atol(argv[2]);
        else if (!strcmp(mode, "swap")) swap_unmap = !strcmp(argv[2], "unmap");
    }
    if (argc > 3) model_page = (size_t)atol(argv[3]);
    int rc = setup();
    if (rc == 1) return 0;                                                 // SKIP
    if (rc) return rc;
    expect_abort = !strcmp(mode, "d2") || !strcmp(mode, "writer-timeout");
    return spawn();
}
