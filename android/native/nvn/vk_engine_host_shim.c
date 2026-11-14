// 共享 NVN 前端的宿主侧最小实现（直连包只编前端、没有游戏运行时时用它）。
// 诊断包（没有游戏运行时）用这里的桩；**与游戏运行时同编时，运行时自己的强定义优先**
// （全部标 weak，见下），所以正式 HLE 服务层不会被这些桩遮住。
// 与 tests 用的 frontend_test_host.c 同源，但去掉 App 已经提供的 now_ns/guest_ns/module_of，
// 并把"未实现入口/直连失败"打到 logcat，便于在设备上看见而不是静默。
#include <android/log.h>
#include <stddef.h>
#include <stdint.h>
#include "graphics/nvn/host/dm.h"
#include "graphics/nvn/host/front.h"
#include "graphics/nvn/host/game_profile.h"

#define TAG "S2Arm"
// 弱定义：真实运行时（runtime/src、native/runtime）里有同名强符号时以它为准。
#define S2A_HOST_WEAK __attribute__((weak))

// 刷新率由 JNI 探针从 Java Display 传进来；不写死 60，也不在没值时假装知道。
static double g_refresh_hz;
void s2a_vk_engine_host_set_refresh(double hz) { g_refresh_hz = hz; }
S2A_HOST_WEAK double front_display_refresh(char *name, size_t n) {
    if (name && n) name[0] = 0;
    return g_refresh_hz;
}
S2A_HOST_WEAK int front_screen_max_fps(void) { return g_refresh_hz > 0 ? (int)(g_refresh_hz + 0.5) : 0; }
// 诊断探针没有 guest 模块表（module_of 在 runtime/src/loader.c，属游戏运行时）；这里如实返回 NULL。
S2A_HOST_WEAK module_t *module_of(const void *p) { (void)p; return NULL; }
static s2a_nvn_profile g_profile;
S2A_HOST_WEAK const s2a_nvn_profile *s2a_nvn_prof(void) { return &g_profile; }
S2A_HOST_WEAK void dm_backtrace(uint64_t fp) { (void)fp; }
S2A_HOST_WEAK int dm_detclock_enabled(void) { return 0; }
S2A_HOST_WEAK void dm_guest_write_prepare(void *addr, size_t len) { (void)addr; (void)len; }
S2A_HOST_WEAK void dm_fault_hook_register(int (*fn)(void *, int, void *)) { (void)fn; }
S2A_HOST_WEAK void dm_guest_write_prep_register(void (*fn)(void *, size_t)) { (void)fn; }
// b9ae197d6 在共用 hle_nvn.c 里新调的两个（保留 NVN2 mesh 着色器源，供苹果宿主的现编补接口用，定义在 graphics/nvn/host/dsh_miss.inc）：
//   安卓直连走编译请求、不用这份缓存，空实现；没有它 APK 链接不过（未定义符号）
S2A_HOST_WEAK void dm_shader_mesh_hold(uint64_t code, const void *control) { (void)code; (void)control; }
S2A_HOST_WEAK void dm_shader_mesh_hold_key(const uint8_t key[8], uint64_t code, const void *control) { (void)key; (void)code; (void)control; }
S2A_HOST_WEAK void dm_shader_miss(const uint8_t key[8], uint64_t code, const void *control) {
    (void)code; (void)control;
    // 开局 SetShaders 会连续上报一千多个缺失键（实测 1662 条/3 秒）。逐条打 INFO 是纯启动期
    // I/O 开销，且这些条目在 direct 路径下并不进入缓存（真正编译走 compile request）。
    // 保留首 4 条键值用于定位，其余只按 256 条汇总，总数仍然可见。
    static unsigned long misses;
    unsigned long n = ++misses;
    if (n <= 4)
        __android_log_print(ANDROID_LOG_INFO, TAG,
                            "engine apk probe: shader miss #%lu %02x%02x%02x%02x%02x%02x%02x%02x",
                            n, key[0], key[1], key[2], key[3], key[4], key[5], key[6], key[7]);
    else if (n % 256 == 0)
        __android_log_print(ANDROID_LOG_INFO, TAG,
                            "engine apk probe: shader misses so far %lu (首 4 条逐条打印，其余每 256 条汇总)",
                            n);
}
S2A_HOST_WEAK void s2a_core_block_begin(void) {}
S2A_HOST_WEAK void s2a_core_block_end(void) {}
S2A_HOST_WEAK void s2a_direct_fail(const char *why) {
    __android_log_print(ANDROID_LOG_ERROR, TAG, "direct fail: %s", why ? why : "");
}
S2A_HOST_WEAK void nvn_big_entry(void) {}
S2A_HOST_WEAK void nvn_prof_entry(void) {}
S2A_HOST_WEAK void nvn_unimpl_entry(void) {
    __android_log_print(ANDROID_LOG_ERROR, TAG, "engine apk probe: unimplemented NVN entry");
}
S2A_HOST_WEAK void dm_guest_frame_tick(void) {}
S2A_HOST_WEAK uint64_t g_t0_ns;
