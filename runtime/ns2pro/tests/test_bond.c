// 主机绑定（runtime/ns2pro/NS2Bond.c，#521）：广播里的唤醒对象、0x15 绑定指令、蓝牙地址解析。期望按协议事实手写，未在实机验证。
#include "NS2Transport.h"
#include <stdio.h>
#include <string.h>
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
int main(void) {
    // 厂商数据 18 字节：公司号 53 05、…、VID 7e 05、产品号、…、m[12..17] 手柄要唤醒的主机（小端）
    const uint8_t us[6] = {0x66, 0x55, 0x44, 0x33, 0x22, 0x11};
    uint8_t pairing[18] = {0x53, 0x05, 1, 0, 3, 0x7e, 0x05, 0x69, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    uint8_t wake_us[18], wake_other[18];
    memcpy(wake_us, pairing, 18); memcpy(wake_us + 12, us, 6);
    memcpy(wake_other, pairing, 18); memcpy(wake_other + 12, us, 6); wake_other[17] = 0x99;
    CK(ns2_advert_wake(pairing, 18, us) == NS2_WAKE_PAIRING && ns2_advert_wake(pairing, 18, NULL) == NS2_WAKE_PAIRING, "① 主机全 0：配对广播（长按 SYNC）；不管本机地址知不知道");
    CK(ns2_advert_wake(wake_us, 18, us) == NS2_WAKE_US, "② 主机 = 本机地址：唤醒本机");
    CK(ns2_advert_wake(wake_other, 18, us) == NS2_WAKE_OTHER && ns2_advert_wake(wake_us, 18, NULL) == NS2_WAKE_OTHER, "③ 主机是别的地址 / 本机地址不知道：唤醒其他主机");
    uint8_t joycon[18]; memcpy(joycon, pairing, 18); joycon[7] = 0x66;   // 右只 0x2066
    CK(ns2_advert_wake(joycon, 18, us) == NS2_WAKE_PAIRING, "④ Joy-Con 2 同一套字段");
    uint8_t apple[18]; memcpy(apple, pairing, 18); apple[0] = 0x4c; apple[1] = 0x00;
    CK(ns2_advert_wake(pairing, 17, us) == NS2_WAKE_UNKNOWN && ns2_advert_wake(apple, 18, us) == NS2_WAKE_UNKNOWN && ns2_advert_wake(NULL, 18, us) == NS2_WAKE_UNKNOWN,
       "⑤ 负对照：不够 18 字节 / 公司号不对 / 空 → 未知（不当成配对，不写绑定）");

    uint8_t k1[16], k2[16], out[NS2_BOND_COMMAND_MAX];
    for (int i = 0; i < 16; i++) { k1[i] = (uint8_t)(0xa0 + i); k2[i] = (uint8_t)(0xb0 + i); }
    size_t n = ns2_bond_command(0, us, k1, k2, out);
    const uint8_t want0[22] = {0x15, 0x91, 0x01, 0x01, 0, 14, 0, 0, 0x00, 0x02, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11};
    CK(n == 22 && !memcmp(out, want0, 22), "⑥ 第 1 条 0x15/01：帧头 15 91 01 01 00 0e 00 00，负载 00 02 + 本机地址写两遍（实长 %zu）", n);
    n = ns2_bond_command(1, us, k1, k2, out);
    CK(n == 25 && out[0] == 0x15 && out[3] == 0x04 && out[5] == 17 && out[8] == 0 && !memcmp(out + 9, k1, 16), "⑦ 第 2 条 0x15/04：00 + 钥匙一（17 字节负载）");
    n = ns2_bond_command(2, us, k1, k2, out);
    CK(n == 25 && out[3] == 0x02 && out[5] == 17 && !memcmp(out + 9, k2, 16), "⑧ 第 3 条 0x15/02：00 + 钥匙二");
    n = ns2_bond_command(3, us, k1, k2, out);
    const uint8_t want3[9] = {0x15, 0x91, 0x01, 0x03, 0, 1, 0, 0, 0x00};
    CK(n == 9 && !memcmp(out, want3, 9), "⑨ 第 4 条 0x15/03：负载只有 00");
    CK(ns2_bond_command(4, us, k1, k2, out) == 0 && ns2_bond_command(0, NULL, k1, k2, out) == 0 && ns2_bond_command(1, us, NULL, k2, out) == 0,
       "⑩ 负对照：步号越界 / 缺地址 / 缺钥匙 → 0（不发半截指令）");

    const uint8_t reply[8] = {0x15, 0x02, 0x01, 0x03, 0, 0, 0, 0}, other[8] = {0x02, 0x01, 0x01, 0x04, 0, 0x78, 0, 0};
    CK(ns2_bond_reply(reply, 8) && !ns2_bond_reply(other, 8) && !ns2_bond_reply(reply, 7) && !ns2_bond_reply(NULL, 8),
       "⑪ 绑定应答只认指令号 0x15（第 1 字节是 2 也收）；别的指令 / 太短 / 空不收");

    uint8_t le[6];
    CK(ns2_parse_bt_address("11-22-33-44-55-66", le) && !memcmp(le, us, 6), "⑫ \"11-22-33-44-55-66\" → 小端 66 55 44 33 22 11");
    CK(ns2_parse_bt_address("11:22:33:44:55:66", le) && !memcmp(le, us, 6), "⑬ 冒号分隔同样认");
    CK(!ns2_parse_bt_address("00-00-00-00-00-00", le) && !ns2_parse_bt_address("11-22-33-44-55", le) && !ns2_parse_bt_address("11-22-33-44-55-66x", le) &&
       !ns2_parse_bt_address("11 22 33 44 55 66", le) && !ns2_parse_bt_address(NULL, le),
       "⑭ 负对照：全 0 / 少一段 / 尾巴多字 / 空格分隔 / 空 → 0（读不到地址就不绑定）");
    CK(ns2_rearm_after_disconnect(1, 0) && !ns2_rearm_after_disconnect(0, 0) && !ns2_rearm_after_disconnect(1, 1),
       "⑮ 断线后接回：用着的手柄断开就挂直连（绑定与否都挂）；还没握手完 / 握手失败断开的不挂");
    CK(ns2_link_idle(1, 0, 0) && !ns2_link_idle(1, 0, 1) && !ns2_link_idle(1, 1, 1) && !ns2_link_idle(0, 0, 0),
       "⑯ 挂着等的链路：系统还没连上才算不占位；已连上在握手 / 已就绪 / 普通 30 秒直连都占位");
    printf(bad ? "\n%d 项不通过\n" : "\n全部通过\n", bad);
    return bad != 0;
}
