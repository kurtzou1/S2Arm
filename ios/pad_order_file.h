// 分配玩家的顺序表（#520 E）：JSON → s2a_pad_order。Mac 宿主（macos/front_mac.m）与 iOS 宿主（ios/controller.m）共用这一份解析，
//   文件格式只有一种：{"generation": N, "order": [...], "dropped": [...]}，每项 type = ns2（player）/ keyboard / empty / gen1（id）/ gen1pair（left、right）/
//   其余 = 系统手柄（name + 同名第几只 index）。Mac 由启动器「分配玩家」写，iOS 由游戏内「分配玩家」面板写；单测 runtime/tests/t_pad_order_file.m
#pragma once
#import <Foundation/Foundation.h>
#include "../runtime/include/s2a_pad.h"

static inline void s2a_pad_order_fill(id list, s2a_pad_order_entry *out, int *count) {
    for (NSDictionary *e in [list isKindOfClass:NSArray.class] ? list : @[]) {
        if (*count >= S2A_PAD_ORDER_MAX || ![e isKindOfClass:NSDictionary.class]) break;
        s2a_pad_order_entry *x = &out[(*count)++];
        memset(x, 0, sizeof *x);
        BOOL ns2 = [e[@"type"] isEqual:@"ns2"], keyboard = [e[@"type"] isEqual:@"keyboard"], gen1 = [e[@"type"] isEqual:@"gen1"],
             gen1pair = [e[@"type"] isEqual:@"gen1pair"], empty = [e[@"type"] isEqual:@"empty"];
        x->ns2_player = empty ? S2A_PAD_ORDER_EMPTY : keyboard ? S2A_PAD_ORDER_KEYBOARD : gen1 ? S2A_PAD_ORDER_GEN1 : gen1pair ? S2A_PAD_ORDER_GEN1_PAIR
            : ns2 ? [e[@"player"] intValue] : -1;
        if (empty || keyboard) continue;
        if (gen1 || gen1pair) {   // 一代按设备：单只 id、一对「左 id|右 id」
            NSString *key = gen1 ? [e[@"id"] description] : [NSString stringWithFormat:@"%@|%@", e[@"left"], e[@"right"]];
            [key getCString:x->name maxLength:sizeof x->name encoding:NSUTF8StringEncoding];
            continue;
        }
        x->index = [e[@"index"] intValue];
        if (!ns2) [[e[@"name"] description] getCString:x->name maxLength:sizeof x->name encoding:NSUTF8StringEncoding];
    }
}

// 诊断用：表里每一位是什么（D-A2X6：玩家「手柄没反应」，日志只有「2 位」，看不出玩家 1 是键盘还是别的手柄）。
//   只写种类与系统手柄名，不写一代 Joy-Con 的设备号（蓝牙地址）。例：「P1 键盘、P2 Joy-Con (L/R)」
static inline void s2a_pad_order_describe(const s2a_pad_order *o, char *out, size_t n) {
    size_t k = 0; out[0] = 0;
    for (int i = 0; i < o->count && k + 1 < n; i++) {
        const s2a_pad_order_entry *e = &o->entry[i];
        char what[80];
        if (e->ns2_player == S2A_PAD_ORDER_KEYBOARD) snprintf(what, sizeof what, "键盘");
        else if (e->ns2_player == S2A_PAD_ORDER_EMPTY) snprintf(what, sizeof what, "空位");
        else if (e->ns2_player == S2A_PAD_ORDER_GEN1) snprintf(what, sizeof what, "一代 Joy-Con 单只");
        else if (e->ns2_player == S2A_PAD_ORDER_GEN1_PAIR) snprintf(what, sizeof what, "一代 Joy-Con 一对");
        else if (e->ns2_player >= 0) snprintf(what, sizeof what, "Switch 2 手柄（通道玩家 %d）", e->ns2_player);
        else snprintf(what, sizeof what, "%s", e->name);
        int w = snprintf(out + k, n - k, "%sP%d %s", i ? "、" : "", i + 1, what);
        if (w < 0) break;
        k += (size_t)w < n - k ? (size_t)w : n - k - 1;
    }
}

// json 不是字典（读不到 / 读不懂）→ 回 0，out 清空、generation = -1：调用方照连接顺序分槽（同没有表）
static inline int s2a_pad_order_from_json(id json, s2a_pad_order *out, long *generation) {
    memset(out, 0, sizeof *out);
    *generation = -1;
    if (![json isKindOfClass:NSDictionary.class]) return 0;
    s2a_pad_order_fill(json[@"order"], out->entry, &out->count);
    s2a_pad_order_fill(json[@"dropped"], out->dropped, &out->dropped_count);
    // 一位玩家都没登记（分配时谁都没按就完成了）：「没分配的不给玩家位」会让在线的手柄全都没有玩家位，游戏里按什么都没反应（D-A2X6）。
    //   没人能玩不是谁要的结果：这种表的「没分配」名单不作数，照连接顺序排（第一只进玩家 1）；generation 照读，重排时机不变
    if (!out->count) out->dropped_count = 0;
    id g = json[@"generation"];
    *generation = [g respondsToSelector:@selector(longValue)] ? [g longValue] : 0;   // 字典里没有 generation 记 0（同抽出前 Mac 的 [nil longValue]）
    return 1;
}
