// GL 层运行时兜底单测（gl_prog.m 首遇现编 + gl_xlate.c 设备上 GLSL 翻译）：生产 GL 各片 + libglx（glslang）+ libnxgal 那份 SPIRV-Cross，真 Metal 设备画、读回。
// 离线库只有 tri.*（t_gl_rt.sh 用出包工具 gl_shaders.py 出），api_es300.*（GLSL ES 3.00）、texture100.*（GLSL ES 1.00）不在库里。两遍进程共用一个 DM_MSL_FALLBACK：
// 第 1 遍（T_GL_RT_PASS=1，缓存目录空）：
//   A 库命中走库：tri 编译状态 1、首遇计数 0；左半四边形画 (1, 0, 0) → 左 255 0 0 255、右清除色蓝 0 0 255 255
//   B 库没有 → 后台翻译：api_es300 两支、texture100 两支编译状态 1，首遇 +4；api_es300 左半红（同 tri 的期望）；texture100 采样 1×1 纯绿贴图画满 → 中心 0 255 0 255；
//     画完翻好 4 支（编好计数 4）、缓存目录 gl/ 下 4 个 .row + 4 个 .metal
//   F 结构体数组 uniform（D-FTA8：uniform Light Lights[2]）：api_es300.vert + api_structarr.frag 现编（顶点已缓存，只新翻片元 1 支）、编译 / 链接成；
//     「Lights[1].color」有位置、「Lights[2].color」没有（−1）；Lights[0] = 红 × 0.5、Lights[1] = 绿 × 0.5，再乘 uSel.x / uSel.y（glUniform2i 设 (2, 2) = 1）
//     → 左半 (0.5, 0.5, 0, 1) = 128 128 0 255（±1）。glUniform2i 没写进去（修前是空实现）时 uSel = (0, 0)，0 / 0 画不出这个颜色。
//     元素偏移错（第 1 个元素写进第 0 个的位置）会读成 0 128 0 128 一类的值；翻不过（修前「类型 / 数组尚未接入运行时」）则链接失败
//   G D-TTP7 / #852：顶点里 uniform float 减 const int（ES 不许 int 隐式转 float，NVIDIA 放过，Darkest Dungeon 一支顶点因此编不过）：
//     api_conv.vert + api_es300.frag 现编（片元已缓存，只新翻顶点 1 支）→ 编译 / 链接成；z = uZero − K = 0，画面同 tri：左红、右蓝
//   C 翻译失败照旧报红：调未声明函数的片元 → 编译状态 0、日志以「翻译失败」开头、链接失败、坏计数 +1、直连异常计数 gl_bad_err +1；同一源码再编一次不重翻（坏计数不变）
// 第 2 遍（T_GL_RT_PASS=2，同一缓存目录、新进程）：
//   D 第二次命中缓存：开机预编上次 6 支（B 的 4 支 + F 的片元 1 支 + G 的顶点 1 支），api_es300 / texture100 编译状态 1，首遇计数 0、读缓存计数 4；两个程序画出同第 1 遍的颜色
// 两遍都核 E 直连就绪判定（s2a_gl_lib_ready，gfxmode 选直连靠它）：只有表头（gl_shaders.py 离线 0 支的产物，第 3 行工具版本超 256 字节）→ 1；
//   离线库（tri 两行 + metallib）→ 1；同一张两行表、拿走 metallib → 0（11-03 AM2R 真机：长表头后半截被数成 1 行、判「有行没库」走了通用）
// 期望都按着色器写法与 GL 规范手算（纯色四边形、1×1 贴图），不跑被测实现。
#include "../../gfx/gl/gl_int.h"
#include <unistd.h>
#include <dirent.h>
#include "t_gl_stubs.inc"

void dm_gl_rt_stats(uint64_t *miss, uint64_t *ok, uint64_t *bad, uint64_t *disk);   // gl_prog.m
int s2a_gl_lib_ready(const char *game_data);   // gl_prog.m
typedef void *(*gpa_t)(const char *);
static gpa_t gpa = gl_lookup;
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (c) printf("  过 " __VA_ARGS__); else { printf("  败 " __VA_ARGS__); fails++; } printf("\n"); } while (0)
#define BASE(X) X(glGenBuffers, void, GLsizei, GLuint *) X(glBindBuffer, void, GLenum, GLuint) X(glBufferData, void, GLenum, GLsizeiptr, const void *, GLenum) \
    X(glGenVertexArrays, void, GLsizei, GLuint *) X(glBindVertexArray, void, GLuint) X(glVertexAttribPointer, void, GLuint, GLint, GLenum, GLuint, GLsizei, const void *) \
    X(glEnableVertexAttribArray, void, GLuint) X(glCreateShader, GLuint, GLenum) X(glShaderSource, void, GLuint, GLsizei, const GLchar *const *, const GLint *) \
    X(glCompileShader, void, GLuint) X(glGetShaderiv, void, GLuint, GLenum, GLint *) X(glGetShaderInfoLog, void, GLuint, GLsizei, GLsizei *, GLchar *) \
    X(glCreateProgram, GLuint, void) X(glAttachShader, void, GLuint, GLuint) X(glLinkProgram, void, GLuint) X(glGetProgramiv, void, GLuint, GLenum, GLint *) \
    X(glUseProgram, void, GLuint) X(glGetAttribLocation, GLint, GLuint, const GLchar *) X(glGetUniformLocation, GLint, GLuint, const GLchar *) \
    X(glUniform1i, void, GLint, GLint) X(glUniform1f, void, GLint, GLfloat) X(glUniform2i, void, GLint, GLint, GLint) X(glUniform2f, void, GLint, GLfloat, GLfloat) X(glUniform4f, void, GLint, GLfloat, GLfloat, GLfloat, GLfloat) \
    X(glClearColor, void, GLfloat, GLfloat, GLfloat, GLfloat) X(glClear, void, GLbitfield) X(glViewport, void, GLint, GLint, GLsizei, GLsizei) \
    X(glDrawArrays, void, GLenum, GLint, GLsizei) X(glFinish, void, void) X(glGetError, GLenum, void) X(glReadPixels, void, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *) \
    X(glGenFramebuffers, void, GLsizei, GLuint *) X(glBindFramebuffer, void, GLenum, GLuint) X(glGenRenderbuffers, void, GLsizei, GLuint *) X(glBindRenderbuffer, void, GLenum, GLuint) \
    X(glRenderbufferStorage, void, GLenum, GLenum, GLsizei, GLsizei) X(glFramebufferRenderbuffer, void, GLenum, GLenum, GLenum, GLuint) \
    X(glGenTextures, void, GLsizei, GLuint *) X(glBindTexture, void, GLenum, GLuint) X(glActiveTexture, void, GLenum) \
    X(glTexImage2D, void, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *) X(glTexParameteri, void, GLenum, GLenum, GLint)
#define DECL(name, ret, ...) static ret (*name)(__VA_ARGS__);
BASE(DECL)
#undef DECL

static int near(int a, int b) { return a - b <= 1 && b - a <= 1; }
static void pxs(int x, int y, uint8_t p[4], char *out) { memset(p, 0, 4); glReadPixels(x, y, 1, 1, 0x1908, 0x1401, p); sprintf(out, "%u %u %u %u", p[0], p[1], p[2], p[3]); }
static int is(const uint8_t p[4], int r, int g, int b, int a) { return near(p[0], r) && near(p[1], g) && near(p[2], b) && near(p[3], a); }
static char *slurp(const char *name) {
    char path[1024]; snprintf(path, sizeof path, "%s/%s", getenv("T_GL_DIR"), name); FILE *f = fopen(path, "rb"); if (!f) { printf("✗ 读不到 %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); char *s = calloc(1, (size_t)n + 1); if (fread(s, 1, (size_t)n, f) != (size_t)n) exit(1); fclose(f); return s;
}
static GLuint shader_src(GLenum type, const char *src, GLint *ok) {
    GLuint s = glCreateShader(type); glShaderSource(s, 1, &src, NULL); glCompileShader(s); glGetShaderiv(s, 0x8B81, ok); return s;
}
static GLuint shader(GLenum type, const char *file, GLint *ok) { char *src = slurp(file); GLuint s = shader_src(type, src, ok); free(src); return s; }
static GLuint program(const char *v, const char *f, GLint *vok, GLint *fok, GLint *lok) {
    GLuint p = glCreateProgram(); glAttachShader(p, shader(0x8B31, v, vok)); glAttachShader(p, shader(0x8B30, f, fok)); glLinkProgram(p); glGetProgramiv(p, 0x8B82, lok); return p;
}
static uint64_t st[4];   // 首遇 / 编好 / 坏 / 读缓存
static void stats(void) { dm_gl_rt_stats(&st[0], &st[1], &st[2], &st[3]); }
#define QUAD(x0, y0, x1, y1, r, g, b) x0, y0, r, g, b,  x1, y0, r, g, b,  x0, y1, r, g, b,  x1, y0, r, g, b,  x1, y1, r, g, b,  x0, y1, r, g, b
static GLuint g_vao, g_vbo;
// tri / api_es300（aPos vec2 + aCol vec3，uOff、uTint）：左半四边形 (1, 0, 0)，读回左 / 右
static void draw_left_red(GLuint p, uint8_t l[4], uint8_t r[4], char *ls, char *rs) {
    glClearColor(0, 0, 1, 1); glClear(0x4000); glUseProgram(p); glBindVertexArray(g_vao); glBindBuffer(0x8892, g_vbo);
    const float q[] = {QUAD(-1, -1, 0, 1, 1, 0, 0)}; glBufferData(0x8892, sizeof q, q, 0x88E4);
    GLint a = glGetAttribLocation(p, "aPos"), c = glGetAttribLocation(p, "aCol");
    glVertexAttribPointer((GLuint)a, 2, 0x1406, 0, 20, (void *)0); glEnableVertexAttribArray((GLuint)a); glVertexAttribPointer((GLuint)c, 3, 0x1406, 0, 20, (void *)8); glEnableVertexAttribArray((GLuint)c);
    glUniform2f(glGetUniformLocation(p, "uOff"), 0, 0); glUniform4f(glGetUniformLocation(p, "uTint"), 1, 1, 1, 1);
    glDrawArrays(4, 0, 6); glFinish(); pxs(16, 32, l, ls); pxs(48, 32, r, rs);
}
// texture100（aPos vec2，uTex）：采样 1×1 纯绿，画满，读中心
static void draw_tex_green(GLuint p, uint8_t m[4], char *ms) {
    static GLuint tex; const uint8_t green[4] = {0, 255, 0, 255};
    if (!tex) { glGenTextures(1, &tex); glActiveTexture(0x84C0); glBindTexture(0x0DE1, tex); glTexImage2D(0x0DE1, 0, 0x8058, 1, 1, 0, 0x1908, 0x1401, green); glTexParameteri(0x0DE1, 0x2801, 0x2600); }
    glClearColor(0, 0, 1, 1); glClear(0x4000); glUseProgram(p); glBindVertexArray(g_vao); glBindBuffer(0x8892, g_vbo);
    const float q[] = {-1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1}; glBufferData(0x8892, sizeof q, q, 0x88E4);
    GLint a = glGetAttribLocation(p, "aPos"); glVertexAttribPointer((GLuint)a, 2, 0x1406, 0, 8, (void *)0); glEnableVertexAttribArray((GLuint)a);
    glActiveTexture(0x84C0); glBindTexture(0x0DE1, tex); glUniform1i(glGetUniformLocation(p, "uTex"), 0);
    glDrawArrays(4, 0, 6); glFinish(); pxs(32, 32, m, ms);
}
static int count_cache(const char *ext) {
    char d[1200]; snprintf(d, sizeof d, "%s/gl", getenv("DM_MSL_FALLBACK")); DIR *dp = opendir(d); if (!dp) return 0; int n = 0; struct dirent *e;
    while ((e = readdir(dp))) { size_t l = strlen(e->d_name); if (l > strlen(ext) && !strcmp(e->d_name + l - strlen(ext), ext)) n++; }
    closedir(dp); return n;
}

int main(void) { alarm(120); @autoreleasepool {
#define LOAD(name, ret, ...) name = (ret (*)(__VA_ARGS__))gpa(#name); if (!name) { printf("✗ 取不到入口 %s\n", #name); return 1; }
    BASE(LOAD)
    EGLDisplay (*eglGetDisplay)(void *) = gpa("eglGetDisplay"); EGLBoolean (*eglInitialize)(EGLDisplay, EGLint *, EGLint *) = gpa("eglInitialize");
    EGLBoolean (*eglBindAPI)(EGLenum) = gpa("eglBindAPI"); EGLBoolean (*eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *) = gpa("eglChooseConfig");
    EGLSurface (*eglCreateWindowSurface)(EGLDisplay, EGLConfig, void *, const EGLint *) = gpa("eglCreateWindowSurface");
    EGLContext (*eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *) = gpa("eglCreateContext");
    EGLBoolean (*eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext) = gpa("eglMakeCurrent");
    eglBindAPI(0x30A0); const EGLint cfg_attr[] = {0x3040, 0x0040, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038}, ctx_attr[] = {0x3098, 3, 0x30FB, 2, 0x3038};
    EGLDisplay dpy = eglGetDisplay(NULL); EGLint ma, mi; eglInitialize(dpy, &ma, &mi); EGLConfig cfg; EGLint n; eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n);
    EGLSurface sf = eglCreateWindowSurface(dpy, cfg, NULL, NULL); EGLContext ctx = eglCreateContext(dpy, cfg, NULL, ctx_attr);
    if (!eglMakeCurrent(dpy, sf, sf, ctx)) { printf("✗ 建上下文失败\n"); return 1; }
    glGenVertexArrays(1, &g_vao); glGenBuffers(1, &g_vbo);
    GLuint fb, rb; glGenFramebuffers(1, &fb); glBindFramebuffer(0x8D40, fb); glGenRenderbuffers(1, &rb); glBindRenderbuffer(0x8D41, rb);
    glRenderbufferStorage(0x8D41, 0x8058, 64, 64); glFramebufferRenderbuffer(0x8D40, 0x8CE0, 0x8D41, rb); glViewport(0, 0, 64, 64);
    int pass = atoi(getenv("T_GL_RT_PASS") ? getenv("T_GL_RT_PASS") : "1");
    uint8_t l[4], r[4], m[4]; char ls[32], rs[32], ms[32]; GLint vok = 0, fok = 0, lok = 0;
    if (pass == 1) {
        printf("A 库命中走库\n");
        GLuint tri = program("tri.vert", "tri.frag", &vok, &fok, &lok); stats();
        CHECK(vok == 1 && fok == 1 && lok == 1 && st[0] == 0, "tri 在离线库：编译 %d / %d、链接 %d、首遇 %llu（期望 0）", vok, fok, lok, (unsigned long long)st[0]);
        draw_left_red(tri, l, r, ls, rs); CHECK(is(l, 255, 0, 0, 255) && is(r, 0, 0, 255, 255) && !glGetError(), "左红（%s）、右蓝（%s）", ls, rs);
        printf("B 库没有 → 后台翻译\n");
        GLuint es3 = program("api_es300.vert", "api_es300.frag", &vok, &fok, &lok); GLint vok1 = 0, fok1 = 0, lok1 = 0;
        GLuint es1 = program("texture100.vs", "texture100.fs", &vok1, &fok1, &lok1); stats();
        CHECK(vok == 1 && fok == 1 && lok == 1 && vok1 == 1 && fok1 == 1 && lok1 == 1 && st[0] == 4, "ES 3.00 / ES 1.00 两个程序：编译 %d %d %d %d、链接 %d %d、首遇 %llu（期望 4）", vok, fok, vok1, fok1, lok, lok1, (unsigned long long)st[0]);
        draw_left_red(es3, l, r, ls, rs); CHECK(is(l, 255, 0, 0, 255) && is(r, 0, 0, 255, 255) && !glGetError(), "ES 3.00 现编：左红（%s）、右蓝（%s）", ls, rs);
        draw_tex_green(es1, m, ms); CHECK(is(m, 0, 255, 0, 255) && !glGetError(), "ES 1.00 现编：采样 1×1 绿贴图画满，中心 %s", ms);
        stats(); int rows = count_cache(".row"), msls = count_cache(".metal");
        CHECK(st[1] == 4 && st[2] == 0 && rows == 4 && msls == 4, "编好 %llu（期望 4）、坏 %llu、缓存 .row %d / .metal %d（期望 4 / 4）", (unsigned long long)st[1], (unsigned long long)st[2], rows, msls);
        printf("C 翻译失败照旧报红\n");
        uint64_t err0 = gl_bad_err; const char *junk = "#version 310 es\nprecision highp float;\nout vec4 o;\nvoid main() { o = no_such_function(1.0); }\n";
        GLint bok = 1; GLuint bs = shader_src(0x8B30, junk, &bok); char logb[700] = ""; GLsizei got = 0; glGetShaderInfoLog(bs, sizeof logb, &got, logb);
        GLuint bp = glCreateProgram(); GLint vs_ok = 0; glAttachShader(bp, shader(0x8B31, "api_es300.vert", &vs_ok)); glAttachShader(bp, bs); glLinkProgram(bp); GLint bl = 1; glGetProgramiv(bp, 0x8B82, &bl);
        stats(); uint64_t bad1 = st[2];
        CHECK(bok == 0 && !strncmp(logb, "翻译失败", strlen("翻译失败")) && bl == 0 && bad1 == 1 && gl_bad_err == err0 + 1, "编译 %d、日志「%.60s…」、链接 %d、坏 %llu、直连异常 +%llu", bok, logb, bl, (unsigned long long)bad1, (unsigned long long)(gl_bad_err - err0));
        GLint bok2 = 1; shader_src(0x8B30, junk, &bok2); stats();
        CHECK(bok2 == 0 && st[2] == bad1, "同一源码再编：编译 %d、不重翻（坏计数仍 %llu）", bok2, (unsigned long long)st[2]);
        printf("F 结构体数组 uniform\n");
        uint64_t m0 = st[0]; GLuint sa = program("api_es300.vert", "api_structarr.frag", &vok, &fok, &lok); stats();
        GLint l1 = glGetUniformLocation(sa, "Lights[1].color"), l2 = glGetUniformLocation(sa, "Lights[2].color");
        CHECK(vok == 1 && fok == 1 && lok == 1 && st[0] == m0 + 1 && l1 != -1 && l2 == -1, "编译 %d / %d、链接 %d、首遇 +%llu（期望 1）、Lights[1].color 位置 %d（期望不是 −1）、Lights[2].color %d（期望 −1）",
              vok, fok, lok, (unsigned long long)(st[0] - m0), l1, l2);
        glUseProgram(sa);
        glUniform4f(glGetUniformLocation(sa, "Lights[0].color"), 1, 0, 0, 1); glUniform1f(glGetUniformLocation(sa, "Lights[0].scale"), 0.5f);
        glUniform4f(l1, 0, 1, 0, 1); glUniform1f(glGetUniformLocation(sa, "Lights[1].scale"), 0.5f); glUniform2i(glGetUniformLocation(sa, "uSel"), 2, 2);
        draw_left_red(sa, l, r, ls, rs); CHECK(is(l, 128, 128, 0, 255) && is(r, 0, 0, 255, 255) && !glGetError(), "左 (0.5, 0.5, 0, 1)（%s）、右蓝（%s）", ls, rs);
        printf("G float 减 const int 的顶点\n");
        uint64_t g0 = st[0]; GLuint cv = program("api_conv.vert", "api_es300.frag", &vok, &fok, &lok); stats();
        CHECK(vok == 1 && fok == 1 && lok == 1 && st[0] == g0 + 1, "编译 %d / %d、链接 %d、首遇 +%llu（期望 1）", vok, fok, lok, (unsigned long long)(st[0] - g0));
        draw_left_red(cv, l, r, ls, rs); CHECK(is(l, 255, 0, 0, 255) && is(r, 0, 0, 255, 255) && !glGetError(), "左红（%s）、右蓝（%s）", ls, rs);
    } else {
        printf("D 第二次命中缓存\n");
        GLuint es3 = program("api_es300.vert", "api_es300.frag", &vok, &fok, &lok); GLint vok1 = 0, fok1 = 0, lok1 = 0;
        GLuint es1 = program("texture100.vs", "texture100.fs", &vok1, &fok1, &lok1);
        draw_left_red(es3, l, r, ls, rs); draw_tex_green(es1, m, ms); stats();
        CHECK(vok == 1 && fok == 1 && vok1 == 1 && fok1 == 1 && lok == 1 && lok1 == 1 && st[0] == 0 && st[3] == 6 && st[1] == 0,
              "编译 / 链接全成；首遇 %llu（期望 0）、读缓存 %llu（期望 6）、新翻 %llu（期望 0）", (unsigned long long)st[0], (unsigned long long)st[3], (unsigned long long)st[1]);
        CHECK(is(l, 255, 0, 0, 255) && is(r, 0, 0, 255, 255) && is(m, 0, 255, 0, 255) && !glGetError(), "ES 3.00 左红（%s）右蓝（%s）；ES 1.00 中心绿（%s）", ls, rs, ms);
    }
    printf("E 直连就绪判定\n");
    { int e0 = s2a_gl_lib_ready(getenv("T_GD_EMPTY")), e1 = s2a_gl_lib_ready(getenv("T_GD_LIB")), e2 = s2a_gl_lib_ready(getenv("T_GD_NOLIB"));
      CHECK(e0 == 1 && e1 == 1 && e2 == 0, "只有表头 %d（期望 1）、表 + 库 %d（期望 1）、有行没库 %d（期望 0）", e0, e1, e2); }
    printf("%s t_gl_rt 第 %d 遍：%d 项，失败 %d\n", fails ? "✗" : "✓", pass, checks, fails); return fails != 0;
}}
