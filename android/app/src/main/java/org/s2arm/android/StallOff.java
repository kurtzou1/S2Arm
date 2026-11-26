package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * 停帧救场的「这款帧率补丁下次也关」标记（runtime/src/cpatch.c s2a_cpatch_persist_fps_off 写进本款 state 目录；
 * 起局由 android/native/docs_android.c s2a_android_stall_off_apply 读，有标记就 S2A_FPS60=0）。
 * 安卓没有按款的帧率设置，这个标记就是那项设置：游戏库面板有标记时给「重新打开」，点了删标记，下次起局帧率补丁照常开
 * （同 Mac：玩家在设置里把「60 帧」开回去）。不依赖 Android，宿主单测 StallOffTest 直接测。
 */
final class StallOff {
    /** 文件名同 cpatch.c / docs_android.c */
    static final String FILE = "cpatch_stall_off";

    /** 这款的标记：起局交给原生层的同一个 state 目录（GameSession.statePath 只算不建）下的 cpatch_stall_off。 */
    static File mark(File privateRoot, String titleId) { return new File(GameSession.statePath(privateRoot, titleId), FILE); }

    /** 这款的帧率补丁是不是被停帧救场关着（起局读的口径：是普通文件才算）。 */
    static boolean marked(File privateRoot, String titleId) { return mark(privateRoot, titleId).isFile(); }

    /** 删标记这一步（可替换：宿主单测换成必定失败的删法，验「删不掉报真原因」，不靠文件权限造——root 下权限挡不住删除）。 */
    interface Deleter { void delete(Path p) throws IOException; }

    /** 重新打开：删标记。null = 删了（或本来就没有）；否则是删不掉的真原因（异常类名 + 消息）。 */
    static String reopen(File privateRoot, String titleId) { return reopen(privateRoot, titleId, Files::deleteIfExists); }

    static String reopen(File privateRoot, String titleId, Deleter deleter) {
        File f = mark(privateRoot, titleId);
        try { deleter.delete(f.toPath()); return null; }
        catch (IOException | SecurityException e) { return e.getClass().getSimpleName() + ": " + e.getMessage(); }
    }
}
