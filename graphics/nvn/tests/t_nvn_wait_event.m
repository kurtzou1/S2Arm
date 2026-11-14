// GPU 等事件（nvnCommandBufferWaitEvent → OP_SIGNAL_EVENT + NVN_EV_WAIT，nvn_mtl.m ev_wait）：直接包含生产 nvn_mtl.m，在真 Metal 队列上回放手写的记录流。
// 每条记录 = {op, size 24} + {事件地址, 方式, 值}；一个提交里「等待 → 之后一笔 GPU 侧 SignalEvent 写标记」，标记在提交完成时由完成回调写（post kind 1），
// 所以「标记落地 / 提交完成」= GPU 越过了等待。期望按 NVN 语义手写，与实现无关：
//   ① 事件已是 1、等「等于 1」→ 不登记等待，提交照常完成、标记 = 7
//   ② 事件是 0、等「等于 1」→ 登记 1 次；CPU 不写，200 ms 内提交不完成、标记仍 0；CPU 写 1 并通知（nvnEventSignal 的路径）→ 提交完成、标记 = 7
//   ③ 同一提交里先 GPU 侧 SignalEvent 写 5、再等「回绕大于等于 5」→ 不登记（队列顺序保证先后；若登记则提交等自己，永远不完成）
//   ④ 保险：等「等于 9」永远没人写，超时 300 ms → 强制放行 1 次、提交完成
//   ⑤ 反证：把等待位去掉当普通记录（= 改前不等）时 ② 的提交不等 CPU 就完成——夹具真能测出「GPU 没等」
//   ⑥ 跨队列（11-05 时之笛：7 条 NVN 队列排进同一条 Metal 队列，等别的队列稍后发的信号）：超时设 3000 ms；提交 1 等 E「等于 1」，提交 2 才录 GPU 侧 SignalEvent 写 E=1
//      → 两个提交都在 1000 ms 内完成（不等到超时）、强制放行 0 次、E = 1；之后提交 3 等 E「等于 2」（E 只由 GPU 侧写过）→ 不登记、照常完成
//   ⑦ 超时放行后复查后面的票：超时 500 ms；票 A 等 F 永远不来，300 ms 后票 B 等 G、CPU 随即写 G=1 并通知（B 排在 A 后面）→ A 超时放行时 B 跟着放：
//      强制放行只 1 次（改前 B 也要等到它自己的超时，2 次）
//   ⑧ 录制时已知 GPU 侧信号（11-05 时之笛第二十九版读档：事件第一次被等时写它的 SignalEvent 还没提交，只录在别的队列的命令缓冲里）：
//      超时 3000 ms；先「录制」写 H 的 SignalEvent（nvn_be_event_gpu_recorded，不提交），再提交等 H「等于 1」→ 不登记、200 ms 内完成、强制放行 0 次；
//      之后才提交那笔信号 → H = 1。对照：没录制过信号的事件 K 同样等待 → 登记 1 次（CPU 随后写 K 放行，免得等到超时）
//   ⑨ 一帧的提交共用命令分配器（照 nxnative，MIT）：闸住 GPU（等一个 CPU 还没写的事件），同一帧再录 24 个提交（三倍于池）→ 都录完、等 GPU 换分配器 0 次、共用 ≥ 23 次、
//      不计数的提交不取计数缓冲（环不变）；放开闸后全部完成。改前第 9 个提交在池满处等 GPU，而 GPU 停在闸上，单测被 alarm 杀掉
//   ⑩ 计数缓冲环：24 个在途计数提交各取一个互不相同的环缓冲；它们完成后下一个复用，环不再长
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
typedef struct { op_hdr h; volatile uint32_t *val; uint32_t mode, v; } ev_rec;
static ev_rec rec(volatile uint32_t *val, uint32_t mode, uint32_t v) { return (ev_rec){{OP_SIGNAL_EVENT, 24}, val, mode, v}; }
enum { N9 = 24 };   // ⑨ ⑩：三倍于分配器池（8）
static uint64_t run_in(const ev_rec *r, int n, int same) {   // 一个提交：n 条事件记录 + END，返回栅栏
    struct { ev_rec r[4]; op_hdr end; } s; memset(&s, 0, sizeof s); REQUIRE(n <= 4);
    for (int i = 0; i < n; i++) s.r[i] = r[i];
    *(op_hdr *)&s.r[n] = (op_hdr){OP_END, sizeof(op_hdr)};
    static uint64_t frame = 1; if (!same) nvn_be_set_frame(++frame); nvn_be_sub_begin(); state_reset();
    nvn_be_exec((const uint8_t *)&s); return nvn_be_sub_commit();
}
static uint64_t run(const ev_rec *r, int n) { return run_in(r, n, 0); }
static uint64_t run_same(const ev_rec *r, int n) { return run_in(r, n, 1); }   // 不换帧：同一帧的又一个提交
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    static volatile uint32_t ev[4], mark[4];
    // ①
    ev[0] = 1; uint64_t w0 = g_evw_waits; ev_rec a[] = {rec(&ev[0], 0 | NVN_EV_WAIT, 1), rec(&mark[0], 0, 7)};
    uint64_t f = run(a, 2); int done = nvn_be_wait(f, 5000000000ull);
    VERIFY(g_evw_waits == w0 && done && mark[0] == 7, "① 已满足：不登记等待（登记 %llu 次）、提交完成 %d、标记 %u（期望 7）", (unsigned long long)(g_evw_waits - w0), done, mark[0]);
    // ②
    ev[1] = 0; w0 = g_evw_waits; ev_rec b[] = {rec(&ev[1], 0 | NVN_EV_WAIT, 1), rec(&mark[1], 0, 7)};
    f = run(b, 2); done = nvn_be_wait(f, 200000000ull);
    VERIFY(g_evw_waits == w0 + 1 && !done && mark[1] == 0, "② 未满足：登记 1 次（实 %llu）、200 ms 内没完成（完成 %d）、标记仍 0（实 %u）", (unsigned long long)(g_evw_waits - w0), done, mark[1]);
    ev[1] = 1; nvn_be_event_written(&ev[1]); done = nvn_be_wait(f, 5000000000ull);
    VERIFY(done && mark[1] == 7, "② CPU 写 1 并通知后：提交完成 %d、标记 %u（期望 7）", done, mark[1]);
    // ③
    ev[2] = 0; w0 = g_evw_waits; ev_rec c[] = {rec(&ev[2], 0, 5), rec(&ev[2], 1 | NVN_EV_WAIT, 5), rec(&mark[2], 0, 7)};
    f = run(c, 3); done = nvn_be_wait(f, 5000000000ull);
    VERIFY(g_evw_waits == w0 && done && mark[2] == 7 && ev[2] == 5, "③ 同提交先信号后等：不登记（登记 %llu）、完成 %d、标记 %u、事件 %u（期望 0 / 1 / 7 / 5）", (unsigned long long)(g_evw_waits - w0), done, mark[2], ev[2]);
    // ④
    g_evw_timeout_ms = 300; ev[3] = 0; uint64_t fo = g_evw_forced; ev_rec d[] = {rec(&ev[3], 0 | NVN_EV_WAIT, 9), rec(&mark[3], 0, 7)};
    f = run(d, 2); done = nvn_be_wait(f, 5000000000ull);
    VERIFY(done && mark[3] == 7 && g_evw_forced == fo + 1, "④ 永远不满足：超时后强制放行 %llu 次、提交完成 %d、标记 %u", (unsigned long long)(g_evw_forced - fo), done, mark[3]);
    // ⑤
    ev[1] = 0; mark[1] = 0; ev_rec e[] = {rec(&ev[1], 0, 0), rec(&mark[1], 0, 7)};   // 等待位去掉：只是一笔写 0 的信号（= 改前没录等待）
    f = run(e, 2); done = nvn_be_wait(f, 200000000ull);
    VERIFY(done && mark[1] == 7, "⑤ 反证 不等时：200 ms 内已完成 %d、标记 %u（夹具能区分「等了 / 没等」）", done, mark[1]);
    // ⑥
    g_evw_timeout_ms = 3000; static volatile uint32_t e6, m6[3]; e6 = 0; uint64_t fo6 = g_evw_forced, w6 = g_evw_waits, sk6 = g_evw_xq_skip;
    uint64_t t6 = bp_now(); ev_rec g1[] = {rec(&e6, 0 | NVN_EV_WAIT, 1), rec(&m6[0], 0, 7)}; uint64_t f1 = run(g1, 2);
    ev_rec g2[] = {rec(&e6, 0, 1), rec(&m6[1], 0, 7)}; uint64_t f2 = run(g2, 2);
    int d1 = nvn_be_wait(f1, 5000000000ull), d2 = nvn_be_wait(f2, 5000000000ull); double ms6 = (bp_now() - t6) / 1e6;
    VERIFY(d1 && d2 && m6[0] == 7 && m6[1] == 7 && e6 == 1 && ms6 < 1000 && g_evw_forced == fo6 && g_evw_waits == w6 + 1,
           "⑥ 信号录在等待之后（别的队列）：两提交完成 %d / %d、%.0f ms（期望 < 1000）、强制放行 %llu 次（期望 0）、E = %u", d1, d2, ms6, (unsigned long long)(g_evw_forced - fo6), e6);
    ev_rec g3[] = {rec(&e6, 0 | NVN_EV_WAIT, 2), rec(&m6[2], 0, 7)}; uint64_t f3 = run(g3, 2); int d3 = nvn_be_wait(f3, 200000000ull);
    VERIFY(d3 && m6[2] == 7 && g_evw_xq_skip == sk6 + 1 && g_evw_waits == w6 + 1, "⑥ 只由 GPU 侧写的事件之后不在 GPU 上等：200 ms 内完成 %d、不等 %llu 次（期望 1）", d3, (unsigned long long)(g_evw_xq_skip - sk6));
    // ⑦
    g_evw_timeout_ms = 500; static volatile uint32_t eF, eG, m7[2]; eF = eG = 0; uint64_t fo7 = g_evw_forced;
    ev_rec ha[] = {rec(&eF, 0 | NVN_EV_WAIT, 1)}; uint64_t fa = run(ha, 1);   // A 只等不写：它完成时没有 GPU 侧信号落地来顺带复查（时之笛 ticket 3 → 4 的情形）
    usleep(300000);
    ev_rec hb[] = {rec(&eG, 0 | NVN_EV_WAIT, 1), rec(&m7[1], 0, 7)}; uint64_t fb = run(hb, 2);
    eG = 1; nvn_be_event_written(&eG);
    int da = nvn_be_wait(fa, 5000000000ull), db = nvn_be_wait(fb, 5000000000ull);
    usleep(600000);   // 等过 B 自己的超时点：改前 B 在那时才被强制放行（计数 +1）
    VERIFY(da && db && m7[1] == 7 && g_evw_forced == fo7 + 1, "⑦ 超时放行后复查：A / B 完成 %d / %d、强制放行 %llu 次（期望 1）", da, db, (unsigned long long)(g_evw_forced - fo7));
    // ⑧
    g_evw_timeout_ms = 3000; static volatile uint32_t eH, eK, m8[3]; eH = eK = 0; uint64_t fo8 = g_evw_forced, w8 = g_evw_waits;
    nvn_be_event_gpu_recorded(&eH);
    ev_rec h1[] = {rec(&eH, 0 | NVN_EV_WAIT, 1), rec(&m8[0], 0, 7)}; uint64_t fh = run(h1, 2); int dh = nvn_be_wait(fh, 200000000ull);
    VERIFY(dh && m8[0] == 7 && g_evw_waits == w8 && g_evw_forced == fo8, "⑧ 录制时已知 GPU 侧信号：200 ms 内完成 %d、登记 %llu 次（期望 0）、强制放行 %llu 次（期望 0）",
           dh, (unsigned long long)(g_evw_waits - w8), (unsigned long long)(g_evw_forced - fo8));
    ev_rec h2[] = {rec(&eH, 0, 1), rec(&m8[1], 0, 7)}; uint64_t fh2 = run(h2, 2); int dh2 = nvn_be_wait(fh2, 5000000000ull);
    VERIFY(dh2 && eH == 1, "⑧ 之后提交的信号照常写：完成 %d、H = %u（期望 1）", dh2, eH);
    ev_rec k1[] = {rec(&eK, 0 | NVN_EV_WAIT, 1), rec(&m8[2], 0, 7)}; uint64_t fk = run(k1, 2);
    VERIFY(g_evw_waits == w8 + 1, "⑧ 对照：没录制过信号的事件照常登记 %llu 次（期望 1）", (unsigned long long)(g_evw_waits - w8));
    eK = 1; nvn_be_event_written(&eK); int dk = nvn_be_wait(fk, 5000000000ull);
    VERIFY(dk && m8[2] == 7 && g_evw_forced == fo8, "⑧ 对照：CPU 写后放行、完成 %d、强制放行 %llu 次（期望 0）", dk, (unsigned long long)(g_evw_forced - fo8));
    // ⑨
    g_evw_timeout_ms = 30000; static volatile uint32_t eW, m9[N9]; eW = 0; uint64_t aw9 = g_alloc_waits, sh9 = g_alloc_shares; int ring9 = g_vis_ring_n, pool9 = g_alloc_n;
    ev_rec hw[] = {rec(&eW, 0 | NVN_EV_WAIT, 1)}; run(hw, 1);   // 闸：GPU 停在这个等待上，后面同队列的提交都不完成
    uint64_t f9 = 0; for (int i = 0; i < N9; i++) { ev_rec r9[] = {rec(&m9[i], 0, 7)}; f9 = run_same(r9, 1); }
    int none9 = 1; for (int i = 0; i < N9; i++) none9 &= m9[i] == 0;
    VERIFY(none9 && g_alloc_waits == aw9, "⑨ 闸住 GPU 时同一帧 %d 个提交照常录完、等 GPU 换分配器 %llu 次（期望 0）", N9, (unsigned long long)(g_alloc_waits - aw9));
    VERIFY(g_alloc_shares - sh9 >= N9 - 1 && g_alloc_n <= pool9 + 1, "⑨ 它们共用这一帧的分配器：共用 %llu 次（期望 ≥ %d）、池 %d → %d", (unsigned long long)(g_alloc_shares - sh9), N9 - 1, pool9, g_alloc_n);
    VERIFY(g_vis_ring_n == ring9, "⑨ 不计数的提交不取计数缓冲：环 %d → %d（期望不变）", ring9, g_vis_ring_n);
    eW = 1; nvn_be_event_written(&eW); int d9 = nvn_be_wait(f9, 5000000000ull); int all9 = 1; for (int i = 0; i < N9; i++) all9 &= m9[i] == 7;
    VERIFY(d9 && all9, "⑨ 放开闸后全部完成：%d、标记全 7：%d", d9, all9);
    // ⑩
    { const uint64_t far = g_done + (1ull << 40); __strong id<MTLBuffer> taken[N9]; int took = 0;
      for (int i = 0; i < N9; i++) { g_vis_ring_i = -1; g_vis = nil; vis_take(); taken[i] = g_vis; if (g_vis && g_vis_ring_i >= 0 && vis_in_ring(g_vis)) { took++; g_vis_ring[g_vis_ring_i].fence = far + (uint64_t)i; } }
      int distinct = 1; for (int i = 0; i < N9; i++) for (int k = 0; k < i; k++) if (taken[i] == taken[k]) distinct = 0;
      VERIFY(took == N9 && distinct, "⑩ %d 个在途计数提交各取环里一个不同的缓冲：取到 %d、互不相同 %d", N9, took, distinct);
      const int grown = g_vis_ring_n; for (int i = 0; i < grown; i++) if (g_vis_ring[i].fence >= far) g_vis_ring[i].fence = 0;
      g_vis_ring_i = -1; g_vis = nil; vis_take();
      VERIFY(g_vis && g_vis_ring_n == grown && vis_in_ring(g_vis), "⑩ 它们完成后下一个复用环里的缓冲：环 %d → %d（期望不变）", grown, g_vis_ring_n);
      if (g_vis_ring_i >= 0) g_vis_ring[g_vis_ring_i].fence = 0; g_vis_ring_i = -1; g_vis = nil; g_vis_n = 0; }
  }
    if (failures) { printf("✗ t_nvn_wait_event：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_wait_event：%u 项全过（GPU 等事件：已满足 / 同提交先信号不等；未满足在 GPU 上等到 CPU 写；超时强制放行并复查后票；跨队列信号录到即放、只 GPU 写的不等）\n", checks); return 0;
}
