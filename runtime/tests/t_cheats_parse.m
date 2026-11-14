// 金手指文本解析（ios/cheats_parse.m s2a_cheats_parse）：期望按 Atmosphere 格式规则手推，不跑被测实现得出。
//   #458：flush block 没有 __block 捕获，任何文件都解析成 0 条（导入一律报「不是 Atmosphere 格式」）；修前 ①②④⑤ 红
#import <Foundation/Foundation.h>
#include <stdio.h>
NSArray<NSDictionary *> *s2a_cheats_parse(NSString *text);
static int fails, checks;
static void check(BOOL ok, const char *what) { checks++; if (ok) printf("过 %s\n", what); else { printf("红 %s\n", what); fails++; } }
static NSString *names(NSArray<NSDictionary *> *r) { return r ? [[r valueForKey:@"name"] componentsJoinedByString:@","] : @"(nil)"; }
int main(void) { @autoreleasepool {
    // 网上常见写法：第一行游戏标题段（没有指令行，不算条目）、空行、CRLF 换行、中间夹一段主代码
    NSString *lf = @"[Game US 1.0.5]\n\n[Money Max]\n580F0000 04824468\n580F1000 00000370\n\n{Master}\n04000000 00000010 00000001\n[Job Points]\n780F0000 00000088\n";
    NSArray *r = s2a_cheats_parse(lf);
    check([names(r) isEqual:@"Money Max,Master,Job Points"], "① LF：标题段不算条目，三条按顺序");
    check(r.count == 3 && ![r[0][@"master"] boolValue] && [r[1][@"master"] boolValue] && ![r[2][@"master"] boolValue], "② 花括号段标主代码，其余不是");
    NSString *crlf = [lf stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
    check([names(s2a_cheats_parse(crlf)) isEqual:@"Money Max,Master,Job Points"], "③ CRLF（Windows 换行）同 LF");
    check([names(s2a_cheats_parse(@"04000000 00000010 00000001\n")) isEqual:@"未命名"], "④ 段外开头的指令归「未命名」");
    NSArray *e = s2a_cheats_parse(@"[]\n1\n{}\n2\n");
    check([names(e) isEqual:@"未命名,主代码"], "⑤ 空名：方括号「未命名」、花括号「主代码」");
    check(s2a_cheats_parse(@"[坏\n04000000 00000010 00000001\n") == nil, "⑥ 括号不闭合整份回 nil");
    check(s2a_cheats_parse(@"[只有标题]\n\n").count == 0, "⑦ 只有标题没有指令：0 条（导入时判坏）");
    // 写死地址（Atmosphere 指令表手判）：0 / 1 型第 3 位区号非 0、5 型区号非 0 且第 5 位为 0 才算；主程序区、指针链、寄存器基址不算
    NSArray *fx = s2a_cheats_parse(@"[Coins]\n02100000 5C27B318 0000270f\n[Health]\n11160000 5C3BE7DC 00000000\n01100000 5C3BE7DC 00000006\n20000000\n"
        "[Moonjump]\n80000002\n580F0000 0149D940\n580F1000 00000090\n640F0000 00000000 42000000\n20000000\n[Code]\n040E0000 00C72FB8 00000002\n[HeapPtr]\n58100000 00001000\n");
    check([[[fx valueForKey:@"fixed"] componentsJoinedByString:@","] isEqual:@"1,1,0,0,1"], "⑧ 写死地址：金币 / 血量 / 堆指针是，超级跳指针链 / 改代码不是");
    // 分组（社区约定：只有一行 20000000 = 分组开始，只有一行 20000001 = 分组结束；多行里带 20000000 的照旧是普通条目）
    NSArray *fo = s2a_cheats_parse(@"[Character]\n20000000\n[Inf HP]\n04000000 00000010 00000001\n[Damage]\n20000000\n[x2]\n04000000 00000020 00000002\n20000000\n"
        "[Damage end]\n20000001\n[Character end]\n20000001\n");
    check([[[fo valueForKey:@"folder"] componentsJoinedByString:@","] isEqual:@"1,0,1,0,2,2"], "⑨ 分组：开始 1、普通 0、结束 2；多行里带 20000000 的是普通条目");
    if (fails) { fprintf(stderr, "t_cheats_parse：%d/%d 项不符\n", fails, checks); return 1; }
    printf("✓ t_cheats_parse：%d 项（LF / CRLF、标题段、主代码、空名、坏括号）\n", checks);
} return 0; }
