// 确定性调试（缺省关；产品与验收局永远真并行）。三档：
//   S2A_DET=1            串行：同一时刻只有一条游戏线程跑（游戏代码 + 系统调用），只在阻塞等待 / 睡眠 / 读计数器处交接；宿主线程照常并行
//   S2A_DET_REC=<文件>    串行 + 记录：全局追加日志（只有锁持有者写，天然有序）：交接轮次、计数器值、系统调用回参哈希、阻塞结局
//   S2A_DET_PLAY=<文件>   串行 + 重放：按日志强制同一交接轮次、计数器回录的值、阻塞按录的结局；系统调用真执行后与录的比，第一处不同打「分叉」
// 射程：只为「同一局记录 → 重放」；只有真并行才出现的竞态（宿主线程之间的互锁、游戏线程真并发的数据竞争）复现不了，那类靠全线程现场。
// 宿主线程异步写游戏内存（输入、时间共享内存、GPU 回写）还不在轮次里（下一步：伪线程进轮次），是现阶段已知的分叉来源。
#include "native.h"
#include "../../platform/plat.h"
#include <errno.h>
#include <fcntl.h>
#if !defined(__APPLE__)
#include <dlfcn.h>
typedef pthread_mutex_t det_mutex;
#define DET_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
static void det_mutex_lock(det_mutex *m) { int e = pthread_mutex_lock(m); if (e) die("确定性：mutex lock errno=%d", e); }
static void det_mutex_unlock(det_mutex *m) { int e = pthread_mutex_unlock(m); if (e) die("确定性：mutex unlock errno=%d", e); }
static int det_mutex_trylock(det_mutex *m) { int e = pthread_mutex_trylock(m); if (e && e != EBUSY) die("确定性：mutex trylock errno=%d", e); return e == 0; }
#else
#include <os/lock.h>
typedef os_unfair_lock det_mutex;
#define DET_MUTEX_INIT OS_UNFAIR_LOCK_INIT
#define det_mutex_lock os_unfair_lock_lock
#define det_mutex_unlock os_unfair_lock_unlock
#define det_mutex_trylock os_unfair_lock_trylock
#endif
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/ucontext.h>

int g_det;                                    // 1 串行 / 2 记录 / 3 重放
enum { E_TURN = 1, E_TICK = 2, E_SVC = 3, E_WAIT = 4, E_HOST = 5, E_MEM = 6, E_HASH = 7 };   // E_HASH：诊断检查点，a = 块号、v = 1 MB 块哈希   // E_MEM：宿主写游戏内存，a = 长度、v = 地址，后跟数据块   // E_HOST：宿主线程改游戏可见对象（事件触发 / 清除），a = 对象号
typedef struct { uint8_t type, pad; uint16_t ord; uint32_t a; uint64_t v; } dent_t;   // 16 字节
_Static_assert(sizeof(dent_t) == 16, "det 日志项 16 字节");

static det_mutex g_gl = DET_MUTEX_INIT;   // 串行 / 记录
static pthread_mutex_t g_pm = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_pc = PTHREAD_COND_INITIALIZER;   // 重放
static int g_held;                                   // 重放：有人持锁（g_pm 护）
static _Atomic(pthread_t) g_owner;
static _Atomic uint64_t g_since, g_handoffs, g_preempts, g_pre_last_pc;
static _Atomic int g_waiters;
static _Atomic int g_started;   // 第一条游戏线程拿到过轮次（之前是单线程初始化：宿主写 / 改事件直接生效、不记）
static _Thread_local int t_held, t_ord;
static uint64_t g_slice_ns = 100000000;
#define PRE_PCS 64
static struct { uint64_t pc; uint32_t n; } g_pre[PRE_PCS];

// ---------- 日志 ----------
#define RBUF (1u << 20)                   // 记录缓冲 100 万项（16 MB），满了整块写出：零分配
static dent_t *g_rb; static uint32_t g_rn; static int g_rfd = -1; static uint64_t g_rtotal;
static const dent_t *g_pl; static uint64_t g_pn, g_pos;      // 重放：整份映射、项数、读到哪
static _Atomic int g_div;                 // 重放已分叉（之后只串行、不再比）
static void rec(int type, uint32_t a, uint64_t v) {
    if (g_det != 2) return;
    g_rb[g_rn++] = (dent_t){ (uint8_t)type, 0, (uint16_t)t_ord, a, v };
    if (g_rn == RBUF) { ssize_t w = write(g_rfd, g_rb, (size_t)g_rn * 16); (void)w; g_rtotal += g_rn; g_rn = 0; }
}
static const char *tname(int t) { return t == E_TURN ? "交接" : t == E_TICK ? "计数器" : t == E_SVC ? "系统调用" : t == E_WAIT ? "阻塞结局" : t == E_HOST ? "宿主改对象" : t == E_MEM ? "宿主写内存" : "?"; }
static void diverge(const char *what, int type, uint32_t a, uint64_t v) {
    if (atomic_exchange(&g_div, 1)) return;
    { void s2a_thread_dump(void); LOG("重放分叉时的游戏线程表："); s2a_thread_dump(); }
    const dent_t *e = g_pos < g_pn ? &g_pl[g_pos] : NULL;
    LOG("【红】重放分叉：第 %llu 项 %s——录的 %s 线程 %u a=%#x v=%#llx，实际 %s 线程 %d a=%#x v=%#llx（此后只串行、不再比）",
        (unsigned long long)g_pos, what, e ? tname(e->type) : "（日志已尽）", e ? e->ord : 0, e ? e->a : 0, e ? (unsigned long long)e->v : 0ull,
        tname(type), t_ord, a, (unsigned long long)v);
    pthread_mutex_lock(&g_pm); pthread_cond_broadcast(&g_pc); pthread_mutex_unlock(&g_pm);
}
static void play_host_pending(void);
// 重放取下一项并核类型 / 线程；不符记分叉，回 NULL
static const dent_t *play(int type, uint32_t a, uint64_t v) {
    if (g_det != 3 || atomic_load(&g_div)) return NULL;
    play_host_pending();   // 持锁者自己流里夹着的宿主项（影子起始内容、发布、窗口内写）先代为生效
    if (g_pos >= g_pn) { diverge("日志已尽", type, a, v); return NULL; }
    const dent_t *e = &g_pl[g_pos];
    if (e->type != type || e->ord != (uint16_t)t_ord) { diverge("事件不同", type, a, v); return NULL; }
    g_pos++; return e;
}

static int g_nsh; static void wr(uint64_t addr, const void *src, uint64_t len); static void rec_raw_pad(const void *p, uint64_t len);
static void play_host_pending(void); static void publish(void); static void mq_drain(void); static void hq_drain(void); static void rec_raw(const void *p, size_t n);
static _Atomic uint32_t g_hq_w, g_hq_r; static uint64_t g_mr_w, g_mr_r;
// ---------- 诊断：游戏可写内存分块哈希（S2A_DET_HASH_EVERY=<交接次数>，缺省关）----------
// 记录档每隔 N 次交接记下游戏可写区每 1 MB 一个哈希；重放档同一时刻算、比，第一块不同就打地址——定位「哪段内存先不一样」，再找写它的人
static uint64_t g_hash_every, g_turns, g_ckpt, g_dump_ckpt, g_dump_addr; static int g_hash_reported; static char g_dump_pfx[1024];
int s2a_det_mem_regions(uint64_t *b, uint64_t *n, int max); void s2a_det_tlr_region(uint64_t *b, uint64_t *n);
static uint64_t fasthash(const uint64_t *p, size_t nw) { uint64_t h = 0x9E3779B97F4A7C15ull; for (size_t i = 0; i < nw; i++) { h ^= p[i] + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2); } return h; }
static void mem_checkpoint(void) {   // 持串行锁
    uint64_t b[64], n[64]; int k = s2a_det_mem_regions(b, n, 64);
    for (int i = 0; i < g_nmod && k < 64; i++) { module_t *m = &g_mod[i]; if (m->image_size > m->data_off) { b[k] = (uint64_t)m->base + m->data_off; n[k++] = m->image_size - m->data_off; } }
    g_ckpt++; uint32_t idx = 0;
    for (int r = 0; r < k; r++) for (uint64_t o = 0; o < n[r]; o += 1u << 20, idx++) {
        uint64_t len = n[r] - o < (1u << 20) ? n[r] - o : (1u << 20);
        uint64_t h = fasthash((const uint64_t *)(b[r] + o), len / 8);
        if (g_dump_ckpt == g_ckpt && g_dump_addr == b[r] + o) {   // S2A_DET_DUMP=<检查点>:<块地址>：把这一块原样落盘（记录 / 重放各一份，离线比字节）
            char path[1100]; snprintf(path, sizeof path, "%s.%s.ckpt%llu.%llx.bin", g_dump_pfx, g_det == 2 ? "rec" : "play", (unsigned long long)g_ckpt, (unsigned long long)g_dump_addr);
            int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0) { ssize_t w = write(fd, (const void *)(b[r] + o), len); (void)w; close(fd); LOG("确定性：检查点 %llu 块 %#llx 已落盘 %s", (unsigned long long)g_ckpt, (unsigned long long)g_dump_addr, path); }
        }
        if (g_det == 2) rec(E_HASH, idx, h);
        else if (g_det == 3 && !atomic_load(&g_div)) {
            if (g_pos >= g_pn || g_pl[g_pos].type != E_HASH || g_pl[g_pos].a != idx) { diverge("检查点块数 / 位置不同", E_HASH, idx, h); return; }
            if (g_pl[g_pos].v != h && !g_hash_reported) { g_hash_reported = 1; LOG("【红】确定性检查点 %llu：游戏内存第一块不同 %#llx +1 MB（区 %d：%#llx +%#llx），在日志第 %llu 项",
                (unsigned long long)g_ckpt, (unsigned long long)(b[r] + o), r, (unsigned long long)b[r], (unsigned long long)n[r], (unsigned long long)g_pos); }
            g_pos++;
        }
    }
    { uint64_t tb, tn; s2a_det_tlr_region(&tb, &tn);   // TLR：逐个 0x200 槽哈希（跳过 +0x1F8 宿主指针），合成一项
      uint64_t h = 0x9E3779B97F4A7C15ull; for (uint64_t o = 0; o + 0x200 <= tn; o += 0x200) h = h * 31 + fasthash((const uint64_t *)(tb + o), 0x1F8 / 8);
      if (g_det == 2) rec(E_HASH, 0xFFFFFFFFu, h);
      else if (g_det == 3 && !atomic_load(&g_div)) {
          if (g_pos >= g_pn || g_pl[g_pos].type != E_HASH || g_pl[g_pos].a != 0xFFFFFFFFu) { diverge("检查点 TLR 项位置不同", E_HASH, 0xFFFFFFFFu, h); return; }
          if (g_pl[g_pos].v != h && !g_hash_reported) { g_hash_reported = 1; LOG("【红】确定性检查点 %llu：TLR 区（各线程 IPC 缓冲，%llu 个线程槽）不同，在日志第 %llu 项", (unsigned long long)g_ckpt, (unsigned long long)(tn / 0x200), (unsigned long long)g_pos); }
          g_pos++;
      } }
    if (g_det == 3 && !g_hash_reported) LOG("确定性检查点 %llu：游戏可写内存 %u 块 + TLR 全同", (unsigned long long)g_ckpt, idx);
}

// ---------- 诊断：写监视（S2A_DET_WATCH=<游戏地址>）：第一次拿锁时把那一页设只读，第一次写缺页时打写的位置后放开 ----------
static uint64_t g_watch, g_watch_turn = 1000, g_watch_n; static _Atomic int g_watch_armed, g_watch_hit;   // 第 N 次交接才上监视：太早上会被游戏随后的 SetHeapSize 改回可写
static void watch_arm(void) { if (g_watch && !atomic_exchange(&g_watch_armed, 1)) { mprotect((void *)(g_watch & ~0x3FFFull), 0x4000, PROT_READ); LOG("确定性：写监视 %#llx 所在页已设只读", (unsigned long long)g_watch); } }
int s2a_det_watch_fault(uint64_t addr, uint64_t pc, uint64_t lr, uint64_t fp) {   // crash.c：回 1 已处理（放开页、继续）
    if (!g_watch || !atomic_load(&g_watch_armed) || (addr & ~0x3FFFull) != (g_watch & ~0x3FFFull)) return 0;
    if (!atomic_exchange(&g_watch_hit, 1)) {
        void s2a_where(uint64_t a, char *b, size_t n); void s2a_backtrace(uint64_t fp); char bp[160], bl[160]; s2a_where(pc, bp, sizeof bp); s2a_where(lr, bl, sizeof bl);
        LOG("【红】确定性写监视：第一次写 %#llx（页内）在 pc %s lr %s，线程 %d%s；回溯：", (unsigned long long)addr, bp, bl, t_ord, t_held ? "（持锁游戏线程）" : "（宿主线程）");
        s2a_backtrace(fp);
    }
    mprotect((void *)(g_watch & ~0x3FFFull), 0x4000, PROT_READ | PROT_WRITE); return 1;
}

// ---------- 轮次 ----------
void s2a_det_set_ord(int ord) { t_ord = ord; }
int s2a_det_mode(void) { return g_det; }
int s2a_det_in_turn(void) { return t_held; }   // 本线程是持串行锁的游戏线程
int s2a_det_replaying(void) { return g_det == 3 && !atomic_load(&g_div); }   // 重放且未分叉：阻塞按录的结局走；分叉后恢复真等
void s2a_det_acquire(void) {
    if (!g_det) return;   // 关路径只读全局开关 g_det
    __asm__ volatile("" ::: "memory");   // 屏障：同 release，g_det==0 不读 t_held（TLS blr）
    if (t_held) return;
    if (g_det == 3) {
        pthread_mutex_lock(&g_pm);
        for (;;) {
            if (!g_held) {
                if (atomic_load(&g_div)) break;
                play_host_pending();
                if (g_pos >= g_pn) { pthread_mutex_unlock(&g_pm); diverge("日志已尽（重放跑完）", E_TURN, 0, 0); pthread_mutex_lock(&g_pm); continue; }
                const dent_t *e = &g_pl[g_pos];
                if (e->type == E_TURN && e->ord == (uint16_t)t_ord) { g_pos++; break; }
            }
            struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 10;
            if (pthread_cond_timedwait(&g_pc, &g_pm, &dl) == ETIMEDOUT && !g_held && !atomic_load(&g_div)) {
                const dent_t *e = &g_pl[g_pos]; pthread_mutex_unlock(&g_pm);
                diverge(e->type == E_TURN ? "10 秒等不到该轮到的线程" : "轮次空档卡住", E_TURN, 0, 0); pthread_mutex_lock(&g_pm);
            }
        }
        g_held = 1; pthread_mutex_unlock(&g_pm);
    } else {
        atomic_fetch_add(&g_waiters, 1); det_mutex_lock(&g_gl); atomic_fetch_sub(&g_waiters, 1);
    }
    t_held = 1; atomic_store(&g_owner, pthread_self()); atomic_store(&g_since, now_ns()); atomic_fetch_add(&g_handoffs, 1);
    atomic_store(&g_started, 1);
    rec(E_TURN, 0, 0);
    if (g_watch && ++g_watch_n >= g_watch_turn) watch_arm();
    if (g_hash_every && ++g_turns % g_hash_every == 0) mem_checkpoint();
    if (g_det == 2 && g_nsh) publish();
    if (g_det == 3 && g_nsh) { pthread_mutex_lock(&g_pm); play_host_pending(); pthread_mutex_unlock(&g_pm); }
}
void s2a_det_release(void) {
    if (!g_det) return;   // 关路径只读全局开关 g_det
    __asm__ volatile("" ::: "memory");   // 屏障：g_det==0 时不得把 t_held 读提前（_Thread_local，读它要 blr tlv_get_addr）——保证关路径零调用、负载无关
    if (!t_held) return;
    t_held = 0; atomic_store(&g_owner, (pthread_t)0);
    if (g_det == 3) { pthread_mutex_lock(&g_pm); play_host_pending(); g_held = 0; pthread_cond_broadcast(&g_pc); pthread_mutex_unlock(&g_pm); }
    else {
        if (g_det == 2) { hq_drain(); mq_drain(); }   // 持锁期间进来的宿主待办：放锁前按序生效并记录
        det_mutex_unlock(&g_gl);
        if (g_det == 2 && (atomic_load(&g_hq_r) != atomic_load(&g_hq_w) || g_mr_r != g_mr_w) && det_mutex_trylock(&g_gl)) { hq_drain(); mq_drain(); det_mutex_unlock(&g_gl); }   // 放锁瞬间进来的
    }
}
static _Thread_local uint32_t t_ticks;
void s2a_det_yield(void) {   // 交接点（读计数器）。串行档：有人等才让；记录 / 重放档：每条线程每读 64 次固定交接一次（次数确定，轮次可重放；
                             // 游戏按时间忙等时不至于独占）
    if (!g_det) return;   // 关路径只读全局开关 g_det
    __asm__ volatile("" ::: "memory");   // 屏障：g_det==0 时不得把 t_held 读提前（_Thread_local，读它要 blr tlv_get_addr）——保证关路径零调用、负载无关
    if (!t_held) return;
    if (g_det == 1) { if (!atomic_load(&g_waiters)) return; }
    else if (++t_ticks & 63) return;
    s2a_det_release(); sched_yield(); s2a_det_acquire();
}

// ---------- 宿主线程改游戏可见对象（事件触发 / 清除）----------
// 宿主线程永不等串行锁（它可能持着自己的锁，等串行锁会和持锁游戏线程反向死锁）：
//   记录档：试拿锁，拿到就当场生效并记一笔；拿不到放进待办队列，持锁者放锁前按序生效并记下
//   重放档：宿主线程的真触发一律忽略，事件状态只按日志改——放锁时 / 等轮次时遇到日志里的宿主项就代为生效
#define HOST_ORD 0xFFFF
#define HQ 4096
static _Atomic uint64_t g_hq[HQ];   // 待办：(id << 1 | 操作)
static _Atomic uint64_t g_hq_drop;
void s2a_det_apply_host(uint32_t id, int op);   // thread.c：按对象号改事件
static void host_rec_apply(uint32_t id, int op) {   // 持串行锁
    if (g_det == 2) { g_rb[g_rn++] = (dent_t){ E_HOST, 0, HOST_ORD, id, (uint64_t)op }; if (g_rn == RBUF) { ssize_t w = write(g_rfd, g_rb, (size_t)g_rn * 16); (void)w; g_rtotal += g_rn; g_rn = 0; } }
    s2a_det_apply_host(id, op);
}
static void hq_drain(void) {   // 持串行锁（记录档）
    for (uint32_t r = atomic_load(&g_hq_r); r != atomic_load(&g_hq_w); r++) {
        uint64_t v; while (!(v = atomic_exchange(&g_hq[r % HQ], 0))) {}   // 写者先占位后填值：等它填好
        host_rec_apply((uint32_t)(v >> 1), (int)(v & 1)); atomic_store(&g_hq_r, r + 1);
    }
}
static void play_host_pending(void) {   // 重放：日志里紧接着的宿主项代为生效（持 g_pm、无人持锁时）
    while (!atomic_load(&g_div) && g_pos < g_pn && (g_pl[g_pos].type == E_HOST || g_pl[g_pos].type == E_MEM)) {
        const dent_t *e = &g_pl[g_pos];
        if (e->type == E_HOST) { s2a_det_apply_host(e->a, (int)e->v); g_pos++; }
        else { wr(e->v, &g_pl[g_pos + 1], e->a); g_pos += 1 + (e->a + 15) / 16; }
    }
}
// ---------- 共享内存影子（记录 / 重放档）：游戏看的是影子副本，宿主写后备；持锁者拿到轮次时（≤ 每毫秒一次）把差异发布进影子并记录 ----------
#if defined(__APPLE__)
#include <mach/mach.h>
#endif
static struct { uint64_t ga, n; const uint8_t *host; uint8_t *rw; } g_sh[16];
static uint64_t g_last_pub;
static void wr(uint64_t addr, const void *src, uint64_t len) {   // 游戏地址写：落在影子里的写影子的可写视图
    for (int i = 0; i < g_nsh; i++) if (addr >= g_sh[i].ga && addr + len <= g_sh[i].ga + g_sh[i].n) { memcpy(g_sh[i].rw + (addr - g_sh[i].ga), src, len); return; }
    memcpy((void *)addr, src, len);
}
int s2a_det_shmem_map(uint64_t ga, const void *host, uint64_t n, uint64_t span, int prot) {   // svc_mem.c MapSharedMemory：回 1 已映射影子
    if (g_det < 2 || g_nsh >= 16) return 0;
    uint8_t *rw = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0); if (rw == MAP_FAILED) return 0;
    if (g_det == 2) memcpy(rw, host, n);   // 记录：起始内容随后由发布补齐差异；重放：起始全零，按日志发布
#if !defined(__APPLE__)
    int rc = plat_vm_alias((void *)(uintptr_t)ga, rw, span, (uint32_t)prot);
    if (rc) {
        munmap(rw, span);
        // EIO means the platform could not restore ownership of the target.
        // Falling back to another MAP_FIXED alias would touch a poisoned range.
        if (rc == EIO) die("确定性共享内存无法恢复地址保留");
        return 0;
    }
#else
    vm_address_t dst = (vm_address_t)ga; vm_prot_t cur, max;
    if (vm_remap(mach_task_self(), &dst, (vm_size_t)span, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)rw, FALSE, &cur, &max, VM_INHERIT_SHARE) != KERN_SUCCESS) return 0;
    if (prot != (VM_PROT_READ | VM_PROT_WRITE)) vm_protect(mach_task_self(), dst, (vm_size_t)span, FALSE, prot);
#endif
    g_sh[g_nsh].ga = ga; g_sh[g_nsh].n = n; g_sh[g_nsh].host = host; g_sh[g_nsh].rw = rw; g_nsh++;
    if (g_det == 2) { rec(E_MEM, (uint32_t)n, ga); rec_raw_pad(rw, n); }   // 起始内容进日志（重放的影子从全零起）
    LOG("确定性：共享内存 %#llx +%#llx 用影子副本（%s）", (unsigned long long)ga, (unsigned long long)n, g_det == 2 ? "记录" : "重放");
    return 1;
}
static void publish(void) {   // 持串行锁（记录档）
    uint64_t t = now_ns(); if (t - g_last_pub < 1000000) return; g_last_pub = t;
    for (int i = 0; i < g_nsh; i++) {
        const uint8_t *h = g_sh[i].host; uint8_t *r = g_sh[i].rw; uint64_t n = g_sh[i].n;
        for (uint64_t o = 0; o < n; ) {
            uint64_t k = n - o < 64 ? n - o : 64;
            if (!memcmp(h + o, r + o, k)) { o += k; continue; }
            uint64_t e = o + k; while (e < n && memcmp(h + e, r + e, n - e < 64 ? n - e : 64)) e += n - e < 64 ? n - e : 64;
            uint32_t len = (uint32_t)(e - o); uint8_t tmp[4096];
            for (uint32_t q = 0; q < len; q += sizeof tmp) { uint32_t m = len - q < sizeof tmp ? len - q : (uint32_t)sizeof tmp; memcpy(tmp, h + o + q, m); rec(E_MEM, m, g_sh[i].ga + o + q); rec_raw_pad(tmp, m); memcpy(r + o + q, tmp, m); }
            o = e;
        }
    }
}

// 宿主写游戏内存的待办：字节环（32 MB），项 = 地址 8 + 长度 8 + 数据（按 16 对齐）。持 g_ml 写入；持串行锁者放锁前按序写进游戏内存并记录。
// 记录跨环尾时按物理下标分两段读（det_mring.h）。不跨环尾时负载仍是环内指针，直接交给 mem_rec_apply，不拼、不多分配。
// 跨环尾才映射一块 16 MB 拼回缓冲（记录档，第一次遇到才建）。写入仍是逐字节取模，收进 mring_put。
#define MRING (32u << 20)
#include "det_mring.h"
static uint8_t *g_mr, *g_mr_scratch; static det_mutex g_ml = DET_MUTEX_INIT;
static _Atomic uint64_t g_mr_drop;
static void mem_rec_apply(uint64_t addr, const void *src, uint32_t len) {   // 持串行锁
    if (g_det == 2) { rec(E_MEM, len, addr); rec_raw_pad(src, len); }
    wr(addr, src, len);
}
static uint8_t *mring_scratch(uint32_t nlen) {   // 跨环尾拼回。写侧拒绝 len > 16 MB，进了环的负载不会更大
    if (nlen > (1u << 24)) die("确定性：跨环尾负载超过 16 MB");
    if (!g_mr_scratch) {
        g_mr_scratch = mmap(NULL, 1u << 24, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (g_mr_scratch == MAP_FAILED) die("确定性：跨环尾拼回缓冲");
    }
    return g_mr_scratch;
}
static void mq_drain(void) {   // 持串行锁
    det_mutex_lock(&g_ml);
    while (g_mr_r != g_mr_w) {
        uint64_t addr, len;
        mring_get(&addr, g_mr, MRING, g_mr_r, 8);
        mring_get(&len, g_mr, MRING, g_mr_r + 8, 8);
        uint32_t nlen = (uint32_t)len;
        uint64_t po = g_mr_r + 16;
        void *scratch = NULL;
        if (!mring_linear(g_mr, MRING, po, nlen) && nlen) scratch = mring_scratch(nlen);
        mem_rec_apply(addr, mring_payload(g_mr, MRING, po, nlen, scratch), nlen);
        g_mr_r += 16 + ((len + 15) & ~15ull);
    }
    det_mutex_unlock(&g_ml);
}
// 事件第一次对游戏可见时的状态（持锁游戏线程上，thread.c ev_expose 调，持 G）：记录档记一笔；重放档当场取录的状态
int s2a_det_event_state(uint32_t did, int signaled) {
    if (!t_held) return signaled;
    if (g_det == 2) rec(E_HOST, did, (uint64_t)signaled);
    else if (g_det == 3 && !atomic_load(&g_div)) {   // 持 G 调：不走代为生效（它要拿 G），当场取录的这一笔
        if (g_pos < g_pn && g_pl[g_pos].type == E_HOST && g_pl[g_pos].a == did) return (int)g_pl[g_pos++].v;
        diverge("事件首次可见时的状态项不在录的位置", E_HOST, did, (uint64_t)signaled);
    }
    return signaled;
}
int s2a_det_host_event(uint32_t id, int op) {   // 回 1：已接管（调用方别再改）；回 0：调用方照常改
    if (!g_det || t_held || !atomic_load(&g_started) || !id) return 0;   // 还没对游戏可见（id 0）的事件：直接改   // 确定性档关 / 游戏线程自己（含它的 C# 处理）改 / 开跑前初始化：位置本就确定
    if (g_det == 3) return 1;          // 重放：只认日志
    if (g_det == 1) return 0;          // 只串行：不记
    if (det_mutex_trylock(&g_gl)) { hq_drain(); host_rec_apply(id, op); det_mutex_unlock(&g_gl); return 1; }
    // 只公开真正有容量的票；满后退共享写游标会撤掉别人的票、留下无人填的空槽。
    uint32_t w = atomic_load(&g_hq_w);
    for (;;) {
        if (w - atomic_load(&g_hq_r) >= HQ) { atomic_fetch_add(&g_hq_drop, 1); return 0; }   // 队列满：照常改（不确定，计数）
        if (atomic_compare_exchange_weak(&g_hq_w, &w, w + 1)) break;
    }
    atomic_store(&g_hq[w % HQ], (uint64_t)id << 1 | (uint64_t)(op & 1));
    if (det_mutex_trylock(&g_gl)) { hq_drain(); det_mutex_unlock(&g_gl); }   // 刚好没人持锁：自己清
    return 1;
}

// 宿主写游戏内存（服务层 GuestMemory 的写、IPC 输出缓冲、GPU 回写）：确定性档关时直接写
void s2a_det_host_write(uint64_t addr, const void *src, uint64_t len) {
    if (!g_det || g_det == 1 || t_held || !len || !atomic_load(&g_started)) { memcpy((void *)addr, src, len); return; }   // 关 / 只串行 / 持锁游戏线程（含它的 C# 处理）/ 游戏开跑前的单线程初始化：直接写
    if (g_det == 3) return;                                                                      // 重放：只按日志写
    if (len > (1u << 24)) { memcpy((void *)addr, src, len); atomic_fetch_add(&g_mr_drop, 1); return; }
    if (det_mutex_trylock(&g_gl)) { hq_drain(); mq_drain(); mem_rec_apply(addr, src, (uint32_t)len); det_mutex_unlock(&g_gl); return; }
    det_mutex_lock(&g_ml);
    uint64_t need = 16 + ((len + 15) & ~15ull);
    if (g_mr_w - g_mr_r + need > MRING) { det_mutex_unlock(&g_ml); memcpy((void *)addr, src, len); atomic_fetch_add(&g_mr_drop, 1); return; }
    uint64_t h[2] = { addr, len };
    mring_put(g_mr, MRING, g_mr_w, h, 16);
    mring_put(g_mr, MRING, g_mr_w + 16, src, len);
    g_mr_w += need;
    det_mutex_unlock(&g_ml);
    if (det_mutex_trylock(&g_gl)) { hq_drain(); mq_drain(); det_mutex_unlock(&g_gl); }
}

// ---------- 不确定来源 ----------
uint64_t s2a_det_tick(uint64_t real) {
    if (g_det == 2) rec(E_TICK, 0, real);
    else if (g_det == 3) { const dent_t *e = play(E_TICK, 0, real); if (e) return e->v; }
    return real;
}
static uint64_t fnv(const void *p, size_t n, uint64_t h) { const uint8_t *b = p; for (size_t i = 0; i < n; i++) h = (h ^ b[i]) * 0x100000001b3ull; return h; }
static void rec_raw(const void *p, size_t n) {   // n 是 16 的倍数：按块直接跟在系统调用项后面
    for (size_t i = 0; i < n; i += 16) { memcpy(&g_rb[g_rn++], (const uint8_t *)p + i, 16);
        if (g_rn == RBUF) { ssize_t w = write(g_rfd, g_rb, (size_t)g_rn * 16); (void)w; g_rtotal += g_rn; g_rn = 0; } }
}
static void rec_raw_pad(const void *p, uint64_t len) { uint8_t blk[16]; for (uint64_t o = 0; o < len; o += 16) { uint64_t n = len - o < 16 ? len - o : 16; memset(blk, 0, 16); memcpy(blk, (const uint8_t *)p + o, n); rec_raw(blk, 16); } }
static _Atomic uint64_t g_overrides;
// Horizon 系统调用的输出寄存器个数（x0 = 结果码起算；表外只回结果码）。确定性档下 C# 处理的调用返回后，门把其余寄存器恢复成调用前的值
int s2a_det_out_regs(int num) {
    switch (num) {
    // x0 + x1
    case 0x01: case 0x06: case 0x08: case 0x0C: case 0x15: case 0x18: case 0x1F: case 0x24: case 0x25: case 0x29: case 0x30: case 0x31:
    case 0x41: case 0x43: case 0x44: case 0x50: case 0x6F: case 0x71: case 0x72: return 2;
    // x0 + x1 + x2
    case 0x0E: case 0x40: case 0x45: case 0x70: return 3;
    default: return 1;   // 其余只回结果码
    }
}
// 重放时允许用录的值覆盖的系统调用：结果本就随宿主变、但游戏要据此往下走的——GetInfo（内存用量 / 随机熵）、IPC 应答（服务回包，含时间 / 状态）
static int may_override(int num) { return num == 0x29 || num == 0x21 || num == 0x22 || num == 0x6F; }
void s2a_det_svc_done(int num, uint64_t *regs, void *msg) {   // msg：IPC 回包（TLR 前 0x100 字节），无则 NULL
    if (g_det < 2 || !t_held) return;
    // 只比输出寄存器：其余是调用方保存寄存器，游戏直调宿主 libc 后本就留着宿主地址（每局不同、游戏不读）
    uint64_t h = fnv(regs, 8 * (size_t)s2a_det_out_regs(num), 0xcbf29ce484222325ull); if (msg) h = fnv(msg, 0x100, h);
    uint32_t nb = 4 + (msg ? 16 : 0);
    if (g_det == 2) { rec(E_SVC, (uint32_t)num | nb << 16, h); rec_raw(regs, 64); if (msg) rec_raw(msg, 0x100); return; }
    const dent_t *e = play(E_SVC, (uint32_t)num | nb << 16, h);
    if (!e) return;
    if ((e->a & 0xffff) != (uint32_t)num || (e->a >> 16) != nb) { g_pos--; diverge("系统调用号 / 回包形态不同", E_SVC, (uint32_t)num, h); return; }
    const uint8_t *raw = (const uint8_t *)&g_pl[g_pos]; g_pos += nb;
    if (e->v == h) return;
    if (!may_override(num)) {
        const uint64_t *rr = (const uint64_t *)raw;
        LOG("确定性重放：系统调用 %#x 回参 录的 x0..x3 = %#llx %#llx %#llx %#llx，实际 = %#llx %#llx %#llx %#llx；x4..x7 录的 %#llx %#llx %#llx %#llx 实际 %#llx %#llx %#llx %#llx", num,
            (unsigned long long)rr[0], (unsigned long long)rr[1], (unsigned long long)rr[2], (unsigned long long)rr[3],
            (unsigned long long)regs[0], (unsigned long long)regs[1], (unsigned long long)regs[2], (unsigned long long)regs[3],
            (unsigned long long)rr[4], (unsigned long long)rr[5], (unsigned long long)rr[6], (unsigned long long)rr[7],
            (unsigned long long)regs[4], (unsigned long long)regs[5], (unsigned long long)regs[6], (unsigned long long)regs[7]);
        g_pos -= nb + 1; diverge("系统调用回参不同", E_SVC, (uint32_t)num, h); return;
    }
    memcpy(regs, raw, 64); if (msg) memcpy(msg, raw + 64, 0x100);
    if (atomic_fetch_add(&g_overrides, 1) < 8) LOG("确定性重放：系统调用 %#x 回参与录的不同，按录的覆盖（第 %llu 项）", num, (unsigned long long)g_pos);
}
// 阻塞结局：记录时记下、回实际；重放时回录的（被唤醒 = 1 / 超时 = 0），*want_res 给录的结果
int s2a_det_wait_outcome(int woke, int64_t res, int64_t *want_res) {
    if (g_det == 2) { rec(E_WAIT, (uint32_t)woke, (uint64_t)res); return woke; }
    if (g_det == 3) { const dent_t *e = play(E_WAIT, (uint32_t)woke, (uint64_t)res); if (e) { if (want_res) *want_res = (int64_t)e->v; return (int)e->a; } }
    return woke;
}
void s2a_det_diverge_note(const char *what) { if (g_det == 3) diverge(what, 0, 0, 0); }

// ---------- 看门狗（只串行档抢占；记录 / 重放档只计数，不抢：抢占点不确定）----------
// 信号现场取 PC：寄存器布局看「系统 × CPU 架构」两件事，不看 __ANDROID__（Linux x86_64 宿主单测也编本文件）
static uint64_t det_ctx_pc(void *ctx) {
    ucontext_t *uc = ctx;
#if defined(__APPLE__) && defined(__aarch64__)
    return uc->uc_mcontext->__ss.__pc;
#elif defined(__APPLE__) && defined(__x86_64__)
    return uc->uc_mcontext->__ss.__rip;
#elif defined(__linux__) && defined(__aarch64__)
    return uc->uc_mcontext.pc;
#elif defined(__linux__) && defined(__x86_64__)
    return (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
#else
#error "det.c：本系统 / 架构没有信号现场取 PC 的写法"
#endif
}
static void on_preempt(int sig, siginfo_t *si, void *ctx) {
    (void)sig; (void)si;
    if (!t_held) return;
    atomic_store(&g_pre_last_pc, det_ctx_pc(ctx));
    s2a_det_release();
    struct timespec ts = {0, 200000}; nanosleep(&ts, NULL);
    s2a_det_acquire();
}
static void *watchdog(void *a) {
    (void)a;
#if !defined(__APPLE__)
    pthread_setname_np(pthread_self(), "s2a-det-watch");
#else
    pthread_setname_np("s2a-确定性看门狗");
#endif
    for (;;) {
        struct timespec ts = {0, 20000000}; nanosleep(&ts, NULL);
        pthread_t o = atomic_load(&g_owner); uint64_t s = atomic_load(&g_since);
        if (o && s && now_ns() - s > g_slice_ns) {
            atomic_fetch_add(&g_preempts, 1); atomic_store(&g_since, now_ns());
            if (g_det != 1) continue;
            pthread_kill(o, SIGUSR2);
            struct timespec w = {0, 2000000}; nanosleep(&w, NULL);
            uint64_t pc = atomic_exchange(&g_pre_last_pc, 0);
            if (pc) { int k = 0; while (k < PRE_PCS && g_pre[k].pc && g_pre[k].pc != pc) k++; if (k < PRE_PCS) { g_pre[k].pc = pc; g_pre[k].n++; } }
        }
    }
    return NULL;
}
void s2a_det_init(void) {
    const char *r = getenv("S2A_DET_REC"), *p = getenv("S2A_DET_PLAY"), *e = getenv("S2A_DET");
#if defined(__ANDROID__) || defined(__OHOS__)
    // 产品默认仍是真并行。调试串行/重放尚无 Android 信号与跨线程验收，显式拒绝而非静默忽略。
    if ((r && *r) || (p && *p) || (e && *e == '1'))
        die("Android 尚不支持确定性串行/记录/重放；请使用默认并行运行");
#endif
    if (p && *p) {
        int fd = open(p, O_RDONLY); struct stat st;
        if (fd < 0 || fstat(fd, &st) || st.st_size < 16) die("确定性重放：打不开日志 %s", p);
        g_pl = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
        if (g_pl == MAP_FAILED) die("确定性重放：映射失败");
        g_pn = (uint64_t)st.st_size / 16; g_det = 3;
    } else if (r && *r) {
        g_rfd = open(r, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (g_rfd < 0) die("确定性记录：建不了 %s", r);
        g_rb = mmap(NULL, (size_t)RBUF * 16, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); if (g_rb == MAP_FAILED) die("确定性记录：缓冲");
        g_mr = mmap(NULL, MRING, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); if (g_mr == MAP_FAILED) die("确定性记录：内存待办环");
        g_det = 2;
    } else if (e && *e == '1') g_det = 1;
    if (!g_det) return;
    { const char *w = getenv("S2A_DET_WATCH"); if (w) g_watch = strtoull(w, NULL, 16); w = getenv("S2A_DET_WATCH_TURN"); if (w) g_watch_turn = strtoull(w, NULL, 10); }
    { const char *h = getenv("S2A_DET_HASH_EVERY"); if (h) g_hash_every = (uint64_t)atoll(h); }
    { const char *d = getenv("S2A_DET_DUMP"); if (d) { g_dump_ckpt = strtoull(d, NULL, 10); const char *c = strchr(d, ':'); if (c) g_dump_addr = strtoull(c + 1, NULL, 16);
        const char *f = p && *p ? p : r; snprintf(g_dump_pfx, sizeof g_dump_pfx, "%s", f ? f : "det"); } }
    const char *s = getenv("S2A_DET_SLICE_MS"); if (s && atoi(s) > 0) g_slice_ns = (uint64_t)atoi(s) * 1000000;
    { int e = plat_fault_install(SIGUSR2, on_preempt, PLAT_FAULT_ONSTACK | PLAT_FAULT_RESTART);
      if (e) LOG("【红】确定性：安装 SIGUSR2 失败 errno=%d", e); }
    pthread_t t; pthread_create(&t, NULL, watchdog, NULL); pthread_detach(t);
    LOG("确定性：%s；游戏线程串行，只在阻塞等待 / 睡眠%s处交接", g_det == 1 ? "串行" : g_det == 2 ? "记录" : "重放", g_det == 1 ? " / 读计数器" : "");
    if (g_det == 3) LOG("确定性重放：日志 %llu 项", (unsigned long long)g_pn);
#if !defined(__APPLE__)
    { Dl_info image; if (dladdr((void *)s2a_det_init, &image)) LOG("确定性：宿主 DSO 基址 %#llx", (unsigned long long)(uintptr_t)image.dli_fbase); }
#else
    { extern intptr_t _dyld_get_image_vmaddr_slide(uint32_t); LOG("确定性：宿主映像加载偏移 %#llx（游戏内存里出现的宿主地址减它再查符号表）", (unsigned long long)_dyld_get_image_vmaddr_slide(0)); }
#endif
}
void s2a_det_summary(void) {
    if (!g_det) return;
    if (g_det == 2) { ssize_t w = write(g_rfd, g_rb, (size_t)g_rn * 16); (void)w; g_rtotal += g_rn; g_rn = 0; LOG("确定性记录：写出 %llu 项", (unsigned long long)g_rtotal); }
    if (g_det == 2 && atomic_load(&g_mr_drop)) LOG("【红】确定性记录：宿主写内存待办满或过大 %llu 次（那几次直接写、没进日志）", (unsigned long long)atomic_load(&g_mr_drop));
    if (g_det == 2 && atomic_load(&g_hq_drop)) LOG("【红】确定性记录：宿主待办队列满 %llu 次（那几次触发没进日志）", (unsigned long long)atomic_load(&g_hq_drop));
    if (g_det == 3) LOG("确定性重放：按录的覆盖回参 %llu 次", (unsigned long long)atomic_load(&g_overrides));
    if (g_det == 3) LOG("确定性重放：%s，读到第 %llu / %llu 项", atomic_load(&g_div) ? "有分叉（见上）" : "到收局全一致", (unsigned long long)g_pos, (unsigned long long)g_pn);
    LOG("确定性汇总：交接 %llu 次，超时片 %llu 次（%s）", (unsigned long long)atomic_load(&g_handoffs), (unsigned long long)atomic_load(&g_preempts),
        g_det == 1 ? (atomic_load(&g_preempts) ? "强制让出过：游戏在两次交接之间长时间不进门" : "全程只在交接点交接") : "记录 / 重放档不抢占，只计数");
    void s2a_where(uint64_t a, char *b, size_t n);
    for (int k = 0; k < PRE_PCS && g_pre[k].pc; k++) { char b[160]; s2a_where(g_pre[k].pc, b, sizeof b); LOG("  强制让出 pc %s ×%u", b, g_pre[k].n); }
}
