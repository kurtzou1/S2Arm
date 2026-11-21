// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Opt-in, fresh-process host probe. Caller must stop before starting any guest,
// managed tracking callback, or GPU worker, including when this probe fails.
#pragma once
#include "../../graphics/track/s2a_track.h"
#include "../../graphics/track/track_platform.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>

// Only CPU edits should be reported: the GPU flush is the new baseline. Each
// edited host page has one CPU byte at +7 in its first 4K tracking subpage.
static int s2a_ohos_alias_snapshot_check_drain(uintptr_t base, size_t page,
                                              unsigned pages, unsigned edited) {
    s2a_track_batch batch;
    s2a_track_drain(&batch);
    unsigned expected = edited ? pages : 0, seen = 0, bad = 0;
    if (batch.overflow || batch.nranges || batch.nprecise != expected ||
        (batch.nprecise && !batch.precise)) bad = 1;
    if (batch.precise) for (uint32_t i = 0; i < batch.nprecise; ++i) {
        const s2a_track_precise *entry = &batch.precise[i];
        unsigned p;
        for (p = 0; p < pages; ++p) if (entry->addr == base + p * page) break;
        if (!edited || p == pages || (seen & (1u << p))) bad = 1;
        else seen |= 1u << p;
        for (unsigned word = 0; word < 64; ++word)
            if (entry->bits[word] != (word == 0 ? (1ull << 7) : 0)) bad = 1;
    }
    if (edited && seen != (1u << pages) - 1u) bad = 1;
    fprintf(stderr, "[alias-snapshot-probe] drain pages=%u edited=%u %s precise=%u expectedPrecise=%u ranges=%u overflow=%d seen=%u expectedBit=7\n",
            pages, edited, bad ? "FAIL" : "PASS", batch.nprecise, expected,
            batch.nranges, batch.overflow, seen);
    s2a_track_drain_done();
    // A second drain with no intervening write must not report CPU edits again.
    s2a_track_drain(&batch);
    if (batch.overflow || batch.nprecise || batch.nranges) bad = 1;
    fprintf(stderr, "[alias-snapshot-probe] drain-repeat pages=%u edited=%u precise=%u ranges=%u overflow=%d\n",
            pages, edited, batch.nprecise, batch.nranges, batch.overflow);
    s2a_track_drain_done();
    return !bad;
}

static int s2a_ohos_alias_snapshot_probe(void) {
    static _Atomic int ran;
    if (atomic_exchange_explicit(&ran, 1, memory_order_relaxed)) return EALREADY;
    long actual_page = sysconf(_SC_PAGESIZE);
    if (actual_page < 4096 || actual_page > 32768 ||
        (actual_page & (actual_page - 1)) || actual_page % 4096) {
        fprintf(stderr, "[alias-snapshot-probe] setup-failure page=%ld\n", actual_page);
        return ENOTSUP;
    }
    size_t page = (size_t)actual_page, bytes = page * 2;
    uint8_t *guest = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                          MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    uint8_t *gpu = malloc(bytes), *observed = malloc(bytes);
    if (guest == MAP_FAILED || !gpu || !observed) {
        int error = errno ? errno : ENOMEM;
        if (guest != MAP_FAILED) munmap(guest, bytes);
        free(gpu); free(observed);
        fprintf(stderr, "[alias-snapshot-probe] setup-failure allocation error=%d\n", error);
        return error;
    }
    // Verify a real shared alias before introducing tracker protections. Do not
    // substitute a byte copy when the platform cannot provide shared backing.
    void *alias = NULL;
    int error = s2a_track_platform_alias((uintptr_t)guest, page, PROT_READ | PROT_WRITE, &alias);
    if (!error) {
        guest[7] = 0x35;
        if (((volatile uint8_t *)alias)[7] != 0x35) error = EIO;
        ((volatile uint8_t *)alias)[8] = 0x6a;
        if (guest[8] != 0x6a) error = EIO;
        int release = s2a_track_platform_unalias(alias, page);
        if (!error) error = release;
    }
    if (error) {
        fprintf(stderr, "[alias-snapshot-probe] setup-failure shared-alias error=%d\n", error);
        munmap(guest, bytes); free(gpu); free(observed);
        return error;
    }

    s2a_track_prepare();
    s2a_track_set_emul(0);
    s2a_track_set_emul_store(0);
    s2a_track_set_walias(1);
    unsigned failures = 0, cases = 0;
    fprintf(stderr, "[alias-snapshot-probe] begin page=%zu guest=%#llx bytes=%zu cases=5\n",
            page, (unsigned long long)(uintptr_t)guest, bytes);
    // True no-snapshot control: do not call write_quiet or otherwise unprotect
    // between marking GPU None and flushing. It should retain the alias shortcut.
    {
        s2a_track_set_readflush(0);
        s2a_track_reprotect((uintptr_t)guest, bytes, S2A_TRACK_RW);
        s2a_track_batch batch;
        s2a_track_drain(&batch); s2a_track_drain_done();
        memset(guest, 0x11, bytes); memset(gpu, 0x77, bytes);
        s2a_track_stat before, prepared, after;
        s2a_track_stats(&before);
        s2a_track_set_readflush(1);
        s2a_track_reprotect((uintptr_t)guest, page, S2A_TRACK_NONE);
        s2a_track_stats(&prepared);
        int setup_ok = !batch.overflow && prepared.psnaps == before.psnaps &&
            s2a_track_platform_protection((uintptr_t)guest) == PROT_NONE;
        if (setup_ok) {
            s2a_track_write_untracked((uintptr_t)guest, gpu, page, 1);
            s2a_track_stats(&after);
            s2a_track_read_untracked((uintptr_t)guest, observed, page);
            size_t mismatches = 0;
            for (size_t i = 0; i < page; ++i) if (observed[i] != 0x77) ++mismatches;
            int protection = s2a_track_platform_protection((uintptr_t)guest);
            int ok = !mismatches && after.psnaps == before.psnaps &&
                after.preps == prepared.preps && after.restore_bytes == prepared.restore_bytes &&
                after.rf_hostread == prepared.rf_hostread && protection == PROT_NONE;
            fprintf(stderr, "[alias-snapshot-probe] no-snapshot pages=1 %s expectedByte=0x77 actual7=%#x mismatches=%zu snapshots=%llu expectedSnapshots=0 preps=%llu restore=%llu hostread=%llu protection=%d expectedProtection=%d\n",
                    ok ? "PASS" : "FAIL", (unsigned)observed[7], mismatches,
                    (unsigned long long)(after.psnaps - before.psnaps),
                    (unsigned long long)(after.preps - prepared.preps),
                    (unsigned long long)(after.restore_bytes - prepared.restore_bytes),
                    (unsigned long long)(after.rf_hostread - prepared.rf_hostread), protection, PROT_NONE);
            if (!s2a_ohos_alias_snapshot_check_drain((uintptr_t)guest, page, 1, 0)) ok = 0;
            if (!ok) ++failures;
        } else {
            ++failures;
            fprintf(stderr, "[alias-snapshot-probe] no-snapshot FAIL setup snapshots=%llu expectedSnapshots=0 overflow=%d\n",
                    (unsigned long long)(prepared.psnaps - before.psnaps), batch.overflow);
        }
        ++cases;
    }
    for (unsigned pages = 1; pages <= 2; ++pages) {
        for (unsigned edited = 0; edited <= 1; ++edited) {
            size_t length = page * pages;
            s2a_track_set_readflush(0);
            s2a_track_reprotect((uintptr_t)guest, bytes, S2A_TRACK_RW);
            s2a_track_batch batch;
            s2a_track_drain(&batch); s2a_track_drain_done();
            memset(guest, 0x11, bytes);
            memset(gpu, 0x77, bytes);
            s2a_track_stat before, prepared, after;
            s2a_track_stats(&before);
            // Quiet preparation captures baseline snapshots but does not Touch
            // GPU data. Protect the full actual host page so single-page alias
            // eligibility is the same on 4K and larger host page sizes.
            for (unsigned p = 0; p < pages; ++p) {
                uintptr_t at = (uintptr_t)guest + p * page;
                s2a_track_reprotect(at, page, S2A_TRACK_NONE);
                s2a_track_write_quiet(at, page);
                if (edited) guest[p * page + 7] = (uint8_t)(0x41 + p);
            }
            s2a_track_set_readflush(1);
            for (unsigned p = 0; p < pages; ++p)
                s2a_track_reprotect((uintptr_t)guest + p * page, page, S2A_TRACK_NONE);
            s2a_track_stats(&prepared);
            uint64_t expected_snapshots = length / 4096;
            uint64_t snapshots = prepared.psnaps - before.psnaps;
            int setup_ok = !batch.overflow && snapshots == expected_snapshots;
            for (unsigned p = 0; p < pages; ++p)
                if (s2a_track_platform_protection((uintptr_t)guest + p * page) != PROT_NONE)
                    setup_ok = 0;
            if (!setup_ok) {
                ++failures; ++cases;
                fprintf(stderr, "[alias-snapshot-probe] case pages=%u edited=%u FAIL setup snapshots=%llu expected=%llu overflow=%u\n",
                        pages, edited, (unsigned long long)snapshots,
                        (unsigned long long)expected_snapshots, (unsigned)batch.overflow);
                continue;
            }
            // Exactly one production flush. No probe signal handler, manual
            // unprotect, mock callback, or alternate write implementation.
            s2a_track_write_untracked((uintptr_t)guest, gpu, length, 1);
            s2a_track_stats(&after);
            s2a_track_read_untracked((uintptr_t)guest, observed, length);
            size_t mismatches = 0, first = length;
            unsigned expected_first = 0, actual_first = 0;
            for (size_t i = 0; i < length; ++i) {
                uint8_t expected = edited && i % page == 7
                    ? (uint8_t)(0x41 + i / page) : 0x77;
                if (observed[i] != expected) {
                    if (!mismatches) { first = i; expected_first = expected; actual_first = observed[i]; }
                    ++mismatches;
                }
            }
            uint64_t hostreads = after.rf_hostread - prepared.rf_hostread;
            uint64_t restored = after.restore_bytes - prepared.restore_bytes;
            int ok = !mismatches && !hostreads;
            ++cases;
            fprintf(stderr, "[alias-snapshot-probe] case pages=%u edited=%u %s snapshots=%llu expectedSnapshots=%llu mismatches=%zu first=%zu expected=%#x actual=%#x cpu7Expected=%#x cpu7Actual=%#x hostread=%llu restore=%llu expectedRestore=%u hit=%llu inter=%llu\n",
                    pages, edited, ok ? "PASS" : "FAIL", (unsigned long long)snapshots,
                    (unsigned long long)expected_snapshots, mismatches, first, expected_first, actual_first,
                    edited ? 0x41u : 0x77u, (unsigned)observed[7],
                    (unsigned long long)hostreads, (unsigned long long)restored, edited ? pages : 0,
                    (unsigned long long)(after.ucw_hit - prepared.ucw_hit),
                    (unsigned long long)(after.ucw_inter - prepared.ucw_inter));
            if (!s2a_ohos_alias_snapshot_check_drain((uintptr_t)guest, page, pages, edited)) ok = 0;
            if (!ok) ++failures;
        }
    }
    s2a_track_set_readflush(0);
    s2a_track_reprotect((uintptr_t)guest, bytes, S2A_TRACK_RW);
    s2a_track_batch final_batch;
    s2a_track_drain(&final_batch); s2a_track_drain_done();
    if (final_batch.overflow) ++failures;
    if (munmap(guest, bytes)) ++failures;
    free(gpu); free(observed);
    fprintf(stderr, "[alias-snapshot-probe] end cases=%u failures=%u guest-not-started=1\n", cases, failures);
    return failures ? EIO : 0;
}
