// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// #674 可编程混合走真实宿主（nvn_mtl.m pso_pb_eff / fs_pb_fn / pso_desc / enc_r_slot27）：片元源码照 SPIRV-Cross 格式写、经 gal_color_round_pb_msl 改写（同出包 / 机上现编），
//   浮点附件开混合的绘制由宿主特化开关常量、关掉固定混合、往 27 号槽绑混合状态。期望手写（Maxwell：混合里 0 × 任何数 = 0，graphics/nvn/tests/maxwell_blend_ref.py）：
//   ① #674 原状态：源 (NaN,NaN,NaN,0) 以 SRC_ALPHA / ONE_MINUS_SRC_ALPHA（A：ZERO / ONE_MINUS_SRC_ALPHA）混进 (0,0,0,1) → (0,0,0,1)；正常半透明照常
//   ② 目标是 NaN（清 NaN 窄修救不了的一路）：源 alpha 1、ONE_MINUS_SRC_ALPHA → 目标项 0 × NaN = 0，结果就是源；固定混合是 NaN
//   ③ 同一次绘制两个重叠三角形依次混合：(1,1,1,.5) 两遍 SRC_ALPHA / ONE_MINUS_SRC_ALPHA（RGB 与 A 同）混进 (0,0,0,0) → (.75,.75,.75,.375)
//   ④ 第二源（SRC1_ALPHA，输出 1 的 alpha = 0）清掉源 NaN；⑤ 混合常量色 (0,1,0,1) 的 CONSTANT_COLOR 只清 R / B
//   ⑥ 老库的着色器（没有开关常量）照旧固定混合、记一次退回
//   ⑦ 着色器照生产加载（sh_fn_constants：带函数常量的函数换成不设值的特化）：特化后的函数读不出常量表（Metal 行为），开关仍认得出（加载时先读）；
//      ①–⑥ 都用这样加载的着色器跑（11-24 真机：特化后再读，开关一律读成 0，可编程混合整套没生效）
#ifndef NVN_PBLEND_SOURCE
#define NVN_PBLEND_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_PBLEND_SOURCE
#include "gal_colorround.h"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); } while (0)

#define HEAD "#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n"
// 像素 0 / 1 各出一种源；输出 1 是第二源（附件 1 不存在时不落地）
static const char *k_frag = HEAD
"struct main0_out\n{\n    float4 out_var_SV_Target0 [[color(0)]];\n    float4 out_var_SV_Target1 [[color(1)]];\n};\n\n"
"fragment main0_out main0(float4 gl_FragCoord [[position]], constant float4* src [[buffer(0)]])\n{\n"
"    main0_out out = {};\n    out.out_var_SV_Target0 = src[2u * uint(gl_FragCoord.x)];\n    out.out_var_SV_Target1 = src[2u * uint(gl_FragCoord.x) + 1u];\n    return out;\n}\n\n";
static NSString *const k_vert = @"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i % 3u],0,1); }\n";
// 老库：同样的输出，没有开关常量（翻译器加开关之前出的库）
static NSString *const k_old = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct O { float4 c [[color(0)]]; };\n"
"fragment O old_main(float4 pos [[position]], constant float4* src [[buffer(0)]], constant uint &mask [[buffer(27)]]) { O o; o.c = src[2u * uint(pos.x)]; return o; }\n";

static NvShader *shader(id<MTLLibrary> lib, NSString *name, int stage) {
    NvShader *s=[NvShader new]; s->stage=stage; s->fn=[lib newFunctionWithName:name]; s->plib=lib; REQUIRE(s->fn);
    REQUIRE(sh_fn_constants(s, lib, name, nil, stage, name));   // 同 shader_build：有函数常量就换成不设值的特化
    strlcpy(s->key,stage?"cccccccccccccccc_b":"dddddddddddddddd_b",sizeof s->key);
    s->rf.pos_attr=-1; s->rf.has_user=stage?2:1;
    if(stage) { s->rf.color_known=1; s->rf.color_mask=3; }
    return s;
}
static void texture(tex_t *t, pool_t *pool, size_t off, int format) {
    memset(t,0,sizeof *t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=format,.flags=NVN_TEXTURE_FLAGS_IMAGE,.width=8,.height=1,.depth=1,.levels=1};
    t->pool=pool; t->off=off; t->mem=pool->mem+off; nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static void read4(tex_t *t, float *out, unsigned n) {
    id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(b);
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer];
    id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(n,1,1)
        toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    memcpy(out, b.contents, n*16);
}
static int same(float x, float y) { return (isnan(x) && isnan(y)) || x == y; }
static int same4(const float *g, const float *w) { for (int i=0;i<4;i++) if (!same(g[i],w[i])) return 0; return 1; }
static void finish(void) { uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
static id<MTLBuffer> g_src; static size_t g_src_at;
static void draw_px(const float *srcs, unsigned n, unsigned count) {   // 源（每像素两个 float4：输出 0、输出 1）；count = 3 一个三角形，6 两个重叠。每笔用缓冲里自己的一段（同一次提交里不互相覆盖）
    memcpy((uint8_t *)g_src.contents + g_src_at, srcs, n*32);
    R.has_sc=1; R.sc=(p_scissor){.x=0,.y=0,.w=n,.h=1}; g_pso_dirty=1;
    tab_addr(g_ft, g_src.gpuAddress + g_src_at, 0); g_src_at += 256;
    const p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=count,.instances=1}; draw(&d,NULL);
}
static void blend(uint32_t eq, uint32_t sr, uint32_t dr, uint32_t ea, uint32_t sa, uint32_t da) {
    S.color.blend_en = 1;
    S.blend[0] = (blend_st){.target=0, .src_rgb=sr, .dst_rgb=dr, .src_a=sa, .dst_a=da, .eq_rgb=eq, .eq_a=ea};
}

int main(void) { @autoreleasepool {
    char map[]="/tmp/t_pblend_map_XXXXXX",user[]="/tmp/t_pblend_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    setenv("DM_NVN_TBDR","0",1); mtl_init(); printf("BACKEND Metal%d\n",g_m3?3:4);
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    char why[256]; char *msl = gal_color_round_pb_msl(k_frag, "main0", why); REQUIRE(msl);
    NSError *error=nil; MTLCompileOptions *co=[MTLCompileOptions new]; co.mathMode=MTLMathModeRelaxed; co.preserveInvariance=YES;
    id<MTLLibrary> flib=[g_dev newLibraryWithSource:@(msl) options:co error:&error]; if(!flib) fprintf(stderr,"MSL %s\n",error.localizedDescription.UTF8String); REQUIRE(flib);
    id<MTLLibrary> vlib=[g_dev newLibraryWithSource:k_vert options:co error:&error]; REQUIRE(vlib);
    id<MTLLibrary> olib=[g_dev newLibraryWithSource:k_old options:co error:&error]; REQUIRE(olib);
    NvProg *program=[NvProg new]; program->sh[0]=shader(vlib,@"triangle",0); program->sh[1]=shader(flib,@"main0",1);
    { NvShader *f=program->sh[1];
      CHECK(f->fn.functionConstantsDictionary.count==0 && fs_pb_avail(f)==3, "⑦ 照生产加载：特化后的函数常量表 %lu 项（Metal 读不出，应 0）、认出的开关 %#x（两个浮点输出，应 0x3）",
            (unsigned long)f->fn.functionConstantsDictionary.count, fs_pb_avail(f)); }
    NvShader *writer=shader(olib,@"old_main",1); writer->rf.color_mask=1; strlcpy(writer->key,"eeeeeeeeeeeeeeee_b",sizeof writer->key);   // 写目标值用：不开混合，照原样写源
    prog_t p={.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p.serial,program);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    g_src=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; REQUIRE(g_src); res_add(g_src);
    tex_t t32; texture(&t32,pool,0,NVN_FORMAT_RGBA32F);
    const float QNAN = NAN;
    float got[8*4];
    // 目标值先由一笔不开混合的绘制写进去（这张贴图由客体内存池支撑，CPU 直接改 Metal 贴图会被宿主按池内容同步盖掉），再画被测的一笔
    #define RUN(dst_, srcs_, npx_, verts_) do { float pre_[8*8] = {0}; for (unsigned x_ = 0; x_ < (npx_); x_++) memcpy(pre_ + 8*x_, (dst_) + 4*x_, 16); \
        g_src_at = 0; nvn_be_sub_begin(); state_reset(); S.prog=&p; rp_flush(); memset(&R.rt,0,sizeof R.rt); \
        R.rt.n=1; R.rt.color[0]=&t32; R.has_rt=1; args_dirty_all(); S.color.blend_en=0; NvShader *keep_=program->sh[1]; program->sh[1]=writer; \
        draw_px(pre_, npx_, 3); program->sh[1]=keep_; setup(); draw_px(srcs_, npx_, verts_); finish(); read4(&t32, got, npx_); } while (0)
    #define setup() blend(NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_SRC_ALPHA, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_ZERO, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA)
    { const float dst[] = {0,0,0,1, 0,0,0,1}, src[] = {QNAN,QNAN,QNAN,0, 0,0,0,0, 1,.5f,.25f,.5f, 0,0,0,0};
      RUN(dst, src, 2, 3);
      const float w0[] = {0,0,0,1}, w1[] = {.5f,.25f,.125f,.5f};
      CHECK(same4(got, w0), "① #674 原状态：(NaN,NaN,NaN,0) 混进 (0,0,0,1) 得 (0,0,0,1)，真结果 (%g,%g,%g,%g)", got[0],got[1],got[2],got[3]);
      CHECK(same4(got+4, w1), "① 正常半透明照常：真结果 (%g,%g,%g,%g)", got[4],got[5],got[6],got[7]); }
    #undef setup
    #define setup() blend(NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA)
    { const float dst[] = {QNAN,QNAN,QNAN,QNAN}, src[] = {1,2,3,1, 0,0,0,0};
      RUN(dst, src, 1, 3);
      const float w[] = {1,2,3,1};
      CHECK(same4(got, w), "② 目标 NaN、源 alpha 1：目标项 0 × NaN = 0，得源 (1,2,3,1)，真结果 (%g,%g,%g,%g)", got[0],got[1],got[2],got[3]); }
    #undef setup
    #define setup() blend(NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_SRC_ALPHA, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_SRC_ALPHA, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA)
    { const float dst[] = {0,0,0,0}, src[] = {1,1,1,.5f, 0,0,0,0};
      RUN(dst, src, 1, 6);
      const float w[] = {.75f,.75f,.75f,.375f};   // RGB：1×.5 + 0 = .5 → 1×.5 + .5×.5 = .75；A：.5×.5 + 0 = .25 → .5×.5 + .25×.5 = .375
      CHECK(same4(got, w), "③ 一次绘制两个重叠三角形依次混合：得 (.75,.75,.75,.375)，真结果 (%g,%g,%g,%g)", got[0],got[1],got[2],got[3]); }
    #undef setup
    #define setup() blend(NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_SRC1_ALPHA, NVN_BLEND_FUNC_ONE, NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ZERO)
    { const float dst[] = {.25f,.25f,.25f,.25f}, src[] = {QNAN,QNAN,QNAN,1, 0,0,0,0};
      RUN(dst, src, 1, 3);
      const float w[] = {.25f,.25f,.25f,1};
      CHECK(same4(got, w), "④ 第二源 SRC1_ALPHA = 0 清掉源 NaN：得 (.25,.25,.25,1)，真结果 (%g,%g,%g,%g)", got[0],got[1],got[2],got[3]); }
    #undef setup
    #define setup() do { blend(NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_CONSTANT_COLOR, NVN_BLEND_FUNC_ZERO, NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ZERO); \
        S.blend_color[0]=0; S.blend_color[1]=1; S.blend_color[2]=0; S.blend_color[3]=1; } while (0)
    { const float dst[] = {0,0,0,0}, src[] = {QNAN,2,QNAN,1, 0,0,0,0};
      RUN(dst, src, 1, 3);
      const float w[] = {0,2,0,1};
      CHECK(same4(got, w), "⑤ 混合常量色 (0,1,0,1) 的 CONSTANT_COLOR 只清 R / B：得 (0,2,0,1)，真结果 (%g,%g,%g,%g)", got[0],got[1],got[2],got[3]); }
    #undef setup
    program->sh[1]=shader(olib,@"old_main",1); program->sh[1]->rf.color_mask=1;
    uint64_t fb0 = atomic_load(&g_pb_fallback);
    #define setup() blend(NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, NVN_BLEND_EQUATION_ADD, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA)
    { const float dst[] = {QNAN,QNAN,QNAN,QNAN}, src[] = {1,2,3,1, 0,0,0,0};
      RUN(dst, src, 1, 3);
      CHECK(isnan(got[0]) && isnan(got[1]) && isnan(got[2]), "⑥ 老库着色器：照旧固定混合（IEEE，目标 NaN 传下来），真结果 (%g,%g,%g,%g)", got[0],got[1],got[2],got[3]);
      CHECK(atomic_load(&g_pb_fallback) == fb0 + 1, "⑥ 退回固定混合记一次（%llu → %llu）", (unsigned long long)fb0, (unsigned long long)atomic_load(&g_pb_fallback)); }
    #undef setup
    free(msl); unlink(map); unlink(user);
} printf("%s t_nvn_pblend: %u checks, %u failures\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
