// 只有通用物理描述的系统手柄（ios/pad_profile.h，#2244 单只一代 Joy-Con）：假描述（假键 / 假方向键）跑生产的认单只与采样，期望按语义手写：
//   ① 认单只：「Nintendo Switch Joy-Con (L)」micro → 8、「(R)」→ 16；配成一对的「(L/R)」、带扩展档的、Siri Remote、没有类别 → 0
//   ② 面键（任天堂手柄、自动布局 = 照字母）：Button A → bit0（东 A）、Button Y → bit3（西 Y）
//   ③ 肩键 / 菜单 / Home：Left Shoulder → bit6、Right Shoulder → bit7、Button Menu → bit10、Home → 扩展位 bit16
//   ④ micro 档只有方向键：它当左摇杆，推满右 (1, 0) → 左摇杆 X 32767，不出方向键位
//   ⑤ 有左摇杆又有方向键：方向键下 → bit15，左摇杆照左摇杆读（推满上 (0, 1) → Y 32767）
//   ⑥ 只有右摇杆：放到左摇杆（推满左 (−1, 0) → 左摇杆 X −32767、右摇杆 0）
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "pad_profile.h"

@interface TButton : NSObject
@property BOOL isPressed;
@end
@implementation TButton
@end
@interface TAxis : NSObject
@property float value;
@end
@implementation TAxis
@end
@interface TDpad : NSObject
@property TAxis *xAxis, *yAxis;
@property TButton *left, *right, *up, *down;
@end
@implementation TDpad
+ (instancetype)x:(float)x y:(float)y {
    TDpad *d = [TDpad new]; d.xAxis = [TAxis new]; d.yAxis = [TAxis new]; d.xAxis.value = x; d.yAxis.value = y;
    d.left = [TButton new]; d.right = [TButton new]; d.up = [TButton new]; d.down = [TButton new];
    d.left.isPressed = x < -.5f; d.right.isPressed = x > .5f; d.up.isPressed = y > .5f; d.down.isPressed = y < -.5f;
    return d;
}
@end
@interface TProfile : NSObject
@property NSDictionary *buttons, *dpads, *axes;
@end
@implementation TProfile
@end
static TProfile *profile(NSArray<NSString *> *pressed, NSDictionary *dpads) {
    NSMutableDictionary *b = [NSMutableDictionary dictionary];
    for (NSString *n in @[GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder, GCInputButtonMenu, GCInputButtonHome]) {
        TButton *t = [TButton new]; t.isPressed = [pressed containsObject:n]; b[n] = t;
    }
    TProfile *p = [TProfile new]; p.buttons = b; p.dpads = dpads; p.axes = @{}; return p;
}
static unsigned checks, failed;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failed += !ok_; printf("%s ", ok_ ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); } while (0)
static NSString *const L = @"Nintendo Switch Joy-Con (L)", *const R = @"Nintendo Switch Joy-Con (R)";

int main(void) {
    @autoreleasepool {
        s2a_pad_layout_set(S2A_PAD_LAYOUT_AUTO);
        int a = s2a_pad_single_joycon(L, NO), b = s2a_pad_single_joycon(R, NO), c = s2a_pad_single_joycon(@"Nintendo Switch Joy-Con (L/R)", NO),
            d = s2a_pad_single_joycon(L, YES), e = s2a_pad_single_joycon(@"Siri Remote", NO), f = s2a_pad_single_joycon(nil, NO);
        CHECK(a == 8 && b == 16 && !c && !d && !e && !f, "① 认单只：左 %d（应 8）、右 %d（应 16）、一对 %d、带扩展档 %d、Siri Remote %d、没有类别 %d（都应 0）", a, b, c, d, e, f);
        uint32_t k; int32_t ax[4];
        s2a_pad_profile_sample((GCPhysicalInputProfile *)profile(@[GCInputButtonA, GCInputButtonY], @{GCInputDirectionPad: [TDpad x:0 y:0]}), L, &k, ax);
        CHECK(k == (1u << 0 | 1u << 3), "② Button A + Button Y：期望 0x9 → 真结果 0x%x", k);
        s2a_pad_profile_sample((GCPhysicalInputProfile *)profile(@[GCInputLeftShoulder, GCInputRightShoulder, GCInputButtonMenu, GCInputButtonHome], @{GCInputDirectionPad: [TDpad x:0 y:0]}), R, &k, ax);
        CHECK(k == (1u << 6 | 1u << 7 | 1u << 10 | 1u << 16), "③ 两肩 + 菜单 + Home：期望 0x104c0 → 真结果 0x%x", k);
        s2a_pad_profile_sample((GCPhysicalInputProfile *)profile(@[], @{GCInputDirectionPad: [TDpad x:1 y:0]}), L, &k, ax);
        CHECK(k == 0 && ax[0] == 32767 && ax[1] == 0 && ax[2] == 0 && ax[3] == 0, "④ 只有方向键、推满右：期望 键 0、左摇杆 (32767, 0)、右摇杆 0 → 真结果 键 0x%x、左 (%d, %d)、右 (%d, %d)", k, ax[0], ax[1], ax[2], ax[3]);
        s2a_pad_profile_sample((GCPhysicalInputProfile *)profile(@[], @{GCInputDirectionPad: [TDpad x:0 y:-1], GCInputLeftThumbstick: [TDpad x:0 y:1]}), L, &k, ax);
        CHECK(k == 1u << 15 && ax[0] == 0 && ax[1] == 32767, "⑤ 方向键下 + 左摇杆推满上：期望 键 0x8000、左摇杆 (0, 32767) → 真结果 键 0x%x、左 (%d, %d)", k, ax[0], ax[1]);
        s2a_pad_profile_sample((GCPhysicalInputProfile *)profile(@[], @{GCInputRightThumbstick: [TDpad x:-1 y:0]}), R, &k, ax);
        CHECK(k == 0 && ax[0] == -32767 && ax[1] == 0 && ax[2] == 0, "⑥ 只有右摇杆、推满左：期望 左摇杆 (−32767, 0)、右摇杆 X 0 → 真结果 左 (%d, %d)、右 X %d", ax[0], ax[1], ax[2]);
    }
    printf("%s t_pad_profile：%u 项，%u 项不符\n", failed ? "✗" : "✓", checks, failed);
    return failed ? 1 : 0;
}
