// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 触控板 / 鼠标 → 手柄状态的纯决策（#1869 PR 2）。规则照 Mac（macos/front_mac.m）：
//   鼠标键按 schema 1 的 mouse 段映射（0 左、1 右、2 中、3 / 4 侧键，同 NSEvent.buttonNumber），与键盘一起算（sample_input）；
//   「转动视角」锁定后位移 → 右摇杆（mouseMoved：× 1500 × 灵敏度，反转各乘 -1），读一次消费一次，回中 / 不回中同 take_mouse_delta；
//   点左键做什么同 mouseDown + left_click_touches。纯 C、无 UIKit / GameController 依赖，单测 runtime/tests/t_mouse_map.c 在 Mac 上跑。
#pragma once
#include <math.h>
#include <stdint.h>
#include "s2a_input_config.h"

// 鼠标位移换算系数：与 front_mac.m mouseMoved 的 1500 同值（t_mouse_map 读 front_mac.m 原文对照）
#define S2A_MOUSE_SCALE 1500
#define S2A_MOUSE_BUTTONS 5

// 按着的鼠标键（位 i = 按键 i）→ 手柄按键位 + 摇杆（front_mac.m sample_input 的鼠标段，与键盘同一个 action）
static inline void s2a_mouse_map(const s2a_input_config *c, unsigned held, uint32_t *buttons, int32_t sticks[4]) {
    for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++) {
        int b = c->mouse[t];
        if (b < 0 || b >= S2A_MOUSE_BUTTONS || !(held >> b & 1)) continue;
        if (t < 16) { *buttons |= 1u << t; continue; }
        int i = t - 16, axis = (i < 4 ? 0 : 2) + (i % 2);
        sticks[axis] += (i % 4 == 0 || i % 4 == 3) ? -32767 : 32767;
    }
}
// 一次位移 → 右摇杆增量（front_mac.m mouseMoved）。dx 向右为正、dy 向上为正（Mac 的 NSEvent.deltaY 向下为正，那边取反后同这里）
static inline void s2a_mouse_delta(const s2a_input_config *c, double dx, double dy, int64_t *ox, int64_t *oy) {
    *ox = llround(dx * S2A_MOUSE_SCALE * c->sensitivity_x * (c->invert_x ? -1 : 1));
    *oy = llround(dy * S2A_MOUSE_SCALE * c->sensitivity_y * (c->invert_y ? -1 : 1));
}
static inline int64_t s2a_mouse_clamp(int64_t v) { return v > 32767 ? 32767 : v < -32767 ? -32767 : v; }
// 读一次（front_mac.m take_mouse_delta）：回中 = 这一拍的位移加进右摇杆后清零；不回中 = 累进保持量，停手后右摇杆停在原处。
//   acc 是两次读之间攒下的位移，读后清零；hold 是不回中的保持量（失焦 / 复位清零）
static inline void s2a_mouse_take(int recenter, int64_t acc[2], int64_t hold[2], int32_t sticks[4]) {
    int64_t dx = acc[0], dy = acc[1];
    acc[0] = acc[1] = 0;
    if (!recenter) {
        hold[0] = s2a_mouse_clamp(hold[0] + dx); hold[1] = s2a_mouse_clamp(hold[1] + dy);
        dx = hold[0]; dy = hold[1];
    }
    sticks[2] = (int32_t)s2a_mouse_clamp((int64_t)sticks[2] + dx);
    sticks[3] = (int32_t)s2a_mouse_clamp((int64_t)sticks[3] + dy);
}

// 左键按下该做什么（front_mac.m mouseDown + left_click_touches，加上 iPad 的两种模式）
typedef enum {
    S2A_MOUSE_PASS = 0,   // 交给 UIKit 当手指：仅触屏模式（点就是触屏点）、按键模式下虚拟按键显示着（点虚拟按键）
    S2A_MOUSE_TOUCH,      // 当触屏点送进游戏（虚拟按键收起时由 controller.m 转给 vpad.m 的触点槽）
    S2A_MOUSE_LOCK,       // 只锁定鼠标、转视角，这一下不发按键
    S2A_MOUSE_BUTTON,     // 按 mouse 段映射发按键
} s2a_mouse_left_action;
typedef struct {
    int touch_only;        // 「仅触屏操作」方案
    int hidden;            // 按键模式下虚拟按键已收起（键盘接管或接着实体手柄）
    int locked;            // 鼠标已锁定
    int camera;            // 鼠标模式 = 转动视角
    int declared_default;  // 游戏声明了触屏配置，且键位是缺省（Mac 规则 ①）
    int left_bound;        // 左键映射了按键
} s2a_mouse_state;
static inline s2a_mouse_left_action s2a_mouse_left(s2a_mouse_state s) {
    if (s.touch_only || !s.hidden) return S2A_MOUSE_PASS;
    if (s.locked) return S2A_MOUSE_BUTTON;                // 锁定后左键照映射（缺省 Y）
    if (s.declared_default) return S2A_MOUSE_TOUCH;       // ① 先于视角锁定：缺省键位里的 Y / 转动视角让给触屏
    if (s.camera) return S2A_MOUSE_LOCK;                  // 没锁定时点一下只负责锁定
    return s.left_bound ? S2A_MOUSE_BUTTON : S2A_MOUSE_TOUCH;   // ② 仅按键模式：左键没别的用途就当触屏
}
// 右 / 中 / 侧键：仅触屏模式或虚拟按键收起时照映射发（同 Mac，与左键无关）；虚拟按键显示着时不进游戏（指针在点虚拟按键）
static inline int s2a_mouse_other_counts(s2a_mouse_state s) { return s.touch_only || s.hidden; }
// 该不该锁着：只在按键模式、虚拟按键收起、转动视角时。条件不成立（碰屏幕交回、切仅触屏、改了模式）就释放
static inline int s2a_mouse_may_lock(s2a_mouse_state s) { return !s.touch_only && s.hidden && s.camera; }
