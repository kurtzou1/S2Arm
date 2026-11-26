// 即时存档恢复：句柄日志里「后来关了」的关闭，记在已不在请求日志里的那条请求之后（那条请求随对象关闭从日志收掉了），
//   重放到下一条之前也要关掉；否则 A 里同格复用的下一个句柄按原号强制分配时格还被旧句柄占着，改按常规分配抢走游戏句柄的格，恢复失败重开局。
// 场景取自真机快照（程序号 0400486024DEC000，句柄日志第 215–222 项）：第 340 条请求建一对事件（读 / 写），服务在第 343 条里自己关掉它们（343 已收掉、不重放），
//   第 344 条在同两格建新的一对。期望（按 A 的句柄日志手算）：重放第 344 条建出的事件句柄 = A 的值 0x7f8052 / 0x8000cf；
//   服务之后再关已被恢复替它关掉的旧句柄 → 当已关（返回 1），不报红
#define main base_thread_suite_main
#include "t_thread.c"
#undef main
typedef struct { uint8_t op, cs; uint16_t pin; uint32_t h, kind; int32_t ctx, after; uint64_t a, b; uint32_t c, uid; } hc_rec;
int s2a_snap_hlog_load(FILE *f); int s2a_snap_replay_prelude(void); int s2a_snap_replay_begin(int seq); int s2a_snap_replay_end(int seq); int s2a_snap_defer_finish(void);
uint64_t s2a_event_create(uint32_t *h_read, uint32_t *h_write); int s2a_handle_close(uint32_t h);
static int bad_hc;
#define CK(c, ...) do { if (c) printf("通 " __VA_ARGS__); else { printf("不通 " __VA_ARGS__); bad_hc = 1; } printf("\n"); } while (0)
int main(void) {
    enum { EVR = 2, EVW = 3 };
    hc_rec r[] = {
        {0, 1, 0, 0x7d8052, EVR, 340, 339, 0, 0, 0, 251}, {0, 1, 0, 0x7e00cf, EVW, 340, 339, 0, 0, 0, 252},
        {1, 1, 0, 0x7d8052, EVR, 0, 343, 0, 0, 0, 0},     {1, 1, 0, 0x7e00cf, EVW, 0, 343, 0, 0, 0, 0},
        {0, 1, 0, 0x7f8052, EVR, 344, 343, 0, 0, 0, 255}, {0, 1, 0, 0x8000cf, EVW, 344, 343, 0, 0, 0, 256},
    };
    int n = (int)(sizeof r / sizeof r[0]); char buf[4096]; size_t len = 0;
    memcpy(buf, &n, 4); len = 4; memcpy(buf + len, r, sizeof r); len += sizeof r;
    FILE *f = fmemopen(buf, len, "rb"); CK(f && !s2a_snap_hlog_load(f), "句柄日志读得进（%d 项）", n); if (f) fclose(f);
    s2a_snap_replay_prelude();
    uint32_t hr = 0, hw = 0;
    s2a_snap_replay_begin(340); s2a_event_create(&hr, &hw); s2a_snap_replay_end(340);
    CK(hr == 0x7d8052 && hw == 0x7e00cf, "第 340 条按 A 的值建出事件：读 %#x 写 %#x（期望 0x7d8052 / 0x7e00cf）", hr, hw);
    uint32_t hr2 = 0, hw2 = 0;   // 第 343 条不在请求日志里（随对象关闭收掉），直接到 344
    s2a_snap_replay_begin(344); s2a_event_create(&hr2, &hw2); int left = s2a_snap_replay_end(344);
    CK(hr2 == 0x7f8052 && hw2 == 0x8000cf && left == 0, "第 344 条在同两格按 A 的值建出：读 %#x 写 %#x（期望 0x7f8052 / 0x8000cf），没按值建出的 %d", hr2, hw2, left);
    s2a_snap_defer_finish();
    CK(s2a_handle_close(0x7d8052) == 1 && s2a_handle_close(0x7e00cf) == 1, "服务之后再关恢复已替它关掉的旧句柄：当已关、返回 1");
    CK(s2a_handle_close(0x7d8052) == 0, "同一个旧句柄第二次关：照旧报不存在（只替一次）");
    printf(bad_hc ? "✗ t_snap_hclose：有不通\n" : "✓ t_snap_hclose：全部通过\n");
    return bad_hc;
}
