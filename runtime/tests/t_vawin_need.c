// t_vawin_need：本款标准布局放不下——S2A_WIN_NEED_MB=81920（80 GB）大于本机 2^39 以下最大的空洞（macOS 上 [0x70, 0x80) 64 GB，手量）。
//   判据（docs/方案_地址空间根修.md）：照样占窗口——那块最大空洞下方 6 GB 留宿主（宿主下限，11-06 由 1 GB 改 3 GB、11-22 改 6 GB），其余 58 GB 作窗口（0x7180000000 起）；s2a_window_need 报跨度 80 GB、最多能放 64 GB
#include "../src/native.h"
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "81920", 1); setenv("S2A_IPHONE_VA", "0", 1); }   // 先于 vawin.c 的构造函数（101）
int main(void) {
    int bad = 0; uint64_t nd, fit, wb, ws; s2a_window_need(&nd, &fit); s2a_window_get(&wb, &ws);
    if (!s2a_window_ok()) { printf("✗ 放不下标准布局也应占到最大一块\n"); bad++; }
    if (wb != 0x7180000000ull || ws != (58ull << 30)) { printf("✗ 窗口 %#llx +%llu MB（应 0x7180000000 +59392）\n", (unsigned long long)wb, (unsigned long long)(ws >> 20)); bad++; }
    if (nd != (80ull << 30) || fit != (64ull << 30)) { printf("✗ 跨度 %llu MB（应 81920）、最多能放 %llu MB（应 65536）\n", (unsigned long long)(nd >> 20), (unsigned long long)(fit >> 20)); bad++; }
    printf("%s t_vawin_need：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
