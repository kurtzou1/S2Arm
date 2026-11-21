// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#define VK_USE_PLATFORM_OHOS 1
#include <vulkan/vulkan.h>
#include <native_window/external_window.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include "s2a_hostapi.h"
#include "host_android.h"
#include "host_ui.h"
#include "input.h"
#include "wsi_lease.h"
#include "runtime_ohos.h"
#include "../tests/alias_snapshot_probe.h"

// Optional new-backend hooks; the default legacy archive has none of them.
extern int nvn_ohos_set_dirs(const char *, const char *) __attribute__((weak));
extern void nvn_ohos_set_window(void *, uint32_t, uint32_t) __attribute__((weak));
extern void nvn_ohos_set_safepoint(void (*)(void)) __attribute__((weak));
extern void s2a_android_guest_host_safepoint(void);

// This host reuses the platform-neutral HostApi/input/lease implementations.
// The retained OHNativeWindow is the only source of display dimensions.
static s2a_wsi_lease *g_lease;
static s2a_ui_broker *g_ui;
static struct s2a_wsi_api g_wsi;
static struct s2a_android_runtime_request g_request;
static char g_modules[16][16];
static const char *g_module_ptrs[16];
static char *g_game, *g_state, *g_module_dir;
static void *g_owner;
static void *g_current_window;
static uint64_t g_session = 1;
static int g_window_width=1280,g_window_height=720;
void s2a_ohos_perf_session(int,int);
void s2a_ohos_perf_foreground(int);
void s2a_ohos_fps_reset_clock(void);
static void retain(void *w) { OH_NativeWindow_NativeObjectReference(w); }
static void release(void *w) { OH_NativeWindow_NativeObjectUnreference(w); }

int s2a_ohos_create_surface(uint64_t instance, void *window, uint64_t *surface) {
    if (!instance || !window || !surface) return VK_ERROR_INITIALIZATION_FAILED;
    *surface = 0;
    PFN_vkCreateSurfaceOHOS create = (PFN_vkCreateSurfaceOHOS)vkGetInstanceProcAddr((VkInstance)(uintptr_t)instance, "vkCreateSurfaceOHOS");
    if (!create) return VK_ERROR_EXTENSION_NOT_PRESENT;
    const char *source = getenv("DEBUG_S2A_GAME_SURFACE");
    if (source && !strcmp(source,"1")) {
        int32_t value = -1;
        int set = OH_NativeWindow_NativeWindowHandleOpt(window, SET_SOURCE_TYPE, (int32_t)OH_SURFACE_SOURCE_GAME);
        int get = OH_NativeWindow_NativeWindowHandleOpt(window, GET_SOURCE_TYPE, &value);
        fprintf(stderr,"[OHOS surface] game-source set=%d get=%d actual=%d expected=%d\n",set,get,value,(int)OH_SURFACE_SOURCE_GAME);
    }
    VkSurfaceCreateInfoOHOS info = {.sType = VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS, .window = window};
    VkSurfaceKHR value = VK_NULL_HANDLE;
    VkResult result = create((VkInstance)(uintptr_t)instance, &info, NULL, &value);
    if (result == VK_SUCCESS) *surface = (uint64_t)value;
    return result;
}

int s2a_ohos_shell_init(void *owner, const char *language, const char *region, const char *zone) {
    if (!owner || !language || !region || !zone) return EINVAL;
    if (g_lease) return EALREADY;
    const struct s2a_wsi_window_ops ops = {retain, release};
    g_lease = s2a_wsi_create(g_session, &ops);
    if (!g_lease) return ENOMEM;
    struct s2a_android_host_config cfg = {language, region, zone, 0, 0, 0};
    int error = s2a_android_host_register(&cfg);
    if (error) { s2a_wsi_destroy(g_lease); g_lease = NULL; return error; }
    g_ui = s2a_ui_broker_create(g_session);
    if (!g_ui) return ENOMEM;
    g_owner = owner;
    s2a_android_host_set_lease(g_lease);
    s2a_wsi_api_fill(g_lease, &g_wsi);
    s2a_android_input_reset();
    return 0;
}

int s2a_ohos_shell_window(void *window, int width, int height, float hz) {
    if (!g_lease || !window || width <= 0 || height <= 0 || hz <= 0) return EINVAL;
    if (g_current_window != window) {
        if (g_current_window) return EBUSY;
        if (!s2a_wsi_offer(g_lease, window)) return EIO;
        g_current_window = window;
    }
    g_window_width=width;g_window_height=height;
    if (nvn_ohos_set_window) nvn_ohos_set_window(window, (uint32_t)width, (uint32_t)height);
    const int32_t insets[4] = {0, 0, 0, 0};
    s2a_wsi_update(g_lease, width, height, VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR, insets, hz);
    s2a_wsi_set_foreground(g_lease, 1);
    return 0;
}
int s2a_ohos_shell_detach(void) {
    if (!g_lease) return 0;
    s2a_android_input_reset();
    s2a_wsi_set_foreground(g_lease, 0);
    // Revoke dimensions before releasing the shell's retained native window.
    // A concurrent attachment must fail closed rather than consume stale size.
    if (nvn_ohos_set_window) nvn_ohos_set_window(NULL, 0, 0);
    int error = s2a_wsi_revoke(g_lease, 1500);
    if (!error) g_current_window = NULL;
    return error;
}
void s2a_ohos_shell_foreground(int foreground) {
    s2a_ohos_perf_foreground(foreground);
    s2a_ohos_fps_reset_clock();
    if (!foreground) s2a_android_input_reset();
    if (g_ui) s2a_ui_broker_available(g_ui, g_session, foreground != 0);
    if (g_lease) s2a_wsi_set_foreground(g_lease, foreground != 0);
}
void s2a_ohos_shell_input(uint32_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    {
        // 诊断：按键状态变化的前 32 次记一行（确认触控层的输入真的到了宿主）。
        static uint32_t last = 0xffffffffu; static int n;
        if (buttons != last && n < 32) { n++; fprintf(stderr, "[OHOS input] buttons=0x%x\n", buttons); }
        last = buttons;
    }
    int32_t sticks[4] = {lx, ly, rx, ry};
    for (unsigned i=0; i<4; i++) {
        if (sticks[i] < -32768) sticks[i] = -32768;
        if (sticks[i] > 32767) sticks[i] = 32767;
    }
    s2a_android_input_set(buttons, sticks);
}
// The pack records a patched projection aspect in <root>/ready.json ("presentationAspect": "53:33").
// The generic path reads it in OhosPresentationPlan; the direct present reads S2A_PRESENT_ASPECT.
static void export_presentation_aspect(const char *game) {
    char path[1200];
    const char *slash = strrchr(game, '/');
    if (!slash || (size_t)(slash - game) + sizeof "/ready.json" > sizeof path) return;
    memcpy(path, game, (size_t)(slash - game)); strcpy(path + (slash - game), "/ready.json");
    FILE *f = fopen(path, "rb");
    if (!f) return;
    static char text[65536];
    size_t n = fread(text, 1, sizeof text - 1, f); fclose(f); text[n] = 0;
    const char *key = strstr(text, "\"presentationAspect\"");
    unsigned w = 0, h = 0;
    if (key && (key = strchr(key + 20, ':')) && (key = strchr(key, '"')) && sscanf(key + 1, "%u:%u", &w, &h) == 2 &&
        w && h && w <= 100000 && h <= 100000) {
        char value[32]; snprintf(value, sizeof value, "%u:%u", w, h);
        setenv("S2A_PRESENT_ASPECT", value, 1);
        fprintf(stderr, "[OHOS display] presentation aspect %s (patched projection)\n", value);
    }
}
// Diagnostics: DEBUG_S2A_AUTOPRESS="bits@sec[:holdms],..." presses pad buttons (TouchModel bit order,
// A=1 B=2 X=4 Y=8 ... PLUS=1024) at those seconds after launch, for automated device tests where
// injected touches do not reach the overlay. Debug-only; absent = no thread.
#include <pthread.h>
#include <time.h>
static char g_autopress[512];
// Explicitly enabled, bounded device-test input mailbox. Never active for users
// without DEBUG_S2A_INPUT_PROBE=1. Sequence numbers prevent repeating a command;
// END rejects partially transferred records. Every accepted hold releases input.
// Diagnostics: while DEBUG_S2A_INPUT_PROBE is on, creating <state>/debug-hangdump makes every thread
// print its PC and frame-pointer chain. For hangs where no system stack dump is available.
#include <dirent.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/syscall.h>
#include <ucontext.h>
#define S2A_HANGDUMP_SIGNAL SIGUSR2
static void hang_print(const char *tag, uintptr_t pc) {
    Dl_info info; const char *name = "?"; uintptr_t off = pc;
    if (pc && dladdr((void *)pc, &info) && info.dli_fname) {
        name = strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname;
        off = pc - (uintptr_t)info.dli_fbase;
    }
    fprintf(stderr, "[hang] %ld %s %s+0x%lx\n", (long)syscall(SYS_gettid), tag, name, (unsigned long)off);
}
static void hang_handler(int sig, siginfo_t *si, void *raw) {
    (void)sig; (void)si;
    ucontext_t *uc = raw;
    char comm[32] = "?"; char path[64];
    snprintf(path, sizeof path, "/proc/self/task/%ld/comm", (long)syscall(SYS_gettid));
    FILE *f = fopen(path, "r"); if (f) { if (fgets(comm, sizeof comm, f)) comm[strcspn(comm, "\n")] = 0; fclose(f); }
    fprintf(stderr, "[hang] %ld thread %s\n", (long)syscall(SYS_gettid), comm);
    hang_print("pc", (uintptr_t)uc->uc_mcontext.pc);
    hang_print("lr", (uintptr_t)uc->uc_mcontext.regs[30]);
    uintptr_t fp = (uintptr_t)uc->uc_mcontext.regs[29], sp = (uintptr_t)uc->uc_mcontext.sp;
    for (int i = 0; i < 24; ++i) {
        if (fp < sp || fp > sp + (64u << 20) || (fp & 7)) break;
        uintptr_t next = ((uintptr_t *)fp)[0], ret = ((uintptr_t *)fp)[1];
        hang_print("fp", ret);
        if (next <= fp) break;
        fp = next;
    }
}
static void hang_dump_all(void) {
    struct sigaction action; memset(&action, 0, sizeof action);
    action.sa_sigaction = hang_handler; action.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK; sigemptyset(&action.sa_mask);
    sigaction(S2A_HANGDUMP_SIGNAL, &action, NULL);
    DIR *dir = opendir("/proc/self/task"); if (!dir) return;
    long self = syscall(SYS_gettid); struct dirent *e;
    while ((e = readdir(dir))) {
        long tid = atol(e->d_name);
        if (tid > 0 && tid != self) syscall(SYS_tgkill, (long)getpid(), tid, S2A_HANGDUMP_SIGNAL);
    }
    closedir(dir);
}
static void *input_probe_thread(void *arg) {
    (void)arg;
    char path[1200];
    if (snprintf(path, sizeof path, "%s/debug-pad.txt", g_state) >= (int)sizeof path) return NULL;
    unsigned last = 0;
    for (;;) {
        FILE *f = fopen(path, "r");
        unsigned seq = 0, bits = 0, hold = 0;
        int32_t sticks[4] = {0};
        char end[8] = {0};
        int n = f ? fscanf(f, "%u %u %d %d %d %d %u %7s", &seq, &bits,
            &sticks[0], &sticks[1], &sticks[2], &sticks[3], &hold, end) : 0;
        if (f) fclose(f);
        int valid = n == 8 && !strcmp(end, "END") && seq > last && hold > 0 && hold <= 10000;
        for (int i = 0; i < 4; ++i) if (sticks[i] < -32767 || sticks[i] > 32767) valid = 0;
        if (valid) {
            last = seq;
            s2a_android_input_set(bits, sticks);
            struct timespec pressed, released;
            clock_gettime(CLOCK_MONOTONIC, &pressed);
            fprintf(stderr, "[OHOS input probe] seq=%u buttons=%u sticks=%d,%d,%d,%d hold=%u start_ns=%llu\n",
                seq, bits, sticks[0], sticks[1], sticks[2], sticks[3], hold,
                (unsigned long long)pressed.tv_sec * 1000000000ull + (unsigned long long)pressed.tv_nsec);
            struct timespec duration = {hold / 1000, (long)(hold % 1000) * 1000000L};
            nanosleep(&duration, NULL);
            clock_gettime(CLOCK_MONOTONIC, &released);
            s2a_android_input_reset();
            fprintf(stderr, "[OHOS input probe] end seq=%u end_ns=%llu\n", seq,
                (unsigned long long)released.tv_sec * 1000000000ull + (unsigned long long)released.tv_nsec);
        }
        char hang[1200];
        if (snprintf(hang, sizeof hang, "%s/debug-hangdump", g_state) < (int)sizeof hang && !access(hang, F_OK)) { unlink(hang); hang_dump_all(); }
        struct timespec poll = {0, 100000000}; nanosleep(&poll, NULL);
    }
    return NULL;
}
static void *autopress_thread(void *arg) {
    (void)arg;
    struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
    const char *p = g_autopress;
    while (*p) {
        unsigned bits = 0, hold = 300; double at = 0;
        int used = 0;
        if (sscanf(p, "%u@%lf%n", &bits, &at, &used) < 2) break;
        p += used;
        if (*p == ':') { int u2 = 0; sscanf(p + 1, "%u%n", &hold, &u2); p += 1 + u2; }
        if (*p == ',') p++;
        for (;;) {
            struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
            double el = (double)(now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
            if (el >= at) break;
            struct timespec nap = { 0, 50000000 }; nanosleep(&nap, NULL);
        }
        int32_t sticks[4] = {0, 0, 0, 0};
        fprintf(stderr, "[OHOS autopress] buttons=0x%x at %.1fs hold %ums\n", bits, at, hold);
        s2a_android_input_set(bits, sticks);
        struct timespec h = { (time_t)(hold / 1000), (long)(hold % 1000) * 1000000L }; nanosleep(&h, NULL);
        s2a_android_input_set(0, sticks);
    }
    return NULL;
}
// Diagnostics: DEBUG_S2A_PCSAMPLE="name1|name2@start_s:dur_s[:hz]" samples the PC/LR and a short
// frame-pointer chain of threads whose comm contains a name, by tgkill(SIGPROF) from a helper
// thread (hiperf on this kernel only sees kernel samples). Writes <state>/pcsample-<pid>.txt as
// "tid name addr..." with module+offset per address. Debug-only; absent = no thread, no handler.
#include <signal.h>
#include <dirent.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <ucontext.h>
#include <unistd.h>
#include <sys/syscall.h>
enum { PCS_MAX = 60000, PCS_DEPTH = 8, PCS_THREADS = 8 };
static char g_pcsample[256];
static uint64_t (*g_pcs_buf)[PCS_DEPTH + 1];
static _Atomic unsigned g_pcs_n;
static _Atomic int g_pcs_tid;           // tid being signalled; one signal in flight at a time
static void pcs_handler(int sig, siginfo_t *si, void *uc) {
    (void)sig; (void)si;
    unsigned i = atomic_fetch_add(&g_pcs_n, 1);
    if (i >= PCS_MAX) return;
    mcontext_t *m = &((ucontext_t *)uc)->uc_mcontext;
    uint64_t *e = g_pcs_buf[i];
    e[0] = (uint64_t)(uint32_t)syscall(SYS_gettid) << 32;
    e[1] = m->pc; e[2] = m->regs[30];
    uint64_t sp = m->sp, fp = m->regs[29];
    for (int d = 3; d <= PCS_DEPTH; d++) {
        if ((fp & 7) || fp < sp || fp - sp > (16u << 20)) break;
        uint64_t next = ((uint64_t *)fp)[0], ret = ((uint64_t *)fp)[1];
        e[d] = ret;
        if (next <= fp) break;
        fp = next;
    }
}
static void pcs_addr(FILE *f, uint64_t a) {
    Dl_info di;
    if (a && dladdr((void *)(uintptr_t)a, &di) && di.dli_fname) {
        const char *b = strrchr(di.dli_fname, '/');
        fprintf(f, " %s+0x%llx", b ? b + 1 : di.dli_fname, (unsigned long long)(a - (uint64_t)(uintptr_t)di.dli_fbase));
    } else fprintf(f, " 0x%llx", (unsigned long long)a);
}
static void *pcsample_thread(void *arg) {
    (void)arg;
    char names[160] = {0}; double start = 0, dur = 0; int hz = 500;
    if (sscanf(g_pcsample, "%159[^@]@%lf:%lf:%d", names, &start, &dur, &hz) < 3 || dur <= 0) return NULL;
    if (hz < 50 || hz > 2000) hz = 500;
    g_pcs_buf = calloc(PCS_MAX, sizeof *g_pcs_buf);
    if (!g_pcs_buf) return NULL;
    struct timespec ts = {(time_t)start, (long)((start - (time_t)start) * 1e9)}; nanosleep(&ts, NULL);
    int tids[PCS_THREADS], nt = 0; char tname[PCS_THREADS][24];
    if (!strcmp(names, "busiest")) {
        // names=busiest：按 1 秒内 CPU 时间（/proc/self/task/<tid>/stat 的 utime+stime）挑最忙的线程。
        // 线程名（nx-NN）每次运行都会变，按名字指定容易采错线程。
        enum { MAXT = 512 }; static int bt[MAXT]; static unsigned long long b0[MAXT]; int nb = 0;
        for (int pass = 0; pass < 2; pass++) {
            DIR *bd = opendir("/proc/self/task");
            for (struct dirent *de; bd && (de = readdir(bd)); ) {
                if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
                char p[300], buf[512] = {0}; snprintf(p, sizeof p, "/proc/self/task/%s/stat", de->d_name);
                FILE *c = fopen(p, "r"); if (!c) continue;
                size_t r = fread(buf, 1, sizeof buf - 1, c); fclose(c); buf[r] = 0;
                char *q = strrchr(buf, ')'); if (!q) continue;
                unsigned long long ut = 0, st = 0;
                if (sscanf(q + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu", &ut, &st) != 2) continue;
                int tid = atoi(de->d_name);
                if (pass == 0) { if (nb < MAXT) { bt[nb] = tid; b0[nb] = ut + st; nb++; } }
                else for (int k = 0; k < nb; k++) if (bt[k] == tid) { b0[k] = ut + st - b0[k]; bt[k] = -tid; break; }
            }
            if (bd) closedir(bd);
            if (pass == 0) nanosleep(&(struct timespec){1, 0}, NULL);
        }
        int best = -1; for (int k = 0; k < nb; k++) if (bt[k] < 0 && (best < 0 || b0[k] > b0[best])) best = k;
        if (best >= 0) {
            tids[0] = -bt[best]; nt = 1;
            char p[300]; snprintf(p, sizeof p, "/proc/self/task/%d/comm", tids[0]);
            FILE *c = fopen(p, "r"); tname[0][0] = 0;
            if (c) { if (fgets(tname[0], 24, c)) tname[0][strcspn(tname[0], "\n")] = 0; fclose(c); }
            fprintf(stderr, "[OHOS pcsample] busiest tid=%d name=%s ticks=%llu/s\n", tids[0], tname[0], b0[best]);
        }
        names[0] = 0;   // 跳过下面按名字匹配
    }
    DIR *d = names[0] ? opendir("/proc/self/task") : NULL;
    for (struct dirent *de; d && nt < PCS_THREADS && (de = readdir(d)); ) {
        if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
        char p[300], comm[24] = {0}; snprintf(p, sizeof p, "/proc/self/task/%s/comm", de->d_name);
        FILE *c = fopen(p, "r"); if (!c) continue;
        if (fgets(comm, sizeof comm, c)) comm[strcspn(comm, "\n")] = 0;
        fclose(c);
        for (char *tok = names; *tok; ) {
            size_t n = strcspn(tok, "|");
            char want[24] = {0}; memcpy(want, tok, n < 23 ? n : 23);
            if (want[0] && strstr(comm, want)) { tids[nt] = atoi(de->d_name); snprintf(tname[nt], 24, "%s", comm); nt++; break; }
            tok += n; if (*tok == '|') tok++;
        }
    }
    if (d) closedir(d);
    struct sigaction sa = {0};
    sa.sa_sigaction = pcs_handler; sa.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK; sigemptyset(&sa.sa_mask);
    if (sigaction(SIGPROF, &sa, NULL)) { fprintf(stderr, "[OHOS pcsample] sigaction errno=%d\n", errno); return NULL; }
    fprintf(stderr, "[OHOS pcsample] start threads=%d hz=%d dur=%.0fs\n", nt, hz, dur);
    struct timespec t0, now, gap = {0, 1000000000L / hz};
    clock_gettime(CLOCK_MONOTONIC, &t0);
    pid_t pid = getpid();
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9 >= dur || atomic_load(&g_pcs_n) >= PCS_MAX) break;
        for (int i = 0; i < nt; i++) { atomic_store(&g_pcs_tid, tids[i]); syscall(SYS_tgkill, pid, tids[i], SIGPROF); nanosleep(&(struct timespec){0, 200000}, NULL); }
        nanosleep(&gap, NULL);
    }
    struct timespec settle = {0, 50000000}; nanosleep(&settle, NULL);
    signal(SIGPROF, SIG_IGN);
    unsigned n = atomic_load(&g_pcs_n); if (n > PCS_MAX) n = PCS_MAX;
    char path[1200]; snprintf(path, sizeof path, "%s/pcsample-%d.txt", g_state, (int)pid);
    FILE *f = fopen(path, "w");
    if (f) {
        for (unsigned i = 0; i < n; i++) {
            int tid = (int)(g_pcs_buf[i][0] >> 32); const char *nm = "?";
            for (int k = 0; k < nt; k++) if (tids[k] == tid) nm = tname[k];
            fprintf(f, "%d %s", tid, nm);
            for (int k = 1; k <= PCS_DEPTH && g_pcs_buf[i][k]; k++) pcs_addr(f, g_pcs_buf[i][k]);
            fputc('\n', f);
        }
        fclose(f);
    }
    fprintf(stderr, "[OHOS pcsample] done samples=%u file=%s\n", n, path);
    return NULL;
}
// Diagnostics: DEBUG_S2A_FPSLOG=<seconds> logs presented frames per interval from the existing
// present counter, so device A/B compares averages instead of overlay snapshots. Debug-only.
uint64_t s2a_ohos_present_count(void);
extern int nvn_unimpl_kinds(void) __attribute__((weak));
extern size_t nvn_unimpl_dump(char *, size_t) __attribute__((weak));
static int g_fpslog_s;
static void *fpslog_thread(void *arg) {
    (void)arg;
    uint64_t last = s2a_ohos_present_count();
    struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (unsigned n = 1;; n++) {
        struct timespec gap = {g_fpslog_s, 0}; nanosleep(&gap, NULL);
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
        uint64_t cur = s2a_ohos_present_count();
        double el = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
        fprintf(stderr, "[OHOS fpslog] t=%.0fs frames=%llu fps=%.2f\n", (double)n * g_fpslog_s,
                (unsigned long long)(cur - last), el > 0 ? (cur - last) / el : 0.0);
        last = cur; t0 = now;
        // The OHOS shell restarts the process on exit, so session-close output
        // is not guaranteed. Read the core's synchronized diagnostics while live.
        if (nvn_unimpl_kinds && nvn_unimpl_dump) {
            char rows[16384];
            size_t bytes = nvn_unimpl_dump(rows, sizeof rows);
            fprintf(stderr, "[OHOS] nvk unimpl summary: %d kinds (live snapshot)\n", nvn_unimpl_kinds());
            for (char *p = rows, *end; bytes && (end = strchr(p, '\n')); p = end + 1) {
                *end = 0;
                fprintf(stderr, "[OHOS] nvk unimpl\t%s\n", p);
            }
        }
    }
    return NULL;
}
// Experiment: DEBUG_S2A_PIN=max|<hex mask> keeps the busiest "S2A.GPU" thread (the single GPU
// command thread; driver workers inherit the name but stay idle) on the highest nominal-frequency
// cores, re-applying every second because the system rewrites affinities (D2R H-09 on Mate90:
// same-package 42 -> 60 fps). Logs topology, requested and read-back masks. Debug-only.
#include <sched.h>
static char g_pin[32];
static unsigned long long pin_thread_cpu(int tid) {
    char p[64], b[1024]; snprintf(p, sizeof p, "/proc/self/task/%d/stat", tid);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    size_t n = fread(b, 1, sizeof b - 1, f); fclose(f); b[n] = 0;
    char *s = strrchr(b, ')'); if (!s) return 0;
    unsigned long long ut = 0, st = 0;   // fields 14/15 counted after "pid (comm)"
    if (sscanf(s + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu", &ut, &st) != 2) return 0;
    return ut + st;
}
static void *pin_thread(void *arg) {
    (void)arg;
    unsigned mask = 0; long best = 0;
    const int watch_only = !strcmp(g_pin, "watch");   // 只观察线程落核与频率，不改亲和性
    if (watch_only) mask = 0xffffu;
    else if (strcmp(g_pin, "max")) mask = (unsigned)strtoul(g_pin, NULL, 16);
    else {
        long all = 0;
        for (int c = 0; c < 32; c++) {
            char p[96]; snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", c);
            FILE *f = fopen(p, "r"); if (!f) continue;
            long v = 0; if (fscanf(f, "%ld", &v) == 1 && v > 0) {
                fprintf(stderr, "[OHOS pin] cpu%d max_khz=%ld\n", c, v);
                all |= 1L << c; if (v > best) { best = v; mask = 0; } if (v == best) mask |= 1u << c;
            }
            fclose(f);
        }
        if ((long)mask == all) mask = 0;
    }
    if (!mask) { fprintf(stderr, "[OHOS pin] no mask (homogeneous or unreadable) nominal_khz=%ld\n", best); return NULL; }
    struct timespec warm = {30, 0}; nanosleep(&warm, NULL);
    int tid = 0; unsigned sets = 0, drifts = 0;
    for (unsigned tick = 0;; tick++) {
        if (!tid || tick % 10 == 0) {   // re-pick the hottest S2A.GPU thread every 10 s
            int pick = 0; unsigned long long hot = 0;
            DIR *d = opendir("/proc/self/task");
            for (struct dirent *de; d && (de = readdir(d)); ) {
                if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
                char p[300], comm[24] = {0}; snprintf(p, sizeof p, "/proc/self/task/%s/comm", de->d_name);
                FILE *c = fopen(p, "r"); if (!c) continue;
                if (fgets(comm, sizeof comm, c)) comm[strcspn(comm, "\n")] = 0;
                fclose(c);
                if (strcmp(comm, "S2A.GPU") && strcmp(comm, "s2a-gfx") && strncmp(comm, "nx-", 3)) continue;   // 直连回放在游戏渲染线程 nx-NN 上
                unsigned long long t = pin_thread_cpu(atoi(de->d_name));
                if (t > hot) { hot = t; pick = atoi(de->d_name); }
            }
            if (d) closedir(d);
            if (pick != tid) fprintf(stderr, "[OHOS pin] target tid=%d cpu_ticks=%llu\n", pick, hot);
            tid = pick;
        }
        if (watch_only && tick % 30 == 5) {   // 所有线程的亲和性、cgroup、累计 CPU，看系统怎么分核
            DIR *d = opendir("/proc/self/task");
            for (struct dirent *de; d && (de = readdir(d)); ) {
                if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
                char p[300], comm[24] = {0}, line[160], allowed[64] = "?", group[96] = "?";
                snprintf(p, sizeof p, "/proc/self/task/%s/comm", de->d_name);
                FILE *c = fopen(p, "r"); if (c) { if (fgets(comm, sizeof comm, c)) comm[strcspn(comm, "\n")] = 0; fclose(c); }
                unsigned long long t = pin_thread_cpu(atoi(de->d_name));
                if (t < 300) continue;
                snprintf(p, sizeof p, "/proc/self/task/%s/status", de->d_name);
                c = fopen(p, "r");
                if (c) { while (fgets(line, sizeof line, c)) if (!strncmp(line, "Cpus_allowed_list:", 18)) { line[strcspn(line, "\n")] = 0; snprintf(allowed, sizeof allowed, "%s", line + 19); } fclose(c); }
                snprintf(p, sizeof p, "/proc/self/task/%s/cgroup", de->d_name);
                c = fopen(p, "r");
                if (c) { while (fgets(line, sizeof line, c)) if (strstr(line, "cpuset") || strstr(line, "cpu,")) { line[strcspn(line, "\n")] = 0; snprintf(group, sizeof group, "%s", line); } fclose(c); }
                fprintf(stderr, "[OHOS pin] thread %s %s ticks=%llu allowed=%s group=%s\n", de->d_name, comm, t, allowed, group);
            }
            if (d) closedir(d);
        }
        if (tid) {
            char sp[64], sb[1024];
            snprintf(sp, sizeof sp, "/proc/self/task/%d/stat", tid);
            FILE *sf = fopen(sp, "r");
            if (sf) {
                size_t sn = fread(sb, 1, sizeof sb - 1, sf);
                fclose(sf);
                sb[sn] = 0;
                char *rp = strrchr(sb, ')');
                int core = -1, field = 0;
                for (char *q = rp ? rp + 2 : NULL; q && *q; q++)
                    if (*q == ' ' && ++field == 36) { core = atoi(q + 1); break; }   // /proc stat 第 39 项 processor
                char fp[96];
                snprintf(fp, sizeof fp, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", core);
                long khz = -1;
                FILE *ff = core >= 0 ? fopen(fp, "r") : NULL;
                if (ff) { if (fscanf(ff, "%ld", &khz) != 1) khz = -1; fclose(ff); }
                fprintf(stderr, "[OHOS pin] watch tid=%d core=%d cur_khz=%ld\n", tid, core, khz);
            }
        }
        if (tid && !watch_only) {
            cpu_set_t cur; CPU_ZERO(&cur); unsigned have = 0;
            if (!sched_getaffinity(tid, sizeof cur, &cur)) for (int c = 0; c < 32; c++) if (CPU_ISSET(c, &cur)) have |= 1u << c;
            if (have != mask) {
                cpu_set_t set; CPU_ZERO(&set); for (int c = 0; c < 32; c++) if (mask >> c & 1) CPU_SET(c, &set);
                int r = sched_setaffinity(tid, sizeof set, &set), e = r ? errno : 0;
                cpu_set_t back; CPU_ZERO(&back); unsigned got = 0;
                if (!sched_getaffinity(tid, sizeof back, &back)) for (int c = 0; c < 32; c++) if (CPU_ISSET(c, &back)) got |= 1u << c;
                if (sets++) drifts++;
                if (sets <= 5 || !(sets & 255)) fprintf(stderr, "[OHOS pin] tid=%d had=%#x requested=%#x rc=%d errno=%d actual=%#x sets=%u drifts=%u\n", tid, have, mask, r, e, got, sets, drifts);
            }
        }
        struct timespec gap = {1, 0}; nanosleep(&gap, NULL);
    }
    return NULL;
}
#include "dmabuf_probe.inc"
#include "codec_caps_probe.inc"
#define main s2a_mesh_contract_main
#include "../probes/mesh/mesh_emulation_probe.c"
#undef main
#undef OK
#undef CHECK
// Diagnostics: <state>/debug-env.txt lines "DEBUG_S2A_X=value" (and engine "S2A_X=value" switches,
// e.g. S2A_GPU_READFLUSH) become process env (the OHOS stand-in for Android debug.s2a.* properties).
// Other keys are ignored; absent file = no change.
static void load_debug_env(const char *state) {
    int start_autopress = 0;
    char path[1200];
    if (snprintf(path, sizeof path, "%s/debug-env.txt", state) >= (int)sizeof path) return;
    FILE *f = fopen(path, "rb");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *eq = strchr(line, '=');
        if (!eq || (strncmp(line, "DEBUG_S2A_", 10) && strncmp(line, "S2A_", 4) && strncmp(line, "DM_", 3))) continue;
        *eq = 0;
        setenv(line, eq + 1, 1);
        fprintf(stderr, "[OHOS debug] %s=%s (from debug-env.txt)\n", line, eq + 1);
        if (!strcmp(line, "DEBUG_S2A_AUTOPRESS") && !g_autopress[0]) {
            snprintf(g_autopress, sizeof g_autopress, "%s", eq + 1);
            start_autopress = 1;
        }
    }
    fclose(f);
    // 上游逐帧 TSV（nvn_vk_frame_tsv.c）写到 S2A_FRAME_LOG_DIR；安卓由 bridge.cpp 设，鸿蒙在这里补：
    // 只在 DEBUG_S2A_FRAME_TSV=1 时指到本目录（debug-env.txt 同目录，s2a.sh 拉日志时一并取回）。
    const char *tsv = getenv("DEBUG_S2A_FRAME_TSV");
    if (tsv && tsv[0] == '1' && !getenv("S2A_FRAME_LOG_DIR")) setenv("S2A_FRAME_LOG_DIR", state, 1);
    const char *isolated_pool_test = getenv("DEBUG_S2A_DMABUF_PROBE");
    if (isolated_pool_test && !strcmp(isolated_pool_test, "2")) return;
    if (start_autopress) {
        pthread_t th;
        if (pthread_create(&th, NULL, autopress_thread, NULL) == 0) pthread_detach(th);
    }
    const char *pin = getenv("DEBUG_S2A_PIN");
    if (pin && *pin && strcmp(pin, "0")) {
        snprintf(g_pin, sizeof g_pin, "%s", pin);
        pthread_t th;
        if (pthread_create(&th, NULL, pin_thread, NULL) == 0) pthread_detach(th);
    }
    const char *fpslog = getenv("DEBUG_S2A_FPSLOG");
    if (fpslog && atoi(fpslog) > 0 && atoi(fpslog) <= 60) {
        g_fpslog_s = atoi(fpslog);
        pthread_t th;
        if (pthread_create(&th, NULL, fpslog_thread, NULL) == 0) pthread_detach(th);
    }
    const char *pcs = getenv("DEBUG_S2A_PCSAMPLE");
    if (pcs && *pcs) {
        snprintf(g_pcsample, sizeof g_pcsample, "%s", pcs);
        pthread_t th;
        if (pthread_create(&th, NULL, pcsample_thread, NULL) == 0) pthread_detach(th);
    }
    // Expose the existing scheduler control for bounded device A/B only.
    // Absent/invalid values preserve its production default; no new policy.
    const char *cores_probe = getenv("DEBUG_S2A_CORES");
    if (cores_probe && (!strcmp(cores_probe, "0") || !strcmp(cores_probe, "1") ||
                        !strcmp(cores_probe, "ondemand"))) {
        setenv("S2A_CORES", cores_probe, 1);
        fprintf(stderr, "[OHOS scheduler probe] S2A_CORES=%s\n", cores_probe);
    }
    const char *dmabuf_probe = getenv("DEBUG_S2A_DMABUF_PROBE");
    if (dmabuf_probe && !strcmp(dmabuf_probe, "1")) {
        pthread_t th;
        if (pthread_create(&th, NULL, dmabuf_probe_thread, NULL) == 0) pthread_detach(th);
    }
    const char *codec_facts = getenv("DEBUG_S2A_CODEC_FEATURES");
    if (codec_facts && !strcmp(codec_facts, "1")) {
        pthread_t th;
        int error = pthread_create(&th, NULL, codec_caps_probe_thread, NULL);
        if (!error) pthread_detach(th);
        fprintf(stderr, "[OHOS codec facts] background query start rc=%d\n", error);
    }
    const char *input_probe = getenv("DEBUG_S2A_INPUT_PROBE");
    if (input_probe && !strcmp(input_probe, "1")) {
        pthread_t th;
        int error = pthread_create(&th, NULL, input_probe_thread, NULL);
        if (!error) pthread_detach(th);
        fprintf(stderr, "[OHOS input probe] start rc=%d\n", error);
    }
}
int s2a_ohos_shell_run(const char *game, const char *state, const char *modules, const char *names, uint64_t program_id) {
    if (!g_owner || !game || !state || !modules || !names || g_game) return EINVAL;
    // Names come from the locally frozen pack manifest; paths and list outlive every guest thread.
    unsigned count = 0; const char *p = names;
    while (*p && count < 16) {
        size_t n = strcspn(p, ",");
        if (!n || n >= sizeof g_modules[0]) return EINVAL;
        memcpy(g_modules[count], p, n); g_modules[count][n] = 0;
        g_module_ptrs[count] = g_modules[count]; count++;
        p += n; if (*p == ',') p++;
    }
    if (*p || !count) return EINVAL;
    g_game = strdup(game); g_state = strdup(state); g_module_dir = strdup(modules);
    if (!g_game || !g_state || !g_module_dir) return ENOMEM;
    export_presentation_aspect(g_game);
    load_debug_env(g_state);
    if (nvn_ohos_set_dirs) {
        // The shell owns the layout: <files>/states/<title id>.
        char *files = strdup(g_state);
        if (!files) return ENOMEM;
        char *title = strrchr(files, '/');
        if (!title) { free(files); return EINVAL; }
        *title = 0;
        char *states = strrchr(files, '/');
        if (!states || strcmp(states, "/states")) { free(files); return EINVAL; }
        *states = 0;
        int error = nvn_ohos_set_dirs(g_state, files);
        free(files);
        if (error) return EIO;
        if (!nvn_ohos_set_safepoint) return ENOSYS;
        nvn_ohos_set_safepoint(s2a_android_guest_host_safepoint);
    }
    const char *mesh_test = getenv("DEBUG_S2A_MESH_CONTRACT");
    if (mesh_test && !strcmp(mesh_test, "1")) {
        char dir[1200], log[1200];
        snprintf(dir, sizeof dir, "%s/mesh-contract", g_state);
        snprintf(log, sizeof log, "%s/mesh-contract.log", g_state);
        mesh_probe_log = fopen(log, "wb");
        if (!mesh_probe_log) return EIO;
        char *args[] = { "mesh-contract", dir, "--negative-first" };
        int positive = s2a_mesh_contract_main(2, args);
        fprintf(mesh_probe_log, "positive result=%d\n", positive);
        int negative = positive ? -1 : s2a_mesh_contract_main(3, args);
        fprintf(mesh_probe_log, "negative result=%d\n%s\n", negative,
                !positive && negative == 1 ? "GPU_POSITIVE_AND_NEGATIVE_PASS" : "GPU_CONTRACT_FAILED");
        fclose(mesh_probe_log); mesh_probe_log = NULL;
        fprintf(stderr, "[OHOS mesh contract] positive=%d negative=%d; guest not started\n", positive, negative);
        return ECANCELED;
    }
    const char *pool_test = getenv("DEBUG_S2A_DMABUF_PROBE");
    if (pool_test && !strcmp(pool_test, "2")) {
        dmabuf_probe_thread(NULL);
        // The diagnostic owns its isolated Vulkan device; never start guest
        // threads or touch its pools after a test failure/timeout.
        return ECANCELED;
    }
    const char *alias_test = getenv("DEBUG_S2A_ALIAS_SNAPSHOT_TEST");
    if (alias_test && !strcmp(alias_test, "1")) {
        int result = s2a_ohos_alias_snapshot_probe();
        fprintf(stderr, "[OHOS alias snapshot] final result=%d; guest intentionally not started\n", result);
        // Test-only process: tracking state is not reused for a game session.
        return ECANCELED;
    }
    g_request = (struct s2a_android_runtime_request){
        .services = {sizeof g_request.services, S2A_ANDROID_SERVICES_ABI, g_session, g_owner,
                     s2a_host_get(), g_game, g_state, &g_wsi, 0, 0},
        .module_dir = g_module_dir, .module_names = g_module_ptrs, .module_count = count, .program_id = program_id
    };
    s2a_ohos_perf_session(g_window_width,g_window_height);
    return s2a_ohos_runtime_run_selected(&g_request);
}
void *s2a_ohos_library_handle(void) { return g_owner; }
const char *s2a_ohos_state_directory(void) { return g_state; }
const char *s2a_ohos_game_directory(void) { return g_game; }
const char *s2a_ohos_module_directory(void) { return g_module_dir; }
int s2a_ohos_shell_status(struct s2a_android_runtime_status *status) {
    return s2a_ohos_runtime_status(g_session, status);
}
int s2a_ohos_shell_stop(void) {
    if (g_ui) s2a_ui_broker_stop(g_ui, g_session);
    s2a_android_input_reset();
    return s2a_ohos_runtime_request_stop(g_session);
}
int s2a_ohos_shell_take_stop(uint32_t *reason, char *detail, size_t cap) {
    return s2a_android_host_take_stop(reason, detail, cap);
}

// Private OHOS keyboard transport. The shared public HostApi UI capability
// remains unchanged; schema validation belongs to the managed and ArkTS ends.
// Broker storage survives until process exit, just like guest threads/DSOs.
int s2a_ohos_ui_available(int available) {
    return g_ui ? s2a_ui_broker_available(g_ui, g_session, available) : S2A_HOST_E_UNSUPPORTED;
}
int s2a_ohos_ui_begin(const char *request, uint64_t *id) {
    return g_ui ? s2a_ui_broker_table()->begin(g_ui, request, id) : S2A_HOST_E_UNSUPPORTED;
}
int s2a_ohos_ui_wait(uint64_t id, int timeout_ms, char *reply, size_t cap, size_t *length) {
    return g_ui ? s2a_ui_broker_table()->wait(g_ui, id, timeout_ms, reply, cap, length) : S2A_HOST_E_UNSUPPORTED;
}
int s2a_ohos_ui_cancel(uint64_t id) {
    return g_ui ? s2a_ui_broker_table()->cancel(g_ui, id) : S2A_HOST_E_UNSUPPORTED;
}
int s2a_ohos_ui_take(uint64_t *id, char *request, size_t cap, size_t *length) {
    return g_ui ? s2a_ui_broker_take(g_ui, g_session, id, request, cap, length) : S2A_HOST_E_UNSUPPORTED;
}
int s2a_ohos_ui_reply(uint64_t id, const char *reply) {
    return g_ui ? s2a_ui_broker_complete(g_ui, g_session, id, reply) : S2A_HOST_E_UNSUPPORTED;
}

// host_android.c (shared) asks for the Android IME broker table. OHOS keeps its own broker
// (s2a_ohos_ui_*, private keyboard protocol), so the HostApi publishes no UI table, as before.
const s2a_host_ui_v1 *s2a_android_ui_table(void) { return NULL; }
void s2a_android_ui_stop(void) {}

// The shared runtime binds these Android-only imports directly. OHOS has no AVC/asset backend yet: fail honestly.
__attribute__((visibility("default"))) int32_t s2a_avc_create(const void *config, void **handle, void *diag) { (void)config; (void)diag; if (handle) *handle = NULL; return -1; }
__attribute__((visibility("default"))) int32_t s2a_avc_decode(void *handle, const uint8_t *au, uint32_t length, void *a, void *b, void *c) { (void)handle; (void)au; (void)length; (void)a; (void)b; (void)c; return -1; }
__attribute__((visibility("default"))) int32_t s2a_avc_planes(void *handle, uint32_t id, void *planes, void *diag) { (void)handle; (void)id; (void)planes; (void)diag; return -1; }
__attribute__((visibility("default"))) int32_t s2a_avc_destroy(void *handle, void *diag) { (void)handle; (void)diag; return 0; }
__attribute__((visibility("default"))) const char *s2a_avc_provenance(void) { return "ohos-unavailable"; }
__attribute__((visibility("default"))) int s2a_android_copy_asset(const char *asset, const char *target) { (void)asset; (void)target; return -1; }
