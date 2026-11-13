// Tests the actual Mac input adapter, including atomic cross-thread snapshots.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <locale.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "../../../macos/ns2_relay.h"
#include "../../../ios/input_config.h"
#import "../../../macos/front_mac.m"
#import "../../../macos/input_guide.m"
#import "../../../macos/controller_view.m"

static BOOL guide_preview;
void s2a_host_shutdown(const char *why) { (void)why; if (guide_preview) exit(0); abort(); }
void s2a_clock_catchup(void) {}   // 游戏日历补时（runtime/src/os.c，Mac 唤醒通知调）在这里不测
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }   // 宿主单调时钟（runtime/src/os.c）：前台焦点计时用（#965 起 front_mac.m 引用），给真时钟
// 生命周期桩（接口 v2.15，缺口扫描族 1）：记下前端报的焦点 / 睡眠、客机冻结与时钟原因 3 的开关次数
static int stub_focus = 1, stub_suspend, stub_sleep, stub_freeze_on, stub_freeze_off, stub_clock3_on, stub_clock3_off;
void s2a_host_focus_set(int focused) { stub_focus = focused; }
int s2a_focus_suspend(void) { return stub_suspend; }
void s2a_host_sleep_set(int sleeping) { stub_sleep = sleeping; }
void s2a_guest_freeze(int on) { if (on) stub_freeze_on++; else stub_freeze_off++; }
void guest_clock_freeze_for(int reason, int on) { if (reason == 3) { if (on) stub_clock3_on++; else stub_clock3_off++; } }
static int width, height;
static int gfx_mode = S2A_GFX_GENERIC, layer_calls;
static void *notified_layer, *published_at_notify;
int s2a_gfx_mode(void) { return gfx_mode; }
void nxgal_window_set_layer(void *layer) {
    layer_calls++; notified_layer = layer; published_at_notify = s2a_mac_front_layer();
}
void nxgal_window_set_size(int32_t w, int32_t h) { width = w; height = h; }
static int fit_w, fit_h;
int s2a_screen_fit(int pw, int ph) { fit_w = pw; fit_h = ph; return 0; }   // 宽屏跟窗口比例（runtime/src/widen.c）：只记前端交出的像素尺寸
int s2a_hud_on(void) { return 0; }   // 开发浮层（runtime/src/hud.c）在这里不测，关着
int s2a_hud_text(char *out, size_t n, const s2a_hud_host *h) { (void)h; return snprintf(out, n, "%s", ""); }
// 存档原子提交判定（runtime/src/direct_prompt.c s2a_save_atomic_poll，判定本身由 runtime/tests/t_direct_prompt.c 测）：这里只给读数，测 Mac 横幅接线
static int fake_atomic;
int s2a_save_atomic_poll(void) { int bits = fake_atomic; fake_atomic = 0; return bits; }

// 鼠标左键当触屏的画面矩形（front_mac.m touch_picture）：渲染层这一帧 / 宽屏状态由单测给
static int fake_frame_w, fake_frame_h, fake_widen_game, fake_widen_full, fake_screen_w = 1920, fake_screen_h = 1080;
int nxgal_present_frame(int32_t *w, int32_t *h, float *ax, float *ay, int32_t *stretched) {
    *w = fake_frame_w; *h = fake_frame_h; *ax = 16; *ay = 9; *stretched = 0; return fake_frame_w > 0;
}
int s2a_widen_game(void) { return fake_widen_game; }
int s2a_widen_full(void) { return fake_widen_full; }
int s2a_screen_w(void) { return fake_screen_w; }
int s2a_screen_h(void) { return fake_screen_h; }
static void expect(int ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }
static NSEvent *key_event(NSEventType type, unsigned short code, BOOL repeat) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:0
        windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:repeat keyCode:code];
}
static BOOL physical_keys[128];
static void poll_stale(void) { for (int n = 0; n < KEY_UP_POLLS; n++) release_stale_keys(); sample_input(); }   // 采样连续报松开满 KEY_UP_POLLS 次才删键
static bool key_state(CGEventSourceStateID state, CGKeyCode code) {
    expect(state == kCGEventSourceStateCombinedSessionState, "query current login session");
    return code < 128 && physical_keys[code];
}

static void test_key_repeat(void) {
    config = default_config(); reset_input(); focused = YES;
    read_key_state = key_state;
    S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSZeroRect];
    unsigned short arrows[] = {123, 126, 124, 125};
    for (int i = 0; i < 4; i++) {
        int32_t sticks[4]; uint32_t bit = 1u << (12 + i);
        physical_keys[arrows[i]] = YES;
        [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], NO)];
        for (int n = 0; n < 1200; n++) [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], YES)];
        expect(s2a_vpad_read(sticks) == bit, "long hold retains direction");
        [view keyUp:key_event(NSEventTypeKeyUp, arrows[i], NO)];
        expect(s2a_vpad_read(sticks) == 0, "release clears repeated direction");
        [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], YES)];
        expect(s2a_vpad_read(sticks) == 0, "late repeat cannot restore released direction");

        physical_keys[arrows[i]] = YES;
        [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], NO)];
        for (int n = 0; n < 1200; n++) { release_stale_keys(); sample_input(); }
        expect(s2a_vpad_read(sticks) == bit, "polling preserves a long physical hold");
        physical_keys[arrows[i]] = NO; // 故意不发送 keyUp，验证下一次采样能恢复
        poll_stale();
        expect(s2a_vpad_read(sticks) == 0, "polling recovers missing arrow release");
    }
    int32_t sticks[4];
    physical_keys[14] = physical_keys[13] = YES;
    [view keyDown:key_event(NSEventTypeKeyDown, 14, NO)];
    [view keyDown:key_event(NSEventTypeKeyDown, 13, NO)];
    physical_keys[13] = NO;
    poll_stale();
    expect(s2a_vpad_read(sticks) == 1 && sticks[1] == 0, "releasing stick direction preserves another held button");
    physical_keys[14] = NO;
    poll_stale();
    expect(s2a_vpad_read(sticks) == 0, "polling recovers missing ordinary key release");

    [keys addObject:@56]; modifiers = 1; physical_keys[60] = YES;
    poll_stale();
    expect(s2a_vpad_read(sticks) == 2 && modifiers == 1, "right shift preserves canonical modifier");
    physical_keys[60] = NO;
    poll_stale();
    expect(s2a_vpad_read(sticks) == 0 && modifiers == 0, "missing modifier release clears chords");

    physical_keys[123] = YES;
    S2AMacDelegate *delegate = [S2AMacDelegate new];
    [view keyDown:key_event(NSEventTypeKeyDown, 123, NO)];
    [delegate windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:nil]];
    [view keyDown:key_event(NSEventTypeKeyDown, 123, NO)];
    [view keyDown:key_event(NSEventTypeKeyDown, 123, YES)];
    expect(s2a_vpad_read(sticks) == 0 && keys.count == 0, "focus loss and queued repeat leave input neutral");
    [delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:nil]];
    [view keyUp:key_event(NSEventTypeKeyUp, 123, NO)];
    [view keyDown:key_event(NSEventTypeKeyDown, 123, YES)];
    expect(s2a_vpad_read(sticks) == 0, "unfocused press then focused release and late repeat remain neutral");
    [view keyDown:key_event(NSEventTypeKeyDown, 123, NO)];
    [view keyUp:key_event(NSEventTypeKeyUp, 123, NO)];
    expect(s2a_vpad_read(sticks) == 0, "fresh press and release still work after focus returns");
    physical_keys[123] = NO;
    poll_input(); // 同时编译、链接并执行生产定时采样入口
    puts("Mac keyboard: four arrows x 1200 repeats and polls, lost keyUp, chords and focus passed");
}
// 审计 P2-13 界面半边：判定（只提示一次）挪到 runtime/src/direct_prompt.c 与 iOS 共用（P2-45）；这里测生产 pollPrompt 拿到非 0 就亮横幅、为 0 不亮。期望手算
static void test_save_atomic_warning(void) {
    S2AMacDelegate *delegate = [S2AMacDelegate new]; S2APromptBanner *banner = [S2APromptBanner new]; delegate.banner = banner;
    fake_atomic = 0; [delegate pollPrompt]; expect(banner.hidden, "atomic saves do not warn");
    fake_atomic = 2; [delegate pollPrompt]; expect(!banner.hidden, "non-atomic save volume warns");
    puts("Mac save safety: non-atomic save volume shows banner passed");
}
// 审计 P1-59：服务层报局域网发现起不来（S2A_LanState 非 0）时，Mac 窗口给玩家一句说明，只提示一次；为 0 不提示。期望手算
static int fake_lan;
static int fake_lan_state(void) { return fake_lan; }
static void test_lan_warning(void) {
    lan_state = fake_lan_state; lan_warned = NO;
    fake_lan = 0; expect(lan_warning() == nil, "LAN available does not warn");
    fake_lan = 1; NSString *missing = lan_warning();
    expect([missing containsString:@"这台 Mac"] && [missing containsString:@"本地联机"], "missing discovery explains this Mac cannot find other devices");
    expect(lan_warning() == nil, "LAN warning is shown only once");
    lan_warned = NO; fake_lan = 2; NSString *failed = lan_warning();
    expect([failed containsString:@"没能启动"], "start failure says discovery failed to start");
    lan_warned = NO; fake_lan = 3;
    expect([lan_warning() isEqualToString:missing], "missing discovery wins over a later start failure");
    puts("Mac LAN: unavailable discovery warns the player once passed");
}
// 缺口扫描族 1 / 审计 P2-64：Mac 失焦按游戏的失焦暂停开关冻结客机、回焦点放开；收尾路径只报失焦不冻结。期望手算（计数）
static void test_focus_suspend(void) {
    stub_freeze_on = stub_freeze_off = stub_clock3_on = stub_clock3_off = 0; focus_frozen = NO;
    stub_suspend = 1;
    display_focus_publish(NO);
    expect(stub_focus == 0 && stub_freeze_on == 1 && stub_clock3_on == 1, "focus loss with suspend requested freezes guest and clock");
    display_focus_publish(NO);
    expect(stub_freeze_on == 1, "repeated focus loss does not freeze twice");
    display_focus_publish(YES);
    expect(stub_focus == 1 && stub_freeze_off == 1 && stub_clock3_off == 1, "focus regained releases guest and clock");
    stub_suspend = 0;
    display_focus_publish(NO); display_focus_publish(YES);
    expect(stub_freeze_on == 1 && stub_freeze_off == 1 && stub_focus == 1, "game that disabled suspend keeps running when unfocused");
    stub_suspend = 1;
    display_focus_publish_ex(NO, NO);
    expect(stub_focus == 0 && stub_freeze_on == 1, "shutdown publishes focus loss without freezing");
    display_focus_publish(NO); display_focus_publish_ex(NO, NO);
    expect(stub_freeze_on == 2 && stub_freeze_off == 2 && stub_clock3_off == 2, "shutdown releases a focus freeze");
    stub_suspend = 0; display_focus_publish(YES);
    puts("Mac lifecycle: focus loss freezes only when the game asks, regains and shutdown release passed");
}
static void test_untrusted_key_state(void) {   // 审计 P1-57：系统状态误报「已松开」时不丢按住的键，也不永久停掉核对
    config = default_config(); reset_input(); focused = YES;
    read_key_state = key_state;
    memset(physical_keys, 0, sizeof physical_keys);
    S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSZeroRect];
    unsigned short arrows[] = {123, 126, 124, 125};
    for (int i = 0; i < 4; i++) {
        int32_t sticks[4]; uint32_t bit = 1u << (12 + i);
        [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], NO)];   // 系统一直误报松开
        for (int n = 0; n < 1200; n++) { [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], YES)]; poll_input(); }
        expect(s2a_vpad_read(sticks) == bit, "repeats keep a hold through a false released state");
        // 循环最后一下是「重复（计数清零）→ 采样（计数 1）」，再采 KEY_UP_POLLS - 2 次到 KEY_UP_POLLS - 1，差一次不删
        for (int n = 0; n < KEY_UP_POLLS - 2; n++) poll_input();
        expect(s2a_vpad_read(sticks) == bit, "one poll short of the debounce keeps the hold");
        poll_input();
        expect(s2a_vpad_read(sticks) == 0, "sustained released state without repeats drops the key");
        [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], YES)];
        expect(s2a_vpad_read(sticks) == bit, "a later repeat restores a key dropped by polling");
        [view keyUp:key_event(NSEventTypeKeyUp, arrows[i], NO)];
        expect(s2a_vpad_read(sticks) == 0, "keyUp clears the restored key");
        [view keyDown:key_event(NSEventTypeKeyDown, arrows[i], YES)];
        expect(s2a_vpad_read(sticks) == 0, "a late repeat after keyUp stays released");
    }
    // 核对不会被永久关掉：误报之后，真正丢了 keyUp 的键仍按采样收回
    int32_t sticks[4]; physical_keys[14] = YES;
    [view keyDown:key_event(NSEventTypeKeyDown, 14, NO)];
    physical_keys[14] = NO; poll_stale();
    expect(s2a_vpad_read(sticks) == 0, "polling still recovers a lost keyUp after earlier mismatches");
    reset_input();
    puts("Mac keyboard: false released state keeps holds, repeat restores, polling stays on passed");
}
// 审计 P1-34：修饰键只走 flagsChanged、没有自动重复可恢复；系统按键重复关掉时普通键同理。
//   采样连续误报松开满防抖被删后，系统恢复报按下就加回（含修饰位）；真正的松开照旧清；本视图没收到过的按下不从系统状态新增。期望手算（缺省映射 Shift=B 位 1、Control=LS 位 4、←=LEFT 位 12）
static NSEvent *flags_event(unsigned short code, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
}
static void test_modifier_false_release(void) {
    config = default_config(); reset_input(); focused = YES;
    read_key_state = key_state;
    memset(physical_keys, 0, sizeof physical_keys);
    S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSZeroRect];
    int32_t sticks[4];
    physical_keys[56] = YES;
    [view flagsChanged:flags_event(56, NSEventModifierFlagShift)];
    expect(s2a_vpad_read(sticks) == (1u << 1) && modifiers == 1, "shift press maps to B");
    physical_keys[56] = NO; poll_stale();
    expect(s2a_vpad_read(sticks) == 0 && modifiers == 0, "sustained false release drops shift");
    physical_keys[56] = YES; poll_input();
    expect(s2a_vpad_read(sticks) == (1u << 1) && modifiers == 1, "system reporting shift held again restores it");
    physical_keys[56] = NO; [view flagsChanged:flags_event(56, 0)];
    expect(s2a_vpad_read(sticks) == 0 && modifiers == 0 && !stale_keys.count, "real flagsChanged release clears shift");
    physical_keys[56] = YES; poll_stale();
    expect(s2a_vpad_read(sticks) == 0 && modifiers == 0, "a press this view never received is not added from system state");
    physical_keys[56] = NO;

    physical_keys[62] = YES;
    [view flagsChanged:flags_event(62, NSEventModifierFlagControl)];
    expect(s2a_vpad_read(sticks) == (1u << 4) && modifiers == 2, "right control maps to canonical LS");
    physical_keys[62] = NO; poll_stale();
    expect(s2a_vpad_read(sticks) == 0 && [stale_keys containsObject:@59], "false release drops right control");
    physical_keys[62] = YES; [view flagsChanged:flags_event(62, NSEventModifierFlagControl)];
    expect(s2a_vpad_read(sticks) == (1u << 4) && ![stale_keys containsObject:@59] && !key_up_polls[@59].intValue, "fresh modifier press clears the stale record");
    physical_keys[62] = NO; [view flagsChanged:flags_event(62, 0)];
    expect(s2a_vpad_read(sticks) == 0 && !keys.count && !stale_keys.count, "right control release clears everything");

    physical_keys[123] = YES;
    [view keyDown:key_event(NSEventTypeKeyDown, 123, NO)];
    physical_keys[123] = NO; poll_stale();
    expect(s2a_vpad_read(sticks) == 0, "ordinary key dropped by a false release");
    physical_keys[123] = YES; poll_input();
    expect(s2a_vpad_read(sticks) == (1u << 12), "ordinary key restores without auto-repeat when system reports it held");
    physical_keys[123] = NO; [view keyUp:key_event(NSEventTypeKeyUp, 123, NO)];
    reset_input();
    puts("Mac keyboard: modifiers and non-repeating keys survive a false released state passed");
}
// 审计 P2-34：鼠标按下只在 mouseUp 删除，松开被别处吃掉时一直按着。现在按系统当前按下的鼠标键核对，与键盘同一套防抖与恢复。
//   期望手算（缺省映射 右键 = ZL 位 8）
static NSUInteger fake_mouse_buttons;
// NSEvent 的 mouseEventWithType 造出的右键按钮号是 0；经 CGEvent 造才带真实按钮号 1
static NSEvent *right_mouse_event(CGEventType type) {
    CGEventRef cg = CGEventCreateMouseEvent(NULL, type, CGPointZero, kCGMouseButtonRight);
    NSEvent *e = [NSEvent eventWithCGEvent:cg]; CFRelease(cg); return e;
}
static NSUInteger mouse_buttons_state(void) { return fake_mouse_buttons; }
// R5：键盘区原始键态（HID usage 位图 + 修饰键字段；服务层 InputPump 照 s2a_kb_read 这份写键盘区共享内存）。
//   键码表对拍：W=13→0x1A、F5=96→0x3E、Esc=53→0x29、小键盘Enter=76→0x58、Z=6→0x1D；修饰键 shift 56→0xE1、
//   ctrl 59→0xE0、option 58→0xE2（0xE0–0xE2 落在位图第 4 个 64 位段）+ 字段位（Shift=2、Control=1、LeftAlt=4）；
//   CapsLock 只走 flagsChanged（位图 0x39 + 字段 bit8）；失焦发全零、按住的键不丢；keyUp 清位；粘键核对删键跟着清；复位全清
static void test_keyboard_hid(void) {
    config = default_config(); reset_input(); focused = YES;
    read_key_state = key_state; memset(physical_keys, 0, sizeof physical_keys);
    uint64_t k[4]; uint32_t m;
    s2a_kb_read(k, &m);
    expect(k[0] == 0 && k[1] == 0 && k[2] == 0 && k[3] == 0 && m == 0, "keyboard bitmap starts empty");
    S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSZeroRect];
    [view keyDown:key_event(NSEventTypeKeyDown, 13, NO)];   // W
    s2a_kb_read(k, &m);
    expect(k[0] == (1UL << 0x1A) && !k[1] && !k[2] && !k[3] && m == 0, "W lands on its HID usage bit");
    [view keyDown:key_event(NSEventTypeKeyDown, 96, NO)];   // F5
    s2a_kb_read(k, &m);
    expect((k[0] & (1UL << 0x3E)) && (k[0] & (1UL << 0x1A)), "F5 lands beside W");
    [view keyDown:key_event(NSEventTypeKeyDown, 76, NO)];   // 小键盘 Enter
    s2a_kb_read(k, &m);
    expect((k[1] & (1UL << (0x58 - 64))) && (k[0] & (1UL << 0x3E)), "keypad Enter lands on usage 0x58");
    [view keyUp:key_event(NSEventTypeKeyUp, 13, NO)];
    s2a_kb_read(k, &m);
    expect(!(k[0] & (1UL << 0x1A)) && (k[0] & (1UL << 0x3E)), "keyUp clears only its own bit");
    [view keyDown:key_event(NSEventTypeKeyDown, 53, NO)];   // Esc（窗口非全屏、没锁鼠标：照常进键盘区）
    s2a_kb_read(k, &m);
    expect((k[0] & (1UL << 0x29)) != 0, "Esc lands on usage 0x29");   // 位号 ≥ 32 的单项判空要显式 != 0：int 截断会把高位清零
    [view flagsChanged:flags_event(56, NSEventModifierFlagShift)];
    s2a_kb_read(k, &m);
    expect((k[3] & (1UL << (0xE1 & 63))) && m == (1u << 1), "shift lands on usage 0xE1 and the Shift field bit");
    // flagsChanged 的 modifierFlags 反映全量状态（与真机一致），合成事件按累积传
    [view flagsChanged:flags_event(59, NSEventModifierFlagShift | NSEventModifierFlagControl)];
    [view flagsChanged:flags_event(58, NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption)];
    s2a_kb_read(k, &m);
    expect((k[3] & (1UL << (0xE0 & 63))) && (k[3] & (1UL << (0xE2 & 63))) && m == ((1u << 1) | 1u | (1u << 2)),
           "control and option land with their usages and field bits");
    [view flagsChanged:flags_event(56, NSEventModifierFlagControl | NSEventModifierFlagOption)];   // 松 shift：其余还在
    [view flagsChanged:flags_event(59, NSEventModifierFlagOption)];
    [view flagsChanged:flags_event(58, 0)];
    s2a_kb_read(k, &m);
    expect(!(k[3] & (7UL << 32)) && m == 0, "releasing modifiers clears bitmap and field");
    [view flagsChanged:flags_event(57, NSEventModifierFlagCapsLock)];
    s2a_kb_read(k, &m);
    expect((k[0] & (1UL << 0x39)) && m == (1u << 8), "CapsLock lands on usage 0x39 and the CapsLock field bit");
    [view flagsChanged:flags_event(57, 0)];
    s2a_kb_read(k, &m);
    expect(!(k[0] & (1UL << 0x39)) && m == 0, "CapsLock release clears both");
    focused = NO; sample_input();
    s2a_kb_read(k, &m);
    expect(!k[0] && !k[1] && !k[2] && !k[3] && m == 0, "unfocused publishes an all-zero bitmap");
    focused = YES; sample_input();
    s2a_kb_read(k, &m);
    expect((k[0] & (1UL << 0x29)) && (k[1] & (1UL << (0x58 - 64))), "refocus re-publishes held keys, like pads");
    [view keyDown:key_event(NSEventTypeKeyDown, 6, NO)];   // Z
    physical_keys[6] = YES;   // 粘键核对的 is_down 桩：Z 还按着，先不清
    poll_stale();
    s2a_kb_read(k, &m);
    expect((k[0] & (1UL << 0x1D)), "Z lands on usage 0x1D while the system still reports it held");
    physical_keys[6] = NO; poll_stale();   // 系统报松开满防抖次数 → 删键（keyUp 被别的响应者吃掉的兜底），位图跟着清
    s2a_kb_read(k, &m);
    expect(!(k[0] & (1UL << 0x1D)), "stale-key reconciliation clears the bitmap without a keyUp");
    reset_input();
    s2a_kb_read(k, &m);
    expect(!k[0] && !k[1] && !k[2] && !k[3] && m == 0, "reset clears the keyboard bitmap");
    puts("Mac keyboard: HID usage bitmap, modifiers, caps, focus and reconciliation passed");
}
static void test_mouse_lost_release(void) {
    config = default_config(); reset_input(); focused = YES;
    read_key_state = key_state; read_mouse_buttons = mouse_buttons_state;
    memset(physical_keys, 0, sizeof physical_keys);
    S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSZeroRect];
    NSEvent *down = right_mouse_event(kCGEventRightMouseDown), *up = right_mouse_event(kCGEventRightMouseUp);
    int32_t sticks[4];
    fake_mouse_buttons = 1u << 1;
    [view rightMouseDown:down];
    for (int n = 0; n < 1200; n++) poll_input();
    expect(s2a_vpad_read(sticks) == (1u << 8), "held right button survives polling");
    fake_mouse_buttons = 0;
    for (int n = 0; n < KEY_UP_POLLS - 1; n++) poll_input();
    expect(s2a_vpad_read(sticks) == (1u << 8), "one poll short of the debounce keeps the button");
    poll_input();
    expect(s2a_vpad_read(sticks) == 0, "lost mouseUp is released by polling");
    fake_mouse_buttons = 1u << 1; poll_input();
    expect(s2a_vpad_read(sticks) == (1u << 8), "system reporting the button held again restores it");
    fake_mouse_buttons = 0; [view rightMouseUp:up];
    expect(s2a_vpad_read(sticks) == 0 && !stale_mouse.count && !mouse_up_polls.count, "real mouseUp clears the button");
    fake_mouse_buttons = 1u << 1; for (int n = 0; n < KEY_UP_POLLS; n++) poll_input();
    expect(s2a_vpad_read(sticks) == 0, "a click this view never received is not added from system state");
    fake_mouse_buttons = 0;
    reset_input();
    puts("Mac mouse: lost mouseUp released by polling, false release restores passed");
}
static void inspect_guide(NSView *view, int *buttons, int *editors) {
    if ([view isKindOfClass:S2AControllerButton.class]) (*buttons)++;
    if ([view isKindOfClass:NSTextField.class] && [(NSTextField *)view isEditable]) (*editors)++;
    if ([view isKindOfClass:NSPopUpButton.class]) (*editors)++;
    for (NSView *child in view.subviews) inspect_guide(child, buttons, editors);
}
static BOOL guide_has_label(NSView *view, NSString *value) {
    if ([view isKindOfClass:NSTextField.class] && [[(NSTextField *)view stringValue] isEqual:value]) return YES;
    for (NSView *child in view.subviews) if (guide_has_label(child, value)) return YES;
    return NO;
}
static void *read_snapshots(void *arg) {
    (void)arg;
    for (int i = 0; i < 100000; i++) {
        int32_t s[4]; uint32_t b = s2a_vpad_read(s);
        if (s[0] != (int32_t)b || s[1] != (int32_t)b || s[2] != (int32_t)b || s[3] != (int32_t)b) return (void *)1;
    }
    return NULL;
}
// Event payload only: the adapter's real mouseMoved/sample/read path is exercised.
@interface TestMotion : NSObject
@property double deltaX, deltaY;
@end
@implementation TestMotion
@end

static CGError association_error;
static int association_calls, cursor_hides, cursor_shows;
static boolean_t association_connected;
static CGError test_associate(boolean_t connected) {
    association_calls++; association_connected = connected; return association_error;
}
static void test_cursor_visibility(BOOL visible) { if (visible) cursor_shows++; else cursor_hides++; }
static NSEvent *capture_key_event(NSEventType type, unsigned short code, BOOL repeat) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:0
        windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:repeat keyCode:code];
}
static void test_capture_held_key(BOOL system_state_matches) {
    config = default_config(); reset_input(); focused = YES;
    physical_keys[13] = system_state_matches;
    S2AMetalView *view = [S2AMetalView new];
    S2AMacDelegate *delegate = [S2AMacDelegate new];
    int32_t sticks[4];
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:2 clickCount:1 pressure:0];
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 13, NO)];
    expect(s2a_vpad_read(sticks) == 0 && sticks[1] == 32767, "W held before capture");
    for (int capture = 0; capture < 2; capture++) {
        [view mouseDown:click];
        expect(mouse_captured && s2a_vpad_read(sticks) == 0 && sticks[1] == 32767,
               "capture preserves held W and first click never sends Y");
        [view mouseUp:up];
        for (int n = 0; n < 1200; n++) {
            [view keyDown:capture_key_event(NSEventTypeKeyDown, 13, YES)]; poll_input();
        }
        expect(s2a_vpad_read(sticks) == 0 && sticks[1] == 32767,
               "held W survives capture and repeated keyDown/poll cycles");
        [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)];
        expect(!mouse_captured && s2a_vpad_read(sticks) == 0 && sticks[1] == 32767,
               "Esc releases mouse without clearing held W");
        [view keyUp:capture_key_event(NSEventTypeKeyUp, 53, NO)];
    }
    [view mouseDown:click]; [view mouseUp:up];
    association_error = kCGErrorFailure;
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)];
    expect(!mouse_captured && mouse_release_pending && s2a_vpad_read(sticks) == 0 && sticks[1] == 32767,
           "failed mouse release preserves held W while waiting for retry");
    association_error = kCGErrorSuccess;
    [view mouseDown:click]; [view mouseUp:up];
    expect(mouse_captured && !mouse_release_pending && s2a_vpad_read(sticks) == 0 && sticks[1] == 32767,
           "release retry and recapture preserve W without sending Y");
    [delegate windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:nil]];
    expect(!mouse_captured && keys.count == 0 && s2a_vpad_read(sticks) == 0 && !sticks[1],
           "focus loss releases capture and clears held W");
    [delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:nil]];
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 13, YES)]; poll_input();
    expect(s2a_vpad_read(sticks) == 0 && !sticks[1], "repeat after focus loss cannot restore W");
    physical_keys[13] = NO;
    [view keyUp:capture_key_event(NSEventTypeKeyUp, 13, NO)];
    reset_input();
    puts("Mac mouse: held W across capture/Esc/recapture, first-click Y isolation and focus passed");
}

// 全屏 Esc（玩家反馈进了全屏回不到窗口）：期望按规则手写——Esc 没映射：全屏下按一次就退全屏（鼠标锁着一并释放），不发游戏键；不是全屏不退；
//   Esc 映射了 PLUS：短按照常发 PLUS、1 秒内松开不退；按住满 1 秒退全屏一次、PLUS 随之松开
static BOOL fake_fullscreen; static int fake_toggles;
static BOOL fake_window_fullscreen(NSWindow *w) { (void)w; return fake_fullscreen; }
static void fake_fullscreen_toggle(NSWindow *w) { (void)w; fake_toggles++; fake_fullscreen = !fake_fullscreen; }
static void run_loop_for(double seconds) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }
static void test_fullscreen_esc(void) {
    window_fullscreen = fake_window_fullscreen; fullscreen_toggle = fake_fullscreen_toggle;
    S2AMetalView *view = [S2AMetalView new]; int32_t sticks[4];
    config = default_config(); reset_input(); focused = YES;
    expect(!esc_mapped(), "default keyboard leaves Esc unmapped");
    fake_fullscreen = NO; fake_toggles = 0;
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)]; [view keyUp:capture_key_event(NSEventTypeKeyUp, 53, NO)];
    expect(fake_toggles == 0, "windowed Esc does not toggle full screen");
    fake_fullscreen = YES; config = @{@"keyboard": @{@"A": @{@"code": @14}}, @"mouse": @{}, @"gamepad": @{}, @"axes": @{}, @"deadzone": @0.15, @"mouseOptions": @{@"mode": @"camera"}};
    set_mouse_capture(YES);
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)];
    expect(fake_toggles == 1 && !fake_fullscreen && !mouse_captured && s2a_vpad_read(sticks) == 0, "unmapped Esc leaves full screen at once and releases the mouse");
    [view keyUp:capture_key_event(NSEventTypeKeyUp, 53, NO)];
    config = @{@"keyboard": @{@"PLUS": @{@"code": @53}}, @"mouse": @{}, @"gamepad": @{}, @"axes": @{}, @"deadzone": @0.15, @"mouseOptions": @{@"mode": @"camera"}};
    reset_input(); fake_fullscreen = YES; fake_toggles = 0;
    physical_keys[53] = YES; [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)];
    expect(s2a_vpad_read(sticks) == (1u << 10) && fake_toggles == 0, "mapped Esc short press sends PLUS and stays full screen");
    run_loop_for(0.4); physical_keys[53] = NO; [view keyUp:capture_key_event(NSEventTypeKeyUp, 53, NO)];
    run_loop_for(0.9);
    expect(fake_toggles == 0 && fake_fullscreen && s2a_vpad_read(sticks) == 0, "released before 1 s: no full-screen change");
    physical_keys[53] = YES; [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)];
    run_loop_for(1.2);
    expect(fake_toggles == 1 && !fake_fullscreen && s2a_vpad_read(sticks) == 0, "mapped Esc held 1 s leaves full screen once and releases PLUS");
    physical_keys[53] = NO; [view keyUp:capture_key_event(NSEventTypeKeyUp, 53, NO)];
    window_fullscreen = window_fullscreen_now; fullscreen_toggle = window_fullscreen_toggle;
    reset_input(); config = default_config();
    puts("Mac full screen: Esc exits when unmapped, short press to game / hold 1 s exits when mapped");
}
static void test_capture_key_order(void) {
    config = @{@"keyboard": @{@"PLUS": @{@"code": @53}, @"A": @{@"code": @14}},
               @"mouse": @{}, @"gamepad": @{}, @"axes": @{}, @"deadzone": @0.15,
               @"mouseOptions": @{@"mode": @"camera"}};
    reset_input(); focused = YES;
    S2AMetalView *view = [S2AMetalView new]; int32_t sticks[4];
    set_mouse_capture(YES);
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)];
    expect(!mouse_captured && s2a_vpad_read(sticks) == 0, "captured Esc only releases, never sends mapped PLUS");
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, YES)];
    expect(s2a_vpad_read(sticks) == 0, "held Esc repeat after release cannot send mapped PLUS");
    [view keyUp:capture_key_event(NSEventTypeKeyUp, 53, NO)];
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, NO)];
    expect(s2a_vpad_read(sticks) == (1u << 10), "fresh uncaptured Esc sends mapped PLUS");
    [view keyUp:capture_key_event(NSEventTypeKeyUp, 53, NO)];
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 14, NO)];
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 14, YES)];
    expect(s2a_vpad_read(sticks) == 1, "repeat preserves an already held game button");
    [view keyUp:capture_key_event(NSEventTypeKeyUp, 14, NO)];
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 14, YES)];
    expect(s2a_vpad_read(sticks) == 0, "late repeat cannot restore a released game button");
    set_mouse_capture(YES); focused = NO; // Defensive release must precede both keyDown filters.
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 53, YES)];
    expect(!mouse_captured && !mouse_release_pending, "Esc release precedes unfocused and repeat rejection");
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 14, NO)];
    [view keyDown:capture_key_event(NSEventTypeKeyDown, 14, YES)];
    focused = YES; sample_input();
    expect(s2a_vpad_read(sticks) == 0, "unfocused events cannot reappear on focus return");
    reset_input(); config = default_config();
    puts("Mac mouse: Esc mapping, release ordering, repeat and focus regression passed");
}

// 审计 P2-63：多个控制器时取最近有输入的扩展手柄；没有扩展手柄档的（遥控器等）跳过。假对象只答 active_pad 用到的两个方法
@interface FakePad : NSObject
@property double lastEventTimestamp;
@property(copy) void (^valueChangedHandler)(GCExtendedGamepad *, GCControllerElement *);
@end
@implementation FakePad
@end
@interface FakeController : NSObject
@property(strong) FakePad *extendedGamepad;
@property(strong) dispatch_queue_t handlerQueue;
@end
@implementation FakeController
@end
static FakeController *fake_controller(FakePad *pad) { FakeController *c = [FakeController new]; c.extendedGamepad = pad; return c; }
static void test_active_pad(void) {
    FakePad *old = [FakePad new], *recent = [FakePad new]; old.lastEventTimestamp = 10; recent.lastEventTimestamp = 20;
    NSArray *list = @[fake_controller(nil), fake_controller(old), fake_controller(recent)];
    expect((id)active_pad(list) == recent, "picks the extended gamepad with the latest input, skipping a remote first in the list");
    old.lastEventTimestamp = 30;
    expect((id)active_pad(list) == old, "switches when the other pad gets newer input");
    expect(active_pad(@[fake_controller(nil)]) == nil && active_pad(@[]) == nil, "no extended gamepad: none");
}

// A2 事件驱动输入：Mac 导出 s2a_vpad_read_ex，sample_input 同步写 runtime/src/pad.c，InputPump 才能从 Sleep(16)
//   换成 s2a_pad_wait。期望手算：keyDown 后 read_ex 立即看到 A 位并带 host 时间戳；keyUp 在 50ms deadline 前唤醒等待线程
//   （旧实现没有 pad 通知，等待只能跑满 deadline）。
static void test_event_input(void) {
    typedef void (*read_ex_fn)(s2a_pad_snapshot *);
    read_ex_fn read_ex = (read_ex_fn)dlsym(RTLD_DEFAULT, "s2a_vpad_read_ex");
    expect(read_ex != NULL, "Mac exports s2a_vpad_read_ex");
    config = default_config(); reset_input(); focused = YES;
    s2a_pad_set_active(1);
    S2AMetalView *view = [S2AMetalView new];
    [view keyDown:key_event(NSEventTypeKeyDown, 14, NO)];   // 缺省映射 E = Switch A（位 0）
    s2a_pad_snapshot down; read_ex(&down);
    expect((down.buttons & 1u) != 0 && down.host_timestamp_us != 0, "event snapshot carries the key and its host timestamp");
    { s2a_pad_latency clear; s2a_pad_get_latency(&clear, 1); }   // 清掉前面用例留下的样本，下面只看这一次提交
    uint64_t before_commit = s2a_pad_now_us();
    s2a_pad_record_commit(&down);
    uint64_t after_commit = s2a_pad_now_us();

    uint64_t observed;
    { s2a_pad_snapshot snap; read_ex(&snap); observed = snap.notification_seq; }
    __block int woke = -1;
    dispatch_semaphore_t started = dispatch_semaphore_create(0), done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_wait(started, DISPATCH_TIME_FOREVER);
        woke = s2a_pad_wait(observed, s2a_pad_now_us() + 5000000);   // 截止放到 5 秒：判它为什么返回，不判用了多久（不受机器负载影响）
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_signal(started);
    [NSThread sleepForTimeInterval:0.02];   // 让等待线程先进入条件变量；即使没进，序号变化也会让它立即返回
    [view keyUp:key_event(NSEventTypeKeyUp, 14, NO)];
    expect(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0, "pad wait completes after key up");
    expect(woke == 1, "key up wakes pad wait because the notification sequence changed, not because the deadline passed");

    // 延迟 = 提交时刻 − 按键的 host 时间戳：提交前后各取一次时钟，记下的值必须夹在两者之间（只依赖时间戳之差，不设绝对上限）
    s2a_pad_latency latency; s2a_pad_get_latency(&latency, 1);
    expect(latency.samples == 1 && latency.host_total_us == latency.host_max_us &&
           latency.host_max_us >= before_commit - down.host_timestamp_us && latency.host_max_us <= after_commit - down.host_timestamp_us,
           "committed event latency equals commit time minus the key's host timestamp");

    // 负对照（维护者要求）：事件驱动只发变化；长按 / 摇杆持续推时，没有新事件的那几拍 read_ex 仍必须返回完整的按住状态。
    [keys addObject:@14]; [keys addObject:@13]; sample_input();   // E = A，W = LS_UP
    uint64_t held_seq;
    { s2a_pad_snapshot snap; read_ex(&snap); held_seq = snap.notification_seq; }
    expect(s2a_pad_wait(held_seq, s2a_pad_now_us() + 20000) == 0, "idle wait times out without new events");
    for (int i = 0; i < 5; i++) {
        s2a_pad_snapshot held; read_ex(&held);
        expect((held.buttons & 1u) != 0 && held.axes[1] == 32767, "held key and stick persist across idle reads");
    }
    [keys removeObject:@14]; [keys removeObject:@13]; sample_input();

    // 鼠标位移仍由 HID 读取侧消费一次（旧 s2a_vpad_read 与 read_ex 共用）
    config = @{@"keyboard": @{}, @"mouse": @{}, @"gamepad": @{}, @"axes": @{}, @"deadzone": @0.15,
               @"mouseOptions": @{@"mode": @"camera", @"sensitivityX": @1, @"sensitivityY": @1}};
    apply_mouse_options(); mouse_captured = YES; focused = YES;
    TestMotion *motion = [TestMotion new]; motion.deltaX = 2;
    S2AMetalView *motionView = [S2AMetalView new];
    [motionView mouseMoved:(NSEvent *)motion];
    s2a_pad_snapshot moved; read_ex(&moved);
    expect(moved.axes[2] == 3000, "read_ex applies pending mouse delta once");
    read_ex(&moved);
    expect(moved.axes[2] == 0, "read_ex consumes the mouse delta");
    mouse_captured = NO;
    config = default_config(); focused = YES; s2a_pad_set_active(0); reset_input();
    puts("Mac input: event-driven snapshot, wait wake, idle-hold persistence and latency recording passed");
}

// 维护方评审 11-09：手柄断开时前端切到 TOUCH 源，但 pad.c 里 SYSTEM 源一直 connected，selected() 仍选 SYSTEM
//   并丢掉 TOUCH 更新，断开瞬间按住的键卡住、键盘失灵。期望手算：SYSTEM 按 A（0x1）→ 断开后键盘按 B（0x2）→
//   快照 source = TOUCH、buttons = 0x2。负对照：去掉 publish_pad_state 里的 SYSTEM 断开 → 快照仍是 SYSTEM / 0x1。
static void test_pad_disconnect(void) {
    typedef void (*read_ex_fn)(s2a_pad_snapshot *);
    read_ex_fn read_ex = (read_ex_fn)dlsym(RTLD_DEFAULT, "s2a_vpad_read_ex");
    expect(read_ex != NULL, "Mac exports s2a_vpad_read_ex");
    int32_t sticks[4] = {0};
    focused = YES; s2a_pad_set_active(0); s2a_pad_set_active(1);
    publish_pad_state(1, 1u, sticks);
    s2a_pad_snapshot snap; read_ex(&snap);
    expect(snap.source == S2A_PAD_SYSTEM && snap.buttons == 1u, "gamepad press is selected on SYSTEM source");
    publish_pad_state(0, 1u << 1, sticks);
    read_ex(&snap);
    expect(snap.source == S2A_PAD_TOUCH && snap.buttons == (1u << 1), "keyboard still works after gamepad disconnect");
    expect(!s2a_pad_has_controller(), "disconnected gamepad is no longer the selected controller");
    s2a_pad_set_active(0); reset_input();
    puts("Mac pad: disconnect returns to touch source and keeps keyboard input passed");
}

// 本地多手柄槽位（s2a_slot_plan 是纯逻辑，用假身份指针测，不碰 GameController）：
//   按连接顺序占槽、断开清槽（槽位不压实，玩家号不跳）、重连回原槽、超过 4 只的第 5 只丢弃。
//   apply_slots 与 sample_input 的写回同构：整表重建，只有本轮还在的才写回。
static void apply_slots(const void **owners, const void *const *live, const int *slot_of, int count, int max) {
    for (int i = 0; i < max; i++) owners[i] = NULL;
    for (int j = 0; j < count; j++) if (slot_of[j] >= 0) owners[slot_of[j]] = live[j];
}
static void test_pad_slots(void) {
    int ids[5] = {1, 2, 3, 4, 5};
    const void *a = &ids[0], *b = &ids[1], *c = &ids[2], *d = &ids[3], *e = &ids[4];
    const void *owners[4] = {NULL, NULL, NULL, NULL};
    const void *live[5]; int slot_of[5];

    live[0] = a;
    expect(s2a_slot_plan(owners, live, 1, 4, slot_of) == 1 && slot_of[0] == 0, "one pad takes slot 0 and reports one pad");
    apply_slots(owners, live, slot_of, 1, 4);

    live[1] = b;
    expect(s2a_slot_plan(owners, live, 2, 4, slot_of) == 2 && slot_of[0] == 0 && slot_of[1] == 1,
        "second pad joins after the first in connection order");
    apply_slots(owners, live, slot_of, 2, 4);

    live[2] = c;
    expect(s2a_slot_plan(owners, live, 3, 4, slot_of) == 3 && slot_of[2] == 2, "third pad takes slot 2");
    apply_slots(owners, live, slot_of, 3, 4);

    // 第一只断开：槽 0 空出来，第二、三只留在原槽（不压实，玩家号不跳）
    expect(s2a_slot_plan(owners, live + 1, 2, 4, slot_of) == 3 && slot_of[0] == 1 && slot_of[1] == 2,
        "unplugging the first clears slot 0 and leaves the others where they were");
    apply_slots(owners, live + 1, slot_of, 2, 4);

    // 重连回原槽：中间没插别的，第一只回到槽 0
    expect(s2a_slot_plan(owners, live, 3, 4, slot_of) == 3 && slot_of[0] == 0,
        "a pad that comes back reclaims its original slot");
    apply_slots(owners, live, slot_of, 3, 4);

    // 第一只又断开、新的第四只接上：占最小空槽（槽 0），不是追加到末尾
    const void *bcd[3] = {b, c, d};
    expect(s2a_slot_plan(owners, bcd, 3, 4, slot_of) == 3 && slot_of[0] == 1 && slot_of[1] == 2 && slot_of[2] == 0,
        "a new pad takes the lowest free slot");
    apply_slots(owners, bcd, slot_of, 3, 4);

    // 超过 4 只：第五只 -1，不参与
    const void *five[5] = {a, b, c, d, e};
    expect(s2a_slot_plan(owners, five, 5, 4, slot_of) == 4 && slot_of[4] == -1, "a fifth pad is ignored");
    // 全断开：回到只有槽 0（键盘 / 鼠标）的那一位
    expect(s2a_slot_plan(owners, live, 0, 4, slot_of) == 1, "no pads: back to one slot for keyboard and mouse");
}

// 只有通用物理描述的手柄（没有扩展手柄档）：按标准键名从 physicalInputProfile 读、回调装在 valueDidChangeHandler 上。
//   用系统自带的虚拟简易手柄（controllerWithMicroGamepad：只有 A / X / Menu / 方向键）当这种手柄。期望手算：
//   它的类别是「Siri Remote」，认不出类型按缺省「自动」照字母（pad.c s2a_pad_abxy_order）：系统 A = Switch A，默认配置第 0 位（1）；
//   方向键上是第 13 位（8192）；没按任何键是 0
static void test_profile_only_pad(void) {
    config = default_config();
    GCController *c = [GCController controllerWithMicroGamepad];
    expect(c.extendedGamepad == nil && pad_has_profile_buttons(c), "micro-only controller counts as a profile-only pad");
    install_pad_handler(c);
    expect(c.physicalInputProfile.valueDidChangeHandler != nil && c.handlerQueue != nil && c.handlerQueue != dispatch_get_main_queue(), "profile handler installed on the dedicated pad queue");
    uint32_t buttons = 99; int32_t sticks[4];
    sample_profile_state(c, &buttons, sticks);
    expect(buttons == 0, "nothing pressed: no buttons");
    [c.microGamepad.buttonA setValue:1];
    sample_profile_state(c, &buttons, sticks);
    expect(buttons == 1, "unrecognized pad, automatic layout: profile button A maps to Switch A by its letter");
    s2a_pad_layout_set(S2A_PAD_LAYOUT_SWITCH); sample_profile_state(c, &buttons, sticks);
    expect(buttons == 2, "Switch layout: profile button A (south) maps to Switch B by position");
    s2a_pad_layout_set(S2A_PAD_LAYOUT_AUTO);
    [c.microGamepad.buttonA setValue:0]; [c.microGamepad.dpad setValueForXAxis:0 yAxis:1];
    sample_profile_state(c, &buttons, sticks);
    expect(buttons == (1u << 13), "profile dpad up maps to Switch Up");
    puts("Mac profile-only pad: handler and standard-name reading passed");
}

// 手柄按键布局（11-11）：系统自带的虚拟扩展手柄（controllerWithExtendedGamepad，类别认不出 = 按 Xbox / MFi 那种排法：buttonA 在南、Y 在北）。
//   期望手算（默认配置 东/南/北/西 = Switch A/B/X/Y = 第 0/1/2/3 位）：
//   自动 / Xbox 布局：照字母，按 buttonA → Switch A（1）、按 buttonY → Switch Y（8）；
//   Switch 布局：按位置，buttonA 在南 → Switch B（2）、buttonY 在北 → Switch X（4）；切换后下一次读即按新布局，不用重开
static void test_pad_layout(void) {
    config = default_config();
    GCController *c = [GCController controllerWithExtendedGamepad];
    GCExtendedGamepad *pad = c.extendedGamepad;
    uint32_t buttons; int32_t sticks[4];
    int layouts[3] = {S2A_PAD_LAYOUT_AUTO, S2A_PAD_LAYOUT_SWITCH, S2A_PAD_LAYOUT_XBOX};
    uint32_t want_a[3] = {1, 2, 1}, want_y[3] = {8, 4, 8};
    for (int i = 0; i < 3; i++) {
        s2a_pad_layout_set(layouts[i]);
        [pad.buttonA setValue:1]; sample_pad_state(pad, &buttons, sticks);
        expect(buttons == want_a[i], "pad layout: button A lands on the expected Switch button");
        [pad.buttonA setValue:0]; [pad.buttonY setValue:1]; sample_pad_state(pad, &buttons, sticks);
        expect(buttons == want_y[i], "pad layout: button Y lands on the expected Switch button");
        [pad.buttonY setValue:0];
    }
    s2a_pad_layout_set(S2A_PAD_LAYOUT_AUTO);
    puts("Mac pad layout: automatic / Switch / Xbox take effect on the next read passed");
}

// 手柄事件回调（A2）：handlerQueue 挂专用串行队列、不再挂主队列（主线程被菜单动画 / 提示条占住时手柄事件不再排队，见 test_pad_fast_path）；
//   没占到槽的回调直接跳过（快速路径不碰没排进槽位表的手柄），没有新事件时 120Hz 定时器仍是回退采样，长按不会因为「只发变化」而丢。
static void test_pad_handler_install(void) {
    FakePad *pad = [FakePad new];
    FakeController *controller = fake_controller(pad);
    install_pad_handler((GCController *)controller);
    expect(controller.handlerQueue != nil && controller.handlerQueue != dispatch_get_main_queue(), "pad handler runs on a dedicated serial queue, not the main queue");
    expect(pad.valueChangedHandler != nil, "gamepad valueChangedHandler installed");
    config = default_config(); keys = [NSMutableSet set]; mouse = [NSMutableSet set]; focused = YES;
    read_key_state = key_state; memset(physical_keys, 0, sizeof physical_keys); physical_keys[14] = YES;
    int32_t sticks[4];
    [keys addObject:@14]; sample_input();
    expect(s2a_vpad_read(sticks) == 1, "120Hz fallback publishes a held state without a callback");
    pad.valueChangedHandler((GCExtendedGamepad *)pad, nil);   // 没占到槽（FakeController 不在系统列表里）：快速路径跳过，不发布也不崩
    expect(s2a_vpad_read(sticks) == 1, "unslotted callback is a no-op");
    [keys removeObject:@14]; sample_input();
    expect(s2a_vpad_read(sticks) == 0, "release is visible after a sample");
    [keys addObject:@14]; poll_input();
    expect(s2a_vpad_read(sticks) == 1, "120Hz fallback publishes a held state without a callback");
    for (int i = 0; i < 120; i++) { poll_input(); pad.valueChangedHandler((GCExtendedGamepad *)pad, nil); }
    expect(s2a_vpad_read(sticks) == 1, "held state persists across the 120Hz fallback and no-op callbacks");
    physical_keys[14] = NO;
    reset_input();
    puts("Mac pad: handler installs on a dedicated queue and 120Hz fallback keeps held state passed");
}

// 手柄快速路径（延迟管线调研·输入：GCController 权衡解除）。期望手算（缺省映射：手柄 A=东=位 0、B=南=位 1；键盘 Shift=B 位 1；E=A 位 0）：
//   ① 回调队列离开主队列（改前：主队列，红）；
//   ② 快速路径合成槽 0：键盘快照（位 1）+ 手柄 A（位 0）一起发布 = 3；松手后只剩键盘位（回调读当前整份状态，不是只发变化）；
//   ③ 主线程忙 300ms 不进 runloop（等效菜单动画 / 提示条占住主线程），事件经 handlerQueue 投递，
//      后台 s2a_pad_wait 截止 200ms 必须被唤醒（改前：回调排主队列、等主线程空下来才发 → 超时，红）；
//   ④ 玩家 2（槽 1）事件只写自己的槽位原子量并唤醒泵（改前：sample_input 采不到不在系统列表里的虚拟手柄 → 槽 1 恒 0，红）；
//   ⑤ 失焦静音：快速路径发零。
//   系统虚拟手柄（controllerWithExtendedGamepad）不在 GCController.controllers 里，槽位镜像由测试照 sample_input
//   写回同构放进去（同 test_pad_slots 的 apply_slots 注释）；setValue 只改读数不触发回调（本机实测，改前改后同一测法），
//   事件 = 照 GameController 的投递方式经 handlerQueue 调回调块本身。
static void slot_fake_pad(int slot, GCController *c) {
    pthread_mutex_lock(&g_compose_mu); pad_slot_owner[slot] = c; pthread_mutex_unlock(&g_compose_mu);
}
static void test_pad_fast_path(void) {
    typedef void (*read_ex_fn)(s2a_pad_snapshot *);
    read_ex_fn read_ex = (read_ex_fn)dlsym(RTLD_DEFAULT, "s2a_vpad_read_ex");
    expect(read_ex != NULL, "Mac exports s2a_vpad_read_ex");
    config = default_config(); keys = [NSMutableSet set]; mouse = [NSMutableSet set]; focused = YES;
    read_key_state = key_state; memset(physical_keys, 0, sizeof physical_keys);
    s2a_pad_set_active(0); s2a_pad_set_active(1);   // 清上一局留下的源选择
    reset_input();

    // ① 回调队列离开主队列
    GCController *pad0 = [GCController controllerWithExtendedGamepad];
    install_pad_handler(pad0);
    expect(pad0.handlerQueue != nil && pad0.handlerQueue != dispatch_get_main_queue(), "pad handler leaves the main queue");
    sample_input();   // 刷新键盘 / 鼠标快照与静音标记（此刻全零）
    slot_fake_pad(0, pad0);

    // ② 快速路径合键盘快照：Shift（位 1）+ 手柄 A（位 0）
    [keys addObject:@56]; modifiers = 1; physical_keys[60] = YES;
    sample_input(); slot_fake_pad(0, pad0);   // sample_input 整表重建镜像（虚拟手柄不在列表里会被清掉）：重放回去
    s2a_pad_snapshot snap; read_ex(&snap);
    expect(snap.buttons == 2, "keyboard shift alone maps to B");
    [pad0.extendedGamepad.buttonA setValue:1];
    pad0.extendedGamepad.valueChangedHandler(pad0.extendedGamepad, pad0.extendedGamepad.buttonA);
    read_ex(&snap);
    expect(snap.buttons == 3, "fast path composes the keyboard snapshot with the pad: B|A");
    [pad0.extendedGamepad.buttonA setValue:0];
    pad0.extendedGamepad.valueChangedHandler(pad0.extendedGamepad, pad0.extendedGamepad.buttonA);
    read_ex(&snap);
    expect(snap.buttons == 2, "release clears the pad bit and keeps the keyboard bit");
    [keys removeObject:@56]; modifiers = 0; physical_keys[60] = NO; sample_input(); slot_fake_pad(0, pad0);
    read_ex(&snap);
    expect(snap.buttons == 0, "keyboard release is visible after a sample");

    // ③ 主线程忙 300ms：事件经 handlerQueue 投递，200ms 截止内必须发布（改前排主队列，红）
    [pad0.extendedGamepad.buttonA setValue:1];
    read_ex(&snap); uint64_t observed = snap.notification_seq;
    dispatch_async(pad0.handlerQueue, ^{ pad0.extendedGamepad.valueChangedHandler(pad0.extendedGamepad, pad0.extendedGamepad.buttonA); });
    __block int woke = -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        woke = s2a_pad_wait(observed, s2a_pad_now_us() + 200000);   // 截止 200ms < 主线程忙 300ms：判「排不排队」，不受机器快慢影响
        dispatch_semaphore_signal(done);
    });
    usleep(20000);   // 让等待线程先进入条件变量；即使没进，序号变化也会让它立即返回
    uint64_t spin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 300000000ull;
    while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < spin) {}   // 主线程忙转：不进 runloop、不排主队列
    expect(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0, "pad wait settles");
    expect(woke == 1, "controller event publishes while the main thread is busy (deadline 200ms < busy 300ms)");
    run_loop_for(0.05);   // 改前实现：让仍排在主队列的那份回调在断言之后补跑，不泄给后面的用例
    read_ex(&snap);
    expect(snap.buttons == 1, "pad bit visible after the queued event");
    [pad0.extendedGamepad.buttonA setValue:0];
    pad0.extendedGamepad.valueChangedHandler(pad0.extendedGamepad, pad0.extendedGamepad.buttonA);

    // ④ 玩家 2（槽 1）：事件只写自己的槽位原子量并唤醒泵
    GCController *pad1 = [GCController controllerWithExtendedGamepad];
    install_pad_handler(pad1);
    slot_fake_pad(1, pad1);
    [pad1.extendedGamepad.buttonB setValue:1];
    read_ex(&snap); uint64_t seq1 = snap.notification_seq;
    dispatch_async(pad1.handlerQueue, ^{ pad1.extendedGamepad.valueChangedHandler(pad1.extendedGamepad, pad1.extendedGamepad.buttonB); });
    run_loop_for(0.05);   // 改前排主队列：跑 runloop 才执行（红）；改后排专用队列：早执行完
    read_ex(&snap);
    expect(snap.buttons == 0, "player 2 events do not leak into the player 1 snapshot");
    int32_t ps[4];
    expect(s2a_vpad_read_pad(1, ps) == 2, "player 2 slot atomics carry the pad B bit");
    expect(snap.notification_seq != seq1, "player 2 event wakes the HID pump");
    [pad1.extendedGamepad.buttonB setValue:0];
    dispatch_async(pad1.handlerQueue, ^{ pad1.extendedGamepad.valueChangedHandler(pad1.extendedGamepad, pad1.extendedGamepad.buttonB); });
    run_loop_for(0.05);

    // ⑤ 失焦静音：快速路径发零
    focused = NO; input_mute_refresh(); sample_input(); slot_fake_pad(0, pad0);
    [pad0.extendedGamepad.buttonA setValue:1];
    pad0.extendedGamepad.valueChangedHandler(pad0.extendedGamepad, pad0.extendedGamepad.buttonA);
    read_ex(&snap);
    expect(snap.buttons == 0, "muted fast path publishes zeros");
    focused = YES; input_mute_refresh(); sample_input();
    read_ex(&snap);
    expect(snap.buttons == 0, "refocus keeps input neutral until the next event");
    [pad0.extendedGamepad.buttonA setValue:0];
    reset_input();
    puts("Mac pad: dedicated-queue fast path, busy-main publish, player 2 slot and mute passed");
}

// 延迟读数（--pad-latency-probe 手动跑，不进门禁）：事件投递 → 回调执行 → pad.c 发布的毫秒读数，
//   同一测法改前改后各跑一遍（改前 = 负对照构建）。设备无关的判据在 test_pad_fast_path（截止 200ms < 忙 300ms），
//   这里只报数：主线程忙 0 / 100 / 300 / 1000ms 各 3 轮，dispatch→回调执行的耗时（排主队列的改前 ≈ 忙的时长）、
//   回调体自身耗时（快速路径采样 + 发布）与发布后的按键位。
static void pad_latency_probe(void) {
    typedef void (*read_ex_fn)(s2a_pad_snapshot *);
    read_ex_fn read_ex = (read_ex_fn)dlsym(RTLD_DEFAULT, "s2a_vpad_read_ex");
    expect(read_ex != NULL, "Mac exports s2a_vpad_read_ex");
    config = default_config(); keys = [NSMutableSet set]; mouse = [NSMutableSet set]; focused = YES;
    read_key_state = key_state; memset(physical_keys, 0, sizeof physical_keys);
    s2a_pad_set_active(0); s2a_pad_set_active(1); reset_input();
    GCController *pad = [GCController controllerWithExtendedGamepad];
    install_pad_handler(pad);
    __block uint64_t exec_us = 0, exec_end_us = 0;
    int cases[] = {0, 100, 300, 1000};
    for (int round = 0; round < 3; round++)
        for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
            [pad.extendedGamepad.buttonA setValue:0];
            pad.extendedGamepad.valueChangedHandler(pad.extendedGamepad, pad.extendedGamepad.buttonA);
            focused = YES; input_mute_refresh(); sample_input();
            slot_fake_pad(0, pad);
            s2a_pad_snapshot snap; read_ex(&snap);   // 清 pending 时间戳
            [pad.extendedGamepad.buttonA setValue:1];
            exec_us = exec_end_us = 0;
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000;
            dispatch_async(pad.handlerQueue, ^{
                exec_us = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000;
                pad.extendedGamepad.valueChangedHandler(pad.extendedGamepad, pad.extendedGamepad.buttonA);
                exec_end_us = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000;
            });
            uint64_t spin = t0 + (uint64_t)cases[i] * 1000;
            while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 < spin) {}   // 主线程忙转：不进 runloop、不排主队列
            run_loop_for(0.2);   // 改前排主队列：等 runloop 才执行；改后排专用队列：早执行完
            for (int n = 0; n < 1000 && !exec_end_us; n++) usleep(1000);
            s2a_pad_snapshot after; read_ex(&after);
            printf("pad-latency busy=%4dms round=%d dispatch→exec %.2fms exec-body %.3fms buttons=%u\n",
                   cases[i], round, (exec_us - t0) / 1000.0, (exec_end_us - exec_us) / 1000.0, after.buttons);
        }
    [pad.extendedGamepad.buttonA setValue:0];
    reset_input();
}

// 11-04 维护者定：鼠标左键点画面 = 触屏（对齐 Ryujinx TouchScreenManager）。期望手写：窗口 1600×720 点、无窗口缩放 1；
//   出图 16:9 → 画面在 x 160..1440（左右各 160 黑边），触点空间 1280×720，所以视图 (480, 360) → 触点 (320, 360)。
//   ① 左键映射成 Y（缺省映射）、模式「仅按键」：不写触点、照发 Y；② 左键没映射、模式「仅按键」：按下 Start (320,360)、拖到 (800,200) 跟点 (640,200)、抬起 End、之后 0 个；
//   ③ 点黑边 (100,360)：不写；④ 两次读之间按下又抬起：先 Start、下一拍 End；⑤ 直连模式（出图比例 16:9）同一矩形；⑥ 视角模式、左键没映射：点一下锁鼠标、不写触点；
//   ⑦ 按着时失焦：补一帧 End
static NSEvent *left_event(NSEventType type, NSPoint view_point, double view_h) {
    return [NSEvent mouseEventWithType:type location:NSMakePoint(view_point.x, view_h - view_point.y)   // 视图翻转（isFlipped），窗口坐标左下原点
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
}
static int read_touch(int32_t *x, int32_t *y, uint32_t *attr) { int32_t xy[2] = {-1, -1}; uint32_t a = 99; int n = s2a_vpad_read_touch(xy, &a); *x = xy[0]; *y = xy[1]; *attr = a; return n; }
static void test_mouse_touch(void) {
    S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSMakeRect(0, 0, 1600, 720)];
    int32_t x, y, sticks[4]; uint32_t a; NSPoint in = NSMakePoint(480, 360);
    fake_frame_w = 1280; fake_frame_h = 720; gfx_mode = S2A_GFX_GENERIC;
    NSMutableDictionary *c = [default_config() mutableCopy]; c[@"mouseOptions"] = @{@"mode": @"off", @"sensitivityX": @1, @"sensitivityY": @1};
    config = c; reset_input(); focused = YES; while (read_touch(&x, &y, &a)) {}
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    expect(read_touch(&x, &y, &a) == 0 && s2a_vpad_read(sticks) == (1u << 3), "① 左键映射成 Y：不写触点、照发 Y");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)];
    c[@"mouse"] = @{@"ZL": @1}; config = c; reset_input(); while (read_touch(&x, &y, &a)) {}
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    int n = read_touch(&x, &y, &a);
    expect(n == 1 && x == 320 && y == 360 && a == 1 && s2a_vpad_read(sticks) == 0, "② 左键没映射：按下 = Start (320,360)、不发键");
    [view mouseDragged:left_event(NSEventTypeLeftMouseDragged, NSMakePoint(800, 200), 720)];
    n = read_touch(&x, &y, &a);
    expect(n == 1 && x == 640 && y == 200 && a == 0, "② 拖动跟点 (640,200)");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, NSMakePoint(800, 200), 720)];
    n = read_touch(&x, &y, &a);
    expect(n == 1 && x == 640 && y == 200 && a == 2, "② 抬起 = End");
    expect(read_touch(&x, &y, &a) == 0, "② End 之后 0 个触点");
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, NSMakePoint(100, 360), 720)];
    expect(read_touch(&x, &y, &a) == 0, "③ 点黑边：不写触点");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, NSMakePoint(100, 360), 720)];
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)]; [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)];
    int n1 = read_touch(&x, &y, &a); uint32_t a1 = a; int n2 = read_touch(&x, &y, &a);
    expect(n1 == 1 && a1 == 1 && n2 == 1 && a == 2 && read_touch(&x, &y, &a) == 0, "④ 快点：先 Start、下一拍 End");
    gfx_mode = S2A_GFX_DIRECT; fake_frame_w = 0;
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    n = read_touch(&x, &y, &a);
    expect(n == 1 && x == 320 && y == 360 && a == 1, "⑤ 直连模式（出图 16:9）同一矩形：(320,360)");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)]; while (read_touch(&x, &y, &a)) {}
    gfx_mode = S2A_GFX_GENERIC; fake_frame_w = 1280;
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    S2AMacDelegate *delegate = [S2AMacDelegate new];
    [delegate windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:nil]];
    n = read_touch(&x, &y, &a); int n3 = read_touch(&x, &y, &a); uint32_t a3 = a;
    expect(n == 1 && n3 == 1 && a3 == 2 && read_touch(&x, &y, &a) == 0, "⑦ 按着时失焦：补一帧 End");
    focused = YES;
    c[@"mouseOptions"] = @{@"mode": @"camera", @"sensitivityX": @1, @"sensitivityY": @1}; config = c; reset_input(); while (read_touch(&x, &y, &a)) {}
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    expect(mouse_captured && read_touch(&x, &y, &a) == 0, "⑥ 视角模式：点一下锁鼠标、不写触点");
    set_mouse_capture(NO);
    config = default_config(); reset_input(); gfx_mode = S2A_GFX_GENERIC; fake_frame_w = 0;
    puts("Mac mouse touch: unmapped left click Start/drag/End, letterbox, quick tap, direct rect, focus End; mapped / camera left click no touch passed");
}

// 11-04 维护者定（开箱即用）：游戏声明了触屏配置（s2a_vpad_touch_configured）且玩家没改过键位 → 左键点画面当触屏（不发 Y、不锁鼠标）；
//   玩家改过键位 → 照他的设置；没声明 → 照旧（视角模式点一下锁鼠标、锁住后左键发 Y）。期望手写，画面同 test_mouse_touch：视图 (480,360) → 触点 (320,360)。
//   「没改过」用启动器标准映射写出的 JSON（Models.swift InputConfig.standard 编码：多 schema、modifiers 0、invert false、recenter true）验按值比较
static NSDictionary *launcher_standard_json(void) {
    NSMutableDictionary *c = [default_config() mutableCopy]; c[@"schema"] = @1;
    NSMutableDictionary *k = [NSMutableDictionary dictionary];
    for (NSString *n in c[@"keyboard"]) k[n] = @{@"code": c[@"keyboard"][n][@"code"], @"modifiers": @0};
    c[@"keyboard"] = k;
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    for (NSString *n in c[@"axes"]) a[n] = @{@"source": c[@"axes"][n][@"source"], @"invert": @NO};
    c[@"axes"] = a;
    c[@"mouseOptions"] = @{@"mode": @"camera", @"sensitivityX": @1.0, @"sensitivityY": @1.0, @"invertX": @NO, @"invertY": @NO, @"recenter": @YES};
    return [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:c options:0 error:nil] options:0 error:nil];   // 过一遍 JSON，同启动器落盘再读
}
static void test_mouse_touch_declared(void) {
    S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSMakeRect(0, 0, 1600, 720)];
    int32_t x, y, sticks[4]; uint32_t a; NSPoint in = NSMakePoint(480, 360);
    fake_frame_w = 1280; fake_frame_h = 720; gfx_mode = S2A_GFX_GENERIC; association_error = kCGErrorSuccess;
    atomic_store(&touch_declared, -1);
    config = default_config(); reset_input(); focused = YES; while (read_touch(&x, &y, &a)) {}
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    expect(mouse_captured && read_touch(&x, &y, &a) == 0, "没声明 + 缺省键位：照旧锁鼠标、不写触点");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)];
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    expect(read_touch(&x, &y, &a) == 0 && s2a_vpad_read(sticks) == (1u << 3), "没声明 + 缺省键位：锁住后左键照旧发 Y");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)]; set_mouse_capture(NO);
    expect(s2a_vpad_touch_configured(2) == 1, "声明配置：收下返回 1");
    config = launcher_standard_json(); reset_input(); while (read_touch(&x, &y, &a)) {}
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    int n = read_touch(&x, &y, &a);
    expect(n == 1 && x == 320 && y == 360 && a == 1 && !mouse_captured && s2a_vpad_read(sticks) == 0, "声明配置 + 缺省键位（启动器标准映射）：左键 = 触点 Start (320,360)、不发 Y、不锁鼠标");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)];
    expect(read_touch(&x, &y, &a) == 1 && a == 2, "声明配置 + 缺省键位：抬起 = End");
    NSMutableDictionary *changed = [launcher_standard_json() mutableCopy]; NSMutableDictionary *kb = [changed[@"keyboard"] mutableCopy];
    kb[@"A"] = @{@"code": @36, @"modifiers": @0}; changed[@"keyboard"] = kb;   // 玩家把 A 改到回车
    config = changed; reset_input(); while (read_touch(&x, &y, &a)) {}
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    expect(mouse_captured && read_touch(&x, &y, &a) == 0, "声明配置 + 玩家改过键位：按玩家设置（视角模式锁鼠标、不写触点）");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)];
    [view mouseDown:left_event(NSEventTypeLeftMouseDown, in, 720)];
    expect(read_touch(&x, &y, &a) == 0 && s2a_vpad_read(sticks) == (1u << 3), "声明配置 + 玩家改过键位：锁住后左键照旧发 Y");
    [view mouseUp:left_event(NSEventTypeLeftMouseUp, in, 720)]; set_mouse_capture(NO);
    atomic_store(&touch_declared, -1); config = default_config(); reset_input(); fake_frame_w = 0;
    puts("Mac mouse touch declared: declared + default mapping touches without Y/capture; changed mapping and undeclared keep camera/Y passed");
}
static NSDictionary *frozen_original_config(void) {
    return @{@"keyboard": @{@"A": @{@"code": @14}, @"B": @{@"code": @56}, @"X": @{@"code": @49},
                            @"L": @{@"code": @12}, @"R": @{@"code": @5}, @"ZR": @{@"code": @15},
                            @"LS": @{@"code": @59}, @"RS": @{@"code": @8}, @"PLUS": @{@"code": @48},
                            @"MINUS": @{@"code": @46}, @"LEFT": @{@"code": @123}, @"UP": @{@"code": @126},
                            @"RIGHT": @{@"code": @124}, @"DOWN": @{@"code": @125},
                            @"LS_UP": @{@"code": @13}, @"LS_DOWN": @{@"code": @1},
                            @"LS_LEFT": @{@"code": @0}, @"LS_RIGHT": @{@"code": @2}},
             @"mouse": @{@"Y": @0, @"ZL": @1},
             @"gamepad": @{@"A": @"east", @"B": @"south", @"X": @"north", @"Y": @"west",
                           @"L": @"leftShoulder", @"R": @"rightShoulder", @"ZL": @"leftTrigger", @"ZR": @"rightTrigger",
                           @"LS": @"leftStick", @"RS": @"rightStick", @"PLUS": @"menu", @"MINUS": @"options",
                           @"LEFT": @"dpadLeft", @"UP": @"dpadUp", @"RIGHT": @"dpadRight", @"DOWN": @"dpadDown"},
             @"axes": @{@"LX": @{@"source": @"leftX"}, @"LY": @{@"source": @"leftY"},
                         @"RX": @{@"source": @"rightX"}, @"RY": @{@"source": @"rightY"}}, @"deadzone": @0.15,
             @"mouseOptions": @{@"mode": @"camera", @"sensitivityX": @1, @"sensitivityY": @1}};
}

// CPU/Foundation-only slice. Calls the actual Mac adapter above and actual iOS
// file adapter (linked from ios/input_config.m), without creating NSApp,
// a Metal layer, a game process, or querying an attached input device.
static void test_shared_input_config(void) {
    unsigned n = 0;
#define CONFIG_EXPECT(x, why) do { n++; expect((x), (why)); } while (0)
    s2a_input_config mac, ios;
    CONFIG_EXPECT(!mac_input_config_read(NULL, &mac) && !s2a_ios_input_config_read(NULL, &ios), "no file selects shared defaults");
    CONFIG_EXPECT(!memcmp(&mac, &ios, sizeof mac), "two platform readers return identical default tables");
    CONFIG_EXPECT([mapping_norm(default_config()) isEqual:mapping_norm(frozen_original_config())], "all original Mac defaults remain semantically identical");
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CONFIG_EXPECT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL], "make private config fixture directory");
    NSString *path = [directory stringByAppendingPathComponent:@"input.json"];
    NSDictionary *base = @{@"schema":@1, @"keyboard":@{@"A":@{@"code":@49,@"modifiers":@3},@"B":@{@"code":@56}},
        @"mouse":@{@"Y":@0}, @"gamepad":@{@"A":@"east"}, @"axes":@{@"LX":@{@"source":@"rightY",@"invert":@YES}},
        @"deadzone":@0.2, @"mouseOptions":@{@"mode":@"camera",@"sensitivityX":@2,@"sensitivityY":@0.5}};
    NSArray *changes = @[
        @{@"expected":@0},
        @{@"schema":@2,@"expected":@(S2A_INPUT_CONFIG_SCHEMA)},
        @{@"schema":@"1",@"expected":@(S2A_INPUT_CONFIG_SCHEMA)},
        @{@"schema":@YES,@"expected":@(S2A_INPUT_CONFIG_SCHEMA)},
        @{@"keyboard":@"invalid",@"expected":@(S2A_INPUT_CONFIG_FIELDS)},
        @{@"keyboard":@{@"A":@{@"code":@"49"}},@"expected":@(S2A_INPUT_CONFIG_BINDING)},
        @{@"keyboard":@{@"A":@{@"code":@128}},@"expected":@(S2A_INPUT_CONFIG_BINDING)},
        @{@"keyboard":@{@"A":@{@"code":@49},@"B":@{@"code":@49}},@"expected":@(S2A_INPUT_CONFIG_DUPLICATE)},
        @{@"mouse":@{@"Y":@5},@"expected":@(S2A_INPUT_CONFIG_BINDING)},
        @{@"gamepad":@{@"A":@"invalid"},@"expected":@(S2A_INPUT_CONFIG_BINDING)},
        @{@"axes":@{@"LX":@{@"source":@"leftX",@"invert":@"yes"}},@"expected":@(S2A_INPUT_CONFIG_BINDING)},
        @{@"axes":@{@"LX":@{@"source":@"leftX"},@"RX":@{@"source":@"leftX"}},@"expected":@(S2A_INPUT_CONFIG_DUPLICATE)},
        @{@"deadzone":@1,@"expected":@(S2A_INPUT_CONFIG_RANGE)}
    ];
    for (NSDictionary *change in changes) {
        NSMutableDictionary *fixture = [base mutableCopy];
        for (NSString *key in change) if (![key isEqual:@"expected"]) fixture[key] = change[key];
        NSData *data = [NSJSONSerialization dataWithJSONObject:fixture options:0 error:NULL];
        CONFIG_EXPECT([data writeToFile:path atomically:YES], "write synthetic JSON fixture");
        memset(&mac,0x5a,sizeof mac); memset(&ios,0x5a,sizeof ios);
        int expected = [change[@"expected"] intValue];
        int a = mac_input_config_read(path.fileSystemRepresentation,&mac), b = s2a_ios_input_config_read(path.fileSystemRepresentation,&ios);
        CONFIG_EXPECT(a == expected && b == expected, "same hand-declared parse/error result on both platform adapters");
        CONFIG_EXPECT(!memcmp(&mac,&ios,sizeof mac), "byte-identical portable tables including failure-not-published cases");
        if (!expected) {
            NSDictionary *converted = input_config_dictionary(&mac);
            CONFIG_EXPECT(mac.keyboard[0].code == 49 && mac.keyboard[0].modifiers == 3 && mac.keyboard[1].code == 56, "handwritten custom physicalkey table");
            CONFIG_EXPECT(mac.mouse[3] == 0 && mac.gamepad[0] == 0 && mac.axes[0].source == 3 && mac.axes[0].invert, "handwritten mouse/gamepad/axis sources");
            CONFIG_EXPECT(mac.deadzone == .2 && mac.sensitivity_x == 2 && mac.sensitivity_y == .5 && mac.recenter, "options and omitted recenter default");
            CONFIG_EXPECT([converted[@"keyboard"][@"A"][@"code"] isEqual:@49] && [converted[@"axes"][@"LX"][@"source"] isEqual:@"rightY"], "Mac dictionary consumes actual decoded fields");
            CONFIG_EXPECT([mapping_norm(converted) isEqual:mapping_norm(base)], "UI/native dictionary bridge preserves supplied config semantics");
        }
    }
    CONFIG_EXPECT([[@"{" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES], "write malformed JSON");
    CONFIG_EXPECT(mac_input_config_read(path.fileSystemRepresentation,&mac) == S2A_INPUT_CONFIG_JSON && s2a_ios_input_config_read(path.fileSystemRepresentation,&ios) == S2A_INPUT_CONFIG_JSON, "malformed JSON same error code");
    NSString *missing = [directory stringByAppendingPathComponent:@"not-created.json"];
    CONFIG_EXPECT(mac_input_config_read(missing.fileSystemRepresentation,&mac) == S2A_INPUT_CONFIG_IO && s2a_ios_input_config_read(missing.fileSystemRepresentation,&ios) == S2A_INPUT_CONFIG_IO, "file I/O errors match");
    NSData *data = [NSJSONSerialization dataWithJSONObject:base options:0 error:NULL];
    CONFIG_EXPECT([data writeToFile:path atomically:YES], "restore own valid fixture only");
    char savedNumericLocale[128]; snprintf(savedNumericLocale,sizeof savedNumericLocale,"%s",setlocale(LC_NUMERIC,NULL));
    for (const char **name = (const char *[]){"fr_FR.UTF-8","de_DE.UTF-8",NULL}; *name; name++) {
        if (!setlocale(LC_NUMERIC,*name)) continue;
        CONFIG_EXPECT(!mac_input_config_read(path.fileSystemRepresentation,&mac) && !s2a_ios_input_config_read(path.fileSystemRepresentation,&ios), "both platform readers accept locale-independent JSON decimals");
        CONFIG_EXPECT(mac.deadzone == .2 && ios.sensitivity_y == .5 && !memcmp(&mac,&ios,sizeof mac), "same numeric table under comma-decimal locale");
    }
    CONFIG_EXPECT(setlocale(LC_NUMERIC,savedNumericLocale) != NULL,"restore test process numeric locale");
    const char *priorDocs = getenv("S2A_DOCS"), *priorPath = getenv("S2A_INPUT_CONFIG");
    NSString *savedDocs = priorDocs ? @(priorDocs) : nil, *savedPath = priorPath ? @(priorPath) : nil;
    setenv("S2A_DOCS",directory.fileSystemRepresentation,1); setenv("S2A_INPUT_CONFIG","input.json",1);
    CONFIG_EXPECT(!s2a_ios_input_config_load(), "iOS shell loads relative imported config under Documents");
    const s2a_input_config *active = s2a_ios_input_config_current();
    CONFIG_EXPECT(active && active->keyboard[0].code == 49 && active->axes[0].source == 3, "iOS published table is the parsed custom mapping");
    CONFIG_EXPECT([[@"{" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES], "replace own fixture with invalid JSON");
    CONFIG_EXPECT(s2a_ios_input_config_load() == S2A_INPUT_CONFIG_JSON && !s2a_ios_input_config_current(), "failed iOS startup load cannot expose previous mapping");
    if (savedDocs) setenv("S2A_DOCS",savedDocs.UTF8String,1); else unsetenv("S2A_DOCS");
    if (savedPath) setenv("S2A_INPUT_CONFIG",savedPath.UTF8String,1); else unsetenv("S2A_INPUT_CONFIG");
    CONFIG_EXPECT([NSFileManager.defaultManager removeItemAtPath:directory error:NULL], "remove only synthetic fixture directory created by this test");
    printf("input_config_apple details: %u/%u checks (actual Mac/iOS readers on macOS, no UI/device/game)\n",n,n);
#undef CONFIG_EXPECT
}
int main(int argc, const char **argv) {
    char relayPath[96];
    snprintf(relayPath, sizeof relayPath, "/tmp/s2arm-motion-%d.sock", getpid());
    struct sockaddr_un relayAddress = {.sun_family = AF_UNIX};
    strcpy(relayAddress.sun_path, relayPath);
    int relayListener = socket(AF_UNIX, SOCK_STREAM, 0);
    expect(bind(relayListener, (struct sockaddr *)&relayAddress, sizeof relayAddress) == 0, "motion relay bind");
    expect(listen(relayListener, 1) == 0, "motion relay listen");
    // 开局后才连手柄（11-11 实机：先开游戏、再在 S2Arm 连 Joy-Con 2，游戏一直收不到输入）：通道文件不在不连、出现后连；已接上 / 非 IDLE 不重复连
    char missingRelay[96];
    snprintf(missingRelay, sizeof missingRelay, "/tmp/s2arm-missing-%d.sock", getpid());
    expect(!s2a_mac_ns2_relay_due(NS2_STATUS_IDLE, missingRelay), "relay not due before the S2Arm connection program creates the socket");
    expect(s2a_mac_ns2_relay_due(NS2_STATUS_IDLE, relayPath), "relay due once the socket exists and the game never connected");
    expect(!s2a_mac_ns2_relay_due(NS2_STATUS_READY, relayPath) && !s2a_mac_ns2_relay_due(NS2_STATUS_CONNECTING, relayPath),
           "relay not reconnected while connected or connecting");
    expect(!s2a_mac_ns2_relay_due(NS2_STATUS_IDLE, NULL) && !s2a_mac_ns2_relay_due(NS2_STATUS_IDLE, ""), "no relay path: keyboard-only launch never connects");
    setenv("S2A_NS2_SOCKET", relayPath, 1);
    s2a_mac_ns2_focus(1);
    expect(s2a_mac_ns2_connect(), "Switch 2 Pro motion relay connects");
    int relayClient = accept(relayListener, NULL, NULL);
    s2a_pad_set_motion_enabled(1);
    s2a_mac_ns2_set_game_style(1 << 4);   // 游戏用 JoyconRight：单只右 Joy-Con 的六轴原样给（#520 A）
    ns2_relay_packet motionPacket = {
        .magic = NS2_RELAY_MAGIC, .version = NS2_RELAY_VERSION, .type = NS2_RELAY_INPUT,
        .ready = 1, .status = NS2_STATUS_READY, .motion_known = 1, .kind = NS2_KIND_JOYCON_R,
        .motion = {.known = 1, .host_timestamp_us = 1234, .gyro_x = 90, .acceleration_z = 1},
    };
    expect(send(relayClient, &motionPacket, sizeof motionPacket, 0) == sizeof motionPacket, "motion relay publishes");
    s2a_pad_motion ns2Motion = {0};
    for (int attempt = 0; attempt < 100 && !s2a_pad_read_motion(&ns2Motion); attempt++) usleep(1000);
    expect(ns2Motion.host_timestamp_us == 1234 && ns2Motion.gyro_x == 90 && ns2Motion.acceleration_z == 1,
           "Switch 2 Pro motion reaches shared Mac six-axis entry");
    // #520 A：游戏不用单只样式（扮 Pro）时，单只右 Joy-Con 的六轴在游戏端转成横握视角：(ax, az) → (−az, ax)、(gx, gz) → (−gz, gx)
    s2a_mac_ns2_set_game_style(1 << 0);
    expect(s2a_pad_read_motion(&ns2Motion) && ns2Motion.gyro_x == 0 && ns2Motion.gyro_z == 90 && ns2Motion.acceleration_x == -1 && ns2Motion.acceleration_z == 0,
           "single right Joy-Con motion turns sideways when the game uses a Pro controller");
    // 按键 / 摇杆同理：通道收原始方向（SL 在扩展位 21）；游戏用 JoyconRight 原样给、SL 换成 Ryujinx SlRight，扮 Pro 时转横握、SL 当 L
    ns2_relay_packet rawPacket = motionPacket; rawPacket.state = (ns2_state){(1ull << 2) | (1ull << NS2_BUTTON_SL), 0, 0, 300, -400};
    expect(send(relayClient, &rawPacket, sizeof rawPacket, 0) == sizeof rawPacket, "raw single Joy-Con packet sent");
    ns2_state shaped; uint32_t side = 0;
    for (int attempt = 0; attempt < 100 && !(s2a_mac_ns2_read(&shaped, &side), shaped.buttons); attempt++) usleep(1000);
    expect(shaped.buttons == ((1ull << 0) | (1ull << 6)) && side == 0 && shaped.lx == -400 && shaped.ly == -300 && !s2a_mac_ns2_raw_now(),
           "game uses Pro: raw right Joy-Con becomes sideways (X -> A, SL -> L, stick (300,-400) -> (-400,-300))");
    s2a_mac_ns2_set_game_style(1 << 4);
    s2a_mac_ns2_read(&shaped, &side);
    expect(shaped.buttons == (1ull << 2) && side == (1u << 26) && shaped.rx == 300 && shaped.ry == -400 && s2a_mac_ns2_raw_now(),
           "game uses JoyconRight: raw keys and right stick pass through, SL becomes Ryujinx SlRight");
    s2a_mac_ns2_set_game_style(1 << 3);
    s2a_mac_ns2_read(&shaped, &side);
    expect(side == 0 && shaped.buttons == ((1ull << 0) | (1ull << 6)) && !s2a_mac_ns2_raw_now(), "game uses JoyconLeft with a right Joy-Con: not raw (sideways)");
    // 游戏不收 Pro、只收双 Joy-Con（InputPump 报 JoyconPair）：单只右 Joy-Con 照原始方向（真机双手模式只接一侧、直握；11-11 一款体育游戏的球类项目实机）
    s2a_mac_ns2_set_game_style(1 << 2);
    s2a_mac_ns2_read(&shaped, &side);
    expect(shaped.buttons == (1ull << 2) && side == (1u << 26) && s2a_mac_ns2_raw_now(), "game uses JoyconPair only: single Joy-Con stays raw (vertical)");
    expect(s2a_mac_ns2_single_style(NS2_KIND_JOYCON_L) == (1 << 3) && s2a_mac_ns2_single_style(NS2_KIND_JOYCON_R) == (1 << 4) &&
           !s2a_mac_ns2_single_style(NS2_KIND_PRO) && !s2a_mac_ns2_single_style(NS2_KIND_JOYCON_PAIR) && !s2a_mac_ns2_single_style(NS2_KIND_NONE),
           "single Joy-Con style hint: only one Joy-Con maps to JoyconLeft / JoyconRight");
    ns2_state pro = {(1ull << 6) | (1ull << NS2_BUTTON_SL), 1, 2, 3, 4};
    expect(s2a_mac_ns2_shape(NS2_KIND_PRO, 0, &pro) == 0 && pro.buttons == ((1ull << 6) | (1ull << NS2_BUTTON_SL)) && pro.lx == 1,
           "shape leaves the Pro controller untouched");
    s2a_mac_ns2_set_game_style(1 << 4);
    // 通道 v2 带型号（#520）：游戏端照收；菜单显示名跟着型号
    expect(s2a_mac_ns2_kind() == NS2_KIND_JOYCON_R && !strcmp(s2a_mac_ns2_kind_name(s2a_mac_ns2_kind()), "Joy-Con 2 (R)"),
           "relay v2 carries the controller kind to the game");
    expect(!strcmp(s2a_mac_ns2_kind_name(NS2_KIND_JOYCON_PAIR), "Joy-Con 2 (L + R)") && !strcmp(s2a_mac_ns2_kind_name(NS2_KIND_NONE), "Switch 手柄") && !strcmp(s2a_mac_ns2_kind_name(NS2_KIND_PRO), "Switch 2 Pro"),
           "kind display names: pair and not-connected fallback");
    // Joy-Con 2 拼成一对：只有右只（motion_left_known 0，同旧启动器）时一路；INPUT 包带左只（motion_left）时左右各一路，左在前
    s2a_pad_motion pairMotion[2] = {0};
    expect(s2a_pad_read_motion_pair(pairMotion) == 1 && pairMotion[0].gyro_x == 90, "Joy-Con 2 pair without left motion: one source (right), as before");
    ns2_relay_packet pairPacket = motionPacket; pairPacket.kind = NS2_KIND_JOYCON_PAIR; pairPacket.motion.host_timestamp_us = 2000;
    pairPacket.motion_left_known = 1;
    pairPacket.motion_left = (ns2_relay_motion_left){.acceleration_z = 1, .gyro_x = -90, .host_timestamp_us_lo = 1999};
    expect(send(relayClient, &pairPacket, sizeof pairPacket, 0) == sizeof pairPacket, "pair relay packet with left motion sent");
    int pairN = 0;
    for (int attempt = 0; attempt < 100 && (pairN = s2a_pad_read_motion_pair(pairMotion)) != 2; attempt++) usleep(1000);
    expect(pairN == 2 && pairMotion[0].gyro_x == -90 && pairMotion[0].host_timestamp_us == 1999 && pairMotion[1].gyro_x == 90 && pairMotion[1].host_timestamp_us == 2000,
           "Joy-Con 2 pair: left motion from motion_left, right from motion, left first");
    expect(s2a_pad_read_motion(&ns2Motion) && ns2Motion.gyro_x == 90, "single-source six-axis entry still reads the right Joy-Con");
    // Joy-Con 2 光学鼠标（INPUT 包 mouse / mouse_kind）：没有鼠标读数（旧启动器）时照样报连着 Joy-Con 2、known 0
    //   （一对 → 两侧）；有读数时 x / y / distance 原样、side 跟 mouse_kind；Pro 不报
    s2a_pad_mouse jcMouse[2] = {{0}};
    expect(s2a_pad_read_mouse_pair(jcMouse) == 2 && jcMouse[0].side == 0 && jcMouse[1].side == 1 && !jcMouse[0].known && !jcMouse[1].known,
           "Joy-Con 2 pair without mouse readings: both sides still reported as Joy-Con 2, no readings");
    ns2_relay_packet mousePacket = pairPacket; mousePacket.kind = NS2_KIND_JOYCON_L; mousePacket.mouse_kind = NS2_KIND_JOYCON_L;
    mousePacket.mouse = (ns2_relay_mouse){.x = -5, .y = 300, .surface = 7, .distance = 0};
    expect(send(relayClient, &mousePacket, sizeof mousePacket, 0) == sizeof mousePacket, "relay packet with mouse readings sent");
    for (int attempt = 0; attempt < 100 && !(s2a_pad_read_mouse_pair(jcMouse) && jcMouse[0].known); attempt++) usleep(1000);
    expect(jcMouse[0].known && jcMouse[0].side == 0 && jcMouse[1].side == 0xff && jcMouse[0].x == -5 && jcMouse[0].y == 300 && jcMouse[0].distance == 0 && jcMouse[0].host_timestamp_us != 0,
           "Joy-Con 2 mouse readings reach the game: left side, raw x / y / distance");
    // 拼成一对、两只都有鼠标：连接程序一包左一包右轮流（mouse_kind 标哪一只），宿主左右各存一份
    ns2_relay_packet pairMouse = pairPacket; pairMouse.kind = NS2_KIND_JOYCON_PAIR;
    pairMouse.mouse_kind = NS2_KIND_JOYCON_R; pairMouse.mouse = (ns2_relay_mouse){.x = 40, .y = 1};
    expect(send(relayClient, &pairMouse, sizeof pairMouse, 0) == sizeof pairMouse, "pair relay packet with right mouse sent");
    pairMouse.mouse_kind = NS2_KIND_JOYCON_L; pairMouse.mouse = (ns2_relay_mouse){.x = -7, .y = 2, .distance = 12};
    expect(send(relayClient, &pairMouse, sizeof pairMouse, 0) == sizeof pairMouse, "pair relay packet with left mouse sent");
    s2a_pad_mouse both[2] = {{0}};
    int bothN = 0;
    for (int attempt = 0; attempt < 100 && !((bothN = s2a_pad_read_mouse_pair(both)) == 2 && both[0].known && both[0].x == -7 && both[1].known); attempt++) usleep(1000);
    expect(bothN == 2 && both[0].side == 0 && both[0].x == -7 && both[0].distance == 12 && both[1].side == 1 && both[1].x == 40,
           "Joy-Con 2 pair: left and right mouse readings both reach the game (alternating packets)");
    ns2_relay_packet proPacket = motionPacket; proPacket.kind = NS2_KIND_PRO;
    expect(send(relayClient, &proPacket, sizeof proPacket, 0) == sizeof proPacket, "Pro relay packet sent");
    for (int attempt = 0; attempt < 100 && s2a_pad_read_mouse_pair(jcMouse); attempt++) usleep(1000);
    expect(!s2a_pad_read_mouse_pair(jcMouse) && !jcMouse[0].known && !jcMouse[1].known, "Pro controller: no Joy-Con 2 mouse");
    // 旧版启动器（通道 v1）：游戏端断开、不猜字段，型号回到 NONE
    ns2_relay_packet oldPacket = motionPacket; oldPacket.version = 1;
    expect(send(relayClient, &oldPacket, sizeof oldPacket, 0) == sizeof oldPacket, "relay v1 packet sent");
    for (int attempt = 0; attempt < 100 && s2a_mac_ns2_status() != NS2_STATUS_DISCONNECTED; attempt++) usleep(1000);
    expect(s2a_mac_ns2_status() == NS2_STATUS_DISCONNECTED && s2a_mac_ns2_kind() == NS2_KIND_NONE,
           "relay version mismatch disconnects instead of guessing fields");
    s2a_pad_set_motion_enabled(0);
    s2a_mac_ns2_detach();
    close(relayClient);
    close(relayListener);
    unlink(relayPath);
    unsetenv("S2A_NS2_SOCKET");
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--input-config-only")) { test_shared_input_config(); return 0; }
        if (argc == 2 && !strcmp(argv[1], "--pad-latency-probe")) { pad_latency_probe(); return 0; }
        if (argc >= 3 && !strcmp(argv[1], "--guide-render")) {
            [NSApplication sharedApplication];
            NSApp.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
            S2AMacInputGuide *guide=[[S2AMacInputGuide alloc] initWithName:guide_text(@"只读手柄图 · 合成样本（非游戏）",@"Read-only controls · Synthetic fixture (not a game)")
                gameID:@"0100000000000001" mapping:default_config() gameWindow:nil];
            if (argc > 3) [guide selectTarget:@(argv[3])];
            NSView *view=guide.window.contentView; [view layoutSubtreeIfNeeded];
            NSBitmapImageRep *bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
            NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            expect([png writeToFile:@(argv[2]) atomically:YES], "write native read-only render");
            return 0;
        }
#ifdef S2A_GUIDE_TEST_HOST
        // Explicit synthetic-host build for control-port/UI integration checks.
        // No loader, game resources or guest execution is linked into this fixture.
        guide_preview = YES; s2a_front_run(NULL); return 0;
#endif
        if (argc == 2 && !strcmp(argv[1], "--guide-preview")) { guide_preview = YES; s2a_front_run(NULL); return 0; }
        test_shared_input_config();
        test_active_pad();
        test_pad_slots();
        // 同一个真实前端实现：通用 attach 先发布层，detach 先通知再清层；
        // 直连只发布/清层，不通知尚未初始化且不应初始化的通用 NxGal。
        CAMetalLayer *front = [CAMetalLayer layer];
        void *raw = (__bridge void *)front;
        front_layer_attach(front);
        expect(layer_calls == 1 && notified_layer == raw, "generic attaches original layer once");
        expect(published_at_notify == raw && s2a_mac_front_layer() == raw, "generic publishes layer before notifying");
        front_layer_detach();
        expect(layer_calls == 2 && notified_layer == NULL, "generic detaches layer once");
        expect(published_at_notify == raw && s2a_mac_front_layer() == NULL, "generic preserves detach ordering");
        gfx_mode = S2A_GFX_DIRECT;
        front_layer_attach(front);
        expect(layer_calls == 2 && s2a_mac_front_layer() == raw, "direct publishes layer without generic attach");
        front_layer_detach();
        expect(layer_calls == 2 && s2a_mac_front_layer() == NULL, "direct clears layer without generic detach");
        gfx_mode = S2A_GFX_GENERIC;
        config = default_config(); keys = [NSMutableSet set]; mouse = [NSMutableSet set]; focused = YES;
        test_key_repeat();
        test_event_input();
        test_pad_disconnect();
        test_pad_handler_install();
        test_pad_fast_path();
        test_profile_only_pad();
    test_pad_layout();
        test_save_atomic_warning();
        test_lan_warning();
        test_focus_suspend();
        test_untrusted_key_state();
        test_modifier_false_release();
        test_keyboard_hid();
        test_mouse_lost_release();
        test_mouse_touch();
        test_mouse_touch_declared();
        setenv("S2A_UI_LANGUAGE", "en", 1);
        NSArray *guideRows = s2a_mac_guide_rows(config);
        expect([guideRows[0][1] isEqual:@"E"], "guide uses actual default A key");
        expect([guideRows[3][2] isEqual:@"Left click"], "guide describes actual mouse Y binding");
        expect([guideRows[0][3] isEqual:@"Right face button"], "guide includes human-readable controller mapping");
        [NSApplication sharedApplication];
        NSMutableDictionary *source=[config mutableCopy];
        source[@"keyboard"]=[config[@"keyboard"] mutableCopy];
        S2AMacInputGuide *visual=[[S2AMacInputGuide alloc] initWithName:@"Synthetic readonly fixture" gameID:@"0100000000000001" mapping:source gameWindow:nil];
        expect(!visual.window.visible, "native visual guide never opens automatically");
        int buttonCount=0, editors=0; inspect_guide(visual.window.contentView, &buttonCount, &editors);
        expect(buttonCount==24 && [NSSet setWithArray:s2a_mac_controller_targets()].count==24, "all 24 supported targets are selectable in the diagram");
        expect(editors==0, "native guide has no editable fields or mapping pickers");
        source[@"keyboard"][@"A"]=@{@"code":@36};
        [visual selectTarget:@"B"];
        expect([visual.selectedTarget isEqual:@"B"] && guide_has_label(visual.window.contentView,@"Shift"), "selection displays the corresponding frozen input");
        [visual selectTarget:@"A"];
        expect(guide_has_label(visual.window.contentView,@"E"), "external edits cannot relabel the running snapshot");
        [visual selectTarget:@"not-an-input"];
        expect([visual.selectedTarget isEqual:@"A"], "invalid selection does not change displayed target");
        expect([config[@"keyboard"][@"A"][@"code"] intValue]==14, "diagram selection never changes HID mapping");
        NSImage *statusIcon=s2a_mac_guide_status_image();
        expect(statusIcon.template && NSEqualSizes(statusIcon.size,NSMakeSize(22,18)) && statusIcon.TIFFRepresentation.length>0, "Switch status icon renders as an adaptive template");
        visual=nil;
        expect(![s2a_mac_guide_preference_key(@"0100000000000001") isEqual:s2a_mac_guide_preference_key(@"0100000000000002")], "guide preferences are keyed by game ID");
        expect(s2a_mac_guide_preference_key(@"../unknown") == nil, "unknown identity cannot share preferences");
        NSString *guideRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:guideRoot withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *preference = [guideRoot stringByAppendingPathComponent:@"guide.json"];
        NSData *pref = [NSJSONSerialization dataWithJSONObject:@{@"schema":@1, @"gameId":@"0100000000000001", @"show":@NO} options:0 error:NULL];
        [pref writeToFile:preference atomically:YES];
        expect(!s2a_mac_guide_show_again(@"0100000000000001", preference), "native guide reads shared launcher preference");
        expect(s2a_mac_guide_show_again(@"0100000000000002", preference), "another game cannot inherit hidden guide");
        NSData *manifest = [NSJSONSerialization dataWithJSONObject:@{@"gameId":@"0100000000000001", @"gameName":@"Fixture A"} options:0 error:NULL];
        [manifest writeToFile:[guideRoot stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
        setenv("S2A_GAME_DATA", guideRoot.UTF8String, 1); unsetenv("S2A_GAME_NAME"); unsetenv("S2A_GAME_ID");
        expect([s2a_mac_guide_identity()[@"name"] isEqual:@"Fixture A"], "packaged game metadata names the guide without a launcher override");
        setenv("S2A_GAME_NAME", "Fixture B", 1); setenv("S2A_GAME_ID", "0100000000000002", 1);
        expect([s2a_mac_guide_identity()[@"name"] isEqual:@"Fixture B"], "new launch identity replaces previous game name");
        [NSFileManager.defaultManager removeItemAtPath:guideRoot error:NULL];
        int32_t sticks[4];
        [keys addObject:@14]; sample_input(); expect(s2a_vpad_read(sticks) == 1, "E maps to Switch A");
        [keys addObject:@13]; sample_input(); s2a_vpad_read(sticks); expect(sticks[1] == 32767, "W moves left stick up");
        [mouse addObject:@1]; sample_input(); expect(s2a_vpad_read(sticks) & (1u << 8), "right mouse maps to ZL");
        focused = NO; sample_input(); expect(s2a_vpad_read(sticks) == 0 && !sticks[1], "focus loss clears input");
        reset_input(); focused = YES;
        associate_mouse = test_associate; set_mouse_visible = test_cursor_visibility;
        set_mouse_capture(YES);
        expect(mouse_captured && !association_connected && cursor_hides == 1, "capture disconnects and hides cursor");
        association_error = kCGErrorFailure; set_mouse_capture(NO);
        expect(!mouse_captured && mouse_release_pending && cursor_shows == 1, "failed release remains retryable and stops camera input");
        set_mouse_capture(NO);
        expect(association_calls == 3 && cursor_shows == 1, "release retry does not unhide twice");
        association_error = kCGErrorSuccess; set_mouse_capture(NO);
        expect(!mouse_release_pending && association_connected, "release retry restores cursor association");
        set_mouse_capture(NO); expect(association_calls == 4, "released cursor needs no extra OS call");
        association_error = kCGErrorFailure; set_mouse_capture(YES);
        expect(!mouse_captured && !mouse_release_pending && cursor_hides == 1, "failed capture does not hide cursor");
        association_error = kCGErrorSuccess;
        test_capture_key_order();
        test_fullscreen_esc();
        test_capture_held_key(YES);
        test_capture_held_key(NO);
        associate_mouse = CGAssociateMouseAndMouseCursorPosition; set_mouse_visible = cursor_visibility;
        S2AMetalView *motionView = [S2AMetalView new];
        mouse_captured = YES; // Handler precondition only; do not call the OS capture API in unit tests.
        TestMotion *motion = [TestMotion new]; motion.deltaX = 1; motion.deltaY = -1;
        for (int i = 0; i < 8; i++) [motionView mouseMoved:(NSEvent *)motion];
        sample_input(); sample_input(); // 120 Hz frontend may publish twice before the 60 Hz HID read.
        s2a_vpad_read(sticks);
        expect(sticks[2] == 12000 && sticks[3] == 12000, "all mouse deltas survive frontend polls until HID consumes them");
        s2a_vpad_read(sticks); expect(!sticks[2] && !sticks[3], "mouse deltas consumed exactly once");
        motion.deltaX = 4; motion.deltaY = 0; [motionView mouseMoved:(NSEvent *)motion];
        motion.deltaX = -4; [motionView mouseMoved:(NSEvent *)motion];
        s2a_vpad_read(sticks); expect(!sticks[2], "opposite mouse deltas cancel within one HID interval");
        motion.deltaX = 100; [motionView mouseMoved:(NSEvent *)motion];
        s2a_vpad_read(sticks); expect(sticks[2] == 32767, "mouse stick clamps only at HID read");
        [motionView mouseMoved:(NSEvent *)motion]; reset_input();
        s2a_vpad_read(sticks); expect(!sticks[2], "focus reset discards pending mouse movement");
        mouse_captured = NO; [motionView mouseMoved:(NSEvent *)motion];
        s2a_vpad_read(sticks); expect(!sticks[2], "uncaptured cursor does not rotate the camera");
        mouse_captured = YES; focused = NO; [motionView mouseMoved:(NSEvent *)motion];
        s2a_vpad_read(sticks); expect(!sticks[2], "unfocused mouse motion is ignored");
        // 审计 P2-62：recenter = false（赛车预设）→ 停手后右摇杆停在原处；复位清零；recenter 缺省 / true → 下一拍回中。期望按 1500 × 灵敏度手算
        config = @{@"keyboard": @{}, @"mouse": @{}, @"gamepad": @{}, @"axes": @{}, @"deadzone": @0.15,
                   @"mouseOptions": @{@"mode": @"camera", @"sensitivityX": @1, @"sensitivityY": @1, @"recenter": @NO}};
        apply_mouse_options(); focused = YES; mouse_captured = YES;
        motion.deltaX = 2; motion.deltaY = 0; [motionView mouseMoved:(NSEvent *)motion];
        s2a_vpad_read(sticks); expect(sticks[2] == 3000, "no-recenter mouse moves the stick");
        s2a_vpad_read(sticks); expect(sticks[2] == 3000, "no-recenter stick holds after the mouse stops");
        [motionView mouseMoved:(NSEvent *)motion];
        s2a_vpad_read(sticks); expect(sticks[2] == 6000, "no-recenter stick accumulates further movement");
        reset_input(); s2a_vpad_read(sticks); expect(!sticks[2], "focus reset recenters a held stick");
        config = default_config(); apply_mouse_options();
        [motionView mouseMoved:(NSEvent *)motion];
        s2a_vpad_read(sticks); expect(sticks[2] == 3000, "default recenter moves the stick");
        s2a_vpad_read(sticks); expect(!sticks[2], "default recenter returns to center after the mouse stops");
        mouse_captured = NO; focused = YES;
        config = @{@"keyboard": @{@"A": @{@"code": @14, @"modifiers": @1}, @"B": @{@"code": @56}},
                   @"mouse": @{}, @"gamepad": @{}, @"axes": @{}, @"deadzone": @0.15};
        [keys addObjectsFromArray:@[@14, @56]]; modifiers = 1; sample_input();
        expect(s2a_vpad_read(sticks) == 1, "chord consumes standalone modifier binding");
        reset_input();
        pthread_t thread; expect(!pthread_create(&thread, NULL, read_snapshots, NULL), "create HID reader");
        for (int i = 0; i < 100000; i++) {   // publish 的序号快照只允许一个写者在 g_compose_mu 内：同生产代码的两条写线
            int32_t v = i % 32768, s[4] = {v, v, v, v};
            pthread_mutex_lock(&g_compose_mu);
            publish((uint32_t)v, s);
            pthread_mutex_unlock(&g_compose_mu);
        }
        void *result; pthread_join(thread, &result); expect(result == NULL, "HID reads coherent snapshots");
        S2AMetalView *view = [[S2AMetalView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
        view.wantsLayer = YES; view.layer = [CAMetalLayer layer]; [view layout];
        expect(width == 640 && height == 360, "view publishes native pixel size");
        expect(fit_w == 640 && fit_h == 360, "view hands the same pixel size to the widen screen (P1-83: the window's aspect follows)");
        puts("Mac input/guide: mappings, identity, snapshots and graphics-mode layer checks passed");
    }
    return 0;
}
