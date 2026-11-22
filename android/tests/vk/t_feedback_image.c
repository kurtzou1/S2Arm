// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 图形阶段存储图像与本通道的附件是同一张图（#999）：这一笔具名跳过并计数，不设粘性错误，同一段里后面的笔照常画。
// 真实 Vulkan（lavapipe）+ 校验层，像素、计数、时间线三处都按读数核，不靠「没崩」。
//   同一段、同一个通道里按列画四笔（用裁剪矩形分开列），同一条管线、同一个着色器（存储图像读改写 + 往附件 0 写绿色）：
//   第 0、2 笔：存储图像 = 附件 A 自己（重叠）→ 必须整笔跳过：A 的这两列留着清屏值，计数 +1
//   第 1、3 笔：存储图像 = 另一张图 B（不重叠）→ 照常画：A 的这两列是绿色，B 的这两列红通道 +0.25
#include "nvn_backend.h"
#include "nvn_plat_vk.h"
#include "vk_device.h"
#include "nvn_unimpl.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static nvn_gpu_err err;
static int dq_mode, opt_mode;
static volatile uint32_t done_status = 99;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "fixture failed line %d: %s rc=%d why=%s\n", __LINE__, #x, err.rc.code, err.why); exit(2); } } while (0)
#define GPU(x) REQUIRE(nvn_gpu_ok(x))
const char *const *nvn_plat_vk_instance_exts(uint32_t *n) { *n = 0; return NULL; }
VkResult nvn_plat_vk_surface_create(VkInstance i, void *w, VkSurfaceKHR *s) { (void)i; (void)w; *s = VK_NULL_HANDLE; return VK_ERROR_EXTENSION_NOT_PRESENT; }
int nvn_plat_window_size(void *w, uint32_t *x, uint32_t *y) { (void)w; (void)x; (void)y; return 0; }
void nvn_plat_safepoint(void) {}
int nvn_plat_flag(const char *n, int d) {
    if (!strcmp(n, "nvk_dq")) return dq_mode;
    if (!strcmp(n, "nvk_opt_layout")) return opt_mode;
    if (!strcmp(n, "nvk_fb_copy")) return 1;
    return d;
}
void nvn_plat_log(int l, const char *c, const char *s) { (void)l; fprintf(stderr, "[%s] %s\n", c ? c : "", s ? s : ""); }
// 不用 REQUIRE：时间线失败时要把读数打出来，让「恢复粘性」那个改坏项按读数变红，而不是在回调里直接退出
static void on_done(void *u, const nvn_gpu_done *d) { (void)u; done_status = d->status; }

static nvn_gpu_shader shader(const char *dir, const char *name, nvn_gpu_stage stage, const nvn_gpu_layout *layout) {
    char path[1024];
    REQUIRE(snprintf(path, sizeof path, "%s/%s.spv", dir, name) < (int)sizeof path);
    FILE *f = fopen(path, "rb");
    REQUIRE(f);
    REQUIRE(!fseek(f, 0, SEEK_END));
    long n = ftell(f);
    REQUIRE(n > 0);
    rewind(f);
    void *data = malloc((size_t)n);
    REQUIRE(data);
    REQUIRE(fread(data, 1, (size_t)n, f) == (size_t)n);
    fclose(f);
    nvn_gpu_shader_src s = {0};
    s.stage = stage; s.kind = NVN_GPU_BLOB_SPIRV; s.entry = "main"; s.blob = data; s.bytes = (size_t)n; s.layout = layout;
    nvn_gpu_shader h = NULL;
    GPU(nvn_gpu_shader_load(&s, &h, &err));
    free(data);
    return h;
}
static void begin_pass(nvn_gpu_cmd c, nvn_gpu_view view, int load) {
    nvn_gpu_pass_desc p = {0};
    p.ncolor = 1; p.color[0].view = view; p.color[0].load = load; p.color[0].store = NVN_GPU_STORE_STORE;
    p.color[0].clear.f[0] = .25f; p.color[0].clear.f[3] = 1;
    p.w = p.h = 4; p.layers = 1;
    nvn_gpu_pass_begin(c, &p);
}
// 一个像素的四个字节是否等于期望
static unsigned px_bad(const unsigned char *img, unsigned x, unsigned y, unsigned r, unsigned g, unsigned b, unsigned a) {
    const unsigned char *p = img + (y * 4 + x) * 4;
    return p[0] != r || p[1] != g || p[2] != b || p[3] != a;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    dq_mode = atoi(argv[2]); opt_mode = atoi(argv[3]);
    REQUIRE((dq_mode == 0 || dq_mode == 1) && (opt_mode == 0 || opt_mode == 1));
    struct s2a_vk_device device;
    char why[256];
    if (s2a_vk_device_create(&device, why, sizeof why)) { fprintf(stderr, "%s\n", why); return 2; }
    nvn_unimpl_reset();
    nvn_gpu_open_desc od = {0};
    od.host_device = &device; od.app_label = "feedback-image";
    GPU(nvn_gpu_open(&od, &err));
    printf("feedback-image begin dq=%d opt=%d\n", dq_mode, opt_mode);

    nvn_gpu_layout_ent ent = {0};
    ent.cls = NVN_GPU_RES_IMAGE; ent.access = NVN_GPU_ACC_R | NVN_GPU_ACC_W; ent.count = 1; ent.stages = 1u << NVN_GPU_SH_FS;
    nvn_gpu_layout layout = {0};
    layout.ent = &ent; layout.nent = 1;
    nvn_gpu_shader vs = shader(argv[1], "fullscreen.vert", NVN_GPU_SH_VS, NULL);
    nvn_gpu_shader fs = shader(argv[1], "feedback_image.frag", NVN_GPU_SH_FS, &layout);
    nvn_gpu_pipe_desc pd = {0};
    pd.poly.mode = NVN_POLYGON_MODE_FILL; pd.color.logic_op = 3; pd.prim = 4; pd.samples = 1; pd.chmask.mask = 15;
    pd.st[NVN_GPU_SH_VS].sh = vs; pd.st[NVN_GPU_SH_FS].sh = fs; pd.cfmt[0] = NVN_FORMAT_RGBA8;
    nvn_gpu_pipe pipe = NULL;
    GPU(nvn_gpu_pipe_get(&pd, NVN_GPU_PIPE_SYNC, &pipe, &err));

    // A：本通道的颜色附件，同时能当存储图像；B：只当存储图像用的另一张图（通道外先清成同一个初值）
    nvn_gpu_tex img[2] = {0};
    nvn_gpu_view view[2] = {0};
    nvn_gpu_tex_desc td = {0};
    td.d.target = NVN_TEXTURE_TARGET_2D; td.d.format = NVN_FORMAT_RGBA8; td.d.width = td.d.height = 4; td.d.depth = td.d.levels = 1;
    td.usage = NVN_GPU_TEX_RENDER | NVN_GPU_TEX_STORAGE | NVN_GPU_TEX_SAMPLED;
    for (unsigned i = 0; i < 2; i++) {
        GPU(nvn_gpu_tex_create(&td, &img[i], &err));
        GPU(nvn_gpu_view_create(img[i], NULL, &view[i], &err));
    }
    unsigned char sentinel[136];
    memset(sentinel, 0xa5, sizeof sentinel);
    nvn_gpu_buf rb = NULL;
    GPU(nvn_gpu_buf_create(sizeof sentinel, NVN_GPU_MEM_SHARED, sentinel, &rb, &err));

    nvn_gpu_cmd cmd = NULL;
    GPU(nvn_gpu_cmd_begin(NULL, &cmd, &err));
    for (unsigned i = 0; i < 2; i++) { begin_pass(cmd, view[i], NVN_GPU_LOAD_CLEAR); nvn_gpu_pass_end(cmd); }
    begin_pass(cmd, view[0], NVN_GPU_LOAD_LOAD);
    nvn_gpu_set_pipe(cmd, pipe);
    nvn_gpu_draw_args a = {0};
    a.prim = 4; a.count = 3; a.instances = 1;
    for (unsigned col = 0; col < 4; col++) {
        nvn_gpu_dyn dyn = {0};
        dyn.nvp = 1; dyn.vp[0][2] = dyn.vp[0][3] = 4; dyn.vp[0][5] = 1;
        dyn.has_sc = 1; dyn.sc[0] = (int32_t)col; dyn.sc[2] = 1; dyn.sc[3] = 4;
        nvn_gpu_set_dyn(cmd, &dyn);
        nvn_gpu_binding b = {0};
        b.cls = NVN_GPU_RES_IMAGE; b.u.view = view[col & 1 ? 1 : 0];   // 偶数列：附件 A 自己；奇数列：另一张图 B
        nvn_gpu_bind(cmd, NVN_GPU_SH_FS, &b, 1);
        nvn_gpu_draw(cmd, &a);
    }
    nvn_gpu_pass_end(cmd);
    nvn_gpu_copy_tex_buf(cmd, img[0], 0, 0, NULL, rb, 0, 16, 64);
    nvn_gpu_copy_tex_buf(cmd, img[1], 0, 0, NULL, rb, 64, 16, 64);
    nvn_gpu_view_release(view[0]); nvn_gpu_view_release(view[1]);
    nvn_gpu_tex_release(img[0]); nvn_gpu_tex_release(img[1]);

    // 提交 / 等待不用 GPU() 包：时间线失败时要走到下面的读数，不能在这里直接退出
    nvn_gpu_rc rc_commit = nvn_gpu_cmd_commit(cmd, 1, on_done, NULL, &err);
    nvn_gpu_rc rc_wait = nvn_gpu_fence_wait(1, 5000000000ull, &err);
    const unsigned commit_bad = !nvn_gpu_ok(rc_commit), wait_bad = !nvn_gpu_ok(rc_wait);
    const unsigned fenced_bad = nvn_gpu_fence_failed() != 0, done_bad = done_status != NVN_GPU_DONE_OK;
    const uint64_t skips = nvn_unimpl_count("draw", "graphics_image_feedback_overlap");
    const unsigned count_bad = skips != 2;

    const unsigned char *px = nvn_gpu_buf_cpu(rb);
    unsigned pixel_bad = 0;
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 4; x++) {
            const int redrawn = x & 1;   // 奇数列是真画了的
            pixel_bad += redrawn ? px_bad(px, x, y, 0, 255, 0, 255) : px_bad(px, x, y, 64, 0, 0, 255);   // A：画了 = 绿，跳过 = 清屏值
            pixel_bad += redrawn ? px_bad(px + 64, x, y, 128, 0, 0, 255) : px_bad(px + 64, x, y, 64, 0, 0, 255);   // B：画了 = 红 64→128，没画 = 清屏值
        }
    unsigned guard_bad = 0;
    for (unsigned i = 128; i < sizeof sentinel; i++) if (px[i] != 0xa5) guard_bad++;   // 越界哨兵不动
    const unsigned failures = commit_bad + wait_bad + fenced_bad + done_bad + count_bad + pixel_bad + guard_bad;
    printf("feedback-image dq=%d opt=%d skips=%llu commit-bad=%u wait-bad=%u fence-failed-bad=%u done-bad=%u count-bad=%u pixel-bad=%u guard-bad=%u\n",
           dq_mode, opt_mode, (unsigned long long)skips, commit_bad, wait_bad, fenced_bad, done_bad, count_bad, pixel_bad, guard_bad);
    nvn_gpu_buf_release(rb, NULL, NULL);
    nvn_gpu_shader_release(vs); nvn_gpu_shader_release(fs);
    GPU(nvn_gpu_close(5000000000ull, &err));
    REQUIRE(!s2a_vk_device_destroy(&device, 1));
    printf("feedback-image cases=1 failures=%u\n", failures);
    return failures ? 1 : 0;
}
