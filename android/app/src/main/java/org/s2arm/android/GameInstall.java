package org.s2arm.android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TimeZone;

/**
 * The install transaction for a game package (implementation plan §6.5, A0 contracts): build
 * games/&lt;title id&gt;/revisions/&lt;content root&gt;.staging, validate that revision with BootContract,
 * rename it into place, then switch current.json with a temp file and a rename. A failure or a
 * killed process at any point leaves the previous current.json and its revision as they were;
 * stale .staging directories are swept at startup. Keeps the active revision and the one it
 * replaced (previousContentRoot, for rollback), removes older ones.
 *
 * <p>Revisions share storage: every file is stored once under its SHA-256 in
 * games/&lt;title id&gt;/objects/ (copied in with its size and hash checked, then read-only), and a
 * revision's files are hard links to those objects (a hard link is an ordinary directory entry, so
 * readers that refuse symbolic links see regular files; the links survive the .staging rename and
 * a move of the app's data). An update costs only the files it changes, and keeping the previous
 * revision costs only the files that differ. Objects no revision uses are removed after each
 * install and at startup. Where hard links are refused, the file is copied into the revision
 * instead: one file at a time when only that path is refused, and every file (with no object
 * store) when the storage cannot hard-link at all. No Android types, so the unit test runs on a
 * plain JDK.
 */
final class GameInstall {
    /** Where the package files come from: a directory (adb import/) or a picked document tree. */
    interface Source {
        /** null when the package has no such file. */
        InputStream open(String path) throws IOException;
    }

    interface Progress { void update(long done, long total); }

    /** Creates one hard link. The host test substitutes a failing implementation to exercise copies. */
    interface Linker { void link(File link, File target) throws IOException; }

    private static final Linker HARD_LINK = (link, target) -> Files.createLink(link.toPath(), target.toPath());

    static final String ARTIFACT = GamePack.ARTIFACT;

    static final class Result {
        final String titleId, contentRoot, previousContentRoot;
        final GamePack.Info info;
        final boolean alreadyActive;
        boolean artifactRefreshed;       // same files, new artifact (e.g. a per-game APK upgrade)
        long storedBytes, sharedBytes;   // copied in this time / already stored (unchanged files)
        boolean linked;                  // revision files are hard links to shared objects (else plain copies)
        Result(String titleId, String contentRoot, String previousContentRoot, GamePack.Info info, boolean alreadyActive) {
            this.titleId = titleId; this.contentRoot = contentRoot; this.previousContentRoot = previousContentRoot;
            this.info = info; this.alreadyActive = alreadyActive;
        }
    }

    private GameInstall() { }

    /** Both queues use the same installer. Internal files stay private, including in debug builds. */
    static File[] importDirectories(File internalFiles, File externalFiles) {
        File internal = new File(internalFiles, "import");
        return externalFiles == null || internalFiles.equals(externalFiles)
            ? new File[] {internal} : new File[] {internal, new File(externalFiles, "import")};
    }

    interface ImportListener {
        void installed(File source, Result result);
        void refused(File source, Exception error);
        default void cleanupDeferred(File source, IOException error) { }
    }

    interface ImportSourceCheck {
        Source checked(Source source) throws IOException;
    }

    static Source checkedImportSource(Source source, String installedPackage,
            boolean debuggable, boolean debugEntriesOpen) {
        return path -> {
            java.io.InputStream input = source.open(path);
            if (input == null || !ARTIFACT.equals(path)) return input;
            byte[] bytes;
            try (java.io.InputStream in = input) { bytes = GamePack.readAll(in); }
            try { BootContract.checkTestImport(bytes, installedPackage, debuggable, debugEntriesOpen); }
            catch (BootContract.BadGame invalid) { throw new IOException(invalid.getMessage(), invalid); }
            return new java.io.ByteArrayInputStream(bytes);
        };
    }

    /** One explicit target only; validation, activation and cleanup share the session lease. */
    static void importDirectory(File privateRoot, File[] inboxes, String target,
            Progress progress, ImportListener listener) throws IOException {
        importDirectory(privateRoot, inboxes, target,
            source -> checkedImportSource(source, null, false, false), progress, listener);
    }

    /** Apply admission to the exact artifact stream before installation writes, under the lease. */
    static void importDirectory(File privateRoot, File[] inboxes, String target,
            ImportSourceCheck sourceCheck, Progress progress, ImportListener listener) throws IOException {
        if (target == null) return;
        {   // 不再取整库锁：install 拿到程序号后只锁那一款
            File dir = new File(target);
            try {
                Path path = dir.toPath();
                if (!path.isAbsolute()) throw new IOException("import target must be an absolute path");
                for (Path part : path)
                    if (part.toString().equals("..")) throw new IOException("import target contains ..");
                boolean allowed = false;
                for (File inbox : inboxes) {
                    File canonicalInbox = inbox.getCanonicalFile();
                    if (!Files.isSymbolicLink(inbox.toPath())
                            && canonicalInbox.equals(dir.getCanonicalFile().getParentFile())) {
                        // System aliases above the Context root (for example /sdcard) are valid.
                        // Never let a descendant symlink return to that root and masquerade as
                        // a direct child: the first occurrence of the root must be the parent.
                        boolean nestedAlias = false;
                        for (File ancestor = dir.getParentFile().getParentFile(); ancestor != null;
                                ancestor = ancestor.getParentFile()) {
                            for (File root : inboxes)
                                if (root.getCanonicalFile().equals(ancestor.getCanonicalFile())) nestedAlias = true;
                        }
                        if (!nestedAlias) allowed = true;
                    }
                }
                if (!allowed || Files.isSymbolicLink(path) || Files.isSymbolicLink(path.getParent()))
                    throw new IOException("import target escapes its staging parent or is a symbolic link");
                // A consumed target is a no-op. Incomplete packages wait for manifest-last staging.
                if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return;
                if (!dir.isDirectory()) throw new IOException("import target is not a directory");
                if (!new File(dir, "manifest.json").isFile()) return;
                Result result = install(new File(privateRoot, "games"), sourceCheck.checked(directory(dir)), progress);
                try {
                    Files.walkFileTree(path, new java.nio.file.SimpleFileVisitor<Path>() {
                        @Override public java.nio.file.FileVisitResult visitFile(Path file,
                                java.nio.file.attribute.BasicFileAttributes attrs) throws IOException {
                            Files.delete(file);
                            return java.nio.file.FileVisitResult.CONTINUE;
                        }
                        @Override public java.nio.file.FileVisitResult postVisitDirectory(Path directory,
                                IOException error) throws IOException {
                            if (error != null) throw error;
                            Files.delete(directory);
                            return java.nio.file.FileVisitResult.CONTINUE;
                        }
                    });
                } catch (IOException cleanup) {
                    // Activation has committed. Do not report cleanup as an installation failure.
                    listener.cleanupDeferred(dir, cleanup);
                }
                listener.installed(dir, result);
            } catch (GamePack.BadPack | BootContract.BadGame | IOException | RuntimeException error) {
                listener.refused(dir, error);
            }
        }
    }

    static Source directory(File dir) {
        Path root = dir.toPath().toAbsolutePath().normalize();
        return path -> {
            Path relative = root.getFileSystem().getPath(path);
            if (relative.isAbsolute()) throw new IOException("package path escapes its directory");
            for (Path segment : relative)
                if (segment.toString().equals("..")) throw new IOException("package path escapes its directory");
            Path file = root.resolve(relative).normalize();
            if (!file.startsWith(root) || file.equals(root))
                throw new IOException("package path escapes its directory");
            // Source packages contain regular files. Installed revisions may still use the
            // installer's checked object-store links; those are validated separately by A0.
            Path part = root;
            if (Files.isSymbolicLink(part)) throw new IOException("package directory is a symbolic link");
            for (Path segment : root.relativize(file)) {
                part = part.resolve(segment);
                if (Files.isSymbolicLink(part)) throw new IOException("package source contains a symbolic link");
            }
            return Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)
                ? Files.newInputStream(file) : null;
        };
    }

    static Result install(File gamesDir, Source source, Progress progress)
            throws GamePack.BadPack, BootContract.BadGame, IOException {
        return install(gamesDir, source, progress, HARD_LINK);
    }

    static Result install(File gamesDir, Source source, Progress progress, Linker linker)
            throws GamePack.BadPack, BootContract.BadGame, IOException {
        byte[] manifest = required(source, "manifest.json");
        byte[] index = required(source, "index.tsv");
        byte[] artifact;
        try (InputStream in = source.open(ARTIFACT)) {
            if (in == null) throw new GamePack.BadPack("package has no " + ARTIFACT + " (build it with the current tools/make_pack.py)");
            artifact = GamePack.readAll(in);
        }
        List<GamePack.Entry> entries = GamePack.readIndex(manifest, index);
        String contentRoot = "sha256-" + GamePack.sha256(index);

        // The title id names the directory, so read control.nacp first (checked against the index like every file).
        GamePack.Info info = new GamePack.Info();
        GamePack.describe(info, verified(source, entry(entries, "ctl/control.nacp")));
        // 只锁这一款（不堵门）：别的游戏在跑不挡本款导入；本款正在跑 / 正在装才报忙
        try (GameStorage lease = GameStorage.acquireIn(gamesDir, info.titleId)) {
            return installLocked(gamesDir, source, progress, linker, manifest, index, artifact, entries, contentRoot, info);
        }
    }

    private static Result installLocked(File gamesDir, Source source, Progress progress, Linker linker, byte[] manifest, byte[] index,
            byte[] artifact, List<GamePack.Entry> entries, String contentRoot, GamePack.Info info)
            throws GamePack.BadPack, BootContract.BadGame, IOException {
        File gameRoot = new File(gamesDir, info.titleId);
        File revisions = new File(gameRoot, "revisions");
        File active = new File(revisions, contentRoot), staging = new File(revisions, contentRoot + ".staging");
        BootContract.Current current = readCurrent(gameRoot);
        String previous = current == null ? null : current.contentRoot;
        if (current != null && contentRoot.equals(previous) && active.isDirectory()) {
            if (GamePack.sha256(artifact).equals(current.artifactSha256))
                return new Result(info.titleId, contentRoot, previous, info, true);
            return refreshArtifact(gameRoot, current, artifact, info);
        }

        Result result = new Result(info.titleId, contentRoot, contentRoot.equals(previous) ? null : previous, info, false);
        File objects = new File(gameRoot, "objects");
        deleteTree(staging);
        if (!staging.mkdirs()) throw new IOException("cannot create " + staging);
        result.linked = canLink(objects, linker);
        GameFingerprint.Reference fingerprint;
        try {
            long total = 0;
            for (GamePack.Entry e : entries) total += e.size;
            long[] done = {0};
            byte[] buf = new byte[1 << 20];
            for (GamePack.Entry e : entries) {
                File out = new File(staging, e.path);
                out.getParentFile().mkdirs();
                if (!result.linked) {   // no shared store here: a checked copy in the revision itself
                    store(source, e, out, new File(objects, "tmp"), buf, progress, done, total);
                    result.storedBytes += e.size;
                    continue;
                }
                File object = new File(objects, e.sha256.substring(0, 2) + "/" + e.sha256);
                if (object.isFile() && object.length() == e.size) {   // stored by an earlier install, checked then
                    result.sharedBytes += e.size;
                    done[0] += e.size;
                    if (progress != null) progress.update(done[0], total);
                } else {
                    store(source, e, object, new File(objects, "tmp"), buf, progress, done, total);
                    result.storedBytes += e.size;
                }
                try {
                    linker.link(out, object);
                } catch (IOException | UnsupportedOperationException | SecurityException linkFailure) {
                    // This path refuses a hard link (e.g. a SELinux label) although the probe
                    // worked: keep the install usable by copying the already verified object.
                    copyObject(object, out);
                }
            }
            writeSynced(new File(staging, "manifest.json"), manifest);
            writeSynced(new File(staging, "index.tsv"), index);
            writeSynced(new File(staging, ARTIFACT), artifact);
            BootContract.validateRevision(gameRoot, "revisions/" + contentRoot + ".staging", contentRoot, ARTIFACT, GamePack.sha256(artifact));
            // Existing CAS objects were formerly only size-checked. Verify the actual
            // installed bytes before a fingerprint can attest to any of them.
            GameFingerprint.Verification checked = GameFingerprint.verify(staging, entries, contentRoot.substring(7), null);
            fingerprint = GameFingerprint.write(staging, entries, contentRoot.substring(7), checked.stamps);

            deleteTree(active);   // same content root but not active: a leftover, replaced by the checked copy
            if (!staging.renameTo(active)) throw new IOException("cannot move the staged revision into place");
        } catch (GamePack.BadPack | BootContract.BadGame | IOException | RuntimeException e) {
            deleteTree(staging);
            throw e;
        }
        writeCurrent(gameRoot, info.titleId, contentRoot, ARTIFACT, GamePack.sha256(artifact), result.previousContentRoot, fingerprint);
        BootContract.open(gameRoot);   // what the runtime will read
        prune(gameRoot, contentRoot, result.previousContentRoot);
        return result;
    }

    // One package file into the object store: copied with its size and SHA-256 checked, flushed,
    // renamed into place and made read-only (objects are never changed, only linked and removed).
    private static void store(Source source, GamePack.Entry e, File object, File tmpDir, byte[] buf,
                              Progress progress, long[] done, long total) throws IOException, GamePack.BadPack {
        tmpDir.mkdirs();
        File tmp = File.createTempFile("object", null, tmpDir);
        try {
            MessageDigest md = GamePack.digest();
            long size = 0;
            try (InputStream in = source.open(e.path); FileOutputStream os = new FileOutputStream(tmp)) {
                if (in == null) throw new GamePack.BadPack("package has no " + e.path);
                for (int n; (n = in.read(buf)) > 0; ) {
                    md.update(buf, 0, n); os.write(buf, 0, n); size += n; done[0] += n;
                    if (progress != null) progress.update(done[0], total);
                }
                os.getFD().sync();
            }
            if (size != e.size || !GamePack.hex(md.digest()).equals(e.sha256))
                throw new GamePack.BadPack(e.path + " does not match index.tsv (size / SHA-256)");
            object.getParentFile().mkdirs();
            if (!tmp.renameTo(object)) throw new IOException("cannot store " + e.path);
            object.setReadOnly();
        } finally {
            tmp.delete();   // gone already after the rename
        }
    }

    // A hard link refused for one file after the probe succeeded: copy the stored object into the
    // revision. The object was verified when it was stored, so its bytes are already trusted.
    private static void copyObject(File object, File out) throws IOException {
        try (InputStream in = new java.io.FileInputStream(object); FileOutputStream os = new FileOutputStream(out)) {
            byte[] buf = new byte[1 << 20];
            for (int n; (n = in.read(buf)) > 0; ) os.write(buf, 0, n);
            os.getFD().sync();
        }
        out.setReadOnly();
    }

    // Whether this storage lets the app create hard links (probed once per install).
    private static boolean canLink(File objects, Linker linker) {
        File probe = new File(objects, "tmp/link-probe"), target = new File(objects, "tmp/link-target");
        try {
            probe.getParentFile().mkdirs();
            probe.delete();
            target.delete();
            try (FileOutputStream out = new FileOutputStream(target)) { out.write(0); }
            linker.link(probe, target);
            return true;
        } catch (UnsupportedOperationException | SecurityException | IOException e) {
            return false;
        } finally {
            probe.delete();
            target.delete();
        }
    }

    /**
     * Startup: a .staging revision is an install that never finished; nothing points at it.
     * Objects it stored stay until no revision needs them (a retry reuses them), then go too.
     */
    static int sweep(File gamesDir) {
        int removed = 0;
        File[] games = gamesDir.listFiles(File::isDirectory);
        if (games != null) for (File g : games) {
            // 逐款取锁：这一款正在跑 / 正在装就跳过（下次再清），不碰它的半成品
            try (GameStorage lease = GameStorage.acquireIn(gamesDir, g.getName())) {
                File[] staged = new File(g, "revisions").listFiles(f -> f.getName().endsWith(".staging"));
                if (staged != null) for (File s : staged) { deleteTree(s); removed++; }
                new File(g, "current.json.tmp").delete();
                collect(g);
            } catch (IOException busyOrForeign) {
                System.err.println("S2Arm: library cleanup skipped " + g.getName() + ": " + busyOrForeign.getMessage());
            }
        }
        return removed;
    }

    // The active version, or null (none yet, or a current.json BootContract cannot read).
    private static BootContract.Current readCurrent(File gameRoot) {
        if (!new File(gameRoot, "current.json").isFile()) return null;
        try {
            return BootContract.readCurrent(gameRoot);
        } catch (BootContract.BadGame | IOException e) {
            return null;
        }
    }

    // current.json's previousContentRoot (kept across an artifact refresh), or null.
    private static String previousRoot(File gameRoot) {
        try {
            Object v = Json.object(Json.parse(new String(GamePack.read(new File(gameRoot, "current.json")), StandardCharsets.UTF_8)),
                                   "current.json").get("previousContentRoot");
            return v instanceof String ? (String) v : null;
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }

    /*
     * Same files, new artifact: a per-game APK upgrade changes apk.versionCode / sha256 without
     * touching the resource files, so the content root is the same. The new artifact goes beside
     * the old one under its own name, is validated, and current.json switches to it; the old one
     * is removed after. A failure leaves the old artifact active.
     */
    private static Result refreshArtifact(File gameRoot, BootContract.Current current, byte[] artifact, GamePack.Info info)
            throws BootContract.BadGame, IOException {
        String sha = GamePack.sha256(artifact);
        String name = "game-build-artifact." + sha.substring(0, 16) + ".json";
        File revision = new File(gameRoot, current.revisionDir), file = new File(revision, name);
        writeSynced(file, artifact);
        try {
            BootContract.validateRevision(gameRoot, current.revisionDir, current.contentRoot, name, sha);
        } catch (BootContract.BadGame | IOException | RuntimeException e) {
            file.delete();
            throw e;
        }
        String previous = previousRoot(gameRoot);
        GameFingerprint.Reference fingerprint = GameFingerprint.currentReference(gameRoot, current.contentRoot.substring(7));
        writeCurrent(gameRoot, info.titleId, current.contentRoot, name, sha, previous, fingerprint);
        BootContract.open(gameRoot);
        if (!current.artifact.equals(name)) new File(revision, current.artifact).delete();
        Result r = new Result(info.titleId, current.contentRoot, previous, info, false);
        r.artifactRefreshed = true;
        return r;
    }

    private static void writeCurrent(File gameRoot, String titleId, String contentRoot, String artifactRel, String artifactSha,
                                     String previous, GameFingerprint.Reference fingerprint) throws IOException {
        SimpleDateFormat utc = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT);
        utc.setTimeZone(TimeZone.getTimeZone("UTC"));
        // Every value is a fixed word, hex or a timestamp: no JSON escaping needed.
        String json = "{\n \"version\": 1,\n \"titleId\": \"" + titleId + "\",\n \"contentRoot\": \"" + contentRoot + "\",\n"
            + " \"revisionDir\": \"revisions/" + contentRoot + "\",\n \"artifact\": \"" + artifactRel + "\",\n"
            + " \"artifactSha256\": \"" + artifactSha + "\",\n \"activatedAt\": \"" + utc.format(new Date()) + "\",\n"
            + " \"previousContentRoot\": " + (previous == null ? "null" : "\"" + previous + "\"")
            + (fingerprint == null ? "" : ",\n \"fingerprint\": {\"version\":1,\"path\":\"" + fingerprint.path
                + "\",\"sha256\":\"" + fingerprint.sha256 + "\",\"indexSha256\":\"" + fingerprint.indexSha256 + "\"}") + "\n}\n";
        File tmp = new File(gameRoot, "current.json.tmp");
        if (Files.exists(tmp.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)
                && !Files.isRegularFile(tmp.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS))
            throw new IOException("current temporary file is not regular");
        writeSynced(tmp, json.getBytes(StandardCharsets.UTF_8));
        if (!tmp.renameTo(new File(gameRoot, "current.json"))) throw new IOException("cannot activate current.json");
    }

    // Keep the active revision and the one it replaced; then the objects only removed ones used.
    private static void prune(File gameRoot, String keep, String previous) {
        File[] all = new File(gameRoot, "revisions").listFiles(File::isDirectory);
        if (all != null) for (File r : all)
            if (!r.getName().equals(keep) && !r.getName().equals(previous)) deleteTree(r);
        collect(gameRoot);
    }

    // Removes objects no remaining revision lists (and object temp files). An unreadable index
    // keeps everything: better a leftover object than a revision missing a file.
    private static void collect(File gameRoot) {
        Set<String> used = new HashSet<>();
        File[] kept = new File(gameRoot, "revisions").listFiles(f -> f.isDirectory() && !f.getName().endsWith(".staging"));
        if (kept != null) for (File r : kept) {
            try {
                for (String line : new String(GamePack.read(new File(r, "index.tsv")), StandardCharsets.UTF_8).split("\n")) {
                    String[] col = line.split("\t");
                    if (col.length == 3) used.add(col[2]);
                }
            } catch (IOException e) {
                return;
            }
        }
        File objects = new File(gameRoot, "objects");
        deleteTree(new File(objects, "tmp"));
        File[] buckets = objects.listFiles(File::isDirectory);
        if (buckets != null) for (File b : buckets) {
            File[] files = b.listFiles();
            if (files != null) for (File o : files) if (!used.contains(o.getName())) o.delete();
            b.delete();   // only when empty
        }
    }

    private static GamePack.Entry entry(List<GamePack.Entry> entries, String path) throws GamePack.BadPack {
        for (GamePack.Entry e : entries) if (e.path.equals(path)) return e;
        throw new GamePack.BadPack("package has no " + path);
    }

    private static byte[] verified(Source source, GamePack.Entry e) throws IOException, GamePack.BadPack {
        byte[] data = required(source, e.path);
        if (data.length != e.size || !GamePack.sha256(data).equals(e.sha256))
            throw new GamePack.BadPack(e.path + " does not match index.tsv (size / SHA-256)");
        return data;
    }

    private static byte[] required(Source source, String path) throws IOException, GamePack.BadPack {
        try (InputStream in = source.open(path)) {
            if (in == null) throw new GamePack.BadPack("package has no " + path);
            return GamePack.readAll(in);
        }
    }

    // Written and flushed to storage before the rename that makes it count.
    private static void writeSynced(File f, byte[] data) throws IOException {
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(data);
            out.getFD().sync();
        }
    }

    static void deleteTree(File f) {
        File[] children = Files.isSymbolicLink(f.toPath()) ? null : f.listFiles();
        if (children != null) for (File c : children) deleteTree(c);
        f.delete();
    }
}
