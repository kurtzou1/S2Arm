// Android/AArch64 half of the existing touch -> BRK -> retry protocol.
// These helpers do not install a signal handler or claim dispatcher readiness.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Default ON since #573 / #736 (SME cores put these in every signal frame): preserve inline TPIDR2
// and inactive ZA records in the existing complete ucontext copy. Active ZA / external records still fail.
// enabled = 0 is a debug opt-out.
// Configure before thread_init; later changes return EBUSY (same value is idempotent).
int s2a_android_fault_configure_inline_sme(int enabled);
// First signal-frame record magic that made a fault unclaimable (0 = none seen; 1 = frame without FPSIMD).
// s2a_android_fault_probe() returns ENOTSUP in that case instead of crashing.
unsigned s2a_android_fault_unsupported_record(void);

// Call on every guest pthread before guest entry, outside signal context.
// Installs the existing guest alternate signal stack and preallocates save state.
// A nonzero errno forbids entry. This can precede sw_xstack_thread_init, but entry
// also requires thread_ready == 1 after the real xstack host slot is registered.
int s2a_android_fault_thread_init(void);
// Only after that thread has stopped executing guest code; EBUSY if deferred.
int s2a_android_fault_thread_fini(void);
// Requires both preallocated save state and a valid existing xstack host slot;
// neither this nor init claims global dispatcher/managed callback readiness.
int s2a_android_fault_thread_ready(void);
int s2a_android_fault_thread_active(void);

// 1 only for a well-formed ESR data-abort record; 0 means do not infer WnR.
int s2a_android_fault_esr(const void *context, int *is_write);

// Signal-context helpers for the ONE existing dispatcher. redirect returns 1
// after changing only the live context; negative errno is fatal for a tracker
// result of 2: DO NOT fall back to s2a_track_fault and unprotect unread-back data.
// restore returns 1 only at this adapter's BRK after touch completed, 0 for other
// trap PCs, negative errno for an invalid own return. Original instruction retries.
int s2a_android_fault_redirect(void *context, uint64_t address);
int s2a_android_fault_restore(void *context);
// Same full-context/host-xstack round trip for the existing thread scheduler.
// callback is a trusted native owner function, runs outside the signal handler,
// and must return normally. It may not destroy this thread's xstack/save state.
int s2a_android_fault_redirect_call(void *context, void (*callback)(void *), void *argument);

// Thin hook called by the existing crash dispatcher, before its fatal fallback.
// is_guest_pc MUST come from the real module/rewritten-code classifier. This
// function installs no handlers. 1 = handled/retry, 0 = continue dispatch;
// negative errno = fatal (never fall through to a second tracker/unprotect path).
// Android full readback always passes skip=0: an address-only skip cannot prove
// that a later GPU write to the same page belongs to the just-completed callback.
int s2a_android_fault_handle(int signal, void *address, void *context, int is_guest_pc);

// Run on each actual guest pthread after managed signal installation/attachment,
// with its host xstack and alternate stack ready, BEFORE executing guest code.
// Uses a private protected page and exact probe PC through the real dispatcher.
// Never substitutes a GPU readback or a managed callback. Missing/broken handler
// chains may terminate the probe process; do not claim a recoverable fallback.
int s2a_android_fault_probe(void);
int s2a_android_fault_dispatch_ready(void);
// Handler owner invalidates final proof before installing/replacing its chain.
void s2a_android_fault_dispatch_reset(void);
// Defined by the actual crash dispatcher owner, not this adapter.
int s2a_android_fault_dispatch_installed(void);

// Actual thread.c owner: installation precedes services preparation; begin
// requires no VM/tracker/GPU/thread lock and returns errno on bounded failure.
// Concurrent transactions return EBUSY; caller must abort that mutation.
int s2a_android_guest_writers_init(void);
int s2a_android_guest_writers_ready(void);
// 只回答“停车通道装过没有”（不看当前处理器是否被覆盖）：收局据此区分“从未安装”与“没停稳”。
int s2a_android_guest_writers_installed(void);
int s2a_android_vm_writer_held(void);   // 本线程持有 VM epoch（svc_mem.c 改表断言用）
int s2a_android_guest_writers_begin(void);
// 0x2C 全空宿主页增页：只串行、发布 epoch，不停其他 writer；条件不成立时由
// s2a_android_guest_writers_quiesce 升级为全体停稳。
int s2a_android_guest_writers_begin_serial(void);
int s2a_android_guest_writers_quiesce(void);
int s2a_android_guest_writers_serial_only(void);
void s2a_android_guest_writers_end(void);
void s2a_android_guest_park_forever(void) __attribute__((noreturn));
// 本线程的事务是否已在调用栈里被撤销（quiesce 升级失败）：为真时外层不得再走正常 end()，
// 必须重新准入后再重做映射。
int s2a_android_guest_writers_revoked(void);
// Shutdown owner's bounded host wait before terminal phases; no-op off guest threads.
void s2a_android_guest_host_wait_begin(void);
void s2a_android_guest_host_wait_end(void);
// 宿主侧长工作里的自愿安全点（图形回放循环每条命令过一次）：有停世界事务时在这里停驻到事务结束。
// 调用时不得持 G / VM / tracker 锁。非客体线程、没有事务时是空操作。
void s2a_android_guest_host_safepoint(void);

#ifdef __cplusplus
}
#endif
