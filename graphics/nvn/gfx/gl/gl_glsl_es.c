// GLSL 源码改写层：游戏交给 glShaderSource 的 GLSL ES 1.00 / 3.00（及 NVIDIA 驱动多收的写法）→ glslang -V 收的 GLSL ES 3.10 文本。
// 出包离线链（translator/gl_shaders.py，经本文件的命令行入口 S2A_GLSL_ES_MAIN）与宿主运行时兜底（gl_xlate.c，gl_prog.m 调）共用这一份实现，不写两遍。
// 两步，与 gl_shaders.py translate() 的顺序一致：
//   ① s2a_glsl_es_prefix（原文、预处理之前）：第一条「#version 300 / 310 / 320」没写 es → 补「 es」（NVIDIA 按 ES 读，glslang 照规范要求写 es；FINAL FANTASY VII 的 ff7/shaders/*.glsl）；
//      后面跟注释的 es 插在注释前，跟 core / compatibility 的换成 es（#749）
//   ② s2a_glsl_es_rewrite（glslang 预处理之后的文本）：
//      · 版本：没有 #version 或 #version 100 = GLSL ES 1.00 → 去掉版本行，头上加「#version 310 es」+ float / int 缺省精度 highp（ES 1.00 片元常只在 #ifdef GL_ES 下设精度，
//        预处理时 GL_ES 没定义）；#version 300 es → 310 es（3.10 是 3.00 的超集，语义不变）；
//      · ES 1.00 按阶段：attribute → in、varying → out（顶点）/ in（片元）；gl_FragColor / gl_FragData[0] → location 0 的输出 s2a_FragColor，gl_FragData[1..7]（EXT_draw_buffers）→ location 1..7 的 s2a_FragData<n>，
//        gl_FragDepthEXT（EXT_frag_depth）→ gl_FragDepth；
//      · 旧纹理函数（各版本都改，NVIDIA 收）：texture2D / textureCube → texture，texture2DLod / textureCubeLod → textureLod，texture2DProj → textureProj，texture2DProjLod → textureProjLod，
//        EXT_shader_texture_lod 的 texture2DLodEXT / textureCubeLodEXT → textureLod、texture2DProjLodEXT → textureProjLod、texture2DGradEXT / textureCubeGradEXT → textureGrad、texture2DProjGradEXT → textureProjGrad，
//        EXT_shadow_samplers 的 shadow2DEXT → texture、shadow2DProjEXT → textureProj（-V 下 glslang 把 textureCube 读成 Vulkan 的类型名，宏改不了，只能在预处理后改）；
//      · 把 gl_Position 重新声明成普通输出的一行删掉（数码宝贝 main 里内置精灵着色器 `out float4 vPosition;`，vPosition 宏成 gl_Position）；
//      · textureOffset / textureLodOffset 的偏移不是常量（内置 FXAA、FINAL FANTASY VII 的 FXAA）：Metal 的采样偏移也必须是常量，改成在 P + 偏移 / 该级尺寸处采样。
// 匹配口径照 Python re（gl_shaders.py 原来的正则）：\b 两侧按 [A-Za-z0-9_] 与非 ASCII 字节算单词字符（Python 按 Unicode 字母算；源码经预处理已去注释，GLSL 标识符只有 ASCII），\s = 空格 \t \n \r \f \v \x1c–\x1f。
// 没覆盖（遇到照旧由 glslang 报红）：ES 1.00 里拿 3.x 关键字 / 内建函数名（texture、sample、flat …）当变量名的源码、gl_FragData 用变量下标。
#include "gl_glsl_es.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

typedef struct { char *p; size_t n, cap; int oom; } sb;
static void sb_put(sb *b, const char *s, size_t n) {
    if (b->oom) return;
    if (b->n + n + 1 > b->cap) { size_t c = b->cap ? b->cap : 256; while (c < b->n + n + 1) c *= 2; char *q = realloc(b->p, c); if (!q) { b->oom = 1; return; } b->p = q; b->cap = c; }
    memcpy(b->p + b->n, s, n); b->n += n; b->p[b->n] = 0;
}
static void sb_str(sb *b, const char *s) { sb_put(b, s, strlen(s)); }
static char *sb_take(sb *b, size_t *n) { if (b->oom) { free(b->p); return NULL; } if (!b->p) sb_put(b, "", 0); if (b->oom) return NULL; if (n) *n = b->n; return b->p; }

static int is_word(unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c >= 0x80; }
static int is_space(unsigned char c) { return c == ' ' || (c >= '\t' && c <= '\r') || (c >= 0x1c && c <= 0x1f); }
static int boundary_before(const char *t, size_t i) { return i == 0 || !is_word((unsigned char)t[i - 1]); }
static int starts(const char *t, size_t n, size_t i, const char *w) { size_t l = strlen(w); return i + l <= n && !memcmp(t + i, w, l); }
static size_t skip_space(const char *t, size_t n, size_t i) { while (i < n && is_space((unsigned char)t[i])) i++; return i; }

// 「\bNAME\s*\(」→「REPL(」，一遍、左到右、不重叠（re.sub）
static char *sub_call(const char *t, size_t n, const char *name, const char *repl, size_t *on) {
    sb o = {0}; size_t i = 0, last = 0, l = strlen(name);
    while (i < n) {
        if (t[i] == name[0] && boundary_before(t, i) && starts(t, n, i, name)) {
            size_t j = skip_space(t, n, i + l);
            if (j < n && t[j] == '(') { sb_put(&o, t + last, i - last); sb_str(&o, repl); sb_put(&o, "(", 1); i = last = j + 1; continue; }
        }
        i++;
    }
    sb_put(&o, t + last, n - last); return sb_take(&o, on);
}
// 「\bWORD\b」→「REPL」
static char *sub_word(const char *t, size_t n, const char *word, const char *repl, size_t *on, int *hits) {
    sb o = {0}; size_t i = 0, last = 0, l = strlen(word);
    while (i < n) {
        if (t[i] == word[0] && boundary_before(t, i) && starts(t, n, i, word) && (i + l == n || !is_word((unsigned char)t[i + l]))) {
            sb_put(&o, t + last, i - last); sb_str(&o, repl); i = last = i + l; if (hits) (*hits)++; continue;
        }
        i++;
    }
    sb_put(&o, t + last, n - last); return sb_take(&o, on);
}
// 「\bgl_FragData\s*\[\s*K\s*\]」在 i 处的长度（K 为一位数字字符串），不匹配 0
static size_t frag_data_at(const char *t, size_t n, size_t i, char k) {
    if (!boundary_before(t, i) || !starts(t, n, i, "gl_FragData")) return 0;
    size_t j = skip_space(t, n, i + 11); if (j >= n || t[j] != '[') return 0;
    j = skip_space(t, n, j + 1); if (j >= n || t[j] != k) return 0;
    j = skip_space(t, n, j + 1); if (j >= n || t[j] != ']') return 0;
    return j + 1 - i;
}

char *s2a_glsl_es_prefix(const char *src, size_t n, size_t *out_n) {
    // 第一条 #version 是 300 / 310 / 320、没写 es 时补成 es（NVIDIA 按 ES 读，glslang 照规范要求写 es）：
    //   ^([ \t]*#[ \t]*version[ \t]+3[012]0)[ \t]*(\r?)$ → \1 es\2（原规则）；
    //   #749：版本号后面跟注释（// 或 /*）→ es 插在注释前；跟桌面 GL 的 core / compatibility → 换成 es（这两个 profile 在 ES 下本来就编不过）。
    //   已写 es、版本号不是这三个、后面是别的写法 → 原样（交 glslang 照常报）。只看第一条 #version：后面的版本行本来就是错的，不替它改
    for (size_t ls = 0; ls <= n; ) {
        size_t j = ls;
        while (j < n && (src[j] == ' ' || src[j] == '\t')) j++;
        if (j < n && src[j] == '#') {
            j++; while (j < n && (src[j] == ' ' || src[j] == '\t')) j++;
            if (starts(src, n, j, "version")) {
                j += 7; size_t k = j; while (k < n && (src[k] == ' ' || src[k] == '\t')) k++;
                if (k > j && k + 3 <= n && src[k] == '3' && (src[k + 1] == '0' || src[k + 1] == '1' || src[k + 1] == '2') && src[k + 2] == '0'
                    && (k + 3 == n || !(src[k + 3] >= '0' && src[k + 3] <= '9'))) {
                    size_t g1 = k + 3, m = g1; while (m < n && (src[m] == ' ' || src[m] == '\t')) m++;
                    int cr = m < n && src[m] == '\r'; size_t e = m + cr;
                    size_t le = m; while (le < n && src[le] != '\n') le++;   // 版本行行尾
                    #define WORD_AT(w) (starts(src, n, m, w) && (m + strlen(w) == le || !((src[m + strlen(w)] | 0x20) >= 'a' && (src[m + strlen(w)] | 0x20) <= 'z') && src[m + strlen(w)] != '_' && !(src[m + strlen(w)] >= '0' && src[m + strlen(w)] <= '9')))
                    sb o = {0};
                    if (e == n || src[e] == '\n') {   // 原规则：后面只有空白
                        sb_put(&o, src, g1); sb_str(&o, " es"); if (cr) sb_put(&o, "\r", 1); sb_put(&o, src + e, n - e); return sb_take(&o, out_n);
                    }
                    if (starts(src, n, m, "//") || starts(src, n, m, "/*")) {   // 跟注释：es 插在注释前
                        sb_put(&o, src, g1); sb_str(&o, " es "); sb_put(&o, src + m, n - m); return sb_take(&o, out_n);
                    }
                    size_t wl = WORD_AT("core") ? 4 : WORD_AT("compatibility") ? 13 : 0;
                    if (wl) {   // 桌面 profile：换成 es
                        sb_put(&o, src, g1); sb_str(&o, " es"); sb_put(&o, src + m + wl, n - m - wl); return sb_take(&o, out_n);
                    }
                    #undef WORD_AT
                }
                break;   // 第一条 #version 已看过：不是要补的形态就原样
            }
        }
        const char *nl = memchr(src + ls, '\n', n - ls); if (!nl) break; ls = (size_t)(nl - src) + 1;
    }
    sb o = {0}; sb_put(&o, src, n); return sb_take(&o, out_n);
}

// GLSL ES 1.00 → 3.10 文本（gl_shaders.py 原 es100）：顶点 attribute / varying、片元 varying / gl_FragColor / gl_FragData、缺省精度
static char *es100(const char *t, size_t n, char stage, size_t *on) {
    sb head = {0}; sb_str(&head, "#version 310 es\nprecision highp float;\nprecision highp int;\n");
    char *cur = malloc(n + 1); size_t cn = n; if (!cur) return NULL; memcpy(cur, t, n); cur[n] = 0;
#define STEP(call) do { size_t nn; char *x = (call); free(cur); if (!x) { free(head.p); return NULL; } cur = x; cn = nn; } while (0)
    if (stage == 'v') { STEP(sub_word(cur, cn, "attribute", "in", &nn, NULL)); STEP(sub_word(cur, cn, "varying", "out", &nn, NULL)); }
    else if (stage == 'f') {
        STEP(sub_word(cur, cn, "varying", "in", &nn, NULL));
        // \bgl_FragColor\b|\bgl_FragData\s*\[\s*0\s*\] → s2a_FragColor；gl_FragData[1..7] → s2a_FragData<n>；改到了才声明输出
        unsigned used = 0; sb o = {0}; size_t i = 0, last = 0;
        while (i < cn) {
            size_t m = 0; int k = -1;
            if (cur[i] == 'g' && boundary_before(cur, i)) {
                if (starts(cur, cn, i, "gl_FragColor") && (i + 12 == cn || !is_word((unsigned char)cur[i + 12]))) { m = 12; k = 0; }
                else for (int d = 0; d < 8 && !m; d++) if ((m = frag_data_at(cur, cn, i, (char)('0' + d)))) k = d;
            }
            if (m) { sb_put(&o, cur + last, i - last); if (k) { char nm[24]; snprintf(nm, sizeof nm, "s2a_FragData%d", k); sb_str(&o, nm); } else sb_str(&o, "s2a_FragColor"); used |= 1u << k; i = last = i + m; continue; }
            i++;
        }
        sb_put(&o, cur + last, cn - last); free(cur); cur = sb_take(&o, &cn); if (!cur) { free(head.p); return NULL; }
        if (used & 1) sb_str(&head, "layout(location = 0) out vec4 s2a_FragColor;\n");
        for (int d = 1; d < 8; d++) if (used >> d & 1) { char l[80]; snprintf(l, sizeof l, "layout(location = %d) out vec4 s2a_FragData%d;\n", d, d); sb_str(&head, l); }
        STEP(sub_word(cur, cn, "gl_FragDepthEXT", "gl_FragDepth", &nn, NULL));
    }
#undef STEP
    sb_put(&head, cur, cn); free(cur); return sb_take(&head, on);
}

// 调用的参数：t[i] 是「(」；按圆括号深度拆第一层逗号（gl_shaders.py 原 call_args）。返回参数个数，*end = 「)」之后；括号不配对返回 -1
enum { MAXARG = 8 };
static int call_args(const char *t, size_t n, size_t i, size_t as[MAXARG], size_t ae[MAXARG], size_t *end) {
    int depth = 0, na = 0; size_t start = i + 1;
    for (size_t k = i; k < n; k++) {
        char c = t[k];
        if (c == '(') depth++;
        else if (c == ')') { if (--depth == 0) { if (na < MAXARG) { as[na] = start; ae[na] = k; } na++; *end = k + 1; return na; } }
        else if (c == ',' && depth == 1) { if (na < MAXARG) { as[na] = start; ae[na] = k; } na++; start = k + 1; }
    }
    return -1;
}
static void strip(const char *t, size_t *s, size_t *e) { while (*s < *e && is_space((unsigned char)t[*s])) (*s)++; while (*e > *s && is_space((unsigned char)t[*e - 1])) (*e)--; }
// 偏移里有变量：在这段参数里去掉「\b[iu]?vec[234]\b」后还剩 [A-Za-z_]（re.sub 在参数子串上做：\b 以子串两端为界）
static int has_variable(const char *t, size_t s, size_t e) {
    for (size_t p = s; p < e; ) {
        if (p == s || !is_word((unsigned char)t[p - 1])) {
            size_t r = p + (t[p] == 'i' || t[p] == 'u');   // [iu]? 不吃的那一支要求 t[p] == 'v'，与吃掉的那支互斥，不必回溯
            if (r + 4 <= e && !memcmp(t + r, "vec", 3) && t[r + 3] >= '2' && t[r + 3] <= '4' && (r + 4 == e || !is_word((unsigned char)t[r + 4]))) { p = r + 4; continue; }
        }
        if ((t[p] >= 'A' && t[p] <= 'Z') || (t[p] >= 'a' && t[p] <= 'z') || t[p] == '_') return 1;
        p++;
    }
    return 0;
}

static const char *const OLD_TEX[][2] = {
    {"texture2DLod", "textureLod"}, {"textureCubeLod", "textureLod"}, {"texture2DProj", "textureProj"}, {"texture2D", "texture"}, {"textureCube", "texture"},
    {"texture2DProjLod", "textureProjLod"}, {"texture2DLodEXT", "textureLod"}, {"textureCubeLodEXT", "textureLod"}, {"texture2DProjLodEXT", "textureProjLod"},
    {"texture2DGradEXT", "textureGrad"}, {"textureCubeGradEXT", "textureGrad"}, {"texture2DProjGradEXT", "textureProjGrad"}, {"shadow2DEXT", "texture"}, {"shadow2DProjEXT", "textureProj"},
};
static char *fixups(char *t, size_t n, size_t *on, char *err, size_t errn) {
    for (size_t k = 0; k < sizeof OLD_TEX / sizeof *OLD_TEX; k++) { size_t nn; char *x = sub_call(t, n, OLD_TEX[k][0], OLD_TEX[k][1], &nn); free(t); if (!x) return NULL; t = x; n = nn; }
    // ^[ \t]*out\s+(?:highp\s+|mediump\s+|lowp\s+)?vec4\s+gl_Position\s*; → 删（多行）
    { sb o = {0}; size_t i = 0, last = 0;
      while (i < n) {
          if (i == 0 || t[i - 1] == '\n') {
              size_t j = i; while (j < n && (t[j] == ' ' || t[j] == '\t')) j++;
              if (starts(t, n, j, "out") && j + 3 < n && is_space((unsigned char)t[j + 3])) {
                  j = skip_space(t, n, j + 3);
                  static const char *const pq[] = {"highp", "mediump", "lowp"};
                  for (int q = 0; q < 3; q++) { size_t l = strlen(pq[q]); if (starts(t, n, j, pq[q]) && j + l < n && is_space((unsigned char)t[j + l])) { j = skip_space(t, n, j + l); break; } }
                  if (starts(t, n, j, "vec4") && j + 4 < n && is_space((unsigned char)t[j + 4])) {
                      j = skip_space(t, n, j + 4);
                      if (starts(t, n, j, "gl_Position")) { j = skip_space(t, n, j + 11); if (j < n && t[j] == ';') { sb_put(&o, t + last, i - last); i = last = j + 1; continue; } }
                  }
              }
          }
          i++;
      }
      sb_put(&o, t + last, n - last); free(t); size_t nn; t = sb_take(&o, &nn); if (!t) return NULL; n = nn; }
    // \btexture(Lod)?Offset\s*\( 偏移不是常量 → 在 P + 偏移 / 尺寸处采样（re.finditer 顺序；落在已改写调用里面的跳过）
    sb o = {0}; size_t i = 0, scan = 0;
    while (scan < n) {
        size_t m = scan; int lod = 0;
        if (!(t[m] == 't' && boundary_before(t, m) && starts(t, n, m, "texture"))) { scan++; continue; }
        size_t j = m + 7; if (starts(t, n, j, "Lod")) { lod = 1; j += 3; }
        if (!starts(t, n, j, "Offset")) { scan++; continue; }
        j = skip_space(t, n, j + 6); if (j >= n || t[j] != '(') { scan++; continue; }
        size_t mend = j + 1; scan = mend;   // finditer 从匹配尾接着找
        if (m < i) continue;
        size_t as[MAXARG], ae[MAXARG], end; int na = call_args(t, n, j, as, ae, &end);
        if (na < 0) { snprintf(err, errn, "unbalanced parentheses"); free(t); free(o.p); return NULL; }
        if (na == 3 + lod && has_variable(t, as[na - 1], ae[na - 1])) {
            size_t s0 = as[0], e0 = ae[0], s1 = as[1], e1 = ae[1], so = as[na - 1], eo = ae[na - 1]; strip(t, &s0, &e0); strip(t, &s1, &e1); strip(t, &so, &eo);
            sb_put(&o, t + i, m - i);
#define P(a, b) sb_put(&o, t + (a), (b) - (a))
            if (lod) { size_t sl = as[2], el = ae[2]; strip(t, &sl, &el);
                sb_str(&o, "textureLod("); P(s0, e0); sb_str(&o, ", ("); P(s1, e1); sb_str(&o, ") + vec2("); P(so, eo); sb_str(&o, ") / vec2(textureSize("); P(s0, e0); sb_str(&o, ", int("); P(sl, el); sb_str(&o, "))), "); P(sl, el); sb_str(&o, ")"); }
            else { sb_str(&o, "texture("); P(s0, e0); sb_str(&o, ", ("); P(s1, e1); sb_str(&o, ") + vec2("); P(so, eo); sb_str(&o, ") / vec2(textureSize("); P(s0, e0); sb_str(&o, ", 0)))"); }
#undef P
            i = end;
        }
    }
    sb_put(&o, t + i, n - i); free(t); return sb_take(&o, on);
}

char *s2a_glsl_es_rewrite(const char *pre, size_t n, char stage, size_t *out_n, char *err, size_t errn) {
    if (errn) err[0] = 0;
    if (stage != 'v' && stage != 'f' && stage != 'c') { snprintf(err, errn, "stage %c is not v / f / c", stage); return NULL; }
    const char *at = NULL;
    for (size_t i = 0; i + 8 <= n; i++) if (!memcmp(pre + i, "#version", 8)) { at = pre + i; break; }
    char *body; size_t bn;
    size_t rest = at ? n - (size_t)(at - pre) : 0;
    // #version\s+100\b / #version\s+300\s+es\b
    int v100 = 0, v300 = 0;
    if (at) {
        size_t j = skip_space(at, rest, 8);
        if (j > 8 && starts(at, rest, j, "100") && (j + 3 == rest || !is_word((unsigned char)at[j + 3]))) v100 = 1;
        else if (j > 8 && starts(at, rest, j, "300")) { size_t k = skip_space(at, rest, j + 3); if (k > j + 3 && starts(at, rest, k, "es") && (k + 2 == rest || !is_word((unsigned char)at[k + 2]))) v300 = 1; }
    }
    const char *nl = at ? memchr(at, '\n', rest) : NULL;
    if (at && v100) {   // 去掉版本行（到第一个换行为止，含换行），按 ES 1.00 改写
        sb o = {0}; sb_put(&o, pre, (size_t)(at - pre)); if (nl) sb_put(&o, nl + 1, n - (size_t)(nl + 1 - pre));
        size_t tn; char *tt = sb_take(&o, &tn); if (!tt) return NULL;
        body = es100(tt, tn, stage, &bn); free(tt);
    } else if (at) {   // 从 #version 起（之前的空行丢掉）；300 es 的版本行换成 310 es
        sb o = {0};
        if (v300) { sb_str(&o, "#version 310 es"); if (nl) sb_put(&o, nl, n - (size_t)(nl - pre)); }
        else sb_put(&o, at, rest);
        body = sb_take(&o, &bn);
    } else body = es100(pre, n, stage, &bn);
    if (!body) { if (errn && !err[0]) snprintf(err, errn, "out of memory"); return NULL; }
    return fixups(body, bn, out_n, err, errn);
}

#ifdef S2A_GLSL_ES_MAIN
// 命令行入口（出包离线链 gl_shaders.py 调）：glsl_es prefix < 原文 > 改后；glsl_es rewrite <vert|frag|comp> < 预处理后 > 3.10 文本。失败退 1、原因写 stderr
int main(int argc, char **argv) {
    sb in = {0}; char buf[65536]; size_t r;
    while ((r = fread(buf, 1, sizeof buf, stdin)) > 0) sb_put(&in, buf, r);
    size_t n; char *src = sb_take(&in, &n); if (!src) { fprintf(stderr, "out of memory\n"); return 1; }
    char *out = NULL, err[256] = ""; size_t on = 0;
    if (argc == 2 && !strcmp(argv[1], "prefix")) out = s2a_glsl_es_prefix(src, n, &on);
    else if (argc == 3 && !strcmp(argv[1], "rewrite")) out = s2a_glsl_es_rewrite(src, n, !strcmp(argv[2], "vert") ? 'v' : !strcmp(argv[2], "frag") ? 'f' : !strcmp(argv[2], "comp") ? 'c' : '?', &on, err, sizeof err);
    else { fprintf(stderr, "usage: glsl_es prefix | glsl_es rewrite <vert|frag|comp>\n"); return 2; }
    if (!out) { fprintf(stderr, "%s\n", err[0] ? err : "out of memory"); return 1; }
    fwrite(out, 1, on, stdout); free(out); free(src); return 0;
}
#endif
