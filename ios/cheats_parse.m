// 金手指文本解析（面板列条目、导入前校验都用它；只依赖 Foundation，Mac 单测 runtime/tests/t_cheats_parse.m 直接编）。
//   规则与服务层 services/S2A.Services/Cheats.cs Parse 一致：[名字] 普通条目，{名字} 主代码，其余非空行是指令；括号不闭合整份回 nil。
//   cur / master / lines 必须是 __block：flush 是 block，不加则捕获的是创建那一刻的值（lines 恒为 0），任何文件都解析成 0 条、导入一律报「不是 Atmosphere 格式」（#458）
#import <Foundation/Foundation.h>
#include <ctype.h>

// 写死地址（与 pack/jobs/cheats.py fixed_address 同一规则）：0 / 1 型第 3 位区号非 0、5 型区号非 0 且第 5 位为 0 = 按堆等区起点 + 固定偏移直接寻址，
//   赌游戏堆内排布与作者当年一致，可能不生效；面板在条目下标出来
static BOOL fixed_address(NSString *l) {
    if (l.length < 8) return NO;
    for (NSUInteger i = 0; i < 8; i++) if (!isxdigit([l characterAtIndex:i])) return NO;
    if (l.length > 8 && ![NSCharacterSet.whitespaceCharacterSet characterIsMember:[l characterAtIndex:8]]) return NO;
    unichar t = [l characterAtIndex:0], m = [l characterAtIndex:2], s = [l characterAtIndex:4];
    if (t == '0' || t == '1') return m != '0';
    if (t == '5') return s == '0' && m != '0';
    return NO;
}
NSArray<NSDictionary *> *s2a_cheats_parse(NSString *text);   // 对外声明在 ios/vpad_cheats.h（那边带 UIKit，这里不引）
NSArray<NSDictionary *> *s2a_cheats_parse(NSString *text) {
    // folder：社区约定的分组标记（11-13，社区金手指库通行写法）：一条只有一行 20000000 = 分组开始（名字是组名）、只有一行 20000001 = 分组结束；
    //   这两种不改任何东西，面板画成分组标题 / 不画，不当开关（folder 1 = 开始、2 = 结束、0 = 普通条目）
    NSMutableArray *out = [NSMutableArray array]; __block NSString *cur = nil; __block BOOL master = NO; __block NSInteger lines = 0; __block BOOL fixed = NO; __block NSString *only = nil;
    void (^flush)(void) = ^{ if (lines > 0) {
        int folder = lines == 1 && !master ? ([only isEqual:@"20000000"] ? 1 : [only isEqual:@"20000001"] ? 2 : 0) : 0;
        [out addObject:@{@"name": cur ?: @"未命名", @"master": @(master), @"fixed": @(fixed), @"folder": @(folder)}]; } };
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!l.length) continue;
        unichar c = [l characterAtIndex:0];
        if (c == '[' || c == '{') {
            unichar close = c == '[' ? ']' : '}';
            if (l.length < 2 || [l characterAtIndex:l.length - 1] != close) return nil;
            flush(); lines = 0; fixed = NO; only = nil; master = c == '{';
            cur = [[l substringWithRange:NSMakeRange(1, l.length - 2)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!cur.length) cur = master ? @"主代码" : @"未命名";
        } else { lines++; fixed = fixed || fixed_address(l); only = l.uppercaseString; }
    }
    flush();
    return out;
}
