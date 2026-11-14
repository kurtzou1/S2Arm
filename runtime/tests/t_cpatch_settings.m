// 社区补丁设置页数据层（ios/cpatch_model.m）：夹具是 pack/cpatch.py plan 在现行根克隆上真实跑出的 cpatch.tsv（直连线 10-27，pack/cpatch d38209398），
//   runtime/tests/cpatch/{xc3,mk8d,acnh}.cpatch.tsv（10-30 维护者：「数据写入」列换成自造的合成字节，仓库不带上游补丁字节；本单测只读编号 / 类别 / 段名 / 缺省开，不读字节）。期望按表手读：编号前缀定组、缺省开列、写回 S2ACommunityPatches 的口径（同 settings.m → S2A_CPATCH_ON → cpatch.c）
#import <Foundation/Foundation.h>
#import "../../ios/cpatch_model.h"
#include <stdio.h>

static int bad, n;
static void ck(BOOL ok, NSString *what) { n++; if (!ok) { bad++; fprintf(stderr, "✗ %s\n", what.UTF8String); } }
static NSString *rd(const char *dir, NSString *name) {
    return [NSString stringWithContentsOfFile:[@(dir) stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil] ?: @"";
}
static NSString *titles(NSArray<S2ACPatchGroup *> *g) {
    NSMutableArray *a = [NSMutableArray new]; for (S2ACPatchGroup *x in g) [a addObject:[NSString stringWithFormat:@"%@×%lu", x.title, (unsigned long)x.items.count]];
    return [a componentsJoinedByString:@" "];
}
static NSString *sorted(id<NSFastEnumeration> s) {
    NSMutableArray *a = [NSMutableArray new]; for (id x in s) [a addObject:x]; [a sortUsingSelector:@selector(compare:)]; return [a componentsJoinedByString:@","];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *xc3 = rd(argv[1], @"xc3.cpatch.tsv"), *mk8d = rd(argv[1], @"mk8d.cpatch.tsv"), *acnh = rd(argv[1], @"acnh.cpatch.tsv");
        if (!xc3.length || !mk8d.length || !acnh.length) { fprintf(stderr, "✗ 夹具读不到：%s\n", argv[1]); return 2; }
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"s2a.t_cpatch_settings"];
        [d removePersistentDomainForName:@"s2a.t_cpatch_settings"];

        // ① xc3：fps 1 份 + gfx 7 份；编号 gfx: 的画面类 iOS 不打不列（11-13 维护者）→ 只剩「帧率×1」；帧率项跟 60 帧开关、不算开着
        NSArray<S2ACPatchGroup *> *g = S2ACPatchGroupsFromTSV(xc3);
        ck([titles(g) isEqual:@"帧率×1"], [@"① xc3 分组（画面类 gfx: 不列）期望 帧率×1 → " stringByAppendingString:titles(g)]);
        ck(g.count == 1 && g[0].items[0].followsFps60 && g[0].items[0].defaultOn, @"① xc3 帧率项 fps:29c3… 跟 60 帧开关、缺省开（我方已验标签）1");
        ck(S2ACPatchEnabled(g, d).count == 0, @"① xc3 没设过：开着 0 项（帧率项不算）");

        // ⑤ mk8d（名字与类别交叉的真表：5 份都在 ultrawide 目录、编号都是 widescreen:，内容却是分辨率 / 分屏 60 帧 / 景深 / 动态分辨率 / LOD）：
        //   按名字分 → 宽屏 1（2208x1204 Docked）、60 帧 1（split screen 60FPS）、画面 3；缺省开 widescreen:c55265572777508a
        [d removeObjectForKey:S2ACPatchDefaultsKey];
        g = S2ACPatchGroupsFromTSV(mk8d);
        ck([titles(g) isEqual:@"宽屏×1 帧率×1 画面×3"], [@"⑤ mk8d 分组 期望 宽屏×1 帧率×1 画面×3 → " stringByAppendingString:titles(g)]);
        ck(g.count == 3 && !g[1].items[0].followsFps60, @"⑤ mk8d 分屏 60 帧显示在 60 帧组，但编号 widescreen: 不跟 60 帧开关（可单独开关）");
        NSMutableArray *all = [NSMutableArray new]; for (S2ACPatchGroup *x in g) for (S2ACPatchItem *it in x.items) [all addObject:it.ident];
        ck(all.count == 5 && [sorted(S2ACPatchEnabled(g, d)) isEqual:sorted(all)], @"⑤ mk8d 没设过：5 项全开（11-13 起没选过 = 默认开）");
        // ② 关掉 widescreen:c552…：写回其余 4 项（按页面顺序）；③ 再全关 → []
        S2ACPatchSetEnabled(g, d, @"widescreen:c55265572777508a", NO);
        NSArray *w = [d objectForKey:S2ACPatchDefaultsKey]; NSMutableArray *rest = [all mutableCopy]; [rest removeObject:@"widescreen:c55265572777508a"];
        ck([w isEqual:rest], [NSString stringWithFormat:@"② 关一项写回其余 4 项 → %@", w]);
        for (NSString *x in all) S2ACPatchSetEnabled(g, d, x, NO);
        ck([[d objectForKey:S2ACPatchDefaultsKey] isEqual:@[]] && S2ACPatchEnabled(g, d).count == 0, @"④ 全关 → 写回 []、开着 0 项");
        ck(g.count == 3 && [g[0].items[0].license isEqual:@"none(未声明)"], @"⑤ mk8d 许可列原样读出 none(未声明)（页面显示「未声明」）");
        // ⑥ 逗号串与 none 两种旧写法（settings.m 也认字符串）
        [d setObject:@"widescreen:e712a07043861394,widescreen:b26418e7dac5640e" forKey:S2ACPatchDefaultsKey];
        ck([sorted(S2ACPatchEnabled(g, d)) isEqual:@"widescreen:b26418e7dac5640e,widescreen:e712a07043861394"], @"⑥ 逗号串：只开串里两项");
        [d setObject:@"none" forKey:S2ACPatchDefaultsKey];
        ck(S2ACPatchEnabled(g, d).count == 0, @"⑥ none：全关");

        // ⑦ acnh：fps 2 份（sdk / main 两模块、编号不同）→ 「帧率×2」；帧率项不进写回：改了也不写键
        [d removeObjectForKey:S2ACPatchDefaultsKey];
        g = S2ACPatchGroupsFromTSV(acnh);
        ck([titles(g) isEqual:@"帧率×2"], [@"⑦ acnh 分组 期望 帧率×2 → " stringByAppendingString:titles(g)]);
        S2ACPatchSetEnabled(g, d, @"fps:5ccba382ea81b769", YES);
        ck(![d objectForKey:S2ACPatchDefaultsKey] && S2ACPatchEnabled(g, d).count == 0, @"⑦ acnh 帧率项改动不写键、开着 0 项");

        // ⑧ 组序：mk8d + xc3 两张表拼一起 → 宽屏 → 60 帧 → 画面
        NSString *body = [xc3 substringFromIndex:[xc3 rangeOfString:@"\n"].location + 1];   // 去掉 xc3 的表头
        g = S2ACPatchGroupsFromTSV([mk8d stringByAppendingString:body]);
        ck([titles(g) isEqual:@"宽屏×1 帧率×2 画面×3"], [@"⑧ 两表合并组序（xc3 画面类 gfx: 不列）期望 宽屏×1 帧率×2 画面×3 → " stringByAppendingString:titles(g)]);

        // ⑨ 同一编号跨模块多行并成一项（plan 按「编号 × 模块」出行）：mk8d 的 widescreen:c552… 在 sdk 模块再出一行 → 仍 5 项
        NSString *dup = [mk8d stringByAppendingString:@"widescreen:c55265572777508a\tsdk\t0\tultrawide\t2208x1204 Docked\t\t-\t\t0\n"];
        g = S2ACPatchGroupsFromTSV(dup);
        ck([titles(g) isEqual:@"宽屏×1 帧率×1 画面×3"], @"⑨ 同编号两模块：仍 5 项");

        // ⑩ 中文名（对照表，逐条手对表里段名）
        NSDictionary<NSString *, NSString *> *zh = @{
            @"2208x1204 Docked": @"分辨率 2208×1204（主机模式）", @"Force the game run at 60FPS in all split screen modes": @"强制 60 帧（分屏）",
            @"Removed depth of field": @"去景深", @"Disabled dynamic resolution": @"关动态分辨率", @"Improved lodbias": @"改进 LOD 偏移",
            @"60fps in game (dynamic), 30fps Cutscenes WIP10": @"游戏中 60 帧（过场 30 帧）", @"Xenoblade Chronicles 3 - Graphics": @"画面增强",
            @"Disables resolution scaling, Game will display 1080p, and 720p respectively. All cutscenes are 720p": @"关分辨率缩放（固定分辨率）",
            @"Increases the shadow resolution": @"提高阴影分辨率", @"Improves Depth of Field for resolution mods (2K+)": @"改进景深",
            @"Removes effect from cutscenes": @"去过场特效", @"Removes all motion blur": @"去动态模糊", @"Remove outlines around characters": @"去角色描边",
            @"Present interval: swap interval of each queued frame 2 -> 1 (surface setting ignored), 30 -> 60 FPS": @"60 帧（交换间隔 2→1）",
            @"120 FPS enabler hook: both copies of the present method call the enabler routine just before the frame is queued": @"120 帧（启用钩子）"};
        int named = 0;
        for (NSString *t in @[mk8d, xc3, acnh])
            for (S2ACPatchGroup *x in S2ACPatchGroupsFromTSV(t))
                for (S2ACPatchItem *it in x.items) {
                    NSString *want = zh[it.name]; named++;
                    ck([it.title isEqual:want], [NSString stringWithFormat:@"⑩ 中文名「%@」 期望 %@ → %@", it.name, want, it.title]);
                }
        ck(named == 8, [NSString stringWithFormat:@"⑩ 三表共 8 项（xc3 画面类 gfx: 7 项不列）都核了中文名 → %d", named]);
        // ⑪ 名字里没有关键词时看「类别」列，再没有看编号前缀；对照表对不上的用「<组名>补丁」
        ck([S2ACPatchClassify(@"Some patch", @"60fps", @"widescreen:x") isEqual:@"fps"] && [S2ACPatchClassify(@"Some patch", @"", @"widescreen:x") isEqual:@"widescreen"]
           && [S2ACPatchClassify(@"Some patch", @"other-gfx", @"fps:x") isEqual:@"gfx"] && [S2ACPatchTitle(@"Some patch", @"gfx") isEqual:@"画面补丁"],
           @"⑪ 无关键词：类别 60fps → 60 帧、类别空 → 按编号前缀宽屏、other-gfx → 画面；中文名兜底「画面补丁」");
        // ⑫ 编进包的金手指行（编号 cheat:）不进画面补丁页：表里只有一份画面补丁 + 两条金手指 → 1 组 1 项
        NSArray *cg = S2ACPatchGroupsFromTSV(@"编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n"
            "widescreen:a\tmain\t0\tother-gfx\tLOD\t\ta.pchtxt\t\t0\ngfx:z\tmain\t3\tother-gfx\tLOD2\t\tz.pchtxt\t\t0\ncheat:ab:1\tmain\t1\tcheat\tInfinite Health\t\td.txt\t\t0\ncheat:ab:m\tmain\t2\tcheat\tMaster\t\td.txt\t\t0\n");
        ck(cg.count == 1 && ((S2ACPatchGroup *)cg[0]).items.count == 1, [NSString stringWithFormat:@"⑫ 金手指行、gfx: 画面类都不进 iOS 补丁页：1 组 1 项 → %lu 组", (unsigned long)cg.count]);

        // ⑬ 定画幅宽屏变体（第 11 列画幅，11-13）：三份并成一项 widescreen:auto「满屏补丁（按屏幕比例自动选）」、名字列画幅 16:10 / 21:9 / 3:2；没写画幅的那份照旧单列
        NSArray *vg = S2ACPatchGroupsFromTSV(@"编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\n"
            "widescreen:v1\tmain\t0\tultrawide\tHUD 16:10\t\ta\t\t0\t\t1.6000\nwidescreen:v2\tmain\t1\tultrawide\tHUD 21:9\t\tb\t\t0\t\t2.3333\n"
            "widescreen:v3\tmain\t2\tultrawide\tWIP\t\tc\t\t0\t\t1.5000\nwidescreen:x\tmain\t3\tultrawide\tUltrawide\t\td\t\t0\t\t\n");
        NSArray<S2ACPatchItem *> *vi = vg.count ? ((S2ACPatchGroup *)vg[0]).items : @[];
        ck(vg.count == 1 && vi.count == 2 && [vi[0].ident isEqual:@"widescreen:auto"] && [vi[0].title isEqual:@"满屏补丁（按屏幕比例自动选）"]
           && [vi[0].name isEqual:@"16:10 / 21:9 / 3:2"] && [vi[1].ident isEqual:@"widescreen:x"],
           [NSString stringWithFormat:@"⑬ 定画幅变体并成一项 widescreen:auto、名字 16:10 / 21:9 / 3:2，没画幅的单列 → %@", [vi valueForKey:@"ident"]]);

        [d removePersistentDomainForName:@"s2a.t_cpatch_settings"];
        if (bad) { fprintf(stderr, "✗ t_cpatch_settings：%d/%d 项不符\n", bad, n); return 1; }
        printf("✓ t_cpatch_settings：%d 项全符（真 cpatch.tsv 夹具 xc3 / mk8d / acnh：名字分组（与类别交叉）、中文名、缺省开、写回值、帧率项不写、旧写法、组序、同编号去重）\n", n);
        return 0;
    }
}
