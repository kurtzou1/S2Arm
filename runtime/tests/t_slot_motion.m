// 手柄传感器跟手柄在槽的时间走（#2142，11-26；ios/slot_feedback.m）：蓝牙第三方 Pro 模式手柄按游戏开关传感器时多数局只回一个全 0 样本，
//   同一台 iPhone、同类手柄在 NX2Apple（引擎 seedds/nxnative dm/host/motion_apple.h）上正常——它分到玩家就开、离开才关、回前台补开。
// 用假手柄 / 假 GCMotion（记 sensorsActive 被设的次数）跑生产的 s2a_ios_slot_feedback_owner / _motion_wanted / _active，期望按上面的规则手写：
//   ① 分到槽、游戏还没要六轴：传感器开着，设了 1 次
//   ② 游戏要 → 不要 → 要：传感器一直开着，不再被设（还是 1 次）
//   ③ 进后台（模拟 iOS 把传感器关掉）再回前台：补开，开着、共 2 次；已在前台再报一次前台：不重复设（仍 2 次）
//   ④ 手柄离开槽：传感器关
//   ⑤ 不用手动开的手柄（系统自己管）：分到槽、前后台都不去设（0 次）
#import <Foundation/Foundation.h>
#include "../../ios/slot_feedback.m"
#include <stdio.h>

int s2a_ios_ble_slot_rumble(int slot, const s2a_pad_vibration raw[2]) { (void)slot; (void)raw; return 0; }
int s2a_ios_ble_slot_motion(int slot, s2a_pad_motion *out) { (void)slot; (void)out; return 0; }
float s2a_ios_rumble_gain(void) { return 1.0f; }   // 震动增益（settings.m）：本测不涉震动

@interface TSensor : NSObject
@property BOOL sensorsRequireManualActivation, hasRotationRate, hasAttitude, hasGravityAndUserAcceleration;
@property(nonatomic) BOOL sensorsActive;
@property unsigned sets;
@property(copy) void (^valueChangedHandler)(id);
@end
@implementation TSensor
- (void)setSensorsActive:(BOOL)v { _sensorsActive = v; _sets++; }
@end
@interface TPad : NSObject
@property TSensor *motion;
@property NSString *vendorName;
@end
@implementation TPad
@end
static TPad *pad(BOOL manual) {
    TPad *p = [TPad new]; p.vendorName = @"Pro Controller"; p.motion = [TSensor new];
    p.motion.sensorsRequireManualActivation = manual; p.motion.hasRotationRate = YES; return p;
}
static unsigned checks, failed;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failed += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); } while (0)

int main(void) {
    @autoreleasepool {
        s2a_ios_slot_feedback_active(1);
        TPad *a = pad(YES);
        s2a_ios_slot_feedback_owner(0, (GCController *)a);
        CHECK(a.motion.sensorsActive && a.motion.sets == 1, "① 分到槽、游戏没要六轴：期望 开着 / 设 1 次 → 真结果 %s / %u 次", a.motion.sensorsActive ? "开着" : "关着", a.motion.sets);
        s2a_ios_slot_feedback_motion_wanted(1); s2a_ios_slot_feedback_motion_wanted(0); s2a_ios_slot_feedback_motion_wanted(1);
        CHECK(a.motion.sensorsActive && a.motion.sets == 1, "② 游戏要 / 不要 / 要：期望 开着 / 仍 1 次 → 真结果 %s / %u 次", a.motion.sensorsActive ? "开着" : "关着", a.motion.sets);
        s2a_ios_slot_feedback_active(0);
        a.motion.sensorsActive = NO;   // iOS 在后台把要手动开的传感器关了（这一次也计数：2）
        s2a_ios_slot_feedback_active(1);
        CHECK(a.motion.sensorsActive && a.motion.sets == 3, "③ 后台被关、回前台：期望 开着 / 共 3 次（含模拟系统关的 1 次）→ 真结果 %s / %u 次", a.motion.sensorsActive ? "开着" : "关着", a.motion.sets);
        s2a_ios_slot_feedback_active(1);
        CHECK(a.motion.sets == 3, "③ 已在前台再报前台：期望 不重设（3 次）→ 真结果 %u 次", a.motion.sets);
        s2a_ios_slot_feedback_owner(0, nil);
        CHECK(!a.motion.sensorsActive, "④ 离开槽：期望 关着 → 真结果 %s", a.motion.sensorsActive ? "开着" : "关着");
        TPad *b = pad(NO);
        s2a_ios_slot_feedback_owner(1, (GCController *)b); s2a_ios_slot_feedback_active(0); s2a_ios_slot_feedback_active(1); s2a_ios_slot_feedback_motion_wanted(0);
        CHECK(b.motion.sets == 0, "⑤ 不用手动开的手柄：期望 设 0 次 → 真结果 %u 次", b.motion.sets);
    }
    printf("%s t_slot_motion：%u 项，%u 项不符\n", failed ? "✗" : "✓", checks, failed);
    return failed ? 1 : 0;
}
