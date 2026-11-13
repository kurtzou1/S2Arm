// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * #528 item 15. Expected values come from three places, none of them the class under test:
 * the shared contract tests/fixtures/redact_cases.tsv, a differential corpus that run.sh produces
 * with tools/redact.py (args[1]), and the hand-written Android cases below.
 * Usage: DiagnosticRedactorTest <redact_cases.tsv> <oracle.tsv>
 */
public final class DiagnosticRedactorTest {
    private static int checks, fails;
    private static final List<String> ORACLE_KEYS = Arrays.asList(
        "00112233445566778899aabbccddeeff", "fedcba9876543210fedcba9876543210ffeeddcc");

    private static void expect(String what, String want, String got) {
        checks++;
        if (!want.equals(got)) {
            fails++;
            if (fails <= 20) System.out.println("【红】" + what + "\n  期望 " + show(want) + "\n  真结果 " + show(got));
        }
    }
    private static String show(String s) {
        return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n");
    }
    private static String unesc(String s) {
        StringBuilder out = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c != '\\' || i + 1 == s.length()) { out.append(c); continue; }
            char n = s.charAt(++i);
            out.append(n == 't' ? '\t' : n == 'r' ? '\r' : n == 'n' ? '\n' : n);
        }
        return out.toString();
    }

    public static void main(String[] args) throws IOException {
        DiagnosticRedactor plain = new DiagnosticRedactor(Collections.emptyList(), Collections.emptyList());

        // 1. Shared contract (Python / Swift / iOS use the same table).
        List<String> rows = Files.readAllLines(Paths.get(args[0]), StandardCharsets.UTF_8);
        if (!rows.get(0).equals("category\tinput\texpected")) throw new AssertionError("fixture header");
        int shared = 0;
        for (int i = 1; i < rows.size(); i++) {
            String line = rows.get(i);
            if (line.isEmpty() || line.startsWith("#")) continue;
            String[] f = line.split("\t", -1);
            if (f.length != 3) throw new AssertionError("fixture line " + (i + 1));
            expect("共同契约第 " + (i + 1) + " 行（" + f[0] + "）", f[2], plain.redact(f[1]));
            shared++;
        }

        // 2. Path rules keep a known strerror tail (cases copied from tests/redact_cases_test.py PathReasonTests).
        String[][] reasons = {
            {"cp: /private/var/Game Disk/S2Arm 库/systemdata/fonts/a.bfttf: Operation not permitted", "cp: [PRIVATE_PATH]: Operation not permitted"},
            {"cp: /private/var/joe/Downloads/字体/a.bfttf: Permission denied", "cp: [PRIVATE_PATH]: Permission denied"},
            {"cp: /private/var/joe/S2Arm/游戏库/cache/x/systemdata/fonts/nintendo_ext2_003.bfttf: clonefile failed: Cross-device link",
             "cp: [PRIVATE_PATH]: clonefile failed: Cross-device link"},
            {"cp: /private/var/joe/a.bfttf: /private/var/X/b.bfttf: No space left on device", "cp: [PRIVATE_PATH]: No space left on device"},
            {"cp: /private/var/joe/Library/x: No such file or directory", "cp: [PRIVATE_PATH]: No such file or directory"},
            {"cp: /private/var/joe/My Game: Director Cut/a.xci", "cp: [PRIVATE_PATH]"},
            {"cp: /private/var/joe/Secret Name: Operation not permitted here", "cp: [PRIVATE_PATH]"},
        };
        for (String[] c : reasons) expect("系统错误原文保留：" + c[0], c[1], plain.redact(c[0]));

        // 3. Differential corpus from tools/redact.py with the same synthetic key values.
        DiagnosticRedactor oracleSide = new DiagnosticRedactor(Collections.emptyList(), ORACLE_KEYS);
        int corpus = 0;
        for (String line : Files.readAllLines(Paths.get(args[1]), StandardCharsets.UTF_8)) {
            int tab = line.indexOf('\t');
            if (tab < 0 || line.indexOf('\t', tab + 1) >= 0) throw new AssertionError("oracle line " + (corpus + 1));
            String input = unesc(line.substring(0, tab));
            expect("与 tools/redact.py 对拍第 " + (corpus + 1) + " 条：" + show(input), unesc(line.substring(tab + 1)), oracleSide.redact(input));
            corpus++;
        }
        if (corpus < 1000) throw new AssertionError("oracle corpus too small: " + corpus);

        // 4. Android: this app's own directories keep their relative part; everything else private is hidden.
        List<String[]> prefixes = new ArrayList<>();
        prefixes.add(new String[] {"/data/user/0/org.s2arm.android", "<APP>"});
        prefixes.add(new String[] {"/data/data/org.s2arm.android", "<APP>"});
        prefixes.add(new String[] {"/data/app/~~Ab12==/org.s2arm.android-Cd34==", "<BUNDLE>"});
        prefixes.add(new String[] {"/storage/emulated/0/Android/data/org.s2arm.android", "<APP_EXT>"});
        String keys = "header_key = 00112233445566778899aabbccddeeff\r\nkey_area_key_application_00 = "
            + "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100\nnot a key line\n";
        DiagnosticRedactor android = new DiagnosticRedactor(prefixes, DiagnosticRedactor.keyValues(keys));
        String[][] cases = {
            {"open /data/user/0/org.s2arm.android/files/user/0/saves/0100000000010000/ryujinx-android/host-1-2-aBc123.log",
             "open <APP>/files/user/0/saves/0100000000010000/ryujinx-android/host-1-2-aBc123.log"},
            {"lib /data/app/~~Ab12==/org.s2arm.android-Cd34==/lib/arm64/libs2arm_android.so", "lib <BUNDLE>/lib/arm64/libs2arm_android.so"},
            {"cache=/data/data/org.s2arm.android/cache/diag", "cache=<APP>/cache/diag"},
            {"ext /storage/emulated/0/Android/data/org.s2arm.android/files/x", "ext <APP_EXT>/files/x"},
            // A sibling package and a path that only contains the prefix are not ours: generic rules hide them.
            {"/data/user/0/org.s2arm.android2/files/x", "[PRIVATE_PATH]"},
            {"x=/mnt/data/user/0/org.s2arm.android/y", "x=/mnt[PRIVATE_PATH]"},
            {"/data/user_de/0/org.s2arm.android/x", "[PRIVATE_PATH]"},
            {"picked /storage/emulated/0/Download/合成 名字/game.nsp", "picked [PRIVATE_PATH]"},
            {"/sdcard/Download/x.xci: Permission denied", "[PRIVATE_PATH]: Permission denied"},
            {"/mnt/media_rw/1234-ABCD/x", "[PRIVATE_PATH]"},
            {"/data/app/~~Zz==/com.other-Yy==/base.apk", "[PRIVATE_PATH]"},
            {"tree content://com.android.externalstorage.documents/tree/primary%3ADownload%2F合成 next",
             "tree content://com.android.externalstorage.documents/[PRIVATE_PATH] next"},
            {"\"content://media/external/file/42\"", "\"content://media/[PRIVATE_PATH]\""},
            // Imported key values vanish wherever they appear, in any case.
            {"loaded 00112233445566778899AABBCCDDEEFF ok", "loaded [REDACTED] ok"},
            {"k=ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100,", "k=[REDACTED],"},
            {"loaded 2 key files", "loaded 2 key files"},
        };
        for (String[] c : cases) expect("安卓：" + c[0], c[1], android.redact(c[0]));
        expect("密钥行只取值", "[00112233445566778899aabbccddeeff, ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100]",
               DiagnosticRedactor.keyValues(keys).toString());

        // 5. Bad configuration is refused, never silently ignored.
        String[][] badPrefixes = {{"relative/x", "<A>"}, {"/x/", "<A>"}, {"/", "<A>"}, {"/x", ""}};
        for (String[] bad : badPrefixes) {
            checks++;
            try { new DiagnosticRedactor(Collections.singletonList(bad), Collections.emptyList()); fails++; System.out.println("【红】收了非法前缀 " + bad[0]); }
            catch (IllegalArgumentException expected) { }
        }
        checks++;
        try { new DiagnosticRedactor(Collections.emptyList(), Collections.singletonList("xyz")); fails++; System.out.println("【红】收了非十六进制密钥值"); }
        catch (IllegalArgumentException expected) { }

        System.out.println("DiagnosticRedactor：共同契约 " + shared + " 条、系统错误原文 " + reasons.length + " 条、与 tools/redact.py 对拍 "
            + corpus + " 条、安卓 " + cases.length + " 条，合计 " + checks + " 项检查，" + fails + " 项红");
        if (fails != 0) System.exit(1);
    }
}
