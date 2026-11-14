package org.s2arm.android;

import android.content.ContentResolver;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.util.Log;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Installed games in the app's internal files directory, games/<title id>/ in the A0 layout
 * (revisions/<content root>/ + current.json, implementation plan §6.5). Two ways in, one
 * transaction (GameInstall): a private or external files/import/<name>/ package directory
 * (selected by an explicit absolute-path intent), or a package folder picked with
 * the Storage Access Framework. Either way every file is copied with its size and SHA-256
 * checked, the revision is validated before it is activated, and a failure leaves the
 * previous version active. Game files are only ever read: rewritten modules are copied into
 * anonymous memory by native/module.c, never mapped executable from storage. All work runs
 * on one background thread.
 */
final class GameLibrary {
    interface Listener {
        void onStatus(String text);
        default void onGameReady(GameSession session) { }
        default void onGameAvailable(String titleId, String name) { }
        /** 游戏库界面用：名字不带版本号；art 是这款的封面（商店横图 banner.jpg 优先，其次游戏图标 icon.jpg），都没有为 null。 */
        default void onGameAvailable(String titleId, String name, File art) { onGameAvailable(titleId, name); }
    }

    private final Context context;
    private final File[] importDirs;
    private final File importDir, gamesDir;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Listener listener;
    private final String selectedTitle;
    private boolean selectedRequested;

    GameLibrary(Context context, Listener listener) { this(context, listener, null); }

    GameLibrary(Context context, Listener listener, String selectedTitle) {
        GameFingerprint.setStatProvider(AndroidFileStamp::read);
        GameFingerprint.setStatProbe(AndroidFileStamp::probe);
        this.selectedTitle = selectedTitle;
        this.context = context;
        this.listener = listener;
        importDirs = GameInstall.importDirectories(context.getFilesDir(), context.getExternalFilesDir(null));
        importDir = importDirs[importDirs.length - 1];   // existing adb hint (external when available)
        gamesDir = new File(context.getFilesDir(), "games");
        for (File inbox : importDirs) inbox.mkdirs();
        gamesDir.mkdirs();
        if (selectedTitle == null) worker.execute(() -> {
            int swept = GameInstall.sweep(gamesDir);   // 逐款取锁，忙的那款跳过
            if (swept > 0) Log.i("S2Arm", "Removed " + swept + " unfinished game install(s)");
        });
    }

    private void status(String text) {
        Log.i("S2Arm", text);
        listener.onStatus(text);
    }

    /** 失败：日志照旧记原始英文串（工具按它认），界面给玩家文案（原因 + 下一步 + 细节）。 */
    private void failure(String logText, int what, Throwable error) {
        Log.i("S2Arm", logText);
        listener.onStatus(PlayerError.text(context, what, error));
    }

    /** Resume without an import target only reports the library. */
    void scanImports() { scanImports(null); }

    /** Import only the explicitly selected absolute staging path, then report the library. */
    void scanImports(String stagingName) {
        if (selectedTitle != null) {
            if (selectedRequested) return;
            selectedRequested = true;
            worker.execute(() -> {
                // Explicit opt-in before process start: log.tag.S2ArmBootTiming=DEBUG. Release builds cannot enable it.
                GameFingerprint.Timing timing = BuildConfig.DEBUG && Log.isLoggable("S2ArmBootTiming", Log.DEBUG)
                    ? new GameFingerprint.Timing() : null;
                try {
                    if (!selectedTitle.matches("[0-9A-F]{16}")) throw new IOException("invalid selected titleId");
                    long phase = GameFingerprint.Timing.start(timing);
                    BootContract.Game boot = BootContract.open(new File(gamesDir, selectedTitle));
                    GameFingerprint.Timing.end(timing, "library_open", phase);
                    if (!selectedTitle.equals(boot.titleId)) throw new IOException("selected game identity differs from the private revision");
                    phase = GameFingerprint.Timing.start(timing);
                    BootSpec spec = BootSpecSource.build(context, gamesDir, boot);
                    GameFingerprint.Timing.end(timing, "boot_spec", phase);
                    spec.mode = "game";
                    phase = GameFingerprint.Timing.start(timing);
                    GameSession.InstalledApk apk = installedApk();
                    GameFingerprint.Timing.end(timing, "installed_apk_identity", phase);
                    phase = GameFingerprint.Timing.start(timing);
                    GameSession session = GameSession.load(spec, context.getFilesDir(), apk,
                        (context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0, DebugGate.open(), timing);
                    GameFingerprint.Timing.end(timing, "session_load_total", phase);
                    if (timing != null) for (String line : timing.lines()) Log.d("S2ArmBootTiming", line);
                    Log.i("S2Arm", session.resourceValidation);
                    if (timing != null) timing.readyNanos = System.nanoTime();
                    listener.onGameReady(session);
                } catch (BootContract.BadGame | GamePack.BadPack | IOException | RuntimeException error) {
                    if (timing != null) for (String line : timing.lines()) Log.d("S2ArmBootTiming", line);
                    failure("Game admission failed: " + error.getMessage(), R.string.player_err_start, error);
                }
            });
            return;
        }
        worker.execute(() -> {
            try {
                GameInstall.importDirectory(context.getFilesDir(), importDirs, stagingName,
                    source -> checkedImportSource(source, context.getPackageName(),
                        (context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0,
                        DebugGate.open()), progress(),
                    new GameInstall.ImportListener() {
                        @Override public void installed(File source, GameInstall.Result result) {
                            status("Game " + outcome(result) + " from import/" + source.getName());
                            // Preserve the deployment receipt after the selected target commits.
                            // A failed receipt read must not turn a committed import into a refusal.
                            try {
                                BootContract.Current now = BootContract.readCurrent(new File(gamesDir, result.titleId));
                                Log.i("S2Arm", "Game import receipt: " + result.titleId + " contentRoot=" + now.contentRoot
                                    + " artifactSha256=" + now.artifactSha256 + " from import/" + source.getName());
                            } catch (BootContract.BadGame | IOException receipt) {
                                Log.i("S2Arm", "Game import receipt unavailable: " + result.titleId + " from import/" + source.getName());
                            }
                        }
                        @Override public void refused(File source, Exception error) {
                            failure("Game import of requested directory refused: " + error.getMessage(), R.string.player_err_import, error);
                        }
                        @Override public void cleanupDeferred(File source, IOException error) {
                            status("Imported staging cleanup deferred: " + error.getMessage());
                        }
                    });
            } catch (IOException error) {
                failure("Game import deferred: " + error.getMessage(), R.string.player_err_import, error);
            }
            status(describe());
        });
    }

    /** Copy a package folder chosen with ACTION_OPEN_DOCUMENT_TREE. */
    void importTree(Uri tree) {
        worker.execute(() -> {
            try {   // 不取整库锁：每个包装进去时只锁它那一款
                ContentResolver cr = context.getContentResolver();
                Map<String, String> ids = new HashMap<>();
                walk(cr, tree, ids);
                // 选了包所在的上一级（或放着几款游戏的文件夹）不挡：在里面找出所有游戏包逐个导入，一个失败不影响其他（不堵门）
                List<String> roots = packageRoots(ids.keySet());
                if (roots.isEmpty())
                    throw new GamePack.BadPack("no game package (a folder with manifest.json) anywhere in the picked folder;"
                        + " pick the folder you copied the package into");
                for (String root : roots) {
                    try {
                        GameInstall.Result r = GameInstall.install(gamesDir, checkedImportSource(path -> {
                            String id = ids.get(root + path);
                            return id == null ? null : cr.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, id));
                        }, context.getPackageName(),
                            (context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0,
                            DebugGate.open()), progress());
                        status("Game " + outcome(r));
                    } catch (GamePack.BadPack | BootContract.BadGame | IOException | RuntimeException e) {
                        failure("Game import refused" + (root.isEmpty() ? "" : " (" + root.substring(0, root.length() - 1) + ")") + ": " + e.getMessage(),
                            R.string.player_err_import, e);
                    }
                }
            } catch (GamePack.BadPack | IOException | RuntimeException e) {
                failure("Game import refused: " + e.getMessage(), R.string.player_err_import, e);
            }
            status(describe());
        });
    }

    /** Package roots under a picked tree ("" = the tree itself, else "dir/…/"): every folder holding manifest.json,
     *  except one nested inside another package (a game's own files may carry that name). */
    static List<String> packageRoots(java.util.Collection<String> paths) {
        if (paths.contains("manifest.json")) return java.util.Collections.singletonList("");
        List<String> found = new ArrayList<>();
        for (String p : paths) if (p.endsWith("/manifest.json")) found.add(p.substring(0, p.length() - "manifest.json".length()));
        java.util.Collections.sort(found);
        List<String> roots = new ArrayList<>();
        for (String r : found) {
            boolean nested = false;
            for (String outer : roots) if (r.startsWith(outer)) { nested = true; break; }
            if (!nested) roots.add(r);
        }
        return roots;
    }

    static GameInstall.Source checkedImportSource(GameInstall.Source source, String installedPackage,
            boolean debuggable, boolean debugEntriesOpen) {
        return GameInstall.checkedImportSource(source, installedPackage, debuggable, debugEntriesOpen);
    }

    private static String outcome(GameInstall.Result r) {
        String game = r.info.name + " " + r.info.version + " [" + r.titleId + "]";
        if (r.alreadyActive) return "already installed: " + game;
        if (r.artifactRefreshed) return "build artifact updated (same files): " + game + " -> " + r.contentRoot.substring(0, 19);
        return "installed: " + game + " -> " + r.contentRoot.substring(0, 19)
            + String.format(Locale.ROOT, "; stored %.1f MiB, shared %.1f MiB with installed versions", r.storedBytes / 1048576.0, r.sharedBytes / 1048576.0)
            + (r.linked ? "" : " (hard links refused: files copied, not shared)")
            + (r.previousContentRoot == null ? "" : "; previous " + r.previousContentRoot.substring(0, 19) + " kept");
    }

    // Progress for the panel, every 64 MiB copied.
    private GameInstall.Progress progress() {
        long[] last = {0};
        return (done, total) -> {
            if (done - last[0] > (64L << 20)) { last[0] = done; listener.onStatus(progress(done, total)); }
        };
    }

    private static String progress(long done, long total) {
        return String.format(Locale.ROOT, "Importing game: %d / %d MiB", done >> 20, total >> 20);
    }

    // Every file and folder under the picked tree, by package-relative path.
    private static void walk(ContentResolver cr, Uri tree, Map<String, String> ids) throws IOException {
        ArrayDeque<String[]> todo = new ArrayDeque<>();   // {path prefix, document id}
        todo.add(new String[] {"", DocumentsContract.getTreeDocumentId(tree)});
        String[] columns = {DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                            DocumentsContract.Document.COLUMN_MIME_TYPE};
        while (!todo.isEmpty()) {
            String[] dir = todo.poll();
            Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dir[1]);
            try (Cursor c = cr.query(children, columns, null, null, null)) {
                if (c == null) throw new IOException("cannot list the picked folder");
                while (c.moveToNext()) {
                    String path = dir[0].isEmpty() ? c.getString(1) : dir[0] + "/" + c.getString(1);
                    ids.put(path, c.getString(0));
                    if (DocumentsContract.Document.MIME_TYPE_DIR.equals(c.getString(2))) todo.add(new String[] {path, c.getString(0)});
                }
            }
        }
    }

    /** One line per installed game, with a load check of its rewritten modules. */
    String describe() {
        File[] games = gamesDir.listFiles(f -> f.isDirectory() && !f.getName().startsWith("."));
        if (games == null || games.length == 0) return "Games: none installed (choose a package, or explicitly request a staged import in "
            + importDir.getAbsolutePath() + ")";
        StringBuilder sb = new StringBuilder("Games:");
        for (File g : games) {
            if (new File(g, "current.json").isFile()) describeA0(sb, g);
            else describeLegacy(sb, g);
        }
        return sb.toString();
    }

    /** A0 layout: metadata lives in the active revision, not at the game root. */
    private void describeA0(StringBuilder sb, File g) {
        try {
            BootContract.Game boot = BootContract.open(g);
            GamePack.Info info = GameMetadata.read(g, boot);
            String mismatch = boot.hasApkModules() ? apkIdentityMismatch(boot.apk) : null;
            String state;
            if (mismatch != null) {
                state = boot.summary() + "; refused: " + mismatch;
            } else {
                state = boot.summary() + "; launch requires session admission";
                File revision = new File(g, boot.revisionDir), banner = new File(revision, "banner.jpg"), icon = new File(revision, "icon.jpg");
                listener.onGameAvailable(boot.titleId, info.name, banner.isFile() ? banner : icon.isFile() ? icon : null);
            }
            sb.append(String.format(Locale.ROOT, "\n%s %s [%s]: %d files, %.1f MiB; %s", info.name, info.version, info.titleId,
                boot.packageFiles, boot.packageBytes / 1048576.0, state));
        } catch (BootContract.BadGame | GamePack.BadPack | IOException e) {
            sb.append("\n").append(g.getName()).append(": unreadable (").append(e.getMessage()).append(")");
        }
    }

    private GameSession.InstalledApk installedApk() throws IOException {
        try {
            PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), PackageManager.GET_SIGNING_CERTIFICATES);
            ArrayList<String> signers = new ArrayList<>();
            if (info.signingInfo != null) for (Signature signer : info.signingInfo.getApkContentsSigners())
                signers.add(GamePack.sha256(signer.toByteArray()));
            String[] splits = context.getApplicationInfo().splitSourceDirs;
            return new GameSession.InstalledApk(new File(context.getApplicationInfo().sourceDir), context.getPackageName(),
                info.getLongVersionCode(), signers, splits != null && splits.length > 0);
        } catch (PackageManager.NameNotFoundException error) { throw new IOException("cannot read installed APK identity"); }
    }

    void close() { worker.shutdown(); }

    /**
     * apk-asset modules run from this APK only when the artifact names this APK: package name,
     * versionCode and signing certificate (the current signer, SHA-256 of its DER encoding).
     * 同一签名和 versionCode 仍可能对应不同构建；真正启动前还要核已安装 APK 的完整哈希。
     * 返回 null 才表示 artifact 绑定的是当前 APK。此方法在 library worker 上运行。
     */
    private String apkIdentityMismatch(BootContract.Apk apk) {
        try { BootContract.packageTitle(apk.packageName,
            (context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0 && DebugGate.open()); }
        catch (IllegalArgumentException closed) { return closed.getMessage(); }
        if (!context.getPackageName().equals(apk.packageName))
            return "the artifact is for " + apk.packageName + ", this app is " + context.getPackageName();
        try {
            PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), PackageManager.GET_SIGNING_CERTIFICATES);
            if (info.getLongVersionCode() != apk.versionCode)
                return "the artifact is for versionCode " + apk.versionCode + ", this app is " + info.getLongVersionCode();
            if (context.getApplicationInfo().splitSourceDirs != null
                    && context.getApplicationInfo().splitSourceDirs.length != 0)
                return "split APK assets are not part of this game artifact";
            if (!GameSession.matchesApk(new File(context.getApplicationInfo().sourceDir), apk.sha256))
                return "this installed APK does not match artifact.apk.sha256";
            if (info.signingInfo != null)
                for (Signature signer : info.signingInfo.getApkContentsSigners())
                    if (GamePack.sha256(signer.toByteArray()).equals(apk.signingCertSha256)) return null;
            return "this app's signing certificate is not the artifact's";
        } catch (PackageManager.NameNotFoundException e) {
            return "cannot read this app's package info";
        } catch (IOException e) {
            return "cannot verify this installed APK's bytes";
        }
    }

    /** Pre-A0 probe layout: package files at the game root, modules under modules/. */
    private void describeLegacy(StringBuilder sb, File g) {
        try {
            List<GamePack.Entry> entries = GamePack.readIndex(GamePack.read(new File(g, "manifest.json")), GamePack.read(new File(g, "index.tsv")));
            GamePack.Info info = new GamePack.Info();
            GamePack.describe(info, GamePack.read(new File(g, "ctl/control.nacp")));
            long bytes = 0;
            for (GamePack.Entry e : entries) bytes += e.size;
            String state = "Legacy package; A0 re-import required";
            sb.append(String.format(Locale.ROOT, "\n%s %s [%s]: %d files, %.1f MiB; %s", info.name, info.version, info.titleId,
                entries.size(), bytes / 1048576.0, state));
        } catch (GamePack.BadPack | IOException e) {
            sb.append("\n").append(g.getName()).append(": unreadable (").append(e.getMessage()).append(")");
        }
    }
}
