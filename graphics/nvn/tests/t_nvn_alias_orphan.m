// #357 无人引用的共享贴图何时放（nvn_mtl.m alias_orphan_pass）。背景：iPad 长局 463 张共享贴图里 393 张已无人引用，Metal 低区耗尽闪退。
// NVN 语义：贴图对象只是描述，字节在存储里；对象全 Finalize 后，同存储同描述重建的对象仍读到原字节。于是：
//   没被 GPU 写过的 → 内容就是存储里的（重建时从存储取回），可以即放；
//   GPU 写过的 → 内容只在宿主贴图里，存储被改写之前不能放；存储被 CPU 写过（整页落在存储内部的页）之后内容已没，可以放。
// 期望（按上面的语义手写，不由被测实现推出）：
//   ① B 建、读过、Finalize、闲 ALIAS_IDLE 次提交 → 放（never GPU-written +1），原 Metal 贴图 GPU 做完后释放
//   ② A 写过、Finalize、闲 → 两遍都留着（存储没被改）；CPU 只改其中一小段 → 仍留着（其余 GPU 写过的块还在）；CPU 改写整段存储 → 放（rewritten +1）
//   ③ C 写过、Finalize、闲，存储没动 → 低区账本要地址（腾退回调）→ 放（for the low-region ledger +1），原 Metal 贴图 GPU 做完后释放
//   ④ E 写过、对象一直活着 → CPU 改写整段存储、账本要地址 → 都留着（活对象由覆写规则管，不归这里）
//   ⑤ #427：同一存储上两个对象，一个采样数 0 + IMAGE（计算阶段写）、一个采样数 1（渲染采样读），其余描述相同 → 同一张 Metal 贴图（0 / 1 都是单采样）；
//      反证：同存储、格式不同的第三个对象 → 另一张贴图（键照旧分开真不同的描述）。修前采样数在键里原样比，两个对象是两张贴图
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static pool_t *g_tp; static uint8_t *g_mem;
// The game's CPU writes to a protected page reach the dirty tracker through the host's signal handler (crash.c → s2a_direct_fault); a test process has none, so it installs the same forwarding
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }
static void make(tex_t *t, size_t off, uint32_t side) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = side, .height = side, .depth = 1, .levels = 1};
    t->pool = g_tp; t->off = (int64_t)off; t->mem = g_mem + off; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
}
static void submit(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); nvn_be_sub_begin(); }
static void idle(void) { for (int i = 0; i <= ALIAS_IDLE; i++) submit(); }
static void settle(void) { for (int i = 0; i < 4; i++) submit(); nvn_be_drain(); }
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        { struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL); }
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        enum { POOL = 32 << 20 };
        REQUIRE(!posix_memalign((void **)&g_mem, 65536, POOL)); memset(g_mem, 0, POOL);
        g_tp = calloc(1, sizeof *g_tp); REQUIRE(g_tp);
        *g_tp = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = g_mem, .size = POOL};
        nvn_be_pool_add(g_mem, POOL); nvn_dirty_add_range(g_mem, POOL);
        nvn_be_sub_begin();
        // ①
        static tex_t B; make(&B, 4 << 20, 256); __weak id<MTLTexture> wb;
        @autoreleasepool { wb = tex_mtl(&B); } submit(); nvn_be_tex_release(&B); idle();
        uint64_t c0 = g_alias_orph_cache; alias_orphan_pass(); settle();
        CHECK(g_alias_orph_cache == c0 + 1, "① 没被 GPU 写过的无人引用贴图：放 +%llu（期望 +1）", (unsigned long long)(g_alias_orph_cache - c0));
        CHECK(wb == nil, "① 原 Metal 贴图 GPU 做完后释放");
        // ②
        static tex_t A; make(&A, 0, 512); __weak id<MTLTexture> wa;
        @autoreleasepool { wa = tex_mtl(&A); gpw_mark(&A, 0, 0, 1, 0, 0, 0, 0); } submit(); nvn_be_tex_release(&A); idle();
        uint64_t w0 = g_alias_orph_rw, n0 = g_alias.n;
        alias_orphan_pass(); alias_orphan_pass(); settle();
        CHECK(g_alias.n == n0 && g_alias_orph_rw == w0 && wa != nil, "② GPU 写过、存储没被改：两遍都留着");
        memset(A.mem + A.L.size / 2, 7, 4096); alias_orphan_pass(); settle();
        CHECK(g_alias.n == n0 && g_alias_orph_rw == w0, "② 只改了其中 4 KB：其余 GPU 写过的块还在，留着");
        memset(A.mem, 9, A.L.size); alias_orphan_pass(); settle();
        CHECK(g_alias_orph_rw == w0 + 1, "② 整段存储被改写：放 +%llu（期望 +1）", (unsigned long long)(g_alias_orph_rw - w0));
        CHECK(wa == nil, "② 原 Metal 贴图 GPU 做完后释放");
        // ③
        static tex_t C; make(&C, 8 << 20, 512); __weak id<MTLTexture> wc;
        @autoreleasepool { wc = tex_mtl(&C); gpw_mark(&C, 0, 0, 1, 0, 0, 0, 0); } submit(); nvn_be_tex_release(&C); idle();
        alias_orphan_pass(); uint64_t v0 = g_alias_orph_valve;
        uint64_t freed = alias_orph_evict(NULL, 1); settle();
        CHECK(g_alias_orph_valve == v0 + 1 && freed > 0, "③ 低区账本要地址：放 +%llu（期望 +1），放掉 %llu 字节", (unsigned long long)(g_alias_orph_valve - v0), (unsigned long long)freed);
        CHECK(wc == nil, "③ 原 Metal 贴图 GPU 做完后释放");
        // ④
        static tex_t E; make(&E, 16 << 20, 512); id<MTLTexture> e0 = tex_mtl(&E); gpw_mark(&E, 0, 0, 1, 0, 0, 0, 0); submit(); idle();
        memset(E.mem, 5, E.L.size); alias_orphan_pass(); alias_orph_evict(NULL, UINT64_MAX); settle();
        CHECK(tex_get(E.serial) == e0, "④ 活对象：存储被改写、账本要地址都留着");
        // ⑤
        static tex_t W, Rd, F; make(&W, 24 << 20, 64); make(&Rd, 24 << 20, 64); make(&F, 24 << 20, 64);
        W.d.samples = 0; W.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; Rd.d.samples = 1; F.d.samples = 1; F.d.format = NVN_FORMAT_RGBA16F;
        nvn_tex_layout(&F.d, &F.L);
        id<MTLTexture> mw = tex_mtl(&W), mr = tex_mtl(&Rd), mf = tex_mtl(&F);
        CHECK(mw && mw == mr, "⑤ 采样数 0 + IMAGE 与采样数 1、同存储同描述：同一张 Metal 贴图（%p / %p）", (__bridge void *)mw, (__bridge void *)mr);
        CHECK(mf && mf != mw, "⑤ 反证：同存储、格式不同 → 另一张贴图");
        // ⑥ #674：已 Finalize 但贴图池 ID 仍在用（视图缓存命中快路径、不刷新 g_alias_seen）的共享贴图不能被孤儿回收踢掉；注销 ID 后才回收
        static tex_t D; make(&D, 28 << 20, 256); id<MTLTexture> d0 = tex_mtl(&D); gpw_mark(&D, 0, 0, 1, 0, 0, 0, 0);
        nvn_be_reg_tex(10, &D, NULL); submit(); nvn_be_tex_release(&D); submit();
        id<MTLTexture> d1 = tex_by_id(10); idle();
        uint64_t rw6 = g_alias_orph_rw, v6 = g_alias_orph_valve;
        memset(D.mem, 4, D.L.size); alias_orphan_pass(); alias_orph_evict(NULL, UINT64_MAX); settle();
        id<MTLTexture> d2 = tex_by_id(10);
        CHECK(d1 == d0 && d2 == d0 && g_alias_orph_rw == rw6 && g_alias_orph_valve == v6,
              "⑥ 已 Finalize 但仍被贴图 ID 视图持有的共享贴图：留着（d1=%d d2=%d rw+%llu v+%llu）",
              d1 == d0, d2 == d0, (unsigned long long)(g_alias_orph_rw - rw6), (unsigned long long)(g_alias_orph_valve - v6));
        nvn_be_unreg_tex_range(10, 1); idle(); alias_orphan_pass(); settle();
        CHECK(g_alias_orph_rw == rw6 + 1, "⑥ 反证：注销贴图 ID 后再回收 → 放 +%llu（期望 +1）", (unsigned long long)(g_alias_orph_rw - rw6));
        printf("%s t_nvn_alias_orphan: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
