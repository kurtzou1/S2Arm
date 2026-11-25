// PR-B（#625 第二阶段）S4「SDR 转 HDR」开关解析与 present 接线单测（设计稿 §3.1 开关 / §2.3 engage 门 / §2.4 填充落点 /
//   §3.5 探针口径 / §5.1 用例 2·4·5；PR #2162 评审终稿口径见设计稿「第 4 轮处置记录」）：
//   三开关一次缓存解析——S2A_HDR_SDR_MAP 总开关（1/0 照 S2A_FPS60 启动翻译形态；未设 / 空串 = 0 缺省关、字节级回现状；
//   看不懂打一次红行按 0，nvn2_hdr_switch 红行先例）+ S2A_HDR_SDR_MAP_NITS（缺省 100 = BT.2446-1 §4.2 设计点，域 [80,1000]）/
//   S2A_HDR_SDR_MAP_TARGET_NITS（缺省 400 = 业界甜点下沿，域 [100,10000]）调校位（nvn2_hdr_sdr_gamma 同款一次缓存
//   + 域外/垃圾红行一次按缺省）；nvn2_hdr_present 读缓存传 hdr_present_fill（关 ⇒ 传 0,0 ⇒ p[2]=p[3]=0 纯 mode 2；
//   开 ∧ engage 门过 ⇒ p[2]=sdr、p[3]=effective target = min(设置, 纸白×净空)，严格大于 max(sdr, 地板 125 nit)）
//   + 首次 engage 的 host.log 生效行（打一次，§3.5 行文定死：数值 %.0f/%.0f/%.1f 现打）。
//   评审终稿联动面（相 14/15）：不联动 S2A_HDR——层视角开关 nvn2_hdr_layer_sw（出图层 / 层状态机用）：S4 开而玩家
//   S2A_HDR 未设 / 显式 off ⇒ 层按 auto 进 / 持 PQ（S4 只让出图层持 PQ、对 SDR 窗口做扩张）；玩家设了 auto/on ⇒
//   以玩家为准原样带过（S4 不覆盖）；vi 答询侧（nvn2_hdr_answer）照玩家开关——off 恒不答 on=1（hdr_choose_mode 的
//   off 分支原样，nvn_hdr_policy.h:123–142——维护者指认的依据，红态起单测实读复核）。
//   开关读一次缓存、进程内不换（出图热路径不逐帧读环境）——分进程多遍起（argv[1] = 相名；present_hdr.mk 第二遍进程先例；
//   S2A_HDR 由 nvn2_hdr_switch 逐次读环境，相内翻环境即可）。
//   纯 C，不需要 GPU / 游戏（t_hdr_layer 口径）。三态流：基线（PR-A 在、PR-B 未实现）上 nvn_hdr_policy.h 没有
//   NVN2_HDR_SDR_MAP_SWITCH 在位标记 → 本测显式红（HDR_SDR_MAP_FILL 特征检测同款口径——PR-A 先例）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "nvn_hdr_policy.h"
static unsigned checks;
#define CHECK(c) do { checks++; if (!(c)) { printf("✗ t_hdr_sdr_map：第 %d 行不通：%s\n", __LINE__, #c); exit(1); } } while (0)

// 本测试给 nvn2.c 的接口（nvn2.c 里是弱定义，缺省 0）：装作 Switch 2 游戏，同 t_hdr_layer / t_nvn2
int s2a_platform_ounce(void) { return 1; }
int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && !strcmp(d, "1"); }   // 替身：同 t_hdr_layer（宿主不链进本单测）

#ifdef NVN2_HDR_SDR_MAP_SWITCH   // 相函数与捕获帮手全在守卫内：红态只编 main 的显式红（无未用告警、无未声明调用）
// host.log 捕获（LOG 落 g_s2a_logfd，单测里是弱缺省 fd 2；t_nvn_devmode 的 dup2 先例）：数 needle 出现次数
static char logpath[] = "/tmp/t_hdr_sdr_map.XXXXXX";
static int saved_err = -1;
static void log_begin(void) { saved_err = dup(2); int fd = mkstemp(logpath); if (fd < 0) { perror("mkstemp"); exit(1); } dup2(fd, 2); close(fd); }
static int log_end(const char *needle) {   // 恢复 stderr、数 needle 行数、删文件（调用方比对期望次数）
    fflush(stderr);
    dup2(saved_err, 2); close(saved_err); saved_err = -1;
    FILE *f = fopen(logpath, "r"); int n = 0; char line[2048];
    while (f && fgets(line, sizeof line, f)) if (strstr(line, needle)) n++;
    if (f) fclose(f);
    unlink(logpath);
    return n;
}

// 合成快照发布 + nvn2_hdr_present 生产入口直调（mode 2 = SDR8 源 → PQ 层目标；headroom 随发布换，开关缓存进程内不换）
static int present_sdr8(float p[8], double headroom) {
    hdr_snapshot pub = { .potential_edr = headroom > 0 ? headroom : 0, .current_headroom = headroom, .s1_ready = 1, .paper_white = 100 };
    nvn2_hdr_snapshot_publish(&pub);
    return nvn2_hdr_present(p, HDR_PF_SDR8, HDR_PT_PQ10);
}

// ---------- 相 1：未设 / 空串 = 缺省关；调校位缺省；present 接线恒纯 mode 2 ----------
static void phase_off(void) {
    setenv("S2A_HDR_SDR_MAP", "", 1);   // 空串按未设（nvn2_hdr_switch 口径：不红行、按 0）
    log_begin();
    CHECK(nvn2_hdr_sdr_map() == 0);   // 一次缓存已定：0
    CHECK(log_end("【红】S2A_HDR_SDR_MAP=") == 0);   // 空串不红
    unsetenv("S2A_HDR_SDR_MAP");
    CHECK(nvn2_hdr_sdr_map() == 0);   // 缓存不随环境翻（出图热路径不逐帧读环境）
    CHECK(nvn2_hdr_sdr_map_nits() == 100.0);        // BT.2446-1 §4.2 设计点（缺省）
    CHECK(nvn2_hdr_sdr_map_target_nits() == 400.0); // 业界甜点下沿（设计稿 §2.3 缺省）
    float p[8]; int pv = present_sdr8(p, 4.0);   // 净空 4×：ceiling 400，够 engage 的净空读数——但开关关
    CHECK(pv == HDR_PV_TO_PQ);
    CHECK(p[0] == 2.0f && p[1] == 100.0f && p[2] == 0.0f && p[3] == 0.0f && p[6] == 2.2f);   // S4 关 ⇒ 传 0,0 ⇒ 纯 mode 2（off 不变量经生产入口）
    log_begin();
    present_sdr8(p, 4.0); present_sdr8(p, 1.3);
    CHECK(log_end("SDR 转 HDR 生效") == 0);   // 关 ⇒ 生效行一次都不打（探针口径 §3.5）
}

// ---------- 相 2：开（缺省参数）——engage、生效行一次、净空夹顶 / 地板门经生产入口 ----------
static void phase_on(void) {
    CHECK(nvn2_hdr_sdr_map() == 1);
    CHECK(nvn2_hdr_sdr_map_nits() == 100.0 && nvn2_hdr_sdr_map_target_nits() == 400.0);
    float p[8]; int pv;
    log_begin();
    pv = present_sdr8(p, 4.0);   // ceiling = 纸白 100 × 净空 4 = 400 ≥ 设置 400 ⇒ effective 400
    CHECK(pv == HDR_PV_TO_PQ && p[0] == 2.0f && p[2] == 100.0f && p[3] == 400.0f);   // 开 ∧ 门过 ⇒ p[2]=sdr、p[3]=effective target
    pv = present_sdr8(p, 1.3);   // ceiling = 130 < 设置 400 ⇒ p[3]=130（净空只夹顶，逐帧随净空走）
    CHECK(pv == HDR_PV_TO_PQ && p[2] == 100.0f && p[3] == 130.0f);
    CHECK(log_end("SDR 转 HDR 生效（mode 2 上扩：BT.2446A 逆映射 sdr=100 nit、target=400 nit") == 1);   // 首次 engage 打一次、后续 engage 不再打（数值 %.0f 现打）
    log_begin();
    pv = present_sdr8(p, 1.2);   // ceiling = 120 ≤ 地板 125 ⇒ 门不过 ⇒ 双零纯 mode 2（平滑退化）
    CHECK(pv == HDR_PV_TO_PQ && p[2] == 0.0f && p[3] == 0.0f);
    CHECK(log_end("SDR 转 HDR 生效") == 0);   // 门不过不补打行
    hdr_snapshot sd = {0}; nvn2_hdr_snapshot_publish(&sd);   // 段末清回缺省（t_hdr_layer 收尾同款）
}

// ---------- 相 3/4：显式 0 / 看不懂的值（红行一次、按 0）----------
static void phase_zero(void) {
    CHECK(nvn2_hdr_sdr_map() == 0);
    float p[8]; CHECK(present_sdr8(p, 4.0) == HDR_PV_TO_PQ && p[2] == 0.0f && p[3] == 0.0f);   // 关的语义在生产入口收口
    log_begin(); present_sdr8(p, 4.0);
    CHECK(log_end("SDR 转 HDR 生效") == 0);
}
static void phase_garbage(void) {
    log_begin();
    CHECK(nvn2_hdr_sdr_map() == 0);   // 看不懂按 0（缺省关，字节级回现状）
    CHECK(log_end("【红】S2A_HDR_SDR_MAP=yes 看不懂") == 1);   // 红行一次（不静默吞拼写错误）；后续不重打
    log_begin(); nvn2_hdr_sdr_map();
    CHECK(log_end("【红】S2A_HDR_SDR_MAP=") == 0);
    float p[8]; CHECK(present_sdr8(p, 4.0) == HDR_PV_TO_PQ && p[2] == 0.0f && p[3] == 0.0f);
}

// ---------- 相 5–8：sdr nits 调校位（域内 / 域外红行按缺省）----------
static void phase_nits_in(void) {
    CHECK(nvn2_hdr_sdr_map_nits() == 203.0);   // 域内（80..1000，纸白基准 203 业界并存）：非设计点参数照传（通用解析式的意义）
    float p[8]; int pv = present_sdr8(p, 4.0);   // ceiling 400 ≥ target 设置 400 ⇒ engage
    CHECK(pv == HDR_PV_TO_PQ && p[2] == 203.0f && p[3] == 400.0f);
    hdr_snapshot sd = {0}; nvn2_hdr_snapshot_publish(&sd);
}
static void phase_nits_low(void) {
    log_begin();
    CHECK(nvn2_hdr_sdr_map_nits() == 100.0);   // 域外（< 80）红行按缺省 100
    CHECK(log_end("【红】S2A_HDR_SDR_MAP_NITS=50 看不懂") == 1);
}
static void phase_nits_high(void) {
    log_begin();
    CHECK(nvn2_hdr_sdr_map_nits() == 100.0);   // 域外（> 1000）
    CHECK(log_end("【红】S2A_HDR_SDR_MAP_NITS=2000 看不懂") == 1);
}
static void phase_nits_garbage(void) {
    log_begin();
    CHECK(nvn2_hdr_sdr_map_nits() == 100.0);   // 垃圾值
    CHECK(log_end("【红】S2A_HDR_SDR_MAP_NITS=abc 看不懂") == 1);
}

// ---------- 相 9–13：target nits 调校位（域内含 target=sdr 门 / 域外红行按缺省）----------
static void phase_target_in(void) {
    CHECK(nvn2_hdr_sdr_map_target_nits() == 1000.0);   // 域内（100..10000，gamescope --hdr-itm-target-nits 顶帽形态）
    float p[8]; int pv = present_sdr8(p, 8.0);   // ceiling 800 < 设置 1000 ⇒ p[3]=800（净空物理上限约束）
    CHECK(pv == HDR_PV_TO_PQ && p[2] == 100.0f && p[3] == 800.0f);
    hdr_snapshot sd = {0}; nvn2_hdr_snapshot_publish(&sd);
}
static void phase_target_eq_sdr(void) {
    CHECK(nvn2_hdr_sdr_map_target_nits() == 100.0);   // 域内但 = sdr：engage 门严格大于（target ≤ sdr 会压暗/重塑，设计稿 §2.2 实测）
    log_begin();
    float p[8]; int pv = present_sdr8(p, 4.0);
    CHECK(pv == HDR_PV_TO_PQ && p[2] == 0.0f && p[3] == 0.0f);   // 不 engage ⇒ 双零纯 mode 2
    CHECK(log_end("SDR 转 HDR 生效") == 0);
}
static void phase_target_low(void) {
    log_begin();
    CHECK(nvn2_hdr_sdr_map_target_nits() == 400.0);   // 域外（< 100）红行按缺省 400
    CHECK(log_end("【红】S2A_HDR_SDR_MAP_TARGET_NITS=50 看不懂") == 1);
}
static void phase_target_high(void) {
    log_begin();
    CHECK(nvn2_hdr_sdr_map_target_nits() == 400.0);   // 域外（> 10000）
    CHECK(log_end("【红】S2A_HDR_SDR_MAP_TARGET_NITS=20000 看不懂") == 1);
}
static void phase_target_garbage(void) {
    log_begin();
    CHECK(nvn2_hdr_sdr_map_target_nits() == 400.0);   // 垃圾值
    CHECK(log_end("【红】S2A_HDR_SDR_MAP_TARGET_NITS=9x9 看不懂") == 1);
}

// ---------- 相 14：S4 关 —— 层视角开关 = 玩家开关（S4 不掺和；off 缺省字节级回现状）----------
static void phase_layer_player(void) {
    unsetenv("S2A_HDR");
    CHECK(nvn2_hdr_layer_sw() == HDR_OFF);   // 未设 = off（层恒 S0，字节级回现状）
    setenv("S2A_HDR", "auto", 1);
    CHECK(nvn2_hdr_layer_sw() == HDR_AUTO);   // 玩家的 auto 原样带过（S4 关不掺和）
    setenv("S2A_HDR", "on", 1);
    CHECK(nvn2_hdr_layer_sw() == HDR_ON);
    setenv("S2A_HDR", "yes", 1);
    CHECK(nvn2_hdr_layer_sw() == HDR_OFF);   // 看不懂按 off（nvn2_hdr_switch 口径：红行一次、按 off）
    unsetenv("S2A_HDR");
}

// ---------- 相 15：S4 开 —— 层按 auto 进 / 持 PQ，vi 照玩家 off 口径恒不答 on=1（评审终稿全链路）----------
static void phase_layer_s4(void) {
    // 层视角开关：S4 开 ∧ 玩家 off（未设与显式 off 在 nvn2_hdr_switch 里同一个解析值——S4 只看玩家开没开，没开就补层）⇒ auto
    unsetenv("S2A_HDR");
    CHECK(nvn2_hdr_layer_sw() == HDR_AUTO);   // S4 开而 S2A_HDR 未设：层按 auto（S4 只让出图层持 PQ）
    setenv("S2A_HDR", "off", 1);
    CHECK(nvn2_hdr_layer_sw() == HDR_AUTO);   // 显式 off 同未设（玩家没开 HDR 上屏，层视角照 auto）
    setenv("S2A_HDR", "auto", 1);
    CHECK(nvn2_hdr_layer_sw() == HDR_AUTO);   // 玩家自己设了：以玩家为准（S4 不覆盖——auto 原样带过）
    setenv("S2A_HDR", "on", 1);
    CHECK(nvn2_hdr_layer_sw() == HDR_ON);     // 玩家的 on 原样带过
    // 全链路（生产入口）：HDR 屏 + s1_ready → 开机预挂进层（层视角开关）→ 层持 PQ 而 vi 恒答 on=0（off 不变量，S4 不改 vi 回答）
    setenv("S2A_HDR", "off", 1);
    hdr_snapshot pub = { .potential_edr = 2.0, .current_headroom = 2.0, .s1_ready = 1, .paper_white = 100 };
    nvn2_hdr_snapshot_publish(&pub);
    nvn2_hdr_preattach(1, 1000);   // 开机预挂：S4 开 ∧ 玩家 off ⇒ 照样进层（PQ 层载体是 S4 的生效面）
    hdr_snapshot s; nvn2_hdr_snapshot_probe(&s);
    CHECK(s.layer_pq == 1);   // 层持 PQ——原生 HDR 游戏此时看到的是 SDR 屏（vi 答 off）、输出 SDR、由 mode 2 上扩
    hdr_decision d = nvn2_hdr_answer(1, 1000);   // vi 答询走玩家开关（nvn2_hdr_answer 不读层视角）
    CHECK(d.vi_on == 0 && d.vi_fmt == 0 && d.vi_peak == 0);   // vi 照玩家 off 口径回答：恒不答 on=1（hdr_choose_mode off 分支原样）
    float p[8];
    int pv = nvn2_hdr_present(p, HDR_PF_SDR8, HDR_PT_PQ10);   // SDR 窗在 PQ 层上：mode 2 + S4 扩张（S4 关时同一调用恒纯 mode 2）
    CHECK(pv == HDR_PV_TO_PQ && p[2] == 100.0f && p[3] == 200.0f);   // engage：p[3] = effective target = min(400, 纸白 100 × 净空 2.0) = 200
    setenv("S2A_HDR", "auto", 1);   // 玩家改设 auto（nvn2_hdr_switch 逐次读环境，相内可翻）：vi 转照玩家回答
    d = nvn2_hdr_answer(1, 1000);
    CHECK(d.vi_on == 1 && d.vi_fmt == 1 && d.vi_peak > 0);   // 「先持层再答」：层已持 PQ → vi 放行 on=1（玩家设置永远优先）
    CHECK(nvn2_hdr_layer_sw() == HDR_AUTO);   // 层视角同为 auto（玩家的，不是 S4 补的）
    setenv("S2A_HDR", "on", 1);
    CHECK(nvn2_hdr_layer_sw() == HDR_ON);
    hdr_snapshot sd = {0}; nvn2_hdr_snapshot_publish(&sd);   // 段末清回缺省
    unsetenv("S2A_HDR");
}

#endif
int main(int argc, char **argv) {
#ifndef NVN2_HDR_SDR_MAP_SWITCH
    // 三态流红态：基线（PR-A 在、PR-B 未实现）上 nvn_hdr_policy.h 没有本在位标记——开关解析族未实现（编译期见不到它，运行期在这里显式红）
    (void)checks; (void)argc; (void)argv;   // 相函数全在守卫内：红态没有 CHECK 消费它
    printf("✗ t_hdr_sdr_map：PR-B（#625 第二阶段）开关解析族不在位——红态（基线无 NVN2_HDR_SDR_MAP_SWITCH：nvn2_hdr_sdr_map 族未实现）\n");
    return 1;
#else
    if (argc != 2) { printf("✗ t_hdr_sdr_map：要相名（off / on / zero / garbage / nits_in / nits_low / nits_high / nits_garbage / target_in / target_eq_sdr / target_low / target_high / target_garbage / layer_player / layer_s4）\n"); return 2; }
    unsetenv("S2A_HDR"); unsetenv("S2A_HDR_SDR_GAMMA");   // S2A_HDR 相 14/15 内自设自清；p[6] 缺省 2.2 不读 SDR_GAMMA——清掉防外环境干扰
    const char *ph = argv[1];
    if (!strcmp(ph, "off")) phase_off();
    else if (!strcmp(ph, "on")) phase_on();
    else if (!strcmp(ph, "zero")) phase_zero();
    else if (!strcmp(ph, "garbage")) phase_garbage();
    else if (!strcmp(ph, "nits_in")) phase_nits_in();
    else if (!strcmp(ph, "nits_low")) phase_nits_low();
    else if (!strcmp(ph, "nits_high")) phase_nits_high();
    else if (!strcmp(ph, "nits_garbage")) phase_nits_garbage();
    else if (!strcmp(ph, "target_in")) phase_target_in();
    else if (!strcmp(ph, "target_eq_sdr")) phase_target_eq_sdr();
    else if (!strcmp(ph, "target_low")) phase_target_low();
    else if (!strcmp(ph, "target_high")) phase_target_high();
    else if (!strcmp(ph, "target_garbage")) phase_target_garbage();
    else if (!strcmp(ph, "layer_player")) phase_layer_player();
    else if (!strcmp(ph, "layer_s4")) phase_layer_s4();
    else { printf("✗ t_hdr_sdr_map：认不得相名 %s\n", ph); return 2; }
    printf("✓ t_hdr_sdr_map：%s 相全部通过（%u 项）\n", ph, checks);
    return 0;
#endif
}
