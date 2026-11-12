// 手机自身当掌机：没有外接 NS2 Pro 时，iPhone 的陀螺仪 / 加速度当 Switch 掌机六轴，HD Rumble 走手机马达（10-26 维护者：0100C2500FC20000 要倾斜瞄准，
//   触屏玩家原先没有六轴来源、也没有震动）。controller.m 在 NS2 不可用时转到这里，C# 侧（ControllerFeedback → Ryujinx MotionInput / UpdateSixAxis）不变。
// 六轴：CoreMotion deviceMotion 拉取（游戏启用 SixAxis 时才开传感器，200 Hz），输出与 NS2 同一约定——NS2 原始坐标、单位 g 与 度/秒。
//   换算：NS2 原始坐标以手柄正面为基（x 右、y 上沿、z 正面法线、加速度报支撑反力），掌机正面即屏幕，raw =（屏幕右、屏幕上、出屏），
//   横屏左右两套旋转 + 加速度取反（CoreMotion 报重力方向），见 runtime/src/phone_axes.c。
// 震动：Core Haptics 一条循环连续事件，动态参数改强度（左右两侧高 / 低频振幅取最大）与锐度（按振幅加权的频率，160 Hz → 0.3、320 Hz → 0.8），
//   20 ms 节流；振幅 0 持续 1 秒停播放器、2 秒停引擎（省电）。
// 设置：系统设置「手机陀螺仪」S2APhoneGyro、「手机震动」S2APhoneHaptics，缺省开（没设过的键按开读）。
#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreHaptics/CoreHaptics.h>
#include "native.h"
#include "s2a_pad.h"
#include "phone_axes.h"
#include "phone_rumble_mailbox.h"
#include <stdatomic.h>
#include <pthread.h>

#define S2A_PHONE_SESSION_BASE 0x5048000000000000ull   // 手机马达的震动会话号（与 NS2 的小整数会话号不相交）
void s2a_phone_rumble_stop(void);

static BOOL pref_on(NSString *key) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : YES;
}

// ---------- 屏幕朝向（主线程刷新，HID 线程读）----------
// 屏幕「右」「上」在机身坐标（CoreMotion x、y）里的方向，由屏幕的界面坐标空间换算到它的固定坐标空间（= 原生面板，机身坐标与之对齐）得出，
//   不按界面朝向枚举猜：iPhone Duo 内屏原生面板是横的，界面横屏时屏幕右就是机身 x，按「竖屏面板横过来」再转 90° 就把 X / Y 对调了（#804）。
//   普通 iPhone 原生面板是竖的，算出来与原来横屏左 / 右的写死换算相同。打包成一个整数：4 个分量各占 2 位（值 + 1）
static int basis_pack(int rx, int ry, int ux, int uy) { return (rx + 1) | (ry + 1) << 2 | (ux + 1) << 4 | (uy + 1) << 6; }
static _Atomic int g_basis = (0 + 1) | (-1 + 1) << 2 | (1 + 1) << 4 | (0 + 1) << 6;   // 缺省 = 竖屏面板横屏右（右 = −y、上 = x）
static int unit(CGFloat v) { return v > 0.5 ? 1 : v < -0.5 ? -1 : 0; }
static void orient_refresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class] && ![s.session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplayNonInteractive]) {   // 朝向取手机屏的场景，不取外接屏的（extdisplay.m）
                UIScreen *sc = ((UIWindowScene *)s).screen; id<UICoordinateSpace> cs = sc.coordinateSpace, fs = sc.fixedCoordinateSpace;
                CGPoint o = [cs convertPoint:CGPointZero toCoordinateSpace:fs], r = [cs convertPoint:CGPointMake(1, 0) toCoordinateSpace:fs], d = [cs convertPoint:CGPointMake(0, 1) toCoordinateSpace:fs];
                // 固定坐标 y 朝下、机身 y 朝上：右 =（Δx, −Δy）；屏幕上 = 界面 −y 方向 =（−Δx, +Δy）
                int rx = unit(r.x - o.x), ry = -unit(r.y - o.y), ux = -unit(d.x - o.x), uy = unit(d.y - o.y);
                if ((rx || ry) && (ux || uy)) {
                    int nb = basis_pack(rx, ry, ux, uy), was = atomic_exchange(&g_basis, nb);
                    if (was != nb) LOG("手机六轴：屏幕右 = 机身 (%d, %d)、上 = 机身 (%d, %d)（原生面板 %.0fx%.0f）", rx, ry, ux, uy, sc.nativeBounds.size.width, sc.nativeBounds.size.height);
                }
                break;
            }
    });
}

// ---------- 六轴 ----------
static pthread_mutex_t g_mm_mu = PTHREAD_MUTEX_INITIALIZER;
static CMMotionManager *g_mm;
static int g_mm_on;
static dispatch_source_t g_orient_timer;

int s2a_phone_motion_available(void) { return pref_on(@"S2APhoneGyro"); }

void s2a_phone_motion_enable(int on) {
    pthread_mutex_lock(&g_mm_mu);
    on = on && pref_on(@"S2APhoneGyro");
    if (on && !g_mm_on) {
        if (!g_mm) g_mm = [CMMotionManager new];
        if (!g_mm.deviceMotionAvailable) { static int said; if (!said++) LOG("【红】手机六轴：本机没有 deviceMotion"); pthread_mutex_unlock(&g_mm_mu); return; }
        g_mm.deviceMotionUpdateInterval = 1.0 / 200;
        [g_mm startDeviceMotionUpdates];
        orient_refresh();
        g_orient_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_orient_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(g_orient_timer, ^{ orient_refresh(); });
        dispatch_resume(g_orient_timer);
        g_mm_on = 1;
        LOG("手机六轴：开（CoreMotion 200 Hz，没有外接手柄时当掌机六轴）");
    } else if (!on && g_mm_on) {
        [g_mm stopDeviceMotionUpdates];
        if (g_orient_timer) { dispatch_source_cancel(g_orient_timer); g_orient_timer = nil; }
        g_mm_on = 0;
        LOG("手机六轴：关");
    }
    pthread_mutex_unlock(&g_mm_mu);
}

int s2a_phone_motion_read(s2a_pad_motion *out) {
    pthread_mutex_lock(&g_mm_mu);
    CMDeviceMotion *dm = g_mm_on ? g_mm.deviceMotion : nil;
    pthread_mutex_unlock(&g_mm_mu);
    if (!dm) return 0;
    // 机身坐标：总加速度 = 重力 + 用户加速度（g，重力方向），角速度 rad/s；换算见 runtime/src/phone_axes.c
    double acc[3] = {dm.gravity.x + dm.userAcceleration.x, dm.gravity.y + dm.userAcceleration.y, dm.gravity.z + dm.userAcceleration.z};
    double gyr[3] = {dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z};
    float a[3], g[3];
    int b = atomic_load(&g_basis), right[2] = {(b & 3) - 1, (b >> 2 & 3) - 1}, up[2] = {(b >> 4 & 3) - 1, (b >> 6 & 3) - 1};
    s2a_phone_axes_basis(right, up, acc, gyr, a, g);
    *out = (s2a_pad_motion){ (uint64_t)(dm.timestamp * 1e6), a[0], a[1], a[2], g[0], g[1], g[2] };
    return 1;
}

// ---------- 震动 ----------
// 提交侧（HID 泵在 _rumbleLock 内同步调 s2a_pad_set_rumble*）只写 mailbox 就返回，一个 CoreHaptics 调用都不碰。
//   契约在 compat/.../NpadDevices.cs:49：「Output hooks run under this same lock. They must not call back from native
//   code or wait for transport IO.」首次建引擎 / 起引擎 / 建播放器要抢 AVAudioSession（真机实测首次 2049 ms 音频 stall），
//   全部搬到 runtime/src/phone_rumble_mailbox.c 的反馈线程上，所以它不再出现在任何 HID 调用栈里。
//   真机 A/B：开手机震动 3 次崩溃时长 36 / 54 / 66 秒各不相同，崩前最后一行都停在「手机震动：首次」——
//   绑的是「首次震动那一刻」而不是帧号，冷启动挪走即拆掉这个绑定点。
static pthread_mutex_t g_hp_mu = PTHREAD_MUTEX_INITIALIZER;   // 只由反馈线程获取；与 _rumbleLock 无获取顺序，无环
static CHHapticEngine *g_eng;
static id<CHHapticAdvancedPatternPlayer> g_player;
static uint64_t g_last_ns, g_zero_since_ns;
static int g_playing;
static _Atomic uint64_t g_hp_session = S2A_PHONE_SESSION_BASE + 1;
static _Atomic int g_hp_stale;      // reset / stopped 回调只置位：回调不在本线程，不能在里面抢 g_hp_mu
static _Atomic int g_hp_mb_ready;   // 反馈线程起过一次就不再进 pthread_create
// capabilitiesForHardware 的线程安全性 Apple 没写：只在后台探一次，之后所有调用方（含 g_feedback_mu 锁内的
//   phone_refresh_availability）只读这个缓存。
enum { HP_CAPS_UNKNOWN = -1, HP_CAPS_PROBING = -2, HP_CAPS_NO = 0, HP_CAPS_YES = 1 };
static _Atomic int g_hp_caps = HP_CAPS_UNKNOWN;

static uint64_t hp_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void hp_apply(const s2a_pad_vibration v[2], int kind);
static void hp_probe_async(void);

static int hp_supported(void) {   // 只读缓存；第一次未知时乐观放行并异步探一次（真不支持由反馈线程报红）
    int c = atomic_load(&g_hp_caps);
    if (c == HP_CAPS_YES) return 1;
    if (c == HP_CAPS_NO) return 0;
    if (c == HP_CAPS_UNKNOWN) hp_probe_async();
    return 1;
}

uint64_t s2a_phone_rumble_session(void) {
    if (!pref_on(@"S2APhoneHaptics") || !hp_supported()) return 0;
    return atomic_load(&g_hp_session);
}
int s2a_phone_rumble_owns(uint64_t session) { return session && session == atomic_load(&g_hp_session); }

static void hp_mb_ensure(void) {
    if (atomic_load(&g_hp_mb_ready)) return;
    s2a_phone_rumble_mailbox_start(hp_apply);   // 幂等；只建线程，不碰 CoreHaptics
    atomic_store(&g_hp_mb_ready, 1);
}

static void hp_probe_async(void) {
    int expected = HP_CAPS_UNKNOWN;
    if (!atomic_compare_exchange_strong(&g_hp_caps, &expected, HP_CAPS_PROBING)) return;   // 并发只探一次
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
        if (!ok) {
            atomic_store(&g_hp_caps, HP_CAPS_NO);
            static int said; if (!said++) LOG("【红】手机震动：本机不支持触觉（CoreHaptics supportsHaptics = NO）");
            return;
        }
        atomic_store(&g_hp_caps, HP_CAPS_YES);
        // 预热时机：走到这里说明游戏已经在查震动会话（渲染与音频会话早就建好），才异步把首次建引擎做掉；
        //   不在 app 启动早期去抢 AVAudioSession。
        if (pref_on(@"S2APhoneHaptics")) { hp_mb_ensure(); s2a_phone_rumble_mailbox_warm(); }
    });
}

static int hp_start(void) {   // 持 g_hp_mu
    NSError *e = nil;
    if (!g_eng) {
        g_eng = [[CHHapticEngine alloc] initAndReturnError:&e];
        if (!g_eng) { static int said; if (!said++) LOG("【红】手机震动：建引擎失败 %s", e.localizedDescription.UTF8String); return 0; }
        g_eng.playsHapticsOnly = YES; g_eng.autoShutdownEnabled = YES;
        g_eng.resetHandler = ^{ atomic_store(&g_hp_stale, 1); };   // 回调在 CoreHaptics 自己的线程：只置位，回反馈线程再收拾
        g_eng.stoppedHandler = ^(CHHapticEngineStoppedReason r) { (void)r; atomic_store(&g_hp_stale, 1); };
    }
    if (![g_eng startAndReturnError:&e]) { static int said; if (!said++) LOG("【红】手机震动：起引擎失败 %s", e.localizedDescription.UTF8String); return 0; }
    if (!g_player) {
        CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]] relativeTime:0 duration:30];
        CHHapticPattern *pt = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&e];
        g_player = pt ? [g_eng createAdvancedPlayerWithPattern:pt error:&e] : nil;
        if (!g_player) { static int said; if (!said++) LOG("【红】手机震动：建播放器失败 %s", e.localizedDescription.UTF8String); return 0; }
        g_player.loopEnabled = YES;
    }
    return 1;
}

// 反馈线程：整段 CoreHaptics 唯一入口。g_hp_mu 只在这里取，提交侧从不持有它。
static void hp_apply(const s2a_pad_vibration v[2], int kind) {
    pthread_mutex_lock(&g_hp_mu);
    if (atomic_exchange(&g_hp_stale, 0)) { g_player = nil; g_playing = 0; }   // 引擎被系统复位：下一次 hp_start 会重新 startAndReturnError
    if (kind == S2A_PHONE_RUMBLE_WARM) { hp_start(); pthread_mutex_unlock(&g_hp_mu); return; }
    if (kind == S2A_PHONE_RUMBLE_STOP || !v) {
        if (g_player && g_playing) { [g_player stopAtTime:CHHapticTimeImmediate error:nil]; g_playing = 0; }
        g_zero_since_ns = 0;
        pthread_mutex_unlock(&g_hp_mu); return;
    }
    float amp = 0, hz = 0;
    for (int i = 0; i < 2; i++) {
        float la = v[i].low_amp, ha = v[i].high_amp;
        if (la > amp) amp = la; if (ha > amp) amp = ha;
        hz += la * v[i].low_hz + ha * v[i].high_hz;
    }
    float wsum = v[0].low_amp + v[0].high_amp + v[1].low_amp + v[1].high_amp;
    hz = wsum > 0 ? hz / wsum : 160;
    if (amp > 1) amp = 1;
    float sharp = (hz - 160) / 160 * 0.5f + 0.3f; if (sharp < 0) sharp = 0; if (sharp > 1) sharp = 1;
    uint64_t t = hp_now_ns();
    if (amp <= 0.01f) {
        if (!g_zero_since_ns) g_zero_since_ns = t;
        if (g_player && g_playing && t - g_zero_since_ns > 1000000000ull) { [g_player stopAtTime:CHHapticTimeImmediate error:nil]; g_playing = 0; }
        if (g_player && g_playing) [g_player sendParameters:@[[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:0 relativeTime:0]] atTime:CHHapticTimeImmediate error:nil];
        pthread_mutex_unlock(&g_hp_mu); return;
    }
    g_zero_since_ns = 0;
    if (t - g_last_ns < 20000000ull && g_playing) { pthread_mutex_unlock(&g_hp_mu); return; }   // 20 ms 节流
    g_last_ns = t;
    if (hp_start()) {
        NSError *e = nil;
        if (!g_playing) { if ([g_player startAtTime:CHHapticTimeImmediate error:&e]) g_playing = 1; }
        [g_player sendParameters:@[
            [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amp relativeTime:0],
            [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]] atTime:CHHapticTimeImmediate error:nil];
        static int said; if (!said++) LOG("手机震动：首次 强度 %.2f 锐度 %.2f（%.0f Hz）", amp, sharp, hz);
    }
    pthread_mutex_unlock(&g_hp_mu);
}

// HID 调用栈上：只写 mailbox（memcpy + signal），返回时一次 IO 都没有。
void s2a_phone_rumble_pair(const s2a_pad_vibration v[2]) {
    if (!pref_on(@"S2APhoneHaptics")) { s2a_phone_rumble_stop(); return; }
    if (!v) return;
    hp_mb_ensure();
    s2a_phone_rumble_mailbox_submit(v);
}

void s2a_phone_rumble_stop(void) {
    if (!atomic_load(&g_hp_mb_ready)) return;   // 还没提交过任何震动：没有在播的东西
    s2a_phone_rumble_mailbox_submit_stop();     // STOP 在信箱里压过 PLAY，连续提交饿不死它
}
