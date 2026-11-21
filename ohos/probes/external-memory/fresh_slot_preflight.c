// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "track_platform.h"
#include "fresh_slot_preflight.h"

// Only the embedded real guest reader uses these accounting wrappers. VM
// operations remain actual mmap/munmap and plat_ohos.c mremap/mprotect.
static void *last_alias;
static size_t last_span;
static unsigned reserves, releases;
static int alias_active;
static void *fresh_reserve(void *a, size_t n, int p, int f, int fd, off_t o) {
    void *result = mmap(a, n, p, f, fd, o);
    if (result != MAP_FAILED) { last_alias = result; last_span = n; reserves++; alias_active = 1; }
    return result;
}
static int fresh_release(void *a, size_t n) {
    int result = munmap(a, n);
    if (!result && a == last_alias && n == last_span) { releases++; alias_active = 0; }
    return result;
}

// Keep all probe-local ABI names isolated from the engine. This is a literal
// include of the staged production helper, not a rewritten copy algorithm.
#define s2a_mem_query s2a_fresh_slot_mem_query
#define s2a_android_copy_guest_readonly s2a_fresh_slot_copy_abi
#define mmap fresh_reserve
#define munmap fresh_release
#ifndef S2A_FRESH_GUEST_READ_SOURCE
#error "The packager must supply the actual OHOS guest_read.c path"
#endif
#include S2A_FRESH_GUEST_READ_SOURCE
#undef munmap
#undef mmap
#undef s2a_android_copy_guest_readonly
#undef s2a_mem_query
// The probe has no tracker; the opt-in untracked path reads the source directly.
int s2a_track_read_untracked(uint64_t va, void *dst, uint64_t n) {
    memcpy(dst, (const void *)(uintptr_t)va, (size_t)n);
    return 0;
}

static unsigned char *source;
static size_t page;
static pthread_mutex_t preflight_lock = PTHREAD_MUTEX_INITIALIZER;
int s2a_fresh_slot_mem_query(uint64_t address, s2a_meminfo *info) {
    memset(info, 0, sizeof *info);
    uint64_t begin = (uintptr_t)source;
    if (!source || address < begin || address - begin >= page * 3) return EFAULT;
    info->base = address & ~((uint64_t)page - 1);
    info->size = page;
    info->perm = 1;
    return 0;
}
static unsigned char pattern(size_t i) { return (unsigned char)(i * 7 + i / page); }
static int source_protected(void) {
    for (unsigned i = 0; i < 3; i++)
        if (s2a_track_platform_protection((uintptr_t)source + i * page) != PROT_NONE) return 0;
    return 1;
}
static int alias_released(void) {
    // The queried range belongs to this invocation's temporary reservation.
    if (alias_active || !last_alias) return 0;
    for (size_t at = 0; at < last_span; at += page)
        if (s2a_track_platform_protection((uintptr_t)last_alias + at) != -ENOENT) return 0;
    return 1;
}

__attribute__((visibility("default"))) int S2AFreshSlotPreflight(int logFd) {
    struct stat log_stat;
    if (logFd < 0 || fstat(logFd, &log_stat) || !S_ISREG(log_stat.st_mode)) return EINVAL;
    if (pthread_mutex_trylock(&preflight_lock)) return EBUSY;
    int result = 0, step = 0;
    unsigned char *output = NULL;
    source = NULL; last_alias = NULL; last_span = 0; alias_active = 0; reserves = releases = 0;
#define REQUIRE(x, number) do { step = (number); if (!(x)) { result = errno ? errno : EIO; goto done; } } while (0)
    page = plat_page_size();
    REQUIRE(page >= 4096 && page <= 65536 && !(page & (page - 1)), 1);
    source = mmap(NULL, page * 3, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (source == MAP_FAILED) { source = NULL; result = errno; step = 2; goto done; }
    REQUIRE(mmap(source + page, page, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == source + page, 3);
    output = malloc(page * 3 + 16);
    REQUIRE(output != NULL, 4);
    for (size_t i = 0; i < page * 3; i++) source[i] = pattern(i);
    REQUIRE(mprotect(source, page * 3, PROT_NONE) == 0, 5);
    REQUIRE(source_protected(), 6);
    for (unsigned mode = 0; mode < 2; mode++) {
        unsigned before_reserve = reserves, before_release = releases;
        memset(output, 0xa5, page * 3 + 16);
        int error = copy_readonly((uintptr_t)source + 7, output + 8, page * 3 - 11, mode ? 64 : 1);
        if (error) { result = error; step = 10 + (int)mode; goto done; }
        for (size_t i = 0; i < page * 3 - 11; i++) REQUIRE(output[8 + i] == pattern(i + 7), 12);
        REQUIRE(output[7] == 0xa5 && output[page * 3 - 3] == 0xa5, 13);
        REQUIRE(source_protected() && alias_released(), 14);
        unsigned expected = mode ? 1 : 3;
        REQUIRE(reserves - before_reserve == expected && releases - before_release == expected, 15);
        dprintf(logFd, "FRESH_SLOT mode=%u pages=3 reserves=%u releases=%u bytes=PASS sourcePermissions=NONE cleanup=PASS\n", mode, reserves - before_reserve, releases - before_release);
    }
    REQUIRE(mprotect(source + page, page, PROT_READ | PROT_WRITE) == 0, 20);
    source[page + 17] = 0x6b;
    REQUIRE(mprotect(source + page, page, PROT_NONE) == 0, 21);
    REQUIRE(copy_readonly((uintptr_t)source + page + 17, output, 1, 64) == 0 && output[0] == 0x6b, 22);
    REQUIRE(source_protected() && alias_released(), 23);
    REQUIRE(mmap(source + page, page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == source + page, 30);
    int rejected = copy_readonly((uintptr_t)source, output, page * 3, 64);
    REQUIRE(rejected != 0, 31);
    REQUIRE(source_protected() && alias_released(), 32);
    dprintf(logFd, "FRESH_SLOT changedData=PASS privateBackingRejected=%d failureCleanup=PASS\n", rejected);
done:
    // No alarm, global signal handler, intentional fault, engine dlopen or exit.
    if (alias_active && last_alias && munmap(last_alias, last_span)) result = errno ? errno : EIO;
    if (source && munmap(source, page * 3)) result = errno ? errno : EIO;
    source = NULL; alias_active = 0;
    free(output);
    dprintf(logFd, "FRESH_SLOT result=%s rc=%d step=%d engine=not-loaded gameValidation=not-run restartRequired=1\n", result ? "FAIL" : "PASS", result, step);
    pthread_mutex_unlock(&preflight_lock);
    return result;
#undef REQUIRE
}
