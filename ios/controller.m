// iOS 直接消费系统手柄和 NS2 Pro BLE，不建立虚拟 HID 或本地网络服务。
#import <GameController/GameController.h>
#import "s2a_l10n.h"
#import <CoreHaptics/CoreHaptics.h>
#import "controller.h"
#import <UIKit/UIGestureRecognizerSubclass.h>   // S2ATouchWatch 要改 state
#include "native.h"
#include "s2a_pad.h"
#include "NS2Module.h"
#include "pad_liveness.h"
#include "haptic_retry.h"
#include "ea_rumble.h"   // GameSir G8+ MFi 有线：手柄马达走配件协议（#462）
#include <dlfcn.h>
#include <stdatomic.h>
#include <pthread.h>
#include <math.h>
#include <string.h>
#include <time.h>
// 手机自身当掌机（phone_motion.m）：没有外接 NS2 Pro 时，六轴取手机陀螺仪、震动走手机马达
int s2a_phone_motion_available(void); void s2a_phone_motion_enable(int on); int s2a_phone_motion_read(s2a_pad_motion *out);
uint64_t s2a_phone_rumble_session(void); void s2a_phone_rumble_pair(const s2a_pad_vibration v[2]); void s2a_phone_rumble_stop(void);

@interface S2AController : NSObject
- (instancetype)initWithRoot:(UIView *)root touchEnabled:(void (^)(BOOL))callback;
- (void)setForeground:(BOOL)foreground;
- (void)bleStatus:(ns2_status)status message:(NSString *)message;
@end
static S2AController *g_controller;
static NSString *const adapterPreference = @"S2ANS2ProAdapterEnabled";
static _Atomic int g_adapter_enabled;
// Objective-C 模块首次启用后保留到进程结束；默认关闭的冷启动不加载镜像。
static _Atomic(const ns2_api *) g_ns2;
static _Atomic uint64_t g_session;
static _Atomic uint64_t g_feedback_session;
static _Atomic int g_ble_ready;
static _Atomic int g_ble_foreground;
static _Atomic int g_motion_requested;
static _Atomic int g_phone_motion_wanted;   // 游戏要六轴（不论有没有外接手柄）
static pthread_mutex_t g_motion_mu = PTHREAD_MUTEX_INITIALIZER;
// ready / 连接代次变更与震动 mailbox 写入必须原子，拒绝暂停前挂起的旧请求。
static pthread_mutex_t g_feedback_mu = PTHREAD_MUTEX_INITIALIZER;
#define SYSTEM_SESSION_BASE 0x5359000000000000ull
#define MOTION_ONLY_SESSION 0x535a000000000001ull
#define PHONE_SESSION_BASE 0x5350000000000000ull
static dispatch_queue_t g_system_haptics_queue;
static GCController *g_haptic_device; // 只在 g_system_haptics_queue 上访问
static CHHapticEngine *g_haptic_engine;
static id<CHHapticPatternPlayer> g_haptic_player;   // 能建循环播放器就用循环的；建不了（见 system_play_on_queue）用普通播放器，快到事件末尾时重起
static BOOL g_haptic_loops;          // 当前播放器是循环的
static BOOL g_haptic_plain_only;     // 这只手柄建循环播放器失败过：之后只建普通播放器（换手柄清掉）
static uint64_t g_haptic_started_ns; // 普通播放器这一轮的起播时刻
#define S2A_HAPTIC_RESTART_NS (20ull * NSEC_PER_SEC)
static dispatch_source_t g_haptic_timer;
static BOOL g_haptic_playing;
static s2a_hp_state g_haptic_retry;   // 只在 g_system_haptics_queue 上访问：失败退避与判死（ios/haptic_retry.h）
// 下列字段由 g_feedback_mu 保护，提交方只更新固定快照。
static uint64_t g_system_epoch;
static BOOL g_system_present, g_system_supported, g_system_selected, g_system_pending, g_system_transition;
static s2a_pad_vibration g_system_pair[2];
static BOOL g_phone_selected, g_phone_available, g_phone_pending, g_phone_stop;
static uint64_t g_phone_epoch;
static s2a_pad_vibration g_phone_pair[2];

static void system_stop_on_queue(void) {
    s2a_ea_rumble_stop();
    if (g_haptic_player && g_haptic_playing) [g_haptic_player stopAtTime:CHHapticTimeImmediate error:nil];
    g_haptic_playing = NO;
    if (g_haptic_timer) dispatch_source_set_timer(g_haptic_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}
static void system_reset_on_queue(void) {
    system_stop_on_queue();
    [g_haptic_engine stopWithCompletionHandler:nil];
    g_haptic_player = nil; g_haptic_engine = nil;
}
void s2a_rumble_apply_settings(void);
// 游戏震动的总开关和强度（设置页「按键显示与触感」）：提交前按倍率缩放振幅，手机马达 / 实体手柄 / NS2 Pro 共用
//   手机马达和系统手柄先过 s2a_hp_feel 再乘倍率（同 Mac 宿主 macos/front_mac.m）：游戏的振幅是给 HD 线性马达的，常见值 0.06–0.19，
//   按原值播几乎摸不到，之前「强」档最大一下也只有 0.19 × 1.8 ≈ 0.34。NS2 Pro 本身就是 HD 马达，振幅原样乘倍率
static _Atomic float g_rumble_gain = 1;
static float finite_clamp(float x, float lo, float hi);
static float rumble_scaled(float amp, BOOL feel) {
    amp = finite_clamp(amp, 0, 1);
    return finite_clamp((feel ? s2a_hp_feel(amp) : amp) * atomic_load(&g_rumble_gain), 0, 1);
}
static BOOL rumble_feel(uint64_t session) {
    uint64_t kind = session & 0xffff000000000000ull;
    return kind == PHONE_SESSION_BASE || kind == SYSTEM_SESSION_BASE;
}
static void rumble_scale_pair(const s2a_pad_vibration in[2], s2a_pad_vibration out[2], BOOL feel) {
    for (int i = 0; i < 2; i++) { out[i] = in[i]; out[i].low_amp = rumble_scaled(in[i].low_amp, feel); out[i].high_amp = rumble_scaled(in[i].high_amp, feel); }
}
static float finite_clamp(float x, float lo, float hi) {
    return isfinite(x) ? fminf(hi, fmaxf(lo, x)) : lo;
}
// 震动失败只从这里归档：一行诊断 + 退避 / 判死（决策在 ios/haptic_retry.h，可在 Mac 宿主单测）。
//   带上 domain / code 而不是只有 localizedDescription——「Couldn't communicate with a helper application.」是
//   NSCocoaErrorDomain 4097（NSXPCConnectionInvalid），只看描述分不出是环境连不上还是 pattern 非法。
static void system_fail_on_queue(const char *what, NSError *error) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const char *domain = error.domain.UTF8String ?: "-";
    long code = error ? (long)error.code : 0;
    BOOL died = s2a_hp_on_fail(&g_haptic_retry, now);
    if (!g_haptic_retry.reported) {
        g_haptic_retry.reported = YES;
        LOG("【红】系统手柄震动：%s（%s/%ld）%s——本设备本局最多再试 %d 次（退避 %u ms、%u ms），仍失败就判死，"
            "不再逐帧重建引擎与播放器",
            what, domain, code,
            error.localizedDescription.UTF8String ?: "unknown",
            S2A_HP_MAX_FAILS - 1, S2A_HP_BACKOFF_MS(1), S2A_HP_BACKOFF_MS(2));
    }
    if (died) LOG("【红】系统手柄震动：本设备本局停用（连续 %d 次失败，最后一次 %s/%ld）；换手柄或重新接入会再试一次",
                  S2A_HP_MAX_FAILS, domain, code);
}
// 1 秒没有新的震动帧就停（游戏不发停止也不会一直震）
static void system_arm_stop_timer(void) {
    if (!g_haptic_timer) {
        g_haptic_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_system_haptics_queue);
        dispatch_source_set_event_handler(g_haptic_timer, ^{ system_stop_on_queue(); });
        dispatch_resume(g_haptic_timer);
    }
    dispatch_source_set_timer(g_haptic_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
}
static void system_play_on_queue(s2a_pad_vibration pair[2]) {
    float amplitude = 0, weighted = 0, weights = 0;
    for (int i = 0; i < 2; i++) {
        float lo = finite_clamp(pair[i].low_amp, 0, 1), hi = finite_clamp(pair[i].high_amp, 0, 1);
        amplitude = fmaxf(amplitude, fmaxf(lo, hi));
        weighted += lo * finite_clamp(pair[i].low_hz, 0, 1250) + hi * finite_clamp(pair[i].high_hz, 0, 1250);
        weights += lo + hi;
    }
    if (amplitude <= 0.001f) { system_stop_on_queue(); return; }
    // 走配件协议的手柄（#462）：左右两侧振幅直接发给手柄马达；Core Haptics 会把这只手柄的震动送到机身，不走它
    if (s2a_ea_rumble_active()) {
        s2a_ea_rumble_set(fmaxf(finite_clamp(pair[0].low_amp, 0, 1), finite_clamp(pair[0].high_amp, 0, 1)),
                          fmaxf(finite_clamp(pair[1].low_amp, 0, 1), finite_clamp(pair[1].high_amp, 0, 1)));
        system_arm_stop_timer(); return;
    }
    // 退避期 / 已判死：一个 CoreHaptics 调用都不碰。游戏每秒提交约 29 次震动，这条路径必须廉价。
    if (s2a_hp_should_try(&g_haptic_retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) == S2A_HP_SKIP) return;
    float hz = weights > 0 ? weighted / weights : 160;
    float sharp = finite_clamp((hz - 160) / 160 * 0.5f + 0.3f, 0, 1);
    NSError *error = nil;
    if (!g_haptic_engine) {
        g_haptic_engine = [g_haptic_device.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!g_haptic_engine) { system_fail_on_queue("无法创建引擎", nil); return; }
        g_haptic_engine.playsHapticsOnly = YES;
        // 回调不在本队列执行，且旧引擎的回调可能晚于设备切换。
        __weak CHHapticEngine *weakEngine = g_haptic_engine;
        void (^invalidate)(void) = ^{
            CHHapticEngine *engine = weakEngine;
            if (!engine) return;
            dispatch_async(g_system_haptics_queue, ^{
                if (g_haptic_engine == engine) system_reset_on_queue();
            });
        };
        g_haptic_engine.resetHandler = ^{ invalidate(); };
        g_haptic_engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; invalidate(); };
        // 只打一次：下一次真机日志用这一行就能区分「引擎没建起来」「玩家关了手柄震动」「locality 不对」。
        if (!g_haptic_retry.diagnosed) {
            g_haptic_retry.diagnosed = YES;
            NSArray *localities = g_haptic_device.haptics.supportedLocalities.allObjects;
            LOG("系统手柄震动：引擎已建（locality Default；手柄 %s 支持 %lu 个 locality：%s）",
                g_haptic_device.vendorName.UTF8String ?: "?",
                (unsigned long)localities.count,
                [localities componentsJoinedByString:@","].UTF8String ?: "");
        }
    }
    if (!g_haptic_player) {
        if (![g_haptic_engine startAndReturnError:&error]) { system_fail_on_queue("启动引擎失败", error); system_reset_on_queue(); return; }
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        // 循环播放器在有的系统 / 手柄上建不出来（#584 iPad A16 / iPadOS 27.3 / 小鸡启明星：NSCocoaErrorDomain 4097；Mac 端 11-10
        //   M1 Max / DualSense 同一个错，见 macos/front_mac.m rumble_play_on_queue），同一台机器上普通播放器能建能播：退到普通播放器，
        //   它不能循环，靠下面的重起接上。循环播放器建失败后这个引擎也废了（接着在它上面建普通播放器会报 Client not registered），
        //   所以记下来、丢掉引擎、从头再来；这一下不算失败次数（判死只看普通播放器那条路也走不通）
        if (pattern && !g_haptic_plain_only) {
            id<CHHapticAdvancedPatternPlayer> advanced = [g_haptic_engine createAdvancedPlayerWithPattern:pattern error:&error];
            if (advanced) { advanced.loopEnabled = YES; g_haptic_player = advanced; g_haptic_loops = YES; }
            else {
                LOG("系统手柄震动：循环播放器建不了（%s/%ld），改用普通播放器", error.domain.UTF8String ?: "-", error ? (long)error.code : 0L);
                g_haptic_plain_only = YES; system_reset_on_queue(); system_play_on_queue(pair); return;
            }
        } else if (pattern) { g_haptic_player = [g_haptic_engine createPlayerWithPattern:pattern error:&error]; g_haptic_loops = NO; }
        if (!g_haptic_player) { system_fail_on_queue("创建播放器失败", error); system_reset_on_queue(); return; }
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (g_haptic_playing && !g_haptic_loops && now - g_haptic_started_ns > S2A_HAPTIC_RESTART_NS) {   // 普通播放器：事件 30 秒，连着震到 20 秒就重起一轮
        [g_haptic_player stopAtTime:CHHapticTimeImmediate error:nil]; g_haptic_playing = NO;
    }
    if (!g_haptic_playing && ![g_haptic_player startAtTime:CHHapticTimeImmediate error:&error]) {
        system_fail_on_queue("播放失败", error); system_reset_on_queue(); return;
    }
    if (!g_haptic_playing) g_haptic_started_ns = now;
    g_haptic_playing = YES;
    if (![g_haptic_player sendParameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]] atTime:CHHapticTimeImmediate error:&error]) {
        system_fail_on_queue("更新强度失败", error); system_reset_on_queue(); return;
    }
    s2a_hp_on_ok(&g_haptic_retry);   // 真正播起来了才清零连续失败
    static BOOL logged; if (!logged) { logged = YES; LOG("系统手柄震动：播放 强度 %.2f 锐度 %.2f（%s播放器）", amplitude, sharp, g_haptic_loops ? "循环" : "普通"); }
    system_arm_stop_timer();
}

static void system_select_device(GCController *device) {
    pthread_mutex_lock(&g_feedback_mu);
    g_system_present = device != nil; g_system_supported = device.haptics != nil;
    g_system_selected = NO;
    uint64_t epoch = ++g_system_epoch; g_system_pending = NO; g_system_transition = YES;
    memset(g_system_pair, 0, sizeof g_system_pair);
    dispatch_async(g_system_haptics_queue, ^{
        system_reset_on_queue(); g_haptic_device = device; g_haptic_plain_only = NO;
        s2a_hp_rearm(&g_haptic_retry);   // 换手柄 / 重新接入 = 新机会；已经报过的红不再刷屏
        pthread_mutex_lock(&g_feedback_mu);
        if (epoch == g_system_epoch) g_system_transition = NO;
        pthread_mutex_unlock(&g_feedback_mu);
        s2a_pad_wake();
    });
    pthread_mutex_unlock(&g_feedback_mu);
    if (device) LOG("系统手柄震动：%s", device.haptics ? "支持" : "不支持震动");
    s2a_ea_rumble_refresh();   // 换手柄：重判是不是走配件协议的那只
}
static void system_sync_selection(void) {
    pthread_mutex_lock(&g_feedback_mu);
    BOOL external = s2a_pad_has_controller();
    BOOL selected = g_system_present && external;
    BOOL phone = atomic_load(&g_ble_foreground) && !external;
    BOOL phone_changed = phone != g_phone_selected;
    if (phone != g_phone_selected) {
        g_phone_selected = phone; g_phone_epoch++; g_phone_pending = NO; g_phone_stop = NO;
        memset(g_phone_pair, 0, sizeof g_phone_pair);
        if (!phone) dispatch_async(g_system_haptics_queue, ^{ s2a_phone_rumble_stop(); });
    }
    if (selected != g_system_selected) {
        g_system_selected = selected; uint64_t epoch = ++g_system_epoch; g_system_pending = NO; g_system_transition = YES;
        memset(g_system_pair, 0, sizeof g_system_pair);
        dispatch_async(g_system_haptics_queue, ^{
            system_stop_on_queue();
            pthread_mutex_lock(&g_feedback_mu);
            if (epoch == g_system_epoch) g_system_transition = NO;
            pthread_mutex_unlock(&g_feedback_mu);
            s2a_pad_wake();
        });
    }
    pthread_mutex_unlock(&g_feedback_mu);
    if (phone_changed) s2a_pad_wake();
}
// 设置 / 设备能力在主线程读取，游戏线程只读取受锁保护的快照。
static void phone_refresh_availability(void) {
    BOOL available = s2a_phone_rumble_session() != 0;
    pthread_mutex_lock(&g_feedback_mu);
    BOOL changed = available != g_phone_available;
    if (changed) {
        g_phone_available = available; g_phone_epoch++; g_phone_pending = NO; g_phone_stop = NO;
        memset(g_phone_pair, 0, sizeof g_phone_pair);
        if (!available) dispatch_async(g_system_haptics_queue, ^{ s2a_phone_rumble_stop(); });
    }
    pthread_mutex_unlock(&g_feedback_mu);
    if (changed) s2a_pad_wake();
}
static void phone_submit_locked(const s2a_pad_vibration pair[2], BOOL stop) {
    if (!g_phone_selected || !g_phone_available || g_system_transition || !atomic_load(&g_ble_foreground) || s2a_pad_has_controller()) return;
    if (pair) memcpy(g_phone_pair, pair, sizeof g_phone_pair);
    g_phone_stop = stop;
    if (g_phone_pending) return;
    g_phone_pending = YES;
    uint64_t epoch = g_phone_epoch;
    dispatch_async(g_system_haptics_queue, ^{
        s2a_pad_vibration copy[2]; BOOL valid, stop_now = NO;
        pthread_mutex_lock(&g_feedback_mu);
        valid = epoch == g_phone_epoch && g_phone_selected && g_phone_available && !g_system_transition && atomic_load(&g_ble_foreground);
        if (epoch == g_phone_epoch) g_phone_pending = NO;
        if (valid) { memcpy(copy, g_phone_pair, sizeof copy); stop_now = g_phone_stop; }
        pthread_mutex_unlock(&g_feedback_mu);
        if (valid) { if (stop_now) s2a_phone_rumble_stop(); else s2a_phone_rumble_pair(copy); }
    });
}
// 震动被丢掉时各打一行（每种原因本局只打一次，#466）：原先送到原生层后会话号对不上、手柄没选中、切换中都静默返回，
//   玩家「iOS 上外接手柄一律不震」时日志里看不出断在哪一步。位：1 手机马达代次过期、2 系统手柄不收、4 会话不是任何一路
static _Atomic unsigned g_rumble_drop_logged;
static BOOL rumble_drop_first(unsigned bit) { return !(atomic_fetch_or(&g_rumble_drop_logged, bit) & bit); }
static void system_submit_locked(uint64_t session, const s2a_pad_vibration pair[2]) {
    if (!session || session != (SYSTEM_SESSION_BASE | g_system_epoch) || !g_system_selected || !g_system_supported || g_system_transition || !s2a_pad_has_controller()) {
        if (rumble_drop_first(2))
            LOG("游戏震动：系统手柄这一路不收，丢弃（会话 %#llx / 当前 %#llx，选中 %d，手柄支持震动 %d，切换中 %d，生效来源是实体手柄 %d；本局只报一次）",
                (unsigned long long)session, (unsigned long long)(SYSTEM_SESSION_BASE | g_system_epoch), (int)g_system_selected, (int)g_system_supported,
                (int)g_system_transition, s2a_pad_has_controller());
        return;
    }
    memcpy(g_system_pair, pair, sizeof g_system_pair);
    if (g_system_pending) return;
    g_system_pending = YES;
    dispatch_async(g_system_haptics_queue, ^{
        s2a_pad_vibration copy[2]; BOOL valid;
        pthread_mutex_lock(&g_feedback_mu);
        valid = session == (SYSTEM_SESSION_BASE | g_system_epoch) && g_system_selected && g_system_supported && !g_system_transition;
        if (valid) { memcpy(copy, g_system_pair, sizeof copy); g_system_pending = NO; }
        pthread_mutex_unlock(&g_feedback_mu);
        if (valid) system_play_on_queue(copy);
    });
}
_Static_assert(sizeof(s2a_pad_motion) == 32, "C# motion ABI requires 32 bytes");
_Static_assert(sizeof(s2a_pad_vibration) == 16, "C# vibration ABI requires 16 bytes per side");

// 外设 UUID 只是重连候选，保存在当前 App 沙盒，不需要额外签名权限。
static NSDictionary *read_record(BOOL *ok) {
    *ok = NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *identifier = [defaults stringForKey:@"S2ArmNS2ProLastReadyPeripheralIdentifier"];
    if (!identifier) { *ok = YES; return nil; }
    if (![[NSUUID alloc] initWithUUIDString:identifier]) {
        LOG("【红】手柄记忆：本 App 的设备标识无效"); return nil;
    }
    *ok = YES;
    return @{@"identifier": identifier, @"automatic": @([defaults boolForKey:@"S2ANS2ProEnabled"])};
}
static BOOL write_record(NSString *identifier, BOOL automatic) {
    if (![[NSUUID alloc] initWithUUIDString:identifier]) { LOG("【红】手柄记忆：设备标识无效"); return NO; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:identifier forKey:@"S2ArmNS2ProLastReadyPeripheralIdentifier"];
    [defaults setBool:automatic forKey:@"S2ANS2ProEnabled"];
    LOG("手柄记忆：已保存本 App 记录，自动连接 %s", automatic ? "开" : "关"); return YES;
}

// 手柄 / 触屏按最后一次输入切换（维护者 10-24）：实体手柄输入可能把生效来源从触屏切回手柄（pad.c 触屏接管），
//   这里在输入队列 / BLE 回调里发现变化后派回主线程更新虚拟按键显示；没变时只读一个原子量
static _Atomic int g_shown_external = -1;   // 虚拟按键当前按「实体手柄生效」隐藏着（1）/ 显示着（0）
static void pad_selection_check(void);
static void pad_face_sync(void);

// 本地多手柄（双人同玩）：槽 0 = 玩家 1，仍走 pad.c（触屏 / NS2 Pro / 系统手柄三选一，服务层读 s2a_pad_read_ex）；
//   槽 1–3 = 其余系统扩展手柄各一只，服务层读 s2a_vpad_read_pad（协议同 Mac macos/front_mac.m）。分槽规则共用 runtime/src/pad.c s2a_slot_plan。
//   输入队列上写、服务层输入线程读：按槽原子量（同 front_mac.m）。
// TODO(多手柄 + 震动 / 体感)：震动会话、Core Haptics 引擎与体感现在都只跟槽 0 那只（g_haptic_device / s2a_pad_rumble_session 单例），
//   服务层 ControllerFeedback 也只有一个玩家号；玩家 2 的震动 / 体感要先有按槽的反馈导出与服务层按玩家分发，再接到这里的槽位手柄
#define S2A_IOS_MAX_PADS 4
static _Atomic uint32_t g_slot_buttons[S2A_IOS_MAX_PADS];
static _Atomic int32_t g_slot_sticks[S2A_IOS_MAX_PADS][4];
static _Atomic int g_slot_live = 1;    // 占到的最高槽位 + 1（触屏也算一位，同 Mac 键盘）
static _Atomic int g_slots_active;     // 前台才喂槽 1–3（后台清零，同 pad.c s2a_pad_set_active）
// 系统扩展手柄 → Switch 按键位（0..15 + Home 扩展位 16）与摇杆。玩家 1（publishSystem）与槽 1–3 共用
static void sample_extended(GCExtendedGamepad *pad, uint32_t *out_buttons, int32_t axes[4]) {
    // GameController 的 ABXY 通常按物理方位定义（南/东/西/北 → Nintendo B/A/Y/X）；任天堂手柄按键帽字母上报（#40），判断同 Mac 侧 front_mac.m。
    // buttonOptions（「-」）在部分手柄上为 nil；位序不能动，bit11 留给它，nil 时该位恒 0（与 Mac 侧 front_mac.m 一致）。
    GCControllerButtonInput *options = pad.buttonOptions;
    GCControllerButtonInput *face[4] = {pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY};
    int order[4]; s2a_pad_abxy_order(s2a_pad_kind(pad.controller.productCategory.UTF8String, [pad isKindOfClass:GCXboxGamepad.class],
        [pad isKindOfClass:GCDualShockGamepad.class] || [pad isKindOfClass:GCDualSenseGamepad.class]), s2a_pad_layout(), order);   // 按键布局（pad.c）
    GCControllerButtonInput *keys[16] = {face[order[0]], face[order[1]], face[order[2]], face[order[3]],
        pad.leftThumbstickButton, pad.rightThumbstickButton, pad.leftShoulder, pad.rightShoulder,
        pad.leftTrigger, pad.rightTrigger, pad.buttonMenu, options,
        pad.dpad.left, pad.dpad.up, pad.dpad.right, pad.dpad.down};
    uint32_t buttons = 0;
    for (int i = 0; i < 16; i++) if (keys[i].isPressed) buttons |= 1u << i;
    if (pad.buttonHome.isPressed) buttons |= 1u << 16;   // Home 放扩展位 bit16（同 NS2 手柄）：只用于长按开局内菜单（#276），pad.c 判完就截掉、不进游戏
    s2a_pad_stick(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value, axes);
    s2a_pad_stick(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value, axes + 2);
    *out_buttons = buttons;
}
// 接一只系统手柄（玩家 1 与槽 1–3 同一套）：回调放输入队列；「-」「Home」关系统手势。
//   「-」（buttonOptions）默认是 GCSystemGestureStateEnabled：系统手势识别器先跑、之后才把输入给 app，
//   短按要等它判定失败才转发（真机约 1 秒），长按完全不转发；iOS 还拿它触发录屏。
//   Disabled 的语义是「手势识别器完全不跑，输入直接给 app」（GCControllerElement.h:45），这才是我们要的。
//   不要用 AlwaysReceive：它已废弃（API_DEPRECATED_WITH_REPLACEMENT(…Disabled, ios(14.0, 27.0))），
//   而且语义是「同时发给 app 和手势识别器」——录屏照旧触发。
//   「+」（buttonMenu）不设：头文件没有把它标成系统保留键（系统保留做截图/录屏的是 buttonShare / buttonHome），
//   且真机实测「+」本来即时响应（Enabled 下若绑了手势，短按必然延迟），没有现象就不改。
static void prepare_pad(GCController *next, dispatch_queue_t queue) {
    next.handlerQueue = queue;
    GCExtendedGamepad *pad = next.extendedGamepad;
    if (@available(iOS 14.0, *)) {
        if (pad.buttonOptions) pad.buttonOptions.preferredSystemGestureState = GCSystemGestureStateDisabled;
        // Home 同理（#276）：系统默认拿去开游戏面板 / 回主屏，关掉手势后输入给 App，长按 1.5 秒开局内设置（同长按「+」、四指长按）
        if (pad.buttonHome) pad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled;
    }
}

// BLE 队列已缓存样本；新运动通知唤醒同一 HID 线程，不另建采样线程。
static void ble_motion(const ns2_motion *motion, void *context) {
    if (motion->known && (uintptr_t)context == atomic_load(&g_session) && atomic_load(&g_ble_ready)) s2a_pad_wake();
}

static void ble_input(const ns2_state *state, void *context) {
    pthread_mutex_lock(&g_feedback_mu);
    if (atomic_load(&g_adapter_enabled) && (uintptr_t)context == atomic_load(&g_session) && atomic_load(&g_ble_ready)) {
        int32_t axes[4] = { state->lx, state->ly, state->rx, state->ry };
        s2a_pad_update(S2A_PAD_BLE, 1, (uint32_t)state->buttons, axes);
    }
    pthread_mutex_unlock(&g_feedback_mu);
    pad_selection_check();
}
static void ble_status(ns2_status status, const char *message, void *context) {
    uint64_t session = (uintptr_t)context;
    pthread_mutex_lock(&g_feedback_mu);
    if (session != atomic_load(&g_session)) { pthread_mutex_unlock(&g_feedback_mu); return; }
    BOOL ready = atomic_load(&g_adapter_enabled) && status == NS2_STATUS_READY && atomic_load(&g_ble_foreground);
    if (ready && !atomic_load(&g_ble_ready)) atomic_fetch_add(&g_feedback_session, 1);
    atomic_store(&g_ble_ready, ready);
    int32_t axes[4] = {0}; s2a_pad_update(S2A_PAD_BLE, ready, 0, axes);
    pthread_mutex_unlock(&g_feedback_mu);
    pad_selection_check();
    NSString *text = [NSString stringWithUTF8String:message ?: ""];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session == atomic_load(&g_session)) [g_controller bleStatus:status message:text];
    });
}

static void log_controllers(int why);   // 下面 systemChanged 旁：GameController 枚举诊断（#456）
@implementation S2AController {
    __weak UIView *_root;
    UIButton *_connect;
    void (^_touchEnabled)(BOOL);
    dispatch_queue_t _inputQueue;
    GCController *_system; // 仅 inputQueue 访问。
    uint64_t _systemRev;      // 仅 inputQueue 访问：断开复查代次，旧 timer 靠它作废。
    BOOL _systemRecheck;      // 仅 inputQueue 访问：已排了一次延迟复查。
    // 仅 inputQueue 访问：各槽的手柄身份与强引用。手柄蓝牙休眠 / 断开时系统会释放 GCController，只存裸指针会变悬空（同 front_mac.m pad_owner），
    //   所以强引用；每次分槽整表重建，不在线的置 nil 才真正释放
    const void *_slotId[S2A_IOS_MAX_PADS];
    GCController *_slotOwner[S2A_IOS_MAX_PADS];
    NSString *_rememberedIdentifier;
    BOOL _adapterEnabled, _foreground, _hasSystem, _bleStarted, _bleBusy, _bleWanted, _blePaused, _bleResuming;
}
- (instancetype)initWithRoot:(UIView *)root touchEnabled:(void (^)(BOOL))callback {
    if (!(self = [super init])) return nil;
    _touchEnabled = [callback copy];
    _root = root;
    _inputQueue = dispatch_queue_create("s2arm.controller.input", DISPATCH_QUEUE_SERIAL);
    g_system_haptics_queue = dispatch_queue_create("s2arm.controller.haptics", DISPATCH_QUEUE_SERIAL);
    s2a_rumble_apply_settings();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemChanged:) name:GCControllerDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemChanged:) name:GCControllerDidDisconnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    pad_face_sync();
    log_controllers(0);
    return self;
}
- (void)createConnectionButton {
    UIView *root = _root;
    _connect = [UIButton buttonWithType:UIButtonTypeSystem];
    _connect.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration = UIButtonConfiguration.filledButtonConfiguration;
    configuration.baseBackgroundColor = [UIColor colorWithWhite:0 alpha:.7];
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.title = S2AL(@"controller.connect");
    _connect.configuration = configuration;
    _connect.titleLabel.adjustsFontForContentSizeCategory = YES;
    _connect.accessibilityHint = S2AL(@"controller.connect.hint");
    [_connect addTarget:self action:@selector(connectTapped) forControlEvents:UIControlEventTouchUpInside];
    _connect.layer.zPosition = 1001;
    [root addSubview:_connect];
    [NSLayoutConstraint activateConstraints:@[
        [_connect.centerXAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.centerXAnchor],
        [_connect.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:52],
        [_connect.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [_connect.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:16],
        [_connect.trailingAnchor constraintLessThanOrEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-16]
    ]];
}
- (BOOL)loadModule {
    if (atomic_load(&g_ns2)) return YES;
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"NS2Pro.framework/NS2Pro"];
    void *image = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!image) { LOG("【红】NS2 Pro：模块加载失败，%s", dlerror()); return NO; }
    const ns2_api *(*entry)(void) = dlsym(image, "ns2_module_api");
    const ns2_api *api = entry ? entry() : NULL;
    if (!api || api->abi_version != NS2_MODULE_ABI_VERSION || api->struct_size != sizeof(ns2_api)) {
        LOG("【红】NS2 Pro：模块接口版本不匹配"); return NO;
    }
    atomic_store(&g_ns2, api);
    LOG("NS2 Pro：已按设置加载适配模块");
    return YES;
}
- (void)reloadAdapterPreference {
    // 缺少设置值即关闭；历史连接意愿不能打开这个每 App 开关。
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:adapterPreference];
    if (enabled == _adapterEnabled) return;
    _adapterEnabled = enabled;
    pthread_mutex_lock(&g_feedback_mu);
    atomic_store(&g_adapter_enabled, enabled);
    pthread_mutex_unlock(&g_feedback_mu);
    if (enabled) {
        [self createConnectionButton];
    } else {
        [self stopBLE:"adapter disabled in Settings"];
        pthread_mutex_lock(&g_motion_mu);
        atomic_store(&g_motion_requested, 0);
        pthread_mutex_unlock(&g_motion_mu);
        _bleWanted = NO; _rememberedIdentifier = nil;
        [_connect removeFromSuperview]; _connect = nil;
    }
    s2a_pad_wake();
    LOG("NS2 Pro：本 App 适配%s", enabled ? "开启" : "关闭");
}
// 手柄按键布局（定义表 game_settings.v1.json 的 padFace：auto 自动（缺省）/ switch / xbox，旧值 letter / position 照认）：
//   偏好一变就转给 pad.c，下一次按键即按新布局（不用重启）
static void pad_face_sync(void) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:@"padFace"];
    if (v) s2a_pad_layout_set(s2a_pad_layout_parse(v.UTF8String));
}
- (void)settingsChanged:(NSNotification *)notification {
    pad_face_sync();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_foreground) return;
        s2a_phone_motion_enable(atomic_load(&g_phone_motion_wanted) && !atomic_load(&g_ble_ready));
        phone_refresh_availability();
        BOOL previous = self->_adapterEnabled;
        [self reloadAdapterPreference];
        if (previous == self->_adapterEnabled) return;
        if (self->_adapterEnabled) [self reloadRecord];
        [self selectSystem];
        if (self->_adapterEnabled && !self->_hasSystem && self->_bleWanted) [self resumeBLE];
        [self updateVisibility];
    });
}
- (void)setTitle:(NSString *)title hint:(NSString *)hint {
    UIButtonConfiguration *configuration = _connect.configuration; configuration.title = title;
    _connect.configuration = configuration; _connect.accessibilityHint = hint;
}
- (void)reloadRecord {
    if (!_adapterEnabled) return;
    BOOL ok; NSDictionary *record = read_record(&ok);
    if (!ok) { _bleWanted = NO; return; }
    if (record) {
        _rememberedIdentifier = record[@"identifier"];
        _bleWanted = [record[@"automatic"] boolValue];
        [NSUserDefaults.standardUserDefaults setObject:_rememberedIdentifier forKey:@"S2ArmNS2ProLastReadyPeripheralIdentifier"];
        LOG("手柄记忆：读取本 App 设备记录，自动连接 %s", _bleWanted ? "开" : "关");
    } else {
        _rememberedIdentifier = nil;
        _bleWanted = NO;
    }
}
- (void)updateVisibility {
    BOOL external = s2a_pad_has_controller();
    atomic_store(&g_shown_external, external);
    _connect.hidden = !_adapterEnabled || !_foreground || external;
    _touchEnabled(_foreground && !external);
}
- (void)publishSystem:(GCExtendedGamepad *)pad {
    uint32_t buttons; int32_t axes[4];
    sample_extended(pad, &buttons, axes);
    s2a_pad_update(S2A_PAD_SYSTEM, 1, buttons, axes);
    pad_selection_check();
}
// 槽 1–3 采一次写进原子量（空槽 / 后台写零）。只在 inputQueue 上跑
- (void)publishSlot:(int)slot {
    uint32_t buttons = 0; int32_t axes[4] = {0};
    GCExtendedGamepad *pad = _slotOwner[slot].extendedGamepad;
    if (pad && atomic_load(&g_slots_active)) { sample_extended(pad, &buttons, axes); buttons &= 0xffffu; }   // Home 扩展位只给玩家 1 开菜单用
    for (int i = 0; i < 4; i++) atomic_store(&g_slot_sticks[slot][i], axes[i]);
    atomic_store(&g_slot_buttons[slot], buttons);
}
// 分槽（只在 inputQueue 上跑）：在线扩展手柄按连接顺序交给 s2a_slot_plan，整表重建；槽 1–3 换人时装 / 摘回调。
//   返回该占槽 0（玩家 1）的手柄，由 selectSystemLocked 照原有的判活 / 延迟复查逻辑接成系统手柄；槽 0 的回调归 attachSystem / clearSystem 管
- (GCController *)planSlots {
    const void *ids[9]; GCController *ctrls[9]; int n = 0;   // 数组留得比槽位多，超出的交给 s2a_slot_plan 判 -1 丢弃
    GCController *current = _system;
    // 当前玩家 1 的对象自身可用就算在线（同 s2a_system_action：快照抖动期不让出槽 0）
    if (current.extendedGamepad) { ids[n] = (__bridge const void *)current; ctrls[n] = current; n++; }
    for (GCController *c in GCController.controllers) {
        if (!c.extendedGamepad || c == current) continue;
        if (n >= 9) break;
        ids[n] = (__bridge const void *)c; ctrls[n] = c; n++;
    }
    int slot_of[9];
    int live = s2a_slot_plan(_slotId, ids, n, S2A_IOS_MAX_PADS, slot_of);
    GCController *old[S2A_IOS_MAX_PADS];
    for (int i = 0; i < S2A_IOS_MAX_PADS; i++) { old[i] = _slotOwner[i]; _slotId[i] = NULL; _slotOwner[i] = nil; }
    for (int j = 0; j < n; j++) if (slot_of[j] >= 0) { _slotId[slot_of[j]] = ids[j]; _slotOwner[slot_of[j]] = ctrls[j]; }
    __weak S2AController *weakSelf = self;
    for (int i = 1; i < S2A_IOS_MAX_PADS; i++) {
        if (old[i] == _slotOwner[i]) continue;   // 原样在槽里：回调已装
        if (old[i] && old[i] != _system) old[i].extendedGamepad.valueChangedHandler = nil;   // 离开的手柄摘回调（强引用随 old 一起释放）
        GCController *next = _slotOwner[i];
        if (!next) continue;
        prepare_pad(next, _inputQueue);
        next.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
            S2AController *owner = weakSelf;
            if (!owner) return;
            for (int k = 1; k < S2A_IOS_MAX_PADS; k++) if (owner->_slotOwner[k].extendedGamepad == pad) { [owner publishSlot:k]; break; }
        };
        LOG("系统手柄：%s 接入玩家 %d", next.vendorName.UTF8String ?: "GameController", i + 1);
    }
    for (int i = 1; i < S2A_IOS_MAX_PADS; i++) [self publishSlot:i];   // 空槽清零；新接入的立即采一次
    if (atomic_exchange(&g_slot_live, live) != live) LOG("系统手柄：槽位 %d 个（含触屏 / 玩家 1）", live);
    return _slotOwner[0];
}
// 换到另一个系统手柄对象：旧对象的 handler 必须摘掉（它已经不在快照里），新对象装上同一套回调。
// 只在 inputQueue 上跑。
- (void)attachSystem:(GCController *)next {
    if (next == _system) return;
    _system.extendedGamepad.valueChangedHandler = nil;
    _system = next;
    _systemRev++;          // 挂起的延迟复查作废：已经有新对象了
    _systemRecheck = NO;
    system_select_device(next);   // 震动侧跟着换设备（原 selectSystem 里的调用，挪到这里）
    prepare_pad(next, _inputQueue);   // 回调队列 + 「-」「Home」关系统手势
    __weak S2AController *weakSelf = self;
    next.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
        S2AController *owner = weakSelf;
        if (owner && pad == owner->_system.extendedGamepad) [owner publishSystem:pad];
    };
    LOG("系统手柄：接入 %s", next.vendorName.UTF8String ?: "GameController");
}
// 确认断开：摘 handler 并把共享内存里的系统手柄状态清零。只在 inputQueue 上跑。
- (void)clearSystem {
    GCController *old = _system;
    _system = nil;
    _systemRev++;
    _systemRecheck = NO;
    system_select_device(nil);    // 震动侧一并摘掉（原 selectSystem 里 next 为 nil 时同样会调）
    old.extendedGamepad.valueChangedHandler = nil;
    s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL);
}
// 第一次发现当前手柄不可用：不立刻清零，S2A_SYSTEM_RECHECK_MS 后复查一次。只在 inputQueue 上跑。
- (void)scheduleSystemRecheck {
    _systemRecheck = YES;
    uint64_t rev = ++_systemRev;
    __weak S2AController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(S2A_SYSTEM_RECHECK_MS * NSEC_PER_MSEC)), _inputQueue, ^{
        S2AController *owner = weakSelf;
        if (!owner) return;
        // 期间已重新接入 / 已有更新的决定：本次复查不生效。
        if (rev != owner->_systemRev || !owner->_systemRecheck) return;
        owner->_systemRecheck = NO;
        // 复查一律按前台语义：真切了后台时 setForeground: 自己会走 selectSystem 立刻清零，不靠这条 timer。
        [owner selectSystemLocked:YES mayClear:YES];
        BOOL hasSystem = owner->_system != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            S2AController *inner = weakSelf;
            if (!inner) return;
            inner->_hasSystem = hasSystem;
            [inner updateVisibility];
        });
    });
}
// 只在 inputQueue 上跑：判活、换对象、延迟复查、确认清零的唯一入口。
- (void)selectSystemLocked:(BOOL)foreground mayClear:(BOOL)mayClear {
    NSArray<GCController *> *controllers = GCController.controllers;
    GCController *current = _system;
    // 玩家 1 = 占槽 0 的那只（s2a_slot_plan）：还在线的手柄保留原槽，所以两只时 1 号断开、2 号仍是玩家 2，不顶上来当玩家 1
    GCController *slot0 = [self planSlots];
    GCController *candidate = slot0 != current ? slot0 : nil;
    s2a_sys_state state = {
        .foreground = foreground,
        .has_current = current != nil,
        .current_alive = current.extendedGamepad != nil,
        .candidate_ready = candidate != nil,
        .may_clear = mayClear,
    };
    const char *name = current.vendorName.UTF8String ?: "GameController";
    switch (s2a_system_action(state)) {
        case S2A_SYS_PUBLISH:
            if (mayClear) LOG("系统手柄：%s 已恢复，保留 handler", name);
            [self publishSystem:current.extendedGamepad];
            break;
        case S2A_SYS_ATTACH:
            [self attachSystem:candidate];
            [self publishSystem:candidate.extendedGamepad];
            break;
        case S2A_SYS_DEFER:
            // 抖动期不清 handler、不清零：这期间实体手柄的按键仍然走 publishSystem 进共享内存。
            // 每条通知都打一行（诊断用：日志里数得出 iOS 到底发了几次 Disconnect），复查只排一次。
            LOG("系统手柄：%s 从快照消失（%d 个在场），延迟确认中", name, (int)controllers.count);
            if (!_systemRecheck) [self scheduleSystemRecheck];
            break;
        case S2A_SYS_CLEAR:
            if (mayClear) LOG("系统手柄：%s 确认断开（%d ms 复查仍不可用，%d 个在场），清零并摘 handler", name, S2A_SYSTEM_RECHECK_MS, (int)controllers.count);
            else LOG("系统手柄：%s 断开（不在前台），清零并摘 handler", name);
            [self clearSystem];
            break;
        case S2A_SYS_NONE:
        default:
            break;
    }
}
- (void)selectSystem {
    __block BOOL hasSystem;
    BOOL foreground = _foreground;
    dispatch_sync(_inputQueue, ^{
        [self selectSystemLocked:foreground mayClear:NO];
        hasSystem = self->_system != nil;
    });
    _hasSystem = hasSystem;
    if (_foreground && _hasSystem) [self stopBLE:"system controller selected"];
    [self updateVisibility];
}
// 诊断（#456）：列出 GameController 枚举到的全部设备与 profile。只有带 extendedGamepad 的才会被选成系统手柄并打「接入」，
//   第三方手柄的 Switch 模式若被枚举成只有 micro / 没有标准 profile，或根本没被枚举，原先日志里一片空白，分不清卡在系统层还是 App 层
static void log_controllers(int why) {   // why：0 启动时、1 连接通知、2 断开通知
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (GCController *c in GCController.controllers)
        [list addObject:[NSString stringWithFormat:@"%@|%@|%@", c.vendorName ?: @"?", c.productCategory ?: @"?",
                         c.extendedGamepad ? @"extended" : c.microGamepad ? @"micro" : @"none"]];
    const char *items = [list componentsJoinedByString:@"; "].UTF8String ?: "";
    if (why == 0) LOG("系统手柄：启动时枚举到 %d 个 %s", (int)list.count, items);
    else if (why == 1) LOG("系统手柄：连接通知，枚举到 %d 个 %s", (int)list.count, items);
    else LOG("系统手柄：断开通知，枚举到 %d 个 %s", (int)list.count, items);
}
- (void)systemChanged:(NSNotification *)notification {
    // 框架通知线程不作假设，设备输入本身仍只在 inputQueue 处理。
    BOOL connected = [notification.name isEqualToString:GCControllerDidConnectNotification];
    dispatch_async(dispatch_get_main_queue(), ^{ log_controllers(connected ? 1 : 2); [self selectSystem]; });
}
- (void)stopBLE:(const char *)reason {
    _blePaused = _bleResuming = NO;
    if (!_bleStarted) return;
    pthread_mutex_lock(&g_feedback_mu);
    atomic_fetch_add(&g_session, 1); atomic_store(&g_ble_ready, 0);
    s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL);
    pthread_mutex_unlock(&g_feedback_mu);
    atomic_load(&g_ns2)->shutdown(reason, 0); // 不在主线程等待电机或连接完成。
    s2a_pad_wake();
    _bleStarted = _bleBusy = NO;
    [self setTitle:S2AL(@"controller.connect") hint:S2AL(@"controller.connect.hint")];
}
- (void)startBLE {
    if (!_adapterEnabled || !_foreground || _hasSystem) return;
    if (![self loadModule]) { [self setTitle:S2AL(@"controller.moduleFailed") hint:S2AL(@"controller.moduleFailed.hint")]; return; }
    const ns2_api *api = atomic_load(&g_ns2);
    if (_bleStarted) { if (api->rescan()) _bleBusy = YES; return; }
    pthread_mutex_lock(&g_feedback_mu);
    uint64_t session = atomic_fetch_add(&g_session, 1) + 1;
    pthread_mutex_unlock(&g_feedback_mu);
    _bleStarted = api->start_with_motion(ble_input, ble_status, ble_motion, (void *)(uintptr_t)session) != 0;
    if (_bleStarted) {
        pthread_mutex_lock(&g_motion_mu);
        api->set_motion_enabled(atomic_load(&g_motion_requested));
        pthread_mutex_unlock(&g_motion_mu);
    }
    _bleBusy = _bleStarted;
    if (!_bleStarted) [self setTitle:S2AL(@"controller.connectFailed") hint:S2AL(@"controller.connectFailed.hint")];
}
- (void)resumeBLE {
    if (!_adapterEnabled || !_foreground || _hasSystem) return;
    if (_bleStarted) {
        if (_blePaused && atomic_load(&g_ns2)->resume()) {
            _bleResuming = YES;
            _bleBusy = YES;
            [self setTitle:S2AL(@"controller.resuming") hint:S2AL(@"controller.resuming.hint")];
            return;
        }
        // A retained link may have disconnected while iOS suspended the app. Start one bounded known-device attempt.
        [self stopBLE:"retained link unavailable on foreground"];
    }
    [self startBLE];
}
- (void)connectTapped {
    if (!_adapterEnabled || !_foreground) return;
    if (![self loadModule]) { [self setTitle:S2AL(@"controller.moduleFailed") hint:S2AL(@"controller.moduleFailed.hint")]; return; }
    if (atomic_load(&g_ns2)->authorization_denied()) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
        return;
    }
    if (_bleBusy) {
        // 取消当前前台尝试，不清除本 App 的成功记录。
        _bleWanted = NO;
        [self stopBLE:"player cancelled"]; [self updateVisibility]; return;
    }
    [self startBLE];
}
- (void)bleStatus:(ns2_status)status message:(NSString *)message {
    if (!_adapterEnabled) return;
    // UIKit may receive a queued READY after entering the background; it must not reopen the logical session.
    if (status == NS2_STATUS_READY && (!_foreground || !atomic_load(&g_ble_ready))) return;
    LOG("NS2 Pro：状态 %d，%s", status, message.UTF8String);
    if (status == NS2_STATUS_READY) {
        _blePaused = _bleResuming = NO;
        _bleWanted = YES;
        ns2_info info; atomic_load(&g_ns2)->get_info(&info);
        _rememberedIdentifier = [NSString stringWithUTF8String:info.identifier];
        write_record(_rememberedIdentifier, YES);
    }
    if (status == NS2_STATUS_DISCONNECTED || status == NS2_STATUS_UNAVAILABLE || status == NS2_STATUS_ERROR || status == NS2_STATUS_STOPPED) {
        BOOL retry = _bleResuming && _foreground && !_hasSystem && _bleWanted;
        _blePaused = _bleResuming = NO;
        if (retry) {
            // One failed soft resume may rebuild the link; a failure of that new connection does not retry again.
            [self stopBLE:"soft resume failed"];
            [self startBLE];
            return;
        }
    }
    _bleBusy = _bleResuming || status == NS2_STATUS_SCANNING || status == NS2_STATUS_CONNECTING || status == NS2_STATUS_INITIALIZING ||
        status == NS2_STATUS_SUSPENDING || status == NS2_STATUS_RESUMING;
    if (_bleBusy) [self setTitle:status == NS2_STATUS_SCANNING ? S2AL(@"controller.scanning") : S2AL(@"controller.connecting") hint:S2AL(@"controller.connecting.hint")];
    else if (status != NS2_STATUS_READY) {
        BOOL denied = atomic_load(&g_ns2)->authorization_denied();
        [self setTitle:denied ? S2AL(@"controller.allowBluetooth") : status == NS2_STATUS_UNAVAILABLE ? S2AL(@"controller.turnOnBluetooth") : S2AL(@"controller.reconnect") hint:message];
    }
    [self updateVisibility];
}
- (void)setForeground:(BOOL)foreground {
    S2A_MAIN_ONLY("-[S2AController setForeground:]");
    if (_foreground == foreground) { if (foreground) [self settingsChanged:nil]; return; }
    _foreground = foreground;
    pthread_mutex_lock(&g_feedback_mu);
    BOOL wasReady = atomic_load(&g_ble_ready);
    atomic_store(&g_ble_foreground, foreground);
    if (!foreground) atomic_store(&g_ble_ready, 0);
    pthread_mutex_unlock(&g_feedback_mu);
    s2a_pad_set_active(foreground);
    atomic_store(&g_slots_active, foreground);   // 槽 1–3：下面 selectSystem 分槽时按它采样或清零
    if (foreground) { phone_refresh_availability(); [self reloadAdapterPreference]; if (_adapterEnabled) [self reloadRecord]; }
    if (!foreground && _bleStarted) {
        _bleResuming = NO;
        // Preserve the physical callback context; resume creates a fresh feedback epoch only after new input is ready.
        if ((wasReady || _blePaused) && atomic_load(&g_ns2)->suspend()) {
            _blePaused = YES;
            _bleBusy = NO;
            s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL);
            LOG("NS2 Pro：后台暂停输入和反馈，保留 BLE 链路候选");
        } else [self stopBLE:"scene background before a retainable link"];
    }
    [self selectSystem];
    system_sync_selection();
    if (foreground && _adapterEnabled && !_hasSystem) {
        if (_bleWanted) [self resumeBLE];
        else if (_blePaused) [self stopBLE:"automatic connection disabled"];
    }
    if (foreground) [self settingsChanged:nil];
    else { s2a_phone_motion_enable(0); s2a_phone_rumble_stop(); }
}
@end

// 长按「+」或 Home 开快捷菜单（外接手柄时四指长按够不着屏幕）：每个新按下的序号交给 diag.m 计时复查（s2a_diag_menu_hold）
static void menu_hold_check(void) {
    static _Atomic uint64_t armed;
    uint64_t press = s2a_pad_plus_press();
    if (!press || atomic_exchange(&armed, press) == press) return;
    void s2a_diag_menu_hold(uint64_t press); s2a_diag_menu_hold(press);
}
static void pad_selection_check(void) {
    menu_hold_check();
    system_sync_selection();
    int external = s2a_pad_has_controller();
    if (atomic_load(&g_shown_external) != external) dispatch_async(dispatch_get_main_queue(), ^{ [g_controller updateVisibility]; });
}
// 屏幕被碰（含虚拟按键隐藏时碰到游戏画面）：连着实体手柄时改由触屏生效、显示虚拟按键。只观察、不拦截任何触摸
@interface S2ATouchWatch : UIGestureRecognizer
@end
@implementation S2ATouchWatch
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    if (s2a_pad_prefer_touch()) {
        system_sync_selection();
        pthread_mutex_lock(&g_feedback_mu);
        if (atomic_load(&g_ble_ready)) {
            atomic_fetch_add(&g_feedback_session, 1);
            atomic_load(&g_ns2)->stop_rumble();
        }
        pthread_mutex_unlock(&g_feedback_mu);
        [g_controller updateVisibility];
    }
    self.state = UIGestureRecognizerStateFailed;
}
@end
void s2a_controller_attach(UIView *root, void (^touchEnabled)(BOOL)) {
    if (g_controller) return;
    g_controller = [[S2AController alloc] initWithRoot:root touchEnabled:touchEnabled];
    [g_controller setForeground:YES];
    S2ATouchWatch *watch = [S2ATouchWatch new];   // 不吃游戏 / 虚拟按键的触摸（同 diag.m 四指长按的设法）
    watch.cancelsTouchesInView = NO; watch.delaysTouchesBegan = NO; watch.delaysTouchesEnded = NO;
    [root addGestureRecognizer:watch];
}
// 前后台切换会改手柄 / 虚拟手柄的 UIKit 状态（selectSystem → updateVisibility、S2AVPadView setInputEnabled → clearTouches），只许在主线程做。
//   v0.3.0 起挂起 / 恢复在串行队列 s2a.ios-lifecycle 上跑（app.m s2a_ios_suspend），从那里直接调会在 UIImageView setHidden 处触发 UIKit 主线程断言、
//   整个 App 被系统中止（11-11 真机：局中一失焦就崩，崩溃报告 EXC_BREAKPOINT，队列 s2a.ios-lifecycle）。不在主线程就排到主队列：
//   用 async 不用 sync——调用方可能正持着主线程要等的东西；主队列先进先出，前后台的先后顺序不变
void s2a_controller_set_foreground(int foreground) {
    BOOL fg = foreground != 0;
    if (NSThread.isMainThread) { [g_controller setForeground:fg]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{ [g_controller setForeground:fg]; });
}

// 多手柄槽位（服务层 InputPump 按符号查，协议同 macos/front_mac.m）：count = 占到的最高槽位 + 1；
//   read_pad 读槽 1–3。槽 0（玩家 1）服务层走 s2a_pad_read_ex，这里不代读——那次读会清掉 pad.c 的短按锁存，回零
__attribute__((visibility("default"), used)) int s2a_vpad_pad_count(void) { return atomic_load(&g_slot_live); }
__attribute__((visibility("default"), used)) uint32_t s2a_vpad_read_pad(int index, int32_t *sticks) {
    if (index < 1 || index >= S2A_IOS_MAX_PADS) { for (int i = 0; i < 4; i++) sticks[i] = 0; return 0; }
    uint32_t buttons = atomic_load(&g_slot_buttons[index]);
    for (int i = 0; i < 4; i++) sticks[i] = atomic_load(&g_slot_sticks[index][i]);
    return buttons;
}

// C# 反馈提交只碰固定 mailbox / 快照，不从游戏线程等待 CoreBluetooth 或 UIKit。
__attribute__((visibility("default"), used)) uint64_t s2a_pad_rumble_session(void) {
    pthread_mutex_lock(&g_feedback_mu);
    BOOL external = s2a_pad_has_controller();
    BOOL system = external && g_system_present;
    uint64_t session = !g_system_transition && system && g_system_selected ? (SYSTEM_SESSION_BASE | g_system_epoch) :
        (!g_system_transition && !system && external && atomic_load(&g_adapter_enabled) && atomic_load(&g_ble_ready) ? atomic_load(&g_feedback_session) : 0);
    BOOL foreground = atomic_load(&g_ble_foreground);
    BOOL phone = !g_system_transition && g_phone_selected && g_phone_available && foreground && !external;
    uint64_t phone_epoch = g_phone_epoch;
    pthread_mutex_unlock(&g_feedback_mu);
    if (session) return session;
    if (phone) return PHONE_SESSION_BASE | phone_epoch;
    return foreground ? MOTION_ONLY_SESSION : 0;
}
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration raw[2]) {
    if (!raw) return;
    s2a_pad_vibration values[2]; rumble_scale_pair(raw, values, rumble_feel(session));
    if ((session & 0xffff000000000000ull) == PHONE_SESSION_BASE) {
        pthread_mutex_lock(&g_feedback_mu);
        if (session == (PHONE_SESSION_BASE | g_phone_epoch)) phone_submit_locked(values, NO);
        else if (rumble_drop_first(1)) LOG("游戏震动：手机马达会话 %#llx 已过期（当前代次 %llu），丢弃；本局只报一次", (unsigned long long)session, (unsigned long long)g_phone_epoch);
        pthread_mutex_unlock(&g_feedback_mu); return;
    }
    pthread_mutex_lock(&g_feedback_mu);
    if ((session & 0xffff000000000000ull) == SYSTEM_SESSION_BASE) {
        system_submit_locked(session, values);
    } else if (!g_system_present && s2a_pad_has_controller() && atomic_load(&g_adapter_enabled) && session && session == atomic_load(&g_feedback_session) && atomic_load(&g_ble_ready)) {
        ns2_vibration pair[2] = {
            { values[0].low_amp, values[0].low_hz, values[0].high_amp, values[0].high_hz },
            { values[1].low_amp, values[1].low_hz, values[1].high_amp, values[1].high_hz }
        };
        atomic_load(&g_ns2)->send_pair_lease(pair, 1000);
    } else if (rumble_drop_first(4)) {
        LOG("游戏震动：会话 %#llx 不是手机马达 / 系统手柄 / NS2 Pro 任何一路（%s；有系统手柄 %d，生效来源是实体手柄 %d），丢弃；本局只报一次",
            (unsigned long long)session, session == MOTION_ONLY_SESSION ? "只给体感的会话：没有能震的设备" : session ? "会话号对不上" : "会话 0",
            (int)g_system_present, s2a_pad_has_controller());
    }
    pthread_mutex_unlock(&g_feedback_mu);
}
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz) {
    BOOL feel = rumble_feel(session); low_amp = rumble_scaled(low_amp, feel); high_amp = rumble_scaled(high_amp, feel);
    if ((session & 0xffff000000000000ull) == PHONE_SESSION_BASE) {   // 手机马达只有一个，合成两侧
        pthread_mutex_lock(&g_feedback_mu);
        if (side < 2 && session == (PHONE_SESSION_BASE | g_phone_epoch)) {
            s2a_pad_vibration pair[2] = {g_phone_pair[0], g_phone_pair[1]};
            pair[side] = (s2a_pad_vibration){low_amp, low_hz, high_amp, high_hz};
            phone_submit_locked(pair, NO);
        }
        pthread_mutex_unlock(&g_feedback_mu); return;
    }
    pthread_mutex_lock(&g_feedback_mu);
    if ((session & 0xffff000000000000ull) == SYSTEM_SESSION_BASE) {
        if (side < 2 && session == (SYSTEM_SESSION_BASE | g_system_epoch)) {
            s2a_pad_vibration pair[2] = {g_system_pair[0], g_system_pair[1]};
            pair[side] = (s2a_pad_vibration){low_amp, low_hz, high_amp, high_hz};
            system_submit_locked(session, pair);
        }
    } else if (!g_system_present && s2a_pad_has_controller() && atomic_load(&g_adapter_enabled) && session && session == atomic_load(&g_feedback_session) && atomic_load(&g_ble_ready))
        atomic_load(&g_ns2)->send_lease(side, low_amp, low_hz, high_amp, high_hz, 1000);
    else if (rumble_drop_first(4))
        LOG("游戏震动：会话 %#llx 不是手机马达 / 系统手柄 / NS2 Pro 任何一路（单侧提交；有系统手柄 %d，生效来源是实体手柄 %d），丢弃；本局只报一次",
            (unsigned long long)session, (int)g_system_present, s2a_pad_has_controller());
    pthread_mutex_unlock(&g_feedback_mu);
}
// 设置页改了开关或强度：立即生效。关掉时三路马上停，不等游戏下一次提交
void s2a_rumble_apply_settings(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    static const float gains[6] = {0.35f, 0.7f, 1, 1.4f, 1.8f, 5};   // 同定义表 launchers/shared/game_settings.v1.json rumbleLevel.scale
    id on = [d objectForKey:@"S2ARumbleOn"], level = [d objectForKey:@"S2ARumbleLevel"];
    int lv = level ? (int)[level integerValue] : 2; lv = lv < 0 ? 0 : lv > 5 ? 5 : lv;
    float gain = (on && ![on boolValue]) ? 0 : gains[lv];
    float old = atomic_exchange(&g_rumble_gain, gain);
    if (gain == 0 && old != 0 && g_system_haptics_queue) {
        dispatch_async(g_system_haptics_queue, ^{ system_stop_on_queue(); s2a_phone_rumble_stop(); });
        if (atomic_load(&g_adapter_enabled) && atomic_load(&g_ble_ready)) atomic_load(&g_ns2)->stop_rumble();
    }
    LOG("游戏震动：%s，强度档 %d（倍率 %.2f）", gain > 0 ? "开" : "关", lv, gain);
}
// 菜单里切震动档位 / 打开游戏震动时试震一下（11-09 维护者：「点击强弱机器是没有反应的……切换的时候手机震一下让玩家有感知」）：
//   走游戏震动同一条出口（s2a_pad_rumble_session 选手机马达或手柄，s2a_pad_set_rumble_pair 按当前档位倍率缩放），震 0.3 秒，几档之间摸得出差别。
//   基准振幅 0.06（游戏常见值；手机马达 / 系统手柄过 s2a_hp_feel 后约 0.5）：弱 0.18、较弱 0.36、标准 0.51、较强 0.72、强 0.92、震爆我 1（倍率见 s2a_rumble_apply_settings）
void s2a_rumble_preview(void) {
    if (atomic_load(&g_rumble_gain) <= 0) return;
    uint64_t session = s2a_pad_rumble_session(); if (!session) { LOG("游戏震动：试震跳过（现在没有可震的设备）"); return; }
    const s2a_pad_vibration v[2] = {{0.06f, 160, 0.06f, 320}, {0.06f, 160, 0.06f, 320}};
    s2a_pad_set_rumble_pair(session, v);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ s2a_pad_stop_rumble(session); });
}
__attribute__((visibility("default"), used)) void s2a_pad_stop_rumble(uint64_t session) {
    if ((session & 0xffff000000000000ull) == PHONE_SESSION_BASE) {
        pthread_mutex_lock(&g_feedback_mu);
        if (session == (PHONE_SESSION_BASE | g_phone_epoch)) phone_submit_locked(NULL, YES);
        pthread_mutex_unlock(&g_feedback_mu); return;
    }
    pthread_mutex_lock(&g_feedback_mu);
    if ((session & 0xffff000000000000ull) == SYSTEM_SESSION_BASE) {
        s2a_pad_vibration zero[2] = {0}; system_submit_locked(session, zero);
    } else if (atomic_load(&g_adapter_enabled) && session && session == atomic_load(&g_feedback_session) && atomic_load(&g_ble_ready)) atomic_load(&g_ns2)->stop_rumble();
    pthread_mutex_unlock(&g_feedback_mu);
}
__attribute__((visibility("default"), used)) void s2a_pad_set_motion_enabled(int enabled) {
    pthread_mutex_lock(&g_motion_mu);
    int want = !!enabled;
    atomic_store(&g_phone_motion_wanted, want);
    enabled = want && atomic_load(&g_adapter_enabled);
    const ns2_api *api = atomic_load(&g_ns2);
    if (atomic_exchange(&g_motion_requested, enabled) != enabled && api && atomic_load(&g_adapter_enabled)) api->set_motion_enabled(enabled);
    int ns2 = enabled && atomic_load(&g_ble_ready);
    pthread_mutex_unlock(&g_motion_mu);
    s2a_phone_motion_enable(want && atomic_load(&g_ble_foreground) && !ns2);   // 后台与游戏不要六轴时关闭。
}
__attribute__((visibility("default"), used)) int s2a_pad_read_motion(s2a_pad_motion *out) {
    if (!out) return 0;
    ns2_motion motion = {0};
    pthread_mutex_lock(&g_motion_mu);
    if (atomic_load(&g_adapter_enabled) && atomic_load(&g_ble_ready) && atomic_load(&g_motion_requested)) atomic_load(&g_ns2)->get_motion(&motion);
    pthread_mutex_unlock(&g_motion_mu);
    *out = (s2a_pad_motion){0};
    if (!motion.known) {
        // 没有外接手柄的样本：手机自身当掌机六轴（游戏要六轴时才开着）；中途连上了外接手柄则在它出样本那次关掉手机传感器
        return atomic_load(&g_phone_motion_wanted) ? s2a_phone_motion_read(out) : 0;
    }
    s2a_phone_motion_enable(0);
    *out = (s2a_pad_motion){motion.host_timestamp_us,
        motion.acceleration_x, motion.acceleration_y, motion.acceleration_z,
        motion.gyro_x, motion.gyro_y, motion.gyro_z};
    return 1;
}
