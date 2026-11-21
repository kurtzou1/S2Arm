// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS normal GPU-owner read copy. ABI name is retained for the shared managed
// consumer; this translation unit is selected only by the OHOS native target.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef S2A_OHOS_GUEST_READ_TEST
#include "guest_read_test_platform.h"
#else
#include "../../runtime/include/s2a_native.h"
#include "../../platform/plat.h"
#include "../../graphics/track/s2a_track.h"
#include <sys/mman.h>
#include <pthread.h>
#include <stdlib.h>
#endif
#include <errno.h>
#include <stdint.h>
#include <string.h>

static pthread_once_t g_read_once = PTHREAD_ONCE_INIT;
static size_t g_read_batch_pages = 1;
// Experiment DEBUG_S2A_GUEST_READ_DIRECT=1: after the same admission check, copy through the
// tracker's untracked read (direct memcpy except tracker PROT_NONE pages). It removed the per-page
// mmap + alias + munmap (~11% of the BotW GPU thread on Mate90) but measured 9.5 fps against
// 11.0-13.2 fps for this default path at the same spot, so it stays opt-in.
static int g_read_alias_always = 1;
static void read_init(void) {
    const char *value = getenv("S2A_OHOS_GUEST_READ_BATCH");
    if (value && value[0] == '1' && !value[1]) g_read_batch_pages = 64;
    const char *direct = getenv("DEBUG_S2A_GUEST_READ_DIRECT");
    g_read_alias_always = !(direct && direct[0] == '1' && !direct[1]);
}

// One fresh reservation per bounded block. Each source page is separately
// mapped into a previously untouched reserved slot: never retarget an alias,
// span a source VMA, retain an alias across calls, or change source permissions.
static int copy_readonly(uint64_t address, void *destination, uint64_t size, size_t batch_pages) {
    if (!size) return 0;
    uintptr_t target = (uintptr_t)destination;
    size_t page = plat_page_size();
    if (!destination || !page || (page & (page - 1)) || size > SIZE_MAX
        || size > UINT64_MAX - address || size > UINTPTR_MAX - target
        || !batch_pages || batch_pages > 64 || page > SIZE_MAX / batch_pages) return EINVAL;
    uint64_t end = address + size;
    if (address < target + size && target < end) return EINVAL;

    // Preserve the existing logical-VM read admission, including holes. The
    // caller retains the existing synchronous GPU-owner backing transaction.
    for (uint64_t cursor = address; cursor < end;) {
        s2a_meminfo info;
        int error = s2a_mem_query(cursor, &info);
        if (error) return error;
        if (!(info.perm & 1) || info.base > cursor || !info.size
            || info.size > UINT64_MAX - info.base || info.base + info.size <= cursor) return EFAULT;
        uint64_t next = info.base + info.size;
        cursor = next < end ? next : end;
    }
#ifndef S2A_OHOS_GUEST_READ_TEST
    if (!g_read_alias_always) { s2a_track_read_untracked(address, destination, size); return 0; }
#endif

    uint8_t *output = destination;
    for (uint64_t cursor = address; cursor < end;) {
        uint64_t base = cursor & ~((uint64_t)page - 1);
        size_t offset = (size_t)(cursor - base);
        size_t capacity = page * batch_pages;
        uint64_t count = end - cursor;
        if (count > capacity - offset) count = capacity - offset;
        size_t span = ((offset + (size_t)count - 1) / page + 1) * page;
        if (base > UINTPTR_MAX - span) return EINVAL;
        void *alias = mmap(NULL, span, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (alias == MAP_FAILED) return errno;
        int error = 0;
        for (size_t at = 0; at < span; at += page) {
            error = plat_vm_alias((uint8_t *)alias + at, (const void *)(uintptr_t)(base + at), page, PLAT_PROT_READ);
            if (error) break;
            size_t begin = at ? 0 : offset;
            size_t bytes = page - begin;
            if (bytes > count) bytes = (size_t)count;
            memcpy(output, (const uint8_t *)alias + at + begin, bytes);
            output += bytes;
            cursor += bytes;
            count -= bytes;
        }
        // Includes successful aliases, failed slot restored by plat_vm_alias,
        // and untouched reserved slots. A partial destination must be discarded.
        int release_error = munmap(alias, span) ? (errno ? errno : EIO) : 0;
        if (release_error) return release_error;
        if (error) return error;
    }
    return 0;
}

int s2a_android_copy_guest_readonly(uint64_t address, void *destination, uint64_t size) {
    pthread_once(&g_read_once, read_init);
    return copy_readonly(address, destination, size, g_read_batch_pages);
}
