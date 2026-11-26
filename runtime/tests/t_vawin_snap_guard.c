// t_vawin_snap_guard：快照原址护栏（vawin.c snap_guard_take / snap_guard_drop）。背景：恢复是玩家在游戏库里点的，构造期窗口按本局布局占；
//   本局学到跨度后宿主保留段变大、窗口起点上移，快照那局的窗口起点落进本局宿主段，.NET GC 在库界面起来时就保留进去，起宿主前按原址重占占不到（0.6.9 候选，
//   0.6.8 存的快照：快照窗口 0x7180000000 +23856 MB，本局窗口 0x7480000000 +11568 MB、宿主 18432 MB）。期望按布局手算：
//   本机构造期窗口 0x7180000000 +59392 MB（S2A_WIN_NEED_MB=81920，同 t_vawin_need：空洞 0x7000000000–2^39、宿主留 6 GiB）；
//   快照那局：窗口 0x70c0000000 +62464 MB（宿主只留 3 GiB，窗口末同为 2^39）、命令记录区 0x7000000000 +3072 MB（宿主段底部）
//   → 两块都有部分不在本局窗口里，合并后护栏 = [0x7000000000, 0x7180000000) 共 6144 MB
//   模式 A（恢复）：构造后护栏两端都占着；模拟 GC 往护栏里保留落不进去；恢复局起宿主前 → 窗口 = 快照窗口、命令记录区 = 快照值
//   模式 B（有快照、普通局）：构造后护栏占着；起宿主前 → 护栏放掉（还给宿主），窗口不动
//     GC 上限在 main 开头按护栏占着时的低区选（D-6QWZ：只量到 1447 MB、落「不设」），放掉护栏后要重选一次
//   模式 C（反证：没有快照 = 改前行为）：构造后 0x70c0000000 空着，模拟 GC 落进去；恢复 → 原址占不到，窗口退回 0x7180000000
#include "../src/native.h"
#include <sys/mman.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "81920", 1); setenv("S2A_IPHONE_VA", "0", 1); }   // 先于 vawin.c 的构造函数（101）
int s2a_window_reserve_late(void);
void s2a_snap_arena_get(uint64_t *base, uint64_t *used, uint64_t *vused);
uint64_t s2a_snap_arena_len(void);
#define MB (1ull << 20)
#define GB (1ull << 30)
static const uint64_t SWB = 0x70c0000000ull, SWS = 62464 * MB, SCB = 0x7000000000ull, SCL = 3 * GB;
static int g_restoring;
static char mode(void) { const char *m = getenv("T_SG_MODE"); return m && *m ? *m : 'A'; }
int s2a_snap_restoring(void) { return g_restoring; }
int s2a_snap_manifest_win(uint64_t *b, uint64_t *s) { *b = SWB; *s = SWS; return 0; }
int s2a_snap_manifest_u64(const char *k, uint64_t *a, uint64_t *b) { (void)k; *a = SCB; *b = SCL; return 0; }
int s2a_snap_layout_of(const char *gid, uint64_t *wb, uint64_t *ws, uint64_t *cb, uint64_t *cl) {
    (void)gid; *wb = *ws = *cb = *cl = 0; if (mode() == 'C') return -1;
    *wb = SWB; *ws = SWS; *cb = SCB; *cl = SCL; return 0; }
static int bad;
static int g_reapply;   // GC 上限重选（gclimit.c s2a_gc_limit_reapply，vawin.c 按名 dlsym 取）的调用次数
__attribute__((used, visibility("default"))) void s2a_gc_limit_reapply(void) { g_reapply++; }
static void eq(uint64_t got, uint64_t want, const char *what) { printf("%s [%c] %s：%#llx（期望 %#llx）\n", got == want ? "✓" : "✗", mode(), what, (unsigned long long)got, (unsigned long long)want); if (got != want) bad++; }
static int taken(uint64_t a) { void *p = mmap((void *)a, 16384, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); int t = p != (void *)a; if (p != MAP_FAILED) munmap(p, 16384); return t; }
int main(void) {
    char m = mode(); uint64_t wb, ws, cb, cu, cv;
    s2a_window_get(&wb, &ws); eq(wb, 0x7180000000ull, "构造期窗口基址"); eq(ws, 59392 * MB, "构造期窗口长度");
    eq((uint64_t)taken(SCB), m != 'C', "护栏底（快照命令记录区起点）"); eq((uint64_t)taken(0x7180000000ull - 16384), m != 'C', "护栏顶（本局窗口下面一页）");
    void *gc = mmap((void *)SWB, 2 * GB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);   // 模拟 GC 在库界面起来时往宿主段里保留
    eq((uint64_t)(gc == (void *)SWB), m == 'C', "模拟 GC 落进快照窗口原址");
    if (gc != (void *)SWB && gc != MAP_FAILED) { munmap(gc, 2 * GB); gc = NULL; }
    if (m != 'B') { g_restoring = 1; s2a_window_reserve_late(); s2a_window_get(&wb, &ws); s2a_snap_arena_get(&cb, &cu, &cv);
        if (m == 'A') { eq(wb, SWB, "恢复：窗口基址 = 快照"); eq(ws, SWS, "恢复：窗口长度 = 快照"); eq(cb, SCB, "恢复：命令记录区 = 快照"); eq(s2a_snap_arena_len(), SCL, "恢复：命令记录区 + 虚拟池区长"); }
        else { eq(wb, 0x7180000000ull, "反证：原址占不到，窗口退回"); eq(ws, 59392 * MB, "反证：窗口长度退回"); } }
    else { int r0 = g_reapply; s2a_window_reserve_late(); s2a_window_get(&wb, &ws);
        eq((uint64_t)(g_reapply - r0), 1, "普通局：放掉护栏后 GC 上限按现在的低区重选一次（构造期是护栏占着时选的）");
        eq(wb, 0x7180000000ull, "普通局：窗口不动"); eq(ws, 59392 * MB, "普通局：窗口长度不动");
        eq((uint64_t)taken(SCB), 0, "普通局：护栏底已放"); eq((uint64_t)taken(0x7180000000ull - 16384), 0, "普通局：护栏顶已放"); }
    printf("%s t_vawin_snap_guard [%c]：%d 处不符\n", bad ? "✗" : "✓", m, bad); return bad != 0;
}
