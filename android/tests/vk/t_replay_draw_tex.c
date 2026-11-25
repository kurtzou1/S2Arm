// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 真实回放 DrawTexture（rp_draw_tex.c）+ 真 Vulkan 后端（nvn_gpu_draw_tex）：只把资源查找与通道管理换成受控替身，读回目标全部像素逐个比。
// 期望值按 NVN 语义手算（iOS nvn_mtl.m draw_tex / Ryujinx HelperShader.DrawTexture）：视口 = 目的矩形，最近点采样下目的像素中心
//   落在源的第 (x - x0) * sw / w 个纹素；窗口原点在左上时源 v0 在目的矩形的上沿（行号小），在左下时在下沿；目的反向 = 源端点交换。
// 用法：test [neg]。neg = 撤改负对照：后端能力位里抹掉 NVN_GPU_CAP_DRAW_TEX（核心照旧记「未接」跳过），同一组逐像素比对必须报红。
#define main backend_fixture_main
#include "t_backend_vk.c"
#undef main
#include "rp_exec.h"
#include "rp_res.h"
#include "rp_state.h"

enum { TW = 16, TH = 16, SW = 4, SH = 4 };
struct rp_state rp_S; struct rp_target rp_R;
static int g_neg, g_unimpl_op, g_unimpl_other, g_open, g_origin_ll;
static nvn_gpu_view g_src_view, g_rt_view; static nvn_gpu_samp g_samp;
static tex_t g_src_snap, g_rt_snap; static p_set_rt g_rt;
static nvn_gpu_cmd g_c; static int g_sig;

void __real_nvn_gpu_caps_get(nvn_gpu_caps *out);
void __wrap_nvn_gpu_caps_get(nvn_gpu_caps *out) { __real_nvn_gpu_caps_get(out); if (g_neg) out->caps &= ~(uint32_t)NVN_GPU_CAP_DRAW_TEX; }
uint64_t nvn_unimpl_count(const char *cls, const char *name) { (void)cls; (void)name; return 0; }
uint64_t nvn_unimpl(const char *cls, const char *name, const void *site) {
    (void)site; printf("unimplemented %s/%s\n", cls, name);
    if (!strcmp(cls, "op") && !strcmp(name, "OP_DRAW_TEX")) g_unimpl_op++; else g_unimpl_other++;
    return 1;
}
int rp_tex_snap_by_id(int id, tex_t *t, view_t *v, int *has_v) { if (id != 7) return 0; *t = g_src_snap; if (v) memset(v, 0, sizeof *v); if (has_v) *has_v = 0; return 1; }
nvn_gpu_view rp_view_by_id_decl(int id, uint8_t dtt, uint8_t dcls, int elem, nvn_gpu_cmd c, tex_t *t_out) {
    (void)dtt; (void)dcls; (void)elem; (void)c; (void)t_out; return id == 7 ? g_src_view : NULL;
}
nvn_gpu_samp rp_samp_for_tex(int sid, int tid) { return sid == 3 && tid == 7 ? g_samp : NULL; }
uint32_t rp_fmt_caps(uint32_t f) { return nvn_gpu_format_caps(f); }
int rp_origin_lower_left(void) { return g_origin_ll; }
const p_set_rt *rp_pass_target(void) { return &g_rt; }
int rp_pass_parked(void) { return 0; }
void rp_pass_land_reads(nvn_gpu_cmd c, const rp_pass_read *ts, int n) { (void)c; (void)ts; (void)n; }
void rp_view_pin_begin(void) {}
void rp_view_pin_end(void) {}
void rp_pass_prepare_draw(nvn_gpu_cmd c, uint32_t m) { (void)c; (void)m; } void rp_pass_want_layered(nvn_gpu_cmd c, int layered) { (void)c; (void)layered; }
int rp_pass_begin(nvn_gpu_cmd c) {   // 替身：颜色 0 = 目标，按 LOAD 开（保留底色），只开一次
    if (g_open) return 1;
    nvn_gpu_pass_desc p; memset(&p, 0, sizeof p);
    p.ncolor = 1; p.color[0].view = g_rt_view; p.color[0].load = NVN_GPU_LOAD_LOAD; p.color[0].store = NVN_GPU_STORE_STORE;
    p.w = TW; p.h = TH; p.layers = 1;
    nvn_gpu_pass_begin(c, &p); g_open = 1; return 1;
}
int rp_pass_slot_attached(int i) { return i == 0 && g_open; }
void rp_pass_slot_size(int i, uint32_t *w, uint32_t *h) { (void)i; *w = TW; *h = TH; }
void rp_occl_draw(nvn_gpu_cmd c) { (void)c; }
void rp_pass_note_draw(int uses_ds) { (void)uses_ds; }
void rp_dirty_all(void) {}

static const uint8_t BG[4] = {16, 32, 48, 255};
static void texel(int i, int j, uint8_t o[4]) { o[0] = (uint8_t)(40 + 60 * i); o[1] = (uint8_t)(40 + 60 * j); o[2] = 200; o[3] = 255; }

// 一个用例：目的矩形端点、源矩形端点、裁剪（w = 0 不设）、写掩码、混合（ONE + ONE 加法）、窗口原点
struct dt_case { const char *name; float d[4], s[4]; int32_t sc[4]; unsigned mask; int add_blend, origin_ll; };

// 期望：手算，不经被测实现
static void expect_px(const struct dt_case *k, int x, int y, uint8_t out[4]) {
    memcpy(out, BG, 4);
    float dx0 = fminf(k->d[0], k->d[2]), dx1 = fmaxf(k->d[0], k->d[2]), dy0 = fminf(k->d[1], k->d[3]), dy1 = fmaxf(k->d[1], k->d[3]);
    float cx = x + 0.5f, cy = y + 0.5f;
    if (cx < dx0 || cx >= dx1 || cy < dy0 || cy >= dy1) return;
    if (k->sc[2] && (x < k->sc[0] || x >= k->sc[0] + k->sc[2] || y < k->sc[1] || y >= k->sc[1] + k->sc[3])) return;
    float fx = (cx - dx0) / (dx1 - dx0), fy = (cy - dy0) / (dy1 - dy0);   // 0..1，左→右、行号小→大
    if (k->d[2] < k->d[0]) fx = 1 - fx;                  // 目的反向：源 u 反着走
    if (k->origin_ll) fy = 1 - fy;                       // 原点在左下：v0 在行号大的一边
    if (k->d[3] < k->d[1]) fy = 1 - fy;
    float u = k->s[0] + fx * (k->s[2] - k->s[0]), v = k->s[1] + fy * (k->s[3] - k->s[1]);   // 源像素坐标
    uint8_t t[4]; texel((int)floorf(u), (int)floorf(v), t);
    for (int ch = 0; ch < 4; ch++) {
        if (!(k->mask >> ch & 1)) continue;
        int val = k->add_blend ? BG[ch] + t[ch] : t[ch];
        out[ch] = (uint8_t)(val > 255 ? 255 : val);
    }
}

static int run_case(const struct dt_case *k, nvn_gpu_tex rt_tex) {
    nvn_gpu_err e = {0}; int bad = 0;
    nvn_gpu_buf rb = make_buf(TW * TH * 4, NVN_GPU_MEM_SHARED, NULL);
    g_c = begin_cmd(); g_open = 0; g_origin_ll = k->origin_ll;
    float bg[4] = {BG[0] / 255.0f, BG[1] / 255.0f, BG[2] / 255.0f, 1};
    nvn_gpu_clear_view(g_c, g_rt_view, bg, NULL, 0);
    memset(&rp_S, 0, sizeof rp_S); memset(&rp_R, 0, sizeof rp_R);
    rp_S.chmask.mask = k->mask; rp_S.color.logic_op = NVN_LOGIC_OP_COPY;
    if (k->add_blend) {
        rp_S.color.blend_en = 1;
        rp_S.blend[0].src_rgb = rp_S.blend[0].dst_rgb = rp_S.blend[0].src_a = rp_S.blend[0].dst_a = NVN_BLEND_FUNC_ONE;
        rp_S.blend[0].eq_rgb = rp_S.blend[0].eq_a = NVN_BLEND_EQUATION_ADD;
    }
    if (k->sc[2]) { rp_R.has_sc = 1; rp_R.sc.x = k->sc[0]; rp_R.sc.y = k->sc[1]; rp_R.sc.w = k->sc[2]; rp_R.sc.h = k->sc[3]; }
    p_draw_tex o; memset(&o, 0, sizeof o); o.handle = 7 | 3ull << 20;
    memcpy(o.dst, k->d, sizeof o.dst); memcpy(o.src, k->s, sizeof o.src);
    rp_op_draw_tex(g_c, &o, &o);
    if (g_open) nvn_gpu_pass_end(g_c);
    nvn_gpu_copy_tex_buf(g_c, rt_tex, 0, 0, NULL, rb, 0, TW * 4, TW * TH * 4);
    nvn_gpu_rc r = nvn_gpu_cmd_commit(g_c, (uint64_t)++g_sig, on_done, NULL, &e);
    CHECK(OK(r), "%s commit：%d %s", k->name, r.code, e.why);
    r = nvn_gpu_fence_wait((uint64_t)g_sig, 5000000000ull, &e);
    CHECK(OK(r), "%s wait：%d %s", k->name, r.code, e.why);
    const uint8_t *px = buf_cpu(rb);
    for (int y = 0; y < TH; y++) for (int x = 0; x < TW; x++) {
        uint8_t want[4]; expect_px(k, x, y, want); const uint8_t *q = px + (y * TW + x) * 4;
        if (memcmp(q, want, 4)) {
            if (bad++ < 3) printf("  %s (%d,%d) = %u,%u,%u,%u 期望 %u,%u,%u,%u\n", k->name, x, y, q[0], q[1], q[2], q[3], want[0], want[1], want[2], want[3]);
        }
    }
    printf("case %s: pixel-failures=%d\n", k->name, bad);
    nvn_gpu_buf_release(rb, NULL, NULL);
    return bad;
}

int main(int argc, char **argv) {
    g_neg = argc > 1 && !strcmp(argv[1], "neg");
    char why[256] = {0};
    if (s2a_vk_device_create(&g_dev, why, sizeof why)) { printf("device failed: %s\n", why); return 2; }
    printf("device: %s (%s)\n", g_dev.properties.deviceName, g_dev.driver_name);
    memset(&g_desc, 0, sizeof g_desc); g_desc.host_device = &g_dev; g_desc.app_label = "nvn-replay-draw-tex-test";
    if (!open_backend()) return 1;
    nvn_gpu_caps cp; __real_nvn_gpu_caps_get(&cp);
    CHECK(cp.caps & NVN_GPU_CAP_DRAW_TEX, "Vulkan 后端没置 NVN_GPU_CAP_DRAW_TEX");
    nvn_gpu_tex rt_tex = make_tex(TW, TH, NVN_FORMAT_RGBA8, NVN_GPU_TEX_RENDER | NVN_GPU_TEX_SAMPLED);
    nvn_gpu_tex src = make_tex(SW, SH, NVN_FORMAT_RGBA8, NVN_GPU_TEX_SAMPLED | NVN_GPU_TEX_CPU_UPLOAD);
    g_rt_view = make_view(rt_tex); g_src_view = make_view(src);
    samp_par sp; memset(&sp, 0, sizeof sp);
    sp.minf = NVN_MIN_FILTER_NEAREST; sp.magf = NVN_MAG_FILTER_NEAREST; sp.ws = sp.wt = sp.wr = NVN_WRAP_MODE_CLAMP_TO_EDGE; sp.lod_max = 1000;
    nvn_gpu_err e = {0};
    CHECK(OK(nvn_gpu_samp_create(&sp, &g_samp, &e)), "samp：%d %s", e.rc.code, e.why);
    uint8_t texels[SW * SH * 4];
    for (int j = 0; j < SH; j++) for (int i = 0; i < SW; i++) texel(i, j, texels + (j * SW + i) * 4);
    nvn_gpu_buf up = make_buf(sizeof texels, NVN_GPU_MEM_SHARED, texels);
    nvn_gpu_cmd c = begin_cmd();
    nvn_gpu_copy_buf_tex(c, up, 0, SW * 4, sizeof texels, src, 0, 0, NULL);
    nvn_gpu_rc r = nvn_gpu_cmd_commit(c, (uint64_t)++g_sig, on_done, NULL, &e); CHECK(OK(r), "upload commit：%d %s", r.code, e.why);
    CHECK(OK(nvn_gpu_fence_wait((uint64_t)g_sig, 5000000000ull, &e)), "upload wait：%s", e.why);
    memset(&g_src_snap, 0, sizeof g_src_snap); g_src_snap.serial = 2; g_src_snap.d.target = NVN_TEXTURE_TARGET_2D; g_src_snap.d.format = NVN_FORMAT_RGBA8;
    g_src_snap.d.width = SW; g_src_snap.d.height = SH; g_src_snap.d.depth = 1; g_src_snap.d.levels = 1;
    g_rt_snap = g_src_snap; g_rt_snap.serial = 1; g_rt_snap.d.width = TW; g_rt_snap.d.height = TH;
    memset(&g_rt, 0, sizeof g_rt); g_rt.n = 1; g_rt.color[0] = &g_rt_snap;

    static const struct dt_case cases[] = {
        {"upper_left",   {2, 2, 10, 10}, {0, 0, 4, 4}, {0}, 0xf, 0, 0},
        {"lower_left",   {2, 2, 10, 10}, {0, 0, 4, 4}, {0}, 0xf, 0, 1},
        {"mirror_x",     {13, 1, 5, 9},  {0, 0, 4, 4}, {0}, 0xf, 0, 0},
        {"sub_src",      {0, 4, 12, 16}, {1, 1, 4, 3}, {0}, 0xf, 0, 0},   // 源 3x2 放大到 12x12（u 每 4 像素一格，v 每 6 像素一格）
        {"scissor_mask", {0, 0, 16, 16}, {0, 0, 4, 4}, {3, 5, 7, 6}, 0x5, 0, 0},   // 裁剪内只写 r、b
        {"blend_add",    {4, 4, 12, 12}, {0, 0, 4, 4}, {0}, 0xf, 1, 0},   // ONE + ONE：底色加纹素，饱和到 255
    };
    int total = 0;
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) total += run_case(&cases[i], rt_tex);
    printf("draw-tex %s: cases=%zu pixel-failures=%d unimpl-op=%d unimpl-other=%d\n", g_neg ? "neg" : "pos", sizeof cases / sizeof cases[0], total, g_unimpl_op, g_unimpl_other);
    if (g_neg) CHECK(total > 0 && g_unimpl_op == (int)(sizeof cases / sizeof cases[0]), "负对照：没有能力位时逐像素比对必须报红、每笔记一次未接");
    else CHECK(total == 0 && g_unimpl_op == 0 && g_unimpl_other == 0, "正例：逐像素比对与记账");
    nvn_gpu_view_release(g_src_view); nvn_gpu_view_release(g_rt_view); nvn_gpu_samp_release(g_samp);
    nvn_gpu_tex_release(src); nvn_gpu_tex_release(rt_tex); nvn_gpu_buf_release(up, NULL, NULL);
    CHECK(OK(nvn_gpu_close(5000000000ull, &e)), "close：%d %s", e.rc.code, e.why);
    s2a_vk_device_destroy(&g_dev, 1);
    printf("%s replay DRAW_TEX %s: failures=%d\n", g_fail ? "FAIL" : "PASS", g_neg ? "negative-control" : "readback", g_fail);
    return g_fail ? 1 : 0;
}
