// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "play_reflection.h"

CGAffineTransform S2APlayReflectionTransform(S2APlayLayout l, CGRect bounds) {
    // CAReplicatorLayer applies instanceTransform about its center, not the root origin.
    return CGAffineTransformMake(1,0,0,-1,0,CGRectGetMaxY(l.game)+CGRectGetMinY(l.controls)-2*CGRectGetMidY(bounds));
}

#if TARGET_OS_IPHONE
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// Only the game layer is replicated. Controls / loading / diagnostic views remain siblings above it.
@interface S2APlayBackground : UIView
@property(nonatomic,strong) CALayer *game;
- (void)update:(S2APlayLayout)layout;
@end
@implementation S2APlayBackground {
    CAReplicatorLayer *_copies;
    UIVisualEffectView *_blur;
    CAGradientLayer *_shade, *_fold;
    S2APlayLayout _layout;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    self.userInteractionEnabled=NO; self.clipsToBounds=YES;
    self.accessibilityElementsHidden=YES;
    _copies=[CAReplicatorLayer layer]; [self.layer addSublayer:_copies];
    // Keep the effect and its ancestors at alpha 1; fade with a separate black overlay.
    _blur=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _blur.userInteractionEnabled=NO; [self addSubview:_blur];
    _shade=[CAGradientLayer layer];
    _shade.colors=@[(id)[UIColor colorWithWhite:0 alpha:.35].CGColor,(id)UIColor.blackColor.CGColor];
    [self.layer addSublayer:_shade];
    _fold=[CAGradientLayer layer];
    _fold.colors=@[(id)UIColor.blackColor.CGColor,(id)[UIColor colorWithWhite:0 alpha:.48].CGColor,(id)[UIColor colorWithWhite:0 alpha:.35].CGColor];
    _fold.locations=@[@0,@.5,@1]; [self.layer addSublayer:_fold];
    NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(applicationChanged:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(applicationChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)setGame:(CALayer *)game {
    if (_game==game && game.superlayer==_copies) return;   // 同一个层但被挪走过（外接屏来回）：照样放回复制层
    [_game removeFromSuperlayer]; _game=game; [_copies addSublayer:game];
}
- (void)applicationChanged:(NSNotification *)note { [self update:_layout]; }
- (void)update:(S2APlayLayout)layout {
    _layout=layout;
    BOOL active=layout.split && self.game && !CGRectIsEmpty(layout.game) && !CGRectIsEmpty(layout.controls) && UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _copies.frame=self.bounds; _copies.bounds=self.bounds;
    _copies.instanceCount=active?2:1;
    _copies.instanceTransform=active?CATransform3DMakeAffineTransform(S2APlayReflectionTransform(layout,self.bounds)):CATransform3DIdentity;
    CGRect lower=active?CGRectMake(CGRectGetMinX(self.bounds),CGRectGetMaxY(layout.game),self.bounds.size.width,MAX(0,CGRectGetMaxY(self.bounds)-CGRectGetMaxY(layout.game))):CGRectZero;
    _blur.frame=lower; _shade.frame=lower;
    _blur.hidden=_shade.hidden=!active;
    CGRect fold=CGRectIntersection(layout.division,self.bounds);
    _fold.hidden=!active || CGRectIsNull(fold) || CGRectIsEmpty(fold);
    if (!_fold.hidden) {
        _fold.frame=fold;
        BOOL horizontal=fold.size.width>fold.size.height;
        _fold.startPoint=CGPointMake(horizontal?.5:0,horizontal?0:.5);
        _fold.endPoint=CGPointMake(horizontal?.5:1,horizontal?1:.5);
    }
    [CATransaction commit];
}
@end

static char backgroundKey;
void S2APlayReflectionLayout(UIView *root, S2APlayLayout layout) {
    S2APlayBackground *background=objc_getAssociatedObject(root,&backgroundKey);
    if (!background) return;
    background.frame=root.bounds; background.bounds=root.bounds;
    [background update:layout];
}
void s2a_ios_attach_game_layer(UIView *root, CALayer *game) {
    NSCAssert(NSThread.isMainThread,@"Game layer attachment requires the main thread");
    S2APlayBackground *background=objc_getAssociatedObject(root,&backgroundKey);
    if (!background) {
        background=[S2APlayBackground new];
        objc_setAssociatedObject(root,&backgroundKey,background,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [root insertSubview:background atIndex:0];
    }
    background.game=game;
    S2APlayReflectionLayout(root,s2a_ios_play_layout());
}
#endif
