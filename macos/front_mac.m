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
#include "../runtime/include/s2a_qos.h"
#include "../runtime/include/phone_axes.h"
#include "joycon_imu.h"
#import "input_guide.h"
#include "ns2_controller.h"
#include "hid_pad.h"
#include "ns2_relay.h"
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
#include <sys/stat.h>
#include "../runtime/include/s2a_direct_prompt.h"
#include "../runtime/include/s2a_gfx_mode.h"
#include "../runtime/include/s2a_hud.h"
#include "../runtime/include/s2a_home_quit.h"
#include "../runtime/include/s2a_mac_focus.h"
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
// 玩家可关（#989，启动设置「切到别的窗口时暂停」关 → S2A_FOCUS_PAUSE=0）：Mac 上切出去看攻略 / 第二块屏是常事，关掉后失焦只报焦点消息、不冻结
static BOOL focus_pause_off(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_FOCUS_PAUSE"); v = e && !strcmp(e, "0"); } return v; }
// 关窗 / 收尾也发布「没焦点」，但不冻结（may_freeze = NO）：收尾要等客机线程退出
static void display_focus_publish_ex(BOOL active, BOOL may_freeze) {
    s2a_mac_ns2_focus(active);
    if (active && !atomic_load(&display_focused)) atomic_store(&display_focus_since, now_ns());
    atomic_store(&display_focused, active);
    s2a_host_focus_set(active);
    if (!active && may_freeze && !focus_frozen && !focus_pause_off() && s2a_focus_suspend()) { focus_frozen = YES; guest_clock_freeze_for(3, 1); s2a_guest_freeze(1); fprintf(stderr, "[s2a] Mac 失焦：游戏要求失焦暂停，冻结客机\n"); }
    else if ((active || !may_freeze) && focus_frozen) { focus_frozen = NO; s2a_guest_freeze(0); guest_clock_freeze_for(3, 0); fprintf(stderr, "[s2a] Mac 回到焦点 / 收尾：放开客机\n"); }
}
static void display_focus_publish(BOOL active) { display_focus_publish_ex(active, YES); }
// 游戏窗口对游戏算不算前台（#279）：我们自己挂在游戏窗口上的系统输入框是 key window 时照旧算前台，否则游戏收到失焦会把输入当取消
int s2a_text_input_mac_is_input_window(NSWindow *w);   // macos/textinput_mac.m
static BOOL game_window_focused(NSWindow *game) {
    NSWindow *key = NSApp.keyWindow;
    return s2a_mac_game_focused(NSApp.isActive, game && game.isKeyWindow, s2a_text_input_mac_is_input_window(key), game && key.sheetParent == game);
}
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
// R5：HID 键盘区的原始键态（游戏读键盘区原先只有 ActivateKeyboard 时的 17 条空条目，读键盘区的游戏按什么都没反应）。
//   Mac 键码（HIToolbox kVK_*）→ HID usage：键码与 usage 都是物理键身份，与键盘布局无关。0 = 不进键盘区
//   （Command 组合键 keyDown: 已交系统、音量 / 亮度键系统消费、fn 无 usage、英数 / 假名只切输入法）。
//   右修饰键在 flagsChanged 已并成左键码（键位编辑器同款约定），表里的右侧值只是备用
static const uint8_t mac_key_hid[128] = {
    [0x00] = 0x04, [0x01] = 0x16, [0x02] = 0x07, [0x03] = 0x09,   // A S D F
    [0x04] = 0x0B, [0x05] = 0x0A, [0x06] = 0x1D, [0x07] = 0x1B,   // H G Z X
    [0x08] = 0x06, [0x09] = 0x19, [0x0B] = 0x05, [0x0C] = 0x14,   // C V B Q
    [0x0D] = 0x1A, [0x0E] = 0x08, [0x0F] = 0x15, [0x10] = 0x1C,   // W E R Y
    [0x11] = 0x17, [0x12] = 0x1E, [0x13] = 0x1F, [0x14] = 0x20,   // T 1 2 3
    [0x15] = 0x21, [0x16] = 0x23, [0x17] = 0x22, [0x18] = 0x2E,   // 4 6 5 =
    [0x19] = 0x26, [0x1A] = 0x24, [0x1B] = 0x2D, [0x1C] = 0x25,   // 9 7 - 8
    [0x1D] = 0x27, [0x1E] = 0x30, [0x1F] = 0x12, [0x20] = 0x18,   // 0 ] O U
    [0x21] = 0x2F, [0x22] = 0x0C, [0x23] = 0x13, [0x24] = 0x28,   // [ I P Return
    [0x25] = 0x0F, [0x26] = 0x0D, [0x27] = 0x34, [0x28] = 0x0E,   // L J ' K
    [0x29] = 0x33, [0x2A] = 0x31, [0x2B] = 0x36, [0x2C] = 0x38,   // ; \ , /
    [0x2D] = 0x11, [0x2E] = 0x10, [0x2F] = 0x37, [0x30] = 0x2B,   // N M . Tab
    [0x31] = 0x2C, [0x32] = 0x35, [0x33] = 0x2A, [0x35] = 0x29,   // Space ` 退格 Esc
    [0x36] = 0xE7, [0x37] = 0xE3, [0x38] = 0xE1, [0x3A] = 0xE0,   // 右⌘ 左⌘（组合键 keyDown: 已交系统，备用）⇧ ⌃
    [0x3B] = 0xE2, [0x3C] = 0xE5, [0x3D] = 0xE6, [0x3E] = 0xE4,   // ⌥ 右⇧ 右⌥ 右⌃
    [0x40] = 0x6C, [0x41] = 0x63, [0x43] = 0x55, [0x45] = 0x57,   // F17 小键盘. 小键盘* 小键盘+
    [0x47] = 0x53, [0x4B] = 0x54, [0x4C] = 0x58, [0x4E] = 0x56,   // 小键盘Clear 小键盘/ 小键盘Enter 小键盘-
    [0x4F] = 0x6D, [0x50] = 0x6E, [0x51] = 0x67, [0x52] = 0x62,   // F18 F19 小键盘= 小键盘0
    [0x53] = 0x59, [0x54] = 0x5A, [0x55] = 0x5B, [0x56] = 0x5C,   // 小键盘1 2 3 4
    [0x57] = 0x5D, [0x58] = 0x5E, [0x59] = 0x5F, [0x5A] = 0x6F,   // 小键盘5 6 7 F20
    [0x5B] = 0x60, [0x5C] = 0x61, [0x5D] = 0x89, [0x5F] = 0x85,   // 小键盘8 9 JIS円 JIS小键盘,
    [0x60] = 0x3E, [0x61] = 0x3F, [0x62] = 0x40, [0x63] = 0x3C,   // F5 F6 F7 F3
    [0x64] = 0x41, [0x65] = 0x42, [0x67] = 0x44, [0x69] = 0x68,   // F8 F9 F11 F13
    [0x6A] = 0x6B, [0x6B] = 0x69, [0x6D] = 0x43, [0x6F] = 0x45,   // F16 F14 F10 F12
    [0x71] = 0x6A, [0x72] = 0x49, [0x73] = 0x4A, [0x74] = 0x4B,   // F15 Help(=Insert) Home PageUp
    [0x75] = 0x4C, [0x76] = 0x3D, [0x77] = 0x4D, [0x78] = 0x3B,   // ForwardDelete F4 End F2
    [0x79] = 0x4E, [0x7A] = 0x3A, [0x7B] = 0x50, [0x7C] = 0x4F,   // PageDown F1 ← →
    [0x7D] = 0x51, [0x7E] = 0x52,                                  // ↓ ↑
};
static BOOL caps_locked;   // CapsLock 只走 flagsChanged（NSEventModifierFlagCapsLock），不进 keys
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
static BOOL ble_raw_source;   // 这一拍的输入来自报原始方向的单只 Joy-Con（sample_input 设，publish_pad_state 读；只在主线程）
// 玩家 1（槽 0）是不是 NS2 手柄（启动器通道 / 直连的玩家 0）：体感、震动、Joy-Con 2 鼠标只给玩家 1，跟着它走——
//   系统手柄先连上占了槽 0 时这几样走系统手柄那一路（同 #282 只有玩家 1 有体感 / 震动）。sample_input 写，任意线程读；缺省 1 = 同改前
// P1（槽 0）是哪一位通道玩家（#520：分配玩家 / 拆开后 P1 不一定是通道玩家 0）；不是 NS2 手柄为 -1。P1 的体感 / 鼠标 / 震动跟它走
static _Atomic int g_slot0_ns2 = 1, g_slot0_player = 0;
static BOOL ns2_leads(void) { return s2a_mac_ns2_status() == NS2_STATUS_READY && atomic_load(&g_slot0_ns2); }
static int ns2_lead_player(void) { return atomic_load(&g_slot0_player); }
// 事件驱动输入（A2）：同一份前端状态同时写进 runtime/src/pad.c，InputPump 找到 s2a_vpad_read_ex 后就等
//   s2a_pad_wait 的序号通知，不再 Thread.Sleep(16)。有扩展手柄时按系统手柄源发布（键盘 / 鼠标仍并进同一份状态），
//   没有手柄时按触屏源发布；两个源互斥的语义由 pad.c 管，Mac 不另造第三份选源状态。
static void publish_pad_state(int has_pad, uint32_t buttons, const int32_t sticks[4]) {
    if (has_pad) { s2a_pad_update(S2A_PAD_SYSTEM, focused ? 1 : 0, buttons, sticks); return; }
    // 没手柄时必须先补一次 SYSTEM 断开：pad.c 的 selected() 只看 connected，不发就仍选 SYSTEM 并丢掉 TOUCH 更新，
    //   手柄断开瞬间按住的键会卡住、键盘也失灵（维护方 11-09 用 pad.c 最小程序复现：0x1，期望 0x2）。
    s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, sticks);
    // 单只 Joy-Con 报原始方向时按 BLE 源发布（#520 A）：InputPump 把 BLE / 系统手柄当实体手柄、不再按横握转一次（触屏源会转，
    //   原始方向的物理键就被转两次）；其余（键盘、扮 Pro 的手柄）照旧按触屏源，BLE 源先报断开（同上 selected() 只看 connected）
    if (ble_raw_source) { s2a_pad_update(S2A_PAD_BLE, focused ? 1 : 0, buttons, sticks); return; }
    s2a_pad_update(S2A_PAD_BLE, 0, 0, sticks);
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
// —— 手柄快速路径（valueChangedHandler 专用队列上的回调，见 sample_input 之后的 pad_event_fast）的共享状态 ——
//   键盘 / 鼠标位快照与静音标记由主线程每次采样刷新，槽位镜像（见 S2A_MAX_PADS 那段）照 pad_owner 抄一份；
//   全部在 g_compose_mu 下交接，谁拿到锁谁重读要合的那份再发布，两条线交错也不丢键
static _Atomic uint32_t kbd_buttons_snap;
static _Atomic int32_t kbd_sticks_snap[4];
static _Atomic int input_muted;   // 失焦 / 退出确认条开着（同 sample_input 的 muted 判据）：快速路径照它发零
static pthread_mutex_t g_compose_mu = PTHREAD_MUTEX_INITIALIZER;   // 主线程的采样发布段与手柄快速路径互斥；publish 的序号快照也只允许一个写者在锁内
static dispatch_queue_t pad_input_queue(void);
static void pad_event_fast(GCController *controller);
static void touch_end(void);   // 鼠标左键当触屏（见下）：抬起 / 复位补一帧 End
static void reset_input(void) {
    [keys removeAllObjects]; [mouse removeAllObjects]; modifiers = 0; [key_up_polls removeAllObjects]; [stale_keys removeAllObjects];
    [mouse_up_polls removeAllObjects]; [stale_mouse removeAllObjects];
    atomic_store_explicit(&mouse_dx, 0, memory_order_relaxed);
    atomic_store_explicit(&mouse_dy, 0, memory_order_relaxed);
    atomic_store(&hold_x, 0); atomic_store(&hold_y, 0);
    int32_t sticks[4] = {0};
    pthread_mutex_lock(&g_compose_mu);   // publish 的序号快照只有一个写者：reset 也走同一把锁（另一路是手柄快速路径）
    publish_input(0, sticks);
    pthread_mutex_unlock(&g_compose_mu);
    uint64_t kb_none[4] = {0}; s2a_kb_update(kb_none, 0);   // R5：键盘区一并复位（失焦 / 关窗，按着的键全清）
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
// 单只 Joy-Con（#520 A）：InputPump 按符号查这两个（services/S2A.Services/InputPump.cs FollowJoyconStyle）——
//   s2a_vpad_joycon_style：连着的单只 Joy-Con 对应的样式（Ryujinx ControllerType：JoyconLeft / JoyconRight；不是单只为 0），
//     游戏收这个样式就改成它；s2a_vpad_set_style：每次改配告诉宿主这一格现在的样式，宿主据此定原始方向还是转横握
__attribute__((visibility("default"), used)) int s2a_vpad_joycon_style(void) { return s2a_mac_ns2_single_style(s2a_mac_ns2_kind()); }
__attribute__((visibility("default"), used)) void s2a_vpad_set_style(int style) { s2a_mac_ns2_set_game_style(style); }
// 每一格的样式（服务层 InputPump.ReportStyle，#520）：sample_input 照槽位转给占那一格的 NS2 玩家，玩家 2 起的单只 Joy-Con 也照它那一格定原始方向 / 横握（8 = S2A_MAX_PADS，那个宏在后面才定义）
static _Atomic int g_slot_style[8];
__attribute__((visibility("default"), used)) void s2a_vpad_set_slot_style(int slot, int style) { if (slot >= 0 && slot < 8) atomic_store(&g_slot_style[slot], style); }
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
// 手柄事件驱动（A2）：valueChangedHandler 走 GameController 的回调队列。队列不再挂主队列——原先为让 sample_input
//   直接读 keys / mouse / config（与 AppKit 键盘 / 鼠标事件串行）的权衡，代价是主线程被菜单动画 / 提示条 / 系统弹窗占住时
//   手柄事件跟着排队（延迟管线调研：列为权衡而非缺陷）。改挂专用串行队列（对齐 iOS ios/controller.m 的 s2arm.controller.input），
//   回调只走 pad_event_fast 快速路径：照槽位采样这一只、合键盘 / 鼠标快照发布，不碰主线程的 keys / mouse / config。
//   120Hz 主线程定时器仍保留：键盘 / 鼠标的粘键核对、补装新连接的手柄、槽位重排、六轴 / 震动 / Home 退出都在那一轮。
// 没有扩展手柄描述、但通用物理描述里有按键的手柄（部分第三方手柄的某些模式、只给简易描述的手柄）：原先整只被忽略、游戏里没反应也没有提示。
//   按标准键名从 physicalInputProfile 读（参照维护者提供的前端实现 Gamepad.swift 的读法）。六轴 / 震动 / Home 退出仍只认扩展手柄
static BOOL pad_has_profile_buttons(GCController *c) { return !c.extendedGamepad && c.physicalInputProfile.buttons.count > 0; }
static void install_pad_handler(GCController *controller) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (pad) {
        if (pad.valueChangedHandler) return;
        controller.handlerQueue = pad_input_queue();
        __weak GCController *wc = controller;   // 断开的手柄会被系统释放：弱引用防悬空（同 iOS attachSystem 的写法）
        pad.valueChangedHandler = ^(GCExtendedGamepad *profile, GCControllerElement *element) {
            (void)profile; (void)element;
            GCController *c = wc;
            if (c) pad_event_fast(c);
        };
        return;
    }
    if (!pad_has_profile_buttons(controller) || controller.physicalInputProfile.valueDidChangeHandler) return;
    controller.handlerQueue = pad_input_queue();
    __weak GCController *wc = controller;
    controller.physicalInputProfile.valueDidChangeHandler = ^(GCPhysicalInputProfile *profile, GCControllerElement *element) {
        (void)profile; (void)element;
        GCController *c = wc;
        if (c) pad_event_fast(c);
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
    s2a_mac_hid_pad_start();   // 兜底手柄监听（只起一次）
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
    BOOL ns2 = ns2_leads();
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
// P1（槽 0）是一代 Joy-Con 单元时（#520，同 Joy-Con 2：P1 的体感 / 震动跟占 P1 的那只走）：定义在槽位表后面
static int p1_gen1_motion(s2a_pad_motion out[2]);
static int p1_gen1_rumble(const s2a_pad_vibration values[2]);
#define GEN1_P1_SESSION (MAC_RUMBLE_BASE | 0xffffffffull)   // P1 是一代 Joy-Con 单元时的震动会话（没有 GameController 引擎，走 HID）
__attribute__((visibility("default"), used)) int s2a_pad_read_motion(s2a_pad_motion *out) {
    { s2a_pad_motion two[2]; if (p1_gen1_motion(two)) { *out = two[0]; return 1; } }
    if (ns2_leads()) return ns2_lead_player() > 0 ? s2a_mac_ns2_read_motion_player(ns2_lead_player(), out) : s2a_mac_ns2_read_motion(out);
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
    { int g = p1_gen1_motion(out); if (g) return g; }   // P1 是一代单只 / 按设备的一对：照它（一对左右两路）
    if (ns2_leads() && ns2_lead_player() > 0) { out[1] = (s2a_pad_motion){0}; return s2a_mac_ns2_read_motion_player(ns2_lead_player(), &out[0]); }   // P1 是拆开的另一只：它自己那一路
    if (ns2_leads()) return s2a_mac_ns2_read_motion_pair(out);   // NS2 手柄（启动器通道）：Joy-Con 2 拼对时左右各一路（ns2_relay.h motion_left）
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
    if (!ns2_leads()) { out[0] = out[1] = (s2a_pad_mouse){0}; return 0; }
    return s2a_mac_ns2_read_mouse_player(ns2_lead_player(), out);   // P1 是哪一位通道玩家就报哪一只（游戏靠它认 Joy-Con 2）
}
// 实体手柄退出游戏（#276）：决策在 runtime/include/s2a_home_quit.h，界面（提示条、失焦、退出）在 S2AMacDelegate 后面的 home_quit_ui
static s2a_hq_state g_hq;
// 静音标记跟随 focused / 退出确认条就地刷新（都在主线程）：失焦 / 开条那一拍就生效，不等下一轮 120Hz 定时采样
static void input_mute_refresh(void) { atomic_store(&input_muted, !focused || g_hq.open); }
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
// 一只系统手柄的震动（只在 g_rumble_q 上碰）：GCDeviceHaptics 建一个 CHHapticEngine，连续事件循环播放、按游戏给的两侧振幅取大调强度，1 秒没新帧自动停；
//   失败退避 / 判死同 ios/haptic_retry.h。P1 一份（g_rumble_main_rumbler，跟 rumble_select 换手柄）；P1 以外的系统手柄各一份（#520 E，s2a_pad_set_rumble_slot）
@interface S2ARumbler : NSObject {
@public
    GCController *device;
    CHHapticEngine *engine;
    id<CHHapticPatternPlayer> player;   // 能建循环播放器就用循环的；建不了用普通播放器，快到事件末尾时重起
    BOOL loops, plainOnly, playing;     // plainOnly：这只手柄建循环播放器失败过，之后只建普通播放器
    uint64_t startedNs;                 // 普通播放器这一轮的起播时刻
    dispatch_source_t timer;
    s2a_hp_state retry;
}
@end
@implementation S2ARumbler
@end
static S2ARumbler *g_rumble_main_rumbler;
static pthread_mutex_t g_rumble_mu = PTHREAD_MUTEX_INITIALIZER;
static s2a_pad_vibration g_rumble_pair[2];       // g_rumble_mu：单侧提交时拼成整对
#define MAC_RUMBLE_RESTART_NS (20ull * NSEC_PER_SEC)
static float rumble_scale(void) {
    static float scale = -1;
    if (scale < 0) { const char *e = getenv("S2A_RUMBLE_SCALE"); float v = e ? strtof(e, NULL) : 1; scale = isfinite(v) && v > 0 ? v : 1; }
    return scale;
}
static BOOL rumble_off(void) { const char *e = getenv("S2A_RUMBLE"); return e && !strcmp(e, "0"); }
static void rumbler_stop(S2ARumbler *r) {
    if (!r) return;
    if (r->player && r->playing) [r->player stopAtTime:CHHapticTimeImmediate error:nil];
    r->playing = NO;
    if (r->timer) dispatch_source_set_timer(r->timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}
static void rumbler_reset(S2ARumbler *r) {
    if (!r) return;
    rumbler_stop(r);
    [r->engine stopWithCompletionHandler:nil];
    r->player = nil; r->engine = nil;
}
static void rumbler_fail(S2ARumbler *r, const char *what, NSError *error) {
    BOOL died = s2a_hp_on_fail(&r->retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    if (!r->retry.reported) {
        r->retry.reported = YES;
        fprintf(stderr, "【红】手柄震动：%s（%s/%ld）%s\n", what, error.domain.UTF8String ?: "-", error ? (long)error.code : 0L, error.localizedDescription.UTF8String ?: "");
    }
    if (died) fprintf(stderr, "【红】手柄震动：本手柄本局停用（连续 %d 次失败）；换手柄会再试\n", S2A_HP_MAX_FAILS);
}
static float rumble_clamp(float x, float lo, float hi) { return isfinite(x) ? fminf(hi, fmaxf(lo, x)) : lo; }
// 一代 Joy-Con / Pro（GameController 没 haptics）：照系统类别认是哪一只，交给 joycon_imu.m 的 HID 震动；不是任天堂一代手柄回 0
static int gen1_rumble_mask(GCController *c) {
    NSString *t = [[c.productCategory ?: @"" stringByAppendingFormat:@" %@", c.vendorName ?: @""] lowercaseString];
    if ([t containsString:@"switch 2"] || [t containsString:@"joy-con 2"]) return 0;
    if ([t containsString:@"joy-con (l/r)"]) return 3;
    if ([t containsString:@"joy-con (l)"]) return 1;
    if ([t containsString:@"joy-con (r)"]) return 2;
    if ([t containsString:@"pro controller"] && ([t containsString:@"switch"] || [t containsString:@"nintendo"])) return 4;   // Pro 自己一位：一代右只也连着时不震错只
    return 0;
}
static void rumbler_play(S2ARumbler *r, s2a_pad_vibration pair[2]) {
    if (!r) return;
    if (!r->device.haptics) {   // 一代任天堂手柄：macOS 不给 haptics，走 HID（#520 E：每位玩家的手柄都要能震）
        int mask = gen1_rumble_mask(r->device);
        if (mask) { s2a_joycon_rumble(mask, pair); return; }
    }
    float amplitude = 0, weighted = 0, weights = 0;
    for (int i = 0; i < 2; i++) {
        float lo = rumble_clamp(pair[i].low_amp, 0, 1), hi = rumble_clamp(pair[i].high_amp, 0, 1);
        amplitude = fmaxf(amplitude, fmaxf(lo, hi));
        weighted += lo * rumble_clamp(pair[i].low_hz, 0, 1250) + hi * rumble_clamp(pair[i].high_hz, 0, 1250);
        weights += lo + hi;
    }
    amplitude = fminf(1, s2a_hp_feel(amplitude) * rumble_scale());
    if (amplitude <= 0.001f || !r->device.haptics) { rumbler_stop(r); return; }
    if (s2a_hp_should_try(&r->retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) == S2A_HP_SKIP) return;
    float hz = weights > 0 ? weighted / weights : 160;
    float sharp = rumble_clamp((hz - 160) / 160 * 0.5f + 0.3f, 0, 1);
    NSError *error = nil;
    if (!r->engine) {
        r->engine = [r->device.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!r->engine) { rumbler_fail(r, "无法创建引擎", nil); return; }
        r->engine.playsHapticsOnly = YES;
        __weak CHHapticEngine *weakEngine = r->engine;
        __weak S2ARumbler *weakR = r;
        void (^invalidate)(void) = ^{
            CHHapticEngine *e = weakEngine;
            if (e) dispatch_async(g_rumble_q, ^{ S2ARumbler *x = weakR; if (x && x->engine == e) rumbler_reset(x); });
        };
        r->engine.resetHandler = ^{ invalidate(); };
        r->engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; invalidate(); };
    }
    if (!r->player) {
        if (![r->engine startAndReturnError:&error]) { rumbler_fail(r, "启动引擎失败", error); rumbler_reset(r); return; }
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        // 循环播放器在有的系统 / 手柄上建不出来（11-10 M1 Max / macOS 27.0.1 / DualSense：NSCocoaErrorDomain 4097，同一引擎上普通播放器能建能播）：
        //   退到普通播放器，它不能循环，靠下面的重起接上
        //   循环播放器建失败后这个引擎也废了（接着在它上面建普通播放器报 GameControllerHaptics/0 Client not registred），所以记下来、丢掉引擎、从头再来一次
        if (pattern && !r->plainOnly) {
            id<CHHapticAdvancedPatternPlayer> advanced = [r->engine createAdvancedPlayerWithPattern:pattern error:&error];
            if (advanced) { advanced.loopEnabled = YES; r->player = advanced; r->loops = YES; }
            else {
                fprintf(stderr, "手柄震动：循环播放器建不了（%s/%ld），改用普通播放器\n", error.domain.UTF8String ?: "-", error ? (long)error.code : 0L);
                r->plainOnly = YES; rumbler_reset(r); rumbler_play(r, pair); return;
            }
        } else if (pattern) { r->player = [r->engine createPlayerWithPattern:pattern error:&error]; r->loops = NO; }
        if (!r->player) { rumbler_fail(r, "创建播放器失败", error); rumbler_reset(r); return; }
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (r->playing && !r->loops && now - r->startedNs > MAC_RUMBLE_RESTART_NS) {   // 普通播放器：事件 30 秒，连着震到 20 秒就重起一轮
        [r->player stopAtTime:CHHapticTimeImmediate error:nil]; r->playing = NO;
    }
    if (!r->playing && ![r->player startAtTime:CHHapticTimeImmediate error:&error]) { rumbler_fail(r, "播放失败", error); rumbler_reset(r); return; }
    if (!r->playing) r->startedNs = now;
    r->playing = YES;
    if (![r->player sendParameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]] atTime:CHHapticTimeImmediate error:&error]) {
        rumbler_fail(r, "更新强度失败", error); rumbler_reset(r); return;
    }
    s2a_hp_on_ok(&r->retry);
    static BOOL logged; if (!logged) { logged = YES; fprintf(stderr, "手柄震动：播放 强度 %.2f（倍率 %.2f）锐度 %.2f\n", amplitude, rumble_scale(), sharp); }
    if (!r->timer) {
        r->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_rumble_q);
        __weak S2ARumbler *weakR = r;
        dispatch_source_set_event_handler(r->timer, ^{ rumbler_stop(weakR); });
        dispatch_resume(r->timer);
    }
    dispatch_source_set_timer(r->timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
}
// P1 那一份（改前的全局函数名，下面的调用处不动）
static void rumble_reset_on_queue(void) { rumbler_reset(g_rumble_main_rumbler); }
static void rumble_play_on_queue(s2a_pad_vibration pair[2]) { rumbler_play(g_rumble_main_rumbler, pair); }
// P1 以外的系统手柄：各一份（g_rumble_q 上建、用；手柄断开时字典里那份跟着丢）
static NSMapTable<GCController *, S2ARumbler *> *g_slot_rumblers;
static void slot_rumble_on_queue(GCController *device, s2a_pad_vibration pair[2]) {
    if (!g_slot_rumblers) g_slot_rumblers = [NSMapTable weakToStrongObjectsMapTable];
    S2ARumbler *r = [g_slot_rumblers objectForKey:device];
    if (!r) { r = [S2ARumbler new]; r->device = device; [g_slot_rumblers setObject:r forKey:device]; }
    rumbler_play(r, pair);
}
// 主线程（输入采样）：当前手柄换了就换会话号，旧会话的提交一律丢掉
static void rumble_select(GCController *device) {
    if (device == g_rumble_main) return;
    g_rumble_main = device;
    if (!g_rumble_q) g_rumble_q = dispatch_queue_create("dev.s2arm.mac-rumble", DISPATCH_QUEUE_SERIAL);
    atomic_store(&g_rumble_epoch, (device.haptics || gen1_rumble_mask(device)) && !rumble_off() ? ++g_rumble_counter : 0);   // 一代任天堂手柄没 haptics 也能震（HID）
    dispatch_async(g_rumble_q, ^{ rumble_reset_on_queue(); S2ARumbler *r = [S2ARumbler new]; r->device = device; g_rumble_main_rumbler = r; });
}
// 会话号高 16 位是 MAC_RUMBLE_BASE 的走系统手柄（CoreHaptics），其余是 Switch 2 Pro（macos/ns2_controller.c，#277）的
static BOOL rumble_is_mac(uint64_t session) { return (session & 0xffff000000000000ull) == MAC_RUMBLE_BASE; }
static void rumble_submit(uint64_t session, const s2a_pad_vibration pair[2]) {
    if (session == GEN1_P1_SESSION) { p1_gen1_rumble(pair); return; }
    if (session && !rumble_is_mac(session) && ns2_lead_player() > 0) { s2a_mac_ns2_set_rumble_player(ns2_lead_player(), pair); return; }   // P1 是拆开的另一只：震它
    if (session && !rumble_is_mac(session)) { s2a_mac_ns2_set_rumble_pair(session, pair); return; }
    uint64_t epoch = atomic_load(&g_rumble_epoch);
    if (!epoch || session != (MAC_RUMBLE_BASE | epoch) || !g_rumble_q) return;
    s2a_pad_vibration left = pair[0], right = pair[1];   // 块里不能捕获数组：拆成两个值
    dispatch_async(g_rumble_q, ^{ s2a_pad_vibration p[2] = {left, right}; rumble_play_on_queue(p); });
}
__attribute__((visibility("default"), used)) uint64_t s2a_pad_rumble_session(void) {
    if (rumble_off()) return 0;   // 启动设置「手柄震动」关：两路都不震
    if (p1_gen1_rumble(NULL)) return GEN1_P1_SESSION;   // P1 是一代 Joy-Con 单元：走 HID 震动
    uint64_t ns2 = atomic_load(&g_slot0_ns2) ? s2a_mac_ns2_rumble_session() : 0;   // NS2 手柄是玩家 1 且在前台：震动交给它
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
//    NS2 手柄（S2Arm 连接程序 / 直连，s2a_mac_ns2_read_player）每位玩家占一个槽，身份是 ns2_slot_id[玩家]，与系统手柄混用（#520 C）；
//    系统手柄列表里认得出是 NS2 手柄的（s2a_pad_is_ns2）在通道连着时不另占槽，免得同一只变两位玩家。
#define S2A_MAX_PADS 8   // 同原机最多 8 位玩家（#520）
_Static_assert(S2A_MAX_PADS == sizeof g_slot_style / sizeof g_slot_style[0], "g_slot_style 跟槽位数");
#define S2A_LIVE_MAX (NS2_RELAY_PLAYERS + 8)   // 一拍里在线的候选：通道玩家 + 系统手柄 + 键盘，超出槽位的由 s2a_slot_plan 判 -1
static _Atomic uint32_t pad_buttons[S2A_MAX_PADS];
static _Atomic int32_t pad_sticks[S2A_MAX_PADS][4];
static _Atomic int pad_live = 1;   // 本次采样占到的最高槽位 + 1（键盘 / 鼠标 / 触屏也算一位）
// 槽位身份（分槽用）与系统手柄的强引用：手柄蓝牙休眠 / 断开时系统会释放 GCController，只存裸指针会变悬空，
//   下一次比较身份时就是野指针。强引用后对象不会提前释放，断开时靠整表重建清槽，置 nil 才真正释放。只在主线程读写。
static const void *pad_id[S2A_MAX_PADS];
static GCController *pad_owner[S2A_MAX_PADS];
// 槽位里这只系统手柄是什么时候接上的（主线程写、任意线程读）：刚连上的手柄 macOS 还在设定（GameController 内部 setSettingsProfile），
//   这时给它建震动引擎会撞上系统框架里的竞争、整个游戏被杀（11-13 实机：游戏中接第二只 PS5 崩在 _GCDevicePhysicalInput updateWithElements:）。
//   P1 以外的震动等它在槽位里待满 2 秒再碰
static _Atomic uint64_t pad_owner_since[S2A_MAX_PADS];
static const char ns2_slot_id[NS2_RELAY_PLAYERS];
static const char kbd_slot_id;   // 键盘分配成一位玩家时的槽位身份（没分配时照旧并进槽 0）
// D2（#520）：一代 Joy-Con 按设备当玩家时的槽位身份——每个单元（单只 / 按设备读的一对）一格，地址就是身份（s2a_slot_plan 照指针认「还在原槽」）。
//   几套一代都行：key = 设备 id（单只）或「左 id|右 id」（一对）。格子只在主线程分配；震动 / 体感线程按槽位读 id 时持 g_gen1_mu
enum { S2A_GEN1_UNITS = 16 };
typedef struct { char key[64], left[64], right[64]; int pair; _Atomic int style; uint32_t side_keys; } gen1_unit;   // style：它占的那一格的样式（照它定原始方向 / 横握，同 Joy-Con 2）
static gen1_unit g_gen1[S2A_GEN1_UNITS];
static pthread_mutex_t g_gen1_mu = PTHREAD_MUTEX_INITIALIZER;
static gen1_unit *gen1_of(const void *owner) {
    const gen1_unit *u = owner;
    return u >= g_gen1 && u < g_gen1 + S2A_GEN1_UNITS ? (gen1_unit *)u : NULL;
}
static int gen1_ids(const void *owner, char left[64], char right[64]);
// 一代单元的震动（单只照游戏给的两侧取强的；按设备的一对左只拿左侧、右只拿右侧）；不是一代单元回 0。values = NULL 只问是不是
static int gen1_rumble(const void *owner, const s2a_pad_vibration values[2]) {
    char gl[64], gr[64];
    if (!gen1_ids(owner, gl, gr)) return 0;
    if (!values) return 1;
    if (!gr[0]) { s2a_joycon_rumble_id(gl, values); return 1; }
    s2a_pad_vibration l2[2] = {values[0], values[0]}, r2[2] = {values[1], values[1]};
    s2a_joycon_rumble_id(gl, l2); s2a_joycon_rumble_id(gr, r2);
    return 1;
}
// 一代单元的六轴：单只照它那一格的样式——原始方向（单只本侧 / 一对样式，游戏按握法自己转）原样给，扮 Pro 时转成横握视角（同 Joy-Con 2）；一对左右两路
static int gen1_motion(const void *owner, s2a_pad_motion out[2]) {
    char gl[64], gr[64];
    gen1_unit *u = gen1_of(owner);
    if (!u || !gen1_ids(owner, gl, gr)) return 0;
    out[0] = out[1] = (s2a_pad_motion){0};
    if (gr[0]) { int l = s2a_joycon_imu_read_id(gl, &out[0]), r = s2a_joycon_imu_read_id(gr, &out[1]); return l && r ? 2 : 0; }
    if (!s2a_joycon_imu_read_id(gl, &out[0])) return 0;
    s2a_joycon_info jc[16]; int n = s2a_joycon_list(jc, 16); ns2_kind kind = NS2_KIND_NONE;
    for (int i = 0; i < n; i++) if (!strcmp(jc[i].id, gl)) kind = jc[i].pid == 0x2006 ? NS2_KIND_JOYCON_L : jc[i].pid == 0x2007 ? NS2_KIND_JOYCON_R : NS2_KIND_NONE;
    if (kind != NS2_KIND_NONE && !s2a_mac_ns2_raw_wanted(kind, atomic_load(&u->style))) {
        ns2_motion m = {.known = 1, .host_timestamp_us = out[0].host_timestamp_us, .acceleration_x = out[0].acceleration_x, .acceleration_y = out[0].acceleration_y, .acceleration_z = out[0].acceleration_z,
                        .gyro_x = out[0].gyro_x, .gyro_y = out[0].gyro_y, .gyro_z = out[0].gyro_z};
        ns2_joycon_sideways_motion(kind, &m);
        out[0] = (s2a_pad_motion){m.host_timestamp_us, m.acceleration_x, m.acceleration_y, m.acceleration_z, m.gyro_x, m.gyro_y, m.gyro_z};
    }
    return 1;
}
// 照槽位拿这一格的两只 id（单只 right 为空）；不是一代格回 0
static int gen1_ids(const void *owner, char left[64], char right[64]) {
    gen1_unit *u = gen1_of(owner);
    if (!u) return 0;
    pthread_mutex_lock(&g_gen1_mu);
    snprintf(left, 64, "%s", u->left); snprintf(right, 64, "%s", u->pair ? u->right : "");
    int ok = u->key[0] != 0;
    pthread_mutex_unlock(&g_gen1_mu);
    return ok;
}
// 槽位镜像（g_compose_mu 下）：主线程整表重建后照 pad_owner 抄一份（含强引用），手柄快速路径按它认「这只手柄占哪个槽」；
//   NS2 那路没有 GCController 对象，留空。快速路径的其余共享状态（键鼠快照 / 静音标记 / 合成锁）在前面的前置段
static GCController *pad_slot_owner[S2A_MAX_PADS];
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
// 按键名位序（同 macos/hid_pad.h）+ 摇杆原值 → 键位配置：Switch 2 Pro（BLE）与兜底 HID 手柄两路共用
static void sample_coded_state(uint32_t bits, int lx, int ly, int rx, int ry, uint32_t *out_buttons, int32_t sticks[4]) {
    NSArray *codes = @[@"east", @"south", @"north", @"west", @"leftStick", @"rightStick",
        @"leftShoulder", @"rightShoulder", @"leftTrigger", @"rightTrigger", @"menu", @"options",
        @"dpadLeft", @"dpadUp", @"dpadRight", @"dpadDown"];
    NSMutableDictionary *all = [NSMutableDictionary new];
    for (int i = 0; i < 16; i++) all[codes[i]] = @((bits & (1u << i)) != 0);
    map_pad_inputs(all, @{@"leftX": @(lx / 32767.0f), @"leftY": @(ly / 32767.0f),
                          @"rightX": @(rx / 32767.0f), @"rightY": @(ry / 32767.0f)}, out_buttons, sticks);
}
static void sample_ns2_state(const ns2_state *ble, uint32_t *out_buttons, int32_t sticks[4]) {
    sample_coded_state(ble->buttons, ble->lx, ble->ly, ble->rx, ble->ry, out_buttons, sticks);
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
// R5：原始键态 → HID 键盘区（s2a_kb_update，键码表 mac_key_hid）。位图是 (keys, modifiers, caps_locked, muted) 的
//   纯函数、每次全量重排：粘键核对删键 / 恢复、失焦复位、keyUp 被别的响应者吃掉都自然跟着对，不会漂。
//   muted（失焦 / 退出确认条）发全零，同手柄口径。修饰键也按 usage 进位图（0xE0–0xE2），同 Ryujinx 键盘路径
static void publish_keyboard(BOOL muted) {
    uint64_t bits[4] = {0, 0, 0, 0}; uint32_t mods = 0;
    if (!muted) {
        for (NSNumber *code in keys) {
            unsigned usage = code.unsignedIntValue < 128 ? mac_key_hid[code.unsignedIntValue] : 0;
            if (usage) bits[usage >> 6] |= 1ULL << (usage & 63);
        }
        if (caps_locked) { bits[0x39 >> 6] |= 1ULL << (0x39 & 63); mods |= 1u << 8; }   // CapsLock：位图 0x39 + 字段 bit8（真机 HID 键盘两处都报）
        if (modifiers & 1) mods |= 1u << 1;    // Shift → KeyboardModifier.Shift
        if (modifiers & 2) mods |= 1u << 0;    // Control
        if (modifiers & 4) mods |= 1u << 2;    // Option → LeftAlt
    }
    s2a_kb_update(bits, mods);
}
// 按槽位震动（#520 E）：服务层把 P1 以外的玩家交到这里——槽位是 NS2 手柄就照它的通道玩家号震；系统手柄（PS5 等）各用自己的 CoreHaptics 引擎
//   （S2ARumbler；跟 P1 是同一只手柄时共用 P1 那份，不在同一只上建两个引擎）
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble_slot(int slot, const s2a_pad_vibration values[2]) {
    if (slot < 0 || slot >= S2A_MAX_PADS || !values || rumble_off()) return;
    const void *owner = pad_id[slot];
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) if (owner == &ns2_slot_id[p]) { s2a_mac_ns2_set_rumble_player(p, values); return; }
    if (gen1_rumble(owner, values)) return;   // D2：一代单只 / 按设备的一对走 HID
    GCController *device = pad_owner[slot];
    if (!device) return;
    uint64_t since = atomic_load(&pad_owner_since[slot]);
    if (!since || clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - since < 2 * NSEC_PER_SEC) return;   // 刚接上：macOS 还在设定这只手柄，先不碰它的震动
    if (!g_rumble_q) g_rumble_q = dispatch_queue_create("dev.s2arm.mac-rumble", DISPATCH_QUEUE_SERIAL);
    s2a_pad_vibration left = values[0], right = values[1];   // 块里不能捕获数组：拆成两个值
    BOOL main = device == g_rumble_main;
    dispatch_async(g_rumble_q, ^{
        s2a_pad_vibration pair[2] = {left, right};
        if (main && g_rumble_main_rumbler) rumbler_play(g_rumble_main_rumbler, pair); else slot_rumble_on_queue(device, pair);
    });
}
// 每位玩家的体感（#520：每位玩家的手柄都要有）：P1 照原来那一路（sample_motion / s2a_pad_read_motion_pair）；
//   P2 起按槽位读——系统手柄用自己的 GCMotion（主线程这里读、存一份），Switch 2 手柄用通道带来的、一代单只用 HID（joycon_imu.m）
static s2a_pad_motion g_slot_motion[S2A_MAX_PADS];   // 持 g_motion_mu
static int g_slot_motion_known[S2A_MAX_PADS];
static GCMotion *g_slot_motion_source[S2A_MAX_PADS];   // 只在主线程碰：开了传感器的那几只，换人时关掉
static void sample_slot_motion(GCController *const owner_before[S2A_MAX_PADS]) {
    BOOL want = atomic_load(&g_motion_wanted);
    for (int s = 1; s < S2A_MAX_PADS; s++) {
        GCMotion *m = want ? pad_owner[s].motion : nil;
        if (!(m.hasRotationRate && m.hasGravityAndUserAcceleration)) m = nil;
        if (m != g_slot_motion_source[s]) {
            if (g_slot_motion_source[s].sensorsRequireManualActivation && g_slot_motion_source[s] != g_motion_source) g_slot_motion_source[s].sensorsActive = NO;
            g_slot_motion_source[s] = m;
            if (m.sensorsRequireManualActivation) m.sensorsActive = YES;
        }
        s2a_pad_motion sample = {0};
        if (m) {
            double gravity[3] = {m.gravity.x, m.gravity.y, m.gravity.z}, user[3] = {m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z};
            double rotation[3] = {m.rotationRate.x, m.rotationRate.y, m.rotationRate.z};
            float acceleration[3], gyro[3];
            s2a_gc_motion_axes(gravity, user, rotation, acceleration, gyro);
            sample = (s2a_pad_motion){clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000, acceleration[0], acceleration[1], acceleration[2], gyro[0], gyro[1], gyro[2]};
        }
        pthread_mutex_lock(&g_motion_mu);
        g_slot_motion[s] = sample; g_slot_motion_known[s] = m != nil;
        pthread_mutex_unlock(&g_motion_mu);
    }
    (void)owner_before;
}
// 服务层按槽位要体感（P2 起）：out[0]（一对时 out[0] 左、out[1] 右），返回几路；没有回 0
__attribute__((visibility("default"), used)) int s2a_pad_read_motion_slot(int slot, s2a_pad_motion out[2]) {
    if (!out || slot <= 0 || slot >= S2A_MAX_PADS) return 0;
    out[0] = out[1] = (s2a_pad_motion){0};
    const void *owner = pad_id[slot];
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) if (owner == &ns2_slot_id[p])
        return p == 0 ? s2a_mac_ns2_read_motion_pair(out) : s2a_mac_ns2_read_motion_player(p, &out[0]);
    if (gen1_of(owner)) return gen1_motion(owner, out);   // D2：一代单只 out[0]；按设备的一对 out[0] 左、out[1] 右
    pthread_mutex_lock(&g_motion_mu);
    int known = g_slot_motion_known[slot];
    if (known) out[0] = g_slot_motion[slot];
    pthread_mutex_unlock(&g_motion_mu);
    return known;
}
static int p1_gen1_motion(s2a_pad_motion out[2]) { return gen1_of(pad_id[0]) ? gen1_motion(pad_id[0], out) : 0; }
static int p1_gen1_rumble(const s2a_pad_vibration values[2]) { return gen1_rumble(pad_id[0], values); }
// 按槽位的 Joy-Con 2 鼠标（#520：P2 起各自的 Joy-Con 2，服务层写在各自的手柄号上，游戏靠它认 Joy-Con 2）：占这一格的是 NS2 手柄就照它这只报，否则回 0
__attribute__((visibility("default"), used)) int s2a_pad_read_mouse_slot(int slot, s2a_pad_mouse out[2]) {
    if (!out) return 0;
    out[0] = out[1] = (s2a_pad_mouse){0};
    if (slot <= 0 || slot >= S2A_MAX_PADS) return 0;
    const void *owner = pad_id[slot];
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) if (owner == &ns2_slot_id[p]) return s2a_mac_ns2_read_mouse_player(p, out);
    return 0;
}
// 每一格的实体手柄是什么样式（#520，同原机：手柄号的样式由连着的那只手柄定）：服务层 InputPump 多手柄时照它配每一格（游戏收就用，不收照旧）。
//   Ryujinx ControllerType：Pro 1、一对 4、左只 8、右只 16；系统手柄 / 键盘 / 没人回 0（照服务层原来的配法）
__attribute__((visibility("default"), used)) int s2a_vpad_slot_style(int slot) {
    if (slot < 0 || slot >= S2A_MAX_PADS) return 0;
    const void *owner = pad_id[slot];
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) if (owner == &ns2_slot_id[p]) {
        ns2_kind kind = s2a_mac_ns2_player_kind(p);
        return kind == NS2_KIND_JOYCON_L ? 1 << 3 : kind == NS2_KIND_JOYCON_R ? 1 << 4 : kind == NS2_KIND_JOYCON_PAIR ? 1 << 2 : kind == NS2_KIND_PRO ? 1 << 0 : 0;
    }
    gen1_unit *u = gen1_of(owner);
    if (u) {
        pthread_mutex_lock(&g_gen1_mu);
        int pair = u->pair; char left[64]; snprintf(left, sizeof left, "%s", u->left);
        pthread_mutex_unlock(&g_gen1_mu);
        if (pair) return 1 << 2;
        s2a_joycon_info jc[16]; int n = s2a_joycon_list(jc, 16);
        for (int i = 0; i < n; i++) if (!strcmp(jc[i].id, left)) return jc[i].pid == 0x2006 ? 1 << 3 : jc[i].pid == 0x2007 ? 1 << 4 : 0;
    }
    return 0;
}
// 分配玩家的顺序表（#520 E）：启动器写 ~/Library/Application Support/S2Arm/pad-order.json（launchers PlayerAssignment.orderFile），
//   这里约每秒看一次修改时间，变了就重读、清掉槽位表照新顺序重排（s2a_slot_plan 之后照常「留原槽」）。读不到 / 读不懂就照连接顺序（同改前）
static s2a_pad_order g_order;
static int g_order_loaded;
static long g_order_generation = -1;   // 启动器每完成一次分配玩家加一：只有它变了才清槽位重排（新手柄自动排进来不变，已在玩的人留原位）
static _Atomic int g_order_force;   // 游戏的手柄设置画面刚分配完：下一拍就重读顺序表，不等一秒
static BOOL pad_order_refresh(void) {
    static int ticks; static struct timespec stamp;
    if (ticks++ % 120 && !atomic_exchange(&g_order_force, 0)) return NO;
    const char *override = getenv("S2A_PAD_ORDER_FILE");   // 单测换一个不存在的路径，不读本机真分配过的那份
    NSString *path = override ? @(override) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/S2Arm/pad-order.json"];
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st)) { if (!g_order_loaded) return NO; g_order_loaded = 0; return YES; }
    if (g_order_loaded && st.st_mtimespec.tv_sec == stamp.tv_sec && st.st_mtimespec.tv_nsec == stamp.tv_nsec) return NO;
    stamp = st.st_mtimespec;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] ?: [NSData data] options:0 error:nil];
    s2a_pad_order order = {0};
    void (^fill)(id, s2a_pad_order_entry *, int *) = ^(id list, s2a_pad_order_entry *out, int *count) {
        for (NSDictionary *e in [list isKindOfClass:NSArray.class] ? list : @[]) {
            if (*count >= S2A_PAD_ORDER_MAX || ![e isKindOfClass:NSDictionary.class]) break;
            s2a_pad_order_entry *x = &out[(*count)++];
            BOOL ns2 = [e[@"type"] isEqual:@"ns2"], keyboard = [e[@"type"] isEqual:@"keyboard"], gen1 = [e[@"type"] isEqual:@"gen1"], gen1pair = [e[@"type"] isEqual:@"gen1pair"];
            x->ns2_player = keyboard ? S2A_PAD_ORDER_KEYBOARD : gen1 ? S2A_PAD_ORDER_GEN1 : gen1pair ? S2A_PAD_ORDER_GEN1_PAIR : ns2 ? [e[@"player"] intValue] : -1;
            if (keyboard) continue;
            if (gen1 || gen1pair) {   // 一代按设备：单只 id、一对「左 id|右 id」
                NSString *key = gen1 ? [e[@"id"] description] : [NSString stringWithFormat:@"%@|%@", e[@"left"], e[@"right"]];
                [key getCString:x->name maxLength:sizeof x->name encoding:NSUTF8StringEncoding];
                continue;
            }
            x->index = [e[@"index"] intValue];
            if (!ns2) [[e[@"name"] description] getCString:x->name maxLength:sizeof x->name encoding:NSUTF8StringEncoding];
        }
    };
    if ([json isKindOfClass:NSDictionary.class]) { fill(json[@"order"], order.entry, &order.count); fill(json[@"dropped"], order.dropped, &order.dropped_count); }
    BOOL was = g_order_loaded;
    long generation = [json isKindOfClass:NSDictionary.class] ? [json[@"generation"] longValue] : -1;
    BOOL reassign = !was || generation != g_order_generation;
    g_order = order; g_order_loaded = [json isKindOfClass:NSDictionary.class]; g_order_generation = generation;
    fprintf(stderr, "[s2a] 分配玩家顺序表：%d 位%s，没分配的 %d 只不给玩家位%s\n", order.count, g_order_loaded ? "" : "（读不懂，照连接顺序）", order.dropped_count,
            reassign ? "；重新分配过，照表重排" : "；只是接上 / 断开手柄，已在玩的留原位");
    return (g_order_loaded || was) && reassign;
}
// 游戏打开系统的手柄设置画面（Ryujinx 手柄设置小程序 → 服务层 Host.DisplayMessageDialog）时交给启动器的「分配玩家」（#520 E，面板与游戏同步）：
//   写 ~/Library/Application Support/S2Arm/assign-request.json（state = request），启动器 3 秒内改成 open 就等它 done / cancel（最多 5 分钟）；
//   没人接（启动器没开）→ 回 0，服务层照旧自动应答，不卡住游戏。done 回登记了几位玩家（顺序表已由启动器写好），cancel / 超时回 0
__attribute__((visibility("default"), used)) int s2a_vpad_assign(int min_players, int max_players, int styles) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/S2Arm"];
    NSString *path = [dir stringByAppendingPathComponent:@"assign-request.json"];
    NSString *token = NSUUID.UUID.UUIDString;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *request = [NSJSONSerialization dataWithJSONObject:@{@"token": token, @"state": @"request", @"min": @(min_players), @"max": @(max_players), @"styles": @(styles)} options:0 error:nil];
    if (![request writeToFile:path atomically:YES]) return 0;
    fprintf(stderr, "[s2a] 游戏的手柄设置画面：交给 S2Arm 面板分配玩家（%d–%d 人）\n", min_players, max_players);
    int players = 0; BOOL opened = NO;
    for (int tick = 0; tick < 3000; tick++) {   // 100 ms 一次：3 秒没接就放弃，接了最多等 5 分钟
        usleep(100 * 1000);
        NSDictionary *now = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] ?: [NSData data] options:0 error:nil];
        if (![now isKindOfClass:NSDictionary.class] || ![now[@"token"] isEqual:token]) break;   // 被删 / 被别的请求盖掉
        NSString *state = now[@"state"];
        if ([state isEqual:@"open"]) opened = YES;
        else if ([state isEqual:@"done"]) { players = [now[@"players"] intValue]; break; }
        else if ([state isEqual:@"cancel"]) break;
        if (!opened && tick >= 30) { fprintf(stderr, "[s2a] S2Arm 面板没接手柄设置画面，照旧自动应答\n"); break; }
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    if (players > 0) { atomic_store(&g_order_force, 1); usleep(150 * 1000); }   // 等主线程照新顺序表排好槽位
    fprintf(stderr, "[s2a] 手柄设置画面：%s\n", players > 0 ? [NSString stringWithFormat:@"分配了 %d 位玩家", players].UTF8String : "没分配（取消 / 没人接），照旧自动应答");
    return players;
}
// D2（#520）：顺序表里有一代 Joy-Con 左只 / 右只（分配成各一位玩家）就按设备读（joycon_imu.m HID），系统合成的那个不再占位
static BOOL gen1_split_wanted(void) {
    if (!g_order_loaded) return NO;
    for (int i = 0; i < g_order.count; i++) if (g_order.entry[i].ns2_player == S2A_PAD_ORDER_GEN1 || g_order.entry[i].ns2_player == S2A_PAD_ORDER_GEN1_PAIR) return YES;
    return NO;
}
// 这一拍的一代单元：key 认格子（同一 key 留同一格，s2a_slot_plan 才认得「还在原槽」）；新 key 拿一个这一拍没用、也不在槽位表里的格子
static gen1_unit *gen1_unit_for(const char *key, const char *left, const char *right, BOOL used[S2A_GEN1_UNITS]) {
    int pick = -1;
    for (int i = 0; i < S2A_GEN1_UNITS && pick < 0; i++) if (!used[i] && !strcmp(g_gen1[i].key, key)) pick = i;
    for (int i = 0; i < S2A_GEN1_UNITS && pick < 0; i++) {
        if (used[i]) continue;
        BOOL held = NO;
        for (int k = 0; k < S2A_MAX_PADS; k++) if (pad_id[k] == &g_gen1[i]) held = YES;
        if (!held) pick = i;
    }
    if (pick < 0) return NULL;
    used[pick] = YES;
    gen1_unit *u = &g_gen1[pick];
    if (strcmp(u->key, key)) {
        pthread_mutex_lock(&g_gen1_mu);
        snprintf(u->key, sizeof u->key, "%s", key); snprintf(u->left, sizeof u->left, "%s", left); snprintf(u->right, sizeof u->right, "%s", right ?: "");
        u->pair = right != NULL;
        pthread_mutex_unlock(&g_gen1_mu);
    }
    return u;
}
static void sample_input(void) {
    int32_t kbd_sticks[4] = {0}; uint32_t kbd_buttons = 0;
    uint32_t slot_buttons[S2A_MAX_PADS] = {0};
    int32_t slot_sticks[S2A_MAX_PADS][4] = {{0}};
    GCExtendedGamepad *active = focused ? active_pad(GCController.controllers) : nil;
    // 玩家 1 的体感 / 震动跟着占槽 0 的那只系统手柄（上一拍的槽位表）；槽 0 不是系统手柄时照旧用最近有输入的那只（#520 E）
    GCExtendedGamepad *lead = focused && pad_owner[0].extendedGamepad ? pad_owner[0].extendedGamepad : active;
    sample_motion(lead);
    if (lead) rumble_select(lead.controller);   // 失焦不换会话：切回来同一个手柄接着震
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
    // —— 与手柄快速路径共用 g_compose_mu 的采样发布段：键鼠 / 静音快照、槽位镜像、槽位原子量、发布都在锁内交接，
    //    两条线谁拿到锁谁重读要合的那份再发布，交错也不会丢键 ——
    pthread_mutex_lock(&g_compose_mu);
    // 键盘 / 鼠标快照：快速路径合槽 0 时读的就是这两份（失焦 / 开退出确认条时 kbd_buttons 本来就是 0）
    atomic_store(&kbd_buttons_snap, kbd_buttons);
    for (int i = 0; i < 4; i++) atomic_store(&kbd_sticks_snap[i], kbd_sticks[i]);
    atomic_store(&input_muted, muted);
    // 在线的手柄（顺序 = 连接顺序）：NS2 手柄（通道每位玩家一只）+ 系统报上来的扩展手柄；数组留得比槽位多，超出的交给 s2a_slot_plan 判 -1 丢弃
    ns2_state ble[NS2_RELAY_PLAYERS]; uint32_t bleSide[NS2_RELAY_PLAYERS] = {0}; int bleCount = 0;
    const void *live_ids[S2A_LIVE_MAX]; GCExtendedGamepad *live_pads[S2A_LIVE_MAX]; GCController *live_ctrls[S2A_LIVE_MAX] = {nil}; int live_ble[S2A_LIVE_MAX]; int n = 0;
    const s2a_hid_pad *live_hid[S2A_LIVE_MAX] = {NULL};   // 兜底 HID 手柄（macos/hid_pad.m，#934）
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) {
        // 单只 Joy-Con 已按游戏样式整形（玩家 0；其余玩家转横握）；SL / SR 不在键位配置里，直接并进它那一槽（#520 A）
        s2a_mac_ns2_read_player(p, &ble[p], &bleSide[p], NULL);   // 失焦时读数是零，但仍占槽（同系统手柄：失焦照扫槽位）
        if (!s2a_mac_ns2_player_present(p)) continue;
        live_ids[n] = &ns2_slot_id[p]; live_pads[n] = nil; live_ble[n] = p; n++; bleCount++;
    }
    // D2：一代 Joy-Con 按设备当玩家——顺序表里登记的单只各一位（按键照横握视角），登记成一对的两只合成一位（竖握，s2a_joycon1_pair_decode）。
    //   几套一代各认各的设备 id；没登记的那几只还在系统合成的那一位里（照系统手柄读），这里不另算；拆开过的那一位启动器列进 dropped，不重复
    BOOL gen1_split = gen1_split_wanted();
    static BOOL gen1_split_was;
    if (gen1_split != gen1_split_was) { gen1_split_was = gen1_split; s2a_joycon_pad_set_enabled(gen1_split); }
    ns2_state gen1_state[S2A_GEN1_UNITS] = {{0}};
    const char *live_key[S2A_LIVE_MAX] = {0};
    if (gen1_split) {
        s2a_joycon_info jc[16]; int njc = s2a_joycon_list(jc, 16);
        BOOL taken[16] = {NO}, used[S2A_GEN1_UNITS] = {NO};
        for (int i = 0; i < njc; i++) if (jc[i].pid != 0x2006 && jc[i].pid != 0x2007) taken[i] = YES;   // Pro 不拆，照系统手柄
        for (int list = 0; list < 2; list++) {   // 登记成一对的（玩家表 + 没分配的）：两只都在才合成一位
            const s2a_pad_order_entry *es = list ? g_order.dropped : g_order.entry; int count = list ? g_order.dropped_count : g_order.count;
            for (int e = 0; e < count && n < S2A_LIVE_MAX; e++) {
                if (es[e].ns2_player != S2A_PAD_ORDER_GEN1_PAIR) continue;
                char left[64] = {0}; const char *bar = strchr(es[e].name, '|');
                if (!bar) continue;
                snprintf(left, sizeof left, "%.*s", (int)(bar - es[e].name), es[e].name);
                int li = -1, ri = -1;
                for (int i = 0; i < njc; i++) if (!taken[i]) { if (!strcmp(jc[i].id, left)) li = i; if (!strcmp(jc[i].id, bar + 1)) ri = i; }
                if (li < 0 || ri < 0) continue;   // 少了一只：剩下那只下面当单只
                gen1_unit *u = gen1_unit_for(es[e].name, left, bar + 1, used);
                if (!u) continue;
                taken[li] = taken[ri] = YES;
                uint8_t lraw[S2A_JC1_RAW], rraw[S2A_JC1_RAW]; uint32_t b; int32_t st[4];
                int lok = s2a_joycon_pad_raw_id(left, lraw), rok = s2a_joycon_pad_raw_id(bar + 1, rraw);
                s2a_joycon1_pair_decode(lok ? lraw : NULL, rok ? rraw : NULL, &b, st);
                gen1_state[u - g_gen1] = (ns2_state){.buttons = b, .lx = st[0], .ly = st[1], .rx = st[2], .ry = st[3]};
                live_ids[n] = u; live_pads[n] = nil; live_ctrls[n] = nil; live_ble[n] = S2A_PAD_ORDER_GEN1_PAIR; live_key[n] = u->key; n++;
            }
        }
        for (int i = 0; i < njc && n < S2A_LIVE_MAX; i++) {
            uint32_t b; int32_t st[4]; int sides;
            if (taken[i] || s2a_pad_order_rank(&g_order, S2A_PAD_ORDER_GEN1, jc[i].id, 0) == S2A_PAD_ORDER_UNLISTED || !s2a_joycon_pad_read_id(jc[i].id, &b, st, &sides, NULL)) continue;
            gen1_unit *u = gen1_unit_for(jc[i].id, jc[i].id, NULL, used);
            if (!u) continue;
            // 原始方向还是横握（#520，同 Joy-Con 2，照它占的那一格的样式）：单只本侧 / 一对样式 → 原样（竖握布局，游戏按握法自己转），SL / SR 另给扩展位；扮 Pro → 横握视角
            ns2_kind kind = jc[i].pid == 0x2006 ? NS2_KIND_JOYCON_L : NS2_KIND_JOYCON_R;
            u->side_keys = 0;
            uint8_t raw[S2A_JC1_RAW];
            if (s2a_mac_ns2_raw_wanted(kind, atomic_load(&u->style)) && s2a_joycon_pad_raw_id(jc[i].id, raw)) {
                s2a_joycon1_pair_decode(kind == NS2_KIND_JOYCON_L ? raw : NULL, kind == NS2_KIND_JOYCON_R ? raw : NULL, &b, st);
                int left = kind == NS2_KIND_JOYCON_L;
                if (sides & S2A_JC1_SIDE_SL) u->side_keys |= left ? 1u << 24 : 1u << 26;
                if (sides & S2A_JC1_SIDE_SR) u->side_keys |= left ? 1u << 25 : 1u << 27;
            }
            gen1_state[u - g_gen1] = (ns2_state){.buttons = b, .lx = st[0], .ly = st[1], .rx = st[2], .ry = st[3]};
            live_ids[n] = u; live_pads[n] = nil; live_ctrls[n] = nil; live_ble[n] = S2A_PAD_ORDER_GEN1; live_key[n] = u->key; n++;
        }
    }
    for (GCController *c in GCController.controllers) {
        GCExtendedGamepad *p = c.extendedGamepad;
        if (!p && !pad_has_profile_buttons(c)) continue;   // 只有通用物理描述的手柄也进槽位（sample_profile_state）
        // 同一只 NS2 手柄也出现在系统手柄列表里：通道那一路已经读了，这里不再占一位玩家
        if (bleCount && s2a_pad_is_ns2(c.productCategory.UTF8String)) {
            static __weak GCController *noted;
            if (noted != c) { noted = c; fprintf(stderr, "[s2a] 系统手柄「%s」是 NS2 手柄，已由 S2Arm 连接读取，不另占玩家位\n", c.productCategory.UTF8String ?: "?"); }
            continue;
        }
        if (n >= S2A_LIVE_MAX) break;
        live_ids[n] = (__bridge const void *)c; live_pads[n] = p; live_ctrls[n] = c; live_ble[n] = -1; n++;
    }
    // 兜底手柄（macos/hid_pad.m，#934）：GameController 认不出的 Switch 样式 HID 手柄，排在系统手柄后面；系统已枚举到同名手柄就跳过（不变成两个玩家）。
    //   分配玩家里同系统手柄（按名字 + 第几只认）
    static s2a_hid_pad hid[S2A_HID_PAD_MAX];
    int nh = s2a_mac_hid_pad_read(hid);
    for (int h = 0; h < nh && n < S2A_LIVE_MAX; h++) {
        BOOL seen = NO;
        for (GCController *c in GCController.controllers) if ([c.vendorName isEqualToString:@(hid[h].name)]) { seen = YES; break; }
        if (seen) continue;
        live_ids[n] = hid[h].id; live_pads[n] = nil; live_ctrls[n] = nil; live_ble[n] = -1; live_hid[n] = &hid[h]; n++;
    }
    // 分配玩家：照顺序表排（表里的在前、没列的照原顺序接着），分配时没登记的系统手柄不进槽位；表一换就清槽位表重排
    if (pad_order_refresh()) for (int i = 0; i < S2A_MAX_PADS; i++) { pad_id[i] = NULL; pad_owner[i] = nil; pad_slot_owner[i] = nil; }
    // 键盘（含鼠标按键）分配成一位玩家（顺序表里有 keyboard）：自己占一个槽、不再并进槽 0；没分配就照旧并进玩家 1（没手柄时键盘就是玩家 1）
    BOOL kbd_own = g_order_loaded && s2a_pad_order_rank(&g_order, S2A_PAD_ORDER_KEYBOARD, NULL, 0) < S2A_PAD_ORDER_UNLISTED;
    if (kbd_own && n < S2A_LIVE_MAX) { live_ids[n] = &kbd_slot_id; live_pads[n] = nil; live_ctrls[n] = nil; live_ble[n] = S2A_PAD_ORDER_KEYBOARD; n++; }
    atomic_store(&kbd_buttons_snap, kbd_own ? 0 : kbd_buttons);   // 手柄快速路径合槽 0 时读这份：键盘有自己的槽就不合
    if (kbd_own) for (int i = 0; i < 4; i++) atomic_store(&kbd_sticks_snap[i], 0);
    if (g_order_loaded) {
        int rank[S2A_LIVE_MAX], m = 0; NSMutableDictionary<NSString *, NSNumber *> *seen = [NSMutableDictionary new];
        for (int j = 0; j < n; j++) {
            NSString *name = live_ctrls[j] ? (live_ctrls[j].vendorName ?: live_ctrls[j].productCategory) : live_hid[j] ? @(live_hid[j]->name) : nil;
            int index = name ? seen[name].intValue : 0;
            if (name) seen[name] = @(index + 1);
            rank[j] = s2a_pad_order_rank(&g_order, live_ble[j], live_key[j] ?: name.UTF8String, index);   // 一代按设备：照设备 id 认
        }
        int order_idx[S2A_LIVE_MAX]; for (int j = 0; j < n; j++) order_idx[j] = j;
        for (int a = 1; a < n; a++) for (int b = a; b > 0 && rank[order_idx[b]] < rank[order_idx[b - 1]]; b--) { int t = order_idx[b]; order_idx[b] = order_idx[b - 1]; order_idx[b - 1] = t; }   // 稳定排序
        const void *ids[S2A_LIVE_MAX]; GCExtendedGamepad *pads[S2A_LIVE_MAX]; GCController *ctrls[S2A_LIVE_MAX]; int bles[S2A_LIVE_MAX]; const char *keys2[S2A_LIVE_MAX]; const s2a_hid_pad *hids[S2A_LIVE_MAX];
        for (int k = 0; k < n; k++) {
            int j = order_idx[k];
            if (rank[j] == S2A_PAD_ORDER_DROPPED) continue;   // 分配时没登记：同原机断开（系统手柄 S2Arm 断不了蓝牙，游戏不读它）
            ids[m] = live_ids[j]; pads[m] = live_pads[j]; ctrls[m] = live_ctrls[j]; bles[m] = live_ble[j]; keys2[m] = live_key[j]; hids[m] = live_hid[j]; m++;
        }
        for (int k = 0; k < m; k++) { live_ids[k] = ids[k]; live_pads[k] = pads[k]; live_ctrls[k] = ctrls[k]; live_ble[k] = bles[k]; live_key[k] = keys2[k]; live_hid[k] = hids[k]; }
        for (int k = m; k < n; k++) live_ctrls[k] = nil;
        n = m;
    }
    static int logged_mix;   // 诊断：NS2 手柄与系统手柄同时在线时列一次（实机定去重规则用）
    int mix = bleCount && n > bleCount;
    if (mix && !logged_mix) {
        for (int j = 0; j < n; j++) if (live_ble[j] == -1) fprintf(stderr, "[s2a] 与 NS2 手柄同时在线的系统手柄：%s（%s）\n",
            live_ctrls[j].vendorName.UTF8String ?: "?", live_ctrls[j].productCategory.UTF8String ?: "?");
    }
    logged_mix = mix;
    int slot_of[S2A_LIVE_MAX];
    int live = s2a_slot_plan(pad_id, live_ids, n, S2A_MAX_PADS, slot_of);
    // 断开清槽：整表重建，只有本轮还在的才写回（强引用随之释放，不会留悬空指针）
    GCController *owner_before[S2A_MAX_PADS];
    for (int i = 0; i < S2A_MAX_PADS; i++) owner_before[i] = pad_owner[i];
    for (int i = 0; i < S2A_MAX_PADS; i++) { pad_id[i] = NULL; pad_owner[i] = nil; pad_slot_owner[i] = nil; }
    for (int j = 0; j < n; j++) {
        int s = slot_of[j];
        if (s < 0) continue;   // 超过 S2A_MAX_PADS 只：多出来的不参与
        pad_id[s] = live_ids[j];
        if (live_ble[j] == S2A_PAD_ORDER_GEN1 || live_ble[j] == S2A_PAD_ORDER_GEN1_PAIR) {
            gen1_unit *u = gen1_of(live_ids[j]);
            sample_ns2_state(&gen1_state[u - g_gen1], &slot_buttons[s], slot_sticks[s]);
            slot_buttons[s] |= u->side_keys;
            atomic_store(&u->style, atomic_load(&g_slot_style[s]));   // 下一拍照这一格的样式定原始方向 / 横握
        }
        else if (live_ble[j] == S2A_PAD_ORDER_KEYBOARD) { slot_buttons[s] = kbd_buttons; for (int i = 0; i < 4; i++) slot_sticks[s][i] = kbd_sticks[i]; }
        else if (live_ble[j] >= 0) { int p = live_ble[j]; sample_ns2_state(&ble[p], &slot_buttons[s], slot_sticks[s]); slot_buttons[s] |= bleSide[p]; }
        else if (live_hid[j]) { const s2a_hid_pad *h = live_hid[j]; sample_coded_state(h->buttons, h->lx, h->ly, h->rx, h->ry, &slot_buttons[s], slot_sticks[s]); }
        else if (live_pads[j]) { pad_owner[s] = live_ctrls[j]; pad_slot_owner[s] = live_ctrls[j]; sample_pad_state(live_pads[j], &slot_buttons[s], slot_sticks[s]); }
        else { pad_owner[s] = live_ctrls[j]; pad_slot_owner[s] = live_ctrls[j]; sample_profile_state(live_ctrls[j], &slot_buttons[s], slot_sticks[s]); }
    }
    int ns2_style[NS2_RELAY_PLAYERS] = {0};   // 玩家 2 起的单只 Joy-Con 照它占的那一格的样式整形（下一拍读时用；没占格 = 转横握）
    for (int i = 0; i < S2A_MAX_PADS; i++) for (int p = 0; p < NS2_RELAY_PLAYERS; p++) if (pad_id[i] == &ns2_slot_id[p]) ns2_style[p] = atomic_load(&g_slot_style[i]);
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) s2a_mac_ns2_set_player_style(p, ns2_style[p]);   // 玩家 0 没占格（0）时照游戏给 P1 的样式
    for (int i = 0; i < S2A_MAX_PADS; i++)   // 槽位换了手柄（或清空）：重新起算「接上多久」
        if (pad_owner[i] != owner_before[i]) atomic_store(&pad_owner_since[i], pad_owner[i] ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0);
    sample_slot_motion(owner_before);
    // 玩家 1 是不是 NS2 手柄（通道玩家 0）：体感 / 震动 / 鼠标跟它走；原始方向的单只 Joy-Con 也只在它占槽 0 时按 BLE 源发布
    int slot0_player = !n ? 0 : -1;
    for (int p = 0; p < NS2_RELAY_PLAYERS; p++) if (pad_id[0] == &ns2_slot_id[p]) slot0_player = p;
    int slot0_ns2 = slot0_player >= 0;
    atomic_store(&g_slot0_player, slot0_player < 0 ? 0 : slot0_player);
    atomic_store(&g_slot0_ns2, slot0_ns2);
    ble_raw_source = slot0_ns2 && s2a_mac_ns2_player_raw(slot0_player);
    if (muted) {
        memset(slot_buttons, 0, sizeof slot_buttons); memset(slot_sticks, 0, sizeof slot_sticks);
    } else {
        if (!kbd_own) {   // 槽 0 = 键盘 / 鼠标 / 触屏 + 第一只手柄（键盘分配到别的槽时不并）
            slot_buttons[0] |= kbd_buttons;
            for (int i = 0; i < 4; i++) slot_sticks[0][i] += kbd_sticks[i];
        }
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
    publish_keyboard(muted);   // R5：键盘区原始键态（先落键态再唤醒，泵醒来读到同一拍）
    pthread_mutex_unlock(&g_compose_mu);
}
// 多手柄槽位（服务层 InputPump 按符号查；没导出时退回旧的单手柄 ABI）
__attribute__((visibility("default"), used)) int s2a_vpad_pad_count(void) { return atomic_load(&pad_live); }
__attribute__((visibility("default"), used)) uint32_t s2a_vpad_read_pad(int index, int32_t *sticks) {
    if (index < 0 || index >= S2A_MAX_PADS) { for (int i = 0; i < 4; i++) sticks[i] = 0; return 0; }
    uint32_t buttons = atomic_load_explicit(&pad_buttons[index], memory_order_seq_cst);
    for (int i = 0; i < 4; i++) sticks[i] = atomic_load_explicit(&pad_sticks[index][i], memory_order_seq_cst);
    return buttons;
}
// 手柄事件的专用串行队列（对齐 iOS ios/controller.m 的 s2arm.controller.input）：valueChangedHandler 全在这条队列上跑，
//   主线程被菜单动画 / 提示条 / 系统弹窗占住时手柄事件不再排在后面。交互优先级对齐主队列，输入不排低优先后面
static dispatch_queue_t pad_input_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("dev.s2arm.mac-pad-input", s2a_qos_queue_attr(DISPATCH_QUEUE_SERIAL, S2A_QOS_INPUT));
    });
    return queue;
}
// 手柄快速路径（pad_input_queue 上跑，valueChangedHandler 的回调体）：只采样这一只手柄并立即发布。
//   槽 0（玩家 1）合主线程刚刷新的键盘 / 鼠标快照走发布（旧 ABI 快照 + pad.c 事件唤醒 HID 泵，pad.c 自带锁）；
//   槽 1–3（玩家 2–4）只写自己的槽位原子量，再 s2a_pad_wake 叫泵立刻重读（原先玩家 2–4 只能等 16ms 心跳）。
//   没占到槽（刚接上、还没被 120Hz 定时器排进槽位表）就交给定时器那一轮，下一事件起走这里——采样读的是当前整份状态，
//   长按 / 持续推摇杆时快速路径与定时器采样任一份都完整，与 A2 的「只发变化不丢按住」负对照同一性质。
//   静音（失焦 / 开退出确认条）照发零；失焦那一拍 pad.c 也已 inactive（s2a_pad_set_active(0)）双兜底。
//   全程 g_compose_mu 与主线程的采样发布段互斥，不碰 keys / mouse 这些只在主线程安全的东西（config 启动后不变，
//   键位布局 / 槽位身份 / 强引用走原子量与锁内镜像）。
static void pad_event_fast(GCController *controller) {
    pthread_mutex_lock(&g_compose_mu);
    int slot = -1;
    for (int i = 0; i < S2A_MAX_PADS; i++) if (pad_slot_owner[i] == controller) { slot = i; break; }
    if (slot < 0) { pthread_mutex_unlock(&g_compose_mu); return; }
    uint32_t buttons = 0; int32_t sticks[4] = {0};
    if (controller.extendedGamepad) sample_pad_state(controller.extendedGamepad, &buttons, sticks);
    else sample_profile_state(controller, &buttons, sticks);
    if (atomic_load(&input_muted)) {
        buttons = 0; memset(sticks, 0, sizeof sticks);
    } else if (slot == 0) {
        buttons |= atomic_load(&kbd_buttons_snap);   // 槽 0 = 键盘 / 鼠标 / 触屏 + 第一只手柄（快照由主线程每次采样刷新）
        for (int i = 0; i < 4; i++) sticks[i] += atomic_load(&kbd_sticks_snap[i]);
    }
    for (int i = 0; i < 4; i++) sticks[i] = MAX(-32767, MIN(32767, sticks[i]));
    atomic_store(&pad_buttons[slot], buttons);
    for (int i = 0; i < 4; i++) atomic_store(&pad_sticks[slot][i], sticks[i]);
    if (slot == 0) {
        publish(buttons, sticks);   // 旧 ABI 快照：与主线程同一个 publish（序号锁不允许多写者并写，g_compose_mu 兜住）
        s2a_pad_update(S2A_PAD_SYSTEM, 1, buttons, sticks);   // 占到槽即在线；不读主线程的 focused（静音发零、失焦时 pad.c inactive 已兜底）
    } else {
        s2a_pad_wake();   // 槽 0 那份没变也要叫醒泵：玩家 2–4 的槽位原子量变了，泵重读就拿到
    }
    pthread_mutex_unlock(&g_compose_mu);
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
// 出图层可画尺寸（#575）：缺省跟「视图尺寸 × backingScaleFactor」走。
//   S2A_OUT_W / S2A_OUT_H（两个都给、各 64–8192 像素）：可画尺寸钉在这个值，层内容在窗口里等比居中、余边留黑，拖窗口 / 全屏 / 系统恢复 frame 都不改渲染尺寸；
//   S2A_OUT_SCALE（0.5–1.0，同 iOS graphics/nvn/host_adapt.m layout_layer）：可画尺寸按倍数缩，交系统合成器放大。两者都给时固定尺寸优先
static int g_out_w = -1, g_out_h; static double g_out_k = 1;
static void out_cfg(void) {
    if (g_out_w >= 0) return;
    const char *w = getenv("S2A_OUT_W"), *h = getenv("S2A_OUT_H"), *k = getenv("S2A_OUT_SCALE");
    long ww = w ? atol(w) : 0, hh = h ? atol(h) : 0; double kk = k ? atof(k) : 1;
    g_out_w = 0; g_out_h = 0; g_out_k = kk >= 0.5 && kk <= 1.0 ? kk : 1.0;
    if (ww >= 64 && ww <= 8192 && hh >= 64 && hh <= 8192) { g_out_w = (int)ww; g_out_h = (int)hh; fprintf(stderr, "[s2a] 出图层可画尺寸固定 %dx%d（S2A_OUT_W / S2A_OUT_H），窗口里等比居中、余边留黑\n", g_out_w, g_out_h); }
    else if (w || h) fprintf(stderr, "[s2a] S2A_OUT_W / S2A_OUT_H 要两个都给、各 64–8192（读到 %s / %s），出图层照旧跟窗口\n", w ? w : "-", h ? h : "-");
    if (!g_out_w && g_out_k != 1.0) fprintf(stderr, "[s2a] 出图层可画尺寸按 %.2f 倍（S2A_OUT_SCALE），交系统合成器放大\n", g_out_k);
    else if (k && g_out_k == 1.0 && kk != 1.0) fprintf(stderr, "[s2a] S2A_OUT_SCALE 要 0.5–1.0（读到 %s），按 1\n", k);
}
- (void)layout {
    [super layout];
    CAMetalLayer *metal = (CAMetalLayer *)self.layer;
    metal.contentsScale = self.window.backingScaleFactor ?: 1;
    CGSize size = CGSizeMake(self.bounds.size.width * metal.contentsScale, self.bounds.size.height * metal.contentsScale);
    out_cfg();
    if (g_out_w) { size = CGSizeMake(g_out_w, g_out_h); metal.contentsGravity = kCAGravityResizeAspect; }
    else if (g_out_k != 1.0) size = CGSizeMake(floor(size.width * g_out_k), floor(size.height * g_out_k));
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
    caps_locked = (e.modifierFlags & NSEventModifierFlagCapsLock) != 0;   // R5：键盘区随 modifiers 一并由 sample_input 发布
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
    set_mouse_capture(NO); focused = NO; input_mute_refresh(); s2a_pad_set_active(0); reset_input();
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
- (void)windowDidBecomeKey:(NSNotification *)note { (void)note; display_focus_publish(game_window_focused(self.window)); if (mouse_release_pending) set_mouse_capture(NO); focused = YES; input_mute_refresh(); s2a_pad_set_active(1); reset_input(); }
// 失去 key：本机键鼠照旧停喂、复位；报给游戏的焦点看 key window 落到哪（AppKit 发这条通知时 NSApp.keyWindow 已是新窗口，sheet 也一样）
- (void)windowDidResignKey:(NSNotification *)note { (void)note; display_focus_publish(game_window_focused(self.window)); set_mouse_capture(NO); focused = NO; input_mute_refresh(); s2a_pad_set_active(0); reset_input(); }
- (void)applicationDidResignActive:(NSNotification *)note { (void)note; display_focus_publish(NO); set_mouse_capture(NO); focused = NO; input_mute_refresh(); s2a_pad_set_active(0); reset_input(); }
- (void)applicationDidBecomeActive:(NSNotification *)note { (void)note; display_focus_publish(game_window_focused(self.window)); focused = self.window.isKeyWindow; input_mute_refresh(); }
@end

// 确认条：打开时游戏失焦（同 Switch 的 HOME 菜单）、不收手柄输入；A / 点「退出」走关窗同一条收尾（等存档写完），B / Home / 点「回到游戏」/ 30 秒没理会收起
static void home_quit_ui(s2a_hq_action action) {
    S2AMacDelegate *d = g_delegate;
    if (!d) return;
    switch (action) {
        case S2A_HQ_OPEN:
            fprintf(stderr, "[s2a] 手柄按住 Home：弹出退出确认\n");
            display_focus_publish(NO);
            d.banner.onAnswer = ^(BOOL accept) { s2a_hq_close(&g_hq); input_mute_refresh(); if (accept) [g_delegate shutdown]; else display_focus_publish(game_window_focused(g_delegate.window)); };
            [d.banner showTitle:@S2A_DPROMPT_HOME_QUIT_TITLE body:@S2A_DPROMPT_HOME_QUIT_BODY accept:@S2A_DPROMPT_HOME_QUIT_ACCEPT decline:@S2A_DPROMPT_HOME_QUIT_DECLINE seconds:30];
            break;
        case S2A_HQ_QUIT: [g_delegate shutdown]; d.banner.onAnswer = nil; d.banner.hidden = YES; fprintf(stderr, "[s2a] 手柄按 A：退出游戏\n"); break;
        case S2A_HQ_CANCEL: d.banner.onAnswer = nil; d.banner.hidden = YES; display_focus_publish(game_window_focused(d.window)); break;
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
        view.wantsLayer = YES; CAMetalLayer *layer = [CAMetalLayer layer]; layer.opaque = YES; layer.backgroundColor = NSColor.blackColor.CGColor;   // 固定出图尺寸时等比居中的余边（#575）
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
        // 启动即全屏（#575，S2A_FULLSCREEN=1）：窗口出来后走系统原生全屏，同菜单「进入全屏幕」，退出后回到窗口
        { const char *fs = getenv("S2A_FULLSCREEN"); if (fs && !strcmp(fs, "1")) { fprintf(stderr, "[s2a] 启动即全屏（S2A_FULLSCREEN=1）\n"); dispatch_async(dispatch_get_main_queue(), ^{ if (!window_fullscreen(window)) window_fullscreen_toggle(window); }); } }
        [app activateIgnoringOtherApps:YES]; focused = YES; input_mute_refresh();
        s2a_pad_set_active(1);
        install_pad_handlers();
        display_focus_publish(game_window_focused(window));
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
        set_mouse_capture(NO); focused = NO; input_mute_refresh(); reset_input(); s2a_mac_ns2_detach(); front_layer_detach();
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
