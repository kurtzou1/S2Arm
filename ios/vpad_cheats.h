// 金手指面板（齿轮菜单「金手指」进入）：导入 Atmosphere 格式 txt、逐条开关；执行在服务层 services/S2A.Services/Cheats.cs
#import <UIKit/UIKit.h>

// 按本款文档根（$S2A_DOCS，没有则 App Documents）/cheats 读写；closed 在面板关掉后回调（虚拟手柄恢复触控）
void s2a_cheats_present(UIViewController *host, void (^closed)(void));
// 金手指页本身（推进别的导航里用，S 级优化组；pushed = YES 时不放「完成」，用导航的返回）
UIViewController *s2a_cheats_controller(BOOL pushed);
// 纯数据层（单测可编）：解析一份 txt，回 @[@{@"name":…, @"master":@YES/NO}]；方括号 / 花括号不闭合回 nil
NSArray<NSDictionary *> *s2a_cheats_parse(NSString *text);
