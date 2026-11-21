#define _GNU_SOURCE   // dladdr / Dl_info on glibc (bionic declares them anyway)
#include "guest_signal.h"
#include "redlog.h"
#include <unistd.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <ucontext.h>
#if defined(__aarch64__)
// OHOS musl signal.h already provides these AArch64 context records.
#if !defined(__OHOS__)
#include <asm/sigcontext.h>
#endif
#endif
#include <unistd.h>
#if defined(__ANDROID__)
#include <android/log.h>
#define GS_LOG(...) __android_log_print(ANDROID_LOG_ERROR, "S2Arm", __VA_ARGS__)
#else
#define GS_LOG(...) ((void)0)
#endif

static __thread uint8_t *g_alt;   // guard page + stack, from s2a_android_altstack_init
static __thread size_t g_alt_len;

int s2a_android_altstack_init(void) {
    if (g_alt) return 0;
    size_t guard = (size_t)sysconf(_SC_PAGESIZE), len = guard + S2A_ALTSTACK_SIZE;
    uint8_t *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return errno;
    // Stacks grow down: an overflowing handler hits the guard, not the next mapping.
    if (mprotect(p, guard, PROT_NONE)) { int e = errno; munmap(p, len); return e; }
    stack_t ss = {.ss_sp = p + guard, .ss_size = S2A_ALTSTACK_SIZE, .ss_flags = 0};
    if (sigaltstack(&ss, NULL)) { int e = errno; munmap(p, len); return e; }
    g_alt = p; g_alt_len = len;
    return 0;
}

void s2a_android_altstack_free(void) {
    if (!g_alt) return;
    stack_t off = {.ss_flags = SS_DISABLE};
    sigaltstack(&off, NULL);
    munmap(g_alt, g_alt_len);
    g_alt = NULL; g_alt_len = 0;
}

int s2a_android_sigaction(int sig, void (*fn)(int, siginfo_t *, void *), struct sigaction *old) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = fn;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    return sigaction(sig, &sa, old) ? errno : 0;
}

static int lacks_onstack(int sig) {
    struct sigaction sa;
    if (sig == SIGKILL || sig == SIGSTOP || sigaction(sig, NULL, &sa)) return 0;
    int custom = (sa.sa_flags & SA_SIGINFO) ? sa.sa_sigaction != NULL
        : (sa.sa_handler != SIG_DFL && sa.sa_handler != SIG_IGN);
    return custom && !(sa.sa_flags & SA_ONSTACK);
}

// Never requested: fault signals (blocking a synchronous fault kills the process),
// and bionic's reserved RT signals whose sender waits for the target thread to
// run the handler (bionic libc/platform/bionic/reserved_signals.h, checked against
// android15-release and main; the NDK does not export it): __SIGRTMIN + 1
// libbacktrace, + 3 debuggerd, + 8 android_run_on_all_threads, + 9 MTE re-enable
// (main only). bionic itself also refuses to block + 1..8; this list keeps other
// libcs (musl on HarmonyOS) from hanging those senders.
static int never_block(int sig) {
    if (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGTRAP || sig == SIGFPE) return 1;
    int rt = sig - 32;   // __SIGRTMIN
    return rt == 1 || rt == 3 || rt == 8 || rt == 9;
}

int s2a_android_guest_sigmask(char *kept, size_t n) {
    sigset_t want, now;
    sigemptyset(&want);
    for (int sig = 1; sig < NSIG; sig++)
        if (!never_block(sig) && lacks_onstack(sig)) sigaddset(&want, sig);
    int e = pthread_sigmask(SIG_BLOCK, &want, NULL);
    if (!e) e = pthread_sigmask(SIG_BLOCK, NULL, &now);
    if (e) return -e;
    int blocked = 0;
    size_t k = 0;
    if (n) kept[0] = 0;
    for (int sig = 1; sig < NSIG; sig++) {
        if (sigismember(&want, sig) != 1) continue;
        if (sigismember(&now, sig) == 1) { blocked++; continue; }
        if (k < n) { int w = snprintf(kept + k, n - k, "%s%d", k ? " " : "", sig); if (w > 0) k += (size_t)w; }
    }
    return blocked;
}

static void nothing(int sig, siginfo_t *si, void *uc) { (void)sig; (void)si; (void)uc; }

int s2a_android_runtime_signals_prepare(void) {
    struct sigaction cur;
    if (sigaction(SIGRTMIN, NULL, &cur)) return errno;
    if (!(cur.sa_flags & SA_SIGINFO) && cur.sa_handler == SIG_DFL) return s2a_android_sigaction(SIGRTMIN, nothing, NULL);
    return 0;
}

int s2a_android_signal_audit(char *out, size_t n) {
    int count = 0;
    size_t k = 0;
    if (n) out[0] = 0;
    for (int sig = 1; sig < NSIG; sig++) {
        if (!lacks_onstack(sig)) continue;
        count++;
        if (k < n) {
            int w = snprintf(out + k, n - k, "%s%d", k ? " " : "", sig);
            if (w > 0) k += (size_t)w;
        }
    }
    if (!count && n) snprintf(out, n, "none");
    return count;
}

// The kernel's record of an action (rt_sigaction); same layout on arm64 and x86_64.
struct kernel_sigaction {
    void *handler;
    unsigned long flags;
    void *restorer;
    uint64_t mask;
};

static const char *const kSignalNames[32] = {
    "", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM",
    "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS"};

// Library that holds a handler ("s2arm" for this file's own no-op).
static void owner(void *fn, char *buf, size_t n) {
    Dl_info info;
    if (fn == (void *)nothing) snprintf(buf, n, "s2arm");
    else if (dladdr(fn, &info) && info.dli_fname) {
        const char *base = strrchr(info.dli_fname, '/');
        snprintf(buf, n, "%s", base ? base + 1 : info.dli_fname);
    } else snprintf(buf, n, "%p", fn);
}

int s2a_android_signal_census(char *out, size_t n) {
    int count = 0;
    size_t k = 0;
    if (n) out[0] = 0;
    for (int sig = 1; sig <= 64; sig++) {
        struct kernel_sigaction ka;
        if (syscall(SYS_rt_sigaction, sig, NULL, &ka, sizeof ka.mask)) continue;
        if (ka.handler == (void *)SIG_DFL || ka.handler == (void *)SIG_IGN) continue;
        struct sigaction app;
        char kern[48], seen[48] = "-";
        owner(ka.handler, kern, sizeof kern);
        if (!sigaction(sig, NULL, &app)) {
            void *fn = (app.sa_flags & SA_SIGINFO) ? (void *)app.sa_sigaction : (void *)app.sa_handler;
            if (fn != (void *)SIG_DFL && fn != (void *)SIG_IGN) owner(fn, seen, sizeof seen);
        }
        char name[12];
        if (sig < 32) snprintf(name, sizeof name, "%s", kSignalNames[sig]);
        else snprintf(name, sizeof name, "RT%d", sig);
        if (k < n) {
            int w = snprintf(out + k, n - k, "%s%d %s %s%s%s%s", k ? "; " : "", sig, name, kern,
                             strcmp(kern, seen) ? " (app sees " : "", strcmp(kern, seen) ? seen : "",
                             strcmp(kern, seen) ? ")" : "");
            if (w > 0) k += (size_t)w;
            if (k < n && (ka.flags & SA_ONSTACK)) { w = snprintf(out + k, n - k, " onstack"); if (w > 0) k += (size_t)w; }
        }
        count++;
    }
    return count;
}

// 信号处理器里只能用异步信号安全的调用：目录由 Java 侧在启动时注入（s2a_android_redlog_set_dir），
// 路径算好存在静态缓冲；处理器里只有 open / write / fsync，同时写 red.log 与宿主日志 fd。
// 红日志落盘只给下面 aarch64 的信号转发用：x86_64 宿主测试构建不编（否则 -Werror 下 gs_red_signal「定义未使用」）
#if defined(__aarch64__)
static void gs_red_signal(int sig, const void *addr) {
    char buf[96];
    size_t k = 0;
    const char *p1 = "guest signal ";
    while (*p1) buf[k++] = *p1++;
    if (sig >= 10) buf[k++] = (char)('0' + sig / 10);
    buf[k++] = (char)('0' + sig % 10);
    const char *p2 = " cannot be forwarded addr=0x";
    while (*p2) buf[k++] = *p2++;
    uintptr_t a = (uintptr_t)addr;
    int started = 0;
    for (int sh = 60; sh >= 0; sh -= 4) {
        int d = (int)((a >> sh) & 0xf);
        if (d || started || sh == 0) { buf[k++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); started = 1; }
    }
    buf[k++] = '\n';
    s2a_android_redlog_write(buf, k);
}
#endif

#if defined(__aarch64__)
static uint8_t *esr_page;
static size_t esr_len;
static struct sigaction esr_old;
static volatile sig_atomic_t esr_old_valid;
static _Atomic int esr_busy;
static volatile uint64_t esr_value;
static volatile sig_atomic_t esr_found;

// A real fault from another thread (or from a different address in this
// thread) must go back to whoever owned SIGSEGV before the probe.  Restoring
// the action before calling it also prevents the probe handler from being
// re-entered if the old handler returns.
static void esr_forward(int sig, siginfo_t *si, void *ctx) {
    struct sigaction old = esr_old;
    if (!esr_old_valid) {
        // 这条致命路径原先静默 _exit(128+sig)（真机上表现为"exited cleanly (134)"、没有 tombstone）。
        // 打一行再退：至少能拿到信号、地址与是否在 ESR 探测期间。
        GS_LOG("【红】guest signal %d 无法转发（没有可恢复的旧 handler）：addr=%p", sig,
               si ? si->si_addr : NULL);
        // 同时落盘：_exit() 不刷缓冲，真机上有可能 logcat 里看不到这一行。
        gs_red_signal(sig, si ? si->si_addr : NULL);
        _exit(128 + sig);
    }
    sigaction(sig, &old, NULL);
    if (old.sa_flags & SA_SIGINFO) {
        if (old.sa_sigaction) old.sa_sigaction(sig, si, ctx);
        else raise(sig);
    } else if (old.sa_handler == SIG_DFL || old.sa_handler == SIG_IGN) {
        raise(sig);
    } else {
        old.sa_handler(sig);
    }
}

// Finds esr_context among the records in the frame's __reserved area, then lets
// the access complete.  Only our own page is handled here; anything else is
// forwarded to the previous action.
static void esr_handler(int sig, siginfo_t *si, void *ctx) {
    uintptr_t a = si ? (uintptr_t)si->si_addr : 0;
    if (!esr_page || a < (uintptr_t)esr_page || a >= (uintptr_t)esr_page + esr_len) {
        esr_forward(sig, si, ctx);
        return;
    }
    ucontext_t *uc = ctx;
    uint8_t *p = (uint8_t *)uc->uc_mcontext.__reserved, *end = p + sizeof uc->uc_mcontext.__reserved;
    while (p + sizeof(struct _aarch64_ctx) <= end) {
        struct _aarch64_ctx *h = (struct _aarch64_ctx *)p;
        if (!h->magic || h->size < sizeof *h) break;
        if (h->magic == ESR_MAGIC) { esr_value = ((struct esr_context *)h)->esr; esr_found = 1; break; }
        p += h->size;
    }
    if (mprotect(esr_page, esr_len, PROT_READ | PROT_WRITE)) esr_forward(sig, si, ctx);
}

static void describe_esr(char *buf, size_t n, int found, uint64_t esr) {
    if (!found) snprintf(buf, n, "no esr_context");
    else snprintf(buf, n, "ESR 0x%llx (EC 0x%x, WnR %d)", (unsigned long long)esr, (unsigned)((esr >> 26) & 0x3f), (int)((esr >> 6) & 1));
}

int s2a_android_fault_esr_probe(char *report, size_t n) {
    if (!report || !n) return -1;
    if (atomic_exchange(&esr_busy, 1)) {
        snprintf(report, n, "fault ESR probe: already running");
        return -1;
    }
    int rc = -1;
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) {
        snprintf(report, n, "fault ESR probe: page size unavailable");
        goto out;
    }
    esr_len = (size_t)pg;
    esr_page = mmap(NULL, esr_len, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (esr_page == MAP_FAILED) {
        esr_page = NULL;
        snprintf(report, n, "fault ESR probe: mmap failed");
        goto out;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = esr_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, NULL, &esr_old)) {
        snprintf(report, n, "fault ESR probe: read old SIGSEGV action failed");
        goto out;
    }
    esr_old_valid = 1;
    // Through ART's sigchain this installs the app's handler and forwards
    // faults from the runtime; the saved action is what we chain back to.
    if (sigaction(SIGSEGV, &sa, NULL)) {
        snprintf(report, n, "fault ESR probe: install SIGSEGV handler failed");
        esr_old_valid = 0;
        goto out;
    }
    esr_found = 0;
    ((volatile uint8_t *)esr_page)[0] = 1;   // write to a read-only page
    int write_found = esr_found;
    uint64_t write_esr = esr_value;
    if (mprotect(esr_page, esr_len, PROT_NONE)) {
        snprintf(report, n, "fault ESR probe: protect page failed");
        goto restore;
    }
    esr_found = 0;
    (void)((volatile uint8_t *)esr_page)[1];   // read of an inaccessible page
    int read_found = esr_found;
    uint64_t read_esr = esr_value;
    char w[64], r[64];
    describe_esr(w, sizeof w, write_found, write_esr);
    describe_esr(r, sizeof r, read_found, read_esr);
    int ok = write_found && read_found && ((write_esr >> 6) & 1) == 1 && ((read_esr >> 6) & 1) == 0;
    snprintf(report, n, "Fault ESR in the signal frame: %s; write %s, read %s", ok ? "write / read distinguishable" : "NOT usable", w, r);
    rc = ok ? 0 : -1;

restore:
    if (esr_old_valid) {
        sigaction(SIGSEGV, &esr_old, NULL);
        esr_old_valid = 0;
    }
out:
    if (esr_page) {
        munmap(esr_page, esr_len);
        esr_page = NULL;
    }
    atomic_store(&esr_busy, 0);
    return rc;
}

#endif

#if defined(__ANDROID__) && defined(__aarch64__)
#include <sys/syscall.h>

uint64_t s2a_redzone_tgkill(int tgid, int tid, int sig);
uint64_t s2a_redzone_store(uint64_t *target);

static volatile uintptr_t g_handler_sp;
static uint8_t *volatile g_ro_page;
static size_t g_page;

static void on_usr2(int sig, siginfo_t *si, void *uc) {
    (void)sig; (void)si; (void)uc;
    volatile int here = 0;
    g_handler_sp = (uintptr_t)&here;
}

static struct sigaction g_prev_segv;
// Same shape as write tracking: a store to a protected page faults, the handler
// unprotects it and the store retries. Faults elsewhere go to whoever was there.
static void on_segv(int sig, siginfo_t *si, void *uc) {
    volatile int here = 0;
    uint8_t *page = g_ro_page;
    if (page && (uint8_t *)si->si_addr >= page && (uint8_t *)si->si_addr < page + g_page) {
        g_handler_sp = (uintptr_t)&here;
        mprotect(page, g_page, PROT_READ | PROT_WRITE);
        return;
    }
    if (g_prev_segv.sa_flags & SA_SIGINFO) g_prev_segv.sa_sigaction(sig, si, uc);
    else if (g_prev_segv.sa_handler != SIG_DFL && g_prev_segv.sa_handler != SIG_IGN) g_prev_segv.sa_handler(sig);
    else { signal(sig, SIG_DFL); }   // re-fault into the default action
}

struct result { uint64_t plain, onstack, fault;   // survivor masks, bit i-1 = sp - 8*i
    int plain_on_alt, onstack_on_alt, fault_on_alt, error; };

static int on_alt(void) {
    return g_alt && g_handler_sp >= (uintptr_t)g_alt && g_handler_sp < (uintptr_t)g_alt + g_alt_len;
}

static void *probe_main(void *arg) {
    struct result *r = arg;
    int tgid = getpid(), tid = (int)syscall(SYS_gettid);
    struct sigaction sa, prev_usr2;
    // (a) control: handler without SA_ONSTACK, so the frame lands on this stack
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_usr2; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
    if ((r->error = sigaction(SIGUSR2, &sa, &prev_usr2) ? errno : 0)) return NULL;
    if ((r->error = s2a_android_altstack_init())) goto restore;
    g_handler_sp = 0;
    r->plain = s2a_redzone_tgkill(tgid, tid, SIGUSR2);
    r->plain_on_alt = on_alt();
    // (b) guest rule: SA_ONSTACK plus the guest alternate stack
    if ((r->error = s2a_android_sigaction(SIGUSR2, on_usr2, NULL))) goto restore;
    g_handler_sp = 0;
    r->onstack = s2a_redzone_tgkill(tgid, tid, SIGUSR2);
    r->onstack_on_alt = on_alt();
    // (c) write-protect fault; in an app process ART's sigchain sees SIGSEGV first
    g_page = (size_t)sysconf(_SC_PAGESIZE);
    uint8_t *page = mmap(NULL, g_page, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) { r->error = errno; goto restore; }
    g_ro_page = page;
    if ((r->error = s2a_android_sigaction(SIGSEGV, on_segv, &g_prev_segv))) { munmap(page, g_page); goto restore; }
    g_handler_sp = 0;
    r->fault = s2a_redzone_store((uint64_t *)page);
    r->fault_on_alt = on_alt();
    sigaction(SIGSEGV, &g_prev_segv, NULL);
    g_ro_page = NULL;
    munmap(page, g_page);
restore:
    sigaction(SIGUSR2, &prev_usr2, NULL);
    s2a_android_altstack_free();
    return NULL;
}

int s2a_android_redzone_check(char *report, size_t n) {
    struct result r = {0};
    pthread_t t;
    int e = pthread_create(&t, NULL, probe_main, &r);
    if (e || (pthread_join(t, NULL), r.error)) {
        snprintf(report, n, "Signal red zone: probe failed (errno %d)", e ? e : r.error);
        return e ? e : r.error;
    }
    const uint64_t all = (1u << 14) - 1;
    int ok = r.onstack == all && r.onstack_on_alt && r.fault == all && r.fault_on_alt;
    char lost[96] = "";
    for (unsigned i = 1, k = 0; i <= 14 && k < sizeof lost; i++)
        if (!(r.plain >> (i - 1) & 1)) k += (unsigned)snprintf(lost + k, sizeof lost - k, "%ssp-%u", k ? "," : "", 8 * i);
    snprintf(report, n, "Signal red zone (112 B below sp): %s; without SA_ONSTACK %d/14 words kept%s%s%s; "
             "SA_ONSTACK %d/14%s; write fault via sigchain %d/14%s",
             ok ? "ok" : "FAILED", __builtin_popcountll(r.plain), *lost ? " (lost " : "", lost, *lost ? ")" : "",
             __builtin_popcountll(r.onstack), r.onstack_on_alt ? " on alt stack" : " NOT on alt stack",
             __builtin_popcountll(r.fault), r.fault_on_alt ? " on alt stack" : " NOT on alt stack");
    return ok ? 0 : EPROTO;
}
#endif
