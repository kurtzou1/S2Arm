// 社区补丁运行时开关单测（runtime/src/cpatch.c s2a_cpatch_load；10-27）：手工模块（基址 / 键页 mmap），模块目录写 cpatch.tsv 三份 + 别的模块一份：
//   A 位 0 缺省关、无数据；B 位 3 缺省开、数据 0x20 处 11 → 99；C 位 5 缺省开、数据 0x30 处原值写成 77（模块里是 0）→ 对不上；D 是 sdk 模块的行（本模块不计）
// 期望（手算，Apple / Android 同口径，#48 D2）：① 不设 S2A_CPATCH_ON → 槽 2046 = 0x08（只 B；C 原值不符不开），0x20 = 0x99、0x30 = 0；② S2A_CPATCH_ON=gfx:A → 0x01，0x20 仍 0x11；
//   ③ none → 0、0x20 仍 0x11；④ S2A_CPATCH_ON=gfx:B,gfx:C → 0x08（C 原值不符照旧不开）。旧代码没有 s2a_cpatch_load：编不过（红）
//   另有 fps:F 位 6 缺省开、数据 0x40 处 00 → 55：① 掩码 0x48；⑤ 帧率类跟 60 帧开关：份数 1，装载后 0x48 / 55，关 → 0x08 / 00，开 → 0x48 / 55
// APK 起局（#48 D2）：同一张表读进内存交 s2a_cpatch_load_source（loader.c load_modules_from_source 的路），五项期望与目录装载逐项相同；
//   另加 ⑥ 表里有 NUL 字节 → 报红中止（不出 RESULT）
#include <sys/wait.h>
#include <unistd.h>
#include "../src/native.h"
#include <sys/mman.h>
void s2a_cpatch_load(module_t *m, const char *dir);
void s2a_cpatch_load_source(module_t *m, const void *bytes, size_t length);
void s2a_cpatch_fps_follow(int on); int s2a_cpatch_fps_count(void);
static int fails, g_source, g_nul;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void load_source(module_t *m, const char *dir) {
    char p[300]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "rb"); if (!f) _exit(3);
    static char buf[1 << 14]; size_t n = fread(buf, 1, sizeof buf, f); fclose(f);
    if (g_nul) buf[n / 2] = 0;
    s2a_cpatch_load_source(m, buf, n);
}

static void run(const char *dir, const char *on) {
    pid_t c = fork();
    if (c == 0) {
        if (on && strcmp(on, "follow")) setenv("S2A_CPATCH_ON", on, 1); else unsetenv("S2A_CPATCH_ON");   // follow：⑤ 的标记，按表缺省开装载
        module_t m; memset(&m, 0, sizeof m); snprintf(m.name, sizeof m.name, "%s", "main");
        m.size = 0x8000; m.base = mmap(NULL, m.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        m.key_page_off = 0x4000; m.key_page_size = 0x4000; m.base[0x20] = 0x11;
        if (g_source) load_source(&m, dir); else s2a_cpatch_load(&m, dir);
        uint64_t v = ((uint64_t *)(m.base + m.key_page_off))[2046];
        if (on && !strcmp(on, "follow")) {   // ⑤ 帧率类跟 60 帧开关：装载后（缺省开）→ 关 → 开
            uint64_t v0 = v; uint8_t d0 = m.base[0x40]; s2a_cpatch_fps_follow(0); uint64_t v1 = ((uint64_t *)(m.base + m.key_page_off))[2046]; uint8_t d1 = m.base[0x40];
            s2a_cpatch_fps_follow(1); uint64_t v2 = ((uint64_t *)(m.base + m.key_page_off))[2046];
            printf("RESULT %d %llx %02x %llx %02x %llx %02x\n", s2a_cpatch_fps_count(), (unsigned long long)v0, d0, (unsigned long long)v1, d1, (unsigned long long)v2, m.base[0x40]); fflush(stdout); _exit(0);
        }
        printf("RESULT %llx %02x %02x\n", (unsigned long long)v, m.base[0x20], m.base[0x30]); fflush(stdout); _exit(0);
    }
    waitpid(c, NULL, 0);
}

int main(void) {
    char dir[] = "/tmp/t_cpatch_XXXXXX"; if (!mkdtemp(dir)) return 2;
    char p[300]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "w");
    fprintf(f, "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n");
    fprintf(f, "gfx:A\tmain\t0\tother-gfx\t细节层级\tMIT\ta.pchtxt\t\t0\n");
    fprintf(f, "gfx:B\tmain\t3\tother-gfx\t分辨率\t\tb.pchtxt\t20:11:99\t1\n");
    fprintf(f, "gfx:C\tmain\t5\tother-gfx\t坏数据\t\tc.pchtxt\t30:77:88\t1\n");
    fprintf(f, "gfx:D\tsdk\t0\tother-gfx\t别的模块\t\td.pchtxt\t\t1\n");
    fprintf(f, "fps:F\tmain\t6\t60fps\t60 帧\t\tf.pchtxt\t40:00:55\t1\n");
    fclose(f);
    // ⑤ follow：份数 1；装载后掩码 0x48（B 位 3 + F 位 6）、0x40 = 55；关 → 0x08、00；开 → 0x48、55
    const char *cases[][2] = {{NULL, "48 99 00"}, {"gfx:A", "1 11 00"}, {"none", "0 11 00"}, {"gfx:B,gfx:C", "8 99 00"}, {"follow", "1 48 55 8 00 48 55"}};
    for (int k = 0; k < 11; k++) {   // 0–4 目录装载，5–9 APK 内存表，10 = ⑥ 内存表带 NUL
        int i = k % 5; const char *on = k == 10 ? "gfx:B" : cases[i][0], *want = k == 10 ? "?" : cases[i][1];
        g_source = k >= 5; g_nul = k == 10;
        int pp[2]; pipe(pp); pid_t c = fork();
        if (c == 0) { dup2(pp[1], 1); close(pp[0]); run(dir, on); _exit(0); }
        close(pp[1]); char buf[4096] = {0}; size_t n = 0; ssize_t r; while ((r = read(pp[0], buf + n, sizeof buf - 1 - n)) > 0) n += (size_t)r; close(pp[0]); waitpid(c, NULL, 0);
        char *res = strstr(buf, "RESULT "); char got[64] = "?"; if (res) { sscanf(res + 7, "%63[^\n]", got); }
        CHECK(!strcmp(got, want), "%s%s S2A_CPATCH_ON=%s：期望 %s，实得 %s", k >= 5 ? "[APK 内存表] " : "",
              k == 10 ? "⑥ 表带 NUL 报红" : i == 0 ? "①" : i == 1 ? "②" : i == 2 ? "③" : i == 3 ? "④" : "⑤ 帧率类跟 60 帧开关（份数 / 掩码与 0x40：装载后、关、开）", on ? on : "(不设)", want, got);
    }
    unlink(p); rmdir(dir);
    if (fails) { printf("✗ t_cpatch：%d 项红\n", fails); return 1; }
    printf("✓ t_cpatch：11 项（缺省按表 / 只开 A / 全关 / 原值不符不开 / 帧率类跟 60 帧开关，目录与 APK 内存表各一遍；内存表带 NUL 报红）\n");
    return 0;
}
