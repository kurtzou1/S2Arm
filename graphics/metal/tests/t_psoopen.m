// 限时打开出包归档（gal_core.m pa_open_timed，11-14：macOS 27.2.1 打开 Xcode 27.1 编的含图形 + 计算管线的归档时系统死循环、永不返回）。
//   期望按规则手写：① 打开很快失败的文件（不存在）→ 返回空、不停用归档；② 注入「系统打开卡住 2 秒」、限时 300 ms → 300 ms 量级返回空、本局停用；
//   ③ 停用后再开（不再注入卡住）→ 立刻返回空（< 50 ms），不再碰系统。反证：去掉限时，② 要等满 2 秒
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
int gal_pso_open_timed_probe(const char *path, int *hung);
static volatile int g_stall_ms;
void gal_pso_test_open_stall(void) { if (g_stall_ms) usleep((useconds_t)g_stall_ms * 1000); }
static double ms_now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
int main(void) { @autoreleasepool {
    setenv("S2A_PSO_OPEN_TIMEOUT_MS", "300", 1);
    if (nxgal_init(0) != 0) { printf("✗ nxgal_init 失败\n"); return 1; }
    int bad = 0, hung = -1; double t;
    t = ms_now(); int got = gal_pso_open_timed_probe("/nonexistent/gal_pso.x.bin", &hung); t = ms_now() - t;
    if (!got && hung == 0 && t < 250) printf("通过 ① 不存在的文件：期望 空 / 不停用 → 真结果 空 / 停用=%d（%.0f ms）\n", hung, t); else { printf("✗ ① 期望 空 / 不停用 → 真结果 %d / %d（%.0f ms）\n", got, hung, t); bad++; }
    g_stall_ms = 2000; t = ms_now(); got = gal_pso_open_timed_probe("/nonexistent/gal_pso.y.bin", &hung); t = ms_now() - t; g_stall_ms = 0;
    if (!got && hung == 1 && t >= 250 && t < 1500) printf("通过 ② 系统打开卡住：期望 约 300 ms 返回空、停用 → 真结果 %.0f ms、停用=%d\n", t, hung); else { printf("✗ ② 期望 约 300 ms 返回空、停用 → 真结果 %d / %d（%.0f ms）\n", got, hung, t); bad++; }
    t = ms_now(); got = gal_pso_open_timed_probe("/nonexistent/gal_pso.z.bin", &hung); t = ms_now() - t;
    if (!got && hung == 1 && t < 50) printf("通过 ③ 停用后再开：期望 立刻返回空 → 真结果 %.1f ms\n", t); else { printf("✗ ③ 期望 立刻返回空 → 真结果 %d / %d（%.1f ms）\n", got, hung, t); bad++; }
    printf("%s t_psoopen：3 项，%d 项失败\n", bad ? "✗" : "✓", bad);
    return bad != 0;
} }
