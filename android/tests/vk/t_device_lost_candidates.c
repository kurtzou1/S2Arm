/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */
#include "capprobe/capprobe.h"
#include "nvn_backend.h"
#include "nvn_plat_vk.h"
#include "sha256.h"
#include "vk_device.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum fixture_mode { FENCE_LOSS, SUBMIT_LOSS, CONCURRENT_SUBMIT, TRUNCATE };
static enum fixture_mode mode;
static int dq;
static VkDevice device_handle;
static pthread_mutex_t fault_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fault_cv = PTHREAD_COND_INITIALIZER;
static VkFence fault_fence;
static int allow_wait, report_seen;
static atomic_int arm_submit, arm_fence;
static atomic_int returned_loss, gs_writebacks, loss_reports, correct_site, observed, pending, uncertain;
static atomic_int graphics_lib, non_candidates, bad_digest, recorded_tail, truncation;
static atomic_int callbacks[4];
static char compute_digest[65], vertex_digest[65];

static nvn_gpu_err err;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "fixture setup failed line %d: %s (%d %s)\n", __LINE__, #x, err.rc.code, err.why); exit(2); } } while (0)
#define GPU(x) REQUIRE(nvn_gpu_ok(x))

static void release_wait(void) {
    pthread_mutex_lock(&fault_mu);
    allow_wait = 1;
    pthread_cond_broadcast(&fault_cv);
    pthread_mutex_unlock(&fault_mu);
}

/* Inject loss only after real work is idle so VVL can check resource lifetimes.
 * In the concurrent case submit has called the driver but hasn't yet returned
 * to the backend. The fence worker must report while this submit is in progress. */
VKAPI_ATTR VkResult VKAPI_CALL __real_vkQueueSubmit(VkQueue, uint32_t, const VkSubmitInfo *, VkFence);
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkQueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *si, VkFence fence) {
    VkResult r = __real_vkQueueSubmit(q, n, si, fence);
    if (r != VK_SUCCESS) return r;
    if (atomic_exchange(&arm_fence, 0)) {
        pthread_mutex_lock(&fault_mu);
        fault_fence = fence;
        pthread_mutex_unlock(&fault_mu);
    }
    if (!atomic_exchange(&arm_submit, 0)) return r;
    REQUIRE(vkDeviceWaitIdle(device_handle) == VK_SUCCESS);
    if (mode == SUBMIT_LOSS) {
        atomic_fetch_add(&returned_loss, 1);
        return VK_ERROR_DEVICE_LOST;
    }
    release_wait();
    pthread_mutex_lock(&fault_mu);
    while (!report_seen) pthread_cond_wait(&fault_cv, &fault_mu);
    pthread_mutex_unlock(&fault_mu);
    return r;
}
_Static_assert(__builtin_types_compatible_p(__typeof__(&__wrap_vkQueueSubmit), PFN_vkQueueSubmit), "vkQueueSubmit ABI");

VKAPI_ATTR VkResult VKAPI_CALL __real_vkWaitForFences(VkDevice, uint32_t, const VkFence *, VkBool32, uint64_t);
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkWaitForFences(VkDevice d, uint32_t n, const VkFence *fences,
                                                    VkBool32 all, uint64_t timeout) {
    pthread_mutex_lock(&fault_mu);
    const int target = fault_fence && n == 1 && fences[0] == fault_fence;
    if (target) while (!allow_wait) pthread_cond_wait(&fault_cv, &fault_mu);
    pthread_mutex_unlock(&fault_mu);
    VkResult r = __real_vkWaitForFences(d, n, fences, all, timeout);
    if (target && r == VK_SUCCESS) {
        atomic_fetch_add(&returned_loss, 1);
        return VK_ERROR_DEVICE_LOST;
    }
    return r;
}
_Static_assert(__builtin_types_compatible_p(__typeof__(&__wrap_vkWaitForFences), PFN_vkWaitForFences), "vkWaitForFences ABI");

void s2a_capprobe_runtime_lost(void) { atomic_fetch_add(&gs_writebacks, 1); }
const char *const *nvn_plat_vk_instance_exts(uint32_t *n) { *n = 0; return NULL; }
VkResult nvn_plat_vk_surface_create(VkInstance i, void *w, VkSurfaceKHR *s) { *s = VK_NULL_HANDLE; return VK_ERROR_EXTENSION_NOT_PRESENT; }
int nvn_plat_window_size(void *w, uint32_t *x, uint32_t *y) { return 0; }
void nvn_plat_safepoint(void) {}
int nvn_plat_flag(const char *name, int fallback) {
    if (!strcmp(name, "nvk_dq")) return dq;
    if (!strcmp(name, "nvk_compute_warm")) return mode == CONCURRENT_SUBMIT;
    return fallback;
}
void nvn_plat_log(int level, const char *cat, const char *line) {
    if (!line) return;
    if (strstr(line, "device-lost first ")) {
        atomic_fetch_add(&loss_reports, 1);
        const char *site = mode == SUBMIT_LOSS ? "site=queue-submit signal=3 " : "site=wait-fence signal=2 ";
        const char *scope = mode == FENCE_LOSS || mode == TRUNCATE
            ? "accepted_unretired=2 submit_uncertain=0" : "accepted_unretired=1 submit_uncertain=1";
        if (strstr(line, site) && strstr(line, scope) && strstr(line, "VK_EXT_device_fault="))
            atomic_fetch_add(&correct_site, 1);
        if (strstr(line, "truncated_segments=1 truncated_rows=0")) atomic_fetch_add(&truncation, 1);
        pthread_mutex_lock(&fault_mu);
        report_seen = 1;
        pthread_cond_broadcast(&fault_cv);
        pthread_mutex_unlock(&fault_mu);
    }
    if (strstr(line, "device-lost candidate")) {
        if (strstr(line, "key=1111111111111111") || strstr(line, "key=5555555555555555") ||
            strstr(line, "key=6666666666666666") || strstr(line, "key=7777777777777777"))
            atomic_fetch_add(&non_candidates, 1);
        if (strstr(line, "stage=vs key=4444444444444444")) atomic_fetch_add(&graphics_lib, 1);
        if (strstr(line, "key=2222222222222222")) {
            if (strstr(line, "role=observed signal=2 ")) atomic_fetch_add(&observed, 1);
            if (strstr(line, "role=inflight signal=2 ")) atomic_fetch_add(&pending, 1);
        }
        if (strstr(line, "key=3333333333333333")) {
            if (strstr(line, "role=inflight signal=3 ")) atomic_fetch_add(&pending, 1);
            if (strstr(line, "role=submit-uncertain signal=3 ")) atomic_fetch_add(&uncertain, 1);
        }
        if (strstr(line, "key=9090909090909090")) atomic_fetch_add(&recorded_tail, 1);
        const char *digest = strstr(line, "stage=vs") ? vertex_digest : compute_digest;
        const char *got = strstr(line, "spirv_sha256=");
        if (!got || strcmp(got + strlen("spirv_sha256="), digest)) atomic_fetch_add(&bad_digest, 1);
    }
    fprintf(stderr, "[%s] %s\n", cat ? cat : "", line);
}

static void done(void *user, const nvn_gpu_done *d) {
    if (d->signal < sizeof callbacks / sizeof callbacks[0])
        atomic_fetch_add(&callbacks[d->signal], (int)d->status + 1);
}

static nvn_gpu_shader load(const char *path, nvn_gpu_stage stage, unsigned key, int precompiled, char digest[65]) {
    uint32_t code[2048];
    FILE *f = fopen(path, "rb");
    REQUIRE(f);
    size_t bytes = fread(code, 1, sizeof code, f);
    REQUIRE(bytes && feof(f));
    fclose(f);
    if (digest) {
        s2a_sha256 hash;
        uint8_t sum[32];
        s2a_sha256_init(&hash);
        s2a_sha256_update(&hash, code, bytes);
        s2a_sha256_final(&hash, sum);
        s2a_sha256_hex(sum, digest);
    }
    nvn_gpu_shader_src src = {.stage = stage, .kind = NVN_GPU_BLOB_SPIRV,
                              .blob = code, .bytes = bytes, .entry = "main", .precompiled = precompiled};
    memset(src.key, (int)key, sizeof src.key);
    nvn_gpu_shader shader;
    GPU(nvn_gpu_shader_load(&src, &shader, &err));
    return shader;
}

static nvn_gpu_pipe compute_pipe(const char *path, unsigned key) {
    nvn_gpu_shader sh = load(path, NVN_GPU_SH_CS, key, 1, compute_digest);
    nvn_gpu_stage_desc recipe = {.sh = sh};
    nvn_gpu_pipe pipe;
    GPU(nvn_gpu_cpipe_get(&recipe, NVN_GPU_PIPE_SYNC, &pipe, &err));
    nvn_gpu_shader_release(sh);
    return pipe;
}

static void dispatch(nvn_gpu_cmd cmd, nvn_gpu_pipe pipe) {
    nvn_gpu_set_pipe(cmd, pipe);
    nvn_gpu_dispatch(cmd, pipe, 1, 1, 1, NULL, 0);
}

static nvn_gpu_pipe graphics_pipe(const char *vs, const char *fs) {
    nvn_gpu_pipe_desc pd = {0};
    pd.cfmt[0] = NVN_FORMAT_RGBA8;
    pd.poly.mode = NVN_POLYGON_MODE_FILL;
    pd.color.logic_op = 3;
    pd.prim = 4;
    pd.samples = 1;
    pd.st[NVN_GPU_SH_VS].sh = load(vs, NVN_GPU_SH_VS, 0x44, 1, vertex_digest);
    pd.st[NVN_GPU_SH_FS].sh = load(fs, NVN_GPU_SH_FS, 0x55, 0, NULL);
    nvn_gpu_pipe pipe;
    GPU(nvn_gpu_pipe_get(&pd, NVN_GPU_PIPE_SYNC, &pipe, &err));
    nvn_gpu_shader_release(pd.st[NVN_GPU_SH_VS].sh);
    nvn_gpu_shader_release(pd.st[NVN_GPU_SH_FS].sh);
    return pipe;
}

static void draw(nvn_gpu_cmd cmd, nvn_gpu_view view, nvn_gpu_pipe pipe) {
    nvn_gpu_pass_desc pass = {.ncolor = 1, .w = 4, .h = 4, .layers = 1};
    pass.color[0].view = view;
    pass.color[0].load = NVN_GPU_LOAD_CLEAR;
    pass.color[0].store = NVN_GPU_STORE_STORE;
    nvn_gpu_pass_begin(cmd, &pass);
    nvn_gpu_set_pipe(cmd, pipe);
    nvn_gpu_dyn dyn = {.nvp = 1, .has_sc = 1, .sc = {0, 0, 4, 4}};
    dyn.vp[0][2] = dyn.vp[0][3] = 4;
    dyn.vp[0][5] = 1;
    nvn_gpu_set_dyn(cmd, &dyn);
    const nvn_gpu_draw_args args = {.prim = 4, .count = 3, .instances = 1};
    nvn_gpu_draw(cmd, &args);
    nvn_gpu_draw(cmd, &args);
    nvn_gpu_pass_end(cmd);
}

int main(int argc, char **argv) {
    REQUIRE(argc == 6);
    dq = atoi(argv[5]);
    if (!strcmp(argv[4], "fence")) mode = FENCE_LOSS;
    else if (!strcmp(argv[4], "submit")) mode = SUBMIT_LOSS;
    else if (!strcmp(argv[4], "concurrent")) mode = CONCURRENT_SUBMIT;
    else if (!strcmp(argv[4], "truncate")) mode = TRUNCATE;
    else REQUIRE(0);
    struct s2a_vk_device device;
    char why[256] = "";
    if (s2a_vk_device_create(&device, why, sizeof why)) { fprintf(stderr, "fixture device: %s\n", why); return 2; }
    device_handle = device.device;
    nvn_gpu_open_desc od = {.host_device = &device, .app_label = "device-lost-candidates"};
    GPU(nvn_gpu_open(&od, &err));

    nvn_gpu_pipe pipes[3];
    for (unsigned i = 0; i < 3; i++) pipes[i] = compute_pipe(argv[1], (i + 1) * 0x11);
    const nvn_gpu_pipe graphics = graphics_pipe(argv[2], argv[3]);
    const nvn_gpu_pipe bound_only = compute_pipe(argv[1], 0x66);
    const nvn_gpu_pipe discarded = compute_pipe(argv[1], 0x77);
    nvn_gpu_cmd abort_cmd;
    GPU(nvn_gpu_cmd_begin(NULL, &abort_cmd, &err));
    dispatch(abort_cmd, discarded);
    nvn_gpu_cmd_abort(abort_cmd);
    nvn_gpu_tex_desc td = {.usage = NVN_GPU_TEX_RENDER};
    td.d.target = NVN_TEXTURE_TARGET_2D;
    td.d.format = NVN_FORMAT_RGBA8;
    td.d.width = td.d.height = 4;
    td.d.depth = td.d.levels = 1;
    nvn_gpu_tex tex;
    nvn_gpu_view view;
    GPU(nvn_gpu_tex_create(&td, &tex, &err));
    GPU(nvn_gpu_view_create(tex, NULL, &view, &err));

    for (unsigned i = 0; i < 3; i++) {
        nvn_gpu_cmd cmd;
        GPU(nvn_gpu_cmd_begin(NULL, &cmd, &err));
        dispatch(cmd, pipes[i]);
        if (i == 1) {
            draw(cmd, view, graphics);
            nvn_gpu_set_pipe(cmd, bound_only);
            nvn_gpu_dispatch(cmd, bound_only, 0, 1, 1, NULL, 0);
            if (mode == TRUNCATE)
                for (unsigned k = 0x80; k <= 0x90; k++) dispatch(cmd, compute_pipe(argv[1], k));
        }
        atomic_store(&arm_fence, i == 1);
        atomic_store(&arm_submit, i == 2 && (mode == SUBMIT_LOSS || mode == CONCURRENT_SUBMIT));
        nvn_gpu_rc commit = nvn_gpu_cmd_commit(cmd, i + 1, done, NULL, &err);
        if (i == 2 && mode == SUBMIT_LOSS) REQUIRE(commit.code == NVN_GPU_E_DEVICE);
        else GPU(commit);
        if (i == 0) GPU(nvn_gpu_fence_wait(1, UINT64_C(5000000000), &err));
    }
    REQUIRE(vkDeviceWaitIdle(device.device) == VK_SUCCESS);
    release_wait();
    REQUIRE(!nvn_gpu_ok(nvn_gpu_fence_wait(2, UINT64_C(5000000000), &err)));
    GPU(nvn_gpu_close(UINT64_C(5000000000), &err));
    REQUIRE(s2a_vk_device_destroy(&device, 1) == 0);
    REQUIRE(atomic_load(&returned_loss) == (mode == SUBMIT_LOSS ? 2 : 1) &&
            atomic_load(&callbacks[1]) == NVN_GPU_DONE_OK + 1 &&
            atomic_load(&callbacks[2]) == NVN_GPU_DONE_FAILED + 1 && atomic_load(&callbacks[3]) == NVN_GPU_DONE_FAILED + 1);

    unsigned failures = 0;
    if (atomic_load(&gs_writebacks)) {
        printf("FAIL: DEVICE_LOST must not change the GS verdict, writebacks=%d\n", atomic_load(&gs_writebacks)); failures++;
    }
    const int submit = mode == SUBMIT_LOSS;
    const int queue = submit || mode == CONCURRENT_SUBMIT;
    if (loss_reports != 1 || correct_site != 1 || observed != !submit || pending != (submit || !queue) || uncertain != queue) {
        printf("FAIL: %s candidates expected first/site/observed/inflight/uncertain=1/1/%d/%d/%d, got %d/%d/%d/%d/%d\n",
               argv[4], !submit, submit || !queue, queue, loss_reports, correct_site, observed, pending, uncertain); failures++;
    }
    if (graphics_lib != 1 || non_candidates != 0 || bad_digest != 0) {
        printf("FAIL: expected one recorded library VS, no non-candidates and correct module digests, got %d/%d/%d\n",
               graphics_lib, non_candidates, bad_digest); failures++;
    }
    if (recorded_tail != 0 || truncation != (mode == TRUNCATE)) {
        printf("FAIL: expected no overflow row and truncation=%d, got %d/%d\n", mode == TRUNCATE, recorded_tail, truncation); failures++;
    }
    printf("device-lost candidates: mode=%s dq=%d failures=%u\n", argv[4], dq, failures);
    return failures ? 1 : 0;
}
