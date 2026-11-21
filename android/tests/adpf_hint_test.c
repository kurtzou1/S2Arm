// Host contract: only Android's ADPF API, thread identity, and monotonic clock are faked.
// 生产的 system_tuning.c（本局最短周期）原样链入；/proc/self/task 读数、可选 API 能力位、日志由下面的替身给。
#include "adpf_hint.h"
#include "system_tuning.h"
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
static int failed;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); failed++; } } while (0)
static int64_t clock_ns;
static int32_t thread_id;
static int creates, reports, closes, updates, fail_report, fail_create, fail_update;
static int active_during_report;
static int enabled = 1;
int s2a_adpf_test_enabled(void) { return enabled; }
static int32_t created_tid;
static int64_t created_target, actual, updated_target;
uint64_t s2a_adpf_test_now(void) { return (uint64_t)clock_ns; }
int32_t s2a_adpf_test_tid(void) { return thread_id; }
static int caps;                                   // 位：1 setThreads、2 report2、4 notifyWorkloadIncrease、8 图形管线会话
int s2a_adpf_test_caps(void) { return caps; }
static int32_t created_tids[8]; static size_t created_n; static int created_pipeline;
void *s2a_adpf_test_create(const int32_t *tids, size_t n, int64_t target, int *pipeline) {
    creates++; created_tid=n ? tids[0] : 0; created_target=target;
    created_n = n; memcpy(created_tids, tids, sizeof tids[0] * (n < 8 ? n : 8));
    *pipeline = created_pipeline = (caps & 8) != 0;
    return fail_create ? NULL : (void *)(uintptr_t)1;
}
static int set_threads_n, set_threads_fail; static int32_t set_tids[8]; static size_t set_n;
int s2a_adpf_test_set_threads(void *s, const int32_t *tids, size_t n) {
    (void)s; set_threads_n++;
    if (set_threads_fail) return 22;
    set_n = n; memcpy(set_tids, tids, sizeof tids[0] * (n < 8 ? n : 8)); return 0;
}
static int report2_n; static int64_t r2_start, r2_total, r2_cpu, r2_gpu;
int s2a_adpf_test_report2(void *s, int64_t start, int64_t total, int64_t cpu, int64_t gpu) {
    (void)s; report2_n++; r2_start=start; r2_total=total; r2_cpu=cpu; r2_gpu=gpu; return 0;
}
static int increase_n, inc_cpu, inc_gpu;
int s2a_adpf_test_increase(void *s, int cpu, int gpu) { (void)s; increase_n++; inc_cpu=cpu; inc_gpu=gpu; return 0; }
static struct s2a_adpf_task tasks[16]; static int ntasks, task_reads;
int s2a_adpf_test_read_tasks(struct s2a_adpf_task *out, int max) {
    task_reads++; int n = ntasks < max ? ntasks : max; memcpy(out, tasks, sizeof tasks[0] * (size_t)n); return n;
}
static char logbuf[8192];
void s2a_adpf_test_log(const char *fmt, ...) {
    size_t o = strlen(logbuf); if (o + 2 >= sizeof logbuf) return;
    va_list ap; va_start(ap, fmt); vsnprintf(logbuf + o, sizeof logbuf - o - 1, fmt, ap); va_end(ap);
    strcat(logbuf, "\n");
}
static int log_count(const char *needle) { int n = 0; for (const char *p = logbuf; (p = strstr(p, needle)); p++) n++; return n; }
int s2a_adpf_test_update(void *s, int64_t target) { (void)s; updates++; updated_target=target; return fail_update; }
int s2a_adpf_test_report(void *s, int64_t ns) {
    (void)s;
    active_during_report = s2a_adpf_session_active();
    reports++; actual=ns; return fail_report;
}
void s2a_adpf_test_close(void *s) { (void)s; closes++; }
static void test_lifecycle(void) {
    s2a_adpf_test_reset(); s2a_android_session_period_reset(); caps = 0;
    CHECK(!s2a_adpf_session_active());
    s2a_adpf_set_foreground(1); s2a_adpf_set_surface(1);
    // First frame: session is created for the worker tid at 3/4 of the present period (本局还没登记周期：用本帧的，16,666,667 × 3/4 = 12,500,000);
    // the reported span is measured begin->end, never the interval itself.
    thread_id=42; clock_ns=1000000000; s2a_adpf_work_begin(1);
    clock_ns=1005000000; s2a_adpf_work_begin(1);           // same frame: first begin wins
    clock_ns=1012000000; s2a_adpf_frame_end(16666667, 1);
    CHECK(creates==1 && created_tid==42 && created_n==1 && created_target==12500000);
    CHECK(reports==1 && actual==12000000);
    CHECK(!active_during_report && s2a_adpf_session_active());
    // Same target is not re-updated; a real target change is.
    clock_ns=2000000000; s2a_adpf_work_begin(2); clock_ns=2020000000; s2a_adpf_frame_end(16666667, 2);
    CHECK(updates==0 && reports==2 && actual==20000000);
    clock_ns=2030000000; s2a_adpf_work_begin(3); clock_ns=2040000000; s2a_adpf_frame_end(33333334, 3);
    CHECK(updates==1 && updated_target==25000000 && reports==3 && actual==10000000);   // 33,333,334 × 3/4 = 25,000,000
    // A failed report closes the session and rate-limits a retry for a second.
    fail_report=1; clock_ns=2050000000; s2a_adpf_work_begin(4); clock_ns=2060000000; s2a_adpf_frame_end(33333334, 4);
    CHECK(reports==4 && closes==1);
    CHECK(!s2a_adpf_session_active());
    fail_report=0; clock_ns=2500000000; s2a_adpf_work_begin(5); clock_ns=2510000000; s2a_adpf_frame_end(33333334, 5);
    CHECK(creates==1 && reports==4);
    clock_ns=3061000000; s2a_adpf_work_begin(6); clock_ns=3071000000; s2a_adpf_frame_end(33333334, 6);
    CHECK(creates==2 && reports==5);
    CHECK(s2a_adpf_session_active());
    // Backgrounding closes the session; work while backgrounded is not recorded.
    s2a_adpf_set_foreground(0); CHECK(closes==2);
    CHECK(!s2a_adpf_session_active());
    clock_ns=3200000000; s2a_adpf_work_begin(7); clock_ns=3210000000; s2a_adpf_frame_end(33333334, 7);
    CHECK(creates==2 && reports==5);
    s2a_adpf_set_foreground(1);
    clock_ns=3300000000; s2a_adpf_work_begin(8); clock_ns=3310000000; s2a_adpf_frame_end(33333334, 8);
    CHECK(creates==3 && reports==6);
    // A span whose present never ran (seq mismatch) is dropped, not charged on.
    clock_ns=3400000000; s2a_adpf_work_begin(9);
    clock_ns=3450000000; s2a_adpf_frame_end(33333334, 10);   // present skipped frame 9
    CHECK(reports==6);
    // ...and a later frame's first job replaces the stale record.
    clock_ns=3500000000; s2a_adpf_work_begin(11);
    clock_ns=3510000000; s2a_adpf_frame_end(33333334, 11);
    CHECK(reports==7 && actual==10000000);
    // A stale pending record from before the mismatch is likewise discarded.
    clock_ns=3600000000; s2a_adpf_work_begin(12);          // frame 12 work begins
    clock_ns=3610000000; s2a_adpf_work_begin(13);          // rollover: 12 never presented
    clock_ns=3620000000; s2a_adpf_frame_end(33333334, 13); // reports 13's span, not 12's
    CHECK(reports==8 && actual==10000000);
    // invisible() closes without touching host lifecycle; next visible frame recreates.
    s2a_adpf_invisible(); CHECK(closes==3);
    clock_ns=3700000000; s2a_adpf_work_begin(14); clock_ns=3710000000; s2a_adpf_frame_end(33333334, 14);
    CHECK(creates==4 && reports==9);
    // Surface loss closes and gates recording; restore resumes.
    s2a_adpf_set_surface(0); CHECK(closes==4);
    CHECK(!s2a_adpf_session_active());
    clock_ns=3800000000; s2a_adpf_work_begin(15); clock_ns=3810000000; s2a_adpf_frame_end(33333334, 15);
    CHECK(creates==4 && reports==9);
    s2a_adpf_set_surface(1);
    clock_ns=3900000000; s2a_adpf_work_begin(16); clock_ns=3910000000; s2a_adpf_frame_end(33333334, 16);
    CHECK(creates==5 && reports==10);
    // debug.s2a.adpf=0 (faked): nothing is recorded or reported while off, and
    // the open session is closed. The property is re-polled only ~1/s, so the
    // re-enable frame must sit more than a second later.
    enabled=0; clock_ns=4100000000; s2a_adpf_work_begin(17); clock_ns=4110000000; s2a_adpf_frame_end(33333334, 17);
    CHECK(creates==5 && reports==10 && closes==5);
    CHECK(!s2a_adpf_session_active());
    enabled=1; clock_ns=5200000000; s2a_adpf_work_begin(18); clock_ns=5210000000; s2a_adpf_frame_end(33333334, 18);
    CHECK(creates==6 && reports==11);
    // A changed owner replaces the session; no work from different threads is mixed.
    thread_id=43; clock_ns=5300000000; s2a_adpf_work_begin(19); clock_ns=5310000000; s2a_adpf_frame_end(33333334, 19);
    CHECK(creates==7 && created_tid==43 && closes==6 && reports==12);
    // update failure also closes + retries after a second.
    fail_update=1; clock_ns=5400000000; s2a_adpf_work_begin(20); clock_ns=5410000000; s2a_adpf_frame_end(16666667, 20);
    CHECK(updates==2 && closes==7 && reports==12);
    fail_update=0; clock_ns=5500000000; s2a_adpf_work_begin(21); clock_ns=5510000000; s2a_adpf_frame_end(16666667, 21);
    CHECK(creates==7 && reports==12);
    clock_ns=6420000000; s2a_adpf_work_begin(22); clock_ns=6430000000; s2a_adpf_frame_end(16666667, 22);
    CHECK(creates==8 && reports==13);
    // create failure retries after a second too (close first: a live session
    // would just report instead of creating).
    s2a_adpf_invisible(); CHECK(closes==8);
    fail_create=1; clock_ns=6500000000; s2a_adpf_work_begin(23); clock_ns=6510000000; s2a_adpf_frame_end(16666667, 23);
    CHECK(creates==9 && reports==13);
    CHECK(!s2a_adpf_session_active());
    fail_create=0; clock_ns=6600000000; s2a_adpf_work_begin(24); clock_ns=6610000000; s2a_adpf_frame_end(16666667, 24);
    CHECK(creates==9 && reports==13);
    clock_ns=7520000000; s2a_adpf_work_begin(25); clock_ns=7530000000; s2a_adpf_frame_end(16666667, 25);
    CHECK(creates==10 && reports==14);
    // A present without work reports nothing; a zero/negative target reports nothing.
    clock_ns=7600000000; s2a_adpf_frame_end(16666667, 26);
    CHECK(reports==14);
    clock_ns=7610000000; s2a_adpf_work_begin(27); clock_ns=7620000000; s2a_adpf_frame_end(0, 27);
    CHECK(reports==14);
    // Stop latches: closes the session and blocks further work.
    s2a_adpf_stop(); CHECK(closes==9);
    CHECK(!s2a_adpf_session_active());
    clock_ns=7700000000; s2a_adpf_work_begin(28); clock_ns=7710000000; s2a_adpf_frame_end(16666667, 28);
    CHECK(creates==10 && reports==14);
    CHECK(report2_n==0 && increase_n==0 && set_threads_n==0 && task_reads==0);   // API 33 能力：新路径一次都不走
}

// 一帧：t 毫秒开工、做 work 毫秒后到出图点
static uint64_t seqn = 1000;
static void frame(int64_t t_ms, int64_t work_ms, int64_t period) {
    seqn++; clock_ns = t_ms * 1000000; s2a_adpf_work_begin(seqn);
    clock_ns = (t_ms + work_ms) * 1000000; s2a_adpf_frame_end(period, seqn);
}
static void frame_us(int64_t t_us, int64_t work_us, int64_t period) {
    seqn++; clock_ns = t_us * 1000; s2a_adpf_work_begin(seqn);
    clock_ns = (t_us + work_us) * 1000; s2a_adpf_frame_end(period, seqn);
}
static void set_tasks(const struct s2a_adpf_task *t, int n) { memcpy(tasks, t, sizeof t[0] * (size_t)n); ntasks = n; }

// 本局最短周期与 ADPF 目标（手算）：16,666,667 × 3/4 = 12,500,000；33,333,334 × 3/4 = 25,000,000；8,333,333 封到 16,666,667
static void test_target(void) {
    CHECK(s2a_adpf_target_ns(33333334) == 25000000);
    CHECK(s2a_adpf_target_ns(16666667) == 12500000);
    CHECK(s2a_adpf_target_ns(0) == 0);
    s2a_android_session_period_reset();
    CHECK(s2a_android_session_period_ns() == 0);
    s2a_android_present_note(16666667); s2a_android_present_note(33333334);
    CHECK(s2a_android_session_period_ns() == 16666667 && s2a_android_present_ns() == 33333334);
    s2a_android_present_note(0);                                   // 0 = 无上限路径：没有判据（同原先），但最短值留着
    CHECK(s2a_android_session_period_ns() == 0);
    s2a_android_present_note(33333334);
    CHECK(s2a_android_session_period_ns() == 16666667);
    s2a_android_session_period_reset();
    s2a_android_present_note(8333333); s2a_android_present_note(33333334);   // 120 帧周期：封到 60 帧
    CHECK(s2a_android_session_period_ns() == 16666667);
    s2a_android_set_battery_limit(1);                              // 省电档：按 30 帧判
    CHECK(s2a_android_session_period_ns() == 33333334);
    s2a_android_set_battery_limit(0);
    // 接线：本局最短 16.7 ms（菜单跑过 60 帧）、当前周期 33.3 ms → 会话目标跟当前周期 = 25,000,000，不是 12,500,000
    s2a_adpf_test_reset(); caps = 0;
    s2a_adpf_set_foreground(1); s2a_adpf_set_surface(1); thread_id = 42;
    s2a_android_session_period_reset(); s2a_android_present_note(16666667); s2a_android_present_note(33333334);
    const int c0 = creates;
    frame(10000, 20, 33333334);
    CHECK(creates == c0 + 1 && created_target == 25000000);
    frame(10100, 20, 16666667);                                    // 回到 60 帧档：目标跟着收紧到 12,500,000
    CHECK(updated_target == 12500000);
    s2a_android_session_period_reset();
}

// 忙线程挑选（hz 100、1 秒窗口 → 门槛 15 滴答）
static void test_pick(void) {
    const struct s2a_adpf_task prev[] = {{10,100},{11,100},{20,100},{21,100},{22,100},{23,100},{24,100}};
    const struct s2a_adpf_task cur[] = {{10,150},{11,103},{20,180},{21,114},{22,140},{23,115},{24,160},{30,900}};
    int32_t out[8]; const int32_t must1[] = {10}, must2[] = {10, 11};
    // 6 条线程（不计 11、30）：呈现 10 必入；20(80) 24(60) 22(40) 23(15，正好门槛) 入；21(14) 不够；30 上次不在、不算
    int n = s2a_adpf_pick_threads(cur, 8, prev, 7, 1000000000ull, 100, must1, 1, out, 5);
    CHECK(n == 5 && out[0] == 10 && out[1] == 20 && out[2] == 24 && out[3] == 22 && out[4] == 23);
    // 录制线程 11 只用了 3 滴答也必入；合计 5 条，最闲的 23 被挤掉
    n = s2a_adpf_pick_threads(cur, 8, prev, 7, 1000000000ull, 100, must2, 2, out, 5);
    CHECK(n == 5 && out[0] == 10 && out[1] == 11 && out[2] == 20 && out[3] == 24 && out[4] == 22);
    // 2 秒窗口 → 门槛 30 滴答：只剩 20 24 22
    n = s2a_adpf_pick_threads(cur, 8, prev, 7, 2000000000ull, 100, must1, 1, out, 5);
    CHECK(n == 4 && out[0] == 10 && out[1] == 20 && out[2] == 24 && out[3] == 22);
}

// 负载上升信号（周期 16,666,667 → 线 17,500,000，严格大于才算超）
static void test_load(void) {
    struct s2a_adpf_load st; memset(&st, 0, sizeof st);
    const int64_t P = 16666667;
    int fired[16] = {0};
    const uint64_t t[] = {1000000000, 1017000000, 1034000000, 1051000000, 1068000000, 1085000000, 1102000000, 1119000000, 1534000000};
    const int64_t w[] = {18000000, 18000000, 18000000, 18000000, 17500000, 18000000, 18000000, 18000000, 18000000};
    for (int i = 0; i < 9; i++) fired[i] = s2a_adpf_load_step(&st, w[i], 0, P, t[i]);
    // 第 3 帧发；第 4 帧离上次 17 ms 不发；第 5 帧 17.5 ms 不算超、清零；第 6–8 帧又连 3 帧但离上次 85 ms 不发；第 9 帧离上次正好 0.5 s 发
    const int want[] = {0, 0, 1, 0, 0, 0, 0, 0, 1};
    for (int i = 0; i < 9; i++) CHECK(fired[i] == want[i]);
    memset(&st, 0, sizeof st);                                     // 线上：17,500,000 连 3 帧不发，17,500,001 连 3 帧发
    for (int i = 0; i < 3; i++) CHECK(!s2a_adpf_load_step(&st, 17500000, 0, P, 10 + (uint64_t)i));
    CHECK(!s2a_adpf_load_step(&st, 17500001, 0, P, 20)); CHECK(!s2a_adpf_load_step(&st, 17500001, 0, P, 21));
    CHECK(s2a_adpf_load_step(&st, 17500001, 0, P, 22));
    memset(&st, 0, sizeof st);                                     // GPU 超、CPU 不超也算
    CHECK(!s2a_adpf_load_step(&st, 10000000, 18000000, P, 1)); CHECK(!s2a_adpf_load_step(&st, 10000000, 18000000, P, 2));
    CHECK(s2a_adpf_load_step(&st, 10000000, 18000000, P, 3));
}

// 全能力（API 36）接线：录制线程常驻、GPU 时长上报、负载信号、每 300 帧扫线程
static void test_full(void) {
    s2a_adpf_test_reset(); s2a_android_session_period_reset(); caps = 15; logbuf[0] = 0;
    set_threads_n = report2_n = increase_n = task_reads = 0;
    s2a_android_present_note(16666667);
    s2a_adpf_set_foreground(1); s2a_adpf_set_surface(1);
    thread_id = 77; s2a_adpf_pin_self();                           // 录制线程起点登记
    thread_id = 42;
    const struct s2a_adpf_task a[] = {{42,1000},{77,1000},{20,1000},{21,1000},{22,1000},{23,1000},{24,1000}};
    set_tasks(a, 7);
    const int c0 = creates, r0 = reports;
    frame(20000, 12, 16666667);                                    // 第 1 帧：建会话 + 记扫描基线
    CHECK(creates == c0 + 1 && created_n == 2 && created_tids[0] == 42 && created_tids[1] == 77 && created_target == 12500000 && created_pipeline);
    CHECK(log_count("[s2a-adpf] session tid=42 threads=2 api=36 pipeline=1 target_ns=12500000") == 1);
    CHECK(task_reads == 1 && set_threads_n == 0);
    // GPU：两段 5 + 3 ms 结成一帧，下一次上报带 8 ms；之后没有新帧就退回只报 CPU
    s2a_adpf_gpu_segment(5000000); s2a_adpf_gpu_segment(3000000); s2a_adpf_gpu_frame_end();
    frame(20020, 12, 16666667);
    CHECK(report2_n == 1 && r2_gpu == 8000000 && r2_total == 12000000 && r2_cpu == 12000000 && r2_start == 20020000000LL);
    CHECK(reports == r0 + 1);                                      // 第 2 帧走 report2，不再报一次旧接口
    CHECK(log_count("[s2a-adpf] report2 ok") == 1);
    frame(20040, 12, 16666667);
    CHECK(report2_n == 1 && reports == r0 + 2);
    // 负载：18 ms 连 3 帧（第 4、5、6 帧）→ 第 6 帧发一次；GPU 0 不到 70% → 只报 CPU
    frame(20060, 18, 16666667); frame(20080, 18, 16666667); CHECK(increase_n == 0);
    frame(20100, 18, 16666667); CHECK(increase_n == 1 && inc_cpu == 1 && inc_gpu == 0);
    CHECK(log_count("[s2a-adpf] workload increase ok") == 1);
    frame(20120, 18, 16666667); CHECK(increase_n == 1);            // 离上次 20 ms
    // 帧按 20 ms 一格排（第 k 帧在 20000 + 20(k−1) ms）。第 8–35 帧 12 ms；第 36 帧 10 ms 清零；
    //   第 37–39 帧 CPU 18 ms、GPU 12 ms（> 11,666,662 = 周期的 7/10）→ 第 39 帧发、带 GPU（离上次 0.66 s）
    for (int k = 8; k <= 35; k++) frame(20000 + 20 * (k - 1), 12, 16666667);
    frame(20000 + 20 * 35, 10, 16666667);
    for (int k = 37; k <= 39; k++) {
        s2a_adpf_gpu_segment(12000000); s2a_adpf_gpu_frame_end();
        frame(20000 + 20 * (k - 1), 18, 16666667);
        CHECK(increase_n == (k == 39 ? 2 : 1));
    }
    CHECK(inc_gpu == 1);
    CHECK(log_count("[s2a-adpf] workload increase ok") == 1);      // 只打第一次
    // 第 301 帧时扫第二次。第 1 帧结束在 20.012 s，第 301 帧结束在 26.012 s：窗口 6 s → 门槛 90 滴答
    const struct s2a_adpf_task b[] = {{42,1400},{77,1010},{20,1500},{21,1089},{22,1200},{23,1090},{24,1300}};
    set_tasks(b, 7);
    for (int k = 40; k <= 300; k++) frame(20000 + 20 * (k - 1), 12, 16666667);
    CHECK(task_reads == 1 && set_threads_n == 0);
    frame(20000 + 20 * 300, 12, 16666667);
    CHECK(task_reads == 2);
    // 42 呈现、77 录制（只用 10 滴答也在）；20(500) 24(300) 22(200) 入；23(90 正好门槛) 被 5 条上限挤掉；21(89) 不够
    CHECK(set_threads_n == 1 && set_n == 5 && set_tids[0] == 42 && set_tids[1] == 77 && set_tids[2] == 20 && set_tids[3] == 24 && set_tids[4] == 22);
    CHECK(log_count("[s2a-adpf] threads=5: 42 77 20 24 22") == 1);
    // 第 601 帧：20 闲了（增量 0）移出，23 用了 95 入
    const struct s2a_adpf_task c[] = {{42,1800},{77,1020},{20,1500},{21,1100},{22,1400},{23,1185},{24,1600}};
    set_tasks(c, 7);
    for (int k = 302; k <= 601; k++) frame(20000 + 20 * (k - 1), 12, 16666667);
    CHECK(task_reads == 3 && set_threads_n == 2 && set_n == 5);
    CHECK(set_tids[0] == 42 && set_tids[1] == 77 && set_tids[2] == 24 && set_tids[3] == 22 && set_tids[4] == 23);
    // setThreads 被拒：成员不变（下一次扫描时仍按旧成员比对，再试）
    const struct s2a_adpf_task d[] = {{42,2200},{77,1030},{20,1700},{21,1100},{22,1400},{23,1185},{24,1600}};
    set_tasks(d, 7); set_threads_fail = 1;
    for (int k = 602; k <= 901; k++) frame(20000 + 20 * (k - 1), 12, 16666667);
    CHECK(task_reads == 4 && set_threads_n == 3 && set_tids[2] == 24);
    CHECK(log_count("[s2a-adpf] setThreads refused") == 1);
    set_threads_fail = 0;
    // 第二条常驻线程中途登记：下一帧补进会话（不等扫描）
    thread_id = 78; s2a_adpf_pin_self(); thread_id = 42;
    frame(20000 + 20 * 901, 12, 16666667);
    CHECK(set_threads_n == 4 && set_tids[0] == 42 && set_tids[1] == 77 && set_tids[2] == 78);
    s2a_adpf_stop();
}

// API 33（没有 setThreads）：常驻线程登记后只能重建会话带上它；不扫线程、不走 report2 / 负载信号
static void test_api33(void) {
    s2a_adpf_test_reset(); s2a_android_session_period_reset(); caps = 0; logbuf[0] = 0;
    set_threads_n = report2_n = increase_n = task_reads = 0;
    s2a_adpf_set_foreground(1); s2a_adpf_set_surface(1); thread_id = 42;
    const int c0 = creates;
    frame_us(30000000, 12000, 16666667);
    CHECK(creates == c0 + 1 && created_n == 1 && !created_pipeline);
    CHECK(log_count("api=33 pipeline=0") == 1);
    thread_id = 77; s2a_adpf_pin_self(); thread_id = 42;
    s2a_adpf_gpu_segment(9000000); s2a_adpf_gpu_frame_end();
    for (int i = 1; i <= 400; i++) frame_us(30000000 + 20000 * i, 18000, 16666667);
    CHECK(creates == c0 + 2 && created_n == 2 && created_tids[1] == 77);
    CHECK(set_threads_n == 0 && report2_n == 0 && increase_n == 0 && task_reads == 0);
    s2a_adpf_stop();
}

int main(void) {
    test_lifecycle();
    test_target();
    test_pick();
    test_load();
    test_full();
    test_api33();
    if (failed) { fprintf(stderr, "adpf: %d checks failed\n", failed); return 1; }
    printf("adpf host lifecycle: passed\n"); return 0;
}
