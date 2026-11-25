// 客体内存文件后备开不开（vawin.c s2a_guest_file_wanted / guest_file_attach）。
// 背景：11-06 时之笛 Switch 2 版 iPhone 17 Pro Max：不带 S2A_GUEST_FILE=1 进游戏 8.2 GB 被单进程上限 8192 MB 杀，带了约 2.8 GB；玩家不会手配环境变量，缺省关 = 大内存游戏默认被杀。
// 期望（按规则手写，不跑被测实现：设了按设的、"0" 关；没设 → 上限已知（room 非 0）且池 + 宿主开销估计 + 余量 > room 才开；Mac 传 room 0）：
//   11-06 维护者：原规则只比「池 > 剩余」漏算宿主开销（DOOM Eternal 宿主约 2.3 GB），④⑦ 改、⑧–⑪ 新增边界
//   ① "0" + 池 9 GiB > 剩余 7.8 GB → 关       ② "1" + 池 3285 MiB < 剩余 → 开
//   ③ 没设 + 池 9 GiB > 剩余 8000 MB → 开     ④ 没设 + 池 3285 MiB < 剩余 8000 MB → 关
//   ⑤ 没设 + room 0（Mac）+ 池 9 GiB → 关     ⑥ 空串同没设：池 9 GiB > 8000 MB → 开     ⑦ 池 = 剩余 → 关（装得下）
//   ⑧ 本机（Mac）真起局、S2A_GUEST_FILE 没设：窗口占到、没接文件（s2a_guest_fd() < 0）
#include "../src/native.h"
int s2a_guest_file_wanted2(const char *e, uint64_t pool, uint64_t room, uint64_t host, uint64_t margin);   // vawin.c（不进 native.h：抽取阶段键）
int s2a_guest_file_wanted3(const char *e, uint64_t pool, uint64_t room, uint64_t seen, uint64_t host, uint64_t margin);
uint64_t s2a_guest_mem_seen(void); void s2a_guest_mem_note(uint64_t footprint); const char *s2a_guest_mem_settle(int died, uint64_t room, uint64_t margin);
int s2a_guest_file_wanted5(const char *e, uint64_t room, uint64_t seen, uint64_t margin, int died); int s2a_guest_file_wanted6(const char *e, uint64_t pool, uint64_t room, uint64_t phys, uint64_t seen, uint64_t host, uint64_t margin, int died, int *low); int s2a_guest_run_died(void); void s2a_guest_run_mark(int running);
int s2a_guest_file_wanted_mac(const char *e, uint64_t pool, uint64_t room, int pressed); int s2a_guest_pressure_seen(void); void s2a_guest_pressure_note(void);   // #306 Mac 判定与压力记录
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "63488", 1); unsetenv("S2A_GUEST_FILE"); }   // 先于 vawin.c 的构造函数（101）；不继承外部环境的开关
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
#define MB (1ull << 20)
int main(void) {
    const uint64_t S2 = 0x240000000ull, S1 = 0xCD500000ull;   // Switch 2 应用池 9 GiB、Switch 3285 MiB（native.h S2A_APP_POOL）
    const uint64_t H = 2560 * MB, G = 512 * MB;   // 宿主开销估计、余量（vawin.c 缺省）
    CHECK(s2a_guest_file_wanted2("0", S2, 7800 * MB, H, G) == 0, "① S2A_GUEST_FILE=0、池 9216 MB > 剩余 7800 MB：关");
    CHECK(s2a_guest_file_wanted2("1", S1, 7800 * MB, H, G) == 1, "② S2A_GUEST_FILE=1、池 3285 MB 装得下：开");
    CHECK(s2a_guest_file_wanted2(NULL, S2, 8000 * MB, H, G) == 1, "③ 没设、池 9216 MB > 剩余 8000 MB（iOS）：开");
    CHECK(s2a_guest_file_wanted2(NULL, S1, 8189 * MB, H, G) == 0, "④ 没设、17 Pro Max 剩余 8189 MB、池 3285 + 宿主 2560 + 余量 512 = 6357 MB：关（装得下，不付闪存代价）");
    CHECK(s2a_guest_file_wanted2(NULL, S2, 0, H, G) == 0, "⑤ 没设、上限未知（Mac，room 0）、池 9216 MB：关");
    CHECK(s2a_guest_file_wanted2("", S2, 8000 * MB, H, G) == 1, "⑥ 空串同没设：池 9216 MB > 8000 MB：开");
    CHECK(s2a_guest_file_wanted2(NULL, S1, S1, H, G) == 1, "⑦ 没设、池 = 剩余：开（宿主开销放不下）——原规则只比池，判关");
    CHECK(s2a_guest_file_wanted2(NULL, S1, S1 + H + G, H, G) == 0, "⑧ 边界：池 + 宿主 + 余量 = 剩余：关（正好装得下）");
    CHECK(s2a_guest_file_wanted2(NULL, S1, S1 + H + G - 1, H, G) == 1, "⑨ 边界：差 1 字节：开");
    CHECK(s2a_guest_file_wanted2(NULL, S1, 5 * 1024 * MB, H, G) == 1, "⑩ 小内存机型剩余 5120 MB、池 3285 MB：开（池本身装得下，加宿主开销装不下）");
    CHECK(s2a_guest_file_wanted2(NULL, S1, 4000 * MB, 0, 0) == 0, "⑪ 宿主开销与余量为 0 时退回原规则：池 3285 < 4000：关");
    CHECK(s2a_window_ok() && s2a_guest_fd() < 0, "⑫ Mac 真起局、没设：窗口占到 %d、没接文件（fd %d，期望 < 0）", s2a_window_ok(), s2a_guest_fd());
    // 11-07 按实测（s2a_guest_file_wanted3）：期望按规则手写——设了按设的；room 0 关；池 > 剩余开；有实测按「实测 + 余量 > 剩余」；没实测按「池 + 宿主估计 2048 + 余量 > 剩余」
    const uint64_t H2 = 2048 * MB, R = 6141 * MB;   // 宿主估计新缺省；测试设备2 / Duo 实测剩余
    CHECK(s2a_guest_file_wanted3(NULL, S1, R, 0, H2, G) == 0, "⑬ 火炬之光3 / WWZ 首局：池 3285 + 宿主 2048 + 余量 512 = 5845 ≤ 剩余 6141：关（旧口径 2560 判开）");
    CHECK(s2a_guest_file_wanted3(NULL, S1, R, 1041 * MB, H2, G) == 0, "⑭ 有实测：火炬之光3 实测 1041 MB + 512 ≤ 6141：关");
    CHECK(s2a_guest_file_wanted3(NULL, S1, R, 5700 * MB, H2, G) == 1, "⑮ 有实测：某款实测 5700 MB + 512 > 6141：开（首局判关后由实测纠正）");
    CHECK(s2a_guest_file_wanted3(NULL, S2, R, 1041 * MB, H2, G) == 1, "⑯ 时之笛：池 9216 > 剩余 6141：开（不看实测）");
    CHECK(s2a_guest_file_wanted3(NULL, S2, 8189 * MB, 0, H2, G) == 1, "⑰ 时之笛：池 9216 > 剩余 8189：开");
    CHECK(s2a_guest_file_wanted3("0", S2, R, 0, H2, G) == 0 && s2a_guest_file_wanted3("1", S1, R, 1041 * MB, H2, G) == 1, "⑱ 显式 0 / 1 照设");
    CHECK(s2a_guest_file_wanted3(NULL, S2, 0, 0, H2, G) == 0, "⑲ Mac（room 0）：关");
    CHECK(s2a_guest_file_wanted3(NULL, S1, 4096 * MB, 0, H2, G) == 1, "⑳ 小内存机型剩余 4096、没实测：3285 + 2048 + 512 > 4096：开");
    CHECK(s2a_guest_file_wanted3(NULL, S1, 4096 * MB, 3000 * MB, H2, G) == 0, "㉑ 剩余 4096、实测 3000 + 512 = 3512 ≤ 4096：关");
    CHECK(s2a_guest_file_wanted3(NULL, S1, R, R - G, H2, G) == 0 && s2a_guest_file_wanted3(NULL, S1, R, R - G + 1, H2, G) == 1, "㉒ 边界：实测 + 余量 = 剩余 关，多 1 字节 开");
    {   // ㉓ 每局记需求、起局按上一局结算（#1634 11-19：原「只增不减 + 文件后备局不记」一局异常就永远判开）。期望按规则手写（余量 512、剩余 6141）：
        //   a 没记录、本局心跳记 900 / 700 → 本局文件「900 MB 2 次 匿名」；结算（短局、900 + 512 ≤ 6141）→ 不建记录（短局只是下限，D-9XY8）
        //   a' 没记录、短局（8 次、文件后备）需求 2817、剩余 6132 → 不建记录（D-9XY8 原样）；没记录、短局需求 5700（+512 > 6141，证明装不下）→ 记录 5700
        //   b 记录 5835、上一局开文件后备够长（40 次）需求 4300 → 换成 4300（往下改：#1634 帖主那种一局异常就纠正）
        //   c 记录 4300、上一局太短（5 次）需求 2000 → 不降，4300
        //   d 记录 4300、上一局前台死掉、需求 6000（+1024 > 6141，像撞上限）→ 6000、记「死过」
        //   e 记录 6000 死过、上一局开文件后备够长需求 4000 → 不降，6000 死过（文件后备局在内存紧的机器上量小了，不许往下改）
        //   f 记录 6000 死过、上一局匿名够长需求 3000 → 3000、不再「死过」
        //   g 记录 3000、上一局前台死掉但需求 2500（+1024 ≤ 6141，不是内存杀的）、够长 → 2500
        //   反证：够长那支改回取大（只增不减）→ b 红
        const char *(*settle)(int, uint64_t, uint64_t) = s2a_guest_mem_settle;
        char pk[] = "/tmp/t_gmem_peak_XXXXXX", rk[] = "/tmp/t_gmem_run_XXXXXX"; int fd = mkstemp(pk); close(fd); unlink(pk); fd = mkstemp(rk); close(fd); unlink(rk);
        setenv("S2A_GUEST_MEM_PEAK", pk, 1); setenv("S2A_GUEST_MEM_PEAK_RUN", rk, 1);
        #define PUT(path, ...) do { FILE *f_ = fopen(path, "w"); fprintf(f_, __VA_ARGS__); fclose(f_); } while (0)
        uint64_t a0 = s2a_guest_mem_seen(); s2a_guest_mem_note(900 * MB); s2a_guest_mem_note(700 * MB);
        unsigned long long rn = 0, rb = 0; int rf = -1; { FILE *f = fopen(rk, "r"); if (f) { if (fscanf(f, "%llu %llu %d", &rn, &rb, &rf) != 3) rn = 0; fclose(f); } }
        settle(0, R, G); uint64_t a1 = s2a_guest_mem_seen(); int gone = access(rk, F_OK) != 0;
        CHECK(a0 == 0 && rn == 900 * MB && rb == 2 && rf == 0 && a1 == 0 && gone, "㉓a 本局文件 %llu MB / %llu 次 / 文件后备 %d（期望 900 / 2 / 0），结算后记录 %llu MB（期望 0，短局不建）、本局文件删掉 %d", rn >> 20, rb, rf, a1 >> 20, gone);
        PUT(rk, "%llu 8 1\n", 2817 * MB); settle(0, 6132 * MB, G); uint64_t a2 = s2a_guest_mem_seen();
        PUT(rk, "%llu 8 1\n", 5700 * MB); settle(0, R, G); uint64_t a3 = s2a_guest_mem_seen();
        CHECK(a2 == 0 && a3 == 5700 * MB, "㉓a' 没记录短局 2817（剩余 6132）：记录 %llu MB（期望 0）；没记录短局 5700（+512 > 6141）：记录 %llu MB（期望 5700）", a2 >> 20, a3 >> 20);
        PUT(pk, "%llu\n", 5835 * MB); PUT(rk, "%llu 40 1\n", 4300 * MB); settle(0, R, G);
        CHECK(s2a_guest_mem_seen() == 4300 * MB, "㉓b 记录 5835、上一局文件后备够长需求 4300：记录 %llu MB（期望 4300，往下改）", s2a_guest_mem_seen() >> 20);
        PUT(rk, "%llu 5 0\n", 2000 * MB); settle(0, R, G);
        CHECK(s2a_guest_mem_seen() == 4300 * MB, "㉓c 上一局太短需求 2000：记录 %llu MB（期望 4300，不降）", s2a_guest_mem_seen() >> 20);
        PUT(rk, "%llu 3 0\n", 6000 * MB); settle(1, R, G); char w[32] = {0}; { FILE *f = fopen(pk, "r"); if (f) { unsigned long long v; if (fscanf(f, "%llu %31s", &v, w) < 1) w[0] = 0; fclose(f); } }
        CHECK(s2a_guest_mem_seen() == 6000 * MB && !strcmp(w, "died"), "㉓d 前台死掉需求 6000（逼近上限）：记录 %llu MB（期望 6000）、标记「%s」（期望 died）", s2a_guest_mem_seen() >> 20, w);
        PUT(rk, "%llu 40 1\n", 4000 * MB); settle(0, R, G);
        CHECK(s2a_guest_mem_seen() == 6000 * MB, "㉓e 死过的记录、上一局文件后备够长需求 4000：记录 %llu MB（期望 6000，不降）", s2a_guest_mem_seen() >> 20);
        PUT(rk, "%llu 40 0\n", 3000 * MB); settle(0, R, G); w[0] = 0; { FILE *f = fopen(pk, "r"); if (f) { unsigned long long v; if (fscanf(f, "%llu %31s", &v, w) < 1) w[0] = 0; fclose(f); } }
        CHECK(s2a_guest_mem_seen() == 3000 * MB && !w[0], "㉓f 死过的记录、上一局匿名够长需求 3000：记录 %llu MB（期望 3000）、不再死过 %d", s2a_guest_mem_seen() >> 20, !w[0]);
        PUT(rk, "%llu 40 0\n", 2500 * MB); settle(1, R, G);
        CHECK(s2a_guest_mem_seen() == 2500 * MB, "㉓g 前台死掉但需求 2500 离上限远、够长：记录 %llu MB（期望 2500）", s2a_guest_mem_seen() >> 20);
        #undef PUT
        unlink(pk); unlink(rk); unsetenv("S2A_GUEST_MEM_PEAK"); unsetenv("S2A_GUEST_MEM_PEAK_RUN");
    }
    // 11-07 安全阀（11-13 起 s2a_guest_file_wanted5，died = 上一局在前台死掉）：期望按规则手写
    CHECK(s2a_guest_file_wanted5(NULL, R, 0, G, 1) == 1, "㉔ 首局判关、上局在前台死掉（标记还在）：强制开");
    CHECK(s2a_guest_file_wanted5(NULL, R, 1041 * MB, G, 1) == 1, "㉕ 有实测 1041 MB 本该关、但上局在前台死掉：强制开（峰值可能没来得及记）");
    CHECK(s2a_guest_file_wanted5(NULL, R, 1041 * MB, G, 0) == 0, "㉖ 同上、上局干净（进了后台）：关");
    CHECK(s2a_guest_file_wanted5("0", R, 0, G, 1) == 0 && s2a_guest_file_wanted5(NULL, 0, 0, G, 1) == 0, "㉗ 显式 0 照关；Mac（room 0）不看标记、照关");
    {   // ㉘ 标记：前台写 → 死掉（没删）→ 下一局读到；进后台删 → 读不到
        char path[] = "/tmp/t_grun_XXXXXX"; int fd = mkstemp(path); close(fd); unlink(path); setenv("S2A_GUEST_RUN_MARK", path, 1);
        int d0 = s2a_guest_run_died(); s2a_guest_run_mark(1); int d1 = s2a_guest_run_died(); s2a_guest_run_mark(0); int d2 = s2a_guest_run_died(); s2a_guest_run_mark(1); s2a_guest_run_mark(1); int d3 = s2a_guest_run_died();
        CHECK(d0 == 0 && d1 == 1 && d2 == 0 && d3 == 1, "㉘ 「在跑」标记：没有 0 → 前台写 1 → 进后台删 0 → 再到前台（两次）1（得 %d %d %d %d）", d0, d1, d2, d3);
        // #909 11-15：本局闪退（崩溃处理改写成 crash）→ 下一局不算死于内存（0），但标记还在（闪退记录 1）；被系统 SIGKILL 不经崩溃处理 → 仍是 pid → 1。
        //   期望手写：mark(1) 后 crash → died 0 / crashed 1；再到前台 mark(1) → died 1（新一局覆盖成 pid）/ crashed 0。旧实现：标记在就算死掉 → 第一项红
        { void s2a_guest_run_mark_crash(void); int s2a_guest_run_crashed(void);
          s2a_guest_run_mark(1); s2a_guest_run_mark_crash(); int c0 = s2a_guest_run_died(), c1 = s2a_guest_run_crashed();
          s2a_guest_run_mark(1); int c2 = s2a_guest_run_died(), c3 = s2a_guest_run_crashed();
          CHECK(c0 == 0 && c1 == 1 && c2 == 1 && c3 == 0, "#909 闪退改写标记：闪退后 不算死于内存 0 / 闪退 1；再到前台 1 / 0（得 %d %d %d %d）", c0, c1, c2, c3); }
        unlink(path); unsetenv("S2A_GUEST_RUN_MARK");
    }
    {   // ㉙ 坏记录：峰值文件在但读不出 / 为 0 → 读出 UINT64_MAX，判开；本局实测覆盖后恢复正常
        char path[] = "/tmp/t_gmem_bad_XXXXXX"; int fd = mkstemp(path); write(fd, "garbage\n", 8); close(fd); setenv("S2A_GUEST_MEM_PEAK", path, 1);
        uint64_t b0 = s2a_guest_mem_seen(); int on0 = s2a_guest_file_wanted5(NULL, R, b0, G, 0);
        FILE *z = fopen(path, "w"); fputs("0\n", z); fclose(z); uint64_t b1 = s2a_guest_mem_seen();
        unlink(path); uint64_t b2 = s2a_guest_mem_seen();
        CHECK(b0 == UINT64_MAX && on0 == 1 && b1 == UINT64_MAX && b2 == 0, "㉙ 坏记录（乱码 / 0）读出 UINT64_MAX、判开；没有记录读出 0（得 %d %d %d %d）", b0 == UINT64_MAX, on0, b1 == UINT64_MAX, (int)b2);
        unsetenv("S2A_GUEST_MEM_PEAK");
    }
    // 11-13 #783（s2a_guest_file_wanted5）：池是上界不作判据；只认实测（匿名内存局的实占）、「在跑」标记、坏记录。期望按规则手写：
    //   时之笛 iPad Pro M2 剩余 8189 MB：判开的局 30 分钟写闪存 189 / 223 GB 后卡死，没开的局实占峰值 2118 MB
    const uint64_t RP = 8189 * MB;
    CHECK(s2a_guest_file_wanted5(NULL, RP, 0, G, 0) == 0, "㊴ 时之笛 iPad 首局、没实测、上局干净：关（旧判据池 9216 > 8189 判开）");
    CHECK(s2a_guest_file_wanted5(NULL, RP, 2118 * MB, G, 0) == 0, "㊵ 实测 2118 + 512 ≤ 8189：关");
    CHECK(s2a_guest_file_wanted5(NULL, RP, 7800 * MB, G, 0) == 1, "㊶ 实测 7800 + 512 > 8189：开");
    CHECK(s2a_guest_file_wanted5(NULL, RP, RP - G, G, 0) == 0 && s2a_guest_file_wanted5(NULL, RP, RP - G + 1, G, 0) == 1, "㊷ 边界：实测 + 余量 = 剩余 关，多 1 字节 开");
    CHECK(s2a_guest_file_wanted5(NULL, RP, 0, G, 1) == 1 && s2a_guest_file_wanted5(NULL, RP, UINT64_MAX, G, 0) == 1, "㊸ 没实测但上局在前台死掉：开；坏记录：开");
    CHECK(s2a_guest_file_wanted5(NULL, 4096 * MB, 0, G, 0) == 0, "㊹ 小内存机型剩余 4096、没实测：关（旧判据 3285 + 2048 + 512 > 4096 判开）");
    CHECK(s2a_guest_file_wanted5("1", RP, 2118 * MB, G, 0) == 1 && s2a_guest_file_wanted5("0", RP, 0, G, 1) == 0, "㊺ 显式 1 / 0 压过一切");
    // #306 / #353 Mac（s2a_guest_file_wanted_mac）：期望按规则手写——设了按设的（"0" 关、其余开、空串同没设）；没设 → 池 > 剩余（物理内存 − 预留 6144 MB，0 = 读不到）开，
    //   否则上一局到过系统内存压力「严重」档才开；不加宿主估计、不看实测（㉚–㊱ 取自 PR #353，wwmogu）
    const uint64_t M16 = (16384 - 6144) * MB, M8 = (8192 - 6144) * MB, M24 = (24576 - 6144) * MB;
    CHECK(s2a_guest_file_wanted_mac(NULL, S2, M16, 0) == 0, "㉚ 16 GB Mac、池 9216 MB ≤ 剩余 10240 MB、没到过「严重」：关（旧判据加宿主估计 2048 + 余量 512 判开，撞脏文件页上限长停顿 #306）");
    CHECK(s2a_guest_file_wanted3(NULL, S2, M16, 0, H2, G) == 1, "㉛ 对照：同参数旧判据（wanted3：池 + 宿主估计 + 余量）判开");
    CHECK(s2a_guest_file_wanted_mac(NULL, S2, M8, 0) == 1 && s2a_guest_file_wanted_mac(NULL, S1, M8, 0) == 1, "㉜ 8 GB Mac、剩余 2048 MB：池 9216 / 3285 MB 都装不下：第一局就开");
    CHECK(s2a_guest_file_wanted_mac(NULL, S2, M24, 0) == 0 && s2a_guest_file_wanted_mac(NULL, S1, M16, 0) == 0, "㉝ 24 GB 跑 Switch 2 款、16 GB 跑 Switch 款：关");
    CHECK(s2a_guest_file_wanted_mac(NULL, S2, S2, 0) == 0 && s2a_guest_file_wanted_mac(NULL, S2, S2 - 1, 0) == 1, "㉞ 边界：池 = 剩余 关，剩余少 1 字节 开");
    CHECK(s2a_guest_file_wanted_mac("1", S1, M24, 0) == 1 && s2a_guest_file_wanted_mac("0", S2, M8, 1) == 0 && s2a_guest_file_wanted_mac("", S2, M16, 0) == 0, "㉟ 显式 1 / 0 照设（0 压过装不下和压力记录），空串同没设");
    CHECK(s2a_guest_file_wanted_mac(NULL, S2, 0, 0) == 0, "㊱ 读不到物理内存（room 0）、没到过「严重」：关");
    CHECK(s2a_guest_file_wanted_mac(NULL, S2, M16, 1) == 1 && s2a_guest_file_wanted_mac(NULL, S2, 0, 1) == 1, "㊲ 池装得下（或读不到物理内存）但上一局到过「严重」：开");
    {   // ㊳ 压力记录：没有 → 读 0；记一次 → 读 1；再记不重写（只写一次）
        char path[] = "/tmp/t_gpress_XXXXXX"; int fd = mkstemp(path); close(fd); unlink(path); setenv("S2A_GUEST_PRESSURE_MARK", path, 1);
        int p0 = s2a_guest_pressure_seen(); s2a_guest_pressure_note(); int p1 = s2a_guest_pressure_seen();
        char buf[64] = {0}; FILE *f = fopen(path, "r"); if (f) { fgets(buf, sizeof buf, f); fclose(f); }
        unlink(path); s2a_guest_pressure_note(); int p2 = s2a_guest_pressure_seen();
        CHECK(p0 == 0 && p1 == 1 && !strncmp(buf, "critical ", 9) && p2 == 0, "㊳ 压力记录：没有 0 → 记一次 1（内容「critical 时间」）→ 删掉后再记不重写 0（得 %d %d「%.9s」%d）", p0, p1, buf, p2);
        unlink(path); unsetenv("S2A_GUEST_PRESSURE_MARK");
    }
    // 11-13 #964 三档（s2a_guest_file_wanted6）：不依赖历史，按单进程上限、物理内存、池 + 宿主估计判。期望按规则手写，例子取真机读数：
    //   一款 Switch 2 大款（0400486024DEC000） Duo（iPhone19,4 物理 11570 MB，剩余 6141 / 8189 MB）：9216 > 剩余，11570 ≥ 9216 + 2048 = 11264 → 开（实测正式游戏每 10 秒写盘 0–8 MB）；
    //   同款 iPad Pro（iPad14,3 物理 7535 MB，剩余 8189）：7535 < 11264 → 开并提示（两种都可能坏，文件后备在它上面每局能玩约 30 分钟，匿名没实测、要的比物理内存还多）；Switch 1 款小内存机（㊹）池 3285 ≤ 4096 → 关、不提示
    { int low = -1; const uint64_t PD = 11570 * MB, PI = 7535 * MB;
      CHECK(s2a_guest_file_wanted6(NULL, S2, R, PD, 0, H2, G, 0, &low) == 1 && low == 0, "㊻ 这款 Duo 首局（剩余 6141、物理 11570）：开（得 low %d）", low);
      CHECK(s2a_guest_file_wanted6(NULL, S2, RP, PD, 0, H2, G, 0, &low) == 1 && low == 0, "㊼ 同上、干净起局剩余 8189：池 9216 仍大于剩余，开");
      CHECK(s2a_guest_file_wanted6(NULL, S2, RP, PI, 0, H2, G, 0, &low) == 1 && low == 1, "㊽ 这款 iPad 首局（物理 7535 < 11264）：开、提示内存可能不够");
      CHECK(s2a_guest_file_wanted6(NULL, S1, 4096 * MB, 6144 * MB, 0, H2, G, 0, &low) == 1 && low == 0, "㊾ Switch 1 款小内存机（池 3285 + 2048 + 512 > 剩余 4096）：开（溢出模式那档，见 72）、不提示（物理 6144 ≥ 5333）");
      { int l1 = -1, l2 = -1; int a = s2a_guest_file_wanted6(NULL, S2, RP, S2 + H2, 0, H2, G, 0, &l1), b = s2a_guest_file_wanted6(NULL, S2, RP, S2 + H2 - 1, 0, H2, G, 0, &l2);
        CHECK(a == 1 && l1 == 0 && b == 1 && l2 == 1, "㊿ 边界：物理 = 池 + 宿主估计 开不提示，少 1 字节 开并提示（得 %d/%d %d/%d）", a, l1, b, l2); }
      CHECK(s2a_guest_file_wanted6(NULL, S2, RP, PI, 0, H2, G, 1, &low) == 1 && s2a_guest_file_wanted6(NULL, S2, RP, PI, UINT64_MAX, H2, G, 0, &low) == 1, "51 上局在前台死掉 / 坏记录：开（物理内存不够也开，安全阀）");
      CHECK(s2a_guest_file_wanted6(NULL, S2, RP, PD, 2118 * MB, H2, G, 0, &low) == 0 && s2a_guest_file_wanted6(NULL, S2, RP, PD, 7800 * MB, H2, G, 0, &low) == 1, "52 有实测按实测：2118 关、7800 开（同 ㊵ ㊶）");
      CHECK(s2a_guest_file_wanted6(NULL, S2, 0, PD, 0, H2, G, 1, &low) == 0, "53 Mac（room 0）：关");
      // #2f79dd 安全阀收窄（D-C73M 6 GB iPhone 读数）：上局前台死掉，但本款实测 + 两份余量 ≤ 剩余 → 不强制开、按实测判关；期望手算：
      //   2372 + 2×512 = 3396 ≤ 4093 → 关；2600 + 1024 = 3624 ≤ 4093 → 关；3100 + 1024 = 4124 > 4093 → 开（那次可能真超上限、心跳漏记）；
      //   没实测（0）→ 开（守 51）；实测本身 + 一份余量就超（3700 + 512 > 4093）→ 开
      CHECK(s2a_guest_file_wanted6(NULL, S1, 4093 * MB, 5667 * MB, 2372 * MB, H2, G, 1, &low) == 0, "55 上局前台死掉、实测 2372 + 1024 ≤ 剩余 4093：关（不是超上限，D-C73M）");
      CHECK(s2a_guest_file_wanted6(NULL, S1, 4093 * MB, 5667 * MB, 3069 * MB, H2, G, 1, &low) == 0 && s2a_guest_file_wanted6(NULL, S1, 4093 * MB, 5667 * MB, 3070 * MB, H2, G, 1, &low) == 1,
            "56 边界：3069 + 1024 = 4093 ≤ 4093 关、3070 + 1024 = 4094 > 4093 开");
      CHECK(s2a_guest_file_wanted6(NULL, S1, 4093 * MB, 5667 * MB, 0, H2, G, 1, &low) == 1, "57 上局前台死掉、没实测：开（安全阀原意）");
      CHECK(s2a_guest_file_wanted6(NULL, S1, 4093 * MB, 5667 * MB, 3700 * MB, H2, G, 1, &low) == 1 && s2a_guest_file_wanted6(NULL, S1, 4093 * MB, 5667 * MB, 3700 * MB, H2, G, 0, &low) == 1,
            "58 实测 3700 + 512 > 4093：死没死都开");
      CHECK(s2a_guest_file_wanted6("1", S1, RP, PI, 0, H2, G, 0, &low) == 1 && s2a_guest_file_wanted6("0", S2, R, PD, 0, H2, G, 1, &low) == 0, "54 显式 1 / 0 压过一切"); }
    {   // 63–67 判据剩余按物理内存封顶（s2a_guest_room_eff，D-YDKK：iPad14,3 物理 7536 MB、带提高内存上限权限剩余 8189 MB）。期望手算：min(剩余, 物理 − 余量 512)
        uint64_t s2a_guest_room_eff(uint64_t, uint64_t, uint64_t); int s2a_guest_carve_wanted(const char *, int, uint64_t, uint64_t); int low = -1;
        CHECK(s2a_guest_room_eff(8189 * MB, 7536 * MB, 512 * MB) == 7024 * MB, "63 iPad 物理 7536、剩余 8189：判据按 7536 − 512 = 7024 MB");
        CHECK(s2a_guest_room_eff(8189 * MB, 11570 * MB, 512 * MB) == 8189 * MB && s2a_guest_room_eff(6141 * MB, 7680 * MB, 512 * MB) == 6141 * MB, "64 物理 − 余量不小于剩余（Duo 11570 / 8 GB iPhone 剩余 6141）：照旧按剩余");
        CHECK(s2a_guest_room_eff(0, 7536 * MB, 512 * MB) == 0 && s2a_guest_room_eff(8189 * MB, 0, 512 * MB) == 8189 * MB, "65 剩余未知（Mac 0）仍 0；物理读不到只按剩余");
        uint64_t r = s2a_guest_room_eff(8189 * MB, 7536 * MB, 512 * MB);
        CHECK(s2a_guest_file_wanted6(NULL, S2, r, 7536 * MB, 7625 * MB, H2, G, 0, &low) == 1, "66 D-YDKK 第 2 局：实测 7625 + 512 = 8137 > 7024 → 开（原先比 8189 判关）");
        CHECK(s2a_guest_carve_wanted(NULL, 0, r, 7168 * MB) == 0 && s2a_guest_carve_wanted(NULL, 1, 8189 * MB, 7168 * MB) == 0,
              "66 D-YDKK 第 3 局：剩余 7024 < 7168 不挖；物理内存也装不下那档（low）也不挖，物理映射区走文件"); }
    {   // 68–71 有实测时也判「物理内存也装不下」那档（D-9R4S：6 GB iPad，Switch 2 大款实测 8877 MB，原先有实测就不判、从不提示）。期望手算：on 且 实测 + 余量 512 > 物理
        int low = -1; uint64_t s2a_guest_need(uint64_t, uint64_t, uint64_t);
        CHECK(s2a_guest_file_wanted6(NULL, S2, 4092 * MB, 5914 * MB, 8877 * MB, H2, G, 0, &low) == 1 && low == 1, "68 D-9R4S：实测 8877 + 512 > 剩余 4092 开、> 物理 5914 提示（low %d，期望 1）", low);
        CHECK(s2a_guest_file_wanted6(NULL, S2, 7024 * MB, 7536 * MB, 7625 * MB, H2, G, 0, &low) == 1 && low == 1, "69 D-YDKK：实测 7625 + 512 = 8137 > 物理 7536：提示（low %d，期望 1）", low);
        CHECK(s2a_guest_file_wanted6(NULL, S2, 8189 * MB, 11570 * MB, 7800 * MB, H2, G, 0, &low) == 1 && low == 0, "70 Duo：实测 7800 + 512 ≤ 物理 11570：开、不提示（low %d，期望 0）", low);
        CHECK(s2a_guest_file_wanted6(NULL, S2, 8189 * MB, 11570 * MB, 2118 * MB, H2, G, 0, &low) == 0 && low == 0, "71 实测装得下：关、不提示（low %d）", low);
        CHECK(s2a_guest_need(9216 * MB, 2048 * MB, 8877 * MB) == 8877 * MB && s2a_guest_need(9216 * MB, 2048 * MB, 0) == 11264 * MB && s2a_guest_need(9216 * MB, 2048 * MB, UINT64_MAX) == 11264 * MB,
              "71 「约需」：有实测 8877、没实测 / 坏记录 9216 + 2048 = 11264"); }
    {   // 72 D-D4AK（6 GB iPhone15,3：物理 5636、剩余 4092，一款 Switch 1 游戏池 3285，没实测）：原先池 ≤ 剩余判关、纯匿名首局到 4093 MB 被系统收掉。
        //   期望手算：3285 + 2048 + 512 = 5845 > 4092 → 开；5845 ≤ 物理 5636？否，但 low 按池 + 宿主 = 5333 ≤ 5636 → 不提示；这档是 soft（首局溢出预算按宿主估计 2048）。
        //   溢出首局预算 = 4092 − 512 − 2048 = 1532 MB（大款缺省 4096 会得 0 = 整段进文件）。8 GB 机（剩余 6141）5845 ≤ 6141 → 照旧关
        int low = -1, src = -1; int s2a_guest_soft_tier(int, const char *, uint64_t, uint64_t, uint64_t, int);
        uint64_t s2a_guest_next_budget(const char *, uint64_t, uint64_t, uint64_t, int, int, uint64_t, uint64_t, int, uint64_t, int *);
        int on = s2a_guest_file_wanted6(NULL, S1, 4092 * MB, 5636 * MB, 0, H2, G, 0, &low);
        CHECK(on == 1 && low == 0 && s2a_guest_soft_tier(on, NULL, S1, 4092 * MB, 0, 0) == 1, "72 D-D4AK 首局：开（%d）、不提示（low %d）、溢出那档", on, low);
        CHECK(s2a_guest_next_budget(NULL, 4092 * MB, G, H2, 0, 0, 0, 0, 0, 0, &src) == 1532 * MB && src == 3, "72 这档首局预算 4092 − 512 − 2048 = 1532 MB");
        CHECK(s2a_guest_next_budget(NULL, 4092 * MB, G, 4096 * MB, 0, 0, 0, 0, 0, 0, &src) == 0, "72 反证：按大款首局宿主 4096 算是 0（整段进文件），所以这档要另给宿主估计");
        CHECK(s2a_guest_file_wanted6(NULL, S1, 6141 * MB, 7800 * MB, 0, H2, G, 0, &low) == 0, "72 8 GB 机剩余 6141：5845 ≤ 6141 照旧关");
        CHECK(s2a_guest_file_wanted6(NULL, S1, 5844 * MB, 7800 * MB, 0, H2, G, 0, &low) == 1 && s2a_guest_file_wanted6(NULL, S1, 5845 * MB, 7800 * MB, 0, H2, G, 0, &low) == 0, "72 边界：剩余 5844 开、5845 关");
        CHECK(s2a_guest_soft_tier(1, NULL, S1, 4092 * MB, 0, 1) == 0 && s2a_guest_soft_tier(1, NULL, S2, 4092 * MB, 0, 0) == 0 && s2a_guest_soft_tier(1, NULL, S1, 4092 * MB, UINT64_MAX, 0) == 0
              && s2a_guest_soft_tier(1, "1", S1, 4092 * MB, 0, 0) == 0 && s2a_guest_soft_tier(0, NULL, S1, 4092 * MB, 0, 0) == 0,
              "72 不按宿主估计：上局死掉（整段）/ 池 > 剩余（Switch 2）/ 坏记录 / 显式设 / 没开"); }
    {   // 73 D-F5PT（6 GB iPhone14,2：物理 5670、剩余 4085，一款 Switch 1 游戏池 3285、实测 3874，上局没死）：3874 + 512 > 4085 → 开；
        //   原先首局预算按 4096 算 = 0，整段进文件（实占 0.5–1.2 GB，10 秒写盘约 3 GB、p99 帧时 0.2–2 秒）。期望：池装得下 → 按宿主 2048：4085 − 512 − 2048 = 1525 MB
        int low = -1, src = -1; int s2a_guest_soft_tier(int, const char *, uint64_t, uint64_t, uint64_t, int);
        uint64_t s2a_guest_next_budget(const char *, uint64_t, uint64_t, uint64_t, int, int, uint64_t, uint64_t, int, uint64_t, int *);
        int on = s2a_guest_file_wanted6(NULL, S1, 4085 * MB, 5670 * MB, 3874 * MB, H2, G, 0, &low);
        CHECK(on == 1 && low == 0 && s2a_guest_soft_tier(on, NULL, S1, 4085 * MB, 3874 * MB, 0) == 1, "73 D-F5PT：开（%d）、不提示（low %d）、池装得下按宿主估计", on, low);
        CHECK(s2a_guest_next_budget(NULL, 4085 * MB, G, H2, 0, 0, 0, 0, 0, 0, &src) == 1525 * MB && src == 3, "73 首局预算 4085 − 512 − 2048 = 1525 MB（原先 0 = 整段）"); }
    {   // 74 起局剩余按前台上限补回（s2a_guest_room_fg，#674 对照 11-25：多款容器起局时是预热 / 后台档，读到剩余 6140、上限 6140 + 占用 1000；
        //   装游戏前此刻上限 8122 + 1000 → 补 1982 = 8122）。期望手算：上限变大补差、变小 / 起局没读到（0）照旧（只补不扣）
        uint64_t s2a_guest_room_fg(uint64_t, uint64_t, uint64_t);
        CHECK(s2a_guest_room_fg(6140 * MB, 7140 * MB, 9122 * MB) == 8122 * MB, "74 后台档 6140、上限 7140 → 9122：补成 8122 MB");
        CHECK(s2a_guest_room_fg(8188 * MB, 9188 * MB, 9000 * MB) == 8188 * MB && s2a_guest_room_fg(6140 * MB, 0, 9122 * MB) == 6140 * MB,
              "74 上限变小不扣（8188 照旧）；起局没读到上限不补（6140 照旧）");
        uint64_t s2a_guest_room_eff(uint64_t, uint64_t, uint64_t);
        CHECK(s2a_guest_room_eff(s2a_guest_room_fg(6140 * MB, 7140 * MB, 9122 * MB), 7536 * MB, 512 * MB) == 7024 * MB, "74 补后仍按物理内存封顶：7536 − 512 = 7024 MB"); }
    {   // 67 「内存可能不够」只问一次（s2a_guest_lowram_once）：记号在 mem_peak_anon 同目录 lowram_asked；第一次 0（要问）、之后 1
        int s2a_guest_lowram_once(void); char d[] = "/tmp/t_lowram_XXXXXX"; if (!mkdtemp(d)) { CHECK(0, "67 建临时目录"); return 1; }
        char pk[256]; snprintf(pk, sizeof pk, "%s/w/mem_peak_anon", d); setenv("S2A_GUEST_MEM_PEAK", pk, 1);
        int a = s2a_guest_lowram_once(), b = s2a_guest_lowram_once(); char m[300]; snprintf(m, sizeof m, "%s/w/lowram_asked", d);
        CHECK(a == 0 && b == 1 && access(m, F_OK) == 0, "67 第一次要问（%d，期望 0）、第二次不问（%d，期望 1）、记号写在 lowram_asked", a, b);
        unlink(m); snprintf(m, sizeof m, "%s/w", d); rmdir(m); rmdir(d); unsetenv("S2A_GUEST_MEM_PEAK"); }
    printf("%s t_guest_file_auto：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
