// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 管线额度（11-22）：Apple GPU 驱动对一个进程里常驻的已编译管线变体有总额度，超了先报「AGX: exceeded compiled variants footprint limit」，
//   之后建管线失败（Internal error during function compilation）、再 bad_alloc / dispatch 空指针把宿主带崩。玩家诊断 40 张卡出现这句、21 张随后崩
//   （0400486024DEC000 21 张、0100F2C0115B6000 8、01007EF00011E000 6 等；iPhone16/18、iPad13/15/16 都有）。离线读数：报错一律在本局累计建造 ≥ 8192 条之后，
//   与管线归档体积（0–3.5 GB，含 0 条全现编的局）、机型内存（7.6–16 GB）都看不出关系 —— 按常驻条数算。
// 原先三张管线表（g_pso 渲染、g_cps / g_cps_se 计算）从不淘汰，预热（pso_user.tsv 记的本机用过的全部）全建全留，归档越攒越大、越玩越容易撞。
// 这里：
//   ① 常驻条数 = 三张表的条目数减去计算表的失败记录（提交线程上精确；预热线程读 g_pb_live_pub + 预热已建未领的条数）
//   ② 每条记最后用到的帧（查表命中、插入时记）；提交线程每帧第一次查表时检查：超过额度就把 PB_KEEP_FRAMES 帧内没用过的按最旧先放，放到额度的 PB_LOW_PCT %；
//      放掉的对象等 GPU 用完再释放（defer_obj_release）。放掉的键记下来，之后又建 = 「淘汰后重建」（首遇代价，按 #2044 口径看首遇长帧）
//   ③ 预热按额度装：常驻到额度的 PB_WARM_PCT % 停止预热（剩下的照旧首遇时建），给游戏里的首遇留余量
//   ④ 额度按机型实测（pb_table），未知机型用缺省；DM_PSO_BUDGET=<条数> 覆盖、0 = 不设额度（不淘汰、预热不停，同改前）
// 由 nvn_mtl.m 在 g_cps / g_cps_se 之后包含；渲染那半在 pso_get_vs_ptr 之前已前向声明（pb_touch_r / pb_tick）
#define PB_KEEP_FRAMES 240   // 这么多帧内用过的不放（约 4–8 秒；在途命令缓冲最多几帧）
#define PB_LOW_PCT 85        // 超额时放到额度的这个比例
#define PB_WARM_PCT 70       // 预热到额度的这个比例就停
// 机型 → 额度（条）。按机型实测（真机逐级实验：额度跟常驻条数 / 装过的总量 / 归档体积哪个有关、各机型阈值、淘汰后首遇长帧按 #2044 口径），
//   实测后在这里加行，前缀匹配（hw.machine / Mac hw.model），先列的先匹配。实测前缺省 0 = 不设额度（行为同改前）：拍一个数会让预热清单大的游戏
//   （0100F2C0115B6000 2.6 万行）提前停预热、首遇变多，没有读数撑不能上；实验用 DM_PSO_BUDGET=<条数> 指定
static const struct { const char *prefix; uint32_t budget; } pb_table[] = {
    {"", 0},   // 缺省：实测前不设
};
static uint32_t g_pb_budget_v; static int g_pb_budget_init;
static uint32_t pb_budget(void) {
    if (g_pb_budget_init) return g_pb_budget_v;
    g_pb_budget_init = 1;
    const char *e = getenv("DM_PSO_BUDGET");
    char model[64] = "?"; size_t l = sizeof model;
    if (sysctlbyname(TARGET_OS_IPHONE ? "hw.machine" : "hw.model", model, &l, NULL, 0)) snprintf(model, sizeof model, "?");
    if (e && *e) g_pb_budget_v = (uint32_t)strtoul(e, NULL, 10);
    else for (size_t i = 0; i < sizeof pb_table / sizeof *pb_table; i++) if (!strncmp(model, pb_table[i].prefix, strlen(pb_table[i].prefix))) { g_pb_budget_v = pb_table[i].budget; break; }
    MLOG("pipeline budget: %u pipelines resident (%s; machine %s; 0 = no budget)", g_pb_budget_v, e && *e ? "DM_PSO_BUDGET" : "per-model table", model);
    return g_pb_budget_v;
}
// 最后用到的帧 + 1（0 = 空槽，nvn_hmap 的约定），与三张表同键
static nvn_hmap g_pb_use_r = {.klen = sizeof(pso_key)}, g_pb_use_c = {.klen = sizeof(void *)}, g_pb_use_s = {.klen = sizeof(cps_se_key)};
static nvn_hmap g_pb_gone_r = {.klen = sizeof(pso_key)}, g_pb_gone_c = {.klen = sizeof(void *)}, g_pb_gone_s = {.klen = sizeof(cps_se_key)};   // 放掉过的键
static uint64_t g_pb_evicted, g_pb_rebuilt, g_pb_ticks_over; static _Atomic uint32_t g_pb_live_pub; static _Atomic uint64_t g_pb_warm_stopped;
static uint64_t g_pb_frame = UINT64_MAX;
static inline void pb_touch(nvn_hmap *use, const void *k) { nvn_hm_put(use, k, (void *)(uintptr_t)(atomic_load(&g_cur_frame) + 1)); }
static inline void pb_built(nvn_hmap *use, nvn_hmap *gone, const void *k) {   // 刚插进表：记用到；放掉过的又建了 = 淘汰后重建
    pb_touch(use, k);
    if (gone->n && nvn_hm_del(gone, k)) g_pb_rebuilt++;
}
static void pb_touch_r(const pso_key *k) { pb_touch(&g_pb_use_r, k); }
static void pb_built_r(const pso_key *k) { pb_built(&g_pb_use_r, &g_pb_gone_r, k); }
static uint32_t g_pb_cfail;   // 计算表里的失败记录（NSNull）条数：不是管线、不占额度（pb_cfail_note，失败记录永不删）
static void pb_cfail_note(void) { g_pb_cfail++; }
static uint32_t pb_live(void) { return g_pso.n + g_cps.n + g_cps_se.n - g_pb_cfail; }
// 一张表里挑可放的：最后用到早于 now − PB_KEEP_FRAMES 的（没记过用到的也算：只当 0 帧），按帧从旧到新
typedef struct { uint64_t at; nvn_hmap *tab, *use, *gone; uint32_t slot; } pb_cand;
static int pb_cand_cmp(const void *a, const void *b) { uint64_t x = ((const pb_cand *)a)->at, y = ((const pb_cand *)b)->at; return x < y ? -1 : x > y; }
static void pb_collect(nvn_hmap *tab, nvn_hmap *use, nvn_hmap *gone, uint64_t now, pb_cand **v, size_t *n, size_t *cap) {
    for (uint32_t i = 0; i < tab->cap; i++) {
        if (!tab->vals[i] || tab->vals[i] == (__bridge void *)NSNull.null) continue;   // NSNull：失败记录，不是管线
        const void *k = tab->keys + (size_t)i * tab->klen; uintptr_t u = (uintptr_t)nvn_hm_get(use, k); uint64_t at = u ? u - 1 : 0;
        if (at + PB_KEEP_FRAMES > now) continue;
        if (*n == *cap) { *cap = *cap ? *cap * 2 : 1024; *v = realloc(*v, *cap * sizeof **v); }
        (*v)[(*n)++] = (pb_cand){at, tab, use, gone, i};
    }
}
// 提交线程：帧变了就检查一次；超额按最旧先放
static void pb_tick(void) {
    uint64_t now = atomic_load(&g_cur_frame);
    if (now == g_pb_frame) return;
    g_pb_frame = now;
    uint32_t budget = pb_budget(), live = pb_live(); atomic_store(&g_pb_live_pub, live);
    if (!budget || live <= budget) return;
    g_pb_ticks_over++;
    uint32_t low = (uint32_t)((uint64_t)budget * PB_LOW_PCT / 100), drop = live - low;
    pb_cand *v = NULL; size_t n = 0, cap = 0;
    pb_collect(&g_pso, &g_pb_use_r, &g_pb_gone_r, now, &v, &n, &cap);
    pb_collect(&g_cps, &g_pb_use_c, &g_pb_gone_c, now, &v, &n, &cap);
    pb_collect(&g_cps_se, &g_pb_use_s, &g_pb_gone_s, now, &v, &n, &cap);
    qsort(v, n, sizeof *v, pb_cand_cmp);
    // 先拷键再删：删除会挪动表里后面的条目（开放寻址），槽号只在删之前有效
    size_t take = n < drop ? n : drop; uint8_t *keys = take ? malloc(take * sizeof(pso_key)) : NULL;
    for (size_t i = 0; i < take; i++) memcpy(keys + i * sizeof(pso_key), v[i].tab->keys + (size_t)v[i].slot * v[i].tab->klen, v[i].tab->klen);
    for (size_t i = 0; i < take; i++) {
        const void *k = keys + i * sizeof(pso_key);
        void *obj = nvn_hm_del(v[i].tab, k); nvn_hm_del(v[i].use, k);
        if (!obj) continue;
        nvn_hm_put(v[i].gone, k, (void *)1);
        defer_obj_release((__bridge_transfer id)obj);   // 表里持的那一份：等 GPU 用完再放（在途命令缓冲可能还引用它）
        g_pb_evicted++;
    }
    free(keys); free(v);
    uint32_t after = pb_live(); atomic_store(&g_pb_live_pub, after);
    if (g_pb_ticks_over <= 8 || !(g_pb_ticks_over & (g_pb_ticks_over - 1)))
        MLOG("pipeline budget: %u resident over the budget %u at frame %llu: released %zu not used in the last %d frames (%zu could be), now %u; so far released %llu, built again after release %llu, prewarm lines stopped by the budget %llu",
             live, budget, (unsigned long long)now, take, PB_KEEP_FRAMES, n, after, (unsigned long long)g_pb_evicted, (unsigned long long)g_pb_rebuilt, (unsigned long long)atomic_load(&g_pb_warm_stopped));
    if (take < drop) { static int warned; if (!warned++) MLOG("【黄】 pipeline budget: %u resident, all but %zu used in the last %d frames: nothing more to release (the game uses more pipelines at once than the budget)", after, n, PB_KEEP_FRAMES); }
}
// 预热线程：再建一条会不会超过预热线（常驻 + 预热已建还没被领走的）
static int pb_warm_full(uint64_t built_unclaimed) {
    uint32_t budget = pb_budget();
    if (!budget) return 0;
    uint64_t est = atomic_load(&g_pb_live_pub) + built_unclaimed;
    if (est * 100 < (uint64_t)budget * PB_WARM_PCT) return 0;
    if (!atomic_fetch_add(&g_pb_warm_stopped, 1)) MLOG("pipeline budget: the prewarm stops at %llu pipelines (%d%% of the budget %u); the rest are built at their first use", (unsigned long long)est, PB_WARM_PCT, budget);
    return 1;
}
