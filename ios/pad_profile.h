// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 只有通用物理描述（physicalInputProfile）、没有扩展手柄描述的系统手柄（#2244）：
//   系统把单只一代 Joy-Con 报成 productCategory「Nintendo Switch Joy-Con (L)」/「(R)」、只有 micro 档（D-9A2V 0007）；
//   iOS 里配成一对的报「Joy-Con (L/R)」、带扩展档，照旧走 sample_extended。原先 ios/controller.m 只收扩展档，单只整只进不了槽位。
// 这里按标准键名读，位序与 sample_extended 同一套（东 南 北 西、左右摇杆按下、L R ZL ZR、+ −、← ↑ → ↓，Home 放扩展位 16）。
//   单只横握视角由系统给：照通用手柄读（同 Mac front_mac.m sample_profile_state，单只一代 Joy-Con 在 Mac 上走原始 HID 才另做横握换算）。
//   单只只有一根摇杆：描述里没有左右摇杆、只有方向键（micro 档的 dpad 就是那根摇杆）时把它当左摇杆；只有右摇杆时也放到左摇杆（横握当一只小手柄，摇杆管移动）
// ios/controller.m 与单测 runtime/tests/t_pad_profile.m 共用；只依赖 Foundation / GameController 与 runtime/src/pad.c 的纯函数
#ifndef S2A_IOS_PAD_PROFILE_H
#define S2A_IOS_PAD_PROFILE_H
#import <GameController/GameController.h>
#include "s2a_pad.h"

// 单只一代 Joy-Con：左只 8、右只 16（Ryujinx ControllerType JoyconLeft / JoyconRight 的位），别的 0。带扩展档的（一对、Pro）不算
static inline int s2a_pad_single_joycon(NSString *category, BOOL extended) {
    if (extended || !category) return 0;
    if ([category hasPrefix:@"Nintendo Switch Joy-Con (L)"]) return 1 << 3;
    if ([category hasPrefix:@"Nintendo Switch Joy-Con (R)"]) return 1 << 4;
    return 0;
}

static inline void s2a_pad_profile_sample(GCPhysicalInputProfile *p, NSString *category, uint32_t *out_buttons, int32_t axes[4]) {
    GCControllerButtonInput *face[4] = {p.buttons[GCInputButtonA], p.buttons[GCInputButtonB], p.buttons[GCInputButtonX], p.buttons[GCInputButtonY]};
    int order[4]; s2a_pad_abxy_order(s2a_pad_kind(category.UTF8String, 0, 0), s2a_pad_layout(), order);
    GCControllerDirectionPad *ls = p.dpads[GCInputLeftThumbstick], *rs = p.dpads[GCInputRightThumbstick], *dpad = p.dpads[GCInputDirectionPad];
    if (!ls && !rs) { ls = dpad; dpad = nil; }   // micro 档：方向键就是那根摇杆
    else if (!ls) { ls = rs; rs = nil; }
    GCControllerButtonInput *keys[16] = {face[order[0]], face[order[1]], face[order[2]], face[order[3]],
        p.buttons[GCInputLeftThumbstickButton], p.buttons[GCInputRightThumbstickButton], p.buttons[GCInputLeftShoulder], p.buttons[GCInputRightShoulder],
        p.buttons[GCInputLeftTrigger], p.buttons[GCInputRightTrigger], p.buttons[GCInputButtonMenu], p.buttons[GCInputButtonOptions],
        dpad.left, dpad.up, dpad.right, dpad.down};
    uint32_t buttons = 0;
    for (int i = 0; i < 16; i++) if (keys[i].isPressed) buttons |= 1u << i;
    if (p.buttons[GCInputButtonHome].isPressed) buttons |= 1u << 16;
    for (int i = 0; i < 4; i++) axes[i] = 0;
    if (ls) s2a_pad_stick(ls.xAxis.value, ls.yAxis.value, axes);
    if (rs) s2a_pad_stick(rs.xAxis.value, rs.yAxis.value, axes + 2);
    *out_buttons = buttons;
}

// 首连诊断：描述里全部键名 / 方向键名 / 轴名（单只没有实物核过，靠这一行核真实键名）
static inline NSString *s2a_pad_profile_names(GCPhysicalInputProfile *p) {
    NSArray *b = [p.buttons.allKeys sortedArrayUsingSelector:@selector(compare:)], *d = [p.dpads.allKeys sortedArrayUsingSelector:@selector(compare:)],
            *a = [p.axes.allKeys sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"键 [%@]；方向 [%@]；轴 [%@]", [b componentsJoinedByString:@", "], [d componentsJoinedByString:@", "], [a componentsJoinedByString:@", "]];
}
#endif
