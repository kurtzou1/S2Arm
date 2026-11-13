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
    private LinearLayout rows;
    private CheckBox fpsOverlay;
    private final Set<String> listed = new HashSet<>();
    private static final int PICK_PACKAGE = 1;
    // A caller opts in to consuming one direct child of files/import/.
    public static final String EXTRA_IMPORT_STAGING = "org.s2arm.android.IMPORT_STAGING";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        rows = new LinearLayout(this); rows.setOrientation(LinearLayout.VERTICAL);
        int pad = Math.round(24 * getResources().getDisplayMetrics().density);
        rows.setPadding(pad, pad, pad, pad);
        status = new TextView(this); status.setText("S2Arm library"); rows.addView(status);
        Button importButton = new Button(this); importButton.setText(R.string.import_game);
        importButton.setOnClickListener(v -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_PACKAGE));
        rows.addView(importButton);
        android.content.SharedPreferences display = getSharedPreferences("display", MODE_PRIVATE);
        fpsOverlay = new CheckBox(this);
        fpsOverlay.setText(R.string.fps_overlay_show);
        fpsOverlay.setChecked(display.getBoolean("fps", false));
        fpsOverlay.setOnCheckedChangeListener((button, checked) -> {
            if (display.getBoolean("fps", false) != checked)
                display.edit().putBoolean("fps", checked).apply();
        });
        rows.addView(fpsOverlay);
        // #528 item 15: works without any game; the bundle goes to whatever app the player picks.
        Button exportButton = new Button(this); exportButton.setText(R.string.export_diagnostics);
        exportButton.setOnClickListener(v -> exportDiagnostics(exportButton));
        rows.addView(exportButton);
        android.widget.ScrollView scroll = new android.widget.ScrollView(this); scroll.addView(rows); setContentView(scroll);
        library = new GameLibrary(getApplicationContext(), new GameLibrary.Listener() {
            @Override public void onStatus(String text) { runOnUiThread(() -> { if (!isDestroyed()) status.setText(text); }); }
            @Override public void onGameAvailable(String titleId, String name) { runOnUiThread(() -> {
                if (isDestroyed() || !listed.add(titleId)) return;
                Button play = new Button(LibraryActivity.this); play.setText("Play " + name + " [" + titleId + "]");
                play.setOnClickListener(v -> launch(titleId)); rows.addView(play);
            }); }
        });
    }

    private void launch(String titleId) {
        try {
            Intent options = new Intent(getIntent());
            options.removeExtra(GameResume.EXTRA);
            int pid = GameActivity.runningPid(this);
            if (pid != 0) options.putExtra(GameResume.EXTRA,
                GameResume.requireSame(getCacheDir(), pid, titleId, new java.io.File(getFilesDir(), "games")));
            startActivity(GameActivity.launch(this, options, titleId));
        } catch (java.io.IOException | BootContract.BadGame | RuntimeException error) {
            status.setTextColor(0xFFFF5252);
            status.setText("Game launch refused: " + error.getMessage());
        }
    }

    private void exportDiagnostics(Button button) {
        button.setEnabled(false);
        status.setText(R.string.export_diagnostics_running);
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
                    status.setText(getString(R.string.export_diagnostics_failed, failure));
                    return;
                }
                android.net.Uri uri = DiagnosticShareProvider.uri(this, done);
                Intent send = new Intent(Intent.ACTION_SEND).setType("application/zip")
                    .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                send.setClipData(android.content.ClipData.newRawUri(done.getFileName().toString(), uri));
                status.setText(getString(R.string.export_diagnostics_done, done.getFileName().toString()));
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
