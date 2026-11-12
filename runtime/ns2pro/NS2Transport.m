// 原生 Switch 2 Pro BLE：工厂校准输入、顺序命令握手、双侧有界震动 mailbox。
// Native Switch 2 Pro BLE: factory-calibrated input, ordered handshake and a bounded two-side rumble mailbox.
// 协议依据 / Protocol references:
// https://github.com/ndeadly/switch2_controller_research (bluetooth_interface.md, commands.md, hid_reports.md)
// https://github.com/murphyjt/wavebird (BLE / NS2Commands, MIT)
// https://github.com/caqlayan/procon2-mac (BLEController, MIT)
// 仅采用协议布局与校准关系，生命周期和线程模型为本桥独立实现。
// Protocol layouts and calibration relations inform this independently implemented lifecycle and threading model.
// S2Arm contributors 修改（2026）：扫描时长可由 NS2_SCAN_SECONDS 编译期设定；记住的手柄标识可经 S2A_NS2_DEFAULTS_SUITE 存到指定偏好域。
// Modified by S2Arm contributors (2026): build-time NS2_SCAN_SECONDS scan length; remembered-controller identifier may use the S2A_NS2_DEFAULTS_SUITE defaults domain.
/*
MIT License
Copyright (c) 2026 jhaizhou
Copyright (c) 2026 Joshua Murphy
Copyright (c) 2026 Arda Caglayan Ercan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/
#import <CoreBluetooth/CoreBluetooth.h>
#include "NS2Transport.h"
#include <math.h>
#include <pthread.h>
#include <errno.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define LOG(...) do { fprintf(stderr, "[NS2Transport] "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define NS2Localized(key) NSLocalizedStringFromTable((key), @"Transport", nil)
#ifndef NS2_SCAN_SECONDS
#define NS2_SCAN_SECONDS 10
#endif
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static NSString *const serviceUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD0";
static NSString *const inputUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD2";
static NSString *const powerUUID = @"7492866C-EC3E-4619-8258-32755FFCC0F8";
static NSString *const vibrationUUID = @"CC483F51-9258-427D-A939-630C31F72B05";
static NSString *const commandUUID = @"649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005";
static NSString *const responseUUID = @"C765A961-D9D8-4D36-A20A-5315B111836A";
static NSString *const lastReadyPeripheralKey = @"S2ArmNS2ProLastReadyPeripheralIdentifier";
static NSUserDefaults *controllerDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *suite = getenv("S2A_NS2_DEFAULTS_SUITE");
        defaults = suite && *suite ? [[NSUserDefaults alloc] initWithSuiteName:[NSString stringWithUTF8String:suite]] : NSUserDefaults.standardUserDefaults;
    });
    return defaults;
}
// Joy-Con 2 左 / 右各自的震动特征（nd bluetooth_interface.md GATT 表）；上次就绪的型号跟标识一起记，重连时没有广播可认
static NSString *const joyconLeftVibrationUUID = @"289326CB-A471-485D-A8F4-240C14F18241";
static NSString *const joyconRightVibrationUUID = @"FA19B0FB-CD1F-46A7-84A1-BBB09E00C149";
static NSString *const lastReadyKindKey = @"S2ArmNS2ProLastReadyKind";
// 拼对要重连两只：左右各记一个就绪过的标识。上面两项仍记「主只」（Pro / 单只就是那一台，拼上一对是左只），旧记录照样认
static NSString *const lastReadyJoyConKeys[2] = {@"S2ArmNS2ProLastReadyJoyConLeftIdentifier", @"S2ArmNS2ProLastReadyJoyConRightIdentifier"};

// 调用线程只更新固定 mailbox；CB 对象始终局限于串行队列，不逐请求创建 block。
// Caller threads only update the fixed mailbox; CB objects stay on one serial queue, without a block per request.
// 传输层最多两条链路（一台 Pro，或 Joy-Con 2 左右各一只）。wanted / submittedMask / stopMask 按「侧」记：
//   Pro 与单只 Joy-Con 由唯一那条链路包下两侧（与改前同一份逻辑）；拼成一对时左只管第 0 侧、右只管第 1 侧，各按自己的节奏写自己的震动特征。
static pthread_mutex_t stateMu = PTHREAD_MUTEX_INITIALIZER;
static ns2_vibration wanted[2], actual[2];
static uint64_t wantedDeadline[2];
static BOOL active, ready, terminal = YES;
static unsigned wantedMask, submittedMask, stopMask;
static uint64_t rumbleRequests, quantizedSilentRequests;
static dispatch_queue_t bleQueue;
static dispatch_group_t shutdownGroup;
static dispatch_source_t mailboxWake;
static char queueKey;
static float rumbleGain = 2;
static ns2_info deviceInfo;
static ns2_motion latestMotion, latestMotionLeft;
static ns2_mouse latestMouse[2];   // Joy-Con 2 光学鼠标最近一笔，[0] 左只、[1] 右只（拼成一对时两只各一份），只经 ns2_get_mouse_side 读   // latestMotionLeft：拼对时左只的六轴（latestMotion 是右只的），只经 ns2_get_motion_left 读
static BOOL motionRequested;
static ns2_state_callback stateCallback;
static ns2_status_callback statusCallback;
static ns2_motion_callback motionCallback;
static void *callbackContext;
static BOOL disposing;
// 每条链路里调用线程也要读到的部分（stateMu 保护），下标就是链路槽位。ready 即改前单链路的 ready；
// present = 已初始化且未失败（streamReady && !sessionFailed），决定输出形态（单只横握 / 拼对竖握）和震动归属。
typedef struct {
    BOOL used, ready, present, failed;
    ns2_kind kind;
    ns2_info info;
    ns2_state last;   // 最近一次已校准、未转横握的状态（拼对合并用；不 ready 时为 0）
} ns2_link_shared;
static ns2_link_shared linkShared[2];
static void emit_state(ns2_state value) { if (stateCallback) stateCallback(&value, callbackContext); }
static void emit_status(ns2_status value, NSString *message) { if (statusCallback) statusCallback(value, message.UTF8String, callbackContext); }
static void on_queue(dispatch_block_t block) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bleQueue = dispatch_queue_create("ns2pro.transport.ble", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(bleQueue, &queueKey, &queueKey, NULL);
    });
    if (dispatch_get_specific(&queueKey)) block(); else dispatch_sync(bleQueue, block);
}

typedef struct { unsigned center[2], above[2], below[2]; } ns2_calibration;
static void unpack12(const uint8_t *p, unsigned out[2]) {
    out[0] = p[0] | (p[1] & 15u) << 8; out[1] = p[1] >> 4 | (unsigned)p[2] << 4;
}
static uint32_t le32(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static BOOL uuid_is(CBUUID *uuid, NSString *text) { return [uuid isEqual:[CBUUID UUIDWithString:text]]; }
static BOOL value_effective(ns2_vibration value) {
    ns2_rumble_amplitudes codes = ns2_rumble_amplitude_codes(value, rumbleGain);
    return codes.low || codes.high;
}
static BOOL is_joycon(ns2_kind kind) { return kind == NS2_KIND_JOYCON_L || kind == NS2_KIND_JOYCON_R; }
// 以下 *_locked 由调用方持有 stateMu。
// 两条链路都 present 且一左一右才算拼成一对。
static BOOL pair_locked(void) {
    return linkShared[0].present && linkShared[1].present && is_joycon(linkShared[0].kind) && is_joycon(linkShared[1].kind) &&
        linkShared[0].kind != linkShared[1].kind;
}
// 这条链路负责哪几侧震动：拼对时左只第 0 侧、右只第 1 侧；否则唯一那条包下两侧（Pro / 单只与改前相同）。
static unsigned owned_sides_locked(unsigned slot) {
    if (pair_locked()) return linkShared[slot].kind == NS2_KIND_JOYCON_L ? 1u : 2u;
    // 另一只在出输入、这一只没在用（握手中 / 已失败）：不碰任何一侧，免得失败那一刻把另一只的停止位清掉。Pro 不会走到这里
    if (!linkShared[slot].present && linkShared[slot ^ 1].present) return 0;
    return 3;
}
// 对外信息的「主只」：只有一条就是它；两条都在时依次优先 present、未失败，都一样（拼对）取左只。
static int primary_slot_locked(void) {
    const ns2_link_shared *a = &linkShared[0], *b = &linkShared[1];
    if (!a->used || !b->used) return a->used ? 0 : b->used ? 1 : -1;
    if (a->present != b->present) return a->present ? 0 : 1;
    if (a->failed != b->failed) return a->failed ? 1 : 0;
    return b->kind == NS2_KIND_JOYCON_L ? 1 : 0;
}
static BOOL info_merge_locked(int slot) { return linkShared[slot].used && !linkShared[slot].failed && linkShared[slot].info.connected; }
// 对外 ns2_get_info：只有一条链路时原样是它那份（Pro / 单只与改前同一份数据）；两只 Joy-Con 时以主只为底，
// 两只都已连上且都没失败才合成：名字拼成「左 + 右」，电量取两只里低的那只，连接 / 就绪任一即算；另一只还在连 / 已失败时只报主只。
static void compose_info_locked(void) {
    int primary = primary_slot_locked();
    if (primary < 0) { memset(&deviceInfo, 0, sizeof deviceInfo); return; }
    deviceInfo = linkShared[primary].info;
    if (!info_merge_locked(primary) || !info_merge_locked(primary ^ 1)) return;
    const ns2_info *other = &linkShared[primary ^ 1].info;
    const ns2_info *left = linkShared[primary].kind == NS2_KIND_JOYCON_L ? &linkShared[primary].info : other;
    const ns2_info *right = left == other ? &linkShared[primary].info : other;
    deviceInfo.connected = deviceInfo.connected || other->connected;
    deviceInfo.ready = deviceInfo.ready || other->ready;
    if (left->name[0] && right->name[0]) snprintf(deviceInfo.name, sizeof deviceInfo.name, "%s + %s", left->name, right->name);
    if (other->battery_known && (!deviceInfo.battery_known || other->battery_millivolts < deviceInfo.battery_millivolts)) {
        deviceInfo.battery_known = 1; deviceInfo.battery_millivolts = other->battery_millivolts;
    }
    if (other->battery_level_known && (!deviceInfo.battery_level_known || other->battery_level < deviceInfo.battery_level)) {
        deviceInfo.battery_level_known = 1; deviceInfo.battery_level = other->battery_level;
    }
    if (!deviceInfo.telemetry_error[0]) memcpy(deviceInfo.telemetry_error, other->telemetry_error, sizeof deviceInfo.telemetry_error);
}
static void refresh_locked(void) {
    ready = linkShared[0].ready || linkShared[1].ready;
    compose_info_locked();
}
// 改前 reset_state 的全局部分：丢弃旧物理连接的震动与运动数值。
static void reset_global_locked(void) {
    ready = NO; wantedMask = submittedMask = stopMask = 0;
    rumbleRequests = quantizedSilentRequests = 0;
    memset(&latestMotion, 0, sizeof latestMotion); memset(&latestMotionLeft, 0, sizeof latestMotionLeft); memset(latestMouse, 0, sizeof latestMouse);
    memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
}
// 输出形态在单只 / 拼对之间切换：震动归属变了，丢掉未发的请求、已提交有效幅码的侧安排停止包，运动样本作废；游戏的下一次请求照常进来。
static void reroute_locked(void) {
    memset(wanted, 0, sizeof wanted); wantedMask = 0; stopMask |= submittedMask;
    memset(&latestMotion, 0, sizeof latestMotion); memset(&latestMotionLeft, 0, sizeof latestMotionLeft); memset(latestMouse, 0, sizeof latestMouse);
}
// 一条链路失效 / 重新开始握手：断线后立即丢弃旧物理连接的输入和震动数值。
// 另一条没有在用时等同改前的 reset_state（Pro 永远走这一支）；另一条在用而这条刚才也在用，说明拼对拆开，改走 reroute。
// 返回对外输出是否受影响（需要发零状态）：只有「另一只在出输入、这一只还没就绪过」时不受影响，免得第二只握手失败打断第一只。
static BOOL reset_link_state_locked(unsigned slot) {
    BOOL wasPresent = linkShared[slot].present;
    linkShared[slot].ready = linkShared[slot].present = NO; linkShared[slot].info.ready = 0;
    memset(&linkShared[slot].last, 0, sizeof linkShared[slot].last);
    ns2_decode_report09_accessories(NULL, 0, &linkShared[slot].info);
    BOOL otherPresent = linkShared[slot ^ 1].present;
    if (!otherPresent) reset_global_locked();
    else if (wasPresent) reroute_locked();
    refresh_locked();
    return !otherPresent || wasPresent;
}
static int32_t calibrated_axis(unsigned raw, ns2_calibration cal, unsigned axis) {
    int delta = (int)raw - (int)cal.center[axis];
    double normalized = (double)delta / (delta >= 0 ? cal.above[axis] : cal.below[axis]);
    // 明示 8% 的宿主死区，工厂中心和正负量程分别缩放；不自动学习玩家当前偏转。
    // Use an explicit 8% host deadzone with factory center and separate extents; never learn a held stick as neutral.
    double magnitude = fmin(1.0, fabs(normalized));
    return magnitude <= .08 ? 0 : (int32_t)(copysign((magnitude - .08) / .92, normalized) * NS2_STICK_MAX);
}

typedef NS_ENUM(unsigned, NS2SoftState) {
    NS2SoftRunning, NS2SoftDraining, NS2SoftUnsubscribingPower, NS2SoftPaused, NS2SoftFreshInput
};
@class NS2Link;
// 共用的 CBCentralManager、扫描、计时器与链路槽位；链路之间的输出合并与对外状态在这里汇总。
@interface NS2Bridge : NSObject <CBCentralManagerDelegate> {
@public
    CBCentralManager *central;
    NSMutableDictionary<NSUUID *, NSNumber *> *retryAfter;
    dispatch_source_t timer;
    uint64_t scanDeadline;
    BOOL scanRequested, initialConnectionRequested;
    NS2Link *links[2];
}
- (void)tick;
- (void)processEvents;
- (void)scheduleTimer;
- (void)beginSession;
- (void)scan;
- (void)connectPeripheral:(CBPeripheral *)peripheral name:(NSString *)name RSSI:(NSNumber *)rssi kind:(ns2_kind)kind;
- (int)rescan;
- (int)suspend;
- (int)resume;
- (void)stop;
- (void)dispose;
- (void)stopScanning;
- (NS2Link *)presentLinkOtherThan:(NS2Link *)link;
- (void)report:(ns2_status)status message:(NSString *)message from:(NS2Link *)link;
- (void)pairBroke;
- (void)linkPaused;
- (BOOL)otherResumePending:(NS2Link *)link;
- (void)rememberReady:(NS2Link *)link;
@end
static NS2Bridge *bridge;

// 一台设备的连接：外设、特征、型号、握手进度、校准、暂停 / 恢复状态与本链路的震动节奏。
// 内容即改前 NS2Bridge 的单设备部分，逐方法搬过来；对外状态经 bridge 汇总。
@interface NS2Link : NSObject <CBPeripheralDelegate> {
@public
    unsigned slot;
    CBCentralManager *central;
    CBPeripheral *device;
    CBCharacteristic *input, *power, *vibration, *command, *response;
    ns2_calibration calibration[2];
    ns2_kind kind;   // Pro / Joy-Con 2 左 / 右（广播产品号；重连取上次就绪时记下的）
    NSUInteger step;
    NSData *pendingCommand;
    BOOL awaitingAck, subscribedResponse, streamReady, sessionFailed, preferReport09, imuEnabled, motionCommand, shutdownSent, shutdownEntered;
    uint64_t deadline, linkStarted, lastRumble, reports, reports09, rumblePackets, effectivePackets, stopPackets;
    const char *waitingFor;
    NS2SoftState softState;
    BOOL pauseWanted, pauseStopPending, resumeCounterKnown, powerSubscribePending;
    uint32_t resumeCounter;
    uint64_t pauseStarted, resumeStarted;
    uint8_t sequence;
}
- (NSUInteger)initializationSteps;
- (void)tick;
- (void)processEvents;
- (void)advanceSoftState;
- (void)fail:(NSString *)reason;
- (void)resetLink;
- (void)telemetryFailed:(NSString *)reason;
- (void)publishInput:(NSData *)data report:(unsigned)reportID;
@end

@implementation NS2Link
- (instancetype)initWithSlot:(unsigned)index kind:(ns2_kind)model central:(CBCentralManager *)manager {
    if ((self = [super init])) { slot = index; kind = model; central = manager; }
    return self;
}
// 仍挂在当前 bridge 上；只比指针（同改前的 self != bridge），回调里 shutdown 后立即为假。
- (BOOL)live {
    NS2Bridge *owner = bridge;
    return owner && (owner->links[0] == self || owner->links[1] == self);
}
- (BOOL)canKeep { return streamReady && !sessionFailed && device.state == CBPeripheralStateConnected; }
- (void)attach:(CBPeripheral *)peripheral name:(NSString *)name RSSI:(NSNumber *)rssi {
    // 断线后的异步 stop 可能晚于 resetLink；新连接握手前丢弃旧 mailbox。
    // A disconnect's asynchronous stop may follow resetLink; discard the old mailbox before a new handshake.
    pthread_mutex_lock(&stateMu);
    reset_link_state_locked(slot);
    linkShared[slot].used = YES; linkShared[slot].failed = NO; linkShared[slot].kind = kind;
    ns2_info *info = &linkShared[slot].info;
    memset(info, 0, sizeof *info);
    if (name && ![name getCString:info->name maxLength:sizeof info->name encoding:NSUTF8StringEncoding])
        memset(info->name, 0, sizeof info->name);
    [peripheral.identifier.UUIDString getCString:info->identifier maxLength:sizeof info->identifier encoding:NSUTF8StringEncoding];
    // CoreBluetooth 用 127 表示不可用 RSSI；发现值不代表持续更新的信号强度。
    // CoreBluetooth uses 127 for unavailable RSSI; a discovery value is not a continuously updated signal reading.
    if (rssi && rssi.intValue != 127) { info->rssi_known = 1; info->rssi_dbm = rssi.intValue; }
    refresh_locked();
    pthread_mutex_unlock(&stateMu);
    device = peripheral; device.delegate = self; sessionFailed = NO;
    // 单独限制系统建立 BLE 链路的等待时间；GATT 发现与命令应答各自计时，不发起标准 SMP 配对。
    // Bound system BLE link establishment separately from GATT discovery and command replies, without initiating standard SMP pairing.
    linkStarted = now_ns(); deadline = linkStarted + 30ull * NSEC_PER_SEC; waitingFor = "BLE link";
    LOG("NS2 Pro BLE 连接 id=%s name=%s RSSI=%s state=%ld，链路期限30秒", peripheral.identifier.UUIDString.UTF8String, peripheral.name.UTF8String ?: "unknown", rssi ? rssi.stringValue.UTF8String : "unavailable", (long)peripheral.state);
    [central connectPeripheral:peripheral options:nil];
}
- (void)didConnect {
    LOG("NS2 Pro BLE 链路已连接，耗时 %.1f ms，开始发现服务", (now_ns() - linkStarted) / 1e6);
    pthread_mutex_lock(&stateMu); linkShared[slot].info.connected = 1; refresh_locked(); pthread_mutex_unlock(&stateMu);
    deadline = now_ns() + 10ull * NSEC_PER_SEC; waitingFor = "service discovery";
    [device discoverServices:@[[CBUUID UUIDWithString:serviceUUID]]];
}
- (void)resetLink {
    // 连接级状态必须整体失效；蓝牙断电后的旧 disconnect 回调可能不再匹配 device。
    // Invalidate all link state; after radio power loss the old disconnect callback may no longer match device.
    pthread_mutex_lock(&stateMu);
    BOOL affected = reset_link_state_locked(slot);
    memset(&linkShared[slot], 0, sizeof linkShared[slot]);
    refresh_locked();
    pthread_mutex_unlock(&stateMu);
    device = nil; input = power = vibration = command = response = nil; kind = NS2_KIND_NONE;
    pendingCommand = nil; awaitingAck = subscribedResponse = streamReady = sessionFailed = preferReport09 = NO;
    imuEnabled = motionCommand = NO;
    softState = NS2SoftRunning; pauseWanted = pauseStopPending = resumeCounterKnown = powerSubscribePending = NO;
    pauseStarted = resumeStarted = 0;
    deadline = linkStarted = lastRumble = reports = reports09 = rumblePackets = effectivePackets = stopPackets = 0; waitingFor = NULL; step = 0; sequence = 0;
    memset(calibration, 0, sizeof calibration);
    if (affected) emit_state((ns2_state){0});
}
// suspend 的本链路部分（调用方已确认 canKeep，并已在全局清空逻辑输入 / 运动 / 震动）。
- (void)beginPause {
    pthread_mutex_lock(&stateMu);
    BOOL begin = !pauseWanted;
    pauseWanted = YES; linkShared[slot].ready = NO; linkShared[slot].info.ready = 0;
    memset(&linkShared[slot].last, 0, sizeof linkShared[slot].last);
    if (begin) { pauseStopPending = YES; stopMask |= owned_sides_locked(slot); pauseStarted = now_ns(); }
    refresh_locked();
    pthread_mutex_unlock(&stateMu);
    // 后台可能冻结队列；不把冻结时间计作 ACK 失败，resume重新给在途操作有界期限。
    // Background suspension may freeze this queue; resume restarts a bounded deadline for pending work.
    deadline = 0; resumeCounterKnown = NO;
    if (softState == NS2SoftRunning || softState == NS2SoftFreshInput) softState = NS2SoftDraining;
    LOG("NS2 Pro BLE suspend mono_ms=%.3f soft=%u input_notify=%d", now_ns() / 1e6, softState, input.isNotifying);
}
// resume 的本链路部分：0 失败（已 fail）、1 本来就在跑、2 开始恢复。
- (int)beginResume {
    pthread_mutex_lock(&stateMu);
    BOOL alreadyRunning = softState == NS2SoftRunning && linkShared[slot].ready;
    pauseWanted = NO;
    pthread_mutex_unlock(&stateMu);
    if (!input.isNotifying) { [self fail:@"Retained report05 subscription is no longer active"]; return 0; }
    if (alreadyRunning) return 1;
    // 快速返回也先完成在途 IMU 关闭与 power 退订；input订阅始终保留，不发送重复的订阅请求。
    // Finish pending IMU disable and power unsubscription; retain input notifications without duplicate subscribe requests.
    resumeStarted = now_ns();
    LOG("NS2 Pro BLE resume mono_ms=%.3f pause_elapsed_ms=%.3f soft=%u input_notify=%d", resumeStarted / 1e6,
        pauseStarted ? (resumeStarted - pauseStarted) / 1e6 : 0, softState, input.isNotifying);
    deadline = now_ns() + 15ull * NSEC_PER_SEC;
    waitingFor = "soft resume pending operation";
    return 2;
}
- (void)advanceSoftState {
    if (softState == NS2SoftDraining) {
        if (pauseStopPending || pendingCommand || awaitingAck || powerSubscribePending) return;
        if (imuEnabled) {
            uint8_t bytes[12] = {0x0c, 0x91, 1, 5, 0, 4, 0, 0, 4, 0, 0, 0};
            pendingCommand = [NSData dataWithBytes:bytes length:sizeof bytes]; motionCommand = YES;
            deadline = pauseWanted ? 0 : now_ns() + 15ull * NSEC_PER_SEC;
            waitingFor = "soft pause IMU disable write";
            return;
        }
        if (!input.isNotifying) { [self fail:@"Retained report05 subscription became inactive while pausing"]; return; }
        if (power.isNotifying) {
            softState = NS2SoftUnsubscribingPower;
            deadline = pauseWanted ? 0 : now_ns() + 15ull * NSEC_PER_SEC;
            waitingFor = "soft pause report09 unsubscribe";
            [device setNotifyValue:NO forCharacteristic:power]; return;
        }
        softState = NS2SoftPaused; deadline = 0;
        LOG("NS2 Pro BLE paused mono_ms=%.3f pause_elapsed_ms=%.3f：零包已提交，IMU已关闭，保留report05订阅但丢弃逻辑输入；power通知已退订", now_ns() / 1e6,
            pauseStarted ? (now_ns() - pauseStarted) / 1e6 : 0);
        if (pauseWanted) { [bridge linkPaused]; return; }
    }
    if (softState == NS2SoftPaused && !pauseWanted) {
        if (!input.isNotifying) { [self fail:@"Retained report05 subscription became inactive while resuming"]; return; }
        softState = NS2SoftFreshInput; preferReport09 = NO; resumeCounterKnown = NO;
        deadline = now_ns() + 15ull * NSEC_PER_SEC; waitingFor = "fresh retained report05 counter advancement after resume";
    }
}
- (void)fail:(NSString *)reason {
    LOG("【红】NS2 Pro BLE：%s", reason.UTF8String);
    BOOL live = [self live];
    pthread_mutex_lock(&stateMu);
    BOOL wasPair = live && pair_locked();
    BOOL affected = live && reset_link_state_locked(slot);
    if (live) { linkShared[slot].failed = YES; refresh_locked(); }
    pthread_mutex_unlock(&stateMu);
    sessionFailed = YES; streamReady = NO; pendingCommand = nil; awaitingAck = NO; deadline = 0;
    // Joy-Con 失败不停扫描：重连记住的那只超时时，另一侧可能正在扫描窗口里等着被找到（Pro 同改前）
    if (live && ns2_link_failure_stops_scan(kind)) [bridge stopScanning];
    if (!live) return;
    if (affected) emit_state((ns2_state){0});
    if (![self live]) return;
    [bridge report:NS2_STATUS_ERROR message:reason from:self];
    if (![self live]) return;
    if (wasPair) { [bridge pairBroke]; if (![self live]) return; }
    // 暂时失败显式报错；只有下一次用户扫描才允许重试，不因 ACK 超时永久封禁。
    // Report transient failures and retry only on the next user scan, without permanently rejecting a device after an ACK timeout.
    if (device) { bridge->retryAfter[device.identifier] = @(now_ns() + 5ull * NSEC_PER_SEC); [central cancelPeripheralConnection:device]; }
    [bridge scheduleTimer];
}
- (void)telemetryFailed:(NSString *)reason {
    LOG("【红】NS2 Pro BLE 电量遥测：%s", reason.UTF8String);
    pthread_mutex_lock(&stateMu);
    ns2_info *info = &linkShared[slot].info;
    ns2_decode_report09_telemetry(NULL, 0, info);
    ns2_decode_report09_accessories(NULL, 0, info);
    snprintf(info->telemetry_error, sizeof info->telemetry_error, "%s", reason.UTF8String);
    refresh_locked();
    pthread_mutex_unlock(&stateMu);
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    NS2Link *hold __attribute__((objc_precise_lifetime)) = self; (void)hold;
    if (![self live] || peripheral != device) return;
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Service discovery failed: %@"), error.localizedDescription]]; return; }
    LOG("NS2 Pro BLE 服务发现完成，%lu 项", (unsigned long)peripheral.services.count);
    for (CBService *service in peripheral.services) if (uuid_is(service.UUID, serviceUUID)) {
        deadline = now_ns() + 10ull * NSEC_PER_SEC; waitingFor = "characteristic discovery";
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:inputUUID], [CBUUID UUIDWithString:powerUUID],
            [CBUUID UUIDWithString:[self vibrationUUIDForKind]], [CBUUID UUIDWithString:commandUUID], [CBUUID UUIDWithString:responseUUID]] forService:service]; [bridge scheduleTimer]; return;
    }
    [self fail:NS2Localized(@"Nintendo service not found")];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    NS2Link *hold __attribute__((objc_precise_lifetime)) = self; (void)hold;
    if (![self live] || peripheral != device || !uuid_is(service.UUID, serviceUUID)) return;
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Characteristic discovery failed: %@"), error.localizedDescription]]; return; }
    for (CBCharacteristic *ch in service.characteristics) {
        if (uuid_is(ch.UUID, inputUUID)) input = ch;
        if (uuid_is(ch.UUID, powerUUID)) power = ch;
        if (uuid_is(ch.UUID, [self vibrationUUIDForKind])) vibration = ch;   // Joy-Con 没有 Pro 的 report09 通道是正常的（power 可为空）
        if (uuid_is(ch.UUID, commandUUID)) command = ch;
        if (uuid_is(ch.UUID, responseUUID)) response = ch;
    }
    if (!input || !(input.properties & CBCharacteristicPropertyNotify) ||
        !response || !(response.properties & CBCharacteristicPropertyNotify) ||
        !command || !(command.properties & CBCharacteristicPropertyWriteWithoutResponse) ||
        !vibration || !(vibration.properties & CBCharacteristicPropertyWriteWithoutResponse)) {
        [self fail:NS2Localized(@"The Pro rumble characteristic or required input/command properties are missing")]; return;
    }
    if ([peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse] < 42) {
        [self fail:NS2Localized(@"BLE writes without response support fewer than 42 bytes. Rumble reports cannot be split.")]; return;
    }
    LOG("NS2 Pro BLE 特征发现完成，write MTU=%lu，订阅命令响应", (unsigned long)[peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse]);
    deadline = now_ns() + 15ull * NSEC_PER_SEC; waitingFor = "response subscription";
    [peripheral setNotifyValue:YES forCharacteristic:response]; [bridge scheduleTimer];
}
- (NSString *)vibrationUUIDForKind { return kind == NS2_KIND_JOYCON_L ? joyconLeftVibrationUUID : kind == NS2_KIND_JOYCON_R ? joyconRightVibrationUUID : vibrationUUID; }
- (BOOL)joycon { return is_joycon(kind); }
- (NSUInteger)initializationSteps { return 9u; }
// 功能位：Pro 0x2b / 0x2f（带 IMU）；Joy-Con 2 去掉 Pro 才有的 0x08、加上 0x10 光学鼠标 = 0x33 / 0x37（同官方序列）
- (uint8_t)featureBits:(BOOL)imu { return (uint8_t)(((imu ? 0x2f : 0x2b) & ([self joycon] ? ~0x08 : 0xff)) | ([self joycon] ? 0x10 : 0)); }
- (NSData *)commandForStep {
    uint8_t bytes[28] = {0, 0x91, 1, 0, 0, 0, 0, 0}; size_t length = 8;
    switch (step) {
        case 0: bytes[0] = 7; bytes[3] = 1; break;
        case 1: case 2:
            bytes[0] = 2; bytes[3] = 4; bytes[5] = 8; length = 16;
            bytes[8] = 0x40; bytes[9] = 0x7e; bytes[12] = step == 1 ? 0x80 : 0xc0; bytes[13] = 0x30; bytes[14] = 1; break;
        case 3: bytes[0] = 3; bytes[3] = 0x0a; bytes[5] = 4; bytes[8] = 5; length = 12; break;
        // 功能位见 featureBits：Joy-Con 2 另开 0x10 光学鼠标（官方序列 0x37 也开），要 Joy-Con 2 鼠标的游戏读它判断是不是 Joy-Con 2、取位移
        case 4: bytes[0] = 0x0c; bytes[3] = 2; bytes[5] = 4; bytes[8] = [self featureBits:motionCallback != nil]; length = 12; break;
        case 5: {
            bytes[0] = 0x0a; bytes[3] = 8; bytes[5] = 20; length = 28;
            bytes[8] = 1; memset(bytes + 9, 0xff, 8); bytes[17] = 0x35; bytes[19] = 0x46; break;
        }
        case 6:
            bytes[0] = 0x0c; bytes[3] = 4; bytes[5] = 4; length = 12;
            pthread_mutex_lock(&stateMu); bytes[8] = [self featureBits:motionCallback && motionRequested]; pthread_mutex_unlock(&stateMu);
            break;
        // 玩家1常亮；采用已公开且在冷启动有效的 09/07 bitmask 命令。
        // Player1 steady light, using the documented 09/07 bitmask command that works on cold start.
        case 7: bytes[0] = 9; bytes[3] = 7; bytes[5] = 8; bytes[8] = 1; length = 16; break;
        // 固件内置的连接成功音型，只播放一次；不建立持续震动任务。
        // Play firmware connection sample 3 once, without starting a rumble loop.
        case 8: bytes[0] = 0x0a; bytes[3] = 2; bytes[5] = 4; bytes[8] = 3; length = 12; break;
        default: return nil;
    }
    return [NSData dataWithBytes:bytes length:length];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    NS2Link *hold __attribute__((objc_precise_lifetime)) = self; (void)hold;
    if (![self live] || peripheral != device || sessionFailed) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) { [central cancelPeripheralConnection:peripheral]; return; }
    if (streamReady && ch == response) {
        if (error || !ch.isNotifying) [self fail:@"Retained command response subscription failed"];
        return;
    }
    if (ch == power && powerSubscribePending) {
        powerSubscribePending = NO;
        if (softState != NS2SoftRunning) {
            if (error || !ch.isNotifying) { [self fail:@"Pending report09 subscription failed during soft pause"]; return; }
            [self tick]; return;
        }
    }
    if (softState != NS2SoftRunning && (ch == input || ch == power)) {
        BOOL unsubscribing = softState == NS2SoftUnsubscribingPower && ch == power;
        if (!unsubscribing) { [self fail:@"Unexpected retained input/power subscription change during soft pause/resume"]; return; }
        if (error || ch.isNotifying) { [self fail:[NSString stringWithFormat:@"Soft report09 unsubscribe failed: %@", error.localizedDescription ?: @"unexpected notification state"]]; return; }
        deadline = 0;
        softState = NS2SoftDraining;
        [self tick]; return;
    }
    if (ch == power) {
        if (error || !ch.isNotifying) {
            preferReport09 = NO;
            [self telemetryFailed:[NSString stringWithFormat:NS2Localized(@"Report09 subscription failed: %@"), error.localizedDescription ?: NS2Localized(@"Notifications were not enabled")]];
        }
        return;
    }
    if (error || !ch.isNotifying) { [self fail:[NSString stringWithFormat:NS2Localized(@"Subscription to %@ failed: %@"), ch.UUID, error.localizedDescription ?: NS2Localized(@"Notifications were not enabled")]]; return; }
    if (ch == response) { LOG("NS2 Pro BLE 命令响应订阅完成，开始握手"); subscribedResponse = YES; deadline = 0; [self tick]; }
    if (ch == input) {
        streamReady = YES; deadline = 0;
        // 不发送初始零包，避免截断刚确认的连接反馈；游戏的停止请求仍走 mailbox。
        // Avoid an initial zero packet truncating the acknowledged connection feedback.
        pthread_mutex_lock(&stateMu);
        // 另一只已在用：这一只就绪即拼成一对，震动归属与输出形态切换
        BOOL formsPair = linkShared[slot ^ 1].present;
        linkShared[slot].present = YES; linkShared[slot].ready = YES; linkShared[slot].info.ready = 1;
        if (formsPair) reroute_locked();
        refresh_locked();
        BOOL paired = pair_locked();
        pthread_mutex_unlock(&stateMu);
        if (formsPair) emit_state((ns2_state){0});
        if (![self live]) return;
        // 仅在校准、命令 ACK 和输入订阅均成功后记住设备，发现或连接事件不写入。
        // Remember the device only after calibration, command ACKs and input subscription succeed, never on discovery or connection alone.
        [bridge rememberReady:self];
        LOG("NS2 Pro BLE ready：工厂摇杆校准；report05%s；玩家1灯与固件反馈命令ACK；双侧双频42-byte震动，仅活动时调度；gain=%.3g（命令ACK不代表电机动作）%s", motionCallback ? " IMU" : "", rumbleGain,
            paired ? "；Joy-Con 2 左右已拼成一对（竖握）" : "");
        [bridge report:NS2_STATUS_READY message:paired ? NS2Localized(@"Connected: Joy-Con 2 pair (left + right)") :
            NS2Localized(@"Connected: factory calibration and player 1 light initialization complete") from:self];
        if (![self live]) return;
        if (softState != NS2SoftRunning) { [self tick]; return; }
        // report09 订阅可能切断 report05；IMU 模式只用公开可解码的 report05。
        // Subscribing to report09 may cut off report05; IMU mode uses only the publicly decoded report05.
        if (power && !motionCallback) {
            if (power.properties & CBCharacteristicPropertyNotify) { powerSubscribePending = YES; [peripheral setNotifyValue:YES forCharacteristic:power]; }
            else [self telemetryFailed:NS2Localized(@"Report09 does not support notifications. Battery level and charging status are unavailable.")];
        }
        [self tick];
    }
}
- (void)receiveAck:(NSData *)data {
    if (!awaitingAck || data.length < 8) return;
    const uint8_t *p = data.bytes, *request = pendingCommand.bytes;
    if (p[0] != request[0] || p[3] != request[3]) return;
    if (p[1] != 1 || p[2] != 1 || (p[5] & 0x7f) != 0x78) { [self fail:NS2Localized(@"Invalid command response direction, transport or acknowledgement")]; return; }
    if (motionCommand) {
        imuEnabled = request[3] == 4;
        LOG("NS2 Pro BLE IMU %s：运行时命令已确认", imuEnabled ? "开启" : "关闭");
        motionCommand = awaitingAck = NO; pendingCommand = nil; deadline = 0;
        [self tick]; return;
    }
    if (step == 1 || step == 2) {
        if (data.length < 80 || le32(p + 8) != 0x40 || le32(p + 12) != le32(request + 12)) {
            [self fail:NS2Localized(@"The factory calibration response length or read address does not match")]; return;
        }
        ns2_calibration *cal = &calibration[step - 1]; const uint8_t *record = p + 16 + 0x28;
        unpack12(record, cal->center); unpack12(record + 3, cal->above); unpack12(record + 6, cal->below);
        for (unsigned axis = 0; axis < 2; axis++) if (!cal->center[axis] || !cal->above[axis] || !cal->below[axis] ||
            cal->center[axis] + cal->above[axis] > 4095 || cal->below[axis] > cal->center[axis]) {
            [self fail:NS2Localized(@"Factory stick calibration is invalid. Estimated centers and ranges are not used.")]; return;
        }
        LOG("NS2 Pro BLE calibration side=%lu center=%u,%u above=%u,%u below=%u,%u", (unsigned long)step - 1,
            cal->center[0], cal->center[1], cal->above[0], cal->above[1], cal->below[0], cal->below[1]);
    }
    LOG("NS2 Pro BLE ACK step=%lu cmd=%02x/%02x len=%lu", (unsigned long)step, p[0], p[3], (unsigned long)data.length);
    if (step == 6) imuEnabled = (request[8] & 4) != 0;
    step++; awaitingAck = NO; pendingCommand = nil; deadline = 0;
    if (step == 2 && [self joycon]) { calibration[1] = calibration[0]; step = 3; }   // Joy-Con 2 左右都只有主校准（0x13080），不读 0x130C0（右只读它会校验失败）
    if (step == [self initializationSteps]) {
        deadline = now_ns() + 5ull * NSEC_PER_SEC; waitingFor = "input subscription";
        [device setNotifyValue:YES forCharacteristic:input]; [bridge scheduleTimer];
    }
    else [self tick];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    NS2Link *hold __attribute__((objc_precise_lifetime)) = self; (void)hold;
    if (![self live] || peripheral != device || sessionFailed) return;
    if (ch != response && softState != NS2SoftRunning && !(ch == input && softState == NS2SoftFreshInput)) return;
    // 开启 report09 后部分固件只持续发送此通道；必须同时解析它的真实输入布局。
    // Some firmware streams only report09 after subscription, so its actual input layout must also be decoded.
    if (ch == power) {
        if (error) { preferReport09 = NO; [self telemetryFailed:[NSString stringWithFormat:NS2Localized(@"Report09 notification read failed: %@"), error.localizedDescription]]; return; }
        NSData *powerData = ch.value;
        pthread_mutex_lock(&stateMu);
        ns2_info *info = &linkShared[slot].info;
        ns2_info previous = *info;
        int valid = ns2_decode_report09_telemetry(powerData.bytes, powerData.length, info);
        ns2_decode_report09_accessories(powerData.bytes, powerData.length, info);
        ns2_info updated = *info;
        if (valid) memset(info->telemetry_error, 0, sizeof info->telemetry_error);
        refresh_locked();
        pthread_mutex_unlock(&stateMu);
        if (previous.nfc_state_known != updated.nfc_state_known || previous.nfc_state != updated.nfc_state ||
            previous.headset_state_known != updated.headset_state_known || previous.headset_state != updated.headset_state)
            LOG("NS2 Pro BLE 附件状态：NFC known=%u raw=%u；耳机 known=%u raw=%u（仅状态，未实现读卡或音频流）",
                updated.nfc_state_known, updated.nfc_state, updated.headset_state_known, updated.headset_state);
        if (!valid) [self telemetryFailed:NS2Localized(@"Report09 is shorter than 63 bytes or its battery level is outside 0..9")];
        if (streamReady) [self publishInput:powerData report:9];
        return;
    }
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Notification read failed: %@"), error.localizedDescription]]; return; }
    NSData *data = ch.value;
    if (!data) { [self fail:NS2Localized(@"Notification data is empty")]; return; }
    if (ch == response) { [self receiveAck:data]; return; }
    if (ch != input || !streamReady) return;
    if (data.length < 63) { [self fail:[NSString stringWithFormat:NS2Localized(@"Report05 has %lu bytes; at least 63 are required"), (unsigned long)data.length]]; return; }
    if (softState == NS2SoftFreshInput) {
        uint32_t counter = le32(data.bytes);
        if (!resumeCounterKnown) {
            resumeCounterKnown = YES; resumeCounter = counter;
            LOG("NS2 Pro BLE resume candidate mono_ms=%.3f counter=%u（仅建立门控基线，不发布）", now_ns() / 1e6, counter);
            return;
        }
        uint32_t delta = counter - resumeCounter;
        if (!delta || delta >= 0x80000000u || pauseWanted) return;
        softState = NS2SoftRunning; deadline = 0;
        pthread_mutex_lock(&stateMu); linkShared[slot].ready = YES; linkShared[slot].info.ready = 1; refresh_locked(); pthread_mutex_unlock(&stateMu);
        LOG("NS2 Pro BLE resumed mono_ms=%.3f resume_elapsed_ms=%.3f：report05 counter %u -> %u，旧候选未发布", now_ns() / 1e6,
            resumeStarted ? (now_ns() - resumeStarted) / 1e6 : 0, resumeCounter, counter);
        // 拼对时等两只都恢复再报一次 READY；另一只恢复失败会经 pairBroke 补报
        if (![bridge otherResumePending:self]) emit_status(NS2_STATUS_READY, @"Controller link resumed with fresh input");
        if (![self live] || softState != NS2SoftRunning) return;
        [self tick];
        if (![self live] || softState != NS2SoftRunning) return;
        if (power && !motionCallback && (power.properties & CBCharacteristicPropertyNotify)) { powerSubscribePending = YES; [peripheral setNotifyValue:YES forCharacteristic:power]; }
    }
    pthread_mutex_lock(&stateMu);
    ns2_info *info = &linkShared[slot].info;
    BOOL headsetWasKnown = info->headset_connected_known, headsetWasConnected = info->headset_connected;
    int valid = ns2_decode_report05_telemetry(data.bytes, data.length, info);
    ns2_decode_report05_accessories(data.bytes, data.length, info);
    BOOL headsetChanged = !headsetWasKnown || headsetWasConnected != info->headset_connected;
    BOOL headsetConnected = info->headset_connected;
    refresh_locked();
    // 拼对时单路六轴只用右只的、不转向；否则（Pro / 单只）同改前
    BOOL paired = pair_locked();
    ns2_motion motion = {0};
    BOOL motionOn = motionRequested && imuEnabled && !motionCommand && active && linkShared[slot].ready && !terminal;
    BOOL publishMotion = motionCallback && motionOn && (!paired || kind == NS2_KIND_JOYCON_R);
    if (publishMotion && ns2_decode_report05_motion(data.bytes, data.length, &motion)) {
        // 部分固件的设备时钟不可靠；对外用接收时的单调时钟，设备值保留用于诊断。
        // Some firmware has unreliable device timestamps; export monotonic arrival time and retain the device value for diagnostics.
        motion.host_timestamp_us = now_ns() / 1000;
        if (!paired) ns2_joycon_sideways_motion(kind, &motion);   // 单只 Joy-Con 2：换成横握视角；Pro 不动
        latestMotion = motion;
    }
    // 拼对时左只的六轴另存（不经回调、不转向）：Mac 启动器通道 INPUT 包的 motion_left 带给宿主，游戏的左手传感器用它（手柄当车把左右一起倾斜时，左右两只坐标相反，
    //   只给右只的读数会被游戏当成两只反向转、互相抵消）
    else if (paired && kind == NS2_KIND_JOYCON_L && motionOn) {
        ns2_motion left = {0};
        if (ns2_decode_report05_motion(data.bytes, data.length, &left)) { left.host_timestamp_us = now_ns() / 1000; latestMotionLeft = left; }
    }
    // Joy-Con 2 光学鼠标：左右两只各存一份（拼成一对时游戏左右两侧都读；只存右只的话玩家拿左只玩鼠标操作没反应）；与体感开不开无关
    if ((kind == NS2_KIND_JOYCON_L || kind == NS2_KIND_JOYCON_R) && active && linkShared[slot].ready && !terminal) {
        ns2_mouse mouse = {0};
        if (ns2_decode_report05_mouse(data.bytes, data.length, &mouse)) { mouse.kind = kind; mouse.host_timestamp_us = now_ns() / 1000; latestMouse[kind == NS2_KIND_JOYCON_R] = mouse; }
    }
    pthread_mutex_unlock(&stateMu);
    if (headsetChanged) LOG("NS2 Pro BLE 耳机插入：%s（仅插入检测，未实现音频流）", headsetConnected ? "是" : "否");
    if (publishMotion && motion.known) motionCallback(&motion, callbackContext);
    if (![self live]) return;
    if (!valid) {
        [self fail:NS2Localized(@"Report05 battery fields could not be decoded")]; return;
    }
    if (!preferReport09) [self publishInput:data report:5];
}
- (void)publishInput:(NSData *)data report:(unsigned)reportID {
    ns2_raw_input decoded;
    if (!ns2_decode_input_report(reportID, data.bytes, data.length, &decoded)) {
        [self fail:[NSString stringWithFormat:NS2Localized(@"Report%02x input has %lu bytes; at least 63 are required"), reportID, (unsigned long)data.length]]; return;
    }
    if (reportID == 9 && !preferReport09) {
        preferReport09 = YES;
        LOG("NS2 Pro BLE input source=report09；report05仅更新电压，避免重复输入");
    }
    uint64_t count = reportID == 9 ? ++reports09 : ++reports;
    if (count == 1 || count % 350 == 0)
        LOG("NS2 Pro BLE input report=%02x n=%llu len=%lu buttons=%llx raw=%u,%u,%u,%u",
            reportID, (unsigned long long)count, (unsigned long)data.length, (unsigned long long)decoded.buttons,
            decoded.lx, decoded.ly, decoded.rx, decoded.ry);
    // 回调在锁外调用，允许调用者在回调内停止或读取能力。
    // Invoke callbacks outside the mutex so callers may stop or query capabilities from a callback.
    pthread_mutex_lock(&stateMu);
    BOOL publish = active && linkShared[slot].ready && !terminal;
    pthread_mutex_unlock(&stateMu);
    if (!publish) return;
    ns2_state state = {decoded.buttons,
        calibrated_axis(decoded.lx, calibration[0], 0), calibrated_axis(decoded.ly, calibration[0], 1),
        calibrated_axis(decoded.rx, calibration[1], 0), calibrated_axis(decoded.ry, calibration[1], 1)};
    // Joy-Con 2（只走 report05）：右只的摇杆在第二个摇杆字段、用主校准（握手时已把 calibration[1] 设成主校准）。
    // 拼成一对就与另一只最近的状态合成竖握手柄；只有一只就换成横握视角。
    if ([self joycon]) {
        pthread_mutex_lock(&stateMu);
        linkShared[slot].last = state;
        BOOL paired = pair_locked();
        ns2_state mine = state, other = linkShared[slot ^ 1].last;
        pthread_mutex_unlock(&stateMu);
        if (paired) ns2_joycon_pair_state(kind == NS2_KIND_JOYCON_L ? &mine : &other, kind == NS2_KIND_JOYCON_L ? &other : &mine, &state);
        else ns2_joycon_sideways(kind, ns2_decode_side_buttons(data.bytes, data.length), &state);
    }
    emit_state(state);
}
- (void)tick { if ([self live]) [bridge tick]; }
// 本链路对下次计时的贡献（调用方持有 stateMu）：握手期限之外，只有活动震动与停止 / 关闭零包需要定时。
- (void)rumbleDueLocked:(uint64_t *)next now:(uint64_t)now {
    if (!streamReady || sessionFailed) return;
    unsigned owned = owned_sides_locked(slot);
    BOOL repeating = (wantedMask & owned) != 0;
    for (unsigned side = 0; side < 2; side++)
        if ((wantedMask & owned & (1u << side)) && (!*next || wantedDeadline[side] < *next)) *next = wantedDeadline[side];
    if (device.canSendWriteWithoutResponse && ((stopMask & owned) || repeating || (terminal && !shutdownSent))) {
        BOOL onset = (wantedMask & ~submittedMask & owned) != 0;
        uint64_t due = (stopMask & owned) || terminal || onset ? now : lastRumble + 15 * NSEC_PER_MSEC;
        if (!*next || due < *next) *next = due;
    }
}
- (void)processEvents {
    if (![self live]) return;
    uint64_t now = now_ns();
    if (sessionFailed) return;
    if (deadline && now >= deadline) {
        [self fail:[NSString stringWithFormat:@"Timed out waiting for %s (peripheral state %ld, command step %lu)", waitingFor ?: "initialization", (long)device.state, (unsigned long)step]];
        return;
    }
    if (!device || device.state != CBPeripheralStateConnected) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (!streamReady) {
        if (stopped || !subscribedResponse || awaitingAck || step >= [self initializationSteps]) return;
        if (!pendingCommand) { pendingCommand = [self commandForStep]; deadline = now + NSEC_PER_SEC; waitingFor = "command write readiness"; }
        if (!device.canSendWriteWithoutResponse) return;
        [device writeValue:pendingCommand forCharacteristic:command type:CBCharacteristicWriteWithoutResponse];
        awaitingAck = YES; deadline = now + NSEC_PER_SEC; waitingFor = "command acknowledgement"; return;
    }
    if (!stopped) [self advanceSoftState];
    if (![self live]) return;
    // IMU 只跟随游戏传感器需求；保持 report05，不启用会替代它的 report09。
    // Enable only the IMU feature bit, retaining report05 for input and motion.
    pthread_mutex_lock(&stateMu); BOOL wantsMotion = softState == NS2SoftRunning && motionCallback && motionRequested && active && !terminal; pthread_mutex_unlock(&stateMu);
    BOOL motionPhase = softState == NS2SoftRunning || softState == NS2SoftDraining;
    if (!stopped && motionPhase && motionCallback && !pauseStopPending && !awaitingAck && (pendingCommand || imuEnabled != wantsMotion)) {
        if (!pendingCommand) {
            uint8_t bytes[12] = {0x0c, 0x91, 1, wantsMotion ? 4 : 5, 0, 4, 0, 0, 4, 0, 0, 0};
            pendingCommand = [NSData dataWithBytes:bytes length:sizeof bytes]; motionCommand = YES;
            deadline = pauseWanted ? 0 : now + (softState == NS2SoftDraining ? 15ull * NSEC_PER_SEC : NSEC_PER_SEC); waitingFor = "IMU command write readiness";
        }
        if (device.canSendWriteWithoutResponse) {
            [device writeValue:pendingCommand forCharacteristic:command type:CBCharacteristicWriteWithoutResponse];
            awaitingAck = YES; deadline = pauseWanted ? 0 : now + (softState == NS2SoftDraining ? 15ull * NSEC_PER_SEC : NSEC_PER_SEC); waitingFor = "IMU command acknowledgement";
        }
    }
    pthread_mutex_lock(&stateMu);
    // 本链路只处理自己负责的侧（Pro / 单只是两侧，与改前相同）。
    unsigned owned = owned_sides_locked(slot);
    // 独立于菜单主线程检查租约，防止界面阻塞时重复旧震动。
    // Enforce leases independently of the UI thread so a stalled menu cannot repeat stale rumble.
    for (unsigned side = 0; side < 2; side++) {
        unsigned bit = 1u << side;
        if ((owned & bit) && (wantedMask & bit) && now >= wantedDeadline[side]) {
            wanted[side] = (ns2_vibration){0}; wantedMask &= ~bit;
            stopMask |= submittedMask & bit;
        }
    }
    BOOL urgent = (stopMask & owned) != 0 || (terminal && !shutdownSent);
    BOOL onset = (wantedMask & ~submittedMask & owned) != 0;
    BOOL repeating = (wantedMask & owned) != 0;
    if (!device.canSendWriteWithoutResponse) {
        pthread_mutex_unlock(&stateMu); return;
    }
    // 静音转有效可写即发；持续活动保持15ms节奏。停止标记先发真实零包，背压只保留最新mailbox。
    // Send silent-to-active onsets when writable; sustain the 15 ms active cadence, real stop priority and latest-mailbox backpressure.
    if ((!urgent && !repeating) || (!urgent && !onset && now - lastRumble < 14 * NSEC_PER_MSEC)) {
        pthread_mutex_unlock(&stateMu); return;
    }
    ns2_vibration values[2]; memcpy(values, wanted, sizeof values);
    unsigned stopping = stopMask & owned;
    for (unsigned side = 0; side < 2; side++)
        if ((stopping & (1u << side)) || !(owned & (1u << side)) || !active || terminal) values[side] = (ns2_vibration){0};
    uint8_t packet[42]; ns2_encode_rumble_for(kind, values, sequence, rumbleGain, packet);
    [device writeValue:[NSData dataWithBytes:packet length:sizeof packet] forCharacteristic:vibration type:CBCharacteristicWriteWithoutResponse];
    ns2_rumble_amplitudes left = ns2_rumble_amplitude_codes(values[0], rumbleGain);
    ns2_rumble_amplitudes right = ns2_rumble_amplitude_codes(values[1], rumbleGain);
    unsigned submitted = (left.low || left.high ? 1u : 0u) | (right.low || right.high ? 2u : 0u);
    submittedMask = (submittedMask & ~owned) | (submitted & owned);
    rumblePackets++;
    if (submitted & owned) effectivePackets++;
    if (stopping || terminal) stopPackets++;
    if (rumblePackets == 1 || ((submitted & owned) && effectivePackets == 1) || rumblePackets % 64 == 0)
        LOG("NS2 Pro BLE rumble submitted=%llu effective=%llu stops=%llu requests=%llu quantizedSilent=%llu L=%.4f@%.2f/%.4f@%.2f code=%u/%u R=%.4f@%.2f/%.4f@%.2f code=%u/%u seq=%u（传输提交，非电机遥测）",
            (unsigned long long)rumblePackets, (unsigned long long)effectivePackets, (unsigned long long)stopPackets,
            (unsigned long long)rumbleRequests, (unsigned long long)quantizedSilentRequests,
            values[0].low_amp, values[0].low_freq, values[0].high_amp, values[0].high_freq, left.low, left.high,
            values[1].low_amp, values[1].low_freq, values[1].high_amp, values[1].high_freq, right.low, right.high, sequence & 15);
    for (unsigned side = 0; side < 2; side++) if (owned & (1u << side)) actual[side] = values[side];
    sequence++; lastRumble = now; stopMask &= ~owned;
    BOOL continuePause = pauseStopPending;
    pauseStopPending = NO;
    if (continuePause) LOG("NS2 Pro BLE pause stop submitted mono_ms=%.3f（CoreBluetooth提交，非电机确认）", now_ns() / 1e6);
    // 只有 ns2_shutdown 为这条链路登记过（dispatch_group_enter）才在零包交出时销账：
    //   暂停 / 恢复中没就绪的链路不登记、零包照发，这时 leave 会让 libdispatch 直接终止进程；拼对时另一只可能还在恢复。Pro 同一条规则
    BOOL signal = terminal && !shutdownSent && shutdownEntered;
    if (terminal) shutdownSent = YES;
    if (signal) shutdownEntered = NO;
    pthread_mutex_unlock(&stateMu);
    if (signal) {
        LOG("NS2 Pro BLE shutdown：42-byte零包已交给 CoreBluetooth（无硬件ACK）");
        dispatch_group_leave(shutdownGroup);
    }
    if (continuePause && [self live]) [self tick];
}
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    NS2Link *hold __attribute__((objc_precise_lifetime)) = self; (void)hold;
    if (peripheral == device) [self tick];
}
@end

@implementation NS2Bridge
- (instancetype)init {
    if ((self = [super init])) {
        retryAfter = [NSMutableDictionary new];
        initialConnectionRequested = YES;
        central = [[CBCentralManager alloc] initWithDelegate:self queue:bleQueue options:nil];
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, bleQueue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
        __weak NS2Bridge *weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { [weakSelf tick]; } });
        dispatch_resume(timer);
        // 合并跨线程 mailbox 唤醒，空闲时不产生周期唤醒，也不为每个震动请求分配 block。
        // Coalesce cross-thread mailbox wakes without idle polling or one allocated block per rumble request.
        dispatch_source_t wake = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, bleQueue);
        dispatch_source_set_event_handler(wake, ^{ @autoreleasepool { [weakSelf tick]; } });
        dispatch_resume(wake);
        pthread_mutex_lock(&stateMu); mailboxWake = wake; pthread_mutex_unlock(&stateMu);
    }
    return self;
}
- (NS2Link *)linkForPeripheral:(CBPeripheral *)peripheral {
    for (unsigned i = 0; i < 2; i++) if (links[i] && links[i]->device == peripheral) return links[i];
    return nil;
}
- (NS2Link *)presentLinkOtherThan:(NS2Link *)link {
    for (unsigned i = 0; i < 2; i++) { NS2Link *other = links[i]; if (other && other != link && other->streamReady && !other->sessionFailed) return other; }
    return nil;
}
// 接下来还接不接设备：一台都没有时什么都接；只有一只 Joy-Con 时只接另一侧；Pro 连着或已凑齐两只就不再接（Pro 优先，一次只服务一台 Pro 或一对 / 一只 Joy-Con）。
- (BOOL)accepts:(ns2_kind)found peripheral:(CBPeripheral *)peripheral {
    if (found == NS2_KIND_NONE) return NO;
    NS2Link *a = links[0], *b = links[1];
    if (!a && !b) return YES;
    if (a && b) return NO;
    NS2Link *only = a ?: b;
    if ([only->device.identifier isEqual:peripheral.identifier]) return NO;
    return (only->kind == NS2_KIND_JOYCON_L && found == NS2_KIND_JOYCON_R) || (only->kind == NS2_KIND_JOYCON_R && found == NS2_KIND_JOYCON_L);
}
// 能否（继续）扫描：没有链路，或只有一只 Joy-Con（已就绪或还在连）缺另一侧。
//   还在连也要扫：重连记住的那只时它可能没开机（直连要等 30 秒才超时），这段时间另一侧照样能被找到；accepts 只收缺的那一侧
- (BOOL)wantsAnotherDevice {
    NS2Link *a = links[0], *b = links[1];
    if (!a && !b) return YES;
    if (a && b) return NO;
    NS2Link *only = a ?: b;
    return ns2_scan_wants_other_side(only->kind, only->streamReady, only->sessionFailed);
}
// 对外状态：没有其他在用链路时原样转发（Pro / 单只 / 两只都还没就绪，与改前同一条路径）。
// 另一只 Joy-Con 正在出输入时，非 READY 状态只记日志——iOS 按钮与 Mac 连接进程见到非 READY 会把整个手柄当成断开。
// 扫描类状态（link 为 nil）在已有链路时同样只记日志：那是在给已连上的一只找另一侧。
- (void)report:(ns2_status)status message:(NSString *)message from:(NS2Link *)link {
    if (self != bridge) return;
    BOOL quiet = status != NS2_STATUS_READY && (link ? [self presentLinkOtherThan:link] != nil : (links[0] || links[1]));
    if (quiet) { LOG("NS2 Joy-Con 2：另一只仍在用，状态 %d 只记日志：%s", status, message.UTF8String); return; }
    emit_status(status, message);
}
// 拼对中一只失效 / 断开：剩下那只回到单只横握；它在出输入就补报一次 READY（上层据此保持连接显示）。
- (void)pairBroke {
    NS2Link *other = [self presentLinkOtherThan:nil];
    if (!other) return;
    pthread_mutex_lock(&stateMu); BOOL remainingReady = linkShared[other->slot].ready; pthread_mutex_unlock(&stateMu);
    LOG("NS2 Joy-Con 2：拼对拆开，剩下一只按单只横握继续");
    [self rememberReady:other];   // 主只记录改成剩下这只，与 ns2_get_info 的标识一致
    if (remainingReady) emit_status(NS2_STATUS_READY, NS2Localized(@"Joy-Con 2 pair split; continuing with one Joy-Con 2 held sideways"));
    else if (other->pauseWanted && other->softState == NS2SoftPaused) [self linkPaused];   // 暂停途中另一只掉了：剩下这只已暂停就补报 PAUSED
}
// 暂停完成：保留下来的每条链路都已暂停才报 PAUSED（Pro 只有一条，同改前）。
- (void)linkPaused {
    for (unsigned i = 0; i < 2; i++) { NS2Link *link = links[i]; if (link && link->streamReady && !link->sessionFailed && link->softState != NS2SoftPaused) return; }
    emit_status(NS2_STATUS_PAUSED, @"Controller link paused; input and motion are disabled");
}
- (BOOL)otherResumePending:(NS2Link *)link {
    NS2Link *other = [self presentLinkOtherThan:link];
    return other && other->softState != NS2SoftRunning;
}
- (void)rememberReady:(NS2Link *)link {
    NSUserDefaults *defaults = controllerDefaults();
    NSString *identifier = link->device.identifier.UUIDString;
    if (!identifier) return;
    NS2Link *primary = link;
    if ([link joycon]) {
        [defaults setObject:identifier forKey:lastReadyJoyConKeys[link->kind == NS2_KIND_JOYCON_R]];
        // 拼上一对时原两项记左只，与 ns2_get_info 的主只一致（iOS 会按 info.identifier 回写同一项）
        NS2Link *other = [self presentLinkOtherThan:link];
        if (other && other->kind == NS2_KIND_JOYCON_L && other->device.identifier) primary = other;
    }
    [defaults setObject:primary->device.identifier.UUIDString forKey:lastReadyPeripheralKey];
    [defaults setInteger:primary->kind forKey:lastReadyKindKey];
}
// 只复用曾完成握手的真实系统标识；其他同团队游戏可能刚释放前台，先接管系统仍持有的同一外设，不凭共同服务 UUID 选其他设备。
- (CBPeripheral *)knownPeripheral:(NSUUID *)identifier {
    for (CBPeripheral *candidate in [central retrieveConnectedPeripheralsWithServices:@[[CBUUID UUIDWithString:serviceUUID]]]) {
        if (![candidate.identifier isEqual:identifier]) continue;
        LOG("NS2 Pro BLE 复用系统已连接的已知外设");
        return candidate;
    }
    return [central retrievePeripheralsWithIdentifiers:@[identifier]].firstObject;
}
- (void)beginSession {
    if (self != bridge || !initialConnectionRequested || links[0] || links[1] || central.state != CBManagerStatePoweredOn) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) return;
    initialConnectionRequested = NO;
    // 只复用曾完成握手的真实系统标识；retrieve 不扫描，失效标识或空结果才进入首次扫描。
    // Reuse only a real system identifier that completed initialization; retrieval does not scan, and invalid or absent results start discovery.
    NSString *saved = [controllerDefaults() stringForKey:lastReadyPeripheralKey];
    NSUUID *identifier = saved ? [[NSUUID alloc] initWithUUIDString:saved] : nil;
    NSInteger savedKind = [controllerDefaults() integerForKey:lastReadyKindKey];
    ns2_kind kind = savedKind == NS2_KIND_JOYCON_L || savedKind == NS2_KIND_JOYCON_R ? (ns2_kind)savedKind : NS2_KIND_PRO;   // 旧版只记 Pro
    if (kind == NS2_KIND_PRO) {
        CBPeripheral *known = identifier ? [self knownPeripheral:identifier] : nil;
        if (known) { [self connectPeripheral:known name:known.name RSSI:nil kind:kind]; return; }
    } else {
        // Joy-Con 2：左右各记一个标识，两只都直连（一只连不上不影响另一只）；只有旧记录（一个标识 + 型号）时按那一只
        BOOL any = NO;
        for (unsigned side = 0; side < 2; side++) {
            ns2_kind sideKind = side ? NS2_KIND_JOYCON_R : NS2_KIND_JOYCON_L;
            NSString *text = [controllerDefaults() stringForKey:lastReadyJoyConKeys[side]] ?: (savedKind == sideKind ? saved : nil);
            NSUUID *sideIdentifier = text ? [[NSUUID alloc] initWithUUIDString:text] : nil;
            CBPeripheral *known = sideIdentifier ? [self knownPeripheral:sideIdentifier] : nil;
            if (!known) continue;
            [self connectPeripheral:known name:known.name RSSI:nil kind:sideKind]; any = YES;
            if (self != bridge) return;
        }
        // 只记得一只（或两只里只取回一只）：直连它的同时扫描另一侧。只直连不扫描时，记住的那只没开机就要等 30 秒超时，
        //   而且失败后不转扫描，另一侧（如只开了右只）永远找不到（11-11 实机：记着左只，右只怎么按都连不上）
        if (any) {
            if (![self wantsAnotherDevice]) return;
            LOG("NS2 Joy-Con 2：直连记住的一只，同时扫描另一侧 %u 秒", (unsigned)NS2_SCAN_SECONDS);
        }
    }
    scanRequested = YES;
    [self scan];
}
- (void)scan {
    if (self != bridge) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (!stopped && scanRequested && [self wantsAnotherDevice] && !central.isScanning && central.state == CBManagerStatePoweredOn) {
        // 配对广播不保证包含服务 UUID，因此前台保留无过滤扫描，但禁止重复广播且只扫描十秒。
        // Pairing advertisements may omit service UUIDs; keep an unfiltered foreground scan without duplicates for ten seconds.
        scanDeadline = now_ns() + (uint64_t)NS2_SCAN_SECONDS * NSEC_PER_SEC;
        [central scanForPeripheralsWithServices:nil options:nil];
        [self report:NS2_STATUS_SCANNING message:NS2Localized(@"Searching for a Switch 2 Pro in pairing mode") from:nil];
        [self scheduleTimer];
    }
}
- (int)rescan {
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (self != bridge || stopped || links[0] || links[1]) return 0;
    if (central.state != CBManagerStatePoweredOn && central.state != CBManagerStateUnknown && central.state != CBManagerStateResetting) {
        emit_status(NS2_STATUS_UNAVAILABLE, [NSString stringWithFormat:NS2Localized(@"Bluetooth unavailable (state %ld). Check Bluetooth power and permission."), (long)central.state]);
        return 0;
    }
    initialConnectionRequested = NO;
    scanRequested = YES;
    scanDeadline = 0;
    [central stopScan];
    [retryAfter removeAllObjects];
    [self scan];
    return 1;
}
- (void)stopScanning {
    initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    [central stopScan];
}
// 摘掉一条链路并整体失效；返回摘之前是否正拼成一对。
- (BOOL)removeLink:(NS2Link *)link {
    pthread_mutex_lock(&stateMu); BOOL wasPair = pair_locked(); pthread_mutex_unlock(&stateMu);
    if (links[link->slot] == link) links[link->slot] = nil;
    [link resetLink];
    return wasPair;
}
// 所有链路整体失效；一条都没有时也做一次（同改前 resetLink 在无设备时的效果：清全局、清信息、发零状态）。
- (void)resetLinks {
    NS2Link *a = links[0], *b = links[1];
    if (!a && !b) {
        pthread_mutex_lock(&stateMu); reset_global_locked(); memset(linkShared, 0, sizeof linkShared); refresh_locked(); pthread_mutex_unlock(&stateMu);
        emit_state((ns2_state){0});
        return;
    }
    if (a) [self removeLink:a];
    if (self != bridge && !disposing) return;   // 回调里 shutdown 已整体 dispose
    if (b) [self removeLink:b];
}
// 后台前不能保留的链路（还在握手、已失败）直接断开并失效，不留半截状态。
- (void)dropLink:(NS2Link *)link {
    LOG("NS2 Joy-Con 2：链路不可保留，断开这一只");
    if (link->device) { link->device.delegate = nil; [central cancelPeripheralConnection:link->device]; }
    [self removeLink:link];
}
- (void)dispose {
    disposing = YES;
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    pthread_mutex_lock(&stateMu);
    dispatch_source_t wake = mailboxWake; mailboxWake = nil;
    pthread_mutex_unlock(&stateMu);
    if (wake) dispatch_source_cancel(wake);
    initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    [central stopScan];
    for (unsigned i = 0; i < 2; i++) { CBPeripheral *device = links[i] ? links[i]->device : nil; if (device) { device.delegate = nil; [central cancelPeripheralConnection:device]; } }
    central.delegate = nil;
    [self resetLinks];
    emit_status(NS2_STATUS_STOPPED, NS2Localized(@"Connection stopped"));
    disposing = NO;
}
// 仅保留已初始化且仍物理连接的链路；一条都不能保留时返回 0 且什么都不动（同改前）。
- (int)suspend {
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (self != bridge || stopped) return 0;
    NS2Link *a = links[0], *b = links[1];
    BOOL keepA = a && [a canKeep], keepB = b && [b canKeep];
    if (!keepA && !keepB) return 0;
    if (a && !keepA) [self dropLink:a];
    if (b && !keepB) [self dropLink:b];
    if (self != bridge) return 0;
    if (scanRequested || scanDeadline) [self stopScanning];   // 给单只找另一侧的扫描一并停掉（Pro 连着时本来就没在扫）
    pthread_mutex_lock(&stateMu);
    active = NO;
    memset(&latestMotion, 0, sizeof latestMotion); memset(&latestMotionLeft, 0, sizeof latestMotionLeft); memset(latestMouse, 0, sizeof latestMouse);
    memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual); wantedMask = 0;
    pthread_mutex_unlock(&stateMu);
    if (keepA) [a beginPause];
    if (keepB) [b beginPause];
    emit_state((ns2_state){0});
    if (self != bridge) return 1;
    BOOL paused = (!keepA || a->softState == NS2SoftPaused) && (!keepB || b->softState == NS2SoftPaused);
    emit_status(paused ? NS2_STATUS_PAUSED : NS2_STATUS_SUSPENDING,
        paused ? @"Controller link is already paused" : @"Pausing the initialized controller link");
    if (self == bridge) [self tick];
    return 1;
}
- (int)resume {
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (self != bridge || stopped) return 0;
    NS2Link *a = links[0], *b = links[1];
    BOOL keepA = a && [a canKeep], keepB = b && [b canKeep];
    if (!keepA && !keepB) return 0;
    if (a && !keepA) [self dropLink:a];
    if (b && !keepB) [self dropLink:b];
    if (self != bridge) return 0;
    pthread_mutex_lock(&stateMu); active = YES; pthread_mutex_unlock(&stateMu);
    int resultA = keepA ? [a beginResume] : 1;
    if (self != bridge) return 0;
    int resultB = keepB ? [b beginResume] : 1;
    if (self != bridge) return 0;
    BOOL any = (keepA && resultA) || (keepB && resultB);
    if (!any) return 0;
    if (resultA != 2 && resultB != 2) return 1;
    emit_status(NS2_STATUS_RESUMING, @"Resuming the retained controller link; waiting for fresh input");
    if (self == bridge) [self tick];
    return 1;
}
- (void)stop {
    initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    [central stopScan];
    for (unsigned i = 0; i < 2; i++) { NS2Link *link = links[i]; if (link && link->device && !link->streamReady) [central cancelPeripheralConnection:link->device]; }
    [self tick];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)manager {
    if (self != bridge) return;
    LOG("NS2 Pro BLE Bluetooth state=%ld", (long)manager.state);
    if (manager.state == CBManagerStatePoweredOn) {
        if (initialConnectionRequested) [self beginSession]; else [self scan];
        return;
    }
    if (manager.state != CBManagerStateUnknown) {
        initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
        LOG("【红】NS2 Pro BLE 不可用 state=%ld（检查蓝牙电源和应用蓝牙权限）", (long)manager.state);
        [self resetLinks]; [retryAfter removeAllObjects];
        if (self != bridge) return;
        emit_status(NS2_STATUS_UNAVAILABLE, [NSString stringWithFormat:NS2Localized(@"Bluetooth unavailable (state %ld). Check Bluetooth power and permission."), (long)manager.state]);
        [self scheduleTimer];
    }
}
- (void)centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)peripheral
    advertisementData:(NSDictionary<NSString *, id> *)advertisement RSSI:(NSNumber *)rssi {
    if (self != bridge || !scanRequested || !manager.isScanning || retryAfter[peripheral.identifier].unsignedLongLongValue > now_ns()) return;
    NSData *manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey];
    const uint8_t *m = manufacturer.bytes;
    ns2_kind found = ns2_kind_from_manufacturer(m, manufacturer.length);   // Pro 0x2069、Joy-Con 2 左 0x2067 / 右 0x2066
    // 无名称模糊匹配；若广播显式携带某型号专属的震动 UUID，也可作为身份依据。
    // Never match names heuristically; an explicitly advertised model-specific rumble UUID is also identity evidence.
    for (CBUUID *uuid in advertisement[CBAdvertisementDataServiceUUIDsKey]) if (found == NS2_KIND_NONE)
        found = uuid_is(uuid, vibrationUUID) ? NS2_KIND_PRO : uuid_is(uuid, joyconLeftVibrationUUID) ? NS2_KIND_JOYCON_L : uuid_is(uuid, joyconRightVibrationUUID) ? NS2_KIND_JOYCON_R : NS2_KIND_NONE;
    // 认得出型号的广播每台记一次：实机报「另一只连不上」时，看得出它有没有被扫到、为什么没接（accepts）
    if (found != NS2_KIND_NONE) {
        static NSMutableSet<NSUUID *> *seen;
        if (!seen) seen = [NSMutableSet new];
        if (![seen containsObject:peripheral.identifier]) {
            [seen addObject:peripheral.identifier];
            LOG("NS2 扫到手柄广播 id=%s kind=%d RSSI=%d accepts=%d", peripheral.identifier.UUIDString.UTF8String, found, rssi.intValue, [self accepts:found peripheral:peripheral]);
        }
    }
    if (![self accepts:found peripheral:peripheral]) return;   // 已有一只 Joy-Con 时只接另一侧
    NSNumber *connectable = advertisement[CBAdvertisementDataIsConnectable];
    if (connectable && !connectable.boolValue) return;
    [retryAfter removeObjectForKey:peripheral.identifier];
    [self connectPeripheral:peripheral name:peripheral.name ?: advertisement[CBAdvertisementDataLocalNameKey] RSSI:rssi kind:found];
}
- (void)connectPeripheral:(CBPeripheral *)peripheral name:(NSString *)name RSSI:(NSNumber *)rssi kind:(ns2_kind)found {
    if (self != bridge || ![self accepts:found peripheral:peripheral] || central.state != CBManagerStatePoweredOn) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) return;
    unsigned slot = links[0] ? 1 : 0;
    // 扫描中连上第一只 Joy-Con：接着扫另一侧，并给另一只重新计满一个扫描窗口；Pro 或凑齐两只就停扫（同改前）
    if (scanRequested && is_joycon(found) && !links[slot ^ 1]) {
        initialConnectionRequested = NO;
        scanDeadline = now_ns() + (uint64_t)NS2_SCAN_SECONDS * NSEC_PER_SEC;
        LOG("NS2 Joy-Con 2：连上一只，继续扫描另一侧 %u 秒", (unsigned)NS2_SCAN_SECONDS);
    } else {
        [central stopScan];
        initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    }
    NS2Link *link = [[NS2Link alloc] initWithSlot:slot kind:found central:central];
    links[slot] = link;
    [link attach:peripheral name:name RSSI:rssi];
    [self scheduleTimer];
    [self report:NS2_STATUS_CONNECTING message:NS2Localized(@"Connecting to Switch 2 Pro") from:link];
}
- (void)centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)peripheral {
    NS2Link *link = [self linkForPeripheral:peripheral];
    if (self != bridge || !link) return;
    [link didConnect];
    [self scheduleTimer];
    [self report:NS2_STATUS_INITIALIZING message:NS2Localized(@"Reading factory calibration and initializing rumble and player lights") from:link];
}
- (void)centralManager:(CBCentralManager *)manager didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NS2Link *link = [self linkForPeripheral:peripheral];
    if (self != bridge || !link) return;
    LOG("【红】NS2 Pro BLE 连接失败：domain=%s code=%ld %s，耗时 %.1f ms", error.domain.UTF8String ?: "none", (long)error.code, error.localizedDescription.UTF8String ?: "未提供错误详情", (now_ns() - link->linkStarted) / 1e6);
    retryAfter[peripheral.identifier] = @(now_ns() + 5ull * NSEC_PER_SEC);
    BOOL wasPair = [self removeLink:link];
    if (self != bridge) return;
    [self report:NS2_STATUS_ERROR message:error.localizedDescription ?: NS2Localized(@"Connection failed") from:link];
    if (self != bridge) return;
    if (wasPair) { [self pairBroke]; if (self != bridge) return; }
    [self scheduleTimer];
}
- (void)centralManager:(CBCentralManager *)manager didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NS2Link *link = [self linkForPeripheral:peripheral];
    if (self != bridge || !link) return;
    uint64_t disconnectedAt = now_ns();
    LOG("%sNS2 Pro BLE 断开 mono_ms=%.3f soft=%u pause_elapsed_ms=%.3f domain=%s code=%ld：%s；输入和震动状态已丢弃",
        error ? "【红】" : "", disconnectedAt / 1e6, link->softState, link->pauseStarted ? (disconnectedAt - link->pauseStarted) / 1e6 : 0,
        error.domain.UTF8String ?: "none", (long)error.code, error.localizedDescription.UTF8String ?: "连接结束");
    BOOL wasPair = [self removeLink:link];
    if (self != bridge) return;
    [self report:NS2_STATUS_DISCONNECTED message:error.localizedDescription ?: NS2Localized(@"Controller disconnected") from:link];
    if (self != bridge) return;
    if (wasPair) { [self pairBroke]; if (self != bridge) return; }
    [self scheduleTimer];
}
- (void)tick {
    [self processEvents];
    [self scheduleTimer];
}
- (void)scheduleTimer {
    if (!timer || self != bridge) return;
    uint64_t now = now_ns(), next = 0;
    for (unsigned i = 0; i < 2; i++) { NS2Link *link = links[i]; if (link && link->deadline && (!next || link->deadline < next)) next = link->deadline; }
    if (scanDeadline && (!next || scanDeadline < next)) next = scanDeadline;
    pthread_mutex_lock(&stateMu);
    for (unsigned i = 0; i < 2; i++) [links[i] rumbleDueLocked:&next now:now];
    pthread_mutex_unlock(&stateMu);
    // 一次性 timer 只覆盖握手超时、扫描窗口及活动震动；无工作时永久停表。
    // A one-shot timer covers handshake deadlines, the scan window and active rumble; otherwise disarm it indefinitely.
    dispatch_time_t due = next ? dispatch_time(DISPATCH_TIME_NOW, next > now ? (int64_t)(next - now) : 0) : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(timer, due, DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
}
- (void)processEvents {
    if (self != bridge) return;
    uint64_t now = now_ns();
    if (scanDeadline && now >= scanDeadline) {
        scanRequested = NO; scanDeadline = 0;
        [central stopScan];
        [self report:NS2_STATUS_SCAN_FINISHED message:NS2Localized(@"Scan finished. Scan again to connect a Switch 2 Pro.") from:nil];
        if (self != bridge) return;
    }
    for (unsigned i = 0; i < 2; i++) {
        NS2Link *link = links[i];
        if (!link) continue;
        [link processEvents];
        if (self != bridge) return;
    }
}
@end

int ns2_start(ns2_state_callback state, ns2_status_callback status, void *context) {
    return ns2_start_with_motion(state, status, NULL, context);
}
ns2_kind ns2_get_output_kind(void) {
    pthread_mutex_lock(&stateMu);
    ns2_kind kind = ns2_output_kind(linkShared[0].kind, linkShared[0].present, linkShared[1].kind, linkShared[1].present);
    pthread_mutex_unlock(&stateMu);
    return kind;
}
int ns2_rescan(void) {
    __block int accepted = 0;
    on_queue(^{ accepted = [bridge rescan]; });
    return accepted;
}
int ns2_suspend(void) {
    __block int accepted = 0;
    on_queue(^{ accepted = [bridge suspend]; });
    return accepted;
}
int ns2_resume(void) {
    __block int accepted = 0;
    on_queue(^{ accepted = [bridge resume]; });
    return accepted;
}
int ns2_start_with_motion(ns2_state_callback state, ns2_status_callback status, ns2_motion_callback motion, void *context) {
    __block int accepted = 0;
    on_queue(^{
        if (bridge) return;
        float gainValue = 2;
        const char *gain = getenv("NS2PRO_RUMBLE_GAIN");
        if (gain) {
            char *end; errno = 0; double parsed = strtod(gain, &end);
            if (!*gain || isspace((unsigned char)*gain) || end == gain || *end || errno || !isfinite(parsed) || parsed < 0 || parsed > 4) {
                LOG("【红】NS2PRO_RUMBLE_GAIN 必须为有限数值 0..4");
                return;
            }
            gainValue = (float)parsed;
        }
        stateCallback = state; statusCallback = status; motionCallback = motion; callbackContext = context;
        pthread_mutex_lock(&stateMu);
        terminal = NO; active = YES; ready = NO; wantedMask = submittedMask = stopMask = 0;
        rumbleRequests = quantizedSilentRequests = 0;
        memset(linkShared, 0, sizeof linkShared);
        memset(&deviceInfo, 0, sizeof deviceInfo);
        memset(&latestMotion, 0, sizeof latestMotion); memset(&latestMotionLeft, 0, sizeof latestMotionLeft); memset(latestMouse, 0, sizeof latestMouse);
        motionRequested = motion != NULL;
        memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual); rumbleGain = gainValue;
        pthread_mutex_unlock(&stateMu);
        shutdownGroup = dispatch_group_create();
        bridge = [[NS2Bridge alloc] init];
        accepted = 1;
    });
    return accepted;
}
void ns2_set_motion_enabled(int enabled) {
    pthread_mutex_lock(&stateMu);
    BOOL next = enabled && !terminal;
    if (motionRequested != next) {
        motionRequested = next;
        memset(&latestMotion, 0, sizeof latestMotion); memset(&latestMotionLeft, 0, sizeof latestMotionLeft); memset(latestMouse, 0, sizeof latestMouse);
        if (mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    }
    pthread_mutex_unlock(&stateMu);
}
void ns2_set_active(int enabled) {
    on_queue(^{
        pthread_mutex_lock(&stateMu);
        BOOL next = enabled && !terminal;
        BOOL changed = active != next;
        active = next;
        if (changed) {
            memset(&latestMotion, 0, sizeof latestMotion); memset(&latestMotionLeft, 0, sizeof latestMotionLeft); memset(latestMouse, 0, sizeof latestMouse);
            memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
            wantedMask = 0; stopMask |= submittedMask;
        }
        pthread_mutex_unlock(&stateMu);
        if (changed) { emit_state((ns2_state){0}); [bridge tick]; }
    });
}
unsigned ns2_caps(void) {
    pthread_mutex_lock(&stateMu); unsigned caps = ready && active && !terminal ? NS2_CAP_LEFT | NS2_CAP_RIGHT : 0;
    pthread_mutex_unlock(&stateMu); return caps;
}
unsigned ns2_device_caps(void) {
    pthread_mutex_lock(&stateMu); unsigned caps = ready && !terminal ? NS2_CAP_LEFT | NS2_CAP_RIGHT : 0;
    pthread_mutex_unlock(&stateMu); return caps;
}
void ns2_send(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq) {
    ns2_send_lease(side, low_amp, low_freq, high_amp, high_freq, 1000);
}
static ns2_vibration bounded_vibration(ns2_vibration bounded, unsigned side, unsigned duration_ms) {
    if (!isfinite(bounded.low_amp) || !isfinite(bounded.high_amp) || !isfinite(bounded.low_freq) || !isfinite(bounded.high_freq)) {
        LOG("【红】NS2 Pro BLE 拒绝非有限震动值并停止该侧 side=%u", side); bounded = (ns2_vibration){0};
    } else if ((bounded.low_amp > 0 && bounded.low_freq <= 0) || (bounded.high_amp > 0 && bounded.high_freq <= 0)) {
        LOG("【红】NS2 Pro BLE 拒绝非正载频并停止该侧 side=%u", side); bounded = (ns2_vibration){0};
    }
    bounded.low_amp = fminf(1, fmaxf(0, bounded.low_amp));
    bounded.high_amp = fminf(1, fmaxf(0, bounded.high_amp));
    bounded.low_freq = bounded.low_amp ? fminf(1252, fmaxf(40, bounded.low_freq)) : 0;
    bounded.high_freq = bounded.high_amp ? fminf(1252, fmaxf(40, bounded.high_freq)) : 0;
    if (!duration_ms) bounded = (ns2_vibration){0};
    return bounded;
}
// 调用方持有 stateMu；双侧提交共用接收时间和截止时间，更新完成后才唤醒 BLE 队列。
// The caller holds stateMu; paired sides share arrival and expiry times and wake BLE only after both updates.
static BOOL update_rumble_side_locked(unsigned side, ns2_vibration bounded, uint64_t expires) {
    unsigned bit = 1u << side;
    BOOL effective = value_effective(bounded);
    rumbleRequests++;
    if (!effective && (bounded.low_amp > 0 || bounded.high_amp > 0)) quantizedSilentRequests++;
    // 量化静音取消未提交的活动请求；只有曾提交有效幅码的侧需要停止包。
    // Quantized silence cancels unsent activity; only a side with submitted active codes needs a stop packet.
    wanted[side] = effective ? bounded : (ns2_vibration){0};
    if (effective) wantedMask |= bit; else wantedMask &= ~bit;
    wantedDeadline[side] = effective ? expires : 0;
    if (!effective) stopMask |= submittedMask & bit;
    return effective || stopMask;
}
void ns2_send_lease(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq, unsigned duration_ms) {
    if (side > 1) return;
    ns2_vibration bounded = bounded_vibration((ns2_vibration){low_amp, low_freq, high_amp, high_freq}, side, duration_ms);
    if (duration_ms > 1000) duration_ms = 1000;
    pthread_mutex_lock(&stateMu);
    if (ready && active && !terminal) {
        uint64_t accepted = now_ns();
        BOOL wake = update_rumble_side_locked(side, bounded, accepted + (uint64_t)duration_ms * NSEC_PER_MSEC);
        if (wake && mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    }
    pthread_mutex_unlock(&stateMu);
}
void ns2_send_pair_lease(const ns2_vibration values[2], unsigned duration_ms) {
    if (!values) return;
    ns2_vibration bounded[2] = {
        bounded_vibration(values[0], 0, duration_ms),
        bounded_vibration(values[1], 1, duration_ms)
    };
    if (duration_ms > 1000) duration_ms = 1000;
    pthread_mutex_lock(&stateMu);
    if (ready && active && !terminal) {
        uint64_t accepted = now_ns(), expires = accepted + (uint64_t)duration_ms * NSEC_PER_MSEC;
        BOOL wake = update_rumble_side_locked(0, bounded[0], expires);
        wake |= update_rumble_side_locked(1, bounded[1], expires);
        if (wake && mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    }
    pthread_mutex_unlock(&stateMu);
}
void ns2_actual(unsigned side, ns2_vibration *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu); *out = side < 2 ? actual[side] : (ns2_vibration){0}; pthread_mutex_unlock(&stateMu);
}
void ns2_get_info(ns2_info *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu); *out = deviceInfo; pthread_mutex_unlock(&stateMu);
}
void ns2_get_motion(ns2_motion *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu);
    *out = latestMotion;
    if (!ready || !active || !motionRequested || terminal || now_ns() / 1000 - out->host_timestamp_us > 250000)
        memset(out, 0, sizeof *out);
    pthread_mutex_unlock(&stateMu);
}
void ns2_get_motion_left(ns2_motion *out) {   // 拼对时左只的六轴；没拼对、没开、超过 250 毫秒没更新 → 全 0（同 ns2_get_motion）
    if (!out) return;
    pthread_mutex_lock(&stateMu);
    *out = latestMotionLeft;
    if (!ready || !active || !motionRequested || terminal || !pair_locked() || now_ns() / 1000 - out->host_timestamp_us > 250000)
        memset(out, 0, sizeof *out);
    pthread_mutex_unlock(&stateMu);
}
void ns2_get_mouse_side(int side, ns2_mouse *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu);
    *out = side == 0 || side == 1 ? latestMouse[side] : (ns2_mouse){0};
    if (!ready || !active || terminal || now_ns() / 1000 - out->host_timestamp_us > 250000)
        memset(out, 0, sizeof *out);
    pthread_mutex_unlock(&stateMu);
}
void ns2_stop_rumble(void) {
    pthread_mutex_lock(&stateMu);
    memset(wanted, 0, sizeof wanted); wantedMask = 0; stopMask |= submittedMask;
    if (stopMask && mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    pthread_mutex_unlock(&stateMu);
}
int ns2_shutdown(const char *reason, unsigned timeout_ms) {
    __block NS2Bridge *target;
    __block dispatch_group_t group;
    __block BOOL connected;
    on_queue(^{
        target = disposing ? nil : bridge;
        if (!target) return;
        pthread_mutex_lock(&stateMu);
        connected = ready;
        // 每条已就绪的链路各提交一个零包、各 leave 一次（Pro 只有一条，同改前）
        if (!terminal) for (unsigned slot = 0; slot < 2; slot++) if (linkShared[slot].ready) {
            dispatch_group_enter(shutdownGroup);
            NS2Link *link = target->links[slot]; if (link) link->shutdownEntered = YES;
        }
        terminal = YES; active = NO; linkShared[0].info.ready = linkShared[1].info.ready = 0; refresh_locked(); wantedMask = 0; stopMask |= submittedMask;
        memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
        pthread_mutex_unlock(&stateMu);
        group = shutdownGroup;
        [target stop];
    });
    if (!target) return 1;
    long pending = connected ? dispatch_group_wait(group, dispatch_get_specific(&queueKey) ? DISPATCH_TIME_NOW :
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC)) : 0;
    on_queue(^{
        if (target != bridge) return;
        [target dispose]; bridge = nil;
        stateCallback = NULL; statusCallback = NULL; motionCallback = NULL; callbackContext = NULL;
    });
    LOG("%sNS2 Pro BLE shutdown reason=%s result=%s（仅传输提交，非物理电机确认）", pending ? "【红】" : "", reason ?: "unknown", pending ? "timeout" : "submitted");
    return !pending;
}
