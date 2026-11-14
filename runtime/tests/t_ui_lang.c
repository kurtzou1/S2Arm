// iOS 宿主界面语言取法（runtime/include/s2a_ui_lang.h）：期望按规则手写——简 → zh-Hans、繁 → zh-Hant、其余 → en；玩家选过就按选的，选「跟随系统」恢复跟随
#include <stdio.h>
#include <string.h>
#include "s2a_ui_lang.h"
#include "s2a_t_result.h"
static int bad, n;
static void ck(const char *what, const char *want, const char *got) { n++; int ok = !strcmp(want, got); if (!ok) bad++; printf("%s %s：期望 %s → 实际 %s\n", ok ? "通" : "不通", what, want, got); }
int main(void) {
    // ① 第一次打开（没存过选择）跟随系统
    ck("首次 · 系统简中 zh-Hans-CN", "zh-Hans", s2a_ui_lang_pick(NULL, "zh-Hans-CN"));
    ck("首次 · 系统繁中 zh-Hant-TW", "zh-Hant", s2a_ui_lang_pick(NULL, "zh-Hant-TW"));
    ck("首次 · 系统 zh-HK（只有地区）", "zh-Hant", s2a_ui_lang_pick(NULL, "zh-HK"));
    ck("首次 · 系统 zh-Hans-HK（文字子标签优先）", "zh-Hans", s2a_ui_lang_pick(NULL, "zh-Hans-HK"));
    ck("首次 · 系统 zh", "zh-Hans", s2a_ui_lang_pick(NULL, "zh"));
    ck("首次 · 系统日语 → 英文", "en", s2a_ui_lang_pick(NULL, "ja-JP"));
    ck("首次 · 系统西语 → 英文", "en", s2a_ui_lang_pick(NULL, "es-419"));
    ck("首次 · 系统 en_GB（下划线）", "en", s2a_ui_lang_pick(NULL, "en_GB"));
    ck("首次 · 取不到系统语言", "en", s2a_ui_lang_pick(NULL, NULL));
    ck("首次 · 「zhx」不是中文", "en", s2a_ui_lang_pick(NULL, "zhx-CN"));
    // ② 玩家切换过：存的选择压过系统（重启后读到同一个存值，结果同）
    ck("选过繁中 · 系统简中", "zh-Hant", s2a_ui_lang_pick("zh-Hant", "zh-Hans-CN"));
    ck("选过英文 · 系统简中", "en", s2a_ui_lang_pick("en", "zh-Hans-CN"));
    ck("选过简中 · 系统日语", "zh-Hans", s2a_ui_lang_pick("zh-Hans", "ja-JP"));
    // ③ 选「跟随系统」恢复跟随；认不出的存值也当跟随系统
    ck("选跟随系统 · 系统繁中", "zh-Hant", s2a_ui_lang_pick("system", "zh-Hant-TW"));
    ck("选跟随系统 · 系统德语", "en", s2a_ui_lang_pick("system", "de-DE"));
    ck("存值空串 · 系统简中", "zh-Hans", s2a_ui_lang_pick("", "zh-Hans-CN"));
    ck("存值认不出 ja · 系统简中", "zh-Hans", s2a_ui_lang_pick("ja", "zh-Hans-CN"));
    // ④ 选「跟随系统」时清不清本 App 的 AppleLanguages（#971：它也是 iOS「设置 → S2Arm → 首选语言」的存值，玩家选的不能抹）
    { const char *fr[] = {"fr"}, *en[] = {"en"}, *two[] = {"zh-Hans", "en"}, *hant[] = {"zh-Hant"};
      ck("没有覆盖 → 不清", "0", s2a_ui_lang_clear_override(NULL, 0, 0) ? "1" : "0");
      ck("我们记过是自己写的 → 清", "1", s2a_ui_lang_clear_override(fr, 1, 1) ? "1" : "0");
      ck("系统设置里给 S2Arm 选了法语（没记过）→ 不清", "0", s2a_ui_lang_clear_override(fr, 1, 0) ? "1" : "0");
      ck("旧版 App 设置写的 en（恰好一项、我们的三种之一）→ 清", "1", s2a_ui_lang_clear_override(en, 1, 0) ? "1" : "0");
      ck("旧版写的 zh-Hant → 清", "1", s2a_ui_lang_clear_override(hant, 1, 0) ? "1" : "0");
      ck("两项（系统那边的列表）没记过 → 不清", "0", s2a_ui_lang_clear_override(two, 2, 0) ? "1" : "0"); }
    printf("共 %d 项\n", n);
    return S2A_T_RESULT("t_ui_lang", bad);
}
