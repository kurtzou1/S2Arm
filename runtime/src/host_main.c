// 宿主入口：构造函数预留纯地址窗口 → 装模块 → 按 NPDM 排布局 → 初始化 C# → 游戏主线程初始化 SDK → nnMain；iOS 预热的宿主初始化等 scene 激活。
// 用法：s2arm-host <模块目录> [模块名…] [-- 游戏参数…]。模块目录是改写器产物（<名>.patched.bin / fixups.tsv / gates.tsv）与 main.npdm 所在处；
// 模块名缺省 main subsdk0…subsdk9 sdk 中有随行表（.fixups.tsv）的（与 exefs 列举一致；DT_INIT 按逆序跑，见 loader.c）
// 弱链接[host,ios]：S2A_Init（C# 服务层（S2A.Aot）提供；原生层单独构建没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：S2A_InitSession（C# 服务层（S2A.Aot）提供；同上）
// 弱链接[host]：nvn_pso_harvest（直连层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：s2a_autoplay_on（自动玩家（C#）提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,ios,nvntest,touchtest]：s2a_autoplay_wait_s（自动玩家累计等模型秒数；同上）
#include "s2a_selfcheck_page.h"   // 自检「仍要启动」按钮文案
#include "native.h"
#include "dev_facilities.h"
#include "guest_main.h"
#include "s2a_session.h"
#include "s2a_boot.h"
#include "s2a_dguard.h"
#include "s2a_unattended.h"
#include "s2a_init_fail.h"
#include "s2a_loadprog.h"
#include "s2a_gfx_mode.h"
#include "s2a_pad.h"
#include "s2a_programs.h"
#include "s2a_launch_ctx.h"
#include "../../graphics/nvn/gfx/nvn/dmsh_chain.h"   // DMSH_CHAIN：直连安全网诊断信息里写翻译链
#include <unistd.h>
#include <sys/stat.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include "../../ios/settings.h"
#include <dlfcn.h>
#endif
#include <sys/resource.h>
#include <errno.h>
#if !TARGET_OS_IPHONE
#include <objc/runtime.h>
#include <objc/message.h>
// Mac 热状态 / 低电量（审计 P1-80）：同 iOS ios/app.m 取 NSProcessInfo（热状态 0 正常 1 一般 2 严重 3 危急；低电量 macOS 12 起有），覆盖 graphics/nvn hle_nvn.c 与
//   runtime/src/fps.c 的弱定义 -1 / 0——原先 Mac 过热、低电量都不降 60 帧，帧步「热状态 ≤ 1」把 -1 当成不热。宿主是 C，不编 ObjC，走 objc 运行时（Mac 宿主链 Foundation，graphics/build.mk）
static id mac_process_info(void) { Class c = objc_getClass("NSProcessInfo"); return c ? ((id (*)(Class, SEL))objc_msgSend)(c, sel_registerName("processInfo")) : nil; }
int dm_thermal_now(void) { id p = mac_process_info(); return p ? (int)((long (*)(id, SEL))objc_msgSend)(p, sel_registerName("thermalState")) : -1; }
int dm_low_power_now(void) {
    id p = mac_process_info(); SEL s = sel_registerName("isLowPowerModeEnabled");
    return p && class_respondsToSelector(object_getClass(p), s) && ((BOOL (*)(id, SEL))objc_msgSend)(p, s);
}
#endif

// 弱引用、不是弱定义：弱定义会让链接器用本地这份、不再从 C# 静态库里拉成员（C# 整个链不进来）。没链 C# 时 S2A_Init 为空指针
extern void S2A_Init(void) __attribute__((weak_import));
extern int S2A_InitSession(void) __attribute__((weak_import));
extern int s2a_autoplay_on(void) __attribute__((weak_import));
extern double s2a_autoplay_wait_s(void) __attribute__((weak_import));   // 自动玩家累计等视觉模型的秒数：局时顺延用（S2A_RUN_EXTEND_MAX）   // 测试层通用自动玩家（S2A_CS=1 时链进来）：开不开见 tests/autoplay/ap_default.h
__attribute__((weak)) void s2a_front_run(void (*start_host)(void)) { (void)start_host; }
__attribute__((weak)) int s2a_front_is_running(void) { return 0; }   // iOS 壳 app.m 覆盖：界面已在主线程跑着（s2a_front_run 会立即返回）   // 前端占主线程时覆盖；iOS 预热传延后启动宿主的续体，其余传 NULL
#include "s2a_lan_discovery.h"
// Hosts without a discovery implementation leave LAN unavailable explicitly.
__attribute__((weak)) const s2a_lan_discovery_v1 *s2a_ldn_lan_provider(void) { return NULL; }
void s2a_crash_install(void); void s2a_term_install(void);
uint64_t s2a_mem_init(const char *npdm);
void s2a_boot_mark(const char *stage);

static char *g_argv[64]; static int g_argc;
static uint64_t g_main_stack_top;
static char *g_module_dir, **g_module_names;
static int g_module_count;
static struct s2a_guest_main_args g_guest_args;
void s2a_session_timer_run(unsigned generation, void (*action)(void));
int s2a_session_try_boot(void (*boot)(void *), void *context);

void s2a_host_shutdown(const char *why);
struct session_timer { unsigned generation, seconds; };
static unsigned timer_wait(void *arg) {
    struct session_timer timer = *(struct session_timer *)arg; free(arg);
    for (unsigned i = 0; i < timer.seconds; i++) {
        sleep(1);
        if (timer.generation != s2a_session_generation() || s2a_session_stop_requested()) return 0;
    }
    return timer.generation;
}
static void timer_shutdown(void) { s2a_host_shutdown("到时（S2A_RUN_S）"); }
// 局时顺延（11-01 维护者：模型等待不算局时，局时只算游戏实际运行）：S2A_RUN_EXTEND_MAX=<秒> > 0 时，S2A_RUN_S 到点后按自动玩家累计等模型秒数
//   （封顶 S2A_RUN_EXTEND_MAX）顺延收局，顺延期间新增的等待接着补。缺省 0 = 不顺延（各执行器的外层墙钟按 S2A_RUN_S 定，开这个要同步放宽外层）
static void *run_timer(void *a) {
    unsigned gen = timer_wait(a);
    const char *e = getenv("S2A_RUN_EXTEND_MAX"); double cap = e && *e ? atof(e) : 0, done = 0;
    while (gen && cap > 0 && s2a_autoplay_wait_s) {
        double w = s2a_autoplay_wait_s(); if (w > cap) w = cap;
        if (w <= done + 0.5) break;
        LOG("局时顺延 %.0f 秒（自动玩家累计等模型 %.0f 秒，上限 %.0f）", w - done, w, cap);
        for (double t = 0; t < w - done; t += 1) { sleep(1); if (gen != s2a_session_generation() || s2a_session_stop_requested()) { gen = 0; break; } }
        done = w;
    }
    if (gen) s2a_session_timer_run(gen, timer_shutdown); return NULL;
}
// S2A_GUEST_PAUSE_AT=<秒>（诊断，缺省关）：起局后到点挂起全部游戏线程，渲染 / 服务 / 声音照跑——能耗减法实验「只跑我们的层」（帧率能耗线 10-20）
static void timer_pause(void) {
    int s2a_guest_pause_all(void); int n = s2a_guest_pause_all();
    LOG("【红】游戏线程全部挂起：%d 条（S2A_GUEST_PAUSE_AT，诊断：只跑我们的层）", n);
}
static void *guest_pause_timer(void *a) { unsigned gen = timer_wait(a); if (gen) s2a_session_timer_run(gen, timer_pause); return NULL; }

static int start_timer(const char *name, void *(*fn)(void *)) {
    const char *e = getenv(name); long sec = e ? atol(e) : 0;
    if (sec <= 0) return 0;
    struct session_timer *timer = malloc(sizeof *timer);
    if (!timer) return -1;
    *timer = (struct session_timer){s2a_session_generation(), (unsigned)sec};
    pthread_t th; int error = pthread_create(&th, NULL, fn, timer);
    if (error) { free(timer); LOG("【红】%s 定时线程创建失败：%d", name, error); return -1; }
    pthread_detach(th); return 0;
}

// 模块目录里有随行表（<名>.fixups.tsv）的缺省模块名：main subsdk0…subsdk9 sdk（与 exefs 列举一致）。names 至少 12 格，回个数
static int discover_modules(const char *dir, const char **names) {
    static char sub[10][16]; static const char *cand[12];
    int k = 0, n = 0; cand[k++] = "main"; for (int s = 0; s < 10; s++) { snprintf(sub[s], sizeof sub[s], "subsdk%d", s); cand[k++] = sub[s]; } cand[k++] = "sdk";
    for (int c = 0; c < k; c++) { char p[1100]; struct stat st; snprintf(p, sizeof p, "%s/%s.fixups.tsv", dir, cand[c]); if (!stat(p, &st)) names[n++] = cand[c]; }
    return n;
}

// 多程序合集（s2a_programs.h）：游戏 ExecuteProgram(n) 登记了下一局的序号 → 本局装该序号的模块目录（programs/<n>/，序号 0 = 根），模块名按目录重新列
static int g_program_switched = -1;   // 本局刚切到的序号（load_session_modules 装完模块后让图形层换库用）；没切 = -1
static void switch_program_modules(void) {
    char dir[1100]; int p = s2a_programs_take(dir, sizeof dir);
    if (p < 0) return;
    void s2a_loader_image_program(int); s2a_loader_image_program(p);   // iOS：外置镜像包里序号 n 的模块名带 p<n>/ 前缀
    if (!strcmp(dir, g_module_dir)) return;
    const char *names[12]; int n = discover_modules(dir, names);
    if (!n) die("【红】多程序合集：序号 %d 的模块目录 %s 里没有模块（*.fixups.tsv）", p, dir);
    char *nd = strdup(dir); char **nn = calloc((size_t)n, sizeof *nn);
    if (!nd || !nn) die("模块名表分配失败");
    for (int m = 0; m < n; m++) if (!(nn[m] = strdup(names[m]))) die("模块名分配失败");
    for (int m = 0; m < g_module_count; m++) free(g_module_names[m]);
    free(g_module_names); free(g_module_dir);
    g_module_dir = nd; g_module_names = nn; g_module_count = n;
    LOG("多程序合集：本局装序号 %d 的程序，模块目录 %s，%d 个模块", p, dir, n);
    g_program_switched = p;
}

static void load_session_modules(void *unused) {
    (void)unused;
    switch_program_modules();
#if defined(__APPLE__)
    { void s2a_test_ballast_commit(void); s2a_test_ballast_commit(); }   // 测试压舱（S2A_TEST_BALLAST_MB，vawin.c）：布局排完、装模块前才真占
#endif
    load_modules(g_module_dir, (const char **)g_module_names, g_module_count);
    if (g_program_switched >= 0) {   // 多程序合集：模块（含 main.npdm 程序号）换好后，直连图形层的着色器库 / 映射表 / 每款参数换到该序号（graphics/nvn/host_adapt.m）；
        //   没链直连图形层的宿主（安卓、图形单测）按名找不到 = 报红，不假装换了
        void s2a_npdm_program_id_reload(void); s2a_npdm_program_id_reload();   // gfxmode.c：程序号按这一支的 main.npdm（load_modules 之后 s2a_module_dir 才是这一支的目录）
        int (*sw)(int) = (int (*)(int))dlsym(RTLD_DEFAULT, "s2a_direct_program_switch");
        if (sw) sw(g_program_switched); else LOG("【红】多程序合集：宿主没有直连图形层的切换入口 s2a_direct_program_switch，序号 %d 仍用原来的着色器库", g_program_switched);
        g_program_switched = -1;
    }
    void s2a_patch_finish(const char *); s2a_patch_finish(s2a_main_build_id());   // 补丁（patch.c）：各段生效结果写 .applied
    void s2a_widen_start(void); s2a_widen_start();
    void s2a_fps_start(const char *); s2a_fps_start(g_module_dir);
    char npdm[1100]; snprintf(npdm, sizeof npdm, "%s/main.npdm", g_module_dir);
    g_main_stack_top = s2a_mem_init(npdm);
}

static int start_guest_thread(void) {
    if (s2a_session_guest_begin(s2a_session_generation())) return -1;
    g_guest_args = (struct s2a_guest_main_args){.stack_top = g_main_stack_top, .argc = g_argc, .argv = g_argv};
    pthread_attr_t attr; int error = pthread_attr_init(&attr);
    if (error) { s2a_session_guest_end(0); return -1; }
    error = pthread_attr_setstacksize(&attr, 8u << 20);
    pthread_t thread;
    if (!error) error = pthread_create(&thread, &attr, s2a_guest_main, &g_guest_args);
    pthread_attr_destroy(&attr);
    if (error) { LOG("【红】游戏主线程创建失败：%d", error); s2a_session_guest_end(0); return -1; }
    // 线程从此归 thread.c 的 roster/reaper；宿主入口不能再并发 pthread_join。
    uint64_t until = now_ns() + 5000000000ull;
    while (!atomic_load(&g_guest_args.entered)) {
        if (now_ns() >= until) {
            LOG("【红】游戏主线程登记超过 5 秒，保留当前会话，不能证明 roster 已完整");
            s2a_session_guest_end(1); return -1;
        }
        usleep(1000);
    }
    error = start_timer("S2A_RUN_S", run_timer) || start_timer("S2A_GUEST_PAUSE_AT", guest_pause_timer);
    s2a_session_guest_end(0);
    return error || s2a_session_stop_requested() ? -1 : 0;
}

// 初启失败的唯一出口。契约（审计 #1534 P1-4，见 runtime/include/s2a_init_fail.h）：初启失败 = 本进程终局——先发布终局（会话 EXITING、门表终局 park），
//   不回收半建资源、不在同一进程再起第二局（托管层 / 图形装配 / session.c 三层都按此设计，生命周期代码不为失败改）。
//   之后只分「怎么告诉人」：iOS 人手局停在提示页（按错误码的玩家话术 +「上传给开发者」+ 划掉重开；内部摘要只进诊断），Mac 与自动化局照旧失败退出码 1。
//   code = S2A_INIT_FAIL_E_*（调用点一处一个，码表在 s2a_init_fail.h）
static void failed_session(int code) {
    const char *why = s2a_init_fail_summary(code), *cid = s2a_init_fail_code_id(code);
    s2a_session_process_exit(s2a_session_generation());
    if (s2a_init_fail_action(TARGET_OS_IPHONE, s2a_unattended()) == S2A_INIT_FAIL_PAGE) {
#if TARGET_OS_IPHONE
        LOG("【红】%s（错误码 %s）：初启失败，停在提示页等玩家从后台划掉重开（本进程终局，未宣称完成会话清理）", why, cid);
        static char diag[8192], body[512]; char lp[1100];
        snprintf(lp, sizeof lp, "%s/host.log", s2a_launch_ctx_get()->log_dir);   // main 开头已核上下文可用
        s2a_init_fail_diag_file(diag, sizeof diag, code, s2a_main_build_id(), DMSH_CHAIN, lp);
        s2a_init_fail_screen(body, sizeof body, code);
        LOG("初启失败诊断（随「上传给开发者」的诊断包带走）：\n%s", diag);
        s2a_logcon_flush();
        void s2a_ios_init_failed(const char *body, const char *diag); s2a_ios_init_failed(body, diag);
        s2a_front_run(NULL);   // iOS 一律延后启动，UIKit 已在主线程：立即返回；宿主线程停在这里直到玩家划掉
        for (;;) pause();
#endif
    }
    LOG("【红】%s（错误码 %s）：初启失败，宿主失败退出，未宣称完成会话清理", why, cid);
    s2a_logcon_flush();
    _exit(EXIT_FAILURE);
}

// 宿主别处（svc_mem.c 布局判出设备放不下，#446）走同一个初启失败出口：iOS 人手局停提示页，Mac / 自动化局失败退出
void s2a_init_failed(int code) { failed_session(code); }

// 只由 session.c 在上一局 guest / 服务 / GPU 完整退休后调用。
int s2a_host_rebuild(void) {
#if TARGET_OS_IPHONE
    if (s2a_ios_reload_graphics_settings()) return -1;
#endif
    // 审计 P2-15：设置里的立刻重启不经过进后台，上一局按着的键 / 摇杆不能带进新局第一次读
    s2a_pad_session_reset();
    void s2a_gfx_mode_session_reset(void); s2a_gfx_mode_session_reset();
    if (s2a_session_try_boot(load_session_modules, NULL)) return -1;
    if (!S2A_InitSession || S2A_InitSession()) return -1;
    // Providers are initialized now; establish a background/restart hold
    // before the replacement guest thread can execute or submit its first frame.
    if (s2a_session_guest_start_prepare(s2a_session_generation())) return -1;
    return start_guest_thread();
}

int s2a_pack_apply(const char *docs);
#if TARGET_OS_IPHONE
// 解包专用局（S2A_PACK_APPLY_ONLY）做完正常收尾：打「优雅退出完成」并冲刷日志再 _exit。原先直接 _exit，这一局日志没有收尾行、也没有心跳，
//   下一局起来诊断模块（ios/diag.m）把它判成「上次 S2Arm 好像没有正常退出」，开局弹「把上次的诊断发给我们？」挡住游戏
//   （10-30 LiveContainer 实测：先起一次解包、正式局三张截图全被这个框挡着；正常真机局只要前面跑过解包同样会弹）
#include <pthread/qos.h>
static const char *qos_str(qos_class_t q) {
    switch (q) { case QOS_CLASS_USER_INTERACTIVE: return "用户交互"; case QOS_CLASS_USER_INITIATED: return "用户发起"; case QOS_CLASS_DEFAULT: return "缺省";
        case QOS_CLASS_UTILITY: return "实用（读写会被限速）"; case QOS_CLASS_BACKGROUND: return "后台（读写重度限速）"; default: return "未定"; } }
static void *pack_apply_thread(void *docs) { s2a_thread_name("s2a-pack-apply");
    { qos_class_t q = QOS_CLASS_UNSPECIFIED; int rel = 0; pthread_get_qos_class_np(pthread_self(), &q, &rel);   // 11-07 定因：解包慢 15–25 倍时先看本线程调度档
      LOG("解包线程：调度档 %s（0x%x，相对 %d）", qos_str(q), (unsigned)q, rel); }
    int rc = s2a_pack_apply(docs);
    LOG("优雅退出完成（解包专用局，%s）", rc ? "解包失败" : "解包完成");
    void s2a_logcon_flush(void); s2a_logcon_flush();
    _exit(rc);
}
#endif
#if !TARGET_OS_IPHONE
// 帧回放入口（graphics/nvn/gfx/nvn/nvn_frame_rec.inc 的强定义）；没链直连后端的宿主 / 探针走这个缺省
__attribute__((weak)) int nvn_frame_replay(const char *dir) { (void)dir; die("【红】S2A_FRAME_REPLAY：这个宿主没链直连后端（nvn_frame_replay）"); return 1; }
#endif
#if !TARGET_OS_IPHONE
void s2a_mac_slot_hold(const char *what);   // runtime/src/mac_slot_hold.c：本机用显卡的活一本账（宿主自己拿 Mac 局槽）
#endif
static int host_run(int argc, char **argv) {
    // 一进程一款（启动上下文，runtime/include/s2a_launch_ctx.h）：同进程第二次起局拒绝；进程内同款重启走 s2a_host_rebuild，不经过这里
    { const char *why = s2a_launch_ctx_begin(); if (why) die("【红】%s", why); }
    const s2a_launch_ctx *lc = s2a_launch_ctx_get();   // main 开头已冻结并核过可用
    // 进程级 env.txt 已在构造期应用；上下文文件给的本款文档根另有 env.txt 时此刻补读（只补缺）。日志 fd 就绪且正式会话开始后，只输出一次暂存的诊断。
    { const char *gd = s2a_launch_ctx_game_env_dir(s2a_envfile_process_docs()); if (gd) s2a_envfile_apply(gd); }
    s2a_envfile_log_flush();
#if TARGET_OS_IPHONE
    s2a_ios_load_graphics_settings();
#endif
    // 档位梯子（runtime/src/qladder_host.c）：要在 iOS 画面设置注入之后（玩家选的运行模式是梯子的上限，#352），服务层 / 宽屏装表读 S2A_DOCKED 之前
    { void s2a_ql_boot(void); s2a_ql_boot(); }
#if TARGET_OS_OSX
    // 文件句柄软上限（10-24 gate-host 实测）：macOS 的 Terminal / ssh / 图形 App 缺省软上限 256，硬上限不限；动森带存档起局读存档时
    //   「Too many open files」、游戏随即 Break。iOS 上是 2560。起局时把软上限抬到 min(硬上限, 10240)（OPEN_MAX，setrlimit 认的最大值）
    { struct rlimit rl; if (!getrlimit(RLIMIT_NOFILE, &rl)) { rlim_t want = rl.rlim_max < 10240 ? rl.rlim_max : 10240;
        if (rl.rlim_cur < want) { rlim_t was = rl.rlim_cur; rl.rlim_cur = want;
            if (setrlimit(RLIMIT_NOFILE, &rl)) LOG("【红】文件句柄软上限 %llu 抬不到 %llu（errno %d）", (unsigned long long)was, (unsigned long long)want, errno);
            else LOG("文件句柄软上限 %llu → %llu", (unsigned long long)was, (unsigned long long)want); } } }
#endif
    // 测试层契约：S2A_PACK_APPLY_ONLY=1 只解开推送来的资源包就退出（Documents = $HOME/Documents，Mac 上可用 S2A_DOCS 指）
    s2a_boot_mark("进入 main");
    { const char *e = getenv("S2A_PACK_APPLY_ONLY");
      if (e && *e == '1') { char docs[1024]; strlcpy(docs, lc->docs, sizeof docs);   // 启动上下文文档根（兼容 = S2A_DOCS，否则 $HOME/Documents）
#if TARGET_OS_IPHONE
          static char sdocs[1024]; strlcpy(sdocs, docs, sizeof sdocs); pthread_t th;
          if (pthread_create(&th, NULL, pack_apply_thread, sdocs)) die("解包线程起不来");
          s2a_front_run(NULL);   // UIKit 照常起来（不返回）；解包线程做完自行退出进程
          for (;;) pause();
#else
          _exit(s2a_pack_apply(docs));
#endif
      } }
    { int s2a_selfcheck(void); void s2a_ios_show_notice(const char *, const char *, const char *, int, int, int); void s2a_selfcheck_page(const char **, const char **);
      if (!s2a_selfcheck()) {
#if TARGET_OS_IPHONE
          const char *t, *b; s2a_selfcheck_page(&t, &b);   // 细节（地址上限、内存上限）已在 host.log「【红】自检不过」，随诊断包带走
          int s2a_selfcheck_can_continue(void); int s2a_ios_ask_continue(const char *, const char *, const char *, const char *);
          // 只差内存上限：提示页多一个「仍要启动」，玩家点了就照常起局（v0.3.1 装机原则）；物理上起不来的照旧只给提示、不起游戏
          if (s2a_selfcheck_can_continue() && s2a_ios_ask_continue("exclamationmark.triangle.fill", t, b, S2A_SELFCHECK_GO))
              LOG("自检：只差内存上限，玩家点了「仍要启动」，照常起局（大游戏可能被系统结束）");
          else { s2a_ios_show_notice("exclamationmark.triangle.fill", t, b, 0, 0, 1); s2a_front_run(NULL); for (;;) pause(); }   // 画面上给提示，不起游戏
#endif
      } }
#if TARGET_OS_IPHONE
    // 玩家首次打开从「文件」导入资源（用户体验线 10-23，原生层线审过插入位置：自检后、占地址窗口前）：资源就绪才往下走；
    //   缺资源显示提示页、有待导入的包就后台解开后提示重新打开，都不起游戏、不返回。执行器先 APPLY_ONLY 解好包，这里是空操作；指定了 S2A_GAME_DATA 的不查
    // 闸门当场解开资源再接着起这一局时：起局前（s2a_ios_load_graphics_settings → s2a_caps_apply → s2a_patch_open）读随包补丁 / 能力清单那会儿
    //   资源包还没解开，读到的是「没有」——按刚解开的资源包重读一遍（同设置页「立刻重启」那条，先撤清单写的再按设置 → 清单重套），
    //   早于图形模式落定与服务层初始化（审计 P1-106：原先要等下次打开才生效）
    //   查不查、查哪个文档根由 s2a_import_docs_pick 按启动上下文定（多款容器 = 本款 Documents/games/<游戏号>；11-07 原先按「S2A_GAME_DATA 没设」判，容器选游戏总会设它 → 漏查）
    { int s2a_import_gate(void); int s2a_ios_reload_graphics_settings(void);
      // v0.3.1（认不出的直接做）：重读失败最多是这局画面设置 / 随包补丁按缺省走（下次打开照常读），不该让 App 直接退出——记一笔照常起局
      if (s2a_import_gate() && s2a_ios_reload_graphics_settings()) LOG("【黄】资源导入后重读画面设置 / 随包补丁失败（见上一行），这局按缺省画面设置起，下次打开照常读"); }
    // 模块目录先定下（启动上下文 main 开头已冻结）：放行之后谁先调 s2a_gfx_mode() 谁就落定图形模式与程序号（gfxmode.c decide 读 <模块目录>/main.npdm）。
    //   原先 iOS 要到装模块（loader.c load_modules）才设目录，放行与装载之间若有人先问——上次没正常收尾时开局弹诊断提示，关掉后 App 重新激活，
    //   恢复回调 s2a_direct_suspend 问图形模式——程序号读成 0 并锁死整局：wire/<程序号> 的现编缓存、跑局知识落到 wire/0000000000000000，
    //   库戳核对报「built for game …, not 0000000000000000」（11-10 测试设备连续冷启动 3 次后两次中；11-04 起的 iOS 日志就有）
    { void s2a_module_dir_set(const char *); s2a_module_dir_set(lc->module_dir); }
    // 资源包已放行：图形模式此后才落定（gfxmode.c）。必须早于装载——装载器按模式绑定 nvnBootstrapLoader（loader.c）
    { void s2a_gfx_mode_data_ready(void); s2a_gfx_mode_data_ready(); }
#endif
    s2a_boot_mark("自检");
#if !TARGET_OS_IPHONE
    // 出包期管线归档收集（S2A_PSO_HARVEST=<目录>，着色器线 10-26）：不装游戏、不建游戏线程，直连后端只初始化 Metal / 着色器表 / 种子表，满核建一遍写进目录就退出（graphics/nvn nvn_pso_harvest）
    { const char *hv = getenv("S2A_PSO_HARVEST"); if (hv && *hv) { int nvn_pso_harvest(const char *) __attribute__((weak));
        if (!nvn_pso_harvest) die("【红】S2A_PSO_HARVEST：这个宿主没链直连后端（nvn_pso_harvest）");
        exit(nvn_pso_harvest(hv)); } }
#endif
    if (!s2a_window_ok()) die("【红】地址窗口不足：首选位置整块 64 GB 与退路（2^39 以下 ≥ 32 GB 的空洞）都没占到，起不了局（见上面的地址表）");
    s2a_crash_install(); s2a_term_install();
#if !TARGET_OS_IPHONE
    // 帧回放（S2A_FRAME_REPLAY=<录像目录>，graphics/nvn/docs/frame_replay.md）：地址窗口占好后不装游戏、不起游戏线程，把录下的一帧喂给直连回放层，出截图 / 满屏判据 / 每笔指令数就退出
    { const char *rp = getenv("S2A_FRAME_REPLAY"); if (rp && *rp) { s2a_mac_slot_hold("帧回放"); LOG("帧回放模式：%s（不装游戏）", rp); exit(nvn_frame_replay(rp)); } }
#endif
    { void s2a_det_init(void); s2a_det_init(); }
#if TARGET_OS_IPHONE
    // iOS：模块映像在外置镜像包（启动上下文 images，loader.c ext_pack），随行表与 main.npdm 在启动上下文的模块目录（单款兼容 = 可执行文件同目录）
    const char *dir = lc->module_dir; int n = 0, i = argc;
#else
    if (argc < 2) die("用法：s2arm-host <模块目录> [模块名…] [-- 游戏参数…]");
    const char *dir = argv[1]; int n = 0, i = 2;
#endif
    const char **names = calloc((size_t)argc + 12, sizeof *names);   // 命令行模块名（≤ argc 个）或缺省 main / subsdk0–9 / sdk 12 个
    if (!names) die("模块名表分配失败");
    for (; i < argc && strcmp(argv[i], "--"); i++) names[n++] = argv[i];
    if (i < argc && !strcmp(argv[i], "--")) for (i++; i < argc && g_argc < 63; i++) g_argv[g_argc++] = argv[i];
    if (!n) n = discover_modules(dir, names);
    LOG("模块：%d 个（%s …），主程序构建号见下", n, n ? names[0] : "无");
#if !TARGET_OS_IPHONE
    // 包内能力清单（产物根 s2a_caps.tsv，改写阶段出，iOS 同一份）：Mac 局按发布口径跑（10-29 维护者：普查原先没读清单，宽屏退回已验证名单门、整局 16:9）。
    //   只在环境变量未设时写：调度器 A/B 的 S2A_WIDEN_CAPS / S2A_FPS60 照旧优先。要在装载前读——宽屏点按屏幕宽在装载时填值（widen.c widen_gate）
    { void s2a_caps_apply(const char *); s2a_caps_apply(dir); }
    // 图形模式在构造函数里（地址窗口取程序号）就判定了，那时模块目录还空，程序号读成 0：目录已知后重读（DM_GAME_ID、wire/<程序号> 都靠它）
    { void s2a_module_dir_set(const char *), s2a_npdm_program_id_reload(void); s2a_module_dir_set(dir); s2a_npdm_program_id_reload(); }
#endif
    g_module_dir = strdup(dir); g_module_count = n;
    if (!g_module_dir) die("模块路径分配失败");
    if (!(g_module_names = calloc(n > 0 ? (size_t)n : 1, sizeof *g_module_names))) die("模块名表分配失败");
    for (int m = 0; m < n; m++) if (!(g_module_names[m] = strdup(names[m]))) die("模块名分配失败");
    free(names);
    s2a_programs_init(dir);   // 多程序合集：数包里几支程序（序号 0 = 本目录）；进程级，跨进程内重启存活
    load_session_modules(NULL);
    // 诊断钩子（diag_brk.c，S2A_DIAG_DELAY / S2A_DIAG_STAMP / S2A_DIAG_DUMP 设了才装，只 Mac）
    { void s2a_diag_brk_arm(void); s2a_diag_brk_arm(); }
    LOG("主程序构建号 %s", s2a_main_build_id());
    s2a_boot_mark("装载 / 重定位 / 门表");
    s2a_boot_mark("内存布局");
#if TARGET_OS_IPHONE
    // 游戏数据（服务接入线登记游戏用：exefs/main.npdm、romfs/、ctl/control.nacp）在资源包根（测试层契约），没给就指过去
    if (!getenv("S2A_GAME_DATA")) { setenv("S2A_GAME_DATA", lc->game_data, 0); LOG("游戏数据：%s", lc->game_data); }   // 启动上下文资源包根（兼容 = $HOME/Documents/资源包）
#endif
    // 出包期工具模式（Oodle：oodle_tool.c；GLSLC：glslc_tool.c）：只要装好的模块与游戏主线程，不起图形 / 前端、不进 nnMain——起游戏主线程，做完就退出。
    //   Oodle 解码器在 SDK 初始化前做完，不要 C#；GLSLC 与 LZ5（勇者斗恶龙 XI S 的 LZ5_decompress_safe，要游戏 malloc）要等 nninitStartup 与各模块全局构造，
    //   nninitInitializeSdkModule 要连系统服务（svc 0x1f），所以先起 C# 服务层（10-29 神之天平 外传 GLSLC、11-01 勇者斗恶龙 XI S LZ5：不起 C# 时 SDK 初始化对 0x1f 无限重试、卡死）
    { int s2a_oodle_tool_on(void), s2a_oodle_tool_needs_sdk(void), s2a_glslc_tool_on(void); int oodle = s2a_oodle_tool_on(); if (oodle || s2a_glslc_tool_on()) {
        if (oodle) { void s2a_oodle_tool_claim_stdout(void); s2a_oodle_tool_claim_stdout(); }   // 应答管道只给解码结果：之后（含 C# 起局）的日志都进 stderr
        int sdk = !oodle || s2a_oodle_tool_needs_sdk();
        // 只认 S2A_InitSession（同下面正式起局，回 0 / -1）：初始化失败 die 非 0 退出。没有它就 die，不再退到 void 的 S2A_Init
        //   （审计 P1-126：void 入口吞异常，失败只报红、照起游戏主线程、最后退 0；现行宿主两个入口都导出，这条退路只在链接结果缺会话符号时走到）
        if (sdk) { if (!S2A_InitSession) die("【红】%s 工具模式要 C# 服务层的 S2A_InitSession（S2A_CS=1 编宿主）：SDK 初始化要连系统服务", oodle ? "LZ5" : "GLSLC");
                   if (s2a_session_prepare() || S2A_InitSession()) die("【红】%s 工具模式：C# 服务层初始化失败（原因见上面的红行），不起游戏主线程", oodle ? "LZ5" : "GLSLC"); }
        LOG("出包期工具模式（%s）：%s，直接起游戏主线程", oodle ? (sdk ? "LZ5" : "Oodle") : "GLSLC", sdk ? "C# 服务层已起、不起前端" : "跳过 C# 初始化");
        struct s2a_guest_main_args tool_args = {.stack_top = g_main_stack_top, .argc = g_argc, .argv = g_argv};
        pthread_t tth; pthread_attr_t tat; pthread_attr_init(&tat); pthread_attr_setstacksize(&tat, 8 << 20);
        if (pthread_create(&tth, &tat, s2a_guest_main, &tool_args)) die("游戏主线程起不来");
        pthread_join(tth, NULL); return 0; } }
#if !TARGET_OS_IPHONE
    s2a_mac_slot_hold(dir);   // 起局用显卡之前（工具模式已在上面返回）
#endif
    if (S2A_InitSession) {
        if (s2a_session_prepare()) failed_session(S2A_INIT_FAIL_E_SESSION_CTRL);
        if (S2A_InitSession()) failed_session(s2a_init_fail_service_code(s2a_launch_ctx_get() ? s2a_launch_ctx_get()->game_data : getenv("S2A_GAME_DATA")));   // 资源包缺 main.npdm 单独归 game_files_missing
    }
    // 只链上老的 void S2A_Init、没有 S2A_InitSession：它把初始化异常报红后吞掉，照常起游戏会在后面别处崩；同工具模式，停下说清楚（审计 P2-268）
    else if (S2A_Init) die("【红】C# 服务层只导出了 S2A_Init、没有 S2A_InitSession：初始化失败报不出来，不起游戏（宿主与服务层版本不配套，重新出包）");
    else LOG("S2A_Init：没链 C#（原生层单独构建），进 C# 的系统调用一律报红");
    // 只有直连（11-07 拆通用模式）：包里没有本宿主口径的直连库（没导完、旧版本出的包、设备跑不了直连）就停在这里报「游戏文件缺失」，
    //   iOS 提示页带「上传给开发者」反馈入口；原先这里静默退成通用模式（11-02 / 11-05 普查两款这样起局，一款崩、一款卡死，直连问题藏在后面）
    if (s2a_gfx_mode() != S2A_GFX_DIRECT) failed_session(S2A_INIT_FAIL_E_DIRECT_LIB);
    s2a_boot_mark("S2A_Init 返回（C# 运行时 + 服务登记）");
    s2a_window_probe("C# 初始化后");
    { uint64_t ht, hl, fs, fh; int fn; s2a_low_holes(&ht, &hl); s2a_fd_usage(&fn, &fs, &fh);
      void s2a_window_need(uint64_t *, uint64_t *); uint64_t wneed = 0, wfit = 0; s2a_window_need(&wneed, &wfit);
      // 一行护栏（10-26 GC 硬上限开局多保留约 10 GB 低区）：窗口已在 C# 之前占好；C# 初始化后低区最大一块要留给宿主线程栈与 Metal ≤256 MB 缓冲
      LOG("地址余量（C# 初始化后）：低区空洞合计 %llu MB、最大一块 %llu MB（宿主线程栈、Metal ≤256 MB 缓冲都从这里取）｜窗口 %s（本款要 %llu MB）｜GC 上限见「GC 上限：」行；文件句柄已开 %d 个，软上限 %llu、硬上限 %llu",
          (unsigned long long)(ht >> 20), (unsigned long long)(hl >> 20), s2a_window_ok() ? "已占" : "没占到", (unsigned long long)(wneed >> 20),
          fn, (unsigned long long)fs, (unsigned long long)fh); }
    { void s2a_vm_top(const char *); s2a_vm_top("C# 初始化后"); void s2a_vm_low(const char *); s2a_vm_low("C# 初始化后"); }
    { void s2a_guest_va_report(const char *); s2a_guest_va_report("C# 初始化后"); }
    if (s2a_dev_on()) { void s2a_va_watch_start(void); s2a_va_watch_start(); }   // 地址走势（30 秒一行）：开发设施，玩家口径不起
    s2a_lowva_start();   // 低区统一记账巡检（lowva.c）：每秒实测保留量、余量不够叫可腾退的腾
    LOG("S2A 就绪");   // 测试层契约第 4 节：运行时（原生层 + C#）已起来
    if (s2a_autoplay_on && s2a_autoplay_on()) LOG("通用自动玩家已开（AI 看屏驾驶）");
#if TARGET_OS_IPHONE
    // 直连安全网（玩家包，runtime/include/s2a_dguard.h）：直连起局先查此前连续失败几次，满 3 次停在提示页（复制诊断信息 / 仍然启动），之后把本次记成一次失败落盘，
    //   首帧后前台满 60 秒清零（ap_host.c 上屏 / app.m 前后台）。放在起游戏主线程之前：此前的崩溃都发生在游戏线程起来之后
    if (s2a_gfx_mode() == S2A_GFX_DIRECT) { uint64_t s2a_npdm_program_id(void); const char *s2a_ios_host_commit(void);   // diag.m：Info.plist S2ACommit
        int fails = s2a_dguard_begin(s2a_npdm_program_id(), s2a_dguard_pack_fp(getenv("S2A_GAME_DATA")), s2a_ios_host_commit());
        if (fails >= S2A_DGUARD_LIMIT) {
            static char diag[2048]; s2a_dguard_diag(diag, sizeof diag, s2a_main_build_id(), DMSH_CHAIN);
            LOG("【红】直连安全网：本款直连已连续失败 %d 次，起局前提示玩家更新后重新出包；诊断：\n%s", fails, diag);
            // 自动化 / 开发工具起的局（s2a_unattended.h）不停在提示页：记录留着（出包指纹或宿主提交号变了才从 0 数），本局收掉
            if (s2a_unattended()) failed_session(S2A_INIT_FAIL_E_DGUARD_LIMIT);
            void s2a_ios_dguard_prompt(const char *diag); s2a_ios_dguard_prompt(diag);   // 玩家点「仍然启动」才返回
            LOG("直连安全网：玩家选了仍然启动");
        }
        s2a_dguard_arm(now_ns());
    }
#endif
    if (start_guest_thread()) failed_session(S2A_INIT_FAIL_E_GAME_THREAD);
    if (s2a_session_running(s2a_session_generation())) failed_session(S2A_INIT_FAIL_E_SERVICE_EARLY);
    s2a_boot_mark("S2A 就绪 → 起游戏主线程");
    s2a_front_run(NULL);
    for (;;) pause();
    return 0;
}

#if TARGET_OS_IPHONE
static int g_boot_argc;
static char **g_boot_argv;
static void prewarmed_host_run(void) { (void)host_run(g_boot_argc, g_boot_argv); }
// 起 UIKit 前读游戏相关值的检查（存档管理 / 资源包就绪 / 直连安全网 / 加载页进度模型），回本次延后启动的说法（只进日志）。
//   单款：main 里、UIKit 之前做（同改造前）；多款容器：构造期与 main 都还没选游戏，app.m 在 Play → s2a_launch_ctx_select 成功之后、换游戏界面前调
const char *s2a_host_pre_ui_checks(void) {
    int (*manage_saves)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_ios_save_management_requested");
    int imp = 0;
    { const char *e = getenv("S2A_PACK_APPLY_ONLY"); int s2a_import_needs_ui(void);   // 查不查 / 查哪儿由启动上下文定（pack_apply.c s2a_import_docs_pick）
      if (!(e && *e == '1')) imp = s2a_import_needs_ui(); }
    int saves = manage_saves && manage_saves();
    // 直连安全网（dguard.c）：记录里已连续失败满 3 次，起局前要弹提示页、等玩家选
    if (!imp && s2a_dguard_needs_ui()) { imp = 2; LOG("直连安全网：此前连续失败已满 %d 次，起局前提示", S2A_DGUARD_LIMIT); }
    // 加载页进度模型（loadprog.c）：本包没完整预热过 = 首次（完整加载页），否则简短启动画面
    { const char *gd = getenv("S2A_GAME_DATA"); if (!gd || !*gd) gd = s2a_launch_ctx_get()->game_data;
      s2a_load_begin(now_ns(), s2a_load_first_run(s2a_dguard_pack_fp(gd))); }
    return saves ? "存档管理，延后启动" : imp == 2 ? "直连安全网要提示，延后启动" : imp ? "资源包没就绪，延后启动" : s2a_process_prewarmed() ? "预热启动" : "延后启动（先出加载页）";
}
#endif
int main(int argc, char **argv) {
    // 启动上下文早于一切服务层 / 存档管理 / 装载：文件来源时这里（iOS 更早，vawin.c 构造期）已把 S2A_GAME_DATA / S2A_DOCS / S2A_RYU_DATA 写进环境，C# 运行时起来前就位。
    //   多款容器（launchctx.c ③）此刻还没选游戏：不冻结、不读任何游戏相关值，选游戏后由 app.m 走 s2a_launch_ctx_select → s2a_host_pre_ui_checks → 起宿主
    int container = s2a_launch_ctx_container();
    if (!container && !s2a_launch_ctx_get()) die("【红】启动上下文不可用：%s", s2a_launch_ctx_error());
    // 地址预算必须早于 NativeAOT / Metal：存档管理可在 host_run 前进入服务层。
    // GC 段 32 MB（DOTNET_ 数值按十六进制）；Metal 编译缓存 64 MB。显式环境值不覆盖。
    setenv("DOTNET_GCSegmentSize", "2000000", 0);
    s2a_gc_limit_apply();   // 窗口已在构造期占好，按低区最大一块自适应；仅初始化一次。
    setenv("MTL_SHADER_CACHE_SIZE", "67108864", 0);
#if TARGET_OS_IPHONE
    // iOS 一律延后启动（10-30 首次加载页，维护者 批准）：UIKit 先起、点开立即出加载页，宿主在后台线程初始化（C# 运行时、装模块、预热都不占主线程，
    //   防 iOS 启动看门狗）；资源包说明页、直连安全网提示页、预热启动都走这同一条路。原先普通启动在主线程跑完宿主初始化才进 UIKit，点开要黑屏等
    //   多款容器：先出游戏库（预热进程也只显示库），起局前检查与起宿主都等 Play
    const char *how = container ? "多款容器：先出游戏库，选了游戏才做起局前检查、起宿主" : s2a_host_pre_ui_checks();
    g_boot_argc = argc; g_boot_argv = argv;
    if (s2a_host_boot_defer(prewarmed_host_run, 1) != 1) die("宿主启动续体冲突");
    LOG("%s：等待前台", how);
    s2a_front_run(prewarmed_host_run);
    return 0;
#else
    return host_run(argc, argv);
#endif
}
