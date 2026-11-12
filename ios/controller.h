#import <UIKit/UIKit.h>
#include <stdio.h>
#include <stdlib.h>
// s2a_controller_attach 只在主线程调用；触控回调也在主线程。
void s2a_controller_attach(UIView *root, void (^touchEnabled)(BOOL enabled));
// 任何线程都可调：不在主线程时排到主队列再改手柄 / 虚拟手柄（v0.3.0 起挂起 / 恢复在串行队列 s2a.ios-lifecycle 上调它）
void s2a_controller_set_foreground(int foreground);
// 只许主线程的 UIKit 入口（11-11 v0.3.0 局中失焦崩溃：生命周期队列上改 UIImageView 触发 UIKit 主线程断言、App 被系统中止）：
//   不在主线程就打一行【红】点名入口；测试开关 S2A_STRICT_MAIN=1（宿主生命周期自测 S2A_TEST_LIFECYCLE 会设）当场中止，谁再把它挪去后台，自测当场红
#define S2A_MAIN_ONLY(what) do { if (!NSThread.isMainThread) { fprintf(stderr, "[s2a] 【红】%s 不在主线程上调（UIKit 只许主线程）\n", what); \
    if (getenv("S2A_STRICT_MAIN")) abort(); } } while (0)
