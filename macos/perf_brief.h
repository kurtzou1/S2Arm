// 帧率浮层（Mac 玩家前端「显示」菜单「显示帧率」，#2207）：游戏运行中随时开关，可只看帧率或帧率旁带内存占用。
#import <AppKit/AppKit.h>

// 在 view 右上角显示 / 去掉浮层（on = NO 去掉）；mem = YES 时帧率旁带内存占用。重复调用只更新、不叠加。主线程调。
void s2a_perf_brief_apply(NSView *view, BOOL on, BOOL mem);
// 立即刷新一次浮层文字（定时器每 0.5 秒也会刷新）；没有浮层返回 nil，否则返回当前文字
NSString *s2a_perf_brief_refresh(void);
