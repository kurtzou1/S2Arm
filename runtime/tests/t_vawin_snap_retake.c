// t_vawin_snap_retake：即时存档恢复局起宿主前按快照清单原址重占窗口与命令记录区（vawin.c snap_retake，s2a_window_reserve_late 末尾调）。
//   背景：游戏库里点「回到这一刻」在构造期之后，窗口按普通局占；两局之间学到 / 没学到跨度、空洞大小不同，落点就变，清单「窗口」不符拒绝
//   （0.6.7 玩家诊断：快照恢复 17 局被拒 9 局，全是窗口不符——4 局起点变、5 局起点不变大小变）。期望按规则手写：
//   ① 纯函数 s2a_snap_retake_plan：同址同长 0；窗口基址或长度不同 1；命令记录区不同 2；两样都不同 3；清单没记的那样不算
//   ② 起点不变、大小变：构造期按普通局占 0x7180000000 +59392 MB（S2A_WIN_NEED_MB=81920，同 t_vawin_need，宿主留 6 GiB）；
//      清单窗口 0x7180000000 +23856 MB、命令记录区 0x7f00000000 +3072 MB（落在旧窗口里）→ 重占后窗口、命令记录区都是清单值，旧窗口多出的段已放掉
//   ②b 起点变、大小不变：清单窗口 0x7200000000 +23856 MB → 重占到清单值
//   ③ 再调一次：已同址，不动
//   ④ 清单窗口 0x7180000000 +59392 MB，但 0x7fe0000000 被别人占了 → 占不到，窗口退回 0x7200000000 +23856 MB 且仍占着（hint 映射落不到那里）
//   ⑤ 窗口里放开过一页（读写）→ 不重占，窗口不动
#include "../src/native.h"
#include <sys/mman.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "81920", 1); setenv("S2A_IPHONE_VA", "0", 1); }   // 先于 vawin.c 的构造函数（101）
int s2a_snap_retake_plan(uint64_t wb, uint64_t ws, uint64_t cb, uint64_t cl, uint64_t mwb, uint64_t mws, uint64_t mcb, uint64_t mcl);
int s2a_window_reserve_late(void);
void s2a_snap_arena_get(uint64_t *base, uint64_t *used, uint64_t *vused);
uint64_t s2a_snap_arena_len(void);
static int g_restoring; static uint64_t g_mwb, g_mws, g_mcb, g_mcl;
int s2a_snap_restoring(void) { return g_restoring; }
int s2a_snap_manifest_win(uint64_t *b, uint64_t *s) { if (!g_mwb) return -1; *b = g_mwb; *s = g_mws; return 0; }
int s2a_snap_manifest_u64(const char *k, uint64_t *a, uint64_t *b) { (void)k; if (!g_mcb) return -1; *a = g_mcb; *b = g_mcl; return 0; }
#define MB (1ull << 20)
#define GB (1ull << 30)
static int bad;
static void eq(uint64_t got, uint64_t want, const char *what) { printf("%s %s：%#llx（期望 %#llx）\n", got == want ? "✓" : "✗", what, (unsigned long long)got, (unsigned long long)want); if (got != want) bad++; }
static int taken(uint64_t a) { void *p = mmap((void *)a, 16384, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); int t = p != (void *)a; if (p != MAP_FAILED) munmap(p, 16384); return t; }
int main(void) {
    eq(s2a_snap_retake_plan(1, 2, 3, 4 * GB, 1, 2, 3, 4 * GB), 0, "① 同址同长");
    eq(s2a_snap_retake_plan(1, 2, 3, 4 * GB, 5, 2, 3, 4 * GB), 1, "① 窗口基址不同");
    eq(s2a_snap_retake_plan(1, 2, 3, 4 * GB, 1, 6, 3, 4 * GB), 1, "① 窗口长度不同");
    eq(s2a_snap_retake_plan(1, 2, 3, 4 * GB, 1, 2, 7, 4 * GB), 2, "① 命令记录区不同");
    eq(s2a_snap_retake_plan(1, 2, 0, 0, 5, 2, 7, 3 * GB), 3, "① 两样都不同（当前没有命令记录区）");
    eq(s2a_snap_retake_plan(1, 2, 3, 4 * GB, 0, 0, 0, 0), 0, "① 清单没记");
    uint64_t wb, ws, cb, cu, cv;
    s2a_window_get(&wb, &ws); eq(wb, 0x7180000000ull, "② 构造期窗口基址"); eq(ws, 59392 * MB, "② 构造期窗口长度");
    g_restoring = 1; g_mwb = 0x7180000000ull; g_mws = 23856 * MB; g_mcb = 0x7f00000000ull; g_mcl = 3 * GB;
    eq((uint64_t)s2a_window_reserve_late(), 1, "② 起宿主前补占返回");
    s2a_window_get(&wb, &ws); eq(wb, g_mwb, "② 重占后窗口基址"); eq(ws, g_mws, "② 重占后窗口长度");
    s2a_snap_arena_get(&cb, &cu, &cv); eq(cb, g_mcb, "② 重占后命令记录区"); eq(s2a_snap_arena_len(), g_mcl, "② 命令记录区 + 虚拟池区长");
    eq((uint64_t)taken(g_mwb), 1, "② 窗口底确实占着"); eq((uint64_t)taken(g_mcb + 2 * GB), 1, "② 虚拟池区确实占着"); eq((uint64_t)taken(0x7f80000000ull - 4 * GB), 0, "② 旧窗口不再占着的段已放掉");
    g_mwb = 0x7200000000ull; s2a_window_reserve_late(); s2a_window_get(&wb, &ws); eq(wb, g_mwb, "②b 起点变：重占后窗口基址"); eq(ws, g_mws, "②b 起点变：长度不变");
    eq((uint64_t)taken(0x7200000000ull), 1, "②b 新起点占着"); eq((uint64_t)taken(0x7180000000ull), 0, "②b 旧起点已放掉");
    s2a_window_reserve_late(); s2a_window_get(&wb, &ws); eq(wb, g_mwb, "③ 再调一次窗口不动");
    void *foe = mmap((void *)0x7fe0000000ull, 16384, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); eq((uint64_t)(uintptr_t)foe, 0x7fe0000000ull, "④ 别人占住 0x7fe0000000");
    g_mwb = 0x7180000000ull; g_mws = 59392 * MB; s2a_window_reserve_late();
    s2a_window_get(&wb, &ws); eq(wb, 0x7200000000ull, "④ 占不到：窗口退回基址"); eq(ws, 23856 * MB, "④ 占不到：窗口退回长度"); eq((uint64_t)taken(0x7200000000ull), 1, "④ 旧窗口占回了");
    eq(s2a_window_ok(), 1, "④ 窗口仍算占着");
    munmap(foe, 16384);
    mprotect((void *)0x7200000000ull, 16384, PROT_READ | PROT_WRITE);
    s2a_window_reserve_late(); s2a_window_get(&wb, &ws); eq(wb, 0x7200000000ull, "⑤ 放开过一页：不重占");
    printf("%s t_vawin_snap_retake：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
