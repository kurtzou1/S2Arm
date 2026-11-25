// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Production NVN draws report slot 27 through an RGBA32F observation target:
// native half attachment rounding cannot conceal a missing/stale mask binding.
#ifndef NVN_COLOR_ROUND_SOURCE
#define NVN_COLOR_ROUND_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_COLOR_ROUND_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); } while (0)

static NSString *const source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"struct O { float4 c [[color(0)]]; float4 observe [[color(1)]]; };\n"
"fragment O colors(constant uint &mask [[buffer(27)]]) { O o; o.c=float4(1.0007f); o.observe=float4(float(mask),mask&1u?1.0f:1.0007f,0,1); return o; }\n"
"struct U { uint4 c [[color(0)]]; float4 observe [[color(1)]]; };\n"
"fragment U integers(constant uint &mask [[buffer(27)]]) { return {uint4(123),float4(float(mask),mask&1u?1.0f:1.0007f,0,1)}; }\n"
"struct M { float4 c [[color(1)]]; float4 observe [[color(2)]]; };\n"
"fragment M mapped(constant uint &mask [[buffer(27)]]) { return {float4(1.0007f),float4(float(mask),mask&1u?1.0f:1.0007f,0,1)}; }\n"
"struct T { float4 a [[color(0)]]; float4 b [[color(1)]]; float4 observe [[color(2)]]; };\n"
"fragment T multiple(constant uint &mask [[buffer(27)]]) { return {float4(1.0007f),float4(1.0007f),float4(float(mask),mask&1u?1.0f:1.0007f,0,1)}; }\n"
"struct W { float4 observe [[color(1)]]; };\n"
"fragment W unwritten(constant uint &mask [[buffer(27)]]) { return {float4(float(mask),mask&1u?1.0f:1.0007f,0,1)}; }\n"
"static inline float4 s2a_blend_zero_rgb(float4 x) { if (x.w == 0.0f) x.xyz = select(x.xyz, float3(0.0f), (as_type<uint3>(x.xyz) & 0x7f800000u) == 0x7f800000u); return x; }\n"
"fragment O blend_nan(float4 pos [[position]], constant uint &mask [[buffer(27)]]) {\n"
"  O o; float n = as_type<float>(0x7fc00000u);\n"
"  o.c = (int(pos.x) == 0) ? float4(n, n, n, 0.0f) : float4(1.0f, 0.5f, 0.25f, 0.5f);\n"
"  if (mask & 256u) o.c = s2a_blend_zero_rgb(o.c);\n"
"  o.observe = float4(float(mask), 0, 0, 1); return o;\n"
"}\n";

static NvShader *shader(id<MTLLibrary> lib, NSString *name, int stage) {
    NvShader *s=[NvShader new]; s->stage=stage; s->fn=[lib newFunctionWithName:name]; REQUIRE(s->fn);
    strlcpy(s->key,stage?"bbbbbbbbbbbbbbbb_b":"aaaaaaaaaaaaaaaa_b",sizeof s->key);
    s->rf.pos_attr=-1; s->rf.has_user=stage?2:1;
    if(stage) { s->rf.color_known=1; s->rf.color_mask=3; }
    return s;
}

static void texture(tex_t *t, pool_t *pool, size_t off, int format) {
    memset(t,0,sizeof *t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=format,.flags=NVN_TEXTURE_FLAGS_IMAGE,.width=8,.height=1,.depth=1,.levels=1};
    t->pool=pool; t->off=off; t->mem=pool->mem+off; nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static void targets(tex_t *half, tex_t *observe) {
    rp_flush(); memset(&R.rt,0,sizeof R.rt); R.rt.n=2; R.rt.color[0]=half; R.rt.color[1]=observe;
    R.has_rt=1; g_pso_dirty=1; args_dirty_all();
}
static void emit(unsigned x) {
    R.has_sc=1; R.sc=(p_scissor){.x=x,.y=0,.w=1,.h=1}; g_pso_dirty=1;
    const p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1}; draw(&d,NULL);
}
static void readback(tex_t *t, const unsigned *expected, unsigned count, const char *label) {
    id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(b);
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer];
    id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,1,1)
        toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    const float *p=b.contents;
    for(unsigned x=0;x<count;x++) CHECK(p[x*4]==expected[x] && p[x*4+1]==(expected[x]&1?1.0f:1.0007f),
        "%s pixel%u: mask %u -> %.0f, FP32 observer %.8f",label,x,expected[x],p[x*4],p[x*4+1]);
}
static void finish(void) { uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error()); }

int main(void) { @autoreleasepool {
    char map[]="/tmp/t_round_map_XXXXXX",user[]="/tmp/t_round_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    setenv("DM_NVN_TBDR","0",1); mtl_init(); printf("BACKEND Metal%d\n",g_m3?3:4);
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!lib) fprintf(stderr,"MSL %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvProg *program=[NvProg new]; program->sh[0]=shader(lib,@"triangle",0); program->sh[1]=shader(lib,@"colors",1);
    prog_t p={.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(p.serial,program);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);
    tex_t half,observe,ordinary,rhalf,rghalf,integer;
    texture(&half,pool,0,NVN_FORMAT_RGBA16F); texture(&observe,pool,65536,NVN_FORMAT_RGBA32F); texture(&ordinary,pool,131072,NVN_FORMAT_RGBA32F);
    texture(&rhalf,pool,196608,NVN_FORMAT_R16F); texture(&rghalf,pool,262144,NVN_FORMAT_RG16F); texture(&integer,pool,327680,NVN_FORMAT_RGBA32UI);
    // Defined pre-existing table state makes an omitted production bind fail by
    // a numeric readback, instead of depending on unbound-buffer GPU validation.
    id<MTLBuffer> zero=[g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared]; REQUIRE(zero); *(uint32_t *)zero.contents=0; res_add(zero); tab_addr(g_ft,zero.gpuAddress,27);
    nvn_be_sub_begin(); state_reset(); S.prog=&p; targets(&half,&observe);
    emit(0); S.color.blend_en=1; emit(1); S.color.blend_en=0; emit(2);
    S.chmask.mask&=~15u; emit(3); S.chmask.mask|=15u; S.ms.a2c=1; emit(4); S.ms.a2c=0;
    rp_flush(); emit(5);
    R.sc.x=6; const p_draw cached={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1}; draw(&cached,NULL); finish();
    const unsigned wanted[]={1,0,1,0,0,1,1}; readback(&observe,wanted,7,"half/change/new encoder/cached PSO");
    nvn_be_sub_begin(); state_reset(); S.prog=&p; targets(&ordinary,&observe); emit(0); finish();
    const unsigned no_round[]={0}; readback(&observe,no_round,1,"RGBA32F remains full precision");
    const unsigned round[]={1};
    nvn_be_sub_begin(); state_reset(); S.prog=&p; targets(&rhalf,&observe); emit(0); finish(); readback(&observe,round,1,"R16Float");
    nvn_be_sub_begin(); state_reset(); S.prog=&p; targets(&rghalf,&observe); emit(0); finish(); readback(&observe,round,1,"RG16Float");
    program->sh[1]->fn_u=[lib newFunctionWithName:@"integers"]; program->sh[1]->u_mask=1;
    nvn_be_sub_begin(); state_reset(); S.prog=&p; targets(&integer,&observe); emit(0); finish(); readback(&observe,no_round,1,"typed uint output excludes RTZ");
    program->sh[1]=shader(lib,@"unwritten",1); program->sh[1]->rf.color_mask=2;
    nvn_be_sub_begin(); state_reset(); S.prog=&p; targets(&half,&observe); emit(0); finish(); readback(&observe,no_round,1,"unwritten half attachment");
    program->sh[1]=shader(lib,@"mapped",1);
    nvn_be_sub_begin(); state_reset(); S.prog=&p; rp_flush(); memset(&R.rt,0,sizeof R.rt);
    R.rt.n=3; R.rt.color[1]=&half; R.rt.color[2]=&observe; R.has_rt=1; args_dirty_all();
    const uint8_t lmap[8]={255,0,1,255,255,255,255,255}; g_pso_lmap=lmap; g_pso_fsfn=program->sh[1]->fn;
    emit(0); finish(); readback(&observe,round,1,"merged physical attachment1 maps to logical output0");
    program->sh[1]=shader(lib,@"multiple",1); program->sh[1]->rf.color_mask=7;
    nvn_be_sub_begin(); state_reset(); S.prog=&p; rp_flush(); memset(&R.rt,0,sizeof R.rt);
    R.rt.n=3; R.rt.color[0]=&half; R.rt.color[1]=&rghalf; R.rt.color[2]=&observe; R.has_rt=1; args_dirty_all();
    emit(0); finish(); const unsigned both[]={3}; readback(&observe,both,1,"two half outputs use persistent table entry3");
    // #674: SRC_ALPHA blending on float target sets bit 8+l so alpha==0 NaN RGB does not poison dst via 0 * NaN = NaN
    program->sh[1]=shader(lib,@"blend_nan",1);
    nvn_be_sub_begin(); state_reset(); S.prog=&p; targets(&half,&observe);
    { id<MTLTexture> ht = tex_mtl(&half);
      MTLRenderPassDescriptor *clr = [MTLRenderPassDescriptor renderPassDescriptor];
      clr.colorAttachments[0].texture = ht; clr.colorAttachments[0].loadAction = MTLLoadActionClear;
      clr.colorAttachments[0].storeAction = MTLStoreActionStore; clr.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
      id<MTLCommandQueue> cq = [g_dev newCommandQueue]; id<MTLCommandBuffer> ccb = [cq commandBuffer];
      id<MTLRenderCommandEncoder> cre = [ccb renderCommandEncoderWithDescriptor:clr]; [cre endEncoding];
      [ccb commit]; [ccb waitUntilCompleted]; REQUIRE(ccb.status == MTLCommandBufferStatusCompleted); }
    S.color.blend_en = 1;
    S.blend[0] = (blend_st){.target=0, .src_rgb=NVN_BLEND_FUNC_SRC_ALPHA, .dst_rgb=NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, .src_a=NVN_BLEND_FUNC_ZERO, .dst_a=NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, .eq_rgb=NVN_BLEND_EQUATION_ADD, .eq_a=NVN_BLEND_EQUATION_ADD};
    emit(0); emit(1); finish();
    { id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(b);
      id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer];
      id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
      [e copyFromTexture:tex_mtl(&half) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(2,1,1)
          toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
      [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
      const uint16_t *h16 = (const uint16_t *)b.contents;
      CHECK(h16[0]==0x0000 && h16[1]==0x0000 && h16[2]==0x0000 && h16[3]==0x3c00,
            "SRC_ALPHA blend with alpha==0 NaN RGB preserves (0,0,0,1): got %04x %04x %04x %04x", h16[0], h16[1], h16[2], h16[3]);
      CHECK(h16[4]==0x3800 && h16[5]==0x3400 && h16[6]==0x3000 && h16[7]==0x3800,
            "SRC_ALPHA blend with alpha==0.5 finite RGB blends normally: got %04x %04x %04x %04x", h16[4], h16[5], h16[6], h16[7]); }
    unlink(map); unlink(user);
} printf("%s t_nvn_color_round: %u checks, %u failures\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
