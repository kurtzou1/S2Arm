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
uint64_t s2a_guest_mem_seen(void); void s2a_guest_mem_note(uint64_t footprint);
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
    {   // ㉓ 记录：只增不减、读回一致（临时文件，S2A_GUEST_MEM_PEAK 指定路径）
        char path[] = "/tmp/t_gmem_peak_XXXXXX"; int fd = mkstemp(path); close(fd); unlink(path); setenv("S2A_GUEST_MEM_PEAK", path, 1);
        uint64_t a0 = s2a_guest_mem_seen(); s2a_guest_mem_note(900 * MB); uint64_t a1 = s2a_guest_mem_seen(); s2a_guest_mem_note(700 * MB); uint64_t a2 = s2a_guest_mem_seen(); s2a_guest_mem_note(1200 * MB); uint64_t a3 = s2a_guest_mem_seen();
        CHECK(a0 == 0 && a1 == 900 * MB && a2 == 900 * MB && a3 == 1200 * MB, "㉓ 实测峰值记录：没有 0 → 900 → 700 不降 → 1200（得 %llu / %llu / %llu / %llu MB）", a0 >> 20, a1 >> 20, a2 >> 20, a3 >> 20);
        unlink(path); unsetenv("S2A_GUEST_MEM_PEAK");
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
      CHECK(s2a_guest_file_wanted6(NULL, S1, 4096 * MB, 6144 * MB, 0, H2, G, 0, &low) == 0 && low == 0, "㊾ Switch 1 款小内存机（池 3285 ≤ 剩余 4096）：关、不提示（守 ㊹）");
      { int l1 = -1, l2 = -1; int a = s2a_guest_file_wanted6(NULL, S2, RP, S2 + H2, 0, H2, G, 0, &l1), b = s2a_guest_file_wanted6(NULL, S2, RP, S2 + H2 - 1, 0, H2, G, 0, &l2);
        CHECK(a == 1 && l1 == 0 && b == 1 && l2 == 1, "㊿ 边界：物理 = 池 + 宿主估计 开不提示，少 1 字节 开并提示（得 %d/%d %d/%d）", a, l1, b, l2); }
      CHECK(s2a_guest_file_wanted6(NULL, S2, RP, PI, 0, H2, G, 1, &low) == 1 && s2a_guest_file_wanted6(NULL, S2, RP, PI, UINT64_MAX, H2, G, 0, &low) == 1, "51 上局在前台死掉 / 坏记录：开（物理内存不够也开，安全阀）");
      CHECK(s2a_guest_file_wanted6(NULL, S2, RP, PD, 2118 * MB, H2, G, 0, &low) == 0 && s2a_guest_file_wanted6(NULL, S2, RP, PD, 7800 * MB, H2, G, 0, &low) == 1, "52 有实测按实测：2118 关、7800 开（同 ㊵ ㊶）");
      CHECK(s2a_guest_file_wanted6(NULL, S2, 0, PD, 0, H2, G, 1, &low) == 0, "53 Mac（room 0）：关");
      CHECK(s2a_guest_file_wanted6("1", S1, RP, PI, 0, H2, G, 0, &low) == 1 && s2a_guest_file_wanted6("0", S2, R, PD, 0, H2, G, 1, &low) == 0, "54 显式 1 / 0 压过一切"); }
    printf("%s t_guest_file_auto：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
