// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 分屏下全部按键须可点；独立位置文件不能改变普通布局、手感或键/触模式。
#import "../../ios/vpad_layout.h"
#include <stdio.h>
static int bad, checks;
#define CK(c,msg) do { checks++; if (!(c)) { bad++; printf("✗ %s\n",msg); } } while (0)
static CGRect key_frame(S2AVPadLayout *layout, NSString *key, CGRect safe) {
    for (NSDictionary *button in layout.buttons) if ([button[@"id"] isEqual:key]) return [layout frameForButton:button safeRect:safe];
    return CGRectNull;
}
int main(void) { @autoreleasepool {
    CGRect areas[]={CGRectMake(16,495.5,637,421.5),CGRectMake(16,220,924,198),CGRectMake(16,400,358,350),CGRectMake(16,300,650,450),CGRectMake(0,700,1032,640)};
    for (unsigned i=0;i<sizeof areas/sizeof *areas;i++) {
        S2AVPadLayout *l=[S2AVPadLayout defaultForSafeRect:areas[i] split:YES];
        CK(l.buttons.count==16 && [S2AVPadLayout readData:[l JSONData:nil] error:nil],"分屏默认仍是可导出/导入的完整 F01 布局");
        for (NSDictionary *button in l.buttons) {
            CGRect f=[l frameForButton:button safeRect:areas[i]]; CGPoint c=CGPointMake(CGRectGetMidX(f),CGRectGetMidY(f));
            NSString *hit=[l buttonAt:c safeRect:areas[i] slop:10 avoiding:CGRectNull nearest:YES];
            CK(CGRectContainsRect(areas[i],f) && [hit isEqualToString:button[@"id"]],"每个默认键都在下区内且中心可点，不被其他键热区抢走");
        }
        NSArray *top=@[@"ZL",@"L",@"MINUS",@"PLUS",@"R",@"ZR"];
        for (NSUInteger j=0;j+1<top.count;j++) {
            CGRect a=key_frame(l,top[j],areas[i]), b=key_frame(l,top[j+1],areas[i]);
            CK(CGRectGetMinX(b)>CGRectGetMaxX(a),"窄竖屏与矮横屏的默认顶排相邻键框留有间距");
        }
        CK([l buttonAt:CGPointMake(areas[i].origin.x+10,areas[i].origin.y-1) safeRect:areas[i] slop:10 avoiding:CGRectNull nearest:YES]==nil,"上区触摸不能触发下区按键");
    }
    // 388 点可用宽：58 点肩键按 .97 缩放为 56.26，左右各对间距须为 8×.97=7.76 点。
    CGRect phone=CGRectMake(16,460,388,402);
    S2AVPadLayout *phoneLayout=[S2AVPadLayout defaultForSafeRect:phone split:YES];
    CK(fabs(CGRectGetMinX(key_frame(phoneLayout,@"L",phone))-CGRectGetMaxX(key_frame(phoneLayout,@"ZL",phone))-7.76)<1e-9,"388 点手机左肩键间距与手算 7.76 点一致");
    CK(fabs(CGRectGetMinX(key_frame(phoneLayout,@"ZR",phone))-CGRectGetMaxX(key_frame(phoneLayout,@"R",phone))-7.76)<1e-9,"388 点手机右肩键间距与手算 7.76 点一致");
    CGRect safe=CGRectMake(0,400,600,350), gap=CGRectMake(290,0,20,800);
    S2AVPadLayout *l=[S2AVPadLayout defaultForSafeRect:safe split:YES];
    l=[l layoutWithButtonCenters:@{@"A":@[@300,@600]} safeRect:safe identifier:@"mine" name:@"分屏位置" error:nil];
    NSDictionary *a=l.buttons[0]; CGRect f=[l frameForButton:a safeRect:safe avoiding:gap];
    CK(CGRectIsEmpty(CGRectIntersection(f,gap)),"自定义键移出竖向折痕");
    CK([[l buttonAt:CGPointMake(CGRectGetMidX(f),CGRectGetMidY(f)) safeRect:safe slop:10 avoiding:gap nearest:YES] isEqual:@"A"],"避让后的显示和热区一致");
    CK([l buttonAt:CGPointMake(300,600) safeRect:safe slop:10 avoiding:gap nearest:YES]==nil,"折痕保留区域不响应按键");
    // 主线每键 / 整体缩放、隐藏，与分屏折痕必须在同一份显示和命中几何上组合。
    CGRect scaled=[l frameForButton:a safeRect:safe avoiding:gap scale:1.6];
    CGPoint center=CGPointMake(CGRectGetMidX(scaled),CGRectGetMidY(scaled));
    CK(CGRectIsEmpty(CGRectIntersection(scaled,gap)) && fabs(scaled.size.width-f.size.width*1.6)<1e-9,"放大后的键仍避开折痕");
    CK([[l buttonAt:center safeRect:safe slop:0 avoiding:gap nearest:YES scales:@{@"A":@1.6}] isEqual:@"A"],"缩放、折痕避让后的显示中心仍命中同一键");
    CK(([[l buttonAt:CGPointMake(CGRectGetMaxX(scaled)-1,center.y) safeRect:safe slop:0 avoiding:gap nearest:YES scales:@{@"*":@0,@"A":@1.6}] isEqual:@"A"]),"放大后超出原框的可见部分也能命中");
    CK(![[l buttonAt:center safeRect:safe slop:0 avoiding:gap nearest:YES scales:@{@"A":@0}] isEqual:@"A"],"分屏隐藏键不能被最邻近命中重新启用");
    CK([l buttonAt:CGPointMake(300,600) safeRect:safe slop:10 avoiding:gap nearest:YES scales:@{@"*":@1.6}]==nil,"整体放大后折痕仍不响应");
    // 手算几何：200×200 区域内，40 点键跨过 x=100..120 的竖折痕后须整键移到一侧。
    CGRect compact=CGRectMake(10,400,200,200), crease=CGRectMake(100,0,20,1000);
    NSDictionary *probe=@{@"x":@.5,@"y":@.5,@"width":@.2,@"height":@.2};
    CK(CGRectEqualToRect([l frameForButton:probe safeRect:compact avoiding:crease],CGRectMake(120,480,40,40)),"折痕右侧避让与手算坐标一致");
    CK(CGRectEqualToRect([l frameForButton:probe safeRect:compact avoiding:crease scale:1.5],CGRectMake(120,470,60,60)),"缩放后先算完整键框再避让");
    probe=@{@"x":@.4,@"y":@.5,@"width":@.2,@"height":@.2};
    CK(CGRectEqualToRect([l frameForButton:probe safeRect:compact avoiding:crease],CGRectMake(60,480,40,40)),"折痕左侧避让与手算坐标一致");
    S2AVPadLayout *close=[S2AVPadLayout defaultForSafeRect:compact split:YES];
    close=[close layoutWithButtonCenters:@{@"A":@[@100,@500],@"B":@[@125,@500]} safeRect:compact identifier:@"mine" name:@"重叠热区" error:nil];
    NSDictionary *onlyAB=@{@"*":@0,@"A":@1,@"B":@1};
    CK(([[close buttonAt:CGPointMake(116,500) safeRect:compact slop:10 avoiding:CGRectNull nearest:NO scales:onlyAB] isEqual:@"A"]),"普通布局保留热区重叠时的按键顺序");
    CK(([[close buttonAt:CGPointMake(116,500) safeRect:compact slop:10 avoiding:CGRectNull nearest:YES scales:onlyAB] isEqual:@"B"]),"分屏重叠热区取较近的 B 键");
    CK(([[close buttonAt:CGPointMake(146,500) safeRect:compact slop:0 avoiding:CGRectNull nearest:YES scales:onlyAB] isEqual:@"B"]),"较小按键仍有至少 44 点命中区域");
    CK([close buttonAt:CGPointMake(148,500) safeRect:compact slop:0 avoiding:CGRectNull nearest:YES scales:onlyAB]==nil,"最邻近选择不扩展到全部空白区域");
    NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"vpad_split_" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSURL *game=[root URLByAppendingPathComponent:@"game"], *app=[root URLByAppendingPathComponent:@"app"];
    S2AVPadLayoutStore *normal=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app];
    S2AVPadLayoutStore *split=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app split:YES];
    S2AVPadLayout *n=[l layoutWithButtonCenters:@{@"A":@[@120,@600]} safeRect:safe identifier:@"mine" name:@"普通位置" error:nil];
    CK([normal replaceLayout:n error:nil] && [normal selectIdentifier:@"mine" error:nil] && [split replaceLayout:l error:nil] && [split selectIdentifier:@"mine" error:nil],"普通和分屏能各自保存/选择 mine");
    CK([NSFileManager.defaultManager fileExistsAtPath:[game URLByAppendingPathComponent:@"mine.json"].path] && [NSFileManager.defaultManager fileExistsAtPath:[game URLByAppendingPathComponent:@"split/mine.json"].path],"普通/分屏位置文件隔离");
    CK(([normal setKeyStyle:(S2AVPadKeyStyle){1.5,.5,YES} forKey:@"A" persist:YES error:nil] && [split setKeyStyle:(S2AVPadKeyStyle){.8,.9,NO} forKey:@"A" persist:YES error:nil]),"两种布局均能保存主线新增的按键外观");
    CK([normal setStickFixed:YES sensitivity:1.5 error:nil] && [split setStickFixed:YES sensitivity:.8 error:nil] && [split setStickCenter:CGPointMake(.25,.7) side:0 error:nil],"分屏可保存固定摇杆和独立位置");
    normal=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app];
    CK(fabs([[[normal selectedLayout:nil].buttons firstObject][@"x"] doubleValue]-.2)<1e-9,"分屏保存没有覆盖普通位置");
    split=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app split:YES];
    CK([normal keyStyle:@"A"].hidden && ![split keyStyle:@"A"].hidden && fabs([split keyStyle:@"A"].scale-.8)<1e-9,"重开后两种布局的大小 / 隐藏设置各自保留");
    CK(normal.stickFixed && split.stickFixed && fabs(normal.stickSensitivity-1.5)<1e-9 && fabs(split.stickSensitivity-.8)<1e-9 && fabs([split stickCenter:0].x-.25)<1e-9,"重开后固定模式、灵敏度和分屏摇杆位置仍在");
    CK([split setHoldLockEnabled:NO error:nil] && [split markManual:nil],"分屏能设置共用的锁定和手动选择标记");
    normal=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app];
    CK(!normal.holdLockEnabled && normal.manualChosen,"普通模式读取相同的锁定与手动选择标记");
    CK([split setTouchOnly:YES error:nil]==1,"在分屏切到纯触屏");
    normal=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app];
    split=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app split:YES];
    CK([normal.selectedIdentifier isEqual:@"touch"] && [split.selectedIdentifier isEqual:@"touch"],"跨模式不会自动把纯触屏改回按键");
    CK([split setTouchOnly:NO error:nil]==1 && [split.selectedIdentifier isEqual:@"mine"],"分屏切回按键后恢复分屏的 mine");
    normal=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app];
    CK([normal.selectedIdentifier isEqual:@"mine"],"普通布局也保留自己的 mine");
    S2AVPadLayoutStore *stale=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app split:YES];
    [normal setTouchOnly:YES error:nil]; [stale selectIdentifier:@"default" error:nil];
    normal=[[S2AVPadLayoutStore alloc] initWithDirectory:game settingsDirectory:app];
    CK(![normal.selectedIdentifier isEqual:@"touch"],"已打开的分屏管理页也能退出另一份 store 刚设的触屏模式");
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    printf("%s t_vpad_split：%d/%d 项符合（5 种区域 × 16 键、顶排间距、折痕、存储与模式）\n",bad?"✗":"✓",checks-bad,checks);
    return bad?1:0;
} }
