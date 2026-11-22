/* capprobe.h — GS + occlusion-query runtime capability probe (#1456).
 *
 * The probe arms run one-per-spawned-helper-process (a GS draw inside an
 * open occlusion query can return VK_ERROR_DEVICE_LOST; the failure must
 * not happen inside the game process's Vulkan device). The helper is the
 * standalone capprobe executable built from capprobe.c with
 * S2A_CAPPROBE_STANDALONE: packaged into the APK as
 * lib/<abi>/libs2a_capprobe.so (jniLibs source directory — AGP packages
 * only shared libraries, so the executable borrows the lib*.so name),
 * stored uncompressed and page-aligned inside the APK and run through the
 * system linker: posix_spawn("/system/bin/linker64", {linker64,
 * "<sourceDir>!/lib/arm64-v8a/libs2a_capprobe.so", ...}) — the exec target
 * is a system file, and bionic maps an apk!/ library like any other .so
 * (Android 10+; #1482: files/ exec is banned on targetSdk ≥29, and the
 * nativeLibraryDir route required package-wide extractNativeLibs) —
 * never fork()+in-process code, which deadlocks on locks inherited held
 * from the ART process's other threads. The Java CapProbe class owns the
 * decision contract and the files/capprobe/<hash>.json cache; this header
 * is the native side's small interface to both.
 *
 * Threading: s2a_capprobe_run blocks its caller for up to the timeout;
 * it is invoked from the game-start worker before any device exists. */
#ifndef S2A_ANDROID_CAPPROBE_H
#define S2A_ANDROID_CAPPROBE_H

#ifdef __cplusplus
extern "C" {
#endif

/* capprobe_host.c — posix_spawn the packaged helper, redirect its stdout
 * into a pipe (stderr goes to a second pipe kept as a bounded tail),
 * wait up to timeout_ms, and return the collected line (malloc'd).
 * Timeout, signal, or missing output produce a synthesized
 * arm/fingerprint line (outcome timeout / crashed / error), never NULL.
 * The helper spec comes from S2A_CAPPROBE_HELPER (set from
 * NativeBridge.configureCapProbe's helperPath argument — the
 * "<apk>!/lib/<abi>/libs2a_capprobe.so" in-APK path); unset means the
 * probe cannot run — an error line, which the contract reads safely. */
char *s2a_capprobe_run(const char *arm, unsigned timeout_ms);

/* capprobe_host.c — diagnostics for the most recent s2a_capprobe_run:
 * the child's wait status (exit:N / signal:S / timeout_ms:N) and a
 * bounded tail of its stderr, flattened to one line. Also emitted to
 * logcat (Android) or stderr (host) by the runner itself — an app
 * process's own fd 2 is /dev/null, so a helper that failed after spawn
 * would otherwise leave no reason anywhere (#1482). The probe path is
 * serialized, so the buffer is a single static string, valid until the
 * next run. */
const char *s2a_capprobe_last_diag(void);

/* Verdict read by the native direct GS-path decision (gs_path.c via
 * s2a_vk_gs_path): reads getenv("S2A_CAPPROBE_RESULT")'s result file
 * and renders it as a short static string — "<source>:<verdict>"
 * (e.g. "probe:supported", "known-bad:unsupported",
 * "legacy-runtime-lost:inconclusive" for old runtime writebacks) — or a
 * fixed token when no verdict can
 * be read: "no-result" (variable unset), "unreadable" (file missing),
 * "malformed" (no gs_occlusion field). Anything that does not end in
 * ":supported" keeps the capability off.
 * Weak: host link units that do not link this provider see a NULL
 * symbol — "not established" — which is the same safe direction as an
 * absent result file. */
const char *s2a_capprobe_gs_occ_state(void) __attribute__((weak));

/* bridge.cpp — called from run_common before graphics selection/device
 * creation: delegates to Java CapProbe.ensure (fingerprint -> cached or
 * fresh verdict file -> publishes S2A_CAPPROBE_RESULT). No-ops when the
 * host did not configure a probe directory this launch. */
int s2a_capprobe_ensure(void);

/* bridge.cpp — legacy entry point used by the generic Vulkan frontend.
 * Strong export required by the game core-link audit and the managed ABI.
 * CapProbe.ensure re-evaluates records from this entry point. */
void s2a_capprobe_runtime_lost(void);

#ifdef __cplusplus
}
#endif
#endif /* S2A_ANDROID_CAPPROBE_H */
