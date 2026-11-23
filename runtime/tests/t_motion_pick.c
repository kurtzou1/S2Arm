// 玩家 1 六轴来源仲裁（runtime/src/motion_pick.c）：期望按「谁在操作 + 谁有样本」手算，不复述实现。
//   输入来源用 s2a_pad_source 原值（0 触屏 / 1 NS2 Pro BLE / 2 系统手柄）；known 非 0 = 那一路这一帧有样本。
#include "motion_pick.h"
#include <stdio.h>

static int bad;
static void expect(const char *what, int got, int want) {
    if (got != want) { printf("✗ %s：期望 %d → 实际 %d\n", what, want, got); bad++; }
}
// 反向检查：返回的那一路必须真的有样本（没有就拿 NONE）
static void expect_never_missing(const char *what, int got, int ns2, int gc, int phone) {
    int ok = got == S2A_MOTION_NONE || (got == S2A_MOTION_NS2 && ns2) || (got == S2A_MOTION_GC && gc) || (got == S2A_MOTION_PHONE && phone);
    if (!ok) { printf("✗ %s：返回 %d，但那一路没有样本（ns2=%d gc=%d phone=%d）\n", what, got, ns2, gc, phone); bad++; }
}

int main(void) {
    // ① 11-15 维护者改规则：接了有体感的手柄就用手柄，不管触屏在不在操作
    expect("① 触屏在操作 + 系统手柄有体感 → 用手柄（不再切手机）", s2a_motion_pick(0, 0, 1, 1), S2A_MOTION_GC);
    expect("① 触屏在操作 + 只有 NS2 有体感 → NS2", s2a_motion_pick(0, 1, 0, 1), S2A_MOTION_NS2);
    expect("① 触屏在操作 + 没接手柄 → 手机", s2a_motion_pick(0, 0, 0, 1), S2A_MOTION_PHONE);
    expect("① 触屏 + 都没有", s2a_motion_pick(0, 0, 0, 0), S2A_MOTION_NONE);
    // ② 系统手柄在驱动输入
    expect("② 系统 + 三路都有 → 手柄", s2a_motion_pick(2, 1, 1, 1), S2A_MOTION_GC);
    expect("② 系统手柄无体感（Xbox / Joy-Con 一代 / 夹手机的手柄）、没 NS2 → 手机", s2a_motion_pick(2, 0, 0, 1), S2A_MOTION_PHONE);
    expect("② 系统手柄无体感、NS2 有 → NS2", s2a_motion_pick(2, 1, 0, 1), S2A_MOTION_NS2);
    expect("② 系统 + 都没有", s2a_motion_pick(2, 0, 0, 0), S2A_MOTION_NONE);
    // ③ NS2 Pro 在驱动输入：两只手柄都在时先读 NS2（不读错刚体）
    expect("③ NS2 + 三路都有 → NS2", s2a_motion_pick(1, 1, 1, 1), S2A_MOTION_NS2);
    expect("③ NS2 还没出样本 → 系统手柄", s2a_motion_pick(1, 0, 1, 1), S2A_MOTION_GC);
    expect("③ 两只手柄都没样本 → 手机", s2a_motion_pick(1, 0, 0, 1), S2A_MOTION_PHONE);
    // ④ 负对照：手机陀螺仪关掉（phone=0）时不许返回手机；有手柄体感时任何输入来源都不许返回手机
    expect("④ 手机陀螺仪关、没接手柄 → NONE", s2a_motion_pick(0, 0, 0, 0), S2A_MOTION_NONE);
    for (int sel = 0; sel <= 3; sel++) { char w[64]; snprintf(w, sizeof w, "④ sel=%d 有手柄体感时不用手机", sel);
        expect(w, s2a_motion_pick(sel, 0, 1, 1) == S2A_MOTION_PHONE || s2a_motion_pick(sel, 1, 0, 1) == S2A_MOTION_PHONE, 0); }
    // ⑤ 全表：任何组合都不许返回「没有样本」的那一路
    for (int sel = 0; sel <= 3; sel++)
        for (int ns2 = 0; ns2 <= 1; ns2++)
            for (int gc = 0; gc <= 1; gc++)
                for (int phone = 0; phone <= 1; phone++) {
                    char what[96];
                    snprintf(what, sizeof what, "⑤ 全表 sel=%d ns2=%d gc=%d phone=%d", sel, ns2, gc, phone);
                    int got = s2a_motion_pick(sel, ns2, gc, phone);
                    expect_never_missing(what, got, ns2, gc, phone);
                    if (!ns2 && !gc && !phone) expect(what, got, S2A_MOTION_NONE);
                }
    // ⑥ 手柄体感按新鲜样本判（S2A_MOTION_STALE_MS = 500）：期望按「收到过、且最近一帧不超过 500 ms」手算
    const uint64_t T = 10000000;   // 任取的「现在」：10 秒（微秒）
    { const float z[3] = {0, 0, 0}, g1[3] = {0, 0, 1}, tiny[3] = {0, 0.0001f, 0}, neg[3] = {-0.0f, -0.0f, -0.0f};
      expect("⑦ 六个值全 0 → 空样本（传感器没开）", s2a_motion_blank(z, z), 1);
      expect("⑦ -0.0 也是 0 → 空样本（日志里的 (-0.00, -0.00, -0.00)）", s2a_motion_blank(neg, neg), 1);
      expect("⑦ 平放静止（重力 1 g、角速度 0）→ 不是空样本", s2a_motion_blank(g1, z), 0);
      expect("⑦ 只有一点角速度 → 不是空样本", s2a_motion_blank(z, tiny), 0); }
    expect("⑥ 从没收到过样本 → 没有", s2a_motion_fresh(0, 0, T), 0);
    expect("⑥ 10 ms 前的样本 → 有", s2a_motion_fresh(1, T - 10000, T), 1);
    expect("⑥ 正好 500 ms 前 → 有（边界含）", s2a_motion_fresh(1, T - 500000, T), 1);
    expect("⑥ 501 ms 前 → 没有", s2a_motion_fresh(1, T - 501000, T), 0);
    expect("⑥ 样本时刻晚于现在（读数与写入跨线程）→ 有", s2a_motion_fresh(1, T + 5, T), 1);
    // ⑦ 玩家反馈的两种无陀螺仪夹持手柄 + 正常有体感手柄，按系统手柄在操作（sel = 2）、手机陀螺仪开着走完整条判定
    //   a. 系统给了体感对象却从不出样本：ever = 0 → 手机
    expect("⑦a 有体感对象但从不出样本 → 手机", s2a_motion_pick(2, 0, s2a_motion_fresh(0, 0, T), 1), S2A_MOTION_PHONE);
    //   b. 刚接上出过一帧（t = 1 秒）就停，现在 10 秒 → 手机
    expect("⑦b 出过一帧就停 → 手机", s2a_motion_pick(2, 0, s2a_motion_fresh(1, 1000000, T), 1), S2A_MOTION_PHONE);
    //   c. 手柄真有体感、样本持续到来（8 ms 前一帧）→ 照旧用手柄（11-15 维护者原则不变）
    expect("⑦c 手柄有体感、样本新鲜 → 手柄", s2a_motion_pick(2, 0, s2a_motion_fresh(1, T - 8000, T), 1), S2A_MOTION_GC);
    //   d. b 的情形手机陀螺仪也关着 → NONE（不许回落到一帧旧数据）
    expect("⑦d 出过一帧就停、手机陀螺仪关 → NONE", s2a_motion_pick(2, 0, s2a_motion_fresh(1, 1000000, T), 0), S2A_MOTION_NONE);
    // ⑧ 提示：有体感对象（capable = 1）却超过 2000 ms 没新鲜样本才算「没体感」；capable = 2 走原提示路径，这里不判
    expect("⑧ 有体感对象、3 秒没样本 → 提示", s2a_motion_pad_silent(1, T - 3000000, T), 1);
    expect("⑧ 有体感对象、1 秒没样本（宽限期内）→ 不提示", s2a_motion_pad_silent(1, T - 1000000, T), 0);
    expect("⑧ 正好 2000 ms → 不提示（边界不含）", s2a_motion_pad_silent(1, T - 2000000, T), 0);
    expect("⑧ 刚有新鲜样本（last_ok = 现在）→ 不提示", s2a_motion_pad_silent(1, T, T), 0);
    expect("⑧ 系统不给体感对象（capable = 2）→ 本函数不判", s2a_motion_pad_silent(2, 0, T), 0);
    expect("⑧ 空槽（capable = 0）→ 不判", s2a_motion_pad_silent(0, 0, T), 0);
    if (bad) { printf("✗ t_motion_pick：%d 处不符\n", bad); return 1; }
    printf("✓ t_motion_pick：%d 组手算 + 全表 64 组一致性全符（有手柄体感就用手柄、不看触屏；手柄都没样本才用手机；无样本→NONE；"
           "手柄样本超过 500 ms 不新鲜就当没有：不出样本 / 出一帧就停的手柄都回到手机）\n", 17 + 15 + 4);
    return 0;
}
