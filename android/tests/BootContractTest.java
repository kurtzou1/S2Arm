package org.s2arm.android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.Locale;

/** Plain-Java checks for the runtime side of the A0 contract (no Android runtime). */
public final class BootContractTest {
    private static int failures;

    private static void check(boolean ok, String what) {
        if (!ok) {
            System.err.println("FAILED: " + what);
            failures++;
        }
    }

    private static void write(File root, String rel, String text) throws IOException {
        write(root, rel, text.getBytes(StandardCharsets.UTF_8));
    }

    private static void write(File root, String rel, byte[] data) throws IOException {
        File f = new File(root, rel);
        File parent = f.getParentFile();
        if (parent != null) parent.mkdirs();
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(data);
        }
    }

    private static String sha(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        md.update(Files.readAllBytes(f.toPath()));
        StringBuilder sb = new StringBuilder(64);
        for (byte b : md.digest()) sb.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        return sb.toString();
    }

    private static String artifact(String rewriteAbi, String image, String fixups) {
        return artifact(rewriteAbi, image, fixups, "modules/main.gates.tsv");
    }

    private static String artifact(String rewriteAbi, String image, String fixups, String gates) {
        return "{\n"
            + "  \"version\": 1,\n"
            + "  \"titleId\": \"0100000000ABCDEF\",\n"
            + "  \"contentRoot\": \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\n"
            + "  \"target\": \"android\",\n"
            + "  \"guestAbi\": \"aarch64\",\n"
            + "  \"rewriteAbi\": \"" + rewriteAbi + "\",\n"
            + "  \"runtime\": {\"version\": \"0.1.0\", \"backend\": \"vulkan\"},\n"
            + "  \"package\": {\"manifest\": \"manifest.json\", \"indexSha256\": \""
            + "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\", \"files\": 5, \"bytes\": 4096},\n"
            + "  \"npdm\": \"exefs/main.npdm\",\n"
            + "  \"control\": \"ctl/control.nacp\",\n"
            + "  \"romfs\": \"romfs\",\n"
            + "  \"modules\": [\n"
            + "    {\"name\": \"main\", \"source\": \"revision\", \"image\": \"" + image + "\", \"fixups\": \"" + fixups
            + "\", \"gates\": \"" + gates + "\", \"target\": \"android\"}\n"
            + "  ]\n"
            + "}\n";
    }

    private static String artifactApk(boolean withApk) {
        String apk = withApk
            ? "  \"apk\": {\"packageName\": \"org.s2arm.game.t0100000000abcdef\", \"versionCode\": 1, "
              + "\"sha256\": \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\", "
              + "\"signingCertSha256\": \"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\", "
              + "\"assetRoot\": \"game/modules\"},\n"
            : "";
        return "{\n"
            + "  \"version\": 1,\n"
            + "  \"titleId\": \"0100000000ABCDEF\",\n"
            + "  \"contentRoot\": \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\n"
            + "  \"target\": \"android\",\n"
            + "  \"guestAbi\": \"aarch64\",\n"
            + "  \"rewriteAbi\": \"" + BootContract.REWRITE_ABI + "\",\n"
            + "  \"runtime\": {\"version\": \"0.1.0\", \"backend\": \"vulkan\"},\n"
            + "  \"package\": {\"manifest\": \"manifest.json\", \"indexSha256\": \""
            + "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\", \"files\": 5, \"bytes\": 4096},\n"
            + apk
            + "  \"npdm\": \"exefs/main.npdm\",\n"
            + "  \"control\": \"ctl/control.nacp\",\n"
            + "  \"romfs\": \"romfs\",\n"
            + "  \"modules\": [\n"
            + "    {\"name\": \"main\", \"source\": \"apk-asset\", \"image\": \"main.patched.bin\", "
            + "\"fixups\": \"main.fixups.tsv\", \"gates\": \"main.gates.tsv\", \"target\": \"android\"}\n"
            + "  ]\n"
            + "}\n";
    }

    private static String artifactWithModules(String... names) {
        StringBuilder modules = new StringBuilder();
        for (int i = 0; i < names.length; i++) {
            String n = names[i];
            modules.append("    {\"name\": \"").append(n).append("\", \"source\": \"revision\", \"image\": \"modules/")
                .append(n).append(".patched.bin\", \"fixups\": \"modules/").append(n)
                .append(".fixups.tsv\", \"gates\": \"modules/").append(n)
                .append(".gates.tsv\", \"target\": \"android\"}");
            if (i + 1 < names.length) modules.append(',');
            modules.append('\n');
        }
        return artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replace("    {\"name\": \"main\", \"source\": \"revision\", \"image\": \"modules/main.patched.bin\", "
                + "\"fixups\": \"modules/main.fixups.tsv\", \"gates\": \"modules/main.gates.tsv\", \"target\": \"android\"}\n",
                modules.toString());
    }

    private static void writeModule(File root, String name) throws IOException {
        String rev = "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/";
        write(root, rev + "modules/" + name + ".patched.bin", new byte[4096]);
        write(root, rev + "modules/" + name + ".fixups.tsv",
            "# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n");
        write(root, rev + "modules/" + name + ".gates.tsv", "0x100\tsvc\t1\t0x128\n");
    }

    private static void replaceArtifact(File root, String artifact) throws Exception {
        File rev = new File(root, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        write(root, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/game-build-artifact.json", artifact);
        String sha = sha(new File(rev, "game-build-artifact.json"));
        write(root, "current.json", new String(Files.readAllBytes(new File(root, "current.json").toPath()), StandardCharsets.UTF_8)
            .replaceAll("\"artifactSha256\": \"[0-9a-f]{64}\"", "\"artifactSha256\": \"" + sha + "\""));
    }

    private static File valid() throws Exception {
        File base = Files.createTempDirectory("s2arm-boot-contract").toFile();
        File root = new File(base, "games/0100000000ABCDEF");
        if (!root.mkdirs()) throw new IOException("cannot create " + root);
        write(root, "manifest.json", "{\"version\":2,\"files\":5,\"total\":4096,\"index_sha256\":\""
            + "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"}\n");
        write(root, "index.tsv", "exefs/main.npdm\t128\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
        write(root, "exefs/main.npdm", new byte[128]);
        write(root, "ctl/control.nacp", new byte[0x4000]);
        write(root, "romfs/readme.txt", "hello\n");
        write(root, "modules/main.patched.bin", new byte[4096]);
        write(root, "modules/main.fixups.tsv", "# BUILD_ID\t00\n# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n");
        write(root, "modules/main.gates.tsv", "0x100\tsvc\t1\t0x128\n");
        String artifact = artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv");
        write(root, "game-build-artifact.json", artifact);
        String artifactSha = sha(new File(root, "game-build-artifact.json"));
        write(root, "current.json", "{\n"
            + "  \"version\": 1,\n"
            + "  \"titleId\": \"0100000000ABCDEF\",\n"
            + "  \"contentRoot\": \"sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\n"
            + "  \"revisionDir\": \"revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\n"
            + "  \"artifact\": \"game-build-artifact.json\",\n"
            + "  \"artifactSha256\": \"" + artifactSha + "\",\n"
            + "  \"activatedAt\": \"2026-10-22T05:30:00Z\",\n"
            + "  \"previousContentRoot\": null\n"
            + "}\n");
        // The artifact is inside the revision; move the package files there too.
        File rev = new File(root, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        for (String rel : new String[] {"manifest.json", "index.tsv", "exefs/main.npdm", "ctl/control.nacp",
                                        "romfs/readme.txt", "modules/main.patched.bin", "modules/main.fixups.tsv",
                                        "modules/main.gates.tsv", "game-build-artifact.json"}) {
            File src = new File(root, rel);
            File dst = new File(rev, rel);
            dst.getParentFile().mkdirs();
            Files.copy(src.toPath(), dst.toPath());
            src.delete();
        }
        return root;
    }

    private static BootContract.BadGame expectBad(File root, String what) {
        try {
            BootContract.open(root);
            check(false, what + " was accepted");
        } catch (BootContract.BadGame e) {
            check(true, what + " rejected: " + e.getMessage());
            return e;
        }
        return null;
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0) {
            BootContract.Game game = BootContract.open(new File(args[0]));
            check(game.summary().startsWith("Validated"), "staged game summary");
            System.out.println("BootContract game: " + game.summary());
            System.out.println(failures == 0 ? "BootContract: ok" : "BootContract: " + failures + " FAILED");
            if (failures != 0) System.exit(1);
            return;
        }
        File root = valid();
        BootContract.Game game = BootContract.open(root);
        check(game.titleId.equals("0100000000ABCDEF"), "title id");
        check(game.contentRoot.startsWith("sha256-"), "content root");
        check(game.modules.size() == 1 && game.modules.get(0).name.equals("main"), "module list");
        check(game.rewriteAbi.equals(BootContract.REWRITE_ABI), "rewrite ABI");
        check(game.summary().startsWith("Validated"), "validated summary");
        BootContract.Game mapped = BootContract.openAndMap(root, g -> "modules main map R|X (TARGET android, 4 KiB)");
        check(mapped.modulesDir.equals(game.modulesDir), "mapped module directory");
        check(mapped.summary().startsWith("ReadyToPlay"), "ready summary");
        try {
            BootContract.openAndMap(root, g -> "module main does not load: bad");
            check(false, "module map failure was accepted");
        } catch (BootContract.BadGame e) {
            check(true, "module map failure rejected: " + e.getMessage());
        }

        File apkRoot = valid();
        replaceArtifact(apkRoot, artifactApk(true));
        BootContract.Game apkGame = BootContract.open(apkRoot);
        check(apkGame.hasApkModules(), "apk-asset module source");
        check(apkGame.apk != null && apkGame.apk.packageName.equals("org.s2arm.game.t0100000000abcdef"), "apk identity");
        check(BootContract.openAndMap(apkRoot, g -> "modules main map R|X (apk-asset)").summary().startsWith("ReadyToPlay"),
            "apk-asset ready summary");
        File testApkRoot = valid();
        replaceArtifact(testApkRoot, artifactApk(true).replace("org.s2arm.game.t0100000000abcdef",
            "org.s2arm.game.t0100000000abcdef.w2"));
        BootContract.Game testGame = BootContract.open(testApkRoot);
        check(testGame.titleId.equals("0100000000ABCDEF"), "test suffix preserves title");
        check(testGame.apk.packageName.equals("org.s2arm.game.t0100000000abcdef.w2"), "test package structure");
        for (String name : new String[]{"org.s2arm.game.t0100000000abcdef.foo", "org.s2arm.game.t0100000000abcdef.w2.extra",
                "org.s2arm.game.t0100000000abcdef.W2", "org.s2arm.game.t0100000000000001.w2", "org.s2arm.game.t0100000000abcdef..w2",
                "org.s2arm.game.t0100000000abcdef.w2;bad", "org.s2arm.game.t0100000000abcdef.2w"}) {
            File badTestApk = valid();
            replaceArtifact(badTestApk, artifactApk(true).replace("org.s2arm.game.t0100000000abcdef", name));
            expectBad(badTestApk, "test suffix cannot replace title or contain invalid segments");
        }
        File noApk = valid();
        replaceArtifact(noApk, artifactApk(false));
        expectBad(noApk, "apk-asset module without apk object");

        File badAssetRoot = valid();
        replaceArtifact(badAssetRoot, artifactApk(true).replace("\"assetRoot\": \"game/modules\"",
            "\"assetRoot\": \"modules\""));
        expectBad(badAssetRoot, "apk assetRoot must be game/modules");

        File badPackage = valid();
        replaceArtifact(badPackage, artifactApk(true).replace("org.s2arm.game.t0100000000abcdef",
            "org.s2arm.game.g0100000000abcdef"));
        expectBad(badPackage, "apk package name must be t + titleId");

        File otherDir = valid();
        String otherRev = "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/";
        write(otherDir, otherRev + "other-modules/main.patched.bin", new byte[4096]);
        write(otherDir, otherRev + "other-modules/main.fixups.tsv", "# BUILD_ID\t00\n# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n");
        write(otherDir, otherRev + "other-modules/main.gates.tsv", "0x100\tsvc\t1\t0x128\n");
        replaceArtifact(otherDir, artifact(BootContract.REWRITE_ABI, "other-modules/main.patched.bin",
            "other-modules/main.fixups.tsv", "other-modules/main.gates.tsv"));
        BootContract.Game other = BootContract.openAndMap(otherDir, g -> {
            check(g.modules.get(0).image.equals("other-modules/main.patched.bin"), "validated module path reaches mapper");
            return "modules main map R|X (other-modules)";
        });
        check(other.modules.get(0).image.startsWith("other-modules/"), "other module path");

        File stagingRoot = valid();
        String contentRoot = "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        String finalRev = "revisions/" + contentRoot;
        String stagingRev = finalRev + ".staging";
        Files.move(new File(stagingRoot, finalRev).toPath(), new File(stagingRoot, stagingRev).toPath());
        File stagingArtifact = new File(stagingRoot, stagingRev + "/game-build-artifact.json");
        BootContract.Game staged = BootContract.validateRevision(stagingRoot, stagingRev, contentRoot,
            "game-build-artifact.json", sha(stagingArtifact));
        check(staged.revisionDir.equals(stagingRev), "staging revision validates before rename");
        String stagedBad = artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replace("0100000000ABCDEF", "0100000000000000");
        write(stagingRoot, stagingRev + "/game-build-artifact.json", stagedBad);
        try {
            BootContract.validateRevision(stagingRoot, stagingRev, contentRoot, "game-build-artifact.json",
                sha(new File(stagingRoot, stagingRev + "/game-build-artifact.json")));
            check(false, "staging title mismatch was accepted");
        } catch (BootContract.BadGame e) {
            check(e.getMessage().contains("titleId"), "staging title mismatch rejected: " + e.getMessage());
        }

        File objectRoot = valid();
        String objectHash = "ab" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".substring(0, 62);
        String revRoot = "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/";
        write(objectRoot, "objects/ab/" + objectHash, new byte[128]);
        File npdmLink = new File(objectRoot, revRoot + "exefs/main.npdm");
        npdmLink.delete();
        Files.createSymbolicLink(npdmLink.toPath(), Paths.get("../../../objects/ab/" + objectHash));
        BootContract.Game symlinked = BootContract.open(objectRoot);
        check(symlinked.titleId.equals("0100000000ABCDEF"), "object-store npdm symlink accepted");

        File badObject = valid();
        write(badObject, "objects/ab/not-a-sha", new byte[128]);
        File badLink = new File(badObject, revRoot + "exefs/main.npdm");
        badLink.delete();
        Files.createSymbolicLink(badLink.toPath(), Paths.get("../../../objects/ab/not-a-sha"));
        expectBad(badObject, "outside object store");

        File escape = valid();
        File escapeLink = new File(escape, revRoot + "exefs/main.npdm");
        escapeLink.delete();
        Files.createSymbolicLink(escapeLink.toPath(), Paths.get("../../../../outside"));
        expectBad(escape, "symlink escapes");

        File wrongFixup = valid();
        write(wrongFixup, otherRev + "modules/approved.fixups.tsv",
            "# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n");
        write(wrongFixup, otherRev + "modules/main.fixups.tsv",
            "# TARGET\tandroid\n# REWRITE_ABI\tandroid-below-sp-v1\n");
        replaceArtifact(wrongFixup, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin",
            "modules/approved.fixups.tsv"));
        expectBad(wrongFixup, "validated fixups differs from loader-inferred fixups");

        File nestedFixup = valid();
        write(nestedFixup, otherRev + "modules/nested/main.fixups.tsv",
            "# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n");
        replaceArtifact(nestedFixup, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin",
            "modules/nested/main.fixups.tsv"));
        expectBad(nestedFixup, "fixups in a nested directory");

        File wrongGates = valid();
        write(wrongGates, otherRev + "modules/approved.gates.tsv", "0x100\tsvc\t1\t0x128\n");
        replaceArtifact(wrongGates, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin",
            "modules/main.fixups.tsv", "modules/approved.gates.tsv"));
        expectBad(wrongGates, "gates differs from the image module name");

        File extended = valid();
        String extension = "\"extensions\": {\"org.example.build\": {\"note\": \"optional\"}}, \"requiredFeatures\": [], ";
        replaceArtifact(extended, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{" + extension));
        write(extended, "current.json", Files.readString(new File(extended, "current.json").toPath())
            .replaceFirst("\\{", "{" + extension));
        check(BootContract.open(extended).modules.size() == 1, "unknown optional metadata is accepted");

        File requiredArtifact = valid();
        replaceArtifact(requiredArtifact, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"requiredFeatures\": [\"org.example.gpu.v1\"],"));
        expectBad(requiredArtifact, "unsupported required artifact feature");

        File requiredInputRoles = valid();
        replaceArtifact(requiredInputRoles, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"requiredFeatures\": [\"s2arm.android-input-roles-v1\"],"));
        expectBad(requiredInputRoles, "unimplemented input-role capability is rejected");

        File requiredCurrent = valid();
        write(requiredCurrent, "current.json", Files.readString(new File(requiredCurrent, "current.json").toPath())
            .replaceFirst("\\{", "{\"requiredFeatures\": [\"org.example.gpu.v1\"],"));
        expectBad(requiredCurrent, "unsupported required activation feature");

        // C1：graphics.v1 required feature + extension 绑定描述文件。
        File graphics = valid();
        String graphicsPath = "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/shaders/vulkan/direct/graphics.v1.json";
        byte[] descriptor = "{\"schema\":\"s2a-graphics-v1\",\"titleId\":\"0100000000ABCDEF\"}".getBytes(StandardCharsets.UTF_8);
        write(graphics, graphicsPath, descriptor);
        String graphicsHash = sha(new File(graphics, graphicsPath));
        String graphicsExtension = "\"requiredFeatures\": [\"org.s2arm.graphics.v1\"], \"extensions\": {\"org.s2arm.graphics.v1\": "
            + "{\"manifest\": \"shaders/vulkan/direct/graphics.v1.json\", \"sha256\": \"" + graphicsHash
            + "\", \"bytes\": " + descriptor.length + "}}, ";
        replaceArtifact(graphics, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{" + graphicsExtension));
        BootContract.Game withGraphics = BootContract.open(graphics);
        check(withGraphics.graphics != null && java.util.Arrays.equals(withGraphics.graphics.descriptor, descriptor),
            "graphics descriptor bound to the verified artifact");
        check(withGraphics.graphics.bytes == descriptor.length && graphicsHash.equals(withGraphics.graphics.sha256),
            "graphics identity fields");

        File graphicsMissingExtension = valid();
        replaceArtifact(graphicsMissingExtension, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"requiredFeatures\": [\"org.s2arm.graphics.v1\"], "));
        expectBad(graphicsMissingExtension, "graphics feature without extension");

        File graphicsNoFeature = valid();
        write(graphicsNoFeature, graphicsPath, descriptor);
        replaceArtifact(graphicsNoFeature, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"extensions\": {\"org.s2arm.graphics.v1\": {\"manifest\": \"shaders/vulkan/direct/graphics.v1.json\", "
                + "\"sha256\": \"" + graphicsHash + "\", \"bytes\": " + descriptor.length + "}}, "));
        BootContract.Game noFeature = BootContract.open(graphicsNoFeature);   // 扩展在、只是没登记：照常接受并用上（不堵门）
        check(noFeature.graphics != null && noFeature.graphics.sha256.equals(graphicsHash), "graphics extension without required feature still used");

        File graphicsWrongHash = valid();
        write(graphicsWrongHash, graphicsPath, descriptor);
        replaceArtifact(graphicsWrongHash, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"requiredFeatures\": [\"org.s2arm.graphics.v1\"], \"extensions\": {\"org.s2arm.graphics.v1\": "
                + "{\"manifest\": \"shaders/vulkan/direct/graphics.v1.json\", \"sha256\": \"" + graphicsHash + "\", \"bytes\": "
                + (descriptor.length + 1) + "}}, "));
        expectBad(graphicsWrongHash, "graphics byte length mismatch");

        File graphicsBadManifest = valid();
        write(graphicsBadManifest, graphicsPath, descriptor);
        replaceArtifact(graphicsBadManifest, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"requiredFeatures\": [\"org.s2arm.graphics.v1\"], \"extensions\": {\"org.s2arm.graphics.v1\": "
                + "{\"manifest\": \"shaders/vulkan/direct/other.json\", \"sha256\": \"" + graphicsHash + "\", \"bytes\": "
                + descriptor.length + "}}, "));
        expectBad(graphicsBadManifest, "graphics manifest path is not the frozen location");

        File graphicsExtraField = valid();
        write(graphicsExtraField, graphicsPath, descriptor);
        replaceArtifact(graphicsExtraField, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"requiredFeatures\": [\"org.s2arm.graphics.v1\"], \"extensions\": {\"org.s2arm.graphics.v1\": "
                + "{\"manifest\": \"shaders/vulkan/direct/graphics.v1.json\", \"sha256\": \"" + graphicsHash + "\", \"bytes\": "
                + descriptor.length + ", \"path\": \"x\"}}, "));
        expectBad(graphicsExtraField, "graphics extension extra field");

        File badExtension = valid();
        replaceArtifact(badExtension, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"extensions\": {\"unqualified\": {}},"));
        expectBad(badExtension, "extension key without namespace");

        File badExtensionValue = valid();
        replaceArtifact(badExtensionValue, artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv")
            .replaceFirst("\\{", "{\"extensions\": {\"org.example.build\": 1},"));
        expectBad(badExtensionValue, "extension payload without object");

        File badHash = valid();
        write(badHash, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/game-build-artifact.json",
            artifact(BootContract.REWRITE_ABI, "modules/main.patched.bin", "modules/main.fixups.tsv").replace("0.1.0", "0.1.1"));
        expectBad(badHash, "artifact hash mismatch");

        File badAbi = valid();
        File rev = new File(badAbi, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        write(badAbi, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/game-build-artifact.json",
            artifact("android-v0", "modules/main.patched.bin", "modules/main.fixups.tsv"));
        String abiSha = sha(new File(rev, "game-build-artifact.json"));
        write(badAbi, "current.json", new String(Files.readAllBytes(new File(badAbi, "current.json").toPath()), StandardCharsets.UTF_8)
            .replaceAll("\"artifactSha256\": \"[0-9a-f]{64}\"", "\"artifactSha256\": \"" + abiSha + "\""));
        expectBad(badAbi, "unsupported rewrite ABI");

        File badPath = valid();
        write(badPath, "current.json", new String(Files.readAllBytes(new File(badPath, "current.json").toPath()), StandardCharsets.UTF_8)
            .replace("\"revisionDir\": \"revisions/", "\"revisionDir\": \"revisions/../"));
        expectBad(badPath, "path traversal");

        File badTarget = valid();
        write(badTarget, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/modules/main.fixups.tsv",
            "# BUILD_ID\t00\n");
        expectBad(badTarget, "missing # TARGET android");

        File badAbiHeader = valid();
        write(badAbiHeader, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/modules/main.fixups.tsv",
            "# BUILD_ID\t00\n# TARGET\tandroid\n");
        expectBad(badAbiHeader, "missing # REWRITE_ABI");

        File badAbiPrefix = valid();
        write(badAbiPrefix, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/modules/main.fixups.tsv",
            "# BUILD_ID\t00\n# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1-CORRUPT\n");
        expectBad(badAbiPrefix, "ABI is not a prefix match");

        File duplicateAbi = valid();
        write(duplicateAbi, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/modules/main.fixups.tsv",
            "# BUILD_ID\t00\n# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n# REWRITE_ABI\tandroid-sp-safe-v1\n");
        expectBad(duplicateAbi, "duplicate ABI header");

        File missing = valid();
        check(new File(missing, "revisions/sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/modules/main.patched.bin").delete(),
            "delete module");
        expectBad(missing, "missing module image");

        File badJson = valid();
        write(badJson, "current.json", "{");
        expectBad(badJson, "invalid JSON");

        // Horizon 装载序：main → subsdk0..N（数字序）→ sdk；artifact 的 modules 顺序就是装载顺序。
        File ordered = valid();
        writeModule(ordered, "subsdk0");
        writeModule(ordered, "subsdk2");
        writeModule(ordered, "subsdk10");
        writeModule(ordered, "sdk");
        replaceArtifact(ordered, artifactWithModules("main", "subsdk0", "subsdk2", "subsdk10", "sdk"));
        BootContract.Game orderedGame = BootContract.open(ordered);
        check(orderedGame.modules.size() == 5 && orderedGame.modules.get(3).name.equals("subsdk10"),
            "Horizon order main/subsdk0/2/10/sdk accepted");

        File wrongOrder = valid();
        writeModule(wrongOrder, "subsdk0");
        writeModule(wrongOrder, "sdk");
        replaceArtifact(wrongOrder, artifactWithModules("main", "sdk", "subsdk0"));
        BootContract.Game reordered = BootContract.open(wrongOrder);   // 旧字母序包不拒收：按 Horizon 装载序排好（不堵门）
        check(reordered.modules.size() == 3 && reordered.modules.get(0).name.equals("main")
            && reordered.modules.get(1).name.equals("subsdk0") && reordered.modules.get(2).name.equals("sdk"),
            "old alphabetical order reordered to main/subsdk0/sdk");

        File badNumeric = valid();
        writeModule(badNumeric, "subsdk2");
        writeModule(badNumeric, "subsdk10");
        writeModule(badNumeric, "sdk");
        replaceArtifact(badNumeric, artifactWithModules("main", "subsdk10", "subsdk2", "sdk"));
        BootContract.Game numeric = BootContract.open(badNumeric);   // subsdk 数字序错：排好（不堵门）
        check(numeric.modules.get(1).name.equals("subsdk2") && numeric.modules.get(2).name.equals("subsdk10"), "subsdk numeric order restored");

        File mainNotFirst = valid();
        writeModule(mainNotFirst, "subsdk0");
        replaceArtifact(mainNotFirst, artifactWithModules("subsdk0", "main"));
        BootContract.Game mainFirst = BootContract.open(mainNotFirst);   // main 不在第一：排到第一（不堵门）
        check(mainFirst.modules.get(0).name.equals("main") && mainFirst.modules.get(1).name.equals("subsdk0"), "main moved first");

        System.out.println(failures == 0 ? "BootContract: ok" : "BootContract: " + failures + " FAILED");
        if (failures != 0) System.exit(1);
    }
}
