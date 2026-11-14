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
            if (!fpsP) fps[@"hidden"] = @YES;
            if (!wsP) full[@"hidden"] = @YES;
            if (fpsP) {
                fps[@"title"] = S2AL(@"settings.fps.patchTitle"); fps[@"enabled"] = @YES; fps[@"on"] = @(s2a_ios_fps60_on_for(gid));
                fps[@"note"] = target > 0 ? [NSString stringWithFormat:S2AL(@"settings.fps.patchNote"), (long)target] : S2AL(@"settings.patchNote");
                // 帧率档位（11-13 维护者：60 / 120 帧补丁都带进去，玩家自己选；同 app_settings.m 帧率档位行）：两档以上才给，值 0 = 自动（不超过屏幕刷新率的最高一档）
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
        return dup_json(@{@"fps": fps, @"fullscreen": full, @"patches": patches, @"cheats": cheats});
    }
}

// kind = fps / fpspick / fullscreen / patch / cheat；key = 补丁编号 / 「文件名/条目名」（fps、fullscreen 不看）。返回 1 存成 / 0 没存成
int s2a_shell_game_option_set(const char *game_id, const char *kind, const char *key, int on) {
    @autoreleasepool {
        if (!gid_ok(game_id) || !kind) return 0;
        NSString *gid = @(game_id), *k = @(kind), *item = key ? @(key) : @"";
        if ([k isEqual:@"fps"]) { s2a_ios_set_fps60_for(gid, on != 0); return 1; }
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
    NSArray<S2ACPatchGroup *> *groups = patch_groups(gid); NSSet *pon = S2ACPatchEnabled(groups, d); BOOL fps = NO;
    for (S2ACPatchGroup *g in groups) for (S2ACPatchItem *it in g.items) {
        if (it.followsFps60) fps = YES;
        else if ([pon containsObject:it.ident]) [out addObject:@{@"kind": @"patch", @"key": it.ident, @"name": it.title}];
    }
    if (fps && s2a_ios_fps60_on_for(gid)) [out addObject:@{@"kind": @"fps", @"key": @"fps60", @"name": S2AL(@"cpatch.group.fps")}];
    return out;
}
NSArray<NSDictionary *> *s2a_ios_crash_suspects(void) { return g_s2a_crash_asked ? @[] : s2a_ios_crash_suspects_for(current_gid()); }
void s2a_ios_crash_turn_off_for(NSString *gid, NSArray<NSDictionary *> *items) {
    NSString *dir = s2a_ios_cheats_dir_for(gid); NSMutableSet *con = cheats_enabled(dir); BOOL cheats = NO;
    NSArray<S2ACPatchGroup *> *groups = nil;
    for (NSDictionary *it in items) {
        if ([it[@"kind"] isEqual:@"cheat"]) { [con removeObject:it[@"key"]]; cheats = YES; }
        else if ([it[@"kind"] isEqual:@"fps"]) s2a_ios_set_fps60_for(gid, NO);
        else { if (!groups) groups = patch_groups(gid); S2ACPatchSetEnabled(groups, s2a_ios_settings_defaults_for(gid), it[@"key"], NO); }
    }
    if (cheats) s2a_ios_cheats_write_enabled(dir, con);
}
void s2a_ios_crash_turn_off(NSArray<NSDictionary *> *items) { s2a_ios_crash_turn_off_for(current_gid(), items); }
