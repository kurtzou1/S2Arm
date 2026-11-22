// Standalone input workbench. Links the production UIKit/layout/controller/pad code;
// no guest, game resources, emulator memory window or renderer is started here.
#import <UIKit/UIKit.h>
#import "s2a_l10n.h"
#import "controller.h"
#import "vpad.h"
#import "play_layout.h"
#include "s2a_pad.h"
#import <GameController/GameController.h>
int s2a_vpad_pad_count(void); uint32_t s2a_vpad_read_pad(int index, int32_t *sticks);   // ios/controller.m 槽 1–3
int s2a_ios_mouse_lock_wanted(void);   // ios/mouse.m
void s2a_vpad_read_ex(s2a_pad_snapshot *out);   // ios/vpad.m
#include <math.h>

void s2a_diag_attach(UIViewController *controller);
static uint64_t displayTicks;
uint64_t s2a_ap_frames(void) { return displayTicks; }
const char *s2a_main_build_id(void) { return "f01-input-lab-no-guest"; }
int s2a_autoplay_on(void) { return 1; } // This workbench never records game replay/save markers.

@interface S2AInputLabVC : S2APlayViewController
- (void)record:(NSDictionary *)event;
@end
static __weak S2AInputLabVC *labController;
// The workbench supplies its own measured viewport; it has no guest display or renderer.
int s2a_screen_w(void) {
    CGSize size = labController.view.bounds.size;
    return size.height > 0 ? MAX(1920, (int)lround(1080.0 * size.width / size.height)) : 0;
}
// No guest load stage here: the measured viewport is known as soon as the view is laid out (vpad.m reads this one).
int s2a_screen_w_after_load(void) { return s2a_screen_w(); }
@implementation S2AInputLabVC {
    UILabel *_snapshot;
    CADisplayLink *_display;
    NSFileHandle *_events;
    NSString *_lastSnapshot, *_run;
    NSUInteger _sequence;
    NSMutableArray<GCVirtualController *> *_virtualPads;   // 模拟器验分配玩家（#1606 ④）：S2A_LAB_VIRTUAL_PADS=n 时建 n 只系统虚拟手柄
}
- (void)viewDidLoad {
    [super viewDidLoad];
    labController = self;
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.13 alpha:1];
    _run = NSUUID.UUID.UUIDString;
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *events = [documents URLByAppendingPathComponent:@"input-events.jsonl"];
    if (![NSFileManager.defaultManager fileExistsAtPath:events.path]) [NSFileManager.defaultManager createFileAtPath:events.path contents:nil attributes:nil];
    _events = [NSFileHandle fileHandleForWritingToURL:events error:nil]; [_events seekToEndOfFile];
    [self record:@{@"kind": @"launch", @"gameRunning": @NO}];
    _snapshot = [UILabel new]; _snapshot.textColor = UIColor.whiteColor;
    _snapshot.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    _snapshot.textAlignment = NSTextAlignmentCenter; _snapshot.numberOfLines = 0;
    _snapshot.accessibilityIdentifier = @"lab.snapshot"; _snapshot.userInteractionEnabled = NO;
    [self.view addSubview:_snapshot];
    s2a_vpad_attach(self.view);
    s2a_diag_attach(self);
    int virtualPads = getenv("S2A_LAB_VIRTUAL_PADS") ? atoi(getenv("S2A_LAB_VIRTUAL_PADS")) : 0;
    _virtualPads = [NSMutableArray array];
    for (int i = 0; i < virtualPads && i < 4; i++) {
        GCVirtualControllerConfiguration *config = [GCVirtualControllerConfiguration new];
        config.elements = [NSSet setWithArray:@[GCInputButtonA, GCInputButtonB, GCInputDirectionPad]];
        GCVirtualController *pad = [GCVirtualController virtualControllerWithConfiguration:config];
        [_virtualPads addObject:pad];
        [pad connectWithReplyHandler:^(NSError *error) { [labController record:@{@"kind": @"virtualPad", @"index": @(i), @"error": error.localizedDescription ?: @""}]; }];
    }
    if (getenv("S2A_LAB_SCRIPT") && !strcmp(getenv("S2A_LAB_SCRIPT"), "assign"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [labController runAssignScript]; });
    _display = [CADisplayLink displayLinkWithTarget:self selector:@selector(refresh:)];
    [_display addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
}
// 模拟器脚本（S2A_LAB_SCRIPT=assign，#1606 ④）：不靠点屏走一遍「分配玩家」——开面板 → 在第 2 只虚拟手柄按 A（登记 P1）→ 第 1 只按 A（P2）→ 完成，
//   再分别在两只上按 A，记下 P1 / P2 各读到什么（input-events.jsonl 的 assignStep）。虚拟手柄用代码按键（iOS 17 GCVirtualController setValue:forButtonElement:）
- (void)press:(int)index after:(double)t label:(NSString *)label {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (index >= (int)self->_virtualPads.count) return;
        [self->_virtualPads[index] setValue:1 forButtonElement:GCInputButtonA];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            s2a_pad_snapshot snap; s2a_vpad_read_ex(&snap); int32_t st[4]; uint32_t p2 = s2a_vpad_read_pad(1, st);
            [self record:@{@"kind": @"assignStep", @"step": label, @"pad": @(index), @"p1buttons": @(snap.buttons), @"p1source": @(snap.source),
                           @"p2buttons": @(p2), @"slots": @(s2a_vpad_pad_count())}];
            [self->_virtualPads[index] setValue:0 forButtonElement:GCInputButtonA];
        });
    });
}
- (void)runAssignScript {
    NSMutableArray *names = [NSMutableArray array];
    for (GCController *c in GCController.controllers) [names addObject:[NSString stringWithFormat:@"%@|%@|%d", c.vendorName ?: @"?", c.productCategory ?: @"?", c.extendedGamepad != nil]];
    [self record:@{@"kind": @"assignStep", @"step": @"controllers", @"list": names}];
    [self press:0 after:0.5 label:@"before-pad0"];
    [self press:1 after:1.5 label:@"before-pad1"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *panel = s2a_ios_player_assign(^{ [labController record:@{@"kind": @"assignStep", @"step": @"panelClosed"}]; });
        UIViewController *top = self; while (top.presentedViewController) top = top.presentedViewController;   // 上面可能还盖着别的弹框
        [top presentViewController:panel animated:NO completion:nil];
        [self record:@{@"kind": @"assignStep", @"step": @"panelShown", @"presenter": NSStringFromClass(top.class)}];
        [self press:1 after:1.0 label:@"panel-pad1"];
        [self press:0 after:2.0 label:@"panel-pad0"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UINavigationController *nav = (UINavigationController *)panel;
            UIBarButtonItem *done = nav.topViewController.navigationItem.rightBarButtonItem;
            [UIApplication.sharedApplication sendAction:done.action to:done.target from:done forEvent:nil];
            [self press:0 after:1.5 label:@"after-pad0"];
            [self press:1 after:2.5 label:@"after-pad1"];
        });
    });
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect game=s2a_ios_game_area(); if (CGRectIsEmpty(game)) game=self.view.bounds;
    _snapshot.frame = CGRectMake(game.origin.x+16, CGRectGetMidY(game)-70, MAX(1, game.size.width-32), 140);
    UIEdgeInsets safe = self.view.safeAreaInsets;
    [self record:@{@"kind": @"geometry", @"width": @(self.view.bounds.size.width), @"height": @(self.view.bounds.size.height),
        @"safeTop": @(safe.top), @"safeLeft": @(safe.left), @"safeBottom": @(safe.bottom), @"safeRight": @(safe.right),
        @"split":@(s2a_ios_play_layout().split), @"gameX":@(game.origin.x), @"gameY":@(game.origin.y), @"gameWidth":@(game.size.width), @"gameHeight":@(game.size.height)}];
}
- (void)record:(NSDictionary *)event {
    NSMutableDictionary *row = [event mutableCopy]; row[@"run"] = _run; row[@"seq"] = @(++_sequence);
    row[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime);
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
    [_events writeData:data]; [_events writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}
- (void)refresh:(CADisplayLink *)link {
    displayTicks++;
    s2a_pad_snapshot snapshot; s2a_vpad_read_ex(&snapshot);   // 走游戏同一个读导出（InputPump 读的就是它）：鼠标视角位移在这里加进右摇杆，直接读 pad.c 看不到
    int32_t p2[4]; uint32_t p2b = s2a_vpad_read_pad(1, p2);
    _snapshot.text = [NSString stringWithFormat:@"F01 输入诊断 · 无游戏运行\nsource=%u buttons=0x%04x\nL=(%d,%d) R=(%d,%d)\nslots=%d P2 buttons=0x%04x",
        snapshot.source, snapshot.buttons, snapshot.axes[0], snapshot.axes[1], snapshot.axes[2], snapshot.axes[3], s2a_vpad_pad_count(), p2b];
    if (![_lastSnapshot isEqualToString:_snapshot.text]) {
        _lastSnapshot = _snapshot.text;
        [self record:@{@"kind": @"input", @"source": @(snapshot.source), @"buttons": @(snapshot.buttons), @"slots": @(s2a_vpad_pad_count()), @"p2buttons": @(p2b),
            @"axes": @[@(snapshot.axes[0]), @(snapshot.axes[1]), @(snapshot.axes[2]), @(snapshot.axes[3])]}];
    }
}
- (void)background:(NSNotification *)note { s2a_controller_set_foreground(0); [self record:@{@"kind": @"background"}]; [self refresh:nil]; }
- (void)foreground:(NSNotification *)note { s2a_controller_set_foreground(1); [self record:@{@"kind": @"foreground"}]; [self refresh:nil]; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersPointerLocked { return s2a_ios_mouse_lock_wanted(); }   // 触控板 / 鼠标转动视角（mouse.m），同游戏页 S2AGameVC
@end

@interface S2AInputLabApplication : UIApplication
@end
@implementation S2AInputLabApplication
- (void)sendEvent:(UIEvent *)event {
    [super sendEvent:event];
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseMoved || touch.phase == UITouchPhaseStationary) continue;
        CGPoint point = [touch locationInView:labController.view];
        [labController record:@{@"kind": @"touch", @"phase": @(touch.phase), @"view": NSStringFromClass(touch.view.class) ?: @"none",
            @"x": @(point.x), @"y": @(point.y)}];
    }
}
@end

@interface S2AInputLabScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation S2AInputLabScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [S2AInputLabVC new]; [self.window makeKeyAndVisible];
}
@end
@interface S2AInputLabApp : UIResponder <UIApplicationDelegate>
@end
@implementation S2AInputLabApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc, char **argv) {
    @autoreleasepool { s2a_l10n_apply_choice(); }   // 同正式 App（ios/app.m 构造期）：设置里选过界面语言就按选的，跟随系统清覆盖
    @autoreleasepool { return UIApplicationMain(argc, argv, NSStringFromClass(S2AInputLabApplication.class), NSStringFromClass(S2AInputLabApp.class)); }
}
