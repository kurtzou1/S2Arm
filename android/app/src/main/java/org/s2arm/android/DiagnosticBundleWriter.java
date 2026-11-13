// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.io.FilterOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.channels.SeekableByteChannel;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.TreeMap;
import java.util.function.Function;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/**
 * #528 item 15: builds the player diagnostic bundle (a zip in ios/diag.m schema 1 layout:
 * manifest.json and logs/ at the root) from the Android session logs.
 *
 * <p>Android writes one native session log per launch, {@code host-<session>-<pid>-XXXXXX.log}
 * (runtime/src/os.c s2a_android_session_log_start), into the game's state directory
 * {@code <files>/user/0/saves/<title id>/ryujinx-android}, next to the save data. Only regular files
 * with exactly that name shape are read, without following links; nothing else in the directory
 * is opened. The newest becomes logs/host.log and older ones logs/host-<modified time>.log, the
 * names {@link DiagnosticBundlePolicy} allows. Every text goes through {@link DiagnosticRedactor};
 * a failure drops the whole bundle. Pure Java (no android.*), so the host tests run it as is.
 */
final class DiagnosticBundleWriter {
    static final long MAX_ZIP_BYTES = 30L << 20;   // the final archive, framing included (iOS: compressed ≤ 30 MB)
    static final int KEEP_BUNDLES = 3;             // as iOS keeps Documents/diag
    static final int MAX_LOGS = 1 + DiagnosticBundlePolicy.MAX_ARCHIVED_LOGS;
    private static final Pattern TITLE_ID = Pattern.compile("[0-9A-Fa-f]{16}");
    private static final Pattern SESSION_LOG = Pattern.compile("host-[0-9]{1,20}-[0-9]{1,10}-[A-Za-z0-9]{6}\\.log");
    private static final Pattern BUNDLE = Pattern.compile("S2Arm-[^/]+\\.zip");
    private static final Pattern WORD = Pattern.compile("[A-Za-z]{1,16}|诊断");
    private static final String STATE_DIR = "ryujinx-android";
    // The cut marker ("\n…截掉 N 字节…\n", at most 41 bytes) comes out of the tail, so head + marker + tail ≤ cap.
    private static final int MARKER_ROOM = 64;

    static final class SessionLog {
        final String titleId;
        final Path file;
        final long modified;
        SessionLog(String titleId, Path file, long modified) {
            this.titleId = titleId;
            this.file = file;
            this.modified = modified;
        }
    }

    static final class Result {
        final Path bundle;
        final int logs, omitted;
        final long bytes;
        Result(Path bundle, int logs, int omitted, long bytes) {
            this.bundle = bundle;
            this.logs = logs;
            this.omitted = omitted;
            this.bytes = bytes;
        }
    }

    private DiagnosticBundleWriter() {}

    /** Session logs under savesRoot, newest first. A missing root means none. */
    static List<SessionLog> sessionLogs(Path savesRoot) throws IOException {
        List<SessionLog> found = new ArrayList<>();
        if (!Files.isDirectory(savesRoot, LinkOption.NOFOLLOW_LINKS)) return found;
        try (DirectoryStream<Path> titles = Files.newDirectoryStream(savesRoot)) {
            for (Path title : titles) {
                String id = title.getFileName().toString();
                if (!TITLE_ID.matcher(id).matches() || !Files.isDirectory(title, LinkOption.NOFOLLOW_LINKS)) continue;
                Path state = title.resolve(STATE_DIR);
                if (!Files.isDirectory(state, LinkOption.NOFOLLOW_LINKS)) continue;
                try (DirectoryStream<Path> logs = Files.newDirectoryStream(state)) {
                    for (Path log : logs) {
                        if (!SESSION_LOG.matcher(log.getFileName().toString()).matches()) continue;
                        BasicFileAttributes a = Files.readAttributes(log, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
                        if (!a.isRegularFile()) continue;   // links, directories, pipes
                        found.add(new SessionLog(id.toUpperCase(Locale.ROOT), log, a.lastModifiedTime().toMillis()));
                    }
                }
            }
        }
        found.sort((a, b) -> a.modified != b.modified ? Long.compare(b.modified, a.modified)
            : b.file.toString().compareTo(a.file.toString()));
        return found;
    }

    /**
     * Writes outDir/S2Arm-&lt;word&gt;-MMdd-HHmm[-n].zip. {@code info} holds the manifest's app / device /
     * settings objects (string values, redacted here too). {@code redactor} is DiagnosticRedactor::redact
     * in production; it signals failure with DiagnosticRedactor.RedactionException. Throws without
     * leaving a partial file.
     */
    static Result write(Path savesRoot, Path outDir, Function<String, String> redactor, Map<String, Map<String, String>> info,
                        String word, long now, TimeZone zone) throws IOException {
        return write(savesRoot, outDir, redactor, info, new ArrayList<>(), word, now, zone, MAX_ZIP_BYTES);
    }

    /** {@code exits}: DiagnosticExits records, newest first; the first MAX_RECORDS go into the manifest, redacted. */
    static Result write(Path savesRoot, Path outDir, Function<String, String> redactor, Map<String, Map<String, String>> info,
                        List<Map<String, Object>> exits, String word, long now, TimeZone zone) throws IOException {
        return write(savesRoot, outDir, redactor, info, exits, word, now, zone, MAX_ZIP_BYTES);
    }

    static Result write(Path savesRoot, Path outDir, Function<String, String> redactor, Map<String, Map<String, String>> info,
                        String word, long now, TimeZone zone, long maxZipBytes) throws IOException {
        return write(savesRoot, outDir, redactor, info, new ArrayList<>(), word, now, zone, maxZipBytes);
    }

    static Result write(Path savesRoot, Path outDir, Function<String, String> redactor, Map<String, Map<String, String>> info,
                        List<Map<String, Object>> exits, String word, long now, TimeZone zone, long maxZipBytes) throws IOException {
        if (!WORD.matcher(word).matches()) throw new IllegalArgumentException("bundle word");
        Files.createDirectories(outDir);
        List<SessionLog> logs = sessionLogs(savesRoot);
        Map<String, byte[]> entries = new LinkedHashMap<>();
        List<Map<String, Object>> files = new ArrayList<>(), sessions = new ArrayList<>();
        long budget = DiagnosticBundlePolicy.MAX_TOTAL_BYTES - DiagnosticBundlePolicy.MAX_MANIFEST_BYTES;
        int omitted = 0;
        try {
            for (SessionLog log : logs) {
                if (entries.size() >= MAX_LOGS) { omitted++; continue; }
                boolean[] truncated = {false};
                byte[] raw = readCapped(log.file, DiagnosticBundlePolicy.MAX_TEXT_BYTES, truncated);
                String text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPLACE)
                    .onUnmappableCharacter(CodingErrorAction.REPLACE).decode(ByteBuffer.wrap(raw)).toString();
                byte[] clean = redactor.apply(text).getBytes(StandardCharsets.UTF_8);
                if (clean.length > DiagnosticBundlePolicy.MAX_TEXT_BYTES) {   // placeholders longer than what they hid
                    clean = truncate(clean, DiagnosticBundlePolicy.MAX_TEXT_BYTES);
                    truncated[0] = true;
                }
                if (clean.length > budget) { omitted++; continue; }
                budget -= clean.length;
                String name = entries.isEmpty() ? "logs/host.log" : archiveName(entries, log.modified, zone);
                entries.put(name, clean);
                Map<String, Object> file = new TreeMap<>();
                file.put("path", name);
                file.put("bytes", (long) clean.length);
                file.put("truncated", truncated[0]);
                files.add(file);
                Map<String, Object> session = new TreeMap<>();
                session.put("file", name);
                session.put("title_id", log.titleId);
                session.put("modified", iso(log.modified));
                session.put("current", sessions.isEmpty());
                sessions.add(session);
            }
            Map<String, Object> manifest = new TreeMap<>();
            manifest.put("schema", 1L);
            manifest.put("platform", "android");
            manifest.put("exported_at", iso(now));
            for (String section : new String[] {"app", "device", "settings"}) {
                Map<String, Object> values = new TreeMap<>();
                Map<String, String> given = info.get(section);
                if (given != null) for (Map.Entry<String, String> e : given.entrySet())
                    values.put(e.getKey(), redactor.apply(e.getValue() == null ? "" : e.getValue()));
                manifest.put(section, values);
            }
            List<Map<String, Object>> exitRecords = new ArrayList<>();
            for (Map<String, Object> exit : exits) {
                if (exitRecords.size() >= DiagnosticExits.MAX_RECORDS) break;
                Map<String, Object> clean = new TreeMap<>();
                for (Map.Entry<String, Object> e : exit.entrySet()) {
                    Object v = e.getValue();
                    if (v instanceof String) {
                        String r = redactor.apply((String) v);
                        // Cut after redaction, so a placeholder is never half of a secret; never inside a surrogate pair.
                        if (e.getKey().equals("description") && r.length() > DiagnosticExits.MAX_DESCRIPTION) {
                            int cut = DiagnosticExits.MAX_DESCRIPTION;
                            if (Character.isHighSurrogate(r.charAt(cut - 1))) cut--;
                            r = r.substring(0, cut) + "…";
                        }
                        v = r;
                    }
                    clean.put(e.getKey(), v);
                }
                exitRecords.add(clean);
            }
            manifest.put("exits", exitRecords);
            manifest.put("sessions", sessions);
            manifest.put("omitted_logs", (long) omitted);
            manifest.put("files", files);
            byte[] manifestBytes = json(manifest, 0).append('\n').toString().getBytes(StandardCharsets.UTF_8);

            List<DiagnosticBundlePolicy.Entry> proposal = new ArrayList<>();
            proposal.add(new DiagnosticBundlePolicy.Entry("manifest.json", manifestBytes.length));
            for (Map.Entry<String, byte[]> e : entries.entrySet())
                proposal.add(new DiagnosticBundlePolicy.Entry(e.getKey(), e.getValue().length));
            DiagnosticBundlePolicy.validate(proposal);

            Path partial = Files.createTempFile(outDir, ".partial-", ".zip");
            try {
                try (ZipOutputStream zip = new ZipOutputStream(new CappedStream(Files.newOutputStream(partial), maxZipBytes),
                                                               StandardCharsets.UTF_8)) {
                    put(zip, "manifest.json", manifestBytes, now);
                    for (Map.Entry<String, byte[]> e : entries.entrySet()) put(zip, e.getKey(), e.getValue(), now);
                }
                long size = Files.size(partial);
                if (size > maxZipBytes) throw new IOException("bundle too large");
                Path target = uniqueName(outDir, word, now, zone);
                Files.move(partial, target, StandardCopyOption.ATOMIC_MOVE);
                prune(outDir, target);
                return new Result(target, entries.size(), omitted, size);
            } finally {
                Files.deleteIfExists(partial);
            }
        } catch (DiagnosticRedactor.RedactionException e) {
            throw new IOException("redaction failed");   // never the text, never a partial bundle
        } catch (DiagnosticBundlePolicy.Rejected e) {
            throw new IOException("bundle rejected: " + e.reason);
        }
    }

    /** Reads at most cap bytes: over the cap, the head quarter and the tail, each cut at a line break. */
    static byte[] readCapped(Path file, long cap, boolean[] truncated) throws IOException {
        try (SeekableByteChannel ch = Files.newByteChannel(file, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            long size = ch.size();
            if (size <= cap) {
                truncated[0] = false;
                return readRange(ch, 0, (int) size);
            }
            truncated[0] = true;
            int head = (int) (cap / 4), tail = (int) (cap - cap / 4) - MARKER_ROOM;
            byte[] h = readRange(ch, 0, head), t = readRange(ch, size - tail, tail);
            return join(h, lastLineEnd(h), t, firstLineStart(t), size);
        }
    }

    /** The same cut applied to text that is already redacted and still over the cap. */
    static byte[] truncate(byte[] data, long cap) {
        int head = (int) (cap / 4), tail = (int) (cap - cap / 4) - MARKER_ROOM;
        byte[] h = java.util.Arrays.copyOfRange(data, 0, head), t = java.util.Arrays.copyOfRange(data, data.length - tail, data.length);
        return join(h, lastLineEnd(h), t, firstLineStart(t), data.length);
    }

    // Cut only at line breaks: a cut inside a token (an e-mail, a path) could leave a piece no rule
    // recognises. A head or tail without any line break is dropped whole rather than cut.
    private static int lastLineEnd(byte[] head) {
        for (int i = head.length - 1; i >= 0; i--) if (head[i] == '\n') return i + 1;
        return 0;
    }
    private static int firstLineStart(byte[] tail) {
        for (int i = 0; i < tail.length; i++) if (tail[i] == '\n') return i + 1;
        return tail.length;
    }
    private static byte[] join(byte[] h, int hEnd, byte[] t, int tStart, long total) {
        long dropped = total - hEnd - (t.length - tStart);
        byte[] marker = ("\n…截掉 " + dropped + " 字节…\n").getBytes(StandardCharsets.UTF_8);
        byte[] out = new byte[hEnd + marker.length + t.length - tStart];
        System.arraycopy(h, 0, out, 0, hEnd);
        System.arraycopy(marker, 0, out, hEnd, marker.length);
        System.arraycopy(t, tStart, out, hEnd + marker.length, t.length - tStart);
        return out;
    }

    private static byte[] readRange(SeekableByteChannel ch, long position, int length) throws IOException {
        ByteBuffer buffer = ByteBuffer.allocate(length);
        ch.position(position);
        while (buffer.hasRemaining() && ch.read(buffer) >= 0) { }
        return java.util.Arrays.copyOf(buffer.array(), buffer.position());   // a log that shrank meanwhile: what was there
    }

    private static String archiveName(Map<String, byte[]> taken, long modified, TimeZone zone) {
        SimpleDateFormat f = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.ROOT);
        f.setTimeZone(zone);
        String stamp = "logs/host-" + f.format(new Date(modified));
        if (!taken.containsKey(stamp + ".log")) return stamp + ".log";
        for (int n = 2; ; n++) {
            String name = String.format(Locale.ROOT, "%s_%02d.log", stamp, n);
            if (!taken.containsKey(name)) return name;
        }
    }

    private static Path uniqueName(Path outDir, String word, long now, TimeZone zone) {
        SimpleDateFormat f = new SimpleDateFormat("MMdd-HHmm", Locale.ROOT);
        f.setTimeZone(zone);
        String base = "S2Arm-" + word + "-" + f.format(new Date(now));
        Path candidate = outDir.resolve(base + ".zip");
        for (int n = 2; Files.exists(candidate, LinkOption.NOFOLLOW_LINKS); n++) candidate = outDir.resolve(base + "-" + n + ".zip");
        return candidate;
    }

    private static final Pattern SHAREABLE = Pattern.compile("S2Arm-(?:[A-Za-z]{1,16}|诊断)-[0-9]{4}-[0-9]{4}(?:-[0-9]{1,4})?\\.zip");

    /**
     * The bundle a share URI may name: only a file this class wrote (its exact name shape), directly
     * in outDir, a regular file and not a link. Anything else, including "..", is null.
     */
    static Path shareable(Path outDir, String name) {
        if (name == null || !SHAREABLE.matcher(name).matches()) return null;
        Path p = outDir.resolve(name);
        if (!p.getParent().equals(outDir) || !Files.isRegularFile(p, LinkOption.NOFOLLOW_LINKS)) return null;
        return p;
    }

    /** Keeps the newest KEEP_BUNDLES bundles (the one just written always stays) and clears leftovers. */
    private static void prune(Path outDir, Path keep) throws IOException {
        List<Path> bundles = new ArrayList<>();
        try (DirectoryStream<Path> all = Files.newDirectoryStream(outDir)) {
            for (Path p : all) {
                String name = p.getFileName().toString();
                if (name.startsWith(".partial-") && name.endsWith(".zip")) { Files.deleteIfExists(p); continue; }
                if (BUNDLE.matcher(name).matches() && Files.isRegularFile(p, LinkOption.NOFOLLOW_LINKS) && !p.equals(keep)) bundles.add(p);
            }
        }
        bundles.sort((a, b) -> {
            try {
                long ma = Files.getLastModifiedTime(a, LinkOption.NOFOLLOW_LINKS).toMillis();
                long mb = Files.getLastModifiedTime(b, LinkOption.NOFOLLOW_LINKS).toMillis();
                return ma != mb ? Long.compare(mb, ma) : b.getFileName().toString().compareTo(a.getFileName().toString());
            } catch (IOException e) {
                return 0;
            }
        });
        for (int i = KEEP_BUNDLES - 1; i < bundles.size(); i++) Files.deleteIfExists(bundles.get(i));
    }

    private static void put(ZipOutputStream zip, String name, byte[] data, long now) throws IOException {
        ZipEntry entry = new ZipEntry(name);
        entry.setTime(now);
        zip.putNextEntry(entry);
        zip.write(data);
        zip.closeEntry();
    }

    static String iso(long millis) {
        SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f.format(new Date(millis));
    }

    /** Sorted keys, two-space indent, like the iOS manifest (NSJSONWritingSortedKeys | PrettyPrinted). */
    @SuppressWarnings("unchecked")
    static StringBuilder json(Object value, int indent) {
        StringBuilder out = new StringBuilder();
        String pad = spaces(2 * indent + 2), end = spaces(2 * indent);   // String.repeat needs API 33, minSdk is 29
        if (value instanceof Map) {
            Map<String, Object> map = new TreeMap<>((Map<String, Object>) value);
            if (map.isEmpty()) return out.append("{}");
            out.append("{\n");
            int i = 0;
            for (Map.Entry<String, Object> e : map.entrySet())
                out.append(pad).append(quote(e.getKey())).append(" : ").append(json(e.getValue(), indent + 1))
                   .append(++i < map.size() ? ",\n" : "\n");
            return out.append(end).append('}');
        }
        if (value instanceof List) {
            List<Object> list = (List<Object>) value;
            if (list.isEmpty()) return out.append("[]");
            out.append("[\n");
            for (int i = 0; i < list.size(); i++)
                out.append(pad).append(json(list.get(i), indent + 1)).append(i + 1 < list.size() ? ",\n" : "\n");
            return out.append(end).append(']');
        }
        if (value instanceof String) return out.append(quote((String) value));
        if (value instanceof Long || value instanceof Boolean) return out.append(value);
        throw new IllegalArgumentException("manifest value type");
    }

    private static String spaces(int n) {
        char[] c = new char[n];
        java.util.Arrays.fill(c, ' ');
        return new String(c);
    }

    private static String quote(String s) {
        StringBuilder out = new StringBuilder(s.length() + 2).append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\') out.append('\\').append(c);
            else if (c == '\n') out.append("\\n");
            else if (c == '\t') out.append("\\t");
            else if (c < 0x20 || c == 0x7f || c == 0x2028 || c == 0x2029) out.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
            else out.append(c);
        }
        return out.append('"').toString();
    }

    /** Stops writing past the cap instead of finishing an archive that will be thrown away. */
    private static final class CappedStream extends FilterOutputStream {
        private final long cap;
        private long written;
        CappedStream(OutputStream out, long cap) {
            super(out);
            this.cap = cap;
        }
        @Override public void write(int b) throws IOException {
            if (++written > cap) throw new IOException("bundle too large");
            out.write(b);
        }
        @Override public void write(byte[] b, int off, int len) throws IOException {
            written += len;
            if (written > cap) throw new IOException("bundle too large");
            out.write(b, off, len);
        }
    }
}
