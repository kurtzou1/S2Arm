#import <Foundation/Foundation.h>
#import "settings.h"
#import "s2a_l10n.h"
#include "caps.h"
#include "s2a_launch_ctx.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 能力清单 s2a_caps.tsv 所在：启动上下文的 caps_dir（单款兼容 = 可执行文件目录 = App 包顶层，同改造前的 bundlePath）；上下文不可用时宿主 main 开头已停，这里退回包顶层
static NSString *caps_dir(void) {
    const s2a_launch_ctx *lc = s2a_launch_ctx_get();
    return lc ? @(lc->caps_dir) : NSBundle.mainBundle.bundlePath;
}

// Only lifecycle startup writes these values; the session coordinator serializes
// reload after all old guests have stopped. UI changes NSUserDefaults directly.
static NSMutableDictionary<NSString *, NSString *> *settings_environment;
static void apply_environment(const char *name, NSString *value) {
    if (setenv(name, value.UTF8String, 0) != 0)
        [NSException raise:NSInternalInconsistencyException format:@"读取画面设置 %s 失败：%s", name, strerror(errno)];
    if (!settings_environment) settings_environment = [NSMutableDictionary new];
    settings_environment[@(name)] = value;
}

// 浮层偏好要在建视图之前落到环境变量：多款容器与单款都是先建视图（app.m prepareGameView → s2a_hud_attach），
// host_run 里才调 s2a_ios_apply_graphics_settings；晚读会让 s2a_hud_on() 把还没设的 S2A_HUD 缓存成 0（#153）。
// 启动环境显式给的优先；开关语义仍是「下次启动生效」。
// Metal 性能浮层的系统键（11-13 维护者实机：iPad mini / iPadOS 27.2 上 Metal 框架初始化时读 MetalForceHudEnabled，只多存这个键 = 冷启动出面板，
//   删掉就没有；我们的开关键 MetalHUDForceEnabled（Settings.bundle / 设置页）它不认，MTL_HUD_ENABLED 是进程起来后才设、对系统建设备太晚）。
//   开关打开就往 App 自己的偏好里写系统键、关掉就删（两种拼法都在：我们的键作界面状态照旧），下次冷启动 Metal 读到。只在值不同时写，免得自己触发变更通知再写
static void metal_hud_mirror(NSUserDefaults *d) {
    BOOL on = [d boolForKey:@"MetalHUDForceEnabled"];
    if (on && ![d boolForKey:@"MetalForceHudEnabled"]) { [d setBool:YES forKey:@"MetalForceHudEnabled"]; fprintf(stderr, "[S2A 画面设置] Metal 性能浮层：写系统键 MetalForceHudEnabled（下次冷启动生效）\n"); }
    else if (!on && [d objectForKey:@"MetalForceHudEnabled"]) { [d removeObjectForKey:@"MetalForceHudEnabled"]; fprintf(stderr, "[S2A 画面设置] Metal 性能浮层：删系统键 MetalForceHudEnabled（下次冷启动生效）\n"); }
}
void s2a_ios_apply_overlay_settings(NSUserDefaults *defaults) {
    metal_hud_mirror(defaults);
    { static id obs; if (!obs) obs = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
          usingBlock:^(NSNotification *n) { (void)n; metal_hud_mirror(NSUserDefaults.standardUserDefaults); }]; }   // App 设置页 / 系统「设置」里切开关时跟着改
    if (!getenv("S2A_HUD") && [defaults boolForKey:@"S2ADevHUD"]) {
        apply_environment("S2A_HUD", @"1");
        fprintf(stderr, "[S2A 画面设置] S2A_HUD=1（本 App 设置：开发浮层）\n");
    }
    if (!getenv("MTL_HUD_ENABLED") && [defaults boolForKey:@"MetalHUDForceEnabled"]) {
        apply_environment("MTL_HUD_ENABLED", @"1");
        fprintf(stderr, "[S2A 画面设置] MTL_HUD_ENABLED=1（本 App 设置：Metal 性能浮层）\n");
    }
}

// ---------- 按游戏分层的设置（见 settings.h s2a_ios_settings_defaults） ----------
// 画面类、会因游戏而异的键：分辨率 / 抗锯齿 / 缩放滤镜 / 帧率上限 / 宽屏 / 60 帧（含手动开）/ 主机模式 / 社区补丁，
//   以及撑不住就问玩家的「问过」与「本款原生 60 帧」记号——原先全在 App 级，一款游戏自动退回 16:9、关 60 帧会串到所有游戏
NSArray *s2a_ios_per_game_keys(void) {
    return @[@"S2AResolutionScale", @"S2AAntiAliasing", @"S2AScalingFilter", @"S2AFrameRateLimit", @"S2AWidescreen", @"S2AFps60",
             @"S2AFps60Manual", @"S2ADockedMode", @"S2ACommunityPatches", @"S2AWidescreenAsked", @"S2AFps60Asked", @"S2AFpsNative60", @"S2AWidenForce", S2AGameLanguageKey];
}
NSArray<NSString *> *s2a_ios_game_languages(void) {
    return @[@"system", @"SimplifiedChinese", @"TraditionalChinese", @"AmericanEnglish", @"BritishEnglish", @"Japanese", @"Korean", @"French", @"CanadianFrench", @"German",
             @"Spanish", @"LatinAmericanSpanish", @"Italian", @"Dutch", @"Portuguese", @"BrazilianPortuguese", @"Russian", @"Polish", @"Thai"];
}
@interface S2AGameLayeredDefaults : NSUserDefaults
- (instancetype)initWithGame:(NSUserDefaults *)game app:(NSUserDefaults *)app keys:(NSSet<NSString *> *)keys;
@end
@implementation S2AGameLayeredDefaults {
    NSUserDefaults *_game, *_app; NSSet<NSString *> *_keys;
}
- (instancetype)initWithGame:(NSUserDefaults *)game app:(NSUserDefaults *)app keys:(NSSet<NSString *> *)keys {
    if ((self = [super initWithSuiteName:nil])) { _game = game; _app = app; _keys = [keys copy]; }
    return self;
}
- (NSUserDefaults *)writerFor:(NSString *)key { return [_keys containsObject:key] ? _game : _app; }
- (id)objectForKey:(NSString *)key { return ([_keys containsObject:key] ? [_game objectForKey:key] : nil) ?: [_app objectForKey:key]; }
- (void)setObject:(id)value forKey:(NSString *)key { [[self writerFor:key] setObject:value forKey:key]; }
- (void)removeObjectForKey:(NSString *)key { [[self writerFor:key] removeObjectForKey:key]; }
- (BOOL)boolForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(boolValue)] && [v boolValue]; }
- (NSInteger)integerForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0; }
- (float)floatForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 0; }
- (double)doubleForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }
- (NSString *)stringForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSNumber.class] ? [v stringValue] : nil; }
- (NSArray *)arrayForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:NSArray.class] ? v : nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:NSDictionary.class] ? v : nil; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setFloat:(float)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
@end
NSUserDefaults *s2a_ios_settings_defaults(void) {
    const char *gid = getenv("S2A_LAUNCH_GAME_ID");
    if (!gid || !*gid) return NSUserDefaults.standardUserDefaults;
    static NSString *cachedID; static NSUserDefaults *cached;   // 进程内同一款反复取（设置页每行都取）：复用一个对象
    @synchronized(NSUserDefaults.class) {
        if (!cached || ![cachedID isEqualToString:@(gid)]) {
            cachedID = @(gid);
            cached = [[S2AGameLayeredDefaults alloc] initWithGame:[[NSUserDefaults alloc] initWithSuiteName:[@"S2AGame." stringByAppendingString:cachedID]]
                                                              app:NSUserDefaults.standardUserDefaults keys:[NSSet setWithArray:s2a_ios_per_game_keys()]];
        }
        return cached;
    }
}

// 包内能力清单（App 包顶层 s2a_caps.tsv，runtime/src/caps.c 同一份）里某项能力（fps60 / widen）的值：1 / 0；没有清单或没有这行 = -1。每次现读（设置页与起局都调，文件很小）
int s2a_ios_caps_value(const char *cap) {
    NSString *text = [NSString stringWithContentsOfFile:[caps_dir() stringByAppendingPathComponent:@"s2a_caps.tsv"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *f = [[line componentsSeparatedByString:@"#"].firstObject componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        f = [f filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (f.count >= 2 && [f[0] isEqual:@(cap)]) return [f[1] isEqual:@"1"] ? 1 : [f[1] isEqual:@"0"] ? 0 : -1;
    }
    return -1;
}

NSArray<NSDictionary *> *s2a_ios_graphics_options(void) {
    return @[
        @{@"key": @"S2AResolutionScale", @"title": S2AL(@"gfx.resolution"), @"initial": @"1",
          @"values": @[@"0.5", @"0.75", @"1", @"1.5", @"2"], @"labels": @[@"0.5×", @"0.75×", @"1×", @"1.5×", @"2×"]},
        @{@"key": @"S2AAntiAliasing", @"title": S2AL(@"gfx.antiAliasing"), @"initial": @"None",
          @"values": @[@"None", @"SmaaMedium", @"SmaaHigh"], @"labels": @[S2AL(@"gfx.antiAliasing.off"), S2AL(@"gfx.antiAliasing.medium"), S2AL(@"gfx.antiAliasing.high")]},
        @{@"key": @"S2AScalingFilter", @"title": S2AL(@"gfx.filter"), @"initial": @"Bilinear",
          @"values": @[@"Bilinear", @"Nearest"], @"labels": @[S2AL(@"gfx.filter.bilinear"), S2AL(@"gfx.filter.nearest")]},
        @{@"key": @"S2AFrameRateLimit", @"title": S2AL(@"gfx.fpsLimit"), @"initial": @"0",
          @"values": @[@"30", @"60", @"120", @"0"], @"labels": @[@"30", @"60", @"120", S2AL(@"gfx.fpsLimit.none")]}
    ];
}

NSInteger s2a_ios_settings_docked_change(NSDictionary *entry, NSDictionary *now, BOOL *restart) {
    NSMutableDictionary *a = [entry mutableCopy] ?: [NSMutableDictionary new], *b = [now mutableCopy] ?: [NSMutableDictionary new];
    NSNumber *was = a[@"S2ADockedMode"], *is = b[@"S2ADockedMode"];
    [a removeObjectForKey:@"S2ADockedMode"]; [b removeObjectForKey:@"S2ADockedMode"];
    if (restart) *restart = ![a isEqual:b];
    return [was boolValue] == [is boolValue] ? -1 : [is boolValue] ? 1 : 0;
}
NSDictionary *s2a_ios_graphics_snapshot(NSUserDefaults *defaults) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (NSDictionary *option in s2a_ios_graphics_options()) {
        id value = [defaults objectForKey:option[@"key"]];
        snapshot[option[@"key"]] = [option[@"values"] containsObject:value ?: NSNull.null] ? value : option[@"initial"];
    }
    for (NSString *key in @[@"S2AWidescreen", @"S2AFps60"])
        snapshot[key] = [defaults objectForKey:key] ? @([defaults boolForKey:key]) : @YES;
    snapshot[@"S2AFps60Manual"] = @([defaults boolForKey:@"S2AFps60Manual"]);
    snapshot[@"S2ADockedMode"] = @([defaults boolForKey:@"S2ADockedMode"]);
    return snapshot;
}

void s2a_ios_apply_graphics_settings(NSUserDefaults *defaults) {
    // 字符串与 Settings.bundle 一致。起局工具显式给出的环境变量优先。
    const struct {
        __unsafe_unretained NSString *key;
        const char *env;
        __unsafe_unretained NSString *initial;
        __unsafe_unretained NSArray<NSString *> *values;
    } options[] = {
        {@"S2AResolutionScale", "S2A_RES_SCALE", @"1", @[@"0.5", @"0.75", @"1", @"1.5", @"2"]},
        {@"S2AAntiAliasing", "S2A_ANTI_ALIASING", @"None", @[@"None", @"SmaaMedium", @"SmaaHigh"]},   // 不带 FXAA（10-30：NVIDIA FXAA 3.11 没有授权条款）；存过的 Fxaa 按无效值清除
        {@"S2AScalingFilter", "S2A_SCALING_FILTER", @"Bilinear", @[@"Bilinear", @"Nearest"]},
        {@"S2AFrameRateLimit", "S2A_FPS", @"0", @[@"30", @"60", @"120", @"0"]},
    };

    for (size_t i = 0; i < sizeof options / sizeof options[0]; i++) {
        const char *explicit = getenv(options[i].env);
        if (explicit) {
            fprintf(stderr, "[S2A 画面设置] %s=%s（启动环境）\n", options[i].env, explicit);
            continue;
        }
        id value = [defaults objectForKey:options[i].key] ?: options[i].initial;
        if (![value isKindOfClass:NSString.class] || ![options[i].values containsObject:value]) {
            fprintf(stderr, "[S2A 画面设置] 【红】%s=%s 无效，清除保存值并使用默认值 %s\n",
                options[i].key.UTF8String, [[value description] UTF8String], options[i].initial.UTF8String);
            [defaults removeObjectForKey:options[i].key];
            value = options[i].initial;
        }
        apply_environment(options[i].env, value);
        fprintf(stderr, "[S2A 画面设置] %s=%s（本 App 设置）\n", options[i].env, [value UTF8String]);
    }
    // Switch 档位：与服务层 Host.Docked、直连 dm_opmode 和宽屏表共用；缺省掌机，下次启动生效。
    const char *docked = getenv("S2A_DOCKED");
    if (docked) fprintf(stderr, "[S2A 画面设置] S2A_DOCKED=%s（启动环境）\n", docked);
    else {
        docked = [defaults boolForKey:@"S2ADockedMode"] ? "1" : "0";
        apply_environment("S2A_DOCKED", @(docked));
        fprintf(stderr, "[S2A 画面设置] S2A_DOCKED=%s（本 App 设置）\n", docked);
    }
    // 游戏语言（按款，11-13）：选了哪种就交宿主枚举名给 S2A_SYSTEM_LANGUAGE（Host.cs PickLanguage 优先用它）；跟随系统不设，服务层读本 App 首选语言。
    //   游戏按语言整套换字体，从 Switch 导入的存档里玩家起的名字要和当时 Switch 的语言对上才显示得出来
    const char *gameLanguage = getenv("S2A_SYSTEM_LANGUAGE");
    if (gameLanguage) fprintf(stderr, "[S2A 画面设置] S2A_SYSTEM_LANGUAGE=%s（启动环境）\n", gameLanguage);
    else {
        NSString *v = [defaults stringForKey:S2AGameLanguageKey];
        if (v && ![s2a_ios_game_languages() containsObject:v]) {
            fprintf(stderr, "[S2A 画面设置] 【红】%s=%s 无效，清除保存值、跟随系统\n", S2AGameLanguageKey.UTF8String, v.UTF8String);
            [defaults removeObjectForKey:S2AGameLanguageKey];
        } else if (v && ![v isEqualToString:@"system"]) {
            apply_environment("S2A_SYSTEM_LANGUAGE", v);
            fprintf(stderr, "[S2A 画面设置] S2A_SYSTEM_LANGUAGE=%s（本款设置）\n", v.UTF8String);
        }
    }
    // 按游戏的设置（11-07 维护者：游戏库里按住游戏 / 点设置，60 帧、宽屏强制启用点一下就切）：多款容器选了游戏后 S2A_LAUNCH_GAME_ID 有值，
    //   游戏库把这款的选择写在独立偏好 S2AGame.<游戏号>（shell S2ArmShellHost）；排在 App 级设置前面（两边都只在环境变量未设时写，先写的赢）。
    //   单款壳没有游戏号，不走这段
    const char *gid = getenv("S2A_LAUNCH_GAME_ID");
    NSUserDefaults *game = gid && *gid ? [[NSUserDefaults alloc] initWithSuiteName:[@"S2AGame." stringByAppendingString:@(gid)]] : nil;
    if (game) {
        // 60 帧不在这里单独读：defaults 是按游戏分层的（s2a_ios_settings_defaults），下面 60 帧那段读到的就是「这款 → 所有游戏的默认」。
        //   原先这里只在这款「关」时写，这款「开」压不过 App 级的「关」（11-11 宿主梳理：库里按款开 60 帧不生效）
        // 宽屏强制启用 = 这款按已验证开满屏（没进宽屏已验证名单也开），并压过 App 级的宽屏关；满屏自检照样兜底（拉伸 / 收窄连续两窗自动退回）
    }
    // 宽屏强制启用也认游戏里设置页写的（11-13 维护者「不许堵门」：包里满屏标了已知问题，设置页原先锁灰不让开；现在提示后照开，记同一个键）。
    //   按游戏分层：这款 → 所有游戏的默认；单款壳没有游戏号，就是 App 级
    if ([s2a_ios_settings_defaults() boolForKey:@"S2AWidenForce"]) {
        if (!getenv("S2A_WIDEN_VERIFIED")) apply_environment("S2A_WIDEN_VERIFIED", @"1");
        if (!getenv("S2A_WIDESCREEN")) apply_environment("S2A_WIDESCREEN", @"1");
        fprintf(stderr, "[S2A 画面设置] 宽屏强制启用（%s）\n", game && [game objectForKey:@"S2AWidenForce"] ? "这款" : "所有游戏的默认");
    }
    // 宽屏（runtime/src/widen.c widen_setting_on）：设置关了 = S2A_WIDESCREEN=0，下次启动整局 16:9；没设过 / 开着不设（缺省开）；启动环境显式给的优先
    // 一次性清记忆（11-06 满屏自检改「两次启动都触发才记住」）：之前单次触发就写下的「宽屏关 + 问过」清掉，下次起局重新试满屏、重新自检。
    //   只清一次（S2AWidenAutoMigrated1106）；之后玩家在设置页自己关的照常记住
    //   清的是 App 级的旧值：明确读写 App 级，不走按游戏分层
    NSUserDefaults *app = NSUserDefaults.standardUserDefaults;
    if (![app boolForKey:@"S2AWidenAutoMigrated1106"]) {
        if ([app boolForKey:@"S2AWidescreenAsked"] && [app objectForKey:@"S2AWidescreen"] && ![app boolForKey:@"S2AWidescreen"]) {
            [app removeObjectForKey:@"S2AWidescreen"]; [app removeObjectForKey:@"S2AWidescreenAsked"];
            fprintf(stderr, "[S2A 画面设置] 满屏自检旧记忆已清：本款下次起局重新试满屏\n");
        }
        [app setBool:YES forKey:@"S2AWidenAutoMigrated1106"];
    }
    // 画面设置改按游戏存（11-11）的一次性迁移，只在多款容器里做：App 级里玩家自己选的值原样留作「所有游戏的默认」；
    //   撑不住就问玩家 / 满屏自检在某一款上自动写下的那一对（宽屏关 + 问过、60 帧关 + 问过）和「本款原生 60 帧」记号是那一款的事，
    //   留在 App 级会继续串到所有游戏，清掉，每款下次起局各自重新判（与 11-06 那次同一判法：带「问过」的关 = 自动写的）
    if (game && ![app boolForKey:@"S2APerGameMigrated1111"]) {
        if ([app boolForKey:@"S2AWidescreenAsked"]) {
            if ([app objectForKey:@"S2AWidescreen"] && ![app boolForKey:@"S2AWidescreen"]) [app removeObjectForKey:@"S2AWidescreen"];
            [app removeObjectForKey:@"S2AWidescreenAsked"];
        }
        if ([app boolForKey:@"S2AFps60Asked"]) {
            if ([app objectForKey:@"S2AFps60"] && ![app boolForKey:@"S2AFps60"]) [app removeObjectForKey:@"S2AFps60"];
            [app removeObjectForKey:@"S2AFps60Asked"];
        }
        [app removeObjectForKey:@"S2AFpsNative60"];
        [app setBool:YES forKey:@"S2APerGameMigrated1111"];
        fprintf(stderr, "[S2A 画面设置] 画面设置改按游戏存：自动写下的宽屏 / 60 帧记号已从「所有游戏的默认」里清掉，玩家自己选的保留\n");
    }
    if (!getenv("S2A_WIDESCREEN") && [defaults objectForKey:@"S2AWidescreen"] && ![defaults boolForKey:@"S2AWidescreen"]) {
        apply_environment("S2A_WIDESCREEN", @"0");
        fprintf(stderr, "[S2A 画面设置] S2A_WIDESCREEN=0（宽屏关：%s）\n", game && [game objectForKey:@"S2AWidescreen"] ? "这款" : "所有游戏的默认");
    }
    // 60 帧（11-11 维护者：缺省游戏原帧率、玩家手动开；速度已验证正确的款保留默认 60）：只转玩家明确的选择——开 S2A_FPS60=1、关 S2A_FPS60=0；
    //   没选过不写，由宿主按清单原因自己定（runtime/src/caps.c：验证过的款开、其余原帧率）。没选也写 0 会把验证过的款一起关掉。
    //   先后：启动环境显式给的 > 这款在游戏库的选择 > App 级开关关 > 玩家在设置页手动开（S2AFps60Manual，只有设置页开关会写）；
    //   与 Mac 启动器（pack/jobs/community.py launch_env）同口径。按款的游戏库键开 / 关都认；App 级老键只认关（见下）
    if (!getenv("S2A_FPS60")) {
        NSString *pick = nil;
        if (game && [game objectForKey:@"S2AFps60"]) pick = [game boolForKey:@"S2AFps60"] ? @"1" : @"0";
        // App 级老键 S2AFps60：老口径缺省开，存着 YES 只代表「沿用缺省」，不算玩家明确开（不然强信号判红、已知会变速的款也被开成 60 帧）；只认 NO = 关
        else if ([defaults objectForKey:@"S2AFps60"] && ![defaults boolForKey:@"S2AFps60"]) pick = @"0";
        // 玩家明确开：设置页 60 帧开关打开时都会写 S2AFps60Manual（强信号款看过提示后开、普通款直接开），与老键是不是 YES 无关
        else if ([defaults boolForKey:@"S2AFps60Manual"]) pick = @"1";
        if (pick) {
            apply_environment("S2A_FPS60", pick);
            fprintf(stderr, "[S2A 画面设置] S2A_FPS60=%s（玩家选了 60 帧%s）\n", pick.UTF8String, [pick isEqualToString:@"1"] ? "开" : "关");
        }
    }
    // 开发浮层 / Metal 性能浮层：建视图之前 app.m prepareGameView 已先调 s2a_ios_apply_overlay_settings 落环境变量，
    //   这里再调一次兜底（host_run 起局、建 Metal 设备之前）；启动环境显式给的优先（#153）。
    s2a_ios_apply_overlay_settings(defaults);
    // 社区补丁（runtime/src/cpatch.c）：设置里开着的补丁编号 S2ACommunityPatches（字符串数组或逗号分隔串）→ S2A_CPATCH_ON；没设过不设（按包里表的缺省开），
    //   空数组 = 全关（none）；启动环境显式给的优先。下次启动生效
    if (!getenv("S2A_CPATCH_ON")) {
        id v = [defaults objectForKey:@"S2ACommunityPatches"];
        NSString *on = [v isKindOfClass:NSArray.class] ? ([(NSArray *)v count] ? [(NSArray *)v componentsJoinedByString:@","] : @"none") : [v isKindOfClass:NSString.class] ? v : nil;
        if (on) { apply_environment("S2A_CPATCH_ON", on); fprintf(stderr, "[S2A 画面设置] S2A_CPATCH_ON=%s（本 App 设置：社区补丁）\n", on.UTF8String); }
    }
}

void s2a_ios_reapply_graphics_settings(NSUserDefaults *defaults) {
    NSDictionary<NSString *, NSString *> *owned = [settings_environment copy];
    for (NSString *name in owned) {
        const char *current = getenv(name.UTF8String);
        if (current && !strcmp(current, owned[name].UTF8String) && unsetenv(name.UTF8String) != 0)
            [NSException raise:NSInternalInconsistencyException format:@"重读画面设置 %@ 失败：%s", name, strerror(errno)];
    }
    [settings_environment removeAllObjects];
    s2a_ios_apply_graphics_settings(defaults);
}

// 开发设施开关（runtime/src/os.c s2a_dev_on 按名字取）：包内 Info.plist 的 S2ADevFacilities（玩家包 pack/ipa_tail.py 写 "0"）。有这个键回 1、*on = 不以 "0" 开头
int s2a_dev_plist_from(NSDictionary *info, int *on) {
    id v = info[@"S2ADevFacilities"];
    if (![v isKindOfClass:NSString.class] || ![(NSString *)v length]) return 0;
    *on = ![(NSString *)v hasPrefix:@"0"]; return 1;
}
__attribute__((visibility("default"))) int s2a_dev_plist(int *on) { @autoreleasepool { return s2a_dev_plist_from(NSBundle.mainBundle.infoDictionary, on); } }

// 设置页「关于本包」只读三行（#377 F09）：画面模式、直连库版本、出包时间。数据全部来自包内 Info.plist —— 出包时写进去，
// 这里只负责把英文键名换成当前语言的展示串（#316，S2ArmHost.strings）；缺字段不猜，直接显示「未知」，免得把「没出直连库」显示成「直连成功」。
void s2a_ios_publish_bundle_info(NSDictionary *info, NSUserDefaults *defaults) {
    NSString *mode = [info[@"S2AGraphicsMode"] isKindOfClass:NSString.class] ? info[@"S2AGraphicsMode"] : nil;
    NSString *lib = [info[@"S2ADirectLibVersion"] isKindOfClass:NSString.class] ? info[@"S2ADirectLibVersion"] : nil;
    NSString *packed = [info[@"S2APackTime"] isKindOfClass:NSString.class] ? info[@"S2APackTime"] : nil;
    NSString *build = [info[@"S2ABuildID"] isKindOfClass:NSString.class] ? info[@"S2ABuildID"] : nil;

    NSString *text;
    if ([mode isEqual:@"direct"]) text = S2AL(@"about.mode.direct");   // 包只出直连（11-07 拆掉通用模式）；与 Mac 启动器同一句，不是 direct 一律未知
    else text = S2AL(@"about.mode.unrecorded");

    [defaults setObject:text forKey:@"S2AGraphicsModeText"];
    [defaults setObject:(lib.length ? lib : S2AL(@"about.directLib.none")) forKey:@"S2ADirectLibVersionText"];
    [defaults setObject:(packed.length ? packed : S2AL(@"about.unknown")) forKey:@"S2APackTimeText"];
    [defaults setObject:(build.length ? build : S2AL(@"about.unknown")) forKey:@"S2ABuildIDText"];
}

float s2a_ios_res_scale(NSUserDefaults *defaults) {
    const char *e = getenv("S2A_RES_SCALE");
    float v = e && *e ? (float)atof(e) : 0;
    if (v >= 0.25f && v <= 4.0f) return v;
    id d = [defaults objectForKey:@"S2AResolutionScale"];
    v = [d isKindOfClass:NSString.class] ? (float)[d doubleValue] : 1.0f;
    return v >= 0.25f && v <= 4.0f ? v : 1.0f;
}

// 诊断局（#438，设置「诊断」组的开关 S2ADiagRunNext）：只管下一局。起局时读到开着就设上逐通道读数的环境变量、立刻关掉开关；
//   读数写本款文档根下的 diagrun/（出图 PNG 与颜色目标 PNG；逐通道记录 [pass] 行走 stderr → host.log），导出诊断包时带上（diag.m）。
//   帧号：第 3600 / 7200 次出图（60 帧游戏约 1 / 2 分钟）。这些是重探针、会拖慢帧率，所以只开一局。启动环境显式给的优先
//   帧内快照到第 60 个渲染 pass（延迟光照这类合成 pass 常在 30 以后）；整数格式的目标按整数值出图，这一帧采样到的 3D 纹理逐层拼成一张图（RGB / alpha 各一张）
void s2a_ios_apply_diag_run(NSUserDefaults *defaults) {
    if (![defaults boolForKey:@"S2ADiagRunNext"]) return;
    [defaults setBool:NO forKey:@"S2ADiagRunNext"];
    const char *d = getenv("S2A_DOCS");
    NSString *docs = d && *d ? @(d) : NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"diagrun"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:dir error:nil];   // 上一次诊断局的图不混进来
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) {
        fprintf(stderr, "【红】[S2A 诊断局] 建 diagrun 目录失败，这一局不开探针\n"); return;
    }
    NSString *td = [NSString stringWithFormat:@"3600,7200:%@/td_%%d.png", dir], *shot = [NSString stringWithFormat:@"3600,7200:%@/shot_%%d.png", dir];
    struct { const char *name; NSString *value; } vars[] = {
        {"DM_NVN_PASSDUMP", @"3600-3601"}, {"DM_NVN_TEXDUMP", td}, {"DM_NVN_TEXSNAP", @"0,5,10,15,20,25,30,35,40,45,50,55,60"}, {"DM_NVN_SHOT", shot}};
    for (size_t i = 0; i < sizeof vars / sizeof vars[0]; i++)
        if (!getenv(vars[i].name)) setenv(vars[i].name, vars[i].value.UTF8String, 1);
    fprintf(stderr, "[S2A 诊断局] 本局开逐通道读数（第 3600 / 7200 次出图），读数写 %s，下一局自动关\n", dir.fileSystemRepresentation);
}

// 本地玩家（#623，维护者 11-11）：游戏库（shell/Sources/S2ArmShellHost/LocalPlayers.swift）把玩家表写在 App 偏好 S2ALocalPlayers
//   （数组，每项 {uid, name, folder}；第一项 uid 空串 = 第一个玩家）、当前玩家的 uid 写在 S2ALocalPlayer。按本机存，不在游戏数据目录里，删游戏不丢。
//   这里只读、校验：表里没有当前那个 / 字段不对 → 第一个玩家；文件夹名只认一层、不以 . 开头、不含 /（防拼出本款文档根以外的路径），不对就按用户号起名
static BOOL player_folder_ok(id v) {
    if (![v isKindOfClass:NSString.class]) return NO;
    NSString *s = v;
    return s.length > 0 && s.length <= 120 && ![s hasPrefix:@"."] && [s rangeOfString:@"/"].location == NSNotFound && [s rangeOfString:@":"].location == NSNotFound;
}
static BOOL player_uid_ok(NSString *uid) {
    if (uid.length != 32) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [uid rangeOfCharacterFromSet:bad].location == NSNotFound && ![uid isEqualToString:[@"" stringByPaddingToLength:32 withString:@"0" startingAtIndex:0]];
}
NSDictionary<NSString *, NSString *> *s2a_ios_local_player(NSUserDefaults *defaults) {
    id list = [defaults objectForKey:@"S2ALocalPlayers"];
    if (![list isKindOfClass:NSArray.class] || ![(NSArray *)list count]) return nil;
    NSString *want = [defaults stringForKey:@"S2ALocalPlayer"] ?: @"";
    NSDictionary *hit = nil;
    for (id p in (NSArray *)list) {
        if (![p isKindOfClass:NSDictionary.class] || ![p[@"uid"] isKindOfClass:NSString.class]) continue;
        if (want.length && [p[@"uid"] isEqualToString:want] && player_uid_ok(want)) { hit = p; break; }
    }
    NSString *name = @"";
    if (!hit) {   // 第一个玩家：表里 uid 空串那项的名字
        for (id p in (NSArray *)list)
            if ([p isKindOfClass:NSDictionary.class] && [p[@"uid"] isEqual:@""] && [p[@"name"] isKindOfClass:NSString.class]) { name = p[@"name"]; break; }
        return @{@"uid": @"", @"name": name, @"folder": @"SaveData"};
    }
    if ([hit[@"name"] isKindOfClass:NSString.class]) name = hit[@"name"];
    NSString *folder = player_folder_ok(hit[@"folder"]) && ![hit[@"folder"] isEqualToString:@"SaveData"] ? hit[@"folder"] : [@"SaveData-" stringByAppendingString:want];
    return @{@"uid": want, @"name": name, @"folder": folder};
}

void s2a_ios_load_graphics_settings(void) {
    @autoreleasepool {
        // 先套用户设置、再读包内能力清单（在 App 包顶层）：两边都只在环境变量未设时写，先写的赢 → 启动环境 > 用户设置 > 清单
        //   （审计 #854 F-caps-beats-settings：原先清单先写，设置里关 60 帧 / 宽屏不生效）
        s2a_ios_apply_graphics_settings(s2a_ios_settings_defaults());
        s2a_caps_apply(caps_dir().fileSystemRepresentation);
        s2a_ios_publish_bundle_info(NSBundle.mainBundle.infoDictionary ?: @{}, NSUserDefaults.standardUserDefaults);
        // 存档位置 SaveData（services/S2A.Services/SaveFolder.cs 读 S2A_SAVE_FOLDER，共享层不判平台）：本款文档根下的 SaveData。
        //   这里在服务层起来之前跑，多款容器选游戏后 S2A_DOCS 已是 Documents/games/<游戏号>（runtime/src/launchctx.c）；单款包没有 S2A_DOCS = Documents。启动环境显式给的优先
        //   本地玩家（#623）：每个玩家一个存档位置（第一个玩家仍是 SaveData），当前玩家给服务层（services/S2A.Services/LocalPlayer.cs 读
        //   S2A_PLAYER_USER = first / 用户号、S2A_PLAYER_NAME）；没建过玩家什么都不设（旧行为）。启动环境显式给了玩家就整个不套游戏库的（存档位置也不按它）
        NSDictionary<NSString *, NSString *> *player = getenv("S2A_PLAYER_USER") ? nil : s2a_ios_local_player(NSUserDefaults.standardUserDefaults);
        if (!getenv("S2A_SAVE_FOLDER")) {
            const char *d = getenv("S2A_DOCS");
            NSString *docs = d && *d ? @(d) : NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            setenv("S2A_SAVE_FOLDER", [docs stringByAppendingPathComponent:player ? player[@"folder"] : @"SaveData"].fileSystemRepresentation, 0);
        }
        if (player) {
            setenv("S2A_PLAYER_USER", player[@"uid"].length ? player[@"uid"].UTF8String : "first", 0);
            if (player[@"name"].length && !getenv("S2A_PLAYER_NAME")) setenv("S2A_PLAYER_NAME", player[@"name"].UTF8String, 0);
            fprintf(stderr, "[S2A 本地玩家] %s（%s），存档位置 %s\n", player[@"uid"].length ? player[@"uid"].UTF8String : "第一个玩家",
                    player[@"name"].length ? player[@"name"].UTF8String : "没改过名", getenv("S2A_SAVE_FOLDER"));
        }
        s2a_ios_apply_diag_run(NSUserDefaults.standardUserDefaults);
    }
}

int s2a_ios_reload_graphics_settings(void) {
    // The UIKit HUD and virtual-pad layout consume these getenv values on
    // the main thread. Keep the entire unset/apply interval in that domain.
    if (!NSThread.isMainThread) {
        __block int result;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = s2a_ios_reload_graphics_settings(); });
        return result;
    }
    @autoreleasepool {
        // 与起局同一顺序：设置 → 清单。先撤清单自己写的变量（审计 P1-80：原先只撤设置页登记的，清单写的 S2A_FPS60=1 留着，设置里关 60 帧、立刻重启不生效）
        @try {
            s2a_caps_reset();
            s2a_ios_reapply_graphics_settings(s2a_ios_settings_defaults());
            s2a_caps_apply(caps_dir().fileSystemRepresentation);
        }
        @catch (NSException *error) {
            fprintf(stderr, "[S2A 画面设置] 【红】重读失败，保留停止状态：%s\n", error.reason.UTF8String);
            return -1;
        }
        return 0;
    }
}

