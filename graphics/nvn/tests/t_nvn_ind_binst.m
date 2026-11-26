// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

// GPU indirect draw baseInstance -> c0 + 0x644 copy (nvn_mtl.m binst_run / binst_take):
// Tests real public NVN recording -> Metal 4 & Metal 3 replay -> GPU readback.
// Also serves as negative control that shaders with drv_read[0] == 0 still use mdx_next.
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <sys/wait.h>

extern void *h_nvnBootstrapLoader(const char *name);

static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static uint8_t *storage;
static unsigned checks, failures;

enum {
    POOL_SIZE = 32 << 20,
    CMD_SIZE = 1 << 20,
    CMD_OFF = 0,
    IND_OFF = 2 << 20,
    CFG_OFF = 3 << 20,
    IDX_OFF = 4 << 20,
    SSBO_OFF = 5 << 20,
    SSBO_SIZE = 0x400,
    READBACK_OFF = 6 << 20,
    TEX_OFF = 8 << 20,
    W = 16,
    H = 4,
};

#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; \
    printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); REQUIRE(e != NULL); return e; }
#define API(name) ((NVNT_##name)load(#name))

static NSString *const kShaderSrc = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct CsArgs { device uint *out [[id(0)]]; const device uint *cfg [[id(1)]]; };\n"
"kernel void cs_writer(constant CsArgs &a [[buffer(0)]]) {\n"
"  uint off = a.cfg[0]; uint n = a.cfg[1];\n"
"  for (uint i = 0; i < n; i++) a.out[off + i] = a.cfg[2 + i];\n"
"}\n"
"struct VsC0Args { const device uint *c0 [[id(0)]]; const device uint *s0 [[id(1)]]; };\n"
"struct VOut { float4 pos [[position]]; uint4 val [[flat, user(locn0)]]; };\n"
"static float4 slot_pos(uint vid) {\n"
"  uint pix = vid / 3u; uint c = vid % 3u;\n"
"  float px = float(pix) + (c == 0 ? 0.0f : c == 1 ? 1.0f : 0.5f);\n"
"  float py = (c == 2 ? 3.0f : -1.0f);\n"
"  return float4(px / 16.0f * 2.0f - 1.0f, py / 4.0f * 2.0f - 1.0f, 0.0f, 1.0f);\n"
"}\n"
"vertex VOut vs_c0(constant VsC0Args &a [[buffer(0)]], uint vid [[vertex_id]]) {\n"
"  VOut o; o.pos = slot_pos(vid);\n"
"  o.val = uint4(a.c0[0x644u / 4u], a.c0[0x610u / 4u], a.c0[0x110u / 4u], a.c0[0x118u / 4u]);\n"
"  return o;\n"
"}\n"
"vertex VOut vs_plain(uint vid [[vertex_id]]) {\n"
"  VOut o; o.pos = slot_pos(vid); o.val = uint4(0xc0000001u, 0u, 0u, 0u); return o;\n"
"}\n"
"fragment uint4 fs_u4(VOut in [[stage_in]]) { return in.val; }\n";

static NvShader *make_shader(id<MTLLibrary> lib, NSString *name, int stage, const char *key, int drv0_c0) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:name]; REQUIRE(s->fn != nil);
    strlcpy(s->key, key, sizeof s->key);
    s->rf.pos_attr = -1;
    char err[256] = "";
    if (stage == 5) {
        REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[
            @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES, @"msl_name": @"out" },
            @{ @"kind": @"cbuf", @"reg": @0, @"arg_id": @1, @"msl_name": @"cfg" }
        ] }, &s->rf, err, sizeof err));
        s->ae = [s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae != nil); s->arg_len = s->ae.encodedLength;
    } else if (stage == 0) {
        s->rf.has_user = 1;
        s->rf.user_out = 1u;
        if (drv0_c0) {
            REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[
                @{ @"kind": @"drvcb", @"bank": @0, @"arg_id": @0, @"msl_name": @"vp_c0" },
                @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @1, @"rw": @NO, @"msl_name": @"vp_s0" }
            ], @"user_out": @[@0] }, &s->rf, err, sizeof err));
            REQUIRE(s->rf.drv_read[0] == 1);
            s->ae = [s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae != nil); s->arg_len = s->ae.encodedLength;
        } else {
            REQUIRE(!nvn_refl_from_json(@{ @"route": @"B", @"bindings": @[], @"user_out": @[@0] }, &s->rf, err, sizeof err));
            REQUIRE(s->rf.drv_read[0] == 0);
        }
    } else {
        s->rf.has_user = 2;
        s->rf.user_in = 1u;
        s->rf.color_known = 1;
        s->rf.color_mask = 1;
        s->fn_u = s->fn;
        s->u_mask = 1;
    }
    return s;
}

static NVNprogram *make_program(NvShader *vs, NvShader *fs, NvShader *cs) {
    static NVNprogram programs[8]; static unsigned count; REQUIRE(count < 8);
    NVNprogram *p = &programs[count++]; REQUIRE(API(nvnProgramInitialize)(p, &device));
    prog_t *guest = (prog_t *)p; guest->serial = nvn_new_serial(); NvProg *native = [NvProg new]; native->gp = guest;
    native->sh[0] = vs; native->sh[1] = fs; native->sh[5] = cs;
    serial_put(guest->serial, native);
    return p;
}

static void setup_rt(NVNtexture *rt) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, W, H);
    API(nvnTextureBuilderSetLevels)(&b, 1); API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA32UI);
    API(nvnTextureBuilderSetFlags)(&b, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    size_t sz = API(nvnTextureBuilderGetStorageSize)(&b);
    REQUIRE(TEX_OFF + sz <= POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)TEX_OFF);
    REQUIRE(API(nvnTextureInitialize)(rt, &b));
}

static void draw_state(NVNtexture *rt) {
    NVNpolygonState p; API(nvnPolygonStateSetDefaults)(&p); API(nvnCommandBufferBindPolygonState)(&commands, &p);
    NVNdepthStencilState d; API(nvnDepthStencilStateSetDefaults)(&d); API(nvnCommandBufferBindDepthStencilState)(&commands, &d);
    NVNcolorState c; API(nvnColorStateSetDefaults)(&c); API(nvnCommandBufferBindColorState)(&commands, &c);
    NVNchannelMaskState m; API(nvnChannelMaskStateSetDefaults)(&m); API(nvnCommandBufferBindChannelMaskState)(&commands, &m);
    NVNmultisampleState ms; API(nvnMultisampleStateSetDefaults)(&ms); API(nvnCommandBufferBindMultisampleState)(&commands, &ms);
    const NVNtexture *ts[1] = {rt}; API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL);
    API(nvnCommandBufferSetViewport)(&commands, 0, 0, W, H);
    API(nvnCommandBufferSetScissor)(&commands, 0, 0, W, H);
}

static void begin_rec(void) {
    API(nvnCommandBufferAddCommandMemory)(&commands, &pool, CMD_OFF, CMD_SIZE);
    API(nvnCommandBufferBeginRecording)(&commands);
}

static void submit_and_finish(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h);
    API(nvnQueueFinish)(&queue);
    REQUIRE(mtl_last_commit_error() == 0);
}

static void copy_row0(NVNtexture *rt, NVNbufferAddress readback_addr) {
    begin_rec();
    NVNcopyRegion reg = {0, 0, 0, W, 1, 1};
    API(nvnCommandBufferCopyTextureToBuffer)(&commands, rt, NULL, &reg, readback_addr, 0);
    submit_and_finish();
}

static const uint32_t *pix(int x) { return (const uint32_t *)(storage + READBACK_OFF) + 4 * x; }

static void gpu_write_words(NVNprogram *cs, NVNbufferAddress ind_addr, NVNbufferAddress cfg_addr, uint32_t word_off, const uint32_t *vals, uint32_t n) {
    uint32_t buf[32] = {word_off, n};
    REQUIRE(n <= 30);
    memcpy(buf + 2, vals, n * 4);
    API(nvnCommandBufferBindProgram)(&commands, cs, NVN_SHADER_STAGE_COMPUTE_BIT);
    API(nvnCommandBufferBindStorageBuffer)(&commands, NVN_SHADER_STAGE_COMPUTE, 0, ind_addr, 4096);
    API(nvnCommandBufferBindUniformBuffer)(&commands, NVN_SHADER_STAGE_COMPUTE, 0, cfg_addr, 128);
    API(nvnCommandBufferUpdateUniformBuffer)(&commands, cfg_addr, 128, 0, sizeof buf, buf);
    API(nvnCommandBufferDispatchCompute)(&commands, 1, 1, 1);
    API(nvnCommandBufferBarrier)(&commands, NVN_BARRIER_ORDER_INDIRECT_DATA_BIT);
}

static int child(int metal3) {
    alarm(60);
    mtl_init();
    REQUIRE(g_m3 == metal3);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(!posix_memalign((void **)&storage, 16384, POOL_SIZE)); memset(storage, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
    REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t ctrl[16384]; API(nvnCommandBufferAddControlMemory)(&commands, ctrl, sizeof ctrl);

    NVNtexture rt; setup_rt(&rt);
    NSError *err = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:kShaderSrc options:nil error:&err];
    if (!lib) fprintf(stderr, "MSL compile error: %s\n", err.localizedDescription.UTF8String);
    REQUIRE(lib != nil);
    NvShader *cs_w = make_shader(lib, @"cs_writer", 5, "0000000000000001", 0);
    NvShader *vs_0 = make_shader(lib, @"vs_c0", 0, "0000000000000002", 1);
    NvShader *vs_p = make_shader(lib, @"vs_plain", 0, "0000000000000003", 0);
    NvShader *fs_0 = make_shader(lib, @"fs_u4", 1, "0000000000000004", 0);
    NVNprogram *p_cs = make_program(NULL, NULL, cs_w);
    NVNprogram *p_c0 = make_program(vs_0, fs_0, NULL);
    NVNprogram *p_plain = make_program(vs_p, fs_0, NULL);

    uint32_t *idx = (uint32_t *)(storage + IDX_OFF);
    for (uint32_t i = 0; i < 48; i++) idx[i] = i;

    const NVNbufferAddress pool_gpu = API(nvnMemoryPoolGetBufferAddress)(&pool);
    const NVNbufferAddress ind_addr = pool_gpu + IND_OFF;
    const NVNbufferAddress cfg_addr = pool_gpu + CFG_OFF;
    const NVNbufferAddress ib_addr = pool_gpu + IDX_OFF;
    const NVNbufferAddress ssbo_addr = pool_gpu + SSBO_OFF;
    const NVNbufferAddress rb_addr = pool_gpu + READBACK_OFF;
    const uint32_t want_ssbo_lo = (uint32_t)(uintptr_t)(storage + SSBO_OFF);
    const uint32_t want_pts = 0x44ffe000u;   // 2047.0f
    const uint32_t sent[4] = {0x0055aa00u, 0x0055aa01u, 0x0055aa02u, 0x0055aa03u};

    // Case 1 + Case 2: back-to-back GPU-written indirect draws (array + indexed + array) then direct instanced draw in ONE pass.
    uint32_t *ind = (uint32_t *)(storage + IND_OFF);
    // Word offsets: 0..3 arr0, 8..12 idx1, 16..19 arr2, all poisoned with stale CPU baseInstance 0x0badf00d
    uint32_t stale0[4] = {3, 1, 0, 0x0badf00du}; memcpy(ind + 0, stale0, 16);
    uint32_t stale1[5] = {3, 1, 3, 0, 0x0badf00du}; memcpy(ind + 8, stale1, 20);
    uint32_t stale2[4] = {3, 1, 6, 0x0badf00du}; memcpy(ind + 16, stale2, 16);

    uint64_t pass0 = g_stat_pass;
    begin_rec();
    const uint32_t gw0[4] = {3, 1, 0, 17}; gpu_write_words(p_cs, ind_addr, cfg_addr, 0, gw0, 4);
    const uint32_t gw1[5] = {3, 1, 3, 0, 42}; gpu_write_words(p_cs, ind_addr, cfg_addr, 8, gw1, 5);
    const uint32_t gw2[4] = {3, 1, 6, 99}; gpu_write_words(p_cs, ind_addr, cfg_addr, 16, gw2, 4);
    draw_state(&rt);
    API(nvnCommandBufferClearColorui)(&commands, 0, sent, 0xf);
    API(nvnCommandBufferBindProgram)(&commands, p_c0, NVN_SHADER_STAGE_VERTEX_BIT | NVN_SHADER_STAGE_FRAGMENT_BIT);
    API(nvnCommandBufferBindStorageBuffer)(&commands, NVN_SHADER_STAGE_VERTEX, 0, ssbo_addr, SSBO_SIZE);
    API(nvnCommandBufferDrawArraysIndirect)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, ind_addr + 0 * 4);
    API(nvnCommandBufferDrawElementsIndirect)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_INT, ib_addr, ind_addr + 8 * 4);
    API(nvnCommandBufferDrawArraysIndirect)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, ind_addr + 16 * 4);
    API(nvnCommandBufferDrawElementsInstanced)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_INT, 3, ib_addr + 9 * 4, 0, 5, 1);
    submit_and_finish();
    uint64_t passes12 = g_stat_pass - pass0;
    copy_row0(&rt, rb_addr);

    VERIFY(passes12 == 1, "M%d Case 1+2 back-to-back indirect + direct draws stay in 1 pass (got %llu)", metal3 ? 3 : 4, (unsigned long long)passes12);
    VERIFY(pix(0)[0] == 17 && pix(0)[1] == want_pts && pix(0)[2] == want_ssbo_lo && pix(0)[3] == SSBO_SIZE,
           "M%d Case 1 draw 0 (DrawArraysIndirect) c0={%u, %#x, %#x, %u}", metal3 ? 3 : 4, pix(0)[0], pix(0)[1], pix(0)[2], pix(0)[3]);
    VERIFY(pix(1)[0] == 42 && pix(1)[1] == want_pts && pix(1)[2] == want_ssbo_lo && pix(1)[3] == SSBO_SIZE,
           "M%d Case 1 draw 1 (DrawElementsIndirect) c0={%u, %#x, %#x, %u}", metal3 ? 3 : 4, pix(1)[0], pix(1)[1], pix(1)[2], pix(1)[3]);
    VERIFY(pix(2)[0] == 99 && pix(2)[1] == want_pts && pix(2)[2] == want_ssbo_lo && pix(2)[3] == SSBO_SIZE,
           "M%d Case 1 draw 2 (DrawArraysIndirect) c0={%u, %#x, %#x, %u}", metal3 ? 3 : 4, pix(2)[0], pix(2)[1], pix(2)[2], pix(2)[3]);
    VERIFY(pix(3)[0] == 5 && pix(3)[1] == want_pts && pix(3)[2] == want_ssbo_lo && pix(3)[3] == SSBO_SIZE,
           "M%d Case 2 direct draw after indirect sees own baseInstance=5 (got %u)", metal3 ? 3 : 4, pix(3)[0]);

    // Case 3: MultiDrawElementsIndirectCount (drv_read[0] = 1, max=4, GPU count=2, baseInstance={11, 23, 77, 88}).
    // Words 64..83 hold 4 records of 5 uints, word 96 holds count (CPU stale = 4).
    for (uint32_t k = 0; k < 4; k++) {
        uint32_t r[5] = {3, 1, 3 * (4 + k), 0, 0x0badf00du};
        memcpy(ind + 64 + 5 * k, r, 20);
    }
    ind[96] = 4;
    uint64_t pass_m0 = g_stat_pass;
    begin_rec();
    const uint32_t mcnt = 2; gpu_write_words(p_cs, ind_addr, cfg_addr, 96, &mcnt, 1);
    const uint32_t mrec[20] = {
        3, 1, 12, 0, 11,
        3, 1, 15, 0, 23,
        3, 1, 18, 0, 77,
        3, 1, 21, 0, 88,
    };
    gpu_write_words(p_cs, ind_addr, cfg_addr, 64, mrec, 20);
    draw_state(&rt);
    API(nvnCommandBufferClearColorui)(&commands, 0, sent, 0xf);
    API(nvnCommandBufferBindProgram)(&commands, p_c0, NVN_SHADER_STAGE_VERTEX_BIT | NVN_SHADER_STAGE_FRAGMENT_BIT);
    API(nvnCommandBufferBindStorageBuffer)(&commands, NVN_SHADER_STAGE_VERTEX, 0, ssbo_addr, SSBO_SIZE);
    API(nvnCommandBufferMultiDrawElementsIndirectCount)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_INT, ib_addr,
        ind_addr + 64 * 4, ind_addr + 96 * 4, 4, 20);
    submit_and_finish();
    uint64_t pass_m = g_stat_pass - pass_m0;
    copy_row0(&rt, rb_addr);

    VERIFY(pass_m == 1, "M%d Case 3 MultiDrawElementsIndirectCount (drv_read) stays in 1 pass (got %llu)", metal3 ? 3 : 4, (unsigned long long)pass_m);
    VERIFY(pix(4)[0] == 11 && pix(5)[0] == 23 && pix(6)[0] == sent[0] && pix(7)[0] == sent[0],
           "M%d Case 3 MultiDraw c0 baseInstance got {%u, %u, %#x, %#x} (want {11, 23, sent, sent})", metal3 ? 3 : 4, pix(4)[0], pix(5)[0], pix(6)[0], pix(7)[0]);

    // Case 4 (negative control): vs_plain (drv_read[0] = 0) MultiDraw still uses mdx_next fast path.
    for (uint32_t k = 0; k < 4; k++) {
        uint32_t r[5] = {3, 1, 3 * (8 + k), 0, 100 + k};
        memcpy(ind + 128 + 5 * k, r, 20);
    }
    ind[160] = 4;
    uint64_t mdx0 = g_mdx_fast;
    begin_rec();
    const uint32_t ncnt = 2; gpu_write_words(p_cs, ind_addr, cfg_addr, 160, &ncnt, 1);
    draw_state(&rt);
    API(nvnCommandBufferClearColorui)(&commands, 0, sent, 0xf);
    API(nvnCommandBufferBindProgram)(&commands, p_plain, NVN_SHADER_STAGE_VERTEX_BIT | NVN_SHADER_STAGE_FRAGMENT_BIT);
    API(nvnCommandBufferMultiDrawElementsIndirectCount)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_INT, ib_addr,
        ind_addr + 128 * 4, ind_addr + 160 * 4, 4, 20);
    submit_and_finish();
    uint64_t mdx_delta = g_mdx_fast - mdx0;
    copy_row0(&rt, rb_addr);

    VERIFY(pix(8)[0] == 0xc0000001u && pix(9)[0] == 0xc0000001u && pix(10)[0] == sent[0] && mdx_delta >= 3,
           "M%d Case 4 negative control (drv_read=0): pix={%#x, %#x, %#x} mdx_next delta=%llu", metal3 ? 3 : 4, pix(8)[0], pix(9)[0], pix(10)[0], (unsigned long long)mdx_delta);

    // Case 5: mid-pass barrier + DrawElementsIndirect + MultiDrawElementsIndirectCount after an opening direct draw stay in 1 pass (zero splits).
    uint32_t stale5[5] = {3, 1, 3, 0, 0x0badf00du}; memcpy(ind + 192, stale5, 20);
    for (uint32_t k = 0; k < 4; k++) {
        uint32_t r[5] = {3, 1, 3 * (2 + k), 0, 0x0badf00du};
        memcpy(ind + 200 + 5 * k, r, 20);
    }
    ind[224] = 4;
    uint64_t pass_z0 = g_stat_pass;
    begin_rec();
    const uint32_t gw5[5] = {3, 1, 3, 0, 77}; gpu_write_words(p_cs, ind_addr, cfg_addr, 192, gw5, 5);
    const uint32_t zcnt = 2; gpu_write_words(p_cs, ind_addr, cfg_addr, 224, &zcnt, 1);
    const uint32_t zrec[20] = {
        3, 1, 6, 0, 31,
        3, 1, 9, 0, 63,
        3, 1, 12, 0, 91,
        3, 1, 15, 0, 92,
    };
    gpu_write_words(p_cs, ind_addr, cfg_addr, 200, zrec, 20);
    draw_state(&rt);
    API(nvnCommandBufferClearColorui)(&commands, 0, sent, 0xf);
    API(nvnCommandBufferBindProgram)(&commands, p_c0, NVN_SHADER_STAGE_VERTEX_BIT | NVN_SHADER_STAGE_FRAGMENT_BIT);
    API(nvnCommandBufferBindStorageBuffer)(&commands, NVN_SHADER_STAGE_VERTEX, 0, ssbo_addr, SSBO_SIZE);
    API(nvnCommandBufferDrawElementsInstanced)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_INT, 3, ib_addr, 0, 3, 1);
    API(nvnCommandBufferBarrier)(&commands, NVN_BARRIER_INVALIDATE_TEXTURE_BIT | NVN_BARRIER_ORDER_PRIMITIVES_BIT);
    API(nvnCommandBufferDrawElementsIndirect)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_INT, ib_addr, ind_addr + 192 * 4);
    API(nvnCommandBufferMultiDrawElementsIndirectCount)(&commands, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_INT, ib_addr,
        ind_addr + 200 * 4, ind_addr + 224 * 4, 4, 20);
    submit_and_finish();
    uint64_t pass_z = g_stat_pass - pass_z0;
    copy_row0(&rt, rb_addr);

    VERIFY(pass_z == 1, "M%d Case 5 mid-pass direct + barrier + indirect + MultiDraw stays in 1 pass (got %llu)", metal3 ? 3 : 4, (unsigned long long)pass_z);
    VERIFY(pix(0)[0] == 3 && pix(1)[0] == 77 && pix(2)[0] == 31 && pix(3)[0] == 63 && pix(4)[0] == sent[0],
           "M%d Case 5 zero-split pix={%u, %u, %u, %u, %#x} (want {3, 77, 31, 63, sent})", metal3 ? 3 : 4, pix(0)[0], pix(1)[0], pix(2)[0], pix(3)[0], pix(4)[0]);

    nvn_be_drain();
    printf("%s Metal %d: %u checks, %u failures\n", failures ? "FAIL" : "PASS", metal3 ? 3 : 4, checks, failures);
    return failures != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--child")) return child(atoi(argv[2]));
        REQUIRE(argc == 1);
        unsigned bad = 0;
        for (int metal3 = 0; metal3 <= 1; metal3++) {
            fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
            if (!pid) {
                if (metal3) setenv("NXGAL_BE", "mtl3", 1); else unsetenv("NXGAL_BE");
                setenv("DM_NVN_ENC_THREAD", "0", 1);
                setenv("DM_PRESENT_LINK", "0", 1);
                execl(argv[0], argv[0], "--child", metal3 ? "1" : "0", (char *)NULL);
                _exit(127);
            }
            int st = 0; pid_t w; do { w = waitpid(pid, &st, 0); } while (w < 0 && errno == EINTR);
            REQUIRE(w == pid);
            int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
            printf("%s process Metal %d (status=%d)\n", ok ? "PASS" : "FAIL", metal3 ? 3 : 4, st);
            bad += !ok;
        }
        if (bad) printf("✗ t_nvn_ind_binst：Metal 4 / Metal 3 共 2 路里 %u 路不过\n", bad);
        else printf("✓ t_nvn_ind_binst：Metal 4 / Metal 3 间接绘制 baseInstance 拷入 c0+0x644 与负对照全过\n");
        return bad != 0;
    }
}
