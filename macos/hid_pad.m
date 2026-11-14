// 兜底手柄（#934）：GameController 认不出的 Switch 样式 HID 手柄。
//   起因：授权第三方「… Pro Controller」（蓝牙 HID，厂商 / 产品号报 0x0 / 0x0）在系统里有设备、GameController 不枚举它，
//   游戏里完全没反应。GameController 靠厂商 / 产品号认手柄，号是 0 的永远认不出，所以这里按 HID 元素直读。
//   只接名字带「Pro Controller」的手柄（Switch 简易 HID 模式的键号含义是确定的；别的通用手柄键号各家不同，硬套会按错键）；
//   GameController 已认出的同名手柄由 front_mac.m 跳过，不会变成两个玩家。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include "hid_pad.h"
#include <pthread.h>
#include <string.h>

enum { B_EAST = 1u << 0, B_SOUTH = 1u << 1, B_NORTH = 1u << 2, B_WEST = 1u << 3, B_LSTICK = 1u << 4, B_RSTICK = 1u << 5,
       B_L = 1u << 6, B_R = 1u << 7, B_ZL = 1u << 8, B_ZR = 1u << 9, B_PLUS = 1u << 10, B_MINUS = 1u << 11,
       B_LEFT = 1u << 12, B_UP = 1u << 13, B_RIGHT = 1u << 14, B_DOWN = 1u << 15 };

uint32_t s2a_hid_pad_switch_button_bit(int usage) {
    static const uint32_t map[] = {0, B_SOUTH, B_EAST, B_WEST, B_NORTH, B_L, B_R, B_ZL, B_ZR, B_MINUS, B_PLUS, B_LSTICK, B_RSTICK};
    return usage > 0 && usage < (int)(sizeof map / sizeof *map) ? map[usage] : 0;   // 13 Home、14 截图不进游戏键位
}
uint32_t s2a_hid_pad_hat_bits(long v, long min, long max) {
    static const uint32_t dir[8] = {B_UP, B_UP | B_RIGHT, B_RIGHT, B_DOWN | B_RIGHT, B_DOWN, B_DOWN | B_LEFT, B_LEFT, B_UP | B_LEFT};
    if (v < min || v > max || max - min < 7) return 0;
    long i = v - min; return i < 8 ? dir[i] : 0;
}
int16_t s2a_hid_pad_axis(long v, long min, long max, int invert) {
    if (max <= min) return 0;
    double f = 2.0 * (double)(v - min) / (double)(max - min) - 1.0;
    if (f < -1) f = -1; if (f > 1) f = 1;
    if (invert) f = -f;
    return (int16_t)(f * 32767.0);
}

typedef struct { IOHIDDeviceRef dev; uint32_t buttons, hat; int16_t ax[4]; char name[96]; } hp_dev;
static hp_dev g_dev[S2A_HID_PAD_MAX];
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static void value_cb(void *ctx, IOReturn r, void *sender, IOHIDValueRef value) {
    (void)r; (void)sender;
    IOHIDElementRef e = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
    long v = IOHIDValueGetIntegerValue(value), min = IOHIDElementGetLogicalMin(e), max = IOHIDElementGetLogicalMax(e);
    pthread_mutex_lock(&g_mu);
    hp_dev *d = ctx;
    if (d->dev) {
        if (page == kHIDPage_Button) { uint32_t b = s2a_hid_pad_switch_button_bit((int)usage); if (v) d->buttons |= b; else d->buttons &= ~b; }
        else if (page == kHIDPage_GenericDesktop) switch (usage) {
            case kHIDUsage_GD_X: d->ax[0] = s2a_hid_pad_axis(v, min, max, 0); break;
            case kHIDUsage_GD_Y: d->ax[1] = s2a_hid_pad_axis(v, min, max, 1); break;
            case kHIDUsage_GD_Z: case kHIDUsage_GD_Rx: d->ax[2] = s2a_hid_pad_axis(v, min, max, 0); break;   // 右摇杆：Switch 样式手柄没有模拟扳机，Z / Rx 只会是右摇杆横轴
            case kHIDUsage_GD_Rz: case kHIDUsage_GD_Ry: d->ax[3] = s2a_hid_pad_axis(v, min, max, 1); break;
            case kHIDUsage_GD_Hatswitch: d->hat = s2a_hid_pad_hat_bits(v, min, max); break;
            default: break;
        }
    }
    pthread_mutex_unlock(&g_mu);
}

static void attach(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    CFStringRef pn = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
    char name[96] = "";
    if (pn) CFStringGetCString(pn, name, sizeof name, kCFStringEncodingUTF8);
    if (!strcasestr(name, "Pro Controller")) return;
    int vid = 0, pid = 0; CFNumberRef n;
    if ((n = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey)))) CFNumberGetValue(n, kCFNumberIntType, &vid);
    if ((n = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey)))) CFNumberGetValue(n, kCFNumberIntType, &pid);
    if (vid == 0x057e) return;   // 任天堂原装：GameController 认得（六轴另有 joycon_imu.m）
    pthread_mutex_lock(&g_mu);
    hp_dev *d = NULL;
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) if (g_dev[i].dev == dev) { pthread_mutex_unlock(&g_mu); return; }
    for (int i = 0; i < S2A_HID_PAD_MAX && !d; i++) if (!g_dev[i].dev) d = &g_dev[i];
    if (!d) { pthread_mutex_unlock(&g_mu); fprintf(stderr, "[输入] 兜底手柄：已满 %d 只，%s 不接\n", S2A_HID_PAD_MAX, name); return; }
    memset(d, 0, sizeof *d); d->dev = dev; snprintf(d->name, sizeof d->name, "%s", name);
    pthread_mutex_unlock(&g_mu);
    IOHIDDeviceRegisterInputValueCallback(dev, value_cb, d);
    fprintf(stderr, "[输入] 兜底手柄：接上 %s（厂商 / 产品号 0x%x / 0x%x，GameController 不认，按 HID 元素直读）\n", name, vid, pid);
}
static void detach(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) if (g_dev[i].dev == dev) {
        fprintf(stderr, "[输入] 兜底手柄：断开 %s\n", g_dev[i].name);
        IOHIDDeviceRegisterInputValueCallback(dev, NULL, NULL);
        memset(&g_dev[i], 0, sizeof g_dev[i]);
    }
    pthread_mutex_unlock(&g_mu);
}

void s2a_mac_hid_pad_start(void) {
    static int started; if (started) return; started = 1;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *match = @[@{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
                       @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)}];
    IOHIDManagerSetDeviceMatchingMultiple(m, (__bridge CFArrayRef)match);
    IOHIDManagerRegisterDeviceMatchingCallback(m, attach, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(m, detach, NULL);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    // 只读不独占（同 joycon_imu.m）：系统 / 别的程序照样收得到；打不开（没有输入监控权限等）只记一行，键盘鼠标与别的手柄不受影响
    IOReturn r = IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) fprintf(stderr, "[输入] 兜底手柄：打开 HID 监听失败 0x%x（GameController 认得的手柄不受影响）\n", r);
}

int s2a_mac_hid_pad_read(s2a_hid_pad out[S2A_HID_PAD_MAX]) {
    int n = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
        hp_dev *d = &g_dev[i]; if (!d->dev) continue;
        s2a_hid_pad *o = &out[n++];
        o->buttons = d->buttons | d->hat; o->lx = d->ax[0]; o->ly = d->ax[1]; o->rx = d->ax[2]; o->ry = d->ax[3];
        o->id = &g_dev[i]; snprintf(o->name, sizeof o->name, "%s", d->name);
    }
    pthread_mutex_unlock(&g_mu);
    return n;
}
