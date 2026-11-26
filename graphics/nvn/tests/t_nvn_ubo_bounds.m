// Regression tests for short uniform-buffer reads and bounds handling across Metal 3 & 4.
#ifndef NVN_UBO_BOUNDS_SOURCE
#define NVN_UBO_BOUNDS_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_UBO_BOUNDS_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok = !!(c); failures += !ok; printf("%s ", ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct UboBlock { float4 _m0[4096]; };\n"
"struct UboLen { uint _m0[14]; };\n"
"struct Desc11 {\n"
"    constant UboBlock* fp_c14 [[id(0)]];\n"
"    const device UboLen* gal_ubo_len [[id(1)]];\n"
"};\n"
"struct Desc6 {\n"
"    constant UboBlock* fp_c9 [[id(0)]];\n"
"};\n"
"vertex float4 tri(uint i [[vertex_id]]) {\n"
"    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
"    return float4(p[i], 0, 1);\n"
"}\n"
// Mirrors ab050124bbe6051d_b: unclamped const _m0[144].x loop limit (+2304) + clamped dynamic access.
// Output encodes: r = loop accumulator, g = clamped dynamic read at idx 1, b = _m0[0].x, a = _m0[147].x.
"fragment float4 ubo_oob_loop(constant Desc11& d [[buffer(0)]]) {\n"
"    uint clamp_max = max((*d.gal_ubo_len)._m0[11u], 1u) - 1u;\n"
"    int limit = as_type<int>((*d.fp_c14)._m0[144].x);\n"
"    float acc = 0.0f;\n"
"    if (0 < limit) {\n"
"        int i = 0;\n"
"        do {\n"
"            uint idx = min(uint(i & 15), clamp_max);\n"
"            acc = fma((*d.fp_c14)._m0[idx].x, 0.00001f, acc + 0.000001f);\n"
"            i = i + 1;\n"
"        } while (!(i >= limit));\n"
"    }\n"
"    uint dyn1 = min(1u, clamp_max);\n"
"    float dynv = (*d.fp_c14)._m0[dyn1].y;\n"
"    return float4(clamp(acc, 0.0f, 1.0f), dynv, (*d.fp_c14)._m0[0].x, (*d.fp_c14)._m0[147].x);\n"
"}\n"
// Mirrors ea0819b6b94018ff_b (cb_ext=144, bound=112) and unaligned tail tests.
"fragment float4 ubo_ext_probe(constant Desc6& d [[buffer(0)]]) {\n"
"    return float4((*d.fp_c9)._m0[0].x, (*d.fp_c9)._m0[1].x, (*d.fp_c9)._m0[1].y, (*d.fp_c9)._m0[8].x);\n"
"}\n"
"struct MeshV { float4 pos [[position]]; float4 col [[user(locn0)]]; };\n"
"using TriMesh = metal::mesh<MeshV, void, 3, 1, topology::triangle>;\n"
"[[mesh]] void mesh_ubo_probe(constant Desc6& d [[buffer(0)]], TriMesh out) {\n"
"    out.set_primitive_count(1);\n"
"    float4 c = float4((*d.fp_c9)._m0[0].x, (*d.fp_c9)._m0[1].x, (*d.fp_c9)._m0[1].y, (*d.fp_c9)._m0[8].x);\n"
"    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
"    for (uint i = 0; i < 3; i++) { MeshV v; v.pos = float4(p[i], 0, 1); v.col = c; out.set_vertex(i, v); }\n"
"    out.set_index(0, 0); out.set_index(1, 1); out.set_index(2, 2);\n"
"}\n"
"fragment float4 mesh_fs_pass(MeshV in [[stage_in]]) { return in.col; }\n";

static NvShader *make_fs_loop(id<MTLLibrary> lib, const char *key) {
    NvShader *fs = [NvShader new]; fs->stage = 1;
    fs->fn = [lib newFunctionWithName:@"ubo_oob_loop"]; REQUIRE(fs->fn);
    strlcpy(fs->key, key, sizeof fs->key);
    fs->rf.pos_attr = -1; fs->rf.has_user = 2; fs->rf.nb = 2;
    fs->rf.b = calloc(2, sizeof *fs->rf.b); REQUIRE(fs->rf.b);
    fs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_CBUF, .reg = 11, .aid = 0};
    fs->rf.b[1] = (nvn_rbind){.kind = NVN_RB_UBOLEN, .reg = 0, .aid = 1};
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(fs->ae);
    fs->arg_len = fs->ae.encodedLength;
    fs->rf.color_known = 1; fs->rf.color_mask = 1;
    return fs;
}

static NvShader *make_fs_ext(id<MTLLibrary> lib, const char *key, int reg, uint32_t ext) {
    NvShader *fs = [NvShader new]; fs->stage = 1;
    fs->fn = [lib newFunctionWithName:@"ubo_ext_probe"]; REQUIRE(fs->fn);
    strlcpy(fs->key, key, sizeof fs->key);
    fs->rf.pos_attr = -1; fs->rf.has_user = 2; fs->rf.nb = 1;
    fs->rf.b = calloc(1, sizeof *fs->rf.b); REQUIRE(fs->rf.b);
    fs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_CBUF, .reg = reg, .aid = 0};
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(fs->ae);
    fs->arg_len = fs->ae.encodedLength;
    fs->rf.color_known = 1; fs->rf.color_mask = 1;
    if (reg >= 0 && reg < 16) fs->cb_ext[reg] = ext;
    return fs;
}

static void make_rt(tex_t *rt, pool_t *pool, size_t off) {
    memset(rt, 0, sizeof *rt); rt->magic = MAGIC('T', 'E', 'X', 0); rt->serial = nvn_new_serial();
    rt->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .flags = NVN_TEXTURE_FLAGS_IMAGE, .width = 16, .height = 16, .depth = 1, .levels = 1};
    rt->pool = pool; rt->off = off; rt->mem = pool->mem + off;
    nvn_tex_layout(&rt->d, &rt->L); nvn_be_tex_init(rt); REQUIRE(tex_mtl(rt));
}

static void read_pixel0(tex_t *rt, uint8_t rgba[4]) {
    id<MTLTexture> image = tex_mtl(rt); REQUIRE(image);
    id<MTLBuffer> buf = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(buf);
    memset(buf.contents, 0xa5, 256);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; REQUIRE(q);
    id<MTLCommandBuffer> cb = [q commandBuffer]; REQUIRE(cb);
    id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder]; REQUIRE(enc);
    [enc copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(1, 1, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    memcpy(rgba, buf.contents, 4);
}

static void set_rt(tex_t *rt) {
    rp_flush();
    memset(&R.rt, 0, sizeof R.rt);
    R.rt.n = 1; R.rt.color[0] = rt; R.has_rt = 1; g_pso_dirty = 1; args_dirty_all();
}

static int approx_u8(uint8_t got, uint8_t want) {
    int d = (int)got - (int)want; return d >= -2 && d <= 2;
}

int main(void) {
    @autoreleasepool {
        char map[] = "/tmp/t_ubo_map_XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd);
        char user[] = "/tmp/t_ubo_user_XXXXXX"; fd = mkstemp(user); REQUIRE(fd >= 0); close(fd);
        setenv("DM_NVN_SHMAP", map, 1);
        setenv("DM_PSO_USER", user, 1);
        setenv("DM_PSO_ARCHIVE", "0", 1);
        setenv("DM_NVN_QUARANTINE", "0", 1);
        mtl_init();
        printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
        const op_hdr empty = {OP_END, sizeof(op_hdr)};
        nvn_be_exec((const uint8_t *)&empty);

        NSError *err = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&err];
        if (!lib) fprintf(stderr, "MSL err: %s\n", err.localizedDescription.UTF8String);
        REQUIRE(lib);

        NvShader *vs = [NvShader new]; vs->stage = 0;
        vs->fn = [lib newFunctionWithName:@"tri"]; REQUIRE(vs->fn);
        strlcpy(vs->key, "1111111111111111_b", sizeof vs->key);
        vs->rf.pos_attr = -1; vs->rf.has_user = 1;

        NvProg *loop_pr = [NvProg new]; loop_pr->sh[0] = vs; loop_pr->sh[1] = make_fs_loop(lib, "2222222222222222_b");
        // The loop shader's slot 11 also reads dynamically, so offline gives no whole-slot extent (cb_ext[11] = 0): C1Cb writes the reach of its constant reads,
        //   _m0[147] → 148 × 16 = 2368 bytes, as c11:2368 (cb_cext). That, not a 64 KB guess, is what the host pads a shorter binding to
        loop_pr->sh[1]->cb_cext[11] = 2368;
        // Plain shader with no known reach (cb_ext = cb_cext = 0): its binding is used in place, never redirected to a padded copy (#2237 review: the 64 KB guess
        //   re-allocated and zeroed 64 KB per bind and moved every such binding off its buffer)
        NvProg *noext_pr = [NvProg new]; noext_pr->sh[0] = vs; noext_pr->sh[1] = make_fs_ext(lib, "5555555555555555_b", 6, 0);
        prog_t noext_p = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(noext_p.serial, noext_pr);
        prog_t loop_p = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(loop_p.serial, loop_pr);

        NvProg *ext_pr = [NvProg new]; ext_pr->sh[0] = vs; ext_pr->sh[1] = make_fs_ext(lib, "3333333333333333_b", 6, 144);
        prog_t ext_p = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(ext_p.serial, ext_pr);

        NvProg *tail_pr = [NvProg new]; tail_pr->sh[0] = vs; tail_pr->sh[1] = make_fs_ext(lib, "4444444444444444_b", 6, 32);
        prog_t tail_p = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(tail_p.serial, tail_pr);

        uint8_t *memory = NULL;
        REQUIRE(!posix_memalign((void **)&memory, 65536, 1 << 20));
        memset(memory, 0, 1 << 20);
        pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
        *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = 1 << 20};
        nvn_be_pool_add(memory, 1 << 20);

        // Separate 64KB pool to test UBO right at the end of a Metal buffer.
        uint8_t *edge_mem = NULL;
        REQUIRE(!posix_memalign((void **)&edge_mem, 65536, 65536));
        memset(edge_mem, 0, 65536);
        pool_t *edge_pool = calloc(1, sizeof *edge_pool); REQUIRE(edge_pool);
        *edge_pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = edge_mem, .size = 65536};
        nvn_be_pool_add(edge_mem, 65536);

        tex_t rt; make_rt(&rt, pool, 131072);
        p_draw tri = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1};
        uint32_t poison_f1 = 0x3f800000u; // 1.0f = 1065353216 as int32
        float f_quarter = 0.25f, f_half = 0.5f, f_three_q = 0.75f;

        // Case 1 + Case 5: args_ubo_patchable fast path AND unclamped const read at +2304 with 16B UBO.
        uint8_t *ubo_norm = memory;
        memset(ubo_norm, 0, 4096);
        memcpy(ubo_norm + 0, &f_half, 4);
        memcpy(ubo_norm + 4, &f_quarter, 4);
        memcpy(ubo_norm + 16 + 4, &f_half, 4); // vec4[1].y = 0.5 (should not be picked when ubolen=1)

        uint8_t *ubo_short = memory + 65536;
        memset(ubo_short, 0, 8192);
        memcpy(ubo_short + 0, &f_three_q, 4);
        memcpy(ubo_short + 4, &f_quarter, 4);
        memcpy(ubo_short + 16 + 4, &f_half, 4);
        memcpy(ubo_short + 2304, &poison_f1, 4); // +2304: _m0[144].x poison loop limit
        memcpy(ubo_short + 2352, &poison_f1, 4); // +2352: _m0[147].x poison

        nvn_be_sub_begin(); state_reset();
        S.prog = &loop_p;
        S.ubo[1][11] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_norm, .size = 256};
        set_rt(&rt);
        draw(&tri, NULL);
        // Switch only UBO binding to short 16B buffer -> hits args_ubo_patchable!
        uint64_t patch_before = g_stat_args_patch;
        S.ubo[1][11] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_short, .size = 16};
        g_args_ubo[1] = 1;
        draw(&tri, NULL);
        uint64_t fence = nvn_be_sub_commit();
        int waited = nvn_be_wait(fence, 10000000000ull);
        int cb_err = mtl_last_commit_error();
        CHECK(waited && !cb_err && !mtl_gpu_halted(), "16B short UBO (+2304 poison, patchable) completes without GPU hang (waited=%d err=%d halted=%d)", waited, cb_err, mtl_gpu_halted());
        if (!cb_err && !mtl_gpu_halted()) {
            uint8_t px[4] = {0}; read_pixel0(&rt, px);
            CHECK(g_stat_args_patch > patch_before, "second draw hits args_ubo_patchable fast path");
            CHECK(approx_u8(px[0], 0) && approx_u8(px[1], 64) && approx_u8(px[2], 191) && approx_u8(px[3], 0),
                  "16B short UBO sees _m0[0].y=0.25 (ubolen=1), _m0[0].x=0.75, _m0[144,147]=0 (got %u,%u,%u,%u)", px[0], px[1], px[2], px[3]);
        } else {
            // Stop cleanly if GPU was halted by the bug.
            unlink(map); unlink(user);
            printf("✗ t_nvn_ubo_bounds: aborted early on GPU hang (%u checks, %u failures)\n", checks, failures);
            return 1;
        }

        // Case 0: no known reach (cb_ext = cb_cext = 0) → the binding is used in place: no padded copy is made. Old logic padded every such slot to 64 KB
        {
            uint8_t *ubo_plain = memory + 3 * 65536; memset(ubo_plain, 0, 256);
            nvn_be_sub_begin(); state_reset(); S.prog = &noext_p; set_rt(&rt);
            S.ubo[1][6] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_plain, .size = 112};
            uint64_t made0 = g_cb_pad_made;
            draw(&tri, NULL);
            int w0 = nvn_be_wait(nvn_be_sub_commit(), 10000000000ull);
            CHECK(w0 && cb_want(noext_pr->sh[1], 6) == 0 && g_cb_pad_made == made0,
                  "cb_ext = cb_cext = 0: cb_want 0, no padded copy made (made %llu, old logic: one 64 KB copy per bind)", (unsigned long long)(g_cb_pad_made - made0));
        }

        // Case 2: cb_ext[6]=144, bound=112, poison at +128 (_m0[8].x).
        uint8_t *ubo_ext = memory + 81920;
        memset(ubo_ext, 0, 256);
        memcpy(ubo_ext + 0, &f_quarter, 4);
        memcpy(ubo_ext + 16, &f_half, 4);
        memcpy(ubo_ext + 128, &f_three_q, 4);
        nvn_be_sub_begin(); state_reset();
        S.prog = &ext_p;
        S.ubo[1][6] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_ext, .size = 112};
        set_rt(&rt); draw(&tri, NULL);
        fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull));
        cb_err = mtl_last_commit_error();
        uint8_t px2[4] = {0}; read_pixel0(&rt, px2);
        CHECK(!cb_err && approx_u8(px2[0], 64) && approx_u8(px2[1], 128) && approx_u8(px2[3], 0),
              "cb_ext=144 bound=112 zeros +128 (got %u,%u,%u,%u)", px2[0], px2[1], px2[2], px2[3]);

        // Case 3: unaligned size=20, cb_ext=32, poison at +20 (+16..19 is _m0[1].x, +20..23 is _m0[1].y).
        uint8_t *ubo_tail = memory + 86016;
        memset(ubo_tail, 0, 64);
        memcpy(ubo_tail + 0, &f_quarter, 4);
        memcpy(ubo_tail + 16, &f_half, 4);
        memcpy(ubo_tail + 20, &f_three_q, 4);
        nvn_be_sub_begin(); state_reset();
        S.prog = &tail_p;
        S.ubo[1][6] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_tail, .size = 20};
        set_rt(&rt); draw(&tri, NULL);
        fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull));
        cb_err = mtl_last_commit_error();
        uint8_t px3[4] = {0}; read_pixel0(&rt, px3);
        CHECK(!cb_err && approx_u8(px3[0], 64) && approx_u8(px3[1], 128) && approx_u8(px3[2], 0),
              "unaligned size=20 keeps _m0[1].x=0.5 and zeros _m0[1].y at +20 (got %u,%u,%u,%u)", px3[0], px3[1], px3[2], px3[3]);

        // Case 4: deferred inline update (ubd_covers) over short 16B UBO inside open pass.
        uint8_t *ubo_def = memory + 90112;
        memset(ubo_def, 0, 8192);
        memcpy(ubo_def + 2304, &poison_f1, 4);
        uint8_t upd_16[16]; memset(upd_16, 0, sizeof upd_16);
        memcpy(upd_16 + 0, &f_half, 4);
        memcpy(upd_16 + 4, &f_quarter, 4);
        uint32_t upd_poison[1024];
        for (int i = 0; i < 1024; i++) upd_poison[i] = poison_f1;

        nvn_be_sub_begin(); state_reset();
        S.prog = &loop_p;
        S.ubo[1][11] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_def, .size = 16};
        set_rt(&rt);
        rp_begin(); REQUIRE(g_enc); // Keep pass open so mtl_sub_update defers into g_ubd!
        mtl_sub_update(upd_16, (uint64_t)(uintptr_t)ubo_def, 16);
        // Place poison updates right after in g_ubs_buf (and at +2304 in guest range).
        mtl_sub_update(upd_poison, (uint64_t)(uintptr_t)(ubo_def + 4096), sizeof upd_poison);
        draw(&tri, NULL);
        fence = nvn_be_sub_commit();
        waited = nvn_be_wait(fence, 10000000000ull);
        cb_err = mtl_last_commit_error();
        CHECK(waited && !cb_err && !mtl_gpu_halted(), "deferred update over 16B UBO does not hang GPU");
        if (!cb_err && !mtl_gpu_halted()) {
            uint8_t px4[4] = {0}; read_pixel0(&rt, px4);
            CHECK(approx_u8(px4[0], 0) && approx_u8(px4[1], 64) && approx_u8(px4[2], 128) && approx_u8(px4[3], 0),
                  "deferred 16B UBO sees updated _m0[0].x=0.5 and _m0[144,147]=0 (got %u,%u,%u,%u)", px4[0], px4[1], px4[2], px4[3]);
        }

        // Case 6: short 16B UBO positioned at the very end of a 64KB Metal buffer pool.
        uint8_t *ubo_edge = edge_mem + 65536 - 16;
        memcpy(ubo_edge + 0, &f_quarter, 4);
        memcpy(ubo_edge + 4, &f_half, 4);
        nvn_be_sub_begin(); state_reset();
        S.prog = &loop_p;
        S.ubo[1][11] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_edge, .size = 16};
        set_rt(&rt); draw(&tri, NULL);
        fence = nvn_be_sub_commit();
        waited = nvn_be_wait(fence, 10000000000ull);
        cb_err = mtl_last_commit_error();
        CHECK(waited && !cb_err && !mtl_gpu_halted(), "short 16B UBO at pool end does not fault or hang");
        if (!cb_err && !mtl_gpu_halted()) {
            uint8_t px6[4] = {0}; read_pixel0(&rt, px6);
            CHECK(approx_u8(px6[0], 0) && approx_u8(px6[1], 128) && approx_u8(px6[2], 64) && approx_u8(px6[3], 0),
                  "pool-end 16B UBO reads valid head and zero tail (got %u,%u,%u,%u)", px6[0], px6[1], px6[2], px6[3]);
        }

        // Case 7: GPU-written (mtl_sub_fill) 16B UBO with +2304 poison, followed by draw in same submission.
        uint8_t *ubo_gpuw = memory + 102400;
        memset(ubo_gpuw, 0, 8192);
        memcpy(ubo_gpuw + 2304, &poison_f1, 4);
        nvn_be_sub_begin(); state_reset();
        mtl_sub_fill((uint64_t)(uintptr_t)ubo_gpuw, 16, 0x3e800000u); // 0.25f across all 4 floats
        S.prog = &loop_p;
        S.ubo[1][11] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_gpuw, .size = 16};
        set_rt(&rt); draw(&tri, NULL);
        fence = nvn_be_sub_commit();
        waited = nvn_be_wait(fence, 10000000000ull);
        cb_err = mtl_last_commit_error();
        CHECK(waited && !cb_err && !mtl_gpu_halted(), "GPU-filled 16B UBO with +2304 poison does not hang");
        if (!cb_err && !mtl_gpu_halted()) {
            uint8_t px7[4] = {0}; read_pixel0(&rt, px7);
            CHECK(approx_u8(px7[0], 0) && approx_u8(px7[1], 64) && approx_u8(px7[2], 64) && approx_u8(px7[3], 0),
                  "GPU-filled 16B UBO sees filled 0.25 and zero +2304/+2352 (got %u,%u,%u,%u)", px7[0], px7[1], px7[2], px7[3]);
        }

        // Case 8: native mesh draw whose mesh stage binds a short GPU-filled UBO while a render pass is open.
        // Previously mtk_encode bound stage 3/4 after draw()'s g_enc != en check, so blit() ended the pass and left
        // g_blit (a compute encoder on Metal 4) open, crashing rec_thread with unrecognized selector on drawMeshThreadgroups*.
        if (g_mesh_ok) {
            NvShader *ms = [NvShader new]; ms->stage = 4; ms->mesh_kind = 2; ms->mesh_task = 0; ms->mesh_threads = 1;
            ms->fn = [lib newFunctionWithName:@"mesh_ubo_probe"]; REQUIRE(ms->fn);
            strlcpy(ms->key, "6666666666666666_b", sizeof ms->key);
            ms->rf.pos_attr = -1; ms->rf.nb = 1;
            ms->rf.b = calloc(1, sizeof *ms->rf.b); REQUIRE(ms->rf.b);
            ms->rf.b[0] = (nvn_rbind){.kind = NVN_RB_CBUF, .reg = 6, .aid = 0};
            ms->ae = [ms->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(ms->ae);
            ms->arg_len = ms->ae.encodedLength;
            ms->cb_ext[6] = 144;

            NvShader *mfs = [NvShader new]; mfs->stage = 1;
            mfs->fn = [lib newFunctionWithName:@"mesh_fs_pass"]; REQUIRE(mfs->fn);
            strlcpy(mfs->key, "7777777777777777_b", sizeof mfs->key);
            mfs->rf.pos_attr = -1; mfs->rf.color_known = 1; mfs->rf.color_mask = 1;

            NvProg *mesh_pr = [NvProg new]; mesh_pr->sh[4] = ms; mesh_pr->sh[1] = mfs;
            prog_t mesh_p = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(mesh_p.serial, mesh_pr);

            uint8_t *ubo_mesh = memory + 114688;
            memset(ubo_mesh, 0, 256);
            memcpy(ubo_mesh + 128, &f_three_q, 4);   // poison at _m0[8].x (past 16B binding)
            nvn_be_sub_begin(); state_reset();
            mtl_sub_fill((uint64_t)(uintptr_t)ubo_mesh, 16, 0x3f000000u);   // 0.5f
            S.prog = &mesh_p;
            S.ubo[4][6] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_mesh, .size = 16};
            set_rt(&rt);
            rp_begin(); REQUIRE(g_enc);   // open render pass before mesh draw so blit() inside mtk_bind splits it
            p_draw mdw = {.prim = DM_PRIM_MESH_TASKS, .count = 1, .first = 0, .instances = 1};
            mesh_tasks_draw(&mdw);
            fence = nvn_be_sub_commit();
            waited = nvn_be_wait(fence, 10000000000ull);
            cb_err = mtl_last_commit_error();
            CHECK(waited && !cb_err && !mtl_gpu_halted(), "mesh draw with short GPU-filled UBO splits pass and retries without crashing");
            if (!cb_err && !mtl_gpu_halted()) {
                uint8_t px8[4] = {0}; read_pixel0(&rt, px8);
                CHECK(approx_u8(px8[0], 128) && approx_u8(px8[1], 0) && approx_u8(px8[2], 0) && approx_u8(px8[3], 0),
                      "mesh draw short GPU-filled UBO reads 0.5 and zero-padded tail (got %u,%u,%u,%u)", px8[0], px8[1], px8[2], px8[3]);
            }
        }

        // Case 9: short UBO with gw_live == 1 (prior in-flight GPU write): retry after blit() must reuse the GPU-copied
        // cbuf_pad_alloc entry instead of missing cache again and dropping the draw after 2 retries.
        {
            uint8_t *ubo_gw = memory + 122880;
            memset(ubo_gw, 0, 256);
            memcpy(ubo_gw + 0, &f_quarter, 4);
            memcpy(ubo_gw + 16, &f_half, 4);
            memcpy(ubo_gw + 128, &f_three_q, 4);
            // rt already holds (128, 0, 0, 0) from Case 8 (or prior case), distinct from (64, 128, 0, 0) below.
            nvn_be_sub_begin(); state_reset();
            set_rt(&rt);
            gw_put((uint64_t)(uintptr_t)ubo_gw, (uint64_t)(uintptr_t)ubo_gw + 64, g_fence + 100, g_done);
            S.prog = &ext_p;
            S.ubo[1][6] = (p_bind_buf){.addr = (uint64_t)(uintptr_t)ubo_gw, .size = 112};
            rp_begin(); REQUIRE(g_enc);
            uint64_t made_before = g_cb_pad_made;
            draw(&tri, NULL);
            uint64_t made_delta = g_cb_pad_made - made_before;
            fence = nvn_be_sub_commit();
            waited = nvn_be_wait(fence, 10000000000ull);
            cb_err = mtl_last_commit_error();
            uint8_t px9[4] = {0}; read_pixel0(&rt, px9);
            CHECK(waited && !cb_err && made_delta == 1 && approx_u8(px9[0], 64) && approx_u8(px9[1], 128) && approx_u8(px9[3], 0),
                  "gw_live short UBO reuses GPU-copied cbuf_pad_alloc entry on retry (made=%llu, px=%u,%u,%u,%u)",
                  (unsigned long long)made_delta, px9[0], px9[1], px9[2], px9[3]);
        }

        unlink(map); unlink(user);
    }
    printf("%s t_nvn_ubo_bounds: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}
