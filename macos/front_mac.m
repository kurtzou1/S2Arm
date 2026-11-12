// Opt-in Mac game shell. Game/library management lives in the separate launcher.
// Input ABI is the legacy s2a_vpad_read plus the event-driven s2a_vpad_read_ex
// (A2) used by services/InputPump.cs when the host exports it.
#include <dlfcn.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <QuartzCore/CAMetalLayer.h>
#include "../runtime/include/s2a_pad.h"
#include "../runtime/include/phone_axes.h"
#include "joycon_imu.h"
#import "input_guide.h"
#include "ns2_controller.h"
#include <stdatomic.h>
#include <stdint.h>
#include <math.h>
#include "../runtime/include/s2a_input_config.h"
#include "../graphics/metal/gal_abi.h"
#include "../graphics/nvn/gfx/nvn/nvn_present_fit.h"   // pf_viewport / pf_out_aspect：直连上屏摆放（鼠标当触屏的画面矩形）
#include <pthread.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include "../runtime/include/s2a_direct_prompt.h"
#include "../runtime/include/s2a_gfx_mode.h"
#include "../runtime/include/s2a_hud.h"
#include "../runtime/include/s2a_home_quit.h"
#include "../runtime/include/s2a_ui_text.h"
// 界面语言（runtime/include/s2a_ui_text.h，#316），盖过 runtime/src 各 .c 返回 1 的弱缺省。Mac 宿主程序不带 .lproj、主 bundle 首选本地化
//   总是开发区域，判不出玩家语言，所以按系统首选语言以 zh 开头判（目前 Mac 上没有显示路径用到它）
int s2a_ui_zh(void) { return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"]; }
#include "../ios/haptic_retry.h"
int s2a_screen_fit(int pw, int ph);   // runtime/src/widen.c：按窗口像素跟屏

void s2a_host_shutdown(const char *why);
void s2a_clock_catchup(void);   // runtime/src/os.c（接口 v2.14）
uint64_t now_ns(void);
// AppKit events publish on the main thread; the display-link thread never
// reads NSApplication/NSWindow. This is separate from input's focused state.
static _Atomic int display_focused;
static _Atomic uint64_t display_focus_since;
int dm_focus_now(void) { return atomic_load(&display_focused); }
uint64_t dm_focus_in_since(void) { return atomic_load(&display_focus_since); }
void s2a_host_focus_set(int focused); int s2a_focus_suspend(void); void s2a_host_sleep_set(int sleeping);   // runtime/src/os.c（接口 v2.15）
void s2a_guest_freeze(int on); void guest_clock_freeze_for(int reason, int on);   // thread.c / os.c
// 失焦（Cmd-Tab、点到别的窗口、打开键位窗口）：报给服务层转成游戏的焦点消息；游戏要求「失焦就暂停」（SetOutOfFocusSuspendingEnabled）时
//   冻结客机线程与游戏时钟（时钟按原因 3 冻），回焦点再放开（缺口扫描族 1 / 审计 P2-64：原先 Mac 失焦游戏照跑）
static BOOL focus_frozen;
// 关窗 / 收尾也发布「没焦点」，但不冻结（may_freeze = NO）：收尾要等客机线程退出
static void display_focus_publish_ex(BOOL active, BOOL may_freeze) {
    s2a_mac_ns2_focus(active);
    if (active && !atomic_load(&display_focused)) atomic_store(&display_focus_since, now_ns());
    atomic_store(&display_focused, active);
    s2a_host_focus_set(active);
    if (!active && may_freeze && !focus_frozen && s2a_focus_suspend()) { focus_frozen = YES; guest_clock_freeze_for(3, 1); s2a_guest_freeze(1); fprintf(stderr, "[s2a] Mac 失焦：游戏要求失焦暂停，冻结客机\n"); }
    else if ((active || !may_freeze) && focus_frozen) { focus_frozen = NO; s2a_guest_freeze(0); guest_clock_freeze_for(3, 0); fprintf(stderr, "[s2a] Mac 回到焦点 / 收尾：放开客机\n"); }
}
static void display_focus_publish(BOOL active) { display_focus_publish_ex(active, YES); }
static _Atomic uint32_t input_seq, input_buttons;
static _Atomic int32_t input_sticks[4];
static NSMutableSet<NSNumber *> *keys, *mouse;
static NSDictionary *config;
static BOOL focused;
static bool (*read_key_state)(CGEventSourceStateID, CGKeyCode) = CGEventSourceKeyState;
static NSUInteger system_mouse_buttons(void) { return NSEvent.pressedMouseButtons; }
// 系统当前按下的鼠标键（第 n 位 = 按钮 n），单测可替换（审计 P2-34）
static NSUInteger (*read_mouse_buttons)(void) = system_mouse_buttons;
static NSUInteger modifiers;
// Main thread collects relative motion; only the HID reader consumes it.
// Frontend timer/keyboard publications must not erase mouse packets between HID reads.
static _Atomic int64_t mouse_dx, mouse_dy;
static BOOL mouse_captured, mouse_release_pending;
// OS boundaries are replaceable by the native input test; it never grabs the desktop mouse.
static CGError (*associate_mouse)(boolean_t) = CGAssociateMouseAndMouseCursorPosition;
static void cursor_visibility(BOOL visible) { if (visible) [NSCursor unhide]; else [NSCursor hide]; }
static void (*set_mouse_visible)(BOOL) = cursor_visibility;

static const char *const targets[] = {"A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR",
                                    "PLUS", "MINUS", "LEFT", "UP", "RIGHT", "DOWN"};
static uint32_t target_bit(NSString *name) {
    for (unsigned i = 0; i < 16; i++) if ([name isEqualToString:@(targets[i])]) return 1u << i;
    return 0;
}
static void action(NSString *name, uint32_t *buttons, int32_t sticks[4]) {
    *buttons |= target_bit(name);
    NSArray *directions = @[@"LS_LEFT", @"LS_UP", @"LS_RIGHT", @"LS_DOWN", @"RS_LEFT", @"RS_UP", @"RS_RIGHT", @"RS_DOWN"];
    NSUInteger i = [directions indexOfObject:name];
    if (i != NSNotFound) {
        int axis = (i < 4 ? 0 : 2) + (i % 2);
        int sign = (i % 4 == 0 || i % 4 == 3) ? -1 : 1;
        sticks[axis] += sign * 32767;
    }
}
// Shared schema 1 parsing produces a portable table. This Apple-only bridge
// keeps the existing NSDictionary consumers/UI without a second JSON parser.
static NSDictionary *input_config_dictionary(const s2a_input_config *c) {
    NSMutableDictionary *keyboard = [NSMutableDictionary dictionary], *mouseMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *pad = [NSMutableDictionary dictionary], *axes = [NSMutableDictionary dictionary];
    for (int i = 0; i < S2A_INPUT_TARGET_COUNT; i++) {
        NSString *name = @(s2a_input_target_name(i));
        if (c->keyboard[i].code >= 0) keyboard[name] = @{@"code": @(c->keyboard[i].code), @"modifiers": @(c->keyboard[i].modifiers)};
        if (c->mouse[i] >= 0) mouseMap[name] = @(c->mouse[i]);
        if (c->gamepad[i] >= 0) pad[name] = @(s2a_input_pad_name(c->gamepad[i]));
    }
    const char *const axisNames[] = {"LX", "LY", "RX", "RY"};
    for (int i = 0; i < 4; i++) if (c->axes[i].source >= 0)
        axes[@(axisNames[i])] = @{@"source": @(s2a_input_axis_name(c->axes[i].source)), @"invert": @((BOOL)c->axes[i].invert)};
    return @{@"schema": @1, @"keyboard": keyboard, @"mouse": mouseMap, @"gamepad": pad, @"axes": axes, @"deadzone": @(c->deadzone),
        @"mouseOptions": @{@"mode": c->mouse_camera ? @"camera" : @"off", @"sensitivityX": @(c->sensitivity_x), @"sensitivityY": @(c->sensitivity_y),
            @"invertX": @((BOOL)c->invert_x), @"invertY": @((BOOL)c->invert_y), @"recenter": @((BOOL)c->recenter)}};
}
static NSDictionary *default_config(void) { s2a_input_config c; s2a_input_config_default(&c); return input_config_dictionary(&c); }
static int mac_input_config_read(const char *path, s2a_input_config *out) {
    if (!out) return S2A_INPUT_CONFIG_JSON;
    if (!path) { s2a_input_config_default(out); return S2A_INPUT_CONFIG_OK; }
    @try {
        NSString *name = [[NSString alloc] initWithUTF8String:path];
        NSFileHandle *file = name ? [NSFileHandle fileHandleForReadingAtPath:name] : nil;
        if (!file) return S2A_INPUT_CONFIG_IO;
        NSData *data = [file readDataUpToLength:S2A_INPUT_CONFIG_MAX_BYTES + 1 error:NULL]; [file closeFile];
        return data ? s2a_input_config_parse(data.bytes, data.length, out) : S2A_INPUT_CONFIG_IO;
    } @catch (NSException *exception) { (void)exception; return S2A_INPUT_CONFIG_IO; }
}
static void publish(uint32_t buttons, const int32_t sticks[4]) {
    atomic_fetch_add_explicit(&input_seq, 1, memory_order_seq_cst);
    atomic_store_explicit(&input_buttons, buttons, memory_order_seq_cst);
    for (int i = 0; i < 4; i++) atomic_store_explicit(&input_sticks[i], sticks[i], memory_order_seq_cst);
    atomic_fetch_add_explicit(&input_seq, 1, memory_order_seq_cst);
}
static GCExtendedGamepad *active_pad(NSArray *controllers);
// 事件驱动输入（A2）：同一份前端状态同时写进 runtime/src/pad.c，InputPump 找到 s2a_vpad_read_ex 后就等
//   s2a_pad_wait 的序号通知，不再 Thread.Sleep(16)。有扩展手柄时按系统手柄源发布（键盘 / 鼠标仍并进同一份状态），
//   没有手柄时按触屏源发布；两个源互斥的语义由 pad.c 管，Mac 不另造第三份选源状态。
static void publish_pad_state(int has_pad, uint32_t buttons, const int32_t sticks[4]) {
    if (has_pad) { s2a_pad_update(S2A_PAD_SYSTEM, focused ? 1 : 0, buttons, sticks); return; }
    // 没手柄时必须先补一次 SYSTEM 断开：pad.c 的 selected() 只看 connected，不发就仍选 SYSTEM 并丢掉 TOUCH 更新，
    //   手柄断开瞬间按住的键会卡住、键盘也失灵（维护方 11-09 用 pad.c 最小程序复现：0x1，期望 0x2）。
    s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, sticks);
    s2a_pad_update(S2A_PAD_TOUCH, focused ? 1 : 0, buttons, sticks);
}
static void publish_pad(uint32_t buttons, const int32_t sticks[4]) {
    publish_pad_state(active_pad(GCController.controllers) != nil, buttons, sticks);
}
static void publish_input(uint32_t buttons, const int32_t sticks[4]) {
    publish(buttons, sticks);
    publish_pad(buttons, sticks);
}
// 鼠标不回中（审计 P2-62：赛车预设写了 mouseOptions.recenter = false，原生读取从不看它，停手照样回中）：
//   回中（缺省）= 每次读把这一拍的位移加进右摇杆后清零；不回中 = 位移累进一个保持量，停手后右摇杆停在原处，失焦 / 复位清零
static _Atomic int mouse_hold;   // 1 = 不回中；配置装好时由 apply_mouse_options 设
static _Atomic int64_t hold_x, hold_y;
static void apply_mouse_options(void) { atomic_store(&mouse_hold, [config[@"mouseOptions"][@"recenter"] isEqual:@NO]); }
static int64_t clamp_stick(int64_t v) { return MAX(-32767, MIN(32767, v)); }
// 鼠标位移由 HID 读取线程消费一次；s2a_vpad_read（旧 ABI）与 s2a_vpad_read_ex（事件驱动 ABI）共用这一份。
static void take_mouse_delta(int32_t sticks[4]) {
    int64_t dx = atomic_exchange_explicit(&mouse_dx, 0, memory_order_relaxed);
    int64_t dy = atomic_exchange_explicit(&mouse_dy, 0, memory_order_relaxed);
    if (atomic_load(&mouse_hold)) {
        int64_t x = clamp_stick(atomic_load(&hold_x) + dx), y = clamp_stick(atomic_load(&hold_y) + dy);   // 只有 HID 读线程写保持量；复位在主线程清零
        atomic_store(&hold_x, x); atomic_store(&hold_y, y); dx = x; dy = y;
    }
    sticks[2] = (int32_t)clamp_stick((int64_t)sticks[2] + dx);
    sticks[3] = (int32_t)clamp_stick((int64_t)sticks[3] + dy);
}
__attribute__((visibility("default"), used)) uint32_t s2a_vpad_read(int32_t *sticks) {
    uint32_t a, b, buttons;
    do {
        a = atomic_load_explicit(&input_seq, memory_order_seq_cst);
        if (a & 1) continue;
        buttons = atomic_load_explicit(&input_buttons, memory_order_seq_cst);
        for (int i = 0; i < 4; i++) sticks[i] = atomic_load_explicit(&input_sticks[i], memory_order_seq_cst);
        b = atomic_load_explicit(&input_seq, memory_order_seq_cst);
    } while ((a & 1) || a != b);
    take_mouse_delta(sticks);
    return buttons;
}
// InputPump 按符号查这个导出（services/S2A.Services/InputPump.cs）：有它就走 pad.c 的序号 / 条件变量，
//   按键和摇杆从快照读，鼠标位移仍在这里消费一次。没有它的宿主继续用 s2a_vpad_read + Sleep(16)。
__attribute__((visibility("default"), used)) void s2a_vpad_read_ex(s2a_pad_snapshot *out) {
    s2a_pad_read_ex(out);
    take_mouse_delta(out->axes);
}
static NSMutableDictionary<NSNumber *, NSNumber *> *key_up_polls;   // 系统报「已松开」连续采样次数（见 release_stale_keys）
// 被采样判成松开、没收到 keyUp 的键：其后系统报按下或自动重复证明还按着，可恢复
static NSMutableSet<NSNumber *> *stale_keys;
// 鼠标键的同一套记录（审计 P2-34，见 release_stale_mouse）
static NSMutableDictionary<NSNumber *, NSNumber *> *mouse_up_polls;
static NSMutableSet<NSNumber *> *stale_mouse;
static void touch_end(void);   // 鼠标左键当触屏（见下）：抬起 / 复位补一帧 End
static void reset_input(void) {
    [keys removeAllObjects]; [mouse removeAllObjects]; modifiers = 0; [key_up_polls removeAllObjects]; [stale_keys removeAllObjects];
    [mouse_up_polls removeAllObjects]; [stale_mouse removeAllObjects];
    atomic_store_explicit(&mouse_dx, 0, memory_order_relaxed);
    atomic_store_explicit(&mouse_dy, 0, memory_order_relaxed);
    atomic_store(&hold_x, 0); atomic_store(&hold_y, 0);
    int32_t sticks[4] = {0}; publish_input(0, sticks);
    touch_end();   // 失焦 / 关窗：按着的触点补一帧 End（定义在下面鼠标触屏段）
}
static void sample_input(void);
// Capture changes only mouse ownership. Keyboard holds/modifiers remain until
// keyUp, stale-key polling or a full focus/shutdown reset clears them.
static void reset_mouse_input(void) {
    [mouse removeAllObjects]; [mouse_up_polls removeAllObjects]; [stale_mouse removeAllObjects];
    atomic_store_explicit(&mouse_dx, 0, memory_order_relaxed);
    atomic_store_explicit(&mouse_dy, 0, memory_order_relaxed);
    atomic_store(&hold_x, 0); atomic_store(&hold_y, 0);
    sample_input();
}
static BOOL camera_mouse(void) { return [config[@"mouseOptions"][@"mode"] isEqualToString:@"camera"]; }
// Called on the AppKit thread. A click captures; Esc/focus loss/termination releases.
static void set_mouse_capture(BOOL capture) {
    if ((capture && mouse_captured) || (!capture && !mouse_captured && !mouse_release_pending)) return;
    if (capture && (!focused || !camera_mouse())) return;
    if (capture && mouse_release_pending) {
        set_mouse_capture(NO); if (mouse_release_pending) return;
    }
    CGError err = associate_mouse(!capture);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "[s2a] 【红】Mac 鼠标%s失败：%d%s\n", capture ? "锁定" : "释放", err, capture ? "" : "（将重试）");
        if (!capture) {
            if (mouse_captured) set_mouse_visible(YES);
            mouse_captured = NO; mouse_release_pending = YES; reset_mouse_input();
        }
        return;
    }
    if (capture) set_mouse_visible(NO); else if (mouse_captured) set_mouse_visible(YES);
    mouse_captured = capture; mouse_release_pending = NO; reset_mouse_input();
    fprintf(stderr, "[s2a] Mac 鼠标视角：%s\n", capture ? "已锁定（Esc 释放）" : "已释放");
}
// ---- 鼠标左键点画面 = 触屏（11-04 维护者定，对齐 Ryujinx Ryujinx.Input/HLE/TouchScreenManager：按下 Start、拖动跟点、抬起 End，坐标落在游戏画面里）----
//   脑锻炼（010062200D392000）标题页「开始」只认点按，Mac 原先鼠标只当视角 / 按键，开不了局。
//   什么时候接管左键（11-04 维护者定，开箱即用）：
//     ① 游戏声明了触屏 / 手写笔配置（hid SetTouchScreenConfiguration，服务层经 s2a_vpad_touch_configured 告知），且玩家没改过键位 → 左键当触屏，
//        缺省键位里左键 = Y、鼠标模式 = 转动视角，这两样在这里让给触屏（不发 Y、不锁鼠标）；
//     ② 否则只在左键没映射成按键、鼠标模式不是「转动视角」时接管（玩家自己的设置里左键没别的用途）。
//   「玩家改过键位」判据（mapping_is_default）：本局生效的映射（S2A_INPUT_CONFIG 的快照，或没给时的内置缺省）与内置缺省 default_config() 按值比，
//     不同 = 改过。不看文件在不在：启动器首启的键位引导卡会把未改动的标准映射也当 launchInputConfig 写成快照（pack/jobs/build.py runtime_env），
//     文件存在不等于玩家改过；启动器的标准映射 InputConfig.standard（Models.swift）与 default_config() 逐项同值，只是 JSON 多写了缺省字段
//     （schema、modifiers 0、invert false、recenter true），比较前按 Models.swift 的解码缺省补齐（mapping_norm）。
//   触点经 s2a_vpad_read_touch 交给服务层 InputPump.PushTouch（与 iOS 壳仅触屏方案同一导出、同一写法），主线程写、HID 线程读，锁保护。
//   画面矩形与上屏同一套算式：通用模式取渲染层这一帧（nxgal_present_frame + gal_present.m dst_rect），直连模式取出图比例
//   （graphics/nvn/host_adapt.m out_aspect 同式）按 nvn_present_fit.h pf_viewport 放进窗口。触点空间同 iOS vpad.m switchPoint：
//   游戏不知道宽屏 = 1280×720 铺满画面；游戏自己出宽图 = 通用取出图尺寸 ÷ 渲染倍率、直连取显示宽 × 720
int nxgal_present_frame(int32_t *w, int32_t *h, float *ax, float *ay, int32_t *stretched);   // graphics/metal/gal_present.m
int s2a_widen_game(void); int s2a_widen_full(void); int s2a_screen_w(void); int s2a_screen_h(void); void s2a_game_canvas(int *w, int *h);   // runtime/src/widen.c
static pthread_mutex_t touch_mu = PTHREAD_MUTEX_INITIALIZER;
static int32_t touch_x, touch_y;
static int touch_state;          // 0 没按、1 按着、2 抬起待发 End（touch_mu 保护）
static BOOL touch_start_pending; // 按下后还没发出 Start（快点：两次读之间按下又抬起，先发 Start、下一拍再发 End）
static BOOL touch_owner;         // 主线程：当前这次左键按下是触屏
static _Atomic int touch_declared = -1;   // 游戏声明的触屏模式（TouchScreenModeForNx），-1 = 没声明
// 服务层 InputPump 按符号查（同 iOS 壳 ios/touch_config.m 的同名导出）：游戏调了 SetTouchScreenConfiguration 后递一次模式，返回 1 = 收下（之后不再递）
__attribute__((visibility("default"), used)) int s2a_vpad_touch_configured(int mode) {
    if (atomic_exchange(&touch_declared, mode) < 0) fprintf(stderr, "[s2a] Mac：游戏声明了触屏配置（模式 %d）；键位没改过时左键点画面当触屏\n", mode);
    return 1;
}
static NSDictionary *mapping_norm(NSDictionary *c) {   // 只取影响输入的字段，缺省字段按 Models.swift 解码缺省补齐
    NSMutableDictionary *k = [NSMutableDictionary dictionary], *a = [NSMutableDictionary dictionary];
    NSDictionary *kb = [c[@"keyboard"] isKindOfClass:NSDictionary.class] ? c[@"keyboard"] : @{};
    for (NSString *n in kb) k[n] = @[kb[n][@"code"] ?: @(-1), kb[n][@"modifiers"] ?: @0];
    NSDictionary *ax = [c[@"axes"] isKindOfClass:NSDictionary.class] ? c[@"axes"] : @{};
    for (NSString *n in ax) a[n] = @[ax[n][@"source"] ?: @"", @([ax[n][@"invert"] boolValue])];
    NSDictionary *o = [c[@"mouseOptions"] isKindOfClass:NSDictionary.class] ? c[@"mouseOptions"] : @{};
    NSArray *opt = @[o[@"mode"] ?: @"", @(llround([o[@"sensitivityX"] doubleValue] * 1000)), @(llround([o[@"sensitivityY"] doubleValue] * 1000)),
                     @([o[@"invertX"] boolValue]), @([o[@"invertY"] boolValue]), @(o[@"recenter"] ? [o[@"recenter"] boolValue] : YES)];
    double dz = c[@"deadzone"] ? [c[@"deadzone"] doubleValue] : .15;
    return @{@"k": k, @"m": c[@"mouse"] ?: @{}, @"g": c[@"gamepad"] ?: @{}, @"a": a, @"o": opt, @"d": @(llround(dz * 1000))};
}
static BOOL mapping_is_default(void) { return [mapping_norm(config) isEqual:mapping_norm(default_config())]; }
static BOOL left_click_touches(void) {
    if (atomic_load(&touch_declared) >= 0 && mapping_is_default()) return YES;
    if (camera_mouse()) return NO;
    NSDictionary *m = config[@"mouse"];
    for (NSString *name in m) if ([m[name] isEqual:@0]) return NO;
    return YES;
}
typedef struct { double x, y, w, h; } touch_rect;
// 画面在窗口里的矩形（像素，左上原点）；cw / ch = 触点空间
static touch_rect touch_picture(double W, double H, int *cw, int *ch) {
    int32_t iw = 0, ih = 0, st = 0; float ax = 0, ay = 0; touch_rect r = {0, 0, W, H};
    int generic = s2a_gfx_mode() == S2A_GFX_GENERIC;
    if (generic && nxgal_present_frame(&iw, &ih, &ax, &ay, &st)) {   // gal_present.m dst_rect 同式（float、int 截断、差不到 1 像素铺满）
        if (!st && ax > 0 && ay > 0) {
            float rx = fminf(1.0f, (float)H * ax / ((float)W * ay)), ry = fminf(1.0f, (float)W * ay / ((float)H * ax));
            int dw = (int)(W * rx), dh = (int)(H * ry);
            if (W - W * rx < 1.0f) dw = (int)W;
            if (H - H * ry < 1.0f) dh = (int)H;
            r = (touch_rect){((int)W - dw) / 2, ((int)H - dh) / 2, dw, dh};
        }
    } else if (!generic) {
        const char *e = getenv("S2A_WIDEN_DIRECT"); int direct_widen = !(e && !strcmp(e, "0")) && s2a_widen_full();
        int sw = s2a_screen_w(), sh = s2a_screen_h();
        int wide = s2a_widen_game() || (direct_widen && sw > 1920), tall = direct_widen && sh > 1080;
        pf_vp v = pf_viewport(W, H, pf_out_aspect(wide || tall, sw, sh), 1);
        r = (touch_rect){v.x, v.y, v.w, v.h};
    }
    *cw = 1280; *ch = 720;
    if (s2a_widen_game()) {
        const char *k = getenv("S2A_RES_SCALE"); double scale = k && atof(k) > 0 ? atof(k) : 1;
        if (generic && iw > 0 && ih > 0) { *cw = (int)lround(iw / scale); *ch = (int)lround(ih / scale); }
        else s2a_game_canvas(cw, ch);   // 直连：游戏画布（宽、高都按屏比，审计 P1-92；原先高留 720）
    }
    return r;
}
// 视图点（点、左上原点）→ 触点；落在画面外返回 NO（clamp = YES 时钳到画面边上，拖出画面用）
static BOOL touch_map(NSSize view, double scale, NSPoint p, BOOL clamp, int32_t *x, int32_t *y) {
    double W = MAX(1, round(view.width * scale)), H = MAX(1, round(view.height * scale)), px = p.x * scale, py = p.y * scale;
    int cw, ch; touch_rect r = touch_picture(W, H, &cw, &ch);
    if (!clamp && (px < r.x || px > r.x + r.w || py < r.y || py > r.y + r.h)) return NO;
    double fx = (px - r.x) / MAX(r.w, 1) * cw, fy = (py - r.y) / MAX(r.h, 1) * ch;
    *x = (int32_t)lround(MIN(cw - 1, MAX(0, fx))); *y = (int32_t)lround(MIN(ch - 1, MAX(0, fy)));
    return YES;
}
static void touch_begin(NSSize view, double scale, NSPoint p) {
    int32_t x, y;
    static int logged; BOOL in = touch_map(view, scale, p, NO, &x, &y);
    if (logged++ < 8) fprintf(stderr, in ? "[s2a] Mac 鼠标点画面 %.0f,%.0f → 触点 %d,%d\n" : "[s2a] Mac 鼠标点在画面外 %.0f,%.0f → 不发触点\n", p.x, p.y, x, y);
    if (!in) return;
    pthread_mutex_lock(&touch_mu); touch_x = x; touch_y = y; touch_state = 1; touch_start_pending = YES; pthread_mutex_unlock(&touch_mu);
    touch_owner = YES;
}
static void touch_move(NSSize view, double scale, NSPoint p) {
    int32_t x, y; if (!touch_owner || !touch_map(view, scale, p, YES, &x, &y)) return;
    pthread_mutex_lock(&touch_mu); if (touch_state == 1) { touch_x = x; touch_y = y; } pthread_mutex_unlock(&touch_mu);
}
static void touch_end(void) {   // 抬起 / 失焦 / 复位：按着的补一帧 End
    touch_owner = NO;
    pthread_mutex_lock(&touch_mu); if (touch_state == 1) touch_state = 2; pthread_mutex_unlock(&touch_mu);
}
// 服务层 InputPump 按符号查（HID 线程每次提交调一次）：返回触点个数 0 / 1，xy = 触点，attributes 1 Start / 2 End / 0 按着
__attribute__((visibility("default"), used)) int s2a_vpad_read_touch(int32_t *xy, uint32_t *attributes) {
    int n = 0;
    pthread_mutex_lock(&touch_mu);
    if (touch_state) {
        xy[0] = touch_x; xy[1] = touch_y; n = 1;
        if (touch_start_pending) { attributes[0] = 1; touch_start_pending = NO; }
        else if (touch_state == 2) { attributes[0] = 2; touch_state = 0; }
        else attributes[0] = 0;
    }
    pthread_mutex_unlock(&touch_mu);
    return n;
}
// 多个手柄（或先连着遥控器等没有扩展手柄档的设备）时取最近有输入的那个扩展手柄（审计 P2-63：原先只读列表第一个）。
//   每次采样从当前列表现挑：断开的设备已不在列表里，不用另听连接 / 断开通知
static GCExtendedGamepad *active_pad(NSArray *controllers) {
    GCExtendedGamepad *best = nil;
    for (GCController *c in controllers) {
        GCExtendedGamepad *p = c.extendedGamepad;
        if (p && (!best || p.lastEventTimestamp > best.lastEventTimestamp)) best = p;
    }
    return best;
}
// 手柄事件驱动（A2）：valueChangedHandler 走 GameController 的回调队列，切到主队列后与 AppKit 键盘 / 鼠标事件串行，
//   sample_input 可以直接读 keys / mouse / config。120Hz 定时器仍保留给键盘 / 鼠标的粘键核对，并顺手补装新连接的手柄。
// 没有扩展手柄描述、但通用物理描述里有按键的手柄（部分第三方手柄的某些模式、只给简易描述的手柄）：原先整只被忽略、游戏里没反应也没有提示。
//   按标准键名从 physicalInputProfile 读（参照维护者提供的前端实现 Gamepad.swift 的读法）。六轴 / 震动 / Home 退出仍只认扩展手柄
static BOOL pad_has_profile_buttons(GCController *c) { return !c.extendedGamepad && c.physicalInputProfile.buttons.count > 0; }
static void install_pad_handler(GCController *controller) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (pad) {
        if (pad.valueChangedHandler) return;
        controller.handlerQueue = dispatch_get_main_queue();
        pad.valueChangedHandler = ^(GCExtendedGamepad *profile, GCControllerElement *element) {
            (void)profile; (void)element;
            sample_input();
        };
        return;
    }
    if (!pad_has_profile_buttons(controller) || controller.physicalInputProfile.valueDidChangeHandler) return;
    controller.handlerQueue = dispatch_get_main_queue();
    controller.physicalInputProfile.valueDidChangeHandler = ^(GCPhysicalInputProfile *profile, GCControllerElement *element) {
        (void)profile; (void)element;
        sample_input();
    };
}
// 诊断：GameController 枚举到的全部手柄与描述（格式同 iOS ios/controller.m log_controllers，#456）：名称 | 类型 | extended / micro / none。
//   每拍都会来（轮询里补装回调），只在手柄集合变了时打一行
static void log_controllers_if_changed(void) {
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (GCController *c in GCController.controllers)
        [list addObject:[NSString stringWithFormat:@"%@|%@|%@", c.vendorName ?: @"?", c.productCategory ?: @"?",
                         c.extendedGamepad ? @"extended" : c.microGamepad ? @"micro" : @"none"]];
    NSString *now = [list componentsJoinedByString:@"; "];
    static NSString *last;
    if (last && [last isEqualToString:now]) return;
    last = now;
    fprintf(stderr, "[s2a] 系统手柄：枚举到 %d 个 %s\n", (int)list.count, now.UTF8String ?: "");
}
static void install_pad_handlers(void) {
    log_controllers_if_changed();
    for (GCController *controller in GCController.controllers) install_pad_handler(controller);
}
// 手柄六轴（同 iOS 的 s2a_pad_read_motion 约定）：游戏要六轴时才开传感器。主线程跟着输入采样读 GCMotion，游戏线程取最新一份
static _Atomic int g_motion_wanted;
static pthread_mutex_t g_motion_mu = PTHREAD_MUTEX_INITIALIZER;
static s2a_pad_motion g_motion;
static int g_motion_known;
static GCMotion *g_motion_source;
// 换了六轴源（两只带六轴的手柄按「最近有输入」切换，审计 P2-215）：读的一方下一次先拿到一次 known = 0，
//   服务层 ControllerFeedback.TickMotion 走已有的「没有六轴 → 清姿态」，新手柄从头积分，不接着上一只的姿态。
//   标记由读取方消费（主线程采样、HID 线程读，只改一帧样本可能被下一帧盖掉、读不到）；单只拔掉本来就是 known = 0，不另标
static int g_motion_switched;   // 持 g_motion_mu
static void set_motion_source(GCMotion *source) {
    if (source == g_motion_source) return;
    if (source && g_motion_source) { pthread_mutex_lock(&g_motion_mu); g_motion_switched = 1; pthread_mutex_unlock(&g_motion_mu); }
    if (g_motion_source.sensorsRequireManualActivation) g_motion_source.sensorsActive = NO;
    g_motion_source = source;
    if (source.sensorsRequireManualActivation) source.sensorsActive = YES;
}
static void sample_motion(GCExtendedGamepad *pad) {
    BOOL ns2 = s2a_mac_ns2_status() == NS2_STATUS_READY;
    GCMotion *m = atomic_load(&g_motion_wanted) && !ns2 ? pad.controller.motion : nil;
    set_motion_source(m.hasRotationRate && m.hasGravityAndUserAcceleration ? m : nil);
    s2a_pad_motion sample = {0};
    int known = g_motion_source != nil;
    if (known) {
        double gravity[3] = {m.gravity.x, m.gravity.y, m.gravity.z}, user[3] = {m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z};
        double rotation[3] = {m.rotationRate.x, m.rotationRate.y, m.rotationRate.z};
        float acceleration[3], gyro[3];
        s2a_gc_motion_axes(gravity, user, rotation, acceleration, gyro);
        sample = (s2a_pad_motion){clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000, acceleration[0], acceleration[1], acceleration[2], gyro[0], gyro[1], gyro[2]};
    }
    pthread_mutex_lock(&g_motion_mu);
    g_motion = sample; g_motion_known = known;
    pthread_mutex_unlock(&g_motion_mu);
}
// 启动设置「体感」关（S2A_MOTION=0，pack/jobs/community.py launch_env）：游戏要六轴也不开手柄传感器（系统手柄与 Switch 2 Pro 同一判断）
__attribute__((visibility("default"), used)) void s2a_pad_set_motion_enabled(int enabled) {
    const char *off = getenv("S2A_MOTION");
    int want = enabled != 0 && !(off && !strcmp(off, "0"));
    atomic_store(&g_motion_wanted, want);
    s2a_mac_ns2_set_motion_enabled(want);
    // Joy-Con：系统 GCMotion 为 nil，改走 HID 全报告六轴（macos/joycon_imu.m）
    s2a_joycon_imu_set_enabled(want);
}
__attribute__((visibility("default"), used)) int s2a_pad_read_motion(s2a_pad_motion *out) {
    if (s2a_mac_ns2_status() == NS2_STATUS_READY) return s2a_mac_ns2_read_motion(out);
    pthread_mutex_lock(&g_motion_mu);
    int known = g_motion_switched ? 0 : g_motion_known;
    *out = g_motion; g_motion_switched = 0;
    pthread_mutex_unlock(&g_motion_mu);
    if (known) return 1;
    // GameController 无六轴时回退 Joy-Con HID（优先右、否则左）
    s2a_pad_motion l = {0}, r = {0};
    int mask = s2a_joycon_imu_read(&l, &r);
    if (mask & 2) { *out = r; return 1; }
    if (mask & 1) { *out = l; return 1; }
    return 0;
}
// 左右 Joy-Con 各一路；只有 GCMotion 时退回单源写在 out[0]
__attribute__((visibility("default"), used)) int s2a_pad_read_motion_pair(s2a_pad_motion out[2]) {
    if (!out) return 0;
    if (s2a_mac_ns2_status() == NS2_STATUS_READY) return s2a_mac_ns2_read_motion_pair(out);   // NS2 手柄（启动器通道）：Joy-Con 2 拼对时左右各一路（ns2_relay.h motion_left）
    s2a_pad_motion l = {0}, r = {0};
    int mask = s2a_joycon_imu_read(&l, &r);
    if (mask) {
        int n = 0;
        if (mask & 1) out[n++] = l;
        if (mask & 2) out[n++] = r;
        // 只有一只时仍返回 1：服务层 UpdateSixAxis 会把同一份写到双 Joy-Con 左右
        return n;
    }
    s2a_pad_motion one = {0};
    if (!s2a_pad_read_motion(&one)) return 0;
    out[0] = one;
    return 1;
}
// Joy-Con 2 光学鼠标（s2a_pad.h）：只有 NS2 手柄（Joy-Con 2）有；服务层写进游戏的 Jcms 缓冲
__attribute__((visibility("default"), used)) int s2a_pad_read_mouse_pair(s2a_pad_mouse out[2]) {
    if (!out) return 0;
    if (s2a_mac_ns2_status() != NS2_STATUS_READY) { out[0] = out[1] = (s2a_pad_mouse){0}; return 0; }
    return s2a_mac_ns2_read_mouse_pair(out);
}
// 实体手柄退出游戏（#276）：决策在 runtime/include/s2a_home_quit.h，界面（提示条、失焦、退出）在 S2AMacDelegate 后面的 home_quit_ui
static s2a_hq_state g_hq;
static void home_quit_ui(s2a_hq_action action);
static void sample_home_quit(GCExtendedGamepad *pad) {
    if (!pad) return;
    static __weak GCController *claimed;   // Home 默认归系统（启动台 / 游戏面板）：每个手柄接管一次
    if (pad.controller != claimed && pad.buttonHome) { pad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled; claimed = pad.controller; }
    // 确认 / 取消按 Switch 的 A / B（与游戏内同一套对应：s2a_pad_abxy_order，按键布局）
    GCControllerButtonInput *face[4] = {pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY};
    int order[4]; s2a_pad_abxy_order(s2a_pad_kind(pad.controller.productCategory.UTF8String, [pad isKindOfClass:GCXboxGamepad.class],
        [pad isKindOfClass:GCDualShockGamepad.class] || [pad isKindOfClass:GCDualSenseGamepad.class]), s2a_pad_layout(), order);
    BOOL home = pad.buttonHome.isPressed, a = face[order[0]].isPressed, b = face[order[1]].isPressed;
    s2a_hq_action act = s2a_hq_step(&g_hq, now_ns(), home || (pad.buttonMenu.isPressed && pad.buttonOptions.isPressed), home, a, b);
    if (act != S2A_HQ_NONE) home_quit_ui(act);
}
// 手柄震动（启动设置「震动」「震动强度」，11-09）：同 iOS ios/controller.m 系统手柄那一支——当前手柄的 GCDeviceHaptics 建一个 CHHapticEngine，
//   连续事件循环播放、按游戏给的两侧振幅取大调强度，1 秒没新帧自动停；失败退避 / 判死同 ios/haptic_retry.h。
//   游戏侧按符号查询这几个导出（s2a_pad.h），Mac 之前没提供 = 游戏的震动全丢。S2A_RUMBLE=0 关掉；S2A_RUMBLE_SCALE 是强度档倍率（定义表 rumbleLevel.scale）
#define MAC_RUMBLE_BASE 0x534d000000000000ull
static dispatch_queue_t g_rumble_q;
static _Atomic uint64_t g_rumble_epoch;          // 0 = 没有能震的手柄 / 玩家关了震动
static uint64_t g_rumble_counter;                // 主线程：换一次手柄加一
static GCController *g_rumble_main;              // 主线程：当前手柄
static GCController *g_rumble_device;            // 以下只在 g_rumble_q 上碰
static CHHapticEngine *g_rumble_engine;
static id<CHHapticPatternPlayer> g_rumble_player;   // 能建循环播放器就用循环的；建不了（见 rumble_play_on_queue）用普通播放器，快到事件末尾时重起
static BOOL g_rumble_loops;
static BOOL g_rumble_plain_only;                 // 这只手柄建循环播放器失败过：之后只建普通播放器
static uint64_t g_rumble_started_ns;             // 普通播放器这一轮的起播时刻
static BOOL g_rumble_playing;
static dispatch_source_t g_rumble_timer;
static s2a_hp_state g_rumble_retry;
static pthread_mutex_t g_rumble_mu = PTHREAD_MUTEX_INITIALIZER;
static s2a_pad_vibration g_rumble_pair[2];       // g_rumble_mu：单侧提交时拼成整对
#define MAC_RUMBLE_RESTART_NS (20ull * NSEC_PER_SEC)
static float rumble_scale(void) {
    static float scale = -1;
    if (scale < 0) { const char *e = getenv("S2A_RUMBLE_SCALE"); float v = e ? strtof(e, NULL) : 1; scale = isfinite(v) && v > 0 ? v : 1; }
    return scale;
}
static BOOL rumble_off(void) { const char *e = getenv("S2A_RUMBLE"); return e && !strcmp(e, "0"); }
static void rumble_stop_on_queue(void) {
    if (g_rumble_player && g_rumble_playing) [g_rumble_player stopAtTime:CHHapticTimeImmediate error:nil];
    g_rumble_playing = NO;
    if (g_rumble_timer) dispatch_source_set_timer(g_rumble_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}
static void rumble_reset_on_queue(void) {
    rumble_stop_on_queue();
    [g_rumble_engine stopWithCompletionHandler:nil];
    g_rumble_player = nil; g_rumble_engine = nil;
}
static void rumble_fail_on_queue(const char *what, NSError *error) {
    BOOL died = s2a_hp_on_fail(&g_rumble_retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    if (!g_rumble_retry.reported) {
        g_rumble_retry.reported = YES;
        fprintf(stderr, "【红】手柄震动：%s（%s/%ld）%s\n", what, error.domain.UTF8String ?: "-", error ? (long)error.code : 0L, error.localizedDescription.UTF8String ?: "");
    }
    if (died) fprintf(stderr, "【红】手柄震动：本手柄本局停用（连续 %d 次失败）；换手柄会再试\n", S2A_HP_MAX_FAILS);
}
static float rumble_clamp(float x, float lo, float hi) { return isfinite(x) ? fminf(hi, fmaxf(lo, x)) : lo; }
static void rumble_play_on_queue(s2a_pad_vibration pair[2]) {
    float amplitude = 0, weighted = 0, weights = 0;
    for (int i = 0; i < 2; i++) {
        float lo = rumble_clamp(pair[i].low_amp, 0, 1), hi = rumble_clamp(pair[i].high_amp, 0, 1);
        amplitude = fmaxf(amplitude, fmaxf(lo, hi));
        weighted += lo * rumble_clamp(pair[i].low_hz, 0, 1250) + hi * rumble_clamp(pair[i].high_hz, 0, 1250);
        weights += lo + hi;
    }
    amplitude = fminf(1, s2a_hp_feel(amplitude) * rumble_scale());
    if (amplitude <= 0.001f || !g_rumble_device.haptics) { rumble_stop_on_queue(); return; }
    if (s2a_hp_should_try(&g_rumble_retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) == S2A_HP_SKIP) return;
    float hz = weights > 0 ? weighted / weights : 160;
    float sharp = rumble_clamp((hz - 160) / 160 * 0.5f + 0.3f, 0, 1);
    NSError *error = nil;
    if (!g_rumble_engine) {
        g_rumble_engine = [g_rumble_device.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!g_rumble_engine) { rumble_fail_on_queue("无法创建引擎", nil); return; }
        g_rumble_engine.playsHapticsOnly = YES;
        __weak CHHapticEngine *weakEngine = g_rumble_engine;
        void (^invalidate)(void) = ^{
            CHHapticEngine *engine = weakEngine;
            if (engine) dispatch_async(g_rumble_q, ^{ if (g_rumble_engine == engine) rumble_reset_on_queue(); });
        };
        g_rumble_engine.resetHandler = ^{ invalidate(); };
        g_rumble_engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; invalidate(); };
    }
    if (!g_rumble_player) {
        if (![g_rumble_engine startAndReturnError:&error]) { rumble_fail_on_queue("启动引擎失败", error); rumble_reset_on_queue(); return; }
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        // 循环播放器在有的系统 / 手柄上建不出来（11-10 M1 Max / macOS 27.0.1 / DualSense：NSCocoaErrorDomain 4097，同一引擎上普通播放器能建能播）：
        //   退到普通播放器，它不能循环，靠下面的重起接上
        //   循环播放器建失败后这个引擎也废了（接着在它上面建普通播放器报 GameControllerHaptics/0 Client not registred），所以记下来、丢掉引擎、从头再来一次
        if (pattern && !g_rumble_plain_only) {
            id<CHHapticAdvancedPatternPlayer> advanced = [g_rumble_engine createAdvancedPlayerWithPattern:pattern error:&error];
            if (advanced) { advanced.loopEnabled = YES; g_rumble_player = advanced; g_rumble_loops = YES; }
            else {
                fprintf(stderr, "手柄震动：循环播放器建不了（%s/%ld），改用普通播放器\n", error.domain.UTF8String ?: "-", error ? (long)error.code : 0L);
                g_rumble_plain_only = YES; rumble_reset_on_queue(); rumble_play_on_queue(pair); return;
            }
        } else if (pattern) { g_rumble_player = [g_rumble_engine createPlayerWithPattern:pattern error:&error]; g_rumble_loops = NO; }
        if (!g_rumble_player) { rumble_fail_on_queue("创建播放器失败", error); rumble_reset_on_queue(); return; }
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (g_rumble_playing && !g_rumble_loops && now - g_rumble_started_ns > MAC_RUMBLE_RESTART_NS) {   // 普通播放器：事件 30 秒，连着震到 20 秒就重起一轮
        [g_rumble_player stopAtTime:CHHapticTimeImmediate error:nil]; g_rumble_playing = NO;
    }
    if (!g_rumble_playing && ![g_rumble_player startAtTime:CHHapticTimeImmediate error:&error]) { rumble_fail_on_queue("播放失败", error); rumble_reset_on_queue(); return; }
    if (!g_rumble_playing) g_rumble_started_ns = now;
    g_rumble_playing = YES;
    if (![g_rumble_player sendParameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]] atTime:CHHapticTimeImmediate error:&error]) {
        rumble_fail_on_queue("更新强度失败", error); rumble_reset_on_queue(); return;
    }
    s2a_hp_on_ok(&g_rumble_retry);
    static BOOL logged; if (!logged) { logged = YES; fprintf(stderr, "手柄震动：播放 强度 %.2f（倍率 %.2f）锐度 %.2f\n", amplitude, rumble_scale(), sharp); }
    if (!g_rumble_timer) {
        g_rumble_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_rumble_q);
        dispatch_source_set_event_handler(g_rumble_timer, ^{ rumble_stop_on_queue(); });
        dispatch_resume(g_rumble_timer);
    }
    dispatch_source_set_timer(g_rumble_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
}
// 主线程（输入采样）：当前手柄换了就换会话号，旧会话的提交一律丢掉
static void rumble_select(GCController *device) {
    if (device == g_rumble_main) return;
    g_rumble_main = device;
    if (!g_rumble_q) g_rumble_q = dispatch_queue_create("dev.s2arm.mac-rumble", DISPATCH_QUEUE_SERIAL);
    atomic_store(&g_rumble_epoch, device.haptics && !rumble_off() ? ++g_rumble_counter : 0);
    dispatch_async(g_rumble_q, ^{ rumble_reset_on_queue(); g_rumble_device = device; g_rumble_retry = (s2a_hp_state){0}; g_rumble_plain_only = NO; });
}
// 会话号高 16 位是 MAC_RUMBLE_BASE 的走系统手柄（CoreHaptics），其余是 Switch 2 Pro（macos/ns2_controller.c，#277）的
static BOOL rumble_is_mac(uint64_t session) { return (session & 0xffff000000000000ull) == MAC_RUMBLE_BASE; }
static void rumble_submit(uint64_t session, const s2a_pad_vibration pair[2]) {
    if (session && !rumble_is_mac(session)) { s2a_mac_ns2_set_rumble_pair(session, pair); return; }
    uint64_t epoch = atomic_load(&g_rumble_epoch);
    if (!epoch || session != (MAC_RUMBLE_BASE | epoch) || !g_rumble_q) return;
    s2a_pad_vibration left = pair[0], right = pair[1];   // 块里不能捕获数组：拆成两个值
    dispatch_async(g_rumble_q, ^{ s2a_pad_vibration p[2] = {left, right}; rumble_play_on_queue(p); });
}
__attribute__((visibility("default"), used)) uint64_t s2a_pad_rumble_session(void) {
    if (rumble_off()) return 0;   // 启动设置「手柄震动」关：两路都不震
    uint64_t ns2 = s2a_mac_ns2_rumble_session();   // Switch 2 Pro 连着且在前台：震动交给它（它是输入来源时系统手柄那路不读）
    if (ns2) return ns2;
    uint64_t epoch = atomic_load(&g_rumble_epoch);
    return epoch ? (MAC_RUMBLE_BASE | epoch) : 0;
}
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]) {
    if (!values) return;
    pthread_mutex_lock(&g_rumble_mu); g_rumble_pair[0] = values[0]; g_rumble_pair[1] = values[1]; pthread_mutex_unlock(&g_rumble_mu);
    rumble_submit(session, values);
}
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz) {
    if (side >= 2) return;
    pthread_mutex_lock(&g_rumble_mu);
    g_rumble_pair[side] = (s2a_pad_vibration){low_amp, low_hz, high_amp, high_hz};
    s2a_pad_vibration pair[2] = {g_rumble_pair[0], g_rumble_pair[1]};
    pthread_mutex_unlock(&g_rumble_mu);
    rumble_submit(session, pair);
}
__attribute__((visibility("default"), used)) void s2a_pad_stop_rumble(uint64_t session) {
    if (session && !rumble_is_mac(session)) { s2a_mac_ns2_stop_rumble(session); return; }
    pthread_mutex_lock(&g_rumble_mu); memset(g_rumble_pair, 0, sizeof g_rumble_pair); pthread_mutex_unlock(&g_rumble_mu);
    s2a_pad_vibration zero[2] = {{0}};
    rumble_submit(session, zero);
}
// —— 本地多手柄（Mac 双人 / 四人）：每个手柄按「连接顺序」占一个固定槽位（0..S2A_MAX_PADS-1），各自独立采样。
//    槽 0 与键盘 / 鼠标 / 触屏共用，只连一个手柄时行为与原来完全一致；active_pad 只留给六轴、震动和 Home 用。
//    原实现只有一个输入源（Switch 2 Pro 或最近有输入的那个系统手柄），两只手柄会合并成一位玩家，本地双人分不开。
//    Switch 2 Pro（S2Arm 连接程序 / 直连，s2a_mac_ns2_read）连着时它是唯一的手柄来源（同改前），占一个槽，身份是 ns2_slot_id。
#define S2A_MAX_PADS 4
static _Atomic uint32_t pad_buttons[S2A_MAX_PADS];
static _Atomic int32_t pad_sticks[S2A_MAX_PADS][4];
static _Atomic int pad_live = 1;   // 本次采样占到的最高槽位 + 1（键盘 / 鼠标 / 触屏也算一位）
// 槽位身份（分槽用）与系统手柄的强引用：手柄蓝牙休眠 / 断开时系统会释放 GCController，只存裸指针会变悬空，
//   下一次比较身份时就是野指针。强引用后对象不会提前释放，断开时靠整表重建清槽，置 nil 才真正释放。只在主线程读写。
static const void *pad_id[S2A_MAX_PADS];
static GCController *pad_owner[S2A_MAX_PADS];
static const char ns2_slot_id = 0;
// 按配置表把一只手柄的键名 / 轴名映射成 Switch 按键位 + 摇杆（不含键盘 / 鼠标；调用方负责叠加）
static void map_pad_inputs(NSDictionary *all, NSDictionary *axes, uint32_t *out_buttons, int32_t sticks[4]) {
    uint32_t buttons = 0;
    for (int i = 0; i < 4; i++) sticks[i] = 0;
    for (NSString *name in config[@"gamepad"]) if ([all[config[@"gamepad"][name]] boolValue]) action(name, &buttons, sticks);
    NSArray *names = @[@"LX", @"LY", @"RX", @"RY"];
    float dz = config[@"deadzone"] ? [config[@"deadzone"] floatValue] : .15;
    for (int i = 0; i < 4; i++) {
        NSDictionary *binding = config[@"axes"][names[i]];
        float v = [axes[binding[@"source"] ?: @""] floatValue];
        if (fabsf(v) > dz) sticks[i] += (int32_t)(v * ([binding[@"invert"] boolValue] ? -32767 : 32767));
    }
    *out_buttons = buttons;
}
static void sample_ns2_state(const ns2_state *ble, uint32_t *out_buttons, int32_t sticks[4]) {
    NSArray *codes = @[@"east", @"south", @"north", @"west", @"leftStick", @"rightStick",
        @"leftShoulder", @"rightShoulder", @"leftTrigger", @"rightTrigger", @"menu", @"options",
        @"dpadLeft", @"dpadUp", @"dpadRight", @"dpadDown"];
    NSMutableDictionary *all = [NSMutableDictionary new];
    for (int i = 0; i < 16; i++) all[codes[i]] = @((ble->buttons & (1u << i)) != 0);
    map_pad_inputs(all, @{@"leftX": @(ble->lx / 32767.0f), @"leftY": @(ble->ly / 32767.0f),
                          @"rightX": @(ble->rx / 32767.0f), @"rightY": @(ble->ry / 32767.0f)}, out_buttons, sticks);
}
static void sample_pad_state(GCExtendedGamepad *pad, uint32_t *out_buttons, int32_t sticks[4]) {
    // GameController 通常按物理方位上报（buttonA 在南侧）；Switch Pro 手柄在 macOS 上按键面字母上报（A 在东侧、X 在北侧）
    //   位序调共用的 s2a_pad_abxy_order（同 iOS controller.m publishSystem；审计 P2-213：两端各写一套，以后只改一处就会一端错）。order 按任天堂 A / B / X / Y = 东 / 南 / 北 / 西
    GCControllerButtonInput *face[4] = {pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY};
    int order[4]; s2a_pad_abxy_order(s2a_pad_kind(pad.controller.productCategory.UTF8String, [pad isKindOfClass:GCXboxGamepad.class],
        [pad isKindOfClass:GCDualShockGamepad.class] || [pad isKindOfClass:GCDualSenseGamepad.class]), s2a_pad_layout(), order);   // 按键布局（pad.c，同 iOS）
    NSDictionary *pad_buttons = @{@"east": face[order[0]], @"south": face[order[1]], @"north": face[order[2]], @"west": face[order[3]],
        @"leftShoulder": pad.leftShoulder, @"rightShoulder": pad.rightShoulder,
        @"leftTrigger": pad.leftTrigger, @"rightTrigger": pad.rightTrigger, @"menu": pad.buttonMenu,
        @"dpadLeft": pad.dpad.left, @"dpadRight": pad.dpad.right, @"dpadUp": pad.dpad.up, @"dpadDown": pad.dpad.down};
    NSMutableDictionary *inputs = [pad_buttons mutableCopy];
    if (pad.buttonOptions) inputs[@"options"] = pad.buttonOptions;
    if (pad.leftThumbstickButton) inputs[@"leftStick"] = pad.leftThumbstickButton;
    if (pad.rightThumbstickButton) inputs[@"rightStick"] = pad.rightThumbstickButton;
    NSMutableDictionary *all = [NSMutableDictionary new];
    for (NSString *code in inputs) all[code] = @([inputs[code] isPressed]);
    map_pad_inputs(all, @{@"leftX": @(pad.leftThumbstick.xAxis.value), @"leftY": @(pad.leftThumbstick.yAxis.value),
                          @"rightX": @(pad.rightThumbstick.xAxis.value), @"rightY": @(pad.rightThumbstick.yAxis.value)}, out_buttons, sticks);
}
// 只有通用物理描述的手柄：按标准键名读，位序与扩展手柄同一套（s2a_pad_abxy_order，类型按 productCategory 判）
static void sample_profile_state(GCController *c, uint32_t *out_buttons, int32_t sticks[4]) {
    GCPhysicalInputProfile *p = c.physicalInputProfile;
    GCControllerButtonInput *(^btn)(NSString *) = ^GCControllerButtonInput *(NSString *name) { return p.buttons[name]; };
    GCControllerButtonInput *face[4] = {btn(GCInputButtonA), btn(GCInputButtonB), btn(GCInputButtonX), btn(GCInputButtonY)};
    int order[4]; s2a_pad_abxy_order(s2a_pad_kind(c.productCategory.UTF8String, NO, NO), s2a_pad_layout(), order);
    NSMutableDictionary *all = [NSMutableDictionary new];
    NSString *faces[4] = {@"east", @"south", @"north", @"west"};
    for (int i = 0; i < 4; i++) all[faces[i]] = @(face[order[i]].isPressed);
    NSDictionary *named = @{@"leftShoulder": GCInputLeftShoulder, @"rightShoulder": GCInputRightShoulder, @"leftTrigger": GCInputLeftTrigger,
                            @"rightTrigger": GCInputRightTrigger, @"menu": GCInputButtonMenu, @"options": GCInputButtonOptions,
                            @"leftStick": GCInputLeftThumbstickButton, @"rightStick": GCInputRightThumbstickButton};
    for (NSString *code in named) all[code] = @(btn(named[code]).isPressed);
    GCControllerDirectionPad *dpad = p.dpads[GCInputDirectionPad], *ls = p.dpads[GCInputLeftThumbstick], *rs = p.dpads[GCInputRightThumbstick];
    all[@"dpadLeft"] = @(dpad.left.isPressed); all[@"dpadRight"] = @(dpad.right.isPressed); all[@"dpadUp"] = @(dpad.up.isPressed); all[@"dpadDown"] = @(dpad.down.isPressed);
    map_pad_inputs(all, @{@"leftX": @(ls.xAxis.value), @"leftY": @(ls.yAxis.value), @"rightX": @(rs.xAxis.value), @"rightY": @(rs.yAxis.value)}, out_buttons, sticks);
}
// 槽位计划 s2a_slot_plan 在 runtime/src/pad.c（iOS ios/controller.m 共用同一份规则）
static void sample_input(void) {
    int32_t kbd_sticks[4] = {0}; uint32_t kbd_buttons = 0;
    uint32_t slot_buttons[S2A_MAX_PADS] = {0};
    int32_t slot_sticks[S2A_MAX_PADS][4] = {{0}};
    GCExtendedGamepad *active = focused ? active_pad(GCController.controllers) : nil;
    sample_motion(active);
    if (active) rumble_select(active.controller);   // 失焦不换会话：切回来同一个手柄接着震
    if (focused) sample_home_quit(active);
    // 失焦 / 退出确认条打开：照旧不喂输入（发一份全零）。手柄槽位仍然要扫，否则窗口一失焦服务层就以为只剩 1 只手柄，会把玩家 2 的格子拆掉
    BOOL muted = !focused || g_hq.open;
    if (!muted) {
        NSDictionary *keyboard = config[@"keyboard"];
        NSUInteger consumed = 0;
        for (NSString *name in keyboard) {
            NSDictionary *binding = keyboard[name]; NSUInteger mods = [binding[@"modifiers"] unsignedIntegerValue];
            if (mods && (modifiers & mods) == mods && [keys containsObject:binding[@"code"]]) {
                action(name, &kbd_buttons, kbd_sticks); consumed |= mods;
            }
        }
        for (NSString *name in keyboard) {
            NSDictionary *binding = keyboard[name]; NSNumber *code = binding[@"code"];
            if ([binding[@"modifiers"] unsignedIntegerValue]) continue;
            unsigned k = code.unsignedIntValue;
            NSUInteger own_mod = (k == 56 || k == 60) ? 1 : (k == 59 || k == 62) ? 2 : (k == 58 || k == 61) ? 4 : 0;
            if (!(consumed & own_mod) && [keys containsObject:code]) action(name, &kbd_buttons, kbd_sticks);
        }
        for (NSString *name in config[@"mouse"]) if ([mouse containsObject:config[@"mouse"][name]]) action(name, &kbd_buttons, kbd_sticks);
    }
    // 在线的手柄（顺序 = 连接顺序）：Switch 2 Pro 一只 + 系统报上来的扩展手柄；数组留得比槽位多，超出的交给 s2a_slot_plan 判 -1 丢弃
    ns2_state ble;
    BOOL hasBLE = s2a_mac_ns2_read(&ble);
    const void *live_ids[9]; GCExtendedGamepad *live_pads[9]; GCController *live_ctrls[9] = {nil}; int n = 0;
    if (hasBLE) { live_ids[n] = &ns2_slot_id; live_pads[n] = nil; n++; }
    // Switch 2 Pro 是输入来源时系统手柄那一路不读（同改前；同一只手柄也可能出现在系统手柄列表里，两路都读会变成两个玩家）
    if (!hasBLE) for (GCController *c in GCController.controllers) {
        GCExtendedGamepad *p = c.extendedGamepad;
        if (!p && !pad_has_profile_buttons(c)) continue;   // 只有通用物理描述的手柄也进槽位（sample_profile_state）
        if (n >= 9) break;
        live_ids[n] = (__bridge const void *)c; live_pads[n] = p; live_ctrls[n] = c; n++;
    }
    int slot_of[9];
    int live = s2a_slot_plan(pad_id, live_ids, n, S2A_MAX_PADS, slot_of);
    // 断开清槽：整表重建，只有本轮还在的才写回（强引用随之释放，不会留悬空指针）
    for (int i = 0; i < S2A_MAX_PADS; i++) { pad_id[i] = NULL; pad_owner[i] = nil; }
    for (int j = 0; j < n; j++) {
        int s = slot_of[j];
        if (s < 0) continue;   // 超过 S2A_MAX_PADS 只：多出来的不参与
        pad_id[s] = live_ids[j];
        if (live_ids[j] == &ns2_slot_id) sample_ns2_state(&ble, &slot_buttons[s], slot_sticks[s]);
        else if (live_pads[j]) { pad_owner[s] = live_ctrls[j]; sample_pad_state(live_pads[j], &slot_buttons[s], slot_sticks[s]); }
        else { pad_owner[s] = live_ctrls[j]; sample_profile_state(live_ctrls[j], &slot_buttons[s], slot_sticks[s]); }
    }
    if (muted) {
        memset(slot_buttons, 0, sizeof slot_buttons); memset(slot_sticks, 0, sizeof slot_sticks);
    } else {
        slot_buttons[0] |= kbd_buttons;   // 槽 0 = 键盘 / 鼠标 / 触屏 + 第一只手柄
        for (int i = 0; i < 4; i++) slot_sticks[0][i] += kbd_sticks[i];
    }
    for (int s = 0; s < S2A_MAX_PADS; s++)
        for (int i = 0; i < 4; i++) slot_sticks[s][i] = MAX(-32767, MIN(32767, slot_sticks[s][i]));
    atomic_store(&pad_live, live);
    static int logged_live;   // 诊断：接上手柄 / 拔掉时打一行
    if (live != logged_live) { logged_live = live; fprintf(stderr, "[s2a] 手柄槽位：%d 个（含键盘 / 鼠标）\n", live); }
    for (int s = 0; s < S2A_MAX_PADS; s++) {
        atomic_store(&pad_buttons[s], slot_buttons[s]);
        for (int i = 0; i < 4; i++) atomic_store(&pad_sticks[s][i], slot_sticks[s][i]);
    }
    publish_input(slot_buttons[0], slot_sticks[0]);   // 玩家 1：旧 ABI + 事件驱动 ABI（含鼠标视角）
}
// 多手柄槽位（服务层 InputPump 按符号查；没导出时退回旧的单手柄 ABI）
__attribute__((visibility("default"), used)) int s2a_vpad_pad_count(void) { return atomic_load(&pad_live); }
__attribute__((visibility("default"), used)) uint32_t s2a_vpad_read_pad(int index, int32_t *sticks) {
    if (index < 0 || index >= S2A_MAX_PADS) { for (int i = 0; i < 4; i++) sticks[i] = 0; return 0; }
    uint32_t buttons = atomic_load_explicit(&pad_buttons[index], memory_order_seq_cst);
    for (int i = 0; i < 4; i++) sticks[i] = atomic_load_explicit(&pad_sticks[index][i], memory_order_seq_cst);
    return buttons;
}

// keyUp 可能在菜单或其他响应者处被消费。定时采样只核对本窗口已经接收的键，
// 不从系统状态新增按下，避免切回窗口时带入其他应用里的按键。
// 审计 P1-57：系统按键状态偶尔报错（按着却报松开）。原先报一次就删键、自动重复也恢复不了，再报一次不一致就永久停掉核对（之后漏掉的 keyUp 会粘键）。
//   现在：连续 KEY_UP_POLLS 次采样（120 Hz 下约 250 ms）都报松开才删键，记进 stale_keys；之后这个键的自动重复（keyDown:）证明它还按着，恢复。
//   核对一直开着，真正的 keyUp / 失焦 / 关机照旧立即清
// 审计 P1-34 / P2-34：修饰键只走 flagsChanged、没有自动重复，系统关掉按键重复时普通键也没有，鼠标原先根本不核对。
//   键盘（含修饰键）和鼠标共用 reconcile_held：stale 里的键之后采样到系统报按下也恢复（误报结束）。
//   只恢复本视图收到过按下、被采样删掉的键，不从系统状态新增（切回窗口时不带入其他应用里的按键）
enum { KEY_UP_POLLS = 30 };
static unsigned modifier_bit(unsigned k) { return k == 56 ? 1u : k == 59 ? 2u : k == 58 ? 4u : 0u; }
static void reconcile_held(NSMutableSet<NSNumber *> *held, NSMutableSet<NSNumber *> *stale, NSMutableDictionary<NSNumber *, NSNumber *> *polls,
                           BOOL (^is_down)(unsigned), void (^changed)(unsigned code, BOOL held_now)) {
    for (NSNumber *code in stale.allObjects) {
        if (!is_down(code.unsignedIntValue)) continue;
        [stale removeObject:code]; [polls removeObjectForKey:code]; [held addObject:code];
        if (changed) changed(code.unsignedIntValue, YES);
    }
    for (NSNumber *code in held.allObjects) {
        int n = is_down(code.unsignedIntValue) ? 0 : polls[code].intValue + 1;
        if (n < KEY_UP_POLLS) { polls[code] = @(n); continue; }
        [polls removeObjectForKey:code]; [held removeObject:code]; [stale addObject:code];
        if (changed) changed(code.unsignedIntValue, NO);
    }
}
static void release_stale_keys(void) {
    if (!key_up_polls) key_up_polls = [NSMutableDictionary new];
    if (!stale_keys) stale_keys = [NSMutableSet new];
    reconcile_held(keys, stale_keys, key_up_polls, ^BOOL(unsigned k) {
        unsigned right = k == 56 ? 60 : k == 59 ? 62 : k == 58 ? 61 : 0;
        return read_key_state(kCGEventSourceStateCombinedSessionState, (CGKeyCode)k) ||
               (right && read_key_state(kCGEventSourceStateCombinedSessionState, (CGKeyCode)right));
    }, ^(unsigned k, BOOL held_now) { if (held_now) modifiers |= modifier_bit(k); else modifiers &= ~modifier_bit(k); });
}
static void release_stale_mouse(void) {
    if (!mouse_up_polls) mouse_up_polls = [NSMutableDictionary new];
    if (!stale_mouse) stale_mouse = [NSMutableSet new];
    NSUInteger pressed = read_mouse_buttons();
    reconcile_held(mouse, stale_mouse, mouse_up_polls, ^BOOL(unsigned b) { return b < 64 && ((pressed >> b) & 1); }, nil);
}
static void poll_input(void) {
    install_pad_handlers();
    release_stale_keys();
    release_stale_mouse();
    sample_input();
}

// 游戏窗口的出图层：通用模式交给 NxGal（nxgal_window_set_layer），直连模式由直连层经 graphics/nvn/host_adapt.m front_metal_layer 取（没有前端窗口时为 NULL）
static CAMetalLayer *g_front_layer;
void *s2a_mac_front_layer(void) { return (__bridge void *)g_front_layer; }
// 层始终发布给直连入口；通用 NxGal 只在本次运行的 generic 模式接层。
// 不在这里初始化另一套渲染器，也不放宽 NxGal 的未初始化检查。
static void front_layer_attach(CAMetalLayer *layer) {
    g_front_layer = layer;
    if (s2a_gfx_mode() == S2A_GFX_GENERIC) nxgal_window_set_layer((__bridge void *)layer);
}
static void front_layer_detach(void) {
    if (s2a_gfx_mode() == S2A_GFX_GENERIC) nxgal_window_set_layer(NULL);
    g_front_layer = nil;
}
@interface S2AMetalView : NSView
@end
// 窗口所在屏的最高刷新（graphics/nvn/host/front.h 点名、审计 P1-80：Mac 原先没实现、恒为 0）：144 / 165 Hz 屏上要 60 Hz 的显示链接落到最近的刷新上，
//   帧步（hle_nvn.c front_screen_max_fps → shown_slack）据此不把准时帧判成迟到。主线程在建窗与换屏时刷新，任意线程读
static _Atomic int g_screen_max_fps;
int front_screen_max_fps(void) { return atomic_load(&g_screen_max_fps); }
static void screen_fps_note(NSWindow *w) {
    NSScreen *sc = w.screen ?: NSScreen.mainScreen; int hz = 0;
    if (@available(macOS 12.0, *)) hz = (int)sc.maximumFramesPerSecond;
    if (atomic_exchange(&g_screen_max_fps, hz) != hz) fprintf(stderr, "[s2a] 窗口所在屏最高刷新 %d Hz\n", hz);
}
@implementation S2AMetalView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    CAMetalLayer *metal = (CAMetalLayer *)self.layer;
    metal.contentsScale = self.window.backingScaleFactor ?: 1;
    CGSize size = CGSizeMake(self.bounds.size.width * metal.contentsScale, self.bounds.size.height * metal.contentsScale);
    if (size.width >= 1 && size.height >= 1) metal.drawableSize = size;   // 直连模式没有 NxGal 跟窗口尺寸，层的可画尺寸在这里跟上
    nxgal_window_set_size((int32_t)size.width, (int32_t)size.height);
    // 宽屏跟窗口比例（审计 P1-83：原先从不换屏幕宽，拉宽 / 全屏后逻辑分辨率仍 1920×1080、两侧黑；维护者 任何比例都满屏）：同 iOS 口径换屏，
    //   直连第三层下一个渲染遍前按新比例重出图（runtime/src/widen.c s2a_screen_fit，钉了原生 16:9 / 环境变量给定屏幕时不跟）
    if (size.width >= 1 && size.height >= 1) s2a_screen_fit((int)size.width, (int)size.height);
}
// 全屏时的 Esc（玩家反馈：进了全屏回不到窗口）：Esc 没映射游戏按键就直接退全屏（鼠标锁着一并释放）；映射了就照常给游戏，按住 1 秒退全屏。
//   ⌃⌘F、菜单「显示 → 退出全屏幕」、顶部绿色按钮走系统原生全屏，退出后回到进全屏前的窗口大小和位置（S2AMacDelegate windowDidExitFullScreen:）
static NSTimer *esc_hold;
static BOOL window_fullscreen_now(NSWindow *w) { return w && (w.styleMask & NSWindowStyleMaskFullScreen); }
static void window_fullscreen_toggle(NSWindow *w) { [w toggleFullScreen:nil]; }
static BOOL (*window_fullscreen)(NSWindow *) = window_fullscreen_now;   // 单测换桩（launchers/macos/Tests/input_test.m）
static void (*fullscreen_toggle)(NSWindow *) = window_fullscreen_toggle;
static BOOL esc_mapped(void) {
    NSDictionary *keyboard = config[@"keyboard"];
    for (NSString *name in keyboard) if ([keyboard[name][@"code"] intValue] == 53) return YES;
    return NO;
}
static void esc_hold_cancel(void) { [esc_hold invalidate]; esc_hold = nil; }
static void esc_hold_start(NSWindow *window) {
    esc_hold_cancel();
    __weak NSWindow *w = window;
    esc_hold = [NSTimer scheduledTimerWithTimeInterval:1 repeats:NO block:^(NSTimer *t) { (void)t;
        esc_hold = nil;
        if (!window_fullscreen(w) || !read_key_state(kCGEventSourceStateCombinedSessionState, 53)) return;
        [keys removeObject:@53]; [stale_keys removeObject:@53]; [key_up_polls removeObjectForKey:@53]; sample_input();   // 游戏那边松开这个键
        fprintf(stderr, "[s2a] Mac 全屏：按住 Esc 1 秒，退出全屏\n");
        fullscreen_toggle(w);
    }];
}
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 53 && !e.isARepeat && window_fullscreen(self.window)) {
        if (!esc_mapped()) {
            if (mouse_captured || mouse_release_pending) set_mouse_capture(NO);
            fprintf(stderr, "[s2a] Mac 全屏：Esc 退出全屏\n");
            fullscreen_toggle(self.window); return;
        }
        esc_hold_start(self.window);
    }
    if (e.keyCode == 53 && (mouse_captured || mouse_release_pending)) { set_mouse_capture(NO); return; }
    if (e.modifierFlags & NSEventModifierFlagCommand) { [super keyDown:e]; return; }
    if (!focused) return;
    if (e.isARepeat) {   // 按住由 keys 保持；重复事件只恢复被采样误删的键（stale_keys），不重建 keyUp 已释放的键
        [key_up_polls removeObjectForKey:@(e.keyCode)];
        if ([stale_keys containsObject:@(e.keyCode)]) { [stale_keys removeObject:@(e.keyCode)]; [keys addObject:@(e.keyCode)]; sample_input(); }
        return;
    }
    [stale_keys removeObject:@(e.keyCode)]; [keys addObject:@(e.keyCode)]; sample_input();
}
- (void)keyUp:(NSEvent *)e { if (e.keyCode == 53) esc_hold_cancel(); [keys removeObject:@(e.keyCode)]; [stale_keys removeObject:@(e.keyCode)]; [key_up_polls removeObjectForKey:@(e.keyCode)]; sample_input(); }
- (void)flagsChanged:(NSEvent *)e {
    modifiers = ((e.modifierFlags & NSEventModifierFlagShift) ? 1 : 0) |
                ((e.modifierFlags & NSEventModifierFlagControl) ? 2 : 0) |
                ((e.modifierFlags & NSEventModifierFlagOption) ? 4 : 0);
    unsigned k = e.keyCode;
    BOOL down = ((k == 56 || k == 60) && (modifiers & 1)) || ((k == 59 || k == 62) && (modifiers & 2)) || ((k == 58 || k == 61) && (modifiers & 4));
    // The mapping editor stores left/right modifiers as the same key code.
    unsigned canonical = k == 60 ? 56 : k == 62 ? 59 : k == 61 ? 58 : k;
    // 审计 P1-34：与 keyDown / keyUp 一样，按下和松开都清掉这个键的误报记录
    [stale_keys removeObject:@(canonical)]; [key_up_polls removeObjectForKey:@(canonical)];
    if (down) [keys addObject:@(canonical)]; else [keys removeObject:@(canonical)];
    sample_input();
}
- (void)mouseDown:(NSEvent *)e {
    if (e.buttonNumber == 0 && !mouse_captured && focused && left_click_touches()) {   // 先于视角锁定：游戏声明触屏配置 + 缺省键位时左键让给触屏
        touch_begin(self.bounds.size, self.window.backingScaleFactor ?: 1, [self convertPoint:e.locationInWindow fromView:nil]); return;
    }
    if (e.buttonNumber == 0 && !mouse_captured && camera_mouse()) { set_mouse_capture(YES); return; }
    [stale_mouse removeObject:@(e.buttonNumber)]; [mouse_up_polls removeObjectForKey:@(e.buttonNumber)];
    [mouse addObject:@(e.buttonNumber)]; sample_input();
}
- (void)mouseUp:(NSEvent *)e {
    if (e.buttonNumber == 0 && touch_owner) { touch_end(); return; }
    [mouse removeObject:@(e.buttonNumber)]; [stale_mouse removeObject:@(e.buttonNumber)]; [mouse_up_polls removeObjectForKey:@(e.buttonNumber)];
    sample_input();
}
- (void)rightMouseDown:(NSEvent *)e { [self mouseDown:e]; }
- (void)rightMouseUp:(NSEvent *)e { [self mouseUp:e]; }
- (void)otherMouseDown:(NSEvent *)e { [self mouseDown:e]; }
- (void)otherMouseUp:(NSEvent *)e { [self mouseUp:e]; }
- (void)mouseMoved:(NSEvent *)e {
    if (!focused || !mouse_captured || !camera_mouse()) return;
    NSDictionary *o = config[@"mouseOptions"];
    atomic_fetch_add_explicit(&mouse_dx, (int64_t)llround(e.deltaX * 1500 * [o[@"sensitivityX"] doubleValue] * ([o[@"invertX"] boolValue] ? -1 : 1)), memory_order_relaxed);
    atomic_fetch_add_explicit(&mouse_dy, (int64_t)llround(-e.deltaY * 1500 * [o[@"sensitivityY"] doubleValue] * ([o[@"invertY"] boolValue] ? -1 : 1)), memory_order_relaxed);
}
- (void)mouseDragged:(NSEvent *)e {
    if (touch_owner) { touch_move(self.bounds.size, self.window.backingScaleFactor ?: 1, [self convertPoint:e.locationInWindow fromView:nil]); return; }
    [self mouseMoved:e];
}
- (void)rightMouseDragged:(NSEvent *)e { [self mouseMoved:e]; }
@end

// 游戏内提示条（文案在 s2a_direct_prompt.h；存档不能原子提交、本地联机等）：贴画面顶部居中，不盖住画面中部；
//   带两个按钮的 30 秒没理会按拒绝收起，确认条按给定秒数自动收起。点完把键盘焦点还给画面，游戏输入不断
@interface S2APromptBanner : NSVisualEffectView
@property(copy) void (^onAnswer)(BOOL accept);
- (void)acceptTapped;
@end
@implementation S2APromptBanner {
    NSTextField *_title, *_body; NSButton *_accept, *_decline; NSInteger _gen;
}
static NSTextField *banner_label(CGFloat size, NSFontWeight weight) {
    NSTextField *t = [NSTextField wrappingLabelWithString:@""]; t.font = [NSFont systemFontOfSize:size weight:weight];
    t.textColor = NSColor.labelColor; t.selectable = NO; t.translatesAutoresizingMaskIntoConstraints = NO; return t;
}
- (instancetype)init {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.material = NSVisualEffectMaterialHUDWindow; self.blendingMode = NSVisualEffectBlendingModeWithinWindow; self.state = NSVisualEffectStateActive;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    self.wantsLayer = YES; self.layer.cornerRadius = 12; self.layer.masksToBounds = YES; self.translatesAutoresizingMaskIntoConstraints = NO; self.hidden = YES;
    _title = banner_label(14, NSFontWeightSemibold); _body = banner_label(13, NSFontWeightRegular); _body.textColor = NSColor.secondaryLabelColor;
    _accept = [NSButton buttonWithTitle:@"" target:self action:@selector(acceptTapped)]; _accept.keyEquivalent = @"";
    _accept.bezelColor = NSColor.controlAccentColor;
    _decline = [NSButton buttonWithTitle:@"" target:self action:@selector(declineTapped)];
    for (NSButton *b in @[_accept, _decline]) { b.controlSize = NSControlSizeRegular; b.refusesFirstResponder = YES; }
    NSStackView *buttons = [NSStackView stackViewWithViews:@[_decline, _accept]]; buttons.spacing = 8;
    NSStackView *text = [NSStackView stackViewWithViews:@[_title, _body]]; text.orientation = NSUserInterfaceLayoutOrientationVertical; text.alignment = NSLayoutAttributeLeading; text.spacing = 2;
    NSStackView *row = [NSStackView stackViewWithViews:@[text, buttons]]; row.spacing = 16; row.alignment = NSLayoutAttributeCenterY;
    row.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16], [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:12], [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
        [self.widthAnchor constraintLessThanOrEqualToConstant:560], [text.widthAnchor constraintLessThanOrEqualToConstant:340]]];
    return self;
}
// 本地联机在这台 Mac 上起不来（审计 P1-59）：服务层 S2A_LanState 位或记原因（1 宿主没有局域网发现 / 2 发现启动失败，services/S2A.Services/Host.cs）。
//   原先只打一行红日志，游戏里搜索一直是空的、玩家不知道为什么。每秒查一次（游戏第一次初始化本地联机后才有值），非 0 提示一次。服务层没链时取不到就不查
static int (*lan_state)(void);
static BOOL lan_warned;
static NSString *lan_warning(void) {
    static BOOL looked;
    if (!looked) { looked = YES; if (!lan_state) lan_state = (int (*)(void))dlsym(RTLD_DEFAULT, "S2A_LanState"); }
    if (lan_warned || !lan_state) return nil;
    int state = lan_state();
    if (!state) return nil;
    lan_warned = YES;
    fprintf(stderr, "[s2a] Mac 本地联机：局域网发现不可用（原因位 %d：1 宿主没有局域网发现 / 2 发现启动失败），已提示玩家\n", state);
    if (state & 1) return @"这台 Mac 暂时不能在局域网里查找其他设备，游戏里的本地联机搜索不到别人。";
    return @"本地联机没能启动，搜索不到其他设备。可以重启游戏再试。";
}
// accept 为 nil = 只有「知道了」的确认条
- (void)showTitle:(NSString *)title body:(NSString *)body accept:(NSString *)accept decline:(NSString *)decline seconds:(double)seconds {
    _title.stringValue = title; _title.hidden = title.length == 0; _body.stringValue = body;
    _accept.title = accept ?: @(S2A_DPROMPT_OK); _decline.title = decline ?: @""; _decline.hidden = accept == nil;
    self.hidden = NO; NSInteger gen = ++_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self->_gen && !self.hidden) { if (accept) [self declineTapped]; else self.hidden = YES; } });
}
- (void)answer:(BOOL)accept { void (^cb)(BOOL) = self.onAnswer; self.onAnswer = nil; self.hidden = YES; if (cb) cb(accept); [self.window makeFirstResponder:self.superview]; }
- (void)acceptTapped { [self answer:YES]; }
- (void)declineTapped { [self answer:NO]; }
// 横幅盖在画面上，命中测试只把按钮放过去：其余点落到下面的画面，免得顶部居中那一块吃掉相机拖动 / 点击
- (NSView *)hitTest:(NSPoint)point { NSView *v = [super hitTest:point]; return [v isKindOfClass:NSButton.class] ? v : nil; }
@end

@interface S2AMacDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
@property(strong) NSWindow *window;
@property(strong) NSTimer *timer, *promptTimer;
@property(strong) S2APromptBanner *banner;
@property(strong) S2AMacInputGuide *inputGuide;
@property(strong) NSMenuItem *controllerStatus;
@property BOOL ns2ReconnectPending;
@property BOOL ns2RelayDisconnectNoticeShown;
@property NSRect windowedFrame;   // 进全屏前的窗口位置大小，退全屏时放回
@end
static __weak S2AMacDelegate *g_delegate;
@implementation S2AMacDelegate
- (void)connectNS2:(id)sender {
    self.ns2ReconnectPending = YES;
    if (s2a_mac_ns2_connect())
        [self.banner showTitle:@"Switch 2 Pro" body:@"正在连接 S2Arm 的手柄通道。若未连上，请回到 S2Arm 的手柄菜单重新连接。" accept:nil decline:nil seconds:10];
    else
        [self.banner showTitle:@"Switch 2 Pro" body:@"未能连接 S2Arm 手柄通道。请回到 S2Arm 手动连接后再重试。" accept:nil decline:nil seconds:8];
}
- (void)disconnectNS2:(id)sender {
    self.ns2ReconnectPending = NO;
    s2a_mac_ns2_disconnect();
}
- (void)testNS2Rumble:(id)sender {
    uint64_t session = s2a_pad_rumble_session();
    if (!session) return;
    const s2a_pad_vibration pair[2] = {{.15f, 160, .0f, 320}, {.0f, 160, .15f, 320}};
    s2a_pad_set_rumble_pair(session, pair);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ s2a_pad_stop_rumble(session); });
}
- (void)pollPrompt {
    ns2_status controller = s2a_mac_ns2_status();
    if (controller == NS2_STATUS_READY) {
        self.ns2ReconnectPending = YES;
        self.ns2RelayDisconnectNoticeShown = NO;
    }
    const char *relay = getenv("S2A_NS2_SOCKET");
    BOOL relayMode = relay && *relay;
    // 开局时 S2Arm 可能还没开连接程序（玩家开局后才连手柄）：通道文件出现才去连，接上前不提示（ns2_controller.c s2a_mac_ns2_relay_due）
    if (self.ns2ReconnectPending && s2a_mac_ns2_relay_due(controller, relay)) s2a_mac_ns2_connect();
    if (self.ns2ReconnectPending && (controller == NS2_STATUS_ERROR || controller == NS2_STATUS_DISCONNECTED)) {
        if (relayMode) {
            if (!self.ns2RelayDisconnectNoticeShown) {
                [self.banner showTitle:@"Switch 2 Pro" body:@"S2Arm 手柄连接已中断；重新连接后游戏会自动接回。" accept:nil decline:nil seconds:12];
                self.ns2RelayDisconnectNoticeShown = YES;
            }
            // S2Arm may be starting a fresh helper; keep trying the stable relay socket.
            s2a_mac_ns2_connect();
        } else {
            // A standalone direct connection gets one manual scan window.
            self.ns2ReconnectPending = NO;
            s2a_mac_ns2_connect();
            [self.banner showTitle:@"Switch 2 Pro" body:@"正在重新搜寻手柄（一分钟）。请按键唤醒；仍未连上时请长按 SYNC。" accept:nil decline:nil seconds:12];
        }
    }
    NSString *state = controller == NS2_STATUS_READY ? @"已连接" :
        controller == NS2_STATUS_SCANNING ? @"搜寻中" :
        controller == NS2_STATUS_CONNECTING || controller == NS2_STATUS_INITIALIZING ? @"连接中" :
        controller == NS2_STATUS_UNAVAILABLE ? @"蓝牙不可用，请检查授权" :
        controller == NS2_STATUS_ERROR ? @"连接失败，请重试" : @"未连接";
    // 菜单这一行照连着的型号写（Joy-Con 2 左 / 右 / 一对，#520）；没连时写 Switch 手柄
    self.controllerStatus.title = [NSString stringWithFormat:@"%s：%@", s2a_mac_ns2_kind_name(s2a_mac_ns2_kind()), state];
    // 存档不能原子提交（审计 P2-13；判定与 iOS 共用 runtime/src/direct_prompt.c s2a_save_atomic_poll）：非 0 提示一次
    if (s2a_save_atomic_poll()) [self.banner showTitle:@S2A_DPROMPT_SAVE_ATOMIC_TITLE body:@S2A_DPROMPT_SAVE_ATOMIC_MAC accept:nil decline:nil seconds:15];
    // 横幅正显示别的提醒时先不查，等它收起再提示，免得互相盖掉
    NSString *lan = self.banner.hidden ? lan_warning() : nil;
    if (lan) [self.banner showTitle:@"本地联机" body:lan accept:nil decline:nil seconds:15];
}
- (void)shutdown {
    display_focus_publish_ex(NO, NO);
    set_mouse_capture(NO); focused = NO; s2a_pad_set_active(0); reset_input();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ s2a_mac_ns2_detach(); s2a_host_shutdown("Mac 窗口关闭"); });
}
// 菜单栏「切换游戏」：先留标记（S2A_RETURN_MARKER，开局作业给的路径），再走关窗同一条收尾（等存档写完）；作业见到标记，启动器回到游戏库并切到前台。
//   不二次确认，同菜单栏「退出」。标记写不了也照样退出（只是启动器停在这局的结果页）
- (void)switchGame:(id)sender {
    (void)sender; const char *marker = getenv("S2A_RETURN_MARKER");
    int fd = marker && *marker ? open(marker, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600) : -1;
    if (fd >= 0) close(fd); else fprintf(stderr, "[s2a] 【红】切换游戏：回游戏库标记写不了（%s，errno %d），照样退出\n", marker ? marker : "未给", errno);
    fprintf(stderr, "[s2a] 菜单栏切换游戏：收尾退出，启动器回到游戏库\n");
    [self shutdown];
}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self shutdown]; return NO; }
- (void)toggleFullScreenItem:(id)sender { (void)sender; fullscreen_toggle(self.window); }
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleFullScreenItem:))
        item.title = window_fullscreen(self.window) ? (s2a_ui_zh() ? @"退出全屏幕" : @"Exit Full Screen") : (s2a_ui_zh() ? @"进入全屏幕" : @"Enter Full Screen");
    return YES;
}
- (void)windowWillEnterFullScreen:(NSNotification *)note { (void)note; self.windowedFrame = self.window.frame; }
- (void)windowDidExitFullScreen:(NSNotification *)note { (void)note; esc_hold_cancel(); if (!NSIsEmptyRect(self.windowedFrame)) [self.window setFrame:self.windowedFrame display:YES]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender { (void)sender; [self shutdown]; return NSTerminateCancel; }
- (void)windowDidBecomeKey:(NSNotification *)note { (void)note; display_focus_publish(NSApp.isActive && self.window.isKeyWindow); if (mouse_release_pending) set_mouse_capture(NO); focused = YES; s2a_pad_set_active(1); reset_input(); }
- (void)windowDidResignKey:(NSNotification *)note { (void)note; display_focus_publish(NO); set_mouse_capture(NO); focused = NO; s2a_pad_set_active(0); reset_input(); }
- (void)applicationDidResignActive:(NSNotification *)note { (void)note; display_focus_publish(NO); set_mouse_capture(NO); focused = NO; s2a_pad_set_active(0); reset_input(); }
- (void)applicationDidBecomeActive:(NSNotification *)note { (void)note; display_focus_publish(NSApp.isActive && self.window.isKeyWindow); focused = self.window.isKeyWindow; }
@end

// 确认条：打开时游戏失焦（同 Switch 的 HOME 菜单）、不收手柄输入；A / 点「退出」走关窗同一条收尾（等存档写完），B / Home / 点「回到游戏」/ 30 秒没理会收起
static void home_quit_ui(s2a_hq_action action) {
    S2AMacDelegate *d = g_delegate;
    if (!d) return;
    switch (action) {
        case S2A_HQ_OPEN:
            fprintf(stderr, "[s2a] 手柄按住 Home：弹出退出确认\n");
            display_focus_publish(NO);
            d.banner.onAnswer = ^(BOOL accept) { s2a_hq_close(&g_hq); if (accept) [g_delegate shutdown]; else display_focus_publish(NSApp.isActive && g_delegate.window.isKeyWindow); };
            [d.banner showTitle:@S2A_DPROMPT_HOME_QUIT_TITLE body:@S2A_DPROMPT_HOME_QUIT_BODY accept:@S2A_DPROMPT_HOME_QUIT_ACCEPT decline:@S2A_DPROMPT_HOME_QUIT_DECLINE seconds:30];
            break;
        case S2A_HQ_QUIT: [g_delegate shutdown]; d.banner.onAnswer = nil; d.banner.hidden = YES; fprintf(stderr, "[s2a] 手柄按 A：退出游戏\n"); break;
        case S2A_HQ_CANCEL: d.banner.onAnswer = nil; d.banner.hidden = YES; display_focus_publish(NSApp.isActive && d.window.isKeyWindow); break;
        default: break;
    }
}

// 整块面板穿透鼠标；refusesFirstResponder 本身并不能避免 NSTextField 截住点击。
@interface S2AHUDPanel : NSView
@property(nonatomic, strong) NSTextField *text;
@end
@implementation S2AHUDPanel
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO; self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.8].CGColor;
        self.layer.cornerRadius = 10; self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.18].CGColor;
        self.text = [NSTextField wrappingLabelWithString:@""];
        self.text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        self.text.textColor = NSColor.whiteColor; self.text.refusesFirstResponder = YES;
        self.text.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:self.text];
        [NSLayoutConstraint activateConstraints:@[
            [self.text.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [self.text.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [self.text.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
            [self.text.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10]]];
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

void s2a_front_run(void (*guest_main)(void)) {
    (void)guest_main;
    @autoreleasepool {
        keys = [NSMutableSet set]; mouse = [NSMutableSet set];
        s2a_input_config decoded;
        int inputError = mac_input_config_read(getenv("S2A_INPUT_CONFIG"), &decoded);
        if (inputError) { fprintf(stderr, "[s2a] 【红】Mac 输入配置损坏，拒绝启动（%d: %s）\n", inputError, s2a_input_config_error_message(inputError)); exit(2); }
        config = input_config_dictionary(&decoded);
        s2a_mac_ns2_set_back_buttons(decoded.back_buttons[0] < 0 ? 0 : (1u << decoded.back_buttons[0]),
                                    decoded.back_buttons[1] < 0 ? 0 : (1u << decoded.back_buttons[1]));
        apply_mouse_options();
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        S2AMacDelegate *delegate = [S2AMacDelegate new]; app.delegate = delegate; g_delegate = delegate;
        // 游戏日历（#863）：Mac 睡眠时游戏计数器停（同 Switch 睡眠），唤醒后把睡掉的时长补进 Ryujinx 稳态时钟
        [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; s2a_clock_catchup(); s2a_host_sleep_set(0); }];
        // 系统睡眠报给服务层（接口 v2.15）：psc 向游戏发休眠请求，唤醒时发唤醒请求
        [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; s2a_host_sleep_set(1); }];
        NSMenu *menu = [NSMenu new]; NSMenuItem *root = [NSMenuItem new]; [menu addItem:root];
        NSMenu *application = [NSMenu new];
        NSMenuItem *controls = [application addItemWithTitle:@"查看键位 / Controls" action:@selector(show) keyEquivalent:@"k"];
        if (getenv("S2A_RETURN_MARKER")) {   // 启动器起的局才有（作业给标记路径）；直接跑宿主没有游戏库可回，不显示
            NSMenuItem *sw = [application addItemWithTitle:s2a_ui_zh() ? @S2A_DPROMPT_SWITCH_GAME_TITLE : @S2A_DPROMPT_SWITCH_GAME_TITLE_EN action:@selector(switchGame:) keyEquivalent:@""];
            sw.target = delegate;
        }
        [application addItemWithTitle:@"Quit S2Arm Game" action:@selector(terminate:) keyEquivalent:@"q"];
        root.submenu = application;
        NSMenuItem *inputRoot = [NSMenuItem new]; NSMenu *inputMenu = [[NSMenu alloc] initWithTitle:@"输入"];
        NSMenuItem *hint = [inputMenu addItemWithTitle:@"点击画面锁定鼠标视角；Esc 释放" action:NULL keyEquivalent:@""]; hint.enabled = NO;
        [inputMenu addItem:NSMenuItem.separatorItem];
        delegate.controllerStatus = [inputMenu addItemWithTitle:@"Switch 2 Pro：未连接" action:NULL keyEquivalent:@""];
        delegate.controllerStatus.enabled = NO;
        NSMenuItem *connect = [inputMenu addItemWithTitle:@"连接 / 重试 Switch 2 Pro…" action:@selector(connectNS2:) keyEquivalent:@""];
        connect.target = delegate;
        NSMenuItem *disconnect = [inputMenu addItemWithTitle:@"中断 Switch 2 Pro" action:@selector(disconnectNS2:) keyEquivalent:@""];
        disconnect.target = delegate;
        NSMenuItem *rumble = [inputMenu addItemWithTitle:@"测试手柄震动" action:@selector(testNS2Rumble:) keyEquivalent:@""];
        rumble.target = delegate;
        inputRoot.submenu = inputMenu; [menu addItem:inputRoot];
        // 「显示」菜单的全屏项（原先没有：⌃⌘F 和菜单都退不出全屏）；系统不再自动插一份重复的
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
        NSMenuItem *viewRoot = [NSMenuItem new]; NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:s2a_ui_zh() ? @"显示" : @"View"];
        NSMenuItem *fullScreen = [viewMenu addItemWithTitle:s2a_ui_zh() ? @"进入全屏幕" : @"Enter Full Screen" action:@selector(toggleFullScreenItem:) keyEquivalent:@"f"];
        fullScreen.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand; fullScreen.target = delegate;
        NSMenuItem *escHint = [viewMenu addItemWithTitle:s2a_ui_zh() ? @"全屏时 Esc 退出（Esc 映射了游戏按键时按住 1 秒）" : @"In full screen, Esc exits (hold 1 s if Esc is mapped to a game button)" action:NULL keyEquivalent:@""];
        escHint.enabled = NO;
        viewRoot.submenu = viewMenu; [menu addItem:viewRoot]; app.mainMenu = menu;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 720)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        NSDictionary *gameIdentity = s2a_mac_guide_identity();
        window.title = gameIdentity[@"name"];
        window.contentMinSize = NSMakeSize(640, 360); window.delegate = delegate; window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
        S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 720)];
        view.wantsLayer = YES; CAMetalLayer *layer = [CAMetalLayer layer]; layer.opaque = YES;
        view.layer = layer; window.contentView = view; window.acceptsMouseMovedEvents = YES;
        delegate.window = window;
        screen_fps_note(window);
        [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeScreenNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { screen_fps_note(n.object); }];
        S2APromptBanner *banner = [S2APromptBanner new]; [view addSubview:banner]; delegate.banner = banner;
        [NSLayoutConstraint activateConstraints:@[[banner.topAnchor constraintEqualToAnchor:view.topAnchor constant:16], [banner.centerXAnchor constraintEqualToAnchor:view.centerXAnchor]]];
        front_layer_attach(layer);
        // S2Arm 诊断浮层：限宽并留内边距，不接鼠标；游戏纹理读回不含此 NSView（官方 Metal HUD 的截图行为需另验）。
        if (s2a_hud_on()) {
            S2AHUDPanel *hud = [S2AHUDPanel new]; [view addSubview:hud];
            NSLayoutConstraint *preferred = [hud.widthAnchor constraintEqualToConstant:420]; preferred.priority = NSLayoutPriorityDefaultHigh;
            [NSLayoutConstraint activateConstraints:@[[hud.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],
                [hud.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:8],
                [hud.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor constant:-16], preferred]];
            const char *bid = getenv("S2A_BUILD_ID");
            fprintf(stderr, "[s2a] 开发浮层：开（S2A_HUD=1，每 0.5 秒刷新，不进截图 / 存帧）\n");
            void (^tick)(void) = ^{
                NSScreen *sc = window.screen ?: NSScreen.mainScreen; CGFloat k = sc.backingScaleFactor;
                const char *th = NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateNominal ? "正常" : NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateFair ? "偏热"
                    : NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateSerious ? "热" : "过热";
                const char *metal = getenv("MTL_HUD_ENABLED");
                s2a_hud_host h = { th, bid, NAN, sc.frame.size.width * k, sc.frame.size.height * k, -1, metal && !strcmp(metal, "1") };
                char t[4096]; s2a_hud_text(t, sizeof t, &h);
                NSString *text = [NSString stringWithUTF8String:t];
                NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
                    NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSForegroundColorAttributeName: NSColor.whiteColor}];
                NSRange title = [text rangeOfString:@"\n"];
                if (title.location != NSNotFound) [styled addAttribute:NSFontAttributeName value:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold] range:NSMakeRange(0, title.location)];
                hud.text.preferredMaxLayoutWidth = MAX(1, MIN(420, view.bounds.size.width - 16) - 20);
                hud.text.attributedStringValue = styled;
            };
            tick(); [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t; tick(); }];
        }
        [view setNeedsLayout:YES]; [window center]; [window makeKeyAndOrderFront:nil]; [window makeFirstResponder:view];
        [app activateIgnoringOtherApps:YES]; focused = YES;
        s2a_pad_set_active(1);
        install_pad_handlers();
        display_focus_publish(app.isActive && window.isKeyWindow);
        delegate.inputGuide = [[S2AMacInputGuide alloc] initWithName:window.title gameID:gameIdentity[@"gameId"] mapping:config gameWindow:window];
        controls.target = delegate.inputGuide;
        delegate.timer = [NSTimer scheduledTimerWithTimeInterval:1.0/120 repeats:YES block:^(NSTimer *t) { (void)t; poll_input(); }];
        delegate.promptTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { (void)t; if (mouse_release_pending) set_mouse_capture(NO); [delegate pollPrompt]; }];
        const char *relaySocket = getenv("S2A_NS2_SOCKET");
        const char *launcherAutoConnect = getenv("S2A_NS2_AUTOCONNECT");
        BOOL shouldAutoConnect = (relaySocket && *relaySocket) ||
            (launcherAutoConnect && !strcmp(launcherAutoConnect, "1"));
        if (shouldAutoConnect) {
            delegate.ns2ReconnectPending = YES;
            fprintf(stderr, "[Mac NS2] Connecting to the S2Arm controller relay\n");
            s2a_mac_ns2_connect();
        }
        [app run];
        s2a_pad_set_active(0);
        display_focus_publish_ex(NO, NO);
        set_mouse_capture(NO); focused = NO; reset_input(); s2a_mac_ns2_detach(); front_layer_detach();
    }
}
// GPU 卡住暂停（11-13；graphics/nvn/host_adapt.m s2a_gpu_stuck 经 dlsym 调，Metal 完成回调线程）：连续 3 帧各过 3 秒。冻游戏线程（不再往 GPU 送新活，已交的跑完），
//   弹「继续玩 / 退出」：继续 → 清判据（s2a_gpu_stuck_resume）、解冻；退出 → 收尾（同关窗）。文案与 iOS 同一套（runtime/include/s2a_ui_text.h）
void s2a_mac_gpu_stuck(const char *why) {
    (void)why;   // 原文已打进 host.log
    s2a_guest_freeze(1);
    dispatch_async(dispatch_get_main_queue(), ^{
        int zh = s2a_ui_zh();
        NSAlert *a = [NSAlert new];
        a.messageText = zh ? @S2A_GPU_STUCK_TITLE : @S2A_GPU_STUCK_TITLE_EN;
        a.informativeText = zh ? @S2A_GPU_STUCK_BODY : @S2A_GPU_STUCK_BODY_EN;
        [a addButtonWithTitle:zh ? @S2A_GPU_STUCK_GO : @S2A_GPU_STUCK_GO_EN];
        [a addButtonWithTitle:zh ? @S2A_GPU_STUCK_QUIT : @S2A_GPU_STUCK_QUIT_EN];
        fprintf(stderr, "[s2a] 【红】Mac 壳：GPU 卡住 → 冻结游戏线程、弹「继续玩 / 退出」\n");
        if ([a runModal] == NSAlertFirstButtonReturn) {
            void (*resume)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "s2a_gpu_stuck_resume"); if (resume) resume();   // 直连层 host_adapt.m：按名取（不链直连层的构建 / 输入单测里没有它）
            s2a_guest_freeze(0);
            fprintf(stderr, "[s2a] GPU 卡住暂停：玩家选继续玩，游戏线程解冻\n");
        } else {
            fprintf(stderr, "[s2a] GPU 卡住暂停：玩家选退出，收尾\n");
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ s2a_host_shutdown("GPU 卡住，玩家选退出"); });
        }
    });
}
