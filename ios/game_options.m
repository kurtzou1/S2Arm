// 单款画面补丁与金手指选项（11-13 维护者：游戏库按住游戏的设置里也要有帧率 / 满屏 / 金手指，并记住选择）。
//   游戏库（shell S2ArmGameSettings.swift）经 s2a_shell_game_options_json / s2a_shell_game_option_set 读写；与游戏内设置页（app_settings.m）、
//   社区补丁页（cpatch_settings.m）、金手指面板（vpad_cheats.m）是同一份存储、同一口径，任一处改了另一处看到的就是改后的：
//     60 帧 / 满屏：按游戏的偏好 S2AGame.<游戏号>（settings.m s2a_ios_fps60_on_for / s2a_ios_fullscreen_state）
//     社区补丁：同上的 S2ACommunityPatches（cpatch_model.m），表取这款随行目录 Games/<游戏号>/cpatch.tsv
//     金手指：这款文档根 cheats/enabled.txt（服务层 Cheats.cs 每秒看改动时间重载，进了游戏也即时生效）
#import <Foundation/Foundation.h>
#import "settings.h"
#import "cpatch_model.h"
#import "s2a_l10n.h"
#include "s2a_docs.h"
#include "native.h"   // LOG（崩溃恢复两行日志）
#include <stdlib.h>
#include <string.h>

NSArray<NSDictionary *> *s2a_cheats_parse(NSString *text);   // ios/cheats_parse.m

static NSString *current_gid(void) { const char *g = getenv("S2A_LAUNCH_GAME_ID"); return g && *g ? @(g) : nil; }
static BOOL gid_ok(const char *g) {   // 进路径：只收 [A-Za-z0-9._-]、不以 . 开头（同 runtime/src/launchctx.c）
    if (!g || !*g || *g == '.' || strlen(g) > 64) return NO;
    for (const char *p = g; *p; p++) if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '.' || *p == '_' || *p == '-')) return NO;
    return YES;
}
// 这款的金手指目录：正在跑的这款 / 单款壳 = 文档根（s2a_docs.h）下 cheats；多款容器里别的款 = Documents/games/<游戏号>/cheats（launchctx.c 同一约定）
NSString *s2a_ios_cheats_dir_for(NSString *gid) {
    if (!gid.length || [gid isEqualToString:current_gid() ?: @""]) { char d[1024]; s2a_docs_path(d, sizeof d, "cheats"); return @(d); }
    return [[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/games"] stringByAppendingPathComponent:gid] stringByAppendingPathComponent:@"cheats"];
}
// 上一局每条社区补丁的实际结果（runtime/src/cpatch.c 写 <本款文档根>/cpatch_status.tsv：编号 → @[状态, 实测]）；没跑过 = 空
NSDictionary<NSString *, NSArray<NSString *> *> *s2a_ios_cpatch_status_for(NSString *gid) {
    NSString *root = [s2a_ios_cheats_dir_for(gid) stringByDeletingLastPathComponent];   // 金手指目录的上一层 = 这款文档根
    NSString *t = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"cpatch_status.tsv"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *l in [t componentsSeparatedByString:@"\n"]) { NSArray *c = [l componentsSeparatedByString:@"\t"]; if (c.count >= 3) m[c[0]] = @[c[1], c[2]]; }
    return m;
}
// 一条补丁给玩家看的结果（追加在说明后）：没生效写原因；生效且量到效果写实测；开着、上一局还没量到 / 没跑过 = 不写
NSString *s2a_ios_cpatch_result(NSArray<NSString *> *st) {
    if (!st) return nil;
    if ([st[0] isEqual:@"不配套"] || [st[0] isEqual:@"表不认"]) return S2AL(@"cpatch.result.mismatch");
    if (![st[0] isEqual:@"开"] || !st[1].length) return nil;
    // 实测是机器值（runtime/src/cpatch.c s2a_cpatch_effect：fps=<帧率> / aspect=<宽>:<高>），这里按当前语言成句
    NSString *v = st[1];
    //   帧率达到 55 帧（60 帧补丁的目标，留 5 帧余量）才算生效，达不到如实写实测；满屏按上屏判据：铺满算生效、多数没铺满如实写
    if ([v hasPrefix:@"fps="]) { NSString *n = [v substringFromIndex:4]; return [NSString stringWithFormat:n.intValue >= 55 ? S2AL(@"cpatch.result.fps") : S2AL(@"cpatch.result.fpsLow"), n]; }
    if ([v hasPrefix:@"aspect="]) return [NSString stringWithFormat:S2AL(@"cpatch.result.aspect"), [v substringFromIndex:7]];
    if ([v isEqual:@"fill=ok"]) return S2AL(@"cpatch.result.filled");
    if ([v isEqual:@"unfilled"]) return S2AL(@"cpatch.result.unfilled");
    return nil;
}
// 上一局这份补丁是不是生效了（同 s2a_ios_cpatch_result 的判法：帧率到 55 帧 / 量到画幅 / 铺满）：设置页把结果写成绿色
BOOL s2a_ios_cpatch_result_ok(NSArray<NSString *> *st) {
    if (st.count < 2 || ![st[0] isEqual:@"开"]) return NO;
    NSString *v = st[1];
    return ([v hasPrefix:@"fps="] && [v substringFromIndex:4].intValue >= 55) || [v hasPrefix:@"aspect="] || [v isEqual:@"fill=ok"];
}
static NSArray<S2ACPatchGroup *> *patch_groups(NSString *gid) {
    NSString *text = [NSString stringWithContentsOfFile:[s2a_ios_game_dir(gid) stringByAppendingPathComponent:@"cpatch.tsv"] encoding:NSUTF8StringEncoding error:nil];
    return text ? S2ACPatchGroupsFromTSV(text) : @[];
}
static NSMutableSet<NSString *> *cheats_enabled(NSString *dir) {
    NSString *en = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"enabled.txt"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableSet *on = [NSMutableSet setWithArray:[en componentsSeparatedByString:@"\n"] ?: @[]]; [on removeObject:@""]; return on;
}
// 金手指条目（文件名/条目名、显示名、写死地址），主代码不列（同文件任一条开着就随之执行）。文件序 + 条目序，与面板一致
NSArray<NSDictionary *> *s2a_ios_cheat_entries(NSString *dir) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f.pathExtension.lowercaseString isEqual:@"txt"] || [f isEqual:@"enabled.txt"] || [f isEqual:@"status.txt"]) continue;
        NSString *text = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        for (NSDictionary *e in (text ? s2a_cheats_parse(text) : nil)) {
            if ([e[@"master"] boolValue] || [e[@"folder"] intValue]) continue;   // 分组标题 / 分组结束（ios/cheats_parse.m folder）不是开关
            [out addObject:@{@"key": [NSString stringWithFormat:@"%@/%@", f, e[@"name"]], @"name": [e[@"name"] isEqual:@"未命名"] ? S2AL(@"cheats.unnamed") : e[@"name"],
                             @"fixed": e[@"fixed"] ?: @NO}];
        }
    }
    return out;
}
// 设置页「S 级优化」两行的计数（11-13）：这款金手指开了几条 / 共几条（分组标题不算）、社区补丁开了几份 / 共几份（跟 60 帧 / 满屏走的按那两个开关算）
void s2a_ios_sgrade_counts(NSString *gid, NSInteger *cheatOn, NSInteger *cheatAll, NSInteger *patchOn, NSInteger *patchAll) {
    NSString *dir = s2a_ios_cheats_dir_for(gid); NSSet *con = cheats_enabled(dir); NSArray *ce = s2a_ios_cheat_entries(dir);
    *cheatAll = (NSInteger)ce.count; *cheatOn = 0; for (NSDictionary *e in ce) if ([con containsObject:e[@"key"]]) (*cheatOn)++;
    NSArray<S2ACPatchGroup *> *groups = patch_groups(gid); NSSet *pon = S2ACPatchEnabled(groups, s2a_ios_settings_defaults_for(gid));
    *patchAll = 0; *patchOn = 0; BOOL fs = NO; s2a_ios_fullscreen_state(gid, &fs);
    for (S2ACPatchGroup *g in groups) for (S2ACPatchItem *it in g.items) {
        (*patchAll)++;
        if (it.followsFps60 ? s2a_ios_fps60_on_for(gid) : it.followsFullscreen ? fs : [pon containsObject:it.ident]) (*patchOn)++;
    }
}
BOOL s2a_ios_cheats_write_enabled(NSString *dir, NSSet<NSString *> *on) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *body = [[[on allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
    return [[body stringByAppendingString:@"\n"] writeToFile:[dir stringByAppendingPathComponent:@"enabled.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 游戏语言（#1252：游戏库每款设置页也能选，开局前选好进游戏直接生效）：{"pick","levels":[{"value","label"}],"note"}，同游戏内设置页（app_settings.m）口径——
//   第一项跟随系统；只列这款支持的（资源包 ctl/control.nacp），读不到就列全部；已选的这款没有也留着；note = 选的这款不支持时起局实际用哪种
static NSDictionary *game_language_json(NSString *gid, NSUserDefaults *d) {
    NSArray<NSString *> *supported;
    if ([gid isEqualToString:current_gid() ?: @""]) supported = s2a_ios_game_supported_languages();
    else { char docs[1024], gdocs[1200], root[1400]; s2a_container_docs(docs, sizeof docs); snprintf(gdocs, sizeof gdocs, "%s/games/%s", docs, gid.UTF8String);
           s2a_pack_root(root, sizeof root, gdocs); supported = s2a_ios_game_supported_languages_in(@(root)); }
    NSString *cur = [d stringForKey:S2AGameLanguageKey];
    NSArray<NSString *> *all = s2a_ios_game_languages();
    NSMutableArray *levels = [NSMutableArray array];
    for (NSUInteger i = 0; i < all.count; i++)
        if (i == 0 || supported.count == 0 || [supported containsObject:all[i]] || [all[i] isEqualToString:cur]) [levels addObject:@{@"value": all[i], @"label": s2a_ios_game_language_label(all[i])}];
    return @{@"pick": cur && [all containsObject:cur] ? cur : @"system", @"levels": levels, @"note": s2a_ios_game_language_note_with(d, supported) ?: @""};
}

static char *dup_json(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return NULL;
    char *p = malloc(d.length + 1); if (!p) return NULL;
    memcpy(p, d.bytes, d.length); p[d.length] = 0; return p;
}

// {"fps":{"on","enabled","note"},"fullscreen":{"on","enabled","note"},"patches":[{"id","title","note","on"}],"cheats":[{"key","name","note","on"}]}
//   帧率类社区补丁（编号 fps:）跟 60 帧开关走，不单列；note 是给玩家看的一行（已按当前语言）
char *s2a_shell_game_options_json(const char *game_id) {
    @autoreleasepool {
        if (!gid_ok(game_id)) return NULL;
        NSString *gid = @(game_id);
        NSUserDefaults *d = s2a_ios_settings_defaults_for(gid);
        // 60 帧：本款原生 60 帧（改不动）/ 包里判过有已知问题（可手动开，写明）/ 正常
        NSMutableDictionary *fps = [@{@"on": @(s2a_ios_fps60_on_for(gid)), @"enabled": @YES, @"note": S2AL(@"game.fps.note")} mutableCopy];
        if ([d boolForKey:@"S2AFpsNative60"]) { fps[@"on"] = @YES; fps[@"enabled"] = @NO; fps[@"note"] = S2AL(@"settings.fps.native"); }
        else {
            NSString *caps = [NSString stringWithContentsOfFile:[s2a_ios_game_dir(gid) stringByAppendingPathComponent:@"s2a_caps.tsv"] encoding:NSUTF8StringEncoding error:nil];
            for (NSString *l in [caps componentsSeparatedByString:@"\n"]) if ([l hasPrefix:@"fps60\t0"]) fps[@"note"] = S2AL(@"settings.fps.knownIssue");
        }
        BOOL fs = NO; int blocked = s2a_ios_fullscreen_state(gid, &fs);
        NSMutableDictionary *full = [@{@"on": @(fs), @"enabled": @(!blocked), @"note": blocked ? S2AL(@"settings.widen.blocked") : S2AL(@"game.fullscreen.note")} mutableCopy];   // 下面补丁结果可能追加
        NSArray<S2ACPatchGroup *> *groups = patch_groups(gid);
        // 补丁优先（11-13 维护者，同整页设置 app_settings.m）：带帧率补丁的款「60 帧」改名「帧率」、写补丁目标，原生 60 帧也不再锁死（补丁可以到 120）；
        //   带满屏补丁的款满屏写「社区满屏补丁接管」
        {
            NSInteger target = 0; BOOL fpsP = NO, wsP = NO;
            for (S2ACPatchGroup *g in groups) for (S2ACPatchItem *it in g.items) { if (it.followsFps60) { fpsP = YES; target = MAX(target, it.targetFps); } if ([g.kind isEqual:@"widescreen"] || it.followsFullscreen) wsP = YES; }
            // 只用社区补丁（11-13 维护者撤掉我方 60 帧与通用满屏，tools/caps_policy.py patch_only）：没有对应补丁的款不出这一行，玩家拿到的就是原生游戏
            //   满屏例外（11-15 维护者「没补丁的游戏手动打开满屏就走咱们通用方案」，#2205）：没有宽屏补丁也出这一行，缺省关、玩家明确开 = 我方通用满屏
            if (!fpsP) fps[@"hidden"] = @YES;
            if (fpsP) {
                fps[@"title"] = S2AL(@"settings.fps.patchTitle"); fps[@"enabled"] = @YES; fps[@"on"] = @(s2a_ios_fps60_on_for(gid));
                fps[@"note"] = target > 0 ? [NSString stringWithFormat:S2AL(@"settings.fps.patchNote"), (long)target] : S2AL(@"settings.patchNote");
                // 帧率档位（11-13 维护者：60 / 120 帧补丁都带进去，玩家自己选；同 app_settings.m 帧率档位行）：两档以上才给，值 0 = 自动（不超过 60 帧的最高一档）
                NSMutableOrderedSet *lv = [NSMutableOrderedSet orderedSet];
                for (S2ACPatchGroup *g in groups) for (S2ACPatchItem *it in g.items) if (it.followsFps60) [lv addObject:@(it.targetFps > 0 ? it.targetFps : 60)];
                NSArray *sorted = [lv.array sortedArrayUsingSelector:@selector(compare:)];
                if (sorted.count > 1) {
                    NSMutableArray *opts = [NSMutableArray arrayWithObject:@{@"value": @"0", @"label": S2AL(@"settings.fps.pick.auto")}];
                    for (NSNumber *n in sorted) [opts addObject:@{@"value": n.stringValue, @"label": [NSString stringWithFormat:S2AL(@"settings.fps.pick.level"), n.longValue]}];
                    NSInteger pick = [d integerForKey:@"S2AFpsPick"];
                    fps[@"levels"] = opts; fps[@"levelsTitle"] = S2AL(@"settings.fps.pick"); fps[@"pick"] = [sorted containsObject:@(pick)] ? @(pick).stringValue : @"0";
                }
            }
            if (wsP && !blocked) full[@"note"] = S2AL(@"settings.fullscreen.patchNote");
        }
        NSSet *pon = S2ACPatchEnabled(groups, d);
        NSDictionary *st = s2a_ios_cpatch_status_for(gid);
        NSMutableArray *patches = [NSMutableArray array];
        for (S2ACPatchGroup *g in groups) for (S2ACPatchItem *it in g.items) {
            NSString *res = s2a_ios_cpatch_result(st[it.ident]);
            if (it.followsFps60 && res) fps[@"note"] = [NSString stringWithFormat:@"%@ · %@", fps[@"note"], res];   // 帧率补丁的结果记在 60 帧那行
            if (it.followsFullscreen && res) full[@"note"] = [NSString stringWithFormat:@"%@ · %@", full[@"note"], res];
            if (it.followsFps60 || it.followsFullscreen) continue;   // 帧率类跟 60 帧、自适应满屏跟满屏开关，不单列
            NSString *note = [NSString stringWithFormat:@"%@ · %@", g.title, it.defaultOn ? S2AL(@"cpatch.tag.verified") : S2AL(@"cpatch.tag.unverified")];
            [patches addObject:@{@"id": it.ident, @"title": it.title, @"on": @([pon containsObject:it.ident]), @"note": res ? [note stringByAppendingFormat:@" · %@", res] : note}];
        }
        NSString *dir = s2a_ios_cheats_dir_for(gid); NSSet *con = cheats_enabled(dir);
        NSMutableArray *cheats = [NSMutableArray array];
        for (NSDictionary *e in s2a_ios_cheat_entries(dir))
            [cheats addObject:@{@"key": e[@"key"], @"name": e[@"name"], @"on": @([con containsObject:e[@"key"]]), @"note": [e[@"fixed"] boolValue] ? S2AL(@"cheats.fixedAddress") : @""}];
        // 游戏音量（#1186，同齿轮菜单「声音」）：0–100，没设过 = 100
        id vo = [d objectForKey:@"S2AGameVolume"]; NSInteger volume = vo ? MAX(0, MIN(100, [vo integerValue])) : 100;
        // 输出设备类型 + 两个虚拟环绕开关（#189 后续，5.1 虚拟环绕第二片；定义表 game_settings.v1.json 的 audioDevice / vsSpeakers /
        //   vsHeadphones）：按游戏存（per_game_keys），没选过 = auto（按设备真实声道判，5.1 直通缺省不变）；两个开关各存各的，
        //   只在对应显式类型下生效（驱动侧判），没拨过按关报
        id ad = [d objectForKey:@"S2AAudioDevice"];
        NSString *device = [ad isKindOfClass:NSString.class] && [@[@"builtin", @"headphones", @"external"] containsObject:ad] ? ad : @"auto";
        id vsS = [d objectForKey:@"S2AAudioVsSpeakers"], vsH = [d objectForKey:@"S2AAudioVsHeadphones"];
        return dup_json(@{@"fps": fps, @"fullscreen": full, @"patches": patches, @"cheats": cheats, @"volume": @(volume), @"language": game_language_json(gid, d),
                          @"audio": @{@"device": device, @"vsSpeakers": @([vsS boolValue]), @"vsHeadphones": @([vsH boolValue])}});
    }
}

// kind = fps / fpspick / fullscreen / patch / cheat / volume / language / audiodevice / audiovs；key = 补丁编号 / 「文件名/条目名」（fps、fullscreen 不看）。返回 1 存成 / 0 没存成
int s2a_shell_game_option_set(const char *game_id, const char *kind, const char *key, int on) {
    @autoreleasepool {
        if (!gid_ok(game_id) || !kind) return 0;
        NSString *gid = @(game_id), *k = @(kind), *item = key ? @(key) : @"";
        if ([k isEqual:@"fps"]) { s2a_ios_set_fps60_for(gid, on != 0); return 1; }
        if ([k isEqual:@"volume"]) { [s2a_ios_settings_defaults_for(gid) setInteger:MAX(0, MIN(100, item.integerValue)) forKey:@"S2AGameVolume"]; return 1; }   // 游戏音量：key = 百分比，on 不看（#1186）
        if ([k isEqual:@"audiodevice"]) {   // 输出设备类型：key = builtin / headphones / external，"auto" = 未选择（删掉这款的值），on 不看（#189 后续，5.1 虚拟环绕第二片）
            if (![item isEqual:@"auto"] && ![item isEqual:@"builtin"] && ![item isEqual:@"headphones"] && ![item isEqual:@"external"]) return 0;
            NSUserDefaults *gd = s2a_ios_settings_defaults_for(gid);
            if ([item isEqual:@"auto"]) [gd removeObjectForKey:@"S2AAudioDevice"]; else [gd setObject:item forKey:@"S2AAudioDevice"];
            return 1;
        }
        if ([k isEqual:@"audiovs"]) {   // 两个虚拟环绕开关：key = speakers / headphones，on = 开关值；各存各的（切换设备类型各自恢复），on 不看类型（驱动侧判）
            if (![item isEqual:@"speakers"] && ![item isEqual:@"headphones"]) return 0;
            [s2a_ios_settings_defaults_for(gid) setBool:(on != 0) forKey:[item isEqual:@"speakers"] ? @"S2AAudioVsSpeakers" : @"S2AAudioVsHeadphones"];
            return 1;
        }
        if ([k isEqual:@"language"]) {   // 游戏语言：key = 宿主枚举名，"system" = 跟随系统（删掉这款的值），on 不看（#1252）
            if (![s2a_ios_game_languages() containsObject:item]) return 0;
            NSUserDefaults *gd = s2a_ios_settings_defaults_for(gid);
            if ([item isEqual:@"system"]) [gd removeObjectForKey:S2AGameLanguageKey]; else [gd setObject:item forKey:S2AGameLanguageKey];
            return 1;
        }
        if ([k isEqual:@"fpspick"]) { [s2a_ios_settings_defaults_for(gid) setInteger:MAX(0, item.integerValue) forKey:@"S2AFpsPick"]; return 1; }   // 帧率档位：key = 目标帧率（"0" = 自动），on 不看
        if ([k isEqual:@"fullscreen"]) { BOOL now; if (s2a_ios_fullscreen_state(gid, &now)) return 0; s2a_ios_set_fullscreen(gid, on != 0); return 1; }
        if ([k isEqual:@"patch"]) { S2ACPatchSetEnabled(patch_groups(gid), s2a_ios_settings_defaults_for(gid), item, on != 0); return 1; }
        if ([k isEqual:@"cheat"]) {
            NSString *dir = s2a_ios_cheats_dir_for(gid); NSMutableSet *set = cheats_enabled(dir);
            if (![[s2a_ios_cheat_entries(dir) valueForKey:@"key"] containsObject:item]) return 0;
            if (on) [set addObject:item]; else [set removeObject:item];
            return s2a_ios_cheats_write_enabled(dir, set) ? 1 : 0;
        }
        return 0;
    }
}

// 开着金手指 / 社区补丁时游戏死在前台（会话标记，diag.m）：下次进这款先问「上次开着 X、Y 时游戏退出了，要先关掉它们吗？」（关掉 / 继续开着），
//   不替玩家关（维护者 11-12「崩了再恢复不打开不就行」；Mac 启动器 pack/jobs/cheats.py note_crash 同一做法，iOS 管 iOS 的）。
//   嫌疑 = 这款开着的金手指 + 玩家明确开的、不是我方验过缺省开的社区补丁（验过的不算嫌疑）
// 游戏库点开始、启动游戏之前已问过（app.m library_play）：进了游戏不再问第二遍（diag.m 只问发诊断）
int g_s2a_crash_asked;
NSArray<NSDictionary *> *s2a_ios_crash_suspects_for(NSString *gid) {
    NSMutableArray *out = [NSMutableArray array];
    NSString *dir = s2a_ios_cheats_dir_for(gid); NSSet *con = cheats_enabled(dir);
    for (NSDictionary *e in s2a_ios_cheat_entries(dir)) if ([con containsObject:e[@"key"]]) [out addObject:@{@"kind": @"cheat", @"key": e[@"key"], @"name": e[@"name"]}];
    // 社区补丁：开着的都算（11-13 起没选过 = 默认开，不再只算玩家自己开的）；帧率补丁跟 60 帧开关，开着就把「60 帧」算进去（关掉 = 关 60 帧）
    NSUserDefaults *d = s2a_ios_settings_defaults_for(gid);
    NSArray<S2ACPatchGroup *> *groups = patch_groups(gid); NSSet *pon = S2ACPatchEnabled(groups, d); BOOL fps = NO, fpsVerified = NO, famVerified = NO;
    for (S2ACPatchGroup *g in groups) for (S2ACPatchItem *it in g.items) {
        if (it.followsFps60) { fps = YES; fpsVerified |= it.defaultOn; }
        else if (it.followsFullscreen) famVerified |= it.defaultOn;   // 自适应满屏一族跟满屏开关：并成一条「满屏」，关 = 关开关（原先逐份从列表里删，开关仍显示开）
        else if ([pon containsObject:it.ident]) [out addObject:@{@"kind": @"patch", @"key": it.ident, @"name": it.title, @"verified": @(it.defaultOn)}];
    }
    if (fps && s2a_ios_fps60_on_for(gid)) [out addObject:@{@"kind": @"fps", @"key": @"fps60", @"name": S2AL(@"cpatch.group.fps"), @"verified": @(fpsVerified)}];
    // 满屏开着就算一条：自适应满屏一族跟开关，或没有补丁、玩家明确开的我方通用满屏（11-15；同 Mac pack/jobs/cheats.py），崩了下一局关满屏
    BOOL fsOn = NO; if (!s2a_ios_fullscreen_state(gid, &fsOn) && fsOn)
        [out addObject:@{@"kind": @"fs", @"key": @"fullscreen", @"name": S2AL(@"cpatch.group.widescreen"), @"verified": @(famVerified)}];
    return out;
}
// 只关出事的那份（v0.4.1，规则 ios/cpatch_model.m S2ACrashNarrow）：每局开始记下这局开着的（S2ACrashSessionOn），上一局好好收局的那份升为 S2ACrashGoodOn；
//   崩了按 GoodOn 找新开的，没有再逐层扩大
static NSSet<NSString *> *crash_good(NSString *gid) { NSArray *a = [s2a_ios_settings_defaults_for(gid) arrayForKey:@"S2ACrashGoodOn"]; return a ? [NSSet setWithArray:a] : nil; }
NSArray<NSDictionary *> *s2a_ios_crash_pick_for(NSString *gid) { return S2ACrashNarrow(s2a_ios_crash_suspects_for(gid), crash_good(gid)); }
// 崩溃落点（runtime/src/crash.c crash_where_note 写 <这款文档根>/crash_where：game / patch / host），读完删
static NSString *crash_where_take(NSString *gid) {
    NSString *p = [[s2a_ios_cheats_dir_for(gid) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"crash_where"];
    NSString *w = [[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [NSFileManager.defaultManager removeItemAtPath:p error:nil];
    return w ?: @"";
}
static NSString *app_version(void) { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""; }
// 上一局死在前台、要自动关的这几条（同 pack/jobs/cheats.py note_crash，11-15「优化 S 级优化，不是撤」）：
//   落点两头都在宿主代码（host）= 多半是 S2Arm 自己的毛病：第一次不关、只记下这组开关（S2ACrashHostOnce），同一组再崩才关；
//   要关的记下 App 版本（S2ACrashAutoOff），换了版本自动重开一次（s2a_ios_crash_session_begin）。→ 这次要关的（空 = 不关）
NSArray<NSDictionary *> *s2a_ios_crash_decide_for(NSString *gid) {
    NSArray<NSDictionary *> *items = s2a_ios_crash_pick_for(gid);
    NSString *where = crash_where_take(gid);
    if (!items.count) return items;
    NSUserDefaults *d = s2a_ios_settings_defaults_for(gid);
    NSMutableArray *tags = [NSMutableArray array]; for (NSDictionary *it in s2a_ios_crash_suspects_for(gid)) [tags addObject:S2ACrashTag(it)];
    [tags sortUsingSelector:@selector(compare:)];
    if ([where isEqualToString:@"host"] && ![[d arrayForKey:@"S2ACrashHostOnce"] isEqualToArray:tags]) {
        [d setObject:tags forKey:@"S2ACrashHostOnce"];
        LOG("崩溃恢复：上一局崩在宿主代码（不在游戏 / 补丁区），这次先不关补丁 / 金手指；同样开着再崩才关");
        return @[];
    }
    [d removeObjectForKey:@"S2ACrashHostOnce"];
    NSMutableArray *rec = [NSMutableArray array];
    NSNumber *now = @((long long)NSDate.date.timeIntervalSince1970);
    for (NSDictionary *it in items) [rec addObject:@{@"kind": it[@"kind"], @"key": it[@"key"], @"name": it[@"name"] ?: @"", @"cause": @"crash", @"at": now}];
    [d setObject:@{@"ver": app_version(), @"items": rec} forKey:@"S2ACrashAutoOff"];
    return items;
}
// 弱链接[lab]：s2a_dprompt_notice（dprompt.m 提供的提示条；输入工作台不编 dprompt.m，取不到就不提示）
void s2a_dprompt_notice(NSString *title, NSString *body, double delay, double seconds) __attribute__((weak_import));
void s2a_ios_crash_session_begin(NSString *gid, BOOL prev_clean) {
    if (!gid.length) return;
    NSUserDefaults *d = s2a_ios_settings_defaults_for(gid);
    // 上次崩溃自动关掉的：App 换了版本就重开一次（只开当时关的），并告诉玩家；记录删掉
    NSDictionary *ao = [d dictionaryForKey:@"S2ACrashAutoOff"];
    if (ao && [ao[@"ver"] length] && ![ao[@"ver"] isEqualToString:app_version()]) {
        NSString *dir = s2a_ios_cheats_dir_for(gid); NSMutableSet *con = cheats_enabled(dir); BOOL cheats = NO; NSArray<S2ACPatchGroup *> *groups = nil;
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *it in ao[@"items"]) {
            NSString *k = it[@"kind"];
            if ([k isEqual:@"cheat"]) { [con addObject:it[@"key"]]; cheats = YES; }
            else if ([k isEqual:@"fps"]) s2a_ios_set_fps60_for(gid, YES);
            else if ([k isEqual:@"fs"]) s2a_ios_set_fullscreen(gid, YES);
            else { if (!groups) groups = patch_groups(gid); S2ACPatchSetEnabled(groups, d, it[@"key"], YES); }
            if ([it[@"name"] length]) [names addObject:it[@"name"]];
        }
        if (cheats) s2a_ios_cheats_write_enabled(dir, con);
        [d removeObjectForKey:@"S2ACrashAutoOff"];
        NSString *joined = [names componentsJoinedByString:S2AL(@"common.listSeparator")];
        LOG("崩溃恢复：App 换了版本（%s → %s），重开上次崩溃时自动关掉的 %s", [ao[@"ver"] UTF8String], app_version().UTF8String, joined.UTF8String);
        if (names.count && s2a_dprompt_notice) s2a_dprompt_notice(S2AL(@"crash.restored.title"), [NSString stringWithFormat:S2AL(@"crash.restored.body"), joined], 3, 8);
    }
    NSArray *last = [d arrayForKey:@"S2ACrashSessionOn"];
    if (prev_clean && last) [d setObject:last forKey:@"S2ACrashGoodOn"];
    NSMutableArray *now = [NSMutableArray array]; for (NSDictionary *it in s2a_ios_crash_suspects_for(gid)) [now addObject:S2ACrashTag(it)];
    [d setObject:now forKey:@"S2ACrashSessionOn"];
}
NSArray<NSDictionary *> *s2a_ios_crash_suspects(void) { return g_s2a_crash_asked ? @[] : s2a_ios_crash_decide_for(current_gid()); }
void s2a_ios_crash_session_begin_single(int prev_clean) { if (!g_s2a_crash_asked) s2a_ios_crash_session_begin(current_gid(), prev_clean); }   // 单款壳（diag.m）；多款容器已在 app.m 记过
void s2a_ios_crash_turn_off_for(NSString *gid, NSArray<NSDictionary *> *items) {
    NSString *dir = s2a_ios_cheats_dir_for(gid); NSMutableSet *con = cheats_enabled(dir); BOOL cheats = NO;
    NSArray<S2ACPatchGroup *> *groups = nil;
    for (NSDictionary *it in items) {
        if ([it[@"kind"] isEqual:@"cheat"]) { [con removeObject:it[@"key"]]; cheats = YES; }
        else if ([it[@"kind"] isEqual:@"fps"]) s2a_ios_set_fps60_for(gid, NO);
        else if ([it[@"kind"] isEqual:@"fs"]) s2a_ios_set_fullscreen(gid, NO);
        else { if (!groups) groups = patch_groups(gid); S2ACPatchSetEnabled(groups, s2a_ios_settings_defaults_for(gid), it[@"key"], NO); }
    }
    if (cheats) s2a_ios_cheats_write_enabled(dir, con);
}
void s2a_ios_crash_turn_off(NSArray<NSDictionary *> *items) { s2a_ios_crash_turn_off_for(current_gid(), items); }


// S 级按类状态（同 pack/jobs/sgrade.py state 的形状与状态码，iPhone 设置页 / 游戏库读；界面与文案归体验梳理线）：
//   随包表：sgrade_state.json（出包 pack/jobs/sgrade.py write_kit_state 写进 iOS kit：版本对照、满屏来源、出包时选不打入；组装时拷进 App）
//   开关、上一局是否生效（cpatch_status.tsv）、自动关（S2ACrashAutoOff，崩溃 / 停帧救场记）由本机算。→ {platform, widescreen, fps, gfx, cheats}，每类 {state, …}
NSDictionary *s2a_ios_sgrade_state(NSString *gid) {
    NSData *raw = [NSData dataWithContentsOfFile:[s2a_ios_game_dir(gid) stringByAppendingPathComponent:@"sgrade_state.json"]];
    NSDictionary *kit = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil; if (![kit isKindOfClass:NSDictionary.class]) kit = nil;
    BOOL opted = [kit[@"optedOut"] boolValue];
    NSUserDefaults *d = s2a_ios_settings_defaults_for(gid);
    NSDictionary *ao = [d dictionaryForKey:@"S2ACrashAutoOff"]; NSMutableDictionary *autoOff = [NSMutableDictionary dictionary];
    for (NSDictionary *it in ao[@"items"]) autoOff[[NSString stringWithFormat:@"%@\t%@", it[@"kind"], it[@"key"]]] = @{@"cause": it[@"cause"] ?: @"crash", @"at": it[@"at"] ?: @0};
    NSDictionary *st = s2a_ios_cpatch_status_for(gid);
    BOOL (^bad)(NSArray *) = ^BOOL(NSArray *x) { return x.count >= 2 && ([x[0] isEqual:@"不配套"] || [x[0] isEqual:@"表不认"] || [x[1] isEqual:@"unfilled"]); };   // 非玩家句（运行时状态值）
    NSString *(^missing)(NSString *) = ^NSString *(NSString *cat) {
        if (!kit) return @"unknown";
        NSDictionary *v = kit[cat][@"versions"]; if ([v[@"exact"] intValue] > 0) return @"pending";
        return [v[@"available"] count] ? @"version" : @"none";
    };
    NSArray<S2ACPatchGroup *> *groups = patch_groups(gid);
    BOOL fam = NO, fpsP = NO; NSMutableArray *wsIds = [NSMutableArray array];
    for (S2ACPatchGroup *g in groups) for (S2ACPatchItem *it in g.items) { if (it.followsFullscreen) fam = YES; else if (it.followsFps60) fpsP = YES; else if ([g.kind isEqual:@"widescreen"]) [wsIds addObject:it.ident]; }
    NSMutableDictionary *out = [@{@"platform": @"ios"} mutableCopy];
    // 满屏：补丁 → 我方通用满屏（宽屏已验证）→ 没有
    BOOL fs = NO; int blocked = s2a_ios_fullscreen_state(gid, &fs);
    NSString *src = (fam || wsIds.count) ? @"patch" : [kit[@"widescreen"][@"source"] isEqual:@"own"] ? @"own" : @"none";
    NSDictionary *wsAuto = autoOff[@"fs\tfullscreen"]; for (NSString *k in wsIds) if (!wsAuto) wsAuto = autoOff[[@"patch\t" stringByAppendingString:k]];
    NSArray *wsSt = nil; for (NSString *k in st) if ([k hasPrefix:@"wsauto:"] || [k hasPrefix:@"widescreen:"]) { wsSt = st[k]; if ([wsSt[0] isEqual:@"开"]) break; }   // 非玩家句
    NSString *s = opted ? @"opted_out" : [src isEqual:@"none"] ? missing(@"widescreen") : (blocked || !fs) ? (wsAuto ? @"off_auto" : @"off_user") : bad(wsSt) ? @"ineffective" : @"on";
    out[@"widescreen"] = @{@"state": s, @"source": src, @"active": fam ? @"adaptive" : wsIds.count ? @"fixed" : [src isEqual:@"own"] ? @"own" : @"",
                           @"lastRun": s2a_ios_cpatch_result(wsSt) ?: @"", @"autoOff": wsAuto ?: NSNull.null, @"versions": kit[@"widescreen"][@"versions"] ?: @{}};
    // 帧率：跟「帧率」开关
    BOOL fon = s2a_ios_fps60_on_for(gid); NSDictionary *fAuto = autoOff[@"fps\tfps60"];
    NSArray *fSt = nil; for (NSString *k in st) if ([k hasPrefix:@"fps:"] && [st[k][0] isEqual:@"开"]) { fSt = st[k]; break; }   // 非玩家句
    s = opted ? @"opted_out" : !fpsP ? missing(@"fps") : !fon ? (fAuto ? @"off_auto" : @"off_user") : @"on";
    out[@"fps"] = @{@"state": s, @"lastRun": s2a_ios_cpatch_result(fSt) ?: @"", @"autoOff": fAuto ?: NSNull.null, @"versions": kit[@"fps"][@"versions"] ?: @{}};
    // 画面：iPhone 只打降负载的（11-16，表第 14 列方向 load，见 cpatch_model.m）；包里没有降负载画面补丁 = 画面补丁只在 Mac 版
    NSSet *gon = S2ACPatchEnabled(groups, d); NSArray *gIds = nil; for (S2ACPatchGroup *g in groups) if ([g.kind isEqual:@"gfx"]) gIds = [g.items valueForKey:@"ident"];
    BOOL gAny = NO; NSDictionary *gAuto = nil; for (NSString *k in gIds) { if ([gon containsObject:k]) gAny = YES; if (!gAuto) gAuto = autoOff[[@"patch\t" stringByAppendingString:k]]; }
    out[@"gfx"] = @{@"state": opted ? @"opted_out" : !gIds.count ? @"mac_only" : gAny ? @"on" : (gAuto ? @"off_auto" : @"off_user"),
                    @"active": gAny ? [gIds filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id k, id b) { (void)b; return [gon containsObject:k]; }]] : @[],
                    @"autoOff": gAuto ?: NSNull.null};
    // 金手指
    NSString *dir = s2a_ios_cheats_dir_for(gid); NSSet *con = cheats_enabled(dir); NSArray *ents = s2a_ios_cheat_entries(dir);
    NSDictionary *cAuto = nil; for (NSDictionary *e in ents) if (!cAuto) cAuto = autoOff[[@"cheat\t" stringByAppendingString:e[@"key"]]];
    s = opted ? @"opted_out" : !ents.count ? missing(@"cheats") : con.count ? @"on" : (cAuto ? @"off_auto" : @"off_user");
    out[@"cheats"] = @{@"state": s, @"active": con.allObjects ?: @[], @"autoOff": cAuto ?: NSNull.null, @"versions": kit[@"cheats"][@"versions"] ?: @{}};
    return out;
}
