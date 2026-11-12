// 放不下标准布局时窗口下方留给宿主多少（vawin.c s2a_window_host_below，#783）与学到的跨度记录（s2a_window_span_seen）。
// 背景：iPad Pro M2 iPadOS 27.2.1，2^39 以下最大一块 64 GB 放不下这款 76 GB 标准布局，原先固定只给宿主 3 GiB，宿主低区开局 3.4 GB，
//   命令录制等宿主映射涨满后 mmap ENOMEM 闪退；那款整局只碰到 16395 MB 的跨度。
// 期望按规则手写（窗口 = 学到的跨度 × 1.25 + 2 GiB、1 GiB 向上取整；宿主 = 空洞 − 窗口、1 GiB 向下取整，至少 3 GiB；没学到 = 3 GiB）：
//   ① 没学到：3 GiB    ② 学到 16395 MB、空洞 64 GiB：窗口 ⌈22541.75 MB⌉ = 23 GiB → 宿主 41 GiB，且宿主 + 学到的跨度 ≤ 空洞
//   ③ 学到的比空洞还大：3 GiB    ④ 学到 100 MB：窗口 ⌈2173 MB⌉ = 3 GiB → 宿主 61 GiB    ⑤ 记录文件：有 → 读出、没有 / 读不出 → 0
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_VAWIN_NORESERVE", "1", 1); }   // 先于 vawin.c 的构造函数（101）：不占窗口
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
#define MB (1ull << 20)
#define GB (1ull << 30)
int main(void) {
    CHECK(s2a_window_host_below(64 * GB, 0) == 3 * GB, "① 没学到跨度：宿主照旧 3 GiB");
    uint64_t h = s2a_window_host_below(64 * GB, 16395 * MB);
    CHECK(h == 41 * GB && h + 16395 * MB <= 64 * GB, "② 学到 16395 MB、空洞 64 GiB：宿主 41 GiB（实得 %llu MB），宿主 + 跨度不超空洞", (unsigned long long)(h / MB));
    CHECK(s2a_window_host_below(64 * GB, 70 * GB) == 3 * GB, "③ 学到的跨度比空洞还大：宿主至少 3 GiB");
    CHECK(s2a_window_host_below(64 * GB, 100 * MB) == 61 * GB, "④ 学到 100 MB：窗口 3 GiB、宿主 61 GiB");
    char p[] = "/tmp/s2a_span_peak_XXXXXX"; int fd = mkstemp(p); dprintf(fd, "17191403520\n"); close(fd);
    setenv("S2A_WIN_SPAN_PEAK", p, 1);
    CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == 17191403520ull, "⑤ 记录文件有值：读出 17191403520");
    FILE *f = fopen(p, "w"); fputs("坏\n", f); fclose(f);
    CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == 0, "⑤ 记录读不出：0（照旧 3 GiB）");
    unlink(p);
    CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == 0, "⑤ 没有记录：0");
    printf("%s t_vawin_learned：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
