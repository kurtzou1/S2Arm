// 帧率表（runtime/src/fps.c）单测：假模块 + 临时表，等写入线程转一轮，核无条件写、按条件写（两条互斥）、坏条件行被拒、present display 设环境变量；
// 键页先封只读（模块没有宽屏表），写槽不崩；运行中关 / 开 60 帧（w 行写回原值、槽写关时值、钩子退回游戏间隔）。旧代码反证：不改可写那一版在写槽 2041 初值时 SIGBUS
#include "../src/native.h"
#include <unistd.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/wait.h>
S2A_TEST_MOD_TABLE(64); int g_nmod;
const char *s2a_main_build_id(void) { return "1234abcd5678ef00aaaa"; }
void s2a_fps_start(const char *dir); int s2a_fps_present_at(uint64_t now); void s2a_fps_set_enabled(int on); int s2a_fps_enabled(void); int s2a_fps_available(void); int s2a_fps_hot_revert_ok(void);
int s2a_fps_cap_reason(void); void s2a_fps_ab_set(int phase);
static int g_capped_n, g_capped_last = -9;   // 降档 / 恢复提示替身（ios/app.m s2a_ios_fps_capped，审计 P1-80）
void s2a_ios_fps_capped(int reason) { g_capped_n++; g_capped_last = reason; }
extern uint8_t *dm_fps_state;   // 宿主帧步状态页（fps.c 强定义；本单测不链 hle_nvn，+0x20 步长由测试手写，模拟 fstep_tick）
static float fs_f32(int off) { float x; uint32_t b = *(uint32_t *)(dm_fps_state + off); memcpy(&x, &b, 4); return x; }
static int fails;
static int g_follow_n, g_follow_last = -1;   // 社区帧率补丁跟随钩子的强定义桩：记调用次数和最后一次的值
void s2a_cpatch_fps_follow(int on) { g_follow_n++; g_follow_last = on; }
static void expect(const char *what, long want, long got) { printf("%s 期望 %ld → 真结果 %ld\n", what, want, got); if (want != got) fails++; }
int main(void) {
    static uint8_t img[0x8000] __attribute__((aligned(0x4000)));   // 键页在 0x4000（2048 个 8 字节槽），按 16 KB 页对齐才能 mprotect
    module_t *m = &g_mod[g_nmod++]; strlcpy(m->name, "main", sizeof m->name); m->base = img; m->size = sizeof img; m->data_off = 0x1000; m->patch_off = 0x2000; m->key_page_off = 0x4000; m->key_page_size = 0x4000;
    if (mprotect(img + 0x4000, 0x4000, PROT_READ)) return 1;   // 装载器把键页封只读；本模块没有宽屏表，帧率表得自己改可写，否则写槽崩（原生层线 10-26）
    char dir[] = "/tmp/t_fps_XXXXXX"; if (!mkdtemp(dir)) return 1;
    char path[256]; snprintf(path, sizeof path, "%s/fps.tsv", dir); FILE *f = fopen(path, "w");
    fprintf(f, "# 单测表\nbuild 1234abcd5678ef00\npresent display\n"
               "w main 0x1000 i32 60 off 30\n"   // 写了关值：运行中关写 30
               
               "w main 0x1004 i32 1 if main 0x1010 u8 == 0\n"
               "w main 0x1004 i32 2 if main 0x1010 u8 != 0\n"
               "w main 0x1008 i32 7 if main 0x0100 u8 == 0\n"   // 条件地址在代码段：整行拒
               "c main 0x100 word 3942f661 52800021\n"          // 改指令行：运行时跳过
               "slot 2041 f32 200 100\nslot 2042 i32 1\nspeed 2040 0.5 2.0\npresent30 if slot 2042 == 0\n");
    fclose(f);
    {   // speed 行带秒槽（11-06 王国之泪布料 / 头发时钟改读实测秒数）。期望手算：33.3 ms → 步长 1.0、秒 1/30 = 0.0333；16.7 ms → 0.5、0.01667；
        //   运行中关 → 步长 1.0、秒 1/30；秒槽与步长槽相同 → 整行报红、两槽都不写（仍是上一张表留下的值）。旧实现：秒槽不写（仍 0）→ 红
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) {
            fails = 0; dm_fps_state = NULL; setenv("S2A_FSTEP", "0", 1); setenv("S2A_FPS60", "1", 1);   /* 玩家开了（11-11 起默认关） */
            char d2[] = "/tmp/t_fps_sec_XXXXXX"; if (!mkdtemp(d2)) _exit(99);
            char p2[256]; snprintf(p2, sizeof p2, "%s/fps.tsv", d2); FILE *f2 = fopen(p2, "w");
            fprintf(f2, "build 1234abcd5678ef00\nspeed 2040 0.5 2.0 2043\n"); fclose(f2);
            s2a_fps_start(d2);
            float r, sc; uint64_t t2 = 5000000000ull; s2a_fps_present_at(t2);
            s2a_fps_present_at(t2 += 33333333); memcpy(&r, img + 0x4000 + 2040 * 8, 4); memcpy(&sc, img + 0x4000 + 2043 * 8, 4);
            expect("秒槽：33.3 ms → 步长 1.0（×100）", 100, lroundf(r * 100)); expect("秒槽：33.3 ms → 秒 0.0333（×10000）", 333, lroundf(sc * 10000));
            s2a_fps_present_at(t2 += 16666667); memcpy(&r, img + 0x4000 + 2040 * 8, 4); memcpy(&sc, img + 0x4000 + 2043 * 8, 4);
            expect("秒槽：16.7 ms → 步长 0.5（×100）", 50, lroundf(r * 100)); expect("秒槽：16.7 ms → 秒 0.01667（×100000）", 1667, lroundf(sc * 100000));
            s2a_fps_set_enabled(0); memcpy(&r, img + 0x4000 + 2040 * 8, 4); memcpy(&sc, img + 0x4000 + 2043 * 8, 4);
            expect("秒槽：运行中关 → 步长 1.0（×100）", 100, lroundf(r * 100)); expect("秒槽：运行中关 → 秒 1/30（×10000）", 333, lroundf(sc * 10000));
            fflush(stdout); _exit(fails);
        }
        int ws = 0; waitpid(p, &ws, 0); expect("秒槽子进程：不符项数", 0, WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
        fflush(stdout); p = fork(); if (p < 0) return 1;
        if (!p) {
            fails = 0; dm_fps_state = NULL; setenv("S2A_FSTEP", "0", 1);
            char d3[] = "/tmp/t_fps_sec2_XXXXXX"; if (!mkdtemp(d3)) _exit(99);
            char p3[256]; snprintf(p3, sizeof p3, "%s/fps.tsv", d3); FILE *f3 = fopen(p3, "w");
            fprintf(f3, "build 1234abcd5678ef00\nspeed 2044 0.5 2.0 2044\n"); fclose(f3);
            float z = 7.0f; mprotect(img + 0x4000, 0x4000, PROT_READ | PROT_WRITE); memcpy(img + 0x4000 + 2044 * 8, &z, 4); s2a_fps_start(d3); s2a_fps_present_at(9000000000ull); s2a_fps_present_at(9016666667ull);
            float r; memcpy(&r, img + 0x4000 + 2044 * 8, 4); expect("秒槽与步长槽相同：整行拒、槽不写（仍 7）", 7, lroundf(r)); expect("秒槽与步长槽相同：表装上了（build 行通过、不是被拒装）", 1, s2a_fps_available());
            fflush(stdout); _exit(fails);
        }
        waitpid(p, &ws, 0); expect("秒槽同槽子进程：不符项数", 0, WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
    }
    {   // 超长行（11-06 旷野之息表：中文注释 279 / 293 字节，超出 256 字节缓冲的那截被当成下一行报「不认的行」红）。期望手写：
        //   ① 数据段短、注释超长的 w 行照常写（main+0x1018 = 5）、紧跟的 slot 2043 照常写（7）、日志里没有「不认的行」；
        //   ② 数据段本身超长（没有 #、超过 255 字节）→ 报「行超过」红、不写（main+0x101c 仍 0），它后面的 slot 2044 照常写（9）。旧实现：①日志有「不认的行」→ 红
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) {
            fails = 0; dm_fps_state = NULL; setenv("S2A_FSTEP", "0", 1); setenv("S2A_FPS60", "1", 1);   /* 玩家开了（11-11 起默认关） */
            char d4[] = "/tmp/t_fps_long_XXXXXX"; if (!mkdtemp(d4)) _exit(99);
            char p4[256]; snprintf(p4, sizeof p4, "%s/fps.tsv", d4); FILE *f4 = fopen(p4, "w");
            char cm[400]; memset(cm, 0, sizeof cm); for (int k = 0; k < 110; k++) strcat(cm, "注");   // 330 字节中文注释
            char dl[300]; memset(dl, 0, sizeof dl); strcpy(dl, "w main 0x101c i32 3 "); while (strlen(dl) < 290) strcat(dl, "* ");
            fprintf(f4, "build 1234abcd5678ef00\nw main 0x1018 i32 5 # %s\nslot 2043 i32 7\n%s\nslot 2044 i32 9\n", cm, dl); fclose(f4);
            char lg[256]; snprintf(lg, sizeof lg, "%s/err.log", d4); fflush(stderr); int se = dup(2); FILE *ef = fopen(lg, "w"); dup2(fileno(ef), 2);
            s2a_fps_start(d4); usleep(250000); fflush(stderr); dup2(se, 2); fclose(ef);
            int32_t v1, v2; memcpy(&v1, img + 0x1018, 4); memcpy(&v2, img + 0x101c, 4);
            int32_t s3, s4; memcpy(&s3, img + 0x4000 + 2043 * 8, 4); memcpy(&s4, img + 0x4000 + 2044 * 8, 4);
            FILE *rf = fopen(lg, "r"); char buf[8192] = ""; size_t nr = rf ? fread(buf, 1, sizeof buf - 1, rf) : 0; buf[nr] = 0; if (rf) fclose(rf);
            expect("超长行①：注释超长的 w 行照常写 main+0x1018 = 5", 5, v1);
            expect("超长行①：紧跟的 slot 2043 照常写 7", 7, s3);
            expect("超长行①：日志里没有「不认的行」", 0, strstr(buf, "不认的行") != NULL);
            expect("超长行②：数据段超长 → 报「行超过」红", 1, strstr(buf, "行超过") != NULL);
            expect("超长行②：数据段超长的 w 行不写（main+0x101c 仍 0）", 0, v2);
            expect("超长行②：它后面的 slot 2044 照常写 9", 9, s4);
            fflush(stdout); _exit(fails);
        }
        int ws = 0; waitpid(p, &ws, 0); expect("超长行子进程：不符项数", 0, WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
    }
    // 起局开关只认 S2A_FPS60（#619 F-fps-cap-disables-table）：起局状态是进程级的，每种组合在子进程里起一次；表目录不存在 = 只走开关那一步。期望手写：
    //   帧率上限 S2A_FPS=30、S2A_FPS60 未设 → 关 0（11-11：默认原帧率、玩家手动开）；S2A_FPS60=0 → 关 0；S2A_FPS=30 且 S2A_FPS60=1 → 开 1；S2A_FPS=120 且 S2A_FPS60=0 → 关 0；
    //   S2A_FPS60=00（不是整串 1）→ 关 0
    static const struct { const char *cap, *f60; int want; } st[] = {{"30", NULL, 0}, {NULL, "0", 0}, {"30", "1", 1}, {"120", "0", 0}, {NULL, "00", 0}};
    for (int i = 0; i < 5; i++) {
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) {
            if (st[i].cap) setenv("S2A_FPS", st[i].cap, 1); else unsetenv("S2A_FPS");
            if (st[i].f60) setenv("S2A_FPS60", st[i].f60, 1); else unsetenv("S2A_FPS60");
            s2a_fps_start("/nonexistent/t_fps"); _exit(s2a_fps_enabled());
        }
        int ws = 0; waitpid(p, &ws, 0); char what[128];
        snprintf(what, sizeof what, "起局 S2A_FPS=%s、S2A_FPS60=%s：60 帧表开", st[i].cap ? st[i].cap : "（未设）", st[i].f60 ? st[i].f60 : "（未设）");
        expect(what, st[i].want, WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
    }
    // 起局就关（S2A_FPS60=0，表里有 present display）：关 = 三层都不动。期望手写：DM_PRESENT_INTERVAL 不设（L1 按游戏间隔）；w 行一处不写（数据区仍是初值 0）；
    //   slot 2041 写关时值 100、速度槽 1.0（改写器打进代码的读槽指令一直在，槽必须有 30 帧口径的值）；钩子返回 1。旧实现第 1 项红（照设 display，10-28 巫师3 关局帧节拍报 60）
    {
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) {
            fails = 0; unsetenv("DM_PRESENT_INTERVAL"); unsetenv("S2A_FPS_TABLE"); unsetenv("S2A_FPS"); setenv("S2A_FPS60", "0", 1);
            s2a_fps_start(dir); usleep(250000);
            const char *e = getenv("DM_PRESENT_INTERVAL"); expect("起局关：不设 DM_PRESENT_INTERVAL（L1 交换间隔按游戏）", 0, e != NULL);
            int32_t a; memcpy(&a, img + 0x1000, 4); expect("起局关：w 行 main+0x1000 不写（仍 0）", 0, a);
            memcpy(&a, img + 0x1004, 4); expect("起局关：条件 w 行 main+0x1004 不写（仍 0）", 0, a);
            float f2; memcpy(&f2, img + 0x4000 + 2041 * 8, 4); expect("起局关：slot 2041 写关时值 100（×1000）", 100000, (long)(f2 * 1000));
            memcpy(&f2, img + 0x4000 + 2040 * 8, 4); expect("起局关：速度槽 1.0（×100）", 100, lroundf(f2 * 100));
            expect("起局关：钩子返回 1（出图不放开）", 1, s2a_fps_present_at(1000000000ull));
            expect("起局关：s2a_fps_enabled", 0, s2a_fps_enabled());
            fflush(stdout); _exit(fails);
        }
        int ws = 0; waitpid(p, &ws, 0);
        expect("起局关子进程：不符项数", 0, WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
    }
    // build 行只写 8 位前缀（审计 P1-93）：是本包构建号的前缀，但不足 16 位十六进制，必须整表不用。期望手写：w 行一处不写（仍 0）、slot 2041 不写（仍 0）。
    //   旧实现（只比 strlen(b) 位前缀）这里 main+0x1000 写成 60 → 红
    {
        char p2[300]; snprintf(p2, sizeof p2, "%s/short.tsv", dir); FILE *g = fopen(p2, "w");
        fprintf(g, "build 1234abcd\nw main 0x1000 i32 60\nslot 2041 f32 200 100\n"); fclose(g);
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) {
            fails = 0; setenv("S2A_FPS_TABLE", p2, 1); unsetenv("S2A_FPS"); setenv("S2A_FPS60", "1", 1);   /* 玩家开了 */
            s2a_fps_start(dir); usleep(250000);
            int32_t a; memcpy(&a, img + 0x1000, 4); expect("build 只有 8 位前缀：整表不用，main+0x1000 不写（仍 0）", 0, a);
            float f2; memcpy(&f2, img + 0x4000 + 2041 * 8, 4); expect("build 只有 8 位前缀：slot 2041 不写（仍 0）", 0, (long)(f2 * 1000));
            fflush(stdout); _exit(fails);
        }
        int ws = 0; waitpid(p, &ws, 0);
        expect("短构建号子进程：不符项数", 0, WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
    }
    unsetenv("DM_PRESENT_INTERVAL"); unsetenv("S2A_FPS"); setenv("S2A_FPS60", "1", 1); unsetenv("S2A_FPS_TABLE");   /* 玩家开了 */
    s2a_fps_start(dir);
    usleep(250000);
    int32_t v; memcpy(&v, img + 0x1000, 4); expect("无条件写 main+0x1000", 60, v);
    memcpy(&v, img + 0x1004, 4); expect("条件标志 0：main+0x1004 写「== 0」那条", 1, v);
    img[0x1010] = 1; usleep(250000);
    memcpy(&v, img + 0x1004, 4); expect("条件标志改 1：main+0x1004 写「!= 0」那条", 2, v);
    memcpy(&v, img + 0x1008, 4); expect("条件地址不在数据段的行被拒：main+0x1008 不写", 0, v);
    float fv; memcpy(&fv, img + 0x4000 + 2041 * 8, 4); expect("slot 2041 初值 200（×1000）", 200000, (long)(fv * 1000));
    memcpy(&v, img + 0x4000 + 2042 * 8, 4); expect("slot 2042 初值 1", 1, v);
    uint64_t t = 1000000000ull; s2a_fps_present_at(t);   // 时间戳精确给（纳秒），不靠 usleep：机器有负载时 33 ms 的 usleep 睡了约 40 ms
    s2a_fps_present_at(t += 33333333); memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("间隔 33.3 ms：速度槽 1.0（×100 取整）", 100, lroundf(fv * 100));
    s2a_fps_present_at(t += 16666667); memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("间隔 16.7 ms：速度槽 0.5（×100 取整）", 50, lroundf(fv * 100));
    s2a_fps_present_at(t += 8000000); memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("间隔 8 ms：夹到下限 0.5（×100 取整）", 50, lroundf(fv * 100));
    s2a_fps_present_at(t += 100000000); memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("间隔 100 ms：夹到上限 2.0（×100 取整）", 200, lroundf(fv * 100));
    s2a_fps_present_at(t += 1500000000ull); memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("间隔 1.5 秒（读档 / 暂停）：不更新，仍 2.0（×100 取整）", 200, lroundf(fv * 100));
    expect("过场槽 = 1：钩子不退回游戏间隔", 0, s2a_fps_present_at(t += 16666667));
    v = 0; memcpy(img + 0x4000 + 2042 * 8, &v, 4); expect("过场槽改 0：钩子退回游戏间隔", 1, s2a_fps_present_at(t += 16666667));
    const char *pi = getenv("DM_PRESENT_INTERVAL"); expect("present display 设 DM_PRESENT_INTERVAL=display", 1, pi && !strcmp(pi, "display"));
    // 运行中关 / 开（维护者 10-27：设置里启停）。期望手算：关 → 写了关值的 w 行写关值 30（11-02：不再写回首次读到的原值）、没写关值的条件行不碰（仍开时值 1），slot 2041 写关时值 100，速度槽固定 1.0，钩子返回 1（退回游戏间隔）且不再改速度槽；
    //   再开 → w 行回 60，slot 2041 回 200，钩子按帧间隔写速度槽（16.7 ms → 0.5）
    expect("有表：s2a_fps_available", 1, s2a_fps_available());
    expect("起局通知 cpatch 跟随一次（开）", 1, g_follow_n); expect("起局跟随值 1", 1, g_follow_last); expect("起局开：s2a_fps_enabled", 1, s2a_fps_enabled());
    int32_t pre1004; memcpy(&pre1004, img + 0x1004, 4);   // 关之前条件行的开时值（条件选中哪个就是哪个）
    s2a_fps_set_enabled(0); usleep(250000);
    expect("关：通知 cpatch 跟随（第 2 次）", 2, g_follow_n); expect("关：跟随值 0", 0, g_follow_last);
    s2a_fps_set_enabled(0); expect("重复关：不再通知", 2, g_follow_n);
    memcpy(&v, img + 0x1000, 4); expect("关：main+0x1000 写关值 30", 30, v);
    memcpy(&v, img + 0x1004, 4); expect("关：没写关值的条件行 main+0x1004 不碰（仍是关之前的开时值，重启后生效）", pre1004, v);
    expect("有 w 行没写关值：运行中关退不完（s2a_fps_hot_revert_ok 0）", 0, s2a_fps_hot_revert_ok());
    memcpy(&fv, img + 0x4000 + 2041 * 8, 4); expect("关：slot 2041 写关时值 100（×1000）", 100000, (long)(fv * 1000));
    memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("关：速度槽固定 1.0（×100）", 100, lroundf(fv * 100));
    expect("关：钩子返回 1（退回游戏间隔）", 1, s2a_fps_present_at(t += 16666667));
    s2a_fps_present_at(t += 16666667); memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("关：钩子不改速度槽，仍 1.0（×100）", 100, lroundf(fv * 100));
    s2a_fps_set_enabled(1); usleep(250000);
    expect("再开：通知 cpatch 跟随（第 3 次）、值 1", 31, g_follow_n * 10 + g_follow_last);
    memcpy(&v, img + 0x1000, 4); expect("再开：main+0x1000 回 60", 60, v);
    memcpy(&fv, img + 0x4000 + 2041 * 8, 4); expect("再开：slot 2041 回 200（×1000）", 200000, (long)(fv * 1000));
    v = 1; memcpy(img + 0x4000 + 2042 * 8, &v, 4);   // 过场标记 = 1（没在放）：钩子不退回
    s2a_fps_present_at(t += 16666667); memcpy(&fv, img + 0x4000 + 2040 * 8, 4); expect("再开：钩子按 16.7 ms 写速度槽 0.5（×100）", 50, lroundf(fv * 100));
    expect("再开：过场标记 1 时钩子不退回", 0, s2a_fps_present_at(t += 16666667));
    // 宿主帧步（10-29 维护者）：表里有 speed 行 → 接状态页。期望手算：开着目标 60；+0x20 步长 1 / 2 / 3 → 速度槽 0.5 / 1.0 / 1.5（步长 × 1/60 ÷ 1/30），
    //   与两帧间隔无关（帧步在跑时出图按它保持）；步长 0（通用模式、帧步没在跑）→ 照旧按真实间隔（33.3 ms → 1.0）；过场槽 = 0 → +4 写 1、= 1 → 写 0；关 / 降档 → 目标 0
    expect("帧步：接上状态页", 1, dm_fps_state != NULL);
    expect("帧步：开着目标帧率 60", 60, lroundf(fs_f32(0)));
    static const int stp[] = {1, 2, 3}; static const long spd[] = {50, 100, 150};
    for (int i = 0; i < 3; i++) {
        *(uint32_t *)(dm_fps_state + 0x20) = (uint32_t)stp[i]; s2a_fps_present_at(t += 5000000);   // 间隔 5 ms：按旧算法会夹到 0.5，帧步应不看它
        memcpy(&fv, img + 0x4000 + 2040 * 8, 4); char w2[96]; snprintf(w2, sizeof w2, "帧步：步长 %d → 速度槽（×100）", stp[i]); expect(w2, spd[i], lroundf(fv * 100));
    }
    *(uint32_t *)(dm_fps_state + 0x20) = 0; s2a_fps_present_at(t += 33333333); memcpy(&fv, img + 0x4000 + 2040 * 8, 4);
    expect("帧步：步长 0（没在跑）→ 退回按真实间隔 33.3 ms 写 1.0（×100）", 100, lroundf(fv * 100));
    v = 0; memcpy(img + 0x4000 + 2042 * 8, &v, 4); s2a_fps_present_at(t += 16666667);
    expect("帧步：过场槽 0 → 状态页过场标记 1（按 30 帧放）", 1, *(uint32_t *)(dm_fps_state + 4));
    v = 1; memcpy(img + 0x4000 + 2042 * 8, &v, 4); s2a_fps_present_at(t += 16666667);
    expect("帧步：过场槽 1 → 过场标记 0", 0, *(uint32_t *)(dm_fps_state + 4));
    s2a_fps_set_enabled(0); expect("帧步：运行中关 → 目标帧率 0（帧步停、出图回游戏）", 0, lroundf(fs_f32(0)));
    s2a_fps_set_enabled(1); expect("帧步：再开 → 目标帧率 60", 60, lroundf(fs_f32(0)));
    {   // S2A_FSTEP=0（对照局）：不接状态页
        fflush(stdout); pid_t p = fork(); if (p < 0) return 1;
        if (!p) { dm_fps_state = NULL; setenv("S2A_FSTEP", "0", 1); s2a_fps_start(dir); _exit(dm_fps_state != NULL); }
        int ws = 0; waitpid(p, &ws, 0); expect("帧步：S2A_FSTEP=0 不接状态页", 0, WIFEXITED(ws) ? WEXITSTATUS(ws) : -1);
    }
    // 11-13 起不按热状态 / 低电量自动降档（维护者：不读电量、不设自己挡自己的闸），原降档用例随之删；玩家自己关 60 帧照旧按关生效：
    {   s2a_fps_set_enabled(0);
        usleep(250000); memcpy(&v, img + 0x1000, 4); expect("用户关着：w 行是关值 30", 30, v);
        expect("用户关着：s2a_fps_enabled 0、钩子退回", 10 + 0, s2a_fps_present_at(t += 16666667) * 10 + s2a_fps_enabled());
        expect("原因位读数：玩家关不是降档原因", 0, s2a_fps_cap_reason());
        expect("没有任何降档提示", 0, g_capped_n);
        // 同局 A/B（自动玩家 speed_ab）：阶段 1 = 原因 3、2 / 0 = 照常；普查 A/B 模式（S2A_FPS_AB=1）下 60 帧没开（S2A_FPS60=0）的款平时原因 3，阶段 2 才放开
        s2a_fps_set_enabled(1); s2a_fps_ab_set(1); expect("A/B 阶段 1：原因 3", 3, s2a_fps_cap_reason());
        usleep(250000); memcpy(&v, img + 0x1000, 4); expect("A/B 阶段 1：w 行写关值 30（同关 60 帧）", 30, v);
        s2a_fps_ab_set(2); expect("A/B 阶段 2：原因 0", 0, s2a_fps_cap_reason());
        usleep(250000); memcpy(&v, img + 0x1000, 4); expect("A/B 阶段 2：w 行回 60", 60, v);
        s2a_fps_ab_set(0); expect("A/B 测完：原因 0", 0, s2a_fps_cap_reason());
        setenv("S2A_FPS_AB", "1", 1); setenv("S2A_FPS60", "0", 1);
        expect("普查 A/B 模式、60 帧没开：平时原因 3", 3, s2a_fps_cap_reason());
        s2a_fps_ab_set(2); expect("普查 A/B 模式、60 帧没开：阶段 2 放开 → 原因 0", 0, s2a_fps_cap_reason());
        s2a_fps_ab_set(0); expect("普查 A/B 模式、60 帧没开：测完回原因 3", 3, s2a_fps_cap_reason());
        setenv("S2A_FPS60", "1", 1); expect("普查 A/B 模式、60 帧开着：原因 0（不受影响）", 0, s2a_fps_cap_reason()); unsetenv("S2A_FPS_AB"); }
    if (fails) printf("✗ t_fps：%d 项不符\n", fails); else printf("✓ t_fps：帧率表写入 / 条件 / 键页只读改可写 / 动态步长 / 宿主帧步 / 退回游戏间隔全过\n");
    return fails != 0;
}
