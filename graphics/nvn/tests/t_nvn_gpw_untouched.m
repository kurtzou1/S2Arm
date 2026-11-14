// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// GPU 写记账（nvn_mtl.m gpw_add 打哈希、gpw_stale 核对）不读游戏从没碰过的页。
// 背景（11-13 0400486024DEC000 Mac 读档进场景）：新建的渲染目标存储游戏没写过，记账时逐 GOB 读一遍算哈希，一帧读 154 / 320 MB，
//   几乎全是没碰过的页：每页缺页一次、都在提交线程上，读出来的零页还计进进程实占。
// 期望（按宿主内核行为与 Switch 语义手写，不由被测实现推出；不经 Metal）：
//   ① 新映射 64 MB 匿名内存（同客体新内存，没写过），整段记成 GPU 写过：前后进程实占增量 < 4 MB（账本自己每 256 KB 一块、4 KB 多，64 MB 约 1 MB），常驻 / 压缩页 0
//   ② 紧接着核对整段：仍全部陈旧（字节没变，Switch 上那段内存还是 GPU 写的），核对也不让页进常驻
//   ③ CPU 往第 40 MB + 5 字节写非 0：那个 GOB 变回最新，其余仍陈旧
//   ④ CPU 往另一页写 0（碰过、内容仍是记账时的 0）：那个 GOB 仍陈旧
//   ⑤ 记账前就写过内容的页照读：之后改其中一个字节，那个 GOB 变回最新
#include "../gfx/nvn/nvn_mtl.m"
#include <mach/mach.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static int64_t footprint(void) { task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; REQUIRE(task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c) == KERN_SUCCESS); return (int64_t)i.phys_footprint; }
static uint64_t touched(const void *p, size_t n) {
    size_t pg = (size_t)getpagesize(), np = (n + pg - 1) / pg; unsigned char *v = malloc(np); REQUIRE(v && !mincore((void *)p, n, (char *)v));
    uint64_t r = 0; for (size_t i = 0; i < np; i++) if (v[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT)) r += pg; free(v); return r;
}
static void mark(uint8_t *p, uint64_t n) { pthread_mutex_lock(&g_gpw_mu); gpw_add(p, 0, n); pthread_mutex_unlock(&g_gpw_mu); }
static uint64_t stale_bytes(const uint8_t *p, uint64_t n) { uint64_t *runs = NULL, b = 0; gpw_stale(p, n, &runs, &b); free(runs); return b; }
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        enum { N = 64 << 20, M = 1 << 20 };
        size_t pg = (size_t)getpagesize();
        uint8_t *a = mmap(NULL, N, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), *b = mmap(NULL, M, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        REQUIRE(a != MAP_FAILED && b != MAP_FAILED && !((uintptr_t)a & 511));
        int64_t f0 = footprint(); mark(a, N); int64_t df = footprint() - f0;
        CHECK(df < (4 << 20), "① 记账未写的 64 MB：进程实占 +%lld KB（期望 < 4096 KB；逐 GOB 读会 +65536 KB 以上）", (long long)(df >> 10));
        CHECK(touched(a, N) == 0, "① 记账后常驻 / 压缩 %llu KB（期望 0）", (unsigned long long)(touched(a, N) >> 10));
        f0 = footprint(); uint64_t s = stale_bytes(a, N); df = footprint() - f0;
        CHECK(s == N, "② 核对整段：陈旧 %llu MB（期望 64 MB）", (unsigned long long)(s >> 20));
        CHECK(df < (1 << 20) && touched(a, N) == 0, "② 核对时进程实占 +%lld KB、常驻 %llu KB（期望 < 1024 KB、0）", (long long)(df >> 10), (unsigned long long)(touched(a, N) >> 10));
        a[(40u << 20) + 5] = 7;
        s = stale_bytes(a, N);
        CHECK(s == N - 512, "③ 第 40 MB + 5 字节写成非 0：陈旧 %llu 字节（期望 %u：只少那个 GOB）", (unsigned long long)s, N - 512);
        memset(a + 3 * pg + 1024, 0, 16);
        s = stale_bytes(a, N);
        CHECK(s == N - 512, "④ 第 3 页写 0（内容同记账时）：陈旧 %llu 字节（期望 %u：不变）", (unsigned long long)s, N - 512);
        for (size_t i = 0; i < M; i += 64) b[i] = (uint8_t)(i >> 6 | 1);
        mark(b, M);
        CHECK(stale_bytes(b, M) == M, "⑤ 写过内容的 1 MB 记账后核对：全部陈旧");
        b[2 * pg + 600] ^= 0x5A;
        s = stale_bytes(b, M);
        CHECK(s == M - 512, "⑤ 改第 2 页第 600 字节：陈旧 %llu 字节（期望 %u）", (unsigned long long)s, M - 512);
        printf("%s t_nvn_gpw_untouched: %u checks %u failures\n", failures ? "✗" : "✓", checks, failures);
        return failures != 0;
    }
}
