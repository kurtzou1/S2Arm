// 管线额度（nvn_pso_budget.inc）：常驻管线超过额度时，按最后用到的帧放掉久没用的；预热到额度的 70% 停。
// 期望按语义手写，不由被测实现推出（g_pso 里放假对象，只看表里留谁、计数与对象释放时机）：
//   额度 10（DM_PSO_BUDGET=10），渲染表 12 条：0–9 号最后用在第 0、100 … 900 帧，10、11 号在第 1900、1950 帧；当前第 2000 帧
//   ① 超额：放到 10 × 85% = 8 条 → 放掉最旧的 4 条（0–3 号），留 4–11 号；淘汰计数 4
//   ② 放掉的对象不当场释放（在途命令缓冲可能还引用）：检查后弱引用仍在；等 GPU 那一拍（g_done 推过）后释放
//   ③ 同一帧第二次检查不再动表
//   ④ 计算表里很旧的失败记录（NSNull）不算管线、不放
//   ⑤ 放掉的 0 号又建（插回表）：淘汰后重建计 1
//   ⑥ 全部最近用过：超额也一条都不放
//   ⑦ 预热线：常驻 6 + 已建未领 0 → 不停（6 < 7）；常驻 6 + 已建未领 1 → 停（7 ≥ 10 × 70%）
//   ⑧ DM_PSO_BUDGET=0：不设额度，超多少都不放、预热不停
//   地址额度（#2020；不设 DM_PSO_BUDGET、机型表缺省 0，低区扫描换成桩 fake_holes，每条 256 KB、留 1 GB）：
//   ⑨ 空洞 1 GB + 100 × 256 KB、常驻 12、未领 0 → 额度 112
//   ⑩ 空洞 1 GB − 5 × 256 KB（不到留给别的 1 GB）、常驻 12 条且都在 240 帧外 → 额度停在峰值 12，一条不放（放了地址也收不回，#2218）
//   ⑪ 空洞 1 GB + 10 × 256 KB、常驻 0、未领 6 → 额度 16；预热线 16 × 70% = 11.2：未领 6 不停、未领 12 停
//   ⑫ 显式 DM_PSO_BUDGET=0：地址额度也不看（同空洞的 ⑩ 场景不放）
//   ⑬ 扫不到低区（桩为空）：不设地址额度、不放
//   ⑭ #2218 反馈环：空洞一直 500 MB（被管线以外的吃掉），常驻 12、连采 5 次再连检查：额度一直 12（不随采样往下掉）、一条不放
//   ⑮ 峰值 12、空洞 1 GB + 2 × 256 KB → 额度 14；常驻涨到 20 条且都在 240 帧外 → 放到 14 × 85% = 11 条（取整 11）
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static pso_key key_of(int i) { pso_key k; memset(&k, 0, sizeof k); memcpy(&k, &i, sizeof i); k.cfmt[0] = 0xA5; return k; }
static void put_r(int i, uint64_t frame, __weak id *wr) {
    pso_key k = key_of(i); id o = [NSObject new]; if (wr) *wr = o; hm_put_id(&g_pso, &k, o);
    nvn_hm_put(&g_pb_use_r, &k, (void *)(uintptr_t)(frame + 1));
}
static int has_r(int i) { pso_key k = key_of(i); return hm_get_id(&g_pso, &k) != nil; }
static uint64_t g_fake_t;
static void fake_holes(uint64_t *t, uint64_t *l) { *t = g_fake_t; *l = g_fake_t; }
static void reset_va(uint64_t holes, int have) {   // 地址额度：不设 DM_PSO_BUDGET，换上桩
    nvn_hm_clear(&g_pso, (void (*)(void *))CFRelease); nvn_hm_clear(&g_cps, NULL); nvn_hm_clear(&g_pb_use_r, NULL); nvn_hm_clear(&g_pb_gone_r, NULL);
    g_pb_cfail = 0; unsetenv("DM_PSO_BUDGET"); g_pb_budget_init = 0; g_pb_frame = UINT64_MAX; g_pb_evicted = g_pb_rebuilt = 0; atomic_store(&g_pb_warm_stopped, 0);
    atomic_store(&g_pb_va, 0); atomic_store(&g_pb_unclaimed, 0); atomic_store(&g_pb_live_pub, 0); atomic_store(&g_pb_peak, 0); g_fake_t = holes; g_pb_holes_tried = 1; g_pb_holes_fn = have ? fake_holes : NULL;
}
static void reset(const char *budget) {
    nvn_hm_clear(&g_pso, (void (*)(void *))CFRelease); nvn_hm_clear(&g_cps, NULL); nvn_hm_clear(&g_pb_use_r, NULL); nvn_hm_clear(&g_pb_gone_r, NULL);
    g_pb_cfail = 0; setenv("DM_PSO_BUDGET", budget, 1); g_pb_budget_init = 0; g_pb_frame = UINT64_MAX; g_pb_evicted = g_pb_rebuilt = 0; atomic_store(&g_pb_warm_stopped, 0);
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    mtl_init();
    reset("10");
    __weak id w0 = nil, w1 = nil;
    for (int i = 0; i < 10; i++) put_r(i, (uint64_t)i * 100, i == 0 ? &w0 : i == 1 ? &w1 : NULL);
    put_r(10, 1900, NULL); put_r(11, 1950, NULL);
    { const void *ck = (const void *)(uintptr_t)0x1234; hm_put_id(&g_cps, &ck, NSNull.null); pb_cfail_note(); }   // ④ 计算表一条失败记录（没记过用到 = 0 帧，最旧）
    atomic_store(&g_cur_frame, 2000);
    @autoreleasepool { pb_tick(); }
    int kept = 0, gone_old = 0; for (int i = 4; i < 12; i++) kept += has_r(i); for (int i = 0; i < 4; i++) gone_old += !has_r(i);
    CHECK(gone_old == 4 && kept == 8 && g_pso.n == 8 && g_pb_evicted == 4, "① 超额放到 8 条：0–3 号放掉 %d / 4、4–11 号留下 %d / 8、表里 %u 条（应 8）、淘汰计数 %llu（应 4）",
          gone_old, kept, g_pso.n, (unsigned long long)g_pb_evicted);
    CHECK(w0 != nil && w1 != nil, "② 放掉的对象检查后仍在（等 GPU 用完再放）：0 号 %s、1 号 %s", w0 ? "在" : "已释放", w1 ? "在" : "已释放");
    @autoreleasepool { pb_tick(); }
    CHECK(g_pso.n == 8 && g_pb_evicted == 4, "③ 同一帧再检查不动表：表里 %u 条、淘汰计数 %llu", g_pso.n, (unsigned long long)g_pb_evicted);
    CHECK(g_cps.n == 1, "④ 计算表的失败记录不放：%u 条（应 1）", g_cps.n);
    { pso_key k = key_of(0); id o = [NSObject new]; hm_put_id(&g_pso, &k, o); pb_built_r(&k); }
    CHECK(g_pb_rebuilt == 1, "⑤ 放掉的 0 号又建：淘汰后重建 %llu（应 1）", (unsigned long long)g_pb_rebuilt);
    // ⑥ 全部最近用过
    reset("10");
    for (int i = 0; i < 12; i++) put_r(i, 1800 + (uint64_t)i, NULL);
    atomic_store(&g_cur_frame, 2000);
    @autoreleasepool { pb_tick(); }
    CHECK(g_pso.n == 12 && g_pb_evicted == 0, "⑥ 全部 240 帧内用过：超额也不放（表里 %u 条、淘汰 %llu）", g_pso.n, (unsigned long long)g_pb_evicted);
    // ⑦ 预热线（额度 10 × 70% = 7）
    reset("10"); (void)pb_budget(); atomic_store(&g_pb_live_pub, 6);
    int f0 = pb_warm_full(0), f1 = pb_warm_full(1);
    CHECK(!f0 && f1, "⑦ 预热线：常驻 6 + 未领 0 → %s（应不停）；常驻 6 + 未领 1 → %s（应停）", f0 ? "停" : "不停", f1 ? "停" : "不停");
    // ⑧ 不设额度
    reset("0");
    for (int i = 0; i < 12; i++) put_r(i, 0, NULL);
    atomic_store(&g_cur_frame, 5000); atomic_store(&g_pb_live_pub, 100000);
    @autoreleasepool { pb_tick(); }
    int f8 = pb_warm_full(100000);
    CHECK(g_pso.n == 12 && g_pb_evicted == 0 && !f8, "⑧ DM_PSO_BUDGET=0：不放（表里 %u 条）、预热不停（%s）", g_pso.n, f8 ? "停" : "不停");
    // ② 后半：GPU 那一拍过去后，放掉的对象真的释放
    @autoreleasepool { g_done = g_fence + 2; defer_drain(); }
    CHECK(w0 == nil || w1 == nil, "② GPU 用完后放掉的对象释放：0 号 %s、1 号 %s", w0 ? "在" : "已释放", w1 ? "在" : "已释放");
    // ⑨ 地址额度的数
    reset_va((1024ull << 20) + 100 * (256ull << 10), 1);
    for (int i = 0; i < 12; i++) put_r(i, 0, NULL);
    atomic_store(&g_pb_live_pub, 12); (void)pb_budget(); pb_va_sample();
    CHECK(pb_budget() == 112, "⑨ 空洞 1 GB + 100 条、常驻 12：额度 %u（应 112）", pb_budget());
    // ⑩ 空洞不够：放
    reset_va((1024ull << 20) - 5 * (256ull << 10), 1);
    for (int i = 0; i < 12; i++) put_r(i, (uint64_t)i, NULL);
    atomic_store(&g_pb_live_pub, 12); (void)pb_budget(); pb_va_sample(); atomic_store(&g_cur_frame, 6000);
    @autoreleasepool { pb_tick(); }
    CHECK(pb_budget() == 12 && g_pso.n == 12 && g_pb_evicted == 0, "⑩ 空洞 1 GB − 5 条、常驻 12：额度 %u（应停在峰值 12）、表里 %u（应 12）、淘汰 %llu（应 0）", pb_budget(), g_pso.n, (unsigned long long)g_pb_evicted);
    // ⑪ 预热线按地址额度
    reset_va((1024ull << 20) + 10 * (256ull << 10), 1);
    (void)pb_budget(); atomic_store(&g_pb_unclaimed, 6); pb_va_sample();
    int g6 = pb_warm_full(6), g12 = pb_warm_full(12);
    CHECK(pb_budget() == 16 && !g6 && g12, "⑪ 空洞 1 GB + 10 条、未领 6：额度 %u（应 16）；未领 6 → %s（应不停）、未领 12 → %s（应停）", pb_budget(), g6 ? "停" : "不停", g12 ? "停" : "不停");
    // ⑫ 显式 0：地址额度也不看
    reset_va((1024ull << 20) - 5 * (256ull << 10), 1); setenv("DM_PSO_BUDGET", "0", 1);
    for (int i = 0; i < 12; i++) put_r(i, (uint64_t)i, NULL);
    atomic_store(&g_pb_live_pub, 12); (void)pb_budget(); pb_va_sample(); atomic_store(&g_cur_frame, 7000);
    @autoreleasepool { pb_tick(); }
    CHECK(g_pso.n == 12 && g_pb_evicted == 0, "⑫ DM_PSO_BUDGET=0：同空洞也不放（表里 %u、淘汰 %llu）", g_pso.n, (unsigned long long)g_pb_evicted);
    // ⑬ 扫不到低区
    reset_va((1024ull << 20) - 5 * (256ull << 10), 0);
    for (int i = 0; i < 12; i++) put_r(i, (uint64_t)i, NULL);
    atomic_store(&g_pb_live_pub, 12); (void)pb_budget(); pb_va_sample(); atomic_store(&g_cur_frame, 8000);
    @autoreleasepool { pb_tick(); }
    CHECK(g_pso.n == 12 && g_pb_evicted == 0 && pb_budget() == 0, "⑬ 扫不到低区：不设地址额度（额度 %u、表里 %u、淘汰 %llu）", pb_budget(), g_pso.n, (unsigned long long)g_pb_evicted);
    // ⑭ #2218 反馈环
    reset_va(500ull << 20, 1);
    for (int i = 0; i < 12; i++) put_r(i, (uint64_t)i, NULL);
    atomic_store(&g_pb_live_pub, 12); (void)pb_budget();
    { uint32_t lo = UINT32_MAX;
      for (int r = 0; r < 5; r++) { pb_va_sample(); uint32_t b = pb_budget(); if (b < lo) lo = b; atomic_store(&g_cur_frame, 9000 + (uint64_t)r); @autoreleasepool { pb_tick(); } }
      CHECK(lo == 12 && g_pso.n == 12 && g_pb_evicted == 0, "⑭ 空洞一直 500 MB（管线以外吃的）、连采 5 次：额度最低 %u（应 12，不往下掉）、表里 %u（应 12）、淘汰 %llu（应 0）", lo, g_pso.n, (unsigned long long)g_pb_evicted); }
    // ⑮ 超过峰值 + 余量才放
    reset_va((1024ull << 20) + 2 * (256ull << 10), 1);
    atomic_store(&g_pb_live_pub, 12); (void)pb_budget(); pb_va_sample();
    for (int i = 0; i < 20; i++) put_r(i, (uint64_t)i, NULL);
    atomic_store(&g_cur_frame, 12000);
    @autoreleasepool { pb_tick(); }
    CHECK(pb_budget() >= 14 && g_pso.n == 11 && g_pb_evicted == 9, "⑮ 峰值 12 + 余量 2：额度 %u（应 14）、常驻 20 放后表里 %u（应 11）、淘汰 %llu（应 9）", pb_budget(), g_pso.n, (unsigned long long)g_pb_evicted);
    printf("%s t_nvn_pso_budget：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
} }
