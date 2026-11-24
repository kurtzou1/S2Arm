// 包里 AppIcon 的文件名（ios/bundle_icon.h s2a_bundle_icon_name，加载页 game_icon 的退路）。期望手写：
//   ① iPhone 包形状 {CFBundlePrimaryIcon: {CFBundleIconFiles: ["AppIcon60x60"]}} → "AppIcon60x60"
//   ② Apple TV 包形状 {CFBundlePrimaryIcon: "App Icon"}（品牌资源名，字符串）→ "App Icon"，不抛异常
//   ③ 缺 CFBundleIcons（nil）→ nil
//   ④ 类型不对（CFBundleIcons 是字符串；CFBundleIconFiles 是字典；空数组；空字符串）→ 都是 nil、不抛异常
//   旧写法 icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] 遇 ② 抛 NSInvalidArgumentException（Apple TV 点开始闪退）：红
#import <Foundation/Foundation.h>
#import "../../ios/bundle_icon.h"
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
static NSString *safe(id icons) { @try { return s2a_bundle_icon_name(icons) ?: @"(nil)"; } @catch (NSException *e) { return [@"抛异常 " stringByAppendingString:e.name]; } }
int main(void) { @autoreleasepool {
    NSString *r = safe(@{@"CFBundlePrimaryIcon": @{@"CFBundleIconFiles": @[@"AppIcon60x60"]}});
    CK([r isEqualToString:@"AppIcon60x60"], "① iPhone 包形状 → AppIcon60x60（实得 %s）", r.UTF8String);
    r = safe(@{@"CFBundlePrimaryIcon": @"App Icon"});
    CK([r isEqualToString:@"App Icon"], "② Apple TV 包形状（品牌名字符串）→ App Icon、不抛异常（实得 %s）", r.UTF8String);
    r = safe(nil);
    CK([r isEqualToString:@"(nil)"], "③ 缺 CFBundleIcons → nil（实得 %s）", r.UTF8String);
    NSArray *odd = @[@"x", @{@"CFBundlePrimaryIcon": @{@"CFBundleIconFiles": @{@"a": @1}}}, @{@"CFBundlePrimaryIcon": @{@"CFBundleIconFiles": @[]}}, @{@"CFBundlePrimaryIcon": @""}];
    int okn = 0; for (id o in odd) if ([safe(o) isEqualToString:@"(nil)"]) okn++;
    CK(okn == 4, "④ 类型不对的 4 种 → 都是 nil、不抛异常（实得 %d / 4）", okn);
    printf("%s t_bundle_icon：%d 不通\n", bad ? "✗" : "✓", bad);
    return bad != 0;
} }
