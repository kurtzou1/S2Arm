// 宿主界面文字的本地化（#316）：字符串表在 App 主 bundle 的 <语言>.lproj/S2ArmHost.strings（源 ios/l10n/，runtime/build.mk 的 ios 目标拷进包）。
//   不用游戏库的 Localizable.xcstrings：单款包不带游戏库资源包。键是稳定的点分 id（按文件 / 功能分前缀），同一句话复用同一个键；
//   含格式的串写 [NSString stringWithFormat:S2AL(@"…"), …]。两表键集合、占位符一致与代码引用由 tests/ios_l10n_test.sh 核对
#pragma once
#import <Foundation/Foundation.h>

#define S2AL(key) [NSBundle.mainBundle localizedStringForKey:(key) value:nil table:@"S2ArmHost"]

// 按 App 语言选中英（#316）：与游戏进程 / Mac 端共用的 C 宏文案（runtime/include/s2a_direct_prompt.h、s2a_init_fail.h、s2a_selfcheck_page.h、s2a_dguard.h）
//   只有中文原宏 + 英文 <宏>_EN 两份（规格里的由 launchers/shared/check_experience.py 核逐字一致），宿主显示处用 S2APICK(宏) 取一种。
//   判据：最终生效的界面语言（下面 s2a_l10n_lang）以 zh 开头 = 中文，其余一律英文（开发区域 en）
// 宿主界面最终生效的语言：zh-Hans / zh-Hant / en（11-13 维护者：首次跟随系统；玩家在 App 设置里选过就记住、以后按选的；选「跟随系统」恢复跟随；
//   简 → 简、繁 → 繁、其余 → 英，取法在 runtime/include/s2a_ui_lang.h，单测 t_ui_lang）。选的值存在 S2AUILanguageKey（标准偏好）；
//   ios/app.m 起进程时据此设本 App 的 AppleLanguages，字符串表 / 游戏库 / 系统弹框都按同一种语言出。进程内只取一次（换语言重开 App 生效）
#include "../runtime/include/s2a_ui_lang.h"   // 按本文件位置找：引用 s2a_l10n.h 的原生单测（vpad_* / cpatch_settings 等）不带 runtime/include
#define S2AUILanguageKey @"S2AUILanguage"
static inline NSString *s2a_l10n_system_tag(void) {   // 系统首选语言第一项：玩家选过语言时 AppleLanguages 是本 App 的覆盖值，要读全局域那份
    NSArray *g = [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain][@"AppleLanguages"];
    return [g isKindOfClass:NSArray.class] && g.count ? g.firstObject : NSLocale.preferredLanguages.firstObject;
}
static inline NSString *s2a_l10n_lang(void) {
    static NSString *l; static dispatch_once_t once;
    dispatch_once(&once, ^{ l = @(s2a_ui_lang_pick([NSUserDefaults.standardUserDefaults stringForKey:S2AUILanguageKey].UTF8String, s2a_l10n_system_tag().UTF8String)); });
    return l;
}
// 起进程时调一次（ios/app.m 构造期、输入工作台 main 开头），在任何本地化查表之前：玩家选过语言就把本 App 的 AppleLanguages 设成它
//   （字符串表 / 游戏库 / 系统弹框随之），并记下「是我们写的」；跟随系统时只清我们写的那份（s2a_ui_lang_clear_override，#971）——
//   玩家在 iOS「设置 → S2Arm → 首选语言」里选的（存的是同一个键）照留，游戏语言缺省读本 App 首选语言列表也就跟它。返回最终生效的界面语言
#define S2AUILanguageOursKey @"S2AUILanguageWroteAppleLanguages"
static inline NSString *s2a_l10n_apply_choice(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults; NSString *c = [d stringForKey:S2AUILanguageKey];
    if ([@[@"zh-Hans", @"zh-Hant", @"en"] containsObject:c]) { [d setObject:@[c] forKey:@"AppleLanguages"]; [d setBool:YES forKey:S2AUILanguageOursKey]; }
    else {
        NSArray *a = [d persistentDomainForName:NSBundle.mainBundle.bundleIdentifier ?: @""][@"AppleLanguages"];   // 只看本 App 域（不含全局列表）
        const char *v[4] = {0}; int n = 0;
        for (id x in [a isKindOfClass:NSArray.class] ? a : @[]) { if (n < 4 && [x isKindOfClass:NSString.class]) v[n] = [x UTF8String]; n++; }
        if (s2a_ui_lang_clear_override(v, n > 4 ? 4 : n, [d boolForKey:S2AUILanguageOursKey])) [d removeObjectForKey:@"AppleLanguages"];
        [d removeObjectForKey:S2AUILanguageOursKey];
    }
    return s2a_l10n_lang();
}
static inline BOOL s2a_l10n_zh(void) { return [s2a_l10n_lang() hasPrefix:@"zh"]; }   // 简 / 繁界面都算中文（宏文案只有中、英两份）
#define S2APICK(macro) (s2a_l10n_zh() ? @macro : @macro##_EN)     // NSString *
#define S2APICKC(macro) (s2a_l10n_zh() ? macro : macro##_EN)      // const char *
