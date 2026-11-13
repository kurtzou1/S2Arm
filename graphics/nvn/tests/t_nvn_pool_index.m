// 内存池「地址 → 池」索引在登记 / 注销时就地维护（nvn_mtl.m pidx_added / pidx_removing），不再每次整表重排。
// 做法：一块 64 MB 内存按 64 KB 切 1024 格，用固定的线性同余序列在格子上登记 / 注销池（先登记 600 个打乱顺序的，再做 2000 步「有就注销、没有就登记」）。
// 期望全部由单测自己的占用表算出，不由被测实现推出：
//   ① 首次查找建索引后，之后每一步索引都保持有效（没有退回整表重排）
//   ② 每一步：被占的格子查得到、且查到的池起点 = 该格地址；空格子查不到（-1）
//   ③ 索引里恰好是当前全部池、按起点不降排列、没有重复
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { SLOTS = 1024, SLOT = 64 << 10 };
static uint8_t *base; static uint8_t used[SLOTS];
static uint32_t rnd(void) { static uint32_t x = 12345; x = x * 1664525u + 1013904223u; return x >> 8; }
// 一步之后核三条；返回出错的条数
static int verify(int *lookups) {
    int bad = 0, live = 0;
    pthread_mutex_lock(&g_mu);
    if (!g_pidx_ok) bad++;
    for (int s = 0; s < SLOTS; s++) {
        uint64_t a = (uint64_t)(uintptr_t)(base + (size_t)s * SLOT);
        g_plast = -1;   // 不让「上次命中」短路，每次都走索引
        int k = pool_find(a + 123, 1); (*lookups)++;
        if (used[s]) { live++; if (k < 0 || g_pools[k].lo != a) bad++; } else if (k >= 0) bad++;
    }
    if (live != g_npool) bad++;
    for (int i = 0; i < g_npool; i++) {
        if (g_pidx[i] < 0 || g_pidx[i] >= g_npool) { bad++; break; }
        if (i && g_pools[g_pidx[i - 1]].lo >= g_pools[g_pidx[i]].lo) bad++;   // 起点各不相同：严格递增同时排除了重复
    }
    pthread_mutex_unlock(&g_mu);
    return bad;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
    mtl_init(); printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
    base = mmap(NULL, (size_t)SLOTS * SLOT, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(base != MAP_FAILED);
    int n0 = 0; pthread_mutex_lock(&g_mu); n0 = g_npool; pthread_mutex_unlock(&g_mu); REQUIRE(n0 == 0);
    int lookups = 0, bad = 0;
    for (int i = 0; i < 600; ) { int s = (int)(rnd() % SLOTS); if (used[s]) continue; nvn_be_pool_add(base + (size_t)s * SLOT, SLOT); used[s] = 1; i++; }
    pthread_mutex_lock(&g_mu); int k0 = pool_find((uint64_t)(uintptr_t)base, 1); int ok0 = g_pidx_ok; (void)k0; pthread_mutex_unlock(&g_mu);
    CHECK(ok0 == 1 && verify(&lookups) == 0, "600 个乱序登记的池：首次查找建好索引，占用的格子都查得到、空格子查不到");
    int adds = 0, dels = 0, invalid = 0;
    for (int step = 0; step < 2000; step++) {
        int s = (int)(rnd() % SLOTS);
        if (used[s]) { nvn_be_pool_del(base + (size_t)s * SLOT); used[s] = 0; dels++; } else { nvn_be_pool_add(base + (size_t)s * SLOT, SLOT); used[s] = 1; adds++; }
        pthread_mutex_lock(&g_mu); invalid += !g_pidx_ok; pthread_mutex_unlock(&g_mu);
        if (step % 50 == 49 || step < 20) bad += verify(&lookups);
    }
    CHECK(adds > 600 && dels > 600, "2000 步里登记 %d 次、注销 %d 次（两种都走到）", adds, dels);
    CHECK(invalid == 0, "① 每一步之后索引都有效（失效 %d 次，期望 0）", invalid);
    CHECK(bad == 0, "②③ 抽查 %d 次查找与索引排列全部正确（出错 %d 条，期望 0）", lookups, bad);
    // 池表扩容后索引容量不够的那一步允许失效一次，下次查找重建后继续就地维护
    for (int s = 0; s < SLOTS; s++) if (!used[s]) { nvn_be_pool_add(base + (size_t)s * SLOT, SLOT); used[s] = 1; }
    CHECK(verify(&lookups) <= 1 && verify(&lookups) == 0, "填满 1024 格（索引扩容）后查找仍全部正确");
    for (int s = 0; s < SLOTS; s += 2) { nvn_be_pool_del(base + (size_t)s * SLOT); used[s] = 0; }
    CHECK(verify(&lookups) == 0, "隔一个注销一个（512 次）后查找全部正确、索引仍有效");
    if (failures) printf("✗ t_nvn_pool_index：%u 项不符（共 %u 项）\n", failures, checks); else printf("✓ t_nvn_pool_index：池地址索引就地维护，%u 项全过\n", checks);
    return failures != 0;
} }
