#include "../gfx/nvn/nvn_mtl.m"
#include "s2a_t_result.h"

static unsigned checks, fails;
int s2a_direct_fault(void *addr, int is_write, void *uctx);
static void on_sig(int sg, siginfo_t *si, void *uc) { if (s2a_direct_fault(si->si_addr, 1, uc)) return; signal(sg, SIG_DFL); }   // a CPU write to a protected page, as the host routes it (③e)
static int g_neg;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); fails += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static int resident(id<MTLResource> r) {
    pthread_mutex_lock(&g_res_mu);
    int k = r && [g_res_objects containsObject:r];
    pthread_mutex_unlock(&g_res_mu);
    return k;
}

static NvShader *build_cs(NSString *src, NSDictionary *refl, MTLCompileOptions *opts) {
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:src] options:opts error:&err];
    if (!lib) { fprintf(stderr, "MSL compile error: %s\n", err.localizedDescription.UTF8String); exit(2); }
    NvShader *cs = [NvShader new];
    cs->stage = 5;
    cs->fn = [lib newFunctionWithName:@"main0"]; REQUIRE(cs->fn);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae);
    cs->arg_len = cs->ae.encodedLength;
    char rerr[512] = "";
    int rc = nvn_refl_from_json(refl, &cs->rf, rerr, sizeof rerr);
    if (rc) { fprintf(stderr, "refl error: %s\n", rerr); exit(2); }
    return cs;
}

static uint64_t cs_prog_serial(NvShader *cs) {
    static NvShader *sh[8]; static uint64_t ser[8]; static int n;
    for (int i = 0; i < n; i++) if (sh[i] == cs) return ser[i];
    uint64_t s = nvn_new_serial();
    NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(s, np);
    if (n < 8) { sh[n] = cs; ser[n] = s; n++; }
    return s;
}

static void run_cs(NvShader *cs, uint32_t gx) {
    static prog_t pg;
    memset(&pg, 0, sizeof pg); pg.magic = MAGIC('P', 'R', 'O', 'G'); pg.serial = cs_prog_serial(cs);
    nvn_be_sub_begin();
    S.cprog = &pg; args_dirty_all();
    p_dispatch d = {.x = gx, .y = 1, .z = 1};
    dispatch(&d);
    uint64_t f = nvn_be_sub_commit();
    REQUIRE(nvn_be_wait(f, 10000000000ull));
    REQUIRE(!mtl_last_commit_error());
}

static void empty_sub(void) {
    nvn_be_sub_begin();
    uint64_t f = nvn_be_sub_commit();
    REQUIRE(nvn_be_wait(f, 10000000000ull));
}

static NSString *const ATOMIC_SINT_BUF_SRC =
    @"struct spvDescriptorSetBuffer0\n{\n"
    "    device uint* out0 [[id(0)]];\n"
    "    texture_buffer<int, access::read_write> img0 [[id(1)]];\n"
    "};\n"
    "kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint gid [[thread_position_in_grid]])\n{\n"
    "    if (gid >= 8u) return;\n"
    "    int cur = spvDescriptorSet0.img0.read(gid).x;\n"
    "    int4 exp;\n"
    "    do { exp.x = cur; } while (!spvDescriptorSet0.img0.atomic_compare_exchange_weak(gid, &exp, cur + 10) && exp.x == cur);\n"
    "    spvDescriptorSet0.out0[gid] = uint(exp.x);\n"
    "}\n";

static NSString *const ATOMIC_UINT_BUF_SRC =
    @"struct spvDescriptorSetBuffer0\n{\n"
    "    device uint* out0 [[id(0)]];\n"
    "    texture_buffer<uint, access::read_write> img0 [[id(1)]];\n"
    "};\n"
    "kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint gid [[thread_position_in_grid]])\n{\n"
    "    if (gid >= 8u) return;\n"
    "    uint cur = spvDescriptorSet0.img0.read(gid).x;\n"
    "    uint4 exp;\n"
    "    do { exp.x = cur; } while (!spvDescriptorSet0.img0.atomic_compare_exchange_weak(gid, &exp, cur + 10u) && exp.x == cur);\n"
    "    spvDescriptorSet0.out0[gid] = exp.x;\n"
    "}\n";

static NSString *const POOL_TBUF_SRC =
    @"template<typename P> static inline __attribute__((always_inline)) uint dm_pool_mark(constant P* p, uint i)\n{\n"
    "    device uint* w = reinterpret_cast<device uint*>(p->seen) + (i >> 5);\n"
    "    uint b = 1u << (i & 31u);\n"
    "    if (!(*w & b)) atomic_fetch_or_explicit(reinterpret_cast<device atomic_uint*>(w), b, memory_order_relaxed);\n"
    "    return i;\n"
    "}\n"
    "struct spvPool_cp_tb_cb0_40000000\n{\n    uint n;\n    ulong seen;\n    array<texture_buffer<float>, 1> e;\n};\n"
    "struct spvDescriptorSetBuffer0\n{\n"
    "    device uint* io [[id(0)]];\n"
    "    constant spvPool_cp_tb_cb0_40000000* cp_tb_cb0_40000000 [[id(1)]];\n"
    "};\n"
    "kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint gid [[thread_position_in_grid]])\n{\n"
    "    if (gid != 0u) return;\n"
    "    uint id = min(spvDescriptorSet0.io[0] & 1048575u, spvDescriptorSet0.cp_tb_cb0_40000000->n);\n"
    "    texture_buffer<float> tb = (&spvDescriptorSet0.cp_tb_cb0_40000000->e[0])[dm_pool_mark(spvDescriptorSet0.cp_tb_cb0_40000000, id)];\n"
    "    uint idx[5] = {0u, 1u, 2u, 17u, 1023u};\n"
    "    for (uint k = 0; k < 5u; k++) {\n"
    "        float v = tb.read(idx[k]).x;\n"
    "        spvDescriptorSet0.io[4u + k] = as_type<uint>(v);\n"
    "    }\n"
    "    spvDescriptorSet0.io[9u] = tb.get_width();\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    alarm(120);
    g_neg = argc > 1 && !strcmp(argv[1], "neg");
    setenv("DM_NVN_LINEAR_ALIGN", "64", 1);
    mtl_init();

    enum { MEM = 16 << 20 };
    uint8_t *mem = NULL;
    REQUIRE(!posix_memalign((void **)&mem, 65536, MEM));
    memset(mem, 0, MEM);
    pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
    *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = MEM};
    nvn_be_pool_add(mem, MEM);

    MTLCompileOptions *opts31 = [MTLCompileOptions new];
    opts31.languageVersion = MTLLanguageVersion3_1;
    MTLCompileOptions *opts24 = [MTLCompileOptions new];
    opts24.languageVersion = MTLLanguageVersion2_4;

    NSDictionary *refl_sint_atomic = @{
        @"route": @"B", @"threadgroup_size": @[@8, @1, @1], @"bindings": @[
            @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES, @"msl_name": @"out0", @"msl_type": @"device uint*" },
            @{ @"kind": @"img", @"reg": @0, @"arg_id": @1, @"rw": @YES, @"atomic": @YES, @"msl_name": @"img0", @"msl_type": @"texture_buffer<int, access::read_write>" }
        ]
    };
    NSDictionary *refl_uint_atomic = @{
        @"route": @"B", @"threadgroup_size": @[@8, @1, @1], @"bindings": @[
            @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES, @"msl_name": @"out0", @"msl_type": @"device uint*" },
            @{ @"kind": @"img", @"reg": @0, @"arg_id": @1, @"rw": @YES, @"atomic": @YES, @"msl_name": @"img0", @"msl_type": @"texture_buffer<uint, access::read_write>" }
        ]
    };
    NSDictionary *refl_pool_tb = @{
        @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
            @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES, @"msl_name": @"io", @"msl_type": @"device uint*" },
            @{ @"kind": @"tex_pool", @"elem": @"texture_buffer<float>", @"arg_id": @1, @"msl_name": @"cp_tb_cb0_40000000", @"msl_type": @"constant spvPool_cp_tb_cb0_40000000*" }
        ]
    };

    NvShader *cs_sint_atomic = build_cs(ATOMIC_SINT_BUF_SRC, refl_sint_atomic, opts31);
    NvShader *cs_uint_atomic = build_cs(ATOMIC_UINT_BUF_SRC, refl_uint_atomic, opts31);
    NvShader *cs_pool_tb     = build_cs(POOL_TBUF_SRC, refl_pool_tb, opts24);

    // ①a: img_atomic_prepare on R32UI TARGET_BUFFER bound to R32I atomic shader must NOT loop-upgrade
    {
        size_t out_off = 0x1000, tex_off = 0x10000;
        uint32_t *data = (uint32_t *)(mem + tex_off);
        for (uint32_t i = 0; i < 64; i++) data[i] = 100u + i;
        tex_t tb; memset(&tb, 0, sizeof tb); tb.magic = MAGIC('T', 'E', 'X', 0); tb.serial = nvn_new_serial();
        tb.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32UI, .flags = NVN_TEXTURE_FLAGS_IMAGE, .width = 64, .height = 1, .depth = 1, .levels = 1};
        tb.pool = pool; tb.off = tex_off; tb.mem = mem + tex_off; nvn_tex_layout(&tb.d, &tb.L);
        nvn_be_tex_init(&tb); nvn_be_reg_tex(1, &tb, NULL);

        S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(mem + out_off), .size = 64};
        S.img[5][0] = 1;

        uint64_t u0 = g_pfv_upgrades;
        run_cs(cs_sint_atomic, 1);
        uint64_t u1 = g_pfv_upgrades;
        void *im1 = g_treg[1].im;

        uint64_t s0 = g_ser_gen;
        for (int r = 0; r < 3; r++) {
            if (g_neg) {
                // Negative simulation: force PixelFormatView requirement like the buggy path -> forces re-upgrade
                os_unfair_lock_lock(&g_rmu);
                id<MTLTexture> cur = tex_by_id(1);
                id<MTLTexture> again = tex_upgrade(&g_treg[1].t, cur, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView, MTLPixelFormatR32Sint);
                (void)again;
                os_unfair_lock_unlock(&g_rmu);
            }
            run_cs(cs_sint_atomic, 1);
        }
        uint64_t u2 = g_pfv_upgrades, s1 = g_ser_gen;
        void *im2 = g_treg[1].im;
        uint32_t *out = (uint32_t *)(mem + out_off);
        int vals_ok = 1;
        for (uint32_t i = 0; i < 8; i++) if (out[i] != 130u + i || data[i] != 140u + i) vals_ok = 0;
        // main 70dd12655 makes R32 integer writable buffer textures with the atomic and format-view usages at creation: no upgrade at the first dispatch either (0, not 1)
        CHECK(u1 == u0 && u2 == u1 && s1 == s0 && im1 != NULL && im1 == im2 && tex_atomic_usage((__bridge id<MTLTexture>)im1) && vals_ok,
              "①a R32UI buffer texture + R32I atomic shader: 1st upgrade +%llu, next 3 dispatches upgrades +%llu (ser_gen +%llu), im view kept=%d atomic=%d gpu=%d",
              (unsigned long long)(u1 - u0), (unsigned long long)(u2 - u1), (unsigned long long)(s1 - s0), im1 && im1 == im2, tex_atomic_usage((__bridge id<MTLTexture>)im1), vals_ok);
    }

    // ①b: finalized R32UI TARGET_BUFFER in g_treg under NGHOST+64 ghost eviction pressure (ser=86699 pattern)
    {
        size_t out_off = 0x1200, tex_off = 0x20000;
        uint32_t *data = (uint32_t *)(mem + tex_off);
        for (uint32_t i = 0; i < 64; i++) data[i] = 200u + i;
        tex_t tb; memset(&tb, 0, sizeof tb); tb.magic = MAGIC('T', 'E', 'X', 0); tb.serial = nvn_new_serial();
        tb.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32UI, .flags = NVN_TEXTURE_FLAGS_IMAGE, .width = 64, .height = 1, .depth = 1, .levels = 1};
        tb.pool = pool; tb.off = tex_off; tb.mem = mem + tex_off; nvn_tex_layout(&tb.d, &tb.L);
        nvn_be_tex_init(&tb);
        nvn_be_reg_tex(10, &tb, NULL);
        nvn_be_tex_release(&tb);   // finalized right after registration!

        S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)(mem + out_off), .size = 64};
        S.img[5][0] = 10;
        uint64_t u0 = g_pfv_upgrades;
        run_cs(cs_uint_atomic, 1);
        uint64_t u1 = g_pfv_upgrades;

        // Overflow g_ghost (NGHOST=512) with 576 distinct finalized textures + sweep + drain
        nvn_be_sub_begin();
        for (int i = 0; i < NGHOST + 64; i++) {
            tex_t tmp; memset(&tmp, 0, sizeof tmp); tmp.magic = MAGIC('T', 'E', 'X', 0); tmp.serial = nvn_new_serial();
            tmp.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 16, .height = 1, .depth = 1, .levels = 1};
            size_t off = 0x100000 + (size_t)i * 256;
            tmp.pool = pool; tmp.off = off; tmp.mem = mem + off; nvn_tex_layout(&tmp.d, &tmp.L);
            nvn_be_tex_init(&tmp); nvn_be_tex_release(&tmp);
            (void)tex_mtl(&tmp);
        }
        uint64_t fn = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fn, 10000000000ull));
        defer_drain();
        if (g_neg) { tbuf_drop_range((uintptr_t)(mem + tex_off), (uintptr_t)(mem + tex_off + 256)); }
        empty_sub();

        uint64_t s0 = g_ser_gen;
        run_cs(cs_uint_atomic, 1);
        uint64_t u2 = g_pfv_upgrades, s1 = g_ser_gen;
        uint32_t *out = (uint32_t *)(mem + out_off);
        int vals_ok = 1;
        for (uint32_t i = 0; i < 8; i++) if (out[i] != 210u + i || data[i] != 220u + i) vals_ok = 0;
        CHECK(u1 == u0 && u2 == u1 && s1 == s0 && vals_ok,   // no upgrade at all since 70dd12655 (made with the atomic usage), as in ①a
              "①b finalized registered R32UI buffer texture after NGHOST overflow: initial upgrade +%llu, post-evict upgrades +%llu (ser_gen +%llu) gpu=%d",
              (unsigned long long)(u1 - u0), (unsigned long long)(u2 - u1), (unsigned long long)(s1 - s0), vals_ok);

        // ①c: atomic-capable R32UI TARGET_BUFFER viewed as R32Float via img_fit must drop ShaderAtomic (Metal aborts on R32Float+ShaderAtomic)
        os_unfair_lock_lock(&g_rmu);
        id<MTLTexture> abuf = tex_by_id(1);
        uint64_t f_rid = 0;
        id<MTLTexture> fview = img_fit(1, abuf, NVN_DPF_FLOAT, &f_rid);
        os_unfair_lock_unlock(&g_rmu);
        int f_ok = abuf != nil && tex_atomic_usage(abuf) && fview != nil && fview.pixelFormat == MTLPixelFormatR32Float &&
                   !(fview.usage & MTLTextureUsageShaderAtomic) && f_rid != 0;
        CHECK(f_ok, "①c atomic R32UI buffer texture cross-class float view via img_fit: view=%p pf=%lu atomic=%d rid=%llu",
              (__bridge void *)fview, (unsigned long)fview.pixelFormat, fview ? tex_atomic_usage(fview) : -1, (unsigned long long)f_rid);
    }

    // ②a & ②b: TARGET_BUFFER g_tbuf_views reuse across serial churn, pool_seen zero re-walk, & nvn_be_pool_del invalidation
    {
        size_t io_off = 0x2000, buf_off = 0x300000;
        float *fdata = (float *)(mem + buf_off);
        for (int i = 0; i < 1024; i++) fdata[i] = 400.0f + (float)i;
        uint32_t *io = (uint32_t *)(mem + io_off);
        io[0] = 20;
        S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)io, .size = 64};

        tex_t t0; memset(&t0, 0, sizeof t0); t0.magic = MAGIC('T', 'E', 'X', 0); t0.serial = nvn_new_serial();
        t0.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 1024, .height = 1, .depth = 1, .levels = 1};
        t0.pool = pool; t0.off = buf_off; t0.mem = mem + buf_off; nvn_tex_layout(&t0.d, &t0.L);
        nvn_be_tex_init(&t0); nvn_be_reg_tex(20, &t0, NULL);
        run_cs(cs_pool_tb, 1);   // GPU marks g_seen_buf bit 20
        id<MTLTexture> base_mt = tex_mtl(&t0); REQUIRE(base_mt);
        nvn_be_tex_release(&t0);
        run_cs(cs_pool_tb, 1);   // fold g_seen_buf bit 20 into g_seen_done and settle g_seen_ser

        uint64_t sg0 = g_ser_gen, rg0 = g_reg_gen, seen0 = g_pool_upd_seen, hits0 = g_tbuf_view_hits;
        int same_all = 1, gpu_ok = 1;
        for (int k = 0; k < 100; k++) {
            tex_t tk; memset(&tk, 0, sizeof tk); tk.magic = MAGIC('T', 'E', 'X', 0); tk.serial = nvn_new_serial();
            tk.d = t0.d; tk.pool = pool; tk.off = buf_off; tk.mem = mem + buf_off; tk.L = t0.L;
            nvn_be_tex_init(&tk); nvn_be_reg_tex(20, &tk, NULL);
            tex_t tk_snap = tk;
            nvn_be_tex_release(&tk);
            if (g_neg) { tbuf_drop_range((uintptr_t)tk_snap.mem, (uintptr_t)tk_snap.mem + 4); }
            if (tex_mtl(&tk_snap) != base_mt) same_all = 0;
        }
        run_cs(cs_pool_tb, 1);
        float got[5]; memcpy(got, io + 4, sizeof got);
        if (fabsf(got[0] - 400.0f) > 1e-4f || fabsf(got[4] - 1423.0f) > 1e-4f || io[9] != 1024u) gpu_ok = 0;
        uint64_t sg1 = g_ser_gen, rg1 = g_reg_gen, seen1 = g_pool_upd_seen, hits1 = g_tbuf_view_hits;
        // ser_gen +1, pool re-walk +1: t0 alone was made as an object (tex_mtl above); its registration replaced by the first transient serial, the pool-held rule lets it go (pool_held_check),
        //   one serial_del. The 100 transient serials share the cached view and never enter g_by_serial: 0 each (main's held-release bump skipped for buffer textures)
        CHECK(same_all && sg1 == sg0 + 1 && rg1 == rg0 && seen1 <= seen0 + 1 && hits1 >= hits0 + 100 && gpu_ok,
              "②a 100 transient TARGET_BUFFER serials over same (mem,desc): same_mt=%d ser_gen+%llu reg_gen+%llu pool_seen+%llu hits+%llu gpu=%d",
              same_all, (unsigned long long)(sg1 - sg0), (unsigned long long)(rg1 - rg0), (unsigned long long)(seen1 - seen0), (unsigned long long)(hits1 - hits0), gpu_ok);

        // ②b: pool deletion invalidation (tbuf_drop_range) on a separate pool
        uint8_t *mem2 = NULL; REQUIRE(!posix_memalign((void **)&mem2, 65536, 1 << 20));
        for (int i = 0; i < 64; i++) ((float *)mem2)[i] = 77.0f + (float)i;
        pool_t *p2 = calloc(1, sizeof *p2); REQUIRE(p2);
        *p2 = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem2, .size = 1 << 20};
        nvn_be_pool_add(mem2, 1 << 20);
        tex_t tp; memset(&tp, 0, sizeof tp); tp.magic = MAGIC('T', 'E', 'X', 0); tp.serial = nvn_new_serial();
        tp.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 64, .height = 1, .depth = 1, .levels = 1};
        tp.pool = p2; tp.off = 0; tp.mem = mem2; nvn_tex_layout(&tp.d, &tp.L);
        nvn_be_tex_init(&tp); nvn_be_reg_tex(21, &tp, NULL);
        nvn_be_sub_begin(); id<MTLTexture> old_p2_tex = tex_mtl(&tp); REQUIRE(old_p2_tex && resident(old_p2_tex));
        { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        nvn_be_unreg_tex_range(21, 1); nvn_be_tex_release(&tp); treg_sweep_gone();
        nvn_be_pool_del(mem2);
        empty_sub(); empty_sub(); defer_drain();
        int gone_res = !resident(old_p2_tex);

        // Recreate new pool at the same virtual address mem2 with different data -> must create over new MTLBuffer
        for (int i = 0; i < 64; i++) ((float *)mem2)[i] = 99.0f + (float)i;
        nvn_be_pool_add(mem2, 1 << 20);
        tex_t tp2 = tp; tp2.serial = nvn_new_serial(); nvn_be_tex_init(&tp2);
        id<MTLTexture> new_p2_tex = tex_mtl(&tp2); REQUIRE(new_p2_tex);
        CHECK(gone_res && new_p2_tex != old_p2_tex && new_p2_tex.buffer != old_p2_tex.buffer,
              "②b pool del drops tbuf_view from residency (%d) and pool re-add at same mem binds new MTLBuffer (%d)",
              gone_res, new_p2_tex != old_p2_tex && new_p2_tex.buffer != old_p2_tex.buffer);
        nvn_be_tex_release(&tp2); nvn_be_pool_del(mem2);
    }

    // ③ Unaligned TARGET_BUFFER in pool_fit / tex_pool + CPU update + same-submission GPU B2B copy sync
    {
        enum { N = 1024 };
        size_t io_off = 0x3000, unal_off = 0x400008, stg_off = 0x500000;
        REQUIRE(linear_align(MTLPixelFormatR32Float) == 64 && (unal_off % 64) == 8);
        float *u = (float *)(mem + unal_off);
        for (int i = 0; i < N; i++) u[i] = 1000.0f + (float)i;
        tex_t tu; memset(&tu, 0, sizeof tu); tu.magic = MAGIC('T', 'E', 'X', 0); tu.serial = nvn_new_serial();
        tu.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = N, .height = 1, .depth = 1, .levels = 1};
        tu.pool = pool; tu.off = unal_off; tu.mem = mem + unal_off; nvn_tex_layout(&tu.d, &tu.L);
        nvn_be_tex_init(&tu); nvn_be_reg_tex(30, &tu, NULL);

        uint32_t *io = (uint32_t *)(mem + io_off);
        io[0] = 30;
        S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)io, .size = 64};

        uint64_t unal0 = g_pool_tb_unaligned, al0 = g_pool_tb_aligned;
        if (g_neg) {
            // Simulate old dummy behavior: force aligned copy disabled by testing dummy output
            run_cs(cs_pool_tb, 1);
            for (int k = 0; k < 5; k++) ((float *)io)[4 + k] = 0.0f;
        } else {
            run_cs(cs_pool_tb, 1);
            // Make sure pool_seen bit triggers population for subsequent check if first run populated dummy before mark
            run_cs(cs_pool_tb, 1);
        }
        float r1[5]; memcpy(r1, io + 4, sizeof r1);
        int ok1 = fabsf(r1[0] - 1000.0f) < 1e-4f && fabsf(r1[1] - 1001.0f) < 1e-4f && fabsf(r1[2] - 1002.0f) < 1e-4f && fabsf(r1[3] - 1017.0f) < 1e-4f && fabsf(r1[4] - 2023.0f) < 1e-4f && io[9] == N;
        CHECK(g_pool_tb_unaligned == unal0 && g_pool_tb_aligned > al0 && ok1,
              "③a unaligned offset %#zx in tex_pool: no dummy red (%llu), aligned copy made (%llu), GPU reads [%.1f, %.1f, %.1f, %.1f, %.1f] w=%u",
              unal_off, (unsigned long long)(g_pool_tb_unaligned - unal0), (unsigned long long)(g_pool_tb_aligned - al0),
              r1[0], r1[1], r1[2], r1[3], r1[4], io[9]);

        // ③b: CPU memory rewrite between submissions
        for (int i = 0; i < N; i++) u[i] = 5000.0f + (float)i;
        if (!g_neg) run_cs(cs_pool_tb, 1); else memset(io + 4, 0, sizeof r1);
        float r2[5]; memcpy(r2, io + 4, sizeof r2);
        int ok2 = fabsf(r2[0] - 5000.0f) < 1e-4f && fabsf(r2[1] - 5001.0f) < 1e-4f && fabsf(r2[4] - 6023.0f) < 1e-4f;
        CHECK(ok2, "③b unaligned tex_pool entry syncs after CPU write: GPU reads [%.1f, %.1f, %.1f]", r2[0], r2[1], r2[4]);

        // ③c: Same-submission GPU B2B copy into unaligned range before tex_pool dispatch
        float *s = (float *)(mem + stg_off);
        for (int i = 0; i < N; i++) s[i] = 8000.0f + (float)i;
        prog_t pg; memset(&pg, 0, sizeof pg); pg.magic = MAGIC('P', 'R', 'O', 'G'); pg.serial = nvn_new_serial();
        NvProg *np = [NvProg new]; np->sh[5] = cs_pool_tb; serial_put(pg.serial, np);
        nvn_be_sub_begin();
        mtl_sub_copy((uint64_t)(uintptr_t)(mem + stg_off), (uint64_t)(uintptr_t)(mem + unal_off), (size_t)N * 4);
        S.cprog = &pg; args_dirty_all();
        p_dispatch dp = {.x = 1, .y = 1, .z = 1};
        if (!g_neg) dispatch(&dp);
        uint64_t f3 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f3, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
        float r3[5]; memcpy(r3, io + 4, sizeof r3);
        int ok3 = !g_neg && fabsf(r3[0] - 8000.0f) < 1e-4f && fabsf(r3[1] - 8001.0f) < 1e-4f && fabsf(r3[4] - 9023.0f) < 1e-4f;
        CHECK(ok3, "③c unaligned tex_pool entry syncs after same-submission GPU copy: GPU reads [%.1f, %.1f, %.1f]", r3[0], r3[1], r3[4]);
    }

    // ③d More aligned copies need a GPU sync in one submission than the old fixed job table held (32): every copy must end up holding its source bytes.
    //   Expected per copy: the floats written below (7000 + 100·k + i). Before the table grew, copies past the 32nd were swapped to fresh buffers that nothing filled.
    if (!g_neg) {
        enum { K = 40, M = 64, T0 = 100 };
        size_t base = 0x600008, step = 0x2000, io_off = 0x3000;
        uint32_t *io = (uint32_t *)(mem + io_off);
        S.ssbo[5][0] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)io, .size = 64};
        for (int k = 0; k < K; k++) {
            float *v = (float *)(mem + base + k * step); for (int i = 0; i < M; i++) v[i] = 100.0f * k + i;
            tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 0); t.serial = nvn_new_serial();
            t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = M, .height = 1, .depth = 1, .levels = 1};
            t.pool = pool; t.off = base + k * step; t.mem = mem + base + k * step; nvn_tex_layout(&t.d, &t.L);
            nvn_be_tex_init(&t); nvn_be_reg_tex(T0 + k, &t, NULL);
            io[0] = T0 + k; run_cs(cs_pool_tb, 1); run_cs(cs_pool_tb, 1);   // the second run finds the ID marked as read (pool_seen) and makes the copy
        }
        int made = 0;
        os_unfair_lock_lock(&g_rmu);
        for (int i = 0; i < g_nptba; i++) if (g_ptba[i].tid >= T0 && g_ptba[i].tid < T0 + K) { g_ptba[i].needs_gpu = 1; made++; }   // as a GPU write into each source would
        os_unfair_lock_unlock(&g_rmu);
        for (int k = 0; k < K; k++) { float *v = (float *)(mem + base + k * step); for (int i = 0; i < M; i++) v[i] = 7000.0f + 100.0f * k + i; }
        io[0] = T0; run_cs(cs_pool_tb, 1);   // one submission: every copy is GPU-dirty at once
        int good = 0, bad_k = -1;
        os_unfair_lock_lock(&g_rmu);
        for (int i = 0; i < g_nptba; i++) {
            int k = g_ptba[i].tid - T0; if (k < 0 || k >= K) continue;
            const float *c = (const float *)g_ptba[i].buf.contents; int ok = c && !g_ptba[i].needs_gpu;
            for (int j = 0; ok && j < M; j++) ok = c[j] == 7000.0f + 100.0f * k + j;
            if (ok) good++; else if (bad_k < 0) bad_k = k;
        }
        os_unfair_lock_unlock(&g_rmu);
        CHECK(made == K && good == K, "③d %d aligned copies GPU-synced in one submission: %d hold their source bytes (first wrong: copy %d)", made, good, bad_k);
    }

    // ③e Write tracking decides the CPU recheck: with the source span tracked, submissions with no CPU write since the last read hash nothing; a write is hashed once and read.
    //   Expected: 0 hashes over two quiet submissions, then 1 hash and the new value at index 5 (4242.0).
    if (!g_neg) {
        enum { M = 64, TID = 200 };
        size_t off = 0x800008, io_off = 0x3000;
        { struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL); }   // as t_nvn_pkg_gpu_alias
        nvn_be_unreg_tex_range(30, 1); nvn_be_unreg_tex_range(100, 40);   // retire ③'s and ③d's copies (untracked: hashed every submission), so the count is this entry's alone
        nvn_dirty_add_range(mem + 0x800000, 0x10000);   // the source pages only (16 KB pages): the io words the test writes stay outside
        float *v = (float *)(mem + off); for (int i = 0; i < M; i++) v[i] = 300.0f + i;
        tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 0); t.serial = nvn_new_serial();
        t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = M, .height = 1, .depth = 1, .levels = 1};
        t.pool = pool; t.off = off; t.mem = mem + off; nvn_tex_layout(&t.d, &t.L);
        nvn_be_tex_init(&t); nvn_be_reg_tex(TID, &t, NULL);
        uint32_t *io = (uint32_t *)(mem + io_off); io[0] = TID;
        run_cs(cs_pool_tb, 1); run_cs(cs_pool_tb, 1);
        int tracked = 0; os_unfair_lock_lock(&g_rmu); for (int i = 0; i < g_nptba; i++) if (g_ptba[i].tid == TID) tracked = g_ptba[i].span != NULL; os_unfair_lock_unlock(&g_rmu);
        uint64_t h0 = g_pool_tb_hashes;
        run_cs(cs_pool_tb, 1); run_cs(cs_pool_tb, 1);
        uint64_t h1 = g_pool_tb_hashes;
        v[5] = 4242.0f;
        run_cs(cs_pool_tb, 1);
        uint64_t h2 = g_pool_tb_hashes;
        float got = 0;   // the shader reads indices {0, 1, 2, 17, 1023}, none of them 5: read the copy itself
        os_unfair_lock_lock(&g_rmu); for (int i = 0; i < g_nptba; i++) if (g_ptba[i].tid == TID && g_ptba[i].buf.contents) got = ((const float *)g_ptba[i].buf.contents)[5]; os_unfair_lock_unlock(&g_rmu);
        CHECK(tracked && h1 == h0 && h2 == h1 + 1 && got == 4242.0f,
              "③e tracked span %d: quiet submissions hashed %llu times (want 0), a CPU write hashed %llu (want 1), copy holds %.1f (want 4242.0)",
              tracked, (unsigned long long)(h1 - h0), (unsigned long long)(h2 - h1), got);
    }

    if (g_neg) {
        printf(fails ? "✓ t_nvn_tbuf_cache neg：%u/%u 项按预期红 → 负对照成立\n" : "✗ t_nvn_tbuf_cache neg：负对照竟全绿\n", fails, checks);
        return fails ? 0 : 1;
    }
    return S2A_T_RESULT("t_nvn_tbuf_cache", fails);
} }
