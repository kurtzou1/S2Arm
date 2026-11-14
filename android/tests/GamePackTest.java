package org.s2arm.android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.zip.Deflater;

/** Plain Java checks for game package verification (no Android runtime). Optional arg: a real package to verify. */
public final class GamePackTest {
    private static int failures;

    private static void check(boolean ok, String what) {
        if (!ok) { System.err.println("FAILED: " + what); failures++; }
    }

    private static byte[] nacp() {
        byte[] n = new byte[0x4000];
        byte[] name = "S2Arm synthetic".getBytes(StandardCharsets.UTF_8);
        System.arraycopy(name, 0, n, 0, name.length);
        long id = 0x0100000000ABCDEFL;
        for (int i = 0; i < 8; i++) n[0x3038 + i] = (byte) (id >>> (8 * i));
        n[0x3060] = '0'; n[0x3061] = '.'; n[0x3062] = '1';
        return n;
    }

    private static byte[] compressedNacp(String name, int size) {
        return compressedNacp(name, size, 0);
    }

    private static byte[] compressedNacp(String name, int size, int slot) {
        byte[] raw = new byte[size];
        byte[] text = name.getBytes(StandardCharsets.UTF_8);
        System.arraycopy(text, 0, raw, slot * 0x300, text.length);
        Deflater deflater = new Deflater(9, true);
        deflater.setInput(raw); deflater.finish();
        byte[] compressed = new byte[0x2ffe];
        int length = deflater.deflate(compressed);
        if (!deflater.finished()) throw new IllegalStateException("fixture is too large");
        deflater.end();
        byte[] n = nacp();
        java.util.Arrays.fill(n, 0, 0x3000, (byte) 0);
        n[0] = (byte) length; n[1] = (byte) (length >>> 8);
        System.arraycopy(compressed, 0, n, 2, length);
        return n;
    }

    private static void names() throws Exception {
        for (String name : new String[] {"Fixture Game", "游戏 sample", "A"}) {
            GamePack.Info info = new GamePack.Info();
            GamePack.describe(info, compressedNacp(name, 0x6000));
            check(info.name.equals(name), "compressed name " + name);
            GamePack.Info later = new GamePack.Info();
            GamePack.describe(later, compressedNacp(name, 0x6000, 14));
            check(later.name.equals(name), "compressed later name " + name);
        }
        for (int size : new int[] {0x5fff, 0x6001, 0x12000}) {
            GamePack.Info shown = new GamePack.Info(); GamePack.describe(shown, compressedNacp("Fixture", size));   // 名字解不出不挡导入（不堵门）
            check(!shown.titleId.isEmpty() && !shown.name.isEmpty() && shown.name.chars().noneMatch(c -> c < 32), "invalid inflate size " + size + ": imported, name falls back");
        }
        byte[] corrupt = compressedNacp("Fixture", 0x6000);
        java.util.Arrays.fill(corrupt, 2, 6, (byte) 0xff);
        { GamePack.Info shown = new GamePack.Info(); GamePack.describe(shown, corrupt);   // 名字解不出不挡导入（不堵门）
          check(!shown.titleId.isEmpty() && !shown.name.isEmpty() && shown.name.chars().noneMatch(c -> c < 32), "invalid deflate: imported, name falls back"); }
        byte[] truncated = compressedNacp("Fixture", 0x6000);
        int length = (truncated[0] & 0xff) | ((truncated[1] & 0xff) << 8);
        truncated[0] = (byte) (length - 1); truncated[1] = (byte) ((length - 1) >>> 8);
        { GamePack.Info shown = new GamePack.Info(); GamePack.describe(shown, truncated);   // 名字解不出不挡导入（不堵门）
          check(!shown.titleId.isEmpty() && !shown.name.isEmpty() && shown.name.chars().noneMatch(c -> c < 32), "truncated deflate: imported, name falls back"); }
        byte[] trailing = compressedNacp("Fixture", 0x6000);
        length = (trailing[0] & 0xff) | ((trailing[1] & 0xff) << 8);
        trailing[2 + length] = (byte) 0xff;
        trailing[0] = (byte) (length + 1); trailing[1] = (byte) ((length + 1) >>> 8);
        { GamePack.Info shown = new GamePack.Info(); GamePack.describe(shown, trailing);   // 名字解不出不挡导入（不堵门）
          check(!shown.titleId.isEmpty() && !shown.name.isEmpty() && shown.name.chars().noneMatch(c -> c < 32), "trailing deflate: imported, name falls back"); }
        byte[] oversized = nacp(); oversized[0] = (byte) 0xff; oversized[1] = 0x2f; oversized[2] = (byte) 0xff; oversized[3] = 0;
        { GamePack.Info shown = new GamePack.Info(); GamePack.describe(shown, oversized);   // 名字解不出不挡导入（不堵门）
          check(!shown.titleId.isEmpty() && !shown.name.isEmpty() && shown.name.chars().noneMatch(c -> c < 32), "oversized length: imported, name falls back"); }
        try { GamePack.describe(new GamePack.Info(), new byte[0x306f]); check(false, "short nacp accepted"); }
        catch (GamePack.BadPack expected) { }
        byte[] invalid = nacp(); invalid[0] = 1; invalid[1] = 'A'; invalid[2] = 0;   // 名字带控制字符：退回程序号
        { GamePack.Info shown = new GamePack.Info(); GamePack.describe(shown, invalid);   // 名字解不出不挡导入（不堵门）
          check(!shown.titleId.isEmpty() && !shown.name.isEmpty() && shown.name.chars().noneMatch(c -> c < 32), "invalid controls: imported, name falls back"); }
    }

    private static Map<String, byte[]> valid() {
        Map<String, byte[]> files = new LinkedHashMap<>();
        files.put("exefs/main.npdm", new byte[128]);
        files.put("romfs/readme.txt", "hello\n".getBytes(StandardCharsets.UTF_8));
        files.put("ctl/control.nacp", nacp());
        files.put("modules/main.patched.bin", new byte[4096]);
        files.put("modules/main.fixups.tsv", "# BUILD_ID\t00\n# TARGET\tandroid\n# PATCH_OFF\t0x10000\n".getBytes(StandardCharsets.UTF_8));
        files.put("modules/main.gates.tsv", "0x100f0\tsvc\t1\t0x128\n".getBytes(StandardCharsets.UTF_8));
        files.put("modules/main.npdm", new byte[128]);
        return files;
    }

    // Writes files + index.tsv + manifest.json (pack/pack.py format); indexEdit / manifestEdit tamper with them.
    private static File write(Map<String, byte[]> files, String indexExtra, boolean badManifest) throws IOException {
        File dir = Files.createTempDirectory("s2a-pack").toFile();
        StringBuilder index = new StringBuilder();
        long total = 0;
        for (Map.Entry<String, byte[]> e : files.entrySet()) {
            File f = new File(dir, e.getKey());
            f.getParentFile().mkdirs();
            try (FileOutputStream out = new FileOutputStream(f)) { out.write(e.getValue()); }
            index.append(e.getKey()).append('\t').append(e.getValue().length).append('\t').append(GamePack.sha256(e.getValue())).append('\n');
            total += e.getValue().length;
        }
        int count = files.size();
        if (indexExtra != null) { index.append(indexExtra); count++; total += Long.parseLong(indexExtra.split("\t")[1]); }
        byte[] ix = index.toString().getBytes(StandardCharsets.UTF_8);
        Files.write(new File(dir, "index.tsv").toPath(), ix);
        String sha = badManifest ? GamePack.sha256(new byte[1]) : GamePack.sha256(ix);
        Files.write(new File(dir, "manifest.json").toPath(), String.format(
            "{\n \"version\": 2,\n \"files\": %d,\n \"total\": %d,\n \"index_sha256\": \"%s\"\n}", count, total, sha).getBytes(StandardCharsets.UTF_8));
        return dir;
    }

    private static void rejects(File dir, String why, String expect) {
        try {
            GamePack.verifyDirectory(dir, null);
            check(false, why + ": accepted");
        } catch (GamePack.BadPack e) {
            check(e.getMessage().contains(expect), why + ": " + e.getMessage());
        } catch (IOException e) {
            check(false, why + ": " + e);
        }
    }

    public static void main(String[] args) throws Exception {
        names();
        GamePack.Info info = GamePack.verifyDirectory(write(valid(), null, false), null);
        check(info.titleId.equals("0100000000ABCDEF") && info.name.equals("S2Arm synthetic") && info.version.equals("0.1"), "nacp: " + info.titleId + " " + info.name + " " + info.version);
        check(info.files == 7 && info.modules.size() == 1 && info.modules.get(0).equals("main"), "counts / modules");

        File tampered = write(valid(), null, false);
        byte[] rom = Files.readAllBytes(new File(tampered, "romfs/readme.txt").toPath());
        rom[0] ^= 1;
        Files.write(new File(tampered, "romfs/readme.txt").toPath(), rom);
        rejects(tampered, "changed byte", "SHA-256");

        File stray = write(valid(), null, false);
        Files.write(new File(stray, "romfs/extra.bin").toPath(), new byte[3]);
        rejects(stray, "stray file", "outside index.tsv");

        Map<String, byte[]> noGates = valid();
        noGates.remove("modules/main.gates.tsv");
        rejects(write(noGates, null, false), "missing gates", "modules/main.gates.tsv");

        Map<String, byte[]> orphan = valid();
        orphan.put("modules/subsdk0.patched.bin", new byte[16]);
        orphan.put("modules/subsdk0.fixups.tsv", "# TARGET\tandroid\n".getBytes(StandardCharsets.UTF_8));
        rejects(write(orphan, null, false), "module without gates", "subsdk0");

        Map<String, byte[]> apple = valid();
        apple.put("modules/main.fixups.tsv", "# BUILD_ID\t00\n# PATCH_OFF\t0x10000\n".getBytes(StandardCharsets.UTF_8));
        rejects(write(apple, null, false), "Apple rewrite", "TARGET android");

        rejects(write(valid(), "../escape\t1\t" + "0".repeat(64) + "\n", false), "path traversal", "unsafe path");
        rejects(write(valid(), "romfs/readme.txt\t6\t" + "0".repeat(64) + "\n", false), "duplicate path", "twice");
        rejects(write(valid(), null, true), "manifest hash", "index_sha256");

        // A per-game APK's resource package has no modules/ at all (they are in the APK): accepted.
        Map<String, byte[]> resources = valid();
        resources.keySet().removeIf(k -> k.startsWith("modules/"));
        GamePack.Info res = GamePack.verifyDirectory(write(resources, null, false), null);
        check(res.titleId.equals("0100000000ABCDEF") && res.modules.isEmpty(), "resource package without modules: " + res.modules);
        Map<String, byte[]> noMain = valid();
        noMain.remove("modules/main.patched.bin");
        rejects(write(noMain, null, false), "some modules but no main", "modules/main.patched.bin");

        if (args.length == 1) {   // a package from tools/make_pack.py
            GamePack.Info real = GamePack.verifyDirectory(new File(args[0]), null);
            check(real.titleId.equals("0100000000ABCDEF") && real.modules.contains("main"), "make_pack.py package: " + real.titleId + " " + real.modules);
            System.out.println("make_pack.py package: " + real.name + " " + real.version + ", " + real.files + " files, " + real.bytes + " bytes, modules " + real.modules);
        }
        if (failures > 0) System.exit(1);
        System.out.println("GamePack: ok");
    }
}
