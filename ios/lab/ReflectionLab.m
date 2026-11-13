// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Synthetic Metal drawable, production host composition; no game or input runtime.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "play_reflection.h"

@interface ReflectionLab : S2APlayViewController
@end
@implementation ReflectionLab {
    CAMetalLayer *_game;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    CADisplayLink *_display;
    UIStackView *_bar;
    UIButton *_key;
    BOOL _fold, _letterbox, _pattern;
    NSUInteger _frames, _presses;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.blackColor; _fold=YES;
    _game=[CAMetalLayer layer]; _game.device=MTLCreateSystemDefaultDevice();
    _game.pixelFormat=MTLPixelFormatBGRA8Unorm; _game.framebufferOnly=YES;
    _game.drawableSize=CGSizeMake(256,192); _queue=[_game.device newCommandQueue];
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint i [[vertex_id]]) { return float4(float2((i<<1)&2,i&2)*2-1,0,1); }\n"
        "fragment float4 fs(float4 p [[position]],constant uint &alternate [[buffer(0)]]) {\n"
        "float3 c=p.y<64?float3(220,20,20):p.y<128?float3(20,220,20):float3(20,20,220);\n"
        "if(alternate) c=c.bgr; if(p.x>=24 && p.x<48) c=float3(240); return float4(c/255,1); }\n";
    NSError *error=nil; id<MTLLibrary> lib=[_game.device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[lib newFunctionWithName:@"vs"]; pd.fragmentFunction=[lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat=_game.pixelFormat;
    _pipeline=[_game.device newRenderPipelineStateWithDescriptor:pd error:&error];
    NSCAssert(_pipeline,@"Synthetic Metal pipeline: %@",error);
#if S2A_REFLECTION_BASELINE
    [self.view.layer insertSublayer:_game atIndex:0];
#else
    s2a_ios_attach_game_layer(self.view,_game);
#endif
    _bar=[UIStackView new]; _bar.axis=UILayoutConstraintAxisVertical; _bar.spacing=8;
    for (NSString *title in @[@"分屏开关",@"模拟折痕",@"画面留边",@"更换图案",@"切换方向"]) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:title forState:UIControlStateNormal]; b.backgroundColor=[UIColor colorWithWhite:0 alpha:.6];
        b.tag=_bar.arrangedSubviews.count; b.accessibilityIdentifier=[@"reflection." stringByAppendingFormat:@"%ld",(long)b.tag];
        [b addTarget:self action:@selector(change:) forControlEvents:UIControlEventTouchUpInside]; [_bar addArrangedSubview:b];
    }
    [self.view addSubview:_bar];
    _key=[UIButton buttonWithType:UIButtonTypeSystem]; [_key setTitle:@"下区按键 0" forState:UIControlStateNormal];
    _key.accessibilityIdentifier=@"reflection.key"; _key.backgroundColor=[UIColor colorWithWhite:0 alpha:.6];
    [_key addTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:_key];
    _display=[CADisplayLink displayLinkWithTarget:self selector:@selector(draw:)];
    _display.preferredFrameRateRange=CAFrameRateRangeMake(5,5,5);
    [_display addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(recordState:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(recordState:) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)change:(UIButton *)button {
    if (button.tag==0) [NSUserDefaults.standardUserDefaults setObject:s2a_ios_play_layout().split?@"off":@"on" forKey:S2APlaySplitKey];
    else if (button.tag==1) _fold=!_fold;
    else if (button.tag==2) _letterbox=!_letterbox;
    else if (button.tag==3) _pattern=!_pattern;
    else [NSUserDefaults.standardUserDefaults setObject:self.view.bounds.size.width>self.view.bounds.size.height?@"portrait":@"landscape" forKey:S2APlayOrientationKey];
    [self.view setNeedsLayout];
}
- (void)press:(UIButton *)button { [button setTitle:[NSString stringWithFormat:@"下区按键 %lu",(unsigned long)++_presses] forState:UIControlStateNormal]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b=self.view.bounds;
    CGRect fold=_fold?CGRectMake(b.origin.x,CGRectGetMidY(b)-12,b.size.width,24):CGRectNull;
    S2APlayLayout l=S2APlayLayoutMake(b,self.view.safeAreaLayoutGuide.layoutFrame,S2APlayReadSplit(NSUserDefaults.standardUserDefaults),NO,fold);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _game.frame=_letterbox?CGRectInset(l.game,l.game.size.width*.15,l.game.size.height*.12):l.game;
    [CATransaction commit];
#if !S2A_REFLECTION_BASELINE
    S2APlayReflectionLayout(self.view,l);
#endif
    _bar.frame=CGRectMake(CGRectGetMidX(l.game)-65,MAX(CGRectGetMinY(l.game),self.view.safeAreaInsets.top)+8,130,182);
    _key.frame=CGRectMake(CGRectGetMidX(l.controls)-65,CGRectGetMinY(l.controls)+40,130,30);
    _key.hidden=!l.split;
}
- (void)draw:(CADisplayLink *)link {
    if (UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || CGRectIsEmpty(_game.frame)) return;
    id<CAMetalDrawable> d=[_game nextDrawable]; if (!d) return;
    id<MTLCommandBuffer> cb=[_queue commandBuffer]; MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture=d.texture; pass.colorAttachments[0].loadAction=MTLLoadActionDontCare; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:_pipeline]; uint32_t alternate=_pattern;
    [e setFragmentBytes:&alternate length:sizeof alternate atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding]; [cb presentDrawable:d]; [cb commit]; _frames++;
    [self recordReport];
}
- (void)recordState:(NSNotification *)note { dispatch_async(dispatch_get_main_queue(),^{ [self recordReport]; }); }
- (void)recordReport {
    CAReplicatorLayer *copies=nil;
    BOOL blurVisible=NO;
    for (UIView *v in self.view.subviews) for (CALayer *layer in v.layer.sublayers) if ([layer isKindOfClass:CAReplicatorLayer.class]) copies=(id)layer;
    for (UIView *v in self.view.subviews) for (UIView *sub in v.subviews) if ([sub isKindOfClass:UIVisualEffectView.class]) blurVisible=!sub.hidden;
    NSDictionary *report=@{@"frames":@(_frames),@"presses":@(_presses),@"split":@(s2a_ios_play_layout().split),@"syntheticFold":@(_fold),@"letterbox":@(_letterbox),@"pattern":@(_pattern),@"replicas":@(copies.instanceCount),@"blurVisible":@(blurVisible),@"applicationState":@(UIApplication.sharedApplication.applicationState),@"framebufferOnly":@(_game.framebufferOnly),@"view":NSStringFromCGRect(self.view.bounds),@"game":NSStringFromCGRect(_game.frame)};
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[docs URLByAppendingPathComponent:@"reflection-lab.json"] atomically:YES];
}
@end

@interface ReflectionScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation ReflectionScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window=[[UIWindow alloc] initWithWindowScene:(id)scene];
    self.window.rootViewController=[ReflectionLab new]; [self.window makeKeyAndVisible];
}
@end
@interface ReflectionApp : UIResponder <UIApplicationDelegate>
@end
@implementation ReflectionApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    [NSUserDefaults.standardUserDefaults setObject:@"on" forKey:S2APlaySplitKey];
    [NSUserDefaults.standardUserDefaults setObject:@"portrait" forKey:S2APlayOrientationKey]; return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ReflectionApp.class)); } }
