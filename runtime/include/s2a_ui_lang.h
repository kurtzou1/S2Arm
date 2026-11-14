// iOS 宿主界面语言的取法（11-13 维护者）：第一次打开跟随系统；玩家在 App 设置里选过就记住、以后都按他选的，不再跟系统；选「跟随系统」恢复跟随。
//   规则：简中 → zh-Hans，繁中（zh-Hant 或只带台 / 港 / 澳地区）→ zh-Hant，其余语言 → en。与 Mac 启动器 AppLanguage.resolved 同一口径（启动器没有繁中界面）。
//   choice = App 设置里存的值（NULL / "" / "system" = 跟随系统；"zh-Hans" / "zh-Hant" / "en" = 玩家选的；别的值当跟随系统）；system = 系统首选语言第一项（BCP 47）。
//   纯函数，单测 runtime/tests/t_ui_lang.c；ios/s2a_l10n.h s2a_l10n_lang 与 ios/app.m 起进程时的语言覆盖都经它
#pragma once
#include <string.h>
#include <ctype.h>

static inline const char *s2a_ui_lang_of_tag(const char *tag) {
    char b[64]; size_t n = 0;
    if (!tag) return "en";
    for (; tag[n] && n < sizeof b - 2; n++) b[n] = (char)(tag[n] == '_' ? '-' : tolower((unsigned char)tag[n]));
    b[n] = '-'; b[n + 1] = 0;   // 末尾补 '-'，按「-子标签-」整段比
    if (strncmp(b, "zh-", 3)) return "en";
    if (strstr(b, "-hant-")) return "zh-Hant";
    if (strstr(b, "-hans-")) return "zh-Hans";
    return strstr(b, "-tw-") || strstr(b, "-hk-") || strstr(b, "-mo-") ? "zh-Hant" : "zh-Hans";
}
static inline const char *s2a_ui_lang_pick(const char *choice, const char *system) {
    if (choice && (!strcmp(choice, "zh-Hans") || !strcmp(choice, "zh-Hant") || !strcmp(choice, "en"))) return choice;
    return s2a_ui_lang_of_tag(system);
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
