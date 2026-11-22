package org.s2arm.android;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;


import org.s2arm.android.CapProbeVerdict.ArmResult;
import org.s2arm.android.CapProbeVerdict.Fingerprint;
import org.s2arm.android.CapProbeVerdict.KnownBad;
import org.s2arm.android.CapProbeVerdict.Outcome;
import org.s2arm.android.CapProbeVerdict.Verdict;

/**
 * Orchestration + cache for the GS+occlusion capability probe (#1456).
 *
 * Called from native s2a_capprobe_ensure() on the game-start worker,
 * before graphics selection creates any Vulkan device — the same launch
 * stage that owns pipeline warm-up, so the normal startup UI keeps
 * showing progress while the probe runs; nothing reaches the game until
 * the verdict file is written.
 *
 * Result files live at files/capprobe/<fingerprint-hash>.json:
 *   {"schema":1,"fingerprint":{...},"source":"probe|known-bad|
 *    runtime-lost|inconclusive-twice","arms":[...],"verdict":
 *    {"gs_occlusion":...,"tess_occlusion":...},"inconclusive_count":N,
 *    "probed_utc":"...","app_version":"..."}
 *
 * A fingerprint with a final probe verdict is reused; an inconclusive
 * verdict re-probes on the next launch, and two consecutive inconclusive
 * probes fix the fingerprint as unsupported with
 * source=inconclusive-twice. At most RETAIN recent files are kept.
 *
 * Plain JDK behind the Runner/Publisher seams — host unit tests inject
 * fakes; production wires NativeBridge.
 */
public final class CapProbe {

    public static final int ARM_TIMEOUT_MS = 10_000;
    /** Whole-probe deadline for one ensure() call: fingerprint plus every
     *  arm in ARMS_IN_ORDER at ARM_TIMEOUT_MS could block first launch for
     *  ~60 s, so the total is capped. Arms not started within the budget
     *  stay missing -> inconclusive (never directly unsupported), and an
     *  arm killed by a budget-truncated timeout counts as missing, not as
     *  a hung arm: only a line produced under the arm's own full
     *  ARM_TIMEOUT_MS window can solidify a verdict. */
    public static final int TOTAL_BUDGET_MS = 15_000;
    public static final int RETAIN = 8;
    public static final String DIRECTORY = "capprobe";

    public interface Runner {
        /** Runs one arm in an independent process; returns its contract
         *  JSON line (never null — timeout/crash synthesize lines). */
        String run(String arm, int timeoutMs);
    }

    public interface Publisher {
        /** Points the capability layer at the verdict file for this
         *  fingerprint (S2A_CAPPROBE_RESULT). */
        void publish(String resultPath);
    }

    // System.err reaches logcat on Android and keeps the class plain-JDK
    // for host tests.
    private static void warn(String what) {
        System.err.println("S2Arm capprobe: " + what);
    }

    /** One-line, length-capped rendering of a runner contract line for
     *  the warn channel — the raw line is what a failed probe leaves for
     *  diagnosis (#1482), so nulls/empties/newlines stay explicit. */
    private static String abbreviate(String line) {
        if (line == null) return "(null)";
        String s = line.replace('\n', ' ').replace('\r', ' ').trim();
        if (s.isEmpty()) return "(empty)";
        return s.length() <= 512 ? s : s.substring(0, 512) + "...";
    }

    private static final Runner BRIDGE_RUNNER = new Runner() {
        @Override public String run(String arm, int timeoutMs) {
            String line = NativeBridge.capProbeArm(arm, timeoutMs);
            return line == null ? "" : line;
        }
    };

    private static final Publisher BRIDGE_PUBLISHER = new Publisher() {
        @Override public void publish(String resultPath) {
            NativeBridge.capProbePublish(resultPath);
        }
    };

    /* ---------------- cached result ---------------- */

    public static final class Result {
        public Fingerprint fingerprint;
        public String source = "";
        public Verdict gsOcclusion = Verdict.INCONCLUSIVE;
        public Verdict tessOcclusion = Verdict.INCONCLUSIVE;
        public int inconclusiveCount;
    }

    /* ---------------- file naming ---------------- */

    /** <fingerprint-hash>.json — hash of the canonical fingerprint
     *  fields, so a driver or build-fingerprint change re-probes while
     *  older fingerprints keep their files for rollback comparison. */
    public static String resultFileName(Fingerprint fp) {
        String canonical = "v1|" + fp.deviceName + "|" + fp.vendorID + "|"
            + fp.deviceID + "|" + fp.driverVersion + "|" + fp.apiVersion
            + "|" + fp.buildFingerprint;
        MessageDigest sha;
        try {
            sha = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
        byte[] digest = sha.digest(canonical.getBytes(StandardCharsets.UTF_8));
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 8; i++) sb.append(String.format("%02x", digest[i]));
        return sb.toString() + ".json";
    }

    /* ---------------- result file read/write ---------------- */

    public static Result readResult(File file) {
        String text = readAll(file);
        if (text == null) return null;
        try {
            Map<String, Object> obj = CapProbeVerdict.parseObject(text.trim());
            if (!(obj.get("schema") instanceof Number) ||
                ((Number) obj.get("schema")).intValue() != 1)
                return null;
            Object fpObj = obj.get("fingerprint");
            if (!(fpObj instanceof Map)) return null;
            @SuppressWarnings("unchecked")
            Map<String, Object> fpMap = (Map<String, Object>) fpObj;
            Result r = new Result();
            r.fingerprint = fingerprintFromMap(fpMap);
            Object src = obj.get("source");
            r.source = src instanceof String ? (String) src : "";
            Object vObj = obj.get("verdict");
            if (vObj instanceof Map) {
                @SuppressWarnings("unchecked")
                Map<String, Object> v = (Map<String, Object>) vObj;
                r.gsOcclusion = CapProbeVerdict.verdictFrom(
                    v.get("gs_occlusion") instanceof String
                        ? (String) v.get("gs_occlusion") : null);
                r.tessOcclusion = CapProbeVerdict.verdictFrom(
                    v.get("tess_occlusion") instanceof String
                        ? (String) v.get("tess_occlusion") : null);
            }
            Object cnt = obj.get("inconclusive_count");
            if (cnt instanceof Number)
                r.inconclusiveCount = ((Number) cnt).intValue();
            return r;
        } catch (RuntimeException e) {
            return null;
        }
    }

    private static Fingerprint fingerprintFromMap(Map<String, Object> m) {
        Fingerprint fp = new Fingerprint();
        Object s;
        fp.deviceName = (s = m.get("deviceName")) instanceof String ? (String) s : "";
        fp.vendorID = numOf(m.get("vendorID"));
        fp.deviceID = numOf(m.get("deviceID"));
        fp.driverVersion = numOf(m.get("driverVersion"));
        fp.apiVersion = numOf(m.get("apiVersion"));
        fp.buildFingerprint =
            (s = m.get("buildFingerprint")) instanceof String ? (String) s : "";
        return fp;
    }

    private static long numOf(Object o) {
        return o instanceof Number ? ((Number) o).longValue() : 0;
    }

    public static String resultJson(Fingerprint fp, String source,
                                    List<ArmResult> arms,
                                    Verdict gs, Verdict tess,
                                    int inconclusiveCount,
                                    String appVersion, String probedUtc) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"schema\":1,\"fingerprint\":{");
        CapProbeVerdict.strField(sb, "deviceName", fp.deviceName); sb.append(',');
        sb.append("\"vendorID\":").append(fp.vendorID).append(',');
        sb.append("\"deviceID\":").append(fp.deviceID).append(',');
        sb.append("\"driverVersion\":").append(fp.driverVersion).append(',');
        sb.append("\"apiVersion\":").append(fp.apiVersion).append(',');
        CapProbeVerdict.strField(sb, "buildFingerprint", fp.buildFingerprint);
        sb.append("},\"source\":");
        CapProbeVerdict.quote(sb, source);
        sb.append(",\"arms\":[");
        for (int i = 0; i < arms.size(); i++) {
            ArmResult r = arms.get(i);
            if (i > 0) sb.append(',');
            sb.append('{');
            CapProbeVerdict.strField(sb, "arm", r.arm); sb.append(',');
            CapProbeVerdict.strField(sb, "outcome",
                CapProbeVerdict.outcomeName(r.outcome)); sb.append(',');
            sb.append("\"vk_result\":")
              .append(r.vkResult == null ? "null" : r.vkResult.toString()).append(',');
            sb.append("\"samples\":")
              .append(r.samples == null ? "null" : r.samples.toString()).append(',');
            sb.append("\"elapsed_ms\":").append(r.elapsedMs).append(',');
            CapProbeVerdict.strField(sb, "stage", r.stage); sb.append(',');
            CapProbeVerdict.strField(sb, "reason", r.reason);
            sb.append('}');
        }
        sb.append("],\"verdict\":{\"gs_occlusion\":")
          .append('"').append(CapProbeVerdict.verdictName(gs)).append("\",")
          .append("\"tess_occlusion\":")
          .append('"').append(CapProbeVerdict.verdictName(tess)).append("\"}");
        sb.append(",\"inconclusive_count\":").append(inconclusiveCount);
        sb.append(",\"probed_utc\":");
        CapProbeVerdict.quote(sb, probedUtc);
        sb.append(",\"app_version\":");
        CapProbeVerdict.quote(sb, appVersion);
        sb.append('}');
        return sb.toString();
    }

    static void writeAtomic(File file, String json) throws IOException {
        File parent = file.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs())
            throw new IOException("cannot create " + parent);
        File tmp = new File(file.getParentFile(), file.getName() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(json.getBytes(StandardCharsets.UTF_8));
        }
        if (!tmp.renameTo(file)) {
            tmp.delete();
            throw new IOException("cannot publish " + file);
        }
    }

    /** At most RETAIN recent result files; the oldest by modification
     *  time go first. The file just written is never pruned. */
    static void prune(File dir, File keep, int retain) {
        File[] all = dir.listFiles();
        if (all == null || all.length <= retain) return;
        List<File> jsons = new ArrayList<File>();
        for (File f : all)
            if (f.isFile() && f.getName().endsWith(".json") && !f.equals(keep))
                jsons.add(f);
        jsons.sort(new Comparator<File>() {
            @Override public int compare(File a, File b) {
                return Long.compare(a.lastModified(), b.lastModified());
            }
        });
        int excess = (jsons.size() + 1) - retain;
        for (int i = 0; i < excess && i < jsons.size(); i++)
            jsons.get(i).delete();
    }

    /** <hash>.json -> <hash>: the fingerprint tag printed in the
     *  "verdict: fp=" line — the same stem QA greps on disk. */
    private static String fileStem(File file) {
        String name = file.getName();
        return name.endsWith(".json")
            ? name.substring(0, name.length() - ".json".length()) : name;
    }

    /** One positive line per landed verdict (#1482): the 9400 readings
     *  grep "verdict: fp=<hash> result=<v> source=<s>" from logcat —
     *  the file write alone left nothing to read on device. */
    private static void verdictLine(File file, Verdict gs, String source) {
        warn("verdict: fp=" + fileStem(file)
             + " result=" + CapProbeVerdict.verdictName(gs)
             + " source=" + source);
    }

    private static String readAll(File file) {
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] buf = new byte[(int) Math.min(file.length(), 1 << 16)];
            int n = in.read(buf);
            return n <= 0 ? null : new String(buf, 0, n, StandardCharsets.UTF_8);
        } catch (IOException e) {
            return null;
        }
    }

    private static String utcNow() {
        SimpleDateFormat fmt =
            new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US);
        fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
        return fmt.format(new Date());
    }

    /* ---------------- orchestration ---------------- */

    /** Production entry called from native s2a_capprobe_ensure. Never
     *  throws outward: a probe orchestration failure leaves
     *  S2A_CAPPROBE_RESULT unset, which the capability layer reads as
     *  "not supported" — the safe direction. */
    public static void ensure(String dir, String badlistText, String appVersion) {
        try {
            ensure(new File(dir), badlistText, appVersion,
                   BRIDGE_RUNNER, BRIDGE_PUBLISHER);
        } catch (Throwable t) {
            warn("ensure failed: " + t);
        }
    }

    /** Test entry: the decision logic with an injected runner/publisher. */
    public static void ensure(File dir, String badlistText, String appVersion,
                              Runner runner, Publisher publisher) {
        ensure(dir, badlistText, appVersion, runner, publisher, TOTAL_BUDGET_MS);
    }

    /** Decision logic with an explicit whole-probe budget (host tests use a
     *  small budget to exercise the deadline without sleeping 15 s). */
    public static void ensure(File dir, String badlistText, String appVersion,
                              Runner runner, Publisher publisher, int totalBudgetMs) {
        long started = System.nanoTime();
        try {
            ensureTimed(dir, badlistText, appVersion, runner, publisher,
                        totalBudgetMs, started);
        } finally {
            // One first-boot-probe total line per ensure call: the device
            // readings (9000 / 9400) grep this from the host/session log.
            warn("probe total elapsed_ms="
                 + (System.nanoTime() - started) / 1_000_000);
        }
    }

    private static int budgetLeftMs(long started, int totalBudgetMs) {
        long spent = (System.nanoTime() - started) / 1_000_000;
        long left = totalBudgetMs - spent;
        return left > 0 ? (int) left : 0;
    }

    private static void ensureTimed(File dir, String badlistText, String appVersion,
                                    Runner runner, Publisher publisher,
                                    int totalBudgetMs, long started) {
        List<KnownBad> knownBad = CapProbeVerdict.parseKnownBad(badlistText);
        int left = budgetLeftMs(started, totalBudgetMs);
        if (left <= 0) {
            warn("probe budget exhausted before fingerprint");
            return;
        }
        String fpLine = runner.run("fingerprint", Math.min(ARM_TIMEOUT_MS, left));
        Fingerprint fp = CapProbeVerdict.tryFingerprint(fpLine);
        if (fp == null) {
            warn("fingerprint unavailable; GS+occlusion stays unsupported; line="
                 + abbreviate(fpLine));
            return;
        }
        if (!dir.isDirectory() && !dir.mkdirs() && !dir.isDirectory()) {
            warn("cannot create " + dir);
            return;
        }
        File file = new File(dir, resultFileName(fp));
        Result existing = readResult(file);
        if (existing != null && "runtime-lost".equals(existing.source)) {
            // A lost device in a game does not say which feature caused it.
            // Discard this old inference and run the usual fingerprint policy.
            warn("legacy runtime-lost verdict ignored; checking GS+occlusion again");
            existing = null;
        }

        // Cached final verdicts never re-probe; inconclusive re-probes
        // (second consecutive inconclusive fixes the fingerprint).
        if (existing != null && existing.gsOcclusion != Verdict.INCONCLUSIVE) {
            publisher.publish(file.getAbsolutePath());
            verdictLine(file, existing.gsOcclusion, "cache");
            return;
        }

        if (CapProbeVerdict.matchesKnownBad(fp, knownBad)) {
            String json = resultJson(fp, "known-bad",
                new ArrayList<ArmResult>(), Verdict.UNSUPPORTED,
                Verdict.UNSUPPORTED, 0, appVersion, utcNow());
            try {
                writeAtomic(file, json);
                prune(dir, file, RETAIN);
                publisher.publish(file.getAbsolutePath());
                verdictLine(file, Verdict.UNSUPPORTED, "known-bad");
            } catch (IOException e) {
                warn("write failed: " + e);
            }
            return;
        }

        List<ArmResult> arms = new ArrayList<ArmResult>();
        for (String name : CapProbeVerdict.ARMS_IN_ORDER) {
            left = budgetLeftMs(started, totalBudgetMs);
            if (left <= 0) {
                warn("probe budget exhausted; remaining arms inconclusive");
                break;
            }
            int armTimeout = Math.min(ARM_TIMEOUT_MS, left);
            String line;
            try {
                line = runner.run(name, armTimeout);
            } catch (RuntimeException e) {
                // The arm never produced a contract line at all — missing,
                // which the verdict layer reads as inconclusive.
                continue;
            }
            if (line == null || line.trim().isEmpty()) {
                warn("arm " + name + ": no contract line from helper");
                continue;
            }
            try {
                ArmResult r = CapProbeVerdict.parseArmLine(line);
                if (!name.equals(r.arm)) r.arm = name;
                if (r.outcome == Outcome.TIMEOUT && armTimeout < ARM_TIMEOUT_MS) {
                    // Killed by the total budget, not the arm's own window —
                    // record it missing so it reads inconclusive instead of
                    // solidifying unsupported on a truncated run.
                    continue;
                }
                arms.add(r);
            } catch (RuntimeException e) {
                warn("arm " + name + ": unparseable contract line="
                     + abbreviate(line));
                ArmResult r = ArmResult.of(name, Outcome.CRASHED);
                r.reason = "unparseable-line";
                arms.add(r);
            }
        }

        Verdict gs = CapProbeVerdict.gsOcclusion(fp, arms, knownBad);
        Verdict tess = CapProbeVerdict.tessOcclusion(fp, arms, knownBad);
        int count = existing != null ? existing.inconclusiveCount : 0;
        String source = "probe";
        if (gs == Verdict.INCONCLUSIVE) {
            count++;
            if (count >= 2) {
                // Two consecutive inconclusive probes fix the fingerprint
                // as unsupported; the file names the reason explicitly.
                gs = Verdict.UNSUPPORTED;
                source = "inconclusive-twice";
            }
        } else {
            count = 0;
        }

        String json = resultJson(fp, source, arms, gs, tess, count,
                                 appVersion, utcNow());
        try {
            writeAtomic(file, json);
            prune(dir, file, RETAIN);
            publisher.publish(file.getAbsolutePath());
            verdictLine(file, gs, source);
        } catch (IOException e) {
            warn("write failed: " + e);
        }
    }

    /* ---------------- runtime DEVICE_LOST writeback ---------------- */

    /** Called from native s2a_capprobe_runtime_lost when a real session
     *  hits VK_ERROR_DEVICE_LOST on this fingerprint. Rewrites the
     *  fingerprint's own result file with source=runtime-lost and
     *  gs_occlusion=unsupported — the fingerprint only, never the game. */
    public static void markRuntimeLost(String resultPath) {
        if (resultPath == null || resultPath.isEmpty()) return;
        File file = new File(resultPath);
        Result existing = readResult(file);
        if (existing == null || existing.fingerprint == null) return;
        if ("runtime-lost".equals(existing.source)) return;
        String json = resultJson(existing.fingerprint, "runtime-lost",
            new ArrayList<ArmResult>(), Verdict.UNSUPPORTED,
            existing.tessOcclusion, existing.inconclusiveCount,
            "", utcNow());
        try {
            writeAtomic(file, json);
            verdictLine(file, Verdict.UNSUPPORTED, "runtime-lost");
        } catch (IOException e) {
            warn("runtime-lost write failed: " + e);
        }
    }
}
