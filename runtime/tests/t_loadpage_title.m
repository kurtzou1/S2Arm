// 加载页游戏名的取法（ios/loadpage_title.h，#502）：期望手写。合成 control.nacp：美式英语 0「Gardening」、法语 3「Jardin」、简中 14「花园」
#import <Foundation/Foundation.h>
#include <stdio.h>
#import "../../ios/loadpage_title.h"
static int fails;
static void expect(const char *what, NSString *want, NSString *got) {
    int ok = (!want && !got) || [want isEqualToString:got];
    printf("%s %s 期望 %s → 真结果 %s\n", ok ? "PASS" : "FAIL", what, want ? want.UTF8String : "（无）", got ? got.UTF8String : "（无）"); fails += !ok;
}
static NSData *nacp(NSDictionary<NSNumber *, NSString *> *t) {
    NSMutableData *d = [NSMutableData dataWithLength:0x4000];
    for (NSNumber *k in t) { const char *s = t[k].UTF8String; memcpy((char *)d.mutableBytes + k.intValue * 0x300, s, strlen(s)); }
    return d;
}
int main(void) { @autoreleasepool {
    NSData *n = nacp(@{@0: @"Gardening", @3: @"Jardin", @14: @"花园"});
    expect("① 有封面名：直接用（同封面）", @"Mon jardin", s2a_loadpage_title(@"Mon jardin", n, @[@"zh-Hans-CN"]));
    expect("② 封面名全是空白：不算", @"Jardin", s2a_loadpage_title(@"  ", n, @[@"fr-FR"]));
    expect("③ 法语系统：取法语槽", @"Jardin", s2a_loadpage_title(nil, n, @[@"fr-FR", @"en-US"]));
    expect("④ 英语系统：取美式英语槽", @"Gardening", s2a_loadpage_title(nil, n, @[@"en-US"]));
    expect("⑤ 简中系统：取简中槽", @"花园", s2a_loadpage_title(nil, n, @[@"zh-Hans-CN"]));
    expect("⑥ 日语系统、游戏没有日文标题：按第二首选语言（法语）", @"Jardin", s2a_loadpage_title(nil, n, @[@"ja-JP", @"fr-FR"]));
    expect("⑦ 首选语言都没有对应标题：退美式英语", @"Gardening", s2a_loadpage_title(nil, n, @[@"ja-JP", @"de-DE"]));
    expect("⑧ 只有日文标题：法语系统也取它", @"ほの暮しの庭", s2a_loadpage_title(nil, nacp(@{@2: @"ほの暮しの庭"}), @[@"fr-FR"]));
    expect("⑨ 加拿大法语优先取加拿大法语槽，没有就退通用法语之外的首选", @"Jardin", s2a_loadpage_title(nil, n, @[@"fr-CA", @"fr-FR"]));
    expect("⑩ nacp 太短、没封面名：取不到", nil, s2a_loadpage_title(nil, [NSData dataWithBytes:"x" length:1], @[@"fr-FR"]));
    expect("⑪ 语言代码映射：zh-TW → 繁中槽 13", @"13", [NSString stringWithFormat:@"%d", s2a_nacp_slot_for_language(@"zh-TW")]);
    if (fails) { printf("✗ t_loadpage_title：%d 项不符\n", fails); return 1; }
    printf("✓ t_loadpage_title：加载页游戏名（封面名优先、按系统语言取 nacp）全过\n"); return 0;
} }
