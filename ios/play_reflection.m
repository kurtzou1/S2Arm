// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "play_reflection.h"

CGRect S2APlayReflectionFrame(S2APlayLayout l) {
    if (!l.split || CGRectIsEmpty(l.game) || CGRectIsEmpty(l.controls)) return CGRectNull;
    return CGRectMake(CGRectGetMinX(l.game),CGRectGetMinY(l.controls),l.game.size.width,l.game.size.height);
}

// 倒影只给有真折痕的设备（Duo 半折，layout.division 来自铰链保留区）。#979：普通 iPhone 强制上下分屏时复制层出两份，
//   真机屏上上半的游戏画面没了、只剩下半的模糊倒影（截屏 / 划后台时合成又是对的）。倒影本来就是给折痕做过渡的，没折痕不复制
BOOL S2APlayReflectionWanted(S2APlayLayout l) { return l.split && !CGRectIsNull(l.division) && !CGRectIsEmpty(l.division); }

#if TARGET_OS_IPHONE
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

// The game layer sits alone in a plain container. The reflection is a second, small CAMetalLayer that the renderer
// draws the same picture into on every present (s2a_ios_reflection_drawable). Not a CAReplicatorLayer: replicating a
// CAMetalLayer shows only one of the copies (Duo split view: upper half black in the foreground, normal in the
// app-switcher snapshot where the copy count drops back to 1).
static pthread_mutex_t g_mu=PTHREAD_MUTEX_INITIALIZER;
static CAMetalLayer *g_live_game, *g_live_mirror;   // Under g_mu: set while the reflection is showing
static int g_inflight; static uint64_t g_taken_ns;   // Under g_mu: reflection drawables taken and not yet on screen

@interface S2APlayBackground : UIView
@property(nonatomic,strong) CALayer *game;
- (void)update:(S2APlayLayout)layout;
@end
@implementation S2APlayBackground {
    CALayer *_host;
    CAMetalLayer *_mirror;
    UIVisualEffectView *_blur;
    CAGradientLayer *_shade, *_fold;
    S2APlayLayout _layout;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    self.userInteractionEnabled=NO; self.clipsToBounds=YES;
    self.accessibilityElementsHidden=YES;
    _host=[CALayer layer]; [self.layer addSublayer:_host];
    _mirror=[CAMetalLayer layer]; _mirror.opaque=YES; _mirror.hidden=YES; _mirror.maximumDrawableCount=3;
    _mirror.transform=CATransform3DMakeScale(1,-1,1);   // Drawn upright by the renderer, shown upside down
    [self.layer addSublayer:_mirror];
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
    if (_game==game && game.superlayer==_host) return;   // 同一个层但被挪走过（外接屏来回）：照样放回容器
    [_game removeFromSuperlayer]; _game=game; [_host addSublayer:game];
}
- (void)applicationChanged:(NSNotification *)note { [self update:_layout]; }
- (void)update:(S2APlayLayout)layout {
    _layout=layout;
    CGRect mirror=S2APlayReflectionFrame(layout);
    BOOL active=S2APlayReflectionWanted(layout) && !CGRectIsNull(mirror) && [self.game isKindOfClass:CAMetalLayer.class] && self.game.superlayer==_host && self.window && UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground;
    CGFloat scale=self.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _host.frame=self.bounds;
    if (active) {
        _mirror.bounds=CGRectMake(0,0,mirror.size.width,mirror.size.height);
        _mirror.position=CGPointMake(CGRectGetMidX(mirror),CGRectGetMidY(mirror));
        _mirror.drawableSize=CGSizeMake(MAX(1,round(mirror.size.width*scale/2)),MAX(1,round(mirror.size.height*scale/2)));   // A quarter of the pixels: it is blurred over
    }
    _mirror.hidden=!active;
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
    pthread_mutex_lock(&g_mu);
    if (active) { g_live_game=(CAMetalLayer *)self.game; g_live_mirror=_mirror; }
    else if (g_live_mirror==_mirror) g_live_game=g_live_mirror=nil;
    pthread_mutex_unlock(&g_mu);
}
@end

id<CAMetalDrawable> s2a_ios_reflection_drawable(CAMetalLayer *game) {
    uint64_t now=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_mutex_lock(&g_mu);
    CAMetalLayer *m=game && g_live_game==game ? g_live_mirror : nil;
    // A drawable whose present never happened (the renderer dropped the frame) is given up after 500 ms
    if (m && g_inflight>=2 && now-g_taken_ns<500000000ull) m=nil;
    if (m) { if (g_inflight>=2) g_inflight=0; g_inflight++; g_taken_ns=now; }
    pthread_mutex_unlock(&g_mu);
    if (!m) return nil;
    if (m.device!=game.device) m.device=game.device;   // The renderer sets these on the game layer after it is attached
    if (m.pixelFormat!=game.pixelFormat) m.pixelFormat=game.pixelFormat;
    if (m.colorspace!=game.colorspace) m.colorspace=game.colorspace;
    id<CAMetalDrawable> d=m.device ? [m nextDrawable] : nil;
    void (^done)(void)=^{ pthread_mutex_lock(&g_mu); if (g_inflight>0) g_inflight--; pthread_mutex_unlock(&g_mu); };
    if (!d) { done(); return nil; }
    [d addPresentedHandler:^(id<MTLDrawable> x) { (void)x; done(); }];   // Also called when the frame is dropped (presentedTime 0)
    return d;
}

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
    pthread_mutex_lock(&g_mu);   // Moved to another root (external display): that root's background decides afresh
    if (g_live_game==game) g_live_game=g_live_mirror=nil;
    pthread_mutex_unlock(&g_mu);
    background.game=game;
    S2APlayReflectionLayout(root,s2a_ios_play_layout());
}
#endif
