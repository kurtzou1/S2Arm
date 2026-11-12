// 进程能耗分账（维护者 10-20 夜：整机 6 W 对旧包 3 W，先把账拆对再改）。s2a_energy_log() 每调一次打一行「上次调用以来」：
//   本进程 CPU：按性能核 / 能效核拆的瓦数、占用核数、平均频率（proc_pid_rusage v6：ri_energy_nj / ri_penergy_nj / 周期 / 时间）；
//   GPU：命令缓冲忙的时间（ms/s，直连层逐帧 GPU 起止累计，s2a_gpu_busy_ms）——是时间、不是能耗。10-30 起不再调资源联盟查询
//   （coalition_info_resource_usage 的 gpu_energy_nj 在 arm64 内核写死 0、iOS 沙盒又拒绝查询，真机永远「取不到」；iOS 功耗测量口径修法 5）；
//   耗能最多的 6 条线程（proc_pidinfo PROC_PIDTHREADCOUNTS：按核类型的周期 / 时间 / 能耗）。
// 整机瓦数（电池遥测）减去 CPU 瓦数 = GPU + 屏幕 + 内存 + 其余（GPU 只有时间、没有瓦数）。线程计数结构照 xnu 公开源码（bsd/sys/proc_info_private.h），内核按长度截断拷出。
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include "native.h"

int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
__attribute__((weak)) double s2a_gpu_busy_ms(void) { return -1; }
__attribute__((weak)) double s2a_gpu_clock_ms(void) { return -1; }   // 同上：已入账各帧最晚 GPU 结束（毫秒）   // 直连层（graphics/nvn hle_nvn.c）的强定义：GPU 忙累计毫秒；没有直连层（通用局 / 单测）→ −1
struct s2a_tc_data { uint64_t instructions, cycles, user_mach, system_mach, energy_nj; };
struct s2a_tc { uint16_t len, r0; uint32_t r1; struct s2a_tc_data d[4]; };
#define S2A_PIDTHREADCOUNTS 34

static double g_tb;   // mach 时间单位 → 纳秒
static const int g_plevel = 0;   // 性能核 = 第 0 档（xnu：0 档恒为最快的核，rusage 的 *p* 字段也按 0 档计；名字因芯片而异：iPhone「Performance」，M5 Max「Super」）
static char g_lvnames[64];


static void init_once(void) {
    if (g_tb) return;
    mach_timebase_info_data_t t; mach_timebase_info(&t); g_tb = (double)t.numer / t.denom;
    int n = 0; size_t sz = sizeof n; sysctlbyname("hw.nperflevels", &n, &sz, NULL, 0);
    for (int i = 0; i < n && i < 4; i++) { char k[32], v[24] = {0}; snprintf(k, sizeof k, "hw.perflevel%d.name", i); sz = sizeof v - 1;
        if (sysctlbyname(k, v, &sz, NULL, 0) == 0) snprintf(g_lvnames + strlen(g_lvnames), sizeof g_lvnames - strlen(g_lvnames), "%s%d=%s", i ? " " : "", i, v); }
}

// 本进程累计写盘字节（rusage v6 ri_diskio_byteswritten）：客体内存文件后备的闪存写回量（11-05，心跳「[写盘]」行）。0 = 成功
int s2a_disk_written(uint64_t *bytes) {
    struct rusage_info_v6 ri; if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) return -1;
    *bytes = ri.ri_diskio_byteswritten; return 0;
}
int s2a_energy_snap(s2a_esnap *s) {
    init_once(); memset(s, 0, sizeof *s);
    s->wall = (uint64_t)(mach_absolute_time() * g_tb);
    struct rusage_info_v6 ri; if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) return -1;
    s->cpu = (uint64_t)((ri.ri_user_time + ri.ri_system_time) * g_tb); s->pcpu = (uint64_t)((ri.ri_user_ptime + ri.ri_system_ptime) * g_tb);
    s->nj = ri.ri_energy_nj; s->pnj = ri.ri_penergy_nj; s->cyc = ri.ri_cycles; s->pcyc = ri.ri_pcycles;
    s->intr = ri.ri_interrupt_wkups; s->idle = ri.ri_pkg_idle_wkups;
    double g = s2a_gpu_busy_ms(); if (g >= 0) { s->ok_g = 1; s->gpu_ms = g; s->gpu_clk_ms = s2a_gpu_clock_ms(); }
    return 0;
}
double s2a_gpu_busy_rate(const s2a_esnap *a, const s2a_esnap *b) {
    if (!a->ok_g || !b->ok_g || a->gpu_clk_ms < 0 || b->gpu_clk_ms < 0) return -1;
    double dc = b->gpu_clk_ms - a->gpu_clk_ms;
    return dc > 0 ? (b->gpu_ms - a->gpu_ms) * 1000.0 / dc : 0;
}

// 线程：按线程号记上次的能耗与性能核时间（开放寻址，进程里线程 < 300）。每次采样只留这一次还活着的线程（审计 P1-85：原先只增不删，
//   进程内重启每局新建一批线程号，累计满 1024 格后找空位的 while 没有步数上限，主线程心跳在这里转死）；探测最多 TN 步，满了这条线程这一窗不记
#define TN 1024
typedef struct { uint64_t tid, nj, pt, t; } s2a_thslot;
static s2a_thslot g_th[TN], g_th_next[TN];
static int th_slot(s2a_thslot *tab, uint64_t tid) {
    unsigned h = (unsigned)(tid * 2654435761u) % TN;
    for (int k = 0; k < TN; k++, h = (h + 1) % TN) if (!tab[h].tid || tab[h].tid == tid) return (int)h;
    return -1;
}
typedef struct { uint64_t tid, dnj, dpt, dt; char name[32]; } s2a_tdelta;
static int thread_deltas(s2a_tdelta *top, int ntop) {
    thread_act_array_t ths; mach_msg_type_number_t n; int got = 0;
    if (task_threads(mach_task_self(), &ths, &n) != KERN_SUCCESS) return 0;
    memset(g_th_next, 0, sizeof g_th_next);
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_identifier_info_data_t id; mach_msg_type_number_t c = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(ths[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&id, &c) == KERN_SUCCESS) {
            struct s2a_tc tc; memset(&tc, 0, sizeof tc);
            if (proc_pidinfo(getpid(), S2A_PIDTHREADCOUNTS, id.thread_id, &tc, sizeof tc) > 0) {
                uint64_t nj = 0, t = 0, pt = 0;
                for (int k = 0; k < tc.len && k < 4; k++) { uint64_t tk = (uint64_t)((tc.d[k].user_mach + tc.d[k].system_mach) * g_tb); nj += tc.d[k].energy_nj; t += tk; if (k == g_plevel) pt = tk; }
                int h = th_slot(g_th, id.thread_id), w = th_slot(g_th_next, id.thread_id);
                if (w < 0) goto next;   // 活着的线程超过 TN：这一窗不记它
                int seen = h >= 0 && g_th[h].tid;
                s2a_tdelta d = { id.thread_id, seen ? nj - g_th[h].nj : 0, seen ? pt - g_th[h].pt : 0, seen ? t - g_th[h].t : 0, "" };
                g_th_next[w] = (s2a_thslot){ id.thread_id, nj, pt, t };
                pthread_t p = pthread_from_mach_thread_np(ths[i]); if (!p || pthread_getname_np(p, d.name, sizeof d.name) != 0 || !d.name[0]) snprintf(d.name, sizeof d.name, "#%llu", (unsigned long long)id.thread_id);
                // 插入排序进前 ntop（按能耗降序）；表满时比不过末位就不进（表没满时末位还没写，不能拿来比）
                int full = got == ntop, j = full ? ntop - 1 : got++;
                if (full && d.dnj <= top[j].dnj) goto next;
                while (j > 0 && top[j - 1].dnj < d.dnj) { top[j] = top[j - 1]; j--; }
                top[j] = d;
            }
        }
    next:
        mach_port_deallocate(mach_task_self(), ths[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)ths, n * sizeof(thread_t));
    memcpy(g_th, g_th_next, sizeof g_th);   // 换成这一次的活线程表：退出的线程号不再占格
    return got;
}

// 游戏线程满核空转现场（10-24 #164 iPad 动森开场视频：游戏线程 nx-172 整段视频 0.98 核、GPU 与解码都闲着，日志里看不出它在干什么）。
// 每 10 秒的耗能采样里，名字是 nx-* 的游戏线程连续 ≥ S2A_SPIN_DUMP_S 秒（缺省 60，0 = 关）占 ≥ 0.95 核 → 打一次游戏线程表 + 宿主线程栈
// （pc / 回溯按「模块+偏移」，空转在哪段代码、等的是什么一眼可见）。每条线程只打一次、每局至多 3 次；没满核的那一窗清零重计
// 现场只在显式给了 S2A_SPIN_DUMP_S 的诊断局抓：抓宿主栈要暂停全部线程打完一千多行，那一帧卡 100+ ms（10-26 帧率能耗线：哈迪斯主循环 nx-81
//   本就满核，15 局里 11 局 MARK 后第 4137–4147 帧卡 112–186 ms，正是这里）。缺省只打一行；帧数停住的现场归出图停住看门（ap_host.c S2A_STALL_DUMP_S）
enum { SPIN_SLOTS = 16, SPIN_MAX = 3 };
static struct { uint64_t tid; double hot; int dumped; } g_sp[SPIN_SLOTS]; static int g_sp_dumps;
static int spin_s(void) { static int v = -1; if (v < 0) { const char *e = getenv("S2A_SPIN_DUMP_S"); v = e && *e ? atoi(e) : 60; } return v; }
static int spin_full(void) { const char *e = getenv("S2A_SPIN_DUMP_S"); return e && *e; }
// 纯判定（单测直接调）：本窗 n 条线程（tid / 名字 / 占用核数），窗长 sec 秒，阈值 lim 秒；该打现场时返回下标、否则 -1
int s2a_spin_step(const uint64_t *tid, const char *const *name, const double *cores, int n, double sec, int lim) {
    int hit = -1;
    for (int k = 0; k < SPIN_SLOTS; k++) { int hot = 0;   // 这一窗没满核的清零（不在本窗名单里的也算没满核）
        for (int i = 0; i < n; i++) if (g_sp[k].tid && g_sp[k].tid == tid[i] && cores[i] >= 0.95) hot = 1;
        if (!hot) g_sp[k].hot = 0; }
    for (int i = 0; i < n; i++) {
        if (strncmp(name[i], "nx-", 3) || cores[i] < 0.95) continue;
        int k = 0, free_ = -1; for (; k < SPIN_SLOTS && g_sp[k].tid != tid[i]; k++) if (!g_sp[k].tid && free_ < 0) free_ = k;
        if (k == SPIN_SLOTS) { if (free_ < 0) continue; k = free_; g_sp[k].tid = tid[i]; g_sp[k].hot = 0; g_sp[k].dumped = 0; }
        g_sp[k].hot += sec;
        if (hit < 0 && lim > 0 && g_sp[k].hot >= lim && !g_sp[k].dumped && g_sp_dumps < SPIN_MAX) { g_sp[k].dumped = 1; g_sp_dumps++; hit = i; }
    }
    return hit;
}
void s2a_spin_test_reset(void) { memset(g_sp, 0, sizeof g_sp); g_sp_dumps = 0; }

static s2a_esnap g_last; static int g_have;
// 「上次调用以来」一行写进 out；第一次调用只记起点（写起点说明，返回 0），之后返回 1
int s2a_energy_capture(char *out, size_t n) {
    s2a_esnap s; if (s2a_energy_snap(&s) != 0) { snprintf(out, n, "【红】proc_pid_rusage v6 取不到"); return 0; }
    s2a_tdelta top[6]; int nt = thread_deltas(top, 6);
    if (!g_have) { g_last = s; g_have = 1; snprintf(out, n, "起点：核档 %s（性能核按 0 档计）；GPU 记命令缓冲忙的时间（ms/s，非能耗）%s", g_lvnames, s.ok_g ? "" : "，本局没有直连层、读不到"); return 0; }
    double dt = (double)(s.wall - g_last.wall); if (dt <= 0) { snprintf(out, n, "间隔为 0"); return 0; }
    double cpu = (double)(s.cpu - g_last.cpu), pcpu = (double)(s.pcpu - g_last.pcpu), ecpu = cpu - pcpu;
    double pnj = (double)(s.pnj - g_last.pnj), enj = (double)(s.nj - g_last.nj) - pnj;
    double pcyc = (double)(s.pcyc - g_last.pcyc), ecyc = (double)(s.cyc - g_last.cyc) - pcyc;
    if (ecpu < 0) ecpu = 0; if (enj < 0) enj = 0; if (ecyc < 0) ecyc = 0;   // 两个累计量相减的舍入
    char tl[512] = "", gl[96] = "读不到"; size_t o = 0;
    for (int i = 0; i < nt && o < sizeof tl - 64; i++)
        o += (size_t)snprintf(tl + o, sizeof tl - o, "%s%s %.2f W（%.2f 核，性能核 %.0f%%）", i ? "、" : "", top[i].name, top[i].dnj / dt, top[i].dt / dt, top[i].dt ? 100.0 * top[i].dpt / top[i].dt : 0.0);
    double gr = s2a_gpu_busy_rate(&g_last, &s); if (gr >= 0) snprintf(gl, sizeof gl, "忙 %.1f ms/s（时间，非能耗）", gr);
    snprintf(out, n, "近 %.1f 秒：CPU %.2f W（性能核 %.2f W / 能效核 %.2f W；性能核 %.2f 核 @%.2f GHz、能效核 %.2f 核 @%.2f GHz）；GPU %s；唤醒 中断 %.0f/秒、空闲 %.0f/秒；耗能前 %d 线程：%s",
        dt / 1e9, (pnj + enj) / dt, pnj / dt, enj / dt, pcpu / dt, pcpu ? pcyc / pcpu : 0.0, ecpu / dt, ecpu ? ecyc / ecpu : 0.0, gl,
        (double)(s.intr - g_last.intr) * 1e9 / dt, (double)(s.idle - g_last.idle) * 1e9 / dt, nt, tl);
    g_last = s;
    if (spin_s() > 0) {
        uint64_t tid[6]; const char *nm[6]; double co[6]; for (int i = 0; i < nt; i++) { tid[i] = top[i].tid; nm[i] = top[i].name; co[i] = top[i].dt / dt; }
        int h = s2a_spin_step(tid, nm, co, nt, dt / 1e9, spin_s());
        if (h >= 0 && !spin_full())
            LOG("游戏线程满核空转：%s（线程号 %llu）连续 ≥ %d 秒占 %.2f 核（第 %d 次，每局至多 %d 次；只打这一行，现场要显式给 S2A_SPIN_DUMP_S=<秒>）",
                top[h].name, (unsigned long long)top[h].tid, spin_s(), co[h], g_sp_dumps, SPIN_MAX);
        else if (h >= 0) {
            void (*td)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "s2a_thread_dump");          // thread.c：游戏线程表（等什么、等了多久）
            int (*hd)(const char *) = (int (*)(const char *))dlsym(RTLD_DEFAULT, "s2a_dump_threads");   // tdump.c：宿主线程栈（游戏线程的 pc 落在游戏模块）
            LOG("游戏线程满核空转：%s（线程号 %llu）连续 ≥ %d 秒占 %.2f 核（第 %d 次，每局至多 %d 次；S2A_SPIN_DUMP_S=0 关），游戏线程表 + 宿主线程栈：",
                top[h].name, (unsigned long long)top[h].tid, spin_s(), co[h], g_sp_dumps, SPIN_MAX);
            if (td) td();
            if (hd) { char w[96]; snprintf(w, sizeof w, "游戏线程满核空转：%s 占 %.2f 核", top[h].name, co[h]); hd(w); }
        }
    }
    return 1;
}
void s2a_energy_log(void) { char b[2048]; s2a_energy_capture(b, sizeof b); LOG("[能耗] %s", b); }
