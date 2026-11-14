// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// NVN 跳板缺省不计数（照 nxnative e250bb8b，MIT；11-13 能耗性能线）：按名字查到的是不带原子计数的跳板 nvn_thunk_fast，调用照样走到实现、槽计数不动；
// DM_NVN_COUNT=1 时查到的是计数跳板 nvn_thunk，每调一次槽计数 +1。期望按构造写死：
//   ① 缺省：查 nvnDeviceBuilderSetDefaults 得到 nvn_thunk_fast[i]（≠ nvn_thunk[i]）；经它调 3 次，构建器被设成缺省值（实现真跑了），计数 +0
//   ② 子进程 DM_NVN_COUNT=1：查到 nvn_thunk[i]；经它调 3 次，计数 +3
// 反证：查名字仍返回计数跳板 → ① 地址不符、计数 +3（红）
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "nvn_count.h"

extern void *h_nvnBootstrapLoader(const char *name);
typedef struct { _Atomic uint64_t cnt; void *fn; } nvn_slot_t;
extern nvn_slot_t nvn_slot[NVN_NFUNC];
extern void *nvn_thunk[NVN_NFUNC], *nvn_thunk_fast[NVN_NFUNC];
extern const char *nvn_names[NVN_NFUNC];
static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static int idx(const char *name) { for (int i = 0; i < NVN_NFUNC; i++) if (!strcmp(nvn_names[i], name)) return i; return -1; }
// 经查到的地址调 3 次 nvnDeviceBuilderSetDefaults，返回 (计数增量, 地址, 构建器是否被写过)
static uint64_t call3(int i, void **addr, int *wrote) {
    NVNT_nvnDeviceGetProcAddress gpa = (NVNT_nvnDeviceGetProcAddress)h_nvnBootstrapLoader("nvnDeviceGetProcAddress");
    void *f = gpa ? (void *)gpa(NULL, "nvnDeviceBuilderSetDefaults") : h_nvnBootstrapLoader("nvnDeviceBuilderSetDefaults");
    *addr = f; uint64_t c0 = atomic_load(&nvn_slot[i].cnt);
    NVNdeviceBuilder b; memset(&b, 0xA5, sizeof b);
    for (int k = 0; k < 3; k++) ((NVNT_nvnDeviceBuilderSetDefaults)f)(&b);
    const uint8_t *p = (const uint8_t *)&b; *wrote = 0; for (size_t k = 0; k < sizeof b; k++) if (p[k] != 0xA5) { *wrote = 1; break; }
    return atomic_load(&nvn_slot[i].cnt) - c0;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    int i = idx("nvnDeviceBuilderSetDefaults"); if (i < 0) { fprintf(stderr, "名字表里没有 nvnDeviceBuilderSetDefaults\n"); return 2; }
    fflush(stdout); pid_t p = fork(); if (p < 0) return 2;
    if (!p) { setenv("DM_NVN_COUNT", "1", 1); void *a; int w; uint64_t d = call3(i, &a, &w);
        _exit(a == nvn_thunk[i] && d == 3 && w ? 0 : 10 + (a == nvn_thunk[i]) + 2 * (d == 3)); }
    unsetenv("DM_NVN_COUNT"); unsetenv("DM_NVN_TSV");
    void *a; int w; uint64_t d = call3(i, &a, &w);
    CHECK(a == nvn_thunk_fast[i] && a != nvn_thunk[i], "① 缺省查到的是不计数跳板（%p，计数跳板 %p）", a, nvn_thunk[i]);
    CHECK(w && d == 0, "① 经它调 3 次：实现真跑了（构建器被写：%d）、计数 +%llu（期望 +0）", w, (unsigned long long)d);
    int ws = 0; waitpid(p, &ws, 0);
    CHECK(WIFEXITED(ws) && WEXITSTATUS(ws) == 0, "② DM_NVN_COUNT=1：查到计数跳板、调 3 次计数 +3（子进程退出码 %d）", WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
} printf("%s t_nvn_thunk_count：%u 项，失败 %u\n", failures ? "✗" : "✓", checks, failures); return failures ? 1 : 0; }
