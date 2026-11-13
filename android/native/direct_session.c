#include "direct_session.h"
#include "direct_vk.h"
#include "direct_choice.h"   // direct-vulkan.txt 的唯一解析、AUTO 判定与 attempt 标记（#274）
#include "direct_callback.h"
#include "direct/selection.h"   // NVN 直连的冻结选择（s2a_direct_lookup 的 nvnBootstrapLoader 分支）
#include "capprobe/capprobe.h"  // #1456 runtime-lost 回写
S2A_CAPPROBE_RUNTIME_LOST_WEAK_REF;   // 宿主链接单元无 bridge.cpp 时解析为 NULL
#include <errno.h>
#include <stdatomic.h>
// 浮层的「成功交给呈现」计数：新回放层（缺省）取 rp_present_stats 的已上屏数，旧层（对照诊断用）取 mtl_present_count。
// 两个都是弱引用：哪一层链进来就读哪一层，都没有时返回 0。
extern void rp_present_stats(uint64_t *shown, uint64_t *dropped) __attribute__((weak));
extern uint64_t mtl_present_count(void) __attribute__((weak));

uint64_t s2a_android_nvn_present_count(void) {
    if (rp_present_stats) { uint64_t shown = 0; rp_present_stats(&shown, NULL); return shown; }
    return mtl_present_count ? mtl_present_count() : 0;
}


#if defined(S2A_ANDROID_GAME_RUNTIME)
#include "s2a_hostapi.h"
#include "runtime/vm/memory.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *sw_xstack_wrap(const char *, void *);
extern void s2a_core_block_begin(void);
extern void s2a_core_block_end(void);
extern int s2a_mem_readable(uint64_t, uint64_t);

static pthread_mutex_t choice_lock = PTHREAD_MUTEX_INITIALIZER;
static int requested, frozen;
static _Atomic int mode;
static void *loader;
static const struct s2a_wsi_api *lease_api;
static _Atomic(int64_t (*)(void)) layer_query;
static int64_t layer_id;
static void *window_token;
static char fail_path[4096];
static char attempt_dir[4096];   // 直连会话的状态目录：正常停止时据此清 attempt / fail 标记
static int session_choice;       // 已提交的直连会话是手动还是 AUTO（s2a_vk_session_end 据此决定清不清 fail）
static _Atomic int failed_now;   // 本局写过 vulkan-direct.fail（设备丢失 / 致命）：正常停止也不清它
static unsigned skipped;
// 客体事实：本局重定位是否真的问了 NVN 入口（nvnBootstrapLoader）。runtime 用它和
// vk-direct 实验开关对账，不按游戏名或包内容猜前端。
static _Atomic int nvn_guest;

static PFN_vkVoidFunction symbol(const char *name) { return (PFN_vkVoidFunction)dlsym(loader, name); }

static void mark_failure(const char *why) {
    atomic_store(&failed_now, 1);
    int fd = open(fail_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd >= 0) { (void)!write(fd, why, strlen(why)); (void)!write(fd, "\n", 1); close(fd); }
}
static void error(const char *operation, VkResult result) {
    fprintf(stderr, "[vk-direct] 【红】%s: VkResult=%d\n", operation, result);
    if (result == VK_ERROR_DEVICE_LOST) {
        mark_failure(operation);
        // #1456：真实 DEVICE_LOST 回写当前指纹 capprobe 结果（source=runtime-lost，
        // 只记指纹不记游戏），下次启动直接走规避不再探。
        if (s2a_capprobe_runtime_lost) s2a_capprobe_runtime_lost();
        const s2a_host_api_v1 *h = s2a_host_get();
        if (h && h->stop) h->stop->request_stop(h->host, S2A_HOST_STOP_DEVICE_LOST, operation);
    }
}
static _Noreturn void fatal(const char *operation) {
    fprintf(stderr, "[vk-direct] 【红】无法继续：%s\n", operation);
    mark_failure(operation);
    const s2a_host_api_v1 *h = s2a_host_get();
    if (h && h->stop) h->stop->request_stop(h->host, S2A_HOST_STOP_ERROR, operation);
    abort();
}

static const struct s2a_wsi_api *window(void *token) {
    // ANativeWindow base is a public Android ABI, not a guest object address.
    // The guest SDK constructs it; only a validated guest allocation is read.
    if (!token || !s2a_mem_readable((uint64_t)(uintptr_t)token, 8)) return NULL;
    uint32_t header[2]; memcpy(header, token, sizeof header);
    int64_t (*query)(void) = atomic_load_explicit(&layer_query, memory_order_acquire);
    int64_t current = query ? query() : 0;
    fprintf(stderr, "[vk-direct] vi窗口：magic=%08x version=%u layer=%lld\n", header[0], header[1], (long long)current);
    // SDK ANativeWindow uses ANDROID_NATIVE_MAKE_CONSTANT('_','w','n','d').
    if (header[0] != 0x5f776e64u || header[1] < 8 || header[1] > 4096 || current <= 0) return NULL;
    pthread_mutex_lock(&choice_lock);
    if (!window_token) { window_token = token; layer_id = current; }
    int same = window_token == token && layer_id == current;
    pthread_mutex_unlock(&choice_lock);
    return same ? lease_api : NULL;
}

// choice：S2A_VK_CHOICE_GENERIC / DIRECT（手动）/ AUTO（冷启动准备时按包与上局状态判，direct_choice.h）
int s2a_android_vk_select(int direct) {
    if (direct != S2A_VK_CHOICE_GENERIC && direct != S2A_VK_CHOICE_DIRECT && direct != S2A_VK_CHOICE_AUTO) return EINVAL;
    pthread_mutex_lock(&choice_lock);
    int result = frozen && requested != direct ? EBUSY : 0;
    if (!result) requested = direct;
    pthread_mutex_unlock(&choice_lock);
    return result;
}

int s2a_android_vk_session_prepare(const struct s2a_wsi_api *api, const char *game_dir, const char *state_dir) {
    pthread_mutex_lock(&choice_lock);
    if (frozen) { pthread_mutex_unlock(&choice_lock); return EALREADY; }
    frozen = 1;
    int choice = requested;
    pthread_mutex_unlock(&choice_lock);
    if (choice == S2A_VK_CHOICE_GENERIC) return 0;
    // AUTO（#274）：本包没有有效描述、或状态目录里有上局的 fail / attempt 标记 → 回通用，打一行写明读到了哪个文件；
    //   之后准备失败（attempt 写不了、libvulkan 打不开、桥接配置失败）也在提交前回通用并说明原因。
    //   手动直连（DIRECT）照旧：任何一步失败都返回错误，由 runtime 报红停在报红页，不悄悄改通用。
    //   每条 AUTO 路径只打一行 "[vk-direct] AUTO → …"：回通用在回的那一刻打，走直连在提交后打。
    int automatic = choice == S2A_VK_CHOICE_AUTO;
    char why[512] = "";
    if (automatic && !s2a_vk_auto_resolve(game_dir, state_dir, why, sizeof why)) {
        fprintf(stderr, "[vk-direct] AUTO → 通用：%s\n", why);
        return 0;
    }
    if (!api || api->size < sizeof *api || api->abi_version != S2A_WSI_ABI_VERSION || !api->lease ||
        !api->take || !api->release_window || !api->released || !game_dir || !state_dir) return EINVAL;
    // direct-vulkan.txt 是“Vulkan 客体直连”的资格与模块合同，不是可选的减项开关：没有它就没有任何依据说明
    // 本包属于该前端，手动直连必须准确失败（ENOENT / EINVAL），让错误开关在起局前报红，而不是在通用 GPU
    // 已关闭的情况下把客体跑成黑屏。解析只有一份（direct_choice.c），与 s2a_vk_lib_ready 同一结论。
    // NVN 直连走 direct/selection.c 的 graphics.v1.json 合同，不经过这里。
    unsigned mask = 0;
    int result = s2a_vk_descriptor_read(game_dir, &mask);
    if (result) return result;
    if (snprintf(fail_path, sizeof fail_path, "%s/vulkan-direct.fail", state_dir) >= (int)sizeof fail_path) return ENAMETOOLONG;
    if (snprintf(attempt_dir, sizeof attempt_dir, "%s", state_dir) >= (int)sizeof attempt_dir) return ENAMETOOLONG;
    // attempt 标记在碰 Vulkan 之前写：之后崩溃或被杀都留下它，下次 AUTO 据此回通用
    if ((result = s2a_vk_attempt_begin(state_dir))) {
        if (!automatic) return result;
        fprintf(stderr, "[vk-direct] AUTO → 通用：写不了 %s/vulkan-direct.attempt（errno=%d）\n", state_dir, result);
        attempt_dir[0] = 0;
        return 0;
    }
    lease_api = api;
    loader = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!loader) result = ENOENT;
    else {
        struct s2a_direct_vk_host h = {(PFN_vkGetInstanceProcAddr)symbol("vkGetInstanceProcAddr"),
            (PFN_vkGetDeviceProcAddr)symbol("vkGetDeviceProcAddr"), symbol, sw_xstack_wrap,
            error, fatal, s2a_core_block_begin, s2a_core_block_end, window, s2a_android_vk_guest_callback};
        result = s2a_android_vk_configure(&h);
    }
    if (result) {
        // 没提交直连：撤掉本次 attempt（不是“上局没正常结束”）。手动 → 报红；AUTO → 回通用并说明
        s2a_vk_attempt_end(state_dir);
        attempt_dir[0] = 0;
        lease_api = NULL;   // loader 不 dlclose：配置失败时桥接层是否还留着取自它的指针不归这里判，同改前一样留着
        if (!automatic) return result;
        fprintf(stderr, "[vk-direct] AUTO → 通用：%s失败（errno=%d）\n", result == ENOENT ? "打开 libvulkan.so " : "直连桥接配置", result);
        return 0;
    }
    skipped = mask;
    session_choice = choice;
    atomic_store_explicit(&mode, 1, memory_order_release);
    if (automatic) fprintf(stderr, "[vk-direct] AUTO → Vulkan直连：%s\n", why);
    fprintf(stderr, "[vk-direct] 冷启动模式已冻结：Vulkan直连，通用GPU线程不启动\n");
    return 0;
}

int s2a_android_vk_set_layer_query(int64_t (*query)(void)) {
    if (!query || atomic_load(&mode) != 1) return EINVAL;
    int64_t (*expected)(void) = NULL;
    return atomic_compare_exchange_strong(&layer_query, &expected, query) ? 0 : EALREADY;
}
int s2a_gfx_mode(void) { return atomic_load_explicit(&mode, memory_order_acquire); }
// 本局客体是否导入过 NVN 入口。只在重定位问过 nvnBootstrapLoader 后才为 1；
// runtime 用它判定“vk-direct 实验开关 + NVN 客体”这个必然黑屏的组合。
int s2a_android_vk_nvn_guest(void) { return atomic_load_explicit(&nvn_guest, memory_order_acquire); }
int s2a_android_vk_skip_module(const char *name) {
    return s2a_gfx_mode() == 1 && name && strlen(name) == 7 && !strncmp(name, "subsdk", 6) &&
        name[6] >= '0' && name[6] <= '9' && (skipped & (1u << (name[6] - '0')));
}
uint64_t s2a_direct_lookup(const char *name) {
    // 本线 NVN 直连前端（共享 hle_nvn.c 的 HLE_FORCE 入口）：只在 relocation 前的
    // 选择事务（direct/selection.c）冻结为 direct 时接管 nvnBootstrapLoader。
    // main 的 Switch Vulkan 分派保持原样：其余名字仍只认 vk*。
    if (name && !strcmp(name, "nvnBootstrapLoader")) {
        atomic_store_explicit(&nvn_guest, 1, memory_order_relaxed);
        const struct s2a_direct_selection *selection = s2a_direct_selection_current();
        if (!selection || selection->mode != 1) return 0;
        extern void *h_nvnBootstrapLoader(const char *name) __attribute__((weak));
        extern void s2a_nvn_set_xwrap(void *(*)(const char *, void *)) __attribute__((weak));
        if (s2a_nvn_set_xwrap) s2a_nvn_set_xwrap(sw_xstack_wrap);   // 非命令录制 NVN 实现切大宿主栈（hle_nvn.c）
        if (!h_nvnBootstrapLoader) {
            fprintf(stderr, "[s2a] FATAL direct graphics selected but the shared NVN frontend is not linked\n");
            abort();
        }
        return (uint64_t)(uintptr_t)sw_xstack_wrap(name, (void *)h_nvnBootstrapLoader);   // 对齐 gfxmode.c 的 Apple 侧包装
    }
    return name && s2a_gfx_mode() == 1 && !strncmp(name, "vk", 2) ? (uint64_t)(uintptr_t)s2a_vk_entry(name) : 0;
}
#else
// 非游戏运行时构建（诊断壳）没有直连：手动直连 ENOTSUP，AUTO 与通用一样就是通用
int s2a_android_vk_select(int direct) {
    return direct == S2A_VK_CHOICE_DIRECT ? ENOTSUP : direct == S2A_VK_CHOICE_GENERIC || direct == S2A_VK_CHOICE_AUTO ? 0 : EINVAL;
}
int s2a_android_vk_session_prepare(const struct s2a_wsi_api *api, const char *game, const char *dir) { (void)api; (void)game; (void)dir; return 0; }
int s2a_android_vk_skip_module(const char *name) { (void)name; return 0; }
int s2a_android_vk_set_layer_query(int64_t (*query)(void)) { (void)query; return ENOTSUP; }
int s2a_android_vk_nvn_guest(void) { return 0; }   // 没有 NVN 前端接管时不可能有 NVN 客体直连
#endif

int s2a_android_vk_session_stop(void) {
    int result=s2a_android_vk_stop();
#if defined(S2A_ANDROID_GAME_RUNTIME)
    extern int s2a_svc_stopping(void);
    if(result && s2a_svc_stopping())result=s2a_android_vk_terminal_drain();
    // 直连会话结束清标记（#274，规则同 NVN 直连 s2a_direct_finish）：正常停止清 attempt，手动直连且本局
    // 没写 fail 时再清上局的 fail；停不干净就都留着，下次 AUTO 回通用
    if(attempt_dir[0] && s2a_gfx_mode()==1){
        s2a_vk_session_end(attempt_dir, session_choice, !result, atomic_load(&failed_now));
        if(!result) attempt_dir[0]=0;
    }
#endif
    return result;
}
uint64_t s2a_android_vk_present_count(void) { return s2a_android_vk_presents(); }
