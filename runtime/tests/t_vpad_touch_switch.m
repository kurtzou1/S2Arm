// 切「仅触屏 / 按键」的三种来源（ios/vpad_layout.m -[S2AVPadLayoutStore switchTouchOnly:source:session:error:]，vpad.m 切方案入口调它）。
//   提示条「切到触屏」曾按手动保存切：一款需要按键开场的游戏点了之后下次开局仍没有按键、回去的路藏在子菜单 → 提示条改成只这一局。临时目录，期望手写：
//   ① Session（提示条）切触：返回 1、本局覆盖 1；磁盘选择不变（.selection.json 没写、重开仍是 default）、manualChosen 仍 NO
//   ② 玩家已手动保存选了按键（manualChosen）时 Session 照切：返回 1、覆盖 1；重开仍是 default
//   ③ Saved（齿轮「显示按键」）切回按键：返回 1、覆盖清 0、选中 default、manualChosen YES，重开同一目录仍 default + 手动
//   ④ Auto（游戏声明触屏配置）遇 manualChosen：返回 0、覆盖仍 0、选中不变；没手动选过时 Auto 切：返回 1、覆盖 1、不写盘不记手动
//   ⑤ Saved「隐藏按键」：返回 1、选中 touch（持久化）、覆盖 0；本局已是覆盖触屏时 Saved 切触：返回 0（本局本来就是仅触屏）、清覆盖、写盘 touch
//   旧实现没有 switchTouchOnly:source:session:error:：编不过（红）
#import <Foundation/Foundation.h>
#import "../../ios/vpad_layout.h"
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
static NSURL *tmpdir(void) { return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES]; }
static BOOL has(NSURL *d, NSString *name) { return [NSFileManager.defaultManager fileExistsAtPath:[d URLByAppendingPathComponent:name].path]; }
static NSString *reopened(NSURL *d) { return [[S2AVPadLayoutStore alloc] initWithDirectory:d].selectedIdentifier; }
int main(void) { @autoreleasepool {
    NSError *e; NSString *def = S2AVPadLayoutDefaultIdentifier, *touch = S2AVPadLayoutTouchIdentifier;
    // ①
    NSURL *d1 = tmpdir(); S2AVPadLayoutStore *s = [[S2AVPadLayoutStore alloc] initWithDirectory:d1]; int ov = 0;
    int r = [s switchTouchOnly:YES source:S2AVPadTouchSession session:&ov error:&e];
    CK(r == 1 && ov == 1 && [s.selectedIdentifier isEqualToString:def] && !has(d1, @".selection.json") && [reopened(d1) isEqualToString:def] && !s.manualChosen && !has(d1, @".manual"),
       "① 提示条切触：1、覆盖 1、选中 default、没写 .selection.json、重开 default、没记手动（实得 %d 覆盖 %d %s 选择文件 %d 重开 %s 手动 %d）",
       r, ov, s.selectedIdentifier.UTF8String, has(d1, @".selection.json"), reopened(d1).UTF8String, s.manualChosen);
    // ②
    NSURL *d2 = tmpdir(); s = [[S2AVPadLayoutStore alloc] initWithDirectory:d2]; ov = 0;
    int a = [s switchTouchOnly:NO source:S2AVPadTouchSaved session:&ov error:&e];   // 玩家在设置里选过按键：本来就是按键，记手动
    r = [s switchTouchOnly:YES source:S2AVPadTouchSession session:&ov error:&e];
    CK(a == 0 && s.manualChosen && r == 1 && ov == 1 && [s.selectedIdentifier isEqualToString:def] && [reopened(d2) isEqualToString:def],
       "② 手动选过按键后提示条照切：先 0 + 手动，再 1、覆盖 1、选中仍 default、重开 default（实得 %d %d %d 覆盖 %d %s 重开 %s）",
       a, s.manualChosen, r, ov, s.selectedIdentifier.UTF8String, reopened(d2).UTF8String);
    // ③ 接 ②：本局覆盖着触屏，齿轮「显示按键」
    r = [s switchTouchOnly:NO source:S2AVPadTouchSaved session:&ov error:&e];
    S2AVPadLayoutStore *s2 = [[S2AVPadLayoutStore alloc] initWithDirectory:d2];
    CK(r == 1 && ov == 0 && [s.selectedIdentifier isEqualToString:def] && s.manualChosen && [s2.selectedIdentifier isEqualToString:def] && s2.manualChosen,
       "③ 齿轮显示按键：1、覆盖清 0、选中 default、手动，重开仍 default + 手动（实得 %d 覆盖 %d %s %d 重开 %s %d）",
       r, ov, s.selectedIdentifier.UTF8String, s.manualChosen, s2.selectedIdentifier.UTF8String, s2.manualChosen);
    // ④
    r = [s switchTouchOnly:YES source:S2AVPadTouchAuto session:&ov error:&e];
    NSURL *d4 = tmpdir(); S2AVPadLayoutStore *f = [[S2AVPadLayoutStore alloc] initWithDirectory:d4]; int ov4 = 0;
    int b = [f switchTouchOnly:YES source:S2AVPadTouchAuto session:&ov4 error:&e];
    CK(r == 0 && ov == 0 && [s.selectedIdentifier isEqualToString:def] && b == 1 && ov4 == 1 && !has(d4, @".selection.json") && !f.manualChosen,
       "④ 自动切：手动选过 → 0、覆盖 0、选中 default；没手动过 → 1、覆盖 1、不写盘不记手动（实得 %d %d %s；%d %d 选择文件 %d 手动 %d）",
       r, ov, s.selectedIdentifier.UTF8String, b, ov4, has(d4, @".selection.json"), f.manualChosen);
    // ⑤
    r = [s switchTouchOnly:YES source:S2AVPadTouchSaved session:&ov error:&e];
    int c = [f switchTouchOnly:YES source:S2AVPadTouchSaved session:&ov4 error:&e];
    CK(r == 1 && ov == 0 && [reopened(d2) isEqualToString:touch] && c == 0 && ov4 == 0 && [reopened(d4) isEqualToString:touch] && f.manualChosen,
       "⑤ 齿轮隐藏按键：1、覆盖 0、重开 touch；本局已覆盖触屏 → 0、覆盖清 0、重开 touch、手动（实得 %d %d %s；%d %d %s %d）",
       r, ov, reopened(d2).UTF8String, c, ov4, reopened(d4).UTF8String, f.manualChosen);
    for (NSURL *d in @[d1, d2, d4]) [NSFileManager.defaultManager removeItemAtURL:d error:nil];
    if (bad) printf("t_vpad_touch_switch：%d 项不过\n", bad); else printf("✓ t_vpad_touch_switch：5 项（提示条只这一局 / 手动选过照切 / 齿轮显示按键保存 / 自动切尊重手动 / 齿轮隐藏按键保存）\n");
    return bad ? 1 : 0;
} }
