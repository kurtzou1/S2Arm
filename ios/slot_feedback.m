// 本地多手柄的震动与体感：槽 0 = 玩家 1，槽 1–3 = 玩家 2–4（系统扩展手柄各一只；分槽见 ios/controller.m planSlots）。
//   体感：每只手柄自己的 GCMotion（重力 + 用户加速度 + 角速度），换算成 NS2 坐标（runtime/include/phone_axes.h，同 Mac）；
//     游戏要六轴时才开传感器。玩家 1 的样本由 controller.m 的 s2a_pad_read_motion 经 s2a_pad_read_motion_slot(0, …) 取，
//     服务层按槽读玩家 2–4（s2a_pad_read_motion_slot，ControllerFeedback 按玩家分发）。
//   震动：玩家 2–4 每只手柄各一个 Core Haptics 引擎（GCDeviceHaptics），连续事件循环播放、两侧振幅取大调强度，1 秒没新帧自动停；
//     失败退避 / 判死同 ios/haptic_retry.h。强度走设置里同一个震动开关与档位（controller.m s2a_ios_rumble_gain）和同一条手感曲线（s2a_hp_feel）。
//     玩家 1 的震动仍走 controller.m 的单例（s2a_pad_rumble_session / system_play_on_queue）。
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include "native.h"
#include "s2a_pad.h"
#include "haptic_retry.h"
#include "haptic_safe.h"
#include "phone_axes.h"
#include "motion_pick.h"
int s2a_ios_ble_slot_rumble(int slot, const s2a_pad_vibration raw[2]);   // controller.m：玩家 2–4 是 NS2 Pro 时由它出
int s2a_ios_ble_slot_motion(int slot, s2a_pad_motion *out);
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

#define SLOT_PADS 4   // 同 controller.m S2A_IOS_MAX_PADS
#define SLOT_RESTART_NS (20ull * NSEC_PER_SEC)

float s2a_ios_rumble_gain(void);   // controller.m：设置里的震动开关与档位倍率（0 = 关）

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;   // 下面四组数组
static GCController *g_owner[SLOT_PADS];
static uint64_t g_since[SLOT_PADS];
static s2a_pad_motion g_motion[SLOT_PADS];
static int g_motion_known[SLOT_PADS];
static _Atomic int g_motion_wanted, g_active;
static _Atomic int g_motion_first_logged;   // 首个样本只打一次（真机排查体感用）
static _Atomic int g_motion_capable[SLOT_PADS];   // 槽里手柄有没有体感：0 空槽、1 有 GCMotion、2 系统不给（Joy-Con 一代 / Xbox 等）
static dispatch_queue_t g_q;   // 震动对象只在这条队列上碰

void s2a_ios_slot_feedback_stop(void);
static uint64_t up_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static float clampf(float x, float lo, float hi) { return isfinite(x) ? fminf(hi, fmaxf(lo, x)) : lo; }
static dispatch_queue_t queue(void) {
    static dispatch_once_t once; dispatch_once(&once, ^{ g_q = dispatch_queue_create("dev.s2arm.slot-rumble", DISPATCH_QUEUE_SERIAL); });
    return g_q;
}

// ---------- 震动（每只手柄一份，只在 g_q 上碰）----------
@interface S2ASlotRumbler : NSObject {
@public
    GCController *device;
    // 一路或两路（ios/haptic_retry.h s2a_hp_split）：手柄同时支持 LeftHandle / RightHandle 就左右各一个引擎（[0] 左、[1] 右），否则 [0] 一路合成
    int split;                           // -1 = 还没看过这只手柄，0 = 合成一路，1 = 左右两路
    CHHapticEngine *engine[2];
    id<CHHapticPatternPlayer> player[2];   // 能建循环播放器就用循环的；建不了用普通播放器，快到事件末尾时重起
    BOOL loops[2], playing[2];
    uint64_t startedNs[2];
    BOOL plainOnly;
    dispatch_source_t timer;
    s2a_hp_state retry;
}
@end
@implementation S2ASlotRumbler
- (instancetype)init { if ((self = [super init])) split = -1; return self; }
@end
static NSMapTable<GCController *, S2ASlotRumbler *> *g_rumblers;   // 手柄断开时跟着丢

static void rumbler_stop(S2ASlotRumbler *r) {
    if (!r) return;
    for (int k = 0; k < 2; k++) { if (r->player[k] && r->playing[k]) s2a_hp_stop(r->player[k]); r->playing[k] = NO; }
    if (r->timer) dispatch_source_set_timer(r->timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}
static void rumbler_reset(S2ASlotRumbler *r) {
    if (!r) return;
    rumbler_stop(r);
    for (int k = 0; k < 2; k++) { s2a_hp_engine_stop(r->engine[k]); r->player[k] = nil; r->engine[k] = nil; }
}
static void rumbler_fail(S2ASlotRumbler *r, const char *what, NSError *error) {
    BOOL died = s2a_hp_on_fail(&r->retry, up_ns());
    if (!r->retry.reported) {
        r->retry.reported = YES;
        LOG("【红】玩家手柄震动（%s）：%s（%s/%ld）%s", r->device.vendorName.UTF8String ?: "?", what, error.domain.UTF8String ?: "-", error ? (long)error.code : 0L, error.localizedDescription.UTF8String ?: "");
    }
    if (died) LOG("【红】玩家手柄震动：%s 本局停用（连续 %d 次失败）；换手柄会再试", r->device.vendorName.UTF8String ?: "?", S2A_HP_MAX_FAILS);
}
// 第 k 路播 amplitude / sharpness：建引擎（locality）→ 建播放器 → 起播 → 更新强度。返回 NO = 失败已记（调用方整只手柄复位）或要重来
static BOOL rumbler_channel(S2ASlotRumbler *r, int k, GCHapticsLocality locality, float amplitude, float sharp, BOOL *retry_plain) {
    NSError *error = nil;
    if (!r->engine[k]) {
        r->engine[k] = [r->device.haptics createEngineWithLocality:locality];
        if (!r->engine[k]) {
            if (r->split > 0) { LOG("玩家手柄震动（%s）：分侧引擎建不出来，改两侧合成一路", r->device.vendorName.UTF8String ?: "?"); r->split = 0; *retry_plain = YES; return NO; }
            rumbler_fail(r, "无法创建引擎", nil); return NO; }
        r->engine[k].playsHapticsOnly = YES;
        __weak CHHapticEngine *weakEngine = r->engine[k];
        __weak S2ASlotRumbler *weakR = r;
        void (^invalidate)(void) = ^{
            CHHapticEngine *e = weakEngine;
            if (e) dispatch_async(queue(), ^{ S2ASlotRumbler *x = weakR; if (x && (x->engine[0] == e || x->engine[1] == e)) rumbler_reset(x); });
        };
        r->engine[k].resetHandler = ^{ invalidate(); };
        r->engine[k].stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; invalidate(); };
    }
    if (!r->player[k]) {
        if (![r->engine[k] startAndReturnError:&error]) { rumbler_fail(r, "启动引擎失败", error); return NO; }
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        // 循环播放器有的系统 / 手柄建不出来（NSCocoaErrorDomain 4097，同 controller.m system_play_on_queue）：退到普通播放器，丢掉引擎从头再来
        if (pattern && !r->plainOnly) {
            id<CHHapticAdvancedPatternPlayer> advanced = [r->engine[k] createAdvancedPlayerWithPattern:pattern error:&error];
            if (advanced) { advanced.loopEnabled = YES; r->player[k] = advanced; r->loops[k] = YES; }
            else { r->plainOnly = YES; *retry_plain = YES; return NO; }
        } else if (pattern) { r->player[k] = [r->engine[k] createPlayerWithPattern:pattern error:&error]; r->loops[k] = NO; }
        if (!r->player[k]) { rumbler_fail(r, "创建播放器失败", error); return NO; }
    }
    uint64_t now = up_ns();
    if (r->playing[k] && !r->loops[k] && now - r->startedNs[k] > SLOT_RESTART_NS) { s2a_hp_stop(r->player[k]); r->playing[k] = NO; }
    if (!r->playing[k] && !s2a_hp_start(r->player[k], &error)) { rumbler_fail(r, "播放失败", error); return NO; }
    if (!r->playing[k]) r->startedNs[k] = now;
    r->playing[k] = YES;
    if (!s2a_hp_send(r->player[k], @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]], &error)) {
        rumbler_fail(r, "更新强度失败", error); return NO;
    }
    return YES;
}
// pair 已按设置倍率与手感曲线缩放（s2a_pad_set_rumble_slot）
static void rumbler_play(S2ASlotRumbler *r, const s2a_pad_vibration pair[2]) {
    if (!r->device.haptics) { rumbler_stop(r); return; }
    if (r->split < 0) {
        NSSet<GCHapticsLocality> *loc = r->device.haptics.supportedLocalities;
        r->split = s2a_hp_split([loc containsObject:GCHapticsLocalityLeftHandle], [loc containsObject:GCHapticsLocalityRightHandle]);
        LOG("玩家手柄震动（%s）：%s（支持 %s）", r->device.vendorName.UTF8String ?: "?", r->split ? "左右马达分开震" : "两侧合成一路", [loc.allObjects componentsJoinedByString:@","].UTF8String ?: "");
    }
    float lo[2] = {pair[0].low_amp, pair[1].low_amp}, hi[2] = {pair[0].high_amp, pair[1].high_amp}, lz[2] = {pair[0].low_hz, pair[1].low_hz}, hz[2] = {pair[0].high_hz, pair[1].high_hz};
    float amp[2] = {0, 0}, sharp[2] = {0.3f, 0.3f}; int n = r->split ? 2 : 1;
    if (r->split) for (int k = 0; k < 2; k++) s2a_hp_mix(1, &lo[k], &hi[k], &lz[k], &hz[k], &amp[k], &sharp[k]);
    else s2a_hp_mix(2, lo, hi, lz, hz, &amp[0], &sharp[0]);
    if (fmaxf(amp[0], amp[1]) <= 0.001f) { rumbler_stop(r); return; }
    if (s2a_hp_should_try(&r->retry, up_ns()) == S2A_HP_SKIP) return;
    for (int k = 0; k < n; k++) {
        GCHapticsLocality locality = !r->split ? GCHapticsLocalityDefault : k == 0 ? GCHapticsLocalityLeftHandle : GCHapticsLocalityRightHandle;
        BOOL plain = NO;
        if (!rumbler_channel(r, k, locality, amp[k], sharp[k], &plain)) { rumbler_reset(r); if (plain) rumbler_play(r, pair); return; }
    }
    s2a_hp_on_ok(&r->retry);
    if (!r->timer) {   // 1 秒没新帧自动停（服务层每 250 ms 续一次）
        r->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue());
        __weak S2ASlotRumbler *weakR = r;
        dispatch_source_set_event_handler(r->timer, ^{ rumbler_stop(weakR); });
        dispatch_resume(r->timer);
    }
    dispatch_source_set_timer(r->timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
}

// 服务层按玩家交来的震动（P1 以外，槽 1–3）：values[0] 左、values[1] 右（原始振幅）
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble_slot(int slot, const s2a_pad_vibration values[2]) {
    if (!values || slot <= 0 || slot >= SLOT_PADS || !atomic_load(&g_active)) return;
    if (s2a_ios_ble_slot_rumble(slot, values)) return;   // 这个槽是 NS2 Pro（controller.m，#1428）
    float gain = s2a_ios_rumble_gain();
    if (!(gain > 0)) return;
    pthread_mutex_lock(&g_mu);
    GCController *device = g_owner[slot]; uint64_t since = g_since[slot];
    pthread_mutex_unlock(&g_mu);
    if (!device || up_ns() - since < 2 * NSEC_PER_SEC) return;   // 刚接上：系统还在设定这只手柄，先不碰它的震动（同 Mac）
    s2a_pad_vibration left = values[0], right = values[1];
    left.low_amp = clampf(s2a_hp_feel(clampf(left.low_amp, 0, 1)) * gain, 0, 1); left.high_amp = clampf(s2a_hp_feel(clampf(left.high_amp, 0, 1)) * gain, 0, 1);
    right.low_amp = clampf(s2a_hp_feel(clampf(right.low_amp, 0, 1)) * gain, 0, 1); right.high_amp = clampf(s2a_hp_feel(clampf(right.high_amp, 0, 1)) * gain, 0, 1);
    static _Atomic unsigned logged;
    if ((left.low_amp > 0 || left.high_amp > 0 || right.low_amp > 0 || right.high_amp > 0) && !(atomic_fetch_or(&logged, 1u << slot) & (1u << slot)))
        LOG("玩家手柄震动：玩家 %d（%s）收到游戏震动", slot + 1, device.vendorName.UTF8String ?: "?");
    dispatch_async(queue(), ^{
        if (!g_rumblers) g_rumblers = [NSMapTable weakToStrongObjectsMapTable];
        S2ASlotRumbler *r = [g_rumblers objectForKey:device];
        if (!r) { r = [S2ASlotRumbler new]; r->device = device; [g_rumblers setObject:r forKey:device]; }
        s2a_pad_vibration pair[2] = {left, right};
        rumbler_play(r, pair);
    });
}

// ---------- 体感（每只手柄自己的 GCMotion）----------
// 开关手柄传感器一律在主线程做（#2142 D-Q99N）：GameController 的对象按约定只在主线程用。游戏开六轴是服务层线程调到这里
//   （controller.m s2a_pad_set_motion_enabled），原先就地设 sensorsActive：iPhone + Switch Pro 有的局整局只来全 0 样本（传感器没开），
//   手柄重连（主线程上再设一次）的局才有真值。开完打一行：系统要不要手动开、开后的状态，下一份诊断能直接核
static void motion_activate(GCController *c, BOOL on) {
    if (!c) return;
    void (^go)(void) = ^{
        GCMotion *m = c.motion;
        if (!m) return;
        if (m.sensorsRequireManualActivation) m.sensorsActive = on;
        LOG("玩家手柄体感：%s 传感器%s（系统要手动开 %s，现在 %s）", c.vendorName.UTF8String ?: "?", on ? "开" : "关",
            m.sensorsRequireManualActivation ? "是" : "否", m.sensorsActive ? "开着" : "关着");
    };
    if (NSThread.isMainThread) go(); else dispatch_async(dispatch_get_main_queue(), go);
}
// 手柄给的加速度：正常路径是 gravity + userAcceleration；但 DualSense / Switch Pro 在 iOS 上实测只有 hasRotationRate
//   （hasGravityAndUserAcceleration = NO、hasAttitude = NO，2026-11-14 真机日志），那两项恒为 0。此时退到「总加速度
//   acceleration（含重力）」——数学上就是 gravity + userAcceleration，换算出来一模一样。
//   两者都没有就只报角速度（accel 全 0）：甩 / 转这类靠角速度的动作照常，倾斜瞄准会漂，但总比整路样本丢掉好。
//   姿态四元数反推重力那条没留：手上两只手柄都不给 attitude，验不了符号方向，宁可不要没验证过的分支。
static void motion_acceleration(GCMotion *m, double gravity[3], double user[3]) {
    gravity[0] = gravity[1] = gravity[2] = 0; user[0] = user[1] = user[2] = 0;
    if (m.hasGravityAndUserAcceleration) {
        gravity[0] = m.gravity.x; gravity[1] = m.gravity.y; gravity[2] = m.gravity.z;
        user[0] = m.userAcceleration.x; user[1] = m.userAcceleration.y; user[2] = m.userAcceleration.z;
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // acceleration 在 iOS 14 起弃用，但 DualSense / Pro 上它才是唯一的加速度来源
    double a[3] = {m.acceleration.x, m.acceleration.y, m.acceleration.z};
#pragma clang diagnostic pop
    if (a[0] || a[1] || a[2]) { gravity[0] = a[0]; gravity[1] = a[1]; gravity[2] = a[2]; }
}
// 服务层按槽要体感（玩家 2–4）：out[0]；返回 1 有样本、0 没有。玩家 1 也走这里（controller.m 的 s2a_pad_read_motion）
__attribute__((visibility("default"), used)) int s2a_pad_read_motion_slot(int slot, s2a_pad_motion out[2]) {
    if (!out) return 0;
    out[0] = out[1] = (s2a_pad_motion){0};
    if (slot < 0 || slot >= SLOT_PADS || !atomic_load(&g_active)) return 0;
    if (slot > 0 && s2a_ios_ble_slot_motion(slot, &out[0])) return 1;   // 这个槽是 NS2 Pro（controller.m，#1428）
    pthread_mutex_lock(&g_mu);
    // 按新鲜样本算「有」（motion_pick.c s2a_motion_fresh）：手柄出过一帧就停、或给了体感对象却从不出样本，过了 500 ms 就当没有，
    //   仲裁自动回到手机陀螺仪；旧帧不再喂给游戏
    int known = s2a_motion_fresh(g_motion_known[slot], g_motion[slot].host_timestamp_us, up_ns() / 1000);
    if (known) out[0] = g_motion[slot];
    pthread_mutex_unlock(&g_mu);
    return known;
}

// 槽里手柄有没有体感（controller.m 判「玩家拿着没体感的手柄、游戏却要体感」时说一次）：0 空槽、1 有、2 系统不给
int s2a_ios_slot_motion_capable(int slot) { return slot >= 0 && slot < SLOT_PADS ? atomic_load(&g_motion_capable[slot]) : 0; }
// ---------- controller.m 调 ----------
// 槽 slot 换了手柄（inputQueue 上，planSlots 分完槽；槽 0 = 玩家 1 由 attachSystem / clearSystem 调）：nil = 空槽。
//   旧手柄摘体感回调、停震动；新手柄装体感回调
void s2a_ios_slot_feedback_owner(int slot, GCController *c) {
    if (slot < 0 || slot >= SLOT_PADS) return;
    pthread_mutex_lock(&g_mu);
    GCController *old = g_owner[slot];
    if (old == c) { pthread_mutex_unlock(&g_mu); return; }
    g_owner[slot] = c; g_since[slot] = up_ns(); g_motion_known[slot] = 0;
    pthread_mutex_unlock(&g_mu);
    if (old) {
        old.motion.valueChangedHandler = nil;
        BOOL elsewhere = NO;
        pthread_mutex_lock(&g_mu); for (int s = 0; s < SLOT_PADS; s++) if (s != slot && g_owner[s] == old) elsewhere = YES; pthread_mutex_unlock(&g_mu);
        if (!elsewhere) { motion_activate(old, NO); dispatch_async(queue(), ^{ rumbler_stop([g_rumblers objectForKey:old]); }); }
    }
    GCMotion *m = c.motion;
    atomic_store(&g_motion_capable[slot], !c ? 0 : m ? 1 : 2);
    if (!m) {
        // 系统不给这只手柄六轴。已知：iOS 的 GameController 只对 Switch Pro / DualSense / DualShock 提供 GCMotion，
        //   **Joy-Con 一代的电量 / 按键能读到，但 motion 是 nil**（Apple 论坛 712394，2022 年起如此），这条路没有体感可读
        if (c) LOG("玩家手柄体感：玩家 %d（%s）没有体感传感器（系统不提供 GCMotion：Joy-Con 一代属已知限制）", slot + 1, c.vendorName.UTF8String ?: "?");
        return;
    }
    // 有传感器才打这一行：插上手柄第一眼就能分清「系统没给六轴」和「App 没读」，以及加速度要走哪条兜底
    if (c) LOG("玩家手柄体感：玩家 %d（%s）已接上六轴（旋转 %s、姿态 %s、重力/用户加速度 %s）", slot + 1, c.vendorName.UTF8String ?: "?",
               m.hasRotationRate ? "有" : "无", m.hasAttitude ? "有" : "无", m.hasGravityAndUserAcceleration ? "有" : "无");
    __weak GCController *weakC = c;
    m.valueChangedHandler = ^(GCMotion *motion) {
        if (!motion.hasRotationRate) return;   // 只要系统给角速度就收：加速度由 motion_acceleration 兜底
        double gravity[3], user[3];
        motion_acceleration(motion, gravity, user);
        double rotation[3] = {motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z};
        float acceleration[3], gyro[3];
        s2a_gc_motion_axes(gravity, user, rotation, acceleration, gyro);
        s2a_pad_motion sample = {up_ns() / 1000, acceleration[0], acceleration[1], acceleration[2], gyro[0], gyro[1], gyro[2]};
        GCController *owner = weakC;
        // 六个值全是精确 0：真传感器静止也有 1 g 重力和噪声，做不到——是传感器没开时系统照样回调的空样本（D-Q99N 整局如此）。
        //   不算新鲜样本：s2a_motion_fresh 过 500 ms 判「没有」，仲裁退回手机陀螺仪，不再整局给游戏喂 0
        int blank = s2a_motion_blank(acceleration, gyro);
        pthread_mutex_lock(&g_mu);
        if (!blank) for (int s = 0; s < SLOT_PADS; s++) if (owner && g_owner[s] == owner) { g_motion[s] = sample; g_motion_known[s] = 1; }
        int first = atomic_exchange(&g_motion_first_logged, 1);
        pthread_mutex_unlock(&g_mu);
        if (!first)   // 首个样本：哪条加速度兜底、数值长什么样，一条日志看全（真机排查体感不灵用它）
            LOG("玩家手柄体感：首个样本（%s）：加速度 (%.2f, %.2f, %.2f) g、角速度 (%.1f, %.1f, %.1f) 度/秒",
                owner.vendorName.UTF8String ?: "?", acceleration[0], acceleration[1], acceleration[2], gyro[0], gyro[1], gyro[2]);
    };
    if (atomic_load(&g_motion_wanted)) motion_activate(c, YES);
}
// 游戏要不要六轴（controller.m s2a_pad_set_motion_enabled）：按需开关各槽手柄的传感器
void s2a_ios_slot_feedback_motion_wanted(int want) {
    want = !!want;
    if (atomic_exchange(&g_motion_wanted, want) == want) return;
    GCController *owners[SLOT_PADS];
    pthread_mutex_lock(&g_mu); for (int s = 0; s < SLOT_PADS; s++) owners[s] = g_owner[s]; pthread_mutex_unlock(&g_mu);
    for (int s = 0; s < SLOT_PADS; s++) if (owners[s]) motion_activate(owners[s], want);
}
// 前后台（controller.m 同 g_slots_active）与震动开关关掉时：后台不收、不震；关掉时马上停
void s2a_ios_slot_feedback_active(int active) {
    atomic_store(&g_active, !!active);
    if (!active) s2a_ios_slot_feedback_stop();
}
void s2a_ios_slot_feedback_stop(void) {
    dispatch_async(queue(), ^{ for (S2ASlotRumbler *r in g_rumblers.objectEnumerator) rumbler_stop(r); });
}
