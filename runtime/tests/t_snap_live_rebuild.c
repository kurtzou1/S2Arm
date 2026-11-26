// 即时存档「恢复局接着记」：服务层重建请求表（SnapLog.cs RebuildTable）在重放收尾里就要问「第 N 条建的句柄还活着吗」、收掉的请求要连句柄日志一起删，
//   这时原生层必须已经接上快照里的句柄日志。原先接日志在之后（snapshot.c snap_live_after_restore），问的是空日志：
//   一律答「没活着的」，已关会话上建过活句柄的请求被收掉；删的也没删在要接的日志里、之后整份照抄回来。再存一次再恢复，那个句柄格就空着。
// 场景取自一款生活模拟游戏的快照（程序号 01006F8002326000）：格 98 代 139 是第 168 条建的会话、后来关了；格 98 代 193 是第 194 条（取字体共享内存）建的共享内存，
//   一直活着，它所在的字体服务会话第 195 条关了。期望（按这份日志手算）：
//   接日志前后问第 194 条都答「活着」；第 168 条答「没活着」，收掉后它的建 / 关两条从要接的日志里删掉，接完日志只剩第 194 条建的那一项（0x608062）
#define main base_thread_suite_main
#include "t_thread.c"
#undef main
typedef struct { uint8_t op, cs; uint16_t pin; uint32_t h, kind; int32_t ctx, after; uint64_t a, b; uint32_t c, uid; } lr_rec;
int s2a_snap_hlog_load(FILE *f); int s2a_snap_hlog_save(FILE *f); void s2a_snap_hlog_continue(void);
int s2a_snap_seq_live(int seq); void s2a_snap_hlog_forget(int seq);
static int bad_lr;
#define CK(c, ...) do { if (c) printf("通 " __VA_ARGS__); else { printf("不通 " __VA_ARGS__); bad_lr = 1; } printf("\n"); } while (0)
static int saved(lr_rec *out, int cap) {   // 此刻要存的句柄日志：项数，前 cap 项拷进 out
    char buf[4096] = {0}; FILE *f = fmemopen(buf, sizeof buf, "wb"); if (!f) return -1;
    s2a_snap_hlog_save(f); fclose(f);
    int n; memcpy(&n, buf, 4); for (int i = 0; i < n && i < cap; i++) memcpy(&out[i], buf + 4 + sizeof *out * (size_t)i, sizeof *out);
    return n;
}
int main(void) {
    enum { SESSION = 4, SHMEM = 5 };
    lr_rec r[] = {
        {0, 1, 0, 139u << 15 | 98, SESSION, 168, 167, 0, 0, 0, 301},
        {1, 1, 0, 139u << 15 | 98, SESSION, 0, 170, 0, 0, 0, 0},
        {0, 1, 0, 193u << 15 | 98, SHMEM, 194, 193, 0, 0, 0, 302},
    };
    int n = (int)(sizeof r / sizeof r[0]); char buf[4096]; size_t len = 0;
    memcpy(buf, &n, 4); len = 4; memcpy(buf + len, r, sizeof r); len += sizeof r;
    FILE *f = fmemopen(buf, len, "rb"); CK(f && !s2a_snap_hlog_load(f), "快照句柄日志读得进（%d 项）", n); if (f) fclose(f);
    // 重放收尾里服务层重建请求表（此时游戏线程还没放开、还没调 s2a_snap_hlog_continue）
    CK(s2a_snap_seq_live(194) == 1, "重建请求表时问第 194 条（建格 98 代 193 的共享内存）：活着（期望 1）");
    CK(s2a_snap_seq_live(168) == 0, "第 168 条建的会话后来关了：没活着（期望 0）");
    s2a_snap_hlog_forget(168);   // 第 168 条随它的对象收掉
    s2a_snap_hlog_continue();    // snap_live_after_restore：接着记
    lr_rec o[4]; int m = saved(o, 4);
    CK(m == 1 && o[0].op == 0 && o[0].h == (193u << 15 | 98) && o[0].ctx == 194,
       "接完日志后要存的句柄日志：%d 项（期望 1 项：第 194 条建 0x608062），首项 建/关 %d 值 %#x 请求 %d", m, m > 0 ? o[0].op : -1, m > 0 ? o[0].h : 0, m > 0 ? o[0].ctx : -1);
    CK(s2a_snap_seq_live(194) == 1, "接完日志后第 194 条仍活着");
    printf(bad_lr ? "✗ t_snap_live_rebuild：有不通\n" : "✓ t_snap_live_rebuild：全部通过\n");
    return bad_lr;
}
