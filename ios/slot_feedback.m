// 本地多手柄的震动与体感：玩家 2–4（槽 1–3，系统扩展手柄各一只；分槽见 ios/controller.m planSlots）。
//   服务层（services/S2A.Services/ControllerFeedback.cs）按玩家把震动交给 s2a_pad_set_rumble_slot、按槽读 s2a_pad_read_motion_slot；
//   导出协议同 Mac（macos/front_mac.m，#520）。原先 iOS 只有玩家 1 一路（controller.m 单例），玩家 2 起的震动和体感都没地方去。
//   震动：每只手柄各一个 Core Haptics 引擎（GCDeviceHaptics），连续事件循环播放、两侧振幅取大调强度，1 秒没新帧自动停；失败退避 / 判死同 ios/haptic_retry.h。
//     强度走设置里同一个震动开关与档位（controller.m s2a_ios_rumble_gain）和同一条手感曲线（s2a_hp_feel）。
//   体感：每只手柄自己的 GCMotion（重力 + 用户加速度 + 角速度），换算成 NS2 坐标（runtime/include/phone_axes.h，同 Mac）；游戏要六轴时才开传感器。
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include "native.h"
#include "s2a_pad.h"
#include "haptic_retry.h"
#include "phone_axes.h"
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
    CHHapticEngine *engine;
    id<CHHapticPatternPlayer> player;   // 能建循环播放器就用循环的；建不了用普通播放器，快到事件末尾时重起
    BOOL loops, plainOnly, playing;
    uint64_t startedNs;
    dispatch_source_t timer;
    s2a_hp_state retry;
}
@end
@implementation S2ASlotRumbler
@end
static NSMapTable<GCController *, S2ASlotRumbler *> *g_rumblers;   // 手柄断开时跟着丢

static void rumbler_stop(S2ASlotRumbler *r) {
    if (!r) return;
    if (r->player && r->playing) [r->player stopAtTime:CHHapticTimeImmediate error:nil];
    r->playing = NO;
    if (r->timer) dispatch_source_set_timer(r->timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}
static void rumbler_reset(S2ASlotRumbler *r) {
    if (!r) return;
    rumbler_stop(r);
    [r->engine stopWithCompletionHandler:nil];
    r->player = nil; r->engine = nil;
}
static void rumbler_fail(S2ASlotRumbler *r, const char *what, NSError *error) {
    BOOL died = s2a_hp_on_fail(&r->retry, up_ns());
    if (!r->retry.reported) {
        r->retry.reported = YES;
        LOG("【红】玩家手柄震动（%s）：%s（%s/%ld）%s", r->device.vendorName.UTF8String ?: "?", what, error.domain.UTF8String ?: "-", error ? (long)error.code : 0L, error.localizedDescription.UTF8String ?: "");
    }
    if (died) LOG("【红】玩家手柄震动：%s 本局停用（连续 %d 次失败）；换手柄会再试", r->device.vendorName.UTF8String ?: "?", S2A_HP_MAX_FAILS);
}
// pair 已按设置倍率与手感曲线缩放（s2a_pad_set_rumble_slot）
static void rumbler_play(S2ASlotRumbler *r, const s2a_pad_vibration pair[2]) {
    float amplitude = 0, weighted = 0, weights = 0;
    for (int i = 0; i < 2; i++) {
        float lo = clampf(pair[i].low_amp, 0, 1), hi = clampf(pair[i].high_amp, 0, 1);
        amplitude = fmaxf(amplitude, fmaxf(lo, hi));
        weighted += lo * clampf(pair[i].low_hz, 0, 1250) + hi * clampf(pair[i].high_hz, 0, 1250);
        weights += lo + hi;
    }
    if (amplitude <= 0.001f || !r->device.haptics) { rumbler_stop(r); return; }
    if (s2a_hp_should_try(&r->retry, up_ns()) == S2A_HP_SKIP) return;
    float hz = weights > 0 ? weighted / weights : 160;
    float sharp = clampf((hz - 160) / 160 * 0.5f + 0.3f, 0, 1);
    NSError *error = nil;
    if (!r->engine) {
        r->engine = [r->device.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!r->engine) { rumbler_fail(r, "无法创建引擎", nil); return; }
        r->engine.playsHapticsOnly = YES;
        __weak CHHapticEngine *weakEngine = r->engine;
        __weak S2ASlotRumbler *weakR = r;
        void (^invalidate)(void) = ^{
            CHHapticEngine *e = weakEngine;
            if (e) dispatch_async(queue(), ^{ S2ASlotRumbler *x = weakR; if (x && x->engine == e) rumbler_reset(x); });
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
        // 循环播放器有的系统 / 手柄建不出来（NSCocoaErrorDomain 4097，同 controller.m system_play_on_queue）：退到普通播放器，丢掉这个引擎从头再来
        if (pattern && !r->plainOnly) {
            id<CHHapticAdvancedPatternPlayer> advanced = [r->engine createAdvancedPlayerWithPattern:pattern error:&error];
            if (advanced) { advanced.loopEnabled = YES; r->player = advanced; r->loops = YES; }
            else { r->plainOnly = YES; rumbler_reset(r); rumbler_play(r, pair); return; }
        } else if (pattern) { r->player = [r->engine createPlayerWithPattern:pattern error:&error]; r->loops = NO; }
        if (!r->player) { rumbler_fail(r, "创建播放器失败", error); rumbler_reset(r); return; }
    }
    uint64_t now = up_ns();
    if (r->playing && !r->loops && now - r->startedNs > SLOT_RESTART_NS) { [r->player stopAtTime:CHHapticTimeImmediate error:nil]; r->playing = NO; }
    if (!r->playing && ![r->player startAtTime:CHHapticTimeImmediate error:&error]) { rumbler_fail(r, "播放失败", error); rumbler_reset(r); return; }
    if (!r->playing) r->startedNs = now;
    r->playing = YES;
    if (![r->player sendParameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]] atTime:CHHapticTimeImmediate error:&error]) {
        rumbler_fail(r, "更新强度失败", error); rumbler_reset(r); return;
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
static void motion_activate(GCController *c, BOOL on) {
    GCMotion *m = c.motion;
    if (m.sensorsRequireManualActivation) m.sensorsActive = on;
}
// 服务层按槽要体感（P2 起）：out[0]；返回 1 有样本、0 没有
__attribute__((visibility("default"), used)) int s2a_pad_read_motion_slot(int slot, s2a_pad_motion out[2]) {
    if (!out) return 0;
    out[0] = out[1] = (s2a_pad_motion){0};
    if (slot <= 0 || slot >= SLOT_PADS || !atomic_load(&g_active)) return 0;
    pthread_mutex_lock(&g_mu);
    int known = g_motion_known[slot];
    if (known) out[0] = g_motion[slot];
    pthread_mutex_unlock(&g_mu);
    return known;
}

// ---------- controller.m 调 ----------
// 槽 slot 换了手柄（inputQueue 上，planSlots 分完槽）：nil = 空槽。旧手柄摘体感回调、停震动；新手柄装体感回调
void s2a_ios_slot_feedback_owner(int slot, GCController *c) {
    if (slot <= 0 || slot >= SLOT_PADS) return;
    pthread_mutex_lock(&g_mu);
    GCController *old = g_owner[slot];
    if (old == c) { pthread_mutex_unlock(&g_mu); return; }
    g_owner[slot] = c; g_since[slot] = up_ns(); g_motion_known[slot] = 0;
    pthread_mutex_unlock(&g_mu);
    if (old) {
        old.motion.valueChangedHandler = nil;
        BOOL elsewhere = NO;
        pthread_mutex_lock(&g_mu); for (int s = 1; s < SLOT_PADS; s++) if (g_owner[s] == old) elsewhere = YES; pthread_mutex_unlock(&g_mu);
        if (!elsewhere) { motion_activate(old, NO); dispatch_async(queue(), ^{ rumbler_stop([g_rumblers objectForKey:old]); }); }
    }
    GCMotion *m = c.motion;
    if (!m) { if (c) LOG("玩家手柄体感：玩家 %d（%s）没有体感传感器", slot + 1, c.vendorName.UTF8String ?: "?"); return; }
    __weak GCController *weakC = c;
    m.valueChangedHandler = ^(GCMotion *motion) {
        if (!(motion.hasRotationRate && motion.hasGravityAndUserAcceleration)) return;
        double gravity[3] = {motion.gravity.x, motion.gravity.y, motion.gravity.z}, user[3] = {motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z};
        double rotation[3] = {motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z};
        float acceleration[3], gyro[3];
        s2a_gc_motion_axes(gravity, user, rotation, acceleration, gyro);
        s2a_pad_motion sample = {up_ns() / 1000, acceleration[0], acceleration[1], acceleration[2], gyro[0], gyro[1], gyro[2]};
        GCController *owner = weakC;
        pthread_mutex_lock(&g_mu);
        for (int s = 1; s < SLOT_PADS; s++) if (owner && g_owner[s] == owner) { g_motion[s] = sample; g_motion_known[s] = 1; }
        pthread_mutex_unlock(&g_mu);
    };
    if (atomic_load(&g_motion_wanted)) motion_activate(c, YES);
}
// 游戏要不要六轴（controller.m s2a_pad_set_motion_enabled）：按需开关各槽手柄的传感器
void s2a_ios_slot_feedback_motion_wanted(int want) {
    want = !!want;
    if (atomic_exchange(&g_motion_wanted, want) == want) return;
    GCController *owners[SLOT_PADS];
    pthread_mutex_lock(&g_mu); for (int s = 0; s < SLOT_PADS; s++) owners[s] = g_owner[s]; pthread_mutex_unlock(&g_mu);
    for (int s = 1; s < SLOT_PADS; s++) if (owners[s]) motion_activate(owners[s], want);
}
// 前后台（controller.m 同 g_slots_active）与震动开关关掉时：后台不收、不震；关掉时马上停
void s2a_ios_slot_feedback_active(int active) {
    atomic_store(&g_active, !!active);
    if (!active) s2a_ios_slot_feedback_stop();
}
void s2a_ios_slot_feedback_stop(void) {
    dispatch_async(queue(), ^{ for (S2ASlotRumbler *r in g_rumblers.objectEnumerator) rumbler_stop(r); });
}
