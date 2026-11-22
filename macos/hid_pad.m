// 兜底手柄（#934）：GameController 认不出的 HID 手柄。
//   起因：授权第三方「… Pro Controller」（蓝牙 HID，厂商 / 产品号报 0x0 / 0x0）在系统里有设备、GameController 不枚举它，
//   游戏里完全没反应。GameController 靠厂商 / 产品号认手柄，号是 0 的永远认不出，所以这里按 HID 元素直读。
//   两支：名字带「Pro Controller」的走 Switch Pro 协议（切 0x30 完整报告、读校准与体感，下面 report_cb）；其余通用手柄（谷歌 Stadia 蓝牙、
//   八位堂 D-input 等）按位置映射直读（hid_generic.h，照参考实现 nxnative（MIT）），不发任何输出报告。
//   占不占玩家位由 front_mac.m 每拍按 s2a_hidg_route 判：GameController 已列出同名就让位，不会变成两个玩家。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <GameController/GameController.h>
#define S2A_XBOX_GIP_IOKIT 1
#include "hid_pad.h"
#include "xbox_gip_relay.h"
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

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

// ---- Switch Pro 协议（#934 11-15）----
// 读不到出厂校准（第三方「… Pro Controller」常不回 SPI 0x603D，#1264 PowerA）：中心 2048、行程起点 1003，之后按实际推到的最远处放大
//   （同参考实现 SDL3 hidapi_switch.c：缺省行程 = 中心 × 0.7，摇杆范围再从它的 0.7 起、随读数扩大）。原先死用 1600 不放大，
//   手柄实际推满不到 1600 时推到底也只算推了一部分（移动慢、菜单上下够不到门槛）
void s2a_pro_cal_default(s2a_pro_cal *c) { c->cx = c->cy = 2048; c->xmax = c->ymax = c->xmin = c->ymin = 1003; }
static int cal12(const uint8_t *d, int i) { return i & 1 ? (d[i / 2 * 3 + 1] >> 4) | (d[i / 2 * 3 + 2] << 4) : d[i / 2 * 3] | ((d[i / 2 * 3 + 1] & 0xF) << 8); }   // 9 字节 = 6 个 12 位值
int s2a_pro_cal_parse(const uint8_t d[18], s2a_pro_cal *l, s2a_pro_cal *r) {
    int v[12]; for (int i = 0; i < 6; i++) { v[i] = cal12(d, i); v[6 + i] = cal12(d + 9, i); }
    int blank = 1; for (int i = 0; i < 12; i++) if (v[i] != 0xFFF && v[i] != 0) blank = 0;
    if (blank) return 0;
    // 左：上行程 x y、中心 x y、下行程 x y；右：中心 x y、下行程 x y、上行程 x y（字段次序两边不同，照协议文档）
    *l = (s2a_pro_cal){(uint16_t)v[2], (uint16_t)v[3], (uint16_t)v[0], (uint16_t)v[1], (uint16_t)v[4], (uint16_t)v[5]};
    *r = (s2a_pro_cal){(uint16_t)v[6], (uint16_t)v[7], (uint16_t)v[10], (uint16_t)v[11], (uint16_t)v[8], (uint16_t)v[9]};
    return 1;
}
int16_t s2a_pro_axis(int v, int center, int above, int below) {
    int dv = v - center; double f = dv > 0 ? (above > 0 ? (double)dv / above : 0) : (below > 0 ? (double)dv / below : 0);
    if (f > 1) f = 1; if (f < -1) f = -1;
    return (int16_t)(f * 32767.0);
}
// 行程随读数扩大：这一拍离中心比记下的行程还远，就把它当新的行程（推到底就是满量程），再按行程换算
int16_t s2a_pro_axis_grow(int v, int center, uint16_t *above, uint16_t *below) {
    int dv = v - center;
    if (dv > *above) *above = (uint16_t)dv;
    if (-dv > *below) *below = (uint16_t)-dv;
    return s2a_pro_axis(v, center, *above, *below);
}
int s2a_pro_parse(const uint8_t *r, size_t n, s2a_pro_cal *l, s2a_pro_cal *rc, uint32_t *buttons, int16_t ax[4]) {
    if (n < 12 || (r[0] != 0x30 && r[0] != 0x21)) return 0;
    uint8_t a = r[3], m = r[4], b = r[5]; uint32_t o = 0;
    if (a & 0x01) o |= B_WEST; if (a & 0x02) o |= B_NORTH; if (a & 0x04) o |= B_SOUTH; if (a & 0x08) o |= B_EAST; if (a & 0x40) o |= B_R; if (a & 0x80) o |= B_ZR;
    if (m & 0x01) o |= B_MINUS; if (m & 0x02) o |= B_PLUS; if (m & 0x04) o |= B_RSTICK; if (m & 0x08) o |= B_LSTICK;
    if (b & 0x01) o |= B_DOWN; if (b & 0x02) o |= B_UP; if (b & 0x04) o |= B_RIGHT; if (b & 0x08) o |= B_LEFT; if (b & 0x40) o |= B_L; if (b & 0x80) o |= B_ZL;
    *buttons = o;
    int lx = r[6] | ((r[7] & 0xF) << 8), ly = (r[7] >> 4) | (r[8] << 4), rx = r[9] | ((r[10] & 0xF) << 8), ry = (r[10] >> 4) | (r[11] << 4);
    ax[0] = s2a_pro_axis_grow(lx, l->cx, &l->xmax, &l->xmin); ax[1] = s2a_pro_axis_grow(ly, l->cy, &l->ymax, &l->ymin);   // 0x30 报告里 Y 向上为正，与 GameController 同向
    ax[2] = s2a_pro_axis_grow(rx, rc->cx, &rc->xmax, &rc->xmin); ax[3] = s2a_pro_axis_grow(ry, rc->cy, &rc->ymax, &rc->ymin);
    return 1;
}
uint8_t s2a_pro_player_lights(int slot) { return slot < 0 ? 0x1 : slot >= 3 ? 0xF : (uint8_t)((1u << (slot + 1)) - 1); }

// ---- Xbox 有线手柄 GIP 协议（#1406，实现收敛在 xbox_gip_relay.h 与启动器中继共用）----
int s2a_is_xbox_gip(int vid, int pid) { return s2a_xbox_gip_is_device(vid, pid); }
int s2a_gip_ack(const uint8_t *r, size_t n, uint8_t ack[13]) { return s2a_xbox_gip_build_ack(r, n, ack); }
int s2a_gip_parse(const uint8_t *r, size_t n, uint32_t *buttons, int16_t ax[4]) { return s2a_xbox_gip_parse_report(r, n, buttons, ax); }

typedef struct { IOHIDDeviceRef dev; uint32_t buttons, hat; int16_t ax[4]; char name[96];
    int pro, vid, gc_hint, joined, is_xbox, xbox_relay; uint8_t relay_slot; uint64_t entry, attach_us; s2a_hidg g;   // pro：走 Switch Pro 协议那一支；g：通用手柄的状态（hid_generic.h）；joined：通用手柄按过键；is_xbox：走 Xbox GIP 协议；xbox_relay：由 S2Arm 启动器中继
    int full; uint8_t cnt, rep[64]; s2a_pro_cal cl, cr;
    int betop_ns, betop_left_logged; int16_t betop_left[2]; uint64_t betop_left_us;
    s2a_pad_motion motion; uint64_t motion_us; int imu_said; uint32_t logged; } hp_dev;   // motion：0x30 报告里的最后一组 IMU（motion_us = 收到时刻，0 = 没有）   // full：已收到 0x30 报告（之后不再用 HID 元素那一路）；cnt：子命令包序号
static hp_dev g_dev[S2A_HID_PAD_MAX];
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static void value_cb(void *ctx, IOReturn r, void *sender, IOHIDValueRef value) {
    (void)r; (void)sender;
    IOHIDElementRef e = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
    long v = IOHIDValueGetIntegerValue(value), min = IOHIDElementGetLogicalMin(e), max = IOHIDElementGetLogicalMax(e);
    pthread_mutex_lock(&g_mu);
    hp_dev *d = ctx;
    if (d->dev && !d->full) {
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

static int g_hid_log;   // S2A_HID_LOG=1（开发用）：每次按下都记；缺省每颗键只记第一次（进诊断，玩家不用设变量）
// 通用手柄（hid_generic.h）：按位置映射，首次按下才算加入（joined，front_mac.m 才给它玩家位）
static void generic_value_cb(void *ctx, IOReturn r, void *sender, IOHIDValueRef value) {
    (void)sender;
    if (r != kIOReturnSuccess) return;
    IOHIDElementRef e = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
    long v = IOHIDValueGetIntegerValue(value), min = IOHIDElementGetLogicalMin(e), max = IOHIDElementGetLogicalMax(e);
    pthread_mutex_lock(&g_mu);
    hp_dev *d = ctx;
    if (d->dev && !d->pro) {
        uint32_t was = d->g.held;
        s2a_hidg_value(&d->g, page, usage, v, min, max);
        if (page == kHIDPage_Button && usage >= 1 && usage <= 32 && (d->g.held & ~was)) {   // 每颗键第一次按下记一行（量小、缺省就进诊断）：按键号 → 映射到的 Switch 键，按错键时照这行改按键设置
            uint32_t bit = 1u << (usage - 1);
            if (g_hid_log || !(d->logged & bit)) { d->logged |= bit; static const char *const nm[S2A_HIDG_BUTTONS] = {"A", "B", "X", "Y", "左摇杆按下", "右摇杆按下", "L", "R", "ZL", "ZR", "+", "−", "左", "上", "右", "下"};
                const char *to = "没映射"; for (int b = 0; b < S2A_HIDG_BUTTONS; b++) if (d->g.map[b] == usage) { to = nm[b]; break; }
                fprintf(stderr, "[输入] 通用手柄 %s：按下 HID 按键号 %u → Switch %s\n", d->name, usage, to); }
        }
        int joined = s2a_hidg_joined(d->joined, 0, s2a_hidg_buttons(&d->g));
        if (joined && !d->joined) fprintf(stderr, "[输入] 通用手柄 %s：第一次按键，加入玩家\n", d->name);
        d->joined = joined;
    }
    pthread_mutex_unlock(&g_mu);
}

static int16_t rd16le(const uint8_t *p) { return (int16_t)(p[0] | p[1] << 8); }
// 0x30 完整报告：报告号 + 计时 + 电量 + 按键 3 + 摇杆 6 + 振动 1 = 13 字节后是 3 组 IMU（每组 12 字节：加速度 xyz、角速度 xyz，5 ms 一组），取最后一组。
//   量程同一代 Pro 出厂（±8 g、±2000 度/秒）：加速度 0.000244 g / 计数、角速度 0.06103 度/秒 / 计数；轴向同 joycon_imu.m 的 Pro（参考 SDL3 hidapi_switch.c，zlib）
int s2a_pro_imu(const uint8_t *r, size_t n, s2a_pad_motion *out) {
    if (!r || n < 13 + 36 || r[0] != 0x30) return 0;
    const uint8_t *s = r + 13 + 24;
    float ax = rd16le(s + 0) * 0.000244f, ay = rd16le(s + 2) * 0.000244f, az = rd16le(s + 4) * 0.000244f;
    float gx = rd16le(s + 6) * 0.06103f, gy = rd16le(s + 8) * 0.06103f, gz = rd16le(s + 10) * 0.06103f;
    out->acceleration_x = -ay; out->acceleration_y = ax; out->acceleration_z = az;
    out->gyro_x = -gy; out->gyro_y = gx; out->gyro_z = gz;
    return 1;
}
static uint64_t hp_now_us(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000; }

// 原始输入报告（报告号在首字节）：0x30 = 完整报告（按键 + 12 位摇杆）；0x21 = 子命令应答（同样带按键摇杆，SPI 读应答带校准数据）
static void report_cb(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id, uint8_t *rep, CFIndex n) {
    (void)r; (void)sender; (void)type;
    if (n < 1 || (id != 0x30 && id != 0x21)) return;
    uint8_t b[64]; size_t m = (size_t)n;
    if (rep[0] == id) { if (m > sizeof b) m = sizeof b; memcpy(b, rep, m); }
    else { b[0] = (uint8_t)id; if (m > sizeof b - 1) m = sizeof b - 1; memcpy(b + 1, rep, m); m++; }   // 有的路径不带报告号：补上
    pthread_mutex_lock(&g_mu);
    hp_dev *d = ctx;
    if (d->dev) {
        if (id == 0x21 && m >= 20 + 18 && b[14] == 0x10 && b[15] == 0x3D && b[16] == 0x60) {   // SPI 读 0x603D 应答：出厂摇杆校准
            s2a_pro_cal l, rc; if (s2a_pro_cal_parse(b + 20, &l, &rc)) { d->cl = l; d->cr = rc;
                fprintf(stderr, "[输入] 兜底手柄 %s：出厂摇杆校准 左 中心 %u/%u 行程 +%u/-%u +%u/-%u，右 中心 %u/%u\n", d->name, l.cx, l.cy, l.xmax, l.xmin, l.ymax, l.ymin, rc.cx, rc.cy); } }
        uint32_t bt; int16_t ax[4];
        if (s2a_pro_parse(b, m, &d->cl, &d->cr, &bt, ax)) {
            if (id == 0x30 && !d->full) { d->full = 1; d->hat = 0; fprintf(stderr, "[输入] 兜底手柄 %s：收到完整报告 0x30，改按 Switch Pro 协议读（摇杆 12 位、按校准换算）\n", d->name); }
            if (d->full) { d->buttons = bt; memcpy(d->ax, ax, sizeof ax); }
            if (d->betop_ns && id == 0x30) {
                memcpy(d->betop_left, ax, sizeof d->betop_left);
                d->betop_left_us = hp_now_us();
            }
        }
        s2a_pad_motion mo;
        if (id == 0x30 && s2a_pro_imu(b, m, &mo) && (mo.acceleration_x != 0 || mo.acceleration_y != 0 || mo.acceleration_z != 0)) {   // 全 0 = 手柄没开 IMU / 不带陀螺仪
            mo.host_timestamp_us = hp_now_us(); d->motion = mo; d->motion_us = mo.host_timestamp_us;
            if (!d->imu_said) { d->imu_said = 1; fprintf(stderr, "[输入] 兜底手柄 %s：报告里有六轴（陀螺仪 / 加速度），按玩家体感交给游戏\n", d->name); } }
    }
    pthread_mutex_unlock(&g_mu);
}
// Switch Pro 子命令：输出报告 0x01 = [0x01, 序号, 8 字节空振动, 子命令号, 参数…]（49 字节），delay_ms 后在主线程发
static void pro_subcmd_later(hp_dev *d, IOHIDDeviceRef dev, uint8_t cmd, const uint8_t *arg, size_t n, int delay_ms) {
    uint8_t p[49] = {0x01, 0, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, cmd}; if (n > sizeof p - 11) n = sizeof p - 11; memcpy(p + 11, arg, n);
    NSData *pk = [NSData dataWithBytes:p length:sizeof p]; CFRetain(dev);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay_ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&g_mu); int live = d->dev == dev; uint8_t c = d->cnt++ & 0xF; pthread_mutex_unlock(&g_mu);
        if (live) { uint8_t q[49]; memcpy(q, pk.bytes, sizeof q); q[1] = c;
            IOReturn r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x01, q, sizeof q);
            if (r != kIOReturnSuccess) fprintf(stderr, "[输入] 兜底手柄：子命令 0x%02x 发送失败 0x%x（手柄不认 Switch Pro 协议时照旧按 HID 元素读）\n", q[10], r); }
        CFRelease(dev);
    });
}
static void attach(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    CFStringRef pn = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
    char name[96] = "";
    if (pn) CFStringGetCString(pn, name, sizeof name, kCFStringEncodingUTF8);
    int vid = 0, pid = 0; CFNumberRef n;
    if ((n = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey)))) CFNumberGetValue(n, kCFNumberIntType, &vid);
    if ((n = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey)))) CFNumberGetValue(n, kCFNumberIntType, &pid);
    NSString *transport = (__bridge id)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey));
    NSString *address = (__bridge id)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDSerialNumberKey));
    int betop_ns = [transport isKindOfClass:NSString.class] && [address isKindOfClass:NSString.class] &&
        s2a_hidg_is_betop_ns(vid, pid, transport.UTF8String, address.UTF8String) &&
        IOHIDDeviceGetProperty(dev, CFSTR("GCSyntheticDevice")) != kCFBooleanTrue;
    int pro = betop_ns || s2a_hidg_is_pro(name);
    // 微软 / 索尼 / 任天堂的通用手柄系统自己认（名字未必等于 HID 产品名，按名字让位认不出同一只），这里不接；记一行便于诊断（#1276）
    if (!pro && s2a_hidg_native_vendor(vid)) { fprintf(stderr, "[输入] HID 游戏手柄：%s（厂商 / 产品号 0x%x / 0x%x）是系统原生认得的厂商，交给 GameController\n", name[0] ? name : "（没名字）", vid, pid); return; }
    // IOHIDManager 按每条匹配条件各给一次、每次是新的 IOHIDDeviceRef：按 I/O Registry 条目认同一只（同参考实现），不变成两个玩家
    uint64_t entry = 0; IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(dev), &entry);
    int gc_hint = [GCController supportsHIDDevice:dev];   // 每只只问一次（调用不便宜）
    pthread_mutex_lock(&g_mu);
    hp_dev *d = NULL;
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) if (g_dev[i].dev && (g_dev[i].dev == dev || (entry && g_dev[i].entry == entry))) { pthread_mutex_unlock(&g_mu); return; }
    for (int i = 0; i < S2A_HID_PAD_MAX && !d; i++) if (!g_dev[i].dev && !g_dev[i].is_xbox) d = &g_dev[i];
    if (!d) { pthread_mutex_unlock(&g_mu); fprintf(stderr, "[输入] 兜底手柄：已满 %d 只，%s 不接\n", S2A_HID_PAD_MAX, name); return; }
    memset(d, 0, sizeof *d); d->dev = dev; snprintf(d->name, sizeof d->name, "%s", name);
    d->betop_ns = betop_ns; d->pro = pro; d->vid = vid; d->gc_hint = gc_hint; d->entry = entry; d->attach_us = hp_now_us();
    if (!pro) {
        const char *map = getenv("S2A_HID_MAP"); if (!map) map = getenv("DM_HID_MAP");   // 也认参考实现的变量名
        s2a_hidg_init(&d->g, map);
        NSArray *els = CFBridgingRelease(IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone));
        for (id o in els) { IOHIDElementRef e = (__bridge IOHIDElementRef)o; int a = s2a_hidg_axis_of(IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e)); if (a >= 0) d->g.has[a] = 1; }
    }
    pthread_mutex_unlock(&g_mu);
    if (!pro) {
        IOHIDDeviceRegisterInputValueCallback(dev, generic_value_cb, d);
        fprintf(stderr, "[输入] 通用手柄：接上 %s（厂商 / 产品号 0x%x / 0x%x，系统%s认得）：按位置映射直读（缺省八位堂 D-input 编号%s），第一次按键才占玩家位；"
                "键位不对在启动器的按键设置里改（每颗键第一次按下会记一行它的编号和映射到哪个键）\n", name[0] ? name : "（没名字）", vid, pid, gc_hint ? "说" : "不",
                getenv("S2A_HID_MAP") || getenv("DM_HID_MAP") ? "，已按 S2A_HID_MAP 覆盖（开发 / 对照用：玩家从启动器起游戏时这个变量带不进来）" : "");
        return;
    }
    if (betop_ns) fprintf(stderr, "[输入] 北通宙斯 NS：匹配蓝牙前缀 00:90:E0（057E:2009）\n");
    s2a_pro_cal_default(&d->cl); s2a_pro_cal_default(&d->cr);
    IOHIDDeviceRegisterInputValueCallback(dev, value_cb, d);
    IOHIDDeviceRegisterInputReportCallback(dev, d->rep, sizeof d->rep, report_cb, d);
    fprintf(stderr, "[输入] 兜底手柄：接上 %s（厂商 / 产品号 0x%x / 0x%x，GameController 不认）：先按 HID 元素直读，同时发 Switch Pro 子命令切完整报告、点玩家灯\n", name, vid, pid);
    // 子命令之间隔 50 ms（蓝牙手柄连发会丢）：读出厂摇杆校准 → 切完整报告 0x30 → 点玩家灯
    int slot = (int)(d - g_dev);
    static const uint8_t spi[] = {0x3D, 0x60, 0x00, 0x00, 18};
    pro_subcmd_later(d, dev, 0x10, spi, sizeof spi, 0);
    pro_subcmd_later(d, dev, 0x03, (const uint8_t[]){0x30}, 1, 50);
    pro_subcmd_later(d, dev, 0x40, (const uint8_t[]){0x01}, 1, 150);   // 打开 IMU（第三方 Switch 模式手柄带陀螺仪的才有读数；不带的照样回全 0，上面按全 0 不收）
    pro_subcmd_later(d, dev, 0x30, (const uint8_t[]){s2a_pro_player_lights(slot)}, 1, 100);
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

int s2a_usb_has_hid_child(io_service_t dev) {
    return s2a_xbox_usb_has_hid_child(dev);
}

static int s2a_xbox_is_gc_listed(void) {
    for (GCController *gc in [GCController controllers]) {
        NSString *prod = [gc.productCategory lowercaseString];
        NSString *vend = [gc.vendorName lowercaseString];
        if ([prod containsString:@"xbox"] || [vend containsString:@"microsoft"] || [vend containsString:@"xbox"]) {
            return 1;
        }
    }
    return 0;
}

typedef struct {
    io_service_t dev;
    hp_dev *d;
    int vid, pid;
} s2a_xbox_worker_ctx;

static void *s2a_xbox_gip_thread(void *arg) {
    s2a_xbox_worker_ctx *ctx = (s2a_xbox_worker_ctx *)arg;
    io_service_t dev = ctx->dev;
    hp_dev *d = ctx->d;
    int vid = ctx->vid, pid = ctx->pid;
    free(ctx);

    // 检查是否已有系统 HID 驱动挂载或 GCController 枚举；有则放弃 Seize，交由原生路径
    if (s2a_usb_has_hid_child(dev) || s2a_xbox_is_gc_listed()) {
        fprintf(stderr, "[输入] 兜底手柄 %s：系统已识别该手柄（HID / GameController），不进行 Seize 抢占\n", d->name);
        goto cleanup_slot;
    }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(dev, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) {
        fprintf(stderr, "[输入] 兜底手柄 %s：IOCreatePlugInInterfaceForService 失败 0x%x\n", d->name, kr);
        goto cleanup_slot;
    }

    IOUSBDeviceInterface **devIntf = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID*)&devIntf);
    (*plug)->Release(plug);
    if (!devIntf) {
        fprintf(stderr, "[输入] 兜底手柄 %s：QueryInterface kIOUSBDeviceInterfaceID 失败\n", d->name);
        goto cleanup_slot;
    }

    int opened = 0;
    int logged_busy = 0;
    char last_owner[128] = "";
    while (d->is_xbox && !opened) {
        if (s2a_usb_has_hid_child(dev) || s2a_xbox_is_gc_listed()) {
            fprintf(stderr, "[输入] 兜底手柄 %s：系统已识别该手柄（HID / GameController），不进行 Seize 抢占\n", d->name);
            break;
        }
        kr = (*devIntf)->USBDeviceOpenSeize(devIntf);
        if (kr != kIOReturnSuccess) kr = (*devIntf)->USBDeviceOpen(devIntf);
        if (kr == kIOReturnSuccess) {
            opened = 1;
            break;
        }
        if (kr == kIOReturnExclusiveAccess) {
            char owner[128] = "";
            s2a_xbox_usb_exclusive_owner(dev, owner, sizeof(owner));
            if (!logged_busy || strcmp(owner, last_owner) != 0) {
                if (owner[0]) fprintf(stderr, "[输入] 兜底手柄 %s：USB 接口正被 %s 占用，等待释放（关闭该进程后自动接管）...\n", d->name, owner);
                else fprintf(stderr, "[输入] 兜底手柄 %s：USB 接口被外部进程占用，等待释放...\n", d->name);
                snprintf(last_owner, sizeof(last_owner), "%s", owner);
                logged_busy = 1;
            }
            uint64_t check_entry = 0;
            if (IORegistryEntryGetRegistryEntryID(dev, &check_entry) != KERN_SUCCESS) {
                kr = kIOReturnNoDevice;
                break;
            }
            usleep(1000000);
        } else {
            break;
        }
    }
    if (!opened) {
        if (kr != kIOReturnSuccess) fprintf(stderr, "[输入] 兜底手柄 %s：打开 USB 设备失败 0x%08x\n", d->name, kr);
        (*devIntf)->Release(devIntf);
        goto cleanup_slot;
    }

    (*devIntf)->SetConfiguration(devIntf, 1);

    // 精确匹配 GIP 接口（bInterfaceClass=0xFF, bInterfaceSubClass=0x47, bInterfaceProtocol=0xD0）
    IOUSBFindInterfaceRequest intfReq = {
        .bInterfaceClass = 0xFF,
        .bInterfaceSubClass = 0x47,
        .bInterfaceProtocol = 0xD0,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare
    };
    io_iterator_t intfIter = 0;
    kr = (*devIntf)->CreateInterfaceIterator(devIntf, &intfReq, &intfIter);
    if (kr != kIOReturnSuccess || !intfIter) {
        (*devIntf)->USBDeviceClose(devIntf);
        (*devIntf)->Release(devIntf);
        goto cleanup_slot;
    }
    io_service_t intfService = 0;
    IOUSBInterfaceInterface **intf = NULL;
    int inPipe = -1, outPipe = -1;

    while ((intfService = IOIteratorNext(intfIter)) != 0) {
        IOCFPlugInInterface **intfPlug = NULL;
        kr = IOCreatePlugInInterfaceForService(intfService, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &intfPlug, &score);
        IOObjectRelease(intfService);
        if (kr != KERN_SUCCESS || !intfPlug) continue;

        IOUSBInterfaceInterface **candidate = NULL;
        (*intfPlug)->QueryInterface(intfPlug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID*)&candidate);
        (*intfPlug)->Release(intfPlug);
        if (!candidate) continue;

        kr = (*candidate)->USBInterfaceOpen(candidate);
        if (kr != kIOReturnSuccess) {
            (*candidate)->Release(candidate);
            continue;
        }

        UInt8 numPipes = 0;
        (*candidate)->GetNumEndpoints(candidate, &numPipes);
        int curIn = -1, curOut = -1;
        for (int p = 1; p <= numPipes; p++) {
            UInt8 direction = 0, number = 0, transferType = 0, interval = 0;
            UInt16 maxPacketSize = 0;
            (*candidate)->GetPipeProperties(candidate, p, &direction, &number, &transferType, &maxPacketSize, &interval);
            if (direction == kUSBIn && transferType == kUSBInterrupt) curIn = p;
            if (direction == kUSBOut && transferType == kUSBInterrupt) curOut = p;
        }

        if (curIn > 0 && curOut > 0) {
            intf = candidate;
            inPipe = curIn;
            outPipe = curOut;
            break;
        }

        (*candidate)->USBInterfaceClose(candidate);
        (*candidate)->Release(candidate);
    }
    IOObjectRelease(intfIter);

    if (!intf) {
        fprintf(stderr, "[输入] 兜底手柄 %s：未找到匹配 GIP (0xFF/0x47/0xD0) 且具备端点的接口\n", d->name);
        (*devIntf)->USBDeviceClose(devIntf);
        (*devIntf)->Release(devIntf);
        goto cleanup_slot;
    }

    uint8_t gip_seq = 0;
    if (outPipe > 0) {
        uint8_t init_power[5], init_wake[5];
        s2a_xbox_gip_build_power(s2a_xbox_gip_next_seq(&gip_seq), init_power);
        s2a_xbox_gip_build_wake(s2a_xbox_gip_next_seq(&gip_seq), init_wake);
        IOReturn w1 = (*intf)->WritePipe(intf, outPipe, init_power, sizeof(init_power));
        IOReturn w2 = (*intf)->WritePipe(intf, outPipe, init_wake, sizeof(init_wake));
        if (w1 != kIOReturnSuccess || w2 != kIOReturnSuccess) {
            fprintf(stderr, "[输入] 兜底手柄 %s：GIP 唤醒写包异常（power=0x%08x wake=0x%08x）\n", d->name, w1, w2);
        }
    }

    fprintf(stderr, "[输入] 兜底手柄 %s（厂商 / 产品号 0x%04x / 0x%04x）：有线 Xbox 手柄接上，GIP 唤醒成功，直读按键与摇杆\n",
            d->name, vid, pid);

    uint8_t report[64];
    UInt32 size = sizeof(report);
    uint32_t recoverable_errs = 0;
    while (d->is_xbox) {
        size = sizeof(report);
        kr = (*intf)->ReadPipe(intf, inPipe > 0 ? inPipe : 1, report, &size);
        int action = s2a_xbox_gip_classify_io_error((uint32_t)kr, &recoverable_errs, 5);
        if (action == S2A_XBOX_GIP_IO_FATAL) {
            fprintf(stderr, "[输入] 兜底手柄 %s：USB ReadPipe 结束 0x%08x\n", d->name, kr);
            break;
        }
        if (action == S2A_XBOX_GIP_IO_RECOVER) {
            fprintf(stderr, "[输入] 兜底手柄 %s：USB ReadPipe 可恢复错误 0x%08x（第 %u 次），清理 stall 并重发 GIP 唤醒\n",
                    d->name, kr, recoverable_errs);
            (*intf)->ClearPipeStall(intf, inPipe > 0 ? inPipe : 1);
            if (outPipe > 0) {
                uint8_t init_power[5], init_wake[5];
                s2a_xbox_gip_build_power(s2a_xbox_gip_next_seq(&gip_seq), init_power);
                s2a_xbox_gip_build_wake(s2a_xbox_gip_next_seq(&gip_seq), init_wake);
                (*intf)->WritePipe(intf, outPipe, init_power, sizeof(init_power));
                (*intf)->WritePipe(intf, outPipe, init_wake, sizeof(init_wake));
            }
            continue;
        }

        uint8_t ack[13];
        int ack_len = s2a_gip_ack(report, size, ack);
        if (ack_len > 0 && outPipe > 0) {
            IOReturn wkr = (*intf)->WritePipe(intf, outPipe, ack, ack_len);
            if (wkr == kIOUSBPipeStalled) {
                (*intf)->ClearPipeStall(intf, outPipe);
                (*intf)->WritePipe(intf, outPipe, ack, ack_len);
            }
        }
        if (s2a_xbox_gip_is_announce(report, size) && outPipe > 0) {
            fprintf(stderr, "[输入] 兜底手柄 %s：收到手柄重通告 0x02，重新发送 GIP 唤醒包\n", d->name);
            uint8_t init_power[5], init_wake[5];
            s2a_xbox_gip_build_power(s2a_xbox_gip_next_seq(&gip_seq), init_power);
            s2a_xbox_gip_build_wake(s2a_xbox_gip_next_seq(&gip_seq), init_wake);
            (*intf)->WritePipe(intf, outPipe, init_power, sizeof(init_power));
            (*intf)->WritePipe(intf, outPipe, init_wake, sizeof(init_wake));
        }

        uint32_t bt = 0;
        int16_t ax[4] = {0};
        if (s2a_gip_parse(report, size, &bt, ax)) {
            pthread_mutex_lock(&g_mu);
            if (d->is_xbox) {
                d->buttons = bt;
                memcpy(d->ax, ax, sizeof(d->ax));
                if (!d->joined && bt != 0) {
                    d->joined = 1;
                    fprintf(stderr, "[输入] 兜底手柄 %s：收到第一个非零按键，加入玩家\n", d->name);
                }
            }
            pthread_mutex_unlock(&g_mu);
        }
    }

    fprintf(stderr, "[输入] 兜底手柄：断开 %s\n", d->name);
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    (*devIntf)->USBDeviceClose(devIntf);
    (*devIntf)->Release(devIntf);

cleanup_slot:
    IOObjectRelease(dev);
    pthread_mutex_lock(&g_mu);
    memset(d, 0, sizeof(*d));
    pthread_mutex_unlock(&g_mu);
    return NULL;
}

static void s2a_xbox_device_matched(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    io_service_t dev;
    while ((dev = IOIteratorNext(iterator)) != 0) {
        int vid = 0, pid = 0;
        CFNumberRef nVid = (CFNumberRef)IORegistryEntryCreateCFProperty(dev, CFSTR(kUSBVendorID), kCFAllocatorDefault, 0);
        CFNumberRef nPid = (CFNumberRef)IORegistryEntryCreateCFProperty(dev, CFSTR(kUSBProductID), kCFAllocatorDefault, 0);
        if (nVid) { CFNumberGetValue(nVid, kCFNumberIntType, &vid); CFRelease(nVid); }
        if (nPid) { CFNumberGetValue(nPid, kCFNumberIntType, &pid); CFRelease(nPid); }

        if (!s2a_is_xbox_gip(vid, pid)) {
            IOObjectRelease(dev);
            continue;
        }

        if (s2a_usb_has_hid_child(dev) || s2a_xbox_is_gc_listed()) {
            fprintf(stderr, "[输入] 兜底手柄：发现 Xbox 手柄（0x%04x:0x%04x），但系统已有 HID / GameController 驱动挂载，交给系统原生路径\n", vid, pid);
            IOObjectRelease(dev);
            continue;
        }

        uint64_t entry = 0;
        IORegistryEntryGetRegistryEntryID(dev, &entry);
        pthread_mutex_lock(&g_mu);
        hp_dev *d = NULL;
        for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
            if ((g_dev[i].dev || g_dev[i].is_xbox) && entry && g_dev[i].entry == entry) {
                d = (hp_dev *)-1;
                break;
            }
        }
        if (d == (hp_dev *)-1) {
            pthread_mutex_unlock(&g_mu);
            IOObjectRelease(dev);
            continue;
        }
        for (int i = 0; i < S2A_HID_PAD_MAX && !d; i++) {
            if (!g_dev[i].dev && !g_dev[i].is_xbox) d = &g_dev[i];
        }
        if (!d) {
            pthread_mutex_unlock(&g_mu);
            fprintf(stderr, "[输入] 兜底手柄：已满 %d 只，有线 Xbox 手柄不接\n", S2A_HID_PAD_MAX);
            IOObjectRelease(dev);
            continue;
        }

        memset(d, 0, sizeof(*d));
        d->is_xbox = 1;
        d->pro = 1;
        d->vid = vid;
        d->entry = entry;
        d->attach_us = hp_now_us();
        d->joined = 0;
        snprintf(d->name, sizeof(d->name), "Xbox Controller");
        CFStringRef pn = (CFStringRef)IORegistryEntryCreateCFProperty(dev, CFSTR(kUSBProductString), kCFAllocatorDefault, 0);
        if (pn) {
            CFStringGetCString(pn, d->name, sizeof(d->name), kCFStringEncodingUTF8);
            CFRelease(pn);
        }
        pthread_mutex_unlock(&g_mu);

        s2a_xbox_worker_ctx *ctx = (s2a_xbox_worker_ctx *)malloc(sizeof(*ctx));
        ctx->dev = dev;
        ctx->d = d;
        ctx->vid = vid;
        ctx->pid = pid;
        pthread_t th;
        if (pthread_create(&th, NULL, s2a_xbox_gip_thread, ctx) != 0) {
            free(ctx);
            pthread_mutex_lock(&g_mu);
            memset(d, 0, sizeof(*d));
            pthread_mutex_unlock(&g_mu);
            IOObjectRelease(dev);
        } else {
            pthread_detach(th);
        }
    }
}

int s2a_mac_hid_pad_apply_xbox_relay(const void *raw, size_t len) {
    if (!raw || len != sizeof(s2a_xbox_gip_relay_packet)) return 0;
    s2a_xbox_gip_relay_packet pkt;
    memcpy(&pkt, raw, sizeof(pkt));
    if (!s2a_xbox_gip_relay_packet_valid(&pkt)) return 0;

    pthread_mutex_lock(&g_mu);
    hp_dev *d = NULL;
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
        if (g_dev[i].is_xbox && g_dev[i].xbox_relay && g_dev[i].relay_slot == pkt.slot) {
            d = &g_dev[i];
            break;
        }
    }
    if (!(pkt.flags & S2A_XBOX_GIP_FLAG_CONNECTED)) {
        if (d) {
            fprintf(stderr, "[输入] 兜底手柄：断开 %s（启动器中继）\n", d->name);
            memset(d, 0, sizeof(*d));
        }
        pthread_mutex_unlock(&g_mu);
        return 1;
    }
    if (!d) {
        for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
            if (!g_dev[i].dev && !g_dev[i].is_xbox) { d = &g_dev[i]; break; }
        }
        if (!d) {
            pthread_mutex_unlock(&g_mu);
            return 0;
        }
        memset(d, 0, sizeof(*d));
        d->is_xbox = 1;
        d->xbox_relay = 1;
        d->relay_slot = pkt.slot;
        d->pro = 1;
        d->vid = (int)pkt.vid;
        d->attach_us = hp_now_us();
        d->joined = 0;
        char safe_name[sizeof(d->name)];
        memcpy(safe_name, pkt.name, sizeof(safe_name));
        safe_name[sizeof(safe_name) - 1] = '\0';
        snprintf(d->name, sizeof(d->name), "%s", safe_name[0] ? safe_name : "Xbox Controller");
        fprintf(stderr, "[输入] 兜底手柄 %s（厂商 / 产品号 0x%04x / 0x%04x）：已通过启动器中继接上有线 Xbox 手柄\n",
                d->name, pkt.vid, pkt.pid);
    }
    d->buttons = pkt.buttons;
    memcpy(d->ax, pkt.ax, sizeof(d->ax));
    if (!d->joined && pkt.buttons != 0) {
        d->joined = 1;
        fprintf(stderr, "[输入] 兜底手柄 %s：收到第一个非零按键，加入玩家\n", d->name);
    }
    pthread_mutex_unlock(&g_mu);
    return 1;
}

void s2a_mac_hid_pad_clear_xbox_relay(void) {
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
        if (g_dev[i].is_xbox && g_dev[i].xbox_relay) {
            memset(&g_dev[i], 0, sizeof(g_dev[i]));
        }
    }
    pthread_mutex_unlock(&g_mu);
}

int s2a_mac_hid_pad_read_xbox_relay_fd(int fd) {
    if (fd < 0) return -1;
    s2a_xbox_gip_relay_packet pkt;
    while (s2a_xbox_gip_read_exact(fd, &pkt, sizeof(pkt)) == 0) {
        if (!s2a_mac_hid_pad_apply_xbox_relay(&pkt, sizeof(pkt))) break;
    }
    s2a_mac_hid_pad_clear_xbox_relay();
    return 0;
}

static void *s2a_xbox_relay_client_thread(void *arg) {
    char *path = (char *)arg;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (!path || strlen(path) >= sizeof(addr.sun_path)) {
        free(path);
        return NULL;
    }
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
    free(path);

    int logged_connect = 0;
    for (;;) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) { usleep(500000); continue; }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            if (!logged_connect) {
                fprintf(stderr, "[输入] 兜底手柄：已连上 S2Arm 启动器 Xbox GIP 中继通道\n");
                logged_connect = 1;
            }
            s2a_mac_hid_pad_read_xbox_relay_fd(fd);
            close(fd);
            usleep(200000);
        } else {
            close(fd);
            usleep(500000);
        }
    }
    return NULL;
}

void s2a_mac_hid_pad_start(void) {
    static int started; if (started) return; started = 1;
    const char *lg = getenv("S2A_HID_LOG"); if (!lg) lg = getenv("DM_HID_LOG"); g_hid_log = lg && atoi(lg);
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

    // Xbox 有线手柄 GIP 兜底（#1406）：
    //   若启动器已提供中继通道（S2A_XBOX_GIP_SOCKET），说明常驻 S2Arm.app 独占持有 USB 设备，宿主直接连中继收按键 / 摇杆，
    //   避免切游戏释放 USB 时被后台浏览器（Chromium XboxDataFetcherMac）抢占；否则回退为宿主直接通过 IOKit 打开 USB。
    const char *xbox_relay = getenv("S2A_XBOX_GIP_SOCKET");
    if (xbox_relay && xbox_relay[0]) {
        char *dup = strdup(xbox_relay);
        if (dup) {
            pthread_t th;
            if (pthread_create(&th, NULL, s2a_xbox_relay_client_thread, dup) == 0) pthread_detach(th);
            else free(dup);
        }
        return;
    }

    static IONotificationPortRef g_gip_notify_port;
    static io_iterator_t g_gip_matched_iter;
    g_gip_notify_port = IONotificationPortCreate(kIOMainPortDefault);
    if (g_gip_notify_port) {
        CFRunLoopSourceRef src = IONotificationPortGetRunLoopSource(g_gip_notify_port);
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
        CFMutableDictionaryRef gip_match = IOServiceMatching(kIOUSBDeviceClassName);
        kern_return_t gkr = IOServiceAddMatchingNotification(g_gip_notify_port, kIOFirstMatchNotification, gip_match, s2a_xbox_device_matched, NULL, &g_gip_matched_iter);
        if (gkr == KERN_SUCCESS) {
            s2a_xbox_device_matched(NULL, g_gip_matched_iter);
        }
    }
}

int s2a_mac_hid_pad_read(s2a_hid_pad out[S2A_HID_PAD_MAX]) {
    int n = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
        hp_dev *d = &g_dev[i]; if ((!d->dev && !d->is_xbox)) continue;
        int pro_flag = d->is_xbox ? 0 : d->pro;
        if (!s2a_hidg_joined(d->joined, pro_flag, 0)) continue;   // 通用手柄及 Xbox GIP 没按过键不列（不占玩家位）
        s2a_hid_pad *o = &out[n++];
        if (d->pro) { o->buttons = d->buttons | d->hat; o->lx = d->ax[0]; o->ly = d->ax[1]; o->rx = d->ax[2]; o->ry = d->ax[3]; }
        else { int16_t st[4]; s2a_hidg_sticks(&d->g, st); o->buttons = s2a_hidg_buttons(&d->g); o->lx = st[0]; o->ly = st[1]; o->rx = st[2]; o->ry = st[3]; }
        o->id = &g_dev[i]; snprintf(o->name, sizeof o->name, "%s", d->name);
        o->pro = d->pro; o->vid = d->vid; o->gc_hint = d->gc_hint; o->age_us = hp_now_us() - d->attach_us;
    }
    pthread_mutex_unlock(&g_mu);
    return n;
}

int s2a_mac_hid_betop_left(uint64_t entry, int16_t left[2]) {
    if (!entry) return 0;
    int fresh = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
        hp_dev *d = &g_dev[i];
        if (!d->dev || !d->betop_ns || d->entry != entry) continue;
        fresh = d->betop_left_us && hp_now_us() - d->betop_left_us < 200000;
        if (fresh) {
            memcpy(left, d->betop_left, sizeof d->betop_left);
            if (!d->betop_left_logged) {
                d->betop_left_logged = 1;
                fprintf(stderr, "[输入] 北通宙斯 NS：已按设备匹配，左摇杆使用 HID 0x30\n");
            }
        }
        break;
    }
    pthread_mutex_unlock(&g_mu);
    return fresh;
}

int s2a_mac_hid_pad_motion(const void *id, s2a_pad_motion *out) {
    int ok = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < S2A_HID_PAD_MAX; i++) {
        hp_dev *d = &g_dev[i];
        if (id != (const void *)d || (!d->dev && !d->is_xbox) || !d->motion_us) continue;
        if (hp_now_us() - d->motion_us < 200000) { *out = d->motion; ok = 1; }
        break;
    }
    pthread_mutex_unlock(&g_mu);
    return ok;
}
