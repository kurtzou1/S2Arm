// 全进程线程调度档（QoS）一张表（11-06 Switch2 线 71，维护者令：各处散设的 QoS 收到这里，按角色取值）。
// 只在 Apple 上用（Android 不 include）。宿主（runtime/src）与图形层（graphics/nvn）共用：runtime/src 以 "s2a_qos.h"、graphics/nvn 以相对路径 "../../../../runtime/include/s2a_qos.h"（host_adapt.m "s2a_qos.h"）引。
//
// 为什么要统一：iPhone 只有 2 个性能核。系统按 QoS 和负载把线程排到性能核 / 能效核；低于 USER_INITIATED 的线程发热时基本只在能效核上跑，
//   能效核主频约为性能核一半、每周期指令也低。实测：
//   ① 时之笛 Duo 11-06（ns2_zelda/dev49_serial/out_1106181717）：提交线程是游戏主线程以外的线程（USER_INITIATED），取图线程的实时声明被内核撤掉后
//      进程 CPU 0% 在性能核、提交线程平均 1.49 GHz、提交 CPU 13.8 ms/帧 → 提交线程按角色提到 USER_INTERACTIVE（hle_nvn.c render_thread_qos）；
//   ② 卡顿线三臂实测：后台编管线线程 UTILITY → DEFAULT 同样活快约 4 倍（2 路 179.7 s → 45.6 s），加线程基本没用（UTILITY 被排到能效核）；
//      那处由卡顿线 perf/warm-bg-qos-default ca6a6bc99 在 nvn_mtl.m WARM_BG_QOS 落地，本表不重复设置。
//   ③ 2 个性能核的手机上不给提交线程做实时声明（11-12，同机整局对照 5 局，机器已热、系统在压 GPU 的状态）：声明后提交线程 100% 落在性能核，
//      进程 CPU 0.57–0.76 W、30–39 帧且逐窗口下降；不声明时它 1%–12% 在性能核，CPU 0.34–0.45 W、42–47 帧。手机稳态总功率是定的，
//      CPU 多花的功率由系统从 GPU 上扣回去。这类功率预算的效应要几十秒才显现，同一局里按帧交替开关量不出来（当初就是这样量出「有益」才加的），要整局对照。
// 取值原则：一帧关键路径上、别的线程会等它的 → USER_INTERACTIVE；首遇时绘制会等 / 会少画几笔的现编 → USER_INITIATED；
//   预取 / 预热这类「越早做完卡顿越少」的后台活 → DEFAULT（不放 UTILITY：能效核上慢约 4 倍）；纯 I/O、诊断、收尾 → UTILITY。
//
// 角色 → 应设 QoS → 依据（「现 QoS」与边界见报告 run/s2arm/cmdr/Switch2线_71_金刚提交线程.md）
#pragma once
#include <pthread.h>
#include <pthread/qos.h>
#include <dispatch/dispatch.h>

typedef enum {
    S2A_QOS_GAME_MAIN,         // 游戏主线程（runtime/src/thread.c）：USER_INTERACTIVE（S2A_GAME_MAIN_QOS 可改，能耗对照用）
    S2A_QOS_GAME_OTHER,        // 其余游戏线程：性能核 ≥ 4（Mac）USER_INTERACTIVE；< 4（iPhone）USER_INITIATED，排在渲染关键线程之后（S2A_GUEST_QOS 可改）。
                               //   其中提交 NVN 的那一个按 S2A_QOS_SUBMIT 另提
    S2A_QOS_GAME_SYSCORE,      // 核掩码只给 3 号核的游戏线程：性能核不足 4 个（或 S2A_SYSCORE_QOS=utility）时 UTILITY，性能核 ≥ 4 与其余游戏线程同档（见 thread.c syscore_utility）
    S2A_QOS_SUBMIT,            // NVN 提交线程（hle_nvn.c nvnQueueSubmitCommands）：USER_INTERACTIVE（依据 ①）
    S2A_QOS_ENCODE,            // Metal 编码线程 dm-encode（nvn_rec.h）：USER_INTERACTIVE，提交线程每次提交末尾等它
    S2A_QOS_UB_COPY,           // 统一缓冲影子拷贝线程 dm-ub-copy（nvn_rec.h）：USER_INTERACTIVE，提交前等它
    S2A_QOS_PRESENT,           // 上屏线程 nvn-present / 显示链接线程 nvn-present-link（nvn_mtl.m）：USER_INTERACTIVE（链接线程另有实时声明）
    S2A_QOS_MTL_FEEDBACK,      // Metal 4 命令队列完成回调队列（nvn_mtl.m）：USER_INTERACTIVE，GPU 完成计数推进、等 GPU 的线程靠它醒
    S2A_QOS_PREEMPT_WATCHDOG,  // 核抢占看门狗（runtime/src/thread.c）：USER_INTERACTIVE，0.5 ms 周期跑不准抢占延迟就飙
    S2A_QOS_SHADER_URGENT,     // 着色器紧急加载道 dm.nvn.sh-urg（前瞻：同一提交里后面的绘制要用）：USER_INITIATED，提交线程到时共享它的加载并借出自己的档
    S2A_QOS_SHADER_VARIANT,    // 首遇变体现编 dm.nvn.se / dm.nvn.vp / dm.nvn.mesh：USER_INITIATED，编好前那几笔跳过
    S2A_QOS_SHADER_PREFETCH,   // 着色器预取道 dm.nvn.sh-pre：DEFAULT（原 UTILITY；依据 ②，预取越早做完首遇现编越少）
    // （后台预热工人不在本表取值：唯一设置点是 nvn_mtl.m 的 WARM_BG_QOS（卡顿线 perf/warm-bg-qos-default ca6a6bc99，utility → default，转后台 / 配置全后台两支共用），
    //   以 main 上那个常量为准；这里不再设第二处）
    S2A_QOS_IO_BG,             // 管线归档写盘、映射释放、满屏判据截图、旧构建目录清理：UTILITY（纯 I/O / 诊断，不在帧路径）
    S2A_QOS_HOST_AUX,          // 宿主杂项：震动邮箱、收局 / 存档管理触发、诊断转储：USER_INITIATED（要按时到，不抢渲染）
    S2A_QOS_INPUT,             // Mac 手柄输入队列（macos/front_mac.m pad_input_queue：GameController 回调 → 快速路径发布 → 唤醒 HID 泵）：
                               //   USER_INTERACTIVE，输入关键路径（依据 ②：低档会被排到能效核上慢约 4 倍，主线程占满性能核时输入直达靠它）
    S2A_QOS_N
} s2a_qos_role;

static inline int s2a_qos_perf_cores(void);
static inline qos_class_t s2a_qos(s2a_qos_role r) {
    switch (r) {
    case S2A_QOS_GAME_MAIN: case S2A_QOS_SUBMIT: case S2A_QOS_ENCODE: case S2A_QOS_UB_COPY: case S2A_QOS_PRESENT:
    case S2A_QOS_MTL_FEEDBACK: case S2A_QOS_PREEMPT_WATCHDOG: case S2A_QOS_INPUT:
        return QOS_CLASS_USER_INTERACTIVE;
    case S2A_QOS_GAME_OTHER: return s2a_qos_perf_cores() >= 4 ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED;
    case S2A_QOS_SHADER_URGENT: case S2A_QOS_SHADER_VARIANT: case S2A_QOS_HOST_AUX:
        return QOS_CLASS_USER_INITIATED;
    case S2A_QOS_SHADER_PREFETCH:
        return QOS_CLASS_DEFAULT;
    case S2A_QOS_GAME_SYSCORE: case S2A_QOS_IO_BG:
        return QOS_CLASS_UTILITY;
    default: return QOS_CLASS_DEFAULT;
    }
}
// 性能核个数（hw.perflevel0.physicalcpu；读不到按 hw.physicalcpu，再读不到按 8）
#include <sys/sysctl.h>
static inline int s2a_qos_perf_cores(void) {
    static int n = -1; if (n >= 0) return n;
    int v = 0; size_t sz = sizeof v;
    if (sysctlbyname("hw.perflevel0.physicalcpu", &v, &sz, NULL, 0) || v <= 0) { sz = sizeof v; if (sysctlbyname("hw.physicalcpu", &v, &sz, NULL, 0) || v <= 0) v = 8; }
    return n = v;
}
static inline int s2a_qos_set_self(s2a_qos_role r) { return pthread_set_qos_class_self_np(s2a_qos(r), 0); }
static inline dispatch_queue_attr_t s2a_qos_queue_attr(dispatch_queue_attr_t base, s2a_qos_role r) { return dispatch_queue_attr_make_with_qos_class(base, s2a_qos(r), 0); }
static inline dispatch_queue_t s2a_qos_global(s2a_qos_role r) { return dispatch_get_global_queue(s2a_qos(r), 0); }
