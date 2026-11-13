// 每键外观（ios/vpad_layout.m）：大小 / 透明度 / 隐藏 / 配色的存储，和按倍率取键。期望按规则手写
#import <Foundation/Foundation.h>
#include <math.h>
#import "../../ios/vpad_layout.h"
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
static S2AVPadKeyStyle ST(CGFloat a, CGFloat b, BOOL c) { S2AVPadKeyStyle s = {a, b, c}; return s; }
int main(void) { @autoreleasepool {
    NSURL *d = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    S2AVPadLayoutStore *s = [[S2AVPadLayoutStore alloc] initWithDirectory:d]; NSError *e;
    S2AVPadKeyStyle k = [s keyStyle:@"A"];
    CK(k.scale == 1 && k.opacity == 1 && !k.hidden && s.keyTheme == 0, "① 没设过：1 / 1 / 不隐藏，配色默认");
    CK(![s setKeyStyle:ST(4.1, 1, NO) forKey:@"A" persist:YES error:&e] && ![s setKeyStyle:ST(1, 0.1, NO) forKey:@"A" persist:YES error:&e] && ![s setKeyTheme:5 error:&e], "② 超范围拒绝：大小 4.1（上限 4）、透明度 0.1、配色 5");
    CK([s setKeyStyle:ST(1.5, 0.5, NO) forKey:@"A" persist:YES error:&e] && [s setKeyStyle:ST(1, 1, YES) forKey:@"B" persist:YES error:&e] && [s setKeyTheme:2 error:&e], "③ 合法值写入成功");
    S2AVPadLayoutStore *r = [[S2AVPadLayoutStore alloc] initWithDirectory:d]; k = [r keyStyle:@"A"];
    CK(k.scale == 1.5 && k.opacity == 0.5 && [r keyStyle:@"B"].hidden && r.keyTheme == 2, "④ 重开同一目录仍在");
    [s setKeyStyle:ST(0.8, 1, NO) forKey:@"A" persist:NO error:&e]; r = [[S2AVPadLayoutStore alloc] initWithDirectory:d];
    CK([s keyStyle:@"A"].scale == 0.8 && [r keyStyle:@"A"].scale == 1.5, "⑤ persist=NO 只改内存，盘上还是旧值");
    NSDictionary *snap = [s keyStyleSnapshot]; [s setKeyStyle:ST(1.2, 1, NO) forKey:@"A" persist:YES error:&e]; [s restoreKeyStyleSnapshot:snap error:&e];
    CK([s keyStyle:@"A"].scale == 0.8, "⑥ 快照还原（编辑取消）");
    CK(s.globalScale == 1 && s.globalOpacity == 1 && ![s setGlobalScale:4.1 opacity:1 persist:YES error:&e] && [s setGlobalScale:1.5 opacity:0.4 persist:YES error:&e], "⑪ 整体值缺省 1，超范围拒绝，合法写入");
    r = [[S2AVPadLayoutStore alloc] initWithDirectory:d];
    NSDictionary *gs = [r keyScalesIncludingHidden:NO];
    CK(r.globalScale == 1.5 && r.globalOpacity == 0.4 && fabs([gs[@"*"] doubleValue] - 1.5) < 1e-9 && fabs([gs[@"A"] doubleValue] - 1.2) < 1e-9, "⑫ 重开仍在；未单设的键 1.5，A 键 0.8×1.5=1.2");
    // #372：滑杆单精度，拉到头的 1.6f / 0.2f 换成双精度越过范围一点点 → 原先拒收；按界面精度取整后收下，存的就是 1.6 / 0.2
    CK([s setKeyStyle:ST((float)1.6, (float)0.2, NO) forKey:@"C" persist:YES error:&e] && [s keyStyle:@"C"].scale == 1.6 && [s keyStyle:@"C"].opacity == 0.2, "⑭ 滑杆拉到头（1.6f / 0.2f）收下，存 1.6 / 0.2（%s）", e.localizedDescription.UTF8String ?: "");
    CK([s setGlobalScale:(float)1.6 opacity:(float)0.2 persist:YES error:&e] && s.globalScale == 1.6 && [[[S2AVPadLayoutStore alloc] initWithDirectory:d] keyStyle:@"C"].scale == 1.6, "⑮ 整体大小拉到头同样收下；重开读回 1.6");
    // #372：上限从 1.6 放到 4（连打类游戏要更大的键）：每键、整体拉到 4 都收下，重开读回仍是 4
    CK([s setKeyStyle:ST(S2A_VPAD_SCALE_MAX, 1, NO) forKey:@"D" persist:YES error:&e] && [s setGlobalScale:S2A_VPAD_SCALE_MAX opacity:1 persist:YES error:&e]
       && [[[S2AVPadLayoutStore alloc] initWithDirectory:d] keyStyle:@"D"].scale == 4 && [[S2AVPadLayoutStore alloc] initWithDirectory:d].globalScale == 4, "⑮ 每键 / 整体大小拉到 4 收下、重开读回 4");
    [s resetKeyStyles:&e]; CK(s.globalScale == 1 && s.globalOpacity == 1 && [s keyStyle:@"A"].scale == 1, "⑬ 恢复默认清掉整体值和单键值");
    CGRect safe = CGRectMake(0, 0, 800, 400); S2AVPadLayout *l = [S2AVPadLayout defaultForSafeRect:safe]; NSDictionary *b = l.buttons[0]; NSString *bid = b[@"id"];
    CGRect f = [l frameForButton:b safeRect:safe]; CGPoint center = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
    CK([[l buttonAt:center safeRect:safe slop:0 scales:@{bid: @0}] isEqualToString:bid] == NO, "⑦ 倍率 0（隐藏）的键点不到");
    CGPoint edge = CGPointMake(CGRectGetMaxX(f) + f.size.width * 0.2, center.y);
    CK(![[l buttonAt:edge safeRect:safe slop:0 scales:nil] isEqualToString:bid] && [[l buttonAt:edge safeRect:safe slop:0 scales:@{bid: @1.6}] isEqualToString:bid], "⑧ 放大 1.6 倍：框外一点变得点得到（绕中心放大）");
    CGPoint in2 = CGPointMake(CGRectGetMaxX(f) - f.size.width * 0.05, center.y);
    CK([[l buttonAt:in2 safeRect:safe slop:0 scales:nil] isEqualToString:bid] && ![[l buttonAt:in2 safeRect:safe slop:0 scales:@{bid: @0.6}] isEqualToString:bid], "⑨ 缩小 0.6 倍：原框边缘点不到了");
    NSURL *bad2 = [d URLByAppendingPathComponent:@".key_style.json"]; [@"{坏" writeToURL:bad2 atomically:YES encoding:NSUTF8StringEncoding error:nil]; r = [[S2AVPadLayoutStore alloc] initWithDirectory:d];
    CK([r keyStyle:@"A"].scale == 1 && r.keyTheme == 0, "⑩ 文件损坏回默认，不崩");
    if (bad) printf("t_vpad_key_style：%d 项不过\n", bad); else printf("✓ t_vpad_key_style：15 项\n");
    return bad != 0;
} }
