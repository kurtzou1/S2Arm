#import <Foundation/Foundation.h>
#import "../../ios/settings.h"
#include "../include/caps.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, checks;
static void check(BOOL ok, NSString *what) {
    checks++;
    if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what.UTF8String); }
}
static const char *variables[] = {"S2A_RES_SCALE", "S2A_ANTI_ALIASING", "S2A_SCALING_FILTER", "S2A_FPS"};
static NSString *const keys[] = {@"S2AResolutionScale", @"S2AAntiAliasing", @"S2AScalingFilter", @"S2AFrameRateLimit"};
static void clear_environment(void) {
    for (size_t i = 0; i < 4; i++) unsetenv(variables[i]);
    unsetenv("S2A_WIDESCREEN"); unsetenv("S2A_FPS60"); unsetenv("S2A_CPATCH_ON"); unsetenv("S2A_DOCKED"); unsetenv("MTL_HUD_ENABLED");
}

static int reload_checks(BOOL explicit) {
    NSString *suite = [@"local.s2arm.settings-reload." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setObject:@"1.5" forKey:keys[0]];
    [defaults setObject:@"Fxaa" forKey:keys[1]];
    [defaults setObject:@"Nearest" forKey:keys[2]];
    [defaults setObject:@"60" forKey:keys[3]];
    [defaults setBool:YES forKey:@"S2ADockedMode"];
    [defaults setBool:NO forKey:@"S2AWidescreen"];
    [defaults setBool:NO forKey:@"S2AFps60"];
    [defaults setBool:YES forKey:@"S2ADevHUD"];
    [defaults setObject:@[@"first"] forKey:@"S2ACommunityPatches"];
    s2a_ios_apply_graphics_settings(defaults);
    check(getenv("S2A_WIDESCREEN") && !strcmp(getenv("S2A_WIDESCREEN"), "0") &&
          getenv("S2A_FPS60") && !strcmp(getenv("S2A_FPS60"), "0") &&
          getenv("S2A_HUD") && !strcmp(getenv("S2A_HUD"), "1") &&
          getenv("S2A_CPATCH_ON") && !strcmp(getenv("S2A_CPATCH_ON"), "first"), @"首局实际导出关闭项、HUD和社区补丁");
    [defaults setObject:@"2" forKey:keys[0]];
    [defaults setObject:@"SmaaHigh" forKey:keys[1]];
    [defaults setObject:@"Bilinear" forKey:keys[2]];
    [defaults setObject:@"120" forKey:keys[3]];
    [defaults setBool:NO forKey:@"S2ADockedMode"];
    [defaults setBool:YES forKey:@"S2AWidescreen"];
    [defaults setBool:YES forKey:@"S2AFps60"];
    [defaults setBool:NO forKey:@"S2ADevHUD"];
    [defaults removeObjectForKey:@"S2ACommunityPatches"];
    s2a_ios_reapply_graphics_settings(defaults);
    const char *expected[] = {explicit ? "1.5" : "2", explicit ? "Fxaa" : "SmaaHigh",
                              explicit ? "Nearest" : "Bilinear", explicit ? "60" : "120"};
    for (size_t i = 0; i < 4; i++)
        check(getenv(variables[i]) && !strcmp(getenv(variables[i]), expected[i]), @"新会话应用偏好，或保留同值的显式启动环境");
    check(getenv("S2A_DOCKED") && !strcmp(getenv("S2A_DOCKED"), explicit ? "1" : "0"), @"重读主机档保留环境来源");
    for (NSString *name in @[@"S2A_WIDESCREEN", @"S2A_FPS60", @"S2A_HUD", @"S2A_CPATCH_ON"]) {
        const char *value = getenv(name.UTF8String);
        NSString *expected = [name isEqual:@"S2A_HUD"] ? @"1" : [name isEqual:@"S2A_CPATCH_ON"] ? @"first" : @"0";
        check(explicit ? value && !strcmp(value, expected.UTF8String) : value == NULL, @"回到默认时撤销自身注入值，显式启动环境不撤销");
    }
    check([[defaults objectForKey:keys[0]] isEqual:@"2"] && ![defaults boolForKey:@"S2ADockedMode"], @"环境覆盖不改写新保存的偏好");
    setenv("S2A_FPS", "30", 1);
    [defaults setObject:@"0" forKey:keys[3]];
    s2a_ios_reapply_graphics_settings(defaults);
    check(getenv("S2A_FPS") && !strcmp(getenv("S2A_FPS"), "30"), @"重启前其他模块改写的环境保持优先");
    s2a_ios_reapply_graphics_settings(defaults);
    check(getenv("S2A_FPS") && !strcmp(getenv("S2A_FPS"), "30"), @"重复重读不重新取得其他模块的环境所有权");
    [defaults removePersistentDomainForName:suite];
    printf("%s t_ios_settings_reload_%s：%d 项检查，%d 项失败\n", failures ? "✗" : "✓", explicit ? "explicit" : "owned", checks, failures);
    return failures ? 1 : 0;
}

static void run_reload_processes(const char *executable, const char *plist) {
    NSDictionary *launch = @{@"S2A_RES_SCALE": @"1.5", @"S2A_ANTI_ALIASING": @"Fxaa", @"S2A_SCALING_FILTER": @"Nearest",
        @"S2A_FPS": @"60", @"S2A_DOCKED": @"1", @"S2A_WIDESCREEN": @"0", @"S2A_FPS60": @"0", @"S2A_HUD": @"1", @"S2A_CPATCH_ON": @"first"};
    for (NSString *mode in @[@"--reload-owned", @"--reload-explicit"]) {
        NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@(executable)];
        task.arguments = @[@(plist), mode];
        NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
        [environment removeObjectsForKeys:launch.allKeys];
        if ([mode isEqual:@"--reload-explicit"]) [environment addEntriesFromDictionary:launch];
        task.environment = environment;
        NSError *error = nil;
        BOOL started = [task launchAndReturnError:&error];
        check(started, [@"实际偏好子进程启动：" stringByAppendingString:error.localizedDescription ?: mode]);
        if (started) { [task waitUntilExit]; check(task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0, @"新进程真实启动环境与多会话偏好重读通过"); }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && (!strcmp(argv[2], "--reload-owned") || !strcmp(argv[2], "--reload-explicit")))
            return reload_checks(!strcmp(argv[2], "--reload-explicit"));
        if (argc != 2) return 2;
        {   // 开发设施开关（settings.m s2a_dev_plist_from，os.c s2a_dev_on 按名字取）：有键回 1，"0" 开头为关；没有键 / 非字符串 / 空串回 0（= 没有这个键）
            int s2a_dev_plist_from(NSDictionary *info, int *on); int on = -1;
            check(s2a_dev_plist_from(@{@"S2ADevFacilities": @"0"}, &on) == 1 && on == 0, @"开发设施：玩家包 Info.plist 写 \"0\" → 有键、关");
            on = -1; check(s2a_dev_plist_from(@{@"S2ADevFacilities": @"1"}, &on) == 1 && on == 1, @"开发设施：写 \"1\" → 有键、开");
            on = -1; check(s2a_dev_plist_from(@{}, &on) == 0 && on == -1, @"开发设施：没有键 → 回 0、不动 on（开发包缺省开）");
            on = -1; check(s2a_dev_plist_from(@{@"S2ADevFacilities": @""}, &on) == 0, @"开发设施：空串当没有键");
            on = -1; check(s2a_dev_plist_from(@{@"S2ADevFacilities": @0}, &on) == 0, @"开发设施：非字符串当没有键");
        }
        run_reload_processes(argv[0], argv[1]);
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1]) options:0 error:&error];
        if (!data) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
        NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
        if (!plist) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
        NSMutableDictionary *specs = [NSMutableDictionary new];
        NSDictionary *group = nil;
        NSUInteger groupItems = 0; BOOL gfxGroup = NO;   // 画面组（含画面设置键）：说明对应且仅对应一个设置项；别的组（如诊断）只要求不空
        NSDictionary *footers = @{   // Root.plist 原文是英文，中文在 zh-Hans.lproj/Root.strings（#316，两边一一对应由 tests/ios_l10n_test.sh 核）
            @"S2AResolutionScale": @"Scales relative to the game’s current render size",
            @"S2AAntiAliasing": @"Reduces jagged edges in the final game picture",
            @"S2AScalingFilter": @"Used to scale the game picture to the screen",
            @"S2AFrameRateLimit": @"Sets a frame rate cap for the game picture",
        };
        for (NSDictionary *spec in plist[@"PreferenceSpecifiers"]) {
            if ([spec[@"Type"] isEqual:@"PSGroupSpecifier"]) {
                if (group) check(gfxGroup ? groupItems == 1 : groupItems >= 1, gfxGroup ? @"画面组说明对应且仅对应一个设置项" : @"非画面组不为空");
                group = spec;
                groupItems = 0; gfxGroup = NO;
            } else {
                groupItems++;
                if (spec[@"Key"] && footers[spec[@"Key"]]) gfxGroup = YES;
                if ([spec[@"Type"] isEqual:@"PSMultiValueSpecifier"] && footers[spec[@"Key"]]) {
                    specs[spec[@"Key"]] = spec;
                    check([group[@"FooterText"] hasPrefix:footers[spec[@"Key"]]], [spec[@"Key"] stringByAppendingString:@" 的组说明对应当前选项"]);
                    if ([spec[@"Key"] isEqual:keys[0]]) {
                        check([group[@"Title"] isEqual:@"Graphics (Restart the Game to Apply)"], @"画面首组标题提示重开游戏");
                    }
                }
            }
        }
        check(gfxGroup ? groupItems == 1 : groupItems >= 1, @"最后一组包含设置项，没有空组");
        check(specs.count == 4, @"系统设置包含四个画面选项");
        // 满屏 / 60 帧开关只在 App 内设置页（11-02 维护者：系统设置里的开关是静态的，缺省显示开、包里关了也照样显示开，按了不生效，误导玩家）
        BOOL stray = NO; for (NSDictionary *spec in plist[@"PreferenceSpecifiers"]) if ([spec[@"Key"] isEqual:@"S2AFps60"] || [spec[@"Key"] isEqual:@"S2AWidescreen"]) stray = YES;
        check(!stray, @"系统设置里没有满屏 / 60 帧开关（只在 App 内设置页）");

        NSString *suiteA = [@"local.s2arm.settings-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *suiteB = [suiteA stringByAppendingString:@".other-app"];
        NSUserDefaults *a = [[NSUserDefaults alloc] initWithSuiteName:suiteA];
        NSUserDefaults *b = [[NSUserDefaults alloc] initWithSuiteName:suiteB];
        [a removePersistentDomainForName:suiteA];
        [b removePersistentDomainForName:suiteB];

        clear_environment();
        s2a_ios_apply_graphics_settings(a);
        for (NSDictionary *option in s2a_ios_graphics_options()) {
            check([option[@"values"] isEqual:specs[option[@"key"]][@"Values"]], @"应用内分档值与系统设置保存值兼容");
            check([option[@"initial"] isEqual:specs[option[@"key"]][@"DefaultValue"]], @"应用内默认值与系统设置一致");
        }
        for (size_t i = 0; i < 4; i++) {
            NSDictionary *spec = specs[keys[i]];
            check([spec[@"DefaultValue"] isEqual:@(getenv(variables[i]))], [keys[i] stringByAppendingString:@" 的首次启动值与菜单默认值一致"]);
            check([spec[@"Values"] count] == [spec[@"Titles"] count], [keys[i] stringByAppendingString:@" 的显示项与保存值数量一致"]);
            check([spec[@"Values"] containsObject:spec[@"DefaultValue"]], [keys[i] stringByAppendingString:@" 的默认值是有效选项"]);
            for (NSString *value in spec[@"Values"]) {
                [a setObject:value forKey:keys[i]];
                check([a synchronize], @"偏好写入成功");
                clear_environment();
                NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suiteA];
                s2a_ios_apply_graphics_settings(reopened);
                check([value isEqual:@(getenv(variables[i]))], [NSString stringWithFormat:@"%@=%@ 保存后重新读取并传给渲染器", keys[i], value]);
                check([[reopened objectForKey:keys[i]] isEqual:value], [keys[i] stringByAppendingString:@" 的合法保存值保持不变"]);
            }
            [a removeObjectForKey:keys[i]];
        }

        [a setObject:@"2" forKey:keys[0]];
        [a setObject:@"SmaaHigh" forKey:keys[1]];
        [a setObject:@"Nearest" forKey:keys[2]];
        [a setObject:@"120" forKey:keys[3]];
        [a setBool:YES forKey:@"S2ANS2ProAdapterEnabled"];
        clear_environment();
        s2a_ios_apply_graphics_settings(a);
        check(!strcmp(getenv(variables[0]), "2") && !strcmp(getenv(variables[1]), "SmaaHigh") && !strcmp(getenv(variables[2]), "Nearest") && !strcmp(getenv(variables[3]), "120"), @"四个自定义设置同时生效");
        check([a boolForKey:@"S2ANS2ProAdapterEnabled"], @"读取画面设置保留现有手柄偏好");
        clear_environment();
        s2a_ios_apply_graphics_settings(b);
        check(!strcmp(getenv(variables[0]), "1") && !strcmp(getenv(variables[1]), "None") && !strcmp(getenv(variables[2]), "Bilinear") && !strcmp(getenv(variables[3]), "0"), @"另一 App 的偏好仍是默认值");

        clear_environment();
        setenv(variables[0], "0.75", 1);
        setenv(variables[1], "SmaaHigh", 1);
        setenv(variables[2], "Bilinear", 1);
        setenv(variables[3], "30", 1);
        s2a_ios_apply_graphics_settings(a);
        check(!strcmp(getenv(variables[0]), "0.75") && !strcmp(getenv(variables[1]), "SmaaHigh") && !strcmp(getenv(variables[2]), "Bilinear") && !strcmp(getenv(variables[3]), "30"), @"起局工具的显式环境优先于保存的偏好");
        for (size_t i = 0; i < 4; i++) [a setObject:@"obsolete" forKey:keys[i]];
        s2a_ios_apply_graphics_settings(a);
        check(!strcmp(getenv(variables[0]), "0.75") && !strcmp(getenv(variables[1]), "SmaaHigh") && !strcmp(getenv(variables[2]), "Bilinear") && !strcmp(getenv(variables[3]), "30"), @"显式环境优先于失效的保存偏好");
        for (size_t i = 0; i < 4; i++) {
            check([[a objectForKey:keys[i]] isEqual:@"obsolete"], [keys[i] stringByAppendingString:@" 被显式环境覆盖时不读取或改写保存值"]);
            [a removeObjectForKey:keys[i]];
        }

        for (size_t i = 0; i < 4; i++) {
            for (id invalid in @[@"obsolete", @2]) {
                clear_environment();
                [a setObject:invalid forKey:keys[i]];
                s2a_ios_apply_graphics_settings(a);
                check([specs[keys[i]][@"DefaultValue"] isEqual:@(getenv(variables[i]))], [NSString stringWithFormat:@"%@ 的非法保存值 %@ 使用默认值", keys[i], invalid]);
                check([a objectForKey:keys[i]] == nil, [keys[i] stringByAppendingString:@" 的非法保存值已清除"]);
                check([a synchronize], @"清除后的偏好写入成功");
                clear_environment();
                NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suiteA];
                s2a_ios_apply_graphics_settings(reopened);
                check([specs[keys[i]][@"DefaultValue"] isEqual:@(getenv(variables[i]))] && [reopened objectForKey:keys[i]] == nil, [keys[i] stringByAppendingString:@" 再次启动仍使用默认值且无失效保存值"]);
            }
        }


        // Switch 主机档与图形运行模式分别设置；偏好只在下次进程启动时导出。
        {
            NSString *key = @"S2ADockedMode";
            NSDictionary *docked = nil; NSUInteger count = 0;
            for (NSDictionary *spec in plist[@"PreferenceSpecifiers"])
                if ([spec[@"Key"] isEqual:key]) { docked = spec; count++; }
            check(count == 1 && [docked[@"Type"] isEqual:@"PSToggleSwitchSpecifier"] && [docked[@"Title"] isEqual:@"Docked Mode"] && [docked[@"DefaultValue"] isEqual:@NO], @"主机模式设置只有一个开关且默认关闭");
            check([s2a_ios_graphics_snapshot(a)[key] isEqual:@NO], @"应用内首次读取为掌机档");
            clear_environment();
            s2a_ios_apply_graphics_settings(a);
            check(getenv("S2A_DOCKED") && !strcmp(getenv("S2A_DOCKED"), "0"), @"首次启动导出掌机档 S2A_DOCKED=0");
            [a setBool:YES forKey:key];
            check([a synchronize], @"主机模式偏好写入成功");
            check([s2a_ios_graphics_snapshot(a)[key] isEqual:@YES], @"应用内读取已保存的主机档");
            check(getenv("S2A_DOCKED") && !strcmp(getenv("S2A_DOCKED"), "0"), @"修改偏好不改变当前进程的档位");
            clear_environment();
            NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suiteA];
            s2a_ios_apply_graphics_settings(reopened);
            check(getenv("S2A_DOCKED") && !strcmp(getenv("S2A_DOCKED"), "1"), @"重开后导出已保存的主机档 S2A_DOCKED=1");
            clear_environment();
            s2a_ios_apply_graphics_settings(b);
            check(getenv("S2A_DOCKED") && !strcmp(getenv("S2A_DOCKED"), "0") && [s2a_ios_graphics_snapshot(b)[key] isEqual:@NO], @"另一 App 保持掌机默认值");
            setenv("S2A_DOCKED", "0", 1);
            s2a_ios_apply_graphics_settings(a);
            check(!strcmp(getenv("S2A_DOCKED"), "0") && [a boolForKey:key], @"显式掌机环境优先且保留主机偏好");
            [a setBool:NO forKey:key];
            setenv("S2A_DOCKED", "1", 1);
            s2a_ios_apply_graphics_settings(a);
            check(!strcmp(getenv("S2A_DOCKED"), "1") && ![a boolForKey:key], @"显式主机环境优先且保留掌机偏好");
            check([a synchronize], @"掌机模式偏好写入成功");
            clear_environment();
            reopened = [[NSUserDefaults alloc] initWithSuiteName:suiteA];
            s2a_ios_apply_graphics_settings(reopened);
            check(getenv("S2A_DOCKED") && !strcmp(getenv("S2A_DOCKED"), "0") && [s2a_ios_graphics_snapshot(reopened)[key] isEqual:@NO], @"关掉主机模式后重开导出掌机档");
            [a removeObjectForKey:key];
        }

        // 开发浮层开关：缺省关 = 不设 S2A_HUD；打开 = S2A_HUD=1；启动环境显式给的优先
        {
            clear_environment(); unsetenv("S2A_HUD"); [a removeObjectForKey:@"S2ADevHUD"];
            NSDictionary *hud = nil; for (NSDictionary *spec in plist[@"PreferenceSpecifiers"]) if ([spec[@"Key"] isEqual:@"S2ADevHUD"]) hud = spec;
            check([hud[@"Type"] isEqual:@"PSToggleSwitchSpecifier"] && [hud[@"DefaultValue"] isEqual:@NO], @"开发浮层开关在设置页、缺省关");
            s2a_ios_apply_graphics_settings(a); check(getenv("S2A_HUD") == NULL, @"开发浮层开关关着：不设 S2A_HUD");
            [a setBool:YES forKey:@"S2ADevHUD"]; clear_environment();
            s2a_ios_apply_graphics_settings(a); check(getenv("S2A_HUD") && !strcmp(getenv("S2A_HUD"), "1"), @"开发浮层开关打开：S2A_HUD=1");
            setenv("S2A_HUD", "0", 1); clear_environment();
            s2a_ios_apply_graphics_settings(a); check(!strcmp(getenv("S2A_HUD"), "0"), @"显式 S2A_HUD=0 优先于开关");
            unsetenv("S2A_HUD"); [a removeObjectForKey:@"S2ADevHUD"];
        }

        // 缺口扫描族 2：设置页「完成」时掌机 / 主机运行中直接切（返回要切的值，交 s2a_console_mode_set），不算重启项；别的画面设置变了照旧要重启
        {
            BOOL restart = YES;
            NSInteger d = s2a_ios_settings_docked_change(@{@"S2ADockedMode": @NO, @"S2AWidescreen": @YES}, @{@"S2ADockedMode": @YES, @"S2AWidescreen": @YES}, &restart);
            check(d == 1 && !restart, @"只切主机：运行中切成 1、不提示重启");
            d = s2a_ios_settings_docked_change(@{@"S2ADockedMode": @YES}, @{@"S2ADockedMode": @NO}, &restart);
            check(d == 0 && !restart, @"只切掌机：运行中切成 0、不提示重启");
            d = s2a_ios_settings_docked_change(@{@"S2ADockedMode": @NO, @"S2AWidescreen": @YES}, @{@"S2ADockedMode": @NO, @"S2AWidescreen": @NO}, &restart);
            check(d == -1 && restart, @"底座没变、宽屏变了：不切、提示重启");
            d = s2a_ios_settings_docked_change(@{@"S2ADockedMode": @NO, @"S2AFps60": @YES}, @{@"S2ADockedMode": @YES, @"S2AFps60": @NO}, &restart);
            check(d == 1 && restart, @"底座和 60 帧都变：切成 1、仍提示重启");
            NSDictionary *before = s2a_ios_graphics_snapshot(a);
            [a setBool:![a boolForKey:@"S2ADockedMode"] forKey:@"S2ADockedMode"];
            d = s2a_ios_settings_docked_change(before, s2a_ios_graphics_snapshot(a), &restart);
            check(d == ([a boolForKey:@"S2ADockedMode"] ? 1 : 0) && !restart, @"真实快照：设置页翻底座开关后判出要切的值");
            [a removeObjectForKey:@"S2ADockedMode"];
        }

        // Metal 直接读取官方 UserDefaults 键；与 S2Arm 浮层偏好独立。
        {
            NSString *key = @"MetalHUDForceEnabled";
            NSDictionary *metal = nil;
            for (NSDictionary *spec in plist[@"PreferenceSpecifiers"])
                if ([spec[@"Key"] isEqual:key]) metal = spec;
            check([metal[@"Type"] isEqual:@"PSToggleSwitchSpecifier"] && [metal[@"DefaultValue"] isEqual:@NO], @"Metal HUD 使用官方偏好键且缺省关");
            [a setBool:YES forKey:key];
            check([a synchronize], @"Metal HUD 偏好写入成功");
            NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suiteA];
            check([reopened boolForKey:key] && ![reopened boolForKey:@"S2ADevHUD"], @"重开后 Metal HUD 保存值与 S2Arm 浮层独立");
            check(![b boolForKey:key], @"另一 App 不继承 Metal HUD 偏好");
            // 审计 P2-21：开关要真的变成 MTL_HUD_ENABLED（关着不设、开着设 1、启动环境显式给的优先）
            unsetenv("MTL_HUD_ENABLED"); [a setBool:NO forKey:key];
            s2a_ios_apply_graphics_settings(a); check(getenv("MTL_HUD_ENABLED") == NULL, @"Metal HUD 开关关着：不设 MTL_HUD_ENABLED");
            [a setBool:YES forKey:key];
            s2a_ios_apply_graphics_settings(a); check(getenv("MTL_HUD_ENABLED") && !strcmp(getenv("MTL_HUD_ENABLED"), "1"), @"Metal HUD 开关打开：MTL_HUD_ENABLED=1");
            setenv("MTL_HUD_ENABLED", "0", 1);
            s2a_ios_apply_graphics_settings(a); check(!strcmp(getenv("MTL_HUD_ENABLED"), "0"), @"显式 MTL_HUD_ENABLED=0 优先于开关");
            unsetenv("MTL_HUD_ENABLED");
            [a removeObjectForKey:key];
        }

        // 关于本包（#377 F09）：Info.plist → 设置页只读文本；缺字段 / 非 direct（旧的通用包）不许猜成「直连」
        {
            NSDictionary *cases = @{
                @"直连成功": @{@"S2AGraphicsMode": @"direct", @"S2ADirectLibVersion": @"b-0a7dae3c1e7b",
                              @"S2APackTime": @"2026-10-25T15:40:00Z", @"S2ABuildID": @"abc123"},
                @"旧通用包": @{@"S2AGraphicsMode": @"generic", @"S2AGraphicsModeReason": @"推导配置失败：没有可用配置档",
                                @"S2APackTime": @"2026-10-25T15:41:00Z"},
                @"缺字段": @{},
            };
            for (NSString *name in cases) {
                NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:[suiteA stringByAppendingString:name]];
                s2a_ios_publish_bundle_info(cases[name], suite);
                NSString *mode = [suite objectForKey:@"S2AGraphicsModeText"];
                if ([name isEqual:@"直连成功"]) {
                    check([mode isEqual:[NSBundle.mainBundle localizedStringForKey:@"about.mode.direct" value:nil table:@"S2ArmHost"]], @"直连局显示当前语言的直连说明");
                    check([[suite objectForKey:@"S2ADirectLibVersionText"] isEqual:@"b-0a7dae3c1e7b"], @"直连库版本照原样显示");
                    check([[suite objectForKey:@"S2ABuildIDText"] isEqual:@"abc123"], @"包号照原样显示");
                } else {
                    check([mode isEqual:[NSBundle.mainBundle localizedStringForKey:@"about.mode.unrecorded" value:nil table:@"S2ArmHost"]], [name stringByAppendingString:@"：画面模式不是 direct 时显示未知，不许当直连"]);
                    check([[suite objectForKey:@"S2ADirectLibVersionText"] isEqual:[NSBundle.mainBundle localizedStringForKey:@"about.directLib.none" value:nil table:@"S2ArmHost"]], [name stringByAppendingString:@"：缺直连库版本时说明这一包没带"]);
                }
                check([[suite objectForKey:@"S2APackTimeText"] length] > 0, [name stringByAppendingString:@" 出包时间总有值（缺则未知）"]);
            }
            NSUInteger aboutRows = 0;
            for (NSDictionary *spec in plist[@"PreferenceSpecifiers"])
                if ([spec[@"Type"] isEqual:@"PSTitleValueSpecifier"] && [spec[@"Key"] hasSuffix:@"Text"]) aboutRows++;
            check(aboutRows == 4, @"设置页有四个只读行（画面模式 / 直连库版本 / 出包时间 / 包号）");
        }

        // 包内能力清单接线（10-28 全能力出包）：起局时清单从 App 包顶层读（模块此刻还没装载，不能按模块目录取）。
        //   命令行程序的 NSBundle.mainBundle 是可执行文件所在目录：在那里放一份 widen 1 / fps60 1 的清单，走真实入口。
        //   ⓐ 用户没动过设置 → 清单生效：S2A_WIDEN_CAPS=1、S2A_FPS60=1；判定局专用的 S2A_WIDEN_VERIFIED 不碰
        //   ⓑ 用户在设置里关了 60 帧与宽屏（审计 #854 F-caps-beats-settings）→ 设置赢：S2A_FPS60=0、S2A_WIDESCREEN=0（widen.c 设置关先于清单判）
        {
            NSString *caps = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"s2a_caps.tsv"];
            check([@"widen\t1\t# 单测\nfps60\t1\t# 默认开：来源 fps.tsv\n" writeToFile:caps atomically:YES encoding:NSUTF8StringEncoding error:nil], @"能力清单写进包目录");   // 11-11：原因是速度已验证的来源，清单才替玩家开
            NSUserDefaults *std = NSUserDefaults.standardUserDefaults;
            for (int k = 0; k < 2; k++) {
                [std removeObjectForKey:@"S2AFps60"]; [std removeObjectForKey:@"S2AWidescreen"];
                if (k) { [std setBool:NO forKey:@"S2AFps60"]; [std setBool:NO forKey:@"S2AWidescreen"]; }
                clear_environment(); unsetenv("S2A_WIDEN_VERIFIED"); unsetenv("S2A_WIDEN_CAPS");
                s2a_ios_load_graphics_settings();
                const char *w = getenv("S2A_WIDEN_CAPS"), *f = getenv("S2A_FPS60"), *ws = getenv("S2A_WIDESCREEN"), *v = getenv("S2A_WIDEN_VERIFIED");
                NSString *(^val)(const char *) = ^(const char *e) { return e ? @(e) : @"未设"; };
                NSString *got = [NSString stringWithFormat:@"S2A_WIDEN_CAPS=%@ S2A_FPS60=%@ S2A_WIDESCREEN=%@ S2A_WIDEN_VERIFIED=%@", val(w), val(f), val(ws), val(v)];
                NSString *want = k ? @"S2A_WIDEN_CAPS=1 S2A_FPS60=0 S2A_WIDESCREEN=0 S2A_WIDEN_VERIFIED=未设" : @"S2A_WIDEN_CAPS=1 S2A_FPS60=1 S2A_WIDESCREEN=未设 S2A_WIDEN_VERIFIED=未设";
                check([got isEqual:want], [NSString stringWithFormat:@"起局入口%@：期望 %@ → 真结果 %@", k ? @"（设置关了 60 帧与宽屏）" : @"（没动过设置）", want, got]);
            }
            [std removeObjectForKey:@"S2AFps60"]; [std removeObjectForKey:@"S2AWidescreen"];
            [NSFileManager.defaultManager removeItemAtPath:caps error:nil]; unsetenv("S2A_WIDEN_CAPS"); clear_environment();
        }

        // 60 帧强信号关的款（11-02 维护者定：设置里玩家可手动开；全引擎默认开后清单 fps60 0 只剩强信号）：清单 fps60 0，期望手写——
        //   ⓒ 玩家没动过 → 清单生效 S2A_FPS60=0、不是放开来源；ⓓ 设置页手动开（S2AFps60Manual）→ S2A_FPS60=1、是放开来源（图形层读时判），不写 DM_PRESENT_INTERVAL（审计 P1-80）；
        //   ⓔ 只存着老的 S2AFps60 = YES（关过又开过，没看过提示）→ 不算手动开，仍 0
        {
            NSString *caps = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"s2a_caps.tsv"];
            check([@"fps60\t0\t# 强信号：静态无来源\n" writeToFile:caps atomically:YES encoding:NSUTF8StringEncoding error:nil], @"未验证清单写进包目录");
            check(s2a_ios_caps_value("fps60") == 0, @"读到清单 fps60 0");
            NSUserDefaults *std = NSUserDefaults.standardUserDefaults;
            NSString *names[] = {@"没动过", @"手动开", @"只存着老的 S2AFps60=YES"}, *wants[] = {@"S2A_FPS60=未设 间隔=未设 来源=0", @"S2A_FPS60=1 间隔=未设 来源=1", @"S2A_FPS60=未设 间隔=未设 来源=0"};   // 11-11：清单不再写 S2A_FPS60（没设 = 原帧率）
            for (int k = 0; k < 3; k++) {
                [std removeObjectForKey:@"S2AFps60"]; [std removeObjectForKey:@"S2AFps60Manual"];
                if (k == 1) { [std setBool:YES forKey:@"S2AFps60Manual"]; [std setBool:YES forKey:@"S2AFps60"]; }
                if (k == 2) [std setBool:YES forKey:@"S2AFps60"];
                clear_environment(); unsetenv("DM_PRESENT_INTERVAL");
                s2a_ios_load_graphics_settings();
                const char *f = getenv("S2A_FPS60"), *i = getenv("DM_PRESENT_INTERVAL");
                NSString *got = [NSString stringWithFormat:@"S2A_FPS60=%@ 间隔=%@ 来源=%d", f ? @(f) : @"未设", i ? @(i) : @"未设", s2a_fps60_display_source()];
                check([got isEqual:wants[k]], [NSString stringWithFormat:@"60 帧强信号关的款（%@）：期望 %@ → 真结果 %@", names[k], wants[k], got]);
            }
            [std removeObjectForKey:@"S2AFps60"]; [std removeObjectForKey:@"S2AFps60Manual"];
            [NSFileManager.defaultManager removeItemAtPath:caps error:nil]; clear_environment(); unsetenv("DM_PRESENT_INTERVAL");
            check(s2a_ios_caps_value("fps60") == -1, @"没有清单读到 -1");
        }
        // 审计 P1-80：清单 fps60_display 1 只记来源、不写进程环境（原先 setenv DM_PRESENT_INTERVAL=display 压过 60 帧开关，关了再进程内重启照样 60）
        {
            NSString *caps = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"s2a_caps.tsv"];
            check([@"fps60\t1\t# 单测\nfps60_display\t1\t# 单测\n" writeToFile:caps atomically:YES encoding:NSUTF8StringEncoding error:nil], @"fps60_display 清单写进包目录");
            NSUserDefaults *std = NSUserDefaults.standardUserDefaults; [std removeObjectForKey:@"S2AFps60"]; [std removeObjectForKey:@"S2AFps60Manual"];
            clear_environment(); unsetenv("DM_PRESENT_INTERVAL");
            s2a_ios_load_graphics_settings();
            const char *i = getenv("DM_PRESENT_INTERVAL");
            NSString *got = [NSString stringWithFormat:@"间隔=%@ 来源=%d", i ? @(i) : @"未设", s2a_fps60_display_source()];
            check([got isEqual:@"间隔=未设 来源=0"], [NSString stringWithFormat:@"清单 fps60_display 1（11-11 起不算放开来源，玩家开才放开）：期望 间隔=未设 来源=0 → 真结果 %@", got]);
            [NSFileManager.defaultManager removeItemAtPath:caps error:nil]; clear_environment();
        }

        // 审计 P1-80：立刻重启（s2a_ios_reload_graphics_settings，真实入口）要撤掉清单自己写的 S2A_FPS60。清单 fps60 1，期望手写：
        //   起局没动过设置 → 1；设置里关 60 帧后立刻重启 → 0；再打开（删掉 S2AFps60）后立刻重启 → 1；别的模块改写成别的值后重启 → 保留那个值
        //   旧实现第 2 项红（重读只撤设置页登记的名字，清单写的 1 留着，设置那条「未设才写」写不进）
        {
            NSString *caps = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"s2a_caps.tsv"];
            check([@"fps60\t1\t# 默认开：来源 fps.tsv\n" writeToFile:caps atomically:YES encoding:NSUTF8StringEncoding error:nil], @"fps60 1 清单写进包目录");   // 11-11：验证过的来源清单才写 1，立刻重启才有东西可撤
            NSUserDefaults *std = NSUserDefaults.standardUserDefaults; [std removeObjectForKey:@"S2AFps60"]; [std removeObjectForKey:@"S2AFps60Manual"];
            // 先清空设置页的登记表（进程级，前面 ⓓ 登记过 S2A_FPS60=1）：否则旧实现②会因为登记表里恰好是 1 被撤掉而碰巧过
            NSString *empty = [@"local.s2arm.settings-p180." stringByAppendingString:NSUUID.UUID.UUIDString];
            s2a_ios_reapply_graphics_settings([[NSUserDefaults alloc] initWithSuiteName:empty]); [[NSUserDefaults new] removePersistentDomainForName:empty];
            clear_environment(); unsetenv("DM_PRESENT_INTERVAL");
            NSString *(^val)(void) = ^{ const char *e = getenv("S2A_FPS60"); return e ? @(e) : @"未设"; };
            s2a_ios_load_graphics_settings();
            check([val() isEqual:@"1"], [@"立刻重启①起局没动过设置：期望 1 → 真结果 " stringByAppendingString:val()]);
            [std setBool:NO forKey:@"S2AFps60"];
            check(s2a_ios_reload_graphics_settings() == 0, @"立刻重启②重读成功");
            check([val() isEqual:@"0"], [@"立刻重启②设置里关 60 帧：期望 0 → 真结果 " stringByAppendingString:val()]);
            [std removeObjectForKey:@"S2AFps60"];
            check(s2a_ios_reload_graphics_settings() == 0, @"立刻重启③重读成功");
            check([val() isEqual:@"1"], [@"立刻重启③再打开：期望 1 → 真结果 " stringByAppendingString:val()]);
            setenv("S2A_FPS60", "7", 1);
            check(s2a_ios_reload_graphics_settings() == 0, @"立刻重启④重读成功");
            check([val() isEqual:@"7"], [@"立刻重启④别的模块改写过的值保留：期望 7 → 真结果 " stringByAppendingString:val()]);
            [std removeObjectForKey:@"S2AFps60"];
            [NSFileManager.defaultManager removeItemAtPath:caps error:nil]; clear_environment(); unsetenv("DM_PRESENT_INTERVAL");
        }

        // 审计 P1-9：渲染倍率每次现读。进程内重启重写 S2A_RES_SCALE 后，下一次读到新值（旧实现：函数内静态缓存，一直是第一次读到的 2）
        clear_environment();
        setenv("S2A_RES_SCALE", "2", 1); check(s2a_ios_res_scale(a) == 2.0f, @"渲染倍率：环境变量 2");
        setenv("S2A_RES_SCALE", "1", 1); check(s2a_ios_res_scale(a) == 1.0f, @"渲染倍率：进程内重启改成 1 后读到 1");
        setenv("S2A_RES_SCALE", "9", 1); [a setObject:@"0.75" forKey:@"S2AResolutionScale"]; check(s2a_ios_res_scale(a) == 0.75f, @"渲染倍率：环境变量越界退回设置值 0.75");
        unsetenv("S2A_RES_SCALE"); [a setObject:@"7" forKey:@"S2AResolutionScale"]; check(s2a_ios_res_scale(a) == 1.0f, @"渲染倍率：都越界退回 1");
        [a removeObjectForKey:@"S2AResolutionScale"];

        // 诊断局（#438）：开关开着 → 设定好的四个变量（帧号 3600 / 7200，读数写本款文档根 diagrun/），开关当场关掉，第二次起局不再开；
        //   启动环境显式给的优先。期望值按规格手写
        {   const char *dv[] = {"DM_NVN_PASSDUMP", "DM_NVN_TEXDUMP", "DM_NVN_TEXSNAP", "DM_NVN_SHOT"};
            for (int i = 0; i < 4; i++) unsetenv(dv[i]);
            NSString *docs = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            NSString *dir = [docs stringByAppendingPathComponent:@"diagrun"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [@"old" writeToFile:[dir stringByAppendingPathComponent:@"shot_1.png"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
            setenv("S2A_DOCS", docs.fileSystemRepresentation, 1);
            s2a_ios_apply_diag_run(a);
            check(getenv("DM_NVN_PASSDUMP") == NULL, @"诊断局：开关没开不设探针");
            [a setBool:YES forKey:@"S2ADiagRunNext"]; setenv("DM_NVN_TEXSNAP", "5", 1);
            s2a_ios_apply_diag_run(a);
            NSString *want_td = [NSString stringWithFormat:@"3600,7200:%@/td_%%d.png", dir], *want_shot = [NSString stringWithFormat:@"3600,7200:%@/shot_%%d.png", dir];
            check(getenv("DM_NVN_PASSDUMP") && !strcmp(getenv("DM_NVN_PASSDUMP"), "3600-3601"), @"诊断局：逐通道记录 3600-3601");
            check(getenv("DM_NVN_TEXDUMP") && [@(getenv("DM_NVN_TEXDUMP")) isEqual:want_td], @"诊断局：颜色目标 3600,7200 写 diagrun/td_%d.png");
            check(getenv("DM_NVN_SHOT") && [@(getenv("DM_NVN_SHOT")) isEqual:want_shot], @"诊断局：出图 3600,7200 写 diagrun/shot_%d.png");
            check(getenv("DM_NVN_TEXSNAP") && !strcmp(getenv("DM_NVN_TEXSNAP"), "5"), @"诊断局：启动环境显式给的优先");
            check(![a boolForKey:@"S2ADiagRunNext"], @"诊断局：开关用一次就关（只管这一局）");
            check(![NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"shot_1.png"]] && [NSFileManager.defaultManager fileExistsAtPath:dir],
                  @"诊断局：上一次的图清掉、diagrun 目录在");
            for (int i = 0; i < 4; i++) unsetenv(dv[i]);
            s2a_ios_apply_diag_run(a);
            check(getenv("DM_NVN_PASSDUMP") == NULL, @"诊断局：第二次起局不再开");
            unsetenv("S2A_DOCS"); [NSFileManager.defaultManager removeItemAtPath:docs error:nil];
        }
        // 本地玩家（#623）：游戏库写的玩家表（shell LocalPlayers.swift 的格式）→ 起局环境与这个玩家的存档位置，走真实入口 s2a_ios_load_graphics_settings。期望手写：
        //   ⓐ 没建过玩家 → 不给玩家、SaveData（旧行为）；ⓑ 当前是第一个玩家 → first、SaveData、没改过名不给名字；ⓒ 当前是 Hong → 她的用户号、SaveData-Hong、名字；
        //   ⓓ 当前 uid 不在表里 → 第一个玩家；ⓔ 文件夹名想跳出本款文档根（../x）→ 按用户号起名；ⓕ 启动环境显式给的玩家优先
        {   NSUserDefaults *std = NSUserDefaults.standardUserDefaults;
            NSString *docs = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            setenv("S2A_DOCS", docs.fileSystemRepresentation, 1);
            NSString *hong = @"d7a43a96495d0a594e615dd88587b6bf";
            NSArray *table = @[@{@"uid": @"", @"name": @"", @"folder": @"SaveData"}, @{@"uid": hong, @"name": @"Hong", @"folder": @"SaveData-Hong"}];
            NSArray *escape = @[@{@"uid": @"", @"name": @"Ming", @"folder": @"SaveData"}, @{@"uid": hong, @"name": @"Hong", @"folder": @"../x"}];
            struct { NSString *what; NSArray *list; NSString *current; const char *preset; NSString *want; } cases[] = {
                {@"ⓐ 没建过玩家", nil, nil, NULL, @"玩家=未设 名字=未设 存档位置=SaveData"},
                {@"ⓑ 第一个玩家", table, @"", NULL, @"玩家=first 名字=未设 存档位置=SaveData"},
                {@"ⓒ 第二个玩家", table, hong, NULL, [NSString stringWithFormat:@"玩家=%@ 名字=Hong 存档位置=SaveData-Hong", hong]},
                {@"ⓓ 当前不在表里", table, @"ffffffffffffffffffffffffffffffff", NULL, @"玩家=first 名字=未设 存档位置=SaveData"},
                {@"ⓔ 文件夹名跳出文档根", escape, hong, NULL, [NSString stringWithFormat:@"玩家=%@ 名字=Hong 存档位置=SaveData-%@", hong, hong]},
                {@"ⓔ' 改过名的第一个玩家", escape, @"", NULL, @"玩家=first 名字=Ming 存档位置=SaveData"},
                {@"ⓕ 启动环境显式给的优先（整个不套游戏库的）", table, hong, "first", @"玩家=first 名字=未设 存档位置=SaveData"},
            };
            for (size_t k = 0; k < sizeof cases / sizeof cases[0]; k++) {
                unsetenv("S2A_SAVE_FOLDER"); unsetenv("S2A_PLAYER_USER"); unsetenv("S2A_PLAYER_NAME");
                if (cases[k].preset) setenv("S2A_PLAYER_USER", cases[k].preset, 1);
                if (cases[k].list) [std setObject:cases[k].list forKey:@"S2ALocalPlayers"]; else [std removeObjectForKey:@"S2ALocalPlayers"];
                if (cases[k].current) [std setObject:cases[k].current forKey:@"S2ALocalPlayer"]; else [std removeObjectForKey:@"S2ALocalPlayer"];
                s2a_ios_load_graphics_settings();
                const char *u = getenv("S2A_PLAYER_USER"), *n = getenv("S2A_PLAYER_NAME"), *f = getenv("S2A_SAVE_FOLDER");
                NSString *folder = f ? @(f) : @"未设";
                if ([folder hasPrefix:[docs stringByAppendingString:@"/"]]) folder = [folder substringFromIndex:docs.length + 1];
                NSString *got = [NSString stringWithFormat:@"玩家=%@ 名字=%@ 存档位置=%@", u ? @(u) : @"未设", n ? @(n) : @"未设", folder];
                check([got isEqual:cases[k].want], [NSString stringWithFormat:@"本地玩家%@：期望 %@ → 真结果 %@", cases[k].what, cases[k].want, got]);
            }
            [std removeObjectForKey:@"S2ALocalPlayers"]; [std removeObjectForKey:@"S2ALocalPlayer"];
            unsetenv("S2A_SAVE_FOLDER"); unsetenv("S2A_PLAYER_USER"); unsetenv("S2A_PLAYER_NAME"); unsetenv("S2A_DOCS");
            clear_environment();
        }
        // 画面设置按游戏存（11-11）：多款容器选了游戏后 s2a_ios_settings_defaults 是分层的——画面键读「这款 → 所有游戏的默认（App 级）」、
        //   写只写这款；非画面键原样走 App 级；没有游戏号就是 App 级本身。一次性迁移清掉 App 级里自动写下的「宽屏关 + 问过」与原生 60 帧记号，
        //   玩家自己选的留作默认。期望按这条规则手写
        {   clear_environment(); unsetenv("S2A_LAUNCH_GAME_ID");
            NSUserDefaults *app = NSUserDefaults.standardUserDefaults;
            check(s2a_ios_settings_defaults() == app, @"按游戏：没有游戏号就是 App 级本身（单款壳行为不变）");
            NSString *gid = [@"01000000000" stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:5]];
            NSUserDefaults *game = [[NSUserDefaults alloc] initWithSuiteName:[@"S2AGame." stringByAppendingString:gid]];
            for (NSString *k in s2a_ios_per_game_keys()) [app removeObjectForKey:k];
            [app removeObjectForKey:@"S2APerGameMigrated1111"];
            [app setBool:NO forKey:@"S2AWidescreen"]; [app setBool:YES forKey:@"S2AWidescreenAsked"];   // 某一款自动退回写下的
            [app setBool:YES forKey:@"S2AFpsNative60"];
            [app setObject:@"2" forKey:@"S2AResolutionScale"];                                          // 玩家自己选的
            [app setBool:NO forKey:@"S2AFps60"];                                                         // 玩家自己关的（没有问过记号）
            setenv("S2A_LAUNCH_GAME_ID", gid.UTF8String, 1);
            NSUserDefaults *d = s2a_ios_settings_defaults();
            s2a_ios_apply_graphics_settings(d);
            check(![app objectForKey:@"S2AWidescreen"] && ![app objectForKey:@"S2AWidescreenAsked"] && ![app objectForKey:@"S2AFpsNative60"] && [app boolForKey:@"S2APerGameMigrated1111"],
                  @"按游戏：迁移清掉 App 级里自动写下的宽屏关 + 问过、原生 60 帧记号");
            check(getenv("S2A_WIDESCREEN") == NULL, @"按游戏：自动退回的宽屏关不再串到别的游戏");
            check(getenv("S2A_RES_SCALE") && !strcmp(getenv("S2A_RES_SCALE"), "2"), @"按游戏：玩家自己选的分辨率留作所有游戏的默认");
            check(getenv("S2A_FPS60") && !strcmp(getenv("S2A_FPS60"), "0"), @"按游戏：这款没设 60 帧 → 用所有游戏的默认（关）");
            clear_environment(); [game setBool:YES forKey:@"S2AFps60"];
            s2a_ios_apply_graphics_settings(d);
            check(getenv("S2A_FPS60") && !strcmp(getenv("S2A_FPS60"), "1"), @"按游戏：这款开 60 帧压过所有游戏的默认（关）——原先压不过；新约定下明确开写 1（宿主只把 1 当开）");
            [d setBool:NO forKey:@"S2AWidescreen"];
            check([game objectForKey:@"S2AWidescreen"] && ![game boolForKey:@"S2AWidescreen"] && ![app objectForKey:@"S2AWidescreen"], @"按游戏：设置页写宽屏只写这款，App 级不变");
            [d setBool:YES forKey:@"S2ADevHUD"];
            check([app boolForKey:@"S2ADevHUD"] && ![game objectForKey:@"S2ADevHUD"], @"按游戏：非画面键（开发浮层）照旧写 App 级");
            check([[d stringForKey:@"S2AResolutionScale"] isEqual:@"2"] && [d boolForKey:@"S2AFps60"], @"按游戏：读这款有的、没有回落默认");
            for (NSString *k in s2a_ios_per_game_keys()) [app removeObjectForKey:k];
            [app removeObjectForKey:@"S2ADevHUD"]; [app removeObjectForKey:@"S2APerGameMigrated1111"];
            [game removePersistentDomainForName:[@"S2AGame." stringByAppendingString:gid]];
            unsetenv("S2A_LAUNCH_GAME_ID"); clear_environment();
        }
        clear_environment();
        [a removePersistentDomainForName:suiteA];
        [b removePersistentDomainForName:suiteB];
        printf("%s t_ios_settings：%d 项检查，%d 项失败\n", failures ? "✗" : "✓", checks, failures);
        return failures ? 1 : 0;
    }
}
