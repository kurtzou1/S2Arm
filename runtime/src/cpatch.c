// 社区画面补丁运行时开关（直连线 10-27，维护者：宽屏 / 60 帧 / 画面补丁进包，宿主设置里启停；10-30 起玩家包缺省不带上游补丁字节，只有 S2A_COMMUNITY_PATCHES=1 出的内部包有这张表）：出包 pack/cpatch.py plan 写的 cpatch.tsv，
//   每份补丁在本模块占掩码的一位。代码里的改动已由改写器编成双路跳板（读键页槽 2046 的掩码、按位分路，runtime/rewriter/rewriter.c cpatch_rows），
//   这里只做两件事：按开关算掩码写进槽 2046；开着的补丁的数据写入（代码段之后，ro / data）写成补丁值，写前核原值（对不上 = 包与游戏不配套，那份不开）。
// 开关：S2A_CPATCH_ON = 逗号分隔的补丁编号（iOS 由 App 设置 S2ACommunityPatches 转来，ios/settings.m）；none = 全关；不设时按表里「缺省开」（Apple / Android 同口径，#48 D2 维护方定；安卓目前经调试环境通道设 S2A_CPATCH_ON）。下次启动生效
// 帧率类（编号 fps:）另跟 60 帧开关走（帧率能耗线 runtime/src/fps.c 起局与每次切换调 s2a_cpatch_fps_follow；没有我方帧率表的款才收这类，见 pack/cpatch.py）
// 随包表：cpatch.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单；
//   安卓 android/tools/make_pack.py 按安卓改写器出表放进 modules/，APK 起局经资源读面交 s2a_cpatch_load_source）
// 随包表：cheat-src.*.txt
#include <dlfcn.h>
#include "native.h"
#include <errno.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#include <math.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include "s2a_docs.h"
#define CP_SLOT 2046
static _Thread_local FILE *g_boot_file;
void s2a_cpatch_abort_boot_inputs(void) {
    FILE *file = g_boot_file; g_boot_file = NULL;
    if (file && fclose(file)) LOG("【红】失败装载的社区补丁表关闭失败 errno=%d", errno);
}

// 帧率补丁逐份（11-13 维护者：60 / 120 都带进去，玩家自己切档）：模块、掩码槽（模块装载完补上）、位、数据写入（可空）、目标帧率（表第 10 列，0 = 取不到）、
//   allow = 这份能开（安卓只认开关列表里的；iOS 屏蔽的画面类不算）。跟随开关时只开选中档的那几份（fps_pick），其余关位、写回原值
struct cp_fu { module_t *m; _Atomic uint64_t *slot; uint64_t bits; char *spec; int target, allow; char id[48]; };
static struct cp_fu g_fu[256]; static int g_nfu, g_nfud;   // g_nfud：其中带数据写入的份数（上限 64，同原帧率跟随表口径；只改代码的不计）   // 有帧率类补丁的各模块：掩码槽、其中帧率类的位（按需增长，无上限；只在装载时追加）
// 随包表：fpslocker.json
// FPSLocker 帧率配置的运行时部分（pack/fpslocker.py 出、与 cpatch.tsv 同目录）：服务层 services/S2A.Services/FpsLocker.cs 经 s2a_cpatch_tables_dir 找到它
static char g_tables_dir[1024];
const char *s2a_cpatch_tables_dir(void) { return g_tables_dir; }
static _Atomic int g_nfps;   // 设置页可与会话装载 / 释放并发查询
static int g_fps_target;   // 当前选中档的目标帧率（fps_pick 定；s2a_cpatch_fps_follow → fps_link 按它定出图上限与节拍）
static int g_fps_on = -1, g_fps_want;   // 跟随开关的最近状态（-1 = 还没跟随过）；玩家选的档（0 = 没选：默认取不超过屏幕最高刷新率的最高一档）
// 金手指（编号 cheat:，pack/cpatch.py scan_cheats；11-12）：缺省全关、不看 S2A_CPATCH_ON，由服务层金手指线程（services/S2A.Services/Cheats.cs）按玩家开关逐条调 s2a_cpatch_cheat。
//   「位」列是逗号表（共享挂钩按「共用这条改动的条目集合」分位，见 cpatch.py）或「-」（只写填充 / 数据、不占位）。
//   数据写入是各条的开关字（空洞开关表搬到映像结尾的可写区后）：变体（伤害 x2 / x5…）写同一处，每次开关先把关着的写回原值、再按表序写开着的（同 Atmosphere 每帧「主代码清零 → 各条写」）
struct cp_cheat { module_t *m; _Atomic uint64_t *slot; char *file, *name, *spec; uint64_t bits; int on; };
static struct cp_cheat *g_ch; static int g_nch, g_cch;
static pthread_mutex_t g_ch_lock = PTHREAD_MUTEX_INITIALIZER;
int s2a_cpatch_fps_count(void) { return atomic_load(&g_nfps); }
// 自适应画幅（编号 wsauto:<族>:w / :n，pack/cpatch.py adapt_families；11-12 夜）：一族按画幅生成的宽屏补丁合成的宽 / 窄两套模板。开关按族（S2A_CPATCH_ON 里写 wsauto:<族>），
//   当前画幅 A（宽 ÷ 高）比 16:9 宽开宽模板、窄开窄模板、正好 16:9 两份都关；数据写入里「@<式><字节数>」按 A 算（a = A、w = A÷(16/9)、n = (16/9)÷A、i = 1÷A，4 字节单精度 / 8 字节双精度；
//   x = 渲染宽度整数 CP_RES_H × A 取偶，只 4 字节），
//   「k<槽>::@…」写本模块键页的槽（补丁代码从这里读）。A 来自 Mac 窗口像素尺寸（s2a_screen_fit）/ iOS 当前屏（s2a_screen_reaspect）/ S2A_CPATCH_ASPECT；变了当场重写，下一帧生效
void s2a_cpatch_aspect(double A);
struct cp_ad { module_t *m; _Atomic uint64_t *slot; char *spec; int bit, en, on; char side; };
static struct cp_ad *g_ad; static int g_nad, g_cad;
static pthread_mutex_t g_ad_lock = PTHREAD_MUTEX_INITIALIZER;
static double g_aspect = 16.0 / 9.0; static _Atomic int g_ad_on;   // 当前画幅；有份自适应补丁正开着（上屏层据此按画幅铺满）
#define CP_R (16.0 / 9.0)
// 「@x4」= 渲染宽度（整数）：高按手机口径 CP_RES_H（= pack/cpatch.py PHONE_H），宽 = 高 × 当前画幅、取偶（自适应满屏把各份补丁写死的 PC 渲染尺寸统一成这个，11-13）
#define CP_RES_H 1080
static uint32_t cp_res_w_h(double A, int h) { long w = lround(h * A / 2) * 2; return (uint32_t)(w < 2 ? 2 : w > 0xFFFF ? 0xFFFE : w); }
static int ad_want(const struct cp_ad *a, double A) { return a->en && (a->side == 'w' ? A > CP_R * 1.001 : A < CP_R * 0.999); }
// 定画幅的宽屏补丁变体（编号 widescreen:、表第 11 列画幅 > 0；11-13）：同款同模块按画幅出的几份（16:10 / 21:9 / 32:9 / 3:2 …）同点各占一位，
//   开着的几份里只开与当前画幅 A 最接近、且与 A 同在 16:9 一侧的一份（16:9 屏都不开）；位与数据写入由 fx_select 管，A 变了重选。
//   上屏按开着那份的画幅铺满（s2a_cpatch_present_aspect；同自适应画幅「游戏按补丁画幅画世界、出 16:9 尺寸的图」）
struct cp_fx { module_t *m; _Atomic uint64_t *slot; char *spec; char id[40]; double a; int bit, en, on; };
static struct cp_fx *g_fx; static int g_nfx, g_cfx;
static double g_fx_aspect;   // 开着那份的画幅；0 = 没有开着的（g_ad_lock 保护）
// 界面把一款的几份定画幅变体并成一项「满屏补丁（按屏幕比例自动选）」，开关写这个总编号（ios/cpatch_model.m）；单份编号照旧认。状态也按它记一行
#define CP_FX_ALL "widescreen:auto"

// FPS controls and their writer must already be stopped. Only release host
// registrations; the loader restores the next session's pristine module data.
void s2a_cpatch_session_reset(void) {
    g_tables_dir[0] = 0;
    pthread_mutex_lock(&g_ch_lock);
    for (int i = 0; i < g_nch; i++) { free(g_ch[i].file); free(g_ch[i].name); free(g_ch[i].spec); }
    free(g_ch); g_ch = NULL; g_nch = g_cch = 0;
    pthread_mutex_unlock(&g_ch_lock);
    pthread_mutex_lock(&g_ad_lock);
    for (int i = 0; i < g_nad; i++) free(g_ad[i].spec);
    free(g_ad); g_ad = NULL; g_nad = g_cad = 0; atomic_store(&g_ad_on, 0);
    for (int i = 0; i < g_nfx; i++) free(g_fx[i].spec);
    free(g_fx); g_fx = NULL; g_nfx = g_cfx = 0; g_fx_aspect = 0;
    pthread_mutex_unlock(&g_ad_lock);
    for (int i = 0; i < g_nfu; i++) free(g_fu[i].spec);
    memset(g_fu, 0, sizeof g_fu); g_nfu = g_nfud = 0; atomic_store(&g_nfps, 0); g_fps_target = 0; g_fps_on = -1; g_fps_want = 0;
}

static int in_list(const char *list, const char *id) {
    size_t n = strlen(id);
    for (const char *p = list; (p = strstr(p, id)); p += n)
        if ((p == list || p[-1] == ',') && (p[n] == 0 || p[n] == ',')) return 1;
    return 0;
}
static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
// 数据写入「偏移:原字节:新字节」逐段：0 只核完整格式 / 范围 / 原值，1 写新值，2 写回原值。
//   新字节写成「@<式><字节数>」= 按当前画幅算（见上 cp_ad）；偏移写成「k<槽>」（原字节空）= 本模块键页的槽（16–2047），写回原值 = 写 0
// 先用 mode 0 核完整份，再允许写入或登记 follow；不截断长 spec、不在部分校验后写前半份。
int s2a_cpatch_data_writes(module_t *m, const char *spec, int mode);
static int data_writes(module_t *m, const char *spec, int mode) { return s2a_cpatch_data_writes(m, spec, mode); }
// 补丁包 [data] 段（patch_data.c）复用同一写入：范围 = 代码段末页之后到键页前，先 mode 0 全核再 mode 1 写
int s2a_cpatch_data_writes(module_t *m, const char *spec, int mode) {
    for (const char *t = spec; *t; ) {
        if (*t == ' ') { t++; continue; }
        const char *a = strchr(t, ':'), *b = a ? strchr(a + 1, ':') : NULL;
        if (!a || a == t || !b) return -1;
        const char *e = strchr(b + 1, ' '); if (!e) e = b + 1 + strlen(b + 1);
        if (b[1] == '@') {   // 按画幅算的值
            char f = b[2]; int n = atoi(b + 3); double A = g_aspect, v;
            if (!strchr("awnixy", f) || !f || (n != 4 && n != 8) || ((f == 'x' || f == 'y') && n != 4)) return -1;
            int rh = CP_RES_H;   // 「@y4/<高>」：另一档渲染宽 = <高> × 画幅（pack/cpatch.py _fill_other_mode）
            if (f == 'y') { const char *sl = memchr(b + 3, '/', (size_t)(e - (b + 3))); rh = sl ? atoi(sl + 1) : 0; if (rh < 2 || rh > 4096) return -1; }
            v = f == 'a' ? A : f == 'w' ? A / CP_R : f == 'n' ? CP_R / A : (f == 'x' || f == 'y') ? 0 : 1 / A;
            uint8_t nb[8]; if (f == 'x' || f == 'y') { uint32_t w = cp_res_w_h(A, rh); memcpy(nb, &w, 4); } else if (n == 4) { float x = (float)v; memcpy(nb, &x, 4); } else memcpy(nb, &v, 8);
            if (*t == 'k') {
                char *ke; long s = strtol(t + 1, &ke, 10);
                if (ke != a || a + 1 != b || s < 16 || s > 2047 || s == CP_SLOT || (uint64_t)(s + 1) * 8 > m->key_page_size) return -1;
                uint8_t *q = m->base + m->key_page_off + (size_t)s * 8;
                if (mode == 1) { memset(q, 0, 8); memcpy(q, nb, (size_t)n); } else if (mode == 2) memset(q, 0, 8);
                t = e; continue;
            }
            uint64_t off = 0;
            for (const char *p = t; p < a; p++) { int d = hex_digit(*p); if (d < 0 || off > (UINT64_MAX - (unsigned)d) / 16) return -1; off = off * 16 + (unsigned)d; }
            uint64_t low = ((m->text_end + m->load_bias + 0x3fff) & ~0x3fffull) - m->load_bias;
            if ((size_t)(b - a - 1) != (size_t)n * 2 || off < low || off > m->key_page_off || (uint64_t)n > m->key_page_off - off || off > m->size || (uint64_t)n > m->size - off) return -1;
            for (int i = 0; i < n; i++) {
                int oh = hex_digit(a[1 + 2 * i]), ol = hex_digit(a[2 + 2 * i]); if (oh < 0 || ol < 0) return -1;
                uint8_t o = (uint8_t)(oh * 16 + ol);
                if (!mode && m->base[off + i] != o) return -1;
                if (mode) m->base[off + i] = mode == 1 ? nb[i] : o;
            }
            t = e; continue;
        }
        uint64_t off = 0;
        for (const char *p = t; p < a; p++) {
            int v = hex_digit(*p); if (v < 0 || off > (UINT64_MAX - (unsigned)v) / 16) return -1;
            off = off * 16 + (unsigned)v;
        }
        size_t no = (size_t)(b - a - 1), nn = (size_t)(e - b - 1);
        if (!nn || no != nn || nn % 2) return -1;
        nn /= 2;
        // 同 loader.c map_image 的 text 封页边界；键页及其后的补丁区不属于原映像数据。
        uint64_t low = ((m->text_end + m->load_bias + 0x3fff) & ~0x3fffull) - m->load_bias;
        if (off < low || off > m->key_page_off || nn > m->key_page_off - off ||
            off > m->size || nn > m->size - off) return -1;
        for (size_t i = 0; i < nn; i++) {
            int oh = hex_digit(a[1 + 2 * i]), ol = hex_digit(a[2 + 2 * i]);
            int vh = hex_digit(b[1 + 2 * i]), vl = hex_digit(b[2 + 2 * i]);
            if (oh < 0 || ol < 0 || vh < 0 || vl < 0) return -1;
            uint8_t o = (uint8_t)(oh * 16 + ol), v = (uint8_t)(vh * 16 + vl);
            if (!mode && m->base[off + i] != o) return -1;
            if (mode) m->base[off + i] = mode == 1 ? v : o;
        }
        t = e;
    }
    return 0;
}
// 每条社区补丁这一局的实际结果（11-13 维护者：确保打进去的补丁生效、玩家看得见）：<文档根>/cpatch_status.tsv，每行「编号<TAB>状态<TAB>实测」，
//   状态 = 开 / 关 / 不配套（数据格式 / 范围 / 原值与游戏对不上，没写进去）/ 表不认；自适应画幅按族编号。实测 = 运行中按类别量到的效果（s2a_cpatch_effect：
//   帧率补丁的实测帧率、满屏补丁的实测画面比例），没量到空着。界面（iOS 社区补丁页 / 游戏库设置、Mac 启动设置）按它如实显示，开关「开」但没生效的不再显示成开
#define NST 512
static struct { char id[96], st[24], eff[64]; } g_st[NST]; static int g_nst; static pthread_mutex_t g_st_lock = PTHREAD_MUTEX_INITIALIZER;
static void st_flush_locked(void) {
    char p[1100]; if (s2a_docs_path(p, sizeof p, "cpatch_status.tsv") >= (int)sizeof p) return;
    char t[1110]; snprintf(t, sizeof t, "%s.tmp", p); FILE *f = fopen(t, "w"); if (!f) return;
    for (int i = 0; i < g_nst; i++) fprintf(f, "%s\t%s\t%s\n", g_st[i].id, g_st[i].st, g_st[i].eff);
    if (fclose(f) == 0) rename(t, p); else unlink(t);
}
static void st_put(const char *id, const char *st) {
    pthread_mutex_lock(&g_st_lock);
    int i = 0; while (i < g_nst && strcmp(g_st[i].id, id)) i++;
    if (i == g_nst && g_nst < NST) { snprintf(g_st[i].id, sizeof g_st[i].id, "%s", id); g_st[i].eff[0] = 0; g_nst++; }
    if (i < g_nst) snprintf(g_st[i].st, sizeof g_st[i].st, "%s", st);
    pthread_mutex_unlock(&g_st_lock);
}
// 运行中量到的效果（帧率 / 画面比例），写给这一类里状态为「开」的补丁（kind = "fps:" / "widescreen:" 前缀；自适应画幅族 wsauto: 归满屏）
void s2a_cpatch_effect(const char *kind, const char *text) {
    pthread_mutex_lock(&g_st_lock);
    int any = 0;
    for (int i = 0; i < g_nst; i++) {
        int hit = !strncmp(g_st[i].id, kind, strlen(kind)) || (!strcmp(kind, "widescreen:") && !strncmp(g_st[i].id, "wsauto:", 7));
        if (hit && !strcmp(g_st[i].st, "开") && strcmp(g_st[i].eff, text)) { snprintf(g_st[i].eff, sizeof g_st[i].eff, "%s", text); any = 1; }
    }
    if (any) st_flush_locked();
    pthread_mutex_unlock(&g_st_lock);
}
int s2a_cpatch_has_on(const char *kind) {   // 这一类有没有开着的社区补丁（量效果的一方据此决定量不量）
    pthread_mutex_lock(&g_st_lock); int r = 0;
    for (int i = 0; i < g_nst && !r; i++) r = !strcmp(g_st[i].st, "开") && (!strncmp(g_st[i].id, kind, strlen(kind)) || (!strcmp(kind, "widescreen:") && !strncmp(g_st[i].id, "wsauto:", 7)));
    pthread_mutex_unlock(&g_st_lock); return r;
}
// 运行中量效果（11-13 维护者：确保打进去的补丁真的生效）：直连上屏每帧经 s2a_qp_frame（runtime/src/qprompt_host.c）调，game = 这一帧是局内游戏画面。
//   30 秒一窗（只算局内帧）：帧率补丁开着 → 实测帧率 fps=<n>；满屏 / 自适应画幅补丁开着 → 看上屏满屏判据（graphics/nvn/gfx/nvn/nvn_mtl.m mtl_fit_last，
//   0 正常 / 1–3 黑带 / 接缝 / 暗带）这一窗的判定：有判定且都正常 = aspect=<画幅>（没有画幅数就 fill=ok），多数没铺满 = unfilled。判定不够（没开判据 / 都是免判）不写
__attribute__((weak)) int mtl_fit_last(uint64_t *seq, uint64_t *present_n) { (void)seq; (void)present_n; return 5; }   // 没链直连上屏（Mac 通用模式 / 单测）：一律免判
double s2a_cpatch_present_aspect(void);
void s2a_cpatch_frame(uint64_t now, int game, uint64_t dt) {
    static uint64_t t0, fseq; static unsigned frames, ok, bad;
    if (!game || !dt || dt > 500000000ull) return;   // 菜单 / 过场 / 卡顿间隔不算
    if (!t0) t0 = now;
    frames++;
    uint64_t seq; int k = mtl_fit_last(&seq, NULL);
    if (seq != fseq) { fseq = seq; if (k == 0) ok++; else if (k >= 1 && k <= 3) bad++; }
    if (now - t0 < 30000000000ull) return;
    double secs = (double)(now - t0) / 1e9; char v[48];
    if (s2a_cpatch_has_on("fps:")) { snprintf(v, sizeof v, "fps=%d", (int)(frames / secs + 0.5)); s2a_cpatch_effect("fps:", v); }
    if (s2a_cpatch_has_on("widescreen:") && ok + bad >= 3) {
        double A = s2a_cpatch_present_aspect();
        if (bad * 2 > ok + bad) snprintf(v, sizeof v, "unfilled");
        else if (!bad && A > 0.2) snprintf(v, sizeof v, "aspect=%.1f:9", A * 9);
        else if (!bad) snprintf(v, sizeof v, "fill=ok");
        else v[0] = 0;
        if (v[0]) s2a_cpatch_effect("widescreen:", v);
    }
    t0 = now; frames = ok = bad = 0;
}
static int cp_ios_blocked(const char *id) {   // iOS 上不开的类：画面类（见上面 en 的说明）
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return !strncmp(id, "gfx:", 4);
#else
    (void)id; return 0;
#endif
}
// 随包金手指原文（11-13，见文件头 cheat-src 那行声明）：出包把版本对得上的金手指 txt 以 cheat-src.<原文件名> 放进 App（pack/cpatch.py CHEAT_SHIP），
//   这里放进这款文档根 cheats/<原文件名>——iPhone 金手指页（ios/game_options.m）与服务层 Cheats.cs 只读那里。没有的照放；已有的只在是上次随包放的
//   （cheats/.packed 记了名字）且内容变了时换新，玩家自己导入的同名文件不碰。Mac 读游戏文件夹 cheats/（启动器管），不走这里
#define CHEAT_SHIP "cheat-src."
static void seed_cheats(const char *dir) {
#if TARGET_OS_IPHONE
    DIR *dp = opendir(dir); if (!dp) return;
    char cd[1024], rec[1100], have[8192] = "";
    if (s2a_docs_path(cd, sizeof cd, "cheats") >= (int)sizeof cd) { closedir(dp); return; }
    mkdir(cd, 0755); snprintf(rec, sizeof rec, "%s/.packed", cd);
    FILE *rf = fopen(rec, "r"); if (rf) { size_t k = fread(have, 1, sizeof have - 1, rf); have[k] = 0; fclose(rf); }
    char list[8192] = ""; int n = 0; struct dirent *e;
    while ((e = readdir(dp))) {
        const char *nm = e->d_name; size_t pl = strlen(CHEAT_SHIP);
        if (strncmp(nm, CHEAT_SHIP, pl) || !nm[pl] || strchr(nm + pl, '/')) continue;
        const char *dn = nm + pl; char src[1100], dst[1100], tmp[1110];
        snprintf(src, sizeof src, "%s/%s", dir, nm); snprintf(dst, sizeof dst, "%s/%s", cd, dn); snprintf(tmp, sizeof tmp, "%s.tmp", dst);
        char key[300]; snprintf(key, sizeof key, "\n%s\n", dn); char wrapped[8200]; snprintf(wrapped, sizeof wrapped, "\n%s", have);
        int ours = strstr(wrapped, key) != NULL, exists = access(dst, F_OK) == 0;
        if (exists && !ours) { LOG("金手指：%s 是玩家自己放的，随包那份不覆盖", dn); continue; }
        if (strlen(list) + strlen(dn) + 2 < sizeof list) { strcat(list, dn); strcat(list, "\n"); }   // 只记随包放的（玩家的同名文件以后也不碰）
        FILE *in = fopen(src, "rb"); if (!in) continue;
        static char buf[4 << 20]; size_t len = fread(buf, 1, sizeof buf, in); fclose(in);
        if (exists) {   // 内容一样就不写（不改时间：Cheats.cs 按改动时间重载）
            FILE *o = fopen(dst, "rb"); static char cur[4 << 20]; size_t cl = o ? fread(cur, 1, sizeof cur, o) : (size_t)-1; if (o) fclose(o);
            if (cl == len && !memcmp(cur, buf, len)) continue;
        }
        FILE *o = fopen(tmp, "wb"); if (!o) continue;
        int ok = fwrite(buf, 1, len, o) == len; ok &= fclose(o) == 0;
        if (ok && rename(tmp, dst) == 0) { n++; LOG("金手指：随包原文 %s 放进文档根 cheats/", dn); } else unlink(tmp);
    }
    closedir(dp);
    if (strcmp(list, have)) { FILE *w = fopen(rec, "w"); if (w) { fputs(list, w); fclose(w); } }
    (void)n;
#else
    (void)dir;
#endif
}

// 一个模块按表装载：f 由调用方打开（目录装载 = 模块目录的 cpatch.tsv；APK 起局 = 已验签的内存表），这里读完关掉
static void cpatch_load_stream(module_t *m, FILE *f) {
    g_boot_file = f;
    const char *on = getenv("S2A_CPATCH_ON");
    uint64_t mask = 0; int n = 0, cheat_mods = 0, ch0 = g_nch, fu0 = g_nfu;
    static char line[1 << 16];
    if (!fgets(line, sizeof line, f)) { fclose(f); g_boot_file = NULL; return; }   // 表头
    while (fgets(line, sizeof line, f)) {
        if (!strchr(line, '\n') && !feof(f)) {   // 不能把截断的前半行当完整份准入
            int ch; while ((ch = fgetc(f)) != '\n' && ch != EOF) {}
            LOG("【红】社区补丁 %s：表行过长，不开", m->name); continue;
        }
        line[strcspn(line, "\r\n")] = 0;
        char *c[11] = {0}; char *s = line; for (int i = 0; i < 11 && s; i++) { c[i] = s; s = strchr(s, '\t'); if (s) *s++ = 0; }   // 第 10 列目标帧率、第 11 列画幅（pack/cpatch.py，旧表没有）
        if (!c[8] || strcmp(c[1], m->name)) continue;
        char *end; long bit = strtol(c[2], &end, 10);
        // 玩家没选过（没有 S2A_CPATCH_ON）= 默认开（11-13 维护者：S 级优化命中的补丁出包时打入并默认开，用户少做选择）；表里「缺省开」列现在只表示我方验过（界面标签）。
        //   画面类（gfx:，提分辨率 / 画质）在 iOS 上一律不开（维护者：iOS 默认不打——手机内存更紧，Switch 上没事的提分辨率可能被系统杀），Mac 照常默认开
        int en = cp_ios_blocked(c[0]) ? 0 : on ? (strcmp(on, "none") && in_list(on, c[0])) : 1, fps = !strncmp(c[0], "fps:", 4);
        n++;
        // 帧率补丁里最高的目标帧率（s2a_cpatch_fps_follow 按它定出图上限、出图节拍与服务层 vsync）。帧率类的开关位本来就跟 60 帧开关走、不看开关列表，
        //   目标却原先只从列表里的取：iOS 设置页把帧率补丁做成 60 帧开关的联动、从不写进 S2ACommunityPatches，玩家动过任何一个补丁开关后目标就是 0，
        //   补丁照开、节拍不放（11-13 实机：列表只有 widescreen:auto → 「sdk fps:… 关」、present tick 60 Hz）
        if (!strncmp(c[0], "wsauto:", 7)) {   // 自适应画幅：开关按族（去掉末尾 :w / :n），登记后按当前画幅开其一（见 ad_apply）
            char fam[96]; char *sd = strrchr(c[0], ':');
            if (!sd || (sd[1] != 'w' && sd[1] != 'n') || sd[2] || (size_t)(sd - c[0]) >= sizeof fam || c[2][0] < '0' || c[2][0] > '9' || *end || bit < 0 || bit >= 64) {
                LOG("【红】社区补丁 %s %s：自适应画幅行不认，不开", m->name, c[0]); st_put(c[0], "表不认"); continue; }
            memcpy(fam, c[0], (size_t)(sd - c[0])); fam[sd - c[0]] = 0;
            int fen = on ? (strcmp(on, "none") && (in_list(on, fam) || in_list(on, c[0]))) : 1;   // 同上：没选过 = 开
            if (c[7][0] && data_writes(m, c[7], 0)) { LOG("【红】社区补丁 %s %s：数据格式 / 范围 / 原值不符（包与游戏不配套），不开", m->name, c[0]); st_put(fam, "不配套"); continue; }
            st_put(fam, fen ? "开" : "关");
            pthread_mutex_lock(&g_ad_lock);
            if (g_nad == g_cad) { int nc = g_cad ? g_cad * 2 : 8; struct cp_ad *q = realloc(g_ad, (size_t)nc * sizeof *q); if (!q) die("自适应画幅表分配失败"); g_ad = q; g_cad = nc; }
            struct cp_ad *ad = &g_ad[g_nad++]; ad->m = m; ad->slot = NULL; ad->spec = strdup(c[7]); ad->bit = (int)bit; ad->en = fen; ad->on = 0; ad->side = sd[1];
            if (!ad->spec) die("自适应画幅表项分配失败");
            pthread_mutex_unlock(&g_ad_lock);
            LOG("社区补丁：%s %s（%s · 许可 %s）%s，按画幅开宽 / 窄模板", m->name, c[0], c[4], c[5][0] ? c[5] : "未声明", fen ? "开" : "关");
            continue;
        }
        if (!strncmp(c[0], "cheat:", 6)) {   // 金手指：只登记（核位表与原值），开关等金手指线程
            uint64_t bits = 0; int ok = 1;
            if (strcmp(c[2], "-"))
                for (char *q = c[2]; ok; q = end + 1) {
                    long b = strtol(q, &end, 10);
                    if (end == q || b < 0 || b >= 64 || (*end && *end != ',')) ok = 0; else bits |= 1ull << b;
                    if (!*end) break;
                }
            if (!ok) { LOG("【红】金手指 %s %s：位表「%s」不认，不收", m->name, c[0], c[2]); continue; }
            if (c[7][0] && data_writes(m, c[7], 0)) { LOG("【红】金手指 %s %s：数据格式 / 范围 / 原值不符（包与游戏不配套），不收", m->name, c[0]); continue; }
            if (g_nch == g_cch) {
                int nc = g_cch ? g_cch * 2 : 32; struct cp_cheat *q = realloc(g_ch, (size_t)nc * sizeof *q);
                if (!q) die("金手指表 %d 项分配失败", nc);
                g_ch = q; g_cch = nc;
            }
            struct cp_cheat *h = &g_ch[g_nch++];
            h->m = m; h->slot = NULL; h->bits = bits; h->on = 0;
            h->file = strdup(c[6]); h->name = strdup(c[4]); h->spec = strdup(c[7]);
            if (!h->file || !h->name || !h->spec) die("金手指表项分配失败");
            cheat_mods++;
            continue;
        }
        if (c[2][0] < '0' || c[2][0] > '9' || *end || bit < 0 || bit >= 64) {
            LOG("【红】社区补丁 %s %s：位编号不在 0–63，不开", m->name, c[0]); st_put(c[0], "表不认"); continue;
        }
        double fa = !strncmp(c[0], "widescreen:", 11) && c[10] ? atof(c[10]) : 0;   // 定画幅变体（见 cp_fx）
        if ((fps || en || fa > 0) && c[7][0] && data_writes(m, c[7], 0)) {
            LOG("【红】社区补丁 %s %s：数据格式 / 范围 / 原值不符（包与游戏不配套），不开", m->name, c[0]); st_put(c[0], "不配套"); continue;
        }
        if (fa > 0.2 && fa < 8) {   // 只登记，按画幅选开哪份（装载末尾 / 换屏时 fx_select）
            pthread_mutex_lock(&g_ad_lock);
            if (g_nfx == g_cfx) { int nc = g_cfx ? g_cfx * 2 : 8; struct cp_fx *q = realloc(g_fx, (size_t)nc * sizeof *q); if (!q) die("宽屏变体表分配失败"); g_fx = q; g_cfx = nc; }
            struct cp_fx *x = &g_fx[g_nfx++]; memset(x, 0, sizeof *x); x->m = m; x->spec = strdup(c[7]); x->a = fa; x->bit = (int)bit;
            x->en = on ? (strcmp(on, "none") && (in_list(on, c[0]) || in_list(on, CP_FX_ALL))) : 1;   // 没选过 = 开（同上）
            snprintf(x->id, sizeof x->id, "%s", c[0]);
            if (!x->spec) die("宽屏变体表项分配失败");
            pthread_mutex_unlock(&g_ad_lock);
            st_put(c[0], "关");
            LOG("社区补丁：%s %s（%s · 画幅 %.3f · 许可 %s）%s，按当前画幅选开", m->name, c[0], c[4], fa, c[5][0] ? c[5] : "未声明", x->en ? "候选" : "关");
            continue;
        }
        if (fps) {
            if (g_nfu >= (int)(sizeof g_fu / sizeof g_fu[0]) || (c[7][0] && g_nfud >= 64)) {
                LOG("【红】社区补丁 %s %s：帧率跟随表容量已满，整份不开", m->name, c[0]); st_put(c[0], "表不认"); continue;
            }
            struct cp_fu *u = &g_fu[g_nfu++]; memset(u, 0, sizeof *u);
            u->m = m; u->bits = 1ull << bit; u->target = c[9] ? atoi(c[9]) : 0; u->allow = !cp_ios_blocked(c[0]);
            snprintf(u->id, sizeof u->id, "%s", c[0]);
            if (c[7][0] && !(u->spec = strdup(c[7]))) die("社区帧率补丁数据分配失败");
            if (c[7][0]) g_nfud++;
            atomic_fetch_add(&g_nfps, 1);
            st_put(c[0], "关");   // 开关由 s2a_cpatch_fps_follow 定（按档只开选中的那几份）
        }
        // 帧率类装载时只登记、不写不开（11-13：几档改同一处，先写一份另一份的原值校验就不过）；位与数据由 s2a_cpatch_fps_follow 按档定（fps.c 起局调一次）
        if (en && !fps && c[7][0] && data_writes(m, c[7], 1)) die("社区补丁已校验的数据写入失败");
        if (en && !fps) mask |= 1ull << bit;
        LOG("社区补丁：%s %s（%s · %s · 许可 %s）%s", m->name, c[0], c[3], c[4], c[5][0] ? c[5] : "未声明", en ? "开" : "关");
        if (!fps) st_put(c[0], en ? "开" : "关");   // 帧率类跟 60 帧开关（s2a_cpatch_fps_follow 定开关时记）
    }
    fclose(f); g_boot_file = NULL;
    pthread_mutex_lock(&g_st_lock); if (g_nst) st_flush_locked(); pthread_mutex_unlock(&g_st_lock);
    if (!n) return;
    uint8_t *page = m->base + m->key_page_off;   // 键页（宽屏点同样把它改成可写：命中槽要写）
    if (mprotect(page, m->key_page_size, PROT_READ | PROT_WRITE)) die("%s 键页改可写失败（社区补丁槽）", m->name);
    ((uint64_t *)page)[CP_SLOT] = mask;
    for (int i = ch0; i < g_nch; i++) g_ch[i].slot = (_Atomic uint64_t *)((uint64_t *)page + CP_SLOT);
    pthread_mutex_lock(&g_ad_lock);
    int nad = 0;
    for (int i = 0; i < g_nad; i++) if (g_ad[i].m == m && !g_ad[i].slot) { g_ad[i].slot = (_Atomic uint64_t *)((uint64_t *)page + CP_SLOT); nad++; }
    for (int i = 0; i < g_nfx; i++) if (g_fx[i].m == m && !g_fx[i].slot) { g_fx[i].slot = (_Atomic uint64_t *)((uint64_t *)page + CP_SLOT); nad++; }
    pthread_mutex_unlock(&g_ad_lock);
    if (nad) {
        const char *e = getenv("S2A_CPATCH_ASPECT"); double A = e ? atof(e) : 0;
#if defined(__APPLE__) && TARGET_OS_IPHONE
        int s2a_ios_screen_h(void); double s2a_ios_screen_aspect(void);   // widen.c：当前屏宽高比（口径见那里）
        if (!(A > 0) && s2a_ios_screen_h() > 0) A = s2a_ios_screen_aspect();
#endif
        s2a_cpatch_aspect(A > 0 ? A : g_aspect);
    }
    if (cheat_mods) LOG("金手指：%s 编进包 %d 条（缺省关，局内逐条开关）", m->name, cheat_mods);
    for (int i = fu0; i < g_nfu; i++) g_fu[i].slot = (_Atomic uint64_t *)((uint64_t *)page + CP_SLOT);
}
void s2a_cpatch_load(module_t *m, const char *dir) {
    if (!g_tables_dir[0] && dir) { snprintf(g_tables_dir, sizeof g_tables_dir, "%s", dir); seed_cheats(dir); }   // 主程序（第一个装载的模块）的表目录
    char p[1100]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "r"); if (!f) return;
    cpatch_load_stream(m, f);
}
// APK 起局（loader.c load_modules_from_source）：表与模块旁车同经已验签的 APK 资源读面读进内存，每个模块各按表装一遍。
//   表进了包却读不到 / 读坏 = 包有问题，报红中止（同 s2a_widen_load_source）；没有这张表的包由调用方跳过
void s2a_cpatch_load_source(module_t *m, const void *bytes, size_t length) {
    if (!bytes || !length || length > 16 * 1024 * 1024 || memchr(bytes, 0, length)) die("%s：APK 社区补丁表无效", m->name);
    FILE *f = fmemopen((void *)(uintptr_t)bytes, length, "r");   // 只读打开，不写回调用方的租约内存
    if (!f) die("APK 社区补丁表无法读取 errno=%d", errno);
    cpatch_load_stream(m, f);
}
// 定画幅变体按画幅 A 选（持 g_ad_lock）：开着的几份里取与 A 同在 16:9 一侧、log 比值最近的一份；先关不该开的（写回原值、清位）再开选中的
static void fx_select(double A) {
    int best = -1; double bd = 0;
    for (int i = 0; i < g_nfx; i++) {
        struct cp_fx *x = &g_fx[i];
        if (!x->slot || !x->en || !(A > CP_R * 1.001 ? x->a > CP_R * 1.001 : A < CP_R * 0.999 ? x->a < CP_R * 0.999 : 0)) continue;
        double d = fabs(log(x->a / A)); if (best < 0 || d < bd) { best = i; bd = d; }
    }
    for (int i = 0; i < g_nfx; i++) {
        struct cp_fx *x = &g_fx[i]; if (i == best || !x->on) continue;
        if (x->spec[0] && data_writes(x->m, x->spec, 2)) die("宽屏变体已校验的数据写回失败");
        atomic_fetch_and(x->slot, ~(1ull << x->bit)); x->on = 0; st_put(x->id, "关");
        LOG("社区补丁：%s 宽屏变体 %s（画幅 %.3f）关（当前画幅 %.3f）", x->m->name, x->id, x->a, A);
    }
    g_fx_aspect = 0;
    if (g_nfx) st_put(CP_FX_ALL, best >= 0 ? "开" : "关");
    if (best >= 0) {
        struct cp_fx *x = &g_fx[best]; g_fx_aspect = x->a;
        if (!x->on) {
            if (x->spec[0] && data_writes(x->m, x->spec, 1)) die("宽屏变体已校验的数据写入失败");
            atomic_fetch_or(x->slot, 1ull << x->bit); x->on = 1; st_put(x->id, "开");
            LOG("社区补丁：%s 宽屏变体 %s（画幅 %.3f）开，当前画幅 %.3f 最近", x->m->name, x->id, x->a, A);
        }
    }
    pthread_mutex_lock(&g_st_lock); if (g_nst) st_flush_locked(); pthread_mutex_unlock(&g_st_lock);
}
// 当前画幅变了（Mac 窗口改尺寸 / 全屏、iOS 换屏、装载时）：各自适应画幅补丁按新画幅选模板、重算值。先关掉不该开的（写回原值、清位），再开 / 重写该开的
void s2a_cpatch_aspect(double A) {
    if (!(A > 0.2 && A < 8)) return;
    pthread_mutex_lock(&g_ad_lock);
    int changed = fabs(A - g_aspect) > 1e-4; g_aspect = A; int any = 0;
    for (int i = 0; i < g_nad; i++) {
        struct cp_ad *a = &g_ad[i]; if (!a->slot || ad_want(a, A) || !a->on) continue;
        if (a->spec[0] && data_writes(a->m, a->spec, 2)) die("自适应画幅已校验的数据写回失败");
        atomic_fetch_and(a->slot, ~(1ull << a->bit)); a->on = 0;
        LOG("社区补丁：%s 自适应画幅 %s 模板关（画幅 %.3f）", a->m->name, a->side == 'w' ? "宽" : "窄", A);
    }
    for (int i = 0; i < g_nad; i++) {
        struct cp_ad *a = &g_ad[i]; if (!a->slot || !ad_want(a, A)) continue;
        if (a->on && !changed) { any = 1; continue; }
        if (a->spec[0] && data_writes(a->m, a->spec, 1)) die("自适应画幅已校验的数据写入失败");
        if (!a->on) LOG("社区补丁：%s 自适应画幅 %s 模板开（画幅 %.3f）", a->m->name, a->side == 'w' ? "宽" : "窄", A);
        atomic_fetch_or(a->slot, 1ull << a->bit); a->on = 1; any = 1;
    }
    atomic_store(&g_ad_on, any);
    fx_select(A);
    pthread_mutex_unlock(&g_ad_lock);
}
// 上屏层（graphics/nvn/gfx/nvn/nvn_mtl.m present）：有份自适应画幅补丁开着 = 游戏按当前画幅画世界、出的仍是 16:9 尺寸的图，要拉满窗口 / 屏幕（社区宽屏补丁的前提「拉伸到窗口」）；
//   回当前画幅，没开 → 0（照旧等比留边）
double s2a_cpatch_present_aspect(void) {
    if (atomic_load(&g_ad_on)) return g_aspect;
    pthread_mutex_lock(&g_ad_lock); double a = g_fx_aspect; pthread_mutex_unlock(&g_ad_lock);   // 定画幅变体开着：按它的画幅铺满（屏幕比例不同处留窄边，不变形）
    return a;
}
// 本款有没有开着的社区宽屏类补丁（widescreen: / wsauto:）——补丁优先（11-13 维护者「满画幅是一样的」）：有就让我方满屏整体让位（runtime/src/widen.c widen_setting_on），
//   不拉宽两次。装载前就要答（屏幕宽在装载早期就读），所以直接读表目录的 cpatch.tsv，按与 s2a_cpatch_load 同一开关口径（S2A_CPATCH_ON；没选过 = 开，Apple / Android 同口径）
// need_docked = 1：只数「只改了主机档渲染尺寸」的满屏补丁（第 12 列模式 docked；定画幅 widescreen: 一律算——没参数化、管不了另一档）。
//   自适应满屏两档都补齐（both）或不涉渲染尺寸（空）的不算：运行模式归玩家（11-09 规矩），不替玩家切主机（host_main.c）
static int ws_scan(const char *dir, int need_docked);
int s2a_cpatch_ws_enabled(const char *dir) { return ws_scan(dir, 0); }
int s2a_cpatch_ws_needs_docked(const char *dir) { return ws_scan(dir, 1); }
static int ws_scan(const char *dir, int need_docked) {
    if (!dir || !dir[0]) return 0;
    const char *on = getenv("S2A_CPATCH_ON");
    if (on && !strcmp(on, "none")) return 0;
    char p[1100]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "r"); if (!f) return 0;
    static char line[1 << 16]; int hit = 0;
    while (!hit && fgets(line, sizeof line, f)) {
        char *c[12] = {0}; char *s = line; for (int i = 0; i < 12 && s; i++) { c[i] = s; s = strchr(s, '\t'); if (s) *s++ = 0; }
        if (!c[1]) continue;
        if (strncmp(line, "widescreen:", 11) && strncmp(line, "wsauto:", 7)) continue;
        if (need_docked && !strncmp(line, "wsauto:", 7) && !(c[11] && !strncmp(c[11], "docked", 6))) continue;
        char fam[96]; snprintf(fam, sizeof fam, "%s", line); char *sd = strrchr(fam, ':'); if (!strncmp(line, "wsauto:", 7) && sd) *sd = 0;
        hit = !on || in_list(on, line) || in_list(on, fam) || (!strncmp(line, "widescreen:", 11) && in_list(on, CP_FX_ALL));
    }
    fclose(f); return hit;
}
// 60 帧开关（fps.c 起局一次、运行中每次切换调）：帧率类各位一起置开 / 关；它们的数据写入写补丁值 / 写回原值（原值在装载时核过）
// 补丁优先（11-13 维护者：有 120 帧补丁就盖过我们的 60 帧，有 60 帧补丁就盖过我们自己的 60 帧，满屏同理）：帧率补丁开着、目标高于 60 时，
//   出图链改 60–120 Hz（graphics/nvn/gfx/nvn/nvn_mtl.m link_range 模式 2；每帧 link_sync 按 g_dm_present_link 对齐，局中切换也即时生效），
//   游戏解了帧率锁后按屏幕的高刷出图；屏幕只有 60 Hz 时系统给 60。关掉帧率补丁回到 60 Hz（模式 1）。启动环境显式给了 DM_PRESENT_LINK 的不动（对照局）
static int tgt(const struct cp_fu *u);
static void fps_link(int on) {   // on = 选中档高于 60（开高刷）；包里有高于 60 的档才归补丁管出图链与节拍，关 / 选回 60 档时退回 60 Hz
    int hi = 0; for (int i = 0; i < g_nfu; i++) if (g_fu[i].allow && tgt(&g_fu[i]) > hi) hi = tgt(&g_fu[i]);
    if (hi <= 60 || getenv("S2A_PRESENT_LINK_USER")) return;
    const char *pin = getenv("DM_PRESENT_LINK");
    static int owned = -1; if (owned < 0) owned = !pin;   // 第一次进来时启动环境没给，才归补丁管
    if (!owned) return;
    setenv("DM_PRESENT_LINK", on ? "2" : "1", 1);   // 图形层还没初始化：mtl_init 读环境
    int *pl = (int *)dlsym(RTLD_DEFAULT, "g_dm_present_link");   // 直连图形层（nvn_mtl.m）已初始化：直接改，下一帧 link_sync 对齐；不链直连层的构建 / 单测里没有
    if (pl) *pl = on ? 2 : 1;
    // 出图节拍（模拟给游戏的垂直同步，graphics/nvn/gfx/nvn/hle_nvn.c present_cfg，缺省 60 Hz）也要跟上：游戏设间隔 1 时每拍出一帧，节拍不放开，
    //   只放开显示链游戏照样只出 60 帧（11-13 维护者实机：一款游戏开 120 帧补丁仍 60 帧，日志「present tick 60 Hz」）。启动环境显式给了 DM_PRESENT_HZ 的不动
    static int hz_owned = -1; if (hz_owned < 0) hz_owned = !getenv("DM_PRESENT_HZ");
    if (hz_owned) {
        int hz = on ? (g_fps_target > 120 ? 120 : g_fps_target) : 60; char v[8]; snprintf(v, sizeof v, "%d", hz);
        setenv("DM_PRESENT_HZ", v, 1);   // 图形层还没定节拍：起局读环境
        void (*ph)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "nvn_present_hz"); if (ph) ph(hz);   // 已定（局中切换）：直接改
    }
    LOG("社区补丁：帧率补丁目标 %d 帧，%s", g_fps_target, on ? "出图链放开到 60–120 Hz、出图节拍跟到补丁目标（补丁优先，盖过我方 60 帧）" : "关了，出图链与出图节拍回 60 Hz");
}
// 选档（11-13 维护者：60 / 120 都带进去，玩家自己切）：能开的各份里，玩家选了档（S2A_FPS_PICK / s2a_cpatch_fps_pick）就取它，没有这一档取不超过它的最高一档；
//   没选取不超过屏幕最高刷新率的最高一档（120 Hz 屏开 120、60 Hz 屏开 60）；都超过就取最低一档。取不到目标的（0）当 60 档。→ 选中的目标帧率；没有能开的 → 0
__attribute__((weak)) int front_screen_max_fps(void) { return 0; }   // macos/front_mac.m 强定义（只 Mac 宿主有）；单测 / iOS 用这个弱的（0 = 不知道，按 60）
#if defined(__APPLE__) && TARGET_OS_IPHONE
int s2a_ios_screen_max_fps(void);
#endif
static int screen_max_hz(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return s2a_ios_screen_max_fps();
#else
    int v = front_screen_max_fps(); return v > 0 ? v : 60;
#endif
}
static int tgt(const struct cp_fu *u) { return u->target > 0 ? u->target : 60; }
static int fps_pick(void) {
    int want = g_fps_want;
    if (!want) { const char *e = getenv("S2A_FPS_PICK"); want = e ? atoi(e) : 0; }
    int cap = want > 0 ? want : screen_max_hz(), best = 0, low = 0;
    for (int i = 0; i < g_nfu; i++) {
        if (!g_fu[i].allow || !g_fu[i].slot) continue;
        int t = tgt(&g_fu[i]);
        if (t <= cap && t > best) best = t;
        if (!low || t < low) low = t;
    }
    return best ? best : low;
}
// 可选档位（设置页列「帧率」档用）：能开的各份的目标帧率，去重升序写进 out（最多 n 个）→ 个数；cur 填当前选中档（没跟随过按默认算）
int s2a_cpatch_fps_levels(int *out, int n, int *cur) {
    int k = 0;
    for (int i = 0; i < g_nfu; i++) {
        if (!g_fu[i].allow) continue;
        int t = tgt(&g_fu[i]), j = 0;
        while (j < k && out[j] < t) j++;
        if (j < k && out[j] == t) continue;
        if (k < n) { memmove(out + j + 1, out + j, (size_t)(k - j) * sizeof *out); out[j] = t; k++; }
    }
    if (cur) *cur = g_fps_on > 0 ? g_fps_target : fps_pick();
    return k;
}
void s2a_cpatch_fps_follow(int on) {
    g_fps_on = on;
    int pick = on ? fps_pick() : 0;
    g_fps_target = pick;
    fps_link(on && pick > 60);
    for (int i = 0; i < g_nfu; i++) {   // 先关不选的（写回原值、清位），再开选中的：几档改同一处，顺序不能反
        struct cp_fu *u = &g_fu[i];
        if (!u->slot || (on && u->allow && tgt(u) == pick)) continue;
        atomic_fetch_and(u->slot, ~u->bits);
        if (u->spec && data_writes(u->m, u->spec, 2)) die("社区帧率补丁已准入的数据写入失败");
    }
    for (int i = 0; on && i < g_nfu; i++) {
        struct cp_fu *u = &g_fu[i];
        if (!u->slot || !u->allow || tgt(u) != pick) continue;
        if (u->spec && data_writes(u->m, u->spec, 1)) die("社区帧率补丁已准入的数据写入失败");
        atomic_fetch_or(u->slot, u->bits);
    }
    if (g_nfu) LOG("社区补丁：帧率类 %d 份，%s", g_nfps, on && pick ? "" : "全关");
    if (g_nfu && on && pick) LOG("社区补丁：帧率档 %d 帧（%s；屏幕最高 %d Hz）", pick, g_fps_want || getenv("S2A_FPS_PICK") ? "玩家选的" : "默认：不超过屏幕刷新率的最高一档", screen_max_hz());
    pthread_mutex_lock(&g_st_lock); int any = 0;
    for (int j = 0; j < g_nst; j++) if (!strncmp(g_st[j].id, "fps:", 4) && strcmp(g_st[j].st, "不配套") && strcmp(g_st[j].st, "表不认")) {
        int lit = 0;
        for (int i = 0; i < g_nfu; i++) if (!strcmp(g_fu[i].id, g_st[j].id) && on && g_fu[i].allow && tgt(&g_fu[i]) == pick) lit = 1;
        snprintf(g_st[j].st, sizeof g_st[j].st, "%s", lit ? "开" : "关"); if (!lit) g_st[j].eff[0] = 0; any = 1; }
    if (any) st_flush_locked();
    pthread_mutex_unlock(&g_st_lock);
}
// 玩家切档（设置页 / 局内菜单）：记下选的档；已在跟随（帧率补丁开着）就当场重选并切换，下一帧生效
void s2a_cpatch_fps_pick(int target) {
    g_fps_want = target > 0 ? target : 0;
    if (g_fps_on > 0) s2a_cpatch_fps_follow(1);
}
// 金手指逐条开关（Cheats.cs 每次重载开关表时对每条调；主代码 = 同文件任一条开着）：
//   → 1 这条编进了包、已按 on 生效；0 包里没有这条（交运行时 Tamper）
int s2a_cpatch_cheat(const char *file, const char *name, int on) {
    int hit = 0;
    pthread_mutex_lock(&g_ch_lock);
    struct cp_cheat *h = NULL;
    for (int i = 0; i < g_nch; i++) if (!strcmp(g_ch[i].file, file) && !strcmp(g_ch[i].name, name)) { h = &g_ch[i]; break; }
    if (h && h->slot) {
        hit = 1;
        if (h->on != !!on) {
            h->on = !!on;
            uint64_t all = 0, want = 0;   // 本模块全部金手指位 / 开着的位
            for (int i = 0; i < g_nch; i++) if (g_ch[i].slot == h->slot) { all |= g_ch[i].bits; if (g_ch[i].on) want |= g_ch[i].bits; }
            for (int i = 0; i < g_nch; i++)   // 先写回关着的、再写开着的（同处变体以开着的为准）
                if (g_ch[i].m == h->m && !g_ch[i].on && g_ch[i].spec[0] && data_writes(g_ch[i].m, g_ch[i].spec, 2)) die("金手指已校验的数据写回失败");
            for (int i = 0; i < g_nch; i++)
                if (g_ch[i].m == h->m && g_ch[i].on && g_ch[i].spec[0] && data_writes(g_ch[i].m, g_ch[i].spec, 1)) die("金手指已校验的数据写入失败");
            uint64_t cur = atomic_load(h->slot);   // 只动金手指的位：帧率跟随可能同时改别的位
            while (!atomic_compare_exchange_weak(h->slot, &cur, (cur & ~all) | want)) {}
            LOG("金手指：%s %s/%s %s（编进游戏）", h->m->name, file, name, on ? "开" : "关");
        }
    }
    pthread_mutex_unlock(&g_ch_lock);
    return hit;
}
