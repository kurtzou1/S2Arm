// 文件后备局「换成匿名要多少」的客体那份（vawin.c s2a_guest_file_live，#1842）。期望全按构造手推，不跑被测实现：
//   窗口按 32 MB 分块、匿名预算 32 MB（S2A_GUEST_FILE_ANON_BUDGET_MB=32）：第一个放开的块 A 匿名，之后的块 B、C 进文件（同 t_guest_file_overflow ④）。
//   ① 起：没放开过任何页 → 0
//   ② A（匿名）写满 32 MB → 仍 0（匿名的已在进程实占里，不重复算）
//   ③ B（文件）写满 32 MB、C（文件）写前 16 MB → 48 MB（脏页在内存，还没落块）
//   ④ B、C 全写回文件后作废内存页（msync MS_SYNC + MS_INVALIDATE = 已落块、不在内存，等同被系统逐出）→ 仍 48 MB；
//      反证：只数在内存的页（修前口径 = mincore）此刻是 0 → 修前会把这 48 MB 漏掉
//   ⑤ 还页 B 前 16 MB（s2a_guest_zero：打洞）→ 32 MB
//   ⑥ 心跳记需求（s2a_guest_mem_note(实占 100 MB)）→ mem_peak_run 第一项 = 100 + 32 = 132 MB、文件后备标 1
#include "../src/native.h"
#include <sys/mman.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
__attribute__((constructor(100))) static void need(void) {   // 先于 vawin.c 的构造函数（101）
    setenv("S2A_WIN_NEED_MB", "63488", 1); setenv("S2A_GUEST_FILE", "1", 1); setenv("S2A_GUEST_FILE_MIN_FREE_MB", "1", 1); setenv("S2A_GUEST_FILE_ANON_BUDGET_MB", "32", 1);
    unsetenv("S2A_GUEST_FILE_CARVE");
}
void s2a_guest_commit(uint64_t a, uint64_t n); int s2a_guest_zero(uint64_t a, uint64_t n); uint64_t s2a_guest_file_live(void); void s2a_guest_mem_note(uint64_t footprint);
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define MB (1ull << 20)
#define GCH (32ull << 20)
static int put(uint64_t p, uint64_t n) {
    s2a_guest_commit(p, n);
    if (mprotect((void *)(uintptr_t)p, n, PROT_READ | PROT_WRITE)) return -1;
    memset((void *)(uintptr_t)p, 7, n); return 0;
}
static uint64_t incore(uint64_t p, uint64_t n) {
    size_t pg = (size_t)getpagesize(), k = (size_t)(n / pg); unsigned char *v = malloc(k); uint64_t c = 0;
    if (!mincore((void *)(uintptr_t)p, (size_t)n, (char *)v)) for (size_t i = 0; i < k; i++) c += (v[i] & MINCORE_INCORE) != 0;
    free(v); return c * pg;
}
int main(void) {
    if (!s2a_window_ok() || s2a_guest_fd() < 0) { printf("✗ t_guest_need_file：窗口没占到 / 没开文件后备\n"); return 1; }
    uint64_t b, n; s2a_window_get(&b, &n);
    uint64_t A = b, B = b + GCH, C = b + 2 * GCH;
    CHECK(s2a_guest_file_live() == 0, "① 起：0（得 %llu MB）", (unsigned long long)(s2a_guest_file_live() / MB));
    CHECK(!put(A, GCH) && s2a_guest_file_live() == 0, "② 匿名块 A 写满 32 MB：仍 0（得 %llu MB）", (unsigned long long)(s2a_guest_file_live() / MB));
    CHECK(!put(B, GCH) && !put(C, 16 * MB) && s2a_guest_file_live() == 48 * MB, "③ 文件块 B 写满 32 + C 写 16：48 MB（得 %llu MB）", (unsigned long long)(s2a_guest_file_live() / MB));
    msync((void *)(uintptr_t)B, 2 * GCH, MS_SYNC); msync((void *)(uintptr_t)B, 2 * GCH, MS_INVALIDATE);
    uint64_t ic = incore(B, 2 * GCH);
    CHECK(s2a_guest_file_live() == 48 * MB, "④ 写回 + 逐出后：仍 48 MB（得 %llu MB）", (unsigned long long)(s2a_guest_file_live() / MB));
    CHECK(ic == 0, "④ 反证：只数在内存的页（修前口径）此刻 %llu MB（期望 0，修前会漏掉这 48 MB）", (unsigned long long)(ic / MB));
    CHECK(s2a_guest_zero(B, 16 * MB) == 1 && s2a_guest_file_live() == 32 * MB, "⑤ 还页 B 前 16 MB（打洞）：32 MB（得 %llu MB）", (unsigned long long)(s2a_guest_file_live() / MB));
    char rk[] = "/tmp/t_gneed_run_XXXXXX"; int fd = mkstemp(rk); close(fd); unlink(rk);
    setenv("S2A_GUEST_MEM_PEAK_RUN", rk, 1); setenv("S2A_GUEST_MEM_PEAK", "/tmp/t_gneed_peak_unused", 1);
    s2a_guest_mem_note(100 * MB);
    unsigned long long need = 0, beats = 0; int file = -1; FILE *f = fopen(rk, "r"); if (f) { if (fscanf(f, "%llu %llu %d", &need, &beats, &file) != 3) need = 0; fclose(f); }
    unlink(rk);
    CHECK(need == 132 * MB && file == 1, "⑥ 心跳记需求 = 实占 100 + 文件里 32 = 132 MB、文件后备 1（得 %llu MB、%d）", need / MB, file);
    printf("t_guest_need_file：%s\n", bad ? "有失败" : "全过");
    return bad ? 1 : 0;
}
