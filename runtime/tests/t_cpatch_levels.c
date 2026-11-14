// 帧率补丁按档（runtime/src/cpatch.c fps_pick / s2a_cpatch_fps_pick / s2a_cpatch_fps_levels，11-13 维护者「60 / 120 都带进去，玩家自己切」）：
//   手工模块，表里两份帧率补丁改同一处数据 0x40（原值 00）：fps:L 位 6 → 55、目标 60；fps:H 位 7 → 77、目标 120。装载时两份都只登记（同处，先写一份另一份原值校验不过）。
// 期望（手算）：可选档 [60, 120]；跟随开、没选档（单测里屏幕刷新率取不到按 60）→ 只开 L：掩码 0x40、0x40 = 55；包里有高于 60 的档 → 出图链 / 节拍归补丁管、选 60 档即 1 / 60；
//   选 120 → 只开 H：掩码 0x80、0x40 = 77、DM_PRESENT_LINK = 2、DM_PRESENT_HZ = 120；选回 60 → 0x40、55、链 1、节拍 60；跟随关 → 0、00；
//   S2A_FPS_PICK=120 起局（玩家设置）→ 开就是 H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../src/native.h"
void s2a_cpatch_load(module_t *m, const char *dir);
void s2a_cpatch_fps_follow(int on); void s2a_cpatch_fps_pick(int target); int s2a_cpatch_fps_levels(int *out, int n, int *cur);
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static const char *E(const char *k) { const char *v = getenv(k); return v ? v : "-"; }
static void run(const char *dir, int pick_env, char *out, size_t n) {
    int pp[2]; pipe(pp); pid_t c = fork();
    if (c == 0) {
        close(pp[0]); unsetenv("DM_PRESENT_LINK"); unsetenv("DM_PRESENT_HZ"); unsetenv("S2A_CPATCH_ON");
        if (pick_env) setenv("S2A_FPS_PICK", "120", 1); else unsetenv("S2A_FPS_PICK");
        module_t m; memset(&m, 0, sizeof m); snprintf(m.name, sizeof m.name, "%s", "main");
        m.size = 0x8000; m.base = mmap(NULL, m.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); m.key_page_off = 0x4000; m.key_page_size = 0x4000;
        s2a_cpatch_load(&m, dir);
        uint64_t *slot = (uint64_t *)(m.base + m.key_page_off) + 2046; char b[512]; int k = 0, lv[8], cur = 0, nl = s2a_cpatch_fps_levels(lv, 8, &cur);
        k += snprintf(b + k, sizeof b - (size_t)k, "档 %d:", nl); for (int i = 0; i < nl; i++) k += snprintf(b + k, sizeof b - (size_t)k, "%s%d", i ? "/" : "", lv[i]);
        s2a_cpatch_fps_follow(1); k += snprintf(b + k, sizeof b - (size_t)k, " 开 %llx %02x %s %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"));
        if (!pick_env) {
            s2a_cpatch_fps_pick(120); k += snprintf(b + k, sizeof b - (size_t)k, " 选120 %llx %02x %s %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"));
            s2a_cpatch_fps_pick(60); k += snprintf(b + k, sizeof b - (size_t)k, " 选60 %llx %02x %s %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"));
        }
        s2a_cpatch_fps_follow(0); k += snprintf(b + k, sizeof b - (size_t)k, " 关 %llx %02x", (unsigned long long)(*slot & 0xC0), m.base[0x40]);
        write(pp[1], b, (size_t)k); _exit(0);
    }
    close(pp[1]); ssize_t r = read(pp[0], out, n - 1); out[r > 0 ? r : 0] = 0; close(pp[0]); waitpid(c, NULL, 0);
}
int main(void) {
    char dir[] = "/tmp/t_cpatch_levels.XXXXXX"; if (!mkdtemp(dir)) return 1;
    char p[256]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "w");
    fprintf(f, "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\n");
    fprintf(f, "fps:L\tmain\t6\t60fps\t60 帧\t\tl.pchtxt\t40:00:55\t1\t60\t\t\n");
    fprintf(f, "fps:H\tmain\t7\t60fps\t120 帧\t\th.pchtxt\t40:00:77\t1\t120\t\t\n");
    fclose(f);
    char got[512];
    run(dir, 0, got, sizeof got);
    const char *want = "档 2:60/120 开 40 55 1 60 选120 80 77 2 120 选60 40 55 1 60 关 0 00";
    CHECK(!strcmp(got, want), "① 缺省选档 / 切 120 / 切回 60 / 关：期望 %s，实得 %s", want, got);
    run(dir, 1, got, sizeof got);
    const char *want2 = "档 2:60/120 开 80 77 2 120 关 0 00";
    CHECK(!strcmp(got, want2), "② 玩家设置 S2A_FPS_PICK=120 起局：期望 %s，实得 %s", want2, got);
    unlink(p); rmdir(dir);
    if (fails) { printf("✗ t_cpatch_levels：%d 项红\n", fails); return 1; }
    printf("✓ t_cpatch_levels：2 项（缺省按屏幕取档、局中切档、玩家设置起局）\n"); return 0;
}
