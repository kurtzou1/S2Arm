// 片元颜色出口 half 舍入改写（翻译期）：片元主入口的 float4 color 输出按附件位图（[[buffer(GAL_COLOR_ROUND_SLOT)]]）在 return 前做 RTZ 量化（直连链另加可编程混合，见 k_pblend），
//   绘制处按附件格式及混合状态填位图（gal_state.m pso_color_round_mask）。原 MSL 其余部分一字不改；记录位 GAL_REC_COLOR_ROUND（gal_prog.m）。
//   纯 C、不引 Metal 头（#783）：编进直连翻译库 libdsx（graphics/dsx/Makefile，11-08；渲染器另链它），
//   Linux / Windows 出包机同编（Makefile 的 linux 目标、dsx_win.py），S2A.Dsh 的 NxgalSpvCross.ColorRound 经 DllImport("dsx") 调。
#include "gal_colorround.h"
#include "dsx_abi.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// 直连离线链和设备现编共用颜色出口规则；失败不生成未量化的新链产物。
// *out 与 nxgal_dmsh_xc_free 使用相同的 malloc/free 所有权。
NXGAL_API int32_t nxgal_dmsh_color_round(const char *msl, const char *entry, char **out, char *err, uint64_t errlen) {
    char why[256] = ""; *out = gal_color_round_pb_msl(msl, entry, why);   // 直连链（S2A.Dsh SpvCross.ColorRound）：带可编程混合开关（#674）
    if (!*out) { if (errlen) snprintf(err, errlen, "%s", why); return 1; }
    if (errlen) err[0] = 0;
    return 0;
}

// 片元阶段独占；同号的计算阶段槽用于共享内存溢出，两张参数表互不影响。
#define LS_HALF_SLOT GAL_COLOR_ROUND_SLOT

// 返回精确可表示为 half 的 FP32 值，附件随后采用哪种舍入模式都不会再次改变有限值。
// 不调用 float→half 转换：其默认模式随平台 / 编译路径而异。整数位运算也保留 ±0、INF 和 NaN。
static const char k_half_round[] =
"#ifndef S2A_HALF_ROUND\n"
"#define S2A_HALF_ROUND\n"
"static inline float s2a_half_rtz(float x) {\n"
"    uint u = as_type<uint>(x), e = (u >> 23) & 255u;\n"
"    if (e == 255u) return x;\n"
"    if (e > 142u) u = (u & 0x80000000u) | 0x477fe000u;\n"
"    else if (e >= 113u) u &= 0xffffe000u;\n"
"    else if (e >= 103u) u &= ~((1u << (126u - e)) - 1u);\n"
"    else u &= 0x80000000u;\n"
"    return as_type<float>(u);\n"
"}\n"
"static inline float4 s2a_half_rtz(float4 x) {\n"
"    return float4(s2a_half_rtz(x.x), s2a_half_rtz(x.y), s2a_half_rtz(x.z), s2a_half_rtz(x.w));\n"
"}\n"
"static inline float4 s2a_blend_zero_rgb(float4 x) {\n"
"    if (x.w == 0.0f) x.xyz = select(x.xyz, float3(0.0f), (as_type<uint3>(x.xyz) & 0x7f800000u) == 0x7f800000u);\n"
"    return x;\n"
"}\n"
"#endif\n";
const char *gal_color_round_helpers(void) { return k_half_round; }

// 可编程混合（#674 通用根修）：Maxwell 的 SET_BLEND_FLOAT_OPTION.ZERO_TIMES_ANYTHING_IS_ZERO（NVN 驱动初始化置 TRUE）——混合里每次「系数 × 颜色」
//   只要一个因子为 0 积就是 0（NaN / ±Inf 乘 0 得 0）；Metal 固定混合按 IEEE（0 × NaN = NaN），#674 时之笛地形黑块即此。每个 float4 颜色输出 n 带一个
//   函数常量 s2a_pb<n>_c（编号 GAL_PB_FC0 + n）：宿主给浮点附件开了混合的管线把它置真、把这个附件的固定混合关掉，入口就读目标像素（帧缓冲读取，
//   读入参数随常量门控：常量为假时参数不存在、不读帧缓冲）并按 27 号槽里的混合状态自己混合。27 号槽是 S2APBlend：第一个字仍是 RTZ / 清 NaN 位图
//   （只开位图时宿主照旧只绑 4 字节表项），其后是常量色与各附件的 (方程, 源系数, 目标系数) ×（RGB, A），取值即 NVN 枚举（nvn.h；期望值来源
//   graphics/nvn/tests/maxwell_blend_ref.py）。MIN / MAX 不乘系数，遇 NaN 取另一方（precise::，运行时是宽松数学）。第二源系数（SRC1_*）用输出 1 的值：
//   片元自己算，不需要双源硬件；只对附件 0（Maxwell 双源只在附件 0）
static const char k_pblend[] =
"#ifndef S2A_PBLEND\n"
"#define S2A_PBLEND\n"
"struct S2APBlend { uint mask; uint pad0, pad1, pad2; float4 k; uint4 f[8][2]; };\n"
"static inline float4 s2a_pb_mul(float4 x, float4 y) { return select(x * y, float4(0.0f), x == 0.0f || y == 0.0f); }\n"
"static inline float4 s2a_pb_factor(uint f, float4 s, float4 s1, float4 d, float4 k) {\n"
"    switch (f) {\n"
"    case 0x1u: return float4(0.0f);\n"
"    case 0x2u: return float4(1.0f);\n"
"    case 0x3u: return s;\n"
"    case 0x4u: return 1.0f - s;\n"
"    case 0x5u: return float4(s.w);\n"
"    case 0x6u: return float4(1.0f - s.w);\n"
"    case 0x7u: return float4(d.w);\n"
"    case 0x8u: return float4(1.0f - d.w);\n"
"    case 0x9u: return d;\n"
"    case 0xAu: return 1.0f - d;\n"
"    case 0xBu: return float4(float3(precise::fmin(s.w, 1.0f - d.w)), 1.0f);\n"
"    case 0x10u: return s1;\n"
"    case 0x11u: return 1.0f - s1;\n"
"    case 0x12u: return float4(s1.w);\n"
"    case 0x13u: return float4(1.0f - s1.w);\n"
"    case 0x61u: return k;\n"
"    case 0x62u: return 1.0f - k;\n"
"    case 0x63u: return float4(k.w);\n"
"    case 0x64u: return float4(1.0f - k.w);\n"
"    default: return float4(0.0f);\n"
"    }\n"
"}\n"
"static inline float4 s2a_pb_eq(uint4 st, float4 s, float4 s1, float4 d, float4 k) {\n"
"    if (st.x == 0x4u) return precise::fmin(s, d);\n"
"    if (st.x == 0x5u) return precise::fmax(s, d);\n"
"    float4 ps = s2a_pb_mul(s2a_pb_factor(st.y, s, s1, d, k), s), pd = s2a_pb_mul(s2a_pb_factor(st.z, s, s1, d, k), d);\n"
"    if (st.x == 0x2u) return ps - pd;\n"
"    if (st.x == 0x3u) return pd - ps;\n"
"    return ps + pd;\n"
"}\n"
"static inline float4 s2a_pblend(float4 s, float4 d, float4 s1, constant S2APBlend &b, uint i) {\n"
"    float4 rgb = s2a_pb_eq(b.f[i][0], s, s1, d, b.k), a = s2a_pb_eq(b.f[i][1], s, s1, d, b.k);\n"
"    return float4(rgb.xyz, a.w);\n"
"}\n"
"#endif\n";

typedef struct { char *s; size_t n, cap; int bad; } lsb;
// 追加 n 字节。n 都是同一段 MSL 里的指针差 / 串长，不会大到回绕；仍先挡住：n + 1 回绕会跳过扩容，GCC 14 的 -Wstringop-overflow
//   据此报 memcpy 越界（-Werror 下 linux 目标编不过，#1341 合入后 moongrant 报）。扩容失败同样只记 bad、不写，由 gal_color_round_msl 报红返回 NULL
static void lput(lsb *b, const char *p, size_t n) {
    if (b->bad || n >= (size_t)PTRDIFF_MAX - b->n) { b->bad = 1; return; }
    if (b->n + n + 1 > b->cap) {
        char *s = realloc(b->s, (b->n + n + 1) * 2); if (!s) { b->bad = 1; return; }
        b->s = s; b->cap = (b->n + n + 1) * 2;
    }
    memcpy(b->s + b->n, p, n); b->n += n; b->s[b->n] = 0;
}
static void lstr(lsb *b, const char *p) { lput(b, p, strlen(p)); }
static void lfmt(lsb *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void lfmt(lsb *b, const char *fmt, ...) {
    char t[1024]; va_list ap; va_start(ap, fmt); int n = vsnprintf(t, sizeof t, fmt, ap); va_end(ap);
    if (n > 0) lput(b, t, (size_t)n < sizeof t ? (size_t)n : sizeof t - 1);
}
static const char *lclose(const char *p) { int d = 0; for (const char *q = p; *q; q++) { if (*q == '(') d++; else if (*q == ')' && --d == 0) return q; } return NULL; }

// 一个「类型 名 [[属性]]」：参数（顶层逗号切）与结构体成员（一行一个）共用。a = 起点、nb..ne = 名、at..ae = [[ 里的属性文本 ]]（无属性 at = ae = NULL）、e = 终点
typedef struct { const char *a, *nb, *ne, *at, *ae, *e; } ldecl;
static int ldecl_parse(const char *p, const char *e, ldecl *o) {
    while (p < e && (*p == ' ' || *p == '\t')) p++;
    while (e > p && (e[-1] == ' ' || e[-1] == ';')) e--;
    const char *at = NULL, *ae = NULL;
    for (const char *q = p; q + 1 < e; q++) if (q[0] == '[' && q[1] == '[') { at = q + 2; break; }
    const char *ne = e;
    if (at) {
        for (const char *q = at; q + 1 < e; q++) if (q[0] == ']' && q[1] == ']') { ae = q; break; }
        if (!ae) return 0;
        ne = at - 2;
    }
    while (ne > p && ne[-1] == ' ') ne--;
    const char *nb = ne; while (nb > p && (isalnum((unsigned char)nb[-1]) || nb[-1] == '_')) nb--;
    if (nb == ne || nb == p) return 0;
    if (at) { while (at < ae && *at == ' ') at++; while (ae > at && ae[-1] == ' ') ae--; }
    *o = (ldecl){p, nb, ne, at, ae, e};
    return 1;
}
// 属性文本是否以 w 开头（后面接 '(' / ',' / 结尾）
static int lattr(const ldecl *d, const char *w) {
    size_t L = strlen(w); if (!d->at || (size_t)(d->ae - d->at) < L || strncmp(d->at, w, L)) return 0;
    char c = d->at + L < d->ae ? d->at[L] : 0; return c == 0 || c == '(' || c == ',' || c == ' ';
}
// 类型文本（去尾空格）是否恰为 t
static int ltype(const ldecl *d, const char *t) {
    const char *e = d->nb; while (e > d->a && e[-1] == ' ') e--;
    return (size_t)(e - d->a) == strlen(t) && !strncmp(d->a, t, (size_t)(e - d->a));
}
static void lattr_copy(const ldecl *d, char *o, size_t cap) {
    if (!d->at) { snprintf(o, cap, "（无属性）"); return; }
    size_t L = (size_t)(d->ae - d->at); if (L >= cap) L = cap - 1; memcpy(o, d->at, L); o[L] = 0;
}
// 结构体 name 的成员表：[*b, *e) 是「struct name\n{\n」之后到「\n};」之前的成员行
static int lstruct(const char *msl, const char *name, const char **b, const char **e) {
    char h[192]; snprintf(h, sizeof h, "struct %s\n{\n", name);
    const char *s = strstr(msl, h); if (!s) return 0;
    *b = s + strlen(h); const char *t = strstr(*b - 1, "\n};"); if (!t) return 0;
    *e = t + 1; return 1;
}

// 原入口定位（SPIRV-Cross 产出的格式约束）
typedef struct { const char *ls, *lp, *rp, *body, *be; char ret[128]; int eft, optnone; } lentry;
static int lentry_find(const char *msl, const char *entry, int stage, lentry *o, char *why) {
    memset(o, 0, sizeof *o);
    char pat[96]; snprintf(pat, sizeof pat, " %s(", entry);
    const char *kw = stage == 1 ? "vertex " : "fragment ", *sig = NULL, *rt = NULL;
    static const char *eft[] = {"[[ early_fragment_tests ]] fragment ", "[[early_fragment_tests]] fragment "};
    for (const char *q = strstr(msl, pat); q; q = strstr(q + 1, pat)) {
        const char *l0 = q; while (l0 > msl && l0[-1] != '\n') l0--;
        // 巨型着色器的入口在行首标了不优化（dmsh_build.py giant_optnone）：认这个前缀，函数体副本照样带上
        static const char *on = "[[clang::optnone]] "; int opt = !strncmp(l0, on, strlen(on)); const char *l = opt ? l0 + strlen(on) : l0;
        if (!strncmp(l, kw, strlen(kw))) { sig = q; o->ls = l0; rt = l + strlen(kw); o->optnone = opt; break; }
        if (stage == 5) for (int i = 0; i < 2; i++) if (!strncmp(l, eft[i], strlen(eft[i]))) {
            sig = q; o->ls = l0; rt = l + strlen(eft[i]); o->eft = 1; o->optnone = opt; break;
        }
        if (sig) break;
    }
    if (!sig) { snprintf(why, 256, "找不到入口 %s", entry); return 0; }
    size_t rl = (size_t)(sig - rt);
    if (!rl || rl >= sizeof o->ret) { snprintf(why, 256, "入口返回类型认不出"); return 0; }
    memcpy(o->ret, rt, rl); o->ret[rl] = 0;
    o->lp = sig + strlen(pat) - 1; o->rp = lclose(o->lp);
    if (!o->rp) { snprintf(why, 256, "入口参数表不闭合"); return 0; }
    o->body = strstr(o->rp, "\n{\n");
    if (!o->body) { snprintf(why, 256, "入口函数体认不出"); return 0; }
    o->body++;
    int d = 0;
    for (const char *q = o->body; *q; q++) { if (*q == '{') d++; else if (*q == '}' && --d == 0) { o->be = q; break; } }
    if (!o->be) { snprintf(why, 256, "入口函数体不闭合"); return 0; }
    return 1;
}

// 只改原 fragment 入口；动态 mask 由绘制处按附件格式及混合状态填写；本层仅对 float4 color 成员处理，不改变整数 / 深度输出。
//   pb = 1（直连链，宿主 nvn_mtl.m 按管线特化 s2a_pb<n>_c）：加可编程混合开关；pb = 0（gal 渲染器 gal_prog.m：宿主不做可编程混合）：与 #674 之前逐字节相同。
//   开关常量的声明写成一行：直连合编（S2A.Dsh batch/Unity.cs UG）把这种行提到全局、只留一份（各键放进自己的命名空间，同编号声明两次编不过）
static char *color_round_impl(const char *msl, const char *entry, int pb, char *why);
char *gal_color_round_msl(const char *msl, const char *entry, char *why) { return color_round_impl(msl, entry, 0, why); }
char *gal_color_round_pb_msl(const char *msl, const char *entry, char *why) { return color_round_impl(msl, entry, 1, why); }
static char *color_round_impl(const char *msl, const char *entry, int pb, char *why) {
    lentry en; if (!lentry_find(msl, entry, 5, &en, why)) return NULL;
    if (!strcmp(en.ret, "void")) return strdup(msl);
    const char *b, *e;
    if (!lstruct(msl, en.ret, &b, &e)) { snprintf(why, 256, "输出结构体 %s 找不到", en.ret); return NULL; }
    ldecl colors[8]; uint32_t seen = 0, floats = 0;
    for (const char *ln = b; ln < e;) {
        const char *le = memchr(ln, '\n', (size_t)(e - ln)); if (!le) le = e;
        ldecl md; if (!ldecl_parse(ln, le, &md) || !md.at) { snprintf(why, 256, "输出成员认不出"); return NULL; }
        if (lattr(&md, "color")) {
            char at[96], chk[32]; int n = -1, index = 0; lattr_copy(&md, at, sizeof at);
            if (sscanf(at, "color(%d)", &n) != 1 || n < 0 || n >= 8) { snprintf(why, 256, "输出颜色属性 %s 认不出", at); return NULL; }
            snprintf(chk, sizeof chk, "color(%d)", n);
            if (strcmp(at, chk)) {
                for (index = 0; index < 2; index++) { snprintf(chk, sizeof chk, "color(%d), index(%d)", n, index); if (!strcmp(at, chk)) break; }
                if (index == 2) { snprintf(why, 256, "输出颜色属性 %s 不是整个附件 / 双源输出", at); return NULL; }
            }
            unsigned bit = (unsigned)n + 8u * (unsigned)index;
            if (seen >> bit & 1) { snprintf(why, 256, "输出颜色属性 %s 重复", at); return NULL; }
            seen |= 1u << bit;
            // index(1) 仅作双源混合因子；无混合时只有 source 0 写附件，不能预先量化 source 1。
            if (!index && ltype(&md, "float4")) { colors[n] = md; floats |= 1u << n; }
        }
        ln = le + 1;
    }
    if (!floats) return strdup(msl);
    // 不让重复改写或原着色器占用内部槽悄悄形成两个同槽参数。
    for (const char *p = en.lp + 1; p < en.rp;) {
        int d = 0; const char *pe = p;
        for (; pe < en.rp; pe++) { if (*pe == '(' || *pe == '<' || *pe == '[') d++; else if (*pe == ')' || *pe == '>' || *pe == ']') d--; else if (*pe == ',' && d == 0) break; }
        ldecl pd; if (!ldecl_parse(p, pe, &pd)) { snprintf(why, 256, "入口参数认不出"); return NULL; }
        int slot = -1;
        if (pd.at && sscanf(pd.at, "buffer(%d)", &slot) == 1 && slot == LS_HALF_SLOT) { snprintf(why, 256, "片元入口已占用内部槽 %d", LS_HALF_SLOT); return NULL; }
        p = pe < en.rp ? pe + 1 : en.rp;
    }
    lsb o = {0}; lput(&o, msl, (size_t)(en.ls - msl)); lstr(&o, k_half_round);
    if (pb) {
        lstr(&o, k_pblend);
        for (int i = 0; i < 8; i++) if (floats >> i & 1)
            lfmt(&o, "constant bool s2a_pb%d_c [[function_constant(%d)]]; constant bool s2a_pb%d = is_function_constant_defined(s2a_pb%d_c) && s2a_pb%d_c;\n", i, GAL_PB_FC0 + i, i, i, i);
    }
    lput(&o, en.ls, (size_t)(en.rp - en.ls));
    const char *p = en.lp + 1; while (p < en.rp && isspace((unsigned char)*p)) p++;
    if (pb) {
        lfmt(&o, "%sconstant S2APBlend& s2a_pb [[buffer(%d)]]", p < en.rp ? ", " : "", LS_HALF_SLOT);
        for (int i = 0; i < 8; i++) if (floats >> i & 1) lfmt(&o, ", float4 s2a_dst%d [[color(%d), function_constant(s2a_pb%d)]]", i, i, i);
    } else lfmt(&o, "%sconstant uint& s2a_half_mask [[buffer(%d)]]", p < en.rp ? ", " : "", LS_HALF_SLOT);
    const char *mask = pb ? "s2a_pb.mask" : "s2a_half_mask";
    lput(&o, en.rp, (size_t)(en.body - en.rp));
    p = en.body; int nr = 0;
    for (const char *q = strstr(p, "return"); q && q < en.be; q = strstr(p, "return")) {
        if ((q > en.body && (isalnum((unsigned char)q[-1]) || q[-1] == '_')) || isalnum((unsigned char)q[6]) || q[6] == '_') {
            lput(&o, p, (size_t)(q + 6 - p)); p = q + 6; continue;
        }
        // SPIRV-Cross 的片元结构体返回是「return 标识符;」；每个出口独立加块，保留 if / switch 的控制范围。
        const char *v = q + 6; while (v < en.be && isspace((unsigned char)*v)) v++;
        const char *ve = v; while (ve < en.be && (isalnum((unsigned char)*ve) || *ve == '_')) ve++;
        const char *se = ve; while (se < en.be && isspace((unsigned char)*se)) se++;
        if (ve == v || !(isalpha((unsigned char)*v) || *v == '_') || se >= en.be || *se != ';') {
            free(o.s); snprintf(why, 256, "片元返回不是结构体变量"); return NULL;
        }
        // Preserve indentation for the direct giant-shader parser's round trip.
        const char *line = q; while (line > en.body && line[-1] != '\n') line--;
        const char *indent = line; while (indent < q && (*indent == ' ' || *indent == '\t')) indent++;
        size_t indentation = (size_t)(indent - line);
        lput(&o, p, (size_t)(q - p)); lstr(&o, "{\n");
        for (int i = 0; i < 8; i++) if (floats >> i & 1) {
            const ldecl *c = &colors[i];
            // 先混合再量化（同硬件：混合结果写进附件时才舍入）；附件 0 的第二源 = 输出 1 的原值（附件 0 先做，附件 1 还没改它）
            if (pb) {
                char s1[200] = "float4(0.0f)";
                if (i == 0 && (floats & 2)) snprintf(s1, sizeof s1, "%.*s.%.*s", (int)(ve - v), v, (int)(colors[1].ne - colors[1].nb), colors[1].nb);
                lput(&o, line, indentation);
                lfmt(&o, "    if (s2a_pb%d) %.*s.%.*s = s2a_pblend(%.*s.%.*s, s2a_dst%d, %s, s2a_pb, %du);\n", i,
                     (int)(ve - v), v, (int)(c->ne - c->nb), c->nb, (int)(ve - v), v, (int)(c->ne - c->nb), c->nb, i, s1, i);
            }
            lput(&o, line, indentation);
            lfmt(&o, "    if (%s & %uu) %.*s.%.*s = s2a_half_rtz(%.*s.%.*s);\n", mask, 1u << i,
                 (int)(ve - v), v, (int)(c->ne - c->nb), c->nb, (int)(ve - v), v, (int)(c->ne - c->nb), c->nb);
            lput(&o, line, indentation);
            lfmt(&o, "    if (%s & %uu) %.*s.%.*s = s2a_blend_zero_rgb(%.*s.%.*s);\n", mask, 256u << i,
                 (int)(ve - v), v, (int)(c->ne - c->nb), c->nb, (int)(ve - v), v, (int)(c->ne - c->nb), c->nb);
        }
        lput(&o, line, indentation); lstr(&o, "    "); lput(&o, q, (size_t)(se + 1 - q));
        lstr(&o, "\n"); lput(&o, line, indentation); lstr(&o, "}"); p = se + 1; nr++;
    }
    if (!nr) { free(o.s); snprintf(why, 256, "片元入口没有结构体返回"); return NULL; }
    lput(&o, p, strlen(p));
    if (o.bad) { free(o.s); snprintf(why, 256, "输出缓冲分配失败"); return NULL; }
    return o.s;
}
