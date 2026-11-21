// SPDX-License-Identifier: Apache-2.0
// ADPF is a scheduling hint; it does not choose CPUs or prove performance.
// All session calls and the pending span are serialized by mu because the NDK
// session API is not thread safe. The recorded worker (async translation thread
// or, in synchronous mode, the submit caller) may differ from the presenter.
// 补齐（参照 nx2android perf_android.c、BananaNative vka_perf.c、BOTWRecompAndroid，均 MIT）：多线程入会（API 34 setThreads）、
// 带 GPU 时长上报（API 35 reportActualWorkDuration2）、负载上升信号（API 36 notifyWorkloadIncrease）、图形管线会话
// （API 36 ASessionCreationConfig_setGraphicsPipeline）。符号全部运行时查，缺哪个就退回现状那一步，不报错不拦。
#include "adpf_hint.h"
#include "system_tuning.h"
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <time.h>
#include <limits.h>
#include <string.h>
#include <stdio.h>
#ifndef S2A_ADPF_TEST
#include <dirent.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <android/log.h>
#include <sys/system_properties.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

enum { ADPF_MAX_THREADS = 5, ADPF_MAX_PINNED = 4, ADPF_SCAN_FRAMES = 300, ADPF_MAX_TASKS = 512 };
// 运行时探到的可选能力（backend_caps）：缺哪一位就走那一步的旧行为
enum { CAP_THREADS = 1, CAP_REPORT2 = 2, CAP_INCREASE = 4, CAP_PIPELINE = 8 };
typedef void *(*create_fn)(const int32_t *, size_t, int64_t, int *);
typedef int (*duration_fn)(void *, int64_t);
typedef void (*close_fn)(void *);
typedef int (*threads_fn)(void *, const int32_t *, size_t);
typedef int (*report2_fn)(void *, int64_t, int64_t, int64_t, int64_t);
typedef int (*increase_fn)(void *, int, int);
#ifdef S2A_ADPF_TEST
extern uint64_t s2a_adpf_test_now(void);
extern int32_t s2a_adpf_test_tid(void);
extern void *s2a_adpf_test_create(const int32_t *, size_t, int64_t, int *);
extern int s2a_adpf_test_update(void *, int64_t);
extern int s2a_adpf_test_report(void *, int64_t);
extern void s2a_adpf_test_close(void *);
extern int s2a_adpf_test_enabled(void);
extern int s2a_adpf_test_caps(void);
extern int s2a_adpf_test_set_threads(void *, const int32_t *, size_t);
extern int s2a_adpf_test_report2(void *, int64_t, int64_t, int64_t, int64_t);
extern int s2a_adpf_test_increase(void *, int, int);
extern int s2a_adpf_test_read_tasks(struct s2a_adpf_task *, int);
extern void s2a_adpf_test_log(const char *, ...) __attribute__((format(printf, 1, 2)));
#define ADPF_LOG(...) s2a_adpf_test_log(__VA_ARGS__)
static uint64_t monotonic_ns(void) { return s2a_adpf_test_now(); }
static int32_t current_tid(void) { return s2a_adpf_test_tid(); }
static create_fn backend_create = s2a_adpf_test_create;
static duration_fn backend_update = s2a_adpf_test_update, backend_report = s2a_adpf_test_report;
static close_fn backend_close = s2a_adpf_test_close;
static threads_fn backend_set_threads = s2a_adpf_test_set_threads;
static report2_fn backend_report2 = s2a_adpf_test_report2;
static increase_fn backend_increase = s2a_adpf_test_increase;
static int backend_init(void) { return 1; }
static void backend_release(void) {}
static int backend_caps(void) { return s2a_adpf_test_caps(); }
static int platform_enabled(void) { return s2a_adpf_test_enabled(); }
static int read_tasks(struct s2a_adpf_task *out, int max) { return s2a_adpf_test_read_tasks(out, max); }
static long clk_tck(void) { return 100; }
#else
struct APerformanceHintManager;
struct APerformanceHintSession;
struct AWorkDuration;
struct ASessionCreationConfig;
static struct APerformanceHintManager *(*get_manager)(void);
static struct APerformanceHintSession *(*create_session)(struct APerformanceHintManager *, const int32_t *, size_t, int64_t);
static int (*update_session)(struct APerformanceHintSession *, int64_t);
static int (*report_session)(struct APerformanceHintSession *, int64_t);
static void (*close_session)(struct APerformanceHintSession *);
static int (*set_threads_session)(struct APerformanceHintSession *, const pid_t *, size_t);  // API 34
static int (*report2_session)(struct APerformanceHintSession *, struct AWorkDuration *);  // API 35
static struct AWorkDuration *(*wd_create)(void);
static void (*wd_release)(struct AWorkDuration *);
static void (*wd_start)(struct AWorkDuration *, int64_t), (*wd_total)(struct AWorkDuration *, int64_t),
            (*wd_cpu)(struct AWorkDuration *, int64_t), (*wd_gpu)(struct AWorkDuration *, int64_t);
static int (*increase_session)(struct APerformanceHintSession *, _Bool, _Bool, const char *);  // API 36
static struct ASessionCreationConfig *(*cfg_create)(void);
static void (*cfg_release)(struct ASessionCreationConfig *),
            (*cfg_tids)(struct ASessionCreationConfig *, const pid_t *, size_t),
            (*cfg_target)(struct ASessionCreationConfig *, int64_t),
            (*cfg_pipeline)(struct ASessionCreationConfig *, _Bool);
static int (*create_with_cfg)(struct APerformanceHintManager *, struct ASessionCreationConfig *, struct APerformanceHintSession **);
static int caps;
static struct AWorkDuration *work_duration;   // 复用的 AWorkDuration（只在 mu 里用）
#define ADPF_LOG(...) __android_log_print(ANDROID_LOG_INFO, "S2Arm", __VA_ARGS__)
// Default on; debug.s2a.adpf=0 switches it off at runtime (polled ~1 Hz).
static int platform_enabled(void) {
    char value[PROP_VALUE_MAX] = {0};
    return __system_property_get("debug.s2a.adpf", value) <= 0 || strcmp(value, "0") != 0;
}
static void *android_lib;
static int attempted_load, api_supported;
static uint64_t monotonic_ns(void) {
    struct timespec t;
    return clock_gettime(CLOCK_MONOTONIC, &t) ? 0 : (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static int32_t current_tid(void) {
#if defined(__APPLE__)
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);   // macOS 无 SYS_gettid，仅宿主语法检查走到
    return (int32_t)tid;
#else
    return (int32_t)syscall(SYS_gettid);
#endif
}
// API 36 先建「图形管线」会话（平台把上报的 GPU 时长也当 GPU 调频输入，参照 BananaNative vka_perf.c），被拒就建普通会话
static void *backend_create_real(const int32_t *tids, size_t n, int64_t target, int *pipeline) {
    struct APerformanceHintManager *manager = get_manager();
    *pipeline = 0;
    if (!manager) return NULL;
    if (caps & CAP_PIPELINE) {
        struct ASessionCreationConfig *c = cfg_create();
        if (c) {
            struct APerformanceHintSession *s = NULL;
            cfg_tids(c, tids, n); cfg_target(c, target); cfg_pipeline(c, 1);
            const int r = create_with_cfg(manager, c, &s);
            cfg_release(c);
            if (!r && s) { *pipeline = 1; return s; }
            static int logged;
            if (logged++ < 2) ADPF_LOG("[s2a-adpf] graphics pipeline session refused (%d); plain session", r);
        }
    }
    return create_session(manager, tids, n, target);
}
static int backend_update_real(void *s, int64_t ns) { return update_session(s, ns); }
static int backend_report_real(void *s, int64_t ns) { return report_session(s, ns); }
static void backend_close_real(void *s) { close_session(s); }
static int backend_set_threads_real(void *s, const int32_t *tids, size_t n) { return set_threads_session(s, tids, n); }
static int backend_report2_real(void *s, int64_t start, int64_t total, int64_t cpu, int64_t gpu) {
    if (!work_duration && !(work_duration = wd_create())) return -1;
    wd_start(work_duration, start); wd_total(work_duration, total); wd_cpu(work_duration, cpu); wd_gpu(work_duration, gpu);
    return report2_session(s, work_duration);
}
// 停局：释放复用的 AWorkDuration（mu 里调）
static void backend_release(void) { if (work_duration && wd_release) wd_release(work_duration); work_duration = NULL; }
static int backend_increase_real(void *s, int cpu, int gpu) { return increase_session(s, cpu != 0, gpu != 0, "s2a frame over period"); }
static create_fn backend_create = backend_create_real;
static duration_fn backend_update = backend_update_real, backend_report = backend_report_real;
static close_fn backend_close = backend_close_real;
static threads_fn backend_set_threads = backend_set_threads_real;
static report2_fn backend_report2 = backend_report2_real;
static increase_fn backend_increase = backend_increase_real;
static int backend_caps(void) { return caps; }
static long clk_tck(void) { static long hz; if (!hz) { hz = sysconf(_SC_CLK_TCK); if (hz <= 0) hz = 100; } return hz; }
// /proc/self/task/<tid>/stat 第 14、15 项 utime + stime（时钟滴答；参照 nx2android perf_android.c task_ticks）
static uint64_t task_ticks(int tid) {
    char path[64], b[512];
    snprintf(path, sizeof path, "/proc/self/task/%d/stat", tid);
    FILE *f = fopen(path, "re");
    if (!f) return 0;
    const size_t n = fread(b, 1, sizeof b - 1, f); fclose(f); b[n] = 0;
    const char *c = strrchr(b, ')');
    if (!c) return 0;
    unsigned long long ut = 0, st = 0; int field = 2;
    for (const char *t = c + 1; *t && field < 15; t++)
        if (*t == ' ') { field++; if (field == 14) ut = strtoull(t + 1, NULL, 10); else if (field == 15) st = strtoull(t + 1, NULL, 10); }
    return ut + st;
}
static int read_tasks(struct s2a_adpf_task *out, int max) {
    DIR *d = opendir("/proc/self/task");
    if (!d) return 0;
    int n = 0; struct dirent *e;
    while (n < max && (e = readdir(d))) {
        const int tid = atoi(e->d_name);
        if (tid > 0) { out[n].tid = tid; out[n].ticks = task_ticks(tid); n++; }
    }
    closedir(d);
    return n;
}
// APerformanceHint_* needs API 33+: resolve the symbols lazily so older Android
// keeps running with the hint silently absent instead of failing to load.
// APK 门禁以较高 API 真头核对动态函数类型。生产对象仍可按 API 29 编译，
// 因为 typeof(&symbol) 本身也会触发 availability 检查。
#define ADPF_LOOKUP(ptr, symbol) ((ptr) = (__typeof__(ptr))dlsym(android_lib, #symbol))
#ifdef S2A_ADPF_CHECK_SIGNATURES
#include <android/performance_hint.h>
#define ADPF_LOAD(ptr, symbol) do { \
    _Static_assert(__builtin_types_compatible_p(__typeof__(ptr), __typeof__(&symbol)), #symbol " signature"); \
    ADPF_LOOKUP(ptr, symbol); \
} while (0)
#else
#define ADPF_LOAD ADPF_LOOKUP
#endif
#if defined(S2A_ADPF_CHECK_SIGNATURES) && __ANDROID_API__ >= 36
#define ADPF_LOAD_36 ADPF_LOAD
#else
#define ADPF_LOAD_36 ADPF_LOOKUP
#endif

static int backend_init(void) {
    if (attempted_load) return api_supported;
    attempted_load = 1;
    android_lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
    if (!android_lib) { ADPF_LOG("[s2a-adpf] libandroid.so unavailable; hint disabled"); return 0; }
    ADPF_LOAD(get_manager, APerformanceHint_getManager);
    ADPF_LOAD(create_session, APerformanceHint_createSession);
    ADPF_LOAD(update_session, APerformanceHint_updateTargetWorkDuration);
    ADPF_LOAD(report_session, APerformanceHint_reportActualWorkDuration);
    ADPF_LOAD(close_session, APerformanceHint_closeSession);
    api_supported = get_manager && create_session && update_session && report_session && close_session;
    if (!api_supported) { ADPF_LOG("[s2a-adpf] APerformanceHint_* missing (API<33); hint disabled"); return 0; }
    ADPF_LOAD(set_threads_session, APerformanceHint_setThreads);
    ADPF_LOAD(report2_session, APerformanceHint_reportActualWorkDuration2);
    ADPF_LOAD(wd_create, AWorkDuration_create);
    ADPF_LOAD(wd_start, AWorkDuration_setWorkPeriodStartTimestampNanos);
    ADPF_LOAD(wd_total, AWorkDuration_setActualTotalDurationNanos);
    ADPF_LOAD(wd_cpu, AWorkDuration_setActualCpuDurationNanos);
    ADPF_LOAD(wd_gpu, AWorkDuration_setActualGpuDurationNanos);
    ADPF_LOAD_36(increase_session, APerformanceHint_notifyWorkloadIncrease);
    ADPF_LOAD_36(cfg_create, ASessionCreationConfig_create);
    ADPF_LOAD_36(cfg_release, ASessionCreationConfig_release);
    ADPF_LOAD_36(cfg_tids, ASessionCreationConfig_setTids);
    ADPF_LOAD_36(cfg_target, ASessionCreationConfig_setTargetWorkDurationNanos);
    ADPF_LOAD_36(cfg_pipeline, ASessionCreationConfig_setGraphicsPipeline);
    ADPF_LOAD_36(create_with_cfg, APerformanceHint_createSessionUsingConfig);
    ADPF_LOAD(wd_release, AWorkDuration_release);
    caps = (set_threads_session ? CAP_THREADS : 0)
         | (report2_session && wd_create && wd_start && wd_total && wd_cpu && wd_gpu ? CAP_REPORT2 : 0)
         | (increase_session ? CAP_INCREASE : 0)
         | (cfg_create && cfg_release && cfg_tids && cfg_target && cfg_pipeline && create_with_cfg ? CAP_PIPELINE : 0);
    return api_supported;
}
#endif
// ---- 纯函数 ----
int64_t s2a_adpf_target_ns(int64_t frame_period_ns) {
    // 目标收紧到当前周期的 3/4（参照 BOTWRecompAndroid）：给满整个周期时，21 ms 的帧在 33 ms 目标下显得宽裕，调度器把频率压到
    //   「刚好够」，稍重一帧就晚一个刷新。用当前周期、不用本局最短周期：锁 30 帧的游戏若菜单跑过 60 帧，按最短周期会一直要
    //   12.5 ms 的时钟，白耗电也涨不了帧（ADPF 没有「没收益就退避」）；掉档追回由 CPU 托底按本局最短周期判（它有退避）。
    const int64_t base = frame_period_ns;
    return base > 0 ? base / 4 * 3 + base % 4 * 3 / 4 : 0;   // = floor(base × 3 / 4)，不溢出
}
static int tid_in(const int32_t *a, int n, int32_t t) {
    for (int i = 0; i < n; i++) if (a[i] == t) return 1;
    return 0;
}
// 参照 nx2android perf_android.c hint_threads_scan：增量 ≥ 15% 一个核、从忙到闲依次入，上次扫描不在的新线程这次不算
int s2a_adpf_pick_threads(const struct s2a_adpf_task *cur, int ncur, const struct s2a_adpf_task *prev, int nprev,
                          uint64_t wall_ns, long hz, const int32_t *must, int nmust, int32_t *out, int max) {
    int n = 0;
    for (int i = 0; i < nmust && n < max; i++) if (must[i] > 0 && !tid_in(out, n, must[i])) out[n++] = must[i];
    if (!wall_ns || hz <= 0) return n;
    const double need = 0.15 * (double)wall_ns / 1e9 * (double)hz;   // 滴答数
    while (n < max) {
        int best = -1; uint64_t best_used = 0;
        for (int i = 0; i < ncur; i++) {
            if (cur[i].tid <= 0 || tid_in(out, n, cur[i].tid)) continue;
            int j = 0;
            while (j < nprev && prev[j].tid != cur[i].tid) j++;
            if (j == nprev) continue;
            const uint64_t used = cur[i].ticks > prev[j].ticks ? cur[i].ticks - prev[j].ticks : 0;
            if (used > 0 && (double)used >= need && (best < 0 || used > best_used)) { best = i; best_used = used; }
        }
        if (best < 0) break;
        out[n++] = cur[best].tid;
    }
    return n;
}
// 参照 nx2android perf_android.c hint_report：连续 3 帧超周期 5%、两次至少隔 0.5 s
int s2a_adpf_load_step(struct s2a_adpf_load *st, int64_t work_ns, int64_t gpu_ns, int64_t period_ns, uint64_t now_ns) {
    if (period_ns <= 0) { st->over = 0; return 0; }
    const int64_t worst = work_ns > gpu_ns ? work_ns : gpu_ns;
    st->over = worst > 0 && (double)worst * 100.0 > (double)period_ns * 105.0 ? st->over + 1 : 0;
    if (st->over >= 3 && (!st->last_ns || (now_ns >= st->last_ns && now_ns - st->last_ns >= 500000000ull))) { st->last_ns = now_ns; return 1; }
    return 0;
}

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static int foreground, surface, stopping;
static void *session;
static _Atomic int session_active;
static int32_t session_tid;
static int64_t session_target;
// One in-flight frame span: the sequence it belongs to, the CLOCK_MONOTONIC
// instant its first job began, and the tid that ran that job.
static uint64_t work_seq, work_begin;
static int32_t work_tid;
// Lock-free fast path mirror of work_seq: repeat jobs of the same frame skip mu.
static _Atomic uint64_t pending_seq;
#ifndef S2A_ADPF_TEST
static _Thread_local int32_t cached_tid;
#endif
static uint64_t retry_at;
static uint64_t property_checked;
static int enabled = 1;
// 会话成员（全在 mu 里动）：pinned = 登记的常驻帧线程（录制线程），跨会话保留；extra = 最近一次扫描挑出的忙线程；
//   members = 会话里现在的成员。threads_dirty：pinned 变了，下一帧补进会话。session_gen：扫描在锁外读 /proc，回来时会话换过就作废
static int32_t pinned[ADPF_MAX_PINNED], extra[ADPF_MAX_THREADS], members[ADPF_MAX_THREADS];
static int npinned, nextra, nmembers, threads_dirty, scan_frames;
static uint64_t session_gen;
static struct s2a_adpf_load load;
static int logged_report2, logged_increase, increase_fail_logs, thread_logs;
// GPU 时长：后端段完成线程累加、上屏段完成时结一帧；上报时取走最近结好的一帧（每帧只用一次）
static _Atomic uint64_t gpu_acc, gpu_last;
static _Atomic int gpu_seen;
// 忙线程扫描的上一份快照（scan_mu 里动，不占 mu）
static pthread_mutex_t scan_mu = PTHREAD_MUTEX_INITIALIZER;
static struct s2a_adpf_task scan_prev[ADPF_MAX_TASKS], scan_cur[ADPF_MAX_TASKS];
static int scan_nprev;
static uint64_t scan_prev_ns;
int s2a_adpf_session_active(void) {
    return atomic_load_explicit(&session_active, memory_order_relaxed);
}
static int enabled_locked(uint64_t now) {
    if (!property_checked || now < property_checked || now - property_checked >= 1000000000ULL) {
        int was = enabled;
        enabled = platform_enabled(); property_checked = now;
        if (was != enabled) ADPF_LOG("[s2a-adpf] enabled=%d (debug.s2a.adpf)", enabled);
    }
    return enabled;
}
static void clear_work_locked(void) {
    work_seq = work_begin = 0; work_tid = 0;
    atomic_store_explicit(&pending_seq, 0, memory_order_release);
}
static void close_locked(void) {
    atomic_store_explicit(&session_active, 0, memory_order_relaxed);
    if (session) { ADPF_LOG("[s2a-adpf] close tid=%d", session_tid); backend_close(session); }
    session = NULL; session_tid = 0; session_target = 0;
    nextra = nmembers = 0;
    clear_work_locked();
}
static void fail_locked(uint64_t now) {
    close_locked();
    retry_at = now > UINT64_MAX - 1000000000ULL ? UINT64_MAX : now + 1000000000ULL;
}
// 呈现（测量）线程 + 常驻帧线程 + 扫出的忙线程，去重、合计最多 ADPF_MAX_THREADS 条
static int build_members_locked(int32_t presenter, int32_t *out) {
    int n = 0;
    if (presenter > 0) out[n++] = presenter;
    for (int i = 0; i < npinned && n < ADPF_MAX_THREADS; i++) if (!tid_in(out, n, pinned[i])) out[n++] = pinned[i];
    for (int i = 0; i < nextra && n < ADPF_MAX_THREADS; i++) if (!tid_in(out, n, extra[i])) out[n++] = extra[i];
    return n;
}
static void apply_members_locked(void) {
    int32_t list[ADPF_MAX_THREADS];
    const int n = build_members_locked(session_tid, list);
    threads_dirty = 0;
    int same = n == nmembers;
    for (int i = 0; same && i < n; i++) same = tid_in(members, nmembers, list[i]);
    if (same || !session) return;
    if (backend_set_threads(session, list, (size_t)n)) {   // 被拒（线程刚退出等）：保留原成员，下一次扫描再换
        if (thread_logs++ < 3) ADPF_LOG("[s2a-adpf] setThreads refused (threads=%d)", n);
        return;
    }
    memcpy(members, list, sizeof list[0] * (size_t)n); nmembers = n;
    if (thread_logs++ < 8) {
        char text[96]; int o = 0;
        for (int i = 0; i < n && o < (int)sizeof text; i++) o += snprintf(text + o, sizeof text - o, " %d", list[i]);
        ADPF_LOG("[s2a-adpf] threads=%d:%s", n, text);
    }
}
void s2a_adpf_pin_self(void) {
    const int32_t tid = current_tid();
    if (tid <= 0) return;
    pthread_mutex_lock(&mu);
    if (!tid_in(pinned, npinned, tid) && npinned < ADPF_MAX_PINNED) { pinned[npinned++] = tid; threads_dirty = 1; }
    pthread_mutex_unlock(&mu);
}
void s2a_adpf_gpu_segment(uint64_t gpu_ns) {
    atomic_fetch_add_explicit(&gpu_acc, gpu_ns, memory_order_relaxed);
    atomic_store_explicit(&gpu_seen, 1, memory_order_relaxed);
}
void s2a_adpf_gpu_frame_end(void) {
    if (atomic_exchange_explicit(&gpu_seen, 0, memory_order_relaxed))
        atomic_store_explicit(&gpu_last, atomic_exchange_explicit(&gpu_acc, 0, memory_order_relaxed), memory_order_relaxed);
}
// 每 ADPF_SCAN_FRAMES 帧一次，在呈现线程上、mu 外读 /proc；第一次只记基线
static void threads_scan(uint64_t now, uint64_t gen, const int32_t *must, int nmust) {
    if (pthread_mutex_trylock(&scan_mu)) return;
    const int n = read_tasks(scan_cur, ADPF_MAX_TASKS);
    int32_t pick[ADPF_MAX_THREADS]; int np = 0;
    if (n > 0 && scan_nprev > 0 && now > scan_prev_ns)
        np = s2a_adpf_pick_threads(scan_cur, n, scan_prev, scan_nprev, now - scan_prev_ns, clk_tck(), must, nmust, pick, ADPF_MAX_THREADS);
    if (n > 0) { memcpy(scan_prev, scan_cur, sizeof scan_cur[0] * (size_t)n); scan_nprev = n; scan_prev_ns = now; }
    pthread_mutex_unlock(&scan_mu);
    if (np <= 0) return;
    pthread_mutex_lock(&mu);
    if (session && session_gen == gen) {
        nextra = 0;
        for (int i = 0; i < np; i++) if (!tid_in(must, nmust, pick[i])) extra[nextra++] = pick[i];
        apply_members_locked();
    }
    pthread_mutex_unlock(&mu);
}
void s2a_adpf_set_foreground(int v) {
    pthread_mutex_lock(&mu); foreground = !!v;
    if (!foreground) { close_locked(); retry_at = 0; }
    pthread_mutex_unlock(&mu);
}
void s2a_adpf_set_surface(int v) {
    pthread_mutex_lock(&mu); surface = !!v;
    if (!surface) { close_locked(); retry_at = 0; }
    pthread_mutex_unlock(&mu);
}
void s2a_adpf_work_begin(uint64_t seq) {
    if (!seq || atomic_load_explicit(&pending_seq, memory_order_acquire) == seq) return;
#ifdef S2A_ADPF_TEST
    const int32_t tid = current_tid();
#else
    if (!cached_tid) cached_tid = current_tid();
    const int32_t tid = cached_tid;
#endif
    const uint64_t now = monotonic_ns();
    pthread_mutex_lock(&mu);
    if (now && !enabled_locked(now)) { close_locked(); pthread_mutex_unlock(&mu); return; }
    if (!stopping && foreground && surface && now && tid > 0 && now >= retry_at) {
        if (work_seq != seq) { work_seq = seq; work_begin = now; work_tid = tid; }
        atomic_store_explicit(&pending_seq, work_seq, memory_order_release);
    }
    pthread_mutex_unlock(&mu);
}
static int api_level(int cap) {
    return cap & (CAP_INCREASE | CAP_PIPELINE) ? 36 : cap & CAP_REPORT2 ? 35 : cap & CAP_THREADS ? 34 : 33;
}
void s2a_adpf_frame_end(int64_t target_ns, uint64_t seq) {
    const uint64_t now = monotonic_ns();
    pthread_mutex_lock(&mu);
    if (now && !enabled_locked(now)) { close_locked(); pthread_mutex_unlock(&mu); return; }
    if (work_seq != seq) {
        // A span whose present never ran (skipped/lost frame) is stale: it must
        // not be charged to a later frame. Discard it; the next matching pair
        // records a fresh span.
        clear_work_locked();
        pthread_mutex_unlock(&mu); return;
    }
    const uint64_t began = work_begin; const int32_t tid = work_tid;
    clear_work_locked();
    if (stopping || !foreground || !surface || !began || now <= began || target_ns <= 0 || now < retry_at) {
        pthread_mutex_unlock(&mu); return;
    }
    const uint64_t elapsed = now - began;
    if (elapsed > (uint64_t)INT64_MAX || !backend_init()) { pthread_mutex_unlock(&mu); return; }
    const int cap = backend_caps();
    // 周期 = 本帧周期；ADPF 目标 = 它的 3/4；负载信号对周期本身比，不对收紧后的目标比
    const int64_t period = target_ns;
    const int64_t adpf_target = s2a_adpf_target_ns(target_ns);
    // Preserve the sample before replacing a previous owner's session.
    if (session && session_tid != tid) close_locked();
    if (session && threads_dirty && !(cap & CAP_THREADS)) close_locked();   // API 33 没有 setThreads：换成员只能重建
    if (!session) {
        int32_t list[ADPF_MAX_THREADS];
        const int n = build_members_locked(tid, list);
        int pipeline = 0;
        session = backend_create(list, (size_t)n, adpf_target, &pipeline);
        if (!session) { fail_locked(now); pthread_mutex_unlock(&mu); return; }
        session_tid = tid; session_target = adpf_target;
        memcpy(members, list, sizeof list[0] * (size_t)n); nmembers = n;
        session_gen++; threads_dirty = 0; scan_frames = ADPF_SCAN_FRAMES - 1;   // 本帧就记扫描基线
        memset(&load, 0, sizeof load);
        ADPF_LOG("[s2a-adpf] session tid=%d threads=%d api=%d pipeline=%d target_ns=%lld", tid, n, api_level(cap), pipeline, (long long)adpf_target);
    } else if (threads_dirty) apply_members_locked();
    if (session_target != adpf_target) {
        if (backend_update(session, adpf_target)) { fail_locked(now); pthread_mutex_unlock(&mu); return; }
        session_target = adpf_target;
        ADPF_LOG("[s2a-adpf] target_ns=%lld", (long long)adpf_target);
    }
    const uint64_t g = atomic_exchange_explicit(&gpu_last, 0, memory_order_relaxed);
    const int64_t gpu = g > (uint64_t)INT64_MAX ? INT64_MAX : (int64_t)g;
    int rc = 1;
    if ((cap & CAP_REPORT2) && gpu > 0) {   // API 35：同一帧的 CPU 跨度与 GPU 时长一起报
        rc = backend_report2(session, (int64_t)began, (int64_t)elapsed, (int64_t)elapsed, gpu);
        if (!rc && !logged_report2) { logged_report2 = 1; ADPF_LOG("[s2a-adpf] report2 ok work_ns=%lld gpu_ns=%lld", (long long)elapsed, (long long)gpu); }
    }
    if (rc && backend_report(session, (int64_t)elapsed)) { fail_locked(now); pthread_mutex_unlock(&mu); return; }
    if (!s2a_adpf_session_active()) atomic_store_explicit(&session_active, 1, memory_order_relaxed);
    if ((cap & CAP_INCREASE) && s2a_adpf_load_step(&load, (int64_t)elapsed, gpu, period, now)) {
        const int r = backend_increase(session, 1, gpu > period / 10 * 7);
        if (!r && !logged_increase) { logged_increase = 1; ADPF_LOG("[s2a-adpf] workload increase ok work_ns=%lld gpu_ns=%lld period_ns=%lld", (long long)elapsed, (long long)gpu, (long long)period); }
        else if (r && increase_fail_logs++ < 3) ADPF_LOG("[s2a-adpf] workload increase refused (%d)", r);
    }
    int scan = 0, nmust = 0; int32_t must[ADPF_MAX_THREADS]; const uint64_t gen = session_gen;
    if ((cap & CAP_THREADS) && ++scan_frames >= ADPF_SCAN_FRAMES) {
        scan_frames = 0; scan = 1;
        must[nmust++] = session_tid;
        for (int i = 0; i < npinned && nmust < ADPF_MAX_THREADS; i++) if (!tid_in(must, nmust, pinned[i])) must[nmust++] = pinned[i];
    }
    pthread_mutex_unlock(&mu);
    if (scan) threads_scan(now, gen, must, nmust);
}
void s2a_adpf_discard(void) { pthread_mutex_lock(&mu); clear_work_locked(); pthread_mutex_unlock(&mu); }
void s2a_adpf_invisible(void) { pthread_mutex_lock(&mu); close_locked(); pthread_mutex_unlock(&mu); }
void s2a_adpf_stop(void) { pthread_mutex_lock(&mu); stopping = 1; foreground = surface = 0; close_locked(); backend_release(); pthread_mutex_unlock(&mu); }
#ifdef S2A_ADPF_TEST
void s2a_adpf_test_reset(void) {
    pthread_mutex_lock(&mu); close_locked(); foreground = surface = stopping = 0; retry_at = property_checked = 0; enabled = 1;
    npinned = threads_dirty = scan_frames = 0; logged_report2 = logged_increase = increase_fail_logs = thread_logs = 0;
    memset(&load, 0, sizeof load);
    atomic_store(&gpu_acc, 0); atomic_store(&gpu_last, 0); atomic_store(&gpu_seen, 0);
    pthread_mutex_unlock(&mu);
    pthread_mutex_lock(&scan_mu); scan_nprev = 0; scan_prev_ns = 0; pthread_mutex_unlock(&scan_mu);
}
#endif
