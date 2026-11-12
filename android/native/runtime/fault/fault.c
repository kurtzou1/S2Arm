#define _GNU_SOURCE
#include "fault.h"
#include "../../guest_signal.h"
#include <asm/sigcontext.h>
#include "sigframe_compat.h"
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>

#if !defined(__aarch64__) || !defined(__linux__)
#error This adapter requires the Linux AArch64 signal ABI (Android uses Bionic).
#endif

extern void s2a_android_fault_trampoline(void);
extern const uint32_t s2a_android_fault_return[];
extern const uint32_t s2a_android_fault_probe_store[];
void s2a_android_fault_probe_instruction(uint64_t *page);
void s2a_track_touch(uint64_t address);
int s2a_track_fault_guest(void *address, int is_write, uint64_t skip);
int s2a_track_fault(void *address, int is_write);
void s2a_core_leave(void);
void s2a_core_enter(void);

enum { IDLE, SAVED, RUNNING, COMPLETE };
// Private ABI already shared by runtime/src/xstack.c, entry.S and touch.c.
// Borrow the existing pthread host stack: NativeAOT must not be entered on a
// new mmap stack outside the pthread's recorded stack bounds.
extern uint64_t g_xs_key;
struct xs_slot { uint64_t cur, top, bottom, gtop; };
struct fault_state {
    ucontext_t saved;
    struct xs_slot *slot;
    uintptr_t stack_low, stack_high;
    uint64_t old_cursor, callback_cursor;
    void (*callback)(void *);
    uintptr_t alt_low, alt_high;
    void *probe_page;
    size_t probe_size;
    volatile sig_atomic_t probe_seen;
    uint64_t touched;
    volatile sig_atomic_t phase;
};
static pthread_key_t state_key;
static pthread_once_t key_once = PTHREAD_ONCE_INIT;
static int key_error;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "signal-side readiness must be lock free");
static atomic_int key_ready;
static atomic_int dispatch_verified;
// Bit 0: opt-in; bit 1: frozen before any thread can receive runtime faults.
// Default ON (#573 / #736): kernels on SME-capable cores (Snapdragon 8 Elite Gen 5 / SM8850 and later)
// append TPIDR2 and a header-only ZA record to EVERY signal frame. Rejecting them meant no fault was
// ever claimed on those devices, so the startup probe and every tracked write died as chained SIGSEGV.
// Both records are inline and fixed-size; the saved ucontext copy restores them byte-for-byte.
// The launcher can still opt out (enabled = 0) before the first runtime thread freezes the choice.
static atomic_int inline_sme_config = 1;
// First signal-frame record that made a fault unclaimable (0 = none); read by the startup probe report.
static atomic_uint unsupported_record;
unsigned s2a_android_fault_unsupported_record(void) {
    return atomic_load_explicit(&unsupported_record, memory_order_acquire);
}
static int unsupported(unsigned magic) {
    unsigned none = 0;
    atomic_compare_exchange_strong_explicit(&unsupported_record, &none, magic ? magic : 1u,
        memory_order_acq_rel, memory_order_acquire);
    return ENOTSUP;
}
int s2a_android_fault_configure_inline_sme(int enabled) {
    if (enabled != 0 && enabled != 1) return EINVAL;
    int old = atomic_load_explicit(&inline_sme_config, memory_order_acquire);
    for (;;) {
        if (old & 2) return (old & 1) == enabled ? 0 : EBUSY;
        if (atomic_compare_exchange_weak_explicit(&inline_sme_config, &old, enabled,
                memory_order_acq_rel, memory_order_acquire)) return 0;
    }
}

static void dispose(void *pointer) {
    struct fault_state *state = pointer;
    if (!state) return;
    // Thread teardown while a callback is active cannot establish guest quiescence.
    if (state->phase != IDLE) _exit(127);
    free(state);
}
static void make_key(void) {
    key_error = pthread_key_create(&state_key, dispose);
    if (!key_error) atomic_store_explicit(&key_ready, 1, memory_order_release);
}
static struct fault_state *current(void) {
    // Bionic pthread_getspecific is a nonallocating TSD read. The key and value
    // are populated on this same thread BEFORE any guest instruction executes.
    return atomic_load_explicit(&key_ready, memory_order_acquire) ? pthread_getspecific(state_key) : NULL;
}

int s2a_android_fault_thread_init(void) {
    atomic_fetch_or_explicit(&inline_sme_config, 2, memory_order_acq_rel);
    int error = pthread_once(&key_once, make_key);
    if (error || key_error) return error ? error : key_error;
    struct fault_state *existing = current();
    if (existing) return existing->phase == IDLE ? 0 : EBUSY;
    struct fault_state *state = calloc(1, sizeof *state);
    if (!state) return ENOMEM;
    pthread_attr_t attr;
    error = pthread_getattr_np(pthread_self(), &attr);
    if (error) { free(state); return error; }
    void *bottom = NULL; size_t length = 0;
    error = pthread_attr_getstack(&attr, &bottom, &length);
    pthread_attr_destroy(&attr);
    if (error || !bottom || length > UINTPTR_MAX - (uintptr_t)bottom) {
        free(state); return error ? error : EINVAL;
    }
    state->stack_low = (uintptr_t)bottom;
    state->stack_high = (uintptr_t)bottom + length;
    error = s2a_android_altstack_init();
    stack_t alternate;
    if (!error && sigaltstack(NULL, &alternate)) error = errno;
    if (!error) {
        state->alt_low = (uintptr_t)alternate.ss_sp;
        state->alt_high = state->alt_low + alternate.ss_size;
        if ((alternate.ss_flags & SS_DISABLE) || state->alt_high < state->alt_low) error = EINVAL;
    }
    if (!error) error = pthread_setspecific(state_key, state);
    if (error) { dispose(state); return error; }
    return 0;
}
int s2a_android_fault_thread_active(void) {
    struct fault_state *state = current();
    return state && state->phase != IDLE;
}
int s2a_android_fault_thread_fini(void) {
    struct fault_state *state = current();
    if (!state) return 0;
    if (state->phase != IDLE) return EBUSY;
    int error = pthread_setspecific(state_key, NULL);
    if (!error) dispose(state);
    // The existing guest-thread owner owns altstack teardown after all handlers.
    return error;
}
static struct xs_slot *host_slot(const struct fault_state *state) {
    if (!state) return NULL;
    struct xs_slot *slot = pthread_getspecific((pthread_key_t)g_xs_key);
    if (!slot || slot->bottom < state->stack_low || slot->top > state->stack_high
        || slot->top <= slot->bottom || slot->cur > slot->top
        || slot->cur <= slot->bottom || (slot->cur & 15) || (slot->top & 15)) return NULL;
    return slot;
}
int s2a_android_fault_thread_ready(void) {
    struct fault_state *state = current();
    return state && state->phase == IDLE && host_slot(state) != NULL;
}
// A copied extra_context would retain a pointer into the expired signal frame.
// Reject it, unknown records, malformed/duplicate records and missing FPSIMD.
// Inline SVE state is copied intact; out-of-line state needs a later deep-copy
// extension, never a silent NEON-only restore. The terminator itself must fit.
static int records(const ucontext_t *context, uint64_t *esr, int *has_esr) {
    const unsigned char *at = (const unsigned char *)context->uc_mcontext.__reserved;
    size_t left = sizeof context->uc_mcontext.__reserved;
    unsigned seen = 0;
    *has_esr = 0;
    while (left >= sizeof(struct _aarch64_ctx)) {
        const struct _aarch64_ctx *head = (const void *)at;
        if (!head->magic && !head->size) return (seen & 1) ? 0 : unsupported(FPSIMD_MAGIC);
        if (head->size < 16 || (head->size & 15) || head->size > left) return EINVAL;
        unsigned bit;
        switch (head->magic) {
        case FPSIMD_MAGIC:
            if (head->size != sizeof(struct fpsimd_context)) return EINVAL;
            bit = 1; break;
        case ESR_MAGIC:
            if (head->size != sizeof(struct esr_context)) return EINVAL;
            bit = 2; *has_esr = 1; *esr = ((const struct esr_context *)head)->esr; break;
        case SVE_MAGIC:
            if (head->size < sizeof(struct sve_context)) return EINVAL;
            // Streaming SVE live at the fault: the redirected host body would resume in streaming
            // mode, where plain FP/SIMD traps. Neither guest nor host code enables it; refuse if seen.
            if (((const struct sve_context *)head)->flags & SVE_SIG_FLAG_SM) return unsupported(SVE_MAGIC);
            bit = 4; break;
        case TPIDR2_MAGIC:
            if (!(atomic_load_explicit(&inline_sme_config, memory_order_acquire) & 1)) return unsupported(TPIDR2_MAGIC);
            if (head->size != sizeof(struct tpidr2_context)) return EINVAL;
            bit = 8; break;
        case ZA_MAGIC: {
            if (!(atomic_load_explicit(&inline_sme_config, memory_order_acquire) & 1)) return unsupported(ZA_MAGIC);
            // Header-only ZA means no live matrix payload. Never discard active
            // ZA or chase an extra_context pointer into a previous signal frame.
            if (head->size != sizeof(struct za_context)) return unsupported(ZA_MAGIC);
            const struct za_context *za = (const void *)head;
            if (!sve_vl_valid(za->vl) || za->__reserved[0] || za->__reserved[1] || za->__reserved[2]) return EINVAL;
            bit = 16; break;
        }
        // FPMR (FP8) and POE (permission overlay) are likewise inline, fixed-size register snapshots
        // that newer kernels append whenever the CPU has the feature; copied back intact like TPIDR2.
        case FPMR_MAGIC:
            if (head->size != sizeof(struct fpmr_context)) return EINVAL;
            bit = 32; break;
        case POE_MAGIC:
            if (head->size != sizeof(struct poe_context)) return EINVAL;
            bit = 64; break;
        default: return unsupported(head->magic);
        }
        if (seen & bit) return EINVAL;
        seen |= bit;
        at += head->size;
        left -= head->size;
    }
    return EINVAL;
}
int s2a_android_fault_esr(const void *pointer, int *is_write) {
    if (!pointer || !is_write) return 0;
    uint64_t esr = 0; int found;
    if (records(pointer, &esr, &found) || !found) return 0;
    unsigned ec = (unsigned)(esr >> 26) & 63;
    if (ec != 0x24 && ec != 0x25) return 0;
    *is_write = (int)(esr >> 6) & 1;
    return 1;
}
int s2a_android_fault_redirect(void *pointer, uint64_t address) {
    struct fault_state *state = current();
    if (!state || !pointer) return -EINVAL;
    if (state->phase != IDLE) return -EBUSY;
    ucontext_t *context = pointer;
    uint64_t esr = 0; int found;
    int error = records(context, &esr, &found);
    if (error) return -error;
    // SIGTRAP is the sole restore route. A guest mask blocking it cannot work.
    if (sigismember(&context->uc_sigmask, SIGTRAP) == 1) return -ENOTSUP;
    struct xs_slot *slot = host_slot(state);
    if (!slot) return -ENXIO;
    if (slot->cur - slot->bottom <= 512) return -ENOMEM;
    uint64_t frame = slot->cur - 256;
    uint64_t sp = context->uc_mcontext.sp;
    // Guest instructions normally use a separate guest stack. If the supplied
    // context is already on the host stack, keep its active frame and 112-byte
    // rewritten red zone intact as well. Move the cursor for nested xstack use.
    if (sp > state->stack_low && sp <= state->stack_high) {
        if (sp - state->stack_low <= 512) return -ENOMEM;
        if (sp - 512 < frame) frame = sp - 512;
    }
    frame &= ~15ull;
    if (frame <= slot->bottom) return -ENOMEM;
    state->phase = SAVED;
    memcpy(&state->saved, context, sizeof *context);
    state->touched = address;
    state->callback = NULL;
    state->slot = slot;
    state->old_cursor = slot->cur;
    state->callback_cursor = frame;
    slot->cur = frame;
    context->uc_mcontext.regs[0] = address;
    context->uc_mcontext.regs[29] = 0;
    context->uc_mcontext.regs[30] = 0;
    context->uc_mcontext.sp = frame;
    context->uc_mcontext.pc = (uintptr_t)s2a_android_fault_trampoline;
    return 1;
}
int s2a_android_fault_redirect_call(void *context, void (*callback)(void *), void *argument) {
    if (!callback) return -EINVAL;
    int result = s2a_android_fault_redirect(context, (uint64_t)(uintptr_t)argument);
    if (result == 1) current()->callback = callback;
    return result;
}
int s2a_android_fault_restore(void *pointer) {
    if (!pointer) return 0;
    ucontext_t *context = pointer;
    if (context->uc_mcontext.pc != (uintptr_t)s2a_android_fault_return) return 0;
    struct fault_state *state = current();
    if (!state || state->phase != COMPLETE) return -EINVAL;
    if (host_slot(state) != state->slot || state->slot->cur != state->callback_cursor) return -EINVAL;
    state->slot->cur = state->old_cursor;
    memcpy(context, &state->saved, sizeof *context);
    state->touched = 0;
    state->phase = IDLE;
    return 1;
}
int s2a_android_fault_handle(int signal, void *address, void *context, int is_guest_pc) {
    struct fault_state *state = current();
    uintptr_t handler_sp = (uintptr_t)&state;
    if (signal == SIGTRAP) {
        if (state && state->probe_page && context
            && ((ucontext_t *)context)->uc_mcontext.pc == (uintptr_t)s2a_android_fault_return) {
            if (handler_sp < state->alt_low || handler_sp >= state->alt_high) return -EFAULT;
            state->probe_seen |= 4;
        }
        return s2a_android_fault_restore(context);
    }
    if (signal != SIGSEGV && signal != SIGBUS) return 0;
    int write;
    // Private startup probe, deliberately outside game modules. Exact PC,
    // address and current-thread activation are all required; no guest exception.
    int probe = state && state->probe_page && context && address == state->probe_page
        && ((ucontext_t *)context)->uc_mcontext.pc == (uintptr_t)s2a_android_fault_probe_store;
    if (!s2a_android_fault_esr(context, &write)) {
        // A self-check must never take startup down (#573): when this device's signal frame cannot be
        // redirected, open the probe page so the store completes, and let the probe report failure.
        // The runtime then refuses guest start with a stated reason instead of a chained SIGSEGV.
        if (probe && !mprotect(state->probe_page, state->probe_size, PROT_READ | PROT_WRITE)) {
            state->probe_seen |= 8;
            return 1;
        }
        return 0;
    }
    if (probe) {
        if (!write || handler_sp < state->alt_low || handler_sp >= state->alt_high) return -EFAULT;
        state->probe_seen |= 1;
        return s2a_android_fault_redirect(context, (uint64_t)address);
    }
    if (is_guest_pc) {
        // A page address is not a GPU-write generation. Retaining it after a
        // successful retry could bypass readback after the page is dirtied anew.
        int result = s2a_track_fault_guest(address, write, 0);
        if (result == 2) return s2a_android_fault_redirect(context, (uint64_t)address);
        return result == 0 || result == 1 ? result : -EPROTO;
    }
    int result = s2a_track_fault(address, write);
    return result == 0 || result == 1 ? result : -EPROTO;
}
// Entered by rt_sigreturn, never called from the dispatcher. The borrowed host
// stack is inside this pthread's bounds and below the owner's active frames.
void s2a_android_fault_body(uint64_t address) {
    struct fault_state *state = current();
    if (!state || state->phase != SAVED || state->touched != address) _exit(127);
    state->phase = RUNNING;
    if (state->probe_page) {
        uintptr_t here = (uintptr_t)&state;
        stack_t alternate;
        if (here < state->stack_low || here >= state->stack_high
            || sigaltstack(NULL, &alternate) || (alternate.ss_flags & SS_ONSTACK)
            || mprotect(state->probe_page, state->probe_size, PROT_READ | PROT_WRITE)) _exit(127);
        state->probe_seen |= 2;
    } else if (state->callback) {
        state->callback((void *)(uintptr_t)address);
    } else {
        s2a_core_leave();
        s2a_track_touch(address);
        s2a_core_enter();
    }
    state->phase = COMPLETE;
}

int s2a_android_fault_probe(void) {
    struct fault_state *state = current();
    if (!s2a_android_fault_thread_ready() || state->probe_page) return EINVAL;
    // NativeAOT may have installed its own altstack during first attachment.
    // Prove the currently active stack, not the earlier initialization pointer.
    stack_t alternate;
    if (sigaltstack(NULL, &alternate)) return errno;
    if ((alternate.ss_flags & SS_DISABLE) || !alternate.ss_sp || !alternate.ss_size
        || alternate.ss_size > UINTPTR_MAX - (uintptr_t)alternate.ss_sp) return EINVAL;
    state->alt_low = (uintptr_t)alternate.ss_sp;
    state->alt_high = state->alt_low + alternate.ss_size;
    long size = sysconf(_SC_PAGESIZE);
    if (size <= 0) return EINVAL;
    void *page = mmap(NULL, (size_t)size, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) return errno;
    state->probe_size = (size_t)size;
    state->probe_seen = 0;
    state->probe_page = page;
    s2a_android_fault_probe_instruction(page);
    int error = state->probe_seen == 7 && state->phase == IDLE && *(uint64_t *)page == 0x5a ? 0
        : (state->probe_seen & 8) ? ENOTSUP : EIO;
    state->probe_page = NULL;
    munmap(page, (size_t)size);
    atomic_store_explicit(&dispatch_verified, !error, memory_order_release);
    return error;
}
int s2a_android_fault_dispatch_ready(void) {
    return atomic_load_explicit(&dispatch_verified, memory_order_acquire);
}
void s2a_android_fault_dispatch_reset(void) {
    atomic_store_explicit(&dispatch_verified, 0, memory_order_release);
}
