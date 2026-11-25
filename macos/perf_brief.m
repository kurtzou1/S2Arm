// 帧率浮层（#2207，约定见 perf_brief.h）：右上角一枚小胶囊，每 0.5 秒刷新（开菜单 / 拖窗时也刷新）。
//   不接鼠标：点画面照旧锁视角；它是 NSView，游戏纹理读回（截图 / 存帧）不含它。文字与 iPhone 齿轮「性能浮层」同源（runtime/src/hud.c）。
#import "perf_brief.h"
#include "../runtime/include/s2a_hud.h"

@interface S2APerfBrief : NSView
@property(nonatomic, strong) NSTextField *text;
@property(nonatomic) BOOL mem;
@end
@implementation S2APerfBrief
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO; self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.55].CGColor; self.layer.cornerRadius = 9;
        self.text = [NSTextField labelWithString:@""];
        self.text.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
        self.text.textColor = NSColor.whiteColor; self.text.refusesFirstResponder = YES;
        self.text.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:self.text];
        [NSLayoutConstraint activateConstraints:@[
            [self.text.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [self.text.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [self.text.topAnchor constraintEqualToAnchor:self.topAnchor constant:2],
            [self.text.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2]]];
        self.accessibilityIdentifier = @"hud.brief";
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

static S2APerfBrief *g_brief; static NSTimer *g_timer;

NSString *s2a_perf_brief_refresh(void) {
    if (!g_brief) return nil;
    char t[128]; if (g_brief.mem) s2a_hud_brief(t, sizeof t); else s2a_hud_brief_fps(t, sizeof t);
    g_brief.text.stringValue = @(t);
    return g_brief.text.stringValue;
}

void s2a_perf_brief_apply(NSView *view, BOOL on, BOOL mem) {
    s2a_hud_brief_set(on && view);   // 开着才记上屏时间戳（runtime/src/ap_host.c）
    if (!on || !view) { [g_timer invalidate]; g_timer = nil; [g_brief removeFromSuperview]; g_brief = nil; return; }
    if (g_brief.superview != view) {
        [g_brief removeFromSuperview];
        g_brief = [S2APerfBrief new]; [view addSubview:g_brief];
        [NSLayoutConstraint activateConstraints:@[[g_brief.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],
            [g_brief.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-8]]];
    }
    g_brief.mem = mem;
    if (!g_timer) {
        g_timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t; s2a_perf_brief_refresh(); }];
        [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
    }
    s2a_perf_brief_refresh();
}
