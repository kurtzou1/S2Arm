// 虚拟手柄 2D 布局（#268，11-09 维护者定稿 cmdr/assets/268_vpad_2d_对比_1109.png；ios/vpad_layout.m twoDForSafeRect / dpadDirectionsAt）
// 跑：make native-test-vpad_2d。期望按定稿几何手算，不跑被测实现推导：
//   安全区 832×419（短边 419）：十字键 56 点 = 56/419、中心 (0.17×832, 0.66×419) = (141.44, 276.54)、间距 52；ABXY 64 点；没有 LS / RS、没有摇杆
//   八方向圆区：圆心 = 四个方向键中心平均 = (141.44, 276.54)，半径 = 52 + 56/2 = 80，正中心 0.2×80 = 16 以内不算方向
#import <Foundation/Foundation.h>
#include <math.h>
#import "../../ios/vpad_layout.h"
static int bad;
#define CK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); printf("\n"); } while (0)
static NSDictionary *btn(S2AVPadLayout *l, NSString *i) { for (NSDictionary *b in l.buttons) if ([b[@"id"] isEqualToString:i]) return b; return nil; }
int main(void) {
    @autoreleasepool {
        CGRect safe = CGRectMake(0, 0, 832, 419); NSError *e;
        S2AVPadLayout *l = [S2AVPadLayout twoDForSafeRect:safe];
        CK(l.buttons.count == 14 && !btn(l, @"LS") && !btn(l, @"RS") && l.sticks.count == 0, "① 14 个键、没有 L3 / R3、没有摇杆");
        CK(fabs([btn(l, @"UP")[@"width"] doubleValue] - 56.0 / 419) < 1e-9 && fabs([btn(l, @"A")[@"width"] doubleValue] - 64.0 / 419) < 1e-9, "② 十字键 56 点、ABXY 64 点（按短边 419 折算）");
        CK([S2AVPadLayout isBuiltinIdentifier:S2AVPadLayout2DIdentifier], "③ 2d 是内置方案（不对应磁盘文件）");
        S2AVPadLayout *back = [S2AVPadLayout readData:[l JSONData:&e] error:&e];
        CK(back && back.sticks.count == 0, "④ 0 根摇杆的布局按生产校验读得回（导出 / 再导入）（%s）", back ? "" : e.localizedDescription.UTF8String);
        S2AVPadLayout *mine = [l layoutWithButtonCenters:@{@"A": @[@700, @300]} safeRect:safe identifier:S2AVPadLayoutMineIdentifier name:@"我的布局" error:&e];
        CK(mine && mine.sticks.count == 0, "⑤ 在 2D 上拖完存「我的布局」成功（%s）", mine ? "" : e.localizedDescription.UTF8String);
        CGFloat cx = 0.17 * 832, cy = 0.66 * 419;
        struct { CGFloat dx, dy; int want; const char *what; } cases[] = {
            {60, 0, 8, "右"}, {42, 42, 8 | 2, "右下（斜角两位）"}, {0, -60, 1, "上"}, {-42, -42, 4 | 1, "左上"},
            {-60, 0, 4, "左"}, {0, 60, 2, "下"}, {-42, 42, 4 | 2, "左下"}, {42, -42, 8 | 1, "右上"}, {5, 5, 0, "正中心（半径 7 < 16）不算方向"}, {90, 0, -1, "圆区外（90 > 80）"}};
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            int got = [l dpadDirectionsAt:CGPointMake(cx + cases[i].dx, cy + cases[i].dy) safeRect:safe];
            CK(got == cases[i].want, "⑥ 十字键%s：期望 %d → 实得 %d", cases[i].what, cases[i].want, got);
        }
        // 分屏下区带有非零原点；八方向与中心 / 圆外判据仍以当前安全区为准，不沿用转屏前的原点。
        CGRect lower = CGRectMake(16, 400, 832, 419);
        S2AVPadLayout *lower2D = [S2AVPadLayout twoDForSafeRect:lower];
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            int got = [lower2D dpadDirectionsAt:CGPointMake(16 + cx + cases[i].dx, 400 + cy + cases[i].dy) safeRect:lower];
            CK(got == cases[i].want, "⑥ 下区非零原点十字键%s：期望 %d → 实得 %d", cases[i].what, cases[i].want, got);
        }
        S2AVPadLayout *d = [S2AVPadLayout defaultForSafeRect:safe];
        CK([d dpadDirectionsAt:CGPointMake(0.235 * 832, 0.80 * 419) safeRect:safe] == -1, "⑦ 有摇杆的默认布局不走八方向（仍按单个方向键）");
        NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"vpad_2d_" stringByAppendingString:NSUUID.UUID.UUIDString]];
        S2AVPadLayoutStore *s = [[S2AVPadLayoutStore alloc] initWithDirectory:dir];
        BOOL picked = [s selectIdentifier:S2AVPadLayout2DIdentifier error:&e];
        S2AVPadLayoutStore *r = [[S2AVPadLayoutStore alloc] initWithDirectory:dir];
        CK(picked && [r.selectedIdentifier isEqualToString:S2AVPadLayout2DIdentifier] && ![r selectedLayout:&e], "⑧ 选 2D 记得住（重开仍是 2d），选中项不读文件（按屏幕现算）");
        BOOL backDefault = [r selectIdentifier:S2AVPadLayoutDefaultIdentifier error:&e];
        CK(backDefault && [[[S2AVPadLayoutStore alloc] initWithDirectory:dir].selectedIdentifier isEqualToString:S2AVPadLayoutDefaultIdentifier], "⑨ 切回默认布局一键");
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    }
    if (bad) printf("✗ t_vpad_2d：%d 项不通\n", bad); else printf("✓ t_vpad_2d：全部通过\n");
    return bad ? 1 : 0;
}
