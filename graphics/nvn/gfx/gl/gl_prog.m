// 着色器程序与 uniform（分片「着色器程序与 uniform」，#272）。最小集：Create / Source / Compile / Attach / Link / Use、查询状态与日志、Get*Location、
// Uniform{1,2,3,4}f(v) / Uniform1i(v) / Matrix4fv（含数组：位置 = 成员号 + 元素号 × 4096，「名字[i]」取第 i 个元素）。
// 着色器先找出包时离线翻好的库（<DM_MSL_DIR>/gl/gl_shaders.metallib + .tsv，表格式见 translator/gl_shaders.py 文件头），按「源码 sha256 前 16 位 + 阶段」找回。
// 库里没有的源码（GameMaker 等运行时才拼 GLSL 的引擎；维护者 11-03 方案①）：首遇时交后台现场翻译（gl_xlate.c s2a_gl_xlate，单独成库 libglx：同离线链口径 GLSL → SPIR-V → MSL）
//   并 newLibraryWithSource，按「键 + 阶段 + 翻译口径」缓存在 <DM_MSL_FALLBACK>/gl/（同 Vulkan 层 vk_rt.inc 的约定），下次开机读缓存预编；源码照旧存进 DM_GL_CAPTURE（设了才存）、
//   下次出包并进离线库——首遇现编 0 仍是目标。游戏线程只在要结果时等它自己那一支：查编译状态 / 链接等翻译（毫秒级），第一次用这个程序画时等 Metal 编译。
//   翻译或 Metal 编译失败照旧报红、编译状态回假，不静默
#include "gl_int.h"
const char gl_slice_gl_prog = 1;   // 分片锚（gl_core.m 引用：静态链接时整片进来，见 gl_int.h「分片锚」）
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <dirent.h>
#include <pthread.h>
#include <mach/mach_time.h>

enum { GL_FRAGMENT_SHADER = 0x8B30, GL_VERTEX_SHADER = 0x8B31, GL_COMPILE_STATUS = 0x8B81, GL_LINK_STATUS = 0x8B82, GL_INFO_LOG_LENGTH = 0x8B84,
       GL_INVALID_ENUM = 0x0500, GL_INVALID_VALUE = 0x0501, GL_INVALID_OPERATION = 0x0502 };
#define CTX(ret) do { if (!gl_cur) { GLRED1("%s：没有当前上下文", __func__); return ret; } } while (0)

// ---------- 库 ----------
typedef struct { char key[17]; int frag; char *fields; } librow;
static librow *g_rows; static int g_nrows; static id<MTLLibrary> g_lib;
static int g_lib_loaded;
static void rt_preload(void);
static void lib_load(void) {
    if (g_lib_loaded) return; g_lib_loaded = 1; gl_dev_init();
    const char *d = getenv("DM_MSL_DIR"); char p[1100], line[8192]; int cap = 0;
    if (!d) { GLOG("【红】 没有 DM_MSL_DIR：OpenGL 着色器库找不到"); return; }
    snprintf(p, sizeof p, "%s/gl/gl_shaders.tsv", d);
    FILE *f = fopen(p, "r"); if (!f) { GLOG("【红】 打不开 %s", p); return; }
    int abi = 0;
    if (!fgets(line, sizeof line, f) || strncmp(line, S2A_GL_LIB_TAG, strlen(S2A_GL_LIB_TAG)) || (abi = atoi(line + strlen(S2A_GL_LIB_TAG))) < S2A_GL_LIB_ABI_MIN || abi > S2A_GL_LIB_ABI) {
        GLOG("【红】 着色器表 %s 不是口径 %d–%d（第一行：%.60s）：重出包", p, S2A_GL_LIB_ABI_MIN, S2A_GL_LIB_ABI, line); fclose(f); return;
    }
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *rest = line, *key = strsep(&rest, "\t"), *stage = strsep(&rest, "\t"), *fields = strsep(&rest, "\t\n");
        if (!key || !stage || strlen(key) != 16) continue;
        if (g_nrows == cap) { cap = cap ? cap * 2 : 128; g_rows = realloc(g_rows, cap * sizeof *g_rows); }
        librow *r = &g_rows[g_nrows++]; memcpy(r->key, key, 17); r->frag = !strcmp(stage, "frag"); r->fields = strdup(fields ? fields : "");
    }
    fclose(f);
    if (g_nrows) {   // 离线 0 支的款（GameMaker：运行时拼 GLSL）只有表头、没有库：全部首遇现编（下面的运行时兜底）
        snprintf(p, sizeof p, "%s/gl/gl_shaders.metallib", d); NSError *e = nil;
        g_lib = [gl_dev newLibraryWithURL:[NSURL fileURLWithPath:@(p)] error:&e];
        if (!g_lib) GLOG("【红】 着色器库 %s 载入失败：%s", p, e.localizedDescription.UTF8String);
    }
    GLOG("着色器表 %d 行", g_nrows);
    rt_preload();
}
static const librow *lib_find(const char *key, int frag) { for (int i = 0; i < g_nrows; i++) if (g_rows[i].frag == frag && !memcmp(g_rows[i].key, key, 16)) return &g_rows[i]; return NULL; }
int s2a_gl_lib_ready(const char *game_data);   // 直连起手判定（graphics/nvn/host_adapt.m 同口径）：表在、口径对；有着色器行就还要有库

// ---------- 运行时兜底：库里没有的源码首遇现场翻译 ----------
// 翻译在 gl_xlate.c（libglx：带 glslang，SPIRV-Cross 用 libnxgal 那份）：弱引用，只链 libnvn 的单测没有它，未命中照旧报红
// 弱链接[host,nvntest]：s2a_gl_xlate（设备上 GLSL 翻译，graphics/nvn/gfx/gl/gl_xlate.c → libglx 提供；不链 C# / 渲染器的宿主、NVN 与 GL 单测没有；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host,nvntest]：s2a_gl_xlate_tag（同上：翻译口径串，缓存行首用）
int s2a_gl_xlate(const char *src, size_t n, int frag, const char *key, char **msl, char **fields, char *err, size_t errcap) __attribute__((weak_import));
const char *s2a_gl_xlate_tag(void) __attribute__((weak_import));
// 一支（键 + 阶段）一条，进程内常驻（Metal 函数跨会话复用，同 vk_rt.inc）。state：0 翻着 / 1 翻好（fields 可读，Metal 编着）/ 2 好（fn 可用）/ 3 坏（why）
struct gl_rt { char key[17]; int frag; _Atomic int state; char *fields; __strong id<MTLFunction> fn; char why[600]; struct gl_rt *next; };
static struct gl_rt *g_rt; static pthread_mutex_t g_rt_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_rt_cv = PTHREAD_COND_INITIALIZER;
static _Atomic uint64_t g_rt_miss, g_rt_ok, g_rt_bad, g_rt_disk, g_rt_wait_n, g_rt_wait_ns;
static double rt_ms(uint64_t a, uint64_t b) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)(b - a) * tb.numer / tb.denom / 1e6; }
static dispatch_queue_t rt_queue(void) {   // 游戏线程会等结果：用户发起级，并发（Metal 编译在系统编译服务里并行）
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("s2a.gl.rt", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0)); });
    return q;
}
static const char *rt_dir(void) {   // <DM_MSL_FALLBACK>/gl（宿主 direct_paths 设成 Documents/wire/<程序号>/shaders）；没设不持久化
    static char d[1100]; static dispatch_once_t once;
    dispatch_once(&once, ^{ const char *f = getenv("DM_MSL_FALLBACK"); if (f && *f) { snprintf(d, sizeof d, "%s/gl", f); mkdir(f, 0755); mkdir(d, 0755); } });
    return d[0] ? d : NULL;
}
// 缓存行首口径：翻译口径（规则号 + glslang 版本）+ 本层表口径；对不上的缓存不读、重翻覆盖
static const char *rt_tag(void) {
    static char t[160]; static dispatch_once_t once;
    dispatch_once(&once, ^{ snprintf(t, sizeof t, "s2a-gl-rt 1 abi %d %s", S2A_GL_LIB_ABI, s2a_gl_xlate_tag ? s2a_gl_xlate_tag() : "-"); });
    return t;
}
static char *rt_read(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL; fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *s = n >= 0 ? malloc((size_t)n + 1) : NULL; if (s && fread(s, 1, (size_t)n, f) == (size_t)n) s[n] = 0; else { free(s); s = NULL; }
    fclose(f); return s;
}
static int rt_write(const char *path, const char *s) {   // 写临时名再改名：被杀在半路也不留半个文件
    char t[1200]; snprintf(t, sizeof t, "%s.%d.tmp", path, getpid()); FILE *f = fopen(t, "wb"); if (!f) return 0;
    size_t n = strlen(s); int ok = fwrite(s, 1, n, f) == n; ok &= fclose(f) == 0;
    if (ok) ok = rename(t, path) == 0; if (!ok) unlink(t); return ok;
}
static void rt_set(struct gl_rt *e, int state) { pthread_mutex_lock(&g_rt_mu); atomic_store(&e->state, state); pthread_cond_broadcast(&g_rt_cv); pthread_mutex_unlock(&g_rt_mu); }
// 等这一支到 want（或坏）；返回最终状态。游戏线程只在这里等，记次数与时长
static int rt_wait(struct gl_rt *e, int want, const char *what) {
    int st = atomic_load(&e->state); if (st >= want) return st;
    uint64_t t0 = mach_absolute_time();
    pthread_mutex_lock(&g_rt_mu); while ((st = atomic_load(&e->state)) < want) pthread_cond_wait(&g_rt_cv, &g_rt_mu); pthread_mutex_unlock(&g_rt_mu);
    uint64_t t1 = mach_absolute_time(); g_rt_wait_n++; g_rt_wait_ns += (uint64_t)(rt_ms(t0, t1) * 1e6);
    GLOG("现编：%s %s %s等了 %.2f ms（累计 %llu 次 %.1f ms）", e->key, e->frag ? "片元" : "顶点", what, rt_ms(t0, t1), (unsigned long long)g_rt_wait_n, g_rt_wait_ns / 1e6);
    return st;
}
static struct gl_rt *rt_find(const char *key, int frag) { for (struct gl_rt *e = g_rt; e; e = e->next) if (e->frag == frag && !memcmp(e->key, key, 16)) return e; return NULL; }
static struct gl_rt *rt_new(const char *key, int frag) { struct gl_rt *e = calloc(1, sizeof *e); memcpy(e->key, key, 16); e->frag = frag; e->next = g_rt; g_rt = e; return e; }
// Metal 编译（后台）：选项同离线链 compile_msl：-fpreserve-invariance；iPhone 库另加 relaxed 数学（-fmetal-math-mode=relaxed），Mac 用缺省
static void rt_metal(struct gl_rt *e, char *msl, int from_disk, double ms_x) {
    @autoreleasepool {
        MTLCompileOptions *o = [MTLCompileOptions new]; o.preserveInvariance = YES;
#if TARGET_OS_IPHONE
        o.mathMode = MTLMathModeRelaxed;
#endif
        char name[40]; snprintf(name, sizeof name, "gl_%s_%c", e->key, e->frag ? 'f' : 'v');
        uint64_t t0 = mach_absolute_time(); NSError *err = nil;
        id<MTLLibrary> l = [gl_dev newLibraryWithSource:@(msl) options:o error:&err];
        id<MTLFunction> fn = l ? [l newFunctionWithName:@(name)] : nil; uint64_t t1 = mach_absolute_time();
        if (!fn) {
            snprintf(e->why, sizeof e->why, "Metal 编译失败：%.500s", err ? err.localizedDescription.UTF8String : "库里没有入口");
            GLOG("【红】 现编：%s %s %s", e->key, e->frag ? "片元" : "顶点", e->why); gl_bad_err++; g_rt_bad++; rt_set(e, 3); free(msl); return;
        }
        // 先落盘、记数，最后发布状态：等它的一方（第一次画）醒来时缓存与计数都已就位（vk_rt.inc 10-26 同类竞态：先发布后写盘，读数的一方见「编好」就数文件）
        const char *d = rt_dir();
        if (d && !from_disk) {   // 持久化：MSL 先、表字段行最后（.row 在 = 整份可用）
            char p[1200], *row = NULL; int ok;
            snprintf(p, sizeof p, "%s/%s_%c.metal", d, e->key, e->frag ? 'f' : 'v'); ok = rt_write(p, msl);
            if (ok && asprintf(&row, "%s\t%s\n", rt_tag(), e->fields) > 0) { snprintf(p, sizeof p, "%s/%s_%c.row", d, e->key, e->frag ? 'f' : 'v'); ok = rt_write(p, row); } else ok = 0;
            free(row); if (!ok) GLOG("【红】 现编：%s 缓存写不进 %s", e->key, d);
        }
        if (from_disk) g_rt_disk++; else g_rt_ok++;
        GLOG("现编：%s %s 好了%s：翻译 %.2f ms、Metal 编译 %.2f ms", e->key, e->frag ? "片元" : "顶点", from_disk ? "（读上次缓存，不翻译）" : "", ms_x, rt_ms(t0, t1));
        e->fn = fn; rt_set(e, 2);
        free(msl);
    }
}
// 读一支缓存（行首口径对上才算）：字段当场可用（state 1），Metal 编译交后台。调用方持 g_rt_mu 或在建表期
static int rt_from_disk(struct gl_rt *e) {
    const char *d = rt_dir(); if (!d) return 0;
    char p[1200]; snprintf(p, sizeof p, "%s/%s_%c.row", d, e->key, e->frag ? 'f' : 'v'); char *row = rt_read(p); if (!row) return 0;
    size_t tl = strlen(rt_tag()); char *nl;
    if (strncmp(row, rt_tag(), tl) || row[tl] != '\t' || !(nl = strchr(row + tl + 1, '\n'))) { free(row); return 0; }   // 别的口径写的：不读，首遇重翻覆盖
    snprintf(p, sizeof p, "%s/%s_%c.metal", d, e->key, e->frag ? 'f' : 'v'); char *msl = rt_read(p); if (!msl) { free(row); return 0; }
    *nl = 0; e->fields = strdup(row + tl + 1); free(row); atomic_store(&e->state, 1);
    dispatch_async(rt_queue(), ^{ rt_metal(e, msl, 1, 0); });
    return 1;
}
// 开机（第一次载库）：上次缓存的全部交后台预编，游戏编到时多半已好；新包离线库已有的不用
static void rt_preload(void) {
    const char *d = rt_dir(); if (!d) return;
    DIR *dp = opendir(d); if (!dp) return; struct dirent *de; int n = 0;
    pthread_mutex_lock(&g_rt_mu);
    while ((de = readdir(dp))) {
        size_t l = strlen(de->d_name); if (l != 22 || strcmp(de->d_name + 18, ".row") || de->d_name[16] != '_' || (de->d_name[17] != 'v' && de->d_name[17] != 'f')) continue;
        char key[17]; memcpy(key, de->d_name, 16); key[16] = 0; int frag = de->d_name[17] == 'f';
        if (lib_find(key, frag) || rt_find(key, frag)) continue;
        struct gl_rt *e = rt_new(key, frag);
        if (rt_from_disk(e)) n++; else { g_rt = e->next; free(e); }   // 读不了（别的口径 / 缺 MSL）：不留空条目，游戏编到时照首遇翻
    }
    pthread_mutex_unlock(&g_rt_mu); closedir(dp);
    if (n) GLOG("现编：开机预编上次缓存的 %d 支（%s）", n, d);
}
// 库里没有的一支：有就复用（同源码同阶段只翻一次），没有先读缓存、再交后台翻译 + Metal 编译
static struct gl_rt *rt_get(const gl_shader *s) {
    int frag = s->type == GL_FRAGMENT_SHADER;
    pthread_mutex_lock(&g_rt_mu);
    struct gl_rt *e = rt_find(s->key, frag);
    if (e) { pthread_mutex_unlock(&g_rt_mu); return e; }
    e = rt_new(s->key, frag);
    if (rt_from_disk(e)) { pthread_mutex_unlock(&g_rt_mu); GLOG("现编：%s %s 读上次缓存", e->key, frag ? "片元" : "顶点"); return e; }
    pthread_mutex_unlock(&g_rt_mu);
    g_rt_miss++;
    GLOG("【首遇】 %s着色器 %s 不在离线库（%zu 字节源码，第 %llu 次），交后台现场翻译", frag ? "片元" : "顶点", s->key, s->len, (unsigned long long)g_rt_miss);
    if (!s2a_gl_xlate) {
        GLOG("【红】 现编：%s 这份宿主没链设备上的 GLSL 翻译（libglx：gl_xlate.c），编译判失败", e->key); gl_bad_err++; g_rt_bad++; rt_set(e, 3); return e;   // why 留空：编译日志照旧回 SHADER_LOG
    }
    char *src = strdup(s->src); size_t n = s->len;   // 游戏随后可能改源码：拷一份交后台
    dispatch_async(rt_queue(), ^{
        char *msl = NULL, *fields = NULL, err[600] = ""; uint64_t t0 = mach_absolute_time();
        int rc = s2a_gl_xlate(src, n, frag, e->key, &msl, &fields, err, sizeof err); free(src);
        double ms_x = rt_ms(t0, mach_absolute_time());
        if (rc) { snprintf(e->why, sizeof e->why, "翻译失败：%.560s", err); GLOG("【红】 现编：%s %s %s", e->key, frag ? "片元" : "顶点", e->why); gl_bad_err++; g_rt_bad++; free(msl); free(fields); rt_set(e, 3); return; }
        e->fields = fields; rt_set(e, 1);
        rt_metal(e, msl, 0, ms_x);
    });
    return e;
}
void dm_gl_rt_stats(uint64_t *miss, uint64_t *ok, uint64_t *bad, uint64_t *disk) { *miss = g_rt_miss; *ok = g_rt_ok; *bad = g_rt_bad; *disk = g_rt_disk; }
// 绘制前（gl_draw.m）：程序里现编的那一阶段还没取到函数就等它编完（只等这一支）；坏了回 0（这笔不画，红已在现编处报过）
int gl_prog_fns(struct gl_program *p) {
    for (int st = 0; st < 2; st++) if (!p->fn[st] && p->rt[st]) {
        if (rt_wait(p->rt[st], 2, "第一次画") != 2) return 0;
        p->fn[st] = p->rt[st]->fn;
    }
    return p->fn[0] && p->fn[1];
}

// ---------- 着色器 ----------
GL(glCreateShader, GLuint, GLenum type) {
    CTX(0); if (type != GL_VERTEX_SHADER && type != GL_FRAGMENT_SHADER) { GLRED1("着色器类型 %#x 没实现（只有顶点 / 片元）", type); gl_set_error(GL_INVALID_ENUM); return 0; }
    gl_shader *s = calloc(1, sizeof *s); if (s) s->type = type; return gl_name_new(&gl_shaders, s);
}
static void shader_destroy(void *object) { gl_shader *s = object; free(s->src); free(s); }
// 删着色器（GLES 3.2 §7.1）：还挂在程序上就只标记删除（名字仍有效、DELETE_STATUS 为真），最后一个程序分离或删除时才真删
static void shader_unref(GLuint name) {
    gl_shader *s = gl_name_get(&gl_shaders, name); if (!s) return;
    if (s->attached > 0) s->attached--;
    if (s->deleted && !s->attached) { gl_name_del(&gl_shaders, name); shader_destroy(s); }
}
GL(glDeleteShader, void, GLuint name) {
    CTX(); if (!name) return; gl_shader *s = gl_name_get(&gl_shaders, name); if (!s) { gl_set_error(GL_INVALID_VALUE); return; }
    if (s->attached) { s->deleted = 1; return; }
    gl_name_del(&gl_shaders, name); shader_destroy(s);
}
// 源码按 GL 规则拼接（length 为空或负 = 以 NUL 结尾）；键按拼接结果到第一个 NUL 算（同出包工具）
GL(glShaderSource, void, GLuint name, GLsizei n, const GLchar *const *str, const GLint *len) {
    CTX(); gl_shader *s = gl_name_get(&gl_shaders, name); if (!s) { gl_set_error(GL_INVALID_VALUE); return; }
    size_t tot = 0; for (GLsizei i = 0; i < n; i++) tot += len && len[i] >= 0 ? (size_t)len[i] : strlen(str[i]);
    free(s->src); s->src = malloc(tot + 1); size_t o = 0;
    for (GLsizei i = 0; i < n; i++) { size_t l = len && len[i] >= 0 ? (size_t)len[i] : strlen(str[i]); memcpy(s->src + o, str[i], l); o += l; }
    s->src[o] = 0; s->len = strlen(s->src); s->compiled = 0; s->rt = NULL;
    uint8_t md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(s->src, (CC_LONG)s->len, md);
    for (int i = 0; i < 8; i++) snprintf(s->key + 2 * i, 3, "%02x", md[i]);
}
static void capture(const gl_shader *s) {
    const char *d = getenv("DM_GL_CAPTURE"); if (!d) return;
    char p[1100]; snprintf(p, sizeof p, "%s/%s.%s", d, s->key, s->type == GL_FRAGMENT_SHADER ? "frag" : "vert");
    FILE *f = fopen(p, "wb"); if (f) { fwrite(s->src, 1, s->len, f); fclose(f); }
}
// 库里有：编好。没有：交运行时兜底（rt_get），编译状态在查询 / 链接时等翻译结果定（shader_ok）
GLB(glCompileShader, void, GLuint name) { @autoreleasepool {
    CTX(); gl_shader *s = gl_name_get(&gl_shaders, name); if (!s || !s->src) { gl_set_error(GL_INVALID_VALUE); return; }
    lib_load();
    s->rt = NULL; s->compiled = lib_find(s->key, s->type == GL_FRAGMENT_SHADER) != NULL;
    if (!s->compiled) { capture(s); s->rt = rt_get(s); }
}}
static int shader_ok(gl_shader *s) {   // 编译状态：库里的直接是；现编的等翻译出结果（翻好 = 成，Metal 编译留到第一次画时等）
    if (s->rt) s->compiled = rt_wait(s->rt, 1, "查编译状态") != 3;
    return s->compiled;
}
#define SHADER_LOG "S2Arm: shader not in the offline library"   // 没进离线库、也没翻成的着色器的编译日志（现编失败给原因）
GL(glGetShaderiv, void, GLuint name, GLenum what, GLint *v) {
    CTX(); gl_shader *s = gl_name_get(&gl_shaders, name); if (!s) { gl_set_error(GL_INVALID_VALUE); return; }
    // GLES 3.2 §7.13 表 20.13 全部 5 个：SHADER_TYPE / DELETE_STATUS / COMPILE_STATUS / INFO_LOG_LENGTH（含结尾 0，空日志 0）/ SHADER_SOURCE_LENGTH（含结尾 0，没源码 0）
    switch (what) {
        case 0x8B4F: *v = (GLint)s->type; break;                                   // SHADER_TYPE
        case 0x8B80: *v = s->deleted; break;                                       // DELETE_STATUS
        case GL_COMPILE_STATUS: *v = shader_ok(s); break;
        case GL_INFO_LOG_LENGTH: *v = shader_ok(s) ? 0 : (GLint)strlen(s->rt && s->rt->why[0] ? s->rt->why : SHADER_LOG) + 1; break;   // 与 glGetShaderInfoLog 写出的同一串
        case 0x8B88: *v = s->src ? (GLint)s->len + 1 : 0; break;                   // SHADER_SOURCE_LENGTH
        default: gl_set_error(GL_INVALID_ENUM); break;
    }
}
// glGetShaderPrecisionFormat（ES 3.2 §7.13；D-S6VQ 开局调它，原先是核心函数空实现、range / precision 不写）：本层着色器一律按 Metal 32 位 float / int 编，
//   精度限定符不降精度，所以 LOW / MEDIUM / HIGH 三档同值——浮点 range {127, 127}、precision 23（IEEE 单精度），整数 range {31, 30}、precision 0。
//   着色器类型只收 VERTEX / FRAGMENT、精度类型只收 0x8DF0–0x8DF5，别的置 INVALID_ENUM 且不写输出
GL(glGetShaderPrecisionFormat, void, GLenum stype, GLenum ptype, GLint *range, GLint *precision) {
    CTX();
    if ((stype != GL_VERTEX_SHADER && stype != GL_FRAGMENT_SHADER) || ptype < 0x8DF0 || ptype > 0x8DF5) { gl_set_error(GL_INVALID_ENUM); return; }
    int flt = ptype <= 0x8DF2;   // LOW / MEDIUM / HIGH_FLOAT；其后三个是 LOW / MEDIUM / HIGH_INT
    if (range) { range[0] = flt ? 127 : 31; range[1] = flt ? 127 : 30; }
    if (precision) *precision = flt ? 23 : 0;
}
GL(glGetShaderInfoLog, void, GLuint name, GLsizei cap, GLsizei *len, GLchar *log) {
    CTX(); gl_shader *s = gl_name_get(&gl_shaders, name); int n = 0;
    if (cap > 0) n = snprintf(log, (size_t)cap, "%s", s && !shader_ok(s) ? (s->rt && s->rt->why[0] ? s->rt->why : SHADER_LOG) : "");
    if (len) *len = n < cap ? n : cap - 1;
}

// ---------- 程序 ----------
GL(glCreateProgram, GLuint, void) { CTX(0); struct gl_program *p = calloc(1, sizeof *p); return gl_name_new(&gl_programs, p); }
static void program_destroy(void *object) {
    struct gl_program *p = object;
    p->fn[0] = p->fn[1] = nil; p->pso = nil; free(p->ub[0]); free(p->ub[1]); free(p->u); free(p->lsrc[0]); free(p->lsrc[1]); free(p);
}
GL(glDeleteProgram, void, GLuint name) {
    CTX(); struct gl_program *p = gl_name_del(&gl_programs, name); if (!p) return;
    for (int st = 0; st < 2; st++) if (p->sh[st]) shader_unref(p->sh[st]);   // 删程序 = 先分离它的着色器（标记删除的此时真删）
    program_destroy(p);
}
void gl_prog_session_reset(void) {
    gl_names_clear(&gl_programs, program_destroy); gl_names_clear(&gl_shaders, shader_destroy);
    for (int i = 0; i < g_nrows; i++) free(g_rows[i].fields);
    free(g_rows); g_rows = NULL; g_nrows = 0; g_lib = nil; g_lib_loaded = 0;
}
GL(glAttachShader, void, GLuint prog, GLuint sh) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, prog); gl_shader *s = gl_name_get(&gl_shaders, sh);
    if (!p || !s) { gl_set_error(GL_INVALID_VALUE); return; }
    int st = s->type == GL_FRAGMENT_SHADER; if (p->sh[st] == sh) { gl_set_error(GL_INVALID_OPERATION); return; }   // 已挂在这个程序上（规范）
    if (p->sh[st]) shader_unref(p->sh[st]);   // 同类型已有一个：换下来的照常减挂接数（本层每个程序每阶段一个着色器）
    p->sh[st] = sh; s->attached++;
}
static gl_uniform *uni(struct gl_program *p, const char *name) {
    for (int i = 0; i < p->nu; i++) if (!strcmp(p->u[i].name, name)) return &p->u[i];
    p->u = realloc(p->u, (p->nu + 1) * sizeof *p->u); gl_uniform *u = &p->u[p->nu++]; memset(u, 0, sizeof *u);
    strlcpy(u->name, name, sizeof u->name); u->off[0] = u->off[1] = -1; return u;
}
// 命名统一块（GLES 3.0）：下标 = 链接时按库表收的块序号；没有该名字 → GL_INVALID_INDEX。绑定点链接后为 0，glUniformBlockBinding 改（绘制时按它取 glBindBufferBase 的缓冲，gl_draw.m）
GL(glGetUniformBlockIndex, GLuint, GLuint prog, const GLchar *name) {
    CTX(0xFFFFFFFFu); struct gl_program *p = gl_name_get(&gl_programs, prog); if (!p) { gl_set_error(GL_INVALID_VALUE); return 0xFFFFFFFFu; }
    for (int k = 0; name && k < p->nblk; k++) if (!strcmp(p->blk[k].name, name)) return (GLuint)k;
    return 0xFFFFFFFFu;
}
GL(glUniformBlockBinding, void, GLuint prog, GLuint index, GLuint binding) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, prog); if (!p) { gl_set_error(GL_INVALID_VALUE); return; }
    if (index >= (GLuint)p->nblk || binding >= 32) { gl_set_error(GL_INVALID_VALUE); return; }
    p->blk[index].binding = binding;
}
// 链接 / 编译日志：库里预编，没有编译器输出，日志为空串
GL(glGetProgramInfoLog, void, GLuint prog, GLsizei bufsize, GLsizei *length, GLchar *log) {
    CTX(); (void)prog; if (length) *length = 0; if (log && bufsize > 0) log[0] = 0;
}
// 链接：两阶段都在库里、取到函数；按库表填顶点输入、默认 uniform 块（槽、大小、成员偏移）。顶点输出 / 片元输入按名字配对（出包工具已改成按名字的 user 属性）
static int glsl_bool_decl(const char *g, const char *name, char *out, size_t n);   // 见下（type_enum 前）：源码声明是 bool 时纠正库表 / 现编字段里的 uint
GLB(glLinkProgram, void, GLuint name) { @autoreleasepool {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p) { gl_set_error(GL_INVALID_VALUE); return; }
    lib_load(); p->linked = 0; p->validated = 0; p->nu = 0; p->nattr = 0; p->nsmp = 0; p->nblk = 0; p->writes_depth = 0;
    p->fn[0] = p->fn[1] = nil; p->rt[0] = p->rt[1] = NULL;
    for (int st = 0; st < 2; st++) {
        // 库里的：取函数、读库表字段；现编的：等翻译出字段（毫秒级），函数留到第一次画时取（gl_prog_fns），不在这里等 Metal 编译
        gl_shader *s = gl_name_get(&gl_shaders, p->sh[st]); const librow *r = s && !s->rt && s->compiled ? lib_find(s->key, st) : NULL;
        struct gl_rt *rt = s && s->rt && shader_ok(s) ? s->rt : NULL;
        if (!r && !rt) { GLOG("【红】 链接程序 %u：%s着色器没有、不在库里也没现编成", name, st ? "片元" : "顶点"); return; }
        memcpy(p->lkey[st], s->key, sizeof p->lkey[st]); free(p->lsrc[st]); p->lsrc[st] = rt ? strdup(s->src) : NULL;
        if (r) {
            p->fn[st] = [g_lib newFunctionWithName:[NSString stringWithFormat:@"gl_%s_%c", r->key, st ? 'f' : 'v']];
            if (!p->fn[st]) { GLOG("【红】 链接程序 %u：库里没有函数 gl_%s_%c", name, r->key, st ? 'f' : 'v'); return; }
        } else p->rt[st] = rt;
        p->ub_slot[st] = -1; p->ub_size[st] = 0;
        char *fl = strdup(r ? r->fields : rt->fields), *save = NULL;
        for (char *t = strtok_r(fl, " ", &save); t; t = strtok_r(NULL, " ", &save)) {
            char nm[64], ty[8]; int a, b, c, d;
            if (t[0] == 'a' && sscanf(t, "a:%63[^=]=%d:%7s", nm, &a, ty) == 3 && !st && p->nattr < 16) { strlcpy(p->attr[p->nattr].name, nm, 64); strlcpy(p->attr[p->nattr].type, ty, 8); p->attr[p->nattr].loc = a; p->attr[p->nattr++].slot = a; }
            else if (t[0] == 'b' && sscanf(t, "b:%d:%d", &a, &b) == 2) { p->ub_slot[st] = a; p->ub_size[st] = b; }
            else if (t[0] == 'D' && !t[1] && st) p->writes_depth = 1;
            else if (t[0] == 'B' && sscanf(t, "B:%63[^=]=%d:%d", nm, &a, &b) == 3) {   // 命名统一块：两阶段同名算一个块（GL 按名字链接）
                int k; for (k = 0; k < p->nblk; k++) if (!strcmp(p->blk[k].name, nm)) break;
                if (k == p->nblk) {
                    if (k == 8) { GLRED1("程序超过 8 个命名统一块"); gl_bad_feat++; free(fl); return; }
                    memset(&p->blk[k], 0, sizeof p->blk[k]); strlcpy(p->blk[k].name, nm, sizeof p->blk[k].name); p->blk[k].slot[0] = p->blk[k].slot[1] = -1; p->nblk++;
                }
                p->blk[k].slot[st] = a; if (b > p->blk[k].size) p->blk[k].size = b;
            }
            else if (t[0] == 'u' && sscanf(t, "u:%63[^=]=%d:%7[^:]:%d:%d", nm, &a, ty, &c, &d) == 5) { gl_uniform *u = uni(p, nm); u->off[st] = a; u->count = c; u->stride = d; strlcpy(u->type, ty, sizeof u->type);
                if ((!strcmp(ty, "uint") || !strncmp(ty, "uvec", 4)) && !strchr(nm, '.') && s) glsl_bool_decl(s->src, nm, u->type, sizeof u->type); }   // 源码声明是 bool：如实报（存储同为 4 字节一个分量）
            else if (t[0] == 't') {   // 采样器；口径 2 起数组带个数（t:<名>=<槽>:<类型>:<个数>，占槽 槽 … 槽 + 个数 − 1），每个元素登记一项、同一数组的各项连续
                char type[32]; int n = 1, got = sscanf(t, "t:%63[^=]=%d:%31[^:]:%d", nm, &a, type, &n);
                if (got < 3 || n < 1 || a < 0 || a + n > 16 || gl_tex_sampler_slot(type) < 0) {
                    GLRED1("采样器反射类型或槽超出已实现范围（2D / 立方体 / 2D 数组 / 3D / 阴影，槽 < 16）：%s", t); gl_bad_feat++; free(fl); return;
                }
                for (int e = 0; e < n; e++) {
                    int k; for (k = 0; k < p->nsmp; k++) if (!strcmp(p->smp[k].name, nm) && p->smp[k].elem == e) break;
                    if (k == p->nsmp) {
                        if (k == 16) { GLRED1("程序超过 16 个采样器"); gl_bad_feat++; free(fl); return; }
                        memset(&p->smp[k], 0, sizeof p->smp[k]); strlcpy(p->smp[k].name, nm, sizeof p->smp[k].name);
                        strlcpy(p->smp[k].type, type, sizeof p->smp[k].type); p->smp[k].slot[0] = p->smp[k].slot[1] = -1; p->smp[k].arr = n; p->smp[k].elem = e; p->nsmp++;
                    }
                    p->smp[k].slot[st] = a + e;
                }
            }
        }
        free(fl);
        free(p->ub[st]); p->ub[st] = p->ub_size[st] ? calloc(1, (size_t)p->ub_size[st]) : NULL;
    }
    // GL 属性号：glBindAttribLocation 绑过的按绑定（GLSL ES 1.00 的款靠它：街霸 30 周年合集，库表的 slot 是翻译时按声明顺序分的）；没绑的取自己的 slot，
    //   和绑过的撞号就取最小的空号（GL 规范：没绑的由实现分配、不与绑过的重叠）
    uint32_t used = 0;
    for (int i = 0; i < p->nattr; i++) { p->attr[i].loc = -1; for (int k = 0; k < p->nbind; k++) if (!strcmp(p->bind[k].name, p->attr[i].name)) { p->attr[i].loc = (int)p->bind[k].idx; used |= 1u << p->bind[k].idx; } }
    for (int i = 0; i < p->nattr; i++) if (p->attr[i].loc < 0) {
        int l = p->attr[i].slot; if (used >> l & 1) for (l = 0; l < 16 && (used >> l & 1); l++) ;
        if (l >= 16) { GLRED1("链接程序 %u：顶点输入超过 16 个属性号", name); gl_bad_feat++; return; }
        p->attr[i].loc = l; used |= 1u << l;
    }
    p->pso = [NSMutableDictionary new]; p->linked = 1;
}}
GL(glBindAttribLocation, void, GLuint name, GLuint idx, const GLchar *nm) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p) { gl_set_error(GL_INVALID_VALUE); return; }
    if (idx >= 16) { gl_set_error(GL_INVALID_VALUE); return; }
    if (!nm || !strncmp(nm, "gl_", 3)) { gl_set_error(GL_INVALID_OPERATION); return; }
    int k; for (k = 0; k < p->nbind; k++) if (!strcmp(p->bind[k].name, nm)) break;
    if (k == p->nbind) { if (k == 16) { GLRED1("程序 %u：glBindAttribLocation 超过 16 个名字", name); gl_bad_feat++; return; } strlcpy(p->bind[k].name, nm, sizeof p->bind[k].name); p->nbind++; }
    p->bind[k].idx = idx;
}
// 采样器数组在 GL 里是一个活动 uniform（名字「tex[0]」、大小 = 个数）：只数每个数组的第 0 项；smp_head 取第 i 个这样的项
static int smp_heads(const struct gl_program *p) { int n = 0; for (int k = 0; k < p->nsmp; k++) n += !p->smp[k].elem; return n; }
static int smp_head(const struct gl_program *p, int i) { for (int k = 0; k < p->nsmp; k++) if (!p->smp[k].elem && !i--) return k; return -1; }
GL(glGetProgramiv, void, GLuint name, GLenum what, GLint *v) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p) { gl_set_error(GL_INVALID_VALUE); return; }
    if (what == GL_LINK_STATUS) *v = p->linked; else if (what == GL_INFO_LOG_LENGTH) *v = p->linked ? 0 : 64;
    else if (what == 0x8B83) *v = p->validated;   // GL_VALIDATE_STATUS
    else if (what == 0x8B89) *v = p->nattr;   // GL_ACTIVE_ATTRIBUTES
    else if (what == 0x8B86) *v = p->nu + smp_heads(p);   // GL_ACTIVE_UNIFORMS：默认块成员 + 采样器（数组算一个），下标同 glGetActiveUniform
    else if (what == 0x8B8A || what == 0x8B87) {   // GL_ACTIVE_ATTRIBUTE_MAX_LENGTH / GL_ACTIVE_UNIFORM_MAX_LENGTH：最长名字含结尾 0（数组成员带「[0]」）
        GLint m = 0;
        if (what == 0x8B8A) for (int i = 0; i < p->nattr; i++) m = MAX(m, (GLint)strlen(p->attr[i].name) + 1);
        else { for (int i = 0; i < p->nu; i++) m = MAX(m, (GLint)strlen(p->u[i].name) + (p->u[i].count ? 4 : 1)); for (int i = 0; i < p->nsmp; i++) m = MAX(m, (GLint)strlen(p->smp[i].name) + (p->smp[i].arr > 1 ? 4 : 1)); }
        *v = m;
    } else { GLRED1("glGetProgramiv %#x 没实现", what); gl_set_error(GL_INVALID_ENUM); }
}
// 源码里 name 是不是声明成 bool / bvecN（「uniform / extern [精度] bool a, b[2];」，LÖVE 着色器头 #define extern uniform）：是就把类型名写进 out。
//   默认块里的 bool 编成 SPIR-V 时被换成 uint（SPIR-V 的 uniform 块不收 bool），库表 / 现编字段只看得到 uint；glGetActiveUniform 报 GL_UNSIGNED_INT 后
//   LÖVE 的 Shader:send 拒收布尔值（小丑牌 engine/sprite.lua:105「bad argument #2 to 'send' (number expected, got boolean)」→ Lua 报错、游戏退出）。
//   在宿主链接时按游戏给的源码纠正：老包离线表、现编字段、旧缓存一处全管，不用重出包
static int idch(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'; }
static int glsl_bool_decl(const char *g, const char *name, char *out, size_t n) {
    static const char *const kw[] = {"uniform", "extern"}, *const ty[] = {"bvec2", "bvec3", "bvec4", "bool"};
    size_t nl = strlen(name);
    for (int k = 0; k < 2 && g; k++) for (const char *p = strstr(g, kw[k]); p; p = strstr(p + 1, kw[k])) {
        size_t kl = strlen(kw[k]); if ((p != g && idch(p[-1])) || idch(p[kl])) continue;
        const char *q = p + kl;
        for (;;) {   // 精度修饰
            while (*q == ' ' || *q == '\t') q++;
            if (!strncmp(q, "lowp", 4) && !idch(q[4])) { q += 4; continue; }
            if (!strncmp(q, "mediump", 7) && !idch(q[7])) { q += 7; continue; }
            if (!strncmp(q, "highp", 5) && !idch(q[5])) { q += 5; continue; }
            break;
        }
        const char *t = NULL; for (int j = 0; j < 4; j++) { size_t l = strlen(ty[j]); if (!strncmp(q, ty[j], l) && !idch(q[l])) { t = ty[j]; q += l; break; } }
        if (!t) continue;
        while (*q && *q != ';') {   // 声明列表：a, b[2], c
            while (*q == ' ' || *q == '\t' || *q == ',') q++;
            const char *id = q; while (idch(*q)) q++;
            if ((size_t)(q - id) == nl && !strncmp(id, name, nl)) { snprintf(out, n, "%s", t); return 1; }
            while (*q && *q != ',' && *q != ';') q++;
        }
    }
    return 0;
}
// GLSL 类型名（着色器表反射）→ GL 类型枚举；认不出的回 0
static GLenum type_enum(const char *t) {
    static const struct { const char *n; GLenum e; } m[] = {{"float", 0x1406}, {"vec2", 0x8B50}, {"vec3", 0x8B51}, {"vec4", 0x8B52}, {"int", 0x1404}, {"ivec2", 0x8B53}, {"ivec3", 0x8B54},
        {"ivec4", 0x8B55}, {"uint", 0x1405}, {"bool", 0x8B56}, {"bvec2", 0x8B57}, {"bvec3", 0x8B58}, {"bvec4", 0x8B59}, {"uvec2", 0x8DC6}, {"uvec3", 0x8DC7}, {"uvec4", 0x8DC8}, {"mat2", 0x8B5A}, {"mat3", 0x8B5B}, {"mat4", 0x8B5C}, {"sampler2D", 0x8B5E}, {"samplerCube", 0x8B60},
        {"sampler2DShadow", 0x8B62}, {"samplerCubeShadow", 0x8DC5}, {"sampler2DArray", 0x8DC1}, {"sampler2DArrayShadow", 0x8DC4}, {"sampler3D", 0x8B5F}};
    for (size_t i = 0; i < sizeof m / sizeof *m; i++) if (!strcmp(m[i].n, t)) return m[i].e;
    return 0;
}
static void active_out(const char *nm, const char *suffix, GLsizei cap, GLsizei *len, GLchar *out) {
    int n = snprintf(out && cap > 0 ? out : NULL, out && cap > 0 ? (size_t)cap : 0, "%s%s", nm, suffix);
    if (len) *len = out && cap > 0 ? MIN(n, cap - 1) : 0;
}
GL(glGetActiveAttrib, void, GLuint name, GLuint i, GLsizei cap, GLsizei *len, GLint *size, GLenum *type, GLchar *out) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p) { gl_set_error(GL_INVALID_VALUE); return; }
    if (i >= (GLuint)p->nattr) { gl_set_error(GL_INVALID_VALUE); return; }
    if (size) *size = 1; if (type) *type = type_enum(p->attr[i].type);
    active_out(p->attr[i].name, "", cap, len, out);
}
GL(glGetActiveUniform, void, GLuint name, GLuint i, GLsizei cap, GLsizei *len, GLint *size, GLenum *type, GLchar *out) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p) { gl_set_error(GL_INVALID_VALUE); return; }
    if (i >= (GLuint)(p->nu + smp_heads(p))) { gl_set_error(GL_INVALID_VALUE); return; }
    if (i < (GLuint)p->nu) { const gl_uniform *u = &p->u[i]; if (size) *size = u->count ? u->count : 1; if (type) *type = type_enum(u->type); active_out(u->name, u->count ? "[0]" : "", cap, len, out); }
    else { int k = smp_head(p, (int)(i - (GLuint)p->nu)); if (size) *size = p->smp[k].arr; if (type) *type = type_enum(p->smp[k].type); active_out(p->smp[k].name, p->smp[k].arr > 1 ? "[0]" : "", cap, len, out); }
}
GL(glUseProgram, void, GLuint name) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, name);
    if (name && (!p || !p->linked)) { gl_set_error(GL_INVALID_OPERATION); return; }
    gl_cur->prog = name; gl_cur->dirty |= GLD_PIPE | GLD_RES;
}
GL(glGetAttribLocation, GLint, GLuint name, const GLchar *nm) {
    CTX(-1); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p || !p->linked) { gl_set_error(GL_INVALID_OPERATION); return -1; }
    for (int i = 0; i < p->nattr; i++) if (!strcmp(p->attr[i].name, nm)) return p->attr[i].loc;
    return -1;
}
enum { ELEM = 4096 };   // 位置编码：成员号 < 4096，数组元素号放高位
GL(glGetUniformLocation, GLint, GLuint name, const GLchar *nm) {
    CTX(-1); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p || !p->linked) { gl_set_error(GL_INVALID_OPERATION); return -1; }
    // 结构体数组展开出的成员（「Lights[1].color」）按全名登记：先比全名；再按 GL 规则只认末尾的「[n]」是数组下标（「Lights[1].pos[2]」= 成员数组 Lights[1].pos 的第 2 项）
    for (int i = 0; i < p->nu && i < ELEM; i++) if (!strcmp(p->u[i].name, nm)) return i;
    char base[64]; strlcpy(base, nm, sizeof base); int elem = 0; char *br = strrchr(base, '[');
    if (br) { char *end; long e = strtol(br + 1, &end, 10); if (end == br + 1 || *end != ']' || end[1] || e < 0) return -1; elem = (int)e; *br = 0; }
    for (int i = 0; i < p->nu; i++) if (!strcmp(p->u[i].name, base)) return elem < (p->u[i].count ? p->u[i].count : 1) && i < ELEM ? i + elem * ELEM : -1;
    for (int i = 0; i < p->nsmp; i++) if (!strcmp(p->smp[i].name, base) && p->smp[i].elem == elem && (!br || p->smp[i].arr > 1)) return p->nu + i;   // 采样器数组：「tex」=「tex[0]」，「tex[i]」= 第 i 项
    return -1;
}
// 写当前程序的 uniform：两个阶段的默认块影子里有它就都写（同一名字在两阶段是同一个 uniform）。
// count 个元素、每个 comps 个 32 位分量，从位置里的元素号起按反射的数组步长排；超出数组的截掉（规范）；矩阵 transpose 按行主序转列主序
static int type_comps(const char *t) {
    return !strcmp(t, "float") || !strcmp(t, "int") || !strcmp(t, "uint") || !strcmp(t, "bool") ? 1 : !strcmp(t, "vec2") || !strcmp(t, "ivec2") || !strcmp(t, "bvec2") ? 2 :
           !strcmp(t, "vec3") || !strcmp(t, "ivec3") || !strcmp(t, "bvec3") ? 3 : !strcmp(t, "mat4") ? 16 : 4;
}
static void uwrite(GLint loc, GLsizei count, const void *v, int comps, int transpose) {
    if (loc == -1) return;   // 规范：位置 −1 静默忽略
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog); int i = loc % ELEM, el = loc / ELEM;
    if (!p || loc < 0 || i >= p->nu) { gl_set_error(GL_INVALID_OPERATION); return; }
    if (count < 0) { gl_set_error(GL_INVALID_VALUE); return; }
    gl_uniform *u = &p->u[i]; int n = u->count ? u->count : 1;
    if (!u->count && count > 1) { gl_set_error(GL_INVALID_OPERATION); return; }
    if (el + count > n) count = n - el;
    int tc = type_comps(u->type), wc = comps < tc ? comps : tc; size_t stride = u->stride ? (size_t)u->stride : (size_t)tc * 4;
    for (int st = 0; st < 2; st++) {
        int o = u->off[st]; if (o < 0 || !p->ub[st]) continue;
        for (GLsizei k = 0; k < count; k++) {
            size_t at = (size_t)o + (size_t)(el + k) * stride; if (at + (size_t)wc * 4 > (size_t)p->ub_size[st]) break;
            const float *src = (const float *)v + (size_t)k * comps; float *dst = (float *)(p->ub[st] + at);
            if (transpose && tc == 16) { for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) dst[c * 4 + r] = src[r * 4 + c]; }
            else memcpy(dst, src, (size_t)wc * 4);
        }
    }
    gl_cur->dirty |= GLD_RES;
}
static void uset(GLint loc, const void *v, size_t n) { uwrite(loc, 1, v, (int)(n / 4), 0); }
GL(glUniform1f, void, GLint loc, GLfloat a) { CTX(); uset(loc, &a, 4); }
GL(glUniform2f, void, GLint loc, GLfloat a, GLfloat b) { CTX(); float v[2] = {a, b}; uset(loc, v, 8); }
GL(glUniform3f, void, GLint loc, GLfloat a, GLfloat b, GLfloat c) { CTX(); float v[3] = {a, b, c}; uset(loc, v, 12); }
GL(glUniform4f, void, GLint loc, GLfloat a, GLfloat b, GLfloat c, GLfloat d) { CTX(); float v[4] = {a, b, c, d}; uset(loc, v, 16); }
GL(glUniform1fv, void, GLint loc, GLsizei n, const GLfloat *v) { CTX(); uwrite(loc, n, v, 1, 0); }
GL(glUniform2fv, void, GLint loc, GLsizei n, const GLfloat *v) { CTX(); uwrite(loc, n, v, 2, 0); }
GL(glUniform3fv, void, GLint loc, GLsizei n, const GLfloat *v) { CTX(); uwrite(loc, n, v, 3, 0); }
GL(glUniform4fv, void, GLint loc, GLsizei n, const GLfloat *v) { CTX(); uwrite(loc, n, v, 4, 0); }
static int sampler_set(GLint loc, GLsizei count, const GLint *value) {
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog);
    if (!p || loc < p->nu || loc >= p->nu + p->nsmp) return 0;
    int k = loc - p->nu, n = p->smp[k].arr - p->smp[k].elem;   // 从这个元素起到数组尾的个数（非数组 1）
    if (count > 1 && p->smp[k].arr == 1) { gl_set_error(GL_INVALID_OPERATION); return 1; }   // 非数组一次给多个值（规范）
    if (count > n) count = n;   // 超出数组尾的值不写（规范）
    for (GLsizei i = 0; i < count; i++) if (value[i] < 0 || value[i] >= 32) { gl_set_error(GL_INVALID_VALUE); return 1; }
    for (GLsizei i = 0; i < count; i++) p->smp[k + i].unit = value[i];
    gl_cur->dirty |= GLD_RES; return 1;
}
// 往 float 成员写整数：GL 规定是错误，NVIDIA 驱动照转成浮点（数码宝贝依赖这一行为）
GL(glUniform1i, void, GLint loc, GLint a) {
    CTX(); if (sampler_set(loc, 1, &a)) return;
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog);
    if (p && loc >= 0 && loc % ELEM < p->nu && !strcmp(p->u[loc % ELEM].type, "float")) { float f = (float)a; uset(loc, &f, 4); return; }
    uset(loc, &a, 4);
}
GL(glUniform1iv, void, GLint loc, GLsizei count, const GLint *value) {
    CTX(); if (count < 0) { gl_set_error(GL_INVALID_VALUE); return; } if (!count || loc == -1) return;
    if (sampler_set(loc, count, value)) return;
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog);
    if (!p || loc < 0 || loc >= p->nu || (strcmp(p->u[loc].type, "int") && strcmp(p->u[loc].type, "bool"))) { gl_set_error(GL_INVALID_OPERATION); return; }   // bool 也收整数（规范；LÖVE 发 bool 走它）
    gl_uniform *u = &p->u[loc];
    if (count != 1 || u->count) { GLRED1("glUniform1iv 普通 uniform 数组尚未实现"); gl_bad_feat++; gl_set_error(GL_INVALID_OPERATION); return; }
    uset(loc, value, 4);
}
GL(glUniformMatrix4fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); uwrite(loc, n, v, 16, (transpose & 0xff) != 0); }
// 整数向量：成员类型必须是同分量数的 ivec（规范：类型不符 INVALID_OPERATION）；数组照 uwrite 的步长与截断
static void ivwrite(GLint loc, GLsizei count, const GLint *v, int comps) {
    if (count < 0) { gl_set_error(GL_INVALID_VALUE); return; } if (loc == -1) return;
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog); char want[8], wantb[8]; snprintf(want, sizeof want, "ivec%d", comps); snprintf(wantb, sizeof wantb, "bvec%d", comps);
    if (!p || loc < 0 || loc % ELEM >= p->nu || (strcmp(p->u[loc % ELEM].type, want) && strcmp(p->u[loc % ELEM].type, wantb))) { gl_set_error(GL_INVALID_OPERATION); return; }   // bvecN 也收整数（规范）
    uwrite(loc, count, v, comps, 0);
}
GL(glUniform2iv, void, GLint loc, GLsizei n, const GLint *v) { CTX(); ivwrite(loc, n, v, 2); }
GL(glUniform3iv, void, GLint loc, GLsizei n, const GLint *v) { CTX(); ivwrite(loc, n, v, 3); }
GL(glUniform4iv, void, GLint loc, GLsizei n, const GLint *v) { CTX(); ivwrite(loc, n, v, 4); }
// 标量版本（D-FTA8：游戏调 glUniform2i，原先只有 iv 版本、标量版交空实现，uniform 没写进去）：同 iv 版本写一个元素
GL(glUniform2i, void, GLint loc, GLint a, GLint b) { CTX(); const GLint v[2] = {a, b}; ivwrite(loc, 1, v, 2); }
GL(glUniform3i, void, GLint loc, GLint a, GLint b, GLint c) { CTX(); const GLint v[3] = {a, b, c}; ivwrite(loc, 1, v, 3); }
GL(glUniform4i, void, GLint loc, GLint a, GLint b, GLint c, GLint d) { CTX(); const GLint v[4] = {a, b, c, d}; ivwrite(loc, 1, v, 4); }
// mat2 / mat3：默认 uniform 块按 std140（glslang -R 的 gl_DefaultUniformBlock），每列占 16 字节（列内 2 / 3 个 float），数组元素步长取反射的 stride；
//   transpose = 源按行主序给（GL ES 3.0 起允许），换成列主序写
//   非方阵（GL 2.1 glUniformMatrixCxRfv：C 列 R 行）同样每列 16 字节、列内 R 个 float
static void mwrite_cr(GLint loc, GLsizei count, const GLfloat *v, int cols, int rows, int transpose) {
    if (count < 0) { gl_set_error(GL_INVALID_VALUE); return; } if (loc == -1) return;
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog); int i = loc % ELEM, el = loc / ELEM; char want[8], alt[8];
    if (cols == rows) { snprintf(want, sizeof want, "mat%d", cols); snprintf(alt, sizeof alt, "mat%dx%d", cols, rows); }
    else { snprintf(want, sizeof want, "mat%dx%d", cols, rows); strlcpy(alt, want, sizeof alt); }
    if (!p || loc < 0 || i >= p->nu || (strcmp(p->u[i].type, want) && strcmp(p->u[i].type, alt))) { gl_set_error(GL_INVALID_OPERATION); return; }
    gl_uniform *u = &p->u[i]; int m = u->count ? u->count : 1;
    if (!u->count && count > 1) { gl_set_error(GL_INVALID_OPERATION); return; }
    if (el + count > m) count = m - el;
    size_t stride = u->stride ? (size_t)u->stride : (size_t)cols * 16;
    for (int st = 0; st < 2; st++) {
        int o = u->off[st]; if (o < 0 || !p->ub[st]) continue;
        for (GLsizei k = 0; k < count; k++) {
            size_t at = (size_t)o + (size_t)(el + k) * stride; if (at + (size_t)(cols - 1) * 16 + (size_t)rows * 4 > (size_t)p->ub_size[st]) break;
            const float *src = v + (size_t)k * cols * rows;
            for (int c = 0; c < cols; c++) for (int r = 0; r < rows; r++) ((float *)(p->ub[st] + at + (size_t)c * 16))[r] = transpose ? src[r * cols + c] : src[c * rows + r];
        }
    }
    gl_cur->dirty |= GLD_RES;
}
static void mwrite(GLint loc, GLsizei count, const GLfloat *v, int n, int transpose) { mwrite_cr(loc, count, v, n, n, transpose); }
GL(glUniformMatrix2fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite(loc, n, v, 2, (transpose & 0xff) != 0); }
GL(glUniformMatrix3fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite(loc, n, v, 3, (transpose & 0xff) != 0); }
GL(glUniformMatrix2x3fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite_cr(loc, n, v, 2, 3, (transpose & 0xff) != 0); }
GL(glUniformMatrix3x2fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite_cr(loc, n, v, 3, 2, (transpose & 0xff) != 0); }
GL(glUniformMatrix2x4fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite_cr(loc, n, v, 2, 4, (transpose & 0xff) != 0); }
GL(glUniformMatrix4x2fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite_cr(loc, n, v, 4, 2, (transpose & 0xff) != 0); }
GL(glUniformMatrix3x4fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite_cr(loc, n, v, 3, 4, (transpose & 0xff) != 0); }
GL(glUniformMatrix4x3fv, void, GLint loc, GLsizei n, GLuint transpose, const GLfloat *v) { CTX(); mwrite_cr(loc, n, v, 4, 3, (transpose & 0xff) != 0); }
// 无符号整数向量（GL 3.0 / ES 3.0）：成员类型必须是 uint / uvecN（规范：类型不符 INVALID_OPERATION）
static void uvwrite(GLint loc, GLsizei count, const GLuint *v, int comps) {
    if (count < 0) { gl_set_error(GL_INVALID_VALUE); return; } if (loc == -1) return;
    struct gl_program *p = gl_name_get(&gl_programs, gl_cur->prog); char want[8]; if (comps == 1) strlcpy(want, "uint", sizeof want); else snprintf(want, sizeof want, "uvec%d", comps);
    if (!p || loc < 0 || loc % ELEM >= p->nu || strcmp(p->u[loc % ELEM].type, want)) { gl_set_error(GL_INVALID_OPERATION); return; }
    uwrite(loc, count, v, comps, 0);
}
GL(glUniform1uiv, void, GLint loc, GLsizei n, const GLuint *v) { CTX(); uvwrite(loc, n, v, 1); }
GL(glUniform2uiv, void, GLint loc, GLsizei n, const GLuint *v) { CTX(); uvwrite(loc, n, v, 2); }
GL(glUniform3uiv, void, GLint loc, GLsizei n, const GLuint *v) { CTX(); uvwrite(loc, n, v, 3); }
GL(glUniform4uiv, void, GLint loc, GLsizei n, const GLuint *v) { CTX(); uvwrite(loc, n, v, 4); }
// 读回 uniform 当前值（GL 4.5 §7.6.2 / ES 3.0 §2.12.6）：从默认块影子里按写入时的排法读（矩阵每列 16 字节、其余分量连续），采样器读它绑的纹理单元。
//   LÖVE 引擎建着色器后逐个读回 uniform 的初值存进自己的表（Balatro），原先查表回空
static void uread(GLuint prog, GLint loc, void *out, int as_float) {
    struct gl_program *p = gl_name_get(&gl_programs, prog);
    if (!p || !p->linked) { gl_set_error(p ? GL_INVALID_OPERATION : GL_INVALID_VALUE); return; }
    if (loc >= p->nu && loc < p->nu + p->nsmp) { int unit = p->smp[loc - p->nu].unit; if (as_float) *(GLfloat *)out = (GLfloat)unit; else *(GLint *)out = unit; return; }
    int i = loc % ELEM, el = loc / ELEM; if (loc < 0 || i >= p->nu) { gl_set_error(GL_INVALID_OPERATION); return; }
    const gl_uniform *u = &p->u[i]; const char *t = u->type; int cols = 0, rows = 0;
    if (!strncmp(t, "mat", 3)) { cols = t[3] - '0'; rows = t[4] == 'x' ? t[5] - '0' : cols; }
    int tc = cols ? 0 : type_comps(t); if (!strcmp(t, "uvec2")) tc = 2; else if (!strcmp(t, "uvec3")) tc = 3;
    size_t stride = u->stride ? (size_t)u->stride : cols ? (size_t)cols * 16 : (size_t)tc * 4;
    int isint = !cols && (t[0] == 'i' || t[0] == 'u' || t[0] == 'b');
    for (int st = 0; st < 2; st++) {
        int o = u->off[st]; if (o < 0 || !p->ub[st]) continue;
        const uint8_t *base = p->ub[st] + (size_t)o + (size_t)el * stride; int n = 0; uint32_t w[16];
        if (cols) { for (int c = 0; c < cols; c++) for (int r = 0; r < rows; r++) w[n++] = ((const uint32_t *)(base + (size_t)c * 16))[r]; }
        else { n = tc; memcpy(w, base, (size_t)n * 4); }
        for (int k = 0; k < n; k++) {
            float f; int32_t s; memcpy(&f, &w[k], 4); memcpy(&s, &w[k], 4);
            if (as_float) ((GLfloat *)out)[k] = isint ? (GLfloat)s : f; else ((GLint *)out)[k] = isint ? s : (GLint)f;
        }
        return;
    }
    // 两个阶段都没用到这个 uniform（被优化掉）：读到初值 0
    int n = cols ? cols * rows : type_comps(t); memset(out, 0, (size_t)n * 4);
}
GL(glGetUniformfv, void, GLuint prog, GLint loc, GLfloat *v) { CTX(); uread(prog, loc, v, 1); }
GL(glGetUniformiv, void, GLuint prog, GLint loc, GLint *v) { CTX(); uread(prog, loc, v, 0); }
GL(glGetUniformuiv, void, GLuint prog, GLint loc, GLuint *v) { CTX(); uread(prog, loc, v, 0); }

// ---------- 名字查询与程序 / 着色器杂项 ----------
GL(glIsShader, GLboolean, GLuint name) { CTX(0); return gl_name_get(&gl_shaders, name) != NULL; }     // glCreateShader 即建对象（不同于 Gen 类）
GL(glIsProgram, GLboolean, GLuint name) { CTX(0); return gl_name_get(&gl_programs, name) != NULL; }
GL(glDetachShader, void, GLuint prog, GLuint sh) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, prog); gl_shader *s = gl_name_get(&gl_shaders, sh);
    if (!p || !s) { gl_set_error(GL_INVALID_VALUE); return; }
    int st = s->type == GL_FRAGMENT_SHADER; if (p->sh[st] != sh) { gl_set_error(GL_INVALID_OPERATION); return; }   // 没挂在这个程序上
    p->sh[st] = 0; shader_unref(sh);   // 已链接的程序不受影响（规范：分离只影响下一次链接）；标记删除的此时真删
}
// 校验：程序已链接，且不同类型的采样器没有指向同一个纹理单元（GL 4.5 §7.13 / ES 3.2 §11.1.3.11 的绘制期错误条件，这里提前判）；结果给 GL_VALIDATE_STATUS
GL(glValidateProgram, void, GLuint name) {
    CTX(); struct gl_program *p = gl_name_get(&gl_programs, name); if (!p) { gl_set_error(GL_INVALID_VALUE); return; }
    int ok = p->linked;
    for (int i = 0; ok && i < p->nsmp; i++) for (int j = i + 1; ok && j < p->nsmp; j++)
        if (p->smp[i].unit == p->smp[j].unit && gl_tex_sampler_slot(p->smp[i].type) != gl_tex_sampler_slot(p->smp[j].type)) ok = 0;
    p->validated = ok;
}
// 释放编译器资源的提示（ES 2.0 §2.10）：对正确性没有影响、之后照样能编译。本层着色器来自离线库，没有在线编译器可释放
GL(glReleaseShaderCompiler, void, void) { CTX(); }
// 二进制着色器：本层只认 GLSL 源码按哈希找离线库，不支持任何二进制格式（GL_NUM_SHADER_BINARY_FORMATS = 0），规范要求报 GL_INVALID_ENUM
GL(glShaderBinary, void, GLsizei count, const GLuint *shaders, GLenum format, const void *binary, GLsizei length) {
    CTX(); (void)shaders; (void)binary;
    if (count < 0 || length < 0) { gl_set_error(GL_INVALID_VALUE); return; }
    GLRED1("glShaderBinary 二进制格式 %#x（%d 个着色器、%d 字节）不支持：本层只收 GLSL 源码（报 GL_INVALID_ENUM）", format, count, length); gl_bad_feat++;
    gl_set_error(GL_INVALID_ENUM);
}
// 直连起手判定（runtime/src/gfxmode.c 弱引用调）：<游戏数据>/shaders/direct/gl/ 下表第一行口径对；表里有着色器行就还要有库。
//   只有表头（离线 0 支：GameMaker 运行时拼 GLSL，graphics/tools/direct/direct_lib.sh GL 段照出）也算就绪：库里没有的源码首遇时现场翻译（本文件运行时兜底）
int s2a_gl_lib_ready(const char *game_data) {
    char p[1200], line[256]; struct stat st;
    if (!game_data || !*game_data) return 0;
    snprintf(p, sizeof p, "%s/shaders/direct/gl/gl_shaders.tsv", game_data);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    int abi = 0, ok = fgets(line, sizeof line, f) && !strncmp(line, S2A_GL_LIB_TAG, strlen(S2A_GL_LIB_TAG)) && (abi = atoi(line + strlen(S2A_GL_LIB_TAG))) >= S2A_GL_LIB_ABI_MIN && abi <= S2A_GL_LIB_ABI, rows = 0;
    if (!ok) GLOG("直连 OpenGL 库口径不符（要 %d–%d，%s 第一行：%.60s）：不算就绪", S2A_GL_LIB_ABI_MIN, S2A_GL_LIB_ABI, p, line);
    // 按整行数：表头第 3 行（工具版本）超过 line 的 256 字节，fgets 切下的后半截不是新行（11-03 AM2R 只有表头，后半截被数成 1 行、判「有行没库」走了通用）
    for (int start = 1; ok && fgets(line, sizeof line, f); start = strchr(line, '\n') != NULL) if (start && line[0] != '#' && line[0] != '\n') rows++;
    fclose(f);
    if (ok && rows) { snprintf(p, sizeof p, "%s/shaders/direct/gl/gl_shaders.metallib", game_data); if (stat(p, &st) || !st.st_size) { GLOG("【红】 直连 OpenGL 表有 %d 行却没有库 %s：不算就绪", rows, p); return 0; } }
    return ok;
}

// ---------- 即时存档：着色器与程序 ----------
// 着色器：类型、源码、编译 / 挂接 / 删除标记；现编的按源码重新交兜底（同键读上次缓存，不再翻译）。程序：链接结果整份存（反射出的槽、uniform 表与 CPU 影子、
//   采样器单元、块绑定、属性号），函数按链接时记下的键重取（库里的 newFunctionWithName，现编的交兜底、第一次画时等），不重新链接（游戏链接后常删掉着色器）
enum { GH_NAME = 1, GH_TYPE, GH_SRC, GH_COMPILED, GH_ATTACHED, GH_DELETED,
       GG_NAME = 1, GG_SH, GG_LINKED, GG_VALID, GG_UBSLOT, GG_UBSIZE, GG_UB0, GG_UB1, GG_SMP, GG_NSMP, GG_U, GG_NU, GG_WDEPTH, GG_BLK, GG_NBLK, GG_ATTR, GG_NATTR, GG_BIND, GG_NBIND, GG_LKEY, GG_LSRC0, GG_LSRC1 };
static void sh_key(gl_shader *s) { uint8_t md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(s->src, (CC_LONG)s->len, md); for (int i = 0; i < 8; i++) snprintf(s->key + 2 * i, 3, "%02x", md[i]); }
int gl_prog_snap_save(FILE *f) {
    sfw w; sfw_sec(&w, f, "gl.shader", 1);
    for (GLuint i = 1; i < gl_shaders.n; i++) { gl_shader *s = gl_shaders.v[i]; if (!s) continue;
        sfw_rec(&w); GLSF_W(&w, GH_NAME, i); GLSF_W(&w, GH_TYPE, s->type); if (s->src) sfw_blob(&w, GH_SRC, s->src, (uint32_t)s->len);
        GLSF_W(&w, GH_COMPILED, s->compiled); GLSF_W(&w, GH_ATTACHED, s->attached); GLSF_W(&w, GH_DELETED, s->deleted); sfw_end_rec(&w); }
    if (sfw_end(&w)) return -1;
    sfw_sec(&w, f, "gl.program", 1); uint32_t np = 0;
    for (GLuint i = 1; i < gl_programs.n; i++) { struct gl_program *p = gl_programs.v[i]; if (!p) continue;
        sfw_rec(&w); GLSF_W(&w, GG_NAME, i); GLSF_W(&w, GG_SH, p->sh); GLSF_W(&w, GG_LINKED, p->linked); GLSF_W(&w, GG_VALID, p->validated); GLSF_W(&w, GG_UBSLOT, p->ub_slot); GLSF_W(&w, GG_UBSIZE, p->ub_size);
        if (p->ub[0]) sfw_blob(&w, GG_UB0, p->ub[0], (uint32_t)p->ub_size[0]); if (p->ub[1]) sfw_blob(&w, GG_UB1, p->ub[1], (uint32_t)p->ub_size[1]);
        GLSF_W(&w, GG_SMP, p->smp); GLSF_W(&w, GG_NSMP, p->nsmp); if (p->nu) sfw_blob(&w, GG_U, p->u, (uint32_t)(p->nu * sizeof *p->u)); GLSF_W(&w, GG_NU, p->nu);
        GLSF_W(&w, GG_WDEPTH, p->writes_depth); GLSF_W(&w, GG_BLK, p->blk); GLSF_W(&w, GG_NBLK, p->nblk); GLSF_W(&w, GG_ATTR, p->attr); GLSF_W(&w, GG_NATTR, p->nattr);
        GLSF_W(&w, GG_BIND, p->bind); GLSF_W(&w, GG_NBIND, p->nbind); GLSF_W(&w, GG_LKEY, p->lkey);
        if (p->lsrc[0]) sfw_blob(&w, GG_LSRC0, p->lsrc[0], (uint32_t)strlen(p->lsrc[0])); if (p->lsrc[1]) sfw_blob(&w, GG_LSRC1, p->lsrc[1], (uint32_t)strlen(p->lsrc[1]));
        sfw_end_rec(&w); np++; }
    GLOG("即时存档：GL 程序 %u 个", np);
    return sfw_end(&w);
}
static char *blob_str(const sfr *r, uint16_t id, size_t *len) { uint32_t n; const char *p = sfr_get(r, id, &n); if (!p) return NULL; char *s = malloc(n + 1); memcpy(s, p, n); s[n] = 0; if (len) *len = n; return s; }
int gl_prog_snap_restore(FILE *f) {
    lib_load();
    sfr r; if (sfr_sec(&r, f, "gl.shader", 1)) return -1; int bad = 0, nfn = 0, nrt = 0, nmiss = 0;
    while (sfr_rec(&r) == 1) {
        GLuint nm = 0; GLSF_R(&r, GH_NAME, nm); gl_shader *s = calloc(1, sizeof *s); if (!nm || !s) { free(s); continue; }
        GLSF_R(&r, GH_TYPE, s->type); s->src = blob_str(&r, GH_SRC, &s->len); GLSF_R(&r, GH_COMPILED, s->compiled); GLSF_R(&r, GH_ATTACHED, s->attached); GLSF_R(&r, GH_DELETED, s->deleted);
        if (s->src) { s->len = strlen(s->src); sh_key(s); }
        if (s->compiled && s->src && !lib_find(s->key, s->type == GL_FRAGMENT_SHADER)) s->rt = rt_get(s);
        if (!gl_name_put(&gl_shaders, nm, s)) { shader_destroy(s); bad = 1; }
    }
    sfr_done(&r);
    if (bad || sfr_sec(&r, f, "gl.program", 1)) return -1;
    while (sfr_rec(&r) == 1) {
        GLuint nm = 0; GLSF_R(&r, GG_NAME, nm); struct gl_program *p = calloc(1, sizeof *p); if (!nm || !p) { free(p); continue; }
        GLSF_R(&r, GG_SH, p->sh); GLSF_R(&r, GG_LINKED, p->linked); GLSF_R(&r, GG_VALID, p->validated); GLSF_R(&r, GG_UBSLOT, p->ub_slot); GLSF_R(&r, GG_UBSIZE, p->ub_size);
        for (int st = 0; st < 2; st++) if (p->ub_size[st] > 0) { p->ub[st] = calloc(1, (size_t)p->ub_size[st]); sfr_into(&r, st ? GG_UB1 : GG_UB0, p->ub[st], (uint32_t)p->ub_size[st]); }
        GLSF_R(&r, GG_SMP, p->smp); GLSF_R(&r, GG_NSMP, p->nsmp); GLSF_R(&r, GG_NU, p->nu);
        if (p->nu > 0) { p->u = calloc((size_t)p->nu, sizeof *p->u); sfr_into_conv(&r, GG_U, p->u, (uint32_t)(p->nu * sizeof *p->u), "gl.uniform", (uint32_t)sizeof *p->u); }
        GLSF_R(&r, GG_WDEPTH, p->writes_depth); GLSF_R(&r, GG_BLK, p->blk); GLSF_R(&r, GG_NBLK, p->nblk); GLSF_R(&r, GG_ATTR, p->attr); GLSF_R(&r, GG_NATTR, p->nattr);
        GLSF_R(&r, GG_BIND, p->bind); GLSF_R(&r, GG_NBIND, p->nbind); GLSF_R(&r, GG_LKEY, p->lkey); p->lsrc[0] = blob_str(&r, GG_LSRC0, NULL); p->lsrc[1] = blob_str(&r, GG_LSRC1, NULL);
        if (p->linked) {
            for (int st = 0; st < 2; st++) {
                const librow *lr = lib_find(p->lkey[st], st);
                if (lr) { p->fn[st] = [g_lib newFunctionWithName:[NSString stringWithFormat:@"gl_%s_%c", lr->key, st ? 'f' : 'v']]; nfn += p->fn[st] != nil; if (!p->fn[st]) nmiss++; }
                else if (p->lsrc[st]) { gl_shader tmp = {0}; memcpy(tmp.key, p->lkey[st], sizeof tmp.key); tmp.type = st ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER; tmp.src = p->lsrc[st]; tmp.len = strlen(p->lsrc[st]);
                    p->rt[st] = rt_get(&tmp); nrt++; }
                else nmiss++;
            }
            p->pso = [NSMutableDictionary new];
        }
        if (!gl_name_put(&gl_programs, nm, p)) { program_destroy(p); bad = 1; }
    }
    sfr_done(&r);
    GLOG("%s即时存档恢复：GL 程序函数 库里取 %d 支、交现编 %d 支、取不到 %d 支", nmiss ? "【红】 " : "", nfn, nrt, nmiss);
    return bad ? -1 : 0;
}
