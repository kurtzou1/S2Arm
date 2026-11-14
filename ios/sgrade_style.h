// S 级优化的金色样式（游戏内整页设置的「S 级优化」组、快捷菜单的「S 级优化」子菜单；11-13 维护者：各界面入口与 UI 统一一次）：
//   金色毛玻璃双色 S（上半香槟金、下半玫瑰金，同启动器出包页与游戏库设置；图在库界面资源包 S2ArmShellUI_ShellUI.bundle/s-gold.png）、
//   香槟金到玫瑰金的标题、BETA 小标、一句崩溃兜底说明
#import <UIKit/UIKit.h>
UIImage *s2a_sgrade_image(void);           // 金色 S；包里没有（不带库界面的旧壳）退回金色的 sparkles 图标
UIColor *s2a_sgrade_gold(void);            // 主金（行图标、强调）
UIView *s2a_sgrade_header(CGFloat width);  // 分组头：S + 渐变标题 + BETA + 说明；width 是表格宽
