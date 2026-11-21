package org.s2arm.android;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import java.io.File;
import java.nio.file.Files;

/** Uses an already installed, privately imported real revision. No fixture backend or native bypass. */
public final class GameSessionLifecycleInstrumentation extends Instrumentation {
    private Bundle arguments;
    private int checks;
    private ProcessBirth activeBirth;
    @Override public void onCreate(Bundle args) { super.onCreate(args); arguments = args; start(); }
    private void check(boolean ok, String why) { checks++; if (!ok) throw new AssertionError(why); }
    private int gamePid(Context context) {
        var processes = context.getSystemService(ActivityManager.class).getRunningAppProcesses();
        if (processes != null) for (var process : processes)
            if ((context.getPackageName() + ":game").equals(process.processName)) return process.pid;
        return 0;
    }
    interface Condition { boolean ready() throws Exception; }
    private void await(Condition condition, String why) throws Exception {
        long end = SystemClock.elapsedRealtime() + 90000;
        while (SystemClock.elapsedRealtime() < end) {
            if (condition.ready()) { check(true, why); return; }
            SystemClock.sleep(50);
        }
        throw new AssertionError("Timed out: " + why);
    }
    private void awaitLive(Context context, int pid, Condition condition, String why) throws Exception {
        await(() -> {
            if (gamePid(context) != pid) throw new AssertionError(why + ": admitted PID " + pid + " died; current-birth exit evidence pending");
            if (activeBirth == null || startTicks(pid) != activeBirth.startTicks)
                throw new AssertionError(why + ": PID was reused by another process birth");
            return condition.ready();
        }, why);
    }
    private long startTicks(int pid) throws Exception {
        return ProcessBirth.startTicks(new String(Files.readAllBytes(new File("/proc/" + pid + "/stat").toPath()),
            java.nio.charset.StandardCharsets.UTF_8),pid);
    }
    private java.util.List<SessionExitEvidence.Exit> exitRecords(Context context, int pid) {
        java.util.List<SessionExitEvidence.Exit> records = new java.util.ArrayList<>();
        for (ApplicationExitInfo entry : context.getSystemService(ActivityManager.class)
                .getHistoricalProcessExitReasons(context.getPackageName(),pid,0))
            records.add(new SessionExitEvidence.Exit(entry.getPid(),entry.getTimestamp(),entry.getProcessName(),
                entry.getProcessStateSummary(),entry.getReason(),entry.getStatus()));
        return records;
    }
    private void phase(Context context, int pid, String event) throws Exception {
        Files.write(new File(context.getCacheDir(), "game-lifecycle-test.tsv").toPath(),
            (SystemClock.elapsedRealtime() + "\t" + pid + "\t" + event + "\n").getBytes(java.nio.charset.StandardCharsets.UTF_8),
            java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
    }
    private String receipt(Context context, int pid) throws Exception {
        File file = new File(context.getCacheDir(), "game-lifecycle-" + pid + ".tsv");
        return file.isFile() ? new String(Files.readAllBytes(file.toPath()), java.nio.charset.StandardCharsets.UTF_8) : "";
    }
    private void openLibrary(Context context) {
        context.startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .setClass(context, LibraryActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(GameActivity.LIFECYCLE_TEST_EXTRA, true));
    }
    private void play(String title) throws Exception {
        await(() -> {
            android.view.accessibility.AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
            return root != null && clickPlay(root, title);
        }, "real Library Play accessibility action is clicked");
    }
    private boolean clickPlay(android.view.accessibility.AccessibilityNodeInfo node, String title) {
        if (node.isClickable() && node.getText() != null && node.getText().toString().endsWith(" [" + title + "]"))
            return node.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK);
        for (int i = 0; i < node.getChildCount(); i++) {
            android.view.accessibility.AccessibilityNodeInfo child = node.getChild(i);
            if (child != null && clickPlay(child, title)) return true;
        }
        return false;
    }
    private long presents(Context context, int pid) throws Exception {
        long latest = 0;
        for (String line : receipt(context,pid).split("\n")) {
            int at = line.indexOf("\tpresented ");
            if (at >= 0) latest = Long.parseLong(line.substring(at + 11));
        }
        return latest;
    }
    private void backgroundAndResume(Context context, int pid, String title, String phase, boolean home) throws Exception {
        long detached = receipt(context,pid).lines().filter(s -> s.contains("\tsurface-detached Surface generation ")).count();
        long offers = receipt(context,pid).lines().filter(s -> s.endsWith("\tsurface-offered")).count();
        phase(context,pid,phase + " background-request presents=" + presents(context,pid));
        if (home) {
            long now = SystemClock.uptimeMillis();
            check(getUiAutomation().injectInputEvent(new android.view.KeyEvent(now,now,android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.KEYCODE_HOME,0),true), phase + ": HOME key down injected");
            check(getUiAutomation().injectInputEvent(new android.view.KeyEvent(now,SystemClock.uptimeMillis(),android.view.KeyEvent.ACTION_UP,
                android.view.KeyEvent.KEYCODE_HOME,0),true), phase + ": HOME key up injected");
        }
        else openLibrary(context);
        awaitLive(context,pid,() -> receipt(context,pid).lines().filter(s -> s.contains("\tsurface-detached Surface generation ")).count() > detached,
            phase + ": background surface retired");
        phase(context,pid,phase + " detached");
        // A legitimate user can remain in the library while the native startup worker is pending.
        SystemClock.sleep(1000);
        check(gamePid(context) == pid, phase + ": background keeps the admitted PID alive");
        if (home) openLibrary(context);
        play(title);
        awaitLive(context,pid,() -> receipt(context,pid).lines().filter(s -> s.endsWith("\tsurface-offered")).count() > offers,
            phase + ": foreground supplies a new surface generation");
        check(gamePid(context) == pid, phase + ": Library Play resumes the same live PID");
        phase(context,pid,phase + " new-generation");
    }
    @Override public void onStart() {
        Bundle result = new Bundle(); Context context = getTargetContext();
        int activePid = 0;
        try {
            // minSdk 34 起步：getHistoricalProcessExitReasons（API 30+）恒可用
            String title = arguments.getString("titleId");
            check(title != null && title.matches("[0-9A-F]{16}"), "titleId argument required");
            check(gamePid(context) == 0, "no previous game process");
            File apk = new File(context.getApplicationInfo().sourceDir);
            String apkBefore = RuntimeLibrary.sha256(apk);
            long updateBefore = context.getPackageManager().getPackageInfo(context.getPackageName(),0).lastUpdateTime;
            int previousPid = 0;
            for (int round = 0; round < 2; round++) {
                openLibrary(context);
                play(title);
                await(() -> gamePid(context) != 0, "independent :game process starts");
                final int pid = gamePid(context); activePid = pid;
                check(pid != android.os.Process.myPid() && pid != previousPid, "each session has a fresh independent PID");
                final long ticks = startTicks(pid);
                await(() -> {
                    try {
                        ProcessBirth birth = ProcessBirth.parse(new String(Files.readAllBytes(new File(context.getCacheDir(),
                            "game-process-" + pid + ".json").toPath()),java.nio.charset.StandardCharsets.UTF_8));
                        if (birth.pid != pid || birth.startTicks != ticks) return false;
                        activeBirth = birth; return true;
                    } catch (java.io.IOException | IllegalArgumentException error) { return false; }
                }, "current PID/startticks birth receipt published with exit summary");
                final ProcessBirth birth = activeBirth;
                phase(context,pid,"observed-birth " + birth.json());
                await(() -> receipt(context,pid).contains("\tstarted\n"), "native worker accepted; guest readiness is separate");
                backgroundAndResume(context,pid,title,"cold startup",false);
                awaitLive(context,pid,() -> presents(context,pid) > 0, "real present after cold-start resume");
                awaitLive(context,pid,() -> presents(context,pid) >= 30, "steady-state real presents before background");
                for (int cycle = 0; cycle < 3; cycle++) {
                    backgroundAndResume(context,pid,title,"running guest " + cycle,cycle == 1);
                    // Sample after the new offer: a queued frame from before background is insufficient.
                    long before = presents(context,pid);
                    awaitLive(context,pid,() -> presents(context,pid) > before, "new real present after steady-state resume");
                    phase(context,pid,"running guest " + cycle + " presented=" + presents(context,pid));
                }
                check(receipt(context,pid).lines().filter(s -> s.endsWith("\tstarted")).count() == 1, "surface replacement does not start a second guest");
                context.startActivity(GameActivity.launch(context,new Intent().putExtra("s2arm.finish",true),title));
                await(() -> gamePid(context) == 0, "old game process exits before the next session"); activePid = 0;
                File evidence = SessionLogEvidence.capture(context.getFilesDir(),context.getCacheDir(),
                    new File(context.getCacheDir(),"boot-spec-" + title + ".json"),birth);
                result.putString("hostEvidence",result.getString("hostEvidence","") + evidence.getAbsolutePath() + "\n");
                phase(context,pid,"persisted-host-evidence " + evidence.getAbsolutePath());
                final SessionExitEvidence.Exit[] selected = new SessionExitEvidence.Exit[1];
                await(() -> {
                    selected[0] = SessionExitEvidence.select(birth,context.getPackageName() + ":game",exitRecords(context,pid));
                    return selected[0] != null;
                }, "exit record for current PID/startticks/time/summary, after asynchronous publication");
                SessionExitEvidence.Exit exit = selected[0];
                phase(context,pid,"current-exit " + birth.json() + " timestamp=" + exit.timestamp + " reason=" + exit.reason + " status=" + exit.status);
                long generation = receipt(context,pid).lines().filter(s -> s.endsWith("\tsurface-offered")).count();
                SessionExitEvidence.requireClean(birth,exit,context.getPackageName() + ":game",
                    SessionLogEvidence.readVerified(evidence,birth),generation);
                check(true,"current-birth EXIT_SELF0 and sealed final-generation WSI/GPU retirement verified");
                previousPid = pid;
            }
            check(apkBefore.equals(RuntimeLibrary.sha256(apk)) && updateBefore == context.getPackageManager()
                .getPackageInfo(context.getPackageName(),0).lastUpdateTime, "two sessions use the same installed APK without reinstall");
            result.putBoolean("passed",true);
            result.putString("stream", "S0 lifecycle: " + checks + " checks PASS; gameplay milestone/visuals require separate evidence\n");
        } catch (Throwable error) {
            result.putBoolean("passed",false); result.putString("stream",android.util.Log.getStackTraceString(error));
        } finally {
            if (activePid != 0) context.startActivity(GameActivity.launch(context,new Intent().putExtra("s2arm.finish",true),arguments.getString("titleId")));
        }
        finish(result.getBoolean("passed") ? android.app.Activity.RESULT_OK : android.app.Activity.RESULT_CANCELED,result);
    }
}
