// 连上就别自己断（runtime/ns2pro/NS2Keep.c）：握手可跳过的步骤、校准缺省、输入长度、应答匹配、震动可写、保活节奏。期望按参考实现记录手算。
#include "NS2Transport.h"
#include <stdio.h>
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
int main(void) {
    int required = 0;
    for (unsigned step = 0; step < 9; step++) required |= ns2_step_required(step) << step;
    CK(required == ((1 << 4) | (1 << 6)), "① 握手只有功能位设定 / 开启（第 4、6 步）必须应答，其余 7 步没应答就跳过");

    unsigned c[2] = {2048, 2050}, a[2] = {1300, 1310}, b[2] = {1290, 1280};
    CK(ns2_calibration_valid(c, a, b), "② 正常工厂校准算合格");
    unsigned c0[2] = {0, 2048}, ahi[2] = {3000, 1300}, bhi[2] = {2100, 1300};
    CK(!ns2_calibration_valid(c0, a, b) && !ns2_calibration_valid(c, ahi, b) && !ns2_calibration_valid(c, a, bhi) && !ns2_calibration_valid(NULL, a, b),
       "③ 中心为 0 / 中心 + 上行程超 4095 / 下行程超过中心 / 空：不合格");
    unsigned dc[2], da[2], db[2];
    ns2_calibration_default(dc, da, db);
    CK(dc[0] == 2048 && dc[1] == 2048 && da[0] == 1200 && da[1] == 1200 && db[0] == 1200 && db[1] == 1200 && ns2_calibration_valid(dc, da, db),
       "④ 缺省校准：中心 2048、上下行程 1200，本身合格");

    CK(!ns2_input_length_ok(62) && ns2_input_length_ok(63) && ns2_input_length_ok(80) && !ns2_input_length_ok(81) && !ns2_input_length_ok(0),
       "⑤ 输入通知只认 63..80 字节：62 / 81 / 0 跳过");

    const uint8_t req[12] = {0x0c, 0x91, 1, 2, 0, 4, 0, 0, 0x2b};
    const uint8_t ok[8] = {0x0c, 1, 1, 2, 0, 0x78, 0, 0}, odd[8] = {0x0c, 2, 1, 2, 0, 0x10, 0, 0}, other[8] = {0x09, 1, 1, 7, 0, 0x78, 0, 0};
    CK(ns2_ack_matches(ok, 8, req, 12) && ns2_ack_matches(odd, 8, req, 12) && !ns2_ack_matches(other, 8, req, 12) && !ns2_ack_matches(ok, 7, req, 12),
       "⑥ 应答按指令号 + 子指令号认：方向 / 第 5 字节不同也算这条的；别的指令（玩家灯）不算；不足 8 字节不算");
    CK(ns2_ack_usual(ok, 8) && !ns2_ack_usual(odd, 8), "⑦ 常见应答（01 01 … 78）与不常见的分得开（不常见只记日志）");

    CK(ns2_rumble_writable(1, 42) && ns2_rumble_writable(1, 182) && !ns2_rumble_writable(1, 41) && !ns2_rumble_writable(0, 182),
       "⑧ 震动特征在且单次写入 ≥ 42 字节才写震动；否则只停震动");

    const uint64_t s = 1000000000ull;
    CK(!ns2_keepalive_due(10 * s, 10 * s) && !ns2_keepalive_due(10 * s, 12 * s) && ns2_keepalive_due(10 * s, 13 * s) && ns2_keepalive_due(0, 3 * s),
       "⑨ 保活：上次写入后满 3 秒才写（2 秒不写），远低于参考实现记录的约 10 秒断线");
    printf(bad ? "\n%d 项失败\n" : "\n全部通过\n", bad);
    return bad != 0;
}
