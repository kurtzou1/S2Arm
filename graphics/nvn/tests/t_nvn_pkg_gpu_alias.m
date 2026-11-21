// #674 随包贴图被 GPU 写过后，同存储同有效块布局重建的非随包对象应复用原 GPU 贴图，不再落空清零（nvn_mtl.m gpw_mark / alias_key_of）。
// NVN 语义：贴图对象只是存储上的描述；无论首用对象是否走随包上传（NvPkg），一旦被 GPU 写过，有效内容就在该宿主贴图里。
//   同一段存储上，只要实际生效的块线性布局（tileH / tileD / 宽对齐）一致（例如 pkg_layout=1 与 pkg_layout=0 + MINIMAL_LAYOUT 对 260x260 RG8 9 级均解析为 1-GOB 块），
//   重建的新对象就应命中同一张宿主贴图；实际块布局不同的描述仍拆开。
// 期望（按 NVN 语义手写，不由被测实现推出）：
//   ① A 为随包贴图（has_layout=1, pkg_layout=1, 260x260 RG8 9 级），GPU 写过后 Finalize；
//      同存储重建非随包 B（has_layout=0, pkg_layout=0, MINIMAL_LAYOUT）→ B 拿到与 A 同一张 Metal 贴图，且留在共享表里
//   ② 非随包 C1（pkg_layout=1）与同存储 C2（pkg_layout=0 + MINIMAL_LAYOUT）实际块布局相同 → 同一张 Metal 贴图；
//      反证 C3（pkg_layout=0、无 MINIMAL_LAYOUT，自动块高不同）→ 另一张贴图
//   ③ A 与 B 均 Finalize 后跑 alias_orphan_pass + settle → GPU 写过的共享贴图仍在共享表且无驻留/释放异常
//   ⑤（维护者补）活着的随包贴图 A2 GPU 写过、进了共享表；闲置后另一张贴图 D 写过重叠存储、按 D 的键接管：A2 的表项退掉，
//      但 A2 自己的贴图仍在驻留集（它的序号照样画它），A2 再解析仍是它。改前接管一律 defer_obj_release，出驻留集后 A2 再画就读未驻留内存
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static pool_t *g_tp; static uint8_t *g_mem;
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static void on_sig(int s, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }

static void make260(tex_t *t, size_t off, uint32_t flags, int pkg_layout, uint8_t has_layout) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RG8, .flags = flags,
                         .width = 260, .height = 260, .depth = 1, .levels = 9, .samples = 0, .pkg_layout = pkg_layout};
    t->has_layout = has_layout;
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
        enum { POOL = 8 << 20 };
        REQUIRE(!posix_memalign((void **)&g_mem, 65536, POOL)); memset(g_mem, 0, POOL);
        g_tp = calloc(1, sizeof *g_tp); REQUIRE(g_tp);
        *g_tp = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = g_mem, .size = POOL};
        nvn_be_pool_add(g_mem, POOL); nvn_dirty_add_range(g_mem, POOL);
        nvn_be_sub_begin();

        // ① 随包贴图 A（pkg_layout=1, has_layout=1）被 GPU 写过后 Finalize，同存储重建非随包 B（pkg_layout=0 + MINIMAL_LAYOUT）
        static tex_t A, B;
        make260(&A, 0, NVN_TEXTURE_FLAGS_MINIMAL_LAYOUT, 1, 1);
        make260(&B, 0, NVN_TEXTURE_FLAGS_MINIMAL_LAYOUT, 0, 0);
        REQUIRE(A.L.tileH == 0 && A.L.tileD == 0 && B.L.tileH == 0 && B.L.tileD == 0 && A.L.size == B.L.size);
        id<MTLTexture> ma = tex_mtl(&A);
        REQUIRE(ma != nil && [tex_get(A.serial) isKindOfClass:[NvPkg class]]);
        gpw_mark(&A, 0, 0, 1, 0, 0, 0, 0);
        submit();
        nvn_be_tex_release(&A);
        settle();
        id<MTLTexture> mb = tex_mtl(&B);
        CHECK(mb != nil && mb == ma, "① 随包贴图被 GPU 写过后重建非随包（等价 1-GOB 布局）：复用同一张 Metal 贴图（%p / %p）", (__bridge void *)ma, (__bridge void *)mb);

        // ② 非随包同存储：pkg_layout=1 与 pkg_layout=0 + MINIMAL_LAYOUT 有效布局一致 → 同一张；无 MINIMAL_LAYOUT（自动块高不同）→ 另一张
        static tex_t C1, C2, C3;
        make260(&C1, 1 << 20, 0, 1, 0);
        make260(&C2, 1 << 20, NVN_TEXTURE_FLAGS_MINIMAL_LAYOUT, 0, 0);
        make260(&C3, 1 << 20, 0, 0, 0);
        REQUIRE(C1.L.tileH == C2.L.tileH && C1.L.tileD == C2.L.tileD && C3.L.tileH != C1.L.tileH);
        id<MTLTexture> m1 = tex_mtl(&C1), m2 = tex_mtl(&C2), m3 = tex_mtl(&C3);
        CHECK(m1 != nil && m1 == m2, "② 非随包等价块布局（pkg=1 vs pkg=0+MINIMAL_LAYOUT）：同一张 Metal 贴图（%p / %p）", (__bridge void *)m1, (__bridge void *)m2);
        CHECK(m3 != nil && m3 != m1, "② 反证：自动块高不同的描述（tileH %u vs %u）→ 另一张贴图", C3.L.tileH, C1.L.tileH);

        // ③ A、B 均 Finalize 后跑 alias_orphan_pass，GPU 写过的共享贴图保持存活、无驻留/释放异常
        __weak id<MTLTexture> wa = ma;
        ma = nil; mb = nil;
        nvn_be_tex_release(&B);
        idle();
        alias_orphan_pass();
        settle();
        CHECK(wa != nil, "③ NvPkg 与重建对象均 Finalize 后，GPU 写过的共享贴图仍由共享表保活");
        // ⑤ 活着的随包贴图被接管：只放共享表那份引用，贴图留在驻留集
        static tex_t A2, D;
        make260(&A2, 2 << 20, NVN_TEXTURE_FLAGS_MINIMAL_LAYOUT, 1, 1);
        id<MTLTexture> m5 = tex_mtl(&A2);
        REQUIRE(m5 != nil && [tex_get(A2.serial) isKindOfClass:[NvPkg class]]);
        gpw_mark(&A2, 0, 0, 1, 0, 0, 0, 0);
        alias_key k5; alias_key_of(&k5, &A2);
        pthread_mutex_lock(&g_smu); int in5 = hm_get_id(&g_alias, &k5) == m5; pthread_mutex_unlock(&g_smu);
        REQUIRE(in5 && ((NvPkg *)tex_get(A2.serial))->tex_shared);
        idle();
        memset(&D, 0, sizeof D); D.magic = MAGIC('T', 'E', 'X', 0); D.serial = nvn_new_serial();   // 同起点、另一种描述（R8 520x260）：字节重叠、键不同
        D.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_R8, .width = 520, .height = 260, .depth = 1, .levels = 1, .samples = 0};
        D.pool = g_tp; D.off = 2 << 20; D.mem = g_mem + D.off; nvn_tex_layout(&D.d, &D.L); nvn_be_tex_init(&D);
        REQUIRE(tex_mtl(&D) != nil);
        gpw_mark(&D, 0, 0, 1, 0, 0, 0, 0); submit();
        alias_key kd; alias_key_of(&kd, &D);
        pthread_mutex_lock(&g_smu); alias_take_over(&kd); int gone5 = hm_get_id(&g_alias, &k5) == nil; pthread_mutex_unlock(&g_smu);
        settle();
        pthread_mutex_lock(&g_res_mu); int res5 = [g_res_objects containsObject:m5]; pthread_mutex_unlock(&g_res_mu);
        CHECK(gone5, "⑤ 另一张贴图写过重叠存储后接管：A2 的共享表项退掉");
        CHECK(res5, "⑤ A2 自己的贴图仍在驻留集（只放共享表的引用）");
        CHECK(tex_mtl(&A2) == m5 && !((NvPkg *)tex_get(A2.serial))->tex_shared, "⑤ A2 再解析仍是同一张贴图，不再记为共享（日后由它自己出驻留集）");
#if !TARGET_OS_IPHONE
        CHECK(g_orph_lv == NULL, "④ macOS 上 alias_orphan_pass 不把私有显存贴图挂进低区账本");
#endif

        printf("%s t_nvn_pkg_gpu_alias: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
