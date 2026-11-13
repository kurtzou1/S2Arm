// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Hand-calculated mirror coordinates; no game assets or UIKit.
#import "../../ios/play_reflection.h"
#include <math.h>
#include <stdio.h>
static int bad, checks;
#define CK(c, msg) do { checks++; if (!(c)) { bad++; printf("✗ %s\n", msg); } } while (0)
static BOOL point(CGAffineTransform t, CGRect bounds, CGPoint p, CGFloat x, CGFloat y) {
    p.y-=CGRectGetMidY(bounds);
    CGPoint q=CGPointApplyAffineTransform(p,t); q.y+=CGRectGetMidY(bounds);
    return fabs(q.x-x)<.001 && fabs(q.y-y)<.001;
}
int main(void) { @autoreleasepool {
    CGRect b=CGRectMake(0,0,600,800);
    S2APlayLayout l=S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(0,380,600,40));
    CGAffineTransform t=S2APlayReflectionTransform(l,b);
    CK(point(t,b,CGPointMake(70,380),70,420),"上区下沿跨过折痕映射到下区上沿");
    CK(point(t,b,CGPointMake(70,0),70,800),"上区上沿映射到下区底部");
    CK(point(t,b,CGPointMake(10,100),10,700) && point(t,b,CGPointMake(590,100),590,700),"只上下镜像，不左右翻转");
    CK(point(t,b,CGPointMake(300,400),300,400),"折痕中心是镜像轴");
    CK(fabs(t.ty)<.001,"居中折痕的原生变换不额外平移一屏");
    b=CGRectMake(10,30,800,400);
    l=S2APlayLayoutMake(b,CGRectMake(30,40,760,360),S2APlaySplitOn,NO,CGRectNull);
    t=S2APlayReflectionTransform(l,b);
    CK(point(t,b,CGPointMake(50,40),50,420),"横屏非零原点沿实际分屏线镜像");
    CK(point(t,b,CGPointMake(50,200),50,260),"实际画面留边随原位置镜像，不拉伸填满下区");
    b=CGRectMake(0,0,600,800);
    l=S2APlayLayoutMake(b,CGRectMake(0,20,600,760),S2APlaySplitOn,NO,CGRectMake(290,0,20,800));
    t=S2APlayReflectionTransform(l,b);
    CK(point(t,b,CGPointMake(100,100),100,700),"竖向折痕不改变上下镜像轴");
    l=S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(0,330,600,40));
    t=S2APlayReflectionTransform(l,b);
    CK(fabs(t.ty+100)<.001 && point(t,b,CGPointMake(70,330),70,370),"非居中折痕使用保留区中心，不硬编码窗口中线");
    printf("%s t_play_reflection：%d/%d 项符合\n",bad?"✗":"✓",checks-bad,checks);
    return bad?1:0;
} }
