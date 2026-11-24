// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Mac 出图层首次取用的多线程竞争（graphics/nvn/host_adapt.m front_metal_layer）：出图线程、游戏线程、主线程同时首调。
//   判据（期望值手写，不跑被测实现推）：8 个线程同起跑线首调，每轮一个新进程（层配置是进程级一次性状态），共 40 轮：
//   ① 配置块只进一次：层配置入口（nvn2_hdr_switch）恰 1 次
//   ② 每个线程拿回的都是同一块层，返回时层已配好 device
//   ③ 进程不崩（改前两个线程同时给静态强引用赋值，objc_storeStrong 的哨兵被另一线程 release，崩在 objc_release）
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include "s2a_t_result.h"

void *front_metal_layer(void);
static CAMetalLayer *g_layer;
__attribute__((used, visibility("default"))) void *s2a_mac_front_layer(void) { return (__bridge void *)g_layer; }

static _Atomic int g_cfg_calls;
int nvn2_hdr_switch(void) { atomic_fetch_add(&g_cfg_calls, 1); return 0; }   // 配置块每进一次调一次（s2a_hdr_layer_apply_to 第一句）；返回 HDR_OFF，层配置到此为止
// host_adapt.m 构造函数与死代码剔除后仍留着的引用（本测不走到的统计 / 远区入口）：名字对上即可
#include <time.h>
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
int s2a_gfx_mode(void) { return 1; }
void s2a_direct_summary_register(void *fn) { (void)fn; }
int s2a_far_has(uint64_t a) { (void)a; return 0; }
void *nvn_dirty_far_fn;
void nvn2_hdr_snapshot_probe(void *s) { (void)s; }
void mtl_hybrid_pkg_stats(void) {} void mtl_se_stats(void) {} void mtl_vp_stats(void) {} void mtl_libact_stats(void) {}

enum { NT = 8, ROUNDS = 40 };
static _Atomic int g_ready, g_go;   // 起跑线：全部线程就位后同时放行（macOS 没有 pthread_barrier）
static void *g_got[NT];
static int g_dev[NT];
static void *take(void *a) {
    int i = (int)(intptr_t)a;
    atomic_fetch_add(&g_ready, 1); while (!atomic_load(&g_go)) {}
    @autoreleasepool {
        CAMetalLayer *l = (__bridge CAMetalLayer *)front_metal_layer();
        g_got[i] = (__bridge void *)l; g_dev[i] = l.device != nil;
    }
    return NULL;
}

static int child(void) {
    @autoreleasepool {
        g_layer = [CAMetalLayer layer];
        g_layer.drawableSize = CGSizeMake(64, 64);
        pthread_t th[NT];
        for (int i = 0; i < NT; i++) pthread_create(&th[i], NULL, take, (void *)(intptr_t)i);
        while (atomic_load(&g_ready) < NT) {}
        atomic_store(&g_go, 1);
        for (int i = 0; i < NT; i++) pthread_join(th[i], NULL);
        int ok = atomic_load(&g_cfg_calls) == 1;
        for (int i = 0; i < NT; i++) ok &= g_got[i] == (__bridge void *)g_layer && g_dev[i];
        if (!ok) printf("  配置块进入 %d 次（期望 1）\n", atomic_load(&g_cfg_calls));
        return ok ? 0 : 1;
    }
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "child")) return child();
    if (!MTLCreateSystemDefaultDevice()) { printf("front layer race: 没有 Metal 设备\n"); return 2; }
    char self[4096]; uint32_t n = sizeof self; if (_NSGetExecutablePath(self, &n)) return 2;
    int pass = 0, crash = 0;
    for (int r = 0; r < ROUNDS; r++) {
        pid_t pid; char *av[] = {self, "child", NULL}; extern char **environ;
        if (posix_spawn(&pid, self, NULL, NULL, av, environ)) return 2;
        int st = 0; waitpid(pid, &st, 0);
        if (WIFEXITED(st) && WEXITSTATUS(st) == 0) pass++;
        else if (WIFSIGNALED(st)) { crash++; printf("  第 %d 轮崩溃：信号 %d\n", r + 1, WTERMSIG(st)); }
    }
    printf("front layer race: %d/%d passed（崩溃 %d 轮）\n", pass, ROUNDS, crash);
    return S2A_T_RESULT("t_front_layer_race", ROUNDS - pass);
}
