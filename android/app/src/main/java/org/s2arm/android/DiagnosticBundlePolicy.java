// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Preflight for proposed, already-redacted diagnostic archive entries. No file I/O.
 * Names follow the text-only subset of ios/diag.m schema 1; this is NOT a manifest
 * serializer, redactor, filesystem collector, ZIP writer or permission to share.
 * A future collector must reject symlinks/non-regular files and recheck actual
 * bytes while reading/writing; a name and a claimed size cannot establish safety.
 */
public final class DiagnosticBundlePolicy {
    public static final long MAX_TEXT_BYTES = 8L << 20;
    public static final long MAX_MANIFEST_BYTES = 256L << 10;
    /** Uncompressed proposed payload budget; ZIP framing still needs its own cap. */
    public static final long MAX_TOTAL_BYTES = 30L << 20;
    public static final int MAX_ARCHIVED_LOGS = 9;
    /** Device profile (s2a-device-profile-v1, android/native/direct/dev_facts.c): a few tens of KB; bigger is not one of ours. */
    public static final long MAX_PROFILE_BYTES = 256L << 10;
    public static final int MAX_ENTRIES = 15;

    private DiagnosticBundlePolicy() {}

    public static final class Entry {
        public final String name;
        public final long bytes;
        public Entry(String name, long bytes) {
            this.name = name;
            this.bytes = bytes;
        }
    }

    public enum Rejection {
        INVALID_LIST, INVALID_ENTRY, NAME_NOT_ALLOWED, DUPLICATE_NAME,
        INVALID_SIZE, ENTRY_TOO_LARGE, TOO_MANY_ARCHIVES, TOTAL_TOO_LARGE,
        MISSING_MANIFEST
    }

    /** Error codes deliberately exclude caller-supplied names and contents. */
    public static final class Rejected extends IllegalArgumentException {
        private static final long serialVersionUID = 1L;
        public final Rejection reason;
        private Rejected(Rejection reason) {
            super(reason.name());
            this.reason = reason;
        }
    }

    /**
     * Validate the entire proposal or throw; no partial list is returned.
     * Caller owns the list and must not mutate it during this call. Entries are
     * immutable. The returned byte count is not an authorization token for I/O.
     */
    public static long validate(List<Entry> entries) {
        if (entries == null || entries.isEmpty() || entries.size() > MAX_ENTRIES)
            throw new Rejected(Rejection.INVALID_LIST);
        Set<String> names = new HashSet<>();
        long total = 0;
        int archives = 0;
        for (Entry entry : entries) {
            if (entry == null) throw new Rejected(Rejection.INVALID_ENTRY);
            String name = entry.name;
            boolean manifest = "manifest.json".equals(name);
            boolean archive = name != null
                    && name.matches("logs/host-[0-9]{8}-[0-9]{6}(?:_(?:0[2-9]|[1-9][0-9]))?\\.log");
            boolean profile = name != null && name.matches("devprofile/[0-9a-f]{16}\\.json");
            // No normalization, basename extraction or URL decoding: a variant
            // is rejected, never repaired into an allowed path.
            if (!manifest && !archive && !profile && !"logs/host.log".equals(name)
                    && !"logs/frames.tsv".equals(name) && !"logs/threads.txt".equals(name)
                    && !"logs/unpack.log".equals(name))
                throw new Rejected(Rejection.NAME_NOT_ALLOWED);
            if (!names.add(name)) throw new Rejected(Rejection.DUPLICATE_NAME);
            if (entry.bytes < 0) throw new Rejected(Rejection.INVALID_SIZE);
            if (entry.bytes > (manifest ? MAX_MANIFEST_BYTES : profile ? MAX_PROFILE_BYTES : MAX_TEXT_BYTES))
                throw new Rejected(Rejection.ENTRY_TOO_LARGE);
            if (archive && ++archives > MAX_ARCHIVED_LOGS)
                throw new Rejected(Rejection.TOO_MANY_ARCHIVES);
            if (entry.bytes > MAX_TOTAL_BYTES - total)
                throw new Rejected(Rejection.TOTAL_TOO_LARGE);
            total += entry.bytes;
        }
        if (!names.contains("manifest.json")) throw new Rejected(Rejection.MISSING_MANIFEST);
        return total;
    }
}
