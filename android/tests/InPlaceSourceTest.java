package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.util.Arrays;
import java.util.List;

/**
 * 原地来源（GameInstall.installInPlace / BootContract.IN_PLACE）：共享存储上的资源目录只登记元数据、内容不复制；
 * 首次按 index 核大小与 SHA-256，之后起局靠指纹表身份命中；文件被改 / 删 / 根被挪具名拒；只认登记的根；
 * 清理私有目录从不碰原地文件。夹具是 GameSessionAdmissionTest.fixture 的 8 文件包（exefs/main.npdm 与 modules/main.npdm
 * 同为 128 个零字节，所以对象库里是 7 个对象），期望值都按这个包手算。
 * 原地起局的「命中 / 重算」：8 个文件里 4 个是可执行文件（exefs/main.npdm 和 main 模块的 image / fixups / gates；
 * modules/main.npdm 不在 exefs 下、不算），每次整份重算；其余 4 个数据文件按身份命中，所以全好时是「命中 4 / 重算 4」，
 * 碰过一个数据文件是「命中 3 / 重算 5」。
 */
public final class InPlaceSourceTest {
    private static int checks;
    private static void check(boolean ok, String why) { checks++; if (!ok) throw new AssertionError(why); }
    private static final GameInstall.ImportSourceCheck SAME = source -> source;
    private static final String TITLE = GameSessionAdmissionTest.TITLE;

    /** 一份 8 文件的资源目录，放在 app 私有游戏库以外（模拟共享存储），不做私有安装。 */
    private static Path shared(Path base, String name) throws Exception {
        Path seed = Files.createDirectories(base.resolve("seed-" + name));
        GameSessionAdmissionTest.fixture(seed);
        Path dir = base.resolve("sdcard/S2Arm/Games/" + name);
        Files.createDirectories(dir.getParent());
        Files.move(seed.resolve("pack"), dir);
        GameInstall.deleteTree(seed.toFile());
        return dir;
    }

    private static String load(Path app, Path game) throws Exception {
        try (GameSession session = GameSession.load(GameSessionAdmissionTest.spec(app, game), app.toFile(), null, true)) {
            return session.resourceValidation;
        }
    }

    private static boolean tamperOnly;

    private static void counts(String line, int hit, int rehash) {
        if (tamperOnly) return;
        check(line.startsWith("资源校验：指纹命中 " + hit + " / 重算 " + rehash + " / 用时 "), "unexpected resource counts: " + line);
    }

    private static String refusal(Path app, Path game) {
        try { load(app, game); return null; }
        catch (Exception e) { return e.getMessage(); }
    }

    private static int objects(Path game) throws IOException {
        Path objects = game.resolve("objects");
        if (!Files.isDirectory(objects)) return 0;
        try (var walk = Files.walk(objects)) {
            // 排除对象库自己的暂存目录 objects/tmp/。按相对 objects 的路径判，不能对整条路径找「/tmp/」：
            //   Linux 的临时目录就在 /tmp 下，整条路径都带它，对象会被全部排除（Mac 的临时目录在 /var/folders 下才没露出来）。
            return (int) walk.filter(p -> Files.isRegularFile(p) && !objects.relativize(p).startsWith("tmp")).count();
        }
    }

    private static String[] names(Path dir) {
        String[] n = dir.toFile().list();
        Arrays.sort(n);
        return n;
    }

    public static void main(String[] args) throws Exception {
        Path base = Files.createTempDirectory("s2a-inplace-");
        try {
            if (args.length == 1 && args[0].equals("tamper-only")) {   // 负对照用：只跑「恢复身份的篡改」两条，不核计数
                tamperOnly = true;
                restoredIdentity(base);
                System.out.println("InPlaceSource tamper-only: " + checks + " checks PASS");
                return;
            }
            exactHash(base);
            registerAndBoot(base);
            changedAndMissing(base);
            rootRules(base);
            storageSwitches(base);
            restoredIdentity(base);
            System.out.println("InPlaceSource: " + checks + " checks PASS (synthetic host only)");
        } finally { GameInstall.deleteTree(base.toFile()); }
    }

    // 读够索引大小就停：比索引长的文件只算前 size 字节，短的返回 null（不为确认末尾多读一次）
    private static void exactHash(Path base) throws Exception {
        File f = Files.write(base.resolve("exact.bin"), "abcdef".getBytes(StandardCharsets.UTF_8)).toFile();
        check(GamePack.sha256("abc".getBytes(StandardCharsets.UTF_8)).equals(GameFingerprint.sha256Exact(f, 3, null)), "prefix hash");
        check(GameFingerprint.sha256Exact(f, 7, null) == null, "short file gives null");
        long[] seen = {0};
        GameFingerprint.sha256Exact(f, 6, n -> seen[0] += n);
        check(seen[0] == 6, "progress counts the bytes read: " + seen[0]);
    }

    private static void registerAndBoot(Path base) throws Exception {
        Path app = Files.createDirectories(base.resolve("app1"));
        Path root = shared(base, "g1");
        File games = app.resolve("games").toFile();
        GameInstall.Result r = GameInstall.installInPlace(games, root.toFile(), SAME, null);
        Path game = app.resolve("games/" + TITLE);
        check(root.toRealPath().toString().equals(r.inPlaceRoot), "registered canonical root: " + r.inPlaceRoot);
        check(!r.alreadyActive && r.storedBytes == 0 && r.sharedBytes == 0, "nothing copied or shared");
        BootContract.Game boot = BootContract.open(game.toFile());
        check(root.toRealPath().toString().equals(boot.inPlaceRoot), "boot reads the in-place root");
        check(boot.contentDir(game.toFile()).equals(root.toRealPath().toFile()), "content dir is the in-place root");
        // 私有版本目录只有元数据：manifest / index / 构建描述 / 原地登记 / 指纹表，共 5 项；对象库里 0 个对象
        String[] meta = names(game.resolve(boot.revisionDir));
        check(meta.length == 5 && meta[0].startsWith(".s2a-fingerprint-") && meta[1].equals(GamePack.ARTIFACT)
            && meta[2].equals(BootContract.IN_PLACE) && meta[3].equals("index.tsv") && meta[4].equals("manifest.json"),
            "metadata-only revision: " + Arrays.toString(meta));
        check(objects(game) == 0, "in-place registration stores no objects");
        // 起局：登记时已核过 8 个文件并记下身份，全部命中、0 重算
        counts(load(app, game), 4, 4);
        try (GameSession session = GameSession.load(GameSessionAdmissionTest.spec(app, game), app.toFile(), null, true)) {
            GameSession.FrozenStart start = session.begin(true, true, 1280, 720, 320, 60, BootSpec.ConsoleMode.HANDHELD);
            check(start.revisionDir.equals(root.toRealPath().toString()), "native reads game files from the in-place root: " + start.revisionDir);
            check(start.npdmPath.equals(root.toRealPath().resolve("exefs/main.npdm").toString()), "npdm from the in-place root");
            check(GameSession.nativeFileAdmission(root.toRealPath().resolve("modules/main.patched.bin").toString()) == 1,
                "module image admitted under the in-place root");
            check(GameSession.nativeFileAdmission(game.resolve(boot.revisionDir).resolve("modules/main.patched.bin").toString()) == 0,
                "nothing admitted under the private revision");
        }
        // 碰一下修改时间：只重算这 1 个，表更新后下次又全命中
        Path readme = root.resolve("romfs/readme");
        Files.setLastModifiedTime(readme, FileTime.fromMillis(Files.getLastModifiedTime(readme).toMillis() + 5000));
        counts(load(app, game), 3, 5);
        counts(load(app, game), 4, 4);
        // 同一个根再登记一次：已在用，不重来
        check(GameInstall.installInPlace(games, root.toFile(), SAME, null).alreadyActive, "same root re-register is already active");
        // 根上多出来的文件（游戏读不到的位置）不挡；内容目录里多出来的游戏读得到，具名拒
        Files.writeString(root.resolve("notes.txt"), "player notes");
        counts(load(app, game), 4, 4);
        Files.writeString(root.resolve("romfs/extra"), "x");
        String why = refusal(app, game);
        check(why != null && why.equals("in-place file is outside the content index: romfs/extra"), "stray content file: " + why);
        Files.delete(root.resolve("romfs/extra"));
        counts(load(app, game), 4, 4);
    }

    private static void changedAndMissing(Path base) throws Exception {
        Path app = Files.createDirectories(base.resolve("app2"));
        Path root = shared(base, "g2");
        GameInstall.installInPlace(app.resolve("games").toFile(), root.toFile(), SAME, null);
        Path game = app.resolve("games/" + TITLE);
        Path readme = root.resolve("romfs/readme");
        byte[] good = Files.readAllBytes(readme);
        // 玩家改了内容（同样 1 字节，身份变了）：重算 SHA 对不上，具名拒，current.json 不动
        byte[] before = Files.readAllBytes(game.resolve("current.json"));
        Files.write(readme, new byte[] {9});
        String why = refusal(app, game);
        check("in-place file changed (SHA-256 differs from index.tsv): romfs/readme".equals(why), "changed content: " + why);
        check(Arrays.equals(before, Files.readAllBytes(game.resolve("current.json"))), "refusal leaves current.json");
        // 长度变了
        Files.write(readme, new byte[] {7, 7});
        why = refusal(app, game);
        check("in-place file changed (size differs from index.tsv): romfs/readme".equals(why), "size change: " + why);
        // 删掉了
        Files.delete(readme);
        why = refusal(app, game);
        check(why != null && why.equals("in-place file is missing: romfs/readme (under " + root.toRealPath() + ")"), "missing file: " + why);
        // 放回原样（新 inode / 新修改时间）：重算 1 个通过
        Files.write(readme, good);
        counts(load(app, game), 3, 5);
        // 换成指向根外的符号链接（内容相同）：只认登记的根，拒
        Path outside = Files.write(base.resolve("outside-readme"), good);
        Files.delete(readme);
        Files.createSymbolicLink(readme, outside);
        why = refusal(app, game);
        check(why != null && why.contains("escapes"), "link out of the root: " + why);
        Files.delete(readme);
        Files.write(readme, good);
        counts(load(app, game), 3, 5);
        // 整个文件夹被挪走：具名拒
        String registered = root.toRealPath().toString();
        Path moved = root.resolveSibling("g2-moved");
        Files.move(root, moved);
        why = refusal(app, game);
        check(("in-place game folder is missing or unreadable: " + registered).equals(why), "moved folder: " + why);
        // 原路径换成指向别处的链接：canonical 不再是登记的路径，拒（只认登记的那个根）
        Files.createSymbolicLink(root, moved);
        why = refusal(app, game);
        check(why != null && why.startsWith("in-place game folder is no longer its registered path"), "linked folder: " + why);
        Files.delete(root);
        Files.move(moved, root);
        counts(load(app, game), 4, 4);
        // 首次登记就核内容：坏文件不登记，什么都不写
        Path app3 = Files.createDirectories(base.resolve("app3"));
        Path bad = shared(base, "g3");
        Files.write(bad.resolve("romfs/readme"), new byte[] {9});
        try {
            GameInstall.installInPlace(app3.resolve("games").toFile(), bad.toFile(), SAME, null);
            check(false, "corrupt in-place package registered");
        } catch (GamePack.BadPack expected) {
            check(expected.getMessage().equals("in-place file does not match index.tsv (SHA-256): romfs/readme"), "first check: " + expected.getMessage());
        }
        Path game3 = app3.resolve("games/" + TITLE);
        check(!Files.exists(game3.resolve("current.json")) && names(game3.resolve("revisions")).length == 0, "refused registration writes nothing");
    }

    private static void rootRules(Path base) throws Exception {
        Path app = Files.createDirectories(base.resolve("app4"));
        File games = app.resolve("games").toFile();
        // 游戏库里面的目录不能当原地根（会和对象库 / 版本目录混在一起）
        Path inside = shared(base, "g4");
        Files.createDirectories(app.resolve("games"));
        Path moved = Files.move(inside, app.resolve("games/fake"));
        try { GameInstall.installInPlace(games, moved.toFile(), SAME, null); check(false, "root inside the library accepted"); }
        catch (BootContract.BadGame expected) { check(expected.getMessage().startsWith("in-place root overlaps the private game library"), expected.getMessage()); }
        for (String bad : new String[] {"relative/x", "/a/../b", "/a/", "/a\"b", "/a\\b", "/a//b"}) {
            try { BootContract.checkInPlaceRoot(bad, games); check(false, "accepted root " + bad); }
            catch (BootContract.BadGame expected) { checks++; }
        }
        BootContract.checkInPlaceRoot("/storage/emulated/0/S2Arm/Games/游戏", games);
        checks++;
    }

    private static void storageSwitches(Path base) throws Exception {
        Path app = Files.createDirectories(base.resolve("app5"));
        File games = app.resolve("games").toFile();
        Path root = shared(base, "g5");
        Path game = app.resolve("games/" + TITLE);
        // 先复制进私有目录（7 个对象），再原地登记同一份内容：私有那份换掉，对象库清空（原地版本目录不算引用）
        GameInstall.install(games, GameInstall.directory(root.toFile()), null);
        check(objects(game) == 7, "private install stores 7 objects: " + objects(game));
        GameInstall.Result r = GameInstall.installInPlace(games, root.toFile(), SAME, null);
        check(!r.alreadyActive && r.inPlaceRoot != null, "same content switched to in place");
        check(objects(game) == 0, "objects of the replaced private copy collected: " + objects(game));
        counts(load(app, game), 4, 4);
        // 反过来：同一份内容再复制进私有目录，照常装（不是「已安装」），原地登记没了
        GameInstall.Result back = GameInstall.install(games, GameInstall.directory(root.toFile()), null);
        check(!back.alreadyActive && BootContract.open(game.toFile()).inPlaceRoot == null, "copy replaces the in-place registration");
        check(objects(game) == 7, "copy stores its objects again");
        // 原地登记后再装两个别的版本：原地版本目录先当上一版保留、再被清掉；共享存储上的文件一个不少、字节不变
        GameInstall.installInPlace(games, root.toFile(), SAME, null);
        List<String> before = sums(root);
        for (String v : new String[] {"v2", "v3"}) {
            Path other = shared(base, "g5" + v);
            Files.write(other.resolve("romfs/readme"), v.getBytes(StandardCharsets.UTF_8));
            String row = "romfs/readme\t1\t" + GamePack.sha256(new byte[] {7});
            Path index = other.resolve("index.tsv");
            String old = Files.readString(index), oldSha = GamePack.sha256(old.getBytes(StandardCharsets.UTF_8));
            String now = old.replace(row, "romfs/readme\t2\t" + GamePack.sha256(v.getBytes(StandardCharsets.UTF_8)));
            check(!now.equals(old), "fixture index row rewritten");
            String nowSha = GamePack.sha256(now.getBytes(StandardCharsets.UTF_8));
            Files.writeString(index, now);
            for (String name : new String[] {"manifest.json", GamePack.ARTIFACT}) {
                Path f = other.resolve(name);
                Files.writeString(f, Files.readString(f).replace(oldSha, nowSha));
            }
            bump(other, 1);
            GameInstall.install(games, GameInstall.directory(other.toFile()), null);
        }
        check(names(game.resolve("revisions")).length == 2, "two revisions kept: " + Arrays.toString(names(game.resolve("revisions"))));
        check(before.equals(sums(root)), "pruning the in-place revision never touches the shared files");
    }

    // 原地改写内容、再把大小 / inode / 修改时间都恢复：数据文件照常命中（等于玩家打 mod），可执行模块必须重算后具名拒
    private static void restoredIdentity(Path base) throws Exception {
        Path app = Files.createDirectories(base.resolve("app6"));
        Path root = shared(base, "g6");
        GameInstall.installInPlace(app.resolve("games").toFile(), root.toFile(), SAME, null);
        Path game = app.resolve("games/" + TITLE);
        counts(load(app, game), 4, 4);
        // ② 数据文件 romfs/readme：{7} → {8}，同 inode、同大小、修改时间恢复 → 照常起局，仍是命中 4 / 重算 4（readme 命中）
        tamperKeepingIdentity(root.resolve("romfs/readme"), new byte[] {8});
        counts(load(app, game), 4, 4);
        // ① 可执行模块 main 的 image：{1,2,3,4} → {9,9,9,9}，同样手法 → 起局拒，错误写明是 main 模块的 image
        tamperKeepingIdentity(root.resolve("modules/main.patched.bin"), new byte[] {9, 9, 9, 9});
        String why = refusal(app, game);
        check("in-place executable changed (SHA-256 differs from index.tsv): module main image modules/main.patched.bin".equals(why),
            "tampered module with restored identity: " + why);
    }

    private static void tamperKeepingIdentity(Path file, byte[] bytes) throws IOException {
        Object key = Files.readAttributes(file, "unix:ino,dev");
        long size = Files.size(file);
        FileTime time = Files.getLastModifiedTime(file);
        check(bytes.length == size, "same-size tamper");
        try (java.io.RandomAccessFile f = new java.io.RandomAccessFile(file.toFile(), "rw")) { f.write(bytes); }
        Files.setLastModifiedTime(file, time);
        check(key.equals(Files.readAttributes(file, "unix:ino,dev")) && Files.size(file) == size
            && time.equals(Files.getLastModifiedTime(file)), "identity restored after tamper: " + file);
    }

    // 资源包总字节数 +delta（manifest.json 的 total、构建描述 package.bytes）
    private static void bump(Path pack, int delta) throws IOException {
        Path m = pack.resolve("manifest.json"), a = pack.resolve(GamePack.ARTIFACT);
        Files.writeString(m, bumpNumber(Files.readString(m), "\"total\":", delta));
        Files.writeString(a, bumpNumber(Files.readString(a), "\"bytes\":", delta));
    }

    private static String bumpNumber(String text, String key, int delta) {
        int at = text.indexOf(key) + key.length(), end = at;
        while (Character.isDigit(text.charAt(end))) end++;
        return text.substring(0, at) + (Long.parseLong(text.substring(at, end)) + delta) + text.substring(end);
    }

    private static List<String> sums(Path root) throws IOException {
        try (var walk = Files.walk(root)) {
            return walk.filter(Files::isRegularFile).sorted().map(p -> {
                try { return root.relativize(p) + " " + GamePack.sha256(Files.readAllBytes(p)); }
                catch (IOException e) { throw new java.io.UncheckedIOException(e); }
            }).toList();
        }
    }
}
