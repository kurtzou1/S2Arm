// 宽屏点（画幅线定的机制，docs/接口_原生层.md §4.8）：改写器把候选点换成「读值槽的跳板」（movz / asp / f2w）或宿主门（aspdiv / aspstr），
// 这里在装载时按屏幕宽与启用表填值槽、改 f32 数据，门里模拟原指令；未启用的点结果与原指令逐位相同。
// 启用表按档位：<模块目录>/widen_enable.<handheld|docked>.tsv（模块 / 偏移 / 种类 / 启用），只放这一档位闭环全过的点集（graphics/widen/scan/closed_loop.sh --write）；
// 档位与服务层 Host.Docked 同一开关 S2A_DOCKED（"1" = 主机，其余 = 掌机，缺省掌机）。没有这一档位的表 = 第二层不加宽。
// 试验时 S2A_WIDEN_SITES="main:0x4075720,main:0x3db1b14" 整表覆盖。
// 屏幕宽 S2A_SCREEN_W（游戏的 1080 高对应的宽；缺省 1920 = 全部原值）；iOS 上没给时由 App 壳按横屏宽高比算。
// 命中：跳板往键页命中槽写非零，宿主每秒扫一次、收局前补扫一次，打「[宽] 点 <模块>+<偏移> 首次命中（<种类>）」；门点在门里直接打。
// 随包表：widen_enable.*.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单）
// 随包表：widen_verified.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单）
// 随包表：widen_full.*.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单）
#include "native.h"
#include "patch.h"
#include <errno.h>
static _Thread_local FILE *g_boot_file;
void s2a_widen_abort_boot_inputs(void) {
    FILE *file = g_boot_file; g_boot_file = NULL;
    if (file && fclose(file)) LOG("【红】失败装载的宽屏表关闭失败 errno=%d", errno);
}
#include <math.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdatomic.h>
#if defined(__ANDROID__)
#include "../../android/native/screen_metrics.h"
#endif
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#define WSLOT 16
#define WHIT 1024
#define WMAX 1008
static const uint16_t k_cls[8] = {1920, 1280, 1600, 960, 2560, 3840, 1024, 640};   // movz 认的 16:9 档宽（同旧库）
typedef struct { uint32_t off, word; uint8_t kind, on, hit; } wsite_t;   // kind：1 movz 2 asp 3 aspdiv 4 aspstr 5 f32 6 f2w 7 lytsz 8 capsz 9 aspf 10 i32 11 aspcap 12 aspcaps 13 seadasp 14 movzh 15 restab 16 f2h 17 i2h
typedef struct { wsite_t *s; int n; uint64_t *page; } wmod_t;
static wmod_t *g_w;   // 按模块下标，g_mod_cap 项（本局第一次装宽屏表时分配，会话复位释放）
static pthread_t g_scanner;
static int g_scanner_started;
static _Atomic int g_scanner_stop;
static int g_full = -1, g_setting_on = -1, g_default_narrow, g_ws_yield = -1;
#if defined(__ANDROID__)
static int g_android_widen_active;
// Authenticated source tables are copied before the source lease is released.
static char *g_android_policy[5];
static size_t g_android_policy_len[5];
static int g_android_source;
static const char *const g_android_policy_names[] = {
    "widen_enable.handheld.tsv", "widen_enable.docked.tsv",
    "widen_full.handheld.tsv", "widen_full.docked.tsv", "widen_verified.tsv"
};
void s2a_widen_source_begin(void) {
    // A pre-admission full-width query may have cached the missing-table default.
    g_full = -1; g_android_source = 1;
}
void s2a_widen_source_policy(unsigned i, const void *bytes, size_t length) {
    if (i >= 5 || (!bytes && length) || length > 2 * 1024 * 1024 ||
        (length && memchr(bytes, 0, length))) die("APK 宽屏策略表无效");
    char *copy = malloc(length + 1);
    if (!copy) die("APK 宽屏策略表分配失败");
    if (length) memcpy(copy, bytes, length);
    copy[length] = 0; g_android_policy[i] = copy; g_android_policy_len[i] = length;
}
static FILE *android_policy_open(const char *name) {
    for (unsigned i = 0; i < 5; i++) if (!strcmp(name, g_android_policy_names[i])) {
        if (!g_android_policy[i] || !g_android_policy_len[i]) return NULL;
        FILE *file = fmemopen(g_android_policy[i], g_android_policy_len[i], "r");
        if (!file) die("APK 宽屏策略表无法读取：%s", name);
        return file;
    }
    return NULL;
}

#endif
static int g_W = 1920, g_H = 1080, g_any, g_on, g_lyt, g_size, g_hsize;   // g_hsize：启用的显示高度点（movzh）个数   // g_on：各模块启用的点总数；g_lyt：其中界面布局尺寸点（lytsz）个数；g_size：其中改渲染尺寸的点（movz / f32 / f2w）个数
// 档宽换算的唯一规则：x × W ÷ 1920 四舍五入、不取偶。各档同一比例，游戏内部「主机 / 掌机」等档间比例才保得住——
// 取偶只在乘积是奇数时改值，恰好破坏比例（画幅线 10-20 暗黑3：主机 1600 → 1955 被取偶成 1954，掌机视口 1954 × 0.8 = 1563.2 截成 1563，右缘少画 1 列）。
// 真值侧 graphics/widen/scan/truth_nso.py 用同一规则
static uint64_t scale_w(uint64_t x) { return (x * (uint64_t)g_W + 960) / 1920; }
// 档高换算（movzh，窄屏加高）：x × H ÷ 1080 四舍五入，同 scale_w 一个口径（Duo 内屏 1350：720 → 900、1080 → 1350）
static uint64_t scale_h(uint64_t x) { return (x * (uint64_t)g_H + 540) / 1080; }
static const uint16_t k_hcls[8] = {1080, 720, 900, 540, 1440, 2160, 576, 360};   // movzh 认的 16:9 档高（同 k_cls 序）
static const char *kname(int k) { static const char *const n[] = {"?", "movz", "asp", "aspdiv", "aspstr", "f32", "f2w", "lytsz", "capsz", "aspf", "i32", "aspcap", "aspcaps", "seadasp", "movzh", "restab", "f2h", "i2h"}; return k >= 1 && k <= 17 ? n[k] : "?"; }
static int kcode(const char *k) { for (int i = 1; i <= 17; i++) if (!strcmp(k, kname(i))) return i; return 0; }

// 当前档位的启用表文件名（不带目录）
static const char *enable_name(void) { const char *d = getenv("S2A_DOCKED"); return d && !strcmp(d, "1") ? "widen_enable.docked.tsv" : "widen_enable.handheld.tsv"; }
static char g_dir[1024];   // 模块目录（首个带宽屏候选表的模块装载时记下）：第三层表也在这里
// 启用表：环境变量整表覆盖 > 当前档位的 widen_enable.<档位>.tsv
static int enabled(const char *mod, uint32_t off, const char *dir) {
#if defined(__ANDROID__)
    if (!g_android_widen_active) return 0;
#endif
    const char *e = getenv("S2A_WIDEN_SITES"); char key[64]; snprintf(key, sizeof key, "%s:%#x", mod, off);
    if (e) { const char *p = e; size_t kl = strlen(key);
        while ((p = strstr(p, key))) { if ((p == e || p[-1] == ',' || p[-1] == ' ') && (p[kl] == 0 || p[kl] == ',' || p[kl] == ' ')) return 1; p += kl; }
        return 0; }
    char path[1100]; snprintf(path, sizeof path, "%s/%s", dir, enable_name()); FILE *f;
#if defined(__ANDROID__)
    f = g_android_source ? android_policy_open(enable_name()) : fopen(path, "r");
#else
    f = fopen(path, "r");
#endif
    if (!f) return 0;
    char line[256], m[32], k[16]; unsigned long o; int on, hit = 0;
    while (fgets(line, sizeof line, f)) if (sscanf(line, "%31s %lx %15s %d", m, &o, k, &on) == 4 && !strcmp(m, mod) && o == off) { hit = on; break; }
    fclose(f); return hit;
}
#if defined(__APPLE__) && TARGET_OS_IPHONE
int s2a_ios_screen_w(void);   // app.m：1080 × 横屏宽 ÷ 高（取偶）
int s2a_ios_screen_h(void);   // app.m：1920 × 横屏高 ÷ 宽（取偶）；屏幕不比 16:9 窄时 1080
int s2a_ios_screen_known(void);   // app.m：窗口场景已连上、比例取自实际所在的屏
// 弱链接[host]：s2a_ios_split_active（ios/play_layout.m；旧宿主未提供时仍按普通整屏模式）
int s2a_ios_split_active(void) __attribute__((weak_import));   // play_layout.m；旧宿主无入口时为普通整屏模式
static int g_split_at_load;
static int split_active(void) { return s2a_ios_split_active && s2a_ios_split_active(); }
#endif
// 宽屏已验证名单（10-26 维护者 拍板，覆盖同日上午「直连宽屏缺省开」）：没验证过宽屏的游戏一律 16:9 原比例加黑边，验证过的才开宽屏，不出现半宽半窄。
//   名单在仓库 graphics/widen/tables/verified.tsv（程序号 + main 构建号，入表条件 = Mac 闭环 + 真机截图量化过）；出包改写阶段（pack/stage_rewrite.sh）命中的款
//   往模块目录写 widen_verified.tsv（那一行）。这里只看文件在不在。S2A_WIDEN_VERIFIED=1 / 0 覆盖（闭环、验证局按已验证跑；=0 对照 16:9）。
//   Apple 在屏幕源头门控；Android 始终报告实际 Surface 比例，仅在启用改写时套用此名单门。
const char *s2a_module_dir(void);   // loader.c
// 宽屏设置开关（10-27 维护者：宽屏表一律进包，运行时按设置启停、不靠重出包）：S2A_WIDESCREEN=0 = 关（iOS 由 App 设置 S2AWidescreen 转来，
//   ios/settings.m；Mac 启动器设同名环境变量），下次启动生效。关 = 名单门判不开 → 屏幕宽按 1920，各层宽屏一起回 16:9（同不在名单）；
//   宽屏点读值槽、核心按屏幕宽算，都在装载时定，所以不用重出包。S2A_WIDEN_VERIFIED 照旧最优先（判定局 / 单测不受设置影响）
//   装载前（s2a_module_dir 还空）只读不缓存：iOS 预热期就有人读屏幕宽，App 设置这时还没转成 S2A_WIDESCREEN（settings.m 在进 main 前才设）。
//   11-02 维护者 饥荒：玩家选了「切换到原生画面比例」（S2AWidescreen = NO），下次启动预热读屏幕宽先把「设置开」缓存住，设置关被吞，核心照旧整套放宽、上屏却按 16:9，画面歪
static int widen_setting_on(void) {
    if (g_setting_on >= 0) return g_setting_on;
    const char *e = getenv("S2A_WIDESCREEN");
    int on = !(e && !strcmp(e, "0"));   // F1 #1574：安卓与苹果同口径——设置缺省开，名单门在 screen_w / 清单 / 验证标记处收窄
    const char *d = s2a_module_dir(); if (!d || !d[0]) return on;
    g_setting_on = on;
    if (!on) LOG("宽屏：设置未启用，整局 16:9 原比例加黑边");
    return on;
}
// 补丁优先（11-13 维护者「补丁的优先级比咱们自己的高，满画幅是一样的」）：本款开着社区宽屏类补丁（runtime/src/cpatch.c s2a_cpatch_ws_enabled）→ 我方满屏整体让位
//   （屏幕宽按 1920、各层宽屏不开，游戏按补丁画幅画、上屏按补丁画幅铺满），压过 S2A_WIDEN_VERIFIED / 满屏明确开，不拉宽两次。装载前不知道、不缓存
__attribute__((weak)) int s2a_cpatch_ws_enabled(const char *dir) { (void)dir; return 0; }   // cpatch.c 强定义；只链 widen.c 的单测用这个
static int ws_yield(void) {
    if (g_ws_yield >= 0) return g_ws_yield;
    const char *d = s2a_module_dir(); if (!d || !d[0]) return 0;
    g_ws_yield = s2a_cpatch_ws_enabled(d);
    if (g_ws_yield) LOG("宽屏：开着社区宽屏补丁，S2Arm 满屏让位（补丁优先），整局按补丁画幅铺满");
    return g_ws_yield;
}
static int widen_verified(void) {
    if (ws_yield()) return 0;
    const char *e = getenv("S2A_WIDEN_VERIFIED"); if (e) return !strcmp(e, "1");
    if (!widen_setting_on()) return 0;
    // 包内能力清单（runtime/src/caps.c：1 = 开、0 = 发布包能力卡未验按 16:9）：在用户设置之后、名单之前（审计 #854 F-caps-beats-settings）
    const char *c = getenv("S2A_WIDEN_CAPS"); if (c) return !strcmp(c, "1");
#if defined(__ANDROID__)
    if (g_android_source) return g_android_policy[4] != NULL;
#endif
    const char *d = s2a_module_dir(); char p[1100]; struct stat st;
    if (!d || !d[0]) return -1;   // 还没装载：不知道
    snprintf(p, sizeof p, "%s/widen_verified.tsv", d); return !stat(p, &st);
}
// 放 / 不放的来源，按 widen_verified 的判定顺序（10-30 #996：原先能力清单开也写「本款在宽屏已验证名单」，读日志的人当成验证过，丝之歌没验证就被宽屏放开）
static const char *widen_src(void) {
    if (ws_yield()) return "开着社区宽屏补丁（补丁优先）";
    const char *e = getenv("S2A_WIDEN_VERIFIED"); if (e) return !strcmp(e, "1") ? "S2A_WIDEN_VERIFIED=1 覆盖" : "S2A_WIDEN_VERIFIED=0 覆盖";
    if (!widen_setting_on()) return "设置里宽屏关";
    const char *c = getenv("S2A_WIDEN_CAPS"); if (c) return !strcmp(c, "1") ? "包内能力清单开（发布缺省开，未必验证过）" : "包内能力清单关";
    return "已验证名单（graphics/widen/tables/verified.tsv）";
}
// 名单门（屏幕宽 / 屏幕高共用）：要放（宽 > 1920 或高 > 1080）时看本款在不在宽屏已验证名单。返回 1 = 放，0 = 不放（16:9 原比例加黑边），-1 = 还没装载、不知道
static int widen_gate(const char *what, int v) {
    int ok = widen_verified();
    if (ok < 0) { LOG("【红】宽屏：装载前就读了%s，还不知道本款在不在宽屏已验证名单，这次按 16:9 且不记住", what); return -1; }
    if (!ok) { LOG("宽屏：不放（来源：%s），整局按 16:9 原比例加黑边（%s %d 不放）", widen_src(), what, v);
               if (!getenv("S2A_WIDEN_NARROW")) {
                   if (setenv("S2A_WIDEN_NARROW", "1", 0)) die("宽屏：设置窄屏标记失败");
                   g_default_narrow = 1;
               }
               return 0; }   // 通用上屏层的满屏判据据此不报黑边（graphics/metal/gal_present.m fit_narrow）
    LOG("宽屏：放开（来源：%s），%s %d", widen_src(), what, v); return 1;
}
// 屏幕宽唯一来源（原生层宽屏点与 C# 宽屏包装层同读这里）：S2A_SCREEN_W 优先，iOS 没给时按实际屏幕算；不在宽屏已验证名单时按 1920（见 widen_verified）；只算一次
//   窗口场景连上前（s2a_ios_screen_known() == 0）只读不缓存，与屏幕高同一做法
static _Atomic int g_sw, g_sh; static _Atomic unsigned g_sgen;   // 屏幕宽 / 高的定值（0 = 还没定）与换屏代数（s2a_screen_reaspect / s2a_screen_switch 改）
int s2a_screen_w(void) {
    int w = g_sw;
    if (!w) { const char *e = getenv("S2A_SCREEN_W"); int v = e ? atoi(e) : 1920, known = 1;
#if defined(__ANDROID__)
        if (!e) { int aw, ah; if (!s2a_android_screen_metrics(&aw, &ah)) return 0; v = aw; known = 0; }   // 安卓真屏宽也过名单门（F1 #1574：名单外 16:9）；不缓存——安卓没有 reaspect 热切，旋转靠每次新读
#elif defined(__APPLE__) && TARGET_OS_IPHONE
        if (!e) { known = s2a_ios_screen_known(); v = s2a_ios_screen_w(); }   // 窗口场景连上前（装载期、主线程）只能拿主屏原生尺寸：Duo 上一直是外屏，先不缓存，场景连上后再定
#endif
        if (v < 1920 || v > 8192) { if (v > 1920) LOG("宽屏：屏幕宽 %d 不在 1920–8192，按 1920（不加宽）", v); v = 1920; }   // 比 16:9 窄的屏：宽守 1920，多出的在高（s2a_screen_h）
        if (v > 1920) { int ok = widen_gate("屏幕宽", v); if (ok < 0) return 1920; if (!ok) v = 1920; }
        if (!known) return v;
        g_sw = w = v; }
    return w;
}
// 装载后的屏幕宽（11-07 启动器线：多款容器先出游戏库、选了游戏才装载，触屏手柄在装载前就挂上并算画面矩形）：模块还没装载（s2a_module_dir 空）回 0、
//   不读屏幕宽——名单门这时判不了，读了只会打「装载前就读了屏幕宽」红行并按 16:9 临时作答；装载后同 s2a_screen_w。
//   给「装载前不必知道、装载后才有意义」的读者用（ios/vpad.m 画面矩形的兜底比例）；单款包同样装载前就挂手柄，两条路一致
int s2a_screen_w_after_load(void) {
    const char *d = s2a_module_dir();
    return d && d[0] ? s2a_screen_w() : 0;
}
// 屏幕高唯一来源（10-26 任意宽高比，维护者派单：iPhone Duo 内屏 2670×1878 = 1.42、iPad 4:3 比 16:9 窄）：以 1920 宽为基准的高——屏幕比 a 窄于 16:9 时
//   = 1920 ÷ a（取偶，Duo 1350、4:3 1440），游戏画面宽不动、上下多画（Vert+；两侧收窄会连贴边界面一起裁掉）；不比 16:9 窄时 1080。
//   S2A_SCREEN_H 优先（Mac 上模拟窄屏）；iOS / Android 未指定时按实际窗口算。Android 不将实际屏高替换成 1080。
// 比 16:9 窄的真屏（iPhone Duo 外屏 1.455 / 内屏 1.42、iPad 4:3）照真屏加高（Vert+）。11-02 起：竖向遮罩外推 / 叠影 / EFB 竖向晋升修完，
//   Duo 外屏真机自动验收（丝之歌、银河2 局内满屏、满屏判据 0 红）与 Mac 1920×1318 / 1920×1440 局过，撤掉原先压回 1080 的上限
int s2a_screen_h(void) {
#if defined(__ANDROID__)
    if (!getenv("S2A_SCREEN_H")) { int w, h; if (!s2a_android_screen_metrics(&w, &h)) return 0;
        if (h > 1080) { int ok = widen_gate("屏幕高", h); if (ok < 0) return 1080; if (!ok) h = 1080; }   // F1 #1574：真屏高也过名单门（窄屏 Vert+ 名单外回 16:9）；不缓存
        return h; }
#endif
    int h = g_sh;
    if (!h) { const char *e = getenv("S2A_SCREEN_H"); int v = e ? atoi(e) : 1080, known = 1;
#if defined(__APPLE__) && TARGET_OS_IPHONE
        if (!e) { known = s2a_ios_screen_known(); v = s2a_ios_screen_h(); }   // 窗口场景连上前（装载期、主线程）只能拿主屏原生尺寸：Duo 上一直是外屏，先不缓存，场景连上后再定
#endif
        if (v < 1080 || v > 8192) { if (v > 1080) LOG("宽屏：屏幕高 %d 不在 1080–8192，按 1080（不加高）", v); v = 1080; }
        if (v > 1080 && s2a_screen_w() > 1920) { LOG("【红】宽屏：屏幕宽 %d、高 %d 同时超出 16:9，按高 1080", s2a_screen_w(), v); v = 1080; }   // 只会有一边多出
        if (v > 1080) { int ok = widen_gate("屏幕高", v); if (ok < 0) return 1080; if (!ok) v = 1080; }
        if (!known) return v;
        g_sh = h = v; }
    return h;
}
// 运行中换屏（10-27 Duo 合上切外屏 1.455、展开回内屏 1.422；macOS 窗口拖拽同理）：直连第三层按新屏幕比重出图（graphics/nvn/widen_glue.inc 在下一个渲染遍前换核心比例、
//   按新尺寸重建放宽的渲染目标）。只改宽屏核心用的屏幕宽 / 高：服务层报的显示分辨率、第二层宽屏点在装载时已定，不跟着变（读这两个值的地方只在装载时读）。
//   名单门沿用首次结果（不在名单 = 一直 1920 × 1080）。s2a_screen_switch：直接给定（Mac 模拟换屏 S2A_REASPECT_AT，测试与窗口拖拽用）；
//   s2a_screen_reaspect：iOS 按当前屏重算（App 壳布局回调经 s2a_direct_relayout 调）。值变了返回 1、代数加一
unsigned s2a_screen_gen(void) { return g_sgen; }
int s2a_screen_switch(int w, int h) {
    if (!g_sw || !g_sh) return 0;   // 首次还没定：首次读时自然按当前屏
    if (g_sw <= 1920 && g_sh <= 1080 && !(widen_verified() > 0)) return 0;   // 不在名单：一直 16:9
    if (w < 1920 || w > 8192) w = 1920;
    if (h < 1080 || h > 8192) h = 1080;
    if (w > 1920 && h > 1080) h = 1080;   // 只会有一边多出（同 s2a_screen_h）
    if (w == g_sw && h == g_sh) return 0;
    LOG("宽屏：运行中换屏，屏幕宽 / 高 %d×%d → %d×%d（第 %u 次）", g_sw, g_sh, w, h, g_sgen + 1);
    g_sw = w; g_sh = h; g_sgen++;
    return 1;
}
static _Atomic int g_force_native, g_force_w, g_force_h;   // s2a_widen_force_native：本局钉成原生 16:9（钉前的屏幕宽 / 高，撤钉时 Mac 按它换回）
// 按窗口像素尺寸跟屏（审计 P1-83：Mac 壳从不换屏幕宽，窗口拉宽 / 全屏后逻辑分辨率仍是 1920×1080、两侧黑边；维护者 任何比例都满屏，Mac 一样）：
//   与 iOS 同一口径（ios/app.m s2a_ios_screen_w / h）：比 16:9 宽 → 宽 = 1080 × 宽高比（取偶）、高 1080；比 16:9 窄 → 宽 1920、高 = 1920 ÷ 宽高比（取偶）。
//   经 s2a_screen_switch 热切（名单门、范围夹取同它）；玩家选了退回原生 16:9（钉住）或环境变量给定屏幕（判定局 / 模拟换屏）时不跟。变了返回 1
__attribute__((weak)) void s2a_cpatch_aspect(double A) { (void)A; }   // runtime/src/cpatch.c 强定义：自适应画幅补丁按窗口 / 屏幕比例重选模板、重算值（不过宽屏名单门：社区补丁自己改画幅）；只链 widen.c 的单测用这个空的
int s2a_screen_fit(int pw, int ph) {
    if (pw > 0 && ph > 0 && !getenv("S2A_CPATCH_ASPECT")) s2a_cpatch_aspect((double)pw / ph);
    if (g_force_native || pw <= 0 || ph <= 0 || getenv("S2A_SCREEN_W") || getenv("S2A_SCREEN_H")) return 0;
    double r = (double)pw / ph;
    return s2a_screen_switch(((int)(1080.0 * r)) & ~1, r * 9 < 16 ? ((int)(1920.0 / r)) & ~1 : 1080);
}
#if TARGET_OS_IPHONE
// iOS 当前屏的宽高比（自适应画幅补丁用，cpatch.c 装载时与下面换屏时同一口径）。s2a_ios_screen_w 是「1080 高对应的宽」、s2a_ios_screen_h 是
//   「1920 宽对应的高」（比 16:9 宽时 1080），两者口径不同不能直接相除（Duo 内屏 1534 ÷ 1350 = 1.136，真屏 1.42）：窄屏按 1920 ÷ 高、宽屏按 宽 ÷ 1080
double s2a_ios_screen_aspect(void) { int h = s2a_ios_screen_h(); return h > 1080 ? 1920.0 / h : s2a_ios_screen_w() / 1080.0; }
#endif
int s2a_screen_reaspect(void) {
    if (g_force_native) return 0;   // 玩家选了退回原生 16:9：App 壳布局回调不许把屏宽改回真屏
#if TARGET_OS_IPHONE
    // 只保护跨分屏模式的变化；普通合上 / 展开沿用主线的满屏热切策略。
    // 对比装载时的模式，重复布局回调不能绕过；切回原模式后自然恢复跟屏。
    if (g_on > 0 && split_active() != g_split_at_load) return 0;
    if (s2a_ios_screen_known() && s2a_ios_screen_h() > 0 && !getenv("S2A_CPATCH_ASPECT")) s2a_cpatch_aspect(s2a_ios_screen_aspect());
    if (getenv("S2A_SCREEN_W") || getenv("S2A_SCREEN_H") || !s2a_ios_screen_known()) return 0;   // 环境变量给定的（Mac 模拟 / 判定局）不跟屏
    return s2a_screen_switch(s2a_ios_screen_w(), s2a_ios_screen_h());   // 运行中换到窄屏（Duo 合上 / 展开）按新屏加高
#else
    return 0;
#endif
}
// 游戏自己出宽图（第二层）：屏幕比 16:9 宽且装载时启用了改渲染尺寸的点（movz 显示宽 / f32 分辨率表 / f2w 宽高字面量）；C# 宽屏包装层据此只管界面层。
//   只启用了改宽高比的点（asp / aspdiv / aspstr）时游戏照旧按 16:9 尺寸建渲染目标、投影已按屏幕比算：不算出宽图，照第三层放宽存储，
//   核心只认 16:9 投影、不会再改写已是屏幕比的投影（10-26 马车8：社区超宽屏补丁只改 main 0x3cd314 的宽高比除法）。模块装完后（S2A_Init 起）才有定值
//   例外：只启用了改宽高比的点、而这一档第三层表写了「0」（闭环验出整套放宽会坏）时仍算出宽图——不然核心进 16:9 原比例居中，投影却已是屏幕比，画面横向压扁；
//   算出宽图时核心只收界面层、上屏按屏幕比铺满，与改前同（s2a_widen_full 读表，模块装完才调）
int s2a_widen_full(void);
int s2a_widen_game(void);
// 运行中退回原生 16:9（11-02 维护者：局内满屏异常累计 20 秒问玩家是否退回，最好热切换；体验线调）：on = 1 钉成 1920×1080，经 s2a_screen_switch 同一机制
//   热切（直连胶水下一个渲染遍前换核心比例：屏宽 ≤ 1920 → 核心 Off、放宽的目标交原尺寸），之后 s2a_screen_reaspect 不再按真屏改回；on = 0 撤钉、按真屏
//   （iOS）/ 钉前的值（Mac）换回。游戏自己出宽图（s2a_widen_game：第二层改渲染尺寸的点在装载时填死值槽）热切不了，不动、返回 -1（要重启：装载前关本款宽屏）。
//   返回 1 = 换了；0 = 没变化（本来就是 16:9 / 没钉 / 屏幕还没定）
int s2a_widen_force_native(int on) {
    if (on) {
        if (g_force_native) return 0;
        if (s2a_widen_game()) return -1;
        if (!g_sw || !g_sh) return 0;
        g_force_w = g_sw; g_force_h = g_sh; g_force_native = 1;
        return s2a_screen_switch(1920, 1080);
    }
    if (!g_force_native) return 0;
    g_force_native = 0;
#if TARGET_OS_IPHONE
    if (!getenv("S2A_SCREEN_W") && !getenv("S2A_SCREEN_H")) return s2a_screen_reaspect();
#endif
    return s2a_screen_switch(g_force_w, g_force_h);
}
// 窄屏（11-02 智慧的再现 Duo）：启用了显示高度点 = 游戏自己按更高的画布渲染、裁切跟着变高（同宽屏的宽度点），核心不再竖向加高
// 先看装载时定下的点数（g_size / g_on / g_hsize，装载前都是 0）再读屏幕宽 / 高：装载前（多款容器停在游戏库、单款加载页时触屏手柄就问画布）不读屏幕，
//   不过名单门、不打「装载前就读了屏幕宽」红行，也不在模块目录还空时把 s2a_widen_full 缓存成开（11-07 启动器线）。真值与原式相同（只调换 && 两边的求值顺序）
int s2a_widen_game(void) { return ((g_size > 0 || (g_on > 0 && !s2a_widen_full())) && s2a_screen_w() > 1920) || (g_hsize > 0 && s2a_screen_h() > 1080); }
// 游戏画布 = 触点坐标空间（审计 P1-92）：游戏自己出宽 / 高图（s2a_widen_game）时是服务层报给游戏的显示尺寸，同 S2ADisplay 掌机档
//   宽 round(720 × 屏宽 ÷ 1080 ÷ 2) × 2、高 round(720 × 屏高 ÷ 1080 ÷ 2) × 2（屏高 ≤ 1080 时 720）；否则游戏按 Switch 触摸屏固定的 1280×720 读触点。
//   iOS 触屏（vpad.m）与 Mac 左键（front_mac.m）都用它：原先两处各写一份、高一律 720，窄屏高度点的局（Duo 1920×1350 游戏按 1280×900 出图）
//   点在画面最下沿发成第 719 行、游戏读成 80% 高处，下面 180 行点不到
void s2a_game_canvas(int *w, int *h) {
    if (!s2a_widen_game()) { *w = 1280; *h = 720; return; }   // 先判出不出宽图（装载前恒否、不读屏幕），再读屏幕宽 / 高
    int sw = s2a_screen_w(), sh = s2a_screen_h();
    *w = sw > 0 ? (int)floor(720.0 * sw / 1080.0 / 2.0 + 0.5) * 2 : 1280;
    *h = sh > 1080 ? (int)floor(720.0 * sh / 1080.0 / 2.0 + 0.5) * 2 : 720;
}
// 游戏界面布局也是宽的（10-23 塞尔达雷达）：第二层启用了界面布局尺寸点（lytsz）= 游戏按宽屏画布排界面、按真实宽屏像素算界面剪裁；
//   C# 包装层据此不再把读改写矩阵的界面层局部剪裁收进中间（那条收缩只对按 16:9 画布拉满全宽排界面的款成立，如动森）。模块装完后才有定值
int s2a_widen_layout(void) { return s2a_widen_game() && g_lyt > 0; }
// 帧回放（graphics/nvn/gfx/nvn/nvn_frame_rec.inc）：不装游戏，屏幕宽高与宽屏三项按录像落定（不过名单门：录时已过）
void s2a_frame_replay_screen(int w, int h, int game, int layout, int full) {
    g_sw = w; g_sh = h; g_full = full ? 1 : 0; g_size = g_hsize = game ? 1 : 0; g_on = 0; g_lyt = layout ? 1 : 0;   // 窄屏录像的「游戏出图」靠 g_hsize（s2a_widen_game 窄屏分支）
    LOG("帧回放：屏幕 %d×%d，游戏出宽图 %d、界面布局 %d、整套放宽 %d（按录像）", w, h, s2a_widen_game(), s2a_widen_layout(), s2a_widen_full());
}
// 第三层（包装层整套放宽：放宽 16:9 一族贴图 + 改写 16:9 投影）也只用闭环验过的表（10-21 维护者 实机：暗黑2 / 巫师3 整套放宽后画面拉伸、错位、阶梯亮带）：
//   10-26 改缺省（维护者定 A，依 维护者「满屏是目标，不是可选项」）：没有表 = 整套放宽；表里一行「0」= 这一档位闭环验出放宽会坏，按 16:9 原比例居中留黑边（维护者 10-20「没得补就留黑边」）。
//   10-21 那道「只用验过的表」的门是因为暗黑2 / 巫师3 整套放宽后拉伸、错位；直连那一类的根子是渲染目标存储没放宽（10-26 tex_widen 根修），所以门改成「验坏才关」。
//   试验时 S2A_WIDEN_FULL=1 / 0 覆盖。第二层生效（s2a_widen_game）时包装层只管界面层，与本表无关
int s2a_widen_full(void) {
    if (g_full >= 0) return g_full;
    const char *e = getenv("S2A_WIDEN_FULL");
#if defined(__ANDROID__)
    const char *verified = getenv("S2A_WIDEN_VERIFIED");
    if (!widen_setting_on() && !(verified && !strcmp(verified, "1"))) return g_full = 0;
    int allowed = widen_gate("宽屏改写", 1);
    if (allowed < 0) return 0; // before module admission: do not cache a decision
    if (!allowed) return g_full = 0;
#endif
    if (e) return g_full = !strcmp(e, "1");
    const char *d = getenv("S2A_DOCKED"); char path[1200], line[64];
    int pf = s2a_patch_widen_full(d && !strcmp(d, "1")); if (pf >= 0) return g_full = pf;   // 补丁 [widen.full.<档位>] 压过包内表
    g_full = 1;
#if defined(__ANDROID__)
    if (!g_dir[0] && !g_android_source) return g_full;
#else
    if (!g_dir[0]) return g_full;
#endif
    snprintf(path, sizeof path, "%s/%s", g_dir, d && !strcmp(d, "1") ? "widen_full.docked.tsv" : "widen_full.handheld.tsv");
    FILE *f;
#if defined(__ANDROID__)
    f = g_android_source ? android_policy_open(d && !strcmp(d, "1") ? "widen_full.docked.tsv" : "widen_full.handheld.tsv") : fopen(path, "r");
#else
    f = fopen(path, "r");
#endif
    if (!f) return g_full;
    while (fgets(line, sizeof line, f)) if (!strcmp(line, "0\n") || !strcmp(line, "0")) { g_full = 0; break; }
    fclose(f);
    return g_full;
}
// 屏幕宽高比 = 屏宽 ÷ 屏高（都以游戏 1920 × 1080 为基准）：宽屏屏高 1080、屏宽 > 1920；比 16:9 窄的屏屏宽守 1920、屏高 > 1080（s2a_screen_h，Vert+）。
//   11-02 维护者 Duo 手测智慧的再现补丁：原先写死 ÷ 1080，窄屏宽高比点仍给 1.778，镜头照 16:9 出图、竖向完全没扩
static float aspect(void) { return (float)g_W / (float)g_H; }
static uint32_t fbits(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }

// 补丁启用行对号（补丁包 v1 第 2.1 节：不按绝对偏移套）：同构建号 = 按偏移找候选点（快路径），核种类与原指令字；
//   构建号不同 = 在本模块候选点里找种类、原指令字相同且前后特征字节对得上的，唯一命中才用（换成新偏移），0 个或多个跳过这一条。
//   特征按原映像比：改写器换掉的候选点（代码类种类）取候选表里的原字，asp 后面那条配对 MOVK 也被换掉，不比。返回 1 = 补丁有本档位的段（整表取补丁）
// restab 档位表的档数：从 off 起 n 个 u32 宽、紧接 n 个 u32 高，逐档宽 × 9 = 高 × 16、宽严格递增；取最大的 n（4–64），不成表 0。扫描器 graphics/widen/scan/wide_scan.py 同一判法
static int restab_n(const uint8_t *base, uint64_t off, uint64_t hi) {
    for (int n = 64; n >= 4; n--) {
        if (off + 8ull * (uint64_t)n > hi) continue;
        const uint32_t *tw = (const uint32_t *)(base + off), *th = tw + n; int ok = 1;
        for (int i = 0; i < n && ok; i++) ok = tw[i] >= 64 && tw[i] <= 16384 && (uint64_t)tw[i] * 9 == (uint64_t)th[i] * 16 && (!i || tw[i] > tw[i - 1]);
        if (ok) return n;
    }
    return 0;
}
static int code_kind(int k) { return k != 5 && k != 9 && k != 10 && k != 15; }   // f32 / aspf / i32 / restab 是数据点，映像里还是原值
static int orig_byte(module_t *m, wmod_t *w, uint64_t p, int *known) {
    *known = 1;
    for (int i = 0; i < w->n; i++) { const wsite_t *t = &w->s[i]; if (!code_kind(t->kind)) continue;
        if (p >= t->off && p < t->off + 4u) return (int)((t->word >> (8 * (p - t->off))) & 0xff);
        if (t->kind == 2 && p >= t->off + 4u && p < t->off + 8u) { *known = 0; return 0; } }
    return p < m->size ? m->base[p] : (*known = 0, 0);
}
static int sig_ok(module_t *m, wmod_t *w, uint32_t at, const s2a_patch_wrow_t *r) {
    for (int j = 0; j < r->npre + r->npost; j++) {
        int pre = j < r->npre; uint8_t want = pre ? r->pre[j] : r->post[j - r->npre], mk = pre ? r->prem[j] : r->postm[j - r->npre];
        if (!mk) continue;
        int64_t p = pre ? (int64_t)at - r->npre + j : (int64_t)at + 4 + (j - r->npre); int kn;
        if (p < 0) return 0;
        int b = orig_byte(m, w, (uint64_t)p, &kn); if (!kn || (uint8_t)b != want) return 0;
    }
    return 1;
}
static int patch_enable(module_t *m, wmod_t *w) {
    const char *d = getenv("S2A_DOCKED"); const s2a_patch_wrow_t *r;
    int n = s2a_patch_widen_rows(m->name, d && !strcmp(d, "1"), &r);
    if (n < 0) return 0;
    const char *pb = s2a_patch_build(), *mb = s2a_main_build_id(); int same = pb[0] && mb && !strcasecmp(pb, mb);
    for (int i = 0; i < w->n; i++) w->s[i].on = 0;
    for (int j = 0; j < n; j++) {
        int kc = kcode(r[j].kind), hit = -1, nh = 0;
        if (!kc) { s2a_patch_count(2); s2a_patch_note("第 %d 行 %s+%#x 种类 %s 不认，跳过", r[j].line, m->name, r[j].off, r[j].kind); continue; }
        if (same) {
            for (int i = 0; i < w->n; i++) if (w->s[i].off == r[j].off) hit = i;
            if (hit < 0 || w->s[hit].kind != kc || (r[j].has_orig && w->s[hit].word != r[j].orig)) {
                s2a_patch_count(2); s2a_patch_note("第 %d 行 %s+%#x %s：本包候选表%s，跳过", r[j].line, m->name, r[j].off, r[j].kind, hit < 0 ? "没有这个点" : "种类或原指令字对不上"); continue; }
            w->s[hit].on = (uint8_t)r[j].on; s2a_patch_count(0); continue;
        }
        if (!r[j].has_orig) { s2a_patch_count(2); s2a_patch_note("第 %d 行 %s+%#x：本包构建 %s 不是补丁编写构建，这行没写 orig= 不能按特征定位，跳过", r[j].line, m->name, r[j].off, mb ? mb : "?"); continue; }
        for (int i = 0; i < w->n; i++)
            if (w->s[i].kind == kc && w->s[i].word == r[j].orig && sig_ok(m, w, w->s[i].off, &r[j])) { hit = i; nh++; }
        if (nh != 1) { s2a_patch_count(2); s2a_patch_note("第 %d 行 %s+%#x %s 在本版本 %s 上特征命中 %d 处，跳过", r[j].line, m->name, r[j].off, r[j].kind, mb ? mb : "?", nh); continue; }
        w->s[hit].on = (uint8_t)r[j].on; s2a_patch_count(1);
        s2a_patch_note("第 %d 行 %s+%#x %s 按特征定位到 +%#x", r[j].line, m->name, r[j].off, r[j].kind, w->s[hit].off);
    }
    return 1;
}
static void widen_load_stream(module_t *m, const char *dir, const char *path, FILE *f) {
    g_boot_file = f;
#if defined(__ANDROID__)
    // Disabled sites still need original-value key slots: rewritten guest code
    // reads them even when no experimental widening is enabled.
    const char *verified = getenv("S2A_WIDEN_VERIFIED");
    int requested = widen_setting_on() || (verified && !strcmp(verified, "1"));
    g_android_widen_active = requested && widen_gate("宽屏改写", 1) == 1;
    g_W = g_android_widen_active ? s2a_screen_w() : 1920;
    g_H = g_android_widen_active ? s2a_screen_h() : 1080;
#else
    g_W = s2a_screen_w(); g_H = s2a_screen_h();
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (!g_on) g_split_at_load = split_active();
#endif
#endif
    if (g_H < 1080) g_H = 1080;   // 读不到屏高（安卓 0）按 16:9
    if (!g_dir[0]) snprintf(g_dir, sizeof g_dir, "%s", dir);
    if (!g_w && !(g_w = calloc((size_t)g_mod_cap, sizeof *g_w))) die("宽屏模块表 %d 项分配失败", g_mod_cap);
    wmod_t *w = &g_w[m - g_mod]; w->s = calloc(WMAX, sizeof *w->s); if (!w->s) die("宽屏点表分配失败"); w->page = (uint64_t *)(m->base + m->key_page_off);
    if (mprotect(w->page, m->key_page_size, PROT_READ | PROT_WRITE)) die("%s 键页改可写失败（宽屏槽）", m->name);   // 命中槽要可写，键页不再封只读
    char line[256], k[16]; unsigned idx; unsigned long off, word; int non = 0;
    while (fgets(line, sizeof line, f)) {
        if (w->n >= WMAX) {
#if defined(__ANDROID__)
            if (g_android_source) die("%s：宽屏点超过槽容量", path);
#endif
            break;
        }
#if defined(__ANDROID__)
        if (g_android_source) {
            char extra;
            if (sscanf(line, "%u %lx %15s %lx %c", &idx, &off, k, &word, &extra) != 4 ||
                idx != (unsigned)w->n || off > UINT32_MAX || word > UINT32_MAX || off + 4 > m->size)
                die("%s 第 %d 行格式、范围或序号不对", path, w->n);
        } else
#endif
        if (sscanf(line, "%u %lx %15s %lx", &idx, &off, k, &word) != 4 || idx != (unsigned)w->n)
            die("%s 第 %d 行格式或序号不对", path, w->n);
        wsite_t *s = &w->s[w->n++]; s->off = (uint32_t)off; s->word = (uint32_t)word; s->kind = (uint8_t)kcode(k);
        if (!s->kind) die("%s：不认识的种类 %s", path, k);
    }
    if (ferror(f)) die("%s：宽屏点表读取失败", path);
    fclose(f); g_boot_file = NULL;
    // 启用：S2A_WIDEN_SITES 整表覆盖 > 补丁 [widen.enable.<档位>]（有这段 = 整表取补丁，没提到的点关）> 包内 widen_enable.<档位>.tsv
    int by_patch = !getenv("S2A_WIDEN_SITES") && patch_enable(m, w);
    if (!by_patch) for (int i = 0; i < w->n; i++) w->s[i].on = (uint8_t)enabled(m->name, w->s[i].off, dir);
    for (idx = 0; idx < (unsigned)w->n; idx++) {
        wsite_t *s = &w->s[idx];
        if (s->kind == 11 || s->kind == 12) {   // aspcap / aspcaps：宽高比上限（10-26 暗黑2 19:9）。取 max(原值, 屏幕比) 自带守卫——屏幕不比上限宽时就是原值，
            //   所以不经闭环挑点、不看启用表：开不开只由名单门管（不在名单屏幕宽按 1920，比上限窄，原值）。不计入 g_on：它不改渲染尺寸，只去掉游戏自己的黑柱
            uint32_t lo = (s->word >> 5) & 0xffff, orig = (lo == 0x1c72 ? 0x4007u : 0x4015u) << 16 | lo; float o, a = aspect(); memcpy(&o, &orig, 4);
            // aspcaps 是存进常量缓冲交给着色器的那份：游戏的边柱着色器在上限处画约 20–30 像素向内的柔边，屏幕宽于上限时再加 0.15 把柔边推出屏外
            //   （d2r-mobile dm/host/thread.c 推导：柔边 ≤ 30 像素 / 900 高 ⇒ 至少 2 × 30 / 900 ≈ 0.067，0.15 留一倍余量；按屏高比例，与分辨率无关）
            w->page[WSLOT + idx] = a > o ? fbits(s->kind == 12 ? a + 0.15f : a) : orig; s->on = a > o;
            if (s->on) LOG("宽屏：%s+%#x %s 宽高比上限 %.4f → %.4f（屏幕宽 %d）", m->name, s->off, kname(s->kind), (double)o, (double)(s->kind == 12 ? a + 0.15f : a), g_W);
            continue;
        }
        non += s->on; if (s->on && s->kind == 7) g_lyt++; if (s->on && (s->kind == 1 || s->kind == 5 || s->kind == 6 || s->kind == 10 || s->kind == 15)) g_size++; if (s->on && (s->kind == 14 || s->kind == 15 || s->kind == 16 || s->kind == 17)) g_hsize++;
        uint64_t *slot = &w->page[WSLOT + idx];
        if (s->kind == 1) {   // movz：值 = 立即数 << 16×hw；启用且是 16:9 档宽 → scale_w(档宽)
            uint32_t imm = (s->word >> 5) & 0xffff, hw = (s->word >> 21) & 3, v = imm << (16 * hw); int c = -1;
            for (int i = 0; i < 8; i++) if (imm == k_cls[i] && !hw) c = i;
            // 浮点写法（11-03 Pokopia 主场景视口 = 缩放比 × 1920.0）：MOVZ Wd,#hi16(档宽.0f),LSL#16 装浮点位 → scale_w(档宽) 的完整浮点位
            int cf = -1; for (int i = 0; i < 8; i++) if (hw == 1 && imm == fbits((float)k_cls[i]) >> 16) cf = i;
            if (s->on && c >= 0) v = (uint32_t)scale_w(imm);
            else if (s->on && cf >= 0) v = fbits((float)scale_w(k_cls[cf]));
            else if (s->on) LOG("【红】宽屏：%s+%#x movz 立即数 %u 不是 16:9 档宽，按原值", m->name, s->off, imm);
            *slot = v;
        } else if (s->kind == 14) {   // movzh：显示高度；启用且是 16:9 档高 → scale_h(档高)，否则原立即数（宽屏 H = 1080 时就是原值）
            uint32_t imm = (s->word >> 5) & 0xffff, hw = (s->word >> 21) & 3, v = imm << (16 * hw); int c = -1;
            for (int i = 0; i < 8; i++) if (imm == k_hcls[i] && !hw) c = i;
            int cf = -1; for (int i = 0; i < 8; i++) if (hw == 1 && imm == fbits((float)k_hcls[i]) >> 16) cf = i;   // 浮点写法，同 movz
            if (s->on && cf >= 0) v = fbits((float)scale_h(k_hcls[cf]));
            else if (s->on && c >= 0) v = (uint32_t)scale_h(imm);
            else if (s->on) LOG("【红】宽屏：%s+%#x movzh 立即数 %u 不是 16:9 档高，按原值", m->name, s->off, imm);
            *slot = v;
        } else if (s->kind == 2) {   // asp：16:9 浮点 → 屏幕宽 ÷ 1080；未启用 = 原 MOVZ 立即数 | 0x3fe3 << 16（改写器只认 MOVK #0x3fe3 配对，低半取原字：0x8e39 / 0x8e3b）
            *slot = s->on ? fbits(aspect()) : (0x3fe3u << 16 | ((s->word >> 5) & 0xffff));
        } else if (s->kind == 6) {   // f2w：MOVZ Xd,#hi16(宽.0f),LSL#16；值槽 = 原值 hi16 << 16，启用且宽是 16:9 档 → scale_w(宽) 的完整浮点位（后面的 MOVK #hi16(高),LSL#48 原样执行）
            uint32_t imm = (s->word >> 5) & 0xffff, v = imm << 16; float fw; memcpy(&fw, &v, 4); int c = -1;
            for (int i = 0; i < 8; i++) if (fw == (float)k_cls[i]) c = i;
            if (s->on && c >= 0) v = fbits((float)scale_w(k_cls[c]));
            else if (s->on) LOG("【红】宽屏：%s+%#x f2w 宽 %g 不是 16:9 档宽，按原值", m->name, s->off, (double)fw);
            *slot = v;
        }
        else if (s->kind == 16 || s->kind == 17) {   // f2h / i2h：打包宽高的高半（MOVK Xd,#高,LSL#48 浮点 / LSL#32 整数，改成装整个 8 字节）。
            //   低半 = 搭档（f2w / movz）这一格算出的宽（开了按屏宽、没开原值）；高半 = 启用且是 16:9 档高 → 按屏高缩放（f2h 浮点位、i2h 整数），否则原值。
            //   两半都没动时与原两条指令拼出的 8 字节逐位相同
            int fl = s->kind == 16, pk = fl ? 6 : 1; uint32_t imm = (s->word >> 5) & 0xffff, hv = fl ? imm << 16 : imm, lo = 0; int have = 0, c = -1;
            float fh = 0; if (fl) memcpy(&fh, &hv, 4);
            // 搭档 = 往回 16 条内第一条写 Xd 的指令（同扫描器配对规则）：是搭档种类的改写点 → 取它这格（已按开关算好，原指令已换成跳板）；
            //   是原样的 MOVZ Xd（f2h：#hi16,LSL#16；i2h：#宽,LSL#0；搭档那行被跳过）→ 原值；别的指令写了 Xd → 配对断了
            for (uint32_t j = 1; !have && j <= 16 && s->off >= 4 * j; j++) {
                uint32_t o = s->off - 4 * j; int si = -1;
                for (int i = 0; i < (int)idx; i++) if (w->s[i].off == o) si = i;
                if (si >= 0 && w->s[si].kind == pk && (w->s[si].word & 31) == (s->word & 31)) { lo = (uint32_t)w->page[WSLOT + si]; have = 1; break; }
                uint32_t z = *(const uint32_t *)(m->base + o);
                if ((z & 0xffe0001f) == ((fl ? 0xd2a00000u : 0xd2800000u) | (s->word & 31))) { lo = fl ? ((z >> 5) & 0xffff) << 16 : (z >> 5) & 0xffff; have = 1; break; }
                if (si < 0 && (z & 31) == (s->word & 31)) break; }
            if (!have) LOG("【红】宽屏：%s+%#x %s 找不到配对的 MOVZ，低半按 0", m->name, s->off, kname(s->kind));
            for (int i = 0; i < 8; i++) if (fl ? fh == (float)k_hcls[i] : imm == k_hcls[i]) c = i;
            if (s->on && c >= 0) hv = fl ? fbits((float)scale_h(k_hcls[c])) : (uint32_t)scale_h(k_hcls[c]);
            else if (s->on) LOG("【红】宽屏：%s+%#x %s 高 %g 不是 16:9 档高，按原值", m->name, s->off, kname(s->kind), fl ? (double)fh : (double)imm);
            *slot = (uint64_t)hv << 32 | lo;
        }
        else if (s->kind == 5 && s->on) {   // f32：16:9 浮点分辨率表的锚点（1920.0, 1080.0）。表里各档（如 960×540 … 3840×2160）一起按屏幕宽放大：
            // 从锚点往前、往后找连续的 8 字节浮点对，满足 y>0、x 是整数、|x/y − 16/9| < 1e-3 的 x 改成 scale_w(x)、y 不动，遇到第一个不满足的就停，
            // 不越过可写的映像范围（表在只读数据段里，画幅线 10-19：掌机模式游戏用 1280×720，只改 1920 那项会让 2.17 的镜头画进 16:9 的目标）
            float *a = (float *)(m->base + s->off);
            uint64_t lo = (m->text_end + 0x3FFF) & ~0x3FFFull, hi = m->patch_off >= 0 ? (uint64_t)m->patch_off : m->file_image_len;   // 可写范围：代码段末页之后（只读数据余部 + data，Mac / iOS 都是可写映射）到映像 / 文件段末
            if (s->off < lo || s->off + 8 > hi) LOG("【红】宽屏：%s+%#x f32 锚点不在代码段之后的可写范围，未改", m->name, s->off);   // 同 aspf / i32（审计 #829 F-scan-f32-text：代码段里凑巧的浮点对不是分辨率表）
            else if (a[0] != 1920.0f || a[1] != 1080.0f) LOG("【红】宽屏：%s+%#x f32 锚点 (%g, %g) 不是 (1920, 1080)，未改", m->name, s->off, (double)a[0], (double)a[1]);
            else {
                #define OK16_9(p) ((p)[1] > 0 && (p)[0] == floorf((p)[0]) && fabsf((p)[0] / (p)[1] - 16.0f / 9.0f) < 1e-3f)
                int n = 0; uint64_t o = s->off;   // o = 表首项偏移
                while (o >= lo + 8 && OK16_9((float *)(m->base + o - 8))) o -= 8;
                uint64_t e = o; while (e + 8 <= hi && OK16_9((float *)(m->base + e))) e += 8;   // 先量整张表的范围，与补丁 [data] 写过的字节重叠就整点让给 [data]
                if (s2a_patch_data_overlap(m->name, o, e - o)) { s2a_patch_note("满屏 %s+%#x f32 表 [%#llx, %#llx) 与补丁 [data] 重叠，以 [data] 为准，这点跳过", m->name, s->off, (unsigned long long)o, (unsigned long long)e); }
                else {
                for (float *p = (float *)(m->base + o); o + 8 <= hi && OK16_9(p); p += 2, o += 8, n++)
                    p[0] = (float)scale_w((uint64_t)p[0]);
                LOG("宽屏：%s+%#x f32 表 %d 项按屏幕宽放大（宽 %d）", m->name, s->off, n, g_W);
                }
                #undef OK16_9
            }
        }
        else if (s->kind == 9 && s->on) {   // aspf：单独的 16:9 浮点常量（代码按地址读它当镜头宽高比，10-26 暗黑3 0xeb0b10）→ 屏幕宽 ÷ 1080；只改代码段之后的可写范围
            uint64_t lo = (m->text_end + 0x3FFF) & ~0x3FFFull, hi = m->patch_off >= 0 ? (uint64_t)m->patch_off : m->file_image_len;
            uint32_t *p = (uint32_t *)(m->base + s->off);
            if (s->off < lo || s->off + 4 > hi) LOG("【红】宽屏：%s+%#x aspf 不在代码段之后的可写范围，未改", m->name, s->off);
            else if (s2a_patch_data_overlap(m->name, s->off, 4)) s2a_patch_note("满屏 %s+%#x aspf 与补丁 [data] 重叠，以 [data] 为准，这点跳过", m->name, s->off);
            else if (*p != 0x3fe38e39u && *p != 0x3fe38e3bu) LOG("【红】宽屏：%s+%#x aspf 原值 %#x 不是 16:9 浮点，未改", m->name, s->off, *p);
            else { *p = fbits(aspect()); LOG("宽屏：%s+%#x aspf 16:9 常量改为屏幕比 %.4f（宽 %d）", m->name, s->off, (double)aspect(), g_W); }
        }
        else if (s->kind == 10 && s->on) {   // i32：整数分辨率表首项（10-26 丝之歌 SwitchPlatform 记录，游戏按它建世界纹理与相机比例）：从首项起连续的 (宽, 宽×9/16) 对，宽是档宽 → scale_w(宽)、高不动
            uint64_t lo = (m->text_end + 0x3FFF) & ~0x3FFFull, hi = m->patch_off >= 0 ? (uint64_t)m->patch_off : m->file_image_len;
            int n = 0; char was[96] = ""; size_t wl = 0;
            uint64_t e = s->off;   // 先量表的范围（与下面逐项判同一条件），与补丁 [data] 重叠就整点让给 [data]
            for (; e >= lo && e + 8 <= hi; e += 8) { uint32_t *p = (uint32_t *)(m->base + e); int c = -1; for (int i = 0; i < 8; i++) if (p[0] == k_cls[i] && p[1] == k_cls[i] * 9u / 16u) c = i; if (c < 0) break; }
            if (e > s->off && s2a_patch_data_overlap(m->name, s->off, e - s->off)) { s2a_patch_note("满屏 %s+%#x i32 表与补丁 [data] 重叠，以 [data] 为准，这点跳过", m->name, s->off); continue; }
            for (uint64_t o = s->off; o >= lo && o + 8 <= hi; o += 8, n++) {
                uint32_t *p = (uint32_t *)(m->base + o); int c = -1;
                for (int i = 0; i < 8; i++) if (p[0] == k_cls[i] && p[1] == k_cls[i] * 9u / 16u) c = i;
                if (c < 0) break;
                if (wl < sizeof was - 16) wl += (size_t)snprintf(was + wl, sizeof was - wl, "%s%u×%u", n ? " " : "", p[0], p[1]);
                p[0] = (uint32_t)scale_w(k_cls[c]);
            }
            if (!n) LOG("【红】宽屏：%s+%#x i32 首项不是 16:9 整数分辨率对（或不在代码段之后的可写范围），未改", m->name, s->off);
            else LOG("宽屏：%s+%#x i32 整数分辨率表 %d 项按屏幕宽放大（%s，宽 %d）", m->name, s->off, n, was, g_W);
        }
        else if (s->kind == 15 && s->on) {   // restab：动态分辨率档位表（11-03 Pokopia main 0x2756530：宽表 34 档紧跟等长高表，960×540 … 1920×1080 … 7680×4320）。
            //   宽表逐档 scale_w、高表逐档 scale_h：宽屏（H = 1080）只改宽、窄屏（W = 1920）只改高；游戏按这张表建全部相对尺寸的缓冲与视口，界面跟着屏幕尺寸排
            uint64_t lo = (m->text_end + 0x3FFF) & ~0x3FFFull, hi = m->patch_off >= 0 ? (uint64_t)m->patch_off : m->file_image_len;
            int n = s->off >= lo ? restab_n(m->base, s->off, hi) : 0;
            if (!n) { LOG("【红】宽屏：%s+%#x restab 不是「宽表紧跟高表、逐档 16:9」的档位表（或不在代码段之后的可写范围），未改", m->name, s->off); continue; }
            if (s2a_patch_data_overlap(m->name, s->off, 8ull * (uint64_t)n)) { s2a_patch_note("满屏 %s+%#x restab 表与补丁 [data] 重叠，以 [data] 为准，这点跳过", m->name, s->off); continue; }
            uint32_t *tw = (uint32_t *)(m->base + s->off), *th = tw + n, w0 = tw[n - 1], h0 = th[n - 1];
            for (int i = 0; i < n; i++) { tw[i] = (uint32_t)scale_w(tw[i]); th[i] = (uint32_t)scale_h(th[i]); }
            LOG("宽屏：%s+%#x restab 档位表 %d 档按屏幕改（末档 %u×%u → %u×%u，屏 %d×%d）", m->name, s->off, n, w0, h0, tw[n - 1], th[n - 1], g_W, g_H);
        }
    }
    g_any = 1; g_on += non;
    LOG("宽屏：%s %d 个点，启用 %d 个，屏幕宽 %d，启用表 %s", m->name, w->n, non, g_W, getenv("S2A_WIDEN_SITES") ? "S2A_WIDEN_SITES" : by_patch ? "补丁" : enable_name());
}
void s2a_widen_load(module_t *m, const char *dir) {
    char path[1100]; snprintf(path, sizeof path, "%s/%s.widen.tsv", dir, m->name);
    FILE *f = fopen(path, "r"); if (f) widen_load_stream(m, dir, path, f);
}
#if defined(__ANDROID__)
void s2a_widen_load_source(module_t *m, const void *bytes, size_t length) {
    for (unsigned i = 0; i < sizeof m->key_idx / sizeof m->key_idx[0]; i++)
        if (m->key_idx[i] >= WSLOT && m->key_idx[i] < WHIT + WMAX)
            die("%s：宽屏槽与线程键重叠", m->name);
    if (!bytes || !length || length > 1024 * 1024 || memchr(bytes, 0, length))
        die("%s：APK 宽屏点表无效", m->name);
    char *copy = malloc(length);
    if (!copy) die("APK 宽屏点表分配失败");
    memcpy(copy, bytes, length);
    FILE *f = fmemopen(copy, length, "r");
    if (!f) die("APK 宽屏点表无法读取");
    widen_load_stream(m, "", m->name, f);
    free(copy);
}
#endif


static void report(module_t *m, wsite_t *s) { if (!__atomic_exchange_n(&s->hit, 1, __ATOMIC_RELAXED)) LOG("[宽] 点 %s+%#x 首次命中（%s）", m->name, s->off, kname(s->kind)); }
// 门：aspdiv / aspstr / lytsz / capsz / seadasp。regs = sw_gate 门帧（x0..x30 @0、q0..q31 @256、[100] = 游戏 sp G，原 sp = G+48，原 x30 在 G+40）
void s2a_widen_gate(int idx, uint64_t *regs, uint64_t orig) {
    module_t *m = module_of((void *)orig); wmod_t *w = m && g_w ? &g_w[m - g_mod] : NULL;
    if (!w || idx < 0 || idx >= w->n) die("宽屏门：%#llx 点序号 %d 无表", (unsigned long long)orig, idx);
    wsite_t *s = &w->s[idx]; report(m, s);
    uint8_t *q = (uint8_t *)regs + 256; uint32_t x = s->word;
    if (s->kind == 3) {   // FDIV Sd, Sn, Sm
        int d = x & 31, n = (x >> 5) & 31, mm = (x >> 16) & 31; float a, b; memcpy(&a, q + 16 * n, 4); memcpy(&b, q + 16 * mm, 4);
        float r = a / b; if (s->on && fabsf(r - 16.0f / 9.0f) < 2e-3f) r = aspect();
        memset(q + 16 * d, 0, 16); memcpy(q + 16 * d, &r, 4);
    } else if (s->kind == 4) {   // STR St, [Xn, #imm12×4]
        int t = x & 31, n = (x >> 5) & 31; uint64_t off = ((x >> 10) & 0xfff) * 4, *g = (uint64_t *)(uintptr_t)regs[100];
        uint64_t base = n == 31 ? (uint64_t)(uintptr_t)(g + 6) : n == 30 ? g[5] : regs[n];
        if (n == 18) die("宽屏门：%s+%#x 基址寄存器是 x18（游戏 x18 在线程槽），未实现", m->name, s->off);
        float r; memcpy(&r, q + 16 * t, 4); if (s->on && fabsf(r - 16.0f / 9.0f) < 2e-3f) r = aspect();
        void s2a_host_write_hook(uint64_t, uint64_t); s2a_host_write_hook(base + off, 4);
        memcpy((void *)(uintptr_t)(base + off), &r, 4);
    } else if (s->kind == 7 || s->kind == 8) {   // LDP Sa, Sb, [Xn, #imm7×4]：照读两个浮点（宽, 高）；启用且是 16:9 档宽高对 → 宽换成 scale_w(宽)，高不动
        // lytsz = 界面布局画布尺寸（按「画布宽 / 2」换算屏幕坐标），capsz = 拷屏控件尺寸；第二层把界面投影放宽到 画布宽·k 后这两处要同样放宽
        int a = x & 31, b = (x >> 10) & 31, n = (x >> 5) & 31; int64_t off = (int64_t)(int32_t)(((x >> 15) & 0x7f) << 25) >> 23, *gs = (int64_t *)(uintptr_t)regs[100];
        if (n == 18) die("宽屏门：%s+%#x 基址寄存器是 x18（游戏 x18 在线程槽），未实现", m->name, s->off);
        uint64_t base = n == 31 ? (uint64_t)(uintptr_t)(gs + 6) : n == 30 ? (uint64_t)gs[5] : regs[n];
        float v[2]; memcpy(v, (const void *)(uintptr_t)(base + (uint64_t)off), 8);
        if (s->on) for (int i = 0; i < 8; i++) if (v[0] == (float)k_cls[i] && v[1] == (float)(k_cls[i] * 9 / 16)) { v[0] = (float)scale_w(k_cls[i]); break; }
        memset(q + 16 * a, 0, 16); memcpy(q + 16 * a, &v[0], 4); memset(q + 16 * b, 0, 16); memcpy(q + 16 * b, &v[1], 4);
    } else if (s->kind == 13) {   // seadasp：sead 透视投影读宽高比（LDR St,[Xn,#imm12×4]，或 LDP Sa,Sb,[Xn,#imm7×4] 第二个是宽高比）：照原指令读；启用且约 16:9 → 屏幕比
        // 10-30 参考 SavageWind（旷野之息原生移植，MIT）tools/patches.py persp_matrix：改读端，所有透视投影（连同由它算出的 CPU 视锥剔除）都跟着变宽；正交投影不读这个字段
        int n = (x >> 5) & 31, pair = (x & 0xFFC00000) == 0x2D400000;
        if (n == 18) die("宽屏门：%s+%#x 基址寄存器是 x18（游戏 x18 在线程槽），未实现", m->name, s->off);
        int64_t *gs = (int64_t *)(uintptr_t)regs[100]; uint64_t base = n == 31 ? (uint64_t)(uintptr_t)(gs + 6) : n == 30 ? (uint64_t)gs[5] : regs[n];
        if (pair) {
            int a = x & 31, b = (x >> 10) & 31; int64_t off = (int64_t)(int32_t)(((x >> 15) & 0x7f) << 25) >> 23;
            float v[2]; memcpy(v, (const void *)(uintptr_t)(base + (uint64_t)off), 8);
            if (s->on && fabsf(v[1] - 16.0f / 9.0f) < 2e-3f) v[1] = aspect();
            memset(q + 16 * a, 0, 16); memcpy(q + 16 * a, &v[0], 4); memset(q + 16 * b, 0, 16); memcpy(q + 16 * b, &v[1], 4);
        } else {
            int t = x & 31; uint64_t off = ((x >> 10) & 0xfff) * 4; float r; memcpy(&r, (const void *)(uintptr_t)(base + off), 4);
            if (s->on && fabsf(r - 16.0f / 9.0f) < 2e-3f) r = aspect();
            memset(q + 16 * t, 0, 16); memcpy(q + 16 * t, &r, 4);
        }
    } else die("宽屏门：%s+%#x 种类 %s 不走门", m->name, s->off, kname(s->kind));
}
// 扫命中槽（跳板点）；收局前也调
void s2a_widen_scan(void) {
    for (int i = 0; g_w && i < g_nmod; i++) { wmod_t *w = &g_w[i];
        for (int j = 0; j < w->n; j++) if ((w->s[j].kind == 1 || w->s[j].kind == 2 || w->s[j].kind == 6 || w->s[j].kind == 11 || w->s[j].kind == 12) && __atomic_load_n(&w->page[WHIT + j], __ATOMIC_RELAXED)) report(&g_mod[i], &w->s[j]); }
}
static void *scanner(void *a) { s2a_thread_name("s2a-widen-scan");
    (void)a;
    while (!atomic_load(&g_scanner_stop)) {
        for (int i = 0; i < 10 && !atomic_load(&g_scanner_stop); i++) usleep(100000);
        if (!atomic_load(&g_scanner_stop)) s2a_widen_scan();
    }
    return NULL;
}
void s2a_widen_start(void) {
    if (!g_any || g_scanner_started) return;
    atomic_store(&g_scanner_stop, 0);
    if (!pthread_create(&g_scanner, NULL, scanner, NULL)) g_scanner_started = 1;
}
int s2a_widen_session_stop(void) {
    atomic_store(&g_scanner_stop, 1);
    if (g_scanner_started) {
        int error = pthread_join(g_scanner, NULL);
        if (error) { LOG("【红】宽屏扫描线程 join 失败：%d", error); return -1; }
        g_scanner_started = 0;
    }
    return 0;
}
int s2a_widen_session_reset(void) {
    if (s2a_widen_session_stop()) return -1;
    for (int i = 0; g_w && i < g_mod_cap; i++) free(g_w[i].s);
    free(g_w); g_w = NULL;
    g_W = 1920; g_H = 1080; g_any = g_on = g_lyt = g_size = g_hsize = 0; g_dir[0] = 0;
    atomic_store(&g_sw, 0); atomic_store(&g_sh, 0); atomic_fetch_add(&g_sgen, 1);
    g_full = g_setting_on = g_ws_yield = -1;
#if defined(__ANDROID__)
    g_android_widen_active = 0;
    for (unsigned i = 0; i < 5; i++) { free(g_android_policy[i]); g_android_policy[i] = NULL; g_android_policy_len[i] = 0; }
    g_android_source = 0;
#endif
    const char *narrow = getenv("S2A_WIDEN_NARROW");
    if (g_default_narrow && narrow && !strcmp(narrow, "1")) unsetenv("S2A_WIDEN_NARROW");
    g_default_narrow = 0;
    return 0;
}
