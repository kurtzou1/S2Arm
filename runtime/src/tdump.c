// 全线程现场（卡死 / 崩溃时）：本进程每条宿主线程的名字、优先级、QoS、运行状态、pc / lr、帧指针回溯，地址按「模块+偏移」或宿主符号写。
// 先挂起别的线程再取状态、读栈（读栈走 vm_read_overwrite，坏指针不会再崩），取完放行。写进 host.log，同时写 <文档目录>/threads.txt
// （iOS = Documents；Mac = S2A_DOCS，没给就只写 host.log），执行器收局拉回。调用方：crash.c 崩溃处理、渲染器卡死判定（_exit 86 之前）。
#include "native.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <pthread/qos.h>

#define VA(x) ((x) & 0x0000007fffffffffull)                  // 去掉返回地址高位的指针认证位（用户空间地址 ≤ 39 位）

static int g_fd = -1;
static void out(const char *fmt, ...) {
    char b[512]; va_list ap; va_start(ap, fmt); int n = vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    if (n < 0) return; if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    s2a_log_line("[现场] %s", b);
    if (g_fd >= 0) { b[n] = '\n'; write(g_fd, b, (size_t)n + 1); }
}
static void where(uint64_t a, char *b, size_t n) {
    if (s2a_guest_where(a, b, n)) return;   // 装载器（loader.c）：游戏模块，带导出名（#806）
    Dl_info di;
    if (dladdr((void *)a, &di) && di.dli_sname) { snprintf(b, n, "%s+%#llx（%s）", di.dli_sname, (unsigned long long)(a - (uint64_t)di.dli_saddr), di.dli_fname ? strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname : "?"); return; }
    snprintf(b, n, "%#llx", (unsigned long long)a);
}
static int rd(uint64_t a, uint64_t *v) {   // 安全读 8 字节：坏地址返回 0
    vm_size_t got = 0;
    return !(a & 7) && vm_read_overwrite(mach_task_self(), (vm_address_t)a, 8, (vm_address_t)v, &got) == KERN_SUCCESS && got == 8;
}
static void walk(uint64_t pc, uint64_t lr, uint64_t fp) {
    char b[256];
    where(VA(pc), b, sizeof b); out("    pc %s", b);
    where(VA(lr), b, sizeof b); out("    lr %s", b);
    for (int i = 0; i < 48 && fp; i++) {
        uint64_t nfp, ret;
        if (!rd(fp, &nfp) || !rd(fp + 8, &ret) || !VA(ret)) break;
        where(VA(ret), b, sizeof b); out("    #%d %s", i, b);
        if (nfp <= fp) break;
        fp = nfp;
    }
}
// 取证（collect / 打印段）：每线程全寄存器 x0–x28；落在游戏模块的寄存器标「模块+偏移」归属并带它指向的两个字
//   （崩溃调试用：查表帧 callee-saved 寄存器指向表指针页之类，事后从这些推表 / 桶，不写死游戏偏移）
static const char *qos_name(int q) {
    switch (q) { case QOS_CLASS_USER_INTERACTIVE: return "UI"; case QOS_CLASS_USER_INITIATED: return "USER_INITIATED"; case QOS_CLASS_UTILITY: return "UTILITY";
        case QOS_CLASS_BACKGROUND: return "BACKGROUND"; case QOS_CLASS_DEFAULT: return "DEFAULT"; default: return "未定"; }
}
static const char *run_name(int s) {
    switch (s) { case TH_STATE_RUNNING: return "在跑"; case TH_STATE_STOPPED: return "停"; case TH_STATE_WAITING: return "等待"; case TH_STATE_UNINTERRUPTIBLE: return "不可中断等待"; case TH_STATE_HALTED: return "终止"; default: return "?"; }
}

// 挂起期间只做内核调用（thread_info / thread_get_state / vm_read_overwrite），结果放进预先分配好的静态表；全部放行之后才符号化、写日志。
//   原先挂起后边取边打：dladdr 要 dyld 锁、pthread_from_mach_thread_np / pthread_get_qos_class_np 要 pthread 内部锁、日志控制台要它的锁，
//   被挂起的线程正好持着其中一把就把发起现场的线程卡死（11-14：停帧看门打到一半断、后续现场全没出）
enum { TD_MAX = 512, TD_FR = 48 };
typedef struct {
    thread_t th; int self, have, unint, regs; uint64_t tid; int run, pri; double ut; char name[64];
    arm_thread_state64_t st; uint64_t fr[TD_FR]; int nfr; uint64_t rw[29][2];
} td_ent;
static td_ent g_td[TD_MAX];
static void collect(td_ent *e) {   // 线程已挂起：只许内核调用
    thread_extended_info_data_t ei; mach_msg_type_number_t c = THREAD_EXTENDED_INFO_COUNT;
    e->have = thread_info(e->th, THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c) == KERN_SUCCESS;
    if (e->have) { e->run = ei.pth_run_state; e->pri = ei.pth_curpri; e->ut = ei.pth_user_time / 1e9; memcpy(e->name, ei.pth_name, sizeof e->name); e->name[sizeof e->name - 1] = 0; }
    thread_identifier_info_data_t ii; c = THREAD_IDENTIFIER_INFO_COUNT;
    e->tid = thread_info(e->th, THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c) == KERN_SUCCESS ? ii.thread_id : 0;
    if (e->self) return;
    // 内核里不可中断等待的线程不取寄存器：thread_get_state 要等它走到可停的点，出不来就把本线程一起卡死（同 thread.c s2a_thread_dump）
    if (e->have && e->run == TH_STATE_UNINTERRUPTIBLE) { e->unint = 1; return; }
    mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(e->th, ARM_THREAD_STATE64, (thread_state_t)&e->st, &sc) != KERN_SUCCESS) return;
    e->regs = 1;
    uint64_t fp = arm_thread_state64_get_fp(e->st);
    for (e->nfr = 0; e->nfr < TD_FR && fp; e->nfr++) {
        uint64_t nfp, ret;
        if (!rd(fp, &nfp) || !rd(fp + 8, &ret) || !VA(ret)) break;
        e->fr[e->nfr] = VA(ret);
        if (nfp <= fp) { e->nfr++; break; }
        fp = nfp;
    }
    for (int i = 0; i < 29; i++) { uint64_t v = VA(e->st.__x[i]); if (v >= 0x100000000ull) { rd(v, &e->rw[i][0]); rd(v + 8, &e->rw[i][1]); } }
}
int s2a_dump_threads(const char *why) {
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    char path[1100] = "";
    const char *docs = getenv("S2A_DOCS");   // Mac 没给 S2A_DOCS 就不落文件（不碰用户文稿夹）；iOS 按文档根
    if (TARGET_OS_IPHONE || (docs && *docs)) { s2a_docs_path(path, sizeof path, "threads.txt"); g_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644); }
    thread_act_array_t th; mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) { out("取线程表失败"); n = 0; }
    thread_t self = mach_thread_self();
    out("===== 全线程现场：%s（%u 条线程%s%s）=====", why, n, path[0] ? "，另写 " : "", path);
    mach_msg_type_number_t m = n < TD_MAX ? n : TD_MAX;
    memset(g_td, 0, sizeof g_td);
    for (mach_msg_type_number_t i = 0; i < m; i++) { g_td[i].th = th[i]; g_td[i].self = th[i] == self; }
    for (mach_msg_type_number_t i = 0; i < m; i++) if (!g_td[i].self) thread_suspend(th[i]);
    for (mach_msg_type_number_t i = 0; i < m; i++) collect(&g_td[i]);
    for (mach_msg_type_number_t i = 0; i < m; i++) if (!g_td[i].self) thread_resume(th[i]);
    // 以下全部线程已放行：符号化（dladdr）、取 QoS（pthread）、写日志都安全
    if (n > m) out("线程 %u 条，只记前 %u 条", n, m);
    for (mach_msg_type_number_t i = 0; i < m; i++) {
        td_ent *e = &g_td[i];
        pthread_t pt = pthread_from_mach_thread_np(e->th); qos_class_t qc_ = QOS_CLASS_UNSPECIFIED; int rel = 0;
        if (pt) pthread_get_qos_class_np(pt, &qc_, &rel);
        out("线程 %u/%u tid %llu「%s」%s 优先级 %d QoS %s 用户态 %.2f s%s", i + 1, n, (unsigned long long)e->tid, e->have && e->name[0] ? e->name : "无名",
            e->have ? run_name(e->run) : "?", e->have ? e->pri : -1, qos_name((int)qc_), e->have ? e->ut : 0.0, e->self ? "（本线程，发起现场）" : "");
        if (e->self) { walk((uint64_t)__builtin_return_address(0), 0, (uint64_t)__builtin_frame_address(0)); continue; }
        if (e->unint) { out("    在内核里不可中断等待，不取寄存器（取了会卡住本线程）"); continue; }
        if (!e->regs) { out("    取寄存器失败"); continue; }
        char b[256];
        where(VA(arm_thread_state64_get_pc(e->st)), b, sizeof b); out("    pc %s", b);
        where(VA(arm_thread_state64_get_lr(e->st)), b, sizeof b); out("    lr %s", b);
        for (int k = 0; k < e->nfr; k++) { where(e->fr[k], b, sizeof b); out("    #%d %s", k, b); }
        const arm_thread_state64_t *st = &e->st;
        for (int r = 0; r < 29; r += 4)
            out("    x%-2d %016llx %016llx %016llx %016llx", r, (unsigned long long)st->__x[r], r + 1 < 29 ? (unsigned long long)st->__x[r + 1] : 0ull,
                r + 2 < 29 ? (unsigned long long)st->__x[r + 2] : 0ull, r + 3 < 29 ? (unsigned long long)st->__x[r + 3] : 0ull);
        for (int r = 0; r < 29; r++) {
            uint64_t v = VA(st->__x[r]);
            if (v < 0x100000000ull || !module_of((void *)v)) continue;
            where(v, b, sizeof b);
            out("    x%-2d → %s  [%016llx %016llx]", r, b, (unsigned long long)e->rw[r][0], (unsigned long long)e->rw[r][1]);
        }
    }
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), th[i]);
    if (n) vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th);
    mach_port_deallocate(mach_task_self(), self);
    out("===== 现场完 =====");
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    pthread_mutex_unlock(&mu);
    return (int)n;
}
