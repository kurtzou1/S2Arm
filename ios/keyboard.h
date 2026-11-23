// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 外接键盘（妙控键盘等，#1869）：ios/keyboard.m 采键（GCKeyboard），ios/controller.m 照 Mac 选源发布，
//   ios/keyboard_settings.m 是改键页（同 Mac 启动器：点按键位后按新键录入，Esc 取消，另有常用键）。映射规则在 ios/keyboard_map.h。
//   触控板 / 鼠标（#1869 PR 2）：ios/mouse.m 采 GCMouse，鼠标键并进键盘这一份发布；规则在 ios/mouse_map.h。
#pragma once
#include <stdint.h>
#include <dispatch/dispatch.h>
#include "s2a_input_config.h"

// controller.m 提供
dispatch_queue_t s2a_ios_input_queue(void);   // 手柄回调的串行输入队列；键盘 / 鼠标回调也挂它，键态只在它上面动
// 键盘这一份按键 / 摇杆变了（只在输入队列上调）。pressed：这次有新按下的键（吸附键盘、抬键不触发接管）
void s2a_ios_keyboard_publish(uint32_t buttons, const int32_t sticks[4], int pressed);
void s2a_ios_keyboard_end(void);              // 键盘断开：结束接管、虚拟按键显示回来（只在输入队列上调）
int s2a_ios_inputs_hidden(void);              // 按键模式下虚拟按键因键盘接管 / 实体手柄收起着（任意线程）

// keyboard.m 提供
void s2a_ios_keyboard_attach(void);           // 主线程，controller.m 建好输入队列后调一次
void s2a_ios_keyboard_background(void);       // 切后台：按着的键放开，接管保留（任意线程）
void s2a_ios_keyboard_foreground(void);       // 回前台：键盘已不在就结束接管（主线程）
int s2a_ios_keyboard_connected(void);         // 现在接着外接键盘（任意线程）
// 改键页用（主线程）
#define S2AKeyboardMapKey @"S2AKeyboardMap"   // 按款存（s2a_ios_per_game_keys）：schema 1 JSON，同 Mac 启动器 input.json 格式
#define S2AMouseOffKey @"S2AMouseOff"         // 按款存：改键页「使用鼠标 / 触控板」关掉（#2072，BOOL，没有 = 打开；不进 schema 1）
void s2a_ios_keyboard_reload(void);           // 存了新键位：当场生效
void s2a_ios_keyboard_set_muted(int muted);   // 改键页开着：键盘不进游戏
// 录一个键：下一次按下的键交回（Mac 键码 + 修饰键位 Shift 1 / Control 2 / Option 4），Esc 交回 code = -1；
//   单按修饰键录成那个键（同 Mac 启动器录键规则），⌘ 组合不收。回调在主线程。传 NULL 取消录键
void s2a_ios_keyboard_record(void (^done)(int code, unsigned modifiers));
void s2a_ios_keyboard_mouse_changed(int pressed);   // mouse.m：算数的鼠标键变了，重算一份发布（只在输入队列上调）

// mouse.m 提供
int s2a_ios_mouse_connected(void);            // 接着鼠标 / 触控板（任意线程）
int s2a_ios_mouse_lock_wanted(void);          // 游戏页 prefersPointerLocked 问这里（主线程）
unsigned s2a_ios_mouse_buttons(void);         // 按着、算数的鼠标键（位 i = 按键 i；输入队列）
void s2a_ios_mouse_config(const s2a_input_config *c, int is_default, int off);   // keyboard.m 装好键位时同步鼠标那几项与开关（输入队列）
void s2a_ios_mouse_take(int32_t sticks[4]);   // HID 读线程：攒下的位移加进右摇杆（vpad.m 两个读导出）
int s2a_ios_mouse_escape(void);               // Esc 按下：锁着就只释放、回 1（这一下不进游戏）；输入队列
void s2a_ios_mouse_sync(void);                // 虚拟按键显示 / 收起、方案切换后：不该锁着就释放（主线程）
void s2a_ios_mouse_background(void);          // 切后台 / 开改键页：释放锁定、放开鼠标键（主线程）
int s2a_ios_mouse_pointer(long button_mask);  // 一下触控板 / 鼠标点击：0 当手指、1 忽略、2 当触屏点（主线程）

// keyboard_settings.m 提供（主线程）
int s2a_ios_keyboard_customized(void);        // 这款在改键页存过键位
#ifdef __OBJC__
@class UIViewController, UIView, UITouch;
// 改键页（带导航栏，模态呈现）；关掉后调 closed
UIViewController *s2a_ios_keyboard_settings(void (^closed)(void));
// 这一款的键位（keyboard.m 持有，改键页改完当场换）；实体系统手柄改键也读它（输入队列上调）
const s2a_input_config *s2a_ios_pad_map_config(void);
void s2a_ios_mouse_attach(UIView *root);      // mouse.m：主线程，controller.m 建好输入队列后调一次；root = 游戏页根视图（请求锁定用）
void s2a_vpad_pointer_touch(UITouch *touch, int phase);   // vpad.m：触控板左键当触屏点（phase 0 按下、1 移动、2 抬起；主线程）
#endif
