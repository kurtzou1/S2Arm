// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 主机绑定（启动器「记住这台设备」，#521）：广播里手柄要唤醒的主机、0x15 绑定指令、蓝牙地址解析。纯函数，单测 runtime/ns2pro/tests/test_bond.c。
//   协议事实（按公开记录自己写，未拷参考实现）：
//   - 广播厂商数据 m[12..17]（公司号两字节之后第 10 字节起）是手柄按键唤醒时要找的主机地址（小端）；长按 SYNC 配对广播时全 0。
//   - 绑定 = 指令 0x15 依次 01（0x00 0x02 + 主机地址写两遍）、04（0x00 + 16 字节钥匙）、02（0x00 + 16 字节钥匙）、03（0x00）。
//     之后按任一键，手柄就唤醒这个地址。钥匙由主机自选，随机值即可；GATT 链路不加密，之后用不到钥匙。
//   - 一只手柄一次只记一台主机：接回游戏主机或别的电脑后改记那台，回来要再长按 SYNC。
#include "NS2Transport.h"
#include <string.h>
#include <stdio.h>

ns2_wake ns2_advert_wake(const uint8_t *m, size_t length, const uint8_t *our_host) {
    if (ns2_kind_from_manufacturer(m, length) == NS2_KIND_NONE || length < 18) return NS2_WAKE_UNKNOWN;
    const uint8_t *host = m + 12;
    int zero = 1;
    for (unsigned i = 0; i < 6; i++) zero &= host[i] == 0;
    if (zero) return NS2_WAKE_PAIRING;
    return our_host && !memcmp(host, our_host, 6) ? NS2_WAKE_US : NS2_WAKE_OTHER;
}

size_t ns2_bond_command(unsigned step, const uint8_t host[6], const uint8_t key1[16], const uint8_t key2[16], uint8_t out[NS2_BOND_COMMAND_MAX]) {
    static const uint8_t sub[NS2_BOND_STEPS] = {0x01, 0x04, 0x02, 0x03};
    if (!out || step >= NS2_BOND_STEPS) return 0;
    memset(out, 0, NS2_BOND_COMMAND_MAX);
    uint8_t *payload = out + 8;
    size_t n;
    switch (step) {
        case 0:
            if (!host) return 0;
            payload[0] = 0x00; payload[1] = 0x02; memcpy(payload + 2, host, 6); memcpy(payload + 8, host, 6); n = 14; break;
        case 1: case 2: {
            const uint8_t *key = step == 1 ? key1 : key2;
            if (!key) return 0;
            payload[0] = 0x00; memcpy(payload + 1, key, 16); n = 17; break;
        }
        default: payload[0] = 0x00; n = 1; break;
    }
    // 指令帧：指令、0x91、0x01（蓝牙）、子指令、0、负载长度、0、0、负载（同握手里的其他指令）
    out[0] = 0x15; out[1] = 0x91; out[2] = 0x01; out[3] = sub[step]; out[5] = (uint8_t)n;
    return 8 + n;
}

int ns2_bond_reply(const uint8_t *reply, size_t length) {
    // 只认指令号：绑定应答的方向 / 状态字节没有公开记录，不按握手指令的 0x78 校验，免得应答格式不同就把能用的连接断掉
    return reply && length >= 8 && reply[0] == 0x15;
}

int ns2_parse_bt_address(const char *text, uint8_t le[6]) {
    unsigned v[6]; char s[5]; int used = 0;
    if (!text || !le) return 0;
    if (sscanf(text, "%2x%c%2x%c%2x%c%2x%c%2x%c%2x%n", &v[0], &s[0], &v[1], &s[1], &v[2], &s[2], &v[3], &s[3], &v[4], &s[4], &v[5], &used) != 11 || text[used]) return 0;
    for (unsigned i = 0; i < 5; i++) if (s[i] != ':' && s[i] != '-') return 0;
    unsigned any = 0;
    for (unsigned i = 0; i < 6; i++) { le[i] = (uint8_t)v[5 - i]; any |= v[i]; }   // 文本是大端（aa:bb:…），广播与指令里是小端
    return any != 0;
}

int ns2_rearm_after_disconnect(int stream_ready, int session_failed) { return stream_ready && !session_failed; }

int ns2_link_idle(int waits_for_wake, int stream_ready, int connected) { return waits_for_wake && !stream_ready && !connected; }
