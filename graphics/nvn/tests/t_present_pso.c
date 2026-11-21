// PR3c 出图 PSO 多槽单测（graphics/nvn/gfx/nvn/nvn_present_pso.h——生产代码的同一份纯逻辑；评审稿 v3 §2.2 PSO 缓存接缝 / §3 B3·B4·B5 / §4 PR3c「新单测」行）：
//   槽命中 / 交替不重建 / 失败回退（HDR 槽死负缓存、基线槽不受牵连——「回退基线」的纯逻辑面）/ 四槽上限（gal_present.m g_pr_pso[4] 同数）/ 预热命中断言。
//   三态流（同 t_hdr_layer 口径）：test-only / negctl 态的红由此而来——基线（无 PR3c 实现）上 nvn_present_pso.h 不存在，编译期报 file not found
//   （t_hdr_layer 的链接红同证：红在测实现本身，不在测测试）。纯 C，不要 GPU / 游戏（t_present_fit 同族口径）。
//   期望值全部手推（不跑被测实现）：格式交替两格式并存、互不逐出（修的是「格式交替即重建」——单槽下每交替一次重建一遍，
//   Metal 4 不保留编码器取过的 PSO，重建即释放旧管线、在飞命令缓冲期悬垂，B5）；生产侧把 MTLPixelFormat 的值当不透明槽键
//   （本测取真值：BGRA8Unorm=80 / RGB10A2Unorm=90 / RGBA16Float=105，纯逻辑只比键相等）。
#include "../gfx/nvn/nvn_present_pso.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static int g_bad, g_n, g_builds;   // g_builds：假 build 的调用次数（不重建 / 预热幂等的判据）
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_bad++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)

enum { FMT_BGRA8 = 80, FMT_RGB10A2 = 90, FMT_RGBA16F = 105, FMT_OTHER = 123 };   // 真 MTLPixelFormat 值（不透明键）
static void *fake_build(uint32_t fmt, void *ctx) { (void)fmt; g_builds++; return ctx; }   // ctx 即「建出来的 PSO」
static void *fail_build(uint32_t fmt, void *ctx) { (void)fmt; (void)ctx; g_builds++; return 0; }   // 模拟编译失败

int main(void) {
    // ① 槽命中：填过一次，后续查找全命中同一个 PSO（不重建）
    {   pf_pso_tab t; memset(&t, 0, sizeof t); void *a = (void *)(uintptr_t)0x11, *p = 0;
        CHECK(pf_pso_lookup(&t, FMT_BGRA8, &p) == PF_PSO_MISS, "① BGRA8 未见过 → MISS（要建）");
        CHECK(pf_pso_add(&t, FMT_BGRA8, a), "① 首填入槽");
        CHECK(pf_pso_lookup(&t, FMT_BGRA8, &p) == PF_PSO_HIT && p == a, "① 命中返回同一个 PSO");
        CHECK(pf_pso_lookup(&t, FMT_BGRA8, &p) == PF_PSO_HIT && p == a, "① 再查仍命中（不重建）"); }

    // ② 交替不重建（PR3c 修的现场：层持 PQ 后抗锯齿中间图（BGRA8）与 PQ 层 drawable（RGB10A2）一帧内交替、
    //    截图 BGRA8 与 HDR 层帧间交替——单槽下每交替一次重建一遍）：两格式都入槽后任意混查全命中
    {   pf_pso_tab t; memset(&t, 0, sizeof t); void *b = (void *)(uintptr_t)0x22, *r = (void *)(uintptr_t)0x33, *p = 0;
        CHECK(pf_pso_add(&t, FMT_BGRA8, b) && pf_pso_add(&t, FMT_RGB10A2, r), "② 两格式并存入槽");
        for (int i = 0; i < 10; i++) {
            int pq = i % 2;
            CHECK(pf_pso_lookup(&t, pq ? FMT_RGB10A2 : FMT_BGRA8, &p) == PF_PSO_HIT && p == (pq ? r : b), "② 交替第 %d 查命中（不重建）", i);
        } }

    // ③ 失败回退（B4 语义）：HDR 槽（PQ 层目标）建不出 → 死槽负缓存（此后查找恒 DEAD、不逐帧重试——每帧重试会把一次性失败变逐帧卡顿）；
    //    基线槽不受死 HDR 槽牵连（查照常命中——「回退基线」的纯逻辑面：SDR 路径照走）；重建成翻身；首建即败的格式也进负缓存。
    //    平台侧口径（nvn_mtl.m present_pso_build）：基线槽建不出照旧 MDIE（现状语义不动），只有 HDR 槽走死槽 + 红日志
    {   pf_pso_tab t; memset(&t, 0, sizeof t); void *b = (void *)(uintptr_t)0x44, *p = 0;
        CHECK(pf_pso_add(&t, FMT_BGRA8, b), "③ 基线槽入槽");
        pf_pso_dead(&t, FMT_RGB10A2);
        CHECK(pf_pso_lookup(&t, FMT_RGB10A2, &p) == PF_PSO_DEAD, "③ 死槽返回 DEAD（负缓存）");
        CHECK(pf_pso_lookup(&t, FMT_RGB10A2, &p) == PF_PSO_DEAD, "③ 仍 DEAD（不逐帧重试）");
        CHECK(pf_pso_lookup(&t, FMT_BGRA8, &p) == PF_PSO_HIT && p == b, "③ 基线槽不被死 HDR 槽拖垮（回退的基线照走）");
        CHECK(pf_pso_add(&t, FMT_RGB10A2, (void *)(uintptr_t)0x55), "③ 死槽重建成翻身（再入槽）");
        CHECK(pf_pso_lookup(&t, FMT_RGB10A2, &p) == PF_PSO_HIT && p == (void *)(uintptr_t)0x55, "③ 翻身后命中");
        pf_pso_dead(&t, FMT_RGBA16F);   // 没进过表的格式首建即败：也登记
        CHECK(pf_pso_lookup(&t, FMT_RGBA16F, &p) == PF_PSO_DEAD, "③ 首建即败也进负缓存"); }

    // ④ 四槽上限（gal_present.m g_pr_pso[4] 同数：S0/S1 层两格式 + 截图 / 中间格式余量）：第 5 种格式不入槽
    //    （返回 0——gal_present.m 四槽同款处置：调用方红一次、本格式不出图），先入的 4 槽不被逐出
    {   pf_pso_tab t; memset(&t, 0, sizeof t); void *p = 0;
        for (uint32_t i = 0; i < PF_PSO_SLOTS; i++) CHECK(pf_pso_add(&t, 200 + i, (void *)(uintptr_t)(0x100 + i)), "④ 第 %u 槽入槽", i);
        CHECK(!pf_pso_add(&t, FMT_OTHER, (void *)(uintptr_t)0x999), "④ 满表：第 5 种格式不入槽");
        CHECK(pf_pso_lookup(&t, 202, &p) == PF_PSO_HIT && p == (void *)(uintptr_t)0x102, "④ 满 4 槽后先入的槽不被逐出"); }

    // ⑤ 预热命中断言（启动预热候选组合，T11 首帧 / 首切换无编译卡顿）：预热后候选查找全命中（零新建）；
    //    预热幂等（重复预热零新建）；建不出的候选不入槽（调用方处置：基线 MDIE / HDR 负缓存——纯逻辑层不管失败语义）
    {   pf_pso_tab t; memset(&t, 0, sizeof t); void *p = 0;
        uint32_t cand[2] = { FMT_BGRA8, FMT_RGB10A2 };   // 候选组合：基线 BGRA8 + PQ 层 RGB10A2（生产侧 off 时只热基线）
        int added = pf_pso_warm(&t, cand, 2, fake_build, (void *)(uintptr_t)0x77);
        CHECK(added == 2 && g_builds == 2, "⑤ 预热每候选恰建一次（入 %d、建 %d）", added, g_builds);
        g_builds = 0;
        CHECK(pf_pso_warm(&t, cand, 2, fake_build, (void *)(uintptr_t)0x77) == 0 && g_builds == 0, "⑤ 预热幂等（重复预热零新建）");
        CHECK(pf_pso_lookup(&t, FMT_BGRA8, &p) == PF_PSO_HIT && p == (void *)(uintptr_t)0x77, "⑤ 预热后基线命中（首帧无编译卡顿）");
        CHECK(pf_pso_lookup(&t, FMT_RGB10A2, &p) == PF_PSO_HIT && p == (void *)(uintptr_t)0x77, "⑤ 预热后 PQ 层目标命中（首切换无编译卡顿）");
        g_builds = 0;
        uint32_t failcand[1] = { FMT_OTHER };
        CHECK(pf_pso_warm(&t, failcand, 1, fail_build, 0) == 0 && g_builds == 1 && pf_pso_lookup(&t, FMT_OTHER, &p) == PF_PSO_MISS,
              "⑤ 建不出的候选不入槽（失败语义归调用方）"); }

    if (g_bad) printf("✗ t_present_pso：%d / %d 项不通\n", g_bad, g_n);
    else printf("✓ t_present_pso：全部通过（%d 项）\n", g_n);
    return g_bad != 0;
}
