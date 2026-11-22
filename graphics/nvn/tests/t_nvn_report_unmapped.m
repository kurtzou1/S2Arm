// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 计数器 / 时间戳报告写到换不成 CPU 地址的 GPU 地址（不在任何池里）：完成回调不能往那里写（宿主上没映射，写即崩）。
//   判据（期望手写）：池尾之后 64 KB 间隔里的 GPU 地址（池的 GPU 段之间留 64 KB 间隔，hle_nvn.c gva_alloc）各报一次时间戳 / 样本数，
//   同一提交里再往池内合法地址报一次时间戳：提交在 10 s 内完成、没有 GPU 错误、进程不崩；池内那次照常写到（计数字段与时间字段都不再是 0xa5 填充）。
//   负对照：去掉 nvn_mtl.m post() 里那段判断，本单测在完成回调里 SIGSEGV（进程退出码非 0）
#include "../gfx/nvn/nvn_mtl.m"
#include "nvn_protos.h"
extern void *h_nvnBootstrapLoader(const char *name);
static unsigned checks, failures;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define CHECK(x, ...) do { checks++; int ok = !!(x); failures += !ok; printf("%s ", ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *load(const char *name) { void *p = h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)load(#name))
enum { SEG = 65536, BYTES = 4 * SEG };
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); setenv("DM_PSO_ARCHIVE", "0", 1);
    NVNdevice dev; NVNqueue queue; NVNmemoryPool pool; NVNcommandBuffer cmd;
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&dev, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &dev); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    uint8_t *storage; REQUIRE(posix_memalign((void **)&storage, SEG, BYTES) == 0); memset(storage, 0, BYTES);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &dev);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, BYTES);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED); REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb));
    NVNbufferAddress ga = API(nvnMemoryPoolGetBufferAddress)(&pool);
    CHECK(nvn_ga_unmapped(ga) && !nvn_ga_unmapped(nvn_ga2ca(ga)), "池的缓冲区地址 %#llx 在 GPU 地址窗口里、换得成 CPU 地址", (unsigned long long)ga);
    NVNbufferAddress bad = ga + BYTES + SEG - 16;   // 池尾之后的间隔里：不在任何池（同 D-BSX8 的 0xc01d4afff0 = 下一 64 KB 边界前 16 字节）
    CHECK(nvn_ga_unmapped(nvn_ga2ca(bad)), "间隔里的 GPU 地址 %#llx 换不成 CPU 地址", (unsigned long long)bad);
    uint64_t *ok_rec = (uint64_t *)(storage + 3 * SEG); memset(ok_rec, 0xa5, 16);
    static uint8_t control[4096];
    REQUIRE(API(nvnCommandBufferInitialize)(&cmd, &dev)); API(nvnCommandBufferAddControlMemory)(&cmd, control, sizeof control); API(nvnCommandBufferAddCommandMemory)(&cmd, &pool, SEG, SEG);
    API(nvnCommandBufferBeginRecording)(&cmd);
    API(nvnCommandBufferReportCounter)(&cmd, NVN_COUNTER_TYPE_TIMESTAMP, bad);
    API(nvnCommandBufferReportCounter)(&cmd, NVN_COUNTER_TYPE_SAMPLES_PASSED, bad);
    API(nvnCommandBufferReportCounter)(&cmd, NVN_COUNTER_TYPE_TIMESTAMP, ga + 3 * SEG);
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&cmd); REQUIRE(h);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); uint64_t f = nvn_be_last_fence();
    int done = nvn_be_wait(f, 10000000000ull);
    CHECK(done && !mtl_last_commit_error(), "提交 10 s 内完成、没有 GPU 错误（完成回调没往换不了的地址写）");
    const uint64_t fill = 0xa5a5a5a5a5a5a5a5ull;
    CHECK(ok_rec[0] != fill && ok_rec[1] != fill, "池内合法地址的时间戳照常写到（计数 %#llx、时间 %#llx）", (unsigned long long)ok_rec[0], (unsigned long long)ok_rec[1]);
    printf("%s t_nvn_report_unmapped: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures); return failures != 0;
} }
