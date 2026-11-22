// iOS 宿主界面语言的取法（11-13 维护者）：第一次打开跟随系统；玩家在 App 设置里选过就记住、以后都按他选的，不再跟系统；选「跟随系统」恢复跟随。
//   规则：简中 → zh-Hans，繁中（zh-Hant 或只带台 / 港 / 澳地区）→ zh-Hant，日 / 西 / 法 → ja / es / fr（11-14 加），其余语言 → en。与 Mac / Windows 启动器同一口径。
//   choice = App 设置里存的值（NULL / "" / "system" = 跟随系统；"zh-Hans" / "zh-Hant" / "en" / "ja" / "es" / "fr" = 玩家选的；别的值当跟随系统）；system = 系统首选语言第一项（BCP 47）。
//   纯函数，单测 runtime/tests/t_ui_lang.c；ios/s2a_l10n.h s2a_l10n_lang 与 ios/app.m 起进程时的语言覆盖都经它
#pragma once
#include <string.h>
#include <ctype.h>

static inline const char *s2a_ui_lang_of_tag(const char *tag) {
    char b[64]; size_t n = 0;
    if (!tag) return "en";
    for (; tag[n] && n < sizeof b - 2; n++) b[n] = (char)(tag[n] == '_' ? '-' : tolower((unsigned char)tag[n]));
    b[n] = '-'; b[n + 1] = 0;   // 末尾补 '-'，按「-子标签-」整段比
    if (strncmp(b, "zh-", 3)) {   // 非中文：有界面文案的日 / 西 / 法按主语言子标签认（ja-JP、es-419、fr-CA …），其余英文（11-14 加新语言）
        if (!strncmp(b, "ja-", 3)) return "ja";
        if (!strncmp(b, "es-", 3)) return "es";
        if (!strncmp(b, "fr-", 3)) return "fr";
        return "en";
    }
    if (strstr(b, "-hant-")) return "zh-Hant";
    if (strstr(b, "-hans-")) return "zh-Hans";
    return strstr(b, "-tw-") || strstr(b, "-hk-") || strstr(b, "-mo-") ? "zh-Hant" : "zh-Hans";
}
static inline const char *s2a_ui_lang_pick(const char *choice, const char *system) {
    static const char *const ours[] = {"zh-Hans", "zh-Hant", "en", "ja", "es", "fr"};   // 有界面文案的语言（ios/l10n/<语言>.lproj）
    for (size_t i = 0; choice && i < sizeof ours / sizeof *ours; i++) if (!strcmp(choice, ours[i])) return ours[i];
    return s2a_ui_lang_of_tag(system);
}
// 「跟随系统」时的系统语言取哪一份（#2069）：iOS「设置 → S2Arm → 语言」给单个 App 选的语言存在本 App 域的 AppleLanguages，
//   字符串表（NSBundle）按它出；这里原先一律读全局域（系统语言），两边不一致——界面中文、按 s2a_l10n_zh 选的报错 / 提示却是英文。
//   本 App 域有值且不是我们自己写的（ours = 0）→ 用它；是我们写的或没有 → 全局域。app_first / global_first = 两个域 AppleLanguages 的第一项（没有为 NULL）
static inline const char *s2a_ui_lang_system_tag(const char *app_first, int ours, const char *global_first) {
    return app_first && *app_first && !ours ? app_first : global_first;
}
// 界面语言选「跟随系统」时，本 App 的 AppleLanguages 清不清（#971）：它同时是 iOS「设置 → S2Arm → 首选语言」（单 App 语言）存值的地方，
//   原先一律清掉，玩家在系统设置里给 S2Arm 选的法语每次启动都被抹，游戏语言缺省（读本 App 首选语言列表）也就落不到法语。
//   只清我们自己写进去的：记过「是我们写的」（ours = 1）就清；没记过（旧版写的）只认「恰好一项、是我们三种界面语言之一」——那是旧版 App 设置写的，
//   玩家在系统设置里选的是别的语言（如 fr）就不动。apple = AppleLanguages 的各项，n 项
static inline int s2a_ui_lang_clear_override(const char *const *apple, int n, int ours) {
    if (n <= 0) return 0;
    if (ours) return 1;
    return n == 1 && apple[0] && (!strcmp(apple[0], "zh-Hans") || !strcmp(apple[0], "zh-Hant") || !strcmp(apple[0], "en"));
}
