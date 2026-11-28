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
//   ④ 额度按机型实测（pb_table），未知机型用缺省；DM_PSO_BUDGET=<条数> 覆盖、0 = 不设额度（不淘汰、预热不停，同改前；也不看下面的地址额度）
//   ⑤ 地址额度（#2020，11-24）：每条活着的管线占宿主低区约 256 KB 地址（本机实测现编 / 存档取一样 240–316 KB；iPad M5 上 0400486024DEC000 一局预热全建全留约 2.5 万条，
//      C# 初始化后低区空洞 6643 MB → 448 MB，各处分配失败、在 nvn_hm_grow / nvn_ft_poll 里 abort）。放掉的管线地址不还给系统，但新建的管线会接着用它
//      （本机：放掉 300 条再建 300 条只多 7–11 MB），所以按条数封顶就封住了地址。后台每秒扫一次低区空洞 T，
//      地址额度 = 峰值 + max(0, T − PB_VA_RESERVE) ÷ PB_VA_PER；峰值 = 本局活着的条数（常驻 + 预热已建未领）到过的最大值。与机型额度取严的那个。
//      为什么按峰值而不按此刻活着的条数（#2218，11-25 M1 Pro 时之笛：额度 9407 → 3732 → 1，放掉 9806 条，常驻只剩 3 条、低区仍 702 → 36 MB）：
//      放掉的管线地址不还系统，放到峰值以下一分地址也收不回；低区被管线以外的分配（Metal 内部 / malloc / 运行时）吃掉时，按此刻条数算的额度
//      会低于活着的条数 → 放 → T 不回升 → 额度更低 …一直放一直重建。按峰值：空洞不够只是不再长（额度停在峰值、预热到线停），
//      已建的照留；超过「峰值 + 余量」的新管线才按最久没用放，放出的地址给新管线接着用，管线占的地址封在峰值
//      扫不到（单测 / 回放不链原生层）= 不设地址额度
//      只在 iOS / iPadOS 上设（#2218，11-25）：低区耗尽而崩只在 iPhone / iPad 上出现（#2020）；Mac 上低区被 Metal 内部与 malloc 吃到几十 MB 是常态，
//      游戏照常运行（M1 Pro 时之笛不设额度一局低区 21 MB 正常退出），设了反而预热停在 70%、读区域那帧多现建 80 条、长约 470 ms
//   ⑥ 混合管线的拉取基础管线（g_pbase，nvn_hybrid.inc）也是活着的管线：计入常驻条数，超额时与三张表一起按最久没用先放（在 g_pbase_lock 下）；
//      放掉的那一对下次首遇照旧在后台重建。预热时 / 登记时先取基础管线到预热线就停（pb_prefetch_full），不为先取占掉游戏首遇要用的额度
//   ⑦ 网格管线（g_pso_mtk，nvn_geometry.inc）同样计入常驻条数、超额时一起按最久没用先放（在 g_pso_mtk_lock 下；在建占位、拒建记录不算也不放）。
//      放掉时一并从首画记录 g_mtk_drawn 与名字表 g_mtk_names 里去掉（两处都强引用管线，不去掉对象放不掉）；下次首遇照旧在后台重建
// 由 nvn_mtl.m 在 g_cps / g_cps_se 之后包含；渲染那半在 pso_get_vs_ptr 之前已前向声明（pb_touch_r / pb_tick）
#define PB_KEEP_FRAMES 240   // 这么多帧内用过的不放（约 4–8 秒；在途命令缓冲最多几帧）
#define PB_LOW_PCT 85        // 超额时放到额度的这个比例
#define PB_WARM_PCT 70       // 预热到额度的这个比例就停
#define PB_VA_PER (256ull << 10)        // 每条活着的管线占的宿主低区地址（实测 240–316 KB，iPad 一局 6.2 GB ÷ 2.5 万条 ≈ 248 KB）
#define PB_VA_RESERVE PB_LOW_KEEP   // 低区空洞留给管线以外的（线程栈、Metal ≤256 MB 缓冲、视频解码、C#）：崩溃那局分配失败出现在空洞 865–448 MB
// 机型 → 额度（条）。按机型实测（真机逐级实验：额度跟常驻条数 / 装过的总量 / 归档体积哪个有关、各机型阈值、淘汰后首遇长帧按 #2044 口径），
//   实测后在这里加行，前缀匹配（hw.machine / Mac hw.model），先列的先匹配。实测前缺省 0 = 不设额度（行为同改前）：拍一个数会让预热清单大的游戏
//   （0100F2C0115B6000 2.6 万行）提前停预热、首遇变多，没有读数撑不能上；实验用 DM_PSO_BUDGET=<条数> 指定
//   D-EH7W（11-26，iPhone 17 Pro Max 真机）：「AGX: exceeded compiled variants footprint limit」按本局累计建过的条数算（档案取出的也算），不按常驻——
//   预热建好即丢（常驻 100、已释放 13567 条）照样在累计 13312–13568 之间报，与全建全留同点；放掉的变体驱动不回收，所以按常驻设额度挡不住这句，
//   淘汰后重建反而让累计涨得更快。这句本身不致命（之后又建约 1 万条 0 失败、建造速度与内存斜率不变）；同期玩家卡的崩溃是低区地址耗尽（⑤ 管）
static const struct { const char *prefix; uint32_t budget; } pb_table[] = {
    {"", 0},   // 缺省：实测前不设
};
static uint32_t g_pb_budget_v; static int g_pb_budget_init, g_pb_env;
static _Atomic uint32_t g_pb_live_pub, g_pb_va, g_pb_peak; static _Atomic uint64_t g_pb_unclaimed, g_pb_va_holes;   // g_pb_va：地址额度，0 = 不设；g_pb_peak：活着条数的峰值
// ⑥ g_pb_bases = g_pbase 里真管线的条数；g_pb_bases_pub = 发布 g_pb_live_pub 那一刻的 g_pb_bases。发布之后新放的（第一帧之前预热工人就在放）要另外补上
static _Atomic uint32_t g_pb_bases, g_pb_bases_pub;
static uint32_t pb_bases_since_pub(void) { uint32_t nb = atomic_load(&g_pb_bases), nb0 = atomic_load(&g_pb_bases_pub); return nb > nb0 ? nb - nb0 : 0; }
static void (*g_pb_holes_fn)(uint64_t *total, uint64_t *largest);   // 原生层 s2a_low_holes（runtime/src/vawin.c），运行时取
static int g_pb_holes_tried;   // 取过了（取不到 = 不设地址额度；单测直接置位、自己给桩）
// 地址额度（⑤）：由一次扫描的空洞 T 与此刻活着的条数算
static void pb_peak_note(uint64_t alive) { uint32_t a = alive > UINT32_MAX ? UINT32_MAX : (uint32_t)alive, p = atomic_load(&g_pb_peak); while (a > p && !atomic_compare_exchange_weak(&g_pb_peak, &p, a)) {} }
// 别处从低区拿地址的大块（#2306 热贴图预建）按同一口径让路：最近一次扫到的空洞 T 扣掉 PB_VA_RESERVE 放不下 sz 就不建；T = 0（没扫到：Mac / 单测不链原生层）= 不拦
static uint64_t pb_low_holes(void) { return atomic_load(&g_pb_va_holes); }
static int pb_low_room(uint64_t sz) { uint64_t t = pb_low_holes(); return !t || (t > PB_VA_RESERVE && t - PB_VA_RESERVE >= sz); }
static uint32_t pb_va_from(uint64_t holes, uint64_t alive) {
    pb_peak_note(alive);
    int64_t room = (int64_t)holes - (int64_t)PB_VA_RESERVE, b = (int64_t)atomic_load(&g_pb_peak) + (room > 0 ? room / (int64_t)PB_VA_PER : 0);
    return b < 1 ? 1 : b > (int64_t)UINT32_MAX ? UINT32_MAX : (uint32_t)b;
}
static void pb_va_sample(void) {
    if (!g_pb_holes_fn) return;
    uint64_t t = 0, l = 0; g_pb_holes_fn(&t, &l);
    uint32_t va = pb_va_from(t, (uint64_t)atomic_load(&g_pb_live_pub) + atomic_load(&g_pb_unclaimed) + pb_bases_since_pub());
    uint32_t old = atomic_exchange(&g_pb_va, va); atomic_store(&g_pb_va_holes, t);
    if (!old) MLOG("pipeline budget: host low addresses %llu MB free (largest %llu MB) → room for %u pipelines resident in all (%llu KB each, %llu MB kept for the rest)",
                   (unsigned long long)(t >> 20), (unsigned long long)(l >> 20), va, (unsigned long long)(PB_VA_PER >> 10), (unsigned long long)(PB_VA_RESERVE >> 20));
}
static uint32_t pb_budget(void) {
    if (g_pb_budget_init) {
        uint32_t va = g_pb_env ? 0 : atomic_load(&g_pb_va);
        return !va ? g_pb_budget_v : !g_pb_budget_v ? va : va < g_pb_budget_v ? va : g_pb_budget_v;
    }
    g_pb_budget_init = 1;
    const char *e = getenv("DM_PSO_BUDGET");
    char model[64] = "?"; size_t l = sizeof model;
    if (sysctlbyname(TARGET_OS_IPHONE ? "hw.machine" : "hw.model", model, &l, NULL, 0)) snprintf(model, sizeof model, "?");
    if (e && *e) g_pb_budget_v = (uint32_t)strtoul(e, NULL, 10);
    else for (size_t i = 0; i < sizeof pb_table / sizeof *pb_table; i++) if (!strncmp(model, pb_table[i].prefix, strlen(pb_table[i].prefix))) { g_pb_budget_v = pb_table[i].budget; break; }
    g_pb_env = e && *e;
    MLOG("pipeline budget: %u pipelines resident (%s; machine %s; 0 = no budget)%s", g_pb_budget_v, g_pb_env ? "DM_PSO_BUDGET" : "per-model table", model,
         g_pb_env ? "; the host-address budget is off" : TARGET_OS_IPHONE ? "; the host-address budget follows" : "; no host-address budget on macOS");
    if (!g_pb_env) {   // ⑤：开局同步扫一次（预热要用），之后后台每秒一次；Mac 不取（见头注 ⑤ 末段），单测自己置 g_pb_holes_tried + 桩
        if (!g_pb_holes_tried) { g_pb_holes_tried = 1; if (TARGET_OS_IPHONE) g_pb_holes_fn = (void (*)(uint64_t *, uint64_t *))dlsym(RTLD_DEFAULT, "s2a_low_holes"); }
        if (g_pb_holes_fn) {
            pb_va_sample();
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
            dispatch_source_set_event_handler(t, ^{ pb_va_sample(); });
            dispatch_resume(t); static dispatch_source_t keep; keep = t;
        }
    }
    return pb_budget();
}
// 最后用到的帧 + 1（0 = 空槽，nvn_hmap 的约定），与三张表同键
static nvn_hmap g_pb_use_r = {.klen = sizeof(pso_key)}, g_pb_use_c = {.klen = sizeof(void *)}, g_pb_use_s = {.klen = sizeof(cps_se_key)};
static nvn_hmap g_pb_gone_r = {.klen = sizeof(pso_key)}, g_pb_gone_c = {.klen = sizeof(void *)}, g_pb_gone_s = {.klen = sizeof(cps_se_key)};   // 放掉过的键
static uint64_t g_pb_evicted, g_pb_rebuilt, g_pb_ticks_over; static _Atomic uint64_t g_pb_warm_stopped;
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
// ⑥ g_pbase 的用到帧 / 放掉过的键（g_pbase_lock 下）；g_pb_bases = 里面真管线的条数（不含 NSNull 占位 / 失败）
static nvn_hmap g_pb_use_b = {.klen = sizeof(pbase_key)}, g_pb_gone_b = {.klen = sizeof(pbase_key)};
#define PB_KMAX sizeof(mtk_key)   // pb_tick 拷键的槽宽：各表键里最长的
_Static_assert(sizeof(pbase_key) <= PB_KMAX && sizeof(cps_se_key) <= PB_KMAX && sizeof(pso_key) <= PB_KMAX, "pb_tick copies keys into PB_KMAX-sized slots");
static void pb_base_put_locked(const pbase_key *bk, id ps) {
    id old = hm_get_id(&g_pbase, bk);
    if (!old || old == NSNull.null) atomic_fetch_add(&g_pb_bases, 1);
    hm_put_id(&g_pbase, bk, ps); pb_built(&g_pb_use_b, &g_pb_gone_b, bk);
}
static void pb_base_touch_locked(const pbase_key *bk) { pb_touch(&g_pb_use_b, bk); }
// ⑦ g_pso_mtk 的用到帧 / 放掉过的键（g_pso_mtk_lock 下；mtk_put_locked / mtk_pso 调）
static nvn_hmap g_pb_use_m = {.klen = sizeof(mtk_key)}, g_pb_gone_m = {.klen = sizeof(mtk_key)};
static void pb_built_m(const mtk_key *k) { pb_built(&g_pb_use_m, &g_pb_gone_m, k); }
static void pb_touch_m(const mtk_key *k) { pb_touch(&g_pb_use_m, k); }
static uint32_t pb_live(void) { return g_pso.n + g_cps.n + g_cps_se.n - g_pb_cfail + atomic_load(&g_pb_bases) + atomic_load(&g_pb_mtk); }
static void pb_live_publish(uint32_t live) { atomic_store(&g_pb_bases_pub, atomic_load(&g_pb_bases)); atomic_store(&g_pb_live_pub, live); }
// 一张表里挑可放的：最后用到早于 now − PB_KEEP_FRAMES 的（没记过用到的也算：只当 0 帧），按帧从旧到新
typedef struct { uint64_t at; nvn_hmap *tab, *use, *gone; uint32_t slot; } pb_cand;
static int pb_cand_cmp(const void *a, const void *b) { uint64_t x = ((const pb_cand *)a)->at, y = ((const pb_cand *)b)->at; return x < y ? -1 : x > y; }
static void pb_collect(nvn_hmap *tab, nvn_hmap *use, nvn_hmap *gone, uint64_t now, pb_cand **v, size_t *n, size_t *cap) {
    for (uint32_t i = 0; i < tab->cap; i++) {
        if (!tab->vals[i] || tab->vals[i] == (__bridge void *)NSNull.null || tab->vals[i] == (__bridge void *)g_pso_mtk_building) continue;   // NSNull：失败记录；网格表的在建占位：都不是管线
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
    uint32_t budget = pb_budget(), live = pb_live(); pb_live_publish(live);
    if (!budget || live <= budget) return;
    g_pb_ticks_over++;
    uint32_t low = (uint32_t)((uint64_t)budget * PB_LOW_PCT / 100), drop = live - low;
    pb_cand *v = NULL; size_t n = 0, cap = 0;
    os_unfair_lock_lock(&g_pbase_lock);   // ⑥：后台会往 g_pbase 里放（会挪槽号），挑与放都在锁里
    os_unfair_lock_lock(&g_pso_mtk_lock);   // ⑦：网格表同理（后台建好就放）；取锁顺序 g_pbase_lock → g_pso_mtk_lock，两边别处都不嵌套取另一把
    pb_collect(&g_pso_mtk, &g_pb_use_m, &g_pb_gone_m, now, &v, &n, &cap);
    pb_collect(&g_pbase, &g_pb_use_b, &g_pb_gone_b, now, &v, &n, &cap);
    pb_collect(&g_pso, &g_pb_use_r, &g_pb_gone_r, now, &v, &n, &cap);
    pb_collect(&g_cps, &g_pb_use_c, &g_pb_gone_c, now, &v, &n, &cap);
    pb_collect(&g_cps_se, &g_pb_use_s, &g_pb_gone_s, now, &v, &n, &cap);
    qsort(v, n, sizeof *v, pb_cand_cmp);
    // 先拷键再删：删除会挪动表里后面的条目（开放寻址），槽号只在删之前有效
    size_t take = n < drop ? n : drop; uint8_t *keys = take ? malloc(take * PB_KMAX) : NULL;
    for (size_t i = 0; i < take; i++) memcpy(keys + i * PB_KMAX, v[i].tab->keys + (size_t)v[i].slot * v[i].tab->klen, v[i].tab->klen);
    for (size_t i = 0; i < take; i++) {
        const void *k = keys + i * PB_KMAX;
        void *obj = nvn_hm_del(v[i].tab, k); nvn_hm_del(v[i].use, k);
        if (!obj) continue;
        nvn_hm_put(v[i].gone, k, (void *)1);
        if (v[i].tab == &g_pbase) atomic_fetch_sub(&g_pb_bases, 1);
        if (v[i].tab == &g_pso_mtk) { atomic_fetch_sub(&g_pb_mtk, 1); id o = (__bridge id)obj; [g_mtk_names removeObjectForKey:o]; [g_mtk_drawn removeObject:o]; }   // ⑦：这两处也强引用它
        defer_obj_release((__bridge_transfer id)obj);   // 表里持的那一份：等 GPU 用完再放（在途命令缓冲可能还引用它）
        g_pb_evicted++;
    }
    os_unfair_lock_unlock(&g_pso_mtk_lock);
    os_unfair_lock_unlock(&g_pbase_lock);
    free(keys); free(v);
    uint32_t after = pb_live(); pb_live_publish(after);
    if (g_pb_ticks_over <= 8 || !(g_pb_ticks_over & (g_pb_ticks_over - 1)))
        MLOG("pipeline budget: %u resident over the budget %u at frame %llu: released %zu not used in the last %d frames (%zu could be), now %u; so far released %llu, built again after release %llu, prewarm lines stopped by the budget %llu",
             live, budget, (unsigned long long)now, take, PB_KEEP_FRAMES, n, after, (unsigned long long)g_pb_evicted, (unsigned long long)g_pb_rebuilt, (unsigned long long)atomic_load(&g_pb_warm_stopped));
    if (take < drop) { static int warned; if (!warned++) MLOG("【黄】 pipeline budget: %u resident, all but %zu used in the last %d frames: nothing more to release (the game uses more pipelines at once than the budget)", after, n, PB_KEEP_FRAMES); }
}
// 管线占用诊断（D-EH7W，11-26）：累计建造每满 256 条打一行——常驻条数（同预热线的估计：已发布常驻 + 预热已建未领 + 发布后新放的基础管线）、
//   进程物理占用、Metal 已分配量。驱动报的「AGX: exceeded compiled variants footprint limit」字面是占用量，没有公开接口直接读，
//   这两个是能拿到的最接近的量：撞线那行之前最后一行的读数，看跨款是条数稳定还是占用稳定，定额度按哪个口径
static void pb_footprint_line(uint64_t built, uint64_t hit, uint64_t compiled) {
    // 分项打：表里（提交线程每帧发布）、预热已建未领（预热计数现算；g_pb_unclaimed 只在预热线程判线时才更新，首帧后会过时）、发布后新放的拉取基础管线
    uint64_t tab = atomic_load(&g_pb_live_pub), warm = atomic_load(&g_warm_rps) + atomic_load(&g_warm_cps), claimed = g_warm_claim_rps + g_warm_claim_cps;
    uint64_t unclaimed = warm > claimed ? warm - claimed : 0, bases = pb_bases_since_pub();
    MLOG("pipeline footprint: %llu built (%llu from the archive, %llu compiled), %llu resident (tables %llu + prewarm unclaimed %llu + new pull bases %llu), budget %u, process footprint %llu MB, Metal allocated %llu MB",
         (unsigned long long)built, (unsigned long long)hit, (unsigned long long)compiled, (unsigned long long)(tab + unclaimed + bases), (unsigned long long)tab, (unsigned long long)unclaimed,
         (unsigned long long)bases, pb_budget(), (unsigned long long)bg_fp_mb(), (unsigned long long)(g_dev.currentAllocatedSize >> 20));
}
// 预热线程：再建一条会不会超过预热线（常驻 + 预热已建还没被领走的）
static int pb_at_warm_line(uint64_t built_unclaimed, uint32_t *budget, uint64_t *est) {
    // 常驻（提交线程每帧发布一次；第一帧之前没发布过）+ 预热已建未领 + 发布之后新放进 g_pbase 的基础管线（预热工人在第一帧之前就在放，不补就漏算）
    *budget = pb_budget(); *est = atomic_load(&g_pb_live_pub) + built_unclaimed + pb_bases_since_pub();
    return *budget && *est * 100 >= (uint64_t)*budget * PB_WARM_PCT;
}
static int pb_warm_full(uint64_t built_unclaimed) {
    atomic_store(&g_pb_unclaimed, built_unclaimed);   // 地址额度按活着的条数算（⑤）：预热已建未领的也活着
    uint32_t budget; uint64_t est;
    if (!pb_at_warm_line(built_unclaimed, &budget, &est)) return 0;
    if (!atomic_fetch_add(&g_pb_warm_stopped, 1)) MLOG("pipeline budget: the prewarm stops at %llu pipelines (%d%% of the budget %u%s); the rest are built at their first use", (unsigned long long)est, PB_WARM_PCT, budget,
                                                        budget == atomic_load(&g_pb_va) && !g_pb_env ? ", from the host low addresses" : "");
    return 1;
}
// ⑥ 先取拉取基础管线（hybrid_prefetch：预热工人 / 登记时）：到预热线就不取。同 pb_warm_full 的线，但不记「预热停了几行」
static int pb_prefetch_full(void) {
    uint32_t budget; uint64_t est; int full = pb_at_warm_line((g_warm_rps + g_warm_cps) - (g_warm_claim_rps + g_warm_claim_cps), &budget, &est);
    if (full) { static _Atomic int said; if (!atomic_exchange(&said, 1)) MLOG("pipeline budget: package pulling bases are no longer looked up ahead at %llu pipelines (%d%% of the budget %u); those pairs build their base at their first use", (unsigned long long)est, PB_WARM_PCT, budget); }
    return full;
}
