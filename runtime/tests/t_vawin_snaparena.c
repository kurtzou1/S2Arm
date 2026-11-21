// 即时存档命令记录区放哪（layout.c s2a_snap_arena_place，vawin.c 占窗口时用）：命令记录区 1 GB + 虚拟池区 2 GB = 3 GB，宿主至少留 3 GB（HOST_BELOW）。期望按规则手写：
//   ① #1867 那台 iPhone（iOS 27.3）：窗口外 [4 GB, 空洞起点) 最大 0 MB，宿主保留段 21504 MB → 2（放宿主段底部，宿主还剩 18432 MB）——修前关快照
//   ② 窗口外有整块 3072 MB → 1（窗口外优先，宿主段不动）③ 宿主段只有 3072 MB（固定档）→ 0（关快照：切了 Metal 没处放）
//   ④ 宿主段正好 6144 MB → 2；少 1 MB → 0
//   s2a_snap_arena_place2（11-21，宿主段不够时按本款已知最高跨度让窗口；余量 2048 MB）：空洞 52224 MB（iOS 26 大地址档，诊断 D-M5VP）、宿主段 3072 MB、窗口外 0：
//   ⑤ 跨度不知道 → 2，宿主段加长到 6144 MB ⑥ 已知 12964 MB（种子表那款）→ 2、6144 ⑦ 已知 44032 MB：44032 + 2048 = 46080 ≤ 52224 − 6144 = 46080 → 2
//   ⑪ 选定游戏后收尾还给系统的那段放不放得下 3 GB + 宿主 3 GB（候选装机冒烟那款还 29302 MB）
//   ⑧ 已知 44033 MB → 0、宿主段不动 3072 ⑨ 空洞 6144 MB（≤ 3 + 3 GB）→ 0 ⑩ 宿主段本来就 21504 MB → 2、不动；窗口外有 3072 → 1、不动
#include <stdint.h>
#include <stdio.h>
int s2a_snap_arena_place(uint64_t out, uint64_t below, uint64_t a, uint64_t host_min);
int s2a_snap_late_fits(uint64_t released, uint64_t a, uint64_t host_min);
int s2a_snap_arena_place2(uint64_t out, uint64_t fit, uint64_t *below, uint64_t a, uint64_t host_min, uint64_t span, uint64_t margin);
#define MB (1ull << 20)
static int bad;
static void eq(int got, int want, const char *what) { printf("%s %s：%d（期望 %d）\n", got == want ? "✓" : "✗", what, got, want); if (got != want) bad++; }
int main(void) {
    const uint64_t A = 3072 * MB, H = 3072 * MB;
    eq(s2a_snap_arena_place(0, 21504 * MB, A, H), 2, "① 窗口外 0 MB、宿主段 21504 MB → 宿主段底部");
    eq(s2a_snap_arena_place(3072 * MB, 21504 * MB, A, H), 1, "② 窗口外有 3072 MB → 窗口外");
    eq(s2a_snap_arena_place(1458 * MB, 3072 * MB, A, H), 0, "③ 宿主段只有 3072 MB → 关快照");
    eq(s2a_snap_arena_place(0, 6144 * MB, A, H), 2, "④ 宿主段正好 6144 MB → 宿主段底部");
    eq(s2a_snap_arena_place(0, 6143 * MB, A, H), 0, "④ 宿主段 6143 MB → 关快照");
    { const uint64_t F = 52224 * MB, M = 2048 * MB; uint64_t b;
      b = 3072 * MB; eq(s2a_snap_arena_place2(0, F, &b, A, H, 0, M), 2, "⑤ 跨度不知道 → 宿主段底部"); eq((int)(b / MB), 6144, "⑤ 宿主段加长到（MB）");
      b = 3072 * MB; eq(s2a_snap_arena_place2(0, F, &b, A, H, 12964 * MB, M), 2, "⑥ 已知 12964 MB → 宿主段底部"); eq((int)(b / MB), 6144, "⑥ 宿主段（MB）");
      b = 3072 * MB; eq(s2a_snap_arena_place2(0, F, &b, A, H, 44032 * MB, M), 2, "⑦ 已知 44032 MB（正好放得进）→ 宿主段底部");
      b = 3072 * MB; eq(s2a_snap_arena_place2(0, F, &b, A, H, 44033 * MB, M), 0, "⑧ 已知 44033 MB → 关快照"); eq((int)(b / MB), 3072, "⑧ 宿主段不动（MB）");
      b = 3072 * MB; eq(s2a_snap_arena_place2(0, 6144 * MB, &b, A, H, 0, M), 0, "⑨ 空洞 6144 MB → 关快照");
      b = 21504 * MB; eq(s2a_snap_arena_place2(0, F, &b, A, H, 60000 * MB, M), 2, "⑩ 宿主段本来 21504 MB → 宿主段底部"); eq((int)(b / MB), 21504, "⑩ 宿主段不动（MB）");
      b = 3072 * MB; eq(s2a_snap_arena_place2(3072 * MB, F, &b, A, H, 60000 * MB, M), 1, "⑩ 窗口外有 3072 MB → 窗口外"); eq((int)(b / MB), 3072, "⑩ 窗口外时宿主段不动（MB）"); }
    // ⑪ 选定游戏后补放（s2a_snap_late_fits）：候选装机冒烟那款收尾还给系统 29302 MB → 放得下；正好 6144 MB → 放得下；6143 MB → 放不下
    eq(s2a_snap_late_fits(29302 * MB, A, H), 1, "⑪ 收尾还 29302 MB → 补放"); eq(s2a_snap_late_fits(6144 * MB, A, H), 1, "⑪ 收尾还 6144 MB → 补放"); eq(s2a_snap_late_fits(6143 * MB, A, H), 0, "⑪ 收尾还 6143 MB → 不放");
    printf("%s t_vawin_snaparena：%d 处不符（共 20 项）\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
