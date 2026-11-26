package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Comparator;
import java.util.stream.Stream;

/**
 * RuntimeLibrary: the APK's library unless a debuggable launch names a verified development override;
 * every failed check refuses the launch (Rejected) and never falls back to the APK's library.
 * Argument: the hash native/jni_abi.py prints for tests/JniAbiFixture.java (test.sh passes it).
 */
public final class RuntimeLibraryTest {
    private static int checks;
    private static final String APK_SHA = "ab".repeat(32);
    private static final String COMMIT = "cd".repeat(20);
    private static final String DIFF = "ef".repeat(32);
    private static final int PID = 100;

    private static void check(boolean ok, String what) {
        checks++;
        if (!ok) throw new AssertionError(what);
    }

    interface Action { Object run() throws Exception; }

    private static void rejected(Action action, String contains, String what) throws Exception {
        checks++;
        try {
            Object got = action.run();
            throw new AssertionError(what + ": accepted" + (got instanceof RuntimeLibrary ? " as " + ((RuntimeLibrary) got).line() : ""));
        } catch (RuntimeLibrary.Rejected expected) {
            if (!expected.getMessage().contains(contains))
                throw new AssertionError(what + ": wrong reason " + expected.getMessage());
        }
    }

    /**
     * A minimal AArch64 ELF64: one LOAD segment (given alignment) over the whole file, a PT_DYNAMIC with
     * DT_STRTAB / DT_SONAME (soname null: none), the string table, and a tag byte to vary the content.
     */
    private static byte[] elf(long align, String soname, int tag) {
        byte[] name = ((soname == null ? "" : soname) + "\0").getBytes(StandardCharsets.US_ASCII);
        int dyn = 64 + 2 * 56, str = dyn + 3 * 16, size = str + 1 + name.length + 1;
        ByteBuffer b = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        b.put(new byte[] {0x7f, 'E', 'L', 'F', 2, 1, 1});
        b.putShort(18, (short) 183).putLong(32, 64).putShort(54, (short) 56).putShort(56, (short) 2);
        b.putInt(64, 1).putLong(64 + 8, 0).putLong(64 + 16, 0).putLong(64 + 32, size).putLong(64 + 48, align);
        b.putInt(120, 2).putLong(120 + 8, dyn).putLong(120 + 16, dyn).putLong(120 + 32, 3 * 16).putLong(120 + 48, 8);
        b.putLong(dyn, 5).putLong(dyn + 8, str);
        if (soname != null) b.putLong(dyn + 16, 14).putLong(dyn + 24, 1);
        b.position(str + 1);
        b.put(name);
        b.put(size - 1, (byte) tag);
        return b.array();
    }

    private static byte[] good(int tag) { return elf(16384, RuntimeLibrary.FILE, tag); }

    private static String manifest(String lib, String base) {
        return "{\"libSha256\": \"" + lib + "\", \"baseApkSha256\": \"" + base + "\", \"sourceTree\": \"" + "11".repeat(20)
            + "\", \"sourceCommit\": \"" + COMMIT + "\", \"dirty\": true, \"diffSha256\": \"" + DIFF
            + "\", \"ilcConfig\": \"Release\", \"aotHost\": \"linux-arm64\", \"unstrippedSha256\": \"" + "22".repeat(32) + "\"}";
    }

    private static String sha(byte[] bytes) throws IOException {
        Path tmp = Files.createTempFile("sha", ".bin");
        Files.write(tmp, bytes);
        String s = RuntimeLibrary.sha256(tmp.toFile());
        Files.delete(tmp);
        return s;
    }

    /** dir/<name>/ with the library and its manifest, pushed the way dev_push does (0444 files, 0555 dir). */
    private static File push(File dir, String name, byte[] bytes, String libSha, String manifestBase) throws IOException {
        File d = new File(dir, name);
        Files.createDirectories(d.toPath());
        Files.write(new File(d, RuntimeLibrary.FILE).toPath(), bytes);
        Files.write(new File(d, RuntimeLibrary.MANIFEST).toPath(), manifest(libSha, manifestBase).getBytes(StandardCharsets.UTF_8));
        readOnly(d);
        return d;
    }

    private static void readOnly(File d) throws IOException {
        Files.setPosixFilePermissions(new File(d, RuntimeLibrary.FILE).toPath(), PosixFilePermissions.fromString("r--r--r--"));
        Files.setPosixFilePermissions(new File(d, RuntimeLibrary.MANIFEST).toPath(), PosixFilePermissions.fromString("r--r--r--"));
        Files.setPosixFilePermissions(d.toPath(), PosixFilePermissions.fromString("r-xr-xr-x"));
    }

    private static void writable(File d) throws IOException {
        Files.setPosixFilePermissions(d.toPath(), PosixFilePermissions.fromString("rwxr-xr-x"));
        for (File f : d.listFiles()) Files.setPosixFilePermissions(f.toPath(), PosixFilePermissions.fromString("rw-r--r--"));
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("runtime-library-test-");
        try {
            run(root.toFile(), args.length == 1 ? args[0] : null);
        } finally {
            try (Stream<Path> paths = Files.walk(root)) {   // fixtures are read-only: make writable, then delete
                paths.forEach(p -> p.toFile().setWritable(true));
            }
            try (Stream<Path> paths = Files.walk(root)) {
                paths.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
        System.out.println("RuntimeLibrary: " + checks + " checks PASS (host only; no System.load)");
    }

    private static void run(File tmp, String fixtureAbi) throws Exception {
        File files = new File(tmp, "files"), cache = new File(tmp, "code_cache"), runtime = new File(files, RuntimeLibrary.DIRECTORY);
        Files.createDirectories(runtime.toPath());
        int[] hashed = {0};
        RuntimeLibrary.ApkDigest apk = () -> { hashed[0]++; return APK_SHA; };

        // No extra: the APK's library, whatever the private directory holds; the APK is not even hashed.
        byte[] bytes = good(1);
        String goodSha = sha(bytes);
        push(runtime, goodSha, bytes, goodSha, APK_SHA);
        RuntimeLibrary plain = RuntimeLibrary.select(null, true, files, cache, PID, null, apk);
        check(!plain.override() && plain.file == null && plain.line().equals("runtime-library: apk")
            && plain.json().equals("{\"kind\": \"apk\"}"), "no extra: APK library");
        check(hashed[0] == 0, "no extra: installed APK not hashed");
        check(RuntimeLibrary.present(files) == 1, "the unused override is reported as present");

        // Debuggable + exact SHA + base APK + read-only + 16 KB + soname: a staged copy, labelled a development run.
        RuntimeLibrary dev = RuntimeLibrary.select(goodSha, true, files, cache, PID, null, apk);
        check(dev.override() && goodSha.equals(dev.sha256), "override selected");
        check(dev.file.getParentFile().getName().equals(RuntimeLibrary.STAGE)
            && dev.file.getCanonicalPath().startsWith(cache.getCanonicalPath() + "/"), "the loaded file is the code-cache copy");
        // 看权限位，不用 canWrite()：root 跑（只有 root 的 Linux 门禁机）时 canWrite() 对只读文件也是 true，验不到「副本只读」
        check(Files.getPosixFilePermissions(dev.file.toPath()).stream().noneMatch(p -> p.name().endsWith("_WRITE"))
            && goodSha.equals(RuntimeLibrary.sha256(dev.file)), "copy is read-only and has the SHA");
        check(dev.line().startsWith("runtime-library: dev-override sha256=" + goodSha + " base-apk=" + APK_SHA
            + " source-commit=" + COMMIT + " dirty=true diff=" + DIFF + " ilc=Release aot-host=linux-arm64")
            && dev.line().contains("开发局，不作性能读数"), dev.line());
        java.util.Map<String, Object> json = Json.object(Json.parse(dev.json()), "json");
        check("dev-override".equals(json.get("kind")) && goodSha.equals(json.get("sha256")) && APK_SHA.equals(json.get("baseApkSha256"))
            && Boolean.TRUE.equals(json.get("dirty")) && "linux-arm64".equals(json.get("aotHost")), "structured record " + dev.json());

        // TOCTOU: replacing the pushed file after the check does not change what would be loaded.
        File pushed = new File(runtime, goodSha + "/" + RuntimeLibrary.FILE);
        writable(pushed.getParentFile());
        Files.write(pushed.toPath(), good(99));
        check(goodSha.equals(RuntimeLibrary.sha256(dev.file)), "staged copy unaffected by a later swap");
        rejected(() -> RuntimeLibrary.select(goodSha, true, files, cache, PID, null, apk), "writable", "swapped and writable");
        readOnly(pushed.getParentFile());
        rejected(() -> RuntimeLibrary.select(goodSha, true, files, cache, PID, null, apk), "has SHA-256", "swapped bytes no longer match");
        writable(pushed.getParentFile());
        Files.write(pushed.toPath(), bytes);
        readOnly(pushed.getParentFile());
        // N1: the same process selecting again (Activity recreated) keeps its mapped copy; another library needs a cold start.
        check(RuntimeLibrary.select(goodSha, true, files, cache, PID, dev, apk) == dev && dev.file.exists(),
            "same selection in the same process reuses the loaded copy");
        rejected(() -> RuntimeLibrary.select(null, true, files, cache, PID, dev, apk), "cold start needed", "APK asked, override runs");
        rejected(() -> RuntimeLibrary.select("00".repeat(32), true, files, cache, PID, dev, apk), "cold start needed", "other SHA asked");
        check(dev.file.exists(), "a refused selection leaves the mapped copy alone");
        check(RuntimeLibrary.select(null, true, files, cache, PID, RuntimeLibrary.APK, apk) == RuntimeLibrary.APK,
            "APK process asked for the APK again");
        rejected(() -> RuntimeLibrary.select(goodSha, true, files, cache, PID, RuntimeLibrary.APK, apk), "cold start needed",
            "override asked, APK runs");
        // An actual live process in the same app can own a mapped copy in the shared cache.
        File live = new File(new File(cache, RuntimeLibrary.STAGE),
            "aaaaaaaaaaaaaaaa-" + ProcessHandle.current().pid() + "-live.so");
        Files.write(live.toPath(), new byte[] {1});
        RuntimeLibrary.select(null, true, files, cache, PID + 2, null, apk);
        check(live.exists(), "a different live process keeps its staged copy");

        // Exercise actual process death on procfs hosts; without procfs cleanup must preserve files.
        Process exited = new ProcessBuilder("true").start();
        long deadPid = exited.pid();
        check(exited.waitFor() == 0, "dead process fixture exited");
        File dead = new File(new File(cache, RuntimeLibrary.STAGE),
            "bbbbbbbbbbbbbbbb-" + deadPid + "-dead.so");
        Files.write(dead.toPath(), new byte[] {1});
        boolean procAvailable = Files.isDirectory(Path.of("/proc/self"));
        boolean pidReused = Files.exists(Path.of("/proc", Long.toString(deadPid)));
        RuntimeLibrary.select(null, true, files, cache, PID + 2, null, apk);
        check(dead.exists() == (!procAvailable || pidReused),
            "cleanup removes only owners proven dead");
        RuntimeLibrary again = RuntimeLibrary.select(goodSha, true, files, cache, PID + 1, null, apk);

        // Process binding (singleTop): later intents must ask for what runs.
        check(RuntimeLibrary.requested(false, null) == null && "".equals(RuntimeLibrary.requested(true, null))
            && "x".equals(RuntimeLibrary.requested(true, "x")), "requested: absent / non-string / string");
        check(plain.selectedBy(null) && !plain.selectedBy(goodSha) && !plain.selectedBy(""), "APK process: only no extra");
        check(dev.selectedBy(goodSha) && !dev.selectedBy(null) && !dev.selectedBy("00".repeat(32)), "override process: same SHA only");
        java.util.Set<String> controls = new java.util.HashSet<>(java.util.Arrays.asList("s2arm.finish", "s2arm.fps"));
        check(!RuntimeLibrary.isLaunch(java.util.Arrays.asList("s2arm.finish"), controls)
            && !RuntimeLibrary.isLaunch(java.util.Arrays.asList("s2arm.fps", "s2arm.finish", "android.intent.extra.REFERRER"), controls),
            "control intents: only control extras");
        check(RuntimeLibrary.isLaunch(java.util.Collections.emptyList(), controls)
            && RuntimeLibrary.isLaunch(java.util.Arrays.asList("android.intent.extra.REFERRER"), controls)
            && RuntimeLibrary.isLaunch(java.util.Arrays.asList("s2arm.finish", RuntimeLibrary.EXTRA), controls)
            && RuntimeLibrary.isLaunch(java.util.Arrays.asList("s2arm.console_mode"), controls),
            "launches: plain am start, a named library, a cold-start extra");

        // Negative controls: each refuses; none returns the APK's library instead.
        rejected(() -> RuntimeLibrary.select(goodSha, false, files, cache, PID, null, apk), "debuggable", "non-debuggable package");
        rejected(() -> RuntimeLibrary.select(goodSha, true, files, cache, PID, null, () -> "99".repeat(32)), "reinstall the APK", "base APK SHA mismatch");
        rejected(() -> RuntimeLibrary.select("", true, files, cache, PID, null, apk), "not a lowercase SHA-256", "--ez / empty extra");
        rejected(() -> RuntimeLibrary.select(goodSha.toUpperCase(), true, files, cache, PID, null, apk), "not a lowercase SHA-256", "uppercase SHA");
        rejected(() -> RuntimeLibrary.select("../" + goodSha.substring(3), true, files, cache, PID, null, apk), "not a lowercase SHA-256", "path in the extra");
        rejected(() -> RuntimeLibrary.select("00".repeat(32), true, files, cache, PID, null, apk), "is missing", "extra names no pushed library");

        String wrong = "77".repeat(32);   // a directory named for another SHA
        push(runtime, wrong, good(2), wrong, APK_SHA);
        rejected(() -> RuntimeLibrary.select(wrong, true, files, cache, PID, null, apk), "has SHA-256", "library SHA differs from the extra");

        for (Object[] c : new Object[][] {{elf(4096, RuntimeLibrary.FILE, 3), "16 KB", "LOAD aligned to 4 KB"},
                                          {elf(16384, "libother.so", 4), "DT_SONAME", "shorter soname"},
                                          {elf(16384, "libs2arm_androix.so", 9), "DT_SONAME", "same-length other soname"},
                                          {elf(16384, null, 5), "DT_SONAME", "no soname"}}) {
            byte[] b = (byte[]) c[0];
            String s = sha(b);
            push(runtime, s, b, s, APK_SHA);
            rejected(() -> RuntimeLibrary.select(s, true, files, cache, PID, null, apk), (String) c[1], (String) c[2]);
        }

        byte[] w = good(6);
        String writableSha = sha(w);
        File wd = push(runtime, writableSha, w, writableSha, APK_SHA);
        Files.setPosixFilePermissions(new File(wd, RuntimeLibrary.FILE).toPath(), PosixFilePermissions.fromString("rw-r--r--"));
        rejected(() -> RuntimeLibrary.select(writableSha, true, files, cache, PID, null, apk), "writable", "library not read-only");
        readOnly(wd);
        Files.setPosixFilePermissions(wd.toPath(), PosixFilePermissions.fromString("rwxr-xr-x"));
        rejected(() -> RuntimeLibrary.select(writableSha, true, files, cache, PID, null, apk), "writable", "directory writable");

        byte[] m = good(7);
        String manifestSha = sha(m);
        File md = push(runtime, manifestSha, m, "88".repeat(32), APK_SHA);
        rejected(() -> RuntimeLibrary.select(manifestSha, true, files, cache, PID, null, apk), "libSha256", "manifest names another library");
        writable(md);
        Files.write(new File(md, RuntimeLibrary.MANIFEST).toPath(),
            ("{\"libSha256\": \"" + manifestSha + "\", \"baseApkSha256\": \"" + APK_SHA + "\"}").getBytes(StandardCharsets.UTF_8));
        readOnly(md);
        rejected(() -> RuntimeLibrary.select(manifestSha, true, files, cache, PID, null, apk), "sourceCommit", "manifest without the build identity");

        // Links: the library, the manifest, the <sha> directory and files/dev-runtime itself.
        File outside = new File(tmp, "outside");
        byte[] l = good(8);
        String linkSha = sha(l);
        File real = push(outside, linkSha, l, linkSha, APK_SHA);
        File ld = new File(runtime, linkSha);
        Files.createSymbolicLink(ld.toPath(), real.toPath());
        rejected(() -> RuntimeLibrary.select(linkSha, true, files, cache, PID, null, apk), "symbolic link", "<sha> directory is a link");
        Files.delete(ld.toPath());
        Files.createDirectories(ld.toPath());
        Files.createSymbolicLink(new File(ld, RuntimeLibrary.FILE).toPath(), new File(real, RuntimeLibrary.FILE).toPath());
        Files.copy(new File(real, RuntimeLibrary.MANIFEST).toPath(), new File(ld, RuntimeLibrary.MANIFEST).toPath());
        rejected(() -> RuntimeLibrary.select(linkSha, true, files, cache, PID, null, apk), "symbolic link", "library is a link");
        Files.delete(new File(ld, RuntimeLibrary.FILE).toPath());
        Files.copy(new File(real, RuntimeLibrary.FILE).toPath(), new File(ld, RuntimeLibrary.FILE).toPath());
        Files.delete(new File(ld, RuntimeLibrary.MANIFEST).toPath());
        Files.createSymbolicLink(new File(ld, RuntimeLibrary.MANIFEST).toPath(), new File(real, RuntimeLibrary.MANIFEST).toPath());
        rejected(() -> RuntimeLibrary.select(linkSha, true, files, cache, PID, null, apk), "symbolic link", "manifest is a link");
        // The reviewer's probe: files/dev-runtime -> a directory outside the private files holding a valid push.
        File files2 = new File(tmp, "files2");
        Files.createDirectories(files2.toPath());
        Files.createSymbolicLink(new File(files2, RuntimeLibrary.DIRECTORY).toPath(), outside.toPath());
        rejected(() -> RuntimeLibrary.select(linkSha, true, files2, cache, PID, null, apk), "symbolic link", "files/dev-runtime is a link");

        // After the load: JNI must be bound to the selected file.
        String apkPath = new File(tmp, "app/base.apk").getPath(), libDir = new File(tmp, "app/lib/arm64").getPath();
        Files.createDirectories(new File(tmp, "app/lib/arm64").toPath());
        Files.createSymbolicLink(new File(tmp, "app-link").toPath(), new File(tmp, "app").toPath());
        RuntimeLibrary.verifyLoaded(again, again.file.getAbsolutePath(), apkPath, null, libDir);
        RuntimeLibrary.verifyLoaded(RuntimeLibrary.APK, apkPath + "!/lib/arm64-v8a/libs2arm_android.so", apkPath, null, libDir);
        // sourceDir reached through a link; dladdr reports the real path
        RuntimeLibrary.verifyLoaded(RuntimeLibrary.APK, new File(tmp, "app/base.apk").getCanonicalPath() + "!/lib/arm64-v8a/libs2arm_android.so",
            new File(tmp, "app-link/base.apk").getPath(), null, libDir);
        String split = new File(tmp, "app/split_config.arm64_v8a.apk").getPath();
        RuntimeLibrary.verifyLoaded(RuntimeLibrary.APK, split + "!/lib/arm64-v8a/libs2arm_android.so", apkPath, new String[] {split}, libDir);
        RuntimeLibrary.verifyLoaded(RuntimeLibrary.APK, libDir + "/libs2arm_android.so", apkPath, null, libDir);
        checks += 5;
        rejected(() -> { RuntimeLibrary.verifyLoaded(again, apkPath + "!/lib/arm64-v8a/libs2arm_android.so", apkPath, null, libDir);
            return null; }, "not to the override", "override asked, APK copy bound");
        rejected(() -> { RuntimeLibrary.verifyLoaded(RuntimeLibrary.APK, pushed.getPath(), apkPath, null, libDir);
            return null; }, "not this APK's library", "APK asked, pushed file bound");
        rejected(() -> { RuntimeLibrary.verifyLoaded(RuntimeLibrary.APK, split + "!/lib/arm64-v8a/libs2arm_android.so", apkPath, null, libDir);
            return null; }, "not this APK's library", "split not part of this install");
        rejected(() -> { RuntimeLibrary.verifyLoaded(RuntimeLibrary.APK, "", apkPath, null, libDir); return null; },
            "no path", "dladdr gave no path");

        // JNI ABI: reflection here == native/jni_abi.py over the source (the hash baked into the library).
        String abi = RuntimeLibrary.jniAbi(JniAbiFixture.class);
        check(abi.matches("[0-9a-f]{64}"), "jniAbi is a SHA-256");
        if (fixtureAbi != null) check(abi.equals(fixtureAbi), "reflection " + abi + " != jni_abi.py " + fixtureAbi);
        check(!abi.equals(RuntimeLibrary.jniAbi(RuntimeLibraryTest.class)), "a class without natives differs");
    }
}
