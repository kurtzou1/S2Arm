package org.s2arm.android;

import android.content.Context;

import java.io.FileNotFoundException;

/**
 * 玩家看到的失败文案：做什么没成功 + 真原因（玩家能懂的一句）+ 下一步，原始异常串留在最后一行当细节。
 * 跟随界面语言（values / values-zh）；日志仍记原始英文串，工具和诊断照旧按它认。
 */
final class PlayerError {
    enum Reason { NO_SPACE, APK_MISMATCH, NO_ACCESS, BAD_PACK, OTHER }

    private PlayerError() { }

    /** 只看异常本身归类：认不出的归 OTHER（下一步是导出诊断包），不猜。 */
    static Reason reason(Throwable error) {
        String m = String.valueOf(error == null ? null : error.getMessage());
        if (m.contains("No space left") || m.contains("ENOSPC")) return Reason.NO_SPACE;
        if (m.contains("APK identity") || m.contains("installed APK") || m.contains("the artifact is for")
                || m.contains("signing certificate")) return Reason.APK_MISMATCH;
        // FileNotFoundException 既可能是没权限也可能是文件缺：只按权限字样归「读不到」，缺文件归「包不完整」。
        if (error instanceof SecurityException || m.contains("Permission denied") || m.contains("EACCES")) return Reason.NO_ACCESS;
        if (error instanceof GamePack.BadPack || error instanceof BootContract.BadGame
                || error instanceof FileNotFoundException || m.contains("ENOENT")) return Reason.BAD_PACK;
        return Reason.OTHER;
    }

    /** what：R.string.player_err_import / player_err_start。返回的文案以 getString(what) 开头。 */
    static String text(Context context, int what, Throwable error) {
        int cause, next;
        switch (reason(error)) {
            case NO_SPACE: cause = R.string.player_err_no_space; next = R.string.player_err_no_space_next; break;
            case APK_MISMATCH: cause = R.string.player_err_apk; next = R.string.player_err_apk_next; break;
            case NO_ACCESS: cause = R.string.player_err_access; next = R.string.player_err_access_next; break;
            case BAD_PACK: cause = R.string.player_err_pack; next = R.string.player_err_pack_next; break;
            default: cause = R.string.player_err_other; next = R.string.player_err_other_next; break;
        }
        String detail = error == null ? "" : String.valueOf(error.getMessage());
        return context.getString(R.string.player_err_fmt, context.getString(what), context.getString(cause),
            context.getString(next), detail);
    }
}
