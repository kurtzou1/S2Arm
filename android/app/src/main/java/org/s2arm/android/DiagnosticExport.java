// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.annotation.SuppressLint;
import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.TreeMap;

/**
 * #528 item 15: the Android side of "export diagnostics". Collects what only a Context knows
 * (this app's directories, the imported key file, version and device facts) and runs
 * DiagnosticBundleWriter. Call off the main thread.
 */
final class DiagnosticExport {
    private static final long MAX_KEY_FILE_BYTES = 1 << 20;

    private DiagnosticExport() {}

    static Path run(Context context) throws IOException {
        DiagnosticRedactor redactor = new DiagnosticRedactor(prefixes(context), DiagnosticRedactor.keyValues(keyText(context)));
        Path saves = new File(context.getFilesDir(), "user/0/saves").toPath();   // same root as BootSpecSource
        String word = Locale.getDefault().getLanguage().equals("zh") ? "诊断" : "diag";
        return DiagnosticBundleWriter.write(saves, DiagnosticShareProvider.checkedDirectory(context), redactor::redact,
                                            info(context), exits(context), word, System.currentTimeMillis(), TimeZone.getDefault()).bundle;
    }

    /** This app's own directories, under every spelling a log may use; the rest of each path is kept. */
    @SuppressLint("SdCardPath")   // the literal aliases are what logs contain; they are matched, never opened
    static List<String[]> prefixes(Context context) {
        Map<String, String> found = new LinkedHashMap<>();
        File data = context.getDataDir();
        add(found, data.getAbsolutePath(), "<APP>");
        add(found, "/data/data/" + context.getPackageName(), "<APP>");
        add(found, "/data/user/0/" + context.getPackageName(), "<APP>");
        try { add(found, data.getCanonicalPath(), "<APP>"); } catch (IOException ignored) { }
        ApplicationInfo app = context.getApplicationInfo();
        if (app.sourceDir != null) add(found, new File(app.sourceDir).getParent(), "<BUNDLE>");
        File external = context.getExternalFilesDir(null);
        if (external != null) add(found, external.getParentFile() == null ? null : external.getParentFile().getAbsolutePath(), "<APP_EXT>");
        List<String[]> pairs = new ArrayList<>();
        for (Map.Entry<String, String> e : found.entrySet()) pairs.add(new String[] {e.getKey(), e.getValue()});
        return pairs;
    }

    /** How this app's processes (library, :game) ended, newest first; none before API 30. */
    static List<Map<String, Object>> exits(Context context) {
        List<Map<String, Object>> out = new ArrayList<>();
        if (Build.VERSION.SDK_INT < 30) return out;
        ActivityManager am = context.getSystemService(ActivityManager.class);
        if (am == null) return out;
        List<ApplicationExitInfo> all = new ArrayList<>(am.getHistoricalProcessExitReasons(context.getPackageName(), 0, DiagnosticExits.MAX_RECORDS));
        all.sort((a, b) -> Long.compare(b.getTimestamp(), a.getTimestamp()));
        for (ApplicationExitInfo e : all)
            out.add(DiagnosticExits.record(e.getTimestamp(), e.getProcessName(), e.getReason(), e.getStatus(), e.getImportance(),
                                           e.getPss(), e.getRss(), e.getDescription()));
        return out;
    }

    private static void add(Map<String, String> found, String path, String placeholder) {
        if (path == null || !path.startsWith("/") || path.length() < 2) return;
        while (path.length() > 1 && path.endsWith("/")) path = path.substring(0, path.length() - 1);
        found.putIfAbsent(path, placeholder);
    }

    /** The imported prod.keys (PlayerKeys), so its values are redacted wherever they appear. Missing = none. */
    private static String keyText(Context context) throws IOException {
        Path keys = new File(context.getFilesDir(), "keys/prod.keys").toPath();
        if (!Files.exists(keys, LinkOption.NOFOLLOW_LINKS)) return "";
        BasicFileAttributes a = Files.readAttributes(keys, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        // A key file that cannot be read safely means its values cannot be hidden: refuse the export.
        if (!a.isRegularFile() || a.size() > MAX_KEY_FILE_BYTES) throw new IOException("key file unreadable");
        return new String(Files.readAllBytes(keys), StandardCharsets.UTF_8);
    }

    private static Map<String, Map<String, String>> info(Context context) {
        Map<String, String> app = new TreeMap<>(), device = new TreeMap<>(), settings = new TreeMap<>();
        app.put("package", context.getPackageName());
        try {
            PackageInfo p = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            app.put("version", p.versionName == null ? "" : p.versionName);
            app.put("version_code", Long.toString(p.getLongVersionCode()));
        } catch (PackageManager.NameNotFoundException e) {
            app.put("version", "");
        }
        device.put("manufacturer", Build.MANUFACTURER);
        device.put("model", Build.MODEL);
        device.put("android", Build.VERSION.RELEASE);
        device.put("sdk", Integer.toString(Build.VERSION.SDK_INT));
        device.put("abi", Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "");
        device.put("soc", Build.VERSION.SDK_INT >= 31 ? Build.SOC_MODEL : "");
        settings.put("language", Locale.getDefault().toLanguageTag());
        Map<String, Map<String, String>> info = new TreeMap<>();
        info.put("app", app);
        info.put("device", device);
        info.put("settings", settings);
        return info;
    }
}
