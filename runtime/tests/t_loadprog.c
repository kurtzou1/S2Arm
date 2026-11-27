// 加载页进度模型单测（runtime/include/s2a_loadprog.h）：期望值按口径手算。每例 fork 一个子进程（模型的静态量从零开始），S2A_DOCS 指临时目录。
// 等事件的上限只当兜底（11-19：原先 1～5 秒，负载高时线程没跑到就判红 → 一律 30 秒，正常时一到就返回）
#include "../src/native.h"
#include "s2a_loadprog.h"
#include <sys/wait.h>
#include <unistd.h>

#define S 1000000000ull
uint64_t now_ns(void) { return 0; }
static int fails, cases;   // cases：跑了几例（报射程按它，不写死）
#define WANT(cond) do { if (!(cond)) { printf("    不符：%s（行 %d）\n", #cond, __LINE__); _exit(1); } } while (0)
#define CASE(name, body) do { cases++; char d[] = "/tmp/t_loadprog.XXXXXX"; if (!mkdtemp(d)) return 1; setenv("S2A_DOCS", d, 1); \
    pid_t p = fork(); if (!p) { body; _exit(0); } int st; waitpid(p, &st, 0); \
    if (!WIFEXITED(st) || WEXITSTATUS(st)) { fails++; printf("✗ %s\n", name); } else printf("  ✓ %s\n", name); } while (0)
static s2a_load_view V(uint64_t t) { s2a_load_view v; s2a_load_snapshot(t, &v); return v; }
// 全部真编（归档关着 / 没命中）时的一拍：真编数 = 已编数，同直连层 warm_prepare 每拍先报真编数再 tick
static int TK(uint64_t t, long d, long total) { s2a_load_warm_compiled(d); return s2a_load_warm_tick(t, d, total); }
static int eq(int s, const char *want) { char b[64]; s2a_load_eta_text(s, b, sizeof b); return !strcmp(b, want); }

#include <pthread.h>
static _Atomic int g_gate_done;
static void *gate_waiter(void *x) { (void)x; s2a_load_front_wait(); g_gate_done = 1; return NULL; }
int main(void) {
    unsetenv("S2A_LOAD_STALL_S"); unsetenv("S2A_LOAD_FIRST_S"); unsetenv("DM_PSO_PREPARE_MAX_MS");
    // 前台激活门（s2a_load_front_state / s2a_load_front_wait；11-19 系统弹框盖着时场景停在前台未激活）：期望按状态定义手写
    CASE("前台激活门：没设过状态（不走 UIKit 场景的路径）→ 不等", { alarm(5); WANT(s2a_load_front_wait() == 0); });
    CASE("前台激活门：前台未激活时加载已做完、起主线程前等着；200 ms 后仍在等，激活后 1 秒内放行", {
        alarm(60); s2a_load_front_state(1); pthread_t th; WANT(!pthread_create(&th, NULL, gate_waiter, NULL));
        usleep(200000); WANT(g_gate_done == 0);
        s2a_load_front_state(2); for (int i = 0; i < 3000 && !g_gate_done; i++) usleep(10000); WANT(g_gate_done == 1); pthread_join(th, NULL); });
    CASE("前台激活门：已激活 → 不等", { alarm(5); s2a_load_front_state(2); WANT(s2a_load_front_wait() == 0); });
    CASE("剩余时间文案逐秒：-1 估算中、3 不到 5 秒、42 → 42 秒、61 → 1 分 1 秒、80 → 1 分 20 秒、120 → 2 分钟", {
        WANT(eq(-1, "正在估算剩余时间")); WANT(eq(3, "不到 5 秒")); WANT(eq(42, "42 秒")); WANT(eq(61, "1 分 1 秒"));
        WANT(eq(80, "1 分 20 秒")); WANT(eq(120, "2 分钟")); });
    // 11-27 之后的启动首帧前不等预热（本包已完整预热过）：第一拍就放行、原因 LATER；预热没完之前已放行后的每一拍都回 1（直连层开局通告那拍先到，
    //   首帧前等待里的那几拍也要看到放行）；预热完那拍 (total, total) 回 0。首装同样的拍照旧等（11-22 #502）
    CASE("之后的启动首帧不等预热：第一拍 (0, 46995) 就回 1、原因 LATER、阶段进入游戏、不给先开始玩；之后预热没完的每一拍都回 1；编完那拍回 0；首帧 → 收起", {
        s2a_load_begin(0, 0); WANT(s2a_load_warm_tick(1 * S, 0, 46995) == 1);
        { s2a_load_view v = V(1 * S); WANT(v.go_reason == S2A_LOAD_GO_LATER && v.stage == S2A_LOAD_ENTER && v.first_run == 0 && v.can_skip == 0); }
        WANT(s2a_load_warm_tick(1 * S, 0, 46995) == 1); WANT(s2a_load_warm_tick(2 * S, 300, 46995) == 1);
        WANT(s2a_load_warm_tick(9 * S, 46995, 46995) == 0);
        s2a_load_first_frame(10 * S); WANT(V(10 * S).stage == S2A_LOAD_DONE); });
    CASE("首装照旧等：同样的拍 (0, 46995)、(300, 46995) 都回 0，阶段停在优化画面", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 46995) == 0); WANT(s2a_load_warm_tick(2 * S, 300, 46995) == 0);
        { s2a_load_view v = V(2 * S); WANT(v.go_reason == S2A_LOAD_GO_NONE && v.stage == S2A_LOAD_OPTIMIZE); } });
    CASE("之后的启动没有可预热的条目 (0, 0)：原因 DONE、回 0（编完不是放行）", {
        s2a_load_begin(0, 0); WANT(s2a_load_warm_tick(1 * S, 0, 0) == 0); WANT(V(1 * S).go_reason == S2A_LOAD_GO_DONE); });
    CASE("阶段：起局 = 准备数据，第一次 tick = 优化画面，编完 = 进入游戏，首帧 = 收起", {
        s2a_load_begin(0, 1); WANT(V(1 * S).stage == S2A_LOAD_DATA);
        WANT(s2a_load_warm_tick(2 * S, 0, 100) == 0); WANT(V(2 * S).stage == S2A_LOAD_OPTIMIZE);
        WANT(s2a_load_warm_tick(3 * S, 100, 100) == 0); { s2a_load_view v = V(3 * S); WANT(v.stage == S2A_LOAD_ENTER && v.go_reason == S2A_LOAD_GO_DONE); }
        s2a_load_first_frame(4 * S); WANT(V(4 * S).stage == S2A_LOAD_DONE && V(4 * S).frac == 1.0); });
    CASE("首帧回调先于预热结束（直连层首次提交里等预热，10-30 真机冷首启黑屏 15 秒）：首帧时还在优化画面 → 不收页；编完那一 tick 直接收起；没预热的启动首帧照旧收起", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 100) == 0);
        s2a_load_first_frame(2 * S); WANT(V(2 * S).stage == S2A_LOAD_OPTIMIZE);
        WANT(s2a_load_warm_tick(3 * S, 60, 100) == 0); WANT(V(3 * S).stage == S2A_LOAD_OPTIMIZE);
        WANT(s2a_load_warm_tick(4 * S, 100, 100) == 0); WANT(V(4 * S).stage == S2A_LOAD_DONE);
        s2a_load_begin(10 * S, 1); s2a_load_first_frame(11 * S); WANT(V(11 * S).stage == S2A_LOAD_DONE); });
    CASE("没有可预热的条目（11-02 魔界战记5 首启卡在「已优化 0 / 0」）：完成 tick (0, 0) 先到 → 进入游戏，首帧 → 收起；首帧先到 → 收起，之后 (0, 0) 不再动阶段", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 0) == 0); { s2a_load_view v = V(1 * S); WANT(v.stage == S2A_LOAD_ENTER && v.go_reason == S2A_LOAD_GO_DONE); }
        s2a_load_first_frame(2 * S); WANT(V(2 * S).stage == S2A_LOAD_DONE);
        s2a_load_begin(10 * S, 1); s2a_load_first_frame(11 * S); WANT(V(11 * S).stage == S2A_LOAD_DONE);
        WANT(s2a_load_warm_tick(12 * S, 0, 0) == 0); WANT(V(12 * S).stage == S2A_LOAD_DONE); });
    CASE("直连层自己放行（11-06：清单领完只剩在编的几条 / 到上限，s2a_front_warm_released）：优化画面中 → 进入游戏、原因 HOST；首帧已到过 → 直接收起；已进入游戏后再通知不动阶段", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 100) == 0);
        s2a_front_warm_released(); { s2a_load_view v = V(2 * S); WANT(v.stage == S2A_LOAD_ENTER && v.go_reason == S2A_LOAD_GO_HOST); }
        s2a_front_warm_released(); WANT(V(2 * S).stage == S2A_LOAD_ENTER && V(2 * S).go_reason == S2A_LOAD_GO_HOST);
        s2a_load_first_frame(3 * S); WANT(V(3 * S).stage == S2A_LOAD_DONE);
        s2a_load_begin(10 * S, 1); WANT(s2a_load_warm_tick(11 * S, 0, 100) == 0); s2a_load_first_frame(12 * S); WANT(V(12 * S).stage == S2A_LOAD_OPTIMIZE);
        s2a_front_warm_released(); WANT(V(13 * S).stage == S2A_LOAD_DONE); });
    CASE("首帧已到、玩家点了先开始玩：那一 tick 回 1（转后台）并直接收起", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(1 * S, 0, 100) == 0); s2a_load_first_frame(2 * S);
        s2a_load_user_skip(); WANT(s2a_load_warm_tick(3 * S, 10, 100) == 1); { s2a_load_view v = V(3 * S); WANT(v.stage == S2A_LOAD_DONE && v.go_reason == S2A_LOAD_GO_USER); } });
    CASE("匀速 100 条 / 秒、共 1000：测满 2 秒前按真编速率还估不出、显示离首装截断还剩的 11 秒；3 秒时 7 秒、4 秒时 6 秒", {
        s2a_load_begin(0, 1);
        for (uint64_t t = 0; t <= 4 * S; t += S / 2) { TK(t, (long)(t / (S / 100)), 1000);
            if (t == S) WANT(V(t).eta_s == 11);
            if (t == 3 * S) WANT(V(t).eta_s == 7);
            if (t == 4 * S) WANT(V(t).eta_s == 6); } });
    CASE("变慢到 10 条 / 秒：头 3 秒显示值只往下走，持续 3 秒后按实测往上修正（≥ 15 秒）", {
        setenv("S2A_LOAD_FIRST_S", "100000", 1); s2a_load_begin(0, 1); int last = -1;
        for (uint64_t t = 0; t <= 4 * S; t += S / 2) { TK(t, (long)(t / (S / 100)), 1000); last = V(t).eta_s; }
        WANT(last == 6);
        long d = 400;
        for (uint64_t t = 4 * S + S / 2; t <= 7 * S; t += S / 2) { d += 5; TK(t, d, 1000);
            if (t % S == 0) { int e = V(t).eta_s; WANT(e <= last); last = e; } }
        int up = 0; for (uint64_t t = 7 * S + S / 2; t <= 9 * S; t += S / 2) { d += 5; TK(t, d, 1000); if (t % S == 0 && V(t).eta_s >= 15) up = 1; }
        WANT(up); });
    CASE("进度只进不退：每 0.5 秒取一次快照，frac 不降；三段边界 5% / 95% / 100%", {
        s2a_load_begin(0, 1); double prev = 0;
        for (uint64_t t = 0; t <= 3 * S; t += S / 2) { double f = V(t).frac; WANT(f >= prev && f < 0.05); prev = f; }
        for (uint64_t t = 3 * S; t <= 13 * S; t += S / 2) { s2a_load_warm_tick(t, (long)((t - 3 * S) / (S / 100)), 1000); double f = V(t).frac; WANT(f >= prev); prev = f; }
        WANT(prev > 0.94 && prev <= 0.95); s2a_load_first_frame(14 * S); WANT(V(14 * S).frac == 1.0); });
    CASE("先开始玩一直可点（11-22 #502）：准备数据段不出；优化画面第一 tick 起就出、每 0.5 秒都在（含快编完剩不到 5 秒时）；点了下一次 tick 返回 1、原因 = 玩家；之后按钮收起", {
        s2a_load_begin(0, 1); WANT(!V(0).can_skip);
        for (uint64_t t = 0; t <= 10 * S; t += S / 2) { TK(t, (long)(t / (S / 95)), 1000); WANT(V(t).can_skip); }   // 95 条 / 秒，10 秒时剩 50 条
        WANT(V(10 * S).eta_s < 5 && V(10 * S).can_skip);
        s2a_load_user_skip(); WANT(s2a_load_warm_tick(10 * S + S / 20, 950, 1000) == 1);
        { s2a_load_view v = V(11 * S); WANT(v.go_reason == S2A_LOAD_GO_USER && v.stage == S2A_LOAD_ENTER && !v.can_skip); } });
    CASE("护栏：已编数 30 秒没涨 → 返回 1、原因 = 无进展；29.5 秒时还在等", {
        setenv("S2A_LOAD_FIRST_S", "100000", 1); s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 1000); s2a_load_warm_tick(1 * S, 10, 1000);
        WANT(s2a_load_warm_tick(30 * S + S / 2, 10, 1000) == 0);
        WANT(s2a_load_warm_tick(31 * S, 10, 1000) == 1); WANT(V(31 * S).go_reason == S2A_LOAD_GO_STALL); });
    // 11-27 首装只等开局那一段（取代 11-22 #502 首装等编完）：期望按 S2A_LOAD_FIRST_S（缺省 12 秒）手算
    CASE("首装满 12 秒放行：10 条 / 秒一直有进展，第 11.5 秒回 0、第 12 秒回 1、原因 PREFIX、阶段进入游戏", {
        s2a_load_begin(0, 1); int r = 0;
        for (uint64_t t = 0; t <= 11 * S + S / 2; t += S / 2) r |= s2a_load_warm_tick(t, (long)(t / (S / 10)), 100000);
        WANT(!r); WANT(V(11 * S + S / 2).stage == S2A_LOAD_OPTIMIZE);
        WANT(s2a_load_warm_tick(12 * S, 120, 100000) == 1);
        { s2a_load_view v = V(12 * S); WANT(v.go_reason == S2A_LOAD_GO_PREFIX && v.stage == S2A_LOAD_ENTER); } });
    CASE("首装 12 秒内编完：第 8 秒 (100, 100) 原因 DONE、回 0（编完不是放行）", {
        s2a_load_begin(0, 1); WANT(s2a_load_warm_tick(0, 0, 100) == 0); WANT(s2a_load_warm_tick(8 * S, 100, 100) == 0); WANT(V(8 * S).go_reason == S2A_LOAD_GO_DONE); });
    CASE("首装剩余时间不超过离截断还剩的秒数：还估不出真编速率时第 3 秒显示 9 秒；S2A_LOAD_FIRST_S=20 时显示 17 秒", {
        s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 47385); s2a_load_warm_tick(3 * S, 8000, 47385); WANT(V(3 * S).eta_s == 9);
        setenv("S2A_LOAD_FIRST_S", "20", 1); s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 47385); s2a_load_warm_tick(3 * S, 8000, 47385); WANT(V(3 * S).eta_s == 17); });
    CASE("剩余时间按已编 / 总数和速率估、不再按上限封顶（11-22 #502）：10 条 / 秒、共 100000 条，第 10 秒剩 99900 条 → 9990 秒、第 20 秒 → 9980 秒（±1 秒取整）", {
        setenv("S2A_LOAD_FIRST_S", "100000", 1); s2a_load_begin(0, 1); int e10 = -9; int e20 = -9;
        for (uint64_t t = 0; t <= 20 * S; t += S / 2) { TK(t, (long)(t / (S / 10)), 100000);
            if (t == 10 * S) e10 = V(t).eta_s; if (t == 20 * S) e20 = V(t).eta_s; }
        WANT(e10 >= 9989 && e10 <= 9991); WANT(e20 >= 9979 && e20 <= 9981); });
    CASE("剩余时间只按真编速率（11-27 冷首启：前 8000 行归档命中、页面显示「约 11 秒」）：共 47385 行，前 2 秒归档命中 4000 行 / 秒、真编 0 → 不给（-1）；之后真编 100 条 / 秒 → 第 4 秒剩 39185 行 ≈ 392 秒", {
        setenv("S2A_LOAD_FIRST_S", "100000", 1); s2a_load_begin(0, 1); long done = 0; long comp = 0; int e2 = -9; int e4 = -9;
        for (uint64_t t = 0; t <= 4 * S; t += S / 2) {
            if (t > 0 && t <= 2 * S) done += 2000; else if (t > 2 * S) { done += 50; comp += 50; }
            s2a_load_warm_compiled(comp); s2a_load_warm_tick(t, done, 47385);
            if (t == 2 * S) e2 = V(t).eta_s; if (t == 4 * S) e4 = V(t).eta_s; }
        WANT(e2 == 99998); WANT(e4 >= 391 && e4 <= 393); });   // 第 2 秒还估不出真编速率：显示离截断（本例设成 100000 秒）还剩的秒数，不按命中段的行速给「约 10 秒」
    CASE("全部编完才进游戏：记下本包已完整预热，同包之后 = 非首次、换包 = 首次", {
        WANT(s2a_load_first_run("aaaa"));
        s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 10); WANT(s2a_load_warm_tick(S, 10, 10) == 0); s2a_load_first_frame(2 * S);
        WANT(!s2a_load_first_run("aaaa")); WANT(s2a_load_first_run("bbbb")); });
    CASE("先开始玩后后台编完：首帧后迟到的 (N, N) 也记标记、不动阶段、回 0；没编完（只跳过）不记", {
        WANT(s2a_load_first_run("bbbb"));
        s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 10); s2a_load_user_skip(); WANT(s2a_load_warm_tick(S, 3, 10) == 1); s2a_load_first_frame(2 * S);
        WANT(s2a_load_first_run("bbbb"));
        WANT(s2a_load_warm_tick(30 * S, 10, 10) == 0); WANT(V(30 * S).stage == S2A_LOAD_DONE); WANT(!s2a_load_first_run("bbbb")); });
    CASE("反证：没有出包指纹（\"-\"）永远算首次、也不记", {
        WANT(s2a_load_first_run("-")); s2a_load_begin(0, 1); s2a_load_warm_tick(0, 0, 10); s2a_load_warm_tick(S, 10, 10); s2a_load_first_frame(2 * S);
        WANT(s2a_load_first_run("-")); });
    CASE("没有加载页前端（没调过 s2a_load_begin）：s2a_front_warm_tick 回 -1；调过之后回 0 / 1", {
        WANT(s2a_front_warm_tick(0, 10) == -1); s2a_load_begin(0, 1); WANT(s2a_front_warm_tick(0, 10) == 0); });
    if (fails) { printf("✗ t_loadprog：%d 例，%d 例不通\n", cases, fails); return 1; }
    printf("✓ t_loadprog：%d 例全过\n", cases); return 0;
}
