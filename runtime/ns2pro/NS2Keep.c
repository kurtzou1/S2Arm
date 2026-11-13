// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 连上就别自己断：握手哪几步可以跳过、摇杆校准不合格时的缺省值、哪些通知长度当输入、指令应答怎么认、空闲多久写一次保活。
//   纯函数，单测 runtime/ns2pro/tests/test_keep.c。
//   依据（参考实现 nxnative 的手柄协议头与 CoreBluetooth 传输，按其记录自己写，未拷代码）：
//   - 参考实现的握手只发读内存、功能位设定 / 开启（0x0C 02 / 04）、玩家灯；本传输多发的 07/01、03/0a、0a/08、0a/02（连接提示震动）
//     和两次校准读取，没有应答时照常往下走；只有功能位两步决定手柄出不出输入，必须成功。
//   - 参考实现认应答只看指令号，加上第 1 字节为 1 或 2；不看第 5 字节。
//   - 参考实现校准读不到 / 不合格时用中心 2048、行程 1200；输入通知只认 0x3C..0x50 字节（同一特征也送更长的音频包）。
//   - 参考实现记录：主机约 10 秒没有任何写入，链路就断（Joy-Con 2 实测）；它每秒写一次玩家灯。
#include "NS2Transport.h"

int ns2_step_required(unsigned step) { return step == 4 || step == 6; }

int ns2_calibration_valid(const unsigned center[2], const unsigned above[2], const unsigned below[2]) {
    if (!center || !above || !below) return 0;
    for (unsigned axis = 0; axis < 2; axis++)
        if (!center[axis] || !above[axis] || !below[axis] || center[axis] + above[axis] > 4095 || below[axis] > center[axis]) return 0;
    return 1;
}

void ns2_calibration_default(unsigned center[2], unsigned above[2], unsigned below[2]) {
    for (unsigned axis = 0; axis < 2; axis++) { center[axis] = NS2_CAL_DEFAULT_CENTER; above[axis] = below[axis] = NS2_CAL_DEFAULT_TRAVEL; }
}

int ns2_input_length_ok(size_t length) { return length >= NS2_INPUT_MIN && length <= NS2_INPUT_MAX; }

int ns2_ack_matches(const uint8_t *reply, size_t length, const uint8_t *request, size_t request_length) {
    return reply && request && length >= 8 && request_length >= 4 && reply[0] == request[0] && reply[3] == request[3];
}

int ns2_ack_usual(const uint8_t *reply, size_t length) {
    return reply && length >= 8 && reply[1] == 1 && reply[2] == 1 && (reply[5] & 0x7f) == 0x78;
}

int ns2_rumble_writable(int has_characteristic, size_t max_write) { return has_characteristic && max_write >= 42; }

int ns2_keepalive_due(uint64_t last_write_ns, uint64_t now_ns) { return now_ns - last_write_ns >= NS2_KEEPALIVE_NS; }
