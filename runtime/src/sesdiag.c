// 上一局是否异常退出 + 会话日志摘要（11-07 Switch2 线 84，维护者令）。
//   测试设备2 金刚 GPU 挂死后重开 App，主线程在 diag.m session_summary 里把上一局整份 host.log（挂死后刷了海量红行）读成 NSString、逐行折叠查找，
//   卡 1.67 s / 6.85 s，叠加 GPU 刚挂死，看门狗把整机复位。根修两处：
//   ① 「上次是不是异常退出」不读日志：会话进行中标记文件 Documents/s2a_session.mark（起局写 fg、进后台写 bg、回前台写 fg、优雅退出删掉）。
//      下次启动见到 fg = 上次死在前台（崩溃 / 卡死被杀 / 内存超限被杀），bg = 在后台被划掉或回收（不算异常），没有 = 正常收尾。读一个几字节的文件，玩家包同样只做这一步。
//   ② 日志摘要（只给导出诊断包，在后台线程）只读头 S2A_SUM_HEAD + 尾 S2A_SUM_TAIL 字节、按字节 memmem 找：心跳 / 收尾 / 崩溃行都在尾部，标记行在头部
#include "native.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#include "s2a_sesdiag.h"
#include "s2a_docs.h"

static int mark_path(const char *docs, char *p, size_t n) { return docs && *docs && snprintf(p, n, "%s/s2a_session.mark", docs) < (int)n; }
int s2a_sesmark_prev(const char *docs) {
    char p[1100]; if (!mark_path(docs, p, sizeof p)) return S2A_SESMARK_NONE;
    int fd = open(p, O_RDONLY); if (fd < 0) return S2A_SESMARK_NONE;
    char b[8] = {0}; ssize_t r = read(fd, b, sizeof b - 1); close(fd);
    return r >= 2 && !memcmp(b, "bg", 2) ? S2A_SESMARK_BG : S2A_SESMARK_FG;   // 读不全按 fg：宁可多问一次
}
// 只解包的起动（S2A_PACK_APPLY_ONLY=1，推完资源包起一次 App 解开就退）不是一局：不写也不删标记，上一局留下的照原样留给下一次正式起局。
//   原先这一次起动照常写 fg（diag.m 挂上 / 回前台），解包线程做完直接 _exit 不删，装机或更新后的第一局都读到「前台未收尾」：凭空问发诊断，并把开着的补丁当崩溃嫌疑关掉
static int apply_only(void) { const char *e = getenv("S2A_PACK_APPLY_ONLY"); return e && *e == '1'; }
void s2a_sesmark_set(const char *docs, int state) {
    char p[1100]; if (apply_only() || !mark_path(docs, p, sizeof p)) return;
    if (state == S2A_SESMARK_NONE) { if (unlink(p) && errno != ENOENT) LOG("【红】会话标记删除失败 errno=%d", errno); return; }
    int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) { LOG("【红】会话标记写入失败 errno=%d", errno); return; }
    ssize_t w = write(fd, state == S2A_SESMARK_BG ? "bg\n" : "fg\n", 3); (void)w; close(fd);
}
// 优雅退出时删标记（lifecycle.c 收局最后调）。只在 iOS：Mac 的 HOME/Documents 是开发者的文稿目录，不往里写
void s2a_sesmark_clear_home(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    char d[1030]; int r = s2a_container_docs(d, sizeof d); if (r <= 0 || (size_t)r >= sizeof d) return;
    s2a_sesmark_set(d, S2A_SESMARK_NONE);   // 进程级容器 Documents（s2a_docs.h），与 diag.m 写标记的位置一致
#endif
}

static long long num_after(const char *p, const char *end) {   // 跳过空白后的十进制整数；没有返回 -1
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end || *p < '0' || *p > '9') return -1;
    long long v = 0; while (p < end && *p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    return v;
}
static const char *find(const char *h, const char *end, const char *needle) { size_t n = strlen(needle); return end - h >= (ptrdiff_t)n ? memmem(h, (size_t)(end - h), needle, n) : NULL; }
static void scan(const char *b, size_t n, s2a_log_sum *o) {
    const char *end = b + n;
    for (const char *ln = b; ln < end;) {
        const char *nl = memchr(ln, '\n', (size_t)(end - ln)); const char *le = nl ? nl : end;
        const char *r;
        if ((r = find(ln, le, "[心跳] 帧 "))) {
            o->frames = num_after(r + strlen("[心跳] 帧 "), le);
            const char *m = find(ln, le, "进程实占 "); long long pk = m ? num_after(m + strlen("进程实占 "), le) : -1; if (pk > o->peak_mb) o->peak_mb = pk;
            o->last_state = find(ln, le, "，后台，") ? S2A_SESMARK_BG : find(ln, le, "，前台失焦，") ? 3 : S2A_SESMARK_FG;
        }
        if ((r = find(ln, le, "热状态变为 "))) { long long t = num_after(r + strlen("热状态变为 "), le); if (t > o->thermal) o->thermal = t; }
        else if ((r = find(ln, le, "热状态 "))) { long long t = num_after(r + strlen("热状态 "), le); if (t > o->thermal) o->thermal = t; }
        if (!o->mark && find(ln, le, "S2A 标记 MARK")) o->mark = 1;
        if (find(ln, le, "优雅退出完成")) o->end = S2A_SUM_END_EXIT;
        else if (o->end != S2A_SUM_END_EXIT && find(ln, le, "【红】CRASH")) o->end = S2A_SUM_END_CRASH;
        ln = nl ? nl + 1 : end;
    }
}
int s2a_log_summary(const char *path, size_t head_cap, size_t tail_cap, s2a_log_sum *o) {
    memset(o, 0, sizeof *o); o->frames = o->thermal = o->peak_mb = -1;
    int fd = open(path, O_RDONLY); if (fd < 0) return -1;
    struct stat st; if (fstat(fd, &st)) { close(fd); return -1; }
    size_t sz = (size_t)st.st_size; o->bytes = sz;
    size_t head = sz <= head_cap + tail_cap ? sz : head_cap, tail = sz <= head_cap + tail_cap ? 0 : tail_cap;
    char *b = malloc((head > tail ? head : tail) + 1); if (!b) { close(fd); return -1; }
    ssize_t r = head ? pread(fd, b, head, 0) : 0;
    if (r > 0) { o->read += (size_t)r; scan(b, (size_t)r, o); }
    if (tail) {
        r = pread(fd, b, tail, (off_t)(sz - tail));
        if (r > 0) o->read += (size_t)r;
        if (r > 0) { const char *s = memchr(b, '\n', (size_t)r); if (s) scan(s + 1, (size_t)(b + r - (s + 1)), o); }   // 尾段第一行多半被截断：从第一个换行后起
        o->truncated = 1;
    }
    free(b); close(fd);
    return 0;
}
