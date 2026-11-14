// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/**
 * The player's own touch layout, one F01 file per game (iOS keeps one "mine" layout per game too).
 * No Android types: the directory comes from the Activity, so host tests can use a temp folder.
 * A missing file means the built-in layout; a damaged one is reported, never half-applied.
 */
final class TouchLayoutStore {
    static final int MAX_IMPORT_BYTES = 65536;
    static final String MINE = "mine";
    private final File file;

    /** title: the game's 16-digit title id; anything else (diagnostic app) shares one "app" file. */
    TouchLayoutStore(File directory, String title) {
        String key = title != null && title.matches("[0-9A-Fa-f]{16}") ? title.toUpperCase(java.util.Locale.ROOT) : "app";
        file = new File(directory, key + ".json");
    }

    File file() { return file; }

    /** The saved layout, or null when none is saved. IllegalArgumentException: the file is not valid F01. */
    TouchLayout load() throws IOException {
        if (!file.isFile()) return null;
        if (file.length() > 65536) throw new IllegalArgumentException("F01: layout must be at most 64 KiB");
        return TouchLayout.read(Files.readAllBytes(file.toPath()));
    }

    /** Write-then-rename, so a crash leaves the old layout or the new one, never a torn file. */
    void save(TouchLayout layout) throws IOException {
        byte[] data = layout.jsonBytes();
        TouchLayout.read(data);   // never write what load() would reject
        File directory = file.getParentFile();
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("cannot create " + directory);
        File temporary = new File(directory, file.getName() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(temporary)) {
            out.write(data);
            out.getFD().sync();
        }
        Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
    }

    /** Read at most the limit plus one sentinel byte, regardless of provider metadata. */
    static byte[] readImport(java.io.InputStream input) throws IOException {
        if (input == null) throw new IOException("F01: document unavailable");
        java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = input.read(buffer, 0, Math.min(buffer.length, MAX_IMPORT_BYTES + 1 - bytes.size()))) != -1) {
            bytes.write(buffer, 0, count);
            if (bytes.size() > MAX_IMPORT_BYTES)
                throw new IllegalArgumentException("F01: layout must be at most 64 KiB");
        }
        return bytes.toByteArray();
    }

    /** Import into Android's one saved slot; keep the document identity for sharing. */
    TouchLayout importLayout(byte[] data) throws IOException {
        TouchLayout layout = TouchLayout.read(data);
        // 内置布局的保留名（default / touch）不拒：换一个新名字照常导入（同导出时的做法），玩家拿到的是同一份布局
        if ("default".equals(layout.identifier) || "touch".equals(layout.identifier))
            layout = layout.copyAs("layout-" + java.util.UUID.randomUUID(), layout.name);
        save(layout);
        return layout;
    }

    /** Export the saved document or the current viewport's generated built-in layout. */
    byte[] exportBytes(TouchLayout builtIn) throws IOException {
        TouchLayout layout = load();
        if (layout == null) layout = builtIn;
        if ("default".equals(layout.identifier) || "touch".equals(layout.identifier))
            layout = layout.copyAs("layout-" + java.util.UUID.randomUUID(), layout.name);
        return layout.jsonBytes();
    }

    static String exportFilename(byte[] data) {
        return TouchLayout.read(data).identifier + ".json";
    }

    /** Back to the built-in layout. */
    void reset() throws IOException {
        Files.deleteIfExists(file.toPath());
    }
}
