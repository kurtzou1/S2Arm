// GAL：翻译前的 SPIR-V 加固改写（方案 5a「Metal 越界与死循环」定案，研究见 docs/研究/Metal越界.md ④）。
// Metal 没有 robustBufferAccess：越界读拿到相邻分配的真数据、越界写无声写坏相邻缓冲；乱值驱动的循环在 iPhone 上一帧内就被 GPU 判挂死（片元单块约 17 ms、计算单批约 0.5 秒）。
// 两道改写，都在 SPIRV-Cross 之前、对所有游戏所有着色器一次做完（不认游戏、不认着色器）：
//   ① spv_bounds：常量 / 存储缓冲、共享（Workgroup）/ 局部（Private）内存、向量 / 矩阵的每一级动态下标（语义依据见 docs/研究/Metal越界.md ⑥ 语义表）
//      · 地址：下标一律钳到 min(idx, 末元素)（读不出本分配，消掉固定数组越界的未定义行为；iPhone 实测代价 −3.4% ~ +0.4%）；
//        能静态证明在界内的不动：常量下标在界内、或 x & c（c 是常量且 < 长度，Ryujinx 常量缓冲分量下标 (off >> 2) & 3 就是这种）；
//      · 读的值：只钳位、不改值（11-01 维护者定，#1204 T1）——越界读拿到钳到的末元素。依据：Vulkan robustBufferAccess 允许越界读返回缓冲内任意值或 0，
//        钳到界内正符合 Ryujinx 翻译器依赖的语义，地址不出本分配、GPU 不缺页。原「越界读回 0」（值 & 界内掩码）在直连上量过代价太大：
//        异度3 10 支重片元 GPU 时间合计 +52%、怪猎 16 支 +38%（每支几百到近三千处读，11-01 微基准），撤掉；
//      · 写与原子：下标同样钳，另外拆块「在界内才执行」，越界的原子返回钳到的元素的当前值（与越界读同值，读改写重试循环才退得出）；
//      · 长度来源：定长数组 / 向量用编译期常量；存储缓冲的运行时数组用 OpArrayLength（SPIRV-Cross 走现成的缓冲长度表 GAL_ARG_SIZES）；
//        常量缓冲（Ryujinx：Block 结构体里唯一成员 vec4 data[4096]）按游戏实际绑定的字节数：本改写在同一描述符集里新增一个只读存储缓冲
//        gal_ubo_len（绑定号 GAL_UBOLEN_BINDING），内容 uint[常量缓冲绑定号] = 绑定的 vec4 个数，由 gal_draw.m 按当前绑定写（GAL_ARG_UBOLEN）。
//        不新增 Metal 绑定槽：它只是该集参数缓冲里多一个 8 字节指针。函数入口读一次长度，之后每次访问只多一条 min / 比较。
//        直连链（nxgal_spv_harden，S2A.Dsh）口径不同：宿主只知道 NVN 槽号、不知道 SPIR-V 绑定号（dmsh_xlate 按出现顺序递增分配），表改按 Maxwell 常量槽索引——
//        变量名 <阶段>_c<N>（N = 3..16，即 NVN 统一缓冲槽 N − 3）的常量缓冲读 表[N − 3]，表长 NXGAL_DIRECT_UBOLEN_N，变量命名 gal_ubo_len（反射认作 ubolen 绑定，nvn_mtl.m 按当前 NVN 绑定填）；
//        c0 / c2（驱动段）与 c1（着色器自带常量段）由宿主按已知长度自造，不钳（c1 读范围另由出库 c1 越界核查表管）
//   ② spv_loop_guard：每个函数一个计数变量，每条循环回边加该循环体的静态指令数（有下限，见 GAL_LOOP_WMIN_*），满上限即跳出到合并块。
//      上限按阶段分档（片元 / 顶点 2^18、计算单线程 2^22 条指令，计算另按整次派发的线程总数缩小，见下方定义）。改档必须升 NXGAL_XC_VERSION（离线库与程序二进制按它作废）。
//   ③ spv_count_flush：常态计数（gal_internal.h GAL_ARG_OOBCNT）。①② 在访问 / 返回处更新每类一个私有布尔，③ 在入口函数返回与丢弃前，
//      有越界或到上限就原子加到本着色器的计数格。只在计数开（NXGAL_BOUNDS_COUNT=1）时翻译才插，计数关（缺省、出包）不插、零开销。
//      不用函数常量：applegpu-nt 离线编渲染管线时，带函数常量的片元函数一特化就报「cannot find private metadata」，整片归档失败（10-21 三款 0 KB，docs/坑记录.md）。
// 改不了的访问（下标不是 32 位整数、循环头块里的写、OpSwitch 回边 …）不静默放过：计数并按类首例报红。
// 纯 C、不引 Metal 头（#783）：编进直连翻译库 libdsx（graphics/dsx/Makefile，11-08；渲染器另链它），
//   Linux / Windows 出包机同编（Makefile 的 linux 目标、dsx_win.py），S2A.Dsh 的 NxgalSpvCross.Harden 经 DllImport("dsx") 调。
#include "gal_spvx.h"
#include "gal_log.h"
#include "dsx_abi.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#define SPV_ENABLE_UTILITY_CODE
#define inline static inline   // spirv.h 的工具函数是 C99 inline 定义，不保证有外部定义：本文件内改成 static inline
#include "spirv.h"
#undef inline

// 上限按「工作量」计：每条回边加该循环体的静态指令数（循环头标签到回边分支，向上取 2 的幂，夹在 [下限, 2^14]），单位 = 条指令。
// 只数回边次数挡不住重循环体：10-21 暗黑2 计算着色器 72a243b8 的循环体约 2000 行，乱值计数跑满 2^18 次 ≈ 单线程 5 亿条指令，
// iPhone 单条命令缓冲 0.5 秒被判挂死、本机 CDM 杀不动而整卡重置（gpuEvent「CDM Kill timeout」）
#define GAL_LOOP_CAP_GFX (1u << 18)   // 片元 / 顶点：iPhone 片元单块挂死阈值约 17 ms（研究 #55）；4 运算体 2^16 次（约 2^18 条）单块 11 ms
#define GAL_LOOP_CAP_CS  (1u << 22)   // 计算单线程：iPhone 单批挂死阈值约 0.5 秒（研究 #57）；重体 2^18 次（约 2^22 条）约 0.1 秒
// 计算再按整次派发封顶：单线程上限 = 总预算 ÷ 线程总数（线程组数 × 组内线程数），夹在 [GAL_LOOP_FLOOR_CS, GAL_LOOP_CAP_CS]。
// 总预算 2^35 条 ≈ 8192 个线程同时跑满单线程上限；派发越大单线程允许越少，整次派发的时长有界（组内线程数取不到常量时只用单线程上限）
#define GAL_LOOP_TOTAL_CS_SH4 (1u << 31)   // 总预算 ÷ 16（32 位整除不溢出；算完左移 4 位还原）
#define GAL_LOOP_FLOOR_CS (1u << 14)
#define GAL_LOOP_WMAX_LOG2 14
// 权重下限 = 单位上限 ÷ 旧回边上限（图形 2^18 / 2^12 = 64、计算 2^22 / 2^18 = 16）：任何循环允许的次数都不超过旧口径（片元 2^12、计算 2^18 次），只对重循环体更严
#define GAL_LOOP_WMIN_LOG2_GFX 6
#define GAL_LOOP_WMIN_LOG2_CS 4

static _Atomic uint32_t g_sx_tot[GAL_SPVX_NSTAT];
// 计数开关（翻译期：开才插计数收尾，见文件头 ③）：NXGAL_BOUNDS_COUNT=1 开，其余一律关；缺省两端都关、与出货（iPhone）一致。
// 10-21 起 macOS 也缺省关：片元函数只要含计数的设备原子写（运行时一次不执行也算），苹果 GPU 上「丢弃后隐式导数」的绘制结果就变（docs/坑记录.md），
// 计数开的局画面不代表 iPhone。要计数的地方（计数单测、tools/mac_health.sh 诊断局）显式开，只读计数不比像素（tests/visual 门禁见计数开即红）。
int gal_spvx_counting(void) {
    static int c = -1;
    if (c < 0) { const char *e = getenv("NXGAL_BOUNDS_COUNT"); c = e && *e == '1'; }
    return c;
}
void gal_spvx_totals(uint32_t out[GAL_SPVX_NSTAT]) { for (int i = 0; i < GAL_SPVX_NSTAT; i++) out[i] = g_sx_tot[i]; }

// ---------- 输出缓冲 ----------
typedef struct { uint32_t *w; uint32_t n, cap; } wbuf;
// 扩容失败（realloc 返回空）或缓冲为空却要写：置本线程失败标记、不写，由 spv_bounds 收尾时整支判加固失败。
// 原先直接 b->w = realloc(...)，失败后 w 为空、cap 已调大，下一次拷贝写到「空指针 + 偏移」（10-20 暗黑3 iPhone 第 2688 帧现翻 SIGSEGV，地址 0x41c）
static _Thread_local int g_wb_bad;
static void wb_put(wbuf *b, const uint32_t *x, uint32_t n) {
    if (g_wb_bad || !n) return;
    if (b->n + n > b->cap) {
        uint64_t nc = ((uint64_t)b->cap + n) * 2 + 256;
        uint32_t *p = nc <= UINT32_MAX / 4 ? realloc(b->w, (size_t)nc * 4) : NULL;
        if (!p) { g_wb_bad = 1; GLOG("【红】着色器越界改写：输出缓冲扩容失败（已有 %u 字、要加 %u 字、申请 %llu 字），本支不加固", b->n, n, (unsigned long long)nc); return; }
        b->w = p; b->cap = (uint32_t)nc;
    }
    memcpy(b->w + b->n, x, (size_t)n * 4); b->n += n;
}
#define OPW(op, n) (((uint32_t)(n) << 16) | (uint32_t)(op))
#define W(b, ...) do { uint32_t _t[] = { __VA_ARGS__ }; wb_put((b), _t, (uint32_t)(sizeof _t / 4)); } while (0)

enum { GLSL_UMin = 38, GLSL_UMax = 41 };
enum { SC_Uniform = 2, SC_Workgroup = 4, SC_Private = 6, SC_Function = 7, SC_StorageBuffer = 12 };

typedef struct {
    const uint32_t *in; uint32_t nw, bound, nb;
    uint32_t *pos, *rtype, *stride, *dset, *dbind, *rename; uint8_t *deco, *wptr, *lm_block;   // deco 位 0 Block 位 1 BufferBlock 位 2 有绑定
    uint32_t *inb;              // 访问链结果 → 界内布尔（被写 / 原子用到的链）
    uint32_t tu32, tbool, glsl; int new_tu32, new_tbool, new_glsl;
    uint32_t mm_pos, ann_end, first_fn, model;
    uint32_t *ptrs; int nptr;   // 现有 OpTypePointer 的 id
    wbuf glob, deco_add;        // 新增的类型 / 常量 / 变量、新增的修饰
    uint32_t cst_v[512], cst_id[512]; int ncst;
    // 常量缓冲长度表（每集一个）
    uint32_t ubo_n[GAL_MAX_SETS], ulen_var[GAL_MAX_SETS], ulen_ptr_u32;
    int direct; uint8_t *cslot; uint32_t name_end, ann_beg; wbuf names;   // 直连口径（见文件头 ①）：cslot[变量] = 名字 <阶段>_c<N> 的 N + 1（0 = 不是）；新增 OpName 插在原名字段末尾（没有就在首条注解前）
    uint32_t cvar[GAL_OOB_NVAR], c_true, ptr_pb;   // 每类越界一个私有布尔「全在界内」（初值真）；真常量；Private bool 指针类型
    uint32_t st[GAL_SPVX_NSTAT];
} sx;

static uint32_t sx_cst(sx *s, uint32_t v) {
    for (int i = 0; i < s->ncst; i++) if (s->cst_v[i] == v) return s->cst_id[i];
    uint32_t id = s->nb++; W(&s->glob, OPW(SpvOpConstant, 4), s->tu32, id, v);
    if (s->ncst < 512) { s->cst_v[s->ncst] = v; s->cst_id[s->ncst++] = id; }
    return id;
}
static uint32_t sx_ptr(sx *s, uint32_t sc, uint32_t t) {   // 找现有指针类型（非聚合类型不许重复声明），没有就新建
    for (int i = 0; i < s->nptr; i++) { const uint32_t *p = s->in + s->pos[s->ptrs[i]]; if (p[2] == sc && p[3] == t) return s->ptrs[i]; }
    uint32_t id = s->nb++; W(&s->glob, OPW(SpvOpTypePointer, 4), id, sc, t); return id;
}
static uint32_t sx_glsl(sx *s) { if (!s->glsl) { s->glsl = s->nb++; s->new_glsl = 1; } return s->glsl; }
static int is_op(const sx *s, uint32_t id, uint32_t op) { return id < s->bound && s->pos[id] && (s->in[s->pos[id]] & 0xffff) == op; }
static int const_u32(const sx *s, uint32_t id, uint32_t *v) {
    if (!is_op(s, id, SpvOpConstant)) return 0;
    const uint32_t *p = s->in + s->pos[id];
    if (!is_op(s, p[1], SpvOpTypeInt) || s->in[s->pos[p[1]] + 2] != 32) return 0;
    *v = p[3]; return 1;
}
// 下标转成 u32（UMin / 比较的操作数类型必须与结果相同）；不是 32 位整数返回 0
static uint32_t as_u32(sx *s, wbuf *o, uint32_t idx) {
    uint32_t t = idx < s->bound ? s->rtype[idx] : 0;
    if (t == s->tu32) return idx;
    if (!is_op(s, t, SpvOpTypeInt) || s->in[s->pos[t] + 2] != 32) return 0;
    uint32_t r = s->nb++; W(o, OPW(SpvOpBitcast, 4), s->tu32, r, idx); return r;
}
static uint32_t umin(sx *s, wbuf *o, uint32_t a, uint32_t b) { uint32_t r = s->nb++; W(o, OPW(SpvOpExtInst, 7), s->tu32, r, sx_glsl(s), GLSL_UMin, a, b); return r; }
static uint32_t ult(sx *s, wbuf *o, uint32_t a, uint32_t b) { uint32_t r = s->nb++; W(o, OPW(SpvOpULessThan, 5), s->tbool, r, a, b); return r; }
// 越界计数：第 k 类的私有布尔「本调用到目前为止全在界内」（Private、初值真）；没有就建
static uint32_t cls_var(sx *s, int k) {
    if (s->cvar[k]) return s->cvar[k];
    if (!s->c_true) { s->c_true = s->nb++; W(&s->glob, OPW(SpvOpConstantTrue, 3), s->tbool, s->c_true); }
    if (!s->ptr_pb) s->ptr_pb = sx_ptr(s, SC_Private, s->tbool);
    uint32_t v = s->nb++; W(&s->glob, OPW(SpvOpVariable, 5), s->ptr_pb, v, SC_Private, s->c_true);
    return s->cvar[k] = v;
}
// 下标能静态证明 < len：x & c（c 是 32 位整数常量且 < len）
static int masked_below(const sx *s, uint32_t idx, uint32_t len) {
    if (!is_op(s, idx, SpvOpBitwiseAnd)) return 0;
    const uint32_t *q = s->in + s->pos[idx]; uint32_t c;
    return (const_u32(s, q[3], &c) || const_u32(s, q[4], &c)) && c < len;
}
static uint32_t land(sx *s, wbuf *o, uint32_t a, uint32_t b) { if (!a) return b; uint32_t r = s->nb++; W(o, OPW(SpvOpLogicalAnd, 5), s->tbool, r, a, b); return r; }

// 函数入口段（首块 OpVariable 之后）：每函数读一次的长度值
typedef struct { uint32_t key0, key1, last, len; } ent_val;
typedef struct { wbuf pre; ent_val v[64]; int nv; } fn_ctx;
static ent_val *fn_val(fn_ctx *f, uint32_t k0, uint32_t k1) {
    for (int i = 0; i < f->nv; i++) if (f->v[i].key0 == k0 && f->v[i].key1 == k1) return &f->v[i];
    return NULL;
}
// 常量缓冲 (集, 绑定)：表里是绑定的 vec4 个数 n（未绑定 0）；入口读一次，末元素下标 last = max(n,1) − 1（钳地址用），n 判界内
static ent_val *ubo_len(sx *s, fn_ctx *f, uint32_t set, uint32_t bind) {
    ent_val *e = fn_val(f, 0x80000000u | set, bind); if (e) return e;
    if (f->nv >= 64) return NULL;
    if (!s->ulen_var[set]) {
        // uint 数组[n]（ArrayStride 4）→ 结构体（BufferBlock，成员 0 偏移 0、只读）→ Uniform 指针 → 变量（集 set，绑定 GAL_UBOLEN_BINDING）
        uint32_t arr = s->nb++, st = s->nb++, pst, var = s->nb++;
        W(&s->glob, OPW(SpvOpTypeArray, 4), arr, s->tu32, sx_cst(s, s->ubo_n[set]));
        W(&s->glob, OPW(SpvOpTypeStruct, 3), st, arr);
        pst = sx_ptr(s, SC_Uniform, st);
        W(&s->glob, OPW(SpvOpVariable, 4), pst, var, SC_Uniform);
        W(&s->deco_add, OPW(SpvOpDecorate, 4), arr, SpvDecorationArrayStride, 4);
        W(&s->deco_add, OPW(SpvOpDecorate, 3), st, SpvDecorationBufferBlock);
        W(&s->deco_add, OPW(SpvOpMemberDecorate, 5), st, 0, SpvDecorationOffset, 0);
        W(&s->deco_add, OPW(SpvOpMemberDecorate, 4), st, 0, SpvDecorationNonWritable);
        W(&s->deco_add, OPW(SpvOpDecorate, 4), var, SpvDecorationDescriptorSet, set);
        W(&s->deco_add, OPW(SpvOpDecorate, 4), var, SpvDecorationBinding, GAL_UBOLEN_BINDING);
        if (s->direct) W(&s->names, OPW(SpvOpName, 5), var, 0x5f6c6167u /* gal_ */, 0x5f6f6275u /* ubo_ */, 0x006e656cu /* len\0 */);   // SPIRV-Cross 参数块成员名 = 变量名
        s->ulen_var[set] = var;
        if (!s->ulen_ptr_u32) s->ulen_ptr_u32 = sx_ptr(s, SC_Uniform, s->tu32);
    }
    uint32_t pc = s->nb++, n = s->nb++, m = s->nb++, last = s->nb++;
    W(&f->pre, OPW(SpvOpAccessChain, 6), s->ulen_ptr_u32, pc, s->ulen_var[set], sx_cst(s, 0), sx_cst(s, bind));
    W(&f->pre, OPW(SpvOpLoad, 4), s->tu32, n, pc);
    W(&f->pre, OPW(SpvOpExtInst, 7), s->tu32, m, sx_glsl(s), GLSL_UMax, n, sx_cst(s, 1));
    W(&f->pre, OPW(SpvOpISub, 5), s->tu32, last, m, sx_cst(s, 1));
    f->v[f->nv] = (ent_val){0x80000000u | set, bind, last, n}; return &f->v[f->nv++];
}
// 存储缓冲运行时数组的长度与末元素下标
static ent_val *rt_len(sx *s, fn_ctx *f, uint32_t var, uint32_t member) {
    ent_val *e = fn_val(f, var, member); if (e) return e;
    if (f->nv >= 64) return NULL;
    uint32_t n = s->nb++, m = s->nb++, last = s->nb++;
    W(&f->pre, OPW(SpvOpArrayLength, 5), s->tu32, n, var, member);
    W(&f->pre, OPW(SpvOpExtInst, 7), s->tu32, m, sx_glsl(s), GLSL_UMax, n, sx_cst(s, 1));
    W(&f->pre, OPW(SpvOpISub, 5), s->tu32, last, m, sx_cst(s, 1));
    f->v[f->nv] = (ent_val){var, member, last, n}; return &f->v[f->nv++];
}

static void red(sx *s, int k, const char *what) {
    s->st[k]++;
    static _Atomic int seen[GAL_SPVX_NSTAT];
    if (!seen[k]++) GLOG("【红】着色器越界改写：%s（首例；之后只计数 gal_spvx_totals[%d]）", what, k);
}

// 访问链：把每一级动态下标钳住；按级算「界内」布尔（数组级归根变量的类，向量 / 矩阵级归 GAL_OOB_VEC），
// 并进该类的私有计数布尔；被写 / 原子用到的链记下整条链的界内布尔。返回 0 = 原样复制
static int rewrite_chain(sx *s, fn_ctx *f, wbuf *o, const uint32_t *p, uint32_t n) {
    uint32_t base = p[3];
    if (!is_op(s, base, SpvOpVariable) || n < 5) return 0;
    uint32_t vt = s->rtype[base], sc = s->in[s->pos[base] + 3];
    if (sc != SC_Uniform && sc != SC_StorageBuffer && sc != SC_Workgroup && sc != SC_Private) return 0;
    if (!is_op(s, vt, SpvOpTypePointer)) return 0;
    uint32_t cur = s->in[s->pos[vt] + 3], nidx = n - 4, ni[64];
    if (nidx > 64) return 0;
    for (int k = 0; k < GAL_OOB_NVAR; k++) if (base == s->cvar[k]) return 0;   // 本改写自己的计数布尔
    memcpy(ni, p + 4, nidx * 4);
    int top_struct = is_op(s, cur, SpvOpTypeStruct), changed = 0, need_inb = p[2] < s->bound && s->wptr[p[2]];
    int is_ubo = sc == SC_Uniform && (s->deco[cur] & 1), ubo = is_ubo && (s->deco[base] & 4);
    int cls = sc == SC_Workgroup ? GAL_OOB_SHARED : sc == SC_Private ? GAL_OOB_LOCAL : is_ubo ? GAL_OOB_UBO : GAL_OOB_SSBO;
    uint32_t member = 0, inb_c[2] = {0, 0};   // [0] 数组级（类 cls）[1] 向量 / 矩阵级（GAL_OOB_VEC）
    for (uint32_t k = 0; k < nidx; k++) {
        uint32_t idx = ni[k], cv, op = cur < s->bound && s->pos[cur] ? s->in[s->pos[cur]] & 0xffff : 0;
        const uint32_t *tp = s->in + s->pos[cur];
        int is_c = const_u32(s, idx, &cv);
        if (op == SpvOpTypeStruct) {
            if (!is_c || cv + 2 >= (tp[0] >> 16)) return 0;   // 结构体成员下标须是常量（否则不是合法 SPIR-V）
            if (k == 0) member = cv;
            cur = tp[2 + cv]; continue;
        }
        uint32_t len_c = 0, elem = 0, last = 0, len = 0; int vec = 0;
        if (op == SpvOpTypeArray) { elem = tp[2]; if (!const_u32(s, tp[3], &len_c) || !len_c) { red(s, GAL_SPVX_SKIP, "数组长度不是常量"); return 0; } }
        else if (op == SpvOpTypeVector || op == SpvOpTypeMatrix) { elem = tp[2]; len_c = tp[3]; vec = 1; }
        else if (op == SpvOpTypeRuntimeArray) elem = tp[2];
        else break;   // 指针 / 标量：链到头了
        // 常量缓冲 vec4 data[4096]：按实际绑定的 vec4 个数判界内（常量下标也判：游戏绑定的大小可能小于 64 KB）；地址只在下标可能出声明数组时钳
        if (ubo && top_struct && k == 1 && member == 0 && op == SpvOpTypeArray && (s->in[s->pos[s->in[s->pos[vt] + 3]]] >> 16) == 3 && s->stride[cur] == 16) {
            uint32_t ub = s->dbind[base];
            if (s->direct) { uint32_t c = s->cslot[base]; if (c < 4 || c > 17) { cur = elem; continue; } ub = c - 4; }   // 直连：表[NVN 槽]；c0 / c1 / c2 不钳（文件头 ①）
            uint32_t u = as_u32(s, o, idx); if (!u) { red(s, GAL_SPVX_SKIP, "下标不是 32 位整数"); cur = elem; continue; }
            ent_val *e = ubo_len(s, f, s->dset[base], ub); if (!e) { red(s, GAL_SPVX_SKIP, "函数内长度值过多"); return 0; }
            uint32_t in1 = ult(s, o, u, e->len);
            if (!(is_c && cv < len_c)) {
                uint32_t c = umin(s, o, u, e->last);
                if (len_c < 4096) { c = umin(s, o, c, sx_cst(s, len_c - 1)); in1 = land(s, o, in1, ult(s, o, u, sx_cst(s, len_c))); }   // 比 Ryujinx 惯例短的数组再钳一次
                ni[k] = c;
            }
            inb_c[0] = land(s, o, inb_c[0], in1); changed = 1; s->st[GAL_SPVX_UBO]++; cur = elem; continue;
        }
        if (op == SpvOpTypeRuntimeArray) {
            if (!(top_struct && k == 1)) { red(s, GAL_SPVX_SKIP, "运行时数组不在顶层结构体成员上"); return 0; }
            ent_val *e = rt_len(s, f, base, member); if (!e) { red(s, GAL_SPVX_SKIP, "函数内长度值过多"); return 0; }
            last = e->last; len = e->len;
        } else {
            if ((is_c && cv < len_c) || masked_below(s, idx, len_c)) { cur = elem; continue; }   // 静态可证在界内：不动
            last = sx_cst(s, len_c - 1); len = sx_cst(s, len_c);
        }
        uint32_t u = as_u32(s, o, idx); if (!u) { red(s, GAL_SPVX_SKIP, "下标不是 32 位整数"); cur = elem; continue; }
        inb_c[vec] = land(s, o, inb_c[vec], ult(s, o, u, len));
        ni[k] = umin(s, o, u, last); changed = 1; s->st[GAL_SPVX_CLAMP]++;
        cur = elem;
    }
    if (!changed) return 0;
    // 计数关（缺省、出包口径）不建：没有 spv_count_flush 读它们，却以 thread bool& 穿函数传递、编译器消不掉（11-01 Spare-host：每支 1000+ 处，重片元 GPU +3%）
    if (gal_spvx_counting()) for (int v = 0; v < 2; v++) if (inb_c[v]) {   // 并进该类的计数布尔：all_k = all_k && 本链界内
        uint32_t var = cls_var(s, v ? GAL_OOB_VEC : cls), ld = s->nb++, a = s->nb++;
        W(o, OPW(SpvOpLoad, 4), s->tbool, ld, var); W(o, OPW(SpvOpLogicalAnd, 5), s->tbool, a, ld, inb_c[v]); W(o, OPW(SpvOpStore, 3), var, a);
    }
    wb_put(o, p, 4); wb_put(o, ni, nidx);
    uint32_t inb = inb_c[0] && inb_c[1] ? land(s, o, inb_c[0], inb_c[1]) : inb_c[0] ? inb_c[0] : inb_c[1];
    if (need_inb && inb && p[2] < s->bound) s->inb[p[2]] = inb;
    return 1;
}
static int atomic_ptr_word(uint32_t op) {   // 原子操作的指针操作数位置；非原子返回 0
    switch (op) {
    case SpvOpAtomicStore: return 1;
    case SpvOpAtomicExchange: case SpvOpAtomicCompareExchange: case SpvOpAtomicCompareExchangeWeak: case SpvOpAtomicIIncrement: case SpvOpAtomicIDecrement:
    case SpvOpAtomicIAdd: case SpvOpAtomicISub: case SpvOpAtomicSMin: case SpvOpAtomicUMin: case SpvOpAtomicSMax: case SpvOpAtomicUMax:
    case SpvOpAtomicAnd: case SpvOpAtomicOr: case SpvOpAtomicXor: case SpvOpAtomicFAddEXT: case SpvOpAtomicFMinEXT: case SpvOpAtomicFMaxEXT: return 3;
    default: return 0;
    }
}

static uint32_t *spv_bounds(const uint32_t *in, uint32_t nw, uint32_t *onw, uint32_t st[GAL_SPVX_NSTAT], uint32_t cvars[GAL_OOB_NVAR], int direct) {
    *onw = 0;
    if (nw < 5 || in[0] != SpvMagicNumber) return NULL;
    sx S = {0}, *s = &S; s->in = in; s->nw = nw; s->bound = in[3]; s->nb = in[3]; s->direct = direct;
    uint32_t B = s->bound;
    s->cslot = calloc(B, 1); s->pos = calloc(B, 4); s->rtype = calloc(B, 4); s->stride = calloc(B, 4); s->dset = calloc(B, 4); s->dbind = calloc(B, 4); s->rename = calloc(B, 4);
    s->deco = calloc(B, 1); s->wptr = calloc(B, 1); s->lm_block = calloc(B, 1); s->inb = calloc(B, 4); s->ptrs = calloc(B, 4);
    uint32_t *out = NULL; wbuf body = {0}; fn_ctx F = {0};
    uint32_t *phis = NULL; int nphi = 0, cphi = 0;
    g_wb_bad = 0;
    if (!s->cslot || !s->pos || !s->rtype || !s->stride || !s->dset || !s->dbind || !s->rename || !s->deco || !s->wptr || !s->lm_block || !s->inb || !s->ptrs) {
        GLOG("【红】着色器越界改写：按 ID 上限 %u 分配表失败，本支不加固", B); goto fail;
    }
    // ---- 第一遍：定义位置、结果类型、修饰、被写的指针、含循环合并指令的块 ----
    uint32_t cur_lab = 0;
    for (uint32_t i = 5; i < nw; ) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff;
        if (!n || i + n > nw) goto fail;
        bool hr = 0, ht = 0; SpvHasResultAndType((SpvOp)op, &hr, &ht);
        if (hr) { uint32_t id = in[i + (ht ? 2 : 1)]; if (id >= B) goto fail; s->pos[id] = i; if (ht) s->rtype[id] = in[i + 1]; }
        switch (op) {
        case SpvOpTypeInt: if (in[i + 2] == 32 && in[i + 3] == 0 && !s->tu32) s->tu32 = in[i + 1]; break;
        case SpvOpTypeBool: if (!s->tbool) s->tbool = in[i + 1]; break;
        case SpvOpTypeVector:
            break;
        case SpvOpTypePointer: s->ptrs[s->nptr++] = in[i + 1]; break;
        case SpvOpExtInstImport: if (!strcmp((const char *)(in + i + 2), "GLSL.std.450")) s->glsl = in[i + 1]; break;
        case SpvOpMemoryModel: s->mm_pos = i; break;
        case SpvOpEntryPoint: s->model = in[i + 1]; break;
        case SpvOpFunction: if (!s->first_fn) s->first_fn = i; break;
        case SpvOpLabel: cur_lab = in[i + 1]; break;
        case SpvOpLoopMerge: if (cur_lab < B) s->lm_block[cur_lab] = 1; break;
        case SpvOpStore: if (in[i + 1] < B) s->wptr[in[i + 1]] = 1; break;
        case SpvOpName: case SpvOpMemberName: {
            s->name_end = i + n;
            if (op != SpvOpName || !direct || in[i + 1] >= B || n < 3) break;   // <阶段>_c<N>：小写字母 + "_c" + 十进制
            const char *nm = (const char *)(in + i + 2), *e = memchr(nm, 0, (size_t)(n - 2) * 4); if (!e) break;
            const char *q = nm; while (*q >= 'a' && *q <= 'z') q++;
            if (q == nm || q[0] != '_' || q[1] != 'c' || q[2] < '0' || q[2] > '9') break;
            uint32_t v = 0; for (q += 2; *q >= '0' && *q <= '9' && v < 100; q++) v = v * 10 + (uint32_t)(*q - '0');
            if (!*q && v < 18) s->cslot[in[i + 1]] = (uint8_t)(v + 1);
            break;
        }
        case SpvOpDecorate: {
            uint32_t t = in[i + 1], d = in[i + 2]; if (t >= B) break;
            if (d == SpvDecorationBlock) s->deco[t] |= 1;
            else if (d == SpvDecorationBufferBlock) s->deco[t] |= 2;
            else if (d == SpvDecorationArrayStride && n > 3) s->stride[t] = in[i + 3];
            else if (d == SpvDecorationDescriptorSet && n > 3) s->dset[t] = in[i + 3];
            else if (d == SpvDecorationBinding && n > 3) { s->dbind[t] = in[i + 3]; s->deco[t] |= 4; }
            break;
        }
        default: { int w = atomic_ptr_word(op); if (w && in[i + w] < B) s->wptr[in[i + w]] = 1; }
        }
        if (op == SpvOpDecorate || op == SpvOpMemberDecorate || op == SpvOpDecorationGroup || op == SpvOpGroupDecorate || op == SpvOpGroupMemberDecorate ||
            op == SpvOpDecorateId || op == SpvOpDecorateString || op == SpvOpMemberDecorateString) { if (!s->ann_beg) s->ann_beg = i; s->ann_end = i + n; }
        i += n;
    }
    if (!s->first_fn || !s->mm_pos || !s->ann_end) goto fail;
    if (!s->tu32) { s->tu32 = s->nb++; s->new_tu32 = 1; W(&s->glob, OPW(SpvOpTypeInt, 4), s->tu32, 32, 0); }
    if (!s->tbool) { s->tbool = s->nb++; s->new_tbool = 1; W(&s->glob, OPW(SpvOpTypeBool, 2), s->tbool); }
    // 常量缓冲长度表大小：每集 = 最大绑定号 + 1（直连：固定 NXGAL_DIRECT_UBOLEN_N，按 NVN 槽）
    for (uint32_t id = 1; id < B; id++) {
        if (!is_op(s, id, SpvOpVariable) || !(s->deco[id] & 4) || s->in[s->pos[id] + 3] != SC_Uniform) continue;
        uint32_t pt = s->rtype[id], t = is_op(s, pt, SpvOpTypePointer) ? s->in[s->pos[pt] + 3] : 0;
        if (!t || !(s->deco[t] & 1) || s->dset[id] >= GAL_MAX_SETS || s->dbind[id] >= GAL_UBOLEN_BINDING) continue;
        uint32_t n = direct ? NXGAL_DIRECT_UBOLEN_N : s->dbind[id] + 1;
        if (n > s->ubo_n[s->dset[id]]) s->ubo_n[s->dset[id]] = n;
    }
    // ---- 第二遍：函数体改写 ----
    uint32_t out_lab = 0, in_lab = 0; int in_fn = 0, first_blk = 0; uint32_t splice = 0;
    for (uint32_t i = s->first_fn; i < nw; ) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff; const uint32_t *p = in + i;
        if (op == SpvOpFunction) { in_fn = 1; first_blk = 1; splice = 0; F.pre.n = 0; F.nv = 0; }
        if (op == SpvOpLabel) { in_lab = out_lab = p[1]; if (first_blk == 2) first_blk = 0; }
        if (in_fn && first_blk == 1 && op == SpvOpLabel) { wb_put(&body, p, n); first_blk = 2; i += n; continue; }
        if (first_blk == 2 && op != SpvOpVariable && !splice) splice = body.n + 1;   // 首块里第一条非变量指令的位置（+1 区分「还没定」）
        if (op == SpvOpFunctionEnd) {
            if (F.pre.n && splice) {   // 入口段插到首块变量之后
                uint32_t at = splice - 1; wbuf t = {0}; wb_put(&t, body.w + at, body.n - at); body.n = at;
                wb_put(&body, F.pre.w, F.pre.n); wb_put(&body, t.w, t.n); free(t.w);
                for (int k = 0; k < nphi; k++) if (phis[k] >= at) phis[k] += F.pre.n;
            }
            in_fn = 0; wb_put(&body, p, n); i += n; continue;
        }
        if (in_fn && (op == SpvOpAccessChain || op == SpvOpInBoundsAccessChain) && rewrite_chain(s, &F, &body, p, n)) { i += n; continue; }
        int aw = atomic_ptr_word(op); uint32_t ptr = op == SpvOpStore ? p[1] : aw ? p[aw] : 0;
        if (in_fn && ptr && ptr < B && s->inb[ptr]) {
            if (s->lm_block[in_lab]) { red(s, GAL_SPVX_SKIP, "循环头块里的写 / 原子（拆块会移走循环合并指令）"); wb_put(&body, p, n); i += n; continue; }
            // 越界的原子不执行，返回钳到的那个元素的当前值（与越界读同值）。原先返回 0：读改写重试循环（do { v = a[k]; r = CAS(a[k], v, f(v)); } while (r != v)，
            //   16 位存储就是这样模拟的）越界时读到钳到的末元素、原子却回 0，末元素不为 0 就永远对不上，GPU 在循环里空转不退（直连没有循环上限）。
            //   11-23 D-WZCF：一款游戏的几何着色器剔除后写压缩下标，写过游戏给的 32 字节，过场一开 GPU 就挂死
            int res = op != SpvOpStore && op != SpvOpAtomicStore; uint32_t rid = res ? p[2] : 0, r2 = res ? s->nb++ : 0;
            uint32_t T = s->nb++, M = s->nb++, E = res ? s->nb++ : M;
            W(&body, OPW(SpvOpSelectionMerge, 3), M, 0); W(&body, OPW(SpvOpBranchConditional, 4), s->inb[ptr], T, E); W(&body, OPW(SpvOpLabel, 2), T);
            uint32_t at = body.n; wb_put(&body, p, n); if (res) body.w[at + 2] = r2;
            W(&body, OPW(SpvOpBranch, 2), M);
            uint32_t r3 = 0; if (res) { r3 = s->nb++; W(&body, OPW(SpvOpLabel, 2), E); W(&body, OPW(SpvOpLoad, 4), p[1], r3, ptr); W(&body, OPW(SpvOpBranch, 2), M); }
            W(&body, OPW(SpvOpLabel, 2), M);
            if (res) W(&body, OPW(SpvOpPhi, 7), p[1], rid, r2, T, r3, E);
            out_lab = M; s->rename[in_lab] = M;
            s->st[res || op == SpvOpAtomicStore ? GAL_SPVX_ATOMIC : GAL_SPVX_STORE]++;
            i += n; continue;
        }
        if (op == SpvOpPhi) { if (nphi == cphi) { cphi = cphi * 2 + 16; phis = realloc(phis, cphi * 4); } phis[nphi++] = body.n; }
        wb_put(&body, p, n); i += n;
    }
    if (!s->st[GAL_SPVX_CLAMP] && !s->st[GAL_SPVX_UBO]) goto fail;   // 没有要改的：用原码
    // 原有 OpPhi 的前驱：被拆的块，终结指令已在最后一个拆出块里
    for (int k = 0; k < nphi; k++) {
        uint32_t *q = body.w + phis[k], m = q[0] >> 16;
        for (uint32_t j = 4; j < m; j += 2) if (q[j] < B && s->rename[q[j]]) q[j] = s->rename[q[j]];
    }
    // ---- 拼模块：头 + [GLSL 导入] + 原注解 + 新修饰 + 原类型段 + 新全局 + 函数体 ----
    wbuf o = {0}; wb_put(&o, in, 5);
    uint32_t name_at = s->name_end ? s->name_end : s->ann_beg;   // 新 OpName：调试名字段末尾（没有名字就在首条注解前）
    for (uint32_t i = 5; i < s->first_fn; ) {
        uint32_t n = in[i] >> 16;
        if (i == name_at) wb_put(&o, s->names.w, s->names.n);
        if (i == s->mm_pos && s->new_glsl) { W(&o, OPW(SpvOpExtInstImport, 6), s->glsl, 0x4c534c47u /* GLSL */, 0x6474732eu /* .std */, 0x3035342eu /* .450 */, 0); }
        wb_put(&o, in + i, n); i += n;
        if (i == s->ann_end) wb_put(&o, s->deco_add.w, s->deco_add.n);
    }
    // 新类型若是 u32 / bool 本身，须排在用到它们的常量之前：glob 里本来就是先建类型后用
    wb_put(&o, s->glob.w, s->glob.n); wb_put(&o, body.w, body.n);
    if (g_wb_bad || !o.w) { free(o.w); goto fail; }   // 扩容失败：整支不出新码（调用方用原 SPIR-V，红行已打）
    o.w[3] = s->nb; out = o.w; *onw = o.n;
    memcpy(cvars, s->cvar, sizeof s->cvar);
    for (int k = 0; k < GAL_SPVX_NSTAT; k++) st[k] += s->st[k];
fail:
    for (int k = 0; k < GAL_SPVX_NSTAT && !out; k++) st[k] += s->st[k];   // 没出新码也记跳过数
    free(s->cslot); free(s->pos); free(s->rtype); free(s->stride); free(s->dset); free(s->dbind); free(s->rename); free(s->deco); free(s->wptr); free(s->lm_block); free(s->inb); free(s->ptrs);
    free(s->glob.w); free(s->deco_add.w); free(s->names.w); free(body.w); free(F.pre.w); free(phis);
    return out;
}

// ---------- 循环上限（10-19 巫师3 自动曝光死循环；画面线 gfx-stall 原型，上限改按阶段分档）----------
// 每个函数一个计数变量（Function 存储、初值 0），每条循环回边 +1，满 cap 次即跳出到该循环的合并块。
// 回边形式：OpBranch 头 → OpBranchConditional 未满 头 合并；OpBranchConditional c 头 合并 → (c && 未满)；OpBranchConditional c 合并 头 → (c || 已满)。
// 其他形式（OpSwitch 回边、合并块带 OpPhi 且会新增前驱）不改，计入跳过并报红。
// 计数（10-21）：计数变量只增不减、到上限即跳出，所以「本函数这次调用到过上限」⇔ 计数 ≥ cap；在函数每个返回 / 丢弃前并进私有布尔 *loopvar（初值假），
// 由 spv_count_flush 在入口收尾时报。返回 malloc 的新码（无循环时 NULL）。
// 10-21 改按工作量：回边加权重 w（该循环体静态指令数向上取 2 的幂，有下限）而不是 +1。
// dyn（计算阶段）：入口函数读 NumWorkgroups（着色器没声明就新增这个内建输入并挂到入口接口上）算上限 capv = clamp(总预算 / 线程总数, 下限, cap_n)，经共享内存 + 栅栏读回后存私有变量，各函数用它；
// 「到过上限」同样按 capv 判（计数 ≥ capv）
static uint32_t *spv_loop_guard(const uint32_t *in, uint32_t nw, uint32_t cap_n, int dyn, uint32_t *onw, uint32_t st[GAL_SPVX_NSTAT], uint32_t *loopvar) {
    enum { EntryPoint = 15, ExecutionMode = 16, TypeBool = 20, TypeInt = 21, TypeVector = 23, TypePointer = 32, Constant = 43, ConstantFalse = 42, Function = 54, FunctionEnd = 56,
           Variable = 59, Load = 61, Store = 62, Decorate = 71, MemberDecorate = 72, CompositeExtract = 81, IAdd = 128, UDiv = 134, LogicalOr = 166, LogicalAnd = 167,
           Select = 169, UGreaterThanEqual = 174, ULessThan = 176, ShiftLeftLogical = 196, Phi = 245, LoopMerge = 246, SelectionMerge = 247,
           Label = 248, Branch = 249, BranchConditional = 250, Kill = 252, Return = 253, ReturnValue = 254, Line = 8, NoLine = 317, TerminateInvocation = 4416,
           TypeArray = 28, AccessChain = 65, ControlBarrier = 224 };
    _Static_assert((int)EntryPoint == SpvOpEntryPoint && (int)ExecutionMode == SpvOpExecutionMode && (int)TypeVector == SpvOpTypeVector && (int)CompositeExtract == SpvOpCompositeExtract &&
                   (int)UDiv == SpvOpUDiv && (int)Select == SpvOpSelect && (int)ShiftLeftLogical == SpvOpShiftLeftLogical && (int)Line == SpvOpLine && (int)NoLine == SpvOpNoLine, "SPIR-V 操作码");
    _Static_assert((int)ConstantFalse == SpvOpConstantFalse && (int)Return == SpvOpReturn && (int)ReturnValue == SpvOpReturnValue && (int)UGreaterThanEqual == SpvOpUGreaterThanEqual, "SPIR-V 操作码");
    _Static_assert((int)TypeArray == SpvOpTypeArray && (int)AccessChain == SpvOpAccessChain && (int)ControlBarrier == SpvOpControlBarrier, "SPIR-V 操作码");
    *onw = 0; *loopvar = 0;
    if (nw < 5) return NULL;
    uint32_t bound = in[3], first_fn = 0, tbool = 0, tuint = 0, ppb = 0, ann_end = 0, np = 0, pp[256][3], nv3 = 0, v3[16][2];
    uint32_t nwg = 0, nwg_pt = 0, ep_at = 0, ep_fn = 0, lsz = 0;   // NumWorkgroups 内建变量及其指针类型、入口指令位置、组内线程数（LocalSize 三维乘积）
    uint32_t *merge_of = calloc(bound, 4), *lab_pos = calloc(bound, 4), *lab_ord = calloc(bound, 4);   // lab_pos：标签在指令流中的字偏移 + 1；lab_ord：标签是第几条指令 + 1
    uint8_t *phi_at = calloc(bound, 1);
#define FREE_ALL() do { free(merge_of); free(lab_pos); free(lab_ord); free(phi_at); } while (0)
    if (!merge_of || !lab_pos || !lab_ord || !phi_at) { FREE_ALL(); return NULL; }
    int nloop = 0; uint32_t cur = 0, prev_op = 0, ord = 0;
    for (uint32_t i = 5; i < nw; ord++) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff;
        if (!n || i + n > nw) { FREE_ALL(); return NULL; }
        if (op == TypeBool && !tbool) tbool = in[i + 1];
        if (op == TypeInt && n == 4 && in[i + 2] == 32 && in[i + 3] == 0 && !tuint) tuint = in[i + 1];
        if (op == TypeVector && n == 4 && in[i + 3] == 3 && nv3 < 16) { v3[nv3][0] = in[i + 1]; v3[nv3][1] = in[i + 2]; nv3++; }
        if (op == EntryPoint && !ep_at) { ep_at = i; ep_fn = n >= 3 ? in[i + 2] : 0; }
        if (op == ExecutionMode && n == 6 && in[i + 2] == 17 /* LocalSize */) { uint64_t sz = (uint64_t)in[i + 3] * in[i + 4] * in[i + 5]; lsz = sz && sz <= 4096 ? (uint32_t)sz : 0; }
        if (op == Decorate && n == 4 && in[i + 2] == 11 /* BuiltIn */ && in[i + 3] == 24 /* NumWorkgroups */) nwg = in[i + 1];
        if (op == Decorate || op == MemberDecorate || (op >= 73 && op <= 75) || op == 332 || op == 5632 || op == 5633) ann_end = i + n;
        // 修饰在类型 / 变量之前，到这里 nwg 已知
        if (op == Variable && n >= 4 && nwg && in[i + 2] == nwg) nwg_pt = in[i + 1];
        if (op == Function && !first_fn) first_fn = i;
        if (op == Label && in[i + 1] < bound) { cur = in[i + 1]; lab_pos[cur] = i + 1; lab_ord[cur] = ord + 1; }
        if (op == Phi && prev_op == Label && cur < bound) phi_at[cur] = 1;
        if (op == LoopMerge && cur < bound && in[i + 1] < bound) { merge_of[cur] = in[i + 1]; nloop++; }
        if (op == TypePointer && n == 4 && in[i + 2] == 6 /* Private */ && tbool && in[i + 3] == tbool && !ppb) ppb = in[i + 1];
        if (op == TypePointer && n == 4 && np < 256) { pp[np][0] = in[i + 1]; pp[np][1] = in[i + 2]; pp[np][2] = in[i + 3]; np++; }
        prev_op = op; i += n;
    }
    if (!nloop || !first_fn) { FREE_ALL(); return NULL; }
    uint32_t nb = bound, ntb = tbool ? 0 : nb++, ntu = tuint ? 0 : nb++;
    if (!tbool) tbool = ntb;
    if (!tuint) tuint = ntu;
    uint32_t tptr = nb++, c0 = nb++, c1 = nb++, ccap = nb++, cfalse = nb++, nppb = ppb ? 0 : nb++, lvar = nb++, cw[GAL_LOOP_WMAX_LOG2 + 1];
    if (!ppb) ppb = nppb;
    for (int k = 0; k <= GAL_LOOP_WMAX_LOG2; k++) cw[k] = nb++;
    // 整次派发封顶：要组内线程数是常量（LocalSize），新增内建变量还要能插修饰（有注解段）与改入口接口
    if (dyn && (!lsz || !ep_at || (!nwg && !ann_end))) dyn = 0;
    uint32_t tv3 = 0, tpv3 = 0, new_v3 = 0, new_pv3 = 0, new_nwg = 0, ctot = 0, cloc = 0, ccap16 = 0, c4 = 0, cfloor = 0;
    // 上限过共享内存中转（见 pend_cap 处）：uint[1] 共享数组及其指针、本线程私有副本、栅栏的作用域 / 语义常量
    uint32_t tarr = 0, pwa = 0, pwu = 0, wgv = 0, ppu = 0, pcv = 0, c2 = 0, csem = 0;
    if (dyn) {
        for (uint32_t k = 0; k < nv3 && !ntu; k++) if (v3[k][1] == tuint) { tv3 = v3[k][0]; break; }
        if (!tv3) { tv3 = nb++; new_v3 = 1; }
        for (uint32_t k = 0; k < np && !new_v3; k++) if (pp[k][1] == 1 /* Input */ && pp[k][2] == tv3) { tpv3 = pp[k][0]; break; }
        if (!tpv3) { tpv3 = nb++; new_pv3 = 1; }
        // 1 = 新增变量 + 修饰 + 挂入口接口；2 = 已声明、只挂入口接口
        if (!nwg) { nwg = nb++; new_nwg = 1; }
        // 着色器自己的 NumWorkgroups 不是 Input uvec3：不碰，只用单线程上限（新分的 id 闲置无害）
        else if (nwg_pt != tpv3) dyn = 0;
        else {
            uint32_t e = ep_at + (in[ep_at] >> 16), k = ep_at + 3; int has = 0;
            // 跳过入口名字符串：末字最高字节为 0
            while (k < e && (in[k] >> 24)) k++;
            for (k++; k < e; k++) if (in[k] == nwg) has = 1;
            if (!has) new_nwg = 2;
        }
        ctot = nb++; cloc = nb++; ccap16 = nb++; c4 = nb++; cfloor = nb++;
        tarr = nb++; pwa = nb++; pwu = nb++; wgv = nb++; ppu = nb++; pcv = nb++; c2 = nb++; csem = nb++;
    }
    const int wmin = cap_n == GAL_LOOP_CAP_CS ? GAL_LOOP_WMIN_LOG2_CS : GAL_LOOP_WMIN_LOG2_GFX;
    // 计数（翻译期开关，同 spv_count_flush）：关时不建「到过上限」私有布尔、不在返回点插记账，只留上限本身
    const int cnt = gal_spvx_counting();
    size_t cap = nw + 256 + (size_t)nloop * 32 + 4096; uint32_t *o = malloc(cap * 4), w = 0;
    if (!o) { FREE_ALL(); return NULL; }
#define GROW(k) do { if (w + (k) > cap) { size_t _nc = cap * 2 + (k); uint32_t *_p = realloc(o, _nc * 4); if (!_p) goto oom; o = _p; cap = _nc; } } while (0)
#define EMIT(...) do { uint32_t _t[] = { __VA_ARGS__ }; uint32_t _n = sizeof _t / 4; GROW(_n); memcpy(o + w, _t, sizeof _t); w += _n; } while (0)
    memcpy(o, in, 20); w = 5;
    uint32_t var = 0, capv = ccap, cur_lab = 0; int in_fn = 0, need_var = 0, first_lab = 0, pend_cap = 0, fn_ep = 0;
    prev_op = 0; ord = 0;
    for (uint32_t i = 5; i < nw; ord++) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff;
        // 新增的 NumWorkgroups 修饰插在注解段末
        if (i == ann_end && dyn && new_nwg == 1) EMIT(OPW(Decorate, 4), nwg, 11 /* BuiltIn */, 24 /* NumWorkgroups */);
        if (i == first_fn) {
            if (ntb) EMIT(OPW(TypeBool, 2), ntb);
            if (ntu) EMIT(OPW(TypeInt, 4), ntu, 32, 0);
            EMIT(OPW(TypePointer, 4), tptr, 7 /* Function */, tuint);
            EMIT(OPW(Constant, 4), tuint, c0, 0); EMIT(OPW(Constant, 4), tuint, c1, 1); EMIT(OPW(Constant, 4), tuint, ccap, cap_n);
            for (int k = 0; k <= GAL_LOOP_WMAX_LOG2; k++) EMIT(OPW(Constant, 4), tuint, cw[k], 1u << k);
            // 到过上限（本调用）：只在计数开时建（与 spv_count_flush 同一翻译期开关；出包口径只留上限本身）
            if (cnt) {
                EMIT(OPW(ConstantFalse, 3), tbool, cfalse);
                if (nppb) EMIT(OPW(TypePointer, 4), nppb, 6 /* Private */, tbool);
                EMIT(OPW(Variable, 5), ppb, lvar, 6 /* Private */, cfalse);
            }
            if (dyn) {
                if (new_v3) EMIT(OPW(TypeVector, 4), tv3, tuint, 3);
                if (new_pv3) EMIT(OPW(TypePointer, 4), tpv3, 1 /* Input */, tv3);
                if (new_nwg == 1) EMIT(OPW(Variable, 4), tpv3, nwg, 1);
                EMIT(OPW(Constant, 4), tuint, ctot, GAL_LOOP_TOTAL_CS_SH4); EMIT(OPW(Constant, 4), tuint, cloc, lsz);
                EMIT(OPW(Constant, 4), tuint, ccap16, cap_n >> 4); EMIT(OPW(Constant, 4), tuint, c4, 4); EMIT(OPW(Constant, 4), tuint, cfloor, GAL_LOOP_FLOOR_CS);
                // 作用域 Workgroup = 2；语义 AcquireRelease (0x8) | WorkgroupMemory (0x100)
                EMIT(OPW(Constant, 4), tuint, c2, 2); EMIT(OPW(Constant, 4), tuint, csem, 0x108);
                EMIT(OPW(TypeArray, 4), tarr, tuint, c1); EMIT(OPW(TypePointer, 4), pwa, 4 /* Workgroup */, tarr); EMIT(OPW(TypePointer, 4), pwu, 4, tuint);
                EMIT(OPW(Variable, 4), pwa, wgv, 4);
                EMIT(OPW(TypePointer, 4), ppu, 6 /* Private */, tuint); EMIT(OPW(Variable, 4), ppu, pcv, 6);
            }
        }
        if (op == Function) {
            in_fn = 1; first_lab = 1; need_var = 0;
            for (uint32_t j = i + n; j < nw; j += in[j] >> 16) { uint32_t oj = in[j] & 0xffff; if (oj == FunctionEnd) break; if (oj == LoopMerge) { need_var = 1; break; } if (!(in[j] >> 16)) break; }
            var = need_var ? nb++ : 0; capv = ccap; fn_ep = ep_fn && n >= 3 && in[i + 2] == ep_fn;
        }
        if (op == FunctionEnd) in_fn = 0;
        if (op == Label) cur_lab = in[i + 1];
        // 首块的局部变量之后：单线程上限 capv = clamp(总预算 / 线程总数, 下限, cap_n)（逐级整除，不会溢出），只在入口函数算一次。
        // 算出的值过一道共享内存（全组写同一个值 → 组内栅栏 → 读回）再用，入口函数存进私有变量，其余带循环的函数从私有变量读：
        //   10-21 怪猎计算着色器 98e4eb43c87f2b1c（约 1.3 万行 MSL、一个约 1 万行的大循环）：由 threadgroups_per_grid 直接算出的值只要活过大循环
        //   （循环出口比较、或循环后才用都算），applegpu-nt 编码阶段 abort「LLVM ERROR: Failed to encode.」（g18p 离线出包、g17s 本机运行时编译服务同样崩，
        //   运行时拿到空管线）；换成缓冲里读的值 / 线程号 / 常量都编得过，经共享内存读回的值也编得过（docs/坑记录.md）。
        //   栅栏在入口首块、任何分支之前，全组线程都到得了；共享数组 uint[1] 走 spvUnsafeArray（计算着色器共享内存溢出改写认得）
        if (pend_cap && op != Variable && op != Line && op != NoLine && !fn_ep) {
            pend_cap = 0; capv = nb++;
            EMIT(OPW(Load, 4), tuint, capv, pcv);
        }
        if (pend_cap && op != Variable && op != Line && op != NoLine) {
            pend_cap = 0;
            uint32_t g = nb++, x = nb++, y = nb++, z = nb++, d0 = nb++, d1 = nb++, d2 = nb++, d3 = nb++, lt = nb++, m = nb++, sh = nb++, lf = nb++;
            capv = nb++;
            EMIT(OPW(Load, 4), tv3, g, nwg);
            EMIT(OPW(CompositeExtract, 5), tuint, x, g, 0); EMIT(OPW(CompositeExtract, 5), tuint, y, g, 1); EMIT(OPW(CompositeExtract, 5), tuint, z, g, 2);
            EMIT(OPW(UDiv, 5), tuint, d0, ctot, x); EMIT(OPW(UDiv, 5), tuint, d1, d0, y); EMIT(OPW(UDiv, 5), tuint, d2, d1, z); EMIT(OPW(UDiv, 5), tuint, d3, d2, cloc);
            EMIT(OPW(ULessThan, 5), tbool, lt, d3, ccap16); EMIT(OPW(Select, 6), tuint, m, lt, d3, ccap16); EMIT(OPW(ShiftLeftLogical, 5), tuint, sh, m, c4);
            uint32_t cv0 = nb++, ac = nb++;
            EMIT(OPW(ULessThan, 5), tbool, lf, sh, cfloor); EMIT(OPW(Select, 6), tuint, cv0, lf, cfloor, sh);
            EMIT(OPW(AccessChain, 5), pwu, ac, wgv, c0); EMIT(OPW(Store, 3), ac, cv0);
            EMIT(OPW(ControlBarrier, 4), c2, c2, csem);
            EMIT(OPW(Load, 4), tuint, capv, ac); EMIT(OPW(Store, 3), pcv, capv);
        }
        if (cnt && in_fn && var && (op == Return || op == ReturnValue || op == Kill || op == TerminateInvocation)) {   // 本调用到过上限 → 并进 lvar（计数开才插）
            uint32_t ld = nb++, h = nb++, l = nb++, r = nb++;
            EMIT(OPW(Load, 4), tuint, ld, var); EMIT(OPW(UGreaterThanEqual, 5), tbool, h, ld, capv);
            EMIT(OPW(Load, 4), tbool, l, lvar); EMIT(OPW(LogicalOr, 5), tbool, r, l, h); EMIT(OPW(Store, 3), lvar, r);
        }
        int guard = 0; uint32_t hdr = 0;
        if (in_fn && var && (op == Branch || op == BranchConditional)) {
            uint32_t t0 = in[i + 1 + (op == BranchConditional)], t1 = op == BranchConditional ? in[i + 3] : 0;
            uint32_t here = lab_pos[cur_lab];
            if (t0 < bound && merge_of[t0] && lab_pos[t0] <= here) hdr = t0;
            else if (op == BranchConditional && t1 < bound && merge_of[t1] && lab_pos[t1] <= here) hdr = t1;
            if (hdr) {
                uint32_t m = merge_of[hdr];
                if (op == Branch) guard = phi_at[m] ? 0 : 1;
                else guard = (t0 == hdr && t1 == m) ? 2 : (t1 == hdr && t0 == m) ? 3 : 0;
                if (guard) st[GAL_SPVX_LOOP]++;
                else { st[GAL_SPVX_SKIP]++; GRED_ONCE("着色器越界改写：循环回边形式认不出、未加上限（首例；之后只计数 gal_spvx_totals[%d]）", GAL_SPVX_SKIP); }
            }
        }
        if (guard) {
            // 本块里紧挨终结指令前若有合并指令（单块循环的 OpLoopMerge），计数指令插在合并指令之前：回退已输出的合并指令
            uint32_t mw = 0, mbuf[8];
            if ((prev_op == LoopMerge || prev_op == SelectionMerge) && w >= 4) { mw = prev_op == LoopMerge ? 4 : 3; if ((o[w - mw] & 0xffff) == prev_op && (o[w - mw] >> 16) == mw) { memcpy(mbuf, o + w - mw, mw * 4); w -= mw; } else mw = 0; }
            // 权重：循环头标签到本回边分支的指令数（含两端；嵌套的内层循环体也算在外层里），向上取 2 的幂，夹在 [下限, 2^14]
            uint32_t cost = lab_ord[hdr] && ord + 1 >= lab_ord[hdr] ? ord + 2 - lab_ord[hdr] : 1; int wl = wmin;
            while (wl < GAL_LOOP_WMAX_LOG2 && (1u << wl) < cost) wl++;
            uint32_t ld = nb++, add = nb++, ok = nb++;
            EMIT(OPW(Load, 4), tuint, ld, var); EMIT(OPW(IAdd, 5), tuint, add, ld, cw[wl]); EMIT(OPW(Store, 3), var, add);
            if (guard == 3) EMIT(OPW(UGreaterThanEqual, 5), tbool, ok, add, capv); else EMIT(OPW(ULessThan, 5), tbool, ok, add, capv);
            uint32_t cond = ok;
            if (guard >= 2) { cond = nb++; EMIT(OPW(guard == 2 ? LogicalAnd : LogicalOr, 5), tbool, cond, in[i + 1], ok); }
            if (mw) { GROW(mw); memcpy(o + w, mbuf, mw * 4); w += mw; }
            if (guard == 1) EMIT(OPW(BranchConditional, 4), cond, hdr, merge_of[hdr]);
            else { GROW(n); memcpy(o + w, in + i, n * 4); o[w + 1] = cond; w += n; }
        } else if (op == EntryPoint && i == ep_at && dyn && (new_nwg || in[1] >= 0x10400)) {
            // NumWorkgroups 挂到入口接口上；SPIR-V 1.4 起接口要列全部全局变量，新增的共享 / 私有变量也挂上
            uint32_t add[3], na = 0;
            if (new_nwg) add[na++] = nwg;
            if (in[1] >= 0x10400) { add[na++] = wgv; add[na++] = pcv; }
            GROW(n + na); memcpy(o + w, in + i, n * 4); o[w] = OPW(EntryPoint, n + na); memcpy(o + w + n, add, na * 4); w += n + na;
        } else {
            GROW(n);
            memcpy(o + w, in + i, n * 4); w += n;
        }
        // 计数变量（OpVariable 须在首块最前）；计算阶段随后在首块局部变量之后算本函数上限
        if (op == Label && in_fn && first_lab) { first_lab = 0; if (var) EMIT(OPW(Variable, 5), tptr, var, 7, c0); pend_cap = dyn && (var || fn_ep); }
        prev_op = op; i += n;
    }
#undef EMIT
#undef GROW
    o[3] = nb; FREE_ALL();
    *onw = w; *loopvar = cnt ? lvar : 0; return o;
oom:
    GLOG("【红】着色器越界改写：循环上限输出缓冲扩容失败（已有 %u 字、容量 %zu 字），本支不加循环上限", w, cap);
    free(o); FREE_ALL();
    return NULL;
#undef FREE_ALL
}

// ---------- 常态计数收尾（10-21）----------
// 入口函数每个 OpReturn 前、任何函数的 OpKill / OpTerminateInvocation 前插：
//   oob = !(各类「全在界内」布尔之与)；any = oob || 到过上限；if (gal_cnt && any) { 格[0] += oob；格[1] |= 类别位；格[2] += 到过上限 }
// gal_cnt = OpConstantTrue（只在计数开时翻译才调本函数；不用函数常量，见文件头 ③）。计数格 = 集 0 绑定 GAL_OOBCNT_BINDING 的 { uint[4] }（Uniform + BufferBlock）。
// vars[k] = 0 表示该类没有（没有任何一类时返回 NULL）。拆出的块以 OpReturn / OpKill 收尾，没有后继，不涉及 OpPhi。
static uint32_t *spv_count_flush(const uint32_t *in, uint32_t nw, const uint32_t vars[GAL_OOB_NVAR], uint32_t *onw) {
    enum { TypeBool = 20, TypeInt = 21, TypePointer = 32, TypeStruct = 30, Constant = 43, ConstantTrue = 41, Function = 54, FunctionEnd = 56,
           Variable = 59, Load = 61, AccessChain = 65, Decorate = 71, MemberDecorate = 72, EntryPoint = 15, BitwiseOr = 197, LogicalOr = 166, LogicalAnd = 167,
           LogicalNot = 168, Select = 169, AtomicIAdd = 234, AtomicOr = 241, SelectionMerge = 247, Label = 248, Branch = 249, BranchConditional = 250,
           Kill = 252, Return = 253, TerminateInvocation = 4416 };
    _Static_assert((int)ConstantTrue == SpvOpConstantTrue && (int)BitwiseOr == SpvOpBitwiseOr && (int)LogicalNot == SpvOpLogicalNot && (int)AtomicOr == SpvOpAtomicOr &&
                   (int)AtomicIAdd == SpvOpAtomicIAdd && (int)TerminateInvocation == SpvOpTerminateInvocation && (int)Kill == SpvOpKill && (int)EntryPoint == SpvOpEntryPoint, "SPIR-V 操作码");
    *onw = 0;
    int any = 0; for (int k = 0; k < GAL_OOB_NVAR; k++) any |= vars[k] != 0;
    if (!any || nw < 5) return NULL;
    uint32_t bound = in[3], first_fn = 0, ann_end = 0, tbool = 0, tuint = 0, entry = 0, puu = 0;
    for (uint32_t i = 5; i < nw; ) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff;
        if (!n || i + n > nw) return NULL;
        if (op == TypeBool && !tbool) tbool = in[i + 1];
        if (op == TypeInt && n == 4 && in[i + 2] == 32 && in[i + 3] == 0 && !tuint) tuint = in[i + 1];
        if (op == EntryPoint && !entry) entry = in[i + 2];
        if (op == Function && !first_fn) first_fn = i;
        if (op == Decorate || op == MemberDecorate || (op >= 73 && op <= 75) || op == 332 || op == 5632 || op == 5633) ann_end = i + n;
        if (op == TypePointer && n == 4 && in[i + 2] == 2 /* Uniform */ && tuint && in[i + 3] == tuint && !puu) puu = in[i + 1];
        i += n;
    }
    if (!first_fn || !ann_end || !tbool || !tuint || !entry) return NULL;   // 前两遍已建好 bool / u32（有计数变量就一定有）
    uint32_t nb = bound, spec = nb++, cst = nb++, pcst = nb++, cell = nb++, npuu = puu ? 0 : nb++, cz = nb++, c1 = nb++, c2 = nb++, cbit[GAL_OOB_NVAR];
    if (!puu) puu = npuu;
    for (int k = 0; k < GAL_OOB_NVAR; k++) cbit[k] = nb++;
    size_t cap = nw + 512 + 4096; uint32_t *o = malloc(cap * 4), w = 0;
    if (!o) return NULL;
#define GROW(k) do { if (w + (k) > cap) { size_t _nc = cap * 2 + (k); uint32_t *_p = realloc(o, _nc * 4); if (!_p) goto oom; o = _p; cap = _nc; } } while (0)
#define EMIT(...) do { uint32_t _t[] = { __VA_ARGS__ }; uint32_t _n = sizeof _t / 4; GROW(_n); memcpy(o + w, _t, sizeof _t); w += _n; } while (0)
    memcpy(o, in, 20); w = 5;
    uint32_t fn = 0;
    for (uint32_t i = 5; i < nw; ) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff;
        if (i == ann_end) {
            EMIT(OPW(Decorate, 3), cst, 3 /* BufferBlock */);
            for (uint32_t m = 0; m < 4; m++) EMIT(OPW(MemberDecorate, 5), cst, m, 35 /* Offset */, m * 4);
            EMIT(OPW(Decorate, 4), cell, 34 /* DescriptorSet */, 0); EMIT(OPW(Decorate, 4), cell, 33 /* Binding */, GAL_OOBCNT_BINDING);
        }
        if (i == first_fn) {
            EMIT(OPW(ConstantTrue, 3), tbool, spec);
            EMIT(OPW(TypeStruct, 6), cst, tuint, tuint, tuint, tuint); EMIT(OPW(TypePointer, 4), pcst, 2 /* Uniform */, cst);
            if (npuu) EMIT(OPW(TypePointer, 4), npuu, 2, tuint);
            EMIT(OPW(Variable, 4), pcst, cell, 2);
            EMIT(OPW(Constant, 4), tuint, cz, 0); EMIT(OPW(Constant, 4), tuint, c1, 1); EMIT(OPW(Constant, 4), tuint, c2, 2);
            for (int k = 0; k < GAL_OOB_NVAR; k++) EMIT(OPW(Constant, 4), tuint, cbit[k], 1u << k);
        }
        if (op == Function) fn = in[i + 2];
        if ((op == Return && fn == entry) || op == Kill || op == TerminateInvocation) {
            uint32_t ld[GAL_OOB_NVAR] = {0}, all = 0, oob = 0, lh = 0, anyv, go, T = nb++, M = nb++;
            for (int k = 0; k < GAL_OOB_LOOP; k++) if (vars[k]) {
                ld[k] = nb++; EMIT(OPW(Load, 4), tbool, ld[k], vars[k]);
                if (all) { uint32_t a = nb++; EMIT(OPW(LogicalAnd, 5), tbool, a, all, ld[k]); all = a; } else all = ld[k];
            }
            if (all) { oob = nb++; EMIT(OPW(LogicalNot, 4), tbool, oob, all); }
            if (vars[GAL_OOB_LOOP]) { lh = nb++; EMIT(OPW(Load, 4), tbool, lh, vars[GAL_OOB_LOOP]); }
            if (oob && lh) { anyv = nb++; EMIT(OPW(LogicalOr, 5), tbool, anyv, oob, lh); } else anyv = oob ? oob : lh;
            go = nb++; EMIT(OPW(LogicalAnd, 5), tbool, go, spec, anyv);
            EMIT(OPW(SelectionMerge, 3), M, 0); EMIT(OPW(BranchConditional, 4), go, T, M); EMIT(OPW(Label, 2), T);
            uint32_t mask = 0;
            for (int k = 0; k < GAL_OOB_NVAR; k++) {
                uint32_t v = k == GAL_OOB_LOOP ? lh : ld[k]; if (!v) continue;
                uint32_t sel = nb++; if (k == GAL_OOB_LOOP) EMIT(OPW(Select, 6), tuint, sel, v, cbit[k], cz); else EMIT(OPW(Select, 6), tuint, sel, v, cz, cbit[k]);
                if (mask) { uint32_t r = nb++; EMIT(OPW(BitwiseOr, 5), tuint, r, mask, sel); mask = r; } else mask = sel;
            }
            uint32_t p0 = nb++, p1 = nb++, a0 = nb++, a1 = nb++, s0 = nb++;
            if (oob) { EMIT(OPW(Select, 6), tuint, s0, oob, c1, cz); EMIT(OPW(AccessChain, 5), puu, p0, cell, cz); EMIT(OPW(AtomicIAdd, 7), tuint, a0, p0, c1 /* Device */, cz /* Relaxed */, s0); }
            EMIT(OPW(AccessChain, 5), puu, p1, cell, c1); EMIT(OPW(AtomicOr, 7), tuint, a1, p1, c1, cz, mask);
            if (lh) { uint32_t p2 = nb++, a2 = nb++, s2 = nb++; EMIT(OPW(Select, 6), tuint, s2, lh, c1, cz); EMIT(OPW(AccessChain, 5), puu, p2, cell, c2); EMIT(OPW(AtomicIAdd, 7), tuint, a2, p2, c1, cz, s2); }
            EMIT(OPW(Branch, 2), M); EMIT(OPW(Label, 2), M);
        }
        GROW(n); memcpy(o + w, in + i, n * 4); w += n; i += n;
    }
#undef EMIT
#undef GROW
    o[3] = nb; *onw = w; return o;
oom:
    GLOG("【红】着色器越界改写：计数收尾输出缓冲扩容失败（已有 %u 字、容量 %zu 字），本支不计数", w, cap);
    free(o); return NULL;
}

// ---------- 纹素缓冲前导元素（#798，直连口径）----------
// Metal 的纹素缓冲视图只能建在 minimumLinearTextureAlignmentForPixelFormat 的整数倍偏移上（Mac 16、iPhone 64 字节）；建在更小的偏移上，GPU 从向下取整处读
//   （M5 Max 实测 R32F 偏移 4 / 8 / 12 整体错后 1 / 2 / 3 个元素，docs/坑记录.md）。NVN 的纹素缓冲可以在任意按元素对齐的池偏移上。照参考实现
//   （nxnative 3c4de03c7，MIT）的做法：宿主把视图建在向下取整的对齐边界上、宽度多出「前导元素数」，着色器每次取数把下标加上它，取宽度减去它，原地读池里的字节、
//   看得见同一次提交里 GPU 先写的内容。前导数由宿主给：本改写给每个单个（非数组）纹素缓冲变量 V 新增一个只读存储缓冲 gal_tbl_<V 的名字>（uint data[1]，
//   绑定号 GAL_TBLEAD_BINDING0 + k），反射按名字认（Dsh.cs kind tblead、for = V），宿主把它指向常量表里值为前导数的那一格（nvn_mtl.m tbl_bind）。
//   数组（array<texture_buffer>）与改不了的访问不动，宿主照旧走 GPU 对齐副本（tba_copy）。
// 下标改写：moved = c + lead（无符号）；moved < lead 说明 c 是负数（-lead .. -1），保持原值：同硬件一样落在缓冲之外、读 0（参考实现同）
typedef struct { uint32_t var, k, tvar; } tb_ent;
static uint32_t tb_lead(sx *s, wbuf *o, const tb_ent *e, uint32_t ptr_u32) {
    uint32_t pc = s->nb++, v = s->nb++;
    W(o, OPW(SpvOpAccessChain, 6), ptr_u32, pc, e->tvar, sx_cst(s, 0), sx_cst(s, 0));
    W(o, OPW(SpvOpLoad, 4), s->tu32, v, pc);
    return v;
}
// 坐标 c（32 位整数标量）挪 lead；返回新坐标 id（同 c 的类型），0 = 改不了
static uint32_t tb_move(sx *s, wbuf *o, uint32_t c, uint32_t lead) {
    uint32_t t = c < s->bound ? s->rtype[c] : 0;
    if (!is_op(s, t, SpvOpTypeInt) || s->in[s->pos[t] + 2] != 32) return 0;
    uint32_t cu = as_u32(s, o, c); if (!cu) return 0;
    uint32_t mv = s->nb++, lt = s->nb++, sel = s->nb++;
    W(o, OPW(SpvOpIAdd, 5), s->tu32, mv, cu, lead);
    W(o, OPW(SpvOpULessThan, 5), s->tbool, lt, mv, lead);
    W(o, OPW(SpvOpSelect, 6), s->tu32, sel, lt, cu, mv);
    if (t == s->tu32) return sel;
    uint32_t r = s->nb++; W(o, OPW(SpvOpBitcast, 4), t, r, sel); return r;
}
static uint32_t *spv_tbias(const uint32_t *in, uint32_t nw, uint32_t *onw, uint32_t *nmoved) {
    *onw = 0; *nmoved = 0;
    if (nw < 5 || in[0] != SpvMagicNumber) return NULL;
    sx S = {0}, *s = &S; s->in = in; s->nw = nw; s->bound = in[3]; s->nb = in[3]; s->direct = 1;
    uint32_t B = s->bound;
    s->pos = calloc(B, 4); s->rtype = calloc(B, 4); s->dset = calloc(B, 4); s->ptrs = calloc(B, 4);
    uint32_t *nm_at = calloc(B, 4), *ent_of = calloc(B, 4); uint8_t *img_buf = calloc(B, 1);   // 按字节：原先同一句声明成 uint32_t * 却只分 B 字节，读写越界踩坏堆（ampere_isa 冷跑卡死 / 段错误）；nm_at[id] = 该 id 的 OpName 位置；img_buf[类型] = Dim Buffer 的图像类型；ent_of[变量 / 载入值] = 1 + 表项号
    tb_ent *ent = NULL; int nent = 0;
    uint32_t *out = NULL; wbuf body = {0};
    g_wb_bad = 0;
    if (!s->pos || !s->rtype || !s->dset || !s->ptrs || !nm_at || !img_buf || !ent_of) { GLOG("【红】纹素缓冲前导改写：按 ID 上限 %u 分配表失败，本支不改", B); goto fail; }
    for (uint32_t i = 5; i < nw; ) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff;
        if (!n || i + n > nw) goto fail;
        bool hr = 0, ht = 0; SpvHasResultAndType((SpvOp)op, &hr, &ht);
        if (hr) { uint32_t id = in[i + (ht ? 2 : 1)]; if (id >= B) goto fail; s->pos[id] = i; if (ht) s->rtype[id] = in[i + 1]; }
        switch (op) {
        case SpvOpTypeInt: if (in[i + 2] == 32 && in[i + 3] == 0 && !s->tu32) s->tu32 = in[i + 1]; break;
        case SpvOpTypeBool: if (!s->tbool) s->tbool = in[i + 1]; break;
        case SpvOpTypeImage: if (n > 3 && in[i + 3] == SpvDimBuffer) img_buf[in[i + 1]] = 1; break;
        case SpvOpTypeSampledImage: if (n > 2 && in[i + 2] < B && img_buf[in[i + 2]]) img_buf[in[i + 1]] = 1; break;   // Ryujinx 把纹素缓冲也声明成采样图像，取数前 OpImage 取出图像
        case SpvOpTypePointer: s->ptrs[s->nptr++] = in[i + 1]; break;
        case SpvOpMemoryModel: s->mm_pos = i; break;
        case SpvOpFunction: if (!s->first_fn) s->first_fn = i; break;
        case SpvOpName: s->name_end = i + n; if (in[i + 1] < B) nm_at[in[i + 1]] = i; break;
        case SpvOpMemberName: s->name_end = i + n; break;
        case SpvOpDecorate: if (in[i + 1] < B && in[i + 2] == SpvDecorationDescriptorSet && n > 3) s->dset[in[i + 1]] = in[i + 3]; break;
        }
        if (op == SpvOpDecorate || op == SpvOpMemberDecorate || op == SpvOpDecorationGroup || op == SpvOpGroupDecorate || op == SpvOpGroupMemberDecorate ||
            op == SpvOpDecorateId || op == SpvOpDecorateString || op == SpvOpMemberDecorateString) { if (!s->ann_beg) s->ann_beg = i; s->ann_end = i + n; }
        i += n;
    }
    if (!s->first_fn || !s->mm_pos || !s->ann_end) goto fail;
    // 单个纹素缓冲变量（UniformConstant 指针 → Dim Buffer 图像，或包着它的采样图像）；有名字的才收（反射靠名字配对）
    for (uint32_t id = 1; id < B; id++) {
        if (!is_op(s, id, SpvOpVariable) || s->in[s->pos[id] + 3] != 0 /* UniformConstant */ || !nm_at[id]) continue;
        uint32_t pt = s->rtype[id], t = is_op(s, pt, SpvOpTypePointer) ? s->in[s->pos[pt] + 3] : 0;
        if (!t || t >= B || !img_buf[t]) continue;
        if (nent >= GAL_TBLEAD_MAX) { GRED_ONCE("纹素缓冲前导改写：一支着色器的纹素缓冲超过 %d 个（首例），其余不改、宿主走对齐副本", GAL_TBLEAD_MAX); break; }
        tb_ent *ne = realloc(ent, (size_t)(nent + 1) * sizeof *ent); if (!ne) goto fail; ent = ne;
        ent[nent] = (tb_ent){id, (uint32_t)nent, 0}; ent_of[id] = (uint32_t)nent + 1; nent++;
    }
    if (!nent) goto fail;
    if (!s->tu32) { s->tu32 = s->nb++; s->new_tu32 = 1; W(&s->glob, OPW(SpvOpTypeInt, 4), s->tu32, 32, 0); }
    if (!s->tbool) { s->tbool = s->nb++; s->new_tbool = 1; W(&s->glob, OPW(SpvOpTypeBool, 2), s->tbool); }
    // 每个纹素缓冲一个 gal_tbl_<名>：uint 数组[1] → 结构体（BufferBlock、只读）→ Uniform 指针 → 变量（同集，绑定 GAL_TBLEAD_BINDING0 + k）
    uint32_t arr = s->nb++, st = s->nb++, pst, ptr_u32;
    W(&s->glob, OPW(SpvOpTypeArray, 4), arr, s->tu32, sx_cst(s, 1));
    W(&s->glob, OPW(SpvOpTypeStruct, 3), st, arr);
    pst = sx_ptr(s, SC_Uniform, st); ptr_u32 = sx_ptr(s, SC_Uniform, s->tu32);
    W(&s->deco_add, OPW(SpvOpDecorate, 4), arr, SpvDecorationArrayStride, 4);
    W(&s->deco_add, OPW(SpvOpDecorate, 3), st, SpvDecorationBufferBlock);
    W(&s->deco_add, OPW(SpvOpMemberDecorate, 5), st, 0, SpvDecorationOffset, 0);
    W(&s->deco_add, OPW(SpvOpMemberDecorate, 4), st, 0, SpvDecorationNonWritable);
    for (int k = 0; k < nent; k++) {
        uint32_t var = s->nb++; ent[k].tvar = var;
        W(&s->glob, OPW(SpvOpVariable, 4), pst, var, SC_Uniform);
        W(&s->deco_add, OPW(SpvOpDecorate, 4), var, SpvDecorationDescriptorSet, s->dset[ent[k].var]);
        W(&s->deco_add, OPW(SpvOpDecorate, 4), var, SpvDecorationBinding, GAL_TBLEAD_BINDING0 + (uint32_t)k);
        // 名字 = "gal_tbl_" + 原名（原名是 OpName 的字面量；SPIRV-Cross 参数块成员名 = 变量名）
        const uint32_t *np = in + nm_at[ent[k].var]; uint32_t nn = np[0] >> 16;
        const char *orig = (const char *)(np + 2); size_t ol = strnlen(orig, (size_t)(nn - 2) * 4);
        char buf[512]; int bl = snprintf(buf, sizeof buf, "gal_tbl_%.*s", (int)ol, orig);
        if (bl <= 0 || bl >= (int)sizeof buf) goto fail;
        uint32_t words = (uint32_t)(bl + 4) / 4, tmp[130] = {0}; memcpy(tmp, buf, (size_t)bl);
        uint32_t hdr[2] = { OPW(SpvOpName, 2 + words), var }; wb_put(&s->names, hdr, 2); wb_put(&s->names, tmp, words);
    }
    // ---- 函数体：载入值认表项，取数 / 读写 / 纹素指针挪下标，取宽度减前导 ----
    for (uint32_t i = s->first_fn; i < nw; ) {
        uint32_t n = in[i] >> 16, op = in[i] & 0xffff; const uint32_t *p = in + i;
        if (op == SpvOpLoad && n >= 4 && p[3] < B && ent_of[p[3]] && p[2] < B) ent_of[p[2]] = ent_of[p[3]];   // OpLoad 结果类型 结果 指针
        if ((op == SpvOpCopyObject || op == SpvOpImage) && n >= 4 && p[3] < B && ent_of[p[3]] && p[2] < B) ent_of[p[2]] = ent_of[p[3]];
        int ci = 0, ii = 0;   // 坐标、图像操作数所在字号
        if (op == SpvOpImageFetch || op == SpvOpImageRead) { ii = 3; ci = 4; }
        else if (op == SpvOpImageWrite) { ii = 1; ci = 2; }
        else if (op == SpvOpImageTexelPointer) { ii = 3; ci = 4; }
        if (ci && n > (uint32_t)ci && p[ii] < B && ent_of[p[ii]]) {
            const tb_ent *e = &ent[ent_of[p[ii]] - 1];
            uint32_t lead = tb_lead(s, &body, e, ptr_u32), c2 = tb_move(s, &body, p[ci], lead);
            if (c2) {
                uint32_t at = body.n; wb_put(&body, p, n); body.w[at + ci] = c2; (*nmoved)++;
                i += n; continue;
            }
            GRED_ONCE("纹素缓冲前导改写：坐标不是 32 位整数标量（首例），这一处不挪");
        }
        if (op == SpvOpImageQuerySize && n >= 4 && p[3] < B && ent_of[p[3]] && is_op(s, p[1], SpvOpTypeInt) && s->in[s->pos[p[1]] + 2] == 32) {
            const tb_ent *e = &ent[ent_of[p[3]] - 1];
            uint32_t r0 = s->nb++, at = body.n; wb_put(&body, p, n); body.w[at + 2] = r0;
            uint32_t lead = tb_lead(s, &body, e, ptr_u32), lt = lead;
            if (p[1] != s->tu32) { lt = s->nb++; W(&body, OPW(SpvOpBitcast, 4), p[1], lt, lead); }
            W(&body, OPW(SpvOpISub, 5), p[1], p[2], r0, lt); (*nmoved)++;
            i += n; continue;
        }
        wb_put(&body, p, n); i += n;
    }
    if (!*nmoved) goto fail;
    // ---- 拼模块（同 spv_bounds）：头 + 原名字段 + 新名 + 原注解 + 新修饰 + 原类型段 + 新全局 + 函数体 ----
    {
        wbuf o = {0}; wb_put(&o, in, 5);
        uint32_t name_at = s->name_end ? s->name_end : s->ann_beg;
        for (uint32_t i = 5; i < s->first_fn; ) {
            uint32_t n = in[i] >> 16;
            if (i == name_at) wb_put(&o, s->names.w, s->names.n);
            wb_put(&o, in + i, n); i += n;
            if (i == s->ann_end) wb_put(&o, s->deco_add.w, s->deco_add.n);
        }
        wb_put(&o, s->glob.w, s->glob.n); wb_put(&o, body.w, body.n);
        if (g_wb_bad || !o.w) { free(o.w); goto fail; }
        o.w[3] = s->nb; out = o.w; *onw = o.n;
    }
fail:
    if (!out) *nmoved = 0;
    free(s->pos); free(s->rtype); free(s->dset); free(s->ptrs); free(nm_at); free(img_buf); free(ent_of); free(ent);
    free(s->glob.w); free(s->deco_add.w); free(s->names.w); free(body.w);
    return out;
}

// 参照后端（galplay --ref 的 Ryujinx Vulkan@MoltenVK）用：只加循环上限（与我方同一套工作量 / 整次派发口径），不加越界钳位（不改正常语义）、不接计数收尾。
// 10-21 08:02 / 08:20 两次整卡重置：参照端跑八方2 选项页的坏常量循环，没有上限，一直跑到系统杀卡。返回 malloc 的新码（nxgal_spv_free 放），无循环或失败返回 NULL
NXGAL_API uint32_t *nxgal_spv_loop_guard(const uint32_t *in, uint32_t nw, uint32_t *onw) {
    uint32_t s[GAL_SPVX_NSTAT] = {0}, model = UINT32_MAX, lv = 0;
    *onw = 0;
    if (!in || nw < 5 || in[0] != SpvMagicNumber) return NULL;
    for (uint32_t i = 5; i < nw; ) { uint32_t n = in[i] >> 16; if (!n) break; if ((in[i] & 0xffff) == SpvOpEntryPoint) { model = in[i + 1]; break; } i += n; }
    return spv_loop_guard(in, nw, model == SpvExecutionModelGLCompute ? GAL_LOOP_CAP_CS : GAL_LOOP_CAP_GFX, model == SpvExecutionModelGLCompute, onw, s, &lv);
}
NXGAL_API void nxgal_spv_free(void *p) { free(p); }
// 直连三条着色器链（S2A.Dsh 出库 / 设备兜底现编 / 曲面）的加固（审计 #1204 T1）：越界钳位（读只钳下标、越界写 / 原子不落），不加循环上限（见 spv_harden）。
//   常量缓冲界长表按 NVN 槽索引、名 gal_ubo_len；存储缓冲取长度走 SPIRV-Cross 的 spvBufferSizeConstants（按参数块成员 [[id]]）——两张表都由 nvn_mtl.m 按当前 NVN 绑定逐绘制填（11-02 重进：首版宿主不认这两种成员，撤回过）。
//   返回 malloc 的新码（nxgal_spv_free 放）；不用改或改写失败（本函数内报红）返回 NULL，调用方用原 SPIR-V
static uint32_t *spv_harden(const uint32_t *in, uint32_t nw, uint32_t *onw, uint32_t st[GAL_SPVX_NSTAT], int direct);
NXGAL_API uint32_t *nxgal_spv_harden(const uint32_t *in, uint32_t nw, uint32_t *onw) {
    *onw = 0;
    if (!in || nw < 5 || in[0] != SpvMagicNumber) return NULL;
    return spv_harden(in, nw, onw, NULL, 1);
}
uint32_t *gal_spv_harden(const uint32_t *in, uint32_t nw, uint32_t *onw, uint32_t st[GAL_SPVX_NSTAT]) { return spv_harden(in, nw, onw, st, 0); }
// direct：直连口径（界长表按 NVN 槽，见文件头 ①），且不加循环上限（②）——11-01 维护者定：上限挡编译器优化，异度3 / 怪猎重片元 GPU +8% ~ +12%，留普查后另做。通用链照旧加
static uint32_t *spv_harden(const uint32_t *in, uint32_t nw, uint32_t *onw, uint32_t st[GAL_SPVX_NSTAT], int direct) {
    uint32_t s[GAL_SPVX_NSTAT] = {0}, n1 = 0, n2 = 0, n3 = 0, model = UINT32_MAX, vars[GAL_OOB_NVAR] = {0};
    for (uint32_t i = 5; i < nw; ) { uint32_t n = in[i] >> 16; if (!n) break; if ((in[i] & 0xffff) == SpvOpEntryPoint) { model = in[i + 1]; break; } i += n; }
    uint32_t *a = spv_bounds(in, nw, &n1, s, vars, direct);
    const uint32_t *src = a ? a : in; uint32_t sn = a ? n1 : nw;
    uint32_t *b = direct ? NULL : spv_loop_guard(src, sn, model == SpvExecutionModelGLCompute ? GAL_LOOP_CAP_CS : GAL_LOOP_CAP_GFX, model == SpvExecutionModelGLCompute, &n2, s, &vars[GAL_OOB_LOOP]);
    if (b) { free(a); a = b; n1 = n2; src = a; sn = n1; }
    if (direct) {   // #798 纹素缓冲前导（见 spv_tbias）：越界改写之后再挪下标
        uint32_t nt = 0, moved = 0, *t = spv_tbias(src, sn, &nt, &moved);
        if (t) { free(a); a = t; n1 = nt; src = a; sn = n1; }
    }
    uint32_t *c = gal_spvx_counting() ? spv_count_flush(src, sn, vars, &n3) : NULL;
    for (int k = 0; k < GAL_SPVX_NSTAT; k++) { g_sx_tot[k] += s[k]; if (st) st[k] += s[k]; }
    if (c) { free(a); *onw = n3; return c; }
    if (gal_spvx_counting() && a && (vars[0] | vars[1] | vars[2] | vars[3] | vars[4] | vars[GAL_OOB_LOOP])) { GRED_ONCE("着色器越界改写：计数收尾没插上（首例），本支越界 / 到上限不计数"); }
    *onw = a ? n1 : 0; return a;
}
