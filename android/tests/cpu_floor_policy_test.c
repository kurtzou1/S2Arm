// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// CPU 频率托底判定表（android/native/cpu_floor_policy.h）的宿主确定性测试：
// 纯函数，按模拟时间线喂「累计帧数 / 目标周期 / 开关 / 热状态 / 目标簇均频 / 各簇上限」，不碰线程、系统调用与真机。
#include "cpu_floor_policy.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failed;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); failed++; } } while (0)

#define MS 1000000ull
#define SEC 1000000000ull
#define TICK (250 * MS)
#define PERIOD30 33333333ull   // 目标 30 帧
#define CAP0 2496000u          // 目标簇（0–5 号核）的 scaling_max_freq，kHz
#define CAP1 2227200u          // 另一簇（6–7 号核）

struct sim {
    struct s2a_floor_state st;
    struct s2a_floor_in in;
    double frac;        // 不足一帧的余数，保证按 fps 精确累计
    unsigned ticks;
    uint32_t avg_khz;   // 目标簇每个周期的均频；0 = 读不到（累计量不动）
};

static void sim_init(struct sim *s, int mode, uint64_t period_ns) {
    memset(s, 0, sizeof *s);
    s->in.mode = mode; s->in.period_ns = period_ns;
    s->in.foreground = 1; s->in.surface = 1; s->in.thermal = 0;
    s->in.now_ns = 1000 * SEC;   // 不从 0 起：0 也是「没记过」的哨兵值，真时钟不会是 0
}
static void sim_caps(struct sim *s, uint32_t c0, uint32_t c1) { s->in.ncaps = 2; s->in.max_khz[0] = c0; s->in.max_khz[1] = c1; }
// 前进一个判定周期（250 ms）：按 fps 增加帧数、按均频增加频率累计（10 ms 单位 = 25），返回这一拍之后是否托底
static int sim_tick(struct sim *s, double fps) {
    s->in.now_ns += TICK;
    s->frac += fps * 0.25;
    uint64_t whole = (uint64_t)s->frac;
    s->frac -= (double)whole;
    s->in.frames += whole;
    if (s->avg_khz) { s->in.fq_time += 25; s->in.fq_work += (uint64_t)s->avg_khz * 25; }
    s->ticks++;
    return s2a_floor_step(&s->st, &s->in);
}
// 连续跑 n 个周期，返回最后一拍的结果
static int sim_run(struct sim *s, double fps, unsigned n) {
    int r = s->st.active;
    while (n--) r = sim_tick(s, fps);
    return r;
}
// 连续跑，返回第一次变为托底时已走的周期数（0 = 没触发）
static unsigned sim_first_on(struct sim *s, double fps, unsigned max_ticks) {
    for (unsigned i = 1; i <= max_ticks; i++) if (sim_tick(s, fps)) return i;
    return 0;
}

static void test_pick(void) {
    unsigned tablet[8] = {762, 762, 762, 762, 762, 762, 1024, 1024};   // 6 + 2：大核组多，选 0–5
    CHECK(s2a_floor_pick_cpus(tablet, 8) == 0x3Full);
    unsigned phone143[8] = {380, 380, 380, 380, 800, 800, 800, 1024};   // 4 + 3 + 1：中核组总容量最大
    CHECK(s2a_floor_pick_cpus(phone143, 8) == 0x70ull);
    unsigned fourfour[8] = {400, 400, 400, 400, 1024, 1024, 1024, 1024};
    CHECK(s2a_floor_pick_cpus(fourfour, 8) == 0xF0ull);
    unsigned tie[3] = {500, 500, 1000};   // 总容量相同：取容量更高的那组
    CHECK(s2a_floor_pick_cpus(tie, 3) == 0x4ull);
    unsigned homogeneous[8] = {1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024};
    CHECK(s2a_floor_pick_cpus(homogeneous, 8) == 0);   // 没有分组：不钉核
    unsigned missing[4] = {512, 0, 1024, 1024};         // 读不到容量 = 未知，不猜
    CHECK(s2a_floor_pick_cpus(missing, 4) == 0);
    CHECK(s2a_floor_pick_cpus(tablet, 0) == 0);
    CHECK(s2a_floor_pick_cpus(tablet, 65) == 0);        // 掩码只有 64 位：放不下就不钉
    CHECK(s2a_floor_pick_cpus(NULL, 4) == 0);
}

static void test_gates(void) {
    // 门：不在前台 / 没有显示面 / 已停，任何模式都不托底
    for (int mode = S2A_FLOOR_ALWAYS; mode <= S2A_FLOOR_AUTO; mode++) {
        struct sim s;
        for (int g = 0; g < 3; g++) {
            sim_init(&s, mode, PERIOD30);
            if (g == 0) s.in.foreground = 0;
            if (g == 1) s.in.surface = 0;
            if (g == 2) s.in.stopped = 1;
            CHECK(sim_first_on(&s, 10.0, 80) == 0);   // 慢到什么程度都不行（一次都不能托：托了再被自检松开也不行）
        }
        // 热状态（没读到 / 轻 / severe / 危急）与省电模式都不拦（不设自己挡自己的闸）
        for (int g = 0; g < 5; g++) {
            sim_init(&s, mode, PERIOD30);
            if (g == 0) s.in.thermal = -1;
            if (g == 1) s.in.thermal = 1;
            if (g == 2) s.in.thermal = 2;
            if (g == 3) s.in.thermal = 3;
            if (g == 4) s.in.low_power = 1;
            CHECK(mode == S2A_FLOOR_ALWAYS ? sim_tick(&s, 10.0) == 1 : sim_first_on(&s, 10.0, 40) != 0);
        }
    }
    // 托底中门一关立刻松开，门再开不记得旧账（重新数）
    struct sim s; sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 17.0, 40) != 0);
    s.in.surface = 0; CHECK(sim_tick(&s, 17.0) == 0);
    s.in.surface = 1;
    unsigned n = sim_first_on(&s, 17.0, 40);
    CHECK(n >= 13 && n <= 14);   // 窗口、连续慢窗口数都从零重数
    // 关闭模式：什么都不做
    sim_init(&s, S2A_FLOOR_OFF, PERIOD30);
    CHECK(sim_run(&s, 5.0, 200) == 0);
}

static void test_always(void) {
    struct sim s; sim_init(&s, S2A_FLOOR_ALWAYS, PERIOD30);
    CHECK(sim_tick(&s, 60.0) == 1);       // 不看帧率，门开即托
    CHECK(sim_run(&s, 0.0, 100) == 1);    // 一帧不出也托（门没关）
    s.in.surface = 0; CHECK(sim_tick(&s, 0.0) == 0);
    s.in.surface = 1; CHECK(sim_tick(&s, 0.0) == 1);
    s.in.mode = S2A_FLOOR_OFF; CHECK(sim_tick(&s, 0.0) == 0);   // 运行中关掉属性：即时松开
}

static void test_auto_enter(void) {
    struct sim s;
    // 负对照：按目标出图（30 帧）、略掉帧（28 帧 > 90%）、纯 60 帧目标跑满 → 一个窗口都不慢
    // （都用 first_on：一次都不能托——托了再被自检松开，停在「没托」上也算错）
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 30.0, 400) == 0);
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 28.0, 400) == 0);
    sim_init(&s, S2A_FLOOR_AUTO, 16666667ull); CHECK(sim_first_on(&s, 60.0, 400) == 0);
    sim_init(&s, S2A_FLOOR_AUTO, 16666667ull); CHECK(sim_first_on(&s, 55.0, 400) == 0);
    // 目标未登记（周期 0）：没有判据，不托底
    sim_init(&s, S2A_FLOOR_AUTO, 0); CHECK(sim_first_on(&s, 5.0, 400) == 0);
    // 正例：17 帧对 30 帧目标——第 1 拍立窗口起点，之后每 4 拍收一个窗口，第 3 个慢窗口收完（第 13 拍）才托底
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_run(&s, 17.0, 12) == 0);
    CHECK(sim_tick(&s, 17.0) == 1);
    // 慢窗口必须连续：慢、慢、正常、慢、慢……永远攒不够
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_tick(&s, 30.0) == 0);          // 第 1 拍只立窗口起点；之后每 4 拍收一个窗口，与下面的 8 + 4 对齐
    for (int round = 0; round < 12; round++) {
        CHECK(sim_run(&s, 17.0, 8) == 0);   // 两个慢窗口
        CHECK(sim_run(&s, 30.0, 4) == 0);   // 一个正常窗口打断
    }
    // 边界：目标 10 帧（周期 100 ms），阈值 9 帧/秒；恰好 9 不算慢，8 算慢
    sim_init(&s, S2A_FLOOR_AUTO, 100 * MS); CHECK(sim_first_on(&s, 9.0, 200) == 0);
    sim_init(&s, S2A_FLOOR_AUTO, 100 * MS); CHECK(sim_first_on(&s, 8.0, 40) != 0);
    // 一帧不出（加载 / 暂停）不算慢：没有帧可比，也就不会托
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 0.0, 400) == 0);
    // 累计帧数回绕（无符号差）
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); s.in.frames = UINT64_MAX - 20;
    CHECK(sim_first_on(&s, 17.0, 40) != 0);
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); s.in.frames = UINT64_MAX - 20;
    CHECK(sim_first_on(&s, 30.0, 200) == 0);
}

static void test_auto_release(void) {
    struct sim s; sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    unsigned on = sim_first_on(&s, 17.0, 40); CHECK(on == 13);
    // 托底后帧率恢复到目标：保持满 60 秒才允许松开（60 秒 = 240 拍，从触发那拍算起；按窗口边界检查）
    unsigned held = 0;
    while (sim_tick(&s, 30.0)) { held++; if (held > 400) break; }
    CHECK(held >= 236 && held <= 244);   // 约 60 s
    CHECK(s.st.why == S2A_FLOOR_WHY_DONE && !s.st.latched);   // 按「帧率到了」松开，不是自检
    // 松开后立即回到慢：2 分钟内再触发 = 反复，保持时间翻倍（120 s）
    CHECK(sim_first_on(&s, 17.0, 40) == 12);   // 松开那拍窗口刚收完：再数 3 个慢窗口 = 12 拍
    CHECK(s.st.active == 1);
    held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 800) break; }
    CHECK(held >= 476 && held <= 484);   // 约 120 s
    // 再反复：240 s
    CHECK(sim_first_on(&s, 17.0, 40) == 12);
    held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 1500) break; }
    CHECK(held >= 956 && held <= 964);
    // 再反复：480 s；之后一直反复：封顶 600 s
    CHECK(sim_first_on(&s, 17.0, 40) == 12);
    held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 4000) break; }
    CHECK(held >= 1916 && held <= 1924);
    for (int i = 0; i < 3; i++) {
        CHECK(sim_first_on(&s, 17.0, 40) == 12);
        held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 4000) break; }
        CHECK(held >= 2396 && held <= 2404);   // 封顶 600 s，不再翻倍
    }
    // 松开后安静超过 2 分钟再慢：保持时间回到 60 s
    CHECK(sim_run(&s, 30.0, 4 * 130) == 0);   // 130 s 正常
    CHECK(sim_first_on(&s, 17.0, 40) != 0);
    held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 800) break; }
    CHECK(held >= 236 && held <= 244);
    // 松开后 100 s（还没到 2 分钟）再慢：仍算反复，保持时间翻倍（120 s）
    CHECK(sim_run(&s, 30.0, 4 * 97) == 0);
    CHECK(sim_first_on(&s, 17.0, 40) != 0);
    held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 800) break; }
    CHECK(held >= 476 && held <= 484);
}

static void test_auto_stays_while_slow(void) {
    struct sim s; sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 17.0, 40) != 0);
    // 带着托底帧率从 17 提到 22（高 29%，「没有收益」自检通过），但仍低于目标的 90%（27）：
    // 保持期满时窗口仍然慢——续期，不松开
    CHECK(sim_run(&s, 22.0, 4 * 200) == 1);
    CHECK(s.st.bench == S2A_FLOOR_BENCH_DONE);
    // 之后正常了：再满一个保持期才松开
    unsigned held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 400) break; }
    CHECK(held >= 1 && held <= 244);
}

static void test_auto_idle(void) {
    struct sim s; sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 17.0, 40) != 0);
    // 每个窗口只有 1 帧（1 fps，卡得很但还在出图）不算空窗口：连着 6 个也不松
    CHECK(sim_run(&s, 1.0, 4 * 6) == 1);
    // 托底中帧停了（暂停 / 卡在加载）：连续 5 个空窗口后松开；中途出一帧就重新数
    CHECK(sim_run(&s, 0.0, 4 * 4) == 1);
    CHECK(sim_run(&s, 17.0, 4) == 1);
    CHECK(sim_run(&s, 0.0, 4 * 4) == 1);
    CHECK(sim_run(&s, 0.0, 4 * 2) == 0);
    // 空闲松开不算「反复」：慢了重新来，保持时间仍是 60 s
    CHECK(sim_first_on(&s, 17.0, 60) != 0);
    unsigned held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 800) break; }
    CHECK(held >= 236 && held <= 244);
}

static void test_auto_clock(void) {
    struct sim s; sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_run(&s, 17.0, 10) == 0);
    // 时钟倒退（不该发生，但不能崩、不能凭空触发）：窗口重开，连续数不带过去
    s.in.now_ns -= 100 * SEC;
    CHECK(sim_tick(&s, 17.0) == 0);
    unsigned n = sim_first_on(&s, 17.0, 40);
    CHECK(n >= 12 && n <= 14);
    // 托底中碰上时钟倒退：连续空窗口数同样从零数（否则倒退前攒下的 4 个空窗口，会让倒退后的第 1 个空窗口就松开）
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 17.0, 40) == 13);
    CHECK(sim_run(&s, 0.0, 4 * 4) == 1);                 // 4 个空窗口，还没到 5 个
    s.in.now_ns -= 100 * SEC;
    CHECK(sim_tick(&s, 0.0) == 1);                       // 倒退这一拍：重开窗口，托底不松
    CHECK(sim_run(&s, 0.0, 4 * 4) == 1);                 // 倒退后重新数：又是 4 个，仍不松
    CHECK(sim_run(&s, 0.0, 4) == 0);                     // 第 5 个空窗口：松开
}

static void test_hist(void) {
    // 桶边界：上沿含等号，超 1 ns 进下一桶
    static const unsigned lim[7] = {17, 25, 34, 42, 51, 67, 100};
    for (int i = 0; i < 7; i++) {
        CHECK(s2a_floor_bucket_limit_ms(i) == lim[i]);
        CHECK(s2a_floor_bucket((uint64_t)lim[i] * 1000000ull) == i);
        CHECK(s2a_floor_bucket((uint64_t)lim[i] * 1000000ull + 1) == i + 1);
    }
    CHECK(s2a_floor_bucket_limit_ms(7) == 0 && s2a_floor_bucket_limit_ms(-1) == 0 && s2a_floor_bucket_limit_ms(99) == 0);
    CHECK(s2a_floor_bucket(0) == 0 && s2a_floor_bucket(1) == 0);
    CHECK(s2a_floor_bucket(UINT64_MAX) == 7);
    CHECK(s2a_floor_bucket(PERIOD30) == 2);                       // 30 帧档的一帧 33.3 ms：不算慢
    CHECK(s2a_floor_bucket(2 * PERIOD30) == 5);                   // 错过一个刷新（66.7 ms）
    // 分位：向上取整、至少覆盖这么多样本
    unsigned empty[8] = {0};
    CHECK(s2a_floor_hist_quantile(empty, 500) == -1 && s2a_floor_hist_quantile(empty, 990) == -1);
    unsigned one[8] = {0, 0, 0, 0, 0, 1, 0, 0};
    CHECK(s2a_floor_hist_quantile(one, 500) == 5 && s2a_floor_hist_quantile(one, 990) == 5 && s2a_floor_hist_quantile(one, 0) == 5);
    unsigned mix[8] = {90, 0, 0, 0, 0, 9, 0, 1};                  // 共 100：p50 在桶 0；p99 要 99 个样本 → 桶 5；p100 → 桶 7
    CHECK(s2a_floor_hist_quantile(mix, 500) == 0);
    CHECK(s2a_floor_hist_quantile(mix, 900) == 0);                // 第 90 个正好是桶 0 的最后一个
    CHECK(s2a_floor_hist_quantile(mix, 910) == 5);                // 要 91 个
    CHECK(s2a_floor_hist_quantile(mix, 990) == 5);
    CHECK(s2a_floor_hist_quantile(mix, 991) == 7);                // 要 100 个（99.1 向上取整）
    CHECK(s2a_floor_hist_quantile(mix, 1000) == 7);
    unsigned m101[8] = {100, 0, 0, 0, 0, 0, 0, 1};                // 101 个：p99 要 ceil(99.99) = 100 个 → 仍在桶 0
    CHECK(s2a_floor_hist_quantile(m101, 990) == 0);
    unsigned big[8] = {4000000000u, 4000000000u, 4000000000u, 0, 0, 0, 0, 1};   // 总数超 32 位：不能溢出
    CHECK(s2a_floor_hist_quantile(big, 500) == 1 && s2a_floor_hist_quantile(big, 1000) == 7);
    // 慢帧数：下标 ≥ 3 的桶之和
    unsigned seq[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    CHECK(s2a_floor_hist_slow(seq) == 30);
    CHECK(s2a_floor_hist_slow(empty) == 0);
    unsigned fast[8] = {9, 9, 9, 0, 0, 0, 0, 0};
    CHECK(s2a_floor_hist_slow(fast) == 0);
}

// 托底前的场景：17 帧对 30 帧目标、目标簇均频 89%（2230 / 2496 MHz）、两簇上限；第 13 拍托底
static void engage_with_headroom(struct sim *s) {
    sim_init(s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(s, CAP0, CAP1); s->avg_khz = 2230000;
    CHECK(sim_first_on(s, 17.0, 40) == 13);
}

static void test_ceiling(void) {
    struct sim s;
    // 已顶在上限（均频 2490 / 上限 2496 MHz = 99.7%）：没有东西可托，慢到 17 帧也不出手，原因记在状态里
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2490000;
    CHECK(sim_first_on(&s, 17.0, 400) == 0);                           // first_on：一次都不能托（托了再被自检松开也不行）
    CHECK(s.st.block == S2A_FLOOR_BLOCK_CEILING && s.st.ceil_permille == 997);
    CHECK(sim_run(&s, 30.0, 8) == 0 && s.st.block == S2A_FLOOR_BLOCK_NONE);   // 帧率回到目标：不出手的原因清掉
    // 边界：均频恰好是上限的 95.0%（2371200 = 2496000 × 0.95）算「已顶在上限」，少 1 kHz 才出手
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2371200;
    CHECK(sim_first_on(&s, 17.0, 100) == 0 && s.st.ceil_permille == 950);
    // 均频比上限还高（读数口径不一致、上限被临时压低等）：千分数封顶 2000，照样是「已顶在上限」
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 10000000;
    CHECK(sim_first_on(&s, 17.0, 100) == 0 && s.st.ceil_permille == 2000);
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2371199;
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && s.st.ceil_permille == 949);
    // 有余量：均频 2230 / 2496 = 89.3%（0100F2C0115B6000 在 Adreno 840 平板上的量级）：照常第 13 拍出手
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2230000;
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && s.st.ceil_permille == 893 && s.st.block == S2A_FLOOR_BLOCK_NONE);
    // 均频读不到（累计不动）/ 上限读不到 / 没有上限读数：这条判据不参与，只剩帧率判据（-1 = 没读到），不拦
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 0;
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && s.st.ceil_permille == -1);
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, 0, 0); s.avg_khz = 2490000;
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && s.st.ceil_permille == -1);
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); s.avg_khz = 2490000;
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && s.st.ceil_permille == -1);
    // 只统计读到了的窗口：近 3 个窗口里第 1 个没有频率读数，另 2 个顶在上限 → 按这 2 个判定（不出手）
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1);
    s.avg_khz = 0; CHECK(sim_run(&s, 17.0, 5) == 0);
    s.avg_khz = 2490000; CHECK(sim_run(&s, 17.0, 8) == 0);
    CHECK(s.st.block == S2A_FLOOR_BLOCK_CEILING && s.st.ceil_permille == 997);
    // 滑动判定：一直顶在上限，均频掉到 89% 之后，近 3 个窗口的平均一过线就出手（不用等 3 个窗口全是低的，
    // 也不能被更早的窗口拖住；被拦期间每个窗口都要重判，不能隔几个窗口才看一次）：
    // 第 44 拍改均频，第 45 拍收的窗口是 3 拍旧 + 1 拍新（97.2%），第 49 / 53 拍收的窗口全是新的（89.3%）；
    // 第 49 拍近 3 个窗口 99.7 / 97.2 / 89.3 → 95.4% 还拦着，第 53 拍 97.2 / 89.3 / 89.3 → 91.9% 出手
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2490000;
    CHECK(sim_first_on(&s, 17.0, 44) == 0);
    s.avg_khz = 2230000;
    CHECK(sim_first_on(&s, 17.0, 40) == 9 && s.st.ceil_permille == 919);
    // 托底之后均频被托到上限（托底自己抬的）：不松开——「顶在上限」只是出手前的条件，不是松开的条件
    engage_with_headroom(&s); s.avg_khz = 2490000;
    CHECK(sim_run(&s, 24.0, 400) == 1 && !s.st.latched);
    // 常开不看这条：顶在上限也托
    sim_init(&s, S2A_FLOOR_ALWAYS, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2490000;
    CHECK(sim_tick(&s, 17.0) == 1);
}

static void test_cap_drop(void) {
    struct sim s;
    // 托底中某簇的 scaling_max_freq 比托底前低了 5% 以上、连续 2 个窗口：松开，本局不再出手
    engage_with_headroom(&s);
    s.in.max_khz[0] = 2300000;                                         // 92.1%
    CHECK(sim_run(&s, 24.0, 4) == 1 && s.st.drop_run == 1);            // 第 1 个窗口：还不松
    CHECK(sim_run(&s, 24.0, 4) == 0);                                  // 第 2 个窗口：松开
    CHECK(s.st.latched && s.st.why == S2A_FLOOR_WHY_CAP_DROP && s.st.cap_idx == 0 && s.st.cap_from == CAP0 && s.st.cap_to == 2300000);
    // 本局不再出手：帧率慢到什么程度、慢多久都不再托（原因 = 已停用）
    CHECK(sim_run(&s, 17.0, 400) == 0 && s.st.block == S2A_FLOOR_BLOCK_LATCHED);
    // 门开关、前后台切换不洗掉它
    s.in.surface = 0; CHECK(sim_tick(&s, 17.0) == 0); s.in.surface = 1;
    s.in.foreground = 0; CHECK(sim_tick(&s, 17.0) == 0); s.in.foreground = 1;
    CHECK(sim_run(&s, 17.0, 400) == 0 && s.st.latched);
    // 开关显式切到 0（A/B / 调试重来）：连停用一起忘，切回自适应就能再出手
    s.in.mode = S2A_FLOOR_OFF; CHECK(sim_tick(&s, 17.0) == 0 && !s.st.latched);
    s.in.mode = S2A_FLOOR_AUTO; s.in.max_khz[0] = CAP0;
    CHECK(sim_first_on(&s, 17.0, 40) == 13);
    // 另一个簇的上限被压同样算（下标 1）
    engage_with_headroom(&s); s.in.max_khz[1] = 2000000;               // 89.8% of 2227 MHz
    CHECK(sim_run(&s, 24.0, 8) == 0 && s.st.cap_idx == 1 && s.st.cap_from == CAP1 && s.st.cap_to == 2000000);
    // 边界：恰好低 5%（2371200 = 2496000 × 0.95）不算，再低 1 kHz 才算
    engage_with_headroom(&s); s.in.max_khz[0] = 2371200;
    CHECK(sim_run(&s, 24.0, 400) == 1 && !s.st.latched);
    engage_with_headroom(&s); s.in.max_khz[0] = 2371199;
    CHECK(sim_run(&s, 24.0, 8) == 0 && s.st.latched);
    // 单个窗口的抖动不算：低一个窗口、下一个窗口恢复，连续数清零
    engage_with_headroom(&s);
    s.in.max_khz[0] = 2300000; CHECK(sim_run(&s, 24.0, 4) == 1 && s.st.drop_run == 1);
    s.in.max_khz[0] = CAP0;    CHECK(sim_run(&s, 24.0, 4) == 1 && s.st.drop_run == 0);
    s.in.max_khz[0] = 2300000; CHECK(sim_run(&s, 24.0, 4) == 1 && s.st.drop_run == 1);   // 又是新的一轮
    // 对照的是托底前近 3 个窗口里的最小值：托底前最后一个窗口恰好读到临时抬高的上限（3629 MHz），
    // 之后回到常态 2496 MHz，不是「被压」
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2230000;
    CHECK(sim_run(&s, 17.0, 12) == 0);
    s.in.max_khz[0] = 3628800;
    CHECK(sim_tick(&s, 17.0) == 1 && s.st.base_cap[0] == CAP0);
    s.in.max_khz[0] = CAP0;
    CHECK(sim_run(&s, 24.0, 400) == 1 && !s.st.latched);
    // 同理，最早的那个窗口读到临时抬高的上限（其后两个窗口回到常态）：基线仍是最小值，不是最早窗口的值
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, 3628800, CAP1); s.avg_khz = 2230000;
    CHECK(sim_run(&s, 17.0, 5) == 0);
    s.in.max_khz[0] = CAP0;
    CHECK(sim_first_on(&s, 17.0, 40) == 8 && s.st.base_cap[0] == CAP0);
    CHECK(sim_run(&s, 24.0, 400) == 1 && !s.st.latched);
    // 上限升高不算；托底中读不到上限（0）也不当作「被压」
    engage_with_headroom(&s); s.in.max_khz[0] = 3628800;
    CHECK(sim_run(&s, 24.0, 400) == 1 && !s.st.latched);
    engage_with_headroom(&s); s.in.max_khz[0] = 0; s.in.max_khz[1] = 0;
    CHECK(sim_run(&s, 24.0, 400) == 1 && !s.st.latched);
    // 托底前就没读到上限的簇（对照为 0）：之后读到什么都不算
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); sim_caps(&s, CAP0, 0); s.avg_khz = 2230000;
    CHECK(sim_first_on(&s, 17.0, 40) == 13); s.in.max_khz[1] = 100000;
    CHECK(sim_run(&s, 24.0, 400) == 1 && !s.st.latched);
    // 常开不看这条
    sim_init(&s, S2A_FLOOR_ALWAYS, PERIOD30); sim_caps(&s, CAP0, CAP1); s.avg_khz = 2490000;
    CHECK(sim_tick(&s, 17.0) == 1);
    s.in.max_khz[0] = 1000000; CHECK(sim_run(&s, 17.0, 400) == 1);
    // 常开切回自适应：从零开始，不继承常开的托底
    s.in.mode = S2A_FLOOR_AUTO; CHECK(sim_tick(&s, 17.0) == 0 && !s.st.forced);
}

static void test_no_gain(void) {
    struct sim s;
    // 托底后帧率一直是 17：托底 5 秒（20 拍）后量 10 个出图窗口，第 60 拍判定，没有收益 → 松开并暂缓 60 s（不是「本局不再出手」）
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);          // 频率读不到：只剩帧率判据与这条自检
    CHECK(sim_first_on(&s, 17.0, 40) == 13);
    CHECK(sim_run(&s, 17.0, 59) == 1 && s.st.bench == S2A_FLOOR_BENCH_MEASURE);
    CHECK(sim_tick(&s, 17.0) == 0);
    CHECK(!s.st.latched && s.st.why == S2A_FLOOR_WHY_NO_GAIN && s.st.pre_mfps == 17000 && s.st.post_mfps == 17000);
    CHECK(s.st.nogain_backoff_ns == 60 * SEC && s.st.nogain_until_ns == s.in.now_ns + 60 * SEC);
    // 暂缓期内（60 s = 240 拍）：慢到什么程度都不出手，原因记「暂缓」；到点那一拍收完窗口就再试
    CHECK(sim_run(&s, 17.0, 239) == 0 && s.st.block == S2A_FLOOR_BLOCK_BACKOFF);
    CHECK(sim_tick(&s, 17.0) == 1 && s.st.block == S2A_FLOOR_BLOCK_NONE);
    // 连着没有收益：暂缓 120 → 240 → 480 → 600 → 600 s（翻倍，封顶 600 s）；每次到点再试、再判 60 拍
    static const unsigned want_s[5] = {120, 240, 480, 600, 600};
    for (int i = 0; i < 5; i++) {
        CHECK(sim_run(&s, 17.0, 59) == 1);
        CHECK(sim_tick(&s, 17.0) == 0 && s.st.why == S2A_FLOOR_WHY_NO_GAIN);
        CHECK(s.st.nogain_backoff_ns == want_s[i] * SEC && s.st.nogain_until_ns == s.in.now_ns + want_s[i] * SEC);
        CHECK(sim_run(&s, 17.0, want_s[i] * 4 - 1) == 0 && s.st.block == S2A_FLOOR_BLOCK_BACKOFF);
        CHECK(sim_tick(&s, 17.0) == 1);
    }
    // 这次量出收益（17 → 24）：之前攒的暂缓清零
    CHECK(sim_run(&s, 24.0, 60) == 1 && s.st.bench == S2A_FLOOR_BENCH_DONE);
    CHECK(s.st.nogain_backoff_ns == 0 && s.st.nogain_until_ns == 0);
    // 带着托底帧率回到 30，保持满 60 s 后松开；之后再慢、再没有收益：又从 60 s 数起，不沿用以前的翻倍
    unsigned held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 400) break; }
    CHECK(held >= 176 && held <= 184 && s.st.why == S2A_FLOOR_WHY_DONE);   // 托底已经开了 60 拍（判决那一刻），保持期共 240 拍
    CHECK(sim_first_on(&s, 17.0, 40) == 12);
    CHECK(sim_run(&s, 17.0, 60) == 0 && s.st.why == S2A_FLOOR_WHY_NO_GAIN && s.st.nogain_backoff_ns == 60 * SEC);
    // 常开是显式指令：暂缓清掉；切回自适应后不带旧账，数满 3 个慢窗口就能出手
    s.in.mode = S2A_FLOOR_ALWAYS; CHECK(sim_tick(&s, 17.0) == 1 && s.st.nogain_backoff_ns == 0 && s.st.nogain_until_ns == 0);
    s.in.mode = S2A_FLOOR_AUTO; CHECK(sim_tick(&s, 17.0) == 0);
    CHECK(sim_first_on(&s, 17.0, 40) != 0);
    // 开关切到 0 同样清掉
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && sim_run(&s, 17.0, 60) == 0 && s.st.nogain_backoff_ns == 60 * SEC);
    s.in.mode = S2A_FLOOR_OFF; CHECK(sim_tick(&s, 17.0) == 0 && s.st.nogain_backoff_ns == 0 && s.st.nogain_until_ns == 0);
    s.in.mode = S2A_FLOOR_AUTO; CHECK(sim_first_on(&s, 17.0, 40) != 0);
    // 暂缓不被门的开关洗掉（同「本局不再出手」）：门关一下再开，到点时刻不变，没到点不出手，到点后出手
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && sim_run(&s, 17.0, 60) == 0 && s.st.nogain_backoff_ns == 60 * SEC);
    const uint64_t until = s.st.nogain_until_ns;
    s.in.surface = 0; CHECK(sim_tick(&s, 17.0) == 0); s.in.surface = 1;
    s.in.foreground = 0; CHECK(sim_tick(&s, 17.0) == 0); s.in.foreground = 1;
    CHECK(s.st.nogain_until_ns == until && s.st.nogain_backoff_ns == 60 * SEC && !s.st.latched);
    CHECK(sim_run(&s, 17.0, 4 * 20) == 0 && s.st.block == S2A_FLOOR_BLOCK_BACKOFF);
    unsigned n = sim_first_on(&s, 17.0, 400);
    CHECK(n != 0 && s.in.now_ns >= until && s.in.now_ns - until <= 2 * S2A_FLOOR_WINDOW_NS);
    // 暂缓期里时钟倒退：到点时刻收回到「现在 + 暂缓长度」以内，不会被倒退的那一段拖长
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 17.0, 40) == 13 && sim_run(&s, 17.0, 60) == 0);
    s.in.now_ns -= 1000 * SEC;                       // 倒退 1000 s，远大于暂缓
    CHECK(sim_tick(&s, 17.0) == 0 && s.st.nogain_until_ns == s.in.now_ns + 60 * SEC);
    n = sim_first_on(&s, 17.0, 400);
    CHECK(n != 0 && n <= 4 * 60 + 8);
    // 照真机上见到的形状模拟（数值是模拟输入）：载入阶段先试探，托底后帧率上不去 → 没有收益，暂缓；
    // 游玩阶段 CPU 受限（17 → 19.8），暂缓到点再试 → 有收益，留下。（一票否决会让这一局的游玩阶段再也托不上）
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_first_on(&s, 14.7, 40) == 13);
    CHECK(sim_run(&s, 14.7, 60) == 0 && s.st.why == S2A_FLOOR_WHY_NO_GAIN);
    CHECK(sim_run(&s, 17.0, 239) == 0 && s.st.block == S2A_FLOOR_BLOCK_BACKOFF);
    CHECK(sim_tick(&s, 17.0) == 1);
    CHECK(sim_run(&s, 19.8, 60) == 1 && s.st.bench == S2A_FLOOR_BENCH_DONE && s.st.nogain_backoff_ns == 0);
    // 帧率到了目标再松开：保持期仍是 60 s（没有收益的那次松开不算「反复」，不会让这次的保持时间翻倍）
    held = 0; while (sim_tick(&s, 30.0)) { held++; if (held > 800) break; }
    CHECK(held >= 176 && held <= 184 && s.st.why == S2A_FLOOR_WHY_DONE);
    // 收益边界：目标 10 帧（周期 100 ms）、托底前 8 帧；托底后 8.4 帧（恰好高 5%）算有收益，8.3 帧不算
    // （帧累计器预置 0.05，避免累计值正好落在整数上被浮点误差带偏一帧）
    sim_init(&s, S2A_FLOOR_AUTO, 100 * MS);
    CHECK(sim_first_on(&s, 8.0, 40) == 13);
    s.frac = 0.05;
    CHECK(sim_run(&s, 8.4, 60) == 1 && s.st.bench == S2A_FLOOR_BENCH_DONE && s.st.nogain_backoff_ns == 0);
    sim_init(&s, S2A_FLOOR_AUTO, 100 * MS);
    CHECK(sim_first_on(&s, 8.0, 40) == 13);
    s.frac = 0.05;
    CHECK(sim_run(&s, 8.3, 60) == 0 && s.st.why == S2A_FLOOR_WHY_NO_GAIN && s.st.nogain_backoff_ns == 60 * SEC && !s.st.latched);
    // 托底后前 5 秒（调频器还没跟上）不算：这 5 秒里帧率提到 22、之后又掉回 17 → 没有收益
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 17.0, 40) == 13);
    CHECK(sim_run(&s, 22.0, 20) == 1);
    CHECK(sim_run(&s, 17.0, 39) == 1 && sim_tick(&s, 17.0) == 0 && s.st.why == S2A_FLOOR_WHY_NO_GAIN);
    // 反过来：前 5 秒还是 17、之后才到 22 → 有收益
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 17.0, 40) == 13);
    CHECK(sim_run(&s, 17.0, 20) == 1);
    CHECK(sim_run(&s, 22.0, 40) == 1 && s.st.bench == S2A_FLOOR_BENCH_DONE);
    // 空窗口（暂停 / 加载）不计入这 10 个窗口：中间停 3 个窗口（< 5，不触发空闲松开），判定顺延
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 17.0, 40) == 13);
    CHECK(sim_run(&s, 22.0, 20) == 1);
    CHECK(sim_run(&s, 22.0, 4 * 4) == 1);
    CHECK(sim_run(&s, 0.0, 4 * 3) == 1);
    CHECK(sim_run(&s, 22.0, 4 * 5) == 1 && s.st.post_n == 9 && s.st.bench == S2A_FLOOR_BENCH_MEASURE);
    CHECK(sim_run(&s, 22.0, 4) == 1 && s.st.bench == S2A_FLOOR_BENCH_DONE);
    // 确认有收益之后不再重复检验：之后帧率再回到 17 也不松（保持期满且仍慢 = 续期）
    CHECK(sim_run(&s, 17.0, 4 * 200) == 1 && !s.st.latched);
    // 慢窗口里「托底前」的帧率就是对照基线：托底前 12 帧、托底后 12.5 帧（+4%）→ 没有收益；托底后 12.7（+5.8%）→ 有
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 12.0, 40) == 13);
    s.frac = 0.05;
    CHECK(sim_run(&s, 12.5, 60) == 0 && s.st.why == S2A_FLOOR_WHY_NO_GAIN);
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 12.0, 40) == 13);
    s.frac = 0.05;
    CHECK(sim_run(&s, 12.7, 60) == 1 && s.st.bench == S2A_FLOOR_BENCH_DONE);
    // 托底前的帧率取近 3 个慢窗口的合计（不是最后一个窗口）：20 / 17 / 14 帧 → 17.0；托底后 17.5（+2.9%）没有收益
    // （若误取最后一个窗口 14 帧当基线，17.5 会被当成 +25% 放过）
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30);
    CHECK(sim_run(&s, 20.0, 5) == 0 && sim_run(&s, 17.0, 4) == 0 && sim_run(&s, 14.0, 3) == 0 && sim_tick(&s, 14.0) == 1);
    s.frac = 0.05;
    CHECK(sim_run(&s, 17.5, 60) == 0 && s.st.why == S2A_FLOOR_WHY_NO_GAIN && s.st.pre_mfps == 17000 && s.st.post_mfps == 17500);
    // 开关被改到 0：松开，原因 = 开关改了
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 17.0, 40) == 13);
    s.in.mode = S2A_FLOOR_OFF; CHECK(sim_tick(&s, 17.0) == 0 && s.st.why == S2A_FLOOR_WHY_MODE);
    // 门关了：松开，原因 = 门关了
    sim_init(&s, S2A_FLOOR_AUTO, PERIOD30); CHECK(sim_first_on(&s, 17.0, 40) == 13);
    s.in.surface = 0; CHECK(sim_tick(&s, 17.0) == 0 && s.st.why == S2A_FLOOR_WHY_GATE);
    // 托底中时钟倒退：起点跟着重设，不会因为「已过很久」立刻松开
    engage_with_headroom(&s); CHECK(sim_run(&s, 24.0, 20) == 1);
    s.in.now_ns -= 100 * SEC;
    CHECK(sim_tick(&s, 24.0) == 1 && s.st.since_ns == s.in.now_ns);
    CHECK(sim_run(&s, 24.0, 200) == 1);
}

static void test_cap_cpus(void) {
    int out[S2A_FLOOR_MAX_CAPS];
    unsigned tablet[8] = {762, 762, 762, 762, 762, 762, 1024, 1024};
    CHECK(s2a_floor_cap_cpus(tablet, 8, 0x3Full, out, S2A_FLOOR_MAX_CAPS) == 2 && out[0] == 0 && out[1] == 6);
    unsigned phone143[8] = {380, 380, 380, 380, 800, 800, 800, 1024};
    CHECK(s2a_floor_cap_cpus(phone143, 8, 0x70ull, out, S2A_FLOOR_MAX_CAPS) == 3 && out[0] == 4 && out[1] == 0 && out[2] == 7);
    unsigned big_first[8] = {1024, 1024, 762, 762, 762, 762, 762, 762};
    CHECK(s2a_floor_cap_cpus(big_first, 8, 0xFCull, out, S2A_FLOOR_MAX_CAPS) == 2 && out[0] == 2 && out[1] == 0);
    CHECK(s2a_floor_cap_cpus(tablet, 8, 0, out, S2A_FLOOR_MAX_CAPS) == 1 && out[0] == 0);       // 没分组：只读核 0
    CHECK(s2a_floor_cap_cpus(NULL, 8, 0x3Full, out, S2A_FLOOR_MAX_CAPS) == 1 && out[0] == 0);
    CHECK(s2a_floor_cap_cpus(tablet, 8, 0x3Full, out, 1) == 1 && out[0] == 0);                    // 数组只放得下 1 个：目标组优先
    CHECK(s2a_floor_cap_cpus(tablet, 8, 0x3Full, NULL, 4) == 0 && s2a_floor_cap_cpus(tablet, 8, 0x3Full, out, 0) == 0);
}

static void test_parse_tis(void) {
    // 真机（骁龙 8 Elite for Galaxy / Adreno 840 平板，policy0）time_in_state 前 12 行的样子
    static const char dev[] = "384000 0\n537600 0\n691200 0\n787200 17921577\n883200 541161\n998400 278572\n"
                              "1113600 265750\n1228800 217815\n1324800 784462\n1440000 345806\n1555200 913606\n1670400 469602\n";
    static const uint64_t khz[12] = {384000, 537600, 691200, 787200, 883200, 998400, 1113600, 1228800, 1324800, 1440000, 1555200, 1670400};
    static const uint64_t ticks[12] = {0, 0, 0, 17921577, 541161, 278572, 265750, 217815, 784462, 345806, 913606, 469602};
    uint64_t w = 0, t = 0, ew = 0, et = 0;
    for (int i = 0; i < 12; i++) { ew += khz[i] * ticks[i]; et += ticks[i]; }
    CHECK(s2a_floor_parse_tis(dev, sizeof dev - 1, &w, &t) == 12 && w == ew && t == et);
#define PARSE(lit) s2a_floor_parse_tis(lit, sizeof(lit) - 1, &w, &t)
    // 没有结尾换行 / CRLF / 行首空白 / 空行 / 行尾多出来的列：都认
    CHECK(PARSE("1000 5") == 1 && w == 5000 && t == 5);
    CHECK(PARSE("1000 5\r\n2000 7\r\n") == 2 && w == 5000 + 14000 && t == 12);
    CHECK(PARSE("1000 5\r\n\r\n2000 7\r\n") == 2 && w == 5000 + 14000 && t == 12);   // CRLF 的空行
    CHECK(PARSE("  1000   5\n\n\n2000 7 99 abc\n") == 2 && w == 5000 + 14000 && t == 12);
    // 格式不认 / 空 / 只有一列 / 数值离谱 / 行数离谱：返回 0，不改输出
    w = 77; t = 88;
    CHECK(PARSE("") == 0 && w == 77 && t == 88);
    CHECK(PARSE("abc\n") == 0);
    CHECK(PARSE("1000\n") == 0);
    CHECK(PARSE("1000 x\n") == 0);
    CHECK(PARSE("\n\n  \n") == 0);
    CHECK(PARSE("99999999999 5\n") == 0);     // 频率 > 2^24 kHz
    CHECK(PARSE("1000 99999999999\n") == 0);  // 时间 > 2^32
    CHECK(PARSE("16777216 1\n") == 1);        // 恰好 2^24 还认
    CHECK(PARSE("16777217 1\n") == 0);
    CHECK(PARSE("1000 4294967296\n") == 1);   // 恰好 2^32 还认
    CHECK(PARSE("1000 4294967297\n") == 0);
    {
        char many[129 * 8 + 1]; size_t o = 0;
        for (int i = 0; i < 129; i++) o += (size_t)snprintf(many + o, sizeof many - o, "100 1\n");
        CHECK(s2a_floor_parse_tis(many, o, &w, &t) == 0);               // 129 行：不是 cpufreq 的样子
        CHECK(s2a_floor_parse_tis(many, o - 6, &w, &t) == 128 && t == 128);   // 128 行还认
    }
    // 到 NUL 为止（缓冲区后面是脏数据）
    CHECK(PARSE("1000 5\n\0009999 9\n") == 1 && t == 5);
#undef PARSE
}

int main(void) {
    test_hist();
    test_pick();
    test_cap_cpus();
    test_parse_tis();
    test_gates();
    test_always();
    test_auto_enter();
    test_auto_release();
    test_auto_stays_while_slow();
    test_auto_idle();
    test_auto_clock();
    test_ceiling();
    test_cap_drop();
    test_no_gain();
    if (failed) { fprintf(stderr, "cpu floor policy: %d checks failed\n", failed); return 1; }
    printf("cpu floor policy: passed\n");
    return 0;
}
