// t_vawin_widen：窗口按学到的跨度收窄后布局放不下，同一次启动里当场放宽（vawin.c s2a_window_span_widen，v0.3.4）。
// 用 S2A_VA_IOS26=1 模拟 iOS 26 大地址档（空洞 51 GiB，放不下 68110 MB 标准布局），学到的跨度 1 GiB。期望（手算）：
//   收窄窗口 = ⌈1 × 1.25 + 2⌉ = 4 GiB，宿主 47 GiB → 窗口在空洞底 + 47 GiB、+4 GiB；
//   放宽后 = 空洞底 + 3 GiB 起、窗口顶不变 → 48 GiB（同没学到时的缺省窗口，t_vawin_ios26）；记录文件已删；放宽的那段别人映射不进去；再调一次回 0
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
#define GB (1ull << 30)
static char g_rec[] = "/tmp/s2a_span_widen_XXXXXX";
__attribute__((constructor(100))) static void env(void) {
    int fd = mkstemp(g_rec); dprintf(fd, "%llu\n", (unsigned long long)GB); close(fd);
    setenv("S2A_WIN_NEED_MB", "68110", 1); setenv("S2A_IPHONE_VA", "0", 1); setenv("S2A_WIN_SPAN_PEAK", g_rec, 1);
}
int s2a_window_span_widen(void);
int main(void) {
    int bad = 0; uint64_t wb, ws; s2a_window_get(&wb, &ws);
#define CHECK(c, ...) do { if (c) printf("✓ "); else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
    uint64_t hole = wb == 0x300000000ull + 47 * GB ? 0x300000000ull : 0x7000000000ull;   // macOS 27 退到 0x70 空洞开头（同 t_vawin_ios26）
    CHECK(s2a_window_ok() && wb == hole + 47 * GB && ws == 4 * GB, "收窄窗口 %#llx +%llu GiB（应 空洞底 + 47 GiB、+4 GiB）", (unsigned long long)wb, (unsigned long long)(ws / GB));
    uint64_t top = wb + ws;
    CHECK(s2a_window_span_widen() == 1, "当场放宽返回 1");
    s2a_window_get(&wb, &ws);
    CHECK(wb == hole + 3 * GB && wb + ws == top && ws == 48 * GB, "放宽后 %#llx +%llu GiB（应 空洞底 + 3 GiB、48 GiB，顶不变）", (unsigned long long)wb, (unsigned long long)(ws / GB));
    CHECK(access(g_rec, F_OK) != 0, "坏记录已删");
    void *p = mmap((void *)(wb + GB), 1 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK(p != (void *)(wb + GB), "放宽的那段已占住，别人映射不进去");
    if (p != MAP_FAILED && p != (void *)(wb + GB)) munmap(p, 1 << 20);
    CHECK(s2a_window_span_widen() == 0, "再调一次回 0（已不是学到的跨度）");
    unlink(g_rec);
    printf("%s t_vawin_widen：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
