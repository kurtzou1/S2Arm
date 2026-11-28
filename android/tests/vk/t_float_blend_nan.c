// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#define main backend_fixture_main
#define nvn_plat_flag backend_fixture_flag
#include "t_backend_vk.c"
#undef nvn_plat_flag
#undef main

static int use_original_module;

int nvn_plat_flag(const char *name, int dflt) {
    if (use_original_module && !strcmp(name, "nvk_float_blend_nan_guard")) return 0;
    return backend_fixture_flag(name, dflt);
}

struct nan_src_stats {
    uint64_t live, bytes, alloc, freed;
    unsigned seen;
};

static void collect_nan_src_stat(void *user, const char *name, uint64_t value) {
    struct nan_src_stats *st = user;
    if (!strcmp(name, "float_nan_src_live")) { st->live = value; st->seen |= 1u; }
    else if (!strcmp(name, "float_nan_src_bytes")) { st->bytes = value; st->seen |= 2u; }
    else if (!strcmp(name, "float_nan_src_alloc")) { st->alloc = value; st->seen |= 4u; }
    else if (!strcmp(name, "float_nan_src_freed")) { st->freed = value; st->seen |= 8u; }
}

static struct nan_src_stats read_nan_src_stats(void) {
    struct nan_src_stats st = {0};
    nvn_gpu_stats(collect_nan_src_stat, &st, 0);
    CHECK(st.seen == 0xfu, "nvn_gpu_stats missing float_nan_src_* keys: mask=0x%x", st.seen);
    return st;
}

static nvn_gpu_shader load_stage(const char *dir, const char *name, nvn_gpu_stage stage, int precompiled, size_t *out_bytes) {
    char path[512];
    size_t bytes = 0;
    snprintf(path, sizeof path, "%s/%s.spv", dir, name);
    void *words = read_file(path, &bytes);
    CHECK(words != NULL, "read %s", name);
    if (!words) return NULL;
    if (out_bytes) *out_bytes = bytes;
    const nvn_gpu_shader_src src = {.stage = stage, .kind = NVN_GPU_BLOB_SPIRV,
        .blob = words, .bytes = bytes, .entry = "main", .precompiled = precompiled};
    nvn_gpu_shader shader = NULL;
    nvn_gpu_err err = {0};
    nvn_gpu_rc result = nvn_gpu_shader_load(&src, &shader, &err);
    CHECK(OK(result) && shader, "load %s: %s", name, err.why);
    free(words);   // Production program consumption also drops its result bytes after loading.
    return shader;
}

static int is_half_nan(uint16_t bits) { return (bits & 0x7c00u) == 0x7c00u && (bits & 0x03ffu); }

static void draw_pixels(nvn_gpu_pipe pipe, int blend, unsigned arm) {
    const float initial[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    nvn_gpu_pass_desc pass = {.w = 4, .h = 4, .layers = 1, .ncolor = 2};
    nvn_gpu_tex tex[2];
    nvn_gpu_buf readback[2];
    for (unsigned i = 0; i < 2; i++) {
        tex[i] = make_tex(4, 4, NVN_FORMAT_RGBA16F, NVN_GPU_TEX_RENDER);
        pass.color[i].view = make_view(tex[i]);
        pass.color[i].load = NVN_GPU_LOAD_CLEAR;
        pass.color[i].store = NVN_GPU_STORE_STORE;
        memcpy(pass.color[i].clear.f, initial, sizeof initial);
        readback[i] = make_buf(128, NVN_GPU_MEM_SHARED, NULL);
    }
    nvn_gpu_cmd cmd = begin_cmd();
    nvn_gpu_pass_begin(cmd, &pass);
    nvn_gpu_dyn dyn = {.origin_ll = 1, .nvp = 1, .has_sc = 1};
    dyn.vp[0][2] = dyn.vp[0][3] = 4.0f;
    dyn.vp[0][5] = 1.0f;
    dyn.sc[2] = dyn.sc[3] = 4;
    nvn_gpu_set_dyn(cmd, &dyn);
    nvn_gpu_set_pipe(cmd, pipe);
    const nvn_gpu_draw_args draw = {.prim = 4, .count = 3, .instances = 1};
    nvn_gpu_draw(cmd, &draw);
    nvn_gpu_pass_end(cmd);
    for (unsigned i = 0; i < 2; i++)
        nvn_gpu_copy_tex_buf(cmd, tex[i], 0, 0, NULL, readback[i], 0, 32, 128);
    nvn_gpu_err err = {0};
    static uint64_t signal;
    signal++;
    if (!OK(nvn_gpu_cmd_commit(cmd, signal, on_done, NULL, &err)) ||
        !OK(nvn_gpu_fence_wait(signal, 5000000000ull, &err))) {
        CHECK(0, "RGBA16F submit/readback arm %u: %s", arm, err.why);
        goto out;
    }
    const uint16_t clear[4] = {0x3400, 0x3800, 0x3a00, 0x3c00};
    const uint16_t mixed[4] = {0x3900, 0x3800, 0x3800, 0x3800};
    const uint16_t finite[4] = {0x3c00, 0x3800, 0x3400, 0x3800};
    unsigned transparent = 0;
    uint16_t sample[4] = {0};
    for (unsigned i = 0; i < 2; i++) {
        const uint8_t *pixels = buf_cpu(readback[i]);
        CHECK(pixels != NULL, "RGBA16F mapped slot %u", i);
        if (!pixels) continue;
        for (unsigned pixel = 0; pixel < 16; pixel++) {
            uint16_t v[4];
            memcpy(v, pixels + pixel * sizeof v, sizeof v);
            const unsigned column = pixel % 4;
            if (i == 1 && blend && column < 2) {
                if (!memcmp(v, clear, sizeof clear)) transparent++;
                if (pixel == 0) memcpy(sample, v, sizeof sample);
            } else if (i == 1 && column == 2) {
                CHECK(!memcmp(v, blend ? mixed : finite, sizeof finite), "finite control arm %u pixel %u", arm, pixel);
            } else if (i == 1 && blend) {
                CHECK(is_half_nan(v[0]) && (v[1] & 0x7c00u) == 0x7c00u &&
                      (v[2] & 0x7c00u) == 0x7c00u && v[3] == 0x3800,
                      "nonzero alpha control arm %u pixel %u", arm, pixel);
            } else {
                CHECK(is_half_nan(v[0]) && v[1] == 0x7c00 && v[2] == 0xfc00 &&
                      (v[3] & 0x7fffu) == ((i == 1 && column == 3) ? 0x3800 : 0),
                      "unblended MRT control arm %u slot %u pixel %u", arm, i, pixel);
            }
        }
    }
    if (blend) CHECK(transparent == 8, "zero-alpha RGB preservation arm %u: %u/8, first=%04x/%04x/%04x/%04x",
                     arm, transparent, sample[0], sample[1], sample[2], sample[3]);
out:
    for (unsigned i = 0; i < 2; i++) {
        nvn_gpu_buf_release(readback[i], NULL, NULL);
        nvn_gpu_view_release(pass.color[i].view);
        nvn_gpu_tex_release(tex[i]);
    }
}

static void test_source(const char *dir, nvn_gpu_shader vs, int precompiled) {
    const struct nan_src_stats before = read_nan_src_stats();
    size_t fs_bytes = 0;
    nvn_gpu_shader fs = load_stage(dir, "float_blend_nan.frag", NVN_GPU_SH_FS, precompiled, &fs_bytes);
    if (!fs) return;
    const struct nan_src_stats after_load = read_nan_src_stats();
    if (!use_original_module) {
        CHECK(after_load.live == before.live + 1 && after_load.live > 0 &&
              after_load.bytes == before.bytes + fs_bytes && after_load.bytes > 0 &&
              after_load.alloc == before.alloc + 1 && after_load.alloc >= after_load.live &&
              after_load.freed == before.freed,
              "stats after load precompiled=%d: live=%llu bytes=%llu alloc=%llu freed=%llu (exp +1/+%zu)",
              precompiled, (unsigned long long)after_load.live, (unsigned long long)after_load.bytes,
              (unsigned long long)after_load.alloc, (unsigned long long)after_load.freed, fs_bytes);
    } else {
        CHECK(after_load.live == 0 && after_load.bytes == 0 &&
              after_load.alloc == 0 && after_load.freed == 0,
              "original-module keeps float_nan_src stats zero after load");
    }
    nvn_gpu_pipe_desc pd = {.cfmt = {NVN_FORMAT_RGBA16F, NVN_FORMAT_RGBA16F},
        .lmap = {0, 1}, .samples = 1, .prim = 4, .origin_ll = 1};
    pd.poly.mode = NVN_POLYGON_MODE_FILL;
    pd.color.logic_op = NVN_LOGIC_OP_COPY;
    pd.chmask.mask = 0xff;
    pd.st[NVN_GPU_SH_VS].sh = vs;
    pd.st[NVN_GPU_SH_FS].sh = fs;
    pd.blend[1] = (blend_st){.src_rgb = NVN_BLEND_FUNC_SRC_ALPHA,
        .dst_rgb = NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, .src_a = NVN_BLEND_FUNC_ZERO,
        .dst_a = NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, .eq_rgb = NVN_BLEND_EQUATION_ADD,
        .eq_a = NVN_BLEND_EQUATION_ADD};
    pd.color.blend_en = 2;
    nvn_gpu_pipe prewarmed = NULL;
    nvn_gpu_err err = {0};
    uint64_t hits = nvn_gpu_pipe_warm_hits();
    nvn_gpu_pipe_warm_scope(1);
    nvn_gpu_rc warm = nvn_gpu_pipe_get(&pd, NVN_GPU_PIPE_SYNC, &prewarmed, &err);
    nvn_gpu_pipe_warm_scope(0);
    CHECK(OK(warm) && prewarmed, "prewarm blend pipeline: %s", err.why);
    if (!prewarmed) goto out;
    const struct nan_src_stats after_pipe = read_nan_src_stats();
    if (!use_original_module) {
        CHECK(after_pipe.live == before.live && after_pipe.bytes == before.bytes &&
              after_pipe.alloc == after_load.alloc && after_pipe.freed == before.freed + 1,
              "stats after rewrite precompiled=%d: live=%llu bytes=%llu alloc=%llu freed=%llu",
              precompiled, (unsigned long long)after_pipe.live, (unsigned long long)after_pipe.bytes,
              (unsigned long long)after_pipe.alloc, (unsigned long long)after_pipe.freed);
    } else {
        CHECK(after_pipe.live == 0 && after_pipe.bytes == 0 &&
              after_pipe.alloc == 0 && after_pipe.freed == 0,
              "original-module keeps float_nan_src stats zero after pipe");
    }
    for (unsigned i = 0; i < 3; i++) {
        pd.color.blend_en = i == 1 ? 0 : 2;
        nvn_gpu_pipe pipe = NULL;
        nvn_gpu_rc r = nvn_gpu_pipe_get(&pd, NVN_GPU_PIPE_SYNC, &pipe, &err);
        CHECK(OK(r) && pipe, "select MRT pipeline arm %u: %s", i, err.why);
        if (!pipe) break;
        CHECK((pipe == prewarmed) == (i != 1), "MRT mask reuses only matching prewarmed pipeline arm %u", i);
        draw_pixels(pipe, i != 1, (unsigned)precompiled * 3 + i);
    }
    CHECK(nvn_gpu_pipe_warm_hits() == hits + 1, "one protected graphics prewarm hit per source");
out:
    nvn_gpu_shader_release(fs);
    const struct nan_src_stats after_rel = read_nan_src_stats();
    if (!use_original_module) {
        CHECK(after_rel.live == before.live && after_rel.bytes == before.bytes &&
              after_rel.alloc == after_load.alloc && after_rel.freed == before.freed + 1,
              "stats stable after releasing rewritten shader precompiled=%d: live=%llu bytes=%llu freed=%llu",
              precompiled, (unsigned long long)after_rel.live, (unsigned long long)after_rel.bytes,
              (unsigned long long)after_rel.freed);
    }
}

static void test_unused_shader_release(const char *dir) {
    const struct nan_src_stats before = read_nan_src_stats();
    size_t fs_bytes = 0;
    nvn_gpu_shader fs = load_stage(dir, "float_blend_nan.frag", NVN_GPU_SH_FS, 0, &fs_bytes);
    if (!fs) return;
    const struct nan_src_stats after_load = read_nan_src_stats();
    if (!use_original_module) {
        CHECK(after_load.live == before.live + 1 && after_load.bytes == before.bytes + fs_bytes &&
              after_load.alloc == before.alloc + 1 && after_load.freed == before.freed,
              "unused fs load stats: live=%llu bytes=%llu alloc=%llu freed=%llu",
              (unsigned long long)after_load.live, (unsigned long long)after_load.bytes,
              (unsigned long long)after_load.alloc, (unsigned long long)after_load.freed);
    }
    nvn_gpu_shader_release(fs);
    const struct nan_src_stats after_rel = read_nan_src_stats();
    if (!use_original_module) {
        CHECK(after_rel.live == 0 && after_rel.bytes == 0 &&
              after_rel.alloc == before.alloc + 1 && after_rel.freed == before.freed + 1,
              "unused fs destroy stats: live=%llu bytes=%llu alloc=%llu freed=%llu",
              (unsigned long long)after_rel.live, (unsigned long long)after_rel.bytes,
              (unsigned long long)after_rel.alloc, (unsigned long long)after_rel.freed);
    } else {
        CHECK(after_rel.live == 0 && after_rel.bytes == 0 &&
              after_rel.alloc == 0 && after_rel.freed == 0,
              "original-module keeps float_nan_src stats zero on unused destroy");
    }
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[2], "--original-module")) use_original_module = 1;
    else if (argc != 2) return 64;
    char why[256] = {0};
    if (s2a_vk_device_create(&g_dev, why, sizeof why) != 0) {
        fprintf(stderr, "create Vulkan device: %s\n", why);
        return 2;
    }
    printf("device: %s (%s)\n", g_dev.properties.deviceName, g_dev.driver_name);
    g_desc.host_device = &g_dev;
    g_desc.app_label = "float-blend-nan";
    if (!open_backend()) return 2;
    CHECK(nvn_gpu_format_caps(NVN_FORMAT_RGBA16F) & NVN_GPU_FMT_BLEND, "RGBA16F blending supported");
    CHECK(g_dev.core_features.independentBlend, "independent MRT blending supported");
    const struct nan_src_stats init = read_nan_src_stats();
    CHECK(init.live == 0 && init.bytes == 0 && init.alloc == 0 && init.freed == 0,
          "initial float_nan_src stats zero: live=%llu bytes=%llu alloc=%llu freed=%llu",
          (unsigned long long)init.live, (unsigned long long)init.bytes,
          (unsigned long long)init.alloc, (unsigned long long)init.freed);
    nvn_gpu_shader vs = load_stage(argv[1], "libpack_depth.vert", NVN_GPU_SH_VS, 0, NULL);
    if (vs && !g_fail) {
        const struct nan_src_stats after_vs = read_nan_src_stats();
        CHECK(after_vs.live == 0 && after_vs.bytes == 0 && after_vs.alloc == 0 && after_vs.freed == 0,
              "vertex stage does not retain float_nan_src");
        test_source(argv[1], vs, 0);
        test_source(argv[1], vs, 1);
        test_unused_shader_release(argv[1]);
        // Load one unreleased fragment shader so close-time teardown + session reopen reset are both exercised.
        size_t close_bytes = 0;
        nvn_gpu_shader leaked_to_close = load_stage(argv[1], "float_blend_nan.frag", NVN_GPU_SH_FS, 0, &close_bytes);
        if (leaked_to_close && !use_original_module) {
            const struct nan_src_stats before_close = read_nan_src_stats();
            CHECK(before_close.live == 1 && before_close.bytes == close_bytes &&
                  before_close.alloc == 4 && before_close.freed == 3,
                  "pre-close resident stats: live=%llu bytes=%llu alloc=%llu freed=%llu",
                  (unsigned long long)before_close.live, (unsigned long long)before_close.bytes,
                  (unsigned long long)before_close.alloc, (unsigned long long)before_close.freed);
        }
    }
    nvn_gpu_shader_release(vs);
    nvn_gpu_err err = {0};
    CHECK(OK(nvn_gpu_close(5000000000ull, &err)), "close: %s", err.why);
    // Reopen once to verify close teardown + session restart leave zero stale counts.
    if (open_backend()) {
        const struct nan_src_stats reopened = read_nan_src_stats();
        CHECK(reopened.live == 0 && reopened.bytes == 0 && reopened.alloc == 0 && reopened.freed == 0,
              "reopened session stats zero: live=%llu bytes=%llu alloc=%llu freed=%llu",
              (unsigned long long)reopened.live, (unsigned long long)reopened.bytes,
              (unsigned long long)reopened.alloc, (unsigned long long)reopened.freed);
        CHECK(OK(nvn_gpu_close(5000000000ull, &err)), "reopen close: %s", err.why);
    }
    s2a_vk_device_destroy(&g_dev, 1);
    printf("float-blend-nan: failures=%d\n", g_fail);
    return g_fail ? 1 : 0;
}
