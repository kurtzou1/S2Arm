// t_vawin_ios26：S2A_VA_IOS26=1（进程启动前给：护栏库在 libSystem 初始化时就读）模拟 iOS 26 大地址档。期望（手算）：空洞 [0x3_0000_0000, 0xF_C000_0000)，下方 1 GiB 留宿主 →
//   窗口 0x3_4000_0000 起 0xF_C000_0000 − 0x3_4000_0000 = 0xC_8000_0000（50 GiB；macOS 27 退到 0x70_4000_0000 起同样大小）；空洞之上不能再给别人映射
#include "../src/native.h"
#include <sys/mman.h>
__attribute__((constructor(100))) static void env(void) { setenv("S2A_WIN_NEED_MB", "68110", 1); setenv("S2A_IPHONE_VA", "0", 1); }
int main(void) {
    int bad = 0; uint64_t wb, ws; s2a_window_get(&wb, &ws);
    // macOS 26：同 iOS 26 位置，窗口 0x3_4000_0000 起；macOS 27（gate-host / Spare-host）低区被共享缓存占满，退到 0x70 空洞开头：窗口 0x70_4000_0000 起。大小都是 50 GiB
    if (!s2a_window_ok() || (wb != 0x480000000ull && wb != 0x7180000000ull) || ws != 0xB40000000ull) { printf("✗ 窗口 %#llx +%#llx（应 0x480000000 或 0x7180000000，+0xB40000000：空洞 51 GB 下方留 6 GB 宿主）\n", (unsigned long long)wb, (unsigned long long)ws); bad++; }
    uint64_t above = wb + ws;   // 模拟的地址上限（空洞顶）之上要已被占死：带提示也落不进去
    void *p = mmap((void *)above, 1 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == (void *)above) { printf("✗ 空洞上方 %#llx 还能映射\n", (unsigned long long)above); bad++; }
    printf("%s t_vawin_ios26：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
