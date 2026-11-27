// 加载页节拍（nvn_mtl.m warm_prepare ↔ 前端 s2a_front_warm_tick，10-30 与真机 / 原生线对齐）：直接包含生产 nvn_mtl.m，前端替身在 warmtick_front_stub.c。
// 清单 = N 条键不在映射表里的着色器行（每条立刻跳过并计完成，1 个工作线程，N 取大让等待循环转好几圈）。期望按约定手写：
//   A 前端第 2 次周期调用返回 1：warm_prepare 返回 0（剩下的转后台），转后台原因 = 玩家；开始那次参数 (0, N)；后台编完后 (N, N) 正好一次
//   B 前端一直返回 0：warm_prepare 返回 1（全部编完才进），之后 warm_finish 发 (N, N) 正好一次（再调一次也不重发）
//   E 有前端时上限不放行（11-22 #502：编译还在往前走就等，等不等由玩家定）：DM_PSO_PREPARE_MAX_MS=100、前端一直返回 0 → 原因从不是上限：全部编完返回 1，
//     或只剩最后在编的一行时 TAIL 放行（同 B）；(N, N) 一次
//   E2 没有前端（替身回 -1，同弱定义：Mac、单测）上限照旧：DM_PSO_PREPARE_MAX_MS=100 → warm_prepare 返回 0、原因 = 上限、返回那一刻还没全部编完，
//     剩下的由后台工人接着编（后台编的行数 > 0），编完 (N, N) 一次（按事件判，不按墙钟）
//   G 清单全部领走、只剩在编的（11-06 异度3：首帧等满 15 s、剩 26 行）：1 个工人、最后一行一直编到 warm_prepare 返回、前端一直返回 0 → warm_prepare 不等那行编完就返回 0（返回时 (N, N) 还没发）、
//     原因 = TAIL、通知前端放行恰好一次；那一行编完后 (N, N) 一次。B 前端一直返回 0 时原先只能「全部编完才返回 1」，现在最后一行在编时放行（TAIL）同样合规
//   H 之后的启动（11-27：首装一次性 loading、之后不卡）：前端开等第一拍就回 1（loadprog.c GO_LATER）→ warm_prepare 返回 0、原因 LATER、返回时前端只被问过 1 次
//     （不进 50 ms 等待循环）、放行时还没全部编完，剩下的后台编完、(N, N) 一次。反证：nvn_mtl.m 不认开等那一拍（原先 front = tick >= 0）→ 原因玩家、问过多次，红
//   F 缺省开：没设 DM_PSO_PREPARE → prepare_on() = 1；DM_PSO_PREPARE=0 → 0
//   C 首帧前宣告（warm_announce，mtl_init 末尾调；10-30 真机线怪猎冷启：首帧回调 0.96 s 先于懒载入的预热，加载页早收）：着色器表旁 pso_manifest.tsv 3 行 + 1 行注释，
//     DM_PSO_PREPARE=1 → 前端恰好收到一次 (0, 3)；D 反证：DM_PSO_MANIFEST=off → 一次都不报
static void t_hold_task(id t);
#define WARM_PREPARE_TASK t_hold_task
#include "../gfx/nvn/nvn_mtl.m"
// G：清单最后一行在工人手里停住（模拟一条编得久的管线）。原先固定停 2 秒：负载高时 warm_prepare 自己拖过 2 秒，那行先编完、放行原因不是 TAIL 就假红。
//   现在停到 warm_prepare 返回（g_t_back）为止，兜底 30 秒（实现错等那行时到点也放，下面按「放行时还没编完」判红）
static NSArray *g_t_tasks; static int g_t_hold; static _Atomic int g_t_back;
static void t_hold_task(id t) { if (g_t_hold && t == g_t_tasks.lastObject) for (int i = 0; i < 30000 && !atomic_load(&g_t_back); i++) usleep(1000); warm_task(t); }
#include <sys/wait.h>
extern _Atomic long g_tick_released, g_tick_calls, g_tick_first_done, g_tick_first_total, g_tick_full; extern long g_tick_enter_at, g_tick_total; extern int g_tick_absent, g_tick_first_ret;
enum { N = 300000 };
static NSArray<WarmTask *> *tasks(void) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:N];
    for (int i = 0; i < N; i++) { WarmTask *t = [WarmTask new]; t->kind = 0; t->stage = 1; t->key = [NSString stringWithFormat:@"%016x_b", i]; [a addObject:t]; }
    return a;
}
static int run(int enter_at) {   // in a child: 0 = everything as expected
    g_tick_enter_at = enter_at; g_tick_total = N;
    NSArray *ts = tasks(); g_t_tasks = ts; uint64_t t0 = bp_now();
    int all = warm_prepare(ts, N); uint64_t back = bp_now() - t0; long full_at_back = atomic_load(&g_tick_full); long calls_at_back = atomic_load(&g_tick_calls);   // 放行那一刻是否已全部编完（事件判据，不靠墙钟）
    atomic_store(&g_t_back, 1);   // G：放开停住的最后一行
    if (all) warm_finish();
    for (int i = 0; i < 3000 && atomic_load(&g_tick_full) == 0; i++) usleep(10000);   // A: the rest finishes in the background, then warm_finish
    warm_finish();   // a second call must not send (N, N) again
    long calls = atomic_load(&g_tick_calls), full = atomic_load(&g_tick_full);
    printf("  enter_at=%d：返回 %d、原因 %d、调用 %ld 次、开始 (%ld, %ld)、(N, N) %ld 次、用时 %.2f s\n", enter_at, all, atomic_load(&g_wp_why), calls,
           atomic_load(&g_tick_first_done), atomic_load(&g_tick_first_total), full, (bp_now() - t0) / 1e9);
    int ok = atomic_load(&g_tick_first_done) == 0 && atomic_load(&g_tick_first_total) == N && full == 1;
    if (enter_at) ok = ok && all == 0 && atomic_load(&g_wp_why) == WARM_WHY_PLAYER && calls >= 3;
    else if (g_tick_first_ret == 1) { printf("  之后的启动：返回 %d、原因 %d、返回时问过前端 %ld 次、%.0f ms 后放行、放行时 (N, N) %ld 次\n", all, atomic_load(&g_wp_why), calls_at_back, back / 1e6, full_at_back);
        ok = ok && all == 0 && atomic_load(&g_wp_why) == WARM_WHY_LATER && calls_at_back == 1 && full_at_back == 0; }
    else if (getenv("T_WARM_CAP") && g_tick_absent) { printf("  没有前端、上限：返回 %d、原因 %d、%.0f ms 后放行、后台接着编 %ld 行\n", all, atomic_load(&g_wp_why), back / 1e6, atomic_load(&g_warm_bg_after_cap));
        ok = ok && all == 0 && atomic_load(&g_wp_why) == WARM_WHY_LIMIT && full_at_back == 0 && atomic_load(&g_warm_bg_after_cap) > 0; }   // 到点放行 = 原因上限 + 放行时还没编完 + 后台接着编（11-09 原「< 250 ms」负载重时偶发红）
    else if (getenv("T_WARM_CAP")) { printf("  有前端、上限 100 ms：返回 %d、原因 %d、%.0f ms 后返回\n", all, atomic_load(&g_wp_why), back / 1e6);
        ok = ok && atomic_load(&g_wp_why) != WARM_WHY_LIMIT && (all == 1 || atomic_load(&g_wp_why) == WARM_WHY_TAIL); }
    else if (g_t_hold) { printf("  领完放行：返回 %d、原因 %d、%.0f ms 后放行、通知前端 %ld 次\n", all, atomic_load(&g_wp_why), back / 1e6, atomic_load(&g_tick_released));
        ok = ok && all == 0 && atomic_load(&g_wp_why) == WARM_WHY_TAIL && full_at_back == 0 && atomic_load(&g_tick_released) == 1; }   // 不等最后那行 = 原因 TAIL + 放行时那行还没编完（11-09 原「< 1 s」负载重时偶发红）
    else ok = ok && (all == 1 || atomic_load(&g_wp_why) == WARM_WHY_TAIL);
    return !ok;
}
static int announce(int off) {   // in a child: C / D
    char dir[] = "/tmp/t_warmann_XXXXXX"; if (!mkdtemp(dir)) return 2;
    char p[300]; snprintf(p, sizeof p, "%s/shader_map.tsv", dir); FILE *f = fopen(p, "w"); if (!f) return 2; fclose(f); setenv("DM_NVN_SHMAP", p, 1);
    snprintf(p, sizeof p, "%s/pso_manifest.tsv", dir); f = fopen(p, "w"); if (!f) return 2;
    fputs("# seed\nS\t0000000000000001_b\t1\nS\t0000000000000002_b\t4\nC\t0000000000000003_b\n", f); fclose(f);
    setenv("DM_PSO_PREPARE", "1", 1); unsetenv("DM_PSO_USER"); unsetenv("DM_SAVE");
    if (off) setenv("DM_PSO_MANIFEST", "off", 1); else unsetenv("DM_PSO_MANIFEST");
    warm_announce();
    long calls = atomic_load(&g_tick_calls);
    printf("  宣告 %s：调用 %ld 次、首次 (%ld, %ld)\n", off ? "清单关" : "清单 3 行", calls, atomic_load(&g_tick_first_done), atomic_load(&g_tick_first_total));
    return off ? calls != 0 : !(calls == 1 && atomic_load(&g_tick_first_done) == 0 && atomic_load(&g_tick_first_total) == 3);
}
static int child_ann(int off) { fflush(stdout); pid_t p = fork(); if (!p) _exit(announce(off)); int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }
static int child_cap(int absent) { fflush(stdout); pid_t p = fork(); if (!p) { g_tick_absent = absent; setenv("DM_PSO_PREPARE_MAX_MS", "100", 1); setenv("T_WARM_CAP", "1", 1); _exit(run(0)); } int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }
static int child_default(const char *v) { fflush(stdout); pid_t p = fork(); if (!p) { if (v) setenv("DM_PSO_PREPARE", v, 1); else unsetenv("DM_PSO_PREPARE"); _exit(prepare_on() != (v ? 0 : 1)); } int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }
static int child_tail(void) { fflush(stdout); pid_t p = fork(); if (!p) { g_t_hold = 1; _exit(run(0)); } int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }
static int child_later(void) { fflush(stdout); pid_t p = fork(); if (!p) { g_tick_first_ret = 1; _exit(run(0)); } int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }
static int child(int enter_at) { fflush(stdout); pid_t p = fork(); if (!p) _exit(run(enter_at)); int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        char map[] = "/tmp/t_warmtick_XXXXXX"; int fd = mkstemp(map); if (fd < 0) return 2; close(fd); setenv("DM_NVN_SHMAP", map, 1);   // empty shader map: every key is skipped at once
        setenv("DM_PSO_PREPARE_THREADS", "1", 1);
        int a = child(2), b = child(0), e = child_cap(0), e2 = child_cap(1), g = child_tail(), h = child_later(), f = child_default(NULL) | child_default("0"); unlink(map);
        int c = child_ann(0), d = child_ann(1);
        printf("%s A 前端第 2 次周期调用返回 1 → 转后台、原因玩家、开始 (0, N)、后台编完 (N, N) 一次\n", a ? "✗" : "✓");
        printf("%s B 前端一直返回 0 → 全部编完再进（或只剩最后在编的一行时 TAIL 放行）、(N, N) 一次\n", b ? "✗" : "✓");
        printf("%s C 首帧前宣告：清单 3 行（另 1 行注释）→ 前端恰好一次 (0, 3)\n", c ? "✗" : "✓");
        printf("%s D 反证：DM_PSO_MANIFEST=off → 不宣告\n", d ? "✗" : "✓");
        printf("%s E 有前端、上限 100 ms、前端一直不放行 → 上限不放行（全部编完或 TAIL）、(N, N) 一次\n", e ? "✗" : "✓");
        printf("%s E2 没有前端、上限 100 ms → 到点放行、原因上限、剩下转后台编完\n", e2 ? "✗" : "✓");
        printf("%s F 缺省开（不设 DM_PSO_PREPARE → 开，=0 → 关）\n", f ? "✗" : "✓");
        printf("%s G 清单全部领走、最后一行编不完 → 不等它放行、原因 TAIL、通知前端一次、编完 (N, N) 一次\n", g ? "✗" : "✓");
        printf("%s H 之后的启动：前端开等第一拍放行 → 不进等待循环、原因 LATER、放行时还没编完、后台编完 (N, N) 一次\n", h ? "✗" : "✓");
        printf("%s t_nvn_warmtick：9 项，%d 项失败\n", a || b || c || d || e || e2 || f || g || h ? "✗" : "✓", !!a + !!b + !!c + !!d + !!e + !!e2 + !!f + !!g + !!h);
        return a || b || c || d || e || e2 || f || g || h;
    }
}
