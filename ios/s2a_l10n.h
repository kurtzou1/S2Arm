// 宿主界面文字的本地化（#316）：字符串表在 App 主 bundle 的 <语言>.lproj/S2ArmHost.strings（源 ios/l10n/，runtime/build.mk 的 ios 目标拷进包）。
//   不用游戏库的 Localizable.xcstrings：单款包不带游戏库资源包。键是稳定的点分 id（按文件 / 功能分前缀），同一句话复用同一个键；
//   含格式的串写 [NSString stringWithFormat:S2AL(@"…"), …]。两表键集合、占位符一致与代码引用由 tests/ios_l10n_test.sh 核对
#pragma once
#import <Foundation/Foundation.h>

#define S2AL(key) [NSBundle.mainBundle localizedStringForKey:(key) value:nil table:@"S2ArmHost"]

// 按 App 语言选中英（#316）：与游戏进程 / Mac 端共用的 C 宏文案（runtime/include/s2a_direct_prompt.h、s2a_init_fail.h、s2a_selfcheck_page.h、s2a_dguard.h）
//   只有中文原宏 + 英文 <宏>_EN 两份（规格里的由 launchers/shared/check_experience.py 核逐字一致），宿主显示处用 S2APICK(宏) 取一种。
//   判据同字符串表的取法：主 bundle 的首选本地化以 zh 开头 = 中文，其余一律英文（开发区域 en）
static inline BOOL s2a_l10n_zh(void) {
    static BOOL zh; static dispatch_once_t once;
    dispatch_once(&once, ^{ zh = [NSBundle.mainBundle.preferredLocalizations.firstObject hasPrefix:@"zh"]; });
    return zh;
}
// 宿主界面实际显示的语言（字符串表 ios/l10n/<语言>.lproj 里有的那几种，按系统首选语言挑）：zh-Hans / zh-Hant / en。
//   不用 preferredLocalizations：Info.plist 的 CFBundleLocalizations 列了 19 种（给游戏名本地化用），日语系统会回 ja，界面却显示英文表
static inline NSString *s2a_l10n_lang(void) {
    static NSString *l; static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSBundle preferredLocalizationsFromArray:@[@"en", @"zh-Hans", @"zh-Hant"] forPreferences:NSLocale.preferredLanguages].firstObject ?: @"en"; });
    return l;
}
#define S2APICK(macro) (s2a_l10n_zh() ? @macro : @macro##_EN)     // NSString *
#define S2APICKC(macro) (s2a_l10n_zh() ? macro : macro##_EN)      // const char *
