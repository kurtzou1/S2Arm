// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;
import java.util.TreeMap;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * #528 item 15: DiagnosticBundleWriter on synthetic state directories. All expected names, contents
 * and the whole manifest are written out by hand from the fixtures below (UTC, fixed clock); none is
 * computed by the writer. Only original synthetic text is used, never real logs.
 */
public final class DiagnosticBundleWriterTest {
    private static int checks, fails;
    private static final TimeZone UTC = TimeZone.getTimeZone("UTC");
    private static final long T0 = 1794297600000L;   // 2026-11-10T08:00:00Z
    private static final long T1 = 1794389415000L;   // 2026-11-11T09:30:15Z
    private static final long T2 = 1794445323000L;   // 2026-11-12T01:02:03Z
    private static final long NOW = 1794446625000L;  // 2026-11-12T01:23:45Z

    private static void expect(String what, Object want, Object got) {
        checks++;
        if (!java.util.Objects.equals(want, got)) {
            fails++;
            System.out.println("【红】" + what + "\n  期望 " + want + "\n  真结果 " + got);
        }
    }

    private static Path write(Path file, String text, long modified) throws IOException {
        Files.createDirectories(file.getParent());
        Files.write(file, text.getBytes(StandardCharsets.UTF_8));
        Files.setLastModifiedTime(file, FileTime.fromMillis(modified));
        return file;
    }
    private static Map<String, String> zip(Path bundle) throws IOException {
        Map<String, String> out = new LinkedHashMap<>();
        try (ZipFile z = new ZipFile(bundle.toFile(), StandardCharsets.UTF_8)) {
            for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements(); ) {
                ZipEntry entry = e.nextElement();
                try (InputStream in = z.getInputStream(entry)) {
                    out.put(entry.getName(), new String(in.readAllBytes(), StandardCharsets.UTF_8));
                }
            }
        }
        return out;
    }
    private static List<String> names(Path dir) throws IOException {
        try (Stream<Path> s = Files.list(dir)) {
            return s.map(p -> p.getFileName().toString()).sorted().collect(Collectors.toList());
        }
    }
    private static Map<String, Map<String, String>> info() {
        Map<String, Map<String, String>> info = new TreeMap<>();
        Map<String, String> app = new TreeMap<>(), device = new TreeMap<>(), settings = new TreeMap<>();
        app.put("package", "org.s2arm.android");
        app.put("version", "0.0-test");
        app.put("native_dir", "/data/app/~~Ab12==/org.s2arm.android-Cd34==/lib/arm64");
        device.put("model", "Synth Phone");
        device.put("android", "16");
        device.put("sdk", "36");
        settings.put("language", "zh-CN");
        info.put("app", app);
        info.put("device", device);
        info.put("settings", settings);
        return info;
    }
    private static int utf8(String s) { return s.getBytes(StandardCharsets.UTF_8).length; }
    private static void deleteTree(Path root) throws IOException {
        if (!Files.exists(root)) return;
        try (Stream<Path> s = Files.walk(root)) {
            for (Path p : s.sorted(Comparator.reverseOrder()).collect(Collectors.toList())) Files.deleteIfExists(p);
        }
    }

    public static void main(String[] args) throws IOException {
        Path root = Files.createTempDirectory("s2a-diag-");
        try {
            run(root);
        } finally {
            deleteTree(root);
        }
        System.out.println("DiagnosticBundleWriter：" + checks + " 项检查，" + fails + " 项红");
        if (fails != 0) System.exit(1);
    }

    private static void run(Path root) throws IOException {
        List<String[]> prefixes = new ArrayList<>();
        prefixes.add(new String[] {"/data/user/0/org.s2arm.android", "<APP>"});
        prefixes.add(new String[] {"/data/app/~~Ab12==/org.s2arm.android-Cd34==", "<BUNDLE>"});
        DiagnosticRedactor redactor = new DiagnosticRedactor(prefixes,
            DiagnosticRedactor.keyValues("header_key = 00112233445566778899aabbccddeeff\n"));

        // ---- 1. What is picked up, in which order, under which name; nothing else from the save area.
        Path saves = root.resolve("files/user/0/saves");
        Path game1 = saves.resolve("0100000000010000/ryujinx-android");
        write(game1.resolve("host-1-100-aaaaaa.log"), "S2Arm: open /data/user/0/org.s2arm.android/files/x\ncontact synth@example.invalid\n", T0);
        write(game1.resolve("host-2-200-bbbbbb.log"), "frame 1\nkey 00112233445566778899AABBCCDDEEFF\n", T1);
        write(game1.resolve("save.bin"), "SAVEDATA-SECRET", T2 + 1000);
        write(game1.resolve("notes.log"), "NOTES-SECRET", T2 + 1000);
        Path outside = write(root.resolve("outside/secret.txt"), "OUTSIDE-SECRET", T2 + 1000);
        Files.createSymbolicLink(game1.resolve("host-3-300-cccccc.log"), outside);
        Files.createDirectories(game1.resolve("host-4-400-dddddd.log"));
        write(saves.resolve("0100000000020000/ryujinx-android/host-5-500-eeeeee.log"), "第二款 frame 9\n", T2);
        write(saves.resolve("not-a-title/ryujinx-android/host-6-600-ffffff.log"), "BADTITLE-SECRET", T2 + 1000);
        write(root.resolve("elsewhere/ryujinx-android/host-7-700-gggggg.log"), "LINKEDTITLE-SECRET", T2 + 1000);
        Files.createSymbolicLink(saves.resolve("0100000000030000"), root.resolve("elsewhere"));

        Path out = root.resolve("cache/diag");
        DiagnosticBundleWriter.Result r = DiagnosticBundleWriter.write(saves, out, redactor::redact, info(), "diag", NOW, UTC);
        expect("包名", "S2Arm-diag-1112-0123.zip", r.bundle.getFileName().toString());
        expect("日志份数 / 略去", "3/0", r.logs + "/" + r.omitted);
        Map<String, String> z = zip(r.bundle);
        expect("包内条目与顺序", Arrays.asList("manifest.json", "logs/host.log", "logs/host-20261111-093015.log", "logs/host-20261110-080000.log"),
               new ArrayList<>(z.keySet()));
        String newest = "第二款 frame 9\n", middle = "frame 1\nkey [REDACTED]\n", oldest = "S2Arm: open <APP>/files/x\ncontact [EMAIL]\n";
        expect("最新一局 → logs/host.log", newest, z.get("logs/host.log"));
        expect("导入的密钥值不出包", middle, z.get("logs/host-20261111-093015.log"));
        expect("本应用目录换成 <APP>、邮箱换掉", oldest, z.get("logs/host-20261110-080000.log"));
        for (String secret : new String[] {"SAVEDATA", "NOTES", "OUTSIDE", "BADTITLE", "LINKEDTITLE", "00112233"})
            for (Map.Entry<String, String> e : z.entrySet())
                expect(e.getKey() + " 不含 " + secret, false, e.getValue().contains(secret));
        String manifest = "{\n"
            + "  \"app\" : {\n"
            + "    \"native_dir\" : \"<BUNDLE>/lib/arm64\",\n"
            + "    \"package\" : \"org.s2arm.android\",\n"
            + "    \"version\" : \"0.0-test\"\n"
            + "  },\n"
            + "  \"device\" : {\n"
            + "    \"android\" : \"16\",\n"
            + "    \"model\" : \"Synth Phone\",\n"
            + "    \"sdk\" : \"36\"\n"
            + "  },\n"
            + "  \"exits\" : [],\n"
            + "  \"exported_at\" : \"2026-11-12T01:23:45Z\",\n"
            + "  \"files\" : [\n"
            + "    {\n      \"bytes\" : " + utf8(newest) + ",\n      \"path\" : \"logs/host.log\",\n      \"truncated\" : false\n    },\n"
            + "    {\n      \"bytes\" : " + utf8(middle) + ",\n      \"path\" : \"logs/host-20261111-093015.log\",\n      \"truncated\" : false\n    },\n"
            + "    {\n      \"bytes\" : " + utf8(oldest) + ",\n      \"path\" : \"logs/host-20261110-080000.log\",\n      \"truncated\" : false\n    }\n"
            + "  ],\n"
            + "  \"omitted_logs\" : 0,\n"
            + "  \"platform\" : \"android\",\n"
            + "  \"schema\" : 1,\n"
            + "  \"sessions\" : [\n"
            + "    {\n      \"current\" : true,\n      \"file\" : \"logs/host.log\",\n      \"modified\" : \"2026-11-12T01:02:03Z\",\n      \"title_id\" : \"0100000000020000\"\n    },\n"
            + "    {\n      \"current\" : false,\n      \"file\" : \"logs/host-20261111-093015.log\",\n      \"modified\" : \"2026-11-11T09:30:15Z\",\n      \"title_id\" : \"0100000000010000\"\n    },\n"
            + "    {\n      \"current\" : false,\n      \"file\" : \"logs/host-20261110-080000.log\",\n      \"modified\" : \"2026-11-10T08:00:00Z\",\n      \"title_id\" : \"0100000000010000\"\n    }\n"
            + "  ],\n"
            + "  \"settings\" : {\n"
            + "    \"language\" : \"zh-CN\"\n"
            + "  }\n"
            + "}\n";
        expect("manifest.json 全文", manifest, z.get("manifest.json"));
        expect("输出目录只有这个包", Collections.singletonList("S2Arm-diag-1112-0123.zip"), names(out));

        // ---- 2. Same minute again: -2; older bundles beyond three go, leftovers from a killed export go.
        write(out.resolve("S2Arm-diag-1101-0000.zip"), "old1", T0 - 3000);
        write(out.resolve("S2Arm-诊断-1102-0000.zip"), "old2", T0 - 2000);
        write(out.resolve(".partial-123.zip"), "half", T0);
        write(out.resolve("keep-me.txt"), "not a bundle", T0 - 9000);
        Files.setLastModifiedTime(out.resolve("S2Arm-diag-1112-0123.zip"), FileTime.fromMillis(T0 - 1000));
        r = DiagnosticBundleWriter.write(saves, out, redactor::redact, info(), "diag", NOW, UTC);
        expect("同一分钟第二个包", "S2Arm-diag-1112-0123-2.zip", r.bundle.getFileName().toString());
        expect("只留最新 3 个、清掉残片、不碰别的文件",
               Arrays.asList("S2Arm-diag-1112-0123-2.zip", "S2Arm-diag-1112-0123.zip", "S2Arm-诊断-1102-0000.zip", "keep-me.txt"),
               names(out));

        // ---- 2b. What the share provider may hand out: our bundle names in that directory, nothing else.
        expect("可分享：刚写的包", out.resolve("S2Arm-diag-1112-0123-2.zip"), DiagnosticBundleWriter.shareable(out, "S2Arm-diag-1112-0123-2.zip"));
        expect("可分享：中文名的包", out.resolve("S2Arm-诊断-1102-0000.zip"), DiagnosticBundleWriter.shareable(out, "S2Arm-诊断-1102-0000.zip"));
        Files.createSymbolicLink(out.resolve("S2Arm-diag-0101-0000.zip"), outside);
        write(root.resolve("cache/S2Arm-diag-0101-0001.zip"), "one level up", T0);
        for (String bad : new String[] {"S2Arm-diag-0101-0000.zip", "../S2Arm-diag-0101-0001.zip", "S2Arm-diag-1112-0123.zip/..",
                                        "keep-me.txt", ".partial-1.zip", "S2Arm-diag-9999-9999.zip", "S2Arm-../x-0101-0000.zip", null})
            expect("不可分享：" + bad, null, DiagnosticBundleWriter.shareable(out, bad));
        Files.delete(out.resolve("S2Arm-diag-0101-0000.zip"));

        // ---- 3. No logs at all (nothing played yet): a manifest-only bundle.
        Path empty = root.resolve("empty");
        r = DiagnosticBundleWriter.write(root.resolve("no-such-saves"), empty, redactor::redact, info(), "diag", NOW, UTC);
        Map<String, String> only = zip(r.bundle);
        expect("没有日志时只有 manifest", Collections.singletonList("manifest.json"), new ArrayList<>(only.keySet()));
        expect("没有日志时 files 为空", true, only.get("manifest.json").contains("\"files\" : [],\n"));

        // ---- 4. More than ten logs: the ten newest, the rest counted as omitted.
        Path many = root.resolve("many/saves");
        for (int i = 0; i < 12; i++)
            write(many.resolve("0100000000040000/ryujinx-android/host-" + i + "-1-abc" + (100 + i) + ".log"), "s" + i + "\n", T0 + i * 1000L);
        r = DiagnosticBundleWriter.write(many, root.resolve("many/out"), redactor::redact, info(), "diag", NOW, UTC);
        expect("十份进包、两份略去", "10/2", r.logs + "/" + r.omitted);
        Map<String, String> m = zip(r.bundle);
        expect("最新的是 s11", "s11\n", m.get("logs/host.log"));
        expect("略去的是最旧的 s0 / s1", false, m.containsValue("s0\n") || m.containsValue("s1\n"));
        expect("manifest 记了略去数", true, m.get("manifest.json").contains("\"omitted_logs\" : 2,"));

        // ---- 5. Redaction failure or an archive over the cap: an error, and nothing left behind.
        Path failOut = root.resolve("fail");
        try {
            // Fails on one log only (manifest values still pass): a fallback to that log's original text must not happen.
            DiagnosticBundleWriter.write(saves, failOut, s -> {
                if (s.contains("frame 1")) throw new DiagnosticRedactor.RedactionException("x");
                return redactor.redact(s);
            }, info(), "diag", NOW, UTC);
            expect("脱敏失败要报错", "IOException", "returned");
        } catch (IOException e) {
            expect("脱敏失败的报错", "redaction failed", e.getMessage());
        }
        expect("脱敏失败不留文件", Collections.emptyList(), names(failOut));
        try {
            DiagnosticBundleWriter.write(saves, failOut, redactor::redact, info(), "diag", NOW, UTC, 200);
            expect("超上限要报错", "IOException", "returned");
        } catch (IOException e) {
            expect("超上限的报错", "bundle too large", e.getMessage());
        }
        expect("超上限不留文件", Collections.emptyList(), names(failOut));
        try {
            DiagnosticBundleWriter.write(saves, failOut, redactor::redact, info(), "../x", NOW, UTC);
            expect("非法包名词要拒", "IllegalArgumentException", "returned");
        } catch (IllegalArgumentException e) {
            expect("非法包名词的报错", "bundle word", e.getMessage());
        }

        // ---- 5b. System exit records: reason names (values from android-36 android.jar ApplicationExitInfo.REASON_*),
        //          strings redacted, description cut after redaction, at most 16, order kept.
        String[] reasonNames = {"unknown", "exit_self", "signaled", "low_memory", "crash", "crash_native", "anr",
            "initialization_failure", "permission_change", "excessive_resource_usage", "user_requested", "user_stopped",
            "dependency_died", "other", "freezer", "package_state_change", "package_updated"};
        for (int code = 0; code < reasonNames.length; code++) expect("退出原因 " + code, reasonNames[code], DiagnosticExits.reason(code));
        expect("未知退出原因", "reason_99", DiagnosticExits.reason(99));
        expect("负的退出原因", "reason_-1", DiagnosticExits.reason(-1));
        List<Map<String, Object>> exits = new ArrayList<>();
        exits.add(DiagnosticExits.record(T2, "org.s2arm.android:game", 5, 11, 100, 2048L, 4096L,
            "crash in /data/user/0/org.s2arm.android/files/x by synth@example.invalid"));
        String longDescription = "x".repeat(DiagnosticExits.MAX_DESCRIPTION - 5) + " /storage/emulated/0/Download/合成/a.nsp tail";
        exits.add(DiagnosticExits.record(T1, "org.s2arm.android", 10, 0, 400, 0L, 0L, longDescription));
        for (int i = 0; i < 20; i++) exits.add(DiagnosticExits.record(T0 - i * 1000L, "org.s2arm.android", 3, 9, 300, 1L, 2L, "lmk " + i));
        r = DiagnosticBundleWriter.write(saves, root.resolve("exits"), redactor::redact, info(), exits, "diag", NOW, UTC);
        String em = zip(r.bundle).get("manifest.json");
        String first = "    {\n"
            + "      \"description\" : \"crash in <APP>/files/x by [EMAIL]\",\n"
            + "      \"importance\" : 100,\n"
            + "      \"process\" : \"org.s2arm.android:game\",\n"
            + "      \"pss_kb\" : 2048,\n"
            + "      \"reason\" : \"crash_native\",\n"
            + "      \"reason_code\" : 5,\n"
            + "      \"rss_kb\" : 4096,\n"
            + "      \"status\" : 11,\n"
            + "      \"time\" : \"2026-11-12T01:02:03Z\"\n"
            + "    },\n";
        expect("第一条退出记录（原生崩溃，信号 11），路径与邮箱已脱敏", true, em.contains("  \"exits\" : [\n" + first));
        // 295 x + " [PRIVATE_PATH]" (the path is hidden first) → cut at 300 characters, then "…"
        String cutDescription = ("x".repeat(DiagnosticExits.MAX_DESCRIPTION - 5) + " [PRIVATE_PATH]").substring(0, DiagnosticExits.MAX_DESCRIPTION) + "…";
        expect("长描述先脱敏再截到 300 字", true, em.contains("\"description\" : \"" + cutDescription + "\""));
        expect("长描述里没有原路径", false, em.contains("Download"));
        int n = 0;
        for (int at = em.indexOf("\"reason_code\""); at >= 0; at = em.indexOf("\"reason_code\"", at + 1)) n++;
        expect("最多 16 条", DiagnosticExits.MAX_RECORDS, n);
        expect("按给的顺序取前 16 条：最后一条是 lmk 13", true, em.contains("\"lmk 13\"") && !em.contains("\"lmk 14\""));

        // ---- 6. Over the cap: head quarter and tail, cut at line breaks (cap 1000: head 250, tail 750 - 64 = 686).
        StringBuilder lines = new StringBuilder();
        for (int i = 0; i < 300; i++) lines.append(String.format("line%05d\n", i));   // 10 bytes each, 3000 in all
        Path big = write(root.resolve("big.log"), lines.toString(), T0);
        boolean[] cut = {false};
        String got = new String(DiagnosticBundleWriter.readCapped(big, 1000, cut), StandardCharsets.UTF_8);
        // head [0,250) ends on a line end at 249 → lines 0–24; tail [2314,3000) first line end at 2319 → lines 232–299
        String want = lines.substring(0, 250) + "\n…截掉 2070 字节…\n" + lines.substring(2320);
        expect("超上限截头尾（按行）", want, got);
        expect("截过要标出来", true, cut[0]);
        expect("截后不超上限", true, utf8(got) <= 1000);
        Path oneLine = write(root.resolve("oneline.log"), "a".repeat(3000), T0);
        expect("没有换行就整段不要，不从中间切", "\n…截掉 3000 字节…\n",
               new String(DiagnosticBundleWriter.readCapped(oneLine, 1000, cut), StandardCharsets.UTF_8));
        Path small = write(root.resolve("small.log"), "short\n", T0);
        expect("不超上限原样", "short\n", new String(DiagnosticBundleWriter.readCapped(small, 1000, cut), StandardCharsets.UTF_8));
        expect("不超上限不标截", false, cut[0]);
    }
}
