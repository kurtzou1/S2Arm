// 各平台共用 SDK / guest 入口。调用方保留参数直到本线程退出。
#include "native.h"
#include "guest_main.h"
#ifdef __ANDROID__
#include "../../android/native/runtime/fault/fault.h"
#include "../../android/native/runtime/runtime.h"
#endif

uint32_t s2a_thread_main_init(void);
uint32_t s2a_thread_current(void);
void sw_call_on_stack(void (*fn)(void), uint64_t sp);
static _Thread_local const struct s2a_guest_main_args *g_start;

static void *req(const char *n) { void *p = guest_sym(n); if (!p) die("SDK 缺符号 %s", n); return p; }
typedef void (*fn0)(void); typedef void (*fn2)(uint64_t, uint64_t); typedef void (*fnp)(void *);

static void guest_main_body(void) {
    // 在宿主栈先登记，启动方看到 entered 后才接受重启。
    uint32_t hmain = s2a_thread_current();
    if (!hmain) die("主线程登记丢失");
    // 主线程句柄作为nnosInitialize的x0。
    // 照抄 nn::init::Start：_init_libc0 → nnosInitialize → _init_libc1（初始化 stdio 等递归锁）→ InitializeSdkModule → nninitStartup → _init_libc2 →
    // rtld 回调（各模块 DT_INIT，全局构造）→ SetHostArgc/Argv → nnMain
    s2a_boot_mark("游戏主线程起");
    // 出包期 Oodle 工具模式（oodle_tool.c，DM_OODLE_SERVE / DM_OODLE_JOB）：游戏主线程已登记、已在客体主栈上，SDK 还没起——Oodle 解码在这里做完就退出
    { void s2a_oodle_tool_maybe(int); s2a_oodle_tool_maybe(0); }
    ((fn0)req("_init_libc0"))();
    LOG(">>> nnosInitialize"); ((fn2)req("nnosInitialize"))(hmain, 0);
    ((fn0)req("_init_libc1"))();
    LOG(">>> nninitInitializeSdkModule"); ((fn0)req("nninitInitializeSdkModule"))();
    LOG(">>> nninitStartup"); ((fn0)req("nninitStartup"))();
    ((fn0)req("_init_libc2"))();
    s2a_boot_mark("SDK 初始化（nnosInitialize / InitializeSdkModule / nninitStartup）");
    run_module_inits();
    s2a_boot_mark("各模块全局构造（DT_INIT）");
    { void s2a_oodle_tool_maybe(int); s2a_oodle_tool_maybe(1); }   // LZ5 款（勇者斗恶龙 XI S）：解码器要游戏的 malloc，nninitStartup 之后才能用
    { void s2a_glslc_tool_maybe(void); s2a_glslc_tool_maybe(); }   // 出包期 GLSLC 工具模式（glslc_tool.c，DM_GLSLC_JOB）：游戏自带的 glslcCompile 要 SDK 与各模块全局构造都起好

    // 只在起局方真给了参数（`--` 之后）时覆盖。没给就保持 SDK 缺省 g_CommandLineParameter = {1, {""}}（真机无宿主参数时游戏看到的值）：
    // 覆盖成 argc = 0 会让按「argc ≥ 1」写的游戏走真机走不到的路径——怪猎 nnMain 把 operator new 后的残留 x8 当 argv[0]，解析参数即段错误（10-20）
    if (g_start->argc) {
        ((fnp)req("_ZN2nn2os11SetHostArgcEi"))((void *)(uint64_t)g_start->argc);
        ((fnp)req("_ZN2nn2os11SetHostArgvEPPc"))(g_start->argv);
    }
    LOG(">>> nnMain"); ((fn0)req("nnMain"))();
    LOG("nnMain 返回");
}
static void main_returned_host(void) {
#if defined(__APPLE__) && !defined(__ANDROID__)
    void s2a_session_park_guest_end(const char *);
    s2a_session_park_guest_end("nnMain 返回");
#endif
    // 正常收局：Android 的 s2a_host_shutdown 会在本 guest 线程里直接 _exit(0)，pthread_join 永远不返回，
    // runtime.c 里 join 之后的 s2a_direct_finish 在 Android 上到不了。这里在 _exit 之前清 direct
    // attempt 锁（非直连/非 Android 构建没有这个符号，weak 判空）。
#if defined(__ANDROID__)   // Apple 不引用安卓专有符号：ld64 对未定义的弱引用照样报错，不靠逐条链接行 -U 放行
    { void s2a_direct_finish(int) __attribute__((weak)); if (s2a_direct_finish) s2a_direct_finish(1); }
#endif
    void s2a_host_shutdown(const char *why); s2a_host_shutdown("nnMain 返回");
}
#if defined(__APPLE__) && !defined(__ANDROID__)
static void thread_returned_host(void) {
    void s2a_session_park_guest_end(const char *), s2a_thread_terminal_stop_point(void);
    s2a_session_park_guest_end("游戏线程入口返回");
    s2a_thread_terminal_stop_point();
    die("游戏线程入口函数返回（Horizon 要求 ExitThread）");
}
// entry.S reaches this on the child guest stack. Keep the stack transition
// with the guest entry glue; thread.c owns only the actual thread exit.
void sw_thread_returned(void) {
    ((void (*)(void))sw_xstack_wrap("s2a_thread_returned", thread_returned_host))();
    die("游戏线程入口函数返回（Horizon 要求 ExitThread）");
}
#endif
// 游戏主线程：宿主 pthread（8 MB 宿主栈），游戏代码跑在 NPDM 给的主线程栈上（栈区最高处），宿主函数经切栈桩回宿主栈
void *s2a_guest_main(void *a) {
    g_start = a;
    if (!s2a_thread_main_init()) die("主线程登记失败");
#ifdef __ANDROID__
    // 先进入既有g_all/TSD/TLR生命周期，shutdown/VM census才能看到正在附着的主线程。
    // thread owner的入口barrier与child共享。
    // 仍在 pthread 真实宿主栈上预分配 fault 状态；thread_bind_host已初始化时幂等。
    int fault_error = s2a_android_fault_thread_init();
    if (fault_error) die("Android 主线程 fault 状态初始化失败 errno=%d", fault_error);
#endif
    sw_xstack_thread_init(((uint64_t)__builtin_frame_address(0) - 0x400) & ~0xfull, g_start->stack_top);
#ifdef __ANDROID__
    // 借用原 xstack host cursor，不能在独立 mmap 栈上调用 NativeAOT。
    if (!s2a_android_fault_thread_ready()) die("Android 主线程 fault/xstack 尚未就绪");
    int entry_error = s2a_android_runtime_enter_guest_thread();
    if (entry_error) die("Android 主线程最终准入失败 error=%d", entry_error);
#endif
    { void s2a_det_set_ord(int), s2a_det_acquire(void); s2a_det_set_ord(0); s2a_det_acquire(); }
#ifdef __ANDROID__
    // 只主 guest 发布共用会话 RUNNING（子线程经 thread.c 只走上面的逐线程准入），之后存档原子态等才问服务层
    int publish_error = s2a_android_runtime_publish_running();
    if (publish_error) die("Android 主线程运行态发布被拒绝（停止先到或会话已失败）error=%d", publish_error);
#endif
#if defined(__APPLE__) && !defined(__ANDROID__)
    atomic_store(&((struct s2a_guest_main_args *)a)->entered, 1);
#endif
    sw_call_on_stack(guest_main_body, g_start->stack_top);
    main_returned_host();
    return NULL;
}
