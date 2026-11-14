// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Hand-calculated reflection frames; no game assets or UIKit.
#import "../../ios/play_reflection.h"
#include <math.h>
#include <stdio.h>
static int bad, checks;
#define CK(c, msg) do { checks++; if (!(c)) { bad++; printf("✗ %s\n", msg); } } while (0)
static BOOL same(CGRect a, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return fabs(a.origin.x-x)<.001 && fabs(a.origin.y-y)<.001 && fabs(a.size.width-w)<.001 && fabs(a.size.height-h)<.001;
}
int main(void) { @autoreleasepool {
    CGRect b=CGRectMake(0,0,600,800);
    // 居中折痕 380–420：上区 0–380、按键区 420–800；倒影 = 上区大小、从按键区上沿起（上区下沿 380 ↔ 倒影上沿 420）
    S2APlayLayout l=S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(0,380,600,40));
    CK(same(S2APlayReflectionFrame(l),0,420,600,380),"居中折痕：倒影从下区上沿起，与上区同大");
    // 非居中折痕 330–370：上区 0–330，倒影 370 起高 330（镜像轴是保留区中心 350，不是窗口中线）
    l=S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(0,330,600,40));
    CK(same(S2APlayReflectionFrame(l),0,370,600,330),"非居中折痕：按保留区中心镜像，不硬编码窗口中线");
    CK(CGRectIsNull(S2APlayReflectionFrame(S2APlayLayoutMake(b,b,S2APlaySplitOff,NO,CGRectNull))),"不分屏：没有倒影");
    CK(S2APlayReflectionWanted(S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(0,380,600,40))),"有横向折痕的分屏：出倒影");
    CK(S2APlayReflectionWanted(S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(290,0,20,800))),"有竖向折痕的分屏：出倒影");
    CK(!S2APlayReflectionWanted(S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectNull)),"没有折痕（普通 iPhone 强制分屏，#979）：不出倒影");
    CK(!S2APlayReflectionWanted(S2APlayLayoutMake(b,b,S2APlaySplitOff,NO,CGRectMake(0,380,600,40))),"不分屏：不出倒影");
    printf("%s t_play_reflection：%d/%d 项符合\n",bad?"✗":"✓",checks-bad,checks);
    return bad?1:0;
} }
