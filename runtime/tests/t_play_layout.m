// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 手算的开关 / 区域 / 目标比例；无 UIKit、无商业资源。make native-test-play_layout
#import "../../ios/play_layout.h"
#include <math.h>
#include <stdio.h>
static int bad, checks;
#define CK(c, msg) do { checks++; if (!(c)) { bad++; printf("✗ %s\n", msg); } } while (0)
static BOOL rect(CGRect a, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return fabs(a.origin.x-x)<.001 && fabs(a.origin.y-y)<.001 && fabs(a.size.width-w)<.001 && fabs(a.size.height-h)<.001;
}
int main(void) { @autoreleasepool {
    CGRect b=CGRectMake(0,0,669,951), safe=CGRectMake(0,62,669,855), fold=CGRectMake(0,455.5,669,40);
    for (int half=0;half<2;half++) {
        CK(S2APlaySplitEnabled(S2APlaySplitAuto,half)==half,"自动只在半折开启");
        CK(S2APlaySplitEnabled(S2APlaySplitOn,half),"开启不受姿态限制");
        CK(!S2APlaySplitEnabled(S2APlaySplitOff,half),"关闭不受姿态限制");
    }
    S2APlayLayout l=S2APlayLayoutMake(b,safe,S2APlaySplitAuto,NO,fold);
    CK(!l.split && CGRectEqualToRect(l.game,b),"竖屏和折痕区域本身都不触发自动分屏");
    l=S2APlayLayoutMake(b,safe,S2APlaySplitAuto,YES,fold);
    CK(l.split && rect(l.game,0,62,669,393.5),"半折上区扣除顶部安全区及折痕");
    CK(rect(l.controls,0,495.5,669,421.5),"半折下区扣除折痕及底部安全区");
    l=S2APlayLayoutMake(CGRectMake(0,0,600,800),CGRectMake(0,20,600,760),S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && rect(l.game,0,20,600,380) && rect(l.controls,0,400,600,380),"手动开启没有折痕时在视口中点分屏");
    l=S2APlayLayoutMake(CGRectMake(10,30,800,400),CGRectMake(30,40,760,360),S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && rect(l.game,30,40,760,190) && rect(l.controls,30,230,760,170),"横屏及非零原点也始终上下分屏");
    l=S2APlayLayoutMake(b,safe,S2APlaySplitAuto,YES,CGRectMake(320,0,29,951));
    CK(l.split && rect(l.game,0,62,669,413.5),"竖向折痕仍符合自动半折条件，按中点上下分屏");
    l=S2APlayLayoutMake(b,safe,S2APlaySplitOn,NO,CGRectMake(NAN,0,10,20));
    CK(l.split && isfinite(l.game.size.height),"无效折痕不能污染区域或关闭强制分屏");
    CK(S2APlayPortrait(S2APlayOrientationAuto,YES) && !S2APlayPortrait(S2APlayOrientationAuto,NO),"自动方向随分屏切换");
    CK(!S2APlayPortrait(S2APlayOrientationLandscape,YES) && S2APlayPortrait(S2APlayOrientationPortrait,NO),"手动方向独立于分屏");
    CGSize t=S2APlayTargetSize(CGSizeMake(600,400));
    CK(t.width==1920 && t.height==1280,"上区 3:2 对应 1920×1280，不能交换宽高");
    t=S2APlayTargetSize(CGSizeMake(800,300));
    CK(t.width==2880 && t.height==1080,"上区 8:3 对应 2880×1080");
    t=S2APlayTargetSize(CGSizeZero);
    CK(t.width==1920 && t.height==1080,"空区域使用原始比例");
    NSString *suite=[@"play_layout_" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *d=[[NSUserDefaults alloc] initWithSuiteName:suite];
    CK(S2APlayReadSplit(d)==S2APlaySplitAuto && S2APlayReadOrientation(d)==S2APlayOrientationAuto,"缺省两项均自动");
    [d setObject:@"on" forKey:S2APlaySplitKey]; [d setObject:@"portrait" forKey:S2APlayOrientationKey];
    CK(S2APlayReadSplit(d)==S2APlaySplitOn && S2APlayReadOrientation(d)==S2APlayOrientationPortrait,"读取已保存选择");
    [d setObject:@42 forKey:S2APlaySplitKey]; [d setObject:@[] forKey:S2APlayOrientationKey];
    CK(S2APlayReadSplit(d)==S2APlaySplitAuto && S2APlayReadOrientation(d)==S2APlayOrientationAuto,"错误类型按默认处理");
    [d removePersistentDomainForName:suite];
    CK([S2APlaySplitKey isEqual:@"splitScreen"] && [S2APlayOrientationKey isEqual:@"screenOrientation"],"设置读写使用共享表 id");
    NSDictionary *table=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"launchers/shared/game_settings.v1.json"] options:0 error:nil];
    for (NSString *key in @[@"splitScreen",@"screenOrientation"]) {
        NSDictionary *item=nil; for (NSDictionary *entry in table[@"items"]) if ([entry[@"id"] isEqual:key]) item=entry;
        NSArray *values=[key isEqual:@"splitScreen"] ? @[@"auto",@"on",@"off"] : @[@"auto",@"landscape",@"portrait"];
        CK([item[@"scope"] isEqual:@"app"] && [item[@"type"] isEqual:@"choice"] && [item[@"default"] isEqual:@"auto"] && [item[@"apply"] isEqual:@"live"] && [item[@"platforms"] isEqual:@[@"ios"]] && [[item[@"options"] valueForKey:@"value"] isEqual:values],"共享表登记 App 级三选项，不向未实现的 Mac 展示");
    }
    S2APlayReadSplit(d); S2APlayReadOrientation(d);
    CK([d persistentDomainForName:suite].count==0,"未选择时使用自动，不写入缺省");
    [d setObject:@"on" forKey:@"S2ASplitScreen"]; [d setObject:@"portrait" forKey:@"S2AScreenOrientation"];
    CK(S2APlayReadSplit(d)==S2APlaySplitOn && S2APlayReadOrientation(d)==S2APlayOrientationPortrait,"保留旧键的有效选择");
    CK([[d objectForKey:@"splitScreen"] isEqual:@"on"] && [[d objectForKey:@"screenOrientation"] isEqual:@"portrait"] && ![d objectForKey:@"S2ASplitScreen"] && ![d objectForKey:@"S2AScreenOrientation"],"迁移到规范键并删除旧键");
    d=[[NSUserDefaults alloc] initWithSuiteName:suite];
    CK(S2APlayReadSplit(d)==S2APlaySplitOn && S2APlayReadOrientation(d)==S2APlayOrientationPortrait,"重开偏好后保留迁移结果");
    [d setObject:@"off" forKey:@"splitScreen"]; [d setObject:@"landscape" forKey:@"screenOrientation"];
    [d setObject:@"on" forKey:@"S2ASplitScreen"]; [d setObject:@"portrait" forKey:@"S2AScreenOrientation"];
    CK(S2APlayReadSplit(d)==S2APlaySplitOff && S2APlayReadOrientation(d)==S2APlayOrientationLandscape,"规范键已保存时不被旧键覆盖");
    CK(![d objectForKey:@"S2ASplitScreen"] && ![d objectForKey:@"S2AScreenOrientation"],"新值优先时也清理旧键");
    [d registerDefaults:@{@"splitScreen":@"auto",@"screenOrientation":@"auto"}];
    CK(S2APlayReadSplit(d)==S2APlaySplitOff && S2APlayReadOrientation(d)==S2APlayOrientationLandscape,"持久选择优先于注册缺省");
    [d setObject:@42 forKey:@"splitScreen"]; [d setObject:@[] forKey:@"screenOrientation"];
    [d setObject:@"on" forKey:@"S2ASplitScreen"]; [d setObject:@"portrait" forKey:@"S2AScreenOrientation"];
    CK(S2APlayReadSplit(d)==S2APlaySplitAuto && S2APlayReadOrientation(d)==S2APlayOrientationAuto,"规范键非法时回自动，不重新复活旧选择");
    CK([d persistentDomainForName:suite].count==0,"非法规范值和旧键均清理，不强存自动");
    [d setObject:@"invalid" forKey:@"S2ASplitScreen"]; [d setObject:@YES forKey:@"S2AScreenOrientation"];
    CK(S2APlayReadSplit(d)==S2APlaySplitAuto && S2APlayReadOrientation(d)==S2APlayOrientationAuto && [d persistentDomainForName:suite].count==0,"非法旧值清理后保持自动");
    [d setObject:@"off" forKey:@"splitScreen"];
    CK(S2APlayReadSplit(d)==S2APlaySplitOff && S2APlayReadSplit(d)==S2APlaySplitOff && ![d objectForKey:@"S2ASplitScreen"],"重复读取不再迁移或改写新选择");
    S2APlayPublishSplit(NO);
    [d setObject:@"on" forKey:@"splitScreen"]; S2APlayReadSplit(d);
    CGRect phone=CGRectMake(0,0,420,912), phoneSafe=CGRectMake(0,62,420,816);
    for (S2APlaySplitMode mode=S2APlaySplitAuto;mode<=S2APlaySplitOff;mode+=2) {
        l=S2APlayLayoutMake(phone,phoneSafe,mode,NO,CGRectNull);
        CK(!l.split && CGRectEqualToRect(l.game,phone) && CGRectEqualToRect(l.controls,phoneSafe) && S2APlayPortrait(S2APlayOrientationPortrait,l.split),"普通手机手动竖屏、自动或关闭分屏时仍为整竖屏画面与叠加按键");
    }
    l=S2APlayLayoutMake(phone,phoneSafe,S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && rect(l.game,0,62,420,394) && rect(l.controls,0,456,420,422) && S2APlayPortrait(S2APlayOrientationAuto,l.split),"普通手机强制分屏也可自动竖屏、上画面下按键");
    CK(!s2a_ios_split_active(),"读取偏好和纯几何预览不提前发布运行时分屏");
    [d removePersistentDomainForName:suite];
    printf("%s t_play_layout：%d/%d 项符合（开关、区域、方向、上区宽屏比例）\n",bad?"✗":"✓",checks-bad,checks);
    return bad?1:0;
} }
