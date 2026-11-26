// 快照删除（runtime/src/snapdel.c）：期望值只看文件系统——删后三个目录都不在、占的块数归零，同名目录能重新建起来再删
// 新快照换上（s2a_snap_swap_in）：首存 / 有旧快照 / 新目录缺失三种看换上后目录里的标记；
//   崩点判据：本文件替换 rename / renamex_np（snapdel.c 同一可执行文件里的调用绑到这里，转调系统的那份），对第 k 次改名刚完成的每个崩点各起一个
//   子进程、在那一刻 _exit，父进程看磁盘：正式目录必须在、标记完整（a / b），不靠事后恢复。崩点逐个穷举，不靠随机时刻碰运气。
//   旧写法两次改名，崩在第 1 次之后正式目录不在（只剩 .old），进程死在这里玩家的快照就没了；原子交换只有一次改名，任何崩点正式目录都在。
//   不用「另一条线程并发 lstat 一次都不能看不到」做判据：APFS 上交换本身原子，但并发查找不保证每一刻都看得见名字（4 份并行共 16 万次交换
//   实测 1 次 lstat 回 ENOENT、交换失败 0 次；11-25 门禁高负载下本项因此偶发红），测的不是要防的「被杀后丢快照」
// 恢复（s2a_snap_recover）：旧版死在两次改名之间留下「正式目录不在、只有 .old」→ 改回正式目录、内容是旧的那份；两个都在 → 删 .old、正式目录不动；只有正式目录 → 不动
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fts.h>

void s2a_snap_rmtree(const char *path); int s2a_snap_delete(const char *dir); int s2a_snap_swap_in(const char *neu, const char *final); int s2a_snap_recover(const char *final);
static int g_busy;   // 引擎「正在存」的替身（snapdel.c 弱引用 s2a_snap_busy，单测不链引擎）
int s2a_snap_busy(void) { return g_busy; }
static int g_fail, g_ok;
#define CHECK(c, ...) do { if (c) g_ok++; else { g_fail++; printf("  不符："); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void put(const char *path, size_t n) { FILE *f = fopen(path, "wb"); if (!f) return; char b[4096]; memset(b, 7, sizeof b); while (n) { size_t k = n < sizeof b ? n : sizeof b; fwrite(b, 1, k, f); n -= k; } fclose(f); }
static long long blocks(const char *root) {   // 这棵树占的 512 字节块数（不存在为 0）
    char *av[] = {(char *)root, NULL}; FTS *fs = fts_open(av, FTS_PHYSICAL | FTS_NOCHDIR, NULL); if (!fs) return 0; long long b = 0;
    for (FTSENT *e; (e = fts_read(fs));) if (e->fts_statp && e->fts_info != FTS_DP && e->fts_info != FTS_NS) b += e->fts_statp->st_blocks;
    fts_close(fs); return b;
}
static int exists(const char *p) { struct stat st; return lstat(p, &st) == 0; }
static void make_snapshot(const char *d) {   // 仿一份快照：清单、缩略图、整帧、子目录里的内存块
    char p[1024]; mkdir(d, 0755);
    snprintf(p, sizeof p, "%s/manifest.tsv", d); put(p, 200);
    snprintf(p, sizeof p, "%s/thumb.png", d); put(p, 53 * 1024);
    snprintf(p, sizeof p, "%s/a_last.png", d); put(p, 500 * 1024);
    snprintf(p, sizeof p, "%s/mem", d); mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/mem/0000.bin", d); put(p, 4 << 20);
}

static void mark(const char *d, const char *tag) { char p[1200]; mkdir(d, 0755); snprintf(p, sizeof p, "%s/manifest.tsv", d); FILE *f = fopen(p, "w"); if (f) { fputs(tag, f); fclose(f); } }
static int marked(const char *d, const char *tag) { char p[1200], b[32] = {0}; snprintf(p, sizeof p, "%s/manifest.tsv", d); FILE *f = fopen(p, "r"); if (!f) return 0; fgets(b, sizeof b, f); fclose(f); return !strcmp(b, tag); }
#include <dlfcn.h>
#include <sys/wait.h>
static int g_crash_at, g_renames;   // 第几次改名完成后退出（0 = 不崩）/ 本进程已完成的改名次数
static void renamed(void) { g_renames++; if (g_crash_at && g_renames == g_crash_at) _exit(0); }
int rename(const char *a, const char *b) {
    static int (*real)(const char *, const char *); if (!real) real = (int (*)(const char *, const char *))dlsym(RTLD_NEXT, "rename");
    int r = real(a, b); if (!r) renamed(); return r;
}
int renamex_np(const char *a, const char *b, unsigned int f) {
    static int (*real)(const char *, const char *, unsigned int); if (!real) real = (int (*)(const char *, const char *, unsigned int))dlsym(RTLD_NEXT, "renamex_np");
    int r = real(a, b, f); if (!r) renamed(); return r;
}
// 有旧快照（a）换上新快照（b），崩在第 k 次改名之后：回 0 = 正式目录在且完整；1 = 不在；2 = 在但标记不完整
static int crash_at(const char *snap, const char *neu, const char *old, int k) {
    s2a_snap_rmtree(snap); s2a_snap_rmtree(neu); s2a_snap_rmtree(old); mark(snap, "a"); mark(neu, "b");
    pid_t pid = fork(); if (pid == 0) { g_renames = 0; g_crash_at = k; s2a_snap_swap_in(neu, snap); _exit(0); }
    if (pid < 0) return 3;
    waitpid(pid, NULL, 0);
    return !exists(snap) ? 1 : marked(snap, "a") || marked(snap, "b") ? 0 : 2;
}

int main(void) {
    char base[] = "/tmp/t_snapdel.XXXXXX"; if (!mkdtemp(base)) { printf("✗ t_snapdel：建临时目录失败\n"); return 1; }
    char snap[1100], neu[1100], old[1100], keep[1100], p[1200];
    snprintf(snap, sizeof snap, "%s/snapshot", base); snprintf(neu, sizeof neu, "%s.new", snap); snprintf(old, sizeof old, "%s.old", snap);
    snprintf(keep, sizeof keep, "%s/saves", base); mkdir(keep, 0755); snprintf(p, sizeof p, "%s/slot0", keep); put(p, 1000);

    make_snapshot(snap); make_snapshot(neu); make_snapshot(old);
    snprintf(p, sizeof p, "%s/link", snap); symlink(keep, p);   // 快照里的符号链接：只删链接，不碰它指向的存档
    long long before = blocks(base);
    CHECK(blocks(snap) > 8000, "仿出来的快照应占 >4 MB，实际 %lld 块", blocks(snap));
    CHECK(s2a_snap_delete(snap) == 0, "删除应回 0");
    CHECK(!exists(snap) && !exists(neu) && !exists(old), "删后快照目录、.new、.old 都应不在");
    CHECK(exists(keep) && blocks(keep) > 0, "符号链接指向的存档应原样还在");
    long long after = blocks(base);
    CHECK(before - after >= 3 * 8192, "空间应腾出至少三份 4 MB 内存块（%lld → %lld 块）", before, after);

    CHECK(s2a_snap_delete(snap) == 0, "再删一次（已不存在）也应回 0");
    make_snapshot(snap);   // 删完同一个位置能重新存
    snprintf(p, sizeof p, "%s/manifest.tsv", snap);
    CHECK(exists(p), "删后同一目录应能重新写入快照");
    CHECK(s2a_snap_delete(snap) == 0 && !exists(snap), "重新存的那份也能删掉");
    CHECK(s2a_snap_delete("") == -1 && s2a_snap_delete(NULL) == -1, "空路径应回 -1、什么都不删");
    make_snapshot(snap);
    CHECK(s2a_snap_delete("snapshot") == -1 && exists(snap), "相对路径应回 -1、不按当前目录去删");
    CHECK(s2a_snap_delete(snap) == 0, "收尾删掉");

    make_snapshot(snap); g_busy = 1;
    CHECK(s2a_snap_delete(snap) == -2 && exists(snap), "引擎正在存时删除应回 -2、快照原样");
    g_busy = 0; CHECK(s2a_snap_delete(snap) == 0 && !exists(snap), "存完再删应删掉");
    // 换上新快照
    mark(neu, "new"); CHECK(s2a_snap_swap_in(neu, snap) == 0 && marked(snap, "new") && !exists(neu), "首存（没有旧快照）应换上、新目录名下不留东西");
    mark(neu, "new2"); CHECK(s2a_snap_swap_in(neu, snap) == 0 && marked(snap, "new2") && !exists(neu) && !exists(old), "有旧快照应换成新的、旧的删掉、不留 .old");
    CHECK(s2a_snap_swap_in(neu, snap) == -1 && marked(snap, "new2"), "新目录不在应回 -1、旧快照原样");
    int bad = 0; for (int i = 0; i < 500; i++) { mark(neu, i & 1 ? "a" : "b"); bad += s2a_snap_swap_in(neu, snap) != 0; }
    CHECK(bad == 0 && marked(snap, "a"), "连换 500 次都应换上、最后是第 500 份（失败 %d 次）", bad);
    g_renames = 0; mark(neu, "b"); s2a_snap_swap_in(neu, snap); int n = g_renames;   // 一次换上做了几次改名 = 要穷举的崩点数
    CHECK(n >= 1, "换上应至少改名一次（实际 %d 次）", n);
    char why[256] = ""; for (int k = 1; k <= n; k++) { int r = crash_at(snap, neu, old, k); if (r) { snprintf(why, sizeof why, "崩在第 %d 次改名后：%s", k, r == 1 ? "正式目录不在" : r == 2 ? "标记不完整" : "fork 失败"); break; } }
    CHECK(!why[0], "换上途中每个崩点（共 %d 个）正式目录都应在且完整（%s）", n, why[0] ? why : "都在");
    s2a_snap_rmtree(neu); s2a_snap_rmtree(old); mark(snap, "a");
    CHECK(s2a_snap_delete(snap) == 0, "收尾删掉");

    // 恢复：旧版死在两次改名之间留下的现场
    mark(old, "old"); CHECK(s2a_snap_recover(snap) == 1 && marked(snap, "old") && !exists(old), "正式目录不在、只有 .old：应恢复成正式目录、内容是旧的那份");
    mark(old, "stale"); CHECK(s2a_snap_recover(snap) == 0 && marked(snap, "old") && !exists(old), "两个都在：应删 .old、正式目录不动");
    CHECK(s2a_snap_recover(snap) == 0 && marked(snap, "old"), "只有正式目录：不动");
    CHECK(s2a_snap_recover(neu) == 0 && !exists(neu), "都不在：什么都不做");
    CHECK(s2a_snap_delete(snap) == 0, "收尾删掉");
    s2a_snap_rmtree(base);
    printf("%s t_snapdel：%d 项通过，%d 项不符\n", g_fail ? "✗" : "✓", g_ok, g_fail);
    return g_fail != 0;
}
