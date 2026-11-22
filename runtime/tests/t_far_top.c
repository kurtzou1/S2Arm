// 远端缺页点表取前 N（ios/far_top.h，诊断包用）。期望手写：
//   ① 5 个点（次数 30 / 500 / 7 / 500 / 1000，哈希槽顺序）取前 3：按次数降序、同次数按原顺序 → 1000、500（第 2 行）、500（第 4 行）；
//      总计行「共 5 点、缺页 2037 次；以下前 3 点占 98.2%」（2000 / 2037 = 0.98184 → 98.2%）
//   ② 取前 200（多于点数）：5 行全在，占 100.0%    ③ 只有表头、没有数据行：NULL    ④ 文件不存在：NULL
#include "../../ios/far_top.h"
#include <unistd.h>
static int bad;
#define CHECK(c, ...) do { if (c) printf("✓ "); else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
static char *mk(const char *body) { static char p[64]; snprintf(p, sizeof p, "/tmp/t_far_top_XXXXXX"); int fd = mkstemp(p); FILE *f = fdopen(fd, "w"); fputs(body, f); fclose(f); return p; }
int main(void) {
    const char *H = "# 模块\t偏移\t次数\t类别\t代执行失败\n";
    char body[512]; snprintf(body, sizeof body, "%smain\t0x10\t30\t1\t0\nmain\t0x20\t500\t1\t0\nsdk\t0x30\t7\t2\t0\nmain\t0x40\t500\t1\t0\nsubsdk0\t0x50\t1000\t1\t0\n", H);
    char *p = mk(body), *o = s2a_far_top(p, 3);
    const char *want = "# 模块\t偏移\t次数\t类别\t代执行失败\n# 共 5 点、缺页 2037 次；以下前 3 点占 98.2%\nsubsdk0\t0x50\t1000\t1\t0\nmain\t0x20\t500\t1\t0\nmain\t0x40\t500\t1\t0\n";
    CHECK(o && !strcmp(o, want), "① 取前 3：降序、同次数按原顺序、总计 98.2%%（实得：%s）", o ? o : "NULL"); free(o);
    o = s2a_far_top(p, 200);
    CHECK(o && strstr(o, "以下前 5 点占 100.0%") && strstr(o, "sdk\t0x30\t7"), "② 取前 200：5 行全在、占 100.0%%"); free(o); unlink(p);
    p = mk(H); o = s2a_far_top(p, 200); CHECK(!o, "③ 只有表头：NULL"); free(o); unlink(p);
    CHECK(!s2a_far_top("/tmp/t_far_top_none_does_not_exist", 200), "④ 文件不存在：NULL");
    printf("%s t_far_top：%d 处不符\n", bad ? "✗" : "✓", bad); return bad ? 1 : 0;
}
