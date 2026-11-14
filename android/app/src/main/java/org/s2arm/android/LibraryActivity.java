package org.s2arm.android;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.HashSet;
import java.util.Set;

/** The library never loads the native runtime. Each explicit launch is admitted again in :game. */
public final class LibraryActivity extends Activity {
    private GameLibrary library;
    private TextView status;
    private LinearLayout more;
    private LibraryShelf shelf;
    private CheckBox fpsOverlay;
    private final Set<String> listed = new HashSet<>();
    private final java.util.Map<String, String> names = new java.util.HashMap<>();
    private final android.os.Handler ui = new android.os.Handler(android.os.Looper.getMainLooper());
    private static final int PICK_PACKAGE = 1;
    // A caller opts in to consuming one direct child of files/import/.
    public static final String EXTRA_IMPORT_STAGING = "org.s2arm.android.IMPORT_STAGING";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        // 与 iOS 同一个样子（shell/Sources/ShellUI/CoverFlowView.swift）：横屏封面流，点正中的卡片开始玩。
        //   导入 / 帧率显示 / 诊断包不在主页面：右上「游戏设置」「设置」两个圆钮打开右侧面板（iOS 的设置页还没整套搬过来，先放这三项）。
        float density = getResources().getDisplayMetrics().density;
        android.widget.FrameLayout root = new android.widget.FrameLayout(this);
        more = new LinearLayout(this); more.setOrientation(LinearLayout.VERTICAL); more.setVisibility(android.view.View.GONE);
        int pad = Math.round(20 * density);
        more.setPadding(pad, pad, pad, pad);
        more.setBackgroundColor(0xF01A1A1C);
        shelf = new LibraryShelf(this, new LibraryShelf.Listener() {
            @Override public void play(String titleId) { launch(titleId); }
            @Override public void openGameSettings() { toggleMore(); }
            @Override public void openControllers() { toggleMore(); }
            @Override public void openSettings() { toggleMore(); }
        });
        root.addView(shelf, new android.widget.FrameLayout.LayoutParams(-1, -1));
        Button importButton = new Button(this); importButton.setText(R.string.import_game);
        importButton.setOnClickListener(v -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_PACKAGE));
        more.addView(importButton);
        android.content.SharedPreferences display = getSharedPreferences("display", MODE_PRIVATE);
        fpsOverlay = new CheckBox(this);
        fpsOverlay.setText(R.string.fps_overlay_show);
        fpsOverlay.setTextColor(0xFFFFFFFF);
        fpsOverlay.setChecked(display.getBoolean("fps", false));
        fpsOverlay.setOnCheckedChangeListener((button, checked) -> {
            if (display.getBoolean("fps", false) != checked)
                display.edit().putBoolean("fps", checked).apply();
        });
        more.addView(fpsOverlay);
        // #528 item 15: works without any game; the bundle goes to whatever app the player picks.
        Button exportButton = new Button(this); exportButton.setText(R.string.export_diagnostics);
        exportButton.setOnClickListener(v -> exportDiagnostics(exportButton));
        more.addView(exportButton);
        root.addView(more, new android.widget.FrameLayout.LayoutParams(Math.round(320 * density), -1, android.view.Gravity.END));
        // 状态行只给玩家看得懂的：导入进度、失败原因；库清单（Games: 文件数 / 哈希…）只进日志，不上屏
        status = new TextView(this); status.setVisibility(android.view.View.GONE);
        status.setTextColor(0xFFFFFFFF); status.setPadding(pad, pad / 2, pad, pad / 2); status.setBackgroundColor(0xB3000000);
        root.addView(status, new android.widget.FrameLayout.LayoutParams(-1, -2, android.view.Gravity.BOTTOM));
        setContentView(root);
        library = new GameLibrary(getApplicationContext(), new GameLibrary.Listener() {
            @Override public void onStatus(String text) { runOnUiThread(() -> {
                if (isDestroyed()) return;
                status.setText(text);
                status.setVisibility(text.startsWith("Games:") ? android.view.View.GONE : android.view.View.VISIBLE);
            }); }
            @Override public void onGameAvailable(String titleId, String name, java.io.File art) { runOnUiThread(() -> {
                if (isDestroyed() || !listed.add(titleId)) return;
                names.put(titleId, name);
                shelf.addGame(titleId, name, art);
            }); }
        });
    }

    private void toggleMore() {
        more.setVisibility(more.getVisibility() == android.view.View.GONE ? android.view.View.VISIBLE : android.view.View.GONE);
    }

    private void show(String text) { status.setText(text); status.setVisibility(android.view.View.VISIBLE); }

    private void launch(String titleId) { launch(titleId, 0); }

    // 不堵门：点的就是正在跑的那款 → 回到它；那款还在启动、收条没写出 → 等一会儿再回到它；
    //   正在跑的是别的款 → 问玩家要不要结束它（照常收局保存）再起这一款，而不是报「launch refused」
    private void launch(String titleId, int waited) {
        Intent options = new Intent(getIntent());
        options.removeExtra(GameResume.EXTRA);
        options.removeExtra(GameActivity.SWITCH_EXTRA);
        int pid = GameActivity.runningPid(this);
        if (pid != 0) {
            try {
                options.putExtra(GameResume.EXTRA,
                    GameResume.requireSame(getCacheDir(), pid, titleId, new java.io.File(getFilesDir(), "games")));
            } catch (java.io.IOException | BootContract.BadGame | RuntimeException notSame) {
                String active = GameResume.activeTitle(getCacheDir());
                if ((active == null || active.equals(titleId)) && waited < 20) {   // 还在启动：每 0.5 秒再看一次，最多 10 秒
                    show(getString(R.string.library_game_starting));
                    ui.postDelayed(() -> { if (!isDestroyed()) launch(titleId, waited + 1); }, 500);
                    return;
                }
                confirmSwitch(active, titleId);
                return;
            }
        }
        try {
            startActivity(GameActivity.launch(this, options, titleId));
        } catch (RuntimeException error) {
            status.setTextColor(0xFFFF5252);
            show(getString(R.string.library_launch_failed, String.valueOf(error.getMessage())));
        }
    }

    private String label(String titleId) {
        if (titleId == null) return getString(R.string.library_current_game);
        String name = names.get(titleId);
        return name != null ? name : titleId;
    }

    private void confirmSwitch(String active, String titleId) {
        new android.app.AlertDialog.Builder(this)
            .setTitle(R.string.library_switch_title)
            .setMessage(getString(R.string.library_switch_message, label(active), label(titleId)))
            .setPositiveButton(R.string.library_switch_confirm, (dialog, which) -> switchTo(active, titleId))
            .setNegativeButton(R.string.library_switch_cancel, null)
            .show();
    }

    // 让正在跑的那局正常收局（MainActivity.onNewIntent 认 SWITCH_EXTRA），等它的进程退出再起新款；20 秒还没退就如实说
    private void switchTo(String active, String titleId) {
        Intent stop = new Intent(getIntent());
        stop.removeExtra(GameResume.EXTRA);
        stop.putExtra(GameActivity.SWITCH_EXTRA, true);
        try {
            startActivity(GameActivity.launch(this, stop, titleId));
        } catch (RuntimeException error) {
            status.setTextColor(0xFFFF5252);
            show(getString(R.string.library_launch_failed, String.valueOf(error.getMessage())));
            return;
        }
        show(getString(R.string.library_switch_waiting, label(active)));
        waitThenLaunch(titleId, 0);
    }

    private void waitThenLaunch(String titleId, int tries) {
        if (isDestroyed()) return;
        if (GameActivity.runningPid(this) == 0) { launch(titleId); return; }
        if (tries >= 40) {
            status.setTextColor(0xFFFF5252);
            show(getString(R.string.library_switch_timeout));
            return;
        }
        ui.postDelayed(() -> waitThenLaunch(titleId, tries + 1), 500);
    }

    private void exportDiagnostics(Button button) {
        button.setEnabled(false);
        show(getString(R.string.export_diagnostics_running));
        android.content.Context app = getApplicationContext();
        new Thread(() -> {
            java.nio.file.Path bundle = null;
            String error = null;
            try {
                bundle = DiagnosticExport.run(app);
            } catch (java.io.IOException | RuntimeException e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            }
            java.nio.file.Path done = bundle;
            String failure = error;
            runOnUiThread(() -> {
                if (isDestroyed()) return;
                button.setEnabled(true);
                if (done == null) {
                    show(getString(R.string.export_diagnostics_failed, failure));
                    return;
                }
                android.net.Uri uri = DiagnosticShareProvider.uri(this, done);
                Intent send = new Intent(Intent.ACTION_SEND).setType("application/zip")
                    .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                send.setClipData(android.content.ClipData.newRawUri(done.getFileName().toString(), uri));
                show(getString(R.string.export_diagnostics_done, done.getFileName().toString()));
                startActivity(Intent.createChooser(send, getString(R.string.export_diagnostics)));
            });
        }, "s2a-diag-export").start();
    }

    @Override protected void onResume() {
        super.onResume();
        fpsOverlay.setChecked(getSharedPreferences("display", MODE_PRIVATE).getBoolean("fps", false));
        if (library != null) {
            String staging = getIntent().getStringExtra(EXTRA_IMPORT_STAGING);
            getIntent().removeExtra(EXTRA_IMPORT_STAGING); // do not repeat on later resumes
            library.scanImports(staging);
        }
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == PICK_PACKAGE && result == RESULT_OK && data != null && data.getData() != null) library.importTree(data.getData());
    }
    @Override protected void onDestroy() { if (library != null) library.close(); super.onDestroy(); }
}
