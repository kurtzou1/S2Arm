// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 外接键盘键位两层存取（ios/keyboard_store.m，#1987 第 2 条「设为所有游戏的默认」）。期望值都是手推的：
//   iPad 缺省 = s2a_kbd_default（Y = F、ZL = Z、右摇杆 IJKL）；M、N 是两套手写的自定义键位。
//   ①–⑧ 只用临时 suite 当「本款」「App 级」两层；⑨ 接 ios/settings.m 的真分层（新游戏读到所有游戏的默认、两层取对）
//   ⑩「使用鼠标 / 触控板」开关（#2072）：单独一个键 S2AMouseOff（不进 schema 1 JSON），和键位同一套两层规则（存、恢复默认、设为默认、撤销、标记）
#import <Foundation/Foundation.h>
#import "../../ios/keyboard_store.h"
#import "../../ios/settings.h"
#include "../../ios/keyboard_map.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, checks;
static void check(BOOL ok, const char *what) { checks++; if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); } }
static NSString *const K = @"S2AKeyboardMap", *const OFF = @"S2AMouseOff";
static NSString *json(const s2a_input_config *c) {
    char b[4096]; int n = s2a_kbd_config_json(c, b, sizeof b);
    return n > 0 ? [[NSString alloc] initWithBytes:b length:(NSUInteger)n encoding:NSUTF8StringEncoding] : @"";
}
static BOOL same(const s2a_input_config *a, const s2a_input_config *b) { return [json(a) isEqualToString:json(b)]; }
static NSUserDefaults *suite(NSMutableArray *names) {
    NSString *n = [@"local.s2arm.kbd-store." stringByAppendingString:NSUUID.UUID.UUIDString];
    [names addObject:n]; return [[NSUserDefaults alloc] initWithSuiteName:n];
}

int main(void) {
    @autoreleasepool {
        NSMutableArray *names = [NSMutableArray array];
        s2a_input_config ipad, M, N, std, got;
        s2a_kbd_default(&ipad);
        M = ipad; M.keyboard[0].code = 31; M.mouse[3] = -1;          // A = O，Y 不绑左键（O、P 在 iPad 缺省里都没用到，不会撞成重复绑定）
        N = ipad; N.keyboard[1].code = 35; N.keyboard[1].modifiers = 1;   // B = ⇧P
        std = ipad;
        {   // 测试数据本身要合法（重复绑定会被解析器拒收、读回 iPad 缺省，后面的断言就测不到东西）
            NSString *jm = json(&M), *jn = json(&N); s2a_input_config pm, pn;
            check(s2a_input_config_parse(jm.UTF8String, strlen(jm.UTF8String), &pm) == S2A_INPUT_CONFIG_OK && same(&pm, &M)
                  && s2a_input_config_parse(jn.UTF8String, strlen(jn.UTF8String), &pn) == S2A_INPUT_CONFIG_OK && same(&pn, &N), "测试用的 M、N 能原样读回");
        }

        // ① 初始：什么都没存 → 标准键位，不显示标记
        NSUserDefaults *app = suite(names), *g1 = suite(names), *g2 = suite(names);
        check(s2a_kbd_store_source(g1, app) == S2AKbdSourceStandard, "① 初始：这款用标准键位（不显示标记）");
        s2a_kbd_store_load(g1, app, &got); check(same(&got, &ipad), "① 初始：读到 iPad 缺省");

        // ② 在 g1 上把 M 设为所有游戏的默认（原来没设过）
        NSDictionary *snap = s2a_kbd_store_set_default(g1, app, &M, 0);
        check([[app stringForKey:K] isEqualToString:json(&M)], "② 设为默认：App 级写的是 M");
        check([g1 objectForKey:K] == nil, "② 设为默认：这款不单独存（以后跟着默认走）");
        check(s2a_kbd_store_source(g1, app) == S2AKbdSourceDefault, "② 设为默认后这款标「默认」");

        // ③ 守卫：新游戏（没有本款记录）直接用所有游戏的默认
        s2a_kbd_store_load(g2, app, &got); check(same(&got, &M), "③ 新游戏读到所有游戏的默认 M");
        check(s2a_kbd_store_source(g2, app) == S2AKbdSourceDefault, "③ 新游戏标「默认」");

        // ④ 有非标准默认时，这款改回标准键位：要单独存下来，读回仍是标准键位（原先和 iPad 缺省比，会删掉记录、读到 M）
        s2a_kbd_store_save(g2, app, &std, 0);
        s2a_kbd_store_load(g2, app, &got); check(same(&got, &std), "④ 默认是 M 时这款改回标准键位：读回仍是标准键位");
        check(s2a_kbd_store_source(g2, app) == S2AKbdSourceCustom, "④ 这款标「自定义」");

        // ⑤ 这款调回和默认一样：不单独存
        s2a_kbd_store_save(g2, app, &M, 0);
        check([g2 objectForKey:K] == nil && s2a_kbd_store_source(g2, app) == S2AKbdSourceDefault, "⑤ 调回和默认一样：删掉本款记录、标「默认」");

        // ⑥ 恢复默认：回到所有游戏的默认
        s2a_kbd_store_save(g2, app, &N, 0);
        s2a_kbd_store_restore(g2);
        s2a_kbd_store_load(g2, app, &got); check(same(&got, &M) && s2a_kbd_store_source(g2, app) == S2AKbdSourceDefault, "⑥ 恢复默认：回到所有游戏的默认 M");

        // ⑦ 撤销（维护方 #1987）：原来没设过 → 撤销后回到没设过，不留一份等于标准键位的记录
        s2a_kbd_store_undo(g1, app, snap);
        check([app objectForKey:K] == nil, "⑦ 原来没设过：撤销后 App 级没有记录（不是一份等于标准键位的存档）");
        check(s2a_kbd_store_source(g1, app) == S2AKbdSourceStandard, "⑦ 撤销后这款回到标准键位（不显示标记）");

        //   原来有默认 M、这款自己存着 N → 把 N 设为默认 → 撤销：App 级逐字回到 M，这款的 N 也回来
        s2a_kbd_store_set_default(g2, app, &M, 0);
        s2a_kbd_store_save(g1, app, &N, 0);
        NSString *beforeApp = [app stringForKey:K], *beforeGame = [g1 stringForKey:K];
        NSDictionary *snap2 = s2a_kbd_store_set_default(g1, app, &N, 0);
        check([[app stringForKey:K] isEqualToString:json(&N)] && [g1 objectForKey:K] == nil, "⑦ 把 N 设为默认：App 级是 N、这款不单独存");
        s2a_kbd_store_undo(g1, app, snap2);
        check([[app stringForKey:K] isEqualToString:beforeApp] && [[g1 stringForKey:K] isEqualToString:beforeGame], "⑦ 撤销：App 级逐字回到 M，这款的 N 也回来");

        //   设成和 iPad 缺省一样 = 没设过
        s2a_kbd_store_set_default(g1, app, &ipad, 0);
        check([app objectForKey:K] == nil && s2a_kbd_store_source(g1, app) == S2AKbdSourceStandard, "⑦ 设成和 iPad 缺省一样：App 级不留记录");

        // ⑧ 单款壳（app = nil）：生效的缺省一律 iPad 缺省，「设为所有游戏的默认」不写任何东西
        NSUserDefaults *shell = suite(names);
        s2a_kbd_store_save(shell, nil, &M, 0);
        check([[shell stringForKey:K] isEqualToString:json(&M)], "⑧ 单款壳：改过就存");
        s2a_kbd_store_save(shell, nil, &ipad, 0);
        check([shell objectForKey:K] == nil, "⑧ 单款壳：改回 iPad 缺省就删（不会把自己当成默认）");
        check(s2a_kbd_store_set_default(shell, nil, &M, 0) == nil && [shell objectForKey:K] == nil, "⑧ 单款壳：设为所有游戏的默认什么都不写");
        [app setObject:@"{" forKey:K];
        s2a_kbd_store_effective_default(app, &got); check(same(&got, &ipad), "⑧ App 级读不懂：生效的缺省用 iPad 缺省");

        // ⑨ 接 settings.m 的真分层：两层取对；新游戏经分层读取拿到 App 级（S2AKeyboardMap 在按款键表里）
        NSUserDefaults *std_d = NSUserDefaults.standardUserDefaults;
        id kept = [std_d objectForKey:K];
        NSString *gidA = @"0100000000KBD001", *gidB = @"0100000000KBD002";
        setenv("S2A_LAUNCH_GAME_ID", gidA.UTF8String, 1);
        NSUserDefaults *lg = nil, *la = nil; s2a_ios_settings_layers(&lg, &la);
        check(la == std_d && lg != nil && lg != std_d, "⑨ 选了游戏：App 级是标准偏好，本款是另一层");
        [s2a_ios_settings_defaults() setObject:json(&N) forKey:K];
        check([[lg stringForKey:K] isEqualToString:json(&N)] && ![[std_d stringForKey:K] isEqualToString:json(&N)], "⑨ 分层对象写的键位落在本款那一层");
        s2a_kbd_store_set_default(lg, la, &M, 0);
        check([[s2a_ios_settings_defaults_for(gidB) stringForKey:K] isEqualToString:json(&M)], "⑨ 守卫：新游戏经分层读取拿到所有游戏的默认");
        id keptOff = [std_d objectForKey:OFF];
        [s2a_ios_settings_defaults() setBool:YES forKey:OFF];
        check([lg objectForKey:OFF] != nil && [std_d objectForKey:OFF] == keptOff, "⑨ 鼠标开关也按款存：分层对象写的落在本款那一层（S2AMouseOff 在按款键表里）");
        s2a_kbd_store_set_default(lg, la, &M, 1);
        check([s2a_ios_settings_defaults_for(gidB) boolForKey:OFF], "⑨ 守卫：新游戏经分层读取拿到所有游戏默认的「关掉鼠标」");
        if (keptOff) [std_d setObject:keptOff forKey:OFF]; else [std_d removeObjectForKey:OFF];
        [lg removePersistentDomainForName:[@"S2AGame." stringByAppendingString:gidA]];
        unsetenv("S2A_LAUNCH_GAME_ID");
        s2a_ios_settings_layers(&lg, &la);
        check(lg == std_d && la == nil, "⑨ 单款壳 / 没选游戏：本款就是 App 级、没有所有游戏的默认");
        if (kept) [std_d setObject:kept forKey:K]; else [std_d removeObjectForKey:K];

        // ⑩「使用鼠标 / 触控板」开关（#2072）：缺省打开（没有记录 = 用鼠标）；和键位同一套两层规则
        NSUserDefaults *app2 = suite(names), *h1 = suite(names), *h2 = suite(names);
        check(!s2a_kbd_store_mouse_off(h1, app2), "⑩ 初始：用鼠标（缺省打开，同 Mac）");
        s2a_kbd_store_save(h1, app2, &ipad, 1);
        check([[h1 objectForKey:OFF] isEqual:@YES] && [h1 objectForKey:K] == nil && s2a_kbd_store_mouse_off(h1, app2), "⑩ 这款关掉鼠标：只存开关，键位仍跟着缺省（不写一份等于缺省的键位）");
        check(s2a_kbd_store_source(h1, app2) == S2AKbdSourceCustom, "⑩ 只关了鼠标也算这款「自定义」");
        s2a_kbd_store_save(h1, app2, &ipad, 0);
        check([h1 objectForKey:OFF] == nil && s2a_kbd_store_source(h1, app2) == S2AKbdSourceStandard, "⑩ 打开回来 = 和缺省一样：删掉记录，回到初始状态");
        NSDictionary *snap3 = s2a_kbd_store_set_default(h1, app2, &ipad, 1);
        check([[app2 objectForKey:OFF] isEqual:@YES] && [app2 objectForKey:K] == nil && [h1 objectForKey:OFF] == nil, "⑩ 设为默认：App 级记下关掉鼠标，这款不单独存");
        check(s2a_kbd_store_mouse_off(h2, app2) && s2a_kbd_store_source(h2, app2) == S2AKbdSourceDefault, "⑩ 守卫：新游戏跟着所有游戏的默认关掉鼠标、标「默认」");
        s2a_kbd_store_save(h2, app2, &ipad, 0);
        check([[h2 objectForKey:OFF] isEqual:@NO] && !s2a_kbd_store_mouse_off(h2, app2) && s2a_kbd_store_source(h2, app2) == S2AKbdSourceCustom,
              "⑩ 默认关掉时这款打开：单独存「打开」，读回仍是打开");
        s2a_kbd_store_restore(h2);
        check([h2 objectForKey:OFF] == nil && s2a_kbd_store_mouse_off(h2, app2), "⑩ 恢复默认：开关也回到所有游戏的默认（关掉）");
        s2a_kbd_store_undo(h1, app2, snap3);
        check([app2 objectForKey:OFF] == nil && !s2a_kbd_store_mouse_off(h1, app2) && s2a_kbd_store_source(h1, app2) == S2AKbdSourceStandard,
              "⑩ 撤销：原来没设过 → App 级不留开关记录，回到打开");
        s2a_kbd_store_save(h1, app2, &ipad, 1);
        NSDictionary *snap4 = s2a_kbd_store_set_default(h1, app2, &N, 0);
        check([[app2 stringForKey:K] isEqualToString:json(&N)] && [app2 objectForKey:OFF] == nil && [h1 objectForKey:OFF] == nil, "⑩ 把「N + 用鼠标」设为默认：这款原来的「关掉」不再单独存");
        s2a_kbd_store_undo(h1, app2, snap4);
        check([[h1 objectForKey:OFF] isEqual:@YES] && [app2 objectForKey:K] == nil && [app2 objectForKey:OFF] == nil, "⑩ 撤销：这款的「关掉」原样回来，App 级回到没设过");
        NSUserDefaults *shell2 = suite(names);
        s2a_kbd_store_save(shell2, nil, &ipad, 1);
        check([[shell2 objectForKey:OFF] isEqual:@YES] && s2a_kbd_store_mouse_off(shell2, nil), "⑩ 单款壳：关掉就存");
        s2a_kbd_store_save(shell2, nil, &ipad, 0);
        check([shell2 objectForKey:OFF] == nil && s2a_kbd_store_set_default(shell2, nil, &ipad, 1) == nil && [shell2 objectForKey:OFF] == nil, "⑩ 单款壳：打开回来就删；设为默认什么都不写");

        for (NSString *n in names) [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:n];
    }
    if (failures) { fprintf(stderr, "✗ t_keyboard_store：%d/%d 项不通\n", failures, checks); return 1; }
    printf("✓ t_keyboard_store：%d 项（两层存取、新游戏用所有游戏的默认、撤销原样写回、单款壳、鼠标开关）\n", checks);
    return 0;
}
