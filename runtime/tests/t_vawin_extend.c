// t_vawin_extend：Mac 上别名区伸出窗口的那段并进窗口（vawin.c s2a_window_extend_up），不开远端、不缺页代执行。
//   同 t_vawin_tail 的摆法：本款跨度 30 GB（S2A_WIN_NEED_MB），窗口 = 30 + 2 = 32 GB。期望手写：
//   ① 窗口之上 1 GB 是空的时接上：回 1，窗口 = 33 GB，那段被本进程占着（带提示 mmap 拿不到窗口原末端）、不可访问（mincore 前的权限查询 = 不可访问）
//   ② 新窗口末之上先被别人占了 1 MB：再接 2 GB 回 0，窗口大小不变，别人的映射原样
//   ③ 窗口收过尾部（大小 ≠ 起局预留）后不接：回 0
//   反证：s2a_window_extend_up 去掉核对落点（直接 MAP_FIXED）→ ② 红（盖了别人的映射、回 1）
#include "../src/native.h"
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "30720", 1); setenv("S2A_IPHONE_VA", "0", 1); }   // 先于 vawin.c 的构造函数（101）
int s2a_window_extend_up(uint64_t end);
static int prot_at(uint64_t a) {
    vm_address_t r = (vm_address_t)a; vm_size_t sz = 0; vm_region_basic_info_data_64_t bi; mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &r, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &c, &o) != KERN_SUCCESS || r > a) return -1;
    return bi.protection;
}
int main(void) {
    const uint64_t G = 1ull << 30; int bad = 0; uint64_t b, n; s2a_window_get(&b, &n);
    if (!s2a_window_ok() || n != 32 * G) { printf("✗ 窗口应占 32 GB，得 ok=%d %llu MB\n", s2a_window_ok(), (unsigned long long)(n >> 20)); return 1; }
    void *probe = mmap((void *)(b + n), G, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);   // 窗口之上 1 GB 本来空不空（不空就没法测 ①）
    if (probe != (void *)(b + n)) { if (probe != MAP_FAILED) munmap(probe, G); printf("✓ t_vawin_extend：窗口之上本来就有映射，跳过\n"); return 0; }
    munmap(probe, G);
    // ①
    if (s2a_window_extend_up(b + n + G) != 1) { printf("✗ ① 窗口之上空着应接上\n"); bad++; }
    uint64_t b1, n1; s2a_window_get(&b1, &n1);
    if (b1 != b || n1 != 33 * G) { printf("✗ ① 窗口应为 %#llx +33 GB，得 %#llx +%llu MB\n", (unsigned long long)b, (unsigned long long)b1, (unsigned long long)(n1 >> 20)); bad++; }
    void *m = mmap((void *)(b + n), 1u << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == (void *)(b + n)) { printf("✗ ① 接上的那段应被本进程占着，带提示 mmap 却拿到了 %p\n", m); bad++; }
    if (m != MAP_FAILED) munmap(m, 1u << 20);
    if (prot_at(b + n) != VM_PROT_NONE) { printf("✗ ① 接上的那段应不可访问，权限 %d\n", prot_at(b + n)); bad++; }
    // ②
    void *other = mmap((void *)(b + n1), 1u << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (other == (void *)(b + n1)) {
        if (s2a_window_extend_up(b + n1 + 2 * G) != 0) { printf("✗ ② 新窗口末之上已有映射，不该接\n"); bad++; }
        s2a_window_get(&b1, &n1);
        if (n1 != 33 * G) { printf("✗ ② 窗口大小应不变 33 GB，得 %llu MB\n", (unsigned long long)(n1 >> 20)); bad++; }
        if (prot_at(b + 33 * G) != (VM_PROT_READ | VM_PROT_WRITE)) { printf("✗ ② 别人的映射应原样可读写，权限 %d\n", prot_at(b + 33 * G)); bad++; }
        munmap(other, 1u << 20);
    } else { if (other != MAP_FAILED) munmap(other, 1u << 20); printf("（② 跳过：新窗口末之上本来就有映射）\n"); }
    // ③
    s2a_window_trim(30 * G);
    if (s2a_window_extend_up(b + 40 * G) != 0) { printf("✗ ③ 收过尾部后不该接\n"); bad++; }
    printf("%s t_vawin_extend：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
