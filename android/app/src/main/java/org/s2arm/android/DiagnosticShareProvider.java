// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.List;

/**
 * #528 item 15: hands one diagnostic bundle to the app the player picks in the share sheet.
 * Not exported; a reader only gets in through the one-off grant on the share intent. Read-only,
 * and only names DiagnosticBundleWriter.shareable accepts in cache/diag (the app has no AndroidX,
 * so no FileProvider).
 */
public final class DiagnosticShareProvider extends ContentProvider {
    static String authority(Context context) { return context.getPackageName() + ".diag"; }

    static Uri uri(Context context, Path bundle) {
        return new Uri.Builder().scheme("content").authority(authority(context))
            .appendPath(bundle.getFileName().toString()).build();
    }

    static Path directory(Context context) { return context.getCacheDir().toPath().resolve("diag"); }

    private Path resolve(Uri uri) {
        Context context = getContext();
        List<String> segments = uri.getPathSegments();
        if (context == null || segments.size() != 1) return null;
        return DiagnosticBundleWriter.shareable(directory(context), segments.get(0));
    }

    @Override public boolean onCreate() { return true; }

    @Override public String getType(Uri uri) { return resolve(uri) != null ? "application/zip" : null; }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new SecurityException("read-only");
        Path bundle = resolve(uri);
        if (bundle == null) throw new FileNotFoundException();
        return ParcelFileDescriptor.open(bundle.toFile(), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        Path bundle = resolve(uri);
        if (bundle == null) return null;
        String[] columns = projection != null ? projection : new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE};
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) row[i] = bundle.getFileName().toString();
            else if (OpenableColumns.SIZE.equals(columns[i])) {
                try { row[i] = Files.size(bundle); } catch (IOException e) { row[i] = null; }
            }
        }
        MatrixCursor cursor = new MatrixCursor(columns, 1);
        cursor.addRow(row);
        return cursor;
    }

    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException("read-only"); }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { throw new UnsupportedOperationException("read-only"); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("read-only");
    }

    /** Only for the export: a link in place of the directory would send the bundle elsewhere. */
    static Path checkedDirectory(Context context) throws IOException {
        Path dir = directory(context);
        if (Files.isSymbolicLink(dir) || (Files.exists(dir, LinkOption.NOFOLLOW_LINKS) && !Files.isDirectory(dir, LinkOption.NOFOLLOW_LINKS)))
            throw new IOException("diagnostic directory is not a directory");
        return dir;
    }
}
