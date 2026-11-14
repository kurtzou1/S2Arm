// 原生层 ↔ C# 接口（机器可读版，与 docs/接口_原生层.md 同步；不一致以本文件为准）。
// C# 侧按本文件声明 [StructLayout(Sequential)] 结构与 [LibraryImport] 函数。
// 宿主能力表（语言/时区、内存、输入、显示、UI、解码、停止）见 s2a_hostapi.h（v1）。
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- §3 C# 单一入口（原生层 → C#）----------
enum { S2A_SVC_UNHANDLED = 0, S2A_SVC_HANDLED = 1 };

typedef struct s2a_svc_ctx {
    uint32_t num;        // 调用号
    uint32_t thread;     // 当前游戏线程句柄（真实句柄）
    uint64_t *regs;      // 门帧 x0..x30，可读可写
    void *tlr;           // 当前线程 ThreadLocalRegion（0x200 字节，IPC 消息在 +0）
    uint64_t obj;        // 0x21/0x22/0x23：会话句柄解出的 cookie；其余 0
    uint32_t obj_kind;   // obj 的种类，无为 0
    uint32_t _pad;
} s2a_svc_ctx;

typedef struct s2a_cs_api {
    uint32_t size;                                          // = sizeof(s2a_cs_api)
    uint32_t _pad;
    int  (*svc)(s2a_svc_ctx *ctx);                          // 返回 S2A_SVC_*；Result 写 regs[0]
    void (*handle_closed)(uint32_t kind, uint64_t cookie);  // 游戏关掉 C# 种类的句柄
    void (*thread_exit)(uint32_t thread);                   // 游戏线程退出
    void (*shutdown)(const char *why);                      // 进程退出前
} s2a_cs_api;

int s2a_register_cs(const s2a_cs_api *api);   // 0 成功；size 不符返回 -1 并报红

// ---------- §4.1 进程信息 ----------
typedef struct s2a_layout {
    uint64_t win_base, win_size;       // 64 GB 窗口
    uint64_t alias_base, alias_size;
    uint64_t heap_base, heap_size;     // 堆区（SetHeapSize 上限 = min(heap_size, 应用内存池 − 映像)）
    uint64_t stack_base, stack_size;
    uint64_t tlsio_base, tlsio_size;
    uint64_t aslr_base, aslr_size;     // 可随机区（GetInfo 12/13）
    uint64_t sys_resource_size;        // NPDM SystemResourceSize（≠ 0 即用虚拟地址内存）
    uint32_t as_type;                  // NPDM 地址空间类型（3 = 39 位）
    uint32_t _pad;
} s2a_layout;

uint64_t s2a_program_id(void);
uint64_t s2a_process_id(void);
const s2a_layout *s2a_layout_get(void);
uint64_t s2a_main_base(void);          // 主程序模块装载基址（未装载 = 0）：金手指 main 区
uint64_t s2a_main_region_va(uint64_t off);   // 金手指 main 区偏移按 Horizon 模块排布换成真实地址（超出起局模块 = 0）：Cheats.cs
const char *s2a_main_build_id(void);   // 主程序构建号（十六进制串，没有 = 空串）
void s2a_cheats_host_enable(void);     // 宿主有金手指界面（ios/vpad_cheats.m）时装载期登记
const char *s2a_cheats_dir(void);      // 金手指目录 <文档根>/cheats；宿主没登记 = 空串（C# 不起金手指线程）

// ---------- §4.2 句柄表 ----------
enum { S2A_OBJ_NONE, S2A_OBJ_THREAD, S2A_OBJ_EVENT_R, S2A_OBJ_EVENT_W, S2A_OBJ_SESSION,
       S2A_OBJ_SHMEM, S2A_OBJ_TMEM, S2A_OBJ_PORT, S2A_OBJ_CS_OTHER, S2A_OBJ_PROCESS };   // PROCESS：只由 s2a_handle_get(0xFFFF8001) 回，表里不存
#define S2A_H_CUR_THREAD  0xFFFF8000u
#define S2A_H_CUR_PROCESS 0xFFFF8001u

// 返回值约定（全表）：返回句柄 / 事件号的，0 = 失败；返回 int 的「查 / 关」类，1 = 成功、0 = 无此对象；例外：s2a_register_cs 0 = 成功、s2a_mem_query 恒回 0（结果在出参）
uint32_t s2a_handle_new(uint32_t kind, uint64_t cookie);              // 只许 C# 种类：SESSION / PORT / CS_OTHER
int      s2a_handle_get(uint32_t h, uint32_t *kind, uint64_t *cookie); // cookie：事件 → 事件号，共享内存 → 宿主指针，传输内存 → 0，线程 → 线程 id，进程 → pid，C# 种类 → 发句柄时的 cookie
int      s2a_handle_close(uint32_t h);   // 1 = 关掉了，0 = 无此句柄

// ---------- §4.3 事件 ----------
uint64_t s2a_event_create(uint32_t *h_read, uint32_t *h_write);   // h_write 可为 NULL；返回事件号并替 C# 持一份引用——只要句柄（如 Horizon CreateEvent）时立刻 s2a_event_release，否则事件永不释放
void     s2a_event_signal(uint64_t ev);
void     s2a_sleep_ns(int64_t ns);   // 按时睡 ns（本线程 kqueue NOTE_CRITICAL 定时器，不受 QoS 定时器余量放宽）：图形层出帧节拍用
void     s2a_event_clear(uint64_t ev);
void     s2a_event_retain(uint64_t ev);    // 跨请求持有游戏递来的事件（经 s2a_handle_get 拿到的事件号）前调，用完 s2a_event_release
void     s2a_event_release(uint64_t ev);
uint32_t s2a_event_dup_read(uint64_t ev);   // 给读端再发一个句柄（复制句柄：服务每次应答给新的，游戏关它不影响服务手里的事件）

// ---------- §4.4 共享内存 / 传输内存 ----------
uint32_t s2a_shmem_create(uint64_t size, void **host);   // *host 恒定不变（游戏只能映射到 16 KB 对齐地址，宿主缓冲不重定位）
uint32_t s2a_shmem_wrap(void *host, uint64_t size);      // 把 C# 已有的宿主后备包成共享内存句柄（不拷贝、不接管释放）；host 须 16 KB 对齐，否则报红回 0
int      s2a_tmem_get(uint32_t h, uint64_t *addr, uint64_t *size, uint32_t *perm);   // 可 SGT

// ---------- §4.5 游戏内存 ----------
typedef struct s2a_meminfo { uint64_t base, size; uint32_t state, attr, perm, _pad; } s2a_meminfo;
int  s2a_mem_query(uint64_t addr, s2a_meminfo *out);   // 恒回 0（例外，同 Horizon QueryMemory：任何地址都有一段状态，空闲 / 不可访问也写进 out）；可 SGT
int  s2a_mem_mapped(uint64_t addr, uint64_t size);   // [addr, addr + size) 全已映射回 1（同逐段 QueryMemory 遇权限 0 即否，但不并段：步数 = 涉及的子页数）；size 0 回 1；可 SGT
int  s2a_mem_readable(uint64_t addr, uint64_t size); // 逻辑读权限：同逐段QueryMemory核perm&1，但只走请求范围；空范围1，溢出/空洞/不可读0；可SGT

typedef struct s2a_track_hooks {
    void (*prot_changed)(uint64_t addr, uint64_t len);
    void (*host_write)(uint64_t addr, uint64_t len);
    // [addr, addr+len) 背后的物理页被整段换掉（共享内存映射 / 解除：vm_remap 覆盖、mmap MAP_FIXED）：同一地址现在是另一批页。
    // 渲染器零拷贝缓冲建在旧页的别名上，收到后要作废重建（10-23 帧率能耗线，缓冲零拷贝）。只改保护 / madvise 的不报（内存对象没换）
    // 约定：原生层以后任何新的「换页」路径（vm_remap 覆盖、mmap MAP_FIXED 换新页、plat_vm_alias 接进核心之后等）都要调它；
    // 回调在游戏线程的系统调用里同步执行，接收方只许登记（不等渲染线程、不拿渲染器入口锁 / 写跟踪 g_mu），重建放到渲染线程自己的取用处
    void (*backing_changed)(uint64_t addr, uint64_t len);
    // SetMemoryPermission：mprotect 与跟踪记账在同一临界区完成（先占页再改保护），与缺页自愈串行。
    // 成功返回 0，失败返回 errno（此时页保持原保护）。设置后仍会再调一次 prot_changed 通知（生产实现重复收尾幂等）。
    int (*guest_protect)(uint64_t addr, uint64_t len, int prot);
} s2a_track_hooks;
void s2a_register_track_hooks(const s2a_track_hooks *h);
// 苹果换页事务（graphics/track/glue.c 登记 track.c 的 s2a_track_backing_begin / end；未登记 = 空操作）：原生层改表系统调用（堆伸缩、Map / Unmap、
//   共享 / 物理 / 代码 / 传输内存）先 begin（等在途排空期结束、挡住新的；调用时不持 svc_mem 锁）、再改保护 / 换页、最后 end（提交了就重算记账）。
//   同一时刻只一个事务：svc_mem() 外层把改表系统调用串行。安卓走 android/native/runtime/tracking 的同名两阶段协议
void s2a_register_track_backing(int (*begin)(uint64_t addr, uint64_t len, uint64_t source), void (*end)(uint64_t addr, uint64_t len, int mapped, int committed));

// ---------- §4.6 线程 ----------
uint32_t s2a_thread_current(void);   // 可 SGT
uint64_t s2a_thread_id(uint32_t h);

// ---------- §4.6 游戏系统计数器（v2.8）：与游戏 mrs cntpct_el0 / cntvct_el0、svc GetSystemTick 读到的完全相同（19.2 MHz），任意线程可调。
// Ryujinx 侧写进时间共享内存的稳态时钟基准必须用它，否则游戏拿自己的计数器减基准会差出两个计数器零点之差（10-19 动森：差开机时长 10 小时）
uint64_t s2a_guest_tick(void);
// v2.16（Switch 2）：上面计数器的频率（Hz）。Switch 19200000，Switch 2（NPDM ACID 是 RSA-3072 布局）31250000；起局定、之后不变
uint64_t s2a_guest_tick_hz(void);
// v2.14（#863）：游戏计数器没看到的宿主时长（纳秒，零点任意）= 含睡眠的连续钟 − 游戏时间。游戏时钟冻结（后台）和宿主睡眠期间在长，其余时候不变。
//   Ryujinx 稳态时钟要把它的增量补上（真机睡眠时系统计数器停、RTC 起的稳态时钟照走），否则游戏日历落后后台 / 睡眠时长。任意线程可调
int64_t s2a_clock_unseen_ns(void);
// C# 起局时登记补时回调；App 壳在回前台、Mac 唤醒时调 s2a_clock_catchup（没登记 = 空操作）。回调在调用线程上同步执行
void s2a_clock_register_catchup(void (*cb)(void));
void s2a_clock_catchup(void);

// ---------- §4.8 屏幕宽：游戏 1080 高对应的屏幕宽（1920 = 16:9 不加宽，范围 1920–8192）----------
// Mac 读 S2A_SCREEN_W；iOS 没给时 App 壳按实际屏幕 1080 × 长边 ÷ 短边（取偶）。原生层宽屏点与 C# 宽屏包装层都只读这里。任意线程可调
int s2a_screen_w(void);
int s2a_screen_w_after_load(void);   // 装载后的屏幕宽：模块还没装载回 0、不读（名单门判不了，见 runtime/src/widen.c）
int s2a_screen_h(void);   // 以 1920 宽为基准的屏幕高：屏幕比 16:9 窄时 > 1080（上下多画），否则 1080（runtime/src/widen.c）
unsigned s2a_screen_gen(void);       // 运行中换屏的代数（每换一次加一；runtime/src/widen.c）
int s2a_screen_switch(int w, int h); // 直接换成给定的屏幕宽 / 高（Mac 模拟换屏、窗口拖拽）；变了返回 1
int s2a_screen_reaspect(void);       // iOS 按当前屏重算屏幕宽 / 高；变了返回 1
int s2a_screen_fit(int pw, int ph);  // 按窗口像素尺寸跟屏（Mac 壳窗口布局回调；同 iOS 口径，钉了原生 16:9 / 环境变量给定屏幕时不跟）；变了返回 1
int s2a_widen_force_native(int on);  // 运行中退回原生 16:9（1 = 钉 1920×1080、reaspect 不再改回；0 = 撤钉）：换了 1、没变化 0、游戏自己出宽图（要重启）-1
// 游戏自己出宽图（第二层）：屏幕宽 > 1920 且装载时启用的宽屏点 ≥ 1 回 1，否则 0；模块装完后（S2A_Init 起）有定值，C# 宽屏包装层据此只管界面层
int s2a_widen_game(void);
void s2a_game_canvas(int *w, int *h);   // 游戏画布 = 触点坐标空间（游戏自出宽 / 高图时按屏比，否则 1280×720）
int s2a_widen_layout(void);
// 第三层整套放宽验过（v2.11）：模块目录 widen_full.<档位>.tsv 有一行「1」回 1，否则 0（屏宽 > 1920 且第二层没生效时，包装层据此决定整套放宽还是 16:9 原比例居中留黑边）；S2A_WIDEN_FULL 覆盖
int s2a_widen_full(void);
// 接口 v2.15（11-01 体验线，缺口扫描族 1 / 2）：前后台 / 焦点与底座。平台壳写、服务层读
void s2a_host_focus_set(int focused);   // 平台壳：iOS 前台 / Mac 有焦点 = 1
int  s2a_host_focused(void);            // 服务层：变了就向游戏发焦点消息
void s2a_focus_suspend_set(int on);     // 服务层：游戏 SetOutOfFocusSuspendingEnabled 的值
int  s2a_focus_suspend(void);           // 平台壳：失焦时据此冻结客机
void s2a_console_mode_set(int docked);  // 平台壳：运行中切掌机 / 主机
int  s2a_console_mode(void);            // 服务层：-1 没设过、0 掌机、1 主机；变了调 ChangeDockedModeState
void s2a_host_sleep_set(int sleeping);  // 平台壳：iOS 进后台 / Mac 系统睡眠 = 1（切窗口不算）
int  s2a_host_sleeping(void);           // 服务层：变了就向 psc 模块发休眠 / 唤醒请求
// 接口 v2.17：客机冻结状态（Mac 失焦暂停 / iOS 后台 / 重启屏障）。服务层据此暂停或恢复声音渲染。
int  s2a_guest_frozen(void);            // runtime/src/thread.c；0 运行、非 0 冻结

// ---------- 起局分段计时：打一行「[起局] <段> +<距起点 ms>（本段 ms）」（起点 = 进程创建；多款容器点 Play 后改为点 Play 那刻，boot.c s2a_boot_rebase）；本段 = 距上一个打点。C# 侧在 S2A_Init 里分段时调（任意线程）----------
void s2a_boot_mark(const char *stage);

// ---------- 通用启动配置文件：<docs>/env.txt 每行 KEY=VALUE，读进来当环境变量（#285）
//   KEY 只收 [A-Z0-9_]+；# 开头与空行跳过；VALUE 原样到行尾（去 \r）；setenv(KEY, VALUE, 0) —— 显式环境变量优先
//   返回生效条数；文件不在 = 返回 0、不改任何变量、不打日志
int s2a_envfile_apply(const char *docs);

// ---------- 确定性调试（v2.10）：宿主线程往游戏内存写一律经这里。确定性档关时就是 memcpy；记录档下持锁游戏线程（含它的 C# 处理）直接写，
// 其余宿主线程的写按序进日志（拿不到串行锁时先入待办，持锁者放锁前写进去）；重放档只按日志写、宿主的写忽略。任意线程可调
void s2a_det_host_write(uint64_t guest_addr, const void *src, uint64_t len);

// ---------- 远端描述符（v2.13，runtime/src/far.c）：回 s2a_far_desc 的地址（定值，任意线程可调）。布局 { uint64_t lo; _Atomic int64_t *dir; }：
//   dir 为空 = 远端没开；否则游戏地址 va 落在 [lo, lo + 2^36) 时 dir[(va - lo) >> 21] = 该 2 MiB 块「影子 − 游戏」的差值，0 = 这块没映射。
//   C# 宿主侧访问游戏内存（GuestMemory）按它把远端地址换成影子地址，不再靠缺页代执行兜底
const void *s2a_far_desc_get(void);

// ---------- 全线程现场：每条宿主线程的名字 / 优先级 / QoS / 状态 / pc / lr / 帧指针回溯（模块+偏移或宿主符号），写 host.log 与 <文档目录>/threads.txt。
// 卡死判定在 _exit 之前调（崩溃时原生层自己调）；任意线程可调，回线程数。iOS 文档目录 = Documents，Mac = S2A_DOCS（没给只写 host.log）
int s2a_dump_threads(const char *why);

// ---------- 渲染器每上屏一帧调一次（自动玩家 / 健康表的帧数；frames.tsv 由渲染器自己写）----------
void s2a_frame_presented(void);
// 出图实际跟的节拍（30 / 60）：渲染器每次上屏 / 节拍变化时报（通用模式 RenderLoop.FrameInterval、直连 host_adapt.m dm_guest_frame_tick）；自动玩家按它折算按 30 帧写的路线帧数（ap_host.c）
void s2a_nominal_fps_set(int fps);

// ---------- §6 C# 初始化（NativeAOT 导出，服务接入线提供；没链 C# 时原生层给弱符号空实现）----------
void S2A_Init(void);

#ifdef __cplusplus
}
#endif
