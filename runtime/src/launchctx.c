// 启动上下文（LaunchContext）：定义与口径见 runtime/include/s2a_launch_ctx.h。本文件只做解析、冻结（单款构造期 / 多款容器选游戏时）、一进程一款与每款 env.txt，
//   各读者（host_main.c / loader.c / vawin.c / ios/settings.m）取冻结后的结构，C# 与其余原生读者经 S2A_GAME_DATA / S2A_DOCS / S2A_RYU_DATA 取。
#include "native.h"
#include "s2a_launch_ctx.h"
#include "s2a_docs.h"   // 多款容器每款资源包根（s2a_pack_root）
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>

#define WHY(...) do { if (why && why_n) snprintf(why, why_n, __VA_ARGS__); } while (0)

static int put(char *dst, const char *src) {   // 拷进 S2A_LCTX_PATH 格；超长 = -1
    size_t n = strlen(src); if (n >= S2A_LCTX_PATH) return -1;
    memcpy(dst, src, n + 1); return 0;
}
static int join(char *dst, const char *a, const char *b) {
    int n = snprintf(dst, S2A_LCTX_PATH, "%s/%s", a, b);
    return n < 0 || n >= S2A_LCTX_PATH ? -1 : 0;
}
// 值 → 绝对路径：/… 原样；@bundle/<相对>、@home/<相对> 按前缀拼；别的（相对路径、空）不收
static int abs_value(char *dst, const char *v, const char *exe_dir, const char *home) {
    if (v[0] == '/') return put(dst, v);
    if (!strncmp(v, "@bundle/", 8) && v[8]) return join(dst, exe_dir, v + 8);
    if (!strncmp(v, "@home/", 6) && v[6]) return join(dst, home, v + 6);
    return -1;
}
static int id_ok(const char *s) {
    if (!*s) return 0;
    for (; *s; s++) if (!((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z') || (*s >= '0' && *s <= '9') || *s == '.' || *s == '_' || *s == '-')) return 0;
    return 1;
}
static const char *env_nonempty(const char *k) { const char *v = getenv(k); return v && *v ? v : NULL; }

static int resolve_compat(s2a_launch_ctx *c, const char *exe_dir, const char *home, char *why, size_t why_n) {
    char hd[S2A_LCTX_PATH]; const char *v;
    if (join(hd, home, "Documents")) { WHY("HOME 太长"); return -1; }
    if (put(c->bundle_dir, exe_dir) || put(c->module_dir, exe_dir) || put(c->caps_dir, exe_dir)
        || join(c->images, exe_dir, "Frameworks/S2AImages.dylib")) { WHY("可执行文件目录太长"); return -1; }
    if ((v = env_nonempty("S2A_GAME_DATA")) ? put(c->game_data, v) : join(c->game_data, hd, "资源包")) { WHY("S2A_GAME_DATA 太长"); return -1; }
    if ((v = env_nonempty("S2A_DOCS")) ? put(c->docs, v) : put(c->docs, hd)) { WHY("S2A_DOCS 太长"); return -1; }
    if ((v = env_nonempty("S2A_RYU_DATA")) ? put(c->ryu_data, v) : join(c->ryu_data, hd, "S2A/ryujinx")) { WHY("S2A_RYU_DATA 太长"); return -1; }
    put(c->log_dir, hd);
    return 0;
}

static int resolve_file(s2a_launch_ctx *c, const char *exe_dir, const char *home, const char *ctx_path, char *why, size_t why_n) {
    if (abs_value(c->ctx_path, ctx_path, exe_dir, home)) { WHY("S2A_LAUNCH_CTX 要绝对路径或 @bundle/ @home/ 前缀：%s", ctx_path); return -1; }
    FILE *f = fopen(c->ctx_path, "r");
    if (!f) { WHY("上下文文件 %s 打不开（errno %d）", c->ctx_path, errno); return -1; }
    char line[2048]; int lineno = 0, version = 0;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        size_t n = strlen(line);
        if (n == sizeof line - 1 && line[n - 1] != '\n') { WHY("上下文文件 %s 第 %d 行太长", c->ctx_path, lineno); fclose(f); return -1; }
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (!n || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) { WHY("上下文文件 %s 第 %d 行没有 TAB（格式：键<TAB>值）", c->ctx_path, lineno); fclose(f); return -1; }
        *tab = 0; const char *k = line, *v = tab + 1; char *dst = NULL; int is_path = 1;
        if (!strcmp(k, "version")) { version = atoi(v); continue; }
        else if (!strcmp(k, "game_id")) { dst = c->game_id; is_path = 0; }
        else if (!strcmp(k, "build_id")) { dst = c->build_id; is_path = 0; }
        else if (!strcmp(k, "images")) dst = c->images;
        else if (!strcmp(k, "module_dir")) dst = c->module_dir;
        else if (!strcmp(k, "caps_dir")) dst = c->caps_dir;
        else if (!strcmp(k, "game_data")) dst = c->game_data;
        else if (!strcmp(k, "ryu_data")) dst = c->ryu_data;
        else if (!strcmp(k, "docs")) dst = c->docs;
        else { WHY("上下文文件 %s 第 %d 行：不认的键「%s」", c->ctx_path, lineno, k); fclose(f); return -1; }
        if (!is_path) {
            if (!id_ok(v) || strlen(v) >= sizeof c->game_id) { WHY("上下文文件 %s 第 %d 行：%s 只收 [A-Za-z0-9._-]、≤127 字", c->ctx_path, lineno, k); fclose(f); return -1; }
            strcpy(dst, v);
        } else if (abs_value(dst, v, exe_dir, home)) { WHY("上下文文件 %s 第 %d 行：%s 要绝对路径或 @bundle/ @home/ 前缀", c->ctx_path, lineno, k); fclose(f); return -1; }
    }
    fclose(f);
    if (version != 1) { WHY("上下文文件 %s：version 要 1（读到 %d）", c->ctx_path, version); return -1; }
    const char *miss = !c->game_id[0] ? "game_id" : !c->images[0] ? "images" : !c->module_dir[0] ? "module_dir" : !c->game_data[0] ? "game_data" : !c->docs[0] ? "docs" : NULL;
    if (miss) { WHY("上下文文件 %s 缺必填键 %s", c->ctx_path, miss); return -1; }
    if (!c->caps_dir[0]) put(c->caps_dir, c->module_dir);
    if (!c->ryu_data[0] && join(c->ryu_data, c->docs, "S2A/ryujinx")) { WHY("docs 太长"); return -1; }
    if (put(c->bundle_dir, exe_dir) || join(c->log_dir, home, "Documents")) { WHY("可执行文件目录或 HOME 太长"); return -1; }
    c->source = S2A_LCTX_FILE;
    return 0;
}

int s2a_launch_ctx_resolve(s2a_launch_ctx *c, const char *exe_dir, const char *home, const char *ctx_path, char *why, size_t why_n) {
    memset(c, 0, sizeof *c);
    if (why && why_n) why[0] = 0;
    if (!exe_dir || !*exe_dir) { WHY("没有可执行文件目录"); return -1; }
    if (!home || !*home) home = ".";
    int rc = ctx_path && *ctx_path ? resolve_file(c, exe_dir, home, ctx_path, why, why_n) : resolve_compat(c, exe_dir, home, why, why_n);
    if (rc) { char keep[sizeof c->ctx_path]; memcpy(keep, c->ctx_path, sizeof keep); memset(c, 0, sizeof *c); memcpy(c->ctx_path, keep, sizeof keep); }
    return rc;
}

// ---------- 多款容器（③）：布局判定与选游戏的纯解析 ----------
static int is_dir(const char *p) { struct stat st; return !stat(p, &st) && S_ISDIR(st.st_mode); }
static int is_file(const char *p) { struct stat st; return !stat(p, &st) && S_ISREG(st.st_mode); }
int s2a_launch_ctx_is_container_dir(const char *b) {
    char p[S2A_LCTX_PATH];
    if (!b || !*b) return 0;
    if (join(p, b, "s2a_catalogue.json") || !is_file(p)) return 0;
    return !join(p, b, "Games") && is_dir(p);
}
// 清单里有没有这款：逐个找键 "title_id" 后的字符串值比对（title_id 是 16 位十六进制，不含转义；值里有反斜杠的条目不认）。
//   界面（S2ArmShellHost Catalogue.swift）读同一份清单；这里只核成员，不判 state（界面只对 playable 放 Play）
static int catalogue_has(const char *path, const char *gid, char *why, size_t why_n) {
    FILE *f = fopen(path, "r");
    if (!f) { WHY("游戏清单 %s 打不开（errno %d）", path, errno); return -1; }
    enum { CAP = 4 << 20 }; char *buf = malloc(CAP + 1); size_t n = buf ? fread(buf, 1, CAP + 1, f) : 0; fclose(f);
    if (!buf) { WHY("游戏清单：内存不够"); return -1; }
    if (n > CAP) { free(buf); WHY("游戏清单 %s 超过 4 MB", path); return -1; }
    buf[n] = 0; size_t gl = strlen(gid); int hit = 0;
    for (char *k = buf; !hit && (k = strstr(k, "\"title_id\"")); ) {
        char *v = k + 10; k = v;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v++ != ':') continue;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v++ != '"') continue;
        char *e = v; while (*e && *e != '"' && *e != '\\') e++;
        hit = *e == '"' && (size_t)(e - v) == gl && !memcmp(v, gid, gl);
    }
    free(buf);
    return hit;
}
int s2a_launch_ctx_resolve_game(s2a_launch_ctx *c, const char *b, const char *home, const char *gid, char *why, size_t why_n) {
    memset(c, 0, sizeof *c);
    if (why && why_n) why[0] = 0;
    if (!b || !*b) { WHY("没有 App 包目录"); return -1; }
    if (!home || !*home) home = ".";
    // gid 进路径（Games/<gid>、S2AImages-<gid>.dylib、Documents/games/<gid>）：只收 [A-Za-z0-9._-]、不以 . 开头（挡 .. 与隐藏目录）
    if (!gid || !id_ok(gid) || gid[0] == '.' || strlen(gid) >= sizeof c->game_id) { WHY("游戏编号「%s」不合规（只收 [A-Za-z0-9._-]、不以 . 开头、≤127 字）", gid ? gid : ""); return -1; }
    char p[S2A_LCTX_PATH], rel[300];
    if (join(p, b, "s2a_catalogue.json")) { WHY("App 包目录太长"); return -1; }
    int has = catalogue_has(p, gid, why, why_n);
    if (has < 0) return -1;
    if (!has) { WHY("游戏 %s 不在本包游戏清单 %s 里", gid, p); return -1; }
    snprintf(rel, sizeof rel, "Games/%s", gid);
    if (join(c->module_dir, b, rel) || !is_dir(c->module_dir)) { WHY("游戏 %s 的随行目录 %s 不在", gid, c->module_dir); memset(c, 0, sizeof *c); return -1; }
    snprintf(rel, sizeof rel, "Frameworks/S2AImages-%s.dylib", gid);
    if (join(c->images, b, rel) || !is_file(c->images)) { WHY("游戏 %s 的镜像包 %s 不在", gid, c->images); memset(c, 0, sizeof *c); return -1; }
    char hd[S2A_LCTX_PATH]; snprintf(rel, sizeof rel, "games/%s", gid);
    // 资源包根：Library/Application Support/S2Arm/games/<游戏号>/资源包（s2a_docs.h s2a_pack_root，v0.3.0 挪出 Documents）；存档仍在本款文档根下
    if (join(hd, home, "Documents") || join(c->docs, hd, rel) || s2a_pack_root(c->game_data, sizeof c->game_data, c->docs) >= (int)sizeof c->game_data
        || join(c->ryu_data, c->docs, "S2A/ryujinx")
        || put(c->caps_dir, c->module_dir) || put(c->bundle_dir, b) || put(c->log_dir, hd)) { WHY("HOME 或 App 包目录太长"); memset(c, 0, sizeof *c); return -1; }
    strcpy(c->game_id, gid);
    c->source = S2A_LCTX_CONTAINER;
    return 0;
}

// ---------- 进程内状态：定模式（一次）→ 冻结（单款：构造期第一次取；容器：选游戏时）----------
static s2a_launch_ctx g_ctx; static _Atomic int g_ok; static char g_err[600];
static char g_bundle[S2A_LCTX_PATH]; static int g_container;
static pthread_mutex_t g_sel_mu = PTHREAD_MUTEX_INITIALIZER; static int g_selected;
static int export_env(void) {   // 冻结后的四个根写进进程环境（覆盖起局方旧值）；兼容来源不调
    static const struct { const char *k; size_t off; } ex[] = {
        {"S2A_GAME_DATA", offsetof(s2a_launch_ctx, game_data)}, {"S2A_DOCS", offsetof(s2a_launch_ctx, docs)},
        {"S2A_RYU_DATA", offsetof(s2a_launch_ctx, ryu_data)}, {"S2A_LAUNCH_GAME_ID", offsetof(s2a_launch_ctx, game_id)}};
    for (size_t i = 0; i < sizeof ex / sizeof ex[0]; i++) {
        const char *v = (const char *)&g_ctx + ex[i].off, *was = getenv(ex[i].k);
        if (was && strcmp(was, v)) LOG("启动上下文：%s 起局环境另有值，按上下文覆盖", ex[i].k);
        if (setenv(ex[i].k, v, 1)) { snprintf(g_err, sizeof g_err, "启动上下文：%s 写不进环境（errno %d）", ex[i].k, errno); return -1; }
    }
    return 0;
}
static void decide(void) {
    char exe[S2A_LCTX_PATH]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) { snprintf(g_err, sizeof g_err, "取不到可执行文件路径"); return; }
    char *sl = strrchr(exe, '/'); if (sl) *sl = 0;
    put(g_bundle, exe);
    const char *ctx = getenv("S2A_LAUNCH_CTX");
    if (!(ctx && *ctx) && s2a_launch_ctx_is_container_dir(g_bundle)) {   // ③ 容器：此刻不冻结，等 s2a_launch_ctx_select
        g_container = 1;
        snprintf(g_err, sizeof g_err, "多款容器还没选游戏：s2a_launch_ctx_select 之前不许读游戏相关值");
        LOG("启动上下文：多款容器（%s 有 s2a_catalogue.json 与 Games/），构造期不冻结，等玩家选游戏", g_bundle);
        return;
    }
    if (s2a_launch_ctx_resolve(&g_ctx, g_bundle, getenv("HOME"), ctx, g_err, sizeof g_err)) return;
    if (g_ctx.source == S2A_LCTX_FILE) {   // 文件来源写四个根进环境；兼容来源不写任何环境变量，各读者照旧取缺省（行为同改造前）
        if (export_env()) return;
        LOG("启动上下文：%s（游戏 %s%s%s），模块 %s，镜像包 %s，资源包 %s，文档 %s", g_ctx.ctx_path, g_ctx.game_id, g_ctx.build_id[0] ? " 构建 " : "", g_ctx.build_id,
            g_ctx.module_dir, g_ctx.images, g_ctx.game_data, g_ctx.docs);
    }
    atomic_store(&g_ok, 1);
}
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
const s2a_launch_ctx *s2a_launch_ctx_get(void) {
    pthread_once(&g_once, decide);
    return atomic_load(&g_ok) ? &g_ctx : NULL;
}
const char *s2a_launch_ctx_error(void) { return s2a_launch_ctx_get() ? NULL : g_err; }
int s2a_launch_ctx_container(void) { pthread_once(&g_once, decide); return g_container; }
const char *s2a_launch_ctx_bundle_dir(void) { pthread_once(&g_once, decide); return g_bundle; }

static int g_sel_kind;   // 上一次 s2a_launch_ctx_select 被拒的类别（S2A_SELECT_*）：库界面按它给玩家说人话，原文只进日志
int s2a_launch_ctx_select_kind(void) { return g_sel_kind; }
const char *s2a_launch_ctx_select(const char *gid) {
    static char why[700];
    pthread_once(&g_once, decide);
    g_sel_kind = S2A_SELECT_OTHER;
    if (!g_container) return "不是多款容器（包根没有 s2a_catalogue.json 与 Games/，或设了 S2A_LAUNCH_CTX）：启动上下文已在构造期定好，不能再选游戏";
    pthread_mutex_lock(&g_sel_mu);
    const char *r = NULL;
    if (g_selected) { snprintf(why, sizeof why, "本进程已经选过游戏 %s，同一进程不再起第二款：请关掉 App 重新打开", g_ctx.game_id); r = why; goto out; }
    s2a_launch_ctx c; char w[600];
    if (s2a_launch_ctx_resolve_game(&c, g_bundle, getenv("HOME"), gid, w, sizeof w)) { snprintf(why, sizeof why, "%s", w); g_sel_kind = S2A_SELECT_APP_INCOMPLETE; r = why; goto out; }
    // 本款文档根第一次用时还不在（存档 / wire / 加载页标记各自只建最后一级）：逐级建好
    for (char *q = c.docs + 1; ; q++) {
        if (*q && *q != '/') continue;
        char k = *q; *q = 0; int bad = mkdir(c.docs, 0755) && errno != EEXIST; *q = k;
        if (bad) { snprintf(why, sizeof why, "建不了游戏 %s 的文档根 %s（errno %d）", c.game_id, c.docs, errno); g_sel_kind = S2A_SELECT_STORAGE; r = why; goto out; }
        if (!k) break;
    }
    g_ctx = c;
    if (export_env()) { snprintf(why, sizeof why, "%s", g_err); memset(&g_ctx, 0, sizeof g_ctx); r = why; goto out; }
    g_selected = 1; atomic_store(&g_ok, 1);
    LOG("启动上下文：多款容器选了游戏 %s，模块 %s，镜像包 %s，资源包 %s，文档 %s", c.game_id, c.module_dir, c.images, c.game_data, c.docs);
out:
    pthread_mutex_unlock(&g_sel_mu);
    if (r) LOG("【红】启动上下文：选游戏 %s 被拒：%s", gid ? gid : "", r);
    return r;
}

const char *s2a_launch_ctx_begin(void) {
    static atomic_int started;
    if (atomic_fetch_add(&started, 1)) return "本进程已经起过一局游戏，同一进程不再起第二局：请从后台划掉 App 后重新打开";
    return NULL;
}

const char *s2a_launch_ctx_game_env_dir(const char *proc_docs) {
    const s2a_launch_ctx *c = s2a_launch_ctx_get();
    if (!c || c->source == S2A_LCTX_COMPAT) return NULL;
    if (proc_docs && !strcmp(c->docs, proc_docs)) return NULL;   // 本款文档根就是进程文档根：构造期已读过
    return c->docs;
}
