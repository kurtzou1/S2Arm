// 直连 GL 层的设备上 GLSL → MSL（宿主运行时兜底，维护者 11-03 方案①：出包离线库里没有的 GLSL——GameMaker 等运行时才拼源码的引擎——首遇时现场翻译，
//   gl_prog.m 弱引用调用、后台队列里跑，按源码哈希缓存）。只兜底：首遇现编 0 仍是目标，抓到的源码（DM_GL_CAPTURE）照旧并进下次出包。
// 规则与出包离线链 translator/gl_shaders.py translate() + graphics/tools/glsl/normalize.py + graphics/tools/spirv_msl.py 逐条同口径（那边改了这里一起改，口径号 S2A_GL_XLATE_REV）：
//   · 源码改写（版本行、ES 1.00 attribute / varying / gl_FragColor、旧纹理函数、gl_Position 重声明、非常量纹理偏移）：共用 graphics/nvn/gfx/gl/gl_glsl_es.c（离线链经它的命令行入口调同一份）
//   · glslang（官方 16.6.0 原样构建，graphics/third_party/glslang/build.sh）：预处理同 glslangValidator -E；编译同 -V -R --aml --amb（宽松 Vulkan 规则：普通 uniform 收进 gl_DefaultUniformBlock，
//     输入输出 / 绑定自动编号），不跑优化
//   · 资源先按种类分命名空间（ubos / ssbos / separate_images / images / separate_samplers / textures / subpass_inputs 依次 0–6），各自按 (binding, 名字) 重排编号（normalize.py）；
//     再按 (命名空间, 编号) 序分 Metal 槽：缓冲 → buffer(n)、图像 → texture(n)、采样器 → sampler(n)、组合采样器取 texture / sampler 两个游标的较大者、两个一起前进，数组占连续槽（spirv_msl.py）
//   · SPIRV-Cross（App 里已有的那一份，graphics/third_party/spirv_cross）：MSL 2.3、按 Binding 装饰取槽、入口改名 gl_<键>_v / gl_<键>_f、顶点着色器 z 从 [−w, w] 映到 [0, w]（fixup_clipspace）、不翻 y
//   · 只登记入口函数真带的资源；varying 按名字配对（[[user(locnN)]] → [[user(<变量名>)]]，GL 按名字链接、两个阶段各自翻）；fast::min / max / clamp 换成 precise::
//   · 库表字段（gl_shaders.py 文件头）：a: 顶点输入、o: 片元输出、D 写 gl_FragDepth、b: / u: 默认 uniform 块与成员、B: 命名统一块、t: 组合采样器；接不上的（varying 数组 / 结构 / 矩阵，
//     其它资源种类、成员类型）整支判失败，原因写进 err
// 单独成库 libglx（graphics/nvn/Makefile：本文件 + glslang 静态库，只链进宿主与 iOS App，graphics/build.mk）：
//   · 不进 graphics/metal：那里的源码进通用着色器翻译键（graphics/tools/shbake/xc_key.sh 编全部 gal_*.m），加在那里全部款的通用着色器阶段冷翻；
//   · 不进 libnvn：只链 libnvn 的单测会被拉进来、要 glslang 与 SPIRV-Cross；GL 层弱引用 s2a_gl_xlate，没链这份库的单测走「没有设备上的翻译」报红
//   · SPIRV-Cross 不另带：spvc_* 在最终链接时由 libnxgal 里那一份解析（静态链接内隐藏可见性照样解析），App 里只有一份
//   纯 C（不用 Metal）：Metal 编译在 GL 层（gl_prog.m）
#include "../../../third_party/spirv_cross/spirv_cross_c.h"
#include <glslang/Include/glslang_c_interface.h>
#include <glslang/Public/resource_limits_c.h>
#include <glslang/build_info.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gl_glsl_es.c"   // 改写层（离线链同一份源码，见文件头）

#define S2A_GL_XLATE_REV 2   // 翻译规则改了加 1：运行时缓存（<DM_MSL_FALLBACK>/gl/*.row）按口径串作废重翻（2：MSL 3.1，审计 #1534 P1-66）
#define XSTR(x) STR(x)
#define STR(x) #x

// 口径串：规则号 + glslang 版本 + GL 库表口径（gl_lib.h 口径号由调用方拼进缓存行）
__attribute__((visibility("default")))
const char *s2a_gl_xlate_tag(void) {
    return "gl-xlate " XSTR(S2A_GL_XLATE_REV) " glslang " XSTR(GLSLANG_VERSION_MAJOR) "." XSTR(GLSLANG_VERSION_MINOR) "." XSTR(GLSLANG_VERSION_PATCH);
}

// 文本拼接用改写层的 sb（gl_glsl_es.c）
static void sb_fmt(sb *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void sb_fmt(sb *b, const char *fmt, ...) {
    char tmp[512]; va_list ap; va_start(ap, fmt); int n = vsnprintf(tmp, sizeof tmp, fmt, ap); va_end(ap);
    if (n < 0) return; if ((size_t)n < sizeof tmp) { sb_put(b, tmp, (size_t)n); return; }
    char *big = malloc((size_t)n + 1); if (!big) { b->oom = 1; return; } va_start(ap, fmt); vsnprintf(big, (size_t)n + 1, fmt, ap); va_end(ap); sb_put(b, big, (size_t)n); free(big);
}

// ---------- glslang：预处理（同 glslangValidator -E）与编译（同 -V -R --aml --amb） ----------
static void glslang_init(void) { glslang_initialize_process(); }
static void gl_init_once(void) { static pthread_once_t once = PTHREAD_ONCE_INIT; pthread_once(&once, glslang_init); }
static char *glsl_preprocess(const char *code, glslang_stage_t stage, char *err, size_t errn) {
    glslang_input_t in = {0};
    in.language = GLSLANG_SOURCE_GLSL; in.stage = stage; in.client = GLSLANG_CLIENT_NONE; in.target_language = GLSLANG_TARGET_NONE;
    in.code = code; in.default_version = 100; in.default_profile = GLSLANG_NO_PROFILE; in.messages = GLSLANG_MSG_ONLY_PREPROCESSOR_BIT; in.resource = glslang_default_resource();
    glslang_shader_t *sh = glslang_shader_create(&in); if (!sh) { snprintf(err, errn, "glslang_shader_create failed"); return NULL; }
    char *out = NULL;
    if (glslang_shader_preprocess(sh, &in)) {   // 命令行 -E 用 puts 输出：末尾多一个换行，照补（逐字节同离线链交给改写层的文本）
        const char *p = glslang_shader_get_preprocessed_code(sh); size_t l = strlen(p);
        if ((out = malloc(l + 2))) { memcpy(out, p, l); out[l] = '\n'; out[l + 1] = 0; }
    }
    else snprintf(err, errn, "%.400s", glslang_shader_get_info_log(sh));
    glslang_shader_delete(sh); return out;
}
static uint32_t *glsl_spirv(const char *code, glslang_stage_t stage, size_t *nwords, char *err, size_t errn) {
    glslang_input_t in = {0};
    in.language = GLSLANG_SOURCE_GLSL; in.stage = stage; in.client = GLSLANG_CLIENT_VULKAN; in.client_version = GLSLANG_TARGET_VULKAN_1_0;
    in.target_language = GLSLANG_TARGET_SPV; in.target_language_version = GLSLANG_TARGET_SPV_1_0;
    in.code = code; in.default_version = 100; in.default_profile = GLSLANG_NO_PROFILE;
    in.messages = GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT; in.resource = glslang_default_resource();
    glslang_shader_t *sh = glslang_shader_create(&in); if (!sh) { snprintf(err, errn, "glslang_shader_create failed"); return NULL; }
    glslang_shader_set_options(sh, GLSLANG_SHADER_AUTO_MAP_BINDINGS | GLSLANG_SHADER_AUTO_MAP_LOCATIONS | GLSLANG_SHADER_VULKAN_RULES_RELAXED);
    uint32_t *w = NULL; glslang_program_t *pr = NULL;
    // C 接口的 parse 读同一对象上 preprocess 的产物：先预处理（已是预处理后的文本，再过一遍不变），再解析
    if (!glslang_shader_preprocess(sh, &in) || !glslang_shader_parse(sh, &in)) { snprintf(err, errn, "%.600s", glslang_shader_get_info_log(sh)); goto out; }
    pr = glslang_program_create(); glslang_program_add_shader(pr, sh);
    if (!glslang_program_link(pr, in.messages) || !glslang_program_map_io(pr)) { snprintf(err, errn, "%.600s", glslang_program_get_info_log(pr)); goto out; }
    glslang_spv_options_t o = {0};   // 同命令行缺省：不出调试信息、不跑优化（本构建本来就不带 SPIRV-Tools）
    glslang_program_SPIRV_generate_with_options(pr, stage, &o);
    *nwords = glslang_program_SPIRV_get_size(pr);
    if (!*nwords || !(w = malloc(*nwords * 4))) { snprintf(err, errn, "SPIR-V is not generated"); goto out; }
    glslang_program_SPIRV_get(pr, w);
out:
    if (pr) glslang_program_delete(pr);
    glslang_shader_delete(sh); return w;
}

// ---------- SPIRV-Cross：反射 + 分槽 + 出 MSL ----------
// GLSL 类型名（同 spirv-cross --reflect 的 type_to_glsl：表字段 a: / u: / t: 的类型列）
static void type_name(spvc_compiler c, spvc_type_id tid, char *out, size_t n) {
    spvc_type t = spvc_compiler_get_type_handle(c, tid); spvc_basetype b = spvc_type_get_basetype(t);
    unsigned vs = spvc_type_get_vector_size(t), cols = spvc_type_get_columns(t);
    if (b == SPVC_BASETYPE_SAMPLED_IMAGE || b == SPVC_BASETYPE_IMAGE) {
        spvc_type st = spvc_compiler_get_type_handle(c, spvc_type_get_image_sampled_type(t)); spvc_basetype sb_ = spvc_type_get_basetype(st);
        const char *pre = sb_ == SPVC_BASETYPE_INT32 ? "i" : sb_ == SPVC_BASETYPE_UINT32 ? "u" : "";
        const char *dim = "?";
        switch (spvc_type_get_image_dimension(t)) { case SpvDim1D: dim = "1D"; break; case SpvDim2D: dim = "2D"; break; case SpvDim3D: dim = "3D"; break; case SpvDimCube: dim = "Cube"; break;
            case SpvDimRect: dim = "2DRect"; break; case SpvDimBuffer: dim = "Buffer"; break; case SpvDimSubpassData: dim = "subpassInput"; break; default: break; }
        snprintf(out, n, "%s%s%s%s%s%s", pre, b == SPVC_BASETYPE_SAMPLED_IMAGE ? "sampler" : spvc_type_get_image_is_storage(t) ? "image" : "texture", dim,
                 spvc_type_get_image_multisampled(t) ? "MS" : "", spvc_type_get_image_arrayed(t) ? "Array" : "", b == SPVC_BASETYPE_SAMPLED_IMAGE && spvc_type_get_image_is_depth(t) ? "Shadow" : "");
        return;
    }
    const char *s = NULL, *v = NULL;   // 标量名 / 向量前缀
    switch (b) {
        case SPVC_BASETYPE_FP32: s = "float"; v = ""; break;
        case SPVC_BASETYPE_INT32: s = "int"; v = "i"; break;
        case SPVC_BASETYPE_UINT32: s = "uint"; v = "u"; break;
        case SPVC_BASETYPE_BOOLEAN: s = "bool"; v = "b"; break;
        case SPVC_BASETYPE_FP64: s = "double"; v = "d"; break;
        case SPVC_BASETYPE_FP16: s = "float16_t"; v = "f16"; break;
        case SPVC_BASETYPE_STRUCT: { const char *nm = spvc_compiler_get_name(c, spvc_type_get_base_type_id(t)); snprintf(out, n, "%s", nm && *nm ? nm : "_struct"); return; }
        default: snprintf(out, n, "?%d", (int)b); return;
    }
    if (cols > 1) { if (cols == vs) snprintf(out, n, "%smat%u", b == SPVC_BASETYPE_FP64 ? "d" : "", cols); else snprintf(out, n, "%smat%ux%u", b == SPVC_BASETYPE_FP64 ? "d" : "", cols, vs); }
    else if (vs > 1) snprintf(out, n, "%svec%u", v, vs);
    else snprintf(out, n, "%s", s);
}
static const struct { spvc_resource_type type; const char *cat; char kind; } KINDS[] = {   // spirv_msl.py KINDS 的顺序 = 命名空间号
    {SPVC_RESOURCE_TYPE_UNIFORM_BUFFER, "ubos", 'u'}, {SPVC_RESOURCE_TYPE_STORAGE_BUFFER, "ssbos", 'b'}, {SPVC_RESOURCE_TYPE_SEPARATE_IMAGE, "separate_images", 't'},
    {SPVC_RESOURCE_TYPE_STORAGE_IMAGE, "images", 't'}, {SPVC_RESOURCE_TYPE_SEPARATE_SAMPLERS, "separate_samplers", 's'}, {SPVC_RESOURCE_TYPE_SAMPLED_IMAGE, "textures", 'c'},
    {SPVC_RESOURCE_TYPE_SUBPASS_INPUT, "subpass_inputs", 't'},
};
enum { NKIND = sizeof KINDS / sizeof *KINDS };
typedef struct { const spvc_reflected_resource *r; int ns, kind_i; unsigned binding; int slot, count, used; sb field, bad; } res_t;   // field / bad：这项的表字段 / 接不上的原因（入口真用到才算数）
static int res_cmp(const void *a, const void *b) {
    const res_t *x = a, *y = b;
    if (x->ns != y->ns) return x->ns - y->ns;
    if (x->binding != y->binding) return x->binding < y->binding ? -1 : 1;
    return strcmp(x->r->name, y->r->name);
}
static char slot_class(char kind) { return kind == 'u' || kind == 'b' ? 'b' : kind == 's' ? 's' : 't'; }   // buffer / sampler / texture（组合采样器按 texture 核用到没有）

// MSL 入口参数里用到的槽：「\b<入口>\((.*?)\)\s*\{」里的 [[buffer(n)]] / [[texture(n)]] / [[sampler(n)]]
static int entry_args(const char *msl, const char *name, const char **a0, const char **a1) {
    size_t l = strlen(name);
    for (const char *p = strstr(msl, name); p; p = strstr(p + 1, name)) {
        if ((p > msl && is_word((unsigned char)p[-1])) || p[l] != '(') continue;
        for (const char *q = p + l + 1; (q = strchr(q, ')')); q++) {
            const char *r = q + 1; while (is_space((unsigned char)*r)) r++;
            if (*r == '{') { *a0 = p + l + 1; *a1 = q; return 1; }
        }   // 这一处后面没有「) {」：re.search 接着找下一处入口名
    }
    return 0;
}
static int slot_used(const char *a0, const char *a1, char cls, int slot) {
    const char *kw = cls == 'b' ? "[[buffer(" : cls == 's' ? "[[sampler(" : "[[texture(";
    size_t kl = strlen(kw);
    for (const char *p = a0; p < a1 && (p = strstr(p, kw)) && p < a1; p += kl) { char *e; long v = strtol(p + kl, &e, 10); if (e != p + kl && *e == ')' && e[1] == ']' && e[2] == ']' && v == slot) return 1; }
    return 0;
}
// 「(\b(\w+)\s+\[\[)user\(locn\d+\)」→「\1user(\2)」与「\bfast::(min|max|clamp)\(」→「precise::\1(」（spirv_msl.py varying_names / PRECISE）
static char *msl_post(const char *s) {
    sb o = {0}; size_t n = strlen(s), i = 0, last = 0;
    while (i < n) {
        if (s[i] == '[' && !strncmp(s + i, "[[user(locn", 11)) {
            size_t d = i + 11, e = d; while (e < n && s[e] >= '0' && s[e] <= '9') e++;
            size_t ws = i; while (ws > 0 && is_space((unsigned char)s[ws - 1])) ws--;
            size_t w0 = ws; while (w0 > 0 && is_word((unsigned char)s[w0 - 1])) w0--;
            if (e > d && e < n && s[e] == ')' && ws < i && w0 < ws) { sb_put(&o, s + last, i + 7 - last); sb_put(&o, s + w0, ws - w0); sb_put(&o, ")", 1); i = last = e + 1; continue; }
        }
        if (s[i] == 'f' && boundary_before(s, i) && !strncmp(s + i, "fast::", 6)) {
            static const char *const fn[] = {"min(", "max(", "clamp("};
            for (int k = 0; k < 3; k++) if (!strncmp(s + i + 6, fn[k], strlen(fn[k]))) { sb_put(&o, s + last, i - last); sb_put(&o, "precise::", 9); i = last = i + 6; goto next; }
        }
        i++;
    next:;
    }
    sb_put(&o, s + last, n - last);
    return sb_take(&o, NULL);
}
static int has_word(const char *s, const char *w) {
    size_t l = strlen(w);
    for (const char *p = strstr(s, w); p; p = strstr(p + 1, w)) if ((p == s || !is_word((unsigned char)p[-1])) && !is_word((unsigned char)p[l])) return 1;
    return 0;
}
static const char *const VEC_TYPES[] = {"float", "vec2", "vec3", "vec4", "int", "ivec2", "ivec3", "ivec4", "uint", "uvec2", "uvec3", "uvec4", "bool", "mat2", "mat3", "mat4"};
static int vec_type(const char *t) { for (size_t i = 0; i < sizeof VEC_TYPES / sizeof *VEC_TYPES; i++) if (!strcmp(VEC_TYPES[i], t)) return 1; return 0; }

// 默认 uniform 块成员 → u: 字段；结构体成员（不是数组的）按 GL 命名展开成「名字.成员」、偏移加上结构体自己的偏移（GameMaker 内置着色器的 uniform LightEnv u_LightEnv），
//   展开的成员排在原位、按声明序（gl_shaders.py 同口径）；接不上的类型 / 数组记进 bad
static void ubo_members(spvc_compiler c, spvc_type_id st_id, const char *prefix, unsigned base, sb *field, sb *bad) {
    spvc_type bt = spvc_compiler_get_type_handle(c, st_id); spvc_type_id st_base = spvc_type_get_base_type_id(bt); char tn[64], name[256];
    for (unsigned m = 0; m < spvc_type_get_num_member_types(bt); m++) {
        spvc_type_id mt = spvc_type_get_member_type(bt, m); spvc_type mh = spvc_compiler_get_type_handle(c, mt);
        unsigned off = 0, stride = 0, nd = spvc_type_get_num_array_dimensions(mh), d0 = nd ? spvc_type_get_array_dimension(mh, 0) : 0;
        snprintf(name, sizeof name, "%s%s", prefix, spvc_compiler_get_member_name(c, st_base, m));
        spvc_compiler_type_struct_member_offset(c, bt, m, &off);
        if (spvc_type_get_basetype(mh) == SPVC_BASETYPE_STRUCT && !nd) { char sub[260]; snprintf(sub, sizeof sub, "%s.", name); ubo_members(c, mt, sub, base + off, field, bad); continue; }
        type_name(c, mt, tn, sizeof tn);
        if (!vec_type(tn) || nd > 1 || (nd && !d0)) { sb_fmt(bad, "%s普通 uniform %s：类型 / 数组尚未接入运行时", bad->n ? "; " : "", name); continue; }
        if (nd && spvc_compiler_has_decoration(c, mt, SpvDecorationArrayStride)) stride = spvc_compiler_get_decoration(c, mt, SpvDecorationArrayStride);
        sb_fmt(field, " u:%s=%u:%s:%u:%u", name, base + off, tn, nd ? d0 : 0, stride);
    }
}
static int spv_to_msl(const uint32_t *w, size_t nw, int frag, const char *key, const char *glsl, char **msl_out, char **fields_out, char *err, size_t errn) {
    spvc_context ctx = NULL; spvc_parsed_ir ir; spvc_compiler c; spvc_resources rs; int rc = 1;
    res_t res[256]; int nres = 0; sb f = {0}, bad = {0}; char *msl_post_s = NULL;
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) { snprintf(err, errn, "spvc_context_create failed"); return 1; }
#define CK(x) do { if ((x) != SPVC_SUCCESS) { snprintf(err, errn, "SPIRV-Cross: %.400s", spvc_context_get_last_error_string(ctx)); goto out; } } while (0)
    CK(spvc_context_parse_spirv(ctx, w, nw, &ir));
    CK(spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &c));
    CK(spvc_compiler_create_shader_resources(c, &rs));
    // 顶点输出 / 片元输入按名字配对：数组、结构、矩阵还没接（gl_shaders.py 同句）
    const spvc_reflected_resource *in, *outp; size_t nin, nout;
    CK(spvc_resources_get_resource_list_for_type(rs, SPVC_RESOURCE_TYPE_STAGE_INPUT, &in, &nin));
    CK(spvc_resources_get_resource_list_for_type(rs, SPVC_RESOURCE_TYPE_STAGE_OUTPUT, &outp, &nout));
    { const spvc_reflected_resource *vy = frag ? in : outp; size_t nv = frag ? nin : nout;
      for (size_t i = 0; i < nv; i++) {
          spvc_type t = spvc_compiler_get_type_handle(c, vy[i].type_id); char tn[64]; type_name(c, vy[i].type_id, tn, sizeof tn);
          if (spvc_type_get_num_array_dimensions(t) || spvc_type_get_basetype(t) == SPVC_BASETYPE_STRUCT || !strncmp(tn, "mat", 3)) { snprintf(err, errn, "varying %s：数组 / 接口块 / 矩阵尚未接入按名链接", vy[i].name); goto out; }
      } }
    { const spvc_reflected_resource *pc; size_t npc; CK(spvc_resources_get_resource_list_for_type(rs, SPVC_RESOURCE_TYPE_PUSH_CONSTANT, &pc, &npc)); if (npc) { snprintf(err, errn, "push constant 块：GL 运行时没有此接线"); goto out; } }
    // 命名空间 + (binding, 名字) 重排，再按序分 Metal 槽（normalize.py + spirv_msl.py）
    for (int k = 0; k < NKIND; k++) {
        const spvc_reflected_resource *l; size_t nl; CK(spvc_resources_get_resource_list_for_type(rs, KINDS[k].type, &l, &nl));
        for (size_t i = 0; i < nl; i++) {
            if (nres == 256) { snprintf(err, errn, "资源超过 256 个"); goto out; }
            res_t *r = &res[nres++]; memset(r, 0, sizeof *r); r->r = &l[i]; r->ns = k; r->kind_i = k; r->binding = spvc_compiler_get_decoration(c, l[i].id, SpvDecorationBinding);
            spvc_type t = spvc_compiler_get_type_handle(c, l[i].type_id); unsigned nd = spvc_type_get_num_array_dimensions(t);
            r->count = nd ? (int)spvc_type_get_array_dimension(t, 0) : 1;
            if (nd > 1 || !r->count) { snprintf(err, errn, "资源 %s 的数组维 %u 尚未实现", l[i].name, nd); goto out; }
        }
    }
    qsort(res, (size_t)nres, sizeof *res, res_cmp);
    { int nb = 0, nt = 0, ns = 0;
      for (int i = 0; i < nres; i++) {
          res_t *r = &res[i];
          char kind = KINDS[r->kind_i].kind;
          if (kind == 'c') { r->slot = nt > ns ? nt : ns; nt = ns = r->slot + r->count; }
          else if (slot_class(kind) == 'b') { r->slot = nb; nb += r->count; }
          else if (slot_class(kind) == 's') { r->slot = ns; ns += r->count; }
          else { r->slot = nt; nt += r->count; }
          spvc_compiler_set_decoration(c, r->r->id, SpvDecorationDescriptorSet, (unsigned)r->ns);
          spvc_compiler_set_decoration(c, r->r->id, SpvDecorationBinding, (unsigned)r->slot);
      }
      if (nb > 16 || nt > 31 || ns > 16) { snprintf(err, errn, "resource slots exceeded {buffer %d, texture %d, sampler %d}", nb, nt, ns); goto out; } }
    // 表字段（gl_shaders.py translate 之后半段）：a / o、D、按命名空间序的资源。名字在出 MSL 之前取：compile 会把 MSL 保留字改名（gl_DefaultUniformBlock → _RESERVED_IDENTIFIER_FIXUP_…）
    char tn[64];
    if (!frag) for (size_t i = 0; i < nin; i++) { type_name(c, in[i].type_id, tn, sizeof tn); sb_fmt(&f, "%sa:%s=%u:%s", f.n ? " " : "", in[i].name, spvc_compiler_get_decoration(c, in[i].id, SpvDecorationLocation), tn); }
    else {
        for (size_t i = 0; i < nout; i++) sb_fmt(&f, "%so:%s=%u", f.n ? " " : "", outp[i].name, spvc_compiler_get_decoration(c, outp[i].id, SpvDecorationLocation));
        if (has_word(glsl, "gl_FragDepth")) sb_fmt(&f, "%sD", f.n ? " " : "");
    }
    for (int i = 0; i < nres; i++) {
        res_t *r = &res[i]; const char *cat = KINDS[r->kind_i].cat;
        if (!strcmp(cat, "ubos")) {
            spvc_type bt = spvc_compiler_get_type_handle(c, r->r->base_type_id); size_t size = 0; spvc_compiler_get_declared_struct_size(c, bt, &size);
            const char *bn = spvc_compiler_get_name(c, r->r->base_type_id);
            if (bn && !strcmp(bn, "gl_DefaultUniformBlock")) {
                sb_fmt(&r->field, "b:%d:%zu", r->slot, size);
                ubo_members(c, r->r->base_type_id, "", 0, &r->field, &r->bad);
            } else if (r->count == 1) sb_fmt(&r->field, "B:%s=%d:%zu", bn && *bn ? bn : r->r->name, r->slot, size);
            else sb_fmt(&r->bad, "ubos %s：GL 库表口径 1 没有此接线", r->r->name);
        } else if (!strcmp(cat, "textures")) {
            type_name(c, r->r->type_id, tn, sizeof tn);
            if (r->count > 1) sb_fmt(&r->field, "t:%s=%d:%s:%d", r->r->name, r->slot, tn, r->count); else sb_fmt(&r->field, "t:%s=%d:%s", r->r->name, r->slot, tn);
        } else sb_fmt(&r->bad, "%s %s：GL 库表口径 1 没有此接线", cat, r->r->name);
    }
    spvc_compiler_options opt; CK(spvc_compiler_create_compiler_options(c, &opt));
    CK(spvc_compiler_options_set_uint(opt, SPVC_COMPILER_OPTION_MSL_VERSION, SPVC_MAKE_MSL_VERSION(3, 1, 0)));   // 同离线链 spirv_msl.py（审计 #1534 P1-66）
    CK(spvc_compiler_options_set_bool(opt, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, SPVC_TRUE));
    if (!frag) CK(spvc_compiler_options_set_bool(opt, SPVC_COMPILER_OPTION_FIXUP_DEPTH_CONVENTION, SPVC_TRUE));
    CK(spvc_compiler_install_compiler_options(c, opt));
    char name[40]; snprintf(name, sizeof name, "gl_%.16s_%c", key, frag ? 'f' : 'v');
    CK(spvc_compiler_rename_entry_point(c, "main", name, frag ? SpvExecutionModelFragment : SpvExecutionModelVertex));
    const char *msl; CK(spvc_compiler_compile(c, &msl));
    const char *a0, *a1; if (!entry_args(msl, name, &a0, &a1)) { snprintf(err, errn, "entry point %s not found in the translated MSL", name); goto out; }
    for (int i = 0; i < nres; i++) res[i].used = slot_used(a0, a1, slot_class(KINDS[res[i].kind_i].kind), res[i].slot);
    if (!(msl_post_s = msl_post(msl))) { snprintf(err, errn, "out of memory"); goto out; }
    for (int i = 0; i < nres; i++) {   // 只登记入口真带的资源（spirv_msl.py 同）
        res_t *r = &res[i]; if (!r->used) continue;
        if (r->field.n) sb_fmt(&f, "%s%s", f.n ? " " : "", r->field.p);
        if (r->bad.n) sb_fmt(&bad, "%s%s", bad.n ? "; " : "", r->bad.p);
        if (r->field.oom || r->bad.oom) f.oom = 1;
    }
    if (bad.n) { snprintf(err, errn, "%.500s", bad.p); goto out; }
    if (f.oom || bad.oom) { snprintf(err, errn, "out of memory"); goto out; }
    *msl_out = msl_post_s; msl_post_s = NULL; *fields_out = f.p ? f.p : strdup(""); f.p = NULL; rc = 0;
#undef CK
out:
    free(msl_post_s); free(f.p); free(bad.p);
    for (int i = 0; i < nres; i++) { free(res[i].field.p); free(res[i].bad.p); }
    spvc_context_destroy(ctx);
    return rc;
}

// 一支 GLSL（glShaderSource 收到的原文，键 = 它的 sha256 前 16 位）→ MSL + 库表字段。0 = 成功（*msl / *fields 由调用方 free）；1 = 失败，原因写 err
__attribute__((visibility("default")))
int s2a_gl_xlate(const char *src, size_t n, int frag, const char *key, char **msl, char **fields, char *err, size_t errcap) {
    *msl = *fields = NULL; if (errcap) err[0] = 0;
    gl_init_once();
    glslang_stage_t st = frag ? GLSLANG_STAGE_FRAGMENT : GLSLANG_STAGE_VERTEX; char stc = frag ? 'f' : 'v';
    size_t pn, rn, nw = 0; int rc = 1; char *pre = NULL, *glsl = NULL; uint32_t *w = NULL;
    char *fixed = s2a_glsl_es_prefix(src, n, &pn); if (!fixed) { snprintf(err, errcap, "out of memory"); return 1; }
    if (!(pre = glsl_preprocess(fixed, st, err, errcap))) {
        // #749：还报「要写 es」= 补 es 没认出这种版本行写法。把原文第一条 #version 行带进报错（只这一行、至多 80 字节、不可打印的换成 ?），下一份诊断包就能对症
        if (strstr(err, "'es' profile")) {
            const char *v = NULL; for (size_t i = 0; i + 8 <= n; i++) if (!memcmp(src + i, "#version", 8)) { v = src + i; break; }
            char line[81]; size_t k = 0; for (; v && k < 80 && v + k < src + n && v[k] != '\n'; k++) line[k] = v[k] >= 0x20 && v[k] < 0x7f ? v[k] : '?'; line[k] = 0;
            size_t el = strlen(err); while (el && (err[el - 1] == '\n' || err[el - 1] == ' ')) err[--el] = 0;
            snprintf(err + el, errcap > el ? errcap - el : 0, "（原文版本行「%s」）", v ? line : "没有 #version");
        }
        goto out;
    }
    if (!(glsl = s2a_glsl_es_rewrite(pre, strlen(pre), stc, &rn, err, errcap))) { if (!err[0]) snprintf(err, errcap, "out of memory"); goto out; }
    if (!(w = glsl_spirv(glsl, st, &nw, err, errcap))) goto out;
    rc = spv_to_msl(w, nw, frag, key, glsl, msl, fields, err, errcap);
out:
    free(fixed); free(pre); free(glsl); free(w); return rc;
}
