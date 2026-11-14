package org.s2arm.android;

import android.content.Context;
import android.content.Intent;

/** One Activity/session per :game process; the existing native shutdown retires all guest resources. */
public final class GameActivity extends MainActivity {
    static final String LIFECYCLE_TEST_EXTRA = "s2arm.lifecycle_test";
    static final String TITLE_EXTRA = "s2arm.title_id";
    /** 跳板回局的控制标记：bare intent 无 s2arm.* 会被 isLaunch 当起局、替换库局被
        判 mismatch stopGame；带它在 CONTROL_EXTRAS 里 → 控制 intent、不动会话（#1474）。 */
    static final String ICON_RESUME_EXTRA = "s2arm.icon_resume";

    /** 玩家在库页确认「结束当前游戏、启动另一款」：正在跑的那局收到后走正常收局（不在调试参数名单里，正式包可用）。 */
    static final String SWITCH_EXTRA = "org.s2arm.android.SWITCH_GAME";

    static Intent launch(Context context, Intent options, String titleId) {
        Intent intent = new Intent(context, GameActivity.class);
        if (options != null && options.getExtras() != null) intent.putExtras(options.getExtras());
        intent.putExtra(TITLE_EXTRA, titleId);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return intent;
    }

    /** #1474：跳板把 bare intent 投进缓存的 :game 进程、activity 已被裁只剩进程时——
        新起实例无 title 且进程无活会话 → 转库页；活会话或畸形 title 维持原红屏。 */
    static boolean libraryRoute(Intent intent, boolean sessionRunning) {
        return intent.getStringExtra(TITLE_EXTRA) == null && !sessionRunning;
    }

    static int runningPid(Context context) {
        android.app.ActivityManager manager = context.getSystemService(android.app.ActivityManager.class);
        java.util.List<android.app.ActivityManager.RunningAppProcessInfo> processes = manager.getRunningAppProcesses();
        if (processes != null) for (var process : processes)
            if ((context.getPackageName() + ":game").equals(process.processName)) return process.pid;
        return 0;
    }
}
