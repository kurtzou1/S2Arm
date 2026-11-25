// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 启动器读 HID 兜底手柄的按键 / 摇杆（#1151：PowerA WLC001「Lic Pro Controller」GameController 认不出，游戏里由宿主 macos/hid_pad.m 按 HID 读、能用，
//   启动器游戏库却选不动）。认法、解析同宿主（hid_generic.h、hid_pro_parse.h 共用一份）：名字带「Pro Controller」的走 Switch Pro 那一支——
//   简单报告按元素读、已在完整报告 0x30 模式（游戏里宿主切过）按报告读；其余通用手柄除了微软 / 索尼 / 任天堂按位置映射直读。
//   只读、不发任何输出报告（不切模式、不点灯：那些归游戏里的宿主），共享打开、不独占；启动器失焦（游戏在前台）时关掉
#import "LauncherPadBridge.h"
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include "../../../../../macos/hid_generic.h"
#include "../../../../../macos/hid_pro_parse.h"
#include <pthread.h>
#include <string.h>

struct s2a_launcher_hid_state {
    int pro, full; uint32_t buttons, hat; int16_t ax[4];   // pro：元素 / 报告读到的（Npad 位）；full：收到过 0x30，之后只认报告
    s2a_pro_cal cl, cr; s2a_hidg g;                         // g：通用手柄
};

void s2a_launcher_hid_state_init(s2a_launcher_hid_state *s, int pro) {
    memset(s, 0, sizeof *s); s->pro = pro;
    s2a_hpp_cal_default(&s->cl); s2a_hpp_cal_default(&s->cr);
    if (!pro) s2a_hidg_init(&s->g, NULL);
}
void s2a_launcher_hid_has_axis(s2a_launcher_hid_state *s, uint32_t page, uint32_t usage) {
    int a = s2a_hidg_axis_of(page, usage); if (a >= 0) s->g.has[a] = 1;
}
// 同宿主 value_cb（Pro 简单报告）/ generic_value_cb（通用手柄）
void s2a_launcher_hid_value(s2a_launcher_hid_state *s, uint32_t page, uint32_t usage, long v, long min, long max) {
    if (!s->pro) { s2a_hidg_value(&s->g, page, usage, v, min, max); return; }
    if (s->full) return;
    if (page == 9) { uint32_t b = s2a_hpp_button_bit((int)usage); if (v) s->buttons |= b; else s->buttons &= ~b; }
    else if (page == 1) switch (usage) {
        case 0x30: s->ax[0] = s2a_hpp_axis(v, min, max, 0); break;
        case 0x31: s->ax[1] = s2a_hpp_axis(v, min, max, 1); break;
        case 0x32: case 0x33: s->ax[2] = s2a_hpp_axis(v, min, max, 0); break;   // Switch 样式手柄没有模拟扳机：Z / Rx 只会是右摇杆横轴
        case 0x35: case 0x34: s->ax[3] = s2a_hpp_axis(v, min, max, 1); break;
        case 0x39: s->hat = s2a_hpp_hat_bits(v, min, max); break;
        default: break;
    }
}
// 同宿主 report_cb：r 首字节是报告号；0x30 / 0x21 回 1
int s2a_launcher_hid_report(s2a_launcher_hid_state *s, const uint8_t *r, size_t n) {
    if (!s->pro) return 0;
    uint32_t bt; int16_t ax[4];
    if (!s2a_hpp_pro_parse(r, n, &s->cl, &s->cr, &bt, ax)) return 0;
    if (r[0] == 0x30 && !s->full) { s->full = 1; s->hat = 0; }
    if (s->full) { s->buttons = bt; memcpy(s->ax, ax, sizeof ax); }
    return 1;
}
void s2a_launcher_hid_state_pad(const s2a_launcher_hid_state *s, s2a_launcher_hid_pad *out) {
    if (s->pro) { out->buttons = s->buttons | s->hat; out->lx = s->ax[0]; out->ly = s->ax[1]; out->rx = s->ax[2]; out->ry = s->ax[3]; return; }
    int16_t st[4]; s2a_hidg_sticks(&s->g, st);
    out->buttons = s2a_hidg_buttons(&s->g); out->lx = st[0]; out->ly = st[1]; out->rx = st[2]; out->ry = st[3];
}

// ---- 设备（主线程的运行循环里收回调；读在主线程，锁只防回调与读交错）----
typedef struct { IOHIDDeviceRef dev; uint64_t entry; char name[96]; s2a_launcher_hid_state st; uint8_t rep[64]; } hid_dev;
enum { HID_MAX = 8 };
static hid_dev g_hd[HID_MAX];
static IOHIDManagerRef g_mgr;
static pthread_mutex_t g_hmu = PTHREAD_MUTEX_INITIALIZER;

static void value_cb(void *ctx, IOReturn r, void *sender, IOHIDValueRef value) {
    (void)sender; if (r != kIOReturnSuccess) return;
    IOHIDElementRef e = IOHIDValueGetElement(value);
    pthread_mutex_lock(&g_hmu); hid_dev *d = ctx;
    if (d->dev) s2a_launcher_hid_value(&d->st, IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e), IOHIDValueGetIntegerValue(value), IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e));
    pthread_mutex_unlock(&g_hmu);
}
static void report_cb(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id, uint8_t *rep, CFIndex n) {
    (void)r; (void)sender; (void)type;
    if (n < 1 || (id != 0x30 && id != 0x21)) return;
    uint8_t b[64]; size_t m = (size_t)n;
    if (rep[0] == id) { if (m > sizeof b) m = sizeof b; memcpy(b, rep, m); }
    else { b[0] = (uint8_t)id; if (m > sizeof b - 1) m = sizeof b - 1; memcpy(b + 1, rep, m); m++; }   // 有的路径不带报告号：补上（同宿主）
    pthread_mutex_lock(&g_hmu); hid_dev *d = ctx;
    if (d->dev) s2a_launcher_hid_report(&d->st, b, m);
    pthread_mutex_unlock(&g_hmu);
}
static void attach(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    char name[96] = ""; CFStringRef pn = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
    if (pn) CFStringGetCString(pn, name, sizeof name, kCFStringEncodingUTF8);
    int vid = 0; CFNumberRef nv = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey)); if (nv) CFNumberGetValue(nv, kCFNumberIntType, &vid);
    int pro = s2a_hidg_is_pro(name);
    if (!pro && s2a_hidg_native_vendor(vid)) return;   // 微软 / 索尼 / 任天堂的通用手柄归 GameController（同宿主 attach、启动器 HIDFallbackPads.hostReads）
    uint64_t entry = 0; IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(dev), &entry);
    pthread_mutex_lock(&g_hmu);
    hid_dev *d = NULL;
    for (int i = 0; i < HID_MAX; i++) if (g_hd[i].dev && (g_hd[i].dev == dev || (entry && g_hd[i].entry == entry))) { pthread_mutex_unlock(&g_hmu); return; }   // 每条匹配条件各给一次
    for (int i = 0; i < HID_MAX && !d; i++) if (!g_hd[i].dev) d = &g_hd[i];
    if (!d) { pthread_mutex_unlock(&g_hmu); return; }
    memset(d, 0, sizeof *d); d->dev = dev; d->entry = entry; snprintf(d->name, sizeof d->name, "%s", name);
    s2a_launcher_hid_state_init(&d->st, pro);
    if (!pro) { NSArray *els = CFBridgingRelease(IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone));
        for (id o in els) { IOHIDElementRef e = (__bridge IOHIDElementRef)o; s2a_launcher_hid_has_axis(&d->st, IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e)); } }
    pthread_mutex_unlock(&g_hmu);
    IOHIDDeviceRegisterInputValueCallback(dev, value_cb, d);
    if (pro) IOHIDDeviceRegisterInputReportCallback(dev, d->rep, sizeof d->rep, report_cb, d);
}
static void detach(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    pthread_mutex_lock(&g_hmu);
    for (int i = 0; i < HID_MAX; i++) if (g_hd[i].dev == dev) memset(&g_hd[i], 0, sizeof g_hd[i]);
    pthread_mutex_unlock(&g_hmu);
}

void s2a_launcher_hid_open(void) {
    if (g_mgr) return;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!m) return;
    NSArray *match = @[@{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
                       @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)}];
    IOHIDManagerSetDeviceMatchingMultiple(m, (__bridge CFArrayRef)match);
    IOHIDManagerRegisterDeviceMatchingCallback(m, attach, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(m, detach, NULL);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);   // 共享打开：游戏里的宿主照样能开同一只
    g_mgr = m;
}
void s2a_launcher_hid_close(void) {
    if (!g_mgr) return;
    IOHIDManagerUnscheduleFromRunLoop(g_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerClose(g_mgr, kIOHIDOptionsTypeNone); CFRelease(g_mgr); g_mgr = NULL;
    pthread_mutex_lock(&g_hmu); memset(g_hd, 0, sizeof g_hd); pthread_mutex_unlock(&g_hmu);
}
int s2a_launcher_hid_read(s2a_launcher_hid_pad *out, int max) {
    int n = 0;
    pthread_mutex_lock(&g_hmu);
    for (int i = 0; i < HID_MAX && n < max; i++) if (g_hd[i].dev) {
        s2a_launcher_hid_state_pad(&g_hd[i].st, &out[n]); snprintf(out[n].name, sizeof out[n].name, "%s", g_hd[i].name); out[n].pro = g_hd[i].st.pro; n++; }
    pthread_mutex_unlock(&g_hmu);
    return n;
}
s2a_launcher_hid_state *s2a_launcher_hid_state_new(int pro) { s2a_launcher_hid_state *s = malloc(sizeof *s); if (s) s2a_launcher_hid_state_init(s, pro); return s; }
void s2a_launcher_hid_state_free(s2a_launcher_hid_state *s) { free(s); }
