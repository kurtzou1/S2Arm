package org.s2arm.android;

import java.io.File;
import java.nio.file.AccessDeniedException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * 游戏库「重新打开帧率补丁」（StallOff）的宿主回归，期望按口径手写：标记在本款 state 目录（与起局同一处，GameSession.stateDir 建的那个）；
 * 没标记 / 标记是目录都不算关着；重新打开 = 删标记、之后不算关着；删不掉时返回真原因、标记还在。
 */
public final class StallOffTest {
    private static int checks;
    private static void demand(boolean ok, String what) { checks++; if (!ok) throw new AssertionError(what); }

    public static void main(String[] args) throws Exception {
        Path base = Files.createTempDirectory("s2a-stall-off");
        File root = base.resolve("files").toFile();
        String id = "0100633007D48000";
        File state = GameSession.stateDir(root, id);   // 起局建的那个目录
        demand(StallOff.mark(root, id).getCanonicalFile().equals(new File(state, "cpatch_stall_off").getCanonicalFile()), "mark sits in the start-up state directory");

        demand(!StallOff.marked(root, id), "no mark: not off");
        demand(StallOff.reopen(root, id) == null, "reopen with no mark: nothing to do, no error");

        Files.write(StallOff.mark(root, id).toPath(), "fps\n".getBytes());
        demand(StallOff.marked(root, id), "mark: off");
        demand(!StallOff.marked(root, "0100DCA0064A6000"), "another game is not affected");
        demand(StallOff.reopen(root, id) == null, "reopen succeeds");
        demand(!StallOff.mark(root, id).exists() && !StallOff.marked(root, id), "after reopen: mark gone, not off");

        Files.createDirectory(StallOff.mark(root, id).toPath());
        demand(!StallOff.marked(root, id), "a directory is not a mark (same as start-up)");
        Files.delete(StallOff.mark(root, id).toPath());

        // 删不掉：注入一个必定失败的删法（同真机上删不掉时文件系统抛的 AccessDeniedException），不靠改目录权限——
        //   root 下权限挡不住删除，那样造出来的「删不掉」在 root 跑的门禁里不成立（11-26 joe-win 门禁以 root 跑）。
        Files.write(StallOff.mark(root, id).toPath(), "fps\n".getBytes());
        String why = StallOff.reopen(root, id, p -> { throw new AccessDeniedException(p.toString()); });
        demand(why != null && why.equals("AccessDeniedException: " + StallOff.mark(root, id).getPath()), "undeletable mark reports the real cause, got " + why);
        demand(StallOff.marked(root, id), "undeletable mark is still there");
        demand(StallOff.reopen(root, id) == null && !StallOff.marked(root, id), "the production deleter removes it afterwards");
        System.out.println("StallOffTest: ok (" + checks + " checks)");
    }
}
