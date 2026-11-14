// Standalone input workbench. Links the production UIKit/layout/controller/pad code;
// no guest, game resources, emulator memory window or renderer is started here.
#import <UIKit/UIKit.h>
#import "s2a_l10n.h"
#import "controller.h"
#import "vpad.h"
#import "play_layout.h"
#include "s2a_pad.h"
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
    _display = [CADisplayLink displayLinkWithTarget:self selector:@selector(refresh:)];
    [_display addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
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
    s2a_pad_snapshot snapshot; s2a_pad_read_ex(&snapshot);
    _snapshot.text = [NSString stringWithFormat:@"F01 输入诊断 · 无游戏运行\nsource=%u buttons=0x%04x\nL=(%d,%d) R=(%d,%d)",
        snapshot.source, snapshot.buttons, snapshot.axes[0], snapshot.axes[1], snapshot.axes[2], snapshot.axes[3]];
    if (![_lastSnapshot isEqualToString:_snapshot.text]) {
        _lastSnapshot = _snapshot.text;
        [self record:@{@"kind": @"input", @"source": @(snapshot.source), @"buttons": @(snapshot.buttons),
            @"axes": @[@(snapshot.axes[0]), @(snapshot.axes[1]), @(snapshot.axes[2]), @(snapshot.axes[3])]}];
    }
}
- (void)background:(NSNotification *)note { s2a_controller_set_foreground(0); [self record:@{@"kind": @"background"}]; [self refresh:nil]; }
- (void)foreground:(NSNotification *)note { s2a_controller_set_foreground(1); [self record:@{@"kind": @"foreground"}]; [self refresh:nil]; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
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
