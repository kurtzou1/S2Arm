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
    // #2179「自动」不半折时：竖着且 16:9 画面按安全区宽放得进上半区（上半区高 ≥ 安全区宽 × 9/16）就分屏。期望手算：
    //   669×951、安全区顶 62：上半区 475.5 − 62 = 413.5 ≥ 669 × 0.5625 = 376.3 → 分；带着横向折痕区（455.5 起 40 高）就按折痕分：上 0,62 669×393.5、下 0,495.5 669×421.5
    S2APlayLayout l=S2APlayLayoutMake(b,safe,S2APlaySplitAuto,NO,fold);
    CK(l.split && rect(l.game,0,62,669,393.5) && rect(l.controls,0,495.5,669,421.5),"竖着、上半区放得下 16:9：自动也分屏（不再只看半折），有折痕按折痕分");
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
    // iPhone Duo 外屏竖屏手动分屏（11-15 真机读数：视图 466×678 点，安全区 上 0 左 0 下 34 右 84）：上区横向按整屏 466 宽、竖向 0–339，画面贴顶；
    //   修前是安全区 ∩ 上半屏 = 382×339。下区照旧扣安全区 = 0,339 382×305
    l=S2APlayLayoutMake(CGRectMake(0,0,466,678),CGRectMake(0,0,382,644),S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && l.top && rect(l.game,0,0,466,339),"Duo 外屏竖屏分屏：上区整屏宽 466×339、贴顶");
    CK(rect(l.controls,0,339,382,305),"Duo 外屏竖屏分屏：下区仍扣安全区");
    // 普通 iPhone 竖屏手动分屏（左右缩进 0、顶部灵动岛 62）：区域与修前相同、不贴顶
    l=S2APlayLayoutMake(CGRectMake(0,0,402,874),CGRectMake(0,62,402,778),S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && !l.top && rect(l.game,0,62,402,375),"普通 iPhone 竖屏分屏：区域不变、不贴顶");
    // 半折内屏（有折痕）：即使安全区左右有缩进也走折痕分支，不放宽、不贴顶
    l=S2APlayLayoutMake(b,CGRectMake(20,62,629,855),S2APlaySplitAuto,YES,fold);
    CK(l.split && !l.top && rect(l.game,20,62,629,393.5),"半折内屏：走折痕分支，区域按安全区、不贴顶");
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
    l=S2APlayLayoutMake(phone,phoneSafe,S2APlaySplitOff,NO,CGRectNull);
    CK(!l.split && CGRectEqualToRect(l.game,phone) && CGRectEqualToRect(l.controls,phoneSafe) && S2APlayPortrait(S2APlayOrientationPortrait,l.split),"普通手机竖屏、分屏关：仍为整竖屏画面与叠加按键");
    // 五种「自动」情况（期望手算，上半区高 = 视图中线 − 安全区顶，要 ≥ 安全区宽 × 9/16）：
    //   ① 普通 iPhone 竖屏（#2179 iPhone 18 Pro Max 真机读数 440×956、安全区 上 62 下 34）：478 − 62 = 416 ≥ 247.5 → 分，上 0,62 440×416、下 0,478 440×444
    l=S2APlayLayoutMake(CGRectMake(0,0,440,956),CGRectMake(0,62,440,860),S2APlaySplitAuto,NO,CGRectNull);
    CK(l.split && rect(l.game,0,62,440,416) && rect(l.controls,0,478,440,444),"① 普通 iPhone 竖屏，自动：上画面下按键");
    //   ② 普通 iPhone 横屏（同机 956×440、安全区 左右 62 下 20）：不竖 → 不分，整屏画面
    l=S2APlayLayoutMake(CGRectMake(0,0,956,440),CGRectMake(62,0,832,420),S2APlaySplitAuto,NO,CGRectNull);
    CK(!l.split && rect(l.game,0,0,956,440),"② 普通 iPhone 横屏，自动：不分屏");
    //   ③ 折叠屏半开：照旧分（上面「半折上区」那组）；④ 折叠屏全开内屏近方（如 900×960、安全区顶 24）：480 − 24 = 456 < 900 × 0.5625 = 506.25 → 不分
    l=S2APlayLayoutMake(CGRectMake(0,0,900,960),CGRectMake(0,24,900,916),S2APlaySplitAuto,NO,CGRectNull);
    CK(!l.split,"④ 近方的大屏全开，自动：上半区放不下 16:9，不分");
    //   ⑤ iPad 竖屏（768×1024、安全区顶 24 下 20）：512 − 24 = 488 ≥ 432 → 分，上 0,24 768×488、下 0,512 768×492
    l=S2APlayLayoutMake(CGRectMake(0,0,768,1024),CGRectMake(0,24,768,980),S2APlaySplitAuto,NO,CGRectNull);
    CK(l.split && rect(l.game,0,24,768,488) && rect(l.controls,0,512,768,492),"⑤ iPad 竖屏，自动：同一规则，上画面下按键");
    //   iPad 横屏（1024×768）：不竖 → 不分
    l=S2APlayLayoutMake(CGRectMake(0,0,1024,768),CGRectMake(0,24,1024,724),S2APlaySplitAuto,NO,CGRectNull);
    CK(!l.split,"iPad 横屏，自动：不分屏");
    l=S2APlayLayoutMake(phone,phoneSafe,S2APlaySplitOn,NO,CGRectNull);
    CK(l.split && rect(l.game,0,62,420,394) && rect(l.controls,0,456,420,422) && S2APlayPortrait(S2APlayOrientationAuto,l.split),"普通手机强制分屏也可自动竖屏、上画面下按键");
    CK(!s2a_ios_split_active(),"读取偏好和纯几何预览不提前发布运行时分屏");
    // 倒着拿（期望按定义手算；内屏数据取自 iPhone Duo 模拟器 iOS 27.1：设备 2 → 界面 3、设备 1 → 界面 4、设备 3 → 界面 1，设备 4 时界面不转）
    CK(S2APlayLearnK(2,3)==270 && S2APlayLearnK(1,4)==270 && S2APlayLearnK(3,1)==-1 && S2APlayLearnK(5,3)==-1,"学差值：内屏横屏两次都学到 270°；竖屏、平放不学");
    CK(S2APlayLearnK(3,3)==0 && S2APlayLearnK(4,4)==0,"学差值：普通手机 / 外屏横屏是 0°");
    CK(S2APlayHoldAction(4,1,270)==1 && S2APlayHoldAction(3,1,270)==0 && S2APlayHoldAction(4,3,270)==2,"内屏：设备 4 该倒置竖屏、停在正竖屏转 180°、停在横屏先申请竖屏；设备 3 正常");
    CK(S2APlayHoldAction(2,1,0)==1 && S2APlayHoldAction(1,1,0)==0 && S2APlayHoldAction(2,2,0)==0 && S2APlayHoldAction(3,3,0)==0,"外屏：倒着拿停在正竖屏转 180°；系统真转了倒置、正着、横屏都不动");
    CK(S2APlayHoldAction(5,1,0)==-1 && S2APlayHoldAction(2,1,-1)==-1,"平放 / 差值没学到：保持原样");
    [d removePersistentDomainForName:suite];
    printf("%s t_play_layout：%d/%d 项符合（开关、区域、方向、上区宽屏比例、倒着拿）\n",bad?"✗":"✓",checks-bad,checks);
    return bad?1:0;
} }
