// Joy-Con / Pro Controller 六轴：IOHID 直读（macOS GameController 对 Joy-Con 的 motion 恒为 nil）。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include "joycon_imu.h"
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach_time.h>

// D2（#520）：按设备记，不再按左 / 右各一格——两套以上的一代 Joy-Con（最多 8 位玩家 = 8 只单只，留些余量给 Pro / 重连）各占一格，不互相顶掉
enum { JC_L = 0, JC_R = 1, JC_N = 16 };
enum { JC_PID_L = 0x2006, JC_PID_R = 0x2007, JC_PID_PRO = 0x2009 };

typedef struct {
    IOHIDDeviceRef device;
    uint8_t *report_buf;
    uint8_t pkt;
    int slot;                 // JC_L / JC_R：这只是左只还是右只 / Pro
    int product_id;
    char id[64];              // 设备 id（序列号 = 蓝牙地址；启动器 Gen1HIDWatcher.deviceID 同一套），跨进程认同一只
    s2a_pad_motion sample;
    int known;
    int vib_on;               // 发过「开震动」子命令 0x48（#520 E 一代手柄 HID 震动）
    uint64_t rumble_gen;      // 每发一包加一：1 秒后还是这一包就补中性停下
    uint32_t pad_buttons;     // D2：这一只自己的按键 / 摇杆（s2a_joycon1_decode；两只被 macOS 合成一个时也各算一位玩家）
    int32_t pad_sticks[4];
    int pad_side, pad_known;
    uint64_t pad_us;
    uint8_t pad_raw[S2A_JC1_RAW];   // 最近一笔标准全报告的按键 / 摇杆原始字节（按设备读的一对拼成一份，s2a_joycon1_pair_decode）
    int pad_raw_known;
} jc_dev;

static IOHIDManagerRef g_mgr;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static jc_dev g_dev[JC_N];
static _Atomic int g_want;
static _Atomic int g_pad_want;   // D2：要按设备读按键（开着就让手柄出标准全报告 0x30，体感关着也一样）
static int g_started;
static uint8_t g_pkt_global;

static int16_t rd16(const uint8_t *p) { return (int16_t)(p[0] | (p[1] << 8)); }

static uint64_t now_us(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / (tb.denom * 1000ull);
}

static void send_sub(jc_dev *d, uint8_t cmd, uint8_t arg) {
    if (!d->device) return;
    uint8_t report[0x40];
    memset(report, 0, sizeof report);
    report[0] = 0x01;                         // OutputType.subcommand
    report[1] = (d->pkt++ & 0x0f);
    report[2] = 0x00; report[3] = 0x01; report[4] = 0x00; report[5] = 0x40;   // rumble neutral
    report[6] = 0x00; report[7] = 0x01; report[8] = 0x00; report[9] = 0x40;
    report[10] = cmd;
    report[11] = arg;
    IOHIDDeviceSetReport(d->device, kIOHIDReportTypeOutput, 0x01, report, sizeof report);
}

// Joy-Con 报告里的加速度 / 角速度 → 近似 NS2 原始坐标（g、度/秒）。
// 竖握：L/R 机身轴不同；Fit Boxing 横握挥拳时主要靠角速度幅值，先保证有读数。
static void decode_imu(int slot, int product_id, const uint8_t *s, s2a_pad_motion *out) {
    float ax = rd16(s + 0) * 0.000244f;
    float ay = rd16(s + 2) * 0.000244f;
    float az = rd16(s + 4) * 0.000244f;
    float gx = rd16(s + 6) * 0.06103f;
    float gy = rd16(s + 8) * 0.06103f;
    float gz = rd16(s + 10) * 0.06103f;
    // 映射到「正面法线 = z、上沿 = y、右 = x」的近似：与常见 SDL hidapi_nintendo 竖握一致
    if (product_id == JC_PID_L) {
        out->acceleration_x = ay; out->acceleration_y = -ax; out->acceleration_z = az;
        out->gyro_x = gy; out->gyro_y = -gx; out->gyro_z = gz;
    } else {
        // Joy-Con (R) / Pro
        out->acceleration_x = -ay; out->acceleration_y = ax; out->acceleration_z = az;
        out->gyro_x = -gy; out->gyro_y = gx; out->gyro_z = gz;
    }
    (void)slot;
    out->host_timestamp_us = now_us();
}

static void apply_report(jc_dev *d, uint32_t report_id, const uint8_t *report, CFIndex len) {
    if (!d || (report_id != 0x30 && report_id != 0x3f)) return;
    // D2：按键 / 摇杆按设备存（0x30 全报告、0x3F 简单报告都认）
    uint32_t buttons; int32_t sticks[4]; int side;
    if (s2a_joycon1_decode(d->product_id, report, (size_t)len, &buttons, sticks, &side)) {
        pthread_mutex_lock(&g_mu);
        d->pad_buttons = buttons; memcpy(d->pad_sticks, sticks, sizeof sticks); d->pad_side = side; d->pad_known = 1; d->pad_us = now_us();
        CFIndex at = (len > 0 && report[0] == report_id) ? 1 : 0;
        if (report_id == 0x30 && len - at >= S2A_JC1_RAW) { memcpy(d->pad_raw, report + at, S2A_JC1_RAW); d->pad_raw_known = 1; }
        pthread_mutex_unlock(&g_mu);
    }
    if (report_id != 0x30) return;
    int off = (len > 0 && report[0] == 0x30) ? 1 : 0;
    if (len - off < 48) return;
    // 标准全报告带 3 组 IMU（5 ms 间隔）；取最后一组
    const uint8_t *s = report + off + 36;
    s2a_pad_motion m = {0};
    decode_imu(d->slot, d->product_id, s, &m);
    pthread_mutex_lock(&g_mu);
    d->sample = m;
    d->known = 1;
    pthread_mutex_unlock(&g_mu);
}

static void report_cb(void *context, IOReturn result, void *sender, IOHIDReportType type,
                      uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    (void)result; (void)sender; (void)type;
    apply_report((jc_dev *)context, reportID, report, reportLength);
}

static int side_for_pid(int pid) {
    if (pid == JC_PID_L) return JC_L;
    if (pid == JC_PID_R || pid == JC_PID_PRO) return JC_R;
    return -1;
}

// 设备 id：序列号（一代 Joy-Con 走蓝牙时是蓝牙地址，重连不变）；没有就用 LocationID。启动器 Gen1HIDWatcher.deviceID 照同一套，两边认同一只
static void s2a_joycon_device_id(IOHIDDeviceRef device, char out[64]) {
    out[0] = 0;
    CFTypeRef serial = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDSerialNumberKey));
    if (serial && CFGetTypeID(serial) == CFStringGetTypeID() && CFStringGetCString(serial, out, 64, kCFStringEncodingUTF8) && out[0]) return;
    CFTypeRef loc = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDLocationIDKey));
    uint32_t v = 0;
    if (loc && CFGetTypeID(loc) == CFNumberGetTypeID() && CFNumberGetValue(loc, kCFNumberSInt32Type, &v)) { snprintf(out, 64, "loc-%x", v); return; }
    snprintf(out, 64, "dev-%p", (void *)device);   // 都没有：只在本进程认得（启动器那边分不出这只，照常自动排进来）
}

static jc_dev *find_id_locked(const char *id) {
    if (!id || !id[0]) return NULL;
    for (int i = 0; i < JC_N; i++) if (g_dev[i].device && !strcmp(g_dev[i].id, id)) return &g_dev[i];
    return NULL;
}

static void attach_device(IOHIDDeviceRef device) {
    CFNumberRef pid_cf = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    int pid = 0;
    if (pid_cf) CFNumberGetValue(pid_cf, kCFNumberIntType, &pid);
    int slot = side_for_pid(pid);
    if (slot < 0) return;

    pthread_mutex_lock(&g_mu);
    jc_dev *d = NULL;
    for (int i = 0; i < JC_N; i++) if (g_dev[i].device == device) { pthread_mutex_unlock(&g_mu); return; }
    for (int i = 0; i < JC_N && !d; i++) if (!g_dev[i].device) d = &g_dev[i];
    if (!d) {   // 物理上 16 只都占着：这只照旧走 GameController（按键能用，只是没有按设备读 / HID 体感震动）
        pthread_mutex_unlock(&g_mu);
        fprintf(stderr, "[输入] 一代 Joy-Con HID：已经接了 %d 只，这只不再按设备读（照系统手柄用）\n", JC_N);
        return;
    }
    if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        pthread_mutex_unlock(&g_mu);
        return;
    }
    d->device = device;
    d->product_id = pid;
    d->slot = slot;
    s2a_joycon_device_id(device, d->id);
    d->pkt = g_pkt_global++;
    d->report_buf = calloc(1, 0x200);
    if (!d->report_buf) {   // 审计 P2-271：分配失败不能按 0x200 字节登记回调（报告来了写进空指针）；这只手柄本次不接，关掉设备、槽位清空
        IOHIDDeviceClose(device, kIOHIDOptionsTypeNone); memset(d, 0, sizeof *d);
        pthread_mutex_unlock(&g_mu);
        fprintf(stderr, "【红】Joy-Con 体感：读报告缓冲分配失败，这只手柄本次不接体感\n");
        return;
    }
    IOHIDDeviceRegisterInputReportCallback(device, d->report_buf, 0x200, report_cb, d);
    int want = atomic_load(&g_want);
    pthread_mutex_unlock(&g_mu);

    if (!want && atomic_load(&g_pad_want)) send_sub(d, 0x03, 0x30);   // D2：只要按键也要全报告
    if (want) {
        send_sub(d, 0x40, 1);     // enable IMU
        send_sub(d, 0x03, 0x30);  // standard full
        fprintf(stderr, "[输入] Joy-Con HID 六轴：已接通 %s（shared）\n",
                pid == JC_PID_L ? "L" : (pid == JC_PID_PRO ? "Pro" : "R"));
    }
}

static void detach_device(IOHIDDeviceRef device) {
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < JC_N; i++) {
        jc_dev *d = &g_dev[i];
        if (d->device != device) continue;
        IOHIDDeviceRegisterInputReportCallback(d->device, d->report_buf, 0x200, NULL, NULL);
        IOHIDDeviceClose(d->device, kIOHIDOptionsTypeNone);
        free(d->report_buf);
        memset(d, 0, sizeof *d);
    }
    pthread_mutex_unlock(&g_mu);
}

static void match_cb(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    attach_device(device);
}

static void remove_cb(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    detach_device(device);
}

static void ensure_manager(void) {
    if (g_started) return;
    g_started = 1;
    g_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *match = @[
        @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @(JC_PID_L)},
        @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @(JC_PID_R)},
        @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @(JC_PID_PRO)},
    ];
    IOHIDManagerSetDeviceMatchingMultiple(g_mgr, (__bridge CFArrayRef)match);
    IOHIDManagerRegisterDeviceMatchingCallback(g_mgr, match_cb, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(g_mgr, remove_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(g_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(g_mgr, kIOHIDOptionsTypeNone);
    NSSet *devs = CFBridgingRelease(IOHIDManagerCopyDevices(g_mgr));
    for (id obj in devs) attach_device((__bridge IOHIDDeviceRef)obj);
}

static void apply_enabled_locked(int enabled) {
    for (int i = 0; i < JC_N; i++) {
        jc_dev *d = &g_dev[i];
        if (!d->device) continue;
        if (enabled) {
            send_sub(d, 0x40, 1);
            send_sub(d, 0x03, 0x30);
        } else {
            send_sub(d, 0x40, 0);
            if (!atomic_load(&g_pad_want)) send_sub(d, 0x03, 0x3f);   // D2 还要按键：留在全报告
            d->known = 0;
            memset(&d->sample, 0, sizeof d->sample);
        }
    }
}

void s2a_joycon_imu_set_enabled(int enabled) {
    ensure_manager();
    int on = enabled ? 1 : 0;
    int prev = atomic_exchange(&g_want, on);
    if (prev == on) return;
    pthread_mutex_lock(&g_mu);
    apply_enabled_locked(on);
    pthread_mutex_unlock(&g_mu);
    if (on) fprintf(stderr, "[输入] Joy-Con HID 六轴：开启（GameController 无 motion 时的回退）\n");
    else fprintf(stderr, "[输入] Joy-Con HID 六轴：关闭\n");
}

int s2a_joycon_imu_read(s2a_pad_motion *out_l, s2a_pad_motion *out_r) {
    int mask = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < JC_N; i++) {   // 好几只时取最先接上的左只 / 右只（同改前只有一对时）
        jc_dev *d = &g_dev[i];
        if (!d->device || !d->known || (mask & (1 << d->slot))) continue;
        if (d->slot == JC_L && out_l) *out_l = d->sample;
        if (d->slot == JC_R && out_r) *out_r = d->sample;
        mask |= 1 << d->slot;
    }
    pthread_mutex_unlock(&g_mu);
    return mask;
}

// 一代 Joy-Con / Pro 的 HID 震动（#520 E）：macOS GameController 不给任天堂一代手柄 haptics 时，front_mac.m 交到这里。
//   which：bit0 = 左只、bit1 = 右只、bit2 = Pro；pair[0] / [1] = 左 / 右两侧。
//   第一次先发子命令 0x48 开震动，之后发报告 0x10（只有震动）；1 秒没新的就补一包中性，免得游戏停了还一直震。返回实际发到的位
static void rumble_dev_locked(jc_dev *d, const s2a_pad_vibration pair[2]) {
    if (!d->vib_on) { send_sub(d, 0x48, 1); d->vib_on = 1; }
    // 单只 Joy-Con 只有自己那一侧：取两侧里强的那份放进它那半包（游戏把单只当横握 Pro 时两侧都给）
    s2a_pad_vibration left = pair[0], right = pair[1];
    if (d->product_id != JC_PID_PRO) {
        s2a_pad_vibration strong = left.low_amp + left.high_amp >= right.low_amp + right.high_amp ? left : right;
        left = right = strong;
    }
    uint8_t report[10] = {0x10, (uint8_t)(d->pkt++ & 0x0f)};
    s2a_joycon1_rumble_encode(left, report + 2);
    s2a_joycon1_rumble_encode(right, report + 6);
    IOHIDDeviceSetReport(d->device, kIOHIDReportTypeOutput, 0x10, report, sizeof report);
    uint64_t gen = ++d->rumble_gen;
    IOHIDDeviceRef device = d->device;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&g_mu);
        for (int k = 0; k < JC_N; k++) {
            jc_dev *x = &g_dev[k];
            if (x->device != device || x->rumble_gen != gen) continue;
            uint8_t stop[10] = {0x10, (uint8_t)(x->pkt++ & 0x0f), 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40};
            IOHIDDeviceSetReport(x->device, kIOHIDReportTypeOutput, 0x10, stop, sizeof stop);
        }
        pthread_mutex_unlock(&g_mu);
    });
}
static void rumble_logged(void) {
    static int logged;
    if (!logged) { logged = 1; fprintf(stderr, "[输入] 一代 Joy-Con / Pro：GameController 没有震动，改走 HID 震动\n"); }
}

int s2a_joycon_rumble(int which, const s2a_pad_vibration pair[2]) {
    ensure_manager();
    int sent = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < JC_N; i++) {   // 系统合成的那一对 / 单只 / Pro：照左只、右只、Pro 各发给最先接上的那只（同改前只有一对时）
        jc_dev *d = &g_dev[i];
        int bit = d->product_id == JC_PID_PRO ? 4 : 1 << d->slot;
        if (!d->device || !(which & bit) || (sent & bit)) continue;
        rumble_dev_locked(d, pair);
        sent |= bit;
    }
    pthread_mutex_unlock(&g_mu);
    if (sent) rumble_logged();
    return sent;
}

int s2a_joycon_rumble_id(const char *id, const s2a_pad_vibration pair[2]) {
    ensure_manager();
    pthread_mutex_lock(&g_mu);
    jc_dev *d = find_id_locked(id);
    if (d) rumble_dev_locked(d, pair);
    pthread_mutex_unlock(&g_mu);
    if (d) rumble_logged();
    return d != NULL;
}

// D2（#520，一代 Joy-Con 按设备当玩家）：开 = 让手柄出全报告、按设备记按键；关 = 体感也没开就回简单报告（同改前）
void s2a_joycon_pad_set_enabled(int enabled) {
    ensure_manager();
    int on = enabled ? 1 : 0;
    if (atomic_exchange(&g_pad_want, on) == on) return;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < JC_N; i++) {
        jc_dev *d = &g_dev[i];
        if (!d->device || atomic_load(&g_want)) continue;   // 体感开着时本来就是全报告
        send_sub(d, 0x03, on ? 0x30 : 0x3f);
        if (!on) d->pad_known = 0;
    }
    pthread_mutex_unlock(&g_mu);
    fprintf(stderr, "[输入] 一代 Joy-Con 按设备读按键：%s\n", on ? "开（D2）" : "关");
}

// 现在接着的一代 Joy-Con / Pro（按接上的先后）
int s2a_joycon_list(s2a_joycon_info *out, int max) {
    ensure_manager();
    int n = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < JC_N && n < max; i++) {
        if (!g_dev[i].device) continue;
        memcpy(out[n].id, g_dev[i].id, sizeof out[n].id); out[n].pid = g_dev[i].product_id; n++;
    }
    pthread_mutex_unlock(&g_mu);
    return n;
}

// 读一只（按设备 id）最近的按键 / 摇杆；250 毫秒没新报告当没有。pid 可 NULL
int s2a_joycon_pad_read_id(const char *id, uint32_t *buttons, int32_t sticks[4], int *side, int *pid) {
    pthread_mutex_lock(&g_mu);
    jc_dev *d = find_id_locked(id);
    int ok = d && d->pad_known && now_us() - d->pad_us <= 250000;
    if (ok) { *buttons = d->pad_buttons; memcpy(sticks, d->pad_sticks, sizeof d->pad_sticks); *side = d->pad_side; if (pid) *pid = d->product_id; }
    pthread_mutex_unlock(&g_mu);
    return ok;
}

int s2a_joycon_pad_raw_id(const char *id, uint8_t raw[S2A_JC1_RAW]) {
    pthread_mutex_lock(&g_mu);
    jc_dev *d = find_id_locked(id);
    int ok = d && d->pad_raw_known && now_us() - d->pad_us <= 250000;
    if (ok) memcpy(raw, d->pad_raw, S2A_JC1_RAW);
    pthread_mutex_unlock(&g_mu);
    return ok;
}

int s2a_joycon_imu_read_id(const char *id, s2a_pad_motion *out) {
    pthread_mutex_lock(&g_mu);
    jc_dev *d = find_id_locked(id);
    int ok = d && d->known;
    if (ok) *out = d->sample;
    pthread_mutex_unlock(&g_mu);
    return ok;
}
