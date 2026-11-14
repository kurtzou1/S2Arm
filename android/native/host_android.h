#pragma once
#include "s2a_hostapi.h"
#include "wsi_lease.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The Android shell's HostApi tables (runtime/include/s2a_hostapi.h, plan A2): what the core and
// the C# service layer read instead of Android system state.
//  user     the session's BootSpec values (language, region, time zone), frozen at registration
//  meminfo  /proc/meminfo MemTotal / MemAvailable (what ActivityManager reads too, without a JNI
//           call on a core thread) and /proc/self/statm resident size; guest and GPU bytes are
//           0 (unknown) until the core and the Vulkan backend report them
//  input    input.c's latest state (MainActivity pushes it) and when it was set
//  display  the current window-lease revision (s2a_wsi_peek): Surface pixels, Surface.ROTATION_*
//           from the transform, refresh rate; all 0 before the first surface. The last size stays
//           while the surface is gone (HOME). xdpi / ydpi from DisplayMetrics; console mode from
//           BootSpec at first, then only set_console_mode changes it
//  stop     the core asks the shell to end the session (game exit, device lost, unrecoverable
//           error, low memory). request_stop never blocks: the first request is latched and an
//           eventfd wakes the shell's main thread, which takes it once and shows / tears down;
//           later requests of the session are ignored
// UI is offered only when the foreground keyboard producer attached before
// registration; later unavailability cancels pending requests. Decode is absent.
//
// Output structs follow the prefix rule: the caller sets size to its own struct's size, the host
// writes the v1 prefix and sets size / abi_version to what it wrote. A size below v1 is
// S2A_HOST_E_RANGE, a NULL output S2A_HOST_E_ARGUMENT.

struct s2a_android_host_config {
    const char *language;   // BCP 47
    const char *region;     // ISO 3166 alpha-2, or "" when the locale has none
    const char *timezone;   // IANA
    uint32_t dpi_x, dpi_y;
    uint32_t console_mode;  // 0 handheld, 1 docked
};

// Validates the values, fills the tables and registers them (s2a_host_register). Once per
// process: the session's values are frozen, so a later call (the Activity recreated) keeps the
// first ones and returns 0. Returns 0 or S2A_HOST_E_*.
int s2a_android_host_register(const struct s2a_android_host_config *config);

// The lease the display table reads (AndroidWindow's). Unset only clears it if it is still the
// current one, and returns after any display read using it, so the lease can then be destroyed.
void s2a_android_host_set_lease(s2a_wsi_lease *lease);
void s2a_android_host_unset_lease(s2a_wsi_lease *lease);
// Exported for the managed GPU runtime (threaded renderer stall clock): the current game lease's
// lifecycle from s2a_wsi_lifecycle, readable from any thread. -1 when no lease is registered.
int s2a_android_host_lifecycle(uint64_t *changes);
// Threaded mode controls native shutdown diagnostics; false keeps baseline order.
void s2a_android_host_set_threaded(int on);
int s2a_android_host_threaded(void);
// owner=0 starts a publication and returns a unique token. Updates/revocation (advance=0 closes)
// require that token and the same writer epoch; a superseded token returns 0 without mutation.
uint64_t s2a_android_host_backing_progress(uint64_t owner, int advance);
// 0 continue, 1 idle timeout, 2 total timeout, 3 revoked (same-version ABI).
int s2a_android_host_backing_decision(uint64_t owner);
// Native admission only: returns whether this epoch has an extended budget.
int s2a_android_host_backing_admission(unsigned writer, uint64_t *deadline);

// The console mode last set through the display table (or the initial one).
uint32_t s2a_android_host_console_mode(void);

// 前后台冻结策略（bridge.cpp 的 setForeground 与宿主单测共用；纯函数，便于覆盖时序）。
// 返回值：FREEZE=冻结客机与游戏时钟，UNFREEZE=放开，KEEP=不变。
// 退后台一律冻结，不看游戏的「失焦暂停」开关（同 iOS 后台整体冻结）：安卓退后台就没有窗口了，客机照跑上不了屏，
//   关了失焦暂停的游戏约 1.5 秒后自己 Abort（#855：系统选文件框一盖上，返回时游戏已从头启动）。
// 停机已开始（stopGame 已 foreground_unfreeze、正在等客机应答）时，迟到的 onPause 不得再冻结：
//   否则收尾线程等客机线程退出会卡到硬预算超时（finishAndRemoveTask 还要 10 秒才执行，Home 路径必现）。
enum {
    S2A_ANDROID_FOREGROUND_KEEP = 0,
    S2A_ANDROID_FOREGROUND_FREEZE = 1,
    S2A_ANDROID_FOREGROUND_UNFREEZE = -1,
};

static inline int s2a_android_foreground_action(int foreground, int stop_started, int frozen) {
    if (foreground) return frozen ? S2A_ANDROID_FOREGROUND_UNFREEZE : S2A_ANDROID_FOREGROUND_KEEP;
    if (stop_started) return S2A_ANDROID_FOREGROUND_KEEP;   // 收尾不冻，冻着的由 stopGame 先放开
    return frozen ? S2A_ANDROID_FOREGROUND_KEEP : S2A_ANDROID_FOREGROUND_FREEZE;
}

// Shell side of the stop table: an eventfd (non-blocking) that becomes readable when the core
// requests a stop, -1 before registration; and the request itself, returned once (1) with its
// reason and detail (NUL-terminated, cut at a UTF-8 boundary), or 0 when there is none to take.
// 非消费查询；不读取 eventfd，不改变 UI 的一次性领取状态。仅用于阶段取消。
int s2a_android_host_stop_requested(void);

// guest 的一次性逻辑准入，与 HostApi request_stop 在同一 stop_lock 上线性化。
// 停止先被接受则返回 0；准入先完成则后续停止属于运行中会话，由退出 owner 处理。
// 不持锁调用 guest / 托管代码，也不声称成功准入后的线程已因停止而静止。
int s2a_android_host_try_enter_guest(void);

int s2a_android_host_stop_fd(void);
int s2a_android_host_take_stop(uint32_t *reason, char *detail, size_t n);

#ifdef __cplusplus
}
#endif
