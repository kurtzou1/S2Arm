// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * #528 item 15: redaction for the Android player diagnostic bundle.
 *
 * <p>A Java port of {@code tools/redact.py redact_text} (the shared contract is
 * {@code tests/fixtures/redact_cases.tsv}, also used by iOS and the Mac launcher), plus Android
 * rules: the caller's own private and install directories become placeholders such as
 * {@code <APP>} (the rest of the path is kept, as iOS does for its containers), other app-data,
 * shared-storage and mount paths become {@code [PRIVATE_PATH]}, and content URIs keep only their
 * authority. Values of the player's imported keys are replaced before any shape rule.
 *
 * <p>Pure Java, no android.* and no file access: the caller supplies the prefixes and the key
 * text. The patterns avoid {@code \b}, {@code \s} and {@code \w}, whose meaning differs between
 * desktop Java and Android's ICU-backed regex; explicit classes reproduce Python's Unicode ones.
 * Failure throws; callers must drop the whole bundle, never fall back to the original text.
 */
final class DiagnosticRedactor {
    // Python str \s and \w, spelled out so desktop Java and Android ICU agree.
    private static final String SPACE = "\\t\\n\\x0B\\f\\r\\x1C-\\x1F\\x85\\p{Z}";
    private static final String HSPACE = "\\t\\x0B\\f\\x1C-\\x1F\\x85\\p{Z}";   // [^\S\r\n]
    private static final String NOT_WORD_BEFORE = "(?<![\\p{L}\\p{N}_])";       // \b before a word char
    private static final String NOT_WORD_AFTER = "(?![\\p{L}\\p{N}_])";         // \b after a word char
    // RFC 5322 atext with every punctuation escaped (a bare & or [ means something else in ICU sets).
    // Case-insensitive ranges are written A-Za-z: Python folds U+212A KELVIN SIGN into [A-Z] through k,
    // Java only compares its upper and lower case against the range as written.
    private static final String ATEXT = "A-Za-z0-9.!#\\$%\\&'*+/=?\\^_`\\{|\\}~\\-";

    // Inline (?d) / (?u) are not ICU syntax: Android gets those through compile flags.
    private static Pattern re(String regex) { return Pattern.compile(regex, Pattern.UNICODE_CASE); }
    private static final Pattern KEY_LINE = Pattern.compile(
        "^([ \\t]*[A-Za-z0-9_.-]+[ \\t]*=[ \\t]*)([0-9a-f]{32,})[^\\r\\n]*(?=\\r?$)",
        Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE | Pattern.MULTILINE | Pattern.UNIX_LINES);
    private static final Pattern SECRET = re(
        "(?i)(?:password|passwd|secret|token|api[_-]?key|authorization|cookie|serial(?:number)?|udid|uuid|imei"
        + "|device[_-]?id|android[_-]?id|idfa|idfv|mac[_-]?address|uniqueidentifier|identifierforvendor|tester"
        + "|(?:^|[_-])keys?(?:[_-]|$)|(?:^|[_-])(?:kek|bek|seed|keyblob)(?:[_-]|$)|titlekek|masterkey|headerkey)");
    private static final Pattern ASSIGNMENT_KEY = re(
        "[\"']?([A-Za-z_][A-Za-z0-9_.-]*)[\"']?[" + HSPACE + "]*[:=][" + HSPACE + "]*");
    private static final Pattern AUTHORIZATION = re(
        "(?i)(authorization[" + SPACE + "]*[:=][" + SPACE + "]*)[^\\r\\n]+");
    private static final Pattern URL_CREDENTIALS = re(
        "(?i)(https?://)[^/" + SPACE + ":@]+:[^/" + SPACE + "@]+@");
    private static final Pattern QUERY_SECRET = re(
        "(?i)([?&](?:token|key|api_key|secret|password|auth|signature|session|access_token)=)[^&#" + SPACE + "]+");
    private static final Pattern SECRET_ASSIGNMENT = re(
        "(?i)((?:password|passwd|secret|token|api[_-]?key|[a-z0-9_]*_key(?:_[a-z0-9]+)*|titlekek|masterkey|headerkey"
        + "|cookie|serial(?:number)?|udid|uuid|imei|device[_-]?id|android[_-]?id|idfa|idfv|mac[_-]?address"
        + "|uniqueidentifier|identifierforvendor)[" + SPACE + "]*[\"']?[" + SPACE + "]*[:=][" + SPACE + "]*[\"']?)"
        + "[^" + SPACE + ",\"';}]+");

    private static final String DOMAIN = "@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+(?![A-Za-z0-9-])";
    private static final Pattern[] IDENTITY = {
        re("(?i)((?<![" + ATEXT + "])(?:contact|email|mail|from|to|reply[_-]?to|user)[\"']?[ \\t]*[:=][ \\t]*[\"']?)["
            + ATEXT + "]+" + DOMAIN),
        re("(?i)(?<![" + ATEXT + "])[" + ATEXT + "]+" + DOMAIN),
        re("(?i)(" + NOT_WORD_BEFORE + "DEVELOPMENT_TEAM[ \\t]*=[ \\t]*[\"']?|" + NOT_WORD_BEFORE
            + "Signing[ \\t]+with[ \\t]+team[ \\t]+)(?<![A-Za-z0-9])[A-Za-z0-9]{10}(?![A-Za-z0-9])"),
        re("(?i)(?<![A-Za-z0-9])(s2arm\\.)[A-Za-z0-9]{10}(\\.[A-F0-9]{16})(?![A-Za-z0-9])"),
        re("(?i)(?<![A-Za-z0-9])[A-F0-9]{8}-[A-F0-9]{16}(?![A-Za-z0-9])"),
    };
    private static final String[] IDENTITY_REPLACEMENT = {"$1[EMAIL]", "[EMAIL]", "$1[TEAM_ID]", "$1[TEAM_ID]$2", "[DEVICE_ID]"};
    private static final Pattern PHYSICAL_LINE = re("[^\\r\\n]+");
    private static final Pattern DEVICE_CONTEXT = re("(?i)" + NOT_WORD_BEFORE + "(?:udid|device|serial)" + NOT_WORD_AFTER);
    private static final Pattern LEGACY_UDID = re("(?i)(?<![A-Za-z0-9])[A-F0-9]{40}(?![A-Za-z0-9])");
    private static final Pattern DEVICE_NAME = re("[^" + SPACE + "\"'<>:=,;\\{\\}\\[\\]，。]+的(iPhone|iPad)");

    private static final String PATH_TAIL = "[^\\r\\n\"'<>]*";
    private static final Pattern PRIVATE_PATH = re(
        "(?:/Volumes/|/private/var/|/var/mobile/|/data/user/|/data/data/|\\\\\\\\)" + PATH_TAIL);
    private static final Pattern HOME_PATH = re(
        "(?:/Users/|/home/|[A-Za-z]:[\\\\/](?:Users|Documents)[\\\\/])" + PATH_TAIL);
    // Android: other apps' data, device-encrypted storage, installs, shared storage and its mounts.
    private static final Pattern ANDROID_PATH = re(
        "(?:/data/user_de/|/data/app/|/data/media/|/storage/|/sdcard/|/mnt/(?:media_rw|user|expand|pass_through|runtime|sdcard)/)"
        + PATH_TAIL);
    // Document URIs carry folder and file names; keep the authority, which names the provider app.
    private static final Pattern CONTENT_URI = re(
        "(?i)(content://[^/" + SPACE + "\"'<>]+/)[^" + SPACE + "\"'<>]*");
    private static final String[] ERRNO_REASONS = {
        "Operation not permitted", "Permission denied", "No such file or directory", "File exists", "Read-only file system",
        "No space left on device", "Is a directory", "Not a directory", "Input/output error", "Resource busy", "Device not configured",
        "File name too long", "Too many open files", "Disc quota exceeded", "Bad file descriptor", "Directory not empty", "Invalid argument",
        "Cross-device link", "Operation not supported", "Operation timed out", "Resource deadlock avoided", "Resource temporarily unavailable",
        "Too many levels of symbolic links", "Bad address", "Result too large"};
    private static final Pattern REASON_TAIL;
    static {
        StringBuilder reasons = new StringBuilder();
        for (String reason : ERRNO_REASONS) reasons.append(reasons.length() == 0 ? "" : "|").append(Pattern.quote(reason));
        REASON_TAIL = re("(?i): (?:(?:clonefile|fclonefileat|copyfile) failed: )?(?:" + reasons + ")\\.?[ \\t]*\\z");   // \z, not $: Java's $ also stops before a final CR, U+0085 or U+2028; Python's only before LF
    }
    private static final Pattern UUID_SHAPE = re(NOT_WORD_BEFORE
        + "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" + NOT_WORD_AFTER);
    private static final Pattern KEY_MATERIAL = re(NOT_WORD_BEFORE + "[0-9a-fA-F]{64,}" + NOT_WORD_AFTER);

    /** Thrown instead of returning text that may not be fully redacted. */
    static final class RedactionException extends RuntimeException {
        private static final long serialVersionUID = 1L;
        RedactionException(String what) { super(what); }
    }

    private final List<Pattern> prefixPatterns = new ArrayList<>();
    private final List<String> prefixPlaceholders = new ArrayList<>();
    private final Pattern keyValues;   // null = no imported keys

    /**
     * @param prefixes pairs {absolute path prefix, placeholder}, e.g. {"/data/user/0/org.s2arm.android", "<APP>"};
     *                 the longest prefix wins and a prefix only matches at a path-component boundary
     * @param keyValues hex values from the player's imported key file (see {@link #keyValues(String)})
     */
    DiagnosticRedactor(List<String[]> prefixes, Collection<String> keyValues) {
        List<String[]> sorted = new ArrayList<>(prefixes);
        for (String[] pair : sorted)
            if (pair == null || pair.length != 2 || pair[0] == null || !pair[0].startsWith("/") || pair[0].length() < 2
                    || pair[0].endsWith("/") || pair[1] == null || pair[1].isEmpty())
                throw new IllegalArgumentException("invalid prefix");
        sorted.sort((a, b) -> b[0].length() - a[0].length());
        for (String[] pair : sorted) {
            // Whole path components only: not inside a longer path, not a sibling such as <package>2.
            prefixPatterns.add(re("(?<![A-Za-z0-9._~+/-])" + Pattern.quote(pair[0]) + "(?![A-Za-z0-9._~+-])"));
            prefixPlaceholders.add(pair[1]);
        }
        TreeSet<String> values = new TreeSet<>((a, b) -> a.length() != b.length() ? b.length() - a.length() : a.compareTo(b));
        for (String value : keyValues) {
            if (value == null || !value.matches("[0-9a-fA-F]+")) throw new IllegalArgumentException("key values are hex");
            values.add(value.toLowerCase(Locale.ROOT));
        }
        StringBuilder alternatives = new StringBuilder();
        for (String value : values) alternatives.append(alternatives.length() == 0 ? "" : "|").append(value);
        this.keyValues = values.isEmpty() ? null : re("(?i:" + alternatives + ")");
    }

    /** The values of {@code name = <32+ hex>} lines, as tools/redact.py load_key_values reads prod.keys. */
    static List<String> keyValues(String keyFileText) {
        List<String> values = new ArrayList<>();
        if (keyFileText == null) return values;
        for (String line : keyFileText.split("\n", -1)) {
            String trimmed = line;
            while (trimmed.endsWith("\r") || trimmed.endsWith("\n")) trimmed = trimmed.substring(0, trimmed.length() - 1);
            Matcher m = KEY_LINE.matcher(trimmed);
            if (m.matches()) values.add(m.group(2).toLowerCase(Locale.ROOT));
        }
        return values;
    }

    String redact(String text) {
        if (text == null) throw new RedactionException("null text");
        try {
            String s = text;
            for (int i = 0; i < prefixPatterns.size(); i++)
                s = prefixPatterns.get(i).matcher(s).replaceAll(Matcher.quoteReplacement(prefixPlaceholders.get(i)));
            if (keyValues != null) s = keyValues.matcher(s).replaceAll("[REDACTED]");
            s = KEY_LINE.matcher(s).replaceAll("$1[REDACTED]");
            s = redactAssignments(s);
            s = AUTHORIZATION.matcher(s).replaceAll("$1[REDACTED]");
            s = URL_CREDENTIALS.matcher(s).replaceAll("$1[REDACTED]@");
            s = QUERY_SECRET.matcher(s).replaceAll("$1[REDACTED]");
            s = SECRET_ASSIGNMENT.matcher(s).replaceAll("$1[REDACTED]");
            s = redactIdentity(s);
            s = replacePaths(PRIVATE_PATH, s);
            s = replacePaths(HOME_PATH, s);
            s = replacePaths(ANDROID_PATH, s);
            s = CONTENT_URI.matcher(s).replaceAll("$1[PRIVATE_PATH]");
            s = UUID_SHAPE.matcher(s).replaceAll("[DEVICE_ID]");
            s = KEY_MATERIAL.matcher(s).replaceAll("[KEY_MATERIAL]");
            return controlsReplaced(s);
        } catch (RuntimeException | StackOverflowError error) {
            // A regex blow-up on hostile input must not leak the original text.
            throw new RedactionException("redaction failed");
        }
    }

    private static boolean pySpace(char c) {
        return c == '\t' || c == '\n' || c == 0x0B || c == '\f' || c == '\r' || (c >= 0x1C && c <= 0x1F) || c == 0x85
            || Character.getType(c) == Character.SPACE_SEPARATOR || Character.getType(c) == Character.LINE_SEPARATOR
            || Character.getType(c) == Character.PARAGRAPH_SEPARATOR;
    }

    /** redact.py redact_assignments: secret-looking keys hide their value up to the end of the token or quote. */
    private static String redactAssignments(String text) {
        StringBuilder pieces = new StringBuilder(text.length());
        int cursor = 0;
        Matcher match = ASSIGNMENT_KEY.matcher(text);
        while (match.find()) {
            if (match.end() <= cursor || !SECRET.matcher(match.group(1)).find()) continue;
            int start = match.end();
            char q = start < text.length() && (text.charAt(start) == '"' || text.charAt(start) == '\'') ? text.charAt(start) : 0;
            char quote = q;
            int end = start + (q != 0 ? 1 : 0);
            while (end < text.length() && text.charAt(end) != '\r' && text.charAt(end) != '\n') {
                char c = text.charAt(end);
                if (quote != 0 && c == '\\') {
                    end++;
                    if (end < text.length() && text.charAt(end) != '\r' && text.charAt(end) != '\n') end++;
                } else if (quote != 0) {
                    if (c == quote) quote = 0;
                    end++;
                } else if (c == '"' || c == '\'') {
                    quote = c;
                    end++;
                } else if (pySpace(c) || c == ',' || c == ';' || c == '}' || (q != 0 && c == ']')) {
                    break;
                } else {
                    end++;
                }
            }
            if (end > start) {
                String mark = q != 0 ? String.valueOf(q) : "";
                pieces.append(text, cursor, start).append(mark).append("[REDACTED]").append(quote == 0 ? mark : "");
                cursor = end;
            }
        }
        return pieces.append(text, cursor, text.length()).toString();
    }

    private static String redactIdentity(String text) {
        String s = text;
        for (int i = 0; i < IDENTITY.length; i++) s = IDENTITY[i].matcher(s).replaceAll(IDENTITY_REPLACEMENT[i]);
        Matcher line = PHYSICAL_LINE.matcher(s);
        StringBuffer out = new StringBuffer(s.length());   // appendReplacement(StringBuilder) is Java 9, newer than minSdk 29
        while (line.find()) {
            String physical = line.group();
            String replaced = DEVICE_CONTEXT.matcher(physical).find()
                ? LEGACY_UDID.matcher(physical).replaceAll("[DEVICE_ID]") : physical;
            line.appendReplacement(out, Matcher.quoteReplacement(replaced));
        }
        line.appendTail(out);
        return DEVICE_NAME.matcher(out.toString()).replaceAll("[DEVICE_NAME]的$1");
    }

    /** redact.py _private_path: Windows paths keep their length and depth, nothing else. */
    private static String privatePath(String matched) {
        String path = matched.replace("\\\\", "\\");
        if (path.indexOf('\\') < 0) return "[PRIVATE_PATH]";
        int depth = 0;
        for (int i = 0; i < path.length(); i++) if (path.charAt(i) == '\\') depth++;
        return "[PRIVATE_PATH len=" + path.codePointCount(0, path.length()) + " depth=" + depth + "]";
    }

    /** redact.py _private_path_keep_reason: a trailing strerror text from the known list survives. */
    private static String replacePaths(Pattern pattern, String text) {
        Matcher m = pattern.matcher(text);
        StringBuffer out = new StringBuffer(text.length());
        while (m.find()) {
            String path = m.group();
            Matcher tail = REASON_TAIL.matcher(path);
            String replaced = tail.find() && tail.start() > 0
                ? privatePath(path.substring(0, tail.start())) + path.substring(tail.start()) : privatePath(path);
            m.appendReplacement(out, Matcher.quoteReplacement(replaced));
        }
        m.appendTail(out);
        return out.toString();
    }

    private static String controlsReplaced(String s) {
        StringBuilder out = null;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\n' || c == '\t' || (c >= 32 && c != 127)) { if (out != null) out.append(c); continue; }
            if (out == null) out = new StringBuilder(s.length()).append(s, 0, i);
            out.append('\uFFFD');
        }
        return out == null ? s : out.toString();
    }
}
