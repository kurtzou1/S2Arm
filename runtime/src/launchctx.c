// 启动上下文（LaunchContext）：定义与口径见 runtime/include/s2a_launch_ctx.h。本文件只做解析、冻结（单款构造期 / 多款容器选游戏时）、一进程一款与每款 env.txt，
//   各读者（host_main.c / loader.c / vawin.c / ios/settings.m）取冻结后的结构，C# 与其余原生读者经 S2A_GAME_DATA / S2A_DOCS / S2A_RYU_DATA 取。
#include "native.h"
#include "s2a_launch_ctx.h"
#include "s2a_docs.h"   // 多款容器每款资源包根（s2a_pack_root）
#include "s2a_host_abi.h"
#include <dlfcn.h>                       // s2a_imgpack_open：宿主才链（imgpack.c），单测不链 → 不预注册   // S2A_HOST_ABI：宿主读产物的约定号（选游戏时核）
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/clonefile.h>
#include <unistd.h>
#include <dirent.h>
#include <ftw.h>
#include <time.h>
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
    if (join(hd, home, S2A_CONTAINER_DOCS_REL)) { WHY("HOME 太长"); return -1; }
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
    if (put(c->bundle_dir, exe_dir) || join(c->log_dir, home, S2A_CONTAINER_DOCS_REL)) { WHY("可执行文件目录或 HOME 太长"); return -1; }
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
    // 只看 s2a_catalogue.json（只有多款容器的组装才写它，pack/ship_ext.py container）：0.6.0 通用壳「只装壳」的容器清单只有 shell_id、games 为空，
    //   也不带 Games/（各款的程序与随行表都在程序包 program/ 里）。原先还要求有 Games/，只装壳的容器会被当成单款包起，FATAL
    return !join(p, b, "s2a_catalogue.json") && is_file(p);
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
// 独立 App（一 App 一游戏，0.6.3，pack/jobs/install.py put_app）：清单里只有一款（各 title_id 值都相同）、且这款的程序库就在 App 包里
//   （Frameworks/S2AImages-<号>.dylib 是文件、Games/<号>/ 是目录）→ 回 1、gid 写这款；否则 0。通用壳的程序在 App 外，包里没有程序库，不会命中
int s2a_launch_ctx_single_game(const char *b, char *gid, size_t gid_n) {
    char p[S2A_LCTX_PATH], one[64] = ""; int bad = 0;
    if (!b || !*b || !gid || !gid_n || join(p, b, "s2a_catalogue.json")) return 0;
    FILE *f = fopen(p, "r"); if (!f) return 0;
    enum { CAP = 4 << 20 }; char *buf = malloc(CAP + 1); size_t n = buf ? fread(buf, 1, CAP + 1, f) : 0; fclose(f);
    if (!buf || n > CAP) { free(buf); return 0; }
    buf[n] = 0;
    for (char *k = buf; !bad && (k = strstr(k, "\"title_id\"")); ) {
        char *v = k + 10; k = v;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v++ != ':') continue;
        while (*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') v++;
        if (*v++ != '"') continue;
        char *e = v; while (*e && *e != '"' && *e != '\\') e++;
        size_t l = (size_t)(e - v);
        if (*e != '"' || !l || l >= sizeof one) { bad = 1; break; }
        if (!*one) { memcpy(one, v, l); one[l] = 0; }
        else if (strlen(one) != l || memcmp(one, v, l)) bad = 1;   // 第二款 → 多款容器
    }
    free(buf);
    if (bad || !*one || strchr(one, '/') || *one == '.') return 0;
    char rel[160];
    snprintf(rel, sizeof rel, "Frameworks/S2AImages-%s.dylib", one);
    if (join(p, b, rel) || !is_file(p)) return 0;
    snprintf(rel, sizeof rel, "Games/%s", one);
    if (join(p, b, rel) || !is_dir(p)) return 0;
    if (strlen(one) >= gid_n) return 0;
    memcpy(gid, one, strlen(one) + 1);
    return 1;
}
// ---------- 宿主约定号核对（11-16）：清单 JSON 里找这款的对象，取 host_abi ----------
// 跳过一个 JSON 字符串（p 指向开头的引号）→ 结尾引号之后；没闭合 → NULL
static const char *skip_str(const char *p, const char *e) {
    for (p++; p < e; p++) { if (*p == '\\') { p++; continue; } if (*p == '"') return p + 1; }
    return NULL;
}
static const char *skip_ws(const char *p, const char *e) { while (p < e && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++; return p; }
// 对象 [s, e)（s 指向 {）里本层的键 key 的值的开头；没有 → NULL。嵌套对象 / 数组里的同名键不算
static const char *obj_value(const char *s, const char *e, const char *key) {
    size_t kl = strlen(key); int depth = 0;
    for (const char *p = s; p < e; ) {
        if (*p == '"') {
            const char *q = skip_str(p, e); if (!q) return NULL;
            if (depth == 1) { const char *c = skip_ws(q, e); if (c < e && *c == ':' && (size_t)(q - p - 2) == kl && !memcmp(p + 1, key, kl)) return skip_ws(c + 1, e); }
            p = q; continue;
        }
        if (*p == '{' || *p == '[') depth++;
        else if (*p == '}' || *p == ']') depth--;
        p++;
    }
    return NULL;
}
// 整份清单里 title_id == gid 的那个对象 [*os, *oe)；回 1 找到、0 没这款
static int find_obj(const char *buf, size_t n, const char *gid, const char **os, const char **oe) {
    const char *e = buf + n, *st[32]; int sp = 0; size_t gl = strlen(gid);
    for (const char *p = buf; p < e; ) {
        if (*p == '"') { p = skip_str(p, e); if (!p) return 0; continue; }
        if (*p == '{') { if (sp < 32) st[sp] = p; sp++; }
        else if (*p == '}' && sp > 0) {
            sp--;
            if (sp < 32) { const char *v = obj_value(st[sp], p + 1, "title_id");
                if (v && *v == '"' && v + 1 + gl < e && !memcmp(v + 1, gid, gl) && v[1 + gl] == '"') { *os = st[sp]; *oe = p + 1; return 1; } }
        }
        p++;
    }
    return 0;
}
// 对象里字符串键 key 的值（不含转义的简单串）拷进 out；没有 / 不是串 / 放不下 → 0
static int obj_str(const char *s, const char *e, const char *key, char *out, size_t n) {
    const char *v = obj_value(s, e, key); if (!v || *v != '"') return 0;
    const char *q = v + 1; while (q < e && *q != '"' && *q != '\\') q++;
    if (q >= e || *q != '"' || (size_t)(q - v - 1) >= n) return 0;
    memcpy(out, v + 1, (size_t)(q - v - 1)); out[q - v - 1] = 0; return 1;
}
// 整份清单里 title_id == gid 的那个对象 → 它的 host_abi（没记 = 1，记成非数字 = -1）；回 1 找到、0 没这款
static int find_abi(const char *buf, size_t n, const char *gid, int *abi) {
    const char *e = buf + n, *st[32]; int sp = 0; size_t gl = strlen(gid);
    for (const char *p = buf; p < e; ) {
        if (*p == '"') { p = skip_str(p, e); if (!p) return 0; continue; }
        if (*p == '{') { if (sp < 32) st[sp] = p; sp++; }
        else if (*p == '}' && sp > 0) {
            sp--;
            if (sp < 32) {
                const char *v = obj_value(st[sp], p + 1, "title_id");
                if (v && *v == '"' && v + 1 + gl < e && !memcmp(v + 1, gid, gl) && v[1 + gl] == '"') {
                    const char *a = obj_value(st[sp], p + 1, "host_abi");
                    if (!a) *abi = 1;
                    else { char *end; long x = strtol(a, &end, 10); *abi = end > a && x >= 0 && x < 1000000 ? (int)x : -1; }
                    return 1;
                }
            }
        }
        p++;
    }
    return 0;
}
static char *slurp(const char *path, size_t *n, char *why, size_t why_n) {
    FILE *f = fopen(path, "r");
    if (!f) { WHY("清单 %s 打不开（errno %d）", path, errno); return NULL; }
    enum { CAP = 4 << 20 }; char *buf = malloc(CAP + 1); *n = buf ? fread(buf, 1, CAP + 1, f) : 0; fclose(f);
    if (!buf) { WHY("清单：内存不够"); return NULL; }
    if (*n > CAP) { free(buf); WHY("清单 %s 超过 4 MB", path); return NULL; }
    buf[*n] = 0; return buf;
}
int s2a_host_abi_check(const char *program_catalogue, const char *app_catalogue, const char *gid, int *have, char *why, size_t why_n) {
    if (why && why_n) why[0] = 0;
    int abi = 1; size_t n; char *buf;
    if (program_catalogue && *program_catalogue && is_file(program_catalogue)) {   // 程序包自带的清单：随程序走，以它为准；不是这一款 = 清单和程序不是一套
        if (!(buf = slurp(program_catalogue, &n, why, why_n))) return -1;
        int hit = find_abi(buf, n, gid, &abi); free(buf);
        if (!hit) { WHY("程序清单 %s 里没有 %s：清单和程序不是同一次出的", program_catalogue, gid); return -1; }
    } else if (app_catalogue && *app_catalogue) {   // 程序还在 App 里：看 App 包根清单这款的条目；没有这款同「没记」（成员另由 catalogue_has 核）
        if (!(buf = slurp(app_catalogue, &n, why, why_n))) return -1;
        find_abi(buf, n, gid, &abi); free(buf);
    }
    if (have) *have = abi;
    return abi == S2A_HOST_ABI ? 0 : 1;
}
int s2a_program_catalogue_path(char *out, size_t n, const char *game_data) {
    const char *sl = game_data ? strrchr(game_data, '/') : NULL;
    if (!sl || (size_t)(sl - game_data) + sizeof "/program/catalogue.json" > n) return -1;
    snprintf(out, n, "%.*s/program/catalogue.json", (int)(sl - game_data), game_data);
    return 0;
}

// 本款程序包（game_data = 这款资源包根）：清单不在 → 0；在 → 写随行目录 <程序包>/Games/<gid> 与镜像包 <程序包>/<清单 image>、回 1；
//   清单读不了 / 没这款 / image 不合规 / 缺件 → -1（why 写原因）。module_dir、images 各 S2A_LCTX_PATH 字节
static int program_paths(const char *game_data, const char *gid, char *module_dir, char *images, char *why, size_t why_n) {
    char pc[S2A_LCTX_PATH], rel[300], img[160] = ""; size_t n;
    if (s2a_program_catalogue_path(pc, sizeof pc, game_data) || !is_file(pc)) return 0;
    char *buf = slurp(pc, &n, why, why_n);
    if (!buf) return -1;
    char dir[160] = "";
    const char *os, *oe; int hit = find_obj(buf, n, gid, &os, &oe), ok = hit && obj_str(os, oe, "image", img, sizeof img);
    if (hit) obj_str(os, oe, "dir", dir, sizeof dir);
    free(buf);
    if (!hit) { WHY("程序包清单 %s 里没有 %s：清单和程序不是同一次出的", pc, gid); return -1; }
    if (!ok || !id_ok(img) || img[0] == '.') { WHY("程序包清单 %s 的 image 不合规（只收 [A-Za-z0-9._-]、不以 . 开头）", pc); return -1; }
    // 写入规则（0.6.0 通用壳，cmdr 方案「写入规则」）：每个写入方把整份程序写进自己的版本目录 program/v-<sha16>-<写入方>/，最后改名覆盖 catalogue.json 换上，
    //   清单的 dir 指向这一份。dir 不合规（只收 v- 开头的 [A-Za-z0-9._-]）→ 拒；没写 dir（第 1 段的布局）→ 程序直接在 program/ 下
    if (dir[0] && (strncmp(dir, "v-", 2) || !id_ok(dir) || strstr(dir, ".."))) { WHY("程序包清单 %s 的 dir「%s」不合规（只收 v- 开头的 [A-Za-z0-9._-]）", pc, dir); return -1; }
    char *sl = strrchr(pc, '/'); *sl = 0;   // pc → 程序包目录
    if (dir[0] && (strlen(pc) + 1 + strlen(dir) >= sizeof pc)) { WHY("程序包路径太长"); return -1; }
    if (dir[0]) { strcat(pc, "/"); strcat(pc, dir); }   // → 清单指着的那个版本目录
    snprintf(rel, sizeof rel, "Games/%s", gid);
    if (join(module_dir, pc, rel) || !is_dir(module_dir)) { WHY("游戏 %s 的程序包随行目录 %s 不在", gid, module_dir); return -1; }
    if (join(images, pc, img) || !is_file(images)) { WHY("游戏 %s 的程序包镜像包 %s 不在", gid, images); return -1; }
    return 1;
}
// ---- 程序包版本目录清理（0.6.0 通用壳写入规则）：电脑端换上新版后不删旧版本目录（App 可能正开着那一版），由 App 启动时清。
//   清：没被本款 catalogue.json 的 dir 指着、且目录里最新一个文件的修改时间离现在超过 1 小时的 program/v-* 目录（大文件边写边刷新修改时间，
//   这样避开电脑正在推的那份）；catalogue.json.*.tmp 同一判据（每次推都会被覆盖，留着的是推断了的）。返回删掉的条目数；纯文件操作，单测 t_launchctx
static time_t g_gc_newest;
static int gc_newest_one(const char *p, const struct stat *st, int flag, struct FTW *w) { (void)p; (void)flag; (void)w; if (st->st_mtime > g_gc_newest) g_gc_newest = st->st_mtime; return 0; }
static int gc_rm_one(const char *p, const struct stat *st, int flag, struct FTW *w) { (void)st; (void)w; return flag == FTW_DP ? rmdir(p) : unlink(p); }
#define S2A_PROGRAM_GC_IDLE (60 * 60)
// 程序包款的随行目录快照（0.6.0 写入规则的双保险）：选中游戏时把 program/<dir>/Games/<号>/ 用 APFS 克隆拍一份到本进程临时目录
//   （<HOME>/tmp/s2a-mod-<号>-<pid>，瞬间完成、不占空间），这局的模块目录 / 能力清单目录改指快照。电脑端换上新版后删旧版本目录，
//   正在玩的这局读的是快照：设置页再读 s2a_caps.tsv / cpatch.tsv / sgrade_state.json 也读得到。克隆不了（不是 APFS 等）→ 原样用原目录、记一行黄。
//   旧进程留下的快照由 s2a_program_gc 清。成功写 out（S2A_LCTX_PATH）回 0
int s2a_program_snapshot(const char *home, const char *gid, const char *module_dir, char *out) {
    char t[S2A_LCTX_PATH];
    if (!module_dir || !*module_dir || !gid || !id_ok(gid) || snprintf(t, sizeof t, "%s/tmp", home && *home ? home : ".") >= (int)sizeof t) return -1;
    mkdir(t, 0755);
    if (snprintf(out, S2A_LCTX_PATH, "%s/s2a-mod-%s-%d", t, gid, (int)getpid()) >= S2A_LCTX_PATH) return -1;
    if (is_dir(out)) { g_gc_newest = 0; nftw(out, gc_rm_one, 16, FTW_DEPTH | FTW_PHYS); }   // 同 pid 的旧快照（pid 复用）
#if defined(__APPLE__)
    if (clonefile(module_dir, out, 0)) { LOG("【黄】启动上下文：随行目录 %s 拍快照失败（errno %d），这局直接用原目录（电脑端运行中删旧版时设置页可能读不到）", module_dir, errno); out[0] = 0; return -1; }
    return 0;
#else
    out[0] = 0; return -1;
#endif
}
int s2a_program_gc(const char *home, time_t now) {
    char root[S2A_LCTX_PATH]; int removed = 0;
    {   // 旧进程留下的随行目录快照（s2a_program_snapshot）：<HOME>/tmp/s2a-mod-<号>-<pid>，不是本进程的都删
        char t[S2A_LCTX_PATH]; snprintf(t, sizeof t, "%s/tmp", home && *home ? home : ".");
        DIR *td = opendir(t); struct dirent *te; char mine[64]; snprintf(mine, sizeof mine, "-%d", (int)getpid());
        while (td && (te = readdir(td))) { size_t L = strlen(te->d_name), M = strlen(mine);
            if (strncmp(te->d_name, "s2a-mod-", 8) || (L > M && !strcmp(te->d_name + L - M, mine))) continue;
            char sp[S2A_LCTX_PATH]; if (snprintf(sp, sizeof sp, "%s/%s", t, te->d_name) >= (int)sizeof sp) continue;
            if (!nftw(sp, gc_rm_one, 16, FTW_DEPTH | FTW_PHYS)) removed++; }
        if (td) closedir(td); }
    if (s2a_program_games_root(root, sizeof root, home)) return removed;
    DIR *g = opendir(root); if (!g) return removed;
    struct dirent *e;
    while ((e = readdir(g))) {
        if (e->d_name[0] == '.' || !id_ok(e->d_name)) continue;
        char pd[S2A_LCTX_PATH], cat[S2A_LCTX_PATH], dir[160] = "";
        if (snprintf(pd, sizeof pd, "%s/%s/program", root, e->d_name) >= (int)sizeof pd || !is_dir(pd)) continue;
        snprintf(cat, sizeof cat, "%s/catalogue.json", pd);
        if (is_file(cat)) { size_t n; char w[200]; char *buf = slurp(cat, &n, w, sizeof w); const char *os, *oe;
            if (buf && find_obj(buf, n, e->d_name, &os, &oe)) obj_str(os, oe, "dir", dir, sizeof dir);
            free(buf); }
        DIR *d = opendir(pd); if (!d) continue;
        struct dirent *v;
        while ((v = readdir(d))) {
            int vdir = !strncmp(v->d_name, "v-", 2), tmp = !strncmp(v->d_name, "catalogue.json.", 15) && strlen(v->d_name) > 19 && !strcmp(v->d_name + strlen(v->d_name) - 4, ".tmp");
            if (!vdir && !tmp) continue;
            if (vdir && dir[0] && !strcmp(v->d_name, dir)) continue;   // 清单正指着的这一版
            char vp[S2A_LCTX_PATH]; if (snprintf(vp, sizeof vp, "%s/%s", pd, v->d_name) >= (int)sizeof vp) continue;
            g_gc_newest = 0; struct stat st;
            if (vdir) { if (!is_dir(vp) || nftw(vp, gc_newest_one, 16, FTW_PHYS)) continue; }
            else { if (stat(vp, &st)) continue; g_gc_newest = st.st_mtime; }
            if (now - g_gc_newest <= S2A_PROGRAM_GC_IDLE) continue;   // 一小时内还有写入：可能是电脑正在推的那份，不动
            int r = vdir ? nftw(vp, gc_rm_one, 16, FTW_DEPTH | FTW_PHYS) : unlink(vp);
            LOG("程序包清理：%s %s/%s（%s，最新文件 %ld 分钟前）", r ? "【黄】删不掉" : "删掉", e->d_name, v->d_name, vdir ? "没被清单指着的版本目录" : "推断了留下的临时清单", (long)((now - g_gc_newest) / 60));
            if (!r) removed++;
        }
        closedir(d);
    }
    closedir(g);
    return removed;
}
int s2a_program_game_paths(const char *home, const char *gid, char *module_dir, char *images, char *why, size_t why_n) {
    char hd[S2A_LCTX_PATH], docs[S2A_LCTX_PATH], gd[S2A_LCTX_PATH], rel[300];
    if (!gid || !id_ok(gid) || gid[0] == '.' || strlen(gid) > 200) { WHY("游戏编号「%s」不合规", gid ? gid : ""); return -1; }
    snprintf(rel, sizeof rel, "games/%s", gid);
    if (join(hd, home && *home ? home : ".", S2A_CONTAINER_DOCS_REL) || join(docs, hd, rel) || s2a_pack_root(gd, sizeof gd, docs) >= (int)sizeof gd) { WHY("HOME 太长"); return -1; }
    return program_paths(gd, gid, module_dir, images, why, why_n);
}
int s2a_program_games_root(char *out, size_t n, const char *home) {
    char hd[S2A_LCTX_PATH], docs[S2A_LCTX_PATH];   // 按一款占位编号 0 的资源包根 <根>/0/资源包 退两级，和 s2a_pack_root 同一套位置判定（备用位置在就是它）
    if (join(hd, home && *home ? home : ".", S2A_CONTAINER_DOCS_REL) || join(docs, hd, "games/0")) return -1;
    int r = s2a_pack_root(out, n, docs); if (r <= 0 || r >= (int)n) return -1;
    static const char tail[] = "/0/资源包"; size_t l = strlen(out), t = sizeof tail - 1;
    if (l <= t || strcmp(out + l - t, tail)) return -1;
    out[l - t] = 0; return 0;
}
int s2a_launch_ctx_resolve_game(s2a_launch_ctx *c, const char *b, const char *home, const char *gid, char *why, size_t why_n) {
    memset(c, 0, sizeof *c);
    if (why && why_n) why[0] = 0;
    if (!b || !*b) { WHY("没有 App 包目录"); return -1; }
    if (!home || !*home) home = ".";
    // gid 进路径（Games/<gid>、S2AImages-<gid>.dylib、Documents/games/<gid>）：只收 [A-Za-z0-9._-]、不以 . 开头（挡 .. 与隐藏目录）
    if (!gid || !id_ok(gid) || gid[0] == '.' || strlen(gid) >= sizeof c->game_id) { WHY("游戏编号「%s」不合规（只收 [A-Za-z0-9._-]、不以 . 开头、≤127 字）", gid ? gid : ""); return -1; }
    char p[S2A_LCTX_PATH], rel[300], hd[S2A_LCTX_PATH];
    // 文档根 / 资源包根先算：资源包根：Library/Application Support/S2Arm/games/<游戏号>/资源包（s2a_docs.h s2a_pack_root，v0.3.0 挪出 Documents）；存档仍在本款文档根下
    snprintf(rel, sizeof rel, "games/%s", gid);
    if (join(hd, home, S2A_CONTAINER_DOCS_REL) || join(c->docs, hd, rel) || s2a_pack_root(c->game_data, sizeof c->game_data, c->docs) >= (int)sizeof c->game_data) {
        WHY("HOME 太长"); memset(c, 0, sizeof *c); return -1; }
    // 通用壳（11-16）：资源包根旁有程序包 program/catalogue.json → 这款的程序（镜像包 + 随行目录）从程序包取，App 包里没有它也行；
    //   清单是写入的最后一步（电脑端先写 dylib、Games/，最后改名写清单），清单在 = 程序包写完。没有清单 → 取 App 包内。
    // App 包里自带这款的镜像包（独立 App，一 App 一游戏，0.6.3）→ 一律取包内、不看程序包：分发 / ad hoc 签的 App 只认包内的程序，
    //   显式描述文件下独立 App 与通用壳同包名、沙盒里可能留着通用壳推过的程序包，取了它就回到包外映射被系统拒。包内这一支是独立 App 的正路，不许删
    snprintf(rel, sizeof rel, "Frameworks/S2AImages-%s.dylib", gid);
    int in_app = !join(p, b, rel) && is_file(p);
    int fp = in_app ? 0 : program_paths(c->game_data, gid, c->module_dir, c->images, why, why_n);
    if (fp < 0) { memset(c, 0, sizeof *c); return -1; }
    if (fp) {
        c->from_program = 1;
    } else {
        if (join(p, b, "s2a_catalogue.json")) { WHY("App 包目录太长"); memset(c, 0, sizeof *c); return -1; }
        int has = catalogue_has(p, gid, why, why_n);
        if (has < 0) { memset(c, 0, sizeof *c); return -1; }
        if (!has) { WHY("游戏 %s 不在本包游戏清单 %s 里", gid, p); memset(c, 0, sizeof *c); return -1; }
        snprintf(rel, sizeof rel, "Games/%s", gid);
        if (join(c->module_dir, b, rel) || !is_dir(c->module_dir)) { WHY("游戏 %s 的随行目录 %s 不在", gid, c->module_dir); memset(c, 0, sizeof *c); return -1; }
        snprintf(rel, sizeof rel, "Frameworks/S2AImages-%s.dylib", gid);
        if (join(c->images, b, rel) || !is_file(c->images)) { WHY("游戏 %s 的镜像包 %s 不在", gid, c->images); memset(c, 0, sizeof *c); return -1; }
    }
    if (join(c->ryu_data, c->docs, "S2A/ryujinx")
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
// selfsign.c：手机端自签真机验证（开发用环境变量，没设就直接返回）。这里给弱的空实现：链了 selfsign.c 的（App / 宿主）用它的强定义，
//   只链 launchctx.c 的单测和工具不用跟着链 Security
__attribute__((weak)) void s2a_selfsign_probe(void) {}
// 校验没过、照常继续（11-17 维护者，waived.c）：打【黄】并记下，FATAL / 崩溃时补报
static void waive(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void waive(const char *fmt, ...) {
    char m[700]; va_list ap; va_start(ap, fmt); vsnprintf(m, sizeof m, fmt, ap); va_end(ap);
    void (*f)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "s2a_check_waived");
    if (f) f(m); else LOG("【黄】校验没过，照常继续：%s", m);
}
static void decide(void) {
    s2a_selfsign_probe();
    char exe[S2A_LCTX_PATH]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) { snprintf(g_err, sizeof g_err, "取不到可执行文件路径"); return; }
    char *sl = strrchr(exe, '/'); if (sl) *sl = 0;
    put(g_bundle, exe);
    const char *ctx = getenv("S2A_LAUNCH_CTX");
    if (!(ctx && *ctx) && s2a_launch_ctx_is_container_dir(g_bundle)) {   // ③ 容器：此刻不冻结，等 s2a_launch_ctx_select
        g_container = 1;
        snprintf(g_err, sizeof g_err, "多款容器还没选游戏：s2a_launch_ctx_select 之前不许读游戏相关值");
        LOG("启动上下文：多款容器（%s 有 s2a_catalogue.json），构造期不冻结，等玩家选游戏", g_bundle);
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

int s2a_launch_ctx_game_needs_update(const char *gid) {
    pthread_once(&g_once, decide);
    if (!g_container) return 0;
    s2a_launch_ctx c; char w[600], prog[S2A_LCTX_PATH], app[S2A_LCTX_PATH];
    if (s2a_launch_ctx_resolve_game(&c, g_bundle, getenv("HOME"), gid, w, sizeof w) || join(app, g_bundle, "s2a_catalogue.json")) return 0;
    return s2a_host_abi_check(!c.from_program || s2a_program_catalogue_path(prog, sizeof prog, c.game_data) ? NULL : prog, app, gid, NULL, w, sizeof w) == 1;
}

static int g_sel_kind;   // 上一次 s2a_launch_ctx_select 被拒的类别（S2A_SELECT_*）：库界面按它给玩家说人话，原文只进日志
int s2a_launch_ctx_select_kind(void) { return g_sel_kind; }
static uint64_t lctx_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull; }
const char *s2a_launch_ctx_select(const char *gid) {
    static char why[700];
    uint64_t t0 = lctx_ms();   // 选游戏耗时（点开始 → 选好），进末尾那行日志（11-19：去掉起局前整份程序库 SHA-256 前后对比用）
    pthread_once(&g_once, decide);
    g_sel_kind = S2A_SELECT_OTHER;
    if (!g_container) return "不是多款容器（包根没有 s2a_catalogue.json，或设了 S2A_LAUNCH_CTX）：启动上下文已在构造期定好，不能再选游戏";
    pthread_mutex_lock(&g_sel_mu);
    const char *r = NULL;
    if (g_selected) { snprintf(why, sizeof why, "本进程已经选过游戏 %s，同一进程不再起第二款：请关掉 App 重新打开", g_ctx.game_id); r = why; goto out; }
    s2a_launch_ctx c; char w[600];
    if (s2a_launch_ctx_resolve_game(&c, g_bundle, getenv("HOME"), gid, w, sizeof w)) { snprintf(why, sizeof why, "%s", w); g_sel_kind = S2A_SELECT_APP_INCOMPLETE; r = why; goto out; }
    {   // 宿主约定号（s2a_host_abi.h）：产物是按别的约定出的就不载入——不然改写器与运行时对不上，进游戏后静默崩。对不上 → 回游戏库标「要更新」
        char prog[S2A_LCTX_PATH], app[S2A_LCTX_PATH]; int have = 0;
        int k = join(app, g_bundle, "s2a_catalogue.json") ? -1 : s2a_host_abi_check(!c.from_program || s2a_program_catalogue_path(prog, sizeof prog, c.game_data) ? NULL : prog, app, gid, &have, w, sizeof w);
        // 11-17 维护者：校验不过不再整个拒绝，黄字提示照常进，之后出问题时报错带上这条（waived.c）
        if (k == 1) waive("游戏 %s 的程序按宿主约定号 %d 出，本宿主是 %d：版本不配，可能闪退，在电脑上重新出包 / 装到 iPhone 可解（ios_host_abi_mismatch）", gid, have, S2A_HOST_ABI);
        if (k < 0) waive("游戏 %s 的宿主约定号核不了：%s", gid, w[0] ? w : "App 包目录太长");
    }
    char rsw[300] = "";   // 重签没成的原因（如证书与 App 不是同一个团队）：签名最后本机不认时并进给玩家的那句
    if (c.from_program) {   // 起局按款重签（0.6.0 通用壳，ios/program_resign.m）：签名身份不是手机上现在这张 / 没签 → 当场用手机上的身份签好，路径改指新版本目录；
        //   做不了照旧用原程序库（原因进日志）。按名取（只链本文件的单测 / 工具没有它）
        int (*rs)(const char *, const char *, const char *, char *, char *, size_t, char *, size_t) =
            (int (*)(const char *, const char *, const char *, char *, char *, size_t, char *, size_t))dlsym(RTLD_DEFAULT, "s2a_program_resign_if_needed");
        if (rs) rs(getenv("HOME"), c.game_data, gid, c.module_dir, c.images, sizeof c.images, rsw, sizeof rsw);
    } else {   // 程序在 App 包里的款（独立 App）：在 LiveContainer 里同样要用它的证书签一份副本（D-HF6H，ios/program_resign.m s2a_bundle_image_resign_lc），不在里面原样用
        int (*rb)(const char *, const char *, const char *, char *, size_t, char *, size_t) =
            (int (*)(const char *, const char *, const char *, char *, size_t, char *, size_t))dlsym(RTLD_DEFAULT, "s2a_bundle_image_resign_lc");
        if (rb) rb(getenv("HOME"), c.game_data, gid, c.images, sizeof c.images, rsw, sizeof rsw);
    }
    {   // 程序签名（通用壳 11-16）：程序库要能被本机这份 App 注册签名 + 库校验（同团队）——物理上必须，进程只认登记过签名的代码页。
        //   原先这里还给整份程序库算 SHA-256 和清单 image_sha256 比（每次起局读完一两百 MB），核不过也只是黄字照常进，只剩花时间：11-19 维护者定
        //   起局前的完整性校验一律去掉，坏了让这一步失败、报清楚原因（文件不完整 / 格式不对 / 签名不认，imgpack.c）。注册在这里先做一次，
        //   进局后 s2a_imgpack_open 同一路径回同一个包（原先进局后 loader.c die「外置镜像包打不开」，App 无提示退回主屏，11-16 Duo 实测）
        int (*open_pk)(const char *, void **, char *, size_t) = (int (*)(const char *, void **, char *, size_t))dlsym(RTLD_DEFAULT, "s2a_imgpack_open");
        void *pk = NULL; int rc = c.from_program && open_pk ? open_pk(c.images, &pk, w, sizeof w) : 0;   // 只对程序包里的款：App 包里的款（0.6.0 前玩家手上全是这种）照旧进局后由装载器打开，行为同改造前
        if (rc == 3) {   // 注册签名失败（证书和手机身份相同、但签名格式老，如 Windows plumesign 签的程序库）：手机上有身份就当场强制重签一次，签好再注册；还不行才回游戏库
            int (*rf)(const char *, const char *, const char *, char *, char *, size_t, char *, size_t) =
                (int (*)(const char *, const char *, const char *, char *, char *, size_t, char *, size_t))dlsym(RTLD_DEFAULT, "s2a_program_resign_force");
            char rw[300] = "";
            int fr = rf ? rf(getenv("HOME"), c.game_data, gid, c.module_dir, c.images, sizeof c.images, rw, sizeof rw) : 0;
            if (fr == -1 && rw[0]) snprintf(rsw, sizeof rsw, "%s", rw);
            if (fr == 1) {
                char w0[600]; snprintf(w0, sizeof w0, "%s", w); pk = NULL; rc = open_pk(c.images, &pk, w, sizeof w);
                LOG("启动上下文：%s 的程序库注册签名失败（%s），已用手机上的签名身份重签 → 再注册%s", gid, w0, rc ? "仍失败" : "成功");
            }
        }
        if (rc == 3) { if (rsw[0]) snprintf(why, sizeof why, "ios_program_resign：游戏 %s 的程序库签名本机不认（%s），手机上也重签不了：%s", gid, w, rsw);
                       else snprintf(why, sizeof why, "ios_program_resign：游戏 %s 的程序库签名本机不认（%s）：要在电脑上重新签名这款", gid, w); g_sel_kind = S2A_SELECT_NEEDS_RESIGN; r = why; goto out; }   // 3 = S2A_IMG_ESIGN（runtime/src/imgpack.h）
        if (rc) { snprintf(why, sizeof why, "游戏 %s 的程序库坏了或不完整（%s）：在电脑上重新把这一款推到 iPhone", gid, w); g_sel_kind = S2A_SELECT_APP_INCOMPLETE; r = why; goto out; }
    }
    // 本款文档根第一次用时还不在（存档 / wire / 加载页标记各自只建最后一级）：逐级建好
    for (char *q = c.docs + 1; ; q++) {
        if (*q && *q != '/') continue;
        char k = *q; *q = 0; int bad = mkdir(c.docs, 0755) && errno != EEXIST; *q = k;
        if (bad) { snprintf(why, sizeof why, "建不了游戏 %s 的文档根 %s（errno %d）", c.game_id, c.docs, errno); g_sel_kind = S2A_SELECT_STORAGE; r = why; goto out; }
        if (!k) break;
    }
    if (c.from_program) { char snap[S2A_LCTX_PATH];   // 程序包款：随行目录拍快照，这局读快照（电脑端换上新版后删旧版本目录也不影响，见 s2a_program_snapshot）
        if (!s2a_program_snapshot(getenv("HOME"), gid, c.module_dir, snap)) { LOG("启动上下文：%s 的随行目录拍了快照 %s（原目录 %s）", gid, snap, c.module_dir); put(c.module_dir, snap); put(c.caps_dir, snap); } }
    g_ctx = c;
    if (export_env()) { snprintf(why, sizeof why, "%s", g_err); memset(&g_ctx, 0, sizeof g_ctx); r = why; goto out; }
    g_selected = 1; atomic_store(&g_ok, 1);
    LOG("启动上下文：多款容器选了游戏 %s（选游戏 %llu ms），模块 %s，镜像包 %s，资源包 %s，文档 %s", c.game_id, (unsigned long long)(lctx_ms() - t0), c.module_dir, c.images, c.game_data, c.docs);
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
