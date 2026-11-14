// 门：改写器把每处 svc #n / mrs cntpct / mrs cntvct 换成「bl 到 sw_gate」（entry.S），这里按门块返回点查回它原来是什么，再分流：
// 线程 / 同步 → thread.c；内存 / 信息 / 计时 / 调试 → svc_mem.c；其余全部 → C# 单一入口（docs/接口_原生层.md §2、§3）。
// C# 没接或回「没处理」= 报红（记调用号与次数，回 0xF201，不回 0）。
#include "native.h"
#include <stdatomic.h>
#include <dlfcn.h>
#ifdef __ANDROID__
#include "../../android/native/runtime/vm/writers.h"
#endif
#include <pthread.h>
#include <stdlib.h>
// 弱缺省定义：真定义在 crash.c（同一个程序里强定义盖过它）；只链 gate.c 的单测没有 crash.c，用这份返回 0
__attribute__((weak)) uint64_t s2a_sp_unaligned_count(void) { return 0; }

enum { G_SVC, G_CNTPCT, G_CNTVCT, G_WIDE, G_SPIN, G_AREGION };
typedef struct { uint64_t ret; int kind, arg; uint64_t orig; } gate_t;
// 门表：开放寻址哈希，装载因子 ≤ 1/4；门数按游戏实际多少来（10-26 普查 3 款门数过 2048：原先定长 8192 槽、超了就 FATAL「门太多」，
//   这是我方表的大小，不是 Switch 的限制）。满 1/4 就换一张两倍大的表：新表填好再原子换上，查表只读一次表指针；
//   旧表不释放（运行中 nn::ro 装 NRO 也会登记门，别的线程可能正在查旧表），几何增长，留下的旧表合计不超过最终表大小。登记由锁串行
typedef struct gtab { struct gtab *older; unsigned bits; gate_t e[]; } gtab_t;
static _Atomic(gtab_t *) g_tab;
static int g_ngate;
static pthread_mutex_t g_reg_mu = PTHREAD_MUTEX_INITIALIZER;
static inline unsigned gate_h(uint64_t a, unsigned bits) { return (unsigned)(((a >> 2) * 0x9E3779B97F4A7C15ull) >> (64 - bits)); }
static gtab_t *gtab_new(unsigned bits) {
    gtab_t *t = calloc(1, sizeof(gtab_t) + sizeof(gate_t) * ((size_t)1 << bits));
    if (!t) return NULL;
    t->bits = bits; return t;
}
static int gtab_put(gtab_t *t, gate_t g) {
    unsigned m = (1u << t->bits) - 1, i = gate_h(g.ret, t->bits);
    while (t->e[i].ret) { if (t->e[i].ret == g.ret) return -1; i = (i + 1) & m; }
    t->e[i] = g;
    return 0;
}

void gate_register(uint64_t ret_abs, const char *kind, int arg, uint64_t orig) {
    int k = !strcmp(kind, "svc") ? G_SVC : !strcmp(kind, "cntpct") ? G_CNTPCT : !strcmp(kind, "cntvct") ? G_CNTVCT : !strcmp(kind, "wide") ? G_WIDE : !strcmp(kind, "spin") ? G_SPIN : !strcmp(kind, "aregion") ? G_AREGION : -1;
    if (k < 0) die("不认识的门类 %s（改写器与原生层版本不符）", kind);
    pthread_mutex_lock(&g_reg_mu);
    gtab_t *t = atomic_load_explicit(&g_tab, memory_order_relaxed);
    if (!t) {
        t = gtab_new(13);   // 8192 槽起步（原定长表的大小）
        if (!t) { pthread_mutex_unlock(&g_reg_mu); die("门表分配失败（13 位）"); }
    }
    if ((size_t)(g_ngate + 1) > ((size_t)1 << t->bits) / 4) {
        gtab_t *n = gtab_new(t->bits + 1);
        if (!n) { unsigned bits = t->bits + 1; pthread_mutex_unlock(&g_reg_mu); die("门表分配失败（%u 位）", bits); }
        // Existing table entries are unique; only the incoming entry can
        // duplicate a key. Preserve the published table on that error.
        for (size_t j = 0; j < ((size_t)1 << t->bits); j++) if (t->e[j].ret) gtab_put(n, t->e[j]);
        n->older = t; t = n;
    }
    if (gtab_put(t, (gate_t){ret_abs, k, arg, orig})) {
        if (t != atomic_load_explicit(&g_tab, memory_order_relaxed)) free(t);
        pthread_mutex_unlock(&g_reg_mu);
        die("门重复登记 %#llx", (unsigned long long)ret_abs);
    }
    g_ngate++;
    atomic_store_explicit(&g_tab, t, memory_order_release);
    pthread_mutex_unlock(&g_reg_mu);
}
int s2a_gate_count(void) { return g_ngate; }
unsigned s2a_gate_bits(void) { gtab_t *t = atomic_load_explicit(&g_tab, memory_order_acquire); return t ? t->bits : 0; }

// ---------- C# 单一入口 ----------
static s2a_cs_api g_cs;   // 登记前全 0
int s2a_register_cs(const s2a_cs_api *api) {
    if (!api || api->size != sizeof(s2a_cs_api)) { LOG("【红】s2a_register_cs：结构大小 %u ≠ %zu（两边头文件版本不符）", api ? api->size : 0, sizeof(s2a_cs_api)); return -1; }
    g_cs = *api; LOG("C# 入口已登记"); return 0;
}
void s2a_cs_handle_closed(uint32_t kind, uint64_t cookie) { if (g_cs.handle_closed) g_cs.handle_closed(kind, cookie); }
void s2a_cs_thread_exit(uint32_t thread) { if (g_cs.thread_exit) g_cs.thread_exit(thread); }
void s2a_cs_shutdown(const char *why) { if (g_cs.shutdown) g_cs.shutdown(why); }

// ---------- 已实现的系统调用集合（10-24 盘点：Ryujinx 实现的 72 个去掉 14 个系统进程级——应用 NPDM 许可不到）----------
// 原生层（thread.c / svc_mem.c）与 C#（0x1F / 0x21 / 0x22）合起来的集合；改分派时同步改这里（运行时报「未实现」却在表里会报红提示表与分派不一致）
// 第三个字是 Switch 2 新号（0x80 起，switchbrew SVC [S2]）：0x80 SetGpuMemoryAttribute（svc_mem.c）
static const uint64_t k_svc_impl[3] = {0x00ff32fefffffffeull, 0x6000800080061820ull, 0x1ull};
int s2a_svc_implemented(int num) { return num >= 0 && num < 0xC0 && (k_svc_impl[num >> 6] >> (num & 63) & 1); }
// NPDM ACI0 许可了、我们却没实现的号：起局报红一行（不等游戏真调到，对以后的新游戏同样成立）。perm = 许可位（0–0xBF，每 64 号一个字）；返回个数
// 真值也没有的号（Ryujinx 同样没实现：0x20 SendSyncRequestLight、0x28 ReturnFromException、0x2F GetLastThreadInfo；十款 NPDM 都许可、历史局从没调到）：
//   不算进返回值，另由 s2a_svc_check_perm_known 列出——否则每局都红，红就没意义了
int s2a_svc_ryu_missing(int num) { return num == 0x20 || num == 0x28 || num == 0x2f; }
int s2a_svc_check_perm(const uint64_t perm[3], char *out, size_t cap) {
    int n = 0; size_t k = 0; if (cap) out[0] = 0;
    for (int i = 0; i < 0xC0; i++) if ((perm[i >> 6] >> (i & 63) & 1) && !s2a_svc_implemented(i) && !s2a_svc_ryu_missing(i)) {
        n++; if (cap && k < cap) k += (size_t)snprintf(out + k, cap - k, "%s%#x", n > 1 ? " " : "", i); }
    return n;
}

// ---------- 报红：未实现的系统调用 ----------
static _Atomic uint64_t g_red[256];
static int strict(void) { static int s = -1; if (s < 0) { const char *e = getenv("S2A_STRICT"); s = e && *e == '1'; } return s; }
void s2a_svc_red(int num, const uint64_t *regs, uint64_t orig, const char *why) {
    uint64_t n = atomic_fetch_add(&g_red[num & 0xff], 1) + 1;
    if (n & (n - 1)) return;   // 首次与第 2^k 次打
    module_t *m = module_of((void *)orig);
    if (n == 1 && s2a_svc_implemented(num)) LOG("【红】系统调用 %#x 在「已实现」表里却报未实现：表与分派不一致（gate.c k_svc_impl）", num);
    LOG("【红】未实现：系统调用/%#x（%s，第 %llu 次）x0=%#llx x1=%#llx x2=%#llx x3=%#llx 位于 %s+%#llx", num, why, (unsigned long long)n,
        (unsigned long long)regs[0], (unsigned long long)regs[1], (unsigned long long)regs[2], (unsigned long long)regs[3], m ? m->name : "?", (unsigned long long)(m ? orig - (uint64_t)m->base : orig));
    if (strict()) { s2a_backtrace(regs[29]); die("S2A_STRICT：系统调用 %#x 未实现", num); }
}
void s2a_svc_red_summary(void) {   // 退出时一行，健康表读：空 = 报红 0
    char b[1024]; size_t k = 0; b[0] = 0;
    for (int i = 0; i < 256; i++) { uint64_t n = atomic_load(&g_red[i]); if (n && k < sizeof b - 32) k += (size_t)snprintf(b + k, sizeof b - k, " %#x×%llu", i, (unsigned long long)n); }
    LOG("未实现系统调用：%s", k ? b : " 无");
    // 栈指针未对齐的读写替游戏做了几条（crash.c / emul_sp.c s2a_emul_sp_unaligned；Switch 不查 SP 对齐、苹果查）：有才报
    { uint64_t n = s2a_sp_unaligned_count();
      if (n) LOG("栈指针未对齐：替游戏模拟了 %llu 条读写（Switch 不查栈对齐，苹果查）", (unsigned long long)n); }
}

int svc_thread(int num, uint64_t *regs);                    // thread.c：线程 / 同步，1 = 已处理
int svc_mem(int num, uint64_t *regs, uint64_t orig);        // svc_mem.c：内存 / 信息 / 计时 / 调试，1 = 已处理
void s2a_svc_ctx_fill(s2a_svc_ctx *c, int num, uint64_t *regs);   // thread.c：当前线程句柄、TLR、会话 cookie
void s2a_svc_ctx_done(void);

// 诊断 S2A_SVC_TRACE=1：每个进 C# 的请求打一行（线程、句柄、命令号）；sm GetService（应答带转移句柄）打服务名与返回句柄——
// 句柄就能对上服务名。HIPC 头：字 0 低 16 位 = 类型，字 1 bit31 = 有句柄描述；CMIF 负载以「SFCI」起，命令号在其后 +8
static int trace_on(void) { static int t = -1; if (t < 0) { const char *e = getenv("S2A_SVC_TRACE"); t = e && *e == '1'; } return t; }
static int cmif_cmd(const uint32_t *m, char *name, uint32_t *dom) {   // 返回命令号（找不到 -1）；name ≠ NULL 时取 SFCI 后 +16 处 8 字节服务名（sm GetService）
    for (int i = 2; i < 0x40; i++) if (m[i] == 0x49434653) {
        if (name) { memcpy(name, &m[i + 4], 8); name[8] = 0; }
        // 域会话：SFCI 前 16 字节是域头（字 0 低 8 位 = 1 发消息 / 2 关对象，字 1 = 对象号）；命令号只在对象内有意义，同会话多对象时要带对象号才认得出是谁
        if (dom) *dom = i >= 4 && (m[i - 4] & 0xff) >= 1 && (m[i - 4] & 0xff) <= 2 && m[i - 3] && m[i - 3] < 0x10000 ? m[i - 3] | (m[i - 4] & 0xff) << 24 : 0;
        return (int)m[i + 2]; }
    return -1;
}
static int cmif_result(const uint32_t *m, uint32_t *res) {   // 应答里 SFCO 后 +8 的结果码；找不到 0
    for (int i = 2; i < 0x40; i++) if (m[i] == 0x4F434653) { *res = m[i + 2]; return 1; }
    return 0;
}
static void trace(const s2a_svc_ctx *c, const uint32_t *msg, int before) {
    if (!msg) return;
    char nm[9] = ""; uint32_t dom = 0; int cmd = before ? cmif_cmd(msg, nm, &dom) : -1;
    if ((msg[0] & 0xffff) >= 16) { cmd = (int)(msg[0] & 0xffff) - 16; const uint32_t *raw = msg + 2 + ((msg[1] >> 31) ? 1 : 0); if (cmd == 1) { memcpy(nm, raw, 8); nm[8] = 0; } else nm[0] = 0; }   // TIPC（sm:）：类型 = 16 + 命令号，原始数据紧跟头
    if (before) { char d[40] = ""; if (dom) snprintf(d, sizeof d, " 域对象 %u%s", dom & 0xffffff, dom >> 24 == 2 ? "（关）" : "");
        LOG("[请求] 线程 %#x svc %#x 句柄 %#x cookie %#llx 类型 %u 命令 %d%s%s%s", c->thread, c->num, (uint32_t)(c->num == 0x21 ? c->regs[0] : c->regs[2]), (unsigned long long)c->obj, msg[0] & 0xffff, cmd, d, cmd == 1 && nm[0] ? " 名 " : "", cmd == 1 ? nm : ""); return; }
    // 应答的 CMIF 结果码非 0 就打（11-02 网球 Aces：手柄小程序每帧被创建却不启动，要看是哪条请求回了错）；svc 本身的返回值另在 regs[0]
    { uint32_t r = 0; if ((msg[0] & 0xffff) < 16 && cmif_result(msg, &r) && r) LOG("[应答错] 线程 %#x 结果 %#x（模块 %u 描述 %u）", c->thread, r, r & 0x1ff, (r >> 9) & 0x1fff); }
    if (msg[1] >> 31) { uint32_t hd = msg[2]; int ncopy = (hd >> 1) & 15, nmove = (hd >> 5) & 15; const uint32_t *h = msg + 3 + ((hd & 1) ? 2 : 0);
        LOG("[应答] 线程 %#x 结果 %#llx 句柄 复制 %d 转移 %d 首个 %#x", c->thread, (unsigned long long)c->regs[0], ncopy, nmove, ncopy + nmove ? h[0] : 0); }
}
// 收局：s2a_svc_park_all() 之后游戏线程进门即停（不再进 C#、也不跑线程 / 内存类），免得服务层关到一半时游戏拿到失效句柄 / 错误码、
// 跑进没人保证过的路径（10-19 动森到时收局：nvdrv 通道已关，游戏读空指针 SIGSEGV，返回码 139）
static _Atomic int g_park, g_cs_inflight;
enum { PARK_TERMINAL = 4 };
void s2a_gate_process_exit(void) {
    pthread_mutex_lock(&g_reg_mu);
    atomic_fetch_or(&g_park, PARK_TERMINAL);
    pthread_mutex_unlock(&g_reg_mu);
}
static _Thread_local uint64_t t_svc_n; static _Thread_local int t_svc_last;   // 诊断：本线程全部系统调用次数 / 最近调用号（diag_brk 打点读）
uint64_t s2a_gate_svc_stat(int *last) { *last = t_svc_last; return t_svc_n; }
// 按调用号的运行时计数（10-23 系统调用覆盖盘点要「九款实际调了哪些 svc、各多少次」，原先只有每线程总数）：每次一条 relaxed 原子加；
//   收局与崩溃时打一行（只列非零），供盘点表的影响面一栏取数
static _Atomic uint64_t g_svc_cnt[0x80];
void s2a_svc_count_report(const char *when) {
    char b[2048]; size_t k = 0; int n = 0; b[0] = 0;
    for (int i = 0; i < 0x80; i++) { uint64_t c = atomic_load_explicit(&g_svc_cnt[i], memory_order_relaxed); if (!c) continue;
        n++; if (k < sizeof b - 32) k += (size_t)snprintf(b + k, sizeof b - k, " %#04x×%llu", i, (unsigned long long)c); }
    LOG("系统调用计数 [%s]：%d 种%s", when, n, n ? b : " 无");
}
static _Thread_local int t_in_cs;   // 本线程正在 C# 里（收局可能就是从一次 C# 调用里发起的，如 am 退出：不等自己）
// 停住前先放开虚拟核（S2A_CORES）：否则停住的持核线程永不放核，从 C# 回来等这个核的线程跟着卡死（10-23 真机 S2A_CORES=1 局 3/5 收局报「还有 1 个系统调用在 C# 里没回」）
static void park_forever(void) {
#if defined(__ANDROID__)
    // Terminal park owns no VM/GPU lock and will never access guest memory again.
    void s2a_android_guest_park_forever(void) __attribute__((noreturn));
    s2a_android_guest_park_forever();
#else
    void s2a_core_leave(void), s2a_svc_ctx_done(void); s2a_core_leave();
    // No managed call remains on this path. Use the same native completion
    // checkpoint as a returning SVC, including its safe session-stop boundary.
    for (;;) { s2a_svc_ctx_done(); usleep(1000); }
#endif
}
#ifdef __ANDROID__
int s2a_svc_stopping(void) { return atomic_load_explicit(&g_park, memory_order_acquire); }
#endif
int s2a_svc_park_all(int wait_ms) {
    atomic_fetch_or(&g_park, 1);
#ifdef __ANDROID__
    s2a_android_guest_writers_notify_stop();
#endif
    for (int i = 0; i < wait_ms && atomic_load(&g_cs_inflight) > t_in_cs; i++) usleep(1000);
    return atomic_load(&g_cs_inflight) - t_in_cs;
}
void s2a_gate_stop_begin(void) { atomic_fetch_or(&g_park, 2); }
int s2a_gate_inflight(void) { return atomic_load(&g_cs_inflight); }
static uint64_t svc_dispatch(int num, uint64_t *regs, uint64_t orig) {
    if (atomic_load_explicit(&g_park, memory_order_relaxed)) park_forever();
    t_svc_n++; t_svc_last = num;
    if ((unsigned)num < 0x80) atomic_fetch_add_explicit(&g_svc_cnt[num], 1, memory_order_relaxed);
    if (svc_thread(num, regs)) return regs[0];
#ifdef __ANDROID__
    s2a_android_memory_svc_enter(num, regs);
    if (svc_mem(num, regs, orig)) return regs[0];
    s2a_android_memory_svc_unhandled();
#else
    if (svc_mem(num, regs, orig)) return regs[0];
#endif
    // SendAsyncRequestWithUserBuffer（→w1 完成事件读端; x1 缓冲, x2 大小, w3 会话）：校验照 Ryujinx；我方 IPC 是游戏线程上同步直调，
    //   所以按 0x22 同步做完，再给一个已触发的完成事件（Ryujinx 是异步完成后触发同一个事件，游戏等它的结果一样）；请求失败不发事件句柄
    if (num == 0x23) { uint64_t b = regs[1], n = regs[2];
        if (b & 0xfff) { regs[0] = 0xCC01; regs[1] = 0; return regs[0]; }
        if ((n & 0xfff) || !n) { regs[0] = 0xCA01; regs[1] = 0; return regs[0]; }
        if (b + n <= b) { regs[0] = 0xD401; regs[1] = 0; return regs[0]; }
        uint64_t sub[31]; memcpy(sub, regs, sizeof sub); sub[0] = b; sub[1] = n; sub[2] = regs[3];
        uint64_t rc = svc_dispatch(0x22, sub, orig);
        if (rc) { regs[0] = rc; regs[1] = 0; return rc; }
        uint32_t hr = 0; uint64_t ev = s2a_event_create(&hr, NULL);
        if (!hr) { regs[0] = 0xD201; regs[1] = 0; return regs[0]; }
        s2a_event_signal(ev); s2a_event_release(ev);
        regs[0] = 0; regs[1] = hr; return 0; }
    // SendSyncRequestWithUserBuffer（x0 缓冲, x1 大小, w2 句柄）：进 C# 前照 Ryujinx 核缓冲——地址 / 大小 4 KB 对齐、非零、不回绕
    if (num == 0x22) { uint64_t b = regs[0], n = regs[1];
        if (b & 0xfff) { regs[0] = 0xCC01; return regs[0]; }
        if ((n & 0xfff) || !n) { regs[0] = 0xCA01; return regs[0]; }
        if (b + n <= b) { regs[0] = 0xD401; return regs[0]; } }
    if (g_cs.svc) {
        atomic_fetch_add(&g_cs_inflight, 1);
        if (atomic_load(&g_park)) { atomic_fetch_sub(&g_cs_inflight, 1); park_forever(); }   // 与 park_all 的先后：先登记在途再复查，收局方要么等到它、要么它停住
        s2a_svc_ctx c; s2a_svc_ctx_fill(&c, num, regs);
        const uint32_t *msg = trace_on() && (num == 0x21 || num == 0x22) ? (const uint32_t *)(num == 0x21 ? c.tlr : (void *)regs[0]) : NULL;
        if (msg) trace(&c, msg, 1);
        extern int g_det; uint64_t keep[8]; if (g_det) memcpy(keep, regs, sizeof keep);
        void s2a_core_leave(void), s2a_core_enter(void); int ipc = num == 0x21 || num == 0x22 || num == 0x23;
        if (ipc) s2a_core_leave();   // IPC 阻塞在服务线程上：放开虚拟核（S2A_CORES，thread.c）
        t_in_cs = 1; int done = g_cs.svc(&c) == S2A_SVC_HANDLED;
        t_in_cs = 0; atomic_fetch_sub(&g_cs_inflight, 1);   // 进 / 出配对：与上面的 fetch_add 一一对应（10-20 曾被下一行注释吞掉，收局在途计数只增不减）
        // 重取核放在出账之后：在途只记「人在 C# 里」，等核不算；已在收局就不再取核、直接停住（取核可能永远等不到）
        if (ipc) { if (atomic_load(&g_park)) park_forever(); s2a_core_enter(); }
        // 系统调用收尾（清 in_svc）留在取核之后：等核期间仍算在系统调用里，暂停方不去 Mach 挂起它
        s2a_svc_ctx_done();
        if (g_det) { int s2a_det_out_regs(int); for (int k = s2a_det_out_regs(num); k < 8; k++) regs[k] = keep[k]; }   // 确定性档：C# 留在非输出寄存器的宿主残值不泄进游戏（每局不同）
        if (msg) trace(&c, msg, 0);
        if (done) return regs[0];
        s2a_svc_red(num, regs, orig, "C# 未处理");
    } else s2a_svc_red(num, regs, orig, "未实现（C# 未登记）");
    regs[0] = 0xF201;   // kernel NotImplemented
    return regs[0];
}
uint64_t gate_dispatch(uint64_t ret_addr, uint64_t *regs) {
    if (atomic_load_explicit(&g_park, memory_order_relaxed) & (2 | PARK_TERMINAL)) park_forever();
    gtab_t *t = atomic_load_explicit(&g_tab, memory_order_acquire);
    if (!t) die("门 %#llx 没登记（门表为空）", (unsigned long long)ret_addr);
    for (unsigned m = (1u << t->bits) - 1, i = gate_h(ret_addr, t->bits);; i = (i + 1) & m) {
        const gate_t *g = &t->e[i];
        if (g->ret == ret_addr) {
            if (g->kind == G_SVC) {   // 确定性档：系统调用持串行锁执行（阻塞处在 thread.c 放开），回参记录 / 比对（IPC 带回包）
                uint64_t r = svc_dispatch(g->arg, regs, g->orig);
                void s2a_det_svc_done(int, uint64_t *, void *); extern int g_det;
                if (g_det >= 2) { void *s2a_thread_tlr(void); s2a_det_svc_done(g->arg, regs, g->arg == 0x21 ? s2a_thread_tlr() : NULL); }
#ifdef __ANDROID__
                if (s2a_svc_stopping()) park_forever();
                s2a_android_memory_svc_finish();
                if (s2a_svc_stopping()) park_forever(); // finish可能等待epoch/虚拟核；停机在等待期间也不能回guest。
#endif
                return r;
            }
            if (g->kind == G_AREGION) {   // SDK VammManager::AllocateAddressRegion 返回处（改写器 SDK 地址区安全阀）：失败当场报红，返回值原样还给游戏
                if ((uint32_t)regs[0]) { static _Atomic uint64_t n; uint64_t k = atomic_fetch_add(&n, 1) + 1;
                    if (!(k & (k - 1))) { module_t *m = module_of((void *)g->orig);
                        LOG("【红】地址区分配失败（第 %llu 次）：SDK AllocateAddressRegion 回 %#x（%s+%#llx）——别名区耗尽或碎片，游戏接下来会把 0 当地址用；别名区账见下一行",
                            (unsigned long long)k, (unsigned)regs[0], m ? m->name : "?", (unsigned long long)(m ? g->orig - (uint64_t)m->base : g->orig));
                        void (*rep)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "s2a_guest_va_report"); if (rep) rep("地址区分配失败"); } }   // svc_mem.c；按名取，单测只链 gate.c
                return regs[0]; }
            if (g->kind == G_SPIN) { void s2a_spin_wait(uint64_t); s2a_spin_wait(g->orig); return regs[0]; }   // 自旋闸（改写器 S2A_REWRITE_SPIN=1；thread.c）
            if (g->kind == G_WIDE) { void s2a_widen_gate(int, uint64_t *, uint64_t); s2a_widen_gate(g->arg, regs, g->orig); return regs[0]; }   // 宽屏点（widen.c）
            { void s2a_det_yield(void); s2a_det_yield(); }   // S2A_DET=1：读计数器也是交接点（游戏按时间忙等时让别的游戏线程跑）
            { void s2a_tick_wait(uint64_t); s2a_tick_wait(g->orig ^ regs[30]); }   // 读时钟闸（thread.c）：按时钟忙等下一帧的循环满 2 ms 后睡；调用点 = 门位置 ^ 调用方返回地址
            { uint64_t s2a_det_tick(uint64_t); return regs[g->arg] = s2a_det_tick(guest_tick()); }   // mrs xN, cntpct_el0 / cntvct_el0：arg = N（确定性档记录 / 回放值）
        }
        if (!g->ret) die("门 %#llx 没登记", (unsigned long long)ret_addr);
    }
}

// Called only after all guest threads have joined and services have stopped.
int s2a_gate_session_reset(void) {
    if (atomic_load(&g_cs_inflight)) return -1;
    pthread_mutex_lock(&g_reg_mu);
    if (atomic_load(&g_park) & PARK_TERMINAL) { pthread_mutex_unlock(&g_reg_mu); return -1; }
    gtab_t *t = atomic_exchange(&g_tab, NULL);
    while (t) { gtab_t *old = t->older; free(t); t = old; }
    g_ngate = 0; g_cs = (s2a_cs_api){0};
    for (int i = 0; i < 256; i++) atomic_store(&g_red[i], 0);
    for (int i = 0; i < 128; i++) atomic_store(&g_svc_cnt[i], 0);
    atomic_store(&g_park, 0);
    pthread_mutex_unlock(&g_reg_mu);
    return 0;
}
