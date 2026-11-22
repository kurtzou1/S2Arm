// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 几何绘制段的边界（nvn_geometry.inc geo_run_*，11-06 能耗线：金刚一帧 541 笔几何绘制首尾相接，段里抓顶点 / 几何核 / 主遍各一个编码器）。
// 段里的几何核在道 1，段结束时才接进主流；所以段外任何工作都得等段先结束，否则会排到几何核前面、读不到它写的东西。
// 期望按构造写死：每次派发一个线程，原子取号 i 后写 out[i] = 标签，out 就是 GPU 上的执行顺序。段由 geo_run_begin 开，道 1 先派一次「几何核」（标签 1）。
//   ① 段内只来状态设置（命令流 [混合色][结束]）：段不结束（延后照旧）
//   ② 段外工作（命令流 [派发 标签 2][结束]，读几何核写的缓冲）：先结束段 → 执行顺序 [1 2]
//   ③ 遍结束（rp_end）：段结束
//   ④ 段末压缩（geo_run_flush 里统一派的压缩）排在段里全部几何核之后：一个故意慢的「几何核」（先空转再取号，标签 1）+ 两次「压缩」（标签 5 / 6）→ 执行顺序第一个是 1，后两个是 {5, 6}
//   ⑤ 几何核之间的屏障判定（geo_hz_* / geo_gs_ranges，纯计算）：读到前面写过的区间 → 要；写到前面读过的 → 要；都不相交 → 不要；记满 → 之后都要；
//      有可写图像的几何核 → 区间列举不全（返回 0）
//   ⑥ 几何变体按程序缓存（geo_variants）：查表换成计数版；同一程序同一几何阶段第二次不查；换拓扑只查几何核那支；换深度模式只查读记录那支；
//      程序的几何阶段换了（换成另一个着色器）两支都重查、查的是新键；换一个程序对象重查；查不到的不缓存
//   ⑦ 大小没给的可写存储缓冲（绑定大小 0）：派发后整次提交不标「写记录溢出」（g_sbw_over），写区间记成「从地址到所在缓冲末尾」：
//      池内绑定地址 +0x8000 之后的页算写过、之前的页（+0x1000）不算（11-06 金刚：原先记成大小 0 → 整次提交溢出 → 之后每笔带下标的几何绘制都等 GPU、不入段）
//   ⑧ 帧暂存到切段阈值（geo_scratch_cut）：段开着、本段暂存已到 ARENA_CUT → 段结束、提交切一刀（段计数 +1、本段暂存归零）；没到阈值什么都不动
//      （11-06 维护者 手测金刚：段里几何绘制的暂存堆在一个不切的段里超过 ARENA_CAP，新块等 GPU 满 2 秒，卡 2.1 秒）。主遍按段里的样子在道 2 开着（8×1 渲染目标）
// 反证（各自在源码上临时改）：geo_scratch_cut 不先结束段 → ⑧ 段仍开着，红；sbw_to_end 退回大小 0（原写法）→ ⑦ 溢出标志为 1，红；geo_variants 不比 geo_base → ⑥「几何阶段换了」那条红；geo_run_flush 里压缩前那道屏障去掉 → ④ 顺序乱（慢的几何核排不到第一）；geo_hz_conflict 恒 0 → ⑤ 的两条「要」红；geo_run_keeps 对 OP_BLEND_COLOR 返回 0 → ① 红；执行循环的段钩子与 dispatch() / enc_c_begin 的钩子都去掉 → ② 顺序成 [2 1]；
//   rp_end 去掉钩子 → ③ 红；geo_pt_variants 不看 geo_pt 标记 → ⑨「没标直通」那条红（查了表、走了快路）
//   ⑩ 段内次序冒险（审计 P1-120）：抓顶点读到段里前面几何核写过的 / 几何核写到段里前面片元读过的 → 先结束段；列举不全按撞上；记满之后都撞
//   ⑫ 原始池表绑定（NVN_RB_GMEM）：读写区间列举不全（只读清读位、可写两位都清）；片元有这种写不入段。反证：geo_stage_ranges 去掉 GMEM 分支 → 只读返回 3、可写返回 3，红
//   ⑬ 原始池表写的预测生效后（11-07 金刚：iOS 缺省开池表、片元带池表写的几何绘制一律不入段，整局几何段 0、帧时 80 ms）：片元带池表写也入段，写区间 = 学到的池；
//      预测没生效 / 已记满 → 仍不入段；段里前一笔片元池表写与后一笔抓顶点读 / 几何核读写重叠 → 先结束段，不重叠不结束；之后学到的新池补进段里的记录；预测中途失效 → 结束段；
//      段里有按预测记的写，段末把段里的读写区间交给 g_gsr（预测漏学时 gml_read 按同一口径查）。反证：geo_run_hazard_fw 去掉重叠查 → ⑬ ③ 红；geo_fs_writes 恢复 GMEM 一律排除 → ⑬ ① 红
//   ⑭ 段内遮挡查询上报（#1449：0100B8E016F76000 每笔几何绘制后报一次 SAMPLES_PASSED，每笔断段、断主遍）：[上报 SAMPLES_PASSED][结束] 段不结束；
//      [上报 时间戳][结束] 照旧结束段、原因记「状态之外的操作」操作码 5。反证：执行循环去掉 SAMPLES_PASSED 例外 → ⑭ 第一条红
//   ⑮ 段内事件信号 / 写值（#1449 0.6.7 D-CQG6：同款每次遮挡上报后跟一笔 ReportValue，⑭ 之后改成每笔都被它断段）：[信号 写值][结束] 段不结束、
//      收尾后事件按写值落地（提交完成后由 CPU 写）；[等事件][结束] 照旧结束段、原因记操作码 4。反证：执行循环去掉信号例外 → ⑮ 第一条红
//   ⑯ 段内遮挡查询重置（#1449 主线 11-22 尼尔 Mac 局：⑭⑮ 之后每笔几何绘制前的 SAMPLES_PASSED 重置断段，429 万段每段 1.008 笔）：[重置 SAMPLES_PASSED][结束] 段不结束、
//      开始计数；[重置 时间戳][结束] 照旧结束段、原因记操作码 36。反证：执行循环去掉重置例外 → ⑯ 第一条红
//   ⑨ 直通几何快路选择（geo_pt_pick）：几何核标直通（json geometry.passthrough）、单实例、单次调用、三角 → 换成 <键>_bgs3 与 <键>_bgc；
//      没标直通 → 不走、一次表都不查；两实例 / 邻接三角（拓扑 4）/ 开变换反馈 / 几何核两次调用 / DM_NVN_GEO_PT=0 → 不走；缺 _bgc → 不走、几何核与读取器保持原样
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); fails += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static uint8_t g_ops[512]; static size_t g_on;
static int g_lk; static char g_lk_last[64]; static int g_lk_nil;   // ⑥ 计数版查表：记次数、最后一个键；g_lk_nil 时回 nil
static NvShader *lookup_count(NSString *k, int st) { (void)st; g_lk++; snprintf(g_lk_last, sizeof g_lk_last, "%s", k.UTF8String); if (g_lk_nil) return nil; NvShader *o = [NvShader new]; o->stage = st;
    strlcpy(o->key, k.UTF8String, sizeof o->key); o->geo_invocations = 1; return o; }
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz = (uint32_t)((8 + n + 7) & ~7u); REQUIRE(g_on + sz <= sizeof g_ops);
    op_hdr h = {op, sz}; memcpy(g_ops + g_on, &h, 8); memset(g_ops + g_on + 8, 0, sz - 8); if (n) memcpy(g_ops + g_on + 8, pay, n); g_on += sz;
}
static id<MTLComputePipelineState> lane_ps;
static uint8_t *mem; static uint64_t gbase; static pool_t *pool8;   // 一块登记过的池：计数 +0x0、输出 +0x100、标签 +0x200（标签 = 字号）
enum { CNT = 0x0, OUT = 0x100, TAG = 0x200 };
static void lane_kernel(uint32_t tag) {   // 道 1 里的一次「几何核」：槽 0 计数、槽 1 输出、槽 2 标签
    rec_lane(1); id ce = g_gr.gs;
    enc_c_pso(ce, lane_ps); enc_c_args(ce, gbase + CNT, 0); enc_c_args(ce, gbase + OUT, 1); enc_c_args(ce, gbase + TAG + tag * 4, 2);
    enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1)); enc_c_inner_barrier(ce); rec_lane(0);
}
static prog_t cprog;
static void bind_tagged(uint32_t tag) {   // 命令流里的派发：同一个计数 / 输出，标签 tag
    S.cprog = &cprog;
    S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(mem + CNT), .size = 16};
    S.ssbo[5][1] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(mem + OUT), .size = 64};
    S.ssbo[5][2] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(mem + TAG + tag * 4), .size = 4};
    args_dirty_all();
}
static void reset_mem(void) { memset(mem + CNT, 0, 16); memset(mem + OUT, 0xff, 64); }
static uint32_t outv(int i) { return ((uint32_t *)(mem + OUT))[i]; }
static uint32_t count(void) { return ((uint32_t *)(mem + CNT))[0]; }
static void finish(void) { uint64_t fe = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    setenv("DM_NVN_ENC_THREAD", "1", 1);   // 段只在录制线程开着时成立（iOS 缺省开）
    mtl_init(); REQUIRE(!g_m3); REQUIRE(rec_on());
    const op_hdr empty = {OP_END, sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *e = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void lane(device atomic_uint *c [[buffer(0)]], device uint *o [[buffer(1)]], device const uint *t [[buffer(2)]]) {"
        " uint i = atomic_fetch_add_explicit(c, 1u, memory_order_relaxed); o[i] = t[0]; }\n"
        "kernel void slow(device atomic_uint *c [[buffer(0)]], device uint *o [[buffer(1)]], device const uint *t [[buffer(2)]]) {"
        " uint x = t[0]; for (uint k = 0; k < 2000000u; k++) x = x * 1664525u + 1013904223u; if (x == 7u) o[15] = x;"
        " uint i = atomic_fetch_add_explicit(c, 1u, memory_order_relaxed); o[i] = t[0]; }\n"
        "struct Job { device atomic_uint *c; device uint *o; uint tag; };\n"
        "kernel void job(constant Job &j [[buffer(0)]], uint tid [[thread_index_in_threadgroup]]) { if (tid) return;"
        " uint i = atomic_fetch_add_explicit(j.c, 1u, memory_order_relaxed); j.o[i] = j.tag; }\n"
        "struct Args { device uint *cp_s0 [[id(0)]]; device uint *cp_s1 [[id(1)]]; device uint *cp_s2 [[id(2)]]; };\n"
        "kernel void cs(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x) return;"
        " uint i = atomic_fetch_add_explicit((device atomic_uint *)a.cp_s0, 1u, memory_order_relaxed); a.cp_s1[i] = a.cp_s2[0]; }" options:nil error:&e];
    if (!lib) fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String); REQUIRE(lib);
    lane_ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"lane"] error:&e]; REQUIRE(lane_ps);
    id<MTLComputePipelineState> slow_ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"slow"] error:&e]; REQUIRE(slow_ps);
    id<MTLComputePipelineState> job_ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"job"] error:&e]; REQUIRE(job_ps);
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"cs"]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
    char err[256] = "";
    REQUIRE(nvn_refl_from_json(@{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
        @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES, @"msl_name": @"cp_s0", @"msl_type": @"device uint*" },
        @{ @"kind": @"sbuf", @"reg": @1, @"arg_id": @1, @"rw": @YES, @"msl_name": @"cp_s1", @"msl_type": @"device uint*" },
        @{ @"kind": @"sbuf", @"reg": @2, @"arg_id": @2, @"rw": @NO, @"msl_name": @"cp_s2", @"msl_type": @"device uint*" } ] }, &cs->rf, err, sizeof err) == 0);
    cprog = (prog_t){.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(cprog.serial, np);
    REQUIRE(!posix_memalign((void **)&mem, 65536, 1 << 16)); memset(mem, 0, 1 << 16);
    pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool); pool8 = pool;   // 活到进程结束：生产池是不拷贝的 MTLBuffer
    *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = 1 << 16};
    nvn_be_pool_add(mem, 1 << 16);
    { void *mb; uint64_t mo; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem, 1 << 16, &mb, &mo, &gbase)); }
    for (uint32_t i = 0; i < 16; i++) ((uint32_t *)(mem + TAG))[i] = i;
    const p_blend_color bc = {{0.25f, 0.5f, 0.75f, 1.0f}};
    const p_dispatch dp = {.x = 1, .y = 1, .z = 1};

    // ① 段内只来状态设置：段不结束
    reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
    g_on = 0; put(OP_BLEND_COLOR, &bc, sizeof bc); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
    int still = g_gr.active;
    finish();
    CHECK(still && count() == 1 && outv(0) == 1, "① [混合色][结束] 之后段仍开着（%d，期望 1）；收尾后几何核照常执行（计数 %u、标签 %u，期望 1、1）", still, count(), outv(0));

    // ⑭ 段内遮挡查询上报：不结束段；别的计数器上报照旧结束段
    {   uint64_t rq[2] = {NVN_COUNTER_TYPE_SAMPLES_PASSED, (uint64_t)(uintptr_t)(mem + 0x8000)};
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
        g_on = 0; put(OP_REPORT_COUNTER, rq, sizeof rq); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
        int kept = g_gr.active; finish();
        CHECK(kept && count() == 1 && outv(0) == 1, "⑭ [上报 SAMPLES_PASSED][结束] 之后段仍开着（%d，期望 1）；收尾后几何核照常执行（计数 %u，期望 1）", kept, count());
        uint64_t rt[2] = {NVN_COUNTER_TYPE_TIMESTAMP, (uint64_t)(uintptr_t)(mem + 0x8000)};
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
        uint64_t e_op = g_gr_end[GEO_END_OP], e_rc = g_gr_end_op[OP_REPORT_COUNTER];
        g_on = 0; put(OP_REPORT_COUNTER, rt, sizeof rt); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
        int ended = !g_gr.active, why = g_gr_end[GEO_END_OP] - e_op == 1 && g_gr_end_op[OP_REPORT_COUNTER] - e_rc == 1; finish();
        CHECK(ended && why, "⑭ [上报 时间戳][结束] 照旧结束段（%d，期望 1），原因记「状态之外的操作」操作码 5（%d，期望 1）", ended, why); }

    // ⑮ 段内事件信号 / 写值：不结束段、完成后照写；等事件照旧结束段
    {   static volatile uint32_t ev15; ev15 = 7; volatile uint32_t *evp = &ev15;
        uint8_t rs[16]; uint32_t mw = NVN_EVENT_SIGNAL_MODE_WRITE, v15 = 42; memcpy(rs, &evp, 8); memcpy(rs + 8, &mw, 4); memcpy(rs + 12, &v15, 4);
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
        g_on = 0; put(OP_SIGNAL_EVENT, rs, sizeof rs); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
        int kept = g_gr.active; finish();
        CHECK(kept && count() == 1 && outv(0) == 1 && ev15 == 42, "⑮ [信号 写值][结束] 之后段仍开着（%d，期望 1）；收尾后几何核照常执行（计数 %u，期望 1）、事件写成 42（%u）", kept, count(), (unsigned)ev15);
        ev15 = 1; uint32_t mwait = NVN_EV_WAIT | 0u, v1 = 1; memcpy(rs + 8, &mwait, 4); memcpy(rs + 12, &v1, 4);   // 等「等于 1」：已满足，不停队列
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
        uint64_t e_op = g_gr_end[GEO_END_OP], e_se = g_gr_end_op[OP_SIGNAL_EVENT];
        g_on = 0; put(OP_SIGNAL_EVENT, rs, sizeof rs); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
        int ended = !g_gr.active, why = g_gr_end[GEO_END_OP] - e_op == 1 && g_gr_end_op[OP_SIGNAL_EVENT] - e_se == 1; finish();
        CHECK(ended && why, "⑮ [等事件][结束] 照旧结束段（%d，期望 1），原因记「状态之外的操作」操作码 4（%d，期望 1）", ended, why); }

    // ⑯ 段内遮挡查询重置：不结束段；别的计数器重置照旧结束段
    {   uint64_t rq[1] = {NVN_COUNTER_TYPE_SAMPLES_PASSED};
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1); g_vis_counting = 0;
        g_on = 0; put(OP_RESET_COUNTER, rq, sizeof rq); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
        int kept = g_gr.active, counting = g_vis_counting; finish(); g_vis_on = g_vis_counting = 0;   // 后面各项按没开遮挡计数写
        CHECK(kept && counting && count() == 1 && outv(0) == 1, "⑯ [重置 SAMPLES_PASSED][结束] 之后段仍开着（%d，期望 1）、开始计数（%d，期望 1）；收尾后几何核照常执行（计数 %u，期望 1）", kept, counting, count());
        uint64_t rt[1] = {NVN_COUNTER_TYPE_TIMESTAMP};
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
        uint64_t e_op = g_gr_end[GEO_END_OP], e_rs = g_gr_end_op[OP_RESET_COUNTER];
        g_on = 0; put(OP_RESET_COUNTER, rt, sizeof rt); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
        int ended = !g_gr.active, why = g_gr_end[GEO_END_OP] - e_op == 1 && g_gr_end_op[OP_RESET_COUNTER] - e_rs == 1; finish();
        CHECK(ended && why, "⑯ [重置 时间戳][结束] 照旧结束段（%d，期望 1），原因记「状态之外的操作」操作码 36（%d，期望 1）", ended, why); }

    // ② 段外工作：先结束段，几何核排在它前面
    reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
    uint64_t e_op0 = g_gr_end[GEO_END_OP], e_dp0 = g_gr_end_op[OP_DISPATCH], e_ot0 = g_gr_end[GEO_END_OTHER];
    bind_tagged(2); g_on = 0; put(OP_DISPATCH, &dp, sizeof dp); put(OP_END, NULL, 0); nvn_be_exec(g_ops);
    int after = g_gr.active;
    int why2 = g_gr_end[GEO_END_OP] - e_op0 == 1 && g_gr_end_op[OP_DISPATCH] - e_dp0 == 1 && g_gr_end[GEO_END_OTHER] == e_ot0;
    finish();
    CHECK(!after && count() == 2 && outv(0) == 1 && outv(1) == 2, "② [派发 标签 2] 先结束段（段开着 %d，期望 0）：执行顺序 [%u %u]（期望 [1 2]），计数 %u（期望 2）", after, outv(0), outv(1), count());
    CHECK(why2, "② 结束原因记成「状态之外的操作」一次、操作码是派发（%d，期望 1），没记成「结束主遍 / 其他」", why2);

    // ③ 遍结束：段结束
    reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
    uint64_t e_ot3 = g_gr_end[GEO_END_OTHER];
    rp_end(); int ended = !g_gr.active, why3 = g_gr_end[GEO_END_OTHER] - e_ot3 == 1;
    finish();
    CHECK(why3, "③ rp_end 结束的段记成「结束主遍 / 其他」一次（%d，期望 1）", why3);
    CHECK(ended && count() == 1 && outv(0) == 1, "③ rp_end 之后段已结束（%d，期望 1），几何核执行了（计数 %u，期望 1）", ended, count());

    // ④ 段末压缩排在全部几何核之后
    reset_mem(); nvn_be_sub_begin(); geo_run_begin();
    rec_lane(1); { id ce = g_gr.gs; enc_c_pso(ce, slow_ps); enc_c_args(ce, gbase + CNT, 0); enc_c_args(ce, gbase + OUT, 1); enc_c_args(ce, gbase + TAG + 4, 2);
        enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1)); } rec_lane(0);
    typedef struct { uint64_t c, o; uint32_t tag, pad; } job_t;   // = struct Job
    job_t *jb = (job_t *)(mem + 0x400);
    for (int i = 0; i < 2; i++) { jb[i] = (job_t){gbase + CNT, gbase + OUT, 5u + (uint32_t)i, 0};
        if (g_gr.njobs == g_gr.cjobs) { g_gr.cjobs = g_gr.cjobs ? 2 * g_gr.cjobs : 256; g_gr.jobs = realloc(g_gr.jobs, g_gr.cjobs * sizeof *g_gr.jobs); REQUIRE(g_gr.jobs); }
        g_gr.jobs[g_gr.njobs++] = gbase + 0x400 + (uint64_t)i * sizeof(job_t); }
    g_gr.pack = job_ps;
    geo_run_flush(); finish();
    uint32_t a1 = outv(1), a2 = outv(2);
    CHECK(count() == 3 && outv(0) == 1 && ((a1 == 5 && a2 == 6) || (a1 == 6 && a2 == 5)), "④ 段末压缩在几何核之后：执行顺序 [%u %u %u]（期望 1 在先、后两个是 {5 6}），计数 %u（期望 3）", outv(0), a1, a2, count());

    // ⑤ 屏障判定
    geo_hz h; memset(&h, 0, sizeof h);
    geo_rg w0 = {0x1000, 0x1010}, r0 = {0x2000, 0x2010};
    int a = geo_hz_conflict(&h, &w0, 1, &w0, 1);
    geo_hz_add(&h, &r0, 1, &w0, 1);   // 前面一笔：读 [0x2000,0x2010)、写 [0x1000,0x1010)
    geo_rg raw = {0x1008, 0x1018}, war = {0x200c, 0x2020}, d_r = {0x3000, 0x3008}, d_w = {0x1010, 0x1020};
    int b = geo_hz_conflict(&h, &raw, 1, NULL, 0), c = geo_hz_conflict(&h, NULL, 0, &war, 1), d = geo_hz_conflict(&h, &d_r, 1, &d_w, 1);
    CHECK(!a && b && c && !d, "⑤ 空记录不要 %d（期望 0）；读到前面写过的要 %d（期望 1）；写到前面读过的要 %d（期望 1）；读写都不相交不要 %d（期望 0）", a, b, c, d);
    geo_hz full; memset(&full, 0, sizeof full); geo_rg x = {0x9000, 0x9001};
    for (int i = 0; i <= GEO_HZ_N; i++) { geo_rg y = {0x10000u + (uint64_t)i * 0x100, 0x10000u + (uint64_t)i * 0x100 + 0x10}; geo_hz_add(&full, NULL, 0, &y, 1); }
    int f = geo_hz_conflict(&full, &x, 1, NULL, 0);
    NvShader *img = [NvShader new]; img->rf.nb = 1; img->rf.b = calloc(1, sizeof *img->rf.b); REQUIRE(img->rf.b); img->rf.b[0].kind = NVN_RB_IMG; img->rf.b[0].rw = 1;   // NvShader 释放时 free 它
    geo_rg rr[4], ww[4]; int nr, nw; int k = geo_gs_ranges(img, rr, &nr, ww, &nw, 4);
    CHECK(f && k == 0, "⑤ 记了 %d 个写区间后（超 %d）之后都要 %d（期望 1）；有可写图像的几何核列举不全 %d（期望 0）", GEO_HZ_N + 1, GEO_HZ_N, f, k);

    // ⑩ 段内次序冒险（审计 P1-120，geo_run_hazard / geo_runset_add / geo_stage_ranges，纯计算；期望按段内次序手写）
    {
        static geo_runset rs; memset(&rs, 0, sizeof rs);
        geo_rg gw = {0x4000, 0x4100}, fr = {0x6000, 0x6040};
        int e0 = geo_run_hazard(&rs, &gw, 1, 1, &gw, 1, 1);
        geo_runset_add(&rs, &gw, 1, 1, &fr, 1, 1);   // 段里前一笔：几何核写 [0x4000,0x4100)、片元读 [0x6000,0x6040)
        geo_rg cap_hit = {0x40f0, 0x4110}, cap_miss = {0x4100, 0x4200}, gw_hit = {0x6030, 0x6050}, gw_miss = {0x7000, 0x7010};
        int aa = !!geo_run_hazard(&rs, &cap_hit, 1, 1, NULL, 0, 1), am = geo_run_hazard(&rs, &cap_miss, 1, 1, &gw_miss, 1, 1);
        int bb = !!geo_run_hazard(&rs, &cap_miss, 1, 1, &gw_hit, 1, 1), au = !!geo_run_hazard(&rs, NULL, 0, 0, NULL, 0, 1), bu = !!geo_run_hazard(&rs, NULL, 0, 1, NULL, 0, 0);
        CHECK(!e0 && aa && !am && bb && au && bu, "⑩ 空段不撞 %d（0）；抓顶点读到前面几何核写过的 %d（1）；读写都不相交 %d（0）；几何核写到前面片元读过的 %d（1）；抓顶点读区间列举不全且段里有写 %d（1）；几何核写区间列举不全且段里有片元读 %d（1）",
              e0, aa, am, bb, au, bu);
        static geo_runset nw0; memset(&nw0, 0, sizeof nw0); geo_runset_add(&nw0, NULL, 0, 1, NULL, 0, 1);
        int clean = geo_run_hazard(&nw0, NULL, 0, 0, NULL, 0, 0);   // 前一笔不写不读：列举不全也不撞
        static geo_runset wl; memset(&wl, 0, sizeof wl); geo_runset_add(&wl, NULL, 0, 0, NULL, 0, 1);
        int wall = geo_run_hazard(&wl, &cap_miss, 1, 1, NULL, 0, 1);
        static geo_runset ov; memset(&ov, 0, sizeof ov);
        for (int i = 0; i <= GEO_RS_N; i++) { geo_rg y = {0x100000u + (uint64_t)i * 0x100, 0x100000u + (uint64_t)i * 0x100 + 0x10}; geo_runset_add(&ov, &y, 1, 1, NULL, 0, 1); }
        int ovf = geo_run_hazard(&ov, &cap_miss, 1, 1, NULL, 0, 1);
        static geo_runset mg; memset(&mg, 0, sizeof mg);   // 相接 / 重叠的写区间合并：200 笔各写相邻 0x100 → 合成 1 段、不记满；中间有洞的另成一段
        for (int i = 0; i < 200; i++) { geo_rg y = {0x200000u + (uint64_t)i * 0x100, 0x200000u + (uint64_t)(i + 1) * 0x100}; geo_runset_add(&mg, &y, 1, 1, NULL, 0, 1); }
        geo_rg far = {0x300000, 0x300010}, ov2 = {0x2000f0, 0x200400}; geo_runset_add(&mg, &far, 1, 1, NULL, 0, 1); geo_runset_add(&mg, &ov2, 1, 1, NULL, 0, 1);
        geo_rg in_mid = {0x20c700, 0x20c708};
        int merged = !mg.wall && mg.nw == 2 && mg.w[0].lo == 0x200000 && mg.w[0].hi == 0x200000 + 200 * 0x100 && geo_run_hazard(&mg, &in_mid, 1, 1, NULL, 0, 1) && !geo_run_hazard(&mg, &(geo_rg){0x2fff00, 0x2fff10}, 1, 1, NULL, 0, 1);
        CHECK(merged, "⑩ 写区间合并：200 段相接 + 1 段重叠合成 1 段、另 1 段独立，共 %d 段（期望 2）、记满 %d（期望 0），中间地址撞 / 洞里不撞", mg.nw, mg.wall);
        p_bind_buf su = S.ubo[0][3];
        S.ubo[0][3] = (p_bind_buf){.addr = 0x4080, .size = 0x10};   // 顶点阶段统一缓冲槽 3 读前面几何核写过的 [0x4080,0x4090)
        NvShader *v = [NvShader new]; v->rf.nb = 1; v->rf.b = calloc(1, sizeof *v->rf.b); REQUIRE(v->rf.b); v->rf.b[0].kind = NVN_RB_UBOP; v->rf.b[0].reg = 3;
        geo_rg vr[4], vw[4]; int nvr, nvw, vk = geo_stage_ranges(v, 0, vr, &nvr, vw, &nvw, 4);
        int viaub = vk && nvr == 1 && vr[0].lo == 0x4080 && geo_run_hazard(&rs, vr, nvr, 1, NULL, 0, 1);
        S.ubo[0][3] = su;
        CHECK(!clean && wall && ovf && viaub, "⑩ 前一笔不读不写时列举不全也不撞 %d（0）；前面几何核写区间列举不全 → 之后都撞 %d（1）；写区间记满 %d 个 → 之后都撞 %d（1）；顶点阶段统一缓冲按阶段 0 取区间并撞上 %d（1）",
              clean, wall, GEO_RS_N + 1, ovf, viaub);
    }
    // ⑫ 原始池表（NVN_RB_GMEM，地址从内存读来、可达任一列表里的池，11-06 按需常驻同改）：读写区间都列举不全 → 只读的清读位、可写的读写位都清；片元有这种写 → 不入段
    {
        NvShader *g = [NvShader new]; g->rf.nb = 1; g->rf.b = calloc(1, sizeof *g->rf.b); REQUIRE(g->rf.b); g->rf.b[0].kind = NVN_RB_GMEM;
        geo_rg r[4], w[4]; int nr, nw, ro = geo_stage_ranges(g, 2, r, &nr, w, &nw, 4);
        g->rf.b[0].rw = 1; int rw = geo_stage_ranges(g, 2, r, &nr, w, &nw, 4), fs = geo_fs_writes(g);
        g->rf.b[0].rw = 0; int fs0 = geo_fs_writes(g);
        CHECK(ro == GEO_WK && rw == 0 && fs == 1 && fs0 == 0, "⑫ 原始池表只读：齐全位 %d（期望 %d = 只剩写齐全）；可写：%d（期望 0）；片元有原始池表写 → 不入段 %d（期望 1）、只读 %d（期望 0）", ro, GEO_WK, rw, fs, fs0);
    }
    // ⑬ 原始池表写的预测生效后片元带池表写的几何绘制入段（期望按学到的池 [0x5000,0x5100) 手写）
    {
        NvShader *fg = [NvShader new]; fg->rf.nb = 1; fg->rf.b = calloc(1, sizeof *fg->rf.b); REQUIRE(fg->rf.b); fg->rf.b[0].kind = NVN_RB_GMEM; fg->rf.b[0].rw = 1;
        int on0 = g_gml_on, n0 = g_gml_n, st0 = g_gml_stable, ov0 = g_gml_over;
        g_gml_on = 1; g_gml_n = 1; g_gml_lo[0] = 0x5000; g_gml_hi[0] = 0x5100; g_gml_over = 0;
        geo_rg r[8], w[8]; int nr, nw;
        g_gml_stable = GML_STABLE - 1; geo_gml_snap(); int off_fs = geo_fs_writes(fg), off_k = geo_stage_ranges(fg, 1, r, &nr, w, &nw, 8);
        g_gml_stable = GML_STABLE; g_gml_over = 1; geo_gml_snap(); int over_fs = geo_fs_writes(fg);
        g_gml_over = 0; geo_gml_snap(); int on_fs = geo_fs_writes(fg), on_k = geo_stage_ranges(fg, 1, r, &nr, w, &nw, 8);
        int on_w = nw == 1 && w[0].lo == 0x5000 && w[0].hi == 0x5100;
        CHECK(on_fs == 0 && on_k == GEO_WK && on_w, "⑬ ① 预测生效：片元带池表写不入段 %d（期望 0）；片元阶段齐全位 %d（期望 %d = 写齐全、读不全），写区间 = 学到的池 %d（期望 1）", on_fs, on_k, GEO_WK, on_w);
        CHECK(off_fs == 1 && off_k == 0 && over_fs == 1, "⑬ ② 预测未生效（只稳定 %d 份）：不入段 %d（期望 1）、齐全位 %d（期望 0）；已记满：不入段 %d（期望 1）", GML_STABLE - 1, off_fs, off_k, over_fs);
        static geo_runset rs; memset(&rs, 0, sizeof rs);   // 段里前一笔（同 geo_draw 入段）：几何核不写、片元不读，片元池表写 = 学到的池
        geo_runset_add(&rs, NULL, 0, 1, NULL, 0, 1); geo_runset_add_fw(&rs, w, nw, 1); rs.gml |= 2;
        geo_rg cap_hit = {0x50f0, 0x5110}, cap_miss = {0x5100, 0x5200}, gr_hit = {0x4ff0, 0x5001}, gw_hit = {0x5080, 0x5090};
        int ab = geo_run_hazard(&rs, &cap_hit, 1, 1, NULL, 0, 1);   // A / B 不管片元写：只有 C 能看见
        int hc = geo_run_hazard_fw(&rs, &cap_hit, 1, 1, NULL, 0, 1, NULL, 0, 1), mc = geo_run_hazard_fw(&rs, &cap_miss, 1, 1, &cap_miss, 1, 1, &cap_miss, 1, 1);
        int hr = geo_run_hazard_fw(&rs, &cap_miss, 1, 1, &gr_hit, 1, 1, NULL, 0, 1), hw = geo_run_hazard_fw(&rs, &cap_miss, 1, 1, NULL, 0, 1, &gw_hit, 1, 1);
        int hu = geo_run_hazard_fw(&rs, NULL, 0, 0, NULL, 0, 1, NULL, 0, 1);
        static geo_runset e0; memset(&e0, 0, sizeof e0); int eu = geo_run_hazard_fw(&e0, NULL, 0, 0, NULL, 0, 0, NULL, 0, 0);   // 段里没有片元写：列举不全也不撞
        CHECK(ab == 0 && hc == 10 && mc == 0 && hr == 10 && hw == 10 && hu == 9 && eu == 0,
              "⑬ ③ 前一笔片元池表写 [0x5000,0x5100)：A / B 查不出 %d（0）；抓顶点读 [0x50f0,0x5110) 重叠 %d（10）；读写都在 [0x5100,0x5200) 不重叠 %d（0）；几何核读重叠 %d（10）；几何核写重叠 %d（10）；抓顶点列举不全 %d（9）；段里无片元写时列举不全 %d（0）",
              ab, hc, mc, hr, hw, hu, eu);
        geo_rg late = {0x9010, 0x9020};
        g_gml_n = 2; g_gml_lo[1] = 0x9000; g_gml_hi[1] = 0x9100;   // 段里前一笔记写之后又学到一个池
        int before = geo_run_hazard_fw(&rs, &late, 1, 1, NULL, 0, 1, NULL, 0, 1);
        geo_gml_snap(); int rf = geo_runset_gml(&rs), after = geo_run_hazard_fw(&rs, &late, 1, 1, NULL, 0, 1, NULL, 0, 1);
        g_gml_over = 1; geo_gml_snap(); int ended = geo_runset_gml(&rs); g_gml_over = 0; geo_gml_snap();
        static geo_runset fa; memset(&fa, 0, sizeof fa); geo_runset_add_fw(&fa, NULL, 0, 0); int fwall = geo_run_hazard_fw(&fa, &cap_miss, 1, 1, NULL, 0, 1, NULL, 0, 1);
        CHECK(before == 0 && rf == 0 && after == 10 && ended == 7 && fwall == 8,
              "⑬ ③ 之后学到的池 [0x9000,0x9100)：补前不撞 %d（0），补进段里记录 %d（0）后撞 %d（10）；预测中途记满 %d（7）；片元写列举不全 %d（8）", before, rf, after, ended, fwall);
        // 预测漏学的事后查：段里有按预测记的写 → 段末把段里列举到的区间交给 g_gsr（本次提交的栅栏）；没有 → 不交；记不下 → 一段包住全部
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); g_gr.rs.gml = 2; geo_runset_note(&g_gr.rs, &cap_miss, 1);
        uint64_t gn = g_gsr_n, fe = g_fence + 1; geo_run_flush();
        int pushed = g_gsr_n == gn + 1 && g_gsr[gn % GSR_N].lo == 0x5100 && g_gsr[gn % GSR_N].hi == 0x5200 && g_gsr[gn % GSR_N].fence == fe;
        geo_run_begin(); geo_runset_note(&g_gr.rs, &cap_miss, 1); gn = g_gsr_n; geo_run_flush(); int none = g_gsr_n == gn;
        geo_run_begin(); g_gr.rs.gml = 1;
        for (int i = 0; i <= GEO_RS_N; i++) { geo_rg y = {0x100000u + (uint64_t)i * 0x100, 0x100000u + (uint64_t)i * 0x100 + 0x10}; geo_runset_note(&g_gr.rs, &y, 1); }
        gn = g_gsr_n; geo_run_flush();
        int box = g_gsr_n == gn + 1 && g_gsr[gn % GSR_N].lo == 0x100000 && g_gsr[gn % GSR_N].hi == 0x100000u + (uint64_t)GEO_RS_N * 0x100 + 0x10;
        finish();
        CHECK(pushed && none && box, "⑬ 段末交给 g_gsr：有按预测记的写交 1 段 [0x5100,0x5200)、本次提交栅栏 %d（期望 1）；没有不交 %d（期望 1）；记满 %d 段退成一段包住全部 %d（期望 1）", pushed, none, GEO_RS_N + 1, box);
        g_gml_on = on0; g_gml_n = n0; g_gml_stable = st0; g_gml_over = ov0; geo_gml_snap();
    }
    // ⑦ 大小没给的可写存储缓冲
    {
        reset_mem(); nvn_be_sub_begin(); bind_tagged(3);
        S.ssbo[5][1] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(mem + 0x8000), .size = 0};   // 输出：大小 0（游戏没给）
        p_dispatch dp7 = {.x = 1, .y = 1, .z = 1}; dispatch(&dp7);
        int over = g_sbw_over, after = sbw_hits((uint64_t)(uintptr_t)(mem + 0xF000), (uint64_t)(uintptr_t)(mem + 0xF010)), before = sbw_hits((uint64_t)(uintptr_t)(mem + 0x1000), (uint64_t)(uintptr_t)(mem + 0x1010));
        finish();
        CHECK(!over && after && !before, "⑦ 大小 0 的可写存储缓冲：整次提交溢出 %d（期望 0），所在缓冲末段 +0xF000 算写过 %d（期望 1），绑定地址之前 +0x1000 不算 %d（期望 0）", over, after, before);
    }
    // ⑧ 帧暂存到切段阈值
    {
        static tex_t rt8; memset(&rt8, 0, sizeof rt8); rt8.magic = MAGIC('T', 'E', 'X', 0); rt8.serial = nvn_new_serial();
        rt8.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA32F, .flags = NVN_TEXTURE_FLAGS_IMAGE, .width = 8, .height = 1, .depth = 1, .levels = 1};
        rt8.pool = pool8; rt8.off = 0xC000; rt8.mem = mem + 0xC000; nvn_tex_layout(&rt8.d, &rt8.L); nvn_be_tex_init(&rt8); REQUIRE(tex_mtl(&rt8));
        reset_mem(); nvn_be_sub_begin(); geo_run_begin(); lane_kernel(1);
        memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &rt8; R.has_rt = 1;
        rec_lane(2); g_game_barrier = 1; rp_begin(); rec_lane(0); REQUIRE(g_enc);   // 段里的主遍：开在道 2
        uint64_t c0 = nvn_be_cut_count(); g_arena_seg = ARENA_CUT / 2; geo_scratch_cut(1, 1024);
        int below = g_gr.active && nvn_be_cut_count() == c0;
        uint64_t e_cut8 = g_gr_end[GEO_END_CUT];
        g_arena_seg = ARENA_CUT; geo_scratch_cut(1, 1024);
        CHECK(g_gr_end[GEO_END_CUT] - e_cut8 == 1 && g_gr_why == 0, "⑧ 切段结束的段记成「切暂存」一次（%llu，期望 1），原因用完清零（%d，期望 0）", (unsigned long long)(g_gr_end[GEO_END_CUT] - e_cut8), g_gr_why);
        int ended = !g_gr.active, cut = nvn_be_cut_count() == c0 + 1, reset = g_arena_seg < ARENA_CUT;
        finish();
        CHECK(below && ended && cut && reset && count() == 1, "⑧ 没到阈值不动（%d，期望 1）；到阈值段结束 %d、切一刀 %d、本段暂存归零 %d（期望 1 1 1），几何核照常执行（计数 %u，期望 1）", below, ended, cut, reset, count());
    }
    // ⑥ 几何变体按程序缓存
    {
        g_geo_lookup = lookup_count;
        NvShader *b1 = [NvShader new]; strlcpy(b1->key, "aaaaaaaaaaaaaaaa_b", sizeof b1->key);
        NvShader *b2 = [NvShader new]; strlcpy(b2->key, "bbbbbbbbbbbbbbbb_b", sizeof b2->key);
        NvProg *p1 = [NvProg new]; NvShader *g, *r, *g0, *r0; int n0;
        atomic_store(&g_depth_zero, 0);
        g_lk = 0; geo_variants(p1, b1, 3, &g0, &r0); int first = g_lk;
        geo_variants(p1, b1, 3, &g, &r); int again = g_lk - first;
        CHECK(first == 2 && again == 0 && g == g0 && r == r0, "⑥ 同一程序同一几何阶段：首次查 %d 次（期望 2），第二次查 %d 次（期望 0），对象相同 %d", first, again, g == g0 && r == r0);
        n0 = g_lk; geo_variants(p1, b1, 1, &g, &r); int topo = g_lk - n0; int topo_key = !strcmp(g_lk_last, "aaaaaaaaaaaaaaaa_bg1");
        n0 = g_lk; atomic_store(&g_depth_zero, 1); geo_variants(p1, b1, 3, &g, &r); int dz = g_lk - n0; int dz_key = !strcmp(g_lk_last, "aaaaaaaaaaaaaaaa_bgv"); atomic_store(&g_depth_zero, 0);
        CHECK(topo == 1 && topo_key && dz == 1 && dz_key, "⑥ 换拓扑只查几何核 %d 次（期望 1，键 _bg1 %d）；换深度模式只查读记录 %d 次（期望 1，键 _bgv %d）", topo, topo_key, dz, dz_key);
        n0 = g_lk; geo_variants(p1, b2, 3, &g, &r); int chg = g_lk - n0; int chg_key = !strcmp(g_lk_last, "bbbbbbbbbbbbbbbb_bgv");
        NvProg *p2 = [NvProg new]; n0 = g_lk; geo_variants(p2, b1, 3, &g, &r); int np2 = g_lk - n0;
        CHECK(chg == 2 && chg_key && g != g0 && np2 == 2, "⑥ 几何阶段换了重查 %d 次（期望 2，查的是新键 %d，拿到新对象 %d）；换程序对象重查 %d 次（期望 2）", chg, chg_key, g != g0, np2);
        NvProg *p3 = [NvProg new]; g_lk_nil = 1; geo_variants(p3, b1, 3, &g, &r); g_lk_nil = 0; n0 = g_lk; geo_variants(p3, b1, 3, &g, &r); int retry = g_lk - n0;
        CHECK(retry == 2 && g && r, "⑥ 查不到的不缓存：下一次再查 %d 次（期望 2），这次拿到 %d", retry, g && r);
        g_geo_lookup = geo_lookup_shader;
    }
    // ⑨ 直通几何快路选择
    {
        g_geo_lookup = lookup_count; g_geo_pt_off = 0; atomic_store(&g_depth_zero, 0);
        NvShader *b = [NvShader new]; strlcpy(b->key, "cccccccccccccccc_b", sizeof b->key);
        NvShader *g3 = [NvShader new]; strlcpy(g3->key, "cccccccccccccccc_bg3", sizeof g3->key); g3->geo_invocations = 1; g3->geo_pt = 1;
        NvShader *rv = [NvShader new]; strlcpy(rv->key, "cccccccccccccccc_bgv", sizeof rv->key);
        NvShader *g, *r; int f;
        g = g3; r = rv; f = geo_pt_pick([NvProg new], b, 0, 1, 3, &g, &r);
        CHECK(f == 1 && !strcmp(g->key, "cccccccccccccccc_bgs3") && !strcmp(r->key, "cccccccccccccccc_bgc"), "⑨ 标直通、单实例、单次调用、三角：走快路 %d（期望 1），几何核 %s（期望 _bgs3）、主遍顶点 %s（期望 _bgc）", f, g->key, r->key);
        g3->geo_pt = 0; g = g3; r = rv; g_lk = 0; f = geo_pt_pick([NvProg new], b, 0, 1, 3, &g, &r); g3->geo_pt = 1;
        CHECK(f == 0 && g_lk == 0 && g == g3 && r == rv, "⑨ 没标直通：走快路 %d（期望 0），查表 %d 次（期望 0），几何核 / 读取器不变 %d", f, g_lk, g == g3 && r == rv);
        int no[5]; g = g3; r = rv;
        no[0] = geo_pt_pick([NvProg new], b, 0, 2, 3, &g, &r);
        no[1] = geo_pt_pick([NvProg new], b, 0, 1, 4, &g, &r);
        no[2] = geo_pt_pick([NvProg new], b, 1, 1, 3, &g, &r);
        g3->geo_invocations = 2; no[3] = geo_pt_pick([NvProg new], b, 0, 1, 3, &g, &r); g3->geo_invocations = 1;
        g_geo_pt_off = 1; no[4] = geo_pt_pick([NvProg new], b, 0, 1, 3, &g, &r); g_geo_pt_off = 0;
        CHECK(!no[0] && !no[1] && !no[2] && !no[3] && !no[4] && g == g3 && r == rv, "⑨ 不走快路：两实例 %d、邻接三角 %d、变换反馈 %d、两次调用 %d、DM_NVN_GEO_PT=0 %d（期望全 0），几何核 / 读取器不变 %d", no[0], no[1], no[2], no[3], no[4], g == g3 && r == rv);
        g_lk_nil = 1; g = g3; r = rv; f = geo_pt_pick([NvProg new], b, 0, 1, 3, &g, &r); g_lk_nil = 0;
        CHECK(f == 0 && g == g3 && r == rv, "⑨ 库里缺 _bgs / _bgc：走快路 %d（期望 0），几何核 / 读取器不变 %d", f, g == g3 && r == rv);
        g_geo_lookup = geo_lookup_shader;
    }
} printf("%s t_nvn_geo_run：%u 项，失败 %u\n", fails ? "✗" : "✓", checks, fails); return fails ? 1 : 0; }
