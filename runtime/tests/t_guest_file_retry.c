// 客体内存文件后备的补接（vawin.c s2a_guest_file_retry）：装游戏前要整段换成文件（多款容器按本款再判开，#783）时，窗口原封不动才换。
//   11-13 #894 起剩余空间不再拦（起局时判开就接），「要换」的状态只由多款容器再判置位；Mac 上 room 0 走不到，单测用 s2a_guest_file_test_pending 造。
// 期望（按语义手写，不跑被测实现推）：
//   ① 起局时显式关（S2A_GUEST_FILE=0）→ 没接文件（s2a_guest_fd() == -1）；没标「要换」时补接返回 0
//   ② 标了「要换」后补接 → 返回 1、接上文件（fd ≥ 0）；窗口里放开 64 MB 写满，实占增量 < 16 MB（文件映射的脏页不计实占；匿名会 ≥ 48 MB）
//   ③ 子进程（fork 时同样没接上）：补接前先在窗口里放开一页写入（窗口已不是原封不动的一整块保留）→ 补接返回 0、不接文件（整段 MAP_FIXED 会抹掉已有内容）
// 反证：去掉补接里的「窗口原封不动」检查 → ③ 返回 1
#include "../src/native.h"
#include <sys/mman.h>
#include <sys/wait.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "63488", 1); setenv("S2A_GUEST_FILE", "0", 1); }   // 先于 vawin.c 的构造函数
int s2a_guest_file_retry(void); void s2a_guest_file_test_pending(void);
static long long fp(void) { task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c); return (long long)i.phys_footprint; }
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
int main(void) {
    if (!s2a_window_ok()) { printf("✗ t_guest_file_retry：窗口没占到\n"); return 1; }
    CHECK(s2a_guest_fd() == -1 && s2a_guest_file_retry() == 0, "① 起局时显式关：没接文件（fd %d，期望 -1）、没标「要换」补接回 0", s2a_guest_fd());
    uint64_t b, n; s2a_window_get(&b, &n); uint8_t *q = (uint8_t *)(uintptr_t)(b + (4ull << 30)); size_t N = 64u << 20;
    s2a_guest_file_test_pending();
    pid_t c = fork();
    if (!c) {   // ③
        if (mprotect(q, 16384, PROT_READ | PROT_WRITE)) _exit(9); q[0] = 1;
        int r = s2a_guest_file_retry(); _exit(r == 0 && s2a_guest_fd() == -1 ? 0 : 3);
    }
    int st; waitpid(c, &st, 0);
    int r = s2a_guest_file_retry();
    CHECK(r == 1 && s2a_guest_fd() >= 0, "② 标了「要换」：补接返回 %d、fd %d（期望 1、≥ 0）", r, s2a_guest_fd());
    if (mprotect(q, N, PROT_READ | PROT_WRITE)) { printf("✗ t_guest_file_retry：放开 64 MB 失败\n"); return 1; }
    long long f0 = fp(); for (size_t i = 0; i < N; i += 64) q[i] = 1; long long df = fp() - f0;
    CHECK(df < (16ll << 20), "② 接上文件后窗口里写满 64 MB 实占 +%lld KB（期望 < 16384 KB）", df >> 10);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "③ 窗口里已有映射时补接：不换、照旧匿名（子进程退出码 %d，期望 0）", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
    printf("%s t_guest_file_retry：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
