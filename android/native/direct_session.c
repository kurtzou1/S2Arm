#define _GNU_SOURCE 1   // Dl_info / dladdr（外挂驱动定位 hook 库目录）
#include "direct_session.h"
#include "direct_vk.h"
#include "direct_choice.h"   // direct-vulkan.txt 的唯一解析、AUTO 判定与 attempt 标记（#274）
#include "direct_callback.h"
#include "direct/selection.h"   // NVN 直连的冻结选择（s2a_direct_lookup 的 nvnBootstrapLoader 分支）
#include "vk_loader_shim.h"  // 窄 shim 的入口表（__wrap_* 在 vk_loader_shim.c；拦的是 Vulkan loader 一级的实例创建，归平台壳）
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
#include <android/log.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
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

// ---------- 外挂 Vulkan 驱动（libadrenotools，BSD-2-Clause） ----------
// 选择通道（按优先级）：
//   1) 环境变量 S2A_VK_DRIVER（宿主测试 / 调试）
//   2) 系统属性 debug.s2a.vk_driver（adb shell setprop；user 版设备上 untrusted_app 常读不到）
//   3) <externalFilesDir>/gpu_drivers/selected.txt 第一行（adb push，最可靠）
// 发布包里玩家只能走第二支的界面选驱动；上面三条（环境变量 / debug.s2a.vk_driver / selected.txt）
// 都是开发入口，只有 adb 或调试环境写得进去，不算玩家路径。
// 值是目录名（<filesDir>/gpu_drivers/<name>）或绝对路径。共享存储上的目录先复制进应用内部
// 私有目录：adrenotools 要求驱动位于内部数据目录，/sdcard 上没有执行权限。
// 没选驱动、或加载失败时返回 NULL，调用方照原路 dlopen("libvulkan.so")，系统驱动路径不变。
#define S2A_GPU_DRIVER_MAX_FILES 256
#define S2A_GPU_DRIVER_MAX_BYTES (512ull * 1024 * 1024)
#define S2A_ADRENOTOOLS_DRIVER_CUSTOM 1   // third_party/libadrenotools/include/adrenotools/priv.h

extern const char *s2a_android_gpu_driver_files_dir(void) __attribute__((weak));
extern const char *s2a_android_gpu_driver_external_dir(void) __attribute__((weak));

// 探针/选择过程的可靠日志：stderr 在 loadRuntime 早期不进 logcat，所以同时写 logcat 与
// <external>/gpu_drivers/probe-result.txt（adb pull 可读）。只在有选择/探针时写。
static void driver_log(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[vk-direct] %s\n", buf);
    __android_log_print(ANDROID_LOG_INFO, "S2Arm", "[vk-direct] %s", buf);
    const char *ext = s2a_android_gpu_driver_external_dir ? s2a_android_gpu_driver_external_dir() : NULL;
    if (ext && ext[0] == '/') {
        char path[PATH_MAX];
        if (snprintf(path, sizeof path, "%s/gpu_drivers/probe-result.txt", ext) < (int)sizeof path) {
            FILE *f = fopen(path, "a");
            if (f) { fprintf(f, "%s\n", buf); fclose(f); }
        }
    }
}

// 回落系统驱动必须留一条红级（玩家与维护方在 logcat 只看【红】）；stderr 与 probe-result.txt 通道保留。
static void driver_log_red(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[vk-direct] %s\n", buf);
    __android_log_print(ANDROID_LOG_ERROR, "S2Arm", "【红】nvk driver: %s", buf);
    const char *ext = s2a_android_gpu_driver_external_dir ? s2a_android_gpu_driver_external_dir() : NULL;
    if (ext && ext[0] == '/') {
        char path[PATH_MAX];
        if (snprintf(path, sizeof path, "%s/gpu_drivers/probe-result.txt", ext) < (int)sizeof path) {
            FILE *f = fopen(path, "a");
            if (f) { fprintf(f, "【红】%s\n", buf); fclose(f); }
        }
    }
}

static const char *driver_dir_or_null(const char *dir) { return dir && dir[0] == '/' ? dir : NULL; }

static int copy_file(const char *src, const char *dst) {
    int in = open(src, O_RDONLY | O_CLOEXEC), out = -1;
    if (in < 0) return -1;
    out = open(dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0700);
    if (out < 0) { close(in); return -1; }
    char buf[1 << 16];
    int failed = 0;
    for (;;) {
        ssize_t n = read(in, buf, sizeof buf);
        if (n == 0) break;
        if (n < 0) { if (errno == EINTR) continue; failed = 1; break; }
        for (ssize_t off = 0; off < n;) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w < 0) { if (errno == EINTR) continue; failed = 1; break; }
            off += w;
        }
        if (failed) break;
    }
    close(in);
    if (close(out) != 0) failed = 1;
    return failed ? -1 : 0;
}

// 逐级建目录（内部 files/gpu_drivers 可能还不存在）；已存在不算错。
static int ensure_dir(const char *path) {
    char tmp[PATH_MAX];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof tmp) return -1;
    memcpy(tmp, path, n + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(tmp, 0700) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, 0700) != 0 && errno != EEXIST) return -1;
    return 0;
}

// 平铺复制（只取普通文件，最多 256 个 / 512 MB）；同名文件覆盖，失败时下次重试。
static int stage_driver_dir(const char *src, const char *dst) {
    DIR *dir = opendir(src);
    if (!dir) return -1;
    if (ensure_dir(dst) != 0) { closedir(dir); return -1; }
    struct dirent *e;
    int files = 0, result = 0;
    unsigned long long total = 0;
    while (!result && (e = readdir(dir))) {
        if (e->d_name[0] == '.') continue;
        if (++files > S2A_GPU_DRIVER_MAX_FILES) { result = -1; break; }
        char from[PATH_MAX], to[PATH_MAX];
        struct stat st;
        if (snprintf(from, sizeof from, "%s/%s", src, e->d_name) >= (int)sizeof from ||
            snprintf(to, sizeof to, "%s/%s", dst, e->d_name) >= (int)sizeof to) { result = -1; break; }
        if (stat(from, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        total += (unsigned long long)st.st_size;
        if (total > S2A_GPU_DRIVER_MAX_BYTES) { result = -1; break; }
        result = copy_file(from, to);
    }
    closedir(dir);
    return result;
}

// meta.json 的 libraryName（只有一个键，不做完整 JSON 解析；目录分隔符一律拒绝）。
static int meta_library(const char *dir, char *out, size_t cap) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/meta.json", dir) >= (int)sizeof path) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    char buf[8192];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    const char *key = strstr(buf, "\"libraryName\"");
    if (!key) return -1;
    const char *colon = strchr(key + 13, ':');
    if (!colon) return -1;
    const char *begin = strchr(colon, '"');
    if (!begin) return -1;
    const char *end = strchr(begin + 1, '"');
    if (!end || end == begin + 1 || (size_t)(end - begin - 1) >= cap) return -1;
    memcpy(out, begin + 1, (size_t)(end - begin - 1));
    out[end - begin - 1] = 0;
    return strchr(out, '/') || strchr(out, '\\') ? -1 : 0;
}

// 选择值：环境变量 > 系统属性 > 外部私有目录的 selected.txt。
// 来源口径：发布包里玩家只能走第二支的界面选驱动；这三条都是开发入口，只有 adb / 调试环境写得进去。
static int driver_selection(char *out, size_t cap, const char **how) {
    const char *env = getenv("S2A_VK_DRIVER");
    if (env && *env) {
        if (strlen(env) >= cap) return -1;
        snprintf(out, cap, "%s", env);
        *how = "环境变量 S2A_VK_DRIVER";
        return 0;
    }
    char prop[PROP_VALUE_MAX];
    if (__system_property_get("debug.s2a.vk_driver", prop) > 0 && prop[0]) {
        if (strlen(prop) >= cap) return -1;
        snprintf(out, cap, "%s", prop);
        *how = "系统属性 debug.s2a.vk_driver";
        return 0;
    }
    const char *ext = driver_dir_or_null(s2a_android_gpu_driver_external_dir ? s2a_android_gpu_driver_external_dir() : NULL);
    if (!ext) return -1;
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/gpu_drivers/selected.txt", ext) >= (int)sizeof path) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    char line[PATH_MAX];
    size_t n = fread(line, 1, sizeof line - 1, f);
    fclose(f);
    line[n] = 0;
    char *p = line, *end;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    end = p + strlen(p);
    while (end > p && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) *--end = 0;
    if (!*p || strlen(p) >= cap) return -1;
    snprintf(out, cap, "%s", p);
    *how = "外部目录 selected.txt";
    return 0;
}

// hook 库（libhook_impl.so / libmain_hook.so）与 libs2arm_android.so 同目录；extractNativeLibs=false
// 时这个目录是 "<base.apk>!/lib/arm64-v8a"，linker 认 zip 路径（与 BananaNative 默认一致）。
// 开发运行库从 files/ 装载时 dladdr 给的目录里没有 hook：退到 capprobe 的包内装载 spec
// （bridge.cpp 设的 <sourceDir>!/lib/arm64-v8a/libs2a_capprobe.so）。
static int hook_dir_from_self(char *out, size_t cap) {
    Dl_info info;
    if (dladdr((void *)(uintptr_t)&hook_dir_from_self, &info) && info.dli_fname) {
        const char *slash = strrchr(info.dli_fname, '/');
        if (slash) {
            size_t n = (size_t)(slash - info.dli_fname);
            if (n > 0 && n < cap) {
                memcpy(out, info.dli_fname, n);
                out[n] = 0;
                char probe[PATH_MAX];
                if (strstr(out, "!/") ||
                    (snprintf(probe, sizeof probe, "%s/libhook_impl.so", out) < (int)sizeof probe && access(probe, F_OK) == 0))
                    return 0;
            }
        }
    }
    const char *helper = getenv("S2A_CAPPROBE_HELPER");
    if (helper && strstr(helper, "!/")) {
        const char *slash = strrchr(helper, '/');
        if (slash) {
            size_t n = (size_t)(slash - helper);
            if (n > 0 && n < cap) {
                memcpy(out, helper, n);
                out[n] = 0;
                return 0;
            }
        }
    }
    return -1;
}

// 选了驱动才调用：返回 libadrenotools 打开的系统 loader handle；没选 / 失败返回 NULL。
// 每个进程只试一次（探针先试，正式路径复用同一 handle，避免开第二个命名空间）。
static void *g_custom_loader;
static int g_custom_attempted;
static void *custom_driver_open(const char *state_dir) {
    if (g_custom_attempted) return g_custom_loader;
    g_custom_attempted = 1;
    const char *ext_now = s2a_android_gpu_driver_external_dir ? s2a_android_gpu_driver_external_dir() : NULL;
    fprintf(stderr, "[vk-direct] 驱动选择检查：external=%s\n", ext_now && ext_now[0] ? ext_now : "(空)");
    char selection[PATH_MAX];
    const char *how = "";
    if (driver_selection(selection, sizeof selection, &how)) {
        fprintf(stderr, "[vk-direct] 驱动选择：未设置\n");
        driver_log("选择：未设置");
        return NULL;
    }
    driver_log("选择=%s（来源 %s）", selection, how);
    const char *files = driver_dir_or_null(s2a_android_gpu_driver_files_dir ? s2a_android_gpu_driver_files_dir() : NULL);
    char dir[PATH_MAX];
    if (selection[0] == '/') {
        if (strlen(selection) >= sizeof dir) { fprintf(stderr, "[vk-direct] 自定义驱动：路径过长：%s\n", selection); driver_log_red("驱动加载失败：路径过长（来源 %s）；回落系统驱动", how); return NULL; }
        snprintf(dir, sizeof dir, "%s", selection);
    } else {
        if (!files) { fprintf(stderr, "[vk-direct] 自定义驱动：没有应用内部目录，无法解析 %s\n", selection); driver_log_red("驱动加载失败：没有应用内部目录（来源 %s）；回落系统驱动", how); return NULL; }
        if (snprintf(dir, sizeof dir, "%s/gpu_drivers/%s", files, selection) >= (int)sizeof dir) {
            fprintf(stderr, "[vk-direct] 自定义驱动：路径过长：%s\n", selection);
            driver_log_red("驱动加载失败：路径过长（来源 %s）；回落系统驱动", how);
            return NULL;
        }
    }
    // 共享存储没有执行权限：adrenotools 要求驱动在应用内部资料目录，先复制过去。
    if (!strncmp(dir, "/sdcard/", 8) || !strncmp(dir, "/storage/", 9) || !strncmp(dir, "/mnt/", 5)) {
        if (!files) { fprintf(stderr, "[vk-direct] 自定义驱动：%s 在共享存储，但没有内部目录可复制\n", dir); driver_log("没有内部目录可复制"); driver_log_red("驱动加载失败：共享存储驱动没有内部目录可复制（来源 %s）；回落系统驱动", how); return NULL; }
        const char *base = strrchr(dir, '/');
        base = base && base[1] ? base + 1 : "driver";
        char staged[PATH_MAX], staged_lib[PATH_MAX], library[128];
        struct stat st;
        if (snprintf(staged, sizeof staged, "%s/gpu_drivers/%s", files, base) >= (int)sizeof staged ||
            meta_library(dir, library, sizeof library) != 0 ||
            snprintf(staged_lib, sizeof staged_lib, "%s/%s", staged, library) >= (int)sizeof staged_lib) {
            fprintf(stderr, "[vk-direct] 自定义驱动：%s 不像驱动目录（meta.json/libraryName）\n", dir);
            driver_log("外部驱动目录不可用（meta.json/libraryName）");
            driver_log_red("驱动加载失败：%s 不像驱动目录（meta.json/libraryName；来源 %s）；回落系统驱动", dir, how);
            return NULL;
        }
        if (stat(staged_lib, &st) != 0 && stage_driver_dir(dir, staged) != 0) {
            int copy_errno = errno;
            fprintf(stderr, "[vk-direct] 自定义驱动：复制 %s → %s 失败（errno=%d）\n", dir, staged, copy_errno);
            driver_log("复制到内部失败（errno=%d）", copy_errno);
            driver_log_red("驱动加载失败：复制到内部失败（errno=%d；来源 %s）；回落系统驱动", copy_errno, how);
            return NULL;
        }
        snprintf(dir, sizeof dir, "%s", staged);
    }
    driver_log("加载目录=%s", dir);
    char library[128], lib[PATH_MAX], hooks[PATH_MAX], driver_dir[PATH_MAX + 1];
    if (meta_library(dir, library, sizeof library) != 0) {
        fprintf(stderr, "[vk-direct] 自定义驱动：%s/meta.json 没有可用的 libraryName\n", dir);
        driver_log_red("驱动加载失败：%s/meta.json 没有可用的 libraryName（来源 %s）；回落系统驱动", dir, how);
        return NULL;
    }
    struct stat st;
    if (snprintf(lib, sizeof lib, "%s/%s", dir, library) >= (int)sizeof lib || stat(lib, &st) != 0 || !S_ISREG(st.st_mode)) {
        fprintf(stderr, "[vk-direct] 自定义驱动：%s/%s 不存在\n", dir, library);
        driver_log_red("驱动加载失败：%s/%s 不存在（来源 %s）；回落系统驱动", dir, library, how);
        return NULL;
    }
    if (hook_dir_from_self(hooks, sizeof hooks) != 0) {
        fprintf(stderr, "[vk-direct] 自定义驱动：无法定位 libs2arm_android.so 所在目录（hook 库）\n");
        driver_log_red("驱动加载失败：无法定位 hook 库目录（来源 %s）；回落系统驱动", how);
        return NULL;
    }
    driver_log("库=%s；hooks=%s", library, hooks);
    void *adrenotools = dlopen("libadrenotools.so", RTLD_NOW | RTLD_LOCAL);
    driver_log("libadrenotools=%s", adrenotools ? "ok" : dlerror());
    typedef void *(*open_libvulkan_fn)(int, int, const char *, const char *, const char *, const char *, const char *, void **);
    open_libvulkan_fn open_vk = adrenotools ? (open_libvulkan_fn)dlsym(adrenotools, "adrenotools_open_libvulkan") : NULL;
    if (!open_vk) {
        const char *why_open = adrenotools ? "缺少 adrenotools_open_libvulkan" : dlerror();
        if (!why_open) why_open = "(dlerror 为空)";
        fprintf(stderr, "[vk-direct] 自定义驱动：libadrenotools.so 不可用（%s），回落系统驱动\n", why_open);
        driver_log_red("驱动加载失败：libadrenotools.so 不可用（%s；来源 %s）；回落系统驱动", why_open, how);
        return NULL;
    }
    size_t dl = strlen(dir);
    if (snprintf(driver_dir, sizeof driver_dir, "%s%s", dir, dl && dir[dl - 1] == '/' ? "" : "/") >= (int)sizeof driver_dir) {
        fprintf(stderr, "[vk-direct] 自定义驱动：路径过长：%s\n", dir);
        driver_log_red("驱动加载失败：路径过长（来源 %s）；回落系统驱动", how);
        return NULL;
    }
    void *handle = open_vk(RTLD_NOW | RTLD_LOCAL, S2A_ADRENOTOOLS_DRIVER_CUSTOM, state_dir, hooks,
                           driver_dir, library, NULL, NULL);
    if (!handle) {
        fprintf(stderr, "[vk-direct] 自定义驱动：adrenotools 加载 %s%s 失败（hooks 在 %s；logcat 看 adrenotools/hook_impl），回落系统驱动\n",
                driver_dir, library, hooks);
        driver_log_red("驱动加载失败：adrenotools 加载 %s%s 失败（hooks 在 %s；来源 %s）；回落系统驱动",
                       driver_dir, library, hooks, how);
        return NULL;
    }
    fprintf(stderr, "[vk-direct] 自定义驱动已加载：%s%s（来源 %s；hooks 在 %s）\n", driver_dir, library, how, hooks);
    driver_log("adrenotools_open_libvulkan=ok");
    g_custom_loader = handle;
    s2a_vk_loader_shim shim = {0};
    shim.gipa = (PFN_vkGetInstanceProcAddr)dlsym(handle, "vkGetInstanceProcAddr");
    if (shim.gipa) {
        shim.create = (PFN_vkCreateInstance)shim.gipa(NULL, "vkCreateInstance");
        shim.version = (PFN_vkEnumerateInstanceVersion)shim.gipa(NULL, "vkEnumerateInstanceVersion");
        shim.ext = (PFN_vkEnumerateInstanceExtensionProperties)shim.gipa(NULL, "vkEnumerateInstanceExtensionProperties");
        shim.layer = (PFN_vkEnumerateInstanceLayerProperties)shim.gipa(NULL, "vkEnumerateInstanceLayerProperties");
    }
    g_s2a_vk_shim = shim;
    driver_log("窄 shim %s", shim.create ? "就绪" : "不可用");
    return handle;
}

// nvk 回放层建实例前调用：把窄 shim 填上（game 构建里 vkCreateInstance 等被 --wrap 接管）。
// 没选驱动 / 失败返回 NULL，调用方照原路走系统 loader，行为不变。每进程只试一次。
void *s2a_android_vk_custom_driver_prepare(const char *state_dir) { return custom_driver_open(state_dir); }

// 隔离探针：只通过 adrenotools 打开驱动、建一个实例、枚举物理设备并打印驱动身份。
// 不改渲染路径；只用来回答“这个驱动包在 S2Arm 里能不能被 adrenotools 加载”。
int s2a_android_vk_probe_driver(void) {
    driver_log("探针开始");
    void *loader = custom_driver_open(NULL);
    driver_log("探针 loader=%p", loader);
    if (!loader) return -1;
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(loader, "vkGetInstanceProcAddr");
    if (!gipa) {
        fprintf(stderr, "[vk-direct] 驱动探针：loader 没有 vkGetInstanceProcAddr\n");
        return -1;
    }
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    if (!create) {
        fprintf(stderr, "[vk-direct] 驱动探针：loader 没有 vkCreateInstance\n");
        return -1;
    }
    VkApplicationInfo app = {0};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "S2Arm driver probe";
    app.applicationVersion = 1;
    app.pEngineName = "S2Arm";
    app.engineVersion = 1;
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    info.pApplicationInfo = &app;
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = create(&info, NULL, &instance);
    driver_log("探针 vkCreateInstance=%d", result);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[vk-direct] 驱动探针：vkCreateInstance 失败 VkResult=%d\n", result);
        return -1;
    }
    PFN_vkEnumeratePhysicalDevices enumerate =
        (PFN_vkEnumeratePhysicalDevices)gipa(instance, "vkEnumeratePhysicalDevices");
    uint32_t count = 0;
    if (enumerate) enumerate(instance, &count, NULL);
    if (!enumerate || count == 0) {
        fprintf(stderr, "[vk-direct] 驱动探针：0 个物理设备\n");
        driver_log("探针 0 个物理设备");
        PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(instance, "vkDestroyInstance");
        if (destroy) destroy(instance, NULL);
        return -1;
    }
    VkPhysicalDevice *devices = calloc(count, sizeof *devices);
    if (devices) enumerate(instance, &count, devices);
    PFN_vkGetPhysicalDeviceProperties get_props =
        (PFN_vkGetPhysicalDeviceProperties)gipa(instance, "vkGetPhysicalDeviceProperties");
    PFN_vkGetPhysicalDeviceProperties2 get_props2 =
        (PFN_vkGetPhysicalDeviceProperties2)gipa(instance, "vkGetPhysicalDeviceProperties2");
    for (uint32_t i = 0; devices && i < count; i++) {
        VkPhysicalDeviceProperties props;
        memset(&props, 0, sizeof props);
        if (get_props) get_props(devices[i], &props);
        char driver[256] = "?", driver_info[256] = "";
        if (get_props2) {
            VkPhysicalDeviceDriverProperties dp;
            memset(&dp, 0, sizeof dp);
            dp.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
            VkPhysicalDeviceProperties2 props2;
            memset(&props2, 0, sizeof props2);
            props2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
            props2.pNext = &dp;
            get_props2(devices[i], &props2);
            snprintf(driver, sizeof driver, "%s", dp.driverName);
            snprintf(driver_info, sizeof driver_info, "%s", dp.driverInfo);
        }
        driver_log("探针设备 %u/%u：%s | driver=%s（%s）| api=%u.%u.%u vendor=0x%04x device=0x%04x",
                i + 1, count, props.deviceName, driver, driver_info,
                VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion),
                VK_VERSION_PATCH(props.apiVersion), props.vendorID, props.deviceID);
    }
    // 窄调度实验：私有 loader 建的 instance，交给系统 loader 的全局命令用。
    // 枚举 / 建设备 / 建命令池与命令缓冲都成功，才说明可以只包创建函数、其余命令继续走系统 loader。
    {
        void *sys = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
        PFN_vkEnumeratePhysicalDevices sys_enumerate =
            sys ? (PFN_vkEnumeratePhysicalDevices)dlsym(sys, "vkEnumeratePhysicalDevices") : NULL;
        PFN_vkGetPhysicalDeviceProperties sys_get_props =
            sys ? (PFN_vkGetPhysicalDeviceProperties)dlsym(sys, "vkGetPhysicalDeviceProperties") : NULL;
        PFN_vkGetPhysicalDeviceQueueFamilyProperties sys_get_qf =
            sys ? (PFN_vkGetPhysicalDeviceQueueFamilyProperties)dlsym(sys, "vkGetPhysicalDeviceQueueFamilyProperties") : NULL;
        PFN_vkCreateDevice sys_create_device = sys ? (PFN_vkCreateDevice)dlsym(sys, "vkCreateDevice") : NULL;
        PFN_vkDestroyDevice sys_destroy_device = sys ? (PFN_vkDestroyDevice)dlsym(sys, "vkDestroyDevice") : NULL;
        PFN_vkCreateCommandPool sys_create_pool = sys ? (PFN_vkCreateCommandPool)dlsym(sys, "vkCreateCommandPool") : NULL;
        PFN_vkDestroyCommandPool sys_destroy_pool = sys ? (PFN_vkDestroyCommandPool)dlsym(sys, "vkDestroyCommandPool") : NULL;
        PFN_vkAllocateCommandBuffers sys_alloc_cb = sys ? (PFN_vkAllocateCommandBuffers)dlsym(sys, "vkAllocateCommandBuffers") : NULL;
        PFN_vkBeginCommandBuffer sys_begin = sys ? (PFN_vkBeginCommandBuffer)dlsym(sys, "vkBeginCommandBuffer") : NULL;
        PFN_vkEndCommandBuffer sys_end = sys ? (PFN_vkEndCommandBuffer)dlsym(sys, "vkEndCommandBuffer") : NULL;
        driver_log("窄调度 系统 loader=%p 函数=%d/%d/%d/%d", sys,
                   sys_enumerate != NULL, sys_get_qf != NULL, sys_create_device != NULL, sys_create_pool != NULL);
        if (sys_enumerate && sys_get_qf && sys_create_device) {
            uint32_t sc = 0;
            VkResult sr = sys_enumerate(instance, &sc, NULL);
            driver_log("窄调度 系统枚举私有实例：VkResult=%d count=%u", sr, sc);
            if (sr == VK_SUCCESS && sc > 0) {
                VkPhysicalDevice *sd = calloc(sc, sizeof *sd);
                if (sd && sys_enumerate(instance, &sc, sd) == VK_SUCCESS) {
                    VkPhysicalDeviceProperties sp;
                    memset(&sp, 0, sizeof sp);
                    if (sys_get_props) sys_get_props(sd[0], &sp);
                    driver_log("窄调度 系统设备：%s", sp.deviceName);
                    uint32_t qn = 0;
                    sys_get_qf(sd[0], &qn, NULL);
                    VkQueueFamilyProperties *qf = calloc(qn ? qn : 1, sizeof *qf);
                    uint32_t qi = 0xffffffffu;
                    if (qf) {
                        sys_get_qf(sd[0], &qn, qf);
                        for (uint32_t i = 0; i < qn; i++)
                            if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && qf[i].queueCount) { qi = i; break; }
                        free(qf);
                    }
                    driver_log("窄调度 图形队列=%d（共 %u 族）", qi == 0xffffffffu ? -1 : (int)qi, qn);
                    if (qi != 0xffffffffu) {
                        float prio = 1.0f;
                        VkDeviceQueueCreateInfo qci;
                        memset(&qci, 0, sizeof qci);
                        qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
                        qci.queueFamilyIndex = qi;
                        qci.queueCount = 1;
                        qci.pQueuePriorities = &prio;
                        VkDeviceCreateInfo dci;
                        memset(&dci, 0, sizeof dci);
                        dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
                        dci.queueCreateInfoCount = 1;
                        dci.pQueueCreateInfos = &qci;
                        VkDevice dev = VK_NULL_HANDLE;
                        VkResult dr = sys_create_device(sd[0], &dci, NULL, &dev);
                        driver_log("窄调度 系统 vkCreateDevice=%d", dr);
                        if (dr == VK_SUCCESS && dev) {
                            if (sys_create_pool && sys_alloc_cb && sys_begin && sys_end) {
                                VkCommandPoolCreateInfo pci;
                                memset(&pci, 0, sizeof pci);
                                pci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
                                pci.queueFamilyIndex = qi;
                                VkCommandPool pool = VK_NULL_HANDLE;
                                VkResult pr = sys_create_pool(dev, &pci, NULL, &pool);
                                driver_log("窄调度 vkCreateCommandPool=%d", pr);
                                if (pr == VK_SUCCESS) {
                                    VkCommandBufferAllocateInfo ai;
                                    memset(&ai, 0, sizeof ai);
                                    ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
                                    ai.commandPool = pool;
                                    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
                                    ai.commandBufferCount = 1;
                                    VkCommandBuffer cb = VK_NULL_HANDLE;
                                    VkResult ar = sys_alloc_cb(dev, &ai, &cb);
                                    driver_log("窄调度 vkAllocateCommandBuffers=%d", ar);
                                    if (ar == VK_SUCCESS) {
                                        VkCommandBufferBeginInfo bi;
                                        memset(&bi, 0, sizeof bi);
                                        bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
                                        VkResult br = sys_begin(cb, &bi);
                                        VkResult er = br == VK_SUCCESS ? sys_end(cb) : br;
                                        driver_log("窄调度 命令缓冲 begin=%d end=%d", br, er);
                                    }
                                    if (sys_destroy_pool) sys_destroy_pool(dev, pool, NULL);
                                }
                            }
                            if (sys_destroy_device) sys_destroy_device(dev, NULL);
                        }
                    }
                }
                free(sd);
            }
        }
    }
#ifdef S2A_ANDROID_VK_LOADER_SHIM
    // 用**全局** vkCreateInstance（应被 --wrap 转到私有 loader）再建一个实例，
    // 直接读它的物理设备 driverName，验证窄 shim 真的把创建路由过去了。
    {
        VkInstance shim = VK_NULL_HANDLE;
        VkResult rr = vkCreateInstance(&info, NULL, &shim);
        driver_log("窄 shim 全局 vkCreateInstance=%d", rr);
        if (rr == VK_SUCCESS && shim) {
            PFN_vkEnumeratePhysicalDevices pe = (PFN_vkEnumeratePhysicalDevices)gipa(shim, "vkEnumeratePhysicalDevices");
            uint32_t n2 = 0;
            if (pe) pe(shim, &n2, NULL);
            char d2[256] = "?";
            if (pe && n2) {
                VkPhysicalDevice *sd2 = calloc(n2, sizeof *sd2);
                if (sd2 && pe(shim, &n2, sd2) == VK_SUCCESS) {
                    PFN_vkGetPhysicalDeviceProperties2 gp2 =
                        (PFN_vkGetPhysicalDeviceProperties2)gipa(shim, "vkGetPhysicalDeviceProperties2");
                    if (gp2) {
                        VkPhysicalDeviceDriverProperties dp;
                        memset(&dp, 0, sizeof dp);
                        dp.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
                        VkPhysicalDeviceProperties2 p2;
                        memset(&p2, 0, sizeof p2);
                        p2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
                        p2.pNext = &dp;
                        gp2(sd2[0], &p2);
                        snprintf(d2, sizeof d2, "%s", dp.driverName);
                    }
                }
                free(sd2);
            }
            driver_log("窄 shim 设备=%u driver=%s", n2, d2);
            PFN_vkDestroyInstance di = (PFN_vkDestroyInstance)gipa(shim, "vkDestroyInstance");
            if (di) di(shim, NULL);
        }
    }
#endif
    free(devices);
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(instance, "vkDestroyInstance");
    if (destroy) destroy(instance, NULL);
    return 0;
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
    loader = custom_driver_open(state_dir);   // 没选驱动 / 失败 → NULL，下面照原路走系统 loader
    if (!loader) loader = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
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
// Switch 2 的 SDK 接管（共用实现 graphics/nvn/gfx/nvn/nvn2.c；次序与条件同 runtime/src/gfxmode.c：nn::vi 先、nv:: 后）：
//   游戏导入的 nv::（GPU 驱动启动层）与 nn::vi（显示层）解析到宿主，条件同 nvnBootstrapLoader：选择事务已冻结为 NVN 直连。
//   不接的后果：nv::InitializeGraphics 落到 sdk 原实现，经 nn::gs::sdk::BootGraphicsSystem → nn::gsv::BootWithRemoteMemory →
//   nn::am::GetGraphicsSupervisor 去起游戏自带的 NVN2 驱动，轮询 ISelfController 命令 2000（服务层没有），游戏永远黑屏。
//   Switch 1 进程两个入口都回 NULL（nvn2_on 为 0）。nn::codec / syncpt / gs 那一族（s2a_codec_entry，nvn2_codec.c，含 Apple 视频解码）安卓没链，不在这里。
static void *ns2_sdk_entry(const char *name) {
    if (strncmp(name, "_Z", 2) && strncmp(name, "Nv", 2)) return NULL;
    const struct s2a_direct_selection *selection = s2a_direct_selection_current();
    if (!selection || selection->mode != 1) return NULL;
    extern void *nvn2_vi_entry(const char *name) __attribute__((weak));
    extern void *s2a_nv_entry(const char *name) __attribute__((weak));
    void *f = NULL;
    if ((!strncmp(name, "_ZN2nn2vi", 9) || !strncmp(name, "_ZNK2nn2vi", 10)) && nvn2_vi_entry) f = nvn2_vi_entry(name);
    if (!f && s2a_nv_entry) f = s2a_nv_entry(name);
    return f;
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
    void *ns2 = name ? ns2_sdk_entry(name) : NULL;
    if (ns2) {
        static _Atomic int said;
        if (!atomic_exchange_explicit(&said, 1, memory_order_relaxed)) {   // 只记第一个：stderr 在发布包上下一局才回放，同一行写系统日志，当局就能核对
            fprintf(stderr, "[s2a] Switch 2 SDK 接管（NVN 直连）：游戏导入 %s 起，nv:: / nn::vi 由宿主应答\n", name);
            __android_log_print(ANDROID_LOG_INFO, "S2Arm", "[s2a] Switch 2 SDK 接管（NVN 直连）：游戏导入 %s 起，nv:: / nn::vi 由宿主应答", name);
        }
        return (uint64_t)(uintptr_t)sw_xstack_wrap(name, ns2);
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
