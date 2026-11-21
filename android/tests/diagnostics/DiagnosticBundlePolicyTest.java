// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import static org.s2arm.android.DiagnosticBundlePolicy.*;

public final class DiagnosticBundlePolicyTest {
    private static int checks;
    private static Entry e(String name, long bytes) { return new Entry(name, bytes); }
    private static List<Entry> bundle(Entry... entries) {
        List<Entry> result = new ArrayList<>();
        result.add(e("manifest.json", 0));
        result.addAll(Arrays.asList(entries));
        return result;
    }
    private static void check(boolean ok) {
        checks++;
        if (!ok) throw new AssertionError("check " + checks);
    }
    private static void rejected(Rejection reason, List<Entry> entries) {
        try { validate(entries); throw new AssertionError("accepted " + reason); }
        catch (Rejected ex) { check(ex.reason == reason); check(ex.getMessage().equals(reason.name())); }
    }
    public static void main(String[] args) {
        check(validate(bundle()) == 0);
        check(validate(bundle(e("logs/host.log", MAX_TEXT_BYTES))) == MAX_TEXT_BYTES);
        check(validate(Arrays.asList(e("manifest.json", MAX_MANIFEST_BYTES))) == MAX_MANIFEST_BYTES);
        for (String name : new String[]{"logs/frames.tsv", "logs/threads.txt", "logs/unpack.log",
                "logs/host-20261111-123456.log", "logs/host-20261111-123456_02.log", "devprofile/0123456789abcdef.json"})
            check(validate(bundle(e(name, 7))) == 7);
        for (String name : new String[]{null, "", "/logs/host.log", "../logs/host.log",
                "logs/../host.log", "logs//host.log", "logs/./host.log", "logs\\host.log",
                "logs/host.log/", "logs/host.log\0", "logs/host.log\n", "LOGS/host.log",
                "logs/%2e%2e/host.log", "logs/host-../secret.log", "logs/host-x.log",
                "logs/host-２０２６１１１１-123456.log", "manifest.json/secret", "prod.keys",
                "bis/user/save/data", "shaders/input.code", "diagrun/image.png", "metrickit/a.json",
                "resources/game.nsp", "logs/host.log.secret", "logs/host-20261111-123456_2.log", "logs/host-20261111-123456_00.log",
                "logs/host-20261111-123456_01.log", "logs/host-20261111-123456_100.log",
                "devprofile/0123456789ABCDEF.json", "devprofile/0123456789abcde.json", "devprofile/../0123456789abcdef.json",
                "devprofile/0123456789abcdef.json.bak", "devprofile/0123456789abcdef", "0123456789abcdef.json", "devprofile/x/0123456789abcdef.json"})
            rejected(Rejection.NAME_NOT_ALLOWED, bundle(e(name, 1)));
        rejected(Rejection.INVALID_LIST, null);
        rejected(Rejection.INVALID_LIST, new ArrayList<>());
        rejected(Rejection.INVALID_ENTRY, bundle((Entry)null));
        rejected(Rejection.MISSING_MANIFEST, Arrays.asList(e("logs/host.log", 1)));
        rejected(Rejection.DUPLICATE_NAME, bundle(e("manifest.json", 1)));
        rejected(Rejection.DUPLICATE_NAME, bundle(e("logs/host.log", 1), e("logs/host.log", 1)));
        rejected(Rejection.INVALID_SIZE, bundle(e("logs/host.log", -1)));
        rejected(Rejection.INVALID_SIZE, bundle(e("logs/host.log", Long.MIN_VALUE)));
        rejected(Rejection.ENTRY_TOO_LARGE, bundle(e("logs/host.log", MAX_TEXT_BYTES + 1)));
        rejected(Rejection.ENTRY_TOO_LARGE, bundle(e("logs/host.log", Long.MAX_VALUE)));
        rejected(Rejection.ENTRY_TOO_LARGE, Arrays.asList(e("manifest.json", MAX_MANIFEST_BYTES + 1)));
        check(validate(bundle(e("devprofile/0123456789abcdef.json", MAX_PROFILE_BYTES))) == MAX_PROFILE_BYTES);
        rejected(Rejection.ENTRY_TOO_LARGE, bundle(e("devprofile/0123456789abcdef.json", MAX_PROFILE_BYTES + 1)));
        List<Entry> archives = bundle();
        for (int i = 0; i < 9; i++) archives.add(e("logs/host-20261111-123456_" + (i + 10) + ".log", 1));
        check(validate(archives) == 9);
        List<Entry> full = new ArrayList<>(archives);
        for (String name : new String[]{"logs/host.log", "logs/frames.tsv", "logs/threads.txt", "logs/unpack.log",
                "devprofile/0123456789abcdef.json"})
            full.add(e(name, 0));
        check(full.size() == MAX_ENTRIES && validate(full) == 9);
        archives.add(e("logs/host-20261111-123456_09.log", 1));
        rejected(Rejection.TOO_MANY_ARCHIVES, archives);
        List<Entry> many = bundle();
        for (int i = 0; i < MAX_ENTRIES; i++) many.add(e("logs/host.log", 0));
        rejected(Rejection.INVALID_LIST, many);
        List<Entry> total = bundle(e("logs/host.log", 8L << 20), e("logs/frames.tsv", 8L << 20),
                e("logs/threads.txt", 8L << 20), e("logs/unpack.log", 6L << 20));
        check(validate(total) == 30L << 20);
        total.set(4, e("logs/unpack.log", (6L << 20) + 1));
        rejected(Rejection.TOTAL_TOO_LARGE, total);
        // A rejected proposal cannot poison the next one (there is no shared budget).
        check(validate(bundle(e("logs/host.log", 1))) == 1);
        System.out.println("DiagnosticBundlePolicy: " + checks + " checks passed");
    }
}
