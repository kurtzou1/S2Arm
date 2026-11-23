// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 外接键盘键位的存取（#1987 第 2 条「设为所有游戏的默认」）：只依赖 Foundation，宿主单测 runtime/tests/t_keyboard_store.m 在 Mac 上跑。
//   两层：本款（S2AGame.<游戏号>，只这一款）和 App 级（= 所有游戏的默认，s2a_ios_settings_defaults 分层读取的回落层）。
//   读：本款有就用本款，否则用 App 级，都没有用 iPad 缺省（s2a_kbd_default）——新加的游戏没有本款记录，自然用所有游戏的默认。
//   单款壳 / 没选游戏（app 传 nil）：本款那一层就是 App 级本身，没有「所有游戏」可言，生效的缺省一律是 iPad 缺省。
//   值都是 schema 1 JSON（同 Mac 启动器 input.json）；「相同」按写出的 JSON 逐字比（同一个写出函数，结构体填充字节不参与）。
//   「使用鼠标 / 触控板」开关（#2072）单独一个键 S2AMouseOff（BOOL，没有 = 打开；不进 schema 1，Mac 用不上），和键位同一套两层规则：
//   存时和生效的缺省比、相同就删；恢复默认 / 设为默认 / 撤销两个键一起动；任一个键本款有记录就标「自定义」。
#pragma once
#import <Foundation/Foundation.h>
#include "s2a_input_config.h"

// 这一款现在用的是哪一套（改键页的「自定义 / 默认」标记；标准 = 初始状态，不显示）
typedef NS_ENUM(int, S2AKbdSource) {
    S2AKbdSourceStandard = 0,   // 本款没存、也没设所有游戏的默认（或单款壳没存）：iPad 缺省
    S2AKbdSourceDefault = 1,    // 本款没存，用的是玩家设的所有游戏的默认
    S2AKbdSourceCustom = 2,     // 本款单独存了一份
};

// 生效的缺省：「恢复默认」回到的、本款「和它一样就不单独存」比的那一套。App 级有合法键位就是它，否则 iPad 缺省；app 为 nil 一律 iPad 缺省
void s2a_kbd_store_effective_default(NSUserDefaults *app, s2a_input_config *out);
// 这一款生效的键位（同 keyboard.m 起局读取：本款的字符串，没有再取 App 级；读不懂用 iPad 缺省）
void s2a_kbd_store_load(NSUserDefaults *game, NSUserDefaults *app, s2a_input_config *out);
S2AKbdSource s2a_kbd_store_source(NSUserDefaults *game, NSUserDefaults *app);
// 这一款关没关鼠标 / 触控板：本款有记录用本款，否则用 App 级，都没有 = 打开（同 keyboard.m 起局的分层读取）
int s2a_kbd_store_mouse_off(NSUserDefaults *game, NSUserDefaults *app);
// 存这一款（键位 + 鼠标开关各比各的）：和生效的缺省相同就删掉本款记录（以后跟着默认走），否则写本款
void s2a_kbd_store_save(NSUserDefaults *game, NSUserDefaults *app, const s2a_input_config *map, int mouse_off);
// 恢复默认：删掉本款记录（键位与鼠标开关），回到所有游戏的默认（没设过就是 iPad 缺省、用鼠标）
void s2a_kbd_store_restore(NSUserDefaults *game);
// 设为所有游戏的默认（app 不能是 nil）：写 App 级，和 iPad 缺省（用鼠标）相同就删掉 App 级记录（= 没设过）；本款这时和默认相同，删掉本款记录。
//   返回撤销用的快照（覆盖前的 App 级与本款原值，没有记 NSNull）；交 s2a_kbd_store_undo 原样写回
NSDictionary *s2a_kbd_store_set_default(NSUserDefaults *game, NSUserDefaults *app, const s2a_input_config *map, int mouse_off);
void s2a_kbd_store_undo(NSUserDefaults *game, NSUserDefaults *app, NSDictionary *snapshot);
