#import "cpatch_model.h"
#import "s2a_l10n.h"

NSString *const S2ACPatchDefaultsKey = @"S2ACommunityPatches";

@implementation S2ACPatchItem
- (BOOL)followsFps60 { return [self.ident hasPrefix:@"fps:"]; }
- (BOOL)followsFullscreen { return [self.ident hasPrefix:@"wsauto:"]; }
@end
@implementation S2ACPatchGroup
@end

static BOOL has(NSString *s, NSString *re) { return [s rangeOfString:re options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound; }
static NSString *cap(NSString *s, NSString *re, NSUInteger i) {
    NSTextCheckingResult *m = [[NSRegularExpression regularExpressionWithPattern:re options:NSRegularExpressionCaseInsensitive error:nil] firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m && [m rangeAtIndex:i].location != NSNotFound ? [s substringWithRange:[m rangeAtIndex:i]] : nil;
}

NSString *S2ACPatchClassify(NSString *name, NSString *category, NSString *ident) {
    if (has(name, @"\\d+\\s*fps|\\bfps\\b|frame\\s*rate|present interval|swap interval")) return @"fps";
    if (has(name, @"ultra\\s*wide|widescreen|aspect|\\b(21|32):9\\b|16:10|\\b\\d{3,4}\\s*x\\s*\\d{3,4}\\b|docked")) return @"widescreen";
    if (has(name, @"depth of field|\\bdof\\b|resolution|\\blod|blur|\\baa\\b|anti-?alias|shadow|outline|bloom|effect|graphic|texture|\\bfog\\b")) return @"gfx";
    if (has(category, @"ultra\\s*wide|widescreen")) return @"widescreen";
    if (has(category, @"fps")) return @"fps";
    if (category.length) return @"gfx";
    return [ident hasPrefix:@"widescreen:"] ? @"widescreen" : [ident hasPrefix:@"fps:"] ? @"fps" : @"gfx";
}

NSString *S2ACPatchTitle(NSString *name, NSString *group) {
    NSString *fps = cap(name, @"(\\d+)\\s*fps", 1);
    if (has(name, @"split\\s*screen") && fps) return [NSString stringWithFormat:S2AL(@"cpatch.title.splitScreen"), fps];
    if (has(name, @"present interval|swap interval")) return [NSString stringWithFormat:S2AL(@"cpatch.title.swapInterval"), cap(name, @"->\\s*(\\d+)\\s*fps", 1) ?: @"60"];
    if (has(name, @"enabler") && fps) return [NSString stringWithFormat:S2AL(@"cpatch.title.enabler"), fps];
    if (has(name, @"\\d+\\s*fps in game") && has(name, @"cutscene")) return [NSString stringWithFormat:S2AL(@"cpatch.title.inGame"), fps, cap(name, @"(\\d+)\\s*fps\\s*cutscene", 1) ?: @"30"];
    if (fps) return [NSString stringWithFormat:S2AL(@"cpatch.title.fps"), fps];
    NSString *w = cap(name, @"\\b(\\d{3,4})\\s*x\\s*(\\d{3,4})\\b", 1), *h = cap(name, @"\\b(\\d{3,4})\\s*x\\s*(\\d{3,4})\\b", 2);
    if (w) return [NSString stringWithFormat:S2AL(@"cpatch.title.resolution"), w, h, has(name, @"docked") ? S2AL(@"cpatch.title.docked") : has(name, @"handheld") ? S2AL(@"cpatch.title.handheld") : @""];
    if (has(name, @"depth of field|\\bdof\\b")) return has(name, @"remov|disabl") ? S2AL(@"cpatch.title.dofRemove") : has(name, @"improv") ? S2AL(@"cpatch.title.dofImprove") : S2AL(@"cpatch.title.dofTweak");
    if (has(name, @"dynamic resolution") && has(name, @"disabl|remov")) return S2AL(@"cpatch.title.noDynamicRes");
    if (has(name, @"resolution scaling") && has(name, @"disabl|remov")) return S2AL(@"cpatch.title.noResScaling");
    if (has(name, @"lod\\s*bias")) return S2AL(@"cpatch.title.lodBias");
    if (has(name, @"motion blur") && has(name, @"remov|disabl")) return S2AL(@"cpatch.title.noMotionBlur");
    if (has(name, @"outline") && has(name, @"remov|disabl")) return S2AL(@"cpatch.title.noOutlines");
    if (has(name, @"shadow resolution") && has(name, @"increas|improv")) return S2AL(@"cpatch.title.shadowRes");
    if (has(name, @"cutscene") && has(name, @"effect") && has(name, @"remov|disabl")) return S2AL(@"cpatch.title.noCutsceneFx");
    NSString *ratio = cap(name, @"\\b(21:9|32:9|16:10)\\b", 1);
    if (ratio) return [NSString stringWithFormat:S2AL(@"cpatch.title.ratio"), ratio];
    if (has(name, @"ultra\\s*wide|widescreen|aspect")) return S2AL(@"cpatch.title.ultrawide");
    if (has(name, @"\\bgraphics?\\b")) return S2AL(@"cpatch.title.graphics");
    return [group isEqual:@"widescreen"] ? S2AL(@"cpatch.title.widescreenPatch") : [group isEqual:@"fps"] ? S2AL(@"cpatch.title.fpsPatch") : S2AL(@"cpatch.title.gfxPatch");
}

// 画幅数 → 常见写法（1.6000 → 16:10、2.3333 → 21:9）；对不上的写两位小数
NSString *S2ACPatchRatioText(double a) {
    static const int r[][2] = {{16, 10}, {21, 9}, {32, 9}, {3, 2}, {4, 3}, {16, 9}, {5, 4}, {18, 9}, {19, 9}, {20, 9}, {24, 10}, {48, 9}, {1, 1}};
    for (unsigned i = 0; i < sizeof r / sizeof r[0]; i++) if (fabs(a - (double)r[i][0] / r[i][1]) < 0.005) return [NSString stringWithFormat:@"%d:%d", r[i][0], r[i][1]];
    return [NSString stringWithFormat:@"%.2f:1", a];
}

NSArray<S2ACPatchGroup *> *S2ACPatchGroupsFromTSV(NSString *text) {
    static NSString *const kinds[] = {@"widescreen", @"fps", @"gfx"};
    NSMutableArray<S2ACPatchItem *> *byKind[3] = {[NSMutableArray new], [NSMutableArray new], [NSMutableArray new]};
    NSMutableDictionary<NSString *, S2ACPatchItem *> *seen = [NSMutableDictionary new];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSUInteger i = 1; i < lines.count; i++) {   // 第一行表头：编号 / 模块 / 位 / 类别 / 段名 / 许可 / 来源 / 数据写入 / 缺省开 / 目标帧率（第 10 列，旧表没有）
        NSArray<NSString *> *c = [lines[i] componentsSeparatedByString:@"\t"];
        if (c.count < 9 || !c[0].length) continue;
        if ([c[0] hasPrefix:@"cheat:"]) continue;
        if ([c[0] hasPrefix:@"gfx:"]) continue;   // 画面类（提分辨率 / 画质）iOS 上不打不列（11-13 维护者；运行时 runtime/src/cpatch.c 同样一律不开）   // 编进包的金手指（pack/cpatch.py scan_cheats）在金手指页开关（ios/vpad_cheats.m → Cheats.cs → s2a_cpatch_cheat），不进画面补丁页
        // 自适应画幅一族（pack/cpatch.py adapt_families）的宽 / 窄两份只列一项，开关按族编号（runtime/src/cpatch.c 按当前画幅开其一）
        BOOL adapt = [c[0] hasPrefix:@"wsauto:"];
        // 定画幅的几份宽屏变体（表第 11 列画幅 > 0，pack/cpatch.py）也只列一项，开关写总编号 widescreen:auto（runtime/src/cpatch.c 按当前屏幕比例开最近的一份）
        double fa = [c[0] hasPrefix:@"widescreen:"] && c.count > 10 ? c[10].doubleValue : 0;
        NSString *ident = adapt ? [c[0] substringToIndex:[c[0] rangeOfString:@":" options:NSBackwardsSearch].location] : fa > 0 ? @"widescreen:auto" : c[0];
        NSString *ratio = fa > 0 ? S2ACPatchRatioText(fa) : nil;
        S2ACPatchItem *it = seen[ident];
        if (it) {
            it.defaultOn |= [c[8] isEqual:@"1"]; if (c.count > 9) it.targetFps = MAX(it.targetFps, c[9].integerValue);
            if (ratio) it.name = [it.name stringByAppendingFormat:@" / %@", ratio];
            continue;
        }
        it = [S2ACPatchItem new];
        it.ident = ident; it.name = ratio ?: c[4].length ? c[4] : c[0]; it.license = c[5]; it.defaultOn = [c[8] isEqual:@"1"];
        if (c.count > 9) it.targetFps = c[9].integerValue;
        it.group = adapt || ratio ? @"widescreen" : S2ACPatchClassify(it.name, c[3], c[0]);
        it.title = adapt ? S2AL(@"cpatch.title.adaptive") : ratio ? S2AL(@"cpatch.title.autoRatio") : S2ACPatchTitle(it.name, it.group);
        seen[ident] = it;
        int k = [it.group isEqual:@"widescreen"] ? 0 : [it.group isEqual:@"fps"] ? 1 : 2;
        [byKind[k] addObject:it];
    }
    NSMutableArray<S2ACPatchGroup *> *groups = [NSMutableArray new];
    for (int k = 0; k < 3; k++) {
        if (!byKind[k].count) continue;
        S2ACPatchGroup *g = [S2ACPatchGroup new];
        g.kind = kinds[k]; g.title = k == 0 ? S2AL(@"cpatch.group.widescreen") : k == 1 ? S2AL(@"cpatch.group.fps") : S2AL(@"cpatch.group.gfx"); g.items = byKind[k];
        [groups addObject:g];
    }
    return groups;
}

NSSet<NSString *> *S2ACPatchEnabled(NSArray<S2ACPatchGroup *> *groups, NSUserDefaults *defaults) {
    id v = [defaults objectForKey:S2ACPatchDefaultsKey];
    NSSet<NSString *> *listed = nil;   // nil = 没设过（按表缺省开）
    if ([v isKindOfClass:NSArray.class]) listed = [NSSet setWithArray:v];
    else if ([v isKindOfClass:NSString.class]) listed = [v isEqual:@"none"] ? [NSSet set] : [NSSet setWithArray:[v componentsSeparatedByString:@","]];
    NSMutableSet<NSString *> *on = [NSMutableSet new];
    for (S2ACPatchGroup *g in groups)
        for (S2ACPatchItem *it in g.items)
            if (!it.followsFps60 && (listed ? [listed containsObject:it.ident] : YES)) [on addObject:it.ident];   // 没设过 = 全开（11-13，同 runtime/src/cpatch.c；defaultOn 只作「我方已验」标签）
    return on;
}

void S2ACPatchSetEnabled(NSArray<S2ACPatchGroup *> *groups, NSUserDefaults *defaults, NSString *ident, BOOL on) {
    if ([ident hasPrefix:@"fps:"]) return;
    NSMutableSet<NSString *> *set = [S2ACPatchEnabled(groups, defaults) mutableCopy];
    if (on) [set addObject:ident]; else [set removeObject:ident];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (S2ACPatchGroup *g in groups)
        for (S2ACPatchItem *it in g.items)
            if ([set containsObject:it.ident]) [out addObject:it.ident];
    [defaults setObject:out forKey:S2ACPatchDefaultsKey];
}
