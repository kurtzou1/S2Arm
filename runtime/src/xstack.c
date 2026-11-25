// 客体栈与宿主栈分开（旧库 hle_xstack.c 直接搬）：客体线程跑在游戏给的栈上（同 Horizon，见 thread.c thread_main），
// 宿主代码（svc 门、libc 直通，凡经装载器交给客体的宿主函数）一律切到本线程的宿主栈（pthread 栈）上跑。
// 为什么：游戏给的栈按 Horizon 用量（几 KiB 到几十 KiB），宿主实现几十 KiB 深、会撑爆；游戏又要求自己的代码跑在自己登记的栈区间里（见 thread_main）。
// 做法：装载器把宿主函数解析成切栈桩（entry.S xs_stubs：movz x9,#k; b xs_entry，静态代码，iOS 可用），xs_entry 按本线程槽 {cur, top, bottom}
// 判断：sp 已在宿主栈（宿主回调客体再进宿主）就直接跳；否则在 cur 下开帧、拷 256 字节 AAPCS64 栈参数（32 格；H.264 编码初始化需要 13 格）、切过去调用、切回。cur 是游标，嵌套切栈不压活帧。
// 没登记槽的线程（主线程、宿主自建线程）直接跳，行为同改前。
#include "native.h"
#include "../../platform/plat.h"
#include <pthread.h>
#if defined(__APPLE__)
#include <mach-o/getsect.h>
#elif defined(__ANDROID__) || defined(__OHOS__)
int s2a_android_is_host_code(uint64_t address);
#else
#error Unsupported native xstack platform
#endif

#define XS_MAX 8192   // = entry.S xs_stubs 条数
extern const uint32_t xs_stubs[], xs_leaf_stubs[];
// entry.S uses direct PC-relative references within this DSO. ELF must not
// preempt these two private objects; keep Apple's existing visibility.
#if defined(__ANDROID__) || defined(__OHOS__)
#define XS_INTERNAL __attribute__((visibility("hidden")))
#else
#define XS_INTERNAL
#endif
XS_INTERNAL void *g_xs_fn[XS_MAX]; // 桩号 → 宿主实现（entry.S 读）
uint64_t g_xs_key;              // 本线程槽的 pthread 键（pthread_getspecific 用）
XS_INTERNAL uint64_t g_xs_off;  // 本线程槽相对 TSD 基址的字节偏移（entry.S 读；Apple key*8，Android key 表偏移）
#undef XS_INTERNAL
static unsigned g_nxs; static pthread_mutex_t g_xs_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t g_xs_plat_once = PTHREAD_ONCE_INIT;
static int g_xs_plat_err;
typedef struct { uint64_t cur, top, bottom, gtop; } xs_slot;   // gtop：客体栈顶（拷栈参数不越过它；0 = 不限，按 256 字节拷）

__attribute__((constructor)) static void xs_key_init(void) {   // 键须在任何桩被调到之前就绪（键 0 处是 pthread 自身指针，读到会被当成槽）
    pthread_key_t k; if (pthread_key_create(&k, NULL)) die("切栈：pthread_key_create 失败");
    g_xs_key = (uint64_t)k;
}
// 不切栈的叶子函数（libc 直通表里的内存 / 字符串 / 基本数学；11-17 起套叶子桩，只在 sp 不对齐时先对齐）：调用极频繁（每帧上万次），自身几乎不用栈，跑在游戏栈上与真机 SDK 的同名函数一样浅。
// 不在此列的直通函数（strtod / strftime / mktime / localtime_r 等用栈较多、可能进系统库深处）照样切栈
static const char *const k_leaf[] = {"memcpy", "memset", "memmove", "memcmp", "memchr", "strlen", "strnlen", "strcmp", "strncmp", "strcpy", "strncpy",
    "strcat", "strncat", "strchr", "strrchr", "strstr", "strspn", "strcspn", "strpbrk", "strcasecmp", "strncasecmp", "atoi",
    "sqrtf", "cbrtf", "expf", "acosf", "cosf", "sinf", "atan2f", "fmodf", "cos", "sin", "powf", "atanf", "tanf", "asinf", "log10", "pow", "logf",
    "ldexpf", "log10f", "log", "ldexp", "frexp", "atan2", "modff", "exp2f", "exp2", "log2f", "log2", "lroundf"};
#ifdef S2A_UNIT_TEST
const char *s2a_xs_leaf_name(unsigned i) { return i < sizeof k_leaf / sizeof *k_leaf ? k_leaf[i] : NULL; }   // 单测逐个核整份名单
#endif
// 叶子函数也套桩（11-17 D-DVZZ：客体 sp 不对齐时宿主叶子函数开头一压栈就 SIGBUS）：叶子桩 xs_leaf_stubs 不切栈，只在 sp 不对齐时先对齐、调完恢复（entry.S xs_leaf_entry）
static void *xs_wrap(const char *name, void *fn, int leaf) {
    if (!fn) return fn;
    const uint32_t *stubs = leaf ? xs_leaf_stubs : xs_stubs;
    pthread_mutex_lock(&g_xs_mu);
    for (unsigned i = 0; i < g_nxs; i++) if (g_xs_fn[i] == fn) { pthread_mutex_unlock(&g_xs_mu); return (void *)&stubs[2 * i]; }   // 同一实现共用一个编号（两种桩按名字取）
    if (g_nxs == XS_MAX) { pthread_mutex_unlock(&g_xs_mu); die("切栈桩不够（%d）：%s", XS_MAX, name); }
    unsigned i = g_nxs++; g_xs_fn[i] = fn;
    pthread_mutex_unlock(&g_xs_mu);
    return (void *)&stubs[2 * i];
}
void *sw_xstack_wrap(const char *name, void *fn) {
    int leaf = 0;
    for (unsigned i = 0; i < sizeof k_leaf / sizeof *k_leaf && !leaf; i++) leaf = !strcmp(name, k_leaf[i]);
    return xs_wrap(name, fn, leaf);
}
// 不在名单里、但同样留在游戏栈上跑的宿主函数（直连层 NVN 命令录制，每帧上万次；graphics/nvn/gfx/nvn/hle_nvn.c nvn_leaf_wrap）：一律给叶子桩
void *sw_xstack_leaf(const char *name, void *fn) { return xs_wrap(name, fn, 1); }
// 客体线程在宿主栈上、进客体之前调：top = 宿主代码从这里往下用（调用方自己的活帧在其上）
static void xs_plat_init(void) {
    uint64_t off;
    g_xs_plat_err = plat_tsd_init();
    if (!g_xs_plat_err) g_xs_plat_err = plat_tsd_offset((uint32_t)g_xs_key, &off);
    if (!g_xs_plat_err) g_xs_off = off;
}

void sw_xstack_thread_init(uint64_t top, uint64_t gtop) {
    pthread_once(&g_xs_plat_once, xs_plat_init);
    if (g_xs_plat_err) die("切栈：plat_tsd_init / offset 失败（%d）", g_xs_plat_err);
    uintptr_t low, high;
    if (plat_thread_stack_bounds(&low, &high)) die("切栈：取宿主栈范围失败");
    xs_slot *s = malloc(sizeof *s); s->top = top & ~15ull; s->cur = s->top; s->bottom = low; s->gtop = gtop;
    if (!(s->top > s->bottom && s->top <= high)) die("切栈：宿主栈范围不对 top=%#llx 栈 %#llx..%#llx", (unsigned long long)s->top, (unsigned long long)s->bottom, (unsigned long long)high);
    int error = pthread_setspecific((pthread_key_t)g_xs_key, s);
    if (error) { free(s); die("切栈：登记线程槽失败（%d）", error); }
}
void sw_xstack_thread_fini(void) { xs_slot *s = pthread_getspecific((pthread_key_t)g_xs_key); pthread_setspecific((pthread_key_t)g_xs_key, NULL); free(s); }
// A signal may leave guest code only if no nested host callback owns frames
// below it. The ordinary SVC boundary occupies the fixed 832-byte gate frame.
// Host-entry threads have no guest stack and may own untracked host frames.
uint64_t sw_xstack_stop_sp(void) {
    xs_slot *s = pthread_getspecific((pthread_key_t)g_xs_key);
    return s && s->gtop && s->cur == s->top ? s->top : 0;
}
int sw_xstack_stop_boundary(void) {
    xs_slot *s = pthread_getspecific((pthread_key_t)g_xs_key);
    return s && s->gtop && (s->cur == s->top || s->cur + 832 == s->top);
}
// 地址是不是宿主自己的代码（主映像 __TEXT）：宿主借 SDK 建的客体线程入口是宿主函数，要跑宿主栈
#if defined(__ANDROID__) || defined(__OHOS__)
int sw_is_host_code(uint64_t address) {
#if defined(__OHOS__)
    // OHOS guest images are signed ELF carriers. dl_iterate_phdr sees their
    // executable segments too; the registered guest module owns classification.
    // Otherwise child guest threads would run on pthread host stacks and their
    // IPC buffers would correctly fail the guest memory mapping check.
    if (module_of((const void *)(uintptr_t)address)) return 0;
#endif
    return s2a_android_is_host_code(address);
}
#else
int sw_is_host_code(uint64_t a) {
    static uint64_t lo, hi; if (!hi) { extern const struct mach_header_64 _mh_execute_header; unsigned long sz = 0; uint8_t *p = getsegmentdata(&_mh_execute_header, "__TEXT", &sz); lo = (uint64_t)p; hi = lo + sz; }
    return a >= lo && a < hi;
}
#endif

// 即时存档续跑：本线程切栈槽 {cur, top, bottom, gtop} 的地址（没登记 = NULL）
void *sw_xstack_slot(void) { return pthread_getspecific((pthread_key_t)g_xs_key); }
