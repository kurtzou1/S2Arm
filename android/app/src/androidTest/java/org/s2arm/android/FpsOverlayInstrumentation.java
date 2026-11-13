// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Handler;
import android.view.View;
import android.view.ViewGroup;
import android.widget.CheckBox;

/** Diagnostic UI only; unavailable native counts are not NVN game evidence. */
public final class FpsOverlayInstrumentation extends Instrumentation {
    private LibraryActivity activity;
    private FrameRateOverlay overlay;
    private int checks;

    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }

    private void check(boolean value, String why) {
        checks++;
        if (!value) throw new AssertionError(why);
    }

    private CheckBox findToggle(View view) {
        if (view instanceof CheckBox) return (CheckBox) view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                CheckBox found = findToggle(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    private CheckBox toggle() {
        CheckBox[] found = new CheckBox[1];
        runOnMainSync(() -> found[0] = findToggle(activity.getWindow().getDecorView()));
        check(found[0] != null, "library offers FPS toggle");
        return found[0];
    }

    private boolean checked() {
        CheckBox box = toggle();
        boolean[] value = new boolean[1];
        runOnMainSync(() -> value[0] = box.isChecked());
        return value[0];
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        SharedPreferences prefs = getTargetContext().getSharedPreferences("display", 0);
        boolean existed = prefs.contains("fps"), original = prefs.getBoolean("fps", false);
        try {
            String pkg = getTargetContext().getPackageName();
            check(pkg.equals("org.s2arm.android") || pkg.equals("org.s2arm.android.w2"), "diagnostic APK only");
            check(prefs.edit().remove("fps").commit(), "remove only FPS preference");
            activity = (LibraryActivity) startActivitySync(new Intent(getTargetContext(), LibraryActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            waitForIdleSync();
            check(!checked(), "default disabled");
            check(!prefs.contains("fps"), "initialization does not write absent preference");
            CheckBox box = toggle();
            runOnMainSync(box::performClick);
            check(prefs.getBoolean("fps", false), "click immediately saves enabled");
            ActivityMonitor monitor = addMonitor(LibraryActivity.class.getName(), null, false);
            LibraryActivity previous = activity;
            runOnMainSync(previous::recreate);
            Activity next = monitor.waitForActivityWithTimeout(10000);
            removeMonitor(monitor);
            check(next instanceof LibraryActivity && next != previous, "library recreated");
            activity = (LibraryActivity) next;
            waitForIdleSync();
            check(checked(), "recreation retains enabled");
            runOnMainSync(() -> callActivityOnPause(activity));
            check(prefs.edit().putBoolean("fps", false).commit(), "external preference updated");
            runOnMainSync(() -> callActivityOnResume(activity));
            check(!checked(), "return synchronizes external preference");
            check(NativeBridge.loaded() == null, "library never loads native runtime");
            MainActivity diagnostic = (MainActivity) startActivitySync(new Intent(getTargetContext(), MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            waitForIdleSync();
            runOnMainSync(diagnostic::finish);
            waitForIdleSync();
            runOnMainSync(() -> {
                overlay = new FrameRateOverlay(activity);
                ((ViewGroup) activity.findViewById(android.R.id.content)).addView(overlay);
                overlay.setEnabledForGame(true);
                overlay.setResumed(true);
                check("FPS —".contentEquals(overlay.getText()), "first sample unavailable");
            });
            waitForIdleSync();
            runOnMainSync(() -> check("FPS —".contentEquals(overlay.getText()), "diagnostic count remains unavailable"));
            java.lang.reflect.Field handlerField = FrameRateOverlay.class.getDeclaredField("handler");
            java.lang.reflect.Field tickField = FrameRateOverlay.class.getDeclaredField("tick");
            handlerField.setAccessible(true); tickField.setAccessible(true);
            Handler handler = (Handler) handlerField.get(overlay);
            Runnable tick = (Runnable) tickField.get(overlay);
            runOnMainSync(() -> {
                check(handler.hasCallbacks(tick), "enabled overlay schedules refresh");
                overlay.setResumed(false);
                check(!handler.hasCallbacks(tick), "pause removes refresh");
                check("FPS —".contentEquals(overlay.getText()), "pause clears old value");
                overlay.setResumed(true);
                check("FPS —".contentEquals(overlay.getText()), "resume resets sample");
                overlay.setEnabledForGame(false);
                check(overlay.getVisibility() == View.GONE, "disabled overlay hidden");
                check(!handler.hasCallbacks(tick), "disabled overlay removes refresh");
            });
            result.putBoolean("passed", true);
            result.putString("stream", "FPS HUD: " + checks + " checks passed; diagnostic UI only; NVN game untested\n");
        } catch (Throwable error) {
            result.putBoolean("passed", false);
            result.putString("stream", android.util.Log.getStackTraceString(error));
        } finally {
            if (activity != null) runOnMainSync(() -> {
                if (overlay != null) overlay.setResumed(false);
                activity.finish();
            });
            SharedPreferences.Editor restore = prefs.edit();
            if (existed) restore.putBoolean("fps", original); else restore.remove("fps");
            if (!restore.commit()) {
                result.putBoolean("passed", false);
                result.putString("stream", result.getString("stream", "") + "FPS preference restore failed\n");
            }
        }
        finish(result.getBoolean("passed") ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
    }
}
