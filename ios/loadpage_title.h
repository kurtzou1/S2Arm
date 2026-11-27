// 加载页上的游戏名（#502 Gustour：原先固定按 简中 → 繁中 → 日 → 英 取 control.nacp，法语 / 英语玩家看到的是中文，和游戏库封面上的名字对不上）。
//   ① 游戏库起局时壳把封面上正显示的名字交过来（S2A_GAME_NAME：玩家在这台手机上改过的名 → 清单里的名，shell S2ArmShellHostModel.requestPlay 设）：有就用它，同封面一字不差；
//   ② 没有（单款独立 App 没有游戏库、老壳）：按系统首选语言取 control.nacp 里那种语言的标题，再退美式英语、英式英语，再按槽位顺序取第一个非空。
//   纯 Foundation、无 UIKit：ios/loadpage.m 与单测 runtime/tests/t_loadpage_title.m 共用
#pragma once
#import <Foundation/Foundation.h>
#include <string.h>

// 苹果语言代码 → control.nacp 标题槽（Switch 固件语言顺序，同 pack/display_name.py LPROJ）；认不出回 -1
static inline int s2a_nacp_slot_for_language(NSString *lang) {
    NSString *l = lang.lowercaseString;
    if ([l hasPrefix:@"zh-hans"] || [l isEqualToString:@"zh-cn"] || [l isEqualToString:@"zh-sg"]) return 14;
    if ([l hasPrefix:@"zh-hant"] || [l isEqualToString:@"zh-tw"] || [l isEqualToString:@"zh-hk"] || [l isEqualToString:@"zh-mo"]) return 13;
    if ([l hasPrefix:@"en-gb"] || [l hasPrefix:@"en-au"] || [l hasPrefix:@"en-nz"] || [l hasPrefix:@"en-ie"]) return 1;
    if ([l hasPrefix:@"en"]) return 0;
    if ([l hasPrefix:@"ja"]) return 2;
    if ([l hasPrefix:@"fr-ca"]) return 9;
    if ([l hasPrefix:@"fr"]) return 3;
    if ([l hasPrefix:@"de"]) return 4;
    if ([l hasPrefix:@"es-419"] || [l hasPrefix:@"es-mx"] || [l hasPrefix:@"es-us"]) return 5;
    if ([l hasPrefix:@"es"]) return 6;
    if ([l hasPrefix:@"it"]) return 7;
    if ([l hasPrefix:@"nl"]) return 8;
    if ([l hasPrefix:@"pt-br"]) return 15;
    if ([l hasPrefix:@"pt"]) return 10;
    if ([l hasPrefix:@"ru"]) return 11;
    if ([l hasPrefix:@"ko"]) return 12;
    return -1;
}

static inline NSString *s2a_nacp_slot_title(NSData *nacp, int slot) {
    if (slot < 0 || slot > 15 || nacp.length < (NSUInteger)(slot + 1) * 0x300) return nil;
    const char *s = (const char *)nacp.bytes + slot * 0x300; size_t n = strnlen(s, 0x200);
    if (!n) return nil;
    NSString *t = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding];
    return t.length ? t : nil;
}

// shown = 壳交来的封面名（可空）；nacp = control.nacp 内容（可空）；languages = 系统首选语言（NSLocale.preferredLanguages）。都取不到回 nil（调用方再退 App 显示名）
static inline NSString *s2a_loadpage_title(NSString *shown, NSData *nacp, NSArray<NSString *> *languages) {
    NSString *s = [shown stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length) return s;
    if (nacp.length < 0x3000) return nil;
    for (NSString *lang in languages) { NSString *t = s2a_nacp_slot_title(nacp, s2a_nacp_slot_for_language(lang)); if (t) return t; }
    for (int slot = 0; slot < 16; slot++) { NSString *t = s2a_nacp_slot_title(nacp, slot); if (t) return t; }   // 美式英语、英式英语打头，再按槽位
    return nil;
}
