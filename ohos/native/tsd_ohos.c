// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Probe the musl ABI, including its private TCB field, without guessing a
// release-specific structure offset. Kernel copy_from_user makes unreadable
// candidates fail with EFAULT instead of installing a temporary SIGSEGV handler.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "tsd_ohos.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

#if !defined(__OHOS__) || !defined(__aarch64__)
#error "OHOS musl TSD requires the real aarch64 OHOS toolchain"
#endif
__attribute__((visibility("hidden"))) int64_t g_s2a_ohos_tsdoff;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static int g_error = EAGAIN;
static uint32_t g_key_limit;

static uintptr_t thread_pointer(void) {
    uintptr_t p;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(p));
    return p;
}
static int read_word(int pipefd[2], uintptr_t addr, uintptr_t *out) {
    ssize_t n;
    do { n = write(pipefd[1], (const void *)addr, sizeof *out); } while (n < 0 && errno == EINTR);
    if (n < 0) return errno;
    if (n != sizeof *out) {
        unsigned char drain[sizeof *out];
        if (n > 0) (void)read(pipefd[0], drain, (size_t)n);
        return EIO;
    }
    size_t got = 0;
    while (got < sizeof *out) {
        do { n = read(pipefd[0], (char *)out + got, sizeof *out - got); } while (n < 0 && errno == EINTR);
        if (n <= 0) return n < 0 ? errno : EIO;
        got += (size_t)n;
    }
    return 0;
}
static int probe_thread(pthread_key_t key, int64_t *out) {
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC)) return errno;
    uintptr_t marker1 = (uintptr_t)&pipefd, marker2 = (uintptr_t)&marker1;
    int e = pthread_setspecific(key, (void *)marker1);
    int matches = 0;
    int64_t found = 0;
    uintptr_t tp = thread_pointer();
    // musl places a new thread's TCB right above its stack, so the scan window also covers that
    // thread's stack, where dead frames of pthread_setspecific and this probe still hold copies of
    // the table pointer (OpenHarmony 7.0.0.39 emulator: four matches in the worker, ENOTSUP).
    // The TCB field is never inside the thread's own stack mapping: skip that range.
    uintptr_t stack_lo = 0, stack_hi = 0;
    pthread_attr_t attr;
    if (!e) e = pthread_getattr_np(pthread_self(), &attr);
    if (!e) {
        void *addr = NULL; size_t size = 0;
        e = pthread_attr_getstack(&attr, &addr, &size);
        if (!e) {
            stack_lo = (uintptr_t)addr;
            if (!size || size > UINTPTR_MAX - stack_lo) e = EINVAL;
            else stack_hi = stack_lo + size;
        }
        pthread_attr_destroy(&attr);
    }
    for (int64_t offset = -4096; !e && offset <= 256; offset += 8) {
        uintptr_t table, value;
        if (tp + (uintptr_t)offset >= stack_lo && tp + (uintptr_t)offset < stack_hi) continue;
        if (read_word(pipefd, tp + (uintptr_t)offset, &table)) continue;
        if (table < 4096 || (table & 7) || table > UINTPTR_MAX - ((uint64_t)key + 1) * 8) continue;
        uintptr_t slot = table + (uint64_t)key * 8;
        if (read_word(pipefd, slot, &value) || value != marker1) continue;
        e = pthread_setspecific(key, (void *)marker2);
        if (e) break;
        if (!read_word(pipefd, slot, &value) && value == marker2) { matches++; found = offset; }
        e = pthread_setspecific(key, (void *)marker1);
    }
    int clear_error = pthread_setspecific(key, NULL);
    close(pipefd[0]); close(pipefd[1]);
    if (e) return e;
    if (clear_error) return clear_error;
    if (matches != 1 || found >= 0) return ENOTSUP;
    *out = found;
    return 0;
}
struct probe_work { pthread_key_t key; int error; int64_t offset; };
static void *probe_worker(void *opaque) {
    struct probe_work *work = opaque;
    work->error = probe_thread(work->key, &work->offset);
    return NULL;
}
static void initialize(void) {
    long limit = sysconf(_SC_THREAD_KEYS_MAX);
    if (limit <= 0 || (unsigned long)limit > UINT32_MAX) { g_error = ENOTSUP; return; }
    pthread_key_t key;
    g_error = pthread_key_create(&key, NULL);
    if (g_error) return;
    int64_t first = 0;
    g_error = probe_thread(key, &first);
    if (!g_error) {
        struct probe_work work = {.key = key, .error = EAGAIN};
        pthread_t worker;
        g_error = pthread_create(&worker, NULL, probe_worker, &work);
        if (!g_error) {
            // A join failure cannot permit a detached probe to retain stack data.
            int join_error = pthread_join(worker, NULL);
            if (join_error) _exit(125);
            g_error = work.error;
            if (!g_error && first != work.offset) g_error = ENOTSUP;
        }
    }
    int delete_error = pthread_key_delete(key);
    if (!g_error && delete_error) g_error = delete_error;
    if (!g_error) { g_s2a_ohos_tsdoff = first; g_key_limit = (uint32_t)limit; }
}
int s2a_ohos_tsd_init(void) {
    int e = pthread_once(&g_once, initialize);
    return e ? e : g_error;
}
uint64_t s2a_ohos_tsd_base(void) {
    if (s2a_ohos_tsd_init()) return 0;
    uintptr_t table = *(const uintptr_t *)(thread_pointer() + (uintptr_t)g_s2a_ohos_tsdoff);
    return table >= 8 ? table - 8 : 0;
}
int s2a_ohos_tsd_offset(uint32_t key, uint64_t *out) {
    if (!out) return EINVAL;
    int e = s2a_ohos_tsd_init();
    if (e) return e;
    if (key >= g_key_limit) return EINVAL;
    *out = ((uint64_t)key + 1) * 8;
    return 0;
}
int s2a_ohos_tsd_pointer_offset(int64_t *out) {
    if (!out) return EINVAL;
    int e = s2a_ohos_tsd_init();
    if (e) return e;
    *out = g_s2a_ohos_tsdoff;
    return 0;
}
