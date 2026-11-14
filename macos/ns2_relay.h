// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_MAC_NS2_RELAY_H
#define S2A_MAC_NS2_RELAY_H

#include "../runtime/ns2pro/include/NS2Transport.h"
#include <stdint.h>

#define NS2_RELAY_MAGIC 0x534E3252u
// 2：加 kind（对外输出型号，ns2_get_output_kind；#520）。两端版本不同时各自记一行日志并断开，不猜字段
//   同在 v2（#520 A，v2 发版前一起进，不另升）：单只 Joy-Con 的 state / motion 报原始方向、SL / SR 在扩展位 21 / 22
//   （ns2_set_joycon_raw；游戏宿主按游戏样式转）。v2 已随 v0.3.0–v0.3.5 发版，单只 Joy-Con 语义改动按上条规则升 3（#619 合入时）
#define NS2_RELAY_VERSION 3u
// 一条通道最多几位玩家（头部 player 0..NS2_RELAY_PLAYERS-1）：每个连接程序一组、每组两个号（2g、2g+1），最多 8 组（同原机最多 8 只手柄）；
//   宿主最多 8 个槽位（front_mac.m S2A_MAX_PADS），号多于槽位时按分配 / 连接顺序取前 8 位
#define NS2_RELAY_PLAYERS 16

typedef enum {
    NS2_RELAY_INPUT = 1,
    NS2_RELAY_RUMBLE = 2,
    NS2_RELAY_MOTION = 3,
    NS2_RELAY_STOP_RUMBLE = 4,
    NS2_RELAY_DISCONNECT = 5,
} ns2_relay_type;

// 左只六轴（拼对时）：单位同 ns2_motion（g、度/秒，设备轴序），时间戳拆成两个 32 位（全 4 字节对齐：放进联合体不改包内偏移）
typedef struct {
    float acceleration_x, acceleration_y, acceleration_z;
    float gyro_x, gyro_y, gyro_z;
    uint32_t host_timestamp_us_lo, host_timestamp_us_hi;
} ns2_relay_motion_left;

// Joy-Con 2 光学鼠标（ns2_mouse）：report05 0x10 起的 8 字节原样——x / y 绝对坐标（16 位、会回绕）、surface、distance（0 = 贴着桌面）
typedef struct {
    int16_t x, y;
    uint16_t surface, distance;
} ns2_relay_mouse;
_Static_assert(sizeof(ns2_relay_mouse) == 8, "mouse fills the 8 spare bytes after motion_left");

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint64_t epoch;
    ns2_state state;
    ns2_motion motion;
    uint8_t ready;
    uint8_t status;
    uint8_t motion_known;
    uint8_t enabled;
    uint8_t kind;   // ns2_kind；只在 INPUT 包里有意义
    uint8_t motion_left_known;   // INPUT 包：motion_left 有值（Joy-Con 2 左右拼成一对时左只的六轴；motion 是右只的）。旧启动器发 0，宿主照旧只用 motion
    uint8_t mouse_kind;   // INPUT 包：mouse 有值时是读数来自哪一只（ns2_kind 左 / 右）；0 = 没有鼠标读数（旧启动器 / Pro）
    // 这个包属于哪位玩家（0 起）。原是保留字节：旧启动器发 0 = 玩家 1，语义不变、不升版本；
    //   INPUT 包按玩家各存一份（多手柄各占一个槽位）；超出 NS2_RELAY_PLAYERS 的包丢掉、不断线。
    //   体感 / 鼠标 / 震动 / 连接状态只跟玩家 0 走（其余玩家的只用按键与摇杆）
    uint8_t player;
    union {
        struct {   // RUMBLE 包（宿主 → 启动器）
            ns2_vibration vibration[2];
            uint32_t duration_ms;
            uint32_t reserved2;
        };
        struct {   // INPUT 包（启动器 → 宿主）：同一段 40 字节带 Joy-Con 2 自身功能的附加读数，不改包长、不升版本（旧宿主不读这段）
            ns2_relay_motion_left motion_left;   // 32 字节
            ns2_relay_mouse mouse;               // 8 字节：Joy-Con 2 光学鼠标（mouse_kind 非 0 时有值）
        };
    };
} ns2_relay_packet;
_Static_assert(sizeof(ns2_relay_packet) == 144, "relay packet size is the v2 wire format: an old launcher / host reads exactly this many bytes");


#endif
