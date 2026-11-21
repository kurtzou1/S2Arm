// 存档不能原子提交的判定（接口见 runtime/include/s2a_direct_prompt.h；iOS 壳与 Mac 游戏窗口共用）。只在前端主线程上调。
#include "native.h"
#include "s2a_direct_prompt.h"
#include "s2a_session.h"
#include <dlfcn.h>

int s2a_save_atomic_poll(void) {
    static int looked, warned, unknown; static int (*state)(void);
    if (warned || s2a_host_session_state() != S2A_SESSION_RUNNING) return 0;
#if defined(__ANDROID__) || defined(__OHOS__)
    // 安卓：服务层静态并入同一个 DSO（--exclude-libs,ALL），dlsym 找不到隐藏导出、恒为 NULL，提示从不出现。改链接期弱引用：
    //   出包的单库里由归档解析（core-link 审计守：归档定义的导出在库里仍未解析就失败）；不带服务层的门禁链接里为空，照旧不提示
    { extern int S2A_SaveAtomicState(void) __attribute__((weak)); if (!looked) { looked = 1; state = S2A_SaveAtomicState; } }
    // 缺席不等于「已确认能原子提交」（#961）：返回未知、红行只打一次；不提示、不挡游戏
    // 弱链接[androidpoll]：S2A_SaveAtomicState（android/tests/save_atomic_poll_test.sh 在 Mac 上链「缺出口」那次）
    if (!state) {
        if (!unknown) { unknown = 1; LOG("【红】存档：服务层没有 S2A_SaveAtomicState（未链服务层或缺这条导出），存档能否原子提交未知，不提示"); }
        return S2A_SAVE_ATOMIC_UNKNOWN;
    }
#else
    if (!looked) { looked = 1; state = (int (*)(void))dlsym(RTLD_DEFAULT, "S2A_SaveAtomicState"); }
#endif
    int bits = state ? state() : 0;
    if (!bits) return 0;
    warned = 1;
    LOG("存档：不能原子提交（原因位 %d：1 没登记原语 / 2 卷不能克隆或原子交换 / 4 工作目录准备失败），提示玩家", bits);
    return bits;
}

// 画面没出来（接口与口径见 runtime/include/s2a_direct_prompt.h）
int s2a_no_picture_decide(double secs, unsigned long long fails, unsigned long long draws, unsigned long long presents) {
    return secs >= S2A_NOPIC_AFTER_S && presents > 0 && fails > 0 && draws == 0;
}
#if defined(__ANDROID__) || defined(__OHOS__)
int s2a_no_picture_poll_at(double now) { (void)now; return 0; }
int s2a_no_picture_poll(void) { return 0; }   // 横幅只在 iPhone 壳（ios/dprompt.m）；安卓的直连现编另有口径
#else
#include "s2a_gfx_mode.h"
#include "s2a_dguard.h"
#include <time.h>
int s2a_no_picture_poll_at(double now) {   // now：单调时钟秒（单测直接给）
    static int done, started; static double t0;
    if (done || s2a_host_session_state() != S2A_SESSION_RUNNING || !s2a_gfx_mode_settled() || s2a_gfx_mode() != S2A_GFX_DIRECT) return 0;
    if (!started) { started = 1; t0 = now; }   // 会话跑起来后第一次问：从这里算
    static void (*dsh)(unsigned long long *); static unsigned long long (*draws)(void), (*presents)(void); static int looked;
    if (!looked) { looked = 1; dsh = (void (*)(unsigned long long *))dlsym(RTLD_DEFAULT, "s2a_dsh_stats");
        draws = (unsigned long long (*)(void))dlsym(RTLD_DEFAULT, "s2a_direct_draws"); presents = (unsigned long long (*)(void))dlsym(RTLD_DEFAULT, "mtl_present_count"); }
    if (!dsh || !draws || !presents) return 0;   // 没链直连层（单测 / 别的前端）：不判
    unsigned long long st[5] = {0}; dsh(st);
    unsigned long long d = draws(), p = presents();
    if (!s2a_no_picture_decide(now - t0, st[1], d, p)) {
        if (d) done = 1;   // 画出过东西：这局不会再「画面没出来」，不再问
        return 0;
    }
    done = 1;
    LOG("【红】画面没出来：起局 %.0f 秒，直连现编成功 %llu、失败 %llu 支，上屏 %llu 次、一次绘制都没编码出去 → 提示玩家重新出包（计进直连安全网）", now - t0, st[0], st[1], p);
    s2a_dguard_evidence("画面没出来（直连现编全失败、起局后一次绘制都没画）", 0);
    return 1;
}
int s2a_no_picture_poll(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return s2a_no_picture_poll_at((double)ts.tv_sec + ts.tv_nsec / 1e9); }
#endif
