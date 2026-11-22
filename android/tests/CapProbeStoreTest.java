package org.s2arm.android;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * CapProbe orchestration against an injected runner/publisher: caching,
 * known-bad short-circuit, inconclusive retry/fixation, runtime-lost
 * writeback, and file retention. Plain JDK, temp dirs only.
 */
public final class CapProbeStoreTest {

    private static int failures;

    private static void check(boolean cond, String what) {
        if (!cond) { failures++; System.out.println("FAIL " + what); }
    }

    /** Scripted one-process-per-arm runner; "missing" arms emit nothing.
     *  sleepFpMs / sleepArmMs model a runner that takes real wall time: the
     *  call sleeps at most the granted timeout and answers "timeout" if its
     *  work did not fit, mirroring the native runner's deadline. */
    private static final class FakeRunner implements CapProbe.Runner {
        final Map<String, String> lines = new HashMap<String, String>();
        final List<String> ran = new ArrayList<String>();
        long sleepFpMs;
        long sleepArmMs;
        @Override public String run(String arm, int timeoutMs) {
            ran.add(arm);
            long sleep = "fingerprint".equals(arm) ? sleepFpMs : sleepArmMs;
            if (sleep > 0) {
                try {
                    Thread.sleep(Math.min(sleep, timeoutMs));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
                if (sleep > timeoutMs)
                    return "fingerprint".equals(arm)
                        ? "{\"type\":\"fingerprint\",\"error\":\"timeout\"}"
                        : "{\"type\":\"arm\",\"arm\":\"" + arm
                            + "\",\"outcome\":\"timeout\"}";
            }
            String line = lines.get(arm);
            if (line == null)
                return "{\"type\":\"arm\",\"arm\":\"" + arm
                    + "\",\"outcome\":\"crashed\"}";
            return line;
        }
        void missing(String arm) { lines.put(arm, ""); }
        void armOutcomes(String... pairs) {
            for (int i = 0; i + 1 < pairs.length; i += 2)
                lines.put(pairs[i],
                    "{\"type\":\"arm\",\"arm\":\"" + pairs[i] + "\","
                    + "\"outcome\":\"" + pairs[i + 1] + "\"}");
        }
        int armRuns() {
            int n = 0;
            for (String a : ran) if (!"fingerprint".equals(a)) n++;
            return n;
        }
    }

    private static final class FakePublisher implements CapProbe.Publisher {
        String path;
        @Override public void publish(String resultPath) { path = resultPath; }
    }

    private static String fpLine(long vendor, long driver) {
        return "{\"type\":\"fingerprint\",\"deviceName\":\"GPU\","
            + "\"vendorID\":" + vendor + ",\"deviceID\":1,"
            + "\"driverVersion\":" + driver + ",\"apiVersion\":4198400,"
            + "\"buildFingerprint\":\"x\"}";
    }

    private static File tempDir(String name) throws Exception {
        File dir = new File(System.getProperty("java.io.tmpdir"),
            "capprobe-test-" + name + "-" + System.nanoTime());
        if (!dir.mkdirs()) throw new IllegalStateException("mkdir " + dir);
        return dir;
    }

    private static String allOkBadlist() {
        return "# source: #1456\n0x13b5 134221824\n";
    }

    public static void main(String[] args) throws Exception {
        /* 1. fresh device, all arms ok -> supported file + publish */
        File dir = tempDir("ok");
        FakeRunner runner = new FakeRunner();
        runner.lines.put("fingerprint", fpLine(0x5143, 900));
        runner.armOutcomes("nogsocc", "ok", "noq", "ok", "occ", "ok",
                           "occimp", "ok", "tessocc", "ok");
        FakePublisher pub = new FakePublisher();
        CapProbe.ensure(dir, allOkBadlist(), "1.0", runner, pub);
        check(pub.path != null, "publish called");
        CapProbe.Result r = CapProbe.readResult(new File(pub.path));
        check(r != null && r.gsOcclusion == CapProbeVerdict.Verdict.SUPPORTED
              && r.tessOcclusion == CapProbeVerdict.Verdict.SUPPORTED
              && "probe".equals(r.source), "all ok -> supported probe file");
        check(runner.armRuns() == CapProbeVerdict.ARMS_IN_ORDER.length,
              "all arms ran once");

        /* 2. cached supported verdict -> no re-probe, same file published */
        FakeRunner runner2 = new FakeRunner();
        runner2.lines.put("fingerprint", fpLine(0x5143, 900));
        CapProbe.ensure(dir, allOkBadlist(), "1.0", runner2, pub);
        check(runner2.armRuns() == 0, "cached verdict skips arm runs");

        /* 3. known-bad fingerprint -> unsupported, arms never run */
        File dirKb = tempDir("kb");
        FakeRunner kb = new FakeRunner();
        kb.lines.put("fingerprint", fpLine(0x13b5, 134221824));
        FakePublisher pubKb = new FakePublisher();
        CapProbe.ensure(dirKb, allOkBadlist(), "1.0", kb, pubKb);
        check(kb.armRuns() == 0, "known-bad never probes arms");
        CapProbe.Result rkb = CapProbe.readResult(new File(pubKb.path));
        check(rkb != null && rkb.gsOcclusion == CapProbeVerdict.Verdict.UNSUPPORTED
              && "known-bad".equals(rkb.source), "known-bad file");

        /* 4. risky lost -> unsupported */
        File dirLost = tempDir("lost");
        FakeRunner lost = new FakeRunner();
        lost.lines.put("fingerprint", fpLine(0x5143, 901));
        lost.armOutcomes("nogsocc", "ok", "noq", "ok", "occ", "lost",
                         "occimp", "ok", "tessocc", "ok");
        FakePublisher pubLost = new FakePublisher();
        CapProbe.ensure(dirLost, "", "1.0", lost, pubLost);
        CapProbe.Result rl = CapProbe.readResult(new File(pubLost.path));
        check(rl != null && rl.gsOcclusion == CapProbeVerdict.Verdict.UNSUPPORTED
              && "probe".equals(rl.source), "occ lost -> unsupported");
        check(rl.tessOcclusion == CapProbeVerdict.Verdict.SUPPORTED,
              "occ lost keeps tess supported");

        /* 5/6. inconclusive -> retried once -> fixed unsupported */
        File dirInc = tempDir("inc");
        FakeRunner inc = new FakeRunner();
        inc.lines.put("fingerprint", fpLine(0x5143, 902));
        inc.armOutcomes("nogsocc", "ok", "noq", "ok", "occimp", "ok",
                        "tessocc", "ok");
        inc.missing("occ");   // risky arm produces no line -> inconclusive
        FakePublisher pubInc = new FakePublisher();
        CapProbe.ensure(dirInc, "", "1.0", inc, pubInc);
        CapProbe.Result ri1 = CapProbe.readResult(new File(pubInc.path));
        check(ri1 != null && ri1.gsOcclusion == CapProbeVerdict.Verdict.INCONCLUSIVE
              && ri1.inconclusiveCount == 1 && "probe".equals(ri1.source),
              "first inconclusive stored as retryable");
        CapProbe.ensure(dirInc, "", "1.0", inc, pubInc);
        CapProbe.Result ri2 = CapProbe.readResult(new File(pubInc.path));
        check(ri2 != null && ri2.gsOcclusion == CapProbeVerdict.Verdict.UNSUPPORTED
              && "inconclusive-twice".equals(ri2.source),
              "second inconclusive fixes unsupported");

        /* 7. fixed verdict never re-probes */
        FakeRunner inc3 = new FakeRunner();
        inc3.lines.put("fingerprint", fpLine(0x5143, 902));
        CapProbe.ensure(dirInc, "", "1.0", inc3, pubInc);
        check(inc3.armRuns() == 0, "fixed inconclusive-twice not re-probed");

        /* 8. runtime-lost writeback flips only this fingerprint's file.
         * Negative control: if markRuntimeLost is stubbed out or dropped,
         * the file stays "supported" and this assertion fails — the test
         * cannot pass without the real writeback path. */
        File dirLostWb = tempDir("rl");
        FakeRunner wb = new FakeRunner();
        wb.lines.put("fingerprint", fpLine(0x5143, 903));
        wb.armOutcomes("nogsocc", "ok", "noq", "ok", "occ", "ok",
                       "occimp", "ok", "tessocc", "ok");
        FakePublisher pubWb = new FakePublisher();
        CapProbe.ensure(dirLostWb, "", "1.0", wb, pubWb);
        File supportedFile = new File(pubWb.path);
        CapProbe.Result before = CapProbe.readResult(supportedFile);
        check(before != null && before.gsOcclusion
                  == CapProbeVerdict.Verdict.SUPPORTED,
              "runtime-lost precondition: supported");
        CapProbe.markRuntimeLost(pubWb.path);
        CapProbe.Result after = CapProbe.readResult(supportedFile);
        check(after != null && after.gsOcclusion
                  == CapProbeVerdict.Verdict.UNSUPPORTED
              && "runtime-lost".equals(after.source)
              && after.fingerprint.vendorID == 0x5143
              && "GPU".equals(after.fingerprint.deviceName)
              && after.fingerprint.driverVersion == 903,
              "runtime-lost writeback rewrites the same fingerprint file");
        check(after.tessOcclusion == CapProbeVerdict.Verdict.SUPPORTED,
              "runtime-lost keeps the unrelated tess verdict");
        FakeRunner reprobe = new FakeRunner();
        reprobe.lines.putAll(wb.lines);
        FakePublisher republished = new FakePublisher();
        CapProbe.ensure(dirLostWb, "", "1.1", reprobe, republished);
        CapProbe.Result refreshed = CapProbe.readResult(supportedFile);
        check(reprobe.armRuns() == CapProbeVerdict.ARMS_IN_ORDER.length
              && supportedFile.getAbsolutePath().equals(republished.path)
              && refreshed != null && refreshed.gsOcclusion == CapProbeVerdict.Verdict.SUPPORTED
              && "probe".equals(refreshed.source),
              "legacy runtime-lost verdict must be re-probed: arms=" + reprobe.armRuns()
              + " source=" + (refreshed == null ? "missing" : refreshed.source));

        /* 9. retention: beyond RETAIN only the newest files stay */
        File dirMany = tempDir("retain");
        for (int i = 0; i < CapProbe.RETAIN + 3; i++) {
            FakeRunner many = new FakeRunner();
            many.lines.put("fingerprint", fpLine(0x5143, 1000 + i));
            many.armOutcomes("nogsocc", "ok", "noq", "ok", "occ", "ok",
                             "occimp", "ok", "tessocc", "ok");
            FakePublisher pm = new FakePublisher();
            CapProbe.ensure(dirMany, "", "1.0", many, pm);
            Thread.sleep(2);   // distinct mtimes for deterministic pruning
        }
        File[] left = dirMany.listFiles();
        int jsonCount = 0;
        for (File f : left) if (f.getName().endsWith(".json")) jsonCount++;
        check(jsonCount <= CapProbe.RETAIN,
              "retention keeps at most " + CapProbe.RETAIN + " (got " + jsonCount + ")");

        /* 10. fingerprint unavailable -> nothing published, no write;
         * the warn must carry the helper's own contract line, not just a
         * fixed string — that was the diagnostic gap in #1482. */
        File dirNoFp = tempDir("nofp");
        FakeRunner nofp = new FakeRunner();
        nofp.lines.put("fingerprint",
            "{\"type\":\"fingerprint\",\"error\":\"vkCreateInstance failed\"}");
        FakePublisher pubNoFp = new FakePublisher();
        java.io.ByteArrayOutputStream noFpErr = new java.io.ByteArrayOutputStream();
        java.io.PrintStream oldErrNoFp = System.err;
        System.setErr(new java.io.PrintStream(noFpErr, true, "UTF-8"));
        try {
            CapProbe.ensure(dirNoFp, "", "1.0", nofp, pubNoFp);
        } finally {
            System.setErr(oldErrNoFp);
        }
        check(pubNoFp.path == null && nofp.armRuns() == 0,
              "fingerprint failure publishes nothing");
        check(noFpErr.toString("UTF-8")
              .contains("vkCreateInstance failed"),
              "fingerprint failure warn carries the contract line");

        /* 11. whole-probe budget (#1482 owner review): slow arms exhaust it —
         * the remaining arms never start and the verdict is inconclusive,
         * never unsupported-by-timeout. Budget 500 ms with 300 ms arms:
         * nogsocc completes, noq gets a truncated window (~200 ms) and its
         * work does not fit — the runner answers timeout but the truncated
         * window records it as missing — and the rest never launch. */
        File dirBudget = tempDir("budget");
        FakeRunner slow = new FakeRunner();
        slow.sleepArmMs = 300;
        slow.lines.put("fingerprint", fpLine(0x5143, 950));
        slow.armOutcomes("nogsocc", "ok", "noq", "ok", "occ", "ok",
                         "occimp", "ok", "tessocc", "ok");
        FakePublisher pubB = new FakePublisher();
        long bt0 = System.nanoTime();
        CapProbe.ensure(dirBudget, "", "1.0", slow, pubB, 500);
        long bElapsed = (System.nanoTime() - bt0) / 1_000_000;
        check(bElapsed < 500 + 2000,
              "ensure respects the total budget (elapsed " + bElapsed + "ms)");
        check(slow.armRuns() <= 2,
              "budget stops launching new arms (ran " + slow.armRuns() + ")");
        CapProbe.Result rb = CapProbe.readResult(new File(pubB.path));
        check(rb != null && rb.gsOcclusion == CapProbeVerdict.Verdict.INCONCLUSIVE
              && "probe".equals(rb.source) && rb.inconclusiveCount == 1,
              "budget-truncated probe stays inconclusive");

        /* 12. the pre-existing policy still applies on the next launch: a
         * second consecutive inconclusive run fixes the fingerprint. */
        CapProbe.ensure(dirBudget, "", "1.0", slow, pubB, 500);
        CapProbe.Result rb2 = CapProbe.readResult(new File(pubB.path));
        check(rb2 != null && rb2.gsOcclusion == CapProbeVerdict.Verdict.UNSUPPORTED
              && "inconclusive-twice".equals(rb2.source),
              "second inconclusive run still fixes unsupported");

        /* 13. first-launch diagnostics emit one total-probe duration line
         * per ensure — the device readings (9000 / 9400) grep it from the
         * session log. */
        File dirLog = tempDir("log");
        FakeRunner logRunner = new FakeRunner();
        logRunner.lines.put("fingerprint", fpLine(0x5143, 960));
        logRunner.armOutcomes("nogsocc", "ok", "noq", "ok", "occ", "ok",
                              "occimp", "ok", "tessocc", "ok");
        java.io.ByteArrayOutputStream captured = new java.io.ByteArrayOutputStream();
        java.io.PrintStream oldErr = System.err;
        System.setErr(new java.io.PrintStream(captured, true, "UTF-8"));
        try {
            CapProbe.ensure(dirLog, "", "1.0", logRunner, new FakePublisher());
        } finally {
            System.setErr(oldErr);
        }
        check(captured.toString("UTF-8").contains("probe total elapsed_ms="),
              "total probe duration line emitted");

        /* 14. the landed verdict always prints one positive line —
         * "verdict: fp=<hash> result=<v> source=<s>" — for every source
         * the 9400 readings grep: probe, cache, known-bad, runtime-lost. */
        File dirV = tempDir("verdict-line");
        FakeRunner rv = new FakeRunner();
        rv.lines.put("fingerprint", fpLine(0x5143, 970));
        rv.armOutcomes("nogsocc", "ok", "noq", "ok", "occ", "ok",
                       "occimp", "ok", "tessocc", "ok");
        FakePublisher pubV = new FakePublisher();
        java.io.ByteArrayOutputStream vErr = new java.io.ByteArrayOutputStream();
        java.io.PrintStream oldVErr = System.err;
        System.setErr(new java.io.PrintStream(vErr, true, "UTF-8"));
        String stem;
        try {
            CapProbe.ensure(dirV, "", "1.0", rv, pubV);
            stem = new File(pubV.path).getName().replace(".json", "");
            // Cached verdict on the next launch reports source=cache.
            FakeRunner rv2 = new FakeRunner();
            rv2.lines.put("fingerprint", fpLine(0x5143, 970));
            CapProbe.ensure(dirV, "", "1.0", rv2, pubV);
            // DEVICE_LOST writeback reports source=runtime-lost.
            CapProbe.markRuntimeLost(pubV.path);
            // Known-bad fingerprints land source=known-bad.
            File dirKbV = tempDir("verdict-kb");
            FakeRunner rkb2 = new FakeRunner();
            rkb2.lines.put("fingerprint", fpLine(0x13b5, 134221824));
            CapProbe.ensure(dirKbV, allOkBadlist(), "1.0", rkb2,
                            new FakePublisher());
        } finally {
            System.setErr(oldVErr);
        }
        String vlog = vErr.toString("UTF-8");
        check(vlog.contains("verdict: fp=" + stem + " result=supported source=probe"),
              "probe verdict line: fp stem + supported + probe");
        check(vlog.contains("verdict: fp=" + stem + " result=supported source=cache"),
              "cache verdict line: fp stem + supported + cache");
        check(vlog.contains("verdict: fp=" + stem + " result=unsupported source=runtime-lost"),
              "runtime-lost verdict line");
        check(vlog.contains(" result=unsupported source=known-bad"),
              "known-bad verdict line");

        if (failures > 0) {
            System.out.println("CapProbeStoreTest: " + failures + " failures");
            System.exit(1);
        }
        System.out.println("CapProbeStoreTest: passed");
    }
}
