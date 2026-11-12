// 原生层内部公共头（不对 C# 公开；对外接口见 runtime/include/s2a_native.h）。
#pragma once
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include "s2a_native.h"
#include <pthread.h>
// 给我方宿主线程起名（11-04 能耗线：「[能耗]」行的耗能前 6 线程只认名字，没名字的只剩线程号，Pokopia 一条吃半个核的宿主线程认不出是谁）。
//   名字 ≤ 15 字节 ASCII（Linux / 安卓上限 16 含结尾），苹果 / 非苹果签名不同
static inline void s2a_thread_name(const char *name) {
#if defined(__APPLE__)
    pthread_setname_np(name);
#elif defined(__ANDROID__) || defined(_GNU_SOURCE)   // bionic 无条件声明；glibc 只在 _GNU_SOURCE 下声明
    pthread_setname_np(pthread_self(), name);
#else
    (void)name;
#endif
}

// 原生层日志写到起局最早时刻 dup 出来的原始 stderr（os.c 构造函数）：C# 侧（Ryujinx 日志器）会把 fd 2 重定向进自己的异步日志线程，
// 原生层的行会被加前缀（测试层按字面匹配标记）、崩溃时还没写出的全丢
__attribute__((weak)) int g_s2a_logfd = 2;   // 各编译单元一份弱定义、链接后同一个；os.c 构造函数改成 dup 出的 fd
// 控制台副本（iOS 起局带 S2A_LOG_CONSOLE=1 时 = 起局时原始 stdout 的 dup；-1 = 不写）：执行器用 devicectl … launch --console 实时收原生层日志行，
//   局中不再靠拷 host.log（10-21 测试出包线：手机端文件服务常挂十几分钟，列进程 / 起进程那条通道一直是好的）。写法见 logcon.c（环形缓冲 + 写线程）
__attribute__((weak)) int g_s2a_confd = -1;
// logcon.c 给强定义；这里的弱定义是只链部分源码的单测用的空实现（副本 fd 只由 s2a_logcon_start 设，空实现下恒 -1）
#ifdef S2A_LOGCON_IMPL
void s2a_logcon_push(const char *p, size_t n); int s2a_logcon_start(int fd); void s2a_logcon_flush(void);
#else
__attribute__((weak)) void s2a_logcon_push(const char *p, size_t n) { (void)p; (void)n; }
__attribute__((weak)) int s2a_logcon_start(int fd) { (void)fd; return -1; }
__attribute__((weak)) void s2a_logcon_flush(void) {}
#endif
#include <unistd.h>
// 日志落盘的唯一出口（11-07 Switch2 线 84，维护者令）：s2a_log_line（LOG）与直连层 MLOG 都经它写。logcap.c 给强定义：同一条红行只记前 8 条、之后每秒一行汇总计数，
//   host.log 到 64 MB 滚动（留开头 8 MB + 最新 16 MB）；这里的弱定义是只链部分源码的单测用的直写
#ifdef S2A_LOGCAP_IMPL
void s2a_log_out(int fd, const char *p, size_t n);
#else
__attribute__((weak)) void s2a_log_out(int fd, const char *p, size_t n) { ssize_t w = write(fd, p, n); (void)w; }
#endif
// 一行日志一次写出：多线程同时打不穿插（旧库 sw.h 同做法）
__attribute__((format(printf, 1, 2))) static inline void s2a_log_line(const char *fmt, ...) {
    char b[1024], *p = b; va_list ap, aq; va_start(ap, fmt); va_copy(aq, ap);
    int n = vsnprintf(b, sizeof b - 1, fmt, ap); va_end(ap);
    if (n < 0) { va_end(aq); return; }
    if ((size_t)n >= sizeof b - 1 && (p = malloc((size_t)n + 2))) vsnprintf(p, (size_t)n + 1, fmt, aq); else if (!p) { p = b; n = (int)sizeof b - 2; }
    va_end(aq); p[n] = '\n'; s2a_log_out(g_s2a_logfd, p, (size_t)n + 1);
    if (g_s2a_confd >= 0) s2a_logcon_push(p, (size_t)n + 1);
    if (p != b) free(p);
}
#define LOG(...) s2a_log_line("[s2a] " __VA_ARGS__)
// 同 s2a_log_line，写 fd 2（直连层 MLOG：单测靠 dup2 截 fd 2 读它的行）
__attribute__((format(printf, 1, 2))) static inline void s2a_log_line2(const char *fmt, ...) {
    char b[1024], *p = b; va_list ap, aq; va_start(ap, fmt); va_copy(aq, ap);
    int n = vsnprintf(b, sizeof b - 1, fmt, ap); va_end(ap);
    if (n < 0) { va_end(aq); return; }
    if ((size_t)n >= sizeof b - 1 && (p = malloc((size_t)n + 2))) vsnprintf(p, (size_t)n + 1, fmt, aq); else if (!p) { p = b; n = (int)sizeof b - 2; }
    va_end(aq); p[n] = '\n'; s2a_log_out(2, p, (size_t)n + 1);
    if (p != b) free(p);
}

#if defined(__ANDROID__)
// Android 地址窗口：平台实现先按最大值整块保留（platform/vawin_android.inc），起局时
// svc_mem 用 s2a_layout_need 算出本款跨度再 s2a_window_trim 收缩。非 Android 由 vawin.c
// 直接按本款跨度预留，不再使用这个最大值常量。
#define S2A_WIN_SIZE (68ull << 30)
#endif
void s2a_log_session_start(void);   // iOS 主线程：正式激活才轮换日志 / 切 fd / 起控制台副本；幂等
// energy.c：进程能耗分账（快照单位：纳秒 / 纳焦；s2a_energy_log 打「上次调用以来」一行）
typedef struct { uint64_t wall, cpu, pcpu, nj, pnj, cyc, pcyc, intr, idle; double gpu_ms, gpu_clk_ms; int ok_g; } s2a_esnap;   // gpu_ms：直连层 GPU 忙累计毫秒（时间，非能耗；ok_g = 有直连层）
int s2a_energy_snap(s2a_esnap *s);
// 两次采样之间的 GPU 忙 ms/s：分母取 GPU 时钟差（gpu_clk_ms，已入账各帧最晚 GPU 结束），不取墙钟——GPU 忙晚 8 帧在 CPU 帧边界入账，墙钟窗口会把慢帧前的时间挤进来；
//   读不到（没有直连层）返回 -1，这段时间没有帧入账返回 0
double s2a_gpu_busy_rate(const s2a_esnap *a, const s2a_esnap *b);
void s2a_energy_log(void);
int s2a_energy_capture(char *out, size_t n);
int s2a_spin_step(const uint64_t *tid, const char *const *name, const double *cores, int n, double sec, int lim);   // 游戏线程满核空转判定（energy.c）
void s2a_spin_test_reset(void);
// 初始启动/运行时仍按原规则中止。重启的纯 C 装载事务可以回到失败
// 边界，保留失败现场并通知壳；该边界不包住 C#、GPU 或客体执行。
__attribute__((noreturn)) static inline void s2a_native_fatal(void) {
    void (*boot_abort)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "s2a_session_abort_boot");
    if (boot_abort) boot_abort();
    abort();
}
#define die(...) do { LOG("FATAL " __VA_ARGS__); s2a_native_fatal(); } while (0)

// ---------- 地址空间窗口（vawin.c）----------
int  s2a_window_ok(void);                       // 是否已占到窗口
int  s2a_process_prewarmed(void);               // 仅 iOS、ActivePrewarm 精确为 1；不读游戏、不分配
void s2a_window_reserve(void);                 // 一次性预留；所有启动均由最早构造函数调用
// 实际窗口：本款跨度 + 尾部统一分配（布局之后收尾部，见 s2a_window_trim）；位置由系统给的空洞定（vawin.c vawin_reserve）
void s2a_window_get(uint64_t *base, uint64_t *size);
uint64_t s2a_window_spare(void);              // 窗口之外还能给宿主大映射的地址（收尾还回 + 窗口所在空洞其余部分，vawin.c）
void s2a_window_need(uint64_t *need, uint64_t *fit);   // 本款要的跨度、本机 2^39 以下最大能放的一块（自检提示用）
// 客体窗口里在内存 / 已压缩换出的字节（mincore 扫整窗，心跳用）
void s2a_window_resident(uint64_t *res, uint64_t *out);
int s2a_guest_fd(void); int s2a_guest_zero(uint64_t a, uint64_t n); void *s2a_guest_map_any(uint64_t len);   // vawin.c：客体内存文件后备（S2A_GUEST_FILE）——文件 fd（-1 = 没开）；还页打洞 + 原偏移重映射成不可访问（不在窗口 / 没开 = 0）
int s2a_guest_in_file(uint64_t a, uint64_t n);   // vawin.c：[a, a+n) 全在文件后备窗口里（#258 懒清零按它判走不走）
int s2a_guest_file_wanted(const char *e, uint64_t pool, uint64_t room);   // vawin.c：文件后备开不开（e = S2A_GUEST_FILE：设了按设的，"0" 关；没设 → room 非 0 且池 > room 才开；room = 起局 os_proc_available_memory，Mac 传 0）
void s2a_range_resident(uint64_t lo, uint64_t len, uint64_t *res, uint64_t *out);   // vawin.c：[lo, lo + len) ∩ 窗口的常驻 / 压缩字节
void s2a_mem_guest_split(uint64_t *heap_lo, uint64_t *heap_len, uint64_t *alias_lo, uint64_t *alias_len, uint64_t *phys);   // svc_mem.c：堆区当前段、别名区（物理映射）范围、已物理映射字节（诊断，不取锁）
void s2a_window_probe(const char *when);
uint64_t s2a_va_top(void);   // 系统给本进程的地址上限（TASK_VM_INFO max_address；读不到 0）
// 自身签名里的权限（imlent.c，iml_probe.m 首启复核）：1 = 带 key 且为 true；0 = 有权限 blob 但不带；-1 = 无签名段 / 无权限槽 / 格式不对
int s2a_ent_has(const void *mh, const char *key);                         // mh = 主程序 Mach-O 头（内存里的）
int s2a_ent_blob_has(const uint8_t *sb, size_t len, const char *key);     // 一段 SuperBlob
int s2a_ent_xml_has(const char *xml, size_t len, const char *key);        // 权限 XML plist
int s2a_va_jumbo(uint64_t va_top);   // 地址上限是不是大地址档（IML / EVA 等权限才给）：1 是 / 0 否 / -1 读不到
// 宿主页只读共享别名（alias.c）：本线程槽里映射 host_page 那一 16 KB 页、只读；信号处理里可调；失败 NULL；下次调用前有效
const uint8_t *s2a_alias_page(uint64_t host_page);
// 同上的可写版（拦写模拟用）：可读写共享别名；源页最大权限没有写 / 起局自检没过 → NULL。与只读版共用本线程槽，下次调用（任一版）前有效
uint8_t *s2a_alias_page_rw(uint64_t host_page);
// 同局交替开关（alt.c，S2A_ALT=<秒>）：-1 没在交替 / 0 关段 / 1 开段；信号处理里可调。s2a_alt_mark 在 MARK 时调
int s2a_alt_phase(void);
void s2a_alt_mark(void);
void s2a_alias_thread_init(void);
void s2a_window_trim(uint64_t size);
uint64_t s2a_module_span(const char *dir);   // loader.c：模块目录里各模块（补丁区 + 映像，2 MB 对齐）的跨度和；窗口跨度 = 各区 + 它
// 窗口尾部统一分配（vawin.c，缺省开，S2A_TAIL=0 关）：GC 只能用低区，没有簿记表的大户放尾部。user = S2A_TAIL_*；| S2A_TAIL_ONLY = 尾部放不下回 NULL（不退回低区）
enum { S2A_TAIL_METAL, S2A_TAIL_RYU, S2A_TAIL_STACK, S2A_TAIL_ALTSTACK, S2A_TAIL_TRACK, S2A_TAIL_MO, S2A_TAIL_NUSER };
#define S2A_TAIL_ONLY 0x100
#define S2A_TAIL_TAG0 242   // 虚存标签 242 + user（VM_MEMORY_APPLICATION_SPECIFIC_1 + 2 起）：地址账按它认出各使用者
void  s2a_tail_init(uint64_t base, uint64_t size);
void *s2a_tail_map(uint64_t len, int user, int prot);
void  s2a_tail_unmap(void *p, uint64_t len, int user);
int   s2a_tail_has(const void *p);
void  s2a_tail_note(char *o, size_t cap);
void s2a_fd_usage(int *open_n, uint64_t *soft, uint64_t *hard);   // 已开文件句柄数（探到 min(软上限, 4096)）+ RLIMIT_NOFILE 软 / 硬上限
int s2a_gc_limit_pick(uint64_t largest); void s2a_gc_limit_apply(void);   // GC 上限自适应三档（gclimit.c）：0 不设 / 1 总 2 GB / 2 分堆
uint64_t s2a_window_host_below(uint64_t fit, uint64_t learned);   // vawin.c：放不下标准布局时窗口下方留给宿主多少（按学到的跨度，#783）
uint64_t s2a_window_span_seen(uint64_t pid);                        // vawin.c：本款本机学到的地址跨度（wire/<程序号>/span_peak；没有 = 0）
uint64_t s2a_mem_span_now(void);                                     // svc_mem.c：本局已碰到的地址跨度（碰到的最高地址 − 窗口基址）
void s2a_low_holes(uint64_t *total, uint64_t *largest);   // 4 GB 到窗口底之间的空洞合计 / 最大块           // 布局只用前 size 字节时把尾部还给系统        // 打一行窗口探测：窗口内除自己的占位外还有没有别人的映射
void s2a_lowva_start(void);   // 低区统一记账（lowva.c，接口 runtime/include/s2a_lowva.h）：起巡检线程
int  s2a_lowva_tick(void);    // 巡检一拍，返回下一拍间隔秒数（单测直接调）
void s2a_lowva_test_reset(void (*scan)(uint64_t *, uint64_t *), uint64_t (*clk)(void));   // 单测：换扫描 / 钟（纳秒）、清状态
int  s2a_lowva_test_watching(void);   // 单测：巡检线程起没起
int  s2a_lowva_peak_tick(void);       // 不设限款的峰值巡检一拍（只扫、只记峰值），返回下一拍间隔秒数
void s2a_lowva_peak_report(const char *when);   // 收局 / 崩溃打一行宿主地址峰值（不拿锁等、不分配）
int  s2a_lowva_test_peak_watching(void);   // 单测：峰值巡检线程起没起
const char *s2a_lowva_test_peak(uint64_t *t0, uint64_t *tmin, uint64_t *tmin_s, uint64_t *bmin, uint64_t *bmin_s);   // 单测：峰值读数，返回存好的按标签快照
void s2a_low_tags(char *out, size_t cap);   // 低区 + 窗口尾部按用途标签合计一行（vawin.c）
#if defined(__APPLE__)
void s2a_low_files(const char *when);       // Mach 低区 + 窗口尾部文件映射按目录合计（vawin.c）
#endif
void s2a_lowva_crash_note(void);   // 崩溃现场打一行低区账（不拿锁）
void *s2a_lowva_test_mutex(void);   // 单测：账本锁（验 note 无锁）
// 低区账判定纯函数（lowva.c，单测直接代实数）：可选申请的保留量 / 比例上限 / 缺口（0 = 够）
uint64_t s2a_lowva_opt_reserve(uint64_t learned, uint64_t t);
int s2a_lowva_over_cap(int64_t e, uint64_t bytes, uint64_t t, uint64_t r);
uint64_t s2a_lowva_need(uint64_t t, uint64_t b, uint64_t r, int fn, uint64_t fs, uint64_t bytes, uint64_t contig, const char **why);

// ---------- 区域布局（layout.c，docs/方案_地址空间根修.md）----------
// 应用内存池 = Switch（4 GB 机型）给应用的 3285 MiB；Switch 2 给游戏 9 GiB（12 GiB 里系统留 3 GiB；同 参考实现 金刚 app_pool 0x240000000）。
//   SetHeapSize 合法上限不会超过它，VAMM 款堆区按它给（2 MiB 对齐）。svc_mem.c 读 NPDM 认出 Switch 2 时设（布局之前），之后不变
uint64_t s2a_app_pool(void); void s2a_app_pool_set(uint64_t v);   // layout.c
#define S2A_APP_POOL (s2a_app_pool())
#define S2A_HEAP_DEFAULT (S2A_APP_POOL & ~((2ull << 20) - 1))
// 标准布局（各区全有宿主地址）的跨度，含模块段；0 = 地址空间类型不支持
uint64_t s2a_layout_need(uint32_t as_type, uint64_t sys_resource_size, uint64_t module_span);
// 按宿主占到的窗口 [win_base, +win_size) 排布局：放得下标准布局就照标准排，放不下就小区在前、别名区伸出窗口。
//   out->win_size = 布局实际用的宿主地址（其余还给宿主）；*mod_base = 模块段起点。0 成功，-1 地址空间类型不支持，-2 窗口连前段都放不下
//   alias_gb：出包静态认出的开局别名区大区（GiB，含 SDK 元数据；0 = 没有）——非 0 即别名优先，乙里放得下它时别名区收到窗口末、不伸出；
//     负数 = 同样大小但读码判「上限不定」（addr_need.tsv 别名区上限 = 不定），别名优先照旧、不收窗口
//   乙另回 *shadow_base = 堆区起点：远端影子块从堆区顶往下分（far.c），与堆共用这段地址；别名区没伸出窗口（甲，或别名优先收在窗口内）为 0
#define S2A_FAR_SLACK (256ull << 20)   // 乙的堆区比应用池多给这么多：影子按 2 MiB 块取整的余量
int s2a_layout_compute(uint32_t as_type, uint64_t sys_resource_size, uint64_t module_span, int alias_gb, uint64_t win_base, uint64_t win_size, s2a_layout *out, uint64_t *mod_base, uint64_t *shadow_base);

// ---------- 远端（far.c，乙布局一律开）：别名区伸出宿主窗口那段的内容放影子区，游戏一碰即缺页代执行并记点 ----------
#define S2A_FAR_SPAN_BITS 36   // 目录最多覆盖远端起点往上 64 GiB；Mac 地址围栏也用此上界避开远端
#define S2A_FAR_SPAN (1ull << S2A_FAR_SPAN_BITS)
void s2a_far_set(uint64_t lo, uint64_t hi, uint64_t sh_lo, uint64_t sh_hi);   // [sh_lo, sh_hi) = 堆区：影子块从顶往下分，不越过堆顶（layout.c 乙）
uint64_t s2a_far_floor(void);              // 影子已分到的最低地址（没分 = 堆区顶）：堆不许长过它
uint64_t s2a_mem_heap_end(void);           // svc_mem.c：堆当前顶
int  s2a_far_has(uint64_t a, uint64_t n);
int  s2a_far_map(uint64_t a, uint64_t n);
int  s2a_far_fault(void *uc, uint64_t fault_addr, int is_write);
void s2a_far_report(const char *when);
uint8_t *s2a_far_g2h(uint64_t a);          // 远端游戏地址 → 影子地址（没分块 NULL）
void s2a_far_release(uint64_t a, uint64_t n);
uint64_t s2a_far_bind(const char *name, uint64_t v);   // 装载器：PLT 表项换成远端感知版 memcpy / memset / memmove / FlushDataCache（没有远端原样回）

// ---------- 时钟 / 熵（os.c）----------
uint64_t now_ns(void);
// 起局分段计时（boot.c）；单测只链被测文件，打点在单测里为空
void s2a_boot_mark(const char *stage);
// 通用启动配置文件 <Documents>/env.txt（envfile.c，#285）：每行 KEY=VALUE，setenv 补缺（显式环境变量优先）。
// constructor(99) 应用，早于构造期 getenv；返回真正 setenv 生效的条数。
// 诊断暂存到静态缓冲，由 host_run 在日志会话就绪后 flush；文件不在时无诊断。
int s2a_envfile_apply(const char *docs);
void s2a_envfile_log_flush(void);   // 启动单线程调用，输出后清空（重复调用不重复打印）
#ifdef S2A_UNIT_TEST
#define BOOT_MARK(s) ((void)0)
#else
#define BOOT_MARK(s) s2a_boot_mark(s)
#endif
uint64_t guest_ns(void);
uint64_t guest_tick(void);      // 系统计数器（Switch 19.2 MHz / Switch 2 31.25 MHz，s2a_guest_tick_hz）
uint64_t s2a_guest_tick_hz(void); uint64_t s2a_ns_to_tick(uint64_t ns);
void s2a_thread_set_hw_cores(int n); int s2a_thread_hw_cores(void);   // thread.c：硬件核数（Switch 4、Switch 2 8）
// 游戏时钟按原因冻结（1 后台会话、2 系统键盘、3 Mac 失焦、4 安卓退后台），全部解除才接着走（os.c）。
void guest_clock_freeze_for(int reason, int on);
void guest_clock_freeze(int on);                    // = 原因 1
uint64_t s2a_entropy64(void);

// ---------- 模块（loader.c）----------
#include <pthread.h>
// 模块表没有固定上限（11-03 大乱斗 SPECIAL：nro_modules.tsv 764 个 NRO；原定长 MAX_MOD 先 64 后 256，马力欧派对 139 个、大乱斗都撞过）：
//   起局时按本局要的个数一次分配 g_mod_cap = 起局模块数 + nro_modules.tsv 行数（nn::ro 只能装表里的 NRO，loader.c mod_table_alloc），
//   一局之内不再变、不搬家（别的线程 / 信号处理按 g_nmod 读 g_mod[i]、拿着 module_t * 都一直有效），会话复位时释放。
//   按模块下标的旁表（widen.c / fps.c / cpatch.c）同样按 g_mod_cap 现分配。
typedef struct { uint32_t st_name; uint8_t st_info, st_other; uint16_t st_shndx; uint64_t st_value, st_size; } Elf64_Sym;
typedef struct { int64_t d_tag; union { uint64_t d_val, d_ptr; } d_un; } Elf64_Dyn;
typedef struct { uint64_t r_offset, r_info; int64_t r_addend; } Elf64_Rela;
typedef struct {
    char name[16];
    uint8_t *base; size_t size;                                          // 映像（非 FAR 含补丁区）首址与大小
    uint64_t text_end, ro_off, data_off, key_page_off, key_page_size;    // 改写器 fixups.tsv 表头
    int64_t patch_off;                                                   // 相对基址；负 = 补丁区在基址前（FAR），size 不含补丁区
    uint64_t image_size, file_image_len, patch_len;                      // 仅 FAR
    int64_t patch2_off; uint64_t patch2_len;                             // 双补丁岛的另一个岛（fixups.tsv # PATCH2_OFF / PATCH2_LEN；0 = 单岛）：近布局时在基址前，FAR 时在键页后
    struct s2a_trap *traps; unsigned ntrap;                              // 两岛都够不着的必改点（fixups.tsv # TRAP 行，序号 = brk #(0x8000 + 序号)；runtime/src/traps.c）
    struct s2a_far *fars; unsigned nfar;                                 // 远跳（fixups.tsv # FAR 行，brk #0xA000，按 from 升序；runtime/src/traps.c）
    uint64_t load_bias;   // 装载偏置（fixups.tsv # LOAD_BIAS，非 FAR 小模块）：宿主映射从 base − load_bias 起，使 base + DATA_OFF 落在宿主页边界
    unsigned key_idx[4];
    const Elf64_Dyn *dyn; const Elf64_Sym *symtab; const char *strtab; unsigned nsym;
    uint32_t *symh; unsigned symh_mask;
    uint64_t init;
} module_t;
extern module_t *g_mod;
extern int g_nmod, g_mod_cap;
// 不链 loader.c 的单测替身：定长存储 + 指针（夹具自己的容量，不是产品上限）
#define S2A_TEST_MOD_TABLE(n) static module_t s2a_test_mod_store[n]; module_t *g_mod = s2a_test_mod_store; int g_mod_cap = (n)
int s2a_key_page_writable(module_t *m);
int s2a_module_rebind(module_t *m, const char *name, uint64_t v);   // loader.c：改指模块 m 对 name 的导入（出包期 GLSLC 工具模式）
// 四个线程槽：K18 = 游戏的 x18、KTLS = tpidr_el0、KTLR = tpidrro_el0（ThreadLocalRegion）、KGATE = 门入口；实际键号由装载器写进键页
extern pthread_key_t g_key18, g_keytls, g_keytlr, g_keygate;
void load_modules(const char *dir, const char **names, int n);
int s2a_module_order_ok(const char *const *names, int n);   // Horizon 装载序（loader.c）：main → subsdk0..N 数字序 → sdk，名单外的名排中间按名定序
void run_module_inits(void);
void *module_sym(module_t *m, const char *name);
void *guest_sym(const char *name);
module_t *module_of(const void *p);
// 地址在本模块任一补丁岛里（近布局的岛在映像尾、FAR 的在基址前；双岛时另一个岛见 patch2_off）
static inline int s2a_in_patch(const module_t *m, uint64_t a) {
    int64_t off = (int64_t)(a - (uint64_t)m->base);
    if (m->patch_off < 0 ? off >= m->patch_off && off < m->patch_off + (int64_t)m->patch_len : off >= m->patch_off && (uint64_t)off < m->size) return 1;
    return m->patch2_len && off >= m->patch2_off && off < m->patch2_off + (int64_t)m->patch2_len;
}
// brk 兜底点（改写器双岛模式下两岛都够不着的必改点）：种类与序号见 traps.c
enum { S2A_TRAP_TPIDR_R, S2A_TRAP_TPIDRRO_R, S2A_TRAP_TPIDR_W, S2A_TRAP_CTR };
struct s2a_trap { uint64_t off, hits; uint32_t orig; uint8_t kind, reg; };
#define S2A_TRAP_IMM0 0x8000u
#define S2A_TRAP_MAX 0x2000u   // 按编号的 brk #0x8000–0x9FFF；0xA000 是远跳
// 远跳（出包线 10-31）：两岛都够不着的 x18 单元照常进岛，越射程的 B 写成 brk #0xA000；from / to 相对基址（有符号，岛在基址前为负），entry = 从原代码进岛那一跳
struct s2a_far { int64_t from, to; uint64_t hits; uint8_t entry; };
#define S2A_FAR_IMM 0xA000u
const char *s2a_main_build_id(void);
void *s2a_libc_lookup(const char *name);
void *sw_xstack_wrap(const char *name, void *fn);
void sw_xstack_thread_init(uint64_t top, uint64_t gtop);
void sw_xstack_thread_fini(void);
int sw_is_host_code(uint64_t a);

// ---------- 门（gate.c）----------
void gate_register(uint64_t ret_abs, const char *kind, int arg, uint64_t orig);
uint64_t gate_dispatch(uint64_t ret_addr, uint64_t *regs);
void s2a_backtrace(uint64_t fp);
