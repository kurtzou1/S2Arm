// 上一局是否异常退出 + 有界日志摘要（runtime/src/sesdiag.c；11-07 测试设备2：重开 App 主线程整份读上一局 host.log 卡 1.67 s / 6.85 s，看门狗复位整机）。
//   期望值手写：① 会话标记读写往返（无 / fg / bg / 删）；判定「上次是否异常」只读标记，和日志多大无关：放一份 200 MB 的假上一局日志，判定结论在日志不可读时照旧（= 不读日志；原判据「< 1 ms」随负载变，11-10 改）。
//   ② 摘要只读头 1 MB + 尾 3 MB：200 MB 假日志里，头部的标记行、尾部最后一次心跳的帧号 / 实占 / 热状态 / 收尾行都取到；读的字节数恰为 4 MB（原判据「< 100 ms」随负载变，11-10 改）。
//   负对照：同一个函数把头尾上限放到整份（旧做法 = 整份读），读的字节数 = 200 MB（并打用时作参考）
#include "../src/native.h"
#include "s2a_sesdiag.h"
#include "s2a_t_result.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int bad;
#define CHECK(c, ...) do { int ok_ = !!(c); if (!ok_) bad++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static double ms_since(struct timespec a) { struct timespec b; clock_gettime(CLOCK_MONOTONIC, &b); return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6; }
static size_t file_bytes(const char *p) { struct stat st; return stat(p, &st) ? 0 : (size_t)st.st_size; }

int main(void) {
    char dir[] = "/tmp/t_sesdiag_XXXXXX"; if (!mkdtemp(dir)) return 2;
    // ① 会话标记
    CHECK(s2a_sesmark_prev(dir) == S2A_SESMARK_NONE, "没有标记 = 正常收尾");
    s2a_sesmark_set(dir, S2A_SESMARK_FG); CHECK(s2a_sesmark_prev(dir) == S2A_SESMARK_FG, "起局写 fg → 下次读到 fg（死在前台）");
    s2a_sesmark_set(dir, S2A_SESMARK_BG); CHECK(s2a_sesmark_prev(dir) == S2A_SESMARK_BG, "进后台写 bg → 读到 bg（后台被划掉不算异常）");
    s2a_sesmark_set(dir, S2A_SESMARK_NONE); CHECK(s2a_sesmark_prev(dir) == S2A_SESMARK_NONE, "优雅退出删掉 → 读到无");
    // 只解包的起动不算一局：不写也不删，上一局留下的照原样留给下一次正式起局
    setenv("S2A_PACK_APPLY_ONLY", "1", 1);
    s2a_sesmark_set(dir, S2A_SESMARK_FG); CHECK(s2a_sesmark_prev(dir) == S2A_SESMARK_NONE, "只解包起动写 fg 不落盘 → 下次正式起局读到无（不误判上次死在前台）");
    unsetenv("S2A_PACK_APPLY_ONLY"); s2a_sesmark_set(dir, S2A_SESMARK_FG); setenv("S2A_PACK_APPLY_ONLY", "1", 1);
    s2a_sesmark_set(dir, S2A_SESMARK_NONE); CHECK(s2a_sesmark_prev(dir) == S2A_SESMARK_FG, "上一局真死在前台、中间夹一次只解包起动 → 标记仍是 fg（不被抹掉）");
    unsetenv("S2A_PACK_APPLY_ONLY"); s2a_sesmark_set(dir, S2A_SESMARK_NONE);

    // 200 MB 假上一局日志：头一行标记 + 一次早心跳，中间全是挂死后的红行，尾部最后一次心跳与收尾
    char log[1200]; snprintf(log, sizeof log, "%s/host-20261107-081200.log", dir);
    int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) return 2;
    const char *head = "[s2a] 起局\nS2A 标记 MARK：帧 10\n[s2a] [心跳] 帧 100，前台，进程实占 900 MB\n";
    if (write(fd, head, strlen(head)) < 0) return 2;
    static char blk[1 << 20]; size_t o = 0; unsigned k = 0;
    while (o + 200 < sizeof blk) o += (size_t)snprintf(blk + o, sizeof blk - o, "[dm] [nvn-mtl] 【红】 command buffer execution error: 未能完成操作。（MTL4CommandQueueErrorDomain错误1。）fence=%u\n", k++);
    for (int i = 0; i < 200; i++) if (write(fd, blk, o) < 0) return 2;
    const char *tail = "[s2a] 热状态变为 2\n[s2a] [心跳] 帧 2228，前台，进程实占 1500 MB\n[s2a] 优雅退出完成（0.4 秒）\n";
    if (write(fd, tail, strlen(tail)) < 0) return 2;
    close(fd);
    size_t big = file_bytes(log);
    CHECK(big > 200u * 1000 * 1000, "假日志 %.1f MB", big / 1048576.0);

    s2a_sesmark_set(dir, S2A_SESMARK_FG);
    // 判据与负载无关（11-10 判据去负载化：原「用时 < 1 ms」在负载 35 时测得 1.289 ms 判红）：把 200 MB 日志设成不可读，结论照旧 = 判定不读日志；用时只打印作参考
    struct timespec t0; chmod(log, 0); clock_gettime(CLOCK_MONOTONIC, &t0);
    int prev = s2a_sesmark_prev(dir); double dm = ms_since(t0); chmod(log, 0644);
    CHECK(prev == S2A_SESMARK_FG, "上一局日志 200 MB 且不可读时判定「上次异常」照旧 = fg（不读日志；用时 %.3f ms 仅供参考）", dm);

    // ② 有界摘要
    s2a_log_sum m; clock_gettime(CLOCK_MONOTONIC, &t0);
    int rc = s2a_log_summary(log, S2A_SUM_HEAD, S2A_SUM_TAIL, &m); double sm = ms_since(t0);
    CHECK(rc == 0 && m.frames == 2228 && m.peak_mb == 1500 && m.thermal == 2 && m.mark == 1 && m.end == S2A_SUM_END_EXIT && m.truncated,
          "有界摘要：帧 %lld（期望 2228）、实占峰 %lld（1500）、热 %lld（2）、标记 %d（1）、收尾 %d（1 = exit）", m.frames, m.peak_mb, m.thermal, m.mark, m.end);
    CHECK(m.read == (size_t)S2A_SUM_HEAD + S2A_SUM_TAIL, "有界摘要读的字节数 %.2f MB = 头 %u MB + 尾 %u MB（用时 %.1f ms 仅供参考）", m.read / 1048576.0, S2A_SUM_HEAD >> 20, S2A_SUM_TAIL >> 20, sm);
    // 负对照：上限放到整份
    clock_gettime(CLOCK_MONOTONIC, &t0);
    s2a_log_sum f; rc = s2a_log_summary(log, big, big, &f); double fm = ms_since(t0);
    CHECK(rc == 0 && !f.truncated && f.read == big, "负对照：头尾上限放到整份 = 读满 %.1f MB（用时 %.1f ms，旧做法在 NSString 上逐行折叠查找更慢，真机实测 6.85 s）", f.read / 1048576.0, fm);
    CHECK(f.read > m.read, "负对照：整份读的字节数大于有界摘要（%.1f MB > %.1f MB；用时 %.1f / %.1f ms 仅供参考）", f.read / 1048576.0, m.read / 1048576.0, fm, sm);
    // 截断的尾段第一行不当成一行：尾段起点落在一行中间时，帧号仍取尾部最后一次心跳
    unlink(log); rmdir(dir);   // 标记文件
    char mk[1200]; snprintf(mk, sizeof mk, "%s/s2a_session.mark", dir); unlink(mk); rmdir(dir);
    return S2A_T_RESULT("t_sesdiag", bad);
}
