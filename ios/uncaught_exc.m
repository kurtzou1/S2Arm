// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 未捕获的 ObjC 异常：记下异常名、原因、userInfo 与调用栈符号，再交给原先的处理（之后照常 abort → 崩溃现场）。
//   11-14 #5eac3f：苹果 GameController 在主队列回调里抛了 NSException（终止原因 FOUNDATION 0x1），我们没装这个处理，
//   诊断里只剩「主队列 → GameController」几帧偏移，异常名和原因都丢了，判不了是哪一步用法触发的
#import <Foundation/Foundation.h>
#include "../runtime/src/native.h"
#include <dlfcn.h>
#include <string.h>

static NSUncaughtExceptionHandler *g_prev;
static void s2a_uncaught(NSException *e) {
    LOG("【红】未捕获的 ObjC 异常：%s：%s", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "（无原因）");
    if (e.userInfo.count) LOG("  异常 userInfo：%s", e.userInfo.description.UTF8String ?: "");
    NSArray<NSString *> *st = e.callStackSymbols; NSArray<NSNumber *> *ra = e.callStackReturnAddresses;
    // 每帧另写「模块 + 偏移」（11-21 D-Q349：符号名是离它最近的导出符号，静态函数会被记成别人的「+1240」，要回找同版本构建产物反查；有了偏移直接 atos）
    for (NSUInteger i = 0; i < st.count && i < 32; i++) {
        Dl_info di = {0}; uintptr_t a = i < ra.count ? (uintptr_t)ra[i].unsignedLongLongValue : 0;
        if (a && dladdr((const void *)a, &di) && di.dli_fname && di.dli_fbase) { const char *bn = strrchr(di.dli_fname, '/');
            LOG("  异常栈 %s（%s+%#lx）", st[i].UTF8String ?: "", bn ? bn + 1 : di.dli_fname, (unsigned long)(a - (uintptr_t)di.dli_fbase)); }
        else LOG("  异常栈 %s", st[i].UTF8String ?: "");
    }
    if (g_prev) g_prev(e);
}
__attribute__((constructor)) static void s2a_uncaught_install(void) {
    g_prev = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(s2a_uncaught);
}

#if TARGET_OS_IPHONE
// 后台线程改 UIKit 视图的取证（D-F2G7 / D-TARV，11-16）：「Modifications to the layout engine must not be performed from a background thread」
//   崩在系统 GCD 线程提交 CoreAnimation 隐式事务时，改视图的那段代码早已返回、栈里没有它。这里给最常用的几个 UIView / UILabel 改动方法套一层：
//   不在主线程调用时记一次调用方的栈（全程最多 8 次），只记日志、照原样调下去，不改行为
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
static _Atomic int g_offmain_n;
static void offmain_note(const char *sel) {
    if (NSThread.isMainThread || g_offmain_n >= 8) return;
    int n = ++g_offmain_n; if (n > 8) return;
    LOG("【红】后台线程改界面（第 %d 次，最多记 8 次）：-%s，线程 %s", n, sel, NSThread.currentThread.description.UTF8String ?: "?");
    NSArray<NSString *> *st = NSThread.callStackSymbols;
    for (NSUInteger i = 2; i < st.count && i < 18; i++) LOG("  改界面栈 %s", st[i].UTF8String ?: "");
}
__attribute__((constructor)) static void s2a_offmain_install(void) {
    const char *e = getenv("S2A_OFFMAIN_UI"); if (e && *e == '0') return;
    { Method m = class_getInstanceMethod(UIView.class, @selector(setFrame:)); void (*o)(id, SEL, CGRect) = (void (*)(id, SEL, CGRect))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s, CGRect r) { offmain_note("setFrame:"); o(s, @selector(setFrame:), r); })); }
    { Method m = class_getInstanceMethod(UIView.class, @selector(setBounds:)); void (*o)(id, SEL, CGRect) = (void (*)(id, SEL, CGRect))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s, CGRect r) { offmain_note("setBounds:"); o(s, @selector(setBounds:), r); })); }
    { Method m = class_getInstanceMethod(UIView.class, @selector(setCenter:)); void (*o)(id, SEL, CGPoint) = (void (*)(id, SEL, CGPoint))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s, CGPoint p) { offmain_note("setCenter:"); o(s, @selector(setCenter:), p); })); }
    { Method m = class_getInstanceMethod(UIView.class, @selector(setHidden:)); void (*o)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s, BOOL h) { offmain_note("setHidden:"); o(s, @selector(setHidden:), h); })); }
    { Method m = class_getInstanceMethod(UIView.class, @selector(addSubview:)); void (*o)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s, id v) { offmain_note("addSubview:"); o(s, @selector(addSubview:), v); })); }
    { Method m = class_getInstanceMethod(UIView.class, @selector(removeFromSuperview)); void (*o)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s) { offmain_note("removeFromSuperview"); o(s, @selector(removeFromSuperview)); })); }
    { Method m = class_getInstanceMethod(UIView.class, @selector(setNeedsLayout)); void (*o)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s) { offmain_note("setNeedsLayout"); o(s, @selector(setNeedsLayout)); })); }
    { Method m = class_getInstanceMethod(UILabel.class, @selector(setText:)); void (*o)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s, id t) { offmain_note("UILabel setText:"); o(s, @selector(setText:), t); })); }
    { Method m = class_getInstanceMethod(UILabel.class, @selector(setAttributedText:)); void (*o)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
      method_setImplementation(m, imp_implementationWithBlock(^(id s, id t) { offmain_note("UILabel setAttributedText:"); o(s, @selector(setAttributedText:), t); })); }
}
#endif
