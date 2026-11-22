// rfx_gen：S2RF 样例生成器。产出 7 对 .in/.exp（README §3 的样例表），全部原创合成数据，
// 不含任何游戏数据；期望流手写在本文件里，是「契约 + FORMAT.md §6 钉法」的独立预测，
// 不经由任何被测实现产出。
//
// 用法：rfx_gen <输出目录>
//
// 输入侧 OP 流直接复用仓库的 nvn_obj.h（op_hdr / p_* 载荷 / set_rt_* 助手），与 hle_nvn.c
// 录出的记录同构；期望侧按 FORMAT.md 的规范化载荷编码，枚举值取 nvn_backend.h / nvn_refl.h 原值。
#include "rfx.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvn_backend.h"   // 下沿契约枚举（NVN_GPU_*）+ nvn_obj.h / nvn_refl.h 一套

// ---------- 字节流小工具 ----------

typedef struct { uint8_t *p; uint32_t len, cap; int err; } bb;
static void bres(bb *b, uint32_t n) {   // 先备容量再写：写半途中不允许 realloc 让已发指针失效
    if (b->len + n <= b->cap) return;
    uint32_t c = (b->len + n) * 2 + 64;
    uint8_t *q = realloc(b->p, c);
    if (!q) { b->err = 1; return; }
    b->p = q; b->cap = c;
}
static void bx(bb *b, const void *p, uint32_t n) {
    if (b->err) return;
    bres(b, n);
    if (b->err) return;
    memcpy(b->p + b->len, p, n); b->len += n;
}
static void b8(bb *b, uint8_t v) { bx(b, &v, 1); }
static void b16(bb *b, uint16_t v) { bx(b, &v, 2); }
static void b32(bb *b, uint32_t v) { bx(b, &v, 4); }
static void b64(bb *b, uint64_t v) { bx(b, &v, 8); }
static void bf(bb *b, float v) { bx(b, &v, 4); }
static void bd(bb *b, double v) { bx(b, &v, 8); }
static void bz(bb *b, uint32_t n) { uint8_t z[8] = {0}; while (n >= 8) { bx(b, z, 8); n -= 8; } if (n) bx(b, z, n); }

// ---------- 记录缓冲（构建期攒，收尾时按序落盘；kind：0 EXP / 1 CHK / 2 ASSUME） ----------

typedef struct { uint32_t id; uint64_t ret; uint8_t kind; bb p; } rec;
static rec in_calls[256]; static int n_calls;
static rec in_res[64];   static int n_res;
static char res_names[64][32];
static rec exps[512];    static int n_exp;

static void ICALL(uint32_t fn, uint64_t ret, bb *b) {
    in_calls[n_calls++] = (rec){fn, ret, 0, *b}; *b = (bb){0};
}
static void IRES(uint32_t kind, const char *name, bb *b) {
    snprintf(res_names[n_res], sizeof res_names[0], "%s", name);
    in_res[n_res++] = (rec){kind, 0, 0, *b}; *b = (bb){0};
}
static void EXP(uint32_t fn, bb *b) { exps[n_exp++] = (rec){fn, 0, 0, *b}; *b = (bb){0}; }
static void CHK_(uint32_t ck, bb *b) { exps[n_exp++] = (rec){ck, 0, 1, *b}; *b = (bb){0}; }

// ---------- 客户机内存像（guest image；每样例一份，段址固定） ----------
//
// 三段，全部落在 REGION/DATA 覆盖内，指针一律是 guest 地址：
//   OBJ  GBASE+0x00000  0x8000   主机侧对象（tex_t / pool_t / dpool_t / prog_t / 合成 blob 副本）
//   CMD  GBASE+0x08000  0x8000   命令内存（OP 流，从 +0 开始）
//   DATA GBASE+0x10000  样例定   GPU 可见数据（顶点 / 贴图存储 / SSBO / 缓冲）
#define GBASE 0x10000000ull
static uint8_t gmem[1 << 21];
static uint64_t opos;                     // OBJ 段内游标
typedef struct { uint64_t a, n; } gseg_t;
static gseg_t segs[8]; static int n_segs;
static uint64_t oalloc(uint64_t n, uint64_t al) {
    opos = (opos + al - 1) & ~(al - 1);
    uint64_t a = GBASE + opos;
    opos += n;
    if (opos > 0x8000) { fprintf(stderr, "OBJ 段装不下\n"); exit(2); }
    return a;
}
static uint8_t *gptr(uint64_t a) { return gmem + (a - GBASE); }

// ---------- OP 流（与 hle_nvn.c REC 同构：op_hdr{op,size} + 8 对齐载荷） ----------

static bb ops_;
static void *op_rec(uint32_t op, uint32_t payload) {
    uint32_t sz = 8 + ((payload + 7) & ~7u);
    bres(&ops_, sz);
    op_hdr h = {op, sz};
    bx(&ops_, &h, 8);
    uint8_t *p = ops_.p + ops_.len;
    bz(&ops_, sz - 8);
    return p;
}

// ---------- 构建期游标 ----------

static uint64_t OBJ_, CMD_, DATA_;       // 三段基址
static uint32_t e_hid;                   // 期望侧句柄计数（attach / cmd / buf / tex … 一个序列）
static uint32_t e_surf;                  // 窗口面句柄（0 = 无窗口）
static uint64_t g_fence;                 // 已提交数（signal = 栅栏值，从 1 起）
static uint32_t g_hobj, g_hcmd, g_hdata; // 三个池的包装 hid（in_pools 按序发）

// ---------- 客户机对象 ----------

static uint64_t g_poolobj(uint64_t mem, uint64_t size) {   // pool_t（dpool / tex_t.pool 引用）
    uint64_t a = oalloc(0x30, 8);
    pool_t *p = (pool_t *)gptr(a);
    memset(p, 0, sizeof *p);
    p->magic = MAGIC('P', 'O', 'O', 'L'); p->mem = (uint8_t *)(uintptr_t)mem; p->size = size;
    return a;
}
// serial 由前端 nvn_new_serial 单调给；样例按 tex_init 调用序 1,2,3…
static uint64_t g_tex(uint64_t serial, int target, int fmt, int flags, int w, int h,
                      uint64_t pool_obj, uint64_t off) {
    uint64_t a = oalloc(0x80, 8);
    tex_t *t = (tex_t *)gptr(a);
    memset(t, 0, sizeof *t);
    t->magic = MAGIC('T', 'E', 'X', 0);
    t->d = (nvn_texdesc){target, fmt, flags, 1, (uint32_t)w, (uint32_t)h, 1, 1, 0, 0};
    t->mem = pool_obj ? (uint8_t *)(uintptr_t)(DATA_ + off) : NULL;
    t->pool = (pool_t *)(uintptr_t)pool_obj; t->off = (int64_t)off;
    t->serial = serial;
    return a;
}
static uint64_t g_dpool(uint64_t pool_obj, int64_t off, int32_t n) {
    uint64_t a = oalloc(sizeof(dpool_t), 8);
    *(dpool_t *)gptr(a) = (dpool_t){(const pool_t *)(uintptr_t)pool_obj, off, n};
    return a;
}
static uint64_t g_blob(const void *p, uint64_t n) {
    uint64_t a = oalloc((n + 7) & ~7ull, 8);
    memcpy(gptr(a), p, (size_t)n);
    return a;
}
// prog_t：sd[i].data/control 指向 OBJ 段里的合成 blob 副本；键与产物在 RES 里配对
static uint64_t g_prog(uint64_t serial, const uint8_t stage_of[6], const uint64_t code_addr[6]) {
    uint64_t a = oalloc(sizeof(prog_t), 8);
    prog_t *p = (prog_t *)gptr(a);
    memset(p, 0, sizeof *p);
    p->magic = MAGIC('P', 'R', 'O', 'G'); p->serial = serial;
    for (int i = 0; i < 6; i++) {
        if (stage_of[i] == 0xff) continue;
        p->nstage++;
        p->sd[i].data = code_addr[i];
        p->sd[i].control = (const void *)(uintptr_t)code_addr[i];
    }
    return a;
}

// ---------- 输入侧 CALL / RES 助手 ----------

static void c_u32(uint32_t fn, uint32_t a) { bb b = {0}; b32(&b, a); ICALL(fn, 0, &b); }
static void c_u64(uint32_t fn, uint64_t a) { bb b = {0}; b64(&b, a); ICALL(fn, 0, &b); }
static void c_pool_add(uint64_t a, uint64_t n) { bb b = {0}; b64(&b, a); b64(&b, n); ICALL(RFX_BE_POOL_ADD, 0, &b); }
static void c_none(uint32_t fn, uint64_t ret) { bb b = {0}; ICALL(fn, ret, &b); }
static void c_wait(uint64_t f_, uint64_t tmo, uint64_t ret) {
    bb b = {0}; b64(&b, f_); b64(&b, tmo); ICALL(RFX_BE_WAIT, ret, &b);
}
static void c_sub_index(const uint64_t *h, uint32_t n) {
    bb b = {0}; b32(&b, n); if (n) bx(&b, h, n * 8); ICALL(RFX_BE_SUB_INDEX, 0, &b);
}
static void c_reg_tex(int32_t id, uint64_t tex) {
    bb b = {0}; b32(&b, (uint32_t)id); b64(&b, tex); b8(&b, 0); ICALL(RFX_BE_REG_TEX, 0, &b);
}
static void c_reg_samp(int32_t id, const samp_par *p) {
    bb b = {0}; b32(&b, (uint32_t)id); bx(&b, p, sizeof *p); ICALL(RFX_BE_REG_SAMP, 0, &b);
}
static void c_set_tex_pool_n(int32_t n) {
    bb b = {0}; b32(&b, (uint32_t)n); ICALL(RFX_BE_SET_TEX_POOL_N, 0, &b);
}
static void c_present(uint64_t tex, double period, uint64_t ticket) {
    bb b = {0}; b64(&b, tex); bd(&b, period); b8(&b, 0); ICALL(RFX_BE_PRESENT, ticket, &b);
}
static void res_surface(uint32_t w, uint32_t h, uint32_t fmt, uint32_t nimg) {
    bb b = {0}; b32(&b, w); b32(&b, h); b32(&b, fmt); b32(&b, nimg);
    IRES(RFX_RES_SURFACE, "win", &b);
}
static void res_prog(uint64_t serial, const uint8_t keys[6][8], const uint8_t stage_of[6]) {
    bb b = {0};
    b64(&b, serial); bx(&b, keys, 48); b8(&b, 0x3f); bx(&b, stage_of, 6);
    IRES(RFX_RES_PROG, "prog", &b);
}
// RES shader 与 EXP shader_load 的 layout 段同构（FORMAT.md §4.4）
static void lay_head(bb *b, uint32_t nent, uint32_t push_off, uint32_t push_bytes, uint32_t sup, const char *idsrc) {
    b32(b, nent); b32(b, push_off); b32(b, push_bytes); b32(b, sup);
    uint8_t id[16] = {0}; bx(b, id, 16);
    b16(b, (uint16_t)strlen(idsrc)); bx(b, idsrc, (uint32_t)strlen(idsrc));
}
static void lay_ent(bb *b, uint8_t set, uint8_t cls, uint8_t acc, uint8_t sk,
                    uint16_t binding, uint16_t sreg, uint16_t cnt, uint16_t aid, uint32_t st) {
    b8(b, set); b8(b, cls); b8(b, acc); b8(b, sk);
    b16(b, binding); b16(b, sreg); b16(b, cnt); b16(b, aid); b32(b, st);
}
static void res_shader(uint8_t stage, const uint8_t key[8], const char *entry,
                       const void *blob, uint32_t blobn, const bb *layout) {
    bb b = {0};
    b8(&b, stage); bx(&b, key, 8); b8(&b, 3);   // kind = SPIRV
    b16(&b, (uint16_t)strlen(entry)); bx(&b, entry, (uint32_t)strlen(entry));
    bx(&b, layout->p, layout->len);
    b64(&b, blobn); bx(&b, blob, blobn);
    IRES(RFX_RES_SHADER, "shader", &b);
}

// ---------- 状态块（样例间共用；取值在 FORMAT.md §7 列出） ----------

typedef struct { blend_st blend; color_st color; chmask_st chmask; ms_st ms; poly_st poly; ds_st ds; } states;
static states st_draw(int depth_on) {
    states s;
    memset(&s, 0, sizeof s);
    s.blend = (blend_st){.target = 0, .src_rgb = 1, .dst_rgb = 0, .src_a = 1, .dst_a = 0, .eq_rgb = 1, .eq_a = 1};
    s.color = (color_st){.blend_en = 0, .logic_op = 0, .alpha_func = 7};
    s.chmask = (chmask_st){.mask = 0xffffffffu};
    s.ms = (ms_st){.samples = 1};
    s.poly = (poly_st){.cull = 0, .front = 0, .mode = 0, .offset_en = 0};
    s.ds = depth_on ? (ds_st){.dt = 1, .dw = 1, .df = 3} : (ds_st){.dt = 0, .dw = 1, .df = 7};
    return s;
}
static void fx_states(const states *s);
static const samp_par SAMP_LINEAR = {.minf = 1, .magf = 1, .ws = 1, .wt = 1, .wr = 1,
                                     .lod_min = 0, .lod_max = 12, .lod_bias = 0, .aniso = 0,
                                     .border = {0, 0, 0, 0}, .lod_snap = 0};

// ---------- 期望侧 EXP / CHK 助手 ----------

static void e_assume(void) {
    bb b = {0};
    // REF 能力档（FORMAT.md §6.1）：Metal 抽离线的主靶——只置 CAP_HOST_IMPORT
    // （池页零拷贝包装），其余位全 0（无 GPL / 动态状态 / 上屏时刻 / GPU 解排布）。
    b32(&b, 10); b32(&b, 0x00401000); b32(&b, 0); b32(&b, 0); b32(&b, 0);   // api / api_version / family / vendor / device
    b32(&b, NVN_GPU_CAP_HOST_IMPORT);   // caps
    b32(&b, 8); b32(&b, 16); b32(&b, 16384); b32(&b, 4); b32(&b, 16);   // color_att / vstreams / tex_dim / samples / viewports
    b32(&b, 4096);        // max_push_bytes
    b32(&b, 16); b32(&b, 16);          // min_ubo / ssbo align
    b64(&b, 65536); b64(&b, 1u << 27); // max_ubo / ssbo range
    b64(&b, 1ull << 30);               // max_buf_bytes
    for (int i = 0; i < 10; i++) b32(&b, 32);   // max_stage_res
    b32(&b, 4);           // max_sets
    b32(&b, 0x3f); b32(&b, 0);          // storage / atomic stages
    b32(&b, 60);          // display_max_hz
    exps[n_exp++] = (rec){RFX_REC_ASSUME, 0, 2, b};
}
static void e_rc(uint32_t fn, int32_t rc) { bb b = {0}; b32(&b, (uint32_t)rc); EXP(fn, &b); }
static void e_attach(uint32_t hid) { bb b = {0}; b32(&b, 0); b32(&b, hid); EXP(RFX_GPU_SURFACE_ATTACH, &b); }
static void e_wrap_ok(uint64_t addr, uint64_t bytes, uint32_t hid) {   // pool_add 同步包装（CAP_HOST_IMPORT）
    bb b = {0}; b64(&b, addr); b64(&b, bytes); b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_BUF_WRAP, &b);
}
static void e_cmd_begin(uint32_t hid) {
    bb b = {0}; b32(&b, 0); b8(&b, 0); b16(&b, 0); b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_CMD_BEGIN, &b);
}
static void e_commit(uint32_t cmd, uint64_t signal) {
    bb b = {0}; b32(&b, cmd); b64(&b, signal); b32(&b, 0);
    EXP(RFX_GPU_CMD_COMMIT, &b);
}
static void k_done(uint64_t signal) {
    bb b = {0}; b64(&b, signal); b8(&b, 0); b32(&b, 0); b8(&b, 0);   // DONE_OK / rc=OK / TIME_NONE
    CHK_(RFX_CHK_DONE, &b);
}
static void k_fence(uint64_t v) { bb b = {0}; b64(&b, v); CHK_(RFX_CHK_FENCE_DONE, &b); }
static void e_fence_wait(uint64_t v, uint64_t tmo) {
    bb b = {0}; b64(&b, v); b64(&b, tmo); b32(&b, 0); EXP(RFX_GPU_FENCE_WAIT, &b);
}
static void e_fill(uint32_t cmd, uint32_t dst, uint64_t off, uint64_t n, uint32_t v) {
    bb b = {0}; b32(&b, cmd); b32(&b, dst); b64(&b, off); b64(&b, n); b32(&b, v);
    EXP(RFX_GPU_FILL_BUF, &b);
}
static void e_copy(uint32_t cmd, uint32_t s, uint64_t so, uint32_t d, uint64_t dof, uint64_t n) {
    bb b = {0}; b32(&b, cmd); b32(&b, s); b64(&b, so); b32(&b, d); b64(&b, dof); b64(&b, n);
    EXP(RFX_GPU_COPY_BUF, &b);
}
static void e_tex(const nvn_texdesc *d, uint32_t usage, uint32_t hid) {
    bb b = {0};
    bx(&b, d, sizeof *d);                          // nvn_texdesc 40B 全字段
    b32(&b, usage); b32(&b, 0); b32(&b, 0);        // usage / host_w / host_h
    b16(&b, 0); b8(&b, 0); b8(&b, 0);              // swz 恒等 / rsv[2] 恒 0
    b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_TEX_CREATE, &b);
}
static void e_view(uint32_t tex, const view_t *v, uint32_t hid) {
    bb b = {0};
    b32(&b, tex); b8(&b, v != NULL);
    if (v) { bx(&b, v, 14); b16(&b, 0); } else bz(&b, 16);   // view_t 16B，末 2B _rsv 归 0
    b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_VIEW_CREATE, &b);
}
static void e_samp(const samp_par *p, uint32_t hid) {
    bb b = {0}; bx(&b, p, sizeof *p); b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_SAMP_CREATE, &b);
}
static void e_upload(uint32_t cmd, uint32_t tex, const int32_t reg[6],
                     uint32_t sbuf, uint64_t soff, uint64_t rowb, uint64_t imgb,
                     const void *src, uint64_t n) {
    bb b = {0}; b32(&b, cmd); b32(&b, tex); b32(&b, 0); b32(&b, 0);
    bx(&b, reg, 24); b32(&b, sbuf); b64(&b, soff);
    b64(&b, rowb); b64(&b, imgb); b64(&b, n); b32(&b, rfx_crc32(src, (size_t)n));
    EXP(RFX_GPU_TEX_UPLOAD, &b);
}
static void e_shader(uint8_t stage, const uint8_t key[8], const char *entry,
                     const void *blob, uint64_t blobn, const bb *layout, uint32_t hid) {
    bb b = {0};
    b8(&b, stage); bx(&b, key, 8); b8(&b, 3);
    b16(&b, (uint16_t)strlen(entry)); bx(&b, entry, (uint32_t)strlen(entry));
    b64(&b, blobn); b32(&b, rfx_crc32(blob, (size_t)blobn));
    bx(&b, layout->p, layout->len);
    b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_SHADER_LOAD, &b);
}
static void e_pass(uint32_t cmd, uint32_t ncolor,
                   const uint32_t views[8], const uint8_t load[8], const float clears[8][4],
                   uint32_t dview, uint8_t dload, float cdepth, uint32_t w, uint32_t h) {
    bb b = {0};
    b32(&b, cmd); b32(&b, ncolor);
    for (int i = 0; i < 8; i++) {   // 每附件 {view, resolve, load, store, rsv, clear.f[4]}
        b32(&b, views[i]); b32(&b, 0); b8(&b, load[i]); b8(&b, 0); b16(&b, 0);
        for (int k = 0; k < 4; k++) bf(&b, clears[i][k]);
    }
    for (int a = 0; a < 2; a++) {   // depth att, stencil att
        b32(&b, a == 0 ? dview : 0); b32(&b, 0); b8(&b, a == 0 ? dload : 0); b8(&b, 0); b16(&b, 0);
        bf(&b, a == 0 ? cdepth : 0); bf(&b, 0); bf(&b, 0); bf(&b, 0);
    }
    bf(&b, cdepth); b32(&b, 0);       // clear_depth / clear_stencil
    b32(&b, w); b32(&b, h); b32(&b, 1);
    b8(&b, 0); b8(&b, 0); b16(&b, 0); // occlusion / fb_fetch / rsv
    EXP(RFX_GPU_PASS_BEGIN, &b);
}
static void e_1c(uint32_t fn, uint32_t cmd) { bb b = {0}; b32(&b, cmd); EXP(fn, &b); }
static void e_2c(uint32_t fn, uint32_t cmd, uint32_t a) { bb b = {0}; b32(&b, cmd); b32(&b, a); EXP(fn, &b); }
static void e_vbuf(uint32_t cmd, uint32_t stream, uint32_t b_, uint64_t off) {
    bb b = {0}; b32(&b, cmd); b32(&b, stream); b32(&b, b_); b64(&b, off);
    EXP(RFX_GPU_SET_VBUF, &b);
}
static void e_draw(uint32_t cmd, uint32_t prim, uint32_t count, uint32_t first, uint32_t inst) {
    bb b = {0};
    b32(&b, cmd); b32(&b, prim); b32(&b, count); b32(&b, first); b32(&b, inst); b32(&b, 0);
    b32(&b, 0); b64(&b, 0); b32(&b, 0); b32(&b, 0);   // ibuf / ioff / itype / base_vertex
    b32(&b, 0); b64(&b, 0); b32(&b, 0); b64(&b, 0);   // ind / ind_off / cnt / cnt_off
    b32(&b, 0); b32(&b, 0);                           // max_draws / stride
    EXP(RFX_GPU_DRAW, &b);
}
static void e_dispatch(uint32_t cmd, uint32_t cp, uint32_t x, uint32_t y, uint32_t z) {
    bb b = {0}; b32(&b, cmd); b32(&b, cp); b32(&b, x); b32(&b, y); b32(&b, z); b32(&b, 0); b64(&b, 0);
    EXP(RFX_GPU_DISPATCH, &b);
}
static void e_dyn(uint32_t cmd, float w, float h, const ds_st *ds, const poly_st *poly) {
    bb b = {0};
    b32(&b, cmd);
    b32(&b, 1);                                  // nvp（FORMAT.md §4.7 的字段序）
    float vp[16][6]; memset(vp, 0, sizeof vp);
    vp[0][2] = w; vp[0][3] = h; vp[0][5] = 1;
    bx(&b, vp, sizeof vp);
    bz(&b, 64);                                  // vp_sw
    { int32_t sc[4] = {0, 0, (int32_t)w, (int32_t)h}; bx(&b, sc, 16); }
    b8(&b, 1); b8(&b, 1); b8(&b, 0); b8(&b, 0);  // has_sc / origin_ll / depth_clamp / rsv
    bx(&b, (float[3]){0, 0, 0}, 12);             // p_poly_offset
    b32(&b, 0xff); b32(&b, 0xff); b32(&b, 0xff); b32(&b, 0xff);   // st_vmask[2] / st_wmask[2]
    b32(&b, 0); b32(&b, 0);                      // st_ref[2]
    bf(&b, 0); bf(&b, 0); bf(&b, 0); bf(&b, 0);  // blend_color
    bx(&b, ds, sizeof *ds); bx(&b, poly, sizeof *poly);
    EXP(RFX_GPU_SET_DYN, &b);
}
static void e_bind_ts(uint32_t cmd, uint8_t stage, uint16_t ent, uint32_t elem, uint32_t view, uint32_t samp) {
    bb b = {0};
    b32(&b, cmd); b8(&b, stage); b32(&b, 1);
    b16(&b, ent); b8(&b, NVN_GPU_RES_TEX_SAMP); b8(&b, 0); b32(&b, elem);
    b32(&b, view); b32(&b, samp);
    EXP(RFX_GPU_BIND, &b);
}
static void e_bind_ssbo(uint32_t cmd, uint8_t stage, uint16_t ent, uint32_t elem,
                        uint32_t b_, uint64_t off, uint64_t len) {
    bb b = {0};
    b32(&b, cmd); b8(&b, stage); b32(&b, 1);
    b16(&b, ent); b8(&b, NVN_GPU_RES_SSBO); b8(&b, 0); b32(&b, elem);
    b32(&b, b_); b64(&b, off); b64(&b, len);
    EXP(RFX_GPU_BIND, &b);
}
static void e_acquire(uint32_t surf, uint32_t view, uint32_t w, uint32_t h, uint32_t fmt,
                      uint64_t gen, uint64_t token) {
    bb b = {0};
    b32(&b, surf); b64(&b, 0); b8(&b, 0); b32(&b, 0);
    b32(&b, view); b32(&b, w); b32(&b, h); b32(&b, fmt); b64(&b, gen); b64(&b, token);
    EXP(RFX_GPU_DRAWABLE_ACQUIRE, &b);
}
static void e_present(uint32_t surf, uint64_t gen, uint32_t src, uint32_t w, uint32_t h, uint64_t ticket) {
    bb b = {0};
    b32(&b, surf); b64(&b, gen); b32(&b, src);
    { int32_t r[4] = {0, 0, (int32_t)w, (int32_t)h}; bx(&b, r, 16); bx(&b, r, 16); }   // crop / dst
    b32(&b, 0); bd(&b, 0); b64(&b, ticket); b32(&b, 0);
    EXP(RFX_GPU_PRESENT, &b);
}
static void k_presented(uint64_t ticket) {
    bb b = {0}; b64(&b, ticket); b32(&b, 2); bd(&b, 0);   // SHOWN_UNKNOWN, at=0
    CHK_(RFX_CHK_PRESENTED, &b);
}
static void k_buf(uint32_t hid, uint64_t off, const void *p, uint64_t n) {
    bb b = {0}; b32(&b, hid); b64(&b, off); b64(&b, n); bx(&b, p, (uint32_t)n);
    CHK_(RFX_CHK_BUF, &b);
}
static void e_pipe(uint32_t vs, uint32_t fs, uint32_t ncfmt, uint32_t cfmt, uint32_t dfmt, uint32_t prim,
                   const states *st, const uint32_t *vattr, uint32_t nva,
                   const vs_st *vstream, uint32_t nvs, uint32_t hid) {
    bb b = {0};
    for (int i = 0; i < 5; i++) b32(&b, i == 0 ? vs : i == 1 ? fs : 0), b32(&b, 0);   // sh / nspec
    for (uint32_t i = 0; i < 8; i++) b32(&b, i < ncfmt ? cfmt : 0);
    b32(&b, dfmt); b32(&b, 0);                   // dfmt / sfmt
    b32(&b, 1);                                  // samples
    { uint8_t lm[8]; for (int i = 0; i < 8; i++) lm[i] = (uint8_t)i; bx(&b, lm, 8); }
    b32(&b, prim); b32(&b, 0); b8(&b, 0); bz(&b, 3);          // prim / patch_size / prim_restart / rsv
    for (int i = 0; i < 8; i++) bx(&b, &st->blend, sizeof st->blend);
    bx(&b, &st->color, sizeof st->color);
    bx(&b, &st->chmask, sizeof st->chmask);
    bx(&b, &st->ms, sizeof st->ms); b16(&b, 0);               // ms 10B + rsv
    for (uint32_t i = 0; i < 16; i++) b32(&b, i < nva ? vattr[i] : 0);
    for (uint32_t i = 0; i < 16; i++) bx(&b, i < nvs ? &vstream[i] : &(vs_st){0}, sizeof(vs_st));
    bx(&b, &st->ds, sizeof st->ds); bx(&b, &st->poly, sizeof st->poly);
    b8(&b, 0); b8(&b, 0); b16(&b, 0);            // rast_discard / clip_neg1 / rsv
    b8(&b, 0);                                    // mode = SYNC
    b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_PIPE_GET, &b);
}
static void e_cpipe(uint32_t sh, uint32_t hid) {
    bb b = {0};
    b32(&b, sh); b32(&b, 0);                     // stage_desc{sh, nspec=0}
    b8(&b, 0); b32(&b, 0); b32(&b, hid);
    EXP(RFX_GPU_CPIPE_GET, &b);
}

// ---------- OP 记录写出 ----------

static void fx_set_rt(uint32_t cmask, const uint64_t *color, uint64_t depth) {
    p_set_rt r = {0};
    r.n = (int32_t)__builtin_popcount(cmask);
    for (int i = 0; i < 8; i++) if (cmask >> i & 1) r.color[i] = (const tex_t *)(uintptr_t)color[i];
    if (depth) r.depth = (const tex_t *)(uintptr_t)depth;
    p_set_rt_c h = set_rt_hdr(&r);
    uint8_t *a = op_rec(OP_SET_RT, (uint32_t)set_rt_payload(&h));
    uint64_t aoff = (uint64_t)(a - ops_.p) + (CMD_ - GBASE);   // 载荷的 guest 地址 - GBASE
    p_set_rt_c *w = set_rt_put(a, &r);
    // 快照搬到记录内，指针改成快照的 guest 地址（录制器对「指针指向记录内快照」的钉法）
    const tex_t **pt = (const tex_t **)(w + 1);
    view_t *pv = (view_t *)(pt + set_rt_ntex(w));
    tex_t *snap = (tex_t *)((uint8_t *)pv + sizeof(view_t) * set_rt_nview(w));
    uint8_t *base = a;
    uint32_t k = 0;
    for (int i = 0; i < 8; i++) {
        if (!(w->cmask >> i & 1)) continue;
        *snap = *(const tex_t *)gptr(color[i]);
        pt[k++] = (const tex_t *)(uintptr_t)(aoff + ((uint8_t *)snap - base));
    }
    if (w->dflags & SET_RT_DEPTH) {
        *snap = *(const tex_t *)gptr(depth);
        pt[k] = (const tex_t *)(uintptr_t)(aoff + ((uint8_t *)snap - base));
    }
}
static void fx_clear_color(int idx, float r, float g, float b, float a) {
    *(p_clear_color *)op_rec(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){idx, 0xf, {r, g, b, a}};
}
static void fx_clear_ds(float d) {
    *(p_clear_ds *)op_rec(OP_CLEAR_DS, sizeof(p_clear_ds)) = (p_clear_ds){d, 1, 0xff, 0xff};
}
static void fx_state(int kind, const void *bytes, uint32_t n) {
    p_bind_state *p = op_rec(OP_BIND_STATE, sizeof *p);
    p->kind = kind; memcpy(p->bytes, bytes, n);
}
static void fx_prog(uint64_t prog, uint64_t serial, int stages) {
    *(p_bind_program_id *)op_rec(OP_BIND_PROGRAM, sizeof(p_bind_program_id)) =
        (p_bind_program_id){(const prog_t *)(uintptr_t)prog, serial, stages, 0};
}
static void fx_vattr(uint32_t st) {   // 样例恒一条
    p_bind_vattr *p = op_rec(OP_BIND_VATTR, offsetof(p_bind_vattr, st) + 4);
    p->first = 0; p->n = 1; p->st[0] = st;
}
static void fx_vstream(vs_st st) {
    p_bind_vstream *p = op_rec(OP_BIND_VSTREAM, offsetof(p_bind_vstream, st) + sizeof st);
    p->first = 0; p->n = 1; p->st[0] = st;
}
static void fx_vbuf(int stream, uint64_t addr, uint32_t size) {
    p_bind_vbuf *p = op_rec(OP_BIND_VBUF, offsetof(p_bind_vbuf, r) + sizeof(NVNbufferRange));
    p->first = stream; p->n = 1; p->r[0].address = addr; p->r[0].size = size;
}
static void fx_vps(float w, float h) {
    p_viewports *p = op_rec(OP_VIEWPORTS, offsetof(p_viewports, v) + 24);
    p->first = 0; p->n = 1; p->v[0][0] = 0; p->v[0][1] = 0; p->v[0][2] = w; p->v[0][3] = h; p->v[0][4] = 0; p->v[0][5] = 1;
}
static void fx_scissor(int w, int h) {
    *(p_scissor *)op_rec(OP_SCISSOR, sizeof(p_scissor)) = (p_scissor){0, 0, w, h};
}
static void fx_draw(int prim, int first, int count, int inst) {
    *(p_draw *)op_rec(OP_DRAW, sizeof(p_draw)) = (p_draw){prim, first, count, inst, 0, 0, 0, 0, 0, 0};
}
static void fx_dispatch(int x, int y, int z) {
    *(p_dispatch *)op_rec(OP_DISPATCH, sizeof(p_dispatch)) = (p_dispatch){x, y, z, 0, 0};
}
static void fx_clear_buf(uint64_t addr, uint64_t n, uint32_t v) {
    *(p_clear_buf *)op_rec(OP_CLEAR_BUF, sizeof(p_clear_buf)) = (p_clear_buf){addr, n, v, 0};
}
static void fx_copy_b2b(uint64_t s, uint64_t d, uint64_t n) {
    uint64_t *p = op_rec(OP_COPY_B2B, 24); p[0] = s; p[1] = d; p[2] = n;
}
static void fx_bind_ssbo(int stage, int index, uint64_t addr, uint64_t size) {
    *(p_bind_buf *)op_rec(OP_BIND_SSBO, sizeof(p_bind_buf)) = (p_bind_buf){stage, index, addr, size};
}
static void fx_set_pool_op(uint32_t op, uint64_t dp) {
    *(p_set_pool *)op_rec(op, sizeof(p_set_pool)) = (p_set_pool){(const dpool_t *)(uintptr_t)dp};
}
static void fx_bind_tex1(int stage, int slot, uint32_t tid, uint32_t sid) {
    *(p_bind_tex1 *)op_rec(OP_BIND_TEX1, sizeof(p_bind_tex1)) =
        (p_bind_tex1){stage, slot, (uint64_t)tid | (uint64_t)sid << 20, 0, 0};
}
static void fx_end(void) { op_rec(OP_END, 0); }

static void fx_states(const states *s) {
    fx_state(0, &s->blend, sizeof s->blend);
    fx_state(1, &s->color, sizeof s->color);
    fx_state(2, &s->chmask, sizeof s->chmask);
    fx_state(3, &s->ms, sizeof s->ms);
    fx_state(4, &s->poly, sizeof s->poly);
    fx_state(5, &s->ds, sizeof s->ds);
}

// ---------- 样例骨架 ----------

#define W 256u
#define H 256u
#define FMT_RGBA8 0x25u
#define FMT_D32 0x34u
#define PRIM_TRI 4
#define USE_RENDER NVN_GPU_TEX_RENDER
#define USE_SAMPLED_UP (NVN_GPU_TEX_SAMPLED | NVN_GPU_TEX_CPU_UPLOAD)

// 合成 blob：可辨识、确定、与实现无关（FORMAT.md §7：键→产物映射在 RES，blob 内容占位）
static const uint8_t SYNTH_VS[16] = {'S', '2', 'R', 'F', '-', 'S', 'P', 'V', '-', 'v', 's', 1, 0, 0, 0, 0};
static const uint8_t SYNTH_FS[16] = {'S', '2', 'R', 'F', '-', 'S', 'P', 'V', '-', 'f', 's', 1, 0, 0, 0, 0};
static const uint8_t SYNTH_CS[16] = {'S', '2', 'R', 'F', '-', 'S', 'P', 'V', '-', 'c', 's', 1, 0, 0, 0, 0};
static const uint8_t K_VS[8] = {'R', 'F', 'X', '_', 'V', 'S', '0', '1'};
static const uint8_t K_FS[8] = {'R', 'F', 'X', '_', 'F', 'S', '0', '1'};
static const uint8_t K_FTS[8] = {'R', 'F', 'X', '_', 'F', 'S', '0', '2'};
static const uint8_t K_CS[8] = {'R', 'F', 'X', '_', 'C', 'S', '0', '1'};

static void fx_reset(void) {
    n_calls = 0; n_res = 0; n_exp = 0;
    ops_ = (bb){0};
    opos = 0; n_segs = 0;
    e_hid = 0; e_surf = 0; g_fence = 0; g_hobj = g_hcmd = g_hdata = 0;
    OBJ_ = GBASE; CMD_ = GBASE + 0x8000; DATA_ = 0;
    segs[n_segs++] = (gseg_t){OBJ_, 0x8000};
    segs[n_segs++] = (gseg_t){CMD_, 0x8000};
    e_assume(); e_rc(RFX_GPU_OPEN, 0);
}
static void fx_surface(void) {
    res_surface(W, H, FMT_RGBA8, 3);
    e_surf = ++e_hid; e_attach(e_surf);
}
static void fx_data(uint64_t n) { DATA_ = GBASE + 0x10000; segs[n_segs++] = (gseg_t){DATA_, n}; }

static void fx_submit(uint32_t e_cmd) {
    memcpy(gptr(CMD_), ops_.p, ops_.len);
    g_fence++;
    c_sub_index(&CMD_, 1);
    c_none(RFX_BE_SUB_BEGIN, 0);
    c_u64(RFX_BE_EXEC, CMD_);
    c_none(RFX_BE_SUB_COMMIT, g_fence);
    c_wait(g_fence, 0, 1);
    e_commit(e_cmd, g_fence);
    k_done(g_fence);
    k_fence(g_fence);
    e_fence_wait(g_fence, 0);
}
static void fx_present(uint64_t tex, uint32_t src_view, uint64_t ticket) {
    c_present(tex, 0, ticket);
    uint32_t dv = ++e_hid;
    e_acquire(e_surf, dv, W, H, FMT_RGBA8, 1, 1);
    e_present(e_surf, 1, src_view, W, H, ticket);
    k_presented(ticket);
}
static void in_pools(uint64_t data_n) {
    // 钉法（FORMAT.md §6.2）：pool_add 同步 buf_wrap 成功（CAP_HOST_IMPORT），
    // 池内后续引用 = 包装 hid + 池内偏移。
    c_u32(RFX_BE_SET_DEPTH_ZERO, 1); c_u32(RFX_BE_SET_ORIGIN_LL, 1);
    c_pool_add(OBJ_, 0x8000);  g_hobj = ++e_hid; e_wrap_ok(OBJ_, 0x8000, g_hobj);
    c_pool_add(CMD_, 0x8000);  g_hcmd = ++e_hid; e_wrap_ok(CMD_, 0x8000, g_hcmd);
    if (data_n) { c_pool_add(DATA_, data_n); g_hdata = ++e_hid; e_wrap_ok(DATA_, data_n, g_hdata); }
}
static void write_pair(const char *dir, const char *name) {
    char p[1024];
    snprintf(p, sizeof p, "%s/%s.in.rfx", dir, name);
    rfx_w *w = rfx_w_open(p, RFX_KIND_IN);
    if (!w) { fprintf(stderr, "打不开 %s\n", p); exit(2); }
    for (int i = 0; i < n_segs; i++) rfx_w_region(w, segs[i].a, segs[i].n, 3);
    for (int i = 0; i < n_segs; i++) rfx_w_data(w, segs[i].a, gptr(segs[i].a), segs[i].n);
    for (int i = 0; i < n_res; i++)
        rfx_w_res(w, in_res[i].id, res_names[i], in_res[i].p.p, in_res[i].p.len);
    for (int i = 0; i < n_calls; i++)
        rfx_w_call(w, in_calls[i].id, in_calls[i].ret, in_calls[i].p.p, in_calls[i].p.len);
    rfx_w_end(w);
    if (rfx_w_close(w)) { fprintf(stderr, "写 %s 失败\n", p); exit(2); }

    snprintf(p, sizeof p, "%s/%s.exp.rfx", dir, name);
    w = rfx_w_open(p, RFX_KIND_EXP);
    if (!w) { fprintf(stderr, "打不开 %s\n", p); exit(2); }
    for (int i = 0; i < n_exp; i++) {
        if (exps[i].kind == 2) rfx_w_raw(w, RFX_REC_ASSUME, exps[i].p.p, exps[i].p.len);
        else if (exps[i].kind == 1) rfx_w_chk(w, exps[i].id, exps[i].p.p, exps[i].p.len);
        else rfx_w_exp(w, exps[i].id, exps[i].p.p, exps[i].p.len);
    }
    rfx_w_end(w);
    if (rfx_w_close(w)) { fprintf(stderr, "写 %s 失败\n", p); exit(2); }
    printf("%s：%d 调用、%d 期望记录\n", name, n_calls, n_exp);
}
// 图形样例公共 RES：vs+fs 程序（快照 + 两份合成产物），返回 prog 的 guest 地址
static uint64_t gfx_prog(const uint8_t *fskey, const bb *lay_fs, uint8_t stof[6], bb *lay_vs) {
    uint8_t keys[6][8] = {0}; memcpy(keys[0], K_VS, 8); memcpy(keys[1], fskey, 8);
    res_prog(1, (const uint8_t (*)[8])keys, stof);
    lay_head(lay_vs, 0, 0, 0, 0, "rfx-empty");
    res_shader(0, K_VS, "main0_z", SYNTH_VS, sizeof SYNTH_VS, lay_vs);
    res_shader(1, fskey, "main0", SYNTH_FS, sizeof SYNTH_FS, lay_fs);
    uint64_t codes[6] = {0};
    codes[0] = g_blob(SYNTH_VS, sizeof SYNTH_VS); codes[1] = g_blob(SYNTH_FS, sizeof SYNTH_FS);
    return g_prog(1, stof, codes);
}

// ---------- 样例 ----------

// s00：缓冲原语（D2 锚：fill_buf 32 位语义 + copy_buf + 时间线；§8 C01/C26 形状）
static void s00_buf(const char *dir) {
    fx_reset();
    fx_data(0x1000);
    uint64_t A = DATA_ + 0x100, B = DATA_ + 0x200;
    memset(gptr(B), 0xAA, 16);
    fx_clear_buf(A, 16, 0x11223344u);
    fx_copy_b2b(A, B, 16);
    fx_end();
    in_pools(0x1000);
    uint32_t C = ++e_hid;
    e_cmd_begin(C);
    uint32_t B_ = g_hdata;
    e_fill(C, B_, A - DATA_, 16, 0x11223344u);
    e_copy(C, B_, A - DATA_, B_, B - DATA_, 16);
    fx_submit(C);
    uint8_t want[16];
    for (int i = 0; i < 4; i++) memcpy(want + 4 * i, (uint8_t[]){0x44, 0x33, 0x22, 0x11}, 4);
    k_buf(B_, B - DATA_, want, 16);
    write_pair(dir, "s00_buf");
}

// s01：清屏 + present（SET_RT + CLEAR_COLOR → load=CLEAR 单通道；D6 上屏形状）
static void s01_clear(const char *dir) {
    fx_reset(); fx_surface();
    uint64_t win = g_tex(1, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, NVN_TEXTURE_FLAGS_DISPLAY, W, H, 0, 0);
    c_u64(RFX_BE_TEX_INIT, win); c_u64(RFX_BE_XV_WINDOW_TEX, 1);
    fx_set_rt(1, (uint64_t[]){win}, 0);
    fx_clear_color(0, 0.1f, 0.4f, 0.9f, 1.0f);
    fx_end();
    in_pools(0);
    uint32_t C = ++e_hid;
    e_cmd_begin(C);
    uint32_t T = ++e_hid;
    e_tex(&((tex_t *)gptr(win))->d, USE_RENDER, T);
    uint32_t V = ++e_hid;
    e_view(T, NULL, V);
    float cl[8][4]; memset(cl, 0, sizeof cl); cl[0][0] = 0.1f; cl[0][1] = 0.4f; cl[0][2] = 0.9f; cl[0][3] = 1.0f;
    e_pass(C, 1, (uint32_t[8]){V}, (uint8_t[8]){NVN_GPU_LOAD_CLEAR}, (const float (*)[4])cl, 0, 0, 0, W, H);
    e_1c(RFX_GPU_PASS_END, C);
    fx_submit(C);
    fx_present(win, V, 1);
    write_pair(dir, "s01_clear");
}

// s02：单三角形（资源懒建 + 管线 + 通道内 draw 的最小闭环）
static void s02_triangle(const char *dir) {
    fx_reset(); fx_surface();
    uint8_t stof[6] = {0, 1, 0xff, 0xff, 0xff, 0xff};
    bb lay_vs = {0}, lay_fs = {0}; lay_head(&lay_fs, 0, 0, 0, 0, "rfx-empty");
    uint64_t win = g_tex(1, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, NVN_TEXTURE_FLAGS_DISPLAY, W, H, 0, 0);
    uint64_t prog = gfx_prog(K_FS, &lay_fs, stof, &lay_vs);
    fx_data(0x1000);
    static const float verts[9] = {0, 0.5f, 0, -0.5f, -0.5f, 0, 0.5f, -0.5f, 0};
    memcpy(gptr(DATA_), verts, sizeof verts);
    states st = st_draw(0);
    fx_set_rt(1, (uint64_t[]){win}, 0);
    fx_states(&st);
    fx_prog(prog, 1, 0x3);
    fx_vattr(0x2E); fx_vstream((vs_st){12, 0}); fx_vbuf(0, DATA_, 36);
    fx_vps(W, H); fx_scissor(W, H);
    fx_draw(PRIM_TRI, 0, 3, 1);
    fx_end();
    c_u64(RFX_BE_TEX_INIT, win); c_u64(RFX_BE_XV_WINDOW_TEX, 1);
    in_pools(0x1000);
    uint32_t C = ++e_hid;
    e_cmd_begin(C);
    uint32_t B = g_hdata;
    uint32_t T = ++e_hid; e_tex(&((tex_t *)gptr(win))->d, USE_RENDER, T);
    uint32_t V = ++e_hid; e_view(T, NULL, V);
    uint32_t SV = ++e_hid; e_shader(0, K_VS, "main0_z", SYNTH_VS, sizeof SYNTH_VS, &lay_vs, SV);
    uint32_t SF = ++e_hid; e_shader(1, K_FS, "main0", SYNTH_FS, sizeof SYNTH_FS, &lay_fs, SF);
    uint32_t P = ++e_hid;
    e_pipe(SV, SF, 1, FMT_RGBA8, 0, PRIM_TRI, &st, (uint32_t[]){0x2E}, 1, (vs_st[]){{12, 0}}, 1, P);
    e_pass(C, 1, (uint32_t[8]){V}, (uint8_t[8]){NVN_GPU_LOAD_DONTCARE}, (const float (*)[4])(float[8][4]){0}, 0, 0, 0, W, H);
    e_2c(RFX_GPU_SET_PIPE, C, P);
    e_dyn(C, W, H, &st.ds, &st.poly);
    e_vbuf(C, 0, B, 0);
    e_draw(C, PRIM_TRI, 3, 0, 1);
    e_1c(RFX_GPU_PASS_END, C);
    fx_submit(C);
    fx_present(win, V, 1);
    write_pair(dir, "s02_triangle");
    free(lay_vs.p); free(lay_fs.p);
}

// s03：纹理采样（池内贴图 + TEX_SAMP 绑定 + tex_upload；§8 C25 形状）
static void s03_texture(const char *dir) {
    fx_reset(); fx_surface();
    uint64_t dmem_pool = g_poolobj(0, 0);
    fx_data(0x8000);
    ((pool_t *)gptr(dmem_pool))->mem = (uint8_t *)(uintptr_t)DATA_;
    ((pool_t *)gptr(dmem_pool))->size = 0x8000;
    uint64_t win = g_tex(1, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, NVN_TEXTURE_FLAGS_DISPLAY, W, H, 0, 0);
    uint64_t smp_tex = g_tex(2, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, NVN_TEXTURE_FLAGS_LINEAR, 64, 64,
                             dmem_pool, 0x4000);
    uint64_t tdp = g_dpool(dmem_pool, 0, 8), sdp = g_dpool(dmem_pool, 0, 8);
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {   // 64×64 RGBA8 线性渐变
        uint8_t *px = gptr(DATA_ + 0x4000 + (y * 64 + x) * 4);
        px[0] = (uint8_t)(x * 4); px[1] = (uint8_t)(y * 4); px[2] = 0x80; px[3] = 0xFF;
    }
    static const float verts[9] = {-1, 1, 0, -1, -1, 0, 1, 1, 0};
    memcpy(gptr(DATA_), verts, sizeof verts);
    uint8_t stof[6] = {0, 1, 0xff, 0xff, 0xff, 0xff};
    bb lay_vs = {0}, lay_fs = {0}; lay_head(&lay_fs, 1, 0, 0, 0, "rfx-direct-v1");
    lay_ent(&lay_fs, 0, NVN_GPU_RES_TEX_SAMP, 1, NVN_RB_TEX, 0, 0, 1, 0, 1u << 1);
    uint64_t prog = gfx_prog(K_FTS, &lay_fs, stof, &lay_vs);
    states st = st_draw(0);
    fx_set_rt(1, (uint64_t[]){win}, 0);
    fx_states(&st);
    fx_prog(prog, 1, 0x3);
    fx_vattr(0x2E); fx_vstream((vs_st){12, 0}); fx_vbuf(0, DATA_, 36);
    fx_vps(W, H); fx_scissor(W, H);
    fx_set_pool_op(OP_SET_TEX_POOL, tdp);
    fx_set_pool_op(OP_SET_SAMP_POOL, sdp);
    fx_bind_tex1(1, 0, 1, 1);                    // stage=FS, slot0, tid=1, sid=1
    fx_draw(PRIM_TRI, 0, 3, 1);
    fx_end();
    c_u64(RFX_BE_TEX_INIT, win); c_u64(RFX_BE_TEX_INIT, smp_tex);
    c_u64(RFX_BE_TEX_CPU_WRITTEN, smp_tex);
    c_u64(RFX_BE_XV_WINDOW_TEX, 1);
    c_reg_tex(1, smp_tex); c_reg_samp(1, &SAMP_LINEAR); c_set_tex_pool_n(8);
    in_pools(0x8000);
    uint32_t C = ++e_hid;
    e_cmd_begin(C);
    uint32_t B = g_hdata;
    uint32_t T = ++e_hid; e_tex(&((tex_t *)gptr(win))->d, USE_RENDER, T);
    uint32_t V = ++e_hid; e_view(T, NULL, V);
    uint32_t T2 = ++e_hid; e_tex(&((tex_t *)gptr(smp_tex))->d, USE_SAMPLED_UP, T2);
    uint32_t V2 = ++e_hid; e_view(T2, NULL, V2);
    uint32_t S = ++e_hid; e_samp(&SAMP_LINEAR, S);
    int32_t reg[6] = {0, 0, 0, 64, 64, 1};
    e_upload(C, T2, reg, g_hdata, 0x4000, 256, 64 * 64 * 4, gptr(DATA_ + 0x4000), 64 * 64 * 4);
    uint32_t SV = ++e_hid; e_shader(0, K_VS, "main0_z", SYNTH_VS, sizeof SYNTH_VS, &lay_vs, SV);
    uint32_t SF = ++e_hid; e_shader(1, K_FTS, "main0", SYNTH_FS, sizeof SYNTH_FS, &lay_fs, SF);
    uint32_t P = ++e_hid;
    e_pipe(SV, SF, 1, FMT_RGBA8, 0, PRIM_TRI, &st, (uint32_t[]){0x2E}, 1, (vs_st[]){{12, 0}}, 1, P);
    e_pass(C, 1, (uint32_t[8]){V}, (uint8_t[8]){NVN_GPU_LOAD_DONTCARE}, (const float (*)[4])(float[8][4]){0}, 0, 0, 0, W, H);
    e_2c(RFX_GPU_SET_PIPE, C, P);
    e_dyn(C, W, H, &st.ds, &st.poly);
    e_vbuf(C, 0, B, 0);
    e_bind_ts(C, 1, 0, 0, V2, S);
    e_draw(C, PRIM_TRI, 3, 0, 1);
    e_1c(RFX_GPU_PASS_END, C);
    fx_submit(C);
    fx_present(win, V, 1);
    write_pair(dir, "s03_texture");
    free(lay_vs.p); free(lay_fs.p);
}

// s04：深度测试（color+depth 双附件，depth load=CLEAR；ds_st 开深度）
static void s04_depth(const char *dir) {
    fx_reset(); fx_surface();
    uint8_t stof[6] = {0, 1, 0xff, 0xff, 0xff, 0xff};
    bb lay_vs = {0}, lay_fs = {0}; lay_head(&lay_fs, 0, 0, 0, 0, "rfx-empty");
    uint64_t win = g_tex(1, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, NVN_TEXTURE_FLAGS_DISPLAY, W, H, 0, 0);
    uint64_t dep = g_tex(2, NVN_TEXTURE_TARGET_2D, FMT_D32, 0, W, H, 0, 0);
    uint64_t prog = gfx_prog(K_FS, &lay_fs, stof, &lay_vs);
    fx_data(0x1000);
    static const float verts[9] = {0, 0.5f, 0, -0.5f, -0.5f, 0, 0.5f, -0.5f, 0};
    memcpy(gptr(DATA_), verts, sizeof verts);
    states st = st_draw(1);
    fx_set_rt(1, (uint64_t[]){win}, dep);
    fx_clear_ds(1.0f);
    fx_states(&st);
    fx_prog(prog, 1, 0x3);
    fx_vattr(0x2E); fx_vstream((vs_st){12, 0}); fx_vbuf(0, DATA_, 36);
    fx_vps(W, H); fx_scissor(W, H);
    fx_draw(PRIM_TRI, 0, 3, 1);
    fx_end();
    c_u64(RFX_BE_TEX_INIT, win); c_u64(RFX_BE_TEX_INIT, dep); c_u64(RFX_BE_XV_WINDOW_TEX, 1);
    in_pools(0x1000);
    uint32_t C = ++e_hid;
    e_cmd_begin(C);
    uint32_t B = g_hdata;
    uint32_t T = ++e_hid; e_tex(&((tex_t *)gptr(win))->d, USE_RENDER, T);
    uint32_t V = ++e_hid; e_view(T, NULL, V);
    uint32_t TD = ++e_hid; e_tex(&((tex_t *)gptr(dep))->d, USE_RENDER, TD);
    uint32_t VD = ++e_hid; e_view(TD, NULL, VD);
    uint32_t SV = ++e_hid; e_shader(0, K_VS, "main0_z", SYNTH_VS, sizeof SYNTH_VS, &lay_vs, SV);
    uint32_t SF = ++e_hid; e_shader(1, K_FS, "main0", SYNTH_FS, sizeof SYNTH_FS, &lay_fs, SF);
    uint32_t P = ++e_hid;
    e_pipe(SV, SF, 1, FMT_RGBA8, FMT_D32, PRIM_TRI, &st, (uint32_t[]){0x2E}, 1, (vs_st[]){{12, 0}}, 1, P);
    e_pass(C, 1, (uint32_t[8]){V}, (uint8_t[8]){NVN_GPU_LOAD_DONTCARE}, (const float (*)[4])(float[8][4]){0}, VD, NVN_GPU_LOAD_CLEAR, 1.0f, W, H);
    e_2c(RFX_GPU_SET_PIPE, C, P);
    e_dyn(C, W, H, &st.ds, &st.poly);
    e_vbuf(C, 0, B, 0);
    e_draw(C, PRIM_TRI, 3, 0, 1);
    e_1c(RFX_GPU_PASS_END, C);
    fx_submit(C);
    fx_present(win, V, 1);
    write_pair(dir, "s04_depth");
    free(lay_vs.p); free(lay_fs.p);
}

// s05：MRT（三颜色附件同通道；ncolor=3）
static void s05_mrt(const char *dir) {
    fx_reset(); fx_surface();
    uint8_t stof[6] = {0, 1, 0xff, 0xff, 0xff, 0xff};
    bb lay_vs = {0}, lay_fs = {0}; lay_head(&lay_fs, 0, 0, 0, 0, "rfx-empty");
    uint64_t t0 = g_tex(1, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, NVN_TEXTURE_FLAGS_DISPLAY, W, H, 0, 0);
    uint64_t t1 = g_tex(2, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, 0, W, H, 0, 0);
    uint64_t t2 = g_tex(3, NVN_TEXTURE_TARGET_2D, FMT_RGBA8, 0, W, H, 0, 0);
    uint64_t prog = gfx_prog(K_FS, &lay_fs, stof, &lay_vs);
    fx_data(0x1000);
    static const float verts[9] = {0, 0.5f, 0, -0.5f, -0.5f, 0, 0.5f, -0.5f, 0};
    memcpy(gptr(DATA_), verts, sizeof verts);
    states st = st_draw(0);
    fx_set_rt(0x7, (uint64_t[]){t0, t1, t2}, 0);
    fx_states(&st);
    fx_prog(prog, 1, 0x3);
    fx_vattr(0x2E); fx_vstream((vs_st){12, 0}); fx_vbuf(0, DATA_, 36);
    fx_vps(W, H); fx_scissor(W, H);
    fx_draw(PRIM_TRI, 0, 3, 1);
    fx_end();
    c_u64(RFX_BE_TEX_INIT, t0); c_u64(RFX_BE_TEX_INIT, t1); c_u64(RFX_BE_TEX_INIT, t2);
    c_u64(RFX_BE_XV_WINDOW_TEX, 1);
    in_pools(0x1000);
    uint32_t C = ++e_hid;
    e_cmd_begin(C);
    uint32_t B = g_hdata;
    uint32_t T0 = ++e_hid; e_tex(&((tex_t *)gptr(t0))->d, USE_RENDER, T0);
    uint32_t V0 = ++e_hid; e_view(T0, NULL, V0);
    uint32_t T1 = ++e_hid; e_tex(&((tex_t *)gptr(t1))->d, USE_RENDER, T1);
    uint32_t V1 = ++e_hid; e_view(T1, NULL, V1);
    uint32_t T2 = ++e_hid; e_tex(&((tex_t *)gptr(t2))->d, USE_RENDER, T2);
    uint32_t V2 = ++e_hid; e_view(T2, NULL, V2);
    uint32_t SV = ++e_hid; e_shader(0, K_VS, "main0_z", SYNTH_VS, sizeof SYNTH_VS, &lay_vs, SV);
    uint32_t SF = ++e_hid; e_shader(1, K_FS, "main0", SYNTH_FS, sizeof SYNTH_FS, &lay_fs, SF);
    uint32_t P = ++e_hid;
    e_pipe(SV, SF, 3, FMT_RGBA8, 0, PRIM_TRI, &st, (uint32_t[]){0x2E}, 1, (vs_st[]){{12, 0}}, 1, P);
    e_pass(C, 3, (uint32_t[8]){V0, V1, V2}, (uint8_t[8]){NVN_GPU_LOAD_DONTCARE, NVN_GPU_LOAD_DONTCARE, NVN_GPU_LOAD_DONTCARE},
           (const float (*)[4])(float[8][4]){0}, 0, 0, 0, W, H);
    e_2c(RFX_GPU_SET_PIPE, C, P);
    e_dyn(C, W, H, &st.ds, &st.poly);
    e_vbuf(C, 0, B, 0);
    e_draw(C, PRIM_TRI, 3, 0, 1);
    e_1c(RFX_GPU_PASS_END, C);
    fx_submit(C);
    fx_present(t0, V0, 1);
    write_pair(dir, "s05_mrt");
    free(lay_vs.p); free(lay_fs.p);
}

// s06：计算派发（无通道：cpipe + SSBO bind + dispatch；D5 形状）
static void s06_dispatch(const char *dir) {
    fx_reset();
    fx_data(0x1000);
    uint8_t stof[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 5};
    bb lay_cs = {0}; lay_head(&lay_cs, 1, 0, 0, 0, "rfx-direct-v1");
    lay_ent(&lay_cs, 0, NVN_GPU_RES_SSBO, 3, NVN_RB_SBUFU, 0, 0, 1, 0, 1u << 5);
    res_shader(5, K_CS, "main0", SYNTH_CS, sizeof SYNTH_CS, &lay_cs);
    uint8_t keys[6][8] = {0}; memcpy(keys[5], K_CS, 8);
    res_prog(1, (const uint8_t (*)[8])keys, stof);
    uint64_t codes[6] = {0}; codes[5] = g_blob(SYNTH_CS, sizeof SYNTH_CS);
    uint64_t prog = g_prog(1, stof, codes);
    fx_prog(prog, 1, 0x20);
    fx_bind_ssbo(5, 0, DATA_, 0x100);
    fx_dispatch(4, 1, 1);
    fx_end();
    in_pools(0x1000);
    uint32_t C = ++e_hid;
    e_cmd_begin(C);
    uint32_t B = g_hdata;
    uint32_t SC = ++e_hid; e_shader(5, K_CS, "main0", SYNTH_CS, sizeof SYNTH_CS, &lay_cs, SC);
    uint32_t P = ++e_hid; e_cpipe(SC, P);
    e_bind_ssbo(C, 5, 0, 0, B, 0, 0x100);
    e_dispatch(C, P, 4, 1, 1);
    fx_submit(C);
    write_pair(dir, "s06_dispatch");
    free(lay_cs.p);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法：rfx_gen <输出目录>\n"); return 2; }
    s00_buf(argv[1]);
    s01_clear(argv[1]);
    s02_triangle(argv[1]);
    s03_texture(argv[1]);
    s04_depth(argv[1]);
    s05_mrt(argv[1]);
    s06_dispatch(argv[1]);
    return 0;
}
