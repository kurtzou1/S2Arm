// 门分派单测（只链 runtime/src/gate.c，其余设施在本文件打桩）：
// ① 进 C# 的系统调用：在途计数进 / 出配对——1000 次调用后在途 0（10-20 曾被一行注释吞掉减一，收局报「还有 10 万个系统调用在 C# 里没回」）；
//    每次调用后「系统调用收尾」（s2a_svc_ctx_done）各调一次
// ② C# 处理期间在途为 1（收局等得到它）
// ③ C# 未处理：回 0xF201 并报红，在途照样归 0
// ④ 虚拟核（S2A_CORES）：IPC 从 C# 回来后卡在等核的线程不算在途（10-23 真机 CORES 局 3/5 收局「还有 1 个系统调用在 C# 里没回」：C# 已回、人在等核）
// ⑤ 收局后进门的线程停住前放开虚拟核（否则从 C# 回来等这个核的线程永远等不到）
// 等事件的上限只当兜底（11-19：原先 1～5 秒，负载高时线程没跑到就判红 → 一律 30 秒，正常时一到就返回）
#include "../src/native.h"
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
int g_det;
uint64_t guest_tick(void) { return 0; }
module_t *module_of(const void *p) { (void)p; return NULL; }
static int n_va; __attribute__((visibility("default"), used)) void s2a_guest_va_report(const char *w) { (void)w; n_va++; }   // gate.c 按名取（dlsym）
static int n_sa; __attribute__((visibility("default"), used)) void s2a_sainit_gate(uint64_t *r) { n_sa++; if (!r[1]) r[2] = 4ull << 30; }   // 分配器初始化闸处理（svc_mem.c）的桩：地址空时把尺寸改成 4 GiB
void s2a_backtrace(uint64_t fp) { (void)fp; }
int s2a_det_out_regs(int num) { (void)num; return 1; }
static _Atomic int n_leave, block_core, at_core;
void s2a_core_leave(void) { atomic_fetch_add(&n_leave, 1); }
void s2a_core_enter(void) { atomic_store(&at_core, 1); while (atomic_load(&block_core)) pause(); }   // thread.c 虚拟核（S2A_CORES）：IPC 前后放 / 取核；block_core 模拟核永远被占
void s2a_det_svc_done(int num, uint64_t *regs, void *msg) { (void)num; (void)regs; (void)msg; }
uint64_t s2a_det_tick(uint64_t v) { return v; }
void s2a_det_yield(void) {}
static int n_done;
void s2a_svc_ctx_done(void) { n_done++; }
static uint32_t g_tlr[64];   // ⑥ 假 TLS 消息区：IPC 请求 / 应答都在这里（同真机 0x21）
void s2a_svc_ctx_fill(s2a_svc_ctx *c, int num, uint64_t *regs) { memset(c, 0, sizeof *c); c->num = (uint32_t)num; c->regs = regs; c->tlr = g_tlr; }
void *s2a_thread_tlr(void) { return NULL; }
void s2a_widen_gate(int idx, uint64_t *regs, uint64_t orig) { (void)idx; (void)regs; (void)orig; }
void s2a_spin_wait(uint64_t site) { (void)site; }
void s2a_tick_wait(uint64_t key) { (void)key; }
uint64_t s2a_event_create(uint32_t *r, uint32_t *w) { (void)r; (void)w; return 0; } void s2a_event_signal(uint64_t e) { (void)e; } void s2a_event_release(uint64_t e) { (void)e; }
int svc_thread(int num, uint64_t *regs) { (void)num; (void)regs; return 0; }
int svc_mem(int num, uint64_t *regs, uint64_t orig) { (void)num; (void)regs; (void)orig; return 0; }
int s2a_svc_park_all(int wait_ms);

static int handled = 1;
static int reply_mode;   // ⑥：1 = 回 GetService（转移一个句柄 0x1234）；2 = 回 CMIF 结果 0x2a2
static int cs_svc(s2a_svc_ctx *c) {
    c->regs[0] = 0;
    if (reply_mode == 1) { memset(g_tlr, 0, sizeof g_tlr); g_tlr[0] = 0; g_tlr[1] = 1u << 31; g_tlr[2] = 1u << 5; g_tlr[3] = 0x1234; }
    if (reply_mode == 2) { memset(g_tlr, 0, sizeof g_tlr); g_tlr[0] = 4; g_tlr[1] = 8; g_tlr[4] = 0x4F434653; g_tlr[6] = 0x2a2; }
    return handled ? S2A_SVC_HANDLED : 0; }
static void *ipc_thread(void *a) { uint64_t r[32] = {0}; gate_dispatch((uint64_t)a, r); return NULL; }
static int fails;
static void check(const char *w, int ok) { printf("%s %s\n", ok ? "✓" : "✗", w); fails += !ok; }
int main(void) {
    s2a_cs_api api = { .size = sizeof api, .svc = cs_svc };
    s2a_register_cs(&api);
    {   // 已实现集合 + NPDM 许可比对（10-24）：期望手写——Ryujinx 72 个里应用不可调的 14 个不在集合；许可 0x01 0x21 0x28 0x40 0x7B → 没实现 0x28 0x40 0x7B
        int s2a_svc_implemented(int), s2a_svc_check_perm(const uint64_t perm[3], char *out, size_t cap);
        static const int yes[] = {0x01, 0x07, 0x0b, 0x1f, 0x21, 0x22, 0x23, 0x29, 0x37, 0x45, 0x4b, 0x52, 0x5f, 0x6f, 0x7d, 0x7e};
        static const int no[] = {0x00, 0x20, 0x28, 0x40, 0x41, 0x43, 0x44, 0x65, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x77, 0x78, 0x7b, 0x7f};
        int ok = 1; for (size_t i = 0; i < sizeof yes / sizeof *yes; i++) ok &= s2a_svc_implemented(yes[i]); for (size_t i = 0; i < sizeof no / sizeof *no; i++) ok &= !s2a_svc_implemented(no[i]);
        check("已实现集合：抽查 16 个已实现、18 个未实现（含 14 个系统进程级）", ok);
        int cnt = 0; for (int i = 0; i < 0xC0; i++) cnt += s2a_svc_implemented(i);
        check("已实现集合共 59 个（72 − 14 + Switch 2 的 0x80）", cnt == 59 && s2a_svc_implemented(0x80) && !s2a_svc_implemented(0x81));
        uint64_t perm[3] = {0}; int ps[] = {0x01, 0x21, 0x28, 0x40, 0x7b}; for (size_t i = 0; i < 5; i++) perm[ps[i] >> 6] |= 1ull << (ps[i] & 63);
        char b[200]; int nu = s2a_svc_check_perm(perm, b, sizeof b);
        check("许可 0x01 0x21 0x28 0x40 0x7B → 没实现 2 个「0x40 0x7b」（0x28 真值也没有，另列）", nu == 2 && !strcmp(b, "0x40 0x7b"));
    }
    {   // 地址区分配失败门（aregion，改写器挂在 SDK AllocateAddressRegion 的每条 ret 上）：成功（w0 = 0）不报；失败原样返回 Result、报红并打一次别名区账
        static uint8_t ac[16]; uint64_t ar = (uint64_t)&ac[4]; gate_register(ar, "aregion", 0, (uint64_t)&ac[0]);
        uint64_t r[32] = {0}; uint64_t g0 = gate_dispatch(ar, r);
        check("aregion 门：返回 0（成功）→ 回 0、不打别名区账", g0 == 0 && r[0] == 0 && n_va == 0);
        r[0] = 0xE401; uint64_t g1 = gate_dispatch(ar, r);
        check("aregion 门：返回 0xE401（失败）→ 原样回 0xE401、打一次别名区账", g1 == 0xE401 && r[0] == 0xE401 && n_va == 1);
    }
    {   // 分配器初始化闸（aregion 参数 1，改写器挂在 StandardAllocator 初始化入口；进门前 x0 已清零）：交给 s2a_sainit_gate 改 x2，不走「地址区分配失败」报红
        static uint8_t sc[16]; uint64_t sr = (uint64_t)&sc[4]; gate_register(sr, "aregion", 1, (uint64_t)&sc[0]);
        uint64_t r[32] = {0}; r[2] = 62ull << 30; int va0 = n_va; uint64_t g = gate_dispatch(sr, r);
        check("分配器初始化闸：地址空 → 处理函数把 x2 改成 4 GiB、回 x0 = 0、不打别名区账", n_sa == 1 && r[2] == (4ull << 30) && g == 0 && n_va == va0);
        r[0] = 0x1234; r[1] = 0x5000; r[2] = 62ull << 30; gate_dispatch(sr, r);
        check("分配器初始化闸：带缓冲（x1 非空）→ x2 原样、x0 非零也不报红", n_sa == 2 && r[2] == (62ull << 30) && n_va == va0);
    }
    static uint8_t code[64];   // 假门块返回点：登记一个 svc 0x21 门
    uint64_t ret = (uint64_t)&code[8];
    gate_register(ret, "svc", 0x21, 0xd4000421);
    uint64_t regs[32] = {0};
    for (int i = 0; i < 1000; i++) gate_dispatch(ret, regs);
    check("1000 次进 C# 的系统调用后，系统调用收尾各调一次（1000 次）", n_done == 1000);
    handled = 0; regs[0] = 0; gate_dispatch(ret, regs);
    check("C# 未处理：回 0xF201", regs[0] == 0xF201);
    check("C# 未处理也调了系统调用收尾（1001 次）", n_done == 1001);
    handled = 1;
    {   // ⑥ 崩溃现场的最近 IPC（#eb9952）：sm 给 fsp-srv 会话 0x1234（TIPC 命令 1，名字在请求里），再在 0x1234 上发 CMIF 命令 7、回结果 0x2a2。
        //   期望（手写）：倒出来的最后两条依次是「句柄 0（sm）命令 1」与「句柄 0x1234（fsp-srv）命令 7 → 结果 0x2a2」
        memset(g_tlr, 0, sizeof g_tlr); g_tlr[0] = 16 + 1; g_tlr[1] = 0; memcpy(&g_tlr[2], "fsp-srv\0", 8);
        reply_mode = 1; regs[0] = 0; gate_dispatch(ret, regs);
        memset(g_tlr, 0, sizeof g_tlr); g_tlr[0] = 4; g_tlr[1] = 8; g_tlr[4] = 0x49434653; g_tlr[6] = 7;
        reply_mode = 2; regs[0] = 0x1234; gate_dispatch(ret, regs); reply_mode = 0;
        void s2a_gate_ipc_recent(const char *); char path[] = "/tmp/t_gate_ipcXXXXXX"; int fd = mkstemp(path), keep = dup(2);
        fflush(stderr); dup2(fd, 2); s2a_gate_ipc_recent("单测"); fflush(stderr); dup2(keep, 2); close(keep);
        char out[8192] = {0}; lseek(fd, 0, SEEK_SET); ssize_t got = read(fd, out, sizeof out - 1); (void)got; close(fd); unlink(path);
        check("⑥ 最近 IPC：sm 那条记成命令 1", strstr(out, "句柄 0（?）命令 1 → 结果 0") != NULL);
        check("⑥ 最近 IPC：0x1234 认出是 fsp-srv、命令 7、结果 0x2a2", strstr(out, "句柄 0x1234（fsp-srv）命令 7 → 结果 0x2a2") != NULL);
        if (!strstr(out, "fsp-srv")) printf("%s\n", out);
    }
    // at_core 先清：前面每次 IPC 都置过
    atomic_store(&at_core, 0); atomic_store(&block_core, 1); pthread_t th; pthread_create(&th, NULL, ipc_thread, (void *)ret);
    for (int i = 0; i < 30000 && !atomic_load(&at_core); i++) usleep(1000);   // 等它从 C# 回来、卡在取核
    check("（前提）IPC 线程已从 C# 回来、卡在取核", atomic_load(&at_core));
    int left = s2a_svc_park_all(300);   // 收局入口：回仍在 C# 里的系统调用数（此后门进即停，单测到此为止）
    check("全部调用回来后在途 0（进 / 出配对；卡在等核的不算在途）", left == 0);
    int l0 = atomic_load(&n_leave); pthread_create(&th, NULL, ipc_thread, (void *)ret);   // 收局后再进门：应停住
    for (int i = 0; i < 30000 && atomic_load(&n_leave) == l0; i++) usleep(1000);
    check("收局后进门的线程停住前放开虚拟核", atomic_load(&n_leave) > l0);
    {   // 门数过 2048（10-26 普查 3 款 FATAL「门太多（2049）」）：登记 5000 个 cntpct 门，表应自动扩到 ≥ 4 × 5000 槽、每个门都查回自己的寄存器号
        int s2a_gate_count(void); unsigned s2a_gate_bits(void);
        static uint8_t big[5000 * 8]; int n0 = s2a_gate_count(), bad_back = 0;
        for (int i = 0; i < 5000; i++) gate_register((uint64_t)&big[i * 8 + 4], "cntpct", i % 31, (uint64_t)&big[i * 8]);
        for (int i = 0; i < 5000; i++) { uint64_t r[32] = {0}; r[i % 31] = 0xdead; gate_dispatch((uint64_t)&big[i * 8 + 4], r); if (r[i % 31] != 0) bad_back++; }   // 桩 guest_tick 恒 0：查回的门把登记的那个寄存器写成 0
        unsigned bits = s2a_gate_bits();
        if (s2a_gate_count() != n0 + 5000 || (1u << bits) < 4u * (unsigned)s2a_gate_count() || bad_back) {
            printf("✗ 门数过 2048：应登记 %d 个、表 ≥ 4 倍、全部查回；实 %d 个、表 2^%u、查回错 %d\n", n0 + 5000, s2a_gate_count(), bits, bad_back); fails++; }
        else printf("  门数过 2048：登记 %d 个，表扩到 2^%u 槽，5000 个全部查回\n", s2a_gate_count(), bits);
    }
    printf("%s t_gate：%d 处不符（共 17 项）\n", fails ? "✗" : "✓", fails);
    return fails != 0;
}
