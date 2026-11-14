package org.s2arm.android;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** Authored bytes through the same install -> load seam as the App, without a guest or device. */
public final class GameSessionAdmissionTest {
    static int checks;
    static final String TITLE = "0100000000ABCDEF";
    static final byte[] IMAGE = {1, 2, 3, 4};
    static final byte[] CPATCH = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\ngfx:A\tmain\t0\tother-gfx\tA\t\ta.pchtxt\t\t0\n"
        .getBytes(java.nio.charset.StandardCharsets.UTF_8);
    static void check(boolean ok, String why) { checks++; if (!ok) throw new AssertionError(why); }
    static Path fixture(Path app) throws Exception { return fixture(app, true); }
    static Path fixture(Path app, boolean addressNeeds) throws Exception {
        Path pack = Files.createDirectories(app.resolve("pack"));
        Map<String, byte[]> files = new LinkedHashMap<>();
        files.put("exefs/main.npdm", new byte[128]);
        if (addressNeeds) files.put("exefs/addr_need.tsv", new byte[]{1,2,3});
        byte[] nacp = new byte[0x4000];
        long id = 0x0100000000ABCDEFL;
        for (int i = 0; i < 8; i++) nacp[0x3038+i] = (byte)(id >>> (8*i));
        files.put("ctl/control.nacp", nacp);
        files.put("romfs/readme", new byte[]{7});
        files.put("modules/main.npdm", new byte[128]);
        files.put("modules/main.patched.bin", IMAGE);
        files.put("modules/main.fixups.tsv", "# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n".getBytes(StandardCharsets.UTF_8));
        files.put("modules/main.gates.tsv", new byte[]{10});
        StringBuilder index = new StringBuilder(); long total = 0;
        for (var entry : files.entrySet()) {
            Path to = pack.resolve(entry.getKey()); Files.createDirectories(to.getParent()); Files.write(to, entry.getValue());
            index.append(entry.getKey()).append('\t').append(entry.getValue().length).append('\t')
                .append(GamePack.sha256(entry.getValue())).append('\n'); total += entry.getValue().length;
        }
        byte[] ix = index.toString().getBytes(StandardCharsets.UTF_8); String hash = GamePack.sha256(ix);
        Files.write(pack.resolve("index.tsv"), ix);
        Files.writeString(pack.resolve("manifest.json"), "{\"version\":2,\"files\":"+files.size()+",\"total\":"+total+",\"index_sha256\":\""+hash+"\"}");
        Files.writeString(pack.resolve(GamePack.ARTIFACT), """
            {"version":1,"titleId":"0100000000ABCDEF","contentRoot":"sha256-%s",
             "target":"android","guestAbi":"aarch64","rewriteAbi":"android-sp-safe-v1",
             "runtime":{"version":"0.1.0","backend":"vulkan"},
             "toolchain":{"rewriter":"runtime/rewriter@android-sp-safe-v1"},
             "package":{"manifest":"manifest.json","indexSha256":"%s","files":%d,"bytes":%d},
             "npdm":"exefs/main.npdm","control":"ctl/control.nacp","romfs":"romfs",
             "modules":[{"name":"main","source":"revision","image":"modules/main.patched.bin",
               "fixups":"modules/main.fixups.tsv","gates":"modules/main.gates.tsv","target":"android"}]}
            """.formatted(hash, hash, files.size(), total));
        GameInstall.install(app.resolve("games").toFile(), GameInstall.directory(pack.toFile()), null);
        return app.resolve("games/"+TITLE);
    }
    static BootSpec spec(Path app, Path game) throws Exception {
        BootSpec s = new BootSpec(); s.sessionId = java.util.UUID.randomUUID().toString(); s.mode = "game"; s.gameRoot = game.toString(); s.game = BootContract.open(game.toFile());
        s.userRoot = app.resolve("user/0").toString(); s.saveRoot = app.resolve("user/0/saves/"+TITLE).toString();
        s.cacheRoot = app.resolve("cache").toString(); return s;
    }
    interface Change { void run(Path app, Path game) throws Exception; }
    static void artifact(Path game, java.util.function.UnaryOperator<String> change) throws Exception {
        BootContract.Current current = BootContract.readCurrent(game.toFile());
        Path file = game.resolve(current.revisionDir).resolve(current.artifact);
        Files.writeString(file, change.apply(Files.readString(file)));
        Files.writeString(game.resolve("current.json"), Files.readString(game.resolve("current.json"))
            .replace(current.artifactSha256, GamePack.sha256(Files.readAllBytes(file))));
    }
    static void refuses(Path root, String name, Change change) throws Exception { refuses(root, name, true, change); }
    static void refuses(Path root, String name, boolean addressNeeds, Change change) throws Exception {
        Path app = Files.createDirectories(root.resolve(name)); Path game = fixture(app, addressNeeds);
        change.run(app, game);
        try (GameSession ignored = GameSession.load(spec(app, game), app.toFile(), null, true)) {
            throw new AssertionError("admission accepted " + name);
        } catch (IOException | BootContract.BadGame | GamePack.BadPack expected) { checks++; }
        try (GameStorage ignored = GameStorage.acquire(app.toFile(), game.getFileName().toString())) { checks++; }
    }

    static GameSession.InstalledApk apk(Path app, Path game) throws Exception {
        Path path = app.resolve("base.apk");
        try (var zip = new java.util.zip.ZipOutputStream(Files.newOutputStream(path))) {
            for (var entry : Map.of("main.patched.bin", IMAGE, "main.fixups.tsv",
                    "# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n".getBytes(StandardCharsets.UTF_8),
                    "main.gates.tsv", new byte[]{10}, "widen_enable.handheld.tsv", "main\t0x10\tmovz\t1\n".getBytes(StandardCharsets.UTF_8),
                    "cpatch.tsv", CPATCH).entrySet()) {
                zip.putNextEntry(new java.util.zip.ZipEntry("assets/game/modules/" + entry.getKey()));
                zip.write(entry.getValue()); zip.closeEntry();
            }
        }
        String hash = GamePack.sha256(Files.readAllBytes(path)); String cert = "11".repeat(32);
        artifact(game, text -> text.replace("\"source\":\"revision\"", "\"source\":\"apk-asset\"")
            .replace("modules/main.", "main.").replace("\"modules\":[", "\"apk\":{\"packageName\":\"org.s2arm.game.t0100000000abcdef\","
                + "\"versionCode\":1,\"sha256\":\""+hash+"\",\"signingCertSha256\":\""+cert+"\",\"assetRoot\":\"game/modules\"},\"modules\":["));
        return new GameSession.InstalledApk(path.toFile(), "org.s2arm.game.t0100000000abcdef",1,List.of(cert),false);
    }
    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("lock-probe")) {
            try (GameStorage ignored = GameStorage.acquire(new File(args[1]), TITLE)) { System.out.println("ACQUIRED"); }
            catch (IOException expected) { System.out.println("BUSY"); System.exit(2); }
            return;
        }
        Path app = Files.createTempDirectory("s2a-admission-");
        try {
            Path game = fixture(app);
            Map<String,Object> currentDoc = Json.object(Json.parse(Files.readString(game.resolve("current.json"))), "current");
            check(currentDoc.get("fingerprint") instanceof Map, "import publishes a fingerprint reference with current");
            try (GameSession session = GameSession.load(spec(app, game), app.toFile(), null, true)) {
                GameSession.FrozenStart start = session.begin(true,true,1280,720,320,60,BootSpec.ConsoleMode.HANDHELD);
                check(start != null && start.assetRoot.isEmpty(), "revision is admitted without APK binding");
                check("9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a".equals(start.moduleSha256.get("main")),
                    "revision executable hash has an independent known value");
                try (GameStorage ignored = GameStorage.acquire(app.toFile(), TITLE)) { throw new AssertionError("live revision not pinned"); }
                catch (IOException expected) { checks++; }
                // 锁按游戏分（不堵门）：这一款在跑时，别的游戏照样能取到自己的锁（导入 / 清扫不被挡）
                try (GameStorage other = GameStorage.acquire(app.toFile(), "0100000000ABCDEE")) { checks++; }
                catch (IOException wrong) { throw new AssertionError("another game's lock blocked by a live session", wrong); }
                Process child = new ProcessBuilder(Path.of(System.getProperty("java.home"),"bin/java").toString(),
                    "-cp",System.getProperty("java.class.path"),GameSessionAdmissionTest.class.getName(),"lock-probe",app.toString())
                    .redirectErrorStream(true).start();
                if (!child.waitFor(15,java.util.concurrent.TimeUnit.SECONDS)) { child.destroyForcibly(); throw new AssertionError("lock probe hung"); }
                check(child.exitValue() == 2 && new String(child.getInputStream().readAllBytes(),StandardCharsets.UTF_8).lines().anyMatch("BUSY"::equals),
                    "another process cannot install/retire a live revision");
            }
            // A metadata-only change to one valid resource must refresh the table.
            Path content = game.resolve(BootContract.readCurrent(game.toFile()).revisionDir).resolve("romfs/readme").toRealPath();
            String beforeTouch = Files.readString(game.resolve("current.json"));
            var oldMtime = Files.getLastModifiedTime(content);
            Files.setLastModifiedTime(content, java.nio.file.attribute.FileTime.fromMillis(oldMtime.toMillis()+5000));
            check(!oldMtime.equals(Files.getLastModifiedTime(content)), "touch changes actual target mtime");
            try (GameSession ignored = GameSession.load(spec(app,game),app.toFile(),null,true)) { }
            check(!beforeTouch.equals(Files.readString(game.resolve("current.json"))), "touch refreshes the current fingerprint");
            // Imported modules are admitted on a release (non-debuggable) app as well: no experimental gate.
            try (GameSession released = GameSession.load(spec(app,game),app.toFile(),null,false)) {
                check(released != null, "revision modules admitted without a debuggable app");
            }
            refuses(app,"bad-content",(a,g)-> {
                Path file = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir).resolve("modules/main.patched.bin");
                file.toFile().setWritable(true); Files.write(file,new byte[]{1,2,3,5});
            });
            refuses(app,"bad-index-binding",(a,g)-> {
                String hash = BootContract.readCurrent(g.toFile()).contentRoot.substring(7);
                artifact(g,s->s.replace("\"indexSha256\":\""+hash+"\"", "\"indexSha256\":\""+"00".repeat(32)+"\""));
            });
            refuses(app,"bad-abi",(a,g)->artifact(g,s->s.replace("\"rewriteAbi\":\"android-sp-safe-v1\"", "\"rewriteAbi\":\"wrong-abi\"")));
            {   // 工具链标签不同、ABI 相同：照常准入（不堵门；ABI 不同见上面 bad-abi，照旧拒）
                Path other = Files.createDirectories(app.resolve("other-rewriter-label")); Path otherGame = fixture(other, true);
                artifact(otherGame, s -> s.replace("runtime/rewriter@android-sp-safe-v1", "other/rewriter@android-sp-safe-v1"));
                try (GameSession ignored = GameSession.load(spec(other, otherGame), other.toFile(), null, true)) { checks++; }
            }
            refuses(app,"missing-rewriter",(a,g)->artifact(g,s->s.replace("\"toolchain\":{\"rewriter\":\"runtime/rewriter@android-sp-safe-v1\"},", "")));
            {   // 运行时版本号只是标签（ABI 另有核对）：不同照常准入（不堵门）
                Path other = Files.createDirectories(app.resolve("other-runtime-version")); Path otherGame = fixture(other, true);
                artifact(otherGame, s -> s.replace("0.1.0", "99.0.0"));
                try (GameSession ignored = GameSession.load(spec(other, otherGame), other.toFile(), null, true)) { checks++; }
            }
            refuses(app,"unindexed-module",(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.createDirectory(revision.resolve("outside"));
                for (String suffix : List.of("patched.bin","fixups.tsv","gates.tsv"))
                    Files.copy(revision.resolve("modules/main."+suffix),revision.resolve("outside/main."+suffix));
                artifact(g,s->s.replace("modules/main.","outside/main."));
            });
            {   // 版本目录根上留着换 artifact 时没删掉的旧 artifact：游戏读不到它，照常准入（不堵门）
                Path stale = Files.createDirectories(app.resolve("stale-root-artifact")); Path staleGame = fixture(stale, true);
                Path staleRev = staleGame.resolve(BootContract.readCurrent(staleGame.toFile()).revisionDir);
                Files.writeString(staleRev.resolve("game-build-artifact.0000000000000000.json"), "{}");
                try (GameSession ignored = GameSession.load(spec(stale, staleGame), stale.toFile(), null, true)) { checks++; }
            }
            refuses(app,"unindexed-romfs",(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.writeString(revision.resolve("romfs/extra"),"outside content root");
            });
            refuses(app,"unindexed-npdm",(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.copy(revision.resolve("exefs/main.npdm"),revision.resolve("unindexed.npdm"));
                artifact(g,s->s.replace("exefs/main.npdm","unindexed.npdm"));
            });
            refuses(app,"unindexed-systemdata",(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.createDirectory(revision.resolve("systemdata"));
                Files.writeString(revision.resolve("systemdata/extra"),"outside content root");
            });
            refuses(app,"metadata-as-npdm",(a,g)->artifact(g,s->s.replace("exefs/main.npdm","manifest.json")));
            refuses(app,"directory-link",(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.createSymbolicLink(revision.resolve("extra-dir"),revision.resolve("romfs"));
            });
            // An indexed entry whose only on-disk path traverses a directory link must still be
            // refused: the no-follow walk never produces an enumerated name for it.
            refuses(app,"indexed-under-dirlink",(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.move(revision.resolve("romfs"),revision.resolve("romfs-real"));
                Files.createSymbolicLink(revision.resolve("romfs"),revision.resolve("romfs-real"));
            });
            refuses(app,"unindexed-address-needs",(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.write(revision.resolve("modules/addr_need.tsv"),new byte[]{1});
                artifact(g,s->s.replace("exefs/main.npdm","modules/main.npdm"));
            });
            refuses(app,"metadata-under-romfs",(a,g)-> {
                var current = BootContract.readCurrent(g.toFile());
                Path revision = g.resolve(current.revisionDir);
                Files.move(revision.resolve(current.artifact),revision.resolve("romfs/metadata.json"));
                Files.writeString(g.resolve("current.json"),Files.readString(g.resolve("current.json")).replace(current.artifact,"romfs/metadata.json"));
            });
            Path noNeeds = Files.createDirectories(app.resolve("missing-address-needs"));
            Path noNeedsGame = fixture(noNeeds, false);
            try (GameSession session = GameSession.load(spec(noNeeds,noNeedsGame),noNeeds.toFile(),null,true)) {
                check(session.begin(true,true,1280,720,320,60,BootSpec.ConsoleMode.HANDHELD) != null,
                    "production-shaped pack without an indexed or on-disk address table is valid");
            }
            refuses(app,"unindexed-adjacent-needs",false,(a,g)-> {
                Path revision = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir);
                Files.write(revision.resolve("exefs/addr_need.tsv"),new byte[]{1,2,3});
            });
            refuses(app,"indexed-needs-missing",(a,g)-> {
                Files.delete(g.resolve(BootContract.readCurrent(g.toFile()).revisionDir).resolve("exefs/addr_need.tsv"));
            });
            refuses(app,"indexed-needs-wrong-hash",(a,g)-> {
                Path file = g.resolve(BootContract.readCurrent(g.toFile()).revisionDir).resolve("exefs/addr_need.tsv");
                Files.delete(file); Files.write(file,new byte[]{9,8,7});
            });
            for (String late : List.of("file","dangling-link")) {
                Path lateApp = Files.createDirectories(app.resolve("late-unindexed-needs-"+late));
                Path lateGame = fixture(lateApp,false);
                try (GameSession session = GameSession.load(spec(lateApp,lateGame),lateApp.toFile(),null,true)) {
                    Path file = Path.of(session.spec.gameRoot,session.spec.game.revisionDir,"exefs/addr_need.tsv");
                    if (late.equals("file")) Files.write(file,new byte[]{1,2,3});
                    else Files.createSymbolicLink(file,Path.of("missing-table-target"));
                    try { session.begin(true,true,1280,720,320,60,BootSpec.ConsoleMode.HANDHELD); throw new AssertionError("unindexed table appeared after admission"); }
                    catch (IOException expected) { checks++; }
                }
            }
            Path noNeedsApk = Files.createDirectories(app.resolve("optional-needs-apk"));
            Path noNeedsApkGame = fixture(noNeedsApk,false);
            var noNeedsInstalled = apk(noNeedsApk,noNeedsApkGame);
            try (GameSession session = GameSession.load(spec(noNeedsApk,noNeedsApkGame),noNeedsApk.toFile(),noNeedsInstalled,true)) {
                check(session.begin(true,true,1280,720,320,60,BootSpec.ConsoleMode.HANDHELD) != null,
                    "APK arm also accepts the current production shape without an address table");
            }
            Path resumeCache = Files.createDirectories(app.resolve("resume-cache"));
            BootSpec resumeSpec = spec(app, game);
            GameResume.publish(resumeCache.toFile(), 123, resumeSpec);
            check(resumeSpec.sessionId.equals(GameResume.requireSame(resumeCache.toFile(),123,TITLE,app.resolve("games").toFile())),
                "same live PID/title/revision/session can resume");
            for (int pid : new int[]{0,124}) {
                try { GameResume.requireSame(resumeCache.toFile(),pid,TITLE,app.resolve("games").toFile()); throw new AssertionError("stale PID resumed"); }
                catch (IOException expected) { checks++; }
            }
            artifact(game,s->s.replace("runtime/rewriter@android-sp-safe-v1","other/rewriter@android-sp-safe-v1"));
            try { GameResume.requireSame(resumeCache.toFile(),123,TITLE,app.resolve("games").toFile()); throw new AssertionError("changed artifact resumed"); }
            catch (IOException expected) { checks++; }
            GameResume.clear(resumeCache.toFile());
            try { GameResume.requireSame(resumeCache.toFile(),123,TITLE,app.resolve("games").toFile()); throw new AssertionError("retiring session resumed"); }
            catch (IOException expected) { checks++; }
            for (String path : List.of("exefs/main.npdm", "exefs/addr_need.tsv")) {
                Path metaApp = Files.createDirectories(app.resolve("metadata-"+path.replace('/','-')));
                Path metaGame = fixture(metaApp);
                try (GameSession session = GameSession.load(spec(metaApp,metaGame),metaApp.toFile(),null,true)) {
                    Path file = Path.of(session.spec.gameRoot,session.spec.game.revisionDir,path);
                    Files.delete(file); Files.write(file,new byte[]{9});
                    try { session.begin(true,true,1280,720,320,60,BootSpec.ConsoleMode.HANDHELD); throw new AssertionError("changed native metadata accepted"); }
                    catch (IOException expected) { checks++; }
                }
            }
            Path assetApp = Files.createDirectories(app.resolve("apk")); Path assetGame = fixture(assetApp);
            GameSession.InstalledApk installed = apk(assetApp,assetGame);
            try (GameSession session = GameSession.load(spec(assetApp,assetGame),assetApp.toFile(),installed,true)) {
                var start = session.begin(true,true,1280,720,320,60,BootSpec.ConsoleMode.HANDHELD);
                check(start.assetRoot.equals("game/modules") && "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a".equals(start.moduleSha256.get("main")),
                    "identical revision/APK executable bytes produce the same digest");
                check(GameSession.nativeFileAdmission("game/modules/widen_enable.handheld.tsv") == 1,
                    "present policy remains declared for missing-asset rejection");
                check(GameSession.nativeFileAdmission("game/modules/widen_full.handheld.tsv") == 0,
                    "absent optional policy is distinguishable");
                byte[] policy = "main\t0x10\tmovz\t1\n".getBytes(StandardCharsets.UTF_8);
                check(GameSession.verifyNativeBytes("game/modules/widen_enable.handheld.tsv", java.nio.ByteBuffer.wrap(policy)),
                    "APK widening policy admitted for native authenticated reads");
                policy[0] ^= 1;
                check(!GameSession.verifyNativeBytes("game/modules/widen_enable.handheld.tsv", java.nio.ByteBuffer.wrap(policy)),
                    "changed widening policy is rejected");
                // #48 D2：社区补丁表与宽屏表同口径进准入名单，原生读面按同一份哈希验
                check(GameSession.nativeFileAdmission("game/modules/cpatch.tsv") == 1, "APK community patch table is admitted");
                byte[] table = CPATCH.clone();
                check(GameSession.verifyNativeBytes("game/modules/cpatch.tsv", java.nio.ByteBuffer.wrap(table)),
                    "APK community patch table admitted for native authenticated reads");
                table[table.length - 2] ^= 1;
                check(!GameSession.verifyNativeBytes("game/modules/cpatch.tsv", java.nio.ByteBuffer.wrap(table)),
                    "changed community patch table is rejected");
            }
            // The persisted (size, dev, ino, mtime) stamp lets a later boot skip re-hashing the APK.
            Map<String,Object> doc = Json.object(Json.parse(Files.readString(assetGame.resolve("current.json"))),"current");
            Map<String,Object> stamp = Json.object(Json.object(doc.get("fingerprint"),"fingerprint").get("apk"),"apk");
            check(stamp.get("sha256").equals(GamePack.sha256(Files.readAllBytes(installed.file.toPath()))),
                "admission persists the measured APK stamp");
            GameFingerprint.Timing stampTiming = new GameFingerprint.Timing();
            try (GameSession session = GameSession.load(spec(assetApp,assetGame),assetApp.toFile(),installed,true,stampTiming)) {
                check(String.join("\n", stampTiming.lines()).contains("phase=apk_sha_stamp_hit ns="),
                    "matching APK stamp admits without re-hashing the APK");
            }
            // Same path/size/mtime with a different inode must miss the stamp and re-verify bytes.
            java.nio.file.attribute.FileTime apkTime = Files.getLastModifiedTime(installed.file.toPath());
            Path apkCopy = Files.createTempFile(installed.file.toPath().getParent(),"apk-",".tmp");
            Files.write(apkCopy, Files.readAllBytes(installed.file.toPath()));
            Files.setLastModifiedTime(apkCopy, apkTime);
            Files.move(apkCopy, installed.file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            GameFingerprint.Timing recalcTiming = new GameFingerprint.Timing();
            try (GameSession session = GameSession.load(spec(assetApp,assetGame),assetApp.toFile(),installed,true,recalcTiming)) {
                check(String.join("\n", recalcTiming.lines()).contains("phase=apk_sha_recalculated ns="),
                    "inode change forces a fresh APK hash");
            }
            try (GameSession session = GameSession.load(spec(assetApp,assetGame),assetApp.toFile(),installed,true,
                    stampTiming = new GameFingerprint.Timing())) {
                check(String.join("\n", stampTiming.lines()).contains("phase=apk_sha_stamp_hit ns="),
                    "refreshed APK stamp hits on the following boot");
            }
            // Same path/size/mtime, different inode AND different bytes: stamp miss must re-verify content.
            apkTime = Files.getLastModifiedTime(installed.file.toPath());
            byte[] tampered = Files.readAllBytes(installed.file.toPath()); tampered[0] ^= 1;
            apkCopy = Files.createTempFile(installed.file.toPath().getParent(),"apk-",".tmp");
            Files.write(apkCopy, tampered);
            Files.setLastModifiedTime(apkCopy, apkTime);
            Files.move(apkCopy, installed.file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            try (GameSession ignored = GameSession.load(spec(assetApp,assetGame),assetApp.toFile(),installed,true)) {
                throw new AssertionError("stamp miss re-hash accepted different APK bytes");
            } catch (IOException expected) { checks++; }
            for (var wrong : List.of(
                    new GameSession.InstalledApk(installed.file,"other.package",1,installed.signerSha256,false),
                    new GameSession.InstalledApk(installed.file,installed.packageName,2,installed.signerSha256,false),
                    new GameSession.InstalledApk(installed.file,installed.packageName,1,List.of("00".repeat(32)),false),
                    new GameSession.InstalledApk(installed.file,installed.packageName,1,installed.signerSha256,true))) {
                try (GameSession ignored = GameSession.load(spec(assetApp,assetGame),assetApp.toFile(),wrong,true)) {
                    throw new AssertionError("APK identity check bypassed");
                } catch (IOException expected) { checks++; }
            }
            Files.writeString(installed.file.toPath(),"different APK build");
            try (GameSession ignored = GameSession.load(spec(assetApp,assetGame),assetApp.toFile(),installed,true)) {
                throw new AssertionError("APK SHA check bypassed");
            } catch (IOException expected) { checks++; }
            System.out.println("GameSession admission: " + checks + " checks PASS (synthetic host only)");
        } finally { GameInstall.deleteTree(app.toFile()); }
    }
}
