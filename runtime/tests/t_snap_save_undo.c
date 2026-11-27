// 即时存档恢复失败时撤销「退回存档」（runtime/src/snapshot.c save_undo_at，#2292）：按生产源文件原样抽出 tree_files / save_tree_put_at / save_undo_at
//   （mk 规则从 snapshot.c 截取，同一份代码），在临时目录里核。期望手写：
//   ① 有备份：当前存档 {slot/0/main.bin=新, slot/1/manual.bin=手动存档}，备份一份；按快照 {slot/0/main.bin=旧} 写回 → 只剩旧 main、手动存档被删；
//      撤销（按备份写回）→ main 回到「新」、手动存档回来，且没有多余文件
//   ② 退回前没有存档目录（备份为空）：写回快照后有 1 个文件；撤销 → 一个文件都不剩
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#define LOG(...) do { printf("  [日志] "); printf(__VA_ARGS__); putchar('\n'); } while (0)
#include "snap_save_undo_ext.c"

static int fails;
static void put(const char *root, const char *rel, const char *text) {
    char p[2048]; snprintf(p, sizeof p, "%s/%s", root, rel);
    for (char *q = p + 1; (q = strchr(q, '/')); q++) { *q = 0; mkdir(p, 0755); *q = '/'; }
    FILE *f = fopen(p, "w"); fputs(text, f); fclose(f);
}
static const char *get(const char *root, const char *rel) {
    static char b[256]; char p[2048]; snprintf(p, sizeof p, "%s/%s", root, rel); FILE *f = fopen(p, "r"); if (!f) return NULL;
    size_t n = fread(b, 1, sizeof b - 1, f); b[n] = 0; fclose(f); return b;
}
static int count(const char *root) { char **v = NULL; int n = 0, cap = 0; tree_files(root, "", &v, &n, &cap); for (int i = 0; i < n; i++) free(v[i]); free(v); return n; }
static void expect(const char *what, const char *want, const char *got) {
    int ok = (!want && !got) || (want && got && !strcmp(want, got));
    printf("%s %s 期望 %s → 真结果 %s\n", ok ? "PASS" : "FAIL", what, want ? want : "（没有）", got ? got : "（没有）"); fails += !ok;
}
int main(void) {
    char T[] = "/tmp/t_snap_save_undo_XXXXXX"; if (!mkdtemp(T)) return 1;
    char root[600], bk[600], snap[600], root2[600], cnt[32];
    snprintf(root, sizeof root, "%s/save", T); snprintf(bk, sizeof bk, "%s/backup", T); snprintf(snap, sizeof snap, "%s/snap_tree", T); snprintf(root2, sizeof root2, "%s/save2", T);
    put(root, "0000000000000001/0/main.bin", "新"); put(root, "0000000000000001/1/manual.bin", "手动存档");
    put(bk, "0000000000000001/0/main.bin", "新"); put(bk, "0000000000000001/1/manual.bin", "手动存档");   // = clonefile 备份
    put(snap, "0000000000000001/0/main.bin", "旧");
    save_tree_put_at(snap, root);
    expect("① 写回快照：main 是旧的", "旧", get(root, "0000000000000001/0/main.bin"));
    expect("① 写回快照：手动存档被删", NULL, get(root, "0000000000000001/1/manual.bin"));
    expect("① 撤销返回 0", "0", save_undo_at(bk, root) ? "-1" : "0");
    expect("① 撤销后 main 回到新", "新", get(root, "0000000000000001/0/main.bin"));
    expect("① 撤销后手动存档回来", "手动存档", get(root, "0000000000000001/1/manual.bin"));
    snprintf(cnt, sizeof cnt, "%d", count(root)); expect("① 没有多余文件", "2", cnt);
    save_tree_put_at(snap, root2);
    snprintf(cnt, sizeof cnt, "%d", count(root2)); expect("② 退回前没有存档：写回后 1 个文件", "1", cnt);
    expect("② 撤销返回 0", "0", save_undo_at("", root2) ? "-1" : "0");
    snprintf(cnt, sizeof cnt, "%d", count(root2)); expect("② 撤销后一个文件都不剩", "0", cnt);
    char cmd[700]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", T); (void)system(cmd);
    if (fails) { printf("✗ t_snap_save_undo：%d 项不符\n", fails); return 1; }
    printf("✓ t_snap_save_undo：恢复失败撤销退回存档（按备份写回 / 退回前无存档则删净）全过\n"); return 0;
}
