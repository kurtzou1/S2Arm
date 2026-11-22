// 放不下标准布局时窗口下方留给宿主多少（vawin.c s2a_window_host_below，#783）与学到的跨度记录（s2a_window_span_seen）。
// 背景：iPad Pro M2 iPadOS 27.2.1，2^39 以下最大一块 64 GB 放不下这款 76 GB 标准布局，原先固定只给宿主 3 GiB，宿主低区开局 3.4 GB，
//   命令录制等宿主映射涨满后 mmap ENOMEM 闪退；那款整局只碰到 16395 MB 的跨度。
// 期望按规则手写（窗口 = 学到的跨度 × 1.25 + 2 GiB、1 GiB 向上取整；宿主 = 空洞 − 窗口、1 GiB 向下取整，至少 3 GiB；没学到 = 3 GiB）：
//   ① 没学到：3 GiB    ② 学到 16395 MB、空洞 64 GiB：窗口 ⌈22541.75 MB⌉ = 23 GiB → 宿主 41 GiB，且宿主 + 学到的跨度 ≤ 空洞
//   ③ 学到的比空洞还大：3 GiB    ④ 学到 100 MB：窗口 ⌈2173 MB⌉ = 3 GiB → 宿主 61 GiB    ⑤ 记录文件：有 → 读出、没有 / 读不出 → 0
//   ⑨ 低区碰底死的局（#1143，11-15 iPhone 读数：最大空洞 6 MB、本局跨度 13649 MB、原记录没有 / 2138 MB）：最大空洞 < 64 MB 才记、比原记录大才写；
//      记下 13649 MB 后空洞 64 GiB：窗口 ⌈13649 × 1.25 + 2048 = 19109.25 MB⌉ = 19 GiB → 宿主 45 GiB
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_VAWIN_NORESERVE", "1", 1); }   // 先于 vawin.c 的构造函数（101）：不占窗口
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
#define MB (1ull << 20)
#define GB (1ull << 30)
static uint64_t g_test_span;
__attribute__((used, visibility("default"))) uint64_t s2a_mem_span_learn(void) { return g_test_span; }   // vawin.c 按名字取（dlsym），这里冒充 svc_mem.c
extern uint64_t s2a_span_seed(uint64_t);
int main(void) {
    {   // ⓪ 学跨度的贴顶规则（s2a_span_learn_ok）：跨度 + 512 MB < 窗口才记；贴顶但有越界映射 / 远端缺页照记。期望手算：窗口 62464 MB
        extern int s2a_span_learn_ok(uint64_t, uint64_t, uint64_t, uint64_t);
        CHECK(!s2a_span_learn_ok(62080 * MB, 62464 * MB, 0, 0), "⓪ 异度3 贴顶 62080（窗口末 −384 MB）、没碰窗口外：不记");
        CHECK(s2a_span_learn_ok(61951 * MB, 62464 * MB, 0, 0) && !s2a_span_learn_ok(61952 * MB, 62464 * MB, 0, 0), "⓪ 边界：61951 + 512 = 62463 < 62464 记，61952 不记");
        CHECK(s2a_span_learn_ok(62400 * MB, 62464 * MB, 3, 0) && s2a_span_learn_ok(62300 * MB, 62464 * MB, 0, 12), "⓪ 贴顶但越界映射 3 次 / 远端缺页 12 次：记");
        CHECK(!s2a_span_learn_ok(0, 62464 * MB, 5, 5), "⓪ 跨度 0：不记"); }
    CHECK(s2a_window_host_below(64 * GB, 0) == 6 * GB, "① 没学到跨度、空洞 64 GiB：宿主下限 6 GiB（11-22 起；原 3 GiB，宿主峰值 p99 约 5 GB 碰底）");
    {   // ①b 宿主下限按空洞定（s2a_window_host_floor）：≥ 22 GiB（6 GiB 宿主 + 16 GiB 窗口）给 6 GiB，更小的空洞照旧 3 GiB
        extern uint64_t s2a_window_host_floor(uint64_t);
        CHECK(s2a_window_host_floor(22 * GB) == 6 * GB && s2a_window_host_floor(22 * GB - 1) == 3 * GB && s2a_window_host_floor(6 * GB) == 3 * GB,
              "①b 空洞 22 GiB → 6 GiB；差 1 字节 → 3 GiB；6 GB 小 iPad → 3 GiB");
        CHECK(s2a_window_host_below(6 * GB, 0) == 3 * GB, "①b 6 GB 空洞没学到跨度：宿主照旧 3 GiB"); }
    uint64_t h = s2a_window_host_below(64 * GB, 16395 * MB);
    CHECK(h == 41 * GB && h + 16395 * MB <= 64 * GB, "② 学到 16395 MB、空洞 64 GiB：宿主 41 GiB（实得 %llu MB），宿主 + 跨度不超空洞", (unsigned long long)(h / MB));
    CHECK(s2a_window_host_below(64 * GB, 70 * GB) == 6 * GB, "③ 学到的跨度比空洞还大：宿主至少下限 6 GiB");
    CHECK(s2a_window_host_below(64 * GB, 100 * MB) == 61 * GB, "④ 学到 100 MB：窗口 3 GiB、宿主 61 GiB");
    // 按学到的跨度该给的窗口（s2a_window_for_span，多款容器选定游戏后收窗口用，#55248c）。期望手算：跨度 × 1.25 + 2 GiB、1 GiB 向上取整、至少 2 GiB
    CHECK(s2a_window_for_span(0) == 0, "④b 没学到：0 = 不限");
    CHECK(s2a_window_for_span(13670 * MB) == 19 * GB, "④c 马车世界学到 13670 MB：13670×1.25+2048 = 19135.5 MB → 19 GiB");
    CHECK(s2a_window_for_span(100 * MB) == 3 * GB, "④d 学到 100 MB：125+2048 = 2173 MB → 3 GiB（同 ④ 的窗口）");
    CHECK(s2a_window_for_span(1) == 3 * GB, "④e 学到 1 字节：2 GiB 多一点 → 3 GiB（取整后不低于 2 GiB）");
    char p[] = "/tmp/s2a_span_peak_XXXXXX"; int fd = mkstemp(p); dprintf(fd, "17191403520\n"); close(fd);
    setenv("S2A_WIN_SPAN_PEAK", p, 1);
    CHECK(s2a_window_span_seen(0x01000000000AB000ull) == 17191403520ull, "⑤ 记录文件有值（种子表里没有的号）：读出 17191403520");
    CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == s2a_span_seed(0x0400486024DEC000ull) && s2a_span_seed(0x0400486024DEC000ull) > 17191403520ull,
          "⑤ 种子表里有、比本机记录大的号：取种子表的值（本机短局记的只是下界）");
    { char q[] = "/tmp/s2a_span_peak_XXXXXX"; int fq = mkstemp(q); dprintf(fq, "%llu\n", (unsigned long long)(s2a_span_seed(0x0400486024DEC000ull) + 1)); close(fq); setenv("S2A_WIN_SPAN_PEAK", q, 1);
      CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == s2a_span_seed(0x0400486024DEC000ull) + 1, "⑤ 本机记录比种子表大：取本机记录"); unlink(q); setenv("S2A_WIN_SPAN_PEAK", p, 1); }
    FILE *f = fopen(p, "w"); fputs("坏\n", f); fclose(f);
    CHECK(s2a_window_span_seen(0x01000000000AB000ull) == 0, "⑤ 记录读不出：0（照旧 3 GiB）");
    unlink(p);
    CHECK(s2a_window_span_seen(0x01000000000AB000ull) == 0, "⑤ 没有记录、种子表也没有：0");
    // ⑥ 只记真跑起来的局（11-12 iPhone 实机：一局刚开就死只碰到 2.26 GB，记下后下一局窗口缩到 5 GB 起不来、且锁死）：出图满 300 次才记
    extern int s2a_window_span_worth(uint64_t presents);
    CHECK(!s2a_window_span_worth(0) && !s2a_window_span_worth(299) && s2a_window_span_worth(300), "⑥ 出图 0 / 299 次不记、300 次起记");
    // ⑦ 自愈：没按学到的跨度收窄（本进程 g_span_learned = 0）时调 forget 不动别人的记录
    { extern void s2a_window_span_forget(void); char q[] = "/tmp/s2a_span_keep_XXXXXX"; int qd = mkstemp(q); dprintf(qd, "123\n"); close(qd);
      setenv("S2A_WIN_SPAN_PEAK", q, 1); s2a_window_span_forget(); CHECK(access(q, F_OK) == 0, "⑦ 没收窄过：forget 不删记录"); unlink(q); }
    // ⑧ 当场放宽的新起点（s2a_window_widen_lo，手算）：留宿主底 0x70_0000_0000、窗口底 0x7B_0000_0000（下方留了 44 GiB）
    //   宿主下限 6 GiB 时下方没别人：0x71_8000_0000（底 + 6 GiB；3 GiB 时 0x70_C000_0000）；已占到 0x75_0000_1000：向上取整 0x75_4000_0000；已占到窗口底：0（放不宽）
    { extern uint64_t s2a_window_widen_lo(uint64_t, uint64_t, uint64_t, uint64_t); const uint64_t K = 0x7000000000ull, B = 0x7B00000000ull;
      CHECK(s2a_window_widen_lo(K, B, K, 6 * GB) == 0x7180000000ull, "⑧ 下方空着：新起点 = 留宿主底 + 宿主下限 6 GiB");
      CHECK(s2a_window_widen_lo(K, B, K, 3 * GB) == 0x70C0000000ull, "⑧ 小空洞下限 3 GiB：新起点 = 留宿主底 + 3 GiB");
      CHECK(s2a_window_widen_lo(K, B, 0x7500001000ull, 6 * GB) == 0x7540000000ull, "⑧ 下方已占到 0x7500001000：新起点取整到 0x7540000000、不盖");
      CHECK(s2a_window_widen_lo(K, B, B, 6 * GB) == 0, "⑧ 下方占满到窗口底：放不宽（0）"); }
    {   // ⑨ 低区碰底死的局记跨度（s2a_window_span_arm / s2a_window_span_crash）
        extern int s2a_window_span_crash_worth(uint64_t); extern void s2a_window_span_arm(void); extern uint64_t s2a_window_span_crash(uint64_t);
        CHECK(s2a_window_span_crash_worth(6 * MB) && s2a_window_span_crash_worth(64 * MB - 1) && !s2a_window_span_crash_worth(64 * MB) && !s2a_window_span_crash_worth(512 * MB),
              "⑨ 最大空洞 6 MB / 64 MB−1 字节算碰底，64 MB / 512 MB 不算");
        char q[] = "/tmp/s2a_span_crash_XXXXXX"; int qd = mkstemp(q); close(qd); unlink(q);   // 先没有记录
        setenv("S2A_WIN_SPAN_PEAK", q, 1);
        g_test_span = 13649 * MB;
        CHECK(s2a_window_span_crash(6 * MB) == 0, "⑨ 没备好（C# 初始化前崩）：不记");
        s2a_window_span_arm();
        CHECK(s2a_window_span_crash(512 * MB) == 0 && access(q, F_OK) != 0, "⑨ 低区没碰底（最大空洞 512 MB）：不记、不建文件");
        CHECK(s2a_window_span_crash(6 * MB) == 13649 * MB && s2a_window_span_seen(1) == 13649 * MB, "⑨ 没有记录、碰底：记下 13649 MB 并读得回");
        FILE *f = fopen(q, "w"); fprintf(f, "%llu\n", (unsigned long long)(2138 * MB)); fclose(f);
        CHECK(s2a_window_span_crash(6 * MB) == 13649 * MB && s2a_window_span_seen(1) == 13649 * MB, "⑨ 原记录 2138 MB 更小：改写成 13649 MB");
        g_test_span = 2138 * MB;
        CHECK(s2a_window_span_crash(6 * MB) == 0 && s2a_window_span_seen(1) == 13649 * MB, "⑨ 本局 2138 MB 不比记录大：不动");
        CHECK(s2a_window_host_below(64 * GB, s2a_window_span_seen(1)) == 45 * GB, "⑨ 下一局空洞 64 GiB：宿主 45 GiB（原先 3 GiB）");
        unlink(q); char t[64]; snprintf(t, sizeof t, "%s.tmp", q); CHECK(access(t, F_OK) != 0, "⑨ 不留临时文件"); }
    {   // ⑩ 旧记录不小于空洞（旧版把窗口外远端映射算进跨度，某机记成 73086 MB、空洞 49152 MB）：当作没有、允许覆盖；空洞未知（0）不判
        extern int s2a_window_span_rec_ok(uint64_t, uint64_t);
        CHECK(!s2a_window_span_rec_ok(73086 * MB, 49152 * MB) && !s2a_window_span_rec_ok(76030 * MB, 65536 * MB), "⑩ 记录 ≥ 空洞：不算数");
        CHECK(s2a_window_span_rec_ok(16408 * MB, 49152 * MB) && !s2a_window_span_rec_ok(0, 49152 * MB) && s2a_window_span_rec_ok(73086 * MB, 0), "⑩ 空洞内的算数、0 不算、空洞未知不判"); }
    {   // ⑪ 小内存 iPad（4 GB 机，2^39 以下 6 GB 空洞）：按游戏应用池给窗口，宿主至少 2 GiB。期望手算，不拿实现输出当期望：
        //    Switch 1 池 3285 MB + 堆起点约 380 MB → 窗口 4 GiB、宿主 2 GiB；64 GB 空洞留宿主下限 6 GiB；已学到更大跨度不被池压小
        extern uint64_t s2a_window_host_below_for_pool(uint64_t, uint64_t, uint64_t);
        CHECK(s2a_window_host_below_for_pool(6 * GB, 0, 3285 * MB) == 2 * GB, "⑪ 6 GB 空洞 + 3285 MB 池：宿主 2 GiB（窗口 4 GiB）");
        CHECK(s2a_window_host_below_for_pool(64 * GB, 0, 3285 * MB) == 6 * GB, "⑫ 64 GB 空洞：宿主下限 6 GiB（池要的 4 GiB 窗口远小于空洞，不压）");
        CHECK(s2a_window_host_below_for_pool(4 * GB, 0, 3285 * MB) == 2 * GB, "⑬ 4 GB 空洞：宿主不低于 2 GiB，放不下如实失败");
        CHECK(s2a_window_host_below_for_pool(6 * GB, 0, 9 * GB) == 2 * GB, "⑭ Switch 2 池 9 GiB 也压到下限，仍放不下由失败页说清");
        CHECK(s2a_window_host_below_for_pool(64 * GB, 16395 * MB, 3285 * MB) == 41 * GB, "⑮ 学到更大跨度时不被池需求反向压小");
        CHECK(s2a_window_host_below_for_pool(6 * GB, 0, 0) == 3 * GB, "⑯ 不知道池时照旧 3 GiB"); }
    // ⑰ 种子表查表（vawin.c s2a_span_seed，表 = tools/span_seed.py 生成的 span_seed.inc）：表里每一条都查得到原值、程序号严格升序（二分的前提）；
    //   不在表里的号（0、1、全 F、表里相邻两号之间）回 0
    { static const struct { uint64_t pid; uint32_t mb, n; } T[] = {
#include "../src/span_seed.inc"
      };
      extern uint64_t s2a_span_seed(uint64_t); size_t n = sizeof T / sizeof T[0]; int miss = 0, order = 0, gap = 0;
      for (size_t i = 0; i < n; i++) { if (s2a_span_seed(T[i].pid) != (uint64_t)T[i].mb << 20 || T[i].n < 2) miss++; if (i && T[i - 1].pid >= T[i].pid) order++;
          if (i && T[i].pid - T[i - 1].pid > 1 && s2a_span_seed(T[i - 1].pid + 1)) gap++; }
      CHECK(n > 0 && !miss && !order && !gap, "⑰ 种子表 %zu 条：查不到原值或样本 < 2 的 %d 条、不升序 %d 处、相邻号之间查出值 %d 处（期望 0）", n, miss, order, gap);
      CHECK(!s2a_span_seed(0) && !s2a_span_seed(1) && !s2a_span_seed(~0ull), "⑰ 不在表里的号回 0"); }
    // ⑱ 收窄后没到首帧的自愈（D-PR33）：种子里一款的跨度来自开局就停掉的局（小），按它收窄后这局还是没到首帧——下一局必须不按它收，否则种子删不掉、每局都打不开。
    //   用「子进程 = 一局」：子进程按已知跨度收窄（s2a_window_cap_try）后不报首帧直接退出 = 早夭局；父进程 = 下一局。期望手写：
    //   早夭后 span_seen = 0（不收）且记下 span_cap_bad = 种子值；本机后来记下比它大 1 字节的跨度 → 照收（回该值）；跑到首帧（s2a_window_cap_ok）的局之后照收；
    //   本局自己写的标记本局不认；多款容器按 games/<号>/ 前缀同样生效；纯判定：跨度 ≤ 记下的值不收、> 照收、没记录照收
    {
        extern uint64_t s2a_span_seed(uint64_t);
        const uint64_t A = 0x0100024008310000ull, B = 0x0100000011D90000ull;   // 种子表里的两款（span_seed.inc 前几行）
        CHECK(s2a_span_seed(A) && s2a_span_seed(B), "⑱ 前提：两款都在种子表里（%llu / %llu MB）", (unsigned long long)(s2a_span_seed(A) >> 20), (unsigned long long)(s2a_span_seed(B) >> 20));
        CHECK(s2a_window_span_cap_blocked(356 * MB, 356 * MB) && !s2a_window_span_cap_blocked(356 * MB + 1, 356 * MB) && !s2a_window_span_cap_blocked(356 * MB, 0),
              "⑱ 纯判定：跨度 ≤ 记下的值不收、大 1 字节照收、没记录照收");
        unsetenv("S2A_WIN_SPAN_PEAK");
        char d[] = "/tmp/s2a_captry_XXXXXX"; if (!mkdtemp(d)) { CHECK(0, "⑱ 建临时文档根"); } setenv("S2A_DOCS", d, 1);
        char bp[512], tp[512], rp[512];
        snprintf(bp, sizeof bp, "%s/wire/%016llX/span_cap_bad", d, (unsigned long long)A); snprintf(tp, sizeof tp, "%s/wire/%016llX/span_cap_try", d, (unsigned long long)A);
        snprintf(rp, sizeof rp, "%s/wire/%016llX/span_peak2", d, (unsigned long long)A);
        CHECK(s2a_window_span_seen(A) == s2a_span_seed(A), "⑱ 第一局：没有标记，按种子值收");
        pid_t c = fork(); if (!c) { s2a_window_cap_try(NULL, A, s2a_window_span_seen(A)); _exit(s2a_window_span_seen(A) == s2a_span_seed(A) ? 0 : 3); }   // 早夭局：收窄、不报首帧就退出
        int st = 0; waitpid(c, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "⑱ 早夭局本局自己写的标记本局不认（局内再查仍按种子值）");
        CHECK(access(tp, F_OK) == 0, "⑱ 早夭局退出后标记还在");
        CHECK(s2a_window_span_seen(A) == 0, "⑱ 下一局：上一局收窄后没到首帧 → 不按种子收（回 0）");
        CHECK(access(tp, F_OK) != 0 && access(bp, F_OK) == 0, "⑱ 标记改名 span_cap_bad");
        CHECK(s2a_window_span_seen(A) == 0, "⑱ 再下一局：种子值仍不超过记下的值 → 照旧不收（不会又打不开）");
        { FILE *f = fopen(rp, "w"); fprintf(f, "%llu\n", (unsigned long long)(s2a_span_seed(A) + 1)); fclose(f); }
        CHECK(s2a_window_span_seen(A) == s2a_span_seed(A) + 1, "⑱ 本机后来学到更大的跨度（多 1 字节）：照收");
        c = fork(); if (!c) { s2a_window_cap_try(NULL, B, s2a_window_span_seen(B)); s2a_window_cap_ok(); _exit(0); }   // 收窄后跑到首帧的局
        waitpid(c, &st, 0);
        CHECK(s2a_window_span_seen(B) == s2a_span_seed(B), "⑱ 收窄后跑到首帧的款：下一局照按种子收");
        // 多款容器：构造期按 games/<号>/ 前缀查（选定后 S2A_DOCS 换成 games/<号>、按 NULL 前缀查同一个文件）
        char gd[600]; snprintf(gd, sizeof gd, "%s/games", d); mkdir(gd, 0755); snprintf(gd, sizeof gd, "%s/games/%016llX", d, (unsigned long long)B); mkdir(gd, 0755);
        c = fork(); if (!c) { setenv("S2A_DOCS", gd, 1); s2a_window_cap_try(NULL, B, s2a_span_seed(B)); _exit(0); }   // 容器里选定 B 后收窄、早夭
        waitpid(c, &st, 0);
        char pre[64]; snprintf(pre, sizeof pre, "games/%016llX/", (unsigned long long)B);
        CHECK(s2a_window_span_trust(pre, B, s2a_span_seed(B)) == 0, "⑱ 多款容器：选定后收窄早夭的款，下一局构造期按 games/<号>/ 查到、不收");
        CHECK(s2a_window_span_seen(B) == s2a_span_seed(B), "⑱ 多款容器的标记不影响旧位置（文档根直下 wire/）的同号");
        setenv("S2A_DOCS", gd, 1); CHECK(s2a_window_span_seen(B) == 0, "⑱ 多款容器选定后（S2A_DOCS = games/<号>）同样不收"); unsetenv("S2A_DOCS");
        char cmd[600]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", d); if (system(cmd)) {}
    }
    printf("%s t_vawin_learned：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
