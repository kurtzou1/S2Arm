// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import java.util.List;

/**
 * #528 item 15: the text of the library's "last session ended abnormally" notice (LastSession). The reason comes
 * from the system's exit record of the :game process (ApplicationExitInfo, Android 11+), and only when that record
 * belongs to the marked session. Without one the notice only says that the session ended abnormally; it never guesses.
 * Makes a binder call: not on the main thread.
 */
final class LastSessionNotice {
    private LastSessionNotice() {}

    static String text(Context context, long markedAt) {
        String reason = reason(context, markedAt);
        return reason == null ? context.getString(R.string.last_session_abnormal)
                              : context.getString(R.string.last_session_abnormal_reason, reason);
    }

    private static String reason(Context context, long markedAt) {
        List<ApplicationExitInfo> exits;
        try {
            ActivityManager am = context.getSystemService(ActivityManager.class);
            if (am == null) return null;
            exits = am.getHistoricalProcessExitReasons(context.getPackageName(), 0, DiagnosticExits.MAX_RECORDS);
        } catch (RuntimeException unavailable) {
            return null;
        }
        String[] processes = new String[exits.size()];
        long[] timestamps = new long[exits.size()];
        for (int i = 0; i < exits.size(); i++) {
            processes[i] = exits.get(i).getProcessName();
            timestamps[i] = exits.get(i).getTimestamp();
        }
        int found = LastSession.pick(context.getPackageName() + ":game", markedAt, processes, timestamps);
        if (found < 0) return null;
        ApplicationExitInfo exit = exits.get(found);
        switch (LastSession.kind(exit.getReason())) {
            case LastSession.CRASH: return context.getString(R.string.last_session_crash);
            case LastSession.NATIVE_CRASH: return context.getString(R.string.last_session_native_crash, exit.getStatus());
            case LastSession.NOT_RESPONDING: return context.getString(R.string.last_session_not_responding);
            case LastSession.LOW_MEMORY: return context.getString(R.string.last_session_low_memory);
            case LastSession.SIGNALED: return context.getString(R.string.last_session_signaled, exit.getStatus());
            case LastSession.EXCESSIVE_RESOURCES: return context.getString(R.string.last_session_excessive);
            default: return null;
        }
    }
}
