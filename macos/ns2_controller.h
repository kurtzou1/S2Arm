// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_MAC_NS2_CONTROLLER_H
#define S2A_MAC_NS2_CONTROLLER_H
#include "../runtime/ns2pro/include/NS2Transport.h"
#include "../runtime/include/s2a_pad.h"

// The menu and the remembered-controller startup path share the same transport.
int s2a_mac_ns2_connect(void);
void s2a_mac_ns2_disconnect(void);
void s2a_mac_ns2_detach(void);
void s2a_mac_ns2_focus(int focused);
// 读手柄状态；单只 Joy-Con 按游戏样式整形（s2a_mac_ns2_shape），side_keys 收 SL / SR（Ryujinx ControllerKeys 位 24–27，可 NULL）
int s2a_mac_ns2_read(ns2_state *state, uint32_t *side_keys);
// 游戏这一格的手柄样式（Ryujinx ControllerType 位；front_mac.m 的 s2a_vpad_set_style 转来）
void s2a_mac_ns2_set_game_style(int style);
// 现在是否在报原始方向（连着单只 Joy-Con、游戏用它那一侧的单只样式）
int s2a_mac_ns2_raw_now(void);
// 纯函数（#520 A）：游戏用这只那一侧的单只样式才报原始方向；单只 Joy-Con 对应的样式（Pro / 一对 / 没连为 0）；
//   整形：原始方向时取出 SL / SR 换成 Ryujinx 键位返回，否则转横握视角、返回 0；不是单只 Joy-Con 不动
int s2a_mac_ns2_raw_wanted(ns2_kind kind, int style);
int s2a_mac_ns2_single_style(ns2_kind kind);
uint32_t s2a_mac_ns2_shape(ns2_kind kind, int raw, ns2_state *state);
void s2a_mac_ns2_set_back_buttons(uint16_t left, uint16_t right);
ns2_status s2a_mac_ns2_status(void);
// 通道模式下开局后还没接上过（IDLE）时要不要去连：通道文件在（S2Arm 的连接程序启动时建、退出时删）才连。
//   玩家开局后才在 S2Arm 连手柄也能接回；只用键盘、没开连接程序时什么都不做（游戏窗口每秒问一次）
int s2a_mac_ns2_relay_due(ns2_status status, const char *relay);
// 当前连着的型号（通道 v2 / 直连都一样；没就绪为 NONE）与显示名（菜单「手柄」一行，#520）
ns2_kind s2a_mac_ns2_kind(void);
const char *s2a_mac_ns2_kind_name(ns2_kind kind);
void s2a_mac_ns2_set_motion_enabled(int enabled);
// 震动（游戏的 s2a_pad_rumble_* 导出在 macos/front_mac.m，Switch 2 Pro 连着时交到这里；会话号与系统手柄那路不重叠）
uint64_t s2a_mac_ns2_rumble_session(void);
void s2a_mac_ns2_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]);
void s2a_mac_ns2_stop_rumble(uint64_t session);
int s2a_mac_ns2_read_motion(s2a_pad_motion *out);
int s2a_mac_ns2_read_motion_pair(s2a_pad_motion out[2]);   // Joy-Con 2 拼对：[左, 右] 返回 2；一路返回 1
int s2a_mac_ns2_read_mouse_pair(s2a_pad_mouse out[2]);   // 左右各一份（s2a_pad.h s2a_pad_read_mouse_pair）
#endif
