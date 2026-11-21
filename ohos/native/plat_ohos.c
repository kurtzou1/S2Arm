// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// HarmonyOS implementation of plat.h. VM and signal semantics follow the
// shared Linux path; musl TSD is measured independently, never treated as Bionic.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../../platform/plat.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "../../android/native/guest_signal.h"
#include "../../android/native/memory.h"
#include "tsd_ohos.h"

size_t plat_page_size(void) {
    long pg = sysconf(_SC_PAGESIZE);
    return pg > 0 ? (size_t)pg : 0;
}

uint64_t plat_now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

#ifdef S2A_UNIT_TEST
static int g_plat_test_protect_fail;
static int g_plat_test_restore_fail;
void plat_vm_test_set_protect_fail(int on) { g_plat_test_protect_fail = on; }
void plat_vm_test_set_restore_fail(int on) { g_plat_test_restore_fail = on; }
#endif

static int plat_restore_reserved(void *dst, size_t size) {
    // Keep dst reserved in the guest window; never hand it back to the system.
    if (!dst || !size) return EINVAL;
#ifdef S2A_UNIT_TEST
    if (g_plat_test_restore_fail) return ENOMEM;
#endif
    void *p = mmap(dst, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (p == dst) return 0;
    if (p != MAP_FAILED) munmap(p, size);
    return errno ? errno : EIO;
}

static int plat_native_prot(uint32_t prot, int *out) {
    if (prot & ~(uint32_t)(PLAT_PROT_READ | PLAT_PROT_WRITE | PLAT_PROT_EXEC)) return EINVAL;
    int p = PROT_NONE;
    if (prot & PLAT_PROT_READ) p |= PROT_READ;
    if (prot & PLAT_PROT_WRITE) p |= PROT_WRITE;
    if (prot & PLAT_PROT_EXEC) p |= PROT_EXEC;
    *out = p;
    return 0;
}

int plat_vm_reserve(size_t size, size_t alignment, uint64_t limit, void **out) {
    if (!out) return EINVAL;
    void *p = NULL;
    int e = s2a_android_reserve(size, alignment, limit, &p);
    if (!e) *out = p;
    return e;
}

int plat_vm_protect(void *addr, size_t size, uint32_t prot) {
    if (!addr || !size) return EINVAL;
    size_t pg = plat_page_size();
    if (!pg || ((uintptr_t)addr & (pg - 1)) || (size % pg)) return EINVAL;
    int p;
    int e = plat_native_prot(prot, &p);
    if (e) return e;
    return mprotect(addr, size, p) ? errno : 0;
}

int plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot) {
    if (!dst || !src || !size || dst == src) return EINVAL;
    size_t pg = plat_page_size();
    if (!pg) return ENOTSUP;
    if (((uintptr_t)dst & (pg - 1)) || ((uintptr_t)src & (pg - 1)) || (size % pg)) return EINVAL;
    int p;
    int e = plat_native_prot(prot, &p);
    if (e) return e;
#if defined(MREMAP_FIXED)
    // Linux/musl: old_size == 0 duplicates the mapping.  FIXED requires a
    // shared-backed src and a reserved dst; both are part of the contract.
    // NativeBuffer VMAs need an alias of their owner's fd, not mremap.
    // These temporary tracker/VM views are not guest GPU address windows.
    extern int s2a_zpool_alias_map(void *, const void *, size_t, int) __attribute__((weak));
    int native_alias = s2a_zpool_alias_map ? s2a_zpool_alias_map(dst, src, size, 0) : 0;
    void *r;
    if (native_alias) { r = native_alias > 0 ? dst : MAP_FAILED; if (native_alias < 0) errno = -native_alias; }
    else r = mremap((void *)src, 0, size, MREMAP_MAYMOVE | MREMAP_FIXED, dst);
    if (r == MAP_FAILED) { e = errno; int re = plat_restore_reserved(dst, size); return re ? EIO : e; }
#ifdef S2A_UNIT_TEST
    if (g_plat_test_protect_fail) e = EACCES; else
#endif
    e = plat_vm_protect(dst, size, prot);
    if (e) { int re = plat_restore_reserved(dst, size); return re ? EIO : e; }
    return 0;
#else
    (void)p;
    return ENOTSUP;
#endif
}

int plat_tsd_init(void) { return s2a_ohos_tsd_init(); }
uint64_t plat_tsd_base(void) { return s2a_ohos_tsd_base(); }
int plat_tsd_offset(uint32_t key, uint64_t *out) { return s2a_ohos_tsd_offset(key, out); }

int plat_fault_install(int sig, void (*fn)(int, siginfo_t *, void *), unsigned flags) {
    if (!fn || sig <= 0) return EINVAL;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = fn;
    // Every handler that can run on a guest thread must use its alternate
    // stack: the guest stack may be only a few KiB and may already be corrupt.
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    if (flags & PLAT_FAULT_RESTART) sa.sa_flags |= SA_RESTART;
    sigemptyset(&sa.sa_mask);
    return sigaction(sig, &sa, NULL) ? errno : 0;
}

int plat_fault_altstack_init(void) {
    return s2a_android_altstack_init();
}

void plat_fault_altstack_free(void) {
    s2a_android_altstack_free();
}

int plat_thread_stack_bounds(uintptr_t *low, uintptr_t *high) {
    if (!low || !high) return EINVAL;
    pthread_attr_t attr;
    int e = pthread_getattr_np(pthread_self(), &attr);
    if (e) return e;
    void *addr = NULL;
    size_t size = 0;
    e = pthread_attr_getstack(&attr, &addr, &size);
    pthread_attr_destroy(&attr);
    if (e) return e;
    if (!addr || !size) return EINVAL;
    *low = (uintptr_t)addr;
    *high = *low + size;
    return 0;
}

int plat_thread_self(plat_thread_t *out) {
    if (!out) return EINVAL;
    uintptr_t self = (uintptr_t)pthread_self();
    if (!self) return EIO;
    *out = (plat_thread_t)self;
    return 0;
}

// Graphics mode is frozen by the runtime before relocation (direct/selection.c), as on Android.
// The standalone V0 VM probe compiles a copy of this file without the direct tree: it gets none of this section.
#if __has_include("direct/selection.h")
#include "direct/selection.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
int s2a_gfx_mode(void) {
    const struct s2a_direct_selection *selection = s2a_direct_selection_current();
    return selection && selection->mode == 1 ? 1 : 0;  // 1 = S2A_GFX_DIRECT
}
// The selection is frozen before relocation; until then the mode is not settled (direct_prompt.c waits on it).
int s2a_gfx_mode_settled(void) { return s2a_direct_selection_current() != NULL; }
// hle_nvn.c reports each present to Android's GPU-turbo controller (android/native/gpu_turbo.c); OHOS has no
// KGSL turbo, the system schedules from QoS / Game Service Kit hints (host/performance_ohos.cpp).
void s2a_android_frame_note(void) {}

// The shared NVN frontend's bootstrap (hle_nvn.c HLE_FORCE); NULL when the frontend is not linked.
extern void *h_nvnBootstrapLoader(const char *name) __attribute__((weak));
void *sw_xstack_wrap(const char *name, void *fn);

// The loader asks once per undefined import in direct mode. Only nvnBootstrapLoader belongs to
// the direct frontend; every other name returns 0 so normal resolution continues.
uint64_t s2a_direct_lookup(const char *name) {
    // Switch 2：游戏自带的 NVN2 驱动 / nn::gs / gsv 直连档不启动，依赖它们的 sdk 函数由宿主答（同 gfxmode.c）。Switch 1 两个入口都回 NULL。
    if (name && (!strncmp(name, "_Z", 2) || !strncmp(name, "Nv", 2))) {
        const struct s2a_direct_selection *selection = s2a_direct_selection_current();
        if (selection && selection->mode == 1) {
            extern void *s2a_nv_entry(const char *name) __attribute__((weak));
            extern void *s2a_codec_entry(const char *name) __attribute__((weak));
            extern void *nvn2_vi_entry(const char *name) __attribute__((weak));
            void *f = (nvn2_vi_entry && (!strncmp(name, "_ZN2nn2vi", 9) || !strncmp(name, "_ZNK2nn2vi", 10))) ? nvn2_vi_entry(name) : NULL;
            if (!f && s2a_nv_entry) f = s2a_nv_entry(name);
            if (!f && s2a_codec_entry) f = s2a_codec_entry(name);
            if (f) return (uint64_t)(uintptr_t)sw_xstack_wrap(name, f);
        }
    }
    const struct s2a_direct_selection *selection = s2a_direct_selection_current();
    if (!selection || selection->mode != 1 || !name) return 0;
    if (strcmp(name, "nvnBootstrapLoader")) return 0;
    if (!h_nvnBootstrapLoader) {
        fprintf(stderr, "[s2a] FATAL direct graphics selected but the shared NVN frontend is not linked\n");
        abort();
    }
    // 非命令录制的 NVN 实现（提交 / 呈现 / 建对象，会深入 Maleoon 驱动）也切宿主大栈，同上游安卓 direct_session.c：
    //   漏了这一步时，游戏线程的小栈被驱动调用压穿（11-09 v0.1.0 塞尔达起局后 SIGSEGV，pc 在 libhitrace_meter，调用方 libmaleoon，sp 在客体窗口内）。
    extern void s2a_nvn_set_xwrap(void *(*)(const char *, void *)) __attribute__((weak));
    if (s2a_nvn_set_xwrap) s2a_nvn_set_xwrap(sw_xstack_wrap);
    // 与 gfxmode.c 一样经切栈桩交给游戏：宿主实现不跑在游戏的小栈上。
    return (uint64_t)(uintptr_t)sw_xstack_wrap(name, (void *)h_nvnBootstrapLoader);
}
// No Apple tail region on OHOS: callers fall back to their own anonymous mappings.
void *s2a_tail_map(uint64_t len, int user, int prot) { (void)len; (void)user; (void)prot; return NULL; }
void s2a_tail_unmap(void *p, uint64_t len, int user) { (void)user; if (p) munmap(p, len); }
#endif
