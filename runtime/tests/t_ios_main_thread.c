// iOS 前后台与 UIKit 主线程（11-11 v0.3.0 局中失焦崩溃：挂起 / 恢复挪到串行队列 s2a.ios-lifecycle 后，
//   s2a_controller_set_foreground 在后台线程改 UIImageView，UIKit 主线程断言中止 App）。这些代码是 UIKit，宿主上编不了，
//   这里对源码做接线断言：谁把主线程那一跳拿掉、把 UIKit 调用写进生命周期队列上跑的函数、或摘掉入口断言 / 真机自测开关，门禁当场红。
//   真机上的行为由宿主自测 S2A_TEST_LIFECYCLE（ios/app.m）覆盖：失去焦点 / 获得焦点 / 进后台 / 回前台，虚拟手柄开着
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int failures, checks;
static void check(int ok, const char *what) { checks++; if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); } }
static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) { fprintf(stderr, "打不开 %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)n + 1); if (fread(b, 1, (size_t)n, f) != (size_t)n) exit(2); b[n] = 0; fclose(f); return b;
}
// 从 head 开始到与第一个「{」配对的「}」为止的函数体（不认字符串里的括号：这几个函数体里没有带括号的字面量）；找不到返回 NULL
static char *body(const char *src, const char *head) {
    const char *p = strstr(src, head); if (!p) return NULL;
    const char *b = strchr(p, '{'); if (!b) return NULL;
    int depth = 0; const char *q = b;
    for (; *q; q++) { if (*q == '{') depth++; else if (*q == '}' && --depth == 0) break; }
    return *q ? strndup(b, (size_t)(q - b + 1)) : NULL;
}
static int has(const char *s, const char *needle) { return s && strstr(s, needle) != NULL; }
// 剔掉「排到主队列」的块（dispatch_async(dispatch_get_main_queue(), ^{ … })）：块里本来就在主线程跑，可以碰 UIKit
static void strip_main_blocks(char *s) {
    static const char key[] = "dispatch_async(dispatch_get_main_queue(), ^{";
    for (char *p; s && (p = strstr(s, key)); ) {
        char *q = p + sizeof key - 2; int depth = 0;   // q 指向块的「{」
        for (; *q; q++) { if (*q == '{') depth++; else if (*q == '}' && --depth == 0) break; }
        if (!*q) return;
        memset(p, ' ', (size_t)(q - p + 1));
    }
}
int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "用法：t_ios_main_thread <app.m> <controller.m> <vpad.m>\n"); return 2; }
    char *app = slurp(argv[1]), *ctl = slurp(argv[2]), *vp = slurp(argv[3]);

    // ① 生命周期队列上跑的挂起 / 恢复：函数体里不直接碰 UIKit（视图、UIApplication、无障碍、根视图），界面一律经 s2a_controller_set_foreground
    char *susp = body(app, "static void s2a_ios_suspend(int on, const char *why) {");
    check(susp != NULL, "app.m 找得到 s2a_ios_suspend 函数体");
    check(has(susp, "s2a_controller_set_foreground"), "s2a_ios_suspend 切手柄前后台只经 s2a_controller_set_foreground");
    strip_main_blocks(susp);
    const char *uikit[] = {"UIApplication", "UIView", "UIImage", "UILabel", "UIScreen", "g_root", "accessibility", "setHidden", "setNeedsLayout", "presentViewController"};
    for (size_t i = 0; i < sizeof uikit / sizeof *uikit; i++) {
        char what[160]; snprintf(what, sizeof what, "s2a_ios_suspend（生命周期队列上跑）不直接用 %s", uikit[i]);
        check(!has(susp, uikit[i]), what);
    }
    check(has(app, "dispatch_async(s2a_lifecycle_queue()"), "挂起 / 恢复仍在生命周期队列上（GPU 排空不回 UIKit 回调里做）");

    // ② s2a_controller_set_foreground 任何线程可调：不在主线程排到主队列
    char *fg = body(ctl, "void s2a_controller_set_foreground(int foreground) {");
    check(has(fg, "NSThread.isMainThread"), "s2a_controller_set_foreground 先判是不是主线程");
    check(has(fg, "dispatch_async(dispatch_get_main_queue()"), "不在主线程时排到主队列（async，不 sync）");
    check(!has(fg, "dispatch_sync"), "不用 dispatch_sync 回主线程（调用方可能持着主线程要等的东西）");

    // ③ 只许主线程的 UIKit 入口带断言
    check(has(body(ctl, "- (void)setForeground:(BOOL)foreground {"), "S2A_MAIN_ONLY("), "-[S2AController setForeground:] 带主线程断言");
    check(has(body(vp, "- (void)setInputEnabled:(BOOL)enabled {"), "S2A_MAIN_ONLY("), "-[S2AVPadView setInputEnabled:] 带主线程断言");
    check(has(body(vp, "- (void)clearTouches {"), "S2A_MAIN_ONLY("), "-[S2AVPadView clearTouches] 带主线程断言");

    // ④ 真机宿主自测开关在：三种事件、严格模式
    check(has(app, "S2A_TEST_LIFECYCLE") && has(app, "setenv(\"S2A_STRICT_MAIN\", \"1\", 1)"), "app.m 有生命周期自测开关且开严格主线程模式");
    char *selftest = strstr(app, "S2A_TEST_LIFECYCLE");
    check(has(selftest, "UIApplicationWillResignActiveNotification") && has(selftest, "UIApplicationDidEnterBackgroundNotification")
          && has(selftest, "UIApplicationWillEnterForegroundNotification") && has(selftest, "UIApplicationDidBecomeActiveNotification"),
          "自测覆盖失去焦点 / 获得焦点 / 进后台 / 回前台");

    printf("%s t_ios_main_thread：%d / %d\n", failures ? "✗" : "✓", checks - failures, checks);
    return failures ? 1 : 0;
}
