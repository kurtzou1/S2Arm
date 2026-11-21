// launchctx.c 单测（启动上下文，runtime/include/s2a_launch_ctx.h）。期望值按改造前代码手算，不跑被测实现推：
//   单款兼容：模块目录 = 可执行文件目录（旧 host_main.c dirname(exe)）、镜像包 = <exe 目录>/Frameworks/S2AImages.dylib（旧 loader.c ext_pack）、
//   资源包 = $HOME/Documents/资源包（旧 host_main.c / gfxmode.c / patch.c）、文档 = S2A_DOCS 否则 $HOME/Documents（旧 envfile.c / qladder_host.c）、
//   Ryujinx 数据 = $HOME/Documents/S2A/ryujinx（ios/save_transfer.m data_root）、host.log 目录 = $HOME/Documents（os.c logfd_redirect）。
//   用例：兼容无环境 / 兼容带环境 / 文件各根取文件 + 缺省推导 / 文件各类错误 / 冻结后写环境（文件）与不写环境（兼容）/ 一进程一款第二次起局被拒 / 每款 env.txt 目录
//   多款容器（11-07 P2，共用布局约定 v1）：期望值按布局约定手写（Games/<gid>、Frameworks/S2AImages-<gid>.dylib、Documents/games/<gid>/资源包、…/S2A/ryujinx）；
//   纯解析的各类拒绝；进程级用例把本测试程序拷进一个临时「App 包」（带 s2a_catalogue.json / Games/）再 exec，构造期（同 vawin.c 101）取上下文、再选游戏
#include "../src/native.h"
#include "s2a_launch_ctx.h"
#include "s2a_docs.h"
#include "s2a_host_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <time.h>
#include <mach-o/dyld.h>

static int fails = 0;
static void ck(int ok, const char *what) { if (!ok) { printf("✗ %s\n", what); fails++; } else printf("✓ %s\n", what); }
static int eq(const char *a, const char *b) { if (strcmp(a, b)) { printf("  期望「%s」，真结果「%s」\n", b, a); return 0; } return 1; }
static void unset_roots(void) { unsetenv("S2A_GAME_DATA"); unsetenv("S2A_DOCS"); unsetenv("S2A_RYU_DATA"); unsetenv("S2A_LAUNCH_CTX"); unsetenv("S2A_LAUNCH_GAME_ID"); }
static void write_file(const char *p, const char *body) {
    FILE *f = fopen(p, "w"); if (!f) { printf("【红】写不了 %s\n", p); exit(99); }
    fputs(body, f); fclose(f);
}

// ---------- 多款容器：进程级用例（在拷进临时 App 包的副本里跑）----------
// 宿主的 s2a_imgpack_open（imgpack.c，本单测不链）的桩：launchctx.c 选游戏时按名字 dlsym 它。记调用次数，恒回 3（= S2A_IMG_ESIGN，签名本机不认）——
//   App 包里的款（没有程序包，0.6.0 前玩家手上全是这种）选游戏时不许调它（行为同改造前：进局后由装载器打开）；改造前的写法对所有款都预开，这一桩会把合规款判成「要重签」
static int g_imgpack_calls;
// 黄字记录（waived.c 的 s2a_check_waived，本单测不链）的桩：launchctx.c 的 waive 按名 dlsym 它。记下所有黄字，第 7 款核「不再给程序库整份算 SHA-256」
static char g_waived[4096];
__attribute__((visibility("default"), used)) void s2a_check_waived(const char *m) { size_t l = strlen(g_waived); snprintf(g_waived + l, sizeof g_waived - l, "%s\n", m ? m : ""); }
__attribute__((visibility("default"), used)) int s2a_imgpack_open(const char *path, void **out, char *why, size_t n) { (void)path; (void)out; if (why && n) why[0] = 0; g_imgpack_calls++; return 3; }
static int g_ctor_ran, g_ctor_container, g_ctor_frozen;
// 同 vawin.c constructor(101)：构造期第一次取上下文。只在 exec 出来的副本里取（父进程取了会把兼容冻结带进下面 fork 的子进程）
__attribute__((constructor(101))) static void t_ctor(int argc, char **argv) {
    if (argc < 2 || (strcmp(argv[1], "container") && strcmp(argv[1], "ctxfile") && strcmp(argv[1], "waive"))) return;
    g_ctor_ran = 1; g_ctor_container = s2a_launch_ctx_container(); g_ctor_frozen = s2a_launch_ctx_get() != NULL;
}
#define CK(x, m) do { if (!(x)) { printf("  ✗（副本）%s\n", m); bad++; } } while (0)
static int child_container(const char *home) {
    int bad = 0;
    CK(g_ctor_ran && g_ctor_container && !g_ctor_frozen, "构造期：认出容器、不冻结");
    CK(!s2a_launch_ctx_get() && s2a_launch_ctx_error() && strstr(s2a_launch_ctx_error(), "还没选"), "选之前取上下文 = NULL，原因「还没选游戏」");
    CK(!getenv("S2A_DOCS") && !getenv("S2A_GAME_DATA") && !getenv("S2A_RYU_DATA") && !getenv("S2A_LAUNCH_GAME_ID"), "选之前不写任何根进环境");
    CK(!s2a_launch_ctx_game_env_dir("/x"), "选之前没有每款 env.txt 目录");
    const char *r = s2a_launch_ctx_select("0100000000000BAD");
    CK(r && strstr(r, "不在本包游戏清单"), "gid 不在清单 → 拒绝");
    CK(s2a_launch_ctx_select_kind() == S2A_SELECT_APP_INCOMPLETE, "不在清单 → 类别 APP_INCOMPLETE（屏上说「在电脑上重新装到 iPhone」）");
    r = s2a_launch_ctx_select("0100000000000002");
    CK(r && strstr(r, "镜像包"), "清单里有、镜像包缺 → 拒绝");
    CK(s2a_launch_ctx_select_kind() == S2A_SELECT_APP_INCOMPLETE, "镜像包缺 → 类别 APP_INCOMPLETE");
    CK(!s2a_launch_ctx_get() && !getenv("S2A_DOCS"), "选失败不冻结、不写环境");
    CK(s2a_launch_ctx_game_needs_update("0100000000000005") == 1 && s2a_launch_ctx_game_needs_update("0100000000000001") == 0
       && s2a_launch_ctx_game_needs_update("0100000000000BAD") == 0, "库界面预判：约定号对不上的那款 → 1；对得上 / 不在清单 → 0（不在清单交给点开时报）");
    CK(!s2a_launch_ctx_get(), "预判不冻结");
    // 0005（约定号对不上）/ 0007（程序包校验值对不上）：11-17 起不再拒、黄字照常继续，选中后本进程就不能再选别款 → 各在自己的副本进程里测（child_waive）
    r = s2a_launch_ctx_select("0100000000000001");
    CK(!r, "合规的那款 → 选中");
    CK(g_imgpack_calls == 0, "App 包里的款（没有程序包）选游戏时不预开程序库：行为同改造前（桩恒回签名不认，预开了就会被拒）");
    if (r) printf("    原因：%s\n", r);
    const s2a_launch_ctx *g = s2a_launch_ctx_get();
    char want[1200]; snprintf(want, sizeof want, "%s/Documents/games/0100000000000001", home);
    CK(g && g->source == S2A_LCTX_CONTAINER && !strcmp(g->game_id, "0100000000000001") && !strcmp(g->docs, want), "选中后取到本款上下文（来源 CONTAINER、文档根 = $HOME/Documents/games/<gid>）");
    const char *e2 = getenv("S2A_DOCS"), *e4 = getenv("S2A_LAUNCH_GAME_ID"), *e1 = getenv("S2A_GAME_DATA");
    char wgd[1300]; s2a_pack_root(wgd, sizeof wgd, want);   // = <home>/Library/Application Support/S2Arm/games/<游戏号>/资源包（同解析，见上面「容器解析：资源包根」的手写期望）
    CK(e2 && !strcmp(e2, want) && e4 && !strcmp(e4, "0100000000000001") && e1 && !strcmp(e1, wgd), "选中后写环境：S2A_DOCS / S2A_GAME_DATA / S2A_LAUNCH_GAME_ID");
    struct stat st; CK(!stat(want, &st) && S_ISDIR(st.st_mode), "选中后本款文档根已建");
    char pd[1100]; snprintf(pd, sizeof pd, "%s/Documents", home);
    const char *gd = s2a_launch_ctx_game_env_dir(pd); CK(gd && !strcmp(gd, want), "本款 env.txt 目录 = 本款文档根（host_run 补读）");
    r = s2a_launch_ctx_select("0100000000000001");
    CK(r && strstr(r, "重新打开"), "同一款二次 select → 拒绝，提示重开");
    CK(s2a_launch_ctx_select_kind() == S2A_SELECT_OTHER, "二次 select → 类别 OTHER（不说成「不完整」）");
    r = s2a_launch_ctx_select("0100000000000BAD");
    CK(r && strstr(r, "重新打开") && s2a_launch_ctx_get() == g && !strcmp(g->game_id, "0100000000000001"), "换一款二次 select → 拒绝，上下文不变");
    return bad;
}
// 校验不过照常继续（11-17 维护者）：0005 宿主约定号对不上 → 照常选中；0007 程序包校验值对不上 → 不再因校验值拒（单测桩恒回签名不认，
//   所以最后按「签名本机不认」拒——这是物理上加载不了的那一项，照旧拒；原因里不该再有校验值那句「不是同一次出的」）
static int child_waive(const char *gid) {
    int bad = 0; const char *r = s2a_launch_ctx_select(gid);
    if (!strcmp(gid, "0100000000000005")) {
        CK(!r, "约定号对不上 → 不再拒，照常选中（黄字记下）");
        if (r) printf("    原因：%s\n", r);
        CK(s2a_launch_ctx_get() && getenv("S2A_DOCS"), "约定号对不上：照常冻结上下文、写环境");
    } else {
        CK(r && !strstr(r, "不是同一次出的") && strstr(r, "签名本机不认"), "校验值对不上 → 不再按校验值拒；只剩签名不认（物理上加载不了）那一项拒");
        // 11-19 起局前完整性校验去掉：清单 image_sha256 全 0（一定对不上），旧代码会整份读程序库算 SHA-256、黄字记「不是同一次出的」；现在一个字都不读、不记
        CK(!strstr(g_waived, "不是同一次出的") && !strstr(g_waived, "SHA-256") && !strstr(g_waived, "程序包核不了"), "选游戏不再给程序库算 SHA-256（没有校验值那条黄字）");
        if (g_waived[0]) printf("    黄字：%s", g_waived);
        if (r) printf("    原因：%s\n", r);
    }
    return bad;
}
static int child_ctxfile(void) {   // 容器包里设了 S2A_LAUNCH_CTX：显式上下文文件优先（自动化局），构造期冻结、不进容器模式
    int bad = 0;
    CK(g_ctor_ran && !g_ctor_container && g_ctor_frozen, "设了 S2A_LAUNCH_CTX：构造期按文件冻结、不当容器");
    const s2a_launch_ctx *g = s2a_launch_ctx_get();
    CK(g && g->source == S2A_LCTX_FILE, "来源 FILE");
    const char *r = s2a_launch_ctx_select("0100000000000001");
    CK(r && strstr(r, "不是多款容器"), "非容器模式 select → 拒绝");
    return bad;
}
#undef CK
static void mkdirs(const char *p) { char b[1200]; snprintf(b, sizeof b, "mkdir -p '%s'", p); if (system(b)) { printf("【红】建不了 %s\n", p); exit(99); } }

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "container")) return child_container(argv[2]) ? 1 : 0;
    if (argc >= 2 && !strcmp(argv[1], "ctxfile")) return child_ctxfile() ? 1 : 0;
    if (argc >= 4 && !strcmp(argv[1], "waive")) return child_waive(argv[3]) ? 1 : 0;
    s2a_launch_ctx c; char why[600];
    unset_roots();

    // 1) 单款兼容、无环境：各根 = 改造前写死的路径
    ck(!s2a_launch_ctx_resolve(&c, "/var/A/S2Arm.app", "/var/H", NULL, why, sizeof why), "兼容解析成功");
    ck(c.source == S2A_LCTX_COMPAT && !c.game_id[0] && !c.ctx_path[0], "兼容：来源 COMPAT、无 game_id");
    ck(eq(c.module_dir, "/var/A/S2Arm.app"), "兼容：模块目录 = 可执行文件目录");
    ck(eq(c.images, "/var/A/S2Arm.app/Frameworks/S2AImages.dylib"), "兼容：镜像包 = <exe 目录>/Frameworks/S2AImages.dylib");
    ck(eq(c.caps_dir, "/var/A/S2Arm.app"), "兼容：能力清单目录 = App 包顶层");
    ck(eq(c.game_data, "/var/H/Documents/资源包"), "兼容：资源包根 = $HOME/Documents/资源包");
    ck(eq(c.docs, "/var/H/Documents"), "兼容：文档根 = $HOME/Documents");
    ck(eq(c.ryu_data, "/var/H/Documents/S2A/ryujinx"), "兼容：Ryujinx 数据根 = $HOME/Documents/S2A/ryujinx");
    ck(eq(c.log_dir, "/var/H/Documents"), "兼容：host.log 目录 = $HOME/Documents");
    ck(!s2a_launch_ctx_resolve(&c, "/x", NULL, "", why, sizeof why) && eq(c.docs, "./Documents"), "兼容：没有 HOME 按 \".\"（同旧代码）、空 ctx 路径当兼容");

    // 2) 单款兼容、带环境（Mac 局 / 执行器）：取环境；空串当没给（同旧 envfile.c 判 *dd）
    setenv("S2A_GAME_DATA", "/g", 1); setenv("S2A_DOCS", "/d", 1); setenv("S2A_RYU_DATA", "/r", 1);
    s2a_launch_ctx_resolve(&c, "/var/A/S2Arm.app", "/var/H", NULL, why, sizeof why);
    ck(eq(c.game_data, "/g") && eq(c.docs, "/d") && eq(c.ryu_data, "/r"), "兼容：S2A_GAME_DATA / S2A_DOCS / S2A_RYU_DATA 照旧优先");
    ck(eq(c.log_dir, "/var/H/Documents"), "兼容：host.log 目录不随 S2A_DOCS（os.c 只看 HOME）");
    setenv("S2A_DOCS", "", 1);
    s2a_launch_ctx_resolve(&c, "/var/A/S2Arm.app", "/var/H", NULL, why, sizeof why);
    ck(eq(c.docs, "/var/H/Documents"), "兼容：S2A_DOCS 空串按没给");
    unset_roots();

    // 3) 上下文文件：各根取文件；@bundle / @home 前缀；caps / ryu 缺省推导
    char dir[] = "/tmp/t_launchctx_XXXXXX"; if (!mkdtemp(dir)) { printf("【红】mkdtemp\n"); return 99; }
    char f1[200]; snprintf(f1, sizeof f1, "%s/launch.tsv", dir);
    write_file(f1, "# 多款容器的一款\nversion\t1\ngame_id\t0100A3D008C5C000\nbuild_id\tb1\r\n\n"
                   "images\t@bundle/Frameworks/G1.dylib\nmodule_dir\t@bundle/Games/0100A3D008C5C000/b1\n"
                   "game_data\t@home/Documents/games/0100A3D008C5C000/资源包\ndocs\t/abs/docs1\n");
    ck(!s2a_launch_ctx_resolve(&c, "/var/A/S2Arm.app", "/var/H", f1, why, sizeof why), "文件：解析成功");
    if (why[0]) printf("  原因：%s\n", why);
    ck(c.source == S2A_LCTX_FILE && eq(c.ctx_path, f1), "文件：来源 FILE、记下文件路径");
    ck(eq(c.game_id, "0100A3D008C5C000") && eq(c.build_id, "b1"), "文件：game_id / build_id（CRLF 已去）");
    ck(eq(c.images, "/var/A/S2Arm.app/Frameworks/G1.dylib"), "文件：镜像包按 @bundle 拼");
    ck(eq(c.module_dir, "/var/A/S2Arm.app/Games/0100A3D008C5C000/b1"), "文件：模块目录按 @bundle 拼");
    ck(eq(c.caps_dir, c.module_dir), "文件：没写 caps_dir = 模块目录");
    ck(eq(c.game_data, "/var/H/Documents/games/0100A3D008C5C000/资源包"), "文件：资源包按 @home 拼");
    ck(eq(c.docs, "/abs/docs1"), "文件：文档根取绝对路径");
    ck(eq(c.ryu_data, "/abs/docs1/S2A/ryujinx"), "文件：没写 ryu_data = <docs>/S2A/ryujinx");
    ck(eq(c.bundle_dir, "/var/A/S2Arm.app") && eq(c.log_dir, "/var/H/Documents"), "文件：包目录 / host.log 目录仍是进程级");
    char rel[220]; snprintf(rel, sizeof rel, "@home/%s", strrchr(f1, '/') + 1);   // S2A_LAUNCH_CTX 自己也认 @home/
    ck(!s2a_launch_ctx_resolve(&c, "/var/A/S2Arm.app", dir, rel, why, sizeof why) && eq(c.ctx_path, f1), "文件：S2A_LAUNCH_CTX 认 @home/ 前缀");

    // 4) 文件错误：都回 -1 且给原因，结构清空（不留半份）
    static const struct { const char *body, *what, *needle; } bad[] = {
        {"version\t1\ngame_id\tg\nimages\t/i\nmodule_dir\t/m\ngame_data\t/g\ndocs\t/d\nlog_dir\t/l\n", "不认的键（log_dir 本刀不收）", "不认的键"},
        {"version\t1\ngame_id\tg\nimages\t/i\nmodule_dir\t/m\ndocs\t/d\n", "缺必填 game_data", "game_data"},
        {"game_id\tg\nimages\t/i\nmodule_dir\t/m\ngame_data\t/g\ndocs\t/d\n", "没有 version", "version"},
        {"version\t1\ngame_id\tg\nimages\trel/i\nmodule_dir\t/m\ngame_data\t/g\ndocs\t/d\n", "相对路径", "绝对路径"},
        {"version\t1\ngame_id\ta/b\nimages\t/i\nmodule_dir\t/m\ngame_data\t/g\ndocs\t/d\n", "game_id 带斜杠", "game_id"},
        {"version 1\n", "没有 TAB", "TAB"},
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        write_file(f1, bad[i].body); char m[200];
        int rc = s2a_launch_ctx_resolve(&c, "/var/A", "/var/H", f1, why, sizeof why);
        snprintf(m, sizeof m, "文件错误：%s → 拒绝并说明", bad[i].what);
        ck(rc == -1 && strstr(why, bad[i].needle) && !c.module_dir[0] && !c.docs[0], m);
        if (rc != -1 || !strstr(why, bad[i].needle)) printf("  rc=%d 原因：%s\n", rc, why);
    }
    char nof[220]; snprintf(nof, sizeof nof, "%s/none.tsv", dir);
    ck(s2a_launch_ctx_resolve(&c, "/var/A", "/var/H", nof, why, sizeof why) == -1 && strstr(why, "打不开"), "文件错误：文件不在 → 拒绝（不退回兼容）");
    ck(s2a_launch_ctx_resolve(&c, "/var/A", "/var/H", "rel.tsv", why, sizeof why) == -1, "文件错误：S2A_LAUNCH_CTX 相对路径 → 拒绝");

    // 5) 冻结（进程一次）：兼容不写环境；文件写四个根进环境且覆盖起局方旧值。各在子进程里冻结
    pid_t p = fork();
    if (!p) {
        unset_roots(); setenv("HOME", "/var/H", 1);
        const s2a_launch_ctx *g = s2a_launch_ctx_get();
        int ok = g && g->source == S2A_LCTX_COMPAT && !getenv("S2A_DOCS") && !getenv("S2A_GAME_DATA") && !getenv("S2A_RYU_DATA") && !getenv("S2A_LAUNCH_GAME_ID")
                 && !strcmp(g->docs, "/var/H/Documents") && s2a_launch_ctx_get() == g && !s2a_launch_ctx_error()
                 && !s2a_launch_ctx_game_env_dir("/var/H/Documents") && !s2a_launch_ctx_game_env_dir("/other");
        _exit(ok ? 0 : 1);
    }
    int st; waitpid(p, &st, 0); ck(WIFEXITED(st) && WEXITSTATUS(st) == 0, "冻结（兼容）：不写任何环境变量、重复取同一份、不补读每款 env.txt");
    write_file(f1, "version\t1\ngame_id\tg2\nimages\t/i\nmodule_dir\t/m\ngame_data\t/gd2\ndocs\t/d2\nryu_data\t/r2\n");
    p = fork();
    if (!p) {
        unset_roots(); setenv("S2A_LAUNCH_CTX", f1, 1); setenv("S2A_DOCS", "/old", 1);
        const s2a_launch_ctx *g = s2a_launch_ctx_get();
        const char *e1 = getenv("S2A_GAME_DATA"), *e2 = getenv("S2A_DOCS"), *e3 = getenv("S2A_RYU_DATA"), *e4 = getenv("S2A_LAUNCH_GAME_ID");
        int ok = g && g->source == S2A_LCTX_FILE && e1 && !strcmp(e1, "/gd2") && e2 && !strcmp(e2, "/d2") && e3 && !strcmp(e3, "/r2") && e4 && !strcmp(e4, "g2");
        const char *gd = s2a_launch_ctx_game_env_dir("/old"), *same = s2a_launch_ctx_game_env_dir("/d2");
        ok = ok && gd && !strcmp(gd, "/d2") && !same;
        _exit(ok ? 0 : 1);
    }
    waitpid(p, &st, 0); ck(WIFEXITED(st) && WEXITSTATUS(st) == 0, "冻结（文件）：S2A_GAME_DATA / S2A_DOCS / S2A_RYU_DATA / S2A_LAUNCH_GAME_ID 按文件写进环境（覆盖旧 S2A_DOCS）；本款文档根另有时补读 env.txt");
    write_file(f1, "version\t2\n");
    p = fork();
    if (!p) { unset_roots(); setenv("S2A_LAUNCH_CTX", f1, 1); _exit(!s2a_launch_ctx_get() && s2a_launch_ctx_error() && strstr(s2a_launch_ctx_error(), "version") && !getenv("S2A_DOCS") ? 0 : 1); }
    waitpid(p, &st, 0); ck(WIFEXITED(st) && WEXITSTATUS(st) == 0, "冻结（坏文件）：取不到上下文、给原因、不写环境");

    // 6) 一进程一款：第一次放行，第二、三次拒绝
    ck(s2a_launch_ctx_begin() == NULL, "一进程一款：第一次起局放行");
    const char *r2 = s2a_launch_ctx_begin(), *r3 = s2a_launch_ctx_begin();
    ck(r2 && strstr(r2, "第二局") && r3, "一进程一款：第二次（及之后）起局被拒并给原因");

    // 7) 多款容器纯解析：期望值按布局约定手写
    char app[300], home[300], p2[400];
    snprintf(app, sizeof app, "%s/App/S2Arm.app", dir); snprintf(home, sizeof home, "%s/home", dir);
    ck(!s2a_launch_ctx_is_container_dir(app), "容器判定：包根什么都没有 → 不是容器");
    snprintf(p2, sizeof p2, "%s/Games/0100000000000001", app); mkdirs(p2);
    snprintf(p2, sizeof p2, "%s/Games/0100000000000002", app); mkdirs(p2);
    snprintf(p2, sizeof p2, "%s/Frameworks", app); mkdirs(p2);
    ck(!s2a_launch_ctx_is_container_dir(app), "容器判定：只有 Games/、没有清单 → 不是容器");
    snprintf(p2, sizeof p2, "%s/s2a_catalogue.json", app);
    { char cat[700]; snprintf(cat, sizeof cat, "{\"schema\":1,\"games\":[\n {\"title_id\" : \"0100000000000001\",\"name\":\"title_id\"},\n {\"title_id\":\"0100000000000002\",\"name\":\"二\"},\n"
                   " {\"name\":\"0100000000000003\",\"title_id\":\"0100000000000004\"},\n {\"title_id\":\"0100000000000005\",\"host_abi\":%d}]}\n", S2A_HOST_ABI + 1);
      write_file(p2, cat); }
    ck(s2a_launch_ctx_is_container_dir(app), "容器判定：有清单且有 Games/ → 容器");
    {   // 0.6.0「只装壳」的容器：清单只有 shell_id、games 为空，没有 Games/ → 也是容器（原先要求 Games/，被当成单款包起）
        char sh[1300], sp[1400]; snprintf(sh, sizeof sh, "%s/ShellOnly/S2Arm.app", dir); mkdirs(sh);
        snprintf(sp, sizeof sp, "%s/s2a_catalogue.json", sh); write_file(sp, "{\"schema\":1,\"shell_id\":\"abc\",\"games\":[]}\n");
        ck(s2a_launch_ctx_is_container_dir(sh), "容器判定：只装壳（清单在、games 空、没有 Games/）→ 容器"); }
    snprintf(p2, sizeof p2, "%s/Frameworks/S2AImages-0100000000000001.dylib", app); write_file(p2, "x");
    snprintf(p2, sizeof p2, "%s/Games/0100000000000005", app); mkdirs(p2);   // 第 5 款：随行目录、镜像包都在，只是 host_abi 对不上（进程级用例核拒载）
    snprintf(p2, sizeof p2, "%s/Frameworks/S2AImages-0100000000000005.dylib", app); write_file(p2, "x");
    {   // 独立 App（一 App 一游戏）判定：期望值按布局约定手写
        char g[64] = "", one[1300], op[1400];
        ck(!s2a_launch_ctx_single_game(app, g, sizeof g), "独立 App 判定：清单里有多款 → 不是");
        snprintf(one, sizeof one, "%s/Single/S2Arm.app", dir);
        snprintf(op, sizeof op, "%s/Games/0100ABCD00000001", one); mkdirs(op);
        snprintf(op, sizeof op, "%s/Frameworks", one); mkdirs(op);
        snprintf(op, sizeof op, "%s/s2a_catalogue.json", one);
        write_file(op, "{\"schema\":1,\"shell_id\":\"abc\",\"games\":[{\"title_id\" : \"0100ABCD00000001\",\"name\":\"一\"}]}\n");
        ck(!s2a_launch_ctx_single_game(one, g, sizeof g), "独立 App 判定：只有一款但程序库不在包里（通用壳布局）→ 不是");
        snprintf(op, sizeof op, "%s/Frameworks/S2AImages-0100ABCD00000001.dylib", one); write_file(op, "x");
        ck(s2a_launch_ctx_single_game(one, g, sizeof g) && eq(g, "0100ABCD00000001"), "独立 App 判定：只有一款、程序库和随行目录在包里 → 是，给出游戏号");
        char sm[4]; ck(!s2a_launch_ctx_single_game(one, sm, sizeof sm), "独立 App 判定：游戏号放不下给的缓冲 → 不是（不截断）");
        snprintf(op, sizeof op, "%s/ShellOnly/S2Arm.app", dir); ck(!s2a_launch_ctx_single_game(op, g, sizeof g), "独立 App 判定：只装壳（games 空）→ 不是");
        ck(!s2a_launch_ctx_single_game(NULL, g, sizeof g), "独立 App 判定：包根为空 → 不是"); }
    ck(!s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000001", why, sizeof why), "容器解析：合规的那款成功");
    if (why[0]) printf("  原因：%s\n", why);
    char w[600];
    snprintf(w, sizeof w, "%s/Games/0100000000000001", app); ck(c.source == S2A_LCTX_CONTAINER && eq(c.module_dir, w) && eq(c.caps_dir, w), "容器解析：模块目录 = 能力清单目录 = <App>/Games/<gid>");
    snprintf(w, sizeof w, "%s/Frameworks/S2AImages-0100000000000001.dylib", app); ck(eq(c.images, w), "容器解析：镜像包 = <App>/Frameworks/S2AImages-<gid>.dylib");
    snprintf(w, sizeof w, "%s/Documents/games/0100000000000001", home); ck(eq(c.docs, w), "容器解析：文档根 = $HOME/Documents/games/<gid>");
    snprintf(w, sizeof w, "%s/Library/Application Support/S2Arm/games/0100000000000001/资源包", home);
    ck(eq(c.game_data, w), "容器解析：资源包根 = Library/Application Support/S2Arm/games/<游戏号>/资源包（v0.3.0 挪出 Documents，s2a_pack_root）");
    snprintf(w, sizeof w, "%s/Documents/games/0100000000000001/S2A/ryujinx", home); ck(eq(c.ryu_data, w), "容器解析：Ryujinx 数据根 = <文档根>/S2A/ryujinx");
    snprintf(w, sizeof w, "%s/Documents", home); ck(eq(c.log_dir, w) && eq(c.bundle_dir, app) && eq(c.game_id, "0100000000000001"), "容器解析：host.log 目录进程级、包目录、game_id");
    {   // 通用壳（11-16）：程序包在资源包根旁 program/（清单 + 镜像包 + Games/<gid>），这款不在 App 包清单、App 包里也没有它的程序。期望手写：
        //   镜像包 = <程序包>/S2AImages-<gid>.dylib（清单 image 原样）、模块目录 = <程序包>/Games/<gid>、from_program = 1；文档根 / 资源包根同 App 包内那支
        char pr[900], q[1000];
        snprintf(pr, sizeof pr, "%s/Library/Application Support/S2Arm/games/0100000000000006/program", home);
        snprintf(q, sizeof q, "%s/Games/0100000000000006", pr); mkdirs(q);
        snprintf(q, sizeof q, "%s/S2AImages-0100000000000006.dylib", pr); write_file(q, "x");
        snprintf(q, sizeof q, "%s/catalogue.json", pr);
        write_file(q, "{\"schema\":1,\"title_id\":\"0100000000000006\",\"name\":\"六\",\"host_abi\":1,\"image\":\"S2AImages-0100000000000006.dylib\"}\n");
        ck(!s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000006", why, sizeof why) && c.from_program == 1, "程序包：不在 App 清单的那款照样解析成功，来源标 from_program");
        if (why[0]) printf("  原因：%s\n", why);
        snprintf(q, sizeof q, "%s/S2AImages-0100000000000006.dylib", pr); ck(eq(c.images, q), "程序包：镜像包 = <程序包>/<清单 image>");
        snprintf(q, sizeof q, "%s/Games/0100000000000006", pr); ck(eq(c.module_dir, q) && eq(c.caps_dir, q), "程序包：模块目录 = 能力清单目录 = <程序包>/Games/<gid>");
        snprintf(q, sizeof q, "%s/Documents/games/0100000000000006", home); ck(eq(c.docs, q), "程序包：文档根照旧 $HOME/Documents/games/<gid>");
        ck(!s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000001", why, sizeof why) && c.from_program == 0, "没有程序包的那款：照旧取 App 包内，from_program = 0");
        {   // 独立 App（0.6.3）：App 包里自带这款的镜像包，沙盒里又留着一份程序包（显式描述文件同包名、通用壳推过）→ 一律取包内，不看程序包
            char p1[900], q1[1000];
            snprintf(p1, sizeof p1, "%s/Library/Application Support/S2Arm/games/0100000000000001/program", home);
            snprintf(q1, sizeof q1, "%s/Games/0100000000000001", p1); mkdirs(q1);
            snprintf(q1, sizeof q1, "%s/S2AImages-0100000000000001.dylib", p1); write_file(q1, "z");
            snprintf(q1, sizeof q1, "%s/catalogue.json", p1);
            write_file(q1, "{\"schema\":1,\"title_id\":\"0100000000000001\",\"host_abi\":1,\"image\":\"S2AImages-0100000000000001.dylib\"}\n");
            char want[600]; snprintf(want, sizeof want, "%s/Frameworks/S2AImages-0100000000000001.dylib", app);
            ck(!s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000001", why, sizeof why) && c.from_program == 0 && eq(c.images, want),
               "包里自带镜像包、沙盒另有程序包：取包内，from_program = 0");
            snprintf(q1, sizeof q1, "rm -rf '%s'", p1); if (system(q1)) printf("  清不掉 %s\n", p1); }
        // 拒绝：清单不是这一款 / image 带路径 / 镜像包缺 / 随行目录缺
        snprintf(q, sizeof q, "%s/catalogue.json", pr);
        write_file(q, "{\"title_id\":\"0100000000000009\",\"image\":\"S2AImages-0100000000000006.dylib\"}\n");
        ck(s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000006", why, sizeof why) == -1 && strstr(why, "清单和程序不是同一次出的") && !c.images[0], "程序包拒绝：清单里没有这款");
        write_file(q, "{\"title_id\":\"0100000000000006\",\"image\":\"../x.dylib\"}\n");
        ck(s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000006", why, sizeof why) == -1 && strstr(why, "不合规"), "程序包拒绝：image 带路径");
        write_file(q, "{\"title_id\":\"0100000000000006\",\"image\":\"S2AImages-missing.dylib\"}\n");
        ck(s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000006", why, sizeof why) == -1 && strstr(why, "程序包镜像包"), "程序包拒绝：镜像包缺");
        write_file(q, "{\"title_id\":\"0100000000000006\",\"image\":\"S2AImages-0100000000000006.dylib\"}\n");
        snprintf(q, sizeof q, "%s/Games/0100000000000006", pr); rmdir(q);
        ck(s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000006", why, sizeof why) == -1 && strstr(why, "程序包随行目录"), "程序包拒绝：随行目录缺");
        // 第 8 款：写入规则（0.6.0）——清单 dir 指向版本目录 program/v-<sha16>-pc/。期望按规则手写：模块目录 / 镜像包都在 v-… 下；dir 不合规拒；
        //   清理只删没被指着且最新文件 1 小时以上没写入的 v-* 与 catalogue.json.*.tmp，被指着的、刚写过的都留
        {
            char p8[1300], q8[1500], w8[1600]; snprintf(p8, sizeof p8, "%s/Library/Application Support/S2Arm/games/0100000000000008/program", home);
            const char *vs[3] = {"v-aaaaaaaaaaaaaaaa-pc", "v-bbbbbbbbbbbbbbbb-pc", "v-cccccccccccccccc-import"};
            for (int i = 0; i < 3; i++) { snprintf(q8, sizeof q8, "%s/%s/Games/0100000000000008", p8, vs[i]); mkdirs(q8);
                snprintf(q8, sizeof q8, "%s/%s/S2AImages-0100000000000008.dylib", p8, vs[i]); write_file(q8, "x"); }
            snprintf(q8, sizeof q8, "%s/catalogue.json", p8);
            write_file(q8, "{\"title_id\":\"0100000000000008\",\"host_abi\":1,\"image\":\"S2AImages-0100000000000008.dylib\",\"dir\":\"v-aaaaaaaaaaaaaaaa-pc\"}\n");
            snprintf(q8, sizeof q8, "%s/catalogue.json.pc.tmp", p8); write_file(q8, "{}");
            ck(!s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000008", why, sizeof why) && c.from_program == 1, "写入规则：清单带 dir 照样解析成功");
            snprintf(w8, sizeof w8, "%s/v-aaaaaaaaaaaaaaaa-pc/S2AImages-0100000000000008.dylib", p8); ck(eq(c.images, w8), "写入规则：镜像包 = program/<dir>/<image>");
            snprintf(w8, sizeof w8, "%s/v-aaaaaaaaaaaaaaaa-pc/Games/0100000000000008", p8); ck(eq(c.module_dir, w8), "写入规则：模块目录 = program/<dir>/Games/<gid>");
            snprintf(q8, sizeof q8, "%s/catalogue.json", p8);
            write_file(q8, "{\"title_id\":\"0100000000000008\",\"image\":\"S2AImages-0100000000000008.dylib\",\"dir\":\"../v-x\"}\n");
            ck(s2a_launch_ctx_resolve_game(&c, app, home, "0100000000000008", why, sizeof why) == -1 && strstr(why, "dir"), "写入规则：dir 不合规（带 ..、不以 v- 开头）→ 拒");
            write_file(q8, "{\"title_id\":\"0100000000000008\",\"image\":\"S2AImages-0100000000000008.dylib\",\"dir\":\"v-aaaaaaaaaaaaaaaa-pc\"}\n");
            // 清理：v-aaa 被指着（改旧也留）；v-bbb 没被指着、两小时前写的 → 删；v-ccc 没被指着、刚写过 → 留；临时清单两小时前 → 删
            time_t now = time(NULL), old = now - 2 * 3600;
            snprintf(w8, sizeof w8, "find '%s/v-aaaaaaaaaaaaaaaa-pc' '%s/v-bbbbbbbbbbbbbbbb-pc' '%s/catalogue.json.pc.tmp' -exec touch -t %s {} +", p8, p8, p8, "200001010000");
            ck(system(w8) == 0, "清理：造旧文件");
            (void)old;
            int rm = s2a_program_gc(home, now);
            snprintf(w8, sizeof w8, "test -d '%s/v-aaaaaaaaaaaaaaaa-pc' && test ! -e '%s/v-bbbbbbbbbbbbbbbb-pc' && test -d '%s/v-cccccccccccccccc-import' && test ! -e '%s/catalogue.json.pc.tmp' && test -f '%s/catalogue.json'", p8, p8, p8, p8, p8);
            ck(rm == 2 && system(w8) == 0, "清理：删没被指着且一小时没写入的 v-bbb 与临时清单（2 项），留被指着的 v-aaa、刚写过的 v-ccc 与清单");
            ck(s2a_program_gc(home, now) == 0, "清理：再跑一次没得删（0 项）");
            // 随行目录快照（双保险）：克隆 v-aaa/Games/<号> 到 <HOME>/tmp/s2a-mod-<号>-<pid>；删掉原目录后快照里的文件照样在；
            //   清理只删别的进程留下的快照（造一个 pid 1 的），本进程的留
            snprintf(q8, sizeof q8, "%s/v-aaaaaaaaaaaaaaaa-pc/Games/0100000000000008/s2a_caps.tsv", p8); write_file(q8, "widen\t1\n");
            char snap[1024]; snprintf(q8, sizeof q8, "%s/v-aaaaaaaaaaaaaaaa-pc/Games/0100000000000008", p8);
            ck(s2a_program_snapshot(home, "0100000000000008", q8, snap) == 0 && strstr(snap, "/tmp/s2a-mod-0100000000000008-"), "快照：拍到 <HOME>/tmp/s2a-mod-<号>-<pid>");
            snprintf(w8, sizeof w8, "rm -rf '%s' && test -s '%s/s2a_caps.tsv'", q8, snap);
            ck(system(w8) == 0, "快照：原随行目录删掉后，快照里的 s2a_caps.tsv 还在");
            snprintf(w8, sizeof w8, "mkdir -p '%s/tmp/s2a-mod-0100000000000008-1' && touch '%s/tmp/s2a-mod-0100000000000008-1/x'", home, home); ck(system(w8) == 0, "快照：造别的进程的旧快照");
            ck(s2a_program_gc(home, now) == 1, "快照：清理删掉别的进程的旧快照（1 项）");
            snprintf(w8, sizeof w8, "test -d '%s' && test ! -e '%s/tmp/s2a-mod-0100000000000008-1'", snap, home); ck(system(w8) == 0, "快照：本进程的快照留着");
        }
        // 第 7 款给进程级用例：程序库内容 "y"、清单 image_sha256 全 0（一定不等）
        snprintf(pr, sizeof pr, "%s/Library/Application Support/S2Arm/games/0100000000000007/program", home);
        snprintf(q, sizeof q, "%s/Games/0100000000000007", pr); mkdirs(q);
        snprintf(q, sizeof q, "%s/S2AImages-0100000000000007.dylib", pr); write_file(q, "y");
        snprintf(q, sizeof q, "%s/catalogue.json", pr);
        write_file(q, "{\"title_id\":\"0100000000000007\",\"host_abi\":1,\"image\":\"S2AImages-0100000000000007.dylib\",\"image_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}\n");
    }
    static const struct { const char *gid, *needle, *what; } rej[] = {
        {"0100000000000BAD", "不在本包游戏清单", "gid 不在清单"},
        {"0100000000000003", "不在本包游戏清单", "只在 name 值里出现、不是 title_id"},
        {"0100000000000002", "镜像包", "镜像包缺"},
        {"0100000000000004", "随行目录", "Games/<gid> 缺"},
        {"../0100000000000001", "不合规", "带 ../"},
        {"..", "不合规", "就是 .."},
        {"", "不合规", "空串"},
    };
    for (size_t i = 0; i < sizeof rej / sizeof rej[0]; i++) {
        char m[200]; int rc = s2a_launch_ctx_resolve_game(&c, app, home, rej[i].gid, why, sizeof why);
        snprintf(m, sizeof m, "容器解析拒绝：%s", rej[i].what);
        ck(rc == -1 && strstr(why, rej[i].needle) && !c.module_dir[0] && !c.docs[0], m);
        if (rc != -1 || !strstr(why, rej[i].needle)) printf("  rc=%d 原因：%s\n", rc, why);
    }

    // 8) 多款容器进程级：本程序拷进临时 App 包再 exec（构造期不冻结 / select 各类拒绝 / 选中写环境 / 二次 select 拒绝）
    char self[1100]; uint32_t sn = sizeof self; char copy[400]; int rc8;
    if (_NSGetExecutablePath(self, &sn)) { printf("【红】取不到本程序路径\n"); return 99; }
    snprintf(copy, sizeof copy, "%s/t_launchctx_app", app);
    { char b[1600]; snprintf(b, sizeof b, "cp '%s' '%s'", self, copy); if (system(b)) { printf("【红】拷不了本程序\n"); return 99; } }
    p = fork();
    if (!p) { unset_roots(); setenv("HOME", home, 1); execl(copy, copy, "container", home, (char *)NULL); _exit(98); }
    waitpid(p, &st, 0); rc8 = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    ck(rc8 == 0, "容器进程：构造期不冻结、gid 不在清单 / 镜像包缺拒绝且不冻结、选中写环境建文档根、二次 select 拒绝");
    for (int wi = 0; wi < 2; wi++) {   // 校验不过照常继续（11-17）：各一个副本进程（选中后本进程不能再选）
        const char *wg = wi ? "0100000000000007" : "0100000000000005";
        p = fork();
        if (!p) { unset_roots(); setenv("HOME", home, 1); execl(copy, copy, "waive", home, wg, (char *)NULL); _exit(98); }
        waitpid(p, &st, 0); rc8 = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
        ck(rc8 == 0, wi ? "程序包校验值对不上：不再按校验值拒（签名不认那项照旧拒）" : "宿主约定号对不上：黄字照常选中");
    }
    write_file(f1, "version\t1\ngame_id\tg3\nimages\t/i\nmodule_dir\t/m\ngame_data\t/gd3\ndocs\t/d3\n");
    p = fork();
    if (!p) { unset_roots(); setenv("HOME", home, 1); setenv("S2A_LAUNCH_CTX", f1, 1); execl(copy, copy, "ctxfile", (char *)NULL); _exit(98); }
    waitpid(p, &st, 0); rc8 = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    ck(rc8 == 0, "容器包里设了 S2A_LAUNCH_CTX：按文件构造期冻结、不进容器模式、select 拒绝");
    // 9) 宿主约定号核对（11-16，纯函数）：期望按约定手写——程序清单优先、不在退回 App 清单、都没记按 1；对得上回 0、对不上回 1 并给出产物上的号
    {
        const int H = S2A_HOST_ABI;
        char pc[500], ac[500], body[600]; int have;
        snprintf(pc, sizeof pc, "%s/abi_prog.json", dir); snprintf(ac, sizeof ac, "%s/abi_app.json", dir);
        snprintf(body, sizeof body, "{\"games\":[{\"title_id\":\"G1\",\"host_abi\":%d},{\"title_id\":\"G2\"},{\"title_id\":\"G3\",\"host_abi\":%d},"
                 "{\"title_id\":\"G4\",\"name\":\"a{b}\\\"c\",\"x\":{\"host_abi\":%d}},{\"title_id\":\"G5\",\"host_abi\":\"x\"}]}", H, H + 1, H + 1);
        write_file(ac, body);
        have = -9; ck(s2a_host_abi_check(NULL, ac, "G1", &have, why, sizeof why) == 0 && have == H, "约定号：App 清单记的号 = 本宿主 → 0");
        have = -9; ck(s2a_host_abi_check(NULL, ac, "G2", &have, why, sizeof why) == (H == 1 ? 0 : 1) && have == 1, "约定号：条目没记 host_abi = 旧包，按 1");
        have = -9; ck(s2a_host_abi_check(NULL, ac, "G3", &have, why, sizeof why) == 1 && have == H + 1, "约定号：App 清单记的号 ≠ 本宿主 → 1，给出产物上的号");
        have = -9; ck(s2a_host_abi_check(NULL, ac, "G4", &have, why, sizeof why) == (H == 1 ? 0 : 1) && have == 1, "约定号：名字里带 { } \\\" 不乱，嵌套对象里的 host_abi 不算这款的");
        have = -9; ck(s2a_host_abi_check(NULL, ac, "G5", &have, why, sizeof why) == 1 && have == -1, "约定号：记成非数字 → 对不上（号记 -1）");
        have = -9; ck(s2a_host_abi_check(NULL, ac, "G9", &have, why, sizeof why) == (H == 1 ? 0 : 1) && have == 1, "约定号：App 清单里没这款 = 没记，按 1（成员另由清单核对拒）");
        snprintf(body, sizeof body, "{\"schema\":1,\"title_id\":\"G1\",\"host_abi\":%d,\"image\":\"S2AImages-G1.dylib\"}", H + 1);
        write_file(pc, body);
        have = -9; ck(s2a_host_abi_check(pc, ac, "G1", &have, why, sizeof why) == 1 && have == H + 1, "约定号：程序清单在 → 以它为准（App 清单对得上也不看）");
        why[0] = 0; ck(s2a_host_abi_check(pc, ac, "G3", &have, why, sizeof why) == -1 && strstr(why, "不是同一次"), "约定号：程序清单不是这一款 → -1（清单和程序不是一套）");
        char gone[520]; snprintf(gone, sizeof gone, "%s/abi_none.json", dir);
        have = -9; ck(s2a_host_abi_check(gone, ac, "G1", &have, why, sizeof why) == 0 && have == H, "约定号：程序清单不存在 → 退回 App 清单");
        have = -9; ck(s2a_host_abi_check(NULL, gone, "G1", &have, why, sizeof why) == -1, "约定号：App 清单打不开 → -1");
        char out[300]; ck(!s2a_program_catalogue_path(out, sizeof out, "/H/Library/Application Support/S2Arm/games/G1/资源包")
                          && eq(out, "/H/Library/Application Support/S2Arm/games/G1/program/catalogue.json"), "程序清单位置 = 资源包根的上一级 /program/catalogue.json");
        unlink(pc); unlink(ac);
    }
    { char b[400]; snprintf(b, sizeof b, "rm -rf '%s/App' '%s'", dir, home); if (system(b)) printf("  （清理 %s 失败）\n", dir); }

    unlink(f1); rmdir(dir);
    printf("%s t_launchctx（%d 处不符）\n", fails ? "✗" : "✓", fails);
    return fails ? 1 : 0;
}
