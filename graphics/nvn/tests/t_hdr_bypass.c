// PR3d AA/FX/FI 旁路判定单测（评审稿 v3 §2.5 开关矩阵 / §3 A3 行 / §4 PR3d「新单测」行）：
//   旁路判定纯逻辑（窗口格式 × S2A_HDR 开关 × vi 答过 latch——RGB10A2 只在答过后才当 PQ 码值，m0b 实证）全矩阵直调
//   + nvn2.c 存储侧入口（nvn2_hdr_bypass_upscale：latch 不在快路径 0、答过后 SDR 窗（含 float / 未归类）照常、
//   off 不变量经存储入口同成立——off 局 latch 本就恒 0，开关再挡一道，缺省字节级零行为变化）。
//   纯 C，不需要 GPU / 游戏（同 t_hdr_layer 口径）。三态流的 test-only / negctl 态的红由此而来：
//   基线（无 PR3d 实现）上 hdr_bypass_upscale 与 nvn2_hdr_bypass_upscale 不存在——编译期报未声明函数。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_hdr_policy.h"
static unsigned checks;
#define CHECK(c) do { checks++; if (!(c)) { printf("✗ t_hdr_bypass：第 %d 行不通：%s\n", __LINE__, #c); exit(1); } } while (0)

int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && !strcmp(d, "1"); }   // 替身：同 t_hdr_layer（宿主不链进本单测）

int main(void) {
    // ---------- 旁路判定纯逻辑全矩阵（hdr_bypass_upscale：窗口格式 × 开关 × vi 答过）----------
    //   唯一旁路组合 = 非 off ∧ 源是 HDR10 窗 ∧ vi 答过（RGB10A2 ∧ 答过 = PQ 码值——m0b 实证游戏在 on=1 后才建 0x3d 窗）；
    //   未答过的 10 位窗按 10 位 gamma SDR 走（§2.4 mode 2 口径）、8 位窗 / float 窗 / 未知格式都照常走 AA/FX/FI——SDR 语义不旁路
    for (int sw = 0; sw <= 2; sw++) for (int pf = 0; pf <= 3; pf++) for (int an = 0; an <= 1; an++)
        CHECK(hdr_bypass_upscale(sw, pf, an) == (sw != HDR_OFF && pf == HDR_PF_HDR10 && an));

    // ---------- 存储侧入口（nvn2_hdr_bypass_upscale：出图热路径口径——读已算好的结果）----------
    {   // 缺省（vi 未答过——off 缺省局 latch 恒 0）：全格式不旁路（快路径零锁零 getenv，字节级同现状）
        unsetenv("S2A_HDR");
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_HDR10) == 0);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_SDR8) == 0);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_FLOAT) == 0);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_OTHER) == 0);
        // auto ∧ 未答过（游戏没问过 vi / 答了 no）：仍不旁路——latch 是「当 PQ 码值」的判据，开关不替 latch 猜
        setenv("S2A_HDR", "auto", 1);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_HDR10) == 0);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_SDR8) == 0);
        // 答过（nvn2_hdr_answer 的 latch 簿记——vi 答 on=1 → 置 1 永不清）：
        //   HDR10 窗旁路；SDR8 / float / 未知照常（SDR 窗口照常——含层在 PQ 态的排空帧：先缩放后 mode 2 转换）
        hdr_snapshot pub = { .potential_edr = 2.0, .current_headroom = 2.0, .s1_ready = 1, .paper_white = 100 };
        nvn2_hdr_snapshot_publish(&pub);
        nvn2_hdr_tick(HDR_AUTO, 1, 1000);
        nvn2_hdr_tick(HDR_AUTO, 1, 1500);   // can 持稳 500ms → 进层（「先持层再答」，§2.3 第 4 条）
        hdr_decision ad = nvn2_hdr_answer(1, 1500);   // vi 答 on=1 → latch 置 1（答过永不清）
        CHECK(ad.vi_on == 1);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_HDR10) == 1);   // HDR 窗（PQ 码值）：旁路 AA/FX/FI
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_SDR8) == 0);    // SDR 窗照常（层在 PQ 态：先缩放后 mode 2 转换）
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_FLOAT) == 0);   // float 窗占位：HDR10 之外的源不旁路
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_OTHER) == 0);
        // off 不变量（latch 已置、开关拨回 off）：不旁路——S2A_HDR=off 缺省字节级零行为变化
        setenv("S2A_HDR", "off", 1);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_HDR10) == 0);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_SDR8) == 0);
        // on：强制 HDR 管线同样旁路（S3 兜底时 vi 仍答 on=1——HDR 窗仍是 PQ 码值）
        setenv("S2A_HDR", "on", 1);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_HDR10) == 1);
        // 看不懂的值：按 off（缺省关，字节级回现状——同 nvn2_hdr_switch 口径）
        setenv("S2A_HDR", "1", 1);
        CHECK(nvn2_hdr_bypass_upscale(HDR_PF_HDR10) == 0);
        // 段末清回缺省（t_hdr_layer 收尾同款）
        unsetenv("S2A_HDR");
        memset(&pub, 0, sizeof pub);
        nvn2_hdr_snapshot_publish(&pub);
    }

    printf("✓ t_hdr_bypass：全部通过（%u 项）\n", checks);
    return 0;
}
