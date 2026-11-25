// 帧率浮层（macos/perf_brief.m，#2207）离屏单测：真建 NSView，按菜单的三种状态调 s2a_perf_brief_apply，核子视图、文字、位置、鼠标穿透与上屏计时开关。
//   帧数 / 内存文字来自 runtime/src/hud.c（t_hud 单测核过），这里桩成固定串，只核浮层取哪一种、放在哪、开关是否干净。期望按需求手写。
//   第一个参数给了 PNG 路径时把浮层开着的画面渲成图（不走系统截屏，不弹授权框）。用法：t_perf_brief [out.png]
#import <AppKit/AppKit.h>
#include <stdio.h>
#import "../perf_brief.h"

static int g_set = -1, g_fails;
void s2a_hud_brief_set(int on) { g_set = on; }
int s2a_hud_brief(char *o, size_t n) { return snprintf(o, n, "57 帧 · 进程 1.2 GB · GPU 0.8 GB"); }
int s2a_hud_brief_fps(char *o, size_t n) { return snprintf(o, n, "57 帧"); }

static void ck(const char *what, int ok, NSString *got) { printf("%s %s%s%s\n", ok ? "✓" : "✗", what, got ? " → " : "", got ? got.UTF8String : ""); g_fails += !ok; }
static NSArray<NSView *> *briefs(NSView *v) { return [v.subviews filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSView *s, id b) { (void)b; return [s.accessibilityIdentifier isEqual:@"hud.brief"]; }]]; }

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)]; view.wantsLayer = YES; view.layer.backgroundColor = NSColor.darkGrayColor.CGColor;
        ck("关着时没有浮层、刷新返回空", briefs(view).count == 0 && s2a_perf_brief_refresh() == nil, nil);
        s2a_perf_brief_apply(view, YES, NO);
        ck("开（只看帧率）：一枚浮层，文字只有帧数", briefs(view).count == 1 && [s2a_perf_brief_refresh() isEqual:@"57 帧"], s2a_perf_brief_refresh());
        ck("开：上屏计时打开", g_set == 1, nil);
        [view layoutSubtreeIfNeeded]; NSView *b = briefs(view).firstObject; NSRect f = b.frame;
        ck("位置：右上角，距右、上各 8 点（不翻转坐标，上边 = 高 - 8）", fabs(NSMaxX(f) - 632) < 0.5 && fabs(NSMaxY(f) - 352) < 0.5 && f.size.width > 20,
           [NSString stringWithFormat:@"%@", NSStringFromRect(f)]);
        NSPoint mid = NSMakePoint(NSMidX(f), NSMidY(f));
        ck("点浮层位置：鼠标落到下面的画面（不被浮层吃掉）", [view hitTest:mid] == view, nil);
        s2a_perf_brief_apply(view, YES, YES);
        ck("帧率旁带内存：仍只一枚、文字带内存", briefs(view).count == 1 && [s2a_perf_brief_refresh() isEqual:@"57 帧 · 进程 1.2 GB · GPU 0.8 GB"], s2a_perf_brief_refresh());
        if (argc > 1) {   // 离屏渲图（人眼看样式）
            [view layoutSubtreeIfNeeded];
            NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds]; [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
        }
        s2a_perf_brief_apply(view, YES, NO);
        ck("再切回只看帧率", briefs(view).count == 1 && [s2a_perf_brief_refresh() isEqual:@"57 帧"], s2a_perf_brief_refresh());
        s2a_perf_brief_apply(view, NO, NO);
        ck("关：浮层去掉、刷新返回空、上屏计时关", briefs(view).count == 0 && s2a_perf_brief_refresh() == nil && g_set == 0, nil);
        s2a_perf_brief_apply(nil, YES, NO);
        ck("没有游戏画面时开：不建浮层、计时不开", s2a_perf_brief_refresh() == nil && g_set == 0, nil);
    }
    printf("%s t_perf_brief：不通 %d\n", g_fails ? "✗" : "✓", g_fails);
    return g_fails ? 1 : 0;
}
