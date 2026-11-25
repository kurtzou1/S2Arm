// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 兜底手柄的纯解析（不碰 IOKit）：宿主 macos/hid_pad.m 与启动器 LauncherPadBridge/HIDPads.m 共用一份（#1151：启动器游戏库也要读 PowerA 这类手柄）。
//   按键位是 Npad 顺序（第 0 位 A … 第 15 位 下），同 hid_generic.h 的 S2A_HIDG_* 与启动器 LauncherPadInput
#ifndef S2A_MAC_HID_PRO_PARSE_H
#define S2A_MAC_HID_PRO_PARSE_H
#include <stddef.h>
#include <stdint.h>

enum { S2A_HPB_EAST = 1u << 0, S2A_HPB_SOUTH = 1u << 1, S2A_HPB_NORTH = 1u << 2, S2A_HPB_WEST = 1u << 3, S2A_HPB_LSTICK = 1u << 4, S2A_HPB_RSTICK = 1u << 5,
       S2A_HPB_L = 1u << 6, S2A_HPB_R = 1u << 7, S2A_HPB_ZL = 1u << 8, S2A_HPB_ZR = 1u << 9, S2A_HPB_PLUS = 1u << 10, S2A_HPB_MINUS = 1u << 11,
       S2A_HPB_LEFT = 1u << 12, S2A_HPB_UP = 1u << 13, S2A_HPB_RIGHT = 1u << 14, S2A_HPB_DOWN = 1u << 15 };
typedef struct { uint16_t cx, cy, xmax, ymax, xmin, ymin; } s2a_pro_cal;   // xmax / ymax：中心以上的行程；xmin / ymin：中心以下的行程

// Switch Pro 简单 HID 报告（0x3F，元素直读）的按键号 → Npad 位
static inline uint32_t s2a_hpp_button_bit(int usage) {
    static const uint32_t map[] = {0, S2A_HPB_SOUTH, S2A_HPB_EAST, S2A_HPB_WEST, S2A_HPB_NORTH, S2A_HPB_L, S2A_HPB_R, S2A_HPB_ZL, S2A_HPB_ZR, S2A_HPB_MINUS, S2A_HPB_PLUS, S2A_HPB_LSTICK, S2A_HPB_RSTICK};
    return usage > 0 && usage < (int)(sizeof map / sizeof *map) ? map[usage] : 0;   // 13 Home、14 截图不进游戏键位
}
static inline uint32_t s2a_hpp_hat_bits(long v, long min, long max) {
    static const uint32_t dir[8] = {S2A_HPB_UP, S2A_HPB_UP | S2A_HPB_RIGHT, S2A_HPB_RIGHT, S2A_HPB_DOWN | S2A_HPB_RIGHT, S2A_HPB_DOWN, S2A_HPB_DOWN | S2A_HPB_LEFT, S2A_HPB_LEFT, S2A_HPB_UP | S2A_HPB_LEFT};
    if (v < min || v > max || max - min < 7) return 0;
    long i = v - min; return i < 8 ? dir[i] : 0;
}
static inline int16_t s2a_hpp_axis(long v, long min, long max, int invert) {
    if (max <= min) return 0;
    double f = 2.0 * (double)(v - min) / (double)(max - min) - 1.0;
    if (f < -1) f = -1; if (f > 1) f = 1;
    if (invert) f = -f;
    return (int16_t)(f * 32767.0);
}
// 读不到出厂校准（第三方「… Pro Controller」常不回 SPI 0x603D，#1264 PowerA）：中心 2048、行程起点 1003，之后按实际推到的最远处放大
//   （同参考实现 SDL3 hidapi_switch.c：缺省行程 = 中心 × 0.7，摇杆范围再从它的 0.7 起、随读数扩大）
static inline void s2a_hpp_cal_default(s2a_pro_cal *c) { c->cx = c->cy = 2048; c->xmax = c->ymax = c->xmin = c->ymin = 1003; }
static inline int16_t s2a_hpp_pro_axis(int v, int center, int above, int below) {
    int dv = v - center; double f = dv > 0 ? (above > 0 ? (double)dv / above : 0) : (below > 0 ? (double)dv / below : 0);
    if (f > 1) f = 1; if (f < -1) f = -1;
    return (int16_t)(f * 32767.0);
}
// 行程随读数扩大：这一拍离中心比记下的行程还远，就把它当新的行程（推到底就是满量程），再按行程换算
static inline int16_t s2a_hpp_pro_axis_grow(int v, int center, uint16_t *above, uint16_t *below) {
    int dv = v - center;
    if (dv > *above) *above = (uint16_t)dv;
    if (-dv > *below) *below = (uint16_t)-dv;
    return s2a_hpp_pro_axis(v, center, *above, *below);
}
// 0x30 完整报告 / 0x21 子命令应答（报告号在首字节）：按键 3 字节 + 12 位摇杆；ax 顺序 左 x y、右 x y，Y 向上为正（同 GameController）
static inline int s2a_hpp_pro_parse(const uint8_t *r, size_t n, s2a_pro_cal *l, s2a_pro_cal *rc, uint32_t *buttons, int16_t ax[4]) {
    if (n < 12 || (r[0] != 0x30 && r[0] != 0x21)) return 0;
    uint8_t a = r[3], m = r[4], b = r[5]; uint32_t o = 0;
    if (a & 0x01) o |= S2A_HPB_WEST; if (a & 0x02) o |= S2A_HPB_NORTH; if (a & 0x04) o |= S2A_HPB_SOUTH; if (a & 0x08) o |= S2A_HPB_EAST; if (a & 0x40) o |= S2A_HPB_R; if (a & 0x80) o |= S2A_HPB_ZR;
    if (m & 0x01) o |= S2A_HPB_MINUS; if (m & 0x02) o |= S2A_HPB_PLUS; if (m & 0x04) o |= S2A_HPB_RSTICK; if (m & 0x08) o |= S2A_HPB_LSTICK;
    if (b & 0x01) o |= S2A_HPB_DOWN; if (b & 0x02) o |= S2A_HPB_UP; if (b & 0x04) o |= S2A_HPB_RIGHT; if (b & 0x08) o |= S2A_HPB_LEFT; if (b & 0x40) o |= S2A_HPB_L; if (b & 0x80) o |= S2A_HPB_ZL;
    *buttons = o;
    int lx = r[6] | ((r[7] & 0xF) << 8), ly = (r[7] >> 4) | (r[8] << 4), rx = r[9] | ((r[10] & 0xF) << 8), ry = (r[10] >> 4) | (r[11] << 4);
    ax[0] = s2a_hpp_pro_axis_grow(lx, l->cx, &l->xmax, &l->xmin); ax[1] = s2a_hpp_pro_axis_grow(ly, l->cy, &l->ymax, &l->ymin);
    ax[2] = s2a_hpp_pro_axis_grow(rx, rc->cx, &rc->xmax, &rc->xmin); ax[3] = s2a_hpp_pro_axis_grow(ry, rc->cy, &rc->ymax, &rc->ymin);
    return 1;
}
#endif
