#include "nvn_fps.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static _Atomic int g_limit;   // 上屏 / 提交线程每帧读；进程内重启时宿主线程重写（nvn_fps_session_reset）
// 只认十进制整数（不带符号、空格或尾随字符）；越界或别的写法返回 -1
int nvn_fps_parse(const char *e) {
    if (!e || !*e) return -1;
    if (!strcmp(e, "0")) return 0;
    int v = 0;
    for (const char *p = e; *p; p++) {
        if (*p < '0' || *p > '9' || p - e >= 4) return -1;
        v = v * 10 + (*p - '0');
    }
    return v >= NVN_FPS_MIN_HZ && v <= NVN_FPS_MAX_HZ ? v : -1;
}
static void fps_read(void) {
    const char *e = getenv("S2A_FPS");
    int v = 0;
    if (e) {
        v = nvn_fps_parse(e);
        if (v < 0) { fprintf(stderr, "[nvn] 【红】 S2A_FPS=%s：只接受 0（不限）或 %d–%d 的整数\n", e, NVN_FPS_MIN_HZ, NVN_FPS_MAX_HZ); abort(); }
    }
    atomic_store(&g_limit, v);
    if (v) fprintf(stderr, "[nvn] S2A_FPS=%d：直连额外帧率上限，保留游戏交换间隔；DM_PRESENT_HZ / DM_FPS 不绕过此上限\n", v);
}
static void fps_init(void) { fps_read(); }
// 进程内重启（设置页 / 局内「立即重启」，runtime/src/host_main.c s2a_host_rebuild）：设置层已按玩家新选的值重放 S2A_FPS，这里跟着重读。
//   原先只在进程里第一次用到时读一次（pthread_once），改了上限点「立即重启」新局仍按旧上限跑，要划掉 App 冷启动才生效（#502 D-XTV7：30 → 60 → 不限两次重启，整局仍压 30）
void nvn_fps_session_reset(void) {
    pthread_once(&g_once, fps_init);   // 先占住首读，免得之后懒读又按当时的环境覆盖一遍
    fps_read();
    if (!atomic_load(&g_limit)) fprintf(stderr, "[nvn] S2A_FPS：本局不额外限帧（进程内重启重读）\n");
}
// 玩家上限只压补丁抬上去的那部分（11-25 #502）：帧率没被抬高（没开 60 帧补丁 / 我方帧率表）时不管用——游戏自己要 60 就按 60，
//   压到 30 按帧推进的款就是半速慢动作；补丁开着、上限 30 时补丁那边已改按 30 帧档跑（runtime/src/cpatch.c cap30）。
//   s2a_fps_raised 在 runtime/src/fps.c；不链运行时的单测 / 工具没有它 = 当作抬高了（旧行为，单测按此判上限本身）
// 弱链接[nvntest]：s2a_fps_raised（runtime/src/fps.c 提供；宿主 / iOS 照常链上，NVN 单测不链原生层，按这行放行未定义）
int s2a_fps_raised(void) __attribute__((weak));
int nvn_fps_limit_set(void) { pthread_once(&g_once, fps_init); return atomic_load_explicit(&g_limit, memory_order_relaxed); }
int nvn_fps_limit(void) { int v = nvn_fps_limit_set(); return v && s2a_fps_raised && !s2a_fps_raised() ? 0 : v; }
double nvn_fps_period(double period) {
    int fps = nvn_fps_limit(); double limit = fps ? 1.0 / fps : 0;
    return period < limit ? limit : period;
}
uint64_t nvn_fps_period_ns(uint64_t period) {
    int fps = nvn_fps_limit(); uint64_t limit = fps ? (1000000000ull + fps - 1) / fps : 0;
    return period < limit ? limit : period;
}
// 用户帧率设置只加上限；不改游戏的交换间隔，也不解除游戏原有的锁帧。
