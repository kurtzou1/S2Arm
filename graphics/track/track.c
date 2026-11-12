// 16 KB 页精确写跟踪（接口与语义见 s2a_track.h、设计.md）。迁自旧库 hle_sv_nvgpu_track.c（main 4f4c17b + 6aaed34 两处并发修复）
// 与性能线「精确地址免读回」补丁（run/arch/precise_noreadback_wip_1715.patch）的语义；排空改成一次交一批（每 NONE 子页一条 + 512 字节变动位图），
// 不再逐段回调（旧版暗黑2 一局 2039 万次托管调用、读回阻塞 4 → 1287 ms）。
//
// 粒度：Ryujinx 按 4 KB 子页要求保护；宿主页 16 KB，页内任一子页要保护即整页只读。游戏写到只读页：
//   · 被写的子页：READ 级记脏；NONE 级（GPU 改过）拍快照、排空时逐字节比；
//   · 同页其余要保护的子页（随整页解开而失去保护）：先记内容哈希、标「观察中」，排空时比对，变了才报脏，没变的重设只读。
// 不跟踪写（GPU 回写 / 信号量）写到的子页只在排空时重设只读，不报脏。
// 信号上下文约束（s2a_track_fault）：只用原子操作、memcpy 与 mprotect，不分配、不加锁。表的叶子在非信号路径（reprotect，持锁）分配、永不释放。
#include "s2a_track.h"
#include "../../runtime/include/s2a_lowva.h"
#include <dlfcn.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#else
#include "track_platform.h"
#include "../../platform/plat.h"
#include "../../android/native/runtime/tracking/mirror.h"   // 只读开关：关时下面两处写路径回到 main 原路径
#endif
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>   // psettle 排空比对 16 字节一次（见 psettle）
#endif
#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_time.h>
#endif

#define TLOG(...) do { fprintf(stderr, "[track] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define FATAL(...) do { TLOG("【红】" __VA_ARGS__); abort(); } while (0)

#define SUB 0x1000ull                                         // Ryujinx 跟踪粒度
#define S2A_ALIAS_STALE_MAX 8                                 // 镜像世代过期（ESTALE）的有界整段重试上限；耗尽照常 FATAL
#define S2A_ALIAS_BUSY_MAX (S2A_ALIAS_STALE_MAX * 4)          // 写者进入时撞上换页事务（EAGAIN）的有界等待/重试上限
#define LEAF_BITS 16                                          // 一片叶子 2^16 个宿主页（16 KB 页 = 1 GB）
#if defined(__APPLE__)
#define TOP_BITS (48 - 14 - LEAF_BITS)
#else
// Linux 支持 4 KiB 宿主页：同一 48 位地址域需要多两位页号，子页算法不变。
#define TOP_BITS (48 - 12 - LEAF_BITS)
#endif
#define LEAF_N (1u << LEAF_BITS)
enum { PG_RW = 0, PG_RO = 1, PG_BUSY = 2 };
typedef struct {
    _Atomic uint8_t state[LEAF_N];                            // 宿主页的实际权限状态
    _Atomic uint8_t want[LEAF_N];                             // 每宿主页各子页「Ryujinx 要保护」位（bit i = 第 i 个 4 KB）
    _Atomic uint8_t dirty[LEAF_N];                            // 待通知的脏子页位
    _Atomic uint8_t queued[LEAF_N];                           // 已进环
    _Atomic uint8_t lastp[LEAF_N];                            // 诊断：本模块最后一次对这页 mprotect 设的权限（PROT_*，0xff = 从没设过，0xfe = 外部改过）
    _Atomic uint8_t watch[LEAF_N];                            // 观察中的子页：随整页解开失去保护、仍要保护，排空时按内容哈希判写没写
    _Atomic uint8_t rearm[LEAF_N];                            // 不跟踪写刚解开、写完待记基线的子页（write_untracked 内转成观察中，不过夜）
    _Atomic uint8_t act[LEAF_N];                              // NONE 级子页（GPU 改过）
    _Atomic uint8_t psnap[LEAF_N];                            // 已拍快照、待排空比对的子页
    _Atomic uint8_t rfm[LEAF_N];                              // 定向读时回写页（s2a_track_mark_readflush 登记）：同 READFLUSH，只对这些页生效
    // 拦写模拟（docs/研究/拦写模拟.md）：vouch = 缓冲登记过「GPU 改过」；taint = 被非缓冲来源（贴图等）标过「GPU 改过」，一旦置上永不清；
    // ebits = 有模拟写待排空上报的子页。mmask = GPU 改过的字节表（每子页 64 位，1 位 64 字节，超集）；eslot = 「CPU 写过」位图槽号 + 1（0 = 没有）
    _Atomic uint8_t vouch[LEAF_N], taint[LEAF_N], ebits[LEAF_N];
#if !defined(__APPLE__)
    _Atomic uint64_t generation[LEAF_N];                     // Android：GPU重新脏化不能被旧skip/无进展判据吞掉
#endif
    _Atomic uint8_t reject[LEAF_N];                          // 过期缺页计数（0 = 首次按竞争/重执行；lastp 非 RW / 外部改过时 1 = 再缺页交回）；苹果自 10-28 审计 #806 起也用
    _Atomic uint64_t *_Atomic mmask;                          // LEAF_N × 8，开关开时分配（leaf_es_alloc，持 g_mu）；信号里原子读，NULL = 不模拟
    _Atomic uint16_t *_Atomic eslot;                          // LEAF_N × 8
    uint64_t *hash;                                           // 观察中子页的内容哈希（LEAF_N × 8）
    _Atomic uint16_t *slot;                                   // 待比对子页的快照槽号（LEAF_N × 8）
} leaf_t;
static _Atomic(leaf_t *) g_top[1u << TOP_BITS];
static uintptr_t g_pg, g_shift; static unsigned g_subs;       // 宿主页大小、位移、每页子页数（≤ 8）
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
#ifndef RING
#define RING 65536
#endif
static _Atomic uintptr_t g_ring[RING]; static _Atomic uint64_t g_rhead, g_rtail; static _Atomic int g_overflow;
// Production uses the safe publication protocol exclusively. The old
// protocol exists only as a compile-time negative control in test builds.
#if defined(S2A_TRACK_TEST_OLD_RING) && !defined(S2A_TRACK_TEST)
#error "S2A_TRACK_TEST_OLD_RING is only allowed in test builds"
#endif
#ifndef S2A_TRACK_TEST_OLD_RING
static _Atomic uint64_t g_rseq[RING];
static _Atomic unsigned g_rwriters;
static _Atomic int g_rreset;
#endif
#ifdef S2A_TRACK_TEST
void (*s2a_track_test_ring_reserved)(uintptr_t pn);
void (*s2a_track_test_ring_loaded)(void);
void (*s2a_track_test_ring_published)(void);
void (*s2a_track_test_ring_reset_wait)(void);
void (*s2a_track_test_ring_retired)(unsigned writers);
void (*s2a_track_test_overflow_visited)(uintptr_t pn);
// 镜像写路径钩子（#1184 D1 夹具）：别名到手 / 前提复核通过即将 memcpy / ESTALE 后即将重试。
// 夹具用它们把「写者在别名上」与「换页提交」排成确定的次序；生产构建没有这些调用点。
void (*s2a_track_test_write_alias_acquired)(void);
void (*s2a_track_test_write_alias_ready)(void);
void (*s2a_track_test_write_alias_retry)(void);
// 关路径单测（#1184 r4 第 2 条）：两处只在镜像开时走的新逻辑各记一次，关时必须保持 0。
_Atomic unsigned s2a_track_test_precise_preimages;    // restore_precise 取写前页像的次数
_Atomic unsigned s2a_track_test_write_alias_rechecks; // write_via_alias 拿到别名后复核 lastp/act 的次数
#endif
static _Atomic uint64_t g_faults, g_preps, g_events, g_mprotects, g_heals, g_races, g_watch_hit, g_watch_miss, g_rearms, g_overflows, g_mp_fail;
// 快照池：NONE 子页首次被写时拍 4 KB。按需增长：每块 8192 槽（32 MB），满了缺页里直接 mmap 下一块，最多 8 块（槽号 16 位，65536 槽 = 256 MB）；
// 排空时整块空了的附加块交还物理页（地址留着）。旧库马车8 2048 槽满退回 6993 次、8192 槽 71–91 次；10-21 S2Arm 马车8 载入阶段一次连写超 8192 子页
#define CHUNK 8192
#define MAXCHUNK 8
static uint8_t *_Atomic g_snapc[MAXCHUNK]; static _Atomic uint64_t g_slot_bits[MAXCHUNK][CHUNK / 64]; static int g_maxchunk = MAXCHUNK;
static _Atomic uint64_t g_snap_live, g_snap_peak, g_snap_chunks, g_snap_freed; static _Atomic uint8_t g_chunk_used[MAXCHUNK];
static inline uint8_t *snap_at(unsigned k) { return atomic_load(&g_snapc[k / CHUNK]) + (size_t)(k % CHUNK) * SUB; }
static _Atomic uint64_t g_psnaps, g_pfull, g_psame, g_pruns, g_pbytes, g_ucw_hit, g_ucw_inter, g_restore_b;
// 诊断 S2A_TRACK_READFLUSH=1（缺省关）：含 GPU 改过子页（act & want）的页设不可读，游戏代码读也先回写（Ryujinx 原版语义：NONE 级读写都拦）。
// 缺省只拦写（「精确地址免读回」：CPU 读 GPU 改过的数据拿到的是回写前的字节）——客体拿到 GPU 结果靠凑巧有一次写触发整页回写（八方2：GPU 线程写信号量顺带回写同页）。
// 开了以后宿主页（16 KB）里任一子页被读写都整页回写（⑳ 写邻居子页不回写在开时不成立），缺省要按九款读回 / 帧率定（10-22 帧率能耗线：八方2 Mac 配合信号量精确写 S2A_SEM_PRECISE=1 读回 11.5% → 0.0%、画面同现行）。
// 页状态仍是 PG_RO，lastp == PROT_NONE 即不可读。宿主代码（C# / 渲染器）读到不可读页不能改道：放成只读、不回写（= 缺省行为），计数
static int g_rf; static _Atomic uint64_t g_rf_flush, g_rf_hostread;
// 定向漏网计数（帧率能耗线 10-23 塞尔达站立陷地）：全局 READFLUSH 开着时，游戏读写到「没登记定向读时回写」的页上、所碰子页本身 GPU 改过还没回写的数据。
// 缺省（全局关）下这些读拿到旧值；九款在全局开的诊断局里此数为 0 = 定向登记覆盖了全部「GPU 写过、游戏又读」的类别
static _Atomic uint64_t g_rf_unmarked;
// 缺页处模拟读（方案 B，帧率能耗线 10-23）：缺省开（init_once 读 S2A_TRACK_EMUL），单测用 s2a_track_set_emul 切。g_rf_emul = 模拟放行的读次数，g_rf_partial = 只回写所碰子页的改道次数
static _Atomic int g_emul_on; static _Atomic uint64_t g_rf_emul, g_rf_partial;
// READFLUSH 宿主读放开的页：缺页里放成只读（宿主代码读不能改道回写），记进这个环，下次排空时按「还有没有 GPU 改过的子页」设回不可读（rf_apply）。
// 原先放开后一直可读，直到 Ryujinx 再改这页保护：之后客体读到的是回写前的旧字节（10-22 八方2：信号量精确写去掉整页回写后，地面成块发黑）
#define RFQ 4096
static _Atomic uintptr_t g_rfq[RFQ]; static _Atomic uint64_t g_rfq_h, g_rfq_t, g_rf_rearm; static _Atomic int g_rfq_over;
void s2a_track_set_readflush(int on) { g_rf = on; }
// 定向读时回写（帧率能耗线 10-22）：全局 READFLUSH 让九款读回暴涨（iPhone 同包：巫师3 0 → 44 s / 60 s、动森 0 → 14 s、暗黑2 3 → 24 s），
// 只有八方2 需要（自动曝光 1x1 GPU 读回与信号量同页）。改成只对登记过的页生效：信号量精确写打过洞的页、DMA 在 GPU 上读回贴图写进的目标页。
// g_rfm_any：有过登记才走这些分支（没登记时与缺省完全相同）
static _Atomic int g_rfm_any;
static _Atomic uint64_t g_rfm_pages;

// 拦写模拟开关（缺省开，S2A_TRACK_EMUL_STORE=0 关；init_once 读，单测 s2a_track_set_emul_store 切；必须在第一次 reprotect 之前定）
// 10-24 翻缺省：塞尔达测试设备2 同局交替（botw_1024080820_2，包 17045483e，S2A_ALT=20）开段 − 前后关段平均：读回 −152.6 ms/秒（约 −60%）、帧率 +0.65、功耗 +0.05 W（噪声底 0.30）；
//   开段每秒模拟约 1340–1390 次、每次 7.7 µs。动森同法中性（MARK 后没有可省的读回，开段 0 次模拟，功耗 −0.01 W）
static _Atomic int g_es_on;
static leaf_t *leaf_of(uintptr_t pn) { uintptr_t t = pn >> LEAF_BITS; return t < (1u << TOP_BITS) ? atomic_load_explicit(&g_top[t], memory_order_acquire) : NULL; }
#define LI(pn) ((pn) & (LEAF_N - 1))
static void leaf_es_alloc(leaf_t *l) {                        // 非信号路径（持 g_mu）：拦写模拟的字节表与位图槽号（先 eslot 后 mmask：信号里以 mmask 非空判可用）
    if (atomic_load(&l->mmask)) return;
    _Atomic uint16_t *e = calloc((size_t)LEAF_N * 8, sizeof *e); _Atomic uint64_t *m = calloc((size_t)LEAF_N * 8, sizeof *m);
    if (!e || !m) FATAL("页表叶子分配失败（拦写模拟）");
    atomic_store(&l->eslot, e); atomic_store(&l->mmask, m);
}
static leaf_t *leaf_make(uintptr_t pn) {                      // 非信号路径（持 g_mu）
    leaf_t *l = leaf_of(pn); if (l) return l;
    uintptr_t t = pn >> LEAF_BITS; if (t >= (1u << TOP_BITS)) return NULL;
    l = calloc(1, sizeof *l); int which = 0, er = 0;
    if (!l) { which = 1; er = errno; }
    else if (!(l->hash = calloc((size_t)LEAF_N * 8, sizeof *l->hash))) { which = 2; er = errno; }
    else if (!(l->slot = calloc((size_t)LEAF_N * 8, sizeof *l->slot))) { which = 3; er = errno; }
    if (which) {   // 说清是哪一块、多大、为什么（10-27 地址空间线：巫师3 直连局低区还有 1955 MB 空洞时它失败，原因不明）
#if defined(__APPLE__)
        task_vm_info_data_t vi; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; int got = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) == KERN_SUCCESS;
        FATAL("页表叶子分配失败：第 %d 块（%zu 字节；1 = 叶子本体 2 = 哈希 3 = 快照槽）errno=%d，叶子号 %#lx；进程常驻 %llu MB、实占 %llu MB、虚拟 %llu GB",
              which, which == 1 ? sizeof *l : which == 2 ? (size_t)LEAF_N * 8 * sizeof *l->hash : (size_t)LEAF_N * 8 * sizeof *l->slot, er, (unsigned long)t,
              got ? (unsigned long long)(vi.resident_size >> 20) : 0, got ? (unsigned long long)(vi.phys_footprint >> 20) : 0, got ? (unsigned long long)(vi.virtual_size >> 30) : 0);
#else
        FATAL("页表叶子分配失败：第 %d 块（%zu 字节；1 = 叶子本体 2 = 哈希 3 = 快照槽）errno=%d，叶子号 %#lx",
              which, which == 1 ? sizeof *l : which == 2 ? (size_t)LEAF_N * 8 * sizeof *l->hash : (size_t)LEAF_N * 8 * sizeof *l->slot, er, (unsigned long)t);
#endif
    }
    if (atomic_load(&g_es_on)) leaf_es_alloc(l);
    memset((void *)l->lastp, 0xff, sizeof l->lastp);
    atomic_store_explicit(&g_top[t], l, memory_order_release); return l;
}
static void sigsafe_hex(const char *tag, uint64_t v) { char b[192]; int n = 0; for (const char *t = tag; *t && n < 160; ) b[n++] = *t++; for (int i = 60; i >= 0; i -= 4) b[n++] = "0123456789abcdef"[(v >> i) & 15]; b[n++] = ' '; write(2, b, (size_t)n); }
// Apple 现有 Mach 权限查询；Android 缺页路径不查询 /proc/self/maps。
#if defined(__APPLE__)
static int kern_prot(uintptr_t pn) {
    vm_address_t a = (vm_address_t)(pn << g_shift); vm_size_t sz = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &o) != KERN_SUCCESS || a > (vm_address_t)(pn << g_shift)) return -1;
    return info.protection;
}
#endif
// 累计设成非可读写的宿主页数（双轨：直连模式下 graphics/track 不保护任何页，直连局收局读数应恒为 0；累计数比「此刻在保护的页数」更强）
static _Atomic uint64_t g_prot_pages;
uint64_t s2a_track_protected_pages(void) { return atomic_load(&g_prot_pages); }
// 改一页保护：0 成功；-1 失败（只在苹果上返回：记账保护已改回调用前的值，调用方不得发布这次改动——审计 #836 F-apple-mp-lastp）
static int mp(uintptr_t pn, int prot) {
    leaf_t *l = leaf_of(pn); uint8_t old = l ? atomic_load(&l->lastp[LI(pn)]) : 0;
    if (l) atomic_store(&l->lastp[LI(pn)], (uint8_t)prot);
    if (mprotect((void *)(pn << g_shift), g_pg, prot)) { int e = errno; if (atomic_fetch_add(&g_mp_fail, 1) < 8) { sigsafe_hex("[track] 【红】mprotect 失败 addr=", (uint64_t)(pn << g_shift)); sigsafe_hex("prot=", (uint64_t)prot); sigsafe_hex("errno=", (uint64_t)e); write(2, "\n", 1); }
#if !defined(__APPLE__)
        // Android 不把未落地的保护发布为成功；本函数也用于信号上下文。
        _exit(125);
#endif
        if (l) atomic_store(&l->lastp[LI(pn)], old);
        return -1;
    }
    if (prot != (PROT_READ | PROT_WRITE)) atomic_fetch_add(&g_prot_pages, 1);
    atomic_fetch_add(&g_mprotects, 1); return 0; }
static void enqueue(leaf_t *l, uintptr_t pn) {
#ifdef S2A_TRACK_TEST_OLD_RING
    uint8_t z = 0; if (!atomic_compare_exchange_strong(&l->queued[LI(pn)], &z, 1)) return;
    uint64_t h = atomic_fetch_add(&g_rhead, 1);
    if (h - atomic_load(&g_rtail) >= RING) { atomic_store(&g_overflow, 1); return; }   // 满：排空时报溢出
#ifdef S2A_TRACK_TEST
    if (s2a_track_test_ring_reserved) s2a_track_test_ring_reserved(pn);
#endif
    atomic_store(&g_ring[h % RING], pn + 1);
#ifdef S2A_TRACK_TEST
    if (s2a_track_test_ring_published) s2a_track_test_ring_published();
#endif
#else
    atomic_fetch_add(&g_rwriters, 1);
    if (atomic_load(&g_rreset)) {
        // No waits/locks in the signal path. This write requires another scan,
        // including when recovery has already visited this particular page.
        atomic_store(&g_overflow, 1); atomic_fetch_sub(&g_rwriters, 1); return;
    }
    uint8_t z = 0;
    if (!atomic_compare_exchange_strong(&l->queued[LI(pn)], &z, 1)) { atomic_fetch_sub(&g_rwriters, 1); return; }
    uint64_t h = atomic_load(&g_rhead);
    for (;;) {
        if (h - atomic_load(&g_rtail) >= RING) {
            atomic_store(&g_overflow, 1); atomic_fetch_sub(&g_rwriters, 1); return;
        }
        if (atomic_compare_exchange_weak(&g_rhead, &h, h + 1)) break;
    }
#ifdef S2A_TRACK_TEST
    if (s2a_track_test_ring_reserved) s2a_track_test_ring_reserved(pn);
#endif
    atomic_store(&g_ring[h % RING], pn + 1);
    atomic_store(&g_rseq[h % RING], h + 1);
#ifdef S2A_TRACK_TEST
    if (s2a_track_test_ring_published) s2a_track_test_ring_published();
#endif
    atomic_fetch_sub(&g_rwriters, 1);
#endif
}

// 子页内容哈希 = 各 8 字节字按位置混合后求和（模 2^64）：hmix 对固定位置是双射，任一个字变了和必变；
// 可按字增量更新——小的不跟踪写只重算写到的那几个字（s2a_track_write_untracked），不必整页重算。纯计算，信号上下文可用
static inline uint64_t hmix(uint64_t w, unsigned i) {
    uint64_t z = w + (uint64_t)(i + 1) * 0x9e3779b97f4a7c15ull;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull; z = (z ^ (z >> 27)) * 0x94d049bb133111ebull; return z ^ (z >> 31);
}
static _Atomic uint64_t g_hash_bytes;   // 诊断 / 单测：累计算过哈希的字节数
uint64_t s2a_track_hash_bytes(void) { return atomic_load(&g_hash_bytes); }
static uint64_t words_hash(uintptr_t sa, unsigned w0, unsigned w1) {   // 子页 sa 里第 w0..w1-1 个字的哈希贡献
    atomic_fetch_add_explicit(&g_hash_bytes, (uint64_t)(w1 - w0) * 8, memory_order_relaxed);
    const uint64_t *p = (const uint64_t *)sa; uint64_t h = 0;
    for (unsigned i = w0; i < w1; i++) h += hmix(p[i], i);
    return h;
}
static uint64_t sub_hash(uintptr_t a) { return words_hash(a, 0, SUB / 8); }   // 一个 4 KB 子页的内容哈希
// 信号上下文可用：原子位图找空槽；已有的块都满了就 mmap 下一块（系统调用，不 malloc、不拿锁；两线程同时扩时输的那份放掉）
static void (*g_lowva_note)(int, int64_t); static int g_lowva_id;   // 低区账（原生层 s2a_lowva.h）：只记账归因，note 无锁可在信号里调
static int slot_get(void) {
    for (int c = 0; c < g_maxchunk; c++) {
        if (!atomic_load(&g_snapc[c])) {
            uint8_t *p = mmap(NULL, (size_t)CHUNK * SUB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (p == MAP_FAILED) return -1;
            uint8_t *exp = NULL;
            if (atomic_compare_exchange_strong(&g_snapc[c], &exp, p)) { atomic_fetch_add(&g_snap_chunks, 1); if (g_lowva_note) g_lowva_note(g_lowva_id, (int64_t)CHUNK * SUB); }
            else munmap(p, (size_t)CHUNK * SUB);
        }
        for (unsigned w = 0; w < CHUNK / 64; w++) { uint64_t b = atomic_load(&g_slot_bits[c][w]);
            while (~b) { unsigned i = (unsigned)__builtin_ctzll(~b);
                if (atomic_compare_exchange_weak(&g_slot_bits[c][w], &b, b | (1ull << i))) {
                    uint64_t lv = atomic_fetch_add(&g_snap_live, 1) + 1, pk = atomic_load(&g_snap_peak);
                    while (lv > pk && !atomic_compare_exchange_weak(&g_snap_peak, &pk, lv)) {}
                    atomic_store(&g_chunk_used[c], 1); return (int)(c * CHUNK + w * 64 + i); } } }
    }
    return -1; }
static void slot_put(int k) { atomic_fetch_and(&g_slot_bits[k / CHUNK][(k % CHUNK) / 64], ~(1ull << (k % 64))); atomic_fetch_sub(&g_snap_live, 1); }
// 排空收尾（非信号路径）：附加块整块空了就交还物理页。先把它的位图字从 0 原子占成全 1（占位期间缺页看它是满的、去别的块），交还完再放开；
// 占不全（有字非 0 = 正有人用）就把占到的放回、这块不动
static void snap_release_idle(void) {
    for (int c = 1; c < MAXCHUNK; c++) {
        uint8_t *p = atomic_load(&g_snapc[c]); if (!p || !atomic_load(&g_chunk_used[c])) continue;
        unsigned w = 0; for (; w < CHUNK / 64; w++) { uint64_t z = 0; if (!atomic_compare_exchange_strong(&g_slot_bits[c][w], &z, ~0ull)) break; }
        if (w == CHUNK / 64) { atomic_store(&g_chunk_used[c], 0);
#if defined(__APPLE__)
            madvise(p, (size_t)CHUNK * SUB, MADV_FREE_REUSABLE);
#else
            if (s2a_track_platform_discard(p, (size_t)CHUNK * SUB)) FATAL("释放空快照页失败");
#endif
            atomic_fetch_add(&g_snap_freed, 1); }
        while (w--) atomic_store(&g_slot_bits[c][w], 0);
    }
}

static inline int rf_on(leaf_t *l, uintptr_t pn) { return g_rf || (l && atomic_load(&l->rfm[LI(pn)])); }
uint64_t s2a_track_page_info(uint64_t addr) {   // 诊断（s2a_track.h）：只读各字段，不取锁
    if (!g_pg) return UINT64_MAX;
    uintptr_t pn = (uintptr_t)addr >> g_shift; leaf_t *l = leaf_of(pn); if (!l) return UINT64_MAX;
    return (uint64_t)atomic_load(&l->state[LI(pn)]) | (uint64_t)atomic_load(&l->lastp[LI(pn)]) << 8 | (uint64_t)atomic_load(&l->act[LI(pn)]) << 16
         | (uint64_t)atomic_load(&l->want[LI(pn)]) << 24 | (uint64_t)(rf_on(l, pn) ? 1 : 0) << 32 | (uint64_t)atomic_load(&l->dirty[LI(pn)]) << 40;
}
// READFLUSH：已受保护（PG_RO）的页按「有没有 GPU 改过的子页」设不可读 / 只读（非信号路径）
static void rf_apply(leaf_t *l, uintptr_t pn) {
    if (!l || !rf_on(l, pn)) return;
    int want_na = (atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)])) != 0, is_na = atomic_load(&l->lastp[LI(pn)]) == PROT_NONE;
    if (want_na == is_na) return;
    uint8_t st = PG_RO; if (!atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) return;
    mp(pn, want_na ? PROT_NONE : PROT_READ); atomic_store(&l->state[LI(pn)], PG_RO);
}
// 把页解成可写（缺页 / 写前两条路径共用）。wmask = 这次被写的子页；core = 1 表示不跟踪写（不算 CPU 写）。返回 1 = 本模块的页
static int unprotect(uintptr_t pn, uint8_t wmask, int core) {
    leaf_t *l = leaf_of(pn); if (!l) return 0;
    for (;;) {
        uint8_t st = PG_RO;
        if (atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) {
            if (atomic_load(&l->lastp[LI(pn)]) == PROT_NONE && mp(pn, PROT_READ)) { atomic_store(&l->state[LI(pn)], PG_RO); return 0; }   // READFLUSH 的不可读页：下面要读内容拍快照 / 算哈希
            uint8_t w = atomic_exchange(&l->want[LI(pn)], 0), hit = w & wmask, other = w & (uint8_t)~wmask;
            // NONE 子页：页仍只读，拍快照，排空时按字节比（不记脏、不观察）。已有待比对快照的不重拍（旧快照才是比对基准）。
            // 不跟踪写写到的也拍：回写字节在比对里也算「写了」、按精确写报（值与 GPU 一致，重传同样数据，无害），换来回写之后到排空之间 CPU 的写不漏
            uint8_t pa = (uint8_t)(atomic_load(&l->act[LI(pn)]) & w), pold = pa & atomic_load(&l->psnap[LI(pn)]), ps = pa & (uint8_t)~pold;
            for (unsigned s = 0; s < g_subs; s++) if (ps >> s & 1) {
                int k = slot_get();
                if (k < 0) {   // 槽满：退回普通脏子页——Ryujinx 收到会先回写，盖掉 CPU 已写的字节。每次都报红带地址（安全阀，不许静默）
#if !defined(__APPLE__)
                    sigsafe_hex("[track] 【红】快照耗尽，拒绝丢失CPU写 addr=", (uint64_t)((pn << g_shift) + s * SUB)); write(2, "\n", 1); _exit(125);
#endif
                    ps &= (uint8_t)~(1u << s); if (atomic_fetch_add(&g_pfull, 1) < 16) { sigsafe_hex("[track] 【红】快照槽满，退回普通脏子页 addr=", (uint64_t)((pn << g_shift) + s * SUB)); write(2, "\n", 1); }
                    continue; }
                memcpy(snap_at((unsigned)k), (const void *)((pn << g_shift) + s * SUB), SUB); l->slot[(size_t)LI(pn) * 8 + s] = (uint16_t)k; atomic_fetch_add(&g_psnaps, 1); }
            atomic_fetch_or(&l->psnap[LI(pn)], ps); hit &= (uint8_t)~(ps | pold); other &= (uint8_t)~(ps | pold);
            if (core) atomic_fetch_or(&l->rearm[LI(pn)], hit); else atomic_fetch_or(&l->dirty[LI(pn)], hit);
            for (unsigned s = 0; s < g_subs; s++) if (other >> s & 1) l->hash[(size_t)LI(pn) * 8 + s] = sub_hash((pn << g_shift) + s * SUB);   // 页仍只读：内容就是设保护时的
            atomic_fetch_or(&l->watch[LI(pn)], other);
            if (mp(pn, PROT_READ | PROT_WRITE)) { atomic_store(&l->state[LI(pn)], PG_RO); return 0; }   // 升不了可写：不当成功重执行（会空转），交回调用方
            atomic_store(&l->state[LI(pn)], PG_RW);
            enqueue(l, pn); return 1;
        }
        if (st == PG_RW) return 1;   // 已可写（别的线程刚解开）：重执行即可
        // BUSY：等落地
    }
}
// ---------- GPU 改过页的 CPU 首写：先同步回写再放行（A 方案，Ryujinx 原版语义）----------
// 游戏代码写到含 NONE 子页（GPU 改过、数据还在 GPU 侧）的页：不拍快照、不事后合并（同值写认不出，回写会把 CPU 刚写的字节盖回旧值——
// 八方2 取码超页、动森调度器链表 / 锁字被回滚，10-20），而是请原生层把这条线程改道到宿主正常上下文调 s2a_track_touch：
// 逐个 NONE 子页通知 Ryujinx（VirtualMemoryEvent，被写的那个按写、其余按读），Ryujinx 当场把 GPU 数据回写进游戏内存并改保护，
// 回来后重执行那条写——次序与原版「缺页里先回写、再让 CPU 写」相同。没登记回调（单测 / 对拍工具）或改道不了时退回原快照路径
static _Atomic uint64_t g_touches, g_touch_subs;
static void (*g_touch)(uint64_t addr, uint64_t size, int write);
// 回调进行中（本线程正替 Ryujinx 回写）：回写自己经托管写进游戏内存（GetWritableRegion → s2a_track_write）不是 CPU 写，不得再触发回写——
// 否则贴图回写写一页、又触发同页回写，无限递归到栈耗尽（10-20 动森冷局第 74 帧）。只在正常上下文读写，信号路径不碰
static __thread int t_in_touch;
// 回写期间 Ryujinx 自己改过保护的子页（s2a_track_reprotect 记，只记 t_rf_pn 那一页）：部分回写后只把它没碰过的子页设回「GPU 改过」。
// Ryujinx 贴图回写按句柄整段回写、改保护，可能连带同页别的子页；这些已回写的再设回 GPU 改过，游戏读它们就缺页 → 改道 → Ryujinx 无可回写不改保护
// → 又设回，同一条读原地空转（10-23 Mac 塞尔达方案 B 首局第 569 帧卡死）
static __thread uintptr_t t_rf_pn; static __thread uint8_t t_rf_reprot;
static void touch_cb(uint64_t a, uint64_t n, int w) { t_in_touch++; g_touch(a, n, w); t_in_touch--; atomic_fetch_add(&g_touch_subs, 1); }

void s2a_track_set_touch(void (*cb)(uint64_t addr, uint64_t size, int write)) { g_touch = cb; }
void s2a_track_set_emul(int on) { atomic_store(&g_emul_on, on); }
// 信号里调：游戏读到读时回写的不可读页、碰的 4 KB 子页本身不是 GPU 改过的 → 1（可以试模拟读）。模拟没开 / 页不是这种状态 → 0
int s2a_track_read_emulable(void *addr) {
    if (!atomic_load(&g_emul_on) || !g_pg || !(g_rf || atomic_load(&g_rfm_any))) return 0;
    uintptr_t pn = (uintptr_t)addr >> g_shift; leaf_t *l = leaf_of(pn);
    if (!l || atomic_load(&l->state[LI(pn)]) == PG_RW || atomic_load(&l->lastp[LI(pn)]) != PROT_NONE) return 0;
    uint8_t aw = atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)]);
    return aw && !(aw >> (((uintptr_t)addr & (g_pg - 1)) / SUB) & 1);
}
// 信号里调（s2a_emul_load 的判定回调）：[ea, ea+len) 碰到的子页没有一个是 GPU 改过的 → 1
int s2a_track_emul_ok(uint64_t ea, uint64_t len) {
    if (!len) return 1;
    uintptr_t pn = (uintptr_t)ea >> g_shift; leaf_t *l = leaf_of(pn); if (!l || ((ea + len - 1) >> g_shift) != pn) return 0;
    uint8_t aw = atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)]);
    for (uint64_t s = (ea & (g_pg - 1)) / SUB; s <= ((ea + len - 1) & (g_pg - 1)) / SUB; s++) if (aw >> s & 1) return 0;
    return 1;
}
void s2a_track_note_emul(void) { atomic_fetch_add(&g_rf_emul, 1); }
// 模拟不了的读（信号里调）：按类别计（-1 = 别名建不出；0–8 见 s2a_emul_class），另记最近 16 种指令字 × 次数（pc 取第一次见到的）
static _Atomic uint64_t g_ef_cls[10]; static _Atomic uint32_t g_ef_insn[16]; static _Atomic uint64_t g_ef_n[16], g_ef_pc[16];
void s2a_track_note_emul_fail(int cls, uint32_t insn, uint64_t pc) {
    atomic_fetch_add(&g_ef_cls[cls < 0 ? 9 : cls > 8 ? 0 : cls], 1);
    for (unsigned i = (insn * 2654435761u) >> 28, k = 0; k < 16; i = (i + 1) & 15, k++) {
        uint32_t z = 0;
        if (atomic_load(&g_ef_insn[i]) == insn || atomic_compare_exchange_strong(&g_ef_insn[i], &z, insn)) { if (!atomic_load(&g_ef_pc[i])) atomic_store(&g_ef_pc[i], pc); atomic_fetch_add(&g_ef_n[i], 1); return; }
    }
}
int s2a_track_fault_guest(void *addr, int is_write, uint64_t skip) {   // 2 = 请改道（调用方随后在正常上下文调 s2a_track_touch）
#if !defined(__APPLE__)
    // 地址不能证明仍是同一次GPU写；Android完整读回路径每次都按当前脏态处理。
    skip = 0;
#endif
    // skip = 本线程刚为之回写过的页内任一地址（0 = 无）：重执行仍缺页（Ryujinx 没改保护）就走原路径，不反复改道。信号路径不碰线程局部变量（macOS 首次访问会分配）
    if ((g_rf || atomic_load(&g_rfm_any)) && g_pg && g_touch) {   // READFLUSH（全局或定向）：不可读页上的读或写都先回写整页的 GPU 改过子页（读不知道读的是哪个子页之外的字节，宁多勿漏）
        uintptr_t pn = (uintptr_t)addr >> g_shift; leaf_t *l = leaf_of(pn);
        if (l && (!skip || pn != (uintptr_t)skip >> g_shift) && atomic_load(&l->state[LI(pn)]) != PG_RW && atomic_load(&l->lastp[LI(pn)]) == PROT_NONE
            && (atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)]))) return 2;
    }
    if (g_pg && is_write && g_touch) {
        uintptr_t pn = (uintptr_t)addr >> g_shift; leaf_t *l = leaf_of(pn);
        // 只看被写的那个 4 KB 子页：它本身是 GPU 改过才改道（Ryujinx 原版按 4 KB 跟踪，写邻居子页不触发回写）。同一 16 KB 宿主页上别的 GPU 改过子页不回写——
        // 10-20 动森：CPU 每帧写渲染目标首 / 尾紧挨着的数据，按整页回写每帧把两张 1920×1080 渲染目标整片读回（测试设备2 读回 9.5 秒 / 60 秒）。
        // 那些子页随整页解开、照原路径拍快照，CPU 真写了才在排空时报
        unsigned fs = (unsigned)(((uintptr_t)addr & (g_pg - 1)) / SUB);
        if (l && (!skip || pn != (uintptr_t)skip >> g_shift) && atomic_load(&l->state[LI(pn)]) != PG_RW && ((atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)])) >> fs & 1)) return 2;
    }
    return s2a_track_fault(addr, is_write);
}
void s2a_track_touch(uint64_t addr) {
    uintptr_t pn = (uintptr_t)addr >> g_shift; leaf_t *l = leaf_of(pn); if (!l) return;
    unsigned fs = (unsigned)((addr & (g_pg - 1)) / SUB);
    if ((g_rf || atomic_load(&g_rfm_any)) && atomic_load(&l->lastp[LI(pn)]) == PROT_NONE) {   // READFLUSH（全局或定向）：整页 GPU 改过子页按读回写（Ryujinx 回写后改保护，页降回只读，重执行）
#if !defined(__APPLE__)
        uint64_t generation = atomic_load(&l->generation[LI(pn)]);
#endif
        uint8_t aw = atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)]), fl = aw;
        // 读指令模拟开着（原生层有可读别名）：只回写这次访问可能覆盖的子页（缺页地址起 64 字节 = 最长一条读 LD4 .2D ×4），
        // 同页别的 GPU 改过子页留着、页保持不可读；之后游戏读那些没改过的子页由缺页处模拟读放行，不再整页回写（16 KB 宿主页 / 4 KB 子页的假共享）。
        // 覆盖范围里一个 GPU 改过子页都没有（模拟不了的指令碰到没改过的子页）：退回整页回写，保证重执行能前进
        if (atomic_load(&g_emul_on)) {
            uintptr_t pb = pn << g_shift; unsigned s0 = (unsigned)((addr - pb) / SUB), s1 = (unsigned)(((addr + 63 < pb + g_pg ? addr + 63 : pb + g_pg - 1) - pb) / SUB);
            uint8_t m = 0; for (unsigned s = s0; s <= s1; s++) m |= (uint8_t)(1u << s);
            if (aw & m) { fl = aw & m; atomic_fetch_add(&g_rf_partial, 1); }
        }
        t_rf_pn = pn + 1; t_rf_reprot = 0;
        for (unsigned s = 0; s < g_subs; s++) if (fl >> s & 1) touch_cb((pn << g_shift) + s * SUB, SUB, 0);
        uint8_t ryu = t_rf_reprot; t_rf_pn = 0;
        // 保证前进：请 Ryujinx 回写的子页它没改保护（它那边已没有可回写的），我方不再拦它——降为只跟踪写，重执行不再缺页
        if (fl != aw) for (unsigned s = 0; s < g_subs; s++) if ((fl & ~ryu) >> s & 1) s2a_track_reprotect((pn << g_shift) + s * SUB, SUB, S2A_TRACK_READ);
        // 只回写了一部分：回写经托管写（贴图 GetWritableRegion → s2a_track_write）会把整页解开、同页别的 GPU 改过子页的拦截意图一起清掉，
        // 回写完 Ryujinx 再按只读改保护，页就成了可读——游戏再读那些子页不缺页、拿旧值（t_track ㉖ 反证）。
        // 照 Ryujinx 自己的意图把它们重新设回「GPU 改过」（同 Ryujinx 发 Reprotect(None)），页随之回到不可读
        if (fl != aw) for (unsigned s = 0; s < g_subs; s++) if ((aw & ~fl & ~ryu) >> s & 1 && (atomic_load(&l->act[LI(pn)]) >> s & 1)) s2a_track_reprotect((pn << g_shift) + s * SUB, SUB, S2A_TRACK_NONE);
#if !defined(__APPLE__)
        // 回调必须完成本次读回；同期真实新GPU写会提升generation，下一次fault重新处理。
        uint8_t unresolved = atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)]) & fl;
        // 新写先提升generation再发布act；先读脏态、最后读generation，避免把同期新写误判成旧状态。
        uint64_t completed_generation = atomic_load(&l->generation[LI(pn)]);
        if (!atomic_load(&g_emul_on) && unresolved && generation == completed_generation)
            FATAL("GPU读回回调未解除旧脏态，拒绝重复改道或读取旧值 addr=%#llx page=%#llx generation=%llu/%llu requested=%#x unresolved=%#x reprotected=%#x state=%u protection=%u",
                (unsigned long long)addr, (unsigned long long)(pn << g_shift),
                (unsigned long long)generation, (unsigned long long)completed_generation,
                fl, unresolved, ryu, atomic_load(&l->state[LI(pn)]), atomic_load(&l->lastp[LI(pn)]));
#endif
        uint64_t n = atomic_fetch_add(&g_rf_flush, 1) + 1; if (n <= 3 || (n & (n - 1)) == 0) TLOG("READFLUSH：游戏读 / 写不可读页先回写：第 %llu 次，本次 %#llx", (unsigned long long)n, (unsigned long long)addr);
        // 只算游戏碰的那个 4 KB 子页本身有 GPU 改过、还没回写的数据（= 缺省下真读到旧值）；同一 16 KB 宿主页上别的子页是 GPU 改过的只算假共享
        if (g_rf && !atomic_load(&l->rfm[LI(pn)]) && (aw >> fs & 1)) {
            uint64_t u = atomic_fetch_add(&g_rf_unmarked, 1) + 1;
            if (u <= 3 || (u & (u - 1)) == 0) TLOG("READFLUSH：定向没登记的页被游戏读写（缺省下读到旧值）：第 %llu 次，本次 %#llx", (unsigned long long)u, (unsigned long long)addr);
        }
        return;
    }
    if ((atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)])) >> fs & 1) touch_cb((pn << g_shift) + fs * SUB, SUB, 1);   // 只回写被写的子页
    uint64_t n = atomic_fetch_add(&g_touches, 1) + 1; if (n <= 3 || (n & (n - 1)) == 0) TLOG("GPU 改过页的 CPU 首写先回写：第 %llu 次（子页累计 %llu），本次 %#llx", (unsigned long long)n, (unsigned long long)atomic_load(&g_touch_subs), (unsigned long long)addr);
}
// 诊断 S2A_TRACK_HOSTREAD_BT=1（缺省关）：宿主读不可读页时沿帧指针打调用链（前 32 次，每次 16 层），查是哪段宿主代码读 GPU 改过、还没回写的页。
// 信号上下文：只读栈上帧记录、write(2)，不分配不加锁；地址按主程序装载地址换成偏移（atos -o <宿主> -l 0x100000000 符号化）
static int g_hrbt = -1;
static void rf_hostread_bt(void) {
    if (g_hrbt < 0) { const char *e = getenv("S2A_TRACK_HOSTREAD_BT"); g_hrbt = e && *e == '1'; }
    static _Atomic int n; if (!g_hrbt || atomic_fetch_add(&n, 1) >= 32) return;
#if defined(__APPLE__)
    uint64_t base = (uint64_t)(uintptr_t)_dyld_get_image_header(0);
#else
    uint64_t base = 0;   // Linux 诊断保留绝对地址，不在信号上下文调用动态加载器。
#endif
    write(2, "[track] 宿主读不可读页调用链", sizeof "[track] 宿主读不可读页调用链" - 1);
    uintptr_t *fp = __builtin_frame_address(0);
    for (int i = 0; i < 16 && fp && ((uintptr_t)fp & 7) == 0; i++) {
        uintptr_t lr = fp[1] & 0x0000ffffffffffffull; if (!lr) break;
        sigsafe_hex(lr >= base && lr < base + 0x10000000 ? " ← 主程序+" : " ← 绝对 ", lr >= base && lr < base + 0x10000000 ? lr - base : lr);
        uintptr_t *nx = (uintptr_t *)fp[0]; if (nx <= fp) break; fp = nx;
    }
    write(2, "\n", 1);
}
#ifdef S2A_TRACK_TEST
// 单测钩子（t_track ㉚）：s2a_track_fault 读记账快照后 / 两条分支之间调，模拟别的线程在这一刻改了页保护
void (*s2a_track_test_hook)(uintptr_t pn); void (*s2a_track_test_hook2)(uintptr_t pn);
void (*s2a_track_test_heal_claim)(uintptr_t pn);
void (*s2a_track_test_prot_wait)(uintptr_t pn);
void (*s2a_track_test_rfq_put)(uintptr_t pn);   // ㊳：写入方动过读回环头指针之后、发布槽或溢出位之前（模拟写入方在这一刻被抢占）
int s2a_track_test_page(uintptr_t pn, int *lastp) { leaf_t *l = leaf_of(pn); if (!l) return -1; *lastp = atomic_load(&l->lastp[LI(pn)]); return atomic_load(&l->state[LI(pn)]); }   // ㊴：页状态与记账保护
void s2a_track_test_set_ro(uintptr_t pn) { leaf_t *l = leaf_of(pn); if (!l) return; mp(pn, PROT_READ); atomic_store(&l->state[LI(pn)], PG_RO); }
#endif
// 读回环入队（信号路径）：先确认有空位、再用 CAS 占下标——占到的下标随后一定写槽；环满只记溢出（排空时整表扫）、不占下标。
//   原先先 fetch_add 占下标再判满：满时下标占了、槽却不写，排空取到这个头指针时溢出位若还没置上，就在锁里等一个永远不来的槽（审计 #846 F-rfq-over-wait）
static void rfq_put(uintptr_t pn) {
    uint64_t h = atomic_load(&g_rfq_h);
    for (;;) {
        if (h - atomic_load(&g_rfq_t) >= RFQ) {
#ifdef S2A_TRACK_TEST
            if (s2a_track_test_rfq_put) s2a_track_test_rfq_put(pn);
#endif
            atomic_store(&g_rfq_over, 1); return; }
        if (atomic_compare_exchange_weak(&g_rfq_h, &h, h + 1)) {
#ifdef S2A_TRACK_TEST
            if (s2a_track_test_rfq_put) s2a_track_test_rfq_put(pn);
#endif
            atomic_store(&g_rfq[h % RFQ], pn + 1); return; }
    }
}
int s2a_track_fault(void *addr, int is_write) {
    if (!g_pg) return 0;
    uintptr_t pn = (uintptr_t)addr >> g_shift; leaf_t *l = leaf_of(pn);
    // 记账保护值只读一次（快照）：两条分支各读一次时，中间别的线程把页从 NONE 改成可读（rf_apply / 改保护 / 未同步放行的设回），
    // 第一条读到 NONE、第二条读到可读，两条都不成立，读缺页落到「非写缺页」返回 0 → 游戏崩（10-23 Mac 塞尔达 main+0x114a138，
    // 现场 lastp=1 kprot=1：页早已可读）。按同一份快照判：可读 = 别的线程已降，重执行；NONE = 不可读页被读
    uint8_t lp = l ? atomic_load(&l->lastp[LI(pn)]) : 0xff;
#ifdef S2A_TRACK_TEST
    if (s2a_track_test_hook) s2a_track_test_hook(pn);
#endif
#ifdef S2A_TRACK_TEST_OLD
#define LP_AT(k) atomic_load(&l->lastp[LI(pn)])
#else
#define LP_AT(k) lp
#endif
    if ((g_rf || atomic_load(&g_rfm_any)) && !is_write && l && lp != PROT_NONE && (lp & PROT_READ)) {
        atomic_fetch_add(&g_races, 1); return 1; }   // READFLUSH 并发：缺页时还不可读、处理时已被别的线程降为可读——重执行
#ifdef S2A_TRACK_TEST
    if (s2a_track_test_hook2) s2a_track_test_hook2(pn);
#endif
    if (!is_write && l && LP_AT(2) == PROT_NONE) {   // READFLUSH 不可读页被读、没改道（宿主代码 / 跳板里）：放成只读、不回写
#undef LP_AT
        uint8_t st = PG_RO;
        if (atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) {
            if (mp(pn, PROT_READ)) { atomic_store(&l->state[LI(pn)], PG_RO); return 0; }   // 放不成只读：重执行只会再缺页
            atomic_store(&l->state[LI(pn)], PG_RO);
            rfq_put(pn);   // 下次排空设回不可读
        }
        rf_hostread_bt();
        if (atomic_fetch_add(&g_rf_hostread, 1) < 8) { sigsafe_hex("[track] READFLUSH：不可读页被宿主读 / 未改道，放成只读不回写 addr=", (uint64_t)(uintptr_t)addr); write(2, "\n", 1); }
        return 1;   // BUSY / 已被别的线程改：重执行
    }
    if (!is_write || !l) { if (l) { sigsafe_hex("[track] 【红】非写缺页 addr=", (uint64_t)(uintptr_t)addr); sigsafe_hex("state=", atomic_load(&l->state[LI(pn)])); write(2, "\n", 1); } return 0; }
    uint8_t st = atomic_load(&l->state[LI(pn)]);
    if (st == PG_RW) {
        // 过期缺页：写发生时页还只读，处理到这里别的线程已合法解开（并发写的缺页解开、Ryujinx 改不跟踪 reprotect RW、自愈）——重执行即可，
        // 脏位由解开的一方记过（改不跟踪的不用记）。按内核里这页的实际保护判，不按时间猜：旧判据「10 ms 内被缺页解开过」不认 reprotect RW 解开的页，
        // 处理函数被抢占超 10 ms 也误判，误判即整页报脏 + 报红（10-21 巫师3 / 动森 / 塞尔达每局几到几十行，lastp=3 want=0，t_track ㉓）
#if defined(__APPLE__)
        int kp = kern_prot(pn); if (kp >= 0 && (kp & PROT_WRITE)) { atomic_fetch_add(&g_races, 1); return 1; }
        // 查的同时别的线程又把它收回只读（reprotect / 排空落地都先标 BUSY 再改保护）：重执行，按新状态走
        if (atomic_load(&l->state[LI(pn)]) != PG_RW) return 1;
        // 外部报过的改保护（lastp 0xfe：客人 SetMemoryPermission / 原生层改可访问性，都经 prot_changed / set_guest_protection 报）不是漏报，不升权
        //   （审计 #806 第 1 条：原先客人刚设的只读被这里改回可写、写成功、整页按脏）。同安卓：首次给过期信号一次重执行，再缺页 = 客人真写了只读页，交回
        if (atomic_load(&l->lastp[LI(pn)]) == 0xfe) { if (atomic_fetch_add(&l->reject[LI(pn)], 1) == 0) return 1; return 0; }
        // 状态可写、内核却不可写：只读不是本模块设的（有路径改了页保护没报 prot_changed）。解开并整页按脏算（保守），计数报红
        if (atomic_fetch_add(&g_heals, 1) < 12) { sigsafe_hex("[track] 【红】状态可写却缺页，自愈 addr=", (uint64_t)(uintptr_t)addr); sigsafe_hex("lastp=", atomic_load(&l->lastp[LI(pn)])); sigsafe_hex("want=", atomic_load(&l->want[LI(pn)])); sigsafe_hex("kprot=", (uint64_t)(int64_t)kp); write(2, "\n", 1); }
        if (mp(pn, PROT_READ | PROT_WRITE)) return 0;   // 自愈也升不了可写：交回，不空转
        atomic_fetch_or(&l->dirty[LI(pn)], (uint8_t)((1u << g_subs) - 1)); enqueue(l, pn);
#else
        // 不读 /proc/self/maps（信号上下文不能 open / 扫 maps）。先占 BUSY 再复核 lastp：
        // SetMemoryPermission 走 s2a_track_set_guest_protection，先占页再 mprotect，所以复核到落地
        // 之间外部改不了这页。
        uint8_t expected = PG_RW;
        if (!atomic_compare_exchange_strong(&l->state[LI(pn)], &expected, PG_BUSY)) return 1;   // 别的线程已改：重执行按新状态走
        if (atomic_load(&l->lastp[LI(pn)]) != (PROT_READ | PROT_WRITE)) {
            // 外部改过（0xfe）/ 未知（0xff）：不升权。首次给过期信号一次重执行；再缺页说明客人
            // 真写了只读页，返回 0 后安卓 on_crash 会 _exit(128+sig)（不是回原信号处理函数）。
            atomic_store(&l->state[LI(pn)], PG_RW);
            if (atomic_fetch_add(&l->reject[LI(pn)], 1) == 0) return 1;
            return 0;
        }
        // lastp=RW 说明本模块的 mprotect(RW) 已经落地（mp() 先写 lastp、再 mprotect；state 随后
        // 才发布 PG_RW；reprotect 也是先 mprotect、再发布）。这时缺页最常见的是「写发生时还只读、
        // 处理到这里别的线程已合法解开」的过期缺页：第一次按竞争处理，不 mprotect、不报脏；
        // 同一页连续第二次才走自愈（同样的自愈在动森 / 塞尔达 10-21 每局误报过几到几十次）。
        if (atomic_fetch_add(&l->reject[LI(pn)], 1) == 0) {
            atomic_store(&l->state[LI(pn)], PG_RW);
            atomic_fetch_add(&g_races, 1);
            return 1;
        }
        atomic_store(&l->reject[LI(pn)], 0);
#ifdef S2A_TRACK_TEST
        if (s2a_track_test_heal_claim) s2a_track_test_heal_claim(pn);
#endif
        mp(pn, PROT_READ | PROT_WRITE);
        atomic_fetch_or(&l->dirty[LI(pn)], (uint8_t)((1u << g_subs) - 1));
        enqueue(l, pn);
        atomic_store(&l->state[LI(pn)], PG_RW);
        atomic_fetch_add(&g_heals, 1);
#endif
        return 1; }
    if (!unprotect(pn, (uint8_t)(1u << (((uintptr_t)addr & (g_pg - 1)) / SUB)), 0)) return 0;
    atomic_fetch_add(&g_faults, 1); return 1;
}

// 回写的保存区（本线程）：要写的段落进待比对快照子页、且 CPU 已改过其中字节 → 写前存下子页现内容与「CPU 改过」字节位图，写完放回
typedef struct { uintptr_t sa; uint8_t cur[SUB]; uint64_t chg[SUB / 64]; } psave_t;
static __thread psave_t *t_ps; static __thread unsigned t_psn, t_psc;
static pthread_key_t g_ps_key; static pthread_once_t g_ps_once = PTHREAD_ONCE_INIT;
static void ps_key_init(void) { if (pthread_key_create(&g_ps_key, free)) FATAL("回写保存区线程析构登记失败"); }
static void prep_range(uintptr_t a, size_t len, int core) {   // 写 [a, a+len) 之前：涉及的页解保护，写到的子页按来源记
    if (!len || !g_pg) return;
    uintptr_t e = a + len;
    for (uintptr_t pn = a >> g_shift, q = (e - 1) >> g_shift; pn <= q; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
        uintptr_t pb = pn << g_shift; uint8_t m = 0;
        for (unsigned s = 0; s < g_subs; s++) { uintptr_t sa = pb + s * SUB; if (sa < e && sa + SUB > a) m |= (uint8_t)(1u << s); }
        if (core == 2) { uint8_t pm = atomic_load(&l->psnap[LI(pn)]) & m;
            for (unsigned s = 0; s < g_subs; s++) if (pm >> s & 1) {
                uintptr_t sa = pb + s * SUB, x0 = a > sa ? a : sa, x1 = e < sa + SUB ? e : sa + SUB; const uint8_t *sn = snap_at(l->slot[(size_t)LI(pn) * 8 + s]);
                if (!memcmp(sn + (x0 - sa), (const void *)x0, x1 - x0)) { atomic_fetch_add(&g_ucw_hit, 1); continue; }
                atomic_fetch_add(&g_ucw_inter, 1);
                if (t_psn == t_psc) { t_psc = t_psc ? t_psc * 2 : 4; t_ps = realloc(t_ps, t_psc * sizeof *t_ps); if (!t_ps) FATAL("回写保存区分配失败"); pthread_once(&g_ps_once, ps_key_init); if (pthread_setspecific(g_ps_key, t_ps)) FATAL("回写保存区线程析构登记失败"); }
                psave_t *v = &t_ps[t_psn++]; v->sa = sa; memcpy(v->cur, (const void *)sa, SUB); memset(v->chg, 0, sizeof v->chg);
                for (uintptr_t i = x0 - sa; i < x1 - sa; i++) if (v->cur[i] != sn[i]) v->chg[i / 64] |= 1ull << (i % 64); } }
        if (atomic_load(&l->state[LI(pn)]) != PG_RW && unprotect(pn, m, core)) atomic_fetch_add(&g_preps, 1);
    }
}
// 托管代码写游戏内存前（NxTrack.Write）：写到 GPU 改过的子页先回写（A 方案，同游戏代码的缺页改道；这里本就在正常上下文，直接回调），再解保护记脏
// 宿主写游戏内存前的外挂通知（10-24 双轨直连：直连写跟踪的「写前通知」由原生层 direct_host.c 登记到这里）：三个写入口最先调它，
//   S2Arm 所有「宿主即将写游戏内存」本就先经这三个入口，挂在这里一处都不漏。原子指针、读用 relaxed（ARM 上即普通读）。
//   回写回调（t_in_touch 期间、渲染线程上的回写）也会经 write_untracked 走到这里，所以回调里不许再写游戏内存、不许拿 RegionHandle 的锁（同 write_quiet 那段 10-21 八方2 的坑）
static _Atomic(void (*)(uint64_t, uint64_t)) g_wprep;
void s2a_track_set_write_prep(void (*fn)(uint64_t, uint64_t)) { atomic_store_explicit(&g_wprep, fn, memory_order_release); }
#define WPREP(a, n) do { void (*f_)(uint64_t, uint64_t) = atomic_load_explicit(&g_wprep, memory_order_relaxed); if (f_ && (n)) f_((a), (n)); } while (0)
void s2a_track_write(uint64_t addr, uint64_t size) {
    WPREP(addr, size);
    if (g_touch && g_pg && size && !t_in_touch) {
        uintptr_t a = (uintptr_t)addr, e = a + (uintptr_t)size;
        for (uintptr_t pn = a >> g_shift, q = (e - 1) >> g_shift; pn <= q; pn++) {
            leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
            for (unsigned s = 0; s < g_subs; s++) { uintptr_t sa = (pn << g_shift) + s * SUB;
                if (sa < e && sa + SUB > a && ((atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)])) >> s & 1)) touch_cb(sa, SUB, 1); }
        }
    }
    prep_range((uintptr_t)addr, (size_t)size, 0);
}
// 不跟踪托管写（Ryujinx GetWritableRegion(tracked: false)：服务写 IPC 缓冲等）真正写之前：只解保护记脏，不触发「GPU 改过的子页先回写」。
// 原版不跟踪写不发跟踪事件。单线程时这种写嵌在 touch 回调里、t_in_touch 挡住了再触发；
// 双线程渲染时回写在渲染线程执行，t_in_touch 挡不住，再触发即回到同一 RegionHandle，与持着它的锁、正等这次回写的 GPU 模拟线程死锁（10-21 八方2 / 暗黑2 Mac 局）。
// GPU 自己的不跟踪写（贴图回写、清缓冲）不走这里：Ryujinx PhysicalMemory 给副本、写完经 s2a_track_write_untracked 写回（不当 CPU 写重报）
void s2a_track_write_quiet(uint64_t addr, uint64_t size) { WPREP(addr, size); if (size) prep_range((uintptr_t)addr, (size_t)size, 0); }
// [addr, addr+size) 涉及的 4 KB 子页里有没有 Ryujinx 标了 GPU 改过（None）的：只读状态位，不改任何东西
int s2a_track_gpu_modified(uint64_t addr, uint64_t size) {
    if (!g_pg || !size) return 0;
    uintptr_t a = (uintptr_t)addr, e = a + (uintptr_t)size;
    for (uintptr_t pn = a >> g_shift, q = (e - 1) >> g_shift; pn <= q; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
        // 只看 act（Ryujinx 设的 None 意图）：页被解开时 want 整页交给观察 / 快照、清成 0，act 仍在——按 act & want 判，解开的页上 GPU 改过的子页会被漏看，
        // 常量缓冲内联更新随之发普通写事件、触发先回写（10-21 怪猎同路线读回 0 → 2923 次）
        uint8_t aw = atomic_load(&l->act[LI(pn)]);
        for (unsigned s = 0; aw && s < g_subs; s++) { uintptr_t sa = (pn << g_shift) + s * SUB; if (sa < e && sa + SUB > a && (aw >> s & 1)) return 1; }
    }
    return 0;
}
// 不跟踪写：① 解开涉及的页（回写时先存 CPU 改过的字节）② 复制 ③ 回写：放回 CPU 的字节 ④ 记基线——
//   刚解开的跟踪子页：写后内容哈希、转观察中（排空时内容再变 = CPU 写了，报）；GPU 改过子页的快照：写到的字节改成写入值（回写 / 信号量的字节不当 CPU 写报）。
// 已知窗口：别的线程恰在 ②–④ 之间（微秒级）写同一 READ 子页，那次写并进基线、漏报；GPU 改过子页没有这个窗口（快照按写入值改，不读内存）
// 观察中子页的基线哈希增量：add = 0 减去 [a, e) 涉及字的现值贡献，add = 1 加上（写前 / 写后各调一次，涉及的观察位两次之间不变时正好抵消成新内容）。
// 两次之间被排空落地（观察位清掉）的子页：加回的是作废的哈希，下次设观察时整页重算，无害
static void watch_delta(uintptr_t a, uintptr_t e, int add) {
    for (uintptr_t pn = a >> g_shift, q = (e - 1) >> g_shift; pn <= q; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
        uintptr_t pb = pn << g_shift; uint8_t wa = atomic_load(&l->watch[LI(pn)]);
        if (!wa) continue;
        for (unsigned s = 0; s < g_subs; s++) {
            uintptr_t sa = pb + s * SUB; if (!(wa >> s & 1) || sa >= e || sa + SUB <= a) continue;
            uintptr_t x0 = a > sa ? a : sa, x1 = e < sa + SUB ? e : sa + SUB;
            uint64_t d = words_hash(sa, (unsigned)((x0 - sa) / 8), (unsigned)((x1 - sa + 7) / 8));
            uint64_t *h = &l->hash[(size_t)LI(pn) * 8 + s];
            *h = add ? *h + d : *h - d;
        }
    }
}
// 宿主读游戏内存、不经页保护（帧率能耗线 10-23）：Ryujinx 贴图回写先把目标段原样拷一份（S2AUntrackedRegionPool.Rent），目标正是读时回写设成
// 不可读的页——直接读就缺页、放成只读再设回（两次 mprotect，塞尔达 Mac 一局约 300 万次）。不可读的页临时共享映射一份只读别名再拷（正常上下文），
// 读到的字节与直接读相同（别名共享同一物理页）。别名建不出时退回直接读（照旧缺页路径）。返回 1 = 走了别名的页数 > 0
static _Atomic uint64_t g_ru_pages, g_ru_direct;
int s2a_track_read_untracked(uint64_t va, void *dst, uint64_t n) {
    if (!n) return 0;
    uint8_t *d = dst; int used = 0;
    for (uint64_t a = va, e = va + n; a < e; ) {
        uint64_t pb = g_pg ? a & ~(uint64_t)(g_pg - 1) : a, pe = g_pg ? pb + g_pg : e, c = (pe < e ? pe : e) - a;
        leaf_t *l = g_pg ? leaf_of((uintptr_t)a >> g_shift) : NULL;
        // #1217 §2.6-②：这里只在 lastp == PROT_NONE（本模块把页设成不可读）时建别名。
        //   已死页（0x2D / 缩堆之后）在换页事务的 s2a_track_backing_reset 里被清成
        //   lastp=0xfe、act=0，事务结束前不会再被设回 PROT_NONE；所以这里不会给死页建
        //   长寿读别名（死页的 memfd 洞由 0x2C 提交前的打洞保证是零）。若调用方仍拿旧
        //   GPU 资源读已死页，走直接 memcpy 会当场缺页——这是保留的响亮失败，不静默读零。
        if (l && atomic_load(&l->lastp[LI((uintptr_t)a >> g_shift)]) == PROT_NONE) {
#if defined(__APPLE__)
            vm_address_t al = 0; vm_prot_t cur, max;
            if (vm_remap(mach_task_self(), &al, g_pg, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)pb, FALSE, &cur, &max, VM_INHERIT_NONE) == KERN_SUCCESS) {
                if (!mprotect((void *)al, g_pg, PROT_READ)) { memcpy(d, (const void *)(al + (a - pb)), c); used = 1; atomic_fetch_add(&g_ru_pages, 1); vm_deallocate(mach_task_self(), al, g_pg); d += c; a += c; continue; }
                vm_deallocate(mach_task_self(), al, g_pg);
            }
#else
            for (int stale = 0;;) {
                void *alias = NULL;
                int error = s2a_track_platform_alias((uintptr_t)pb, g_pg, PROT_READ, &alias);
                if (error) FATAL("不可读页共享别名失败 errno=%d", error);
                memcpy(d, (const uint8_t *)alias + (a - pb), c);
                error = s2a_track_platform_unalias(alias, g_pg);
                if (!error) break;
                if (error != ESTALE || ++stale > S2A_ALIAS_STALE_MAX) FATAL("释放共享读别名失败 errno=%d", error);
                s2a_track_platform_note_stale();
            }
            used = 1; atomic_fetch_add(&g_ru_pages, 1); d += c; a += c; continue;
#endif
        }
        memcpy(d, (const void *)(uintptr_t)a, c); atomic_fetch_add(&g_ru_direct, 1); d += c; a += c;
    }
    return used;
}
// The Android precise consumer must not race a READFLUSH re-protect between
// checking lastp and reading guest memory. Always use the real shared alias;
// keeping the original mapping protected preserves concurrent guest semantics.
// 苹果（10-28 审计 #806 第 5 条：排空原先直接解引用客人页，读时回写设成不可读的页即缺页、被放成只读）：持 g_mu 判 lastp 再拷——
//   本模块把页设成不可读（rf_apply）、客人改保护（set_guest_protection）都持 g_mu，持锁期间记账可读（READ / RW）的页不会变不可读，直接拷；
//   其余（不可读、外部改过 0xfe、叶子新建未设过）经临时只读别名拷，客人页保护不动。不像安卓每页都建别名：苹果一次 vm_remap + mprotect + vm_deallocate 约 3 µs
int s2a_track_copy_precise(uint64_t va, void *dst, uint64_t n) {
    if (!n) return 0;
    if (!g_pg || !dst || va + n < va) FATAL("精确快照读取参数无效");
#if defined(__APPLE__)
    uint8_t *d = dst; int used = 0;
    pthread_mutex_lock(&g_mu);
    for (uint64_t a = va, e = va + n; a < e; ) {
        uint64_t pb = a & ~(uint64_t)(g_pg - 1), c = g_pg - (a - pb);
        if (c > e - a) c = e - a;
        leaf_t *l = leaf_of((uintptr_t)a >> g_shift);
        uint8_t lp = l ? atomic_load(&l->lastp[LI((uintptr_t)a >> g_shift)]) : (uint8_t)(PROT_READ | PROT_WRITE);
        if (lp == PROT_READ || lp == (PROT_READ | PROT_WRITE)) memcpy(d, (const void *)(uintptr_t)a, c);
        else {
            vm_address_t al = 0; vm_prot_t cur, max;
            if (vm_remap(mach_task_self(), &al, g_pg, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)pb, FALSE, &cur, &max, VM_INHERIT_NONE) != KERN_SUCCESS) FATAL("精确快照只读别名失败");
            if (mprotect((void *)al, g_pg, PROT_READ)) FATAL("精确快照别名不可读 errno=%d", errno);
            memcpy(d, (const void *)(al + (a - pb)), c);
            if (vm_deallocate(mach_task_self(), al, g_pg) != KERN_SUCCESS) FATAL("释放精确快照别名失败");
            used = 1; atomic_fetch_add(&g_ru_pages, 1);
        }
        d += c; a += c;
    }
    pthread_mutex_unlock(&g_mu);
    return used;
#else
    uint8_t *d = dst;
    for (uint64_t a = va, e = va + n; a < e; ) {
        uint64_t pb = a & ~(uint64_t)(g_pg - 1);
        uint64_t count = g_pg - (a - pb);
        if (count > e - a) count = e - a;
        for (int stale = 0;;) {
            void *alias = NULL;
            // #1217 §2.6-②：精确快照由排空 / 快照流程在换页事务之外调用，页面仍属当前
            //   generation（backing_reset 会把 psnap/slot 清掉，快照不会跨代保留）。即使
            //   调用方传进已死页，这里只读：memfd 的洞读回零，不会得到旧 shmem 内容。
            //   事务外的打洞来自 NVN unref（backing_alias_unref → backing_release_locked），
            //   它只打已经 backing_reset 过的死页；这里即使撞上，读到的也只是零，不会写坏活页。
            int error = s2a_track_platform_alias((uintptr_t)pb, g_pg, PROT_READ, &alias);
            if (error) FATAL("精确快照共享别名失败 errno=%d", error);
            memcpy(d, (const uint8_t *)alias + (a - pb), count);
            error = s2a_track_platform_unalias(alias, g_pg);
            if (!error) break;
            if (error != ESTALE || ++stale > S2A_ALIAS_STALE_MAX) FATAL("释放精确快照别名失败 errno=%d", error);
            s2a_track_platform_note_stale();
        }
        d += count; a += count;
    }
    return 1;
#endif
}
#if !defined(__APPLE__)
// 精确恢复的写前页像缓冲（线程局部，热路径不再每次 malloc）。线程退出由 pthread key 析构释放。
static pthread_key_t g_pi_key; static pthread_once_t g_pi_once = PTHREAD_ONCE_INIT;
static void pi_key_init(void) { if (pthread_key_create(&g_pi_key, free)) FATAL("精确恢复页像缓冲析构登记失败"); }
static uint8_t *pre_image_buffer(void) {
    pthread_once(&g_pi_once, pi_key_init);
    uint8_t *p = pthread_getspecific(g_pi_key);
    if (!p) {
        p = malloc(g_pg);
        if (!p) FATAL("精确恢复页像缓冲分配失败");
        if (pthread_setspecific(g_pi_key, p)) { free(p); FATAL("精确恢复页像缓冲线程析构登记失败"); }
    }
    return p;
}
#endif
void s2a_track_restore_precise(uint64_t va, const void *src, uint64_t n) {
    if (!n) return;
    if (!g_pg || !src || va + n < va) FATAL("精确快照恢复参数无效");
    WPREP(va, n);   // 与其他宿主写入口保留相同的写前协调。
    const uint8_t *s = src;
#if !defined(__APPLE__)
    // 开关只在入口读一次：关时整段回到 main 的活别名路径（先记账、再在别名上写、最后解别名），
    // 不分配页像、不进写者计数、不做 ESTALE 重试；开时保持 #1184 D1 的页像 + 世代重试逻辑。
    int mirror = s2a_android_mirror_enabled();
    // 写前页像只在第一次真正落笔的重试上取一次：ESTALE 可能发生在 memcpy 之后，失败轮写入已落地，
    // 若下一轮再取页像，成功轮的「减旧加新」会把失败轮写过的内容当成基线（哈希残留）。
    // 保留首次页像 + 最终写入值，成功轮一次提交，等价于从写前内容直接到写后内容（#1184 D1）。
    uint8_t *pre_image = mirror ? pre_image_buffer() : NULL;
#endif
    for (uint64_t a = va, end = va + n; a < end; ) {
        uint64_t pb = a & ~(uint64_t)(g_pg - 1);
        uint64_t count = g_pg - (a - pb);
        if (count > end - a) count = end - a;
#if defined(__APPLE__)
        vm_address_t mapped = 0; vm_prot_t cur, max;
        if (vm_remap(mach_task_self(), &mapped, g_pg, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                     (vm_address_t)pb, FALSE, &cur, &max, VM_INHERIT_NONE) != KERN_SUCCESS)
            FATAL("精确恢复共享别名失败");
        if (mprotect((void *)mapped, g_pg, PROT_READ | PROT_WRITE)) FATAL("精确恢复共享别名不可写 errno=%d", errno);
        uint8_t *alias = (uint8_t *)mapped;
#else
        void *mapped = NULL;
        if (!mirror) {
            // main 原路径：一次取可写活别名，记账与写入都落在这张别名上，最后直接解别名。
            // #1217 §2.6-②：restore_precise 只在排空提交里对「同一世代仍有快照」的页调用；
            //   0x2D / 缩堆的换页事务会先 backing_reset 把 psnap/slot/hash 清空并置
            //   lastp=0xfe，之后不会再有人恢复这一代的页像。事务期间 guest/GPU 已停稳，
            //   所以这里拿不到已死页；即使拿到，写入也只是回填已释放的 memfd 页（不影响
            //   下次提交，下一次 0x2C 会先打洞）。边角：若该死页正被 NVN ref 推迟打洞，
            //   这次回填会改到 NVN 别名看到的内容，并在下次 0x2C 打洞前常驻；当前只可能
            //   出现在调用方绕过事务恢复旧快照的路径，属已知限制（PR 正文「限制」）。
            int error = s2a_track_platform_alias((uintptr_t)pb, g_pg, PROT_READ | PROT_WRITE, &mapped);
            if (error) FATAL("精确恢复共享别名失败 errno=%d", error);
        } else {
            for (int captured = 0, stale = 0, busy = 0;;) {
                void *target_alias = NULL;
                s2a_track_platform_writer_enter();   // 页像读取 + 写入 + 哈希记账全程挡住换页（#1184 D1）
                int error = s2a_track_platform_alias((uintptr_t)pb, g_pg, PROT_READ | PROT_WRITE, &target_alias);
                if (error == EAGAIN) {
                    s2a_track_platform_writer_leave();
                    if (++busy > S2A_ALIAS_BUSY_MAX) FATAL("精确恢复等待换页世代超限（%d 次）", busy);
                    if (s2a_track_platform_wait_stable()) FATAL("精确恢复等待换页世代超时");
                    continue;
                }
                if (error) { s2a_track_platform_writer_leave(); FATAL("精确恢复共享别名失败 errno=%d", error); }
                if (!captured) {
                    memcpy(pre_image, target_alias, g_pg); captured = 1;
#ifdef S2A_TRACK_TEST
                    atomic_fetch_add(&s2a_track_test_precise_preimages, 1);
#endif
                }
                memcpy((uint8_t *)target_alias + (a - pb), s, count);
                error = s2a_track_platform_unalias(target_alias, g_pg);
                if (!error) break;   // 成功轮保持计数，下面的哈希记账也要在同一世代内完成
                s2a_track_platform_writer_leave();
                if (error != ESTALE || ++stale > S2A_ALIAS_STALE_MAX) FATAL("释放精确恢复别名失败 errno=%d", error);
                s2a_track_platform_note_stale();
                if (s2a_track_platform_wait_stable()) FATAL("精确恢复等待换页世代超时");
            }
        }
        uint8_t *alias = mirror ? pre_image : (uint8_t *)mapped;
#endif
        // Preserve write_untracked's existing watch/snapshot bookkeeping, but
        // use the alias for hashing so the guest mapping stays protected.
        // 镜像开：alias 指向写前页像，下面 memcpy 把它补成写后页像——记账与真实提交同值。
        // 镜像关：alias 是 main 活别名，记账/写入与 main 相同。
        uintptr_t pn = (uintptr_t)pb >> g_shift;
        leaf_t *l = leaf_of(pn);
        uint8_t mask = 0;
        for (unsigned sub = 0; sub < g_subs; ++sub) {
            uint64_t sa = pb + sub * SUB;
            if (sa >= a + count || sa + SUB <= a) continue;
            mask |= (uint8_t)(1u << sub);
            if (l && ((atomic_load(&l->watch[LI(pn)]) >> sub) & 1)) {
                uint64_t x0 = a > sa ? a : sa, x1 = a + count < sa + SUB ? a + count : sa + SUB;
                uint64_t d = words_hash((uintptr_t)(alias + sub * SUB), (unsigned)((x0 - sa) / 8), (unsigned)((x1 - sa + 7) / 8));
                l->hash[(size_t)LI(pn) * 8 + sub] -= d;
            }
        }
        memcpy(alias + (a - pb), s, count);
        if (l) {
            for (unsigned sub = 0; sub < g_subs; ++sub) {
                uint64_t sa = pb + sub * SUB;
                if (!(mask >> sub & 1) || !(atomic_load(&l->watch[LI(pn)]) >> sub & 1)) continue;
                uint64_t x0 = a > sa ? a : sa, x1 = a + count < sa + SUB ? a + count : sa + SUB;
                uint64_t d = words_hash((uintptr_t)(alias + sub * SUB), (unsigned)((x0 - sa) / 8), (unsigned)((x1 - sa + 7) / 8));
                l->hash[(size_t)LI(pn) * 8 + sub] += d;
            }
            uint8_t r = atomic_fetch_and(&l->rearm[LI(pn)], (uint8_t)~mask) & mask;
            uint8_t ps = atomic_load(&l->psnap[LI(pn)]) & mask;
            for (unsigned sub = 0; sub < g_subs; ++sub) {
                uint64_t sa = pb + sub * SUB;
                if (r >> sub & 1) l->hash[(size_t)LI(pn) * 8 + sub] = sub_hash((uintptr_t)(alias + sub * SUB));
                if (ps >> sub & 1) {
                    uint64_t x0 = a > sa ? a : sa, x1 = a + count < sa + SUB ? a + count : sa + SUB;
                    memcpy(snap_at(l->slot[(size_t)LI(pn) * 8 + sub]) + (x0 - sa), s + (x0 - a), x1 - x0);
                }
            }
            atomic_fetch_or(&l->watch[LI(pn)], r);
        }
#if defined(__APPLE__)
        if (vm_deallocate(mach_task_self(), mapped, g_pg) != KERN_SUCCESS) FATAL("释放精确恢复别名失败");
#else
        if (mirror) s2a_track_platform_writer_leave();   // 记账提交后才放换页进来
        else if (s2a_track_platform_unalias(mapped, g_pg)) FATAL("释放精确恢复别名失败");
#endif
        s += count; a += count;
    }
}
// 回写进读时回写设成不可读的页、且写到的子页全是 GPU 改过的（正在回写的就是它们）：经临时共享可写别名写，页保护全程不动——
// 同页其余 GPU 改过子页一直拦着，别的线程这时读它们照样缺页、先回写（部分回写不留「整页解开 → 再设回」的窗口，维护者 10-23）。
// 这些子页不在观察 / 快照里（GPU 改过的子页不拍快照），写完由 Ryujinx 按回写结果改保护。返回 1 = 已写
// g_walias：随 S2A_GPU_READFLUSH=1（缺省关，init_once 读；单测用 s2a_track_set_walias 切）
static _Atomic uint64_t g_wa_pages; static int g_walias;
void s2a_track_set_walias(int on) { g_walias = on; }
// 宿主替游戏写内存（服务 / DSP 改共享结构的一个字）：1 / 2 / 4 / 8 字节且自然对齐时一条存储写完，游戏线程并发读不会读到半截值；其余照旧 memcpy。
//   11-06 超级舞动 瓦力欧制造：音频 DSP 改 32 位写偏移经这里 memcpy，macOS 小于 8 字节的 memcpy 逐字节升序写，游戏线程读到低字节新、高字节旧的
//   0x0380 / 0x0740（真值 0x03C0→0x0780 / 0x0780→0x0B40），混响回调读量 896 不是 960 的整数倍 → abort（sdk+0x158b40）。真机上这类字一次写完
//   S2A_TRACK_TEST_OLD_STORE：单测反证用旧写法
static inline void guest_store(void *d, const void *s, size_t n) {
#ifndef S2A_TRACK_TEST_OLD_STORE
    uintptr_t p = (uintptr_t)d;
    if (n == 4 && !(p & 3)) { uint32_t v; memcpy(&v, s, 4); __atomic_store_n((uint32_t *)d, v, __ATOMIC_RELAXED); return; }
    if (n == 8 && !(p & 7)) { uint64_t v; memcpy(&v, s, 8); __atomic_store_n((uint64_t *)d, v, __ATOMIC_RELAXED); return; }
    if (n == 2 && !(p & 1)) { uint16_t v; memcpy(&v, s, 2); __atomic_store_n((uint16_t *)d, v, __ATOMIC_RELAXED); return; }
#endif
    memcpy(d, s, n);
}
static int write_via_alias(uintptr_t a, uintptr_t e, const void *src) {
    uintptr_t pn = a >> g_shift; leaf_t *l = leaf_of(pn);
    if (!l || ((e - 1) >> g_shift) != pn || atomic_load(&l->lastp[LI(pn)]) != PROT_NONE) return 0;
    uintptr_t pb = pn << g_shift; uint8_t m = 0;
    for (unsigned s = 0; s < g_subs; s++) { uintptr_t sa = pb + s * SUB; if (sa < e && sa + SUB > a) m |= (uint8_t)(1u << s); }
    if ((atomic_load(&l->act[LI(pn)]) & m) != m) return 0;
#if defined(__APPLE__)
    vm_address_t al = 0; vm_prot_t cur, max;
    if (vm_remap(mach_task_self(), &al, g_pg, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)pb, FALSE, &cur, &max, VM_INHERIT_NONE) != KERN_SUCCESS) return 0;
    int ok = !mprotect((void *)al, g_pg, PROT_READ | PROT_WRITE);
    if (ok) { guest_store((void *)(al + (a - pb)), src, e - a); atomic_fetch_add(&g_wa_pages, 1); }
    vm_deallocate(mach_task_self(), al, g_pg);
    return ok;
#else
    if (!s2a_android_mirror_enabled()) {
        // main 原路径：取一次可写活别名，写入后直接解别名；不做写者计数，也不在拿到别名后复核。
        // #1217 §2.6-②：入口已判 lastp == PROT_NONE 且目标子页 act 全置位；已死页在
        //   0x2D / 缩堆事务里被 backing_reset 置成 lastp=0xfe、act=0，事务结束前不会
        //   再满足这个前提。互斥出处：GPU before 回调与宿主回写由 runtime tracking 的
        //   backing 事务串行（runtime/tracking/README.md「事务合同」；runtime.c 的
        //   s2a_track_backing_begin/end 持 backing_busy，0x2D/0x2C 走同一入口），
        //   所以「复核 lastp/act → 写别名」之间不会插入一次 0x2D；事务外的打洞只来自
        //   NVN unref 且只落在已复位死页，写别名不会写进已经换走 / 打洞的页。
        void *alias = NULL;
        int error = s2a_track_platform_alias(pb, g_pg, PROT_READ | PROT_WRITE, &alias);
        if (error) FATAL("回写共享别名失败 errno=%d", error);
        memcpy((uint8_t *)alias + (a - pb), src, e - a);
        if (s2a_track_platform_unalias(alias, g_pg)) FATAL("释放共享写别名失败");
        atomic_fetch_add(&g_wa_pages, 1);
        return 1;
    }
    for (int stale = 0, busy = 0;;) {
        // 写者计数（#1184 D1）：计数期间 mirror_begin 不得改映射；写完整段（含解别名）才减。
        s2a_track_platform_writer_enter();
        void *alias = NULL;
        // #1217 §2.6-②：镜像开时写者计数把整个写入挡在换页事务之外；镜像关时走上面的
        //   main 原路径。两条路都要求 lastp == PROT_NONE + act 子页齐（已死页被
        //   backing_reset 置成 0xfe / 0），所以写别名永远落到活页；活页的 memfd pgoff
        //   不会被 0x2D / 缩堆打洞（有引用或还在堆界内）。
        int error = s2a_track_platform_alias(pb, g_pg, PROT_READ | PROT_WRITE, &alias);
        if (error == EAGAIN) {   // 进入时撞上换页事务：退计数、等偶数再重试（不能持计数等，mirror_begin 正等计数）
            s2a_track_platform_writer_leave();
            if (++busy > S2A_ALIAS_BUSY_MAX) FATAL("回写等待换页世代超限（%d 次）", busy);
            if (s2a_track_platform_wait_stable()) FATAL("回写等待换页世代超时");
            continue;
        }
        if (error) { s2a_track_platform_writer_leave(); FATAL("回写共享别名失败 errno=%d", error); }
#ifdef S2A_TRACK_TEST
        if (s2a_track_test_write_alias_acquired) s2a_track_test_write_alias_acquired();
#endif
        // 前提逐次复核：别名拿到手后再读 lastp/act——ESTALE 重试意味着中途换过页，
        // GPU 改过子页可能已被回写放成可读、或页被解开；前提不再成立时释放别名退回正常路径，
        // 不把旧 GPU 数据写进新换入的页。（仅镜像开；关时走上面 main 原路径）
#ifdef S2A_TRACK_TEST
        atomic_fetch_add(&s2a_track_test_write_alias_rechecks, 1);
#endif
        l = leaf_of(pn);
        if (!l || atomic_load(&l->lastp[LI(pn)]) != PROT_NONE ||
            (atomic_load(&l->act[LI(pn)]) & m) != m) {
            error = s2a_track_platform_unalias(alias, g_pg);
            s2a_track_platform_writer_leave();
            // 前提失效不是「可以忽略的释放失败」：ENOENT/EINVAL（别名栈错位）、窗外 munmap 失败都是记账/映射违约，
            // 继续走正常路径会把真实错误藏起来（#1184 D2）。ESTALE 只表示换过页，退回正常路径。
            if (error && error != ESTALE) FATAL("释放共享写别名失败（前提失效）errno=%d", error);
            if (error == ESTALE) s2a_track_platform_note_stale();
            return 0;
        }
#ifdef S2A_TRACK_TEST
        if (s2a_track_test_write_alias_ready) s2a_track_test_write_alias_ready();
#endif
        memcpy((uint8_t *)alias + (a - pb), src, e - a);
        error = s2a_track_platform_unalias(alias, g_pg);
        s2a_track_platform_writer_leave();
        if (!error) break;
        if (error != ESTALE || ++stale > S2A_ALIAS_STALE_MAX) FATAL("释放共享写别名失败 errno=%d", error);
        s2a_track_platform_note_stale();
#ifdef S2A_TRACK_TEST
        if (s2a_track_test_write_alias_retry) s2a_track_test_write_alias_retry();
#endif
    }
    atomic_fetch_add(&g_wa_pages, 1);
    return 1;
#endif
}
void s2a_track_write_untracked(uint64_t addr, const void *src, uint64_t size, int flush) {
    if (!size) return;
    WPREP(addr, size);
    uintptr_t a = (uintptr_t)addr, e = a + size;
    if (flush && g_pg && g_walias && write_via_alias(a, e, src)) return;
    // 已在观察中的子页（页早被解开）：基线哈希按字增量改——写前减去写到的字（按 8 字节对齐外扩）的现值贡献、写后加上新值贡献，
    // 写本身不当 CPU 写报，子页里别处 CPU 的改动照样在排空时比得出来。只算写到的字，不整页重算
    //（10-21 暗黑3：常量缓冲内联更新每次几十～几百字节，修前每次写前写后各整页算一次 4 KB 哈希，GPU 模拟线程写跟踪 2.3 秒 / 20 秒）。
    // 写前 CPU 已改过写到的字：减掉的是改后值，基线与内容对不上，排空报脏（多报不漏）。已知窗口：对齐外扩出的邻居字节恰在减与加之间被别的线程改，那次改动并进基线
    // 先解开（解开时同页其余要保护的子页按写前内容整页记基线、转观察中），再减：这样这些子页也在减加之列，前后一致
    t_psn = 0; prep_range(a, (size_t)size, flush ? 2 : 1);
    if (g_pg) watch_delta(a, e, 0);
    // 诊断 S2A_FLUSH_DIFF=1（缺省关，帧率能耗线 10-22）：回写写入前比 GPU 数据与游戏内存现内容，数实际不同的字节——
    // 塞尔达每帧被计算着色器「存储写」标成 GPU 改过、又被 CPU 写的那段，回写回来的字节有多少真变了（全同 = 着色器没写这段，标记是绑定范围整段的保守标）
    { static int on = -1; if (on < 0) { const char *v = getenv("S2A_FLUSH_DIFF"); on = v && *v == '1'; }
      if (on && flush) { static _Atomic uint64_t nf, nb, nd, nz; uint64_t d = 0; const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)src;
        for (uint64_t i = 0; i < size; i++) d += x[i] != y[i];
        uint64_t k = atomic_fetch_add(&nf, 1) + 1; atomic_fetch_add(&nb, size); atomic_fetch_add(&nd, d); if (!d) atomic_fetch_add(&nz, 1);
        if ((k & (k - 1)) == 0 || k % 4096 == 0) TLOG("回写比对：%llu 次 %llu KB，与游戏内存现内容不同 %llu 字节（%.2f%%），整段全同 %llu 次", (unsigned long long)k,
            (unsigned long long)(atomic_load(&nb) >> 10), (unsigned long long)atomic_load(&nd), atomic_load(&nb) ? 100.0 * atomic_load(&nd) / atomic_load(&nb) : 0.0, (unsigned long long)atomic_load(&nz)); } }
    guest_store((void *)a, src, (size_t)size);
    for (unsigned k = 0; k < t_psn; k++) { psave_t *v = &t_ps[k];
        for (unsigned i = 0; i < SUB; i++) if (v->chg[i / 64] >> (i % 64) & 1) { ((uint8_t *)v->sa)[i] = v->cur[i]; atomic_fetch_add(&g_restore_b, 1); } }
    t_psn = 0;
    if (g_pg) watch_delta(a, e, 1);
    if (!g_pg) return;
    for (uintptr_t pn = a >> g_shift, q = (e - 1) >> g_shift; pn <= q; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
        uintptr_t pb = pn << g_shift; uint8_t m = 0;
        for (unsigned s = 0; s < g_subs; s++) { uintptr_t sa = pb + s * SUB; if (sa < e && sa + SUB > a) m |= (uint8_t)(1u << s); }
        uint8_t r = atomic_fetch_and(&l->rearm[LI(pn)], (uint8_t)~m) & m, ps = atomic_load(&l->psnap[LI(pn)]) & m;
        for (unsigned s = 0; s < g_subs; s++) if (r >> s & 1) l->hash[(size_t)LI(pn) * 8 + s] = sub_hash(pb + s * SUB);
        atomic_fetch_or(&l->watch[LI(pn)], r);   // 刚解开的子页以写后内容为基线（整页算一次：页原先只读，这是它解开后的第一笔）
        for (unsigned s = 0; s < g_subs; s++) if (ps >> s & 1) {
            uintptr_t sa = pb + s * SUB, x0 = a > sa ? a : sa, x1 = e < sa + SUB ? e : sa + SUB;
            memcpy(snap_at(l->slot[(size_t)LI(pn) * 8 + s]) + (x0 - sa), (const uint8_t *)src + (x0 - a), x1 - x0); }
    }
}
static void ebm_alloc(void);
static void init_once(void) {
    if (g_pg) return;
    { const char *r = getenv("S2A_TRACK_READFLUSH"); if (r && *r == '1') { g_rf = 1; TLOG("【红】READFLUSH 诊断开：GPU 改过的页读也先回写（对照局专用，缺省关）"); } }
    // 缺页处模拟读缺省开（S2A_TRACK_EMUL=0 关，A/B 用）：别名不可用时原生层 s2a_alias_page 回 NULL，自然走老路
    { const char *e = getenv("S2A_TRACK_EMUL"); atomic_store(&g_emul_on, !(e && *e == '0')); if (e && *e == '0') TLOG("缺页处模拟读：关（S2A_TRACK_EMUL=0）"); }
    { const char *e = getenv("S2A_GPU_READFLUSH"); g_walias = e && *e == '1'; }
    { const char *e = getenv("S2A_TRACK_EMUL_STORE"); if (!(e && *e == '0')) { ebm_alloc(); atomic_store(&g_es_on, 1); TLOG("拦写模拟：开（缺省；S2A_TRACK_EMUL_STORE=0 关）——写到 GPU 改过子页、不碰 GPU 改过字节的写在缺页里替游戏做，不回写不等 GPU"); } }
    uintptr_t pg = (uintptr_t)getpagesize(); unsigned subs = (unsigned)(pg / SUB); if (subs > 8 || subs < 1 || (pg & (pg - 1)) || pg % SUB) FATAL("宿主页 %#lx 不支持", (unsigned long)pg);
    { uint8_t *p = mmap(NULL, (size_t)CHUNK * SUB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (p == MAP_FAILED) FATAL("快照池分配失败");
      atomic_store(&g_snapc[0], p); atomic_store(&g_snap_chunks, 1); }
    { const s2a_lowva_api *(*get)(void) = (const s2a_lowva_api *(*)(void))dlsym(RTLD_DEFAULT, "s2a_lowva");   // 低区账（原生层）：取不到（单测 / 回放）不记账
      if (get) { const s2a_lowva_api *a = get(); if (!g_lowva_note) g_lowva_id = a->user("写跟踪快照池", NULL, NULL); a->note(g_lowva_id, (int64_t)CHUNK * SUB); g_lowva_note = a->note; } }
    g_shift = (uintptr_t)__builtin_ctzl(pg); g_subs = subs; g_pg = pg;   // g_pg 最后写：缺页路径以它判「已初始化」
    TLOG("精确写跟踪：宿主页 %#lx，子页 %#llx，%u 子页 / 页，快照槽每块 %d、按需增到 %d 块", (unsigned long)pg, SUB, subs, CHUNK, g_maxchunk);
}
void s2a_track_prepare(void) {
    pthread_mutex_lock(&g_mu); init_once(); pthread_mutex_unlock(&g_mu);
}
void s2a_track_reprotect(uint64_t addr, uint64_t size, int perm) {
    if (!size) return;
    int from_buf = (perm & S2A_TRACK_FROM_BUFFER) != 0; perm &= 0xff;   // 拦写模拟：C# 在缓冲登记回写动作期间置这一位（见 s2a_track.h）
    int writable = perm == S2A_TRACK_RW ? 1 : perm == S2A_TRACK_NONE ? 2 : 0;   // 1 不跟踪；0 跟踪写；2 跟踪写 + GPU 改过
    if (perm != S2A_TRACK_RW && perm != S2A_TRACK_READ && perm != S2A_TRACK_NONE) { static _Atomic int n; if (n++ < 4) TLOG("【红】reprotect 权限 %d 不认识（只认 None/Read/ReadAndWrite），按跟踪写处理", perm); }
    pthread_mutex_lock(&g_mu); init_once();
    uint64_t a = addr & ~(SUB - 1), e = (addr + size + SUB - 1) & ~(SUB - 1);
    if (t_rf_pn && t_in_touch) { uint64_t pb = (uint64_t)(t_rf_pn - 1) << g_shift; for (unsigned sb = 0; sb < g_subs; sb++) { uint64_t sa = pb + sb * SUB; if (sa >= a && sa < e) t_rf_reprot |= (uint8_t)(1u << sb); } }
    // 连续要改成同一权限的页合成一次 mprotect。先把要改的页标成 BUSY（缺页 / 写前路径遇到 BUSY 会等），mprotect 落地后再写最终状态
    uintptr_t run0 = 0; int open = 0, run_prot = 0;
    uintptr_t p0 = (uintptr_t)(a >> g_shift), q = (uintptr_t)((e - 1) >> g_shift);
    for (uintptr_t pn = p0; pn <= q + 1; pn++) {
        int took = 0, prot = 0;
        if (pn <= q) {
            leaf_t *l = leaf_make(pn);
            if (l) {
                uint64_t pb = (uint64_t)pn << g_shift; uint8_t bits = 0;
                for (unsigned sb = 0; sb < g_subs; sb++) { uint64_t sa = pb + sb * SUB; if (sa >= a && sa < e) bits |= (uint8_t)(1u << sb); }
                atomic_fetch_and(&l->watch[LI(pn)], (uint8_t)~bits); atomic_fetch_and(&l->rearm[LI(pn)], (uint8_t)~bits);   // Ryujinx 重新给了保护意图：观察 / 重设作废，以它为准
                if (writable == 2) {
#if !defined(__APPLE__)
                    atomic_fetch_add(&l->generation[LI(pn)], 1);
#endif
                    atomic_fetch_or(&l->act[LI(pn)], bits);
                } else atomic_fetch_and(&l->act[LI(pn)], (uint8_t)~bits);
                if (writable == 2) { if (from_buf) { if (atomic_load(&g_es_on)) leaf_es_alloc(l); atomic_fetch_or(&l->vouch[LI(pn)], bits); } else atomic_fetch_or(&l->taint[LI(pn)], bits); }   // 污染永不清（保守）
                if (writable == 1) {   // Ryujinx 不再跟踪（解除映射 / 释放即此）：待比对快照作废、不再上报——原版里不跟踪的区间不发事件、不回写；
                                       // 留着会在之后的排空里触发回写，盖到已还给游戏、被复用的内存（10-20 动森调度器对象被整页回写）
                    uint8_t pd = atomic_fetch_and(&l->psnap[LI(pn)], (uint8_t)~bits) & bits;
                    for (unsigned sb = 0; sb < g_subs; sb++) if (pd >> sb & 1) slot_put(l->slot[(size_t)LI(pn) * 8 + sb]);
                }
                if (writable == 1) {
                    uint8_t w = atomic_fetch_and(&l->want[LI(pn)], (uint8_t)~bits) & (uint8_t)~bits;
                    if (!w) { uint8_t st = PG_RO; if (atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) { took = 1; prot = PROT_READ | PROT_WRITE; } }
                } else {
                    atomic_fetch_or(&l->want[LI(pn)], bits);
                    // 别的线程正在缺页里解开这页（BUSY）：等它落地再收回，否则它刚取走的 want 不含这几位、随后设成可写，之后的写全漏（旧库 t_track ⑤）
                    for (;;) { uint8_t st = PG_RW; if (atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) { took = 1; prot = PROT_READ; break; } if (st == PG_RO) break; }
                }
            }
        }
        if (open && (!took || prot != run_prot)) {   // 结束一段：一次 mprotect，再落状态
            if (mprotect((void *)(run0 << g_shift), (pn - run0) << g_shift, run_prot)) { int er = errno; TLOG("【红】mprotect %#lx+%#lx 失败 errno=%d（这段不发布、状态退回改动前）", (unsigned long)(run0 << g_shift), (unsigned long)((pn - run0) << g_shift), er);
#if !defined(__APPLE__)
                _exit(125);
#endif
                // 苹果（审计 #836 F-apple-mp-lastp）：内核保护没变，记账保护不动；这段是从只读占来升可写的就退回只读，从可写占来降只读的就退回可写
                for (uintptr_t j = run0; j < pn; j++) atomic_store(&leaf_of(j)->state[LI(j)], run_prot == PROT_READ ? PG_RW : PG_RO);
                open = 0;
                if (took && !open) { run0 = pn; run_prot = prot; open = 1; }
                continue;
            }
            atomic_fetch_add(&g_mprotects, 1);
            if (run_prot != (PROT_READ | PROT_WRITE)) atomic_fetch_add(&g_prot_pages, pn - run0);
            for (uintptr_t j = run0; j < pn; j++) { atomic_store(&leaf_of(j)->lastp[LI(j)], (uint8_t)run_prot); atomic_store(&leaf_of(j)->state[LI(j)], run_prot == PROT_READ ? PG_RO : PG_RW);
#if !defined(__APPLE__)
                atomic_store(&leaf_of(j)->reject[LI(j)], 0);
#endif
            }
            open = 0;
        }
        if (took && !open) { run0 = pn; run_prot = prot; open = 1; }
    }
    if (g_rf || atomic_load(&g_rfm_any)) for (uintptr_t pn = p0; pn <= q; pn++) rf_apply(leaf_of(pn), pn);
    pthread_mutex_unlock(&g_mu);
}
// 一页外部改保护（SetMemoryPermission / 原生层改可访问性）落地后的记账。调用前已把 state 占成
// BUSY（prot_changed / set_guest_protection），函数返回时释放成 PG_RW。持 g_mu。
static void prot_changed_page(leaf_t *l, uintptr_t pn) {
    uint8_t ps = atomic_exchange(&l->psnap[LI(pn)], 0);
    for (unsigned s = 0; s < g_subs; s++) if (ps >> s & 1) slot_put(l->slot[(size_t)LI(pn) * 8 + s]);   // 内容可能被整页换掉：快照作废，按脏报（Ryujinx 照原版回写）
    uint8_t w = atomic_exchange(&l->want[LI(pn)], 0) | atomic_exchange(&l->watch[LI(pn)], 0) | atomic_exchange(&l->rearm[LI(pn)], 0) | ps;
    atomic_store(&l->reject[LI(pn)], 0);   // 苹果也用（10-28 审计 #806：外部改过的页再缺页按 reject 计数交回，同安卓）
    atomic_store(&l->lastp[LI(pn)], 0xfe);
    atomic_store(&l->state[LI(pn)], PG_RW);
    if (w) { atomic_fetch_or(&l->dirty[LI(pn)], w); enqueue(l, pn); }
}
// 非信号路径取一页所有权：state -> BUSY。另一线程的短 BUSY 窗口（缺页解开 / 自愈 / 改保护）等它落地。
// 返回原状态；leaf 为 NULL（不在跟踪里）时不占。
static int claim_page(leaf_t *l, uintptr_t pn) {
    if (!l) return -1;
    for (;;) {
        uint8_t st = atomic_load(&l->state[LI(pn)]);
        if (st == PG_BUSY) {
#ifdef S2A_TRACK_TEST
            if (s2a_track_test_prot_wait) s2a_track_test_prot_wait(pn);
#endif
            continue;
        }
        if (atomic_compare_exchange_weak(&l->state[LI(pn)], &st, PG_BUSY)) return st;
    }
}
void s2a_track_prot_changed(uint64_t addr, uint64_t size) {
    if (!g_pg || !size) return;
    pthread_mutex_lock(&g_mu);
    for (uintptr_t pn = (uintptr_t)(addr >> g_shift), q = (uintptr_t)((addr + size - 1) >> g_shift); pn <= q; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
        claim_page(l, pn);
        prot_changed_page(l, pn);
    }
    pthread_mutex_unlock(&g_mu);
}
// 客人 SetMemoryPermission：mprotect 与跟踪记账放进同一临界区，先占页再改内核保护。
// 缺页自愈也要先占同一页，所以「检查 lastp = RW 之后外部又改回只读」的窗口不存在；
// 外部 RO 一定会排在自愈之后落地。返回 0；失败返回 errno（此时占到的页恢复原状态）。
int s2a_track_set_guest_protection(uint64_t addr, uint64_t size, int prot) {
    if (!size) return 0;
    // 苹果也走这条（10-28 审计 #806 第 1 条：原先苹果先 mprotect 再 prot_changed，两步之间的写缺页看到旧 lastp 会被自愈改回可写）
    if (addr + size < addr) return EINVAL;
    int saved_errno = errno;
    pthread_mutex_lock(&g_mu); init_once();
    if (addr + size > UINTPTR_MAX - (g_pg - 1)) { pthread_mutex_unlock(&g_mu); errno = saved_errno; return EINVAL; }
    uintptr_t lo = (uintptr_t)(addr & ~(uint64_t)(g_pg - 1));
    uintptr_t hi = (uintptr_t)((addr + size + g_pg - 1) & ~(uint64_t)(g_pg - 1));
    size_t n = (size_t)((hi - lo) >> g_shift);
    uint8_t small[64], *old = n <= sizeof small ? small : malloc(n);
    if (!old) { pthread_mutex_unlock(&g_mu); errno = saved_errno; return ENOMEM; }
    for (size_t i = 0; i < n; i++) old[i] = (uint8_t)claim_page(leaf_of((lo >> g_shift) + i), (lo >> g_shift) + i);
    int error = mprotect((void *)lo, hi - lo, prot) ? errno : 0;
    for (size_t i = 0; i < n; i++) {
        leaf_t *l = leaf_of((lo >> g_shift) + i);
        if (!l || old[i] == 0xff) continue;
        if (error) atomic_store(&l->state[LI((lo >> g_shift) + i)], old[i]);
        else prot_changed_page(l, (lo >> g_shift) + i);
    }
    free(old == small ? NULL : old);
    pthread_mutex_unlock(&g_mu);
    errno = saved_errno;
    return error;
}

// ---------- 拦写模拟（帧率能耗线 10-24，docs/研究/拦写模拟.md）----------
// 「CPU 写过」位图槽池：每槽 512 字节（4 KB 子页 1 位 1 字节），开关开时 init 里一次 mmap。槽按子页常驻（不在排空时还），满了走老路
#define ESLOTS 16384
typedef _Atomic uint64_t ebm_t[64]; static ebm_t *_Atomic g_ebm; static _Atomic uint64_t g_ebm_bits[ESLOTS / 64]; static _Atomic uint64_t g_ebm_live, g_ebm_peak;
static _Atomic int g_drain_busy; static _Atomic int64_t g_es_inflight;
#if defined(__APPLE__)
// 苹果换页事务（原生层 svc_mem 的 backing_begin / end，同安卓两阶段协议的名字与参数）：排空期 = s2a_track_drain 到 s2a_track_drain_done
//   （C# 在这之间按地址抄精确写字节、发 VirtualMemoryEvent）。换页事务与排空期互斥：begin 等在途排空期结束、挂「换页中」，
//   新排空期在入口等它 end——窗口里（先改保护 / 换页、后重算记账）排空不会按旧记账读到刚设成不可访问的页（审计 #806 第 5 条续，画面线查出）。
//   不占页：窗口里 svc 自己 memset / memcpy 这些页照常缺页走老路，不会撞上自己占着的页。安卓另有 android/native/runtime/tracking/runtime.c
static pthread_cond_t g_gate_cv = PTHREAD_COND_INITIALIZER;
static int g_drain_epoch, g_backing_on; static uint64_t g_backing_a, g_backing_n;
#else
// 安卓 drain 门：排空期 = s2a_track_drain 到 s2a_track_drain_done（C# 在中间消费 batch）。持门期间
//   checked store 提交一律 -EAGAIN：settle 在取 g_mu 之前就先交换 watch/rearm、按旧快照比对，门把这段窗口整个罩住。
//   锁序（owner 裁定）：VM g_mu → tracker g_mu → 本门，提交侧只 trylock 不等待——排空方「门 → g_mu」的反向靠 trylock 破坏。
static pthread_mutex_t g_drain_gate = PTHREAD_MUTEX_INITIALIZER;
#endif
// 计数：模拟成功次数 / 字节 / 累计耗时（纳秒，原生层量）；没模拟的原因 0 无缓冲担保 1 污染 2 碰 GPU 改过字节 3 排空中 4 位图槽满 5 越子页条件 6 别名建不出 7 解码不认 / 越页
static _Atomic uint64_t g_es_n, g_es_bytes, g_es_ns, g_es_why[8];
static void ebm_alloc(void) {   // 非信号路径：开关开时一次 mmap 位图池（ESLOTS × 512 B = 8 MB 虚拟，按用到的槽占物理页）
    if (atomic_load(&g_ebm)) return;
    void *p = mmap(NULL, (size_t)ESLOTS * 512, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) { TLOG("【红】拦写模拟：位图池分配失败，关闭"); atomic_store(&g_es_on, 0); return; }
    atomic_store(&g_ebm, (ebm_t *)p);
}
void s2a_track_set_emul_store(int on) { if (on) ebm_alloc(); atomic_store(&g_es_on, on); }
static uint64_t mbits(uint64_t lo, uint64_t hi) {   // 子页内 [lo, hi) 字节 → 64 字节粒度位（向外取整）
    unsigned b0 = (unsigned)(lo >> 6), b1 = (unsigned)((hi + 63) >> 6);
    return b1 - b0 >= 64 ? ~0ull : (((1ull << (b1 - b0)) - 1) << b0);
}
// C# → 本模块（非信号路径）：GPU 改过的字节表。set 向外取整到 64 字节（超集），clear 只清完全落在区间里的 64 字节块
void s2a_track_mod_set(uint64_t addr, uint64_t size) {
    if (!atomic_load(&g_es_on) || !size) return;
    for (uint64_t a = addr, e = addr + size; a < e; ) {
        uintptr_t pn = (uintptr_t)(a >> g_shift); leaf_t *l = leaf_of(pn);
        if (!l || !atomic_load(&l->mmask)) { pthread_mutex_lock(&g_mu); init_once(); l = leaf_make(pn); if (l) leaf_es_alloc(l); pthread_mutex_unlock(&g_mu); }
        uint64_t sa = a & ~(SUB - 1), se = sa + SUB, x1 = e < se ? e : se;
        if (l && l->mmask) atomic_fetch_or(&l->mmask[(size_t)LI(pn) * 8 + (unsigned)((sa >> 12) & (g_subs - 1))], mbits(a - sa, x1 - sa));
        a = x1;
    }
}
void s2a_track_mod_clear(uint64_t addr, uint64_t size) {
    if (!atomic_load(&g_es_on) || !size) return;
    uint64_t a = (addr + 63) & ~63ull, e = (addr + size) & ~63ull;
    for (; a < e; ) {
        uintptr_t pn = (uintptr_t)(a >> g_shift); leaf_t *l = leaf_of(pn);
        uint64_t sa = a & ~(SUB - 1), se = sa + SUB, x1 = e < se ? e : se;
        if (l && l->mmask) { unsigned b0 = (unsigned)((a - sa) >> 6), b1 = (unsigned)((x1 - sa) >> 6);
            uint64_t m = b1 - b0 >= 64 ? ~0ull : (((1ull << (b1 - b0)) - 1) << b0);
            atomic_fetch_and(&l->mmask[(size_t)LI(pn) * 8 + (unsigned)((sa >> 12) & (g_subs - 1))], ~m); }
        a = x1;
    }
}
// 同局交替开关（原生层 alt.c，S2A_ALT=<秒>）：-1 没在交替、0 关段、1 开段。字节表 / 担保 / 位图照常维护（S2A_TRACK_EMUL_STORE=1 即武装），
// 关段只是不模拟、写照旧走老路——切到开段时字节表是全的（关段里也一直在记）。单测不链原生层：弱符号缺省 -1，测试可覆盖
__attribute__((weak)) int s2a_alt_phase(void) { return -1; }
_Atomic uint64_t g_es_alt_off;   // 关段里本可模拟、按交替走老路的次数（诊断）
// 一个子页能不能模拟写（不看字节）：GPU 改过、缓冲担保、没污染、表已分配。why：不满足的原因（-1 = 子页根本不是 GPU 改过，不计数）
static int es_sub_ok(leaf_t *l, uintptr_t pn, unsigned s, int *why) {
    uint8_t b = (uint8_t)(1u << s);
    if (!l || !l->mmask || !l->eslot || !atomic_load(&g_ebm) || !((atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)])) & b)) { *why = -1; return 0; }
    if (atomic_load(&l->taint[LI(pn)]) & b) { *why = 1; return 0; }
    if (!(atomic_load(&l->vouch[LI(pn)]) & b)) { *why = 0; return 0; }
    return 1;
}
// 信号里调，解码之前的粗筛：缺页地址所在子页满足 es_sub_ok
int s2a_track_store_try(void *addr) {
    if (!atomic_load(&g_es_on) || !g_pg) return 0;
    if (s2a_alt_phase() == 0) { atomic_fetch_add(&g_es_alt_off, 1); return 0; }   // 交替关段
    uintptr_t pn = (uintptr_t)addr >> g_shift; leaf_t *l = leaf_of(pn); int why;
    if (es_sub_ok(l, pn, (unsigned)(((uintptr_t)addr & (g_pg - 1)) / SUB), &why)) return 1;
    if (why >= 0) atomic_fetch_add(&g_es_why[why], 1);
    return 0;
}
static int eslot_get(leaf_t *l, size_t idx) {   // 信号里可调：原子位图找空槽，CAS 挂到子页上；两线程同时挂时输的那份放回
    uint16_t k = atomic_load(&l->eslot[idx]); if (k) return k - 1;
    for (unsigned w = 0; w < ESLOTS / 64; w++) { uint64_t b = atomic_load(&g_ebm_bits[w]);
        while (~b) { unsigned i = (unsigned)__builtin_ctzll(~b);
            if (atomic_compare_exchange_weak(&g_ebm_bits[w], &b, b | (1ull << i))) {
                uint16_t mine = (uint16_t)(w * 64 + i + 1), z = 0;
                for (int j = 0; j < 64; j++) atomic_store(&g_ebm[mine - 1][j], 0);
                if (atomic_compare_exchange_strong(&l->eslot[idx], &z, mine)) {
                    uint64_t lv = atomic_fetch_add(&g_ebm_live, 1) + 1, pk = atomic_load(&g_ebm_peak);
                    while (lv > pk && !atomic_compare_exchange_weak(&g_ebm_peak, &pk, lv)) {}
                    return mine - 1; }
                atomic_fetch_and(&g_ebm_bits[w], ~(1ull << i)); return z - 1; } } }
    return -1;
}
// 信号里调（s2a_emul_store 的判定回调，写之前最后一问）：[ea, ea+len) 落在一个宿主页内、所碰子页都满足 es_sub_ok、不碰字节表、
// 不在排空中、位图槽拿得到 → 1，并计入「在途」（写完 s2a_track_store_done 减）。先加在途再看排空中：排空置标志后等在途归零，两边不会错过
int s2a_track_store_ok(uint64_t ea, uint64_t len) {
    if (!len || !g_pg || ((ea + len - 1) >> g_shift) != (ea >> g_shift)) { atomic_fetch_add(&g_es_why[7], 1); return 0; }
    uintptr_t pn = (uintptr_t)(ea >> g_shift); leaf_t *l = leaf_of(pn); uintptr_t pb = (uintptr_t)pn << g_shift;
    unsigned s0 = (unsigned)((ea - pb) / SUB), s1 = (unsigned)((ea + len - 1 - pb) / SUB); int why;
    for (unsigned s = s0; s <= s1; s++) {
        if (!es_sub_ok(l, pn, s, &why)) { atomic_fetch_add(&g_es_why[why < 0 ? 5 : why], 1); return 0; }
        uint64_t sa = pb + s * SUB, lo = ea > sa ? ea - sa : 0, hi = (ea + len < sa + SUB ? ea + len : sa + SUB) - sa;
        if (atomic_load(&l->mmask[(size_t)LI(pn) * 8 + s]) & mbits(lo, hi)) { atomic_fetch_add(&g_es_why[2], 1); return 0; }
    }
    // 排空中：先退出在途（排空在等在途归零），有上限地等它处理完（约 200 µs，C# 一次处理精确写通常远小于此），等到了再进；等不到走老路。
    // 有上限：C# 不调 drain_done（旧代码）也只是一直走老路、不挂死
    uint64_t t0 = 0, lim = 0;
    for (;;) {
        atomic_fetch_add(&g_es_inflight, 1);
        if (!atomic_load(&g_drain_busy)) break;
        atomic_fetch_sub(&g_es_inflight, 1);
#if defined(__APPLE__)
        if (!t0) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); t0 = mach_absolute_time(); lim = 200000ull * tb.denom / tb.numer; }
        while (atomic_load(&g_drain_busy) && mach_absolute_time() - t0 < lim) { }
        if (mach_absolute_time() - t0 >= lim) { atomic_fetch_add(&g_es_why[3], 1); return 0; }
#else
        if (!t0) { t0 = plat_now_ns(); lim = 200000; }
        while (atomic_load(&g_drain_busy) && plat_now_ns() - t0 < lim) { }
        if (plat_now_ns() - t0 >= lim) { atomic_fetch_add(&g_es_why[3], 1); return 0; }
#endif
    }
    for (unsigned s = s0; s <= s1; s++) if (eslot_get(l, (size_t)LI(pn) * 8 + s) < 0) { atomic_fetch_sub(&g_es_inflight, 1); atomic_fetch_add(&g_es_why[4], 1); return 0; }
    return 1;
}
// 信号里调：s2a_emul_store 写成之后。[ea, ea+len) 在各子页的「CPU 写过」位图里置位（同值写照记），页进排空环，在途减一
void s2a_track_store_done(uint64_t ea, uint64_t len, uint64_t ns) {
    uintptr_t pn = (uintptr_t)(ea >> g_shift); leaf_t *l = leaf_of(pn); uintptr_t pb = (uintptr_t)pn << g_shift; uint8_t sbits = 0;
    for (uint64_t a = ea, e = ea + len; a < e; ) {
        unsigned s = (unsigned)((a - pb) / SUB); uint64_t sa = pb + s * SUB, x1 = e < sa + SUB ? e : sa + SUB;
        int k = (int)atomic_load(&l->eslot[(size_t)LI(pn) * 8 + s]) - 1;
        for (uint64_t b = a - sa; b < x1 - sa; ) {   // 按 64 位字置位
            unsigned w = (unsigned)(b >> 6), b0 = (unsigned)(b & 63), n = (unsigned)((x1 - sa - b) < 64 - b0 ? (x1 - sa - b) : 64 - b0);
            atomic_fetch_or(&g_ebm[k][w], (n >= 64 ? ~0ull : ((1ull << n) - 1)) << b0); b += n; }
        sbits |= (uint8_t)(1u << s); a = x1;
    }
    atomic_fetch_or(&l->ebits[LI(pn)], sbits); enqueue(l, pn);
    atomic_fetch_add(&g_es_n, 1); atomic_fetch_add(&g_es_bytes, len); atomic_fetch_add(&g_es_ns, ns);
    atomic_fetch_sub(&g_es_inflight, 1);
}
void s2a_track_note_store_fail(int why) { atomic_fetch_add(&g_es_why[why & 7], 1); }
// 排空后、C# 处理完精确写之后调：清「排空中」，模拟写恢复
void s2a_track_drain_done(void) {
    atomic_store(&g_drain_busy, 0);
#if defined(__APPLE__)
    pthread_mutex_lock(&g_mu); g_drain_epoch = 0; pthread_cond_broadcast(&g_gate_cv); pthread_mutex_unlock(&g_mu);
#else
    pthread_mutex_unlock(&g_drain_gate);
#endif
}
#if !defined(__APPLE__)
// ---------- 安卓 checked store（s2a_mem_write32_checked，#968 owner 裁定）----------
// 提交锁序：VM g_mu（调用方已持）→ tracker g_mu → drain 门，后两级只 trylock。任一拿不到即按相反顺序放掉已得的、回 -EAGAIN——
//   实现内不自旋，调用方（fps.c）下一帧再试。只占这一页：经共享别名写，绝不碰原映射的保护，不占其他页。
static int store32_undo(int e) { pthread_mutex_unlock(&g_drain_gate); pthread_mutex_unlock(&g_mu); return e; }
// 占用一页：成功回 0 时持 tracker g_mu + drain 门 + 页 PG_BUSY；*prior = 被占前页状态（页无跟踪 = 0xff，不占页）。
//   -EAGAIN：锁竞争、页 BUSY、子页 GPU 改过未落地（act&want）、精确写快照在途（psnap）、READFLUSH 不可读——重保护 / 替页 / 排空中都归这里。
//   -EACCES：外部记过的保护（客人 0x02 / prot_changed，lastp 0xfe 或从没跟踪过的 0xff）按内核现态判，宿主不可写。
int s2a_track_store32_claim(uint64_t addr, uint8_t *prior) {
    *prior = 0xff;
    if (pthread_mutex_trylock(&g_mu)) return -EAGAIN;
    if (pthread_mutex_trylock(&g_drain_gate)) { pthread_mutex_unlock(&g_mu); return -EAGAIN; }
    if (!g_pg) return 0;   // 未跟踪：两锁照持（调用方统一在 release 放），下面只走别名写
    uintptr_t pn = (uintptr_t)(addr >> g_shift); leaf_t *l = leaf_of(pn);
    uint8_t lp = l ? atomic_load(&l->lastp[LI(pn)]) : 0xff;
    if (!l || lp == 0xfe || lp == 0xff) {   // 没跟踪过 / 外部记过：记账里的权限与 backing 都不可信，按内核现态核
        int shared = -1;
        int kp = s2a_track_platform_prot_shared(addr, &shared);
        if (kp < 0) return store32_undo(-EFAULT);
        if (!shared) return store32_undo(-EOPNOTSUPP);   // 私有 backing：建不出共享别名（mremap 也只回 EINVAL，先在此判死）
        if (!(kp & PROT_WRITE)) return store32_undo(-EACCES);
    }
    if (!l) return 0;      // 没跟踪过且共享可写：不占页，只走别名写
    if (lp == PROT_NONE) return store32_undo(-EAGAIN);   // READFLUSH 不可读：等回写落地，下帧再来
    unsigned sub = (unsigned)(((uintptr_t)addr & (g_pg - 1)) / SUB);
    uint8_t st = atomic_load(&l->state[LI(pn)]);
    if (st == PG_BUSY) return store32_undo(-EAGAIN);
    if ((atomic_load(&l->act[LI(pn)]) & atomic_load(&l->want[LI(pn)])) >> sub & 1) return store32_undo(-EAGAIN);
    if (atomic_load(&l->psnap[LI(pn)]) >> sub & 1) return store32_undo(-EAGAIN);
    if (!atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) return store32_undo(-EAGAIN);   // 信号路径缺页同时占页
    *prior = st;
    return 0;
}
// 写完放占：被写子页按 Ryujinx 要保护（want）的部分记脏 + 进排空环（与 drain 同一记账口），页状态还原，反向放门 / 锁。
void s2a_track_store32_release(uint64_t addr, uint8_t prior, int wrote) {
    if (g_pg && prior != 0xff) {
        uintptr_t pn = (uintptr_t)(addr >> g_shift); leaf_t *l = leaf_of(pn);
        if (l) {
            if (wrote) {
                unsigned sub = (unsigned)(((uintptr_t)addr & (g_pg - 1)) / SUB);
                uint8_t m = atomic_load(&l->want[LI(pn)]) & (uint8_t)(1u << sub);
                if (m) { atomic_fetch_or(&l->dirty[LI(pn)], m); enqueue(l, pn); }
            }
            atomic_store(&l->state[LI(pn)], prior);
        }
    }
    pthread_mutex_unlock(&g_drain_gate);
    pthread_mutex_unlock(&g_mu);
}
#endif
#if defined(__APPLE__)
// begin：等在途排空期结束、挂「换页中」（同一时刻只一个事务：原生层改表系统调用由 svc_mem 外层串行）。调用方不持 svc_mem 的锁
//   （排空期里 C# 会经 IsRangeMapped 进 svc_mem）。source 是别名源（苹果不另记，同安卓参数位）。返回 0；范围不是整宿主页回 EINVAL
int s2a_track_backing_begin(uint64_t addr, uint64_t size, uint64_t source) {
    (void)source;
    pthread_mutex_lock(&g_mu); init_once();
    if (!size || addr % g_pg || size % g_pg || size > UINT64_MAX - addr) { pthread_mutex_unlock(&g_mu); return EINVAL; }
    if (g_backing_on) FATAL("换页事务嵌套（%#llx+%#llx 未结束又开 %#llx+%#llx）", (unsigned long long)g_backing_a, (unsigned long long)g_backing_n, (unsigned long long)addr, (unsigned long long)size);
    while (g_drain_epoch) pthread_cond_wait(&g_gate_cv, &g_mu);
    g_backing_on = 1; g_backing_a = addr; g_backing_n = size;
    pthread_mutex_unlock(&g_mu);
    return 0;
}
// end：提交了（committed）就把这段按「外部改过保护」重算（同 s2a_track_prot_changed：快照作废、跟踪中的子页按脏报），再放排空期进来。
//   没提交（失败完整回滚）只放闸。mapped 同安卓参数位（苹果的重算不分映射 / 解除）
void s2a_track_backing_end(uint64_t addr, uint64_t size, int mapped, int committed) {
    (void)mapped;
    pthread_mutex_lock(&g_mu);
    if (!g_backing_on || g_backing_a != addr || g_backing_n != size) FATAL("换页事务 end 与 begin 不配（end %#llx+%#llx）", (unsigned long long)addr, (unsigned long long)size);
    if (committed) for (uintptr_t pn = (uintptr_t)(addr >> g_shift), q = (uintptr_t)((addr + size - 1) >> g_shift); pn <= q; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
        claim_page(l, pn); prot_changed_page(l, pn);
    }
    g_backing_on = 0; pthread_cond_broadcast(&g_gate_cv);
    pthread_mutex_unlock(&g_mu);
}
#endif
void s2a_track_es_stats(uint64_t out[12]) {
    out[0] = g_es_n; out[1] = g_es_bytes; out[2] = g_es_ns; for (int i = 0; i < 8; i++) out[3 + i] = g_es_why[i]; out[11] = g_ebm_peak;
}

void s2a_track_backing_reset(uint64_t addr, uint64_t size) {
    if (!g_pg) return;   // loader 初始映射早于 GPU/tracker 初始化
    if (!size || addr % g_pg || size % g_pg || size > UINT64_MAX - addr)
        FATAL("backing reset 范围不是完整宿主页");
    pthread_mutex_lock(&g_mu);
    if (atomic_load(&g_drain_busy) || atomic_load(&g_es_inflight)) FATAL("backing reset 时 GPU/guest 未停稳");
    for (uintptr_t pn = (uintptr_t)(addr >> g_shift), end = (uintptr_t)((addr + size) >> g_shift); pn < end; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) { pn |= LEAF_N - 1; continue; }
        size_t i = LI(pn);
        uint8_t snapshots = atomic_exchange(&l->psnap[i], 0);
        for (unsigned s = 0; s < g_subs; s++) {
            size_t sub = i * 8 + s;
            if (snapshots >> s & 1) slot_put(atomic_load(&l->slot[sub]));
            atomic_store(&l->slot[sub], 0); l->hash[sub] = 0;
            if (l->mmask) atomic_store(&l->mmask[sub], 0);
            if (l->eslot) {
                unsigned k = atomic_exchange(&l->eslot[sub], 0);
                if (k) {
                    --k;
                    for (unsigned w = 0; w < 64; w++) atomic_store(&g_ebm[k][w], 0);
                    atomic_fetch_and(&g_ebm_bits[k / 64], ~(1ull << (k % 64)));
                    atomic_fetch_sub(&g_ebm_live, 1);
                }
            }
        }
        atomic_store(&l->want[i], 0); atomic_store(&l->dirty[i], 0);
        atomic_store(&l->watch[i], 0); atomic_store(&l->rearm[i], 0);
        atomic_store(&l->act[i], 0); atomic_store(&l->rfm[i], 0);
        atomic_store(&l->vouch[i], 0); atomic_store(&l->taint[i], 0); atomic_store(&l->ebits[i], 0);
        atomic_store(&l->lastp[i], 0xfe); atomic_store(&l->state[i], PG_RW);
#if !defined(__APPLE__)
        atomic_store(&l->reject[i], 0);   // 新世代：上一代的过期缺页计数不能带到这页
#endif
        // 已排队的页号保留，让 drain 消费空记录；不丢失同页随后新世代的入队。
    }
    pthread_mutex_unlock(&g_mu);
}

// ---------- 排空 ----------
static s2a_track_precise *g_pr; static uint32_t g_npr, g_cpr;
static s2a_track_range *g_rg; static uint32_t g_nrg, g_crg;
// 拦写模拟：一页里有模拟写待报的子页，按「CPU 写过」位图出精确写（与快照比对出的记录同一种，C# 同样处理；同一子页两种记录各出一条）
static void esettle(leaf_t *l, uintptr_t pn) {
    uint8_t eb = atomic_exchange(&l->ebits[LI(pn)], 0); if (!eb || !l->eslot) return;
    for (unsigned s = 0; s < g_subs; s++) if (eb >> s & 1) {
        int k = (int)atomic_load(&l->eslot[(size_t)LI(pn) * 8 + s]) - 1; if (k < 0) continue;
        uint64_t bits[64], nz = 0; for (int j = 0; j < 64; j++) { bits[j] = atomic_exchange(&g_ebm[k][j], 0); nz |= bits[j]; }
        if (!nz) continue;
        if (g_npr == g_cpr) { g_cpr = g_cpr ? g_cpr * 2 : 256; g_pr = realloc(g_pr, g_cpr * sizeof *g_pr); if (!g_pr) FATAL("精确写表分配失败"); }
        s2a_track_precise *r = &g_pr[g_npr++]; r->addr = ((uint64_t)pn << g_shift) + s * SUB; memcpy(r->bits, bits, sizeof bits);
    }
}
// 拍了快照的子页（页已设回只读、内容稳定）逐字节比：变了的字节进位图。位图之间不合并：没变的字节可能正是 GPU 改过、还没回写的，
// 并进来会被当成 CPU 写、用客体内存旧值覆盖 GPU 数据（旧库第一版段超 64 退回整子页普通事件，暗黑2 / 怪猎读回 7→109 / 2→3277 次）
static void psettle(uintptr_t pn, uint8_t ps, const uint16_t *k) {
    for (unsigned s = 0; s < g_subs; s++) if (ps >> s & 1) {
        const uint8_t *o = snap_at(k[s]), *c = (const uint8_t *)((pn << g_shift) + s * SUB);
        uint64_t bits[64] = {0}; unsigned nb = 0, runs = 0; int prev = 0;
        // 比对（排空线程，正常上下文）：整块相等直接跳过。NEON 一次 vceqq 比 16 字节（比 8 字节快路径再少一半迭代）；
        //   有差异的块退回逐字节，位图 / 字节计数 / 连续段计数与纯逐字节版完全一致（块内前 8 字节相等时旧版会整 8 字节跳过，
        //   跳过的都是相等字节、对位图无贡献，prev 归零语义一致）。非 ARM 宿主（x86 CI / Linux 构建）照旧逐字节
#if defined(__ARM_NEON)
        for (unsigned i = 0; i + 16 <= SUB; i += 16) {
            if (vminvq_u8(vceqq_u8(vld1q_u8(o + i), vld1q_u8(c + i))) == 0xff) { prev = 0; continue; }
            for (unsigned j = i; j < i + 16; j++) { int d = o[j] != c[j]; if (d) { bits[j / 64] |= 1ull << (j % 64); nb++; runs += !prev; } prev = d; }
        }
        for (unsigned i = SUB & ~(unsigned)15; i < SUB; i++) { int d = o[i] != c[i]; if (d) { bits[i / 64] |= 1ull << (i % 64); nb++; runs += !prev; } prev = d; }
#else
        for (unsigned i = 0; i < SUB; ) {
            if (i % 8 == 0 && *(const uint64_t *)(o + i) == *(const uint64_t *)(c + i)) { i += 8; prev = 0; continue; }
            int d = o[i] != c[i]; if (d) { bits[i / 64] |= 1ull << (i % 64); nb++; runs += !prev; } prev = d; i++;
        }
#endif
        slot_put(k[s]);
        if (!nb) { atomic_fetch_add(&g_psame, 1); continue; }
        if (g_npr == g_cpr) { g_cpr = g_cpr ? g_cpr * 2 : 256; g_pr = realloc(g_pr, g_cpr * sizeof *g_pr); if (!g_pr) FATAL("精确写表分配失败"); }
        s2a_track_precise *r = &g_pr[g_npr++]; r->addr = ((uint64_t)pn << g_shift) + s * SUB; memcpy(r->bits, bits, sizeof bits);
        atomic_fetch_add(&g_pruns, runs); atomic_fetch_add(&g_pbytes, nb);
    }
}
// 一页的观察中 / 快照子页落地：先把这些子页恢复「要保护」、页设回只读，再比（顺序不能反：比完到设只读之间 CPU 对同一子页的写永久漏报，
// 旧库 t_track ⑤ 修前 1 秒漏报约 5 万次、巫师3 挂死帧常量缓冲 4 KB 块级旧内容）。设只读后再写会缺页、走正常记脏；比对用设只读前取下的哈希 / 槽号
static uint8_t settle(leaf_t *l, uintptr_t pn) {
    uint8_t wa = atomic_exchange(&l->watch[LI(pn)], 0), ra = atomic_exchange(&l->rearm[LI(pn)], 0), ps = atomic_exchange(&l->psnap[LI(pn)], 0), chg = 0;
    if (!wa && !ra && !ps) return 0;
    uint64_t h0[8]; uint16_t k0[8];
    for (unsigned s = 0; s < g_subs; s++) { h0[s] = l->hash[(size_t)LI(pn) * 8 + s]; k0[s] = l->slot[(size_t)LI(pn) * 8 + s]; }
    pthread_mutex_lock(&g_mu);
    // 拍了快照的子页：Ryujinx 仍记 GPU 改过（act）的，精确写不会让它重设保护，由这里恢复；Ryujinx 已改了意图的（reprotect 清了 act）以它为准
    atomic_fetch_or(&l->want[LI(pn)], (uint8_t)(wa | ra | (ps & atomic_load(&l->act[LI(pn)]))));
    for (;;) {   // 别的线程正在缺页里解开这页（BUSY）：等它落地再设只读
        uint8_t st = PG_RW; if (atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) { if (mp(pn, PROT_READ)) { atomic_store(&l->state[LI(pn)], PG_RW); break; } atomic_store(&l->state[LI(pn)], PG_RO); atomic_fetch_add(&g_rearms, 1); break; }
        if (st == PG_RO) {   // 已受保护：READFLUSH 的不可读页先降只读，下面要读内容比对（比完由 rf_apply 再设回不可读）
            if (atomic_load(&l->lastp[LI(pn)]) == PROT_NONE) { st = PG_RO; if (!atomic_compare_exchange_strong(&l->state[LI(pn)], &st, PG_BUSY)) continue; mp(pn, PROT_READ); atomic_store(&l->state[LI(pn)], PG_RO); }
            break; }
    }
    pthread_mutex_unlock(&g_mu);
    for (unsigned s = 0; s < g_subs; s++) if (wa >> s & 1) { if (sub_hash((pn << g_shift) + s * SUB) != h0[s]) chg |= (uint8_t)(1u << s); }
    if (ps) psettle(pn, ps, k0);
    if (chg) atomic_fetch_and(&l->want[LI(pn)], (uint8_t)~chg);   // 变了的子页报脏，保护意图交还 Ryujinx（它同步时自己重设）
    if (g_rf || atomic_load(&g_rfm_any)) { pthread_mutex_lock(&g_mu); rf_apply(l, pn); pthread_mutex_unlock(&g_mu); }   // READFLUSH（全局或定向）：比对读完内容后再设不可读
    atomic_fetch_add(&g_watch_hit, (uint64_t)__builtin_popcount(chg)); atomic_fetch_add(&g_watch_miss, (uint64_t)__builtin_popcount(wa & ~chg));
    return chg;
}
static void range_add(uint64_t a, uint64_t n) {
    if (g_nrg && g_rg[g_nrg - 1].addr + g_rg[g_nrg - 1].size == a) { g_rg[g_nrg - 1].size += n; return; }
    if (g_nrg == g_crg) { g_crg = g_crg ? g_crg * 2 : 256; g_rg = realloc(g_rg, g_crg * sizeof *g_rg); if (!g_rg) FATAL("脏区间表分配失败"); }
    g_rg[g_nrg++] = (s2a_track_range){a, n};
}
// Overflow reports a conservative superset, even if its bounded range list fills
// or cannot grow. Keep the previous allocation on realloc failure; the single
// envelope needs no allocation and remains valid until the next drain.
typedef struct { uint64_t first, end; int envelope; } overflow_ranges;
static s2a_track_range g_overflow_range;
static void overflow_range_add(overflow_ranges *b, uint64_t a, uint64_t n) {
    if (!b->end) b->first = a;
    b->end = a + n; // leaf/page/subpage iteration is in ascending address order.
    if (b->envelope) return;
    if (g_nrg && g_rg[g_nrg - 1].addr + g_rg[g_nrg - 1].size == a) { g_rg[g_nrg - 1].size += n; return; }
    if (g_nrg >= RING) { b->envelope = 1; return; }
    if (g_nrg == g_crg) {
        uint32_t cap = g_crg ? g_crg * 2 : 256;
        if (cap > RING) cap = RING;
        s2a_track_range *next = realloc(g_rg, (size_t)cap * sizeof *next);
        if (!next) { b->envelope = 1; return; }
        g_rg = next; g_crg = cap;
    }
    g_rg[g_nrg++] = (s2a_track_range){a, n};
}
// READFLUSH：把宿主读放开的页设回不可读（只设还有 GPU 改过子页的；rf_apply 自己判）。排空开头调（非信号路径）
static void rf_rearm_hostread(void) {
    if (!g_rf && !atomic_load(&g_rfm_any)) return;
    uint64_t t = atomic_load(&g_rfq_t), h = atomic_load(&g_rfq_h);
    pthread_mutex_lock(&g_mu);
    if (atomic_exchange(&g_rfq_over, 0)) {
        for (uintptr_t t0 = 0; t0 < (1u << TOP_BITS); t0++) { leaf_t *l = atomic_load(&g_top[t0]); if (!l) continue;
            for (uintptr_t i = 0; i < LEAF_N; i++) if (atomic_load(&l->lastp[i]) == PROT_READ) { rf_apply(l, (t0 << LEAF_BITS) | i); if (atomic_load(&l->lastp[i]) == PROT_NONE) atomic_fetch_add(&g_rf_rearm, 1); } }
    }   // 整表扫过之后照样走下面的环：清掉已写的槽（重复设一次是空操作），下标才能复用
    for (; t < h; t++) {
        uintptr_t v = atomic_load(&g_rfq[t % RFQ]);
        if (!v) break;   // 写入方占了下标、还没写槽（被抢占 / 冻结）：留到下次排空，不在锁里等
        atomic_store(&g_rfq[t % RFQ], 0);
        uintptr_t pn = v - 1; leaf_t *l = leaf_of(pn);
        if (l) { rf_apply(l, pn); if (atomic_load(&l->lastp[LI(pn)]) == PROT_NONE) atomic_fetch_add(&g_rf_rearm, 1); }
    }
    atomic_store(&g_rfq_t, t);
    pthread_mutex_unlock(&g_mu);
    // 每 10 秒一行累计（九款每帧触发次数按它算）
    static uint64_t last;
#if defined(__APPLE__)
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    uint64_t now = plat_now_ns();
#endif
    if (now - last > 10000000000ull) { last = now;
        { char b[900]; int o = snprintf(b, sizeof b, "缺页处模拟读·模拟不了：类别 别名无 %llu / 不认识 %llu / 立即数 %llu / 未缩放 %llu / 寄存器偏移 %llu / 对 %llu / 获取 %llu / 独占原子 %llu / SIMD 结构 %llu / 写类 %llu；指令：",
              (unsigned long long)g_ef_cls[9], (unsigned long long)g_ef_cls[0], (unsigned long long)g_ef_cls[1], (unsigned long long)g_ef_cls[2], (unsigned long long)g_ef_cls[3], (unsigned long long)g_ef_cls[4],
              (unsigned long long)g_ef_cls[5], (unsigned long long)g_ef_cls[6], (unsigned long long)g_ef_cls[7], (unsigned long long)g_ef_cls[8]);
          for (int i = 0; i < 16 && o < (int)sizeof b - 60; i++) if (atomic_load(&g_ef_n[i])) o += snprintf(b + o, sizeof b - (size_t)o, " %08x×%llu（pc %#llx）", atomic_load(&g_ef_insn[i]), (unsigned long long)atomic_load(&g_ef_n[i]), (unsigned long long)atomic_load(&g_ef_pc[i]));
          TLOG("%s", b); }
        TLOG("READFLUSH 累计：回写经别名写 %llu 页；宿主不经保护读 别名 %llu 页 / 直接 %llu 段；游戏读写不可读页先回写 %llu（其中定向没登记的页 %llu、只回写所碰子页 %llu）、缺页处模拟读 %llu、宿主读放开 %llu、放开后设回不可读 %llu、定向登记 %llu 页", (unsigned long long)atomic_load(&g_wa_pages), (unsigned long long)atomic_load(&g_ru_pages), (unsigned long long)atomic_load(&g_ru_direct), (unsigned long long)atomic_load(&g_rf_flush),
             (unsigned long long)atomic_load(&g_rf_unmarked), (unsigned long long)atomic_load(&g_rf_partial), (unsigned long long)atomic_load(&g_rf_emul), (unsigned long long)atomic_load(&g_rf_hostread), (unsigned long long)atomic_load(&g_rf_rearm), (unsigned long long)atomic_load(&g_rfm_pages)); }
}
// 登记定向读时回写页（非信号路径；GPU 线程在信号量精确写 / DMA 的 GPU 读回之后调）：范围内每页打标记，含 GPU 改过子页的立刻设不可读
void s2a_track_mark_readflush(uint64_t addr, uint64_t size) {
    if (!g_pg || !size) return;
    uintptr_t p0 = (uintptr_t)addr >> g_shift, q = (uintptr_t)(addr + size - 1) >> g_shift;
    pthread_mutex_lock(&g_mu);
    for (uintptr_t pn = p0; pn <= q; pn++) {
        leaf_t *l = leaf_of(pn); if (!l) continue;
        if (!atomic_exchange(&l->rfm[LI(pn)], 1)) {
            uint64_t n = atomic_fetch_add(&g_rfm_pages, 1) + 1;
            if (n <= 3 || (n & (n - 1)) == 0) TLOG("定向读时回写：登记第 %llu 页 %#llx", (unsigned long long)n, (unsigned long long)(pn << g_shift));
        }
        atomic_store(&g_rfm_any, 1);
        rf_apply(l, pn);
    }
    pthread_mutex_unlock(&g_mu);
}
static void (*g_remap_cb)(uint64_t, uint64_t);
void s2a_track_set_remap_cb(void (*cb)(uint64_t, uint64_t)) { g_remap_cb = cb; }
void s2a_track_backing_changed(uint64_t addr, uint64_t size) { if (g_remap_cb && size) g_remap_cb(addr, size); }
void s2a_track_drain(s2a_track_batch *out) {
#if !defined(__APPLE__)
    pthread_mutex_lock(&g_drain_gate);   // 安卓排空期入口：drain_done 才放门；!g_pg 早退同样持门到 done，保持配对
#endif
    g_npr = g_nrg = 0; memset(out, 0, sizeof *out);
    if (!g_pg) return;
#if defined(__APPLE__)
    pthread_mutex_lock(&g_mu); while (g_backing_on) pthread_cond_wait(&g_gate_cv, &g_mu); g_drain_epoch = 1; pthread_mutex_unlock(&g_mu);
#endif
    // 拦写模拟：置「排空中」、等在途模拟写落地，到 C# 处理完精确写（s2a_track_drain_done）之间新的写走老路——
    // C# 会拿处理前抄下的内容放回被回写改掉的字节，并发的模拟写会被放回盖掉（docs/研究/拦写模拟.md §5）
    if (atomic_load(&g_es_on)) {
        atomic_store(&g_drain_busy, 1); while (atomic_load(&g_es_inflight)) {}
        static uint64_t last;
#if defined(__APPLE__)
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
        uint64_t now = plat_now_ns();
#endif
        if (now - last > 10000000000ull) { last = now; uint64_t n = atomic_load(&g_es_n);
            TLOG("拦写模拟：累计模拟 %llu 次 %llu 字节，每次平均 %.2f µs；没模拟：无缓冲担保 %llu、污染 %llu、碰 GPU 改过字节 %llu、排空中 %llu、位图槽满 %llu、越子页条件 %llu、别名建不出 %llu、解码不认 / 越页 %llu；位图槽峰值 %llu",
                 (unsigned long long)n, (unsigned long long)atomic_load(&g_es_bytes), n ? atomic_load(&g_es_ns) / 1000.0 / (double)n : 0.0,
                 (unsigned long long)g_es_why[0], (unsigned long long)g_es_why[1], (unsigned long long)g_es_why[2], (unsigned long long)g_es_why[3],
                 (unsigned long long)g_es_why[4], (unsigned long long)g_es_why[5], (unsigned long long)g_es_why[6], (unsigned long long)g_es_why[7], (unsigned long long)g_ebm_peak); }
    }
    rf_rearm_hostread();
    if (atomic_exchange(&g_overflow, 0)) {
#ifndef S2A_TRACK_TEST_OLD_RING
            atomic_store(&g_rreset, 1);
            while (atomic_load(&g_rwriters)) {
#ifdef S2A_TRACK_TEST
                if (s2a_track_test_ring_reset_wait) s2a_track_test_ring_reset_wait();
#endif
            }
#ifdef S2A_TRACK_TEST
            if (s2a_track_test_ring_retired) s2a_track_test_ring_retired(atomic_load(&g_rwriters));
#endif
            for (unsigned slot = 0; slot < RING; slot++) { atomic_store(&g_ring[slot], 0); atomic_store(&g_rseq[slot], 0); }
#endif
        atomic_fetch_add(&g_overflows, 1); atomic_store(&g_rtail, atomic_load(&g_rhead)); TLOG("【红】脏页环溢出（%d），本批按全部跟踪区间写过处理", RING);
        overflow_ranges batch = {0};
        for (uintptr_t t0 = 0; t0 < (1u << TOP_BITS); t0++) { leaf_t *l = atomic_load(&g_top[t0]); if (!l) continue;
            for (uintptr_t i = 0; i < LEAF_N; i++) {
                // Capture notification inputs before the existing overflow
                // settlement clears them. Do not use dirty to restore protection.
                uint8_t notify = atomic_load(&l->want[i]) | atomic_exchange(&l->dirty[i], 0)
                    | atomic_load(&l->watch[i]) | atomic_load(&l->rearm[i])
                    | atomic_load(&l->psnap[i]) | atomic_load(&l->ebits[i]);
                atomic_store(&l->queued[i], 0);
                uintptr_t pn = (t0 << LEAF_BITS) | i;
                if (atomic_load(&l->watch[i]) | atomic_load(&l->rearm[i]) | atomic_load(&l->psnap[i])) {
                    atomic_fetch_or(&l->rearm[i], atomic_exchange(&l->watch[i], 0)); settle(l, pn);
                }
                if (atomic_load(&l->ebits[i])) esettle(l, pn);
                for (unsigned sub = 0; sub < g_subs; sub++) if (notify >> sub & 1)
                    overflow_range_add(&batch, ((uint64_t)pn << g_shift) + sub * SUB, SUB);
#ifdef S2A_TRACK_TEST
                if (s2a_track_test_overflow_visited) s2a_track_test_overflow_visited(pn);
#endif
            }
        }
#ifndef S2A_TRACK_TEST_OLD_RING
        atomic_store(&g_rreset, 0);
#endif
        out->overflow = 1; out->precise = g_pr; out->nprecise = g_npr;
        if (batch.envelope && batch.end) {
            g_overflow_range = (s2a_track_range){batch.first, batch.end - batch.first};
            out->ranges = &g_overflow_range; out->nranges = 1;
        } else { out->ranges = g_rg; out->nranges = g_nrg; }
        atomic_fetch_add(&g_events, out->nranges);
        return;
    }
    uint64_t t0 = atomic_load(&g_rtail), t, h = atomic_load(&g_rhead);
    // 两遍：先把所有页比对完（精确写进表），再收普通区间——普通区间会让 Ryujinx 回写，回写不能早于同批快照子页的比对
    for (t = t0; t < h; t++) {
        uintptr_t v;
#ifdef S2A_TRACK_TEST_OLD_RING
        do {
            v = atomic_load(&g_ring[t % RING]);
#ifdef S2A_TRACK_TEST
            if (s2a_track_test_ring_loaded) s2a_track_test_ring_loaded();
#endif
        } while (!v);   // 写入方已占位、还没写进来：等它（只在多线程同时缺页时出现）
#else
            uint64_t published;
            do {
                published = atomic_load(&g_rseq[t % RING]);
#ifdef S2A_TRACK_TEST
                if (s2a_track_test_ring_loaded) s2a_track_test_ring_loaded();
#endif
            } while (published != t + 1);
            v = atomic_load(&g_ring[t % RING]);
#endif
        uintptr_t pn = v - 1; leaf_t *l = leaf_of(pn);
        atomic_store(&l->queued[LI(pn)], 0);   // 先清「已进环」再比对：之后的缺页会重新进环，下次排空照样比对新标的子页
        uint8_t c = settle(l, pn); if (c) atomic_fetch_or(&l->dirty[LI(pn)], c);
        esettle(l, pn);
    }
    for (t = t0; t < h; t++) {
        uintptr_t v = atomic_load(&g_ring[t % RING]); atomic_store(&g_ring[t % RING], 0);
#ifndef S2A_TRACK_TEST_OLD_RING
        atomic_store(&g_rseq[t % RING], 0);
#endif
        uintptr_t pn = v - 1; leaf_t *l = leaf_of(pn);
        uint8_t d = atomic_exchange(&l->dirty[LI(pn)], 0);
        for (unsigned s = 0; s < g_subs; s++) if (d >> s & 1) range_add(((uint64_t)pn << g_shift) + s * SUB, SUB);
    }
    atomic_store(&g_rtail, h); atomic_fetch_add(&g_events, g_nrg);
    snap_release_idle();
    out->precise = g_pr; out->nprecise = g_npr; out->ranges = g_rg; out->nranges = g_nrg;
}
void s2a_track_stats(s2a_track_stat *o) {
    *o = (s2a_track_stat){ g_faults, g_races, g_heals, g_preps, g_events, g_mprotects, g_watch_hit, g_watch_miss, g_rearms,
                           g_psnaps, g_pfull, g_psame, g_pruns, g_pbytes, g_ucw_hit, g_ucw_inter, g_restore_b, g_overflows, g_rf_flush, g_rf_hostread,
                           g_snap_peak, g_snap_chunks, g_snap_freed };
}
// 只读查询（诊断，graphics/metal/gal_pstat.m 的 GPFIFO 统计用）：addr 所在 4 KB 子页在本模块的状态位——1 Ryujinx 要保护（跟踪中）2 有待排空的脏位
// 4 观察中（随整页解开、排空时按内容判）8 GPU 改过；0 = 不在跟踪里（本模块对它写没写过一无所知）。不改任何状态、不加锁（原子读）
int s2a_track_sub_state(uint64_t addr) {
    if (!g_pg) return 0;
    uintptr_t pn = (uintptr_t)(addr >> g_shift); leaf_t *l = leaf_of(pn); if (!l) return 0;
    uint8_t b = (uint8_t)(1u << ((addr & (g_pg - 1)) / SUB));
    return (atomic_load(&l->want[LI(pn)]) & b ? 1 : 0) | (atomic_load(&l->dirty[LI(pn)]) & b ? 2 : 0)
         | (atomic_load(&l->watch[LI(pn)]) & b ? 4 : 0) | (atomic_load(&l->act[LI(pn)]) & b ? 8 : 0);
}
// 单测：把快照池块数上限压小（验槽满退回）；只在第一次 reprotect 之前或块数不超过已有时调
void s2a_track_test_snap_chunks(int n) { g_maxchunk = n < 1 ? 1 : n > MAXCHUNK ? MAXCHUNK : n; }

int s2a_track_reset_session(void) {
    // No signal handler or callback may still be using a leaf at this point.
    pthread_mutex_lock(&g_mu);
    if (atomic_load(&g_drain_busy) || atomic_load(&g_es_inflight)) { pthread_mutex_unlock(&g_mu); return EBUSY; }
#if defined(__APPLE__)
    if (g_drain_epoch || g_backing_on) { pthread_mutex_unlock(&g_mu); return EBUSY; }
    g_backing_a = g_backing_n = 0;
#endif
    g_touch = NULL; g_remap_cb = NULL; atomic_store(&g_wprep, NULL);
    for (size_t i = 0; i < (1u << TOP_BITS); i++) {
        leaf_t *l = atomic_exchange(&g_top[i], NULL); if (!l) continue;
        free(atomic_load(&l->mmask)); free(atomic_load(&l->eslot)); free(l->hash); free(l->slot); free(l);
    }
    for (int c = 0; c < MAXCHUNK; c++) {
        uint8_t *p = atomic_load(&g_snapc[c]);
        if (p && munmap(p, (size_t)CHUNK * SUB)) { int e = errno; pthread_mutex_unlock(&g_mu); return e; }
        if (p && g_lowva_note) g_lowva_note(g_lowva_id, -(int64_t)CHUNK * SUB);
        atomic_store(&g_snapc[c], NULL);
        for (int w = 0; w < CHUNK / 64; w++) atomic_store(&g_slot_bits[c][w], 0);
        atomic_store(&g_chunk_used[c], 0);
    }
    ebm_t *bits = atomic_load(&g_ebm);
    if (bits && munmap(bits, (size_t)ESLOTS * 512)) { int e = errno; pthread_mutex_unlock(&g_mu); return e; }
    atomic_store(&g_ebm, NULL);
    for (int i = 0; i < ESLOTS / 64; i++) atomic_store(&g_ebm_bits[i], 0);
    for (int i = 0; i < RING; i++) {
        atomic_store(&g_ring[i], 0);
#ifndef S2A_TRACK_TEST_OLD_RING
        atomic_store(&g_rseq[i], 0);
#endif
    }
    for (int i = 0; i < RFQ; i++) atomic_store(&g_rfq[i], 0);
    atomic_store(&g_rhead, 0); atomic_store(&g_rtail, 0); atomic_store(&g_overflow, 0);
#ifndef S2A_TRACK_TEST_OLD_RING
    atomic_store(&g_rwriters, 0); atomic_store(&g_rreset, 0);
#endif
    atomic_store(&g_rfq_h, 0); atomic_store(&g_rfq_t, 0); atomic_store(&g_rfq_over, 0);
    atomic_store(&g_rfm_any, 0); atomic_store(&g_rfm_pages, 0); atomic_store(&g_prot_pages, 0);
    atomic_store(&g_snap_live, 0); atomic_store(&g_snap_peak, 0); atomic_store(&g_snap_chunks, 0);
    atomic_store(&g_ebm_live, 0); atomic_store(&g_ebm_peak, 0);
    free(g_pr); g_pr = NULL; g_npr = g_cpr = 0;
    free(g_rg); g_rg = NULL; g_nrg = g_crg = 0;
    if (t_ps) { pthread_setspecific(g_ps_key, NULL); free(t_ps); t_ps = NULL; } t_psn = t_psc = 0;
    g_pg = g_shift = g_subs = 0; g_rf = g_walias = 0;
    atomic_store(&g_emul_on, 0); atomic_store(&g_es_on, 0);
    pthread_mutex_unlock(&g_mu);
    return 0;
}
