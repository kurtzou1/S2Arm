// Link stand-ins for the s2a_native functions the C# service layer binds with
// DirectPInvoke (services/S2A.Services/Native.cs Imports), so the single-library
// build (NativeAOT static library + this host) links before the shared native core
// runs on Android through platform/plat.h. Signatures come from the ABI header.
// The diagnostic width, actual surface height, and boot mark are implemented (the self-test checks both
// directions of a direct C# -> C call); every other function returns the header's
// failure value and logs its first call. Remove when the native core is linked.
#include "s2a_native.h"
#include "s2a_session.h"
#include "s2a_text_input.h"
#include "s2a_native_stub.h"
#include "screen_metrics.h"
#include <android/log.h>
#include <stdatomic.h>
#include <string.h>

static atomic_int g_screen_w;
static char g_boot_mark[64];

// Product diagnostic mode has no native session core. Never certify a
// prepared/running/joined/quiescent session just to satisfy static imports.
#define session_unbacked() do { \
        static atomic_flag said = ATOMIC_FLAG_INIT; \
        if (!atomic_flag_test_and_set(&said)) \
            __android_log_print(ANDROID_LOG_ERROR, "S2Arm", "【红】%s: diagnostic target has no native session core", __func__); \
    } while (0)
int s2a_session_prepare(void) { session_unbacked(); return -1; }
int s2a_session_rebuild_supported(void) { session_unbacked(); return 0; }
unsigned s2a_session_generation(void) { session_unbacked(); return 0; }
int s2a_session_service_failed(unsigned generation) { (void)generation; session_unbacked(); return -1; }
void s2a_session_process_exit(unsigned generation) { (void)generation; session_unbacked(); }
int s2a_host_session_state(void) { session_unbacked(); return S2A_SESSION_FAILED; }
int s2a_thread_session_joined(void) { session_unbacked(); return 0; }
int s2a_gate_inflight(void) { session_unbacked(); return -1; }
#undef session_unbacked

void s2a_android_set_screen_w(int width) { atomic_store(&g_screen_w, width); }
const char *s2a_android_last_boot_mark(void) { return g_boot_mark; }

#define unbacked(name) do { \
        static atomic_flag said = ATOMIC_FLAG_INIT; \
        if (!atomic_flag_test_and_set(&said)) \
            __android_log_print(ANDROID_LOG_WARN, "S2Arm", "%s: link stub, the native core does not run on Android yet", name); \
    } while (0)

int s2a_screen_w(void) { return atomic_load(&g_screen_w); }
int s2a_screen_h(void) { int w, h; return s2a_android_screen_metrics(&w, &h) ? h : 0; }
void s2a_boot_mark(const char *stage) { strncpy(g_boot_mark, stage ? stage : "", sizeof g_boot_mark - 1); }

int s2a_fps_live(void) { unbacked(__func__); return 0; }
const char *s2a_cpatch_tables_dir(void) { unbacked(__func__); return ""; }   // runtime/src/cpatch.c：随包补丁表目录（FpsLocker.cs 找帧率配置）；诊断库没有 = 空串，服务层照常跳过
int s2a_cpatch_cheat(const char *file, const char *name, int on) { (void)file; (void)name; (void)on; unbacked(__func__); return 0; }   // runtime/src/cpatch.c：编进包的金手指开关（Cheats.cs）；0 = 包里没有，交运行时 Tamper   // runtime/src/fps.c：60 帧此刻是否真在生效（服务层 FpsLocker.cs 每秒问）；诊断库里不跑核心 = 不生效
uint32_t s2a_handle_new(uint32_t kind, uint64_t cookie) { (void)kind; (void)cookie; unbacked(__func__); return 0; }
int s2a_handle_get(uint32_t h, uint32_t *kind, uint64_t *cookie) { (void)h; (void)kind; (void)cookie; unbacked(__func__); return 0; }
int s2a_handle_close(uint32_t h) { (void)h; unbacked(__func__); return 0; }
int s2a_widen_game(void) { return 0; }
int s2a_widen_layout(void) { return 0; }
int s2a_widen_full(void) { return 0; }
// The diagnostic target has no guest threads to freeze. Game mode excludes
// this file and reads the actual freeze state from runtime/src/thread.c.
int s2a_guest_frozen(void) { return 0; }
// The Android host links real s2a_alt_phase (alt.c) and s2a_gfx_mode (plat_android.c).
uint64_t s2a_event_create(uint32_t *h_read, uint32_t *h_write) {
    if (h_read) *h_read = 0;
    if (h_write) *h_write = 0;
    unbacked(__func__);
    return 0;
}
void s2a_event_signal(uint64_t ev) { (void)ev; unbacked(__func__); }
void s2a_event_clear(uint64_t ev) { (void)ev; unbacked(__func__); }
void s2a_event_retain(uint64_t ev) { (void)ev; unbacked(__func__); }
void s2a_event_release(uint64_t ev) { (void)ev; unbacked(__func__); }
uint32_t s2a_event_dup_read(uint64_t ev) { (void)ev; unbacked(__func__); return 0; }
uint32_t s2a_shmem_wrap(void *host, uint64_t size) { (void)host; (void)size; unbacked(__func__); return 0; }
int s2a_tmem_get(uint32_t h, uint64_t *addr, uint64_t *size, uint32_t *perm) {
    (void)h; (void)addr; (void)size; (void)perm; unbacked(__func__); return 0;
}
int s2a_mem_query(uint64_t addr, s2a_meminfo *out) {
    (void)addr;
    if (out) memset(out, 0, sizeof *out);
    unbacked(__func__);
    return 0;
}
int s2a_mem_mapped(uint64_t addr, uint64_t size) { (void)addr; (void)size; unbacked(__func__); return 0; }
int s2a_mem_readable(uint64_t addr, uint64_t size) { (void)addr; (void)size; unbacked(__func__); return 0; }
// #1217 P2：诊断单库带 NVN 前端（hle_nvn.c）但不跑原生 VM，这些入口按「不在背板区」
// 返回；真游戏目标由 svc_mem.c 的强定义覆盖。
int s2a_mem_backing_alias_ref(uint64_t src, uint64_t n) { (void)src; (void)n; unbacked(__func__); return 0; }
void s2a_mem_backing_alias_unref(uint64_t src, uint64_t n) { (void)src; (void)n; unbacked(__func__); }
void s2a_mem_lockorder_vp_enter(void) { }
uint64_t s2a_process_id(void) { unbacked(__func__); return 0; }
uint64_t s2a_program_id(void) { unbacked(__func__); return 0; }
int s2a_register_cs(const s2a_cs_api *api) { (void)api; unbacked(__func__); return -1; }
// nn::ro 装 / 卸 NRO（runtime/src/loader.c；返回码见 Ryujinx.HLE/S2AHooks.cs）：诊断目标不跑原生核心，按失败返回——1 = 包里没有这个 NRO / 没装载
int s2a_nro_map(const uint8_t sha[32], uint64_t size, uint64_t bss, uint64_t *base) {
    (void)sha; (void)size; (void)bss; if (base) *base = 0; unbacked(__func__); return 1;
}
int s2a_nro_unmap(uint64_t base) { (void)base; unbacked(__func__); return 1; }
// 金手指（services Cheats.cs）取主程序基址 / 构建号（runtime/src/loader.c）：诊断目标没有装载器，回「未装载」
uint64_t s2a_main_base(void) { unbacked(__func__); return 0; }
uint64_t s2a_main_region_va(uint64_t off) { (void)off; unbacked(__func__); return 0; }
const char *s2a_main_build_id(void) { unbacked(__func__); return ""; }
const s2a_layout *s2a_layout_get(void) { return NULL; }   // 诊断目标不跑原生核心、没有区域表（svc_mem.c 是游戏目标的强定义）；金手指等读者拿到空就当没装载
const char *s2a_cheats_dir(void) { return ""; }   // 安卓没有金手指界面：空串 = 不起线程（不是缺口，不报 unbacked）

// 系统键盘桥接：诊断目标没有输入框，回 0 = 不交互（服务层退回自动应答，不算失败）
int s2a_host_text_input(int64_t id, const char *json, s2a_text_input_cb cb) { (void)id; (void)json; (void)cb; return 0; }
void s2a_host_text_input_cancel(int64_t id) { (void)id; }
