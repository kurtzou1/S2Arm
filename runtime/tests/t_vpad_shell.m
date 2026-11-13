// 游戏库调整虚拟手柄布局的宿主接口（ios/vpad_shell.m，s2a_shell.h「虚拟手柄布局」）。跑：make native-test-vpad_shell
// 期望值手算（区域 832×419，默认布局 A 键中心 x = 0.905·832 + 47 → 比例 0.905 + 47/832）：
//   ① g1 没有自定义：selected default、hasMine false、16 键、A 键 x = 0.905 + 47/832
//   ② 存 {"A":[416,209.5]} → 1；games/g1/VPadLayouts/mine.json 在；再读 selected mine、hasMine true、A 键 x 0.5 y 0.5
//   ③ g2 不受影响：selected default、hasMine false
//   ④ 选 default → 1；selected default、hasMine true（文件保留），底稿仍是 mine（A 键 x 0.5）
//   ⑤ 游戏号 "../x" / ".h"：读返回 NULL、写返回 0
//   ⑥ 游戏内（vpad.m 同目录）打开 g1：选 mine 后读到 A 键 x 0.5
#import <Foundation/Foundation.h>
#include <stdlib.h>
#import "../../ios/vpad_layout.h"
char *s2a_shell_vpad_layout_json(const char *game_id, double safe_w, double safe_h, int split);
int s2a_shell_vpad_save(const char *game_id, const char *centers_json, double safe_w, double safe_h, int split);
int s2a_shell_vpad_select(const char *game_id, const char *layout_id, int split);
int s2a_shell_vpad_set_hold_lock(const char *game_id, int enabled);
static int bad;
#define CK(c, ...) do { if (c) printf("✓ "); else { printf("✗ "); bad++; } printf(__VA_ARGS__); printf("\n"); } while (0)
static NSDictionary *rd_area(const char *g, double w, double h, int split) { char *j = s2a_shell_vpad_layout_json(g, w, h, split); if (!j) return nil;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:j length:strlen(j)] options:0 error:nil]; free(j); return d; }
static NSDictionary *rd(const char *g) { return rd_area(g, 832, 419, 0); }
static NSDictionary *btn(NSDictionary *d, NSString *i) { for (NSDictionary *b in d[@"buttons"]) if ([b[@"id"] isEqualToString:i]) return b; return nil; }
static BOOL near(double a, double b) { return fabs(a - b) < 1e-9; }
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"vpad_shell_" stringByAppendingString:NSUUID.UUID.UUIDString]];
        setenv("S2A_SHELL_DOCS", root.fileSystemRepresentation, 1);
        NSDictionary *d = rd("g1");
        CK(d && [d[@"selected"] isEqualToString:@"default"] && ![d[@"hasMine"] boolValue] && [d[@"buttons"] count] == 16, "① g1 默认：selected %s、hasMine %d、%lu 键", [d[@"selected"] UTF8String], [d[@"hasMine"] intValue], (unsigned long)[d[@"buttons"] count]);
        CK(near([btn(d, @"A")[@"x"] doubleValue], 0.905 + 47.0 / 832), "① A 键 x = 0.905 + 47/832（实得 %.6f）", [btn(d, @"A")[@"x"] doubleValue]);
        CK(s2a_shell_vpad_save("g1", "{\"A\":[416,209.5]}", 832, 419, 0) == 1, "② 存「我的布局」成功");
        CK([NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"games/g1/VPadLayouts/mine.json"]], "② mine.json 在 games/g1/VPadLayouts");
        d = rd("g1");
        CK([d[@"selected"] isEqualToString:@"mine"] && [d[@"hasMine"] boolValue] && near([btn(d, @"A")[@"x"] doubleValue], 0.5) && near([btn(d, @"A")[@"y"] doubleValue], 0.5), "② 再读：selected %s、A 键 (%.3f, %.3f)", [d[@"selected"] UTF8String], [btn(d, @"A")[@"x"] doubleValue], [btn(d, @"A")[@"y"] doubleValue]);
        NSDictionary *d2 = rd("g2");
        CK([d2[@"selected"] isEqualToString:@"default"] && ![d2[@"hasMine"] boolValue], "③ g2 不受影响：selected %s、hasMine %d", [d2[@"selected"] UTF8String], [d2[@"hasMine"] intValue]);
        CK(s2a_shell_vpad_select("g1", "default", 0) == 1, "④ 恢复默认成功");
        d = rd("g1");
        CK([d[@"selected"] isEqualToString:@"default"] && [d[@"hasMine"] boolValue] && near([btn(d, @"A")[@"x"] doubleValue], 0.5), "④ selected default、mine 保留、底稿仍是 mine（A x %.3f）", [btn(d, @"A")[@"x"] doubleValue]);
        CK(rd("../x") == nil && rd(".h") == nil && s2a_shell_vpad_save("../x", "{}", 832, 419, 0) == 0 && s2a_shell_vpad_select("../x", "mine", 0) == 0, "⑤ 不合规游戏号读写都拒绝");
        CK([rd("g1")[@"holdLock"] boolValue] && s2a_shell_vpad_set_hold_lock("g1", 0) == 1 && ![rd("g1")[@"holdLock"] boolValue] && [rd("g2")[@"holdLock"] boolValue] && s2a_shell_vpad_set_hold_lock("../x", 0) == 0, "⑦ 按住锁定缺省开；g1 关了不影响 g2；不合规游戏号拒绝");
        CK(s2a_shell_vpad_select("g1", "mine", 0) == 1, "⑥ 选回 mine");
        S2AVPadLayoutStore *s = [[S2AVPadLayoutStore alloc] initWithDirectory:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"games/g1/VPadLayouts"]]
                                                           settingsDirectory:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"VPadLayouts"]]];
        S2AVPadLayout *l = [s selectedLayout:nil]; double ax = -1; for (NSDictionary *b in l.buttons) if ([b[@"id"] isEqualToString:@"A"]) ax = [b[@"x"] doubleValue];
        CK([l.identifier isEqualToString:S2AVPadLayoutMineIdentifier] && near(ax, 0.5), "⑥ 游戏内同目录读到 mine、A x %.3f", ax);
        CK(s2a_shell_vpad_save("g1", "{\"A\":[208,209.5]}", 832, 419, 1) == 1, "⑧ 分屏编辑接口保存独立的位置");
        CK([NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"games/g1/VPadLayouts/split/mine.json"]] && near([btn(rd("g1"), @"A")[@"x"] doubleValue], .5), "⑧ 分屏文件单独存，普通布局 A x 仍是 .5");
        // 主线 2D 是 14 键、0 摇杆；普通 / 分屏各自选择，宿主每次按当前区域重算，不能缓存成另一种内置布局。
        NSURL *twoDir = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"games/g2d/VPadLayouts"]];
        S2AVPadLayoutStore *two = [[S2AVPadLayoutStore alloc] initWithDirectory:twoDir];
        CK([two selectIdentifier:S2AVPadLayout2DIdentifier error:nil], "⑨ 普通 profile 能选择主线 2D");
        NSDictionary *wide = rd("g2d"), *tall = rd_area("g2d", 419, 832, 0);
        CK([wide[@"buttons"] count] == 14 && !btn(wide, @"LS") && !btn(wide, @"RS") && near([btn(wide, @"UP")[@"x"] doubleValue], .17) && near([btn(wide, @"UP")[@"y"] doubleValue], .66 - 52.0/419), "⑨ 游戏库保留 2D 14 键与手算的横屏十字键位置");
        CK([tall[@"buttons"] count] == 14 && near([btn(tall, @"UP")[@"y"] doubleValue], .66 - 52.0/832) && near([btn(tall, @"UP")[@"width"] doubleValue], 56.0/419), "⑨ 改为竖屏安全区后重新计算 2D，沿用主线 56 点十字键");
        CK([rd_area("g2d", 832, 419, 1)[@"buttons"] count] == 16, "⑨ 普通选 2D 不改变分屏的默认 16 键");
        CK(s2a_shell_vpad_save("g2d", "{\"A\":[416,209.5]}", 832, 419, 0) == 1, "⑩ 游戏库可从 2D 保存普通自定义布局");
        two = [[S2AVPadLayoutStore alloc] initWithDirectory:twoDir];
        S2AVPadLayout *twoMine = [two selectedLayout:nil];
        CK(twoMine.buttons.count == 14 && twoMine.sticks.count == 0 && near([[twoMine.buttons firstObject][@"x"] doubleValue], .5), "⑩ 重开仍是 14 键、0 摇杆的普通自定义位置");
        S2AVPadLayoutStore *twoSplit = [[S2AVPadLayoutStore alloc] initWithDirectory:twoDir settingsDirectory:twoDir split:YES];
        CK([twoSplit selectIdentifier:S2AVPadLayout2DIdentifier error:nil] && [rd_area("g2d", 832, 419, 1)[@"buttons"] count] == 14, "⑪ 分屏选择 2D 后下一次查询立即生效");
        CK(s2a_shell_vpad_select("g2d", "default", 1) == 1 && [rd_area("g2d", 832, 419, 1)[@"buttons"] count] == 16 && btn(rd_area("g2d", 832, 419, 1), @"LS") != nil, "⑪ 分屏切回默认立即恢复 16 键，没有旧 2D 查询缓存");
        twoSplit = [[S2AVPadLayoutStore alloc] initWithDirectory:twoDir settingsDirectory:twoDir split:YES];
        CK([twoSplit selectIdentifier:S2AVPadLayout2DIdentifier error:nil] && s2a_shell_vpad_save("g2d", "{\"A\":[208,209.5]}", 832, 419, 1) == 1, "⑫ 分屏也能在 2D 上编辑并保存");
        twoSplit = [[S2AVPadLayoutStore alloc] initWithDirectory:twoDir settingsDirectory:twoDir split:YES];
        S2AVPadLayout *splitMine = [twoSplit selectedLayout:nil];
        CK(splitMine.buttons.count == 14 && splitMine.sticks.count == 0 && near([[splitMine.buttons firstObject][@"x"] doubleValue], .25), "⑫ 重开分屏 2D 自定义位置，仍无摇杆");
        CK([rd("g2d")[@"selected"] isEqualToString:@"mine"] && near([btn(rd("g2d"), @"A")[@"x"] doubleValue], .5), "⑫ 分屏保存不会覆盖普通 2D 自定义位置");
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (bad) printf("✗ t_vpad_shell：%d 项不通\n", bad); else printf("✓ t_vpad_shell：全部通过\n");
    return bad ? 1 : 0;
}
