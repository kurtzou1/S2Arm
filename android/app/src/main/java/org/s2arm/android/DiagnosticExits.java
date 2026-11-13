// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.util.Map;
import java.util.TreeMap;

/**
 * #528 item 15: the system's record of how this app's processes ended (ApplicationExitInfo, API 30+),
 * as manifest data, the Android counterpart of the MetricKit crash / hang / exit records in the iOS
 * bundle. It answers "did the game crash, run out of memory, or get killed?" for a session whose log
 * just stops. Pure Java: DiagnosticExport copies the fields out of ApplicationExitInfo; the writer
 * redacts every string.
 */
final class DiagnosticExits {
    static final int MAX_RECORDS = 16;
    static final int MAX_DESCRIPTION = 300;
    // ApplicationExitInfo.REASON_* in value order (android-36 android.jar: UNKNOWN 0 … PACKAGE_UPDATED 16).
    private static final String[] REASONS = {
        "unknown", "exit_self", "signaled", "low_memory", "crash", "crash_native", "anr", "initialization_failure",
        "permission_change", "excessive_resource_usage", "user_requested", "user_stopped", "dependency_died", "other",
        "freezer", "package_state_change", "package_updated"};

    private DiagnosticExits() {}

    static String reason(int code) {
        return code >= 0 && code < REASONS.length ? REASONS[code] : "reason_" + code;
    }

    /** One exit. status is the exit code, or the signal number for a signaled / native-crash exit. */
    static Map<String, Object> record(long timestamp, String process, int reason, int status, int importance,
                                      long pssKb, long rssKb, String description) {
        Map<String, Object> r = new TreeMap<>();
        r.put("time", DiagnosticBundleWriter.iso(timestamp));
        r.put("process", process == null ? "" : process);
        r.put("reason", reason(reason));
        r.put("reason_code", (long) reason);
        r.put("status", (long) status);
        r.put("importance", (long) importance);
        r.put("pss_kb", pssKb);
        r.put("rss_kb", rssKb);
        r.put("description", description == null ? "" : description);   // cut to MAX_DESCRIPTION after redaction, by the writer
        return r;
    }
}
