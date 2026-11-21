// 即时存档命令记录区放哪（layout.c s2a_snap_arena_place，vawin.c 占窗口时用）：命令记录区 1 GB + 虚拟池区 2 GB = 3 GB，宿主至少留 3 GB（HOST_BELOW）。期望按规则手写：
//   ① #1867 那台 iPhone（iOS 27.3）：窗口外 [4 GB, 空洞起点) 最大 0 MB，宿主保留段 21504 MB → 2（放宿主段底部，宿主还剩 18432 MB）——修前关快照
//   ② 窗口外有整块 3072 MB → 1（窗口外优先，宿主段不动）③ 宿主段只有 3072 MB（固定档）→ 0（关快照：切了 Metal 没处放）
//   ④ 宿主段正好 6144 MB → 2；少 1 MB → 0
#include <stdint.h>
#include <stdio.h>
int s2a_snap_arena_place(uint64_t out, uint64_t below, uint64_t a, uint64_t host_min);
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
    printf("%s t_vawin_snaparena：%d 处不符（共 5 项）\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
