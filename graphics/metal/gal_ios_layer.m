// iOS：把 CAMetalLayer 挂到原生层 App 壳的根视图（ios/app.m s2a_ios_root_view）并交给渲染器出图。Mac 宿主无窗口（出图只计数 / 截图），返回 -1。
// 在主线程建层（UIKit 要求），按屏幕原生像素设可绘制尺寸；之后的尺寸变化（转屏）另接。
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#endif
#import "gal_internal.h"
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
#if TARGET_OS_IPHONE
UIView *s2a_ios_root_view(void) __attribute__((weak_import));
CGRect s2a_ios_game_area(void) __attribute__((weak_import));
void s2a_ios_attach_game_layer(UIView *root, CALayer *game) __attribute__((weak_import));
static CAMetalLayer *g_ios_layer;
// 主线程布局，不接触游戏纹理；渲染线程经已有 SetSize 锁读取新 drawable 尺寸。
NXGAL_API void nxgal_window_relayout_ios(void) {
    UIView *v=g_ios_layer && s2a_ios_root_view ? s2a_ios_root_view() : nil;
    if (!v || UIApplication.sharedApplication.applicationState==UIApplicationStateBackground) return;
    CGRect b=s2a_ios_game_area ? s2a_ios_game_area() : v.bounds;
    if (CGRectIsEmpty(b)) b=v.bounds;
    CGFloat s=v.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    g_ios_layer.frame=b; g_ios_layer.contentsScale=s;
    [CATransaction commit];
    nxgal_window_set_size((int32_t)round(b.size.width*s),(int32_t)round(b.size.height*s));
}
// Optional host hook: wait on the render thread, before dispatching UIKit work.
int s2a_ios_wait_root_view(int timeout_ms) __attribute__((weak_import));
void s2a_ios_render_init_failed(void) __attribute__((weak_import));
NXGAL_API void nxgal_window_attach_failed_ios(void) {
    if (s2a_ios_render_init_failed) s2a_ios_render_init_failed();
    else GRED_ONCE("出图：宿主没有渲染初始化失败提示接口");
}
NXGAL_API int32_t nxgal_window_attach_ios(void) {
    if (!s2a_ios_root_view) { GRED_ONCE("出图：宿主没有 s2a_ios_root_view（不是 iOS App 壳）"); return -1; }
    if (!NSThread.isMainThread && s2a_ios_wait_root_view && s2a_ios_wait_root_view(10000) != 0) {
        GRED_ONCE("出图：等待可见根视图超时，未挂接 Metal 层"); return -1;
    }
    __block CAMetalLayer *L = nil; __block CGSize px = {0, 0};
    void (^mk)(void) = ^{
        UIView *v = s2a_ios_root_view(); if (!v) return;
        L = [CAMetalLayer layer]; CGFloat s = v.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
        CGRect b=s2a_ios_game_area ? s2a_ios_game_area() : v.bounds; if (CGRectIsEmpty(b)) b=v.bounds;
        L.frame = b; L.contentsScale = s; px = CGSizeMake(round(b.size.width * s), round(b.size.height * s));
        L.drawableSize = px;
        g_ios_layer=L;
        // 出图层不透明：整屏游戏画面（黑边也由本层自己画），合成器不必与下面的根视图混合
        L.opaque = YES;
        if (s2a_ios_attach_game_layer) s2a_ios_attach_game_layer(v,L);
        else [v.layer insertSublayer:L atIndex:0];   // Old hosts keep their existing layer hierarchy.
    };
    if (NSThread.isMainThread) mk(); else dispatch_sync(dispatch_get_main_queue(), mk);
    if (!L) { GRED_ONCE("出图：根视图还没建好，没挂上 Metal 层"); return -1; }
    nxgal_window_set_layer((__bridge void *)L); nxgal_window_set_size((int32_t)px.width, (int32_t)px.height);
    GLOG("出图：Metal 层已挂到根视图 %.0fx%.0f 像素（不透明）", px.width, px.height);
    return 0;
}
#else
NXGAL_API void nxgal_window_relayout_ios(void) { }
NXGAL_API int32_t nxgal_window_attach_ios(void) { return -1; }
NXGAL_API void nxgal_window_attach_failed_ios(void) { }
#endif
GAL_MTL4_ZONE_END
