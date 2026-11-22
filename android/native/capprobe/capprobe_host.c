/* capprobe_host.c — native orchestration helpers for the GS+occlusion
 * capability probe (#1456). The Java CapProbe class owns the decision
 * contract and the result-file cache; this file provides the one process
 * per arm isolation the contract requires plus the result-file reader the
 * native direct device path consumes.
 *
 * s2a_capprobe_run posix_spawns the standalone capprobe helper for exactly
 * one arm — through the system dynamic linker: the exec target is
 * /system/bin/linker64 and its first argument is the helper's in-APK spec
 * "<sourceDir>!/lib/arm64-v8a/libs2a_capprobe.so". Bionic (Android 10+)
 * runs executables that way and maps an apk!/ library in place like any
 * other .so, so the exec lands on a system file an untrusted_app may
 * always run while the helper never leaves the package (#1482: files/
 * app_data_file exec fails on targetSdk ≥29; the nativeLibraryDir route
 * worked but needed package-wide extractNativeLibs). The STORED +
 * 16 KB page alignment verify-apk.py enforces is the precondition that
 * makes the !/ mapping possible. The Java side hands us the spec via
 * S2A_CAPPROBE_HELPER (see MainActivity.configureCapProbe). Spawning an
 * independent executable — rather than fork+in-process run — is what the
 * contract needs: a forked child of the ART process keeps only the
 * calling thread, so locks held by the other threads (malloc, dynamic
 * loader, ART internals) stay held forever and the child's
 * vkCreateInstance can deadlock into a silent timeout that reads as
 * inconclusive twice -> unsupported.
 * The helper's stdout is redirected into a pipe the parent drains with a
 * deadline; its stderr goes to a second pipe kept as a bounded tail. A
 * silent wedge is a timeout, a signal is a crash, and both come back as
 * synthesized contract lines the Java side parses like any other arm
 * output; the wait status and the stderr tail also travel in the line's
 * "detail" field and in a per-run diag string, because "fingerprint
 * unavailable" without the helper's own error is undiagnosable (#1482). */
#include "capprobe.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if (defined(__ANDROID__) || defined(__OHOS__))
#include <android/log.h>
#define S2A_DIAG_WARN(...) \
    __android_log_print(ANDROID_LOG_WARN, "S2Arm", __VA_ARGS__)
#define S2A_DIAG_INFO(...) \
    __android_log_print(ANDROID_LOG_INFO, "S2Arm", __VA_ARGS__)
#else
#define S2A_DIAG_WARN(...) fprintf(stderr, __VA_ARGS__)
#define S2A_DIAG_INFO(...) fprintf(stderr, __VA_ARGS__)
#endif

extern char **environ;

/* Diagnostics for the last s2a_capprobe_run on this thread's serialized
 * probe path: child wait status plus a bounded helper-stderr tail,
 * flattened to one line. Kept separate from the contract line so a valid
 * helper line is never mutated; s2a_capprobe_last_diag exposes it to
 * host tests while the same text is emitted to logcat on Android. */
static char g_last_diag[4096];

const char *s2a_capprobe_last_diag(void) { return g_last_diag; }

/* JSON-escape src into dst for embedding inside a contract-line string
 * value: quotes and backslashes are escaped, newlines become \n, and
 * control/non-ASCII bytes blank out. */
static size_t json_escape(char *dst, size_t cap, const char *src, size_t n) {
    size_t w = 0;
    for (size_t i = 0; i < n && w + 2 < cap; i++) {
        unsigned char c = (unsigned char) src[i];
        if (c == '"' || c == '\\') {
            if (w + 3 >= cap) break;
            dst[w++] = '\\';
            dst[w++] = (char) c;
        } else if (c == '\n') {
            if (w + 3 >= cap) break;
            dst[w++] = '\\';
            dst[w++] = 'n';
        } else if (c >= 0x20 && c < 0x7f) {
            dst[w++] = (char) c;
        } else {
            dst[w++] = ' ';
        }
    }
    dst[w] = 0;
    return w;
}

/* Record + emit the per-run diagnostic: wait status plus a bounded
 * stderr tail flattened to one line for logcat. */
static void set_diag(const char *arm, const char *status,
                     const char *errbuf, size_t err_len, int warn_level) {
    char flat[1537];
    size_t tail = err_len > 1400 ? 1400 : err_len;
    const char *src = errbuf + err_len - tail;
    size_t w = 0;
    for (size_t i = 0; i < tail && w + 1 < sizeof flat; i++) {
        unsigned char c = (unsigned char) src[i];
        flat[w++] = (c < 0x20 || c == 0x7f) ? ' ' : (char) c;
    }
    flat[w] = 0;
    if (snprintf(g_last_diag, sizeof g_last_diag,
                 "capprobe %s: status=%s stderr=\"%s\"",
                 arm, status, flat) < 0)
        g_last_diag[0] = 0;
    if (warn_level) S2A_DIAG_WARN("%s\n", g_last_diag);
    else S2A_DIAG_INFO("%s\n", g_last_diag);
}

/* Compose the "detail" payload carried by a synthesized contract line:
 * the wait status plus a short stderr tail, so the reason survives into
 * the Java warn that logs the line. */
static void build_detail(char *out, size_t cap, const char *status,
                         const char *errbuf, size_t err_len) {
    size_t pos = (size_t) snprintf(out, cap, "%s", status);
    size_t tail = err_len > 160 ? 160 : err_len;
    if (tail && pos < cap) {
        char esc[201];
        json_escape(esc, sizeof esc, errbuf + err_len - tail, tail);
        snprintf(out + pos, cap - pos, " stderr=\"%s\"", esc);
    }
}

static char *synthetic_line(const char *arm, const char *outcome,
                            const char *stage, const char *reason,
                            const char *detail) {
    char buf[1536];
    if (!strcmp(arm, "fingerprint"))
        snprintf(buf, sizeof buf,
                 "{\"type\":\"fingerprint\",\"error\":\"%s\"%s%s%s}",
                 outcome, detail ? ",\"detail\":\"" : "",
                 detail ? detail : "", detail ? "\"" : "");
    else
        snprintf(buf, sizeof buf,
                 "{\"type\":\"arm\",\"arm\":\"%s\",\"outcome\":\"%s\","
                 "\"vk_result\":null,\"samples\":null,\"elapsed_ms\":0,"
                 "\"stage\":\"%s\",\"reason\":\"%s\"%s%s%s}",
                 arm, outcome, stage, reason,
                 detail ? ",\"detail\":\"" : "",
                 detail ? detail : "", detail ? "\"" : "");
    return strdup(buf);
}

static long long mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

char *s2a_capprobe_run(const char *arm, unsigned timeout_ms) {
    /* In-APK spec of the packaged helper — "<apk>!/lib/<abi>/
     * libs2a_capprobe.so" — resolved by the Java side before the first
     * probe run. */
    const char *helper = getenv("S2A_CAPPROBE_HELPER");
    g_last_diag[0] = 0;
    if (!helper || !*helper) {
        snprintf(g_last_diag, sizeof g_last_diag,
                 "capprobe %s: helper-unset", arm);
        S2A_DIAG_WARN("%s\n", g_last_diag);
        return synthetic_line(arm, "error", "host", "helper-unset", NULL);
    }
    int fds[2] = {-1, -1};
    int efds[2] = {-1, -1};
    if (pipe(fds) != 0 || pipe(efds) != 0) {
        if (fds[0] >= 0) { close(fds[0]); close(fds[1]); }
        if (efds[0] >= 0) { close(efds[0]); close(efds[1]); }
        return synthetic_line(arm, "error", "host", "pipe-failed", NULL);
    }
    posix_spawn_file_actions_t actions;
    int a_rc = posix_spawn_file_actions_init(&actions);
    if (a_rc != 0) {
        close(fds[0]);
        close(fds[1]);
        close(efds[0]);
        close(efds[1]);
        return synthetic_line(arm, "error", "host", "spawn-actions-failed", NULL);
    }
    /* Contract output goes to fds[1]; helper stderr goes to efds[1].
     * Nothing else may write the contract pipe, and stderr must never
     * inherit the app fd — an ART process's stderr is /dev/null, which is
     * exactly how the helper's real failure was being lost (#1482). */
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, efds[0]);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, efds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    posix_spawn_file_actions_addclose(&actions, efds[1]);
    /* The exec target is the system dynamic linker; it loads the helper
     * from the "<apk>!/<entry>" spec like any mapped library — the spawned
     * file is a system binary, which is exactly what the sandbox allows.
     * S2A_CAPPROBE_LINKER overrides the linker path for host tests, where
     * /system/bin/linker64 does not exist. */
    const char *linker = getenv("S2A_CAPPROBE_LINKER");
    if (!linker || !*linker) linker = "/system/bin/linker64";
    const char *linker_name = strrchr(linker, '/');
    linker_name = linker_name ? linker_name + 1 : linker;
    int is_fingerprint = !strcmp(arm, "fingerprint");
    char *const argv[] = {(char *) linker_name,
                          (char *) helper,
                          is_fingerprint ? (char *) "fingerprint" : (char *) "arm",
                          is_fingerprint ? NULL : (char *) arm, NULL};
    pid_t pid = -1;
    int sp_rc = posix_spawn(&pid, linker, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    close(efds[1]);
    if (sp_rc != 0) {
        close(fds[0]);
        close(efds[0]);
        char d[64];
        snprintf(d, sizeof d, "spawn_rc:%d", sp_rc);
        snprintf(g_last_diag, sizeof g_last_diag,
                 "capprobe %s: spawn-failed rc=%d", arm, sp_rc);
        S2A_DIAG_WARN("%s\n", g_last_diag);
        return synthetic_line(arm, "error", "host", "spawn-failed", d);
    }
    char buf[4096];
    size_t len = 0;
    /* Bounded stderr tail: when a helper complains and dies the reason is
     * at the end, so the ring keeps the last bytes. */
    char errbuf[2048];
    size_t err_len = 0;
    int out_open = 1, err_open = 1;
    long long deadline = mono_ms() + timeout_ms;
    int timed_out = 0;
    /* Drain both pipes until both ends close or the deadline hits — a
     * helper spamming stderr must not deadlock on a full pipe while the
     * parent waits on stdout. */
    while (out_open || err_open) {
        long long left = deadline - mono_ms();
        if (left <= 0) { timed_out = 1; break; }
        struct pollfd pfds[2];
        int nfd = 0;
        if (out_open) {
            pfds[nfd].fd = fds[0];
            pfds[nfd].events = POLLIN;
            nfd++;
        }
        if (err_open) {
            pfds[nfd].fd = efds[0];
            pfds[nfd].events = POLLIN;
            nfd++;
        }
        int pr = poll(pfds, nfd, (int)left);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) { timed_out = 1; break; }
        for (int i = 0; i < nfd; i++) {
            int is_out = pfds[i].fd == fds[0];
            if (!(pfds[i].revents & (POLLIN | POLLHUP))) {
                if (pfds[i].revents & (POLLERR | POLLNVAL)) {
                    if (is_out) out_open = 0; else err_open = 0;
                }
                continue;
            }
            char tmp[1024];
            ssize_t n = read(pfds[i].fd, tmp, sizeof tmp);
            if (n < 0) {
                if (errno == EINTR) continue;   /* data stays; next poll returns it */
                if (is_out) out_open = 0; else err_open = 0;
                continue;
            }
            if (n == 0) {
                if (is_out) out_open = 0; else err_open = 0;
                continue;
            }
            if (is_out) {
                size_t room = sizeof(buf) - 1 - len;
                size_t take = (size_t)n < room ? (size_t)n : room;
                memcpy(buf + len, tmp, take);
                len += take;
                /* Overflow beyond the buffer is drained and dropped —
                 * the contract line is always the first line. */
            } else {
                if (err_len + (size_t)n > sizeof errbuf) {
                    size_t drop = err_len + (size_t)n - sizeof errbuf;
                    memmove(errbuf, errbuf + drop, err_len - drop);
                    err_len -= drop;
                }
                memcpy(errbuf + err_len, tmp, (size_t)n);
                err_len += (size_t)n;
            }
        }
    }
    close(fds[0]);
    close(efds[0]);
    int status = 0;
    /* Timeout or an unobservable child (abnormal drain break): never
     * wait unbounded. */
    if (timed_out || out_open || err_open) kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
    char status_str[64];
    if (timed_out)
        snprintf(status_str, sizeof status_str, "timeout_ms:%u", timeout_ms);
    else if (WIFSIGNALED(status))
        snprintf(status_str, sizeof status_str, "signal:%d", WTERMSIG(status));
    else if (WIFEXITED(status))
        snprintf(status_str, sizeof status_str, "exit:%d", WEXITSTATUS(status));
    else
        snprintf(status_str, sizeof status_str, "status:0x%x", status);
    char detail[320];
    build_detail(detail, sizeof detail, status_str, errbuf, err_len);
    int failed = timed_out || !WIFEXITED(status) || WEXITSTATUS(status) != 0;
    set_diag(arm, status_str, errbuf, err_len, failed);
    if (timed_out)
        return synthetic_line(arm, "timeout", "host", "killed", detail);
    if (!WIFEXITED(status))
        return is_fingerprint
            ? synthetic_line(arm, "no-exit", "host", "signaled", detail)
            : synthetic_line(arm, "crashed", "child", "signaled", detail);
    buf[len] = 0;
    /* Keep exactly one contract line: stdout only ever carries ours, so
     * trim anything after the first newline defensively. */
    char *nl = strchr(buf, '\n');
    if (nl) *nl = 0;
    if (len == 0 || buf[0] != '{')
        return synthetic_line(arm, "error", "host", "empty-output", detail);
    return strdup(buf);
}

/* Reads the published result file into buf (NUL-terminated). Returns
 * bytes read, -1 when S2A_CAPPROBE_RESULT is unset/empty, -2 when the
 * file cannot be opened. */
static int read_result_file(char *buf, size_t cap) {
    const char *path = getenv("S2A_CAPPROBE_RESULT");
    if (!path || !*path || cap < 2) return -1;
    FILE *f = fopen(path, "r");
    if (!f) return -2;
    size_t n = fread(buf, 1, cap - 1, f);
    fclose(f);
    buf[n] = 0;
    return (int)n;
}

/* Copies the value of "<key>":"<value>" — the Java writer emits these
 * flat fields verbatim — into out ("" when absent or unterminated). */
static void json_field(const char *buf, const char *key,
                       char *out, size_t cap) {
    out[0] = 0;
    const char *p = strstr(buf, key);
    if (!p) return;
    p += strlen(key);
    const char *e = strchr(p, '"');
    if (!e) return;
    size_t n = (size_t)(e - p);
    if (n >= cap) n = cap - 1;
    memcpy(out, p, n);
    out[n] = 0;
}

const char *s2a_capprobe_gs_occ_state(void) {
    static char state[96];
    char buf[8192];
    int n = read_result_file(buf, sizeof buf);
    if (n == -1) return "no-result";
    if (n == -2) return "unreadable";
    char src[32] = "", verdict[32] = "";
    json_field(buf, "\"source\":\"", src, sizeof src);
    json_field(buf, "\"gs_occlusion\":\"", verdict, sizeof verdict);
    if (!verdict[0]) return "malformed";
    if (!strcmp(src, "runtime-lost")) return "legacy-runtime-lost:inconclusive";
    snprintf(state, sizeof state, "%s:%s", src[0] ? src : "unknown", verdict);
    return state;
}
