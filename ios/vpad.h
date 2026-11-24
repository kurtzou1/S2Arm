#pragma once
#import <UIKit/UIKit.h>

// Main thread only. The layout action is available only when this controller
// owns an attached touch view; it dismisses the shared menu before presenting.
void s2a_vpad_attach(UIView *root);
void s2a_vpad_add_layout_action(UIAlertController *menu, UIViewController *controller);
void s2a_vpad_set_settings_open(BOOL open);
// Main thread only. Persist the preference and immediately remove a disabled HUD.
void s2a_vpad_set_touch_hud(BOOL enabled);
// 「键 / 触」切换（vpad.m 注释）：manual = S2AVPadTouchSwitch（vpad_layout.h）：1 = 玩家手动保存（持久化 + 记手动选过）、
//   2 = 玩家手动只这一局（不写盘，手动选过也切）、0 = 自动（只本次运行，手动选过时不切）；
//   主线程同步返回 1 / 0 / -1，别的线程派主线程返回 2；读当前方案 1 触屏 / 0 按键 / -1 没挂；玩家手动选过 1 / 0 / -1
int s2a_vpad_set_touch_only(int on, int manual, const char *why);
int s2a_vpad_touch_only(void);
int s2a_vpad_touch_user_chose(void);
BOOL s2a_vpad_has_layouts(void);
NSString *s2a_vpad_layout_name(void);
UIViewController *s2a_vpad_layout_controller(void);
