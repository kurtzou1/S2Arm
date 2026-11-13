// 上一局是否异常退出（会话标记）+ 有界的会话日志摘要（runtime/src/sesdiag.c）
#ifndef S2A_SESDIAG_H
#define S2A_SESDIAG_H
#include <stddef.h>
enum { S2A_SESMARK_NONE = 0, S2A_SESMARK_FG = 1, S2A_SESMARK_BG = 2 };
enum { S2A_SUM_END_UNKNOWN = 0, S2A_SUM_END_EXIT = 1, S2A_SUM_END_CRASH = 2 };
#define S2A_SUM_HEAD (1u << 20)   // 头 1 MB：标记行
#define S2A_SUM_TAIL (3u << 20)   // 尾 3 MB：心跳 / 收尾 / 崩溃行
// docs = App 的 Documents 目录。prev 返回上一局留下的状态（NONE = 正常收尾或没有）
int s2a_sesmark_prev(const char *docs);
void s2a_sesmark_set(const char *docs, int state);
void s2a_sesmark_clear_home(void);
typedef struct {
    long long frames, thermal, peak_mb;   // -1 = 没见到
    int mark, end, last_state, truncated;  // last_state：S2A_SESMARK_FG / BG / 3 = 前台失焦，0 = 没有心跳
    size_t bytes;   // 日志文件大小
    size_t read;    // 实际读进来的字节数（头段 + 尾段；单测按它核「有界」，与负载无关）
} s2a_log_sum;
int s2a_log_summary(const char *path, size_t head_cap, size_t tail_cap, s2a_log_sum *o);
#endif
