// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 触控板 / 鼠标（#1869 PR 2）：GCMouse 采按键与位移 → ios/mouse_map.h（规则同 Mac macos/front_mac.m）。
//   鼠标键与键盘一起映射（keyboard.m publish 调 s2a_mouse_map，走同一条发布路），位移在 vpad.m 的两个读导出里加进右摇杆（同 Mac take_mouse_delta）。
//   「转动视角」：按键模式下虚拟按键收起时，点左键请求系统指针锁定（游戏页 prefersPointerLocked 问这里），系统给了才收位移；
//   Esc / 切后台 / 碰屏幕交回 / 切仅触屏 / 改成「不起作用」 / 开改键页 / 关掉「使用鼠标 / 触控板」都释放，回来要再点一下（同 Mac 失焦释放）。
//   不加 UIApplicationSupportsIndirectInputEvents：11-21 真机（iPadOS 27.3，妙控键盘）没有这个键时触控板点击照样是 UITouchTypeIndirectPointer、
//   带 buttonMask，GCMouse 也照样认得出触控板，所以不碰全局开关（游戏库 / 设置等界面的触摸不受影响）。
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include "keyboard.h"
#include "mouse_map.h"
#include "native.h"
#include <stdatomic.h>

int s2a_vpad_touch_only(void);   // vpad.m：1 仅触屏、0 按键、-1 没挂
// 弱链接[lab]：s2a_ios_touch_declared
int s2a_ios_touch_declared(void) __attribute__((weak_import));   // touch_config.m：游戏声明过触屏配置（输入工作台不编它，取不到当没声明）

static dispatch_queue_t g_queue;            // = controller.m 的输入队列；GCMouse 回调挂它
static __weak UIView *g_root;               // 游戏页根视图：请求锁定时找它的控制器
static _Atomic int g_mice;                  // 接着几只鼠标 / 触控板
static _Atomic unsigned g_raw;              // 按着的鼠标键（位 i = 按键 i），不管算不算数
static _Atomic unsigned g_counted;          // 按着、算数的鼠标键（交给 keyboard.m 映射）
static _Atomic int g_wanted, g_locked;      // 想锁 / 系统给锁了
static _Atomic int g_camera = 1, g_left_bound = 1, g_map_default = 1, g_recenter = 1;   // keyboard.m 装键位时同步（主线程也要读）
static _Atomic int g_off;                   // 改键页「使用鼠标 / 触控板」关掉了（#2072，同上由 keyboard.m 同步）
static double g_sens_x = 1, g_sens_y = 1; static int g_inv_x, g_inv_y;   // 只在输入队列上读写
static _Atomic int64_t g_acc_x, g_acc_y, g_hold_x, g_hold_y;              // 攒下的位移 / 不回中的保持量（HID 读线程消费）

static s2a_mouse_state current_state(void) {
    s2a_mouse_state s = {
        .touch_only = s2a_vpad_touch_only() == 1,
        .hidden = s2a_ios_inputs_hidden(),
        .locked = atomic_load(&g_locked),
        .camera = atomic_load(&g_camera),
        .declared_default = s2a_ios_touch_declared && s2a_ios_touch_declared() && atomic_load(&g_map_default),
        .left_bound = atomic_load(&g_left_bound),
        .off = atomic_load(&g_off),
    };
    return s;
}
static void reset_motion(void) {
    atomic_store(&g_acc_x, 0); atomic_store(&g_acc_y, 0); atomic_store(&g_hold_x, 0); atomic_store(&g_hold_y, 0);
}
// 主线程：让游戏页重新问一次 prefersPointerLocked
static void ask_system(void) {
    UIViewController *vc = g_root.window.rootViewController;
    [vc setNeedsUpdateOfPrefersPointerLocked];
}
static void unlock(const char *why) {
    if (!atomic_exchange(&g_wanted, 0) && !atomic_load(&g_locked)) return;
    reset_motion();
    LOG("鼠标视角：释放（%s）", why);
    if (NSThread.isMainThread) ask_system(); else dispatch_async(dispatch_get_main_queue(), ^{ ask_system(); });
}
static void request_lock(void) {
    if (atomic_exchange(&g_wanted, 1)) return;
    reset_motion();
    dispatch_async(dispatch_get_main_queue(), ^{ if (atomic_load(&g_wanted)) ask_system(); });
}
static const char *const kLeftActions[] = {"交给 UIKit 当手指", "当触屏点", "只锁定", "照映射发按键"};
static CFTimeInterval g_down_at[S2A_MOUSE_BUTTONS];
static int g_said;   // 前 12 次按键各记一行（按下做了什么、按了多久）：真机上「点了没反应」时分得清是系统没给事件、规则没让发，还是按得太短看不见
// 一个鼠标键变了（输入队列）
static void button_changed(int b, BOOL down) {
    unsigned bit = 1u << b, before = atomic_load(&g_counted);
    if (!down) {
        if (g_said <= 12 && g_down_at[b] > 0) LOG("鼠标：键 %d 松开（按了 %.0f ms）", b, (CACurrentMediaTime() - g_down_at[b]) * 1000);
        g_down_at[b] = 0;
        atomic_fetch_and(&g_raw, ~bit);
        if (!(before & bit)) return;
        atomic_fetch_and(&g_counted, ~bit);
        s2a_ios_keyboard_mouse_changed(0);
        return;
    }
    if (atomic_fetch_or(&g_raw, bit) & bit) return;
    s2a_mouse_state s = current_state();
    int counts;
    if (b == 0) {
        s2a_mouse_left_action a = s2a_mouse_left(s);
        if (a == S2A_MOUSE_LOCK) request_lock();
        counts = a == S2A_MOUSE_BUTTON;   // 交给 UIKit / 当触屏 / 只锁定：这一下不发按键（同 Mac mouseDown）
        if (++g_said <= 12) LOG("鼠标：左键按下 → %s", kLeftActions[a]);
    } else {
        counts = s2a_mouse_other_counts(s);
        if (++g_said <= 12) LOG("鼠标：键 %d 按下 → %s", b, counts ? "照映射发按键" : "不进游戏（虚拟按键显示着）");
    }
    g_down_at[b] = CACurrentMediaTime();
    if (!counts) return;
    atomic_fetch_or(&g_counted, bit);
    s2a_ios_keyboard_mouse_changed(1);
}
static void moved(float dx, float dy) {
    if (!atomic_load(&g_locked) || !atomic_load(&g_camera) || atomic_load(&g_off)) return;   // 同 Mac mouseMoved：锁定且转动视角才收；关了鼠标后系统收回锁定前的几拍也不收
    s2a_input_config c = {0};
    c.sensitivity_x = g_sens_x; c.sensitivity_y = g_sens_y; c.invert_x = g_inv_x; c.invert_y = g_inv_y;
    int64_t ox, oy;
    s2a_mouse_delta(&c, dx, dy, &ox, &oy);   // GCMouse：dx 向右、dy 向上为正
    atomic_fetch_add(&g_acc_x, ox); atomic_fetch_add(&g_acc_y, oy);
}
static void attach_mouse(GCMouse *mouse) {
    if (!mouse || !g_queue) return;
    mouse.handlerQueue = g_queue;
    GCMouseInput *in = mouse.mouseInput;
    in.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { (void)b; (void)v; button_changed(0, p); };
    in.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { (void)b; (void)v; button_changed(1, p); };
    in.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { (void)b; (void)v; button_changed(2, p); };
    NSArray<GCControllerButtonInput *> *aux = in.auxiliaryButtons;
    for (NSUInteger i = 0; i < aux.count && i < 2; i++) {
        int b = 3 + (int)i;
        aux[i].pressedChangedHandler = ^(GCControllerButtonInput *x, float v, BOOL p) { (void)x; (void)v; button_changed(b, p); };
    }
    in.mouseMovedHandler = ^(GCMouseInput *m, float dx, float dy) { (void)m; moved(dx, dy); };
    atomic_fetch_add(&g_mice, 1);
    LOG("鼠标：已连接（%s，右键 %d、中键 %d、侧键 %d）", mouse.vendorName.UTF8String ?: "GCMouse", in.rightButton != nil, in.middleButton != nil, (int)aux.count);
}
static void release_buttons(void) {   // 输入队列
    atomic_store(&g_raw, 0);
    if (atomic_exchange(&g_counted, 0)) s2a_ios_keyboard_mouse_changed(0);
}

void s2a_ios_mouse_attach(UIView *root) {
    if (g_queue) return;
    g_queue = s2a_ios_input_queue();
    g_root = root;
    if (!g_queue) return;
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if ([n.object isKindOfClass:GCMouse.class]) attach_mouse(n.object);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n;
        int left = (int)GCMouse.mice.count;
        atomic_store(&g_mice, left);
        LOG("鼠标：已断开（还接着 %d 只）", left);
        if (!left) { unlock("鼠标断开"); dispatch_async(g_queue, ^{ release_buttons(); }); }
    }];
    // 系统给没给锁：没给 / 被系统收回（切走、换窗口）都当释放，回来要再点一下（同 Mac 失焦释放，不靠系统自动重锁）
    [NSNotificationCenter.defaultCenter addObserverForName:UIPointerLockStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        UIScene *scene = n.userInfo[UIPointerLockStateSceneUserInfoKey];
        if (scene != g_root.window.windowScene) return;
        int locked = ((UIWindowScene *)scene).pointerLockState.isLocked;
        atomic_store(&g_locked, locked);
        reset_motion();
        LOG("鼠标视角：%s", locked ? "已锁定（Esc 释放）" : "已释放");
        if (!locked && atomic_exchange(&g_wanted, 0)) ask_system();
    }];
    for (GCMouse *m in GCMouse.mice) attach_mouse(m);
}
int s2a_ios_mouse_connected(void) { return atomic_load(&g_mice) > 0; }
int s2a_ios_mouse_lock_wanted(void) { return atomic_load(&g_wanted); }
unsigned s2a_ios_mouse_buttons(void) { return atomic_load(&g_counted); }
// keyboard.m 装好键位时（输入队列）：同步鼠标那几项和「使用鼠标 / 触控板」开关；is_default = 没动过鼠标的用法（mouse_map.h s2a_mouse_use_default）
void s2a_ios_mouse_config(const s2a_input_config *c, int is_default, int off) {
    int left_bound = 0;
    for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++) if (c->mouse[t] == 0) left_bound = 1;
    atomic_store(&g_camera, c->mouse_camera != 0); atomic_store(&g_left_bound, left_bound);
    atomic_store(&g_map_default, is_default); atomic_store(&g_recenter, c->recenter != 0);
    g_sens_x = c->sensitivity_x; g_sens_y = c->sensitivity_y; g_inv_x = c->invert_x; g_inv_y = c->invert_y;
    atomic_store(&g_off, off != 0);
    if (off) {   // 关掉：锁着就当场释放，按着的鼠标键放开（keyboard.m 装完键位紧接着重算一份发布）
        unlock("关了鼠标 / 触控板");
        atomic_store(&g_counted, 0);
    } else if (!c->mouse_camera) unlock("改成不起作用");
}
// HID 读线程（vpad.m 两个读导出）：攒下的位移加进右摇杆，读一次消费一次（同 Mac take_mouse_delta）
void s2a_ios_mouse_take(int32_t sticks[4]) {
    int64_t acc[2] = {atomic_exchange(&g_acc_x, 0), atomic_exchange(&g_acc_y, 0)};
    int recenter = atomic_load(&g_recenter);
    if (recenter && !acc[0] && !acc[1]) return;
    int64_t hold[2] = {atomic_load(&g_hold_x), atomic_load(&g_hold_y)};
    s2a_mouse_take(recenter, acc, hold, sticks);
    if (!recenter) { atomic_store(&g_hold_x, hold[0]); atomic_store(&g_hold_y, hold[1]); }
}
// keyboard.m（输入队列）：按下 Esc 时锁着 → 只释放，这一下不进游戏（同 Mac keyDown：Esc 先释放鼠标）
int s2a_ios_mouse_escape(void) {
    if (!atomic_load(&g_wanted) && !atomic_load(&g_locked)) return 0;
    unlock("Esc");
    return 1;
}
// 主线程：虚拟按键显示 / 收起、方案切换后核对一次——不该锁着就释放
void s2a_ios_mouse_sync(void) {
    if (!s2a_mouse_may_lock(current_state())) unlock("虚拟按键回来或切了方案");
}
// 主线程：切后台 / 开改键页——释放锁定、放开按键
void s2a_ios_mouse_background(void) {
    unlock("切后台或开了改键页");
    dispatch_queue_t queue = g_queue;
    if (queue) dispatch_async(queue, ^{ release_buttons(); });
}
// 主线程（controller.m 触摸观察）：一下触控板 / 鼠标点击怎么处理。0 当手指（交给 UIKit）、1 忽略、2 当触屏点转给 vpad.m
int s2a_ios_mouse_pointer(long button_mask) {
    s2a_mouse_state s = current_state();
    if (s2a_mouse_left(s) == S2A_MOUSE_PASS) return 0;
    if (!(button_mask & UIEventButtonMaskPrimary)) return 1;   // 右 / 中键：走 GCMouse 映射
    return s2a_mouse_left(s) == S2A_MOUSE_TOUCH ? 2 : 1;
}
