// 起局分段计时：每段打一行「[起局] <段> +<距起点 ms>（本段 <ms>）」。起点 = 内核创建本进程的时刻（sysctl kern.proc.pid 的 p_starttime；多款容器点 Play 后改为点 Play 那刻，见 s2a_boot_rebase），
// 含 dyld 装可执行文件与各库的时间。原生层自己的段在 host_main / vawin / ap_host 里打，C# 侧（运行时起来、服务登记）调导出的 s2a_boot_mark 打。
#if defined(__ANDROID__) || defined(__OHOS__)
#include "../../android/native/runtime/platform/boot_android.inc"
#else
#include "native.h"
#include <sys/sysctl.h>
#include <sys/time.h>
#include <stdatomic.h>
static uint64_t wall_us(void) { struct timeval t; gettimeofday(&t, NULL); return (uint64_t)t.tv_sec * 1000000 + (uint64_t)t.tv_usec; }
static _Atomic uint64_t g_origin;   // 计时起点改到别处时的时刻（s2a_boot_rebase）；0 = 进程创建
static uint64_t start_us(void) {
    static uint64_t s;
    uint64_t o = atomic_load(&g_origin); if (o) return o;
    if (!s) { struct kinfo_proc kp; size_t n = sizeof kp; int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
        s = (!sysctl(mib, 4, &kp, &n, NULL, 0) && n) ? (uint64_t)kp.kp_proc.p_starttime.tv_sec * 1000000 + (uint64_t)kp.kp_proc.p_starttime.tv_usec : wall_us(); }
    return s;
}
static _Atomic uint64_t g_last;
void s2a_boot_mark(const char *stage) {
    uint64_t t = wall_us(), s = start_us(), last = atomic_exchange(&g_last, t);
    if (!last) last = s;
    s2a_log_line("[起局] %s +%.1f ms（本段 %.1f ms）", stage, (t - s) / 1000.0, (t - last) / 1000.0);
}
// 计时起点改为此刻（11-07 启动器线：多款容器停在游戏库等玩家点 Play，库界面停留不算起局）：之后各段「+」从这里算，本段也从这里重新起。
//   只调一次（app.m library_play，s2a_launch_ctx_select 冻结之后）；单款包不调，照旧从进程创建算
void s2a_boot_rebase(const char *why);   // 声明不进 native.h（抽取阶段键，改它冷全库）：调用方 ios/app.m 本地声明
void s2a_boot_rebase(const char *why) {
    uint64_t t = wall_us(), s = start_us();
    atomic_store(&g_origin, t); atomic_store(&g_last, t);
    s2a_log_line("[起局] 计时起点改为%s（距进程创建 %.1f ms 不计入起局）", why, (t - s) / 1000.0);
}
#endif
