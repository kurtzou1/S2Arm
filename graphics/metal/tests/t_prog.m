// 第 4 块单测（程序 / 着色器）。期望值全部手算（不跑被测实现）。
// 用法：t_prog <手写 SPIR-V 目录（vs/fs/cs.spv + lib/gal.idx + lib/gal.shards + 各片）> [语料目录（prog_*.txt + *.spv + lib/）]
//  A 端到端图形：手写 VS + FS（Ryujinx 形态：常量集 0、组合贴图采样器集 2、绑定号按 Gpu 层片元段）→ 运行时现编 → 布局逐项对手算期望 →
//    按 gal_arg 偏移手工写参数缓冲（常量给颜色 / 缩放、一张贴图 + 采样器）画到 4×4 离屏目标 → 读回逐像素对手算期望。这一步证明 offset 约定是真的。
//  B 二进制往返：create → binary → release → 清内存缓存 + 关现编（先验「未命中干净失败」）→ 开离线库 → load_binary → 布局与 A 逐字节相同 → 再画一遍，像素与 A 逐字节相同。
//  C 计算：存储缓冲读写 + .length()（缓冲长度表）→ 读回对手算。
//  D 语料：Ryujinx 真实产出的 SPIR-V 程序全量过 create（现编）→ 成功率、失败分类与首例、布局自洽检查；计算程序建管线；
//    再关现编、开语料离线库重建全部程序 + 二进制往返，布局须与现编逐字节相同。
#import "../gal_internal.h"
#import "../gal_draw_internal.h"
#define SPV_ENABLE_UTILITY_CODE
// spirv.h 的工具函数是 C99 inline 定义：同 gal_spvx.m，本文件内改成 static inline
#define inline static inline
#include "spirv.h"
#undef inline
#include <dirent.h>
#include <execinfo.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libproc.h>
#include <objc/runtime.h>
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }

static int g_fail, g_checks;
static const char *g_argv0;   // 子进程用例（--first-load）要重起自己

#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static void *slurp(const char *path, uint32_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    void *b = malloc(n ? n : 1); if (fread(b, 1, n, f) != (size_t)n) { free(b); fclose(f); return NULL; }
    fclose(f); *len = (uint32_t)n; return b;
}

// 程序布局快照（用于跨路径逐字节比较）
typedef struct { int nargs; gal_arg *args; uint32_t set_size[GAL_MAX_SETS], set_stages[GAL_MAX_SETS], stage_set_size[6][GAL_MAX_SETS];
    int32_t sbi[6]; uint32_t vs_inputs, fs_outputs; uint8_t vct[32], fct[8]; MTLSize tg; uint64_t hash; int fnmask, fs_color_round; } snap;
static snap take(const gal_prog *p) {
    snap s; memset(&s, 0, sizeof s);
    s.nargs = p->nargs; s.args = malloc((p->nargs + 1) * sizeof *s.args); memcpy(s.args, p->args, p->nargs * sizeof *s.args);
    memcpy(s.set_size, p->set_size, sizeof s.set_size); memcpy(s.set_stages, p->set_stages, sizeof s.set_stages);
    memcpy(s.stage_set_size, p->stage_set_size, sizeof s.stage_set_size); memcpy(s.sbi, p->size_buf_index, sizeof s.sbi);
    s.vs_inputs = p->vs_inputs; s.fs_outputs = p->fs_outputs; s.fs_color_round = p->fs_color_round; memcpy(s.vct, p->vs_input_ctype, 32); memcpy(s.fct, p->fs_output_ctype, 8);
    s.tg = p->threadgroup; s.hash = p->hash; for (int i = 0; i < 6; i++) if (p->fn[i]) s.fnmask |= 1 << i;
    return s;
}
static int snap_eq(const snap *a, const snap *b) {
    return a->nargs == b->nargs && !memcmp(a->args, b->args, a->nargs * sizeof *a->args) && !memcmp(a->set_size, b->set_size, sizeof a->set_size) &&
           !memcmp(a->set_stages, b->set_stages, sizeof a->set_stages) && !memcmp(a->stage_set_size, b->stage_set_size, sizeof a->stage_set_size) &&
           !memcmp(a->sbi, b->sbi, sizeof a->sbi) && a->vs_inputs == b->vs_inputs && a->fs_outputs == b->fs_outputs && !memcmp(a->vct, b->vct, 32) &&
           !memcmp(a->fct, b->fct, 8) && a->fs_color_round == b->fs_color_round && a->tg.width == b->tg.width && a->tg.height == b->tg.height && a->tg.depth == b->tg.depth && a->hash == b->hash && a->fnmask == b->fnmask;
}
static const gal_arg *find_arg(const gal_prog *p, int kind, int set, int binding, int stage) {
    for (int i = 0; i < p->nargs; i++) { const gal_arg *a = &p->args[i]; if (a->kind == kind && a->set == set && a->binding == binding && (a->stages >> stage & 1)) return a; }
    return NULL;
}
static void dump_args(const gal_prog *p) {
    for (int i = 0; i < p->nargs; i++) { const gal_arg *a = &p->args[i]; printf("    arg kind %u set %u binding %u offset %u count %u stages %#x slot %u\n", a->kind, a->set, a->binding, a->offset, a->count, a->stages, a->slot); }
}

// ---------- A / B：画图 ----------
enum { RGBA8 = 36 };
static nxgal_tex_info info2d(int w, int h) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, 4, RGBA8, 0, 1, {2, 3, 4, 5}}; return i; }
static uint32_t g_rt, g_tex; static id<MTLSamplerState> g_smp;
static id<MTL4ArgumentTable> g_vt, g_ft, g_ct;

static void setup_draw(void) {
    nxgal_tex_info ri = info2d(4, 4); g_rt = nxgal_tex_create(&ri);
    nxgal_tex_info ti = info2d(2, 2); g_tex = nxgal_tex_create(&ti);
    // 贴图 2×2：行 0 = 红 绿，行 1 = 蓝 白
    uint8_t texel[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
    nxgal_tex_set_data(g_tex, -1, -1, NULL, texel, sizeof texel);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; sd.supportArgumentBuffers = YES;
    g_smp = [g_gdev newSamplerStateWithDescriptor:sd];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = GAL_TABLE_SLOTS; NSError *e = nil;
    g_vt = [g_gdev newArgumentTableWithDescriptor:ad error:&e]; g_ft = [g_gdev newArgumentTableWithDescriptor:ad error:&e]; g_ct = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
}

// 按 gal_prog 写某阶段的全部参数缓冲并设到参数表——这就是第 5/6 块要做的事的最小版
typedef struct { uint64_t ubo[64]; uint64_t ssbo[64]; uint64_t sizes_tab; uint32_t ubo_size[64]; } binds;   // 下标 = Ryujinx 绑定号（测试里够用）；ubo_size：常量缓冲绑定字节数（长度表用）
static void bind_stage(const gal_prog *p, int st, id<MTL4ArgumentTable> t, const binds *b) {
    for (int s = 0; s < GAL_MAX_SETS; s++) {
        uint32_t sz = p->stage_set_size[st][s]; if (!sz) continue;
        uint64_t gpu; uint8_t *ab = gal_transient(sz, 16, &gpu); memset(ab, 0, sz);
        for (int i = 0; i < p->nargs; i++) {
            const gal_arg *a = &p->args[i]; if (a->set != s || !(a->stages >> st & 1)) continue;
            for (uint32_t k = 0; k < a->count; k++) {
                uint64_t v = 0;
                switch (a->kind) {
                case GAL_ARG_UBO: v = b->ubo[a->binding]; break;
                case GAL_ARG_SSBO: v = b->ssbo[a->binding]; break;
                case GAL_ARG_TEX: { MTLResourceID r = gal_tex_get(g_tex)->tex.gpuResourceID; memcpy(&v, &r, 8); break; }
                case GAL_ARG_SMP: { MTLResourceID r = g_smp.gpuResourceID; memcpy(&v, &r, 8); break; }
                case GAL_ARG_SIZES: v = b->sizes_tab; break;
                case GAL_ARG_OOBCNT: v = gal_oob_cell(p->stage_hash[st]); break;   // 越界 / 循环到上限计数格（同 gal_draw.m write_arg）
                case GAL_ARG_UBOLEN: {   // 常量缓冲长度表：[绑定号] = 绑定的 vec4 个数，封顶 4096（同 gal_draw.m ubolen_table）
                    uint32_t *t = gal_transient(a->slot * 4, 16, &v);
                    for (uint32_t j = 0; j < a->slot; j++) { uint32_t q = (b->ubo_size[j] + 15) / 16; t[j] = q > 4096 ? 4096 : q; }
                    break; }
                }
                memcpy(ab + a->offset + 8 * k, &v, 8);
            }
        }
        [t setAddress:gpu atIndex:s];
    }
    if (p->size_buf_index[st] >= 0) [t setAddress:b->sizes_tab atIndex:p->size_buf_index[st]];
}

extern int gal_border_table(gal_prog *pg, uint64_t *gpu_out);
static int draw(uint32_t prog, uint8_t out[64]) {
    gal_prog *p = gal_prog_get(prog); if (!p) return 0;
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    d.vertexFunctionDescriptor = p->fn[1]; d.fragmentFunctionDescriptor = p->fn[5];   // 同 gal_state.m pso_desc
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = GAL_VB_BASE;
    vd.attributes[2].format = MTLVertexFormatUInt; vd.attributes[2].offset = 8; vd.attributes[2].bufferIndex = GAL_VB_BASE;
    vd.layouts[GAL_VB_BASE].stride = 12;
    d.vertexDescriptor = vd;
    NSError *e = nil;
    id<MTLRenderPipelineState> ps = [g_gcomp newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e];
    if (!ps) { printf("  ✗ 建渲染管线失败：%s\n", e.localizedDescription.UTF8String); return 0; }
    // 常量：支撑缓冲（绑定 0）d[0] = 位置缩放 (1,1)，d[1] = 缩放 (1,1,1,0.4)；常量缓冲 19：d[2] = 颜色 (1,0.6,0.2,1)，其余格子填 9（取错下标就看得出）
    binds b; memset(&b, 0, sizeof b);
    float *sb = gal_transient(64, 16, &b.ubo[0]); float sbv[16] = {1, 1, 0, 0, 1, 1, 1, 0.4f, 9, 9, 9, 9, 9, 9, 9, 9}; memcpy(sb, sbv, 64);
    float *cb = gal_transient(64, 16, &b.ubo[19]); float cbv[16] = {9, 9, 9, 9, 9, 9, 9, 9, 1, 0.6f, 0.2f, 1, 9, 9, 9, 9}; memcpy(cb, cbv, 64);
    b.ubo_size[0] = b.ubo_size[19] = 64;
    // 顶点：盖满全屏的大三角，属性 0 = float2 位置，属性 2 = uint（恒 0）
    uint64_t vgpu; uint8_t *vb = gal_transient(36, 16, &vgpu);
    float pos[3][2] = {{-1, -1}, {3, -1}, {-1, 3}}; for (int i = 0; i < 3; i++) { memcpy(vb + i * 12, pos[i], 8); uint32_t z = 0; memcpy(vb + i * 12 + 8, &z, 4); }
    nxgal_set_render_targets(&g_rt, 1, 0);
    id<MTL4RenderCommandEncoder> enc = gal_render_enc();
    bind_stage(p, 1, g_vt, &b); [g_vt setAddress:vgpu atIndex:GAL_VB_BASE];
    bind_stage(p, 5, g_ft, &b);
    uint64_t round_gpu; uint32_t *round_mask = gal_transient(sizeof *round_mask, 16, &round_gpu);
    if (!round_mask) return 0;
    *round_mask = 0; [g_ft setAddress:round_gpu atIndex:GAL_COLOR_ROUND_SLOT];   // RGBA8 不量化
    if (p->border_stages & (1u << 5)) {
        uint64_t border_gpu; if (!gal_border_table(p, &border_gpu)) return 0;
        [g_ft setAddress:border_gpu atIndex:GAL_BORDER_SLOT];
    }
    [enc setArgumentTable:g_vt atStages:MTLRenderStageVertex]; [enc setArgumentTable:g_ft atStages:MTLRenderStageFragment];
    [enc setRenderPipelineState:ps];
    [enc setViewport:(MTLViewport){0, 0, 4, 4, 0, 1}];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    g_genc_serial++;
    return nxgal_tex_get_data(g_rt, 0, 0, out, 64) == 64;
}

static uint32_t create_vf(const char *dir) {
    char p[1024]; uint32_t lv, lf;
    snprintf(p, sizeof p, "%s/vs.spv", dir); void *vs = slurp(p, &lv);
    snprintf(p, sizeof p, "%s/fs.spv", dir); void *fs = slurp(p, &lf);
    if (!vs || !fs) { printf("  ✗ 读不了 %s 下的 vs/fs.spv\n", dir); return 0; }
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    // Gpu 层资源布局（节选，同 ShaderInfoBuilder 口径）：支撑缓冲 0（C|V|F）、顶点常量 1..18、片元常量 19..36、片元组合贴图 128..191
    nxgal_res_desc d[1 + 18 + 18 + 64]; int n = 0;
    d[n++] = (nxgal_res_desc){0, 0, 1, 0, 1 | 2 | 32};
    for (int i = 0; i < 18; i++) d[n++] = (nxgal_res_desc){0, 1 + i, 1, 0, 2};
    for (int i = 0; i < 18; i++) d[n++] = (nxgal_res_desc){0, 19 + i, 1, 0, 32};
    for (int i = 0; i < 64; i++) d[n++] = (nxgal_res_desc){2, 128 + i, 1, 4, 32};
    uint32_t id = nxgal_prog_create(sh, 2, d, n, 0xf);
    free(vs); free(fs);
    return id;
}

static uint8_t g_pxA[64];
static snap g_snapA;
static int g_nocount = 1;   // 缺省计数关（出包口径），翻译不插计数收尾与计数格；--count 计数开（只跑现翻的用例 + 计数，见 main）
static void t_graphics(const char *dir) {
    printf("· A 端到端图形：手写 VS+FS → 运行时现编 → 按 gal_arg 写参数缓冲 → 画 4×4\n");
    uint32_t prog = create_vf(dir);
    CHECK(prog && nxgal_prog_status(prog, 1) == 0, "建程序失败：%s", nxgal_prog_last_error());
    gal_prog *p = gal_prog_get(prog); if (!p || p->status) return;
    dump_args(p);
    // 手算期望（规则：本阶段资源按 (集, 绑定) 升序占 [[id]]；组合贴图采样器 = 贴图 count 个 + 采样器 count 个；offset = id × 8）
    //   VS 集 0：绑定 0 → id 0 → 偏移 0；FS 集 0：绑定 0 → 0、绑定 19 → 8；FS 集 2：绑定 128 贴图 0 / 采样器 8，绑定 129 贴图 16 / 采样器 24
    //   加固新增（gal_spvx.m，按绑定号排在集内最后）：越界计数格（绑定 0xfffd，只在计数开时翻译才有）VS 集 0 偏移 8、FS 集 0 偏移 16；
    //   常量缓冲长度表（绑定 0xfffe）计数开时 VS 集 0 偏移 16、FS 集 0 偏移 24，计数关时各前移一格（VS 8、FS 16），表长 = 最大常量缓冲绑定号 + 1（VS 1、FS 20）
    //   于是计数开 / 关：参数条目 10 / 8，集大小 VS0 24 / 16、FS0 32 / 24、set_size[0] 32 / 24
    const int oc = !g_nocount;
    const gal_arg *a;
    a = find_arg(p, GAL_ARG_UBO, 0, 0, 1); CHECK(a && a->offset == 0 && a->count == 1, "VS 集0 绑定0 偏移期望 0");
    a = find_arg(p, GAL_ARG_UBO, 0, 0, 5); CHECK(a && a->offset == 0 && a->stages == (2u | 32u), "支撑缓冲：VS/FS 偏移都 0，应合成一条 stages = V|F（%#x）", a ? a->stages : 0);
    a = find_arg(p, GAL_ARG_UBO, 0, 19, 5); CHECK(a && a->offset == 8 && a->stages == 32u, "FS 集0 绑定19 偏移期望 8（实得 %d）", a ? (int)a->offset : -1);
    a = find_arg(p, GAL_ARG_TEX, 2, 128, 5); CHECK(a && a->offset == 0, "FS 集2 绑定128 贴图偏移期望 0（实得 %d）", a ? (int)a->offset : -1);
    a = find_arg(p, GAL_ARG_SMP, 2, 128, 5); CHECK(a && a->offset == 8, "FS 集2 绑定128 采样器偏移期望 8（实得 %d）", a ? (int)a->offset : -1);
    a = find_arg(p, GAL_ARG_TEX, 2, 129, 5); CHECK(a && a->offset == 16, "FS 集2 绑定129（未用）贴图偏移期望 16（实得 %d）", a ? (int)a->offset : -1);
    a = find_arg(p, GAL_ARG_SMP, 2, 129, 5); CHECK(a && a->offset == 24, "FS 集2 绑定129 采样器偏移期望 24（实得 %d）", a ? (int)a->offset : -1);
    if (oc) {
        a = find_arg(p, GAL_ARG_OOBCNT, 0, GAL_OOBCNT_BINDING, 1); CHECK(a && a->offset == 8 && a->stages == 2u, "VS 越界计数格期望偏移 8（实得 %d）", a ? (int)a->offset : -1);
        a = find_arg(p, GAL_ARG_OOBCNT, 0, GAL_OOBCNT_BINDING, 5); CHECK(a && a->offset == 16 && a->stages == 32u, "FS 越界计数格期望偏移 16（实得 %d）", a ? (int)a->offset : -1);
    } else { CHECK(!find_arg(p, GAL_ARG_OOBCNT, 0, GAL_OOBCNT_BINDING, 1) && !find_arg(p, GAL_ARG_OOBCNT, 0, GAL_OOBCNT_BINDING, 5), "计数关：期望没有越界计数格参数"); }
    a = find_arg(p, GAL_ARG_UBOLEN, 0, GAL_UBOLEN_BINDING, 1); CHECK(a && a->offset == (oc ? 16 : 8) && a->slot == 1 && a->stages == 2u, "VS 常量缓冲长度表期望偏移 16 / 8 表长 1（实得 %d %d）", a ? (int)a->offset : -1, a ? (int)a->slot : -1);
    a = find_arg(p, GAL_ARG_UBOLEN, 0, GAL_UBOLEN_BINDING, 5); CHECK(a && a->offset == (oc ? 24 : 16) && a->slot == 20 && a->stages == 32u, "FS 常量缓冲长度表期望偏移 24 / 16 表长 20（实得 %d %d）", a ? (int)a->offset : -1, a ? (int)a->slot : -1);
    CHECK(p->nargs == (oc ? 10 : 8), "参数条目期望 %d（实得 %d）", oc ? 10 : 8, p->nargs);
    CHECK(p->stage_set_size[1][0] == (oc ? 24u : 16u) && p->stage_set_size[5][0] == (oc ? 32u : 24u) && p->stage_set_size[5][2] == 32 && p->stage_set_size[1][2] == 0,
          "各阶段集大小期望 VS0=24/16 FS0=32/24 FS2=32（实得 %u %u %u）", p->stage_set_size[1][0], p->stage_set_size[5][0], p->stage_set_size[5][2]);
    CHECK(p->set_size[0] == (oc ? 32u : 24u) && p->set_size[2] == 32 && p->set_stages[0] == (2u | 32u) && p->set_stages[2] == 32u, "set_size / set_stages 不符");
    CHECK(p->vs_inputs == 0x5 && p->vs_input_ctype[0] == 0 && p->vs_input_ctype[2] == 1, "顶点输入期望 位置 0（浮点）+ 2（无符号）（实得 %#x，类型 %u %u）", p->vs_inputs, p->vs_input_ctype[0], p->vs_input_ctype[2]);
    CHECK(p->fs_outputs == 0x1 && p->fs_output_ctype[0] == 0, "片元输出期望 位置 0 浮点（实得 %#x）", p->fs_outputs);
    CHECK(p->fs_color_round, "现翻片元程序应保留 half 颜色量化能力");
    CHECK(p->size_buf_index[1] == -1 && p->size_buf_index[5] == -1 && p->frag_output_map == 0xf, "size_buf_index / frag_output_map 不符");
    CHECK(!p->is_compute && p->fn[1] && p->fn[5] && !p->fn[0], "阶段函数不符");

    CHECK(draw(prog, g_pxA), "画图失败");
    // 期望：像素 (x,y) 用 FragCoord/4 取最近邻纹素 (x≥2, y≥2)；结果 = 纹素 × (1,0.6,0.2,1) × (1,1,1,0.4)，unorm8 = round(值 × 255)
    static const uint8_t want[4][4] = {{255, 0, 0, 102}, {0, 153, 0, 102}, {0, 0, 51, 102}, {255, 153, 51, 102}};   // 纹素 00 10 01 11
    int bad = 0;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        const uint8_t *w = want[(y >= 2) * 2 + (x >= 2)], *g = g_pxA + (y * 4 + x) * 4;
        if (memcmp(w, g, 4) && bad++ < 4) printf("  ✗ (%d,%d) 期望 %u %u %u %u 实得 %u %u %u %u\n", x, y, w[0], w[1], w[2], w[3], g[0], g[1], g[2], g[3]);
    }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d / 16 像素不符\n", bad); }
    else printf("  像素 16/16 与手算一致：(0,0)=%u,%u,%u,%u (3,0)=%u,%u,%u,%u (0,3)=%u,%u,%u,%u (3,3)=%u,%u,%u,%u\n",
                g_pxA[0], g_pxA[1], g_pxA[2], g_pxA[3], g_pxA[12], g_pxA[13], g_pxA[14], g_pxA[15], g_pxA[48], g_pxA[49], g_pxA[50], g_pxA[51], g_pxA[60], g_pxA[61], g_pxA[62], g_pxA[63]);
    g_snapA = take(p);
    // B（二进制往返 / 离线库）只在出包口径跑：计数开时不开离线库（gal_prog.m nxgal_prog_lib_open），离线库与现编布局也本就不同（现编多计数格）
    if (!g_nocount) { nxgal_prog_release(prog); return; }

    printf("· B 二进制往返：binary → release → 清缓存 + 关现编 → 未命中须干净失败 → 开离线库 → load_binary → 布局 / 像素与 A 相同\n");
    int32_t n = nxgal_prog_binary(prog, NULL, 0); CHECK(n > 20, "二进制长度 %d", n);
    uint8_t *bin = malloc(n > 0 ? n : 1); CHECK(nxgal_prog_binary(prog, bin, n) == n, "取二进制失败");
    printf("  二进制 %d 字节\n", n);
    {   // 进程里第一个调用就是 load_binary（Ryujinx 磁盘缓存先于任何 CreateProgram 载主机二进制）：离线库须已按 NXGAL_SHLIB_DIR 打开（10-19 动森帐篷黑：库在首个 create 时才开，之前载的程序全判未命中）
        char bf[1100], cmd[4096]; snprintf(bf, sizeof bf, "%s/first_load.bin", dir); FILE *f = fopen(bf, "wb"); if (f) { fwrite(bin, 1, (size_t)n, f); fclose(f); }
        snprintf(cmd, sizeof cmd, "NXGAL_SHLIB_DIR='%s/lib' '%s' --first-load '%s'", dir, g_argv0, bf); int rc = system(cmd);
        CHECK(f && rc == 0, "新进程首个调用 load_binary（NXGAL_SHLIB_DIR 已设）应从离线库建成（子进程 rc=%d）", rc); }
    {   // 包外着色器跨开机（10-20 各款每次开机 Ryujinx「Rebuilding N shaders」整份重写主机缓存）：上一进程现编并取二进制，下一进程首个调用 load_binary、
        // 不开离线库，只给同一个持久缓存目录 → 须建成；换成空目录 → 须失败（反证：建成靠的是持久缓存，不是别的路）
        char cd[1100], ed[1100], bf[1100], cmd[4096]; int rc;
        snprintf(cd, sizeof cd, "%s/xc_cache", dir); snprintf(ed, sizeof ed, "%s/xc_cache_empty", dir); snprintf(bf, sizeof bf, "%s/cache_fill.bin", dir);
        snprintf(cmd, sizeof cmd, "rm -rf '%s' '%s' '%s' && mkdir -p '%s'", cd, ed, bf, ed); system(cmd);
        snprintf(cmd, sizeof cmd, "NXGAL_SHADER_CACHE_DIR='%s' '%s' --cache-fill '%s' '%s'", cd, g_argv0, dir, bf); rc = system(cmd);
        CHECK(rc == 0, "子进程现编 + 取二进制失败（rc=%d）", rc);
        snprintf(cmd, sizeof cmd, "NXGAL_SHADER_CACHE_DIR='%s' '%s' --first-load '%s'", cd, g_argv0, bf); rc = system(cmd);
        CHECK(rc == 0, "新进程 load_binary（无离线库、有上一进程的持久缓存）应建成（子进程 rc=%d）", rc);
        snprintf(cmd, sizeof cmd, "NXGAL_SHADER_CACHE_DIR='%s' '%s' --first-load '%s' >/dev/null", ed, g_argv0, bf); rc = system(cmd);
        CHECK(rc != 0, "反证：持久缓存目录为空时 load_binary 应失败（子进程 rc=%d）", rc); }
    nxgal_prog_release(prog);
    CHECK(gal_prog_get(prog) == NULL, "释放后 gal_prog_get 应为空");
    nxgal_prog_cache_clear(); nxgal_prog_set_xc(0);
    uint32_t miss = create_vf(dir);
    CHECK(miss && nxgal_prog_status(miss, 1) == 1, "关现编且无离线库：建程序应 Failure（实得 %d）", nxgal_prog_status(miss, 1));
    CHECK(strstr(nxgal_prog_last_error(), "离线库未命中") != NULL, "未命中原因应是「离线库未命中」：%s", nxgal_prog_last_error());
    nxgal_prog_release(miss);
    uint32_t bad_bin = nxgal_prog_load_binary(bin, n, 1);
    CHECK(nxgal_prog_status(bad_bin, 1) == 1, "无离线库时 load_binary 应 Failure"); nxgal_prog_release(bad_bin);
    char ld[1024]; snprintf(ld, sizeof ld, "%s/lib", dir);
    CHECK(nxgal_prog_lib_open(ld) == 0, "开离线库失败：%s", nxgal_prog_last_error());
    uint32_t st0[6], st1[6]; nxgal_prog_stats(st0);
    uint32_t p2 = nxgal_prog_load_binary(bin, n, 1);
    nxgal_prog_stats(st1);
    CHECK(nxgal_prog_status(p2, 1) == 0, "load_binary 失败：%s", nxgal_prog_last_error());
    CHECK(st1[2] - st0[2] == 2 && st1[4] == st0[4], "load_binary 应从离线库取 2 支、不现编（离线命中 +%u，现编 +%u）", st1[2] - st0[2], st1[4] - st0[4]);
    gal_prog *q = gal_prog_get(p2);
    if (q) { snap sb = take(q); CHECK(snap_eq(&g_snapA, &sb), "load_binary 重建的布局与 A 不同"); }
    uint8_t pxB[64]; CHECK(draw(p2, pxB), "B 画图失败");
    CHECK(!memcmp(g_pxA, pxB, 64), "B 像素与 A 不同");
    if (!memcmp(g_pxA, pxB, 64)) printf("  B 像素与 A 逐字节相同（64 字节）\n");
    // 同一 SPIR-V 走离线库 create（不经二进制）也应得同一布局
    uint32_t p3 = create_vf(dir); gal_prog *r3 = gal_prog_get(p3);
    CHECK(r3 && !r3->status, "离线库 create 失败：%s", nxgal_prog_last_error());
    if (r3 && !r3->status) { snap s3 = take(r3); CHECK(snap_eq(&g_snapA, &s3), "离线库 create 的布局与现编不同"); }
    nxgal_prog_release(p2); nxgal_prog_release(p3);
    nxgal_prog_set_xc(1);
    free(bin);
}

// ---------- L：写层号 + 点大小的顶点着色器（10-18 八方2 两支管线建不出）----------
// Metal 规则（本机逐组合实测）：写层号的管线拓扑类别必须指定；写点大小的只能 Point / Unspecified → 两者都写时画线 / 三角形要用无点大小变体。
// 期望：现编与离线库两条路都带变体（vs_layer_np = 1、fn_np 名为 s<键>_np），三角形与点拓扑都建得出管线，三角形用的是变体
static uint32_t create_lf(const char *dir) {
    char p[1024]; uint32_t lv, lf;
    snprintf(p, sizeof p, "%s/vsl.spv", dir); void *vs = slurp(p, &lv);
    snprintf(p, sizeof p, "%s/fs.spv", dir); void *fs = slurp(p, &lf);
    if (!vs || !fs) { printf("  ✗ 读不了 %s 下的 vsl/fs.spv\n", dir); return 0; }
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    uint32_t id = nxgal_prog_create(sh, 2, NULL, 0, 0xf);
    free(vs); free(fs);
    return id;
}
static void t_layer(const char *dir) {
    printf("· L 写层号 + 点大小：现编 / 离线库都带无点大小变体；三角形 / 点拓扑都建得出管线\n");
    for (int pass = 0; pass < 2; pass++) {
        const char *how = pass ? "离线库" : "现编";
        nxgal_prog_set_xc(pass == 0);
        uint32_t id = create_lf(dir); gal_prog *pg = gal_prog_get(id);
        CHECK(pg && !pg->status, "%s 建程序失败：%s", how, nxgal_prog_last_error());
        if (!pg || pg->status) continue;
        CHECK(pg->vs_point_size && pg->vs_layer_np && pg->fn_np, "%s：期望写点大小 + 带变体，实得点大小 %d 变体 %d", how, pg->vs_point_size, pg->vs_layer_np);
        if (pg->fn_np) CHECK([pg->fn_np.name hasSuffix:@"_np"], "%s：变体函数名 %s 应以 _np 结尾", how, pg->fn_np.name.UTF8String);
        nxgal_set_render_targets(&g_rt, 1, 0);
        nxgal_set_program(id);
        nxgal_set_topology(4); CHECK(gal_pso_get(pg, NULL, NULL) != nil, "%s：三角形拓扑建管线失败", how);
        nxgal_set_topology(0); CHECK(gal_pso_get(pg, NULL, NULL) != nil, "%s：点拓扑建管线失败", how);
        nxgal_set_topology(4);
        nxgal_prog_release(id);
    }
    nxgal_prog_set_xc(1);
}

// ---------- C：计算 ----------
// 越界（gal_spvx.m）：静态计数按手写 SPIR-V 逐条数出；GPU 结果按「常量 / 存储缓冲越界读钳到末元素、共享内存钳到末元素、越界写与原子不执行 / 原子返回钳到元素的当前值、循环按工作量截断」手算；
// 循环上限手算：循环头标签到回边分支 = 头块 3 条 + 判断块 8 条（读 a[0] 的越界处理另加若干条，总数仍在 18–32）+ 循环体 4 条 + 续块 2 条 → 权重向上取 2 的幂 = 32；
// 单线程上限 = clamp(2^31 / 线程组数 / 4 线程, ≤ 2^18) × 16、下限 2^14：1 组 → 2^22 → 循环 2^17 次。按派发缩小 / 权重下限另用 csl.spv / csw.spv（见其文件头）
// 计数格按「4 个线程各有越界、各到过循环上限」手算（--count）；缺省（NXGAL_BOUNDS_COUNT=0，出包口径）：翻译不插计数收尾、输出不变、计数格不建
int gal_oob_read(uint64_t h, uint32_t out[4]);
static void t_bounds(const char *dir) {
    printf("· D 越界与循环上限：常量 / 存储缓冲越界读钳到末元素、x & 3 下标免钳、越界写与原子不执行、共享内存钳位、循环按工作量截到 2^17 次；计数%s\n", g_nocount ? "关" : "开");
    char p[1024]; uint32_t len; snprintf(p, sizeof p, "%s/cso.spv", dir); void *cs = slurp(p, &len);
    if (!cs) { CHECK(0, "读不了 cso.spv"); return; }
    // 静态：访问链 17 条 = 钳位 15（存储缓冲 12 条运行时数组下标 + 共享 3 条）+ 常量缓冲 2 条（d[i+2] 动态、d[0] 常量；d[0][i & 3] 的分量级可证在界内不钳）；
    //   被守卫的写 10 条、原子 2 条、循环回边 1 条、改不了 0（越界读只钳下标、不改值：11-01 撤掉读回 0）
    uint32_t st[GAL_SPVX_NSTAT] = {0}, nw = 0; uint32_t *h = gal_spv_harden(cs, len / 4, &nw, st); int got = h != NULL; free(h);
    CHECK(got && st[GAL_SPVX_CLAMP] == 15 && st[GAL_SPVX_UBO] == 2 && st[GAL_SPVX_STORE] == 10 && st[GAL_SPVX_ATOMIC] == 2 && st[GAL_SPVX_LOOP] == 1 && st[GAL_SPVX_SKIP] == 0,
          "改写计数期望 钳位 15 常量 2 写 10 原子 2 循环 1 跳过 0（实得 %u %u %u %u %u %u）", st[0], st[1], st[2], st[3], st[4], st[5]);
    nxgal_shader sh = {cs, len, 0};
    nxgal_res_desc d[] = {{0, 0, 1, 0, 1}, {1, 0, 1, 1, 1}, {1, 1, 1, 1, 1}};
    uint32_t prog = nxgal_prog_create(&sh, 1, d, 3, -1); free(cs);
    gal_prog *g = gal_prog_get(prog);
    CHECK(g && !g->status, "建计算程序失败：%s", nxgal_prog_last_error()); if (!g || g->status) return;
    MTL4ComputePipelineDescriptor *cd = [MTL4ComputePipelineDescriptor new]; cd.computeFunctionDescriptor = g->fn[0];
    NSError *e = nil; id<MTLComputePipelineState> ps = [g_gcomp newComputePipelineStateWithDescriptor:cd compilerTaskOptions:nil error:&e];
    CHECK(ps, "建计算管线失败：%s", e.localizedDescription.UTF8String); if (!ps) return;
    // a：同一块 64 字节里前 16 字节绑给着色器（10 11 12 13），后 48 字节是哨兵 77——越界读写若没拦住，读到 / 写坏的就是它
    id<MTLBuffer> ab = [g_gdev newBufferWithLength:64 options:MTLResourceStorageModeShared], ob = [g_gdev newBufferWithLength:128 options:MTLResourceStorageModeShared],
                  ub = [g_gdev newBufferWithLength:128 options:MTLResourceStorageModeShared];
    gal_res_add(ab); gal_res_add(ob); gal_res_add(ub);
    uint32_t *av = ab.contents; for (int i = 0; i < 16; i++) av[i] = i < 4 ? (uint32_t)(10 + i) : 77u;
    memset(ob.contents, 0xee, 128);
    uint32_t *uv = ub.contents; for (int k = 0; k < 8; k++) { uv[k * 4] = 1000u + k; uv[k * 4 + 1] = uv[k * 4 + 2] = uv[k * 4 + 3] = 0; }   // d[k].x = 1000+k，只绑前 3 个（48 字节）
    binds b; memset(&b, 0, sizeof b);
    b.ubo[0] = ub.gpuAddress; b.ubo_size[0] = 48; b.ssbo[0] = ab.gpuAddress; b.ssbo[1] = ob.gpuAddress;
    uint32_t *sz = gal_transient(8, 16, &b.sizes_tab); sz[0] = 16; sz[1] = 128;
    id<MTL4ComputeCommandEncoder> enc = gal_blit_enc();
    bind_stage(g, 0, g_ct, &b);
    [enc setArgumentTable:g_ct]; [enc setComputePipelineState:ps];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:g->threadgroup];
    gal_finish();
    uint32_t cell[4]; int have = gal_oob_read(g->stage_hash[0], cell);
    if (!g_nocount) {
        // 4 个线程每个都有越界（a[i+4] 读写、a[i+8] 原子 → 存储缓冲；wg[i+4] → 共享内存；线程 1–3 的 d[i+2] → 常量缓冲），每个都到过循环上限：
        //   格[0] 越界调用数 4，格[1] 类别位 = 常量缓冲 1 | 存储缓冲 2 | 共享内存 4 | 循环 32 = 39，格[2] 到上限调用数 4
        CHECK(have && cell[0] == 4 && cell[1] == 39 && cell[2] == 4, "计数格期望 越界 4 次 类别位 39 到上限 4 次（实得 有格 %d：%u %u %u）", have, cell[0], cell[1], cell[2]);
        CHECK(nxgal_bounds_report() == 1, "报数：有计数的着色器 1 支");
        if (have && cell[0] == 4) printf("  计数格 越界 %u 次 / 类别位 %u / 到上限 %u 次，与手算一致\n", cell[0], cell[1], cell[2]);
    } else CHECK(!have && nxgal_bounds_report() == 0, "计数关：期望不建计数格、报数 0（实得 有格 %d）", have);
    const uint32_t *o = ob.contents; int bad = 0;
    for (int i = 0; i < 4; i++) {
        const uint32_t want[8][2] = {{0, 13}, {4, 1002}, {8, 13}, {12, 0xeeeeeef3u}, {16, 23}, {20, 1u << 17}, {24, 0xeeeeeeeeu}, {28, i == 0 ? 1000u : 0u}};
        for (int k = 0; k < 8; k++) if (o[want[k][0] + i] != want[k][1] && bad++ < 6) printf("  ✗ o[%u] 期望 %u 实得 %u\n", want[k][0] + i, want[k][1], o[want[k][0] + i]);
    }
    for (int i = 0; i < 16; i++) { uint32_t w = i < 4 ? (uint32_t)(10 + i) : 77u; if (av[i] != w && bad++ < 8) printf("  ✗ a[%d]（%s）期望 %u 实得 %u\n", i, i < 4 ? "绑定区间" : "哨兵", w, av[i]); }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d 处不符\n", bad); }
    else printf("  32/32 输出与手算一致（存储越界读钳到 a[3] 13 / 常量越界钳到 d[2] 1002 / 越界原子回 a[3] 13 / 共享 23 / 循环 %u / 掩码分量 1000），哨兵 12/12 未被写\n", o[20]);
    // 整次派发封顶（csl.spv）：线程组数越多单线程上限越小；权重下限（csw.spv）：轻循环体允许的次数不超过旧口径 2^18。
    // 所有线程同样跑到上限，原子最大 = 最小 = 手算次数（手算见两支 .spvasm 文件头）
    {
        const struct { const char *f; uint32_t g, want; } cs[] = {{"csl", 1, 1u << 17}, {"csl", 65536, 4096}, {"csl", 1u << 20, 512}, {"csw", 1, 1u << 18}};
        for (int r = 0; r < 4; r++) {
            snprintf(p, sizeof p, "%s/%s.spv", dir, cs[r].f); void *cl = slurp(p, &len);
            CHECK(cl != NULL, "读不了 %s.spv", cs[r].f); if (!cl) continue;
            nxgal_shader sl = {cl, len, 0};
            nxgal_res_desc dl[] = {{1, 0, 1, 1, 1}, {1, 1, 1, 1, 1}};
            uint32_t pl = nxgal_prog_create(&sl, 1, dl, 2, -1); free(cl);
            gal_prog *gl = pl ? gal_prog_get(pl) : NULL;
            CHECK(gl && !gl->status, "建 %s 计算程序失败：%s", cs[r].f, nxgal_prog_last_error()); if (!gl || gl->status) continue;
            MTL4ComputePipelineDescriptor *cl_d = [MTL4ComputePipelineDescriptor new]; cl_d.computeFunctionDescriptor = gl->fn[0];
            id<MTLComputePipelineState> pls = [g_gcomp newComputePipelineStateWithDescriptor:cl_d compilerTaskOptions:nil error:&e];
            CHECK(pls, "建 %s 计算管线失败", cs[r].f); if (!pls) { nxgal_prog_release(pl); continue; }
            uint32_t *ov = ob.contents; ov[0] = 0; ov[1] = 0xffffffffu;
            // 长度表每次重分：上面 cso 那份是临时内存，gal_finish 后已回收复用（读成 0 时越界守卫会把原子写全跳过）
            uint32_t *sz2 = gal_transient(8, 16, &b.sizes_tab); sz2[0] = 16; sz2[1] = 128;
            id<MTL4ComputeCommandEncoder> e2 = gal_blit_enc();
            bind_stage(gl, 0, g_ct, &b);
            [e2 setArgumentTable:g_ct]; [e2 setComputePipelineState:pls];
            [e2 dispatchThreadgroups:MTLSizeMake(cs[r].g, 1, 1) threadsPerThreadgroup:gl->threadgroup];
            gal_finish();
            CHECK(ov[0] == cs[r].want && ov[1] == cs[r].want, "%s %u 组派发：每线程循环次数期望 %u（实得 最大 %u 最小 %u）", cs[r].f, cs[r].g, cs[r].want, ov[0], ov[1]);
            if (ov[0] == cs[r].want && ov[1] == cs[r].want) printf("  %s %u 组派发：每线程循环 %u 次（最大 = 最小），与手算一致\n", cs[r].f, cs[r].g, ov[0]);
            nxgal_prog_release(pl);
        }
    }
    gal_release_later(ab, 1); gal_release_later(ob, 1); gal_release_later(ub, 1);
    nxgal_prog_release(prog);
}
// 越界原子与读改写重试循环（csx.spv，手算见文件头）：越界读钳到 a[3] 读 13，越界的比较交换不执行、返回同一钳到元素的当前值 13 → 每线程第一圈退出，o[i] = 1；
//   a 的 4 个绑定元素与其后哨兵不变。反例（越界原子回 0 的旧口径）：r 永远 ≠ v，转到循环上限（直连无上限 = GPU 挂死，11-23 D-WZCF）
static void t_oob_cas(const char *dir) {
    printf("· D3 越界原子不让读改写重试循环空转：比较交换越界时返回钳到元素的当前值\n");
    char p[1024]; uint32_t len; snprintf(p, sizeof p, "%s/csx.spv", dir); void *cs = slurp(p, &len);
    if (!cs) { CHECK(0, "读不了 csx.spv"); return; }
    nxgal_shader sh = {cs, len, 0};
    nxgal_res_desc d[] = {{1, 0, 1, 1, 1}, {1, 1, 1, 1, 1}};
    uint32_t prog = nxgal_prog_create(&sh, 1, d, 2, -1); free(cs);
    gal_prog *g = prog ? gal_prog_get(prog) : NULL;
    CHECK(g && !g->status, "建 csx 计算程序失败：%s", nxgal_prog_last_error()); if (!g || g->status) return;
    MTL4ComputePipelineDescriptor *cd = [MTL4ComputePipelineDescriptor new]; cd.computeFunctionDescriptor = g->fn[0];
    NSError *e = nil; id<MTLComputePipelineState> ps = [g_gcomp newComputePipelineStateWithDescriptor:cd compilerTaskOptions:nil error:&e];
    CHECK(ps, "建 csx 计算管线失败：%s", e.localizedDescription.UTF8String); if (!ps) { nxgal_prog_release(prog); return; }
    id<MTLBuffer> ab = [g_gdev newBufferWithLength:64 options:MTLResourceStorageModeShared], ob = [g_gdev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    gal_res_add(ab); gal_res_add(ob);
    uint32_t *av = ab.contents; for (int i = 0; i < 16; i++) av[i] = i < 4 ? (uint32_t)(10 + i) : 77u;
    memset(ob.contents, 0xee, 16);
    binds b; memset(&b, 0, sizeof b); b.ssbo[0] = ab.gpuAddress; b.ssbo[1] = ob.gpuAddress;
    uint32_t *sz = gal_transient(8, 16, &b.sizes_tab); sz[0] = 16; sz[1] = 16;
    id<MTL4ComputeCommandEncoder> enc = gal_blit_enc();
    bind_stage(g, 0, g_ct, &b);
    [enc setArgumentTable:g_ct]; [enc setComputePipelineState:ps];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:g->threadgroup];
    gal_finish();
    const uint32_t *o = ob.contents; int bad = 0;
    for (int i = 0; i < 4; i++) if (o[i] != 1 && bad++ < 4) printf("  ✗ 线程 %d 循环 %u 圈（期望 1）\n", i, o[i]);
    for (int i = 0; i < 16; i++) { uint32_t w = i < 4 ? (uint32_t)(10 + i) : 77u; if (av[i] != w && bad++ < 8) printf("  ✗ a[%d] 期望 %u 实得 %u\n", i, w, av[i]); }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d 处不符\n", bad); }
    else printf("  4/4 线程各转 1 圈退出，a 的绑定区间与哨兵 16/16 未被写\n");
    gal_release_later(ab, 1); gal_release_later(ob, 1);
    nxgal_prog_release(prog);
}
// 循环上限的整次派发取值（gal_spvx.m spv_loop_guard）：由 NumWorkgroups 算出的值不得活过入口——只许在入口首块算完、写进共享内存、组内栅栏后读回再用。
// 10-21 怪猎 98e4eb43c87f2b1c：threadgroups_per_grid 算出的值活过约 1 万行的大循环，applegpu-nt（g18p 出包 / g17s 本机运行时）编码 abort「Failed to encode.」。
// 判据直接按数据流查（不跑被测实现推期望）：从 NumWorkgroups 的读出发，沿 SSA 操作数传递得到「派生值」集合 T（栅栏前）；
// 期望：入口里有 OpControlBarrier、T 非空、栅栏之后没有任何指令用到 T 里的值（循环比较用的是共享内存读回的新值）。旧翻译没有栅栏、回边比较直接用 T → 判红。
// 语义（不同派发规模下每线程循环次数）由 t_bounds 的 csl 用例在 GPU 上按手算核对，这里只验结构
static void t_nwg_launder(const char *dir) {
    printf("· D2 循环上限取值：NumWorkgroups 派生值不活过入口栅栏（怪猎 98e4eb43 编码崩溃的根因形态）\n");
    char p[1024]; uint32_t len; snprintf(p, sizeof p, "%s/csl.spv", dir); uint32_t *cs = slurp(p, &len);
    if (!cs) { CHECK(0, "读不了 csl.spv"); return; }
    uint32_t st[GAL_SPVX_NSTAT] = {0}, nw = 0; uint32_t *h = gal_spv_harden(cs, len / 4, &nw, st); free(cs);
    CHECK(h != NULL, "csl.spv 加固改写失败"); if (!h) return;
    uint32_t bound = h[3], nwg = 0, nt = 0, late = 0, first_late = 0; int barrier = 0;
    uint8_t *inT = calloc(bound, 1);
    for (uint32_t i = 5; i < nw; i += h[i] >> 16) {
        uint32_t n = h[i] >> 16, op = h[i] & 0xffff; if (!n) break;
        if (op == SpvOpDecorate && n == 4 && h[i + 2] == SpvDecorationBuiltIn && h[i + 3] == SpvBuiltInNumWorkgroups) nwg = h[i + 1];
        bool hr = false, ht = false; SpvHasResultAndType((SpvOp)op, &hr, &ht);
        uint32_t ri = hr ? (ht ? 2 : 1) : 0, a0 = 1 + (hr ? 1 : 0) + (ht ? 1 : 0);
        int uses = 0; for (uint32_t k = a0; k < n; k++) if (h[i + k] < bound && inT[h[i + k]]) uses = 1;
        if (!barrier) {
            if (op == SpvOpLoad && nwg && h[i + 3] == nwg && ri) { inT[h[i + ri]] = 1; nt++; }
            else if (uses && ri) { inT[h[i + ri]] = 1; nt++; }
            if (op == SpvOpControlBarrier) barrier = 1;
        } else if (uses && !late++) first_late = op;
    }
    free(inT); free(h);
    CHECK(nwg && barrier && nt >= 5 && late == 0, "期望 有 NumWorkgroups、入口有栅栏、派生值 ≥5 个（读 + 3 取分量 + 除）、栅栏后 0 处使用（实得 内建 %u 栅栏 %d 派生 %u 栅栏后使用 %u 处，首处操作码 %u）",
          nwg, barrier, nt, late, first_late);
    if (nwg && barrier && !late) printf("  派生值 %u 个全在栅栏前，栅栏后 0 处使用\n", nt);
}
// 片元输入上限（Apple GPU 片元最多 124 个输入分量）：声明 32 个 vec4（128 分量）只读 4 个 → 只保留实际读的、翻译成功且 MSL 里只有 4 个用户输入；
// 32 个全读 → 判失败报红（不交给 Metal：实测会让编译服务中断）
static void t_fragin(const char *dir) {
    printf("· E 片元输入上限：32 个 vec4 输入只读 4 个降级成功、全读判失败\n");
    for (int k = 0; k < 2; k++) {
        char p[1024]; uint32_t len; snprintf(p, sizeof p, "%s/../t_prog_fin/%s", dir, k ? "fs32r32.spv" : "fs32r4.spv"); void *spv = slurp(p, &len);
        if (!spv) { CHECK(0, "读不了 %s", p); continue; }
        char *msl = NULL; void *rec = NULL; uint32_t rl = 0; uint64_t h = 0;
        int ok = nxgal_prog_xc(spv, len, 1, &msl, &rec, &rl, &h);
        if (!k) {
            int nuser = 0; for (const char *q = msl; q && (q = strstr(q, "[[user(locn")); q++) nuser++;
            CHECK(ok && nuser == 4, "只读 4 个：期望翻译成功、MSL 用户输入 4 个（实得 成功 %d、%d 个）", ok, nuser);
            NSError *e = nil; id<MTLLibrary> lib = ok ? [g_gdev newLibraryWithSource:@(msl) options:[MTLCompileOptions new] error:&e] : nil;
            CHECK(lib != nil, "只读 4 个：MSL 编不过：%s", e.localizedDescription.UTF8String);
        } else CHECK(!ok && strstr(nxgal_prog_last_error(), "超 Apple GPU 上限 124"), "全读 32 个：期望判失败并说明超 124（实得 成功 %d：%s）", ok, nxgal_prog_last_error());
        free(msl); free(rec); free(spv);
    }
}
// Q 首遇现编排队（10-21 Mac 怪猎 / 暗黑2 / 暗黑3 / 巫师3 局 GPU 线程在 prog_finalize 停 60 秒）：后台现编槽全被占住时，
//   首用一支还在排队的着色器 → 期望等待线程就地编完、程序建成，不等槽；旧代码在这里永远等（30 秒闹钟判红）
void nxgal_test_xc_hold_slots(int on);
static void on_alarm(int s) { (void)s; printf("  ✗ Q：首用排队的作业 30 秒没编完（等后台槽）\n✗ 失败\n"); _exit(1); }
static void t_queued(const char *dir) {
    printf("· Q 首遇现编排队：后台槽全占时首用 → 等待线程就地编（计算程序 cs.spv）\n");
    char p[1024]; uint32_t len; snprintf(p, sizeof p, "%s/cs.spv", dir); void *cs = slurp(p, &len);
    if (!cs) { CHECK(0, "读不了 cs.spv"); return; }
    nxgal_shader sh = {cs, len, 0};
    nxgal_res_desc d[] = {{0, 0, 1, 0, 1 | 2 | 32}, {1, 0, 1, 1, 1}, {1, 1, 1, 1, 1}};
    nxgal_test_xc_hold_slots(1);
    uint32_t prog = nxgal_prog_create(&sh, 1, d, 3, -1); free(cs);
    signal(SIGALRM, on_alarm); alarm(30);
    gal_prog *g = gal_prog_get(prog);
    alarm(0); signal(SIGALRM, SIG_DFL);
    nxgal_test_xc_hold_slots(0);
    CHECK(g && !g->status, "槽全占时首用：期望程序建成（状态 0），实得 %d：%s", g ? g->status : -1, nxgal_prog_last_error());
}
static void t_compute(const char *dir) {
    printf("· C 计算：out[i] = in[i] × 乘数 + in.length()；16 个元素、线程组 4\n");
    char p[1024]; uint32_t len; snprintf(p, sizeof p, "%s/cs.spv", dir); void *cs = slurp(p, &len);
    if (!cs) { CHECK(0, "读不了 cs.spv"); return; }
    nxgal_shader sh = {cs, len, 0};
    nxgal_res_desc d[] = {{0, 0, 1, 0, 1 | 2 | 32}, {1, 0, 1, 1, 1}, {1, 1, 1, 1, 1}};
    uint32_t prog = nxgal_prog_create(&sh, 1, d, 3, -1); free(cs);
    gal_prog *g = gal_prog_get(prog);
    CHECK(g && !g->status, "建计算程序失败：%s", nxgal_prog_last_error()); if (!g || g->status) return;
    dump_args(g);
    // 手算：集 0 绑定 0 → 0、越界计数格 → 8、常量缓冲长度表 → 16；集 1：绑定 0（In）id 0 偏移 0 slot 0，绑定 1（Out）id 1 偏移 8 slot 1，长度表 id 2 偏移 16
    const gal_arg *a;
    a = find_arg(g, GAL_ARG_SSBO, 1, 0, 0); CHECK(a && a->offset == 0 && a->slot == 0, "In 期望偏移 0 slot 0");
    a = find_arg(g, GAL_ARG_SSBO, 1, 1, 0); CHECK(a && a->offset == 8 && a->slot == 1, "Out 期望偏移 8 slot 1");
    a = find_arg(g, GAL_ARG_SIZES, 1, 0xffff, 0); CHECK(a && a->offset == 16, "长度表期望在集 1 偏移 16");
    CHECK(g->stage_set_size[0][1] == 24 && g->stage_set_size[0][0] == (g_nocount ? 16u : 24u), "集大小期望 集0=24（计数关 16，无计数格）集1=24（实得 %u %u）", g->stage_set_size[0][0], g->stage_set_size[0][1]);
    CHECK(g->is_compute && g->threadgroup.width == 4 && g->threadgroup.height == 1 && g->threadgroup.depth == 1, "线程组期望 4×1×1");
    CHECK(g->size_buf_index[0] == 24, "入口签名的长度表参数期望在 24 号（实得 %d）", g->size_buf_index[0]);
    MTL4ComputePipelineDescriptor *cd = [MTL4ComputePipelineDescriptor new]; cd.computeFunctionDescriptor = g->fn[0];
    NSError *e = nil; id<MTLComputePipelineState> ps = [g_gcomp newComputePipelineStateWithDescriptor:cd compilerTaskOptions:nil error:&e];
    CHECK(ps, "建计算管线失败：%s", e.localizedDescription.UTF8String); if (!ps) return;
    id<MTLBuffer> in = [g_gdev newBufferWithLength:64 options:MTLResourceStorageModeShared], out = [g_gdev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    gal_res_add(in); gal_res_add(out);
    uint32_t *iv = in.contents; for (int i = 0; i < 16; i++) iv[i] = (uint32_t)(i * 7 + 1);
    memset(out.contents, 0xee, 64);
    binds b; memset(&b, 0, sizeof b);
    uint32_t *sbv = gal_transient(16, 16, &b.ubo[0]); sbv[0] = 3; sbv[1] = sbv[2] = sbv[3] = 0; b.ubo_size[0] = 16;
    b.ssbo[0] = in.gpuAddress; b.ssbo[1] = out.gpuAddress;
    uint32_t *sz = gal_transient(8, 16, &b.sizes_tab); sz[0] = 64; sz[1] = 64;   // 长度表[slot] = 绑定字节数
    id<MTL4ComputeCommandEncoder> enc = gal_blit_enc();
    bind_stage(g, 0, g_ct, &b);
    [enc setArgumentTable:g_ct]; [enc setComputePipelineState:ps];
    [enc dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:g->threadgroup];
    gal_finish();
    const uint32_t *ov = out.contents; int bad = 0;
    for (int i = 0; i < 16; i++) { uint32_t w = (uint32_t)(i * 7 + 1) * 3 + 16; if (ov[i] != w && bad++ < 4) printf("  ✗ out[%d] 期望 %u 实得 %u\n", i, w, ov[i]); }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d / 16 不符\n", bad); }
    else printf("  out[0..3] = %u %u %u %u，out[15] = %u（16/16 与手算一致）\n", ov[0], ov[1], ov[2], ov[3], ov[15]);
    gal_release_later(in, 1); gal_release_later(out, 1);
    nxgal_prog_release(prog);
}

// ---------- S：共享内存溢出（gal_prog.m spill_msl + gal_draw.m nxgal_dispatch 槽 27）----------
// 手写 SPIR-V（t_prog_csspill.spvasm）：big[9216]（36864 字节）+ small[16]（64 字节）= 36928 > 32 KB → big 溢出到设备内存、small 留在线程组内存。
// 走 nxgal_set_program / nxgal_set_storage_buffers / nxgal_dispatch 全路径派发 4 组 × 256 线程；期望值按 GLSL 语义手算：
//   o[g*256+l] = g*65536 + (9215 − 36l) + (l == 0 ? 256 : 0) + ((3·(l&15) + g) << 24)
// 各组溢出段若重叠，组号 g 会串、big[9215] 的原子加会超过 256；屏障若对溢出段不可见，读到的是别的线程没写完的格
static void t_spill(const char *dir) {
    printf("· S 共享内存溢出：36928 字节共享内存（> 32 KB）的计算着色器，最大数组改放设备内存，4 组 × 256 线程派发结果对手算\n");
    char p[1024]; uint32_t len; snprintf(p, sizeof p, "%s/csspill.spv", dir); void *cs = slurp(p, &len);
    if (!cs) { CHECK(0, "读不了 csspill.spv"); return; }
    char *msl = NULL; void *rec = NULL; uint32_t rl = 0; uint64_t h = 0;
    int ok = nxgal_prog_xc(cs, len, 1, &msl, &rec, &rl, &h);
    CHECK(ok && msl && strstr(msl, "device spvUnsafeArray<uint, 9216>&") && strstr(msl, "threadgroup spvUnsafeArray<uint, 16>") && strstr(msl, "(device atomic_uint*)") &&
          !strstr(msl, "threadgroup spvUnsafeArray<uint, 9216>") && strstr(msl, "threadgroup_barrier(mem_flags::mem_device | "),
          "MSL 期望 big 改设备引用、small 留线程组、原子转 device、屏障带 mem_device（翻译 %d：%s）", ok, ok ? "见 MSL" : nxgal_prog_last_error());
    free(msl); free(rec);
    nxgal_shader sh = {cs, len, 0};
    nxgal_res_desc d[] = {{1, 0, 1, 1, 1}};
    uint32_t prog = nxgal_prog_create(&sh, 1, d, 1, -1); free(cs);
    gal_prog *g = gal_prog_get(prog);
    CHECK(g && !g->status, "建计算程序失败：%s", nxgal_prog_last_error()); if (!g || g->status) return;
    CHECK(g->cs_spill == 36864, "每线程组溢出字节期望 36864（9216 × 4，16 对齐），实得 %u", g->cs_spill);
    CHECK(g->threadgroup.width == 256, "线程组期望 256，实得 %lu", (unsigned long)g->threadgroup.width);
    uint32_t ob = nxgal_buf_create(4 * 1024, 0); uint32_t fill[1024]; memset(fill, 0xee, sizeof fill); nxgal_buf_set_data(ob, 0, fill, (int32_t)sizeof fill);
    nxgal_buf_assign sa = {0, {ob, 0, 4 * 1024, 1}}; nxgal_set_storage_buffers(&sa, 1);
    nxgal_set_program(prog); nxgal_dispatch(4, 1, 1);
    uint32_t o[1024]; CHECK(nxgal_buf_get_data(ob, 0, (int32_t)sizeof o, o) == 0, "读回存储缓冲失败");
    int bad = 0;
    for (uint32_t gi = 0; gi < 4; gi++) for (uint32_t l = 0; l < 256; l++) {
        uint32_t w = gi * 65536u + (9215u - 36u * l) + (l == 0 ? 256u : 0u) + ((3u * (l & 15u) + gi) << 24);
        if (o[gi * 256 + l] != w && bad++ < 6) printf("  ✗ o[%u]（组 %u 线程 %u）期望 %u 实得 %u\n", gi * 256 + l, gi, l, w, o[gi * 256 + l]);
    }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d / 1024 不符\n", bad); }
    else printf("  1024/1024 与手算一致（o[0] = %u = 0 + 9215 + 256 原子 + 0；o[1023] = %u）\n", o[0], o[1023]);
    nxgal_buf_delete(ob); nxgal_prog_release(prog);
}

// ---------- D：语料 ----------
typedef struct { char file[64]; nxgal_shader sh[6]; void *code[6]; int nsh; nxgal_res_desc *d; int nd; int fmap; } cprog;
static int load_cprog(const char *dir, const char *name, cprog *c) {
    memset(c, 0, sizeof *c); snprintf(c->file, sizeof c->file, "%s", name);
    char p[1024]; snprintf(p, sizeof p, "%s/%s", dir, name);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    char ln[512]; int cap = 0;
    while (fgets(ln, sizeof ln, f)) {
        int st; char fn[128]; int a, b2, cc, t, s;
        if (sscanf(ln, "stage %d %127s", &st, fn) == 2 && c->nsh < 6) {
            snprintf(p, sizeof p, "%s/%s", dir, fn); uint32_t L; void *code = slurp(p, &L);
            if (!code) { fclose(f); return 0; }
            c->code[c->nsh] = code; c->sh[c->nsh++] = (nxgal_shader){code, L, st};
        } else if (sscanf(ln, "fragmap %d", &a) == 1) c->fmap = a;
        else if (sscanf(ln, "desc %d %d %d %d %d", &a, &b2, &cc, &t, &s) == 5) {
            if (c->nd == cap) { cap = cap ? cap * 2 : 512; c->d = realloc(c->d, cap * sizeof *c->d); }
            c->d[c->nd++] = (nxgal_res_desc){a, b2, cc, t, s};
        }
    }
    fclose(f); return c->nsh > 0;
}
static void free_cprog(cprog *c) { for (int i = 0; i < c->nsh; i++) free(c->code[i]); free(c->d); }
static int namecmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// 布局自洽：同一阶段同一集内成员区间 [offset, offset + 8×count) 不重叠、不越过该阶段该集大小
static int layout_sane(const gal_prog *p, char *why) {
    for (int st = 0; st < 6; st++) for (int s = 0; s < GAL_MAX_SETS; s++) {
        for (int i = 0; i < p->nargs; i++) {
            const gal_arg *a = &p->args[i]; if (a->set != s || !(a->stages >> st & 1)) continue;
            if (a->offset + 8 * a->count > p->stage_set_size[st][s]) { snprintf(why, 200, "阶段 %d 集 %d 绑定 %u 越界（%u+8×%u > %u）", st, s, a->binding, a->offset, a->count, p->stage_set_size[st][s]); return 0; }
            for (int j = i + 1; j < p->nargs; j++) {
                const gal_arg *b = &p->args[j]; if (b->set != s || !(b->stages >> st & 1)) continue;
                if (a->offset < b->offset + 8 * b->count && b->offset < a->offset + 8 * a->count) { snprintf(why, 200, "阶段 %d 集 %d 绑定 %u 与 %u 重叠", st, s, a->binding, b->binding); return 0; }
            }
        }
    }
    return 1;
}

static void t_corpus(const char *dir) {
    printf("· D 语料（%s）\n", dir);
    DIR *dd = opendir(dir); if (!dd) { CHECK(0, "打不开语料目录"); return; }
    char **names = NULL; int nn = 0; struct dirent *de;
    while ((de = readdir(dd))) if (!strncmp(de->d_name, "prog_", 5)) { names = realloc(names, (nn + 1) * sizeof *names); names[nn++] = strdup(de->d_name); }
    closedir(dd); qsort(names, nn, sizeof *names, namecmp);
    nxgal_prog_cache_clear(); nxgal_prog_set_xc(1);
    snap *snaps = calloc(nn, sizeof *snaps); int *okv = calloc(nn, sizeof *okv);
    int ok = 0, nsh = 0, nst[6] = {0}, insane = 0, ncs = 0, ncs_ok = 0, nsizes = 0;
    char cls[16][64]; int ncls = 0, clsn[16] = {0}; char clsex[16][300];
    NSDate *t0 = [NSDate date];
    for (int i = 0; i < nn; i++) {
        cprog c; if (!load_cprog(dir, names[i], &c)) { CHECK(0, "读不了 %s", names[i]); continue; }
        nsh += c.nsh; for (int k = 0; k < c.nsh; k++) nst[c.sh[k].stage]++;
        @autoreleasepool {
            uint32_t pid = nxgal_prog_create(c.sh, c.nsh, c.d, c.nd, c.fmap);
            gal_prog *p = gal_prog_get(pid);
            if (p && !p->status) {
                char why[200];
                if (!layout_sane(p, why)) { insane++; if (insane == 1) printf("  ✗ 布局自洽检查失败首例 %s：%s\n", names[i], why); }
                for (int k = 0; k < p->nargs; k++) if (p->args[k].kind == GAL_ARG_SIZES) { nsizes++; break; }
                if (p->is_compute) {
                    ncs++;
                    MTL4ComputePipelineDescriptor *cd = [MTL4ComputePipelineDescriptor new]; cd.computeFunctionDescriptor = p->fn[0];
                    NSError *e = nil; id<MTLComputePipelineState> ps = [g_gcomp newComputePipelineStateWithDescriptor:cd compilerTaskOptions:nil error:&e];
                    if (ps) ncs_ok++; else if (ncs - ncs_ok == 1) printf("  ✗ 计算管线失败首例 %s：%s\n", names[i], e.localizedDescription.UTF8String);
                }
                snaps[i] = take(p); okv[i] = 1; ok++;
            } else {
                const char *err = nxgal_prog_last_error(); char k[64]; const char *bar = strstr(err, "｜");
                size_t L = bar ? (size_t)(bar - err) : strlen(err); if (L > 63) L = 63; memcpy(k, err, L); k[L] = 0;
                int ci = -1; for (int j = 0; j < ncls; j++) if (!strcmp(cls[j], k)) ci = j;
                if (ci < 0 && ncls < 16) { ci = ncls++; strcpy(cls[ci], k); snprintf(clsex[ci], sizeof clsex[ci], "%s：%s", names[i], err); }
                if (ci >= 0) clsn[ci]++;
            }
            nxgal_prog_release(pid);
        }
        free_cprog(&c);
    }
    double dt = -[t0 timeIntervalSinceNow];
    uint32_t st[6]; nxgal_prog_stats(st);
    printf("  程序 %d 个（着色器 %d 支：计算 %d / 顶点 %d / 片元 %d），现编建成 %d / %d（%.1f%%），用时 %.1f 秒（现编 %u 支）\n",
           nn, nsh, nst[0], nst[1], nst[5], ok, nn, nn ? 100.0 * ok / nn : 0, dt, st[4]);
    for (int j = 0; j < ncls; j++) printf("  失败类「%s」%d 个，首例 %s\n", cls[j], clsn[j], clsex[j]);
    printf("  布局自洽：%d / %d 通过；含缓冲长度表的程序 %d 个；计算管线 %d / %d 建成\n", ok - insane, ok, nsizes, ncs_ok, ncs);
    CHECK(ok == nn, "语料现编未全过（%d / %d）", ok, nn);
    CHECK(!insane, "布局自洽失败 %d 个", insane);
    CHECK(ncs_ok == ncs, "计算管线失败 %d 个", ncs - ncs_ok);

    // 离线库：关现编、清缓存，重建全部 + 二进制往返，布局须与现编逐字节相同
    char ld[1024], lm[1024]; snprintf(ld, sizeof ld, "%s/lib", dir); snprintf(lm, sizeof lm, "%s/lib/gal.shards", dir);
    if (access(lm, R_OK)) { printf("  （没有语料离线库 %s，跳过离线比对）\n", lm); CHECK(0, "缺语料离线库"); goto done; }
    nxgal_prog_cache_clear(); nxgal_prog_set_xc(0);
    CHECK(nxgal_prog_lib_open(ld) == 0, "开语料离线库失败：%s", nxgal_prog_last_error());
    int same = 0, bsame = 0, tried = 0;
    for (int i = 0; i < nn; i++) {
        if (!okv[i]) continue;
        cprog c; if (!load_cprog(dir, names[i], &c)) continue;
        tried++;
        @autoreleasepool {
            uint32_t pid = nxgal_prog_create(c.sh, c.nsh, c.d, c.nd, c.fmap); gal_prog *p = gal_prog_get(pid);
            if (p && !p->status) {
                snap s = take(p); if (snap_eq(&snaps[i], &s)) same++; else if (tried - same == 1) printf("  ✗ 离线库布局与现编不同首例 %s\n", names[i]);
                free(s.args);
                int32_t n = nxgal_prog_binary(pid, NULL, 0); uint8_t *bin = malloc(n > 0 ? n : 1); nxgal_prog_binary(pid, bin, n);
                uint32_t id2 = nxgal_prog_load_binary(bin, n, p->fn[5] != nil); gal_prog *p2 = gal_prog_get(id2);
                if (p2 && !p2->status) { snap s2 = take(p2); if (snap_eq(&snaps[i], &s2)) bsame++; free(s2.args); }
                free(bin); nxgal_prog_release(id2);
            } else if (tried - same == 1) printf("  ✗ 离线库建程序失败首例 %s：%s\n", names[i], nxgal_prog_last_error());
            nxgal_prog_release(pid);
        }
        free_cprog(&c);
    }
    printf("  离线库（不现编）：重建 %d / %d 布局与现编逐字节相同；二进制往返 %d / %d 相同\n", same, tried, bsame, tried);
    CHECK(same == tried && bsame == tried, "离线库 / 二进制往返与现编不一致");
    nxgal_prog_set_xc(1);
done:
    for (int i = 0; i < nn; i++) { free(names[i]); free(snaps[i].args); }
    free(names); free(snaps); free(okv);
}

// ---------- R：管线归档按需开片 + 「管线描述 → 片号」索引 + 低区账本接入（10-21 巫师3 起局崩：138 片归档 1032 MB 开局全开吃光低区）----------
// 本单测自造本机归档：3 支计算着色器（cs / cso / csspill）现编，各用一个挂「收二进制」序列化器的编译器建一次计算管线、各存一片 gal_pso.<本机架构>.macos<大版本>.<i>.bin，
//   再写索引 gal_pso.idx（键 = FNV-1a 64(函数名)，本单测按定义自己算）。Mac 上 MTL4Archive 打开时按文件 1:1 占地址（原生层线实测），映射量直接按区域文件名数（proc_pidinfo）。
// 仿 iPhone 低区上限 L = 1.5 × 最大片（按 16 KB 页取整）：拦下设备的 newArchiveWithURL:error:，已映射 + 本片 > L 就返回空 + 「unable to open file」；
//   本测试程序导出一个仿真账本 s2a_lowva（被测代码运行时 dlsym 取到它）：acquire 按实际映射判，超了先回调使用者的腾退（登记了才有），腾不出返回 -1。
// 期望（手算，10-21 起本表开了不关、不登记腾退：iPhone 上关片不还地址，gal_core.m 归档段头注释）：开目录成功；3 支 × 2 轮按 0 1 2 0 1 2 建计算管线，
//   L 只容 1 片：第一次的片 0 开成并命中，片 1 / 2 账本不给 → 现建；第二轮片 0 已开着命中、片 1 / 2 照旧现建 → 命中 2、现建 4、开片 1 次；
//   拦截层开失败 0、账本 fail 0；任何时刻已映射 ≤ L。反证：旧代码（腾退关片）6 次全部命中、开片 6 次；更早的开目录即全开：第 2 片开失败
static uint64_t g_ra_cap, g_ra_peak, g_ra_failopen, g_ra_lvfail, g_ra_badtry; static IMP g_ra_orig;
static uint64_t ra_mapped(void) {
    uint64_t tot = 0; uint64_t a = 0; struct proc_regionwithpathinfo ri;
    for (;;) { int n = proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, a, &ri, sizeof ri); if (n <= 0) break;
        if (strstr(ri.prp_vip.vip_path, "/gal_pso.")) tot += ri.prp_prinfo.pri_size;
        a = ri.prp_prinfo.pri_address + ri.prp_prinfo.pri_size; }
    if (tot > g_ra_peak) g_ra_peak = tot; return tot;
}
static id ra_newarch(id self, SEL _cmd, NSURL *u, NSError **e) {
    uint64_t b = ([[NSFileManager defaultManager] attributesOfItemAtPath:u.path error:nil].fileSize + 16383) & ~16383ull;
    if ([u.path hasSuffix:@".3.bin"]) g_ra_badtry++;
    if (ra_mapped() + b > g_ra_cap) { g_ra_failopen++; if (e) *e = [NSError errorWithDomain:@"sim" code:1 userInfo:@{NSLocalizedDescriptionKey: @"unable to open file（仿 iPhone 低区映射不下）"}]; return nil; }
    id a = ((id (*)(id, SEL, NSURL *, NSError **))g_ra_orig)(self, _cmd, u, e); ra_mapped(); return a;
}
typedef uint64_t (*ra_evict_fn)(void *, uint64_t);
static ra_evict_fn g_ra_ev; static void *g_ra_ctx;
static int ra_user(const char *n, ra_evict_fn ev, void *ctx) { (void)n; g_ra_ev = ev; g_ra_ctx = ctx; return 1; }
static int ra_acquire(int u, uint64_t bytes, uint64_t contig, int opt, const char *what) {
    (void)u; (void)contig; (void)opt; (void)what; uint64_t need = (bytes + 16383) & ~16383ull;
    // 同原生层账本（runtime/src/lowva.c）：腾退回调返回后，映射真放掉有延迟（Metal 释放归档非同步），等回落最多 2 秒再判；
    //   10-21 起初不等，6 遍里 3 遍误判「不够」拒开、现建（门禁里偶发红）
    while (ra_mapped() + need > g_ra_cap && g_ra_ev && g_ra_ev(g_ra_ctx, ra_mapped() + need - g_ra_cap)) {
        for (int w = 0; w < 200 && ra_mapped() + need > g_ra_cap; w++) usleep(10000);
    }
    return ra_mapped() + need > g_ra_cap ? -1 : 0;
}
static void ra_note(int u, int64_t d) { (void)u; (void)d; }
static void ra_fail(int u, uint64_t b, const char *w) { (void)u; (void)b; (void)w; g_ra_lvfail++; }
// 账本快照：报地址 / 句柄都够（坏文件用例要走「按文件本身坏处理」那条路）
static void ra_snap(uint64_t *t, uint64_t *b, uint64_t *r, uint64_t *x, uint64_t *y) { *t = *b = 1ull << 40; *r = *x = *y = 0; }
static struct { uint32_t size, version; void *user, *acquire, *note, *fail, *snapshot; } g_ra_api = {sizeof g_ra_api, 1, ra_user, ra_acquire, ra_note, ra_fail, ra_snap};
__attribute__((visibility("default"), used)) const void *s2a_lowva(void) { return g_ra_cap ? &g_ra_api : NULL; }
static uint64_t ra_fnv(const char *t) { uint64_t x = 0xcbf29ce484222325ull; for (; *t; t++) x = (x ^ (unsigned char)*t) * 0x100000001b3ull; return x; }
static int t_arch_lazy(const char *dir, int lru) {
    if (lru) printf("· R2 管线归档腾退（NXGAL_PSO_ARCH_CAP_MB 只容 1 片，账本不设限）：3 支 × 2 轮，每次开新片先放掉最冷那片\n");
    else printf("· R 管线归档按需开片：自造 3 片本机归档 + 索引，仿 iPhone 低区上限只容 1 片，3 支 × 2 轮建计算管线\n");
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    if (nxgal_init(0)) return 3;
    @autoreleasepool {
        setup_draw();
        char ad[1100]; snprintf(ad, sizeof ad, "%s/arch_lazy", dir); char cmd[1300]; snprintf(cmd, sizeof cmd, "rm -rf '%s' && mkdir -p '%s'", ad, ad); system(cmd);
        long major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        const char *cf[3] = {"cs.spv", "cso.spv", "csspill.spv"}; nxgal_res_desc cd3[3][3] = {{{0, 0, 1, 0, 1 | 2 | 32}, {1, 0, 1, 1, 1}, {1, 1, 1, 1, 1}}, {{0, 0, 1, 0, 1}, {1, 0, 1, 1, 1}, {1, 1, 1, 1, 1}}, {{1, 0, 1, 1, 1}}};
        int ncd[3] = {3, 3, 1}; id fn[3] = {nil, nil, nil}; uint64_t key[3], mx = 0;
        for (int i = 0; i < 3; i++) {
            char pth[1100]; uint32_t len; snprintf(pth, sizeof pth, "%s/%s", dir, cf[i]); void *cs = slurp(pth, &len); if (!cs) { CHECK(0, "读不了 %s", cf[i]); return 1; }
            nxgal_shader sh = {cs, len, 0}; uint32_t pr = nxgal_prog_create(&sh, 1, cd3[i], ncd[i], -1); free(cs);
            gal_prog *g = pr ? gal_prog_get(pr) : NULL; if (!g || g->status) { CHECK(0, "建 %s 失败：%s", cf[i], nxgal_prog_last_error()); return 1; }
            fn[i] = g->fn[0]; key[i] = ra_fnv([fn[i] name].UTF8String);
            MTL4PipelineDataSetSerializerDescriptor *sd = [MTL4PipelineDataSetSerializerDescriptor new]; sd.configuration = MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
            id<MTL4PipelineDataSetSerializer> ser = [g_gdev newPipelineDataSetSerializerWithDescriptor:sd];
            MTL4CompilerDescriptor *ccd = [MTL4CompilerDescriptor new]; ccd.pipelineDataSetSerializer = ser; NSError *e = nil;
            id<MTL4Compiler> comp = [g_gdev newCompilerWithDescriptor:ccd error:&e];
            MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new]; d.computeFunctionDescriptor = fn[i];
            id ps = [comp newComputePipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e]; CHECK(ps, "自造归档：建管线失败 %s", e.localizedDescription.UTF8String);
            NSString *out = [NSString stringWithFormat:@"%s/gal_pso.%@.macos%ld.%d.bin", ad, g_gdev.architecture.name, major, i];
            CHECK([ser serializeAsArchiveAndFlushToURL:[NSURL fileURLWithPath:out] error:&e], "自造归档：存档失败 %s", e.localizedDescription.UTF8String);
            uint64_t sz = [[NSFileManager defaultManager] attributesOfItemAtPath:out error:nil].fileSize; if (sz > mx) mx = sz;
        }
        // 索引：按键升序
        int ord[3] = {0, 1, 2}; for (int a = 0; a < 3; a++) for (int b = a + 1; b < 3; b++) if (key[ord[b]] < key[ord[a]]) { int t = ord[a]; ord[a] = ord[b]; ord[b] = t; }
        NSMutableData *ix = [NSMutableData data]; uint32_t hd[4] = {0x49535047u, 1, 3, 0}; [ix appendBytes:hd length:16];
        for (int a = 0; a < 3; a++) { uint32_t c[2] = {(uint32_t)ord[a], 0}; [ix appendBytes:&key[ord[a]] length:8]; [ix appendBytes:c length:8]; }
        [ix writeToFile:[NSString stringWithFormat:@"%s/gal_pso.idx", ad] atomically:YES];
        g_ra_cap = ((mx + 16383) & ~16383ull) * 3 / 2;
        uint64_t lru_cap = g_ra_cap;
        if (lru) { char v[64]; snprintf(v, sizeof v, "%.6f", lru_cap / 1048576.0); setenv("NXGAL_PSO_ARCH_CAP_MB", v, 1); g_ra_cap = 1ull << 34; }   // 腾退上限只容 1 片；账本 / 拦截层不设限
        printf("  3 片最大 %llu 字节，仿低区上限 %llu 字节（只容 1 片）\n", (unsigned long long)mx, (unsigned long long)g_ra_cap);
        Method m = class_getInstanceMethod([g_gdev class], @selector(newArchiveWithURL:error:)); g_ra_orig = method_setImplementation(m, (IMP)ra_newarch);
        CHECK(nxgal_pso_archive_open_dir(ad) == 0, "开归档目录失败（旧代码开目录即全开、第 2 片超仿真上限即在此失败）");
        uint64_t s0[4], s1[4]; nxgal_pso_cache_stats(s0);
        for (int r = 0; r < 2; r++) for (int i = 0; i < 3; i++) @autoreleasepool {
            MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new]; d.computeFunctionDescriptor = fn[i]; NSError *e = nil;
            CHECK(gal_new_compute_pso(d, &e), "第 %d 轮 %s 计算管线建不出：%s", r, cf[i], e.localizedDescription.UTF8String);
            CHECK(ra_mapped() <= g_ra_cap, "第 %d 轮 %s 后已映射 %llu > 仿真上限", r, cf[i], (unsigned long long)ra_mapped());
        }
        nxgal_pso_cache_stats(s1); uint64_t as[5]; void gal_pso_arch_stats(uint64_t out[5]); gal_pso_arch_stats(as);
        if (lru) {
            // 期望（手算）：每次都从归档取（命中 6、现建 0）；每次换片都要先放掉上一片：开片 6、腾退 5；放掉的片真解映射（Mac：等 2 秒内），收尾已映射 ≤ 上限
            // 期望（不变式，与各片大小无关）：每次都从归档取（命中 6、现建 0）；至少换了 3 次片（3 支轮流、上限只容 1 片最大的）；账面已开 ≤ 上限；
            //   真解映射：收尾时实际映射着的归档片文件数 = 开片 − 放片（放掉的片不再映射；Mac 等至多 10 秒），索引文件 gal_pso.idx 不算
            int nmap = 0, waited = 0;
            for (; waited < 1000; waited++) { nmap = 0; uint64_t aa = 0; struct proc_regionwithpathinfo ri;
                for (;;) { int nn = proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, aa, &ri, sizeof ri); if (nn <= 0) break;
                    const char *b = strrchr(ri.prp_vip.vip_path, '/'); if (b && strstr(b, "/gal_pso.") && strstr(b, ".bin")) nmap++; aa = ri.prp_prinfo.pri_address + ri.prp_prinfo.pri_size; }
                if ((uint64_t)nmap <= as[0] - as[1]) break; usleep(10000); }
            CHECK(s1[0] - s0[0] == 6 && s1[1] - s0[1] == 0, "腾退：期望命中 6、现建 0（实得命中 %llu、现建 %llu）", (unsigned long long)(s1[0] - s0[0]), (unsigned long long)(s1[1] - s0[1]));
            CHECK(as[0] == 6 && as[1] >= 3 && as[4] <= lru_cap, "腾退：期望开片 6、放片 ≥ 3、账面已开 ≤ 上限（实得 %llu / %llu / %llu 字节，上限 %llu）", (unsigned long long)as[0], (unsigned long long)as[1], (unsigned long long)as[4], (unsigned long long)lru_cap);
            CHECK((uint64_t)nmap == as[0] - as[1], "腾退：放掉的片真解映射：实际映射着 %d 片 = 开片 − 放片 %llu（等了 %d0 ms；Mac 实测，iPhone 另由真机读数定）", nmap, (unsigned long long)(as[0] - as[1]), waited);
            nxgal_shutdown(); printf("%s %d/%d\n", g_fail ? "✗ 失败" : "✓ 全过", g_checks - g_fail, g_checks); return g_fail ? 1 : 0;
        }
        CHECK(s1[0] - s0[0] == 2 && s1[1] - s0[1] == 4, "期望命中 2、现建 4（开了不关：只容 1 片时片 1 / 2 账本不给）（实得命中 %llu、现建 %llu）", (unsigned long long)(s1[0] - s0[0]), (unsigned long long)(s1[1] - s0[1]));
        CHECK(as[0] == 1 && as[1] == 0, "期望开片 1 次、关片 0 次（实得 %llu / %llu）", (unsigned long long)as[0], (unsigned long long)as[1]);
        CHECK(g_ra_failopen == 0 && g_ra_lvfail == 0, "期望开失败 0、账本 fail 0（实得 %llu / %llu）", (unsigned long long)g_ra_failopen, (unsigned long long)g_ra_lvfail);
        CHECK(g_ra_peak <= g_ra_cap, "已映射峰值 %llu 应 ≤ 仿真上限 %llu", (unsigned long long)g_ra_peak, (unsigned long long)g_ra_cap);
        // 打不开的片：索引里 cs 改指第 3 片，重登记后连建两次 cs —— 期望不调账本 fail（不杀游戏）、两次都现建、这片只试开 1 次（之后作废不再开）。
        //   造法：登记时第 3 片是一份正常归档的拷贝（目录里有、有大小），登记后删掉文件，打开必然确定地返回空。
        //   不用写垃圾字节：10-21 门禁实测 14 字节垃圾有时让 Metal 在 MTL4ArchiveImpl::loadFromURL 里段错误、把单测进程带崩（有时只报「unable to find slice」），不确定
        {
            // 重登记保留旧片映射；给坏片另留一片空间，让它实际试开而非先被账本拒绝。
            g_ra_cap = ra_mapped() + ((mx + 16383) & ~16383ull);
            NSString *bad = [NSString stringWithFormat:@"%s/gal_pso.%@.macos%ld.3.bin", ad, g_gdev.architecture.name, major];
            [[NSFileManager defaultManager] copyItemAtPath:[NSString stringWithFormat:@"%s/gal_pso.%@.macos%ld.0.bin", ad, g_gdev.architecture.name, major] toPath:bad error:nil];
            NSMutableData *ix2 = [ix mutableCopy]; uint8_t *q = (uint8_t *)ix2.mutableBytes + 16;
            for (int a = 0; a < 3; a++) { uint64_t kk; memcpy(&kk, q + a * 16, 8); if (kk == key[0]) { uint32_t c3 = 3; memcpy(q + a * 16 + 8, &c3, 4); } }
            [ix2 writeToFile:[NSString stringWithFormat:@"%s/gal_pso.idx", ad] atomically:YES];
            CHECK(nxgal_pso_archive_open_dir(ad) == 0, "坏文件用例：重登记失败");
            [[NSFileManager defaultManager] removeItemAtPath:bad error:nil];
            uint64_t f0 = g_ra_lvfail, b0[4], b1[4]; nxgal_pso_cache_stats(b0);
            for (int r = 0; r < 2; r++) @autoreleasepool { MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new]; d.computeFunctionDescriptor = fn[0]; NSError *e = nil;
                CHECK(gal_new_compute_pso(d, &e), "坏文件用例：cs 第 %d 次现建失败：%s", r, e.localizedDescription.UTF8String); }
            nxgal_pso_cache_stats(b1);
            CHECK(g_ra_lvfail == f0 && b1[0] == b0[0] && b1[1] - b0[1] == 2 && g_ra_badtry == 1,
                  "坏文件：期望账本 fail 不调、2 次都现建、坏片只试开 1 次（实得 fail +%llu、命中 +%llu、现建 +%llu、试开 %llu）",
                  (unsigned long long)(g_ra_lvfail - f0), (unsigned long long)(b1[0] - b0[0]), (unsigned long long)(b1[1] - b0[1]), (unsigned long long)g_ra_badtry);
        }
        printf("  命中 %llu、现建 %llu；已映射峰值 %llu 字节（上限 %llu）；拦截层开失败 %llu、账本 fail %llu\n", (unsigned long long)(s1[0] - s0[0]), (unsigned long long)(s1[1] - s0[1]),
               (unsigned long long)g_ra_peak, (unsigned long long)g_ra_cap, (unsigned long long)g_ra_failopen, (unsigned long long)g_ra_lvfail);
    }
    nxgal_shutdown(); printf("%s %d/%d\n", g_fail ? "✗ 失败" : "✓ 全过", g_checks - g_fail, g_checks); return g_fail ? 1 : 0;
}
int main(int argc, char **argv) {
    signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig); signal(SIGABRT, on_sig);
    setvbuf(stdout, NULL, _IOLBF, 0); g_argv0 = argv[0];
    if (argc == 3 && !strcmp(argv[1], "--first-load")) {   // 子进程：首个 nxgal_prog_* 调用是 load_binary
        if (nxgal_init(0)) return 3;
        NSData *d = [NSData dataWithContentsOfFile:@(argv[2])]; if (!d) return 4;
        uint32_t id = nxgal_prog_load_binary(d.bytes, (int32_t)d.length, 1); int st = nxgal_prog_status(id, 1);
        if (st) printf("  子进程：load_binary 状态 %d（%s）\n", st, nxgal_prog_last_error());
        gal_prog *p = gal_prog_get(id);
        if (!st && (!p || !p->fs_color_round)) { printf("  子进程：load_binary 丢失 half 颜色量化能力\n"); return 1; }
        return st ? 1 : 0; }
    if (argc == 4 && !strcmp(argv[1], "--cache-fill")) {   // 子进程：从 SPIR-V 现编（写 NXGAL_SHADER_CACHE_DIR）并把程序二进制写到 argv[3]
        if (nxgal_init(0)) return 3;
        uint32_t id = create_vf(argv[2]); if (!id || nxgal_prog_status(id, 1)) { printf("  子进程：现编失败（%s）\n", nxgal_prog_last_error()); return 1; }
        int32_t n = nxgal_prog_binary(id, NULL, 0); if (n <= 20) return 5;
        uint8_t *b = malloc(n); if (nxgal_prog_binary(id, b, n) != n) return 6;
        FILE *f = fopen(argv[3], "wb"); if (!f) return 4; fwrite(b, 1, (size_t)n, f); fclose(f); return 0; }
    if (argc == 3 && !strcmp(argv[1], "--arch-lazy")) return t_arch_lazy(argv[2], 0);
    if (argc == 3 && !strcmp(argv[1], "--arch-lru")) return t_arch_lazy(argv[2], 1);
    if (argc < 2) { fprintf(stderr, "用法：t_prog <手写 SPIR-V 目录> [语料目录]\n"); return 2; }
    if (argc == 3 && !strcmp(argv[1], "--count")) {   // 计数开（诊断口径）：A 画图、C 计算现编带计数格，D 越界计数按手算；输出与计数关相同
        setenv("NXGAL_BOUNDS_COUNT", "1", 1); g_nocount = 0;
        if (nxgal_init(0)) return 3;
        @autoreleasepool {
            setup_draw(); t_graphics(argv[2]); t_compute(argv[2]);
            // 计数开时离线库不开（离线库按出包口径不带计数）：照常调开库，cso.spv 也在库里——D 仍须现翻并计出数，证明没走离线库
            char ld[1024]; snprintf(ld, sizeof ld, "%s/lib", argv[2]); CHECK(nxgal_prog_lib_open(ld) == 0, "计数开：开离线库调用应成功（跳过）：%s", nxgal_prog_last_error());
            t_bounds(argv[2]);
        }
        nxgal_shutdown(); printf("%s %d/%d\n", g_fail ? "✗ 失败" : "✓ 全过", g_checks - g_fail, g_checks); return g_fail ? 1 : 0; }
    // 缺省 = 出包口径（计数关）：全套用例；--count 另跑计数口径
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    if (nxgal_init(0)) { printf("✗ 初始化失败\n"); return 1; }
    @autoreleasepool {
        setup_draw();
        t_queued(argv[1]);
        t_graphics(argv[1]);
        t_compute(argv[1]);
        t_bounds(argv[1]);
        t_oob_cas(argv[1]);
        t_nwg_launder(argv[1]);
        t_fragin(argv[1]);
        t_layer(argv[1]);
        t_spill(argv[1]);
        if (argc >= 3) t_corpus(argv[2]);
    }
    nxgal_shutdown();
    printf("%s %d/%d\n", g_fail ? "✗ 失败" : "✓ 全过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
