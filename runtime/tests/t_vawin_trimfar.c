// t_vawin_trimfar：有远端段（别名区伸出窗口）时窗口收尾不还尾部（11-21 D-D6ZG：还给系统的尾部被宿主映射占住，远端判重叠整段不开）。
//   同 t_vawin_tail 的摆法：本款跨度 30 GB（S2A_WIN_NEED_MB），窗口 = 30 + 2 = 32 GB。期望手写：
//   ① 布局报「有远端段」（s2a_window_snap_late(0)）后收到 28 GB：窗口大小 = 28 GB；② 尾部 4 GB 里越过尾部分配那 2 GB 的一段（基址 + 30 GB 起）仍被本进程占着——
//   带提示 mmap 到那里拿不到那个地址（旧实现把这段还给系统）；③ 尾部分配没接管（只有没有远端段时才接管）。
//   反证：去掉 s2a_window_trim 里「有远端段」那支 → ② 红（尾部还给了系统，提示映射正好落在尾部起点）、③ 红
#include "../src/native.h"
#include <string.h>
#include <sys/mman.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "30720", 1); setenv("S2A_IPHONE_VA", "0", 1); }   // 先于 vawin.c 的构造函数（101）
int main(void) {
    int bad = 0; uint64_t b, n; s2a_window_get(&b, &n);
    if (!s2a_window_ok() || n != (32ull << 30)) { printf("✗ 窗口应占 32 GB，得 ok=%d %llu MB\n", s2a_window_ok(), (unsigned long long)(n >> 20)); return 1; }
    s2a_window_snap_late(0);   // 布局：这一款有远端段
    s2a_window_trim(28ull << 30);
    s2a_window_get(&b, &n);
    if (n != (28ull << 30)) { printf("✗ ① 窗口应收到 28 GB，得 %llu MB\n", (unsigned long long)(n >> 20)); bad++; }
    void *m = mmap((void *)(b + (30ull << 30)), 1u << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == (void *)(b + (30ull << 30))) { printf("✗ ② 尾部应仍被占着，带提示 mmap 却拿到了基址 + 30 GB %p\n", m); bad++; }
    if (m != MAP_FAILED) munmap(m, 1u << 20);
    char note[900]; s2a_tail_note(note, sizeof note);
    if (strstr(note, "接管 2048 MB")) { printf("✗ ③ 有远端段时尾部分配不该接管：%s\n", note); bad++; }
    printf("%s t_vawin_trimfar：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
