/* Host test for the GS-path decision + force switch (#1482).
 *
 * Built twice from run_host_tests.sh:
 *   -D__ANDROID__ -DS2A_ANDROID_DEBUG_ENV   "debug build" — both gates live;
 *   -D__ANDROID__                           "release build" — the compile-time
 *                                           gate is dead, so the switch must
 *                                           stay inert whatever the props say.
 * The property table and logcat are stubbed here — the same seam bionic
 * provides on device, so the double gate is exercised for real. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../native/direct/gs_path.h"

static char g_props[32][2][96];
static int g_nprops;
static void prop_set(const char *name, const char *value) {
    for (int i = 0; i < g_nprops; i++)
        if (!strcmp(g_props[i][0], name)) {
            snprintf(g_props[i][1], sizeof g_props[i][1], "%s", value);
            return;
        }
    snprintf(g_props[g_nprops][0], sizeof g_props[0][0], "%s", name);
    snprintf(g_props[g_nprops][1], sizeof g_props[0][1], "%s", value);
    g_nprops++;
}
int __system_property_get(const char *name, char *value) {
    for (int i = 0; i < g_nprops; i++)
        if (!strcmp(g_props[i][0], name)) {
            strcpy(value, g_props[i][1]);
            return (int)strlen(value);
        }
    value[0] = 0;
    return 0;
}

static char g_log[1024];
int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; (void)tag;
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(g_log, sizeof g_log, fmt, ap);
    va_end(ap);
    return n;
}

static int fails;
#define CHECK(cond) do { \
    if (!(cond)) { printf("FAIL %d: %s\n", __LINE__, #cond); fails++; } \
} while (0)

static char g_result_path[4096];
static void write_result(const char *json) {
    const char *tmp = getenv("TMPDIR");
    int n = snprintf(g_result_path, sizeof g_result_path,
                     "%s/gs-path-test-%d.json", tmp && *tmp ? tmp : ".", (int)getpid());
    if (n < 0 || (size_t)n >= sizeof g_result_path) abort();
    FILE *f = fopen(g_result_path, "w");
    if (!f) abort();
    fputs(json, f);
    fclose(f);
    setenv("S2A_CAPPROBE_RESULT", g_result_path, 1);
}

/* Minimal verdict file — the two flat fields the native reader picks
 * out are emitted verbatim by the Java writer. */
#define RESULT(src, verdict) \
    "{\"schema\":1,\"source\":\"" src "\",\"verdict\":{" \
    "\"gs_occlusion\":\"" verdict "\",\"tess_occlusion\":\"unsupported\"}}"

static void expect(const char *tag, int hw, int want_path,
                   const char *want_reason) {
    const char *reason = NULL;
    g_log[0] = 0;
    int got = s2a_vk_gs_path(hw, &reason);
    if (got != want_path || !reason || strcmp(reason, want_reason)) {
        printf("FAIL %s: path %d/%d reason %s/%s\n", tag,
               got, want_path, reason ? reason : "(null)", want_reason);
        fails++;
        return;
    }
    char want_log[160];
    snprintf(want_log, sizeof want_log,
             "graphics GS path: %s reason=%s",
             want_path ? "hardware" : "compute", want_reason);
    if (!strstr(g_log, want_log)) {
        printf("FAIL %s: log \"%s\" missing \"%s\"\n", tag, g_log, want_log);
        fails++;
    }
}

int main(void) {
    /* verdict decides when the switch gate is closed (no debug_env). */
    unsetenv("S2A_CAPPROBE_RESULT");
    expect("no-result", 1, 0, "no-result");

    write_result(RESULT("probe", "supported"));
    expect("probe supported", 1, 1, "probe:supported");
    write_result(RESULT("known-bad", "unsupported"));
    expect("known-bad", 1, 0, "known-bad:unsupported");
    write_result(RESULT("runtime-lost", "unsupported"));
    expect("legacy runtime-lost", 1, 0, "legacy-runtime-lost:inconclusive");
    write_result(RESULT("probe", "inconclusive"));
    expect("inconclusive", 1, 0, "probe:inconclusive");
    write_result("{\"schema\":1}");
    expect("malformed", 1, 0, "malformed");
    write_result(RESULT("probe", "supported"));
    expect("hw-missing", 0, 0, "hw-missing");

    /* gs_path props without the debug_env gate: inert. */
    prop_set("debug.s2a.gs_path", "compute");
    expect("switch gated", 1, 1, "probe:supported");
    prop_set("debug.s2a.gs_path", "garbage");
    prop_set("debug.s2a.debug_env", "1");
    expect("bad value", 1, 1, "probe:supported");

#if defined(S2A_ANDROID_DEBUG_ENV)
    /* debug build + debug_env=1: the switch owns the leg. */
    prop_set("debug.s2a.gs_path", "compute");
    expect("forced compute", 1, 0, "forced-compute");
    write_result(RESULT("probe", "unsupported"));
    prop_set("debug.s2a.gs_path", "hardware");
    expect("forced hardware", 1, 1, "forced-hardware");
    expect("forced hardware hw-missing", 0, 0, "forced-hardware-hw-missing");
#else
    /* release build: both props set and the switch still does nothing —
     * the verdict file keeps deciding. */
    prop_set("debug.s2a.gs_path", "compute");
    expect("release ignores switch", 1, 1, "probe:supported");
#endif

    unlink(g_result_path);
    unsetenv("S2A_CAPPROBE_RESULT");
    if (fails) { printf("gs_path_test: %d failures\n", fails); return 1; }
    printf("gs_path_test: passed\n");
    return 0;
}
