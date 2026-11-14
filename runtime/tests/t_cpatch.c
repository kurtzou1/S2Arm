// 社区补丁运行时开关单测（runtime/src/cpatch.c s2a_cpatch_load；10-27）：手工模块（基址 / 键页 mmap），模块目录写 cpatch.tsv 三份 + 别的模块一份：
//   A 位 0 缺省关、无数据；B 位 3 缺省开、数据 0x20 处 11 → 99；C 位 5 缺省开、数据 0x30 处原值写成 77（模块里是 0）→ 对不上；D 是 sdk 模块的行（本模块不计）
// 期望（手算，Apple / Android 同口径，#48 D2）：① 不设 S2A_CPATCH_ON → 槽 2046 = 0x09（11-13 起玩家没选过 = 包里的全开：A、B；C 原值不符不开），0x20 = 0x99、0x30 = 0；② S2A_CPATCH_ON=gfx:A → 0x01，0x20 仍 0x11；
//   ③ none → 0、0x20 仍 0x11；④ S2A_CPATCH_ON=gfx:B,gfx:C → 0x08（C 原值不符照旧不开）。旧代码没有 s2a_cpatch_load：编不过（红）
//   另有 fps:F 位 6 缺省开、数据 0x40 处 00 → 55：① 掩码 0x49（11-13 起没选过 = 包里的全开，A 也开）；⑤ 帧率类跟 60 帧开关：份数 1，装载后 0x49 / 55，关 → 0x09 / 00，开 → 0x49 / 55
// APK 起局（#48 D2）：同一张表读进内存交 s2a_cpatch_load_source（loader.c load_modules_from_source 的路），九项期望与目录装载逐项相同；
//   另加 ⑩ 表里有 NUL 字节 → 报红中止（不出 RESULT）
#include <sys/wait.h>
#include <unistd.h>
#include "../src/native.h"
#include <sys/mman.h>
void s2a_cpatch_load(module_t *m, const char *dir);
void s2a_cpatch_load_source(module_t *m, const void *bytes, size_t length);
void s2a_cpatch_fps_follow(int on); int s2a_cpatch_fps_count(void);
int s2a_cpatch_cheat(const char *file, const char *name, int on);
void s2a_cpatch_aspect(double A); double s2a_cpatch_present_aspect(void); int s2a_cpatch_ws_enabled(const char *dir);
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
        unsetenv("DM_PRESENT_LINK"); unsetenv("DM_PRESENT_HZ");   // ⑤ 核出图链与出图节拍：从没设过开始
        if (on && !strcmp(on, "fixed")) on = "widescreen:auto";
        int followlist = on && !strcmp(on, "followlist"); if (followlist) on = "gfx:A";   // ⑨ 的标记：玩家动过补丁开关、列表里没有帧率补丁（iOS 设置页从不写它），再跟 60 帧开关   // ⑧ 的标记：只开定画幅变体的总编号（自适应一族不开，上屏画幅只看变体）
        if (on && strcmp(on, "follow") && strcmp(on, "cheat") && strcmp(on, "adapt")) setenv("S2A_CPATCH_ON", on, 1); else unsetenv("S2A_CPATCH_ON");   // follow：⑤ 的标记，按表缺省开装载
        module_t m; memset(&m, 0, sizeof m); snprintf(m.name, sizeof m.name, "%s", "main");
        m.size = 0x8000; m.base = mmap(NULL, m.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        m.key_page_off = 0x4000; m.key_page_size = 0x4000; m.base[0x20] = 0x11; float one = 1.0f; memcpy(m.base + 0x3100, &one, 4);
        if (g_source) load_source(&m, dir); else s2a_cpatch_load(&m, dir);
        uint64_t v = ((uint64_t *)(m.base + m.key_page_off))[2046];
        if (on && !strcmp(on, "cheat")) {   // ⑥ 金手指（11-12）：装载不开；逐条开关按「位」逗号表求掩码，同处变体以开着的为准
            uint64_t *s = (uint64_t *)(m.base + m.key_page_off) + 2046; uint64_t c0 = *s & 0x700;
            int r1 = s2a_cpatch_cheat("d.txt", "X", 1); uint64_t c1 = *s & 0x700; uint8_t x1 = m.base[0x50];
            s2a_cpatch_cheat("d.txt", "Y", 1); uint64_t c2 = *s & 0x700; uint8_t x2 = m.base[0x50];
            s2a_cpatch_cheat("d.txt", "X", 0); uint64_t c3 = *s & 0x700; uint8_t x3 = m.base[0x50];
            s2a_cpatch_cheat("d.txt", "Y", 0); uint64_t c4 = *s & 0x700; uint8_t x4 = m.base[0x50];
            int r0 = s2a_cpatch_cheat("d.txt", "不在包里", 1), rz = s2a_cpatch_cheat("d.txt", "Z", 1); uint8_t z = m.base[0x60];
            printf("RESULT %llx %d %llx %02x %llx %02x %llx %02x %llx %02x %d %d %02x %llx\n", (unsigned long long)c0, r1, (unsigned long long)c1, x1, (unsigned long long)c2, x2,
                   (unsigned long long)c3, x3, (unsigned long long)c4, x4, r0, rz, z, (unsigned long long)(*s & ~0x700ull)); fflush(stdout); _exit(0);
        }
        if (on && !strcmp(on, "adapt")) {   // ⑦ 自适应画幅：装载时 16:9 两份都关；2.0 开宽；1.6 换窄；16:9 全关、写回
            uint64_t *s = (uint64_t *)(m.base + m.key_page_off); float *d = (float *)(m.base + 0x3100);
            #define SL(i) (*(float *)(s + (i)))
            #define SX (*(uint32_t *)(s + 1019))
            #define SY (*(uint32_t *)(s + 1020))
            printf("RESULT %llx %.4f %u %u", (unsigned long long)(s[2046] & 0xc00), *d, SX, SY);
            s2a_cpatch_aspect(2.0); printf(" %llx %.4f %.4f %.4f %.4f %u %u", (unsigned long long)(s[2046] & 0xc00), *d, SL(1016), SL(1017), s2a_cpatch_present_aspect(), SX, SY);
            s2a_cpatch_aspect(1.6); printf(" %llx %.4f %.4f %.4f %.4f %.4f %u %u", (unsigned long long)(s[2046] & 0xc00), *d, SL(1016), SL(1017), SL(1018), s2a_cpatch_present_aspect(), SX, SY);
            s2a_cpatch_aspect(16.0 / 9); printf(" %llx %.4f %.4f %.4f %.4f %u %u\n", (unsigned long long)(s[2046] & 0xc00), *d, SL(1016), SL(1018), s2a_cpatch_present_aspect(), SX, SY);
            fflush(stdout); _exit(0);
        }
        if (on && !strcmp(on, "widescreen:auto")) {   // ⑧ 定画幅变体：本款开着宽屏补丁；装载（16:9）不开；2.2 开 2.0；2.4 换 2.5；1.4 开窄 1.5；16:9 全关写回
            uint64_t *s = (uint64_t *)(m.base + m.key_page_off);
            printf("RESULT %d %llx %02x", s2a_cpatch_ws_enabled(dir), (unsigned long long)(s[2046] & 0x7000), m.base[0x3200]);
            const double as[] = {2.2, 2.4, 1.4, 16.0 / 9};
            for (int k = 0; k < 4; k++) { s2a_cpatch_aspect(as[k]); printf(" %llx %02x %.4f", (unsigned long long)(s[2046] & 0x7000), m.base[0x3200], s2a_cpatch_present_aspect()); }
            printf("\n"); fflush(stdout); _exit(0);
        }
        if (followlist || (on && !strcmp(on, "follow"))) {   // ⑤ 帧率类跟 60 帧开关：装载后（缺省开）→ 关 → 开（⑨ 同一流程）
            #define LK() (getenv("DM_PRESENT_LINK") ? getenv("DM_PRESENT_LINK") : "-")
            #define HZ() (getenv("DM_PRESENT_HZ") ? getenv("DM_PRESENT_HZ") : "-")
            char l0[4], l1[4], h0[8], h1[8]; snprintf(l0, sizeof l0, "%s", LK()); snprintf(h0, sizeof h0, "%s", HZ());
            uint64_t v0 = v; uint8_t d0 = m.base[0x40]; s2a_cpatch_fps_follow(0); uint64_t v1 = ((uint64_t *)(m.base + m.key_page_off))[2046]; uint8_t d1 = m.base[0x40]; snprintf(l1, sizeof l1, "%s", LK()); snprintf(h1, sizeof h1, "%s", HZ());
            s2a_cpatch_fps_follow(1); uint64_t v2 = ((uint64_t *)(m.base + m.key_page_off))[2046];
            printf("RESULT %d %llx %02x %llx %02x %llx %02x %s %s %s %s %s %s\n", s2a_cpatch_fps_count(), (unsigned long long)v0, d0, (unsigned long long)v1, d1, (unsigned long long)v2, m.base[0x40], l0, l1, LK(), h0, h1, HZ()); fflush(stdout); _exit(0);
        }
        printf("RESULT %llx %02x %02x\n", (unsigned long long)v, m.base[0x20], m.base[0x30]); fflush(stdout); _exit(0);
    }
    waitpid(c, NULL, 0);
}

int main(void) {
    char dir[] = "/tmp/t_cpatch_XXXXXX"; if (!mkdtemp(dir)) return 2;
    char p[300]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "w");
    fprintf(f, "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\n");
    fprintf(f, "gfx:A\tmain\t0\tother-gfx\t细节层级\tMIT\ta.pchtxt\t\t0\n");
    fprintf(f, "gfx:B\tmain\t3\tother-gfx\t分辨率\t\tb.pchtxt\t20:11:99\t1\n");
    fprintf(f, "gfx:C\tmain\t5\tother-gfx\t坏数据\t\tc.pchtxt\t30:77:88\t1\n");
    fprintf(f, "gfx:D\tsdk\t0\tother-gfx\t别的模块\t\td.pchtxt\t\t1\n");
    fprintf(f, "fps:F\tmain\t6\t60fps\t60 帧\t\tf.pchtxt\t40:00:55\t1\t120\n");   // 目标 120：⑤ 跟随开时出图链放开到 60–120 Hz（DM_PRESENT_LINK=2），关时回 1
    // 金手指 X 位 8,9（共享挂钩 8 + 自己的 9）开关字 0x50 → 01；Y 位 8、同处变体 → 02；Z 不占位、0x60 → 07；缺省开列写 1 也不开（金手指一律等玩家开）
    fprintf(f, "cheat:ab:1\tmain\t8,9\tcheat\tX\t\td.txt\t50:00:01\t1\n");
    fprintf(f, "cheat:ab:2\tmain\t8\tcheat\tY\t\td.txt\t50:00:02\t0\n");
    fprintf(f, "cheat:ab:3\tmain\t-\tcheat\tZ\t\td.txt\t60:00:07\t0\n");
    // 自适应画幅一族（宽位 10 / 窄位 11）：0x3100 原值 1.0 → @a4；宽写槽 1016 = A、1017 = A÷(16/9)；窄写 1016 = A、1018 = (16/9)÷A
    //   两份都写槽 1019 = @x4（渲染宽度整数 = 1080 × A 取偶，11-13 分辨率目录一族合成）
    fprintf(f, "wsauto:fam:w\tmain\t10\twidescreen\t宽\t\tw.pchtxt\t3100:0000803f:@a4 k1016::@a4 k1017::@w4 k1019::@x4 k1020::@y4/864\t1\n");
    fprintf(f, "wsauto:fam:n\tmain\t11\twidescreen\t窄\t\tw.pchtxt\t3100:0000803f:@a4 k1016::@a4 k1018::@n4 k1019::@x4 k1020::@y4/864\t1\n");
    // 定画幅宽屏变体（第 11 列画幅；位 12 / 13 / 14，同一处数据 0x3200 原值 00 → 20 / 25 / 15）
    fprintf(f, "widescreen:V1\tmain\t12\twidescreen\t2:1\t\tv.pchtxt\t3200:00:20\t0\t\t2.0000\n");
    fprintf(f, "widescreen:V2\tmain\t13\twidescreen\t5:2\t\tv.pchtxt\t3200:00:25\t0\t\t2.5000\n");
    fprintf(f, "widescreen:V3\tmain\t14\twidescreen\t3:2\t\tv.pchtxt\t3200:00:15\t0\t\t1.5000\n");
    fclose(f);
    // ⑧ 手算（S2A_CPATCH_ON=widescreen:auto）：本款开着宽屏补丁 → 1；装载 16:9 → 0、00；2.2：|ln(2/2.2)| = 0.095 < |ln(2.5/2.2)| = 0.128 → V1 位 12 = 0x1000、20、上屏 2.0；
    //   2.4：|ln(2.5/2.4)| = 0.041 < 0.182 → V2 0x2000、25、2.5；1.4 比 16:9 窄 → 只看窄的 V3 0x4000、15、1.5；16:9 → 0、写回 00、0
    // ⑦ 手算：装载（画幅缺省 16:9）位 10/11 都清、0x3100 = 1.0；2.0 → 位 10 = 0x400、2.0、槽 1016 = 2.0、1017 = 2 ÷ 1.7778 = 1.125、上屏画幅 2.0；
    //   1.6 → 位 11 = 0x800、1.6、1016 = 1.6、1017 写回 0、1018 = 1.7778 ÷ 1.6 = 1.1111、上屏 1.6；16:9 → 0、1.0、1016 = 0、1018 = 0、上屏 0
    //   槽 1019（@x4）：装载 0；2.0 → 1080 × 2.0 = 2160；1.6 → 1080 × 1.6 = 1728；16:9 写回 0
    //   槽 1020（@y4/864，另一档）：2.0 → 864 × 2.0 = 1728；1.6 → 864 × 1.6 = 1382.4 → 取偶 1382；16:9 写回 0
    // ⑤ follow：份数 1；装载后掩码 0x49（A 位 0 + B 位 3 + F 位 6）、0x40 = 55；关 → 0x09、00；开 → 0x49、55；
    //   出图链（F 目标 120，补丁优先）：跟随前没动 -、关 → 1（60 Hz）、开 → 2（60–120 Hz）
//   出图节拍 DM_PRESENT_HZ 同理：跟随前 -、关 → 60、开 → 120（补丁目标；不放开节拍游戏间隔 1 照样只出 60 帧）
    // ⑥ 手算：装载后金手指位 0；X 开 → 位 8|9 = 0x300、0x50 = 01；Y 也开 → 0x300、0x50 = 02（后开的变体）；X 关 → 只剩 Y 的位 8 = 0x100、0x50 = 02；
    //   Y 关 → 0、0x50 写回 00；不在包里的条目 → 0；Z（不占位）→ 1、0x60 = 07；其余位（A 位 0 / B 位 3 / F 位 6）不受影响：缺省 0x09
#define CHEAT_CASE {"cheat", "0 1 300 01 300 02 100 02 0 00 0 1 07 9"}   // 11-13 起帧率类 F 装载时只登记、起局跟随才开（单测不跟随）：其余位 0x09
#define FIXED_CASE {"fixed", "1 0 00 1000 20 2.0000 2000 25 2.5000 4000 15 1.5000 0 00 0.0000"}
    // 11-13 起帧率类装载时只登记、不写不开（几档改同一处，cpatch.c fps_pick），位与 0x40 由跟随定：① 装载后 0x09（不再含 F 的位 6）、⑤ 装载后 0x09 / 00
    const char *cases[][2] = {{NULL, "9 99 00"}, {"gfx:A", "1 11 00"}, {"none", "0 11 00"}, {"gfx:B,gfx:C", "8 99 00"}, {"follow", "1 9 00 9 00 49 55 - 1 2 - 60 120"}, CHEAT_CASE,
                              {"adapt", "0 1.0000 0 0 400 2.0000 2.0000 1.1250 2.0000 2160 1728 800 1.6000 1.6000 0.0000 1.1111 1.6000 1728 1382 0 1.0000 0.0000 0.0000 0.0000 0 0"}, FIXED_CASE,
                              // ⑨ 手算（11-13 实机那局）：列表 gfx:A → 装载 A 开 0x01、F 不在列表不开（0x40 = 00）；跟随关 → 0x01 / 00、链 1 / 节拍 60；
                              //   跟随开 → 0x41 / 55、链 2 / 节拍 120（目标取所有帧率补丁的 120；旧代码只取列表里的 → 目标 0，链 / 节拍三处都是 -）
                              {"followlist", "1 1 00 1 00 41 55 - 1 2 - 60 120"}};
    for (int k = 0; k < 19; k++) {   // 0–8 目录装载，9–17 APK 内存表，18 = ⑩ 内存表带 NUL
        int i = k % 9; const char *on = k == 18 ? "gfx:B" : cases[i][0], *want = k == 18 ? "?" : cases[i][1];
        g_source = k >= 9; g_nul = k == 18;
        int pp[2]; pipe(pp); pid_t c = fork();
        if (c == 0) { dup2(pp[1], 1); close(pp[0]); run(dir, on); _exit(0); }
        close(pp[1]); char buf[4096] = {0}; size_t n = 0; ssize_t r; while ((r = read(pp[0], buf + n, sizeof buf - 1 - n)) > 0) n += (size_t)r; close(pp[0]); waitpid(c, NULL, 0);
        char *res = strstr(buf, "RESULT "); char got[256] = "?"; if (res) { sscanf(res + 7, "%255[^\n]", got); }
        CHECK(!strcmp(got, want), "%s%s S2A_CPATCH_ON=%s：期望 %s，实得 %s", k >= 9 ? "[APK 内存表] " : "", k == 18 ? "⑩ 表带 NUL 报红" : i == 0 ? "①" : i == 1 ? "②" : i == 2 ? "③" : i == 3 ? "④" : i == 4 ? "⑤ 帧率类跟 60 帧开关（份数 / 掩码与 0x40：装载后、关、开）" : i == 5 ? "⑥ 金手指逐条开关（掩码 / 开关字 / 不在包里 / 不占位）" : i == 6 ? "⑦ 自适应画幅（宽 / 窄模板随画幅、值槽与数据按画幅算、16:9 全关写回）" : i == 8 ? "⑨ 列表里没有帧率补丁时目标帧率照取（出图链 / 节拍跟到 120）" : "⑧ 定画幅宽屏变体（按画幅选最近同侧一份、上屏按它铺满、16:9 全关写回）", on ? on : "(不设)", want, got);
    }
    unlink(p); rmdir(dir);
    if (fails) { printf("✗ t_cpatch：%d 项红\n", fails); return 1; }
    printf("✓ t_cpatch：19 项（目录装载与 APK 内存表各 9 项 + 内存表带 NUL 报红：没选过 = 包里全开 / 只开 A / 全关 / 原值不符不开 / 帧率类跟 60 帧开关 / 金手指逐条开关 / 自适应画幅 / 定画幅变体 / 列表外帧率补丁目标照取）\n");
    return 0;
}
